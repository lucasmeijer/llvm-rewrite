// SLPVectorizer: HorizontalReduction matching. Port of llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp's
// HorizontalReduction (lines 29003-30400): isCmpSelMinMax, isBoolLogicOp, isVectorizable, getRdxOperand, getRdxKind,
// getFirstOperandIndex, getNumberOfOperands, hasRequiredNumberOfUses, initReductionOps, addReductionOps,
// isGoodForReduction, optimizeReducedVals, matchOrderedReduction, matchAssociativeReduction (with
// generateKeySubkey and its loads subkey generator) and tryToReduce up to the point where a non-tiny tree goes to
// the reordering and the cost model (not ported: slp_after_tree fails loudly). The emission parts of tryToReduce
// (const.rdx, emitScaleForReusedOps) and tryToReduceOrdered fail loudly too.
//
// The keys of generateKeySubkey are LLVM hash_codes, of which only equality matters: they are reproduced as 64-bit
// mixes of the same components (hash_value of an integer, of a pointer, hash_combine), so equal inputs give equal
// keys.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import pm;
import flags;
import vt;
import laa;
import cfgutil;
import tti;
import tti_x86;
import tti_vec;
import slp_util;
import slp_keys;
import slp_pipeline;
import slp_minbw;
import slp_tree;
import slp_ops;
import slp_loads;
import slp_build;
import slp_stores;
import iv_descriptors;

// RecurKind: iv_descriptors.goose's RK_* (RecurrenceDescriptor's enum)
// ReductionOrdering
let RO_UNORDERED: i64 = 0;
let RO_ORDERED: i64 = 1;
let RO_NONE: i64 = 2;

fn hr_is_cmp_sel_minmax(i: i32) -> bool { is_inst_op(i, OP_SELECT) && slp_is_cmp(op(i, 0)) && rk_is_minmax(hr_rdx_kind(i)) }
fn hr_first_operand_index(i: i32) -> i64 { if hr_is_cmp_sel_minmax(i) { 1 } else { 0 } }
fn hr_number_of_operands(i: i32) -> i64 { if hr_is_cmp_sel_minmax(i) { 3 } else { 2 } }
fn hr_rdx_operand(i: i32, idx: i64) -> i32 {
    if hr_rdx_kind(i) == RK_OR && is_inst_op(i, OP_SELECT) && idx == 1 { return op(i, 2); }
    return op(i, idx);
}
// Instruction::isAssociative (Instruction.cpp 1390; IntrinsicInst::isAssociative for intrinsics)
fn hr_is_associative(i: i32) -> bool {
    let id = inst_iid(i);
    if id != 0 { return id == IID_smax || id == IID_smin || id == IID_umax || id == IID_umin; }
    let o = iop(i);
    if o == OP_ADD || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR { return true; }
    let f = insts[inst_of(i)].fmf;
    if o == OP_FMUL { return (f & FMF_REASSOC) != 0; }
    if o == OP_FADD { return (f & FMF_REASSOC) != 0 && (f & FMF_NSZ) != 0; }
    return false;
}
// isVectorizable(Kind, I, TwoElementReduction)
fn hr_is_vectorizable(k: i32, i: i32, two: bool) -> i64 {
    if k == RK_NONE { return RO_NONE; }
    if rk_is_int_minmax(k) || hr_is_bool_logic_op(i) { return RO_UNORDERED; }
    if two { return RO_UNORDERED; }
    if k == RK_FMAX || k == RK_FMIN { return if (insts[inst_of(i)].fmf & FMF_NNAN) != 0 { RO_UNORDERED } else { RO_ORDERED }; }
    if k == RK_FMAXIMUM || k == RK_FMINIMUM { return RO_UNORDERED; }
    if hr_is_associative(i) { return RO_UNORDERED; }
    return if slp_is_commutative(i) { RO_ORDERED } else { RO_NONE };
}
fn hr_has_required_uses(cmpsel: bool, i: i32) -> bool {
    if cmpsel {
        if is_inst_op(i, OP_SELECT) { return slp_num_uses(i) == 2 && slp_has_one_use(op(i, 0)); }
        return slp_num_uses(i) == 2;
    }
    return slp_has_one_use(i);
}
fn hr_is_good_for_reduction(data: const i32[:]) -> bool {
    let i = data[0];
    return data.len > 1 || slp_is_constant(i) || (is_inst(i) && iop(i) != OP_LOAD && slp_valid_for_alternation(iop(i)));
}

// ---------------------------------------------------------------- the reduction being matched
var hr_rk: i64 = RO_NONE;
var hr_kind: i32 = RK_NONE;
var hr_root: i32 = -1;
var hr_limit: i64 = 4;
var hr_ops0: i32[>..<];          // ReductionOps[0]
var hr_ops1: i32[>..<];          // ReductionOps[1] (cmp + select min/max)
var hr_nops_lists: i64 = 0;
var hr_rv: i32[>..<];            // ReducedVals: groups of values (runs)
var hr_rv_at: i64[>..<];
var hr_rv_n: i64[>..<];
let SH_HR_R2O: i64 = 23;         // ReducedValsToOps: value -> count
let SH_HR_OPS: i64 = 24;         // the Operands set of matchAssociativeReduction
let SH_HR_VIS: i64 = 25;

fn hr_reset() {
    hr_ops0.clear(); hr_ops1.clear(); hr_nops_lists = 0;
    hr_rv.clear(); hr_rv_at.clear(); hr_rv_n.clear();
    sh_clear(SH_HR_R2O);
}
fn hr_init_reduction_ops(i: i32) { hr_ops0.clear(); hr_ops1.clear(); hr_nops_lists = if hr_is_cmp_sel_minmax(i) { 2 } else { 1 }; }
fn hr_add_reduction_ops(i: i32) {
    if hr_is_cmp_sel_minmax(i) { hr_ops0.push(op(i, 0)); hr_ops1.push(i); } else { hr_ops0.push(i); }
}
fn hr_r2o_add(v: i32) { sh_set(SH_HR_R2O, v as i64, 0, sh_get(SH_HR_R2O, v as i64, 0, 0) + 1); }
fn hr_mark_analyzed_roots() {
    for x in hr_ops0 { sh_add(SH_ANRR, x as i64, 0); }
    for x in hr_ops1 { sh_add(SH_ANRR, x as i64, 0); }
}
fn hr_group(g: i64) -> const i32[:] { let a = hr_rv_at[g]; return hr_rv[a..a + hr_rv_n[g]]; }
fn hr_new_group() { hr_rv_at.push(hr_rv.len); hr_rv_n.push(0); }
fn hr_group_push(v: i32) {
    let g = hr_rv_n.len - 1;
    if hr_rv_at[g] + hr_rv_n[g] != hr_rv.len {
        // move the last group to the end of the pool
        let a = hr_rv_at[g];
        let n = hr_rv_n[g];
        let na = hr_rv.len;
        for k in n { hr_rv.push(hr_rv[a + k]); }
        hr_rv_at[g] = na;
    }
    hr_rv.push(v);
    hr_rv_n[g] += 1;
}


// ---------------------------------------------------------------- matching
// matchOrderedReduction(R, Root, MatchLHS)
fn hr_match_ordered(root: i32, match_lhs: bool) -> bool {
    hr_reset();
    hr_kind = hr_rdx_kind(root);
    if hr_kind != RK_FADD { return false; }
    if hr_is_vectorizable(hr_kind, root, false) != RO_ORDERED { return false; }
    if hr_is_cmp_sel_minmax(root) || hr_is_bool_logic_op(root) { return false; }
    let ty: i32 = vals[root].ty;
    if !slp_is_valid_element_type(ty) || ty_kind(ty) == TK_PTR { return false; }
    hr_rk = RO_ORDERED;
    hr_root = root;
    let bb = inst_parent(root);
    let first = hr_first_operand_index(root);
    let chain_idx = if match_lhs { first } else { first + 1 };
    let leaf_idx = if match_lhs { first + 1 } else { first };
    hr_init_reduction_ops(root);
    hr_new_group();
    sh_clear(SH_HR_VIS);
    var tn = root;
    var depth: i64 = 0;
    var complete = false;
    let rmd = flag_int("slp-recursion-max-depth", 12);
    while tn >= 0 {
        if depth > rmd { break; }
        depth++;
        if hr_rv_n[0] >= 1024 { break; }
        if !sh_add(SH_HR_VIS, tn as i64, 0) { break; }
        if hr_rdx_kind(tn) != hr_kind { break; }
        if inst_parent(tn) != bb { break; }
        hr_add_reduction_ops(tn);
        let leaf = hr_rdx_operand(tn, leaf_idx);
        let chain = hr_rdx_operand(tn, chain_idx);
        hr_r2o_add(leaf);
        hr_r2o_add(chain);
        hr_group_push(leaf);
        if !is_inst(chain) || hr_rdx_kind(chain) != hr_kind || !hr_has_required_uses(false, chain) {
            hr_group_push(chain);
            complete = true;
            break;
        }
        tn = chain;
    }
    if !complete || hr_rv_n[0] < hr_limit {
        hr_mark_analyzed_roots();
        hr_reset();
        return false;
    }
    return true;
}
// matchAssociativeReduction(R, Root, SE, DT, DL, TTI, TLI)
fn hr_match_associative(root: i32) -> bool {
    hr_reset();
    hr_kind = hr_rdx_kind(root);
    hr_rk = hr_is_vectorizable(hr_kind, root, false);
    if hr_rk == RO_NONE { return false; }
    let ty: i32 = vals[root].ty;
    if !slp_is_valid_element_type(ty) || ty_kind(ty) == TK_PTR { return false; }
    if is_inst_op(root, OP_SELECT) && !slp_has_one_use(op(root, 0)) { hr_rk = RO_ORDERED; }
    hr_root = root;
    let bb = inst_parent(root);
    let cmpsel = hr_is_cmp_sel_minmax(root);
    let rmd = flag_int("slp-recursion-max-depth", 12);
    var wl_i: i32[>..<] = [];
    var wl_l: i64[>..<] = [];
    wl_i.push(root); wl_l.push(0);
    sh_clear(SH_HR_OPS);
    var por_i: i32[>..<] = [];
    var por_l: i64[>..<] = [];
    hr_init_reduction_ops(root);
    hr_lm_key.clear(); hr_lm_ptr.clear(); hr_lm_li.clear(); hr_lk_used.clear();
    var cands: i32[>..<] = [];
    var adjusted = false;
    sh_clear(SH_HR_VIS);
    while wl_i.len > 0 {
        let tn = wl_i.pop();
        let level = wl_l.pop();
        if !sh_add(SH_HR_VIS, tn as i64, 0) { continue; }
        var prv: i32[>..<] = [];
        var pro: i32[>..<] = [];
        // CheckOperands(TreeN, PossibleRedVals, PossibleReductionOps, Level)
        var i = hr_number_of_operands(tn);
        let fo = hr_first_operand_index(tn);
        while i > fo {
            i--;
            let ev = hr_rdx_operand(tn, i);
            hr_r2o_add(ev);
            let ei = is_inst(ev);
            var is_rv = !ei || level > rmd || hr_rdx_kind(ev) != hr_kind || cmpsel != hr_is_cmp_sel_minmax(ev);
            var crk = if is_rv { RO_NONE } else { hr_is_vectorizable(hr_kind, ev, false) };
            if !is_rv && crk == RO_UNORDERED && hr_rk == RO_UNORDERED && !hr_has_required_uses(cmpsel, ev) {
                is_rv = true;
                crk = RO_NONE;
                if prv.len < hr_limit && !sh_has(SH_HR_OPS, ev as i64, 0) { por_i.push(ev); por_l.push(level); }
            }
            var all_const_ops = false;
            if ei && sh_has(SH_ANRR, ev as i64, 0) {
                all_const_ops = true;
                for k in nops(ev) { if !is_constant(op(ev, k)) { all_const_ops = false; break; } }
            }
            if crk == RO_NONE || (ei && sh_has(SH_HR_OPS, ev as i64, 0)) || all_const_ops {
                prv.push(ev);
                if ei && !hr_is_cmp_sel_minmax(ev) { for k in nops(ev) { sh_add(SH_HR_OPS, op(ev, k) as i64, 0); } }
                continue;
            }
            if crk == RO_ORDERED { hr_rk = RO_ORDERED; }
            pro.push(ev);
        }
        hr_add_reduction_ops(tn);
        for x in prv { cands.push(x); }
        var k = pro.len;
        while k > 0 { k--; let x = pro[k]; wl_i.push(x); wl_l.push(if inst_parent(x) == bb { 0 } else { level + 1 }); }
        if wl_i.len == 0 && cands.len < hr_limit && por_i.len > 0 && hr_rk == RO_UNORDERED {
            hr_rk = RO_ORDERED;
            adjusted = true;
            var kept: i32[>..<] = [];
            for v in cands {
                var drop_ = false;
                if is_inst(v) { for x in por_i { if x == v { drop_ = true; break; } } }
                if !drop_ { kept.push(v); }
            }
            cands.clear();
            for v in kept { cands.push(v); }
            for j in por_i.len { wl_i.push(por_i[j]); wl_l.push(por_l[j]); }
            por_i.clear(); por_l.clear();
        }
    }
    if cands.len > 1024 && adjusted && ty_is_int(ty_scalar(vals[cands[0]].ty)) { return false; }
    // PossibleReducedVals: MapVector<Key, MapVector<SubKey, MapVector<Value *, count>>>
    var k1: u64[>..<] = [];
    var k2_k1: i64[>..<] = [];
    var k2: u64[>..<] = [];
    var v_k2: i64[>..<] = [];
    var vv: i32[>..<] = [];
    var vc: i64[>..<] = [];
    for v in cands {
        if hr_rk == RO_ORDERED && !is_inst(v) { continue; }
        let key, sub = hr_key_subkey(v, false);
        var a: i64 = -1;
        for j in k1.len { if k1[j] == key { a = j; break; } }
        if a < 0 { a = k1.len; k1.push(key); }
        var b: i64 = -1;
        for j in k2.len { if k2_k1[j] == a && k2[j] == sub { b = j; break; } }
        if b < 0 { b = k2.len; k2.push(sub); k2_k1.push(a); }
        var c: i64 = -1;
        for j in vv.len { if v_k2[j] == b && vv[j] == v { c = j; break; } }
        if c < 0 { c = vv.len; vv.push(v); v_k2.push(b); vc.push(0); }
        vc[c] += 1;
    }
    for a in k1.len {
        // PossibleRedValsVect: one list per subkey, values repeated by their counts (stable by count)
        var lists_at: i64[>..<] = [];
        var lists_n: i64[>..<] = [];
        var pool: i32[>..<] = [];
        for b in k2.len {
            if k2_k1[b] != a { continue; }
            var ids: i64[>..<] = [];
            for c in vv.len { if v_k2[c] == b { ids.push(c); } }
            for x in 1..ids.len {
                var j = x;
                while j > 0 && vc[ids[j]] < vc[ids[j - 1]] { let t = ids[j]; ids[j] = ids[j - 1]; ids[j - 1] = t; j--; }
            }
            lists_at.push(pool.len);
            let st = pool.len;
            for c in ids { for r in vc[c] { pool.push(vv[c]); } }
            lists_n.push(pool.len - st);
        }
        var ord: i64[>..<] = [];
        for x in lists_at.len { ord.push(x); }
        for x in 1..ord.len {
            var j = x;
            while j > 0 && lists_n[ord[j]] > lists_n[ord[j - 1]] { let t = ord[j]; ord[j] = ord[j - 1]; ord[j - 1] = t; j--; }
        }
        var first = true;
        for li in ord {
            let data = pool[lists_at[li]..lists_at[li] + lists_n[li]];
            if first {
                first = false;
                hr_new_group();
            } else if !hr_is_good_for_reduction(data) {
                let ld = is_inst_op(data[0], OP_LOAD);
                let lastg = hr_group(hr_rv_n.len - 1);
                let lld = lastg.len > 0 && is_inst_op(lastg[0], OP_LOAD);
                if !ld || !lld || get_underlying_object(op(data[0], 0), 6) != get_underlying_object(op(lastg[0], 0), 6) { hr_new_group(); }
            }
            var r = data.len;
            while r > 0 { r--; hr_group_push(data[r]); }
        }
    }
    hr_optimize_reduced_vals();
    // stable_sort(ReducedVals) by size, larger first
    var gord: i64[>..<] = [];
    for g in hr_rv_n.len { gord.push(g); }
    for x in 1..gord.len {
        var j = x;
        while j > 0 && hr_rv_n[gord[j]] > hr_rv_n[gord[j - 1]] { let t = gord[j]; gord[j] = gord[j - 1]; gord[j - 1] = t; j--; }
    }
    var na: i64[>..<] = [];
    var nn: i64[>..<] = [];
    for g in gord { na.push(hr_rv_at[g]); nn.push(hr_rv_n[g]); }
    hr_rv_at.clear(); hr_rv_n.clear();
    for g in na.len { hr_rv_at.push(na[g]); hr_rv_n.push(nn[g]); }
    return true;
}
// optimizeReducedVals(R, DT, DL, TTI, TLI)
fn hr_optimize_reduced_vals() {
    var zext_idx: i64 = -1;
    var sel_idx: i64 = -1;
    for g in hr_rv_n.len {
        let f = hr_group(g)[0];
        if !is_inst(f) { continue; }
        if iop(f) == OP_ZEXT && zext_idx < 0 { zext_idx = g; }
        if iop(f) == OP_SELECT && sel_idx < 0 { sel_idx = g; }
    }
    if zext_idx >= 0 && sel_idx >= 0 {
        let z = hr_group(zext_idx)[0];
        if ty_is_int(vals[op(z, 0)].ty) && ty_bits(vals[op(z, 0)].ty) == 1 && vals[z].ty as i32 == vals[hr_group(sel_idx)[0]].ty as i32 {
            // ReducedVals[ZExtIdx].append(ReducedVals[SelectIdx]); erase SelectIdx
            var tmp: i32[>..<] = [];
            for v in hr_group(zext_idx) { tmp.push(v); }
            for v in hr_group(sel_idx) { tmp.push(v); }
            let at = hr_rv.len;
            for v in tmp { hr_rv.push(v); }
            hr_rv_at[zext_idx] = at;
            hr_rv_n[zext_idx] = tmp.len;
            hr_rv_at.remove_at(sel_idx);
            hr_rv_n.remove_at(sel_idx);
        }
    }
    if hr_rv_n.len == 2 && (hr_rv_n[0] == 1 || hr_rv_n[1] == 1) {
        var ops: i32[>..<] = [];
        for v in hr_group(0) { ops.push(v); }
        for v in hr_group(1) { ops.push(v); }
        let s = slp_build_instructions_state(ops, true, true);
        if sis_valid(s) && s.copy && sis_opcode(s) == OP_SHL {
            if hr_rv_n[1] == 1 && hr_rv_n[0] != 1 {
                let ta = hr_rv_at[0]; let tn = hr_rv_n[0];
                hr_rv_at[0] = hr_rv_at[1]; hr_rv_n[0] = hr_rv_n[1];
                hr_rv_at[1] = ta; hr_rv_n[1] = tn;
            }
            var back: i32[>..<] = [];
            for v in hr_group(1) { back.push(v); }
            fn shl_c(v: i32) -> i64 { if is_inst_op(v, OP_SHL) && is_cint(op(v, 1)) { return cint_lo(op(v, 1)) as i64; } return -1; }
            for x in 1..back.len {
                var j = x;
                while j > 0 {
                    let c1 = shl_c(back[j]);
                    let c2 = shl_c(back[j - 1]);
                    let less = c1 >= 0 && (c2 < 0 || c1 < c2);
                    if !less { break; }
                    let t = back[j]; back[j] = back[j - 1]; back[j - 1] = t;
                    j--;
                }
            }
            var tmp: i32[>..<] = [];
            for v in hr_group(0) { tmp.push(v); }
            for v in back { tmp.push(v); }
            let at = hr_rv.len;
            for v in tmp { hr_rv.push(v); }
            hr_rv_at[0] = at;
            hr_rv_n[0] = tmp.len;
            hr_rv_at.pop();
            hr_rv_n.pop();
        }
    }
}

// ---------------------------------------------------------------- tryToReduce (up to the trees)
fn hr_any_gathered_in_ignore_list() -> bool {
    for x in hr_ops0 { if slp_is_gathered(x) { return true; } }
    for x in hr_ops1 { if slp_is_gathered(x) { return true; } }
    return false;
}
// tryToReduce(V, DL, TTI, TLI, AC, DT): the vectorized value (never: nothing is emitted yet), -1 = nullptr
fn hr_try_to_reduce() -> i32 {
    let rvmax: i64 = if hr_rk == RO_ORDERED && ty_is_int(ty_scalar(vals[hr_root].ty)) { 48 } else { 128 };
    var nred: i64 = 0;
    var all_ok = true;
    for g in hr_rv_n.len {
        let gv = hr_group(g);
        if hr_is_good_for_reduction(gv) { nred += gv.len; }
        if !(gv.len < 2 || !slp_all_constant(gv) || !slp_is_splat(gv)) { all_ok = false; }
    }
    if nred < hr_limit && all_ok {
        hr_mark_analyzed_roots();
        return -1;
    }
    // IgnoreList (cleared for ordered reductions)
    var ignore: i32[>..<] = [];
    for x in hr_ops0 { ignore.push(x); }
    for x in hr_ops1 { ignore.push(x); }
    var rdx_fmf: u8 = FMF_FAST;
    for x in ignore { if is_fp_math_operator(x) { rdx_fmf = rdx_fmf & insts[inst_of(x)].fmf; } }
    if hr_rk == RO_ORDERED { ignore.clear(); }
    var check_reused = false;
    // the grouping into LocalReducedVals / States
    var lrv: i32[>..<] = [];
    var lrv_at: i64[>..<] = [];
    var lrv_n: i64[>..<] = [];
    var st_main: i32[>..<] = [];
    var st_alt: i32[>..<] = [];
    var st_copy: bool[>..<] = [];
    let two_groups = hr_rv_n.len == 2;
    let two_small = two_groups && hr_rv_n[0] == hr_rv_n[1] && hr_rv_n[0] < hr_limit;
    fn push_group(xs: const i32[:], s: SIS) {
        lrv_at.push(lrv.len);
        for x in xs { lrv.push(x); }
        lrv_n.push(xs.len);
        st_main.push(s.main); st_alt.push(s.alt); st_copy.push(s.copy);
    }
    fn set_back(xs: const i32[:], s: SIS) {
        let g = lrv_n.len - 1;
        lrv_at[g] = lrv.len;
        for x in xs { lrv.push(x); }
        lrv_n[g] = xs.len;
        st_main[g] = s.main; st_alt[g] = s.alt; st_copy[g] = s.copy;
    }
    fn back_group() -> const i32[:] { let g = lrv_n.len - 1; return lrv[lrv_at[g]..lrv_at[g] + lrv_n[g]]; }
    for g in hr_rv_n.len {
        var rvg: i32[>..<] = [];
        for x in hr_group(g) { rvg.push(x); }
        let nb = st_main.len;
        if is_undef_or_poison(rvg[0]) && (nb == 0 || st_main[nb - 1] < 0 || iop(st_main[nb - 1]) == OP_LOAD) {
            push_group(rvg, sis_invalid());
            continue;
        }
        if lrv_n.len > 0 && is_undef_or_poison(back_group()[0]) && is_inst_op(rvg[0], OP_LOAD) {
            push_group(rvg, slp_get_same_opcode(rvg));
            continue;
        }
        if !two_small {
            var ops: i32[>..<] = [];
            if lrv_n.len > 0 { for x in back_group() { ops.push(x); } }
            for x in rvg { ops.push(x); }
            var s = slp_build_instructions_state(ops, true, false);
            if sis_valid(s) {
                if lrv_n.len == 0 { push_group(ops, s); continue; }
                set_back(ops, s);
                continue;
            }
            if two_groups {
                let m, a = slp_main_alt_no_state(ops);
                s = SIS { main: m, alt: a, copy: false };
                if m >= 0 && a >= 0 {
                    let ok, r1, n1, r2, n2, rr, nr = slp_can_build_split_node(ops, s);
                    if ok {
                        if lrv_n.len == 0 { push_group(ops, s); continue; }
                        set_back(ops, s);
                        continue;
                    }
                }
            }
        }
        push_group(rvg, slp_get_same_opcode(rvg));
    }
    let ngroups = lrv_n.len;
    var gi: i64 = 0;
    while gi < ngroups {
        let i = gi;
        gi++;
        let s = SIS { main: st_main[i], alt: st_alt[i], copy: st_copy[i] };
        var cands: i32[>..<] = [];
        var excluded: i32[>..<] = [];
        let orig = lrv[lrv_at[i]..lrv_at[i] + lrv_n[i]];
        for rv in orig {
            let inst = is_inst(rv);
            if inst && slp_is_deleted(rv) { continue; }
            if inst && slp_is_vector_like_inst_with_const_ops(rv) &&
               (!sis_valid(s) || (sis_matching(s, rv) < 0 && !sis_is_copyable_element(s, rv))) {
                excluded.push(rv);
                continue;
            }
            if sis_valid(s) && !inst && !is_undef_or_poison(rv) && !sis_is_copyable_element(s, rv) { continue; }
            cands.push(rv);
        }
        if sis_valid(s) && sis_opcode(s) == OP_EXTRACTELEMENT && !sis_is_alt_shuffle(s) && i + 1 < ngroups {
            var common: i32[>..<] = [];
            for x in cands { common.push(x); }
            for x in lrv[lrv_at[i + 1]..lrv_at[i + 1] + lrv_n[i + 1]] { if is_inst_op(x, OP_EXTRACTELEMENT) { common.push(x); } }
            var m: i32[>..<] = [];
            if slp_is_fixed_vector_shuffle(common, m) >= 0 {
                gi++;
                cands.clear();
                for x in common { cands.push(x); }
            }
        }
        if cands.len > 1 && slp_all_constant(cands) {
            if hr_rk == RO_ORDERED { continue; }
            slp_fail("HorizontalReduction: folding constant reduced values (const.rdx)");
        }
        var nrv = cands.len;
        if nrv < hr_limit && (nrv < 2 || !slp_is_splat(cands)) { continue; }
        let identity_ok = hr_rk == RO_UNORDERED && hr_kind != RK_MUL && hr_kind != RK_FMUL;
        // SameValuesCounter: MapVector<orig value, count>
        var svc_v: i32[>..<] = [];
        var svc_n: i64[>..<] = [];
        fn svc_add(v: i32) {
            for j in svc_v.len { if svc_v[j] == v { svc_n[j] += 1; return; } }
            svc_v.push(v); svc_n.push(1);
        }
        if identity_ok { for x in cands { svc_add(x); } }
        let opt_reused = identity_ok && svc_v.len != cands.len;
        if opt_reused {
            cands.clear();
            for x in svc_v { cands.push(x); }
            nrv = cands.len;
            if nrv == 1 && svc_n[0] != 1 { slp_fail("HorizontalReduction::emitScaleForReusedOps"); }
            if nrv == 1 { slp_fail("HorizontalReduction: a single reused reduced value"); }
        }
        let elt = slp_vector_element_size(cands[0]);
        var maxelts = slp_bit_floor(slp_max_vreg / elt);
        if maxelts < rvmax { maxelts = rvmax; }
        if maxelts > 4 * rvmax { maxelts = 4 * rvmax; }
        let sty: i32 = vals[cands[0]].ty;
        fn vector_factor(w0: i64) -> i64 {
            var w = slp_floor_full_vector_number_of_elements(sty, w0);
            var tp = slp_widened_type(sty, w);
            var np = slp_number_of_parts(tp, sty, 0x7FFFFFFFFFFFFFFF);
            var nregs = tv_number_of_registers(tv_register_class_for_type(true, tp));
            while np > nregs {
                w = slp_bit_floor(w - 1);
                tp = slp_widened_type(sty, w);
                np = slp_number_of_parts(tp, sty, 0x7FFFFFFFFFFFFFFF);
                nregs = tv_number_of_registers(tv_register_class_for_type(true, tp));
            }
            if np > nregs / 2 { w = slp_bit_floor(w); }
            return w;
        }
        var width = nrv;
        if !slp_allowed_non_pow2_vf(width) { width = vector_factor(width); }
        if maxelts < width { width = maxelts; }
        var start: i64 = 0;
        var pos = start;
        var prev_width = width;
        var check_local = false;
        fn any_gathered_ignore_now() -> bool {
            for x in ignore { if slp_is_gathered(x) { return true; } }
            return false;
        }
        fn adjust(ignore_vl: bool) -> bool {
            let gathered = !ignore_vl && (hr_rk == RO_ORDERED || any_gathered_ignore_now());
            if !check_local && prev_width == width { check_local = check_local || gathered; }
            pos++;
            if pos < nrv - width + 1 { return gathered; }
            pos = start;
            width--;
            if width > 1 { width = vector_factor(width); }
            return gathered;
        }
        var ign_p: i64[>..<] = [];
        var ign_w: i64[>..<] = [];
        fn ignored(p: i64, w: i64) -> bool { for j in ign_p.len { if ign_p[j] == p && ign_w[j] == w { return true; } } return false; }
        while pos < nrv - width + 1 && width >= hr_limit {
            if check_local && prev_width != width && start == 0 { check_reused = true; break; }
            prev_width = width;
            let vl = cands[pos..pos + width];
            if ignored(pos, width) ||
               (!slp_is_pow2(width) && (ignored(pos, slp_bit_floor(width)) || ignored(pos + (width - slp_bit_floor(width)), slp_bit_floor(width)))) ||
               slp_are_analyzed_reduction_vals(vl) {
                adjust(true);
                continue;
            }
            var any_del = false;
            for x in vl { if is_inst(x) && slp_is_deleted(x) { any_del = true; break; } }
            if any_del { break; }
            if hr_rk == RO_ORDERED { slp_build_tree(vl, false, ignore[..0]); } else { slp_build_tree(vl, true, ignore); }
            if slp_is_tree_tiny_and_not_fully_vectorizable(hr_rk == RO_UNORDERED) {
                if !adjust(hr_rk == RO_ORDERED && cands.len >= 64) { slp_analyzed_reduction_vals(vl); }
                continue;
            }
            var mm: i32[>..<] = [];
            for x in ignore { if rk_is_int_minmax(hr_rdx_kind(x)) { mm.push(x); } }
            let ign_reorder = (rdx_fmf & FMF_REASSOC) != 0 || ty_is_int(ty_scalar(vals[vl[0]].ty)) || hr_limit > 2 || hr_rk == RO_ORDERED;
            slp_after_tree_reduction(ign_reorder, mm);
        }
        if opt_reused { slp_fail("HorizontalReduction::emitScaleForReusedOps"); }
    }
    if !check_reused { hr_mark_analyzed_roots(); }
    return -1;
}
// TryToReduce(Inst) of vectorizeHorReduction: the reduced value or -1
fn slp_try_to_reduce_inst(inst: i32) -> i32 {
    if sh_has(SH_ANRR, inst as i64, 0) { return -1; }
    if !slp_is_reduction_candidate(inst) { return -1; }
    hr_limit = if slp_vectorize_non_pow2() { 3 } else { 4 };
    var res: i32 = -1;
    if hr_match_associative(inst) {
        let red = hr_try_to_reduce();
        if red >= 0 { if red != inst { return red; } res = red; }
    }
    if iop(inst) == OP_FADD {
        if hr_match_ordered(inst, true) { slp_fail("HorizontalReduction::tryToReduceOrdered"); }
        if hr_match_ordered(inst, false) { slp_fail("HorizontalReduction::tryToReduceOrdered"); }
    }
    return res;
}
