// LoopVersioning: llvm/lib/Transforms/Utils/LoopVersioning.cpp (versionLoop, addPHINodes, the noalias annotation),
// with addRuntimeChecks / expandBounds (llvm/lib/Transforms/Utils/LoopUtils.cpp), cloneLoopWithPreheader /
// CloneBasicBlock / remapInstructionsInBlocks (llvm/lib/Transforms/Utils/CloneFunction.cpp) and SCEVExpander's
// predicate expansion (expandCodeForPredicate, expandComparePredicate, generateOverflowCheck, expandWrapPredicate,
// expandUnionPredicate; llvm/lib/Transforms/Utils/ScalarEvolutionExpander.cpp).

lver_opts: struct { annotate_no_alias := true; };   // -loop-version-annotate-no-alias

// ---------------------------------------------------------------- cloning (CloneFunction.cpp)

// CloneBasicBlock(BB, VMap, NameSuffix, F): the new block is appended to F
clone_basic_block :: (bb: Value_Id, vm: *Table(Value_Id, Value_Id), suffix: string, f: Value_Id) -> Value_Id {
    nb := create_block(f, "", NONE);
    if vname(bb).count set_name(nb, tprint("%1%2", vname(bb), suffix));
    recs: [..] u32; recs.allocator = temp;
    for i: block_insts(bb) {
        c := inst_clone(i);
        block_append_inst(nb, c);
        if vname(i).count set_name(c, tprint("%1%2", vname(i), suffix));
        if inst(i).records clone_debug_info_from(c, i, inst(i).records, *recs);
        table_set(vm, i, c);
    }
    return nb;
}

// cloneLoopWithPreheader(Before, LoopDomBB, OrigLoop, VMap, NameSuffix, LI, DT, Blocks)
clone_loop_with_preheader :: (before: Value_Id, loop_dom_bb: Value_Id, orig: Loop_Id, vm: *Table(Value_Id, Value_Id), suffix: string,
                              li: *Loop_Info, dt: *Dom_Tree, blocks: *[..] Value_Id) -> Loop_Id {
    f := li.fn;
    parent := li_parent(li, orig);
    lmap: Table(Loop_Id, Loop_Id); lmap.allocator = temp;
    new_loop := li_alloc_loop(li);
    table_set(*lmap, orig, new_loop);
    if parent != NONE li_add_child_loop(li, parent, new_loop);
    else li_add_top_level_loop(li, new_loop);
    orig_ph := li_loop_preheader(li, orig);
    new_ph := clone_basic_block(orig_ph, vm, suffix, f);
    table_set(vm, orig_ph, new_ph);
    array_add(blocks, new_ph);
    if parent != NONE li_add_basic_block_to_loop(li, parent, new_ph);
    dt_add_new_block(dt, new_ph, loop_dom_bb);
    pre: [..] Loop_Id; pre.allocator = temp;
    li_loops_in_preorder_of(li, orig, *pre);
    for cur: pre {
        if table_contains(*lmap, cur) continue;
        nl := li_alloc_loop(li);
        _, np := table_find(*lmap, li_parent(li, cur));
        li_add_child_loop(li, np, nl);
        table_set(*lmap, cur, nl);
    }
    obl: [..] Value_Id; obl.allocator = temp;
    for li_blocks(li, orig) array_add(*obl, it);
    for bb: obl {
        _, nl := table_find(*lmap, li_loop_for(li, bb));
        nb := clone_basic_block(bb, vm, suffix, f);
        table_set(vm, bb, nb);
        li_add_basic_block_to_loop(li, nl, nb);
        dt_add_new_block(dt, nb, new_ph);
        array_add(blocks, nb);
    }
    for bb: obl {
        cur := li_loop_for(li, bb);
        _, nb := table_find(vm, bb);
        if bb == li_header(li, cur) { _, nl := table_find(*lmap, cur); li_move_to_header(li, nl, nb); }
        _, nidom := table_find(vm, dt_idom_block(dt, bb));
        dt_change_idom(dt, nb, nidom);
    }
    // F->splice: the new preheader, then everything from the new header to the end of F, go before `before`
    fn_unlink_block(f, new_ph);
    fn_insert_block_before(f, before, new_ph);
    nh := li_header(li, new_loop);
    moving: [..] Value_Id; moving.allocator = temp;
    b := nh;
    while b != NONE { array_add(*moving, b); b = block(b).next; }
    for moving { fn_unlink_block(f, it); fn_insert_block_before(f, before, it); }
    return new_loop;
}
// Loop::getLoopsInPreorder
li_loops_in_preorder_of :: (li: *Loop_Info, l: Loop_Id, out: *[..] Loop_Id) {
    stack: [..] Loop_Id; stack.allocator = temp;
    array_add(*stack, l);
    while stack.count {
        x := pop(*stack);
        array_add(out, x);
        subs := li_subloops(li, x);
        for < subs array_add(*stack, it);
    }
}

// remapInstructionsInBlocks(Blocks, VMap) with RF_NoModuleLevelChanges | RF_IgnoreMissingLocals: operands and phi
// blocks found in VMap are replaced, metadata maps to itself
remap_instructions_in_blocks :: (blocks: [] Value_Id, vm: *Table(Value_Id, Value_Id)) {
    recs: [..] u32; recs.allocator = temp;
    for bb: blocks for i: block_insts(bb) {
        recs.count = 0;
        r := inst(i).records;
        while r != 0 { array_add(*recs, r); r = dbgr(r).next; }
        remap_dbg_records(recs, vm);
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            o := op(i, cast(u32) k);
            if o == NONE continue;
            found, m := table_find(vm, o);
            if found && m != o set_op(i, cast(u32) k, m);
        }
        if inst_op(i) == .PHI {
            for k: 0..cast(s64) n - 1 {
                found, m := table_find(vm, phi_block(i, cast(u32) k));
                if found phi_set_block(i, cast(u32) k, m);
            }
        }
    }
}

// ---------------------------------------------------------------- an IRBuilder<InstSimplifyFolder>

isf_binop :: (b: *Irb, opc: Opcode, l: Value_Id, r: Value_Id, name := "") -> Value_Id {
    q: Simplify_Query; q.have_tli = false;
    f := simplify_binop(opc, l, r, q);
    if f != NONE return f;
    i := new_inst(opc, vtype(l), 2);
    set_op(i, 0, l); set_op(i, 1, r);
    return irb_insert(b, i, name);
}
isf_icmp :: (b: *Irb, pred: u8, l: Value_Id, r: Value_Id, name := "") -> Value_Id {
    q: Simplify_Query; q.have_tli = false;
    f := simplify_cmp_inst(pred, false, l, r, q);
    if f != NONE return f;
    return irb_insert(b, create_icmp(pred, l, r), name);
}

// ---------------------------------------------------------------- SCEVExpander predicate expansion

// expandComparePredicate
sx_expand_compare_predicate :: (x: *Scev_Expander, p: u32, ip: Value_Id) -> Value_Id {
    r := se.preds[p];
    sx_set_insert_point(x, ip);
    e0 := sx_expand(x, r.a);
    sx_set_insert_point(x, ip);
    e1 := sx_expand(x, r.b);
    sx_set_insert_point(x, ip);
    return sx_create_icmp(x, icmp_inverse(r.pred), e0, e1, "ident.check");
}
// generateOverflowCheck
sx_generate_overflow_check :: (x: *Scev_Expander, ar: Scev_Id, loc: Value_Id, signed: bool) -> Value_Id {
    preds: [..] u32; preds.allocator = temp;
    exit_count := sc_get_predicated_symbolic_max_backedge_taken_count(sc_loop(ar), *preds);
    step := sc_step_recurrence(ar);
    start := sc_start(ar);
    ar_ty := sc_type(ar);
    src_bits := sc_type_bits(sc_type(exit_count));
    dst_bits := sc_type_bits(ar_ty);
    expand_at :: (x: *Scev_Expander, s: Scev_Id, loc: Value_Id) -> Value_Id { sx_set_insert_point(x, loc); return sx_expand(x, s); }
    trip := expand_at(x, exit_count, loc);
    ty := type_int(dst_bits);
    step_v := expand_at(x, step, loc);
    neg_step_v := expand_at(x, sc_get_negative(step), loc);
    start_v := expand_at(x, start, loc);
    zero := const_int(ty, 0);
    sx_set_insert_point(x, loc);
    step_cmp := sx_create_icmp(x, ICMP_SLT, step_v, zero);
    abs_step := sx_create_select(x, step_cmp, neg_step_v, step_v);
    // ComputeEndCheck
    trunc_trip := sx_create_zext_or_trunc(x, trip, ty);
    mul := sx_create_intrinsic(x, "llvm.umul.with.overflow", .[ty], .[abs_step, trunc_trip], "mul");
    mul_v := sx_create_extract_value(x, mul, 0, "mul.result");
    of_mul := sx_create_extract_value(x, mul, 1, "mul.overflow");
    add, sub: Value_Id = NONE, NONE;
    need_pos := !sc_is_known_negative(step);
    need_neg := !sc_is_known_positive(step);
    if type_kind(ar_ty) == .PTR {
        neg_mul := sx_create_binop(x, .SUB, const_null_value(vtype(mul_v)), mul_v);   // CreateNeg
        if need_pos add = sx_create_ptr_add(x, start_v, mul_v);
        if need_neg sub = sx_create_ptr_add(x, start_v, neg_mul);
    } else {
        if need_pos add = sx_create_binop(x, .ADD, start_v, mul_v);
        if need_neg sub = sx_create_binop(x, .SUB, start_v, mul_v);
    }
    end_lt, end_gt, end_check: Value_Id = NONE, NONE, NONE;
    if need_pos { end_lt = sx_create_icmp(x, ifx signed then cast(u8) ICMP_SLT else ICMP_ULT, add, start_v); end_check = end_lt; }
    if need_neg { end_gt = sx_create_icmp(x, ifx signed then cast(u8) ICMP_SGT else ICMP_UGT, sub, start_v); end_check = end_gt; }
    if need_pos && need_neg end_check = sx_create_select(x, step_cmp, end_gt, end_lt);
    end_check = sx_create_binop(x, .OR, end_check, of_mul);
    if src_bits > dst_bits {
        max_val := ap_zext(ap_all_ones(dst_bits), src_bits);
        be_check := sx_create_icmp(x, ICMP_UGT, trip, const_int_ap(type_int(src_bits), max_val));
        be_check = sx_create_binop(x, .AND, be_check, sx_create_icmp(x, ICMP_NE, step_v, zero));
        end_check = sx_create_binop(x, .OR, end_check, be_check);
    }
    return end_check;
}
sx_create_zext_or_trunc :: (x: *Scev_Expander, v: Value_Id, ty: Type_Id) -> Value_Id {
    a := type_int_width(vtype(v)); b := type_int_width(ty);
    if a < b return sx_create_cast(x, .ZEXT, v, ty);
    if a > b return sx_create_cast(x, .TRUNC, v, ty);
    return v;
}
// CreateExtractValue (InstSimplifyFolder: simplifyExtractValueInst)
sx_create_extract_value :: (x: *Scev_Expander, agg: Value_Id, idx: u32, name: string) -> Value_Id {
    idxs := u32.[idx];
    f := simplify_extract_value_inst(agg, idxs, sx_q());
    if f != NONE return f;
    rt := vtype(agg);
    rt = type_sub(rt, ifx type_kind(rt) == .STRUCT then idx else 0);
    i := new_inst(.EXTRACTVALUE, rt, 1);
    set_op(i, 0, agg);
    r := inst(i);
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = 1;
    array_add(*ir.u32_pool, idx);
    return sx_insert(x, i, name);
}
// expandWrapPredicate
sx_expand_wrap_predicate :: (x: *Scev_Expander, p: u32, ip: Value_Id) -> Value_Id {
    r := se.preds[p];
    nusw, nssw: Value_Id = NONE, NONE;
    if r.pred & INCREMENT_NUSW nusw = sx_generate_overflow_check(x, r.a, ip, false);
    if r.pred & INCREMENT_NSSW nssw = sx_generate_overflow_check(x, r.a, ip, true);
    if nusw != NONE && nssw != NONE return sx_create_binop(x, .OR, nusw, nssw);
    if nusw != NONE return nusw;
    if nssw != NONE return nssw;
    return const_false();
}
// expandCodeForPredicate for one compare / wrap predicate
sx_expand_one_predicate :: (x: *Scev_Expander, p: u32, ip: Value_Id) -> Value_Id {
    if se.preds[p].kind == .COMPARE return sx_expand_compare_predicate(x, p, ip);
    return sx_expand_wrap_predicate(x, p, ip);
}
// expandUnionPredicate
sx_expand_union_predicate :: (x: *Scev_Expander, preds: [] u32, ip: Value_Id) -> Value_Id {
    checks: [..] Value_Id; checks.allocator = temp;
    for preds {
        array_add(*checks, sx_expand_one_predicate(x, it, ip));
        sx_set_insert_point(x, ip);
    }
    if checks.count == 0 return const_false();
    acc := checks[0];
    for k: 1..checks.count-1 acc = sx_create_binop(x, .OR, acc, checks[k]);   // CreateOr(ArrayRef)
    return acc;
}

// ---------------------------------------------------------------- addRuntimeChecks (LoopUtils.cpp)

Ptr_Bounds :: struct { start: Value_Id; end: Value_Id; stride: Value_Id = NONE; }
// expandBounds(CG, TheLoop, Loc, Exp, HoistRuntimeChecks)
lver_expand_bounds :: (g: *Rt_Group, l: Loop_Id, li: *Loop_Info, loc: Value_Id, x: *Scev_Expander) -> Ptr_Bounds {
    ptr_ty := type_ptr(g.addrspace);
    low := g.low; high := g.high; stride := SCEV_NULL;
    outer := li_parent(li, l);
    if laa_opts.hoist_runtime_checks && outer != NONE && sc_is_addrec(high) && sc_is_addrec(low) {
        recur := sc_step_recurrence(low);
        if recur == sc_step_recurrence(high) && sc_loop(high) == outer && sc_loop(low) == outer {
            oec := sc_get_exit_count(outer, li_loop_latch(li, outer), .EXACT);
            if !sc_is_cnc(oec) && is_int_type(sc_type(oec)) {
                nh := sc_evaluate_at_iteration(high, oec);
                if !sc_is_cnc(nh) {
                    high = nh;
                    low = sc_start(low);
                    if !sc_is_known_non_negative(sc_apply_loop_guards(recur, outer)) stride = recur;
                }
            }
        }
    }
    r: Ptr_Bounds;
    r.start = sx_expand_code_for_at(x, low, ptr_ty, loc);
    r.end = sx_expand_code_for_at(x, high, ptr_ty, loc);
    if g.needs_freeze {
        b: Irb;
        irb_set_before(*b, loc);
        fs := new_inst(.FREEZE, vtype(r.start), 1); set_op(fs, 0, r.start);
        r.start = irb_insert(*b, fs, tprint("%.fr", vname(r.start)));
        fe := new_inst(.FREEZE, vtype(r.end), 1); set_op(fe, 0, r.end);
        r.end = irb_insert(*b, fe, tprint("%.fr", vname(r.end)));
    }
    if stride != SCEV_NULL r.stride = sx_expand_code_for_at(x, stride, sc_type(stride), loc);
    return r;
}

// addRuntimeChecks(Loc, TheLoop, PointerChecks, Exp, HoistRuntimeChecks): NONE when there are no checks
lver_add_runtime_checks :: (loc: Value_Id, l: Loop_Id, li: *Loop_Info, rt: *Rpc, checks: [] s64, x: *Scev_Expander) -> Value_Id {
    Pair :: struct { a: Ptr_Bounds; b: Ptr_Bounds; }
    expanded: [..] Pair; expanded.allocator = temp;
    for ci: checks {
        c := rt.checks[ci];
        first := lver_expand_bounds(*rt.groups[c[0]], l, li, loc, x);
        second := lver_expand_bounds(*rt.groups[c[1]], l, li, loc, x);
        array_add(*expanded, .{first, second});
    }
    b: Irb;
    irb_set_before(*b, loc);
    mem_check: Value_Id = NONE;
    for e: expanded {
        cmp0 := isf_icmp(*b, ICMP_ULT, e.a.start, e.b.end, "bound0");
        cmp1 := isf_icmp(*b, ICMP_ULT, e.b.start, e.a.end, "bound1");
        conflict := isf_binop(*b, .AND, cmp0, cmp1, "found.conflict");
        if e.a.stride != NONE {
            neg := isf_icmp(*b, ICMP_SLT, e.a.stride, const_int(vtype(e.a.stride), 0), "stride.check");
            conflict = isf_binop(*b, .OR, conflict, neg);
        }
        if e.b.stride != NONE {
            neg := isf_icmp(*b, ICMP_SLT, e.b.stride, const_int(vtype(e.b.stride), 0), "stride.check");
            conflict = isf_binop(*b, .OR, conflict, neg);
        }
        if mem_check != NONE conflict = isf_binop(*b, .OR, mem_check, conflict, "conflict.rdx");
        mem_check = conflict;
    }
    sx_erase_dead_instructions(x, mem_check);
    return mem_check;
}

// ---------------------------------------------------------------- LoopVersioning

Lver :: struct {
    versioned: Loop_Id;
    non_versioned: Loop_Id = NONE;
    lai: *Laa;
    checks: [] s64;                     // AliasChecks: indices into lai.rt.checks
    li: *Loop_Info;
    dt: *Dom_Tree;
    vm: Table(Value_Id, Value_Id);
}

// LoopVersioning::versionLoop(DefsUsedOutside = {})
lver_version_loop :: (v: *Lver) {
    li := v.li; dt := v.dt; l := v.versioned;
    v.vm.allocator = temp;
    check_bb := li_loop_preheader(li, l);
    exp2: Scev_Expander; sx_init(*exp2, "induction");
    mem_check := lver_add_runtime_checks(block_terminator(check_bb), l, li, *v.lai.rt, v.checks, *exp2);
    exp: Scev_Expander; sx_init(*exp, "scev.check");
    scev_check := sx_expand_union_predicate(*exp, v.lai.pse.preds, block_terminator(check_bb));
    b: Irb;
    rc: Value_Id;
    if mem_check != NONE && scev_check != NONE {
        irb_set_before(*b, block_terminator(check_bb));
        rc = isf_binop(*b, .OR, mem_check, scev_check, "lver.safe");
    } else rc = ifx mem_check != NONE then mem_check else scev_check;
    sx_erase_dead_instructions(*exp, scev_check);
    header_name := vname(li_header(li, l));
    set_name(check_bb, tprint("%.lver.check", header_name));
    ph := split_block(check_bb, block_terminator(check_bb), dt, li, null, tprint("%.ph", header_name));
    nvb: [..] Value_Id; nvb.allocator = temp;
    v.non_versioned = clone_loop_with_preheader(ph, check_bb, l, *v.vm, ".lver.orig", li, dt, *nvb);
    remap_instructions_in_blocks(nvb, *v.vm);
    orig_term := block_terminator(check_bb);
    irb_set_before(*b, orig_term);
    bi := irb_insert(*b, create_cond_br(rc, li_loop_preheader(li, v.non_versioned), li_loop_preheader(li, l)));
    set_explicitly_unknown_branch_weights_if_profiled(bi, "loop-versioning");
    erase_inst(orig_term);
    dt_change_idom(dt, li_exit_block(li, l), check_bb);
    lver_add_phi_nodes(v);
    form_dedicated_exit_blocks(li, v.non_versioned, dt, null, true);
    form_dedicated_exit_blocks(li, l, dt, null, true);
}

// addPHINodes with no DefsUsedOutside
lver_add_phi_nodes :: (v: *Lver) {
    phi_block_ := li_exit_block(v.li, v.versioned);
    for pn: block_insts(phi_block_) {
        if inst_op(pn) != .PHI break;
        cloned := op(pn, 0);
        found, m := table_find(*v.vm, cloned);
        if found cloned = m;
        phi_add_incoming(pn, cloned, li_exiting_block(v.li, v.non_versioned));
    }
}
