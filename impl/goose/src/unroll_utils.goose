// Loop / CFG utilities shared by LoopUnroll, the runtime remainder, LoopPeel and SimpleLoopUnswitch. Ports of:
// - llvm/lib/Analysis/LoopInfo.cpp: LoopInfo::erase + UnloopUpdater, LoopInfo::removeLoop, Loop::isSafeToClone,
//   Loop::getExitBlock, Loop::getUniqueNonLatchExitBlocks
// - llvm/lib/Analysis/LoopIterator.cpp: LoopBlocksDFS::perform
// - llvm/lib/Transforms/Utils/LoopUnroll.cpp: addClonedBlockToLoopInfo
// - llvm/lib/Transforms/Utils/LoopUtils.cpp: cloneLoop
// - llvm/lib/Transforms/Utils/BasicBlockUtils.cpp: MergeBlockIntoPredecessor(BB, DTU or DT, LI), SplitEdge /
//   SplitBlock / splitBlockBefore with a DominatorTree and LoopInfo (BasicBlock::splitBasicBlockBefore)
// - llvm/lib/Transforms/Utils/Local.cpp: changeToUnreachable(I, PreserveLCSSA),
//   RecursivelyDeleteTriviallyDeadInstructions(V)
//
// Not ported (fail loudly): SplitEdge of a critical edge, splitBlockBefore of a block with several
// predecessors or one creating a new loop header.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_attrs;
import local;
import instsimplify;
import dinfo;
import domtree;
import dtu;
import loopinfo;
import loopsimplify;
import breakcrit;
import cfgutil;
import scev;
import value_mapper;

fn uu_not_ported(what: const u8[:]) { fatal(str("loop utilities: ", what, " is not ported yet")); }

var ul_dfs_seen = hm_new();

// LoopBlocksDFS::perform(LI): the postorder of the loop's blocks from the header (successors in order;
// a successor is visited when its innermost loop is contained in l)
fn loop_blocks_dfs_post(l: i32, post: i32[>..<]&) {
    hm_clear(ul_dfs_seen);
    var st_b: i32[>..<] = [];
    var st_k: i64[>..<] = [];
    let h = loop_header(l);
    hm_put(ul_dfs_seen, h as u64, 1);
    st_b.push(h);
    st_k.push(0);
    while st_b.len > 0 {
        let top = st_b.len - 1;
        let b = st_b[top];
        let k = st_k[top];
        if k < block_nsucc(b) {
            st_k[top] = k + 1;
            let s = block_succ(b, k);
            let sl = li_loop_for(s);
            if sl >= 0 && loop_contains_loop(l, sl) && !hm_has(ul_dfs_seen, s as u64) {
                hm_put(ul_dfs_seen, s as u64, 1);
                st_b.push(s);
                st_k.push(0);
            }
        } else {
            post.push(b);
            st_b.pop();
            st_k.pop();
        }
    }
}

fn loop_blocks_rpo(l: i32, out: i32[>..<]&) {
    var post: i32[>..<] = [];
    loop_blocks_dfs_post(l, post);
    var i = post.len;
    while i > 0 { i--; out.push(post[i]); }
}

// LoopInfo::removeLoop(I) for a top-level loop
fn li_remove_top_level_loop(fv: i32, l: i32) {
    let g = glob_of(fv);
    let r = li_heads[g].top;
    var w: i64 = 0;
    for k in r.n { let x = lrun_get(r, k); if x != l { li_pool[r.at + w] = x; w++; } }
    li_heads[g].top.n = w as i32;
}

// LoopInfo::erase(Unloop)
fn li_erase_loop(ul: i32) {
    let fv = loops[ul].fv;
    if loop_parent(ul) < 0 {
        for k in loop_nblocks(ul) {
            let bb = loop_block(ul, k);
            if li_loop_for(bb) != ul { continue; }
            li_change_loop_for(bb, -1);
        }
        li_remove_top_level_loop(fv, ul);
        while !loop_is_innermost(ul) {
            let c = loop_sub(ul, loop_nsubs(ul) - 1);
            loop_remove_child(ul, c);
            li_add_top_level_loop(fv, c);
        }
        li_destroy_loop(ul);
        return;
    }
    // UnloopUpdater
    var sp_k: i32[>..<] = [];      // SubloopParents keys
    var sp_v: i32[>..<] = [];
    fn sp_find(x: i32) -> i64 { for j in sp_k.len { if sp_k[j] == x { return j; } } return -1; }
    var found_ib = false;
    var post: i32[>..<] = [];
    // getNearestLoop(BB, BBLoop)
    fn nearest_loop(bb: i32, bbl: i32) -> i32 {
        var near = bbl;
        var sub: i32 = -1;
        if near != ul && loop_contains_loop(ul, near) {
            sub = near;
            while loop_parent(sub) != ul { sub = loop_parent(sub); }
            var j = sp_find(sub);
            if j < 0 { sp_k.push(sub); sp_v.push(ul); j = sp_k.len - 1; }
            near = sp_v[j];
        }
        if block_nsucc(bb) == 0 { near = -1; }
        for k in block_nsucc(bb) {
            let s = block_succ(bb, k);
            if s == bb { continue; }
            var l2 = li_loop_for(s);
            if l2 == ul { found_ib = true; }
            if l2 != ul && loop_contains_loop(ul, l2) {
                if sub >= 0 { continue; }
                let j = sp_find(l2);
                if j < 0 { sp_k.push(l2); sp_v.push(-1); l2 = -1; } else { l2 = sp_v[j]; }
            }
            if l2 == ul { continue; }
            if l2 >= 0 && !loop_contains_loop(l2, ul) { l2 = loop_parent(l2); }
            if near == ul || near < 0 || loop_contains_loop(near, l2) { near = l2; }
        }
        if sub >= 0 {
            let j = sp_find(sub);
            sp_v[j] = near;
            return bbl;
        }
        return near;
    }
    // updateBlockParents
    if loop_nblocks(ul) > 0 {
        loop_blocks_dfs_post(ul, post);
        for b in post {
            let l2 = li_loop_for(b);
            let nl = nearest_loop(b, l2);
            if nl != l2 { li_change_loop_for(b, nl); }
        }
    }
    var changed = found_ib;
    while changed {
        changed = false;
        for b in post {
            let l2 = li_loop_for(b);
            let nl = nearest_loop(b, l2);
            if nl != l2 { li_change_loop_for(b, nl); changed = true; }
        }
    }
    // removeBlocksFromAncestors
    var blocks: i32[>..<] = [];
    for k in loop_nblocks(ul) { blocks.push(loop_block(ul, k)); }
    for bb in blocks {
        var op_ = li_loop_for(bb);
        if loop_contains_loop(ul, op_) {
            while loop_parent(op_) != ul { op_ = loop_parent(op_); }
            let j = sp_find(op_);
            if j < 0 { sp_k.push(op_); sp_v.push(-1); op_ = -1; } else { op_ = sp_v[j]; }
        }
        var old = loop_parent(ul);
        while old != op_ {
            if old < 0 { fatal("internal: LoopInfo::erase: new loop is not an ancestor of the original"); }
            loop_remove_block_from_loop(old, bb);
            old = loop_parent(old);
        }
    }
    // updateSubloopParents
    while !loop_is_innermost(ul) {
        let sub = loop_sub(ul, loop_nsubs(ul) - 1);
        loop_remove_child(ul, sub);
        let j = sp_find(sub);
        if j < 0 { fatal("internal: LoopInfo::erase: DFS failed to visit subloop"); }
        let p = sp_v[j];
        if p >= 0 { loop_add_child(p, sub); } else { li_add_top_level_loop(fv, sub); }
    }
    let parent = loop_parent(ul);
    loop_remove_child(parent, ul);
    li_destroy_loop(ul);
}

// LoopInfo::destroy: the loop is invalid from now on
fn li_destroy_loop(l: i32) {
    loops[l].blocks.n = 0;
    loops[l].subs.n = 0;
    loops[l].parent = -1;
}

// addClonedBlockToLoopInfo(OriginalBB, ClonedBB, LI, NewLoops): NewLoops is the pair list (nl_o, nl_n);
// returns the original loop if a new loop was created, else -1
fn add_cloned_block_to_loop_info(obb: i32, cbb: i32, nl_o: i32[>..<]&, nl_n: i32[>..<]&) -> i32 {
    let fv = block_func(obb);
    let old = li_loop_for(obb);
    var j: i64 = -1;
    for k in nl_o.len { if nl_o[k] == old { j = k; } }
    if j < 0 {
        let nl = li_allocate_loop(fv);
        nl_o.push(old);
        nl_n.push(nl);
        var np: i32 = -1;
        let op_ = loop_parent(old);
        for k in nl_o.len { if nl_o[k] == op_ && op_ >= 0 { np = nl_n[k]; } }
        if np >= 0 { loop_add_child(np, nl); } else { li_add_top_level_loop(fv, nl); }
        loop_add_basic_block_to_loop(nl, cbb);
        return old;
    }
    loop_add_basic_block_to_loop(nl_n[j], cbb);
    return -1;
}

// DomTreeNode::setIDom (no DFS-number invalidation)
fn ul_dt_set_idom(fv: i32, bb: i32, idom: i32) { dt_focus(fv, DT_DOM); t_set_idom(bb, idom); }
fn ul_dt_children(fv: i32, bb: i32, out: i32[>..<]&) {
    var c = dt_first_child(fv, DT_DOM, bb);
    while c >= 0 { out.push(c); c = dt_next_sibling(DT_DOM, c); }
}

// changeToUnreachable(I, PreserveLCSSA) without DTU / MSSAU
fn ul_change_to_unreachable(iv: i32, preserve_lcssa: bool) -> i64 {
    let bb = inst_parent(iv);
    let t = block_terminator(bb);
    var succs: i32[>..<] = [];
    for k in term_nsucc(t) { succs.push(term_succ(t, k)); }
    for s in succs { block_remove_predecessor(s, bb, preserve_lcssa); }
    let ui = create_inst(OP_UNREACHABLE, T_VOID, []);
    inst_insert_before(ui, iv);
    let dl = inst_get_md(iv, 0);
    if dl >= 0 { inst_set_md(ui, 0, dl); }
    var n: i64 = 0;
    var i = iv;
    while i >= 0 {
        let ni = inst_next(i);
        if vals[i].first_use >= 0 { rauw(i, c_poison(vals[i].ty)); }
        inst_erase_from_parent(i);
        n++;
        i = ni;
    }
    block_flush_terminator_records(bb);
    return n;
}

// MergeBlockIntoPredecessor(BB, DTU, LI, MSSAU = null, MemDep = null, PredecessorWithTwoSuccessors = false, DT):
// use_dtu = the active (lazy) DomTreeUpdater, else the DT is updated directly
fn ul_merge_block_into_predecessor(bb: i32, use_dtu: bool) -> bool {
    let fv = block_func(bb);
    if cu_has_address_taken(bb) { return false; }
    let pred = cu_unique_pred(bb);
    if pred < 0 || pred == bb { return false; }
    let pti = block_terminator(pred);
    if cu_is_special_terminator(pti) || inst_may_have_side_effects(pti) { return false; }
    if cu_unique_succ(pred) != bb { return false; }
    var i = block_first(bb);
    while i >= 0 && iop(i) == OP_PHI {
        for k in nops(i) { if op(i, k) == i { return false; } }
        i = inst_next(i);
    }
    if cu_has_loop_or_entry_convergence_token(bb) && cu_has_loop_or_entry_convergence_token(pred) { return false; }
    if cu_has_phis(bb) { cu_fold_single_entry_phis(bb); }
    if !use_dtu {
        if dt_has_node(DT_DOM, pred) {
            var ch: i32[>..<] = [];
            ul_dt_children(fv, bb, ch);
            for c in ch { ul_dt_set_idom(fv, c, pred); }
        }
    }
    var ups: DTUpdate[>..<] = [];
    if use_dtu {
        var seen: i32[>..<] = [];
        var succs_of_pred: i32[>..<] = [];
        cu_succs(pred, succs_of_pred);
        var succs: i32[>..<] = [];
        cu_succs(bb, succs);
        for s in succs { if position(succs_of_pred, s) < 0 && cu_push_unique(seen, s) { ups.push(DTUpdate { kind: DT_INSERT, from: pred, to: s }); } }
        seen.clear();
        for s in succs { if cu_push_unique(seen, s) { ups.push(DTUpdate { kind: DT_DELETE, from: bb, to: s }); } }
        ups.push(DTUpdate { kind: DT_DELETE, from: pred, to: bb });
    }
    let sti = block_terminator(bb);
    block_splice(pred, pti, false, bb, block_first(bb), true, sti, false);
    cu_block_rauw(bb, pred);
    inst_erase_from_parent(pti);
    inst_move_impl(sti, pred, -1, false, true);
    block_append_inst(bb, create_inst(OP_UNREACHABLE, T_VOID, []));
    if vals[pred].name < 0 && vals[bb].name >= 0 { cu_take_name(pred, bb); }
    li_remove_block(bb);
    if use_dtu { dtu_apply_updates(ups); }
    if !use_dtu { dt_erase_node(fv, DT_DOM, bb); }
    let save = cu_dtu;
    cu_dtu = use_dtu;
    cu_delete_dead_block(bb);
    cu_dtu = save;
    return true;
}

// RecursivelyDeleteTriviallyDeadInstructions(V) for one value (TLI = nullptr)
fn ul_delete_dead_inst(v: i32) {
    if v < 0 || is_dead(v) || !is_inst(v) { return; }
    if !is_instruction_trivially_dead(v) { return; }
    var one: i32[>..<] = [];
    one.push(v);
    recursively_delete_trivially_dead(one);
}

// Loop::isSafeToClone
fn loop_is_safe_to_clone(l: i32) -> bool {
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        if iop(block_terminator(bb)) == OP_INDIRECTBR { return false; }
        var i = block_first(bb);
        while i >= 0 {
            if is_callbase(i) && call_has_fn_attr(i, AK_NoDuplicate) { return false; }
            i = inst_next(i);
        }
    }
    return true;
}

// SplitBlock(Old, SplitPt, DT, LI) (Before = false)
fn lp_split_block(old: i32, at0: i32) -> i32 {
    let fv = block_func(old);
    var at = at0;
    while iop(at) == OP_PHI || inst_is_eh_pad(at) { at = inst_next(at); }
    var nm: u8[>..] = [];
    nm.append(val_name(old));
    nm.append(".split");
    let nb = split_block(old, at, nm);
    let l = li_loop_for(old);
    if l >= 0 { loop_add_basic_block_to_loop(l, nb); }
    if dt_has_node(DT_DOM, old) {
        var ch: i32[>..<] = [];
        ul_dt_children(fv, old, ch);
        dt_add_new_block(fv, DT_DOM, nb, old);
        for c in ch { dt_change_idom(fv, DT_DOM, c, nb); }
    }
    return nb;
}

// splitBlockBefore(Old, SplitPt, DTU (local lazy over DT), LI) for a block with a single predecessor
fn lp_split_block_before(old: i32, at0: i32) -> i32 {
    let fv = block_func(old);
    var at = at0;
    while iop(at) == OP_PHI || inst_is_eh_pad(at) { at = inst_next(at); }
    var preds: i32[>..<] = [];
    each_pred(old) { p => preds.push(p); };
    if preds.len != 1 { uu_not_ported("splitBlockBefore of a block with several predecessors"); }
    // BasicBlock::splitBasicBlockBefore
    var nm: u8[>..] = [];
    nm.append(val_name(old));
    nm.append(".split");
    let nb = create_block_after(fv, block_prev(old), "");
    if nm.len > 0 { set_name(nb, nm); }
    var loc = inst_get_md(at, 0);
    if loc >= 0 && mds[loc].kind == MK_DI && di_kind(loc) == DIK_LOCATION && di_int(loc, "atomGroup") != 0 { uu_not_ported("key-instruction atoms"); }
    if block_first(old) != at { block_splice(nb, -1, false, old, block_first(old), true, at, false); }
    for p in preds {
        term_replace_successor_with(block_terminator(p), old, nb);
        block_replace_phi_uses_with(old, p, nb);
    }
    let br = create_inst(OP_BR, T_VOID, [old]);
    block_append_inst(nb, br);
    if loc >= 0 { inst_set_md(br, 0, loc); }
    // UpdateAnalysisInformation(Old, New, Preds, DTU, nullptr, LI, nullptr, false, HasLoopExit)
    var ups: DTUpdate[>..<] = [];
    ups.push(DTUpdate { kind: DT_INSERT, from: nb, to: old });
    ups.push(DTUpdate { kind: DT_INSERT, from: preds[0], to: nb });
    ups.push(DTUpdate { kind: DT_DELETE, from: preds[0], to: old });
    dtu_begin(fv, true, false, true);
    dtu_apply_updates(ups);
    dtu_get_dt();
    let l = li_loop_for(old);
    if l >= 0 {
        var entry = true;
        var new_header = false;
        for p in preds {
            if !dt_has_node(DT_DOM, p) { continue; }
            if loop_contains(l, p) { entry = false; } else { new_header = true; }
        }
        if entry {
            var inner: i32 = -1;
            for p in preds {
                var pl = li_loop_for(p);
                while pl >= 0 && !loop_contains(pl, old) { pl = loop_parent(pl); }
                if pl >= 0 && (inner < 0 || loop_depth(inner) < loop_depth(pl)) { inner = pl; }
            }
            if inner >= 0 { loop_add_basic_block_to_loop(inner, nb); }
        } else {
            loop_add_basic_block_to_loop(l, nb);
            if new_header { uu_not_ported("splitBlockBefore creating a new loop header"); }
        }
    }
    dtu_end();
    return nb;
}

// SplitEdge(BB, Succ, DT, LI)
fn lp_split_edge(bb: i32, succ: i32) -> i32 {
    let t = block_terminator(bb);
    var k: i64 = -1;
    for j in term_nsucc(t) { if term_succ(t, j) == succ && k < 0 { k = j; } }
    if is_critical_edge(t, k, false) { uu_not_ported("SplitEdge of a critical edge"); }
    if single_pred(succ) >= 0 { return lp_split_block_before(succ, block_first(succ)); }
    return lp_split_block(bb, block_terminator(bb));
}

// cloneLoop(L, PL, VM, LI, LPM = null)
recursive fn clone_loop(l: i32, pl: i32, m: i32) -> i32 {
    let fv = loops[l].fv;
    let nl = li_allocate_loop(fv);
    if pl >= 0 { loop_add_child(pl, nl); } else { li_add_top_level_loop(fv, nl); }
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        if li_loop_for(bb) == l { loop_add_basic_block_to_loop(nl, vmm_get(m, bb)); }
    }
    for k in loop_nsubs(l) { clone_loop(loop_sub(l, k), nl, m); }
    return nl;
}

// Loop::getExitBlock: the unique exit block (all exit edges to one block), else -1
fn loop_exit_block(l: i32) -> i32 {
    var ex: i32[>..<] = [];
    loop_exit_blocks(l, ex);
    if ex.len != 1 { return -1; }
    return ex[0];
}

// getUniqueNonLatchExitBlocks
fn loop_unique_non_latch_exit_blocks(l: i32, out: i32[>..<]&) {
    let latch = loop_latch(l);
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        if bb == latch { continue; }
        let t = block_terminator(bb);
        for j in term_nsucc(t) {
            let s = term_succ(t, j);
            if !loop_contains(l, s) && position(out, s) < 0 { out.push(s); }
        }
    }
}

// LoopInfo::replacementPreservesLCSSAForm(From, To)
fn uu_replacement_preserves_lcssa(from: i32, to: i32) -> bool {
    if !is_inst(to) { return true; }
    if inst_parent(to) == inst_parent(from) { return true; }
    let tl = li_loop_for(inst_parent(to));
    if tl < 0 { return true; }
    return loop_contains_loop(tl, li_loop_for(inst_parent(from)));
}
