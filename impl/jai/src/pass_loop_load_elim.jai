// LoopLoadElimination: llvm/lib/Transforms/Scalar/LoopLoadElimination.cpp. Loops that need LoopVersioning (runtime
// memory checks or SCEV predicates) fail loudly: LoopVersioning is not ported yet.

lle_opts: struct {
    check_per_elim: s64 = 1;          // -runtime-check-per-loop-load-elim
    scev_check_threshold: s64 = 8;    // -loop-load-elimination-scev-check-threshold
};
LLE_CL_OPT_COUNT :: 2;
add_lle_cl_opts :: (list: [] Cl_Opt, base: s64) {
    list[base + 0] = .{"runtime-check-per-loop-load-elim", .INT, null, *lle_opts.check_per_elim, null};
    list[base + 1] = .{"loop-load-elimination-scev-check-threshold", .INT, null, *lle_opts.scev_check_threshold, null};
}

// StoreToLoadForwardingCandidate
Lle_Cand :: struct { load: Value_Id; store: Value_Id; }

Lel :: struct {          // LoadEliminationForLoop
    l: Loop_Id;
    li: *Loop_Info;
    lai: *Laa;
    dt: *Dom_Tree;
    pse: Pse;            // a copy of LAI.getPSE()
    inst_order: Table(Value_Id, u32);
}

// isDependenceDistanceOfOne
lle_is_dependence_distance_of_one :: (c: *Lel, cand: Lle_Cand) -> bool {
    load_ptr := op(cand.load, 0);
    store_ptr := op(cand.store, 1);
    load_ty := load_store_type(cand.load);
    empty: Table(Value_Id, Scev_Id); empty.allocator = temp;   // getPtrStride's default StridesMap
    oks, sl := laa_get_ptr_stride_assume(*c.pse, c.li, load_ty, load_ptr, c.l, c.dt, *empty, false, true);
    if !oks sl = 0;
    okt, ss := laa_get_ptr_stride_assume(*c.pse, c.li, load_ty, store_ptr, c.l, c.dt, *empty, false, true);
    if !okt ss = 0;
    if sl == 0 || ss == 0 || sl != ss return false;
    if sl != 1 && sl != -1 return false;
    type_byte_size := cast(s64) dl_type_alloc_size(load_ty);
    lp := pse_get_scev(*c.pse, load_ptr);
    sp := pse_get_scev(*c.pse, store_ptr);
    dist := sc_get_minus(sp, lp);
    if !sc_is_const(dist) return false;
    v := sc_ap(dist);
    want := ap_from_u64(v.bits, cast,no_check(u64) (type_byte_size * sl));
    return ap_eq(v, want);
}

// findStoreToLoadDependences (std::forward_list: emplace_front, so the list is in reverse dependence order)
lle_find_store_to_load_dependences :: (c: *Lel) -> [..] Lle_Cand {
    cands: [..] Lle_Cand; cands.allocator = temp;
    d := *c.lai.dc;
    if !d.record_dependences return cands;
    unknown_loads: [..] Value_Id; unknown_loads.allocator = temp;
    for dep: d.dependences {
        src := d.inst_map[dep.source]; dst := d.inst_map[dep.destination];
        if dep.type == .Unknown || dep.type == .IndirectUnsafe || dep.type == .InvariantUnsafe {
            if inst_op(src) == .LOAD && !block_set_contains(unknown_loads, src) array_add(*unknown_loads, src);
            if inst_op(dst) == .LOAD && !block_set_contains(unknown_loads, dst) array_add(*unknown_loads, dst);
            continue;
        }
        if dep_is_backward(dep.type) { t := src; src = dst; dst = t; }
        if inst_op(src) != .STORE continue;
        if inst_op(dst) != .LOAD continue;
        if !is_bit_or_noop_pointer_castable(load_store_type(src), load_store_type(dst)) continue;
        array_insert_at(*cands, .{dst, src}, 0);   // emplace_front
    }
    if unknown_loads.count {
        k := 0;
        for cands if !block_set_contains(unknown_loads, it.load) { cands[k] = it; k += 1; }
        cands.count = k;
    }
    return cands;
}
dep_is_backward :: (t: Dep_Type) -> bool { return t == .BackwardVectorizable || t == .Backward || t == .BackwardVectorizableButPreventsForwarding; }

lle_instr_index :: (c: *Lel, i: Value_Id) -> u32 { found, v := table_find(*c.inst_order, i); assert(found, "No index for instruction"); return v; }

// removeDependencesFromMultipleStores
lle_remove_dependences_from_multiple_stores :: (c: *Lel, cands: *[..] Lle_Cand) {
    single: Table(Value_Id, s64); single.allocator = temp;   // Load -> index of the single candidate, -1 = none
    for cand, ci: cands.* {
        found, other := table_find(*single, cand.load);
        if !found { table_set(*single, cand.load, ci); continue; }
        if other < 0 continue;
        oc := cands.*[other];
        if inst_block(cand.store) == inst_block(oc.store) && lle_is_dependence_distance_of_one(c, cand) && lle_is_dependence_distance_of_one(c, oc) {
            if lle_instr_index(c, oc.store) < lle_instr_index(c, cand.store) table_set(*single, cand.load, ci);
        } else table_set(*single, cand.load, -1);
    }
    k := 0;
    for cand, ci: cands.* {
        _, s := table_find(*single, cand.load);
        if s != ci continue;
        cands.*[k] = cand; k += 1;
    }
    cands.count = k;
}

// findPointersWrittenOnForwardingPath
lle_pointers_written_on_forwarding_path :: (c: *Lel, cands: [] Lle_Cand) -> [..] Value_Id {
    last_load := cands[0].load;
    for cands if lle_instr_index(c, it.load) > lle_instr_index(c, last_load) last_load = it.load;   // max_element: first max
    first_store := cands[0].store;
    for cands if lle_instr_index(c, it.store) < lle_instr_index(c, first_store) first_store = it.store;
    ptrs: [..] Value_Id; ptrs.allocator = temp;
    mem := c.lai.dc.inst_map;
    insert_store_ptr :: (ptrs: *[..] Value_Id, i: Value_Id) {
        if inst_op(i) != .STORE return;
        p := op(i, 1);
        if !block_set_contains(ptrs.*, p) array_add(ptrs, p);
    }
    for k: lle_instr_index(c, first_store) + 1..mem.count-1 insert_store_ptr(*ptrs, mem[k]);
    li := cast(s64) lle_instr_index(c, last_load);
    for k: 0..li-1 insert_store_ptr(*ptrs, mem[k]);
    return ptrs;
}

// collectMemchecks: indices into LAI's checks
lle_collect_memchecks :: (c: *Lel, cands: [] Lle_Cand) -> [..] s64 {
    written := lle_pointers_written_on_forwarding_path(c, cands);
    load_ptrs: [..] Value_Id; load_ptrs.allocator = temp;
    for cands if !block_set_contains(load_ptrs, op(it.load, 0)) array_add(*load_ptrs, op(it.load, 0));
    r := *c.lai.rt;
    checks: [..] s64; checks.allocator = temp;
    for chk, ci: r.checks {
        needed := false;
        for i1: r.groups[chk[0]].members {
            for i2: r.groups[chk[1]].members {
                p1 := r.pointers[i1].ptr; p2 := r.pointers[i2].ptr;
                if (block_set_contains(written, p1) && block_set_contains(load_ptrs, p2)) || (block_set_contains(written, p2) && block_set_contains(load_ptrs, p1)) { needed = true; break; }
            }
            if needed break;
        }
        if needed array_add(*checks, ci);
    }
    return checks;
}

// propagateStoredValueToLoadUsers
lle_propagate_stored_value_to_load_users :: (c: *Lel, cand: Lle_Cand, x: *Scev_Expander) {
    ptr := op(cand.load, 0);
    ptr_scev := pse_get_scev(*c.pse, ptr);
    ph := li_loop_preheader(c.li, c.l);
    initial_ptr := sx_expand_code_for_at(x, sc_start(ptr_scev), vtype(ptr), block_terminator(ph));
    initial := new_inst(.LOAD, vtype(cand.load), 1);
    set_op(initial, 0, initial_ptr);
    inst(initial).align = inst(cand.load).align;
    insert_at_position(initial, ph, block_terminator(ph), false);
    set_name(initial, "load_initial");
    // DebugLoc::getDropped(): no location
    phi := create_phi(vtype(initial), 2);
    h := li_header(c.li, c.l);
    insert_at_position(phi, h, block_first(h), true);
    set_name(phi, "store_forwarded");
    phi_add_incoming(phi, initial, ph);
    load_ty := vtype(initial);
    store_val := op(cand.store, 0);
    if load_ty != vtype(store_val) {
        cast_ := create_bit_or_pointer_cast_inst(store_val, load_ty);
        insert_at_position(cast_, inst_block(cand.store), cand.store, false);
        set_name(cast_, "store_forward_cast");
        set_metadata(cast_, 0, get_metadata(cand.load, 0));
        store_val = cast_;
    }
    phi_add_incoming(phi, store_val, li_loop_latch(c.li, c.l));
    rauw_with_metadata(cand.load, phi);
    set_metadata(phi, 0, get_metadata(cand.load, 0));
}
// CastInst::CreateBitOrPointerCast (always an instruction)
create_bit_or_pointer_cast_inst :: (v: Value_Id, t: Type_Id) -> Value_Id {
    st := vtype(v);
    opc: Opcode = .BITCAST;
    if type_kind(scalar_type(st)) == .PTR && is_int_type(scalar_type(t)) opc = .PTRTOINT;
    else if is_int_type(scalar_type(st)) && type_kind(scalar_type(t)) == .PTR opc = .INTTOPTR;
    return create_cast(opc, v, t);
}

// processLoop
lel_process_loop :: (c: *Lel) -> bool {
    cands := lle_find_store_to_load_dependences(c);
    if cands.count == 0 return false;
    for i, k: c.lai.dc.inst_map table_set(*c.inst_order, i, cast(u32) k);   // generateInstructionOrderMap
    lle_remove_dependences_from_multiple_stores(c, *cands);
    if cands.count == 0 return false;
    candidates: [..] Lle_Cand; candidates.allocator = temp;
    latches: [..] Value_Id; latches.allocator = temp;
    li_loop_latches(c.li, c.l, *latches);
    for cand: cands {
        dominates_all := true;
        for latches if !dt_dominates(c.dt, inst_block(cand.store), it) { dominates_all = false; break; }
        if !dominates_all continue;
        if inst_block(cand.load) != li_header(c.li, c.l) continue;   // isLoadConditional
        if !lle_is_dependence_distance_of_one(c, cand) continue;
        array_add(*candidates, cand);
    }
    if candidates.count == 0 return false;
    checks := lle_collect_memchecks(c, candidates);
    if checks.count > candidates.count * lle_opts.check_per_elim return false;
    if c.lai.pse.preds.count > lle_opts.scev_check_threshold return false;
    if !li_is_loop_simplify_form(c.li, c.l) return false;
    if checks.count != 0 || !sc_union_is_always_true(c.lai.pse.preds) {
        if c.lai.has_convergent_op return false;
        // shouldOptimizeForSize(Header, PSI, BFI): false without a ProfileSummaryInfo
        fatal("loop-load-elim: LoopVersioning (runtime checks or SCEV predicates) is not supported yet");
    }
    x: Scev_Expander;
    sx_init(*x, "storeforward");
    for candidates lle_propagate_stored_value_to_load_users(c, it, *x);
    return true;
}

// LoopLoadEliminationPass::run / eliminateLoadsAcrossLoops
loop_load_elim_run :: (f: Value_Id) -> Preserved {
    li := get_loop_info(f);
    if li.top_level.count == 0 return PRESERVE_ALL;
    s := get_scev(f);
    dt := get_domtree(f);
    ac := get_assumption_cache(f);
    // MAMProxy.getCachedResult<ProfileSummaryAnalysis>: never cached here (require<profile-summary> is not supported),
    // so PSI and BFI are null and shouldOptimizeForSize is false
    se = s;
    saved := scev_pass_se;
    scev_pass_se = s;
    defer scev_pass_se = saved;
    changed := false;
    worklist: [..] Loop_Id; worklist.allocator = temp;
    tops: [..] Loop_Id; tops.allocator = temp;
    for li.top_level array_add(*tops, it);
    for top: tops {
        pre: [..] Loop_Id; pre.allocator = temp;   // depth_first(TopLevelLoop)
        stack: [..] Loop_Id; stack.allocator = temp;
        array_add(*stack, top);
        while stack.count {
            l := pop(*stack);
            array_add(*pre, l);
            subs := li_subloops(li, l);
            for < subs array_add(*stack, it);
        }
        for l: pre {
            changed |= simplify_loop(li, l, dt, ac, null, false);
            if li_subloops(li, l).count == 0 array_add(*worklist, l);
        }
    }
    for l: worklist {
        if !li_is_rotated_form(li, l) || li_exiting_block(li, l) == NONE continue;
        lai := laa_cached_info(f, l, li, dt, ac, false);
        c: Lel;
        c.l = l; c.li = li; c.lai = lai; c.dt = dt;
        c.inst_order.allocator = temp;
        pse_copy(*c.pse, *lai.pse);
        changed |= lel_process_loop(*c);
    }
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    preserve(*pa, .LOOPS);
    return pa;
}
