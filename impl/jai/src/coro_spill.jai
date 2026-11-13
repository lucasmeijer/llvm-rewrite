// Which values a coroutine must keep in its frame: the suspend-crossing analysis, rematerialization of cheap
// values instead of spilling them, and the collection of spills and frame allocas.
// Ported from llvm/lib/Transforms/Coroutines/SuspendCrossingInfo.cpp (+ SuspendCrossingInfo.h),
// llvm/lib/Transforms/Coroutines/MaterializationUtils.cpp (RematGraph, rewriteMaterializableInstructions,
// defaultMaterializable, doRematerializations) and llvm/lib/Transforms/Coroutines/SpillUtils.cpp (AllocaUseVisitor as
// an explicit PtrUseVisitor walk, collectFrameAlloca, collectSpillsFromArgs / AndAllocasFromInsts / FromDbgInfo,
// sinkSpillUsesAfterCoroBegin, getSpillInsertionPt), and libstdc++'s std::sort (std_sort_by).

// ---------------------------------------------------------------- SuspendCrossingInfo

// BlockToIndexMapping + BlockData. LLVM numbers blocks by pointer order; any bijection gives the same answers.
Sci :: struct {
    n: s64;
    w: s64;   // words per bit vector
    idx: Table(Value_Id, s32);
    blocks: [..] Value_Id;
    consumes: [..] u64;
    kills: [..] u64;
    kill_loop: [..] bool;
    changed: [..] bool;
    always_kill: [..] bool;
    never_kill: [..] bool;
}

sci_index :: (s: *Sci, bb: Value_Id) -> s64 {
    found, i := table_find(*s.idx, bb);
    assert(found, "BasicBlockNumberng: Unknown block");
    return i;
}
sci_bit :: inline (s: *Sci, vec: *[..] u64, b: s64, bit: s64) -> bool { return (vec.*[b * s.w + bit / 64] >> cast(u64)(bit % 64)) & 1 != 0; }
sci_set :: inline (s: *Sci, vec: *[..] u64, b: s64, bit: s64) { vec.*[b * s.w + bit / 64] |= (cast(u64) 1) << cast(u64)(bit % 64); }
sci_clear :: inline (s: *Sci, vec: *[..] u64, b: s64, bit: s64) { vec.*[b * s.w + bit / 64] &= ~((cast(u64) 1) << cast(u64)(bit % 64)); }
sci_or :: inline (s: *Sci, dst: *[..] u64, d: s64, src: *[..] u64, sb: s64) { for k: 0..s.w - 1 dst.*[d * s.w + k] |= src.*[sb * s.w + k]; }

sci_set_always_kill :: (s: *Sci, b: s64) { s.always_kill[b] = true; s.never_kill[b] = false; }
sci_set_never_kill :: (s: *Sci, b: s64) { s.always_kill[b] = false; s.never_kill[b] = true; }

// SuspendCrossingInfo::computeBlockData<Initialize>
sci_compute_block_data :: (s: *Sci, rpot: [] Value_Id, initialize: bool) -> bool {
    changed := false;
    preds: [..] Value_Id; preds.allocator = temp;
    saved_c := NewArray(s.w, u64,, allocator = temp);
    saved_k := NewArray(s.w, u64,, allocator = temp);
    for bb: rpot {
        b := sci_index(s, bb);
        block_predecessors(bb, *preds);
        if !initialize {
            all_unchanged := true;
            for p: preds if s.changed[sci_index(s, p)] { all_unchanged = false; break; }
            if all_unchanged { s.changed[b] = false; continue; }
        }
        for k: 0..s.w - 1 { saved_c[k] = s.consumes[b * s.w + k]; saved_k[k] = s.kills[b * s.w + k]; }
        for p: preds {
            pn := sci_index(s, p);
            sci_or(s, *s.consumes, b, *s.consumes, pn);
            sci_or(s, *s.kills, b, *s.kills, pn);
            if s.always_kill[pn] sci_or(s, *s.kills, b, *s.consumes, pn);
        }
        if s.always_kill[b] sci_or(s, *s.kills, b, *s.consumes, b);
        else if s.never_kill[b] { for k: 0..s.w - 1 s.kills[b * s.w + k] = 0; }
        else {
            if sci_bit(s, *s.kills, b, b) s.kill_loop[b] = true;
            sci_clear(s, *s.kills, b, b);
        }
        if !initialize {
            ch := false;
            for k: 0..s.w - 1 if saved_c[k] != s.consumes[b * s.w + k] || saved_k[k] != s.kills[b * s.w + k] { ch = true; break; }
            s.changed[b] = ch;
            changed |= ch;
        }
    }
    return changed;
}

// SuspendCrossingInfo::SuspendCrossingInfo
sci_build :: (s: *Sci, f: Value_Id, shape: *Coro_Shape) {
    s.idx.allocator = temp; s.blocks.allocator = temp; s.consumes.allocator = temp; s.kills.allocator = temp;
    s.kill_loop.allocator = temp; s.changed.allocator = temp; s.always_kill.allocator = temp; s.never_kill.allocator = temp;
    for b: fn_blocks(f) { table_set(*s.idx, b, cast(s32) s.blocks.count); array_add(*s.blocks, b); }
    s.n = s.blocks.count;
    s.w = (s.n + 63) / 64;
    array_resize(*s.consumes, s.n * s.w); array_resize(*s.kills, s.n * s.w);
    array_resize(*s.kill_loop, s.n); array_resize(*s.changed, s.n); array_resize(*s.always_kill, s.n); array_resize(*s.never_kill, s.n);
    for k: 0..s.n - 1 { sci_set(s, *s.consumes, k, k); s.changed[k] = true; }
    for ce: shape.coro_ends sci_set_never_kill(s, sci_index(s, inst_block(ce)));
    for ir_i: shape.coro_is_in_ramp_insts {
        u := ir.v_first_use[ir_i];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if is_inst(usr) && inst_op(usr) == .CONDBR {
                t := get_successor(usr, 0);
                if block_single_predecessor(t) != NONE sci_set_never_kill(s, sci_index(s, t));
            }
        }
    }
    mark_suspend_block :: (s: *Sci, barrier: Value_Id) {
        b := sci_index(s, inst_block(barrier));
        sci_set_always_kill(s, b);
        sci_or(s, *s.kills, b, *s.consumes, b);
    }
    for csi: shape.coro_suspends {
        mark_suspend_block(s, csi);
        save := coro_suspend_save(csi);
        if save != NONE mark_suspend_block(s, save);
    }
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(f), *po);
    rpot := NewArray(po.count, Value_Id,, allocator = temp);
    for po rpot[po.count - 1 - it_index] = it;
    sci_compute_block_data(s, rpot, true);
    while sci_compute_block_data(s, rpot, false) {}
}

sci_has_path_crossing_suspend_point :: (s: *Sci, from: Value_Id, to: Value_Id) -> bool {
    return sci_bit(s, *s.kills, sci_index(s, to), sci_index(s, from));
}
sci_has_path_or_loop_crossing_suspend_point :: (s: *Sci, from: Value_Id, to: Value_Id) -> bool {
    t := sci_index(s, to);
    return sci_bit(s, *s.kills, t, sci_index(s, from)) || (from == to && s.kill_loop[t]);
}
// isDefinitionAcrossSuspend(BasicBlock *DefBB, User *U)
sci_def_bb_across_suspend :: (s: *Sci, def_bb: Value_Id, u: Value_Id) -> bool {
    if inst_op(u) == .PHI && phi_num_incoming(u) > 1 return false;
    use_bb := inst_block(u);
    id := call_iid(u);
    if id == IID_CORO_SUSPEND_RETCON || id == IID_CORO_SUSPEND_ASYNC {
        use_bb = block_single_predecessor(use_bb);
        assert(use_bb != NONE, "should have split coro.suspend into its own block");
    }
    return sci_has_path_crossing_suspend_point(s, def_bb, use_bb);
}
// isDefinitionAcrossSuspend(Value &V, User *U) (Argument or Instruction)
sci_def_across_suspend :: (s: *Sci, v: Value_Id, u: Value_Id) -> bool {
    if vkind(v) == .ARGUMENT return sci_def_bb_across_suspend(s, fn_entry(arg_parent(v)), u);
    def_bb := inst_block(v);
    if coro_is_any_suspend(v) {
        def_bb = block_single_successor(def_bb);
        assert(def_bb != NONE, "should have split coro.suspend into its own block");
    }
    return sci_def_bb_across_suspend(s, def_bb, u);
}

// ---------------------------------------------------------------- SpillInfo (SmallMapVector<Value *, SmallVector<Instruction *>>)

Spill_Info :: struct {
    keys: [..] Value_Id;
    uses: [..] [..] Value_Id;
    index: Table(Value_Id, s32);
}
spill_init :: (s: *Spill_Info) { s.keys.allocator = temp; s.uses.allocator = temp; s.index.allocator = temp; }
spill_add :: (s: *Spill_Info, def: Value_Id, user: Value_Id) {
    found, k := table_find(*s.index, def);
    if !found {
        k = cast(s32) s.keys.count;
        table_set(*s.index, def, k);
        array_add(*s.keys, def);
        l: [..] Value_Id; l.allocator = temp;
        array_add(*s.uses, l);
    }
    array_add(*s.uses[k], user);
}

// ---------------------------------------------------------------- MaterializationUtils

// coro::defaultMaterializable (= isTriviallyMaterializable)
coro_default_materializable :: (v: Value_Id) -> bool {
    o := inst_op(v);
    if is_cast_op(o) || o == .GEP || is_binary_op(o) || o == .FNEG || o == .ICMP || o == .FCMP || o == .SELECT return true;
    if o == .CALL {
        name := intrinsic_id_of_call(v);
        if name == {
          case "llvm.fabs"; #through; case "llvm.sqrt"; #through; case "llvm.sin"; #through; case "llvm.cos"; #through;
          case "llvm.exp2"; #through; case "llvm.log2"; #through; case "llvm.minnum"; #through; case "llvm.maxnum"; #through;
          case "llvm.minimum"; #through; case "llvm.maximum"; #through; case "llvm.copysign"; #through; case "llvm.ldexp"; #through;
          case "llvm.fptoui.sat"; #through; case "llvm.fptosi.sat"; #through; case "llvm.is.fpclass"; #through;
          case "llvm.floor"; #through; case "llvm.ceil"; #through; case "llvm.trunc"; #through; case "llvm.rint"; #through;
          case "llvm.nearbyint"; #through; case "llvm.round"; #through; case "llvm.roundeven"; #through;
          case "llvm.ctpop"; #through; case "llvm.ctlz"; #through; case "llvm.cttz"; #through; case "llvm.bitreverse"; #through;
          case "llvm.sadd.sat"; #through; case "llvm.uadd.sat"; #through; case "llvm.ssub.sat"; #through; case "llvm.usub.sat"; #through;
          case "llvm.smax"; #through; case "llvm.smin"; #through; case "llvm.umax"; #through; case "llvm.umin";
            return true;
        }
    }
    return false;
}

// RematGraph: nodes are rows; Remats (instruction -> node) is a table
Remat_Node :: struct { node: Value_Id; operands: [..] s32; }
Remat_Graph :: struct {
    nodes: [..] Remat_Node;
    remats: Table(Value_Id, s32);
    entry: s32;
}

// RematGraph::RematGraph + addNode
remat_graph_build :: (g: *Remat_Graph, i: Value_Id, sci: *Sci) {
    g.nodes.allocator = temp; g.remats.allocator = temp;
    new_node :: (g: *Remat_Graph, v: Value_Id) -> s32 {
        n: Remat_Node; n.node = v; n.operands.allocator = temp;
        array_add(*g.nodes, n);
        return cast(s32) g.nodes.count - 1;
    }
    worklist: [..] s32; worklist.allocator = temp;   // a deque, processed front to back
    wl_head := 0;
    first := new_node(g, i);
    g.entry = first;
    add_node :: (g: *Remat_Graph, nid: s32, worklist: *[..] s32, wl_head: s64, first_use: Value_Id, sci: *Sci) {
        nv := g.nodes[nid].node;
        if table_contains(*g.remats, nv) return;
        table_set(*g.remats, nv, nid);
        n := nops(nv);
        for k: 0..cast(s64) n - 1 {
            d := op(nv, cast(u32) k);
            if d == NONE || !is_inst(d) || !coro_default_materializable(d) || !sci_def_across_suspend(sci, d, first_use) continue;
            found, existing := table_find(*g.remats, d);
            if found { array_add(*g.nodes[nid].operands, existing); continue; }
            no_match := true;
            for x: wl_head..worklist.count - 1 {
                w := worklist.*[x];
                if g.nodes[w].node == d { no_match = false; array_add(*g.nodes[nid].operands, w); break; }
            }
            if no_match {
                child := new_node(g, d);
                array_add(*g.nodes[nid].operands, child);
                array_add(worklist, child);
            }
        }
    }
    add_node(g, first, *worklist, wl_head, i, sci);
    while wl_head < worklist.count {
        nid := worklist[wl_head];
        wl_head += 1;
        add_node(g, nid, *worklist, wl_head, i, sci);
    }
}

// ReversePostOrderTraversal<RematGraph *>
remat_graph_rpot :: (g: *Remat_Graph) -> [] s32 {
    Frame :: struct { n: s32; next: s64; }
    visited: Table(s32, bool); visited.allocator = temp;
    po: [..] s32; po.allocator = temp;
    stack: [..] Frame; stack.allocator = temp;
    table_set(*visited, g.entry, true);
    array_add(*stack, .{g.entry, 0});
    while stack.count {
        top := *stack[stack.count - 1];
        ops := g.nodes[top.n].operands;
        if top.next < ops.count {
            c := ops[top.next];
            top.next += 1;
            if !table_contains(*visited, c) { table_set(*visited, c, true); array_add(*stack, .{c, 0}); }
            continue;
        }
        array_add(*po, top.n);
        stack.count -= 1;
    }
    r := NewArray(po.count, s32,, allocator = temp);
    for po r[po.count - 1 - it_index] = it;
    return r;
}

// rewriteMaterializableInstructions
coro_rewrite_materializable_instructions :: (uses: [] Value_Id, graphs: [] Remat_Graph) {
    Process :: struct { use: Value_Id; def: Value_Id; remat: Value_Id; }
    final: [..] Process; final.allocator = temp;
    for use: uses {
        g := *graphs[it_index];
        rpot := remat_graph_rpot(g);
        to_process: [..] Value_Id; to_process.allocator = temp;
        ub := inst_block(use);
        ins_bb := ub;
        ins_pt := block_first_insertion_pt(ub);
        if coro_is_any_suspend(use) {
            pred := block_single_predecessor(ub);
            assert(pred != NONE, "malformed coro suspend instruction");
            ins_bb = pred; ins_pt = block_terminator(pred);
        }
        // getFirstInsertionPt carries the head bit; an Instruction iterator does not
        head := !coro_is_any_suspend(use);
        for k: 1..rpot.count - 1 {
            d := g.nodes[rpot[k]].node;
            cm := inst_clone(d);
            insert_at_position(cm, ins_bb, ins_pt, head);
            set_name(cm, vname(d));
            ins_pt = cm; head = false;
            for x: to_process replace_uses_of_with(x, d, cm);
            n := nops(use);
            for o: 0..cast(s64) n - 1 if op(use, cast(u32) o) == d array_add(*final, .{use, d, cm});
            array_add(*to_process, cm);
        }
    }
    for r: final {
        if inst_op(r.use) == .PHI {
            if vkind(r.use) == .DEAD continue;
            coro_rauw(r.use, r.remat);
            coro_erase(r.use);
            continue;
        }
        replace_uses_of_with(r.use, r.def, r.remat);
    }
}

// coro::doRematerializations
coro_do_rematerializations :: (f: Value_Id, sci: *Sci) {
    if fn_has_fn_attr(f, .OptimizeNone) return;
    spills: Spill_Info; spill_init(*spills);
    for i: fn_insts(f) {
        if !coro_default_materializable(i) continue;
        u := ir.v_first_use[i];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if sci_def_across_suspend(sci, i, usr) spill_add(*spills, i, usr);
        }
    }
    uses: [..] Value_Id; uses.allocator = temp;
    graphs: [..] Remat_Graph; graphs.allocator = temp;
    seen: Table(Value_Id, bool); seen.allocator = temp;
    for k: 0..spills.keys.count - 1 {
        for usr: spills.uses[k] {
            if table_contains(*seen, usr) continue;
            table_set(*seen, usr, true);
            g: Remat_Graph;
            remat_graph_build(*g, usr, sci);
            array_add(*uses, usr);
            array_add(*graphs, g);
        }
    }
    coro_rewrite_materializable_instructions(uses, graphs);
}

// ---------------------------------------------------------------- SpillUtils

Coro_Alloca_Info :: struct {
    alloca: Value_Id;
    alias_insts: [..] Value_Id;   // DenseMap<Instruction *, std::optional<APInt>> Aliases (offsets known: checked)
    alias_offsets: [..] s64;
    may_write_before_coro_begin: bool;
}

// isSuspendReachableFrom
coro_is_suspend_reachable_from :: (from: Value_Id, visited_or_free: *Table(Value_Id, bool)) -> bool {
    if table_contains(visited_or_free, from) return false;
    table_set(visited_or_free, from, true);
    if coro_is_suspend_block(from) return true;
    t := block_terminator(from);
    n := num_successors(t);
    for k: 0..cast(s64) n - 1 if coro_is_suspend_reachable_from(get_successor(t, cast(u32) k), visited_or_free) return true;
    return false;
}
// isLocalAlloca
coro_is_local_alloca :: (ai: Value_Id) -> bool {
    v: Table(Value_Id, bool); v.allocator = temp;
    u := ir.v_first_use[ai];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if call_iid(usr) == IID_CORO_ALLOCA_FREE table_set(*v, inst_block(usr), true);
    }
    return !coro_is_suspend_reachable_from(inst_block(ai), *v);
}
// lowerNonLocalAlloca
coro_lower_non_local_alloca :: (ai: Value_Id, shape: *Coro_Shape, dead: *[..] Value_Id) -> Value_Id {
    b: Irb; irb_set_before(*b, ai);
    alloc := coro_emit_alloc(shape, *b, call_arg(ai, 0));
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[ai];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for usr: users {
        if call_iid(usr) == IID_CORO_ALLOCA_GET coro_rauw(usr, alloc);
        else {
            irb_set_before(*b, usr);
            coro_emit_dealloc(shape, *b, alloc);
        }
        array_add(dead, usr);
    }
    array_add(dead, ai);
    return alloc;
}

// AllocaUseVisitor
Alloca_Use_Visitor :: struct {
    dt: *Dom_Tree;
    shape: *Coro_Shape;
    sci: *Sci;
    should_use_lifetime_start_info: bool;
    // PtrUseVisitor state
    worklist: [..] Use_Work;
    visited_uses: Table(Use_Id, bool);
    u: Use_Id;
    is_offset_known: bool;
    offset: s64;
    escaped: Value_Id = NONE;   // PI.getEscapingInst()
    // AllocaUseVisitor state
    alias_insts: [..] Value_Id;
    alias_known: [..] bool;
    alias_offsets: [..] s64;
    users: Table(Value_Id, bool);
    user_list: [..] Value_Id;
    lifetime_starts: [..] Value_Id;
    lifetime_start_bbs: [..] Value_Id;
    lifetime_end_bbs: Table(Value_Id, bool);
    coro_suspend_bbs: Table(Value_Id, bool);
    may_write_before_coro_begin: bool;
    should_live_on_frame_set: bool;
    should_live_on_frame: bool;
}
Use_Work :: struct { u: Use_Id; known: bool; offset: s64; }

auv_init :: (v: *Alloca_Use_Visitor, dt: *Dom_Tree, shape: *Coro_Shape, sci: *Sci, use_lifetime: bool) {
    v.dt = dt; v.shape = shape; v.sci = sci; v.should_use_lifetime_start_info = use_lifetime;
    v.worklist.allocator = temp; v.visited_uses.allocator = temp; v.alias_insts.allocator = temp;
    v.alias_known.allocator = temp; v.alias_offsets.allocator = temp; v.users.allocator = temp; v.user_list.allocator = temp;
    v.lifetime_starts.allocator = temp; v.lifetime_start_bbs.allocator = temp; v.lifetime_end_bbs.allocator = temp;
    v.coro_suspend_bbs.allocator = temp;
    for shape.coro_suspends table_set(*v.coro_suspend_bbs, inst_block(it), true);
}
auv_enqueue_users :: (v: *Alloca_Use_Visitor, i: Value_Id) {
    u := ir.v_first_use[i];
    while u != NONE {
        if !table_contains(*v.visited_uses, u) {
            table_set(*v.visited_uses, u, true);
            array_add(*v.worklist, .{u, v.is_offset_known, v.offset});
        }
        u = ir.u_next[u];
    }
}
auv_handle_may_write :: (v: *Alloca_Use_Visitor, i: Value_Id) {
    if !dt_dominates_inst(v.dt, v.shape.coro_begin, i) v.may_write_before_coro_begin = true;
}
auv_used_after_coro_begin :: (v: *Alloca_Use_Visitor, i: Value_Id) -> bool {
    u := ir.v_first_use[i];
    while u != NONE {
        if dt_dominates_use(v.dt, v.shape.coro_begin, u) return true;
        u = ir.u_next[u];
    }
    return false;
}
auv_handle_alias :: (v: *Alloca_Use_Visitor, i: Value_Id) {
    if dt_dominates_inst(v.dt, v.shape.coro_begin, i) || !auv_used_after_coro_begin(v, i) return;
    idx := -1;
    for v.alias_insts if it == i { idx = it_index; break; }
    if !v.is_offset_known {
        if idx < 0 { array_add(*v.alias_insts, i); array_add(*v.alias_known, false); array_add(*v.alias_offsets, 0); }
        else v.alias_known[idx] = false;
    } else {
        if idx < 0 { array_add(*v.alias_insts, i); array_add(*v.alias_known, true); array_add(*v.alias_offsets, v.offset); }
        else if v.alias_known[idx] && v.alias_offsets[idx] != v.offset v.alias_known[idx] = false;
    }
}
auv_set_escaped :: (v: *Alloca_Use_Visitor, i: Value_Id) { v.escaped = i; }

// AllocaUseVisitor::visitStoreInst
auv_visit_store :: (v: *Alloca_Use_Visitor, si: Value_Id) {
    auv_handle_may_write(v, si);
    if op(si, 0) != ir.u_val[v.u] return;
    // IsSimpleStoreThenLoad
    simple := true;
    ai := op(si, 1);
    if !(is_inst(ai) && inst_op(ai) == .ALLOCA) simple = false;
    else {
        store_aliases: [..] Value_Id; store_aliases.allocator = temp;
        array_add(*store_aliases, ai);
        while store_aliases.count && simple {
            i := pop(*store_aliases);
            u := ir.v_first_use[i];
            while u != NONE {
                usr := ir.u_user[u];
                u = ir.u_next[u];
                if !is_inst(usr) { simple = false; break; }
                o := inst_op(usr);
                if o == .LOAD { auv_enqueue_users(v, usr); auv_handle_alias(v, usr); continue; }
                if o == .STORE && op(usr, 1) == i continue;
                id := call_iid(usr);
                if id == IID_LIFETIME_START || id == IID_LIFETIME_END continue;
                if o == .BITCAST { array_add(*store_aliases, usr); continue; }
                simple = false; break;
            }
        }
    }
    if !simple auv_set_escaped(v, si);
}

// AllocaUseVisitor::visitCallBase
auv_visit_call_base :: (v: *Alloca_Use_Visitor, cb: Value_Id) {
    n := call_arg_count(cb);
    val := ir.u_val[v.u];
    for k: 0..cast(s64) n - 1 if call_arg(cb, cast(u32) k) == val && !call_does_not_capture(cb, cast(u32) k) auv_set_escaped(v, cb);
    auv_handle_may_write(v, cb);
}

// AllocaUseVisitor::visit(Instruction &I): Users.insert, InstVisitor dispatch, then the MayWriteBeforeCoroBegin check
auv_visit :: (v: *Alloca_Use_Visitor, i: Value_Id) {
    if !table_contains(*v.users, i) { table_set(*v.users, i, true); array_add(*v.user_list, i); }
    o := inst_op(i);
    if o == {
      case .PHI; #through;
      case .SELECT; #through;
      case .INSERTELEMENT; #through;
      case .INSERTVALUE;
        auv_enqueue_users(v, i); auv_handle_alias(v, i);
      case .CATCHPAD;
        v.should_live_on_frame_set = true; v.should_live_on_frame = false;
        v.worklist.count = 0;
      case .STORE; auv_visit_store(v, i);
      case .BITCAST; #through;
      case .ADDRSPACECAST;
        auv_enqueue_users(v, i); auv_handle_alias(v, i);
      case .GEP;
        // PtrUseVisitor::visitGetElementPtrInst, then handleAlias
        if has_uses(i) {
            if v.is_offset_known {
                ok, off := gep_accumulate_constant_offset(i, ap_zero(64));
                if ok v.offset += ap_sext_value(off); else { v.is_offset_known = false; v.offset = 0; }
            }
            auv_enqueue_users(v, i);
        }
        auv_handle_alias(v, i);
      case .PTRTOINT; auv_set_escaped(v, i);
      case .CALL; #through;
      case .INVOKE; #through;
      case .CALLBR;
        id := call_iid(i);
        if o == .CALL && id != NOT_INTRINSIC {
            if is_mem_intrinsic_id(id) auv_handle_may_write(v, i);   // visitMemIntrinsic
            else if id == IID_LIFETIME_START { array_add(*v.lifetime_starts, i); array_add(*v.lifetime_start_bbs, inst_block(i)); }
            else if id == IID_LIFETIME_END table_set(*v.lifetime_end_bbs, inst_block(i), true);
            else if id == IID_FAKE_USE auv_set_escaped(v, i);
            else auv_visit_call_base(v, i);
        } else auv_visit_call_base(v, i);
    }
    if v.escaped != NONE && !dt_dominates_inst(v.dt, v.shape.coro_begin, v.escaped) v.may_write_before_coro_begin = true;
}

// PtrUseVisitor::visitPtr
auv_visit_ptr :: (v: *Alloca_Use_Visitor, ai: Value_Id) {
    v.is_offset_known = true;
    v.offset = 0;
    auv_enqueue_users(v, ai);
    while v.worklist.count {
        w := pop(*v.worklist);
        v.u = w.u;
        v.is_offset_known = w.known;
        if w.known v.offset = w.offset;
        auv_visit(v, ir.u_user[w.u]);
    }
}

// isManyPotentiallyReachableFromMany(Worklist, StopSet, ExclusionSet (non-empty), DT, nullptr): the DT is dropped
coro_many_reachable_from_many :: (worklist_in: [] Value_Id, stop: *Table(Value_Id, bool), exclusion: *Table(Value_Id, bool)) -> bool {
    worklist: [..] Value_Id; worklist.allocator = temp;
    for worklist_in array_add(*worklist, it);
    visited: Table(Value_Id, bool); visited.allocator = temp;
    limit := CFG_MAX_BBS_TO_EXPLORE;
    while worklist.count {
        bb := pop(*worklist);
        if table_contains(*visited, bb) continue;
        table_set(*visited, bb, true);
        if table_contains(stop, bb) return true;
        if table_contains(exclusion, bb) continue;
        limit -= 1;
        if limit == 0 return true;
        t := block_terminator(bb);
        n := num_successors(t);
        for k: 0..cast(s64) n - 1 array_add(*worklist, get_successor(t, cast(u32) k));
    }
    return false;
}

// AllocaUseVisitor::computeShouldLiveOnFrame
auv_compute_should_live_on_frame :: (v: *Alloca_Use_Visitor) -> bool {
    if v.should_use_lifetime_start_info && v.lifetime_starts.count {
        if v.lifetime_end_bbs.count == 0 return true;
        if coro_many_reachable_from_many(v.lifetime_start_bbs, *v.coro_suspend_bbs, *v.lifetime_end_bbs) return true;
        if v.escaped != NONE {
            for a: v.lifetime_starts for b: v.lifetime_starts
                if sci_has_path_or_loop_crossing_suspend_point(v.sci, inst_block(a), inst_block(b)) return true;
        }
        return false;
    }
    if v.escaped != NONE return true;
    for u1: v.user_list for u2: v.user_list if sci_def_across_suspend(v.sci, u1, u2) return true;
    return false;
}
auv_get_should_live_on_frame :: (v: *Alloca_Use_Visitor) -> bool {
    if !v.should_live_on_frame_set { v.should_live_on_frame = auv_compute_should_live_on_frame(v); v.should_live_on_frame_set = true; }
    return v.should_live_on_frame;
}

// collectFrameAlloca
coro_collect_frame_alloca :: (ai: Value_Id, shape: *Coro_Shape, sci: *Sci, allocas: *[..] Coro_Alloca_Info, dt: *Dom_Tree) {
    if shape.coro_suspends.count == 0 return;
    if ai == shape.sw_promise_alloca && shape.abi == .SWITCH return;
    if get_metadata(ai, md_kind_id("coro.outside.frame")) != NONE return;
    use_lifetime := shape.abi != .ASYNC && shape.abi != .RETCON && shape.abi != .RETCON_ONCE;
    v: Alloca_Use_Visitor;
    auv_init(*v, dt, shape, sci, use_lifetime);
    auv_visit_ptr(*v, ai);
    if !auv_get_should_live_on_frame(*v) return;
    info: Coro_Alloca_Info;
    info.alloca = ai;
    info.alias_insts.allocator = temp; info.alias_offsets.allocator = temp;
    for v.alias_insts {
        if !v.alias_known[it_index] fatal("Unable to handle an alias with unknown offset created before CoroBegin.");
        array_add(*info.alias_insts, it);
        array_add(*info.alias_offsets, v.alias_offsets[it_index]);
    }
    info.may_write_before_coro_begin = v.may_write_before_coro_begin;
    array_add(allocas, info);
}

// coro::collectSpillsFromArgs
coro_collect_spills_from_args :: (spills: *Spill_Info, f: Value_Id, sci: *Sci) {
    na := glob(f).nargs;
    for k: 0..cast(s64) na - 1 {
        a := fn_arg(f, cast(u32) k);
        u := ir.v_first_use[a];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if sci_def_across_suspend(sci, a, usr) spill_add(spills, a, usr);
        }
    }
}

// coro::collectSpillsAndAllocasFromInsts
coro_collect_spills_and_allocas_from_insts :: (spills: *Spill_Info, allocas: *[..] Coro_Alloca_Info, dead: *[..] Value_Id,
                                               local_allocas: *[..] Value_Id, f: Value_Id, sci: *Sci, dt: *Dom_Tree, shape: *Coro_Shape) {
    for i: fn_insts(f) {
        id := call_iid(i);
        if id == IID_CORO_ID || id == IID_CORO_SAVE || i == shape.coro_begin continue;   // isNonSpilledIntrinsic
        if id == IID_CORO_ALLOCA_ALLOC {
            if coro_is_local_alloca(i) { array_add(local_allocas, i); continue; }
            alloc := coro_lower_non_local_alloca(i, shape, dead);
            u := ir.v_first_use[alloc];
            while u != NONE {
                usr := ir.u_user[u];
                u = ir.u_next[u];
                if sci_def_across_suspend(sci, alloc, usr) spill_add(spills, alloc, usr);
            }
            continue;
        }
        if id == IID_CORO_ALLOCA_GET continue;
        if inst_op(i) == .ALLOCA { coro_collect_frame_alloca(i, shape, sci, allocas, dt); continue; }
        u := ir.v_first_use[i];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if sci_def_across_suspend(sci, i, usr) {
                if vtype(i) == ir.t_token fatal("token definition is separated from the use by a suspend point");
                spill_add(spills, i, usr);
            }
        }
    }
}

// findDbgValues / findDVRDeclares / findDVRDeclareValues: the records of a kind using v
coro_find_dbg_records :: (f: Value_Id, v: Value_Id, kind: Dbg_Record_Kind, out: *[..] u32) {
    all: [..] u32; all.allocator = temp;
    find_dbg_users(f, v, *all);
    out.count = 0;
    for all if dbgr(it).kind == kind array_add(out, it);
}

// coro::collectSpillsFromDbgInfo
coro_collect_spills_from_dbg_info :: (spills: *Spill_Info, f: Value_Id, sci: *Sci) {
    recs: [..] u32; recs.allocator = temp;
    k := 0;
    while k < spills.keys.count {
        v := spills.keys[k];
        coro_find_dbg_records(f, v, .VALUE, *recs);
        for r: recs {
            owner := dbgr(r).owner;
            if sci_def_across_suspend(sci, v, owner) spill_add(spills, v, owner);
        }
        k += 1;
    }
}

// coro::sinkSpillUsesAfterCoroBegin
coro_sink_spill_uses_after_coro_begin :: (dt: *Dom_Tree, coro_begin: Value_Id, spills: *Spill_Info, allocas: [] Coro_Alloca_Info) {
    to_move: [..] Value_Id; to_move.allocator = temp;
    in_move: Table(Value_Id, bool); in_move.allocator = temp;
    worklist: [..] Value_Id; worklist.allocator = temp;
    collect_users :: (def: Value_Id) #expand {
        u := ir.v_first_use[def];
        while u != NONE {
            inst_u := ir.u_user[u];
            u = ir.u_next[u];
            if inst_block(inst_u) != inst_block(coro_begin) || dt_dominates_inst(dt, coro_begin, inst_u) continue;
            if !table_contains(*in_move, inst_u) { table_set(*in_move, inst_u, true); array_add(*to_move, inst_u); array_add(*worklist, inst_u); }
        }
    }
    for spills.keys collect_users(it);
    for allocas collect_users(it.alloca);
    while worklist.count {
        def := pop(*worklist);
        u := ir.v_first_use[def];
        while u != NONE {
            inst_u := ir.u_user[u];
            u = ir.u_next[u];
            if dt_dominates_inst(dt, coro_begin, inst_u) continue;
            if !table_contains(*in_move, inst_u) { table_set(*in_move, inst_u, true); array_add(*to_move, inst_u); array_add(*worklist, inst_u); }
        }
    }
    // llvm::sort(InsertionList, Dom.dominates(A, B)) (std::sort: insertion sort below 16 elements)
    list := to_move;
    std_sort_by(list, (a: Value_Id, b: Value_Id, d: *void) -> bool { return dt_dominates_inst(cast(*Dom_Tree) d, a, b); }, dt);
    insert_pt := inst_next(coro_begin);
    for list inst_move_before_dbg(it, insert_pt);
}

// splitBeforeCatchSwitch
coro_split_before_catch_switch :: (cs: Value_Id) -> Value_Id {
    cur := inst_block(cs);
    nb := split_basic_block(cur, cs, "");
    t := block_terminator(cur);
    coro_erase(t);
    pad := new_inst(.CLEANUPPAD, ir.t_token, 1);
    set_op(pad, 0, op(cs, 0));   // the catchswitch's parent pad
    block_append_inst(cur, pad);
    ret := new_inst(.CLEANUPRET, ir.t_void, 2);
    set_op(ret, 0, pad); set_op(ret, 1, nb);
    block_append_inst(cur, ret);
    return ret;
}

// coro::getSpillInsertionPt: (block, instruction, head bit)
coro_get_spill_insertion_pt :: (shape: *Coro_Shape, def: Value_Id, dt: *Dom_Tree) -> (Value_Id, Value_Id, bool) {
    if vkind(def) == .ARGUMENT {
        coro_fn_remove_param_attr(arg_parent(def), arg_no(def), .Captures);
        a, b, c := coro_insert_pt_after_frame_ptr(shape);
        return a, b, c;
    }
    if coro_is_any_suspend(def) {
        s := block_single_successor(inst_block(def));
        return s, block_first_non_phi(s), false;
    }
    if !dt_dominates_inst(dt, shape.coro_begin, def) { a, b, c := coro_insert_pt_after_frame_ptr(shape); return a, b, c; }
    if inst_op(def) == .INVOKE {
        nb := split_edge(inst_block(def), get_successor(def, 0), null, null);
        return nb, block_terminator(nb), false;
    }
    if inst_op(def) == .PHI {
        db := inst_block(def);
        t := block_terminator(db);
        if inst_op(t) == .CATCHSWITCH { r := coro_split_before_catch_switch(t); return inst_block(r), r, false; }
        pt := block_first_insertion_pt(db);
        return db, pt, true;
    }
    return inst_block(def), inst_next(def), false;
}

// libstdc++ std::sort (introsort + final insertion sort) over Value_Ids, so that a comparator that is not a strict
// weak order (LLVM sorts with DominatorTree::dominates) gives the same permutation as LLVM's build
std_sort_by :: (a: [] Value_Id, less: (Value_Id, Value_Id, *void) -> bool, data: *void) {
    n := a.count;
    if n < 2 return;
    lg := 0; x := n; while x > 1 { x >>= 1; lg += 1; }
    std_introsort_loop(a, 0, n, lg * 2, less, data);
    // __final_insertion_sort
    if n > 16 {
        std_insertion_sort(a, 0, 16, less, data);
        for i: 16..n - 1 std_unguarded_linear_insert(a, i, less, data);
    } else std_insertion_sort(a, 0, n, less, data);
}
std_introsort_loop :: (a: [] Value_Id, first: s64, last_in: s64, depth_in: s64, less: (Value_Id, Value_Id, *void) -> bool, data: *void) {
    last := last_in; depth := depth_in;
    while last - first > 16 {
        if depth == 0 fatal("internal: std::sort fell back to heap sort (not ported)");
        depth -= 1;
        // __unguarded_partition_pivot
        mid := first + (last - first) / 2;
        // __move_median_to_first(first, first + 1, mid, last - 1)
        r := first; pa := first + 1; pb := mid; pc := last - 1;
        sw :: (a: [] Value_Id, i: s64, j: s64) { t := a[i]; a[i] = a[j]; a[j] = t; }
        if less(a[pa], a[pb], data) {
            if less(a[pb], a[pc], data) sw(a, r, pb);
            else if less(a[pa], a[pc], data) sw(a, r, pc);
            else sw(a, r, pa);
        } else if less(a[pa], a[pc], data) sw(a, r, pa);
        else if less(a[pb], a[pc], data) sw(a, r, pc);
        else sw(a, r, pb);
        // __unguarded_partition(first + 1, last, first)
        lo := first + 1; hi := last;
        while true {
            while less(a[lo], a[first], data) lo += 1;
            hi -= 1;
            while less(a[first], a[hi], data) hi -= 1;
            if !(lo < hi) break;
            sw(a, lo, hi);
            lo += 1;
        }
        std_introsort_loop(a, lo, last, depth, less, data);
        last = lo;
    }
}
std_insertion_sort :: (a: [] Value_Id, first: s64, last: s64, less: (Value_Id, Value_Id, *void) -> bool, data: *void) {
    if first == last return;
    for i: first + 1..last - 1 {
        if less(a[i], a[first], data) {
            v := a[i];
            j := i;
            while j > first { a[j] = a[j - 1]; j -= 1; }
            a[first] = v;
        } else std_unguarded_linear_insert(a, i, less, data);
    }
}
std_unguarded_linear_insert :: (a: [] Value_Id, last_in: s64, less: (Value_Id, Value_Id, *void) -> bool, data: *void) {
    last := last_in;
    v := a[last];
    nx := last - 1;
    while less(v, a[nx], data) { a[last] = a[nx]; last = nx; nx -= 1; }
    a[last] = v;
}
