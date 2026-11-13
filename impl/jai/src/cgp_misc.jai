// CodeGenPrepare, part 4: port of llvm/lib/CodeGen/CodeGenPrepare.cpp: optimizeShiftInst, optimizeFunnelShift,
// sinkSelectOperand, isFormingBranchFromSelectProfitable, getTrueOrFalseValue, optimizeSelectInst (with
// SplitBlockAndInsertIfThen/Else/ThenElse of llvm/lib/Transforms/Utils/BasicBlockUtils.cpp), optimizeShuffleVectorInst,
// tryToSinkFreeOperands (X86TTIImpl::isProfitableToSinkOperands), optimizeSwitchType / optimizeSwitchPhiConstants,
// optimizeExtractElementInst, splitMergedValStore, tryUnmergingGEPsAcrossIndirectBr, optimizeBranch.

inline_asm_constraints :: (asm: Value_Id) -> string { return inline_asms[ir.v_aux[asm]].constraints; }

// X86TTIImpl::isVectorShiftByScalarCheap
cgp_is_vector_shift_by_scalar_cheap :: (ty: Type_Id) -> bool {
    bits := type_bits(scalar_type(ty));
    st := cgp.xl;
    if xs_has(st, X86FLD_HasXOP) && (bits == 8 || bits == 16 || bits == 32 || bits == 64) return false;
    if st_hasAVX2(st) && (bits == 32 || bits == 64) return false;
    if st_hasBWI(st) && bits == 16 return false;
    return true;
}

// optimizeShiftInst
cgp_optimize_shift_inst :: (shift: Value_Id) -> bool {
    ty := vtype(shift);
    if !is_vector_type(ty) || !cgp_is_vector_shift_by_scalar_cheap(ty) return false;
    sel := op(shift, 1);
    if !(is_inst(sel) && inst_op(sel) == .SELECT && has_one_use(sel)) return false;
    c := op(sel, 0); tv := op(sel, 1); fv := op(sel, 2);
    if !is_splat_value(tv) || !is_splat_value(fv) return false;
    b: Irb; irb_set_before(*b, shift);
    o := inst_op(shift);
    nt := irb_binop(*b, o, op(shift, 0), tv);
    nf := irb_binop(*b, o, op(shift, 0), fv);
    ns := irb_select(*b, c, nt, nf);
    cgp_rauw(shift, ns);
    erase_inst_with_metadata(shift);
    return true;
}

// optimizeFunnelShift
cgp_optimize_funnel_shift :: (fsh: Value_Id) -> bool {
    ty := vtype(fsh);
    if !is_vector_type(ty) || !cgp_is_vector_shift_by_scalar_cheap(ty) return false;
    sel := call_arg(fsh, 2);
    if !(is_inst(sel) && inst_op(sel) == .SELECT && has_one_use(sel)) return false;
    c := op(sel, 0); tv := op(sel, 1); fv := op(sel, 2);
    if !is_splat_value(tv) || !is_splat_value(fv) return false;
    b: Irb; irb_set_before(*b, fsh);
    name := iid_name(call_iid(fsh));
    x := call_arg(fsh, 0); y := call_arg(fsh, 1);
    if is_const(x) && is_const(y) && is_const(tv) fatal("codegenprepare: constant-folding a funnel shift is not supported yet");
    nt := irb_intrinsic(*b, name, .[ty], .[x, y, tv]);
    nf := irb_intrinsic(*b, name, .[ty], .[x, y, fv]);
    ns := irb_select(*b, c, nt, nf);
    cgp_rauw(fsh, ns);
    erase_inst_with_metadata(fsh);
    return true;
}

// sinkSelectOperand
cgp_sink_select_operand :: (v: Value_Id) -> bool {
    return is_inst(v) && has_one_use(v) && is_safe_to_speculatively_execute(v) && tti_is_expensive_to_speculatively_execute(cgp.t, v);
}

// isFormingBranchFromSelectProfitable
cgp_is_forming_branch_from_select_profitable :: (si: Value_Id) -> bool {
    // TLI->isPredictableSelectExpensive(): X86 sets PredictableSelectIsExpensive to SchedModel.isOutOfOrder()
    if !x86_sched_is_out_of_order(cgp.xl) return false;
    ok, tw, fw := extract_branch_weights_2(si);
    if ok {
        mx := max(tw, fw);
        sum := tw + fw;
        if sum != 0 {
            p := bprob_get(mx, sum);
            if p > tti_predictable_branch_threshold_prob(cgp.t) return true;
        }
    }
    cmp := op(si, 0);
    if !(is_inst(cmp) && (inst_op(cmp) == .ICMP || inst_op(cmp) == .FCMP)) || !has_one_use(cmp) return false;
    if cgp_sink_select_operand(op(si, 1)) || cgp_sink_select_operand(op(si, 2)) return true;
    return false;
}

// getTrueOrFalseValue
cgp_get_true_or_false_value :: (si: Value_Id, is_true: bool, selects: [] Value_Id) -> Value_Id {
    v: Value_Id = NONE;
    in_set :: (s: [] Value_Id, x: Value_Id) -> bool { for s if it == x return true; return false; }
    def := si;
    while def != NONE && in_set(selects, def) {
        v = ifx is_true then op(def, 1) else op(def, 2);
        def = ifx is_inst(v) && inst_op(v) == .SELECT then v else NONE;
    }
    return v;
}

// SplitBlockAndInsertIfThenElse(Cond, SplitBefore, ThenBlock?, ElseBlock?, false, false, nullptr, DTU, LI)
// -> (ThenBlock, ElseBlock, Tail); a block not asked for is NONE
cgp_split_block_and_insert_if_then_else :: (cond: Value_Id, split_before: Value_Id, head_bit: bool, want_then: bool, want_else: bool) -> (Value_Id, Value_Id, Value_Id) {
    head := inst_block(split_before);
    orig: [..] Value_Id; orig.allocator = temp;
    {
        s: [..] Value_Id; s.allocator = temp;
        block_successors(head, *s);
        for s { dup := false; for x: orig if x == it dup = true; if !dup array_add(*orig, it); }
    }
    f := block_fn(head);
    tail := split_basic_block(head, split_before, "", head_bit);
    tb := tail; fb := tail;
    then_edge, else_edge := false, false;
    dl := get_metadata(split_before, 0);
    mk :: (f: Value_Id, tail: Value_Id, dl: Md_Id) -> Value_Id {
        bb := create_block(f, "", tail);
        br := create_br(tail);
        block_append_inst(bb, br);
        set_metadata(br, 0, dl);
        return bb;
    }
    then_b, else_b: Value_Id = NONE;
    if want_then { tb = mk(f, tail, dl); then_edge = true; then_b = tb; }
    if want_else { fb = mk(f, tail, dl); else_edge = true; else_b = fb; }
    old := block_terminator(head);
    nt := create_cond_br(cond, tb, fb);
    // ReplaceInstWithInst
    if get_metadata(nt, 0) == NONE { d := get_metadata(old, 0); if d != NONE set_metadata(nt, 0, d); }
    insert_at_position(nt, head, old, false);
    erase_inst_with_metadata(old);
    ups: [..] Dom_Update; ups.allocator = temp;
    array_add(*ups, .{true, head, tb});
    array_add(*ups, .{true, head, fb});
    if then_edge array_add(*ups, .{true, tb, tail});
    if else_edge array_add(*ups, .{true, fb, tail});
    for orig array_add(*ups, .{true, tail, it});
    for orig array_add(*ups, .{false, head, it});
    dtu_apply(*cgp.dtu, ups);
    if cgp.li {
        l := li_loop_for(cgp.li, head);
        if l != NONE {
            if then_edge li_add_basic_block_to_loop(cgp.li, l, tb);
            if else_edge li_add_basic_block_to_loop(cgp.li, l, fb);
            li_add_basic_block_to_loop(cgp.li, l, tail);
        }
    }
    return then_b, else_b, tail;
}

// optimizeSelectInst
cgp_optimize_select_inst :: (si: Value_Id) -> bool {
    if cgp_cl.disable_select_to_branch return false;
    asi: [..] Value_Id; asi.allocator = temp;
    array_add(*asi, si);
    x := inst_next(si);
    while x != NONE {
        if inst_op(x) == .SELECT && op(x, 0) == op(si, 0) array_add(*asi, x);
        else break;
        x = inst_next(x);
    }
    last_si := asi[asi.count - 1];
    cgp.cur_inst = inst_next(last_si);
    for k: 1..asi.count - 1 cgp_fixup_dbg_variable_records_on_inst(asi[k]);
    cond := op(si, 0);
    vector_cond := !(type_kind(vtype(cond)) == .INT && type_bits(vtype(cond)) == 1);
    if vector_cond || get_metadata(si, md_fixed("unpredictable")) != NONE return false;
    // TLI->isSelectSupported(Kind): true (base)
    if !cgp_is_forming_branch_from_select_profitable(si) || cgp_should_optimize_for_size(inst_block(si)) return false;

    true_instrs: [..] Value_Id; true_instrs.allocator = temp;
    false_instrs: [..] Value_Id; false_instrs.allocator = temp;
    for s: asi {
        if cgp_sink_select_operand(op(s, 1)) array_add(*true_instrs, op(s, 1));
        if cgp_sink_select_operand(op(s, 2)) array_add(*false_instrs, op(s, 2));
    }
    start := inst_block(si);
    split_pt := inst_next(last_si);
    b: Irb; irb_set_before(*b, si);
    fr := new_inst(.FREEZE, vtype(cond), 1);
    set_op(fr, 0, cond);
    cond_fr := irb_insert(*b, fr, tconcat(vname(si), ".frozen"));
    true_block, false_block, end_block: Value_Id = NONE;
    true_branch, false_branch: Value_Id = NONE;
    if true_instrs.count == 0 {
        _, eb, tl := cgp_split_block_and_insert_if_then_else(cond_fr, split_pt, true, false, true);
        false_block = eb; false_branch = block_terminator(eb);
        end_block = get_successor(false_branch, 0);
    } else if false_instrs.count == 0 {
        tb, _, tl := cgp_split_block_and_insert_if_then_else(cond_fr, split_pt, true, true, false);
        true_block = tb; true_branch = block_terminator(tb);
        end_block = get_successor(true_branch, 0);
    } else {
        tb, eb, tl := cgp_split_block_and_insert_if_then_else(cond_fr, split_pt, true, true, true);
        true_branch = block_terminator(tb); false_branch = block_terminator(eb);
        true_block = tb; false_block = eb;
        end_block = get_successor(true_branch, 0);
    }
    set_name(end_block, "select.end");
    if true_block != NONE set_name(true_block, "select.true.sink");
    if false_block != NONE set_name(false_block, ifx false_instrs.count == 0 then "select.false" else "select.false.sink");
    if cgp.is_huge_func {
        if true_block != NONE cgp_fresh_insert(true_block);
        if false_block != NONE cgp_fresh_insert(false_block);
        cgp_fresh_insert(end_block);
    }
    bfi_set_block_freq(cgp.bfi, end_block, bfi_get_block_freq(cgp.bfi, start));
    // copyMetadata(*SI, {prof, unpredictable, make.implicit, dbg}): the debug location is copied even when empty
    copy_metadata_kinds(block_terminator(start), si, .[md_fixed("prof"), md_fixed("unpredictable"), md_fixed("make.implicit")]);
    set_metadata(block_terminator(start), 0, get_metadata(si, 0));
    for true_instrs inst_move_before_dbg(it, true_branch);
    for false_instrs inst_move_before_dbg(it, false_branch);
    if true_block == NONE true_block = start;
    else if false_block == NONE false_block = start;
    ins: [..] Value_Id; ins.allocator = temp;
    for asi array_add(*ins, it);
    k := asi.count - 1;
    while k >= 0 {
        s := asi[k];
        pn := create_phi(vtype(s), 2);
        insert_at_position(pn, end_block, block_first(end_block), false);
        take_name(pn, s);
        phi_add_incoming(pn, cgp_get_true_or_false_value(s, true, ins), true_block);
        phi_add_incoming(pn, cgp_get_true_or_false_value(s, false, ins), false_block);
        set_metadata(pn, 0, get_metadata(s, 0));
        cgp_rauw(s, pn);
        erase_inst_with_metadata(s);
        for ins if it == s { array_ordered_remove_by_index(*ins, it_index); break; }
        k -= 1;
    }
    cgp.cur_inst = NONE;   // CurInstIterator = StartBlock->end()
    return true;
}
// MCSchedModel::isOutOfOrder: MicroOpBufferSize > 1. Every X86 model sets it above 1 (GenericX86Model 32,
// SandyBridgeModel 168, ...) except AtomModel (0); an unknown CPU gets MCSchedModel::Default (0).
x86_sched_is_out_of_order :: (st: *X86_Lowering) -> bool {
    for X86_SCHED if it.cpu == st.tune_cpu return it.model != "AtomModel";
    return false;
}

// optimizeShuffleVectorInst: TLI->shouldConvertSplatType returns nullptr (base; no X86 override)
cgp_optimize_shuffle_vector_inst :: (svi: Value_Id) -> bool { return false; }

// X86TTIImpl::isProfitableToSinkOperands -> uses (in LLVM's push order)
cgp_x86_profitable_to_sink_operands :: (i: Value_Id, ops: *[..] Use_Id) -> bool {
    st := cgp.xl;
    o := inst_op(i);
    if o == .AND && (st_hasBMI(st) || (is_vector_type(vtype(i)) && st_hasSSE2(st))) {
        for k: 0..cast(s64) nops(i) - 1 {
            u := ir.v_ops[i] + cast(u32) k;
            v := ir.u_val[u];
            ok, _ := pm_not(v);
            if ok && !(type_kind(vtype(i)) == .INT && type_bits(vtype(i)) == 8) { array_add(ops, u); return true; }
            // (and X, (splat (not Y))): shufflevector (insertelement _, (not Y), 0), _, zeroinitializer
            if is_inst(v) && inst_op(v) == .SHUFFLEVECTOR && shuffle_mask_is_zero(v) {
                ie := op(v, 0);
                if is_inst(ie) && inst_op(ie) == .INSERTELEMENT && pm_zero_int(op(ie, 2)) {
                    okn, _ := pm_not(op(ie, 1));
                    if okn {
                        array_add(ops, ir.v_ops[ie] + 1);
                        array_add(ops, ir.v_ops[v]);
                        array_add(ops, u);
                        return true;
                    }
                }
            }
        }
    }
    vt := vtype(i);
    if type_kind(vt) != .VECTOR return false;
    if o == .MUL && type_kind(type_elem(vt)) == .INT && type_bits(type_elem(vt)) == 64 {
        for k: 0..cast(s64) nops(i) - 1 {
            u := ir.v_ops[i] + cast(u32) k;
            v := ir.u_val[u];
            dup := false;
            for ops.* if ir.u_val[it] == v { dup = true; break; }
            if dup continue;
            if st_hasSSE41(st) && cgp_match_ashr_shl32(v) {
                array_add(ops, ir.v_ops[v]);
                array_add(ops, u);
            } else if st_hasSSE2(st) && is_inst(v) && inst_op(v) == .AND && pm_specific_int(op(v, 1), 0xffffffff) {
                array_add(ops, u);
            }
        }
        return ops.count > 0;
    }
    amt := -1;
    if o == .SHL || o == .LSHR || o == .ASHR amt = 1;
    else { id := call_iid(i); if id == IID_FSHL || id == IID_FSHR amt = 2; }
    if amt == -1 return false;
    shuf := op(i, cast(u32) amt);
    if is_inst(shuf) && inst_op(shuf) == .SHUFFLEVECTOR && get_splat_index(shuffle_mask_s32(shuf)) >= 0 && cgp_is_vector_shift_by_scalar_cheap(vt) {
        array_add(ops, ir.v_ops[i] + cast(u32) amt);
        return true;
    }
    return false;
}
cgp_match_ashr_shl32 :: (v: Value_Id) -> bool {
    if !(is_inst(v) && inst_op(v) == .ASHR && pm_specific_int(op(v, 1), 32)) return false;
    s := op(v, 0);
    return is_inst(s) && inst_op(s) == .SHL && pm_specific_int(op(s, 1), 32);
}
shuffle_mask_is_zero :: (sv: Value_Id) -> bool {
    m := shuffle_mask_s32(sv);
    for m if it != 0 return false;
    return true;
}

// tryToSinkFreeOperands
cgp_try_to_sink_free_operands :: (i: Value_Id) -> bool {
    ops: [..] Use_Id; ops.allocator = temp;
    if !cgp_x86_profitable_to_sink_operands(i, *ops) return false;
    target_bb := inst_block(i);
    changed := false;
    to_replace: [..] Use_Id; to_replace.allocator = temp;
    insert_point := i;
    k := ops.count - 1;
    while k >= 0 {
        u := ops[k];
        k -= 1;
        ui := ir.u_val[u];
        if inst_op(ui) == .PHI || may_have_side_effects(ui) || may_read_from_memory(ui) continue;
        if inst_block(ui) == target_bb {
            if comes_before(ui, insert_point) insert_point = ui;
            continue;
        }
        array_add(*to_replace, u);
    }
    maybe_dead: [..] Value_Id; maybe_dead.allocator = temp;
    new_insts: Table(Value_Id, Value_Id); new_insts.allocator = temp;
    for u: to_replace {
        ui := ir.u_val[u];
        ni := ic_clone_inst(ui);
        if cgp.is_huge_func {
            for kk: 0..cast(s64) nops(ni) - 1 { x := op(ni, cast(u32) kk); if is_inst(x) cgp_fresh_insert(inst_block(x)); }
        }
        table_set(*new_insts, ui, ni);
        dup := false;
        for maybe_dead if it == ui dup = true;
        if !dup array_add(*maybe_dead, ui);
        insert_at_position(ni, inst_block(insert_point), insert_point, false);
        insert_point = ni;
        table_set(*cgp.inserted_insts, ni, true);
        old_i := ir.u_user[u];
        found, nold := table_find(*new_insts, old_i);
        if found set_op(nold, use_operand_no(u), ni);
        else use_set(u, ni);
        changed = true;
    }
    for maybe_dead if !has_uses(it) erase_inst_with_metadata(it);
    return changed;
}

// optimizeSwitchType
cgp_optimize_switch_type :: (si: Value_Id) -> bool {
    c := op(si, 0);
    old_ty := vtype(c);
    old_vt := cgp_evt(old_ty);
    // X86TargetLowering::getPreferredSwitchConditionType: i32 below 32 bits, else getRegisterType(Context, VT)
    reg_width: u32;
    if evt_bits(old_vt) < 32 reg_width = 32;
    else reg_width = cgp_register_type_bits(old_vt);
    if reg_width <= type_bits(old_ty) return false;
    new_ty := type_int(reg_width);
    ext_type := Opcode.ZEXT;
    // isSExtCheaperThanZExt: false (base)
    if vkind(c) == .ARGUMENT {
        f := arg_parent(c);
        pa := attr_list_param(glob(f).attrs, arg_numbers[ir.v_aux[c]]);
        if attr_set_has(pa, .SExt) ext_type = .SEXT;
        if attr_set_has(pa, .ZExt) ext_type = .ZEXT;
    }
    ext := create_cast(ext_type, c, new_ty);
    insert_at_position(ext, inst_block(si), si, false);
    set_metadata(ext, 0, get_metadata(si, 0));
    set_op(si, 0, ext);
    n := switch_num_cases(si);
    for k: 0..cast(s64) n - 1 {
        cv := switch_case_value(si, cast(u32) k);
        narrow := const_ap(cv);
        wide := ifx ext_type == .ZEXT then ap_zext(narrow, reg_width) else ap_sext(narrow, reg_width);
        ir.u_aux[ir.v_ops[si] + 2 + cast(u32) k] = const_int_ap(new_ty, wide);
    }
    return true;
}
// TargetLoweringBase::getRegisterType(Context, VT): RegisterTypeForVT for a simple type, else the register type of
// the type it is transformed to
cgp_register_type_bits :: (vt: Evt) -> u32 {
    t := vt;
    while !evt_is_simple(t) {
        n := xl_type_to_transform_to(cgp.xl, t);
        if evt_eq(n, t) fatal("codegenprepare: getRegisterType of an extended type that does not transform");
        t = n;
    }
    return mvt_bits(cgp.xl.register_type[xl_ord(t.m)]);
}

// optimizeSwitchPhiConstants
cgp_optimize_switch_phi_constants :: (si: Value_Id) -> bool {
    cond := op(si, 0);
    if vkind(cond) == .C_INT return false;
    changed := false;
    switch_bb := inst_block(si);
    cond_ty := vtype(cond);
    n := switch_num_cases(si);
    for k: 0..cast(s64) n - 1 {
        case_value := switch_case_value(si, cast(u32) k);
        case_bb := get_successor(si, cast(u32) (k + 1));
        checked := false;
        for phi: block_insts(case_bb) {
            if inst_op(phi) != .PHI break;
            phi_ty := vtype(phi);
            try_zext := type_kind(phi_ty) == .INT && type_bits(phi_ty) > type_bits(cond_ty) && cgp_is_zext_free(cond_ty, phi_ty);
            if phi_ty == cond_ty || try_zext {
                skip_case := false;
                replacement: Value_Id = NONE;
                for ii: 0..cast(s64) nops(phi) - 1 {
                    pv := phi_value(phi, cast(u32) ii);
                    if pv != case_value {
                        if !try_zext continue;
                        if vkind(pv) != .C_INT || !ap_eq(const_ap(pv), ap_zext(const_ap(case_value), type_bits(phi_ty))) continue;
                    }
                    if phi_block(phi, cast(u32) ii) != switch_bb continue;
                    if !checked {
                        checked = true;
                        if cgp_switch_find_case_dest(si, case_bb) == NONE { skip_case = true; break; }
                    }
                    if replacement == NONE {
                        if pv == case_value replacement = cond;
                        else {
                            b: Irb; irb_set_before(*b, si);
                            replacement = irb_cast(*b, .ZEXT, cond, phi_ty);
                        }
                    }
                    set_op(phi, cast(u32) ii, replacement);
                    changed = true;
                }
                if skip_case break;
            }
        }
    }
    return changed;
}

cgp_optimize_switch_inst :: (si: Value_Id) -> bool {
    changed := cgp_optimize_switch_type(si);
    changed |= cgp_optimize_switch_phi_constants(si);
    return changed;
}

// optimizeExtractElementInst: TLI->canCombineStoreAndExtract is false (base; no X86 override)
cgp_optimize_extract_element_inst :: (i: Value_Id) -> bool {
    if cgp_cl.stress_store_extract fatal("codegenprepare: -stress-cgp-store-extract is not supported yet");
    return false;
}

// splitMergedValStore
cgp_split_merged_val_store :: (si: Value_Id) -> bool {
    store_ty := vtype(op(si, 0));
    if type_kind(store_ty) == .SVECTOR return false;
    bits := dl_type_size_bits(store_ty);
    if dl_type_store_size(store_ty) * 8 != bits || bits == 0 return false;
    half := cast(u32) (bits / 2);
    split_ty := type_int(half);
    if dl_type_store_size(split_ty) * 8 != dl_type_size_bits(split_ty) return false;
    if !load_store_is_simple(si) return false;
    v := op(si, 0);
    if !(is_inst(v) && inst_op(v) == .OR) return false;
    lvalue, hvalue: Value_Id = NONE;
    matched := false;
    for side: 0..1 {
        a := op(v, cast(u32) side); bb := op(v, cast(u32) (1 - side));
        if !(is_inst(a) && inst_op(a) == .ZEXT && has_one_use(a)) continue;
        if !(is_inst(bb) && inst_op(bb) == .SHL && has_one_use(bb)) continue;
        z := op(bb, 0);
        if !(is_inst(z) && inst_op(z) == .ZEXT && has_one_use(z)) continue;
        if !pm_specific_int(op(bb, 1), cast(u64) half) continue;
        lvalue = op(a, 0); hvalue = op(z, 0);
        matched = true;
        break;
    }
    if !matched return false;
    if type_kind(vtype(lvalue)) != .INT || dl_type_size_bits(vtype(lvalue)) > cast(u64) half ||
       type_kind(vtype(hvalue)) != .INT || dl_type_size_bits(vtype(hvalue)) > cast(u64) half return false;
    lbc := ifx is_inst(lvalue) && inst_op(lvalue) == .BITCAST then lvalue else NONE;
    hbc := ifx is_inst(hvalue) && inst_op(hvalue) == .BITCAST then hvalue else NONE;
    low_ty := vtype(ifx lbc != NONE then op(lbc, 0) else lvalue);
    high_ty := vtype(ifx hbc != NONE then op(hbc, 0) else hvalue);
    // X86TargetLowering::isMultiStoresCheaperThanBitsMerge: only a float / int mix
    lfp := is_fp_type(scalar_type(low_ty)); hfp := is_fp_type(scalar_type(high_ty));
    lint := type_kind(scalar_type(low_ty)) == .INT; hint := type_kind(scalar_type(high_ty)) == .INT;
    if !cgp_cl.force_split_store && !((lfp && hint) || (lint && hfp)) return false;
    fatal("codegenprepare: splitMergedValStore is not supported yet");
    return false;
}

// GEPSequentialConstIndexed
cgp_gep_sequential_const_indexed :: (g: Value_Id) -> bool {
    return nops(g) == 2 && vkind(op(g, 1)) == .C_INT;   // the first index is always sequential
}
// TTI->getIntImmCost(Imm, Ty, TCK_SizeAndLatency) > TCC_Basic
cgp_imm_cost_above_basic :: (imm: APInt, ty: Type_Id) -> bool { return cast(s64) x86_int_imm_cost(imm, ty) > TCC_BASIC; }

// tryUnmergingGEPsAcrossIndirectBr
cgp_try_unmerging_geps_across_indirectbr :: (gepi: Value_Id) -> bool {
    src_block := inst_block(gepi);
    if inst_op(block_terminator(src_block)) != .INDIRECTBR return false;
    if !cgp_gep_sequential_const_indexed(gepi) return false;
    idx_c := op(gepi, 1);
    if cgp_imm_cost_above_basic(const_ap(idx_c), vtype(idx_c)) return false;
    gep_op := op(gepi, 0);
    if !is_inst(gep_op) || inst_block(gep_op) != src_block return false;
    any_outside := false;
    u := ir.v_first_use[gepi];
    while u != NONE { usr := ir.u_user[u]; if is_inst(usr) && inst_block(usr) != src_block { any_outside = true; break; } u = ir.u_next[u]; }
    if !any_outside return false;
    ugepis: [..] Value_Id; ugepis.allocator = temp;
    u = ir.v_first_use[gep_op];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if usr == gepi continue;
        if !is_inst(usr) return false;
        if inst_block(usr) == src_block continue;
        if inst_op(usr) != .GEP return false;
        if !cgp_gep_sequential_const_indexed(usr) return false;
        if op(usr, 0) != gep_op return false;
        if inst(usr).ty2 != inst(gepi).ty2 return false;
        if vtype(idx_c) != vtype(op(usr, 1)) return false;
        if cgp_imm_cost_above_basic(const_ap(op(usr, 1)), vtype(op(usr, 1))) return false;
        array_add(*ugepis, usr);
    }
    if ugepis.count == 0 return false;
    for ug: ugepis {
        nidx := ap_sub(const_ap(op(ug, 1)), const_ap(idx_c));
        if cgp_imm_cost_above_basic(nidx, vtype(idx_c)) return false;
    }
    for ug: ugepis {
        set_op(ug, 0, gepi);
        nidx := ap_sub(const_ap(op(ug, 1)), const_ap(idx_c));
        set_op(ug, 1, const_int_ap(vtype(idx_c), nidx));
        // GEPNoWrapFlags::intersectForOffsetAdd
        fa := inst(gepi).flags; fb := inst(ug).flags;
        inb := (fa & F_INBOUNDS) != 0 && (fb & F_INBOUNDS) != 0;
        nusw := ((fa & (F_INBOUNDS | F_NUSW)) != 0) && ((fb & (F_INBOUNDS | F_NUSW)) != 0);
        nuw := (fa & F_GEP_NUW) != 0 && (fb & F_GEP_NUW) != 0;
        if !inb nusw = false;
        if ap_is_negative(nidx) nuw = false;
        nf := fb & ~cast(u32) (F_INBOUNDS | F_NUSW | F_GEP_NUW);
        if inb nf |= F_INBOUNDS; else if nusw nf |= F_NUSW;
        if nuw nf |= F_GEP_NUW;
        inst(ug).flags = nf;
    }
    return true;
}

// optimizeBranch: TLI.preferZeroCompareBranch() is false (base; no X86 override)
cgp_optimize_branch :: (br: Value_Id) -> bool { return false; }

// SwitchInst::findCaseDest(BB): the single case value leading to BB (nullptr for the default or several cases)
cgp_switch_find_case_dest :: (sw: Value_Id, bb: Value_Id) -> Value_Id {
    if bb == op(sw, 1) return NONE;
    ci: Value_Id = NONE;
    n := switch_num_cases(sw);
    for k: 0..cast(s64) n - 1 {
        if get_successor(sw, cast(u32) (k + 1)) != bb continue;
        if ci != NONE return NONE;
        ci = switch_case_value(sw, cast(u32) k);
    }
    return ci;
}
