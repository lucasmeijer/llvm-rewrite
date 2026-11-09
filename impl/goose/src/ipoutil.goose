// Small IR helpers the interprocedural passes share: Function::eraseFromParent (llvm/lib/IR/Function.cpp:
// dropAllReferences + erase), Constant::hasZeroLiveUses / hasNLiveUses (llvm/lib/IR/Constants.cpp;
// removeDeadConstantUsers is sccp.goose's sc_remove_dead_constant_users), GlobalValue::isDiscardableIfUnused /
// hasLinkOnceLinkage & co. (llvm/include/llvm/IR/GlobalValue.h).
import std;
import ir;
import irutil;

fn gv_linkage(v: i32) -> i64 { globs[glob_of(v)].linkage as i64 }
fn gv_has_local_linkage(v: i32) -> bool { let l = gv_linkage(v); l == LK_INTERNAL || l == LK_PRIVATE }
fn gv_has_linkonce_linkage(v: i32) -> bool { let l = gv_linkage(v); l == LK_LINKONCE_ANY || l == LK_LINKONCE_ODR }
fn gv_has_available_externally_linkage(v: i32) -> bool { gv_linkage(v) == LK_AVAILABLE_EXTERNALLY }
// GlobalValue::isDiscardableIfUnused(Linkage): linkonce, local, available_externally
fn gv_is_discardable_if_unused(v: i32) -> bool {
    gv_has_linkonce_linkage(v) || gv_has_local_linkage(v) || gv_has_available_externally_linkage(v)
}
// GlobalValue::isInterposable: weak, linkonce (non-ODR), extern_weak, common, external_weak... (mayBeDerefined)
fn gv_is_interposable(v: i32) -> bool {
    let l = gv_linkage(v);
    if l == LK_WEAK_ANY || l == LK_LINKONCE_ANY || l == LK_COMMON || l == LK_EXTERN_WEAK { return true; }
    // isInterposableLinkage(External) is false; semantic interposition (the "SemanticInterposition" module flag)
    // is not consulted by the passes using this helper
    return false;
}
// GlobalValue::hasExactDefinition: !isDeclaration && !mayBeDerefined (linkonce/weak non-ODR, available_externally, ...)
fn gv_has_exact_definition(v: i32) -> bool {
    if func_is_decl(v) { return false; }
    let l = gv_linkage(v);
    // isDefinitionExact: !mayBeDerefined(); mayBeDerefined: weak/linkonce (any and ODR), available_externally,
    // extern_weak, common
    return !(l == LK_WEAK_ANY || l == LK_WEAK_ODR || l == LK_LINKONCE_ANY || l == LK_LINKONCE_ODR ||
             l == LK_AVAILABLE_EXTERNALLY || l == LK_EXTERN_WEAK || l == LK_COMMON);
}

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
