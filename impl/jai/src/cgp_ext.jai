// CodeGenPrepare, part 3: port of llvm/lib/CodeGen/CodeGenPrepare.cpp: optimizeGatherScatterInst and
// optimizeMulWithOverflow / optimizeInlineAsmInst (guards: the X86 hooks they need never fire on the corpus' IR or are
// not ported), hasSameExtUse, tryToPromoteExts, mergeSExts, splitLargeGEPOffsets, optimizePhiType(s), canFormExtLd,
// optimizeExt, performAddressTypePromotion, optimizeExtUses, optimizeLoadExt.

// optimizeGatherScatterInst: rewrites the GEP feeding a masked gather / scatter
cgp_optimize_gather_scatter_inst :: (mi: Value_Id, ptr: Value_Id) -> bool {
    if is_inst(ptr) && inst_op(ptr) == .GEP {
        if nops(ptr) <= 1 return false;
        if inst_block(mi) != inst_block(ptr) return false;
    } else {
        if !is_inst(ptr) && !is_const(ptr) return false;   // getSplatValue(Ptr) of an argument is null
    }
    fatal("codegenprepare: optimizeGatherScatterInst is not supported yet");
    return false;
}

// optimizeMulWithOverflow: TLI->shouldOptimizeMulOverflowWithZeroHighBits is false (base; X86 has no override)
cgp_optimize_mul_with_overflow :: (i: Value_Id, is_signed: bool, modified: *Cgp_Modify_Dt) -> bool { return false; }

// optimizeInlineAsmInst: only indirect memory operands ('*' constraints of C_Memory type) are sunk
cgp_optimize_inline_asm_inst :: (cs: Value_Id) -> bool {
    asm := call_callee(cs);
    cons := inline_asm_constraints(asm);
    if find_index_from_left(cons, #char "*") >= 0
        fatal("codegenprepare: inline asm with indirect operands (address sinking into memory constraints) is not supported yet");
    return false;
}

// hasSameExtUse
cgp_has_same_ext_use :: (v: Value_Id) -> bool {
    first_user := ir.u_user[ir.v_first_use[v]];
    is_sext := inst_op(first_user) == .SEXT;
    ext_ty := vtype(first_user);
    u := ir.v_first_use[v];
    while u != NONE {
        ui := ir.u_user[u];
        u = ir.u_next[u];
        if (is_sext && inst_op(ui) != .SEXT) || (!is_sext && inst_op(ui) != .ZEXT) return false;
        cur_ty := vtype(ui);
        if cur_ty == ext_ty continue;
        if is_sext return false;
        narrow, large: Type_Id;
        if type_bits(scalar_type(ext_ty)) > type_bits(scalar_type(cur_ty)) { narrow = cur_ty; large = ext_ty; }
        else { narrow = ext_ty; large = cur_ty; }
        if !cgp_is_zext_free(narrow, large) return false;
    }
    return true;
}

// tryToPromoteExts (X86TargetLowering sets EnableExtLdPromotion)
cgp_try_to_promote_exts :: (exts: [] Value_Id, moved: *[..] Value_Id, created_cost: u32 = 0) -> bool {
    promoted := false;
    for i: exts {
        x := op(i, 0);
        if is_inst(x) && inst_op(x) == .LOAD { array_add(moved, i); continue; }
        if cgp_cl.disable_ext_ld_promotion return false;
        tph := tph_get_action(i);
        if tph == .NONE { array_add(moved, i); continue; }
        last_known_good := tpt_restoration_point();
        new_exts: [..] Value_Id; new_exts.allocator = temp;
        new_cost: u32 = 0;
        ext_cost: u32 = ifx !cgp_is_ext_free(i) then cast(u32) 1 else 0;
        promoted_val := tph_run(tph, i, *new_cost, *new_exts, null);
        total: s64 = cast(s64) created_cost + cast(s64) new_cost;
        total = max(0, total - cast(s64) ext_cost);
        if !cgp_cl.stress_ext_ld_promotion && (total > 1 || !cgp_is_promoted_instruction_legal(promoted_val) || (ext_cost == 0 && new_exts.count > 1)) {
            tpt_rollback(last_known_good);
            array_add(moved, i);
            continue;
        }
        newly_moved: [..] Value_Id; newly_moved.allocator = temp;
        cgp_try_to_promote_exts(new_exts, *newly_moved, cast(u32) total);
        new_promoted := false;
        for moved_ext: newly_moved {
            ext_operand := op(moved_ext, 0);
            if is_inst(ext_operand) && inst_op(ext_operand) == .LOAD &&
               !(cgp_cl.stress_ext_ld_promotion || new_cost <= ext_cost || (has_one_use(ext_operand) || cgp_has_same_ext_use(ext_operand)))
                continue;
            array_add(moved, moved_ext);
            new_promoted = true;
        }
        if !new_promoted {
            tpt_rollback(last_known_good);
            array_add(moved, i);
            continue;
        }
        promoted = true;
    }
    return promoted;
}

// mergeSExts (ValToSExtendedUses is filled by performAddressTypePromotion only)
cgp_merge_sexts :: (f: Value_Id) -> bool {
    changed := false;
    for key: cgp.sext_keys {
        insts := cgp.sext_vals[it_index];
        cur_pts: [..] Value_Id; cur_pts.allocator = temp;
        for inst: insts {
            if table_contains(*cgp_removed_set, inst) || inst_op(inst) != .SEXT || op(inst, 0) != key continue;
            inserted := false;
            for * pt: cur_pts {
                if dt_dominates_inst(cgp_get_dt(), inst, pt.*) {
                    cgp_rauw(pt.*, inst);
                    table_set(*cgp_removed_set, pt.*, true);
                    array_add(*cgp.removed_insts, pt.*);
                    cgp_remove_from_parent(pt.*);
                    pt.* = inst;
                    inserted = true;
                    changed = true;
                    break;
                }
                if !dt_dominates_inst(cgp_get_dt(), pt.*, inst) continue;
                cgp_rauw(inst, pt.*);
                table_set(*cgp_removed_set, inst, true);
                array_add(*cgp.removed_insts, inst);
                cgp_remove_from_parent(inst);
                inserted = true;
                changed = true;
                break;
            }
            if !inserted array_add(*cur_pts, inst);
        }
    }
    return changed;
}

// splitLargeGEPOffsets: LargeOffsetGEPMap is only filled when TLI.shouldConsiderGEPOffsetSplit() (false on X86)
cgp_split_large_gep_offsets :: () -> bool {
    fatal("codegenprepare: splitLargeGEPOffsets is not supported yet");
    return false;
}

// optimizePhiType. The SmallPtrSets (PhiNodes, Defs, Uses, Constants: 4 inline elements) iterate in insertion order
// while small; larger sets iterate in pointer order, which fails loudly.
cgp_optimize_phi_type :: (i: Value_Id, visited: *Table(Value_Id, bool), deleted: *[..] Value_Id) -> bool {
    phi_ty := vtype(i);
    convert_ty: Type_Id = NONE;
    if table_contains(visited, i) || (type_kind(phi_ty) != .INT && !is_fp_type(phi_ty)) return false;
    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add(*worklist, i);
    phi_nodes: [..] Value_Id; phi_nodes.allocator = temp;
    constants: [..] Value_Id; constants.allocator = temp;
    defs: [..] Value_Id; defs.allocator = temp;
    uses: [..] Value_Id; uses.allocator = temp;
    contains :: (l: [] Value_Id, v: Value_Id) -> bool { for l if it == v return true; return false; }
    add :: (l: *[..] Value_Id, v: Value_Id) -> bool { if contains(l.*, v) return false; array_add(l, v); return true; }
    add(*phi_nodes, i);
    table_set(visited, i, true);
    any_anchored := false;
    while worklist.count {
        ii := pop(*worklist);
        if inst_op(ii) == .PHI {
            for k: 0..cast(s64) nops(ii) - 1 {
                v := phi_value(ii, cast(u32) k);
                if is_phi(v) {
                    if !contains(phi_nodes, v) {
                        if table_contains(visited, v) return false;
                        table_set(visited, v, true);
                        add(*phi_nodes, v);
                        array_add(*worklist, v);
                    }
                } else if is_inst(v) && inst_op(v) == .LOAD {
                    if !load_store_is_simple(v) return false;
                    if add(*defs, v) array_add(*worklist, v);
                } else if is_inst(v) && inst_op(v) == .EXTRACTELEMENT {
                    if add(*defs, v) array_add(*worklist, v);
                } else if is_inst(v) && inst_op(v) == .BITCAST {
                    if convert_ty == NONE convert_ty = vtype(op(v, 0));
                    if vtype(op(v, 0)) != convert_ty return false;
                    if add(*defs, v) {
                        array_add(*worklist, v);
                        x := op(v, 0);
                        any_anchored |= !(is_inst(x) && (inst_op(x) == .LOAD || inst_op(x) == .EXTRACTELEMENT));
                    }
                } else if cgp_is_constant_data(v) add(*constants, v);
                else return false;
            }
        }
        u := ir.v_first_use[ii];
        while u != NONE {
            v := ir.u_user[u];
            u = ir.u_next[u];
            if is_phi(v) {
                if !contains(phi_nodes, v) {
                    if table_contains(visited, v) return false;
                    add(*phi_nodes, v);
                    table_set(visited, v, true);
                    array_add(*worklist, v);
                }
            } else if inst_op(v) == .STORE {
                if !load_store_is_simple(v) || op(v, 0) != ii return false;
                add(*uses, v);
            } else if inst_op(v) == .BITCAST {
                if convert_ty == NONE convert_ty = vtype(v);
                if vtype(v) != convert_ty return false;
                add(*uses, v);
                w := ir.v_first_use[v];
                while w != NONE { if inst_op(ir.u_user[w]) != .STORE any_anchored = true; w = ir.u_next[w]; }
            } else return false;
        }
    }
    // X86TargetLowering::shouldConvertPhiType: is64Bit && both int-or-fp
    if convert_ty == NONE || !any_anchored || phi_ty == convert_ty || !st_is64Bit(cgp.xl) ||
       !((type_kind(phi_ty) == .INT || is_fp_type(phi_ty)) && (type_kind(convert_ty) == .INT || is_fp_type(convert_ty))) return false;
    if phi_nodes.count > 4 || defs.count > 4 || uses.count > 4 || constants.count > 4
        fatal("codegenprepare: optimizePhiType over more than 4 nodes of a kind (pointer-ordered SmallPtrSet) is not supported yet");
    val_map: Table(Value_Id, Value_Id); val_map.allocator = temp;
    for c: constants table_set(*val_map, c, ce_cast(.BITCAST, c, convert_ty));
    for d: defs {
        if inst_op(d) == .BITCAST {
            table_set(*val_map, d, op(d, 0));
            add(deleted, d);
        } else {
            bc := create_cast(.BITCAST, d, convert_ty);
            insert_at_position(bc, inst_block(d), inst_next(d), false);
            set_name(bc, tconcat(vname(d), ".bc"));
            table_set(*val_map, d, bc);
        }
    }
    for p: phi_nodes {
        np := create_phi(convert_ty, nops(p));
        insert_at_position(np, inst_block(p), p, false);
        set_name(np, tconcat(vname(p), ".tc"));
        table_set(*val_map, p, np);
    }
    for p: phi_nodes {
        _, np := table_find(*val_map, p);
        for k: 0..cast(s64) nops(p) - 1 {
            _, mv := table_find(*val_map, phi_value(p, cast(u32) k));
            phi_add_incoming(np, mv, phi_block(p, cast(u32) k));
        }
        table_set(visited, np, true);
    }
    for u: uses {
        if inst_op(u) == .BITCAST {
            add(deleted, u);
            _, mv := table_find(*val_map, op(u, 0));
            cgp_rauw(u, mv);
        } else {
            _, mv := table_find(*val_map, op(u, 0));
            bc := create_cast(.BITCAST, mv, phi_ty);
            insert_at_position(bc, inst_block(u), u, false);
            set_name(bc, "bc");
            set_op(u, 0, bc);
        }
    }
    for phi_nodes add(deleted, it);
    return true;
}
cgp_is_constant_data :: (v: Value_Id) -> bool {
    k := vkind(v);
    return k == .C_INT || k == .C_FP || k == .C_NULL || k == .C_ZERO || k == .C_UNDEF || k == .C_POISON || k == .C_DATA ||
           k == .C_TOKEN_NONE || k == .C_TARGET_NONE;
}
load_store_is_simple :: (i: Value_Id) -> bool { return !inst_is_atomic(i) && !is_volatile(i); }

cgp_optimize_phi_types :: (f: Value_Id) -> bool {
    if !cgp_cl.optimize_phi_types return false;
    changed := false;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    deleted: [..] Value_Id; deleted.allocator = temp;
    for bb: fn_blocks(f) {
        for p: block_insts(bb) {
            if inst_op(p) != .PHI break;
            changed |= cgp_optimize_phi_type(p, *visited, *deleted);
        }
    }
    if deleted.count > 4 fatal("codegenprepare: deleting more than 4 converted phi-type nodes (pointer order) is not supported yet");
    for d: deleted {
        cgp_rauw(d, const_poison(vtype(d)));
        erase_inst_with_metadata(d);
    }
    return changed;
}

// canFormExtLd -> (ok, LI, Inst)
cgp_can_form_ext_ld :: (moved: [] Value_Id, has_promoted: bool) -> (bool, Value_Id, Value_Id) {
    li, ins: Value_Id = NONE;
    for m: moved {
        x := op(m, 0);
        if is_inst(x) && inst_op(x) == .LOAD { li = x; ins = m; break; }
    }
    if li == NONE return false, NONE, NONE;
    if !has_promoted && inst_block(li) == inst_block(ins) return false, NONE, NONE;
    return cgp_is_ext_load(li, ins), li, ins;
}
// TargetLoweringBase::isExtLoad
cgp_is_ext_load :: (load: Value_Id, ext: Value_Id) -> bool {
    vt := cgp_evt(vtype(ext));
    load_vt := cgp_evt(vtype(load));
    if !has_one_use(load) && (xl_is_type_legal(cgp.xl, load_vt) || !xl_is_type_legal(cgp.xl, vt)) && !cgp_is_truncate_free(vtype(ext), vtype(load)) return false;
    ltype := ifx inst_op(ext) == .ZEXT then ISD_ZEXTLOAD else ISD_SEXTLOAD;
    return cgp_is_load_legal(vt, load_vt, ltype);
}
// isLoadLegal(ValVT, MemVT, Align, AS, ExtType, Atomic = false): getLoadAction == Legal
cgp_is_load_legal :: (val_vt: Evt, mem_vt: Evt, ext_type: u32) -> bool {
    if !evt_is_simple(val_vt) || !evt_is_simple(mem_vt) return false;   // Expand
    return xl_load_ext_action(cgp.xl, ext_type, val_vt.m, mem_vt.m) == LA_LEGAL;
}

// optimizeExt (Inst is updated through the pointer)
cgp_optimize_ext :: (inst_p: *Value_Id) -> bool {
    // TTI->shouldConsiderAddressTypePromotion: false (no X86 override)
    cgp_tpt.count = 0;
    last_known_good := tpt_restoration_point();
    exts: [1] Value_Id;
    exts[0] = inst_p.*;
    moved: [..] Value_Id; moved.allocator = temp;
    has_promoted := cgp_try_to_promote_exts(exts, *moved);
    ok, li, ext_fed_by_load := cgp_can_form_ext_ld(moved, has_promoted);
    if ok {
        tpt_commit();
        inst_move_after(ext_fed_by_load, li);
        inst_p.* = ext_fed_by_load;
        return true;
    }
    tpt_rollback(last_known_good);
    return false;
}

// optimizeExtUses
cgp_optimize_ext_uses :: (i: Value_Id) -> bool {
    def_bb := inst_block(i);
    src := op(i, 0);
    if has_one_use(src) return false;
    if !cgp_is_truncate_free(vtype(i), vtype(src)) return false;
    if !is_inst(src) || def_bb != inst_block(src) return false;
    live_out := false;
    u := ir.v_first_use[i];
    while u != NONE { if inst_block(ir.u_user[u]) != def_bb { live_out = true; break; } u = ir.u_next[u]; }
    if !live_out return false;
    u = ir.v_first_use[src];
    while u != NONE {
        ui := ir.u_user[u];
        u = ir.u_next[u];
        if inst_block(ui) == def_bb continue;
        o := inst_op(ui);
        if o == .PHI || o == .LOAD || o == .STORE return false;
    }
    inserted: Table(Value_Id, Value_Id); inserted.allocator = temp;
    made_change := false;
    // `for (Use &U : Src->uses())` while `U = InsertedTrunc` moves U to the head of the trunc's use list: the walk
    // continues from U's next in that list (LLVM's behaviour: after the first rewrite only the trunc's other uses,
    // none, follow)
    u = ir.v_first_use[src];
    while u != NONE {
        usr := ir.u_user[u];
        defer u = ir.u_next[u];
        user_bb := inst_block(usr);
        if user_bb == def_bb continue;
        found, it := table_find(*inserted, user_bb);
        if !found {
            pt := block_first_insertion_pt(user_bb);
            it = create_cast(.TRUNC, i, vtype(src));
            insert_at_position(it, user_bb, pt, true);
            table_set(*cgp.inserted_insts, it, true);
            table_set(*inserted, user_bb, it);
        }
        use_set(u, it);
        made_change = true;
    }
    if made_change drop_poison_generating_flags(i);
    return made_change;
}

// optimizeLoadExt
cgp_optimize_load_ext :: (load: Value_Id) -> bool {
    if !load_store_is_simple(load) return false;
    k := type_kind(vtype(load));
    if k != .INT && k != .PTR return false;
    if has_one_use(load) && table_contains(*cgp.inserted_insts, ir.u_user[ir.v_first_use[load]]) return false;
    worklist: [..] Value_Id; worklist.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    ands_to_maybe_remove: [..] Value_Id; ands_to_maybe_remove.allocator = temp;
    drop_flags: [..] Value_Id; drop_flags.allocator = temp;
    u := ir.v_first_use[load];
    while u != NONE { array_add(*worklist, ir.u_user[u]); u = ir.u_next[u]; }
    load_vt := cgp_evt(vtype(load));
    bw := evt_bits(load_vt);
    if bw == 0 return false;
    demand := ap_zero(bw);
    widest := ap_zero(bw);
    while worklist.count {
        i := pop(*worklist);
        if table_contains(*visited, i) continue;
        table_set(*visited, i, true);
        if inst_op(i) == .PHI {
            w := ir.v_first_use[i];
            while w != NONE { array_add(*worklist, ir.u_user[w]); w = ir.u_next[w]; }
            continue;
        }
        o := inst_op(i);
        if o == .AND {
            c := op(i, 1);
            if vkind(c) != .C_INT return false;
            and_bits := const_ap(c);
            demand = ap_or(demand, and_bits);
            if ap_ugt(and_bits, widest) widest = and_bits;
            if ap_eq(and_bits, widest) && op(i, 0) == load array_add(*ands_to_maybe_remove, i);
        } else if o == .SHL {
            c := op(i, 1);
            if vkind(c) != .C_INT return false;
            sh := ap_limited_value(const_ap(c));
            if sh > cast(u64) (bw - 1) sh = cast(u64) (bw - 1);
            ap_set_low_bits(*demand, bw - cast(u32) sh);
            array_add(*drop_flags, i);
        } else if o == .TRUNC {
            tb := evt_bits(cgp_evt(vtype(i)));
            ap_set_low_bits(*demand, tb);
            array_add(*drop_flags, i);
        } else return false;
    }
    active := ap_active_bits(demand);
    if active <= 1 || !ap_is_mask_n(demand, active) || !ap_eq(widest, demand) return false;
    trunc_ty := type_int(active);
    trunc_vt := cgp_evt(trunc_ty);
    if !(evt_bits(load_vt) > evt_bits(trunc_vt)) || !evt_is_round(trunc_vt) || !cgp_is_load_legal(load_vt, trunc_vt, ISD_ZEXTLOAD) return false;
    b: Irb;
    irb_set_before(*b, inst_next(load));
    new_and := irb_binop(*b, .AND, load, const_int_ap(type_int(bw), demand));
    table_set(*cgp.inserted_insts, new_and, true);
    cgp_rauw(load, new_and);
    set_op(new_and, 0, load);
    for a: ands_to_maybe_remove {
        if ap_eq(const_ap(op(a, 1)), demand) {
            cgp_rauw(a, new_and);
            if cgp.cur_inst == a cgp.cur_inst = inst_next(a);
            erase_inst_with_metadata(a);
        }
    }
    for x: drop_flags if inst_op(x) == .SHL || inst_op(x) == .TRUNC inst(x).flags &= ~cast(u32) F_NSW;
    return true;
}
// EVT::isRound: a power-of-two size of at least 8 bits
evt_is_round :: (e: Evt) -> bool { b := evt_bits(e); return b >= 8 && (b & (b - 1)) == 0; }
