// Small IR helpers the interprocedural passes share: Function::eraseFromParent (llvm/lib/IR/Function.cpp:
// dropAllReferences + erase), Constant::hasZeroLiveUses / hasNLiveUses (llvm/lib/IR/Constants.cpp;
// removeDeadConstantUsers is sccp.goose's sc_remove_dead_constant_users), GlobalValue::isDiscardableIfUnused /
// hasLinkOnceLinkage & co. (llvm/include/llvm/IR/GlobalValue.h).
import std;
import ir;
import irutil;
import gen_attrs;
import tli;
import dinfo;
import sccp;

fn gv_linkage(v: i32) -> i64 { globs[glob_of(v)].linkage as i64 }
fn gv_has_local_linkage(v: i32) -> bool { let l = gv_linkage(v); l == LK_INTERNAL || l == LK_PRIVATE }
fn gv_has_linkonce_linkage(v: i32) -> bool { let l = gv_linkage(v); l == LK_LINKONCE_ANY || l == LK_LINKONCE_ODR }
fn gv_has_available_externally_linkage(v: i32) -> bool { gv_linkage(v) == LK_AVAILABLE_EXTERNALLY }
// GlobalValue::isDiscardableIfUnused(Linkage): linkonce, local, available_externally
fn gv_is_discardable_if_unused(v: i32) -> bool {
    gv_has_linkonce_linkage(v) || gv_has_local_linkage(v) || gv_has_available_externally_linkage(v)
}
// GlobalValue::isInterposableLinkage
fn gv_interposable_linkage(v: i32) -> bool {
    let l = gv_linkage(v);
    return l == LK_WEAK_ANY || l == LK_LINKONCE_ANY || l == LK_COMMON || l == LK_EXTERN_WEAK;
}
fn gv_fn_def_has(v: i32, kind: i64) -> bool {
    vals[v].kind == VK_FUNC && !func_is_decl(v) && aset_has(alist_fn(globs[glob_of(v)].attrs), kind)
}
// Module::getSemanticInterposition
fn module_semantic_interposition(m: i32) -> bool { tli_module_flag_int(m, "SemanticInterposition") > 0 }
// GlobalValue::isInterposable(CheckNoIPA)
fn gv_is_interposable(v: i32, check_noipa: bool) -> bool {
    if check_noipa && gv_fn_def_has(v, AK_NoIPA) { return true; }
    if gv_interposable_linkage(v) { return true; }
    return globs[glob_of(v)].dso_local == 0 && module_semantic_interposition(globs[glob_of(v)].module);
}
// GlobalValue::mayBeDerefined
fn gv_may_be_derefined(v: i32) -> bool {
    let l = gv_linkage(v);
    if l == LK_WEAK_ODR || l == LK_LINKONCE_ODR || l == LK_AVAILABLE_EXTERNALLY { return true; }
    return gv_is_interposable(v, true) || gv_fn_def_has(v, AK_NoBuiltin);
}
// GlobalValue::hasExactDefinition
fn gv_has_exact_definition(v: i32) -> bool { !func_is_decl(v) && !gv_may_be_derefined(v) }

// constantIsDead(C, RemoveDeadUsers = false)
recursive fn ipo_constant_is_dead(c: i32) -> bool {
    if is_global(c) { return false; }
    var u = first_use(c);
    while u >= 0 {
        let us = uses[u].user;
        if !is_constant(us) { return false; }
        if !ipo_constant_is_dead(us) { return false; }
        u = use_next(u);
    }
    return true;
}
// Constant::hasNLiveUses
fn ipo_has_n_live_uses(c: i32, n: i64) -> bool {
    var num: i64 = 0;
    var u = first_use(c);
    while u >= 0 {
        let us = uses[u].user;
        if !is_constant(us) || !ipo_constant_is_dead(us) {
            num++;
            if num > n { return false; }
        }
        u = use_next(u);
    }
    return num == n;
}
fn ipo_has_zero_live_uses(c: i32) -> bool { ipo_has_n_live_uses(c, 0) }

// Function::eraseFromParent: dropAllReferences (the body goes), then the function leaves its module.
fn func_erase_from_parent(f: i32) {
    var b = func_first_block(f);
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 { drop_all_refs(i); i = inst_next(i); }
        b = block_next(b);
    }
    b = func_first_block(f);
    while b >= 0 { let nb = block_next(b); block_erase(b); b = nb; }
    sc_remove_dead_constant_users(f);   // ~GlobalValue
    if first_use(f) >= 0 { fatal("internal: erasing a function that still has uses"); }
    if f < val_vam.len && val_vam[f] >= 0 { vam_handle_deletion(f); }
    ipo_metadata_handle_deletion(f);
    drop_all_refs(f);
    module_remove_global(f);
    let m = globs[glob_of(f)].module;
    if vals[f].name >= 0 { symtab_remove(modules[m].symtab, f); }
    val_set_dead(f);
}

// Function::dropAllReferences: the body goes (every block erased), the function stays
fn func_drop_all_references(f: i32) {
    var b = func_first_block(f);
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 { drop_all_refs(i); i = inst_next(i); }
        b = block_next(b);
    }
    b = func_first_block(f);
    while b >= 0 { let nb = block_next(b); block_erase(b); b = nb; }
}

// makeFunctionBodyUnreachable (Inliner.cpp): drop the body, then one block with `unreachable`
fn func_make_body_unreachable(f: i32) {
    func_drop_all_references(f);
    let bb = create_block_after(f, -1, "");
    let u = create_inst(OP_UNREACHABLE, T_VOID, []);
    block_append_inst(bb, u);
}

// ValueAsMetadata::handleDeletion for a constant (a function): the nodes using its ValueAsMetadata get a null
// operand and lose their uniquing (MDNode::handleChangedOperand: "deleted constants" become distinct)
fn ipo_metadata_handle_deletion(v: i32) {
    if md_tab.len == 0 { md_rebuild_tab(); }
    let h = md_hash(MK_VALUE, v, []);
    let mask = md_tab.len - 1;
    var j = (h as i64) & mask;
    var vam: i32 = -1;
    loop {
        let e = md_tab[j];
        if e < 0 { break; }
        if mds[e].kind as i64 == MK_VALUE && mds[e].extra == v && mds[e].nops == 0 { vam = e; break; }
        j = (j + 1) & mask;
    }
    if vam < 0 { return; }
    var changed = false;
    for k in mds.len {
        let n = mds[k];
        if n.kind as i64 != MK_TUPLE { continue; }
        var hit = false;
        for q in n.nops as i64 { if md_ops[(n.ops as i64) + q] == vam { md_ops[(n.ops as i64) + q] = -1; hit = true; } }
        if hit { mds[k].distinct = 1; changed = true; }
    }
    if changed { md_tab.clear(); }
}
