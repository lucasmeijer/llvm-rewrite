// LowerExpectIntrinsic: port of llvm/lib/Transforms/Scalar/LowerExpectIntrinsic.cpp (LowerExpectIntrinsicPass).
// MisExpect diagnostics (-pgo-warn-misexpect) are remarks only and not ported.
import std;
import binary;
import math;
import ir;
import irutil;
import analyses;
import instinfo;
import calls;
import flags;
import apint;
import pm;
import profdata;
import fpu;
import crange;
import gen_iids;

fn le_is_expect(ci: i32) -> bool {
    if ci < 0 || !is_inst(ci) || iop(ci) != OP_CALL { return false; }
    let id = call_iid(ci);
    return id == IID_expect || id == IID_expect_with_probability;
}

fn le_prob(ci: i32) -> f64 {
    let c = cb_arg(ci, 2);
    let k = cfp_kind(c);
    var lo = cint_lo(c);
    if k != TK_DOUBLE { let l2, h2 = fp_convert(k, TK_DOUBLE, cint_lo(c), cint_hi(c)); lo = l2; }
    return binary::f64_of_bits(lo);
}

// getBranchWeight
fn le_weights(ci: i32, branch_count: i64) -> u64, u64 {
    if call_iid(ci) == IID_expect {
        return (flag_int("likely-branch-weight", 2000) as u64) & 0xFFFFFFFF,
               (flag_int("unlikely-branch-weight", 1) as u64) & 0xFFFFFFFF;
    }
    let tp = le_prob(ci);
    let fp = (1.0 - tp) / ((branch_count - 1) as f64);
    let lk = ceil((tp * (2147483646.0)) + 1.0);
    let un = ceil((fp * (2147483646.0)) + 1.0);
    return (lk as u64) & 0xFFFFFFFF, (un as u64) & 0xFFFFFFFF;
}

fn le_handle_switch(si: i32) -> bool {
    let ci = op(si, 0);
    if !le_is_expect(ci) { return false; }
    let arg = cb_arg(ci, 0);
    let ev = cb_arg(ci, 1);
    if !is_cint(ev) || ty_is_vector(vals[ev].ty) { return false; }
    let n = sw_ncases(si);
    let lk, un = le_weights(ci, n + 1);
    var ws: u64[>..<] = [];
    for k in n + 1 { ws.push(un); }
    var idx: i64 = 0;
    for k in n { if sw_case_val(si, k) == ev { idx = k + 1; break; } }
    ws[idx] = lk;
    set_op(si, 0, arg);
    pd_set(si, ws, true, false);
    return true;
}

fn le_handle_phi_def(ex: i32) {
    let ev = cb_arg(ex, 1);
    if !is_cint(ev) || ty_is_vector(vals[ev].ty) { return; }
    let expected = ci_ap(ev);
    var likely = true;
    if call_iid(ex) == IID_expect_with_probability { likely = le_prob(ex) > 0.5; }
    var v = cb_arg(ex, 0);
    var opsl: i32[>..<] = [];
    while !(is_inst(v) && iop(v) == OP_PHI) {
        if is_inst(v) && (iop(v) == OP_ZEXT || iop(v) == OP_SEXT) { opsl.push(v); v = op(v, 0); continue; }
        if !(is_inst(v) && iop(v) == OP_XOR) { return; }
        let c = op(v, 1);
        if !is_cint(c) || ty_is_vector(vals[c].ty) { return; }
        opsl.push(v);
        v = op(v, 0);
    }
    let phi = v;
    let phibb = inst_parent(phi);
    for i in phi_nincoming(phi) {
        let pv = phi_value(phi, i);
        if !is_cint(pv) || ty_is_vector(vals[pv].ty) { continue; }
        var r = ci_ap(pv);
        var k = opsl.len - 1;
        while k >= 0 {
            let o = opsl[k];
            let oc = iop(o);
            if oc == OP_XOR { r = ap_xor(r, ci_ap(op(o, 1))); }
            else if oc == OP_ZEXT { r = ap_zext(r, ty_bits(vals[o].ty)); }
            else { r = ap_sext(r, ty_bits(vals[o].ty)); }
            k--;
        }
        if likely == ap_eq(expected, r) { continue; }
        // GetDomConditional
        var bb = phi_block(phi, i);
        var bi = block_terminator(bb);
        if bi < 0 || iop(bi) != OP_CONDBR {
            bb = single_pred(bb);
            if bb < 0 { continue; }
            bi = block_terminator(bb);
            if bi < 0 || iop(bi) != OP_CONDBR { continue; }
        }
        let inc = phi_block(phi, i);
        var lk, un = le_weights(ex, 2);
        if !likely { let t = lk; lk = un; un = t; }
        let s1 = term_succ(bi, 1);
        let s0 = term_succ(bi, 0);
        let from1 = inc == s1 || (inc == inst_parent(bi) && s1 == phibb);
        let from0 = inc == s0 || (inc == inst_parent(bi) && s0 == phibb);
        if from1 { inst_set_md(bi, MDK_PROF, pd_create([lk, un], true)); }
        else if from0 { inst_set_md(bi, MDK_PROF, pd_create([un, lk], true)); }
    }
}

// handleBrSelExpect (condbr or select: the condition is operand 0)
fn le_handle_brsel(bsi: i32) -> bool {
    let cond = op(bsi, 0);
    var ci: i32 = -1;
    var pred: i64 = CRP_NE;
    var cmpc: i32 = -1;
    let is_cmp = is_inst(cond) && iop(cond) == OP_ICMP;
    if !is_cmp {
        ci = cond;
    } else {
        pred = inst_pred(cond);
        if pred != CRP_NE && pred != CRP_EQ { return false; }
        cmpc = op(cond, 1);
        if !is_cint(cmpc) || ty_is_vector(vals[cmpc].ty) { return false; }
        ci = op(cond, 0);
    }
    if !(is_inst(ci) && iop(ci) == OP_CALL) { return false; }
    var cmp_to: u64 = 0;
    if cmpc >= 0 {
        if ty_bits(vals[cmpc].ty) > 64 { return false; }
        cmp_to = cint_lo(cmpc);
    }
    if !le_is_expect(ci) { return false; }
    let arg = cb_arg(ci, 0);
    let ev = cb_arg(ci, 1);
    if !is_cint(ev) || ty_is_vector(vals[ev].ty) { return false; }
    if ty_bits(vals[ev].ty) > 64 { fatal("lower-expect: getZExtValue of a constant wider than 64 bits"); }
    let lk, un = le_weights(ci, 2);
    var node: i32 = -1;
    if (cint_lo(ev) == cmp_to) == (pred == CRP_EQ) { node = pd_create([lk, un], true); }
    else { node = pd_create([un, lk], true); }
    set_op(if is_cmp { cond } else { bsi }, 0, arg);
    inst_set_md(bsi, MDK_PROF, node);
    return true;
}

fn lower_expect_run(fv: i32) -> u32 {
    var changed = false;
    var bb = func_first_block(fv);
    while bb >= 0 {
        let t = block_terminator(bb);
        if t >= 0 && iop(t) == OP_CONDBR { le_handle_brsel(t); }
        else if t >= 0 && iop(t) == OP_SWITCH { le_handle_switch(t); }
        var i = block_last(bb);
        while i >= 0 {
            let prev = inst_prev(i);
            if iop(i) != OP_CALL {
                if iop(i) == OP_SELECT { le_handle_brsel(i); }
                i = prev;
                continue;
            }
            if le_is_expect(i) {
                le_handle_phi_def(i);
                rauw(i, cb_arg(i, 0));
                inst_erase_from_parent(i);
                changed = true;
            }
            i = prev;
        }
        bb = block_next(bb);
    }
    if !changed { return PA_ALL; }
    return PA_NONE;
}
