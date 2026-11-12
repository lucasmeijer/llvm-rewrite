// Small shared helpers of the misc passes (misc_passes.goose):
// - ReversePostOrderTraversal<Function *> (llvm/ADT/PostOrderIterator.h)
// - replaceAndRecursivelySimplify (llvm/lib/Analysis/InstructionSimplify.cpp)
import std;
import ir;
import irutil;
import instinfo;
import instsimplify;
import vt;
import knownbits;
import assume;
import calls;
import gen_iids;

var mu_bstamp: i32[>..<];
var mu_bepoch: i32 = 0;
fn mu_bmark_clear() { mu_bepoch++; }
fn mu_bmark(bb: i32) -> bool {
    let k = block_number(bb) as i64;
    while mu_bstamp.len <= k { mu_bstamp.push(0); }
    if mu_bstamp[k] == mu_bepoch { return false; }
    mu_bstamp[k] = mu_bepoch;
    return true;
}
fn mu_bmarked(bb: i32) -> bool {
    let k = block_number(bb) as i64;
    return k < mu_bstamp.len && mu_bstamp[k] == mu_bepoch;
}

// post_order(&F) from block `entry`
fn mu_po_from(entry: i32, po: i32[>..<]&) {
    po.clear();
    mu_bmark_clear();
    var stk: i32[>..<] = [];
    var idx: i64[>..<] = [];
    mu_bmark(entry);
    stk.push(entry);
    idx.push(0);
    while stk.len > 0 {
        let t = stk.len - 1;
        let bb = stk[t];
        if idx[t] < block_nsucc(bb) {
            let s = block_succ(bb, idx[t]);
            idx[t]++;
            if mu_bmark(s) { stk.push(s); idx.push(0); }
            continue;
        }
        po.push(bb);
        stk.pop();
        idx.pop();
    }
}

// ReversePostOrderTraversal<Function *>
fn mu_rpo(fv: i32, out: i32[>..<]&) {
    var po: i32[>..<] = [];
    mu_po_from(func_entry(fv), po);
    out.clear();
    var k = po.len - 1;
    while k >= 0 { out.push(po[k]); k--; }
}

// SetVector insert over a local array (linear membership: the sets here are small).
fn mu_sv_insert(xs: i32[>..<]&, v: i32) -> bool {
    for x in xs { if x == v { return false; } }
    xs.push(v);
    return true;
}

// replaceAndRecursivelySimplify(I, SimpleV, TLI, DT, AC, UnsimplifiedUsers) with TLI = DT = AC = nullptr
// (the only caller so far, LowerConstantIntrinsics, passes none). Unsimplified users are appended to `unsimp`
// (a SetVector).
fn mu_replace_and_recursively_simplify(i0: i32, simple0: i32, unsimp: i32[>..<]&) -> bool {
    let s1 = sq_no_dt; let s2 = sq_no_ac; let s3 = sq_no_tli; let sc = kb_cxt;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    var simplified = false;
    var wl: i32[>..<] = [];
    var u = vals[i0].first_use;
    while u >= 0 { let us = uses[u].user; if us != i0 { mu_sv_insert(wl, us); } u = uses[u].next; }
    ac_rauw(i0, simple0);
    rauw(i0, simple0);
    if !inst_is_eh_pad(i0) && !is_terminator(i0) && !inst_may_have_side_effects(i0) { inst_erase_from_parent(i0); }
    var idx: i64 = 0;
    while idx < wl.len {
        let i = wl[idx];
        idx++;
        if is_dead(i) { fatal("internal: replaceAndRecursivelySimplify visited an erased instruction"); }
        kb_cxt = -1;
        let sv = simplify_instruction(i);
        if sv < 0 {
            mu_sv_insert(unsimp, i);
            continue;
        }
        simplified = true;
        var u2 = vals[i].first_use;
        while u2 >= 0 { mu_sv_insert(wl, uses[u2].user); u2 = uses[u2].next; }
        ac_rauw(i, sv);
        rauw(i, sv);
        if !inst_is_eh_pad(i) && !is_terminator(i) && !inst_may_have_side_effects(i) { inst_erase_from_parent(i); }
    }
    sq_no_dt = s1; sq_no_ac = s2; sq_no_tli = s3; kb_cxt = sc;
    return simplified;
}

// BasicBlock::getFirstInsertionPt (the iterator has its head bit set: insert with the _head functions); -1 = end
fn mu_first_insertion_pt(bb: i32) -> i32 {
    var i = block_first(bb);
    while i >= 0 && iop(i) == OP_PHI { i = inst_next(i); }
    if i >= 0 && inst_is_eh_pad(i) { i = inst_next(i); }
    return i;
}

// Instruction::isDebugOrPseudoInst
fn mu_is_debug_or_pseudo(i: i32) -> bool {
    if iop(i) != OP_CALL { return false; }
    let id = inst_iid(i);
    return id == IID_dbg_declare || id == IID_dbg_value || id == IID_dbg_label || id == IID_dbg_assign || id == IID_pseudoprobe;
}

// Value::hasOneUse
fn mu_has_one_use(v: i32) -> bool { let u = vals[v].first_use; return u >= 0 && uses[u].next < 0; }
