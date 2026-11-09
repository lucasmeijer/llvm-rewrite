// GlobalValue / GlobalVariable / Function helpers the IPO passes need, and the shared utilities they call.
// Ported from llvm/lib/IR/Globals.cpp (copyAttributesFrom, getAliaseeObject/findBaseObject, getComdat,
// setInitializer, isInterposable), llvm/include/llvm/IR/GlobalValue.h (linkage predicates, setLinkage,
// isImplicitDSOLocal), llvm/lib/IR/Function.cpp (deleteBody), llvm/lib/IR/Constants.cpp (destroyConstant),
// llvm/lib/IR/Module.cpp (collectUsedGlobalVariables, getGlobalVariable), llvm/lib/Transforms/Utils/CtorUtils.cpp
// (optimizeGlobalCtorsList) and llvm/lib/Transforms/Utils/GlobalStatus.cpp (isSafeToDestroyConstant, GlobalStatus).

// ---------------------------------------------------------------- linkage predicates (GlobalValue.h)

gv_is_weak_for_linker :: (g: Value_Id) -> bool {
    l := glob(g).linkage;
    return l == .WEAK_ANY || l == .WEAK_ODR || l == .LINKONCE_ANY || l == .LINKONCE_ODR || l == .COMMON || l == .EXTERN_WEAK;
}
linkage_is_interposable :: (l: Linkage) -> bool {
    return l == .WEAK_ANY || l == .LINKONCE_ANY || l == .COMMON || l == .EXTERN_WEAK;
}
// GlobalValue::mayBeDerefined / isDefinitionExact
gv_may_be_derefined :: (g: Value_Id) -> bool {
    l := glob(g).linkage;
    if l == .WEAK_ODR || l == .LINKONCE_ODR || l == .AVAILABLE_EXTERNALLY return true;
    // isInterposable() || isNobuiltinFnDef()
    if gv_is_interposable(g) return true;
    return vkind(g) == .FUNCTION && !is_declaration(g) && fn_has_fn_attr(g, .NoBuiltin);
}
// gv_is_definition_exact is in globals_aa.jai
// GlobalValue::isImplicitDSOLocal
gv_is_implicit_dso_local :: (g: Value_Id) -> bool {
    return gv_has_local_linkage(g) || (glob(g).visibility != 0 && glob(g).linkage != .EXTERN_WEAK);
}
// GlobalValue::setLinkage
gv_set_linkage :: (g: Value_Id, l: Linkage) {
    gr := glob(g);
    if l == .INTERNAL || l == .PRIVATE { gr.visibility = 0; gr.dll = 0; }
    gr.linkage = l;
    if gv_is_implicit_dso_local(g) gr.dso_local = true;
}
// GlobalValue::setVisibility
gv_set_visibility :: (g: Value_Id, v: u8) {
    glob(g).visibility = v;
    if gv_is_implicit_dso_local(g) glob(g).dso_local = true;
}
// GlobalValue::isDeclarationForLinker / isStrongDefinitionForLinker
gv_is_declaration_for_linker :: (g: Value_Id) -> bool {
    if glob(g).linkage == .AVAILABLE_EXTERNALLY return true;
    return is_declaration(g);
}
// gv_is_strong_definition_for_linker is in value_tracking.jai
// GlobalVariable::hasUniqueInitializer
gv_has_unique_initializer :: (g: Value_Id) -> bool {
    return gv_is_strong_definition_for_linker(g) && !glob(g).ext_init;
}
gv_has_global_unnamed_addr :: inline (g: Value_Id) -> bool { return glob(g).unnamed_addr == 2; }
gv_is_thread_local :: inline (g: Value_Id) -> bool { return glob(g).tls != 0; }

// GlobalValue::getAliaseeObject (findBaseObject)
gv_aliasee_object :: (c: Value_Id) -> Value_Id {
    seen: [..] Value_Id; seen.allocator = temp;
    find :: (c: Value_Id, seen: *[..] Value_Id) -> Value_Id {
        if c == NONE return NONE;
        k := vkind(c);
        if k == .GLOBAL_VAR || k == .FUNCTION || k == .IFUNC return c;
        if k == .ALIAS {
            for seen.* if it == c return NONE;
            array_add(seen, c);
            return find(op(c, 0), seen);
        }
        if k == .C_EXPR {
            o := cexpr(c).op;
            if o == .ADD {
                lhs := find(op(c, 0), seen);
                rhs := find(op(c, 1), seen);
                if lhs != NONE && rhs != NONE return NONE;
                return ifx lhs != NONE then lhs else rhs;
            }
            if o == .SUB {
                if find(op(c, 1), seen) != NONE return NONE;
                return find(op(c, 0), seen);
            }
            if o == .INTTOPTR || o == .PTRTOADDR || o == .PTRTOINT || o == .BITCAST || o == .ADDRSPACECAST || o == .GEP
                return find(op(c, 0), seen);
        }
        return NONE;
    }
    return find(c, *seen);
}
// GlobalValue::getComdat: an alias reports its aliasee object's comdat; -1 = none
gv_comdat :: (g: Value_Id) -> s32 {
    if vkind(g) == .ALIAS {
        o := gv_aliasee_object(g);
        if o == NONE return -1;
        return glob(o).comdat;
    }
    if vkind(g) == .IFUNC return -1;
    return glob(g).comdat;
}

// GlobalValue::copyAttributesFrom (+ GlobalObject: alignment, section; GlobalVariable: externally_initialized,
// attributes, code model)
gv_copy_attributes_from :: (dst: Value_Id, src: Value_Id) {
    d := glob(dst); s := glob(src);
    d.visibility = s.visibility;
    d.unnamed_addr = s.unnamed_addr;
    d.tls = s.tls;
    d.dll = s.dll;
    d.dso_local = s.dso_local;
    d.partition = s.partition;
    d.sanitizer = s.sanitizer;
    // GlobalObject::copyAttributesFrom
    d.align = s.align;
    d.section = s.section;
    if vkind(dst) == .GLOBAL_VAR && vkind(src) == .GLOBAL_VAR {
        d.ext_init = s.ext_init;
        d.attrs = s.attrs;
        d.code_model = s.code_model;
    }
}

// Value::takeName for globals: dst loses its own name, then takes src's
gv_take_name :: (dst: Value_Id, src: Value_Id) {
    if dst == src return;
    n := vname(src);
    if n.count == 0 { if vname(dst).count set_name(dst, ""); return; }
    if vname(dst).count set_name(dst, "");
    set_name(src, "");
    set_name(dst, n);
}

// GlobalVariable::setInitializer (NONE = drop it)
gv_set_initializer :: (g: Value_Id, c: Value_Id) {
    if c == NONE {
        if glob(g).has_init { set_op(g, 0, NONE); glob(g).has_init = false; }
        return;
    }
    set_op(g, 0, c);
    glob(g).has_init = true;
}

// new GlobalVariable(M, Ty, isConstant, Linkage, Init, Name, Before, TLMode, AddressSpace): inserted before `before`
// (NONE = at the end of the global list)
gv_create :: (ty: Type_Id, is_const: bool, linkage: Linkage, init: Value_Id, name: string, before: Value_Id, tls: u8, as: u32) -> Value_Id {
    gv := new_global(.GLOBAL_VAR, ty, as, 1);
    g := glob(gv);
    g.is_const = is_const;
    g.tls = tls;
    gv_set_linkage(gv, linkage);
    if init != NONE gv_set_initializer(gv, init);
    if before == NONE array_add(*ir.m_globals, gv);
    else {
        idx := -1;
        for ir.m_globals if it == before { idx = it_index; break; }
        assert(idx >= 0);
        array_insert_at(*ir.m_globals, gv, idx);
    }
    if name.count set_name(gv, name);
    return gv;
}
// A GlobalVariable that is not linked into the module (new GlobalVariable(Ty, ...) without M): no symbol table
gv_create_detached :: (ty: Type_Id, is_const: bool, linkage: Linkage, init: Value_Id, tls: u8, as: u32) -> Value_Id {
    gv := new_global(.GLOBAL_VAR, ty, as, 1);
    g := glob(gv);
    g.is_const = is_const;
    g.tls = tls;
    gv_set_linkage(gv, linkage);
    if init != NONE gv_set_initializer(gv, init);
    return gv;
}
// Module::insertGlobalVariable(Where, GV) for a detached global, then its name (setName after insertion)
gv_insert_before :: (gv: Value_Id, before: Value_Id, name: string) {
    if before == NONE array_add(*ir.m_globals, gv);
    else {
        idx := -1;
        for ir.m_globals if it == before { idx = it_index; break; }
        assert(idx >= 0);
        array_insert_at(*ir.m_globals, gv, idx);
    }
    if name.count set_name(gv, name);
}

// Function::deleteBody: drop the body, the prefix/prologue/personality operands (set to null) and all metadata;
// linkage becomes external
fn_delete_body :: (f: Value_Id) {
    fn_drop_all_references(f);
    g := glob(f);
    if g.has_prefix || g.has_prologue || g.has_personality {
        cpn := const_null_value(type_ptr(0));
        for k: 0..2 set_op(f, cast(u32) k, cpn);
    }
    g.has_prefix = false; g.has_prologue = false; g.has_personality = false;
    ir.v_md[f] = NONE;
    table_remove(*fam, f);
    gv_set_linkage(f, .EXTERNAL);
}

// GlobalValue::eraseFromParent for any global (a function's body is dropped first, metadata uses become null)
gv_erase_from_parent :: (g: Value_Id) {
    md_as_value_deleted(g, false);
    if vkind(g) == .FUNCTION { erase_function(g); return; }
    md_global_value_deleted(g);
    erase_global(g);
}
// ValueAsMetadata::handleDeletion / SalvageDebugInfo for MetadataAsValue owners: `metadata ptr @g` operands of calls
// become `metadata !{}` (deletion: canonicalizeMetadataForValue(nullptr)) or `metadata ptr poison` (salvage)
md_as_value_deleted :: (g: Value_Id, salvage: bool) {
    k := *md_key; key_reset(k); key_u8(k, 1); key_u32(k, g);
    found, m := table_find(*ir.md_map, key_view(k));
    if !found return;
    repl: Md_Id = NONE;
    for kind, v: ir.v_kind {
        if kind != .MD_VALUE || ir.v_aux[v] != m continue;
        if repl == NONE repl = ifx salvage then md_value(const_poison(vtype(g))) else md_tuple(.[], false);
        ir.v_aux[v] = repl;
    }
}

// Constant::destroyConstant: constant users are destroyed first (they must all be constants)
constant_destroy :: (c: Value_Id) {
    while ir.v_first_use[c] != NONE {
        usr := ir.u_user[ir.v_first_use[c]];
        assert(is_constant_kind(vkind(usr)) && !is_global_value(vkind(usr)), "destroying a constant with a non-constant user");
        constant_destroy(usr);
    }
    destroy_constant(c);
}

// isSafeToDestroyConstant (GlobalStatus.cpp): only used by constants (transitively)
is_safe_to_destroy_constant :: (c_in: Value_Id) -> bool {
    worklist: [..] Value_Id; worklist.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    array_add(*worklist, c_in);
    while worklist.count {
        c := pop(*worklist);
        if table_contains(*visited, c) continue;
        table_add(*visited, c, true);
        k := vkind(c);
        if is_global_value(k) return false;
        // ConstantData: no operands and not a ConstantExpr / aggregate / blockaddress-like
        if is_constant_data_kind(k) return false;
        u := ir.v_first_use[c];
        while u != NONE {
            usr := ir.u_user[u];
            if is_constant_kind(vkind(usr)) array_add(*worklist, usr);
            else return false;
            u = ir.u_next[u];
        }
    }
    return true;
}
// isa<ConstantData>
is_constant_data_kind :: (k: Value_Kind) -> bool {
    return k == .C_INT || k == .C_FP || k == .C_NULL || k == .C_ZERO || k == .C_TOKEN_NONE || k == .C_UNDEF ||
           k == .C_POISON || k == .C_DATA || k == .C_TARGET_NONE;
}

// Module::getGlobalVariable(Name, AllowLocal = false)
module_get_global_variable :: (name: string, allow_local := false) -> Value_Id {
    g := lookup_global(name);
    if g == NONE || vkind(g) != .GLOBAL_VAR return NONE;
    if !allow_local && gv_has_local_linkage(g) return NONE;
    return g;
}
// Module::getFunction(Name)
module_get_function :: (name: string) -> Value_Id {
    g := lookup_global(name);
    if g == NONE || vkind(g) != .FUNCTION return NONE;
    return g;
}

// collectUsedGlobalVariables (Module.cpp): the llvm.used / llvm.compiler.used variable and its elements
collect_used_global_variables :: (out: *[..] Value_Id, compiler_used: bool) -> Value_Id {
    gv := module_get_global_variable(ifx compiler_used then "llvm.compiler.used" else "llvm.used");
    if gv == NONE || !glob(gv).has_init return gv;
    init := gv_initializer(gv);
    if vkind(init) != .C_ARRAY fatal("llvm.used initializer that is not a ConstantArray is not supported");
    for k: 0..nops(init)-1 {
        e := strip_pointer_casts(op(init, k));
        assert(is_global_value(vkind(e)));
        array_add(out, e);
    }
    return gv;
}

// GlobalObject::hasMetadataOtherThanDebugLocAndGuid
gv_has_metadata_other_than_dbg_and_guid :: (g: Value_Id) -> bool {
    a := ir.v_md[g];
    while a != NONE {
        k := ir.attaches[a].kind;
        if k != MDK_DBG && k != MDK_UNIQUE_ID return true;
        a = ir.attaches[a].next;
    }
    return false;
}
MDK_UNIQUE_ID :: 51;   // "guid" (FixedMetadataKinds.def)

// GlobalVariable::getDebugInfo: every !dbg attachment (a DIGlobalVariableExpression)
gv_get_debug_info :: (g: Value_Id, out: *[..] Md_Id) {
    a := ir.v_md[g];
    while a != NONE {
        if ir.attaches[a].kind == MDK_DBG array_add(out, ir.attaches[a].md);
        a = ir.attaches[a].next;
    }
}
gv_add_debug_info :: (g: Value_Id, m: Md_Id) { add_metadata(g, MDK_DBG, m); }

// ---------------------------------------------------------------- CtorUtils.cpp

Ctor_Should_Remove_Kind :: enum u8 { EMPTY_FUNCTION; GLOBALOPT_EVALUATE; }

// findGlobalCtors
find_global_ctors :: () -> Value_Id {
    gv := module_get_global_variable("llvm.global_ctors");
    if gv == NONE return NONE;
    if !gv_has_unique_initializer(gv) return NONE;
    ca := gv_initializer(gv);
    if vkind(ca) != .C_ARRAY return NONE;
    for k: 0..nops(ca)-1 {
        v := op(ca, k);
        if vkind(v) == .C_ZERO continue;
        assert(vkind(v) == .C_STRUCT);
        fnv := op(v, 1);
        if vkind(fnv) == .C_NULL continue;
        if vkind(fnv) != .FUNCTION || glob(fnv).nargs != 0 return NONE;
    }
    return gv;
}

Ctor_Entry :: struct { priority: u32; f: Value_Id; }

// optimizeGlobalCtorsList: ShouldRemove is a kind switch (GlobalDCE: isEmptyFunction; GlobalOpt: evaluate)
optimize_global_ctors_list :: (kind: Ctor_Should_Remove_Kind, go: *Global_Opt = null) -> bool {
    gcl := find_global_ctors();
    if gcl == NONE return false;
    ca := gv_initializer(gcl);
    n := nops(ca);
    if n == 0 return false;
    ctors := NewArray(n, Ctor_Entry,, allocator = temp);
    for k: 0..n-1 {
        cs := op(ca, k);
        // parseGlobalCtors: cast<ConstantStruct>
        if vkind(cs) != .C_STRUCT fatal("llvm.global_ctors element that is not a ConstantStruct is not supported");
        ctors[k].priority = cast(u32) const_int_zext(op(cs, 0));
        f := op(cs, 1);
        ctors[k].f = ifx vkind(f) == .FUNCTION then f else NONE;
    }
    // stable sort of the indices by priority
    order := NewArray(n, u32,, allocator = temp);
    for k: 0..n-1 order[k] = k;
    for i: 1..cast(s64) n - 1 {
        x := order[i]; j := i - 1;
        while j >= 0 && ctors[order[j]].priority > ctors[x].priority { order[j + 1] = order[j]; j -= 1; }
        order[j + 1] = x;
    }
    to_remove := NewArray(n, bool,, allocator = temp);
    made_change := false;
    for idx: order {
        prio := ctors[idx].priority;
        f := ctors[idx].f;
        if f == NONE continue;
        should := false;
        if kind == {
            case .EMPTY_FUNCTION; should = gdce_is_empty_function(f);
            case .GLOBALOPT_EVALUATE; should = go_ctor_should_remove(go, prio, f);
        }
        if should {
            ctors[idx].f = NONE;
            to_remove[idx] = true;
            made_change = true;
        }
    }
    if !made_change return false;
    remove_global_ctors(gcl, to_remove);
    return true;
}

// removeGlobalCtors
remove_global_ctors :: (gcl: Value_Id, to_remove: [] bool) {
    old := gv_initializer(gcl);
    list: [..] Value_Id; list.allocator = temp;
    for k: 0..nops(old)-1 if !to_remove[k] array_add(*list, op(old, k));
    old_ty := vtype(old);
    aty := type_array(cast(u64) list.count, type_elem(old_ty));
    ca := const_aggregate(.C_ARRAY, aty, list);
    if vtype(ca) == old_ty { gv_set_initializer(gcl, ca); return; }
    ngv := gv_create_detached(vtype(ca), glob(gcl).is_const, glob(gcl).linkage, ca, glob(gcl).tls, glob(gcl).addrspace);
    gv_insert_before(ngv, gcl, "");
    gv_take_name(ngv, gcl);
    if has_uses(gcl) ipo_rauw(gcl, ngv);
    gv_erase_from_parent(gcl);
}

// ---------------------------------------------------------------- GlobalStatus.cpp

Gs_Stored :: enum u8 { NOT_STORED; INITIALIZER_STORED; STORED_ONCE; STORED; }
Global_Status :: struct {
    is_compared: bool;
    is_loaded: bool;
    num_stores: u32;
    stored_type: Gs_Stored;
    stored_once_store: Value_Id = NONE;
    accessing_function: Value_Id = NONE;
    has_multiple_accessing_functions: bool;
    ordering: u8;   // AtomicOrdering (0 = NotAtomic)
}
gs_stored_once_value :: (gs: *Global_Status) -> Value_Id {
    if gs.stored_type == .STORED_ONCE && gs.stored_once_store != NONE return op(gs.stored_once_store, 0);
    return NONE;
}
// strongerOrdering (AtomicOrdering: 0 NotAtomic, 1 Unordered, 2 Monotonic, 4 Acquire, 5 Release, 6 AcqRel, 7 SeqCst)
gs_stronger_ordering :: (x: u8, y: u8) -> u8 {
    if (x == 4 && y == 5) || (y == 4 && x == 5) return 6;
    return max(x, y);
}

// GlobalStatus::analyzeGlobal: true = the global's address escapes (give up)
analyze_global :: (v: Value_Id, gs: *Global_Status) -> bool {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    return analyze_global_aux(v, gs, *visited);
}
analyze_global_aux :: (v: Value_Id, gs: *Global_Status, visited: *Table(Value_Id, bool)) -> bool {
    if vkind(v) == .GLOBAL_VAR && glob(v).ext_init gs.stored_type = .STORED_ONCE;
    u := ir.v_first_use[v];
    while u != NONE {
        defer u = ir.u_next[u];
        ur := ir.u_user[u];
        k := vkind(ur);
        if k == .C_BLOCKADDR continue;   // not a user of its function in LLVM 23
        if is_constant_kind(k) {
            if k == .C_EXPR && is_ptr_type(vtype(ur)) {
                if analyze_global_aux(ur, gs, visited) return true;
            } else {
                if !is_safe_to_destroy_constant(ur) return true;
            }
        } else if k == .INST {
            if !gs.has_multiple_accessing_functions {
                f := inst_fn(ur);
                if gs.accessing_function == NONE gs.accessing_function = f;
                else if gs.accessing_function != f gs.has_multiple_accessing_functions = true;
            }
            o := inst_op(ur);
            if o == .LOAD {
                gs.is_loaded = true;
                if (inst(ur).flags & F_VOLATILE) != 0 return true;
                gs.ordering = gs_stronger_ordering(gs.ordering, inst(ur).ord1);
            } else if o == .STORE {
                if op(ur, 0) == v return true;
                if (inst(ur).flags & F_VOLATILE) != 0 return true;
                gs.num_stores += 1;
                gs.ordering = gs_stronger_ordering(gs.ordering, inst(ur).ord1);
                if gs.stored_type != .STORED {
                    ptr := strip_pointer_casts(op(ur, 1));
                    if vkind(ptr) == .GLOBAL_VAR {
                        sv := op(ur, 0);
                        if is_const(sv) && const_is_thread_dependent(sv) return true;
                        if glob(ptr).has_init && sv == gv_initializer(ptr) {
                            if gs.stored_type < .INITIALIZER_STORED gs.stored_type = .INITIALIZER_STORED;
                        } else if is_inst(sv) && inst_op(sv) == .LOAD && op(sv, 0) == ptr {
                            if gs.stored_type < .INITIALIZER_STORED gs.stored_type = .INITIALIZER_STORED;
                        } else if gs.stored_type < .STORED_ONCE {
                            gs.stored_type = .STORED_ONCE;
                            gs.stored_once_store = ur;
                        } else if gs.stored_type == .STORED_ONCE && gs_stored_once_value(gs) == sv {
                            // noop
                        } else {
                            gs.stored_type = .STORED;
                        }
                    } else {
                        gs.stored_type = .STORED;
                    }
                }
            } else if o == .GEP || o == .ADDRSPACECAST {
                if analyze_global_aux(ur, gs, visited) return true;
            } else if o == .SELECT || o == .PHI {
                if !table_contains(visited, ur) {
                    table_add(visited, ur, true);
                    if analyze_global_aux(ur, gs, visited) return true;
                }
            } else if o == .ICMP || o == .FCMP {
                gs.is_compared = true;
            } else if o == .CALL && is_mem_transfer_inst(ur) {
                if mi_is_volatile(ur) return true;
                if call_arg(ur, 0) == v gs.stored_type = .STORED;
                if call_arg(ur, 1) == v gs.is_loaded = true;
            } else if o == .CALL && is_mem_set_inst(ur) {
                if mi_is_volatile(ur) return true;
                gs.stored_type = .STORED;
            } else if o == .CALL || o == .INVOKE || o == .CALLBR {
                if call_iid(ur) == IID_THREADLOCAL_ADDRESS {
                    if analyze_global_aux(ur, gs, visited) return true;
                } else {
                    if opno_of(u) != nops(ur) - 1 return true;   // !CB->isCallee(&U)
                    gs.is_loaded = true;
                }
            } else {
                return true;
            }
        } else {
            return true;
        }
    }
    return false;
}

// Value::replaceAllUsesWith including the metadata half (ValueAsMetadata::handleRAUW): a constant replaced by a
// function-local value drops its metadata uses (ConstantAsMetadata -> null), everything else follows the value
ipo_rauw :: (old: Value_Id, new: Value_Id) {
    if is_constant_kind(vkind(old)) && !is_constant_kind(vkind(new)) {
        replace_all_uses_with(old, new);
        md_as_value_deleted(old, false);
        md_global_value_deleted(old);
        return;
    }
    rauw_with_metadata(old, new);
}
