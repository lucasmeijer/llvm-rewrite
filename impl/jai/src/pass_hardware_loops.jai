// HardwareLoops (hardware-loops<...>): port of llvm/lib/CodeGen/HardwareLoops.cpp (HardwareLoopsPass,
// HardwareLoopsImpl, HardwareLoop) with HardwareLoopInfo::canAnalyze / isHardwareLoopCandidate
// (llvm/lib/Analysis/TargetTransformInfo.cpp) and parseHardwareLoopOptions (llvm/lib/Passes/PassBuilder.cpp).
// No target we model has hardware loops (TTI::isHardwareLoopProfitable is false), so only `force-hardware-loops`
// converts loops. The -force-hardware-loop* / -hardware-loop-* cl::opts only configure the legacy pass: they are
// accepted and ignored. Optimization remarks are not emitted.

hwl_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == "force-hardware-loops" || name == "force-hardware-loop-phi" || name == "force-nested-hardware-loop" ||
       name == "hardware-loop-decrement" || name == "hardware-loop-counter-bitwidth" || name == "force-hardware-loop-guard" return true;
    return false;
}

// HardwareLoopOptions (std::optional fields: has_* = has_value)
Hwl_Options :: struct {
    has_decrement: bool; decrement: u32;
    has_bitwidth: bool; bitwidth: u32;
    force: bool; force_phi: bool; force_nested: bool; force_guard: bool;   // only ever set to true
}

// parseHardwareLoopOptions (the pass name is hardware-loops or hardware-loops<params>)
hwl_parse_options :: (name: string) -> Hwl_Options {
    o: Hwl_Options;
    if name == "hardware-loops" return o;
    params := slice(name, 15, name.count - 16);
    while params.count {
        k := find_index_from_left(params, #char ";");
        p := ifx k >= 0 then slice(params, 0, k) else params;
        params = ifx k >= 0 then slice(params, k + 1, params.count - k - 1) else "";
        parse_count :: (s: string) -> (bool, u32) {
            v, ok, rest := string_to_int(s);
            if !ok || rest.count return false, 0;
            return true, cast,trunc(u32) v;
        }
        if begins_with(p, "hardware-loop-decrement=") {
            ok, v := parse_count(slice(p, 24, p.count - 24));
            if !ok fatal("invalid pass pipeline: invalid HardwareLoopPass parameter '%'", slice(p, 24, p.count - 24));
            o.has_decrement = true; o.decrement = v;
            continue;
        }
        if begins_with(p, "hardware-loop-counter-bitwidth=") {
            ok, v := parse_count(slice(p, 31, p.count - 31));
            if !ok fatal("invalid pass pipeline: invalid HardwareLoopPass parameter '%'", slice(p, 31, p.count - 31));
            o.has_bitwidth = true; o.bitwidth = v;
            continue;
        }
        if p == "force-hardware-loops" o.force = true;
        else if p == "force-hardware-loop-phi" o.force_phi = true;
        else if p == "force-nested-hardware-loop" o.force_nested = true;
        else if p == "force-hardware-loop-guard" o.force_guard = true;
        else fatal("invalid pass pipeline: invalid HardwarePass parameter '%'", p);
    }
    return o;
}

// HardwareLoopInfo
Hwl_Info :: struct {
    l: Loop_Id;
    exit_block: Value_Id = NONE;
    exit_branch: Value_Id = NONE;
    exit_count: Scev_Id = SCEV_NULL;
    count_type: Type_Id;
    loop_decrement: Value_Id;
    is_nesting_legal: bool;
    counter_in_reg: bool;
    perform_entry_test: bool;
}

Hwl :: struct {
    li: *Loop_Info;
    dt: *Dom_Tree;
    opts: Hwl_Options;
    made_change: bool;
}

// HardwareLoopInfo::isHardwareLoopCandidate
hwl_is_candidate :: (h: *Hwl, info: *Hwl_Info, force_nested: bool, force_phi: bool) -> bool {
    li := h.li; l := info.l;
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(li, l, *exiting);
    for bb: exiting {
        if bb != li_loop_latch_of(li, l, bb) {
            if force_phi || info.counter_in_reg continue;
        }
        ec := sc_get_exit_count(l, bb);
        if sc_is_cnc(ec) continue;
        if sc_is_const(ec) {
            if ap_is_zero(sc_ap(ec)) continue;
        } else if !sc_is_loop_invariant(ec, l) continue;
        if sc_type_bits(sc_type(ec)) > type_bits(info.count_type) continue;
        if !info.is_nesting_legal && li_loop_for(li, bb) != l && !force_nested continue;
        not_always := false;
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(li_header(li, l), *preds);
        for p: preds {
            if !li_contains(li, l, p) continue;
            if !dt_dominates(h.dt, bb, p) { not_always = true; break; }
        }
        if not_always continue;
        ti := block_terminator(bb);
        if ti == NONE continue;
        if inst_op(ti) != .CONDBR continue;
        info.exit_branch = ti;
        info.exit_block = bb;
        info.exit_count = ec;
        break;
    }
    return info.exit_block != NONE;
}
// Loop::isLoopLatch(BB): BB is in the loop and branches to the header
li_loop_latch_of :: (li: *Loop_Info, l: Loop_Id, bb: Value_Id) -> Value_Id {
    t := block_terminator(bb);
    n := num_successors(t);
    if n > 0 for k: 0..n - 1 if get_successor(t, k) == li_header(li, l) return bb;
    return NONE;
}

// HardwareLoopsImpl::TryConvertLoop(Loop *L)
hwl_try_convert_loop :: (h: *Hwl, l: Loop_Id) -> bool {
    any_changed := false;
    subs: [..] Loop_Id; subs.allocator = temp;
    for li_subloops(h.li, l) array_add(*subs, it);
    for subs any_changed |= hwl_try_convert_loop(h, it);
    if any_changed return true;
    info: Hwl_Info;
    info.l = l;
    info.count_type = type_int(32);
    info.loop_decrement = const_int(info.count_type, 1);
    // canAnalyze: no irreducible control flow
    rpo: [..] Value_Id; rpo.allocator = temp;
    loop_blocks_rpo(h.li, l, *rpo);
    if contains_irreducible_cfg_rpo(h.li, rpo) return false;
    if !h.opts.force return false;   // !Opts.Force && !TTI.isHardwareLoopProfitable(...) (false for every target we model)
    if h.opts.has_bitwidth info.count_type = type_int(h.opts.bitwidth);
    if h.opts.has_decrement info.loop_decrement = const_int(info.count_type, h.opts.decrement);
    h.made_change |= hwl_try_convert_info(h, *info);
    return h.made_change && (!info.is_nesting_legal && !h.opts.force_nested);
}

// HardwareLoopsImpl::TryConvertLoop(HardwareLoopInfo &)
hwl_try_convert_info :: (h: *Hwl, info: *Hwl_Info) -> bool {
    l := info.l;
    if !hwl_is_candidate(h, info, h.opts.force_nested, h.opts.force_phi) return false;
    ph := li_loop_preheader(h.li, l);
    if ph == NONE ph = insert_preheader_for_loop(h.li, l, h.dt, null, true);
    if ph == NONE return false;
    hwl_create(h, info);
    return true;
}

hwl_strictfp_call :: (c: Value_Id) { if fn_has_fn_attr(inst_fn(c), .StrictFP) call_add_fn_attr(c, .StrictFP); }

// CanGenerateTest
hwl_can_generate_test :: (h: *Hwl, l: Loop_Id, count: Value_Id) -> bool {
    ph := li_loop_preheader(h.li, l);
    pred := block_single_predecessor(ph);
    if pred == NONE return false;
    bi := block_terminator(pred);
    if inst_op(bi) != .CONDBR || !is_inst(op(bi, 0)) || inst_op(op(bi, 0)) != .ICMP return false;
    icmp := op(bi, 0);
    if !icmp_is_equality(inst(icmp).pred) return false;
    is_compare_zero :: (icmp: Value_Id, count: Value_Id, idx: u32) -> bool {
        c := op(icmp, idx);
        if vkind(c) == .C_INT return ap_is_zero(const_ap(c)) && op(icmp, idx ^ 1) == count;
        return false;
    }
    bef_zext: Value_Id = ifx is_inst(count) && inst_op(count) == .ZEXT then op(count, 0) else NONE;
    if !is_compare_zero(icmp, count, 0) && !is_compare_zero(icmp, count, 1) &&
       !is_compare_zero(icmp, bef_zext, 0) && !is_compare_zero(icmp, bef_zext, 1) return false;
    succ_idx: u32 = ifx inst(icmp).pred == ICMP_NE then cast(u32) 0 else 1;
    if get_successor(bi, succ_idx) != ph return false;
    return true;
}

// HardwareLoop::Create (InitLoopCount, InsertIterationSetup, InsertLoopDec / InsertLoopRegDec + InsertPHICounter +
// UpdateBranch)
hwl_create :: (h: *Hwl, info: *Hwl_Info) {
    li := h.li; l := info.l;
    use_phi := info.counter_in_reg || h.opts.force_phi;
    use_loop_guard := info.perform_entry_test;
    // InitLoopCount
    x: Scev_Expander; sx_init(*x, "loopcnt");
    ec := info.exit_count;
    if !is_ptr_type(sc_type(ec)) && sc_type(ec) != info.count_type ec = sc_get_zero_extend(ec, info.count_type);
    ec = sc_get_add2(ec, sc_get_one(info.count_type));
    if sc_is_loop_entry_guarded_by_cond(l, ICMP_NE, ec, sc_get_zero(sc_type(ec))) {
        if h.opts.force_guard use_loop_guard = true;
    } else use_loop_guard = false;
    bb := li_loop_preheader(li, l);
    if use_loop_guard && block_single_predecessor(bb) != NONE && inst_op(block_terminator(bb)) == .BR {
        p := block_single_predecessor(bb);
        if !sx_is_safe_to_expand_at(*x, ec, block_terminator(p)) use_loop_guard = false;
        else bb = p;
    }
    if !sx_is_safe_to_expand_at(*x, ec, block_terminator(bb)) return;
    count := sx_expand_code_for_at(*x, ec, info.count_type, block_terminator(bb));
    use_loop_guard = use_loop_guard && hwl_can_generate_test(h, l, count);
    begin_bb := ifx use_loop_guard then bb else li_loop_preheader(li, l);

    // InsertIterationSetup
    b: Irb; irb_set_before(*b, block_terminator(begin_bb));
    ty := vtype(count);
    iname: string;
    if use_loop_guard iname = ifx use_phi then "llvm.test.start.loop.iterations" else "llvm.test.set.loop.iterations";
    else iname = ifx use_phi then "llvm.start.loop.iterations" else "llvm.set.loop.iterations";
    loop_setup := irb_intrinsic(*b, iname, .[ty], .[count]);
    hwl_strictfp_call(loop_setup);
    if use_loop_guard {
        set_count := ifx use_phi then irb_extract_value(*b, loop_setup, .[1]) else loop_setup;
        guard := block_terminator(begin_bb);
        set_op(guard, 0, set_count);
        if get_successor(guard, 0) != li_loop_preheader(li, l) swap_successors(guard);
    }
    if use_phi && use_loop_guard loop_setup = irb_extract_value(*b, loop_setup, .[0]);
    setup := ifx !use_phi then count else loop_setup;

    exit_branch := info.exit_branch;
    if use_phi {
        // InsertLoopRegDec
        cb: Irb; irb_set_before(*cb, exit_branch);
        loop_dec := irb_intrinsic(*cb, "llvm.loop.decrement.reg", .[vtype(count)], .[count, info.loop_decrement]);
        hwl_strictfp_call(loop_dec);
        // InsertPHICounter
        header := li_header(li, l);
        pb: Irb; irb_set_at(*pb, header, block_first_non_phi(header), true);
        index := irb_phi(*pb, vtype(setup), 2);
        phi_add_incoming(index, setup, li_loop_preheader(li, l));
        phi_add_incoming(index, loop_dec, inst_block(exit_branch));
        set_op(loop_dec, 0, index);
        // UpdateBranch
        ub: Irb; irb_set_before(*ub, exit_branch);
        new_cond := irb_icmp(*ub, ICMP_NE, loop_dec, const_int(vtype(loop_dec), 0));
        old_cond := op(exit_branch, 0);
        set_op(exit_branch, 0, new_cond);
        if !li_contains(li, l, get_successor(exit_branch, 0)) swap_successors(exit_branch);
        ivs_recursively_delete_trivially_dead(old_cond, null);
    } else {
        // InsertLoopDec
        cb: Irb; irb_set_before(*cb, exit_branch);
        new_cond := irb_intrinsic(*cb, "llvm.loop.decrement", .[vtype(info.loop_decrement)], .[info.loop_decrement]);
        hwl_strictfp_call(new_cond);
        old_cond := op(exit_branch, 0);
        set_op(exit_branch, 0, new_cond);
        if !li_contains(li, l, get_successor(exit_branch, 0)) swap_successors(exit_branch);
        ivs_recursively_delete_trivially_dead(old_cond, null);
    }
    blocks: [..] Value_Id; blocks.allocator = temp;
    for li_blocks(li, l) array_add(*blocks, it);
    for blocks ivs_delete_dead_phis(it, null);
}

// HardwareLoopsPass::run
hardware_loops_run :: (node: *Pass_Node, f: Value_Id) -> Preserved {
    h: Hwl;
    h.opts = hwl_parse_options(node.name);
    h.li = get_loop_info(f);
    s := get_scev(f);
    h.dt = get_domtree(f);
    se = s;
    saved := scev_pass_se;
    scev_pass_se = s;
    defer scev_pass_se = saved;
    tops: [..] Loop_Id; tops.allocator = temp;
    for h.li.top_level array_add(*tops, it);
    for tops if li_is_outermost(h.li, it) hwl_try_convert_loop(*h, it);
    if !h.made_change return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .LOOPS);
    preserve(*pa, .SCEV);
    preserve(*pa, .DOMTREE);
    preserve(*pa, .BPI);
    return pa;
}
