// llvm-link: link textual IR modules into one module.
// Ported from llvm/tools/llvm-link/llvm-link.cpp (main, linkFiles), llvm/lib/Linker/LinkModules.cpp (ModuleLinker:
// comdat resolution, linkage resolution, lazy linking), llvm/lib/Linker/IRMover.cpp (IRLinker, TypeMapTy,
// IdentifiedStructTypeSet, appending globals, named metadata, module flags) and the parts of
// llvm/lib/Transforms/Utils/ValueMapper.cpp that IRMover uses (Mapper with a TypeMapper and the IRLinker as
// materializer, two mapping contexts, MDNodeMapper with RF_ReuseAndMutateDistinctMDs, the global-value worklist).
//
// Design (DESIGN.md "llvm-link"): all modules live in the one world `ir` (one LLVMContext): types, constants,
// metadata and attributes are shared, as in LLVM. The module-level state (global lists, symbol table, comdats, named
// metadata, target strings) of the composite module is in `ir` while linking; the source module's is kept in a
// Module_State. Every global row records which module owns it (lk_owner). Function bodies are moved, not cloned:
// the new destination function takes the source function's arguments, blocks and local symbol table, and the
// mapper rewrites operands and types in place (like Function::stealArgumentListFrom + splice + remapFunction).
//
// Not supported (fails loudly): -override and -import, ARM/AArch64 module attributes (copyModuleAttrToFunctions),
// old two-field llvm.global_ctors, blockaddress of a function not linked yet (DelayedBBs), remapping intrinsics
// whose name mangles a renamed struct type, uniqued metadata cycles, #dbg_assign records.

Module_State :: struct {
    module_id:       string;
    source_filename: string;
    datalayout:      string;
    triple:          string;
    module_asm:      [..] string;
    module_asm_features: [..] string;
    module_asm_cpu:  [..] string;
    m_globals:       [..] Value_Id;
    m_functions:     [..] Value_Id;
    m_aliases:       [..] Value_Id;
    m_ifuncs:        [..] Value_Id;
    m_symtab:        Table(string, Value_Id);
    m_last_unique:   u32;
    comdats:         [..] Comdat_Row;
    comdat_map:      Table(string, s32);
    named_md:        [..] Named_Md;
}

lk_sw :: (a: *$T, b: *T) { t := a.*; a.* = b.*; b.* = t; }

// Exchange the module-level state in `ir` with s.
lk_swap_module :: (s: *Module_State) {
    lk_sw(*ir.module_id, *s.module_id);
    lk_sw(*ir.source_filename, *s.source_filename);
    lk_sw(*ir.datalayout, *s.datalayout);
    lk_sw(*ir.triple, *s.triple);
    lk_sw(*ir.module_asm, *s.module_asm);
    lk_sw(*ir.module_asm_features, *s.module_asm_features);
    lk_sw(*ir.module_asm_cpu, *s.module_asm_cpu);
    lk_sw(*ir.m_globals, *s.m_globals);
    lk_sw(*ir.m_functions, *s.m_functions);
    lk_sw(*ir.m_aliases, *s.m_aliases);
    lk_sw(*ir.m_ifuncs, *s.m_ifuncs);
    lk_sw(*ir.m_symtab, *s.m_symtab);
    lk_sw(*ir.m_last_unique, *s.m_last_unique);
    lk_sw(*ir.comdats, *s.comdats);
    lk_sw(*ir.comdat_map, *s.comdat_map);
    lk_sw(*ir.named_md, *s.named_md);
}

// ---------------------------------------------------------------- state

OWN_DST  : u8 : 0;   // the composite (also: everything created while linking)
OWN_SRC  : u8 : 1;   // the module being linked in
OWN_GONE : u8 : 2;   // a source module that has been linked already (destroyed in LLVM)

LINK_FROM_DST  : u8 : 0;
LINK_FROM_SRC  : u8 : 1;
LINK_FROM_BOTH : u8 : 2;

// Comdat::SelectionKind (Comdat_Row.kind)
SK_ANY : u8 : 0; SK_EXACT_MATCH : u8 : 1; SK_LARGEST : u8 : 2; SK_NO_DEDUPLICATE : u8 : 3; SK_SAME_SIZE : u8 : 4;

// Module::ModFlagBehavior
MFB_ERROR : u64 : 1; MFB_WARNING : u64 : 2; MFB_REQUIRE : u64 : 3; MFB_OVERRIDE : u64 : 4; MFB_APPEND : u64 : 5; MFB_APPEND_UNIQUE : u64 : 6;
MFB_MAX : u64 : 7; MFB_MIN : u64 : 8;

Lk_Work_Kind :: enum u8 { GLOBAL_INIT; APPENDING_VAR; ALIAS_OR_IFUNC; REMAP_FUNCTION; }
Lk_Work :: struct {
    kind:   Lk_Work_Kind;
    mcid:   u8;
    gv:     Value_Id;
    init:   Value_Id = NONE;   // initializer / aliasee / resolver
    old_gv: Value_Id = NONE;   // appending: the destination's previous variable
    num_new: u32;              // appending: how many members of lk.appending_inits are this entry's
}
Lk_Rauw :: struct { old: Value_Id; new: Value_Id; }
Lk_Comdat_Choice :: struct { kind: u8; from: u8; }

Lk :: struct {
    owner: [..] u8;   // by global row (ir.v_aux of a global value)

    // IRMover (lives across all input files)
    opaque_types: Table(Type_Id, bool);         // IdentifiedStructTypeSet::OpaqueStructTypes
    nonopaque:    Table(string, Type_Id);       // NonOpaqueStructTypes, keyed by (packed, element types)
    shared_mds:   Table(Md_Id, Md_Id);          // IRMover::SharedMDs (the main value map's MD map)
    nmd_inserted: Table(string, Table(Md_Id, bool));   // IRMover::NamedMDNodes, by destination node name

    // IRLinker (one per source module)
    src:        *Module_State;
    tm:         Table(Type_Id, Type_Id);         // TypeMapTy::MappedTypes
    vmap:       [2] Table(Value_Id, Value_Id);   // ValueMap, IndirectSymbolValueMap (mapping contexts 0 and 1)
    mdmap1:     Table(Md_Id, Md_Id);             // the MD map of IndirectSymbolValueMap
    to_link:    Table(Value_Id, bool);           // IRLinker::ValuesToLink
    worklist:   [..] Value_Id;
    rauw:       [..] Lk_Rauw;
    unmapped_md: [..] Value_Id;
    done_linking_bodies: bool;
    null_map_missing: bool;                      // RF_NullMapMissingGlobalValues
    mcid:       u8;
    work:       [..] Lk_Work;                    // Mapper::Worklist
    appending_inits: [..] Value_Id;
    distinct_worklist: [..] Md_Id;               // MDNodeMapper::DistinctWorklist
    md_in_progress: Table(Md_Id, bool);
    md_cycle_seen: bool;

    // ModuleLinker (one per source module)
    override_from_src: bool;
    only_needed: bool;
    internalize_cb: bool;
    ml_values: [..] Value_Id;                    // SetVector ValuesToLink
    ml_values_set: Table(Value_Id, bool);
    comdats_chosen: Table(s32, Lk_Comdat_Choice);   // by source comdat index
    lazy_comdat_members: Table(s32, [..] Value_Id);
    internalize_names: Table(string, bool);
}

lk: Lk;

lk_owner_of :: (v: Value_Id) -> u8 {
    row := ir.v_aux[v];
    if row >= lk.owner.count return OWN_DST;
    return lk.owner[row];
}
lk_set_owner :: (v: Value_Id, o: u8) {
    row := ir.v_aux[v];
    while lk.owner.count <= row array_add(*lk.owner, OWN_DST);
    lk.owner[row] = o;
}
lk_mark_module :: (s: *Module_State, o: u8) {
    for s.m_globals lk_set_owner(it, o);
    for s.m_functions lk_set_owner(it, o);
    for s.m_aliases lk_set_owner(it, o);
    for s.m_ifuncs lk_set_owner(it, o);
}

lk_fail :: (fmt: string, args: .. Any) {
    fatal(fmt, ..args);
}
lk_warn :: (s: string) {
    write_string(tprint("warning: %\n", s), to_standard_error = true);
}

// ---------------------------------------------------------------- linkage predicates

lk_linkage :: inline (g: Value_Id) -> Linkage { return glob(g).linkage; }
lk_is_local :: inline (g: Value_Id) -> bool { l := lk_linkage(g); return l == .INTERNAL || l == .PRIVATE; }
lk_is_appending :: inline (g: Value_Id) -> bool { return lk_linkage(g) == .APPENDING; }
lk_is_linkonce :: inline (g: Value_Id) -> bool { l := lk_linkage(g); return l == .LINKONCE_ANY || l == .LINKONCE_ODR; }
lk_is_weak :: inline (g: Value_Id) -> bool { l := lk_linkage(g); return l == .WEAK_ANY || l == .WEAK_ODR; }
lk_is_avail_ext :: inline (g: Value_Id) -> bool { return lk_linkage(g) == .AVAILABLE_EXTERNALLY; }
// GlobalValue::isDeclaration (aliases and ifuncs never are)
lk_is_declaration :: (g: Value_Id) -> bool { return is_declaration(g); }
lk_has_exact_definition :: (g: Value_Id) -> bool { return !lk_is_declaration(g) && !gv_may_be_derefined(g); }

// GlobalVariable::getGlobalSize
lk_global_size :: (g: Value_Id) -> u64 { return dl_type_alloc_size(glob(g).value_type); }

// Module::getNamedValue in the source module
lk_src_named_value :: (name: string) -> Value_Id {
    found, v := table_find(*lk.src.m_symtab, name);
    if found return v;
    return NONE;
}

// ---------------------------------------------------------------- IdentifiedStructTypeSet

lk_struct_key :: (elts: [] Type_Id, packed: bool) -> string {
    k := *type_key; key_reset(k);
    key_u8(k, ifx packed then cast(u8) 1 else 0);
    for elts key_u32(k, it);
    return key_view(k);
}
lk_type_elts :: (t: Type_Id) -> [] Type_Id {
    r: [] Type_Id;
    r.data = ir.type_list.data + ir.types[t].sub;
    r.count = ir.types[t].nsub;
    return r;
}
lk_is_packed :: inline (t: Type_Id) -> bool { return (ir.types[t].flags & TYF_PACKED) != 0; }
lk_is_opaque :: inline (t: Type_Id) -> bool { return type_kind(t) == .STRUCT && (ir.types[t].flags & TYF_OPAQUE) != 0; }
lk_is_literal :: inline (t: Type_Id) -> bool { return (ir.types[t].flags & TYF_LITERAL) != 0; }

lk_add_nonopaque :: (t: Type_Id) {
    key := lk_struct_key(lk_type_elts(t), lk_is_packed(t));
    if table_contains(*lk.nonopaque, key) return;   // DenseSet::insert keeps the first type with this body
    table_add(*lk.nonopaque, copy_string(key), t);
}
lk_add_opaque :: (t: Type_Id) { table_set(*lk.opaque_types, t, true); }
lk_find_nonopaque :: (elts: [] Type_Id, packed: bool) -> Type_Id {
    found, t := table_find(*lk.nonopaque, lk_struct_key(elts, packed));
    if found return t;
    return NONE;
}
lk_set_has_type :: (t: Type_Id) -> bool {
    if lk_is_opaque(t) return table_contains(*lk.opaque_types, t);
    found, x := table_find(*lk.nonopaque, lk_struct_key(lk_type_elts(t), lk_is_packed(t)));
    return found && x == t;
}

// ---------------------------------------------------------------- TypeMapTy

// recursivelyAddMappingIfTypesAreIsomorphic. As in LLVM 23 only identity mappings are recorded: the entry created by
// `MappedTypes[SrcTy]` stays null when the types are isomorphic (the final insert does not overwrite it), so a
// mapping found here only clears the source struct's name; TypeMapTy::get then maps it by body.
lk_tm_add_mapping :: (dst: Type_Id, src: Type_Id) -> bool {
    if type_kind(dst) != type_kind(src) return false;
    found, e := table_find(*lk.tm, src);
    if found && e != NONE return e == dst;
    if dst == src { table_set(*lk.tm, src, dst); return true; }
    if type_kind(src) == .STRUCT && (lk_is_opaque(src) || lk_is_opaque(dst)) return false;
    if type_nsub(src) != type_nsub(dst) return false;
    k := type_kind(dst);
    if k == .INT return false;
    if k == .PTR { if ir.types[dst].a != ir.types[src].a return false; }
    else if k == .FUNC { if func_vararg(dst) != func_vararg(src) return false; }
    else if k == .STRUCT { if lk_is_literal(dst) != lk_is_literal(src) || lk_is_packed(dst) != lk_is_packed(src) return false; }
    else if k == .ARRAY || k == .VECTOR || k == .SVECTOR { if type_count(dst) != type_count(src) return false; }
    n := type_nsub(src);
    if n > 0 for i: 0..n - 1 if !lk_tm_add_mapping(type_sub(dst, i), type_sub(src, i)) return false;
    if k == .STRUCT && ir.types[src].name.count ctx_set_struct_name(src, "");
    return true;
}

// TypeMapTy::get
lk_tm_get :: (t: Type_Id) -> Type_Id {
    if t == NONE return NONE;
    found, e := table_find(*lk.tm, t);
    if found && e != NONE return e;
    k := type_kind(t);
    is_uniqued := k != .STRUCT || lk_is_literal(t);
    n := type_nsub(t);
    if n == 0 && is_uniqued { table_set(*lk.tm, t, t); return t; }
    elts := NewArray(n, Type_Id,, allocator = temp);
    any_change := false;
    if n > 0 for i: 0..n - 1 {
        elts[i] = lk_tm_get(type_sub(t, i));
        if elts[i] != type_sub(t, i) any_change = true;
    }
    if !any_change && is_uniqued { table_set(*lk.tm, t, t); return t; }
    r: Type_Id = NONE;
    if k == {
        case .ARRAY; r = type_array(type_count(t), elts[0]);
        case .VECTOR; r = type_vector(type_count(t), elts[0], false);
        case .SVECTOR; r = type_vector(type_count(t), elts[0], true);
        case .FUNC;
            ps: [] Type_Id; ps.data = elts.data + 1; ps.count = elts.count - 1;
            r = type_func(elts[0], ps, func_vararg(t));
        case .STRUCT;
            packed := lk_is_packed(t);
            if is_uniqued { r = type_literal_struct(elts, packed); }
            else if lk_is_opaque(t) { lk_add_opaque(t); r = t; }
            else {
                old := lk_find_nonopaque(elts, packed);
                if old != NONE { ctx_set_struct_name(t, ""); r = old; }
                else if !any_change { lk_add_nonopaque(t); r = t; }
                else {
                    d := type_named_struct("");
                    set_struct_body(d, elts, packed);
                    if ir.types[t].name.count {
                        nm := ir.types[t].name;
                        ctx_set_struct_name(t, "");
                        ctx_set_struct_name(d, nm);
                    }
                    lk_add_nonopaque(d);
                    r = d;
                }
            }
        case;
            lk_fail("llvm-link: remapping the contained types of a % type is not supported", k);
    }
    table_set(*lk.tm, t, r);
    return r;
}

// IRLinker::mapAttributeTypes / the attribute half of Mapper::remapInstruction: in each attribute set the first
// type attribute (byval, byref, preallocated, inalloca, sret, elementtype) gets the mapped type.
lk_map_attr_types :: (l: u32) -> u32 {
    if l == 0 return 0;
    row := ir.attr_lists[l];
    map_set :: (s: u32) -> u32 {
        items := attr_set_items(s);
        for items {
            if it.kind > .LAST_ENUM && it.kind < .LAST_TYPE && it.ty != NONE {
                nt := lk_tm_get(it.ty);
                if nt == it.ty return s;
                all: [..] Attr; all.allocator = temp;
                for a: items array_add(*all, a);
                all[it_index].ty = nt;
                return attr_set_get(all);
            }
        }
        return s;
    }
    ret := map_set(row.ret);
    params := NewArray(row.params.count, u32,, allocator = temp);
    changed := ret != row.ret;
    for row.params { params[it_index] = map_set(it); if params[it_index] != it changed = true; }
    if !changed return l;
    return attr_list_get(row.fn, ret, params);
}

// ---------------------------------------------------------------- the value mapper (ValueMapper.cpp Mapper)

lk_vm :: inline () -> *Table(Value_Id, Value_Id) { return *lk.vmap[lk.mcid]; }
lk_mdm :: inline () -> *Table(Md_Id, Md_Id) { return ifx lk.mcid == 0 then *lk.shared_mds else *lk.mdmap1; }

// Mapper::mapValue
lk_map_value :: (v: Value_Id) -> Value_Id {
    if v == NONE return NONE;
    vm := lk_vm();
    found, m := table_find(vm, v);
    if found return m;
    nv := lk_materialize(v, lk.mcid == 1);
    if nv != NONE { table_set(lk_vm(), v, nv); return nv; }
    k := vkind(v);
    if is_global_value(k) {
        if lk.null_map_missing return NONE;
        table_set(vm, v, v);
        return v;
    }
    if k == .INLINE_ASM {
        // InlineAsm::get with the remapped function type
        fty := inline_asms[ir.v_aux[v]].fty;
        if lk_tm_get(fty) != fty lk_fail("llvm-link: remapping the type of inline asm is not supported yet");
        table_set(vm, v, v);
        return v;
    }
    if k == .MD_VALUE {
        md := cast(Md_Id) ir.v_aux[v];
        if md != NONE && ir.mds[md].kind == .VALUE && !is_constant_kind(vkind(ir.mds[md].value)) {
            // LocalAsMetadata: look through to the local value (moved, so unmapped: RF_IgnoreMissingLocals)
            lv := lk_map_value(ir.mds[md].value);
            if lv != NONE {
                if lv == ir.mds[md].value return v;
                return md_as_value(md_value(lv));
            }
            return NONE;
        }
        if md != NONE && is_di(md, .ARG_LIST) {
            mapped: [..] Md_Id; mapped.allocator = temp;
            n := ir.mds[md].nops;
            if n > 0 for i: 0..n - 1 {
                vam := md_op(md, i);
                val := ir.mds[vam].value;
                lv := lk_map_value(val);
                if lv != NONE array_add(*mapped, ifx lv == val then vam else md_value(lv));
                else if !is_constant_kind(vkind(val)) array_add(*mapped, vam);
                else array_add(*mapped, md_value(const_poison(vtype(val))));
            }
            return md_as_value(di_arg_list_get(mapped));
        }
        mm := lk_map_md(md);
        if mm == md { table_set(vm, v, v); return v; }
        r := md_as_value(mm);
        table_set(vm, v, r);
        return r;
    }
    if !is_constant_kind(k) return NONE;
    if k == .C_BLOCKADDR {
        f := lk_map_value(op(v, 0));
        if is_declaration(f) lk_fail("llvm-link: blockaddress of a function whose body is not linked yet is not supported");
        bb := lk_map_value(op(v, 1));
        r := const_blockaddr(f, ifx bb != NONE then bb else op(v, 1));
        table_set(lk_vm(), v, r);
        return r;
    }
    if k == .C_DSO_EQUIV || k == .C_NO_CFI {
        gv := lk_map_value(op(v, 0));
        if gv == NONE || !is_global_value(vkind(gv)) lk_fail("llvm-link: a dso_local_equivalent / no_cfi of a non-global is not supported yet");
        key := const_key_begin(k, vtype(gv)); key_u32(key, gv);
        r := const_lookup_or_create(key, k, vtype(gv), .[gv], 0);
        table_set(lk_vm(), v, r);
        return r;
    }
    n := nops(v);
    opno: u32 = 0;
    mapped: Value_Id = NONE;
    while opno < n {
        o := op(v, opno);
        mapped = lk_map_value(o);
        if mapped == NONE return NONE;
        if mapped != o break;
        opno += 1;
    }
    new_ty := lk_tm_get(vtype(v));
    if opno == n && new_ty == vtype(v) { table_set(lk_vm(), v, v); return v; }
    ops: [..] Value_Id; ops.allocator = temp;
    if opno > 0 for j: 0..opno - 1 array_add(*ops, op(v, j));
    if opno != n {
        array_add(*ops, mapped);
        opno += 1;
        while opno < n {
            mm := lk_map_value(op(v, opno));
            if mm == NONE return NONE;
            array_add(*ops, mm);
            opno += 1;
        }
    }
    r: Value_Id = NONE;
    if k == {
        case .C_EXPR;
            ce := cexpr(v);
            src_ty := ce.ty2;
            if ce.op == .GEP src_ty = lk_tm_get(ce.ty2);
            extra: [..] u32; extra.allocator = temp;
            if ce.nidx > 0 for j: 0..ce.nidx - 1 array_add(*extra, ir.u32_pool[ce.idx + j]);
            r = const_expr(ce.op, new_ty, ce.flags, src_ty, ops, extra);
        case .C_ARRAY; #through;
        case .C_STRUCT; #through;
        case .C_VECTOR;
            r = const_aggregate(k, new_ty, ops);
        case .C_POISON; r = const_poison(new_ty);
        case .C_UNDEF; r = const_undef(new_ty);
        case .C_ZERO; r = const_zero(new_ty);
        case .C_TARGET_NONE; r = const_null_value(new_ty);
        case .C_NULL; r = const_null(new_ty);
        case;
            lk_fail("llvm-link: remapping a constant of kind % is not supported yet", k);
    }
    table_set(lk_vm(), v, r);
    return r;
}

// Mapper::mapSimpleMetadata: (true, result) when no MDNodeMapper is needed
lk_map_simple_md :: (m: Md_Id) -> bool, Md_Id {
    found, x := table_find(lk_mdm(), m);
    if found return true, x;
    r := ir.mds[m];
    if r.kind == .STRING return true, m;
    if r.kind == .VALUE {
        // ConstantAsMetadata: not memoized
        cv := lk_map_value(r.value);
        if cv == r.value return true, m;
        if cv == NONE return true, NONE;
        return true, md_value(cv);
    }
    return false, NONE;
}

// Mapper::mapMetadata (MDNodeMapper::map). Distinct nodes are reused and their operands remapped in place
// (RF_ReuseAndMutateDistinctMDs); a uniqued node is re-uniqued when an operand changes.
lk_map_md :: (m: Md_Id) -> Md_Id {
    if m == NONE return NONE;
    ok, r := lk_map_simple_md(m);
    if ok return r;
    res := ifx ir.mds[m].distinct then lk_map_distinct(m) else lk_map_uniqued(m);
    while lk.distinct_worklist.count {
        d := pop(*lk.distinct_worklist);
        n := ir.mds[d].nops;
        if n > 0 for i: 0..n - 1 {
            old := ir.md_ops[ir.mds[d].ops + i];
            nw := lk_map_operand(old);
            if nw != old ir.md_ops[ir.mds[d].ops + i] = nw;
        }
    }
    return res;
}
lk_map_distinct :: (m: Md_Id) -> Md_Id {
    table_set(lk_mdm(), m, m);
    array_add(*lk.distinct_worklist, m);
    return m;
}
lk_map_operand :: (o: Md_Id) -> Md_Id {
    if o == NONE return NONE;
    ok, r := lk_map_simple_md(o);
    if ok return r;
    if ir.mds[o].distinct return lk_map_distinct(o);
    return lk_map_uniqued(o);
}
lk_map_uniqued :: (m: Md_Id) -> Md_Id {
    found, x := table_find(lk_mdm(), m);
    if found return x;
    // A uniqued cycle (only possible through forward references in textual IR) maps to itself unless something
    // in it changes; that case would need MDNodeMapper's placeholders and fails loudly.
    if table_contains(*lk.md_in_progress, m) { lk.md_cycle_seen = true; return m; }
    outer_cycle := lk.md_cycle_seen;
    lk.md_cycle_seen = false;
    defer lk.md_cycle_seen = lk.md_cycle_seen || outer_cycle;
    table_set(*lk.md_in_progress, m, true);
    r := ir.mds[m];
    n := r.nops;
    ops := NewArray(n, Md_Id,, allocator = temp);
    same := true;
    if n > 0 for i: 0..n - 1 {
        o := ir.md_ops[ir.mds[m].ops + i];
        ops[i] = lk_map_operand(o);
        if ops[i] != o same = false;
    }
    table_remove(*lk.md_in_progress, m);
    nm := m;
    if !same && lk.md_cycle_seen lk_fail("llvm-link: remapping a uniqued metadata cycle is not supported");
    if !same {
        rr := ir.mds[m];
        if rr.kind == .TUPLE nm = md_tuple(ops, false);
        else if rr.kind == .SPECIAL {
            ints := NewArray(rr.nints, u64,, allocator = temp);
            if rr.nints > 0 for i: 0..rr.nints - 1 ints[i] = ir.md_ints[rr.ints + i];
            nm = di_get(cast(DI_Kind) rr.sub, false, ops, ints);
        } else lk_fail("llvm-link: remapping metadata of kind % is not supported", rr.kind);
    }
    table_set(lk_mdm(), m, nm);
    return nm;
}

// Mapper::remapGlobalObjectMetadata
lk_remap_global_object_metadata :: (g: Value_Id) {
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(g, *all);
    ir.v_md[g] = NONE;
    for all add_metadata(g, it.kind, lk_map_md(it.md));
}

// Mapper::remapInstruction (RF_IgnoreMissingLocals: moved locals are left alone)
lk_remap_instruction :: (i: Value_Id) {
    n := nops(i);
    if n > 0 for k: 0..n - 1 {
        o := op(i, k);
        if o == NONE continue;
        v := lk_map_value(o);
        if v != NONE set_op(i, k, v);
    }
    if is_call_base(i) {
        ct := md_fixed("callee_type");
        if get_metadata(i, ct) != NONE && call_called_function(i) != NONE set_metadata(i, ct, NONE);
    }
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(i, *all);
    for all {
        nw := lk_map_md(it.md);
        if nw != it.md set_metadata(i, it.kind, nw);
    }
    r := inst(i);
    if is_call_base(i) {
        fty := r.ty2;
        np := func_nparams(fty);
        ps := NewArray(np, Type_Id,, allocator = temp);
        if np > 0 for k: 0..np - 1 ps[k] = lk_tm_get(func_param(fty, k));
        ret := lk_tm_get(vtype(i));
        inst(i).ty2 = type_func(ret, ps, func_vararg(fty));
        ir.v_type[i] = ret;
        inst(i).attrs = lk_map_attr_types(inst(i).attrs);
        return;
    }
    if r.op == .ALLOCA || r.op == .GEP inst(i).ty2 = lk_tm_get(r.ty2);
    ir.v_type[i] = lk_tm_get(vtype(i));
}

// Mapper::remapDbgRecord
lk_remap_dbg_record :: (x: u32) {
    if dbgr(x).dbg != NONE dbgr(x).dbg = lk_map_md(dbgr(x).dbg);
    if dbgr(x).kind == .LABEL {
        if dbgr(x).loc != NONE dbgr(x).loc = lk_map_md(dbgr(x).loc);
        return;
    }
    if dbgr(x).var != NONE dbgr(x).var = lk_map_md(dbgr(x).var);
    if dbgr(x).kind == .ASSIGN lk_fail("llvm-link: #dbg_assign records are not supported yet");
    vals: [..] Value_Id; vals.allocator = temp;
    dbgr_values_of_loc(dbgr(x).loc, *vals);
    new_vals: [..] Value_Id; new_vals.allocator = temp;
    for vals array_add(*new_vals, lk_map_value(it));
    for vals if new_vals[it_index] != NONE && new_vals[it_index] != it dbgr_replace_variable_location_op_idx(x, cast(u32) it_index, new_vals[it_index]);
}

// Mapper::remapFunction
lk_remap_function :: (f: Value_Id) {
    g := glob(f);
    if g.has_personality set_op(f, 0, lk_map_value(op(f, 0)));
    if g.has_prefix set_op(f, 1, lk_map_value(op(f, 1)));
    if g.has_prologue set_op(f, 2, lk_map_value(op(f, 2)));
    lk_remap_global_object_metadata(f);
    if glob(f).nargs > 0 for a: 0..glob(f).nargs - 1 {
        av := fn_arg(f, a);
        ir.v_type[av] = lk_tm_get(vtype(av));
    }
    for b: fn_blocks(f) for i: block_insts(b) {
        lk_remap_instruction(i);
        x := inst(i).records;
        while x != 0 {
            nx := dbgr(x).next;
            lk_remap_dbg_record(x);
            x = nx;
        }
    }
}

// Mapper::mapAppendingVariable
lk_map_appending_variable :: (gv: Value_Id, old_gv: Value_Id, new_members: [] Value_Id) {
    elements: [..] Value_Id; elements.allocator = temp;
    if old_gv != NONE && !is_declaration(old_gv) {
        init := op(old_gv, 0);
        n := type_count(vtype(init));
        if n > 0 for i: 0..n - 1 array_add(*elements, cf_elt(init, i));
        gv_set_initializer(old_gv, NONE);
    }
    for new_members array_add(*elements, lk_map_value(it));
    gv_set_initializer(gv, const_aggregate(.C_ARRAY, glob(gv).value_type, elements));
}

lk_schedule :: (w: Lk_Work) { array_add(*lk.work, w); }

// Mapper::flush
lk_flush :: () {
    while lk.work.count {
        e := pop(*lk.work);
        lk.mcid = e.mcid;
        if e.kind == {
            case .GLOBAL_INIT;
                gv_set_initializer(e.gv, lk_map_value(e.init));
                lk_remap_global_object_metadata(e.gv);
            case .APPENDING_VAR;
                prefix := lk.appending_inits.count - e.num_new;
                news := NewArray(e.num_new, Value_Id,, allocator = temp);
                for k: 0..cast(s64) e.num_new - 1 news[k] = lk.appending_inits[prefix + k];
                lk.appending_inits.count = prefix;
                lk_map_appending_variable(e.gv, e.old_gv, news);
            case .ALIAS_OR_IFUNC;
                set_op(e.gv, 0, lk_map_value(e.init));
            case .REMAP_FUNCTION;
                lk_remap_function(e.gv);
        }
    }
    lk.mcid = 0;
}

// ValueMapper::mapValue / mapMDNode (FlushingMapper: the worklist is flushed after the top-level call)
lk_map_value_flushing :: (v: Value_Id) -> Value_Id { r := lk_map_value(v); lk_flush(); return r; }
lk_map_md_flushing :: (m: Md_Id) -> Md_Id { r := lk_map_md(m); lk_flush(); return r; }

// ---------------------------------------------------------------- IRLinker

// IRLinker::getLinkedToGlobal
lk_linked_to_global :: (sgv: Value_Id) -> Value_Id {
    if vname(sgv).count == 0 || lk_is_local(sgv) return NONE;
    dgv := lookup_global(vname(sgv));
    if dgv == NONE || lk_is_local(dgv) return NONE;
    if vkind(dgv) == .FUNCTION && glob(dgv).intrinsic && vkind(sgv) == .FUNCTION {
        if glob(dgv).value_type != lk_tm_get(glob(sgv).value_type) return NONE;
    }
    return dgv;
}

// The IRLinker's half of IRLinker::maybeAdd
lk_maybe_add :: (gv: Value_Id) {
    if table_contains(*lk.to_link, gv) return;
    table_set(*lk.to_link, gv, true);
    array_add(*lk.worklist, gv);
}

// IRLinker::shouldLink
lk_should_link :: (dgv: Value_Id, sgv: Value_Id) -> bool {
    if table_contains(*lk.to_link, sgv) || lk_is_local(sgv) return true;
    if dgv != NONE && !gv_is_declaration_for_linker(dgv) return false;
    if lk_is_declaration(sgv) || lk.done_linking_bodies return false;
    return ml_add_lazy_for(sgv);
}

// The LLVM SymbolTable class autorenames globals that conflict in the symbol table; force the name back.
lk_force_renaming :: (gv: Value_Id, name: string) {
    if lk_is_local(gv) || vname(gv) == name return;
    conflict := lookup_global(name);
    if conflict != NONE {
        gv_take_name(gv, conflict);
        set_name(conflict, name);
    } else set_name(gv, name);
}

// GlobalObject::copyMetadata(Other, 0)
lk_copy_metadata :: (dst: Value_Id, src: Value_Id) {
    a := ir.v_md[src];
    while a != NONE {
        add_metadata(dst, ir.attaches[a].kind, ir.attaches[a].md);
        a = ir.attaches[a].next;
    }
}

lk_new_function :: (fty: Type_Id, as: u32, name: string) -> Value_Id {
    f := new_function(fty, name, as);
    array_add(*ir.m_functions, f);
    lk_set_owner(f, OWN_DST);
    return f;
}
lk_new_gvar :: (ty: Type_Id, is_const: bool, linkage: Linkage, name: string, before: Value_Id, tls: u8, as: u32) -> Value_Id {
    gv := gv_create(ty, is_const, linkage, NONE, name, before, tls, as);
    lk_set_owner(gv, OWN_DST);
    return gv;
}

// IRLinker::copyGlobalVariableProto
lk_copy_gvar_proto :: (s: Value_Id) -> Value_Id {
    g := glob(s);
    d := lk_new_gvar(lk_tm_get(g.value_type), g.is_const, .EXTERNAL, vname(s), NONE, g.tls, g.addrspace);
    glob(d).align = g.align;
    gv_copy_attributes_from(d, s);
    return d;
}
// IRLinker::copyFunctionProto
lk_copy_fn_proto :: (s: Value_Id) -> Value_Id {
    g := glob(s);
    f := lk_new_function(lk_tm_get(g.value_type), g.addrspace, vname(s));
    gv_set_linkage(f, .EXTERNAL);
    ipo_fn_copy_attributes_from(f, s);
    glob(f).attrs = lk_map_attr_types(glob(f).attrs);
    return f;
}
// IRLinker::copyIndirectSymbolProto
lk_copy_indirect_proto :: (s: Value_Id) -> Value_Id {
    g := glob(s);
    k := vkind(s);
    d := new_global(k, lk_tm_get(g.value_type), g.addrspace, 1);
    gv_set_linkage(d, .EXTERNAL);
    if vname(s).count set_name(d, vname(s));
    if k == .ALIAS array_add(*ir.m_aliases, d); else array_add(*ir.m_ifuncs, d);
    lk_set_owner(d, OWN_DST);
    gv_copy_attributes_from(d, s);
    return d;
}

// IRLinker::copyGlobalValueProto
lk_copy_global_value_proto :: (s: Value_Id, for_definition: bool) -> Value_Id {
    k := vkind(s);
    nv: Value_Id;
    if k == .GLOBAL_VAR nv = lk_copy_gvar_proto(s);
    else if k == .FUNCTION nv = lk_copy_fn_proto(s);
    else if for_definition nv = lk_copy_indirect_proto(s);
    else {
        g := glob(s);
        vt := lk_tm_get(g.value_type);
        if type_kind(vt) == .FUNC {
            nv = lk_new_function(vt, g.addrspace, vname(s));
            gv_set_linkage(nv, .EXTERNAL);
        } else nv = lk_new_gvar(vt, false, .EXTERNAL, vname(s), NONE, g.tls, g.addrspace);
    }
    if for_definition gv_set_linkage(nv, lk_linkage(s));
    else if lk_linkage(s) == .EXTERN_WEAK gv_set_linkage(nv, .EXTERN_WEAK);
    nk := vkind(nv);
    if nk == .GLOBAL_VAR || nk == .FUNCTION {
        if k == .GLOBAL_VAR || lk_is_declaration(s) {
            lk_copy_metadata(nv, s);
            if lk_is_declaration(s) && ir.v_md[nv] != NONE array_add(*lk.unmapped_md, nv);
        }
    }
    if nk == .FUNCTION {
        g := glob(nv);
        if g.has_personality || g.has_prefix || g.has_prologue for x: 0..2 set_op(nv, cast(u32) x, NONE);
        g.has_personality = false; g.has_prefix = false; g.has_prologue = false;
    }
    return nv;
}

// Module::getOrInsertComdat in the destination
lk_dst_comdat :: (name: string) -> s32 {
    found, c := table_find(*ir.comdat_map, name);
    if found return c;
    row: Comdat_Row; row.name = intern_str(name);
    c = cast(s32) ir.comdats.count;
    array_add(*ir.comdats, row);
    table_add(*ir.comdat_map, row.name, c);
    return c;
}

// IRLinker::linkGlobalValueProto
lk_link_global_value_proto :: (sgv: Value_Id, for_indirect: bool) -> Value_Id {
    dgv := lk_linked_to_global(sgv);
    should := lk_should_link(dgv, sgv);
    if should {
        found, x := table_find(*lk.vmap[0], sgv);
        if found return x;
        found2, y := table_find(*lk.vmap[1], sgv);
        if found2 return y;
    }
    if !should && for_indirect dgv = NONE;
    if lk_is_appending(sgv) || (dgv != NONE && lk_is_appending(dgv)) return lk_link_appending_var_proto(dgv, sgv);
    needs_renaming := false;
    nv: Value_Id;
    if dgv != NONE && !should {
        nv = dgv;
        if vkind(sgv) == .FUNCTION && lk_is_declaration(dgv) && lk_has_exact_definition(sgv) && !lk.done_linking_bodies {
            nv = lk_copy_global_value_proto(sgv, false);
            needs_renaming = true;
        }
    } else {
        if lk.done_linking_bodies return NONE;
        nv = lk_copy_global_value_proto(sgv, should || for_indirect);
        if should || !for_indirect needs_renaming = true;
    }
    // Intrinsic::remangleIntrinsicFunction: only needed when the mangled name contains a renamed struct type
    if vkind(nv) == .FUNCTION && glob(nv).intrinsic lk_check_intrinsic_mangling(nv);
    if needs_renaming lk_force_renaming(nv, vname(sgv));
    if should || for_indirect {
        sc := gv_comdat(sgv);
        if sc >= 0 && (vkind(nv) == .GLOBAL_VAR || vkind(nv) == .FUNCTION) {
            row := lk.src.comdats[sc];
            dc := lk_dst_comdat(row.name);
            ir.comdats[dc].kind = row.kind;
            glob(nv).comdat = dc;
        }
    }
    if !should && for_indirect gv_set_linkage(nv, .INTERNAL);
    c := nv;
    if dgv != NONE && nv != sgv c = lk_pointer_cast(nv, lk_tm_get(vtype(sgv)));
    if dgv != NONE && nv != dgv array_add(*lk.rauw, .{dgv, lk_pointer_cast(nv, vtype(dgv))});
    return c;
}

// ConstantExpr::getPointerBitCastOrAddrSpaceCast
lk_pointer_cast :: (v: Value_Id, ty: Type_Id) -> Value_Id {
    if vtype(v) == ty return v;
    if ir.types[vtype(v)].a != ir.types[ty].a return const_expr(.ADDRSPACECAST, ty, 0, NONE, .[v]);
    return const_expr(.BITCAST, ty, 0, NONE, .[v]);
}

lk_check_intrinsic_mangling :: (f: Value_Id) {
    ft := glob(f).value_type;
    has_struct :: (t: Type_Id) -> bool {
        if type_kind(t) == .STRUCT && !lk_is_literal(t) return true;
        n := type_nsub(t);
        if n > 0 for i: 0..n - 1 if has_struct(type_sub(t, i)) return true;
        return false;
    }
    if has_struct(ft) lk_fail("llvm-link: remangling the intrinsic '%' (struct types in its signature) is not supported yet", vname(f));
}

// IRLinker::linkAppendingVarProto
lk_link_appending_var_proto :: (dst_gv: Value_Id, src_gv: Value_Id) -> Value_Id {
    name := vname(src_gv);
    if dst_gv != NONE && !lk_is_declaration(dst_gv) && !lk_is_declaration(src_gv) {
        d := glob(dst_gv); s := glob(src_gv);
        if !lk_is_appending(src_gv) || !lk_is_appending(dst_gv)
            lk_fail("Linking globals named '%': can only link appending global with another appending global!", name);
        if d.is_const != s.is_const lk_fail("Appending variables linked with different const'ness!");
        if d.align != s.align lk_fail("Appending variables with different alignment need to be linked!");
        if d.visibility != s.visibility lk_fail("Appending variables with different visibility need to be linked!");
        if (d.unnamed_addr == 2) != (s.unnamed_addr == 2) lk_fail("Appending variables with different unnamed_addr need to be linked!");
        if d.section != s.section lk_fail("Appending variables with different section name need to be linked!");
        if d.addrspace != s.addrspace lk_fail("Appending variables with different address spaces need to be linked!");
    }
    if lk_is_declaration(src_gv) return dst_gv;
    elt_ty := type_elem(lk_tm_get(glob(src_gv).value_type));
    if (name == "llvm.global_ctors" || name == "llvm.global_dtors") && type_nsub(elt_ty) != 3
        lk_fail("llvm-link: linking old-style two-field % is not supported", name);
    is_new_structor := name == "llvm.global_ctors" || name == "llvm.global_dtors";
    dst_num: u64 = 0;
    if dst_gv != NONE && !lk_is_declaration(dst_gv) {
        dst_ty := glob(dst_gv).value_type;
        dst_num = type_count(dst_ty);
        if elt_ty != type_elem(dst_ty) lk_fail("Appending variables with different element types!");
    }
    init := op(src_gv, 0);
    src_elements: [..] Value_Id;
    n := type_count(vtype(init));
    if n > 0 for i: 0..n - 1 array_add(*src_elements, cf_elt(init, i));
    if is_new_structor {
        kept: [..] Value_Id;
        for e: src_elements {
            key := strip_pointer_casts(cf_elt(e, 2));
            if key != NONE && is_global_value(vkind(key)) {
                dgv := lk_linked_to_global(key);
                if !lk_should_link(dgv, key) continue;
            }
            array_add(*kept, e);
        }
        src_elements = kept;
    }
    new_type := type_array(dst_num + cast(u64) src_elements.count, elt_ty);
    s := glob(src_gv);
    ng := lk_new_gvar(new_type, s.is_const, s.linkage, "", dst_gv, s.tls, s.addrspace);
    gv_copy_attributes_from(ng, src_gv);
    lk_force_renaming(ng, name);
    // Mapper::scheduleMapAppendingVariable
    w: Lk_Work; w.kind = .APPENDING_VAR; w.mcid = 0; w.gv = ng; w.old_gv = dst_gv; w.num_new = cast(u32) src_elements.count;
    lk_schedule(w);
    for src_elements array_add(*lk.appending_inits, it);
    if dst_gv != NONE array_add(*lk.rauw, .{dst_gv, ng});
    return ng;
}

// IRLinker::materialize (both materializers; for_indirect = LocalValueMaterializer)
lk_materialize :: (v: Value_Id, for_indirect: bool) -> Value_Id {
    if !is_global_value(vkind(v)) return NONE;
    if lk_owner_of(v) != OWN_SRC return NONE;
    nv := lk_link_global_value_proto(v, for_indirect);
    if nv == NONE return NONE;
    k := vkind(nv);
    if !is_global_value(k) return nv;
    if k == .FUNCTION { if !is_declaration(nv) return nv; }
    else if k == .GLOBAL_VAR { if glob(nv).has_init || lk_is_appending(nv) return nv; }
    else if op(nv, 0) != NONE return nv;
    if for_indirect { found, x := table_find(*lk.vmap[0], v); if found && x == nv return nv; }
    else { found, x := table_find(*lk.vmap[1], v); if found && x == nv return nv; }
    if for_indirect || lk_should_link(nv, v) lk_link_global_value_body(nv, v);
    lk_update_attributes(nv);
    return nv;
}

// IRLinker::linkFunctionBody: steal the arguments and splice the body, then schedule the remapping
lk_link_function_body :: (dst: Value_Id, src: Value_Id) {
    s := glob(src);
    if s.has_prefix { set_op(dst, 1, op(src, 1)); glob(dst).has_prefix = true; }
    if s.has_prologue { set_op(dst, 2, op(src, 2)); glob(dst).has_prologue = true; }
    if s.has_personality { set_op(dst, 0, op(src, 0)); glob(dst).has_personality = true; }
    lk_copy_metadata(dst, src);
    // Function::stealArgumentListFrom: the arguments (with their names) move over
    d := glob(dst);
    d.arg_start = s.arg_start;
    d.nargs = s.nargs;
    if s.nargs > 0 for a: 0..s.nargs - 1 arg_parents[ir.v_aux[s.arg_start + a]] = dst;
    // Function::splice(end, Src): blocks, instructions and their names (the local symbol table) move over
    d.symtab = s.symtab;
    d.first_block = s.first_block; d.last_block = s.last_block; d.next_block_num = s.next_block_num;
    s.first_block = NONE; s.last_block = NONE;
    for b: fn_blocks(dst) block(b).parent = dst;
    w: Lk_Work; w.kind = .REMAP_FUNCTION; w.gv = dst;
    lk_schedule(w);
}

// IRLinker::linkGlobalValueBody
lk_link_global_value_body :: (dst: Value_Id, src: Value_Id) {
    k := vkind(src);
    w: Lk_Work;
    if k == .FUNCTION { lk_link_function_body(dst, src); return; }
    if k == .GLOBAL_VAR { w.kind = .GLOBAL_INIT; w.mcid = 0; w.gv = dst; w.init = op(src, 0); lk_schedule(w); return; }
    // linkAliasAliasee / linkIFuncResolver: mapped in the indirect-symbol context
    w.kind = .ALIAS_OR_IFUNC; w.mcid = 1; w.gv = dst; w.init = op(src, 0);
    lk_schedule(w);
}

// IRLinker::updateAttributes: nocallback no longer holds once modules are merged
lk_update_attributes :: (gv: Value_Id) {
    if vkind(gv) != .FUNCTION return;
    if !glob(gv).intrinsic {
        l := glob(gv).attrs;
        glob(gv).attrs = attr_list_with_fn(l, attr_set_remove(attr_list_fn(l), .NoCallback));
    }
    for b: fn_blocks(gv) for i: block_insts(b) if is_call_base(i) && attr_set_has(attr_list_fn(inst(i).attrs), .NoCallback) call_remove_fn_attr(i, .NoCallback);
}

// IRLinker::flushRAUWWorklist
lk_flush_rauw :: () {
    for lk.rauw {
        ipo_rauw(it.old, it.new);
        gv_erase_from_parent(it.old);
    }
    lk.rauw.count = 0;
}

// getTypeNamePrefix: "%foo.42" -> "%foo"
lk_type_name_prefix :: (name: string) -> string {
    dot := -1;
    for < i: name.count - 1..0 if name[i] == #char "." { dot = i; break; }
    if dot == 0 || dot < 0 || name[name.count - 1] == #char "." return name;
    c := name[dot + 1];
    if c < #char "0" || c > #char "9" return name;
    return slice(name, 0, dot);
}

// Module::getIdentifiedStructTypes of the source module (TypeFinder, OnlyNamed = false)
lk_src_identified_struct_types :: () -> [..] Type_Id {
    lk_swap_module(lk.src);
    printer_reset();
    type_finder_run();
    out: [..] Type_Id; out.allocator = temp;
    for W.tf_structs if !lk_is_literal(it) array_add(*out, it);
    printer_reset();
    lk_swap_module(lk.src);
    return out;
}

// IRLinker::computeTypeMapping
lk_compute_type_mapping :: () {
    for sgv: lk.src.m_globals {
        dgv := lk_linked_to_global(sgv);
        if dgv == NONE continue;
        if !lk_is_appending(dgv) || !lk_is_appending(sgv) { lk_tm_add_mapping(vtype(dgv), vtype(sgv)); continue; }
        lk_tm_add_mapping(type_elem(glob(dgv).value_type), type_elem(glob(sgv).value_type));
    }
    for sgv: lk.src.m_functions {
        dgv := lk_linked_to_global(sgv);
        if dgv == NONE || vtype(dgv) == vtype(sgv) continue;
        lk_tm_add_mapping(vtype(dgv), vtype(sgv));
    }
    for sgv: lk.src.m_aliases {
        dgv := lk_linked_to_global(sgv);
        if dgv != NONE lk_tm_add_mapping(vtype(dgv), vtype(sgv));
    }
    types := lk_src_identified_struct_types();
    for st: types {
        name := ir.types[st].name;
        if name.count == 0 continue;
        if lk_set_has_type(st) continue;
        prefix := lk_type_name_prefix(name);
        if prefix.count == name.count continue;
        found, dst := table_find(*ir.named_types, prefix);
        if !found continue;
        if lk_set_has_type(dst) lk_tm_add_mapping(dst, st);
    }
}

lk_find_named_md :: (name: string) -> *Named_Md {
    for * ir.named_md if it.name == name return it;
    return null;
}
lk_src_find_named_md :: (name: string) -> *Named_Md {
    for * lk.src.named_md if it.name == name return it;
    return null;
}
// Module::getOrInsertNamedMetadata (index into ir.named_md)
lk_get_or_insert_named_md :: (name: string) -> s64 {
    for ir.named_md if it.name == name return it_index;
    nm: Named_Md; nm.name = intern_str(name);
    array_add(*ir.named_md, nm);
    return ir.named_md.count - 1;
}

// IRLinker::linkNamedMDNodes
lk_link_named_md_nodes :: () {
    for src_nmd: lk.src.named_md {
        if src_nmd.name == "llvm.module.flags" continue;
        di := lk_get_or_insert_named_md(src_nmd.name);
        ins := table_find_pointer(*lk.nmd_inserted, src_nmd.name);
        if !ins { e: Table(Md_Id, bool); ins = table_add(*lk.nmd_inserted, intern_str(src_nmd.name), e); }
        if ins.count == 0 for ir.named_md[di].ops table_set(ins, it, true);
        for o: src_nmd.ops {
            m := lk_map_md_flushing(o);
            if table_contains(ins, m) continue;
            table_set(ins, m, true);
            array_add(*ir.named_md[di].ops, m);
        }
    }
}

lk_flag_behavior :: (op: Md_Id) -> u64 {
    b := md_op(op, 0);
    return const_int_zext(ir.mds[b].value);
}
lk_md_const_int :: (m: Md_Id) -> u64 { return const_int_zext(ir.mds[m].value); }

// MDTuple::push_back on a distinct tuple
lk_md_push_back :: (t: Md_Id, o: Md_Id) {
    r := *ir.mds[t];
    start := cast(u32) ir.md_ops.count;
    for i: 0..cast(s64) r.nops - 1 array_add(*ir.md_ops, ir.md_ops[r.ops + cast(u32) i]);
    array_add(*ir.md_ops, o);
    r.ops = start;
    r.nops += 1;
}

// IRLinker::linkModuleFlagsMetadata
lk_link_module_flags :: () {
    src_flags := lk_src_find_named_md("llvm.module.flags");
    if !src_flags return;
    di := lk_get_or_insert_named_md("llvm.module.flags");
    if ir.named_md[di].ops.count == 0 {
        for src_flags.ops array_add(*ir.named_md[di].ops, it);
        return;
    }
    Flag_Entry :: struct { op: Md_Id; idx: s64; }
    flags: Table(Md_Id, Flag_Entry); flags.allocator = temp;
    requirements: [..] Md_Id; requirements.allocator = temp;
    mins: [..] s64; mins.allocator = temp;
    seen_min: Table(Md_Id, bool); seen_min.allocator = temp;
    add_req :: (reqs: *[..] Md_Id, m: Md_Id) -> bool { for reqs.* if it == m return false; array_add(reqs, m); return true; }
    for o, i: ir.named_md[di].ops {
        b := lk_flag_behavior(o);
        id := md_op(o, 1);
        if b == MFB_REQUIRE add_req(*requirements, md_op(o, 2));
        else {
            if b == MFB_MIN array_add(*mins, i);
            table_set(*flags, id, .{o, i});
        }
    }
    for src_op: src_flags.ops {
        sb := lk_flag_behavior(src_op);
        id := md_op(src_op, 1);
        found, fe := table_find(*flags, id);
        dst_op: Md_Id = ifx found then fe.op else NONE;
        dst_idx := ifx found then fe.idx else 0;
        table_set(*seen_min, id, true);
        if sb == MFB_REQUIRE {
            if add_req(*requirements, md_op(src_op, 2)) array_add(*ir.named_md[di].ops, src_op);
            continue;
        }
        if dst_op == NONE {
            if sb == MFB_MIN { array_add(*mins, ir.named_md[di].ops.count); table_remove(*seen_min, id); }
            table_set(*flags, id, .{src_op, ir.named_md[di].ops.count});
            array_add(*ir.named_md[di].ops, src_op);
            continue;
        }
        db := lk_flag_behavior(dst_op);
        idstr := ir.mds[id].str;
        if db == MFB_OVERRIDE {
            if sb == MFB_OVERRIDE && md_op(src_op, 2) != md_op(dst_op, 2)
                lk_fail("linking module flags '%': IDs have conflicting override values", idstr);
            continue;
        } else if sb == MFB_OVERRIDE {
            ir.named_md[di].ops[dst_idx] = src_op;
            table_set(*flags, id, .{src_op, dst_idx});
            continue;
        }
        if sb != db {
            min_and_warn := (sb == MFB_MIN && db == MFB_WARNING) || (db == MFB_MIN && sb == MFB_WARNING);
            max_and_warn := (sb == MFB_MAX && db == MFB_WARNING) || (db == MFB_MAX && sb == MFB_WARNING);
            if !(max_and_warn || min_and_warn) lk_fail("linking module flags '%': IDs have conflicting behaviors", idstr);
        }
        if (db == MFB_WARNING || sb == MFB_WARNING) && md_op(src_op, 2) != md_op(dst_op, 2)
            lk_warn(tprint("linking module flags '%': IDs have conflicting values", idstr));
        if db == MFB_MIN || sb == MFB_MIN || db == MFB_MAX || sb == MFB_MAX {
            is_min := db == MFB_MIN || sb == MFB_MIN;
            want := ifx is_min then MFB_MIN else MFB_MAX;
            dv := lk_md_const_int(md_op(dst_op, 2));
            sv := lk_md_const_int(md_op(src_op, 2));
            pick_src := ifx is_min then sv < dv else sv > dv;
            ops := Md_Id.[md_op(ifx db != want then src_op else dst_op, 0), id, md_op(ifx pick_src then src_op else dst_op, 2)];
            fl := md_tuple(ops, false);
            ir.named_md[di].ops[dst_idx] = fl;
            table_set(*flags, id, .{fl, dst_idx});
            continue;
        }
        if sb == {
            case MFB_ERROR;
                if md_op(src_op, 2) != md_op(dst_op, 2) lk_fail("linking module flags '%': IDs have conflicting values", idstr);
            case MFB_WARNING;
            case MFB_APPEND; #through;
            case MFB_APPEND_UNIQUE;
                // ensureDistinctOp
                dv := md_op(dst_op, 2);
                if !ir.mds[dv].distinct {
                    n := ir.mds[dv].nops;
                    cp := NewArray(n, Md_Id,, allocator = temp);
                    if n > 0 for k: 0..n - 1 cp[k] = md_op(dv, k);
                    nw := md_tuple(cp, true);
                    fl := md_tuple(Md_Id.[md_op(dst_op, 0), id, nw], true);
                    ir.named_md[di].ops[dst_idx] = fl;
                    table_set(*flags, id, .{fl, dst_idx});
                    dv = nw;
                }
                sv := md_op(src_op, 2);
                ns := ir.mds[sv].nops;
                if sb == MFB_APPEND {
                    if ns > 0 for k: 0..ns - 1 lk_md_push_back(dv, md_op(sv, k));
                } else {
                    elts: [..] Md_Id; elts.allocator = temp;
                    add_unique :: (e: *[..] Md_Id, m: Md_Id) { for e.* if it == m return; array_add(e, m); }
                    for k: 0..cast(s64) ir.mds[dv].nops - 1 add_unique(*elts, md_op(dv, cast(u32) k));
                    if ns > 0 for k: 0..ns - 1 add_unique(*elts, md_op(sv, k));
                    start := ir.mds[dv].nops;
                    for k: start..cast(u32) elts.count - 1 lk_md_push_back(dv, elts[k]);
                }
            case;
                lk_fail("llvm-link: unknown module flag behavior %", sb);
        }
    }
    for idx: mins {
        o := ir.named_md[di].ops[idx];
        id := md_op(o, 1);
        if !table_contains(*seen_min, id) {
            v := ir.mds[md_op(o, 2)].value;
            ops := Md_Id.[md_op(o, 0), id, md_value(const_int(vtype(v), 0))];
            ir.named_md[di].ops[idx] = md_tuple(ops, false);
        }
    }
    for req: requirements {
        flag := md_op(req, 0);
        req_val := md_op(req, 1);
        found, fe := table_find(*flags, flag);
        if !found || md_op(fe.op, 2) != req_val lk_fail("linking module flags '%': does not have the required value", ir.mds[flag].str);
    }
}

// IRLinker::run
lk_irlinker_run :: () {
    src := lk.src;
    if ir.datalayout.count == 0 && src.datalayout.count { ir.datalayout = src.datalayout; }
    if ir.triple.count == 0 && src.triple.count ir.triple = src.triple;
    if src.datalayout != ir.datalayout
        lk_warn(tprint("Linking two modules of different data layouts: '%' is '%' whereas '%' is '%'\n", src.module_id, src.datalayout, ir.module_id, ir.datalayout));
    if src.triple.count && src.triple != ir.triple {
        st := triple_parse(src.triple);
        if st.vendor == .Apple lk_fail("llvm-link: merging Apple target triples is not supported");
        lk_warn(tprint("Linking two modules of different target triples: '%' is '%' whereas '%' is '%'\n", src.module_id, src.triple, ir.module_id, ir.triple));
    }
    tt := triple_parse(src.triple);
    if tt.arch == .arm || tt.arch == .armeb || tt.arch == .thumb || tt.arch == .thumbeb || tt.arch == .aarch64 || tt.arch == .aarch64_be || tt.arch == .aarch64_32
        lk_fail("llvm-link: ARM / AArch64 modules (copyModuleAttrToFunctions) are not supported");
    dl_init(ir.datalayout);
    lk_compute_type_mapping();

    // std::reverse(Worklist), then pop from the back
    n := lk.worklist.count;
    for i: 0..n / 2 - 1 { t := lk.worklist[i]; lk.worklist[i] = lk.worklist[n - 1 - i]; lk.worklist[n - 1 - i] = t; }
    while lk.worklist.count {
        gv := pop(*lk.worklist);
        if table_contains(*lk.vmap[0], gv) || table_contains(*lk.vmap[1], gv) continue;
        lk_map_value_flushing(gv);
        lk_flush_rauw();
    }
    lk.done_linking_bodies = true;
    lk.null_map_missing = true;
    lk_link_named_md_nodes();
    for lk.unmapped_md if vkind(it) != .DEAD && is_declaration(it) { lk_remap_global_object_metadata(it); lk_flush(); }
    for src.module_asm append_module_asm(it, src.module_asm_features[it_index], src.module_asm_cpu[it_index]);
    // reorder the globals just added to match their order in the source module
    for gv: src.m_globals {
        if lk_is_appending(gv) continue;
        nv := lk_map_value_flushing(gv);
        if nv == NONE continue;
        g := strip_pointer_casts(nv);
        if vkind(g) != .GLOBAL_VAR continue;
        remove_from_list(*ir.m_globals, g);
        array_add(*ir.m_globals, g);
    }
    lk_link_module_flags();
}

// IRMover::move
lk_irmover_move :: (src: *Module_State, values: [] Value_Id) {
    lk.src = src;
    table_reset(*lk.tm);
    table_reset(*lk.vmap[0]); table_reset(*lk.vmap[1]);
    table_reset(*lk.mdmap1);
    table_reset(*lk.to_link);
    lk.worklist.count = 0; lk.rauw.count = 0; lk.unmapped_md.count = 0; lk.work.count = 0;
    lk.appending_inits.count = 0; lk.distinct_worklist.count = 0;
    lk.done_linking_bodies = false; lk.null_map_missing = false; lk.mcid = 0;
    for values lk_maybe_add(it);
    lk_irlinker_run();
}

// ---------------------------------------------------------------- ModuleLinker

// ModuleLinker::getLinkedToGlobal
ml_linked_to_global :: (sgv: Value_Id) -> Value_Id {
    if vname(sgv).count == 0 || lk_is_local(sgv) return NONE;
    dgv := lookup_global(vname(sgv));
    if dgv == NONE || lk_is_local(dgv) return NONE;
    return dgv;
}

// getComdatLeader: the global variable named like the comdat in the given module
ml_comdat_leader :: (in_src: bool, name: string) -> Value_Id {
    gv := ifx in_src then lk_src_named_value(name) else lookup_global(name);
    if gv != NONE && vkind(gv) == .ALIAS {
        gv = gv_aliasee_object(op(gv, 0));
        if gv == NONE lk_fail("Linking COMDATs named '%': COMDAT key involves incomputable alias size.", name);
    }
    if gv == NONE || vkind(gv) != .GLOBAL_VAR lk_fail("Linking COMDATs named '%': GlobalVariable required for data dependent selection!", name);
    return gv;
}

// ModuleLinker::computeResultingSelectionKind
ml_resulting_selection_kind :: (name: string, src_k: u8, dst_k: u8) -> (kind: u8, from: u8) {
    dst_any_or_largest := dst_k == SK_ANY || dst_k == SK_LARGEST;
    src_any_or_largest := src_k == SK_ANY || src_k == SK_LARGEST;
    result: u8;
    if dst_any_or_largest && src_any_or_largest {
        result = ifx dst_k == SK_LARGEST || src_k == SK_LARGEST then SK_LARGEST else SK_ANY;
    } else if src_k == dst_k result = dst_k;
    else lk_fail("Linking COMDATs named '%': invalid selection kinds!", name);
    from: u8;
    if result == {
        case SK_ANY; from = LINK_FROM_DST;
        case SK_NO_DEDUPLICATE; from = LINK_FROM_BOTH;
        case;
            dst_gv := ml_comdat_leader(false, name);
            src_gv := ml_comdat_leader(true, name);
            dst_size := lk_global_size(dst_gv);
            src_size := lk_global_size(src_gv);
            if result == SK_EXACT_MATCH {
                if op(src_gv, 0) != op(dst_gv, 0) lk_fail("Linking COMDATs named '%': ExactMatch violated!", name);
                from = LINK_FROM_DST;
            } else if result == SK_LARGEST {
                from = ifx src_size > dst_size then LINK_FROM_SRC else LINK_FROM_DST;
            } else {
                if src_size != dst_size lk_fail("Linking COMDATs named '%': SameSize violated!", name);
                from = LINK_FROM_DST;
            }
    }
    return result, from;
}

// ModuleLinker::getComdatResult
ml_comdat_result :: (sc: s32) -> (kind: u8, from: u8) {
    row := lk.src.comdats[sc];
    found, dc := table_find(*ir.comdat_map, row.name);
    if !found return row.kind, LINK_FROM_SRC;
    k, f := ml_resulting_selection_kind(row.name, row.kind, ir.comdats[dc].kind);
    return k, f;
}

min_visibility :: (a: u8, b: u8) -> u8 {
    if a == 1 || b == 1 return 1;
    if a == 2 || b == 2 return 2;
    return 0;
}
// GlobalValue::getMinUnnamedAddr (0 none, 1 local, 2 global)
min_unnamed_addr :: (a: u8, b: u8) -> u8 {
    if a == 0 || b == 0 return 0;
    if a == 1 || b == 1 return 1;
    return 2;
}

// ModuleLinker::shouldLinkFromSource (errors are fatal)
ml_should_link_from_source :: (dest: Value_Id, src: Value_Id) -> bool {
    if lk.override_from_src return true;
    if lk_is_appending(src) || lk_is_appending(dest) return true;
    src_decl := gv_is_declaration_for_linker(src);
    dest_decl := gv_is_declaration_for_linker(dest);
    if src_decl {
        if glob(src).dll == 1 return dest_decl;
        if lk_linkage(dest) == .EXTERN_WEAK return true;
        return !lk_is_declaration(src) && lk_is_declaration(dest);
    }
    if dest_decl return true;
    if lk_linkage(src) == .COMMON {
        if lk_is_linkonce(dest) || lk_is_weak(dest) return true;
        if lk_linkage(dest) != .COMMON return false;
        return lk_global_size(src) > lk_global_size(dest);
    }
    if gv_is_weak_for_linker(src) {
        if lk_is_linkonce(dest) && lk_is_weak(src) return true;
        return false;
    }
    if gv_is_weak_for_linker(dest) return true;
    lk_fail("Linking globals named '%': symbol multiply defined!", vname(src));
    return false;
}

ml_insert_value :: (gv: Value_Id) {
    if table_contains(*lk.ml_values_set, gv) return;
    table_set(*lk.ml_values_set, gv, true);
    array_add(*lk.ml_values, gv);
}

// ModuleLinker::linkIfNeeded
ml_link_if_needed :: (gv: Value_Id, to_clone: *[..] Value_Id) {
    dgv := ml_linked_to_global(gv);
    if lk.only_needed && !lk_is_appending(gv) {
        if dgv == NONE return;
        if !lk_is_declaration(dgv) return;
    }
    if dgv != NONE && !lk_is_local(gv) && !lk_is_appending(gv) {
        if vkind(dgv) == .GLOBAL_VAR && vkind(gv) == .GLOBAL_VAR {
            d := glob(dgv); s := glob(gv);
            if lk_is_declaration(dgv) && lk_is_declaration(gv) && (!d.is_const || !s.is_const) { d.is_const = false; s.is_const = false; }
            if d.linkage == .COMMON && s.linkage == .COMMON {
                al: u64 = 0;
                if d.align != 0 || s.align != 0 al = max(max(d.align, 1), max(s.align, 1));
                s.align = al; d.align = al;
            }
        }
        vis := min_visibility(glob(dgv).visibility, glob(gv).visibility);
        gv_set_visibility(dgv, vis);
        gv_set_visibility(gv, vis);
        ua := min_unnamed_addr(glob(dgv).unnamed_addr, glob(gv).unnamed_addr);
        glob(dgv).unnamed_addr = ua;
        glob(gv).unnamed_addr = ua;
    }
    if dgv == NONE && !lk.override_from_src && (lk_is_local(gv) || lk_is_linkonce(gv) || lk_is_avail_ext(gv)) return;
    if lk_is_declaration(gv) return;
    comdat_from := LINK_FROM_DST;
    sc := gv_comdat(gv);
    if sc >= 0 {
        found, ch := table_find(*lk.comdats_chosen, sc);
        comdat_from = ifx found then ch.from else LINK_FROM_DST;
        if comdat_from == LINK_FROM_DST return;
    }
    link_from_src := true;
    if dgv != NONE link_from_src = ml_should_link_from_source(dgv, gv);
    if dgv != NONE && comdat_from == LINK_FROM_BOTH array_add(to_clone, ifx link_from_src then dgv else gv);
    if link_from_src ml_insert_value(gv);
}

// ModuleLinker::addLazyFor (the IRMover's AddLazyFor callback); returns whether anything was added
ml_add_lazy_for :: (gv: Value_Id) -> bool {
    if !lk_is_linkonce(gv) && !lk_is_avail_ext(gv) && !lk.only_needed return false;
    if lk.internalize_cb table_set(*lk.internalize_names, vname(gv), true);
    lk_maybe_add(gv);
    sc := gv_comdat(gv);
    if sc < 0 return true;
    members := table_find_pointer(*lk.lazy_comdat_members, sc);
    if members for gv2: members.* {
        dgv := ml_linked_to_global(gv2);
        lfs := true;
        if dgv != NONE lfs = ml_should_link_from_source(dgv, gv2);
        if !lfs continue;
        if lk.internalize_cb table_set(*lk.internalize_names, vname(gv2), true);
        lk_maybe_add(gv2);
    }
    return true;
}

// ModuleLinker::dropReplacedComdat
ml_drop_replaced_comdat :: (gv: Value_Id, replaced: *Table(s32, bool)) {
    c := gv_comdat(gv);
    if c < 0 || !table_contains(replaced, c) return;
    if !has_uses(gv) { gv_erase_from_parent(gv); return; }
    k := vkind(gv);
    if k == .FUNCTION { fn_delete_body(gv); return; }
    if k == .GLOBAL_VAR { gv_set_initializer(gv, NONE); return; }
    vt := glob(gv).value_type;
    decl: Value_Id;
    if type_kind(vt) == .FUNC { decl = lk_new_function(vt, 0, ""); gv_set_linkage(decl, .EXTERNAL); }
    else decl = lk_new_gvar(vt, false, .EXTERNAL, "", NONE, 0, 0);
    gv_take_name(decl, gv);
    ipo_rauw(gv, decl);
    gv_erase_from_parent(gv);
}

// ModuleLinker::run
ml_run :: (src: *Module_State) {
    lk.src = src;
    table_reset(*lk.comdats_chosen);
    table_reset(*lk.lazy_comdat_members);
    table_reset(*lk.ml_values_set);
    lk.ml_values.count = 0;
    table_reset(*lk.internalize_names);

    replaced: Table(s32, bool); replaced.allocator = temp;
    non_prevailing: [..] s32; non_prevailing.allocator = temp;
    for c, ci: src.comdats {
        sc := cast(s32) ci;
        if table_contains(*lk.comdats_chosen, sc) continue;
        k, from := ml_comdat_result(sc);
        table_set(*lk.comdats_chosen, sc, .{k, from});
        if from == LINK_FROM_DST array_add(*non_prevailing, sc);
        if from != LINK_FROM_SRC continue;
        found, dc := table_find(*ir.comdat_map, c.name);
        if !found continue;
        table_set(*replaced, dc, true);
    }
    if replaced.count {
        copy_list :: (l: [] Value_Id) -> [..] Value_Id { c: [..] Value_Id; c.allocator = temp; for l array_add(*c, it); return c; }
        for copy_list(ir.m_aliases) ml_drop_replaced_comdat(it, *replaced);
        for copy_list(ir.m_globals) ml_drop_replaced_comdat(it, *replaced);
        for copy_list(ir.m_functions) ml_drop_replaced_comdat(it, *replaced);
    }
    if non_prevailing.count {
        aliased: Table(Value_Id, bool); aliased.allocator = temp;
        for ga: src.m_aliases {
            go := gv_aliasee_object(op(ga, 0));
            if go != NONE && gv_comdat(go) >= 0 table_set(*aliased, go, true);
        }
        for c: non_prevailing {
            to_update: [..] Value_Id; to_update.allocator = temp;
            for g: src.m_globals if glob(g).comdat == c && glob(g).linkage == .PRIVATE && !table_contains(*aliased, g) array_add(*to_update, g);
            for g: src.m_functions if glob(g).comdat == c && glob(g).linkage == .PRIVATE && !table_contains(*aliased, g) array_add(*to_update, g);
            for to_update { gv_set_linkage(it, .AVAILABLE_EXTERNALLY); glob(it).comdat = -1; }
        }
    }
    add_member :: (g: Value_Id) {
        if !lk_is_linkonce(g) return;
        sc := gv_comdat(g);
        if sc < 0 return;
        p := table_find_pointer(*lk.lazy_comdat_members, sc);
        if !p { e: [..] Value_Id; p = table_add(*lk.lazy_comdat_members, sc, e); }
        array_add(p, g);
    }
    for src.m_globals add_member(it);
    for src.m_functions add_member(it);
    for src.m_aliases add_member(it);

    to_clone: [..] Value_Id; to_clone.allocator = temp;
    for src.m_globals ml_link_if_needed(it, *to_clone);
    for src.m_functions ml_link_if_needed(it, *to_clone);
    for src.m_aliases ml_link_if_needed(it, *to_clone);
    for src.m_ifuncs ml_link_if_needed(it, *to_clone);

    for v: to_clone {
        if vkind(v) != .GLOBAL_VAR lk_fail("linking '%': non-variables in comdat nodeduplicate are not handled", vname(v));
        g := glob(v);
        in_src := lk_owner_of(v) == OWN_SRC;
        if in_src lk_swap_module(src);   // new GlobalVariable(*Var->getParent(), ...)
        nv := gv_create(g.value_type, g.is_const, g.linkage, op(v, 0), "", NONE, 0, g.addrspace);
        if in_src lk_swap_module(src);
        lk_set_owner(nv, ifx in_src then OWN_SRC else OWN_DST);
        gv_copy_attributes_from(nv, v);
        gv_set_visibility(nv, 0);
        gv_set_linkage(nv, .PRIVATE);
        glob(nv).dso_local = true;
        glob(nv).comdat = glob(v).comdat;
        if in_src ml_insert_value(nv);
    }

    i := 0;
    while i < lk.ml_values.count {
        gv := lk.ml_values[i];
        i += 1;
        sc := gv_comdat(gv);
        if sc < 0 continue;
        members := table_find_pointer(*lk.lazy_comdat_members, sc);
        if !members continue;
        for gv2: members.* {
            dgv := ml_linked_to_global(gv2);
            lfs := true;
            if dgv != NONE lfs = ml_should_link_from_source(dgv, gv2);
            if lfs ml_insert_value(gv2);
        }
    }
    if lk.internalize_cb for lk.ml_values table_set(*lk.internalize_names, vname(it), true);

    lk_irmover_move(src, lk.ml_values);

    if lk.internalize_cb {
        // internalizeModule(DstM, [&](GV) { return !GV.hasName() || !GVS.count(GV.getName()); })
        s: Internalize;
        s.link_names = *lk.internalize_names;
        internalize_module(*s);
    }
}

// ---------------------------------------------------------------- llvm-link

llvm_link_main :: () {
    tool_name = "llvm-link";
    args := get_command_line_arguments();
    inputs: [..] string;
    output := "-";
    internalize := false;
    only_needed := false;
    i := 1;
    while i < args.count {
        a := args[i];
        i += 1;
        if a == "-S" || a == "--S" continue;
        if a == "-o" { if i >= args.count fatal("-o needs a file"); output = args[i]; i += 1; continue; }
        if begins_with(a, "-o=") { output = slice(a, 3, a.count - 3); continue; }
        if a == "-internalize" || a == "--internalize" { internalize = true; continue; }
        if a == "-only-needed" || a == "--only-needed" { only_needed = true; continue; }
        // -disable-lazy-loading: text input is never lazy; -suppress-warnings / -f / -v change nothing we print
        if a == "-disable-lazy-loading" || a == "--disable-lazy-loading" || a == "-suppress-warnings" || a == "--suppress-warnings" continue;
        if a == "-f" || a == "--f" continue;
        if begins_with(a, "-") && a != "-" fatal("unsupported option '%'", a);
        array_add(*inputs, a);
    }
    if inputs.count == 0 fatal("no input files");
    ir_init();
    parse_without_dl_callback = true;
    ir.module_id = "llvm-link";
    ir.source_filename = "llvm-link";   // Module(ModuleID): SourceFileName = ModuleID
    internalize_linked := false;
    first := true;
    for file: inputs {
        text, ok := read_entire_file(file);
        if !ok fatal("No such file or directory: '%'", file);
        // load the file into the same context: the composite's module state is set aside while parsing
        st: Module_State;
        lk_swap_module(*st);
        P = .{};
        saw_source_filename = false;
        ir.module_id = file;
        parse_module(text, file);
        if ir.source_filename.count == 0 && !saw_source_filename ir.source_filename = file;
        lk_swap_module(*st);
        lk_mark_module(*st, OWN_SRC);
        lk.override_from_src = false;
        lk.only_needed = !first && only_needed;
        lk.internalize_cb = internalize_linked;
        ml_run(*st);
        lk_mark_module(*st, OWN_GONE);
        internalize_linked = internalize;
        first = false;
        reset_temporary_storage();
    }
    dl_init(ir.datalayout);
    text := print_module_fresh();
    if output == "-" write_string(text);
    else if !write_entire_file(output, text) fatal("could not write '%'", output);
}
