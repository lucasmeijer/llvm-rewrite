// SLPVectorizer: BoUpSLP::getEntryCost and its helpers. Port of llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp:
// getEntryCost (17029-18290), getCastContextHint, getVectorSpillReloadCost, getInsertBuildVectorSrcTy,
// canVectorStoreInsertValue, TreeEntry::hasEqualOperands / getSplitMask, dumpTreeCosts.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import pm;
import flags;
import vt;
import apint;
import datalayout;
import laa;
import tti;
import tti_x86;
import tti_x86_intr;
import tti_vec;
import tti_x86_vec;
import gen_x86target;
import slp_util;
import slp_tree;
import slp_loads;
import slp_build;
import slp_gather;
import slp_reorder;
import slp_transform;
import slp_minbw;
import slp_bvcost;

fn slp_errs_cost(c: i64) { if tc_valid(c) { errs_int(c); } else { errs("Invalid"); } }
// dumpTreeCosts(E, ReuseShuffleCost, VecCost, ScalarCost, Banner)
fn slp_dump_tree_costs(e: i32, reuse: i64, vec: i64, scal: i64, banner: const u8[:]) {
    if !slp_dbg_on { return; }
    errs("SLP: "); errs(banner); errs(":\n");
    slp_dump_te(e);
    errs("SLP: Costs:\n");
    errs("SLP:     ReuseShuffleCost = "); slp_errs_cost(reuse); errs("\n");
    errs("SLP:     VectorCost = "); slp_errs_cost(vec); errs("\n");
    errs("SLP:     ScalarCost = "); slp_errs_cost(scal); errs("\n");
    errs("SLP:     ReuseShuffleCost + VecCost - ScalarCost = "); slp_errs_cost(tc_sub(tc_add(reuse, vec), scal)); errs("\n");
    slp_dbg_flush();
}

// getCastContextHint(TE)
fn slp_te_cast_context_hint(t: i32) -> i64 {
    let st = slp_te[t].state;
    if st == TE_SCATTER || st == TE_STRIDED { return 3; }
    if st == TE_COMPRESS { return 2; }
    if st == TE_VECTORIZE && te_opcode(t) == OP_LOAD && !te_is_alt_shuffle(t) {
        if slp_te[t].nreord == 0 { return 1; }
        var m: i32[>..<] = [];
        slp_inverse_permutation(te_reorder(t), m);
        if slp_is_reverse_mask(m, m.len) { return 5; }
    }
    return 0;
}
fn slp_is_reverse_mask(m: const i32[:], nsrc: i64) -> bool {
    if m.len != nsrc || !slp_single_source_mask(m, nsrc) || nsrc < 2 { return false; }
    for i in m.len { if m[i] != -1 && m[i] as i64 != nsrc - 1 - i && m[i] as i64 != 2 * nsrc - 1 - i { return false; } }
    return true;
}
// the scalar type of an entry after MinBWs: (ScalarTy, VecTy)
fn slp_entry_vec_ty(t: i32) -> i32, i32 {
    var sty = slp_value_type(te_scalar(t, 0), false);
    if slp_te[t].mbw > 0 {
        let vt = ty_kind(sty) == TK_FVEC;
        let n = if vt { ty_count(sty) } else { 0 };
        sty = ty_int(slp_te[t].mbw as i64);
        if vt { sty = slp_widened_type(sty, n); }
    }
    return sty, slp_widened_type(sty, te_vector_factor(t));
}
// getVectorSpillReloadCost(E, ScalarTy, VecTy, FinalVecTy)
fn slp_vector_spill_reload_cost(e: i32, sty: i32, vecty: i32, final_vecty: i32) -> i64 {
    var sr: i64 = 0;
    if !te_has_state(e) { return sr; }
    let o = te_opcode(e);
    if o == OP_STORE || o == OP_EXTRACTELEMENT || o == OP_EXTRACTVALUE || o == OP_FREEZE || (o == OP_LOAD && slp_te[e].state != TE_SCATTER) { return sr; }
    let is_phi = slp_te[e].state == TE_VECTORIZE && o == OP_PHI;
    var counted: i32[>..<] = [];
    var rc_k: i64[>..<] = [];
    var rc_n: i64[>..<] = [];
    fn add_parts(rc: i64, parts: i64) {
        for k in rc_k.len { if rc_k[k] == rc { rc_n[k] += parts; return; } }
        rc_k.push(rc); rc_n.push(parts);
    }
    if slp_te[e].state == TE_SPLIT {
        for k in te_comb_n(e) {
            let ot = te_comb_idx(e, k);
            if slp_contains(counted, ot) { continue; }
            counted.push(ot);
            let s2, ovt = slp_entry_vec_ty(ot);
            let parts = slp_number_of_parts(ovt, s2, 0x7FFFFFFF);
            if parts == 0 { continue; }
            add_parts(tv_register_class_for_type(true, ovt), parts);
        }
    } else if is_phi {
        var mk: i64[>..<] = [];
        var mn: i64[>..<] = [];
        for idx in te_num_operands(e) {
            let ot = slp_operand_entry(e, idx);
            let s2, ovt = slp_entry_vec_ty(ot);
            let parts = slp_number_of_parts(ovt, s2, 0x7FFFFFFF);
            if parts == 0 { continue; }
            let rc = tv_register_class_for_type(true, ovt);
            var found = false;
            for k in mk.len { if mk[k] == rc { if parts > mn[k] { mn[k] = parts; } found = true; } }
            if !found { mk.push(rc); mn.push(parts); }
        }
        for k in mk.len { add_parts(mk[k], mn[k]); }
    } else {
        for idx in te_num_operands(e) {
            if (o == OP_INSERTELEMENT || o == OP_INSERTVALUE) && idx == 0 { continue; }
            let ops = te_operand(e, idx);
            if ops.len == 0 || slp_all_constant(ops) || slp_is_splat(ops) { continue; }
            let o0 = ops[0];
            let ot = slp_operand_entry(e, idx);
            if slp_contains(counted, ot) { continue; }
            counted.push(ot);
            let ovt = slp_widened_type(vals[o0].ty, ops.len);
            let parts = slp_number_of_parts(ovt, vals[o0].ty, 0x7FFFFFFF);
            if parts == 0 { continue; }
            add_parts(tv_register_class_for_type(true, ovt), parts);
        }
    }
    if o != OP_LOAD {
        let rp = slp_number_of_parts(vecty, sty, 0x7FFFFFFF);
        if rp != 0 { add_parts(tv_register_class_for_type(true, vecty), rp); }
        if vecty != final_vecty {
            let fp = slp_number_of_parts(final_vecty, sty, 0x7FFFFFFF);
            if fp != 0 { add_parts(tv_register_class_for_type(true, final_vecty), fp); }
        }
    }
    for k in rc_k.len {
        let avail = tv_number_of_registers(rc_k[k]);
        if avail == 0 || rc_n[k] <= avail { continue; }
        slp_fail("getVectorSpillReloadCost with more registers than available (getRegisterClassSpillCost / ReloadCost)");
    }
    return sr;
}
// getInsertBuildVectorSrcTy(E)
fn slp_insert_build_vector_src_ty(e: i32) -> i32 {
    let v0 = te_main(e);
    if te_opcode(e) == OP_INSERTELEMENT { return vals[v0].ty; }
    var mx = te_nscalars(e) - 1;
    for v in te_scalars(e) {
        if !is_inst_op(v, OP_INSERTVALUE) { continue; }
        let x = insts[inst_of(v)];
        let i0 = ints[x.aux] as i64;
        if i0 > mx { mx = i0; }
    }
    return slp_widened_type(slp_value_type(v0, false), mx + 1);
}
// canVectorStoreInsertValue(E)
fn slp_can_vector_store_insert_value(e: i32) -> bool {
    if te_opcode(e) != OP_INSERTVALUE || slp_te[e].state != TE_VECTORIZE { return false; }
    var has_store = false;
    for v in te_scalars(e) {
        if !is_inst_op(v, OP_INSERTVALUE) || slp_is_deleted(v) { return false; }
        var ext = false;
        var u = vals[v].first_use;
        while u >= 0 {
            let usr = uses[u].user;
            u = uses[u].next;
            if is_inst(usr) && slp_is_deleted(usr) { continue; }
            if slp_contains(te_scalars(e), usr) { continue; }
            ext = true;
            if !is_inst_op(usr, OP_STORE) || !ld_is_simple(usr) { return false; }
            has_store = true;
        }
        if ext && !slp_has_one_use(v) { return false; }
    }
    return has_store;
}
// TreeEntry::hasEqualOperands(TE)
fn te_has_equal_operands(a: i32, b: i32) -> bool {
    let n = te_num_operands(a);
    if te_num_operands(b) != n { return false; }
    var used: bool[>..<] = [];
    for k in n { used.push(false); }
    for i in n {
        var found = false;
        for k in n {
            if used[k] { continue; }
            if slp_lists_equal(te_operand(a, k), te_operand(b, i)) { used[k] = true; found = true; break; }
        }
        if !found { return false; }
    }
    return true;
}
// TreeEntry::getSplitMask()
fn te_split_mask(e: i32, out: i32[>..<]&) {
    let back = te_comb_off(e, te_comb_n(e) - 1) as i64;
    let n = te_nscalars(e);
    var cvf = if back > n - back { back } else { n - back };
    out.clear();
    for k in te_vector_factor(e) { out.push(-1); }
    let ro = te_reorder(e);
    for idx in ro.len {
        let i = ro[idx] as i64;
        out[i] = (idx + (if idx >= back { cvf - back } else { 0 })) as i32;
    }
}
// isReducedBitcastRoot()
fn slp_is_reduced_bitcast_root() -> bool {
    if !te_has_state(0) { return false; }
    let c = slp_te[0].cop;
    return (c == CO_RBITCAST || c == CO_RBITCAST_BSWAP || c == CO_RBITCAST_LOADS || c == CO_RBITCAST_BSWAP_LOADS) && slp_te[0].state == TE_VECTORIZE;
}
// TTI::getOperandInfo(V)
fn slp_tti_oi(v: i32) -> i64 { tti_operand_info(v) }
// getArithmeticInstrCost(Opcode, Ty, CostKind, Op1Info, Op2Info, Args)
fn slp_arith_args(o: i64, ty: i32, oi1: i64, oi2: i64, a0: i32, a1: i32, nargs: i64) -> i64 {
    if tti_kind != TTI_X86 { return base_arith_cost(o, ty, TCK_RECIP_THROUGHPUT, -1, -1); }
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_arith_cost(o, ty, TCK_RECIP_THROUGHPUT, oi1, oi2, a0, a1, nargs, -1);
    mk_release(m);
    ica_release(im);
    return c;
}
fn slp_cmpsel_i(o: i64, valty: i32, condty: i32, pred: i64, oi1: i64, oi2: i64, i: i32) -> i64 {
    if tti_kind != TTI_X86 { return 1; }
    let p = if pred < 0 { PRED_BAD_ICMP } else { pred };
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_cmpsel_cost(o, valty, condty, p, TCK_RECIP_THROUGHPUT, oi1, oi2, i);
    mk_release(m);
    ica_release(im);
    return c;
}
fn slp_mem_i(o: i64, ty: i32, align: i64, as_: i64, oi: i64, i: i32) -> i64 {
    if tti_kind != TTI_X86 { return 1; }
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_memory_op_cost(o, ty, align, as_, TCK_RECIP_THROUGHPUT, oi, i);
    mk_release(m);
    ica_release(im);
    return c;
}
// IntrinsicCostAttributes(ID, *CI, ScalarizationCost = 1)
fn slp_intrinsic_call_cost_id(id: i32, ci: i32) -> i64 {
    if tti_kind != TTI_X86 { return base_intrinsic_cost(id, vals[ci].ty); }
    let m = mk_mark();
    let im = ica_mark();
    let ic = ica_new(id as i64, vals[ci].ty, inst_fmf(ci), ci, 1);
    for k in cb_nargs(ci) { ica_add_arg(ic, cb_arg(ci, k)); }
    let ft: i32 = insts[inst_of(ci)].ty2;
    for k in ty_fn_nparams(ft) { ica_add_type(ic, ty_fn_param(ft, k)); }
    let r = x86_intrinsic_cost(ic, TCK_RECIP_THROUGHPUT);
    mk_release(m);
    ica_release(im);
    return r;
}

// getEntryCost(E, VectorizedVals, CheckedExtracts)
fn slp_entry_cost(e: i32, vvals: const i32[:]) -> i64 {
    let vl = te_scalars(e);
    var sty = slp_value_type(vl[0], false);
    if !slp_is_valid_element_type(sty) { return TTI_INVALID; }
    let has_mbw = slp_te[e].mbw > 0;
    var osty = sty;
    if has_mbw {
        let vt = ty_kind(sty) == TK_FVEC;
        let n = if vt { ty_count(sty) } else { 0 };
        sty = ty_int(slp_te[e].mbw as i64);
        if vt { sty = slp_widened_type(sty, n); }
    } else if e == 0 && slp_is_reduced_bitcast_root() {
        let z = slp_operand_entry(e, 0);
        sty = vals[op(te_main(z), 0)].ty;
    }
    var vecty = slp_widened_type(sty, vl.len);
    let entry_vf = te_vector_factor(e);
    let final_vecty = slp_widened_type(sty, entry_vf);
    let sr = slp_vector_spill_reload_cost(e, sty, vecty, final_vecty);
    if te_is_gather(e) || slp_is_transformed_to_gather(e) {
        if slp_all_constant(vl) { return 0; }
        if is_inst_op(vl[0], OP_INSERTELEMENT) || is_inst_op(vl[0], OP_INSERTVALUE) { return TTI_INVALID; }
        return tc_add(sr, slp_pbv_cost(e, sty, vvals));
    }
    if slp_te[e].state == TE_SPLIT {
        var vc: i64 = 0;
        let last = te_comb_n(e) - 1;
        if slp_te[e].nreord == 0 {
            vc = slp_shuffle_cost(SK_INSERTSUBVECTOR, final_vecty, slp_no_mask(), te_comb_off(e, last) as i64,
                                  slp_widened_type(sty, te_vector_factor(te_comb_idx(e, last))));
        } else {
            let a = te_vector_factor(te_comb_idx(e, 0));
            let b = te_vector_factor(te_comb_idx(e, last));
            var sm: i32[>..<] = [];
            te_split_mask(e, sm);
            vc = slp_shuffle_cost(SK_PERMUTETWOSRC, slp_widened_type(sty, if a > b { a } else { b }), sm, 0, -1);
        }
        vc = tc_add(vc, sr);
        slp_dump_tree_costs(e, 0, vc, 0, "Calculated costs for Tree");
        return vc;
    }
    var common: i64 = 0;
    var mask: i32[>..<] = [];
    let st = slp_te[e].state;
    if slp_te[e].nreord > 0 && st != TE_COMPRESS && (st != TE_STRIDED || !slp_is_reverse_order(te_reorder(e))) {
        var nm: i32[>..<] = [];
        if te_opcode(e) == OP_STORE { slp_copy_list(te_reorder(e), nm); } else { slp_inverse_permutation(te_reorder(e), nm); }
        slp_add_mask(mask, nm, false);
    }
    if slp_te[e].nreuse > 0 { slp_add_mask(mask, te_reuse(e), false); }
    if mask.len > 0 && !slp_is_identity_mask(mask, mask.len) {
        common = slp_shuffle_cost(SK_PERMUTESINGLESRC, final_vecty, mask, 0, vecty);
    }
    let vl0 = te_main(e);
    var sop = if te_is_alt_shuffle(e) { OP_SHUFFLEVECTOR } else { te_opcode(e) };
    if slp_te[e].cop != CO_NONE { sop = slp_te[e].cop as i64; }
    var uniq: i32[>..<] = [];
    var uniq_idx: i64[>..<] = [];
    for k in vl.len { if !slp_contains(uniq, vl[k]) { uniq.push(vl[k]); uniq_idx.push(k); } }
    let sz = uniq.len;
    var used: bool[>..<] = [];
    var nused: i64 = 0;
    for i in sz {
        let v = uniq[i];
        if is_inst(v) && !te_is_copyable_element(e, v) && slp_tree_entries_head(v) >= 0 && slp_lk[slp_tree_entries_head(v)].x == e {
            used.push(false);
            continue;
        }
        used.push(true);
        nused++;
    }
    fn cast_context_hint(v: i32) -> i64 {
        if slp_lk_count(SH_S2TE, v as i64) == 1 { return slp_te_cast_context_hint(slp_lk[slp_tree_entries_head(v)].x); }
        let ss = slp_get_same_opcode(te_operand(e, 0));
        if sis_valid(ss) && sis_opcode(ss) == OP_LOAD && !sis_is_alt_shuffle(ss) { return 3; }
        return 0;
    }
    // GetCostDiff(ScalarEltCost, VectorCost): the scalar costs are given, per unique value (-1: skipped)
    fn cost_diff(scalar: i64, vec0: i64) -> i64 {
        var vec = vec0;
        if has_mbw && !is_cast_op(te_opcode(e)) && e != 0 && (te_opcode(e) != OP_LOAD || slp_te[e].ui_te >= 0) {
            let ut = slp_te[e].ui_te;
            let edge = slp_te[e].ui_edge;
            if !te_has_state(ut) || te_opcode(ut) != OP_SELECT || edge != 0 {
                var usty: i32 = if te_is_gather(ut) || slp_te[ut].state == TE_SPLIT { vals[te_scalar(ut, 0)].ty } else { vals[te_operand(ut, edge)[0]].ty };
                if slp_te[ut].mbw > 0 { usty = ty_int(slp_te[ut].mbw as i64); }
                if sty != usty {
                    let bwsz = slp_dl_bits(sty);
                    let srcsz = slp_dl_bits(usty);
                    let uvt = slp_widened_type(usty, te_nscalars(e));
                    let vo = if bwsz > srcsz { OP_TRUNC } else if slp_te[e].mbw_s { OP_SEXT } else { OP_ZEXT };
                    vec = tc_add(vec, tv_cast(vo, uvt, vecty, cast_context_hint(vl0), TCK_RECIP_THROUGHPUT, -1));
                }
            }
        }
        vec = tc_add(vec, sr);
        slp_dump_tree_costs(e, common, tc_sub(vec, common), scalar, "Calculated costs for Tree");
        return tc_sub(vec, scalar);
    }
    fn gep_cost_diff(ptrs: const i32[:], base: i32) -> i64 {
        let sc, vc = slp_gep_costs(ptrs, base, te_opcode(e), osty, vecty);
        slp_dump_tree_costs(e, 0, vc, sc, "Calculated GEPs cost for Tree");
        return tc_add(tc_sub(vc, sc), sr);
    }
    fn minmax_cost(ty: i32, vi: i32) -> i64 {
        var id: i32 = 0;
        var sel_only = false;
        if vi >= 0 { var one: i32[1] = [vi]; let a, b = slp_can_convert_to_min_or_max(one[..]); id = a; sel_only = b; }
        else { let a, b = slp_can_convert_to_min_or_max(vl); id = a; sel_only = b; }
        if id == 0 { return TTI_INVALID; }
        var ct = ty;
        if ty_kind(ty_scalar(ty)) == TK_PTR {
            let it = ty_int(dl_size_bits(ty_scalar(ty)));
            ct = if ty_kind(ty) == TK_FVEC { slp_widened_type(it, ty_count(ty)) } else { it };
        }
        var tys: i32[2] = [ct, ct];
        var ic = tv_intrinsic_types(id, ct, tys[..], 0, TCK_RECIP_THROUGHPUT);
        if vi >= 0 && sel_only {
            let ci = op(vi, 0);
            ic = tc_sub(ic, slp_cmpsel_i(iop(ci), ty, T_I1, inst_pred(ci), 0, 0, ci));
        }
        return ic;
    }
    fn sum_scalar(per: const i64[:]) -> i64 {
        var s: i64 = 0;
        for i in sz { if used[i] { continue; } s = tc_add(s, per[i]); }
        return s;
    }
    var per: i64[>..<] = [];
    for i in sz { per.push(0); }
    let castcall = is_cast_op(iop(vl0)) || iop(vl0) == OP_CALL;
    fn scalar_total() -> i64 {
        if castcall { return tc_mul(per[0], sz - nused); }
        return sum_scalar(per);
    }
    if sop == OP_PHI {
        var sc: i64 = 0;
        var counted: i32[>..<] = [];
        for v in uniq {
            if !is_inst_op(v, OP_PHI) { continue; }
            var opsl: i32[>..<] = [];
            for k in phi_nincoming(v) { opsl.push(op(v, k)); }
            let ot = slp_same_values_tree_entry(opsl[0], opsl, false);
            if ot >= 0 && !slp_contains(counted, ot) {
                counted.push(ot);
                if slp_te[ot].nreuse > 0 { sc = tc_add(sc, TCC_BASIC * (slp_te[ot].nreuse as i64 - te_nscalars(ot))); }
            }
        }
        return tc_add(tc_sub(common, sc), sr);
    }
    if sop == OP_EXTRACTVALUE || sop == OP_EXTRACTELEMENT {
        var dem: bool[>..<] = [];
        var srcvt: i32 = -1;
        for i in sz {
            if used[i] { continue; }
            let v = uniq[i];
            if is_poison(v) { per[i] = 0; continue; }
            if srcvt < 0 {
                if sop == OP_EXTRACTELEMENT { srcvt = vals[op(v, 0)].ty; }
                else {
                    let at: i32 = vals[op(v, 0)].ty;
                    let n = if ty_kind(at) == TK_ARRAY { ty_count(at) } else { ty_count(at) };
                    srcvt = slp_widened_type(osty, n);
                }
            }
            if slp_has_one_use(v) {
                let ext = slp_user_back(v);
                if (is_inst_op(ext, OP_SEXT) || is_inst_op(ext, OP_ZEXT)) && slp_users_all_op(ext, OP_GEP) {
                    var c = tv_extract_with_extend(iop(ext), vals[ext].ty, srcvt, slp_extract_index(v));
                    c = tc_sub(c, tv_cast(iop(ext), vals[ext].ty, vals[v].ty, tv_cast_context_hint(ext), TCK_RECIP_THROUGHPUT, ext));
                    per[i] = c;
                    continue;
                }
            }
            if dem.len == 0 { for k in ty_count(srcvt) { dem.push(false); } }
            dem[slp_extract_index(v)] = true;
            per[i] = 0;
        }
        var anyd = false;
        for d in dem { if d { anyd = true; } }
        let vc = tc_sub(common, if !anyd { 0 } else { tv_scalarization_overhead(srcvt, dem, false, true, TCK_RECIP_THROUGHPUT) });
        return cost_diff(sum_scalar(per), vc);
    }
    if sop == OP_INSERTVALUE || sop == OP_INSERTELEMENT {
        let srcvt = slp_insert_build_vector_src_ty(e);
        let nelts = ty_count(srcvt);
        let ns = vl.len;
        let nparts = slp_number_of_parts(srcvt, vals[op(vl0, 1)].ty, 0x7FFFFFFF);
        var imask: i32[>..<] = [];
        for k in nelts { imask.push(-1); }
        var obeg = slp_element_index(vl[0], 0);
        var oend = obeg;
        imask[obeg] = 0;
        for i in 1..vl.len {
            let idx = slp_element_index(vl[i], 0);
            if obeg > idx { obeg = idx; } else if oend < idx { oend = idx; }
            imask[idx] = i as i32;
        }
        var vss = slp_bit_ceil(nelts);
        if nparts > 0 && nparts < nelts { vss = slp_bit_ceil((nelts + nparts - 1) / nparts); }
        let vsz = (1 + oend / vss - obeg / vss) * vss;
        let offset = vss * (obeg / vss);
        let a = slp_bit_ceil(oend - obeg + 1);
        let b = ((oend - obeg + vss) / vss) * vss;
        var ivsz = if a < b { a } else { b };
        let whole = obeg == offset && ((oend + 1) % vss == 0);
        if obeg + ivsz > vsz {
            obeg = offset + ((obeg - offset) / vsz) * vsz;
            ivsz = vsz;
        }
        var dem: bool[>..<] = [];
        for k in nelts { dem.push(false); }
        var m: i32[>..<] = [];
        if slp_te[e].nreord > 0 {
            slp_inverse_permutation(te_reorder(e), m);
            while m.len < ivsz { m.push(-1); }
        } else {
            for k in vsz { m.push(-1); }
            for k in ivsz { m[k] = k as i32; }
        }
        var ident = true;
        var prev: i32[>..<] = [];
        slp_copy_list(m, prev);
        m.clear();
        for k in ivsz { m.push(-1); }
        var adj: i32[>..<] = [];
        for k in nelts { adj.push(c_poison(sty)); }
        for i in ns {
            let v = vl[prev[i] as i64];
            let ii = slp_element_index(v, 0);
            dem[ii] = true;
            adj[ii] = v;
            ident = ident && ii - obeg == i;
            m[ii - obeg] = i as i32;
        }
        var cost: i64 = 0;
        let ivt = slp_widened_type(sty, ivsz);
        if !ident { cost = tc_add(cost, slp_shuffle_cost(SK_PERMUTESINGLESRC, ivt, m, 0, -1)); }
        var first: i32 = -1;
        for v in te_scalars(e) { if !slp_contains(te_scalars(e), op(v, 0)) { first = v; break; } }
        var um: bool[>..<] = [];
        slp_build_use_mask(nelts, imask, 2, um);
        var inm: bool[>..<] = [];
        slp_undef_vector_mask(op(first, 0), false, um, inm);
        var all = true;
        for x in inm { if !x { all = false; } }
        cost = tc_sub(cost, slp_scalarization_overhead_vl(sty, srcvt, dem, true, false, all, adj));
        if !all && ns != nelts && !whole {
            if ivsz != vsz {
                cost = tc_add(cost, slp_shuffle_cost(SK_INSERTSUBVECTOR, slp_widened_type(sty, vsz), slp_no_mask(), obeg - offset, ivt));
            } else {
                for i in (obeg - offset) { m[i] = if inm[i] { -1 } else { i as i32 }; }
                for i in (obeg - offset)..(oend - offset + 1) { if m[i] != -1 { m[i] = (i + vsz) as i32; } }
                for i in (oend + 1 - offset)..vsz { m[i] = if i >= inm.len || inm[i] { -1 } else { i as i32 }; }
                cost = tc_add(cost, slp_shuffle_cost(SK_PERMUTETWOSRC, ivt, m, 0, -1));
            }
        }
        if sop == OP_INSERTVALUE && !slp_can_vector_store_insert_value(e) {
            slp_fail("the cost of an insertvalue node without a vector store (getPrefTypeAlign)");
        }
        return tc_add(cost, sr);
    }
    if is_cast_op(sop) {
        let src_te = slp_operand_entry(e, 0);
        var ssty: i32 = vals[op(vl0, 0)].ty;
        var svt = slp_widened_type(ssty, vl.len);
        let opc = sop;
        var vo = opc;
        let sm = slp_te[src_te].mbw > 0;
        if !ty_is_fp(ty_scalar(sty)) && !ty_is_fp(ty_scalar(ssty)) && (sm || has_mbw) {
            var sbw = slp_dl_bits(ty_scalar(ssty));
            if sm {
                sbw = slp_te[src_te].mbw as i64;
                let n = if ty_kind(ssty) == TK_FVEC { ty_count(ssty) } else { 1 };
                ssty = ty_int(sbw);
                svt = slp_widened_type(ssty, vl.len * n);
            }
            let bw = slp_dl_bits(ty_scalar(sty));
            if bw == sbw { vo = OP_BITCAST; }
            else if bw < sbw { vo = OP_TRUNC; }
            else if has_mbw { vo = if slp_te[e].mbw_s { OP_SEXT } else { OP_ZEXT }; }
            else if sm { vo = if slp_te[src_te].mbw_s { OP_SEXT } else { OP_ZEXT }; }
        } else if vo == OP_SITOFP && sm && !slp_te[src_te].mbw_s {
            vo = OP_UITOFP;
        }
        per[0] = tv_cast(opc, vals[vl0].ty, vals[op(vl0, 0)].ty, tv_cast_context_hint(vl0), TCK_RECIP_THROUGHPUT, vl0);
        var vc: i64 = 0;
        if vo != opc && vo == OP_BITCAST {
            vc = common;
        } else {
            let vi = if iop(vl0) == opc { vl0 } else { -1 };
            let cch = cast_context_hint(op(vl0, 0));
            var ext_rdx = e == 0 && slp_uil_on;
            if ext_rdx {
                for x in slp_uil_vals {
                    let xo = iop(x);
                    if !(xo == OP_ADD || xo == OP_FADD || xo == OP_MUL || xo == OP_FMUL || xo == OP_AND || xo == OP_OR || xo == OP_XOR) { ext_rdx = false; break; }
                }
            }
            if ext_rdx && (vo == OP_ZEXT || vo == OP_SEXT) { vc = common; }
            else { vc = tc_add(common, tv_cast(vo, vecty, svt, cch, TCK_RECIP_THROUGHPUT, if vo == opc { vi } else { -1 })); }
        }
        return cost_diff(scalar_total(), vc);
    }
    if sop == OP_FCMP || sop == OP_ICMP || sop == OP_SELECT {
        if sop != OP_SELECT {
            sty = slp_value_type(vl0, true);
            osty = sty;
            vecty = slp_widened_type(sty, vl.len);
        }
        let fp = ty_is_fp(sty);
        let bad: i64 = if fp { 16 } else { PRED_BAD_ICMP };
        var vpred: i64 = bad;
        var spred: i64 = bad;
        if (is_inst_op(vl0, OP_SELECT) && slp_is_cmp(op(vl0, 0))) || slp_is_cmp(vl0) {
            vpred = if slp_is_cmp(vl0) { inst_pred(vl0) } else { inst_pred(op(vl0, 0)) };
            spred = slp_swapped_pred(vpred);
        }
        for i in sz {
            if used[i] { continue; }
            let vi = uniq[i];
            if is_poison(vi) { per[i] = 0; continue; }
            if !is_inst_op(vi, OP_SELECT) { per[i] = tv_inst_cost(vi, TCK_RECIP_THROUGHPUT); continue; }
            var cur: i64 = bad;
            var lhs: i32 = -1;
            var rhs: i32 = -1;
            var is_sel = false;
            if sop == OP_SELECT {
                is_sel = true;
                lhs = op(vi, 1);
                rhs = op(vi, 2);
                if slp_is_cmp(op(vi, 0)) { cur = inst_pred(op(vi, 0)); }
            }
            if (!is_sel && !slp_is_cmp(vi)) || (cur != vpred && cur != spred) { vpred = bad; spred = bad; }
            var sc = TTI_INVALID;
            if is_sel && vals[lhs].ty as i32 == vals[op(vi, 0)].ty as i32 {
                if slp_is_all_ones(lhs) {
                    sc = tv_arith(OP_OR, vals[lhs].ty, TCK_RECIP_THROUGHPUT, slp_tti_oi(op(vi, 0)), slp_tti_oi(rhs));
                } else if slp_is_zero_value(rhs) {
                    sc = tv_arith(OP_AND, vals[lhs].ty, TCK_RECIP_THROUGHPUT, slp_tti_oi(op(vi, 0)), slp_tti_oi(lhs));
                }
            }
            if !tc_valid(sc) {
                let condt: i32 = if sop == OP_SELECT { vals[op(vl0, 0)].ty } else { vals[vl0].ty };
                sc = slp_cmpsel_i(te_opcode(e), osty, condt, cur, slp_tti_oi(op(vi, if sop == OP_SELECT { 1 } else { 0 })),
                                  slp_tti_oi(op(vi, if sop == OP_SELECT { 2 } else { 1 })), vi);
            }
            let icost = minmax_cost(osty, vi);
            if tc_valid(icost) { sc = icost; }
            per[i] = sc;
        }
        let mty = slp_widened_type(if sop == OP_SELECT { vals[op(vl0, 0)].ty } else { vals[vl0].ty }, vl.len);
        var vc = TTI_INVALID;
        if sop == OP_SELECT {
            let cnd = te_operand(e, 0);
            let l = te_operand(e, 1);
            let r = te_operand(e, 2);
            if vals[cnd[0]].ty as i32 == vals[l[0]].ty as i32 {
                var all1 = true;
                for v in l { if !slp_is_all_ones(v) { all1 = false; break; } }
                var all0 = true;
                for v in r { if !slp_is_zero_value(v) { all0 = false; break; } }
                if all1 { vc = tv_arith(OP_OR, vecty, TCK_RECIP_THROUGHPUT, slp_operand_info(cnd), slp_operand_info(r)); }
                else if all0 { vc = tv_arith(OP_AND, vecty, TCK_RECIP_THROUGHPUT, slp_operand_info(cnd), slp_operand_info(l)); }
            }
        }
        if !tc_valid(vc) {
            vc = slp_cmpsel_i(te_opcode(e), vecty, mty, vpred, slp_operand_info(te_operand(e, if sop == OP_SELECT { 1 } else { 0 })),
                              slp_operand_info(te_operand(e, if sop == OP_SELECT { 2 } else { 1 })), vl0);
            if is_inst_op(vl0, OP_SELECT) {
                let cn = ty_count(mty);
                let vn = ty_count(vecty);
                if cn != vn {
                    var rep: i32[>..<] = [];
                    for k in cn { for j in vn / cn { rep.push(k as i32); } }
                    vc = tc_add(vc, slp_shuffle_cost(SK_PERMUTESINGLESRC, mty, rep, 0, -1));
                }
            }
        }
        return cost_diff(sum_scalar(per), tc_add(vc, common));
    }
    if sop == CO_MINMAX as i64 {
        let one = minmax_cost(osty, -1);
        for i in sz { per[i] = one; }
        return cost_diff(sum_scalar(per), tc_add(minmax_cost(vecty, -1), common));
    }
    if sop == CO_FMULADD as i64 {
        for i in sz {
            if used[i] { continue; }
            let v = uniq[i];
            if is_poison(v) { per[i] = 0; continue; }
            var one: i32[1] = [v];
            per[i] = slp_can_convert_to_fma(one[..], te_s(e));
        }
        var fmf: u8 = FMF_FAST;
        for v in te_scalars(e) {
            if is_fp_math_operator(v) {
                fmf = fmf & insts[inst_of(v)].fmf;
                let o0 = op(v, 0);
                if is_fp_math_operator(o0) { fmf = fmf & insts[inst_of(o0)].fmf; }
            }
        }
        var tys: i32[3] = [vecty, vecty, vecty];
        return cost_diff(sum_scalar(per), tc_add(tv_intrinsic_types(IID_fmuladd, vecty, tys[..], fmf, TCK_RECIP_THROUGHPUT), common));
    }
    if sop == CO_RBITCAST as i64 || sop == CO_RBITCAST_BSWAP as i64 || sop == CO_RBITCAST_LOADS as i64 ||
       sop == CO_RBITCAST_BSWAP_LOADS as i64 || sop == CO_RCMP_BITCAST as i64 {
        if sop != CO_RCMP_BITCAST as i64 { slp_fail("the cost of reduced bitcast nodes"); }
        for i in sz {
            if used[i] { continue; }
            let v = uniq[i];
            if is_poison(v) || !is_inst(v) { per[i] = 0; continue; }
            per[i] = tv_inst_cost(v, TCK_RECIP_THROUGHPUT);
        }
        let cmpty = cmp_result_ty(vecty);
        let dst = ty_int(te_vector_factor(e));
        var bc = tv_cast(OP_BITCAST, dst, cmpty, 0, TCK_RECIP_THROUGHPUT, -1);
        if dst != sty { bc = tc_add(bc, tv_cast(OP_ZEXT, sty, dst, 0, TCK_RECIP_THROUGHPUT, -1)); }
        return cost_diff(sum_scalar(per), tc_add(bc, common));
    }
    if sop == OP_FNEG || is_binary_op(sop) {
        for i in sz {
            if used[i] { continue; }
            let v = uniq[i];
            if is_poison(v) { per[i] = 0; continue; }
            let lane = uniq_idx[i];
            let o1 = te_operand(e, 0)[lane];
            var o2 = o1;
            var nargs: i64 = 1;
            if !is_inst_op(v, OP_FNEG) { o2 = te_operand(e, 1)[lane]; nargs = 2; }
            var sc = slp_arith_args(sop, osty, slp_tti_oi(o1), slp_tti_oi(o2), o1, if nargs == 2 { o2 } else { -1 }, nargs);
            if is_inst(v) && (sop == OP_FADD || sop == OP_FSUB) {
                var one: i32[1] = [v];
                let ic = slp_can_convert_to_fma(one[..], te_s(e));
                if tc_valid(ic) { sc = ic; }
            }
            per[i] = sc;
        }
        var vc: i64 = 0;
        var done = false;
        if sop == OP_AND && has_mbw {
            for k in te_num_operands(e) {
                var all = true;
                for o in te_operand(e, k) {
                    if !(vals[o].kind == VK_CINT && ty_kind(vals[o].ty) != TK_FVEC && ap_countr_one(ci_ap(o)) >= slp_te[e].mbw as i64) { all = false; break; }
                }
                if all { vc = common; done = true; break; }
            }
        }
        if !done {
            let opidx: i64 = if is_inst_op(vl0, OP_FNEG) { 0 } else { 1 };
            vc = tc_add(tv_arith(sop, vecty, TCK_RECIP_THROUGHPUT, slp_operand_info(te_operand(e, 0)), slp_operand_info(te_operand(e, opidx))), common);
        }
        return cost_diff(sum_scalar(per), vc);
    }
    if sop == OP_GEP { return tc_add(common, gep_cost_diff(vl, vl0)); }
    if sop == OP_LOAD {
        for i in sz {
            if used[i] { continue; }
            let v = uniq[i];
            per[i] = slp_mem_i(OP_LOAD, osty, slp_ld_align(v), slp_ptr_as(op(v, 0)), 0, v);
        }
        let li0 = vl0;
        var vlc: i64 = 0;
        if st == TE_VECTORIZE {
            if slp_te[e].inter > 0 { slp_fail("the cost of interleaved loads (getInterleavedMemoryOpCost)"); }
            vlc = slp_mem_i(OP_LOAD, vecty, slp_ld_align(li0), slp_ptr_as(op(li0, 0)), 0, -1);
        } else if st == TE_SCATTER {
            vlc = slp_mem_intrinsic_cost(IID_masked_gather, vecty, op(li0, 0), false, slp_common_alignment(uniq), slp_ptr_as(op(li0, 0)));
        } else {
            slp_fail("the cost of strided / compressed loads");
        }
        let c = cost_diff(sum_scalar(per), tc_add(vlc, common));
        if st == TE_SCATTER { return c; }
        var ptrs: i32[>..<] = [];
        for v in vl { ptrs.push(op(v, 0)); }
        return tc_add(c, gep_cost_diff(ptrs, op(li0, 0)));
    }
    if sop == OP_STORE {
        let reord = slp_te[e].nreord > 0;
        for i in sz {
            if used[i] { continue; }
            let v = vl[i];
            per[i] = slp_mem_i(OP_STORE, osty, slp_ld_align(v), slp_ptr_as(op(v, 1)), slp_tti_oi(op(v, 0)), v);
        }
        let base_si = if reord { vl[te_reorder(e)[0] as i64] } else { vl0 };
        var vsc: i64 = 0;
        if st == TE_VECTORIZE {
            if slp_te[e].inter > 0 { slp_fail("the cost of interleaved stores (getInterleavedMemoryOpCost)"); }
            vsc = slp_mem_i(OP_STORE, vecty, slp_ld_align(base_si), slp_ptr_as(op(base_si, 1)), slp_operand_info(te_operand(e, 0)), -1);
        } else {
            slp_fail("the cost of strided / expanded stores");
        }
        var ptrs: i32[>..<] = [];
        for k in vl.len { ptrs.push(-1); }
        for i in vl.len {
            let idx = if reord { te_reorder(e)[i] as i64 } else { i };
            ptrs[idx] = op(vl[i], 1);
        }
        return tc_add(cost_diff(sum_scalar(per), tc_add(vsc, common)), gep_cost_diff(ptrs, op(base_si, 1)));
    }
    if sop == OP_CALL {
        let ci0 = uniq[0];
        let id0 = laa_vector_intrinsic_id_for_call(ci0);
        if id0 != 0 { per[0] = slp_intrinsic_call_cost_id(id0, ci0); }
        else { slp_fail("the scalar cost of a non-intrinsic call (getCallInstrCost)"); }
        let id = laa_vector_intrinsic_id_for_call(vl0);
        var argtys: i32[>..<] = [];
        slp_intrinsic_arg_types(vl0, id, ty_count(vecty), if has_mbw { slp_te[e].mbw as i64 } else { 0 }, argtys);
        let a, b = slp_vector_call_costs(vl0, vecty, argtys);
        return cost_diff(scalar_total(), tc_add(if a < b { a } else { b }, common));
    }
    if sop == OP_SHUFFLEVECTOR {
        for i in sz {
            if used[i] { continue; }
            let v = uniq[i];
            if is_poison(v) { per[i] = 0; continue; }
            per[i] = tv_inst_cost(v, TCK_RECIP_THROUGHPUT);
        }
        var vc: i64 = 0;
        var found_equal = false;
        for t in slp_te.len {
            if t as i32 == e { break; }
            let x = t as i32;
            if te_has_state(x) && te_is_alt_shuffle(x) &&
               ((te_opcode(x) == te_opcode(e) && te_alt_opcode(x) == te_alt_opcode(e)) ||
                (te_opcode(x) == te_alt_opcode(e) && te_alt_opcode(x) == te_opcode(e))) && te_has_equal_operands(x, e) { found_equal = true; break; }
        }
        var early = false;
        if found_equal {
            if slp_dbg_on { errs("SLP: diamond match for alternate node found.\n"); slp_dump_te(e); slp_dbg_flush(); }
        } else if is_binary_op(te_opcode(e)) {
            vc = tc_add(tv_arith0(te_opcode(e), vecty, TCK_RECIP_THROUGHPUT), tv_arith0(te_alt_opcode(e), vecty, TCK_RECIP_THROUGHPUT));
        } else if slp_is_cmp(vl0) {
            let mty = slp_widened_type(T_I1, vl.len);
            vc = tc_add(slp_cmpsel_i(te_opcode(e), vecty, mty, inst_pred(vl0), 0, 0, vl0),
                        slp_cmpsel_i(te_opcode(e), vecty, mty, inst_pred(te_alt(e)), 0, 0, te_alt(e)));
        } else {
            var sscl: i32 = vals[op(te_main(e), 0)].ty;
            var srcty = slp_widened_type(sscl, vl.len);
            if ty_is_int(sscl) && ty_is_int(sty) {
                let ste = slp_operand_entry(e, 0);
                let bwsz = slp_dl_bits(sty);
                var sbw = slp_dl_bits(vals[op(te_main(e), 0)].ty);
                if slp_te[ste].mbw > 0 {
                    sbw = slp_te[ste].mbw as i64;
                    sscl = ty_int(sbw);
                    srcty = slp_widened_type(sscl, vl.len);
                }
                if bwsz <= sbw {
                    if bwsz < sbw { vc = tv_cast(OP_TRUNC, vecty, srcty, 0, TCK_RECIP_THROUGHPUT, -1); }
                    if slp_dbg_on { errs("SLP: alternate extension, which should be truncated.\n"); slp_dump_te(e); slp_dbg_flush(); }
                    early = true;
                }
            }
            if !early {
                vc = tc_add(tv_cast(te_opcode(e), vecty, srcty, 0, TCK_RECIP_THROUGHPUT, -1), tv_cast(te_alt_opcode(e), vecty, srcty, 0, TCK_RECIP_THROUGHPUT, -1));
            }
        }
        if !early {
            var m: i32[>..<] = [];
            te_build_alt_op_shuffle_mask(e, m);
            vc = tc_add(vc, slp_shuffle_cost(SK_PERMUTETWOSRC, final_vecty, m, 0, -1));
            let o0 = te_opcode(e);
            let o1 = te_alt_opcode(e);
            var om: bool[>..<] = [];
            slp_alt_instr_mask(te_scalars(e), sty, o1, om);
            if slp_tti_legal_alt_instr(vecty, o0, o1, om) {
                let mk = mk_mark();
                let ms = mk_pool.len;
                for b in om { mk_pool.push(if b { 1 } else { 0 }); }
                let ac = x86_alt_instr_cost(vecty, o0, o1, ms, TCK_RECIP_THROUGHPUT);
                mk_release(mk);
                if ac < vc { vc = ac; }
            }
        }
        return cost_diff(sum_scalar(per), vc);
    }
    if sop == OP_FREEZE { return common; }
    fatal("internal: SLP: getEntryCost of an unknown instruction");
    return TTI_INVALID;
}
fn slp_is_all_ones(v: i32) -> bool {
    if vals[v].kind == VK_CINT { return ap_is_all_ones(ci_ap(v)); }
    if is_constant(v) && ty_is_vector(vals[v].ty) { let s = vu_get_splat_value(v); return s >= 0 && vals[s].kind == VK_CINT && ap_is_all_ones(ci_ap(s)); }
    return false;
}
fn slp_is_zero_value(v: i32) -> bool { is_constant(v) && is_null_value(v) }
