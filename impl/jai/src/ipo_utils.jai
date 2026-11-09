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

// ---------------------------------------------------------------- function signature rewriting
// (Function::Create / copyAttributesFrom / splice, CallInst::Create / InvokeInst::Create with operand bundles)

// Function::Create(Ty, Linkage, AddrSpace) without a module and a name
ipo_fn_create :: (ft: Type_Id, linkage: Linkage, as: u32) -> Value_Id {
    nf := new_function(ft, "", as);
    gv_set_linkage(nf, linkage);
    return nf;
}
// Function::copyAttributesFrom
ipo_fn_copy_attributes_from :: (nf: Value_Id, f: Value_Id) {
    gv_copy_attributes_from(nf, f);
    d := glob(nf); s := glob(f);
    d.cc = s.cc;
    d.attrs = s.attrs;
    d.gc = s.gc;
    if s.has_personality { set_op(nf, 0, op(f, 0)); d.has_personality = true; }
    if s.has_prefix { set_op(nf, 1, op(f, 1)); d.has_prefix = true; }
    if s.has_prologue { set_op(nf, 2, op(f, 2)); d.has_prologue = true; }
}
// getFunctionList().insert(F->getIterator(), NF)
ipo_fn_insert_before :: (nf: Value_Id, f: Value_Id) {
    idx := -1;
    for ir.m_functions if it == f { idx = it_index; break; }
    assert(idx >= 0);
    array_insert_at(*ir.m_functions, nf, idx);
}
// NF->splice(NF->begin(), F): every block moves (with its instructions' names) to the new function's symbol table;
// the blocks are numbered anew in order (BasicBlock::setParent)
ipo_fn_splice_body :: (nf: Value_Id, f: Value_Id) {
    names: [..] string; names.allocator = temp;
    vals: [..] Value_Id; vals.allocator = temp;
    for b: fn_blocks(f) {
        if vname(b).count { array_add(*names, vname(b)); array_add(*vals, b); }
        for i: block_insts(b) if vname(i).count { array_add(*names, vname(i)); array_add(*vals, i); }
    }
    for vals set_name(it, "");
    g := glob(f); ng := glob(nf);
    assert(ng.first_block == NONE);
    ng.first_block = g.first_block; ng.last_block = g.last_block;
    g.first_block = NONE; g.last_block = NONE;
    for b: fn_blocks(nf) block(b).parent = nf;
    ng.next_block_num = -1;
    for vals set_name(it, names[it_index]);
    table_remove(*fam, f);
    table_remove(*fam, nf);
}
// the parameter attribute sets of a list, as an array
ipo_param_attrs :: (l: u32, n: u32) -> [..] u32 {
    out: [..] u32; out.allocator = temp;
    for k: 0..cast(s64) n - 1 array_add(*out, attr_list_param(l, cast(u32) k));
    return out;
}

// CallInst::Create(FTy, Callee, Args, CB's operand bundles, "", InsertBefore) / InvokeInst::Create(..., Normal,
// Unwind, ...): a fresh call (no flags, no attributes, no metadata) inserted before `before`, or at the end of
// `at_end` when before == NONE
ipo_create_call_like :: (cb: Value_Id, fty: Type_Id, callee: Value_Id, args: [] Value_Id, before: Value_Id, at_end: Value_Id = NONE) -> Value_Id {
    o := inst_op(cb);
    if o == .CALLBR fatal("IPO: rewriting a callbr call site is not supported yet");
    nb := call_num_bundles(cb);
    nbops: u32 = 0;
    for k: 0..cast(s64) nb - 1 { b, e := call_bundle_range(cb, cast(u32) k); nbops += e - b; }
    tail: u32 = ifx o == .INVOKE then cast(u32) 3 else 1;
    n := cast(u32) args.count + nbops + tail;
    i := new_inst(o, func_ret(fty), n);
    inst(i).ty2 = fty;
    k: u32 = 0;
    for args { set_op(i, k, it); k += 1; }
    if nb {
        r := inst(i);
        r.idx = cast(u32) ir.u32_pool.count; r.nidx = nb;
        for x: 0..cast(s64) nb - 1 {
            b, e := call_bundle_range(cb, cast(u32) x);
            tag := ir.u32_pool[inst(cb).idx + 3 * cast(u32) x];
            array_add(*ir.u32_pool, tag); array_add(*ir.u32_pool, k); array_add(*ir.u32_pool, k + (e - b));
            for y: b..e-1 { set_op(i, k, op(cb, y)); k += 1; }
        }
    }
    if o == .INVOKE {
        set_op(i, k, get_successor(cb, 0)); k += 1;
        set_op(i, k, get_successor(cb, 1)); k += 1;
    }
    set_op(i, k, callee);
    if before != NONE insert_at_position(i, inst_block(before), before, false);
    else block_append_inst(at_end, i);
    return i;
}
// copyMetadata(CB, {MD_prof, MD_dbg})
ipo_copy_prof_dbg :: (dst: Value_Id, src: Value_Id) {
    k := md_kind_id("prof");
    m := get_metadata(src, k);
    if m != NONE set_metadata(dst, k, m);
    d := get_metadata(src, MDK_DBG);
    if d != NONE set_metadata(dst, MDK_DBG, d);
}
// AttributeFuncs::updateMinLegalVectorWidthAttr
ipo_update_min_legal_vector_width_attr :: (f: Value_Id, width: u64) {
    a := fn_find_str_attr(f, "min-legal-vector-width");
    if !a return;
    old, ok := str_to_u64_auto(a.val);
    if width > old fn_add_fn_str_attr(f, "min-legal-vector-width", tprint("%", width));
}
// SP->replaceType(SP->getType()->cloneWithCC(DW_CC_nocall))
ipo_mark_subprogram_nocall :: (f: Value_Id) {
    sp := get_metadata(f, MDK_DBG);
    if sp == NONE || ir.mds[sp].kind != .SPECIAL || di_kind(sp) != .SUBPROGRAM return;
    ty := di_op(sp, 4);
    if ty == NONE fatal("IPO: DISubprogram without a type");
    r := ir.mds[ty];
    ops := NewArray(r.nops, Md_Id,, allocator = temp);
    for k: 0..cast(s64) r.nops - 1 ops[k] = md_op(ty, cast(u32) k);
    ints := NewArray(r.nints, u64,, allocator = temp);
    for k: 0..cast(s64) r.nints - 1 ints[k] = di_int(ty, cast(u32) k);
    ints[1] = 0x03;   // cc: DW_CC_nocall
    nt := di_get(.SUBROUTINE_TYPE, false, ops, ints);   // MDNode::replaceWithPermanent: uniqued
    if !ir.mds[sp].distinct fatal("IPO: replacing the type of a uniqued DISubprogram is not supported yet");
    ir.md_ops[ir.mds[sp].ops + 4] = nt;
}
