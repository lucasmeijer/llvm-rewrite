// SimpleLoopUnswitch, non-trivial unswitching: cloning and loop rebuilding. Port of
// llvm/lib/Transforms/Scalar/SimpleLoopUnswitch.cpp (buildClonedLoopBlocks, cloneLoopNest, buildClonedLoops,
// deleteDeadClonedBlocks, deleteDeadBlocksFromLoop, recomputeLoopBlockSet, rebuildLoopAfterUnswitch).
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_iids;
import local;
import instsimplify;
import assume;
import domtree;
import loopinfo;
import loopsimplify;
import cfgutil;
import memoryssa;
import mssaupdater;
import scev;
import scev_update;
import lpm;
import stdsort;
import value_mapper;
import clone_function;
import unroll_utils;
import loop_utils;
import simple_loop_unswitch;

// LoopInfo::getLoopDepth(BB)
fn slu_li_depth(b: i32) -> i64 { let l = li_loop_for(b); return if l < 0 { 0 } else { loop_depth(l) }; }

// replace a loop's block vector by `keep` (a subset, in order)
fn slu_loop_set_blocks(l: i32, keep: const i32[:]) {
    let r = loops[l].blocks;
    for k in keep.len { li_pool[r.at + k] = keep[k]; }
    loops[l].blocks.n = keep.len as i32;
}
fn slu_loop_set_subs(l: i32, keep: const i32[:]) {
    let r = loops[l].subs;
    for k in keep.len { li_pool[r.at + k] = keep[k]; }
    loops[l].subs.n = keep.len as i32;
}
fn slu_loop_blocks(l: i32, out: i32[>..<]&) { for k in loop_nblocks(l) { out.push(loop_block(l, k)); } }

// buildClonedLoopBlocks(L, LoopPH, SplitBB, ExitBlocks, ParentBB, UnswitchedSuccBB, ContinueSuccBB,
// DominatingSucc (ds_k -> ds_v), VMap, DTUpdates, AC, DT, LI, MSSAU, SE)
fn build_cloned_loop_blocks(l: i32, loop_ph: i32, exits: const i32[:], parent_bb: i32, unswitched_succ: i32,
                            ds_k: i32[>..<]&, ds_v: i32[>..<]&, vm: i32, dt_ups: DTUpdate[>..<]&) -> i32 {
    let fv = block_func(loop_ph);
    var new_blocks: i32[>..<] = [];
    fn clone_block(ob: i32) -> i32 {
        let nb = clone_basic_block(ob, vm, ".us", fv, false);
        block_move_before(nb, loop_ph);
        new_blocks.push(nb);
        vmm_set(vm, ob, nb);
        return nb;
    }
    fn skip_block(b: i32) -> bool {
        let j = position(ds_k, b);
        return j >= 0 && ds_v[j] != unswitched_succ;
    }
    let cph = clone_block(loop_ph);
    for k in loop_nblocks(l) {
        let lb = loop_block(l, k);
        if !skip_block(lb) { clone_block(lb); }
    }
    for eb in exits {
        if skip_block(eb) { continue; }
        let mb = slu_split_block(eb, block_first(eb));
        cu_take_name(mb, eb);
        var nm: u8[>..] = [];
        nm.append(val_name(mb));
        nm.append(".split");
        set_name(eb, nm);
        let ceb = clone_block(eb);
        var i = block_first(eb);
        var ci = block_first(ceb);
        while i >= 0 && i != block_terminator(eb) && ci >= 0 && ci != block_terminator(ceb) {
            let ni = inst_next(i);
            let nci = inst_next(ci);
            if slu_se && iop(i) == OP_PHI { sc_forget_lcssa_phi_with_new_predecessor(l, i); }
            let ip = first_insertion_pt(mb);
            let mpn = new_phi(vals[i].ty, 2);
            inst_insert_before_head(mpn, ip);
            set_name(mpn, ".us-phi");
            let dl = inst_get_md(ip, 0);
            if dl >= 0 { inst_set_md(mpn, 0, dl); }
            ac_rauw(i, mpn);
            rauw(i, mpn);
            phi_add_incoming(mpn, i, eb);
            phi_add_incoming(mpn, ci, ceb);
            i = ni;
            ci = nci;
        }
    }
    for cb in new_blocks {
        var i = block_first(cb);
        while i >= 0 {
            remap_dbg_record_range(i, vm, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
            remap_instruction(i, vm, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
            if inst_iid(i) == IID_assume { ac_register_assumption(i); }
            i = inst_next(i);
        }
    }
    for k in loop_nblocks(l) {
        let lb = loop_block(l, k);
        if !skip_block(lb) { continue; }
        let t = block_terminator(lb);
        for j in term_nsucc(t) {
            let cs = vmm_get(vm, term_succ(t, j));
            if cs < 0 { continue; }
            var p = block_first(cs);
            while p >= 0 && iop(p) == OP_PHI {
                let nx = inst_next(p);
                phi_remove_incoming_block(p, lb, false);
                p = nx;
            }
        }
    }
    let cparent = vmm_get(vm, parent_bb);
    let pt = block_terminator(parent_bb);
    for j in term_nsucc(pt) {
        let s = term_succ(pt, j);
        if s == unswitched_succ { continue; }
        let cs = vmm_get(vm, s);
        if cs < 0 { continue; }
        block_remove_predecessor(cs, cparent, true);
    }
    let csucc = vmm_get(vm, unswitched_succ);
    let cterm = block_terminator(cparent);
    var cond_to_erase: i32 = -1;
    if iop(cterm) == OP_CONDBR || iop(cterm) == OP_SWITCH { cond_to_erase = op(cterm, 0); }
    let nbi = create_inst(OP_BR, T_VOID, [csucc]);
    block_append_inst(cparent, nbi);
    let dl = inst_get_md(cterm, 0);
    if dl >= 0 { inst_set_md(nbi, 0, dl); }
    inst_erase_from_parent(cterm);
    if cond_to_erase >= 0 && is_inst(cond_to_erase) && is_instruction_trivially_dead(cond_to_erase) {
        var one: i32[>..<] = [];
        one.push(cond_to_erase);
        let save = local_have_tli;
        local_have_tli = false;
        lu_recursively_delete_dead(one, slu_mssau);
        local_have_tli = save;
    }
    var p = block_first(csucc);
    while p >= 0 && iop(p) == OP_PHI {
        var found = false;
        var i = nops(p) - 1;
        while i >= 0 {
            if phi_block(p, i) == cparent {
                if !found { found = true; } else { phi_remove_incoming(p, i); }
            }
            i--;
        }
        p = inst_next(p);
    }
    for cb in new_blocks {
        var seen: i32[>..<] = [];
        let t = block_terminator(cb);
        for j in term_nsucc(t) {
            let s = term_succ(t, j);
            if position(seen, s) < 0 { seen.push(s); dt_ups.push(DTUpdate { kind: DT_INSERT, from: cb, to: s }); }
        }
    }
    return cph;
}

// cloneLoopNest(OrigRootL, RootParentL, VMap, LI)
fn clone_loop_nest(orig: i32, root_parent: i32, vm: i32) -> i32 {
    let fv = loops[orig].fv;
    fn add_cloned_blocks(ol: i32, cl: i32) {
        for k in loop_nblocks(ol) {
            let bb = loop_block(ol, k);
            let cb = vmm_get(vm, bb);
            loop_add_block_entry(cl, cb);
            if li_loop_for(bb) == ol { li_change_loop_for(cb, cl); }
        }
    }
    let croot = li_allocate_loop(fv);
    if root_parent >= 0 { loop_add_child(root_parent, croot); } else { li_add_top_level_loop(fv, croot); }
    add_cloned_blocks(orig, croot);
    if loop_is_innermost(orig) { return croot; }
    var st_p: i32[>..<] = [];
    var st_l: i32[>..<] = [];
    var k = loop_nsubs(orig);
    while k > 0 { k--; st_p.push(croot); st_l.push(loop_sub(orig, k)); }
    while st_l.len > 0 {
        let cp = st_p.pop();
        let ol = st_l.pop();
        let cl = li_allocate_loop(fv);
        loop_add_child(cp, cl);
        add_cloned_blocks(ol, cl);
        var j = loop_nsubs(ol);
        while j > 0 { j--; st_p.push(cl); st_l.push(loop_sub(ol, j)); }
    }
    return croot;
}

// buildClonedLoops(OrigL, ExitBlocks, VMap, LI, NonChildClonedLoops)
fn build_cloned_loops(ol: i32, exits: const i32[:], vm: i32, non_child: i32[>..<]&) {
    let fv = loops[ol].fv;
    var cl: i32 = -1;
    let oph = loop_preheader(ol);
    let oh = loop_header(ol);
    let cph = vmm_get(vm, oph);
    let ch = vmm_get(vm, oh);
    var parent: i32 = -1;
    var cexits: i32[>..<] = [];
    var elm_k: i32[>..<] = [];     // ExitLoopMap
    var elm_v: i32[>..<] = [];
    fn elm_get(b: i32) -> i32 { let j = position(elm_k, b); return if j >= 0 { elm_v[j] } else { -1 }; }
    for eb in exits {
        let ceb = vmm_get(vm, eb);
        if ceb < 0 { continue; }
        let el = li_loop_for(eb);
        if el < 0 { continue; }
        let j = position(elm_k, ceb);
        if j >= 0 { elm_v[j] = el; } else { elm_k.push(ceb); elm_v.push(el); }
        cexits.push(ceb);
        if parent < 0 || (parent != el && loop_contains_loop(parent, el)) { parent = el; }
    }
    var clb: i32[>..<] = [];    // ClonedLoopBlocks (SetVector)
    for k in loop_nblocks(ol) {
        let cb = vmm_get(vm, loop_block(ol, k));
        if cb >= 0 && position(clb, cb) < 0 { clb.push(cb); }
    }
    var wl: i32[>..<] = [];
    var bicl = hm_new();         // BlocksInClonedLoop
    var bicl_n: i64 = 0;
    fn bicl_insert(b: i32) -> bool { if hm_has(bicl, b as u64) { return false; } hm_put(bicl, b as u64, 1); bicl_n++; return true; }
    each_pred(ch) { p =>
        if p != cph {
            if bicl_insert(p) && p != ch { wl.push(p); }
        }
    };
    if bicl_n > 0 {
        bicl_insert(ch);
        while wl.len > 0 {
            let bb = wl.pop();
            each_pred(bb) { p => if position(clb, p) >= 0 && bicl_insert(p) { wl.push(p); } };
        }
        cl = li_allocate_loop(fv);
        if parent >= 0 {
            loop_add_basic_block_to_loop(parent, cph);
            loop_add_child(parent, cl);
        } else {
            li_add_top_level_loop(fv, cl);
        }
        non_child.push(cl);
        for k in loop_nblocks(ol) {
            let bb = loop_block(ol, k);
            let cb = vmm_get(vm, bb);
            if cb < 0 || !hm_has(bicl, cb as u64) { continue; }
            if li_loop_for(bb) == ol { loop_add_basic_block_to_loop(cl, cb); continue; }
            var pl = cl;
            while pl >= 0 { loop_add_block_entry(pl, cb); pl = loop_parent(pl); }
        }
        for k in loop_nsubs(ol) {
            let child = loop_sub(ol, k);
            let cch = vmm_get(vm, loop_header(child));
            if cch < 0 || !hm_has(bicl, cch as u64) { continue; }
            clone_loop_nest(child, cl, vm);
        }
    }
    var unlooped = hm_new();
    var unlooped_n: i64 = 0;
    if bicl_n == 0 { hm_put(unlooped, cph as u64, 1); unlooped_n++; }
    for cb in clb { if !hm_has(bicl, cb as u64) && !hm_has(unlooped, cb as u64) { hm_put(unlooped, cb as u64, 1); unlooped_n++; } }
    // llvm::sort by ascending loop depth (std::sort)
    var ordered: i32[>..<] = [];
    for x in cexits { ordered.push(x); }
    slu_sort_by_depth(ordered, elm_k, elm_v);
    while unlooped_n > 0 && ordered.len > 0 {
        let eb = ordered.pop();
        let el = elm_get(eb);
        wl.push(eb);
        while wl.len > 0 {
            let bb = wl.pop();
            if bb == cph { continue; }
            each_pred(bb) { p =>
                if hm_has(unlooped, p as u64) {
                    hm_del(unlooped, p as u64);
                    unlooped_n--;
                    elm_k.push(p);
                    elm_v.push(el);
                    wl.push(p);
                }
            };
        }
    }
    var order: i32[>..<] = [];
    order.push(cph);
    for x in clb { order.push(x); }
    for x in cexits { order.push(x); }
    for bb in order {
        let olp = elm_get(bb);
        if olp >= 0 { loop_add_basic_block_to_loop(olp, bb); }
    }
    for k in loop_nsubs(ol) {
        let child = loop_sub(ol, k);
        let cch = vmm_get(vm, loop_header(child));
        if cch < 0 || hm_has(bicl, cch as u64) { continue; }
        non_child.push(clone_loop_nest(child, elm_get(cch), vm));
    }
}
// llvm::sort(OrderedClonedExitsInLoops, depth(LHS) < depth(RHS)) through libstdc++'s std::sort
fn slu_sort_by_depth(xs: i32[>..<]&, k: i32[>..<]&, v: i32[>..<]&) {
    std_sort(xs, 0, xs.len) { a, b => loop_depth(v[position(k, a)]) < loop_depth(v[position(k, b)]) };
}

// deleteDeadClonedBlocks(L, ExitBlocks, VMaps, DT, MSSAU)
fn delete_dead_cloned_blocks(l: i32, exits: const i32[:], vms: const i32[:]) {
    var dead: i32[>..<] = [];
    var bbs: i32[>..<] = [];
    slu_loop_blocks(l, bbs);
    for e in exits { bbs.push(e); }
    for bb in bbs {
        for vm in vms {
            let cb = vmm_get(vm, bb);
            if cb < 0 { continue; }
            if !dt_has_node(DT_DOM, cb) {
                let t = block_terminator(cb);
                var succs: i32[>..<] = [];
                for j in term_nsucc(t) { succs.push(term_succ(t, j)); }
                for s in succs { block_remove_predecessor(s, cb, false); }
                dead.push(cb);
            }
        }
    }
    if slu_mssau {
        var set: i32[>..<] = [];
        for d in dead { if position(set, d) < 0 { set.push(d); } }
        msu_remove_blocks(set);
    }
    for b in dead { var i = block_first(b); while i >= 0 { drop_all_refs(i); i = inst_next(i); } }
    for b in dead { slu_block_erase(b); }
}
// BasicBlock::eraseFromParent for a block whose instructions' references are dropped (uses may remain among
// dead blocks): uses become poison first
fn slu_block_erase(b: i32) {
    var i = block_first(b);
    while i >= 0 { if vals[i].first_use >= 0 { rauw(i, c_poison(vals[i].ty)); } i = inst_next(i); }
    li_remove_block_map_only(b);
    block_erase(b);
}
fn li_remove_block_map_only(b: i32) { if li_loop_for(b) >= 0 { li_change_loop_for(b, -1); } }

// deleteDeadBlocksFromLoop(L, ExitBlocks, DT, LI, MSSAU, SE, LoopUpdater)
fn delete_dead_blocks_from_loop(l: i32, exits: i32[>..<]&) {
    var dead: i32[>..<] = [];
    var cand: i32[>..<] = [];
    for e in exits { cand.push(e); }
    for k in loop_nblocks(l) { cand.push(loop_block(l, k)); }
    while cand.len > 0 {
        let bb = cand.pop();
        if position(dead, bb) < 0 && !dt_has_node(DT_DOM, bb) {
            let t = block_terminator(bb);
            for j in term_nsucc(t) {
                let s = term_succ(t, j);
                block_remove_predecessor(s, bb, false);
                cand.push(s);
            }
            dead.push(bb);
        }
    }
    if slu_mssau { msu_remove_blocks(dead); }
    var w: i64 = 0;
    for k in exits.len { if position(dead, exits[k]) < 0 { exits[w] = exits[k]; w++; } }
    exits.resize(w);
    var pl = l;
    while pl >= 0 {
        var keep: i32[>..<] = [];
        for k in loop_nblocks(pl) { let b = loop_block(pl, k); if position(dead, b) < 0 { keep.push(b); } }
        slu_loop_set_blocks(pl, keep);
        pl = loop_parent(pl);
    }
    var ks: i32[>..<] = [];
    for k in loop_nsubs(l) {
        let c = loop_sub(l, k);
        if position(dead, loop_header(c)) < 0 { ks.push(c); continue; }
        lpm_mark_loop_as_deleted(c);
        if slu_se { sc_forget_block_and_loop_dispositions_all(); }
        loops[c].parent = -1;
        li_destroy_loop(c);
    }
    slu_loop_set_subs(l, ks);
    for bb in dead {
        li_change_loop_for(bb, -1);
        var i = block_first(bb);
        while i >= 0 { if vals[i].first_use >= 0 { rauw(i, c_poison(vals[i].ty)); } i = inst_next(i); }
        i = block_first(bb);
        while i >= 0 { drop_all_refs(i); i = inst_next(i); }
    }
    for bb in dead { block_erase(bb); }
}

// recomputeLoopBlockSet(L, LI): the set as an HMap, plus its size
fn recompute_loop_block_set(l: i32, set: HMap&) -> i64 {
    let ph = loop_preheader(l);
    let header = loop_header(l);
    var n: i64 = 0;
    fn ins(b: i32) -> bool { if hm_has(set, b as u64) { return false; } hm_put(set, b as u64, 1); n++; return true; }
    var wl: i32[>..<] = [];
    each_pred(header) { p => if p != ph { if ins(p) && p != header { wl.push(p); } } };
    if n == 0 { return 0; }
    while wl.len > 0 {
        let bb = wl.pop();
        if bb == header { continue; }
        let il = li_loop_for(bb);
        if il >= 0 && il != l {
            let iph = loop_preheader(il);
            if !ins(iph) { continue; }
            for k in loop_nblocks(il) {
                let ib = loop_block(il, k);
                if ib == bb { continue; }
                ins(ib);
            }
            wl.push(iph);
            continue;
        }
        each_pred(bb) { p => if loop_contains(l, p) && ins(p) { wl.push(p); } };
    }
    return n;
}

// rebuildLoopAfterUnswitch(L, ExitBlocks, LI, HoistedLoops, SE): false if L is no longer a loop
fn rebuild_loop_after_unswitch(l: i32, exits: const i32[:], hoisted: i32[>..<]&) -> bool {
    let fv = loops[l].fv;
    let ph = loop_preheader(l);
    var parent: i32 = -1;
    var exits_in_loops: i32[>..<] = [];
    for eb in exits {
        let el = li_loop_for(eb);
        if el < 0 { continue; }
        exits_in_loops.push(eb);
        if parent < 0 || (parent != el && loop_contains_loop(parent, el)) { parent = el; }
    }
    var lbs = hm_new();
    let nlbs = recompute_loop_block_set(l, lbs);
    if nlbs > 0 && loop_parent(l) != parent {
        var il = loop_parent(l);
        while il != parent {
            var keep: i32[>..<] = [];
            for k in loop_nblocks(il) { let b = loop_block(il, k); if b != ph && !loop_contains(l, b) { keep.push(b); } }
            slu_loop_set_blocks(il, keep);
            il = loop_parent(il);
        }
        li_change_loop_for(ph, parent);
        loop_remove_child(loop_parent(l), l);
        if parent >= 0 { loop_add_child(parent, l); } else { li_add_top_level_loop(fv, l); }
    }
    // stable_partition of the blocks
    var inb: i32[>..<] = [];
    var outb: i32[>..<] = [];
    for k in loop_nblocks(l) {
        let b = loop_block(l, k);
        if nlbs > 0 && hm_has(lbs, b as u64) { inb.push(b); } else { outb.push(b); }
    }
    var unlooped = hm_new();
    for b in outb { hm_put(unlooped, b as u64, 1); }
    if nlbs == 0 { hm_put(unlooped, ph as u64, 1); }
    var unlooped_list: i32[>..<] = [];     // the set's members in a fixed order (for the final walks)
    for b in outb { unlooped_list.push(b); }
    if nlbs == 0 && position(unlooped_list, ph) < 0 { unlooped_list.push(ph); }
    slu_loop_set_blocks(l, inb);
    // stable_sort of the exits by LI.getLoopDepth
    var sorted: i32[>..<] = [];
    for e in exits_in_loops { sorted.push(e); }
    std_stable_sort(sorted, 0, sorted.len) { a, b => slu_li_depth(a) < slu_li_depth(b) };
    var prev = loop_parent(l);
    fn remove_unlooped(x: i32) {
        var keep: i32[>..<] = [];
        for k in loop_nblocks(x) { let b = loop_block(x, k); if !hm_has(unlooped, b as u64) { keep.push(b); } }
        slu_loop_set_blocks(x, keep);
    }
    var wl: i32[>..<] = [];
    var nelb: i32[>..<] = [];
    fn unlooped_count() -> i64 { var c: i64 = 0; for b in unlooped_list { if hm_has(unlooped, b as u64) { c++; } } return c; }
    while unlooped_count() > 0 && sorted.len > 0 {
        let eb = sorted.pop();
        let el = li_loop_for(eb);
        while prev != el { remove_unlooped(prev); prev = loop_parent(prev); }
        wl.push(eb);
        while wl.len > 0 {
            let bb = wl.pop();
            if bb == ph { continue; }
            each_pred(bb) { p =>
                if hm_has(unlooped, p as u64) {
                    hm_del(unlooped, p as u64);
                    nelb.push(p);
                    wl.push(p);
                }
            };
        }
        for bb in nelb {
            let bbl = li_loop_for(bb);
            if bbl >= 0 && (bbl == l || !loop_contains_loop(l, bbl)) { li_change_loop_for(bb, el); }
        }
        nelb.clear();
    }
    while prev >= 0 { remove_unlooped(prev); prev = loop_parent(prev); }
    for bb in unlooped_list {
        if !hm_has(unlooped, bb as u64) { continue; }
        let bbl = li_loop_for(bb);
        if bbl >= 0 && (bbl == l || !loop_contains_loop(l, bbl)) { li_change_loop_for(bb, -1); }
    }
    // stable_partition of the subloops by header membership
    var ins_: i32[>..<] = [];
    var outs: i32[>..<] = [];
    for k in loop_nsubs(l) {
        let s = loop_sub(l, k);
        if nlbs > 0 && hm_has(lbs, loop_header(s) as u64) { ins_.push(s); } else { outs.push(s); }
    }
    for h in outs {
        hoisted.push(h);
        loops[h].parent = -1;
        let npl = li_loop_for(loop_preheader(h));
        if npl >= 0 { loop_add_child(npl, h); } else { li_add_top_level_loop(fv, h); }
    }
    slu_loop_set_subs(l, ins_);
    if loop_nblocks(l) == 0 {
        let p = loop_parent(l);
        if p >= 0 { loop_remove_child(p, l); } else { li_remove_top_level_loop(fv, l); }
        if slu_se { sc_forget_block_and_loop_dispositions_all(); }
        li_destroy_loop(l);
        return false;
    }
    return true;
}
