// SLPVectorizer: BoUpSLP::transformNodes. Port of llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp: transformNodes,
// reorderGatherNode, canConvertToFMA, matchesInversedZExtSelect, matchesSelectOfBits, and
// llvm::canConvertToMinOrMaxIntrinsic (llvm/lib/Analysis/ValueTracking.cpp).
//
// Not ported (fail loudly): matchesShlZExt (the reduced-disjoint-or bitcast nodes) and tryToVectorizeGatheredLoads
// (gatherPossiblyVectorizableLoads).
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
import datalayout;
import tti;
import tti_x86;
import tti_vec;
import gen_x86target;
import implied;
import slp_util;
import slp_tree;
import slp_ops;
import slp_sched;
import slp_loads;
import slp_build;
import slp_keys;
import slp_gather;
import slp_reorder;

// canConvertToFMA(VL, S, DT, DL, TTI, TLI): the FMA cost or TTI_INVALID
fn slp_can_convert_to_fma(vl: const i32[:], s: SIS) -> i64 {
    fn contractable(xs: const i32[:]) -> bool {
        var fmf: u8 = FMF_FAST;
        for v in xs {
            if !is_inst(v) { continue; }
            if sis_is_copyable_element(s, v) { continue; }
            let m = sis_matching(s, v);
            if s.main != m && s.alt != m { continue; }
            if is_fp_math_operator(v) { fmf = fmf & insts[inst_of(v)].fmf; }
        }
        return (fmf & FMF_CONTRACT) != 0;
    }
    if !contractable(vl) { return TTI_INVALID; }
    let opl, nopl = slp_build_operands(s, vl);
    var front: i32[>..<] = [];
    for k in vl.len { front.push(slp_vp[slp_opl[opl as i64].at as i64 + k]); }
    let ops = slp_get_same_opcode(front);
    if !sis_valid(ops) { return TTI_INVALID; }
    if sis_is_alt_shuffle(ops) || sis_opcode(ops) != OP_FMUL { return TTI_INVALID; }
    if !contractable(front) { return TTI_INVALID; }
    var fmul_fadd: i64 = 0;
    var fma: i64 = 0;
    var fmf: u8 = FMF_FAST;
    for v in vl {
        if !is_inst(v) { continue; }
        if !sis_is_copyable_element(s, v) && is_fp_math_operator(v) { fmf = fmf & insts[inst_of(v)].fmf; }
        fmul_fadd = tc_add(fmul_fadd, tv_inst_cost(v, TCK_RECIP_THROUGHPUT));
    }
    var nops_: i64 = 0;
    for k in vl.len {
        let v = vl[k];
        let o = front[k];
        if sis_is_copyable_element(s, v) { continue; }
        let oi = is_inst(o);
        if !oi || !slp_has_one_use(o) || sis_is_copyable_element(ops, o) {
            if is_inst(v) { fma = tc_add(fma, tv_inst_cost(v, TCK_RECIP_THROUGHPUT)); }
            if oi { fma = tc_add(fma, tv_inst_cost(o, TCK_RECIP_THROUGHPUT)); }
            continue;
        }
        nops_++;
        if is_fp_math_operator(o) { fmf = fmf & insts[inst_of(o)].fmf; }
        fmul_fadd = tc_add(fmul_fadd, tv_inst_cost(o, TCK_RECIP_THROUGHPUT));
    }
    let ty: i32 = vals[vl[0]].ty;
    let tys: i32[3] = [ty, ty, ty];
    fma = tc_add(fma, tc_mul(tv_intrinsic_types(IID_fmuladd, ty, tys[..], fmf, TCK_RECIP_THROUGHPUT), nops_));
    return if fma < fmul_fadd { fma } else { TTI_INVALID };
}
// llvm::canConvertToMinOrMaxIntrinsic(VL): (intrinsic id or 0, AllCmpSingleUse)
fn slp_can_convert_to_min_or_max(vl: const i32[:]) -> i32, bool {
    var all_single = true;
    var flavor = SPF_UNKNOWN;
    for v in vl {
        let f = match_select_pattern_v(v, 0);
        if !spf_is_minmax(f) { return 0, false; }
        if flavor != SPF_UNKNOWN && flavor != f { return 0, false; }
        flavor = f;
        all_single = all_single && is_inst_op(v, OP_SELECT) && slp_has_one_use(op(v, 0));
    }
    if flavor == SPF_SMIN { return IID_smin, all_single; }
    if flavor == SPF_UMIN { return IID_umin, all_single; }
    if flavor == SPF_SMAX { return IID_smax, all_single; }
    if flavor == SPF_UMAX { return IID_umax, all_single; }
    if flavor == SPF_FMAXNUM { return IID_maxnum, all_single; }
    if flavor == SPF_FMINNUM { return IID_minnum, all_single; }
    return 0, false;
}

// reorderGatherNode(TE)
fn slp_reorder_gather_node(te: i32) {
    let sc0 = te_scalars(te);
    if sc0.len == 2 || (te_has_state(te) && !te_is_alt_shuffle(te)) { return; }
    var allc = true;
    for v in sc0 { if !slp_is_constant(v) { allc = false; break; } }
    if allc { return; }
    for i in te { if te_is_same(i as i32, te_scalars(te)) { return; } }
    hr_lm_key.clear(); hr_lm_ptr.clear(); hr_lm_li.clear(); hr_lk_used.clear();
    // SortedValues: MapVector<Key, MapVector<Idx, values>>; KeyToIndex: value -> lanes
    var sv_key: u64[>..<] = [];     // outer keys
    var sv_idx_o: i64[>..<] = [];   // per inner entry: outer index
    var sv_idx: u64[>..<] = [];     // per inner entry: inner key
    var sv_vals_e: i64[>..<] = [];  // per value: inner entry
    var sv_vals_v: i32[>..<] = [];
    var kti_v: i32[>..<] = [];
    var kti_l: i64[>..<] = [];      // (value, lane) pairs in insertion order
    fn kti_has(v: i32) -> bool { for x in kti_v { if x == v { return true; } } return false; }
    fn kti_last(v: i32) -> i64 { var r: i64 = -1; for k in kti_v.len { if kti_v[k] == v { r = kti_l[k]; } } return r; }
    fn inner_last_value(e: i64) -> i32 { var r: i32 = -1; for k in sv_vals_e.len { if sv_vals_e[k] == e { r = sv_vals_v[k]; } } return r; }
    var ordered = true;
    var ninst: i64 = 0;
    let n = te_nscalars(te);
    for i in n {
        let v = te_scalar(te, i);
        var key = hk_int(1);
        var idx = hk_int(1);
        if is_inst(v) && !is_inst_op(v, OP_EXTRACTELEMENT) && !is_inst_op(v, OP_LOAD) && !is_cast_op(iop(v)) && !slp_is_deleted(v) &&
           !slp_is_vectorized(v) {
            let k2, s2 = hr_key_subkey(v, false);
            key = k2;
            idx = s2;
            ninst++;
        }
        var oi: i64 = -1;
        for k in sv_key.len { if sv_key[k] == key { oi = k; break; } }
        if oi < 0 { oi = sv_key.len; sv_key.push(key); }
        // Container = SortedValues[Key]
        var has_idx: i64 = -1;
        var last_inner: i64 = -1;
        for k in sv_idx.len { if sv_idx_o[k] == oi { last_inner = k; if sv_idx[k] == idx { has_idx = k; } } }
        if ordered && !kti_has(v) && !(slp_is_constant(v) || is_inst_op(v, OP_EXTRACTELEMENT) || slp_is_vector_like_inst_with_const_ops(v)) &&
           ((has_idx >= 0 && kti_last(inner_last_value(has_idx)) != i - 1) ||
            (last_inner >= 0 && has_idx < 0 && kti_last(inner_last_value(last_inner)) != i - 1)) {
            ordered = false;
        }
        if !kti_has(v) {
            var e = has_idx;
            if e < 0 { e = sv_idx.len; sv_idx.push(idx); sv_idx_o.push(oi); }
            sv_vals_e.push(e);
            sv_vals_v.push(v);
        }
        kti_v.push(v);
        kti_l.push(i);
    }
    var subs_at: i64[>..<] = [];
    var subs_n: i64[>..<] = [];
    var dem: bool[>..<] = [];
    for k in n { dem.push(true); }
    var ro: i32[>..<] = [];
    if !ordered && ninst > 1 {
        var cnt: i64 = 0;
        for k in n { ro.push(n as i32); }
        var nsc: i32[>..<] = [];
        slp_copy_list(te_scalars(te), nsc);
        for oi in sv_key.len {
            for ie in sv_idx.len {
                if sv_idx_o[ie] != oi as i64 { continue; }
                var sz: i64 = 0;
                var first: i32 = -1;
                for k in sv_vals_e.len {
                    if sv_vals_e[k] != ie as i64 { continue; }
                    let v = sv_vals_v[k];
                    if first < 0 { first = v; }
                    var kk: i64 = 0;
                    for j in kti_v.len {
                        if kti_v[j] != v { continue; }
                        ro[cnt + kk] = kti_l[j] as i32;
                        nsc[cnt + kk] = v;
                        kk++;
                    }
                    sz += kk;
                    cnt += kk;
                }
                if sz > 1 && is_inst(first) {
                    let subvf = slp_floor_full_vector_number_of_elements(vals[nsc[0]].ty, sz);
                    subs_at.push(cnt - sz);
                    subs_n.push(subvf);
                    for i in (cnt - sz)..(cnt - sz + subvf) { dem[i] = false; }
                } else if first >= 0 && slp_is_constant(first) {
                    for i in (cnt - sz)..cnt { dem[i] = false; }
                }
            }
        }
        te_set_scalars_list(te, nsc);
        te_set_reorder(te, ro);
    }
    if slp_te[te].nreuse > 0 || slp_te[te].nreord == 0 { return; }
    let sty: i32 = vals[te_scalar(te, 0)].ty;
    let vecty = slp_widened_type(sty, n);
    var cost: i64 = 0;
    for k in subs_at.len {
        cost = tc_add(cost, slp_shuffle_cost(SK_INSERTSUBVECTOR, vecty, slp_no_mask(), subs_at[k], slp_widened_type(sty, subs_n[k])));
    }
    cost = tc_add(cost, slp_scalarization_overhead(sty, vecty, dem, true, false, true));
    var rm: i32[>..<] = [];
    slp_copy_list(te_reorder(te), rm);
    let rsz = slp_te[te].nreord as i64;
    for i in n {
        let v = te_get_ordered(te, i);
        if is_poison(v) { rm[i] = -1; } else if slp_is_constant(v) || dem[i] { rm[i] = (i + rsz) as i32; }
    }
    var two = false;
    for x in rm { if x as i64 >= n { two = true; } }
    cost = tc_add(cost, slp_shuffle_cost(if two { SK_PERMUTETWOSRC } else { SK_PERMUTESINGLESRC }, vecty, rm, 0, -1));
    for k in n { dem[k] = true; }
    for k in n { rm[k] = -1; }
    for i in n {
        let v = te_get_ordered(te, i);
        if slp_is_constant(v) {
            dem[i] = false;
            if !is_poison(v) { rm[i] = i as i32; }
        } else {
            rm[i] = (i + n) as i32;
        }
    }
    var bv = slp_scalarization_overhead(sty, vecty, dem, true, false, true);
    var all = true;
    for d in dem { if !d { all = false; } }
    if !all { bv = tc_add(bv, slp_shuffle_cost(SK_PERMUTETWOSRC, vecty, rm, 0, -1)); }
    if cost >= bv {
        var mask: i32[>..<] = [];
        slp_copy_list(te_reorder(te), mask);
        te_reorder_scalars(te, mask);
        te_clear_reorder(te);
    }
}

// matchesInversedZExtSelect(SelectTE, InversedCmpsIndices)
fn slp_matches_inversed_zext_select(e: i32, inv: i64[>..<]&) -> bool {
    inv.clear();
    var any_zext = false;
    for v in te_scalars(e) { if is_inst_op(v, OP_ZEXT) { any_zext = true; break; } }
    if !any_zext { return false; }
    let cmp = slp_operand_entry(e, 0);
    let o1 = slp_operand_entry(e, 1);
    let o2 = slp_operand_entry(e, 2);
    if slp_te[cmp].state != TE_VECTORIZE || !te_is_alt_shuffle(cmp) || (te_opcode(cmp) != OP_ICMP && te_opcode(cmp) != OP_FCMP) ||
       slp_te[cmp].nreord > 0 || slp_te[cmp].nreuse > 0 || slp_te[o1].nreord > 0 || slp_te[o1].nreuse > 0 ||
       slp_te[o2].nreord > 0 || slp_te[o2].nreuse > 0 { return false; }
    if !te_is_gather(o1) || !te_is_gather(o2) { return false; }
    let c = te_main(cmp);
    if !slp_is_cmp(c) { return false; }
    let mp = inst_pred(c);
    let ms = has_flag(c, FL_SAMESIGN);
    let ip = slp_inverse_pred(mp);
    for idx in te_nscalars(cmp) {
        let v = te_scalar(cmp, idx);
        if !slp_is_cmp(v) { continue; }
        let p = inst_pred(v);
        if slp_cmp_pred_matching(mp, ms, p, has_flag(v, FL_SAMESIGN)) { continue; }
        if !slp_cmp_pred_matching(ip, ms, p, has_flag(v, FL_SAMESIGN)) { inv.clear(); return false; }
        if !slp_has_one_use(v) { inv.clear(); return false; }
        inv.push(idx);
    }
    if inv.len == 0 { return false; }
    let vecty = slp_widened_type(vals[op(c, 0)].ty, te_vector_factor(cmp));
    let cmpty = cmp_result_ty(vecty);
    let vc = tv_cmpsel(te_opcode(cmp), vecty, cmpty, mp, TCK_RECIP_THROUGHPUT, slp_operand_info(te_operand(cmp, 0)),
                       slp_operand_info(te_operand(cmp, 1)));
    var bv = slp_scalarization_overhead_all(vals[c].ty, cmpty, te_vector_factor(cmp), true, false);
    for v in te_scalars(cmp) { if is_inst(v) { bv = tc_add(bv, tv_inst_cost(v, TCK_RECIP_THROUGHPUT)); } }
    let r = vc < bv;
    if !r { inv.clear(); }
    return r;
}
// matchesSelectOfBits(SelectTE)
fn slp_matches_select_of_bits(e: i32) -> bool {
    if dl_big_endian { return false; }
    if slp_te[e].nreord > 0 || slp_te[e].nreuse > 0 { return false; }
    if !slp_uil_on || e != 0 { return false; }
    for v in te_scalars(e) { if !slp_has_one_use(v) { return false; } }
    for v in slp_uil_vals { if !is_inst_op(v, OP_OR) { return false; } }
    let o1 = slp_operand_entry(e, 1);
    let o2 = slp_operand_entry(e, 2);
    if !te_is_gather(o1) || !te_is_gather(o2) { return false; }
    if slp_te[o1].nreord > 0 || slp_te[o1].nreuse > 0 || slp_te[o2].nreuse > 0 { return false; }
    let sty: i32 = vals[te_scalar(o1, 0)].ty;
    if !ty_is_int(sty) { return false; }
    for v in te_scalars(o2) { if !slp_is_zero_int(v) { return false; } }
    let sc1 = te_scalars(o1);
    for i in sc1.len {
        let v = sc1[i];
        if vals[v].kind != VK_CINT || !ap_fits_u64(ci_ap(v)) { return false; }
        let x = ci_ap(v).lo;
        if x == 0 || (x & (x - 1)) != 0 { return false; }
        var lg: i64 = 0;
        var y = x;
        while y > 1 { y = y >> 1; lg++; }
        if lg != i { return false; }
    }
    let vf = te_vector_factor(e);
    let dst = ty_int(vf);
    let opty = slp_widened_type(dst, vf);
    let cmpty = cmp_result_ty(opty);
    let vecty = slp_widened_type(sty, vf);
    var bc = tv_cast(OP_BITCAST, dst, cmpty, 0, TCK_RECIP_THROUGHPUT, -1);
    if dst != sty { bc = tc_add(bc, tv_cast(OP_ZEXT, sty, dst, 0, TCK_RECIP_THROUGHPUT, -1)); }
    let selc = tc_add(tv_cmpsel(OP_SELECT, vecty, cmpty, PRED_BAD_ICMP, TCK_RECIP_THROUGHPUT, slp_operand_info(te_scalars(o1)),
                                slp_operand_info(te_scalars(o2))),
                      tv_arith_reduction(OP_OR, vecty, false, TCK_RECIP_THROUGHPUT));
    return bc <= selc;
}

// transformNodes()
fn slp_transform_nodes() {
    slp_base_graph_size = slp_te.len;
    slp_graph_transform_mode = true;
    let base = slp_base_graph_size;
    fn check_operands_profitability(i1: i32, i2: i32, s: SIS) -> bool {
        for k in nops(s.main) {
            let a = op(i1, k);
            let b = op(i2, k);
            if is_constant(a) || is_constant(b) || a == b { continue; }
            var ca: i32[1] = [a];
            var cb: i32[1] = [b];
            let idx, best = slp_find_best_root_pair(ca[..], cb[..], LA_SPLAT_LOADS);
            if idx < 0 { return false; }
        }
        return true;
    }
    for idx in base { if te_is_gather(idx as i32) { slp_reorder_gather_node(idx as i32); } }
    var nlg: i64 = 0;
    for t in slp_te.len { let x = t as i32; if te_is_gather(x) && te_has_state(x) && te_opcode(x) == OP_LOAD && te_vector_factor(x) < 16 { nlg++; } }
    let force_load_gather = nlg == 2;
    fn are_reused_scalars(t: i32, vl: const i32[:], split: bool, tes: const i32[:]) -> bool {
        if te_is_same(t, vl) { return true; }
        for v in vl {
            if is_poison(v) { continue; }
            if !is_inst(v) { return false; }
            if slp_contains(te_scalars(t), v) { continue; }
            var c = if split { slp_lk_head(SH_SPLIT, v as i64) } else { slp_tree_entries_head(v) };
            var hit = false;
            while c >= 0 { if slp_contains(tes, slp_lk[c].x) { hit = true; break; } c = slp_lk[c].next; }
            if !hit { return false; }
        }
        return true;
    }
    fn check_for_same_vector_nodes(e: i32) -> bool {
        fn check(v: i32, split: bool) -> bool {
            var tes: i32[>..<] = [];
            var c = if split { slp_lk_head(SH_SPLIT, v as i64) } else { slp_tree_entries_head(v) };
            while c >= 0 { tes.push(slp_lk[c].x); c = slp_lk[c].next; }
            for t in tes { if are_reused_scalars(t, te_scalars(e), split, tes) { return true; } }
            return false;
        }
        if te_has_state(e) {
            if check(te_main(e), false) { return true; }
            if check(te_main(e), true) { return true; }
        } else {
            for v in te_scalars(e) { if is_inst(v) { return check(v, true); } }
        }
        return false;
    }
    for idx0 in base {
        let e = idx0 as i32;
        if te_is_gather(e) {
            let vl = te_scalars(e);
            let vat = slp_te[e].sc;
            let vn = te_nscalars(e);
            let sz = slp_vector_element_size(vl[0]);
            let minvf = slp_min_vf(2 * sz);
            var in_load_entries = false;
            for x in slp_load_entries { if x as i64 == idx0 { in_load_entries = true; } }
            var skip = vl.len <= 2 || in_load_entries ||
                       !(!te_has_state(e) || te_opcode(e) == OP_LOAD || !slp_all_same_opcode(vl) || !slp_all_same_block(vl)) ||
                       slp_all_constant(vl) || slp_is_splat(vl);
            if !skip && force_load_gather && te_has_state(e) && te_opcode(e) == OP_LOAD { skip = true; }
            if !skip && check_for_same_vector_nodes(e) { skip = true; }
            if !skip {
                var start: i64 = 0;
                var end = vn;
                var processed: bool[>..<] = [];
                for k in vn { processed.push(false); }
                let fty: i32 = vals[slp_vp[vat as i64]].ty;
                var vf = slp_floor_full_vector_number_of_elements(fty, vn - 1);
                while vf >= minvf {
                    let next_vf = slp_floor_full_vector_number_of_elements(fty, vf - 1);
                    if start + vf > end { if next_vf >= vf { break; } vf = next_vf; continue; }
                    var sl_at: i64[>..<] = [];
                    var sl_n: i64[>..<] = [];
                    var all_strided = true;
                    var cnt = start;
                    while cnt < end {
                        let svf = if vf < end - cnt { vf } else { end - cnt };
                        let this_cnt = cnt;
                        cnt += vf;
                        if svf <= 1 { continue; }
                        let sl = slp_vp[(vat as i64 + this_cnt)..(vat as i64 + this_cnt + svf)];
                        if (processed[this_cnt] || slp_is_vectorized(sl[0])) && slp_same_values_tree_entry(sl[0], sl, true) < 0 { continue; }
                        if slp_all_constant(sl) { continue; }
                        let is_splat = slp_is_splat(sl);
                        var two_reg = true;
                        if is_splat && vf == 2 {
                            let vt0 = slp_value_type(sl[0], false);
                            two_reg = slp_number_of_parts(slp_widened_type(vt0, 2 * vf), vt0, 0x7FFFFFFF) == 2;
                        }
                        var c0: i64 = 0;
                        for v in sl { if v == sl[0] { c0++; } }
                        if sl_at.len == 0 || !is_splat || !two_reg || c0 == (if is_undef_or_poison(sl[0]) { svf - 1 } else { 1 }) {
                            if is_splat { continue; }
                            let s = slp_get_same_opcode(sl);
                            if !sis_valid(s) || !slp_all_same_opcode(sl) || !slp_all_same_block(sl) ||
                               (sis_opcode(s) == OP_LOAD && slp_known_nonvect_loads(sl)) { continue; }
                            if vf == 2 {
                                var cheap_known = false;
                                var cheap = false;
                                fn main_cheap() -> bool {
                                    if !cheap_known { cheap = tv_inst_cost(s.main, TCK_RECIP_THROUGHPUT) < TCC_EXPENSIVE; cheap_known = true; }
                                    return cheap;
                                }
                                if (!slp_uil_on || e != 0) && main_cheap() {
                                    var all = true;
                                    for v in sl { if is_poison(v) { continue; } if !slp_are_all_users_vectorized(v, slp_uil_on) { all = false; break; } }
                                    if !all { continue; }
                                }
                                if sis_opcode(s) == OP_LOAD {
                                    var order: i32[>..<] = [];
                                    var ptrs: i32[>..<] = [];
                                    let r = slp_can_vectorize_loads(sl, sl[0], order, ptrs, false, true);
                                    all_strided = all_strided && (r == LS_STRIDED || r == LS_SCATTER || r == LS_GATHER);
                                    if r == LS_SCATTER || r == LS_GATHER {
                                        if r == LS_GATHER {
                                            slp_register_nonvect_loads(sl);
                                            if slp_uil_on && e == 0 { slp_analyzed_reduction_vals(sl); }
                                        }
                                        continue;
                                    }
                                } else if sis_opcode(s) == OP_EXTRACTELEMENT {
                                    continue;
                                } else if main_cheap() {
                                    var last: i32 = -1;
                                    var j = sl.len;
                                    while j > 0 { j--; if is_inst(sl[j]) { last = sl[j]; break; } }
                                    if !check_operands_profitability(s.main, last, s) { continue; }
                                }
                            }
                        }
                        sl_at.push(this_cnt);
                        sl_n.push(svf);
                    }
                    if !(vf == 2 && all_strided && sl_at.len > 2) {
                        for k in sl_at.len {
                            let c = sl_at[k];
                            let szs = sl_n[k];
                            let sl = slp_vp[(vat as i64 + c)..(vat as i64 + c + szs)];
                            var same_te: i32 = -1;
                            for v in sl { if is_inst(v) { same_te = slp_same_values_tree_entry(v, sl, false); break; } }
                            let prev = slp_te.len;
                            slp_build_tree_rec(vat + c as i32, szs, 0, e, -1, 0);
                            if prev + 1 == slp_te.len && same_te < 0 && te_is_gather(prev as i32) && te_has_state(prev as i32) &&
                               te_opcode(prev as i32) != OP_EXTRACTELEMENT && !slp_is_splat(sl) {
                                if slp_uil_on && e == 0 && vf == 2 { slp_analyzed_reduction_vals(sl); }
                                slp_pop_tree_entry();
                                continue;
                            }
                            te_comb_push(e, prev as i32, c as i32);
                            for j in c..(c + szs) { processed[j] = true; }
                            if start == c { start = c + szs; }
                            if end == c + szs { end = c; }
                        }
                    }
                    if next_vf >= vf { break; }
                    vf = next_vf;
                }
                if te_comb_n(e) == 0 && slp_te[e].nreord > 0 {
                    var mask: i32[>..<] = [];
                    slp_copy_list(te_reorder(e), mask);
                    te_reorder_scalars(e, mask);
                    te_clear_reorder(e);
                }
            }
        }
        if !te_has_state(e) { continue; }
        let o = te_opcode(e);
        if o == OP_LOAD || o == OP_STORE {
            // isLegalStridedLoadStore is false on X86 and without a target: no strided transformation
            if o == OP_STORE && slp_te[e].state != TE_EXPAND && slp_te[e].nreord > 0 && !slp_is_reverse_order(te_reorder(e)) {
                // the interleaved-store check: isLegalInterleavedAccessType is false on X86 and without a target
            }
        } else if o == OP_SELECT {
            if slp_te[e].state != TE_VECTORIZE { continue; }
            let mmid, sel_only = slp_can_convert_to_min_or_max(te_scalars(e));
            if mmid != 0 {
                slp_te[e].cop = CO_MINMAX;
                let ce = slp_operand_entry(e, 0);
                if sel_only && slp_te[ce].ui_te >= 0 && slp_te[ce].state == TE_VECTORIZE { slp_te[ce].state = TE_COMBINED; }
                continue;
            }
            var inv: i64[>..<] = [];
            if slp_matches_inversed_zext_select(e, inv) {
                let ct = slp_operand_entry(e, 0);
                let o1 = slp_operand_entry(e, 1);
                let o2 = slp_operand_entry(e, 2);
                te_set_operations(ct, SIS { main: te_main(ct), alt: te_main(ct), copy: false });
                fn update_gather_entry(old: i32, new: i32, v: i32) {
                    if slp_is_constant(v) { return; }
                    if !slp_contains(te_scalars(old), v) { cd_lk_remove(SH_V2G, v as i64, 0, old); }
                    if !slp_lk_contains(SH_V2G, v as i64, new) { slp_lk_push_tail(SH_V2G, v as i64, new); }
                }
                var s1: i32[>..<] = [];
                var s2: i32[>..<] = [];
                slp_copy_list(te_scalars(o1), s1);
                slp_copy_list(te_scalars(o2), s2);
                var op1: i32[>..<] = [];
                var op2: i32[>..<] = [];
                slp_copy_list(te_operand(e, 1), op1);
                slp_copy_list(te_operand(e, 2), op2);
                for i in inv {
                    let v1 = s1[i];
                    let v2 = s2[i];
                    s1[i] = v2; s2[i] = v1;
                    let t = op1[i]; op1[i] = op2[i]; op2[i] = t;
                    te_set_scalars_list(o1, s1);
                    te_set_scalars_list(o2, s2);
                    update_gather_entry(o1, o2, v1);
                    update_gather_entry(o2, o1, v2);
                }
                te_replace_operand(e, 1, op1);
                te_replace_operand(e, 2, op2);
                sh_set(SH_OP2TE, e as i64, 1, o1 as i64);
                sh_set(SH_OP2TE, e as i64, 2, o2 as i64);
            }
            if slp_matches_select_of_bits(e) {
                slp_te[e].cop = CO_RCMP_BITCAST;
                let o1 = slp_operand_entry(e, 1);
                let o2 = slp_operand_entry(e, 2);
                slp_te[o1].state = TE_COMBINED; slp_te[o1].cop = CO_RCMP_BITCAST;
                slp_te[o2].state = TE_COMBINED; slp_te[o2].cop = CO_RCMP_BITCAST;
            }
        } else if o == OP_FSUB || o == OP_FADD {
            if slp_te[e].state != TE_VECTORIZE || !sis_is_addsub_like_op(te_s(e)) || te_is_alt_shuffle(e) { continue; }
            let lhs = slp_operand_entry(e, 0);
            let rhs = slp_operand_entry(e, 1);
            fn one_use_fmul(t: i32) -> bool {
                if !(slp_te[t].state == TE_VECTORIZE && slp_te[t].nreord == 0 && slp_te[t].nreuse == 0 && te_opcode(t) == OP_FMUL &&
                     !te_is_alt_shuffle(t)) { return false; }
                for v in te_scalars(t) { if !((te_has_copyable_elements(t) && te_is_copyable_element(t, v)) || slp_has_one_use(v)) { return false; } }
                return true;
            }
            if !one_use_fmul(lhs) && (o == OP_FSUB || !one_use_fmul(rhs)) { continue; }
            if !tc_valid(slp_can_convert_to_fma(te_scalars(e), te_s(e))) { continue; }
            slp_te[e].cop = CO_FMULADD;
            let fe = slp_operand_entry(e, 0);
            if slp_te[fe].ui_te >= 0 && slp_te[fe].state == TE_VECTORIZE { slp_te[fe].state = TE_COMBINED; }
        } else if o == OP_SHL {
            if e != 0 || dl_big_endian || !slp_uil_on { continue; }
            var all_disjoint = true;
            for v in slp_uil_vals { if !(is_inst_op(v, OP_OR) && op_disjoint(v)) { all_disjoint = false; break; } }
            if !all_disjoint { continue; }
            slp_fail("matchesShlZExt (reduced disjoint-or bitcast nodes)");
        }
    }
    if slp_load_entries.len == 0 {
        if slp_te.len <= 1 && te_has_state(0) && te_opcode(0) == OP_LOAD { slp_graph_transform_mode = false; return; }
        if (slp_te.len <= 3 && te_nscalars(0) == 2) || (slp_te.len <= 2 && slp_uil_on) { slp_graph_transform_mode = false; return; }
        if te_is_non_pow2_vec(0) && slp_base_graph_size != slp_te.len && slp_uil_on && slp_base_graph_size <= 3 {
            var c: i64 = 0;
            for t in slp_base_graph_size..slp_te.len {
                let x = t as i32;
                if te_is_gather(x) && te_has_state(x) && te_opcode(x) == OP_LOAD && !slp_all_same_block(te_scalars(x)) { c++; }
            }
            if c == 1 { slp_graph_transform_mode = false; return; }
        }
    }
    var any_gathered = false;
    for t in slp_te.len {
        let x = t as i32;
        if !te_is_gather(x) || slp_is_splat(te_scalars(x)) { continue; }
        var cand = te_has_state(x) && te_opcode(x) == OP_LOAD;
        if !cand && !te_has_state(x) {
            for v in te_scalars(x) { if is_inst_op(v, OP_LOAD) && !slp_is_vectorized(v) && !slp_is_deleted(v) { cand = true; break; } }
        }
        if !cand { continue; }
        for v in te_scalars(x) {
            if !is_inst_op(v, OP_LOAD) { continue; }
            if slp_is_deleted(v) || slp_is_vectorized(v) || !ld_is_simple(v) { continue; }
            any_gathered = true;
        }
    }
    if any_gathered { slp_fail("tryToVectorizeGatheredLoads (gatherPossiblyVectorizableLoads)"); }
    slp_graph_transform_mode = false;
}
// CmpPredicate::getMatching(A, B) has a value
fn slp_cmp_pred_matching(ap: i64, asame: bool, bp: i64, bsame: bool) -> bool {
    if ap == bp { return true; }
    if ap < 32 || bp < 32 { return false; }
    fn rel(p: i64) -> bool { p >= P_UGT && p <= P_SLE }
    fn flip(p: i64) -> i64 { if p >= 38 { p - 4 } else { p + 4 } }
    if asame && rel(bp) && ap == flip(bp) { return true; }
    if bsame && rel(ap) && bp == flip(ap) { return true; }
    return false;
}
// VectorizableTree.pop_back() of a gather entry built by transformNodes
fn slp_pop_tree_entry() {
    let te = (slp_te.len - 1) as i32;
    for v in te_scalars(te) { sh_del(SH_COPYABLE, te as i64, v as i64); sh_del(SH_LANE, te as i64, v as i64); }
    sh_del(SH_E2LI, te as i64, 0);
    slp_te.pop();
}
