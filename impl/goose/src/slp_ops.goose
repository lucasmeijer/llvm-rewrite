// SLPVectorizer: BoUpSLP::LookAheadHeuristics, BoUpSLP::VLOperands and findBestRootPair. Port of
// llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp lines 2470-3700 (getShallowScore, getScoreAtLevelRec,
// getSplatScore, getExternalUseScore, getLookAheadScore, getBestOperand, getBestLaneToStartReordering,
// getMaxNumOperandsThatCanBeReordered, appendOperands, shouldBroadcast, canBeVectorized, reorder) and the X86 /
// base TTI legality queries they ask.
//
// VLOperands lives in locals of slp_vlops_reorder (it never outlives one reordering); the operands come from and go
// back to runs of the value pool.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import pm;
import vt;
import laa;
import scev;
import loopinfo;
import tti;
import tti_x86;
import tti_x86_vec;
import slp_util;
import slp_tree;

// ---------------------------------------------------------------- TTI legality queries (X86TTIImpl / NoTTIImpl)
fn slp_tti_legal_broadcast_load(elt: i32, n: i64) -> bool { if tti_kind == TTI_X86 { x86_is_legal_broadcast_load(elt, n) } else { false } }
fn slp_tti_legal_masked_gather(vt: i32) -> bool { if tti_kind == TTI_X86 { x86_is_legal_masked_gather(vt) } else { false } }
fn slp_tti_force_scalarize_masked_gather(vt: i32) -> bool { if tti_kind == TTI_X86 { x86_force_scalarize_masked_gather(vt) } else { false } }
fn slp_tti_legal_masked_load(vt: i32) -> bool { if tti_kind == TTI_X86 { x86_is_legal_masked_load(vt) } else { false } }
fn slp_tti_legal_masked_store(vt: i32) -> bool { if tti_kind == TTI_X86 { x86_is_legal_masked_store(vt) } else { false } }
fn slp_tti_prefer_alternate_opcode_vectorization() -> bool { tti_kind != TTI_X86 }
fn slp_tti_legal_alt_instr(vt: i32, o0: i64, o1: i64, mask: const bool[:]) -> bool {
    if tti_kind != TTI_X86 { return false; }
    let m = mk_mark();
    let ms = mk_pool.len;
    for b in mask { mk_pool.push(if b { 1 } else { 0 }); }
    let r = x86_is_legal_alt_instr(vt, o0, o1, ms);
    mk_release(m);
    return r;
}

// ---------------------------------------------------------------- LookAheadHeuristics
let LA_CONSECUTIVE_LOADS: i64 = 40;
let LA_SPLAT_LOADS: i64 = 30;
let LA_REVERSED_LOADS: i64 = 30;
let LA_MASKED_GATHER: i64 = 10;
let LA_CONSECUTIVE_EXTRACTS: i64 = 40;
let LA_REVERSED_EXTRACTS: i64 = 30;
let LA_CONSTANTS: i64 = 15;
let LA_SAME_CONSTANTS: i64 = 17;
let LA_SAME_OPCODE: i64 = 20;
let LA_ALT_OPCODES: i64 = 10;
let LA_SPLAT: i64 = 10;
let LA_UNDEF: i64 = 10;
let LA_FAIL: i64 = 0;
let LA_ALL_USERS_VECTORIZED: i64 = 10;
fn slp_lookahead_max_depth() -> i64 { flag_int("slp-max-look-ahead-depth", 2) }
fn slp_root_lookahead_max_depth() -> i64 { flag_int("slp-max-root-look-ahead-depth", 2) }

// getShallowScore(V1, V2, U1, U2, MainAltOps): main_alt is MainAltOps (at most 2 values)
fn slp_shallow_score(v1: i32, v2: i32, u1: i32, u2: i32, main_alt: const i32[:], nlanes: i64) -> i64 {
    if !slp_is_valid_element_type(vals[v1].ty) || !slp_is_valid_element_type(vals[v2].ty) { return LA_FAIL; }
    if v1 == v2 {
        if is_inst_op(v1, OP_LOAD) {
            fn all_users_vectorized(v: i32, u1: i32, u2: i32) -> bool {
                var u = vals[v].first_use;
                while u >= 0 {
                    let usr = uses[u].user;
                    if !(usr == u1 || usr == u2 || slp_is_vectorized(usr)) { return false; }
                    u = uses[u].next;
                }
                return true;
            }
            if slp_tti_legal_broadcast_load(vals[v1].ty, nlanes) {
                if slp_num_uses(v1) == nlanes { return LA_SPLAT_LOADS; }
                if !slp_has_n_uses_or_more(v1, SLP_USES_LIMIT) && !slp_has_n_uses_or_more(v2, SLP_USES_LIMIT) &&
                   all_users_vectorized(v1, u1, u2) && all_users_vectorized(v2, u1, u2) { return LA_SPLAT_LOADS; }
            }
        }
        if is_undef_or_poison(v1) { return LA_UNDEF; }
        if slp_is_constant(v1) { return LA_SAME_CONSTANTS; }
        return LA_SPLAT;
    }
    fn same_entry_or_fail(v1: i32, v2: i32) -> i64 {
        var c1 = slp_tree_entries_head(v1);
        if c1 < 0 { return LA_FAIL; }
        var c2 = slp_tree_entries_head(v2);
        while c2 >= 0 {
            let e = slp_lk[c2].x;
            var c = c1;
            while c >= 0 { if slp_lk[c].x == e { return LA_SPLAT_LOADS; } c = slp_lk[c].next; }
            c2 = slp_lk[c2].next;
        }
        return LA_FAIL;
    }
    let l1 = is_inst_op(v1, OP_LOAD);
    let l2 = is_inst_op(v2, OP_LOAD);
    if l1 && l2 {
        if inst_parent(v1) != inst_parent(v2) || !ld_is_simple(v1) || !ld_is_simple(v2) { return same_entry_or_fail(v1, v2); }
        let ok, dist = laa_get_pointers_diff(vals[v1].ty, op(v1, 0), vals[v2].ty, op(v2, 0), true, true);
        if !ok || dist == 0 {
            if get_underlying_object(op(v1, 0), 6) == get_underlying_object(op(v2, 0), 6) &&
               slp_tti_legal_masked_gather(slp_widened_type(vals[v1].ty, nlanes)) { return LA_MASKED_GATHER; }
            return same_entry_or_fail(v1, v2);
        }
        let ad = if dist < 0 { -dist } else { dist };
        if ad > nlanes / 2 { return LA_MASKED_GATHER; }
        return if dist > 0 { LA_CONSECUTIVE_LOADS } else { LA_REVERSED_LOADS };
    }
    let c1 = is_constant(v1);
    let c2 = is_constant(v2);
    if c1 && c2 { return LA_CONSTANTS; }
    if (c1 && is_inst_op(v2, OP_INSERTELEMENT)) || (c2 && is_inst_op(v1, OP_INSERTELEMENT)) { return LA_SAME_OPCODE; }
    if is_inst_op(v1, OP_EXTRACTELEMENT) && is_cint(op(v1, 1)) {
        let ev1 = op(v1, 0);
        if is_undef_or_poison(v2) {
            return if is_poison(v2) || slp_is_undef_vector_all(ev1, false) { LA_CONSECUTIVE_EXTRACTS } else { LA_SAME_OPCODE };
        }
        if is_inst_op(v2, OP_EXTRACTELEMENT) && (is_cint(op(v2, 1)) || is_undef_or_poison(op(v2, 1))) {
            if !is_cint(op(v2, 1)) { return LA_CONSECUTIVE_EXTRACTS; }
            let ev2 = op(v2, 0);
            if slp_is_undef_vector_all(ev2, false) && vals[ev2].ty as i32 == vals[ev1].ty as i32 { return LA_CONSECUTIVE_EXTRACTS; }
            if ev2 == ev1 {
                let i1 = cint_lo(op(v1, 1)) as i64;
                let i2 = cint_lo(op(v2, 1)) as i64;
                let d = i2 - i1;
                let ad = if d < 0 { -d } else { d };
                if ad == 0 { return LA_SPLAT; }
                if ad > nlanes / 2 { return LA_SAME_OPCODE; }
                return if d > 0 { LA_CONSECUTIVE_EXTRACTS } else { LA_REVERSED_EXTRACTS };
            }
            return LA_ALT_OPCODES;
        }
        return same_entry_or_fail(v1, v2);
    }
    let i1 = is_inst(v1);
    let i2 = is_inst(v2);
    if i1 && i2 {
        if inst_parent(v1) != inst_parent(v2) { return same_entry_or_fail(v1, v2); }
        if (iop(v1) == OP_ZEXT && iop(v2) == OP_SELECT && vals[op(v1, 0)].ty as i32 == vals[op(v2, 0)].ty as i32) ||
           (iop(v2) == OP_ZEXT && iop(v1) == OP_SELECT && vals[op(v2, 0)].ty as i32 == vals[op(v1, 0)].ty as i32) {
            return LA_SAME_OPCODE;
        }
        var ops: i32[4] = [0, 0, 0, 0];
        for k in main_alt.len { ops[k] = main_alt[k]; }
        ops[main_alt.len] = v1;
        ops[main_alt.len + 1] = v2;
        let n = main_alt.len + 2;
        let s = slp_get_same_opcode(ops[..n]);
        if sis_valid(s) && (nops(s.main) <= 2 || main_alt.len > 0 || !sis_is_alt_shuffle(s)) {
            var ok = true;
            for k in n { let v = ops[k]; if !is_poison(v) && nops(v) != nops(s.main) { ok = false; break; } }
            if ok { return if sis_is_alt_shuffle(s) { LA_ALT_OPCODES } else { LA_SAME_OPCODE }; }
        }
    }
    if i1 && is_poison(v2) { return LA_SAME_OPCODE; }
    if is_undef_or_poison(v2) { return LA_UNDEF; }
    return same_entry_or_fail(v1, v2);
}
// getScoreAtLevelRec(LHS, RHS, U1, U2, CurrLevel, MainAltOps)
recursive fn slp_score_at_level(lhs: i32, rhs: i32, u1: i32, u2: i32, level: i64, max_level: i64, main_alt: const i32[:],
                                nlanes: i64) -> i64 {
    var shallow = slp_shallow_score(lhs, rhs, u1, u2, main_alt, nlanes);
    let ii1 = is_inst(lhs);
    let ii2 = is_inst(rhs);
    if level == max_level || !(ii1 && ii2) || lhs == rhs || shallow == LA_FAIL { return shallow; }
    if ((iop(lhs) == OP_LOAD && iop(rhs) == OP_LOAD) || (nops(lhs) > 2 && nops(rhs) > 2) ||
        (iop(lhs) == OP_EXTRACTELEMENT && iop(rhs) == OP_EXTRACTELEMENT)) && shallow != 0 { return shallow; }
    if nops(lhs) != nops(rhs) { return LA_SAME_OPCODE; }
    if nops(rhs) > 64 { slp_fail("look-ahead scores of instructions with more than 64 operands"); }
    var used: u64 = 0;
    let comm2 = slp_is_commutative(rhs);
    for o1 in nops(lhs) {
        var max_tmp: i64 = 0;
        var max_o2: i64 = 0;
        var found = false;
        let from = if comm2 { 0 } else { o1 };
        let to = if comm2 { nops(rhs) } else { if nops(rhs) < o1 + 1 { nops(rhs) } else { o1 + 1 } };
        var o2 = from;
        while o2 != to {
            if (used & ((1 as u64) << (o2 as u64))) != 0 { o2++; continue; }
            let empty: i32[1] = [0];
            let tmp = slp_score_at_level(op(lhs, o1), op(rhs, o2), lhs, rhs, level + 1, max_level, empty[..0], nlanes);
            if tmp > LA_FAIL && tmp > max_tmp { max_tmp = tmp; max_o2 = o2; found = true; }
            o2++;
        }
        if found {
            used |= (1 as u64) << (max_o2 as u64);
            shallow += max_tmp;
        }
    }
    return shallow;
}
// findBestRootPair(Candidates, Limit): (index or -1, best score)
fn slp_find_best_root_pair(ca: const i32[:], cb: const i32[:], limit: i64) -> i64, i64 {
    var best = limit;
    var idx: i64 = -1;
    let md = slp_root_lookahead_max_depth();
    for i in ca.len {
        let empty: i32[1] = [0];
        let sc = slp_score_at_level(ca[i], cb[i], -1, -1, 1, md, empty[..0], 2);
        if sc > best { best = sc; idx = i; }
    }
    return idx, best;
}

// ---------------------------------------------------------------- VLOperands
// ReorderingMode
let RM_LOAD: i64 = 0;
let RM_OPCODE: i64 = 1;
let RM_CONSTANT: i64 = 2;
let RM_SPLAT: i64 = 3;
let RM_FAILED: i64 = 4;

fn slp_loop_invariant(l: i32, v: i32) -> bool { !is_inst(v) || !loop_contains(l, inst_parent(v)) }

// VLOperands(VL, Operands, S, R).reorder() and getVL(0) / getVL(1) written back into the first two operand runs
// `opl` (runs of slp_vp; Operands.size() lists)
fn slp_vlops_reorder(vl: const i32[:], opl: i32, nopl: i64, s: SIS) {
    let main = s.main;
    let nlanes = vl.len;
    let argsz = slp_num_potentially_commutative_ops(main);
    let nmain = nops(main);
    let l = li_loop_for(inst_parent(main));
    // OpsVec[OpIdx][Lane] = (V, APO, IsUsed) at OpIdx * nlanes + Lane
    var ov: i32[>..<] = [];
    var apo: bool[>..<] = [];
    var isused: bool[>..<] = [];
    for k in argsz * nlanes { ov.push(0); apo.push(false); isused.push(false); }
    fn opv(oi: i64, lane: i64) -> i32 { let r = slp_opl[opl as i64 + oi]; return slp_vp[r.at as i64 + lane]; }
    // appendOperands
    for lane in nlanes {
        let v = vl[lane];
        if !is_inst(v) && is_poison(v) {
            for oi in nmain {
                if oi < argsz { ov[oi * nlanes + lane] = opv(oi, lane); apo[oi * nlanes + lane] = true; isused[oi * nlanes + lane] = false; }
            }
            continue;
        }
        var inverse = false;
        if sis_is_copyable_element(s, v) {
            inverse = !slp_is_commutative_vu(main, v, true);
        } else {
            let sel, a, b = slp_convert_to(v, s);
            inverse = !slp_is_commutative_vu(sel, v, false);
        }
        for oi in argsz {
            ov[oi * nlanes + lane] = opv(oi, lane);
            apo[oi * nlanes + lane] = if oi == 0 { false } else { inverse };
            isused[oi * nlanes + lane] = false;
        }
    }
    let nops_ = argsz;
    fn gv(oi: i64, lane: i64) -> i32 { ov[oi * nlanes + lane] }
    fn swap_(a: i64, b: i64, lane: i64) {
        let x = a * nlanes + lane;
        let y = b * nlanes + lane;
        let tv = ov[x]; ov[x] = ov[y]; ov[y] = tv;
        let ta = apo[x]; apo[x] = apo[y]; apo[y] = ta;
        let tu = isused[x]; isused[x] = isused[y]; isused[y] = tu;
    }
    fn clear_used() { for k in isused.len { isused[k] = false; } }
    // BestScoresPerLanes
    var best_scores: i64[>..<] = [];
    for k in nops_ * nlanes { best_scores.push(0); }
    // getSplatScore(Lane, OpIdx, Idx, UsedLanes)
    fn splat_score(lane: i64, opidx: i64, idx: i64, used_lanes: const bool[:]) -> i64 {
        let ilv = gv(idx, lane);
        if !is_inst(ilv) || ilv == gv(opidx, lane) || iop(ilv) == OP_EXTRACTELEMENT { return 0; }
        var uv: i32[>..<] = [];
        var ul: i64[>..<] = [];
        for ln in nlanes {
            if ln == lane { continue; }
            let x = gv(opidx, ln);
            if !is_inst(x) { return 0; }
            var seen = false;
            for y in uv { if y == x { seen = true; break; } }
            if !seen { uv.push(x); ul.push(ln); }
        }
        let cnt = uv.len;
        var idx_it: i64 = -1;
        for k in uv.len { if uv[k] == ilv { idx_it = k; break; } }
        let with_idx = if idx_it >= 0 { cnt } else { cnt + 1 };
        let olv = gv(opidx, lane);
        var op_it: i64 = -1;
        for k in uv.len { if uv[k] == olv { op_it = k; break; } }
        let with_op = if op_it >= 0 { cnt } else { cnt + 1 };
        if with_idx == with_op { return 0; }
        let a = slp_bit_ceil(with_op) - with_op;
        let b = with_op - slp_bit_floor(with_op);
        let m = if a < b { a } else { b };
        let sub = if idx_it >= 0 && used_lanes[ul[idx_it]] { with_idx - slp_bit_floor(with_idx) } else { slp_bit_ceil(with_idx) - with_idx };
        return m - sub;
    }
    // getExternalUseScore(Lane, OpIdx, Idx)
    fn external_use_score(lane: i64, opidx: i64, idx: i64) -> i64 {
        let ilv = gv(idx, lane);
        let olv = gv(opidx, lane);
        if slp_is_vector_like_inst_with_const_ops(ilv) && slp_is_vector_like_inst_with_const_ops(olv) { return LA_ALL_USERS_VECTORIZED; }
        if !is_inst(ilv) || !is_inst(olv) { return 0; }
        return if slp_are_all_users_vectorized(ilv, false) { LA_ALL_USERS_VECTORIZED } else { 0 };
    }
    let la_depth = slp_lookahead_max_depth();
    // getLookAheadScore(LHS, RHS, MainAltOps, Lane, OpIdx, Idx, IsUsed, UsedLanes)
    fn lookahead_score(lhs: i32, rhs: i32, main_alt: const i32[:], lane: i64, opidx: i64, idx: i64, used_lanes: const bool[:]) -> i64, bool {
        var score = slp_score_at_level(lhs, rhs, -1, -1, 1, la_depth, main_alt, nlanes);
        var used = false;
        if score != 0 {
            let ss = splat_score(lane, opidx, idx, used_lanes) * 10;
            if score <= -ss {
                score = 0;
            } else {
                score += ss;
                let sf: i64 = if lhs == rhs && slp_is_constant(lhs) { 6 } else { 10 };
                score *= sf;
                score += external_use_score(lane, opidx, idx);
                used = true;
            }
        }
        return score, used;
    }
    // getBestOperand(OpIdx, Lane, LastLane, ReorderingModes, MainAltOps, UsedLanes): -1 = none
    fn best_operand(opidx: i64, lane: i64, last_lane: i64, modes: const i64[:], main_alt: const i32[:], used_lanes: const bool[:]) -> i64 {
        let op_last = gv(opidx, last_lane);
        let rmode = modes[opidx];
        if rmode == RM_FAILED { return -1; }
        let opidx_apo = apo[opidx * nlanes + lane];
        var best_idx: i64 = -1;
        var best_score: i64 = best_scores[opidx * nlanes + lane];
        var is_used = rmode == RM_SPLAT || rmode == RM_CONSTANT || rmode == RM_LOAD;
        for idx in nops_ {
            let p = idx * nlanes + lane;
            let o = ov[p];
            if isused[p] { continue; }
            if apo[p] != opidx_apo { continue; }
            if rmode == RM_LOAD || rmode == RM_OPCODE {
                let ltr = lane > last_lane;
                let ol = if ltr { op_last } else { o };
                let orr = if ltr { o } else { op_last };
                let score, u = lookahead_score(ol, orr, main_alt, lane, opidx, idx, used_lanes);
                if u { is_used = true; }
                if score > best_score || (score > 0 && score == best_score && idx == opidx) {
                    best_idx = idx;
                    best_score = score;
                    best_scores[opidx * nlanes + lane] = score;
                }
            } else if rmode == RM_CONSTANT {
                if is_constant(o) || (best_score == 0 && l >= 0 && slp_loop_invariant(l, o)) {
                    best_idx = idx;
                    if is_constant(o) {
                        best_score = LA_CONSTANTS;
                        best_scores[opidx * nlanes + lane] = LA_CONSTANTS;
                    }
                    if is_undef_or_poison(o) || !is_constant(o) { is_used = false; }
                }
            } else if rmode == RM_SPLAT {
                if o == op_last || (best_score == 0 && is_constant(o)) {
                    is_used = o == op_last;
                    if o == op_last {
                        best_score = LA_SPLAT;
                        best_scores[opidx * nlanes + lane] = LA_SPLAT;
                    }
                    best_idx = idx;
                }
            }
        }
        if best_idx >= 0 {
            isused[best_idx * nlanes + lane] = is_used;
            return best_idx;
        }
        return -1;
    }
    // getMaxNumOperandsThatCanBeReordered(Lane): (NumOfAPOs, NumOpsWithSameOpcodeParent, hash)
    fn max_num_operands(lane: i64) -> i64, i64, u64 {
        var cnt_true: i64 = 0;
        var all_undefs = true;
        var nsame: i64 = 0;
        var opcode_i: i32 = -1;
        var parent: i32 = -1;
        var h: u64 = 0xcbf29ce484222325;
        for oi in nops_ {
            let p = oi * nlanes + lane;
            if apo[p] { cnt_true++; }
            let v = ov[p];
            if is_inst(v) {
                var same = false;
                if opcode_i >= 0 {
                    let s2 = slp_same_opcode2(opcode_i, v);
                    same = sis_valid(s2) && inst_parent(v) == parent;
                }
                if !same {
                    if nsame == 0 { nsame = 1; opcode_i = v; parent = inst_parent(v); } else { nsame--; }
                } else {
                    nsame++;
                }
            }
            h = (h ^ (((oi + 1) * (slp_value_id(v) + 1)) as u64)) * 0x100000001b3;
            all_undefs = all_undefs && is_undef_or_poison(v);
        }
        if all_undefs { return 0xFFFFFFFF, 0, 0; }
        let a = if cnt_true > nops_ - cnt_true { cnt_true } else { nops_ - cnt_true };
        return a, nsame, h;
    }
    // getBestLaneToStartReordering()
    fn best_lane_to_start() -> i64 {
        var mn: i64 = 0xFFFFFFFF;
        var same_n: i64 = 0;
        var hk: u64[>..<] = [];
        var hc: i64[>..<] = [];
        var hl: i64[>..<] = [];
        fn hm_find(h: u64) -> i64 { for k in hk.len { if hk[k] == h { return k; } } return -1; }
        fn hm_set(h: u64, c: i64, ln: i64) {
            let k = hm_find(h);
            if k >= 0 { hc[k] = c; hl[k] = ln; return; }
            hk.push(h); hc.push(c); hl.push(ln);
        }
        var i = nlanes;
        while i > 0 {
            let lane = i - 1;
            i--;
            let napos, nsame, h = max_num_operands(lane);
            if napos < mn {
                mn = napos;
                same_n = nsame;
                hk.clear(); hc.clear(); hl.clear();
                hm_set(h, 1, lane);
            } else if napos == mn && nsame < same_n {
                same_n = nsame;
                hm_set(h, 1, lane);
            } else if napos == mn && nsame == same_n {
                let k = hm_find(h);
                if k < 0 { hk.push(h); hc.push(1); hl.push(lane); } else { hc[k] += 1; }
            }
        }
        var best_lane: i64 = 0;
        var cnt_min: i64 = 0xFFFFFFFF;
        var k = hk.len;
        while k > 0 {
            k--;
            if hc[k] < cnt_min { cnt_min = hc[k]; best_lane = hl[k]; }
        }
        return best_lane;
    }
    // shouldBroadcast(Op, OpIdx, Lane)
    fn should_broadcast(o: i32, opidx: i64, lane: i64) -> bool {
        if is_inst_op(o, OP_LOAD) && nlanes == 2 && nops_ == 2 { return false; }
        let opapo = apo[opidx * nlanes + lane];
        let invariant = l >= 0 && slp_loop_invariant(l, o);
        var cnt: i64 = 0;
        for ln in nlanes {
            if ln == lane { continue; }
            var found = false;
            for opi in nops_ {
                let p = opi * nlanes + ln;
                if apo[p] != opapo || isused[p] { continue; }
                let dv = ov[p];
                let opilane = gv(opi, lane);
                let is_const_op = is_constant(opilane);
                var cand = dv == o;
                if !cand && !is_const_op {
                    if nlanes > 2 && is_constant(dv) { cand = true; }
                    else if nlanes == 2 && is_constant(dv) {
                        let s2 = slp_same_opcode2(o, gv((opi + 1) % nops_, ln));
                        if !sis_valid(s2) { cand = true; }
                    }
                }
                if !cand && invariant && !is_constant(dv) && slp_loop_invariant(l, dv) {
                    let s3 = slp_same_opcode2(o, dv);
                    if !sis_valid(s3) { cand = true; }
                }
                if cand {
                    found = true;
                    isused[p] = dv == o;
                    if dv == o { cnt++; }
                    break;
                }
            }
            if !found { return false; }
        }
        return nlanes == 2 || cnt > 1;
    }
    // canBeVectorized(Op, OpIdx, Lane)
    fn can_be_vectorized(o: i32, opidx: i64, lane: i64) -> bool {
        let opapo = apo[opidx * nlanes + lane];
        for ln in nlanes {
            if ln == lane { continue; }
            for opi in nops_ {
                let p = opi * nlanes + ln;
                if apo[p] != opapo || isused[p] { return true; }
                let x = gv(opi, ln);
                if l >= 0 && slp_loop_invariant(l, x) { return true; }
                let s2 = slp_same_opcode2(o, x);
                if sis_valid(s2) {
                    let pr: i32[2] = [o, x];
                    if slp_all_same_block(pr[..]) { return true; }
                }
            }
        }
        return false;
    }
    // reorder()
    var modes: i64[>..<] = [];
    for k in nops_ { modes.push(RM_FAILED); }
    let first_lane = best_lane_to_start();
    for oi in nops_ {
        let o0 = gv(oi, first_lane);
        if is_inst(o0) {
            if should_broadcast(o0, oi, first_lane) || !can_be_vectorized(o0, oi, first_lane) { modes[oi] = RM_SPLAT; }
            else if iop(o0) == OP_LOAD { modes[oi] = RM_LOAD; }
            else { modes[oi] = RM_OPCODE; }
        } else if is_constant(o0) {
            modes[oi] = RM_CONSTANT;
        } else if is_arg(o0) {
            modes[oi] = RM_SPLAT;
        } else {
            fatal("internal: SLP: unexpected value kind in VLOperands::reorder");
        }
    }
    fn skip_reordering() -> bool {
        var uniq: i32[>..<] = [];
        for ln in nlanes {
            let v = gv(0, ln);
            var seen = false;
            for y in uniq { if y == v { seen = true; break; } }
            if !seen { uniq.push(v); }
        }
        for oi in 1..nops_ {
            for ln in nlanes {
                let v = gv(oi, ln);
                var seen = false;
                for y in uniq { if y == v { seen = true; break; } }
                if !seen { return false; }
            }
        }
        return uniq.len != 2;
    }
    for pass in 2 {
        if skip_reordering() { break; }
        var failed = false;
        clear_used();
        // MainAltOps[OpIdx]: at most 2 values each
        var ma: i32[>..<] = [];
        var man: i64[>..<] = [];
        for i in nops_ { ma.push(gv(i, first_lane)); ma.push(0); man.push(1); }
        var used_lanes: bool[>..<] = [];
        for k in nlanes { used_lanes.push(false); }
        used_lanes[first_lane] = true;
        for dist in 1..nlanes {
            for dirk in 2 {
                let dir: i64 = if dirk == 0 { 1 } else { -1 };
                let lane = first_lane + dir * dist;
                if lane < 0 || lane >= nlanes { continue; }
                used_lanes[lane] = true;
                let last_lane = lane - dir;
                for oi in nops_ {
                    let b = best_operand(oi, lane, last_lane, modes, ma[2 * oi..2 * oi + man[oi]], used_lanes);
                    if b >= 0 { swap_(oi, b, lane); } else { failed = true; }
                    if man[oi] != 2 {
                        let altv = gv(oi, lane);
                        let ops2 = slp_same_opcode2(ma[2 * oi], altv);
                        if sis_valid(ops2) && sis_is_alt_shuffle(ops2) { ma[2 * oi + 1] = altv; man[oi] = 2; }
                    }
                }
            }
        }
        if !failed { break; }
    }
    // getVL(0) / getVL(1) into the first two operand lists
    for oi in 2 {
        if oi >= nopl { break; }
        let r = slp_opl[opl as i64 + oi];
        for lane in nlanes { slp_vp[r.at as i64 + lane] = gv(oi, lane); }
    }
}
fn slp_value_id(v: i32) -> i64 { sc_value_id(v) }
