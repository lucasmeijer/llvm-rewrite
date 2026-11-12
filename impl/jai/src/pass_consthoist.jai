// ConstantHoisting: port of llvm/lib/Transforms/Scalar/ConstantHoisting.cpp (ConstantHoistingPass::runImpl and its
// helpers) with X86TTIImpl::getIntImmCostInst / getIntImmCostIntrin, isLegalAddImmediate, isLegalAddressingMode.
// The constant-GEP path (-consthoist-gep, default off) fails loudly.

Ch_User :: struct { inst: Value_Id; idx: u32; }
Ch_Cand :: struct {
    uses: [..] Ch_User;
    const_int: Value_Id;
    const_expr: Value_Id = NONE;
    cumulative_cost: s64;
}
Ch_Rebased :: struct { uses: [..] Ch_User; offset: Value_Id; ty: Type_Id; }
Ch_Info :: struct { base_int: Value_Id; base_expr: Value_Id; rebased: [..] Ch_Rebased; }
Ch_Adj :: struct { offset: Value_Id; ty: Type_Id; mat_insert_pt: Value_Id; user: Ch_User; }

ch_cl: struct {
    with_block_frequency := true;   // -consthoist-with-block-frequency
    gep := false;                   // -consthoist-gep
    min_num_to_rebase: u64 = 0;     // -consthoist-min-num-to-rebase
}

Ch_State :: struct {
    f: Value_Id;
    t: *Tti;
    dt: *Dom_Tree;
    bfi: *Bfi;
    entry: Value_Id;
    opt_for_size: bool;
    cand_vec: [..] Ch_Cand;       // ConstIntCandVec
    info_vec: [..] Ch_Info;       // ConstIntInfoVec
    cloned_cast_keys: [..] Value_Id;   // ClonedCastMap (DenseMap; only erased at the end)
    cloned_cast_vals: [..] Value_Id;
}

// findMatInsertPt (Idx = ~0U: no operand)
ch_find_mat_insert_pt :: (s: *Ch_State, i: Value_Id, idx: u32 = 0xFFFF_FFFF) -> Value_Id {
    if idx != 0xFFFF_FFFF {
        o := op(i, idx);
        if is_inst(o) && cgp_is_cast_op(inst_op(o)) return o;
    }
    if inst_op(i) != .PHI && !is_eh_pad(i) return i;
    ib: Value_Id = NONE;
    if idx != 0xFFFF_FFFF && inst_op(i) == .PHI {
        ib = phi_block(i, idx);
        if !is_eh_pad(block_first_non_phi(ib)) return block_terminator(ib);
    } else ib = inst_block(i);
    n := dt_idom(s.dt, dt_node(s.dt, ib));
    while is_eh_pad(block_first_non_phi(s.dt.nodes[n].block)) n = dt_idom(s.dt, n);
    return block_terminator(s.dt.nodes[n].block);
}

// findBestInsertionSet(DT, BFI, Entry, BBs)
ch_find_best_insertion_set :: (s: *Ch_State, bbs: *[..] Value_Id) {
    contains :: (l: [] Value_Id, v: Value_Id) -> bool { for l if it == v return true; return false; }
    path: [..] Value_Id; path.allocator = temp;
    candidates: Table(Value_Id, bool); candidates.allocator = temp;
    for bb: bbs.* {
        if !dt_is_reachable_from_entry(s.dt, bb) continue;
        path.count = 0;
        node := bb;
        is_candidate := false;
        while true {
            array_add(*path, node);
            if node == s.entry || table_contains(*candidates, node) { is_candidate = true; break; }
            node = s.dt.nodes[dt_idom(s.dt, dt_node(s.dt, node))].block;
            if contains(bbs.*, node) break;
        }
        if !is_candidate continue;
        for path table_set(*candidates, it, true);
    }
    orders: [..] Value_Id; orders.allocator = temp;
    array_add(*orders, s.entry);
    idx := 0;
    while idx != orders.count {
        node := orders[idx];
        idx += 1;
        c := s.dt.nodes[dt_node(s.dt, node)].first_child;
        while c >= 0 {
            b := s.dt.nodes[c].block;
            if table_contains(*candidates, b) array_add(*orders, b);
            c = s.dt.nodes[c].sibling;
        }
    }
    // InsertPtsMap: (SetVector of blocks, frequency) per node
    pts: Table(Value_Id, s64); pts.allocator = temp;   // node -> index into the lists below
    pts_list: [..] [..] Value_Id; pts_list.allocator = temp;
    pts_freq: [..] u64; pts_freq.allocator = temp;
    for orders {
        table_set(*pts, it, pts_list.count);
        e: [..] Value_Id; e.allocator = temp;
        array_add(*pts_list, e);
        array_add(*pts_freq, 0);
    }
    sv_insert :: (l: *[..] Value_Id, v: Value_Id) { for l.* if it == v return; array_add(l, v); }
    k := orders.count - 1;
    while k >= 0 {
        node := orders[k];
        k -= 1;
        node_in_bbs := contains(bbs.*, node);
        _, ni := table_find(*pts, node);
        freq := bfi_get_block_freq(s.bfi, node);
        if node == s.entry {
            bbs.count = 0;
            if pts_freq[ni] > freq || (pts_freq[ni] == freq && pts_list[ni].count > 1) array_add(bbs, s.entry);
            else for pts_list[ni] array_add(bbs, it);
            break;
        }
        parent := s.dt.nodes[dt_idom(s.dt, dt_node(s.dt, node))].block;
        _, pi := table_find(*pts, parent);
        if node_in_bbs || (!is_eh_pad(block_first_non_phi(node)) && (pts_freq[ni] > freq || (pts_freq[ni] == freq && pts_list[ni].count > 1))) {
            sv_insert(*pts_list[pi], node);
            pts_freq[pi] += freq;
        } else {
            for pts_list[ni] sv_insert(*pts_list[pi], it);
            pts_freq[pi] += pts_freq[ni];
        }
    }
}

// findConstantInsertionPoint -> the IPSet (SetVector of iterators: instructions; head bit for first insertion points)
Ch_Ip :: struct { bb: Value_Id; pt: Value_Id; head: bool; }
ch_find_constant_insertion_point :: (s: *Ch_State, info: *Ch_Info, mat_pts: [] Value_Id) -> [..] Ch_Ip {
    ips: [..] Ch_Ip; ips.allocator = temp;
    bbs: [..] Value_Id; bbs.allocator = temp;
    for mat_pts { b := inst_block(it); dup := false; for x: bbs if x == b dup = true; if !dup array_add(*bbs, b); }
    for bbs if it == s.entry {
        array_add(*ips, .{s.entry, block_first(s.entry), false});   // Entry->begin()
        return ips;
    }
    if s.bfi {
        ch_find_best_insertion_set(s, *bbs);
        for bb: bbs {
            ip := Ch_Ip.{bb, block_first_insertion_pt(bb), true};
            dup := false;
            for ips if it.pt == ip.pt && it.bb == ip.bb dup = true;
            if !dup array_add(*ips, ip);
        }
        return ips;
    }
    fatal("consthoist: -consthoist-with-block-frequency=false is not supported yet");
    return ips;
}

// collectConstantCandidates(ConstCandMap, Inst, Idx, ConstInt)
ch_collect_const_int :: (s: *Ch_State, map: *Table(Value_Id, s64), i: Value_Id, idx: u32, ci: Value_Id) {
    if is_vector_type(vtype(ci)) return;
    cost: s64;
    id := call_iid(i);
    if id != NOT_INTRINSIC cost = ch_int_imm_cost_intrin(s.t, id, idx, const_ap(ci), vtype(ci));
    else cost = cast(s64) tti_int_imm_cost_inst(s.t, inst_op(i), true, cast(s32) idx, const_ap(ci), vtype(ci), TCK_SIZE_AND_LATENCY, i);
    if cost > TCC_BASIC {
        found, k := table_find(map, ci);
        if !found {
            c: Ch_Cand;
            c.uses.allocator = temp;
            c.const_int = ci;
            array_add(*s.cand_vec, c);
            k = s.cand_vec.count - 1;
            table_set(map, ci, k);
        }
        array_add(*s.cand_vec[k].uses, .{i, idx});
        s.cand_vec[k].cumulative_cost += cost;
    }
}
// X86TTIImpl::getIntImmCostIntrin
ch_int_imm_cost_intrin :: (t: *Tti, id: Intrinsic_Id, idx: u32, imm: APInt, ty: Type_Id) -> s64 {
    if t.kind != .X86 return TCC_FREE;
    if type_bits(ty) == 0 return TCC_FREE;
    n := iid_name(id);
    if n == "llvm.sadd.with.overflow" || n == "llvm.uadd.with.overflow" || n == "llvm.ssub.with.overflow" ||
       n == "llvm.usub.with.overflow" || n == "llvm.smul.with.overflow" || n == "llvm.umul.with.overflow" {
        if idx == 1 && imm.bits <= 64 && ap_is_signed_int_n(imm, 32) return TCC_FREE;
    } else if n == "llvm.experimental.stackmap" {
        if idx < 2 || (imm.bits <= 64 && ap_is_signed_int_n(imm, 64)) return TCC_FREE;
    } else if n == "llvm.experimental.patchpoint.void" || n == "llvm.experimental.patchpoint" {
        if idx < 4 || (imm.bits <= 64 && ap_is_signed_int_n(imm, 64)) return TCC_FREE;
    } else return TCC_FREE;
    return cast(s64) x86_int_imm_cost(imm, ty);
}

// collectConstantCandidates(ConstCandMap, Inst, Idx)
ch_collect_operand :: (s: *Ch_State, map: *Table(Value_Id, s64), i: Value_Id, idx: u32) {
    o := op(i, idx);
    if vkind(o) == .C_INT { ch_collect_const_int(s, map, i, idx, o); return; }
    if is_inst(o) {
        if !cgp_is_cast_op(inst_op(o)) return;
        if vkind(op(o, 0)) == .C_INT { ch_collect_const_int(s, map, i, idx, op(o, 0)); return; }
    }
    if vkind(o) == .C_EXPR {
        if ch_cl.gep && cexpr(o).op == .GEP fatal("consthoist: -consthoist-gep is not supported yet");
        if !cgp_is_cast_op(cexpr(o).op) return;
        if vkind(op(o, 0)) == .C_INT { ch_collect_const_int(s, map, i, idx, op(o, 0)); return; }
    }
}

// maximizeConstantsInRange -> (NumUses, MaxCostItr)
ch_maximize_constants_in_range :: (s: *Ch_State, b: s64, e: s64) -> (u32, s64) {
    num_uses: u32 = 0;
    max_itr := b;
    if !s.opt_for_size || e - b > 100 {
        for k: b..e-1 {
            num_uses += cast(u32) s.cand_vec[k].uses.count;
            if s.cand_vec[k].cumulative_cost > s.cand_vec[max_itr].cumulative_cost max_itr = k;
        }
        return num_uses, max_itr;
    }
    fatal("consthoist: maximizeConstantsInRange under optsize (getIntImmCodeSizeCost) is not supported yet");
    return 0, b;
}

// findAndMakeBaseConstant
ch_find_and_make_base_constant :: (s: *Ch_State, b: s64, e: s64) {
    num_uses, max_itr := ch_maximize_constants_in_range(s, b, e);
    if num_uses <= 1 return;
    info: Ch_Info;
    info.rebased.allocator = temp;
    info.base_int = s.cand_vec[max_itr].const_int;
    info.base_expr = s.cand_vec[max_itr].const_expr;
    ty := vtype(info.base_int);
    for k: b..e-1 {
        diff := ap_sub(const_ap(s.cand_vec[k].const_int), const_ap(info.base_int));
        off := ifx ap_is_zero(diff) then NONE else const_int_ap(ty, diff);
        cty := ifx s.cand_vec[k].const_expr != NONE then vtype(s.cand_vec[k].const_expr) else NONE;
        r: Ch_Rebased;
        r.uses = s.cand_vec[k].uses;
        r.offset = off; r.ty = cty;
        array_add(*info.rebased, r);
    }
    array_add(*s.info_vec, info);
}

// findBaseConstants(nullptr)
ch_find_base_constants :: (s: *Ch_State) {
    // stable_sort by (bit width, unsigned value)
    less :: (a: *Ch_Cand, b: *Ch_Cand) -> bool {
        ta := vtype(a.const_int); tb := vtype(b.const_int);
        if ta != tb return type_bits(ta) < type_bits(tb);
        return ap_ult(const_ap(a.const_int), const_ap(b.const_int));
    }
    n := s.cand_vec.count;
    for i: 1..n-1 {
        j := i;
        while j > 0 && less(*s.cand_vec[j], *s.cand_vec[j - 1]) {
            tmp := s.cand_vec[j]; s.cand_vec[j] = s.cand_vec[j - 1]; s.cand_vec[j - 1] = tmp;
            j -= 1;
        }
    }
    min_itr := 0;
    for cc: 1..n-1 {
        if vtype(s.cand_vec[min_itr].const_int) == vtype(s.cand_vec[cc].const_int) {
            mem_use_val_ty: Type_Id = NONE;
            for u: s.cand_vec[cc].uses {
                ui := u.inst;
                if inst_op(ui) == .LOAD { mem_use_val_ty = vtype(ui); break; }
                if inst_op(ui) == .STORE {
                    if op(ui, 1) == op(ui, u.idx) { mem_use_val_ty = vtype(op(ui, 0)); break; }
                }
            }
            diff := ap_sub(const_ap(s.cand_vec[cc].const_int), const_ap(s.cand_vec[min_itr].const_int));
            if diff.bits <= 64 {
                d := ap_sext_value(diff);
                // X86TargetLowering::isLegalAddImmediate: isInt<32>
                if d >= -0x8000_0000 && d <= 0x7FFF_FFFF &&
                   (mem_use_val_ty == NONE || x86_is_legal_addressing_mode(*s.t.xl, mem_use_val_ty, NONE, d, true, 0, 0))
                    continue;
            }
        }
        ch_find_and_make_base_constant(s, min_itr, cc);
        min_itr = cc;
    }
    ch_find_and_make_base_constant(s, min_itr, n);
}

// updateOperand
ch_update_operand :: (i: Value_Id, idx: u32, mat: Value_Id) -> bool {
    if inst_op(i) == .PHI {
        ib := phi_block(i, idx);
        for k: 0..cast(s64) idx - 1 {
            if phi_block(i, cast(u32) k) == ib {
                set_op(i, idx, phi_value(i, cast(u32) k));
                return false;
            }
        }
    }
    set_op(i, idx, mat);
    return true;
}

// emitBaseConstants(Base, Adj)
ch_emit_base_constants_adj :: (s: *Ch_State, base: Value_Id, adj: *Ch_Adj) {
    mat := base;
    if adj.offset == NONE && adj.ty != NONE && adj.ty != vtype(base) adj.offset = const_int(ir.t_i32, 0);
    if adj.offset != NONE {
        if adj.ty != NONE fatal("consthoist: rebasing constant expressions is not supported yet");
        mat = create_binop(.ADD, base, adj.offset);
        insert_at_position(mat, inst_block(adj.mat_insert_pt), adj.mat_insert_pt, false);
        set_name(mat, "const_mat");
        set_metadata(mat, 0, get_metadata(adj.user.inst, 0));
    }
    o := op(adj.user.inst, adj.user.idx);
    if vkind(o) == .C_INT {
        if !ch_update_operand(adj.user.inst, adj.user.idx, mat) && adj.offset != NONE erase_inst_with_metadata(mat);
        return;
    }
    if is_inst(o) {
        k := -1;
        for s.cloned_cast_keys if it == o { k = it_index; break; }
        if k < 0 {
            cl := ic_clone_inst(o);
            set_op(cl, 0, mat);
            inst_insert_after(cl, o);
            set_metadata(cl, 0, get_metadata(o, 0));
            array_add(*s.cloned_cast_keys, o);
            array_add(*s.cloned_cast_vals, cl);
            k = s.cloned_cast_keys.count - 1;
        }
        ch_update_operand(adj.user.inst, adj.user.idx, s.cloned_cast_vals[k]);
        return;
    }
    if vkind(o) == .C_EXPR {
        if cexpr(o).op == .GEP { ch_update_operand(adj.user.inst, adj.user.idx, mat); return; }
        // ConstantExpr::getAsInstruction for a cast expression
        ce_i := create_cast(cexpr(o).op, op(o, 0), vtype(o));
        insert_at_position(ce_i, inst_block(adj.mat_insert_pt), adj.mat_insert_pt, false);
        set_op(ce_i, 0, mat);
        set_metadata(ce_i, 0, get_metadata(adj.user.inst, 0));
        if !ch_update_operand(adj.user.inst, adj.user.idx, ce_i) {
            erase_inst_with_metadata(ce_i);
            if adj.offset != NONE erase_inst_with_metadata(mat);
        }
    }
}

// emitBaseConstants(nullptr)
ch_emit_base_constants :: (s: *Ch_State) -> bool {
    made_change := false;
    for * info: s.info_vec {
        mat_pts: [..] Value_Id; mat_pts.allocator = temp;
        for r: info.rebased for u: r.uses array_add(*mat_pts, ch_find_mat_insert_pt(s, u.inst, u.idx));
        ips := ch_find_constant_insertion_point(s, info, mat_pts);
        if ips.count == 0 continue;
        for ip: ips {
            to_rebase: [..] Ch_Adj; to_rebase.allocator = temp;
            mat_ctr := 0;
            for r: info.rebased for u: r.uses {
                mp := mat_pts[mat_ctr];
                mat_ctr += 1;
                orig_bb := inst_block(mp);
                if ips.count == 1 || dt_dominates(s.dt, ip.bb, orig_bb) array_add(*to_rebase, .{r.offset, r.ty, mp, u});
            }
            if cast(u64) to_rebase.count < ch_cl.min_num_to_rebase continue;
            if info.base_expr != NONE fatal("consthoist: hoisting constant expressions is not supported yet");
            ty := vtype(info.base_int);
            base := create_cast(.BITCAST, info.base_int, ty);
            insert_at_position(base, ip.bb, ip.pt, ip.head);
            set_name(base, "const");
            set_metadata(base, 0, ifx ip.pt != NONE then get_metadata(ip.pt, 0) else NONE);
            for * r: to_rebase {
                ch_emit_base_constants_adj(s, base, r);
                set_metadata(base, 0, merged_location(get_metadata(base, 0), get_metadata(r.user.inst, 0)));
            }
        }
        made_change = true;
    }
    return made_change;
}

consthoist_run :: (f: Value_Id) -> Preserved {
    if cg_skip_function(f) return PRESERVE_ALL;
    s: Ch_State;
    s.f = f;
    s.t = tti_get(f);
    s.dt = get_domtree(f);
    s.bfi = ifx ch_cl.with_block_frequency then get_bfi(f) else null;
    s.entry = fn_entry(f);
    s.opt_for_size = fn_has_fn_attr(f, .OptimizeForSize) || fn_has_fn_attr(f, .MinSize);
    if psi_get().has_summary fatal("consthoist: modules with a profile summary are not supported yet");
    s.cand_vec.allocator = temp; s.info_vec.allocator = temp;
    s.cloned_cast_keys.allocator = temp; s.cloned_cast_vals.allocator = temp;
    map: Table(Value_Id, s64); map.allocator = temp;
    for bb: fn_blocks(f) {
        if !dt_is_reachable_from_entry(s.dt, bb) continue;
        for i: block_insts(bb) {
            // TTI->preferToKeepConstantsAttached: false (no X86 override)
            if cgp_is_cast_op(inst_op(i)) continue;
            n := nops(i);
            for k: 0..cast(s64) n - 1 {
                idx := cast(u32) k;
                if inst_op(i) == .PHI && !dt_is_reachable_from_entry(s.dt, phi_block(i, idx)) continue;
                if can_replace_operand_with_variable(i, idx) ch_collect_operand(*s, *map, i, idx);
            }
        }
    }
    if s.cand_vec.count ch_find_base_constants(*s);
    made_change := false;
    if s.info_vec.count made_change = ch_emit_base_constants(*s);
    for s.cloned_cast_keys if !has_uses(it) erase_inst_with_metadata(it);
    if !made_change return PRESERVE_ALL;
    return preserved_cfg();
}
