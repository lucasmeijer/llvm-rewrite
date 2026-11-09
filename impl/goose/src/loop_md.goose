// Loop metadata and loop-level profile helpers. Ports of:
// - llvm/lib/Analysis/LoopInfo.cpp: Loop::setLoopID, setLoopAlreadyUnrolled, addStringLoopAttribute,
//   findStringMetadataForLoop, getOptionalBoolLoopAttribute, getBooleanLoopAttribute,
//   getOptionalIntLoopAttribute, getIntLoopAttribute, getLoopConvergenceHeart, makePostTransformationMetadata,
//   isFinite, hasMustProgress, isMustProgress
// - llvm/lib/Transforms/Utils/LoopUtils.cpp: addStringMetadataToLoop, makeFollowupLoopID,
//   hasDisableAllTransformsHint, hasUnrollTransformation, hasUnrollAndJamTransformation,
//   getExpectedExitLoopLatchBranch, estimateLoopTripCount, getLoopEstimatedTripCount,
//   setLoopEstimatedTripCount, getLoopProbability, setLoopProbability, getBranchProbability (both),
//   setBranchProbability
// - llvm/lib/Transforms/Utils/LoopUnroll.cpp: GetUnrollMetadata, getUnrollMetadataForLoop
// - llvm/lib/Support/BranchProbability.cpp: getBranchProbability(double), pow
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_attrs;
import loopinfo;
import profdata;
import tti;
import math;

// TransformationMode
let TM_UNSPECIFIED: i64 = 0;
let TM_ENABLE: i64 = 1;
let TM_DISABLE: i64 = 2;
let TM_FORCE: i64 = 4;
let TM_FORCED_BY_USER: i64 = 5;
let TM_SUPPRESSED_BY_USER: i64 = 6;

// Loop::setLoopID(LoopID): -1 removes it
fn lmd_set_loop_id(l: i32, md: i32) {
    var latches: i32[>..<] = [];
    loop_latches(l, latches);
    for b in latches { inst_set_md(block_terminator(b), MDK_LOOP, md); }
}

// findOptionMDForLoop(L, Name)
fn lmd_find(l: i32, name: const u8[:]) -> i32 { find_option_md_for_loop_id(loop_id(l), name) }

// getOptionalBoolLoopAttribute: (present, value)
fn lmd_optional_bool(l: i32, name: const u8[:]) -> bool, bool {
    let md = lmd_find(l, name);
    if md < 0 { return false, false; }
    if mds[md].nops == 1 { return true, true; }
    if mds[md].nops == 2 {
        let o = md_op(md, 1);
        if o >= 0 && mds[o].kind == MK_VALUE && vals[mds[o].extra].kind == VK_CINT {
            return true, !cint_is_zero(mds[o].extra);
        }
        return true, true;
    }
    fatal("internal: unexpected number of loop metadata options");
    return false, false;
}
// getBooleanLoopAttribute
fn lmd_bool(l: i32, name: const u8[:]) -> bool { let p, v = lmd_optional_bool(l, name); return p && v; }
// getOptionalIntLoopAttribute: (present, value)
fn lmd_optional_int(l: i32, name: const u8[:]) -> bool, i64 {
    let md = lmd_find(l, name);
    if md < 0 { return false, 0; }
    if mds[md].nops == 1 { return false, 0; }
    if mds[md].nops != 2 { fatal("internal: loop metadata has 0 or 1 operand"); }
    let o = md_op(md, 1);
    if o < 0 || mds[o].kind != MK_VALUE || vals[mds[o].extra].kind != VK_CINT { return false, 0; }
    return true, cint_sext(mds[o].extra);
}
fn lmd_int(l: i32, name: const u8[:], dflt: i64) -> i64 { let p, v = lmd_optional_int(l, name); return if p { v } else { dflt }; }

// hasDisableAllTransformsHint
fn lmd_disable_all_transforms(l: i32) -> bool { lmd_bool(l, "llvm.loop.disable_nonforced") }

// hasUnrollTransformation
fn has_unroll_transformation(l: i32) -> i64 {
    if lmd_bool(l, "llvm.loop.unroll.disable") { return TM_SUPPRESSED_BY_USER; }
    let p, c = lmd_optional_int(l, "llvm.loop.unroll.count");
    if p { return if c == 1 { TM_SUPPRESSED_BY_USER } else { TM_FORCED_BY_USER }; }
    if lmd_bool(l, "llvm.loop.unroll.enable") { return TM_FORCED_BY_USER; }
    if lmd_bool(l, "llvm.loop.unroll.full") { return TM_FORCED_BY_USER; }
    if lmd_disable_all_transforms(l) { return TM_DISABLE; }
    return TM_UNSPECIFIED;
}
// hasUnrollAndJamTransformation
fn has_unroll_and_jam_transformation(l: i32) -> i64 {
    if lmd_bool(l, "llvm.loop.unroll_and_jam.disable") { return TM_SUPPRESSED_BY_USER; }
    let p, c = lmd_optional_int(l, "llvm.loop.unroll_and_jam.count");
    if p { return if c == 1 { TM_SUPPRESSED_BY_USER } else { TM_FORCED_BY_USER }; }
    if lmd_bool(l, "llvm.loop.unroll_and_jam.enable") { return TM_FORCED_BY_USER; }
    if lmd_disable_all_transforms(l) { return TM_DISABLE; }
    return TM_UNSPECIFIED;
}

// GetUnrollMetadata(LoopID, Name) / getUnrollMetadataForLoop(L, Name)
fn lmd_unroll_md(l: i32, name: const u8[:]) -> i32 {
    let lid = loop_id(l);
    if lid < 0 { return -1; }
    for k in 1..mds[lid].nops as i64 {
        let m = md_op(lid, k);
        if m < 0 || !md_is_node(m) { continue; }
        if mds[m].nops < 1 { continue; }
        let s = md_op(m, 0);
        if s < 0 || mds[s].kind != MK_STRING { continue; }
        if sbytes(mds[s].extra) == name { return m; }
    }
    return -1;
}

// a distinct self-referential loop ID with operands ops[1..] (ops[0] is replaced)
fn lmd_new_loop_id(ops: i32[>..]&) -> i32 {
    ops[0] = -1;
    let n = md_get(MK_TUPLE, -1, ops, true);
    md_ops[mds[n].ops] = n;
    return n;
}

// makePostTransformationMetadata(Context, OrigLoopID, RemovePrefixes, AddAttrs)
fn make_post_transformation_metadata(orig: i32, remove_prefixes: const u8[:][:], add: const i32[:]) -> i32 {
    var ops: i32[>..] = [];
    ops.push(-1);
    if orig >= 0 {
        for k in 1..mds[orig].nops as i64 {
            let o = md_op(orig, k);
            var is_vec = false;
            if o >= 0 && md_is_node(o) && mds[o].nops > 0 {
                let s = md_op(o, 0);
                if s >= 0 && mds[s].kind == MK_STRING {
                    let sb = sbytes(mds[s].extra);
                    for p in remove_prefixes { if starts_with(sb, p) { is_vec = true; } }
                }
            }
            if !is_vec { ops.push(o); }
        }
    }
    for a in add { ops.push(a); }
    return lmd_new_loop_id(ops);
}

// Loop::addStringLoopAttribute(Name, RemovePrefixes)
fn lmd_add_string_loop_attribute(l: i32, name: const u8[:], remove_prefixes: const u8[:][:]) {
    let attr = md_get(MK_TUPLE, -1, [md_string(name)], false);
    let nid = make_post_transformation_metadata(loop_id(l), remove_prefixes, [attr]);
    lmd_set_loop_id(l, nid);
}
// Loop::setLoopAlreadyUnrolled
fn loop_set_already_unrolled(l: i32) {
    let pfx: const u8[:][1] = ["llvm.loop.unroll."];
    lmd_add_string_loop_attribute(l, "llvm.loop.unroll.disable", pfx);
}

// addStringMetadataToLoop(TheLoop, StringMD, V)
fn add_string_metadata_to_loop(l: i32, name: const u8[:], v: i64) {
    var ops: i32[>..] = [];
    ops.push(-1);
    let lid = loop_id(l);
    if lid >= 0 {
        for k in 1..mds[lid].nops as i64 {
            let node = md_op(lid, k);
            if mds[node].nops == 2 {
                let s = md_op(node, 0);
                if s >= 0 && mds[s].kind == MK_STRING && sbytes(mds[s].extra) == name {
                    let o = md_op(node, 1);
                    if o >= 0 && mds[o].kind == MK_VALUE && vals[mds[o].extra].kind == VK_CINT && cint_sext(mds[o].extra) == v {
                        return;
                    }
                    continue;
                }
            }
            ops.push(node);
        }
    }
    ops.push(md_get(MK_TUPLE, -1, [md_string(name), md_value(c_int(T_I32, v))], false));
    lmd_set_loop_id(l, lmd_new_loop_id(ops));
}

// makeFollowupLoopID(OrigLoopID, FollowupOptions, InheritOptionsExceptPrefix = "llvm.loop.unroll.",
// AlwaysNew = false) as LoopUnroll/LoopPeel call it: (has value, loop id or -1 = nullptr)
fn make_followup_loop_id(orig: i32, options: const u8[:][:], inherit_except: const u8[:], always_new: bool) -> bool, i32 {
    if orig < 0 { if always_new { return true, -1; } return false, -1; }
    let inherit_all = false;
    let inherit_some = inherit_except.len > 0;
    var ops: i32[>..] = [];
    ops.push(-1);
    var changed = false;
    if inherit_all || inherit_some {
        for k in 1..mds[orig].nops as i64 {
            let o = md_op(orig, k);
            var inherit = true;
            if mds[o].nops == 0 { inherit = true; }
            else {
                let nm = md_op(o, 0);
                if nm < 0 || mds[nm].kind != MK_STRING { inherit = true; }
                else { inherit = !starts_with(sbytes(mds[nm].extra), inherit_except); }
            }
            if inherit { ops.push(o); } else { changed = true; }
        }
    } else {
        changed = mds[orig].nops > 1;
    }
    var has_any = false;
    for opt in options {
        let f = find_option_md_for_loop_id(orig, opt);
        if f < 0 { continue; }
        has_any = true;
        for k in 1..mds[f].nops as i64 { ops.push(md_op(f, k)); changed = true; }
    }
    if !always_new && !has_any { return false, -1; }
    if !always_new && !changed { return true, orig; }
    if ops.len == 1 { return true, -1; }
    return true, lmd_new_loop_id(ops);
}

// getLoopConvergenceHeart(L)
fn get_loop_convergence_heart(l: i32) -> i32 {
    var i = block_first(loop_header(l));
    while i >= 0 {
        if is_callbase(i) {
            if call_has_fn_attr(i, AK_Convergent) {
                let tok = cb_convergence_control_token(i);
                if tok >= 0 {
                    if !loop_contains(l, inst_parent(tok)) { return i; }
                }
                return -1;
            }
        }
        i = inst_next(i);
    }
    return -1;
}
// CallBase::getConvergenceControlToken: the "convergencectrl" bundle operand
fn cb_convergence_control_token(i: i32) -> i32 {
    for k in cb_nbundles(i) {
        if sbytes(cb_bundle_tag(i, k)) == "convergencectrl" { return op(i, cb_bundle_begin(i, k)); }
    }
    return -1;
}

// getExpectedExitLoopLatchBranch(L)
fn expected_exit_loop_latch_branch(l: i32) -> i32 {
    let latch = loop_latch(l);
    if latch < 0 { return -1; }
    let t = block_terminator(latch);
    if iop(t) != OP_CONDBR || !loop_is_exiting(l, latch) { return -1; }
    return t;
}
// extractBranchWeights(I, TrueVal, FalseVal)
fn lmd_extract_branch_weights(i: i32) -> bool, u64, u64 {
    var ws: u64[>..<] = [];
    if !pd_extract(i, ws) { return false, 0, 0; }
    if ws.len != 2 { return false, 0, 0; }
    return true, ws[0], ws[1];
}
// divideNearest
fn lmd_divide_nearest(n: u64, d: u64) -> u64 { let m = n % d; return n / d + (if m > (d - 1) / 2 { 1 } else { 0 }); }

// estimateLoopTripCount(L): (has, count)
fn estimate_loop_trip_count(l: i32) -> bool, u64 {
    let br = expected_exit_loop_latch_branch(l);
    if br < 0 { return false, 0; }
    let ok, w0, w1 = lmd_extract_branch_weights(br);
    if !ok { return false, 0; }
    var lw = w0;
    var ew = w1;
    if loop_contains(l, term_succ(br, 1)) { lw = w1; ew = w0; }
    if ew == 0 { return false, 0; }
    let ec = lmd_divide_nearest(lw, ew);
    if ec >= 0xFFFFFFFF { return true, 0xFFFFFFFF; }
    return true, ec + 1;
}
// getLoopEstimatedTripCount(L, EstimatedLoopInvocationWeight): (has, count, has weight, weight)
fn get_loop_estimated_trip_count_w(l: i32, want_weight: bool) -> bool, u64, u64 {
    let br = expected_exit_loop_latch_branch(l);
    if br < 0 { return false, 0, 0; }
    var weight: u64 = 0;
    if want_weight {
        let ok, w0, w1 = lmd_extract_branch_weights(br);
        if !ok { return false, 0, 0; }
        var ew = w1;
        if loop_contains(l, term_succ(br, 1)) { ew = w0; }
        if ew == 0 { return false, 0, 0; }
        weight = ew;
    }
    let p, tc = lmd_optional_int(l, "llvm.loop.estimated_trip_count");
    if p {
        let u = (tc as! u64) & 0xFFFFFFFF;
        if u == 0 { return false, 0, weight; }
        return true, u, weight;
    }
    let h, e = estimate_loop_trip_count(l);
    return h, e, weight;
}
fn get_loop_estimated_trip_count(l: i32) -> bool, u64 { let h, t, w = get_loop_estimated_trip_count_w(l, false); return h, t; }

// setLoopEstimatedTripCount(L, EstimatedTripCount, EstimatedloopInvocationWeight)
fn set_loop_estimated_trip_count(l: i32, tc: u64, has_weight: bool, weight: u64) -> bool {
    let br = expected_exit_loop_latch_branch(l);
    if br < 0 { return false; }
    add_string_metadata_to_loop(l, "llvm.loop.estimated_trip_count", (tc & 0xFFFFFFFF) as i64);
    if !has_weight { return true; }
    var exitw: u64 = 1;
    var takenw: u64 = 0;
    if tc != 0 {
        exitw = weight;
        takenw = ((tc - 1) * exitw) & 0xFFFFFFFF;
    }
    // the latch branch may have changed with the loop ID
    let br2 = expected_exit_loop_latch_branch(l);
    if term_succ(br2, 0) != loop_header(l) { let t = takenw; takenw = exitw; exitw = t; }
    pd_set(br2, [takenw, exitw], false, false);
    return true;
}

// getBranchProbability(CondBrInst *B, bool ForFirstTarget); BP_UNKNOWN when there are no weights
fn lmd_branch_probability(b: i32, first: bool) -> u32 {
    let ok, w0, w1 = lmd_extract_branch_weights(b);
    if !ok { return 0xFFFFFFFF; }
    let den = w0 + w1;
    if den == 0 { return 0xFFFFFFFF; }
    return bp_get(if first { w0 } else { w1 }, den);
}
// setBranchProbability(B, P, ForFirstTarget)
fn lmd_set_branch_probability(b: i32, p: u32, first: bool) {
    var p0 = p;
    var p1 = bp_compl(p);
    if !first { let t = p0; p0 = p1; p1 = t; }
    pd_set(b, [p0 as u64, p1 as u64], false, false);
}
// getLoopProbability(L)
fn get_loop_probability(l: i32) -> u32 {
    let br = expected_exit_loop_latch_branch(l);
    if br < 0 { return 0xFFFFFFFF; }
    return lmd_branch_probability(br, term_succ(br, 0) == loop_header(l));
}
// setLoopProbability(L, P)
fn set_loop_probability(l: i32, p: u32) -> bool {
    let br = expected_exit_loop_latch_branch(l);
    if br < 0 { return false; }
    lmd_set_branch_probability(br, p, term_succ(br, 0) == loop_header(l));
    return true;
}
// BranchProbability::getBranchProbability(double Prob)
fn bp_from_double(p: f64) -> u32 {
    let x = round(p * (BP_D as f64));
    return bp_from_ratio(x as u64, BP_D);
}
fn bp_to_double(p: u32) -> f64 { (p as f64) / (BP_D as f64) }
// BranchProbability::pow(N)
fn bp_pow(p: u32, n: i64) -> u32 {
    var r = BP_D as u32;
    for k in n { r = (((r as u64) * (p as u64) + BP_D / 2) / BP_D) as u32; }
    return r;
}
