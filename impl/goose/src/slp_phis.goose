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
fn slp_try_vectorize_phi_sequence(incoming: i32[>..<]&) -> bool { return slp_try_vectorize_value_sequence(incoming, 0); }
// compareCmp<IsCompatibility>(V, V2, TLI, DT)
fn slp_compare_cmp(v: i32, v2: i32, compat: bool) -> bool {
    if v == v2 { return compat; }
    let t1 = slp_type_id(vals[op(v, 0)].ty);
    let t2 = slp_type_id(vals[op(v2, 0)].ty);
    if t1 < t2 { return !compat; }
    if t1 > t2 { return false; }
    let s1 = tt_scalar_bits(vals[op(v, 0)].ty);
    let s2 = tt_scalar_bits(vals[op(v2, 0)].ty);
    if s1 < s2 { return !compat; }
    if s1 > s2 { return false; }
    let p1 = inst_pred(v);
    let p2 = inst_pred(v2);
    let sp1 = slp_swapped_pred(p1);
    let sp2 = slp_swapped_pred(p2);
    let b1 = if p1 < sp1 { p1 } else { sp1 };
    let b2 = if p2 < sp2 { p2 } else { sp2 };
    if b1 < b2 { return !compat; }
    if b1 > b2 { return false; }
    let c1p = p1 == b1;
    let c2p = p2 == b1;
    let e = nops(v);
    for i in e {
        let o1 = op(v, if c1p { i } else { e - i - 1 });
        let o2 = op(v2, if c2p { i } else { e - i - 1 });
        if o1 == o2 { continue; }
        let d1 = slp_value_id(o1);
        let d2 = slp_value_id(o2);
        if d1 < d2 { return !compat; }
        if d1 > d2 { return false; }
        if is_inst(o1) && is_inst(o2) {
            if compat {
                if inst_parent(o1) != inst_parent(o2) { return false; }
            } else {
                let n1 = slp_dfs_node(inst_parent(o1));
                let n2 = slp_dfs_node(inst_parent(o2));
                if !n1 { return n2; }
                if !n2 { return false; }
                if inst_parent(o1) != inst_parent(o2) { return slp_dom_dfs_in(inst_parent(o1)) < slp_dom_dfs_in(inst_parent(o2)); }
            }
            let s = slp_same_opcode2(o1, o2);
            if sis_valid(s) && (compat || !sis_is_alt_shuffle(s)) { continue; }
            if compat { return false; }
            if iop(o1) != iop(o2) { return iop(o1) < iop(o2); }
        }
    }
    return compat;
}
// the OperandGroupKeys of vectorizeNonVectorizableInsts (kind 2): value -> key index
var slp_nvk_v: i32[>..<];
var slp_nvk_k: i64[>..<];
var slp_nvk_id: i64[>..<];
var slp_nvk_sub: i64[>..<];
var slp_nvk_fn: i32[>..<];
var slp_nvk_pos: i64[>..<];
let SH_NVK: i64 = 29;
fn slp_nv_keys_set(vs: const i32[:], k: const i64[:], id: const i64[:], sub: const i64[:], fnm: const i32[:], pos: const i64[:]) {
    slp_nvk_v.clear(); slp_nvk_k.clear(); slp_nvk_id.clear(); slp_nvk_sub.clear(); slp_nvk_fn.clear(); slp_nvk_pos.clear();
    sh_clear(SH_NVK);
    for j in vs.len {
        sh_set(SH_NVK, vs[j] as i64, 0, j);
        slp_nvk_v.push(vs[j]); slp_nvk_k.push(k[j]); slp_nvk_id.push(id[j]); slp_nvk_sub.push(sub[j]); slp_nvk_fn.push(fnm[j]);
        slp_nvk_pos.push(pos[j]);
    }
}
fn slp_nvk_eq(a: i64, b: i64) -> bool {
    return slp_nvk_k[a] == slp_nvk_k[b] && slp_nvk_id[a] == slp_nvk_id[b] && slp_nvk_sub[a] == slp_nvk_sub[b] &&
           slp_fn_name_cmp(slp_nvk_fn[a], slp_nvk_fn[b]) == 0 && slp_nvk_pos[a] == slp_nvk_pos[b];
}
fn slp_fn_name_cmp(f1: i32, f2: i32) -> i64 {
    let a: const u8[:] = if f1 >= 0 && vals[f1].name >= 0 { sbytes(vals[f1].name) } else { "" };
    let b: const u8[:] = if f2 >= 0 && vals[f2].name >= 0 { sbytes(vals[f2].name) } else { "" };
    let n = if a.len < b.len { a.len } else { b.len };
    for k in n { if a[k] != b[k] { return if a[k] < b[k] { -1 } else { 1 }; } }
    if a.len == b.len { return 0; }
    return if a.len < b.len { -1 } else { 1 };
}
fn slp_nvk_less(a: i64, b: i64) -> bool {
    if slp_nvk_k[a] != slp_nvk_k[b] { return slp_nvk_k[a] < slp_nvk_k[b]; }
    if slp_nvk_id[a] != slp_nvk_id[b] { return slp_nvk_id[a] < slp_nvk_id[b]; }
    if slp_nvk_sub[a] != slp_nvk_sub[b] { return slp_nvk_sub[a] < slp_nvk_sub[b]; }
    let c = slp_fn_name_cmp(slp_nvk_fn[a], slp_nvk_fn[b]);
    if c != 0 { return c < 0; }
    return slp_nvk_pos[a] < slp_nvk_pos[b];
}
fn slp_seq_less(kind: i64, a: i32, b: i32) -> bool {
    if kind == 0 { return slp_phi_less(a, b); }
    if kind == 2 {
        // OperandSorter
        if a == b { return false; }
        let ka = sh_get(SH_NVK, a as i64, 0, -1);
        let kb = sh_get(SH_NVK, b as i64, 0, -1);
        if !slp_nvk_eq(ka, kb) { return slp_nvk_less(ka, kb); }
        let ta = slp_type_id(vals[a].ty);
        let tb = slp_type_id(vals[b].ty);
        if ta != tb { return ta < tb; }
        let sa = tt_scalar_bits(vals[a].ty);
        let sb = tt_scalar_bits(vals[b].ty);
        if sa != sb { return sa < sb; }
        if iop(a) != iop(b) { return iop(a) < iop(b); }
        return slp_comes_before(a, b);
    }
    if a == b { return false; }
    return slp_compare_cmp(a, b, false);
}
// AreCompatible(VL with back `v2` (-1: empty), V1)
fn slp_seq_compatible(kind: i64, v2: i32, v1: i32) -> bool {
    if kind == 0 { return slp_phis_compatible(v2, v1); }
    if kind == 2 {
        if v2 < 0 || v2 == v1 { return true; }
        let kb = sh_get(SH_NVK, v2 as i64, 0, -1);
        let k = sh_get(SH_NVK, v1 as i64, 0, -1);
        if !slp_nvk_eq(kb, k) { return false; }
        return vals[v2].ty as i32 == vals[v1].ty as i32 && iop(v2) == iop(v1);
    }
    if v2 < 0 || v2 == v1 { return true; }
    return slp_compare_cmp(v1, v2, true);
}
// TryToVectorizeHelper(Candidates, MaxVFOnly)
fn slp_seq_helper(kind: i64, cands: const i32[:], max_vf_only: bool) -> bool {
    if kind == 1 {
        for v in cands {
            var u = vals[v].first_use;
            while u >= 0 {
                let usr = uses[u].user;
                if is_inst_op(usr, OP_SELECT) && inst_parent(usr) != inst_parent(v) { return false; }
                u = uses[u].next;
            }
        }
    }
    return slp_try_to_vectorize_list_r(cands, max_vf_only, false);
}
// tryToVectorizeSequence<Value>(Incoming, Comparator, AreCompatible, TryToVectorizeHelper, MaxVFOnly = true, R)
fn slp_try_vectorize_value_sequence(incoming: i32[>..<]&, kind: i64) -> bool {
    var changed = false;
    std_stable_sort(incoming, 0, incoming.len) { a, b => slp_seq_less(kind, a, b) };
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
            if !(!is_inst(x) || slp_is_deleted(x) || slp_seq_compatible(kind, back, x)) { break; }
            st++;
            if is_inst(x) && !slp_is_deleted(x) { vl.push(x); }
        }
        let n = vl.len;
        if slp_dbg_on { errs("SLP: Trying to vectorize starting at nodes ("); errs_int(n); errs(")\n"); slp_dbg_flush(); }
        if n > 1 && slp_seq_helper(kind, vl, true) {
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
            if slp_seq_helper(kind, cands, false) {
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
                        if !(!is_inst(y) || slp_is_deleted(y) || slp_seq_compatible(kind, y, cands[it2])) { break; }
                        st2++;
                        if is_inst(y) && !slp_is_deleted(y) { vl2.push(y); }
                    }
                    if vl2.len > 1 && slp_seq_helper(kind, vl2, false) { changed = true; }
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
