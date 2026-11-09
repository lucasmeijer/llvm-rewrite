// SLPVectorizer: BoUpSLP::VLOperands (operand reordering of commutative / alternating bundles) and
// BoUpSLP::findBestRootPair. Ported from llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp (class VLOperands,
// complete). OpsVec[OpIdx][Lane] is `ops[op_idx][lane]`.

Operand_Data :: struct {
    v: Value_Id = NONE;
    apo: bool;
    used: bool;
}
VL_MODE_LOAD :: 0; VL_MODE_OPCODE :: 1; VL_MODE_CONSTANT :: 2; VL_MODE_SPLAT :: 3; VL_MODE_FAILED :: 4;

Vl_Operands :: struct {
    ops: [..] [..] Operand_Data;
    arg_size: u32;
    l: Loop_Id = NONE;                   // R.LI->getLoopFor(MainOp->getParent())
    best_scores: Table(u64, u32);        // BestScoresPerLanes: {OpIdx, Lane} -> score
}

vlo_num_operands :: inline (o: *Vl_Operands) -> s64 { return cast(s64) o.arg_size; }
vlo_num_lanes :: inline (o: *Vl_Operands) -> s64 { return o.ops[0].count; }
vlo_data :: inline (o: *Vl_Operands, op_idx: s64, lane: s64) -> *Operand_Data { return *o.ops[op_idx][lane]; }
vlo_value :: inline (o: *Vl_Operands, op_idx: s64, lane: s64) -> Value_Id { return o.ops[op_idx][lane].v; }
vlo_loop_invariant :: (o: *Vl_Operands, v: Value_Id) -> bool { return o.l != NONE && li_is_loop_invariant(slp.li, o.l, v); }

vlo_clear_used :: (o: *Vl_Operands) {
    for k: 0..vlo_num_operands(o)-1 for l: 0..vlo_num_lanes(o)-1 o.ops[k][l].used = false;
}
vlo_swap :: (o: *Vl_Operands, a: s64, b: s64, lane: s64) {
    t := o.ops[a][lane]; o.ops[a][lane] = o.ops[b][lane]; o.ops[b][lane] = t;
}

// getSplatScore(Lane, OpIdx, Idx, UsedLanes)
vlo_splat_score :: (o: *Vl_Operands, lane: s64, op_idx: s64, idx: s64, used_lanes: [] bool) -> s64 {
    idx_lane_v := vlo_value(o, idx, lane);
    if !is_inst(idx_lane_v) || idx_lane_v == vlo_value(o, op_idx, lane) || vc_is_op(idx_lane_v, .EXTRACTELEMENT) return 0;
    uv: [..] Value_Id; uv.allocator = temp;   // SmallDenseMap<Value *, unsigned>: value -> first lane
    ul: [..] s64; ul.allocator = temp;
    for ln: 0..vlo_num_lanes(o)-1 {
        if ln == lane continue;
        v := vlo_value(o, op_idx, ln);
        if !is_inst(v) return 0;
        found := false; for uv if it == v { found = true; break; }
        if !found { array_add(*uv, v); array_add(*ul, ln); }
    }
    cnt := cast(u64) uv.count;
    idx_pos := -1; for uv if it == idx_lane_v { idx_pos = it_index; break; }
    with_idx := ifx idx_pos >= 0 then cnt else cnt + 1;
    op_lane_v := vlo_value(o, op_idx, lane);
    op_pos := -1; for uv if it == op_lane_v { op_pos = it_index; break; }
    with_op := ifx op_pos >= 0 then cnt else cnt + 1;
    if with_idx == with_op return 0;
    a := cast(s64) min(bit_ceil(with_op) - with_op, with_op - bit_floor(with_op));
    b: s64;
    if idx_pos >= 0 && used_lanes[ul[idx_pos]] b = cast(s64) (with_idx - bit_floor(with_idx));
    else b = cast(s64) (bit_ceil(with_idx) - with_idx);
    return a - b;
}
// getExternalUseScore(Lane, OpIdx, Idx)
vlo_external_use_score :: (o: *Vl_Operands, lane: s64, op_idx: s64, idx: s64) -> s64 {
    iv := vlo_value(o, idx, lane);
    ov := vlo_value(o, op_idx, lane);
    if slp_is_vector_like_inst_with_const_ops(iv) && slp_is_vector_like_inst_with_const_ops(ov) return LA_SCORE_ALL_USER_VECTORIZED;
    if !is_inst(iv) || !is_inst(ov) return 0;
    return ifx slp_are_all_users_vectorized(iv) then cast(s64) LA_SCORE_ALL_USER_VECTORIZED else 0;
}
VLO_SCORE_SCALE_FACTOR :: 10;
VLO_SCORE_CONSTANT_SCALE_FACTOR :: 6;
// getLookAheadScore
vlo_look_ahead_score :: (o: *Vl_Operands, lhs: Value_Id, rhs: Value_Id, main_alt_ops: [] Value_Id, lane: s64, op_idx: s64, idx: s64, is_used: *bool, used_lanes: [] bool) -> s64 {
    la := Look_Ahead.{vlo_num_lanes(o), slp_cl.look_ahead_max_depth};
    score := la_score_at_level_rec(*la, lhs, rhs, NONE, NONE, 1, main_alt_ops);
    if score != 0 {
        splat := vlo_splat_score(o, lane, op_idx, idx, used_lanes) * VLO_SCORE_SCALE_FACTOR;
        if score <= -splat score = 0;
        else {
            score += splat;
            sf := ifx lhs == rhs && slp_is_constant(lhs) then VLO_SCORE_CONSTANT_SCALE_FACTOR else VLO_SCORE_SCALE_FACTOR;
            score *= sf;
            score += vlo_external_use_score(o, lane, op_idx, idx);
            is_used.* = true;
        }
    }
    return score;
}
// getBestOperand(OpIdx, Lane, LastLane, ReorderingModes, MainAltOps, UsedLanes): -1 = none
vlo_best_operand :: (o: *Vl_Operands, op_idx: s64, lane: s64, last_lane: s64, modes: [] s64, main_alt_ops: [] Value_Id, used_lanes: [] bool) -> s64 {
    n := vlo_num_operands(o);
    op_last_lane := vlo_value(o, op_idx, last_lane);
    mode := modes[op_idx];
    if mode == VL_MODE_FAILED return -1;
    op_idx_apo := vlo_data(o, op_idx, lane).apo;
    key := ((cast(u64) op_idx) << 32) | cast(u64) lane;
    found, prev := table_find(*o.best_scores, key);
    if !found { table_set(*o.best_scores, key, 0); prev = 0; }
    best_idx := -1;
    best_score: u32 = prev;
    is_used := mode == VL_MODE_SPLAT || mode == VL_MODE_CONSTANT || mode == VL_MODE_LOAD;
    for idx: 0..n-1 {
        d := vlo_data(o, idx, lane);
        v := d.v;
        if d.used continue;
        if d.apo != op_idx_apo continue;
        if mode == VL_MODE_LOAD || mode == VL_MODE_OPCODE {
            ltr := lane > last_lane;
            left := ifx ltr then op_last_lane else v;
            right := ifx ltr then v else op_last_lane;
            score := vlo_look_ahead_score(o, left, right, main_alt_ops, lane, op_idx, idx, *is_used, used_lanes);
            if score > cast(s64) best_score || (score > 0 && score == cast(s64) best_score && idx == op_idx) {
                best_idx = idx;
                best_score = cast(u32) score;
                table_set(*o.best_scores, key, cast(u32) score);
            }
        } else if mode == VL_MODE_CONSTANT {
            if is_const(v) || (best_score == 0 && vlo_loop_invariant(o, v)) {
                best_idx = idx;
                if is_const(v) {
                    best_score = LA_SCORE_CONSTANTS;
                    table_set(*o.best_scores, key, LA_SCORE_CONSTANTS);
                }
                if pm_undef_value(v) || !is_const(v) is_used = false;
            }
        } else if mode == VL_MODE_SPLAT {
            if v == op_last_lane || (best_score == 0 && is_const(v)) {
                is_used = v == op_last_lane;
                if v == op_last_lane {
                    best_score = LA_SCORE_SPLAT;
                    table_set(*o.best_scores, key, LA_SCORE_SPLAT);
                }
                best_idx = idx;
            }
        }
    }
    if best_idx >= 0 {
        vlo_data(o, best_idx, lane).used = is_used;
        return best_idx;
    }
    return -1;
}

// getMaxNumOperandsThatCanBeReordered(Lane): (NumOfAPOs, NumOpsWithSameOpcodeParent, hash key)
// The hash of LLVM is only compared for equality (a MapVector key); the exact sequence it hashes is used here.
vlo_max_num_operands_reorderable :: (o: *Vl_Operands, lane: s64) -> (u64, u64, [..] u64) {
    key: [..] u64; key.allocator = temp;
    cnt_true: u64 = 0;
    n := vlo_num_operands(o);
    all_undefs := true;
    same_parent: u64 = 0;
    opcode_i: Value_Id = NONE;
    parent: Value_Id = NONE;
    for k: 0..n-1 {
        d := vlo_data(o, k, lane);
        if d.apo cnt_true += 1;
        if is_inst(d.v) {
            if opcode_i == NONE || !is_valid(slp_get_same_opcode(.[opcode_i, d.v])) || inst_block(d.v) != parent {
                if same_parent == 0 { same_parent = 1; opcode_i = d.v; parent = inst_block(d.v); }
                else same_parent -= 1;
            } else same_parent += 1;
        }
        array_add(*key, (cast(u64) k + 1) * (cast(u64) slp_value_id(d.v) + 1));
        all_undefs = all_undefs && pm_undef_value(d.v);
    }
    if all_undefs { e: [..] u64; e.allocator = temp; return 0xFFFF_FFFF, 0, e; }
    return max(cnt_true, cast(u64) n - cnt_true), same_parent, key;
}
// getBestLaneToStartReordering
vlo_best_lane_to_start_reordering :: (o: *Vl_Operands) -> s64 {
    min_apos: u64 = 0xFFFF_FFFF;
    same_op: u64 = 0;
    Entry :: struct { key: [..] u64; cnt: u64; lane: s64; }
    map: [..] Entry; map.allocator = temp;   // MapVector<hash, (count, lane)>
    keys_equal :: (a: [] u64, b: [] u64) -> bool { if a.count != b.count return false; for a if it != b[it_index] return false; return true; }
    set_entry :: (map: *[..] Entry, key: [..] u64, cnt: u64, lane: s64) {
        for * map.* if keys_equal(it.key, key) { it.cnt = cnt; it.lane = lane; return; }
        array_add(map, .{key, cnt, lane});
    }
    i := vlo_num_lanes(o);
    while i > 0 {
        lane := i - 1;
        i -= 1;
        apos, same, key := vlo_max_num_operands_reorderable(o, lane);
        if apos < min_apos {
            min_apos = apos;
            same_op = same;
            array_reset_keeping_memory(*map);
            array_add(*map, .{key, 1, lane});
        } else if apos == min_apos && same < same_op {
            same_op = same;
            set_entry(*map, key, 1, lane);
        } else if apos == min_apos && same == same_op {
            found := false;
            for * map if keys_equal(it.key, key) { it.cnt += 1; found = true; break; }
            if !found array_add(*map, .{key, 1, lane});
        }
    }
    best_lane: s64 = 0;
    cnt_min: u64 = 0xFFFF_FFFF;
    for < map if it.cnt < cnt_min { cnt_min = it.cnt; best_lane = it.lane; }
    return best_lane;
}

// appendOperands(VL, Operands, S)
vlo_append_operands :: (o: *Vl_Operands, vl: [] Value_Id, operands: [] [..] Value_Id, s: Inst_State) {
    main := s.main;
    nops_main := cast(s64) nops(main);
    o.arg_size = slp_num_potentially_commutative_ops(main);
    nl := vl.count;
    for k: 0..cast(s64) o.arg_size - 1 {
        d: [..] Operand_Data; d.allocator = temp;
        array_resize(*d, nl);
        array_add(*o.ops, d);
    }
    for lane: 0..nl-1 {
        v := vl[lane];
        if !is_inst(v) && pm_poison(v) {
            for k: 0..min(nops_main, cast(s64) o.arg_size)-1 o.ops[k][lane] = .{operands[k][lane], true, false};
            continue;
        }
        inverse := false;
        if is_copyable_element(s, v) {
            inverse = !slp_is_commutative_with(main, v, true);
        } else {
            sel, _ := slp_convert_to(v, s);
            inverse = !slp_is_commutative_with(sel, v);
        }
        for k: 0..cast(s64) o.arg_size - 1 {
            apo := ifx k == 0 then false else inverse;
            o.ops[k][lane] = .{operands[k][lane], apo, false};
        }
    }
}

// VLOperands(RootVL, Operands, S, R)
vlo_init :: (vl: [] Value_Id, operands: [] [..] Value_Id, s: Inst_State) -> Vl_Operands {
    o: Vl_Operands;
    o.ops.allocator = temp;
    o.best_scores.allocator = temp;
    o.l = li_loop_for(slp.li, inst_block(s.main));
    vlo_append_operands(*o, vl, operands, s);
    return o;
}
// getVL(OpIdx)
vlo_get_vl :: (o: *Vl_Operands, op_idx: s64) -> [..] Value_Id {
    r: [..] Value_Id; r.allocator = temp;
    for o.ops[op_idx] array_add(*r, it.v);
    return r;
}

// shouldBroadcast(Op, OpIdx, Lane)
vlo_should_broadcast :: (o: *Vl_Operands, v: Value_Id, op_idx: s64, lane: s64) -> bool {
    if vc_is_op(v, .LOAD) && vlo_num_lanes(o) == 2 && vlo_num_operands(o) == 2 return false;
    apo := vlo_data(o, op_idx, lane).apo;
    invariant := vlo_loop_invariant(o, v);
    cnt := 0;
    lns := vlo_num_lanes(o);
    ope := vlo_num_operands(o);
    for ln: 0..lns-1 {
        if ln == lane continue;
        found := false;
        for opi: 0..ope-1 {
            d := vlo_data(o, opi, ln);
            if d.apo != apo || d.used continue;
            op_i_lane := vlo_value(o, opi, lane);
            is_const_op := is_const(op_i_lane);
            if d.v == v ||
               (!is_const_op && ((lns > 2 && is_const(d.v)) ||
                                 (lns == 2 && !is_valid(slp_get_same_opcode(.[v, vlo_value(o, (opi + 1) % ope, ln)])) && is_const(d.v)))) ||
               (invariant && !is_const(d.v) && !is_valid(slp_get_same_opcode(.[v, d.v])) && vlo_loop_invariant(o, d.v)) {
                found = true;
                d.used = d.v == v;
                if d.v == v cnt += 1;
                break;
            }
        }
        if !found return false;
    }
    return vlo_num_lanes(o) == 2 || cnt > 1;
}
// canBeVectorized(Op, OpIdx, Lane)
vlo_can_be_vectorized :: (o: *Vl_Operands, v: Value_Id, op_idx: s64, lane: s64) -> bool {
    apo := vlo_data(o, op_idx, lane).apo;
    for ln: 0..vlo_num_lanes(o)-1 {
        if ln == lane continue;
        for opi: 0..vlo_num_operands(o)-1 {
            d := vlo_data(o, opi, ln);
            if d.apo != apo || d.used return true;
            x := vlo_value(o, opi, ln);
            if vlo_loop_invariant(o, x) || (is_valid(slp_get_same_opcode(.[v, x])) && slp_all_same_block(.[v, x])) return true;
        }
    }
    return false;
}

// reorder()
vlo_reorder :: (o: *Vl_Operands) {
    n := vlo_num_operands(o);
    nl := vlo_num_lanes(o);
    modes := NewArray(n, s64,, temp);
    first := vlo_best_lane_to_start_reordering(o);
    for k: 0..n-1 {
        v := vlo_value(o, k, first);
        if is_inst(v) {
            if vlo_should_broadcast(o, v, k, first) || !vlo_can_be_vectorized(o, v, k, first) modes[k] = VL_MODE_SPLAT;
            else if inst_op(v) == .LOAD modes[k] = VL_MODE_LOAD;
            else modes[k] = VL_MODE_OPCODE;
        } else if is_const(v) {
            modes[k] = VL_MODE_CONSTANT;
        } else if vkind(v) == .ARGUMENT {
            modes[k] = VL_MODE_SPLAT;
        } else {
            fatal("internal: slp: VLOperands::reorder: unexpected value kind");
        }
    }
    skip_reordering :: (o: *Vl_Operands) -> bool {
        uniq: [..] Value_Id; uniq.allocator = temp;
        for o.ops[0] { f := false; for u: uniq if u == it.v { f = true; break; } if !f array_add(*uniq, it.v); }
        for k: 1..vlo_num_operands(o)-1 {
            for d: o.ops[k] {
                f := false; for uniq if it == d.v { f = true; break; }
                if !f return false;
            }
        }
        return uniq.count != 2;
    }
    for pass: 0..1 {
        if skip_reordering(o) break;
        failed := false;
        vlo_clear_used(o);
        main_alt: [..] [..] Value_Id; main_alt.allocator = temp;
        for k: 0..n-1 { m: [..] Value_Id; m.allocator = temp; array_add(*m, vlo_value(o, k, first)); array_add(*main_alt, m); }
        used_lanes := NewArray(nl, bool,, temp);
        used_lanes[first] = true;
        for dist: 1..nl-1 {
            for dir: s64.[1, -1] {
                lane := first + dir * dist;
                if lane < 0 || lane >= nl continue;
                used_lanes[lane] = true;
                last := lane - dir;
                for k: 0..n-1 {
                    best := vlo_best_operand(o, k, lane, last, modes, main_alt[k], used_lanes);
                    if best >= 0 vlo_swap(o, k, best, lane);
                    else failed = true;
                    if main_alt[k].count != 2 {
                        alt := vlo_data(o, k, lane).v;
                        s := slp_get_same_opcode(.[main_alt[k][0], alt]);
                        if is_valid(s) && is_alt_shuffle(s) array_add(*main_alt[k], alt);
                    }
                }
            }
        }
        if !failed break;
    }
}

// findBestRootPair(Candidates, Limit): (index or -1, best score)
slp_find_best_root_pair :: (cands: [] [2] Value_Id, limit: s64 = LA_SCORE_FAIL) -> (s64, s64) {
    la := Look_Ahead.{2, slp_cl.root_look_ahead_max_depth};
    best := limit;
    index := -1;
    for c, i: cands {
        score := la_score_at_level_rec(*la, c[0], c[1], NONE, NONE, 1, .[]);
        if score > best { best = score; index = i; }
    }
    return index, best;
}

// Value::getValueID (Value.def order: constants, globals, argument, block, ..., Instruction + opcode)
slp_value_id :: (v: Value_Id) -> u32 {
    k := vkind(v);
    if k == {
        case .C_UNDEF; return 0;
        case .C_POISON; return 1;
        case .C_ZERO; return 2;
        case .C_DATA; return ifx type_kind(vtype(v)) == .ARRAY then cast(u32) 3 else 4;
        case .C_INT; return ifx type_kind(scalar_type(vtype(v))) == .BYTE then cast(u32) 6 else 5;
        case .C_FP; return 7;
        case .C_TARGET_NONE; return 8;
        case .C_NULL; return ifx type_kind(scalar_type(vtype(v))) == .PTR then cast(u32) 9 else 2;
        case .C_TOKEN_NONE; return 10;
        case .C_ARRAY; return 11;
        case .C_STRUCT; return 12;
        case .C_VECTOR; return 13;
        case .FUNCTION; return 14;
        case .ALIAS; return 15;
        case .IFUNC; return 16;
        case .GLOBAL_VAR; return 17;
        case .C_BLOCKADDR; return 18;
        case .C_EXPR; return 19;
        case .C_DSO_EQUIV; return 20;
        case .C_NO_CFI; return 21;
        case .C_PTRAUTH; return 22;
        case .ARGUMENT; return 23;
        case .BLOCK; return 24;
        case .MD_VALUE; return 25;
        case .INLINE_ASM; return 26;
        case .INST; return 30 + cast(u32) inst_op(v);
    }
    fatal("internal: slp: getValueID of an unexpected value kind");
    return 0;
}
// Type::getTypeID
slp_type_id :: (t: Type_Id) -> u32 {
    k := type_kind(t);
    if k == {
        case .HALF; return 0; case .BFLOAT; return 1; case .FLOAT; return 2; case .DOUBLE; return 3;
        case .X86_FP80; return 4; case .FP128; return 5; case .PPC_FP128; return 6; case .VOID; return 7;
        case .LABEL; return 8; case .METADATA; return 9; case .X86_AMX; return 10; case .TOKEN; return 11;
        case .INT; return 12; case .BYTE; return 13; case .FUNC; return 14; case .PTR; return 15;
        case .STRUCT; return 16; case .ARRAY; return 17; case .VECTOR; return 18; case .SVECTOR; return 19;
        case .TARGET_EXT; return 21;
    }
    return 20;
}
