// Small IR helpers the interprocedural passes share: Function::eraseFromParent (llvm/lib/IR/Function.cpp:
// dropAllReferences + erase), Constant::hasZeroLiveUses / hasNLiveUses (llvm/lib/IR/Constants.cpp;
// removeDeadConstantUsers is sccp.goose's sc_remove_dead_constant_users), GlobalValue::isDiscardableIfUnused /
// hasLinkOnceLinkage & co. (llvm/include/llvm/IR/GlobalValue.h).
import std;
import ir;
import irutil;
import gen_attrs;
import tli;

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
    if first_use(f) >= 0 { fatal("internal: erasing a function that still has uses"); }
    drop_all_refs(f);
    module_remove_global(f);
    let m = globs[glob_of(f)].module;
    if vals[f].name >= 0 { symtab_remove(modules[m].symtab, f); }
    val_set_dead(f);
}
