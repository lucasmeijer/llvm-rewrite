// CaptureTracking: a port of llvm/lib/Analysis/CaptureTracking.cpp (PointerMayBeCaptured with the
// SimpleCaptureTracker, CapturesBefore and EarliestCaptures trackers, DetermineUseCaptureKind) and of the
// reachability queries it needs from llvm/lib/Analysis/CFG.cpp (isPotentiallyReachable, ...FromMany; no LoopInfo or
// CycleInfo yet: callers that have one must add it).
//
// CaptureComponents are u8 bit masks with LLVM's values (CC_* constants in inst_simplify.jai): AddressIsNull = 1,
// Address = 3, ReadProvenance = 4, Provenance = 12, All = 15. A tracker is a plain struct with a kind tag; the
// virtual `captured` callback of LLVM is a switch on that tag.

CAPTURE_TRACKING_MAX_USES :: 100;   // -capture-tracking-max-uses-to-explore
CFG_MAX_BBS_TO_EXPLORE :: 32;       // DefaultMaxBBsToExplore (CFG.cpp)

cc_captures_full_provenance :: inline (cc: u8) -> bool { return (cc & CC_PROVENANCE) == CC_PROVENANCE; }
cc_captures_read_provenance_only :: inline (cc: u8) -> bool { return (cc & CC_PROVENANCE) == CC_READ_PROVENANCE; }
cc_captures_any_provenance :: inline (cc: u8) -> bool { return (cc & CC_PROVENANCE) != 0; }

// The StopFn passed to PointerMayBeCaptured
Ct_Stop :: enum u8 { ANYTHING; FULL_PROVENANCE; NEVER; }
ct_should_stop :: (s: Ct_Stop, cc: u8) -> bool {
    if s == .ANYTHING return cc != CC_NONE;
    if s == .FULL_PROVENANCE return cc_captures_full_provenance(cc);
    return false;
}

Ct_Kind :: enum u8 { SIMPLE; BEFORE; EARLIEST; ALLOCA_CMP; }
Ct_Action :: enum u8 { STOP; CONTINUE; CONTINUE_IGNORING_RETURN; }

Capture_Tracker :: struct {
    kind: Ct_Kind;
    mask: u8 = CC_ALL;
    stop: Ct_Stop = .ANYTHING;
    cc: u8;
    cc_with_ret: u8;
    // CapturesBefore
    before_here: Value_Id = NONE;
    dt: *Dom_Tree;
    return_captures: bool;
    include_i: bool;
    // EarliestCaptures
    f: Value_Id = NONE;
    earliest: Value_Id = NONE;
    // InstCombinerImpl::foldAllocaCmp's CmpCaptureTracker: equality icmps of the alloca (a SmallMapVector)
    alloca: Value_Id = NONE;
    captured: bool;
    icmps: [..] Value_Id;
    icmp_masks: [..] u32;
}

ct_too_many_uses :: (t: *Capture_Tracker) {
    if t.kind == {
        case .SIMPLE; t.cc = t.mask; t.cc_with_ret = t.mask;
        case .BEFORE; t.cc = t.mask;
        case .EARLIEST;
            t.cc = t.mask; t.cc_with_ret = t.mask;
            t.earliest = block(fn_entry(t.f)).first;
        case .ALLOCA_CMP; t.captured = true;
    }
}

ct_captured :: (t: *Capture_Tracker, u: Use_Id, use_cc: u8) -> Ct_Action {
    user := ir.u_user[u];
    if t.kind == {
        case .SIMPLE;
            if (use_cc & t.mask) == CC_NONE return .CONTINUE;
            t.cc_with_ret |= use_cc & t.mask;
            if !(is_inst(user) && inst_op(user) == .RET) t.cc |= use_cc & t.mask;
            return ifx ct_should_stop(t.stop, t.cc) then Ct_Action.STOP else .CONTINUE;
        case .BEFORE;
            if inst_op(user) == .RET && !t.return_captures return .CONTINUE_IGNORING_RETURN;
            // isSafeToPrune
            prune: bool;
            if t.before_here == user prune = !t.include_i;
            else if !dt_is_reachable_from_entry(t.dt, inst_block(user)) prune = true;
            else prune = !is_potentially_reachable_inst(user, t.before_here, t.dt);
            if prune return .CONTINUE_IGNORING_RETURN;
            if (use_cc & t.mask) == CC_NONE return .CONTINUE;
            t.cc |= use_cc & t.mask;
            return ifx ct_should_stop(t.stop, t.cc) then Ct_Action.STOP else .CONTINUE;
        case .EARLIEST;
            if (use_cc & t.mask) != CC_NONE {
                t.cc_with_ret |= use_cc & t.mask;
                if inst_op(user) != .RET {
                    if t.earliest == NONE t.earliest = user;
                    else t.earliest = dt_find_nearest_common_dominator_inst(t.dt, t.earliest, user);
                    t.cc |= use_cc & t.mask;
                }
            }
            return .CONTINUE;
        case .ALLOCA_CMP;
            if is_inst(user) && inst_op(user) == .ICMP && icmp_is_equality(inst_pred(user)) && get_underlying_object(ir.u_val[u]) == t.alloca {
                opno := u - ir.v_ops[user];
                for t.icmps if it == user { t.icmp_masks[it_index] |= (cast(u32) 1) << opno; return .CONTINUE; }
                array_add(*t.icmps, user);
                array_add(*t.icmp_masks, (cast(u32) 1) << opno);
                return .CONTINUE;
            }
            t.captured = true;
            return .STOP;
    }
    return .CONTINUE;
}

// DominatorTree::findNearestCommonDominator(Instruction *, Instruction *)
dt_find_nearest_common_dominator_inst :: (dt: *Dom_Tree, i1: Value_Id, i2: Value_Id) -> Value_Id {
    b1 := inst_block(i1); b2 := inst_block(i2);
    if b1 == b2 return ifx comes_before(i1, i2) then i1 else i2;
    if !dt_is_reachable_from_entry(dt, b2) return i1;
    if !dt_is_reachable_from_entry(dt, b1) return i2;
    dom := dt_find_nca(dt, b1, b2);
    if dom == b1 return i1;
    if dom == b2 return i2;
    return block_terminator(dom);
}

// CallBase::getCaptureInfo(OpNo) as (other, ret) components
call_capture_info :: (c: Value_Id, opno: u32) -> (other: u8, ret: u8) {
    if opno < call_num_args(c) {
        if call_is_byval_arg(c, opno) return CC_NONE, CC_NONE;
        oth, ret := capture_info_of_attrs(attr_list_param(inst(c).attrs, opno));
        f := call_called_operand_fn(c);
        if f != NONE {
            o2, r2 := capture_info_of_attrs(attr_list_param(glob(f).attrs, opno));
            oth &= o2; ret &= r2;
        }
        return oth, ret;
    }
    if call_iid_any(c) == IID_ASSUME return CC_NONE, CC_NONE;
    if call_bundle_tag_of_operand(c, opno) == "deopt" return CC_NONE, CC_NONE;
    return CC_ALL, CC_ALL;
}
// CallBase::getIntrinsicID: the ID of any Function callee (no function-type check, unlike call_iid)
call_iid_any :: (c: Value_Id) -> Intrinsic_Id {
    f := call_called_operand_fn(c);
    if f == NONE return NOT_INTRINSIC;
    return fn_iid(f);
}
// CallBase::hasArgumentWithAdditionalReturnCaptureComponents
call_has_arg_with_additional_return_captures :: (c: Value_Id) -> bool {
    n := call_num_args(c);
    if n > 0 for k: 0..n-1 {
        if !is_ptr_type(vtype(op(c, k))) continue;
        oth, ret := capture_info_of_attrs(attr_list_param(inst(c).attrs, k));
        f := call_called_operand_fn(c);
        if f != NONE {
            o2, r2 := capture_info_of_attrs(attr_list_param(glob(f).attrs, k));
            oth &= o2; ret &= r2;
        }
        if (ret & ~oth) != 0 return true;
    }
    return false;
}
// isIntrinsicReturningPointerAliasingArgumentWithoutCapturing
intrinsic_returns_aliasing_arg_without_capturing :: (c: Value_Id, must_preserve_offset: bool) -> bool {
    id := call_iid_any(c);
    if id == IID_LAUNDER_INVARIANT_GROUP || id == IID_STRIP_INVARIANT_GROUP return true;
    if id == IID_PTRMASK return !must_preserve_offset;
    if id == IID_THREADLOCAL_ADDRESS return !fn_has_fn_attr(inst_fn(c), .PresplitCoroutine);
    return false;
}
// number of trailing non-data operands of a call (callee, and the destinations of invoke/callbr)
call_non_data_operands :: (c: Value_Id) -> u32 {
    o := inst_op(c);
    if o == .INVOKE return 3;
    if o == .CALLBR return 2 + inst(c).addrspace;
    return 1;
}
// MDNode::toCaptureComponents
md_to_capture_components :: (m: Md_Id) -> u8 {
    if m == NONE return CC_ALL;
    cc: u8 = CC_NONE;
    n := ir.mds[m].nops;
    if n > 0 for k: 0..n-1 {
        s := ir.mds[md_op(m, k)].str;
        if s == "address" cc |= CC_ADDRESS;
        else if s == "address_is_null" cc |= CC_ADDRESS_IS_NULL;
        else if s == "provenance" cc |= CC_PROVENANCE;
        else if s == "read_provenance" cc |= CC_READ_PROVENANCE;
    }
    return cc;
}

// DetermineUseCaptureKind: (UseCC, ResultCC)
ct_use_capture_kind :: (u: Use_Id, base: Value_Id) -> (use_cc: u8, result_cc: u8) {
    i := ir.u_user[u];
    if !is_inst(i) return CC_ALL, CC_NONE;
    opno := u - ir.v_ops[i];
    o := inst_op(i);
    if o == {
        case .CALL; #through;
        case .INVOKE;
            if intrinsic_returns_aliasing_arg_without_capturing(i, false) return CC_NONE, CC_ALL;
            if opno == nops(i) - 1 return CC_NONE, CC_NONE;   // isCallee
            volatile_cc: u8 = CC_NONE;
            if is_mem_intrinsic_call(i) && is_volatile(i) volatile_cc |= CC_ADDRESS;
            oth, ret := call_capture_info(i, opno);
            mask: u8 = CC_ALL;
            if call_only_reads_memory(i) && type_kind(vtype(i)) == .VOID mask = CC_ADDRESS;
            return (oth & mask) | volatile_cc, ret;
        case .LOAD;
            if (inst(i).flags & F_VOLATILE) != 0 return CC_ADDRESS, CC_NONE;
            return CC_NONE, CC_NONE;
        case .VAARG; return CC_NONE, CC_NONE;
        case .STORE;
            if opno == 0 return md_to_capture_components(inst_md(i, "captures")), CC_NONE;
            if (inst(i).flags & F_VOLATILE) != 0 return CC_ADDRESS, CC_NONE;
            return CC_NONE, CC_NONE;
        case .ATOMICRMW;
            if opno == 1 return CC_ALL, CC_NONE;
            if (inst(i).flags & F_VOLATILE) != 0 return CC_ADDRESS, CC_NONE;
            return CC_NONE, CC_NONE;
        case .CMPXCHG;
            if opno == 1 || opno == 2 return CC_ALL, CC_NONE;
            if (inst(i).flags & F_VOLATILE) != 0 return CC_ADDRESS, CC_NONE;
            return CC_NONE, CC_NONE;
        case .GEP;
            if is_vector_type(vtype(i)) return CC_ALL, CC_NONE;
            return CC_NONE, CC_ALL;
        case .BITCAST; #through; case .PHI; #through; case .SELECT; #through; case .ADDRSPACECAST;
            return CC_NONE, CC_ALL;
        case .PTRTOADDR; return CC_ADDRESS, CC_NONE;
        case .ICMP;
            other := op(i, 1 - opno);
            if vkind(other) == .C_NULL && icmp_is_equality(inst_pred(i)) && ir.u_val[u] == base return CC_ADDRESS_IS_NULL, CC_NONE;
            return CC_ADDRESS, CC_NONE;
    }
    return CC_ALL, CC_NONE;
}

// PointerMayBeCaptured(V, Tracker, MaxUsesToExplore)
ct_run :: (v: Value_Id, t: *Capture_Tracker, max_uses: s64 = CAPTURE_TRACKING_MAX_USES) {
    worklist: [..] Use_Id; worklist.allocator = temp;
    visited: Table(Use_Id, bool); visited.allocator = temp;
    add_uses :: (x: Value_Id, worklist: *[..] Use_Id, visited: *Table(Use_Id, bool), t: *Capture_Tracker, max_uses: s64) -> bool {
        u := ir.v_first_use[x];
        while u != NONE {
            if visited.count >= max_uses { ct_too_many_uses(t); return false; }
            if !table_find_pointer(visited, u) {
                table_set(visited, u, true);
                array_add(worklist, u);
            }
            u = ir.u_next[u];
        }
        return true;
    }
    if !add_uses(v, *worklist, *visited, t, max_uses) return;
    while worklist.count {
        u := pop(*worklist);
        use_cc, res_cc := ct_use_capture_kind(u, v);
        if use_cc != CC_NONE {
            a := ct_captured(t, u, use_cc);
            if a == .STOP return;
            if a == .CONTINUE_IGNORING_RETURN continue;
            if (res_cc & ~use_cc) == CC_NONE continue;
        }
        if res_cc != CC_NONE && !add_uses(ir.u_user[u], *worklist, *visited, t, max_uses) return;
    }
}

// PointerMayBeCaptured(V, Mask, StopFn): (WithoutRet, WithRet)
pointer_may_be_captured :: (v: Value_Id, mask: u8, stop: Ct_Stop) -> (without_ret: u8, with_ret: u8) {
    t: Capture_Tracker; t.kind = .SIMPLE; t.mask = mask; t.stop = stop;
    ct_run(v, *t);
    return t.cc, t.cc_with_ret;
}
// PointerMayBeCaptured(V, ReturnCaptures)
pointer_may_be_captured_bool :: (v: Value_Id, return_captures: bool) -> bool {
    a, b := pointer_may_be_captured(v, CC_ALL, .ANYTHING);
    return (ifx return_captures then b else a) != CC_NONE;
}
// PointerMayBeCapturedBefore(V, ReturnCaptures, I, DT, IncludeI, Mask, StopFn)
pointer_may_be_captured_before :: (v: Value_Id, return_captures: bool, i: Value_Id, dt: *Dom_Tree, include_i: bool,
                                   mask: u8 = CC_ALL, stop := Ct_Stop.ANYTHING) -> u8 {
    if !dt {
        a, b := pointer_may_be_captured(v, mask, stop);
        return ifx return_captures then b else a;
    }
    t: Capture_Tracker; t.kind = .BEFORE; t.mask = mask; t.stop = stop;
    t.before_here = i; t.dt = dt; t.return_captures = return_captures; t.include_i = include_i;
    ct_run(v, *t);
    return t.cc;
}
// FindEarliestCapture: (instruction or NONE, WithoutRet, WithRet)
find_earliest_capture :: (v: Value_Id, f: Value_Id, dt: *Dom_Tree, mask: u8) -> (Value_Id, u8, u8) {
    t: Capture_Tracker; t.kind = .EARLIEST; t.mask = mask; t.stop = .NEVER; t.dt = dt; t.f = f;
    ct_run(v, *t);
    return t.earliest, t.cc, t.cc_with_ret;
}

// ---------------------------------------------------------------- CFG.cpp reachability (no LoopInfo / CycleInfo)

// isPotentiallyReachableFromMany(Worklist, StopBB, ExclusionSet = null, DT, LI = null)
is_potentially_reachable_from_many :: (worklist_in: [] Value_Id, stop_bb: Value_Id, dt_in: *Dom_Tree) -> bool {
    dt := dt_in;
    if dt && !dt_is_reachable_from_entry(dt, stop_bb) dt = null;
    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add_array(*worklist, worklist_in);
    visited: Table(Value_Id, bool); visited.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    limit := CFG_MAX_BBS_TO_EXPLORE;
    while worklist.count {
        bb := pop(*worklist);
        if table_find_pointer(*visited, bb) continue;
        table_set(*visited, bb, true);
        if bb == stop_bb return true;
        if dt && dt_dominates(dt, bb, stop_bb) return true;
        limit -= 1;
        if limit == 0 return true;
        block_successors(bb, *succs);
        array_add_array(*worklist, succs);
    }
    return false;
}
array_add_array :: (a: *[..] Value_Id, b: [] Value_Id) { for b array_add(a, it); }

// isPotentiallyReachable(BasicBlock *A, BasicBlock *B, null, DT, null)
is_potentially_reachable_block :: (a: Value_Id, b: Value_Id, dt: *Dom_Tree) -> bool {
    if dt {
        if dt_is_reachable_from_entry(dt, a) && !dt_is_reachable_from_entry(dt, b) return false;
        f := block_fn(a);
        if a == fn_entry(f) && dt_is_reachable_from_entry(dt, b) return true;
        if b == fn_entry(f) && dt_is_reachable_from_entry(dt, a) return false;
    }
    return is_potentially_reachable_from_many(.[a], b, dt);
}

// isPotentiallyReachable(Instruction *A, Instruction *B, null, DT, null)
is_potentially_reachable_inst :: (a: Value_Id, b: Value_Id, dt: *Dom_Tree) -> bool {
    ba := inst_block(a);
    if ba == inst_block(b) {
        if a == b || comes_before(a, b) return true;
        if ba == fn_entry(block_fn(ba)) return false;
        succs: [..] Value_Id; succs.allocator = temp;
        block_successors(ba, *succs);
        if succs.count == 0 return false;
        return is_potentially_reachable_from_many(succs, ba, dt);
    }
    return is_potentially_reachable_block(ba, inst_block(b), dt);
}

// ---------------------------------------------------------------- CFG.cpp reachability with CycleInfo (LI = null)

// isPotentiallyReachableFromMany(Worklist, StopBB, ExclusionSet = null, DT, LI = null, CI)
is_potentially_reachable_from_many_ci :: (worklist_in: [] Value_Id, stop_bb: Value_Id, dt_in: *Dom_Tree, ci: *Cycle_Info) -> bool {
    if !ci return is_potentially_reachable_from_many(worklist_in, stop_bb, dt_in);
    dt := dt_in;
    if dt && !dt_is_reachable_from_entry(dt, stop_bb) dt = null;
    stop_cycle := ci_top_level_parent(ci, stop_bb);
    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add_array(*worklist, worklist_in);
    visited: Table(Value_Id, bool); visited.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    limit := CFG_MAX_BBS_TO_EXPLORE;
    while worklist.count {
        bb := pop(*worklist);
        if table_find_pointer(*visited, bb) continue;
        table_set(*visited, bb, true);
        if bb == stop_bb return true;
        if dt && dt_dominates(dt, bb, stop_bb) return true;
        outer := ci_top_level_parent(ci, bb);
        if outer != NONE {
            if outer == stop_cycle return true;
        } else {
            if dt && dt_is_reachable_from_entry(dt, bb) && dt_dominates(dt, stop_bb, bb) continue;
        }
        limit -= 1;
        if limit == 0 return true;
        if outer != NONE ci_exit_blocks(ci, outer, *worklist);
        else { block_successors(bb, *succs); array_add_array(*worklist, succs); }
    }
    return false;
}
// isPotentiallyReachable(BasicBlock *A, BasicBlock *B, null, DT, null, CI)
is_potentially_reachable_block_ci :: (a: Value_Id, b: Value_Id, dt: *Dom_Tree, ci: *Cycle_Info) -> bool {
    if dt {
        if dt_is_reachable_from_entry(dt, a) && !dt_is_reachable_from_entry(dt, b) return false;
        f := block_fn(a);
        if a == fn_entry(f) && dt_is_reachable_from_entry(dt, b) return true;
        if b == fn_entry(f) && dt_is_reachable_from_entry(dt, a) return false;
    }
    return is_potentially_reachable_from_many_ci(.[a], b, dt, ci);
}
// isPotentiallyReachable(Instruction *A, Instruction *B, null, DT, null, CI)
is_potentially_reachable_inst_ci :: (a: Value_Id, b: Value_Id, dt: *Dom_Tree, ci: *Cycle_Info) -> bool {
    if !ci return is_potentially_reachable_inst(a, b, dt);
    ba := inst_block(a);
    if ba == inst_block(b) {
        if a == b || comes_before(a, b) return true;
        return ci_cycle_for(ci, ba) != NONE;
    }
    return is_potentially_reachable_block_ci(ba, inst_block(b), dt, ci);
}
