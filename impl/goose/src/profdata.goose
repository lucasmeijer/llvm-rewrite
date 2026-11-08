// Branch-weight metadata: llvm/lib/IR/ProfDataUtils.cpp (isBranchWeightMD, getBranchWeightOffset,
// extractBranchWeights, getValidBranchWeightMDNode, fitWeights, setBranchWeights, setFittedBranchWeights),
// llvm/lib/IR/MDBuilder.cpp (createBranchWeights) and SwitchInstProfUpdateWrapper (llvm/lib/IR/Instructions.cpp).
// Weights are u64 arrays; MD_prof is metadata kind 2.
import std;
import ir;
import irutil;
import instinfo;
import apint;
import pm;

let MDK_PROF: i32 = 2;

fn pd_md_string_is(m: i32, s: const u8[:]) -> bool { m >= 0 && mds[m].kind == MK_STRING && sbytes(mds[m].extra) == s }

// isBranchWeightMD
fn pd_is_branch_weight_md(m: i32) -> bool {
    if m < 0 || mds[m].kind != MK_TUPLE { return false; }
    if mds[m].nops < 3 { return false; }
    return pd_md_string_is(md_op(m, 0), "branch_weights");
}
// hasBranchWeightOrigin(MD)
fn pd_has_origin(m: i32) -> bool {
    if !pd_is_branch_weight_md(m) { return false; }
    let o = md_op(m, 1);
    return o >= 0 && mds[o].kind == MK_STRING;
}
fn pd_offset(m: i32) -> i64 { if pd_has_origin(m) { 2 } else { 1 } }
fn pd_num_weights(m: i32) -> i64 { mds[m].nops as i64 - pd_offset(m) }

fn pd_prof(i: i32) -> i32 { inst_get_md(i, MDK_PROF) }
fn pd_has_branch_weights(i: i32) -> bool { pd_is_branch_weight_md(pd_prof(i)) }

// getValidBranchWeightMDNode: -1 if none or the count doesn't match the successors
fn pd_valid_md(i: i32) -> i32 {
    let m = pd_prof(i);
    if !pd_is_branch_weight_md(m) { return -1; }
    if pd_num_weights(m) != term_nsucc(i) { return -1; }
    return m;
}

fn pd_md_weight(m: i32, k: i64) -> u64 {
    let o = md_op(m, k);
    if o < 0 || mds[o].kind != MK_VALUE { fatal("malformed branch_weights metadata"); }
    let c = mds[o].extra;
    if vals[c].kind != VK_CINT { fatal("malformed branch_weights metadata"); }
    return ap_zext64(ci_ap(c));
}

// extractFromBranchWeightMD64
fn pd_extract_md(m: i32, out: u64[>..<]&) {
    out.clear();
    let off = pd_offset(m);
    for k in off..(mds[m].nops as i64) { out.push(pd_md_weight(m, k)); }
}

// extractBranchWeights(I, Weights) (uint32 version: weights must fit 32 bits; LLVM asserts)
fn pd_extract(i: i32, out: u64[>..<]&) -> bool {
    let m = pd_prof(i);
    if !pd_is_branch_weight_md(m) { return false; }
    pd_extract_md(m, out);
    return true;
}

// extractBranchWeights(I, TrueVal, FalseVal) for condbr / select
fn pd_extract2(i: i32) -> bool, u64, u64 {
    var ws: u64[>..<] = [];
    if !pd_extract(i, ws) { return false, 0, 0; }
    if ws.len > 2 { return false, 0, 0; }
    return true, ws[0], ws[1];
}

// fitWeights
fn pd_fit(ws: u64[>..<]&) {
    var mx: u64 = 0;
    for w in ws { if w > mx { mx = w; } }
    if mx > 0xFFFFFFFF {
        var lz = 0;
        var x = mx;
        while (x & 0x8000000000000000) == 0 { x = x << 1; lz++; }
        let off = 32 - lz;
        for k in ws.len { ws[k] = (ws[k] >> off) & 0xFFFFFFFF; }
    }
}

// MDBuilder::createBranchWeights(Weights, IsExpected)
fn pd_create(ws: const u64[:], expected: bool) -> i32 {
    var ops: i32[>..<] = [];
    ops.push(md_string("branch_weights"));
    if expected { ops.push(md_string("expected")); }
    for w in ws { ops.push(md_value(c_int(T_I32, (w & 0xFFFFFFFF) as i64))); }
    return md_get(MK_TUPLE, -1, ops, false);
}

// setBranchWeights(I, Weights(u32), IsExpected, ElideAllZero); ElideAllZeroBranchWeights is on
fn pd_set(i: i32, ws: const u64[:], expected: bool, elide_all_zero: bool) {
    if elide_all_zero {
        var allz = true;
        for w in ws { if w != 0 { allz = false; } }
        if allz { inst_erase_md(i, MDK_PROF); return; }
    }
    inst_set_md(i, MDK_PROF, pd_create(ws, expected));
}

// setFittedBranchWeights(I, Weights(u64), IsExpected, ElideAllZero)
fn pd_set_fitted(i: i32, ws0: const u64[:], expected: bool, elide_all_zero: bool) {
    var ws: u64[>..<] = [];
    for w in ws0 { ws.push(w); }
    pd_fit(ws);
    pd_set(i, ws, expected, elide_all_zero);
}

// ---------------------------------------------------------------------------------------------
// SwitchInstProfUpdateWrapper: weights loaded on construction (if valid), written back by the destructor
// (only when changed). One wrapper at a time.

var sw_w: u64[>..<];
var sw_has: bool = false;
var sw_changed: bool = false;
var sw_inst: i32 = -1;

// getProfBranchWeightsMD + the constructor (init)
fn swp_begin(si: i32) {
    sw_inst = si;
    sw_changed = false;
    sw_w.clear();
    sw_has = false;
    let m = pd_prof(si);
    if !pd_is_branch_weight_md(m) { return; }
    if pd_num_weights(m) != term_nsucc(si) {
        fatal("internal: SwitchInstProfUpdateWrapper: the number of branch weights doesn't match the switch");
    }
    pd_extract_md(m, sw_w);
    sw_has = true;
}

// ~SwitchInstProfUpdateWrapper: setBranchWeights(SI, Weights, IsExpected = false) when changed
fn swp_end() {
    if sw_changed && sw_has {
        if sw_w.len >= 2 { pd_set(sw_inst, sw_w, false, false); }
        else { inst_erase_md(sw_inst, MDK_PROF); }
    }
    sw_inst = -1;
    sw_has = false;
    sw_changed = false;
}
// SwitchInstProfUpdateWrapper::eraseFromParent (the caller erases the instruction)
fn swp_erase() { sw_changed = false; sw_w.clear(); sw_has = false; sw_inst = -1; }

fn sw_ncases(si: i32) -> i64 { (nops(si) - 2) / 2 }
fn sw_case_val(si: i32, k: i64) -> i32 { op(si, 2 + 2 * k) }
fn sw_case_dest(si: i32, k: i64) -> i32 { op(si, 3 + 2 * k) }
fn sw_default(si: i32) -> i32 { op(si, 1) }

// SwitchInst::removeCase(I): the last case moves into the hole.
fn sw_remove_case_raw(si: i32, idx: i64) {
    let n = nops(si);
    let at = 2 + 2 * idx;
    if at + 2 != n {
        set_op(si, at, op(si, n - 2));
        set_op(si, at + 1, op(si, n - 1));
    }
    set_op(si, n - 2, -1);
    set_op(si, n - 1, -1);
    vals[si].nops = (n - 2) as i32;
}

// SwitchInstProfUpdateWrapper::removeCase
fn swp_remove_case(si: i32, idx: i64) {
    if sw_has && sw_inst == si {
        let last = sw_w.len - 1;
        sw_w[idx + 1] = sw_w[last];
        sw_w.resize(last);
        sw_changed = true;
    }
    sw_remove_case_raw(si, idx);
}

// SwitchInst::addCase: grows like SwitchInst::growOperands (3x the LLVM operand count 2 + #cases).
fn sw_add_case_raw(si: i32, v: i32, dest: i32) {
    let n = nops(si);
    let ncases = (n - 2) / 2;
    let llvm_ops = 2 + ncases;
    let reserved = (vals[si].cap as i64 + 2) / 2;    // our capacity 2R - 2 <-> LLVM's ReservedSpace R
    if llvm_ops + 1 > reserved {
        let nr = llvm_ops * 3;
        grow_ops(si, 2 * nr - 2);
    }
    vals[si].nops = (n + 2) as i32;
    set_op(si, n, v);
    set_op(si, n + 1, dest);
}

// SwitchInstProfUpdateWrapper::addCase(OnVal, Dest, W)
fn swp_add_case(si: i32, v: i32, dest: i32, has_w: bool, w: u64) {
    sw_add_case_raw(si, v, dest);
    if !sw_has && has_w && w != 0 {
        sw_changed = true;
        sw_w.clear();
        for k in term_nsucc(si) { sw_w.push(0); }
        sw_w[sw_w.len - 1] = w;
        sw_has = true;
    } else if sw_has {
        sw_changed = true;
        sw_w.push(if has_w { w } else { 0 });
    }
}

// SwitchInstProfUpdateWrapper::setSuccessorWeight(idx, W)
fn swp_set_weight(si: i32, idx: i64, has_w: bool, w: u64) {
    if !has_w { return; }
    if !sw_has && w != 0 {
        sw_w.clear();
        for k in term_nsucc(si) { sw_w.push(0); }
        sw_has = true;
    }
    if sw_has && sw_w[idx] != w { sw_w[idx] = w; sw_changed = true; }
}
fn swp_get_weight(idx: i64) -> bool, u64 {
    if !sw_has { return false, 0; }
    return true, sw_w[idx];
}
// SwitchInstProfUpdateWrapper::replaceDefaultDest(case idx)
fn swp_replace_default_dest(si: i32, idx: i64) {
    let d = sw_case_dest(si, idx);
    if sw_has { sw_w[0] = sw_w[idx + 1]; }
    set_op(si, 1, d);
}
