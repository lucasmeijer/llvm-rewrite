// AssumeBundleBuilder: a port of the knowledge-salvaging half of llvm/lib/Transforms/Utils/AssumeBundleBuilder.cpp
// (-enable-knowledge-retention; isUsefullToPreserve, canonicalizedKnowledge, AssumeBuilderState, buildAssumeFromInst,
// salvageKnowledge) and of GEPOperator::getMaxPreservedAlignment (llvm/lib/IR/Operator.cpp).
// Only the AC = DT = null form of salvageKnowledge is ported (tryToPreserveWithoutAddingAssume needs the assumption
// cache's getKnowledgeForValue); a pass that passes an AssumptionCache must fail loudly (see knowledge_retention_check).
// Not ported: the assume-simplify / assume-builder passes.

knowledge_retention: struct {
    enabled := false;    // -enable-knowledge-retention
};

// the passes that honour -enable-knowledge-retention here (the others call salvageKnowledge in ways not ported)
knowledge_retention_check :: (kind: Pass_Kind, name: string) {
    if !knowledge_retention.enabled return;
    if kind == .DSE || kind == .REQUIRE || kind == .INVALIDATE || kind == .NO_OP_FUNCTION || kind == .NO_OP_MODULE ||
       kind == .MODULE_PM || kind == .FUNCTION_ADAPTOR || kind == .VERIFY_MEMORYSSA || kind == .PRINT_MEMORYSSA return;
    fatal("-enable-knowledge-retention is not supported with pass '%' yet", name);
}

Ab_Knowledge :: struct { kind: Attr_Kind; arg: u64; was_on: Value_Id = NONE; }

// GEPOperator::getMaxPreservedAlignment
gep_max_preserved_alignment :: (g: Value_Id) -> u64 {
    result: u64 = (cast(u64) 1) << 32;
    min_align :: (a: u64, b: u64) -> u64 { x := a | b; return x & (~x + 1); }
    n := nops(g);
    t := opr_gep_source_type(g);
    prev: Type_Id = NONE;
    for i: 1..cast(s64) n - 1 {
        c := op(g, cast(u32) i);
        if i > 1 { prev = t; t = gep_indexed_type(prev, i, c); }
        offset: u64;
        if i > 1 && type_kind(prev) == .STRUCT {
            offset = dl_struct_offset(prev, cast(u32) ap_zext_value(const_ap(c)));
        } else {
            count: u64 = ifx is_scalar_const_int(c) then ap_zext_value(const_ap(c)) else 1;
            offset = gep_seq_stride(ifx i > 1 then prev else NONE, i, t) * count;
        }
        result = min_align(offset, result);
    }
    return result;
}

ab_is_usefull_to_preserve :: (k: Attr_Kind) -> bool {
    return k == .NonNull || k == .NoUndef || k == .Alignment || k == .Dereferenceable || k == .DereferenceableOrNull || k == .Cold;
}
ab_is_int_attr_kind :: (k: Attr_Kind) -> bool { return k == .Alignment || k == .Dereferenceable || k == .DereferenceableOrNull; }

// canonicalizedKnowledge
ab_canonicalized_knowledge :: (rk_in: Ab_Knowledge) -> Ab_Knowledge {
    rk := rk_in;
    if rk.kind == .NonNull { rk.was_on = strip_in_bounds_offsets(rk.was_on); return rk; }
    if rk.kind == .Alignment {
        // stripInBoundsOffsets with a callback on every visited value
        v := rk.was_on;
        visited: [..] Value_Id; visited.allocator = temp;
        array_add(*visited, v);
        while true {
            if opr_code(v) == .GEP {
                x := rk.arg | gep_max_preserved_alignment(v);
                rk.arg = x & (~x + 1);
            }
            nv := strip_pointer_casts_one_step_in_bounds(v);
            if nv == v break;
            v = nv;
            seen := false;
            for visited if it == v { seen = true; break; }
            if seen break;
            array_add(*visited, v);
        }
        rk.was_on = v;
        return rk;
    }
    if rk.kind == .Dereferenceable || rk.kind == .DereferenceableOrNull {
        off := ap_zero(dl_index_type_size_bits(vtype(rk.was_on)));
        base, o := strip_and_accumulate_constant_offsets(rk.was_on, off, false);
        offset := ap_sext_value(o);
        if offset < 0 return rk;
        rk.arg = rk.arg + cast(u64) offset;
        rk.was_on = base;
    }
    return rk;
}
// one step of stripPointerCastsAndOffsets<PSK_InBounds> (returns v when it cannot be stripped)
strip_pointer_casts_one_step_in_bounds :: (v: Value_Id) -> Value_Id {
    if !is_ptr_type(vtype(v)) return v;
    o := opr_code(v);
    if o == .GEP { if (opr_flags(v) & F_INBOUNDS) == 0 return v; return op(v, 0); }
    if o == .BITCAST { nv := op(v, 0); if !is_ptr_type(vtype(nv)) return v; return nv; }
    if o == .ADDRSPACECAST return op(v, 0);
    if is_inst(v) && is_call_base(v) { rv := call_returned_arg(v); if rv != NONE return rv; }
    return v;
}

Assume_Builder :: struct {
    inst_being_modified: Value_Id = NONE;
    keys: [..] Ab_Knowledge;   // SmallMapVector<(WasOn, Kind), ArgValue>: insertion order
}

ab_is_knowledge_worth_preserving :: (b: *Assume_Builder, rk: Ab_Knowledge) -> bool {
    if rk.was_on == NONE return true;
    if is_ptr_type(vtype(rk.was_on)) {
        u := get_underlying_object(rk.was_on);
        if (is_inst(u) && inst_op(u) == .ALLOCA) || is_global_value(vkind(u)) return false;
    }
    if vkind(rk.was_on) == .ARGUMENT {
        at := attr_set_find(arg_attrs(rk.was_on), rk.kind);
        if at && (!ab_is_int_attr_kind(rk.kind) || at.ival >= rk.arg) return false;
        return true;
    }
    if is_inst(rk.was_on) && would_instruction_be_trivially_dead(rk.was_on, false) {   // TLI = nullptr
        if !has_uses(rk.was_on) return false;
        single: Use_Id = NONE;
        u := ir.v_first_use[rk.was_on];
        multiple := false;
        while u != NONE {
            usr := ir.u_user[u];
            droppable := is_inst(usr) && inst_op(usr) == .CALL &&
                         (call_iid(usr) == IID_ASSUME || intrinsic_id_of_call(usr) == "llvm.pseudoprobe" ||
                          intrinsic_id_of_call(usr) == "llvm.experimental.noalias.scope.decl");
            if !droppable { if single != NONE { multiple = true; break; } single = u; }
            u = ir.u_next[u];
        }
        if !multiple && single != NONE && ir.u_user[single] == b.inst_being_modified return false;
    }
    return true;
}

ab_add_knowledge :: (b: *Assume_Builder, rk_in: Ab_Knowledge) {
    rk := ab_canonicalized_knowledge(rk_in);
    if !ab_is_knowledge_worth_preserving(b, rk) return;
    // tryToPreserveWithoutAddingAssume: no AssumptionCache here
    for * b.keys if it.was_on == rk.was_on && it.kind == rk.kind { it.arg = max(it.arg, rk.arg); return; }
    array_add(*b.keys, rk);
}
ab_add_attribute :: (b: *Assume_Builder, a: Attr, was_on: Value_Id) {
    if a.kind == .STRING_ATTR || a.ty != NONE || !ab_is_usefull_to_preserve(a.kind) return;
    arg: u64 = ifx ab_is_int_attr_kind(a.kind) then a.ival else 0;
    ab_add_knowledge(b, .{a.kind, arg, was_on});
}
ab_add_call :: (b: *Assume_Builder, c: Value_Id) {
    add_attr_list :: (b: *Assume_Builder, c: Value_Id, l: u32, nargs: u32) {
        if nargs > 0 for idx: 0..nargs - 1 {
            for attr_set_items(attr_list_param(l, idx)) {
                is_poison_attr := it.kind == .NonNull || it.kind == .Alignment;
                passing_undef_ub := call_param_has_attr(c, idx, .NoUndef) || call_param_has_attr(c, idx, .Dereferenceable) ||
                                    call_param_has_attr(c, idx, .DereferenceableOrNull);
                if !is_poison_attr || passing_undef_ub ab_add_attribute(b, it, call_arg(c, idx));
            }
        }
        for attr_set_items(attr_list_fn(l)) ab_add_attribute(b, it, NONE);
    }
    add_attr_list(b, c, inst(c).attrs, call_num_args(c));
    f := call_called_function(c);
    if f != NONE add_attr_list(b, c, glob(f).attrs, glob(f).nargs);
}
ab_add_accessed_ptr :: (b: *Assume_Builder, mem_inst: Value_Id, ptr: Value_Id, acc_ty: Type_Id, align: u64) {
    deref := dl_type_store_size(acc_ty);
    if deref != 0 {
        ab_add_knowledge(b, .{.Dereferenceable, deref, ptr});
        if !null_pointer_is_defined(inst_fn(mem_inst), type_addrspace(vtype(ptr))) ab_add_knowledge(b, .{.NonNull, 0, ptr});
    }
    if max(align, 1) > 1 ab_add_knowledge(b, .{.Alignment, align, ptr});
}
ab_add_instruction :: (b: *Assume_Builder, i: Value_Id) {
    o := inst_op(i);
    if is_call_base(i) { ab_add_call(b, i); return; }
    if o == .LOAD { ab_add_accessed_ptr(b, i, op(i, 0), vtype(i), inst(i).align); return; }
    if o == .STORE { ab_add_accessed_ptr(b, i, op(i, 1), vtype(op(i, 0)), inst(i).align); return; }
    if o == .ATOMICRMW { ab_add_accessed_ptr(b, i, op(i, 0), vtype(op(i, 1)), inst(i).align); return; }
    if o == .CMPXCHG { ab_add_accessed_ptr(b, i, op(i, 0), vtype(op(i, 1)), inst(i).align); return; }
}
// build(): an unlinked `call void @llvm.assume(i1 true) [ bundles ]`, or NONE
ab_build :: (b: *Assume_Builder) -> Value_Id {
    if b.keys.count == 0 return NONE;
    f := get_or_insert_intrinsic_declaration(IID_ASSUME);
    nb := 0;
    for b.keys { if it.was_on != NONE nb += 1; if it.arg != 0 nb += 1; }
    i := new_inst(.CALL, ir.t_void, cast(u32)(1 + nb + 1));
    r := inst(i);
    r.ty2 = glob(f).value_type;
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) b.keys.count;
    pos: u32 = 1;
    for b.keys {
        array_add(*ir.u32_pool, bundle_tag_id(attr_name(it.kind)));
        array_add(*ir.u32_pool, pos);
        if it.was_on != NONE pos += 1;
        if it.arg != 0 pos += 1;
        array_add(*ir.u32_pool, pos);
    }
    set_op(i, 0, const_int(ir.t_i1, 1));
    set_op(i, cast(u32)(1 + nb), f);
    k: u32 = 1;
    for b.keys {
        if it.was_on != NONE { set_op(i, k, it.was_on); k += 1; }
        if it.arg != 0 { set_op(i, k, const_int(ir.t_i64, it.arg)); k += 1; }
    }
    return i;
}

// salvageKnowledge(I, AC = nullptr, DT = nullptr)
salvage_knowledge :: (i: Value_Id) -> bool {
    if !knowledge_retention.enabled || is_terminator(inst_op(i)) return false;
    b: Assume_Builder; b.inst_being_modified = i; b.keys.allocator = temp;
    ab_add_instruction(*b, i);
    a := ab_build(*b);
    if a == NONE return false;
    insert_at_position(a, inst_block(i), i, false);
    return true;
}
