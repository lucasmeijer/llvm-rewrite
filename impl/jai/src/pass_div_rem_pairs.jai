// DivRemPairs: port of llvm/lib/Transforms/Scalar/DivRemPairs.cpp (matchExpandedRem, getWorklist, optimizeDivRem).
// TTI::hasDivRemOp is tti_has_div_rem_op (tti.jai).

Drp_Key :: struct { signed: bool; dividend: Value_Id; divisor: Value_Id; }
drp_key_hash :: (k: Drp_Key) -> u32 {
    h: u64 = cast(u64) k.dividend * 0x9E37_79B9_7F4A_7C15 + cast(u64) k.divisor * 0xC2B2_AE3D_27D4_EB4F + cast(u64) k.signed;
    h ^= h >> 29;
    return cast(u32) (h & 0xFFFF_FFFF);
}
drp_key_eq :: (a: Drp_Key, b: Drp_Key) -> bool { return a.signed == b.signed && a.dividend == b.dividend && a.divisor == b.divisor; }

// matchExpandedRem: X - ((X ?/ Y) * Y)
drp_match_expanded_rem :: (i: Value_Id) -> (bool, Drp_Key) {
    k: Drp_Key;
    if inst_op(i) != .SUB return false, k;
    dividend := op(i, 0);
    m := op(i, 1);
    if !is_inst(m) || inst_op(m) != .MUL return false, k;
    try :: (d: Value_Id, other: Value_Id, dividend: Value_Id) -> (bool, Drp_Key) {
        k: Drp_Key;
        if !is_inst(d) || (inst_op(d) != .SDIV && inst_op(d) != .UDIV) return false, k;
        if op(d, 0) != dividend return false, k;
        divisor := op(d, 1);
        if other != divisor return false, k;
        k.signed = inst_op(d) == .SDIV; k.dividend = dividend; k.divisor = divisor;
        return true, k;
    }
    ok: bool;
    ok, k = try(op(m, 0), op(m, 1), dividend);
    if ok return true, k;
    ok, k = try(op(m, 1), op(m, 0), dividend);
    return ok, k;
}

Drp_Entry :: struct { div: Value_Id; rem: Value_Id; }

drp_is_rem_expanded :: (e: Drp_Entry) -> bool { o := inst_op(e.rem); return o != .SREM && o != .UREM; }

drp_get_worklist :: (f: Value_Id) -> [..] Drp_Entry {
    div_map: Table(Drp_Key, Value_Id, drp_key_hash, drp_key_eq); div_map.allocator = temp;
    rem_index: Table(Drp_Key, s64, drp_key_hash, drp_key_eq); rem_index.allocator = temp;   // MapVector
    rem_keys: [..] Drp_Key; rem_keys.allocator = temp;
    rem_vals: [..] Value_Id; rem_vals.allocator = temp;
    rem_set :: (k: Drp_Key, v: Value_Id) #expand {
        found, idx := table_find(*rem_index, k);
        if found { rem_vals[idx] = v; return; }
        table_set(*rem_index, k, rem_keys.count);
        array_add(*rem_keys, k); array_add(*rem_vals, v);
    }
    for i: fn_insts(f) {
        o := inst_op(i);
        if o == .SDIV table_set(*div_map, .{true, op(i, 0), op(i, 1)}, i);
        else if o == .UDIV table_set(*div_map, .{false, op(i, 0), op(i, 1)}, i);
        else if o == .SREM rem_set(.{true, op(i, 0), op(i, 1)}, i);
        else if o == .UREM rem_set(.{false, op(i, 0), op(i, 1)}, i);
        else {
            ok, k := drp_match_expanded_rem(i);
            if ok rem_set(k, i);
        }
    }
    wl: [..] Drp_Entry; wl.allocator = temp;
    for k: rem_keys {
        found, d := table_find(*div_map, k);
        if !found continue;
        array_add(*wl, .{d, rem_vals[it_index]});
    }
    return wl;
}

// Instruction::insertAfter(It) of a new instruction: inserted before the next one, adopting its debug records
drp_insert_after :: (i: Value_Id, pos: Value_Id) {
    insert_at_position(i, inst_block(pos), inst_next(pos), false);
}
// Instruction::moveAfter
drp_move_after :: (i: Value_Id, pos: Value_Id) {
    nx := inst_next(pos);
    if nx == i return;   // moveBefore(itself): nothing moves (no records are touched without the head bit)
    if nx == NONE fatal("div-rem-pairs: moving after a block's last instruction is not supported");
    inst_move_before_dbg(i, nx);
}

div_rem_pairs_run :: (f: Value_Id) -> Preserved {
    tti := tti_get(f);
    dt := get_domtree(f);
    changed := false;
    wl := drp_get_worklist(f);
    for * e: wl {
        signed := inst_op(e.div) == .SDIV;
        has_div_rem_op := tti_has_div_rem_op(tti, vtype(e.div), signed);
        if has_div_rem_op && drp_is_rem_expanded(e) {
            x := op(e.div, 0); y := op(e.div, 1);
            real_rem := create_binop(ifx signed then Opcode.SREM else .UREM, x, y);
            drp_insert_after(real_rem, e.rem);
            set_name(real_rem, tconcat(vname(e.rem), ".recomposed"));
            orig := e.rem;
            e.rem = real_rem;
            rauw_with_metadata(orig, real_rem);
            copy_debug_loc(real_rem, orig);
            erase_inst_with_metadata(orig);
            changed = true;
        }
        if has_div_rem_op && inst_block(e.rem) == inst_block(e.div) continue;

        div_dominates := dt_dominates_inst(dt, e.div, e.rem);
        if !div_dominates && !dt_dominates_inst(dt, e.rem, e.div) {
            pred_bb: Value_Id = NONE;
            div_bb := inst_block(e.div);
            rem_bb := inst_block(e.rem);
            is_safe_to_hoist :: (div_or_rem: Value_Id, bb: Value_Id) -> bool {
                x := block_first(bb);
                while x != div_or_rem { if !is_guaranteed_to_transfer_execution(x) return false; x = inst_next(x); }
                return true;
            }
            if block_single_successor(rem_bb) == div_bb {
                pred_bb = block_unique_predecessor(rem_bb);
            } else {
                rem_pred_bb := block_unique_predecessor(rem_bb);
                if rem_pred_bb != NONE && has_div_rem_op && rem_pred_bb == block_unique_predecessor(div_bb) pred_bb = rem_pred_bb;
            }
            ok := pred_bb != NONE;
            if ok {
                t := block_terminator(pred_bb);
                ok = inst_op(t) != .CATCHSWITCH && is_guaranteed_to_transfer_execution(t) &&
                     is_safe_to_hoist(e.rem, rem_bb) && is_safe_to_hoist(e.div, div_bb);
                if ok {
                    succs: [..] Value_Id; succs.allocator = temp;
                    block_successors(pred_bb, *succs);
                    for succs if it != div_bb && it != rem_bb { ok = false; break; }
                }
                if ok {
                    preds: [..] Value_Id; preds.allocator = temp;
                    block_predecessors(div_bb, *preds);
                    for preds if it != rem_bb && it != pred_bb { ok = false; break; }
                }
            }
            if ok {
                div_dominates = true;
                inst_move_before_dbg(e.div, block_terminator(pred_bb));
                changed = true;
                if has_div_rem_op {
                    inst_move_before_dbg(e.rem, block_terminator(pred_bb));
                    continue;
                }
            } else continue;
        }
        if !has_div_rem_op && drp_is_rem_expanded(e) continue;
        if has_div_rem_op {
            if div_dominates drp_move_after(e.rem, e.div);
            else drp_move_after(e.div, e.rem);
        } else {
            x := op(e.div, 0); y := op(e.div, 1);
            mul := create_binop(.MUL, e.div, y);
            sub := create_binop(.SUB, x, mul);
            if !div_dominates inst_move_before_dbg(e.div, e.rem);
            drp_insert_after(mul, e.rem);
            copy_debug_loc(mul, e.rem);
            drp_insert_after(sub, mul);
            copy_debug_loc(sub, e.rem);
            drop_poison_generating_flags(e.div);
            if !is_guaranteed_not_to_be_undef(x, null, e.div, dt) {
                fr := new_inst(.FREEZE, vtype(x), 1);
                set_op(fr, 0, x);
                insert_at_position(fr, inst_block(e.div), e.div, false);
                set_name(fr, tconcat(vname(x), ".frozen"));
                copy_debug_loc(fr, e.div);
                set_op(e.div, 0, fr);
                set_op(sub, 0, fr);
            }
            if !is_guaranteed_not_to_be_undef(y, null, e.div, dt) {
                fr := new_inst(.FREEZE, vtype(y), 1);
                set_op(fr, 0, y);
                insert_at_position(fr, inst_block(e.div), e.div, false);
                set_name(fr, tconcat(vname(y), ".frozen"));
                copy_debug_loc(fr, e.div);
                set_op(e.div, 1, fr);
                set_op(mul, 1, fr);
            }
            set_name(sub, tconcat(vname(e.rem), ".decomposed"));
            orig := e.rem;
            e.rem = sub;
            rauw_with_metadata(orig, sub);
            erase_inst_with_metadata(orig);
        }
        changed = true;
    }
    if !changed return PRESERVE_ALL;
    return preserved_cfg();
}
