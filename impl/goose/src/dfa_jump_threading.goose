// DFAJumpThreading: port of llvm/lib/Transforms/Scalar/DFAJumpThreading.cpp (DFAJumpThreading::run and unfold,
// MainSwitch::isCandidate / isValidSelectInst, AllSwitchPaths (findTPaths with getStateDefMap,
// getPathsFromStateDefMap and paths, unifyTPaths), TransformDFA (isLegalAndProfitableToTransform,
// createAllExitPaths, createExitPath, cloneBlockAndUpdatePredecessor, updateSuccessorPhis, updatePredecessor,
// updateDefMap, updateLastSuccessor, updateSSA with SSAUpdaterBulk, cleanPhiNodes)). Optimization remarks are not
// emitted (no -pass-remarks output yet).
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import flags;
import loopinfo;
import gen_attrs;
import gen_iids;
import domtree;
import dtu;
import scev;
import apint;
import assume;
import profdata;
import simplifycfg;
import loopsimplify;
import clone_function;
import value_mapper;
import loop_unroll_pass;
import inline_cost;
import tti;
import tti_x86;
import ssa_updater_bulk;

fn dj_is_valid_select(si: i32, sels: i32[>..<]&) -> bool {
    let u = vals[si].first_use;
    if u < 0 || uses[u].next >= 0 { return false; }
    let us = uses[u].user;
    if !is_inst(us) || (iop(us) != OP_PHI && iop(us) != OP_SELECT) { return false; }
    let bb = inst_parent(si);
    let t = block_terminator(bb);
    if t < 0 || iop(t) != OP_BR { return false; }
    if iop(us) == OP_PHI && phi_block(us, u - vals[us].ops) != bb { return false; }
    for p in sels {
        if op(p, 1) != si && op(p, 2) != si && inst_parent(p) == bb { return false; }
    }
    return true;
}

// MainSwitch::isCandidate (SelectInsts: the selects whose single user is a phi)
var dj_sels: i32[>..<];
fn dj_is_candidate(sw: i32) -> bool {
    dj_sels.clear();
    let cond = op(sw, 0);
    if !is_inst(cond) || iop(cond) != OP_PHI { return false; }
    let l = li_loop_for(inst_parent(sw));
    if l < 0 { return false; }
    var qv: i32[>..<] = [];
    var qb: i32[>..<] = [];
    var seen: i32[>..<] = [];
    var sels: i32[>..<] = [];
    fn add(v: i32, b: i32, qv: i32[>..<]&, qb: i32[>..<]&, seen: i32[>..<]&) {
        for x in seen { if x == v { return; } }
        seen.push(v);
        qv.push(v);
        qb.push(b);
    }
    add(cond, -1, qv, qb, seen);
    let early = flag_bool("dfa-early-exit-heuristic", true);
    var h: i64 = 0;
    while h < qv.len {
        let cur = qv[h];
        let cb = qb[h];
        h++;
        if is_inst(cur) && iop(cur) == OP_PHI {
            // Phi->blocks() with getIncomingValueForBlock
            for k in phi_nincoming(cur) {
                let ib = phi_block(cur, k);
                let iv = phi_value(cur, phi_block_index(cur, ib));
                add(iv, ib, qv, qb, seen);
            }
        } else if is_inst(cur) && iop(cur) == OP_SELECT {
            if !dj_is_valid_select(cur, sels) { return false; }
            add(op(cur, 1), cb, qv, qb, seen);
            add(op(cur, 2), cb, qv, qb, seen);
            let us = uses[vals[cur].first_use].user;
            if iop(us) == OP_PHI { sels.push(cur); dj_sels.push(cur); }
        } else if is_constant(cur) {
            continue;
        } else {
            if early && cb >= 0 {
                let cl = li_loop_for(cb);
                if cl >= 0 && loop_contains_loop(l, cl) { return false; }
            }
        }
    }
    return true;
}

// DFAJumpThreadingPass::run + DFAJumpThreading::run
fn dfa_jump_threading_run(fv: i32) -> u32 {
    // AC, DT, LI and TTI are requested before the optsize check (LoopInfo numbers the DT)
    li_get(fv);
    if func_has_fn_attr(fv, AK_OptimizeForSize) || func_has_fn_attr(fv, AK_MinSize) { return PA_ALL; }
    dtu_begin(fv, true, false, true);
    var made = false;
    var threadable: i32 = -1;
    var bb = func_first_block(fv);
    while bb >= 0 {
        let t = block_terminator(bb);
        if t >= 0 && iop(t) == OP_SWITCH && dj_is_candidate(t) {
            // MainSwitch::getSelectInsts with the phi user of each select
            var sels: i32[>..<] = [];
            var sel_uses: i32[>..<] = [];
            for x in dj_sels { sels.push(x); sel_uses.push(uses[vals[x].first_use].user); }
            if sels.len > 0 { made = true; }
            dj_unfold_select_instrs(sels, sel_uses);
            if dj_find_tpaths(t) > 0 { threadable = t; break; }
        }
        bb = block_next(bb);
    }
    // LI->verify(DTU->getDomTree()) in a release build: only the flush
    dtu_get_dt();
    var broken = false;
    if threadable >= 0 {
        dj_collect_ephemeral_values(fv);
        if dj_is_legal_and_profitable() {
            dj_create_all_exit_paths(fv);
            made = true;
            broken = true;
        }
    }
    dtu_end();
    if !made { return PA_ALL; }
    var pa: u32 = (1 as u32) << A_DOMTREE;
    if !broken { pa = pa | ((1 as u32) << A_LOOPS); }
    return pa;
}

// ---------------------------------------------------------------------------------------------
// unfoldSelectInstrs / unfold

fn dj_first_insertion_pt(bb: i32) -> i32 {
    var i = block_first(bb);
    while i >= 0 && (iop(i) == OP_PHI || inst_is_eh_pad(i)) { i = inst_next(i); }
    return i;
}
fn dj_name_plus(v: i32, suffix: const u8[:]) -> u8[>..] {
    var nm: u8[>..] = [];
    nm.append(val_name(v));
    nm.append(suffix);
    return nm;
}
// PHINode::Create(Ty, N, Name, InsertBefore = BB->getFirstInsertionPt())
fn dj_new_phi(ty: i32, bb: i32, name: const u8[:]) -> i32 {
    let pn = new_inst(OP_PHI, ty, 0);
    vals[pn].nops = 0;
    inst_insert_at(pn, bb, dj_first_insertion_pt(bb), true);
    if name.len > 0 { set_name(pn, name); }
    return pn;
}
// User::replaceUsesOfWith(From, To)
fn dj_replace_uses_of_with(u: i32, from: i32, to: i32) {
    for k in nops(u) { if op(u, k) == from { set_op(u, k, to); } }
}
fn dj_set_loc(i: i32, loc: i32) { if loc >= 0 { inst_set_md(i, 0, loc); } }

fn dj_unfold_select_instrs(sels0: const i32[:], uses0: const i32[:]) {
    var st_si: i32[>..<] = [];
    var st_use: i32[>..<] = [];
    for k in sels0.len { st_si.push(sels0[k]); st_use.push(uses0[k]); }
    var new_si: i32[>..<] = [];
    var new_use: i32[>..<] = [];
    while st_si.len > 0 {
        let si = st_si.pop();
        let su = st_use.pop();
        new_si.clear(); new_use.clear();
        dj_unfold(si, su, new_si, new_use);
        for k in new_si.len { st_si.push(new_si[k]); st_use.push(new_use[k]); }
    }
}

fn dj_unfold(si: i32, siuse0: i32, new_si: i32[>..<]&, new_use: i32[>..<]&) {
    var siuse = siuse0;
    let su = vals[si].first_use;
    if su < 0 || uses[su].user != siuse { fatal("internal: dfa-jump-threading: the select's use is not its phi"); }
    let start = phi_block(siuse, (su - vals[siuse].ops) as i64);
    let fv = block_func(start);
    let sterm = block_terminator(start);
    var newbbs: i32[>..<] = [];
    if iop(sterm) == OP_BR {
        let end = term_succ(sterm, 0);
        let nb = create_block_before(fv, end, dj_name_plus(si, ".si.unfold.false"));
        newbbs.push(nb);
        let loc = merged_location(inst_get_md(sterm, 0), inst_get_md(si, 0));
        let br = create_inst(OP_BR, T_VOID, [end]);
        block_append_inst(nb, br);
        dj_set_loc(br, loc);
        dtu_apply_updates([DTUpdate { kind: DT_INSERT, from: nb, to: end }]);
        let op1 = op(si, 1);
        let op2 = op(si, 2);
        let nphi = dj_new_phi(vals[siuse].ty, nb, dj_name_plus(op2, ".si.unfold.phi"));
        phi_add_incoming(nphi, op2, start);
        var p = block_first(end);
        while p >= 0 && iop(p) == OP_PHI {
            if p != siuse { phi_add_incoming(p, phi_value(p, phi_block_index(p, start)), nb); }
            p = inst_next(p);
        }
        if end == inst_parent(siuse) {
            phi_add_incoming(siuse, nphi, nb);
            dj_replace_uses_of_with(siuse, si, op1);
        } else {
            let ephi = dj_new_phi(vals[siuse].ty, end, dj_name_plus(si, ".si.unfold.phi"));
            each_pred(end) { pr => if pr != start && pr != nb { phi_add_incoming(ephi, ephi, pr); } };
            phi_add_incoming(ephi, op1, start);
            phi_add_incoming(ephi, nphi, nb);
            dj_replace_uses_of_with(siuse, si, ephi);
            siuse = ephi;
        }
        if is_inst(op1) && iop(op1) == OP_SELECT { new_si.push(op1); new_use.push(siuse); }
        if is_inst(op2) && iop(op2) == OP_SELECT { new_si.push(op2); new_use.push(nphi); }
        inst_erase_from_parent(sterm);
        let bi = create_inst(OP_CONDBR, T_VOID, [op(si, 0), end, nb]);
        block_append_inst(start, bi);
        dj_set_loc(bi, loc);
        inst_set_md(bi, MDK_PROF, inst_get_md(si, MDK_PROF));
        dtu_apply_updates([DTUpdate { kind: DT_INSERT, from: start, to: nb }]);
    } else {
        let end = inst_parent(siuse);
        let nbt = create_block_before(fv, end, dj_name_plus(si, ".si.unfold.true"));
        let nbf = create_block_before(fv, end, dj_name_plus(si, ".si.unfold.false"));
        newbbs.push(nbt);
        newbbs.push(nbf);
        let nfe = create_inst(OP_BR, T_VOID, [end]);
        block_append_inst(nbf, nfe);
        let bi = create_inst(OP_CONDBR, T_VOID, [op(si, 0), end, nbf]);
        block_append_inst(nbt, bi);
        let sloc = inst_get_md(si, 0);
        dj_set_loc(nfe, sloc);
        dj_set_loc(bi, sloc);
        inst_set_md(bi, MDK_PROF, inst_get_md(si, MDK_PROF));
        dtu_apply_updates([DTUpdate { kind: DT_INSERT, from: nbt, to: nbf }, DTUpdate { kind: DT_INSERT, from: nbt, to: end },
                           DTUpdate { kind: DT_INSERT, from: nbf, to: end }]);
        let tv = op(si, 1);
        let fvv = op(si, 2);
        let pt = dj_new_phi(vals[siuse].ty, nbt, dj_name_plus(tv, ".si.unfold.phi"));
        let pf = dj_new_phi(vals[siuse].ty, nbf, dj_name_plus(fvv, ".si.unfold.phi"));
        phi_add_incoming(pt, tv, start);
        phi_add_incoming(pf, fvv, nbt);
        if is_inst(tv) && iop(tv) == OP_SELECT { new_si.push(tv); new_use.push(pt); }
        if is_inst(fvv) && iop(fvv) == OP_SELECT { new_si.push(fvv); new_use.push(pf); }
        phi_add_incoming(siuse, pt, nbt);
        phi_add_incoming(siuse, pf, nbf);
        phi_remove_incoming_block(siuse, start, true);
        var p = block_first(end);
        while p >= 0 && iop(p) == OP_PHI {
            let np = inst_next(p);
            if p != siuse {
                let v = phi_value(p, phi_block_index(p, start));
                phi_add_incoming(p, v, nbt);
                phi_add_incoming(p, v, nbf);
                phi_remove_incoming_block(p, start, true);
            }
            p = np;
        }
        let cbr = block_terminator(start);
        let sn: i64 = if term_succ(cbr, 1) == end { 1 } else { 0 };
        term_set_succ(cbr, sn, nbt);
        dtu_apply_updates([DTUpdate { kind: DT_DELETE, from: start, to: end }, DTUpdate { kind: DT_INSERT, from: start, to: nbt }]);
    }
    let l = li_loop_for(start);
    if l >= 0 { for b in newbbs { loop_add_basic_block_to_loop(l, b); } }
    if vals[si].first_use >= 0 { fatal("internal: dfa-jump-threading: the select must be dead now"); }
    inst_erase_from_parent(si);
}

// ---------------------------------------------------------------------------------------------
// AllSwitchPaths: paths are immutable runs in dj_pb (dj_pat/dj_plen), with a determinator and an exit value for
// ThreadingPaths; the recursive functions return their result path ids as a range at the top of dj_stk.

var dj_pb: i32[>..<];
var dj_pat: i32[>..<];
var dj_plen: i32[>..<];
var dj_pexit: i32[>..<];        // ThreadingPath exit value (a ConstantInt; -1 = not set)
var dj_pdet: i32[>..<];         // ThreadingPath determinator block (-1 = not set)
var dj_tp: i32[>..<];           // AllSwitchPaths::TPaths (path ids)
var dj_stk: i32[>..<];
var dj_vb: i32[>..<];           // VisitedBlocks (a set: insert if absent, erase if present)
var dj_uniq: i32[>..<];         // per-activation unique-block sets, by mark
var dj_sd_bb: i32[>..<];        // StateDefMap
var dj_sd_phi: i32[>..<];
var dj_sw: i32 = -1;
var dj_swbb: i32 = -1;
var dj_outer: i32 = -1;
var dj_visited_n: i64 = 0;
var dj_max_len: i64 = 20;
var dj_max_visited: i64 = 2500;

fn dj_new_path(src: i32, extra_front: i32, extra_back: i32, exit: i32) -> i32 {
    let at = dj_pb.len as i32;
    if extra_front >= 0 { dj_pb.push(extra_front); }
    if src >= 0 { for k in dj_plen[src] as i64 { dj_pb.push(dj_pb[dj_pat[src] + k]); } }
    if extra_back >= 0 { dj_pb.push(extra_back); }
    dj_pat.push(at);
    dj_plen.push(dj_pb.len as i32 - at);
    dj_pexit.push(exit);
    dj_pdet.push(if src >= 0 { dj_pdet[src] } else { -1 });
    return dj_pat.len as i32 - 1;
}
fn dj_raw_path(at: i32, exit: i32, det: i32) -> i32 {
    dj_pat.push(at);
    dj_plen.push(dj_pb.len as i32 - at);
    dj_pexit.push(exit);
    dj_pdet.push(det);
    return dj_pat.len as i32 - 1;
}
// Path + OtherPath[1..]
fn dj_append_excluding_first(p: i32, q: i32) -> i32 {
    let at = dj_pb.len as i32;
    for k in dj_plen[p] as i64 { dj_pb.push(dj_pb[dj_pat[p] + k]); }
    for k in 1..dj_plen[q] as i64 { dj_pb.push(dj_pb[dj_pat[q] + k]); }
    dj_pat.push(at);
    dj_plen.push(dj_pb.len as i32 - at);
    dj_pexit.push(dj_pexit[p]);
    dj_pdet.push(dj_pdet[p]);
    return dj_pat.len as i32 - 1;
}
fn dj_vb_has(b: i32) -> bool { for x in dj_vb { if x == b { return true; } } return false; }
fn dj_vb_insert(b: i32) { if !dj_vb_has(b) { dj_vb.push(b); } }
fn dj_vb_erase(b: i32) {
    for k in dj_vb.len { if dj_vb[k] == b { dj_vb[k] = dj_vb[dj_vb.len - 1]; dj_vb.pop(); return; } }
}
fn dj_outer_contains(b: i32) -> bool { loop_contains(dj_outer, b) }
fn dj_sd_has(b: i32) -> bool { for x in dj_sd_bb { if x == b && b >= 0 { return true; } } return false; }

// replace the stack range [from, top) by the ids at [mid, top)
fn dj_stk_collapse(from: i64, mid: i64) {
    let n = dj_stk.len - mid;
    for k in n { dj_stk[from + k] = dj_stk[mid + k]; }
    dj_stk.resize(from + n);
}

// paths(BB, ToBB, Visited, PathDepth, PathsLimit): result ids pushed on dj_stk
recursive fn dj_paths(bb: i32, to: i32, depth: i64, limit: i64) {
    let base = dj_stk.len;
    if depth > dj_max_len { return; }
    dj_vb_insert(bb);
    dj_visited_n++;
    if dj_visited_n > dj_max_visited { return; }
    if !dj_outer_contains(bb) { return; }
    let umark = dj_uniq.len;
    for k in block_nsucc(bb) {
        let s = block_succ(bb, k);
        if (dj_stk.len - base) >= limit { break; }
        var seen = false;
        for j in umark..dj_uniq.len { if dj_uniq[j] == s { seen = true; } }
        if seen { continue; }
        dj_uniq.push(s);
        if s == to {
            let at = dj_pb.len as i32;
            dj_pb.push(bb); dj_pb.push(to);
            dj_stk.push(dj_raw_path(at, -1, -1));
            continue;
        }
        if dj_vb_has(s) { continue; }
        let cl = li_loop_for(bb);
        if s == loop_header(cl) { continue; }
        if li_loop_for(s) != cl { continue; }
        let cb = dj_stk.len;
        dj_paths(s, to, depth + 1, limit - (cb - base));
        let ce = dj_stk.len;
        for j in cb..ce { dj_stk.push(dj_new_path(dj_stk[j], bb, -1, -1)); }
        dj_stk_collapse(cb, ce);
    }
    dj_uniq.resize(umark);
    dj_vb_erase(bb);
}

// getPathsFromStateDefMap(StateDef, Phi, VB, PathsLimit): result ids pushed on dj_stk
recursive fn dj_paths_from_state_def(phi: i32, limit: i64) {
    let base = dj_stk.len;
    let phibb = inst_parent(phi);
    dj_vb_insert(phibb);
    let umark = dj_uniq.len;
    for k in phi_nincoming(phi) {
        if (dj_stk.len - base) >= limit { break; }
        let ib = phi_block(phi, k);
        var seen = false;
        for j in umark..dj_uniq.len { if dj_uniq[j] == ib { seen = true; } }
        if seen { continue; }
        dj_uniq.push(ib);
        if !dj_outer_contains(ib) { continue; }
        let iv = phi_value(phi, phi_block_index(phi, ib));
        if is_cint(iv) {
            if phibb == dj_swbb && dj_swbb != inst_parent(op(dj_sw, 0)) { continue; }
            let at = dj_pb.len as i32;
            if ib != dj_swbb {
                if dj_vb_has(ib) { continue; }
                dj_pb.push(ib);
            }
            dj_pb.push(phibb);
            dj_stk.push(dj_raw_path(at, iv, phibb));
            continue;
        }
        if dj_vb_has(ib) || ib == dj_swbb { continue; }
        if !is_inst(iv) || iop(iv) != OP_PHI { continue; }
        let ipd = inst_parent(iv);
        if !dj_sd_has(ipd) { continue; }
        if ipd == ib {
            let cb = dj_stk.len;
            dj_paths_from_state_def(iv, limit - (cb - base));
            let ce = dj_stk.len;
            for j in cb..ce { dj_stk.push(dj_new_path(dj_stk[j], -1, phibb, dj_pexit[dj_stk[j]])); }
            dj_stk_collapse(cb, ce);
            continue;
        }
        if dj_vb_has(ipd) { continue; }
        let inter_limit = limit - (dj_stk.len - base);
        let ib0 = dj_stk.len;
        dj_paths(ipd, ib, 1, inter_limit);
        let ib1 = dj_stk.len;
        let nip = ib1 - ib0;
        if nip == 0 { continue; }
        let pred_limit = inter_limit / nip;
        dj_paths_from_state_def(iv, pred_limit);
        let pe = dj_stk.len;
        for j in ib1..pe {
            for q in ib0..ib1 {
                let np = dj_append_excluding_first(dj_stk[j], dj_stk[q]);
                dj_stk.push(dj_new_path(np, -1, phibb, dj_pexit[dj_stk[j]]));
            }
        }
        dj_stk_collapse(ib0, pe);
    }
    dj_uniq.resize(umark);
    dj_vb_erase(phibb);
}

// getStateDefMap
fn dj_state_def_map() {
    dj_sd_bb.clear(); dj_sd_phi.clear();
    var multi: i32[>..<] = [];
    var stack: i32[>..<] = [];
    var seenv: i32[>..<] = [];
    stack.push(op(dj_sw, 0));
    while stack.len > 0 {
        let cur = stack.pop();
        let db = inst_parent(cur);
        if dj_sd_has(db) { var m = false; for x in multi { if x == db { m = true; } } if !m { multi.push(db); } }
        else { dj_sd_bb.push(db); dj_sd_phi.push(cur); }
        var s1 = false;
        for x in seenv { if x == cur { s1 = true; } }
        if !s1 { seenv.push(cur); }
        for k in phi_nincoming(cur) {
            let ib = phi_block(cur, k);
            let iv = phi_value(cur, phi_block_index(cur, ib));
            if !is_inst(iv) || iop(iv) != OP_PHI { continue; }
            var seen = false;
            for x in seenv { if x == iv { seen = true; } }
            if seen || !dj_outer_contains(ib) { continue; }
            stack.push(iv);
        }
    }
    for b in multi {
        for k in dj_sd_bb.len { if dj_sd_bb[k] == b { dj_sd_bb[k] = -1; } }
    }
}

// AllSwitchPaths::run (findTPaths, unifyTPaths): the threading paths go to dj_tp
fn dj_find_tpaths(sw: i32) -> i64 {
    dj_sw = sw;
    dj_swbb = inst_parent(sw);
    dj_outer = loop_outermost(li_loop_for(dj_swbb));
    dj_max_len = flag_int("dfa-max-path-length", 20);
    dj_max_visited = flag_int("dfa-max-num-visited-paths", 2500);
    let max_paths = flag_int("dfa-max-num-paths", 200);
    dj_visited_n = 0;
    dj_pb.clear(); dj_pat.clear(); dj_plen.clear(); dj_pexit.clear(); dj_pdet.clear(); dj_stk.clear(); dj_vb.clear(); dj_uniq.clear();
    dj_tp.clear();
    dj_state_def_map();
    var any = false;
    for b in dj_sd_bb { if b >= 0 { any = true; } }
    if !any { return 0; }
    let sphi = op(sw, 0);
    let sdef = inst_parent(sphi);
    dj_paths_from_state_def(sphi, max_paths);
    let n_to_def = dj_stk.len;
    if sdef == dj_swbb || n_to_def == 0 {
        for j in n_to_def { dj_tp.push(dj_stk[j]); }
    } else {
        let plimit = max_paths / n_to_def;
        dj_paths(sdef, dj_swbb, 1, plimit);
        let ne = dj_stk.len;
        if ne == n_to_def { return 0; }
        for j in 0..n_to_def {
            let p = dj_stk[j];
            for q in n_to_def..ne {
                let ps = dj_stk[q];
                var clash = false;
                for k in 1..dj_plen[ps] as i64 {
                    let b = dj_pb[dj_pat[ps] + k];
                    for m in dj_plen[p] as i64 { if dj_pb[dj_pat[p] + m] == b { clash = true; } }
                }
                if !clash { dj_tp.push(dj_append_excluding_first(p, ps)); }
            }
        }
    }
    // unifyTPaths: two states with the same switch destination become the first one seen
    var dests: i32[>..<] = [];
    var states: i32[>..<] = [];
    for p in dj_tp {
        let ns = dj_pexit[p];
        let d = dj_next_case_successor(sw, ns);
        var found = false;
        for k in dests.len {
            if dests[k] == d { found = true; if states[k] != ns { dj_pexit[p] = states[k]; } break; }
        }
        if !found { dests.push(d); states.push(ns); }
    }
    return dj_tp.len;
}

// getNextCaseSuccessor(Switch, NextState): states are ConstantInts of the condition's type (uniqued, so equal
// values are equal ids)
fn dj_next_case_successor(sw: i32, ns: i32) -> i32 {
    var k: i64 = 2;
    while k + 1 < nops(sw) {
        if op(sw, k) == ns { return op(sw, k + 1); }
        k += 2;
    }
    return op(sw, 1);
}

// ---------------------------------------------------------------------------------------------
// TransformDFA. DuplicateBlockMap is dj_dup: (block, state) -> clone, with its keys in dj_dup_keys;
// DefMap (a MapVector) is dj_nd_key (originals in insertion order) with each original's clones in a linked list.

var dj_dup = hm_new();
var dj_dup_keys: i32[>..<];
var dj_dup_key_set = hm_new();
fn dj_dup_get(bb: i32, ns: i32) -> i32 { hm_get(dj_dup, hk2(bb, ns), -1) as i32 }
fn dj_dup_put(bb: i32, ns: i32, nb: i32) {
    hm_put(dj_dup, hk2(bb, ns), nb as i64);
    if !hm_has(dj_dup_key_set, (bb as i64) as u64) { hm_put(dj_dup_key_set, (bb as i64) as u64, 1); dj_dup_keys.push(bb); }
}
fn dj_dup_clear() { hm_clear(dj_dup); hm_clear(dj_dup_key_set); dj_dup_keys.clear(); }

fn dj_block_size(bb: i32) -> i64 { var n: i64 = 0; var i = block_first(bb); while i >= 0 { n++; i = inst_next(i); } return n; }
fn dj_path_at(p: i32, k: i64) -> i32 { dj_pb[dj_pat[p] + k] }
fn dj_path_len(p: i32) -> i64 { dj_plen[p] as i64 }
fn dj_path_find(p: i32, from: i64, b: i32) -> i64 {
    for k in from..dj_path_len(p) { if dj_path_at(p, k) == b { return k; } }
    return dj_path_len(p);
}

// CodeMetrics::collectEphemeralValues(F, AC, EphValues) into cm_eph
fn dj_collect_ephemeral_values(fv: i32) {
    hm_clear(cm_eph);
    hm_clear(cm_visited);
    var wl: i32[>..<] = [];
    fn append_spec_operands(v: i32) {
        for k in nops(v) {
            let o = op(v, k);
            if hm_has(cm_visited, (o as i64) as u64) { continue; }
            hm_put(cm_visited, (o as i64) as u64, 1);
            if is_inst(o) && !inst_may_have_side_effects(o) && !is_terminator(o) { wl.push(o); }
        }
    }
    var asms: i32[>..<] = [];
    ac_assumptions(fv, asms);
    for a in asms {
        if !hm_has(cm_eph, (a as i64) as u64) { hm_put(cm_eph, (a as i64) as u64, 1); append_spec_operands(a); }
    }
    var k: i64 = 0;
    while k < wl.len {
        let v = wl[k];
        k++;
        var all = true;
        var u = vals[v].first_use;
        while u >= 0 { if !hm_has(cm_eph, (uses[u].user as i64) as u64) { all = false; break; } u = uses[u].next; }
        if !all { continue; }
        hm_put(cm_eph, (v as i64) as u64, 1);
        append_spec_operands(v);
    }
}

// cl::opt<double> dfa-max-cloned-rate (decimal digits with an optional fraction)
fn dj_max_cloned_rate() -> f64 {
    if !flag_given("dfa-max-cloned-rate") { return 7.5; }
    let s = flag_str("dfa-max-cloned-rate");
    var r: f64 = 0.0;
    var scale: f64 = 0.0;
    for c in s {
        if c == '.' && scale == 0.0 { scale = 1.0; continue; }
        if c < '0' || c > '9' { fatal("dfa-jump-threading: -dfa-max-cloned-rate: expected a decimal number"); }
        if scale == 0.0 { r = r * 10.0 + ((c - '0') as f64); }
        else { scale = scale / 10.0; r = r + ((c - '0') as f64) * scale; }
    }
    return r;
}

// isLegalAndProfitableToTransform
fn dj_is_legal_and_profitable() -> bool {
    let sw = dj_sw;
    tti_init_function(inst_func(sw), globs[glob_of(inst_func(sw))].module);
    if term_nsucc(sw) <= 1 { return false; }
    var cm = CodeMetricsInfo { num_insts: 0, num_inline_candidates: 0, not_duplicatable: false, convergence: CK_NONE, num_calls: 0 };
    var ncloned: i64 = 0;
    dj_dup_clear();
    for tp in dj_tp {
        let ns = dj_pexit[tp];
        let det = dj_pdet[tp];
        var bb = dj_swbb;
        if dj_dup_get(bb, ns) < 0 {
            cm_analyze_basic_block(cm, bb, false, -1);
            ncloned += dj_block_size(bb);
            dj_dup_put(bb, ns, bb);
        }
        if dj_path_at(tp, 0) == det { continue; }
        for k in dj_path_find(tp, 0, det)..dj_path_len(tp) {
            bb = dj_path_at(tp, k);
            if dj_dup_get(bb, ns) >= 0 { continue; }
            cm_analyze_basic_block(cm, bb, false, -1);
            ncloned += dj_block_size(bb);
            dj_dup_put(bb, ns, bb);
        }
        if cm.not_duplicatable { return false; }
        if cm.convergence != CK_NONE { return false; }
        if !tc_valid(cm.num_insts) { return false; }
    }
    var norig: i64 = 0;
    var nouter: i64 = 0;
    for bb in dj_dup_keys {
        norig += dj_block_size(bb);
        for k in block_nsucc(bb) {
            let s = block_succ(bb, k);
            if !hm_has(dj_dup_key_set, (s as i64) as u64) && single_pred(s) >= 0 { nouter++; }
        }
    }
    if (ncloned as f64) / (norig as f64) > dj_max_cloned_rate() { return false; }
    if nouter > flag_int("dfa-max-out-use-blocks", 40) { return false; }
    let clusters, jts = tti_case_clusters(sw, false, false);
    var cost: i64 = 0;
    if jts == 0 {
        // APInt(32, NumSuccessors).ceilLogBase2()
        let n = term_nsucc(sw);
        var cb: i64 = 0;
        while ((1 as i64) << cb) < n { cb++; }
        cost = cm.num_insts / cb;
    } else {
        cost = cm.num_insts / jts;
    }
    if cost > flag_int("dfa-cost-threshold", 50) { return false; }
    return true;
}

// createAllExitPaths
var dj_clean: i32[>..<];        // BlocksToClean (cleanPhiNodes doesn't depend on the order)
var dj_clean_set = hm_new();
var dj_nd_key: i32[>..<];       // NewDefs keys in insertion order
var dj_nd_head: i32[>..<];
var dj_nd_tail: i32[>..<];
var dj_nd_index = hm_new();     // original -> row
var dj_nd_val: i32[>..<];
var dj_nd_next: i32[>..<];
fn dj_clean_add(b: i32) { if !hm_has(dj_clean_set, (b as i64) as u64) { hm_put(dj_clean_set, (b as i64) as u64, 1); dj_clean.push(b); } }

fn dj_create_all_exit_paths(fv: i32) {
    // the switch block goes in front of every path (a placeholder)
    for k in dj_tp.len {
        let p = dj_tp[k];
        dj_tp[k] = dj_new_path(p, dj_swbb, -1, dj_pexit[p]);
    }
    dj_dup_clear();
    dj_nd_key.clear(); dj_nd_head.clear(); dj_nd_tail.clear(); hm_clear(dj_nd_index); dj_nd_val.clear(); dj_nd_next.clear();
    dj_clean.clear(); hm_clear(dj_clean_set);
    for k in block_nsucc(dj_swbb) { dj_clean_add(block_succ(dj_swbb, k)); }
    for p in dj_tp { dj_create_exit_path(fv, p); }
    for p in dj_tp { dj_update_last_successor(p); }
    dj_update_ssa(fv);
    for b in dj_clean { dj_clean_phi_nodes(b); }
}

// createExitPath
fn dj_create_exit_path(fv: i32, p: i32) {
    let ns = dj_pexit[p];
    let det = dj_pdet[p];
    var from: i64 = 0;
    if dj_path_at(p, 0) == det { from = 1; }
    let n = dj_path_len(p) - from;
    let di = dj_path_find(p, from, det);
    if di >= dj_path_len(p) || (n != 1 && di == from) { fatal("internal: dfa-jump-threading: determinator not inside the path"); }
    var prev = if n == 1 { dj_path_at(p, di) } else { dj_path_at(p, di - 1) };
    for k in di..dj_path_len(p) {
        let bb = dj_path_at(p, k);
        dj_clean_add(bb);
        let nx = dj_dup_get(bb, ns);
        if nx >= 0 {
            dj_update_predecessor(prev, bb, nx);
            prev = nx;
            continue;
        }
        let nb = dj_clone_block_and_update_predecessor(fv, bb, prev, ns);
        dj_dup_put(bb, ns, nb);
        dj_clean_add(nb);
        prev = nb;
    }
}

// APInt::getLimitedValue()
fn dj_limited_value(c: i32) -> u64 {
    let a = ap_from_cint(c);
    if ap_active_bits(a) > 64 { return 0xFFFFFFFFFFFFFFFF; }
    return a.lo;
}

// cloneBlockAndUpdatePredecessor
fn dj_clone_block_and_update_predecessor(fv: i32, bb: i32, prev: i32, ns: i32) -> i32 {
    let mark = vmm_mark();
    let m = vmm_new();
    var suffix: u8[>..] = [];
    suffix.append(".jt");
    suffix.append(str(dj_limited_value(ns)));
    let nb = clone_basic_block(bb, m, suffix, fv, false);
    block_move_after(nb, bb);
    var scopes: i32[>..<] = [];
    identify_noalias_scopes_to_clone([nb], scopes);
    clone_and_adapt_noalias_scopes(scopes, [nb], "dfa");
    var i = block_first(nb);
    while i >= 0 {
        if iop(i) != OP_PHI {
            remap_instruction(i, m, RF_IGNORE_MISSING_LOCALS | RF_NO_MODULE_LEVEL_CHANGES);
            if inst_iid(i) == IID_assume { ac_register_assumption(i); }
        }
        i = inst_next(i);
    }
    dj_update_successor_phis(bb, nb, ns, m);
    dj_update_predecessor(prev, bb, nb);
    dj_update_def_map(bb, nb);
    var seen: i32[>..<] = [];
    for k in block_nsucc(nb) {
        let s = block_succ(nb, k);
        var dup = false;
        for x in seen { if x == s { dup = true; } }
        if dup { continue; }
        seen.push(s);
        dtu_apply_updates([DTUpdate { kind: DT_INSERT, from: nb, to: s }]);
    }
    vmm_release(mark);
    return nb;
}

// updateSuccessorPhis
fn dj_update_successor_phis(bb: i32, cb: i32, ns: i32, m: i32) {
    var todo: i32[>..<] = [];
    if bb == dj_swbb {
        let nc = dj_next_case_successor(dj_sw, ns);
        todo.push(nc);
        let cs = dj_dup_get(nc, ns);
        if cs >= 0 { todo.push(cs); }
    } else {
        for k in block_nsucc(bb) {
            let s = block_succ(bb, k);
            todo.push(s);
            let cs = dj_dup_get(s, ns);
            if cs >= 0 { todo.push(cs); }
        }
    }
    for s in todo {
        var p = block_first(s);
        while p >= 0 && iop(p) == OP_PHI {
            let idx = phi_block_index(p, bb);
            if idx >= 0 {
                let inc = phi_value(p, idx);
                if is_constant(inc) { phi_add_incoming(p, inc, cb); }
                else {
                    let cv = vmm_get(m, inc);
                    phi_add_incoming(p, if cv >= 0 { cv } else { inc }, cb);
                }
            }
            p = inst_next(p);
        }
    }
}

fn dj_is_predecessor(bb: i32, inc: i32) -> bool {
    var r = false;
    each_pred(bb) { p => if p == inc { r = true; } };
    return r;
}

// updatePredecessor
fn dj_update_predecessor(prev: i32, old: i32, nw: i32) {
    if !dj_is_predecessor(old, prev) { return; }
    let t = block_terminator(prev);
    for k in term_nsucc(t) {
        if term_succ(t, k) == old {
            block_remove_predecessor(old, prev, true);
            term_set_succ(t, k, nw);
        }
    }
    dtu_apply_updates([DTUpdate { kind: DT_DELETE, from: prev, to: old }, DTUpdate { kind: DT_INSERT, from: prev, to: nw }]);
}

// updateDefMap: the clones of one block, in the original's instruction order
fn dj_update_def_map(bb: i32, nb: i32) {
    var i = block_first(bb);
    var ni = block_first(nb);
    while i >= 0 {
        let o = iop(i);
        if o != OP_BR && o != OP_CONDBR && o != OP_SWITCH {
            var r = hm_get(dj_nd_index, (i as i64) as u64, -1);
            if r < 0 {
                dj_nd_key.push(i); dj_nd_head.push(-1); dj_nd_tail.push(-1);
                r = dj_nd_key.len - 1;
                hm_put(dj_nd_index, (i as i64) as u64, r);
            }
            let c = dj_nd_val.len as i32;
            dj_nd_val.push(ni); dj_nd_next.push(-1);
            if dj_nd_tail[r] >= 0 { dj_nd_next[dj_nd_tail[r]] = c; } else { dj_nd_head[r] = c; }
            dj_nd_tail[r] = c;
        }
        i = inst_next(i);
        ni = inst_next(ni);
    }
}

// updateLastSuccessor
fn dj_update_last_successor(p: i32) {
    let ns = dj_pexit[p];
    let bb = dj_path_at(p, dj_path_len(p) - 1);
    let lb = dj_dup_get(bb, ns);
    let sw = block_terminator(lb);
    if iop(sw) != OP_SWITCH { return; }
    let nc = dj_next_case_successor(sw, ns);
    var ups: DTUpdate[>..<] = [];
    var seen: i32[>..<] = [];
    for k in term_nsucc(sw) {
        let s = term_succ(sw, k);
        if s == nc { continue; }
        var dup = false;
        for x in seen { if x == s { dup = true; } }
        if dup { continue; }
        seen.push(s);
        ups.push(DTUpdate { kind: DT_DELETE, from: lb, to: s });
    }
    let loc = inst_get_md(sw, 0);
    inst_erase_from_parent(sw);
    let br = create_inst(OP_BR, T_VOID, [nc]);
    block_append_inst(lb, br);
    dj_set_loc(br, loc);
    dtu_apply_updates(ups);
}

// updateSSA
fn dj_update_ssa(fv: i32) {
    sbu_begin();
    var to_rename: i32[>..<] = [];
    for r in dj_nd_key.len {
        let i = dj_nd_key[r];
        let bb = inst_parent(i);
        var u = vals[i].first_use;
        while u >= 0 {
            let usr = uses[u].user;
            if iop(usr) == OP_PHI {
                if phi_block(usr, (u - vals[usr].ops) as i64) != bb { to_rename.push(u); }
            } else if inst_parent(usr) != bb {
                to_rename.push(u);
            }
            u = uses[u].next;
        }
        if to_rename.len == 0 { continue; }
        let var_ = sbu_add_variable(vals[i].name, vals[i].ty);
        sbu_add_available_value(var_, bb, i);
        var c = dj_nd_head[r];
        while c >= 0 { let x = dj_nd_val[c]; sbu_add_available_value(var_, inst_parent(x), x); c = dj_nd_next[c]; }
        while to_rename.len > 0 { sbu_add_use(var_, to_rename.pop()); }
    }
    dtu_get_dt();
    sbu_rewrite_all_uses(fv);
}

// cleanPhiNodes
fn dj_clean_phi_nodes(bb: i32) {
    if pred_count(bb) == 0 {
        var p = block_first(bb);
        while p >= 0 && iop(p) == OP_PHI {
            let np = inst_next(p);
            rauw(p, c_poison(vals[p].ty));
            inst_erase_from_parent(p);
            p = np;
        }
        return;
    }
    var p = block_first(bb);
    while p >= 0 && iop(p) == OP_PHI {
        let np = inst_next(p);
        // removeIncomingValueIf: backwards, each removed entry takes the current last one
        var k = phi_nincoming(p);
        while k > 0 {
            k--;
            if !dj_is_predecessor(bb, phi_block(p, k)) { phi_remove_incoming(p, k); }
        }
        if nops(p) == 0 {
            rauw(p, c_poison(vals[p].ty));
            inst_erase_from_parent(p);
        }
        p = np;
    }
}
