// Global-value helpers and the small module passes over globals. Ported from:
// - llvm/lib/Transforms/Utils/GlobalStatus.cpp (isSafeToDestroyConstant, GlobalStatus::analyzeGlobal)
// - llvm/lib/Transforms/Utils/CtorUtils.cpp (optimizeGlobalCtorsList, removeGlobalCtors)
// - llvm/lib/IR/Globals.cpp (setLinkage/isImplicitDSOLocal, getComdat, findBaseObject, copyAttributesFrom),
//   llvm/lib/IR/Function.cpp (deleteBody), llvm/lib/IR/Constants.cpp (destroyConstant), llvm/lib/IR/Module.cpp
//   (getGlobalVariable, collectUsedGlobalVariables)
// - llvm/lib/Transforms/IPO/StripDeadPrototypes.cpp, ElimAvailExtern.cpp, ConstantMerge.cpp, GlobalDCE.cpp
// - llvm/lib/Analysis/TypeMetadataUtils.cpp (getPointerAtOffset, replaceRelativePointerUsersWithZero)
// A blockaddress is not a user of its function in LLVM 23 (BlockAddress has no operands); here it has the
// function as operand 0, so every walk over a function's uses skips VK_BLOCKADDR users.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import intrinsics;
import datalayout;
import knownbits;
import memintr;
import dinfo;
import tli;
import sccp;
import ipoutil;
import inliner;
import parser;
import clone_function;
import autoupgrade;
import flags;
import wvh;
import scev;
import md5;
import globalopt;

fn ig_fail(what: const u8[:]) { fatal(str("IPO: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// GlobalValue predicates

fn ig_is_gv(v: i32) -> bool { let k = vals[v].kind; k == VK_FUNC || k == VK_ALIAS || k == VK_IFUNC || k == VK_GVAR }
// GlobalValue::isDeclaration
fn ig_is_declaration(v: i32) -> bool {
    let k = vals[v].kind;
    if k == VK_FUNC { return globs[glob_of(v)].first_block < 0; }
    if k == VK_GVAR { return nops(v) == 0 || op(v, 0) < 0; }
    return false;
}
fn ig_has_init(v: i32) -> bool { vals[v].kind == VK_GVAR && nops(v) > 0 && op(v, 0) >= 0 }
fn ig_init(v: i32) -> i32 { op(v, 0) }
// GlobalValue::isWeakForLinker
fn ig_is_weak_for_linker(v: i32) -> bool {
    let l = gv_linkage(v);
    return l == LK_WEAK_ANY || l == LK_WEAK_ODR || l == LK_LINKONCE_ANY || l == LK_LINKONCE_ODR || l == LK_COMMON || l == LK_EXTERN_WEAK;
}
// GlobalValue::isDeclarationForLinker
fn ig_is_declaration_for_linker(v: i32) -> bool { gv_linkage(v) == LK_AVAILABLE_EXTERNALLY || ig_is_declaration(v) }
// GlobalValue::isStrongDefinitionForLinker
fn ig_is_strong_definition_for_linker(v: i32) -> bool { !(ig_is_declaration_for_linker(v) || ig_is_weak_for_linker(v)) }
// GlobalVariable::hasUniqueInitializer
fn ig_has_unique_initializer(v: i32) -> bool {
    ig_has_init(v) && !ig_is_weak_for_linker(v) && gv_linkage(v) != LK_AVAILABLE_EXTERNALLY && globs[glob_of(v)].ext_init == 0
}
// GlobalVariable::hasDefinitiveInitializer
fn ig_has_definitive_initializer(v: i32) -> bool {
    ig_has_init(v) && !ig_is_declaration(v) && !gv_is_interposable(v, false) && globs[glob_of(v)].ext_init == 0
}
fn ig_has_global_unnamed_addr(v: i32) -> bool { globs[glob_of(v)].unnamed == 2 }
fn ig_has_atleast_local_unnamed_addr(v: i32) -> bool { globs[glob_of(v)].unnamed != 0 }
fn ig_is_thread_local(v: i32) -> bool { globs[glob_of(v)].tls != 0 }
fn ig_addrspace(v: i32) -> i64 { ptr_as(vals[v].ty) }
// GlobalValue::isImplicitDSOLocal
fn ig_is_implicit_dso_local(v: i32) -> bool {
    gv_has_local_linkage(v) || (globs[glob_of(v)].vis != 0 && gv_linkage(v) != LK_EXTERN_WEAK)
}
// GlobalValue::setLinkage
fn ig_set_linkage(v: i32, l: i64) {
    let g = glob_of(v);
    if l == LK_INTERNAL || l == LK_PRIVATE { globs[g].vis = 0; globs[g].dll = 0; }
    globs[g].linkage = l as u8;
    if ig_is_implicit_dso_local(v) { globs[g].dso_local = 1; }
}
// GlobalValue::setVisibility
fn ig_set_visibility(v: i32, vis: u8) {
    let g = glob_of(v);
    globs[g].vis = vis;
    if vis != 0 && gv_linkage(v) != LK_EXTERN_WEAK { globs[g].dso_local = 1; }
}
// Value::use_empty with LLVM 23's blockaddress (not a user)
fn ig_use_empty(v: i32) -> bool {
    var u = first_use(v);
    while u >= 0 { if vals[uses[u].user].kind != VK_BLOCKADDR { return false; } u = use_next(u); }
    return true;
}

// GlobalValue::getAliaseeObject (findBaseObject)
recursive fn ig_find_base_object(c: i32, seen: i32[>..<]&) -> i32 {
    if c < 0 { return -1; }
    let k = vals[c].kind;
    if k == VK_GVAR || k == VK_FUNC || k == VK_IFUNC { return c; }
    if k == VK_ALIAS {
        for x in seen { if x == c { return -1; } }
        seen.push(c);
        return ig_find_base_object(op(c, 0), seen);
    }
    if k == VK_CEXPR {
        let o = cexpr_op(c);
        if o == OP_ADD {
            let lhs = ig_find_base_object(op(c, 0), seen);
            let rhs = ig_find_base_object(op(c, 1), seen);
            if lhs >= 0 && rhs >= 0 { return -1; }
            return if lhs >= 0 { lhs } else { rhs };
        }
        if o == OP_SUB {
            if ig_find_base_object(op(c, 1), seen) >= 0 { return -1; }
            return ig_find_base_object(op(c, 0), seen);
        }
        if o == OP_INTTOPTR || o == OP_PTRTOINT || o == OP_PTRTOADDR || o == OP_BITCAST || o == OP_ADDRSPACECAST || o == OP_GEP {
            return ig_find_base_object(op(c, 0), seen);
        }
    }
    return -1;
}
fn ig_aliasee_object(v: i32) -> i32 {
    var seen: i32[>..<] = [];
    if vals[v].kind == VK_ALIAS { seen.push(v); return ig_find_base_object(op(v, 0), seen); }
    return ig_find_base_object(v, seen);
}
// GlobalValue::getComdat (an alias reports its aliasee object's; ifuncs have none); -1 = none
fn ig_comdat(v: i32) -> i32 {
    let k = vals[v].kind;
    if k == VK_ALIAS { let o = ig_aliasee_object(v); if o < 0 { return -1; } return globs[glob_of(o)].comdat; }
    if k == VK_IFUNC { return -1; }
    return globs[glob_of(v)].comdat;
}

// GlobalObject::hasMetadataOtherThanDebugLocAndGuid
fn ig_has_md_other_than_dbg_and_guid(v: i32) -> bool {
    let g = globs[glob_of(v)];
    let guid = md_kind_id("guid");
    for k in g.nmd { let kk = md_att[g.md + 2 * k]; if kk != 0 && kk != guid { return true; } }
    return false;
}
fn ig_get_md(v: i32, kind: i32) -> i32 {
    let g = globs[glob_of(v)];
    for k in g.nmd { if md_att[g.md + 2 * k] == kind { return md_att[g.md + 2 * k + 1]; } }
    return -1;
}

// Module::getGlobalVariable(Name, AllowLocal)
fn ig_module_gvar(m: i32, name: const u8[:], allow_local: bool) -> i32 {
    let v = symtab_lookup(modules[m].symtab, intern(name));
    if v < 0 || vals[v].kind != VK_GVAR { return -1; }
    if !allow_local && gv_has_local_linkage(v) { return -1; }
    return v;
}
fn ig_module_function(m: i32, name: const u8[:]) -> i32 {
    let v = symtab_lookup(modules[m].symtab, intern(name));
    if v < 0 || vals[v].kind != VK_FUNC { return -1; }
    return v;
}

// ---------------------------------------------------------------------------------------------
// Constants

// isSafeToDestroyConstant
fn ig_is_safe_to_destroy_constant(c0: i32) -> bool {
    var wl: i32[>..<] = [];
    var seen: i32[>..<] = [];
    wl.push(c0);
    while wl.len > 0 {
        let c = wl.pop();
        var dup = false;
        for x in seen { if x == c { dup = true; break; } }
        if dup { continue; }
        seen.push(c);
        if ig_is_gv(c) || is_constant_data(c) { return false; }
        var u = first_use(c);
        while u >= 0 {
            let us = uses[u].user;
            if is_constant(us) { wl.push(us); } else { return false; }
            u = use_next(u);
        }
    }
    return true;
}
// Constant::destroyConstant: constant users first (all must be constants), then this one
recursive fn ig_destroy_constant(c: i32) {
    while first_use(c) >= 0 {
        let us = uses[first_use(c)].user;
        if !is_constant(us) || ig_is_gv(us) { fatal("internal: destroying a constant with a non-constant user"); }
        ig_destroy_constant(us);
    }
    if is_constant_data(c) { return; }   // never destroyed (ConstantData lives forever)
    for m in mds { if m.kind == MK_VALUE && m.extra == c { ig_fail("destroying a constant used by metadata"); } }
    cst_remove(c);
    drop_all_refs(c);
    vals[c].kind = VK_DEAD;
}
// Constant::removeDeadConstantUsers
fn ig_remove_dead_constant_users(c: i32) { sc_remove_dead_constant_users(c); }

// Value::replaceAllUsesWith for a global or constant: value handles and debug-record tracking first (as
// Value::doRAUW), then every use; a constant user is re-uniqued (Constant::handleOperandChange). Metadata
// (ConstantAsMetadata) follows the value: ValueAsMetadata::handleRAUW.
fn ig_rauw(old: i32, nv: i32) {
    if vh_lvi_n > 0 { vh_lvi_events.push(old); }
    if wvh_live > 0 { wvh_value_rauwd(old, nv); }
    if sc_valid { scev_note_rauw(old, nv); }
    if old < val_vam.len && val_vam[old] >= 0 { vam_handle_rauw(old, nv); }
    ig_md_rauw(old, nv);
    rauw_with_constants(old, nv);
}
// ValueAsMetadata::handleRAUW for ConstantAsMetadata(old): constant -> constant moves every user to
// ConstantAsMetadata(new) (uniqued nodes re-uniqued); constant -> non-constant drops the metadata uses (null).
fn ig_md_rauw(old: i32, nv: i32) {
    if !is_constant(old) { return; }
    let vm = ig_find_vam(old);
    if vm < 0 { return; }
    var repl: i32 = -1;
    if is_constant(nv) { repl = md_value(nv); }
    // MetadataAsValue owners (call operands)
    for k in vals.len { if vals[k].kind == VK_MDVAL && vals[k].sub == vm { vals[k].sub = if repl >= 0 { repl } else { md_get(MK_TUPLE, -1, [], false) }; } }
    var changed = false;
    for k in mds.len {
        let n = mds[k];
        if n.kind as i64 != MK_TUPLE && n.kind as i64 != MK_DI { continue; }
        var hit = false;
        for q in n.nops as i64 { if md_ops[(n.ops as i64) + q] == vm { md_ops[(n.ops as i64) + q] = repl; hit = true; } }
        if hit {
            changed = true;
            if repl < 0 { mds[k].distinct = 1; }
        }
    }
    if changed { md_tab.clear(); md_merge_uniqued(); }
}
fn ig_find_vam(v: i32) -> i32 {
    if md_tab.len == 0 { md_rebuild_tab(); }
    let h = md_hash(MK_VALUE, v, []);
    let mask = md_tab.len - 1;
    var j = (h as i64) & mask;
    loop {
        let e = md_tab[j];
        if e < 0 { break; }
        if mds[e].kind as i64 == MK_VALUE && mds[e].extra == v && mds[e].nops == 0 { return e; }
        j = (j + 1) & mask;
    }
    return -1;
}
// ValueAsMetadata::handleDeletion (salvage = false: `metadata ptr @g` operands become `metadata !{}`) or
// ReplaceableMetadataImpl::SalvageDebugInfo first (salvage = true: they become `metadata ptr poison`); MDTuple
// operands are nulled (and the node made distinct) in both cases.
fn ig_md_value_deleted(v: i32, salvage: bool) {
    let vm = ig_find_vam(v);
    if vm < 0 { return; }
    var repl: i32 = -1;
    for k in vals.len {
        if vals[k].kind == VK_MDVAL && vals[k].sub == vm {
            if repl < 0 { repl = if salvage { md_value(c_poison(vals[v].ty)) } else { md_get(MK_TUPLE, -1, [], false) }; }
            vals[k].sub = repl;
        }
    }
    ipo_metadata_handle_deletion(v);
}

// ---------------------------------------------------------------------------------------------
// Creating, erasing and changing globals

// GlobalVariable::setInitializer (-1 = drop it)
fn ig_set_initializer(v: i32, c: i32) {
    if c < 0 {
        if nops(v) > 0 { set_op(v, 0, -1); vals[v].nops = 0; }
        globs[glob_of(v)].is_decl = 1;
        return;
    }
    if nops(v) == 0 {
        if vals[v].cap == 0 { let at = alloc_uses(v, 1); vals[v].ops = at; }
        vals[v].nops = 1;
        uses[vals[v].ops].val = -1;
    }
    set_op(v, 0, c);
    globs[glob_of(v)].is_decl = 0;
}
// new GlobalVariable(Ty, isConstant, Linkage, Init, "", TLMode, AddressSpace): not linked into a module yet
fn ig_new_gvar(m: i32, ty: i32, is_const: bool, linkage: i64, init: i32, tls: u8, as_: i64) -> i32 {
    let gv = new_glob(VK_GVAR, ty_ptr(as_), -1, 1);
    vals[gv].nops = 0;
    let g = glob_of(gv);
    globs[g].module = m;
    globs[g].vty = ty;
    globs[g].is_const = if is_const { 1 } else { 0 };
    globs[g].tls = tls;
    globs[g].addrspace = as_ as i32;
    ig_set_linkage(gv, linkage);
    if init >= 0 { ig_set_initializer(gv, init); }
    return gv;
}
// Module::insertGlobalVariable(Where, GV) (before = -1: at the end of the global list)
fn ig_insert_global_before(v: i32, before: i32) {
    if before < 0 { module_append_global(v); return; }
    let g = glob_of(v);
    let m = globs[g].module;
    let bg = glob_of(before);
    let p = globs[bg].prev;
    globs[g].prev = p;
    globs[g].next = before;
    globs[bg].prev = v;
    let k = vals[v].kind;
    if p >= 0 { globs[glob_of(p)].next = v; }
    else if k == VK_GVAR { modules[m].first_gvar = v; }
    else if k == VK_FUNC { modules[m].first_func = v; }
    else if k == VK_ALIAS { modules[m].first_alias = v; }
    else { modules[m].first_ifunc = v; }
}
// Value::takeName for globals
fn ig_take_name(dst: i32, src: i32) {
    if dst == src { return; }
    if vals[src].name < 0 { if vals[dst].name >= 0 { set_name(dst, ""); } return; }
    var buf: u8[>..] = [];
    buf.append(sbytes(vals[src].name));
    if vals[dst].name >= 0 { set_name(dst, ""); }
    set_name(src, "");
    set_name(dst, buf);
}
// GlobalValue::copyAttributesFrom + GlobalObject (alignment, section) + GlobalVariable (externally_initialized,
// attributes, code model) when both are variables
fn ig_copy_attributes_from(dst: i32, src: i32) {
    let d = glob_of(dst);
    let s = glob_of(src);
    globs[d].vis = globs[s].vis;
    globs[d].unnamed = globs[s].unnamed;
    globs[d].tls = globs[s].tls;
    globs[d].dll = globs[s].dll;
    globs[d].dso_local = globs[s].dso_local;
    globs[d].partition = globs[s].partition;
    globs[d].sanitizer = globs[s].sanitizer;
    globs[d].align = globs[s].align;
    globs[d].section = globs[s].section;
    if vals[dst].kind == VK_GVAR && vals[src].kind == VK_GVAR {
        globs[d].ext_init = globs[s].ext_init;
        globs[d].attrs = globs[s].attrs;
        globs[d].code_model = globs[s].code_model;
    }
}
// Function::deleteBody: the body goes, the hung-off operands become null, metadata is cleared, linkage external
fn ig_delete_body(f: i32) {
    func_drop_all_references(f);
    let g = glob_of(f);
    if nops(f) > 0 {
        let cpn = c_null(ty_ptr(0));
        for k in nops(f) { set_op(f, k, cpn); }
        globs[g].has_personality = 0;
        globs[g].has_prefix = 0;
        globs[g].has_prologue = 0;
    }
    globs[g].md = 0;
    globs[g].nmd = 0;
    globs[g].is_decl = 1;
    ig_set_linkage(f, LK_EXTERNAL);
}
// GlobalValue::eraseFromParent for a variable, alias or ifunc (functions: func_erase_from_parent); the
// metadata uses of the value are handled first (salvage: through deleteIfDead's SalvageDebugInfo)
fn ig_erase_global(v: i32, salvage: bool) {
    ig_md_value_deleted(v, salvage);
    if vals[v].kind == VK_FUNC { func_erase_from_parent(v); return; }
    sc_remove_dead_constant_users(v);
    if first_use(v) >= 0 { fatal("internal: erasing a global that still has uses"); }
    if v < val_vam.len && val_vam[v] >= 0 { vam_handle_deletion(v); }
    module_remove_global(v);
    let m = globs[glob_of(v)].module;
    if vals[v].name >= 0 { symtab_remove(modules[m].symtab, v); }
    drop_all_refs(v);
    val_set_dead(v);
}
// GlobalAlias::setAliasee / GlobalIFunc::setResolver (-1 = null operand)
fn ig_set_aliasee(v: i32, c: i32) { set_op(v, 0, c); }

// collectUsedGlobalVariables(M, Vec, CompilerUsed): the elements (stripped of pointer casts) and the variable
fn ig_collect_used(m: i32, compiler_used: bool, out: i32[>..<]&) -> i32 {
    let gv = ig_module_gvar(m, if compiler_used { "llvm.compiler.used" } else { "llvm.used" }, false);
    if gv < 0 || !ig_has_init(gv) { return gv; }
    let init = ig_init(gv);
    if vals[init].kind != VK_CARRAY { return gv; }
    for k in nops(init) { out.push(strip_pointer_casts(op(init, k))); }
    return gv;
}

// ---------------------------------------------------------------------------------------------
// GlobalStatus

let GS_NOT_STORED = 0;
let GS_INITIALIZER_STORED = 1;
let GS_STORED_ONCE = 2;
let GS_STORED = 3;
struct GStatus {
    is_compared: bool, is_loaded: bool, num_stores: i32, stored_type: i32, stored_once_store: i32,
    accessing_function: i32, multiple_accessing: bool, ordering: u8
}
var gs: GStatus = GStatus { is_compared: false, is_loaded: false, num_stores: 0, stored_type: 0, stored_once_store: -1,
    accessing_function: -1, multiple_accessing: false, ordering: 0 };
var gs_visited: i32[>..<];
fn gs_stored_once_value() -> i32 {
    if gs.stored_type == GS_STORED_ONCE && gs.stored_once_store >= 0 { return op(gs.stored_once_store, 0); }
    return -1;
}
// strongerOrdering (AtomicOrdering: 0 NotAtomic, 1 Unordered, 2 Monotonic, 4 Acquire, 5 Release, 6 AcqRel, 7 SeqCst)
fn gs_stronger(x: u8, y: u8) -> u8 {
    if (x == 4 && y == 5) || (x == 5 && y == 4) { return 6; }
    return if x > y { x } else { y };
}
// GlobalStatus::analyzeGlobal: true = the address escapes; the result is in `gs`
fn gs_analyze(v: i32) -> bool {
    gs = GStatus { is_compared: false, is_loaded: false, num_stores: 0, stored_type: 0, stored_once_store: -1,
        accessing_function: -1, multiple_accessing: false, ordering: 0 };
    gs_visited.clear();
    return gs_analyze_aux(v);
}
// Constant::isThreadDependent
fn gs_is_thread_dependent(c: i32) -> bool {
    var wl: i32[>..<] = [];
    var seen: i32[>..<] = [];
    wl.push(c);
    while wl.len > 0 {
        let d = wl.pop();
        if vals[d].kind == VK_GVAR && globs[glob_of(d)].tls != 0 { return true; }
        for k in nops(d) {
            let o = op(d, k);
            if o < 0 || !is_constant(o) || ig_is_gv(o) && vals[o].kind != VK_GVAR { continue; }
            var dup = false;
            for x in seen { if x == o { dup = true; break; } }
            if !dup { seen.push(o); if vals[o].kind == VK_GVAR { if globs[glob_of(o)].tls != 0 { return true; } } else { wl.push(o); } }
        }
    }
    return false;
}
recursive fn gs_analyze_aux(v: i32) -> bool {
    if vals[v].kind == VK_GVAR && globs[glob_of(v)].ext_init != 0 { gs.stored_type = GS_STORED_ONCE; }
    var u = first_use(v);
    while u >= 0 {
        let ur = uses[u].user;
        let nu = use_next(u);
        let k = vals[ur].kind;
        if k == VK_BLOCKADDR { u = nu; continue; }
        if is_constant(ur) {
            if k == VK_CEXPR && ty_kind(vals[ur].ty) == TK_PTR {
                if gs_analyze_aux(ur) { return true; }
            } else {
                if !ig_is_safe_to_destroy_constant(ur) { return true; }
            }
        } else if k == VK_INST {
            if !gs.multiple_accessing {
                let f = inst_func(ur);
                if gs.accessing_function < 0 { gs.accessing_function = f; }
                else if gs.accessing_function != f { gs.multiple_accessing = true; }
            }
            let o = iop(ur);
            if o == OP_LOAD {
                gs.is_loaded = true;
                if inst_is_volatile(ur) { return true; }
                gs.ordering = gs_stronger(gs.ordering, insts[inst_of(ur)].ord);
            } else if o == OP_STORE {
                if op(ur, 0) == v { return true; }
                if inst_is_volatile(ur) { return true; }
                gs.num_stores++;
                gs.ordering = gs_stronger(gs.ordering, insts[inst_of(ur)].ord);
                if gs.stored_type != GS_STORED {
                    let ptr = strip_pointer_casts(op(ur, 1));
                    if vals[ptr].kind == VK_GVAR {
                        let sv = op(ur, 0);
                        if is_constant(sv) && gs_is_thread_dependent(sv) { return true; }
                        if ig_has_init(ptr) && sv == ig_init(ptr) {
                            if gs.stored_type < GS_INITIALIZER_STORED { gs.stored_type = GS_INITIALIZER_STORED; }
                        } else if is_inst(sv) && iop(sv) == OP_LOAD && op(sv, 0) == ptr {
                            if gs.stored_type < GS_INITIALIZER_STORED { gs.stored_type = GS_INITIALIZER_STORED; }
                        } else if gs.stored_type < GS_STORED_ONCE {
                            gs.stored_type = GS_STORED_ONCE;
                            gs.stored_once_store = ur;
                        } else if gs.stored_type == GS_STORED_ONCE && gs_stored_once_value() == sv {
                        } else {
                            gs.stored_type = GS_STORED;
                        }
                    } else {
                        gs.stored_type = GS_STORED;
                    }
                }
            } else if o == OP_GEP || o == OP_ADDRSPACECAST {
                if gs_analyze_aux(ur) { return true; }
            } else if o == OP_SELECT || o == OP_PHI {
                var dup = false;
                for x in gs_visited { if x == ur { dup = true; break; } }
                if !dup {
                    gs_visited.push(ur);
                    if gs_analyze_aux(ur) { return true; }
                }
            } else if o == OP_ICMP || o == OP_FCMP {
                gs.is_compared = true;
            } else if o == OP_CALL && mi_is_mem_transfer(ur) {
                if inst_is_volatile(ur) { return true; }
                if cb_arg(ur, 0) == v { gs.stored_type = GS_STORED; }
                if cb_arg(ur, 1) == v { gs.is_loaded = true; }
            } else if o == OP_CALL && mi_is_memset(ur) {
                if inst_is_volatile(ur) { return true; }
                gs.stored_type = GS_STORED;
            } else if o == OP_CALL || o == OP_INVOKE || o == OP_CALLBR {
                if inst_iid(ur) == IID_threadlocal_address {
                    if gs_analyze_aux(ur) { return true; }
                } else {
                    // !CB->isCallee(&U)
                    if (u - vals[ur].ops) as i64 != nops(ur) - 1 { return true; }
                    gs.is_loaded = true;
                }
            } else {
                return true;
            }
        } else {
            return true;
        }
        u = nu;
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// CtorUtils

// findGlobalCtors
fn ig_find_global_ctors(m: i32) -> i32 {
    let gv = ig_module_gvar(m, "llvm.global_ctors", false);
    if gv < 0 { return -1; }
    if !ig_has_unique_initializer(gv) { return -1; }
    let ca = ig_init(gv);
    if vals[ca].kind != VK_CARRAY { return -1; }
    for k in nops(ca) {
        let v = op(ca, k);
        if vals[v].kind == VK_AGGZERO { continue; }
        if vals[v].kind != VK_CSTRUCT { ig_fail("llvm.global_ctors element that is not a ConstantStruct"); }
        let f = op(v, 1);
        if vals[f].kind == VK_CNULL { continue; }
        if vals[f].kind != VK_FUNC || func_nargs(f) != 0 { return -1; }
    }
    return gv;
}
// The ShouldRemove callback of optimizeGlobalCtorsList: 0 = GlobalDCE's isEmptyFunction, 1 = GlobalOpt's
// evaluation (globalopt.goose)
var ig_ctor_mode: i64 = 0;
var ig_ctor_entries_p: i64[>..<];
var ig_ctor_entries_f: i32[>..<];
fn ig_optimize_global_ctors_list(m: i32, mode: i64) -> bool {
    let gcl = ig_find_global_ctors(m);
    if gcl < 0 { return false; }
    let ca = ig_init(gcl);
    let n = nops(ca);
    if n == 0 { return false; }
    var prio: i64[>..<] = [];
    var fns: i32[>..<] = [];
    for k in n {
        let cs = op(ca, k);
        if vals[cs].kind != VK_CSTRUCT { ig_fail("llvm.global_ctors element that is not a ConstantStruct"); }
        prio.push(cint_lo(op(cs, 0)) as! i64);
        let f = op(cs, 1);
        fns.push(if vals[f].kind == VK_FUNC { f } else { -1 });
    }
    // stable sort of the indices by priority
    var order: i64[>..<] = [];
    for k in n { order.push(k); }
    var i: i64 = 1;
    while i < n {
        let x = order[i];
        var j = i - 1;
        while j >= 0 && prio[order[j]] > prio[x] { order[j + 1] = order[j]; j--; }
        order[j + 1] = x;
        i++;
    }
    var remove: bool[>..<] = [];
    for k in n { remove.push(false); }
    var changed = false;
    for idx in order {
        let f = fns[idx];
        if f < 0 { continue; }
        var should = false;
        if mode == 0 { should = gdce_is_empty_function(f); }
        else { should = go_ctor_should_remove(prio[idx], f); }
        if should {
            fns[idx] = -1;
            remove[idx] = true;
            changed = true;
        }
    }
    if !changed { return false; }
    ig_remove_global_ctors(gcl, remove);
    return true;
}
// removeGlobalCtors
fn ig_remove_global_ctors(gcl: i32, remove: bool[>..<]&) {
    let old = ig_init(gcl);
    var list: i32[>..<] = [];
    for k in nops(old) { if !remove[k] { list.push(op(old, k)); } }
    let oty: i32 = vals[old].ty;
    let aty = ty_array(ty_elem(oty), list.len);
    let ca = c_aggregate(aty, list);
    if vals[ca].ty == oty { ig_set_initializer(gcl, ca); return; }
    let g = glob_of(gcl);
    let ngv = ig_new_gvar(globs[g].module, aty, globs[g].is_const != 0, gv_linkage(gcl), ca, globs[g].tls, ptr_as(vals[gcl].ty));
    ig_insert_global_before(ngv, gcl);
    ig_take_name(ngv, gcl);
    if first_use(gcl) >= 0 { ig_rauw(gcl, ngv); }
    ig_erase_global(gcl, false);
}

// ---------------------------------------------------------------------------------------------
// StripDeadPrototypesPass

fn strip_dead_prototypes_run(m: i32) -> bool {
    var changed = false;
    var f = modules[m].first_func;
    while f >= 0 {
        let nf = globs[glob_of(f)].next;
        if ig_is_declaration(f) && ig_use_empty(f) {
            ig_erase_global(f, false);
            changed = true;
        }
        f = nf;
    }
    var gv = modules[m].first_gvar;
    while gv >= 0 {
        let ng = globs[glob_of(gv)].next;
        if ig_is_declaration(gv) && first_use(gv) < 0 { ig_erase_global(gv, false); }
        gv = ng;
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// EliminateAvailableExternallyPass

// getUniqueModuleId(M) ("" when the module exports nothing)
fn ig_unique_module_id(m: i32, out: u8[>..]&) {
    md5_init();
    var usfi: i32 = -1;
    for &nm in named_mds {
        if nm.module != m || sbytes(nm.name) != "llvm.module.flags" { continue; }
        for i in nm.nops {
            let e = md_ops[nm.ops + i];
            if e < 0 || mds[e].kind != MK_TUPLE || mds[e].nops < 3 { continue; }
            let kk = md_op(e, 1);
            if kk >= 0 && mds[kk].kind == MK_STRING && sbytes(mds[kk].extra) == "Unique Source File Identifier" { usfi = md_op(e, 2); }
        }
    }
    if usfi >= 0 && md_is_node(usfi) {
        md5_update(sbytes(mds[md_op(usfi, 0)].extra));
    } else {
        var exports = false;
        for pass in 4 {
            var g = if pass == 0 { modules[m].first_func } else if pass == 1 { modules[m].first_gvar } else if pass == 2 { modules[m].first_alias } else { modules[m].first_ifunc };
            while g >= 0 {
                let ng = globs[glob_of(g)].next;
                if ig_is_declaration(g) || starts_with(val_name(g), "llvm.") || gv_linkage(g) != LK_EXTERNAL || ig_comdat(g) >= 0 { g = ng; continue; }
                exports = true;
                md5_update(val_name(g));
                md5_update_byte(0);
                g = ng;
            }
        }
        if !exports { return; }
    }
    md5_final();
    out.push('.');
    md5_hex(out);
}

fn elim_avail_extern_run(m: i32) -> bool {
    if flag_bool("avail-extern-to-local", false) { ig_fail("elim-avail-extern -avail-extern-to-local"); }
    let conv_as = if flag_given("avail-extern-gv-in-addrspace-to-local") { flag_int("avail-extern-gv-in-addrspace-to-local", 0) } else { -1 };
    var changed = false;
    var gv = modules[m].first_gvar;
    while gv >= 0 {
        let ng = globs[glob_of(gv)].next;
        if gv_linkage(gv) == LK_AVAILABLE_EXTERNALLY && conv_as >= 0 && ig_addrspace(gv) == conv_as && first_use(gv) >= 0 {
            // convertToLocalCopy(M, GV)
            var nm: u8[>..] = [];
            nm.append(val_name(gv));
            nm.append(".__uniq");
            ig_unique_module_id(m, nm);
            set_name(gv, nm);
            ig_set_linkage(gv, LK_INTERNAL);
            changed = true;
            gv = ng;
            continue;
        }
        if gv_linkage(gv) == LK_AVAILABLE_EXTERNALLY {
            if ig_has_init(gv) {
                let init = ig_init(gv);
                ig_set_initializer(gv, -1);
                if ig_is_safe_to_destroy_constant(init) { ig_destroy_constant(init); }
            }
            sc_remove_dead_constant_users(gv);
            ig_set_linkage(gv, LK_EXTERNAL);
            changed = true;
        }
        gv = ng;
    }
    var f = modules[m].first_func;
    while f >= 0 {
        let nf = globs[glob_of(f)].next;
        if !ig_is_declaration(f) && gv_linkage(f) == LK_AVAILABLE_EXTERNALLY {
            ig_delete_body(f);
            sc_remove_dead_constant_users(f);
            changed = true;
        }
        f = nf;
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// ConstantMergePass

fn cm_is_better_canonical(a: i32, b: i32) -> bool {
    if !gv_has_local_linkage(a) && gv_has_local_linkage(b) { return true; }
    if gv_has_local_linkage(a) && !gv_has_local_linkage(b) { return false; }
    if ig_has_global_unnamed_addr(a) != ig_has_global_unnamed_addr(b) { return ig_has_global_unnamed_addr(a); }
    return globs[glob_of(a)].comdat < 0;
}
fn cm_get_align(v: i32) -> i64 {
    let a = globs[glob_of(v)].align;
    if a != 0 { return 1 << (a - 1); }
    return gv_preferred_align(v);
}
fn cm_is_unmergeable(v: i32, used: i32[>..<]&) -> bool {
    if globs[glob_of(v)].is_const == 0 || !ig_has_definitive_initializer(v) || ig_addrspace(v) != 0 ||
       globs[glob_of(v)].section >= 0 || ig_is_thread_local(v) { return true; }
    for x in used { if x == v { return true; } }
    return false;
}
fn cm_log2(a: i64) -> u8 { var k: u8 = 0; while (1 << k) < a { k++; } return k + 1; }

fn constmerge_run(m: i32) -> bool {
    var used: i32[>..<] = [];
    ig_collect_used(m, false, used);
    ig_collect_used(m, true, used);
    var changes: i64 = 0;
    var old_changes: i64 = 0;
    var rep_old: i32[>..<] = [];
    var rep_new: i32[>..<] = [];
    loop {
        // CMap: initializer -> canonical global, a scratch map over value ids
        vm_clear(VM_PASS0);
        var gv = modules[m].first_gvar;
        while gv >= 0 {
            let ng = globs[glob_of(gv)].next;
            sc_remove_dead_constant_users(gv);
            if first_use(gv) < 0 && gv_has_local_linkage(gv) {
                ig_erase_global(gv, false);
                changes++;
                gv = ng;
                continue;
            }
            if cm_is_unmergeable(gv, used) || ig_is_weak_for_linker(gv) || ig_has_md_other_than_dbg_and_guid(gv) { gv = ng; continue; }
            let init = ig_init(gv);
            let slot = vm_get(VM_PASS0, init, -1) as i32;
            if slot < 0 || cm_is_better_canonical(gv, slot) { vm_set(VM_PASS0, init, gv as i64); }
            gv = ng;
        }
        gv = modules[m].first_gvar;
        while gv >= 0 {
            let ng = globs[glob_of(gv)].next;
            if cm_is_unmergeable(gv, used) || !gv_has_local_linkage(gv) { gv = ng; continue; }
            let init = ig_init(gv);
            let slot = vm_get(VM_PASS0, init, -1) as i32;
            if slot < 0 || slot == gv { gv = ng; continue; }
            // makeMergeable(GV, Slot)
            if !ig_has_global_unnamed_addr(gv) && !ig_has_global_unnamed_addr(slot) { gv = ng; continue; }
            if ig_has_md_other_than_dbg_and_guid(gv) { gv = ng; continue; }
            if globs[glob_of(gv)].comdat != globs[glob_of(slot)].comdat && globs[glob_of(slot)].comdat >= 0 { gv = ng; continue; }
            if !ig_has_global_unnamed_addr(gv) { globs[glob_of(slot)].unnamed = 0; }
            rep_old.push(gv);
            rep_new.push(slot);
            gv = ng;
        }
        for k in rep_old.len {
            let old = rep_old[k];
            let nw = rep_new[k];
            // replace(M, Old, New)
            if globs[glob_of(old)].align != 0 || globs[glob_of(nw)].align != 0 {
                let a = max(cm_get_align(old), cm_get_align(nw));
                globs[glob_of(nw)].align = cm_log2(a);
            }
            let og = globs[glob_of(old)];
            for j in og.nmd { if md_att[og.md + 2 * j] == 0 { glob_add_md(nw, 0, md_att[og.md + 2 * j + 1]); } }
            ig_rauw(old, nw);
            ig_erase_global(old, false);
            changes++;
        }
        if changes == old_changes { break; }
        old_changes = changes;
        rep_old.clear();
        rep_new.clear();
    }
    return changes > 0;
}

// ---------------------------------------------------------------------------------------------
// GlobalDCEPass

// isEmptyFunction
fn gdce_is_empty_function(f: i32) -> bool {
    if ig_is_declaration(f) { return false; }
    var i = block_first(func_entry(f));
    while i >= 0 {
        if inst_is_debug_or_pseudo(i) { i = inst_next(i); continue; }
        if iop(i) == OP_RET { return nops(i) == 0; }
        break;
    }
    return false;
}

// Per-pass state: alive set (VS_PASS0), GVDependencies as edge lists, the constant-dependency cache as runs
var gd_alive_list: i32[>..<];
var gd_dep_head: i32[>..<];     // indexed by the dependency-source's position in gd_nodes
var gd_edges_to: i32[>..<];
var gd_edges_next: i32[>..<];
var gd_ccache_at: i32[>..<];    // constant cache: VM_PASS1 maps a constant to an index here
var gd_ccache_n: i32[>..<];
var gd_ccache_pool: i32[>..<];
var gd_tmp: i32[>..<];          // dependency collection stack
var gd_vfe_safe: i32[>..<];
var gd_typeid_md: i32[>..<];    // TypeIdMap: (typeid md, vtable, offset) triples in insertion order
var gd_typeid_gv: i32[>..<];
var gd_typeid_off: i64[>..<];
var gd_in_lto_post_link = false;

// node numbering of globals: VM_PASS0 value -> index into gd_dep_head
fn gd_node(v: i32) -> i64 {
    let n = vm_get(VM_PASS0, v, -1);
    if n >= 0 { return n; }
    let k = gd_dep_head.len;
    gd_dep_head.push(-1);
    vm_set(VM_PASS0, v, k);
    return k;
}
fn gd_add_dep(from: i32, to: i32) {
    let n = gd_node(from);
    var e = gd_dep_head[n];
    while e >= 0 { if gd_edges_to[e] == to { return; } e = gd_edges_next[e]; }
    gd_edges_to.push(to);
    gd_edges_next.push(gd_dep_head[n]);
    gd_dep_head[n] = (gd_edges_to.len - 1) as i32;
}
fn gd_tmp_add(base: i64, v: i32) {
    var k = base;
    while k < gd_tmp.len { if gd_tmp[k] == v { return; } k++; }
    gd_tmp.push(v);
}
// ComputeDependencies(V, Deps): Deps is gd_tmp[base..]
recursive fn gd_compute_deps(v: i32, base: i64) {
    let k = vals[v].kind;
    if k == VK_INST { gd_tmp_add(base, inst_func(v)); return; }
    if ig_is_gv(v) { gd_tmp_add(base, v); return; }
    if !is_constant(v) { return; }
    var ci = vm_get(VM_PASS1, v, -1);
    if ci < 0 {
        let lb = gd_tmp.len;
        var u = first_use(v);
        while u >= 0 { gd_compute_deps(uses[u].user, lb); u = use_next(u); }
        ci = gd_ccache_at.len;
        gd_ccache_at.push(gd_ccache_pool.len as i32);
        gd_ccache_n.push((gd_tmp.len - lb) as i32);
        var j = lb;
        while j < gd_tmp.len { gd_ccache_pool.push(gd_tmp[j]); j++; }
        gd_tmp.resize(lb);
        vm_set(VM_PASS1, v, ci);
    }
    let at = gd_ccache_at[ci] as i64;
    for j in gd_ccache_n[ci] as i64 { gd_tmp_add(base, gd_ccache_pool[at + j]); }
}
fn gd_update_deps(gv: i32) {
    let base = gd_tmp.len;
    var u = first_use(gv);
    while u >= 0 {
        let us = uses[u].user;
        if !(vals[gv].kind == VK_FUNC && vals[us].kind == VK_BLOCKADDR) { gd_compute_deps(us, base); }
        u = use_next(u);
    }
    var j = base;
    while j < gd_tmp.len {
        let d = gd_tmp[j];
        j++;
        if d == gv { continue; }
        if vals[gv].kind == VK_FUNC && position(gd_vfe_safe, d) >= 0 { continue; }
        gd_add_dep(d, gv);
    }
    gd_tmp.resize(base);
}
fn position(xs: i32[>..<]&, v: i32) -> i64 { for x, i in xs { if x == v { return i; } } return -1; }

// MarkLive(GV, Updates): comdat members become live too
fn gd_mark_live(gv: i32, wl: i32[>..<]&, m: i32) {
    if !vs_add(VS_PASS0, gv) { return; }
    wl.push(gv);
    gd_alive_list.push(gv);
    let c = ig_comdat(gv);
    if c >= 0 { gd_mark_comdat(c, wl, m); }
}
fn gd_mark_comdat(c: i32, wl: i32[>..<]&, m: i32) {
    // ComdatMembers: functions, variables and aliases whose own getComdat() is c
    var f = modules[m].first_func;
    while f >= 0 { if globs[glob_of(f)].comdat == c { gd_mark_live_nc(f, wl); } f = globs[glob_of(f)].next; }
    var g = modules[m].first_gvar;
    while g >= 0 { if globs[glob_of(g)].comdat == c { gd_mark_live_nc(g, wl); } g = globs[glob_of(g)].next; }
    var a = modules[m].first_alias;
    while a >= 0 { if ig_comdat(a) == c { gd_mark_live_nc(a, wl); } a = globs[glob_of(a)].next; }
}
fn gd_mark_live_nc(gv: i32, wl: i32[>..<]&) {
    if !vs_add(VS_PASS0, gv) { return; }
    wl.push(gv);
    gd_alive_list.push(gv);
}

// getPointerAtOffset(I, Offset, M, TopLevelGlobal); -1 = none
recursive fn gd_pointer_at_offset(c0: i32, off: u64, top: i32) -> i32 {
    var c = c0;
    if vals[c].kind == VK_DSOLOCAL { c = op(c, 0); }
    let t: i32 = vals[c].ty;
    if ty_kind(t) == TK_PTR { return if off == 0 { c } else { -1 }; }
    let k = vals[c].kind;
    if k == VK_CSTRUCT {
        let size = dl_alloc_size(t) as u64;
        let ssize = dl_struct_size(t) as u64;
        if off >= ssize { return -1; }
        // getElementContainingOffset
        var e: i64 = 0;
        let ne = ty_count(t);
        while e + 1 < ne && (dl_struct_offset(t, e + 1) as u64) <= off { e++; }
        return gd_pointer_at_offset(op(c, e), off - (dl_struct_offset(t, e) as u64), top);
    }
    if k == VK_CARRAY {
        let es = dl_alloc_size(ty_elem(t)) as u64;
        let o = off / es;
        if o >= (nops(c) as u64) { return -1; }
        return gd_pointer_at_offset(op(c, o as i64), off % es, top);
    }
    if k == VK_CINT { if off == 0 && cint_is_zero(c) { return c; } }
    if k == VK_CEXPR {
        let o = cexpr_op(c);
        if o == OP_TRUNC || o == OP_PTRTOINT { return gd_pointer_at_offset(op(c, 0), off, top); }
        if o == OP_SUB {
            var t1 = gd_pointer_at_offset(op(c, 1), 0, -1);
            if t1 >= 0 && vals[t1].kind == VK_CEXPR && cexpr_op(t1) == OP_GEP { t1 = op(t1, 0); }
            if t1 != top || t1 < 0 { return -1; }
            return gd_pointer_at_offset(op(c, 0), off, top);
        }
        return -1;
    }
    return -1;
}
fn gd_md_type_kind() -> i32 { md_kind_id("type") }

// ScanVTables
fn gd_scan_vtables(m: i32) {
    let tk = gd_md_type_kind();
    let vk = md_kind_id("vcall_visibility");
    var gv = modules[m].first_gvar;
    while gv >= 0 {
        let g = globs[glob_of(gv)];
        var any = false;
        for j in g.nmd { if md_att[g.md + 2 * j] == tk { any = true; } }
        if !ig_is_declaration(gv) && any {
            for j in g.nmd {
                if md_att[g.md + 2 * j] != tk { continue; }
                let t = md_att[g.md + 2 * j + 1];
                let tid = md_op(t, 1);
                let offm = md_op(t, 0);
                let off = cint_lo(mds[offm].extra);
                gd_typeid_md.push(tid);
                gd_typeid_gv.push(gv);
                gd_typeid_off.push(off as! i64);
            }
            // getVCallVisibility
            var vis: i64 = 0;
            for j in g.nmd {
                if md_att[g.md + 2 * j] != vk { continue; }
                let n = md_att[g.md + 2 * j + 1];
                let x = cint_lo(mds[md_op(n, 0)].extra) as! i64;
                if x > vis { vis = x; }
            }
            if vis == 2 || (gd_in_lto_post_link && vis == 1) { gd_vfe_safe.push(gv); }
        }
        gv = globs[glob_of(gv)].next;
    }
}
fn gd_vfe_erase(gv: i32) {
    let p = position(gd_vfe_safe, gv);
    if p < 0 { return; }
    var k = p;
    while k + 1 < gd_vfe_safe.len { gd_vfe_safe[k] = gd_vfe_safe[k + 1]; k++; }
    gd_vfe_safe.pop();
}
// ScanVTableLoad
fn gd_scan_vtable_load(caller: i32, tid: i32, call_off: u64) {
    for k in gd_typeid_md.len {
        if gd_typeid_md[k] != tid { continue; }
        let vt = gd_typeid_gv[k];
        let voff = gd_typeid_off[k] as! u64;
        let p = gd_pointer_at_offset(ig_init(vt), voff + call_off, vt);
        if p < 0 { gd_vfe_erase(vt); continue; }
        let callee = strip_pointer_casts(p);
        if vals[callee].kind != VK_FUNC { gd_vfe_erase(vt); continue; }
        gd_add_dep(caller, callee);
    }
}
fn gd_scan_type_checked_loads(m: i32) {
    for which in 2 {
        let f = ig_module_function(m, if which == 0 { "llvm.type.checked.load" } else { "llvm.type.checked.load.relative" });
        if f < 0 { continue; }
        var u = first_use(f);
        while u >= 0 {
            let ci = uses[u].user;
            u = use_next(u);
            if !is_inst(ci) || iop(ci) != OP_CALL { continue; }
            let offv = cb_arg(ci, 1);
            let tidv = cb_arg(ci, 2);
            let tid = vals[tidv].sub;
            if vals[offv].kind == VK_CINT {
                gd_scan_vtable_load(inst_func(ci), tid, cint_lo(offv));
            } else {
                for k in gd_typeid_md.len { if gd_typeid_md[k] == tid { gd_vfe_erase(gd_typeid_gv[k]); } }
            }
        }
    }
}
fn gd_add_virtual_function_dependencies(m: i32) {
    if !flag_bool("enable-vfe", true) { return; }
    // M.getModuleFlag("Virtual Function Elim") as a ConstantInt
    if tli_module_flag_int(m, "Virtual Function Elim") == 0 { return; }
    gd_scan_vtables(m);
    if gd_vfe_safe.len == 0 { return; }
    gd_scan_type_checked_loads(m);
}

// replaceRelativePointerUsersWithZero(C)
recursive fn gd_replace_relative_pointer_users_with_zero(c: i32) {
    var u = first_use(c);
    while u >= 0 {
        let us = uses[u].user;
        u = use_next(u);
        if vals[us].kind == VK_DSOLOCAL { gd_replace_relative_pointer_users_with_zero(us); continue; }
        if vals[us].kind != VK_CEXPR || cexpr_op(us) != OP_PTRTOINT { continue; }
        var w = first_use(us);
        while w >= 0 {
            let sub = uses[w].user;
            w = use_next(w);
            if vals[sub].kind != VK_CEXPR || cexpr_op(sub) != OP_SUB { break; }
            ig_rauw_non_metadata(sub, c_int(vals[sub].ty, 0));
        }
    }
}
// Value::replaceNonMetadataUsesWith
fn ig_rauw_non_metadata(old: i32, nv: i32) {
    if vh_lvi_n > 0 { vh_lvi_events.push(old); }
    if wvh_live > 0 { wvh_value_rauwd(old, nv); }
    if sc_valid { scev_note_rauw(old, nv); }
    rauw_with_constants(old, nv);
}

fn globaldce_run(m: i32) -> bool {
    var changed = false;
    changed = ig_optimize_global_ctors_list(m, 0) || changed;
    vs_clear(VS_PASS0);
    vm_clear(VM_PASS0);
    vm_clear(VM_PASS1);
    gd_alive_list.clear();
    gd_dep_head.clear();
    gd_edges_to.clear();
    gd_edges_next.clear();
    gd_ccache_at.clear();
    gd_ccache_n.clear();
    gd_ccache_pool.clear();
    gd_tmp.clear();
    gd_vfe_safe.clear();
    gd_typeid_md.clear();
    gd_typeid_gv.clear();
    gd_typeid_off.clear();
    gd_add_virtual_function_dependencies(m);
    var wl: i32[>..<] = [];
    // global_objects(): functions, then variables
    for pass in 2 {
        var go = if pass == 0 { modules[m].first_func } else { modules[m].first_gvar };
        while go >= 0 {
            sc_remove_dead_constant_users(go);
            if !ig_is_declaration(go) && !gv_is_discardable_if_unused(go) { gd_mark_live(go, wl, m); }
            gd_update_deps(go);
            go = globs[glob_of(go)].next;
        }
    }
    var ga = modules[m].first_alias;
    while ga >= 0 {
        sc_remove_dead_constant_users(ga);
        if !gv_is_discardable_if_unused(ga) { gd_mark_live(ga, wl, m); }
        gd_update_deps(ga);
        ga = globs[glob_of(ga)].next;
    }
    var gi = modules[m].first_ifunc;
    while gi >= 0 {
        sc_remove_dead_constant_users(gi);
        if !gv_is_discardable_if_unused(gi) { gd_mark_live(gi, wl, m); }
        gd_update_deps(gi);
        gi = globs[glob_of(gi)].next;
    }
    while wl.len > 0 {
        let l = wl.pop();
        let n = vm_get(VM_PASS0, l, -1);
        if n < 0 { continue; }
        var e = gd_dep_head[n];
        while e >= 0 { gd_mark_live(gd_edges_to[e], wl, m); e = gd_edges_next[e]; }
    }
    // dead variables: drop initializers
    var dead_vars: i32[>..<] = [];
    var gv = modules[m].first_gvar;
    while gv >= 0 {
        if !vs_has(VS_PASS0, gv) {
            dead_vars.push(gv);
            if ig_has_init(gv) {
                let init = ig_init(gv);
                ig_set_initializer(gv, -1);
                if ig_is_safe_to_destroy_constant(init) { ig_destroy_constant(init); }
            }
        }
        gv = globs[glob_of(gv)].next;
    }
    var dead_fns: i32[>..<] = [];
    var f = modules[m].first_func;
    while f >= 0 {
        if !vs_has(VS_PASS0, f) {
            dead_fns.push(f);
            if !ig_is_declaration(f) { ig_delete_body(f); }
        }
        f = globs[glob_of(f)].next;
    }
    var dead_aliases: i32[>..<] = [];
    ga = modules[m].first_alias;
    while ga >= 0 {
        if !vs_has(VS_PASS0, ga) { dead_aliases.push(ga); ig_set_aliasee(ga, -1); }
        ga = globs[glob_of(ga)].next;
    }
    var dead_ifuncs: i32[>..<] = [];
    gi = modules[m].first_ifunc;
    while gi >= 0 {
        if !vs_has(VS_PASS0, gi) { dead_ifuncs.push(gi); ig_set_aliasee(gi, -1); }
        gi = globs[glob_of(gi)].next;
    }
    for fd in dead_fns {
        if !ig_use_empty(fd) {
            gd_replace_relative_pointer_users_with_zero(fd);
            ig_rauw_non_metadata(fd, c_null(vals[fd].ty));
        }
        sc_remove_dead_constant_users(fd);
        ig_erase_global(fd, false);
        changed = true;
    }
    for x in dead_vars { sc_remove_dead_constant_users(x); ig_erase_global(x, false); changed = true; }
    for x in dead_aliases { sc_remove_dead_constant_users(x); ig_erase_global(x, false); changed = true; }
    for x in dead_ifuncs { sc_remove_dead_constant_users(x); ig_erase_global(x, false); changed = true; }
    return changed;
}

// GlobalValue::getGlobalIdentifier()
fn ig_global_identifier(v: i32, out: u8[>..]&) {
    var nm = val_name(v);
    if nm.len > 0 && nm[0] == 1 { nm = nm[1..]; }
    if gv_has_local_linkage(v) {
        let sf = modules[globs[glob_of(v)].module].source_filename;
        if sf < 0 || strs[sf].len == 0 { out.append("<unknown>"); } else { out.append(sbytes(sf)); }
        out.push(';');
    }
    out.append(nm);
}
// GlobalValue::assignGUID
fn ig_assign_guid(v: i32) {
    let k = md_kind_id("guid");
    if ig_get_md(v, k) >= 0 { return; }
    var id: u8[>..] = [];
    ig_global_identifier(v, id);
    let g = md5_hash_u64(id);
    let node = md_get(MK_TUPLE, -1, [md_value(c_int(T_I64, g as! i64))], false);
    glob_set_md(v, k, node);
}
// AssignGUIDPass::runOnModule
fn assign_guid_run(m: i32) {
    var gv = modules[m].first_gvar;
    while gv >= 0 { if !ig_is_declaration(gv) { ig_assign_guid(gv); } gv = globs[glob_of(gv)].next; }
    var f = modules[m].first_func;
    while f >= 0 { if !ig_is_declaration(f) { ig_assign_guid(f); } f = globs[glob_of(f)].next; }
}
