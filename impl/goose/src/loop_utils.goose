// Loop utilities shared by the loop passes (LoopDeletion, LoopSimplifyCFG, LoopIdiom, ...).
// Ports from llvm/lib/Transforms/Utils/LoopUtils.cpp: deleteDeadLoop, breakLoopBackedge, getBooleanLoopAttribute
// (+ hasMustProgress); llvm/lib/Analysis/LoopInfo.cpp: LoopInfo::erase and UnloopUpdater;
// llvm/include/llvm/Analysis/LoopIterator.h: LoopBlocksDFS / LoopBlocksRPO / LoopBlocksTraversal;
// llvm/include/llvm/Analysis/CFG.h: containsIrreducibleCFG; llvm/lib/Transforms/Utils/BasicBlockUtils.cpp:
// SplitBlock (DT, LI, MSSAU), SplitEdge; llvm/lib/Transforms/Utils/Local.cpp: changeToUnreachable (PreserveLCSSA,
// eager DTU, MSSAU), RecursivelyDeleteTriviallyDeadInstructions(Permissive) with MSSAU.
import std;
import ir;
import irutil;
import instinfo;
import analyses;
import flags;
import domtree;
import loopinfo;
import memoryssa;
import mssaupdater;
import dinfo;
import dbgutil;
import lcssa;
import breakcrit;
import cfgutil;
import local;
import salvage;
import scev;
import scev_eval;
import scev_update;

fn lu_not_ported(what: const u8[:]) { fatal(str("loop utilities: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// LoopBlocksDFS::perform: post-order of the loop's blocks from the header, visiting a successor only if
// L->contains(LI->getLoopFor(Succ)) and it was not visited yet.

var lu_vis: i32[>..];
var lu_vis_epoch: i32 = 0;
fn lu_vis_begin() { lu_vis_epoch++; }
fn lu_vis_add(b: i32) -> bool {
    let k = block_of(b) as i64;
    while lu_vis.len <= k { lu_vis.push(0); }
    if lu_vis[k] == lu_vis_epoch { return false; }
    lu_vis[k] = lu_vis_epoch;
    return true;
}
fn lu_vis_has(b: i32) -> bool { let k = block_of(b) as i64; k < lu_vis.len && lu_vis[k] == lu_vis_epoch }

fn lu_loop_postorder(l: i32, post: i32[>..<]&) {
    post.clear();
    var st_b: i32[>..<] = [];
    var st_k: i64[>..<] = [];
    lu_vis_begin();
    let h = loop_header(l);
    lu_vis_add(h);
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
            if sl >= 0 && loop_contains_loop(l, sl) && lu_vis_add(s) { st_b.push(s); st_k.push(0); }
        } else {
            post.push(b);
            st_b.pop();
            st_k.pop();
        }
    }
}
// LoopBlocksRPO
fn lu_loop_rpo(l: i32, out: i32[>..<]&) {
    var post: i32[>..<] = [];
    lu_loop_postorder(l, post);
    out.clear();
    var i = post.len - 1;
    while i >= 0 { out.push(post[i]); i--; }
}

// containsIrreducibleCFG(RPOTraversal, LI)
fn lu_contains_irreducible(rpo: const i32[:]) -> bool {
    lu_vis_begin();
    for node in rpo {
        lu_vis_add(node);
        for k in block_nsucc(node) {
            let s = block_succ(node, k);
            if !lu_vis_has(s) { continue; }
            var proper = false;
            var lp = li_loop_for(node);
            while lp >= 0 { if loop_header(lp) == s { proper = true; break; } lp = loop_parent(lp); }
            if !proper { return true; }
        }
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// Loop metadata

// getBooleanLoopAttribute(L, Name)
fn lu_boolean_loop_attr(l: i32, name: const u8[:]) -> bool {
    let md = find_option_md_for_loop_id(loop_id(l), name);
    if md < 0 { return false; }
    if mds[md].nops == 1 { return true; }
    let o = md_op(md, 1);
    if o < 0 || mds[o].kind != MK_VALUE { return false; }
    let c = mds[o].extra;
    if vals[c].kind != VK_CINT { return false; }
    return !is_null_value(c);
}
// hasMustProgress(L)
fn lu_has_must_progress(l: i32) -> bool { lu_boolean_loop_attr(l, "llvm.loop.mustprogress") }

// getUniqueExitBlock: the one exit block (repeats allowed), or -1 when there are none or several.
fn lu_unique_exit_block(l: i32) -> i32 {
    var r: i32 = -1;
    for i in loop_nblocks(l) {
        let bb = loop_block(l, i);
        for k in block_nsucc(bb) {
            let s = block_succ(bb, k);
            if loop_contains(l, s) { continue; }
            if r < 0 { r = s; } else if r != s { return -1; }
        }
    }
    return r;
}
// hasNoExitBlocks
fn lu_has_no_exit_blocks(l: i32) -> bool {
    for i in loop_nblocks(l) {
        let bb = loop_block(l, i);
        for k in block_nsucc(bb) { if !loop_contains(l, block_succ(bb, k)) { return false; } }
    }
    return true;
}

// IRBuilder(I) / SetInsertPoint(I): the builder's debug location is I's (getStableDebugLoc)
fn lu_copy_dbg_loc(nw: i32, at: i32) {
    let dl = inst_get_md(at, 0);
    if dl >= 0 { inst_set_md(nw, 0, dl); }
}

// BasicBlock::getFirstInsertionPt (-1 = end())
fn lu_first_insertion_pt(bb: i32) -> i32 {
    let i = first_non_phi(bb);
    if i < 0 { return -1; }
    if inst_is_eh_pad(i) { return inst_next(i); }
    return i;
}

// ---------------------------------------------------------------------------------------------
// LoopInfo::erase(Unloop) with UnloopUpdater

var lu_sp_key: i32[>..<];     // SubloopParents (Unloop's immediate subloops -> nearest reachable parent)
var lu_sp_val: i32[>..<];
var lu_found_ib: bool = false;

fn lu_sp_find(k: i32) -> i64 { for j in lu_sp_key.len { if lu_sp_key[j] == k { return j; } } return -1; }
// SubloopParents.insert({k, v}).first->second
fn lu_sp_insert(k: i32, v: i32) -> i32 {
    let j = lu_sp_find(k);
    if j >= 0 { return lu_sp_val[j]; }
    lu_sp_key.push(k);
    lu_sp_val.push(v);
    return v;
}
fn lu_sp_set(k: i32, v: i32) { let j = lu_sp_find(k); if j >= 0 { lu_sp_val[j] = v; } else { lu_sp_key.push(k); lu_sp_val.push(v); } }
// SubloopParents[k] (default-inserting nullptr)
fn lu_sp_get(k: i32) -> i32 { let j = lu_sp_find(k); if j >= 0 { return lu_sp_val[j]; } lu_sp_key.push(k); lu_sp_val.push(-1); return -1; }

// UnloopUpdater::getNearestLoop
fn lu_get_nearest_loop(unloop: i32, bb: i32, bbloop: i32) -> i32 {
    var near = bbloop;
    var sub: i32 = -1;
    if near != unloop && loop_contains_loop(unloop, near) {
        sub = near;
        while loop_parent(sub) != unloop { sub = loop_parent(sub); }
        near = lu_sp_insert(sub, unloop);
    }
    if block_nsucc(bb) == 0 { near = -1; }
    for k in block_nsucc(bb) {
        let s = block_succ(bb, k);
        if s == bb { continue; }
        var l = li_loop_for(s);
        if l == unloop { lu_found_ib = true; }
        if l != unloop && loop_contains_loop(unloop, l) {
            if sub >= 0 { continue; }
            l = lu_sp_get(l);
        }
        if l == unloop { continue; }
        if l >= 0 && !loop_contains_loop(l, unloop) { l = loop_parent(l); }
        if near == unloop || near < 0 || loop_contains_loop(near, l) { near = l; }
    }
    if sub >= 0 { lu_sp_set(sub, near); return bbloop; }
    return near;
}

// LoopInfo::erase(Unloop). The loop id stays allocated (destroy).
fn lu_li_erase(fv: i32, unloop: i32) {
    if loop_is_outermost(unloop) {
        for i in loop_nblocks(unloop) {
            let bb = loop_block(unloop, i);
            if li_loop_for(bb) != unloop { continue; }
            li_change_loop_for(bb, -1);
        }
        lu_remove_top_level_loop(fv, unloop);
        while !loop_is_innermost(unloop) {
            let c = loop_sub(unloop, loop_nsubs(unloop) - 1);
            loop_remove_child(unloop, c);
            li_add_top_level_loop(fv, c);
        }
        return;
    }
    lu_sp_key.clear();
    lu_sp_val.clear();
    lu_found_ib = false;
    // updateBlockParents
    var post: i32[>..<] = [];
    if loop_nblocks(unloop) > 0 {
        lu_loop_postorder(unloop, post);
        for b in post {
            let l = li_loop_for(b);
            let nl = lu_get_nearest_loop(unloop, b, l);
            if nl != l { li_change_loop_for(b, nl); }
        }
    }
    var changed = lu_found_ib;
    while changed {
        changed = false;
        for b in post {
            let l = li_loop_for(b);
            let nl = lu_get_nearest_loop(unloop, b, l);
            if nl != l { li_change_loop_for(b, nl); changed = true; }
        }
    }
    // removeBlocksFromAncestors
    var blocks: i32[>..<] = [];
    for i in loop_nblocks(unloop) { blocks.push(loop_block(unloop, i)); }
    for bb in blocks {
        var outer = li_loop_for(bb);
        if loop_contains_loop(unloop, outer) {
            while loop_parent(outer) != unloop { outer = loop_parent(outer); }
            outer = lu_sp_get(outer);
        }
        var old = loop_parent(unloop);
        while old != outer {
            if old < 0 { fatal("internal: LoopInfo::erase: new loop is not an ancestor of the original"); }
            loop_remove_block_from_loop(old, bb);
            old = loop_parent(old);
        }
    }
    // updateSubloopParents
    while !loop_is_innermost(unloop) {
        let sub = loop_sub(unloop, loop_nsubs(unloop) - 1);
        loop_remove_child(unloop, sub);
        let p = lu_sp_get(sub);
        if p >= 0 { loop_add_child(p, sub); } else { li_add_top_level_loop(fv, sub); }
    }
    loop_remove_child(loop_parent(unloop), unloop);
}

// LoopInfo::removeLoop(find(*LI, L))
fn lu_remove_top_level_loop(fv: i32, l: i32) {
    let g = glob_of(fv);
    let r = li_heads[g].top;
    var w: i64 = 0;
    for k in r.n { let x = lrun_get(r, k); if x != l { li_pool[r.at + w] = x; w++; } }
    li_heads[g].top.n = w as i32;
}

// ---------------------------------------------------------------------------------------------
// CFG helpers with DT / LI / MSSAU

// SplitBlock(Old, SplitPt, DT, LI, MSSAU, BBName = "", Before = false)
fn lu_split_block(old: i32, at0: i32, use_mssau: bool) -> i32 {
    var at = at0;
    while iop(at) == OP_PHI || inst_is_eh_pad(at) { at = inst_next(at); }
    var nm: u8[>..] = [];
    nm.append(val_name(old));
    nm.append(".split");
    let nb = split_block(old, at, nm);
    let l = li_loop_for(old);
    if l >= 0 { loop_add_basic_block_to_loop(l, nb); }
    let fv = block_func(old);
    if dt_has_node(DT_DOM, old) {
        var children: i32[>..<] = [];
        var c = dt_first_child(fv, DT_DOM, old);
        while c >= 0 { children.push(c); c = dt_next_sibling(DT_DOM, c); }
        dt_add_new_block(fv, DT_DOM, nb, old);
        for ch in children { dt_change_idom(fv, DT_DOM, ch, nb); }
    }
    if use_mssau { msu_move_all_after_splice_blocks(old, nb, block_first(nb)); }
    return nb;
}

// SplitEdge(BB, Succ, DT, LI, MSSAU)
fn lu_split_edge(bb: i32, succ: i32, use_mssau: bool) -> i32 {
    let t = block_terminator(bb);
    var k: i64 = 0;
    while term_succ(t, k) != succ { k++; }
    var o = ces_opts(true, true, false);
    o.preserve_lcssa = true;
    o.mssau = use_mssau;
    if is_critical_edge(t, k, o.merge_identical) {
        let nb = split_known_critical_edge(t, k, o, "");
        if nb < 0 { lu_not_ported("SplitEdge of an edge SplitKnownCriticalEdge refuses"); }
        return nb;
    }
    if single_pred(succ) >= 0 { lu_not_ported("SplitEdge by splitting the top of the successor (SplitBlock Before)"); }
    return lu_split_block(bb, t, use_mssau);
}

// changeToUnreachable(I, PreserveLCSSA, DTU (eager, DT), MSSAU)
fn lu_change_to_unreachable(iv: i32, preserve_lcssa: bool, use_dt: bool, use_mssau: bool) -> i64 {
    let bb = inst_parent(iv);
    if use_mssau { msu_change_to_unreachable(iv); }
    var uniq: i32[>..<] = [];
    var succs: i32[>..<] = [];
    cu_succs(bb, succs);
    for s in succs {
        block_remove_predecessor(s, bb, preserve_lcssa);
        if use_dt { cu_push_unique(uniq, s); }
    }
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
    if use_dt {
        var ups: DTUpdate[>..<] = [];
        for s in uniq { ups.push(DTUpdate { kind: DT_DELETE, from: bb, to: s }); }
        dt_apply_updates(block_func(bb), DT_DOM, ups);
    }
    return n;
}

// RecursivelyDeleteTriviallyDeadInstructions(DeadInsts, TLI, MSSAU): entries are WeakTrackingVHs (deleted ones
// skipped); only trivially dead entries are processed (the Permissive variant's filter; LLVM's plain variant
// asserts it).
fn lu_recursively_delete_dead(dead: i32[>..<]&, use_mssau: bool) {
    var wl: i32[>..<] = [];
    for d in dead {
        if d < 0 || is_dead(d) { continue; }
        if is_instruction_trivially_dead(d) { wl.push(d); }
    }
    while wl.len > 0 {
        let i = wl.pop();
        if is_dead(i) { continue; }
        salvage_debug_info(i);
        for k in nops(i) {
            let opv = op(i, k);
            set_op(i, k, -1);
            if opv < 0 || !has_use_list(opv) || vals[opv].first_use >= 0 { continue; }
            if is_inst(opv) && is_instruction_trivially_dead(opv) { wl.push(opv); }
        }
        if use_mssau { msu_remove_inst_access(i, false); }
        inst_erase_from_parent(i);
    }
}

// ---------------------------------------------------------------------------------------------
// deleteDeadLoop(L, DT, SE, LI, MSSA)

struct LuDVKey { dvar: i32, has_frag: bool, fo: i64, fs: i64, dl: i32 }

fn lu_delete_dead_loop(l: i32, use_se: bool, use_mssa: bool) {
    let preheader = loop_preheader(l);
    if preheader < 0 { fatal("internal: deleteDeadLoop: preheader should exist"); }
    let fv = block_func(preheader);
    if use_se {
        sc_forget_loop(l);
        sc_forget_block_and_loop_dispositions_all();
    }
    let old_term = block_terminator(preheader);
    let header = loop_header(l);
    let exit = lu_unique_exit_block(l);
    if exit >= 0 {
        let cbr = create_inst(OP_CONDBR, T_VOID, [c_false(), header, exit]);
        lu_copy_dbg_loc(cbr, old_term);
        inst_insert_before(cbr, old_term);
        inst_erase_from_parent(old_term);
        var p = block_first(exit);
        while p >= 0 && iop(p) == OP_PHI {
            phi_set_block(p, 0, preheader);
            while nops(p) > 1 { phi_remove_incoming(p, nops(p) - 1); }
            p = inst_next(p);
        }
        let up: DTUpdate[1] = [DTUpdate { kind: DT_INSERT, from: preheader, to: exit }];
        dt_apply_updates(fv, DT_DOM, up);
        if use_mssa {
            msu_apply_updates(fv, up, false);
            if flag_bool("verify-memoryssa", false) { mssa_verify(fv); }
        }
        let t2 = block_terminator(preheader);
        let br = create_inst(OP_BR, T_VOID, [exit]);
        lu_copy_dbg_loc(br, t2);
        inst_insert_before(br, t2);
        inst_erase_from_parent(t2);
    } else {
        let ui = create_inst(OP_UNREACHABLE, T_VOID, []);
        lu_copy_dbg_loc(ui, old_term);
        inst_insert_before(ui, old_term);
        inst_erase_from_parent(block_terminator(preheader));
    }
    {
        let up: DTUpdate[1] = [DTUpdate { kind: DT_DELETE, from: preheader, to: header }];
        dt_apply_updates(fv, DT_DOM, up);
        if use_mssa {
            msu_apply_updates(fv, up, false);
            var dead: i32[>..<] = [];
            for i in loop_nblocks(l) { cu_push_unique(dead, loop_block(l, i)); }
            msu_remove_blocks(dead);
            if flag_bool("verify-memoryssa", false) { mssa_verify(fv); }
        }
    }
    // Uses outside the loop (only in unreachable code) become poison; one debug record per DebugVariable moves
    // to the exit block.
    var keys: LuDVKey[>..<] = [];
    var moved: i32[>..<] = [];
    var blocks: i32[>..<] = [];
    for i in loop_nblocks(l) { blocks.push(loop_block(l, i)); }
    for bb in blocks {
        var i = block_first(bb);
        while i >= 0 {
            var u = vals[i].first_use;
            while u >= 0 {
                let nx = uses[u].next;
                let us = uses[u].user;
                var inside = false;
                if is_inst(us) { inside = loop_contains(l, inst_parent(us)); }
                if !inside { use_set(u, c_poison(vals[i].ty)); }
                u = nx;
            }
            if exit >= 0 {
                var r = inst_first_dbg(i);
                while r >= 0 {
                    let nr = dbgrecs[r].next;
                    if dbgrecs[r].kind as i64 != DR_LABEL {
                        let hf, fo, fs = du_fragment(dbgrecs[r].expr);
                        let k = LuDVKey { dvar: dbgrecs[r].dvar, has_frag: hf, fo: fo, fs: fs, dl: dbgrecs[r].dl };
                        var seen = false;
                        for x in keys {
                            if x.dvar == k.dvar && x.has_frag == k.has_frag && (!k.has_frag || (x.fo == k.fo && x.fs == k.fs)) && x.dl == k.dl { seen = true; break; }
                        }
                        if !seen {
                            keys.push(k);
                            dbg_erase_record(r);
                            moved.push(r);
                        }
                    }
                    r = nr;
                }
            }
            i = inst_next(i);
        }
    }
    if exit >= 0 && moved.len > 0 {
        let pt = lu_first_insertion_pt(exit);
        if pt < 0 { fatal("internal: deleteDeadLoop: no non-PHI instruction in the exit block"); }
        // inserted one at a time at the head of the marker, in reverse: the original order in front
        for k in moved.len - 1 { dbgrecs[moved[k]].next = moved[k + 1]; }
        dbgrecs[moved[moved.len - 1]].next = -1;
        marker_absorb(exit, pt, moved[0], true);
    }
    for bb in blocks { var i = block_first(bb); while i >= 0 { drop_all_refs(i); i = inst_next(i); } }
    if use_mssa && flag_bool("verify-memoryssa", false) { mssa_verify(fv); }
    for bb in blocks {
        li_remove_block(bb);
        lu_erase_dead_block(bb);
    }
    let parent = loop_parent(l);
    if parent >= 0 { loop_remove_child(parent, l); } else { lu_remove_top_level_loop(fv, l); }
}

// BasicBlock::eraseFromParent of a block whose instructions have dropped all references: the debug records go
// with the block; a blockaddress of it becomes inttoptr (i32 1 to ptr).
fn lu_erase_dead_block(bb: i32) {
    var i = block_first(bb);
    while i >= 0 {
        var r = inst_first_dbg(i);
        while r >= 0 { let nr = dbgrecs[r].next; dbg_delete_record(r); r = nr; }
        i = inst_next(i);
    }
    if block_has_trailing(bb) {
        var r = block_trail[block_of(bb)];
        while r >= 0 { let nr = dbgrecs[r].next; dbg_delete_record(r); r = nr; }
    }
    cu_drop_block_address(bb);
    block_erase(bb);
}

// ---------------------------------------------------------------------------------------------
// breakLoopBackedge(L, DT, SE, LI, MSSA)

fn lu_break_loop_backedge(l: i32, use_mssa: bool) {
    let latch = loop_latch(l);
    let header = loop_header(l);
    let fv = block_func(header);
    let outermost = loop_outermost(l);
    sc_forget_loop(l);
    sc_forget_block_and_loop_dispositions_all();
    let bi = block_terminator(latch);
    var done = false;
    if iop(bi) == OP_BR {
        lu_change_to_unreachable(bi, true, true, use_mssa);
        done = true;
    } else if iop(bi) == OP_CONDBR && loop_is_exiting(l, latch) {
        let exit_idx: i64 = if loop_contains(l, term_succ(bi, 0)) { 1 } else { 0 };
        let exit_bb = term_succ(bi, exit_idx);
        block_remove_predecessor(header, latch, true);
        let nbi = create_inst(OP_BR, T_VOID, [exit_bb]);
        inst_insert_before(nbi, bi);
        let dl = inst_get_md(bi, 0);
        if dl >= 0 { inst_set_md(nbi, 0, dl); }
        let an = inst_get_md(bi, mdk_annotation());
        if an >= 0 { inst_set_md(nbi, mdk_annotation(), an); }
        inst_erase_from_parent(bi);
        let up: DTUpdate[1] = [DTUpdate { kind: DT_DELETE, from: latch, to: header }];
        dt_apply_updates(fv, DT_DOM, up);
        if use_mssa { msu_apply_updates(fv, up, false); }
        done = true;
    }
    if !done {
        let be = lu_split_edge(latch, header, use_mssa);
        lu_change_to_unreachable(block_terminator(be), true, true, use_mssa);
    }
    lu_li_erase(fv, l);
    if outermost != l {
        let save = lcssa_se;
        lcssa_se = true;
        form_lcssa_recursively(outermost);
        lcssa_se = save;
    }
}
