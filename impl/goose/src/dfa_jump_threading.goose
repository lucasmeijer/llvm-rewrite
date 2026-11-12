// DFAJumpThreading: the analysis part of llvm/lib/Transforms/Scalar/DFAJumpThreading.cpp (DFAJumpThreading::run,
// MainSwitch::isCandidate / isValidSelectInst, AllSwitchPaths::findTPaths with getStateDefMap,
// getPathsFromStateDefMap and paths). The transformation (unfoldSelectInstrs, TransformDFA with SSAUpdaterBulk) is
// not ported: a candidate switch with selects to unfold or with threading paths fails loudly; every other function
// is left unchanged, as LLVM leaves it.
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import flags;
import loopinfo;
import gen_attrs;

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

fn dfa_jump_threading_run(fv: i32) -> u32 {
    if func_has_fn_attr(fv, AK_OptimizeForSize) || func_has_fn_attr(fv, AK_MinSize) { return PA_ALL; }
    li_get(fv);
    var bb = func_first_block(fv);
    while bb >= 0 {
        let t = block_terminator(bb);
        if t >= 0 && iop(t) == OP_SWITCH && dj_is_candidate(t) {
            if dj_sels.len > 0 { fatal("dfa-jump-threading: unfolding selects of a candidate switch is not ported yet"); }
            if dj_num_threading_paths(t) > 0 { fatal("dfa-jump-threading: threading a switch with threading paths is not ported yet"); }
        }
        bb = block_next(bb);
    }
    return PA_ALL;
}

// ---------------------------------------------------------------------------------------------
// AllSwitchPaths: paths are immutable runs in dj_pb (dj_pat/dj_plen), with a determinator and an exit value for
// ThreadingPaths; the recursive functions return their result path ids as a range at the top of dj_stk.

var dj_pb: i32[>..<];
var dj_pat: i32[>..<];
var dj_plen: i32[>..<];
var dj_pexit: i32[>..<];
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
            dj_pat.push(at); dj_plen.push(2); dj_pexit.push(-1);
            dj_stk.push(dj_pat.len as i32 - 1);
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
            if ib != dj_swbb {
                if dj_vb_has(ib) { continue; }
                let at = dj_pb.len as i32;
                dj_pb.push(ib); dj_pb.push(phibb);
                dj_pat.push(at); dj_plen.push(2); dj_pexit.push(iv);
            } else {
                let at = dj_pb.len as i32;
                dj_pb.push(phibb);
                dj_pat.push(at); dj_plen.push(1); dj_pexit.push(iv);
            }
            dj_stk.push(dj_pat.len as i32 - 1);
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

// AllSwitchPaths::run: the number of threading paths (unifyTPaths doesn't change it)
fn dj_num_threading_paths(sw: i32) -> i64 {
    dj_sw = sw;
    dj_swbb = inst_parent(sw);
    var l = li_loop_for(dj_swbb);
    while loop_parent(l) >= 0 { l = loop_parent(l); }
    dj_outer = l;
    dj_max_len = flag_int("dfa-max-path-length", 20);
    dj_max_visited = flag_int("dfa-max-num-visited-paths", 2500);
    let max_paths = flag_int("dfa-max-num-paths", 200);
    dj_visited_n = 0;
    dj_pb.clear(); dj_pat.clear(); dj_plen.clear(); dj_pexit.clear(); dj_stk.clear(); dj_vb.clear(); dj_uniq.clear();
    dj_state_def_map();
    var any = false;
    for b in dj_sd_bb { if b >= 0 { any = true; } }
    if !any { return 0; }
    let sphi = op(sw, 0);
    let sdef = inst_parent(sphi);
    dj_paths_from_state_def(sphi, max_paths);
    let n_to_def = dj_stk.len;
    if sdef == dj_swbb || n_to_def == 0 { return n_to_def; }
    let plimit = max_paths / n_to_def;
    dj_paths(sdef, dj_swbb, 1, plimit);
    let ne = dj_stk.len;
    if ne == n_to_def { return 0; }
    var count: i64 = 0;
    for j in 0..n_to_def {
        let p = dj_stk[j];
        for q in n_to_def..ne {
            let ps = dj_stk[q];
            var clash = false;
            for k in 1..dj_plen[ps] as i64 {
                let b = dj_pb[dj_pat[ps] + k];
                for m in dj_plen[p] as i64 { if dj_pb[dj_pat[p] + m] == b { clash = true; } }
            }
            if !clash { count++; }
        }
    }
    return count;
}
