// The SandboxVectorizer's dependency graph and scheduler: port of
// llvm/lib/Transforms/Vectorize/SandboxVectorizer/DependencyGraph.cpp, Scheduler.cpp, Interval.cpp and their
// headers (DependencyGraph.h, Scheduler.h, Interval.h).
//
// Design (DESIGN.md "SandboxVectorizer"): DGNode / MemDGNode are rows of `Sdag_Node` (`is_mem` is the subclass
// tag; PredIterator / SuccIterator's "virtual" preds()/succs() are one procedure that looks at it), SchedBundles are
// rows of `Ssch_Bundle`, and the ready list is libstdc++'s std::priority_queue (push_heap / pop_heap) over node rows.
// Only one DependencyGraph + Scheduler is alive at a time (a LegalityAnalysis of bottom-up-vec, or load-store-vec's
// local Scheduler), so they are the globals `sdag` and `ssch`; their callbacks are rows in sbx.callbacks.
// Only SchedDirection::BottomUp is ported: it is the only direction any pass constructs.
//
// Address order: MemDGNode::MemPreds / MemSuccs are DenseSets. Their order is observable only through the order in
// which nodes enter the ready list, and with a heap ordered by a strict total order (PriorityCmp) that order does
// not change what is popped -- unless an instruction moves while it is in the heap. SchedBundle::cluster checks
// that this never happens (fails loudly otherwise).

// std::optional<unsigned>: setScheduled() disengages it, but incr/decr still write the storage (LLVM derefs it)
Sdag_Counter :: struct { v: u32; on: bool = true; }

Sdag_Node :: struct {
    inst: Value_Id;
    is_mem: bool;                 // MemDGNode
    live: bool;
    succs: Sdag_Counter;          // UnscheduledSuccs
    preds: Sdag_Counter;          // UnscheduledPreds
    scheduled: bool;
    sb: s32 = -1;                 // SchedBundle
    prev_mem: s32 = -1;           // MemDGNode chain
    next_mem: s32 = -1;
    mem_preds: [..] s32;          // DenseSet<MemDGNode *> (membership only, see the header)
    mem_succs: [..] s32;
}

Sdag_Interval :: struct { top: Value_Id = NONE; bot: Value_Id = NONE; }    // Interval<Instruction>
Sdag_Mem_Interval :: struct { top: s32 = -1; bot: s32 = -1; }              // Interval<MemDGNode>

sdag: struct {
    nodes: [..] Sdag_Node;
    node_of: Table(Value_Id, s32);   // InstrToNodeMap
    iv: Sdag_Interval;               // DAGInterval
    aa: *Aa_Query;                   // BatchAA
    cb_create: s64; cb_erase: s64; cb_move: s64; cb_set_use: s64;
}

Ssch_Bundle :: struct { nodes: [..] s32; live: bool; }

ssch: struct {
    ready: [..] s32;                 // ReadyListContainer: the std::priority_queue's vector
    bundles: [..] Ssch_Bundle;       // Bndls
    top_set: bool;                   // ScheduleTopItOpt (top_pt = NONE: the end of top_bb)
    top_bb: Value_Id = NONE;
    top_pt: Value_Id = NONE;
    scheduled_bb: Value_Id = NONE;
    cb_create: s64;
    alive: bool;
}

// instruction order within one block (Instruction::comesBefore; LLVM asserts the same block)
sdag_cb :: (a: Value_Id, b: Value_Id) -> bool {
    if inst_block(a) != inst_block(b) fatal("internal: sandbox-vectorizer: comesBefore across blocks");
    return comes_before(a, b);
}

// ---------------------------------------------------------------- Interval<Instruction>

iv_empty :: inline (iv: Sdag_Interval) -> bool { return iv.top == NONE; }
iv_make :: (instrs: [] Value_Id) -> Sdag_Interval {
    r: Sdag_Interval;
    r.top = instrs[0]; r.bot = instrs[0];
    for k: 1..instrs.count - 1 {
        i := instrs[k];
        if sdag_cb(i, r.top) r.top = i;
        else if sdag_cb(r.bot, i) r.bot = i;
    }
    return r;
}
iv_contains :: (iv: Sdag_Interval, i: Value_Id) -> bool {
    if iv_empty(iv) return false;
    if inst_block(i) != inst_block(iv.top) return false;
    return (iv.top == i || sdag_cb(iv.top, i)) && (i == iv.bot || sdag_cb(i, iv.bot));
}
iv_touches :: (iv: Sdag_Interval, i: Value_Id) -> bool {
    return iv.top == inst_next(i) || iv.bot == inst_prev(i);
}
iv_disjoint :: (a: Sdag_Interval, b: Sdag_Interval) -> bool {
    if iv_empty(b) || iv_empty(a) return true;
    return sdag_cb(b.bot, a.top) || sdag_cb(a.bot, b.top);
}
iv_comes_before :: (a: Sdag_Interval, b: Sdag_Interval) -> bool { return sdag_cb(a.bot, b.top); }
iv_union :: (a: Sdag_Interval, b: Sdag_Interval) -> Sdag_Interval {
    if iv_empty(a) return b;
    if iv_empty(b) return a;
    r: Sdag_Interval;
    r.top = ifx sdag_cb(a.top, b.top) then a.top else b.top;
    r.bot = ifx sdag_cb(a.bot, b.bot) then b.bot else a.bot;
    return r;
}
iv_intersection :: (a: Sdag_Interval, b: Sdag_Interval) -> Sdag_Interval {
    if iv_empty(a) return a;
    if iv_empty(b) return .{};
    if sdag_cb(a.bot, b.top) || sdag_cb(b.bot, a.top) return .{};
    r: Sdag_Interval;
    r.top = ifx sdag_cb(a.top, b.top) then b.top else a.top;
    r.bot = ifx sdag_cb(a.bot, b.bot) then a.bot else b.bot;
    return r;
}
// Interval::getSingleDiff (operator- that must give one interval)
iv_single_diff :: (a: Sdag_Interval, b: Sdag_Interval) -> Sdag_Interval {
    if iv_disjoint(a, b) return a;
    if iv_empty(b) return a;
    if a.top == b.top && a.bot == b.bot return .{};
    x := iv_intersection(a, b);
    parts: [2] Sdag_Interval; n := 0;
    if a.top != x.top { parts[n] = .{a.top, inst_prev(x.top)}; n += 1; }
    if x.bot != a.bot { parts[n] = .{inst_next(x.bot), a.bot}; n += 1; }
    if n != 1 fatal("internal: sandbox-vectorizer: extending the dependency graph in both directions");
    return parts[0];
}
// Interval::notifyMoveInstr(I, BeforeIt)
iv_notify_move :: (iv: *Sdag_Interval, i: Value_Id, pt: Value_Id) {
    if inst_next(i) == pt return;
    new_top := ifx iv.top == pt then i else ifx i == iv.top then inst_next(iv.top) else iv.top;
    new_bot := ifx inst_next(iv.bot) == pt then i else ifx i == iv.bot then inst_prev(iv.bot) else iv.bot;
    iv.top = new_top;
    iv.bot = new_bot;
}

// ---------------------------------------------------------------- DGNode

sdag_node :: inline (n: s32) -> *Sdag_Node { return *sdag.nodes[n]; }
sdag_get_node :: (i: Value_Id) -> s32 {
    if i == NONE return -1;
    found, n := table_find(*sdag.node_of, i);
    if !found return -1;
    return n;
}

cnt_incr :: inline (c: *Sdag_Counter) { c.v += 1; }
cnt_decr :: inline (c: *Sdag_Counter) { c.v -= 1; }
node_ready_bottom_up :: inline (n: s32) -> bool { c := sdag_node(n).succs; return c.on && c.v == 0; }
node_set_scheduled :: (n: s32) {
    x := sdag_node(n);
    x.scheduled = true;
    x.succs.on = false;
    x.preds.on = false;
}
node_reset_schedule_state :: (n: s32) {
    x := sdag_node(n);
    x.succs = .{0, true};
    x.preds = .{0, true};
    x.scheduled = false;
}

// DGNode::isStackSaveOrRestoreIntrinsic / isMemIntrinsic / isMemDepCandidate / isFenceLike / isMemDepNodeCandidate
sdag_intrinsic_id :: (i: Value_Id) -> Intrinsic_Id {
    if inst_op(i) != .CALL return NOT_INTRINSIC;   // sandboxir::IntrinsicInst is a CallInst
    return call_iid(i);
}
sdag_is_stack_save_or_restore :: (i: Value_Id) -> bool {
    id := sdag_intrinsic_id(i);
    return id == IID_STACKRESTORE || id == IID_STACKSAVE;
}
sdag_is_mem_intrinsic :: (id: Intrinsic_Id) -> bool { return id != IID_SIDEEFFECT && id != IID_PSEUDOPROBE; }
sdag_is_mem_dep_candidate :: (i: Value_Id) -> bool {
    id := sdag_intrinsic_id(i);
    return may_read_or_write_memory(i) && (id == NOT_INTRINSIC || sdag_is_mem_intrinsic(id));
}
sdag_is_fence_like :: (i: Value_Id) -> bool {
    id := sdag_intrinsic_id(i);
    return is_fence_like(i) && (id == NOT_INTRINSIC || sdag_is_mem_intrinsic(id));
}
sdag_is_mem_dep_node_candidate :: (i: Value_Id) -> bool {
    return sdag_is_mem_dep_candidate(i) || (inst_op(i) == .ALLOCA && alloca_is_used_with_inalloca(i)) ||
           sdag_is_stack_save_or_restore(i) || sdag_is_fence_like(i);
}

sdag_get_or_create_node :: (i: Value_Id) -> s32 {
    n := sdag_get_node(i);
    if n >= 0 return n;
    x: Sdag_Node;
    x.inst = i; x.live = true;
    x.is_mem = sdag_is_mem_dep_node_candidate(i);
    x.mem_preds.allocator = temp; x.mem_succs.allocator = temp;
    array_add(*sdag.nodes, x);
    n = cast(s32) sdag.nodes.count - 1;
    table_set(*sdag.node_of, i, n);
    return n;
}

// DGNode::preds(DAG): the operands that are instructions with a node, then (MemDGNode) the memory predecessors
sdag_preds :: (n: s32, out: *[..] s32) {
    out.count = 0;
    i := sdag_node(n).inst;
    for k: 0..cast(s64) nops(i) - 1 {
        o := op(i, cast(u32) k);
        if !is_inst(o) continue;
        on := sdag_get_node(o);
        if on >= 0 array_add(out, on);
    }
    if sdag_node(n).is_mem for sdag_node(n).mem_preds array_add(out, it);
}
// DGNode::succs(DAG): the users that are instructions with a node, then (MemDGNode) the memory successors
sdag_succs :: (n: s32, out: *[..] s32) {
    out.count = 0;
    i := sdag_node(n).inst;
    u := ir.v_first_use[i];
    while u != NONE {
        user := ir.u_user[u];
        if is_inst(user) {
            un := sdag_get_node(user);
            if un >= 0 array_add(out, un);
        }
        u = ir.u_next[u];
    }
    if sdag_node(n).is_mem for sdag_node(n).mem_succs array_add(out, it);
}

// MemDGNode::addMemPred / removeMemPred
sdag_set_contains :: (s: [] s32, x: s32) -> bool { for s if it == x return true; return false; }
sdag_set_remove :: (s: *[..] s32, x: s32) { for s.* if it == x { array_ordered_remove_by_index(s, it_index); return; } }
sdag_add_mem_pred :: (n: s32, pred: s32) {
    x := sdag_node(n);
    if !sdag_set_contains(x.mem_preds, pred) array_add(*x.mem_preds, pred);
    p := sdag_node(pred);
    if !sdag_set_contains(p.mem_succs, n) array_add(*p.mem_succs, n);
    if !x.scheduled && !p.scheduled {
        cnt_incr(*p.succs);
        cnt_incr(*x.preds);
    }
}
sdag_remove_mem_pred :: (n: s32, pred: s32) {
    x := sdag_node(n);
    p := sdag_node(pred);
    sdag_set_remove(*x.mem_preds, pred);
    sdag_set_remove(*p.mem_succs, n);
    if !x.scheduled && !p.scheduled {
        cnt_decr(*p.succs);
        cnt_decr(*x.preds);
    }
}
// setNextNode / setPrevNode / detachFromChain
sdag_set_next_mem :: (n: s32, nx: s32) {
    sdag_node(n).next_mem = nx;
    if nx >= 0 sdag_node(nx).prev_mem = n;
}
sdag_set_prev_mem :: (n: s32, pv: s32) {
    sdag_node(n).prev_mem = pv;
    if pv >= 0 sdag_node(pv).next_mem = n;
}
sdag_detach_from_chain :: (n: s32) {
    x := sdag_node(n);
    if x.prev_mem >= 0 sdag_node(x.prev_mem).next_mem = x.next_mem;
    if x.next_mem >= 0 sdag_node(x.next_mem).prev_mem = x.prev_mem;
    x.prev_mem = -1; x.next_mem = -1;
}

// MemDGNodeIntervalBuilder::getTopMemDGNode / getBotMemDGNode / make
sdag_top_mem_node :: (iv: Sdag_Interval) -> s32 {
    i := iv.top;
    while !sdag_is_mem_dep_node_candidate(i) && i != iv.bot i = inst_next(i);
    if !sdag_is_mem_dep_node_candidate(i) return -1;
    return sdag_get_node(i);
}
sdag_bot_mem_node :: (iv: Sdag_Interval) -> s32 {
    i := iv.bot;
    while !sdag_is_mem_dep_node_candidate(i) && i != iv.top i = inst_prev(i);
    if !sdag_is_mem_dep_node_candidate(i) return -1;
    return sdag_get_node(i);
}
sdag_make_mem_interval :: (iv: Sdag_Interval) -> Sdag_Mem_Interval {
    if iv_empty(iv) return .{};
    t := sdag_top_mem_node(iv);
    if t < 0 return .{};
    return .{t, sdag_bot_mem_node(iv)};
}

// ---------------------------------------------------------------- dependencies

Sdag_Dep :: enum u8 { READ_AFTER_WRITE; WRITE_AFTER_WRITE; WRITE_AFTER_READ; CONTROL; OTHER; NONE; }

// DependencyGraph::getRoughDepType
sdag_rough_dep_type :: (from: Value_Id, to: Value_Id) -> Sdag_Dep {
    if may_write_to_memory(from) {
        if may_read_from_memory(to) return .READ_AFTER_WRITE;
        if may_write_to_memory(to) return .WRITE_AFTER_WRITE;
    } else if may_read_from_memory(from) {
        if may_write_to_memory(to) return .WRITE_AFTER_READ;
    }
    if inst_op(from) == .PHI || inst_op(to) == .PHI return .CONTROL;
    if is_terminator(inst_op(to)) return .CONTROL;
    if sdag_is_stack_save_or_restore(from) || sdag_is_stack_save_or_restore(to) return .OTHER;
    return .NONE;
}
// isOrdered
sdag_is_ordered :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .LOAD || o == .STORE return !is_unordered(i);
    return sdag_is_fence_like(i);
}
// DependencyGraph::alias
sdag_alias :: (src: Value_Id, dst: Value_Id, dep: Sdag_Dep) -> bool {
    has_loc, loc := mloc_get_or_none(dst);
    if !has_loc return true;
    mr: u8 = MR_REF | MR_MOD;
    if !sdag_is_ordered(src) mr = aa_mod_ref_inst_loc(sdag.aa, src, loc);
    if dep == .READ_AFTER_WRITE || dep == .WRITE_AFTER_WRITE return (mr & MR_MOD) != 0;
    return (mr & MR_REF) != 0;
}
// DependencyGraph::hasDep
sdag_has_dep :: (src: Value_Id, dst: Value_Id) -> bool {
    d := sdag_rough_dep_type(src, dst);
    if d == {
        case .READ_AFTER_WRITE; #through;
        case .WRITE_AFTER_WRITE; #through;
        case .WRITE_AFTER_READ; return sdag_alias(src, dst, d);
        case .CONTROL; return false;
        case .OTHER; return true;
        case .NONE; return false;
    }
    return false;
}
// DependencyGraph::scanAndAddDeps: walk SrcScanRange bottom to top
sdag_scan_and_add_deps :: (dst: s32, src_range: Sdag_Mem_Interval) {
    if src_range.top < 0 return;
    dst_i := sdag_node(dst).inst;
    s := src_range.bot;
    while true {
        if sdag_has_dep(sdag_node(s).inst, dst_i) sdag_add_mem_pred(dst, s);
        if s == src_range.top break;
        s = sdag_node(s).prev_mem;
        if s < 0 fatal("internal: sandbox-vectorizer: broken MemDGNode chain");
    }
}

// DependencyGraph::setDefUseUnscheduledSuccs
sdag_set_def_use_unscheduled_succs :: (new_iv: Sdag_Interval) {
    i := new_iv.top;
    end := inst_next(new_iv.bot);
    while i != end {
        cnt: u32 = 0;
        for k: 0..cast(s64) nops(i) - 1 {
            o := op(i, cast(u32) k);
            if !is_inst(o) continue;
            if inst_block(o) != inst_block(i) continue;
            if !iv_contains(new_iv, o) continue;
            on := sdag_get_node(o);
            if on < 0 continue;
            cnt_incr(*sdag_node(on).succs);
            if !sdag_node(on).scheduled cnt += 1;
        }
        sdag_node(sdag_get_node(i)).preds = .{cnt, true};
        i = inst_next(i);
    }
    new_is_above := iv_empty(sdag.iv) || iv_comes_before(new_iv, sdag.iv);
    top_iv := ifx new_is_above then new_iv else sdag.iv;
    bot_iv := ifx new_is_above then sdag.iv else new_iv;
    if iv_empty(bot_iv) return;
    b := bot_iv.top;
    bend := inst_next(bot_iv.bot);
    while b != bend {
        bn := sdag_get_node(b);
        if !sdag_node(bn).scheduled {
            cnt: u32 = 0;
            for k: 0..cast(s64) nops(b) - 1 {
                o := op(b, cast(u32) k);
                if !is_inst(o) continue;
                on := sdag_get_node(o);
                if on < 0 continue;
                if !iv_contains(top_iv, o) continue;
                if !sdag_node(on).scheduled {
                    cnt_incr(*sdag_node(on).succs);
                    cnt += 1;
                }
            }
            sdag_node(bn).preds.v += cnt;
        }
        b = inst_next(b);
    }
}

// DependencyGraph::createNewNodes
sdag_create_new_nodes :: (new_iv: Sdag_Interval) {
    last_n := sdag_get_or_create_node(new_iv.top);
    last_mem := ifx sdag_node(last_n).is_mem then last_n else -1;
    i := inst_next(new_iv.top);
    end := inst_next(new_iv.bot);
    if new_iv.top == new_iv.bot i = end;
    while i != end {
        n := sdag_get_or_create_node(i);
        if sdag_node(n).is_mem {
            sdag_set_prev_mem(n, last_mem);
            last_mem = n;
        }
        i = inst_next(i);
    }
    if !iv_empty(sdag.iv) {
        new_is_above := iv_comes_before(new_iv, sdag.iv);
        top_iv := ifx new_is_above then new_iv else sdag.iv;
        bot_iv := ifx new_is_above then sdag.iv else new_iv;
        link_top := sdag_bot_mem_node(top_iv);
        link_bot := sdag_top_mem_node(bot_iv);
        if link_top >= 0 && link_bot >= 0 sdag_set_next_mem(link_top, link_bot);
    }
    sdag_set_def_use_unscheduled_succs(new_iv);
}

sdag_full_scan :: (iv: Sdag_Interval) {
    dst_range := sdag_make_mem_interval(iv);
    if dst_range.top < 0 return;
    if dst_range.top == dst_range.bot return;
    end := sdag_node(dst_range.bot).next_mem;
    d := sdag_node(dst_range.top).next_mem;
    while d != end {
        sdag_scan_and_add_deps(d, .{dst_range.top, sdag_node(d).prev_mem});
        d = sdag_node(d).next_mem;
    }
}

// DependencyGraph::extend
sdag_extend :: (instrs: [] Value_Id) -> Sdag_Interval {
    if instrs.count == 0 return .{};
    instrs_iv := iv_make(instrs);
    uni := iv_union(sdag.iv, instrs_iv);
    new_iv := iv_single_diff(uni, sdag.iv);
    if iv_empty(new_iv) return .{};
    sdag_create_new_nodes(new_iv);
    mem_dag := sdag_make_mem_interval(sdag.iv);
    if mem_dag.top < 0 {
        sdag_full_scan(new_iv);
    } else if sdag_cb(sdag.iv.bot, new_iv.top) {
        dst_range := sdag_make_mem_interval(new_iv);
        if dst_range.top >= 0 {
            // SrcRangeFull = MemDAGInterval.getUnionInterval(DstRange)
            full_top := ifx sdag_cb(sdag_node(mem_dag.top).inst, sdag_node(dst_range.top).inst) then mem_dag.top else dst_range.top;
            end := sdag_node(dst_range.bot).next_mem;
            d := dst_range.top;
            while d != end {
                sdag_scan_and_add_deps(d, .{full_top, sdag_node(d).prev_mem});
                d = sdag_node(d).next_mem;
            }
        }
    } else if sdag_cb(new_iv.bot, sdag.iv.top) {
        sdag_full_scan(new_iv);
        src_range := sdag_make_mem_interval(new_iv);
        end := sdag_node(mem_dag.bot).next_mem;
        d := mem_dag.top;
        while d != end {
            sdag_scan_and_add_deps(d, src_range);
            d = sdag_node(d).next_mem;
        }
    } else {
        fatal("internal: sandbox-vectorizer: extending the dependency graph in both directions");
    }
    sdag.iv = uni;
    return new_iv;
}

// getMemDGNodeBefore / getMemDGNodeAfter
sdag_mem_node_before :: (n: s32, including: bool, skip: s32) -> s32 {
    i := sdag_node(n).inst;
    p := ifx including then i else inst_prev(i);
    while p != NONE {
        pn := sdag_get_node(p);
        if pn < 0 return -1;
        if sdag_node(pn).is_mem && pn != skip return pn;
        p = inst_prev(p);
    }
    return -1;
}
sdag_mem_node_after :: (n: s32, including: bool, skip: s32) -> s32 {
    i := sdag_node(n).inst;
    p := ifx including then i else inst_next(i);
    while p != NONE {
        pn := sdag_get_node(p);
        if pn < 0 return -1;
        if sdag_node(pn).is_mem && pn != skip return pn;
        p = inst_next(p);
    }
    return -1;
}

// ---------------------------------------------------------------- DAG callbacks
// (Only the move callback can change what the passes do: create / erase / set-use happen while a pass emits its
// vectors, after its last scheduling query. They are ported all the same.)

sdag_notify_create_instr :: (i: Value_Id) {
    if sbx.state == .REVERTING return;
    if !(iv_contains(sdag.iv, i) || (!iv_empty(sdag.iv) && iv_touches(sdag.iv, i))) return;
    sdag.iv = iv_union(sdag.iv, .{i, i});
    n := sdag_get_or_create_node(i);
    if !sdag_node(n).is_mem return;
    pm := sdag_mem_node_before(n, false, -1);
    if pm >= 0 { sdag_node(pm).next_mem = n; sdag_node(n).prev_mem = pm; }
    nm := sdag_mem_node_after(n, false, -1);
    if nm >= 0 { sdag_node(nm).prev_mem = n; sdag_node(n).next_mem = nm; }
    if sdag_cb(sdag.iv.top, i) {
        above := sdag_make_mem_interval(.{sdag.iv.top, inst_prev(i)});
        sdag_scan_and_add_deps(n, above);
    }
    if sdag_cb(i, sdag.iv.bot) {
        below := sdag_make_mem_interval(.{inst_next(i), sdag.iv.bot});
        if below.top >= 0 {
            end := sdag_node(below.bot).next_mem;
            b := below.top;
            while b != end {
                sdag_scan_and_add_deps(b, .{n, n});
                b = sdag_node(b).next_mem;
            }
        }
    }
}

// DependencyGraph::notifyMoveInstr (runs before `i` moves to (bb, pt))
sdag_notify_move_instr :: (i: Value_Id, bb: Value_Id, pt: Value_Id) {
    if sbx.state == .REVERTING return;
    if inst_block(i) != bb fatal("internal: sandbox-vectorizer: the dependency graph does not support moves across blocks");
    orig := sdag.iv;
    iv_notify_move(*sdag.iv, i, pt);
    n := sdag_get_node(i);
    if n < 0 || !sdag_node(n).is_mem return;
    sdag_detach_from_chain(n);
    if pt == NONE || pt == inst_next(orig.bot) {
        prev := ifx pt == NONE then block_last(bb) else inst_prev(pt);
        after := sdag_get_node(prev);
        if after < 0 fatal("internal: sandbox-vectorizer: moving an instruction after one outside the dependency graph");
        sdag_set_prev_mem(n, sdag_mem_node_before(after, true, n));
    } else {
        before := sdag_get_node(pt);
        if before < 0 fatal("internal: sandbox-vectorizer: moving an instruction before one outside the dependency graph");
        sdag_set_prev_mem(n, sdag_mem_node_before(before, false, n));
        sdag_set_next_mem(n, sdag_mem_node_after(before, true, n));
    }
}

sdag_notify_erase_instr :: (i: Value_Id) {
    if sbx.state == .REVERTING return;
    n := sdag_get_node(i);
    if n < 0 return;
    if sdag_node(n).is_mem {
        pm := sdag_mem_node_before(n, false, -1);
        nm := sdag_mem_node_after(n, false, -1);
        if pm >= 0 sdag_node(pm).next_mem = nm;
        if nm >= 0 sdag_node(nm).prev_mem = pm;
        while sdag_node(n).mem_preds.count sdag_remove_mem_pred(n, sdag_node(n).mem_preds[0]);
        while sdag_node(n).mem_succs.count sdag_remove_mem_pred(sdag_node(n).mem_succs[0], n);
    } else if !sdag_node(n).scheduled {
        tmp: [..] s32; tmp.allocator = temp;
        sdag_preds(n, *tmp);
        for tmp cnt_decr(*sdag_node(it).succs);
        sdag_succs(n, *tmp);
        for tmp cnt_decr(*sdag_node(it).preds);
    }
    sdag_destroy_node(n);
}

// ~DGNode (InstrToNodeMap.erase): leaves its SchedBundle
sdag_destroy_node :: (n: s32) {
    x := sdag_node(n);
    if x.sb >= 0 sdag_set_remove(*ssch.bundles[x.sb].nodes, n);
    x.sb = -1;
    x.live = false;
    table_remove(*sdag.node_of, x.inst);
}

sdag_notify_set_use :: (u: Use_Id, new_src: Value_Id) {
    user := ir.u_user[u];
    if !is_inst(user) return;
    un := sdag_get_node(user);
    if un < 0 return;
    if sdag_node(un).scheduled return;
    cur := ir.u_val[u];
    if is_inst(cur) {
        cn := sdag_get_node(cur);
        if cn >= 0 && !sdag_node(cn).scheduled {
            cnt_decr(*sdag_node(cn).succs);
            cnt_decr(*sdag_node(un).preds);
        }
    }
    if is_inst(new_src) {
        nn := sdag_get_node(new_src);
        if nn >= 0 && !sdag_node(nn).scheduled {
            cnt_incr(*sdag_node(nn).succs);
            cnt_incr(*sdag_node(un).preds);
        }
    }
}

// ---------------------------------------------------------------- ready list (std::priority_queue<.., PriorityCmp>)

// PriorityCmp(N1, N2): true if N1 has the lower priority
ssch_cmp :: (n1: s32, n2: s32) -> bool {
    i1 := sdag_node(n1).inst; i2 := sdag_node(n2).inst;
    t1 := is_terminator(inst_op(i1)); t2 := is_terminator(inst_op(i2));
    if t1 != t2 return t1 && !t2;
    p1 := inst_op(i1) == .PHI; p2 := inst_op(i2) == .PHI;
    if p1 != p2 return !p1 && p2;
    return sdag_cb(i2, i1);
}
// libstdc++ std::__push_heap
ssch_push_heap :: (h: [] s32, hole_in: s64, top: s64, value: s32) {
    hole := hole_in;
    parent := (hole - 1) / 2;
    while hole > top && ssch_cmp(h[parent], value) {
        h[hole] = h[parent];
        hole = parent;
        parent = (hole - 1) / 2;
    }
    h[hole] = value;
}
// libstdc++ std::__adjust_heap
ssch_adjust_heap :: (h: [] s32, hole_in: s64, len: s64, value: s32) {
    hole := hole_in;
    top := hole;
    second := hole;
    while second < (len - 1) / 2 {
        second = 2 * (second + 1);
        if ssch_cmp(h[second], h[second - 1]) second -= 1;
        h[hole] = h[second];
        hole = second;
    }
    if (len & 1) == 0 && second == (len - 2) / 2 {
        second = 2 * (second + 1);
        h[hole] = h[second - 1];
        hole = second - 1;
    }
    ssch_push_heap(h, hole, top, value);
}
ssch_ready_insert :: (n: s32) {
    array_add(*ssch.ready, n);
    ssch_push_heap(ssch.ready, ssch.ready.count - 1, 0, n);
}
ssch_ready_pop :: () -> s32 {
    h := ssch.ready;
    top := h[0];
    last := h.count - 1;
    if last > 0 {
        value := h[last];
        h[last] = h[0];
        sub := h; sub.count = last;
        ssch_adjust_heap(sub, 0, last, value);
    }
    ssch.ready.count -= 1;
    return top;
}
ssch_ready_remove :: (n: s32) {
    keep: [..] s32; keep.allocator = temp;
    while ssch.ready.count {
        t := ssch_ready_pop();
        if t == n break;
        array_add(*keep, t);
    }
    for keep ssch_ready_insert(it);
}
ssch_ready_contains :: (n: s32) -> bool { for ssch.ready if it == n return true; return false; }

// ---------------------------------------------------------------- SchedBundle

ssch_create_bundle :: (instrs: [] Value_Id) -> s32 {
    b: Ssch_Bundle;
    b.nodes.allocator = temp;
    b.live = true;
    array_add(*ssch.bundles, b);
    bi := cast(s32) ssch.bundles.count - 1;
    for instrs {
        n := sdag_get_node(it);
        if n < 0 fatal("internal: sandbox-vectorizer: scheduling an instruction outside the dependency graph");
        array_add(*ssch.bundles[bi].nodes, n);
    }
    // SchedBundle(ContainerTy &&): N->setSchedBundle(*this)
    for n: ssch.bundles[bi].nodes {
        x := sdag_node(n);
        if x.sb >= 0 && x.sb != bi sdag_set_remove(*ssch.bundles[x.sb].nodes, n);
        x.sb = bi;
    }
    return bi;
}
// ~SchedBundle
ssch_erase_bundle :: (bi: s32) {
    b := *ssch.bundles[bi];
    for b.nodes if sdag_node(it).sb == bi sdag_node(it).sb = -1;
    b.nodes.count = 0;
    b.live = false;
}
ssch_bundle_top :: (bi: s32) -> s32 {
    nodes := ssch.bundles[bi].nodes;
    t := nodes[0];
    for k: 1..nodes.count - 1 if sdag_cb(sdag_node(nodes[k]).inst, sdag_node(t).inst) t = nodes[k];
    return t;
}
ssch_bundle_ready :: (bi: s32) -> bool {
    for ssch.bundles[bi].nodes if !node_ready_bottom_up(it) return false;
    return true;
}
// SchedBundle::cluster(Where)
ssch_cluster :: (bi: s32, bb: Value_Id, where_in: Value_Id) {
    where := where_in;
    nodes := ssch.bundles[bi].nodes;
    for n: nodes {
        if ssch_ready_contains(n)
            fatal("sandbox-vectorizer: an instruction in the ready list moves (the ready list order would depend on addresses)");
        i := sdag_node(n).inst;
        if i == where where = inst_next(where);
        sbx_move_before(i, bb, where);
    }
}

// ---------------------------------------------------------------- Scheduler

ssch_new :: (aar: *Aa_Results) {
    // DependencyGraph(AA, Ctx)
    sbv_temp_array(*sdag.nodes);
    sdag.node_of = .{}; sdag.node_of.allocator = temp;
    sdag.iv = .{};
    sdag.aa = aa_query_new(aar);
    sdag.cb_create = sbx_register_callback(.CREATE, .DAG, 0);
    sdag.cb_erase = sbx_register_callback(.ERASE, .DAG, 0);
    sdag.cb_move = sbx_register_callback(.MOVE, .DAG, 0);
    sdag.cb_set_use = sbx_register_callback(.SET_USE, .DAG, 0);
    // Scheduler(AA, Ctx, BottomUp)
    sbv_temp_array(*ssch.ready);
    sbv_temp_array(*ssch.bundles);
    ssch.top_set = false; ssch.top_bb = NONE; ssch.top_pt = NONE;
    ssch.scheduled_bb = NONE;
    ssch.cb_create = sbx_register_callback(.CREATE, .SCHEDULER, 0);
    ssch.alive = true;
}
ssch_delete :: () {
    sbx_unregister_callback(ssch.cb_create);
    sbx_unregister_callback(sdag.cb_create);
    sbx_unregister_callback(sdag.cb_erase);
    sbx_unregister_callback(sdag.cb_move);
    sbx_unregister_callback(sdag.cb_set_use);
    ssch.alive = false;
}
// Scheduler::clear
ssch_clear :: () {
    for * ssch.bundles if it.live { for n: it.nodes sdag_node(n).sb = -1; it.live = false; }
    ssch.bundles.count = 0;
    sdag.nodes.count = 0;
    table_reset(*sdag.node_of);
    sdag.iv = .{};
    ssch.ready.count = 0;
    ssch.top_set = false;
    ssch.scheduled_bb = NONE;
}

// Scheduler::notifyCreateInstr (BottomUp)
ssch_notify_create_instr :: (i: Value_Id) {
    n := sdag_get_node(i);
    if n < 0 return;
    is_scheduled := ssch.top_set && ssch.top_pt != NONE && inst_block(ssch.top_pt) == inst_block(i) && sdag_cb(ssch.top_pt, i);
    if is_scheduled { node_set_scheduled(n); return; }
    tmp: [..] s32; tmp.allocator = temp;
    sdag_preds(n, *tmp);
    for tmp {
        ssch_ready_remove(it);
        cnt_incr(*sdag_node(it).succs);
    }
}

// Scheduler::scheduleAndUpdateReadyList (BottomUp)
ssch_schedule_and_update_ready_list :: (bi: s32) {
    if !ssch.top_set fatal("internal: sandbox-vectorizer: no top of schedule");
    ssch_cluster(bi, ssch.top_bb, ssch.top_pt);
    t := ssch_bundle_top(bi);
    ssch.top_bb = inst_block(sdag_node(t).inst);
    ssch.top_pt = sdag_node(t).inst;
    tmp: [..] s32; tmp.allocator = temp;
    for n: ssch.bundles[bi].nodes {
        sdag_preds(n, *tmp);
        for d: tmp {
            cnt_decr(*sdag_node(d).succs);
            if node_ready_bottom_up(d) && !sdag_node(d).scheduled ssch_ready_insert(d);
        }
        node_set_scheduled(n);
    }
}

Ssch_Try :: enum u8 { SUCCESS; FAILURE; FINISHED; }

ssch_try_schedule_bundle :: (ready_n: s32, instrs_sb: s32) -> Ssch_Try {
    sb := sdag_node(ready_n).sb;
    if sb < 0 {
        one: [1] Value_Id;
        one[0] = sdag_node(ready_n).inst;
        single := ssch_create_bundle(one);
        ssch_schedule_and_update_ready_list(single);
        return .SUCCESS;
    }
    if ssch_bundle_ready(sb) {
        for n: ssch.bundles[sb].nodes if n != ready_n ssch_ready_remove(n);
        ssch_schedule_and_update_ready_list(sb);
        if sb == instrs_sb return .FINISHED;
        return .SUCCESS;
    }
    return .FAILURE;
}

// Scheduler::tryScheduleUntil
ssch_try_schedule_until :: (instrs: [] Value_Id) -> bool {
    instrs_sb := ssch_create_bundle(instrs);
    // Retry is a SmallVector walked with make_early_inc_range while it is erased from: the end of the walk is fixed
    // at its start and the slots past the shrunk size keep their old values, so model the buffer, not the vector.
    retry: [..] s32; retry.allocator = temp;
    retry_n := 0;
    keep := true;
    while keep {
        while ssch.ready.count {
            rn := ssch_ready_pop();
            res := ssch_try_schedule_bundle(rn, instrs_sb);
            if res == .FINISHED return true;
            if res == .FAILURE {
                if retry_n < retry.count retry[retry_n] = rn; else array_add(*retry, rn);
                retry_n += 1;
            }
        }
        keep = false;
        end := retry_n;
        p := 0;
        while p < end {
            n := retry[p];
            p += 1;
            res := ssch_try_schedule_bundle(n, instrs_sb);
            if res == .SUCCESS {
                pos := -1;
                for k: 0..retry_n - 1 if retry[k] == n { pos = k; break; }
                if pos < 0 fatal("sandbox-vectorizer: the scheduler's retry list erases an element it no longer has (LLVM erases end())");
                for k: pos..retry_n - 2 retry[k] = retry[k + 1];
                retry_n -= 1;
                keep = true;
            } else if res == .FINISHED {
                // a FINISHED result in the retry walk is not acted on (LLVM only checks for Success)
            }
        }
    }
    ssch_erase_bundle(instrs_sb);
    return false;
}

Ssch_State :: enum u8 { NONE_SCHEDULED; ALREADY_SCHEDULED; TEMPORARILY_SCHEDULED; FULLY_SCHEDULED; }

// Scheduler::getBndlSchedState
ssch_bundle_sched_state :: (instrs: [] Value_Id) -> Ssch_State {
    n0 := sdag_get_node(instrs[0]);
    sb0 := ifx n0 >= 0 then sdag_node(n0).sb else -1;
    single :: (sb: s32) -> bool { return ssch.bundles[sb].nodes.count == 1; }
    all_unscheduled := sb0 < 0;
    fully := sb0 >= 0 && !single(sb0);
    for k: 1..instrs.count - 1 {
        n := sdag_get_node(instrs[k]);
        sb := ifx n >= 0 then sdag_node(n).sb else -1;
        if sb >= 0 {
            all_unscheduled = false;
            if single(sb) fully = false;
        }
        if sb != sb0 {
            fully = false;
            if (sb >= 0 && !single(sb)) || (sb0 >= 0 && !single(sb0)) return .ALREADY_SCHEDULED;
        }
    }
    if all_unscheduled return .NONE_SCHEDULED;
    if fully return .FULLY_SCHEDULED;
    return .TEMPORARILY_SCHEDULED;
}

sbv_lowest :: (instrs: [] Value_Id) -> Value_Id {
    l := instrs[0];
    for k: 1..instrs.count - 1 if sdag_cb(l, instrs[k]) l = instrs[k];
    return l;
}

// Scheduler::trimSchedule (BottomUp)
ssch_trim_schedule :: (instrs: [] Value_Id) {
    if ssch.top_pt == NONE fatal("internal: sandbox-vectorizer: the top of the schedule is the end of the block");
    top_i := ssch.top_pt;
    lowest := sbv_lowest(instrs);
    i := top_i;
    end := inst_next(lowest);
    while i != end {
        n := sdag_get_node(i);
        if n >= 0 {
            sb := sdag_node(n).sb;
            if sb < 0 fatal("sandbox-vectorizer: trimming the schedule reaches an unscheduled node (LLVM dereferences null)");
            if ssch.bundles[sb].nodes.count == 1 ssch_erase_bundle(sb);
            node_reset_schedule_state(n);
        }
        i = inst_next(i);
    }
    tmp: [..] s32; tmp.allocator = temp;
    i = top_i;
    while i != end {
        n := sdag_get_node(i);
        if n < 0 fatal("sandbox-vectorizer: trimming the schedule reaches an instruction outside the dependency graph (LLVM dereferences null)");
        sdag_preds(n, *tmp);
        for tmp cnt_incr(*sdag_node(it).succs);
        i = inst_next(i);
    }
    ssch.ready.count = 0;
    i = sdag.iv.top;
    while i != end {
        n := sdag_get_node(i);
        if n < 0 fatal("sandbox-vectorizer: refilling the ready list reaches an instruction outside the dependency graph");
        if node_ready_bottom_up(n) ssch_ready_insert(n);
        i = inst_next(i);
    }
}

// Scheduler::trySchedule (BottomUp)
ssch_try_schedule :: (instrs: [] Value_Id) -> bool {
    if !iv_empty(sdag.iv) {
        bb := inst_block(sdag.iv.top);
        for instrs if inst_block(it) != bb return false;
    }
    if ssch.scheduled_bb == NONE ssch.scheduled_bb = inst_block(instrs[0]);
    for instrs if inst_block(it) != ssch.scheduled_bb return false;
    state := ssch_bundle_sched_state(instrs);
    if state == {
        case .FULLY_SCHEDULED; return true;
        case .ALREADY_SCHEDULED; return false;
        case .TEMPORARILY_SCHEDULED;
            sdag_extend(instrs);
            ssch_trim_schedule(instrs);
            l := sbv_lowest(instrs);
            ssch.top_set = true; ssch.top_bb = inst_block(l); ssch.top_pt = inst_next(l);
            return ssch_try_schedule_until(instrs);
        case .NONE_SCHEDULED;
            if !ssch.top_set {
                l := sbv_lowest(instrs);
                ssch.top_set = true; ssch.top_bb = inst_block(l); ssch.top_pt = inst_next(l);
            }
            ext := sdag_extend(instrs);
            if !iv_empty(ext) {
                i := ext.top;
                end := inst_next(ext.bot);
                while i != end {
                    n := sdag_get_node(i);
                    if node_ready_bottom_up(n) ssch_ready_insert(n);
                    i = inst_next(i);
                }
            }
            return ssch_try_schedule_until(instrs);
    }
    return false;
}
