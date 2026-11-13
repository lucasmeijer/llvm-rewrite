// The Verifier's metadata checks (part of the port of llvm/lib/IR/Verifier.cpp, see verifier.jai): generic MDNodes,
// the debug-info nodes (visitDI*), debug records (#dbg_value ...), named metadata, module flags, the attachments of
// instructions and functions (!range, !prof, !tbaa, ...), and the TBAA verifier (TBAAVerifier).
//
// DI node layouts are the parser's (debuginfo.jai parse_di_node): every DIType has file, scope, name as operands 0,
// 1, 2 and its tag (when it has one) as integer field 0.

// ---------------------------------------------------------------- metadata classes

md_is_value :: inline (m: Md_Id) -> bool { return m != NONE && ir.mds[m].kind == .VALUE; }
md_is_string :: inline (m: Md_Id) -> bool { return m != NONE && ir.mds[m].kind == .STRING; }
md_is_tuple :: inline (m: Md_Id) -> bool { return m != NONE && ir.mds[m].kind == .TUPLE; }
// LocalAsMetadata: a ValueAsMetadata of an instruction, argument or block
md_is_local :: (m: Md_Id) -> bool {
    if !md_is_value(m) return false;
    v := ir.mds[m].value;
    if v == NONE return false;
    k := vkind(v);
    return k == .INST || k == .ARGUMENT || k == .BLOCK || k == .PLACEHOLDER;
}
// ConstantAsMetadata
md_is_constant :: (m: Md_Id) -> bool {
    if !md_is_value(m) return false;
    v := ir.mds[m].value;
    return v != NONE && is_constant_kind(vkind(v));
}
// mdconst::dyn_extract<ConstantInt>
md_const_int :: (m: Md_Id) -> Value_Id {
    if !md_is_constant(m) return NONE;
    v := ir.mds[m].value;
    if vkind(v) == .C_INT return v;
    return NONE;
}
vf_md_nops :: inline (m: Md_Id) -> u32 { return ir.mds[m].nops; }

vf_di_is_type :: (m: Md_Id) -> bool {
    if m == NONE || ir.mds[m].kind != .SPECIAL return false;
    k := di_kind(m);
    return k == .BASIC_TYPE || k == .DERIVED_TYPE || k == .COMPOSITE_TYPE || k == .SUBROUTINE_TYPE;
}
di_is_scope :: (m: Md_Id) -> bool {
    if m == NONE || ir.mds[m].kind != .SPECIAL return false;
    if vf_di_is_type(m) return true;
    k := di_kind(m);
    return k == .FILE || k == .COMPILE_UNIT || k == .SUBPROGRAM || k == .LEXICAL_BLOCK || k == .LEXICAL_BLOCK_FILE || k == .NAMESPACE;
}
di_is_local_scope :: (m: Md_Id) -> bool {
    if m == NONE || ir.mds[m].kind != .SPECIAL return false;
    k := di_kind(m);
    return k == .SUBPROGRAM || k == .LEXICAL_BLOCK || k == .LEXICAL_BLOCK_FILE;
}
di_is_node :: (m: Md_Id) -> bool {
    if m == NONE || ir.mds[m].kind != .SPECIAL return false;
    k := di_kind(m);
    return !(k == .LOCATION || k == .EXPRESSION || k == .GLOBAL_VARIABLE_EXPRESSION || k == .ASSIGN_ID || k == .ARG_LIST);
}
di_is_variable :: (m: Md_Id) -> bool { return is_di(m, .LOCAL_VARIABLE) || is_di(m, .GLOBAL_VARIABLE); }
// isType / isScope / isDINode / isMDTuple: null or of that class
vf_is_type :: inline (m: Md_Id) -> bool { return m == NONE || vf_di_is_type(m); }
vf_is_scope :: inline (m: Md_Id) -> bool { return m == NONE || di_is_scope(m); }
vf_is_dinode :: inline (m: Md_Id) -> bool { return m == NONE || di_is_node(m); }
vf_is_md_tuple :: inline (m: Md_Id) -> bool { return m == NONE || md_is_tuple(m); }

VDW_TAG_ARRAY_TYPE :: 0x01; VDW_TAG_CLASS_TYPE :: 0x02; VDW_TAG_ENUMERATION_TYPE :: 0x04; VDW_TAG_IMPORTED_DECLARATION :: 0x08;
VDW_TAG_MEMBER :: 0x0d; VDW_TAG_POINTER_TYPE :: 0x0f; VDW_TAG_REFERENCE_TYPE :: 0x10; VDW_TAG_STRING_TYPE :: 0x12;
VDW_TAG_STRUCTURE_TYPE :: 0x13; VDW_TAG_SUBROUTINE_TYPE :: 0x15; VDW_TAG_TYPEDEF :: 0x16; VDW_TAG_UNION_TYPE :: 0x17;
VDW_TAG_VARIANT :: 0x19; VDW_TAG_INHERITANCE :: 0x1c; VDW_TAG_PTR_TO_MEMBER_TYPE :: 0x1f; VDW_TAG_SET_TYPE :: 0x20;
VDW_TAG_SUBRANGE_TYPE :: 0x21; VDW_TAG_CONST_TYPE :: 0x26; VDW_TAG_FRIEND :: 0x2a; VDW_TAG_NAMELIST :: 0x2b;
VDW_TAG_TEMPLATE_TYPE_PARAMETER :: 0x2f; VDW_TAG_VARIANT_PART :: 0x33; VDW_TAG_VARIABLE :: 0x34;
VDW_TAG_VOLATILE_TYPE :: 0x35; VDW_TAG_RESTRICT_TYPE :: 0x37; VDW_TAG_IMPORTED_MODULE :: 0x3a; VDW_TAG_UNSPECIFIED_TYPE :: 0x3b;
VDW_TAG_RVALUE_REFERENCE_TYPE :: 0x42; VDW_TAG_TEMPLATE_ALIAS :: 0x43; VDW_TAG_ATOMIC_TYPE :: 0x47; VDW_TAG_IMMUTABLE_TYPE :: 0x4b;
VDW_TAG_GNU_TEMPLATE_TEMPLATE_PARAM :: 0x4106; VDW_TAG_GNU_TEMPLATE_PARAMETER_PACK :: 0x4107;
VDW_ATE_BOOLEAN :: 0x02; VDW_ATE_SIGNED :: 0x05; VDW_ATE_SIGNED_CHAR :: 0x06; VDW_ATE_UNSIGNED :: 0x07; VDW_ATE_UNSIGNED_CHAR :: 0x08;

DI_FLAG_ARTIFICIAL :: 1 << 6; DI_FLAG_VECTOR :: 1 << 11; DI_FLAG_STATIC_MEMBER :: 1 << 12;
DI_FLAG_LVALUE_REFERENCE :: 1 << 13; DI_FLAG_RVALUE_REFERENCE :: 1 << 14; DI_FLAG_TYPE_PASS_BY_VALUE :: 1 << 22;
DI_FLAG_TYPE_PASS_BY_REFERENCE :: 1 << 23; DI_FLAG_ALL_CALLS_DESCRIBED :: 1 << 29;

di_type_tag :: (m: Md_Id) -> u64 {
    k := di_kind(m);
    if k == .BASIC_TYPE || k == .DERIVED_TYPE || k == .COMPOSITE_TYPE || k == .IMPORTED_ENTITY || k == .TEMPLATE_VALUE_PARAMETER return di_int(m, 0);
    if k == .SUBROUTINE_TYPE return VDW_TAG_SUBROUTINE_TYPE;
    return 0;
}
di_type_line :: (m: Md_Id) -> u64 {
    k := di_kind(m);
    if k == .BASIC_TYPE || k == .DERIVED_TYPE || k == .COMPOSITE_TYPE return di_int(m, 1);
    return 0;
}
di_type_flags :: (m: Md_Id) -> u64 {
    k := di_kind(m);
    if k == .BASIC_TYPE return di_int(m, 6);
    if k == .DERIVED_TYPE return di_int(m, 4);
    if k == .COMPOSITE_TYPE return di_int(m, 6);
    if k == .SUBROUTINE_TYPE return di_int(m, 0);
    return 0;
}
di_has_conflicting_reference_flags :: (f: u64) -> bool {
    return ((f & DI_FLAG_LVALUE_REFERENCE) && (f & DI_FLAG_RVALUE_REFERENCE)) || ((f & DI_FLAG_TYPE_PASS_BY_VALUE) && (f & DI_FLAG_TYPE_PASS_BY_REFERENCE));
}

// DILocalScope::getSubprogram (careful with broken scope chains, like the Verifier's getSubprogram)
vf_di_local_scope_subprogram :: (s_in: Md_Id) -> Md_Id {
    s := s_in;
    for 1..10000 {
        if s == NONE return NONE;
        if is_di(s, .SUBPROGRAM) return s;
        if is_di(s, .LEXICAL_BLOCK) || is_di(s, .LEXICAL_BLOCK_FILE) { s = di_op(s, 1); continue; }
        return NONE;
    }
    return NONE;
}
// DILocation::getInlinedAtScope
di_location_inlined_at_scope :: (loc_in: Md_Id) -> Md_Id {
    loc := loc_in;
    for 1..10000 {
        ia := di_op(loc, 1);
        if !is_di(ia, .LOCATION) break;
        loc = ia;
    }
    return di_op(loc, 0);
}
// DISubprogram::describes(F): F->getSubprogram() == this
di_subprogram_describes :: (sp: Md_Id, f: Value_Id) -> bool { return sp != NONE && get_metadata(f, 0) == sp; }

// ---------------------------------------------------------------- generic metadata

vf_visit_named_md :: (nmi: s64) {
    nm := *ir.named_md[nmi];
    if begins_with(nm.name, "llvm.dbg.")
        vcheck_di(nm.name == "llvm.dbg.cu", "unrecognized named metadata node in the llvm.dbg namespace", vq_nmd(nmi));
    for m: nm.ops {
        if nm.name == "llvm.dbg.cu" vcheck_di(m != NONE && is_di(m, .COMPILE_UNIT), "invalid compile unit", vq_nmd(nmi), vq_md(m));
        if m == NONE continue;
        vf_visit_md_node(m, true);
    }
}

// Verifier::visitMDNode: breadth first over the operands; each node once per run
vf_visit_md_node :: (base: Md_Id, allow_locs: bool) {
    if !md_seen_insert(base) return;
    queue: [..] Md_Id; queue.allocator = temp;
    array_add(*queue, base);
    qi := 0;
    while qi < queue.count {
        cur := queue[qi];
        qi += 1;
        r := ir.mds[cur];
        if r.kind == .SPECIAL vf_visit_di_node(cur);
        for k: 0..cast(s64) r.nops - 1 {
            o := ir.md_ops[r.ops + cast(u32) k];
            if o == NONE continue;
            vcheck(!md_is_local(o), "Invalid operand for global metadata!", vq_md(cur), vq_md(o));
            vcheck_di(!is_di(o, .LOCATION) || allow_locs, "DILocation not allowed within this metadata node", vq_md(cur), vq_md(o));
            if is_md_node(o) {
                if md_seen_insert(o) array_add(*queue, o);
                continue;
            }
            if md_is_value(o) { vf_visit_value_as_metadata(o, NONE); continue; }
        }
        // llvm.loop.estimated_trip_count
        if r.nops > 0 && md_is_string(md_op(cur, 0)) && ir.mds[md_op(cur, 0)].str == "llvm.loop.estimated_trip_count" {
            vcheck(r.nops == 2, "Expected two operands", vq_md(cur));
            c := md_op(cur, 1);
            vcheck(md_is_constant(c) && is_int_type(vtype(ir.mds[c].value)) && type_int_width(vtype(ir.mds[c].value)) <= 32,
                "Expected second operand to be an integer constant of type i32 or smaller", vq_md(cur));
        }
        // temporaries and unresolved nodes can't come out of the parser
    }
}

vf_visit_value_as_metadata :: (m: Md_Id, f: Value_Id) {
    v := ir.mds[m].value;
    vcheck(v != NONE, "Expected valid value", vq_md(m));
    vcheck(type_kind(vtype(v)) != .METADATA, "Unexpected metadata round-trip through values", vq_md(m), vq_val(v));
    if !md_is_local(m) return;
    vcheck(f != NONE, "function-local metadata used outside a function", vq_md(m));
    actual: Value_Id = NONE;
    k := vkind(v);
    if k == .INST {
        b := inst(v).parent;
        vcheck(b != NONE, "function-local metadata not in basic block", vq_md(m), vq_val(v));
        actual = block(b).parent;
    } else if k == .BLOCK {
        actual = block(v).parent;
    } else if k == .ARGUMENT {
        actual = arg_parent(v);
    }
    vcheck(actual == f, "function-local metadata used in wrong function", vq_md(m));
}

vf_visit_di_arg_list :: (m: Md_Id, f: Value_Id) {
    for k: 0..cast(s64) ir.mds[m].nops - 1 {
        a := md_op(m, cast(u32) k);
        if md_is_value(a) vf_visit_value_as_metadata(a, f);
    }
}

vf_visit_metadata_as_value :: (m: Md_Id, f: Value_Id) {
    if m == NONE return;
    if is_md_node(m) { vf_visit_md_node(m, false); return; }
    if !md_seen_insert(m) return;
    if md_is_value(m) vf_visit_value_as_metadata(m, f);
    if is_di(m, .ARG_LIST) vf_visit_di_arg_list(m, f);
}

// ---------------------------------------------------------------- debug info nodes

vf_visit_di_node :: (n: Md_Id) {
    k := di_kind(n);
    if k == {
      case .LOCATION; vf_visit_di_location(n);
      case .EXPRESSION; vf_visit_di_expression(n);
      case .GLOBAL_VARIABLE_EXPRESSION; vf_visit_di_global_variable_expression(n);
      case .FILE; vf_visit_di_file(n);
      case .COMPILE_UNIT; vf_visit_di_compile_unit(n);
      case .SUBPROGRAM; vf_visit_di_subprogram(n);
      case .SUBROUTINE_TYPE; vf_visit_di_subroutine_type(n);
      case .BASIC_TYPE; vf_visit_di_basic_type(n);
      case .DERIVED_TYPE; vf_visit_di_derived_type(n);
      case .COMPOSITE_TYPE; vf_visit_di_composite_type(n);
      case .LOCAL_VARIABLE; vf_visit_di_local_variable(n);
      case .GLOBAL_VARIABLE; vf_visit_di_global_variable(n);
      case .LEXICAL_BLOCK; vf_visit_di_lexical_block(n);
      case .LEXICAL_BLOCK_FILE; vf_visit_di_lexical_block_base(n);
      case .NAMESPACE; vf_visit_di_namespace(n);
      case .SUBRANGE; vf_visit_di_subrange(n);
      case .LABEL; vf_visit_di_label(n);
      case .ASSIGN_ID; vf_visit_di_assign_id(n);
      case .ARG_LIST;   // not an MDNode
      case .IMPORTED_ENTITY; vf_visit_di_imported_entity(n);
      case .TEMPLATE_TYPE_PARAMETER; vf_visit_di_template_parameter(n);   // tag is always DW_TAG_template_type_parameter
      case .TEMPLATE_VALUE_PARAMETER; vf_visit_di_template_value_parameter(n);
    }
}

vf_visit_di_location :: (n: Md_Id) {
    s := di_op(n, 0);
    vcheck_di(s != NONE && di_is_local_scope(s), "location requires a valid scope", vq_md(n), vq_md(s));
    ia := di_op(n, 1);
    if ia != NONE vcheck_di(is_di(ia, .LOCATION), "inlined-at should be a location", vq_md(n), vq_md(ia));
    if is_di(s, .SUBPROGRAM) vcheck_di((di_int(s, 5) & SPFLAG_DEFINITION) != 0, "scope points into the type hierarchy", vq_md(n));
}

vf_visit_di_scope :: (n: Md_Id) {
    f := di_op(n, 0);
    if f != NONE vcheck_di(is_di(f, .FILE), "invalid file", vq_md(n), vq_md(f));
}

// visitDIType; returns false when one of its checks failed (the caller's CheckDI-free code still runs in LLVM,
// since visitDIType is a separate method)
vf_visit_di_type :: (n: Md_Id) {
    s := di_op(n, 1);
    vcheck_di(vf_is_scope(s), "invalid scope", vq_md(n), vq_md(s));
    vf_visit_di_scope(n);
    vcheck_di(di_op(n, 0) != NONE || di_type_line(n) == 0, "line specified with no file", vq_md(n), vq_uint(di_type_line(n)));
}

vf_visit_di_subrange :: (n: Md_Id) {
    count := di_op(n, 0); lb := di_op(n, 1); ub := di_op(n, 2); stride := di_op(n, 3);
    vcheck_di(count == NONE || ub == NONE, "Subrange can have any one of count or upperBound", vq_md(n));
    valid :: (m: Md_Id) -> bool { return m == NONE || md_is_constant(m) || di_is_variable(m) || is_di(m, .EXPRESSION); }
    vcheck_di(valid(count), "Count must be signed constant or DIVariable or DIExpression", vq_md(n));
    // getCount(): a ConstantInt count must be >= -1
    if md_is_constant(count) && vkind(ir.mds[count].value) == .C_INT
        vcheck_di(const_int_sext(ir.mds[count].value) >= -1, "invalid subrange count", vq_md(n));
    vcheck_di(valid(lb), "LowerBound must be signed constant or DIVariable or DIExpression", vq_md(n));
    vcheck_di(valid(ub), "UpperBound must be signed constant or DIVariable or DIExpression", vq_md(n));
    vcheck_di(valid(stride), "Stride must be signed constant or DIVariable or DIExpression", vq_md(n));
}

vf_visit_di_basic_type :: (n: Md_Id) {
    vf_visit_di_type(n);
    tag := di_int(n, 0);
    vcheck_di(tag == DW_TAG_BASE_TYPE || tag == VDW_TAG_UNSPECIFIED_TYPE || tag == VDW_TAG_STRING_TYPE, "invalid tag", vq_md(n));
    sz := di_op(n, 3);
    vcheck_di(sz == NONE || md_is_constant(sz), "SizeInBits must be a constant");
}

vf_visit_di_derived_type :: (n: Md_Id) {
    vf_visit_di_type(n);
    tag := di_int(n, 0);
    flags := di_int(n, 4);
    vcheck_di(tag == VDW_TAG_TYPEDEF || tag == VDW_TAG_POINTER_TYPE || tag == VDW_TAG_PTR_TO_MEMBER_TYPE || tag == VDW_TAG_REFERENCE_TYPE ||
        tag == VDW_TAG_RVALUE_REFERENCE_TYPE || tag == VDW_TAG_CONST_TYPE || tag == VDW_TAG_IMMUTABLE_TYPE || tag == VDW_TAG_VOLATILE_TYPE ||
        tag == VDW_TAG_RESTRICT_TYPE || tag == VDW_TAG_ATOMIC_TYPE || tag == DW_TAG_LLVM_PTRAUTH_TYPE || tag == VDW_TAG_MEMBER ||
        (tag == VDW_TAG_VARIABLE && (flags & DI_FLAG_STATIC_MEMBER) != 0) || tag == VDW_TAG_INHERITANCE || tag == VDW_TAG_FRIEND ||
        tag == VDW_TAG_SET_TYPE || tag == VDW_TAG_TEMPLATE_ALIAS, "invalid tag", vq_md(n));
    extra := di_op(n, 6);
    if tag == VDW_TAG_PTR_TO_MEMBER_TYPE {
        vcheck_di(vf_is_type(extra), "invalid pointer to member type", vq_md(n), vq_md(extra));
    } else if tag == VDW_TAG_TEMPLATE_ALIAS {
        vcheck_di(vf_is_md_tuple(extra), "invalid template parameters", vq_md(n), vq_md(extra));
    } else if tag == VDW_TAG_INHERITANCE || tag == VDW_TAG_MEMBER || tag == VDW_TAG_VARIABLE {
        valid := true;
        if extra != NONE {
            valid = md_is_constant(extra) || md_is_string(extra);
            if !valid && md_is_tuple(extra) valid = vf_md_nops(extra) == 1 && md_is_constant(md_op(extra, 0));
        }
        vcheck_di(valid, "extraData must be ConstantAsMetadata, MDString, DIObjCProperty, or MDTuple with single ConstantAsMetadata operand", vq_md(n), vq_md(extra));
    }
    base := di_op(n, 5);
    if tag == VDW_TAG_SET_TYPE && base != NONE {
        ok := false;
        if is_di(base, .COMPOSITE_TYPE) ok = di_int(base, 0) == VDW_TAG_ENUMERATION_TYPE;
        if is_di(base, .BASIC_TYPE) { e := di_int(base, 3); ok = e == VDW_ATE_UNSIGNED || e == VDW_ATE_SIGNED || e == VDW_ATE_UNSIGNED_CHAR || e == VDW_ATE_SIGNED_CHAR || e == VDW_ATE_BOOLEAN; }
        vcheck_di(ok, "invalid set base type", vq_md(n), vq_md(base));
    }
    vcheck_di(vf_is_type(base), "invalid base type", vq_md(n), vq_md(base));
    // dwarfAddressSpace: UINT32_MAX = none
    if di_int(n, 3) != 0xFFFF_FFFF
        vcheck_di(tag == VDW_TAG_POINTER_TYPE || tag == VDW_TAG_REFERENCE_TYPE || tag == VDW_TAG_RVALUE_REFERENCE_TYPE,
            "DWARF address space only applies to pointer or reference types", vq_md(n));
    sz := di_op(n, 3);
    vcheck_di(sz == NONE || md_is_constant(sz) || di_is_variable(sz) || is_di(sz, .EXPRESSION), "SizeInBits must be a constant or DIVariable or DIExpression");
}

vf_visit_template_params :: (n: Md_Id, params: Md_Id) {
    vcheck_di(md_is_tuple(params), "invalid template params", vq_md(n), vq_md(params));
    for k: 0..cast(s64) vf_md_nops(params) - 1 {
        o := md_op(params, cast(u32) k);
        vcheck_di(o != NONE && (is_di(o, .TEMPLATE_TYPE_PARAMETER) || is_di(o, .TEMPLATE_VALUE_PARAMETER)), "invalid template parameter", vq_md(n), vq_md(params), vq_md(o));
    }
}

vf_visit_di_composite_type :: (n: Md_Id) {
    vf_visit_di_type(n);
    tag := di_int(n, 0);
    flags := di_int(n, 6);
    vcheck_di(tag == VDW_TAG_ARRAY_TYPE || tag == VDW_TAG_STRUCTURE_TYPE || tag == VDW_TAG_UNION_TYPE || tag == VDW_TAG_ENUMERATION_TYPE ||
        tag == VDW_TAG_CLASS_TYPE || tag == VDW_TAG_VARIANT_PART || tag == VDW_TAG_VARIANT || tag == VDW_TAG_NAMELIST, "invalid tag", vq_md(n));
    base := di_op(n, 5);
    vcheck_di(vf_is_type(base), "invalid base type", vq_md(n), vq_md(base));
    elems := di_op(n, 6);
    vcheck_di(elems == NONE || md_is_tuple(elems), "invalid composite elements", vq_md(n), vq_md(elems));
    vt := di_op(n, 7);
    vcheck_di(vf_is_type(vt), "invalid vtable holder", vq_md(n), vq_md(vt));
    vcheck_di(!di_has_conflicting_reference_flags(flags), "invalid reference flags", vq_md(n));
    vcheck_di((flags & (1 << 4)) == 0, "DIBlockByRefStruct on DICompositeType is no longer supported", vq_md(n));
    // getElements(): a DINodeArray (cast_or_null<MDTuple>)
    all_nonnull := true;
    if md_is_tuple(elems) for k: 0..cast(s64) vf_md_nops(elems) - 1 if md_op(elems, cast(u32) k) == NONE { all_nonnull = false; break; }
    vcheck_di(all_nonnull, "DISubprogram contains null entry in `elements` field", vq_md(n));
    if flags & DI_FLAG_VECTOR {
        ok := md_is_tuple(elems) && vf_md_nops(elems) == 1 && is_di(md_op(elems, 0), .SUBRANGE);
        vcheck_di(ok, "invalid vector, expected one element of type subrange", vq_md(n));
    }
    tp := di_op(n, 8);
    if tp != NONE vf_visit_template_params(n, tp);
    d := di_op(n, 10);
    if d != NONE vcheck_di(is_di(d, .DERIVED_TYPE) && tag == VDW_TAG_VARIANT_PART, "discriminator can only appear on variant part");
    if di_op(n, 11) != NONE vcheck_di(tag == VDW_TAG_ARRAY_TYPE, "dataLocation can only appear in array type");
    if di_op(n, 12) != NONE vcheck_di(tag == VDW_TAG_ARRAY_TYPE, "associated can only appear in array type");
    if di_op(n, 13) != NONE vcheck_di(tag == VDW_TAG_ARRAY_TYPE, "allocated can only appear in array type");
    if di_op(n, 14) != NONE vcheck_di(tag == VDW_TAG_ARRAY_TYPE, "rank can only appear in array type");
    if tag == VDW_TAG_ARRAY_TYPE vcheck_di(base != NONE, "array types must have a base type", vq_md(n));
    sz := di_op(n, 3);
    vcheck_di(sz == NONE || md_is_constant(sz) || di_is_variable(sz) || is_di(sz, .EXPRESSION), "SizeInBits must be a constant or DIVariable or DIExpression");
}

vf_visit_di_subroutine_type :: (n: Md_Id) {
    vf_visit_di_type(n);
    types := di_op(n, 5);
    if types != NONE {
        vcheck_di(md_is_tuple(types), "invalid composite elements", vq_md(n), vq_md(types));
        for k: 0..cast(s64) vf_md_nops(types) - 1 {
            t := md_op(types, cast(u32) k);
            vcheck_di(vf_is_type(t), "invalid subroutine type ref", vq_md(n), vq_md(types), vq_md(t));
        }
    }
    vcheck_di(!di_has_conflicting_reference_flags(di_int(n, 0)), "invalid reference flags", vq_md(n));
}

vf_visit_di_file :: (n: Md_Id) {
    cs := di_op(n, 2);
    if cs == NONE return;
    kind := di_int(n, 0);
    vcheck_di(kind >= 1 && kind <= 3, "invalid checksum kind", vq_md(n));
    size: s64 = ifx kind == 1 then 32 else ifx kind == 2 then 40 else 64;
    s := ir.mds[cs].str;
    vcheck_di(s.count == size, "invalid checksum length", vq_md(n));
    ok := true;
    for c: cast([] u8) s if !((c >= #char "0" && c <= #char "9") || (c >= #char "a" && c <= #char "f") || (c >= #char "A" && c <= #char "F")) { ok = false; break; }
    vcheck_di(ok, "invalid checksum", vq_md(n));
}

vf_visit_di_compile_unit :: (n: Md_Id) {
    vcheck_di(ir.mds[n].distinct, "compile units must be distinct", vq_md(n));
    file := di_op(n, 0);
    vcheck_di(file != NONE && is_di(file, .FILE), "invalid file", vq_md(n), vq_md(file));
    vcheck_di(md_str_of(di_op(file, 0)).count > 0, "invalid filename", vq_md(n), vq_md(file));
    vcheck_di(di_int(n, 6) <= 3, "invalid emission kind", vq_md(n));
    vcheck_di(di_int(n, 2) <= 2, "invalid language dialect", vq_md(n));
    enums := di_op(n, 4);
    if enums != NONE {
        vcheck_di(md_is_tuple(enums), "invalid enum list", vq_md(n), vq_md(enums));
        for k: 0..cast(s64) vf_md_nops(enums) - 1 {
            o := md_op(enums, cast(u32) k);
            vcheck_di(is_di(o, .COMPOSITE_TYPE) && di_int(o, 0) == VDW_TAG_ENUMERATION_TYPE, "invalid enum type", vq_md(n), vq_md(enums), vq_md(o));
            sc := di_op(o, 1);
            vcheck_di(sc == NONE || !di_is_local_scope(sc), "function-local enum in a DICompileUnit's enum list", vq_md(n), vq_md(enums), vq_md(o));
        }
    }
    rt := di_op(n, 5);
    if rt != NONE {
        vcheck_di(md_is_tuple(rt), "invalid retained type list", vq_md(n), vq_md(rt));
        for k: 0..cast(s64) vf_md_nops(rt) - 1 {
            o := md_op(rt, cast(u32) k);
            vcheck_di(o != NONE && (vf_di_is_type(o) || (is_di(o, .SUBPROGRAM) && !(di_int(o, 5) & SPFLAG_DEFINITION))), "invalid retained type", vq_md(n), vq_md(o));
        }
    }
    gvs := di_op(n, 6);
    if gvs != NONE {
        vcheck_di(md_is_tuple(gvs), "invalid global variable list", vq_md(n), vq_md(gvs));
        for k: 0..cast(s64) vf_md_nops(gvs) - 1 {
            o := md_op(gvs, cast(u32) k);
            vcheck_di(is_di(o, .GLOBAL_VARIABLE_EXPRESSION), "invalid global variable ref", vq_md(n), vq_md(o));
            var := di_op(o, 0);
            sc := ifx var != NONE then di_op(var, 0) else NONE;
            vcheck_di(!di_is_local_scope(sc), "function-local variables are not allowed in a DICompileUnit's global variables list", vq_md(n), vq_md(o));
        }
    }
    ims := di_op(n, 7);
    if ims != NONE {
        vcheck_di(md_is_tuple(ims), "invalid imported entity list", vq_md(n), vq_md(ims));
        for k: 0..cast(s64) vf_md_nops(ims) - 1 {
            o := md_op(ims, cast(u32) k);
            vcheck_di(is_di(o, .IMPORTED_ENTITY), "invalid imported entity ref", vq_md(n), vq_md(o));
            vcheck_di(!di_is_local_scope(di_op(o, 0)), "function-local imports are not allowed in a DICompileUnit's imported entities list", vq_md(n), vq_md(o));
        }
    }
    macros := di_op(n, 8);
    if macros != NONE {
        vcheck_di(md_is_tuple(macros), "invalid macro list", vq_md(n), vq_md(macros));
        for k: 0..cast(s64) vf_md_nops(macros) - 1 {
            o := md_op(macros, cast(u32) k);
            vcheck_di(false, "invalid macro ref", vq_md(n), vq_md(o));   // DIMacroNode is not supported by our parser
        }
    }
    for vf.cu_visited if it == n return;
    array_add(*vf.cu_visited, n);
}

// verifyCompileUnits: every visited DICompileUnit is listed in llvm.dbg.cu (not checked with ODR type uniquing,
// which opt enables unless --disable-debug-info-type-map: types may then point into another module's CU)
vf_verify_compile_units :: () {
    defer vf.cu_visited.count = 0;
    if odr_uniquing_debug_types return;
    k := vf_named_md_index("llvm.dbg.cu");
    for cu: vf.cu_visited {
        listed := false;
        if k >= 0 for ir.named_md[k].ops if it == cu { listed = true; break; }
        vcheck_di(listed, "DICompileUnit not listed in llvm.dbg.cu", vq_md(cu));
    }
}

// getRawRetainedNodeScope: the scope of a local variable / label / imported entity / type / global variable expression
di_retained_node_scope :: (m: Md_Id) -> Md_Id {
    k := di_kind(m);
    if k == .LOCAL_VARIABLE || k == .LABEL || k == .IMPORTED_ENTITY return di_op(m, 0);
    if vf_di_is_type(m) return di_op(m, 1);
    if k == .GLOBAL_VARIABLE_EXPRESSION { v := di_op(m, 0); if v != NONE return di_op(v, 0); return NONE; }
    return NONE;
}

vf_visit_di_subprogram :: (n: Md_Id) {
    vcheck_di(vf_is_scope(di_op(n, 1)), "invalid scope", vq_md(n), vq_md(di_op(n, 1)));
    file := di_op(n, 0);
    if file != NONE vcheck_di(is_di(file, .FILE), "invalid file", vq_md(n), vq_md(file));
    else vcheck_di(di_int(n, 0) == 0, "line specified with no file", vq_md(n), vq_uint(di_int(n, 0)));
    t := di_op(n, 4);
    vcheck_di(t != NONE, "DISubprogram requires a non-null type", vq_md(n));
    vcheck_di(is_di(t, .SUBROUTINE_TYPE), "invalid subroutine type", vq_md(n), vq_md(t));
    ct := di_op(n, 8);
    vcheck_di(vf_is_type(ct), "invalid containing type", vq_md(n), vq_md(ct));
    tp := di_op(n, 9);
    if tp != NONE vf_visit_template_params(n, tp);
    decl := di_op(n, 6);
    if decl != NONE vcheck_di(is_di(decl, .SUBPROGRAM) && !(di_int(decl, 5) & SPFLAG_DEFINITION), "invalid subprogram declaration", vq_md(n), vq_md(decl));
    rn := di_op(n, 7);
    if rn != NONE {
        vcheck_di(md_is_tuple(rn), "invalid retained nodes list", vq_md(n), vq_md(rn));
        Arg_Entry :: struct { arg: u64; var: Md_Id; }
        args: [..] Arg_Entry; args.allocator = temp;
        for k: 0..cast(s64) vf_md_nops(rn) - 1 {
            o := md_op(rn, cast(u32) k);
            vcheck_di(o != NONE, "nullptr in retained nodes", vq_md(n), vq_md(rn));
            ok := is_di(o, .LOCAL_VARIABLE) || is_di(o, .LABEL) || is_di(o, .IMPORTED_ENTITY) || vf_di_is_type(o) || is_di(o, .GLOBAL_VARIABLE_EXPRESSION);
            vcheck_di(ok, "invalid retained nodes, expected DILocalVariable, DILabel, DIImportedEntity, DIType or DIGlobalVariableExpression", vq_md(n), vq_md(rn), vq_md(o));
            scope := di_retained_node_scope(o);
            if !di_is_local_scope(scope) scope = NONE;
            vcheck_di(scope != NONE, "invalid retained nodes, retained node is not local", vq_md(n), vq_md(rn), vq_md(o));
            rsp := vf_di_local_scope_subprogram(scope);
            unit := ifx rsp != NONE then di_op(rsp, 5) else NONE;
            vcheck_di(rsp == n, "invalid retained nodes, retained node does not belong to subprogram", vq_md(n), vq_md(rn), vq_md(o), vq_md(scope), vq_md(rsp), vq_md(unit));
            if !is_di(o, .LOCAL_VARIABLE) continue;
            argno := di_int(o, 1);
            if argno {
                prev: Md_Id = NONE;
                for args if it.arg == argno { prev = it.var; break; }
                if prev == NONE { array_add(*args, .{argno, o}); prev = o; }
                vcheck_di(prev == o, "invalid retained nodes, more than one local variable with the same argument index", vq_md(n), vq_md(di_op(n, 5)), vq_md(rn), vq_md(o), vq_md(prev));
            }
        }
    }
    flags := di_int(n, 4);
    vcheck_di(!di_has_conflicting_reference_flags(flags), "invalid reference flags", vq_md(n));
    unit := di_op(n, 5);
    is_def := (di_int(n, 5) & SPFLAG_DEFINITION) != 0;
    if is_def {
        vcheck_di(ir.mds[n].distinct, "subprogram definitions must be distinct", vq_md(n));
        vcheck_di(unit != NONE, "subprogram definitions must have a compile unit", vq_md(n));
        vcheck_di(is_di(unit, .COMPILE_UNIT), "invalid unit type", vq_md(n), vq_md(unit));
        sc := di_op(n, 1);
        if is_di(sc, .COMPOSITE_TYPE) && di_op(sc, 9) != NONE && odr_uniquing_debug_types
            vcheck_di(is_di(decl, .SUBPROGRAM), "definition subprograms cannot be nested within DICompositeType when enabling ODR", vq_md(n));
    } else {
        vcheck_di(unit == NONE, "subprogram declarations must not have a compile unit", vq_md(n));
        vcheck_di(decl == NONE, "subprogram declaration must not have a declaration field");
    }
    tt := di_op(n, 10);
    if tt != NONE {
        vcheck_di(md_is_tuple(tt), "invalid thrown types list", vq_md(n), vq_md(tt));
        for k: 0..cast(s64) vf_md_nops(tt) - 1 {
            o := md_op(tt, cast(u32) k);
            vcheck_di(o != NONE && vf_di_is_type(o), "invalid thrown type", vq_md(n), vq_md(tt), vq_md(o));
        }
    }
    if flags & DI_FLAG_ALL_CALLS_DESCRIBED vcheck_di(is_def, "DIFlagAllCallsDescribed must be attached to a definition");
}

vf_visit_di_lexical_block_base :: (n: Md_Id) {
    s := di_op(n, 1);
    vcheck_di(s != NONE && di_is_local_scope(s), "invalid local scope", vq_md(n), vq_md(s));
    if is_di(s, .SUBPROGRAM) vcheck_di((di_int(s, 5) & SPFLAG_DEFINITION) != 0, "scope points into the type hierarchy", vq_md(n));
}
vf_visit_di_lexical_block :: (n: Md_Id) {
    vf_visit_di_lexical_block_base(n);
    vcheck_di(di_int(n, 0) != 0 || di_int(n, 1) == 0, "cannot have column info without line info", vq_md(n));
}

vf_visit_di_namespace :: (n: Md_Id) {
    s := di_op(n, 1);
    if s != NONE vcheck_di(di_is_scope(s), "invalid scope ref", vq_md(n), vq_md(s));
}

vf_visit_di_template_parameter :: (n: Md_Id) {
    t := di_op(n, 1);
    vcheck_di(vf_is_type(t), "invalid type ref", vq_md(n), vq_md(t));
}
vf_visit_di_template_value_parameter :: (n: Md_Id) {
    vf_visit_di_template_parameter(n);
    tag := di_int(n, 0);
    vcheck_di(tag == DW_TAG_TEMPLATE_VALUE_PARAMETER || tag == VDW_TAG_GNU_TEMPLATE_TEMPLATE_PARAM || tag == VDW_TAG_GNU_TEMPLATE_PARAMETER_PACK, "invalid tag", vq_md(n));
}

vf_visit_di_variable :: (n: Md_Id) {
    s := di_op(n, 0);
    if s != NONE vcheck_di(di_is_scope(s), "invalid scope", vq_md(n), vq_md(s));
    f := di_op(n, 2);
    if f != NONE vcheck_di(is_di(f, .FILE), "invalid file", vq_md(n), vq_md(f));
}

vf_visit_di_global_variable :: (n: Md_Id) {
    vf_visit_di_variable(n);
    t := di_op(n, 3);
    vcheck_di(vf_is_type(t), "invalid type ref", vq_md(n), vq_md(t));
    if di_int(n, 2) vcheck_di(t != NONE && vf_di_is_type(t), "missing global variable type", vq_md(n));
    m := di_op(n, 6);
    if m != NONE vcheck_di(is_di(m, .DERIVED_TYPE), "invalid static data member declaration", vq_md(n), vq_md(m));
}

vf_visit_di_local_variable :: (n: Md_Id) {
    vf_visit_di_variable(n);
    t := di_op(n, 3);
    vcheck_di(vf_is_type(t), "invalid type ref", vq_md(n), vq_md(t));
    s := di_op(n, 0);
    vcheck_di(s != NONE && di_is_local_scope(s), "local variable requires a valid scope", vq_md(n), vq_md(s));
    if t != NONE && vf_di_is_type(t) vcheck_di(!is_di(t, .SUBROUTINE_TYPE), "invalid type", vq_md(n), vq_md(t));
}

vf_visit_di_assign_id :: (n: Md_Id) {
    vcheck_di(vf_md_nops(n) == 0, "DIAssignID has no arguments", vq_md(n));
    vcheck_di(ir.mds[n].distinct, "DIAssignID must be distinct", vq_md(n));
}

vf_visit_di_label :: (n: Md_Id) {
    s := di_op(n, 0);
    if s != NONE vcheck_di(di_is_scope(s), "invalid scope", vq_md(n), vq_md(s));
    f := di_op(n, 2);
    if f != NONE vcheck_di(is_di(f, .FILE), "invalid file", vq_md(n), vq_md(f));
    vcheck_di(s != NONE && di_is_local_scope(s), "label requires a valid scope", vq_md(n), vq_md(s));
}

vf_visit_di_expression :: (n: Md_Id) {
    e: [] u64; e.data = ir.md_ints.data + ir.mds[n].ints; e.count = ir.mds[n].nints;
    vcheck_di(di_expression_valid(e), "invalid expression", vq_md(n));
}

vf_visit_di_global_variable_expression :: (gve: Md_Id) {
    var := di_op(gve, 0);
    vcheck_di(var != NONE && is_di(var, .GLOBAL_VARIABLE), "missing variable");
    vf_visit_di_global_variable(var);
    ex := di_op(gve, 1);
    if is_di(ex, .EXPRESSION) {
        vf_visit_di_expression(ex);
        ok, off, size := diexpr_fragment(ex);
        if ok vf_verify_fragment_expression_var(var, off, size, vq_md(gve));
    }
}

vf_visit_di_imported_entity :: (n: Md_Id) {
    tag := di_int(n, 0);
    vcheck_di(tag == VDW_TAG_IMPORTED_MODULE || tag == VDW_TAG_IMPORTED_DECLARATION, "invalid tag", vq_md(n));
    s := di_op(n, 0);
    if s != NONE vcheck_di(di_is_scope(s), "invalid scope for imported entity", vq_md(n), vq_md(s));
    e := di_op(n, 1);
    vcheck_di(vf_is_dinode(e), "invalid imported entity", vq_md(n), vq_md(e));
}

// verifyFragmentExpression(const DIVariable &V, FragmentInfo, Desc)
vf_verify_fragment_expression_var :: (var: Md_Id, off: u64, size: u64, desc: VArg) {
    ok, var_size := divar_size_bits(var);
    if !ok return;
    vcheck_di(size + off <= var_size, "fragment is larger than or outside of variable", desc, vq_md(var));
    vcheck_di(size != var_size, "fragment covers entire variable", desc, vq_md(var));
}

// ---------------------------------------------------------------- debug records

vf_visit_dbg_records :: (i: Value_Id) {
    x := inst(i).records;
    if x == 0 return;
    vcheck_di(inst_op(i) != .PHI, "PHI Node must not have any attached DbgRecords", vq_val(i));
    while x != 0 {
        r := *ir.dbg_records[x - 1];
        if is_di(r.dbg, .LOCATION) vf_visit_md_node(r.dbg, true);
        if r.kind == .LABEL {
            vf_visit_dbg_label_record(x);
        } else {
            vf_visit_dbg_variable_record(x);
            vf_verify_fragment_expression_record(x);
            vf_verify_not_entry_value(x);
        }
        x = r.next;
    }
}

vf_record_block :: (rec: u32) -> (Value_Id, Value_Id) {
    r := *ir.dbg_records[rec - 1];
    if r.owner == NONE return NONE, NONE;
    b := inst(r.owner).parent;
    if b == NONE return NONE, NONE;
    return b, block(b).parent;
}

vf_visit_dbg_label_record :: (rec: u32) {
    r := *ir.dbg_records[rec - 1];
    vcheck_di(is_di(r.loc, .LABEL), "invalid #dbg_label intrinsic variable", vq_rec(rec), vq_md(r.loc));
    if r.dbg != NONE && !is_di(r.dbg, .LOCATION) return;
    bb, f := vf_record_block(rec);
    vcheck_di(r.dbg != NONE, "#dbg_label record requires a !dbg attachment", vq_rec(rec), vq_val(bb), vq_val(f));
    label_sp := vf_di_local_scope_subprogram(di_op(r.loc, 0));
    loc_sp := vf_di_local_scope_subprogram(di_op(r.dbg, 0));
    if label_sp == NONE || loc_sp == NONE return;
    vcheck_di(label_sp == loc_sp, "mismatched subprogram between #dbg_label label and !dbg attachment",
        vq_rec(rec), vq_val(bb), vq_val(f), vq_md(r.loc), vq_md(label_sp), vq_md(r.dbg), vq_md(loc_sp));
}

vf_visit_dbg_variable_record :: (rec: u32) {
    r := *ir.dbg_records[rec - 1];
    bb, f := vf_record_block(rec);
    // the record type is always one of value/declare/declare_value/assign here
    md := r.loc;
    vcheck_di(md != NONE && (md_is_value(md) || is_di(md, .ARG_LIST) || (is_md_node(md) && vf_md_nops(md) == 0)),
        "invalid #dbg record address/value", vq_rec(rec), vq_md(md), vq_val(bb), vq_val(f));
    if md_is_value(md) {
        vf_visit_value_as_metadata(md, f);
        if r.kind == .DECLARE {
            t := vtype(ir.mds[md].value);
            vcheck_di(is_ptr_type(t) || is_int_type(t), "location of #dbg_declare must be a pointer or int", vq_rec(rec), vq_md(md), vq_val(bb), vq_val(f));
        }
    } else if is_di(md, .ARG_LIST) {
        vf_visit_di_arg_list(md, f);
    }
    vcheck_di(r.var != NONE && is_di(r.var, .LOCAL_VARIABLE), "invalid #dbg record variable", vq_rec(rec), vq_md(r.var), vq_val(bb), vq_val(f));
    vf_visit_md_node(r.var, false);
    vcheck_di(r.expr != NONE && is_di(r.expr, .EXPRESSION), "invalid #dbg record expression", vq_rec(rec), vq_md(r.expr), vq_val(bb), vq_val(f));
    vf_visit_md_node(r.expr, false);
    if r.kind == .ASSIGN {
        vcheck_di(r.assign_id != NONE && is_di(r.assign_id, .ASSIGN_ID), "invalid #dbg_assign DIAssignID", vq_rec(rec), vq_md(r.assign_id), vq_val(bb), vq_val(f));
        vf_visit_md_node(r.assign_id, false);
        a := r.addr;
        vcheck_di(md_is_value(a) || (is_md_node(a) && vf_md_nops(a) == 0), "invalid #dbg_assign address", vq_rec(rec), vq_md(a), vq_val(bb), vq_val(f));
        if md_is_value(a) vf_visit_value_as_metadata(a, f);
        vcheck_di(r.addr_expr != NONE && is_di(r.addr_expr, .EXPRESSION), "invalid #dbg_assign address expression", vq_rec(rec), vq_md(r.addr_expr), vq_val(bb), vq_val(f));
        vf_visit_md_node(r.addr_expr, false);
        // at::getAssignmentInsts: the instructions with this !DIAssignID are in the same function (one module)
        for g: ir.m_functions for b2: fn_blocks(g) for i2: block_insts(b2) {
            if get_metadata(i2, MDV_DIASSIGNID) != r.assign_id continue;
            vcheck_di(g == f, "inst not in same function as #dbg_assign", vq_val(i2), vq_rec(rec), vq_val(bb), vq_val(f));
        }
    }
    var := r.var;
    vt := di_op(var, 3);
    vcheck_di(vf_is_type(vt), "invalid type ref", vq_md(var), vq_md(vt), vq_val(bb), vq_val(f));
    vcheck_di(r.dbg != NONE && is_di(r.dbg, .LOCATION), "invalid #dbg record DILocation", vq_rec(rec), vq_md(r.dbg), vq_val(bb), vq_val(f));
    var_sp := vf_di_local_scope_subprogram(di_op(var, 0));
    loc_sp := vf_di_local_scope_subprogram(di_op(r.dbg, 0));
    if var_sp == NONE || loc_sp == NONE return;
    vcheck_di(var_sp == loc_sp, "mismatched subprogram between #dbg record variable and DILocation",
        vq_rec(rec), vq_val(bb), vq_val(f), vq_md(var), vq_md(var_sp), vq_md(r.dbg), vq_md(loc_sp), vq_val(bb), vq_val(f));
    vf_verify_fn_args(rec);
}

vf_verify_fragment_expression_record :: (rec: u32) {
    r := *ir.dbg_records[rec - 1];
    v := r.var; e := r.expr;
    if !is_di(v, .LOCAL_VARIABLE) || !is_di(e, .EXPRESSION) return;
    ev: [] u64; ev.data = ir.md_ints.data + ir.mds[e].ints; ev.count = ir.mds[e].nints;
    if !di_expression_valid(ev) return;
    ok, off, size := diexpr_fragment(e);
    if !ok return;
    if di_int(v, 2) & DI_FLAG_ARTIFICIAL return;
    vf_verify_fragment_expression_var(v, off, size, vq_rec(rec));
}

vf_verify_fn_args :: (rec: u32) {
    if !vf.has_debug_info return;
    r := *ir.dbg_records[rec - 1];
    if di_op(r.dbg, 1) != NONE return;   // inlined
    var := r.var;
    vcheck_di(var != NONE, "#dbg record without variable");
    argno := di_int(var, 1);
    if !argno return;
    while vf.debug_fn_args.count < cast(s64) argno array_add(*vf.debug_fn_args, NONE);
    prev := vf.debug_fn_args[argno - 1];
    vf.debug_fn_args[argno - 1] = var;
    vcheck_di(prev == NONE || prev == var, "conflicting debug info for argument", vq_rec(rec), vq_md(prev), vq_md(var));
}

vf_verify_not_entry_value :: (rec: u32) {
    r := *ir.dbg_records[rec - 1];
    e := r.expr;
    if !is_di(e, .EXPRESSION) return;
    ev: [] u64; ev.data = ir.md_ints.data + ir.mds[e].ints; ev.count = ir.mds[e].nints;
    if !di_expression_valid(ev) return;
    if md_is_value(r.loc) {
        v := ir.mds[r.loc].value;
        k := vkind(v);
        if k == .C_UNDEF || k == .C_POISON return;
        if k == .ARGUMENT && arg_has_attr(v, .SwiftAsync) return;
    }
    // DIExpression::isEntryValue: the first operation is DW_OP_LLVM_entry_value
    is_entry := ev.count > 0 && ev[0] == DW_OP_LLVM_ENTRY_VALUE;
    vcheck_di(!is_entry, "Entry values are only allowed in MIR unless they target a swiftasync Argument", vq_rec(rec));
}

// ---------------------------------------------------------------- module-level metadata

vf_named_md_index :: (name: string) -> s64 {
    for ir.named_md if it.name == name return it_index;
    return -1;
}

vf_visit_module_idents :: (name: string, count_msg: string, string_msg: string) {
    k := vf_named_md_index(name);
    if k < 0 return;
    for n: ir.named_md[k].ops {
        vcheck(vf_md_nops(n) == 1, count_msg, vq_md(n));
        o := md_op(n, 0);
        vcheck(md_is_string(o), string_msg, vq_md(o));
    }
}

vf_visit_module_errno_tbaa :: () {
    k := vf_named_md_index("llvm.errno.tbaa");
    if k < 0 return;
    vcheck(ir.named_md[k].ops.count >= 1, "llvm.errno.tbaa must have at least one operand", vq_nmd(k));
    for n: ir.named_md[k].ops vf_visit_tbaa_metadata(NONE, n);
}

// Module::ModFlagBehavior: MFB_ERROR = 1 ... MFB_MIN = 8 (linker.jai)

vf_visit_module_flags :: () {
    k := vf_named_md_index("llvm.module.flags");
    if k < 0 return;
    Seen :: struct { id: Md_Id; op: Md_Id; }
    seen: [..] Seen; seen.allocator = temp;
    reqs: [..] Md_Id; reqs.allocator = temp;
    pauth_platform := false; pauth_version := false;
    init_fini: u64 = 0; init_fini_addr: u64 = 0;
    for mdn: ir.named_md[k].ops {
        vf_visit_module_flag(mdn, *seen, *reqs);
        if vf_md_nops(mdn) != 3 continue;
        fname := md_op(mdn, 1);
        if !md_is_string(fname) continue;
        s := ir.mds[fname].str;
        get :: (s: string, name: string, mdn: Md_Id) -> (bool, u64) {
            if s != name return false, 0;
            c := md_const_int(md_op(mdn, 2));
            if c != NONE return true, const_int_zext(c);
            check_failed(tprint("%: module flag expects integer value", name));
            return false, 0;
        }
        ok, v := get(s, "aarch64-elf-pauthabi-platform", mdn);
        if ok { pauth_platform = true; continue; }
        if s == "aarch64-elf-pauthabi-platform" continue;
        ok, v = get(s, "aarch64-elf-pauthabi-version", mdn);
        if ok { pauth_version = true; continue; }
        if s == "aarch64-elf-pauthabi-version" continue;
        ok, v = get(s, "ptrauth-init-fini", mdn);
        if ok { init_fini = v; continue; }
        if s == "ptrauth-init-fini" continue;
        ok, v = get(s, "ptrauth-init-fini-address-discrimination", mdn);
        if ok init_fini_addr = v;
    }
    vcheck(init_fini == 0 || init_fini == 1, "ptrauth-init-fini must be 0 or 1");
    vcheck(init_fini_addr == 0 || init_fini_addr == 1, "ptrauth-init-fini-address-discrimination must be 0 or 1, if set");
    if init_fini_addr vcheck(init_fini != 0, "ptrauth-init-fini-address-discrimination module flag requires ptrauth-init-fini");
    if pauth_platform != pauth_version
        check_failed("either both or no 'aarch64-elf-pauthabi-platform' and 'aarch64-elf-pauthabi-version' module flags must be present");
    for req: reqs {
        flag := md_op(req, 0);
        val := md_op(req, 1);
        op: Md_Id = NONE;
        for seen if it.id == flag { op = it.op; break; }
        if op == NONE { check_failed("invalid requirement on flag, flag is not present in module", vq_md(flag)); continue; }
        if md_op(op, 2) != val { check_failed("invalid requirement on flag, flag does not have the required value", vq_md(flag)); continue; }
    }
}

vf_visit_module_flag :: (op: Md_Id, seen: *[..] $T, reqs: *[..] Md_Id) {
    vcheck(vf_md_nops(op) == 3, "incorrect number of operands in module flag", vq_md(op));
    b := md_op(op, 0);
    mfb: u64 = 0;
    bc := md_const_int(b);
    if bc != NONE mfb = const_int_zext(bc);
    if !(bc != NONE && mfb >= MFB_ERROR && mfb <= MFB_MIN) {
        vcheck(bc != NONE, "invalid behavior operand in module flag (expected constant integer)", vq_md(b));
        vcheck(false, "invalid behavior operand in module flag (unexpected constant)", vq_md(b));
    }
    id := md_op(op, 1);
    vcheck(md_is_string(id), "invalid ID operand in module flag (expected metadata string)", vq_md(id));
    val := md_op(op, 2);
    if mfb == {
      case MFB_MIN;
        c := md_const_int(val);
        vcheck(c != NONE && !const_int_is_negative(c), "invalid value for 'min' module flag (expected constant non-negative integer)", vq_md(val));
      case MFB_MAX;
        vcheck(md_const_int(val) != NONE, "invalid value for 'max' module flag (expected constant integer)", vq_md(val));
      case MFB_REQUIRE;
        vcheck(is_md_node(val) && vf_md_nops(val) == 2, "invalid value for 'require' module flag (expected metadata pair)", vq_md(val));
        vcheck(md_is_string(md_op(val, 0)), "invalid value for 'require' module flag (first value operand should be a string)", vq_md(md_op(val, 0)));
        array_add(reqs, val);
      case MFB_APPEND; #through;
      case MFB_APPEND_UNIQUE;
        vcheck(is_md_node(val), "invalid value for 'append'-type module flag (expected a metadata node)", vq_md(val));
    }
    if mfb != MFB_REQUIRE {
        dup := false;
        for seen.* if it.id == id { dup = true; break; }
        if !dup { e: T; e.id = id; e.op = op; array_add(seen, e); }
        vcheck(!dup, "module flag identifiers must be unique (or of 'require' type)", vq_md(id));
    }
    s := ir.mds[id].str;
    if s == "wchar_size" vcheck(md_const_int(val) != NONE, "wchar_size metadata requires constant integer argument");
    if s == "Linker Options" vcheck(vf_named_md_index("llvm.linker.options") >= 0, "'Linker Options' named metadata no longer supported");
    if s == "SemanticInterposition" vcheck(md_const_int(val) != NONE, "SemanticInterposition metadata requires constant integer argument");
    if s == "CG Profile" {
        for k: 0..cast(s64) vf_md_nops(val) - 1 vf_visit_module_flag_cg_profile_entry(md_op(val, cast(u32) k));
    }
    // (verifyAMDGPUModuleFlag only checks AMDGPU flags)
}

const_int_is_negative :: (c: Value_Id) -> bool {
    w := type_int_width(vtype(c));
    words := const_int_value(c);
    top := words[(w - 1) / 64];
    return ((top >> ((w - 1) % 64)) & 1) != 0;
}

vf_visit_module_flag_cg_profile_entry :: (m: Md_Id) {
    check_fn :: (o: Md_Id) {
        if o == NONE return;
        vcheck(md_is_value(o) && vkind(strip_pointer_casts(ir.mds[o].value)) == .FUNCTION, "expected a Function or null", vq_md(o));
    }
    vcheck(is_md_node(m) && vf_md_nops(m) == 3, "expected a MDNode triple", vq_md(m));
    check_fn(md_op(m, 0));
    check_fn(md_op(m, 1));
    c := md_op(m, 2);
    vcheck(md_is_constant(c) && is_int_type(vtype(ir.mds[c].value)), "expected an integer constant", vq_md(c));
}

// ---------------------------------------------------------------- function metadata

vf_verify_unknown_profile_metadata :: (m: Md_Id) {
    vcheck(vf_md_nops(m) == 2, "'unknown' !prof should have a single additional operand", vq_md(m));
    pn := md_op(m, 1);
    vcheck(md_is_string(pn), "'unknown' !prof should have an additional operand of type string");
    vcheck(ir.mds[pn].str.count > 0, "the 'unknown' !prof operand should not be an empty string");
}

md_op_equals_str :: (m: Md_Id, i: u32, s: string) -> bool {
    if i >= vf_md_nops(m) return false;
    o := md_op(m, i);
    return md_is_string(o) && ir.mds[o].str == s;
}

vf_verify_function_metadata :: (mds: [] Kind_Md) {
    wg := vf.kind_reqd_wg;
    for mds {
        m := it.md;
        if it.kind == MDV_PROF {
            vcheck(vf_md_nops(m) >= 2, "!prof annotations should have no less than 2 operands", vq_md(m));
            if md_op_equals_str(m, 0, "unknown") { vf_verify_unknown_profile_metadata(m); continue; }
            o0 := md_op(m, 0);
            vcheck(o0 != NONE, "first operand should not be null", vq_md(m));
            vcheck(md_is_string(o0), "expected string with name of the !prof annotation", vq_md(m));
            pn := ir.mds[o0].str;
            vcheck(pn == "function_entry_count" || pn == "synthetic_function_entry_count", "first operand should be 'function_entry_count' or 'synthetic_function_entry_count'", vq_md(m));
            o1 := md_op(m, 1);
            vcheck(o1 != NONE, "second operand should not be null", vq_md(m));
            vcheck(md_is_constant(o1), "expected integer argument to function_entry_count", vq_md(m));
        } else if it.kind == MDV_KCFI_TYPE {
            vcheck(vf_md_nops(m) == 1, "!kcfi_type must have exactly one operand", vq_md(m));
            o := md_op(m, 0);
            vcheck(o != NONE, "!kcfi_type operand must not be null", vq_md(m));
            vcheck(md_is_constant(o), "expected a constant operand for !kcfi_type", vq_md(m));
            c := ir.mds[o].value;
            vcheck(vkind(c) == .C_INT, "expected a constant integer operand for !kcfi_type", vq_md(m));
            vcheck(type_int_width(vtype(c)) == 32, "expected a 32-bit integer constant operand for !kcfi_type", vq_md(m));
        } else if wg != NONE && it.kind == wg {
            vcheck(vf_md_nops(m) == 3, "reqd_work_group_size must have exactly three operands", vq_md(m));
            product: u64 = 1;
            for k: 0..2 {
                c := md_const_int(md_op(m, cast(u32) k));
                vcheck(c != NONE, "reqd_work_group_size operands must be integer constants", vq_md(m));
                active := const_int_active_bits(c);
                vcheck(active <= 64, "reqd_work_group_size operands must fit in 64 bits", vq_md(m));
                dim := const_int_zext(c);
                vcheck(dim == 0 || product <= 0xFFFF_FFFF_FFFF_FFFF / dim, "reqd_work_group_size product must fit in 64 bits", vq_md(m));
                product *= dim;
            }
        }
    }
}

// the kind id of `name` if it is registered (no registration: lookups must not add kinds)
md_kind_id_lookup :: (name: string) -> u32 {
    found, id := table_find(*ir.md_kind_map, name);
    if found return id;
    return NONE;
}

const_int_active_bits :: (c: Value_Id) -> u32 {
    w := type_int_width(vtype(c));
    words := const_int_value(c);
    k := cast(s64) words.count - 1;
    while k >= 0 {
        x := words[k];
        if k == words.count - 1 && w % 64 != 0 x &= (cast(u64) 1 << (w % 64)) - 1;
        if x != 0 return cast(u32) (k * 64 + 64 - bit_scan_reverse_u64(x));
        k -= 1;
    }
    return 0;
}
bit_scan_reverse_u64 :: (x: u64) -> s64 {   // number of leading zeros
    n := 0;
    y := x;
    while n < 64 && (y & 0x8000_0000_0000_0000) == 0 { y <<= 1; n += 1; }
    return n;
}

// ---------------------------------------------------------------- instruction metadata (the tail of visitInstruction)

// Check(...) inside visitInstruction itself returns from visitInstruction: vcheck_inst sets vf.inst_md_failed
vcheck_inst :: (vc_cond: bool, $vc_msg: Code, $vc_args: ..Code) #expand {
    if !vc_cond {
        #insert -> string { return vf_check_call_text("check_failed", vc_args.count); }
        vf.inst_md_failed = true;
        `return;
    }
}
vcheck_di_inst :: (vc_cond: bool, $vc_msg: Code, $vc_args: ..Code) #expand {
    if !vc_cond {
        #insert -> string { return vf_check_call_text("di_check_failed", vc_args.count); }
        vf.inst_md_failed = true;
        `return;
    }
}

vf_has_md :: inline (i: Value_Id, k: u32) -> bool { return get_metadata(i, k) != NONE; }

// the attachments of kinds 0..MDV_MEM_CACHE_HINT of the instruction being checked (one scan of its list)
vf_att: [MDV_MEM_CACHE_HINT + 1] Md_Id;
vf_att_get :: inline (k: u32) -> Md_Id { return vf_att[k]; }

vf_visit_instruction_metadata :: (i: Value_Id) {
    if ir.v_md[i] == NONE return;   // no attachments: none of the checks below applies
    for * vf_att it.* = NONE;
    a := ir.v_md[i];
    while a != NONE {
        k := ir.attaches[a].kind;
        if k <= MDV_MEM_CACHE_HINT && vf_att[k] == NONE vf_att[k] = ir.attaches[a].md;
        a = ir.attaches[a].next;
    }
    vf_visit_instruction_metadata_checks(i);
}

vf_visit_instruction_metadata_checks :: (i: Value_Id) {
    o := inst_op(i);
    ty := vtype(i);
    m := vf_att_get(MDV_FPMATH);
    if m != NONE {
        st := scalar_type(ty);
        vcheck_inst(is_fp_type(st), "fpmath requires a floating point result!", vq_val(i));
        vcheck_inst(vf_md_nops(m) == 1, "fpmath takes one operand!", vq_val(i));
        o0 := md_op(m, 0);
        if md_is_constant(o0) && vkind(ir.mds[o0].value) == .C_FP {
            c := ir.mds[o0].value;
            vcheck_inst(vtype(c) == type_simple(.FLOAT), "fpmath accuracy must have float type", vq_val(i));
            bits := cast(u32) const_fp_value(c)[0];   // IEEE single
            finite_nonzero := ((bits >> 23) & 0xFF) != 0xFF && (bits & 0x7FFF_FFFF) != 0;
            vcheck_inst(finite_nonzero && (bits >> 31) == 0, "fpmath accuracy not a positive number!", vq_val(i));
        } else {
            vcheck_inst(false, "invalid fpmath accuracy!", vq_val(i));
        }
    }
    m = vf_att_get(MDV_RANGE);
    if m != NONE {
        vcheck_inst(o == .LOAD || o == .CALL || o == .INVOKE, "Ranges are only for loads, calls and invokes!", vq_val(i));
        vf_verify_range_like_metadata(i, m, ty, .RANGE);
    }
    m = vf_att_get(MDV_NOFPCLASS);
    if m != NONE {
        vcheck_inst(o == .LOAD, "nofpclass is only for loads", vq_val(i));
        vf_visit_nofpclass_metadata(i, m, ty);
    }
    m = vf_att_get(MDV_NOALIAS_ADDRSPACE);
    if m != NONE {
        vcheck_inst(o == .LOAD || o == .STORE || o == .ATOMICRMW || o == .CMPXCHG || o == .CALL, "noalias.addrspace are only for memory operations!", vq_val(i));
        vf_verify_range_like_metadata(i, m, ty, .NOALIAS_ADDRSPACE);
    }
    if (vf_att_get(MDV_INVARIANT_GROUP) != NONE) vcheck_inst(o == .LOAD || o == .STORE, "invariant.group metadata is only for loads and stores", vq_val(i));
    if (vf_att_get(MDV_INVARIANT_LOAD) != NONE) {
        is_ii := o == .CALL && intrinsic_id_of_call(i).count > 0;
        vcheck_inst(o == .LOAD || (is_ii && call_only_reads_memory(i)), "invariant.load metadata is only for loads and readonly intrinsic calls", vq_val(i));
    }
    m = vf_att_get(MDV_NONNULL);
    if m != NONE {
        vcheck_inst(is_ptr_type(ty), "nonnull applies only to pointer types", vq_val(i));
        vcheck_inst(o == .LOAD, "nonnull applies only to load instructions, use attributes for calls or invokes", vq_val(i));
        vcheck_inst(vf_md_nops(m) == 0, "nonnull metadata must be empty", vq_val(i));
    }
    m = vf_att_get(MDV_NOUNDEF);
    if m != NONE {
        vcheck_inst(o == .LOAD, "noundef applies only to load instructions", vq_val(i));
        vcheck_inst(vf_md_nops(m) == 0, "noundef metadata must be empty", vq_val(i));
    }
    m = vf_att_get(MDV_DEREFERENCEABLE);
    if m != NONE vf_visit_dereferenceable_metadata(i, m);
    m = vf_att_get(MDV_DEREFERENCEABLE_OR_NULL);
    if m != NONE vf_visit_dereferenceable_metadata(i, m);
    m = vf_att_get(MDV_NOFREE);
    if m != NONE vf_visit_nofree_metadata(i, m);
    m = vf_att_get(MDK_TBAA);
    if m != NONE vf_visit_tbaa_metadata(i, m);
    m = vf_att_get(MDV_NOALIAS);
    if m != NONE vf_visit_alias_scope_list_metadata(m);
    m = vf_att_get(MDV_ALIAS_SCOPE);
    if m != NONE vf_visit_alias_scope_list_metadata(m);
    m = vf_att_get(MDV_ACCESS_GROUP);
    if m != NONE vf_visit_access_group_metadata(m);
    m = vf_att_get(MDV_ALIGN);
    if m != NONE {
        vcheck_inst(is_ptr_type(ty), "align applies only to pointer types", vq_val(i));
        vcheck_inst(o == .LOAD, "align applies only to load instructions, use attributes for calls or invokes", vq_val(i));
        vcheck_inst(vf_md_nops(m) == 1, "align takes one operand!", vq_val(i));
        c := md_const_int(md_op(m, 0));
        vcheck_inst(c != NONE && type_int_width(vtype(c)) == 64, "align metadata value must be an i64!", vq_val(i));
        a := const_int_zext(c);
        vcheck_inst(a != 0 && (a & (a - 1)) == 0, "align metadata value must be a power of 2!", vq_val(i));
        vcheck_inst(a <= MAXIMUM_ALIGNMENT, "alignment is larger that implementation defined limit", vq_val(i));
    }
    m = vf_att_get(MDV_PROF);
    if m != NONE vf_visit_prof_metadata(i, m);
    m = vf_att_get(MDV_MEMPROF);
    if m != NONE vf_visit_memprof_metadata(i, m);
    m = vf_att_get(MDV_CALLSITE);
    if m != NONE vf_visit_callsite_metadata(i, m);
    m = vf_att_get(MDV_CALLEE_TYPE);
    if m != NONE vf_visit_callee_type_metadata(i, m);
    m = vf_att_get(MDV_DIASSIGNID);
    if m != NONE vf_visit_di_assign_id_metadata(i, m);
    m = vf_att_get(MDV_MMRA);
    if m != NONE vf_visit_mmra_metadata(i, m);
    m = vf_att_get(MDV_ANNOTATION);
    if m != NONE vf_visit_annotation_metadata(m);
    m = vf_att_get(MDV_CAPTURES);
    if m != NONE vf_visit_captures_metadata(i, m);
    m = vf_att_get(MDV_ALLOC_TOKEN);
    if m != NONE vf_visit_alloc_token_metadata(i, m);
    m = vf_att_get(MDV_INLINE_HISTORY);
    if m != NONE vf_visit_inline_history_metadata(i, m);
    m = vf_att_get(MDV_MEM_CACHE_HINT);
    if m != NONE vf_visit_mem_cache_hint_metadata(i, m);
    lanes := vf.kind_amdgpu_lanes;
    if lanes != NONE {
        m = get_metadata(i, lanes);
        if m != NONE {
            vcheck_inst(vf_md_nops(m) == 1, "!amdgpu.expected.active.lanes must have exactly one operand", vq_val(i), vq_md(m));
            c := md_const_int(md_op(m, 0));
            vcheck_inst(c != NONE && type_int_width(vtype(c)) == 32, "!amdgpu.expected.active.lanes operand must be an i32 constant", vq_val(i), vq_md(m));
        }
    }
    n := vf_att_get(0);
    if n != NONE {
        vcheck_di_inst(is_di(n, .LOCATION), "invalid !dbg metadata attachment", vq_val(i), vq_md(n));
        vf_visit_md_node(n, true);
        if di_int(n, 3) != 0 {
            sp := vf_di_local_scope_subprogram(di_op(n, 0));
            vcheck_di_inst(sp != NONE && di_int(sp, 6) != 0, "DbgLoc uses atomGroup but DISubprogram doesn't have Key Instructions enabled", vq_md(n), vq_md(sp));
        }
    }
    for vf_all_attachments(i) {
        allow := it.kind == 0 || it.kind == MDV_LOOP;
        vf_visit_md_node(it.md, allow);
    }
}

Range_Like :: enum u8 { RANGE; ABSOLUTE_SYMBOL; NOALIAS_ADDRSPACE; }

// verifyRangeLikeMetadata: the pairs are half-open ConstantRanges, non-empty, sorted, disjoint and not adjacent
vf_verify_range_like_metadata :: (v: Value_Id, rng: Md_Id, ty: Type_Id, kind: Range_Like) {
    nops := vf_md_nops(rng);
    vcheck(nops % 2 == 0, "Unfinished range!", vq_md(rng));
    nr := nops / 2;
    vcheck(nr >= 1, "It should have at least one range!", vq_md(rng));
    last_lo, last_hi: APInt;
    first_lo, first_hi: APInt;
    for k: 0..cast(s64) nr - 1 {
        lo := md_const_int(md_op(rng, cast(u32) (2 * k)));
        vcheck(lo != NONE, "The lower limit must be an integer!", vq_val(lo));
        hi := md_const_int(md_op(rng, cast(u32) (2 * k + 1)));
        vcheck(hi != NONE, "The upper limit must be an integer!", vq_val(hi));
        vcheck(vtype(hi) == vtype(lo), "Range pair types must match!", vq_val(v));
        if kind == .NOALIAS_ADDRSPACE vcheck(is_int_type(vtype(hi)) && type_int_width(vtype(hi)) == 32, "noalias.addrspace type must be i32!", vq_val(v));
        else vcheck(vtype(hi) == scalar_type(ty), "Range types must match instruction type!", vq_val(v));
        lv := const_ap(lo); hv := const_ap(hi);
        vcheck(!ap_eq(lv, hv) || ap_is_max_value(lv) || ap_is_min_value(lv), "The upper and lower limits cannot be the same value", vq_val(v));
        cur := cr_new(lv, hv);
        vcheck(!cr_is_empty_set(cur) && (kind == .ABSOLUTE_SYMBOL || !cr_is_full_set(cur)), "Range must not be empty!", vq_md(rng));
        if k != 0 {
            last := cr_new(last_lo, last_hi);
            vcheck(cr_is_empty_set(cr_intersect(cur, last)), "Intervals are overlapping", vq_md(rng));
            vcheck(ap_sgt(lv, last_lo), "Intervals are not in order", vq_md(rng));
            vcheck(!(ap_eq(hv, last_lo) || ap_eq(lv, last_hi)), "Intervals are contiguous", vq_md(rng));
        } else {
            first_lo = lv; first_hi = hv;
        }
        last_lo = lv; last_hi = hv;
    }
    if nr > 2 {
        first := cr_new(first_lo, first_hi);
        last := cr_new(last_lo, last_hi);
        vcheck(cr_is_empty_set(cr_intersect(first, last)), "Intervals are overlapping", vq_md(rng));
        vcheck(!(ap_eq(first_hi, last_lo) || ap_eq(first_lo, last_hi)), "Intervals are contiguous", vq_md(rng));
    }
}


vf_visit_nofpclass_metadata :: (i: Value_Id, m: Md_Id, ty: Type_Id) {
    vcheck(attr_nofpclass_compatible_type(ty), "nofpclass only applies to floating-point typed loads", vq_val(i));
    vcheck(vf_md_nops(m) == 1, "nofpclass must have exactly one entry", vq_md(m));
    c := md_const_int(md_op(m, 0));
    vcheck(c != NONE && type_int_width(vtype(c)) == 32, "nofpclass entry must be a constant i32", vq_md(m));
    v := const_int_zext(c);
    vcheck(v != 0, "'nofpclass' must have at least one test bit set", vq_md(m), vq_val(i));
    vcheck((v & ~cast(u64) FC_ALL_FLAGS) == 0, "Invalid value for 'nofpclass' test mask", vq_md(m), vq_val(i));
}

// AttributeFuncs::isNoFPClassCompatibleType: FP, vectors of FP, arrays (and literal structs of the same) of them
attr_nofpclass_compatible_type :: (t: Type_Id) -> bool {
    st := scalar_type(t);
    if is_fp_type(st) return true;
    k := type_kind(t);
    if k == .ARRAY return attr_nofpclass_compatible_type(type_elem(t));
    if k == .STRUCT {
        if type_nsub(t) == 0 return false;
        for x: 0..cast(s64) type_nsub(t) - 1 if !attr_nofpclass_compatible_type(type_sub(t, cast(u32) x)) return false;
        return true;
    }
    return false;
}

vf_visit_dereferenceable_metadata :: (i: Value_Id, m: Md_Id) {
    vcheck(is_ptr_type(vtype(i)), "dereferenceable, dereferenceable_or_null apply only to pointer types", vq_val(i));
    o := inst_op(i);
    vcheck(o == .LOAD || o == .INTTOPTR, "dereferenceable, dereferenceable_or_null apply only to load and inttoptr instructions, use attributes for calls or invokes", vq_val(i));
    vcheck(vf_md_nops(m) == 1, "dereferenceable, dereferenceable_or_null take one operand!", vq_val(i));
    c := md_const_int(md_op(m, 0));
    vcheck(c != NONE && type_int_width(vtype(c)) == 64, "dereferenceable, dereferenceable_or_null metadata value must be an i64!", vq_val(i));
}

vf_visit_nofree_metadata :: (i: Value_Id, m: Md_Id) {
    vcheck(is_ptr_type(vtype(i)), "nofree applies only to pointer types", vq_val(i));
    vcheck(inst_op(i) == .INTTOPTR, "nofree applies only to inttoptr instruction", vq_val(i));
    vcheck(vf_md_nops(m) == 0, "nofree metadata must be empty", vq_val(i));
}

vf_visit_prof_metadata :: (i: Value_Id, m: Md_Id) {
    o := inst_op(i);
    expected_ops :: (i: Value_Id, o: Opcode) -> u32 {
        if o == .CONDBR return 2;
        if o == .SWITCH return num_successors(i);
        if o == .CALL return 1;
        if o == .INDIRECTBR return nops(i) - 1;
        if o == .SELECT return 2;
        if o == .CALLBR return num_successors(i);
        return 0;
    }
    vcheck(vf_md_nops(m) >= 1, "!prof annotations should have at least 1 operand", vq_md(m));
    o0 := md_op(m, 0);
    vcheck(o0 != NONE, "first operand should not be null", vq_md(m));
    vcheck(md_is_string(o0), "expected string with name of the !prof annotation", vq_md(m));
    name := ir.mds[o0].str;
    if name == "unknown" {
        vcheck(expected_ops(i, o) != 0 || o == .INVOKE, "'unknown' !prof should only appear on instructions on which 'branch_weights' would", vq_md(m));
        vf_verify_unknown_profile_metadata(m);
        return;
    }
    vcheck(vf_md_nops(m) >= 2, "!prof annotations should have no less than 2 operands", vq_md(m));
    if name == "branch_weights" {
        // getBranchWeightOffset: 2 with an "expected" origin string, else 1
        off: u32 = ifx md_op_equals_str(m, 1, "expected") then cast(u32) 2 else 1;
        nw := vf_md_nops(m) - off;
        if o == .INVOKE {
            vcheck(nw == 1 || nw == 2, "Wrong number of InvokeInst branch_weights operands", vq_md(m));
        } else {
            e := expected_ops(i, o);
            if e == 0 check_failed("!prof branch_weights are not allowed for this instruction", vq_md(m));
            vcheck(nw == e, "Wrong number of operands", vq_md(m));
        }
        for k: off..vf_md_nops(m) - 1 {
            x := md_op(m, k);
            vcheck(x != NONE, "second operand should not be null", vq_md(m));
            vcheck(md_const_int(x) != NONE, "!prof brunch_weights operand is not a const int");
        }
    } else if name == "VP" {
        // isValueProfileMD: "VP" with at least 3 operands
        vcheck(vf_md_nops(m) >= 3, "invalid value profiling metadata", vq_md(m));
        kc := md_const_int(md_op(m, 1));
        vcheck(kc != NONE, "VP !prof missing kind argument", vq_md(m));
        kind := const_int_zext(kc);
        vcheck(kind <= 2, "Invalid VP !prof kind", vq_md(m));   // IPVK_First = 0 .. IPVK_Last = 2
        vcheck(vf_md_nops(m) % 2 == 1, "VP !prof should have an even number of arguments after 'VP'", vq_md(m));
        if kind == 0 || kind == 1
            vcheck(o == .CALL || o == .INVOKE || o == .CALLBR, "VP !prof indirect call or memop size expected to be applied to CallBase instructions only", vq_md(m));
        vals: [..] u64; vals.allocator = temp;
        k: u32 = 3;
        while k < vf_md_nops(m) {
            pv := md_const_int(md_op(m, k));
            vcheck(pv != NONE, "VP !prof value operand is not a const int", vq_md(m));
            x := const_int_zext(pv);
            dup := false;
            for vals if it == x { dup = true; break; }
            vcheck(!dup, "VP !prof should not have duplicate profile values", vq_md(m));
            array_add(*vals, x);
            k += 2;
        }
    } else {
        check_failed("expected either branch_weights or VP profile name", vq_md(m));
    }
}

vf_visit_di_assign_id_metadata :: (i: Value_Id, m: Md_Id) {
    o := inst_op(i);
    is_ii := o == .CALL && intrinsic_id_of_call(i).count > 0;
    vcheck_di(o == .ALLOCA || o == .STORE || is_ii, "!DIAssignID attached to unexpected instruction kind", vq_val(i), vq_md(m));
    // MetadataAsValue users of the DIAssignID: llvm.dbg.assign calls (upgraded to records by the parser)
    f := block(inst(i).parent).parent;
    for g: ir.m_functions for b: fn_blocks(g) for i2: block_insts(b) {
        x := inst(i2).records;
        while x != 0 {
            r := *ir.dbg_records[x - 1];
            if r.assign_id == m {
                vcheck_di(r.kind == .ASSIGN, "!DIAssignID should only be used by Assign DVRs.", vq_md(m), vq_rec(x));
                vcheck_di(g == f, "DVRAssign not in same function as inst", vq_rec(x), vq_val(i));
            }
            x = r.next;
        }
    }
}

// MMRAMetadata::isTagMD: a tuple of two strings
mmra_is_tag :: (m: Md_Id) -> bool {
    return md_is_tuple(m) && vf_md_nops(m) == 2 && md_is_string(md_op(m, 0)) && md_is_string(md_op(m, 1));
}

vf_visit_mmra_metadata :: (i: Value_Id, m: Md_Id) {
    // canInstructionHaveMMRAs: fences, memory accesses, calls (that may access memory)
    o := inst_op(i);
    can := o == .FENCE || o == .LOAD || o == .STORE || o == .CMPXCHG || o == .ATOMICRMW || ((o == .CALL || o == .INVOKE || o == .CALLBR) && (may_read_from_memory(i) || may_write_to_memory(i)));
    vcheck(can, "!mmra metadata attached to unexpected instruction kind", vq_val(i), vq_md(m));
    if mmra_is_tag(m) return;
    vcheck(md_is_tuple(m), "!mmra expected to be a metadata tuple", vq_val(i), vq_md(m));
    for k: 0..cast(s64) vf_md_nops(m) - 1 {
        x := md_op(m, cast(u32) k);
        vcheck(mmra_is_tag(x), "!mmra metadata tuple operand is not an MMRA tag", vq_val(i), vq_md(x));
    }
}

vf_visit_call_stack_metadata :: (m: Md_Id) {
    vcheck(vf_md_nops(m) >= 1, "call stack metadata should have at least 1 operand", vq_md(m));
    for k: 0..cast(s64) vf_md_nops(m) - 1 {
        x := md_op(m, cast(u32) k);
        vcheck(md_const_int(x) != NONE, "call stack metadata operand should be constant integer", vq_md(x));
    }
}

vf_visit_memprof_metadata :: (i: Value_Id, m: Md_Id) {
    is_cb := is_call_base(i);
    vcheck(is_cb, "!memprof metadata should only exist on calls", vq_val(i));
    if is_cb vcheck(vf_has_md(i, MDV_CALLSITE), "!memprof metadata requires !callsite metadata", vq_val(i), vq_md(m));
    vcheck(vf_md_nops(m) >= 1, "!memprof annotations should have at least 1 metadata operand (MemInfoBlock)", vq_md(m));
    for k: 0..cast(s64) vf_md_nops(m) - 1 {
        mib := md_op(m, cast(u32) k);
        vcheck(vf_md_nops(mib) >= 2, "Each !memprof MemInfoBlock should have at least 2 operands", vq_md(mib));
        vcheck(md_op(mib, 0) != NONE, "!memprof MemInfoBlock first operand should not be null", vq_md(mib));
        vcheck(is_md_node(md_op(mib, 0)), "!memprof MemInfoBlock first operand should be an MDNode", vq_md(mib));
        vf_visit_call_stack_metadata(md_op(mib, 0));
        vcheck(md_is_string(md_op(mib, 1)), "!memprof MemInfoBlock second operand should be an MDString", vq_md(mib));
        for j: 2..cast(s64) vf_md_nops(mib) - 1 {
            on := md_op(mib, cast(u32) j);
            vcheck(is_md_node(on), "Not all !memprof MemInfoBlock operands 2 to N are MDNode", vq_md(mib));
            vcheck(vf_md_nops(on) == 2, "Not all !memprof MemInfoBlock operands 2 to N are MDNode with 2 operands", vq_md(mib));
            vcheck(md_const_int(md_op(on, 0)) != NONE && md_const_int(md_op(on, 1)) != NONE, "Not all !memprof MemInfoBlock operands 2 to N are MDNode with ConstantInt operands", vq_md(mib));
        }
    }
}

vf_visit_callsite_metadata :: (i: Value_Id, m: Md_Id) {
    vcheck(is_call_base(i), "!callsite metadata should only exist on calls", vq_val(i));
    vf_visit_call_stack_metadata(m);
}

vf_visit_callee_type_metadata :: (i: Value_Id, m: Md_Id) {
    vcheck(is_call_base(i), "!callee_type metadata should only exist on calls", vq_val(i));
    for k: 0..cast(s64) vf_md_nops(m) - 1 {
        o := md_op(m, cast(u32) k);
        vcheck(is_md_node(o), "The callee_type metadata must be a list of callgraph metadata nodes", vq_md(o));
        vcheck(vf_md_nops(o) == 1, "Well-formed generalized callgraph metadata must contain exactly one operand", vq_md(o));
        vcheck(md_is_string(md_op(o, 0)), "The operand of callgraph metadata for functions must be an MDString", vq_md(o));
        vcheck(ends_with(ir.mds[md_op(o, 0)].str, ".generalized"), "Only generalized callgraph metadata can be part of the callee_type metadata list", vq_md(o));
    }
}

vf_visit_annotation_metadata :: (a: Md_Id) {
    vcheck(md_is_tuple(a), "annotation must be a tuple");
    vcheck(vf_md_nops(a) >= 1, "annotation must have at least one operand");
    for k: 0..cast(s64) vf_md_nops(a) - 1 {
        o := md_op(a, cast(u32) k);
        tuple_of_strings := md_is_tuple(o);
        if tuple_of_strings for j: 0..cast(s64) vf_md_nops(o) - 1 if !md_is_string(md_op(o, cast(u32) j)) { tuple_of_strings = false; break; }
        vcheck(md_is_string(o) || tuple_of_strings, "operands must be a string or a tuple of strings");
    }
}

vf_visit_alias_scope_metadata :: (m: Md_Id) {
    n := vf_md_nops(m);
    vcheck(n >= 2 && n <= 3, "scope must have two or three operands", vq_md(m));
    vcheck(md_op(m, 0) == m || md_is_string(md_op(m, 0)), "first scope operand must be self-referential or string", vq_md(m));
    if n == 3 vcheck(md_is_string(md_op(m, 2)), "third scope operand must be string (if used)", vq_md(m));
    d := md_op(m, 1);
    vcheck(is_md_node(d), "second scope operand must be MDNode", vq_md(m));
    nd := vf_md_nops(d);
    vcheck(nd >= 1 && nd <= 2, "domain must have one or two operands", vq_md(d));
    vcheck(md_op(d, 0) == d || md_is_string(md_op(d, 0)), "first domain operand must be self-referential or string", vq_md(d));
    if nd == 2 vcheck(md_is_string(md_op(d, 1)), "second domain operand must be string (if used)", vq_md(d));
}

vf_visit_alias_scope_list_metadata :: (m: Md_Id) {
    for k: 0..cast(s64) vf_md_nops(m) - 1 {
        o := md_op(m, cast(u32) k);
        vcheck(is_md_node(o), "scope list must consist of MDNodes", vq_md(m));
        vf_visit_alias_scope_metadata(o);
    }
}

vf_visit_access_group_metadata :: (m: Md_Id) {
    valid :: (m: Md_Id) -> bool { return vf_md_nops(m) == 0 && ir.mds[m].distinct; }
    if valid(m) return;
    for k: 0..cast(s64) vf_md_nops(m) - 1 {
        o := md_op(m, cast(u32) k);
        vcheck(is_md_node(o), "Access scope list must consist of MDNodes", vq_md(m));
        vcheck(valid(o), "Access scope list contains invalid access scope", vq_md(m));
    }
}

vf_visit_captures_metadata :: (i: Value_Id, c: Md_Id) {
    vcheck(inst_op(i) == .STORE, "!captures metadata can only be applied to store instructions", vq_val(i));
    vcheck(is_ptr_type(vtype(op(i, 0))), "!captures metadata can only be applied to store with value operand of pointer type", vq_val(i));
    vcheck(vf_md_nops(c) != 0, "!captures metadata cannot be empty", vq_val(i));
    for k: 0..cast(s64) vf_md_nops(c) - 1 {
        s := md_op(c, cast(u32) k);
        vcheck(md_is_string(s), "!captures metadata must be a list of strings", vq_val(i));
        str := ir.mds[s].str;
        vcheck(str == "address_is_null" || str == "address" || str == "read_provenance" || str == "provenance", "invalid entry in !captures metadata", vq_val(i), vq_md(s));
    }
}

vf_visit_alloc_token_metadata :: (i: Value_Id, m: Md_Id) {
    vcheck(is_call_base(i), "!alloc_token should only exist on calls", vq_val(i));
    vcheck(vf_md_nops(m) == 2, "!alloc_token must have 2 operands", vq_md(m));
    vcheck(md_is_string(md_op(m, 0)), "expected string", vq_md(m));
    vcheck(md_const_int(md_op(m, 1)) != NONE, "expected integer constant", vq_md(m));
}

vf_visit_inline_history_metadata :: (i: Value_Id, m: Md_Id) {
    vcheck(is_call_base(i), "!inline_history should only exist on calls", vq_val(i));
    for k: 0..cast(s64) vf_md_nops(m) - 1 {
        o := md_op(m, cast(u32) k);
        if o == NONE continue;
        vcheck(md_is_value(o) && vkind(vf_strip_pointer_casts_and_aliases(ir.mds[o].value)) == .FUNCTION, "!inline_history operands must be functions or null", vq_md(m));
    }
}

vf_visit_mem_cache_hint_metadata :: (i: Value_Id, m: Md_Id) {
    vcheck(may_read_from_memory(i) || may_write_to_memory(i), "!mem.cache_hint is only valid on memory operations", vq_val(i));
    vcheck(vf_md_nops(m) % 2 == 0, "!mem.cache_hint must have even number of operands (operand_no, hint_node pairs)", vq_md(m));
    is_cb := is_call_base(i);
    if is_cb vcheck(intrinsic_id_of_call(i).count > 0, "!mem.cache_hint is not supported on non-intrinsic calls", vq_val(i));
    num_ops := ifx is_cb then call_num_args(i) else nops(i);
    seen: [..] u64; seen.allocator = temp;
    have_last := false; last: u64 = 0;
    j: u32 = 0;
    while j + 1 < vf_md_nops(m) {
        defer j += 2;
        c := md_const_int(md_op(m, j));
        vcheck(c != NONE, "!mem.cache_hint must alternate between i32 operand numbers and metadata hint nodes", vq_md(m));
        vcheck(!const_int_is_negative(c), "!mem.cache_hint operand number must be non-negative", vq_md(m));
        opno := const_int_zext(c);
        vcheck(opno < num_ops, "!mem.cache_hint operand number is out of range", vq_val(i));
        operand := op(i, cast(u32) opno);
        vcheck(vf_is_ptr_or_ptr_vector(vtype(operand)), "!mem.cache_hint operand number must refer to a pointer operand", vq_val(i));
        inserted := true;
        for seen if it == opno { inserted = false; break; }
        if inserted array_add(*seen, opno);
        vcheck(inserted, "!mem.cache_hint contains duplicate operand number", vq_md(m));
        vcheck(!inserted || !have_last || opno > last, "!mem.cache_hint operand numbers must be in increasing order", vq_md(m));
        have_last = true; last = opno;
        node := md_op(m, j + 1);
        vcheck(is_md_node(node), "!mem.cache_hint must alternate between i32 operand numbers and metadata hint nodes", vq_md(m));
        vcheck(vf_md_nops(node) % 2 == 0, "!mem.cache_hint hint node must have even number of operands (key-value pairs)", vq_md(node));
        keys: [..] string; keys.allocator = temp;
        kk: u32 = 0;
        while kk + 1 < vf_md_nops(node) {
            defer kk += 2;
            key := md_op(node, kk);
            vcheck(md_is_string(key), "!mem.cache_hint key must be a string", vq_md(node));
            ks := ir.mds[key].str;
            dupk := false;
            for keys if it == ks { dupk = true; break; }
            vcheck(!dupk, "!mem.cache_hint hint node contains duplicate key", vq_md(node));
            array_add(*keys, ks);
            val := md_op(node, kk + 1);
            vcheck(md_is_string(val) || md_const_int(val) != NONE, "!mem.cache_hint value must be a string or integer", vq_md(node));
        }
    }
}

// ---------------------------------------------------------------- TBAA (TBAAVerifier)

// CheckTBAA: print and return false
vcheck_tbaa :: (vc_cond: bool, $vc_msg: Code, $vc_args: ..Code) #expand {
    if !vc_cond {
        #insert -> string { return vf_check_call_text("check_failed", vc_args.count); }
        `return false;
    }
}

tbaa_is_root :: inline (m: Md_Id) -> bool { return vf_md_nops(m) < 2; }

tbaa_is_scalar_impl :: (m: Md_Id, visited: *[..] Md_Id) -> bool {
    n := vf_md_nops(m);
    if n != 2 && n != 3 return false;
    if !md_is_string(md_op(m, 0)) return false;
    if n == 3 {
        off := md_const_int(md_op(m, 2));
        if !(off != NONE && const_int_zext(off) == 0 && !vf_const_int_nonzero_high(off)) return false;
    }
    parent := md_op(m, 1);
    if !is_md_node(parent) return false;
    for visited.* if it == parent return false;
    array_add(visited, parent);
    return tbaa_is_root(parent) || tbaa_is_scalar_impl(parent, visited);
}
vf_const_int_nonzero_high :: (c: Value_Id) -> bool {
    w := const_int_value(c);
    for k: 1..w.count - 1 if w[k] != 0 return true;
    return false;
}

tbaa_is_valid_scalar :: (m: Md_Id) -> bool {
    found, r := table_find(*vf.tbaa_scalar, m);
    if found return r;
    visited: [..] Md_Id; visited.allocator = temp;
    r = tbaa_is_scalar_impl(m, *visited);
    table_add(*vf.tbaa_scalar, m, r);
    return r;
}

tbaa_verify_base_node :: (i: Value_Id, base: Md_Id, new_format: bool) -> Tbaa_Summary {
    if vf_md_nops(base) < 2 {
        check_failed("Base nodes must have at least two operands", vq_val(i), vq_md(base));
        return .{true, 0xFFFF_FFFF};
    }
    found, r := table_find(*vf.tbaa_base, base);
    if found return r;
    r = tbaa_verify_base_node_impl(i, base, new_format);
    table_add(*vf.tbaa_base, base, r);
    return r;
}

tbaa_verify_base_node_impl :: (i: Value_Id, base: Md_Id, new_format: bool) -> Tbaa_Summary {
    INVALID :: Tbaa_Summary.{true, 0xFFFF_FFFF};
    n := vf_md_nops(base);
    if n == 2 return ifx tbaa_is_valid_scalar(base) then Tbaa_Summary.{false, 0} else INVALID;
    if new_format {
        if n % 3 != 0 { check_failed("Access tag nodes must have the number of operands that is a multiple of 3!", vq_md(base)); return INVALID; }
    } else {
        if n % 2 != 1 { check_failed("Struct tag nodes must have an odd number of operands!", vq_md(base)); return INVALID; }
    }
    if new_format {
        if md_const_int(md_op(base, 1)) == NONE { check_failed("Type size nodes must be constants!", vq_val(i), vq_md(base)); return INVALID; }
    }
    if !new_format && !md_is_string(md_op(base, 0)) { check_failed("Struct tag nodes have a string as their first operand", vq_md(base)); return INVALID; }
    failed := false;
    have_prev := false;
    prev: APInt;
    bit_width: u32 = 0xFFFF_FFFF;
    first: u32 = ifx new_format then cast(u32) 3 else 1;
    per: u32 = ifx new_format then cast(u32) 3 else 2;
    idx := first;
    while idx < n {
        defer idx += per;
        fty := md_op(base, idx);
        foff := ifx idx + 1 < n then md_op(base, idx + 1) else NONE;
        if !is_md_node(fty) { check_failed("Incorrect field entry in struct type node!", vq_val(i), vq_md(base)); failed = true; continue; }
        oc := md_const_int(foff);
        if oc == NONE { check_failed("Offset entries must be constants!", vq_val(i), vq_md(base)); failed = true; continue; }
        w := type_int_width(vtype(oc));
        if bit_width == 0xFFFF_FFFF bit_width = w;
        if w != bit_width { check_failed("Bitwidth between the offsets and struct type entries must match", vq_val(i), vq_md(base)); failed = true; continue; }
        ov := const_ap(oc);
        if have_prev && !ap_ule(prev, ov) { check_failed("Offsets must be increasing!", vq_val(i), vq_md(base)); failed = true; }
        prev = ov; have_prev = true;
        if new_format {
            if md_const_int(ifx idx + 2 < n then md_op(base, idx + 2) else NONE) == NONE { check_failed("Member size entries must be constants!", vq_val(i), vq_md(base)); failed = true; continue; }
        }
    }
    if failed return INVALID;
    return .{false, bit_width};
}

// getFieldNodeFromTBAABaseNode: the field at `offset` (updated to the offset within the field)
tbaa_field_node :: (i: Value_Id, base: Md_Id, offset: *APInt, new_format: bool) -> Md_Id {
    n := vf_md_nops(base);
    if n == 2 { p := md_op(base, 1); return ifx is_md_node(p) then p else NONE; }
    first: u32 = ifx new_format then cast(u32) 3 else 1;
    per: u32 = ifx new_format then cast(u32) 3 else 2;
    idx := first;
    while idx < n {
        oc := md_const_int(md_op(base, idx + 1));
        ov := const_ap(oc);
        if ap_ugt(ov, offset.*) {
            if idx == first {
                check_failed("Could not find TBAA parent in struct type node", vq_val(i), vq_md(base), vq_text(tprint("%\n", ap_to_string_signed(offset.*))));
                return NONE;
            }
            pi := idx - per;
            po := const_ap(md_const_int(md_op(base, pi + 1)));
            offset.* = ap_sub(offset.*, po);
            return md_op(base, pi);
        }
        idx += per;
    }
    li := n - per;
    lo := const_ap(md_const_int(md_op(base, li + 1)));
    offset.* = ap_sub(offset.*, lo);
    return md_op(base, li);
}

tbaa_is_new_format_type :: (t: Md_Id) -> bool {
    if t == NONE || vf_md_nops(t) < 3 return false;
    return is_md_node(md_op(t, 0));
}

// TBAAVerifier::visitTBAAMetadata (I = NONE for llvm.errno.tbaa)
vf_visit_tbaa_metadata :: (i: Value_Id, m: Md_Id) -> bool {
    vcheck_tbaa(vf_md_nops(m) > 0, "TBAA metadata cannot have 0 operands", vq_val(i), vq_md(m));
    if i != NONE {
        o := inst_op(i);
        vcheck_tbaa(o == .LOAD || o == .STORE || o == .CALL || o == .VAARG || o == .ATOMICRMW || o == .CMPXCHG, "This instruction shall not have a TBAA access tag!", vq_val(i));
    }
    if table_contains(*vf.tbaa_ok, m) return true;   // the rest depends only on the tag
    before := vf.fail_count;
    ok := vf_visit_tbaa_tag(i, m);
    if ok && vf.fail_count == before table_add(*vf.tbaa_ok, m, true);
    return ok;
}

vf_visit_tbaa_tag :: (i: Value_Id, m: Md_Id) -> bool {
    struct_path := is_md_node(md_op(m, 0)) && vf_md_nops(m) >= 3;
    vcheck_tbaa(struct_path, "Old-style TBAA is no longer allowed, use struct-path TBAA instead", vq_val(i));
    base := md_op(m, 0);
    if !is_md_node(base) base = NONE;
    access := ifx vf_md_nops(m) > 1 then md_op(m, 1) else NONE;
    if !is_md_node(access) access = NONE;
    new_format := tbaa_is_new_format_type(access);
    if new_format vcheck_tbaa(vf_md_nops(m) == 4 || vf_md_nops(m) == 5, "Access tag metadata must have either 4 or 5 operands", vq_val(i), vq_md(m));
    else vcheck_tbaa(vf_md_nops(m) < 5, "Struct tag metadata must have either 3 or 4 operands", vq_val(i), vq_md(m));
    if new_format vcheck_tbaa(md_const_int(md_op(m, 3)) != NONE, "Access size field must be a constant", vq_val(i), vq_md(m));
    imm_op: u32 = ifx new_format then cast(u32) 4 else 3;
    if vf_md_nops(m) == imm_op + 1 {
        c := md_const_int(md_op(m, imm_op));
        vcheck_tbaa(c != NONE, "Immutability tag on struct tag metadata must be a constant", vq_val(i), vq_md(m));
        v := const_int_zext(c);
        vcheck_tbaa(!vf_const_int_nonzero_high(c) && (v == 0 || v == 1), "Immutability part of the struct tag metadata must be either 0 or 1", vq_val(i), vq_md(m));
    }
    vcheck_tbaa(base != NONE && access != NONE, "Malformed struct tag metadata: base and access-type should be non-null and point to Metadata nodes", vq_val(i), vq_md(m), vq_md(base), vq_md(access));
    if !new_format vcheck_tbaa(tbaa_is_valid_scalar(access), "Access type node must be a valid scalar type", vq_val(i), vq_md(m), vq_md(access));
    oc := md_const_int(md_op(m, 2));
    vcheck_tbaa(oc != NONE, "Offset must be constant integer", vq_val(i), vq_md(m));
    offset := const_ap(oc);
    seen_access := false;
    path: [..] Md_Id; path.allocator = temp;
    while base != NONE && !tbaa_is_root(base) {
        for path if it == base { check_failed("Cycle detected in struct path", vq_val(i), vq_md(m)); return false; }
        array_add(*path, base);
        s := tbaa_verify_base_node(i, base, new_format);
        if s.invalid return false;
        seen_access |= base == access;
        if tbaa_is_valid_scalar(base) || base == access
            vcheck_tbaa(ap_is_zero(offset), "Offset not zero at the point of scalar access", vq_val(i), vq_md(m), vq_text(tprint("%\n", ap_to_string_signed(offset))));
        vcheck_tbaa(s.bit_width == offset.bits || (s.bit_width == 0 && ap_is_zero(offset)) || (new_format && s.bit_width == 0xFFFF_FFFF),
            "Access bit-width not the same as description bit-width", vq_val(i), vq_md(m), vq_uint(s.bit_width), vq_uint(offset.bits));
        if new_format && seen_access break;
        base = tbaa_field_node(i, base, *offset, new_format);
    }
    vcheck_tbaa(seen_access, "Did not see access type in access path!", vq_val(i), vq_md(m));
    return true;
}
