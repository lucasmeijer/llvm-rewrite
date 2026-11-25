// The ObjC ARC passes: a port of
//   llvm/lib/Transforms/ObjCARC/ObjCARCOpts.cpp       objc-arc (ObjCARCOpt: peepholes, weak calls, retain/release
//                                                      pairing with BBState / BlotMapVector, returns, pools)
//   llvm/lib/Transforms/ObjCARC/ObjCARCContract.cpp   objc-arc-contract
//   llvm/lib/Transforms/ObjCARC/ObjCARCExpand.cpp     objc-arc-expand
//   llvm/lib/Transforms/ObjCARC/ProvenanceAnalysisEvaluator.cpp   pa-eval
// The shared analyses (ARCInstKind, ProvenanceAnalysis, DependencyAnalysis, PtrState) are in objcarc.jai.

// ---------------------------------------------------------------- BBState (ObjCARCOpts.cpp)

// BlotMapVector<const Value *, PtrState>: insertion-ordered (the per-pointer maps are never blotted)
Arc_Ptr_Map :: struct {
    keys: [..] Value_Id;
    vals: [..] Arc_Ptr_State;
    index: Table(Value_Id, s64);   // built once the map has more than ARC_PM_LINEAR entries
}
ARC_PM_LINEAR :: 16;
arc_pm_find :: (m: *Arc_Ptr_Map, key: Value_Id) -> s64 {
    if m.keys.count <= ARC_PM_LINEAR {
        for m.keys if it == key return it_index;
        return -1;
    }
    if m.index.count != m.keys.count {
        if m.index.allocator.proc == null m.index.allocator = temp;
        table_reset(*m.index);
        for m.keys table_set(*m.index, it, it_index);
    }
    p := table_find_pointer(*m.index, key);
    if p return p.*;
    return -1;
}
arc_pm_add :: (m: *Arc_Ptr_Map, key: Value_Id, v: Arc_Ptr_State) -> s64 {
    if m.keys.allocator.proc == null { m.keys.allocator = temp; m.vals.allocator = temp; }
    array_add(*m.keys, key);
    array_add(*m.vals, v);
    n := m.keys.count - 1;
    if m.index.count == n && n >= ARC_PM_LINEAR {
        if m.index.allocator.proc == null m.index.allocator = temp;
        table_set(*m.index, key, n);
    }
    return n;
}
// operator[]
arc_pm_get :: (m: *Arc_Ptr_Map, key: Value_Id) -> *Arc_Ptr_State {
    i := arc_pm_find(m, key);
    if i < 0 { e: Arc_Ptr_State; i = arc_pm_add(m, key, e); }
    return *m.vals[i];
}
arc_pm_clear :: (m: *Arc_Ptr_Map) { m.keys.count = 0; m.vals.count = 0; if m.index.count table_reset(*m.index); }
arc_pm_copy :: (dst: *Arc_Ptr_Map, src: *Arc_Ptr_Map) {
    arc_pm_clear(dst);
    for src.keys arc_pm_add(dst, it, arc_ps_copy(src.vals[it_index]));
}

ARC_OVERFLOW :: 0xffff_ffff;

Arc_Bb_State :: struct {
    td_count: u32;
    bu_count: u32;
    td: Arc_Ptr_Map;
    bu: Arc_Ptr_Map;
    preds: [..] Value_Id;
    succs: [..] Value_Id;
}

// GetAllPathCountWithOverflow: (overflow, path count)
arc_all_path_count :: (s: *Arc_Bb_State) -> bool, u32 {
    if s.td_count == ARC_OVERFLOW || s.bu_count == ARC_OVERFLOW return true, 0;
    p := cast(u64) s.td_count * cast(u64) s.bu_count;
    if p >> 32 return true, 0;
    pc := cast(u32) p;
    return pc == ARC_OVERFLOW, pc;
}

arc_merge_pred :: (s: *Arc_Bb_State, o: *Arc_Bb_State) {
    if s.td_count == ARC_OVERFLOW return;
    s.td_count += o.td_count;
    if s.td_count == ARC_OVERFLOW { arc_pm_clear(*s.td); return; }
    if s.td_count < o.td_count { s.td_count = ARC_OVERFLOW; arc_pm_clear(*s.td); return; }
    for key, oi: o.td.keys {
        i := arc_pm_find(*s.td, key);
        if i < 0 {
            i = arc_pm_add(*s.td, key, arc_ps_copy(o.td.vals[oi]));
            e: Arc_Ptr_State;
            arc_ps_merge(*s.td.vals[i], *e, true);
        } else arc_ps_merge(*s.td.vals[i], *o.td.vals[oi], true);
    }
    for key, i: s.td.keys {
        if arc_pm_find(*o.td, key) < 0 { e: Arc_Ptr_State; arc_ps_merge(*s.td.vals[i], *e, true); }
    }
}
arc_merge_succ :: (s: *Arc_Bb_State, o: *Arc_Bb_State) {
    if s.bu_count == ARC_OVERFLOW return;
    s.bu_count += o.bu_count;
    if s.bu_count == ARC_OVERFLOW { arc_pm_clear(*s.bu); return; }
    if s.bu_count < o.bu_count { s.bu_count = ARC_OVERFLOW; arc_pm_clear(*s.bu); return; }
    for key, oi: o.bu.keys {
        i := arc_pm_find(*s.bu, key);
        if i < 0 {
            i = arc_pm_add(*s.bu, key, arc_ps_copy(o.bu.vals[oi]));
            e: Arc_Ptr_State;
            arc_ps_merge(*s.bu.vals[i], *e, false);
        } else arc_ps_merge(*s.bu.vals[i], *o.bu.vals[oi], false);
    }
    for key, i: s.bu.keys {
        if arc_pm_find(*o.bu, key) < 0 { e: Arc_Ptr_State; arc_ps_merge(*s.bu.vals[i], *e, false); }
    }
}

// BlotMapVector<Value *, RRInfo> (Retains) and DenseMap<Value *, RRInfo> (Releases)
Arc_Rr_Map :: struct {
    keys: [..] Value_Id;      // NONE = blotted
    vals: [..] Arc_Rr_Info;
    index: Table(Value_Id, s64);
}
arc_rm_init :: (m: *Arc_Rr_Map) { m.keys.allocator = temp; m.vals.allocator = temp; m.index.allocator = temp; }
arc_rm_find :: (m: *Arc_Rr_Map, key: Value_Id) -> *Arc_Rr_Info {
    p := table_find_pointer(*m.index, key);
    if !p return null;
    return *m.vals[p.*];
}
arc_rm_set :: (m: *Arc_Rr_Map, key: Value_Id, r: Arc_Rr_Info) {
    p := table_find_pointer(*m.index, key);
    if p { m.vals[p.*] = arc_rri_copy(r); return; }
    table_set(*m.index, key, m.keys.count);
    array_add(*m.keys, key);
    array_add(*m.vals, arc_rri_copy(r));
}
arc_rm_blot :: (m: *Arc_Rr_Map, key: Value_Id) {
    p := table_find_pointer(*m.index, key);
    if !p return;
    m.keys[p.*] = NONE;
    table_remove(*m.index, key);
}

// ---------------------------------------------------------------- ObjCARCOpt

Arc_Opt :: struct {
    f: Value_Id;
    changed: bool;
    cfg_changed: bool;
    pa: Arc_Pa;
    ep: Arc_Entry_Points;
    bundled: *Arc_Bundled;
    disable_pairing: bool;
    used: u32;                        // UsedInThisFunction
    colors: Arc_Colors;               // BlockEHColors
    // OptimizeSequences state
    states: [..] Arc_Bb_State;
    state_index: Table(Value_Id, s32);
}

arc_state :: (o: *Arc_Opt, bb: Value_Id) -> *Arc_Bb_State {
    p := table_find_pointer(*o.state_index, bb);
    assert(p != null, "objc-arc: block without a BBState");
    return *o.states[p.*];
}

// FindSingleUseIdentifiedObject
arc_find_single_use_identified_object :: (a: Value_Id) -> Value_Id {
    if is_constant_data(a) return NONE;
    if has_one_use(a) {
        if is_inst(a) && inst_op(a) == .BITCAST return arc_find_single_use_identified_object(op(a, 0));
        if is_inst(a) && inst_op(a) == .GEP && gep_has_all_zero_indices(a) return arc_find_single_use_identified_object(op(a, 0));
        if arc_is_forwarding(arc_basic_kind(a)) return arc_find_single_use_identified_object(arc_arg0(a));
        if !arc_is_objc_identified_object(a) return NONE;
        return a;
    }
    if arc_is_objc_identified_object(a) {
        u := ir.v_first_use[a];
        while u != NONE {
            usr := ir.u_user[u];
            if has_uses(usr) || arc_rc_identity_root(usr) != a return NONE;
            u = ir.u_next[u];
        }
        return a;
    }
    return NONE;
}

// OptimizeRetainRVCall
arc_optimize_retain_rv_call :: (o: *Arc_Opt, rv: Value_Id) -> bool {
    a := arc_arg_rc_identity_root(rv);
    if is_inst(a) && is_call_base(a) {
        if inst_block(a) == inst_block(rv) {
            i := inst(a).next;
            while arc_is_noop_instruction(i) i = inst(i).next;
            if i == rv return false;
        } else if inst_op(a) == .INVOKE {
            p := inst_block(rv);
            if get_successor(a, 0) == p {
                i := block(p).first;
                while arc_is_noop_instruction(i) i = inst(i).next;
                if i == rv return false;
            }
        }
    }
    o.changed = true;
    call_set_called_function(rv, arc_ep_get(*o.ep, .Retain));
    return false;
}

// OptimizeInlinedAutoreleaseRVCall
arc_optimize_inlined_autorelease_rv_call :: (o: *Arc_Opt, i: Value_Id, arg: *Value_Id, k: Arc_Kind, arv: Value_Id, arv_arg: *Value_Id) -> bool {
    if arc_bundled_contains(o.bundled, i) return false;
    arg.* = arc_arg_rc_identity_root(i);
    arv_arg.* = arc_arg_rc_identity_root(arv);
    if arg.* != arv_arg.* {
        if !is_phi(arg.*) return false;
        users: [..] Value_Id; users.allocator = temp;
        arc_equivalent_phis(arg.*, *users);
        found := false;
        for users if it == arv_arg.* { found = true; break; }
        if !found return false;
    }
    rauw_with_metadata(arv, arc_arg0(arv));
    o.changed = true;
    arc_erase_instruction(arv);
    if k == .RetainRV {
        rauw_with_metadata(i, arc_arg0(i));
        arc_erase_instruction(i);
        return true;
    }
    assert(k == .UnsafeClaimRV);
    call_arg_v := arc_arg0(i);
    rel := arc_new_call_fn(arc_ep_get(*o.ep, .Release), .[call_arg_v]);
    insert_at_position(rel, inst_block(i), i, false);
    arc_set_tail_call(rel);
    rauw_with_metadata(i, call_arg_v);
    arc_erase_instruction(i);
    arc_optimize_individual_call_impl(o, rel, .Release, arg.*);
    return true;
}

// OptimizeAutoreleaseRVCall
arc_optimize_autorelease_rv_call :: (o: *Arc_Opt, arv: Value_Id, k: *Arc_Kind) {
    ptr := arc_arg_rc_identity_root(arv);
    if is_constant_data(ptr) return;
    users: [..] Value_Id; users.allocator = temp;
    array_add(*users, ptr);
    if is_phi(ptr) arc_equivalent_phis(ptr, *users);
    while users.count {
        p := pop(*users);
        u := ir.v_first_use[p];
        while u != NONE {
            usr := ir.u_user[u];
            if (is_inst(usr) && inst_op(usr) == .RET) || arc_basic_kind(usr) == .RetainRV return;
            if is_inst(usr) && inst_op(usr) == .BITCAST array_add(*users, usr);
            u = ir.u_next[u];
        }
    }
    o.changed = true;
    call_set_called_function(arv, arc_ep_get(*o.ep, .Autorelease));
    arc_set_tail_call(arv, false);
    k.* = .Autorelease;
}

// isInertARCValue
arc_is_inert_value :: (v_in: Value_Id, visited: *[..] Value_Id) -> bool {
    v := arc_strip(v_in);
    if arc_is_null_or_undef(v) return true;
    if vkind(v) == .GLOBAL_VAR && attr_set_has_str(glob(v).attrs, "objc_arc_inert") return true;
    if is_phi(v) {
        if !arc_set_insert(visited, v) return true;
        n := phi_num_incoming(v);
        if n > 0 for i: 0..n-1 if !arc_is_inert_value(phi_value(v, i), visited) return false;
        return true;
    }
    return false;
}

// addOpBundleForFunclet
arc_add_funclet_bundle :: (o: *Arc_Opt, bb: Value_Id, out: *[..] Arc_Bundle) {
    if !o.colors.any return;
    cv := table_find_pointer(*o.colors.colors, bb);
    assert(cv != null && cv.count > 0, "Uncolored block");
    for pad_bb: cv.* {
        pad := block_first_non_phi(pad_bb);
        if pad != NONE && (inst_op(pad) == .CATCHPAD || inst_op(pad) == .CLEANUPPAD) {
            ins := NewArray(1, Value_Id,, allocator = temp); ins[0] = pad;
            array_add(out, .{"funclet", ins});
            return;
        }
    }
}

// OptimizeIndividualCallImpl
arc_optimize_individual_call_impl :: (o: *Arc_Opt, inst_in: Value_Id, class_in: Arc_Kind, arg_in: Value_Id) {
    i := inst_in; k := class_in; arg := arg_in;
    visited_phis: [..] Value_Id; visited_phis.allocator = temp;
    if arc_bundled_contains(o.bundled, i) { o.used |= arc_bit(k); return; }
    if arc_is_noop_on_global(k) && arc_is_inert_value(op(i, 0), *visited_phis) {
        if vtype(i) != ir.t_void rauw_with_metadata(i, op(i, 0));
        erase_inst_with_metadata(i);
        o.changed = true;
        return;
    }
    if k == {
        case .NoopCast;
            o.changed = true;
            arc_erase_instruction(i);
            return;
        case .StoreWeak; #through; case .LoadWeak; #through; case .LoadWeakRetained; #through; case .InitWeak; #through;
        case .DestroyWeak;
            if arc_is_null_or_undef(arc_arg0(i)) {
                arc_null_weak_ub(o, i);
                return;
            }
        case .CopyWeak; #through; case .MoveWeak;
            if arc_is_null_or_undef(arc_arg0(i)) || arc_is_null_or_undef(call_arg(i, 1)) {
                arc_null_weak_ub(o, i);
                return;
            }
        case .RetainRV;
            if arc_optimize_retain_rv_call(o, i) return;
        case .AutoreleaseRV;
            arc_optimize_autorelease_rv_call(o, i, *k);
    }
    if arc_is_autorelease(k) && !has_uses(i) {
        a := arc_find_single_use_identified_object(arc_arg0(i));
        if a != NONE {
            o.changed = true;
            nc := arc_new_call_fn(arc_ep_get(*o.ep, .Release), .[arc_arg0(i)]);
            insert_at_position(nc, inst_block(i), i, false);
            set_metadata(nc, arc_md_imprecise_release(), md_tuple(.[], false));
            arc_erase_instruction(i);
            i = nc;
            k = .Release;
        }
    }
    if arc_is_always_tail(k) && call_tail_kind(i) != TCK_NOTAIL { o.changed = true; arc_set_tail_call(i); }
    if arc_is_never_tail(k) { o.changed = true; arc_set_tail_call(i, false); }
    if arc_is_no_throw(k) { o.changed = true; call_set_does_not_throw(i); }
    if !arc_is_noop_on_null(k) { o.used |= arc_bit(k); return; }
    if arg == NONE arg = arc_arg_rc_identity_root(i);
    if arc_is_null_or_undef(arg) {
        o.changed = true;
        arc_erase_instruction(i);
        return;
    }
    o.used |= arc_bit(k);
    if k == .Release && get_metadata(i, arc_md_imprecise_release()) == NONE return;

    Item :: struct { i: Value_Id; arg: Value_Id; }
    wl: [..] Item; wl.allocator = temp;
    array_add(*wl, .{i, arg});
    while wl.count {
        it := pop(*wl);
        i = it.i; arg = it.arg;
        if !is_phi(arg) continue;
        pn := arg;
        has_null, has_crit := false, false;
        n := phi_num_incoming(pn);
        for x: 0..n-1 {
            inc := arc_rc_identity_root(phi_value(pn, x));
            if arc_is_null_or_undef(inc) has_null = true;
            else if block_num_successors(phi_block(pn, x)) != 1 { has_crit = true; break; }
        }
        if has_crit || !has_null continue;
        dep: Value_Id = NONE;
        if k == {
            case .Retain; #through; case .RetainBlock;
            case .Release; dep = arc_find_single_dependency(.NeedsPositiveRetainCount, arg, inst_block(i), i, *o.pa);
            case .Autorelease; dep = arc_find_single_dependency(.AutoreleasePoolBoundary, arg, inst_block(i), i, *o.pa);
            case .UnsafeClaimRV; #through; case .RetainRV; #through; case .AutoreleaseRV; continue;
            case; assert(false, "Invalid dependence flavor");
        }
        if dep != pn continue;
        o.changed = true;
        ci := i;
        pty := vtype(arc_arg0(ci));
        for x: 0..n-1 {
            inc := arc_rc_identity_root(phi_value(pn, x));
            if arc_is_null_or_undef(inc) continue;
            v := phi_value(pn, x);
            ib := phi_block(pn, x);
            pos := block(ib).last;
            bundles: [..] Arc_Bundle; bundles.allocator = temp;
            all: [..] Arc_Bundle; all.allocator = temp;
            arc_call_bundles(ci, *all);
            for all if it.tag != "funclet" array_add(*bundles, it);
            arc_add_funclet_bundle(o, ib, *bundles);
            clone := arc_clone_call_with_bundles(ci, bundles);
            if vtype(v) != pty fatal("objc-arc: a bitcast of a phi operand is not supported");
            set_op(clone, 0, v);
            insert_at_position(clone, ib, pos, false);
            if vname(ci).count set_name(clone, vname(ci));
            array_add(*wl, .{clone, inc});
        }
        arc_erase_instruction(ci);
    }
}


// the "null pointer-to-weak-pointer is undefined behavior" rewrite
arc_null_weak_ub :: (o: *Arc_Opt, ci: Value_Id) {
    o.changed = true;
    st := create_store_raw(get_true(ir.t_i1), const_poison(type_ptr(0)), 1);
    insert_at_position(st, inst_block(ci), ci, false);
    rauw_with_metadata(ci, const_poison(vtype(ci)));
    erase_inst_with_metadata(ci);
}

// OptimizeIndividualCalls
arc_optimize_individual_calls :: (o: *Arc_Opt) {
    f := o.f;
    o.used = 0;
    delayed: Value_Id = NONE;
    delayed_arg: Value_Id = NONE;
    set_delayed :: (delayed: *Value_Id, delayed_arg: *Value_Id, arv: Value_Id) { delayed.* = arv; delayed_arg.* = NONE; }
    optimize_delayed :: (o: *Arc_Opt, delayed: *Value_Id, delayed_arg: *Value_Id) {
        if delayed.* == NONE return;
        arc_optimize_individual_call_impl(o, delayed.*, .AutoreleaseRV, delayed_arg.*);
        set_delayed(delayed, delayed_arg, NONE);
    }
    should_delay :: (delayed: Value_Id, i: Value_Id) -> bool {
        if delayed == NONE return true;
        if is_terminator(inst_op(i)) return false;
        if !is_call_base(i) return true;
        return call_iid_any(i) != NOT_INTRINSIC;
    }
    // inst_iterator: the next position is taken (eagerly, across blocks) before the body
    bb := glob(f).first_block;
    next: Value_Id = NONE;
    while bb != NONE && block(bb).first == NONE bb = block(bb).next;
    if bb != NONE next = block(bb).first;
    while next != NONE {
        i := next;
        next = arc_inst_iter_next(i);
        if inst_op(i) == .CALL && arc_has_attached_call_bundle(i) {
            none: Arc_Colors;
            arc_bundled_insert_rv_call(o.bundled, inst_block(next), next, false, i, *none);
            o.changed = true;
        }
        k := arc_basic_kind(i);
        arg: Value_Id = NONE;
        if k == {
            case .CallOrUser; #through; case .User; #through; case .None;
                if !should_delay(delayed, i) optimize_delayed(o, *delayed, *delayed_arg);
                continue;
            case .AutoreleaseRV;
                optimize_delayed(o, *delayed, *delayed_arg);
                set_delayed(*delayed, *delayed_arg, i);
                continue;
            case .RetainRV; #through; case .UnsafeClaimRV;
                if delayed != NONE {
                    if arc_optimize_inlined_autorelease_rv_call(o, i, *arg, k, delayed, *delayed_arg) {
                        set_delayed(*delayed, *delayed_arg, NONE);
                        continue;
                    }
                    optimize_delayed(o, *delayed, *delayed_arg);
                }
            case;
                optimize_delayed(o, *delayed, *delayed_arg);
        }
        arc_optimize_individual_call_impl(o, i, k, arg);
    }
    optimize_delayed(o, *delayed, *delayed_arg);
}

// CheckForUseCFGHazard / CheckForCanReleaseCFGHazard / CheckForCFGHazards
arc_check_for_cfg_hazards :: (o: *Arc_Opt, bb: Value_Id, my: *Arc_Bb_State) {
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    for key, idx: my.td.keys {
        s := *my.td.vals[idx];
        seq := s.seq;
        if seq == .None continue;
        assert(seq == .Retain || seq == .CanRelease || seq == .Use, "Unknown top down sequence state.");
        some_same, all_same, not_all_but_safe := false, true, false;
        for succ: succs {
            ss := arc_pm_get(*arc_state(o, succ).bu, key);
            s = *my.td.vals[idx];
            sseq := ss.seq;
            if sseq == .None { arc_ps_clear_progress(s); continue; }
            ssafe := ss.rri.known_safe;
            if s.seq == {
                case .Use;
                    should_continue := false;
                    if sseq == {
                        case .CanRelease;
                            if !s.rri.known_safe && !ssafe { arc_ps_clear_progress(s); }
                            else { s.rri.cfg_hazard = true; should_continue = true; }
                        case .Use; some_same = true;
                        case .Stop; #through; case .MovableRelease;
                            if !s.rri.known_safe && !ssafe all_same = false; else not_all_but_safe = true;
                        case; assert(false, "bottom-up pointer in retain state!");
                    }
                    if should_continue continue;
                case .CanRelease;
                    if sseq == {
                        case .CanRelease; some_same = true;
                        case .Stop; #through; case .MovableRelease; #through; case .Use;
                            if !s.rri.known_safe && !ssafe all_same = false; else not_all_but_safe = true;
                        case; assert(false, "bottom-up pointer in retain state!");
                    }
            }
        }
        s = *my.td.vals[idx];
        if some_same && !all_same arc_ps_clear_progress(s);
        else if not_all_but_safe s.rri.cfg_hazard = true;
    }
}

// VisitInstructionBottomUp
arc_visit_inst_bottom_up :: (o: *Arc_Opt, i: Value_Id, bb: Value_Id, retains: *Arc_Rr_Map, my: *Arc_Bb_State) -> bool {
    nesting := false;
    k := arc_inst_kind(i);
    arg: Value_Id = NONE;
    if k == {
        case .Release;
            arg = arc_arg_rc_identity_root(i);
            s := arc_pm_get(*my.bu, arg);
            nesting |= arc_bu_init(s, i);
        case .RetainBlock;
        case .Retain; #through; case .RetainRV;
            arg = arc_arg_rc_identity_root(i);
            s := arc_pm_get(*my.bu, arg);
            if arc_bu_match_with_retain(s) {
                if k != .RetainRV arc_rm_set(retains, i, s.rri);
                arc_ps_clear_progress(s);
            }
        case .AutoreleasepoolPop;
            arc_pm_clear(*my.bu);
            return nesting;
        case .AutoreleasepoolPush; #through; case .None;
            return nesting;
    }
    for key, idx: my.bu.keys {
        if key == arg continue;
        s := *my.bu.vals[idx];
        if arc_bu_handle_potential_alter_ref_count(s, i, key, *o.pa, k) continue;
        arc_bu_handle_potential_use(s, bb, i, key, *o.pa, k);
    }
    return nesting;
}

// VisitBottomUp
arc_visit_bottom_up :: (o: *Arc_Opt, bb: Value_Id, retains: *Arc_Rr_Map) -> bool {
    nesting := false;
    my := arc_state(o, bb);
    if my.succs.count {
        first := arc_state(o, my.succs[0]);
        arc_pm_copy(*my.bu, *first.bu);
        my.bu_count = first.bu_count;
        for x: 1..my.succs.count-1 arc_merge_succ(my, arc_state(o, my.succs[x]));
    }
    i := block(bb).last;
    while i != NONE {
        prev := inst(i).prev;
        if inst_op(i) != .INVOKE {
            nesting |= arc_visit_inst_bottom_up(o, i, bb, retains, my);
            if my.bu.keys.count > arc_cl.max_ptr_states { o.disable_pairing = true; return false; }
        }
        i = prev;
    }
    for p: my.preds {
        t := block(p).last;
        if t != NONE && inst_op(t) == .INVOKE nesting |= arc_visit_inst_bottom_up(o, t, bb, retains, my);
    }
    return nesting;
}

// ReleaseInsertPtToRCIdentityRoots: insertion point -> roots (SmallPtrSet<const Value *, 2>)
Arc_Rip_Roots :: struct { index: Table(Value_Id, s64); roots: [..] [..] Value_Id; }

// VisitInstructionTopDown
arc_visit_inst_top_down :: (o: *Arc_Opt, i: Value_Id, releases: *Arc_Rr_Map, my: *Arc_Bb_State, rr: *Arc_Rip_Roots) -> bool {
    nesting := false;
    k := arc_inst_kind(i);
    arg: Value_Id = NONE;
    rp := table_find_pointer(*rr.index, i);
    if rp {
        roots := rr.roots[rp.*];
        if roots.count > 2 {
            // SmallPtrSet<const Value *, 2> past its small size iterates in pointer order; that order is only
            // visible when it adds more than one new pointer to the top-down map
            fresh := 0;
            for roots if arc_pm_find(*my.td, it) < 0 fresh += 1;
            if fresh > 1 fatal("objc-arc: the top-down pointer order depends on the address order of more than two RC identity roots at one release insertion point");
        }
        for root: roots {
            s := arc_pm_get(*my.td, root);
            if s.seq == .Retain s.rri.cfg_hazard = true;
        }
    }
    if k == {
        case .RetainBlock;
        case .Retain; #through; case .RetainRV;
            arg = arc_arg_rc_identity_root(i);
            s := arc_pm_get(*my.td, arg);
            nesting |= arc_td_init(s, k, i);
        case .Release;
            arg = arc_arg_rc_identity_root(i);
            s := arc_pm_get(*my.td, arg);
            if arc_td_match_with_release(s, i) {
                arc_rm_set(releases, i, s.rri);
                arc_ps_clear_progress(s);
            }
        case .AutoreleasepoolPop;
            arc_pm_clear(*my.td);
            return false;
        case .AutoreleasepoolPush; #through; case .None;
            return false;
    }
    for key, idx: my.td.keys {
        if key == arg continue;
        s := *my.td.vals[idx];
        if arc_td_handle_potential_alter_ref_count(s, i, key, *o.pa, k, o.bundled) continue;
        arc_td_handle_potential_use(s, i, key, *o.pa, k);
    }
    return nesting;
}

// VisitTopDown
arc_visit_top_down :: (o: *Arc_Opt, bb: Value_Id, releases: *Arc_Rr_Map, rr: *Arc_Rip_Roots) -> bool {
    nesting := false;
    my := arc_state(o, bb);
    if my.preds.count {
        first := arc_state(o, my.preds[0]);
        arc_pm_copy(*my.td, *first.td);
        my.td_count = first.td_count;
        for x: 1..my.preds.count-1 arc_merge_pred(my, arc_state(o, my.preds[x]));
    }
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    if preds.count != my.preds.count for * my.td.vals it.rri.cfg_hazard = true;
    i := block(bb).first;
    while i != NONE {
        next := inst(i).next;
        nesting |= arc_visit_inst_top_down(o, i, releases, my, rr);
        if my.td.keys.count > arc_cl.max_ptr_states { o.disable_pairing = true; return false; }
        i = next;
    }
    arc_check_for_cfg_hazards(o, bb, my);
    return nesting;
}

// ComputePostOrders
arc_compute_post_orders :: (o: *Arc_Opt, post_order: *[..] Value_Id, rev_post_order: *[..] Value_Id) {
    f := o.f;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    on_stack: Table(Value_Id, bool); on_stack.allocator = temp;
    Frame :: struct { bb: Value_Id; succs: [..] Value_Id; next: s64; }
    stack: [..] Frame; stack.allocator = temp;
    push :: (stack: *[..] Frame, bb: Value_Id) {
        fr: Frame; fr.bb = bb; fr.succs.allocator = temp;
        block_successors(bb, *fr.succs);
        array_add(stack, fr);
    }
    entry := fn_entry(f);
    arc_state(o, entry).td_count = 1;
    push(*stack, entry);
    table_set(*visited, entry, true);
    table_set(*on_stack, entry, true);
    while stack.count {
        top := *stack[stack.count - 1];
        cur := top.bb;
        pushed := false;
        while top.next < top.succs.count {
            s := top.succs[top.next];
            top.next += 1;
            if !table_contains(*visited, s) {
                table_set(*visited, s, true);
                arc_set_add_edge(o, cur, s);
                table_set(*on_stack, s, true);
                push(*stack, s);
                pushed = true;
                break;
            }
            if !table_contains(*on_stack, s) arc_set_add_edge(o, cur, s);
        }
        if pushed continue;
        table_remove(*on_stack, cur);
        array_add(post_order, cur);
        pop(*stack);
    }

    table_reset(*visited);
    PFrame :: struct { bb: Value_Id; next: s64; }
    pstack: [..] PFrame; pstack.allocator = temp;
    for exit_bb: fn_blocks(f) {
        my := arc_state(o, exit_bb);
        if my.succs.count != 0 continue;
        my.bu_count = 1;
        array_add(*pstack, .{exit_bb, 0});
        table_set(*visited, exit_bb, true);
        while pstack.count {
            top := *pstack[pstack.count - 1];
            preds := *arc_state(o, top.bb).preds;
            pushed := false;
            while top.next < preds.count {
                b := preds.*[top.next];
                top.next += 1;
                if !table_contains(*visited, b) {
                    table_set(*visited, b, true);
                    array_add(*pstack, .{b, 0});
                    pushed = true;
                    break;
                }
            }
            if pushed continue;
            array_add(rev_post_order, pop(*pstack).bb);
        }
    }
}
arc_set_add_edge :: (o: *Arc_Opt, from: Value_Id, to: Value_Id) {
    a := arc_state(o, from);
    if a.succs.allocator.proc == null a.succs.allocator = temp;
    array_add(*a.succs, to);
    b := arc_state(o, to);
    if b.preds.allocator.proc == null b.preds.allocator = temp;
    array_add(*b.preds, from);
}

// Visit
arc_visit :: (o: *Arc_Opt, retains: *Arc_Rr_Map, releases: *Arc_Rr_Map) -> bool {
    post: [..] Value_Id; post.allocator = temp;
    rpost: [..] Value_Id; rpost.allocator = temp;
    arc_md_no_objc_arc_exceptions();
    arc_compute_post_orders(o, *post, *rpost);
    bu_nesting := false;
    for < rpost {
        bu_nesting |= arc_visit_bottom_up(o, it, retains);
        if o.disable_pairing return false;
    }
    // collectReleaseInsertPts
    rr: Arc_Rip_Roots; rr.index.allocator = temp; rr.roots.allocator = temp;
    for key, idx: retains.keys {
        if key == NONE continue;   // blotted entries keep their RRInfo in LLVM's vector, with a null key
        root := arc_rc_identity_root(op(key, 0));
        for ip: retains.vals[idx].rips {
            p := table_find_pointer(*rr.index, ip);
            if !p {
                table_set(*rr.index, ip, rr.roots.count);
                e: [..] Value_Id; e.allocator = temp;
                array_add(*rr.roots, e);
                p = table_find_pointer(*rr.index, ip);
            }
            arc_set_insert(*rr.roots[p.*], root);
        }
    }
    td_nesting := false;
    for < post {
        td_nesting |= arc_visit_top_down(o, it, releases, *rr);
        if o.disable_pairing return false;
    }
    return td_nesting && bu_nesting;
}

// MoveCalls
arc_move_calls :: (o: *Arc_Opt, arg: Value_Id, rtm: *Arc_Rr_Info, rlm: *Arc_Rr_Info, retains: *Arc_Rr_Map, releases: *Arc_Rr_Map, dead: *[..] Value_Id) {
    for ip: rlm.rips {
        decl := arc_ep_get(*o.ep, .Retain);
        bl: [..] Arc_Bundle; bl.allocator = temp;
        arc_add_funclet_bundle(o, inst_block(ip), *bl);
        c := arc_new_call_fn(decl, .[arg], bl);
        insert_at_position(c, inst_block(ip), ip, false);
        call_set_does_not_throw(c);
        arc_set_tail_call(c);
    }
    for ip: rtm.rips {
        decl := arc_ep_get(*o.ep, .Release);
        bl: [..] Arc_Bundle; bl.allocator = temp;
        arc_add_funclet_bundle(o, inst_block(ip), *bl);
        c := arc_new_call_fn(decl, .[arg], bl);
        insert_at_position(c, inst_block(ip), ip, false);
        if rlm.release_md != NONE set_metadata(c, arc_md_imprecise_release(), rlm.release_md);
        call_set_does_not_throw(c);
        if rlm.is_tail_call_release arc_set_tail_call(c);
    }
    for rtm.calls { arc_rm_blot(retains, it); array_add(dead, it); }
    for rlm.calls { arc_rm_blot(releases, it); array_add(dead, it); }
}

// PairUpRetainsAndReleases
arc_pair_up :: (o: *Arc_Opt, retains: *Arc_Rr_Map, releases: *Arc_Rr_Map, retain: Value_Id, rtm: *Arc_Rr_Info, rlm: *Arc_Rr_Info, known_safe: bool, any_eliminated: *bool) -> bool {
    ksafe_td, ksafe_bu := true, true;
    cfg_hazard := false;
    old_delta: u32 = 0; new_delta: u32 = 0; old_count: u32 = 0; new_count: u32 = 0;
    first_release := true;
    new_retains: [..] Value_Id; new_retains.allocator = temp;
    array_add(*new_retains, retain);
    new_releases: [..] Value_Id; new_releases.allocator = temp;
    while true {
        new_releases.count = 0;
        for nr: new_retains {
            nrri := arc_rm_find(retains, nr);
            assert(nrri != null);
            ksafe_td &= nrri.known_safe;
            cfg_hazard |= nrri.cfg_hazard;
            for nrr: nrri.calls {
                jt := arc_rm_find(releases, nrr);
                if !jt return false;
                if !arc_set_contains(jt.calls, nr) return false;
                if arc_set_insert(*rlm.calls, nrr) {
                    ovf, pc := arc_all_path_count(arc_state(o, inst_block(nrr)));
                    if ovf return false;
                    old_delta -= pc;
                    if first_release {
                        rlm.release_md = jt.release_md;
                        rlm.is_tail_call_release = jt.is_tail_call_release;
                        first_release = false;
                    } else {
                        if rlm.release_md != jt.release_md rlm.release_md = NONE;
                        if rlm.is_tail_call_release != jt.is_tail_call_release rlm.is_tail_call_release = false;
                    }
                    if !known_safe for rip: jt.rips {
                        if arc_set_insert(*rlm.rips, rip) {
                            ovf2, pc2 := arc_all_path_count(arc_state(o, inst_block(rip)));
                            if ovf2 return false;
                            new_delta -= pc2;
                        }
                    }
                    array_add(*new_releases, nrr);
                }
            }
        }
        new_retains.count = 0;
        if new_releases.count == 0 break;
        for nrl: new_releases {
            nrri := arc_rm_find(releases, nrl);
            assert(nrri != null);
            ksafe_bu &= nrri.known_safe;
            cfg_hazard |= nrri.cfg_hazard;
            for nrr: nrri.calls {
                jt := arc_rm_find(retains, nrr);
                if !jt return false;
                if !arc_set_contains(jt.calls, nrl) return false;
                if arc_set_insert(*rtm.calls, nrr) {
                    ovf, pc := arc_all_path_count(arc_state(o, inst_block(nrr)));
                    if ovf return false;
                    old_delta += pc;
                    old_count += pc;
                    if !known_safe for rip: jt.rips {
                        if arc_set_insert(*rtm.rips, rip) {
                            ovf2, pc2 := arc_all_path_count(arc_state(o, inst_block(rip)));
                            if ovf2 return false;
                            new_delta += pc2;
                            new_count += pc2;
                        }
                    }
                    array_add(*new_retains, nrr);
                }
            }
        }
        if new_retains.count == 0 break;
    }
    if ksafe_td && ksafe_bu {
        rtm.rips.count = 0;
        rlm.rips.count = 0;
        new_count = 0;
    } else {
        if new_delta != 0 return false;
        will_move := rtm.rips.count != 0 || rlm.rips.count != 0;
        if cfg_hazard && will_move return false;
    }
    if old_delta != 0 return false;
    o.changed = true;
    any_eliminated.* = new_count == 0;
    return true;
}

// PerformCodePlacement
arc_perform_code_placement :: (o: *Arc_Opt, retains: *Arc_Rr_Map, releases: *Arc_Rr_Map) -> bool {
    any_eliminated := false;
    dead: [..] Value_Id; dead.allocator = temp;
    x := 0;
    while x < retains.keys.count {
        v := retains.keys[x];
        x += 1;
        if v == NONE continue;
        arg := arc_arg_rc_identity_root(v);
        known_safe := is_const(arg) || (is_inst(arg) && inst_op(arg) == .ALLOCA);
        if is_inst(arg) && inst_op(arg) == .LOAD {
            g := arc_rc_identity_root(op(arg, 0));
            if vkind(g) == .GLOBAL_VAR && glob(g).is_const known_safe = true;
        }
        rtm, rlm: Arc_Rr_Info;
        if arc_pair_up(o, retains, releases, v, *rtm, *rlm, known_safe, *any_eliminated)
            arc_move_calls(o, arg, *rtm, *rlm, retains, releases, *dead);
    }
    while dead.count arc_erase_instruction(pop(*dead));
    return any_eliminated;
}

// OptimizeWeakCalls
arc_optimize_weak_calls :: (o: *Arc_Opt) {
    f := o.f;
    for :early_inc i: fn_insts(f) {
        k := arc_basic_kind(i);
        if k != .LoadWeak && k != .LoadWeakRetained continue;
        if k == .LoadWeak && !has_uses(i) {
            erase_inst_with_metadata(i);
            o.changed = true;
            continue;
        }
        j := inst(i).prev;
        while j != NONE {
            ek := arc_inst_kind(j);
            clobbered := false;
            if ek == {
                case .LoadWeak; #through; case .LoadWeakRetained; #through; case .StoreWeak; #through; case .InitWeak;
                    a := arc_arg0(i);
                    ea := arc_arg0(j);
                    r := aa_alias_once(o.pa.aar, mloc_before_or_after(a), mloc_before_or_after(ea)).kind;
                    if r == AR_MUST {
                        o.changed = true;
                        if k == .LoadWeakRetained {
                            c := arc_new_call_fn(arc_ep_get(*o.ep, .Retain), .[j]);
                            insert_at_position(c, inst_block(i), i, false);
                            arc_set_tail_call(c);
                        }
                        repl := ifx ek == .LoadWeak || ek == .LoadWeakRetained then j else call_arg(j, 1);
                        rauw_with_metadata(i, repl);
                        erase_inst_with_metadata(i);
                        clobbered = true;
                    } else if r == AR_MAY || r == AR_PARTIAL clobbered = true;
                case .MoveWeak; #through; case .CopyWeak; clobbered = true;
                case .AutoreleasepoolPush; #through; case .None; #through; case .IntrinsicUser; #through; case .User;
                case; clobbered = true;
            }
            if clobbered break;
            j = inst(j).prev;
        }
    }
    for :early_inc i: fn_insts(f) {
        if arc_basic_kind(i) != .DestroyWeak continue;
        a := arc_arg0(i);
        if !is_inst(a) || inst_op(a) != .ALLOCA continue;
        ok := true;
        u := ir.v_first_use[a];
        while u != NONE {
            k := arc_basic_kind(ir.u_user[u]);
            if k != .InitWeak && k != .StoreWeak && k != .DestroyWeak { ok = false; break; }
            u = ir.u_next[u];
        }
        if !ok continue;
        o.changed = true;
        u = ir.v_first_use[a];
        while u != NONE {
            nu := ir.u_next[u];
            usr := ir.u_user[u];
            k := arc_basic_kind(usr);
            if k == .InitWeak || k == .StoreWeak rauw_with_metadata(usr, call_arg(usr, 1));
            // the user may appear twice in the use list (both operands); skip uses of the erased user
            while nu != NONE && ir.u_user[nu] == usr nu = ir.u_next[nu];
            erase_inst_with_metadata(usr);
            u = nu;
        }
        erase_inst_with_metadata(a);
    }
}

// OptimizeSequences
arc_optimize_sequences :: (o: *Arc_Opt) -> bool {
    retains, releases: Arc_Rr_Map;
    arc_rm_init(*retains); arc_rm_init(*releases);
    o.states.allocator = temp; o.states.count = 0;
    o.state_index.allocator = temp; table_reset(*o.state_index);
    for b: fn_blocks(o.f) {
        table_set(*o.state_index, b, cast(s32) o.states.count);
        e: Arc_Bb_State;
        array_add(*o.states, e);
    }
    nesting := arc_visit(o, *retains, *releases);
    if o.disable_pairing return false;
    any := arc_perform_code_placement(o, *retains, *releases);
    return any && nesting;
}

// HasSafePathToPredecessorCall
arc_has_safe_path_to_predecessor_call :: (arg: Value_Id, retain: Value_Id, pa: *Arc_Pa) -> Value_Id {
    c := arc_find_single_dependency(.CanChangeRetainCount, arg, inst_block(retain), retain, pa);
    if c == NONE || !is_inst(c) || inst_op(c) != .CALL || arg != c return NONE;
    k := arc_basic_kind(c);
    return ifx k == .CallOrUser || k == .Call then c else NONE;
}
// FindPredecessorRetainWithSafePath
arc_find_predecessor_retain :: (arg: Value_Id, bb: Value_Id, ar: Value_Id, pa: *Arc_Pa) -> Value_Id {
    r := arc_find_single_dependency(.CanChangeRetainCount, arg, bb, ar, pa);
    if r == NONE || !is_inst(r) || inst_op(r) != .CALL || !arc_is_retain(arc_basic_kind(r)) || arc_arg_rc_identity_root(r) != arg return NONE;
    return r;
}
// FindPredecessorAutoreleaseWithSafePath
arc_find_predecessor_autorelease :: (arg: Value_Id, bb: Value_Id, ret: Value_Id, pa: *Arc_Pa) -> Value_Id {
    a := arc_find_single_dependency(.NeedsPositiveRetainCount, arg, bb, ret, pa);
    if a == NONE || !is_inst(a) || inst_op(a) != .CALL return NONE;
    if !arc_is_autorelease(arc_basic_kind(a)) return NONE;
    if arc_arg_rc_identity_root(a) != arg return NONE;
    return a;
}

// OptimizeReturns
arc_optimize_returns :: (o: *Arc_Opt) {
    f := o.f;
    if !is_ptr_type(func_ret(glob(f).value_type)) return;
    for bb: fn_blocks(f) {
        ret := block(bb).last;
        if ret == NONE || inst_op(ret) != .RET continue;
        arg := arc_rc_identity_root(op(ret, 0));
        ar := arc_find_predecessor_autorelease(arg, bb, ret, *o.pa);
        if ar == NONE continue;
        rt := arc_find_predecessor_retain(arg, inst_block(ar), ar, *o.pa);
        if rt == NONE continue;
        c := arc_has_safe_path_to_predecessor_call(arg, rt, *o.pa);
        if c == NONE || (!arc_is_tail_call(c) && arc_basic_kind(rt) == .RetainRV && arc_basic_kind(ar) == .AutoreleaseRV) continue;
        o.changed = true;
        arc_bundled_erase_inst(o.bundled, rt);
        arc_erase_instruction(ar);
    }
}

// MayAutorelease
arc_may_autorelease :: (cb: Value_Id, depth: s64 = 0) -> bool {
    if call_only_reads_memory(cb) return false;
    if depth > 5 return true;
    callee := call_called_function(cb);
    if callee == NONE return true;
    if !cgp_has_exact_definition(callee) return true;
    for bb: fn_blocks(callee) {
        stack: [..] bool; stack.allocator = temp;
        for i: block_insts(bb) {
            k := arc_basic_kind(i);
            if k == {
                case .AutoreleasepoolPush; array_add(*stack, false);
                case .AutoreleasepoolPop; if stack.count pop(*stack);
                case .Autorelease; #through; case .AutoreleaseRV; #through; case .FusedRetainAutorelease; #through;
                case .FusedRetainAutoreleaseRV; #through; case .LoadWeak;
                    if stack.count == 0 return true;
                    stack[stack.count - 1] = true;
                case .CallOrUser; #through; case .Call;
                    if arc_may_autorelease(i, depth + 1) {
                        if stack.count == 0 return true;
                        stack[stack.count - 1] = true;
                    }
            }
        }
        if stack.count for stack if it return true;
    }
    return false;
}

// OptimizeAutoreleasePools
arc_optimize_autorelease_pools :: (o: *Arc_Opt) {
    Pool :: struct { push: Value_Id; had: bool; }
    for bb: fn_blocks(o.f) {
        stack: [..] Pool; stack.allocator = temp;
        for :early_inc i: block_insts(bb) {
            k := arc_basic_kind(i);
            mark := false;
            if k == {
                case .AutoreleasepoolPush; array_add(*stack, .{i, false});
                case .AutoreleasepoolPop;
                    if stack.count == 0 continue;
                    push := stack[stack.count - 1].push;
                    had := stack[stack.count - 1].had;
                    if arc_strip(arc_arg0(i)) != push { stack.count = 0; continue; }
                    pop(*stack);
                    if had continue;
                    rauw_with_metadata(push, const_poison(vtype(push)));
                    erase_inst_with_metadata(push);
                    erase_inst_with_metadata(i);
                    o.changed = true;
                case .CallOrUser; #through; case .Call;
                    mark = arc_may_autorelease(i);
                case .Autorelease; #through; case .AutoreleaseRV; #through; case .FusedRetainAutorelease; #through;
                case .FusedRetainAutoreleaseRV; #through; case .LoadWeak;
                    mark = true;
            }
            if mark && stack.count stack[stack.count - 1].had = true;
        }
    }
}

// ObjCARCOpt::run
arc_opt_run :: (o: *Arc_Opt) -> bool {
    if !arc_cl.enable_arc_opts return false;
    o.changed = false; o.cfg_changed = false;
    brv: Arc_Bundled;
    arc_bundled_init(*brv, *o.ep, false, false);
    o.bundled = *brv;
    c, cfg := arc_bundled_insert_after_invokes(*brv, o.f, null);
    o.changed |= c; o.cfg_changed |= cfg;
    arc_optimize_individual_calls(o);
    WEAK :: Arc_Kind.[.LoadWeak, .LoadWeakRetained, .StoreWeak, .InitWeak, .CopyWeak, .MoveWeak, .DestroyWeak];
    wm: u32 = 0; for WEAK wm |= arc_bit(it);
    if o.used & wm arc_optimize_weak_calls(o);
    if o.used & (arc_bit(.Retain) | arc_bit(.RetainRV) | arc_bit(.RetainBlock))
        if o.used & arc_bit(.Release)
            while arc_optimize_sequences(o) {}
    if o.used & (arc_bit(.Autorelease) | arc_bit(.AutoreleaseRV)) arc_optimize_returns(o);
    if o.used & (arc_bit(.AutoreleasepoolPush) | arc_bit(.AutoreleasepoolPop)) arc_optimize_autorelease_pools(o);
    arc_bundled_finish(*brv);
    return o.changed;
}

// ObjCARCOptPass::run
objc_arc_run :: (f: Value_Id) -> Preserved {
    o: Arc_Opt;
    o.f = f;
    arc_ep_init(*o.ep);
    if arc_cl.enable_arc_opts arc_colors_init(*o.colors, f);
    aar := aa_results_for(f);
    arc_pa_init(*o.pa, *aar);
    changed := arc_opt_run(*o);
    vh_release_all();
    if changed {
        if !o.cfg_changed return preserved_cfg();
        return PRESERVE_NONE;
    }
    return PRESERVE_ALL;
}

// ---------------------------------------------------------------- ObjCARCContract

Arc_Contract :: struct {
    f: Value_Id;
    changed: bool;
    cfg_changed: bool;
    aar: *Aa_Results;
    dt: *Dom_Tree;
    pa: Arc_Pa;
    ep: Arc_Entry_Points;
    bundled: *Arc_Bundled;
    has_claim_rv: bool;
    rv_marker: Md_Id;
    store_strong_calls: [..] Value_Id;
}

// optimizeRetainCall
arc_c_optimize_retain_call :: (c: *Arc_Contract, retain: Value_Id) -> bool {
    call := arc_arg_rc_identity_root(retain);
    if !is_inst(call) || !is_call_base(call) return false;
    if inst_block(call) != inst_block(retain) return false;
    i := inst(call).next;
    while arc_is_noop_instruction(i) i = inst(i).next;
    if i != retain return false;
    c.changed = true;
    call_set_called_function(retain, arc_ep_get(*c.ep, .RetainRV));
    return true;
}

// contractAutorelease
arc_c_contract_autorelease :: (c: *Arc_Contract, ar: Value_Id, k: Arc_Kind) -> bool {
    arg := arc_arg_rc_identity_root(ar);
    dk: Arc_Dep = ifx k == .AutoreleaseRV then .RetainAutoreleaseRVDep else .RetainAutoreleaseDep;
    r := arc_find_single_dependency(dk, arg, inst_block(ar), ar, *c.pa);
    if r == NONE || !is_inst(r) || inst_op(r) != .CALL || arc_basic_kind(r) != .Retain || arc_arg_rc_identity_root(r) != arg return false;
    c.changed = true;
    decl := arc_ep_get(*c.ep, ifx k == .AutoreleaseRV then Arc_Entry.RetainAutoreleaseRV else .RetainAutorelease);
    call_set_called_function(r, decl);
    arc_erase_instruction(ar);
    return true;
}

// findSafeStoreForStoreStrongContraction
arc_c_find_safe_store :: (load: Value_Id, release: Value_Id, c: *Arc_Contract) -> Value_Id {
    store: Value_Id = NONE;
    saw_release := false;
    loc := mloc_get(load);
    loc_ptr := arc_strip(loc.ptr);
    i := inst(load).next;
    while i != NONE {
        defer i = inst(i).next;
        if store != NONE && saw_release break;
        if i == release { saw_release = true; continue; }
        k := arc_basic_kind(i);
        if store != NONE {
            if !arc_can_use(i, load, *c.pa, k) continue;
            return NONE;
        }
        if arc_is_retain(k) continue;
        if !(aa_mod_ref_inst_loc(aa_query_new(c.aar), i, loc) & MR_MOD) continue;
        if inst_op(i) != .STORE return NONE;
        store = i;
        if !is_simple_load_store(store) return NONE;
        if arc_strip(op(store, 1)) == loc_ptr continue;
        return NONE;
    }
    if store == NONE || !saw_release return NONE;
    return store;
}
store_is_simple :: (s: Value_Id) -> bool { return inst(s).ord1 == 0 && !(inst(s).flags & F_VOLATILE); }

// findRetainForStoreStrongContraction
arc_c_find_retain_for_store_strong :: (new: Value_Id, store: Value_Id, release: Value_Id, c: *Arc_Contract) -> Value_Id {
    i := store;
    begin := block(inst_block(store)).first;
    while i != begin && arc_basic_kind(i) != .Retain {
        if arc_can_decrement_ref_count(i, new, *c.pa, arc_inst_kind(i)) && i != release return NONE;
        i = inst(i).prev;
    }
    if arc_basic_kind(i) != .Retain return NONE;
    if arc_arg_rc_identity_root(i) != new return NONE;
    return i;
}

// tryToContractReleaseIntoStoreStrong
arc_c_try_store_strong :: (c: *Arc_Contract, release: Value_Id, iter: *Value_Id, colors: *Arc_Colors) {
    load := arc_arg_rc_identity_root(release);
    if !is_inst(load) || inst_op(load) != .LOAD || !is_simple_load_store(load) return;
    bb := inst_block(release);
    if inst_block(load) != bb return;
    store := arc_c_find_safe_store(load, release, c);
    if store == NONE return;
    new := arc_rc_identity_root(op(store, 0));
    retain := arc_c_find_retain_for_store_strong(new, store, release, c);
    if retain == NONE return;
    c.changed = true;
    decl := arc_ep_get(*c.ep, .StoreStrong);
    ss := arc_create_call_with_colors(glob(decl).value_type, decl, .[op(load, 0), new], inst_block(store), store, false, colors);
    call_set_does_not_throw(ss);
    d := get_metadata(store, 0);
    set_metadata(ss, 0, d);
    arc_set_insert(*c.store_strong_calls, ss);
    if iter.* == retain iter.* = arc_inst_iter_next(iter.*);
    if iter.* == store iter.* = arc_inst_iter_next(iter.*);
    erase_inst_with_metadata(store);
    erase_inst_with_metadata(release);
    arc_erase_instruction(retain);
    if !has_uses(load) erase_inst_with_metadata(load);
}

// inst_iterator ++ (eagerly across blocks)
arc_inst_iter_next :: (i: Value_Id) -> Value_Id {
    n := inst(i).next;
    if n != NONE return n;
    b := block(inst_block(i)).next;
    while b != NONE && block(b).first == NONE b = block(b).next;
    if b == NONE return NONE;
    return block(b).first;
}
// inst_iterator -- (only used right after an insertion before the iterator's instruction)
arc_inst_iter_prev :: (i: Value_Id) -> Value_Id {
    p := inst(i).prev;
    assert(p != NONE, "objc-arc-contract: --I at a block start");
    return p;
}

// tryToPeepholeInstruction
arc_c_try_peephole :: (c: *Arc_Contract, i: Value_Id, iter: *Value_Id, tail_ok: *bool, colors: *Arc_Colors) -> bool {
    k := arc_basic_kind(i);
    if k == {
        case .FusedRetainAutorelease; #through; case .FusedRetainAutoreleaseRV; return false;
        case .Autorelease; #through; case .AutoreleaseRV; return arc_c_contract_autorelease(c, i, k);
        case .Retain; #through; case .RetainRV; #through; case .UnsafeClaimRV;
            if k == .Retain && !arc_c_optimize_retain_call(c, i) return false;
            if arc_bundled_contains(c.bundled, i) return true;
            if c.rv_marker == NONE return false;
            bbi := i;
            parent := inst_block(i);
            decline := false;
            while true {
                if bbi == block(parent).first {
                    pred := block_single_predecessor(parent);
                    if pred == NONE { decline = true; break; }
                    bbi = block_terminator(pred);
                    break;
                }
                bbi = inst(bbi).prev;
                if !arc_is_noop_instruction(bbi) break;
            }
            if !decline && arc_rc_identity_root(bbi) == arc_arg_rc_identity_root(i) {
                c.changed = true;
                fty := type_func(ir.t_void, .[], false);
                ia := inline_asm_get(fty, ir.mds[c.rv_marker].str, "", 1);
                arc_create_call_with_colors(fty, ia, .[], inst_block(i), i, false, colors);
            }
            return false;
        case .InitWeak;
            if arc_is_null_or_undef(call_arg(i, 1)) {
                nullv := const_null(vtype(i));
                c.changed = true;
                st := create_store_raw(nullv, arc_arg0(i), dl_abi_align(vtype(nullv)));
                insert_at_position(st, inst_block(i), i, false);
                rauw_with_metadata(i, nullv);
                erase_inst_with_metadata(i);
            }
            return true;
        case .Release;
            arc_c_try_store_strong(c, i, iter, colors);
            return true;
        case .User;
            if inst_op(i) == .ALLOCA tail_ok.* = false;
            return true;
        case .IntrinsicUser;
            c.changed = true;
            erase_inst_with_metadata(i);
            return true;
    }
    if inst_op(i) == .CALL && call_iid_any(i) == IID_OBJC_CLANG_ARC_NOOP_USE {
        c.changed = true;
        erase_inst_with_metadata(i);
    }
    return true;
}

// useClaimRuntimeCall
arc_use_claim_runtime_call :: () -> bool {
    if arc_cl.use_claim_rv >= 0 return arc_cl.use_claim_rv == 1;
    t := triple_parse(ir.triple);
    if t.arch != .aarch64 && t.arch != .aarch64_be && t.arch != .aarch64_32 return false;
    major := triple_os_version(*t).major;
    if t.os == {
        case .IOS; #through; case .TvOS; return major >= 16;
        case .WatchOS; return major >= 9;
        case .BridgeOS; return major >= 7;
        case .MacOSX; return major >= 13;
        case .Darwin; return major >= 21;
    }
    return false;
}

// ReplaceArgUses (a lambda of ObjCARCContract::run)
arc_c_replace_arg_uses :: (c: *Arc_Contract, i: Value_Id, arg: Value_Id) {
    if !is_inst(arg) && vkind(arg) != .ARGUMENT return;
    u := ir.v_first_use[arg];
    while u != NONE {
        uu := u;
        u = ir.u_next[u];
        usr := ir.u_user[uu];
        opno := use_operand_no(uu);
        if !can_replace_operand_with_variable(usr, opno) continue;
        use_bb := ifx is_phi(usr) then ir.u_aux[uu] else inst_block(usr);
        if !dt_is_reachable_from_entry(c.dt, use_bb) || !dt_dominates_use(c.dt, i, uu) continue;
        c.changed = true;
        repl := i;
        use_ty := vtype(arg);
        if is_phi(usr) {
            ib := ir.u_aux[uu];
            if vtype(repl) != use_ty fatal("objc-arc-contract: a bitcast of the retained value is not supported");
            n := phi_num_incoming(usr);
            for x: 0..n-1 if phi_block(usr, x) == ib {
                if u != NONE && op_use(usr, x) == u u = ir.u_next[u];
                phi_set_value(usr, x, repl);
            }
        } else {
            if vtype(repl) != use_ty fatal("objc-arc-contract: a bitcast of the retained value is not supported");
            set_op(usr, opno, repl);
        }
    }
}

// ObjCARCContract::run
arc_contract_run :: (c: *Arc_Contract) -> bool {
    f := c.f;
    c.changed = false; c.cfg_changed = false;
    brv: Arc_Bundled;
    arc_bundled_init(*brv, *c.ep, true, c.has_claim_rv);
    c.bundled = *brv;
    ch, cfg := arc_bundled_insert_after_invokes(*brv, f, c.dt);
    c.changed |= ch; c.cfg_changed |= cfg;
    colors: Arc_Colors;
    arc_colors_init(*colors, f);
    tail_ok := !func_vararg(glob(f).value_type) && !fn_calls_returns_twice(f);
    c.store_strong_calls.allocator = temp;
    bb := glob(f).first_block;
    while bb != NONE && block(bb).first == NONE bb = block(bb).next;
    iter: Value_Id = NONE;
    if bb != NONE iter = block(bb).first;
    while iter != NONE {
        i := iter;
        iter = arc_inst_iter_next(i);
        if inst_op(i) == .CALL && arc_has_attached_call_bundle(i) {
            arc_bundled_insert_rv_call(*brv, inst_block(iter), iter, false, i, *colors);
            iter = arc_inst_iter_prev(iter);
            c.changed = true;
        }
        if arc_c_try_peephole(c, i, *iter, *tail_ok, *colors) continue;
        arg := arc_arg0(i);
        while true {
            arc_c_replace_arg_uses(c, i, arg);
            if is_inst(arg) && inst_op(arg) == .BITCAST arg = op(arg, 0);
            else if (opr_code(arg) == .GEP) && gep_has_all_zero_indices_v(arg) arg = op(arg, 0);
            else if vkind(arg) == .ALIAS && !gv_is_interposable(arg) arg = op(arg, 0);
            else {
                if is_phi(arg) {
                    phis: [..] Value_Id; phis.allocator = temp;
                    arc_equivalent_phis(arg, *phis);
                    for phis arc_c_replace_arg_uses(c, i, it);
                }
                break;
            }
        }
    }
    if tail_ok for c.store_strong_calls arc_set_tail_call(it);
    c.store_strong_calls.count = 0;
    arc_bundled_finish(*brv);
    return c.changed;
}

fn_calls_returns_twice :: (f: Value_Id) -> bool {
    for i: fn_insts(f) if is_call_base(i) && call_has_fn_attr(i, .ReturnsTwice) return true;
    return false;
}

// ObjCARCContractPass::run
objc_arc_contract_run :: (f: Value_Id) -> Preserved {
    if !arc_module_has_arc() return PRESERVE_ALL;
    if !arc_cl.enable_arc_opts return PRESERVE_ALL;
    c: Arc_Contract;
    c.f = f;
    arc_ep_init(*c.ep);
    c.has_claim_rv = arc_use_claim_runtime_call();
    c.rv_marker = arc_rv_inst_marker();
    aar := aa_results_for(f);
    c.aar = *aar;
    c.dt = get_domtree(f);
    arc_pa_init(*c.pa, *aar);
    changed := arc_contract_run(*c);
    vh_release_all();
    if changed {
        if !c.cfg_changed return preserved_cfg();
        return PRESERVE_NONE;
    }
    return PRESERVE_ALL;
}

// ---------------------------------------------------------------- ObjCARCExpand

objc_arc_expand_run :: (f: Value_Id) -> Preserved {
    if !arc_cl.enable_arc_opts return PRESERVE_ALL;
    if !arc_module_has_arc() return PRESERVE_ALL;
    changed := false;
    for i: fn_insts(f) {
        k := arc_basic_kind(i);
        if k == .Retain || k == .RetainRV || k == .Autorelease || k == .AutoreleaseRV || k == .FusedRetainAutorelease || k == .FusedRetainAutoreleaseRV {
            changed = true;
            rauw_with_metadata(i, arc_arg0(i));
        }
    }
    if !changed return PRESERVE_ALL;
    return preserved_cfg();
}

// ---------------------------------------------------------------- pa-eval (ProvenanceAnalysisEvaluator.cpp)

pa_eval_run :: (f: Value_Id) -> Preserved {
    values: [..] Value_Id; values.allocator = temp;
    seen: Table(Value_Id, bool); seen.allocator = temp;
    insert_if_named :: (values: *[..] Value_Id, seen: *Table(Value_Id, bool), v: Value_Id) {
        if v == NONE || vname(v).count == 0 return;
        if !is_ptr_type(vtype(v)) return;
        if table_contains(seen, v) return;
        table_set(seen, v, true);
        array_add(values, v);
    }
    n := func_nparams(glob(f).value_type);
    if n > 0 for k: 0..n-1 insert_if_named(*values, *seen, fn_arg(f, cast(u32) k));
    for i: fn_insts(f) {
        insert_if_named(*values, *seen, i);
        m := nops(i);
        if m > 0 for k: 0..m-1 insert_if_named(*values, *seen, op(i, k));
    }
    get_name :: (v: Value_Id) -> string {
        s := vname(v);
        if begins_with(s, "\x01") return slice(s, 1, s.count - 1);
        return s;
    }
    aar := aa_results_for(f);
    pa: Arc_Pa;
    arc_pa_init(*pa, *aar);
    sb: String_Builder; sb.allocator = temp;
    for v1: values {
        n1 := get_name(v1);
        for v2: values {
            n2 := get_name(v2);
            if compare(n1, n2) >= 0 continue;
            print_to_builder(*sb, "% and %", n1, n2);
            if arc_pa_related(*pa, v1, v2) append(*sb, " are related.\n");
            else append(*sb, " are not related.\n");
        }
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    vh_release_all();
    return PRESERVE_ALL;
}
