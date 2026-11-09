// VectorCombine: scalar/vector interaction folds driven by the target cost model.
// Ported from llvm/lib/Transforms/Vectorize/VectorCombine.cpp (the whole pass: every fold, in LLVM's order, the
// worklist driver and VectorCombinePass::run). The InstructionWorklist is a second instance next to InstCombine's
// (`vc.wl`); the pass's IRBuilder<InstSimplifyFolder> is `vcb_*` (InstSimplify folding with SimplifyQuery(DL)),
// the local `IRBuilder<> Builder(I)` instances are plain `Irb`s (ConstantFolder, ir_builder.jai).
// Not ported (fail loudly when reached): VP intrinsics (scalarizeVPIntrinsic, foldBitcastOfVPLoad).

vc_cl: struct {
    disable: bool;                       // -disable-vector-combine
    disable_binop_extract_shuffle: bool; // -disable-binop-extract-shuffle
    max_instrs_to_scan: s64 = 30;        // -vector-combine-max-scan-instrs
};

vector_combine_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    parse_bool :: (p: *bool, name: string, value: string, has_value: bool) {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" p.* = true;
        else if value == "false" || value == "0" || value == "FALSE" || value == "False" p.* = false;
        else fatal("invalid boolean value '%' for option -%", value, name);
    }
    if name == "disable-vector-combine" { parse_bool(*vc_cl.disable, name, value, has_value); return true; }
    if name == "disable-binop-extract-shuffle" { parse_bool(*vc_cl.disable_binop_extract_shuffle, name, value, has_value); return true; }
    if name == "vector-combine-max-scan-instrs" {
        if !has_value fatal("option -% requires a value", name);
        v, ok := string_to_int(value);
        if !ok || v < 0 fatal("invalid value '%' for option -%", value, name);
        vc_cl.max_instrs_to_scan = cast(s64) v;
        return true;
    }
    return false;
}

VC_INVALID_INDEX :: 0xFFFF_FFFF;   // InvalidIndex = std::numeric_limits<unsigned>::max()

Vc_State :: struct {
    f: Value_Id;
    tti: *Tti;
    dt: *Dom_Tree;
    ac: *Assumption_Cache;
    aar: Aa_Results;
    kind: s64;                    // CostKind
    sq: Simplify_Query;           // SQ(*DL, nullptr, &DT, &AC)
    early_only: bool;             // TryEarlyFoldsOnly
    wl: [..] Value_Id;            // InstructionWorklist (no deferred list is used by this pass)
    wl_map: Table(Value_Id, s64);
    next_inst: Value_Id = NONE;   // NextInst
    b: Irb;                       // Builder
}
vc: Vc_State;

// ---------------------------------------------------------------- InstructionWorklist

vc_push :: (i: Value_Id) {
    if table_contains(*vc.wl_map, i) return;
    table_set(*vc.wl_map, i, vc.wl.count);
    array_add(*vc.wl, i);
}
vc_push_value :: (v: Value_Id) { if is_inst(v) vc_push(v); }
vc_remove :: (i: Value_Id) {
    found, idx := table_find(*vc.wl_map, i);
    if found { vc.wl[idx] = NONE; table_remove(*vc.wl_map, i); }
}
vc_remove_one :: () -> Value_Id {
    if vc.wl.count == 0 return NONE;
    i := pop(*vc.wl);
    if i != NONE table_remove(*vc.wl_map, i);
    return i;
}
vc_push_users :: (i: Value_Id) {
    u := ir.v_first_use[i];
    while u != NONE { vc_push(ir.u_user[u]); u = ir.u_next[u]; }
}

// replaceValue(Old, New, Erase)
vc_replace_value :: (old: Value_Id, new: Value_Id, erase := true) {
    rauw_with_metadata(old, new);
    if is_inst(new) {
        ic_take_name(new, old);
        vc_push_users(new);
        vc_push_value(new);
    }
    if erase && is_instruction_trivially_dead_tli(old, false) vc_erase_instruction(old);
    else vc_push(old);
}

// eraseInstruction(I)
vc_erase_instruction :: (i: Value_Id) {
    n := nops(i);
    ops := NewArray(n, Value_Id,, temp);
    for k: 0..cast(s64) n - 1 ops[k] = op(i, cast(u32) k);
    vc_remove(i);
    erase_inst_with_metadata(i);
    visited: [..] Value_Id; visited.allocator = temp;
    for o: ops {
        contains := false;
        for visited if it == o { contains = true; break; }
        if contains continue;
        if !is_inst(o) continue;
        if vc_recursively_delete_trivially_dead(o, *visited) continue;
        vc_push_users(o);
        vc_push_value(o);
    }
}

// RecursivelyDeleteTriviallyDeadInstructions(V, TLI = nullptr, MSSAU = nullptr, AboutToDeleteCallback) with
// eraseInstruction's callback (drop from the worklist, advance NextInst, remember as visited)
vc_recursively_delete_trivially_dead :: (v: Value_Id, visited: *[..] Value_Id) -> bool {
    if !is_inst(v) || !is_instruction_trivially_dead_tli(v, false) return false;
    dead: [..] Value_Id; dead.allocator = temp;
    array_add(*dead, v);
    while dead.count {
        i := pop(*dead);
        if vkind(i) == .DEAD continue;
        salvage_debug_info(i);
        vc_remove(i);
        if i == vc.next_inst vc.next_inst = inst(i).next;
        array_add(visited, i);
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            o := op(i, cast(u32) k);
            set_op(i, cast(u32) k, NONE);
            if o == NONE || has_uses(o) continue;
            if is_inst(o) && is_instruction_trivially_dead_tli(o, false) array_add(*dead, o);
        }
        erase_inst_with_metadata(i);
    }
    return true;
}

// ---------------------------------------------------------------- IRBuilder<InstSimplifyFolder>

// InstSimplifyFolder's SimplifyQuery(DL): no TLI, DT, AC or context
vcb_q :: () -> Simplify_Query { q: Simplify_Query; q.have_tli = false; q.no_tli_libcalls = true; return q; }

vcb_insert :: (i: Value_Id, name: string = "") -> Value_Id { return irb_insert(*vc.b, i, name); }

vcb_binop :: (opc: Opcode, l: Value_Id, r: Value_Id, name: string = "") -> Value_Id {
    f := simplify_binop(opc, l, r, vcb_q());
    if f != NONE return f;
    return vcb_insert(create_binop(opc, l, r), name);
}
// CreateOr(LHS, RHS, Name, IsDisjoint)
vcb_or_disjoint :: (l: Value_Id, r: Value_Id, disjoint: bool, name: string = "") -> Value_Id {
    f := simplify_binop(.OR, l, r, vcb_q());
    if f != NONE return f;
    i := create_binop(.OR, l, r);
    if disjoint inst(i).flags |= F_EXACT;
    return vcb_insert(i, name);
}
// CreateCmp / CreateICmp / CreateFCmp
vcb_cmp :: (pred: u8, l: Value_Id, r: Value_Id, name: string = "") -> Value_Id {
    f := simplify_cmp_inst(pred, false, l, r, vcb_q());
    if f != NONE return f;
    if is_fp_predicate(pred) return vcb_insert(create_fcmp(pred, l, r), name);
    return vcb_insert(create_icmp(pred, l, r), name);
}
// CreateShuffleVector(V1, V2, Mask); v2 = NONE: poison
vcb_shuffle :: (v1: Value_Id, v2_in: Value_Id, mask: [] s32, name: string = "") -> Value_Id {
    v2 := v2_in;
    if v2 == NONE v2 = const_poison(vtype(v1));
    m := mask_to_u32(mask);
    vt := vtype(v1);
    rt := type_vector(cast(u64) mask.count, type_elem(vt), type_kind(vt) == .SVECTOR);
    f := simplify_shuffle_vector_inst(v1, v2, m, rt, vcb_q());
    if f != NONE return f;
    return vcb_insert(create_shuffle(v1, v2, m), name);
}
vcb_extract_element :: (v: Value_Id, idx: Value_Id, name: string = "") -> Value_Id {
    f := simplify_extract_element_inst(v, idx, vcb_q());
    if f != NONE return f;
    i := new_inst(.EXTRACTELEMENT, type_elem(vtype(v)), 2);
    set_op(i, 0, v); set_op(i, 1, idx);
    return vcb_insert(i, name);
}
vcb_insert_element :: (v: Value_Id, e: Value_Id, idx: Value_Id, name: string = "") -> Value_Id {
    f := simplify_insert_element_inst(v, e, idx, vcb_q());
    if f != NONE return f;
    i := new_inst(.INSERTELEMENT, vtype(v), 3);
    set_op(i, 0, v); set_op(i, 1, e); set_op(i, 2, idx);
    return vcb_insert(i, name);
}
// CreateCast(Op, V, DestTy, Name, FMFSource); flags: nneg/nuw/nsw of the cast
vcb_cast :: (opc: Opcode, v: Value_Id, dt: Type_Id, name: string = "", flags: u32 = 0) -> Value_Id {
    if vtype(v) == dt return v;
    f := simplify_cast_inst(opc, v, dt, vcb_q());
    if f != NONE return f;
    i := create_cast(opc, v, dt);
    inst(i).flags |= flags;
    return vcb_insert(i, name);
}
// CreateSelect(C, True, False, Name, MDFrom) / CreateSelectFMF
vcb_select :: (c: Value_Id, t: Value_Id, f: Value_Id, name: string = "", md_from: Value_Id = NONE, fmf: u32 = 0) -> Value_Id {
    x := simplify_select_inst(c, t, f, fmf, vcb_q());
    if x != NONE return x;
    i := create_select(c, t, f);
    if md_from != NONE copy_prof_unpredictable(i, md_from);
    if is_fp_math_inst(i) set_fmf(i, fmf);
    return vcb_insert(i, name);
}
// CreateFNegFMF(V, FMFSource)
vcb_fneg_fmf :: (v: Value_Id, src: Value_Id, name: string = "") -> Value_Id {
    fmf := get_fmf(src);
    x := simplify_fp_unop(.FNEG, v, fmf, vcb_q());
    if x != NONE return x;
    return vcb_insert(create_fneg_fmf(v, src), name);
}
// CreateUnOp(Opc, V)
vcb_unop :: (opc: Opcode, v: Value_Id, name: string = "") -> Value_Id {
    x := simplify_fp_unop(opc, v, 0, vcb_q());
    if x != NONE return x;
    i := new_inst(opc, vtype(v), 1);
    set_op(i, 0, v);
    return vcb_insert(i, name);
}
// CreateNAryOp(Opc, Ops)
vcb_nary_op :: (opc: Opcode, ops: [] Value_Id, name: string = "") -> Value_Id {
    if ops.count == 1 return vcb_unop(opc, ops[0], name);
    return vcb_binop(opc, ops[0], ops[1], name);
}
// CreateInBoundsGEP(Ty, Ptr, IdxList, Name)
vcb_inbounds_gep :: (ty: Type_Id, ptr: Value_Id, idxs: [] Value_Id, name: string = "") -> Value_Id {
    x := simplify_gep_inst(ty, ptr, idxs, F_INBOUNDS | F_NUSW, vcb_q());
    if x != NONE return x;
    return vcb_insert(create_gep(ty, ptr, idxs, F_INBOUNDS), name);
}
// CreateFreeze(V, Name): never folded
vcb_freeze :: (v: Value_Id, name: string = "") -> Value_Id {
    i := new_inst(.FREEZE, vtype(v), 1);
    set_op(i, 0, v);
    return vcb_insert(i, name);
}
// CreateIntrinsic(RetTy, ID, Args, FMFSource, Name): FoldIntrinsic, else CreateIntrinsicWithoutFolding (the
// overload types come from matching the return and argument types against the intrinsic's signature)
vcb_intrinsic :: (ret_ty: Type_Id, id: Intrinsic_Id, args: [] Value_Id, fmf: u32 = 0, name: string = "") -> Value_Id {
    x := simplify_intrinsic(id, ret_ty, args, fmf, vcb_q(), vc.f, EB_IGNORE, RM_NEAREST_TIES_TO_EVEN);
    if x != NONE return x;
    return vcb_insert(vc_create_intrinsic_call(ret_ty, id, args, fmf), name);
}
// CreateIntrinsic(ID, OverloadTypes, Args, FMFSource, Name)
vcb_intrinsic_tys :: (id: Intrinsic_Id, otys: [] Type_Id, args: [] Value_Id, fmf: u32 = 0, name: string = "") -> Value_Id {
    ret_ty := func_ret(intrinsic_type(id, otys));
    x := simplify_intrinsic(id, ret_ty, args, fmf, vcb_q(), vc.f, EB_IGNORE, RM_NEAREST_TIES_TO_EVEN);
    if x != NONE return x;
    i := create_intrinsic_call(id, otys, args);
    if is_fp_math_inst(i) set_fmf(i, fmf);
    return vcb_insert(i, name);
}
// CallInst::Create(Intrinsic::getOrInsertDeclaration(M, ID, RetTy, ArgTys), Args) with FMF
vc_create_intrinsic_call :: (ret_ty: Type_Id, id: Intrinsic_Id, args: [] Value_Id, fmf: u32) -> Value_Id {
    tys := NewArray(args.count, Type_Id,, temp);
    for args tys[it_index] = vtype(it);
    ft := type_func(ret_ty, tys, false);
    otys: [..] Type_Id; otys.allocator = temp;
    if !intrinsic_signature_valid(id, ft, *otys) fatal("internal: vector-combine: intrinsic % does not accept these types", iid_name(id));
    i := create_intrinsic_call(id, otys, args);
    if is_fp_math_inst(i) set_fmf(i, fmf);
    return i;
}

// ---------------------------------------------------------------- small helpers

vc_is_op :: inline (v: Value_Id, opc: Opcode) -> bool { return is_inst(v) && inst_op(v) == opc; }
vc_is_binop :: inline (v: Value_Id) -> bool { return is_inst(v) && is_binary_op(inst_op(v)); }
vc_is_cmp :: inline (v: Value_Id) -> bool { return is_inst(v) && (inst_op(v) == .ICMP || inst_op(v) == .FCMP); }
vc_is_cast :: inline (v: Value_Id) -> bool { return is_inst(v) && is_cast_op(inst_op(v)); }
vc_is_fixed_vec :: inline (t: Type_Id) -> bool { return type_kind(t) == .VECTOR; }
vc_iid :: (v: Value_Id) -> Intrinsic_Id { if !is_inst(v) || inst_op(v) != .CALL return NOT_INTRINSIC; return call_iid(v); }
vc_prim_bits :: (t: Type_Id) -> u64 { b, _ := prim_size_bits(t); return b; }
vc_as :: (ptr: Value_Id) -> u32 { return cast(u32) ir.types[scalar_type(vtype(ptr))].a; }
vc_ptr_ty :: (as: u32) -> Type_Id { return type_ptr(as); }
vc_i64 :: (x: u64) -> Value_Id { return const_int(ir.t_i64, x); }
vc_i32 :: (x: u64) -> Value_Id { return const_int(type_int(32), x); }
vc_iota :: (n: s64) -> [..] s32 {
    m: [..] s32; m.allocator = temp;
    for k: 0..n-1 array_add(*m, cast(s32) k);
    return m;
}
vc_poison_mask :: (n: s64) -> [..] s32 {
    m: [..] s32; m.allocator = temp;
    for k: 0..n-1 array_add(*m, -1);
    return m;
}
vc_contains_s32 :: (m: [] s32, x: s32) -> bool { for m if it == x return true; return false; }
vc_masks_equal :: (a: [] s32, b: [] s32) -> bool {
    if a.count != b.count return false;
    for a if it != b[it_index] return false;
    return true;
}
// m_ExtractElt(m_Value(V), m_ConstantInt(C))
vc_match_extract_const :: (v: Value_Id) -> (bool, Value_Id, u64) {
    if !vc_is_op(v, .EXTRACTELEMENT) return false, NONE, 0;
    ok, c := pm_constant_int_u64(op(v, 1));
    if !ok return false, NONE, 0;
    return true, op(v, 0), c;
}
// m_InsertElt(m_Value(V), m_Value(E), m_ConstantInt(C))
vc_match_insert_const :: (v: Value_Id) -> (bool, Value_Id, Value_Id, u64) {
    if !vc_is_op(v, .INSERTELEMENT) return false, NONE, NONE, 0;
    ok, c := pm_constant_int_u64(op(v, 2));
    if !ok return false, NONE, NONE, 0;
    return true, op(v, 0), op(v, 1), c;
}
// peekThroughBitcasts
vc_peek_through_bitcasts :: (v_in: Value_Id) -> Value_Id {
    v := v_in;
    while vc_is_op(v, .BITCAST) v = op(v, 0);
    return v;
}
vc_cmp_result_type :: (t: Type_Id) -> Type_Id { return make_cmp_result_type(t); }
// TTI::getInstructionCost(U, CostKind) for an instruction or a constant (a non-operator constant is TCC_Basic)
vc_inst_cost :: (v: Value_Id) -> Cost {
    if is_inst(v) || vkind(v) == .C_EXPR return tti_instruction_cost(vc.tti, v, vc.kind);
    return TCC_BASIC;
}
vc_samesign :: (v: Value_Id) -> bool { return inst_op(v) == .ICMP && (inst(v).flags & F_EXACT) != 0; }

// ---------------------------------------------------------------- loads

// canWidenLoad
vc_can_widen_load :: (load: Value_Id) -> bool {
    if !vc_is_op(load, .LOAD) return false;
    if !is_simple_load_store(load) || !value_has_one_use(load) || fn_has_fn_attr(inst_fn(load), .SanitizeMemTag) || must_suppress_speculation(load)
        return false;
    sty := scalar_type(vtype(load));
    ssize := vc_prim_bits(sty);
    minv := tti_min_vector_register_bit_width(vc.tti);
    if ssize == 0 || minv == 0 || minv % ssize != 0 || ssize % 8 != 0 return false;
    return true;
}

// vectorizeLoadInsert
vc_vectorize_load_insert :: (i: Value_Id) -> bool {
    if !pm_poison(op(i, 0)) return false;
    scalar := op(i, 1);
    if !value_has_one_use(scalar) || !pm_zero_int(op(i, 2)) return false;
    x := scalar;
    has_extract := vc_is_op(scalar, .EXTRACTELEMENT) && pm_zero_int(op(scalar, 1));
    if has_extract x = op(scalar, 0);
    load := x;
    if !vc_can_widen_load(load) return false;
    scalar_ty := vtype(scalar);
    ssize := vc_prim_bits(scalar_ty);
    minv := tti_min_vector_register_bit_width(vc.tti);
    src_ptr := strip_pointer_casts(op(load, 0));
    min_n := minv / ssize;
    min_vec_ty := type_vector(min_n, scalar_ty, false);
    offset_elt: u64 = 0;
    align := inst(load).align;
    if !ld_is_safe_to_load_unconditionally_ty(src_ptr, min_vec_ty, 1, load, vc.sq.ac, vc.sq.dt) {
        bw := dl_index_type_size_bits(vtype(src_ptr));
        off: APInt;
        src_ptr, off = strip_and_accumulate_constant_offsets(src_ptr, ap_zero(bw), false);
        if ap_is_negative(off) return false;
        ssb := ssize / 8;
        o := ap_zext_value(off);
        if o % ssb != 0 return false;
        offset_elt = o / ssb;
        if offset_elt >= min_n return false;
        if !ld_is_safe_to_load_unconditionally_ty(src_ptr, min_vec_ty, 1, load, vc.sq.ac, vc.sq.dt) return false;
        align = common_alignment(align, o);
    }
    align = max(pointer_alignment(src_ptr), align);
    load_ty := vtype(load);
    as := vc_as(op(load, 0));
    old := tti_memory_op_cost(vc.tti, .LOAD, load_ty, align, as, vc.kind);
    dem := NewArray(cast(s64) min_n, bool,, temp);
    dem[0] = true;
    old = cost_add(old, tti_scalarization_overhead(vc.tti, min_vec_ty, dem, true, has_extract, vc.kind));
    new := tti_memory_op_cost(vc.tti, .LOAD, min_vec_ty, align, as, vc.kind);
    ty := vtype(i);
    out_n := cast(s64) type_count(ty);
    mask := vc_poison_mask(out_n);
    mask[0] = cast(s32) offset_elt;
    if offset_elt new = cost_add(new, tti_shuffle_cost(vc.tti, SK_PERMUTE_SINGLE_SRC, ty, min_vec_ty, mask, vc.kind, 0, NONE, .[], NONE));
    if old < new || !cost_valid(new) return false;
    b: Irb;
    irb_set_before(*b, load);
    casted := irb_pointer_bitcast_or_addrspacecast(*b, src_ptr, vc_ptr_ty(as));
    vec_ld := irb_load(*b, min_vec_ty, casted, align);
    vec_ld = irb_shuffle(*b, vec_ld, NONE, mask_to_u32(mask));
    vc_replace_value(i, vec_ld);
    return true;
}

// widenSubvectorLoad
vc_widen_subvector_load :: (i: Value_Id) -> bool {
    if !sv_is_identity_with_padding(i) return false;
    nop := cast(s64) type_count(vtype(op(i, 0)));
    op_index: u32 = 0;
    for shuf_mask(i) if it >= nop { op_index = 1; break; }
    load := op(i, op_index);
    if !vc_can_widen_load(load) return false;
    ty := vtype(i);
    src_ptr := strip_pointer_casts(op(load, 0));
    align := inst(load).align;
    if !ld_is_safe_to_load_unconditionally_ty(src_ptr, ty, 1, load, vc.sq.ac, vc.sq.dt) return false;
    align = max(pointer_alignment(src_ptr), align);
    load_ty := vtype(load);
    as := vc_as(op(load, 0));
    old := tti_memory_op_cost(vc.tti, .LOAD, load_ty, align, as, vc.kind);
    new := tti_memory_op_cost(vc.tti, .LOAD, ty, align, as, vc.kind);
    if old < new || !cost_valid(new) return false;
    b: Irb;
    irb_set_before(*b, load);
    casted := irb_pointer_bitcast_or_addrspacecast(*b, src_ptr, vc_ptr_ty(as));
    vec_ld := irb_load(*b, ty, casted, align);
    vc_replace_value(i, vec_ld);
    return true;
}

// ---------------------------------------------------------------- extract-extract

// getShuffleExtract
vc_get_shuffle_extract :: (ext0: Value_Id, ext1: Value_Id, preferred: u32 = VC_INVALID_INDEX) -> Value_Id {
    _, idx0 := pm_constant_int_u64(op(ext0, 1));
    _, idx1 := pm_constant_int_u64(op(ext1, 1));
    i0 := cast(u32) idx0; i1 := cast(u32) idx1;
    if i0 == i1 return NONE;
    vec_ty := vtype(op(ext0, 0));
    c0 := tti_vector_inst_cost(vc.tti, ext0, vec_ty, vc.kind, i0);
    c1 := tti_vector_inst_cost(vc.tti, ext1, vec_ty, vc.kind, i1);
    if !cost_valid(c0) && !cost_valid(c1) return NONE;
    if c0 > c1 return ext0;
    if c1 > c0 return ext1;
    if preferred == i0 return ext1;
    if preferred == i1 return ext0;
    return ifx i0 > i1 then ext0 else ext1;
}

// isExtractExtractCheap: (cheap, ConvertToShuffle)
vc_is_extract_extract_cheap :: (ext0: Value_Id, ext1: Value_Id, i: Value_Id, preferred: u32) -> (bool, Value_Id) {
    opc := inst_op(i);
    src0 := op(ext0, 0); src1 := op(ext1, 0);
    sty := vtype(ext0);
    vec_ty := vtype(src0);
    scalar_cost, vector_cost: Cost;
    is_binop := is_binary_op(opc);
    if is_binop {
        scalar_cost = tti_arith_cost(vc.tti, opc, sty, vc.kind);
        vector_cost = tti_arith_cost(vc.tti, opc, vec_ty, vc.kind);
    } else {
        pred := inst(i).pred;
        scalar_cost = tti_cmp_sel_cost(vc.tti, opc, sty, vc_cmp_result_type(sty), pred, vc.kind);
        vector_cost = tti_cmp_sel_cost(vc.tti, opc, vec_ty, vc_cmp_result_type(vec_ty), pred, vc.kind);
    }
    _, x0 := pm_constant_int_u64(op(ext0, 1));
    _, x1 := pm_constant_int_u64(op(ext1, 1));
    e0 := cast(u32) x0; e1 := cast(u32) x1;
    ec0 := tti_vector_inst_cost(vc.tti, ext0, vec_ty, vc.kind, e0);
    ec1 := tti_vector_inst_cost(vc.tti, ext1, vec_ty, vc.kind, e1);
    best_ext := ifx ec0 > ec1 then e0 else e1;
    best_ins := ifx ec0 > ec1 then e1 else e0;
    cheap := min(ec0, ec1);
    old, new: Cost;
    if src0 == src1 && e0 == e1 {
        tax := ifx ext0 == ext1 then !has_n_uses(ext0, 2) else (!value_has_one_use(ext0) || !value_has_one_use(ext1));
        old = cost_add(cheap, scalar_cost);
        new = cost_add(cost_add(vector_cost, cheap), ifx tax then cheap else 0);
    } else {
        old = cost_add(cost_add(ec0, ec1), scalar_cost);
        new = cost_add(vector_cost, cheap);
        if !value_has_one_use(ext0) new = cost_add(new, ec0);
        if !value_has_one_use(ext1) new = cost_add(new, ec1);
    }
    conv := vc_get_shuffle_extract(ext0, ext1, preferred);
    if conv != NONE {
        if is_binop && vc_cl.disable_binop_extract_shuffle return true, conv;
        if vc_is_fixed_vec(vec_ty) {
            m := vc_poison_mask(cast(s64) type_count(vec_ty));
            m[best_ins] = cast(s32) best_ext;
            new = cost_add(new, tti_shuffle_cost(vc.tti, SK_PERMUTE_SINGLE_SRC, vec_ty, vec_ty, m, vc.kind, 0, NONE, .[conv], NONE));
        } else {
            new = cost_add(new, tti_shuffle_cost(vc.tti, SK_PERMUTE_SINGLE_SRC, vec_ty, vec_ty, .[], vc.kind, 0, NONE, .[conv], NONE));
        }
    }
    return old < new, conv;
}

// createShiftShuffle
vc_create_shift_shuffle :: (vec: Value_Id, old_index: u64, new_index: u64) -> Value_Id {
    m := vc_poison_mask(cast(s64) type_count(vtype(vec)));
    m[new_index] = cast(s32) old_index;
    return vcb_shuffle(vec, NONE, m, "shift");
}
// translateExtract
vc_translate_extract :: (ext: Value_Id, new_index: u64) -> Value_Id {
    x := op(ext, 0);
    if !vc_is_fixed_vec(vtype(x)) return NONE;
    if is_const(x) return NONE;
    _, c := pm_constant_int_u64(op(ext, 1));
    return vc_create_shift_shuffle(x, c, new_index);
}

// foldExtractExtract
vc_fold_extract_extract :: (i: Value_Id) -> bool {
    if !is_safe_to_speculatively_execute(i) return false;
    is_cmp := vc_is_cmp(i);
    if !is_cmp && !vc_is_binop(i) return false;
    i0 := op(i, 0); i1 := op(i, 1);
    if !is_inst(i0) || !is_inst(i1) return false;
    ok0, v0, c0 := vc_match_extract_const(i0);
    if !ok0 return false;
    ok1, v1, c1 := vc_match_extract_const(i1);
    if !ok1 || vtype(v0) != vtype(v1) return false;
    if vc_is_fixed_vec(vtype(v0)) {
        n := type_count(vtype(v0));
        if c0 >= n || c1 >= n return false;
    }
    ext0 := i0; ext1 := i1;
    insert_index: u64 = VC_INVALID_INDEX;
    if value_has_one_use(i) {
        oki, _, _, ii := vc_match_insert_const(first_user(i));
        if oki insert_index = ii;
    }
    cheap, to_change := vc_is_extract_extract_cheap(ext0, ext1, i, cast,no_check(u32) insert_index);
    if cheap return false;
    ext_op0 := op(ext0, 0); ext_op1 := op(ext1, 0);
    if to_change != NONE {
        cheap_idx := ifx to_change == ext0 then c1 else c0;
        new_op := vc_translate_extract(to_change, cheap_idx);
        if new_op == NONE return false;
        if to_change == ext0 ext_op0 = new_op; else ext_op1 = new_op;
    }
    ext_index := ifx to_change == ext0 then op(ext1, 1) else op(ext0, 1);
    new_ext: Value_Id;
    if is_cmp {
        vcmp := vcb_cmp(inst(i).pred, ext_op0, ext_op1);
        new_ext = vcb_extract_element(vcmp, ext_index, "foldExtExtCmp");
    } else {
        vbo := vcb_binop(inst_op(i), ext_op0, ext_op1, "foldExtExtBinop");
        if is_inst(vbo) copy_ir_flags(vbo, i);
        new_ext = vcb_extract_element(vbo, ext_index, "foldExtExtBinop");
    }
    vc_push(ext0);
    vc_push(ext1);
    vc_replace_value(i, new_ext);
    return true;
}

// ---------------------------------------------------------------- insert/extract folds

// foldInsExtFNeg
vc_fold_ins_ext_fneg :: (i: Value_Id) -> bool {
    ok, dst_vec, fneg, ins_idx := vc_match_insert_const(i);
    if !ok || !is_inst(fneg) || !value_has_one_use(fneg) return false;
    okf, ext := pm_fneg(fneg);
    if !okf || !is_inst(ext) return false;
    oke, src_vec, ext_idx := vc_match_extract_const(ext);
    if !oke return false;
    dst_ty := vtype(dst_vec);
    dst_sty := scalar_type(dst_ty);
    src_ty := vtype(src_vec);
    if !vc_is_fixed_vec(src_ty) || dst_sty != type_elem(src_ty) return false;
    nd := type_count(dst_ty); ns := type_count(src_ty);
    if ext_idx > ns || ins_idx >= nd || nd == 1 return false;
    mask := vc_iota(cast(s64) nd);
    mask[ins_idx] = cast(s32) ((ext_idx % nd) + nd);
    old := cost_add(tti_arith_cost(vc.tti, .FNEG, dst_sty, vc.kind), tti_vector_inst_cost(vc.tti, i, dst_ty, vc.kind, cast(u32) ins_idx));
    if value_has_one_use(ext) old = cost_add(old, tti_vector_inst_cost(vc.tti, ext, src_ty, vc.kind, cast(u32) ext_idx));
    new := cost_add(tti_arith_cost(vc.tti, .FNEG, src_ty, vc.kind),
                    tti_shuffle_cost(vc.tti, SK_PERMUTE_TWO_SRC, dst_ty, dst_ty, mask, vc.kind, 0, NONE, .[], NONE));
    need_len_chg := ns != nd;
    src_mask: [..] s32;
    if need_len_chg {
        src_mask = vc_poison_mask(cast(s64) nd);
        src_mask[ext_idx % nd] = cast(s32) ext_idx;
        new = cost_add(new, tti_shuffle_cost(vc.tti, SK_PERMUTE_SINGLE_SRC, dst_ty, src_ty, src_mask, vc.kind, 0, NONE, .[], NONE));
    }
    if new > old return false;
    vfneg := vcb_fneg_fmf(src_vec, fneg);
    new_shuf: Value_Id;
    if need_len_chg {
        len_chg := vcb_shuffle(vfneg, NONE, src_mask);
        new_shuf = vcb_shuffle(dst_vec, len_chg, mask);
        vc_push_value(len_chg);
    } else {
        new_shuf = vcb_shuffle(dst_vec, vfneg, mask);
    }
    vc_push_value(vfneg);
    vc_replace_value(i, new_shuf);
    return true;
}

// foldInsExtBinop
vc_fold_ins_ext_binop :: (i: Value_Id) -> bool {
    vbo := op(i, 0); sbo := op(i, 1);
    if !vc_is_binop(vbo) || !value_has_one_use(vbo) || !vc_is_binop(sbo) || !value_has_one_use(sbo) return false;
    ok, index := pm_constant_int_u64(op(i, 2));
    if !ok return false;
    opc := inst_op(vbo);
    if opc != inst_op(sbo) return false;
    rt := vtype(i);
    if !vc_is_fixed_vec(rt) return false;
    old := cost_add(cost_add(tti_instruction_cost(vc.tti, i, vc.kind), tti_instruction_cost(vc.tti, vbo, vc.kind)), tti_instruction_cost(vc.tti, sbo, vc.kind));
    new := tti_arith_cost(vc.tti, opc, rt, vc.kind);
    new = cost_add(new, tti_vector_instr_cost(vc.tti, .INSERTELEMENT, rt, vc.kind, cast(u32) index, op(vbo, 0), op(sbo, 0)));
    new = cost_add(new, tti_vector_instr_cost(vc.tti, .INSERTELEMENT, rt, vc.kind, cast(u32) index, op(vbo, 1), op(sbo, 1)));
    if new > old return false;
    ni0 := vcb_insert_element(op(vbo, 0), op(sbo, 0), vc_i64(index));
    ni1 := vcb_insert_element(op(vbo, 1), op(sbo, 1), vc_i64(index));
    nbo := vcb_binop(opc, ni0, ni1);
    if is_inst(nbo) { copy_ir_flags(nbo, vbo); and_ir_flags(nbo, sbo); }
    vc_push_value(ni0);
    vc_push_value(ni1);
    vc_replace_value(i, nbo);
    return true;
}

// foldInsExtVectorToShuffle
vc_fold_ins_ext_vector_to_shuffle :: (i: Value_Id) -> bool {
    ok, dst_vec, e, ins_idx := vc_match_insert_const(i);
    if !ok return false;
    oke, src_vec, ext_idx := vc_match_extract_const(e);
    if !oke return false;
    dst_ty := vtype(i); src_ty := vtype(src_vec);
    if !vc_is_fixed_vec(dst_ty) || !vc_is_fixed_vec(src_ty) || type_elem(src_ty) != type_elem(dst_ty) return false;
    nd := type_count(dst_ty); ns := type_count(src_ty);
    if ins_idx >= nd || ext_idx >= ns || nd == 1 return false;
    sk: s64;
    mask := vc_poison_mask(cast(s64) nd);
    need_exp := ns != nd;
    need_swap := pm_poison(dst_vec) && !pm_undef_value(src_vec);
    if need_swap {
        sk = SK_PERMUTE_SINGLE_SRC;
        mask[ins_idx] = cast(s32) (ext_idx % nd);
        t := dst_vec; dst_vec = src_vec; src_vec = t;
    } else {
        sk = SK_PERMUTE_TWO_SRC;
        for k: 0..cast(s64) nd - 1 mask[k] = cast(s32) k;
        mask[ins_idx] = cast(s32) ((ext_idx % nd) + nd);
    }
    ins_cost := tti_vector_inst_cost(vc.tti, i, dst_ty, vc.kind, cast(u32) ins_idx);
    ext_cost := tti_vector_inst_cost(vc.tti, e, dst_ty, vc.kind, cast(u32) ext_idx);
    old := cost_add(ext_cost, ins_cost);
    new: Cost = 0;
    ext_to_vec: [..] s32;
    if !need_exp {
        if !svm_is_identity(mask, cast(s64) ns)
            new = cost_add(new, tti_shuffle_cost(vc.tti, sk, dst_ty, dst_ty, mask, vc.kind, 0, NONE, .[dst_vec, src_vec], NONE));
    } else {
        ext_to_vec = vc_poison_mask(cast(s64) nd);
        ext_to_vec[ext_idx % nd] = cast(s32) ext_idx;
        new = tti_shuffle_cost(vc.tti, SK_PERMUTE_SINGLE_SRC, dst_ty, src_ty, ext_to_vec, vc.kind, 0, NONE, .[], NONE);
        new = cost_add(new, tti_shuffle_cost(vc.tti, sk, dst_ty, dst_ty, mask, vc.kind, 0, NONE, .[], NONE));
    }
    if !value_has_one_use(e) new = cost_add(new, ext_cost);
    if old < new return false;
    if need_exp {
        if !need_swap src_vec = vcb_shuffle(src_vec, NONE, ext_to_vec);
        else dst_vec = vcb_shuffle(dst_vec, NONE, ext_to_vec);
    }
    if pm_undef_value(dst_vec) && !pm_undef_value(src_vec) {
        commute_shuffle_mask(*mask, cast(s64) nd);
        t := dst_vec; dst_vec = src_vec; src_vec = t;
    }
    shuf := vcb_shuffle(dst_vec, src_vec, mask);
    vc_replace_value(i, shuf);
    return true;
}

// ---------------------------------------------------------------- bit ops of casts

vc_cast_supported :: (opc: Opcode) -> bool { return opc == .BITCAST || opc == .TRUNC || opc == .SEXT || opc == .ZEXT; }

// foldBitOpOfCastops
vc_fold_bit_op_of_castops :: (i: Value_Id) -> bool {
    if !vc_is_binop(i) || !is_bitwise_logic_op(inst_op(i)) return false;
    lc := op(i, 0); rc := op(i, 1);
    if !vc_is_cast(lc) || !vc_is_cast(rc) return false;
    copc := inst_op(lc);
    if copc != inst_op(rc) return false;
    if !vc_cast_supported(copc) return false;
    ls := op(lc, 0); rs := op(rc, 0);
    if vtype(ls) != vtype(rs) return false;
    src_ty := vtype(ls); dst_ty := vtype(i);
    if copc != .BITCAST && (!vc_is_fixed_vec(src_ty) || !vc_is_fixed_vec(dst_ty)) return false;
    if !is_int_type(scalar_type(src_ty)) || !is_int_type(scalar_type(dst_ty)) return false;
    lcost := tti_cast_cost(vc.tti, copc, dst_ty, src_ty, CCH_NONE, vc.kind, lc);
    rcost := tti_cast_cost(vc.tti, copc, dst_ty, src_ty, CCH_NONE, vc.kind, rc);
    old := cost_add(cost_add(tti_arith_cost(vc.tti, inst_op(i), dst_ty, vc.kind), lcost), rcost);
    generic := tti_cast_cost(vc.tti, copc, dst_ty, src_ty, CCH_NONE, vc.kind);
    new := cost_add(tti_arith_cost(vc.tti, inst_op(i), src_ty, vc.kind), generic);
    if !value_has_one_use(lc) new = cost_add(new, lcost);
    if !value_has_one_use(rc) new = cost_add(new, rcost);
    if new > old return false;
    nop := vcb_binop(inst_op(i), ls, rs, tprint("%.inner", vname(i)));
    if vc_is_binop(nop) copy_ir_flags(nop, i);
    vc_push_value(nop);
    nc := create_cast(copc, nop, vtype(i));
    copy_ir_flags(nc, lc);
    and_ir_flags(nc, rc);
    res := vcb_insert(nc);
    vc_replace_value(i, res);
    return true;
}

// getLosslessInvCast(C, InvCastTo, CastOp, DL, &Flags): (constant, nneg, nuw, nsw)
vc_get_lossless_inv_cast :: (c: Value_Id, to: Type_Id, cast_op: Opcode) -> (Value_Id, bool, bool, bool) {
    if cast_op == {
        case .BITCAST; return cfo_cast_operand(.BITCAST, c, to), false, false, false;
        case .TRUNC;
            z := cfo_cast_operand(.ZEXT, c, to);
            s := cfo_cast_operand(.SEXT, c, to);
            return z, false, true, z == s;
        case .SEXT; #through;
        case .ZEXT;
            inv := ce_cast(.TRUNC, c, to);
            back := cfo_cast_operand(cast_op, inv, vtype(c));
            if back == NONE || back != c return NONE, false, false, false;
            nneg := false;
            if cast_op == .ZEXT { sx := cfo_cast_operand(.SEXT, inv, vtype(c)); nneg = back == sx; }
            return inv, nneg, false, false;
        case .FPEXT;
            inv := cfo_cast_operand(.FPTRUNC, c, to);
            if inv != NONE { back := cfo_cast_operand(cast_op, inv, vtype(c)); if back == c return inv, false, false, false; }
            return NONE, false, false, false;
    }
    return NONE, false, false, false;
}

// foldBitOpOfCastConstant
vc_fold_bit_op_of_cast_constant :: (i: Value_Id) -> bool {
    if !vc_is_binop(i) || !is_bitwise_logic_op(inst_op(i)) return false;
    // m_c_BitwiseLogic(m_Instruction(LHS), m_Constant(C))
    lhs: Value_Id = NONE; c: Value_Id = NONE;
    if is_inst(op(i, 0)) && is_const(op(i, 1)) { lhs = op(i, 0); c = op(i, 1); }
    else if is_inst(op(i, 1)) && is_const(op(i, 0)) { lhs = op(i, 1); c = op(i, 0); }
    else return false;
    if !vc_is_cast(lhs) return false;
    copc := inst_op(lhs);
    if !vc_cast_supported(copc) return false;
    ls := op(lhs, 0);
    src_ty := vtype(ls); dst_ty := vtype(i);
    if copc != .BITCAST && (!vc_is_fixed_vec(src_ty) || !vc_is_fixed_vec(dst_ty)) return false;
    if !is_int_type(scalar_type(src_ty)) || !is_int_type(scalar_type(dst_ty)) return false;
    inv, nneg, nuw, nsw := vc_get_lossless_inv_cast(c, src_ty, copc);
    if inv == NONE return false;
    lcost := tti_cast_cost(vc.tti, copc, dst_ty, src_ty, CCH_NONE, vc.kind, lhs);
    old := cost_add(tti_arith_cost(vc.tti, inst_op(i), dst_ty, vc.kind), lcost);
    generic := tti_cast_cost(vc.tti, copc, dst_ty, src_ty, CCH_NONE, vc.kind);
    new := cost_add(tti_arith_cost(vc.tti, inst_op(i), src_ty, vc.kind), generic);
    if !value_has_one_use(lhs) new = cost_add(new, lcost);
    if new > old return false;
    nop := vcb_binop(inst_op(i), ls, inv, tprint("%.inner", vname(i)));
    if vc_is_binop(nop) copy_ir_flags(nop, i);
    vc_push_value(nop);
    nc := create_cast(copc, nop, vtype(i));
    if nneg inst(nc).flags |= F_EXACT;
    if nuw inst(nc).flags |= F_NUW;
    if nsw inst(nc).flags |= F_NSW;
    and_ir_flags(nc, lhs);
    res := vcb_insert(nc);
    vc_replace_value(i, res);
    return true;
}

// foldBitcastShuffle
vc_fold_bitcast_shuffle :: (i: Value_Id) -> bool {
    sh := op(i, 0);
    if !vc_is_op(sh, .SHUFFLEVECTOR) || !value_has_one_use(sh) return false;
    v0 := op(sh, 0); v1 := op(sh, 1);
    mask := shuf_mask(sh);
    dest_ty := vtype(i); src_ty := vtype(v0);
    if !vc_is_fixed_vec(dest_ty) || !vc_is_fixed_vec(src_ty) return false;
    dest_elt := vc_prim_bits(type_elem(dest_ty));
    src_elt := vc_prim_bits(type_elem(src_ty));
    src_bits := vc_prim_bits(src_ty);
    if src_bits % dest_elt != 0 return false;
    is_unary := pm_undef_value(v1);
    if !is_unary {
        t0 := vtype(vc_peek_through_bitcasts(v0));
        t1 := vtype(vc_peek_through_bitcasts(v1));
        ok0 := vc_is_fixed_vec(t0) && type_elem(t0) == type_elem(dest_ty);
        ok1 := vc_is_fixed_vec(t1) && type_elem(t1) == type_elem(dest_ty);
        if !ok0 && !ok1 return false;
    }
    new_mask: [..] s32;
    if dest_elt <= src_elt {
        if src_elt % dest_elt != 0 return false;
        new_mask = narrow_shuffle_mask_elts(cast(s64) (src_elt / dest_elt), mask);
    } else {
        if dest_elt % src_elt != 0 return false;
        ok: bool;
        ok, new_mask = widen_shuffle_mask_elts(cast(s64) (dest_elt / src_elt), mask);
        if !ok return false;
    }
    nsrc := src_bits / dest_elt;
    new_shuffle_ty := type_vector(nsrc, type_elem(dest_ty), false);
    old_shuffle_ty := type_vector(cast(u64) mask.count, type_elem(src_ty), false);
    num_ops: Cost = ifx is_unary then 1 else 2;
    sk := ifx is_unary then SK_PERMUTE_SINGLE_SRC else SK_PERMUTE_TWO_SRC;
    new := cost_add(tti_shuffle_cost(vc.tti, sk, dest_ty, new_shuffle_ty, new_mask, vc.kind, 0, NONE, .[], NONE),
                    cost_mul(num_ops, tti_cast_cost(vc.tti, .BITCAST, new_shuffle_ty, src_ty, CCH_NONE, vc.kind)));
    old := cost_add(tti_shuffle_cost(vc.tti, sk, old_shuffle_ty, src_ty, mask, vc.kind, 0, NONE, .[], NONE),
                    tti_cast_cost(vc.tti, .BITCAST, dest_ty, old_shuffle_ty, CCH_NONE, vc.kind));
    if new > old || !cost_valid(new) return false;
    cv0 := vcb_cast(.BITCAST, vc_peek_through_bitcasts(v0), new_shuffle_ty);
    cv1 := vcb_cast(.BITCAST, vc_peek_through_bitcasts(v1), new_shuffle_ty);
    shuf := vcb_shuffle(cv0, cv1, new_mask);
    vc_replace_value(i, shuf);
    return true;
}

// scalarizeVPIntrinsic (only the matching is ported: a VP intrinsic that would be scalarized fails loudly)
vc_scalarize_vp_intrinsic :: (i: Value_Id) -> bool {
    id := vc_iid(i);
    if !is_vp_intrinsic(id) return false;
    o0 := call_arg(i, 0); o1 := call_arg(i, 1);
    if !is_splat_value(o0) || !is_splat_value(o1) return false;
    if vt_get_splat_value(o0) == NONE || vt_get_splat_value(o1) == NONE return false;
    m := vt_get_splat_value(call_arg(i, 2));
    if m == NONE || !is_const(m) || !cf_is_all_ones(m) return false;
    fatal("vector-combine: scalarizing VP intrinsics (%) is not supported yet", iid_name(id));
    return false;
}

// ---------------------------------------------------------------- scalarization

// scalarizeOpOrCmp
vc_scalarize_op_or_cmp :: (i: Value_Id) -> bool {
    opc := inst_op(i);
    is_uo := opc == .FNEG;
    is_bo := is_binary_op(opc);
    is_ci := opc == .ICMP || opc == .FCMP;
    iid := vc_iid(i);
    is_ii := iid != NOT_INTRINSIC;
    if !is_uo && !is_bo && !is_ci && !is_ii return false;
    nargs: s64 = ifx is_ii then cast(s64) call_num_args(i) else cast(s64) nops(i);
    if is_ii {
        if !is_trivially_vectorizable(iid) return false;
        for k: 0..nargs-1
            if vtype(call_arg(i, cast(u32) k)) != vtype(i) && !vu_is_vector_intrinsic_with_scalar_op_at_arg(iid, cast(u32) k) return false;
    }
    if is_ci {
        u := ir.v_first_use[i];
        while u != NONE {
            usr := ir.u_user[u];
            if vc_is_op(usr, .SELECT) && op(usr, 0) == i return false;
            u = ir.u_next[u];
        }
    }
    vec_cs: [..] Value_Id; vec_cs.allocator = temp;
    scalar_ops: [..] Value_Id; scalar_ops.allocator = temp;
    has_index := false; index: u64 = 0;
    for k: 0..nargs-1 {
        o := op(i, cast(u32) k);
        oki, vecc, v, ins_idx := vc_match_insert_const(o);
        if oki && is_const(vecc) {
            if type_count(vtype(o)) <= ins_idx return false;
            if !has_index { has_index = true; index = ins_idx; }
            else if ins_idx != index return false;
            array_add(*vec_cs, vecc);
            array_add(*scalar_ops, v);
        } else if is_ii && vu_is_vector_intrinsic_with_scalar_op_at_arg(iid, cast(u32) k) {
            array_add(*vec_cs, o);
            array_add(*scalar_ops, o);
        } else if is_const(o) {
            array_add(*vec_cs, o);
            array_add(*scalar_ops, NONE);
        } else return false;
    }
    if !has_index return false;
    vec_ty := vtype(i);
    sty := scalar_type(vec_ty);
    scalar_cost, vector_cost: Cost;
    if is_ci {
        pred := inst(i).pred;
        scalar_cost = tti_cmp_sel_cost(vc.tti, opc, sty, vc_cmp_result_type(sty), pred, vc.kind);
        vector_cost = tti_cmp_sel_cost(vc.tti, opc, vec_ty, vc_cmp_result_type(vec_ty), pred, vc.kind);
    } else if is_uo || is_bo {
        scalar_cost = tti_arith_cost(vc.tti, opc, sty, vc.kind);
        vector_cost = tti_arith_cost(vc.tti, opc, vec_ty, vc.kind);
    } else {
        stys := NewArray(nargs, Type_Id,, temp); for * stys it.* = sty;
        vtys := NewArray(nargs, Type_Id,, temp); for * vtys it.* = vec_ty;
        sa := ica_types(iid, sty, stys);
        scalar_cost = tti_intrinsic_cost(vc.tti, *sa, vc.kind);
        va := ica_types(iid, vec_ty, vtys);
        vector_cost = tti_intrinsic_cost(vc.tti, *va, vc.kind);
    }
    new_vec_c: Value_Id = NONE;
    if is_ci new_vec_c = simplify_cmp_inst(inst(i).pred, false, vec_cs[0], vec_cs[1], vc.sq);
    else if is_uo new_vec_c = simplify_fp_unop(opc, vec_cs[0], get_fmf(i), vc.sq);
    else if is_bo new_vec_c = simplify_binop(opc, vec_cs[0], vec_cs[1], vc.sq);
    else new_vec_c = simplify_call(i, call_callee(i), vec_cs, vc.sq);
    if new_vec_c == NONE return false;
    old := vector_cost;
    new := cost_add(scalar_cost, tti_vector_instr_cost(vc.tti, .INSERTELEMENT, vec_ty, vc.kind, cast(u32) index, new_vec_c));
    for k: 0..nargs-1 {
        sc := scalar_ops[k];
        if sc == NONE || (is_ii && vu_is_vector_intrinsic_with_scalar_op_at_arg(iid, cast(u32) k)) continue;
        ins := tti_vector_instr_cost(vc.tti, .INSERTELEMENT, vec_ty, vc.kind, cast(u32) index, vec_cs[k], sc);
        old = cost_add(old, ins);
        if !value_has_one_use(op(i, cast(u32) k)) new = cost_add(new, ins);
    }
    if old < new || !cost_valid(new) return false;
    for k: 0..nargs-1 if scalar_ops[k] == NONE scalar_ops[k] = ce_extract_element(vec_cs[k], vc_i64(index));
    scalar: Value_Id;
    if is_ci scalar = vcb_cmp(inst(i).pred, scalar_ops[0], scalar_ops[1]);
    else if is_uo || is_bo scalar = vcb_nary_op(opc, scalar_ops);
    else scalar = vcb_intrinsic(sty, iid, scalar_ops);
    if !is_const(scalar) set_name(scalar, tprint("%.scalar", vname(i)));   // Value::setName is a no-op on constants
    if is_inst(scalar) copy_ir_flags(scalar, i);
    ins := vcb_insert_element(new_vec_c, scalar, vc_i64(index));
    vc_replace_value(i, ins);
    return true;
}

// foldExtractedCmps
vc_fold_extracted_cmps :: (i: Value_Id) -> bool {
    if !vc_is_binop(i) || vtype(i) != ir.t_i1 return false;
    b0 := op(i, 0); b1 := op(i, 1);
    if !vc_is_cmp(b0) || !vc_is_cmp(b1) return false;
    i0 := op(b0, 0); c0 := op(b0, 1); i1 := op(b1, 0); c1 := op(b1, 1);
    if !is_inst(i0) || !is_const(c0) || !is_inst(i1) || !is_const(c1) return false;
    okm, mpred, _ := cmp_get_matching(inst(b0).pred, vc_samesign(b0), inst(b1).pred, vc_samesign(b1));
    if !okm return false;
    ok0, x, index0 := vc_match_extract_const(i0);
    if !ok0 return false;
    ok1, x1, index1 := vc_match_extract_const(i1);
    if !ok1 || x1 != x return false;
    ext0 := i0; ext1 := i1;
    // getShuffleExtract(Ext0, Ext1, CostKind): the cost kind lands in the PreferredExtractIndex parameter
    conv := vc_get_shuffle_extract(ext0, ext1, cast(u32) vc.kind);
    if conv == NONE return false;
    pred := mpred;
    cmp_opc: Opcode = ifx is_fp_predicate(pred) then .FCMP else .ICMP;
    vec_ty := vtype(x);
    if !vc_is_fixed_vec(vec_ty) return false;
    n := type_count(vec_ty);
    if index0 >= n || index1 >= n return false;
    ext0_cost := tti_vector_inst_cost(vc.tti, ext0, vec_ty, vc.kind, cast(u32) index0);
    ext1_cost := tti_vector_inst_cost(vc.tti, ext1, vec_ty, vc.kind, cast(u32) index1);
    cmp_cost := tti_cmp_sel_cost(vc.tti, cmp_opc, vtype(i0), vc_cmp_result_type(vtype(i0)), pred, vc.kind);
    old := cost_add(cost_add(cost_add(ext0_cost, ext1_cost), cost_mul(cmp_cost, 2)), tti_arith_cost(vc.tti, inst_op(i), vtype(i), vc.kind));
    cheap := ifx conv == ext0 then index1 else index0;
    expensive := ifx conv == ext0 then index0 else index1;
    cmp_ty := vc_cmp_result_type(vec_ty);
    new := tti_cmp_sel_cost(vc.tti, cmp_opc, vec_ty, cmp_ty, pred, vc.kind);
    m := vc_poison_mask(cast(s64) n);
    m[cheap] = cast(s32) expensive;
    new = cost_add(new, tti_shuffle_cost(vc.tti, SK_PERMUTE_SINGLE_SRC, cmp_ty, cmp_ty, m, vc.kind, 0, NONE, .[], NONE));
    new = cost_add(new, tti_arith_cost(vc.tti, inst_op(i), cmp_ty, vc.kind));
    new = cost_add(new, tti_vector_inst_cost(vc.tti, ext0, cmp_ty, vc.kind, cast(u32) cheap));
    if !value_has_one_use(ext0) new = cost_add(new, ext0_cost);
    if !value_has_one_use(ext1) new = cost_add(new, ext1_cost);
    if old < new || !cost_valid(new) return false;
    elts := NewArray(cast(s64) n, Value_Id,, temp);
    for * elts it.* = const_poison(type_elem(vec_ty));
    elts[index0] = c0;
    elts[index1] = c1;
    vcmp := vcb_cmp(pred, x, const_vector_of(elts));
    shuf := vc_create_shift_shuffle(vcmp, expensive, cheap);
    lhs := ifx conv == ext0 then shuf else vcmp;
    rhs := ifx conv == ext0 then vcmp else shuf;
    vlogic := vcb_binop(inst_op(i), lhs, rhs);
    new_ext := vcb_extract_element(vlogic, vc_i64(cheap));
    vc_replace_value(i, new_ext);
    return true;
}

// foldSelectsFromBitcast
vc_fold_selects_from_bitcast :: (bc: Value_Id) -> bool {
    src_ty := vtype(op(bc, 0)); dst_ty := vtype(bc);
    if !vc_is_fixed_vec(src_ty) || !vc_is_fixed_vec(dst_ty) return false;
    src_elt := type_elem(src_ty); dst_elt := type_elem(dst_ty);
    sb := vc_prim_bits(src_elt); db := vc_prim_bits(dst_elt);
    if sb != 32 && sb != 64 return false;
    if !is_int_type(dst_elt) || db >= sb return false;
    cond_ty := vc_cmp_result_type(dst_elt);
    vec_cond_ty := vc_cmp_result_type(src_ty);
    ssel := tti_cmp_sel_cost(vc.tti, .SELECT, dst_elt, cond_ty, BAD_ICMP_PREDICATE, vc.kind);
    vsel := tti_cmp_sel_cost(vc.tti, .SELECT, src_ty, vec_cond_ty, BAD_ICMP_PREDICATE, vc.kind);
    if !cost_valid(ssel) || ssel == 0 return false;
    min_selects := vsel / ssel + 1;
    if !has_n_uses_or_more(bc, min_selects) return false;
    // DenseMap<Value *, SmallVector<SelectInst *>>: iterated in hash order in LLVM
    conds: [..] Value_Id; conds.allocator = temp;
    groups: [..] [..] Value_Id; groups.allocator = temp;
    u := ir.v_first_use[bc];
    while u != NONE {
        ext := ir.u_user[u];
        u = ir.u_next[u];
        if !vc_is_op(ext, .EXTRACTELEMENT) continue;
        w := ir.v_first_use[ext];
        while w != NONE {
            eu := ir.u_user[w];
            w = ir.u_next[w];
            if !vc_is_op(eu, .SELECT) || op(eu, 1) != ext || !pm_zero(op(eu, 2)) continue;
            c := op(eu, 0);
            if vtype(c) != ir.t_i1 continue;
            gi := -1;
            for conds if it == c { gi = it_index; break; }
            if gi < 0 {
                array_add(*conds, c);
                g: [..] Value_Id; g.allocator = temp;
                array_add(*groups, g);
                gi = conds.count - 1;
            }
            array_add(*groups[gi], eu);
        }
    }
    if conds.count == 0 return false;
    nprofitable := 0;
    for groups if it.count >= min_selects nprofitable += 1;
    if nprofitable > 1 fatal("vector-combine: foldSelectsFromBitcast with several conditions (DenseMap order) is not supported yet");
    made := false;
    src_vec := op(bc, 0);
    for c: conds {
        sels := groups[it_index];
        if sels.count < min_selects continue;
        pt := inst(bc).next;
        if is_inst(c) && dt_dominates_inst(vc.dt, bc, c) pt = inst(c).next;
        irb_set_at(*vc.b, inst_block(pt), pt, false);
        vsel_v := vcb_select(c, src_vec, const_null_value(src_ty));
        nbc := vcb_cast(.BITCAST, vsel_v, dst_ty);
        for s: sels {
            ext := op(s, 1);
            idx := op(ext, 1);
            irb_set_before(*vc.b, s);
            ne := vcb_extract_element(nbc, idx);
            vc_replace_value(s, ne);
            made = true;
        }
    }
    return made;
}

// ---------------------------------------------------------------- reductions of binops

// analyzeCostOfVecReduction: (CostBeforeReduction, CostAfterReduction)
vc_analyze_cost_of_vec_reduction :: (ii: Value_Id, before: *Cost, after: *Cost) {
    red_op := op(ii, 0);
    vec_red_ty := vtype(red_op);
    id := call_iid(ii);
    red_opc := arithmetic_reduction_instruction(id);
    if vc_is_op(red_op, .ZEXT) || vc_is_op(red_op, .SEXT) {
        is_unsigned := inst_op(red_op) == .ZEXT;
        ext_ty := vtype(op(red_op, 0));
        before.* = tti_cast_cost(vc.tti, inst_op(red_op), vec_red_ty, ext_ty, CCH_NONE, vc.kind, red_op);
        after.* = tti_extended_reduction_cost(vc.tti, red_opc, is_unsigned, vtype(ii), ext_ty, true, 0, vc.kind);
        return;
    }
    // reduce.add(ext(mul(ext(A), ext(B)))): the first case already took every zext/sext RedOp, so this one
    // never matches (as in LLVM)
    after.* = tti_arithmetic_reduction_cost(vc.tti, red_opc, vec_red_ty, false, 0, vc.kind);
}

// foldBinopOfReductions
vc_fold_binop_of_reductions :: (i: Value_Id) -> bool {
    bopc := inst_op(i);
    rid := reduction_for_binop(bopc);
    if bopc == .SUB rid = IID_VECTOR_REDUCE_ADD;
    if rid == NOT_INTRINSIC return false;
    if rid == IID_VECTOR_REDUCE_FADD || rid == IID_VECTOR_REDUCE_FMUL return false;
    arg_of :: (v: Value_Id, id: Intrinsic_Id) -> Value_Id {
        if vc_iid(v) == id && value_has_one_use(v) return call_arg(v, 0);
        return NONE;
    }
    v0 := arg_of(op(i, 0), rid);
    if v0 == NONE return false;
    v1 := arg_of(op(i, 1), rid);
    if v1 == NONE return false;
    vty := vtype(v0);
    if vtype(v1) != vty return false;
    ii0 := op(i, 0); ii1 := op(i, 1);
    red_opc := arithmetic_reduction_instruction(call_iid(ii0));
    op0c: Cost = 0; r0c: Cost = 0; op1c: Cost = 0; r1c: Cost = 0;
    vc_analyze_cost_of_vec_reduction(ii0, *op0c, *r0c);
    vc_analyze_cost_of_vec_reduction(ii1, *op1c, *r1c);
    old := cost_add(cost_add(r0c, r1c), tti_instruction_cost(vc.tti, i, vc.kind));
    new := cost_add(cost_add(cost_add(op0c, op1c), tti_arith_cost(vc.tti, bopc, vty, vc.kind)),
                    tti_arithmetic_reduction_cost(vc.tti, red_opc, vty, false, 0, vc.kind));
    if new >= old || !cost_valid(new) return false;
    vbo: Value_Id;
    if bopc == .OR vbo = vcb_or_disjoint(v0, v1, (inst(i).flags & F_EXACT) != 0);
    else vbo = vcb_binop(bopc, v0, v1);
    rdx := vcb_intrinsic_tys(rid, .[vty], .[vbo]);
    vc_replace_value(i, rdx);
    return true;
}

// ---------------------------------------------------------------- scalarizing memory accesses

// isMemModifiedBetween(Begin, End, Loc, AA)
vc_is_mem_modified_between :: (begin: Value_Id, end: Value_Id, loc: Mem_Loc) -> bool {
    scanned := 0;
    x := begin;
    while x != end && x != NONE {
        q := aa_query_new(*vc.aar);
        if mr_is_mod_set(aa_mod_ref_inst_loc(q, x, loc)) return true;
        scanned += 1;
        if scanned > vc_cl.max_instrs_to_scan return true;
        x = inst(x).next;
    }
    return false;
}

VC_UNSAFE :: 0; VC_SAFE :: 1; VC_SAFE_WITH_FREEZE :: 2;
Vc_Scalarization :: struct { status: u8; to_freeze: Value_Id = NONE; }

// canScalarizeAccess
vc_can_scalarize_access :: (vec_ty: Type_Id, idx: Value_Id, q: Simplify_Query) -> Vc_Scalarization {
    n := type_count(vec_ty);
    w := type_int_width(scalar_type(vtype(idx)));
    if vkind(idx) == .C_INT {
        if ap_ult_u64(cf_ap(idx), n) return .{VC_SAFE, NONE};
        return .{VC_UNSAFE, NONE};
    }
    if w < 64 && n >= ((cast(u64) 1) << w) return .{VC_UNSAFE, NONE};
    valid := cr_new(ap_zero(w), ap_from_u64(w, n));
    if is_guaranteed_not_to_be_poison(idx, q.ac, q.cxt, q.dt) {
        if cr_contains_range(valid, compute_constant_range(idx, false, q)) return .{VC_SAFE, NONE};
        return .{VC_UNSAFE, NONE};
    }
    rng := cr_full(w);
    base: Value_Id = NONE;
    if vc_is_op(idx, .AND) && vkind(op(idx, 1)) == .C_INT {
        base = op(idx, 0);
        rng = cr_binary_and(rng, cr_single(cf_ap(op(idx, 1))));
    } else if vc_is_op(idx, .UREM) && vkind(op(idx, 1)) == .C_INT {
        base = op(idx, 0);
        rng = cr_urem(rng, cr_single(cf_ap(op(idx, 1))));
    }
    if cr_contains_range(valid, rng) return .{VC_SAFE_WITH_FREEZE, base};
    return .{VC_UNSAFE, NONE};
}
// ScalarizationResult::freeze(Builder, UserI)
vc_freeze_index :: (s: Vc_Scalarization, user: Value_Id) {
    saved := vc.b;
    irb_set_before(*vc.b, user);
    frozen := vcb_freeze(s.to_freeze, tprint("%.frozen", vname(s.to_freeze)));
    for k: 0..cast(s64) nops(user) - 1 if op(user, cast(u32) k) == s.to_freeze set_op(user, cast(u32) k, frozen);
    vc.b = saved;
}
// computeAlignmentAfterScalarization
vc_alignment_after_scalarization :: (vec_align: u64, sty: Type_Id, idx: Value_Id) -> u64 {
    if vkind(idx) == .C_INT return common_alignment(vec_align, ap_zext_value(cf_ap(idx)) * dl_type_store_size(sty));
    return common_alignment(vec_align, dl_type_store_size(sty));
}

// foldSingleElementStore
vc_fold_single_element_store :: (i: Value_Id) -> bool {
    if !tti_allow_vector_element_indexing_using_gep(vc.tti) return false;
    val := op(i, 0);
    if !is_simple_load_store(i) || !is_vector_type(vtype(val)) return false;
    if !vc_is_op(val, .INSERTELEMENT) return false;
    source := op(val, 0); new_elt := op(val, 1); idx := op(val, 2);
    if !is_inst(source) return false;
    if !vc_is_op(source, .LOAD) return false;
    load := source;
    vec_ty := vtype(val);
    src_addr := strip_pointer_casts(op(load, 0));
    if !is_simple_load_store(load) || inst_block(load) != inst_block(i) || !dl_size_eq_store_size(scalar_type(vtype(load))) ||
       src_addr != strip_pointer_casts(op(i, 1))
        return false;
    if vc_is_mem_modified_between(load, i, mloc_get(i)) return false;
    sc := vc_can_scalarize_access(vec_ty, idx, sq_with_instruction(vc.sq, load));
    if sc.status == VC_UNSAFE return false;
    vc_push(load);
    if sc.status == VC_SAFE_WITH_FREEZE vc_freeze_index(sc, idx);
    gep := vcb_inbounds_gep(vtype(val), op(i, 1), .[const_int(vtype(idx), 0), idx]);
    st := irb_store(*vc.b, new_elt, gep, dl_alignment(vtype(new_elt), true));
    copy_metadata(st, i);
    inst(st).align = vc_alignment_after_scalarization(max(inst(i).align, inst(load).align), vtype(new_elt), idx);
    vc_replace_value(i, st);
    vc_erase_instruction(i);
    return true;
}

// scalarizeLoad
vc_scalarize_load :: (i: Value_Id) -> bool {
    if inst_op(i) != .LOAD return false;
    ptr := op(i, 0);
    vec_ty := vtype(i);
    if !is_simple_load_store(i) || !dl_size_eq_store_size(scalar_type(vec_ty)) return false;
    all_extracts := true; all_bitcasts := true;
    last_checked := i;
    num_checked := 0;
    u := ir.v_first_use[i];
    while u != NONE {
        ui := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(ui) || inst_block(ui) != inst_block(i) return false;
        if !has_uses(ui) return false;
        if inst_op(ui) != .EXTRACTELEMENT all_extracts = false;
        if inst_op(ui) != .BITCAST all_bitcasts = false;
        if comes_before(last_checked, ui) {
            x := inst(i).next;
            while x != ui {
                if num_checked == vc_cl.max_instrs_to_scan || may_write_to_memory(x) return false;
                num_checked += 1;
                x = inst(x).next;
            }
            last_checked = ui;
        }
    }
    if all_extracts return vc_scalarize_load_extract(i, vec_ty, ptr);
    if all_bitcasts return vc_scalarize_load_bitcast(i, vec_ty, ptr);
    return false;
}

// scalarizeLoadExtract
vc_scalarize_load_extract :: (li: Value_Id, vec_ty: Type_Id, ptr: Value_Id) -> bool {
    if !tti_allow_vector_element_indexing_using_gep(vc.tti) return false;
    need_freeze_ext: [..] Value_Id; need_freeze_ext.allocator = temp;
    need_freeze: [..] Vc_Scalarization; need_freeze.allocator = temp;
    as := vc_as(op(li, 0));
    orig := tti_memory_op_cost(vc.tti, .LOAD, vec_ty, inst(li).align, as, vc.kind);
    scal: Cost = 0;
    u := ir.v_first_use[li];
    while u != NONE {
        ui := ir.u_user[u];
        u = ir.u_next[u];
        sidx := vc_can_scalarize_access(vec_ty, op(ui, 1), sq_with_instruction(vc.sq, li));
        if sidx.status == VC_UNSAFE return false;
        if sidx.status == VC_SAFE_WITH_FREEZE {
            dup := false; for need_freeze_ext if it == ui dup = true;
            if !dup { array_add(*need_freeze_ext, ui); array_add(*need_freeze, sidx); }
        }
        x := op(ui, 1);
        index: u32 = U32_NONE;
        if vkind(x) == .C_INT index = cast,no_check(u32) ap_zext_value(cf_ap(x));
        orig = cost_add(orig, tti_vector_instr_cost(vc.tti, .EXTRACTELEMENT, vec_ty, vc.kind, index));
        scal = cost_add(scal, tti_memory_op_cost(vc.tti, .LOAD, type_elem(vec_ty), 1, as, vc.kind));
        scal = cost_add(scal, tti_address_computation_cost_no_se(vc.tti, vtype(op(li, 0)), vc.kind));
    }
    if scal >= orig return false;
    vc_push(li);
    elem_ty := type_elem(vec_ty);
    // the users are rewritten in use-list order; replaceValue(*EI, *NewLoad, false) moves no use of the load
    users: [..] Value_Id; users.allocator = temp;
    u = ir.v_first_use[li];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for ei: users {
        idx := op(ei, 1);
        for need_freeze_ext if it == ei { vc_freeze_index(need_freeze[it_index], idx); break; }
        irb_set_before(*vc.b, ei);
        gep := vcb_inbounds_gep(vec_ty, ptr, .[vc_i32(0), idx]);
        nl := irb_load(*vc.b, elem_ty, gep, dl_alignment(elem_ty, true), false, tprint("%.scalar", vname(ei)));
        inst(nl).align = vc_alignment_after_scalarization(inst(li).align, elem_ty, idx);
        if vkind(idx) == .C_INT {
            off := ap_zext_value(cf_ap(idx)) * dl_type_store_size(elem_ty);
            set_aa_metadata(nl, aa_adjust_for_access_ty(get_aa_metadata(li), off, elem_ty));
        }
        vc_replace_value(ei, nl, false);
    }
    return true;
}

// scalarizeLoadBitcast
vc_scalarize_load_bitcast :: (li: Value_Id, vec_ty: Type_Id, ptr: Value_Id) -> bool {
    as := vc_as(op(li, 0));
    orig := tti_memory_op_cost(vc.tti, .LOAD, vec_ty, inst(li).align, as, vc.kind);
    target: Type_Id = NONE;
    vbits := dl_type_size_bits(vec_ty);
    u := ir.v_first_use[li];
    while u != NONE {
        bc := ir.u_user[u];
        u = ir.u_next[u];
        dest := vtype(bc);
        if !is_int_type(dest) && !is_fp_type(dest) return false;
        if dl_type_size_bits(dest) != vbits return false;
        if target == NONE target = dest;
        else if target != dest return false;
        orig = cost_add(orig, tti_cast_cost(vc.tti, .BITCAST, target, vec_ty, tti_cast_context_hint(bc), vc.kind, bc));
    }
    if target == NONE return false;
    scal := tti_memory_op_cost(vc.tti, .LOAD, target, inst(li).align, as, vc.kind);
    if scal >= orig return false;
    vc_push(li);
    irb_set_before(*vc.b, li);
    sl := irb_load(*vc.b, target, ptr, dl_alignment(target, true), false, tprint("%.scalar", vname(li)));
    inst(sl).align = inst(li).align;
    copy_metadata(sl, li);
    users: [..] Value_Id; users.allocator = temp;
    u = ir.v_first_use[li];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for bc: users vc_replace_value(bc, sl, false);
    return true;
}

// scalarizeExtExtract
vc_scalarize_ext_extract :: (i: Value_Id) -> bool {
    if !tti_allow_vector_element_indexing_using_gep(vc.tti) return false;
    if inst_op(i) != .ZEXT return false;
    ext := i;
    src_ty := vtype(op(ext, 0));
    if !vc_is_fixed_vec(src_ty) return false;
    dst_ty := vtype(ext);
    sdst := type_elem(dst_ty);
    if dl_type_size_bits(src_ty) != dl_type_size_bits(sdst) return false;
    vector_cost := tti_cast_cost(vc.tti, .ZEXT, dst_ty, src_ty, CCH_NONE, vc.kind, ext);
    ext_cnt: Cost = 0;
    ext_lane0 := false;
    u := ir.v_first_use[ext];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        ok, _, idx := vc_match_extract_const(usr);
        if !ok return false;
        if !has_uses(usr) continue;
        ext_cnt += 1;
        ext_lane0 |= idx == 0;
        vector_cost = cost_add(vector_cost, tti_vector_instr_cost(vc.tti, .EXTRACTELEMENT, dst_ty, vc.kind, cast(u32) idx, usr));
    }
    and_c := tti_arith_cost(vc.tti, .AND, sdst, vc.kind, OI_ANY, .{OK_NON_UNIFORM_CONSTANT_VALUE, OP_NONE});
    shr_c := tti_arith_cost(vc.tti, .LSHR, sdst, vc.kind, OI_ANY, .{OK_NON_UNIFORM_CONSTANT_VALUE, OP_NONE});
    scalar_cost := cost_add(cost_mul(ext_cnt, and_c), cost_mul(ext_cnt - ifx ext_lane0 then cast(Cost) 1 else 0, shr_c));
    if scalar_cost > vector_cost return false;
    scalar_v := op(ext, 0);
    if !is_guaranteed_not_to_be_poison(scalar_v, vc.sq.ac, ifx is_inst(scalar_v) then scalar_v else NONE, vc.sq.dt) {
        lanes: [..] Value_Id; lanes.allocator = temp;
        all_ub := true;
        last: Value_Id = NONE;
        bb := inst_block(ext);
        w := ir.v_first_use[ext];
        while w != NONE {
            e := ir.u_user[w];
            w = ir.u_next[w];
            if inst_block(e) != bb || !program_undefined_if_poison(e) { all_ub = false; break; }
            c := op(e, 1);
            dup := false; for lanes if it == c dup = true;
            if !dup array_add(*lanes, c);
            if last == NONE || comes_before(last, e) last = e;
        }
        if cast(u64) lanes.count != type_count(dst_ty) || !all_ub ||
           !is_guaranteed_to_transfer_execution_range(ext, last, 32)
            scalar_v = vcb_freeze(scalar_v);
    }
    total := dl_type_size_bits(src_ty);
    scalar_v = vcb_cast(.BITCAST, scalar_v, type_int(cast(u32) total));
    elt_bits := dl_type_size_bits(type_elem(src_ty));
    packed_ty := type_int(cast(u32) total);
    mask := const_int_ap(packed_ty, ap_low_bits_set(cast(u32) total, cast(u32) elt_bits));
    users: [..] Value_Id; users.allocator = temp;
    w := ir.v_first_use[ext];
    while w != NONE { array_add(*users, ir.u_user[w]); w = ir.u_next[w]; }
    for e: users {
        _, idx := pm_constant_int_u64(op(e, 1));
        sh := ifx dl.big_endian then (total - elt_bits - idx * elt_bits) else idx * elt_bits;
        lshr := vcb_binop(.LSHR, scalar_v, const_int(packed_ty, sh));
        and := vcb_binop(.AND, lshr, mask);
        rauw_with_metadata(e, and);
    }
    return true;
}

// foldConcatOfBoolMasks
vc_fold_concat_of_bool_masks :: (i: Value_Id) -> bool {
    ty := vtype(i);
    if !is_int_type(ty) return false;
    if dl.big_endian return false;
    if inst_op(i) != .OR || (inst(i).flags & F_EXACT) == 0 return false;
    x := op(i, 0); y := op(i, 1);
    if !is_inst(x) || !is_inst(y) return false;
    // m_OneUse(m_ZExt(m_OneUse(m_BitCast(m_Value(Src))))) or the same under m_OneUse(m_Shl(.., m_ConstantInt(ShAmt)))
    match_src :: (v: Value_Id) -> (bool, Value_Id, u64) {
        zext_bc :: (z: Value_Id) -> (bool, Value_Id) {
            if !value_has_one_use(z) || !vc_is_op(z, .ZEXT) return false, NONE;
            b := op(z, 0);
            if !value_has_one_use(b) || opr_code(b) != .BITCAST return false, NONE;
            return true, op(b, 0);
        }
        ok, s := zext_bc(v);
        if ok return true, s, 0;
        if !value_has_one_use(v) || opr_code(v) != .SHL return false, NONE, 0;
        ok2, s2 := zext_bc(op(v, 0));
        if !ok2 return false, NONE, 0;
        okc, c := pm_constant_int_u64(op(v, 1));
        if !okc return false, NONE, 0;
        return true, s2, c;
    }
    okx, src_x, sh_x := match_src(x);
    if !okx return false;
    oky, src_y, sh_y := match_src(y);
    if !oky return false;
    if sh_x > sh_y {
        t := x; x = y; y = t;
        ts := src_x; src_x = src_y; src_y = ts;
        tt := sh_x; sh_x = sh_y; sh_y = tt;
    }
    diff := sh_y - sh_x;
    num_shl: Cost = (ifx sh_x > 0 then cast(Cost) 1 else 0) + (ifx sh_y > 0 then cast(Cost) 1 else 0);
    bw := vc_prim_bits(ty);
    mask_ty := vtype(src_x);
    if !vc_is_fixed_vec(mask_ty) || vtype(src_x) != vtype(src_y) || type_elem(mask_ty) != ir.t_i1 ||
       type_count(mask_ty) != diff || type_count(mask_ty) > bw / 2
        return false;
    concat_ty := type_vector(type_count(mask_ty) * 2, ir.t_i1, false);
    concat_int_ty := type_int(cast(u32) type_count(concat_ty));
    mask_int_ty := type_int(cast(u32) diff);
    cmask := vc_iota(cast(s64) type_count(concat_ty));
    old: Cost = 0;
    old = cost_add(old, tti_arith_cost(vc.tti, .OR, ty, vc.kind));
    old = cost_add(old, cost_mul(num_shl, tti_arith_cost(vc.tti, .SHL, ty, vc.kind)));
    old = cost_add(old, cost_mul(2, tti_cast_cost(vc.tti, .ZEXT, ty, mask_int_ty, CCH_NONE, vc.kind)));
    old = cost_add(old, cost_mul(2, tti_cast_cost(vc.tti, .BITCAST, mask_int_ty, mask_ty, CCH_NONE, vc.kind)));
    new: Cost = 0;
    new = cost_add(new, tti_shuffle_cost(vc.tti, SK_PERMUTE_TWO_SRC, concat_ty, mask_ty, cmask, vc.kind, 0, NONE, .[], NONE));
    new = cost_add(new, tti_cast_cost(vc.tti, .BITCAST, concat_int_ty, concat_ty, CCH_NONE, vc.kind));
    if ty != concat_int_ty new = cost_add(new, tti_cast_cost(vc.tti, .ZEXT, ty, concat_int_ty, CCH_NONE, vc.kind));
    if sh_x > 0 new = cost_add(new, tti_arith_cost(vc.tti, .SHL, ty, vc.kind));
    if new > old return false;
    concat := vcb_shuffle(src_x, src_y, cmask);
    vc_push_value(concat);
    result := vcb_cast(.BITCAST, concat, concat_int_ty);
    if ty != concat_int_ty {
        vc_push_value(result);
        result = vcb_cast(.ZEXT, result, ty);
    }
    if sh_x > 0 {
        vc_push_value(result);
        result = vcb_binop(.SHL, result, const_int(ty, sh_x));
    }
    vc_replace_value(i, result);
    return true;
}

// ---------------------------------------------------------------- shuffles

// m_Shuffle(m_Value(A), m_Value(B), m_Mask(M))
vc_match_shuffle :: (v: Value_Id) -> (bool, Value_Id, Value_Id, [..] s32) {
    if !vc_is_op(v, .SHUFFLEVECTOR) { e: [..] s32; return false, NONE, NONE, e; }
    return true, op(v, 0), op(v, 1), shuf_mask(v);
}
vc_all_lt :: (m: [] s32, n: s64) -> bool { for m if it >= n return false; return true; }
vc_any_ge :: (m: [] s32, n: s64) -> bool { for m if it >= n return true; return false; }

// foldPermuteOfBinops
vc_fold_permute_of_binops :: (i: Value_Id) -> bool {
    bin := op(i, 0);
    if !vc_is_binop(bin) || !pm_undef(op(i, 1)) return false;
    outer := shuf_mask(i);
    opc := inst_op(bin);
    if is_int_div_rem(opc) && vc_contains_s32(outer, -1) return false;
    m0, op00, op01, mask0 := vc_match_shuffle(op(bin, 0));
    m1, op10, op11, mask1 := vc_match_shuffle(op(bin, 1));
    if !m0 && !m1 return false;
    if !m0 { op00 = op(bin, 0); op01 = op(bin, 0); }
    if !m1 { op10 = op(bin, 1); op11 = op(bin, 1); }
    dst_ty := vtype(i); bin_ty := vtype(bin); op0_ty := vtype(op00); op1_ty := vtype(op10);
    if !vc_is_fixed_vec(dst_ty) || !vc_is_fixed_vec(bin_ty) || !vc_is_fixed_vec(op0_ty) || !vc_is_fixed_vec(op1_ty) return false;
    nsrc := cast(s64) type_count(bin_ty);
    if (is_int_div_rem(opc) || !pm_poison(op(i, 1))) && vc_any_ge(outer, nsrc) return false;
    nm0: [..] s32; nm0.allocator = temp;
    nm1: [..] s32; nm1.allocator = temp;
    for m: outer {
        if m < 0 || m >= nsrc { array_add(*nm0, -1); array_add(*nm1, -1); }
        else {
            array_add(*nm0, ifx m0 then mask0[m] else m);
            array_add(*nm1, ifx m1 then mask1[m] else m);
        }
    }
    nop := cast(s64) type_count(op0_ty);
    id0 := dst_ty == op0_ty && vc_all_lt(nm0, nop) && svm_is_identity(nm0, nop);
    id1 := dst_ty == op1_ty && vc_all_lt(nm1, nop) && svm_is_identity(nm1, nop);
    new: Cost = 0;
    bin_cost := tti_arith_cost(vc.tti, opc, bin_ty, vc.kind);
    old := cost_add(bin_cost, tti_shuffle_cost(vc.tti, SK_PERMUTE_SINGLE_SRC, dst_ty, bin_ty, outer, vc.kind, 0, NONE, .[bin], i));
    if !value_has_one_use(bin) new = cost_add(new, bin_cost);
    if m0 {
        c := tti_shuffle_cost(vc.tti, SK_PERMUTE_TWO_SRC, bin_ty, op0_ty, mask0, vc.kind, 0, NONE, .[op00, op01], op(bin, 0));
        old = cost_add(old, c);
        if !value_has_one_use(bin) || !value_has_one_use(op(bin, 0)) new = cost_add(new, c);
    }
    if m1 {
        c := tti_shuffle_cost(vc.tti, SK_PERMUTE_TWO_SRC, bin_ty, op1_ty, mask1, vc.kind, 0, NONE, .[op10, op11], op(bin, 1));
        old = cost_add(old, c);
        if !value_has_one_use(bin) || !value_has_one_use(op(bin, 1)) new = cost_add(new, c);
    }
    new = cost_add(new, tti_arith_cost(vc.tti, opc, dst_ty, vc.kind));
    if !id0 new = cost_add(new, tti_shuffle_cost(vc.tti, SK_PERMUTE_TWO_SRC, dst_ty, op0_ty, nm0, vc.kind, 0, NONE, .[op00, op01], NONE));
    if !id1 new = cost_add(new, tti_shuffle_cost(vc.tti, SK_PERMUTE_TWO_SRC, dst_ty, op1_ty, nm1, vc.kind, 0, NONE, .[op10, op11], NONE));
    if new > old return false;
    lhs := ifx id0 then op00 else vcb_shuffle(op00, op01, nm0);
    rhs := ifx id1 then op10 else vcb_shuffle(op10, op11, nm1);
    nbo := vcb_binop(opc, lhs, rhs);
    if is_inst(nbo) copy_ir_flags(nbo, bin);
    vc_push_value(lhs);
    vc_push_value(rhs);
    vc_replace_value(i, nbo);
    return true;
}

// CmpInst::isCommutative
vc_cmp_is_commutative :: (c: Value_Id) -> bool {
    p := inst(c).pred;
    if inst_op(c) == .ICMP return icmp_is_equality(p);
    return fcmp_is_commutative(p);
}

// foldShuffleOfBinops
vc_fold_shuffle_of_binops :: (i: Value_Id) -> bool {
    lhs := op(i, 0); rhs := op(i, 1);
    if !is_inst(lhs) || !is_inst(rhs) return false;
    old_mask := shuf_mask(i);
    if inst_op(lhs) != inst_op(rhs) return false;
    x, y, z, w: Value_Id;
    is_comm := false;
    pred_lhs: u8 = BAD_ICMP_PREDICATE;
    if vc_is_binop(lhs) && vc_is_binop(rhs) {
        x = op(lhs, 0); y = op(lhs, 1); z = op(rhs, 0); w = op(rhs, 1);
        if vc_contains_s32(old_mask, -1) && is_int_div_rem(inst_op(lhs)) return false;
        is_comm = is_commutative_op(inst_op(lhs));
    } else if vc_is_cmp(lhs) && vc_is_cmp(rhs) && inst(lhs).pred == inst(rhs).pred {
        x = op(lhs, 0); y = op(lhs, 1); z = op(rhs, 0); w = op(rhs, 1);
        pred_lhs = inst(lhs).pred;
        is_comm = vc_cmp_is_commutative(lhs);
    } else return false;
    dst_ty := vtype(i); res_ty := vtype(lhs); bin_ty := vtype(x);
    if !vc_is_fixed_vec(dst_ty) || !vc_is_fixed_vec(res_ty) || !vc_is_fixed_vec(bin_ty) || vtype(x) != vtype(z) return false;
    same := lhs == rhs;
    nsrc := cast(s64) type_count(bin_ty);
    if is_comm && x != z && y != w && (x == w || y == z) { t := x; x = y; y = t; }
    nm0: [..] s32; nm0.allocator = temp; for old_mask array_add(*nm0, it);
    sk0 := SK_PERMUTE_TWO_SRC;
    oi0 := tti_common_operand_info(x, z);
    if x == z {
        for * nm0 if it.* >= nsrc it.* -= cast(s32) nsrc;
        sk0 = SK_PERMUTE_SINGLE_SRC;
        z = const_poison(bin_ty);
    }
    nm1: [..] s32; nm1.allocator = temp; for old_mask array_add(*nm1, it);
    sk1 := SK_PERMUTE_TWO_SRC;
    oi1 := tti_common_operand_info(y, w);
    if y == w {
        for * nm1 if it.* >= nsrc it.* -= cast(s32) nsrc;
        sk1 = SK_PERMUTE_SINGLE_SRC;
        w = const_poison(bin_ty);
    }
    lcost := tti_instruction_cost(vc.tti, lhs, vc.kind);
    rcost := tti_instruction_cost(vc.tti, rhs, vc.kind);
    old := lcost;
    if !same old = cost_add(old, rcost);
    old = cost_add(old, tti_shuffle_cost(vc.tti, SK_PERMUTE_TWO_SRC, dst_ty, res_ty, old_mask, vc.kind, 0, NONE, .[lhs, rhs], i));
    merge_inner :: (o: *Value_Id, offset: s64, mask: *[..] s32, nsrc: s64, old: *Cost) -> bool {
        v := o.*;
        if !value_has_one_use(v) || !vc_is_op(v, .SHUFFLEVECTOR) || !pm_undef(op(v, 1)) return false;
        inner_op := op(v, 0);
        inner := shuf_mask(v);
        if vtype(inner_op) != vtype(v) || !vc_all_lt(inner, nsrc) return false;
        for * mask.* {
            m := it.*;
            if offset <= m && m < offset + nsrc {
                m = inner[m - offset];
                if 0 <= m m = cast(s32) (m + offset);
                it.* = m;
            }
        }
        old.* = cost_add(old.*, tti_instruction_cost(vc.tti, v, vc.kind));
        o.* = inner_op;
        return true;
    }
    reduced := false;
    reduced |= merge_inner(*x, 0, *nm0, nsrc, *old);
    reduced |= merge_inner(*y, 0, *nm1, nsrc, *old);
    reduced |= merge_inner(*z, nsrc, *nm0, nsrc, *old);
    reduced |= merge_inner(*w, nsrc, *nm1, nsrc, *old);
    single := x == y && z == w && vc_masks_equal(nm0, nm1);
    reduced |= single && has_one_user(lhs) && has_one_user(rhs);
    reduced |= sv_is_concat(i) && scalar_type(dst_ty) == ir.t_i1 && vc_is_binop(lhs) && has_one_user(lhs) && has_one_user(rhs);
    cmp_ty := type_vector(type_count(dst_ty), type_elem(bin_ty), false);
    new := tti_shuffle_cost(vc.tti, sk0, cmp_ty, bin_ty, nm0, vc.kind, 0, NONE, .[x, z], NONE);
    if !single new = cost_add(new, tti_shuffle_cost(vc.tti, sk1, cmp_ty, bin_ty, nm1, vc.kind, 0, NONE, .[y, w], NONE));
    if pred_lhs == BAD_ICMP_PREDICATE new = cost_add(new, tti_arith_cost(vc.tti, inst_op(lhs), dst_ty, vc.kind, oi0, oi1));
    else new = cost_add(new, tti_cmp_sel_cost(vc.tti, inst_op(lhs), cmp_ty, dst_ty, pred_lhs, vc.kind, oi0, oi1));
    if !has_one_user(lhs) new = cost_add(new, lcost);
    if !same && !has_one_user(rhs) new = cost_add(new, rcost);
    reduced |= (is_const(x) && is_const(z)) || (is_const(y) && is_const(w));
    if ifx reduced then new > old else new >= old return false;
    s0 := vcb_shuffle(x, z, nm0);
    s1 := ifx single then s0 else vcb_shuffle(y, w, nm1);
    nbo := ifx pred_lhs == BAD_ICMP_PREDICATE then vcb_binop(inst_op(lhs), s0, s1) else vcb_cmp(pred_lhs, s0, s1);
    if is_inst(nbo) { copy_ir_flags(nbo, lhs); and_ir_flags(nbo, rhs); }
    vc_push_value(s0);
    vc_push_value(s1);
    vc_replace_value(i, nbo);
    return true;
}

// foldShuffleOfSelects
vc_fold_shuffle_of_selects :: (i: Value_Id) -> bool {
    sel1 := op(i, 0); sel2 := op(i, 1);
    if !vc_is_op(sel1, .SELECT) || !vc_is_op(sel2, .SELECT) return false;
    mask := shuf_mask(i);
    c1 := op(sel1, 0); t1 := op(sel1, 1); f1 := op(sel1, 2);
    c2 := op(sel2, 0); t2 := op(sel2, 1); f2 := op(sel2, 2);
    c1_ty := vtype(c1); c2_ty := vtype(c2);
    if !vc_is_fixed_vec(c1_ty) || !vc_is_fixed_vec(c2_ty) || c1_ty != c2_ty return false;
    fp1 := is_fp_math_inst(sel1); fp2 := is_fp_math_inst(sel2);
    if fp1 != fp2 || (fp1 && get_fmf(sel1) != get_fmf(sel2)) return false;
    src_ty := vtype(t1); dst_ty := vtype(i);
    sk := SK_PERMUTE_TWO_SRC;
    cs1 := tti_cmp_sel_cost(vc.tti, .SELECT, src_ty, c1_ty, BAD_ICMP_PREDICATE, vc.kind);
    cs2 := tti_cmp_sel_cost(vc.tti, .SELECT, src_ty, c2_ty, BAD_ICMP_PREDICATE, vc.kind);
    old := cost_add(cost_add(cs1, cs2), tti_shuffle_cost(vc.tti, sk, dst_ty, src_ty, mask, vc.kind, 0, NONE, .[sel1, sel2], i));
    new := tti_shuffle_cost(vc.tti, sk, type_vector(cast(u64) mask.count, type_elem(c1_ty), false), c1_ty, mask, vc.kind, 0, NONE, .[c1, c2], NONE);
    new = cost_add(new, tti_shuffle_cost(vc.tti, sk, dst_ty, src_ty, mask, vc.kind, 0, NONE, .[t1, t2], NONE));
    new = cost_add(new, tti_shuffle_cost(vc.tti, sk, dst_ty, src_ty, mask, vc.kind, 0, NONE, .[f1, f2], NONE));
    shuffled_c := type_vector(type_count(dst_ty), ir.t_i1, false);
    new = cost_add(new, tti_cmp_sel_cost(vc.tti, .SELECT, dst_ty, shuffled_c, BAD_ICMP_PREDICATE, vc.kind));
    if !value_has_one_use(sel1) new = cost_add(new, cs1);
    if !value_has_one_use(sel2) new = cost_add(new, cs2);
    if new > old return false;
    sc := vcb_shuffle(c1, c2, mask);
    st := vcb_shuffle(t1, t2, mask);
    sf := vcb_shuffle(f1, f2, mask);
    nsel := vcb_select(sc, st, sf, "", NONE, ifx fp1 then get_fmf(sel1) else 0);
    vc_push_value(sc);
    vc_push_value(st);
    vc_push_value(sf);
    vc_replace_value(i, nsel);
    return true;
}

// m_SExtLike(m_Value()): sext, or zext nneg
vc_is_sext_like :: (v: Value_Id) -> bool { return vc_is_op(v, .SEXT) || (vc_is_op(v, .ZEXT) && (inst(v).flags & F_EXACT) != 0); }

// foldShuffleOfCastops
vc_fold_shuffle_of_castops :: (i: Value_Id) -> bool {
    v0 := op(i, 0); v1 := op(i, 1);
    old_mask := shuf_mask(i);
    is_binary := !pm_undef_value(v1);
    if !vc_is_cast(v0) || (is_binary && !vc_is_cast(v1)) return false;
    c0 := v0; c1 := v1;
    opc := inst_op(c0);
    if !is_binary && opc == .BITCAST return false;
    if is_binary {
        if vtype(op(c0, 0)) != vtype(op(c1, 0)) return false;
        if opc != inst_op(c1) {
            if vc_is_sext_like(c0) && vc_is_sext_like(c1) opc = .SEXT;
            else return false;
        }
    }
    dst_ty := vtype(i); cdst := vtype(c0); csrc := vtype(op(c0, 0));
    if !vc_is_fixed_vec(dst_ty) || !vc_is_fixed_vec(cdst) || !vc_is_fixed_vec(csrc) return false;
    ns := cast(s64) type_count(csrc); nd := cast(s64) type_count(cdst);
    if nd != ns && (ns % nd) != 0 && (nd % ns) != 0 return false;
    new_mask: [..] s32;
    if ns >= nd new_mask = narrow_shuffle_mask_elts(ns / nd, old_mask);
    else {
        ok: bool;
        ok, new_mask = widen_shuffle_mask_elts(nd / ns, old_mask);
        if !ok return false;
    }
    new_dst := type_vector(cast(u64) new_mask.count, type_elem(csrc), false);
    cc0 := tti_cast_cost(vc.tti, inst_op(c0), cdst, csrc, CCH_NONE, vc.kind, c0);
    sk := ifx is_binary then SK_PERMUTE_TWO_SRC else SK_PERMUTE_SINGLE_SRC;
    old := cost_add(cc0, tti_shuffle_cost(vc.tti, sk, dst_ty, cdst, old_mask, vc.kind, 0, NONE, .[], i));
    new := tti_shuffle_cost(vc.tti, sk, new_dst, csrc, new_mask, vc.kind, 0, NONE, .[], NONE);
    new = cost_add(new, tti_cast_cost(vc.tti, opc, dst_ty, new_dst, CCH_NONE, vc.kind));
    if !value_has_one_use(c0) new = cost_add(new, cc0);
    if is_binary {
        cc1 := tti_cast_cost(vc.tti, inst_op(c1), cdst, csrc, CCH_NONE, vc.kind, c1);
        old = cost_add(old, cc1);
        if !value_has_one_use(c1) new = cost_add(new, cc1);
    }
    if new > old return false;
    shuf: Value_Id;
    if is_binary shuf = vcb_shuffle(op(c0, 0), op(c1, 0), new_mask);
    else shuf = vcb_shuffle(op(c0, 0), NONE, new_mask);
    c := vcb_cast(opc, shuf, dst_ty);
    if is_inst(c) {
        copy_ir_flags(c, c0);
        if is_binary and_ir_flags(c, c1);
    }
    vc_push_value(shuf);
    vc_replace_value(i, c);
    return true;
}

// foldShuffleOfShuffles
vc_fold_shuffle_of_shuffles :: (i: Value_Id) -> bool {
    outer0 := op(i, 0); outer1 := op(i, 1);
    outer_mask := shuf_mask(i);
    match0, x0, y0, inner0 := vc_match_shuffle(outer0);
    match1, x1, y1, inner1 := vc_match_shuffle(outer1);
    if !match0 && !match1 return false;
    fake1 := false;
    if !match1 && pm_poison(outer1) {
        x1 = x0; y1 = y0;
        inner1 = vc_poison_mask(inner0.count);
        match1 = true;
        fake1 = true;
    }
    if !match0 { x0 = outer0; y0 = outer0; }
    if !match1 { x1 = outer1; y1 = outer1; }
    dst_ty := vtype(i); src_ty := vtype(x0); imm_ty := vtype(outer0);
    if !vc_is_fixed_vec(dst_ty) || !vc_is_fixed_vec(src_ty) || !vc_is_fixed_vec(imm_ty) || vtype(x0) != vtype(x1) return false;
    nsrc := cast(s64) type_count(src_ty);
    nimm := cast(s64) type_count(imm_ty);
    new_mask: [..] s32; new_mask.allocator = temp;
    for outer_mask array_add(*new_mask, it);
    new_x: Value_Id = NONE; new_y: Value_Id = NONE;
    for * mr: new_mask {
        m := mr.*;
        src: Value_Id = NONE;
        if 0 <= m && m < nimm {
            src = outer0;
            if match0 {
                m = inner0[m];
                src = ifx m >= nsrc then y0 else x0;
                if m >= nsrc m -= cast(s32) nsrc;
            }
        } else if m >= nimm {
            src = outer1;
            m -= cast(s32) nimm;
            if match1 {
                m = inner1[m];
                src = ifx m >= nsrc then y1 else x1;
                if m >= nsrc m -= cast(s32) nsrc;
            }
        }
        mr.* = m;
        if src != NONE && m != -1 {
            if pm_undef_value(src) {
                if !pm_poison(src) return false;
                mr.* = -1;
                continue;
            }
            if new_x == NONE || new_x == src { new_x = src; continue; }
            if new_y == NONE || new_y == src { mr.* = m + cast(s32) nsrc; new_y = src; continue; }
            return false;
        }
    }
    if new_x == NONE { vc_replace_value(i, const_poison(dst_ty)); return true; }
    if new_y == NONE new_y = const_poison(src_ty);
    if svm_is_identity(new_mask, nsrc) { vc_replace_value(i, new_x); return true; }
    ic0: Cost = 0;
    if match0 ic0 = tti_instruction_cost(vc.tti, outer0, vc.kind);
    ic1: Cost = 0;
    if match1 ic1 = vc_inst_cost(outer1);   // a PoisonValue for the fake inner shuffle
    oc := tti_instruction_cost(vc.tti, i, vc.kind);
    old := cost_add(cost_add(ic0, ic1), oc);
    is_unary := vc_all_lt(new_mask, nsrc);
    sk := ifx is_unary then SK_PERMUTE_SINGLE_SRC else SK_PERMUTE_TWO_SRC;
    new := tti_shuffle_cost(vc.tti, sk, dst_ty, src_ty, new_mask, vc.kind, 0, NONE, .[new_x, new_y], NONE);
    if !value_has_one_use(outer0) new = cost_add(new, ic0);
    if !value_has_one_use(outer1) new = cost_add(new, ic1);
    if new > old return false;
    shuf := vcb_shuffle(new_x, new_y, new_mask);
    vc_replace_value(i, shuf);
    return true;
}

// foldShufflesOfLengthChangingShuffles
vc_fold_shuffles_of_length_changing_shuffles :: (i: Value_Id) -> bool {
    trunk_ty := vtype(i);
    if !vc_is_fixed_vec(trunk_ty) return false;
    chain := 0;
    mask: [..] s32; mask.allocator = temp;
    ymask: [..] s32; ymask.allocator = temp;
    old: Cost = 0; new: Cost = 0;
    trunk := i;
    ntrunk := cast(s64) type_count(trunk_ty);
    y: Value_Id = NONE;
    while true {
        if chain != 0 && !value_has_one_use(trunk) break;
        okt, outer0, outer1, outer_mask := vc_match_shuffle(trunk);
        if !okt break;
        if vtype(outer0) != trunk_ty break;
        match0, a0, b0, inner0 := vc_match_shuffle(outer0);
        match1, a1, b1, inner1 := vc_match_shuffle(outer1);
        leaf0 := match0 && vtype(a0) != vtype(i);
        leaf1 := match1 && vtype(a1) != vtype(i);
        if leaf0 == leaf1 break;
        if leaf0 {
            t := outer0; outer0 = outer1; outer1 = t;
            tm := inner0; inner0 = inner1; inner1 = tm;
            ta := a0; a0 = a1; a1 = ta;
            tb := b0; b0 = b1; b1 = tb;
            for * outer_mask {
                if it.* == -1 continue;
                if it.* < ntrunk it.* += cast(s32) ntrunk; else it.* -= cast(s32) ntrunk;
            }
        }
        if !value_has_one_use(outer1) break;
        if !pm_undef_value(a1) { if y == NONE y = a1; else if y != a1 break; }
        if !pm_undef_value(b1) { if y == NONE y = b1; else if y != b1 break; }
        y_ty := vtype(a1);
        nleaf := cast(s64) type_count(y_ty);
        local_y: [..] s32; local_y.allocator = temp;
        for inner1 array_add(*local_y, ifx it >= nleaf then cast(s32) (it - nleaf) else it);
        local_old := cost_add(tti_instruction_cost(vc.tti, trunk, vc.kind), tti_instruction_cost(vc.tti, outer1, vc.kind));
        if chain == 0 {
            array_reset_keeping_memory(*mask); for outer_mask array_add(*mask, it);
            array_reset_keeping_memory(*ymask); for local_y array_add(*ymask, it);
            old = local_old; new = local_old;
            trunk = outer0;
            chain += 1;
            continue;
        }
        new_y: [..] s32; new_y.allocator = temp;
        for ymask array_add(*new_y, it);
        valid := true;
        for k: 0..new_y.count-1 {
            if k >= local_y.count break;
            leaf := local_y[k];
            if leaf == -1 || new_y[k] == leaf continue;
            if new_y[k] == -1 new_y[k] = leaf;
            else { valid = false; break; }
        }
        if !valid break;
        nmask: [..] s32; nmask.allocator = temp;
        for m: mask {
            if m < 0 || m >= ntrunk array_add(*nmask, m);
            else array_add(*nmask, outer_mask[m]);
        }
        local_new := cost_add(tti_shuffle_cost(vc.tti, SK_PERMUTE_SINGLE_SRC, trunk_ty, y_ty, new_y, vc.kind, 0, NONE, .[], NONE),
                              tti_shuffle_cost(vc.tti, SK_PERMUTE_TWO_SRC, trunk_ty, trunk_ty, nmask, vc.kind, 0, NONE, .[], NONE));
        if local_new >= new && local_old < local_new - new break;
        mask = nmask;
        ymask = new_y;
        old = cost_add(old, local_old);
        new = local_new;
        trunk = outer0;
        chain += 1;
    }
    if chain <= 1 return false;
    if y == NONE return false;
    all_y := true;
    for mask if !(it < 0 || it >= ntrunk) { all_y = false; break; }
    if all_y {
        for * mask if it.* >= ntrunk it.* = ymask[it.* - ntrunk];
        root := vcb_shuffle(y, const_poison(vtype(y)), mask);
        vc_replace_value(i, root);
        return true;
    }
    leaf := vcb_shuffle(y, const_poison(vtype(y)), ymask);
    root := vcb_shuffle(trunk, leaf, mask);
    vc_replace_value(i, root);
    return true;
}

// foldShuffleOfIntrinsics
vc_fold_shuffle_of_intrinsics :: (i: Value_Id) -> bool {
    ii0 := op(i, 0); ii1 := op(i, 1);
    old_mask := shuf_mask(i);
    id := vc_iid(ii0);
    if id == NOT_INTRINSIC || vc_iid(ii1) == NOT_INTRINSIC return false;
    if id != vc_iid(ii1) return false;
    a0 := ica_from_call(ii0);
    cost0 := tti_intrinsic_cost(vc.tti, *a0, vc.kind);
    a1 := ica_from_call(ii1);
    cost1 := tti_intrinsic_cost(vc.tti, *a1, vc.kind);
    dst_ty := vtype(i); ii0_ty := vtype(ii0);
    if !vc_is_fixed_vec(dst_ty) || !vc_is_fixed_vec(ii0_ty) return false;
    if !is_trivially_vectorizable(id) return false;
    nargs := cast(s64) call_num_args(ii0);
    for k: 0..nargs-1 {
        g0 := call_arg(ii0, cast(u32) k); g1 := call_arg(ii1, cast(u32) k);
        if vu_is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) k) { if g0 != g1 return false; }
        else if vtype(g0) != vtype(g1) return false;
    }
    old := cost_add(cost_add(cost0, cost1), tti_shuffle_cost(vc.tti, SK_PERMUTE_TWO_SRC, dst_ty, ii0_ty, old_mask, vc.kind, 0, NONE, .[ii0, ii1], i));
    new_tys: [..] Type_Id; new_tys.allocator = temp;
    new: Cost = 0;
    seen: [..] [2] Value_Id; seen.allocator = temp;
    for k: 0..nargs-1 {
        g0 := call_arg(ii0, cast(u32) k); g1 := call_arg(ii1, cast(u32) k);
        if vu_is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) k) { array_add(*new_tys, vtype(g0)); continue; }
        vt := vtype(g0);
        at := type_vector(type_count(dst_ty), type_elem(vt), false);
        array_add(*new_tys, at);
        dup := false;
        for seen if it[0] == g0 && it[1] == g1 { dup = true; break; }
        if dup continue;
        pair: [2] Value_Id; pair[0] = g0; pair[1] = g1;
        array_add(*seen, pair);
        new = cost_add(new, tti_shuffle_cost(vc.tti, SK_PERMUTE_TWO_SRC, at, vt, old_mask, vc.kind, 0, NONE, .[g0, g1], NONE));
    }
    na := ica_types(id, dst_ty, new_tys);
    new = cost_add(new, tti_intrinsic_cost(vc.tti, *na, vc.kind));
    if !value_has_one_use(ii0) new = cost_add(new, cost0);
    if ii1 != ii0 && !value_has_one_use(ii1) new = cost_add(new, cost1);
    if new > old return false;
    args: [..] Value_Id; args.allocator = temp;
    cache_k: [..] [2] Value_Id; cache_k.allocator = temp;
    cache_v: [..] Value_Id; cache_v.allocator = temp;
    for k: 0..nargs-1 {
        g0 := call_arg(ii0, cast(u32) k); g1 := call_arg(ii1, cast(u32) k);
        if vu_is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) k) { array_add(*args, g0); continue; }
        hit := -1;
        for cache_k if it[0] == g0 && it[1] == g1 { hit = it_index; break; }
        if hit >= 0 { array_add(*args, cache_v[hit]); continue; }
        s := vcb_shuffle(g0, g1, old_mask);
        pair: [2] Value_Id; pair[0] = g0; pair[1] = g1;
        array_add(*cache_k, pair); array_add(*cache_v, s);
        array_add(*args, s);
        vc_push_value(s);
    }
    ni := vcb_intrinsic(dst_ty, id, args);
    if is_inst(ni) { copy_ir_flags(ni, ii0); and_ir_flags(ni, ii1); }
    vc_replace_value(i, ni);
    return true;
}

// foldPermuteOfIntrinsic
vc_fold_permute_of_intrinsic :: (i: Value_Id) -> bool {
    if !pm_undef(op(i, 1)) return false;
    ii0 := op(i, 0);
    mask := shuf_mask(i);
    id := vc_iid(ii0);
    if id == NOT_INTRINSIC return false;
    dst_ty := vtype(i); src_ty := vtype(ii0);
    if !vc_is_fixed_vec(dst_ty) || !vc_is_fixed_vec(src_ty) return false;
    nsrc := cast(s64) type_count(src_ty);
    if vc_any_ge(mask, nsrc) return false;
    if !is_trivially_vectorizable(id) return false;
    a0 := ica_from_call(ii0);
    icost := tti_intrinsic_cost(vc.tti, *a0, vc.kind);
    old := cost_add(icost, tti_shuffle_cost(vc.tti, SK_PERMUTE_SINGLE_SRC, dst_ty, src_ty, mask, vc.kind, 0, NONE, .[ii0], i));
    new_tys: [..] Type_Id; new_tys.allocator = temp;
    new: Cost = 0;
    nargs := cast(s64) call_num_args(ii0);
    for k: 0..nargs-1 {
        g := call_arg(ii0, cast(u32) k);
        if vu_is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) k) { array_add(*new_tys, vtype(g)); continue; }
        vt := vtype(g);
        at := type_vector(type_count(dst_ty), type_elem(vt), false);
        array_add(*new_tys, at);
        new = cost_add(new, tti_shuffle_cost(vc.tti, SK_PERMUTE_SINGLE_SRC, at, vt, mask, vc.kind, 0, NONE, .[g], NONE));
    }
    na := ica_types(id, dst_ty, new_tys);
    new = cost_add(new, tti_intrinsic_cost(vc.tti, *na, vc.kind));
    if !value_has_one_use(ii0) new = cost_add(new, icost);
    if new > old return false;
    args: [..] Value_Id; args.allocator = temp;
    for k: 0..nargs-1 {
        g := call_arg(ii0, cast(u32) k);
        if vu_is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) k) { array_add(*args, g); continue; }
        s := vcb_shuffle(g, NONE, mask);
        array_add(*args, s);
        vc_push_value(s);
    }
    ni := vcb_intrinsic(dst_ty, id, args);
    if is_inst(ni) copy_ir_flags(ni, ii0);
    vc_replace_value(i, ni);
    return true;
}

// ---------------------------------------------------------------- foldShuffleToIdentity

Vc_Lane :: struct { v: Value_Id; lane: s32; }
Vc_Item :: struct { lanes: [..] Vc_Lane; from: Use_Id; }
Vc_Leaf :: struct { v: Value_Id; from: Use_Id; }

// lookThroughShuffles
vc_look_through_shuffles :: (v_in: Value_Id, lane_in: s32) -> Vc_Lane {
    v := v_in; lane := lane_in;
    while vc_is_op(v, .SHUFFLEVECTOR) {
        n := cast(s32) type_count(vtype(op(v, 0)));
        m := cast,no_check(s32) shuffle_mask(v)[lane];
        if m < 0 return .{NONE, -1};
        if m < n { v = op(v, 0); lane = m; }
        else { v = op(v, 1); lane = m - n; }
    }
    return .{v, lane};
}
// generateInstLaneVectorFromOperand
vc_lanes_from_operand :: (item: [] Vc_Lane, k: u32) -> [..] Vc_Lane {
    out: [..] Vc_Lane; out.allocator = temp;
    for item {
        if it.v != NONE array_add(*out, vc_look_through_shuffles(op(it.v, k), it.lane));
        else array_add(*out, .{NONE, -1});
    }
    return out;
}
vc_leaf_contains :: (s: [] Vc_Leaf, v: Value_Id, from: Use_Id) -> bool { for s if it.v == v && it.from == from return true; return false; }
// Value::getValueID, as far as the equivalence test of foldShuffleToIdentity needs it
vc_value_id :: (v: Value_Id) -> u32 { if is_inst(v) return 1000 + cast(u32) inst_op(v); return cast(u32) vkind(v); }

// isFreeConcat
vc_is_free_concat :: (item: [] Vc_Lane) -> bool {
    ty := vtype(item[0].v);
    n := cast(s64) type_count(ty);
    if item.count == n || n == 1 || item.count % n != 0 return false;
    cm := vc_iota(n * 2);
    if tti_shuffle_cost(vc.tti, SK_PERMUTE_TWO_SRC, type_vector(cast(u64) (n * 2), type_elem(ty), false), ty, cm, vc.kind, 0, NONE, .[], NONE) != 0 return false;
    slices := item.count / n;
    if (slices & (slices - 1)) != 0 return false;
    for s: 0..slices-1 {
        sv := item[s * n].v;
        if sv == NONE || vtype(sv) != ty return false;
        for e: 0..n-1 {
            l := item[s * n + e];
            if l.lane != e || l.v != sv return false;
        }
    }
    return true;
}

// generateNewInstTree
vc_generate_new_inst_tree :: (item: [] Vc_Lane, from: Use_Id, id_leafs: [] Vc_Leaf, splat_leafs: [] Vc_Leaf, concat_leafs: [] Vc_Leaf) -> Value_Id {
    front := item[0].v; front_lane := item[0].lane;
    if vc_leaf_contains(id_leafs, front, from) return front;
    if vc_leaf_contains(splat_leafs, front, from) {
        m: [..] s32; m.allocator = temp;
        for item array_add(*m, front_lane);
        return vcb_shuffle(front, NONE, m);
    }
    if vc_leaf_contains(concat_leafs, front, from) {
        n := cast(s64) type_count(vtype(front));
        values: [..] Value_Id; values.allocator = temp;
        for s: 0..item.count / n - 1 array_add(*values, item[s * n].v);
        while values.count > 1 {
            n *= 2;
            m := vc_iota(n);
            nv: [..] Value_Id; nv.allocator = temp;
            for s: 0..values.count / 2 - 1 array_add(*nv, vcb_shuffle(values[s * 2], values[s * 2 + 1], m));
            values = nv;
        }
        return values[0];
    }
    i := front;
    if inst_op(i) == .BITCAST {
        dt := vtype(i); st := vtype(op(i, 0));
        if vc_is_fixed_vec(dt) && vc_is_fixed_vec(st) && type_count(dt) != type_count(st) {
            de := cast(s64) type_count(dt); se := cast(s64) type_count(st);
            ni: [..] Vc_Lane; ni.allocator = temp;
            if de > se {
                r := de / se;
                if item.count % r != 0 return NONE;
                k := 0;
                while k < item.count {
                    l := item[k];
                    if l.v == NONE array_add(*ni, .{NONE, -1});
                    else array_add(*ni, vc_look_through_shuffles(op(l.v, 0), cast(s32) (l.lane / r)));
                    k += r;
                }
            } else {
                r := se / de;
                for l: item {
                    if l.v == NONE { for j: 0..r-1 array_add(*ni, .{NONE, -1}); continue; }
                    o := op(l.v, 0);
                    for j: 0..r-1 array_add(*ni, vc_look_through_shuffles(o, cast(s32) (l.lane * r + j)));
                }
            }
            o := vc_generate_new_inst_tree(ni, op_use(i, 0), id_leafs, splat_leafs, concat_leafs);
            return vcb_cast(.BITCAST, o, type_vector(cast(u64) item.count, type_elem(dt), false));
        }
    }
    iid := vc_iid(i);
    nops_i: s64 = cast(s64) nops(i) - ifx iid != NOT_INTRINSIC then 1 else 0;
    ops := NewArray(nops_i, Value_Id,, temp);
    for k: 0..nops_i-1 {
        if iid != NOT_INTRINSIC && vu_is_vector_intrinsic_with_scalar_op_at_arg(iid, cast(u32) k) { ops[k] = op(i, cast(u32) k); continue; }
        ops[k] = vc_generate_new_inst_tree(vc_lanes_from_operand(item, cast(u32) k), op_use(i, cast(u32) k), id_leafs, splat_leafs, concat_leafs);
    }
    vl: [..] Value_Id; vl.allocator = temp;
    for item if it.v != NONE array_add(*vl, it.v);
    dst_ty := type_vector(cast(u64) item.count, scalar_type(vtype(i)), false);
    o := inst_op(i);
    r: Value_Id;
    if is_binary_op(o) r = vcb_binop(o, ops[0], ops[1]);
    else if o == .ICMP || o == .FCMP r = vcb_cmp(inst(i).pred, ops[0], ops[1]);
    else if o == .SELECT r = vcb_select(ops[0], ops[1], ops[2], "", i);
    else if is_cast_op(o) r = vcb_cast(o, ops[0], dst_ty);
    else if iid != NOT_INTRINSIC r = vcb_intrinsic(dst_ty, iid, ops);
    else r = vcb_unop(o, ops[0]);
    propagate_ir_flags(r, vl);
    return r;
}

// foldShuffleToIdentity
vc_fold_shuffle_to_identity :: (i: Value_Id) -> bool {
    ty := vtype(i);
    if !vc_is_fixed_vec(ty) || !has_uses(i) return false;
    n := cast(s64) type_count(ty);
    start: [..] Vc_Lane; start.allocator = temp;
    for m: 0..n-1 array_add(*start, vc_look_through_shuffles(i, cast(s32) m));
    wl: [..] Vc_Item; wl.allocator = temp;
    array_add(*wl, .{start, ir.v_first_use[i]});
    id_leafs: [..] Vc_Leaf; id_leafs.allocator = temp;
    splat_leafs: [..] Vc_Leaf; splat_leafs.allocator = temp;
    concat_leafs: [..] Vc_Leaf; concat_leafs.allocator = temp;
    add_leaf :: (s: *[..] Vc_Leaf, v: Value_Id, from: Use_Id) { if !vc_leaf_contains(s.*, v, from) array_add(s, .{v, from}); }
    visited := 0;
    traversed_ec_bitcast := false;
    push_op :: (wl: *[..] Vc_Item, item: [] Vc_Lane, front: Value_Id, k: u32) { array_add(wl, .{vc_lanes_from_operand(item, k), op_use(front, k)}); }
    while wl.count {
        visited += 1;
        if visited > vc_cl.max_instrs_to_scan return false;
        it_from := pop(*wl);
        item := it_from.lanes;
        from := it_from.from;
        fv := item[0].v; fl := item[0].lane;
        if fv == NONE return false;
        is_equiv :: (x: Value_Id, y: Value_Id) -> bool { return vtype(x) == vtype(y) && vc_peek_through_bitcasts(x) == vc_peek_through_bitcasts(y); }
        // an identity value
        if fl == 0 && cast(s64) type_count(vtype(fv)) == item.count {
            ok := true;
            for k: 1..item.count-1 {
                l := item[k];
                if l.v != NONE && !(is_equiv(l.v, fv) && l.lane == k) { ok = false; break; }
            }
            if ok { add_leaf(*id_leafs, fv, from); continue; }
        }
        // constant splats
        if is_const(fv) {
            fs := get_splat_value(fv);
            if fs != NONE {
                ok := true;
                for k: 1..item.count-1 {
                    l := item[k];
                    if l.v != NONE && !(is_const(l.v) && get_splat_value(l.v) == fs) { ok = false; break; }
                }
                if ok { add_leaf(*splat_leafs, fv, from); continue; }
            }
        }
        // a splat value
        {
            ok := true;
            for k: 1..item.count-1 {
                l := item[k];
                if l.v != NONE && !(l.v == fv && l.lane == fl) { ok = false; break; }
            }
            if ok { add_leaf(*splat_leafs, fv, from); continue; }
        }
        lane_equiv :: (l: Vc_Lane, fv: Value_Id) -> bool {
            if l.v == NONE return true;
            v := l.v;
            if is_inst(v) && !has_one_user(v) return false;
            if vc_value_id(v) != vc_value_id(fv) return false;
            if vc_is_cmp(v) && inst(v).pred != inst(fv).pred return false;
            if vc_is_cast(v) && scalar_type(vtype(op(v, 0))) != scalar_type(vtype(op(fv, 0))) return false;
            if vc_is_op(v, .SELECT) && (!is_vector_type(vtype(op(v, 0))) || vtype(op(v, 0)) != vtype(op(fv, 0))) return false;
            if vc_is_op(v, .CALL) && call_iid(v) == NOT_INTRINSIC return false;
            id := vc_iid(v);
            if id == NOT_INTRINSIC return true;
            return vc_iid(fv) != NOT_INTRINSIC && id == vc_iid(fv) && call_num_bundles(v) == 0;
        }
        all_equiv := true;
        for k: 1..item.count-1 if !lane_equiv(item[k], fv) { all_equiv = false; break; }
        if all_equiv && is_inst(fv) {
            o := inst_op(fv);
            fid := vc_iid(fv);
            if is_binary_op(o) || o == .ICMP || o == .FCMP {
                if is_binary_op(o) && is_int_div_rem(o) return false;
                push_op(*wl, item, fv, 0);
                push_op(*wl, item, fv, 1);
                continue;
            } else if o == .FNEG || o == .TRUNC || o == .ZEXT || o == .SEXT || o == .FPTOSI || o == .FPTOUI || o == .SITOFP || o == .UITOFP {
                push_op(*wl, item, fv, 0);
                continue;
            } else if o == .BITCAST {
                dt := vtype(fv); st := vtype(op(fv, 0));
                if vc_is_fixed_vec(dt) && vc_is_fixed_vec(st) {
                    de := cast(s64) type_count(dt); se := cast(s64) type_count(st);
                    if de == se { push_op(*wl, item, fv, 0); continue; }
                    if de > se && de % se == 0 {
                        r := de / se;
                        ni: [..] Vc_Lane; ni.allocator = temp;
                        valid := item.count % r == 0;
                        idx := 0;
                        while valid && idx < item.count {
                            l0 := item[idx];
                            if l0.v == NONE {
                                for j: idx + 1..idx + r - 1 if item[j].v != NONE { valid = false; break; }
                                if !valid break;
                                array_add(*ni, .{NONE, -1});
                                idx += r;
                                continue;
                            }
                            if l0.lane % r != 0 { valid = false; break; }
                            for j: 1..r-1 {
                                lj := item[idx + j];
                                if lj.v == NONE || lj.v != l0.v || lj.lane != l0.lane + j { valid = false; break; }
                            }
                            if !valid break;
                            array_add(*ni, vc_look_through_shuffles(op(l0.v, 0), cast(s32) (l0.lane / r)));
                            idx += r;
                        }
                        if valid {
                            traversed_ec_bitcast = true;
                            array_add(*wl, .{ni, op_use(fv, 0)});
                            continue;
                        }
                    } else if se > de && se % de == 0 {
                        r := se / de;
                        ni: [..] Vc_Lane; ni.allocator = temp;
                        for l: item {
                            if l.v == NONE { for j: 0..r-1 array_add(*ni, .{NONE, -1}); continue; }
                            src := op(l.v, 0);
                            for j: 0..r-1 array_add(*ni, vc_look_through_shuffles(src, cast(s32) (l.lane * r + j)));
                        }
                        traversed_ec_bitcast = true;
                        array_add(*wl, .{ni, op_use(fv, 0)});
                        continue;
                    }
                }
            } else if o == .SELECT {
                push_op(*wl, item, fv, 0);
                push_op(*wl, item, fv, 1);
                push_op(*wl, item, fv, 2);
                continue;
            } else if fid != NOT_INTRINSIC && is_trivially_vectorizable(fid) && call_num_bundles(fv) == 0 {
                bail := false;
                for k: 0..cast(s64) nops(fv) - 2 {
                    if vu_is_vector_intrinsic_with_scalar_op_at_arg(fid, cast(u32) k) {
                        for j: 1..item.count-1 {
                            v := item[j].v;
                            if v != NONE && op(v, cast(u32) k) != op(fv, cast(u32) k) { bail = true; break; }
                        }
                        if bail break;
                        continue;
                    }
                    push_op(*wl, item, fv, cast(u32) k);
                }
                if bail return false;
                continue;
            }
        }
        if vc_is_free_concat(item) { add_leaf(*concat_leafs, fv, from); continue; }
        return false;
    }
    if visited <= 1 return false;
    if visited == 2 && traversed_ec_bitcast return false;
    irb_set_before(*vc.b, i);
    v := vc_generate_new_inst_tree(start, ir.v_first_use[i], id_leafs, splat_leafs, concat_leafs);
    vc_replace_value(i, v);
    return true;
}

// ---------------------------------------------------------------- reductions

vc_is_lane_invariant_reduction :: (id: Intrinsic_Id) -> bool {
    return id == IID_VECTOR_REDUCE_ADD || id == IID_VECTOR_REDUCE_MUL || id == IID_VECTOR_REDUCE_AND || id == IID_VECTOR_REDUCE_OR ||
           id == IID_VECTOR_REDUCE_XOR || id == IID_VECTOR_REDUCE_SMIN || id == IID_VECTOR_REDUCE_SMAX ||
           id == IID_VECTOR_REDUCE_UMIN || id == IID_VECTOR_REDUCE_UMAX;
}

// foldShuffleFromReductions
vc_fold_shuffle_from_reductions :: (i: Value_Id) -> bool {
    if !vc_is_lane_invariant_reduction(vc_iid(i)) return false;
    queue: [..] Value_Id; queue.allocator = temp;
    head := 0;
    visited: [..] Value_Id; visited.allocator = temp;
    shuffle: Value_Id = NONE;
    if is_inst(op(i, 0)) array_add(*queue, op(i, 0));
    contains :: (s: [] Value_Id, v: Value_Id) -> bool { for s if it == v return true; return false; }
    while head < queue.count {
        cv := queue[head];
        head += 1;
        if contains(visited, cv) continue;
        if is_splat_value(cv) continue;
        array_add(*visited, cv);
        if is_inst(cv) {
            if is_binary_op(inst_op(cv)) {
                for k: 0..cast(s64) nops(cv) - 1 array_add(*queue, op(cv, cast(u32) k));
                continue;
            } else if inst_op(cv) == .SHUFFLEVECTOR {
                if shuffle != NONE && shuffle != cv return false;
                shuffle = cv;
                continue;
            }
        }
        return false;
    }
    if shuffle == NONE return false;
    for v: visited {
        u := ir.v_first_use[v];
        while u != NONE {
            usr := ir.u_user[u];
            if !contains(visited, usr) && usr != i return false;
            u = ir.u_next[u];
        }
    }
    vec_ty := vtype(op(i, 0));
    if !vc_is_fixed_vec(vec_ty) return false;
    in_ty := vtype(op(shuffle, 0));
    if !vc_is_fixed_vec(in_ty) return false;
    nin := cast(s64) type_count(in_ty);
    cmask := shuf_mask(shuffle);
    // sort(ConcatMask, (unsigned)X < (unsigned)Y): poison lanes last
    for a: 1..cmask.count-1 {
        x := cmask[a]; j := a - 1;
        while j >= 0 && cast,no_check(u32) cmask[j] > cast,no_check(u32) x { cmask[j + 1] = cmask[j]; j -= 1; }
        cmask[j + 1] = x;
    }
    uses_second := vc_any_ge(cmask, nin);
    sk := ifx uses_second then SK_PERMUTE_TWO_SRC else SK_PERMUTE_SINGLE_SRC;
    old := tti_shuffle_cost(vc.tti, sk, vec_ty, in_ty, shuf_mask(shuffle), vc.kind, 0, NONE, .[], NONE);
    new := tti_shuffle_cost(vc.tti, sk, vec_ty, in_ty, cmask, vc.kind, 0, NONE, .[], NONE);
    if new < old {
        irb_set_before(*vc.b, shuffle);
        ns := vcb_shuffle(op(shuffle, 0), op(shuffle, 1), cmask);
        vc_replace_value(shuffle, ns);
        return true;
    }
    return vc_fold_select_shuffle(shuffle, true);
}

// foldShuffleChainsToReduce
vc_fold_shuffle_chains_to_reduce :: (i: Value_Id) -> bool {
    if !pm_zero(op(i, 1)) return false;
    vec_ee := op(i, 0);
    fvt := vtype(vec_ee);
    if !vc_is_fixed_vec(fvt) || type_count(fvt) < 2 return false;
    common_binop := Opcode.NONE_OP;
    common_call: Intrinsic_Id = NOT_INTRINSIC;
    if vc_is_binop(vec_ee) {
        if reduction_for_binop(inst_op(vec_ee)) == NOT_INTRINSIC return false;
        common_binop = inst_op(vec_ee);
    } else if is_min_max_intrinsic(vc_iid(vec_ee)) {
        common_call = vc_iid(vec_ee);
    } else return false;
    common_fmf: u32 = 0;
    is_float := false;
    Chain :: struct { nodes: [..] Value_Id; sources: [..] Value_Id; visited: s64; binop: Opcode; call: Intrinsic_Id; }
    ch: Chain;
    ch.nodes.allocator = temp; ch.sources.allocator = temp;
    ch.binop = common_binop; ch.call = common_call;
    contains :: (s: [] Value_Id, v: Value_Id) -> bool { for s if it == v return true; return false; }
    is_chain_node :: (ch: *Chain, v: Value_Id) -> bool {
        if vc_is_binop(v) return ch.binop != .NONE_OP && inst_op(v) == ch.binop;
        id := vc_iid(v);
        if is_min_max_intrinsic(id) return ch.call != NOT_INTRINSIC && id == ch.call;
        if vc_is_op(v, .SHUFFLEVECTOR) return pm_poison(op(v, 1));
        return false;
    }
    add_source :: (ch: *Chain, v: Value_Id) -> bool {
        if !vc_is_fixed_vec(vtype(v)) return false;
        if !contains(ch.sources, v) array_add(*ch.sources, v);
        return true;
    }
    walk :: (ch: *Chain, v: Value_Id) -> bool {
        if contains(ch.nodes, v) || contains(ch.sources, v) return true;
        ch.visited += 1;
        if ch.visited > 32 return false;
        if !is_chain_node(ch, v) return add_source(ch, v);
        n: u32 = ifx vc_is_op(v, .SHUFFLEVECTOR) then cast(u32) 1 else 2;
        for k: 0..n-1 if !walk(ch, op(v, k)) return false;
        if vc_is_op(v, .SHUFFLEVECTOR) || contains(ch.nodes, op(v, 0)) || contains(ch.nodes, op(v, 1)) {
            if !contains(ch.nodes, v) array_add(*ch.nodes, v);
            return true;
        }
        return add_source(ch, v);
    }
    if !walk(*ch, vec_ee) || ch.nodes.count == 0 return false;
    idempotent := common_call != NOT_INTRINSIC || (common_binop == .AND || common_binop == .OR);
    for v: ch.nodes {
        if !vc_is_binop(v) || !is_fp_type(scalar_type(vtype(v))) continue;
        f := get_fmf(v);
        if (f & FMF_REASSOC) == 0 return false;
        if !is_float { common_fmf = f; is_float = true; }
        else common_fmf &= f;
    }
    // Demands: per value, the lanes feeding lane 0 of the extract and the ones feeding it more than once
    Demand :: struct { v: Value_Id; lanes: [] bool; dups: [] bool; }
    demands: [..] Demand; demands.allocator = temp;
    find_demand :: (d: *[..] Demand, v: Value_Id) -> s64 { for d.* if it.v == v return it_index; return -1; }
    demand_of :: (d: *[..] Demand, v: Value_Id) -> s64 {
        n := cast(s64) type_count(vtype(v));
        k := find_demand(d, v);
        if k < 0 { e: Demand; e.v = v; array_add(d, e); k = d.count - 1; }
        if d.*[k].lanes.count != n {
            d.*[k].lanes = NewArray(n, bool,, temp);
            d.*[k].dups = NewArray(n, bool,, temp);
        }
        return k;
    }
    k0 := demand_of(*demands, vec_ee);
    demands[k0].lanes[0] = true;
    for < v: ch.nodes {
        kv := find_demand(*demands, v);
        if kv < 0 continue;
        dv_lanes := array_copy(demands[kv].lanes,, temp);
        dv_dups := array_copy(demands[kv].dups,, temp);
        any := false; for dv_lanes if it any = true;
        if !any continue;
        if vc_is_op(v, .SHUFFLEVECTOR) {
            mask := shuf_mask(v);
            ks := demand_of(*demands, op(v, 0));
            ds := *demands[ks];
            for m, x: mask {
                if !dv_lanes[x] || m < 0 || m >= ds.lanes.count continue;
                if ds.lanes[m] || dv_dups[x] ds.dups[m] = true;
                ds.lanes[m] = true;
            }
        } else {
            for o: 0..1 {
                ko := demand_of(*demands, op(v, cast(u32) o));
                d := *demands[ko];
                for x: 0..d.lanes.count-1 {
                    d.dups[x] = d.dups[x] || dv_dups[x] || (d.lanes[x] && dv_lanes[x]);
                    d.lanes[x] = d.lanes[x] || dv_lanes[x];
                }
            }
        }
    }
    covers_chain :: (ch: *Chain, root: Value_Id, v: Value_Id) -> bool {
        stack: [..] Value_Id; stack.allocator = temp;
        seen: [..] Value_Id; seen.allocator = temp;
        array_add(*stack, root); array_add(*seen, root);
        while stack.count {
            u := pop(*stack);
            n: u32 = ifx vc_is_op(u, .SHUFFLEVECTOR) then cast(u32) 1 else 2;
            for k: 0..n-1 {
                o := op(u, k);
                if o == v || contains(seen, o) continue;
                array_add(*seen, o);
                if !contains(ch.nodes, o) return false;
                array_add(*stack, o);
            }
        }
        return true;
    }
    any_true :: (b: [] bool) -> bool { for b if it return true; return false; }
    all_true_b :: (b: [] bool) -> bool { for b if !it return false; return true; }
    cut_src: Value_Id = NONE;
    cut_elts: [] bool;
    for s: ch.sources {
        ks := find_demand(*demands, s);
        if ks < 0 || !any_true(demands[ks].lanes) continue;
        if cut_src != NONE || (!idempotent && any_true(demands[ks].dups)) { cut_src = NONE; break; }
        cut_src = s; cut_elts = demands[ks].lanes;
    }
    if cut_src == NONE {
        for v: ch.nodes {
            if !vc_is_binop(v) && !is_min_max_intrinsic(vc_iid(v)) continue;
            kv := find_demand(*demands, v);
            if kv < 0 || !all_true_b(demands[kv].lanes) continue;
            if !idempotent && any_true(demands[kv].dups) continue;
            if !covers_chain(*ch, vec_ee, v) continue;
            cut_src = v; cut_elts = demands[kv].lanes;
            break;
        }
    }
    npop := 0; for cut_elts if it npop += 1;
    if cut_src == NONE || npop < 2 return false;
    reduced_op := ifx common_call != NOT_INTRINSIC then min_max_reduction_intrinsic_id(common_call) else reduction_for_binop(common_binop);
    if reduced_op == NOT_INTRINSIC return false;
    orig: Cost = 0;
    for ch.nodes orig = cost_add(orig, tti_instruction_cost(vc.tti, it, vc.kind));
    src_vt := vtype(cut_src);
    partial := !all_true_b(cut_elts);
    red_ty := ifx partial then type_vector(cast(u64) npop, type_elem(fvt), false) else src_vt;
    extract_mask: [..] s32; extract_mask.allocator = temp;
    new: Cost = 0;
    if partial {
        for cut_elts if it array_add(*extract_mask, cast(s32) it_index);
        // APInt::isShiftedMask(MaskIdx, MaskLen)
        first := -1; last := -1;
        for cut_elts if it { if first < 0 first = it_index; last = it_index; }
        shifted := last - first + 1 == npop;
        sub_idx := ifx shifted then first else 0;
        sk := ifx shifted then SK_EXTRACT_SUBVECTOR else SK_PERMUTE_SINGLE_SRC;
        new = cost_add(new, tti_shuffle_cost(vc.tti, sk, red_ty, src_vt, extract_mask, vc.kind, sub_idx, red_ty, .[], NONE));
    }
    ica: Ica;
    if is_float ica = ica_types(reduced_op, type_elem(red_ty), .[type_elem(red_ty), red_ty], common_fmf);
    else ica = ica_types(reduced_op, type_elem(red_ty), .[red_ty]);
    new = cost_add(new, tti_intrinsic_cost(vc.tti, *ica, vc.kind));
    if !cost_valid(orig) || !cost_valid(new) return false;
    if ifx value_has_one_use(vec_ee) then new > orig else new >= orig return false;
    input := cut_src;
    if partial input = vcb_shuffle(cut_src, NONE, extract_mask);
    reduced: Value_Id;
    if is_float {
        ident: Value_Id;
        if common_binop == .FADD && (common_fmf & FMF_NSZ) != 0 ident = fp_zero_of(type_elem(red_ty), false);
        else ident = cf_binop_identity(common_binop, type_elem(red_ty), false);
        reduced = vcb_intrinsic_tys(reduced_op, .[red_ty], .[ident, input], common_fmf);
    } else {
        reduced = vcb_intrinsic_tys(reduced_op, .[red_ty], .[input]);
    }
    vc_replace_value(i, reduced);
    return true;
}

// foldCastFromReductions
vc_fold_cast_from_reductions :: (i: Value_Id) -> bool {
    id := vc_iid(i);
    trunc_only := false;
    if id == IID_VECTOR_REDUCE_ADD || id == IID_VECTOR_REDUCE_MUL trunc_only = true;
    else if id != IID_VECTOR_REDUCE_AND && id != IID_VECTOR_REDUCE_OR && id != IID_VECTOR_REDUCE_XOR return false;
    red_opc := arithmetic_reduction_instruction(id);
    rsrc := op(i, 0);
    is_trunc := value_has_one_use(rsrc) && opr_code(rsrc) == .TRUNC;
    if !is_trunc && (trunc_only || !(value_has_one_use(rsrc) && (vc_is_op(rsrc, .ZEXT) || vc_is_op(rsrc, .SEXT)))) return false;
    if !is_inst(rsrc) fatal("vector-combine: foldCastFromReductions of a constant expression");
    src := op(rsrc, 0);
    copc := inst_op(rsrc);
    src_ty := vtype(src); rsrc_ty := vtype(rsrc);
    res_ty := vtype(i);
    old := tti_arithmetic_reduction_cost(vc.tti, red_opc, rsrc_ty, false, 0, vc.kind);
    old = cost_add(old, tti_cast_cost(vc.tti, copc, rsrc_ty, src_ty, CCH_NONE, vc.kind, rsrc));
    new := cost_add(tti_arithmetic_reduction_cost(vc.tti, red_opc, src_ty, false, 0, vc.kind),
                    tti_cast_cost(vc.tti, copc, res_ty, scalar_type(rsrc_ty), CCH_NONE, vc.kind));
    if old <= new || !cost_valid(new) return false;
    nr := vcb_intrinsic(scalar_type(src_ty), id, .[src]);
    nc := vcb_cast(copc, nr, res_ty);
    vc_replace_value(i, nc);
    return true;
}

// icmp pred X, C with an APInt C (m_ICmp(Pred, m_Value, m_APInt))
vc_match_icmp_apint :: (i: Value_Id) -> (bool, u8, Value_Id, APInt) {
    if !vc_is_op(i, .ICMP) return false, 0, NONE, .{};
    ok, c := pm_apint(op(i, 1));
    if !ok return false, 0, NONE, .{};
    return true, inst(i).pred, op(i, 0), c;
}

// foldSignBitReductionCmp
vc_fold_sign_bit_reduction_cmp :: (i: Value_Id) -> bool {
    ok, pred, red, cmp_val := vc_match_icmp_apint(i);
    if !ok || !value_has_one_use(red) return false;
    orig_iid := vc_iid(red);
    if orig_iid != IID_VECTOR_REDUCE_OR && orig_iid != IID_VECTOR_REDUCE_UMAX && orig_iid != IID_VECTOR_REDUCE_AND &&
       orig_iid != IID_VECTOR_REDUCE_UMIN && orig_iid != IID_VECTOR_REDUCE_ADD return false;
    rsrc := call_arg(red, 0);
    vec_ty := vtype(rsrc);
    if !vc_is_fixed_vec(vec_ty) return false;
    bw := type_int_width(type_elem(vec_ty));
    if bw == 1 return false;
    nelts := type_count(vec_ty);
    tree_opc: Opcode;
    if orig_iid == IID_VECTOR_REDUCE_OR || orig_iid == IID_VECTOR_REDUCE_UMAX tree_opc = .OR;
    else if orig_iid == IID_VECTOR_REDUCE_AND || orig_iid == IID_VECTOR_REDUCE_UMIN tree_opc = .AND;
    else tree_opc = .ADD;
    wl: [..] Value_Id; wl.allocator = temp;
    sources: [..] Value_Id; sources.allocator = temp;
    array_add(*wl, rsrc);
    has_ashr := false; is_ashr := false;
    MAX_SOURCES :: 8;
    old := tti_instruction_cost(vc.tti, red, vc.kind);
    while wl.count && wl.count <= MAX_SOURCES && sources.count <= MAX_SOURCES {
        v := pop(*wl);
        oc := opr_code(v);
        if value_has_one_use(v) && (oc == .LSHR || oc == .ASHR) && pm_specific_int(op(v, 1), bw - 1) {
            this_ashr := oc == .ASHR;
            if !has_ashr { has_ashr = true; is_ashr = this_ashr; }
            else if is_ashr != this_ashr return false;
            array_add(*sources, op(v, 0));
            old = cost_add(old, vc_inst_cost(v));
            continue;
        }
        if !(value_has_one_use(v) && oc == tree_opc) return false;
        old = cost_add(old, vc_inst_cost(v));
        array_add(*wl, op(v, 0));
        array_add(*wl, op(v, 1));
    }
    if sources.count == 0 || sources.count > MAX_SOURCES || wl.count > MAX_SOURCES || !has_ashr return false;
    nsrc := cast(u64) sources.count;
    if orig_iid == IID_VECTOR_REDUCE_ADD {
        // isIntN(BitWidth, NumSources * NumElts)
        x := cast(s64) (nsrc * nelts);
        if bw < 64 && (x >= ((cast(s64) 1) << (bw - 1)) || x < -((cast(s64) 1) << (bw - 1))) return false;
    }
    count: u64 = ifx orig_iid == IID_VECTOR_REDUCE_ADD then nsrc * nelts else 1;
    cbw := cmp_val.bits;
    neg_val := ap_from_u64(cbw, count);
    if is_ashr neg_val = ap_neg(neg_val);
    zero := ap_zero(cbw);
    range_low := ap_smin(zero, neg_val);
    range_high := ap_smax(zero, neg_val);
    p := pred;
    if !icmp_is_equality(p) && !icmp_is_signed(p) {
        if ap_is_negative(range_low) return false;
        p = icmp_signed_predicate(p);
    }
    is_eq: bool; tests_neg: bool;
    if icmp_is_equality(p) {
        if ap_is_zero(cmp_val) tests_neg = false;
        else if ap_eq(cmp_val, neg_val) tests_neg = true;
        else return false;
        is_eq = p == ICMP_EQ;
    } else if p == ICMP_SLT && ap_eq(cmp_val, range_high) {
        is_eq = false; tests_neg = ap_eq(range_high, neg_val);
    } else if p == ICMP_SGT && ap_eq(cmp_val, ap_sub_u64(range_high, 1)) {
        is_eq = true; tests_neg = ap_eq(range_high, neg_val);
    } else if p == ICMP_SGT && ap_eq(cmp_val, range_low) {
        is_eq = false; tests_neg = ap_eq(range_low, neg_val);
    } else if p == ICMP_SLT && ap_eq(cmp_val, ap_add_u64(range_low, 1)) {
        is_eq = true; tests_neg = ap_eq(range_low, neg_val);
    } else return false;
    ANY_NON_NEG :: 0b000; ALL_NEG :: 0b011; ALL_NON_NEG :: 0b101; ANY_NEG :: 0b110;
    base: u32;
    if orig_iid == IID_VECTOR_REDUCE_OR || orig_iid == IID_VECTOR_REDUCE_UMAX base = ifx tests_neg then cast(u32) ANY_NEG else ALL_NON_NEG;
    else if orig_iid == IID_VECTOR_REDUCE_AND || orig_iid == IID_VECTOR_REDUCE_UMIN base = ifx tests_neg then cast(u32) ALL_NEG else ANY_NON_NEG;
    else base = ifx tests_neg then cast(u32) ALL_NEG else ALL_NON_NEG;
    check := ifx is_eq then base else base ^ 0b011;
    requires_or := (check & 0b100) != 0;
    neg_check := (check & 0b010) != 0;
    pick :: (arith: Intrinsic_Id, mm: Intrinsic_Id, vec_ty: Type_Id) -> (Intrinsic_Id, Cost) {
        ac := tti_arithmetic_reduction_cost(vc.tti, arithmetic_reduction_instruction(arith), vec_ty, false, 0, vc.kind);
        mc := tti_min_max_reduction_cost(vc.tti, min_max_reduction_intrinsic_op(mm), vec_ty, 0, vc.kind);
        if ac <= mc return arith, ac;
        return mm, mc;
    }
    new_iid: Intrinsic_Id; new: Cost;
    if requires_or new_iid, new = pick(IID_VECTOR_REDUCE_OR, IID_VECTOR_REDUCE_UMAX, vec_ty);
    else new_iid, new = pick(IID_VECTOR_REDUCE_AND, IID_VECTOR_REDUCE_UMIN, vec_ty);
    if nsrc > 1 {
        copc: Opcode = ifx requires_or then .OR else .AND;
        new = cost_add(new, cost_mul(tti_arith_cost(vc.tti, copc, vec_ty, vc.kind), cast(Cost) (nsrc - 1)));
    }
    if new > old return false;
    irb_set_before(*vc.b, i);
    sty := type_elem(vec_ty);
    input: Value_Id;
    if nsrc == 1 input = sources[0];
    else {
        input = sources[0];
        for k: 1..sources.count-1 input = vcb_binop(ifx requires_or then Opcode.OR else .AND, input, sources[k]);
    }
    nr := vcb_intrinsic(sty, new_iid, .[input]);
    ncmp: Value_Id;
    if neg_check ncmp = vcb_cmp(ICMP_SLT, nr, const_null_value(vtype(nr)));
    else ncmp = vcb_cmp(ICMP_SGT, nr, cf_all_ones(vtype(nr)));
    vc_replace_value(i, ncmp);
    return true;
}

// foldReductionZeroTest
vc_fold_reduction_zero_test :: (i: Value_Id) -> bool {
    if !vc_is_op(i, .ICMP) return false;
    pred := inst(i).pred;
    o: Value_Id;
    if pm_zero(op(i, 1)) o = op(i, 0);
    else if pm_zero(op(i, 0)) o = op(i, 1);
    else return false;
    if !icmp_is_equality(pred) return false;
    ii := o;
    id := vc_iid(ii);
    if id == NOT_INTRINSIC || !value_has_one_use(ii) return false;
    if id != IID_VECTOR_REDUCE_OR && id != IID_VECTOR_REDUCE_UMAX return false;
    vec := call_arg(ii, 0);
    vec_ty := vtype(vec);
    if !vc_is_fixed_vec(vec_ty) || !is_int_type(type_elem(vec_ty)) return false;
    new_iid := ifx pred == ICMP_NE then IID_VECTOR_REDUCE_OR else IID_VECTOR_REDUCE_AND;
    old := cost_add(tti_instruction_cost(vc.tti, ii, vc.kind), tti_instruction_cost(vc.tti, i, vc.kind));
    cmp_ty := vc_cmp_result_type(vec_ty);
    new := tti_cmp_sel_cost(vc.tti, .ICMP, vec_ty, cmp_ty, pred, vc.kind);
    new = cost_add(new, tti_arithmetic_reduction_cost(vc.tti, arithmetic_reduction_instruction(new_iid), cmp_ty, false, 0, vc.kind));
    if !cost_valid(old) || !cost_valid(new) || new > old return false;
    irb_set_before(*vc.b, i);
    nc := vcb_cmp(pred, vec, const_null_value(vec_ty));
    nr := vcb_intrinsic_tys(new_iid, .[cmp_ty], .[nc]);
    vc_replace_value(i, nr);
    return true;
}

// foldICmpEqZeroVectorReduce
vc_fold_icmp_eq_zero_vector_reduce :: (i: Value_Id) -> bool {
    if !vc_is_op(i, .ICMP) || !pm_zero(op(i, 1)) return false;
    pred := inst(i).pred;
    if !icmp_is_equality(pred) return false;
    ii := op(i, 0);
    id := vc_iid(ii);
    if id != IID_VECTOR_REDUCE_ADD && id != IID_VECTOR_REDUCE_OR && id != IID_VECTOR_REDUCE_UMIN && id != IID_VECTOR_REDUCE_UMAX &&
       id != IID_VECTOR_REDUCE_SMIN && id != IID_VECTOR_REDUCE_SMAX return false;
    inner := call_arg(ii, 0);
    if !value_has_one_use(ii) || !vc_is_fixed_vec(vtype(inner)) return false;
    x: Value_Id = NONE;
    oc := opr_code(inner);
    if oc == .SHL && (opr_flags(inner) & F_NUW) != 0 x = op(inner, 0);
    else if oc == .MUL && (opr_flags(inner) & F_NUW) != 0 && pm_non_zero_int(op(inner, 1)) x = op(inner, 0);
    else if vc_is_op(inner, .ZEXT) || vc_is_op(inner, .SEXT) x = op(inner, 0);
    else { okn, nx := pm_neg(inner); if okn x = nx; }
    if x == NONE return false;
    s := sq_with_instruction(vc.sq, i);
    xty := vtype(x);
    if id == IID_VECTOR_REDUCE_ADD {
        kx := known_bits(x, s);
        kfx := known_bits(inner, s);
        ne := type_count(xty);
        lost: u32 = 0; while ((cast(u64) 1) << lost) < ne lost += 1;   // Log2_32_Ceil
        if kb_count_min_leading_zeros(kx) <= lost || kb_count_min_leading_zeros(kfx) <= lost return false;
    } else if id == IID_VECTOR_REDUCE_SMIN || id == IID_VECTOR_REDUCE_SMAX {
        if !is_known_non_negative(inner, s) || !is_known_non_negative(x, s) return false;
    }
    if vc_is_op(inner, .ZEXT) || vc_is_op(inner, .SEXT) {
        fxty := vtype(inner);
        ext := tti_cast_cost(vc.tti, inst_op(inner), fxty, xty, CCH_NONE, vc.kind, inner);
        oldr, newr: Cost;
        if id == IID_VECTOR_REDUCE_ADD || id == IID_VECTOR_REDUCE_OR {
            oldr = tti_arithmetic_reduction_cost(vc.tti, arithmetic_reduction_instruction(id), fxty, false, 0, vc.kind);
            newr = tti_arithmetic_reduction_cost(vc.tti, arithmetic_reduction_instruction(id), xty, false, 0, vc.kind);
        } else {
            oldr = tti_min_max_reduction_cost(vc.tti, min_max_reduction_intrinsic_op(id), fxty, 0, vc.kind);
            newr = tti_min_max_reduction_cost(vc.tti, min_max_reduction_intrinsic_op(id), xty, 0, vc.kind);
        }
        old := cost_add(oldr, ext);
        new := cost_add(newr, ifx value_has_one_use(inner) then cast(Cost) 0 else ext);
        if new > old return false;
    }
    ty := type_elem(xty);
    nr := vcb_intrinsic(ty, id, .[x]);
    nc := vcb_cmp(pred, nr, const_null_value(ty));
    vc_replace_value(i, nc);
    return true;
}

// foldEquivalentReductionCmp
vc_fold_equivalent_reduction_cmp :: (i: Value_Id) -> bool {
    ok, pred, red, cv := vc_match_icmp_apint(i);
    if !ok return false;
    id := vc_iid(red);
    if id == NOT_INTRINSIC || !value_has_one_use(red) return false;
    valid_or_umax :: (cv: APInt, pred: u8) -> bool {
        if cv.bits == 1 return true;
        is_eq := (ap_is_zero(cv) || ap_is_one(cv)) && icmp_is_equality(pred);
        is_pos := ap_is_all_ones(cv) && pred == ICMP_SGT;
        is_neg := (ap_is_zero(cv) || ap_is_one(cv) || ap_eq_u64(cv, 2)) && pred == ICMP_SLT;
        return is_eq || is_pos || is_neg;
    }
    valid_and_umin :: (cv: APInt, pred: u8) -> bool {
        if cv.bits == 1 return true;
        lo := ap_clo(cv);
        is_eq := (ap_is_all_ones(cv) || lo + 1 == cv.bits) && icmp_is_equality(pred);
        is_neg := ap_is_zero(cv) && pred == ICMP_SLT;
        is_pos := lo + 2 >= cv.bits && (ap_get_bit(cv, 0) || ap_get_bit(cv, 1)) && pred == ICMP_SGT;
        return is_eq || is_neg || is_pos;
    }
    alt: Intrinsic_Id;
    if id == IID_VECTOR_REDUCE_OR { if !valid_or_umax(cv, pred) return false; alt = IID_VECTOR_REDUCE_UMAX; }
    else if id == IID_VECTOR_REDUCE_UMAX { if !valid_or_umax(cv, pred) return false; alt = IID_VECTOR_REDUCE_OR; }
    else if id == IID_VECTOR_REDUCE_AND { if !valid_and_umin(cv, pred) return false; alt = IID_VECTOR_REDUCE_UMIN; }
    else if id == IID_VECTOR_REDUCE_UMIN { if !valid_and_umin(cv, pred) return false; alt = IID_VECTOR_REDUCE_AND; }
    else return false;
    x := call_arg(red, 0);
    vec_ty := vtype(x);
    if !vc_is_fixed_vec(vec_ty) return false;
    red_cost :: (id: Intrinsic_Id, vec_ty: Type_Id) -> Cost {
        opc := arithmetic_reduction_instruction(id);
        if opc != .ICMP return tti_arithmetic_reduction_cost(vc.tti, opc, vec_ty, false, 0, vc.kind);
        return tti_min_max_reduction_cost(vc.tti, min_max_reduction_intrinsic_op(id), vec_ty, 0, vc.kind);
    }
    orig := red_cost(id, vec_ty);
    altc := red_cost(alt, vec_ty);
    if altc >= orig return false;
    irb_set_before(*vc.b, i);
    sty := type_elem(vec_ty);
    nr := vcb_intrinsic(sty, alt, .[x]);
    nc := vcb_cmp(pred, nr, const_int_ap(sty, cv));
    vc_replace_value(i, nc);
    return true;
}

// isKnownNonPositive (the static helper of foldReduceAddCmpZero)
vc_is_known_non_positive :: (v: Value_Id, q: Simplify_Query, depth: u32 = 0) -> bool {
    if depth > 2 return false;
    nsb :: (x: Value_Id, q: Simplify_Query) -> u32 { return num_sign_bits_ctx(x, q.cxt, q.dt, q.ac); }
    if nsb(v, q) == type_int_width(scalar_type(vtype(v))) return true;
    if opr_code(v) == .ADD {
        a := op(v, 0); b := op(v, 1);
        return nsb(a, q) >= 2 && nsb(b, q) >= 2 && vc_is_known_non_positive(a, q, depth + 1) && vc_is_known_non_positive(b, q, depth + 1);
    }
    return kb_is_non_positive(known_bits(v, q));
}

// foldReduceAddCmpZero
vc_fold_reduce_add_cmp_zero :: (i: Value_Id) -> bool {
    if !vc_is_op(i, .ICMP) || !pm_zero(op(i, 1)) return false;
    pred := inst(i).pred;
    red := op(i, 0);
    if !value_has_one_use(red) || vc_iid(red) != IID_VECTOR_REDUCE_ADD return false;
    vec := call_arg(red, 0);
    vec_ty := vtype(vec);
    if !vc_is_fixed_vec(vec_ty) || type_count(vec_ty) < 2 return false;
    q := sq_with_instruction(vc.sq, i);
    non_neg := is_known_non_negative(vec, q);
    non_pos := !non_neg && vc_is_known_non_positive(vec, q);
    if !non_neg && !non_pos return false;
    ne := type_count(vec_ty);
    sign_bits := num_sign_bits_ctx(vec, i, vc.dt, vc.sq.ac);
    log2: u32 = 0; while ((cast(u64) 1) << (log2 + 1)) <= ne log2 += 1;   // Log2_32
    if log2 >= sign_bits return false;
    new_pred: u8;
    if pred == ICMP_EQ || pred == ICMP_ULE || pred == ICMP_SLE || pred == ICMP_SGE new_pred = ICMP_EQ;
    else if pred == ICMP_NE || pred == ICMP_UGT || pred == ICMP_SGT || pred == ICMP_SLT new_pred = ICMP_NE;
    else return false;
    if !non_neg && (pred == ICMP_SGT || pred == ICMP_SLE) return false;
    if !non_pos && (pred == ICMP_SLT || pred == ICMP_SGE) return false;
    if (pred == ICMP_SGT || pred == ICMP_SLE || pred == ICMP_SLT || pred == ICMP_SGE) && log2 >= sign_bits - 1 return false;
    orig := tti_arithmetic_reduction_cost(vc.tti, .ADD, vec_ty, false, 0, vc.kind);
    orc := tti_arithmetic_reduction_cost(vc.tti, .OR, vec_ty, false, 0, vc.kind);
    umc := tti_min_max_reduction_cost(vc.tti, IID_UMAX, vec_ty, 0, vc.kind);
    if !cost_valid(orc) && !cost_valid(umc) return false;
    use_or := cost_valid(orc) && (!cost_valid(umc) || orc <= umc);
    altc := ifx use_or then orc else umc;
    if altc > orig return false;
    irb_set_before(*vc.b, i);
    nr := vcb_intrinsic_tys(ifx use_or then IID_VECTOR_REDUCE_OR else IID_VECTOR_REDUCE_UMAX, .[vec_ty], .[vec]);
    vc_push_value(nr);
    nc := vcb_cmp(new_pred, nr, const_null_value(type_elem(vec_ty)));
    vc_replace_value(i, nc);
    return true;
}

// ---------------------------------------------------------------- foldSelectShuffle

// feedsIntoVectorReduction
vc_feeds_into_vector_reduction :: (svi: Value_Id) -> bool {
    visited: [..] Value_Id; visited.allocator = temp;
    wl: [..] Value_Id; wl.allocator = temp;
    found := false;
    array_add(*wl, svi);
    while wl.count {
        x := pop(*wl);
        u := ir.v_first_use[x];
        while u != NONE {
            ui := ir.u_user[u];
            u = ir.u_next[u];
            seen := false; for visited if it == ui { seen = true; break; }
            if seen continue;
            array_add(*visited, ui);
            if visited.count > 32 return false;
            id := vc_iid(ui);
            if id != NOT_INTRINSIC {
                if found return false;
                if vc_is_lane_invariant_reduction(id) { found = true; continue; }
                return false;
            }
            if !vc_is_binop(ui) && !vc_is_op(ui, .SHUFFLEVECTOR) return false;
            array_add(*wl, ui);
        }
    }
    return found;
}

// foldSelectShuffle(I, FromReduction)
vc_fold_select_shuffle :: (svi: Value_Id, from_reduction := false) -> bool {
    vt := vtype(svi);
    op0 := op(svi, 0); op1 := op(svi, 1);
    if !is_inst(op0) || !is_inst(op1) || op0 == op1 || !vc_is_binop(op0) || !vc_is_binop(op1) || vt != vtype(op0) return false;
    a0 := op(op0, 0); b0 := op(op0, 1); a1 := op(op1, 0); b1 := op(op1, 1);
    svi0a := ifx is_inst(a0) then a0 else NONE;
    svi0b := ifx is_inst(b0) then b0 else NONE;
    svi1a := ifx is_inst(a1) then a1 else NONE;
    svi1b := ifx is_inst(b1) then b1 else NONE;
    // SmallPtrSet<Instruction *, 4> InputShuffles({SVI0A, SVI0B, SVI1A, SVI1B}): small mode, insertion order
    inputs: [..] Value_Id; inputs.allocator = temp;
    for x: Value_Id.[svi0a, svi0b, svi1a, svi1b] {
        dup := false; for inputs if it == x dup = true;
        if !dup array_add(*inputs, x);
    }
    in_inputs :: (inputs: [] Value_Id, x: Value_Id) -> bool { for inputs if it == x return true; return false; }
    check_non_op_uses :: (x: Value_Id, vt: Type_Id, op0: Value_Id, op1: Value_Id, inputs: [] Value_Id) -> bool {
        if x == NONE || vtype(op(x, 0)) != vt return true;
        u := ir.v_first_use[x];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if usr != op0 && usr != op1 && !(vc_is_op(usr, .SHUFFLEVECTOR) && (in_inputs(inputs, usr) || is_instruction_trivially_dead_tli(usr, false)))
                return true;
        }
        return false;
    }
    if check_non_op_uses(svi0a, vt, op0, op1, inputs) || check_non_op_uses(svi0b, vt, op0, op1, inputs) ||
       check_non_op_uses(svi1a, vt, op0, op1, inputs) || check_non_op_uses(svi1b, vt, op0, op1, inputs) return false;
    shuffles: [..] Value_Id; shuffles.allocator = temp;
    collect :: (x: Value_Id, vt: Type_Id, op0: Value_Id, op1: Value_Id, shuffles: *[..] Value_Id) -> bool {
        u := ir.v_first_use[x];
        while u != NONE {
            sv := ir.u_user[u];
            u = ir.u_next[u];
            if !vc_is_op(sv, .SHUFFLEVECTOR) || vtype(sv) != vt return false;
            if (op(sv, 0) != op0 && op(sv, 0) != op1) || (op(sv, 1) != op0 && op(sv, 1) != op1) return false;
            dup := false; for shuffles.* if it == sv dup = true;
            if !dup array_add(shuffles, sv);
        }
        return true;
    }
    if !collect(op0, vt, op0, op1, *shuffles) || !collect(op1, vt, op0, op1, *shuffles) return false;
    if from_reduction && shuffles.count > 1 return false;
    if !from_reduction {
        e := shuffles.count;
        for k: 0..e-1 {
            u := ir.v_first_use[shuffles[k]];
            while u != NONE {
                ssv := ir.u_user[u];
                u = ir.u_next[u];
                if vc_is_op(ssv, .SHUFFLEVECTOR) && pm_undef_value(op(ssv, 1)) && vtype(ssv) == vt array_add(*shuffles, ssv);
            }
        }
    }
    Pair :: struct { first: s32; second: s32; }
    v1: [..] Pair; v1.allocator = temp;
    v2: [..] Pair; v2.allocator = temp;
    orig_masks: [..] [..] s32; orig_masks.allocator = temp;
    max_v1: s32 = 0; max_v2: s32 = 0;
    ne := cast(s32) type_count(vt);
    for svn: shuffles {
        mask := shuf_mask(svn);
        svop0 := op(svn, 0); svop1 := op(svn, 1);
        if pm_undef_value(svop1) {
            ssv := svop0;
            svop0 = op(ssv, 0); svop1 = op(ssv, 1);
            smask := shuffle_mask(ssv);
            for * mask {
                if it.* >= cast(s32) smask.count return false;
                if it.* >= 0 it.* = cast,no_check(s32) smask[it.*];
            }
        }
        if svop0 == op1 && svop1 == op0 {
            t := svop0; svop0 = svop1; svop1 = t;
            commute_shuffle_mask(*mask, ne);
        }
        if svop0 != op0 || svop1 != op1 return false;
        rm: [..] s32; rm.allocator = temp;
        for m: mask {
            if m < 0 { array_add(*rm, -1); continue; }
            if m < ne {
                max_v1 = max(max_v1, m);
                pos := -1; for v1 if it.first == m { pos = it_index; break; }
                if pos >= 0 array_add(*rm, cast(s32) pos);
                else { array_add(*rm, cast(s32) v1.count); array_add(*v1, .{m, cast(s32) v1.count}); }
            } else {
                max_v2 = max(max_v2, m - ne);
                pos := -1; for v2 if it.first == m - ne { pos = it_index; break; }
                if pos >= 0 array_add(*rm, ne + cast(s32) pos);
                else { array_add(*rm, ne + cast(s32) v2.count); array_add(*v2, .{m - ne, ne + cast(s32) v2.count}); }
            }
        }
        if from_reduction {
            for a: 1..rm.count-1 { x := rm[a]; j := a - 1; while j >= 0 && rm[j] > x { rm[j + 1] = rm[j]; j -= 1; } rm[j + 1] = x; }
        }
        array_add(*orig_masks, rm);
    }
    if v1.count == 0 || v2.count == 0 || (max_v1 == cast(s32) v1.count - 1 && max_v2 == cast(s32) v2.count - 1) return false;
    base_mask_value :: (x: Value_Id, m: s32, inputs: [] Value_Id) -> s32 {
        if !vc_is_op(x, .SHUFFLEVECTOR) return m;
        sm := shuffle_mask(x);
        if pm_undef_value(op(x, 1)) {
            ssv := op(x, 0);
            if vc_is_op(ssv, .SHUFFLEVECTOR) && in_inputs(inputs, ssv) return cast,no_check(s32) shuffle_mask(ssv)[cast,no_check(s32) sm[m]];
        }
        return cast,no_check(s32) sm[m];
    }
    // stable_sort(V1/V2) by the base mask value of SVI0A / SVI1A
    sort_pairs :: (v: *[..] Pair, a: Value_Id, inputs: [] Value_Id) {
        for k: 1..v.count-1 {
            x := v.*[k]; kx := base_mask_value(a, x.first, inputs);
            j := k - 1;
            while j >= 0 && base_mask_value(a, v.*[j].first, inputs) > kx { v.*[j + 1] = v.*[j]; j -= 1; }
            v.*[j + 1] = x;
        }
    }
    sort_pairs(*v1, svi0a, inputs);
    sort_pairs(*v2, svi1a, inputs);
    find_index :: (v: [] Pair, m: s32) -> s32 { for v if it.second == m return cast(s32) it_index; return -1; }
    rmasks: [..] [..] s32; rmasks.allocator = temp;
    for om: orig_masks {
        rm: [..] s32; rm.allocator = temp;
        for m: om {
            if m < 0 array_add(*rm, -1);
            else if m < ne array_add(*rm, find_index(v1, m));
            else array_add(*rm, ne + find_index(v2, m));
        }
        array_add(*rmasks, rm);
    }
    v1a: [..] s32; v1a.allocator = temp; v1b: [..] s32; v1b.allocator = temp;
    v2a: [..] s32; v2a.allocator = temp; v2b: [..] s32; v2b.allocator = temp;
    for v1 { array_add(*v1a, base_mask_value(svi0a, it.first, inputs)); array_add(*v1b, base_mask_value(svi0b, it.first, inputs)); }
    for v2 { array_add(*v2a, base_mask_value(svi1a, it.first, inputs)); array_add(*v2b, base_mask_value(svi1b, it.first, inputs)); }
    while v1a.count < ne { array_add(*v1a, -1); array_add(*v1b, -1); }
    while v2a.count < ne { array_add(*v2a, -1); array_add(*v2b, -1); }
    add_shuffle_cost :: (c: Cost, x: Value_Id, vt: Type_Id) -> Cost {
        if !vc_is_op(x, .SHUFFLEVECTOR) return c;
        sk := ifx pm_undef_value(op(x, 1)) then SK_PERMUTE_SINGLE_SRC else SK_PERMUTE_TWO_SRC;
        return cost_add(c, tti_shuffle_cost(vc.tti, sk, vt, vt, shuf_mask(x), vc.kind, 0, NONE, .[], NONE));
    }
    add_mask_cost :: (c: Cost, m: [] s32, vt: Type_Id) -> Cost {
        return cost_add(c, tti_shuffle_cost(vc.tti, SK_PERMUTE_TWO_SRC, vt, vt, m, vc.kind, 0, NONE, .[], NONE));
    }
    esize := vc_prim_bits(type_elem(vt));
    maxv := tti_register_bit_width(vc.tti, RGK_FIXED_WIDTH_VECTOR);
    max_elts := cast(s64) (maxv / esize);
    if max_elts == 0 return false;
    unique: [..] [..] s32; unique.allocator = temp;   // std::set<SmallVector<int, 4>>
    add_mask_adjusted :: (c: Cost, m: [] s32, vt: Type_Id, max_elts: s64, unique: *[..] [..] s32) -> Cost {
        sc := tti_shuffle_cost(vc.tti, SK_PERMUTE_TWO_SRC, vt, vt, m, vc.kind, 0, NONE, .[], NONE);
        nfull := m.count / max_elts;
        if nfull < 2 return cost_add(c, sc);
        nunique: Cost = 0;
        ngroups := m.count / max_elts;
        for g: 0..nfull-1 {
            sub: [..] s32; sub.allocator = temp;
            for j: 0..max_elts-1 array_add(*sub, m[max_elts * g + j]);
            found := false;
            for unique.* if vc_masks_equal(it, sub) { found = true; break; }
            if !found { array_add(unique, sub); nunique += 1; }
        }
        if !cost_valid(sc) return COST_INVALID;
        return cost_add(c, sc * nunique / ngroups);
    }
    same_operands := false;
    if inputs.count >= 2 && vc_is_op(inputs[0], .SHUFFLEVECTOR) {
        in0 := op(inputs[0], 0); in1 := op(inputs[0], 1);
        same_operands = true;
        for k: 1..inputs.count-1 {
            x := inputs[k];
            if !vc_is_op(x, .SHUFFLEVECTOR) || op(x, 0) != in0 || op(x, 1) != in1 { same_operands = false; break; }
        }
    }
    before := cost_add(tti_arith_cost(vc.tti, inst_op(op0), vt, vc.kind), tti_arith_cost(vc.tti, inst_op(op1), vt, vc.kind));
    for shuffles before = add_shuffle_cost(before, it, vt);
    if same_operands {
        array_reset_keeping_memory(*unique);
        for x: inputs if vc_is_op(x, .SHUFFLEVECTOR) before = add_mask_adjusted(before, shuf_mask(x), vt, max_elts, *unique);
    } else {
        for inputs before = add_shuffle_cost(before, it, vt);
    }
    op0_small := type_vector(cast(u64) v1.count, type_elem(vt), false);
    op1_small := type_vector(cast(u64) v2.count, type_elem(vt), false);
    after := cost_add(tti_arith_cost(vc.tti, inst_op(op0), op0_small, vc.kind), tti_arith_cost(vc.tti, inst_op(op1), op1_small, vc.kind));
    array_reset_keeping_memory(*unique);
    for rmasks after = add_mask_adjusted(after, it, vt, max_elts, *unique);
    outs: [..] [..] s32; outs.allocator = temp;   // std::set of the four input masks (duplicates dropped)
    for m: [..] s32.[v1a, v1b, v2a, v2b] {
        dup := false; for outs if vc_masks_equal(it, m) { dup = true; break; }
        if !dup array_add(*outs, m);
    }
    for outs after = add_mask_cost(after, it, vt);
    if before < after || (before == after && !vc_feeds_into_vector_reduction(svi)) return false;
    shuffle_operand :: (x: Value_Id, k: u32, inputs: [] Value_Id) -> Value_Id {
        if !vc_is_op(x, .SHUFFLEVECTOR) return x;
        if pm_undef_value(op(x, 1)) {
            ssv := op(x, 0);
            if vc_is_op(ssv, .SHUFFLEVECTOR) && in_inputs(inputs, ssv) return op(ssv, k);
        }
        return op(x, k);
    }
    set_after_def :: (x: Value_Id) {
        pt, bb, head := inst_insertion_point_after_def(x);
        if bb == NONE || pt == NONE fatal("internal: vector-combine: getInsertionPointAfterDef has no insertion point");
        irb_set_at(*vc.b, bb, pt, head);
    }
    set_after_def(svi0a);
    nsv0a := vcb_shuffle(shuffle_operand(svi0a, 0, inputs), shuffle_operand(svi0a, 1, inputs), v1a);
    set_after_def(svi0b);
    nsv0b := vcb_shuffle(shuffle_operand(svi0b, 0, inputs), shuffle_operand(svi0b, 1, inputs), v1b);
    set_after_def(svi1a);
    nsv1a := vcb_shuffle(shuffle_operand(svi1a, 0, inputs), shuffle_operand(svi1a, 1, inputs), v2a);
    set_after_def(svi1b);
    nsv1b := vcb_shuffle(shuffle_operand(svi1b, 0, inputs), shuffle_operand(svi1b, 1, inputs), v2b);
    irb_set_before(*vc.b, op0);
    nop0 := vcb_binop(inst_op(op0), nsv0a, nsv0b);
    if is_inst(nop0) copy_ir_flags(nop0, op0);
    irb_set_before(*vc.b, op1);
    nop1 := vcb_binop(inst_op(op1), nsv1a, nsv1b);
    if is_inst(nop1) copy_ir_flags(nop1, op1);
    for s: 0..rmasks.count-1 {
        irb_set_before(*vc.b, shuffles[s]);
        nsv := vcb_shuffle(nop0, nop1, rmasks[s]);
        vc_replace_value(shuffles[s], nsv, false);
    }
    vc_push_value(nsv0a);
    vc_push_value(nsv0b);
    vc_push_value(nsv1a);
    vc_push_value(nsv1b);
    return true;
}

// ---------------------------------------------------------------- shrinkType

vc_shrink_type :: (i: Value_Id) -> bool {
    zexted: Value_Id = NONE; other: Value_Id = NONE;
    o := inst_op(i);
    if is_bitwise_logic_op(o) {
        if vc_is_op(op(i, 0), .ZEXT) { zexted = op(op(i, 0), 0); other = op(i, 1); }
        else if vc_is_op(op(i, 1), .ZEXT) { zexted = op(op(i, 1), 0); other = op(i, 0); }
    }
    if zexted == NONE && o == .LSHR && vc_is_op(op(i, 0), .ZEXT) { zexted = op(op(i, 0), 0); other = op(i, 1); }
    if zexted == NONE return false;
    zext_operand := op(i, ifx op(i, 0) == other then cast(u32) 1 else 0);
    big_ty := vtype(i); small_ty := vtype(zexted);
    bw := cast(u32) vc_prim_bits(type_elem(small_ty));
    q: Simplify_Query;   // computeKnownBits(V, DL): no context
    if o == .LSHR {
        sh := known_bits(op(i, 1), q);
        if ap_uge_u64(kb_max_value(sh), bw) return false;
    } else {
        kb := known_bits(i, q);
        if kb_count_max_active_bits(kb) > bw return false;
    }
    zext_cost := tti_cast_cost(vc.tti, .ZEXT, big_ty, small_ty, CCH_NONE, vc.kind);
    current := zext_cost;
    shrink: Cost = 0;
    u := ir.v_first_use[zext_operand];
    while u != NONE {
        ui := ir.u_user[u];
        u = ir.u_next[u];
        if ui == i {
            current = cost_add(current, tti_arith_cost(vc.tti, inst_op(ui), big_ty, vc.kind));
            shrink = cost_add(cost_add(shrink, tti_arith_cost(vc.tti, inst_op(ui), small_ty, vc.kind)), zext_cost);
            continue;
        }
        if !is_binary_op(inst_op(ui)) return false;
        kb := known_bits(ui, q);
        if kb_count_max_active_bits(kb) > bw return false;
        current = cost_add(current, tti_arith_cost(vc.tti, inst_op(ui), big_ty, vc.kind));
        shrink = cost_add(cost_add(shrink, tti_arith_cost(vc.tti, inst_op(ui), small_ty, vc.kind)), zext_cost);
    }
    if !is_const(other) shrink = cost_add(shrink, tti_cast_cost(vc.tti, .TRUNC, small_ty, big_ty, CCH_NONE, vc.kind));
    if shrink > current return false;
    irb_set_before(*vc.b, i);
    o0 := zexted;
    o1 := vcb_cast(.TRUNC, other, small_ty);
    if op(i, 0) == other { t := o0; o0 = o1; o1 = t; }
    nb := vcb_binop(o, o0, o1);
    if is_inst(nb) { copy_ir_flags(nb, i); copy_metadata(nb, i); }
    nz := vcb_cast(.ZEXT, nb, big_ty);
    vc_replace_value(i, nz);
    return true;
}

// ---------------------------------------------------------------- interleave / deinterleave / VP / bit order

IID_VP_LOAD :: #run iid_by_name("llvm.vp.load");

// foldInterleaveIntrinsics
vc_fold_interleave_intrinsics :: (i: Value_Id) -> bool {
    if vc_iid(i) != IID_VECTOR_INTERLEAVE2 return false;
    ok0, s0 := pm_apint(call_arg(i, 0));
    if !ok0 return false;
    ok1, s1 := pm_apint(call_arg(i, 1));
    if !ok1 return false;
    vty := vtype(call_arg(i, 0));
    width := type_int_width(type_elem(vty));
    ext_ty := vector_with_elt(vty, type_int(width * 2));
    if tti_instruction_cost(vc.tti, i, vc.kind) <= tti_cast_cost(vc.tti, .BITCAST, vtype(i), ext_ty, CCH_NONE, vc.kind) return false;
    nv := ap_or(ap_shl(ap_zext(s1, width * 2), width), ap_zext(s0, width * 2));
    splat := cf_get_splat(ext_ty, const_int_ap(type_int(width * 2), nv));
    b: Irb;
    irb_set_before(*b, i);
    vc_replace_value(i, irb_bitcast(*b, splat, vtype(i)));
    return true;
}

// foldDeinterleaveIntrinsics
vc_fold_deinterleave_intrinsics :: (i: Value_Id) -> bool {
    if dl.big_endian return false;
    if vc_iid(i) != IID_VECTOR_DEINTERLEAVE2 return false;
    dv := call_arg(i, 0);
    vec_ty := vtype(dv);
    elt := type_elem(vec_ty);
    if !is_int_type(elt) return false;
    ew := type_int_width(elt);
    if ew < 2 || (ew & (ew - 1)) != 0 return false;
    half := ew / 2;
    if !has_n_uses(i, 2) return false;
    fields: [2] Value_Id; fields[0] = NONE; fields[1] = NONE;
    u := ir.v_first_use[i];
    while u != NONE {
        e := ir.u_user[u];
        u = ir.u_next[u];
        if !vc_is_op(e, .EXTRACTVALUE) || inst(e).nidx != 1 return false;
        idx := ir.u32_pool[inst(e).idx];
        if idx >= 2 || fields[idx] != NONE || !has_n_uses(e, 2) return false;
        fields[idx] = e;
    }
    merges: [..] Value_Id; merges.allocator = temp;
    u = ir.v_first_use[fields[0]];
    while u != NONE {
        fu := ir.u_user[u];
        u = ir.u_next[u];
        if !value_has_one_use(fu) || !is_inst(first_user(fu)) return false;
        array_add(*merges, first_user(fu));
    }
    match_merge :: (m0: Value_Id, m1: Value_Id, f0: Value_Id, f1: Value_Id, ew: u32, half: u32) -> bool {
        lo := ap_low_bits_set(ew, half);
        hi := ap_shl(ap_low_bits_set(ew, half), ew - half);
        // m_c_Or(m_And(m_Specific(A), m_SpecificInt(M)), m_<Shift>(m_Specific(B), m_SpecificInt(Half)))
        side :: (v: Value_Id, a: Value_Id, mask: APInt, b: Value_Id, sh: Opcode, half: u32) -> bool {
            if opr_code(v) != .OR return false;
            for s: 0..1 {
                x := op(v, cast(u32) s); y := op(v, cast(u32) (1 - s));
                if opr_code(x) == .AND && op(x, 0) == a && pm_specific_int_ap(op(x, 1), mask) &&
                   opr_code(y) == sh && op(y, 0) == b && pm_specific_int(op(y, 1), half) return true;
            }
            return false;
        }
        return side(m0, f0, lo, f1, .SHL, half) && side(m1, f1, hi, f0, .LSHR, half);
    }
    if !match_merge(merges[0], merges[1], fields[0], fields[1], ew, half) {
        t := merges[0]; merges[0] = merges[1]; merges[1] = t;
        if !match_merge(merges[0], merges[1], fields[0], fields[1], ew, half) return false;
    }
    old := cost_add(cost_add(tti_instruction_cost(vc.tti, merges[0], vc.kind), tti_instruction_cost(vc.tti, op(merges[0], 0), vc.kind)),
                    tti_instruction_cost(vc.tti, op(merges[0], 1), vc.kind));
    old = cost_mul(old, 2);
    field_ty := vector_with_elt(vec_ty, type_int(half));
    new_vec_ty := type_vector(type_count(field_ty) * 2, type_int(half), type_kind(field_ty) == .SVECTOR);
    new := cost_add(tti_cast_cost(vc.tti, .BITCAST, vec_ty, new_vec_ty, CCH_NONE, vc.kind),
                    cost_mul(tti_cast_cost(vc.tti, .BITCAST, field_ty, vtype(merges[0]), CCH_NONE, vc.kind), 2));
    if old <= new || !cost_valid(new) return false;
    b: Irb;
    irb_set_before(*b, i);
    nvc := irb_bitcast(*b, dv, new_vec_ty);
    nd := irb_intrinsic(*b, "llvm.vector.deinterleave2", .[new_vec_ty], .[nvc]);
    for m: merges {
        nf := irb_extract_value(*b, nd, .[cast(u32) it_index]);
        nf = irb_bitcast(*b, nf, vtype(m));
        vc_replace_value(m, nf);
    }
    return true;
}

// foldBitcastOfVPLoad (only the matching: rewriting VP loads is not ported)
vc_fold_bitcast_of_vp_load :: (i: Value_Id) -> bool {
    if !vc_is_cast(i) || !is_vector_type(vtype(i)) return false;
    ii := op(i, 0);
    if vc_iid(ii) != IID_VP_LOAD || !value_has_one_use(ii) || !pm_all_ones(call_arg(ii, 1)) return false;
    fatal("vector-combine: folding bitcasts of llvm.vp.load is not supported yet");
    return false;
}

// foldBitOrderReverseAndSwap
vc_fold_bit_order_reverse_and_swap :: (i: Value_Id) -> bool {
    id := vc_iid(i);
    if id != IID_BITREVERSE && id != IID_BSWAP return false;
    inner := call_arg(i, 0);
    want: Intrinsic_Id = ifx id == IID_BITREVERSE then IID_BSWAP else IID_BITREVERSE;
    if vc_iid(inner) != want return false;
    x := call_arg(inner, 0);
    ty := vtype(i);
    es := dl_type_store_size(ty);
    new_vec_ty := type_vector(es, ir.t_i8, type_kind(ty) == .SVECTOR);
    old := cost_add(tti_instruction_cost(vc.tti, i, vc.kind), tti_instruction_cost(vc.tti, inner, vc.kind));
    to_vec := tti_cast_cost(vc.tti, .BITCAST, new_vec_ty, ty, CCH_NONE, vc.kind);
    to_orig := tti_cast_cost(vc.tti, .BITCAST, ty, new_vec_ty, CCH_NONE, vc.kind);
    ica := ica_types(IID_BITREVERSE, new_vec_ty, .[new_vec_ty]);
    new := cost_add(cost_add(to_vec, tti_intrinsic_cost(vc.tti, *ica, vc.kind)), to_orig);
    if !value_has_one_use(inner) new = cost_add(new, tti_instruction_cost(vc.tti, inner, vc.kind));
    if !cost_valid(new) || new >= old return false;
    irb_set_before(*vc.b, i);
    cv := vcb_cast(.BITCAST, x, new_vec_ty);
    // CreateUnaryIntrinsic: the declaration first, then FoldIntrinsic
    get_or_insert_intrinsic_declaration(IID_BITREVERSE, .[vtype(cv)]);
    nc := vcb_intrinsic_tys(IID_BITREVERSE, .[vtype(cv)], .[cv]);
    co := vcb_cast(.BITCAST, nc, ty);
    vc_replace_value(i, co);
    return true;
}

// ---------------------------------------------------------------- shrinking loads and phis

// shrinkLoadForShuffles
vc_shrink_load_for_shuffles :: (i: Value_Id) -> bool {
    if inst_op(i) != .LOAD || !is_simple_load_store(i) return false;
    old_ty := vtype(i);
    if !vc_is_fixed_vec(old_ty) return false;
    old_n := cast(s32) type_count(old_ty);
    lo := old_n; hi: s32 = -1;
    u := ir.v_first_use[i];
    while u != NONE {
        sh := ir.u_user[u];
        u = ir.u_next[u];
        if !vc_is_op(sh, .SHUFFLEVECTOR) || op(sh, 0) != i || !pm_undef(op(sh, 1)) return false;
        if !has_uses(sh) continue;
        for shuf_mask(sh) if it >= 0 && it < old_n { lo = min(it, lo); hi = max(it, hi); }
    }
    if hi < lo return false;
    new_n := hi + 1;
    if new_n >= old_n return false;
    b: Irb;
    irb_set_before(*b, i);
    elem := type_elem(old_ty);
    new_ty := type_vector(cast(u64) new_n, elem, false);
    ptr := op(i, 0);
    as := vc_as(ptr);
    old := tti_memory_op_cost(vc.tti, .LOAD, old_ty, inst(i).align, as, vc.kind);
    new := tti_memory_op_cost(vc.tti, .LOAD, new_ty, inst(i).align, as, vc.kind);
    uses: [..] Value_Id; uses.allocator = temp;
    max_index := new_n * 2;
    u = ir.v_first_use[i];
    while u != NONE {
        sh := ir.u_user[u];
        u = ir.u_next[u];
        if !has_uses(sh) continue;
        m := shuf_mask(sh);
        array_add(*uses, sh);
        for m if it >= max_index return false;
        old = cost_add(old, tti_shuffle_cost(vc.tti, SK_PERMUTE_SINGLE_SRC, vtype(sh), old_ty, m, vc.kind, 0, NONE, .[], NONE));
        new = cost_add(new, tti_shuffle_cost(vc.tti, SK_PERMUTE_SINGLE_SRC, vtype(sh), new_ty, m, vc.kind, 0, NONE, .[], NONE));
    }
    if old < new || !cost_valid(new) return false;
    nl := irb_load(*b, new_ty, ptr, inst(i).align);
    copy_metadata(nl, i);
    for sh: uses {
        irb_set_before(*b, sh);
        ns := irb_shuffle(*b, nl, const_poison(new_ty), mask_to_u32(shuf_mask(sh)));
        vc_replace_value(sh, ns, false);
    }
    return true;
}

// shrinkPhiOfShuffles
vc_shrink_phi_of_shuffles :: (i: Value_Id) -> bool {
    if inst_op(i) != .PHI || nops(i) != 2 return false;
    s0 := op(i, 0); s1 := op(i, 1);
    if !value_has_one_use(s0) || !vc_is_op(s0, .SHUFFLEVECTOR) || !pm_poison(op(s0, 1)) return false;
    x := op(s0, 0);
    if !value_has_one_use(s1) || !vc_is_op(s1, .SHUFFLEVECTOR) || op(s1, 0) != x || !pm_poison(op(s1, 1)) return false;
    mask0 := shuf_mask(s0); mask1 := shuf_mask(s1);
    in_ty := vtype(x); res_ty := vtype(s0);
    in_n := cast(s64) type_count(in_ty);
    if in_n >= cast(s64) type_count(res_ty) return false;
    nm: [..] s32; nm.allocator = temp;
    for k: 0..min(mask0.count, mask1.count)-1 {
        m0 := mask0[k]; m1 := mask1[k];
        if m0 >= 0 && m1 >= 0 array_add(*nm, m0 - m1);
        else if m0 == -1 && m1 == -1 continue;
        else return false;
    }
    if nm.count == 0 return false;
    for nm if it != nm[0] return false;
    off := cast(s64) nm[0];
    index := (in_n + off) % in_n;
    array_reset_keeping_memory(*nm);
    for k: 0..in_n-1 { array_add(*nm, cast(s32) index); index = (index + 1) % in_n; }
    old := cost_max(tti_shuffle_cost(vc.tti, SK_PERMUTE_SINGLE_SRC, res_ty, in_ty, mask0, vc.kind, 0, NONE, .[], NONE),
                    tti_shuffle_cost(vc.tti, SK_PERMUTE_SINGLE_SRC, res_ty, in_ty, mask1, vc.kind, 0, NONE, .[], NONE));
    new := cost_add(tti_shuffle_cost(vc.tti, SK_PERMUTE_SINGLE_SRC, in_ty, in_ty, nm, vc.kind, 0, NONE, .[], NONE),
                    tti_shuffle_cost(vc.tti, SK_PERMUTE_SINGLE_SRC, res_ty, in_ty, mask1, vc.kind, 0, NONE, .[], NONE));
    if new > old return false;
    b: Irb;
    irb_set_before(*b, s0);
    ns0 := irb_shuffle(*b, x, const_poison(in_ty), mask_to_u32(nm));
    vc_push(ns0);
    irb_set_before(*b, i);
    np := irb_phi(*b, vtype(ns0), 2);
    phi_add_incoming(np, ns0, ir.u_aux[op_use(i, 0)]);
    phi_add_incoming(np, x, ir.u_aux[op_use(i, 1)]);
    pt, bb, head := inst_insertion_point_after_def(np);
    irb_set_at(*b, bb, pt, head);
    ns1 := irb_shuffle(*b, np, const_poison(vtype(np)), mask_to_u32(mask1));
    vc_replace_value(i, ns1);
    return true;
}

// ---------------------------------------------------------------- the driver

vc_fold_inst :: (i: Value_Id) -> bool {
    irb_set_before(*vc.b, i);
    ty := vtype(i);
    is_vec := is_vector_type(ty);
    is_fixed := vc_is_fixed_vec(ty);
    o := inst_op(i);
    if is_fixed {
        if o == .INSERTELEMENT { if vc_vectorize_load_insert(i) return true; }
        else if o == .SHUFFLEVECTOR { if vc_widen_subvector_load(i) return true; }
    }
    if is_vec {
        if vc_scalarize_op_or_cmp(i) return true;
        if vc_scalarize_load(i) return true;
        if vc_scalarize_ext_extract(i) return true;
        if vc_scalarize_vp_intrinsic(i) return true;
        if vc_fold_interleave_intrinsics(i) return true;
        if vc_fold_bitcast_of_vp_load(i) return true;
    }
    if vc_fold_deinterleave_intrinsics(i) return true;
    if o == .STORE && vc_fold_single_element_store(i) return true;
    if vc.early_only return false;
    if o == .CALL && vc_fold_bit_order_reverse_and_swap(i) return true;
    if is_fixed {
        if o == {
            case .INSERTELEMENT;
                if vc_fold_ins_ext_fneg(i) return true;
                if vc_fold_ins_ext_binop(i) return true;
                if vc_fold_ins_ext_vector_to_shuffle(i) return true;
            case .SHUFFLEVECTOR;
                if vc_fold_permute_of_binops(i) return true;
                if vc_fold_shuffle_of_binops(i) return true;
                if vc_fold_shuffle_of_selects(i) return true;
                if vc_fold_shuffle_of_castops(i) return true;
                if vc_fold_shuffle_of_shuffles(i) return true;
                if vc_fold_permute_of_intrinsic(i) return true;
                if vc_fold_shuffles_of_length_changing_shuffles(i) return true;
                if vc_fold_shuffle_of_intrinsics(i) return true;
                if vc_fold_select_shuffle(i) return true;
                if vc_fold_shuffle_to_identity(i) return true;
            case .LOAD;
                if vc_shrink_load_for_shuffles(i) return true;
            case .BITCAST;
                if vc_fold_bitcast_shuffle(i) return true;
                if vc_fold_selects_from_bitcast(i) return true;
            case .AND; #through;
            case .OR; #through;
            case .XOR;
                if vc_fold_bit_op_of_castops(i) return true;
                if vc_fold_bit_op_of_cast_constant(i) return true;
            case .PHI;
                if vc_shrink_phi_of_shuffles(i) return true;
            case;
                if vc_shrink_type(i) return true;
        }
    } else {
        if o == .CALL {
            if vc_fold_shuffle_from_reductions(i) return true;
            if vc_fold_cast_from_reductions(i) return true;
        } else if o == .EXTRACTELEMENT {
            if vc_fold_shuffle_chains_to_reduce(i) return true;
        } else if o == .ICMP || o == .FCMP {
            if o == .ICMP {
                if vc_fold_sign_bit_reduction_cmp(i) return true;
                if vc_fold_icmp_eq_zero_vector_reduce(i) return true;
                if vc_fold_reduction_zero_test(i) return true;
                if vc_fold_equivalent_reduction_cmp(i) return true;
                if vc_fold_reduce_add_cmp_zero(i) return true;
            }
            if vc_fold_extract_extract(i) return true;
        } else {
            if o == .OR && vc_fold_concat_of_bool_masks(i) return true;
            if is_binary_op(o) {
                if vc_fold_extract_extract(i) return true;
                if vc_fold_extracted_cmps(i) return true;
                if vc_fold_binop_of_reductions(i) return true;
            }
        }
    }
    return false;
}

// VectorCombine::run
vc_run :: () -> bool {
    if vc_cl.disable return false;
    if tti_number_of_registers(vc.tti, tti_register_class_for_type(vc.tti, true)) == 0 return false;
    changed := false;
    for bb: fn_blocks(vc.f) {
        if !dt_is_reachable_from_entry(vc.dt, bb) continue;
        x := block_first(bb);
        while x != NONE {
            vc.next_inst = inst(x).next;
            if !is_debug_or_pseudo_inst(x) changed |= vc_fold_inst(x);
            x = vc.next_inst;
        }
    }
    vc.next_inst = NONE;
    while vc.wl.count {
        x := vc_remove_one();
        if x == NONE continue;
        if is_instruction_trivially_dead_tli(x, false) { vc_erase_instruction(x); continue; }
        changed |= vc_fold_inst(x);
    }
    return changed;
}

// VectorCombinePass::run (TryEarlyFoldsOnly = false: the PassRegistry's "vector-combine")
vector_combine_run :: (f: Value_Id) -> Preserved {
    ac := get_assumption_cache(f);
    tti := tti_get(f);
    dt := get_domtree(f);
    aar := aa_results_for(f);
    vc = .{};
    vc.f = f; vc.tti = tti; vc.dt = dt; vc.ac = ac; vc.aar = aar;
    vc.kind = ifx fn_has_opt_size(f) then TCK_CODE_SIZE else TCK_RECIP_THROUGHPUT;
    vc.sq.dt = dt; vc.sq.ac = ac; vc.sq.have_tli = false; vc.sq.no_tli_libcalls = true;
    vc.early_only = false;
    vc.wl.allocator = temp;
    vc.wl_map.allocator = temp;
    if !vc_run() return PRESERVE_ALL;
    return preserved_cfg();
}
