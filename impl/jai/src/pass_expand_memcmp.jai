// ExpandMemCmpPass: a port of llvm/lib/Transforms/Scalar/ExpandMemCmp.cpp (LLVM 23.1.5): MemCmpExpansion (greedy
// and overlapping load sequences, optimiseLoadSequence, the one-block, zero-equality and multi-block expansions),
// expandMemCmp and runImpl, with X86TTIImpl::enableMemCmpExpansion (the default target has no expansion).
// cl::opts: -memcmp-num-loads-per-block, -max-loads-per-memcmp, -max-loads-per-memcmp-opt-size.

emc_opts: struct {
    num_loads_per_block: s64 = 1;      // -memcmp-num-loads-per-block
    num_loads_per_block_set: bool;
    max_loads: s64;                    // -max-loads-per-memcmp
    max_loads_set: bool;
    max_loads_opt_size: s64;           // -max-loads-per-memcmp-opt-size
    max_loads_opt_size_set: bool;
};

expand_memcmp_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    int_value :: (name: string, value: string, has_value: bool) -> s64 {
        v, ok := string_to_int(value);
        if !has_value || !ok fatal("invalid integer value '%' for option -%", value, name);
        return v;
    }
    if name == {
        case "memcmp-num-loads-per-block"; emc_opts.num_loads_per_block = int_value(name, value, has_value); emc_opts.num_loads_per_block_set = true; return true;
        case "max-loads-per-memcmp"; emc_opts.max_loads = int_value(name, value, has_value); emc_opts.max_loads_set = true; return true;
        case "max-loads-per-memcmp-opt-size"; emc_opts.max_loads_opt_size = int_value(name, value, has_value); emc_opts.max_loads_opt_size_set = true; return true;
    }
    return false;
}

// TTI::MemCmpExpansionOptions
Memcmp_Options :: struct {
    max_num_loads: u64;
    load_sizes: [..] u64;
    num_loads_per_block: u64 = 1;
    allow_overlapping_loads: bool;
    allowed_tail_expansions: [..] u64;
}

// X86TTIImpl::enableMemCmpExpansion (false: the target does not expand)
emc_enable_memcmp_expansion :: (t: *Tti, opt_size: bool, is_zero_cmp: bool) -> (bool, Memcmp_Options) {
    o: Memcmp_Options;
    o.load_sizes.allocator = temp; o.allowed_tail_expansions.allocator = temp;
    if t.kind != .X86 return false, o;
    st := *t.xl;
    o.max_num_loads = 2;   // X86TargetLowering: MaxLoadsPerMemcmp = MaxLoadsPerMemcmpOptSize = 2
    o.num_loads_per_block = 2;
    o.allow_overlapping_loads = true;
    if is_zero_cmp {
        pw := st.prefer_vector_width;
        if pw >= 512 && st_hasAVX512(st) array_add(*o.load_sizes, 64);
        if pw >= 256 && st_hasAVX(st) array_add(*o.load_sizes, 32);
        if pw >= 128 && st_hasSSE2(st) array_add(*o.load_sizes, 16);
    }
    if st_is64Bit(st) array_add(*o.load_sizes, 8);
    array_add(*o.load_sizes, 4);
    array_add(*o.load_sizes, 2);
    array_add(*o.load_sizes, 1);
    // MaxNumLoads == 0 means no expansion (the options convert to false)
    return o.max_num_loads != 0, o;
}

Emc_Load_Entry :: struct { load_size: u64; offset: u64; }

Memcmp_Expansion :: struct {
    ci: Value_Id;
    res_bb: Value_Id = NONE;
    phi_src1: Value_Id = NONE;
    phi_src2: Value_Id = NONE;
    size: u64;
    max_load_size: u64;
    num_loads_non_one_byte: u64;
    num_loads_per_block_for_zero_cmp: u64;
    load_cmp_blocks: [..] Value_Id;
    end_block: Value_Id = NONE;
    phi_res: Value_Id = NONE;
    is_used_for_zero_cmp: bool;
    dtu: *Dtu;
    b: Irb;
    load_sequence: [..] Emc_Load_Entry;
}

// computeGreedyLoadSequence
emc_greedy_load_sequence :: (size_in: u64, load_sizes_in: [] u64, max_num_loads: u64) -> ([..] Emc_Load_Entry, u64) {
    seq: [..] Emc_Load_Entry; seq.allocator = temp;
    non_one: u64 = 0;
    offset: u64 = 0;
    size := size_in;
    load_sizes := load_sizes_in;
    while size != 0 && load_sizes.count > 0 {
        ls := load_sizes[0];
        n := size / ls;
        if cast(u64) seq.count + n > max_num_loads { e: [..] Emc_Load_Entry; e.allocator = temp; return e, 0; }
        if n > 0 {
            for 1..n { array_add(*seq, .{ls, offset}); offset += ls; }
            if ls > 1 non_one += 1;
            size = size % ls;
        }
        load_sizes.data += 1; load_sizes.count -= 1;
    }
    return seq, non_one;
}

// computeOverlappingLoadSequence
emc_overlapping_load_sequence :: (size_in: u64, max_load_size: u64, max_num_loads: u64) -> ([..] Emc_Load_Entry, u64) {
    seq: [..] Emc_Load_Entry; seq.allocator = temp;
    if size_in < 2 || max_load_size < 2 return seq, 0;
    n := size_in / max_load_size;
    size := size_in - n * max_load_size;
    if size == 0 return seq, 0;
    if n + 1 > max_num_loads return seq, 0;
    offset: u64 = 0;
    for 1..n { array_add(*seq, .{max_load_size, offset}); offset += max_load_size; }
    array_add(*seq, .{max_load_size, offset - (max_load_size - size)});
    return seq, 1;
}

// optimiseLoadSequence (LLVM's emplace_back(PreLast.Offset, LoadSize) passes the fields swapped: reproduced)
emc_optimise_load_sequence :: (seq: *[..] Emc_Load_Entry, o: *Memcmp_Options, is_used_for_zero_cmp: bool) {
    if is_used_for_zero_cmp || o.allowed_tail_expansions.count == 0 return;
    while seq.count >= 2 {
        last := seq.*[seq.count - 1];
        pre_last := seq.*[seq.count - 2];
        if pre_last.offset + pre_last.load_size != last.offset break;
        ls := last.load_size + pre_last.load_size;
        found := false;
        for o.allowed_tail_expansions if it == ls { found = true; break; }
        if !found break;
        seq.count -= 2;
        array_add(seq, .{pre_last.offset, ls});
    }
}

emc_init :: (e: *Memcmp_Expansion, ci: Value_Id, size: u64, o: *Memcmp_Options, is_used_for_zero_cmp: bool, dtu: *Dtu) {
    e.ci = ci; e.size = size; e.num_loads_per_block_for_zero_cmp = o.num_loads_per_block;
    e.is_used_for_zero_cmp = is_used_for_zero_cmp; e.dtu = dtu;
    e.load_cmp_blocks.allocator = temp;
    irb_set_before(*e.b, ci);
    load_sizes: [] u64 = o.load_sizes;
    while load_sizes.count > 0 && load_sizes[0] > size { load_sizes.data += 1; load_sizes.count -= 1; }
    if load_sizes.count == 0 fatal("internal: expand-memcmp: cannot load Size bytes");
    e.max_load_size = load_sizes[0];
    seq, non_one := emc_greedy_load_sequence(size, load_sizes, o.max_num_loads);
    e.load_sequence = seq;
    e.num_loads_non_one_byte = non_one;
    if o.allow_overlapping_loads && (e.load_sequence.count == 0 || e.load_sequence.count > 2) {
        ov, ov_non_one := emc_overlapping_load_sequence(size, e.max_load_size, o.max_num_loads);
        if ov.count > 0 && (e.load_sequence.count == 0 || ov.count < e.load_sequence.count) {
            e.load_sequence = ov;
            e.num_loads_non_one_byte = ov_non_one;
        }
    }
    emc_optimise_load_sequence(*e.load_sequence, o, is_used_for_zero_cmp);
}

emc_num_loads :: (e: *Memcmp_Expansion) -> u64 { return cast(u64) e.load_sequence.count; }
emc_num_blocks :: (e: *Memcmp_Expansion) -> u64 {
    if e.is_used_for_zero_cmp {
        n := emc_num_loads(e);
        k := e.num_loads_per_block_for_zero_cmp;
        return n / k + (ifx n % k != 0 then cast(u64) 1 else 0);
    }
    return emc_num_loads(e);
}

emc_create_load_cmp_blocks :: (e: *Memcmp_Expansion) {
    f := block_fn(e.end_block);
    for 1..emc_num_blocks(e) array_add(*e.load_cmp_blocks, create_block(f, "loadbb", e.end_block));
}
emc_create_result_block :: (e: *Memcmp_Expansion) {
    e.res_bb = create_block(block_fn(e.end_block), "res_block", e.end_block);
}

emc_int_ty :: (bytes: u64) -> Type_Id { return type_int(cast(u32) (bytes * 8)); }

// getLoadPair: (Lhs, Rhs); bswap_ty / cmp_ty may be 0 (nullptr)
emc_get_load_pair :: (e: *Memcmp_Expansion, load_ty: Type_Id, bswap_ty: Type_Id, cmp_ty: Type_Id, offset: u64) -> (Value_Id, Value_Id) {
    b := *e.b;
    lsrc := call_arg(e.ci, 0);
    rsrc := call_arg(e.ci, 1);
    lalign := pointer_alignment(lsrc);
    ralign := pointer_alignment(rsrc);
    if offset > 0 {
        off := const_int(ir.t_i64, offset);
        lsrc = irb_gep(b, ir.t_i8, lsrc, .[off]);
        rsrc = irb_gep(b, ir.t_i8, rsrc, .[off]);
        lalign = common_alignment(lalign, offset);
        ralign = common_alignment(ralign, offset);
    }
    lhs: Value_Id = NONE;
    if is_const(lsrc) lhs = cfo_load_from_const_ptr(lsrc, load_ty);
    if lhs == NONE lhs = irb_load(b, load_ty, lsrc, lalign);
    rhs: Value_Id = NONE;
    if is_const(rsrc) rhs = cfo_load_from_const_ptr(rsrc, load_ty);
    if rhs == NONE rhs = irb_load(b, load_ty, rsrc, ralign);
    if bswap_ty != 0 && load_ty != bswap_ty {
        lhs = irb_cast(b, .ZEXT, lhs, bswap_ty);
        rhs = irb_cast(b, .ZEXT, rhs, bswap_ty);
    }
    if bswap_ty != 0 {
        bswap := get_or_insert_intrinsic_declaration(IID_BSWAP, .[bswap_ty]);
        lhs = irb_call(b, bswap, .[lhs]);
        rhs = irb_call(b, bswap, .[rhs]);
    }
    if cmp_ty != 0 && cmp_ty != vtype(lhs) {
        lhs = irb_cast(b, .ZEXT, lhs, cmp_ty);
        rhs = irb_cast(b, .ZEXT, rhs, cmp_ty);
    }
    return lhs, rhs;
}

emc_dtu :: (e: *Memcmp_Expansion, ups: [] Dom_Update) { if e.dtu dtu_apply(e.dtu, ups); }

// emitLoadCompareByteBlock
emc_emit_load_compare_byte_block :: (e: *Memcmp_Expansion, bi: s64, offset: u64) {
    bb := e.load_cmp_blocks[bi];
    irb_set_end(*e.b, bb);
    l, r := emc_get_load_pair(e, ir.t_i8, 0, ir.t_i32, offset);
    diff := irb_binop(*e.b, .SUB, l, r);
    phi_add_incoming(e.phi_res, diff, bb);
    if bi < e.load_cmp_blocks.count - 1 {
        cmp := irb_icmp(*e.b, ICMP_NE, diff, const_int(vtype(diff), 0));
        irb_cond_br(*e.b, cmp, e.end_block, e.load_cmp_blocks[bi + 1]);
        emc_dtu(e, .[.{true, bb, e.end_block}, .{true, bb, e.load_cmp_blocks[bi + 1]}]);
    } else {
        irb_br(*e.b, e.end_block);
        emc_dtu(e, .[.{true, bb, e.end_block}]);
    }
}

// getCompareLoadPairs
emc_get_compare_load_pairs :: (e: *Memcmp_Expansion, bi: s64, load_index: *u64) -> Value_Id {
    b := *e.b;
    xor_list: [..] Value_Id; xor_list.allocator = temp;
    diff: Value_Id = NONE;
    num_loads := min(emc_num_loads(e) - load_index.*, e.num_loads_per_block_for_zero_cmp);
    if e.load_cmp_blocks.count == 0 irb_set_before(b, e.ci);
    else irb_set_end(b, e.load_cmp_blocks[bi]);
    cmp: Value_Id = NONE;
    max_load_ty: Type_Id = ifx num_loads == 1 then cast(Type_Id) 0 else emc_int_ty(e.max_load_size);
    for 1..num_loads {
        le := e.load_sequence[load_index.*];
        l, r := emc_get_load_pair(e, emc_int_ty(le.load_size), 0, max_load_ty, le.offset);
        if num_loads != 1 {
            diff = irb_binop(b, .XOR, l, r);
            diff = irb_cast(b, .ZEXT, diff, max_load_ty);
            array_add(*xor_list, diff);
        } else {
            cmp = irb_icmp(b, ICMP_NE, l, r);
        }
        load_index.* += 1;
    }
    pair_wise_or :: (b: *Irb, in_list: [] Value_Id) -> [..] Value_Id {
        out: [..] Value_Id; out.allocator = temp;
        i := 0;
        while i < in_list.count - 1 { array_add(*out, irb_binop(b, .OR, in_list[i], in_list[i + 1])); i += 2; }
        if in_list.count % 2 != 0 array_add(*out, in_list[in_list.count - 1]);
        return out;
    }
    if cmp == NONE {
        or_list := pair_wise_or(b, xor_list);
        while or_list.count != 1 or_list = pair_wise_or(b, or_list);
        cmp = irb_icmp(b, ICMP_NE, or_list[0], const_int(vtype(diff), 0));
    }
    return cmp;
}

// emitLoadCompareBlockMultipleLoads
emc_emit_load_compare_block_multiple_loads :: (e: *Memcmp_Expansion, bi: s64, load_index: *u64) {
    cmp := emc_get_compare_load_pairs(e, bi, load_index);
    next_bb := ifx bi == e.load_cmp_blocks.count - 1 then e.end_block else e.load_cmp_blocks[bi + 1];
    bb := e.b.bb;
    br := irb_cond_br(*e.b, cmp, e.res_bb, next_bb);
    set_explicitly_unknown_branch_weights_if_profiled(br, "expand-memcmp");
    emc_dtu(e, .[.{true, bb, e.res_bb}, .{true, bb, next_bb}]);
    if bi == e.load_cmp_blocks.count - 1 phi_add_incoming(e.phi_res, const_int(ir.t_i32, 0), e.load_cmp_blocks[bi]);
}

// emitLoadCompareBlock
emc_emit_load_compare_block :: (e: *Memcmp_Expansion, bi: s64) {
    le := e.load_sequence[bi];
    if le.load_size == 1 { emc_emit_load_compare_byte_block(e, bi, le.offset); return; }
    load_ty := emc_int_ty(le.load_size);
    bswap_ty := type_int(cast(u32) power_of_2_ceil(le.load_size * 8));   // little-endian x86
    max_load_ty := emc_int_ty(max(e.max_load_size, power_of_2_ceil(le.load_size)));
    irb_set_end(*e.b, e.load_cmp_blocks[bi]);
    l, r := emc_get_load_pair(e, load_ty, bswap_ty, max_load_ty, le.offset);
    if !e.is_used_for_zero_cmp {
        phi_add_incoming(e.phi_src1, l, e.load_cmp_blocks[bi]);
        phi_add_incoming(e.phi_src2, r, e.load_cmp_blocks[bi]);
    }
    cmp := irb_icmp(*e.b, ICMP_EQ, l, r);
    next_bb := ifx bi == e.load_cmp_blocks.count - 1 then e.end_block else e.load_cmp_blocks[bi + 1];
    bb := e.b.bb;
    br := irb_cond_br(*e.b, cmp, next_bb, e.res_bb);
    set_explicitly_unknown_branch_weights_if_profiled(br, "expand-memcmp");
    emc_dtu(e, .[.{true, bb, next_bb}, .{true, bb, e.res_bb}]);
    if bi == e.load_cmp_blocks.count - 1 phi_add_incoming(e.phi_res, const_int(ir.t_i32, 0), e.load_cmp_blocks[bi]);
}

// emitMemCmpResultBlock
emc_emit_memcmp_result_block :: (e: *Memcmp_Expansion) {
    irb_set_at(*e.b, e.res_bb, block_first_insertion_pt(e.res_bb), true);
    if e.is_used_for_zero_cmp {
        phi_add_incoming(e.phi_res, const_int(ir.t_i32, 1), e.res_bb);
        irb_br(*e.b, e.end_block);
        emc_dtu(e, .[.{true, e.res_bb, e.end_block}]);
        return;
    }
    cmp := irb_icmp(*e.b, ICMP_ULT, e.phi_src1, e.phi_src2);
    res := irb_select(*e.b, cmp, const_all_ones_of(ir.t_i32), const_int(ir.t_i32, 1));
    if is_inst(res) set_explicitly_unknown_branch_weights_if_profiled(res, "expand-memcmp");
    phi_add_incoming(e.phi_res, res, e.res_bb);
    irb_br(*e.b, e.end_block);
    emc_dtu(e, .[.{true, e.res_bb, e.end_block}]);
}

emc_setup_result_block_phis :: (e: *Memcmp_Expansion) {
    t := emc_int_ty(e.max_load_size);
    irb_set_end(*e.b, e.res_bb);
    e.phi_src1 = irb_phi(*e.b, t, cast(u32) e.num_loads_non_one_byte, "phi.src1");
    e.phi_src2 = irb_phi(*e.b, t, cast(u32) e.num_loads_non_one_byte, "phi.src2");
}
emc_setup_end_block_phis :: (e: *Memcmp_Expansion) {
    irb_set_at(*e.b, e.end_block, block_first(e.end_block), true);
    e.phi_res = irb_phi(*e.b, ir.t_i32, 2, "phi.res");
}

// getMemCmpExpansionZeroCase
emc_zero_case :: (e: *Memcmp_Expansion) -> Value_Id {
    load_index: u64 = 0;
    for i: 0..cast(s64) emc_num_blocks(e) - 1 emc_emit_load_compare_block_multiple_loads(e, i, *load_index);
    emc_emit_memcmp_result_block(e);
    return e.phi_res;
}
// getMemCmpEqZeroOneBlock
emc_eq_zero_one_block :: (e: *Memcmp_Expansion) -> Value_Id {
    load_index: u64 = 0;
    cmp := emc_get_compare_load_pairs(e, 0, *load_index);
    return irb_cast(*e.b, .ZEXT, cmp, ir.t_i32);
}

// getMemCmpOneBlock (NONE: the call and its user were replaced already)
emc_one_block :: (e: *Memcmp_Expansion) -> Value_Id {
    b := *e.b;
    size := e.size;
    needs_bswap := size != 1;   // little-endian
    load_ty := emc_int_ty(size);
    bswap_ty: Type_Id = ifx needs_bswap then type_int(cast(u32) power_of_2_ceil(size * 8)) else cast(Type_Id) 0;
    max_load_ty := emc_int_ty(max(e.max_load_size, power_of_2_ceil(size)));
    if size == 1 || size == 2 {
        l, r := emc_get_load_pair(e, load_ty, bswap_ty, ir.t_i32, 0);
        return irb_binop(b, .SUB, l, r);
    }
    l, r := emc_get_load_pair(e, load_ty, bswap_ty, max_load_ty, 0);
    ci := e.ci;
    if has_one_user(ci) {
        ui := first_user(ci);
        pred: u8 = BAD_ICMP_PREDICATE;
        needs_zext := false;
        bw := type_int_width(vtype(ci));
        if inst_op(ui) == .LSHR && op(ui, 0) != NONE && pm_specific_int(op(ui, 1), cast(u64) (bw - 1)) {
            pred = ICMP_SLT; needs_zext = true;
        } else if inst_op(ui) == .ICMP && inst_pred(ui) == ICMP_SGT && op(ui, 0) == ci && pm_all_ones(op(ui, 1)) {
            pred = ICMP_SGE;
        } else if inst_op(ui) == .ICMP && inst_pred(ui) == ICMP_SLT && op(ui, 0) == ci && pm_one(op(ui, 1)) {
            pred = ICMP_SLE;
        } else if inst_op(ui) == .ICMP && op(ui, 0) == ci && pm_zero(op(ui, 1)) {
            pred = inst_pred(ui);
        }
        if icmp_is_signed(pred) {
            cmp := irb_icmp(b, icmp_unsigned_predicate(pred), l, r);
            result := ifx needs_zext then irb_cast(b, .ZEXT, cmp, vtype(ui)) else cmp;
            replace_all_uses_with(ui, result);
            erase_inst_with_metadata(ui);
            erase_inst_with_metadata(ci);
            return NONE;
        }
    }
    ucmp := get_or_insert_intrinsic_declaration(IID_UCMP, .[ir.t_i32, vtype(l)]);
    return irb_call(b, ucmp, .[l, r]);
}

// getMemCmpExpansion
emc_expand :: (e: *Memcmp_Expansion) -> Value_Id {
    if emc_num_blocks(e) != 1 {
        start := inst_block(e.ci);
        e.end_block = split_block_dtu(start, e.ci, e.dtu, "endblock");
        emc_setup_end_block_phis(e);
        emc_create_result_block(e);
        if !e.is_used_for_zero_cmp emc_setup_result_block_phis(e);
        emc_create_load_cmp_blocks(e);
        set_successor(block_terminator(start), 0, e.load_cmp_blocks[0]);
        emc_dtu(e, .[.{true, start, e.load_cmp_blocks[0]}, .{false, start, e.end_block}]);
    }
    e.b.dbg = get_metadata(e.ci, 0);   // SetCurrentDebugLocation(CI->getDebugLoc())
    if e.is_used_for_zero_cmp return ifx emc_num_blocks(e) == 1 then emc_eq_zero_one_block(e) else emc_zero_case(e);
    if emc_num_blocks(e) == 1 return emc_one_block(e);
    for i: 0..cast(s64) emc_num_blocks(e) - 1 emc_emit_load_compare_block(e, i);
    emc_emit_memcmp_result_block(e);
    return e.phi_res;
}

// expandMemCmp
emc_expand_memcmp :: (ci: Value_Id, tti: *Tti, psi: *Psi, bfi: *Bfi, dtu: *Dtu, is_bcmp: bool) -> bool {
    f := block_fn(inst_block(ci));
    if fn_has_min_size(f) return false;
    sz := call_arg(ci, 2);
    if vkind(sz) != .C_INT return false;
    size := const_int_zext(sz);
    if size == 0 return false;
    is_used_for_zero_cmp := is_bcmp || is_only_used_in_zero_equality_comparison(ci);
    opt_for_size := should_optimize_for_size_bb(inst_block(ci), psi, bfi);
    ok, o := emc_enable_memcmp_expansion(tti, opt_for_size, is_used_for_zero_cmp);
    if !ok return false;
    if emc_opts.num_loads_per_block_set o.num_loads_per_block = cast(u64) emc_opts.num_loads_per_block;
    if opt_for_size && emc_opts.max_loads_opt_size_set o.max_num_loads = cast(u64) emc_opts.max_loads_opt_size;
    if !opt_for_size && emc_opts.max_loads_set o.max_num_loads = cast(u64) emc_opts.max_loads;
    e: Memcmp_Expansion;
    emc_init(*e, ci, size, *o, is_used_for_zero_cmp, dtu);
    if emc_num_loads(*e) == 0 return false;
    res := emc_expand(*e);
    if res != NONE {
        replace_all_uses_with(ci, res);
        erase_inst_with_metadata(ci);
    }
    return true;
}

expand_memcmp_run :: (f: Value_Id) -> Preserved {
    for k: Attr_Kind.[.SanitizeAddress, .SanitizeMemory, .SanitizeThread, .SanitizeHWAddress]
        if fn_has_fn_attr(f, k) return PRESERVE_ALL;
    tti := tti_get(f);
    // the module's cached ProfileSummaryInfo; BlockFrequencyInfo only when it has a profile summary
    psi := psi_cached_or_null();
    bfi: *Bfi = null;
    if psi && psi.has_summary bfi = get_bfi(f);
    dt := cached_domtree(f);
    dtu_storage: Dtu;
    dtu: *Dtu = null;
    if dt { dtu_storage.dt = dt; dtu_storage.lazy = true; dtu_storage.pending.allocator = temp; dtu_storage.deleted.allocator = temp; dtu_storage.deleted_set.allocator = temp; dtu = *dtu_storage; }
    calls: [..] Value_Id; calls.allocator = temp;
    is_bcmp: [..] bool; is_bcmp.allocator = temp;
    for i: fn_insts(f) {
        if inst_op(i) != .CALL continue;
        // TargetLibraryInfo::getLibFunc(CallBase): name and prototype only, no availability check
        ok, lf := tli_lookup_call(i);
        if !ok continue;
        if lf == .memcmp || lf == .bcmp { array_add(*calls, i); array_add(*is_bcmp, lf == .bcmp); }
    }
    made_changes := false;
    for calls if emc_expand_memcmp(it, tti, psi, bfi, dtu, is_bcmp[it_index]) made_changes = true;
    if made_changes for b: fn_blocks(f) simplify_instructions_in_block(b, false);   // TLI = nullptr
    if dtu dtu_flush(dtu);   // ~DomTreeUpdater
    if !made_changes return PRESERVE_ALL;
    pa := PRESERVE_NONE;
    preserve(*pa, .DOMTREE);
    return pa;
}
