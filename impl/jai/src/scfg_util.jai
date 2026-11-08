// Shared CFG-editing utilities used by SimplifyCFG (and reusable by any pass):
// - branch-weight metadata: llvm/lib/IR/ProfDataUtils.cpp (prof_*)
// - SwitchInst case API and SwitchInstProfUpdateWrapper: llvm/lib/IR/Instructions.cpp (sw_*, Sw_Prof)
// - DomTreeUpdater with the Eager strategy: llvm/lib/Analysis/DomTreeUpdater.cpp (Dtu, dtu_*)
// - DeleteDeadBlock(s) / detachDeadBlocks / emptyAndDetachBlock: llvm/lib/Transforms/Utils/BasicBlockUtils.cpp
// - BasicBlock::eraseFromParent of a block whose address is taken (~BasicBlock): llvm/lib/IR/BasicBlock.cpp

// ---------------------------------------------------------------- ProfDataUtils.cpp

MD_PROF_NAME :: "prof";
prof_md :: (i: Value_Id) -> Md_Id { return get_metadata(i, md_kind_id(MD_PROF_NAME)); }
// isBranchWeightMD
prof_is_branch_weight_md :: (m: Md_Id) -> bool {
    if m == NONE || !md_is_node(m) || md_nops(m) < 3 return false;
    s := md_op(m, 0);
    return s != NONE && ir.mds[s].kind == .STRING && ir.mds[s].str == "branch_weights";
}
prof_has_branch_weight_md :: (i: Value_Id) -> bool { return prof_is_branch_weight_md(prof_md(i)); }
// hasBranchWeightOrigin
prof_has_branch_weight_origin :: (m: Md_Id) -> bool {
    if !prof_is_branch_weight_md(m) return false;
    s := md_op(m, 1);
    return s != NONE && ir.mds[s].kind == .STRING;
}
prof_num_branch_weights :: (m: Md_Id) -> u32 { return md_nops(m) - ifx prof_has_branch_weight_origin(m) then cast(u32) 2 else 1; }
// getValidBranchWeightMDNode
prof_valid_branch_weight_md :: (i: Value_Id) -> Md_Id {
    m := prof_md(i);
    if !prof_is_branch_weight_md(m) return NONE;
    if prof_num_branch_weights(m) == num_successors(i) return m;
    return NONE;
}
// extractFromBranchWeightMD64
prof_weights_of_md :: (m: Md_Id) -> [] u64 {
    first: u32 = ifx prof_has_branch_weight_origin(m) then cast(u32) 2 else 1;
    w := NewArray(md_nops(m) - first, u64,, allocator = temp);
    for k: first..md_nops(m)-1 {
        c := md_const_int_op(m, k);
        assert(c != NONE, "Malformed branch_weight in MD_prof node");
        w[k - first] = const_int_zext(c);
    }
    return w;
}
// extractBranchWeights(I, Weights)
prof_extract_branch_weights :: (i: Value_Id) -> (bool, [] u64) {
    m := prof_md(i);
    if !prof_is_branch_weight_md(m) return false, .[];
    return true, prof_weights_of_md(m);
}
// extractBranchWeights(I, TrueVal, FalseVal)
prof_extract_branch_weights_2 :: (i: Value_Id) -> (bool, u64, u64) {
    ok, w := prof_extract_branch_weights(i);
    if !ok || w.count > 2 return false, 0, 0;
    return true, w[0], w[1];
}
// fitWeights
prof_fit_weights :: (w: [] u64) -> [] u32 {
    mx: u64 = 0;
    for w if it > mx mx = it;
    out := NewArray(w.count, u32,, allocator = temp);
    if mx > 0xFFFF_FFFF {
        lz := 0; x := mx; while (x & 0x8000_0000_0000_0000) == 0 { x <<= 1; lz += 1; }
        off := cast(u64) (32 - lz);
        for w out[it_index] = cast(u32) (it >> off);
    } else for w out[it_index] = cast(u32) it;
    return out;
}
// setBranchWeights(I, Weights, IsExpected, ElideAllZero = true)
prof_set_branch_weights :: (i: Value_Id, w: [] u32, is_expected: bool, elide_all_zero := false) {
    if elide_all_zero {
        all0 := true;
        for w if it != 0 all0 = false;
        if all0 { set_metadata(i, md_kind_id(MD_PROF_NAME), NONE); return; }
    }
    ops: [..] Md_Id; ops.allocator = temp;
    array_add(*ops, md_string("branch_weights"));
    if is_expected array_add(*ops, md_string("expected"));
    i32 := type_int(cast(u64) 32);
    for w array_add(*ops, md_value(const_int(i32, it)));
    set_metadata(i, md_kind_id(MD_PROF_NAME), md_tuple(ops, false));
}
prof_set_branch_weights_u64 :: (i: Value_Id, w: [] u64, is_expected: bool) {
    w32 := NewArray(w.count, u32,, allocator = temp);
    for w w32[it_index] = cast(u32) it;
    prof_set_branch_weights(i, w32, is_expected);
}
// setFittedBranchWeights
prof_set_fitted_branch_weights :: (i: Value_Id, w: [] u64, is_expected := false, elide_all_zero := false) {
    prof_set_branch_weights(i, prof_fit_weights(w), is_expected, elide_all_zero);
}
// hasExplicitlyUnknownBranchWeights
prof_has_explicitly_unknown_branch_weights :: (i: Value_Id) -> bool {
    m := prof_md(i);
    if m == NONE || !md_is_node(m) || md_nops(m) != 2 return false;
    s := md_op(m, 0);
    return s != NONE && ir.mds[s].kind == .STRING && ir.mds[s].str == "unknown";
}

// ---------------------------------------------------------------- SwitchInst

// operands: [cond, default, dest_0, ..., dest_{n-1}], case value k in u_aux of operand 2 + k
sw_num_cases :: inline (sw: Value_Id) -> u32 { return nops(sw) - 2; }
sw_cond :: inline (sw: Value_Id) -> Value_Id { return op(sw, 0); }
sw_default :: inline (sw: Value_Id) -> Value_Id { return op(sw, 1); }
sw_case_value :: inline (sw: Value_Id, k: u32) -> Value_Id { return ir.u_aux[ir.v_ops[sw] + 2 + k]; }
sw_case_dest :: inline (sw: Value_Id, k: u32) -> Value_Id { return op(sw, 2 + k); }
sw_set_case_dest :: inline (sw: Value_Id, k: u32, b: Value_Id) { set_op(sw, 2 + k, b); }
sw_set_case_value :: inline (sw: Value_Id, k: u32, c: Value_Id) { ir.u_aux[ir.v_ops[sw] + 2 + k] = c; }
sw_set_default :: inline (sw: Value_Id, b: Value_Id) { set_op(sw, 1, b); }
// SwitchInst::Create(Cond, Default, NumCases) (unlinked)
create_switch :: (c: Value_Id, def: Value_Id, num_cases: u32) -> Value_Id {
    i := new_inst(.SWITCH, ir.t_void, 2);
    grow_ops(i, 2 + num_cases);
    set_op(i, 0, c); set_op(i, 1, def);
    return i;
}
// SwitchInst::addCase
sw_add_case :: (sw: Value_Id, c: Value_Id, dest: Value_Id) { add_op(sw, dest, c); }
// SwitchInst::removeCase: the last case moves into the hole
sw_remove_case :: (sw: Value_Id, k: u32) {
    n := nops(sw);
    if 2 + k + 1 != n {
        set_op(sw, 2 + k, op(sw, n - 1));
        ir.u_aux[ir.v_ops[sw] + 2 + k] = ir.u_aux[ir.v_ops[sw] + n - 1];
    }
    use_set(op_use(sw, n - 1), NONE);
    ir.u_aux[op_use(sw, n - 1)] = NONE;
    ir.v_nops[sw] = n - 1;
}
// findCaseValue: case index or -1 (default)
sw_find_case_value :: (sw: Value_Id, c: Value_Id) -> s64 {
    n := sw_num_cases(sw);
    for k: 0..cast(s64) n - 1 if sw_case_value(sw, cast(u32) k) == c return k;
    return -1;
}
// findCaseDest: the unique case value going to bb (NONE if none or several)
sw_find_case_dest :: (sw: Value_Id, bb: Value_Id) -> Value_Id {
    if bb == sw_default(sw) return NONE;
    r: Value_Id = NONE;
    for k: 0..cast(s64) sw_num_cases(sw) - 1 {
        if sw_case_dest(sw, cast(u32) k) == bb {
            if r != NONE return NONE;
            r = sw_case_value(sw, cast(u32) k);
        }
    }
    return r;
}
// defaultDestUnreachable: the default block starts with `unreachable` (getFirstNonPHIOrDbg)
sw_default_dest_unreachable :: (sw: Value_Id) -> bool {
    f := block_first_non_phi_or_dbg(sw_default(sw));
    return f != NONE && inst_op(f) == .UNREACHABLE;
}

// SwitchInstProfUpdateWrapper: weights tracked while cases change; sw_prof_done = the destructor
Sw_Prof :: struct { sw: Value_Id; have: bool; changed: bool; w: [..] u32; }
sw_prof_init :: (p: *Sw_Prof, sw: Value_Id) {
    p.sw = sw;
    p.w.allocator = temp;
    m := prof_md(sw);
    if !prof_is_branch_weight_md(m) return;
    if prof_num_branch_weights(m) != num_successors(sw) fatal("number of prof branch_weights metadata operands does not correspond to number of succesors");
    for prof_weights_of_md(m) array_add(*p.w, cast(u32) it);
    p.have = true;
}
sw_prof_remove_case :: (p: *Sw_Prof, k: u32) {
    if p.have {
        p.changed = true;
        p.w[k + 1] = p.w[p.w.count - 1];
        p.w.count -= 1;
    }
    sw_remove_case(p.sw, k);
}
sw_prof_add_case :: (p: *Sw_Prof, c: Value_Id, dest: Value_Id, has_w: bool, w: u32) {
    sw_add_case(p.sw, c, dest);
    if !p.have && has_w && w != 0 {
        p.changed = true;
        p.have = true;
        array_resize(*p.w, num_successors(p.sw));
        for *p.w it.* = 0;
        p.w[p.w.count - 1] = w;
    } else if p.have {
        p.changed = true;
        array_add(*p.w, ifx has_w then w else 0);
    }
}
sw_prof_get_weight :: (p: *Sw_Prof, idx: u32) -> (bool, u32) {
    if !p.have return false, 0;
    return true, p.w[idx];
}
sw_prof_set_weight :: (p: *Sw_Prof, idx: u32, has_w: bool, w: u32) {
    if !has_w return;
    if !p.have && w != 0 {
        p.have = true;
        array_resize(*p.w, num_successors(p.sw));
        for *p.w it.* = 0;
    }
    if p.have && p.w[idx] != w { p.changed = true; p.w[idx] = w; }
}
// replaceDefaultDest(case k)
sw_prof_replace_default_dest :: (p: *Sw_Prof, k: u32) {
    d := sw_case_dest(p.sw, k);
    if p.have p.w[0] = p.w[k + 1];
    sw_set_default(p.sw, d);
}
sw_prof_erase :: (p: *Sw_Prof) { p.changed = false; p.w.count = 0; }
sw_prof_done :: (p: *Sw_Prof) {
    if p.changed && p.have {
        if p.w.count >= 2 { prof_set_branch_weights(p.sw, p.w, false); return; }
        set_metadata(p.sw, md_kind_id(MD_PROF_NAME), NONE);
    }
}
// SwitchInstProfUpdateWrapper::getSuccessorWeight(SI, idx) (static)
sw_successor_weight :: (sw: Value_Id, idx: u32) -> (bool, u32) {
    m := prof_valid_branch_weight_md(sw);
    if m == NONE return false, 0;
    return true, cast(u32) prof_weights_of_md(m)[idx];
}

// ---------------------------------------------------------------- DomTreeUpdater (Eager)

// A null *Dtu = no DTU. With the Eager strategy every update is applied immediately.
Dtu :: struct { dt: *Dom_Tree; }
dtu_apply :: (dtu: *Dtu, updates: [] Dom_Update) {
    if !dtu || !dtu.dt || updates.count == 0 return;
    dt_apply_updates(dtu.dt, updates);
}
dtu_apply1 :: (dtu: *Dtu, insert: bool, from: Value_Id, to: Value_Id) {
    if !dtu return;
    u := Dom_Update.[.{insert, from, to}];
    dtu_apply(dtu, u);
}
// DomTreeUpdater::deleteBB: validateDeleteBB, eraseDelBBNode, eraseFromParent
dtu_delete_bb :: (dtu: *Dtu, bb: Value_Id) {
    validate_delete_bb(bb);
    if dtu && dtu.dt && dt_node(dtu.dt, bb) >= 0 dt_erase_node(dtu.dt, bb);
    block_erase_from_parent(bb);
}
// validateDeleteBB: everything goes, an `unreachable` is left
validate_delete_bb :: (bb: Value_Id) {
    while block_last(bb) != NONE {
        i := block_last(bb);
        if has_uses(i) rauw_with_metadata(i, const_poison(vtype(i)));
        drop_dbg_records(i);
        erase_inst_with_metadata(i);
    }
    u := new_inst(.UNREACHABLE, ir.t_void, 0);
    block_append_inst(bb, u);
}

// BasicBlock::eraseFromParent (~BasicBlock: a remaining blockaddress becomes inttoptr (i32 1))
block_erase_from_parent :: (bb: Value_Id) {
    // the address-taken case
    u := ir.v_first_use[bb];
    while u != NONE {
        nx := ir.u_next[u];
        user := ir.u_user[u];
        if vkind(user) == .C_BLOCKADDR {
            repl := ce_cast(.INTTOPTR, const_int(type_int(cast(u64) 32), 1), vtype(user));
            replace_all_uses_with(user, repl);
        }
        u = nx;
    }
    while block_last(bb) != NONE {
        i := block_last(bb);
        if has_uses(i) rauw_with_metadata(i, const_poison(vtype(i)));
        drop_dbg_records(i);
        erase_inst_with_metadata(i);
    }
    f := block_fn(bb);
    fn_unlink_block(f, bb);
    if vname(bb).count set_name(bb, "");
    ir.v_kind[bb] = .DEAD;
}

// ---------------------------------------------------------------- BasicBlockUtils.cpp

// emptyAndDetachBlock
empty_and_detach_block :: (bb: Value_Id, updates: *[..] Dom_Update, keep_one_input_phis: bool) {
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    uniq: [..] Value_Id; uniq.allocator = temp;
    for s: succs {
        block_remove_predecessor(s, bb, keep_one_input_phis);
        if updates {
            seen := false;
            for uniq if it == s seen = true;
            if !seen { array_add(*uniq, s); array_add(updates, .{false, bb, s}); }
        }
    }
    while block_last(bb) != NONE {
        i := block_last(bb);
        if has_uses(i) rauw_with_metadata(i, const_poison(vtype(i)));
        drop_dbg_records(i);
        erase_inst_with_metadata(i);
    }
    u := new_inst(.UNREACHABLE, ir.t_void, 0);
    block_append_inst(bb, u);
}
// detachDeadBlocks
detach_dead_blocks :: (bbs: [] Value_Id, updates: *[..] Dom_Update, keep_one_input_phis: bool) {
    for bb: bbs {
        f := block_first_non_phi(bb);
        if f != NONE && (inst_op(f) == .CATCHPAD || inst_op(f) == .CLEANUPPAD) {
            rets: [..] Value_Id; rets.allocator = temp;
            u := ir.v_first_use[f];
            while u != NONE {
                user := ir.u_user[u];
                if is_inst(user) && (inst_op(user) == .CATCHRET || inst_op(user) == .CLEANUPRET) {
                    rb := inst_block(user);
                    seen := false;
                    for rets if it == rb seen = true;
                    if !seen array_add(*rets, rb);
                }
                u = ir.u_next[u];
            }
            for rets empty_and_detach_block(it, updates, keep_one_input_phis);
        }
        empty_and_detach_block(bb, updates, keep_one_input_phis);
    }
}
// DeleteDeadBlocks(BBs, DTU, KeepOneInputPHIs)
delete_dead_blocks :: (bbs: [] Value_Id, dtu: *Dtu, keep_one_input_phis := false) {
    updates: [..] Dom_Update; updates.allocator = temp;
    detach_dead_blocks(bbs, ifx dtu then *updates else null, keep_one_input_phis);
    if dtu dtu_apply(dtu, updates);
    for bbs {
        if dtu dtu_delete_bb(dtu, it);
        else block_erase_from_parent(it);
    }
}
delete_dead_block :: (bb: Value_Id, dtu: *Dtu, keep_one_input_phis := false) {
    a := Value_Id.[bb];
    delete_dead_blocks(a, dtu, keep_one_input_phis);
}
U64_MAX : u64 : 0xFFFF_FFFF_FFFF_FFFF;

// DataLayout::hasUnstableRepresentation (getIntPtrType: dl_int_ptr_type, const_folding.jai)
dl_unstable_repr :: (t: Type_Id) -> bool { return dl_ptr_spec(ptr_addrspace(t)).unstable; }
