// SLPVectorizer: the PHI seeds of vectorizeChainsInBlock. Port of llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp's
// SLPVectorizerPass::vectorizeChainsInBlock PHI loop (PHIToOpcodes, PHICompare, AreCompatiblePHIs) and
// tryToVectorizeSequence<Value> with MaxVFOnly = true. PHICompare is not a strict weak order, so the sort is
// libstdc++'s std::stable_sort (stdsort.goose).
import std;
import ir;
import irutil;
import pm;
import domtree;
import stdsort;
import slp_util;
import slp_tree;
import slp_build;
import slp_stores;

// PHIToOpcodes: phi -> run of its non-phi incoming values (through phi chains)
var slp_p2o_v: i32[>..<];
var slp_p2o_at: i64[>..<];
var slp_p2o_n: i64[>..<];
let SH_P2O: i64 = 27;
let SH_PHIVIS: i64 = 28;
fn slp_p2o_index(p: i32) -> i64 { sh_get(SH_P2O, p as i64, 0, -1) }
fn slp_p2o(p: i32) -> const i32[:] {
    let k = slp_p2o_index(p);
    if k < 0 { return slp_p2o_v[0..0]; }
    return slp_p2o_v[slp_p2o_at[k]..slp_p2o_at[k] + slp_p2o_n[k]];
}
fn slp_p2o_build(v: i32) {
    if slp_p2o_index(v) >= 0 && slp_p2o_n[slp_p2o_index(v)] > 0 { return; }
    var k = slp_p2o_index(v);
    if k < 0 { k = slp_p2o_at.len; slp_p2o_at.push(slp_p2o_v.len); slp_p2o_n.push(0); sh_set(SH_P2O, v as i64, 0, k); }
    slp_p2o_at[k] = slp_p2o_v.len;
    var nodes: i32[>..<] = [];
    nodes.push(v);
    sh_clear(SH_TMP0);
    while nodes.len > 0 {
        let phi = nodes.pop();
        if !sh_add(SH_TMP0, phi as i64, 0) { continue; }
        for j in phi_nincoming(phi) {
            let x = phi_value(phi, j);
            if is_inst_op(x, OP_PHI) { nodes.push(x); continue; }
            slp_p2o_v.push(x);
            slp_p2o_n[k] += 1;
        }
    }
}
fn slp_dfs_node(bb: i32) -> bool { dt_has_node(DT_DOM, bb) }
// PHICompare(V1, V2)
fn slp_phi_less(v1: i32, v2: i32) -> bool {
    if v1 == v2 { return false; }
    let t1 = slp_type_id(vals[v1].ty);
    let t2 = slp_type_id(vals[v2].ty);
    if t1 < t2 { return true; }
    if t1 > t2 { return false; }
    let s1 = tt_scalar_bits(vals[v1].ty);
    let s2 = tt_scalar_bits(vals[v2].ty);
    if s1 < s2 { return true; }
    if s1 > s2 { return false; }
    let o1 = slp_p2o(v1);
    let o2 = slp_p2o(v2);
    if o1.len < o2.len { return true; }
    if o1.len > o2.len { return false; }
    for k in o1.len {
        let a = o1[k];
        let b = o2[k];
        let i1 = is_inst(a);
        let i2 = is_inst(b);
        if i1 && i2 {
            let n1 = slp_dfs_node(inst_parent(a));
            let n2 = slp_dfs_node(inst_parent(b));
            if !n1 { return n2; }
            if !n2 { return false; }
            if inst_parent(a) != inst_parent(b) { return slp_dom_dfs_in(inst_parent(a)) < slp_dom_dfs_in(inst_parent(b)); }
            let s = slp_same_opcode2(a, b);
            if sis_valid(s) && !sis_is_alt_shuffle(s) && iop(a) == iop(b) {
                if !(iop(a) == OP_EXTRACTELEMENT && iop(b) == OP_EXTRACTELEMENT) { continue; }
                let x1 = op(a, 0);
                let x2 = op(b, 0);
                let vi1 = is_inst(x1);
                let vi2 = is_inst(x2);
                let w1 = if vi1 { x1 } else { -1 };
                let w2 = if vi2 { x2 } else { -1 };
                if w1 != w2 {
                    if vi1 && !vi2 { return true; }
                    if !vi1 && vi2 { return false; }
                    let m1 = slp_dfs_node(inst_parent(x1));
                    let m2 = slp_dfs_node(inst_parent(x2));
                    if !m1 { return m2; }
                    if !m2 { return false; }
                    if inst_parent(x1) != inst_parent(x2) { return slp_dom_dfs_in(inst_parent(x1)) < slp_dom_dfs_in(inst_parent(x2)); }
                    return slp_comes_before(x1, x2);
                }
                let id1 = slp_extract_index(a);
                let id2 = slp_extract_index(b);
                if id1 >= 0 && id2 < 0 { return true; }
                if id1 < 0 && id2 >= 0 { return false; }
                if id1 >= 0 && id2 >= 0 { return id1 < id2; }
                continue;
            }
            if iop(a) == iop(b) { continue; }
            return iop(a) < iop(b);
        }
        if i1 { return true; }
        if i2 { return false; }
        let c1 = is_constant(a) && !is_undef_or_poison(a);
        let c2 = is_constant(b) && !is_undef_or_poison(b);
        if c1 && c2 { continue; }
        if c1 { return true; }
        if c2 { return false; }
        let u1 = is_undef_or_poison(a);
        let u2 = is_undef_or_poison(b);
        if !u1 && !u2 {
            let d1 = slp_value_id(a);
            let d2 = slp_value_id(b);
            if d1 == d2 { continue; }
            if d1 < d2 { return true; }
            if d1 > d2 { return false; }
        }
        if !u1 { return true; }
        if !u2 { return false; }
    }
    return false;
}
// AreCompatiblePHIs(VL, V1) with VL.back() = v2 (-1: VL empty)
fn slp_phis_compatible(v2: i32, v1: i32) -> bool {
    if v2 < 0 || v1 == v2 { return true; }
    if vals[v1].ty as i32 != vals[v2].ty as i32 { return false; }
    let o1 = slp_p2o(v1);
    let o2 = slp_p2o(v2);
    if o1.len != o2.len { return false; }
    for k in o1.len {
        let a = o1[k];
        let b = o2[k];
        if is_undef_or_poison(a) || is_undef_or_poison(b) { continue; }
        if is_inst(a) && is_inst(b) {
            if slp_is_deleted(a) || slp_is_deleted(b) { return false; }
            if inst_parent(a) != inst_parent(b) { return false; }
            if sis_valid(slp_same_opcode2(a, b)) { continue; }
            return false;
        }
        if is_constant(a) && is_constant(b) { continue; }
        if slp_value_id(a) != slp_value_id(b) { return false; }
    }
    return true;
}
// tryToVectorizeSequence<Value>(Incoming, PHICompare, AreCompatiblePHIs, tryToVectorizeList, MaxVFOnly = true)
fn slp_try_vectorize_phi_sequence(incoming: i32[>..<]&) -> bool {
    var changed = false;
    std_stable_sort(incoming, 0, incoming.len) { a, b => slp_phi_less(a, b) };
    var cands: i32[>..<] = [];
    var vl: i32[>..<] = [];
    var it: i64 = 0;
    let e = incoming.len;
    while it != e {
        vl.clear();
        let i = incoming[it];
        if !is_inst(i) || slp_is_deleted(i) || !slp_is_valid_element_type(slp_value_type(i, false)) { it++; continue; }
        var st = it;
        while st != e {
            let x = incoming[st];
            let back = if vl.len > 0 { vl[vl.len - 1] } else { -1 };
            if !(!is_inst(x) || slp_is_deleted(x) || slp_phis_compatible(back, x)) { break; }
            st++;
            if is_inst(x) && !slp_is_deleted(x) { vl.push(x); }
        }
        let n = vl.len;
        if slp_dbg_on { errs("SLP: Trying to vectorize starting at nodes ("); errs_int(n); errs(")\n"); slp_dbg_flush(); }
        if n > 1 && slp_try_to_vectorize_list_r(vl, true, false) {
            changed = true;
            cands.clear();
            for v in vl { if is_inst(v) && !slp_is_deleted(v) { cands.push(v); } }
        } else {
            let es = slp_vector_element_size(incoming[it]);
            let mn = if slp_max_vreg / es > 2 { slp_max_vreg / es } else { 2 };
            if n < mn && (cands.len == 0 || vals[cands[0]].ty as i32 == vals[incoming[it]].ty as i32) {
                for v in vl { if is_inst(v) && !slp_is_deleted(v) { cands.push(v); } }
            }
        }
        if cands.len > 1 && (st == e || vals[incoming[st]].ty as i32 != vals[incoming[it]].ty as i32) {
            if slp_try_to_vectorize_list_r(cands, false, false) {
                changed = true;
            } else {
                // MaxVFOnly: retry each compatible sub-sequence
                var vl2: i32[>..<] = [];
                var it2: i64 = 0;
                let e2 = cands.len;
                while it2 != e2 {
                    vl2.clear();
                    let x = cands[it2];
                    if !is_inst(x) || slp_is_deleted(x) { it2++; continue; }
                    var st2 = it2;
                    while st2 != e2 {
                        let y = cands[st2];
                        if !(!is_inst(y) || slp_is_deleted(y) || slp_phis_compatible(y, cands[it2])) { break; }
                        st2++;
                        if is_inst(y) && !slp_is_deleted(y) { vl2.push(y); }
                    }
                    if vl2.len > 1 && slp_try_to_vectorize_list_r(vl2, false, false) { changed = true; }
                    it2 = st2;
                }
            }
            cands.clear();
        }
        it = st;
    }
    return changed;
}
// the PHI loop of vectorizeChainsInBlock(BB, R)
fn slp_vectorize_block_phis(bb: i32) -> bool {
    var changed = false;
    sh_clear(SH_P2O);
    slp_p2o_v.clear(); slp_p2o_at.clear(); slp_p2o_n.clear();
    sh_clear(SH_PHIVIS);   // VisitedInstrs
    var have = false;
    loop {
        var incoming: i32[>..<] = [];
        var x = block_first(bb);
        while x >= 0 && iop(x) == OP_PHI {
            if phi_nincoming(x) > 128 { break; }
            if !sh_has(SH_PHIVIS, x as i64, 0) && !slp_is_deleted(x) && slp_is_valid_element_type(vals[x].ty) { incoming.push(x); }
            x = inst_next(x);
        }
        if incoming.len <= 1 { break; }
        for v in incoming { slp_p2o_build(v); }
        have = slp_try_vectorize_phi_sequence(incoming);
        changed = changed || have;
        for v in incoming { sh_add(SH_PHIVIS, v as i64, 0); }
        if !have { break; }
    }
    return changed;
}
