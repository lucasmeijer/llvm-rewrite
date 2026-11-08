// CorrelatedValuePropagation: a port of llvm/lib/Transforms/Scalar/CorrelatedValuePropagation.cpp (every
// process* function and runImpl, in file order). The analysis is LazyValueInfo (lvi.goose).
//
// The block walk is depth_first(&F.getEntryBlock()): df_iterator creates a block's child iterator when the walk
// first moves past it (after the block was processed), with the terminator at that point; the successor count is
// re-read at every step, so removed switch cases are not walked.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_attrs;
import gen_iids;
import apint;
import constrange;
import valuelattice;
import constfold;
import cfold;
import instsimplify;
import knownbits;
import pm;
import vt;
import poison;
import assume;
import domtree;
import dtu;
import cfgutil;
import profdata;
import analyses;
import autoupgrade;
import loopsimplify;
import sccp;
import lvi;
import tli;

fn cv_not_ported(what: const u8[:]) { fatal(str("CorrelatedValuePropagation: ", what, " is not ported yet")); }

let CV_MDK_DBG: i32 = 0;

// ---------------------------------------------------------------------------------------------
// IRBuilder<> (ConstantFolder) at an instruction; BinaryOperator::Create(..., I->getIterator())

var cvb_pos: i32 = -1;
var cvb_dl: i32 = -1;
fn cvb_set(i: i32) { cvb_pos = i; cvb_dl = inst_get_md(i, CV_MDK_DBG); }
fn cvb_insert(iv: i32, name: const u8[:]) -> i32 {
    inst_insert_before(iv, cvb_pos);
    if name.len > 0 && vals[iv].ty != T_VOID { set_name(iv, name); }
    if cvb_dl >= 0 { inst_set_md(iv, CV_MDK_DBG, cvb_dl); }
    return iv;
}
fn cvb_binop(o: i64, a: i32, b: i32, name: const u8[:], fl: u8) -> i32 {
    if is_constant(a) && is_constant(b) {
        if is_desirable_binop(o) { return ce_binop(o, a, b, fl); }
        let r = cf_binop(o, a, b);
        if r >= 0 { return r; }
    }
    let iv = create_inst(o, vals[a].ty, [a, b]);
    insts[inst_of(iv)].flags = fl;
    return cvb_insert(iv, name);
}
fn cvb_cast(o: i64, v: i32, ty: i32, name: const u8[:]) -> i32 {
    if vals[v].ty == ty { return v; }
    if is_constant(v) {
        if is_desirable_cast_op(o) { return ce_cast(o, v, ty); }
        let r = cf_cast(o, v, ty);
        if r >= 0 { return r; }
    }
    return cvb_insert(create_inst(o, ty, [v]), name);
}
// CreateTruncOrBitCast
fn cvb_trunc_or_bitcast(v: i32, ty: i32, name: const u8[:]) -> i32 {
    if lv_scalar_bits(vals[v].ty) == lv_scalar_bits(ty) { return cvb_cast(OP_BITCAST, v, ty, name); }
    return cvb_cast(OP_TRUNC, v, ty, name);
}
fn cvb_icmp(p: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    if is_constant(a) && is_constant(b) {
        let r = cf_fold_cmp_operands(p, a, b, -1);
        if r >= 0 { return r; }
    }
    let iv = create_inst(OP_ICMP, lv_cmp_result_type(vals[a].ty), [a, b]);
    insts[inst_of(iv)].pred = p as u8;
    return cvb_insert(iv, name);
}
fn cvb_freeze(v: i32, name: const u8[:]) -> i32 { cvb_insert(create_inst(OP_FREEZE, vals[v].ty, [v]), name) }
// CreateSelectWithUnknownProfile(C, T, F, PassName)
fn cvb_select_unknown_profile(c: i32, t: i32, f: i32) -> i32 {
    if is_constant(c) && is_constant(t) && is_constant(f) { cv_not_ported("a constant-folded select in the IRBuilder"); }
    let iv = cvb_insert(create_inst(OP_SELECT, vals[t].ty, [c, t, f]), "");
    // setExplicitlyUnknownBranchWeightsIfProfiled(*Sel, PassName)
    if lv_fn_entry_count(inst_func(iv)) > 0 {
        let ops: i32[2] = [md_string("unknown"), md_string("correlated-value-propagation")];
        inst_set_md(iv, md_kind_id("prof"), md_get(MK_TUPLE, -1, ops, false));
    }
    return iv;
}
fn cvb_binary_intrinsic(id: i64, a: i32, b: i32) -> i32 {
    let f = au_get_declaration(id, [vals[a].ty as i32]);
    let fty = globs[glob_of(f)].vty;
    let iv = create_inst(OP_CALL, ty_fn_ret(fty), [a, b, f]);
    insts[inst_of(iv)].ty2 = fty;
    return cvb_insert(iv, "");
}
// CreateInsertValue(Agg, Val, 0)
fn cvb_insert_value0(agg: i32, v: i32) -> i32 {
    if is_constant(agg) && is_constant(v) {
        let idx: i32[1] = [0];
        let r = cf_insertvalue(agg, v, idx);
        if r >= 0 { return r; }
    }
    let iv = create_inst(OP_INSERTVALUE, vals[agg].ty, [agg, v]);
    let at = ints.len as i32;
    ints.push(0);
    insts[inst_of(iv)].aux = at;
    insts[inst_of(iv)].naux = 1;
    return cvb_insert(iv, "");
}
// BinaryOperator::Create(Op, L, R, Name, I->getIterator()) + setDebugLoc(I->getDebugLoc())
fn cv_new_binop_before(o: i64, a: i32, b: i32, name: const u8[:], at: i32) -> i32 {
    let iv = create_inst(o, vals[a].ty, [a, b]);
    inst_insert_before(iv, at);
    if name.len > 0 { set_name(iv, name); }
    let dl = inst_get_md(at, CV_MDK_DBG);
    if dl >= 0 { inst_set_md(iv, CV_MDK_DBG, dl); }
    return iv;
}
// BinaryOperator::CreateNeg(V, Name, InsertBefore)
fn cv_new_neg_before(v: i32, name: const u8[:], at: i32) -> i32 { cv_new_binop_before(OP_SUB, c_null(vals[v].ty), v, name, at) }
fn cv_name_plus(v: i32, suffix: const u8[:]) -> u8[>..] {
    var b: u8[>..] = [];
    if vals[v].name >= 0 { b.append(sbytes(vals[v].name)); }
    b.append(suffix);
    return b;
}

// RAUW: also the AssumptionCache's AffectedValueCallbackVH (LVI's handles are queued by rauw itself)
fn cv_rauw(old: i32, nv: i32) { ac_rauw(old, nv); rauw(old, nv); }

fn cv_set_flag(i: i32, f: u8) { insts[inst_of(i)].flags = insts[inst_of(i)].flags | f; }

// ---------------------------------------------------------------------------------------------

// getConstantAt
fn cv_get_constant_at(v: i32, at: i32) -> i32 {
    let c = lvi_get_constant(v, at);
    if c >= 0 { return c; }
    if !is_inst(v) || !(iop(v) == OP_ICMP || iop(v) == OP_FCMP) { return -1; }
    let op0 = op(v, 0);
    let op1 = op(v, 1);
    if !is_constant(op1) { return -1; }
    return lvi_get_predicate_at(inst_pred(v), op0, op1, at, false);
}

// processSelect
fn cv_process_select(s: i32) -> bool {
    if ty_is_vector(vals[s].ty) || is_constant(op(s, 0)) { return false; }
    var changed = false;
    var us: i32[>..<] = [];
    var u = vals[s].first_use;
    while u >= 0 { us.push(u); u = uses[u].next; }
    for x in us {
        if uses[x].val != s { continue; }
        let i = uses[x].user;
        var c: i32 = -1;
        if iop(i) == OP_PHI {
            let k = (x - vals[i].ops) as i64;
            c = lvi_get_constant_on_edge(op(s, 0), phi_block(i, k), inst_parent(i), i);
        } else {
            c = cv_get_constant_at(op(s, 0), i);
        }
        if c < 0 || vals[c].kind != VK_CINT || ty_is_vector(vals[c].ty) { continue; }
        use_set(x, if !cint_is_zero(c) { op(s, 1) } else { op(s, 2) });
        changed = true;
    }
    if changed && vals[s].first_use < 0 { inst_erase_from_parent(s); }
    return changed;
}

// simplifyCommonValuePhi
fn cv_simplify_common_value_phi(p: i32) -> bool {
    var consts: i32[>..<] = [];
    var idxs: i64[>..<] = [];
    var common: i32 = -1;
    for i in phi_nincoming(p) {
        let inc = phi_value(p, i);
        if is_constant(inc) { consts.push(inc); idxs.push(i); }
        else if common < 0 { common = inc; }
        else if inc != common { return false; }
    }
    if common < 0 || consts.len == 0 { return false; }
    let to = inst_parent(p);
    if is_inst(common) && !dt_inst_dominates_block(common, to) { return false; }
    for k in consts.len {
        let ib = phi_block(p, idxs[k]);
        if consts[k] != lvi_get_constant_on_edge(common, ib, to, p) { return false; }
    }
    let s2 = sq_no_ac;
    sq_no_ac = true;
    let np = is_guaranteed_not_to_be_poison(common, p, 0);
    sq_no_ac = s2;
    if !np { return false; }
    cv_rauw(p, common);
    inst_erase_from_parent(p);
    return true;
}
// getValueOnEdge
fn cv_get_value_on_edge(inc: i32, from: i32, to: i32, cxt: i32) -> i32 {
    let c = lvi_get_constant_on_edge(inc, from, to, cxt);
    if c >= 0 { return c; }
    if !is_inst_op(inc, OP_SELECT) { return -1; }
    let si = inc;
    let cond = op(si, 0);
    if !ty_is_vector(vals[cond].ty) {
        let cc = lvi_get_constant_on_edge(cond, from, to, cxt);
        if cc >= 0 {
            if is_one_value(cc) { return op(si, 1); }
            if is_null_value(cc) { return op(si, 2); }
        }
    }
    let fc = op(si, 2);
    if is_constant(fc) {
        let r = lvi_get_predicate_on_edge(P_EQ, si, fc, from, to, cxt);
        if r >= 0 && vals[r].kind == VK_CINT && !ty_is_vector(vals[r].ty) && cint_is_zero(r) { return op(si, 1); }
    }
    let tc = op(si, 1);
    if is_constant(tc) {
        let r = lvi_get_predicate_on_edge(P_EQ, si, tc, from, to, cxt);
        if r >= 0 && vals[r].kind == VK_CINT && !ty_is_vector(vals[r].ty) && cint_is_zero(r) { return op(si, 2); }
    }
    return -1;
}

// processPHI
fn cv_process_phi(p: i32) -> bool {
    var changed = false;
    let bb = inst_parent(p);
    for i in phi_nincoming(p) {
        let inc = phi_value(p, i);
        if is_constant(inc) { continue; }
        let v = cv_get_value_on_edge(inc, phi_block(p, i), bb, p);
        if v >= 0 {
            set_op(p, i, v);
            changed = true;
        }
    }
    let v = simplify_instruction(p);
    if v >= 0 {
        cv_rauw(p, v);
        inst_erase_from_parent(p);
        changed = true;
    }
    if !changed { changed = cv_simplify_common_value_phi(p); }
    return changed;
}

fn cv_is_signed_pred(p: i64) -> bool { p == P_SGT || p == P_SGE || p == P_SLT || p == P_SLE }
fn cv_is_unsigned_pred(p: i64) -> bool { p == P_UGT || p == P_UGE || p == P_ULT || p == P_ULE }
// ICmpInst::getFlippedSignednessPredicate
fn cv_flip_signedness(p: i64) -> i64 { if cv_is_signed_pred(p) { p - 4 } else { p + 4 } }

// processICmp
fn cv_process_icmp(cmp: i32) -> bool {
    if !is_int_or_int_vec(vals[op(cmp, 0)].ty) { return false; }
    let p = inst_pred(cmp);
    if !cv_is_signed_pred(p) && (!cv_is_unsigned_pred(p) || has_flag(cmp, FL_SAMESIGN)) { return false; }
    var changed = false;
    let base = vals[cmp].ops;
    let cr1 = lvi_get_constant_range_at_use(base, false);
    let cr2 = lvi_get_constant_range_at_use(base + 1, false);
    if cv_is_signed_pred(p) {
        let up = rg_equivalent_pred_flipped_signedness(p, cr1, cr2);
        if up < 0 { return false; }
        insts[inst_of(cmp)].pred = up as u8;
        changed = true;
    }
    if rg_insensitive_to_signedness(cr1, cr2) {
        cv_set_flag(cmp, FL_SAMESIGN);
        changed = true;
    }
    return changed;
}

// constantFoldCmp
fn cv_constant_fold_cmp(cmp: i32) -> bool {
    let res = lvi_get_predicate_at2(inst_pred(cmp), op(cmp, 0), op(cmp, 1), cmp, true);
    if res < 0 { return false; }
    var changed = false;
    var us: i32[>..<] = [];
    var u = vals[cmp].first_use;
    while u >= 0 { us.push(u); u = uses[u].next; }
    for x in us {
        if uses[x].val != cmp { continue; }
        if inst_iid(uses[x].user) == IID_assume { continue; }
        use_set(x, res);
        changed = true;
    }
    if vals[cmp].first_use < 0 {
        inst_erase_from_parent(cmp);
        changed = true;
    }
    return changed;
}

// processCmp
fn cv_process_cmp(cmp: i32) -> bool {
    if cv_constant_fold_cmp(cmp) { return true; }
    if iop(cmp) == OP_ICMP && cv_process_icmp(cmp) { return true; }
    return false;
}

// processSwitch
fn cv_process_switch(si: i32) -> bool {
    let fv = inst_func(si);
    dtu_begin(fv, true, false, true);
    var cond = op(si, 0);
    let bb = inst_parent(si);
    var changed = false;
    var succs: i32[>..<] = [];
    var counts: i64[>..<] = [];
    for k in term_nsucc(si) {
        let s = term_succ(si, k);
        var found = false;
        for j in succs.len { if succs[j] == s { counts[j] = counts[j] + 1; found = true; } }
        if !found { succs.push(s); counts.push(1); }
    }
    {
        swp_begin(si);
        let cr = lvi_get_constant_range_at_use(vals[si].ops, false);
        var reachable: i64 = 0;
        var k: i64 = 0;
        while k < sw_ncases(si) {
            let case = sw_case_val(si, k);
            let cv = ci_ap(case);
            var pred: i64 = -1;     // -1 unknown, 0 false, 1 true
            if !rg_contains_ap(cr, cv) { pred = 0; }
            else if rg_is_single(cr) && ap_eq(cr.lo, cv) { pred = 1; }
            if pred < 0 {
                let res = lvi_get_predicate_at(P_EQ, cond, case, si, true);
                if res >= 0 && vals[res].kind == VK_CINT && !ty_is_vector(vals[res].ty) {
                    if cint_is_zero(res) { pred = 0; } else if is_one_value(res) { pred = 1; }
                }
            }
            if pred == 0 {
                let succ = sw_case_dest(si, k);
                block_remove_predecessor(succ, bb, false);
                swp_remove_case(si, k);
                cond = op(si, 0);
                changed = true;
                for j in succs.len {
                    if succs[j] == succ {
                        counts[j] = counts[j] - 1;
                        if counts[j] == 0 {
                            let ups: DTUpdate[1] = [DTUpdate { kind: DT_DELETE, from: bb, to: succ }];
                            dtu_apply_updates_permissive(ups);
                        }
                    }
                }
                continue;
            }
            if pred == 1 {
                set_op(si, 0, case);
                changed = true;
                break;
            }
            k++;
            reachable++;
        }
        if !cu_default_dest_unreachable(si) && !rg_is_size_larger_than(cr, reachable as u64) {
            let dd = sw_default(si);
            let nb = create_block_before(fv, dd, "default.unreachable");
            let ui = create_inst(OP_UNREACHABLE, T_VOID, []);
            block_append_inst(nb, ui);
            block_remove_predecessor(dd, bb, false);
            set_op(si, 1, nb);
            var cnt: i64 = 0;
            for j in succs.len { if succs[j] == dd { cnt = counts[j]; } }
            if cnt == 1 {
                let ups: DTUpdate[1] = [DTUpdate { kind: DT_DELETE, from: bb, to: dd }];
                dtu_apply_updates(ups);
            }
            let ups2: DTUpdate[1] = [DTUpdate { kind: DT_INSERT, from: bb, to: nb }];
            dtu_apply_updates(ups2);
            changed = true;
        }
        swp_end();
    }
    if changed {
        cu_dtu = true;
        cu_constant_fold_terminator(bb, false);
        cu_dtu = false;
    }
    dtu_end();
    return changed;
}

// willNotOverflow
fn cv_will_not_overflow(bo: i32) -> bool {
    let base = vals[bo].ops;
    let lr = lvi_get_constant_range_at_use(base, false);
    let rr = lvi_get_constant_range_at_use(base + 1, false);
    let nwr = rg_guaranteed_no_wrap(lv_bo_intr_binop(bo), rr, lv_bo_intr_nwk(bo));
    return rg_contains(nwr, lr);
}

// setDeducedOverflowingFlags
fn cv_set_deduced_flags(v: i32, nsw: bool, nuw: bool) {
    if !is_inst(v) { return; }
    if nsw { cv_set_flag(v, FL_NSW); }
    if nuw { cv_set_flag(v, FL_NUW); }
}

// processAbsIntrinsic
fn cv_process_abs(ii: i32) -> bool {
    let x = cb_arg(ii, 0);
    let pois = !cint_is_zero(cb_arg(ii, 1));
    let w = lv_scalar_bits(vals[x].ty);
    let intmin = ap_smin_val(w);
    let range = lvi_get_constant_range_at_use(vals[ii].ops, pois);
    if rg_icmp(P_ULE, range, rg_single(intmin)) {
        cv_rauw(ii, x);
        inst_erase_from_parent(ii);
        return true;
    }
    if !ap_is_strictly_pos(rg_smax(range)) {
        cvb_set(ii);
        var nm: u8[>..] = [];
        if vals[ii].name >= 0 { nm.append(sbytes(vals[ii].name)); }
        let negx = cvb_binop(OP_SUB, c_null(vals[x].ty), x, nm, if pois { FL_NSW } else { 0 as u8 });
        cv_rauw(ii, negx);
        inst_erase_from_parent(ii);
        if is_inst(negx) && is_binary_op(iop(negx)) { cv_process_binop(negx); }
        return true;
    }
    if !pois && !rg_contains_ap(range, intmin) {
        set_op(ii, 1, c_true());
        return true;
    }
    return false;
}

// processCmpIntrinsic
fn cv_process_cmp_intrinsic(ci: i32) -> bool {
    let base = vals[ci].ops;
    let l = lvi_get_constant_range_at_use(base, false);
    let r = lvi_get_constant_range_at_use(base + 1, false);
    let signed = inst_iid(ci) == IID_scmp;
    let ty = vals[ci].ty;
    let w = lv_scalar_bits(ty);
    if rg_icmp(if signed { P_SGT } else { P_UGT }, l, r) {
        cv_rauw(ci, ap_to_cint(ty, ap_u64(1, w)));
        inst_erase_from_parent(ci);
        return true;
    }
    if rg_icmp(if signed { P_SLT } else { P_ULT }, l, r) {
        cv_rauw(ci, ap_to_cint(ty, ap_ones(w)));
        inst_erase_from_parent(ci);
        return true;
    }
    if rg_icmp(P_EQ, l, r) {
        cv_rauw(ci, ap_to_cint(ty, ap_zero(w)));
        inst_erase_from_parent(ci);
        return true;
    }
    return false;
}

// processMinMaxIntrinsic
fn cv_process_minmax(mm: i32) -> bool {
    let id = inst_iid(mm);
    // getNonStrictPredicate(getPredicate()): smax -> sge, smin -> sle, umax -> uge, umin -> ule
    let p = if id == IID_smax { P_SGE } else if id == IID_smin { P_SLE } else if id == IID_umax { P_UGE } else { P_ULE };
    let base = vals[mm].ops;
    let l = lvi_get_constant_range_at_use(base, false);
    let r = lvi_get_constant_range_at_use(base + 1, false);
    if rg_icmp(p, l, r) {
        cv_rauw(mm, cb_arg(mm, 0));
        inst_erase_from_parent(mm);
        return true;
    }
    if rg_icmp(p, r, l) {
        cv_rauw(mm, cb_arg(mm, 1));
        inst_erase_from_parent(mm);
        return true;
    }
    if (id == IID_smin || id == IID_smax) && rg_insensitive_to_signedness(l, r) {
        cvb_set(mm);
        let nv = cvb_binary_intrinsic(if id == IID_smin { IID_umin } else { IID_umax }, cb_arg(mm, 0), cb_arg(mm, 1));
        cv_rauw(mm, nv);
        inst_erase_from_parent(mm);
        return true;
    }
    return false;
}

// processOverflowIntrinsic
fn cv_process_overflow_intrinsic(wo: i32) -> bool {
    cvb_set(wo);
    let o = lv_bo_intr_binop(wo);
    let nsw = lv_bo_intr_signed(wo);
    let nuw = !nsw;
    var nm: u8[>..] = [];
    if vals[wo].name >= 0 { nm.append(sbytes(vals[wo].name)); }
    let nop = cvb_binop(o, cb_arg(wo, 0), cb_arg(wo, 1), nm, 0);
    cv_set_deduced_flags(nop, nsw, nuw);
    let st = vals[wo].ty;
    let elems: i32[2] = [c_poison(ty_field(st, 0)), c_false_of(ty_field(st, 1))];
    let strc = c_aggregate(st, elems);
    let ni = cvb_insert_value0(strc, nop);
    cv_rauw(wo, ni);
    inst_erase_from_parent(wo);
    if is_inst(nop) && is_binary_op(iop(nop)) { cv_process_binop(nop); }
    return true;
}
fn c_false_of(ty: i32) -> i32 { ap_to_cint(ty, ap_zero(lv_scalar_bits(ty))) }

// processSaturatingInst
fn cv_process_saturating(si: i32) -> bool {
    let o = lv_bo_intr_binop(si);
    let nsw = lv_bo_intr_signed(si);
    let nuw = !nsw;
    var nm: u8[>..] = [];
    if vals[si].name >= 0 { nm.append(sbytes(vals[si].name)); }
    let bo = cv_new_binop_before(o, cb_arg(si, 0), cb_arg(si, 1), nm, si);
    cv_set_deduced_flags(bo, nsw, nuw);
    cv_rauw(si, bo);
    inst_erase_from_parent(si);
    cv_process_binop(bo);
    return true;
}

// processCallSite
fn cv_process_call_site(cb: i32) -> bool {
    let id = inst_iid(cb);
    if id == IID_abs { return cv_process_abs(cb); }
    if id == IID_scmp || id == IID_ucmp { return cv_process_cmp_intrinsic(cb); }
    if id == IID_smin || id == IID_smax || id == IID_umin || id == IID_umax { return cv_process_minmax(cb); }
    if lv_is_with_overflow(cb) {
        if cv_will_not_overflow(cb) { return cv_process_overflow_intrinsic(cb); }
    }
    if lv_is_saturating(cb) {
        if cv_will_not_overflow(cb) { return cv_process_saturating(cb); }
    }
    var changed = false;
    for b in cb_nbundles(cb) {
        if sbytes(cb_bundle_tag(cb, b)) != "deopt" { continue; }
        let start = cb_bundle_begin(cb, b);
        for j in cb_bundle_count(cb, b) {
            let k = start + j;
            let v = op(cb, k);
            if ty_is_vector(vals[v].ty) { continue; }
            if is_constant(v) { continue; }
            let c = lvi_get_constant(v, cb);
            if c < 0 { continue; }
            set_op(cb, k, c);
            changed = true;
        }
        break;
    }
    var argnos: i64[>..<] = [];
    for k in cb_nargs(cb) {
        let v = cb_arg(cb, k);
        let ty = vals[v].ty;
        if ty_kind(ty) == TK_PTR && !cb_param_has_attr(cb, k, AK_NonNull) && !is_constant(v) {
            let res = lvi_get_predicate_at(P_EQ, v, c_null(ty), cb, false);
            if res >= 0 && vals[res].kind == VK_CINT && !ty_is_vector(vals[res].ty) && cint_is_zero(res) { argnos.push(k); }
        }
    }
    if argnos.len == 0 { return changed; }
    var l = insts[inst_of(cb)].attrs;
    for k in argnos {
        l = alist_set_param(l, k, aset_with(alist_param(l, k), attr_enum(AK_NonNull)));
    }
    insts[inst_of(cb)].attrs = l;
    return true;
}

// Domain: 0 NonNegative, 1 NonPositive, 2 Unknown
fn cv_domain(cr: CRange) -> i64 {
    if rg_is_all_nonneg(cr) { return 0; }
    if rg_icmp(P_SLE, cr, rg_single(ap_zero(rg_w(cr)))) { return 1; }
    return 2;
}

fn cv_power_of2_ceil(x: i64) -> i64 { var p: i64 = 1; if x == 0 { return 0; } while p < x { p *= 2; } return p; }
fn cv_with_new_bit_width(ty: i32, w: i64) -> i32 {
    let it = ty_int(w);
    if ty_is_vector(ty) { return ty_vector(it, ty_count(ty), ty_kind(ty) == TK_SVEC); }
    return it;
}

// narrowSDivOrSRem
fn cv_narrow_sdiv_or_srem(ins: i32, lcr: CRange, rcr: CRange) -> bool {
    let ow = lv_scalar_bits(vals[ins].ty);
    var msb = max(rg_min_signed_bits(lcr), rg_min_signed_bits(rcr));
    if rg_contains_ap(rcr, ap_ones(ow)) && rg_contains_ap(lcr, ap_sext(ap_smin_val(msb), ow)) { msb++; }
    let nw = max(cv_power_of2_ceil(msb), 8);
    if nw >= ow { return false; }
    cvb_set(ins);
    let tt = cv_with_new_bit_width(vals[ins].ty, nw);
    let l = cvb_trunc_or_bitcast(op(ins, 0), tt, cv_name_plus(ins, ".lhs.trunc"));
    let r = cvb_trunc_or_bitcast(op(ins, 1), tt, cv_name_plus(ins, ".rhs.trunc"));
    let bo = cvb_binop(iop(ins), l, r, cv_name_plus(ins, ""), 0);
    let sx = cvb_cast(OP_SEXT, bo, vals[ins].ty, cv_name_plus(ins, ".sext"));
    if is_inst(bo) && iop(bo) == OP_SDIV && has_flag(ins, FL_EXACT) { cv_set_flag(bo, FL_EXACT); }
    cv_rauw(ins, sx);
    inst_erase_from_parent(ins);
    return true;
}

// expandUDivOrURem
fn cv_expand_udiv_or_urem(ins: i32, xcr: CRange, ycr: CRange) -> bool {
    let ty = vals[ins].ty;
    let is_rem = iop(ins) == OP_UREM;
    let x = op(ins, 0);
    let y = op(ins, 1);
    if rg_icmp(P_ULT, xcr, ycr) {
        cv_rauw(ins, if is_rem { x } else { c_null(ty) });
        inst_erase_from_parent(ins);
        return true;
    }
    if !rg_icmp(P_ULT, xcr, rg_uadd_sat(ycr, ycr)) && !rg_is_all_negative(ycr) { return false; }
    cvb_set(ins);
    var ex: i32 = -1;
    if rg_icmp(P_UGE, xcr, ycr) {
        if is_rem { ex = cvb_binop(OP_SUB, x, y, "", FL_NUW); }
        else { ex = ap_to_cint(ty, ap_u64(1, lv_scalar_bits(ty))); }
    } else if is_rem {
        var fx = x;
        if !lv_not_undef_noac(x) { fx = cvb_freeze(x, cv_name_plus(x, ".frozen")); }
        var fy = y;
        if !lv_not_undef_noac(y) { fy = cvb_freeze(y, cv_name_plus(y, ".frozen")); }
        let adj = cvb_binop(OP_SUB, fx, fy, cv_name_plus(ins, ".urem"), FL_NUW);
        let cmp = cvb_icmp(P_ULT, fx, fy, cv_name_plus(ins, ".cmp"));
        ex = cvb_select_unknown_profile(cmp, fx, adj);
    } else {
        let cmp = cvb_icmp(P_UGE, x, y, cv_name_plus(ins, ".cmp"));
        ex = cvb_cast(OP_ZEXT, cmp, ty, cv_name_plus(ins, ".udiv"));
    }
    cv_take_name(ex, ins);
    cv_rauw(ins, ex);
    inst_erase_from_parent(ins);
    return true;
}
// isGuaranteedNotToBeUndef(V) (no AC, context or DT)
fn lv_not_undef_noac(v: i32) -> bool {
    let s = sq_no_ac;
    sq_no_ac = true;
    let r = lv_not_undef(v);
    sq_no_ac = s;
    return r;
}
// Value::takeName (a constant destination only clears the source's name)
fn cv_take_name(dst: i32, src: i32) {
    if is_constant(dst) { if vals[src].name >= 0 { set_name(src, ""); } return; }
    cu_take_name(dst, src);
}

// narrowUDivOrURem
fn cv_narrow_udiv_or_urem(ins: i32, xcr: CRange, ycr: CRange) -> bool {
    let mab = max(rg_active_bits(xcr), rg_active_bits(ycr));
    let nw = max(cv_power_of2_ceil(mab), 8);
    if nw >= lv_scalar_bits(vals[ins].ty) { return false; }
    cvb_set(ins);
    let tt = cv_with_new_bit_width(vals[ins].ty, nw);
    let l = cvb_trunc_or_bitcast(op(ins, 0), tt, cv_name_plus(ins, ".lhs.trunc"));
    let r = cvb_trunc_or_bitcast(op(ins, 1), tt, cv_name_plus(ins, ".rhs.trunc"));
    let bo = cvb_binop(iop(ins), l, r, cv_name_plus(ins, ""), 0);
    let zx = cvb_cast(OP_ZEXT, bo, vals[ins].ty, cv_name_plus(ins, ".zext"));
    if is_inst(bo) && iop(bo) == OP_UDIV && has_flag(ins, FL_EXACT) { cv_set_flag(bo, FL_EXACT); }
    cv_rauw(ins, zx);
    inst_erase_from_parent(ins);
    return true;
}

// processUDivOrURem
fn cv_process_udiv_or_urem(ins: i32) -> bool {
    let base = vals[ins].ops;
    let xcr = lvi_get_constant_range_at_use(base, false);
    let ycr = lvi_get_constant_range_at_use(base + 1, true);
    if cv_expand_udiv_or_urem(ins, xcr, ycr) { return true; }
    return cv_narrow_udiv_or_urem(ins, xcr, ycr);
}

// processSRem
fn cv_process_srem(sdi: i32, lcr: CRange, rcr: CRange) -> bool {
    if rg_icmp(P_ULT, rg_abs(lcr, false), rg_abs(rcr, false)) {
        cv_rauw(sdi, op(sdi, 0));
        inst_erase_from_parent(sdi);
        return true;
    }
    var ov: i32[2] = [op(sdi, 0), op(sdi, 1)];
    let d: i64[2] = [cv_domain(lcr), cv_domain(rcr)];
    if d[0] == 2 || d[1] == 2 { return false; }
    for k in 2 {
        if d[k] == 0 { continue; }
        ov[k] = cv_new_neg_before(ov[k], cv_name_plus(ov[k], ".nonneg"), sdi);
    }
    let urem = cv_new_binop_before(OP_UREM, ov[0], ov[1], cv_name_plus(sdi, ""), sdi);
    var res = urem;
    if d[0] == 1 { res = cv_new_neg_before(res, cv_name_plus(res, ".neg"), sdi); }
    cv_rauw(sdi, res);
    inst_erase_from_parent(sdi);
    cv_process_udiv_or_urem(urem);
    return true;
}

// processSDiv
fn cv_process_sdiv(sdi: i32, lcr: CRange, rcr: CRange) -> bool {
    let divcr = rg_sdiv(lcr, rcr);
    if rg_is_single(divcr) {
        cv_rauw(sdi, ap_to_cint(vals[sdi].ty, divcr.lo));
        inst_erase_from_parent(sdi);
        return true;
    }
    var ov: i32[2] = [op(sdi, 0), op(sdi, 1)];
    let d: i64[2] = [cv_domain(lcr), cv_domain(rcr)];
    if d[0] == 2 || d[1] == 2 { return false; }
    for k in 2 {
        if d[k] == 0 { continue; }
        ov[k] = cv_new_neg_before(ov[k], cv_name_plus(ov[k], ".nonneg"), sdi);
    }
    let udiv = cv_new_binop_before(OP_UDIV, ov[0], ov[1], cv_name_plus(sdi, ""), sdi);
    if has_flag(sdi, FL_EXACT) { cv_set_flag(udiv, FL_EXACT); }
    var res = udiv;
    if d[0] != d[1] { res = cv_new_neg_before(res, cv_name_plus(res, ".neg"), sdi); }
    cv_rauw(sdi, res);
    inst_erase_from_parent(sdi);
    cv_process_udiv_or_urem(udiv);
    return true;
}

// processSDivOrSRem
fn cv_process_sdiv_or_srem(ins: i32) -> bool {
    let base = vals[ins].ops;
    let lcr = lvi_get_constant_range_at_use(base, false);
    let rcr = lvi_get_constant_range_at_use(base + 1, true);
    if iop(ins) == OP_SDIV { if cv_process_sdiv(ins, lcr, rcr) { return true; } }
    if iop(ins) == OP_SREM { if cv_process_srem(ins, lcr, rcr) { return true; } }
    return cv_narrow_sdiv_or_srem(ins, lcr, rcr);
}

// processAShr
fn cv_process_ashr(sdi: i32) -> bool {
    let lr = lvi_get_constant_range_at_use(vals[sdi].ops, false);
    let ow = lv_scalar_bits(vals[sdi].ty);
    let neg_one_or_zero = rg_new(ap_ones(ow), ap_u64(1, ow));
    if rg_contains(neg_one_or_zero, lr) {
        cv_rauw(sdi, op(sdi, 0));
        inst_erase_from_parent(sdi);
        return true;
    }
    if !rg_is_all_nonneg(lr) { return false; }
    let bo = cv_new_binop_before(OP_LSHR, op(sdi, 0), op(sdi, 1), "", sdi);
    cu_take_name(bo, sdi);
    if has_flag(sdi, FL_EXACT) { cv_set_flag(bo, FL_EXACT); }
    cv_rauw(sdi, bo);
    inst_erase_from_parent(sdi);
    return true;
}

// CastInst::Create(Op, V, Ty, "", I->getIterator()) + takeName + setDebugLoc + setNonNeg
fn cv_replace_cast(i: i32, o: i64) -> i32 {
    let base = op(i, 0);
    let ni = create_inst(o, vals[i].ty, [base]);
    inst_insert_before(ni, i);
    cu_take_name(ni, i);
    let dl = inst_get_md(i, CV_MDK_DBG);
    if dl >= 0 { inst_set_md(ni, CV_MDK_DBG, dl); }
    cv_set_flag(ni, FL_NNEG);
    cv_rauw(i, ni);
    inst_erase_from_parent(i);
    return ni;
}

// processSExt
fn cv_process_sext(sdi: i32) -> bool {
    if !rg_is_all_nonneg(lvi_get_constant_range_at_use(vals[sdi].ops, false)) { return false; }
    // CreateZExtOrBitCast: the types differ in width (a sext)
    cv_replace_cast(sdi, OP_ZEXT);
    return true;
}

// processPossibleNonNeg (zext, uitofp)
fn cv_process_possible_non_neg(i: i32) -> bool {
    if has_flag(i, FL_NNEG) { return false; }
    if !rg_is_all_nonneg(lvi_get_constant_range_at_use(vals[i].ops, false)) { return false; }
    cv_set_flag(i, FL_NNEG);
    return true;
}

// processSIToFP
fn cv_process_sitofp(i: i32) -> bool {
    if !rg_is_all_nonneg(lvi_get_constant_range_at_use(vals[i].ops, false)) { return false; }
    cv_replace_cast(i, OP_UITOFP);
    return true;
}

// processBinOp
fn cv_process_binop(bo: i32) -> bool {
    let nsw = has_flag(bo, FL_NSW);
    let nuw = has_flag(bo, FL_NUW);
    if nsw && nuw { return false; }
    let o = iop(bo);
    let base = vals[bo].ops;
    let lr = lvi_get_constant_range_at_use(base, false);
    let rr = lvi_get_constant_range_at_use(base + 1, false);
    var changed = false;
    var new_nuw = false;
    var new_nsw = false;
    if !nuw {
        new_nuw = rg_contains(rg_guaranteed_no_wrap(o, rr, NW_NUW), lr);
        changed = changed || new_nuw;
    }
    if !nsw {
        new_nsw = rg_contains(rg_guaranteed_no_wrap(o, rr, NW_NSW), lr);
        changed = changed || new_nsw;
    }
    cv_set_deduced_flags(bo, new_nsw, new_nuw);
    return changed;
}

// processAnd
fn cv_process_and(bo: i32) -> bool {
    let c = m_apint_ap(op(bo, 1), true);
    if c < 0 { return false; }
    let rhs = ci_ap(c);
    // m_LowBitMask(const APInt *&): a splat (poison lanes allowed) mask 0b0..01..1
    if !ap_is_mask(rhs) { return false; }
    let lr = lvi_get_constant_range_at_use(vals[bo].ops, false);
    if !ap_ule(rg_umax(lr), rhs) { return false; }
    cv_rauw(bo, op(bo, 0));
    inst_erase_from_parent(bo);
    return true;
}

// processTrunc
fn cv_process_trunc(ti: i32) -> bool {
    let nsw = has_flag(ti, FL_NSW);
    let nuw = has_flag(ti, FL_NUW);
    if nsw && nuw { return false; }
    let range = lvi_get_constant_range_at_use(vals[ti].ops, false);
    let dw = lv_scalar_bits(vals[ti].ty);
    var changed = false;
    if !nuw && rg_active_bits(range) <= dw { cv_set_flag(ti, FL_NUW); changed = true; }
    if !nsw && rg_min_signed_bits(range) <= dw { cv_set_flag(ti, FL_NSW); changed = true; }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// runImpl

struct CvFrame { b: i32, term: i32, next: i64, init: bool }

fn cv_visit(bb: i32, has_ret: bool, ret_range: CRange&) -> bool {
    var changed = false;
    var i = block_first(bb);
    while i >= 0 {
        let nx = inst_next(i);
        let o = iop(i);
        if o == OP_SELECT { changed = cv_process_select(i) || changed; }
        else if o == OP_PHI { changed = cv_process_phi(i) || changed; }
        else if o == OP_ICMP || o == OP_FCMP { changed = cv_process_cmp(i) || changed; }
        else if o == OP_CALL || o == OP_INVOKE { changed = cv_process_call_site(i) || changed; }
        else if o == OP_SREM || o == OP_SDIV { changed = cv_process_sdiv_or_srem(i) || changed; }
        else if o == OP_UDIV || o == OP_UREM { changed = cv_process_udiv_or_urem(i) || changed; }
        else if o == OP_ASHR { changed = cv_process_ashr(i) || changed; }
        else if o == OP_SEXT { changed = cv_process_sext(i) || changed; }
        else if o == OP_ZEXT || o == OP_UITOFP { changed = cv_process_possible_non_neg(i) || changed; }
        else if o == OP_SITOFP { changed = cv_process_sitofp(i) || changed; }
        else if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL { changed = cv_process_binop(i) || changed; }
        else if o == OP_AND { changed = cv_process_and(i) || changed; }
        else if o == OP_TRUNC { changed = cv_process_trunc(i) || changed; }
        i = nx;
    }
    let t = block_terminator(bb);
    if iop(t) == OP_SWITCH {
        changed = cv_process_switch(t) || changed;
    } else if iop(t) == OP_RET && nops(t) > 0 {
        let rv = op(t, 0);
        if has_ret && !rg_is_full(ret_range) {
            ret_range = rg_union(ret_range, lvi_get_constant_range(rv, t, false));
        }
        if !is_constant(rv) {
            let c = cv_get_constant_at(rv, t);
            if c >= 0 {
                for k in nops(t) { if op(t, k) == rv { set_op(t, k, c); } }
                changed = true;
            }
        }
    }
    return changed;
}

fn cv_run_impl(fv: i32) -> bool {
    var fn_changed = false;
    let rty = ty_fn_ret(globs[glob_of(fv)].vty);
    let has_ret = sc_has_exact_definition(fv) && is_int_or_int_vec(rty);
    var ret_range = rg_empty(if has_ret { lv_scalar_bits(rty) } else { 1 });
    // depth_first(&F.getEntryBlock())
    var visited: i32[>..<] = [];
    var stack: CvFrame[>..<] = [];
    let entry = func_entry(fv);
    vs_clear(VS_PASS0);
    vs_add(VS_PASS0, entry);
    stack.push(CvFrame { b: entry, term: -1, next: 0, init: false });
    fn_changed = cv_visit(entry, has_ret, ret_range) || fn_changed;
    while stack.len > 0 {
        let top = stack.len - 1;
        if !stack[top].init { stack[top].init = true; stack[top].term = block_terminator(stack[top].b); stack[top].next = 0; }
        let t = stack[top].term;
        if t >= 0 && stack[top].next < term_nsucc(t) {
            let s = term_succ(t, stack[top].next);
            stack[top].next = stack[top].next + 1;
            if vs_add(VS_PASS0, s) {
                stack.push(CvFrame { b: s, term: -1, next: 0, init: false });
                fn_changed = cv_visit(s, has_ret, ret_range) || fn_changed;
            }
            continue;
        }
        stack.pop();
    }
    let unused = visited.len;
    if has_ret && !rg_is_full(ret_range) {
        let g = glob_of(fv);
        let al = globs[g].attrs;
        let ok, old = rg_from_range_attr(alist_ret(al));
        if ok { ret_range = rg_intersect(ret_range, old); }
        if !rg_is_empty(ret_range) && !rg_is_single(ret_range) {
            globs[g].attrs = cv_alist_set_ret(al, aset_with(alist_ret(al), rg_attr(ret_range)));
            fn_changed = true;
        }
    }
    return fn_changed;
}
fn cv_alist_set_ret(l: i32, s: i32) -> i32 {
    var xs: i32[>..<] = [];
    xs.push(alist_fn(l));
    xs.push(s);
    let n = if l == 0 { 0 } else { alists[l].n as i64 - 2 };
    for j in n { xs.push(alist_param(l, j)); }
    return alist_get(xs);
}

// CorrelatedValuePropagationPass::run
fn cvp_run(fv: i32) -> u32 {
    lvi_get(fv);
    dt_get(fv, DT_DOM);
    tli_cur_fn = fv;
    let changed = cv_run_impl(fv);
    // PA.abandon<LazyValueAnalysis>() in both cases
    if !changed { return PA_ALL & ~((1 as u32) << A_LVI); }
    return (1 as u32) << A_DOMTREE;
}
