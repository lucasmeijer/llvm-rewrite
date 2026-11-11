// SLPVectorizer: vectorizeTree() (the whole tree: scheduling, postponed gathers, extraction for external users,
// shuffled insertelement users, removal of the vectorized scalars), optimizeGatherSequence,
// removeInstructionsAndOperands and ~BoUpSLP. Ported from llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp
// (BoUpSLP::vectorizeTree(ExternallyUsedValues, ReductionRoot, VectorValuesAndScales), performExtractsShuffleAction
// <Value>, optimizeGatherSequence, removeInstructionsAndOperands, ~BoUpSLP) and Instruction::mergeDIAssignID
// (llvm/lib/IR/DebugInfo.cpp).

// removeFromParent(): the instruction stays alive (its debug records move to the next instruction)
slp_remove_from_parent :: (i: Value_Id) {
    if inst_block(i) == NONE return;
    if ir.v_name[i].count set_name(i, "");   // the symbol table forgets the name
    if inst(i).records {
        nx := inst_next(i);
        if nx == NONE fatal("slp-vectorizer: removing a terminator with debug records");
        records_prepend(nx, records_take(i));
    }
    inst_unlink(i);
}

Shuffled_Insert :: struct {
    inserts: [..] Value_Id;                 // InsertElements
    vm_keys: [..] Value_Id;                 // MapVector<Value *, SmallVector<int>> ValueMasks
    vm_masks: [..] [..] s32;
}
Slp_Ee_Entry :: struct { scalar: Value_Id; bb: Value_Id; ex: Value_Id; exv: Value_Id; }   // ScalarToEEs[Scalar][BB]

// vectorizeTree(): ExternallyUsedValues empty, no reduction root
slp_vectorize_tree :: () { slp_vectorize_tree_full(NONE, .[]); }

// vectorizeTree(ExternallyUsedValues, ReductionRoot, VectorValuesAndScales); `vector_values` are the vectors of
// VectorValuesAndScales
slp_vectorize_tree_full :: (rdx_root: Value_Id, vector_values: [] Value_Id) -> Value_Id {
    table_reset(*slpx.entry_to_last_instruction);
    for slpx.block_schedules bs_schedule_block(it);
    for te: 0..cast(Te_Id) slp.entries.count-1 {
        e := *slp.entries[te];
        c := e.combined_op;
        if te_is_gather(te) || table_contains(*slp.deleted_nodes, te) ||
           (e.state == TE_COMBINED_VECTORIZE && (c == TE_REDUCED_BITCAST || c == TE_REDUCED_BITCAST_BSWAP ||
            ((c == TE_REDUCED_BITCAST_LOADS || c == TE_REDUCED_BITCAST_BSWAP_LOADS || c == TE_REDUCED_CMP_BITCAST) &&
             (!te_has_state(te) || te_opcode(te) != .LOAD)))) continue;
        slp_last_instruction_in_bundle(te);
    }
    entry := fn_entry(slp.f);
    if rdx_root != NONE sgb_set_before(rdx_root);
    else sgb_set_at(entry, block_first(entry), true);
    // vectorize the gather operands of nodes whose scalars are all used outside their block
    Gather_Entry :: struct { te: Te_Id; last: Value_Id; }
    gather_entries: [..] Gather_Entry; gather_entries.allocator = temp;
    cache_keys: [..] Te_Id; cache_keys.allocator = temp; cache_vals: [..] bool; cache_vals.allocator = temp;
    for te: 0..cast(Te_Id) slp.entries.count-1 {
        if table_contains(*slp.deleted_nodes, te) continue;
        e := *slp.entries[te];
        ut := e.user_tree_index.user;
        if !(te_is_gather(te) && te_vv(te) == NONE && ut != TE_NONE && te_has_state(ut) && slp.entries[ut].state == TE_VECTORIZE &&
             (te_opcode(ut) != .PHI || is_alt_shuffle(slp.entries[ut].s)) && !slp_te_has_copyables(ut)) continue;
        ki := -1; for cache_keys if it == ut { ki = it_index; break; }
        if ki < 0 {
            all := true;
            for v: slp.entries[ut].scalars if !slp_is_used_outside_block(v) { all = false; break; }
            array_add(*cache_keys, ut); array_add(*cache_vals, all);
            ki = cache_keys.count - 1;
        }
        if !cache_vals[ki] continue;
        array_add(*gather_entries, .{te, slp_last_instruction_in_bundle(ut)});
    }
    for ge: gather_entries {
        saved := slpg.b;
        sgb_set_before(ge.last);
        slpg.b.dbg = get_metadata(ge.last, 0);
        slp_vectorize_tree_entry(ge.te);
        slpg.b = saved;
    }
    // gathered loads first
    for te: 0..cast(Te_Id) slp.entries.count-1 {
        if table_contains(*slp.deleted_nodes, te) continue;
        e := *slp.entries[te];
        if slpx.gathered_loads_first >= 0 && e.idx >= slpx.gathered_loads_first && te_vv(te) == NONE &&
           (!te_is_gather(te) || e.user_tree_index.user != TE_NONE)
            slp_vectorize_tree_entry(te);
    }
    slp_vectorize_tree_entry(0);
    // postponed gathers
    pv_keys: [..] Value_Id; pv_keys.allocator = temp;     // PostponedValues
    pv_lists: [..] [..] Te_Id; pv_lists.allocator = temp;
    pi := 0;
    while pi < slpg.postponed_gathers.count {
        te := slpg.postponed_gathers[pi];
        pi += 1;
        prev_vec := te_vv(te);
        te_set_vv(te, NONE);
        ut := slp.entries[te].user_tree_index.user;
        user_i := te_vv(ut);
        if inst_op(user_i) == .PHI || (te_has_state(ut) && slp.entries[ut].state != TE_SPLIT_VECTORIZE && te_opcode(ut) == .PHI) {
            insert_pt := block_terminator(inst_block(prev_vec));
            u := ir.v_first_use[prev_vec];
            while u != NONE {
                usr := ir.u_user[u]; u = ir.u_next[u];
                if usr == user_i continue;
                if !is_inst(usr) || inst_op(usr) == .PHI || inst_block(usr) != inst_block(insert_pt) continue;
                if comes_before(usr, insert_pt) insert_pt = usr;
            }
            sgb_set_before(insert_pt);
        } else {
            sgb_set_before(prev_vec);
        }
        slpg.b.dbg = get_metadata(user_i, 0);
        vec := slp_vectorize_tree_entry(te);
        if is_inst(vec) && inst_block(vec) == slpg.b.bb && slpg.b.pt != NONE && comes_before(slpg.b.pt, vec)
            inst_move_before(vec, slpg.b.pt);
        if vtype(vec) != vtype(prev_vec) {
            has_signed := false; is_signed := false;
            for v: slp.entries[te].scalars {
                if !slp_is_vectorized(v) continue;
                for mnte: slp_get_tree_entries(v) {
                    found, bw := slp_min_bw_of(mnte);
                    if found { is_signed = is_signed || bw.signed; has_signed = true; if is_signed break; }
                }
                if has_signed && is_signed break;
                p := table_find_pointer(*slpx.value_to_gather_nodes, v);
                if p for bve: p.* {
                    found, bw := slp_min_bw_of(bve);
                    if found { is_signed = is_signed || bw.signed; has_signed = true; if is_signed break; }
                }
                if has_signed && is_signed break;
                if is_inst(v) && inst_op(v) == .EXTRACTELEMENT {
                    is_signed = is_signed || !is_known_non_negative(op(v, 0), slp_simple_query());
                    has_signed = true;
                    continue;
                }
                if has_signed && is_signed break;
            }
            if has_signed && is_signed {
                found, bw := slp_min_bw_of(ut);
                if found is_signed = bw.signed;
            }
            if !has_signed fatal("internal: slp: postponed gather of a different type without a signedness");
            vec = sgb_int_cast(vec, vtype(prev_vec), is_signed);
        }
        replace_all_uses_with(prev_vec, vec);
        ki := -1; for pv_keys if it == vec { ki = it_index; break; }
        if ki < 0 { array_add(*pv_keys, vec); l: [..] Te_Id; l.allocator = temp; array_add(*pv_lists, l); ki = pv_keys.count - 1; }
        array_add(*pv_lists[ki], te);
        for pv_keys if it == prev_vec { for vte: pv_lists[it_index] te_set_vv(vte, vec); break; }
        slp_erase_instruction(prev_vec);
    }

    // extract all of the elements with external uses
    shuffled_inserts: [..] Shuffled_Insert; shuffled_inserts.allocator = temp;
    scalar_to_ees: [..] Slp_Ee_Entry; scalar_to_ees.allocator = temp;
    used_inserts: [..] Value_Id; used_inserts.allocator = temp;
    Vec_Cast :: struct { vec: Value_Id; ty: Type_Id; res: Value_Id; }
    vector_casts: [..] Vec_Cast; vector_casts.allocator = temp;
    scalars_with_nullptr_user: [..] Value_Id; scalars_with_nullptr_user.allocator = temp;
    ignored_extracts: [..] Value_Id; ignored_extracts.allocator = temp;
    for eu_idx: 0..slpx.external_uses.count-1 {
        eu := slpx.external_uses[eu_idx];
        scalar := eu.scalar;
        user := eu.user;
        if user != NONE && !slp_value_has_user(scalar, user) continue;
        te := eu.te;
        if te_opcode(te) == .GEP && !(is_inst(scalar) && inst_op(scalar) == .GEP) continue;
        vec := te_vv(te);
        if user == NONE {
            if slp_has(scalars_with_nullptr_user, scalar) continue;
            array_add(*scalars_with_nullptr_user, scalar);
            if is_inst(vec) {
                if inst_op(vec) == .PHI {
                    bb := inst_block(vec);
                    if is_landing_pad_block(bb) { lp := block_first_non_phi(bb); sgb_set_at(bb, inst_next(lp)); }
                    else sgb_set_at(bb, block_first_non_phi(bb), true);
                } else {
                    sgb_set_at(inst_block(vec), inst_next(vec));
                }
            } else {
                sgb_set_at(entry, block_first(entry), true);
            }
            new_inst := slp_extract_and_extend(scalar, user, vec, eu.lane, *scalar_to_ees, *ignored_extracts);
            if scalar != new_inst replace_all_uses_with(scalar, new_inst);
            continue;
        }
        if is_inst(user) && inst_op(user) == .INSERTELEMENT && op(user, 1) == scalar {
            vu := user;
            if !is_vector_type(vtype(scalar)) && is_inst(vec) && type_kind(vtype(user)) == .VECTOR {
                fty := vtype(user);
                if slp_has(used_inserts, vu) continue;
                array_add(*used_inserts, vu);
                found_bw, bw := slp_min_bw_of(te);
                if found_bw && vtype(vec) != vtype(vu) {
                    esty := type_elem(fty);
                    ci := -1; for vector_casts if it.vec == vec && it.ty == esty { ci = it_index; break; }
                    if ci < 0 {
                        saved := slpg.b;
                        if inst_op(vec) == .PHI {
                            bb := inst_block(vec);
                            if is_landing_pad_block(bb) { lp := block_first_non_phi(bb); sgb_set_at(bb, inst_next(lp)); }
                            else sgb_set_at(bb, block_first_non_phi_or_dbg_or_lifetime(bb));
                        } else sgb_set_before(inst_next(vec));
                        orig_vec := vec;
                        vec = sgb_int_cast(vec, slp_widened_type(esty, type_count(vtype(vec))), bw.signed);
                        array_add(*vector_casts, .{orig_vec, esty, vec});
                        slpg.b = saved;
                    } else vec = vector_casts[ci].res;
                }
                ok, insert_idx := slp_element_index(vu);
                if ok {
                    si := -1;
                    for * d: shuffled_inserts if slp_are_two_insert_from_same_build_vector(vu, d.inserts[0], true) { si = it_index; break; }
                    if si < 0 {
                        d: Shuffled_Insert;
                        d.inserts.allocator = temp; d.vm_keys.allocator = temp; d.vm_masks.allocator = temp;
                        array_add(*shuffled_inserts, d);
                        si = shuffled_inserts.count - 1;
                    }
                    d := *shuffled_inserts[si];
                    mi := -1; for d.vm_keys if it == vec { mi = it_index; break; }
                    if mi < 0 { array_add(*d.vm_keys, vec); array_add(*d.vm_masks, new_mask()); mi = d.vm_keys.count - 1; }
                    if d.vm_masks[mi].count == 0 d.vm_masks[mi] = new_mask(cast(s64) type_count(fty));
                    d.vm_masks[mi][insert_idx] = cast(s32) eu.lane;
                    array_add(*d.inserts, user);
                    continue;
                }
            }
        }
        if is_inst(vec) {
            if is_inst(user) && inst_op(user) == .PHI {
                ph := user;
                for i: 0..phi_num_incoming(ph)-1 {
                    if phi_value(ph, i) != scalar continue;
                    term := block_terminator(phi_block(ph, i));
                    if inst_op(term) == .CATCHSWITCH sgb_set_at(inst_block(vec), inst_next(vec));
                    else sgb_set_before(term);
                    new_inst := slp_extract_and_extend(scalar, user, vec, eu.lane, *scalar_to_ees, *ignored_extracts);
                    phi_set_value(ph, i, new_inst);
                }
            } else {
                sgb_set_before(user);
                new_inst := slp_extract_and_extend(scalar, user, vec, eu.lane, *scalar_to_ees, *ignored_extracts);
                replace_uses_of_with(user, scalar, new_inst);
            }
        } else {
            sgb_set_at(entry, block_first(entry), true);
            new_inst := slp_extract_and_extend(scalar, user, vec, eu.lane, *scalar_to_ees, *ignored_extracts);
            replace_uses_of_with(user, scalar, new_inst);
        }
    }

    // shuffles of the vectorized tree entries for the external insertelement users
    for * d: shuffled_inserts {
        // sort(InsertElements, isFirstInsertElement)
        for i: 1..d.inserts.count-1 {
            x := d.inserts[i];
            j := i - 1;
            while j >= 0 && slp_is_first_insert_element(x, d.inserts[j]) { d.inserts[j + 1] = d.inserts[j]; j -= 1; }
            d.inserts[j + 1] = x;
        }
        first_insert := d.inserts[0];
        last_insert := d.inserts[d.inserts.count - 1];
        sgb_set_before(last_insert);
        new_inst := slp_perform_extracts_shuffle_ir(d.vm_keys, d.vm_masks, op(first_insert, 0));
        // rebuild the buildvector chain
        k := d.inserts.count - 1;
        ii := ifx k >= 0 then d.inserts[k] else NONE;
        inserts: [..] Value_Id; inserts.allocator = temp;
        while k >= 0 {
            if d.inserts[k] == ii k -= 1;
            else array_add(*inserts, ii);
            o := op(ii, 0);
            ii = ifx is_inst(o) && inst_op(o) == .INSERTELEMENT then o else NONE;
        }
        for < x: inserts {
            replace_uses_of_with(x, op(x, 0), new_inst);
            if is_inst(new_inst) && inst_block(x) == inst_block(new_inst) && comes_before(x, new_inst) inst_move_after_head(x, new_inst);
            new_inst = x;
        }
        replace_all_uses_with(last_insert, new_inst);
        for < ie: d.inserts {
            replace_uses_of_with(ie, op(ie, 0), const_poison(vtype(op(ie, 0))));
            replace_uses_of_with(ie, op(ie, 1), const_poison(vtype(op(ie, 1))));
            slp_erase_instruction(ie);
        }
        slpg_add_cse_block(inst_block(last_insert));
    }

    removed: [..] Value_Id; removed.allocator = temp;
    for te: 0..cast(Te_Id) slp.entries.count-1 {
        e := *slp.entries[te];
        if te_is_gather(te) || e.state == TE_SPLIT_VECTORIZE || table_contains(*slp.deleted_nodes, te) ||
           table_contains(*slp.transformed_to_gather_nodes, te) continue;
        if e.combined_op >= TE_REDUCED_BITCAST {
            if !te_has_state(te) continue;
            for v: e.scalars if is_inst(v) && !slp_te_is_copyable(te, v) array_add(*removed, v);
            continue;
        }
        for scalar: e.scalars {
            if te_opcode(te) == .GEP && !(is_inst(scalar) && inst_op(scalar) == .GEP) continue;
            if is_inst(scalar) && inst_op(scalar) == .EXTRACTELEMENT && slp_has(ignored_extracts, scalar) continue;
            if !is_inst(scalar) || slp_te_is_copyable(te, scalar) continue;
            array_add(*removed, scalar);
        }
    }
    // tree-entry vectors left without any live use
    {
        root_vec := te_vv(0);
        dead_set: Table(Value_Id, bool); dead_set.allocator = temp;
        for removed table_set(*dead_set, it, true);
        candidates: Table(Value_Id, bool); candidates.allocator = temp;
        worklist: [..] Value_Id; worklist.allocator = temp;
        for te: 0..cast(Te_Id) slp.entries.count-1 {
            vv := te_vv(te);
            if vv == NONE || vv == root_vec || vtype(vv) == ir.t_void || table_contains(*dead_set, vv) || !is_inst(vv) continue;
            if !table_contains(*candidates, vv) { table_set(*candidates, vv, true); array_add(*worklist, vv); }
        }
        while worklist.count {
            i := pop(*worklist);
            if table_contains(*dead_set, i) continue;
            all_dead := true;
            u := ir.v_first_use[i];
            while u != NONE { if !table_contains(*dead_set, ir.u_user[u]) { all_dead = false; break; } u = ir.u_next[u]; }
            if !all_dead continue;
            table_set(*dead_set, i, true);
            array_add(*removed, i);
            for k: 0..cast(s64) nops(i) - 1 {
                o := op(i, cast(u32) k);
                if is_inst(o) && table_contains(*candidates, o) && !table_contains(*dead_set, o) array_add(*worklist, o);
            }
        }
    }
    if is_inst(te_vv(0)) slp_merge_di_assign_id(te_vv(0), removed);
    if slpx.has_user_ignore_list {
        root := *slp.entries[0];
        for i: removed {
            entries := slp_get_tree_entries(i);
            if entries.count == 0 continue;
            ie := entries[0];
            split := slp_get_split_tree_entries(i);
            if split.count && split[0] < ie ie = split[0];
            iee := *slp.entries[ie];
            keep := ie != 0;
            if keep && te_is_gather(0) && iee.user_tree_index.user != TE_NONE {
                p := table_find_pointer(*slpx.value_to_gather_nodes, i);
                in_g := p && slp_has(p.*, 0);
                if in_g || (iee.user_tree_index.user == 0 && iee.user_tree_index.edge == EDGE_NONE) keep = false;
            }
            if keep && root.state == TE_SPLIT_VECTORIZE && iee.user_tree_index.user != TE_NONE && slp_has(root.scalars, i) keep = false;
            if keep && slpx.gathered_loads_first >= 0 && ie >= slpx.gathered_loads_first && te_is_gather(0) && slp_has(root.scalars, i) keep = false;
            if keep && !te_is_gather(0) && slp_te_is_copyable(0, i) keep = false;
            if keep continue;
            logical_selects: [..] Value_Id; logical_selects.allocator = temp;
            u := ir.v_first_use[i];
            while u != NONE {
                usr := ir.u_user[u];
                nx := ir.u_next[u];
                if is_inst(usr) && inst_op(usr) == .SELECT && use_operand_no(u) == 0 && (pm_logical_and(usr) || pm_logical_or(usr)) {
                    array_add(*logical_selects, usr);
                } else if slp_in_user_ignore_list(usr) {
                    use_set(u, const_poison(vtype(i)));
                }
                u = nx;
            }
            for si: logical_selects set_op(si, 0, const_null_value(vtype(op(si, 0))));
        }
    }
    slp_remove_instructions_and_operands(removed, vector_values);
    slpg.b.bb = NONE; slpg.b.pt = NONE;   // ClearInsertionPoint
    table_reset(*slpx.instr_element_size);
    #if DEBUG_SLP print("DBG IR after vectorizeTree:\n%\n", print_module());
    vec := te_vv(0);
    found, bw := slp_min_bw_of(0);
    if slpx.reduction_bit_width != 0 && found && slpx.reduction_bit_width != bw.bits {
        saved := slpg.b;
        sgb_set_before(rdx_root);
        if slp_is_reduced_bitcast_root() || slp_is_reduced_cmp_bitcast_root() vec = sgb_int_cast(vec, type_int(cast(u32) slpx.reduction_bit_width), bw.signed);
        else vec = sgb_int_cast(vec, type_vector(type_count(vtype(vec)), type_int(cast(u32) slpx.reduction_bit_width), false), bw.signed);
        slpg.b = saved;
    }
    return vec;
}

// is_contained(Scalar->users(), User)
slp_value_has_user :: (v: Value_Id, user: Value_Id) -> bool {
    u := ir.v_first_use[v];
    while u != NONE { if ir.u_user[u] == user return true; u = ir.u_next[u]; }
    return false;
}

// BasicBlock::getFirstNonPHIOrDbgOrLifetime (pseudo probes skipped)
block_first_non_phi_or_dbg_or_lifetime :: (bb: Value_Id) -> Value_Id {
    for i: block_insts(bb) {
        if inst_op(i) == .PHI continue;
        id := call_iid(i);
        if id == IID_LIFETIME_START || id == IID_LIFETIME_END || id == IID_PSEUDOPROBE continue;
        return i;
    }
    return NONE;
}

// moveAfter(Pos): right after Pos, before the debug records of the next instruction; its records stay behind
inst_move_after_head :: (i: Value_Id, pos: Value_Id) {
    nx := inst_next(pos);
    if nx == NONE {
        if inst(i).records { n2 := inst_next(i); if n2 != NONE records_prepend(n2, records_take(i)); }
        inst_unlink(i);
        block_append_inst(inst_block(pos), i);
        return;
    }
    slp_move_before_head(i, nx);
}

// the ExtractAndExtendIfNeeded lambda of vectorizeTree
slp_extract_and_extend :: (scalar: Value_Id, user: Value_Id, vec: Value_Id, lane: u32, scalar_to_ees: *[..] Slp_Ee_Entry, ignored_extracts: *[..] Value_Id) -> Value_Id {
    if is_inst(scalar) && inst_op(scalar) == .INSERTVALUE return vec;
    if vtype(scalar) != vtype(vec) {
        ex: Value_Id = NONE; exv: Value_Id = NONE;
        replace_inst := is_inst(scalar) && slp_has(slpx.external_uses_as_original_scalar, scalar);
        if type_kind(vtype(scalar)) == .STRUCT slp_fail("external uses of struct-typed scalars");
        bb := ifx replace_inst then inst_block(scalar) else slpg.b.bb;
        for * x: scalar_to_ees.* {
            if x.scalar != scalar || x.bb != bb continue;
            prev_v := x.ex;
            if is_inst(prev_v) && !replace_inst && slpg.b.pt != NONE && inst_block(prev_v) == slpg.b.bb && comes_before(slpg.b.pt, prev_v) {
                inst_move_before_dbg(prev_v, slpg.b.pt);
                if is_inst(x.exv) && x.exv != prev_v inst_move_after_head(x.exv, prev_v);
            }
            ex = prev_v;
            exv = ifx x.exv != NONE then x.exv else ex;
            break;
        }
        if ex == NONE {
            if replace_inst {
                if inst_op(scalar) == .EXTRACTELEMENT {
                    array_add(ignored_extracts, scalar);
                    ex = scalar;
                } else {
                    c := inst_clone(scalar);
                    inst_insert_before(c, scalar);
                    if ir.v_name[scalar].count take_name(c, scalar);
                    ex = c;
                }
            } else if is_inst(scalar) && inst_op(scalar) == .EXTRACTELEMENT && is_inst(vec) {
                v := op(scalar, 0);
                etes := slp_get_tree_entries(v);
                if etes.count v = te_vv(etes[0]);
                if !is_inst(v) || v == vec || inst_block(v) != inst_block(vec) || comes_before(v, vec) ex = sgb_extract_element_v(v, op(scalar, 1));
                else ex = sgb_extract_element(vec, cast(u64) lane);
            } else if is_vector_type(vtype(scalar)) {
                slp_fail("REVEC extracts");
            } else {
                if type_kind(vtype(vec)) == .STRUCT slp_fail("external uses of struct-typed scalars");
                ex = sgb_extract_element(vec, cast(u64) lane);
            }
            exv = ex;
            if vtype(scalar) != vtype(ex) exv = sgb_int_cast(ex, vtype(scalar), !is_known_non_negative(scalar, slp_simple_query()));
            key_bb := ifx is_inst(ex) then inst_block(ex) else fn_entry(slp.f);
            dup := false;
            for scalar_to_ees.* if it.scalar == scalar && it.bb == key_bb { dup = true; break; }
            if !dup array_add(scalar_to_ees, .{scalar, key_bb, ex, exv});
        }
        if is_inst(ex) && inst_op(ex) != .PHI && !may_have_non_def_use_dependency(ex) slpg_record(ex);
        return exv;
    }
    return vec;   // an insertelement scalar of vector type (VectorToInsertElement is not used)
}

// performExtractsShuffleAction<Value>(ShuffleMask, Base, GetVF, ResizeToVF, Action) with the vectorizeTree lambdas
slp_perform_extracts_shuffle_ir :: (keys: [] Value_Id, masks: [] [..] s32, base: Value_Id) -> Value_Id {
    // CreateShuffle(V1, V2, Mask)
    create_shuffle :: (v1: Value_Id, v2: Value_Id, mask: [] s32) -> Value_Id {
        cm1 := new_mask(mask.count); cm2 := new_mask(mask.count);
        vf := cast(s64) type_count(vtype(v1));
        for i: 0..mask.count-1 {
            if mask[i] < vf cm1[i] = mask[i];
            else cm2[i] = mask[i] - cast(s32) vf;
        }
        b: Bv_Builder;
        bv_init_ir(*b, type_elem(vtype(v1)));
        sib_add_v(*b, v1, cm1);
        if v2 != NONE sib_add_v(*b, v2, cm2);
        return sib_finalize(*b, .[], .[], .[]);
    }
    // ResizeToVF(Vec, Mask, ForSingleMask): (vec, identity found)
    resize_to_vf :: (vec_in: Value_Id, mask: [] s32, for_single: bool) -> (Value_Id, bool) {
        vec := vec_in;
        vf := mask.count;
        vec_vf := cast(s64) type_count(vtype(vec));
        if vf != vec_vf {
            any := false; for mask if it >= cast(s32) vf { any = true; break; }
            if any return create_shuffle(vec, NONE, mask), true;
            if !for_single {
                rm := new_mask(vf);
                for i: 0..vf-1 if mask[i] != PME rm[mask[i]] = mask[i];
                vec = create_shuffle(vec, NONE, rm);
            }
        }
        return vec, false;
    }
    // Action(Mask, Vals)
    action :: (mask: [] s32, v0: Value_Id, v1: Value_Id, two: bool, first_insert_op0: Value_Id) -> Value_Id {
        if !two {
            if mask.count != cast(s64) type_count(vtype(v0)) || !svm_is_identity(mask, mask.count) return create_shuffle(v0, NONE, mask);
            return v0;
        }
        return create_shuffle(ifx v0 != NONE then v0 else first_insert_op0, v1, mask);
    }
    mask := mask_copy(masks[0]);
    vmi := 1;
    prev: Value_Id = NONE;
    use_mask := slp_build_use_mask(mask.count, mask, SLP_USE_MASK_UNDEFS_AS_MASK);
    base_undef := slp_is_undef_vector(base, use_mask);
    if !all_bits(base_undef) {
        r, rs := resize_to_vf(keys[0], mask, false);
        base_poison := slp_is_undef_vector(base, use_mask, true);
        vf := mask.count;
        for idx: 0..vf-1 {
            if mask[idx] == PME mask[idx] = ifx base_poison[idx] then PME else cast(s32) idx;
            else mask[idx] = (ifx rs then cast(s32) idx else mask[idx]) + cast(s32) vf;
        }
        prev = action(mask, NONE, r, true, base);
    } else if keys.count == 1 {
        r, rs := resize_to_vf(keys[0], mask, true);
        if rs prev = r;
        else prev = action(mask, keys[0], NONE, false, base);
    } else {
        v1vf := cast(s64) type_count(vtype(keys[0]));
        v2vf := cast(s64) type_count(vtype(keys[1]));
        if v1vf == v2vf {
            sec := masks[1];
            for i: 0..mask.count-1 if sec[i] != PME mask[i] = sec[i] + cast(s32) v1vf;
            prev = action(mask, keys[0], keys[1], true, base);
        } else {
            r1, rs1 := resize_to_vf(keys[0], mask, false);
            r2, rs2 := resize_to_vf(keys[1], masks[1], false);
            sec := masks[1];
            vf := mask.count;
            for i: 0..vf-1 {
                if mask[i] != PME { if rs1 mask[i] = cast(s32) i; }
                else if sec[i] != PME mask[i] = (ifx rs2 then cast(s32) i else sec[i]) + cast(s32) vf;
            }
            prev = action(mask, r1, r2, true, base);
        }
        vmi = 2;
    }
    while vmi < keys.count {
        r, rs := resize_to_vf(keys[vmi], masks[vmi], false);
        sec := masks[vmi];
        vf := mask.count;
        for i: 0..vf-1 {
            if sec[i] != PME mask[i] = (ifx rs then cast(s32) i else sec[i]) + cast(s32) vf;
            else if mask[i] != PME mask[i] = cast(s32) i;
        }
        prev = action(mask, prev, r, true, base);
        vmi += 1;
    }
    return prev;
}

// Instruction::mergeDIAssignID(SourceInstructions)
slp_merge_di_assign_id :: (i: Value_Id, sources: [] Value_Id) {
    kind := md_kind_id("DIAssignID");
    ids: [..] Md_Id; ids.allocator = temp;
    for sources { m := get_metadata(it, kind); if m != NONE array_add(*ids, m); }
    m := get_metadata(i, kind); if m != NONE array_add(*ids, m);
    if ids.count == 0 return;
    merge := ids[0];
    for ids {
        if it_index == 0 || it == merge continue;
        old := it;
        for bb: fn_blocks(slp.f) for x: block_insts(bb) if get_metadata(x, kind) == old set_metadata(x, kind, merge);
        for sources if get_metadata(it, kind) == old set_metadata(it, kind, merge);
        for * r: ir.dbg_records if r.assign_id == old r.assign_id = merge;
    }
    set_metadata(i, kind, merge);
}

// removeInstructionsAndOperands(DeadVals, VectorValuesAndScales)
slp_remove_instructions_and_operands :: (dead_vals: [] Value_Id, vector_values: [] Value_Id) {
    dead_insts: [..] Value_Id; dead_insts.allocator = temp;
    for dead_vals slp_erase_instruction(it);
    processed: Table(Value_Id, bool); processed.allocator = temp;
    for i: dead_vals {
        if i == NONE || table_contains(*processed, i) continue;
        table_set(*processed, i, true);
        salvage_debug_info(i);
        entries := slp_get_tree_entries(i);
        for k: 0..cast(s64) nops(i) - 1 {
            o := op(i, cast(u32) k);
            if !is_inst(o) || slp_is_deleted(o) || !has_one_user(o) || !would_instruction_be_trivially_dead(o) continue;
            bad := false;
            for en: entries if te_vv(en) == o { bad = true; break; }
            if !bad array_add(*dead_insts, o);
        }
        drop_all_references(i);
    }
    for i: dead_vals {
        if inst_block(i) == NONE continue;
        slp_remove_from_parent(i);
        sc_forget_value(i);
    }
    while dead_insts.count {
        vi := pop(*dead_insts);
        if vkind(vi) == .DEAD || inst_block(vi) == NONE continue;
        salvage_debug_info(vi);
        for k: 0..cast(s64) nops(vi) - 1 {
            o := op(vi, cast(u32) k);
            if o == NONE continue;
            set_op(vi, cast(u32) k, NONE);
            if has_uses(o) continue;
            if is_inst(o) && !slp_is_deleted(o) && (!is_vector_type(vtype(o)) || !slp_has(vector_values, o)) && is_instruction_trivially_dead(o)
                array_add(*dead_insts, o);
        }
        slp_remove_from_parent(vi);
        slp_erase_instruction(vi);
        sc_forget_value(vi);
    }
}

// optimizeGatherSequence()
slp_optimize_gather_sequence :: () {
    for i: slpg.gather_seq {
        if slp_is_deleted(i) continue;
        l := li_loop_for(slp.li, inst_block(i));
        if l == NONE continue;
        ph := li_loop_preheader(slp.li, l);
        if ph == NONE continue;
        bad := false;
        for k: 0..cast(s64) nops(i) - 1 {
            o := op(i, cast(u32) k);
            if is_inst(o) && li_contains_inst(slp.li, l, o) { bad = true; break; }
        }
        if bad continue;
        inst_move_before_dbg(i, block_terminator(ph));
        slpg_add_cse_block(ph);
    }
    work: [..] Value_Id; work.allocator = temp;
    for bb: slpg.cse_blocks if dt_is_reachable_from_entry(slp.dt, bb) array_add(*work, bb);
    // sort by DFS-in number
    for i: 1..work.count-1 {
        x := work[i];
        j := i - 1;
        while j >= 0 && dt_dfs_in(slp.dt, work[j]) > dt_dfs_in(slp.dt, x) { work[j + 1] = work[j]; j -= 1; }
        work[j + 1] = x;
    }
    // IsIdenticalOrLessDefined(I1, I2, NewMask): (result, new mask)
    identical_or_less_defined :: (i1: Value_Id, i2: Value_Id, new_mask: *[..] s32) -> bool {
        if vtype(i1) != vtype(i2) return false;
        if inst_op(i1) != .SHUFFLEVECTOR || inst_op(i2) != .SHUFFLEVECTOR return slp_is_identical_to(i1, i2);
        if slp_is_identical_to(i1, i2) return true;
        for k: 0..cast(s64) nops(i1) - 1 if op(i1, cast(u32) k) != op(i2, cast(u32) k) return false;
        new_mask.* = mask_copy(shuffle_mask_s32(i2));
        sm1 := shuffle_mask_s32(i1);
        last_undefs := 0;
        for i: 0..new_mask.count-1 {
            if sm1[i] == PME last_undefs += 1;
            else last_undefs = 0;
            if new_mask.*[i] != PME && sm1[i] != PME && new_mask.*[i] != sm1[i] return false;
            if new_mask.*[i] == PME new_mask.*[i] = sm1[i];
        }
        ety := type_elem(vtype(i1));
        return sm1.count - last_undefs > 1 &&
               slp_number_of_parts(slp.tti, vtype(i1), ety) == slp_number_of_parts(slp.tti, slp_widened_type(ety, cast(u64) (sm1.count - last_undefs)), ety);
    }
    visited: [..] Value_Id; visited.allocator = temp;
    for bb: work {
        in := block_first(bb);
        while in != NONE {
            nx := inst_next(in);
            defer in = nx;
            if slp_is_deleted(in) continue;
            o := inst_op(in);
            if !(o == .INSERTELEMENT || o == .EXTRACTELEMENT || o == .SHUFFLEVECTOR) && !table_contains(*slpg.gather_seq_set, in) continue;
            replaced := false;
            for * vp: visited {
                v := vp.*;
                nm := new_mask();
                if identical_or_less_defined(in, v, *nm) && dt_dominates(slp.dt, inst_block(v), inst_block(in)) {
                    replace_all_uses_with(in, v);
                    slp_erase_instruction(in);
                    if inst_op(v) == .SHUFFLEVECTOR && nm.count slp_set_shuffle_mask(v, nm);
                    replaced = true;
                    break;
                }
                nm = new_mask();
                if o == .SHUFFLEVECTOR && inst_op(v) == .SHUFFLEVECTOR && table_contains(*slpg.gather_seq_set, v) &&
                   identical_or_less_defined(v, in, *nm) && dt_dominates(slp.dt, inst_block(in), inst_block(v)) {
                    inst_move_after_head(in, v);
                    replace_all_uses_with(v, in);
                    slp_erase_instruction(v);
                    if nm.count slp_set_shuffle_mask(in, nm);
                    vp.* = in;
                    replaced = true;
                    break;
                }
            }
            if !replaced array_add(*visited, in);
        }
    }
    array_reset_keeping_memory(*slpg.cse_blocks);
    array_reset_keeping_memory(*slpg.gather_seq);
    table_reset(*slpg.gather_seq_set);
}

// Instruction::isIdenticalTo
slp_is_identical_to :: (a: Value_Id, b: Value_Id) -> bool { return is_identical_to(a, b); }

// ShuffleVectorInst::setShuffleMask
slp_set_shuffle_mask :: (sv: Value_Id, mask: [] s32) {
    r := inst(sv);
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) mask.count;
    for mask array_add(*ir.u32_pool, ifx it < 0 then 0xFFFF_FFFF else cast(u32) it);
}

// ~BoUpSLP()
slp_finish :: () {
    dead_insts: [..] Value_Id; dead_insts.allocator = temp;
    for i: slpg.deleted_list {
        if inst_block(i) == NONE continue;
        for k: 0..cast(s64) nops(i) - 1 {
            o := op(i, cast(u32) k);
            if is_inst(o) && !slp_is_deleted(o) && has_one_user(o) && would_instruction_be_trivially_dead(o) array_add(*dead_insts, o);
        }
        drop_all_references(i);
    }
    for i: slpg.deleted_list erase_inst(i);
    recursively_delete_trivially_dead_instructions(dead_insts);
    vh_release_all();
}
