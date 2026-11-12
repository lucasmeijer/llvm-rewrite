// bypassSlowDivision: port of llvm/lib/Transforms/Utils/BypassSlowDivision.cpp (FastDivInsertionTask), called by
// CodeGenPrepare with X86's bypass widths (64 -> 32 with idivq-to-divl on x86-64, 32 -> 8 with idivl-to-divb) and
// CodeGenPrepare's lazy DomTreeUpdater and LoopInfo.

Bsd_Pair :: struct { quot: Value_Id; rem: Value_Id; }
Bsd_Key :: struct { signed: bool; dividend: Value_Id; divisor: Value_Id; }
Bsd_Task :: struct {
    slow: Value_Id;
    bypass_ty: Type_Id;
    main_bb: Value_Id;
}
VALRNG_KNOWN_SHORT :: 0; VALRNG_UNKNOWN :: 1; VALRNG_LIKELY_LONG :: 2;

bsd_bypass_width :: (bits: u32) -> u32 {
    if cg_tm_opt_level < 2 return 0;
    if bits == 64 && st_hasSlowDivide64(cgp.xl) && st_is64Bit(cgp.xl) return 32;
    if bits == 32 && st_hasSlowDivide32(cgp.xl) return 8;
    return 0;
}
bsd_is_signed :: (t: *Bsd_Task) -> bool { o := inst_op(t.slow); return o == .SDIV || o == .SREM; }
bsd_is_div :: (t: *Bsd_Task) -> bool { o := inst_op(t.slow); return o == .SDIV || o == .UDIV; }

bsd_is_hash_like_value :: (t: *Bsd_Task, v: Value_Id, visited: *[..] Value_Id) -> bool {
    if !is_inst(v) return false;
    o := inst_op(v);
    if o == .XOR return true;
    if o == .MUL {
        op1 := op(v, 1);
        c: Value_Id = NONE;
        if vkind(op1) == .C_INT c = op1;
        else if is_inst(op1) && inst_op(op1) == .BITCAST && vkind(op(op1, 0)) == .C_INT c = op(op1, 0);
        return c != NONE && ap_significant_bits(const_ap(c)) > type_bits(t.bypass_ty);
    }
    if o == .PHI {
        if visited.count >= 16 return false;
        for visited.* if it == v return true;
        array_add(visited, v);
        for k: 0..cast(s64) nops(v) - 1 {
            x := phi_value(v, cast(u32) k);
            if !(bsd_get_value_range(t, x, visited) == VALRNG_LIKELY_LONG || vkind(x) == .C_UNDEF || vkind(x) == .C_POISON) return false;
        }
        return true;
    }
    return false;
}

bsd_get_value_range :: (t: *Bsd_Task, v: Value_Id, visited: *[..] Value_Id) -> int {
    short_len := type_bits(t.bypass_ty);
    long_len := type_bits(vtype(v));
    hi_bits := long_len - short_len;
    q: Simplify_Query;
    k := known_bits(v, q);
    if kb_count_min_leading_zeros(k) >= hi_bits return VALRNG_KNOWN_SHORT;
    if kb_count_max_leading_zeros(k) < hi_bits return VALRNG_LIKELY_LONG;
    if bsd_is_hash_like_value(t, v, visited) return VALRNG_LIKELY_LONG;
    return VALRNG_UNKNOWN;
}

Bsd_Bb :: struct { bb: Value_Id; quot: Value_Id; rem: Value_Id; }

bsd_create_slow_bb :: (t: *Bsd_Task, succ: Value_Id) -> Bsd_Bb {
    r: Bsd_Bb;
    r.bb = create_block(block_fn(t.main_bb), "", succ);
    b: Irb; irb_set_end(*b, r.bb); b.dbg = get_metadata(t.slow, 0);
    a := op(t.slow, 0); d := op(t.slow, 1);
    if bsd_is_signed(t) { r.quot = irb_binop(*b, .SDIV, a, d); r.rem = irb_binop(*b, .SREM, a, d); }
    else { r.quot = irb_binop(*b, .UDIV, a, d); r.rem = irb_binop(*b, .UREM, a, d); }
    irb_br(*b, succ);
    return r;
}
bsd_create_fast_bb :: (t: *Bsd_Task, succ: Value_Id) -> Bsd_Bb {
    r: Bsd_Bb;
    r.bb = create_block(block_fn(t.main_bb), "", succ);
    b: Irb; irb_set_end(*b, r.bb); b.dbg = get_metadata(t.slow, 0);
    a := op(t.slow, 0); d := op(t.slow, 1);
    sd := irb_cast(*b, .TRUNC, d, t.bypass_ty);
    sa := irb_cast(*b, .TRUNC, a, t.bypass_ty);
    sq := irb_binop(*b, .UDIV, sa, sd);
    sr := irb_binop(*b, .UREM, sa, sd);
    r.quot = irb_cast(*b, .ZEXT, sq, vtype(t.slow));
    r.rem = irb_cast(*b, .ZEXT, sr, vtype(t.slow));
    irb_br(*b, succ);
    return r;
}
bsd_create_div_rem_phi_nodes :: (t: *Bsd_Task, l: *Bsd_Bb, r: *Bsd_Bb, phi_bb: Value_Id) -> Bsd_Pair {
    b: Irb; irb_set_at(*b, phi_bb, block_first(phi_bb), false); b.dbg = get_metadata(t.slow, 0);
    qp := irb_phi(*b, vtype(t.slow), 2);
    phi_add_incoming(qp, l.quot, l.bb);
    phi_add_incoming(qp, r.quot, r.bb);
    rp := irb_phi(*b, vtype(t.slow), 2);
    phi_add_incoming(rp, l.rem, l.bb);
    phi_add_incoming(rp, r.rem, r.bb);
    return .{qp, rp};
}
bsd_insert_operand_runtime_check :: (t: *Bsd_Task, op1: Value_Id, op2: Value_Id) -> Value_Id {
    b: Irb; irb_set_end(*b, t.main_bb); b.dbg = get_metadata(t.slow, 0);
    or_v: Value_Id;
    if op1 != NONE && op2 != NONE or_v = irb_binop(*b, .OR, op1, op2);
    else or_v = ifx op1 != NONE then op1 else op2;
    w := type_bits(vtype(or_v));
    and_v := irb_binop(*b, .AND, or_v, const_int_ap(vtype(or_v), ap_bits_set_from(w, type_bits(t.bypass_ty))));
    zero := const_int(vtype(t.slow), 0);
    return irb_icmp(*b, ICMP_EQ, and_v, zero);
}

// insertFastDivAndRem -> (ok, pair)
bsd_insert_fast_div_and_rem :: (t: *Bsd_Task) -> (bool, Bsd_Pair) {
    dividend := op(t.slow, 0); divisor := op(t.slow, 1);
    set_l: [..] Value_Id; set_l.allocator = temp;
    dr := bsd_get_value_range(t, dividend, *set_l);
    if dr == VALRNG_LIKELY_LONG return false, .{};
    set_r: [..] Value_Id; set_r.allocator = temp;
    vr := bsd_get_value_range(t, divisor, *set_r);
    if vr == VALRNG_LIKELY_LONG return false, .{};
    dividend_short := dr == VALRNG_KNOWN_SHORT;
    divisor_short := vr == VALRNG_KNOWN_SHORT;
    if dividend_short && divisor_short {
        b: Irb; irb_set_before(*b, t.slow);
        ta := irb_cast(*b, .TRUNC, dividend, t.bypass_ty);
        td := irb_cast(*b, .TRUNC, divisor, t.bypass_ty);
        tq := irb_binop(*b, .UDIV, ta, td);
        tr := irb_binop(*b, .UREM, ta, td);
        eq := irb_cast(*b, .ZEXT, tq, vtype(t.slow));
        er := irb_cast(*b, .ZEXT, tr, vtype(t.slow));
        return true, .{eq, er};
    }
    if vkind(divisor) == .C_INT return false, .{};
    if is_inst(divisor) && inst_op(divisor) == .BITCAST && inst_block(divisor) == inst_block(t.slow) && vkind(op(divisor, 0)) == .C_INT return false, .{};
    if dividend_short && !bsd_is_signed(t) {
        succ := cgp_split_block(t.main_bb, t.slow, "");
        erase_inst_with_metadata(block_last(t.main_bb));
        long: Bsd_Bb;
        long.bb = t.main_bb;
        long.quot = const_int(vtype(t.slow), 0);
        long.rem = dividend;
        fast := bsd_create_fast_bb(t, succ);
        result := bsd_create_div_rem_phi_nodes(t, *fast, *long, succ);
        b: Irb; irb_set_end(*b, t.main_bb); b.dbg = get_metadata(t.slow, 0);
        cmp := irb_icmp(*b, ICMP_UGE, dividend, divisor);
        irb_cond_br(*b, cmp, fast.bb, succ);
        dtu_apply(*cgp.dtu, .[.{true, t.main_bb, fast.bb}, .{true, fast.bb, succ}]);
        if cgp.li { l := li_loop_for(cgp.li, t.main_bb); if l != NONE li_add_basic_block_to_loop(cgp.li, l, fast.bb); }
        return true, result;
    }
    succ := cgp_split_block(t.main_bb, t.slow, "");
    erase_inst_with_metadata(block_last(t.main_bb));
    fast := bsd_create_fast_bb(t, succ);
    slow := bsd_create_slow_bb(t, succ);
    result := bsd_create_div_rem_phi_nodes(t, *fast, *slow, succ);
    cmp := bsd_insert_operand_runtime_check(t, ifx dividend_short then NONE else dividend, ifx divisor_short then NONE else divisor);
    b: Irb; irb_set_end(*b, t.main_bb); b.dbg = get_metadata(t.slow, 0);
    irb_cond_br(*b, cmp, fast.bb, slow.bb);
    dtu_apply(*cgp.dtu, .[.{true, t.main_bb, fast.bb}, .{true, t.main_bb, slow.bb}, .{true, fast.bb, succ},
                          .{true, slow.bb, succ}, .{false, t.main_bb, succ}]);
    if cgp.li {
        l := li_loop_for(cgp.li, t.main_bb);
        if l != NONE { li_add_basic_block_to_loop(cgp.li, l, fast.bb); li_add_basic_block_to_loop(cgp.li, l, slow.bb); }
    }
    return true, result;
}

// bypassSlowDivision(BB, BypassWidths, DTU, LI)
bypass_slow_division :: (bb: Value_Id) -> bool {
    cache_keys: [..] Bsd_Key; cache_keys.allocator = temp;
    cache_vals: [..] Bsd_Pair; cache_vals.allocator = temp;
    made_change := false;
    next := block_first(bb);
    while next != NONE {
        i := next;
        next = inst_next(next);
        if !has_uses(i) continue;
        o := inst_op(i);
        if o != .UDIV && o != .SDIV && o != .UREM && o != .SREM continue;
        if type_kind(vtype(i)) != .INT continue;
        bw := bsd_bypass_width(type_bits(vtype(i)));
        if bw == 0 continue;
        t: Bsd_Task;
        t.slow = i; t.bypass_ty = type_int(bw); t.main_bb = inst_block(i);
        key := Bsd_Key.{bsd_is_signed(*t), op(i, 0), op(i, 1)};
        idx := -1;
        for cache_keys if it.signed == key.signed && it.dividend == key.dividend && it.divisor == key.divisor { idx = it_index; break; }
        if idx < 0 {
            ok, pair := bsd_insert_fast_div_and_rem(*t);
            if !ok continue;
            array_add(*cache_keys, key);
            array_add(*cache_vals, pair);
            idx = cache_keys.count - 1;
        }
        repl := ifx bsd_is_div(*t) then cache_vals[idx].quot else cache_vals[idx].rem;
        rauw_with_metadata(i, repl);
        erase_inst_with_metadata(i);
        made_change = true;
    }
    for cache_vals {
        recursively_delete_trivially_dead_value_tli(it.quot);
        recursively_delete_trivially_dead_value_tli(it.rem);
    }
    return made_change;
}
// RecursivelyDeleteTriviallyDeadInstructions(V) (TLI = nullptr)
recursively_delete_trivially_dead_value_tli :: (v: Value_Id) -> bool {
    if vkind(v) == .DEAD return false;
    return recursively_delete_trivially_dead_value(v);
}
