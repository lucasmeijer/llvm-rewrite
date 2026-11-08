// DemandedBits analysis: port of llvm/lib/Analysis/DemandedBits.cpp (determineLiveOperandBits, performAnalysis,
// getDemandedBits, isInstructionDead, isUseDead, print, determineLiveOperandBitsAddCarry).
// Uses known_bits.jai, which is a partial computeKnownBits (see there).
//
// Results (alive bits per instruction, dead uses) live on the heap; scratch in temp.

Demanded_Bits :: struct {
    fn: Value_Id;
    dt: *Dom_Tree;
    analyzed: bool;
    visited: Table(Value_Id, bool);
    alive: Table(Value_Id, APInt);      // AliveBits (words on the heap)
    alive_order: [..] Value_Id;         // insertion order (the printer's DenseMap order is unspecified)
    dead_uses: Table(Use_Id, bool);
}

db_free :: (db: *Demanded_Bits) {
    for db.alive free(it.w.data);
    deinit(*db.visited); deinit(*db.alive); deinit(*db.dead_uses); array_free(db.alive_order);
    free(db);
}

db_is_always_live :: (i: Value_Id) -> bool {
    return is_terminator(inst_op(i)) || is_eh_pad(i) || may_have_side_effects(i);
}



db_set_alive :: (db: *Demanded_Bits, i: Value_Id, a: APInt) {
    p := table_find_pointer(*db.alive, i);
    if p {
        ap_assign(p, a);
        return;
    }
    table_set(*db.alive, i, ap_heap_copy(a));
    array_add(*db.alive_order, i);
}

// m_APInt: a ConstantInt or a splat of one
match_apint :: (v: Value_Id) -> (ok: bool, c: APInt) {
    k := vkind(v);
    bits := kb_scalar_bits(vtype(v));
    if k == .C_INT return true, ap_from_words(bits, const_int_value(v));
    if (k == .C_ZERO || k == .C_NULL) && type_kind(scalar_type(vtype(v))) == .INT return true, ap_zero(bits);
    if k == .C_DATA && is_vector_type(vtype(v)) && type_kind(scalar_type(vtype(v))) == .INT {
        n := const_data_count(v);
        e0 := const_data_elt(v, 0);
        for e: 1..cast(s64)n-1 if const_data_elt(v, cast(u64) e) != e0 return false, .{};
        return true, ap_from_u64(bits, e0);
    }
    if k == .C_VECTOR {
        n := nops(v);
        s := op(v, 0);
        for e: 1..n-1 if op(v, e) != s return false, .{};
        if vkind(s) == .C_INT return true, ap_from_words(bits, const_int_value(s));
    }
    return false, .{};
}

Db_Known :: struct {
    known: Known_Bits;
    known2: Known_Bits;
    computed: bool;
}

determine_live_operand_bits :: (db: *Demanded_Bits, user: Value_Id, val: Value_Id, opno: u32, aout: APInt,
                                ab: *APInt, kc: *Db_Known) {
    bits := ab.bits;
    compute :: (kc: *Db_Known, v1: Value_Id, v2: Value_Id) {
        if kc.computed return;
        kc.computed = true;
        kc.known = compute_known_bits(v1);
        if v2 != NONE kc.known2 = compute_known_bits(v2);
    }
    shifted_range :: (ab: *APInt, aout: APInt, mn: u64, mx: u64, shift_left: bool) {
        sh :: (m: APInt, a: u64, left: bool) -> APInt {
            s := cast(u32) min(a, cast(u64) 0xFFFF_FFFF);
            if left return ap_shl(m, s);
            return ap_lshr(m, s);
        }
        loop_range := mx - mn;
        mask := aout;
        shifted := aout;
        s: u64 = 1;
        while s <= loop_range {
            if loop_range & s {
                mask = ap_or(mask, sh(shifted, loop_range - s + 1, shift_left));
                loop_range -= s;
            }
            shifted = ap_or(shifted, sh(shifted, s, shift_left));
            s <<= 1;
        }
        ab.* = sh(mask, mn, shift_left);
    }
    r := inst(user);
    if r.op == {
        case .CALL; #through;
        case .INVOKE;
            id := intrinsic_id_of_call(user);
            if id == {
                case "llvm.bswap"; ab.* = ap_byte_swap(aout);
                case "llvm.bitreverse"; ab.* = ap_reverse_bits(aout);
                case "llvm.clmul"; ab.* = ap_low_bits_set(bits, ap_active_bits(aout));
                case "llvm.ctlz";
                    if opno == 0 {
                        compute(kc, val, NONE);
                        ab.* = ap_high_bits_set(bits, min(bits, kb_count_max_leading_zeros(kc.known) + 1));
                    }
                case "llvm.cttz";
                    if opno == 0 {
                        compute(kc, val, NONE);
                        ab.* = ap_low_bits_set(bits, min(bits, kb_count_max_trailing_zeros(kc.known) + 1));
                    }
                case "llvm.fshl"; #through;
                case "llvm.fshr";
                    if opno == 2 {
                        if (bits & (bits - 1)) == 0 ab.* = ap_from_u64(bits, bits - 1);
                    } else {
                        ok, sa := match_apint(op(user, 2));
                        if ok {
                            shift := ap_urem_u64(sa, bits);
                            if id == "llvm.fshr" shift = bits - shift;
                            if opno == 0 ab.* = ap_lshr(aout, cast(u32) shift);
                            else if opno == 1 ab.* = ap_shl(aout, cast(u32)(bits - shift));
                        }
                    }
                case "llvm.umax"; #through;
                case "llvm.umin"; #through;
                case "llvm.smax"; #through;
                case "llvm.smin";
                    ab.* = ap_bits_set_from(bits, ap_ctz(aout));
            }
        case .ADD; #through;
        case .SUB;
            if ap_is_mask(aout) ab.* = aout;
            else {
                compute(kc, op(user, 0), op(user, 1));
                if r.op == .ADD ab.* = live_bits_add_carry(opno, aout, kc.known, kc.known2, true, false);
                else {
                    nrhs: Known_Bits; nrhs.zero = kc.known2.one; nrhs.one = kc.known2.zero;
                    ab.* = live_bits_add_carry(opno, aout, kc.known, nrhs, false, true);
                }
            }
        case .MUL;
            ab.* = ap_low_bits_set(bits, ap_active_bits(aout));
        case .SHL;
            if opno == 0 {
                ok, c := match_apint(op(user, 1));
                if ok {
                    s := ap_limited(c, bits - 1);
                    ab.* = ap_lshr(aout, cast(u32) s);
                    if r.flags & F_NSW ab.* = ap_or(ab.*, ap_high_bits_set(bits, (cast(u32) s) + 1));
                    else if r.flags & F_NUW ab.* = ap_or(ab.*, ap_high_bits_set(bits, cast(u32) s));
                } else {
                    compute(kc, op(user, 1), NONE);
                    mn := ap_limited(kb_min_value(kc.known), bits - 1);
                    mx := ap_limited(kb_max_value(kc.known), bits - 1);
                    shifted_range(ab, aout, mn, mx, false);
                    if r.flags & F_NSW ab.* = ap_or(ab.*, ap_high_bits_set(bits, (cast(u32) mx) + 1));
                    else if r.flags & F_NUW ab.* = ap_or(ab.*, ap_high_bits_set(bits, cast(u32) mx));
                }
            }
        case .LSHR;
            if opno == 0 {
                ok, c := match_apint(op(user, 1));
                if ok {
                    s := ap_limited(c, bits - 1);
                    ab.* = ap_shl(aout, cast(u32) s);
                    if r.flags & F_EXACT ab.* = ap_or(ab.*, ap_low_bits_set(bits, cast(u32) s));
                } else {
                    compute(kc, op(user, 1), NONE);
                    mn := ap_limited(kb_min_value(kc.known), bits - 1);
                    mx := ap_limited(kb_max_value(kc.known), bits - 1);
                    shifted_range(ab, aout, mn, mx, true);
                    if r.flags & F_EXACT ab.* = ap_or(ab.*, ap_low_bits_set(bits, cast(u32) mx));
                }
            }
        case .ASHR;
            if opno == 0 {
                ok, c := match_apint(op(user, 1));
                if ok {
                    s := ap_limited(c, bits - 1);
                    ab.* = ap_shl(aout, cast(u32) s);
                    if ap_bool(ap_and(aout, ap_high_bits_set(bits, cast(u32) s))) ap_set_sign_bit(ab);
                    if r.flags & F_EXACT ab.* = ap_or(ab.*, ap_low_bits_set(bits, cast(u32) s));
                } else {
                    compute(kc, op(user, 1), NONE);
                    mn := ap_limited(kb_min_value(kc.known), bits - 1);
                    mx := ap_limited(kb_max_value(kc.known), bits - 1);
                    shifted_range(ab, aout, mn, mx, true);
                    if mx != 0 && ap_bool(ap_and(aout, ap_high_bits_set(bits, cast(u32) mx))) ap_set_sign_bit(ab);
                    if r.flags & F_EXACT ab.* = ap_or(ab.*, ap_low_bits_set(bits, cast(u32) mx));
                }
            }
        case .AND;
            ab.* = aout;
            compute(kc, op(user, 0), op(user, 1));
            if opno == 0 ab.* = ap_and(ab.*, ap_not(kc.known2.zero));
            else ab.* = ap_and(ab.*, ap_not(ap_and(kc.known.zero, ap_not(kc.known2.zero))));
        case .OR;
            ab.* = aout;
            compute(kc, op(user, 0), op(user, 1));
            if opno == 0 ab.* = ap_and(ab.*, ap_not(kc.known2.one));
            else ab.* = ap_and(ab.*, ap_not(ap_and(kc.known.one, ap_not(kc.known2.one))));
        case .XOR; #through;
        case .PHI; ab.* = aout;
        case .TRUNC; ab.* = ap_zext(aout, bits);
        case .ZEXT; ab.* = ap_trunc(aout, bits);
        case .SEXT;
            ab.* = ap_trunc(aout, bits);
            if ap_bool(ap_and(aout, ap_high_bits_set(aout.bits, aout.bits - bits))) ap_set_sign_bit(ab);
        case .SELECT; if opno != 0 ab.* = aout;
        case .EXTRACTELEMENT; if opno == 0 ab.* = aout;
        case .INSERTELEMENT; #through;
        case .SHUFFLEVECTOR; if opno == 0 || opno == 1 ab.* = aout;
    }
}

// determineLiveOperandBitsAddCarry
live_bits_add_carry :: (opno: u32, aout: APInt, lhs: Known_Bits, rhs: Known_Bits, carry_zero: bool, carry_one: bool) -> APInt {
    bound := ap_or(ap_and(lhs.zero, rhs.zero), ap_and(lhs.one, rhs.one));
    rbound := ap_reverse_bits(bound);
    raout := ap_reverse_bits(aout);
    rprop := ap_add(raout, ap_or(raout, ap_not(rbound)));
    racarry := ap_xor(rprop, ap_not(rbound));
    acarry := ap_reverse_bits(racarry);
    nz, no: APInt;
    if opno == 0 {
        nz = ap_or(lhs.zero, ap_not(rhs.zero));
        no = ap_or(lhs.one, ap_not(rhs.one));
    } else {
        nz = ap_or(rhs.zero, ap_not(lhs.zero));
        no = ap_or(rhs.one, ap_not(lhs.one));
    }
    psz := ap_add_u64(ap_add(ap_not(lhs.zero), ap_not(rhs.zero)), ifx carry_zero then cast(u64) 0 else 1);
    pso := ap_add_u64(ap_add(lhs.one, rhs.one), ifx carry_one then cast(u64) 1 else 0);
    need := ap_and(ap_or(ap_not(psz), nz), ap_or(pso, no));
    return ap_or(aout, ap_and(acarry, need));
}

// performAnalysis
db_perform_analysis :: (db: *Demanded_Bits) {
    if db.analyzed return;
    db.analyzed = true;
    wl: Small_Set_Vector; ssv_init(*wl);
    for i: fn_insts(db.fn) {
        if !db_is_always_live(i) continue;
        t := vtype(i);
        if is_int_or_int_vector(t) {
            if !table_contains(*db.alive, i) {
                db_set_alive(db, i, ap_zero(kb_scalar_bits(t)));
                ssv_insert(*wl, i);
            }
            continue;
        }
        n := nops(i);
        if n > 0 for k: 0..n-1 {
            j := op(i, k);
            if !is_inst(j) continue;
            jt := vtype(j);
            if is_int_or_int_vector(jt) db_set_alive(db, j, ap_all_ones(kb_scalar_bits(jt)));
            else table_set(*db.visited, j, true);
            ssv_insert(*wl, j);
        }
    }
    while wl.items.count {
        user := ssv_pop(*wl);
        aout: APInt;
        input_dead := false;
        if is_int_or_int_vector(vtype(user)) {
            _, a := table_find(*db.alive, user);
            aout = ap_copy(a);
            input_dead = ap_is_zero(aout) && !db_is_always_live(user);
        }
        kc: Db_Known;
        n := nops(user);
        if n > 0 for k: 0..n-1 {
            u := op_use(user, k);
            v := ir.u_val[u];
            if v == NONE continue;
            is_i := is_inst(v);
            if !is_i && vkind(v) != .ARGUMENT continue;
            t := vtype(v);
            if is_int_or_int_vector(t) {
                bits := kb_scalar_bits(t);
                ab := ap_all_ones(bits);
                if input_dead {
                    ab = ap_zero(bits);
                } else {
                    determine_live_operand_bits(db, user, v, k, aout, *ab, *kc);
                    if ap_is_zero(ab) table_set(*db.dead_uses, u, true);
                    else table_remove(*db.dead_uses, u);
                }
                if is_i {
                    p := table_find_pointer(*db.alive, v);
                    if !p {
                        db_set_alive(db, v, ab);
                        ssv_insert(*wl, v);
                    } else {
                        merged := ap_or(ab, p.*);
                        if !ap_eq(merged, p.*) {
                            db_set_alive(db, v, merged);
                            ssv_insert(*wl, v);
                        }
                    }
                }
            } else if is_i && !table_contains(*db.visited, v) {
                table_set(*db.visited, v, true);
                ssv_insert(*wl, v);
            }
        }
    }
}

// getDemandedBits(Instruction *I)
db_demanded_bits :: (db: *Demanded_Bits, i: Value_Id) -> APInt {
    db_perform_analysis(db);
    p := table_find_pointer(*db.alive, i);
    if p return ap_copy(p.*);
    return ap_all_ones(type_bits_for_db(vtype(i)));
}

// getDemandedBits(Use *U)
db_demanded_bits_use :: (db: *Demanded_Bits, u: Use_Id) -> APInt {
    v := ir.u_val[u];
    t := vtype(v);
    user := ir.u_user[u];
    bits := type_bits_for_db(t);
    if !is_int_or_int_vector(t) return ap_all_ones(bits);
    if db_is_use_dead(db, u) return ap_zero(bits);
    db_perform_analysis(db);
    aout := db_demanded_bits(db, user);
    ab := ap_all_ones(bits);
    kc: Db_Known;
    determine_live_operand_bits(db, user, v, u - ir.v_ops[user], aout, *ab, *kc);
    return ab;
}
// DL.getTypeSizeInBits(T->getScalarType())
type_bits_for_db :: (t: Type_Id) -> u32 { return cast(u32) dl_type_size_bits(scalar_type(t)); }

db_is_instruction_dead :: (db: *Demanded_Bits, i: Value_Id) -> bool {
    db_perform_analysis(db);
    return !table_contains(*db.visited, i) && !table_contains(*db.alive, i) && !db_is_always_live(i);
}

db_is_use_dead :: (db: *Demanded_Bits, u: Use_Id) -> bool {
    v := ir.u_val[u];
    if !is_int_or_int_vector(vtype(v)) return false;
    user := ir.u_user[u];
    if db_is_always_live(user) return false;
    db_perform_analysis(db);
    if table_contains(*db.dead_uses, u) return true;
    if is_int_or_int_vector(vtype(user)) {
        p := table_find_pointer(*db.alive, user);
        if p && ap_is_zero(p.*) return true;
    }
    return false;
}

// DemandedBits::print. LLVM iterates a DenseMap keyed by pointer, so the order is unspecified (tests compare it
// unordered); we use insertion order.
db_print :: (db: *Demanded_Bits, sb: *String_Builder) {
    print_to_builder(sb, "Printing analysis 'Demanded Bits Analysis' for function '%':\n", vname(db.fn));
    db_perform_analysis(db);
    for i: db.alive_order {
        _, a := table_find(*db.alive, i);
        print_to_builder(sb, "DemandedBits: 0x% for %\n", u64_to_hex(ap_limited(a)), inst_to_string(i));
        n := nops(i);
        if n > 0 for k: 0..n-1 {
            u := op_use(i, k);
            d := db_demanded_bits_use(db, u);
            print_to_builder(sb, "DemandedBits: 0x% for % in %\n", u64_to_hex(ap_limited(d)),
                             value_as_operand(ir.u_val[u]), inst_to_string(i));
        }
    }
}
