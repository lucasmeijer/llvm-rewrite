// LoopSimplify (loop-simplify) and the block-splitting utilities it is built on.
// Ports:
//   llvm/lib/Transforms/Utils/LoopSimplify.cpp  placeSplitBlockCarefully, InsertPreheaderForLoop,
//       addBlockAndPredsToSet, findPHIToPartitionLoops, separateNestedLoop, insertUniqueBackedgeBlock,
//       simplifyOneLoop, simplifyLoop, LoopSimplifyPass::run
//   llvm/lib/Transforms/Utils/BasicBlockUtils.cpp  SplitBlockPredecessors (UpdateAnalysisInformation,
//       UpdatePHINodes) for the DominatorTree (not DomTreeUpdater) + LoopInfo form
//   llvm/lib/Transforms/Utils/LoopUtils.cpp  formDedicatedExitBlocks
//   llvm/lib/Transforms/Utils/Local.cpp  changeToUnreachable (without DTU)
//   llvm/lib/Analysis/LoopInfo.cpp  Loop::makeLoopInvariant, Loop::getStartLoc
// simplifyInstruction on PHIs is simplifyPHINode, in ssaupdater.goose.
// Not ported (fail loudly): landing-pad predecessors (SplitLandingPadPredecessors), LoopInfo::erase,
// MemorySSA/ScalarEvolution updates, and the exit-merging foldBranchToCommonDest transformation (its
// "nothing to do" checks are ported, so it only fails when LLVM would actually fold).
import std;
import ir;
import dinfo;
import apint;
import irutil;
import instinfo;
import calls;
import analyses;
import domtree;
import memoryssa;
import mssaupdater;
import loopinfo;
import ssaupdater;

// ---------------------------------------------------------------------------------------------
// Block list helpers

// Unlink a block from its function's list without changing its parent or number (ilist splice).
fn block_unlink_raw(bv: i32) {
    let b = block_of(bv);
    let g = glob_of(blocks[b].parent);
    let p = blocks[b].prev;
    let n = blocks[b].next;
    if p >= 0 { blocks[block_of(p)].next = n; } else { globs[g].first_block = n; }
    if n >= 0 { blocks[block_of(n)].prev = p; } else { globs[g].last_block = p; }
    blocks[b].prev = -1;
    blocks[b].next = -1;
}
// BasicBlock::moveAfter(MovePos)
fn block_move_after(bv: i32, after: i32) {
    if bv == after { return; }
    block_unlink_raw(bv);
    let b = block_of(bv);
    let g = glob_of(blocks[b].parent);
    let nx = block_next(after);
    blocks[b].prev = after;
    blocks[b].next = nx;
    blocks[block_of(after)].next = bv;
    if nx >= 0 { blocks[block_of(nx)].prev = bv; } else { globs[g].last_block = bv; }
}
// BasicBlock::moveBefore(MovePos) / F->splice(Pos, F, BB); before = -1 moves to the end.
fn block_move_before(bv: i32, before: i32) {
    if bv == before { return; }
    block_unlink_raw(bv);
    let b = block_of(bv);
    let g = glob_of(blocks[b].parent);
    if before < 0 {
        let last = globs[g].last_block;
        blocks[b].prev = last;
        blocks[b].next = -1;
        if last >= 0 { blocks[block_of(last)].next = bv; } else { globs[g].first_block = bv; }
        globs[g].last_block = bv;
        return;
    }
    let pv = block_prev(before);
    blocks[b].prev = pv;
    blocks[b].next = before;
    blocks[block_of(before)].prev = bv;
    if pv >= 0 { blocks[block_of(pv)].next = bv; } else { globs[g].first_block = bv; }
}
// BasicBlock::Create(Ctx, Name, F, InsertBefore)
fn create_block_before(fv: i32, before: i32, name: const u8[:]) -> i32 {
    let nb = create_block_after(fv, -1, "");
    block_move_before(nb, before);
    if name.len > 0 { set_name(nb, name); }
    return nb;
}
// Instruction::replaceSuccessorWith(OldBB, NewBB): every successor slot equal to old.
fn term_replace_successor_with(t: i32, old: i32, nw: i32) {
    for k in term_nsucc(t) { if term_succ(t, k) == old { term_set_succ(t, k, nw); } }
}
fn block_name_plus(bv: i32, suffix: const u8[:]) -> u8[>..] {
    var nm: u8[>..] = [];
    nm.append(val_name(bv));
    nm.append(suffix);
    return nm;
}
fn new_phi(ty: i32, reserve: i64) -> i32 {
    let pn = new_inst(OP_PHI, ty, reserve);
    vals[pn].nops = 0;
    return pn;
}
// PHINode::getIncomingValueForBlock
fn phi_value_for_block(p: i32, b: i32) -> i32 { let k = phi_block_index(p, b); if k < 0 { -1 } else { phi_value(p, k) } }

// ---------------------------------------------------------------------------------------------
// Loop::getStartLoc (getLocRange().getStart())
fn loop_start_loc(l: i32) -> i32 {
    let lid = loop_id(l);
    if lid >= 0 {
        for k in 1..mds[lid].nops as i64 {
            let m = md_op(lid, k);
            if m >= 0 && mds[m].kind == MK_DI && di_kind(m) == DIK_LOCATION { return m; }
        }
    }
    let ph = loop_preheader(l);
    if ph >= 0 {
        let dl = inst_get_md(block_terminator(ph), 0);
        if dl >= 0 { return dl; }
    }
    return inst_get_md(block_terminator(loop_header(l)), 0);
}

// ---------------------------------------------------------------------------------------------
// SplitBlockPredecessors(BB, Preds, Suffix, DT, LI, MSSAU = null, PreserveLCSSA)

fn has_reachable_loop_entry_to_header(l: i32) -> bool {
    var r = false;
    each_pred(loop_header(l)) { p => if !loop_contains(l, p) && dt_has_node(DT_DOM, p) { r = true; } };
    return r;
}

// MemorySSAUpdater *MSSAU != nullptr (the cached MemorySSA of the function is kept up to date)
var ls_mssau: bool = false;
// SplitBlockPredecessors gets a (lazy) DomTreeUpdater instead of the DominatorTree (LICM's sinking)
var ls_split_dtu: bool = false;

// UpdateAnalysisInformation (DT form); returns HasLoopExit.
fn update_analysis_information(old: i32, nb: i32, preds: const i32[:], use_dt: bool, use_li: bool, preserve_lcssa: bool) -> bool {
    let fv = block_func(old);
    if use_dt && ls_split_dtu {
        // a lazy DomTreeUpdater, flushed right away by DTU->getDomTree() (LoopInfo is updated below)
        if func_entry(fv) == nb { fatal("SplitBlockPredecessors of the entry block with a DomTreeUpdater is not ported yet"); }
        var ups: DTUpdate[>..<] = [];
        var uniq: i32[>..<] = [];
        ups.push(DTUpdate { kind: DT_INSERT, from: nb, to: old });
        for p in preds {
            if position(uniq, p) < 0 {
                uniq.push(p);
                ups.push(DTUpdate { kind: DT_INSERT, from: p, to: nb });
                ups.push(DTUpdate { kind: DT_DELETE, from: p, to: old });
            }
        }
        dt_apply_updates(fv, DT_DOM, ups);
    } else if use_dt {
        if old == dt_root(fv, DT_DOM) { fatal("SplitBlockPredecessors of the entry block (DominatorTree::setNewRoot) is not ported yet"); }
        dt_split_block(fv, DT_DOM, nb);
    }
    // Update MemoryPhis after split if MemorySSA is available
    if ls_mssau { msu_wire_old_preds_to_new_pred(old, nb, preds, true); }
    var has_loop_exit = false;
    if !use_li { return false; }
    if !use_dt { fatal("internal: SplitBlockPredecessors updates LoopInfo only with a DominatorTree"); }
    let l = li_loop_for(old);
    var is_loop_entry = l >= 0;
    var split_new_header = false;
    for p in preds {
        if !dt_has_node(DT_DOM, p) { continue; }
        if preserve_lcssa {
            let pl = li_loop_for(p);
            if pl >= 0 && !loop_contains(pl, old) { has_loop_exit = true; }
        }
        if l < 0 { continue; }
        if loop_contains(l, p) { is_loop_entry = false; } else { split_new_header = true; }
    }
    if l < 0 { return has_loop_exit; }
    if is_loop_entry {
        var inner: i32 = -1;
        for p in preds {
            var pl = li_loop_for(p);
            if pl >= 0 {
                while pl >= 0 && !loop_contains(pl, old) { pl = loop_parent(pl); }
                if pl >= 0 && loop_contains(pl, old) && (inner < 0 || loop_depth(inner) < loop_depth(pl)) { inner = pl; }
            }
        }
        if inner >= 0 { loop_add_basic_block_to_loop(inner, nb); }
    } else {
        loop_add_basic_block_to_loop(l, nb);
        if split_new_header {
            if has_reachable_loop_entry_to_header(l) { fatal("LoopInfo::erase (SplitBlockPredecessors making a new loop header) is not ported yet"); }
            loop_move_to_header(l, nb);
        }
    }
    return has_loop_exit;
}

// UpdatePHINodes(OrigBB, NewBB, Preds, BI, HasLoopExit)
fn update_phi_nodes(orig: i32, nb: i32, preds: const i32[:], bi: i32, has_loop_exit: bool) {
    fn in_preds(b: i32) -> bool { position(preds, b) >= 0 }
    var i = block_first(orig);
    while i >= 0 && iop(i) == OP_PHI {
        let pn = i;
        i = inst_next(i);
        var inval: i32 = -1;
        if !has_loop_exit {
            inval = phi_value_for_block(pn, preds[0]);
            for k in phi_nincoming(pn) {
                if !in_preds(phi_block(pn, k)) { continue; }
                if inval < 0 { inval = phi_value(pn, k); }
                else if inval != phi_value(pn, k) { inval = -1; break; }
            }
        }
        if inval >= 0 {
            // removeIncomingValueIf(in PredSet), then addIncoming(InVal, NewBB)
            var k = phi_nincoming(pn);
            while k > 0 { k--; if in_preds(phi_block(pn, k)) { phi_remove_incoming(pn, k); } }
            phi_add_incoming(pn, inval, nb);
            continue;
        }
        let np = new_phi(vals[pn].ty, preds.len);
        inst_insert_before(np, bi);
        let nm = block_name_plus(pn, ".ph");
        set_name(np, nm);
        var k = phi_nincoming(pn) as i64 - 1;
        while k >= 0 {
            let ib = phi_block(pn, k);
            if in_preds(ib) {
                let v = phi_remove_incoming(pn, k);
                phi_add_incoming(np, v, ib);
            }
            k--;
        }
        phi_add_incoming(pn, np, nb);
    }
}

fn split_block_predecessors(bb: i32, preds: const i32[:], suffix: const u8[:], use_dt: bool, use_li: bool, preserve_lcssa: bool) -> i32 {
    // canSplitPredecessors / isLandingPad
    let fnp = first_non_phi(bb);
    if fnp >= 0 && iop(fnp) == OP_LANDINGPAD {
        var s2: u8[>..] = [];
        s2.append(suffix);
        s2.append(".split-lp");
        return split_landing_pad_predecessors(bb, preds, suffix, s2, use_dt, use_li, preserve_lcssa);
    }
    if fnp >= 0 && inst_is_eh_pad(fnp) { return -1; }
    let fv = block_func(bb);
    let nm = block_name_plus(bb, suffix);
    let nb = create_block_before(fv, bb, nm);
    let br = create_inst(OP_BR, T_VOID, [bb]);
    block_append_inst(nb, br);
    var l: i32 = -1;
    var old_latch: i32 = -1;
    var dl: i32 = -1;
    if use_li && li_is_loop_header(bb) {
        l = li_loop_for(bb);
        dl = loop_start_loc(l);
        old_latch = loop_latch(l);
    } else if fnp >= 0 {
        dl = inst_get_md(fnp, 0);
    }
    if dl >= 0 { inst_set_md(br, 0, dl); }
    for p in preds { term_replace_successor_with(block_terminator(p), bb, nb); }
    if preds.len == 0 {
        var i = block_first(bb);
        while i >= 0 && iop(i) == OP_PHI { phi_add_incoming(i, c_poison(vals[i].ty), nb); i = inst_next(i); }
    }
    let hle = update_analysis_information(bb, nb, preds, use_dt, use_li, preserve_lcssa);
    if preds.len > 0 { update_phi_nodes(bb, nb, preds, br, hle); }
    if old_latch >= 0 {
        let nl = loop_latch(l);
        if nl != old_latch {
            let md = inst_get_md(block_terminator(old_latch), MDK_LOOP);
            if md >= 0 { inst_set_md(block_terminator(nl), MDK_LOOP, md); } else { inst_erase_md(block_terminator(nl), MDK_LOOP); }
            let il = li_loop_for(old_latch);
            if il >= 0 && loop_latch(il) != old_latch { inst_erase_md(block_terminator(old_latch), MDK_LOOP); }
        }
    }
    return nb;
}

// SplitLandingPadPredecessorsImpl: returns NewBBs[0].
fn split_landing_pad_predecessors(orig: i32, preds: const i32[:], suffix1: const u8[:], suffix2: const u8[:], use_dt: bool, use_li: bool, preserve_lcssa: bool) -> i32 {
    let fv = block_func(orig);
    let nm1 = block_name_plus(orig, suffix1);
    let nb1 = create_block_before(fv, orig, nm1);
    let bi1 = create_inst(OP_BR, T_VOID, [orig]);
    block_append_inst(nb1, bi1);
    let dl = inst_get_md(first_non_phi(orig), 0);
    if dl >= 0 { inst_set_md(bi1, 0, dl); }
    for p in preds { term_replace_uses_of_with(block_terminator(p), orig, nb1); }
    var hle = update_analysis_information(orig, nb1, preds, use_dt, use_li, preserve_lcssa);
    update_phi_nodes(orig, nb1, preds, bi1, hle);
    var preds2: i32[>..<] = [];
    each_pred(orig) { p => if p != nb1 { preds2.push(p); } };
    var nb2: i32 = -1;
    if preds2.len > 0 {
        let nm2 = block_name_plus(orig, suffix2);
        nb2 = create_block_before(fv, orig, nm2);
        let bi2 = create_inst(OP_BR, T_VOID, [orig]);
        block_append_inst(nb2, bi2);
        if dl >= 0 { inst_set_md(bi2, 0, dl); }
        for p in preds2 { term_replace_uses_of_with(block_terminator(p), orig, nb2); }
        hle = update_analysis_information(orig, nb2, preds2, use_dt, use_li, preserve_lcssa);
        update_phi_nodes(orig, nb2, preds2, bi2, hle);
    }
    let lpad = first_non_phi(orig);
    let c1 = inst_clone(lpad);
    inst_insert_before_head(c1, first_non_phi(nb1));
    var n1: u8[>..] = [];
    n1.append("lpad");
    n1.append(suffix1);
    set_name(c1, n1);
    if nb2 >= 0 {
        let c2 = inst_clone(lpad);
        inst_insert_before_head(c2, first_non_phi(nb2));
        var n2: u8[>..] = [];
        n2.append("lpad");
        n2.append(suffix2);
        set_name(c2, n2);
        if vals[lpad].first_use >= 0 {
            let pn = new_phi(vals[lpad].ty, 2);
            inst_insert_before(pn, lpad);
            set_name(pn, "lpad.phi");
            phi_add_incoming(pn, c1, nb1);
            phi_add_incoming(pn, c2, nb2);
            rauw(lpad, pn);
        }
        inst_erase_from_parent(lpad);
    } else {
        rauw(lpad, c1);
        inst_erase_from_parent(lpad);
    }
    return nb1;
}

// User::replaceUsesOfWith on a terminator: every operand equal to old.
fn term_replace_uses_of_with(t: i32, old: i32, nw: i32) {
    for k in nops(t) { if op(t, k) == old { set_op(t, k, nw); } }
}

// ---------------------------------------------------------------------------------------------
// formDedicatedExitBlocks(L, DT, LI, MSSAU, PreserveLCSSA)

var fde_mark: i32[>..];
var fde_epoch: i32 = 0;

fn form_dedicated_exit_blocks(l: i32, preserve_lcssa: bool) -> bool {
    var changed = false;
    fde_epoch++;
    let my_epoch = fde_epoch;
    var inloop: i32[>..<] = [];
    fn rewrite_exit(bb: i32) -> bool {
        inloop.clear();
        var dedicated = true;
        var ibr = false;
        each_pred(bb) { p =>
            if !ibr {
                if loop_contains(l, p) {
                    if iop(block_terminator(p)) == OP_INDIRECTBR { ibr = true; } else { inloop.push(p); }
                } else { dedicated = false; }
            }
        };
        if ibr { return false; }
        if dedicated { return false; }
        split_block_predecessors(bb, inloop, ".loopexit", true, true, preserve_lcssa);
        return true;
    }
    for i in loop_nblocks(l) {
        let bb = loop_block(l, i);
        let tm = block_terminator(bb);
        if tm < 0 { continue; }
        var k: i64 = 0;
        while k < term_nsucc(tm) {
            let s = term_succ(tm, k);
            k++;
            if loop_contains(l, s) { continue; }
            let sk = block_of(s) as i64;
            while fde_mark.len <= sk { fde_mark.push(0); }
            if fde_mark[sk] == my_epoch { continue; }
            fde_mark[sk] = my_epoch;
            if rewrite_exit(s) { changed = true; }
        }
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// InsertPreheaderForLoop and placeSplitBlockCarefully

fn place_split_block_carefully(nb: i32, split_preds: const i32[:], l: i32) {
    let bbi = block_prev(nb);
    if position(split_preds, bbi) >= 0 { return; }
    var found: i32 = -1;
    for p in split_preds {
        let nx = block_next(p);
        if nx >= 0 && loop_contains(l, nx) { found = p; break; }
    }
    if found < 0 { found = split_preds[0]; }
    block_move_after(nb, found);
}

fn insert_preheader_for_loop(l: i32, preserve_lcssa: bool) -> i32 {
    let header = loop_header(l);
    var outside: i32[>..<] = [];
    var ibr = false;
    each_pred(header) { p =>
        if !ibr && !loop_contains(l, p) {
            if iop(block_terminator(p)) == OP_INDIRECTBR { ibr = true; } else { outside.push(p); }
        }
    };
    if ibr { return -1; }
    let ph = split_block_predecessors(header, outside, ".preheader", true, true, preserve_lcssa);
    if ph < 0 { return -1; }
    place_split_block_carefully(ph, outside, l);
    return ph;
}

// ---------------------------------------------------------------------------------------------
// separateNestedLoop

// findPHIToPartitionLoops
fn find_phi_to_partition_loops(l: i32) -> i32 {
    var i = block_first(loop_header(l));
    while i >= 0 && iop(i) == OP_PHI {
        let pn = i;
        i = inst_next(i);
        let v = simplify_phi(pn, true);
        if v >= 0 {
            rauw(pn, v);
            inst_erase_from_parent(pn);
            continue;
        }
        for k in phi_nincoming(pn) {
            if phi_value(pn, k) == pn && loop_contains(l, phi_block(pn, k)) { return pn; }
        }
    }
    return -1;
}

var abp_mark: i32[>..];
var abp_epoch: i32 = 0;
fn abp_has(b: i32) -> bool { let k = block_of(b) as i64; k < abp_mark.len && abp_mark[k] == abp_epoch }
// addBlockAndPredsToSet
fn add_block_and_preds_to_set(input: i32, stop: i32) {
    var wl: i32[>..<] = [];
    wl.push(input);
    while wl.len > 0 {
        let bb = wl.pop();
        let k = block_of(bb) as i64;
        while abp_mark.len <= k { abp_mark.push(0); }
        if abp_mark[k] != abp_epoch {
            abp_mark[k] = abp_epoch;
            if bb != stop { each_pred(bb) { p => wl.push(p); }; }
        }
    }
}

fn separate_nested_loop(l: i32, preheader: i32, preserve_lcssa: bool) -> i32 {
    if preheader < 0 { return -1; }
    for bi in loop_nblocks(l) {
        var i = block_first(loop_block(l, bi));
        while i >= 0 {
            if is_callbase(i) && call_has_fn_attr(i, AK_Convergent) { return -1; }
            i = inst_next(i);
        }
    }
    let header = loop_header(l);
    let fv = block_func(header);
    let pn = find_phi_to_partition_loops(l);
    if pn < 0 { return -1; }
    var outer_preds: i32[>..<] = [];
    for k in phi_nincoming(pn) {
        if phi_value(pn, k) != pn || !loop_contains(l, phi_block(pn, k)) {
            if iop(block_terminator(phi_block(pn, k))) == OP_INDIRECTBR { return -1; }
            outer_preds.push(phi_block(pn, k));
        }
    }
    let nb = split_block_predecessors(header, outer_preds, ".outer", true, true, preserve_lcssa);
    place_split_block_carefully(nb, outer_preds, l);
    let no = li_allocate_loop(fv);
    let par = loop_parent(l);
    if par >= 0 { loop_replace_child_with(par, l, no); } else { li_change_top_level_loop(fv, l, no); }
    loop_add_child(no, l);
    for i in loop_nblocks(l) { loop_add_block_entry(no, loop_block(l, i)); }
    loop_move_to_header(l, header);
    abp_epoch++;
    each_pred(header) { p => if dt_dominates_block(DT_DOM, header, p) { add_block_and_preds_to_set(p, header); } };
    var si: i64 = 0;
    while si < loop_nsubs(l) {
        let sl = loop_sub(l, si);
        if abp_has(loop_header(sl)) { si++; }
        else { loop_remove_child(l, sl); loop_add_child(no, sl); }
    }
    var i: i64 = 0;
    while i < loop_nblocks(l) {
        let bb = loop_block(l, i);
        if !abp_has(bb) {
            loop_remove_block_from_loop(l, bb);
            if li_loop_for(bb) == l { li_change_loop_for(bb, no); }
        } else { i++; }
    }
    form_dedicated_exit_blocks(l, preserve_lcssa);
    if preserve_lcssa { fatal("LoopSimplify: separateNestedLoop with PreserveLCSSA (formLCSSA) is not ported yet"); }
    return no;
}

// ---------------------------------------------------------------------------------------------
// insertUniqueBackedgeBlock

fn insert_unique_backedge_block(l: i32, preheader: i32) -> i32 {
    let header = loop_header(l);
    let fv = block_func(header);
    if preheader < 0 { return -1; }
    var be_blocks: i32[>..<] = [];
    var ibr = false;
    each_pred(header) { p =>
        if !ibr {
            if iop(block_terminator(p)) == OP_INDIRECTBR { ibr = true; }
            else if p != preheader { be_blocks.push(p); }
        }
    };
    if ibr { return -1; }
    let nm = block_name_plus(header, ".backedge");
    let be = create_block_after(fv, -1, nm);
    let bt = create_inst(OP_BR, T_VOID, [header]);
    block_append_inst(be, bt);
    let dl = inst_get_md(first_non_phi(header), 0);
    if dl >= 0 { inst_set_md(bt, 0, dl); }
    block_move_before(be, block_next(be_blocks[be_blocks.len - 1]));
    var i = block_first(header);
    while i >= 0 && iop(i) == OP_PHI {
        let pn = i;
        i = inst_next(i);
        let np = new_phi(vals[pn].ty, be_blocks.len);
        inst_insert_before(np, bt);
        let pnm = block_name_plus(pn, ".be");
        set_name(np, pnm);
        var ph_idx: i64 = -1;
        var unique = true;
        var uval: i32 = -1;
        for k in phi_nincoming(pn) {
            let ibb = phi_block(pn, k);
            let iv = phi_value(pn, k);
            if ibb == preheader { ph_idx = k; }
            else {
                phi_add_incoming(np, iv, ibb);
                if unique {
                    if uval < 0 { uval = iv; } else if uval != iv { unique = false; }
                }
            }
        }
        if ph_idx < 0 { fatal("internal: PHI has no preheader entry"); }
        if ph_idx != 0 {
            set_op(pn, 0, phi_value(pn, ph_idx));
            phi_set_block(pn, 0, phi_block(pn, ph_idx));
        }
        var k = phi_nincoming(pn);
        while k > 1 { k--; phi_remove_incoming(pn, k); }
        phi_add_incoming(pn, np, be);
        if unique {
            rauw(np, uval);
            inst_erase_from_parent(np);
        }
    }
    var loop_md: i32 = -1;
    for b in be_blocks {
        let ti = block_terminator(b);
        if loop_md < 0 { loop_md = inst_get_md(ti, MDK_LOOP); }
        inst_erase_md(ti, MDK_LOOP);
        term_replace_successor_with(ti, header, be);
    }
    if loop_md >= 0 { inst_set_md(bt, MDK_LOOP, loop_md); }
    loop_add_basic_block_to_loop(l, be);
    dt_split_block(fv, DT_DOM, be);
    if ls_mssau { msu_update_phis_unique_backedge(header, preheader, be); }
    return be;
}

// ---------------------------------------------------------------------------------------------
// changeToUnreachable(I, PreserveLCSSA, DTU = null, MSSAU = null)
fn change_to_unreachable(iv: i32, preserve_lcssa: bool) {
    if ls_mssau { msu_change_to_unreachable(iv); }
    let bb = inst_parent(iv);
    let tm = block_terminator(bb);
    if tm >= 0 {
        var k: i64 = 0;
        while k < term_nsucc(tm) { block_remove_predecessor(term_succ(tm, k), bb, preserve_lcssa); k++; }
    }
    let ui = create_inst(OP_UNREACHABLE, T_VOID, []);
    inst_insert_before(ui, iv);
    let dl = inst_get_md(iv, 0);
    if dl >= 0 { inst_set_md(ui, 0, dl); }
    var i = iv;
    while i >= 0 {
        let ni = inst_next(i);
        if vals[i].first_use >= 0 { rauw(i, c_poison(vals[i].ty)); }
        inst_erase_from_parent(i);
        i = ni;
    }
}

// ---------------------------------------------------------------------------------------------
// Loop::makeLoopInvariant

// isSafeToSpeculativelyExecute (ValueTracking.cpp), for what makeLoopInvariant can hoist: loads always fail
// makeLoopInvariant (mayReadFromMemory), so their dereferenceability is not needed.
fn safe_to_speculate(iv: i32) -> bool {
    let o = iop(iv);
    if o == OP_UDIV || o == OP_UREM {
        let d = op(iv, 1);
        if vals[d].kind == VK_CINT { return !cint_is_zero(d); }
        if is_constant(d) { fatal("isSafeToSpeculativelyExecute: vector divisors are not ported"); }
        return false;
    }
    if o == OP_SDIV || o == OP_SREM {
        let d = op(iv, 1);
        if vals[d].kind != VK_CINT {
            if is_constant(d) { fatal("isSafeToSpeculativelyExecute: vector divisors are not ported"); }
            return false;
        }
        if cint_is_zero(d) { return false; }
        if cint_sext(d) != -1 { return true; }
        let n = op(iv, 0);
        if vals[n].kind == VK_CINT {
            let bits = ty_bits(vals[n].ty);
            if bits > 64 { fatal("isSafeToSpeculativelyExecute: wide sdiv numerators are not ported"); }
            let minv: i64 = if bits == 64 { -9223372036854775807 - 1 } else { -((1 as i64) << (bits - 1)) };
            return cint_sext(n) != minv;
        }
        return false;
    }
    if o == OP_LOAD { return false; }
    if o == OP_CALL {
        let cf = called_function(iv);
        // Loop::makeLoopInvariant passes IgnoreUBImplyingAttrs = true
        return cf >= 0 && func_has_fn_attr(cf, AK_Speculatable);
    }
    if o == OP_VAARG || o == OP_ALLOCA || o == OP_INVOKE || o == OP_CALLBR || o == OP_PHI || o == OP_STORE ||
       is_terminator_op(o) || o == OP_FENCE || o == OP_ATOMICRMW || o == OP_CMPXCHG || o == OP_LANDINGPAD ||
       o == OP_CATCHPAD || o == OP_CLEANUPPAD { return false; }
    return true;
}

// Instruction::dropUBImplyingAttrsAndUnknownMetadata(Keep): keep !dbg and the kinds in keep.
fn drop_unknown_metadata(iv: i32, keep_prof: bool) {
    let ii = inst_of(iv);
    let at = insts[ii].md;
    var w: i32 = 0;
    for k in insts[ii].nmd {
        let kind = md_att[at + 2 * k];
        if kind == 0 || (keep_prof && kind == 2) {
            md_att[at + 2 * w] = kind;
            md_att[at + 2 * w + 1] = md_att[at + 2 * k + 1];
            w++;
        }
    }
    insts[ii].nmd = w;
    if !is_callbase(iv) { return; }
    // remove AttributeFuncs::getUBImplyingAttributes() from the return and every parameter
    let al = insts[ii].attrs;
    if al == 0 { return; }
    let kinds: i64[3] = [AK_NoUndef, AK_Dereferenceable, AK_DereferenceableOrNull];
    var sets: i32[>..<] = [];
    let n = alists[al].n as i64;
    for k in n {
        let st = alist_runs[alists[al].at + k];
        sets.push(if k == 0 { st } else { aset_without(st, kinds) });
    }
    insts[ii].attrs = alist_get(sets);
}

recursive fn make_loop_invariant(l: i32, v: i32, ins_pt: i32, changed: bool&) -> bool {
    if !is_inst(v) { return true; }
    let orig = inst_parent(v);
    if !loop_contains(l, orig) { return true; }
    if !safe_to_speculate(v) { return false; }
    if inst_may_read_memory(v) { return false; }
    if inst_is_eh_pad(v) { return false; }
    var ip = ins_pt;
    if ip < 0 {
        let ph = loop_preheader(l);
        if ph < 0 { return false; }
        ip = block_terminator(ph);
    }
    for k in nops(v) { if !make_loop_invariant(l, op(v, k), ip, changed) { return false; } }
    inst_move_before(v, ip);
    if ls_mssau {
        let mud = mssa_access_of(v);
        if mud >= 0 { msu_move_to_place(mud, inst_parent(ip), MSP_BEFORE_TERMINATOR); }
    }
    drop_unknown_metadata(v, orig == loop_header(l));
    // setExplicitlyUnknownBranchWeightsIfProfiled(*I, "LoopInfo") when no !prof was kept
    if iop(v) == OP_SELECT && orig != loop_header(l) && ls_fn_entry_count(inst_func(v)) > 0 {
        let ops: i32[2] = [md_string("unknown"), md_string("LoopInfo")];
        inst_set_md(v, md_kind_id("prof"), md_get(MK_TUPLE, -1, ops, false));
    }
    changed = true;
    return true;
}

// Function::getEntryCount()->getCount() (0 when absent)
fn ls_fn_entry_count(fv: i32) -> u64 {
    let g = glob_of(fv);
    let k = md_kind_id("prof");
    for j in globs[g].nmd {
        if md_att[globs[g].md + 2 * j] != k { continue; }
        let m = md_att[globs[g].md + 2 * j + 1];
        if mds[m].nops < 2 { return 0; }
        let s = md_op(m, 0);
        if s < 0 || mds[s].kind != MK_STRING { return 0; }
        let nm = sbytes(mds[s].extra);
        if nm != "function_entry_count" { return 0; }
        let o = md_op(m, 1);
        if o < 0 || mds[o].kind != MK_VALUE { return 0; }
        let c = mds[o].extra;
        if vals[c].kind != VK_CINT { return 0; }
        let n = ap_zext64(ci_ap(c));
        if n == 0xFFFFFFFFFFFFFFFF { return 0; }
        return n;
    }
    return 0;
}
