// Induction variable simplification and widening.
// Port of llvm/lib/Transforms/Utils/SimplifyIndVar.cpp (LLVM 23.1.5): findCommonDominator, class SimplifyIndvar
// (foldIVUser, makeIVComparisonInvariant, eliminateIVComparison, eliminateSDiv, replaceSRemWithURem,
// replaceRemWithNumerator(OrZero), simplifyIVRemainder, eliminateOverflowIntrinsic, eliminateSaturatingIntrinsic,
// eliminateTrunc, eliminateIVUser, replaceIVUserWithLoopInvariant, replaceFloatIVWithIntegerIV,
// eliminateIdentitySCEV, strengthenBinaryOp / strengthenOverflowingOperation / strengthenRightShift,
// pushIVUsers, isSimpleIVUser, simplifyUsers), simplifyUsersOfIV, simplifyLoopIVs, class WidenIV
// (getInsertPointForUses, createExtendInst, cloneIVUser / cloneArithmeticIVUser / cloneBitwiseIVUser,
// getSCEVByOpCode, matchBinaryOp, getExtendedOperandRecurrence, getWideRecurrence, truncateIVUse,
// widenLoopCompare, widenWithVariantUse, widenIVUse, pushNarrowIVUsers, createWideIV, calculatePostIncRange(s))
// and createWideIV. Also IndVarSimplify.cpp's visitIVCast (the IndVarSimplifyVisitor) and
// Type::getFPMantissaWidth, DominatorTree::findNearestCommonDominator(Instruction*, Instruction*).
//
// DeadInsts is `iv_dead`, a list of WeakTrackingVH handles (wvh.goose) owned by the running IndVarSimplify.
// The SCEVExpander is the active one (scev_expander.goose). IRBuilder<> (ConstantFolder) is ib_*.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import pm;
import gen_iids;
import constfold;
import cfold;
import datalayout;
import apint;
import constrange;
import poison;
import local;
import instsimplify;
import loopinfo;
import loopsimplify;
import domtree;
import lcssa;
import dbgutil;
import tti;
import wvh;
import scev;
import scev_create;
import scev_range;
import scev_eval;
import scev_btc;
import scev_pred;
import scev_update;
import scev_expander;

var iv_dead: i32[>..<];     // DeadInsts (WeakTrackingVH handles)
fn iv_dead_push(v: i32) { iv_dead.push(wvh_new(v, WVH_WEAK_TRACKING)); }

// ---------------------------------------------------------------------------------------------
// IRBuilder<> (ConstantFolder)

var ib_bb: i32 = -1;
var ib_pos: i32 = -1;
var ib_head: bool = false;
var ib_dl: i32 = -1;
// IRBuilder<> Builder(I) / SetInsertPoint(I)
fn ib_set(i: i32) { ib_bb = inst_parent(i); ib_pos = i; ib_head = false; ib_dl = inst_get_md(i, 0); }
// SetInsertPoint(BB, It)
fn ib_set_it(bb: i32, pos: i32, head: bool) { ib_bb = bb; ib_pos = pos; ib_head = head; if pos >= 0 { ib_dl = inst_get_md(pos, 0); } }
fn ib_insert(iv: i32, name: const u8[:]) -> i32 {
    inst_insert_at(iv, ib_bb, ib_pos, ib_head);
    if vals[iv].ty != T_VOID { set_name(iv, name); }
    if ib_dl >= 0 { inst_set_md(iv, 0, ib_dl); }
    return iv;
}
// ConstantFolder::FoldCast
fn ib_fold_cast(o: i64, v: i32, ty: i32) -> i32 {
    if !is_constant(v) { return -1; }
    if is_desirable_cast_op(o) { return ce_cast(o, v, ty); }
    return cf_cast(o, v, ty);
}
fn ib_cast(o: i64, v: i32, ty: i32, name: const u8[:]) -> i32 {
    if vals[v].ty == ty { return v; }
    let f = ib_fold_cast(o, v, ty);
    if f >= 0 { return f; }
    return ib_insert(create_inst(o, ty, [v]), name);
}
fn ib_trunc(v: i32, ty: i32, name: const u8[:], nuw: bool, nsw: bool) -> i32 {
    if vals[v].ty == ty { return v; }
    let f = ib_fold_cast(OP_TRUNC, v, ty);
    if f >= 0 { return f; }
    let iv = create_inst(OP_TRUNC, ty, [v]);
    var fl: u8 = 0;
    if nuw { fl |= FL_NUW; }
    if nsw { fl |= FL_NSW; }
    insts[inst_of(iv)].flags = fl;
    return ib_insert(iv, name);
}
fn ib_icmp(p: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    if is_constant(a) && is_constant(b) {
        let r = cf_fold_cmp_operands(p, a, b, -1);
        if r >= 0 { return r; }
    }
    let iv = create_inst(OP_ICMP, cmp_result_ty(vals[a].ty), [a, b]);
    insts[inst_of(iv)].pred = p as u8;
    return ib_insert(iv, name);
}
fn ib_phi(ty: i32, reserve: i64, name: const u8[:]) -> i32 {
    let pn = new_inst(OP_PHI, ty, reserve);
    vals[pn].nops = 0;
    return ib_insert(pn, name);
}
// a name copied out of the string pool (val_name is a slice of it)
fn iv_name_plus(v: i32, suffix: const u8[:]) -> u8[>..] {
    var nm: u8[>..] = [];
    nm.append(val_name(v));
    nm.append(suffix);
    return nm;
}

// ---------------------------------------------------------------------------------------------
// Small helpers

// DominatorTree::findNearestCommonDominator(Instruction *I1, Instruction *I2)
fn iv_ncd_inst(i1: i32, i2: i32) -> i32 {
    let b1 = inst_parent(i1);
    let b2 = inst_parent(i2);
    if b1 == b2 { return if comes_before(i1, i2) { i1 } else { i2 }; }
    if !dt_has_node(DT_DOM, b2) { return i1; }
    if !dt_has_node(DT_DOM, b1) { return i2; }
    let d = dt_find_ncd(DT_DOM, b1, b2);
    if b1 == d { return i1; }
    if b2 == d { return i2; }
    return block_terminator(d);
}
// findCommonDominator
fn iv_find_common_dominator(xs: const i32[:]) -> i32 {
    var c: i32 = -1;
    for i in xs { c = if c >= 0 { iv_ncd_inst(c, i) } else { i }; }
    return c;
}
// Type::getFPMantissaWidth
fn iv_fp_mantissa_width(t: i32) -> i64 {
    let k = ty_kind(t);
    if k == TK_HALF { return 11; }
    if k == TK_BFLOAT { return 8; }
    if k == TK_FLOAT { return 24; }
    if k == TK_DOUBLE { return 53; }
    if k == TK_X86_FP80 { return 64; }
    if k == TK_FP128 { return 113; }
    return -1;
}
fn iv_is_obo(i: i32) -> bool { let o = iop(i); o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL }
fn iv_is_binop(i: i32) -> bool { is_inst(i) && is_binary_op(iop(i)) }
fn iv_is_icmp(i: i32) -> bool { is_inst(i) && iop(i) == OP_ICMP }
// CmpInst::getCmpPredicate (samesign as CP_SAMESIGN)
fn iv_cmp_pred(i: i32) -> i64 { (insts[inst_of(i)].pred as i64) | (if has_flag(i, FL_SAMESIGN) { CP_SAMESIGN } else { 0 }) }
fn iv_set_pred(i: i32, p: i64) { insts[inst_of(i)].pred = cpp(p) as u8; }
// WithOverflowInst: the binary op (or -1) and signedness
fn iv_with_overflow(i: i32) -> i64, bool {
    let id = inst_iid(i);
    if id == IID_sadd_with_overflow { return OP_ADD, true; }
    if id == IID_uadd_with_overflow { return OP_ADD, false; }
    if id == IID_ssub_with_overflow { return OP_SUB, true; }
    if id == IID_usub_with_overflow { return OP_SUB, false; }
    if id == IID_smul_with_overflow { return OP_MUL, true; }
    if id == IID_umul_with_overflow { return OP_MUL, false; }
    return -1, false;
}
// SaturatingInst
fn iv_saturating(i: i32) -> i64, bool {
    let id = inst_iid(i);
    if id == IID_uadd_sat { return OP_ADD, false; }
    if id == IID_sadd_sat { return OP_ADD, true; }
    if id == IID_usub_sat { return OP_SUB, false; }
    if id == IID_ssub_sat { return OP_SUB, true; }
    return -1, false;
}
fn iv_set_nuw(i: i32, b: bool) { let ii = inst_of(i); if b { insts[ii].flags |= FL_NUW; } else { insts[ii].flags &= ~FL_NUW; } }
fn iv_set_nsw(i: i32, b: bool) { let ii = inst_of(i); if b { insts[ii].flags |= FL_NSW; } else { insts[ii].flags &= ~FL_NSW; } }
fn iv_set_exact(i: i32, b: bool) { let ii = inst_of(i); if b { insts[ii].flags |= FL_EXACT; } else { insts[ii].flags &= ~FL_EXACT; } }
// Instruction::copyIRFlags(V) for binary operators (wrap flags, exact, disjoint, fast-math)
fn iv_copy_ir_flags(dst: i32, src: i32) {
    insts[inst_of(dst)].flags = insts[inst_of(src)].flags;
    insts[inst_of(dst)].fmf = insts[inst_of(src)].fmf;
}
// BinaryOperator::Create(Op, L, R, Name) + IRBuilder::Insert(BO) (named while unlinked, so the symbol table
// uniques the name when it is linked; Insert then calls setName("")) at the IRBuilder<>(NarrowUse) position
fn iv_insert_clone_binop(o: i64, lhs: i32, rhs: i32, name_src: i32, at: i32) -> i32 {
    let bo = create_inst(o, vals[lhs].ty, [lhs, rhs]);
    var nm: u8[>..] = [];
    nm.append(val_name(name_src));
    set_name(bo, nm);           // unlinked: just stored
    ib_set(at);
    inst_insert_at(bo, ib_bb, ib_pos, ib_head);
    iv_register_name(bo);       // ValueSymbolTable::reinsertValue
    set_name(bo, "");           // IRBuilder::Insert(I, Name = "")
    if ib_dl >= 0 { inst_set_md(bo, 0, ib_dl); }
    return bo;
}
// the name an unlinked instruction carries is registered (and uniqued) when it is linked
fn iv_register_name(iv: i32) {
    let n = vals[iv].name;
    if n < 0 { return; }
    let st = symtab_for(iv);
    if st < 0 { return; }
    if symtab_lookup(st, n) == iv { return; }
    var buf: u8[>..] = [];
    buf.append(sbytes(n));
    vals[iv].name = -1;
    set_name(iv, buf);
}
// BinaryOperator::Create(Op, L, R, Name, InsertBefore): linked before `before` (adopting its records), then named
fn iv_binop_before(o: i64, lhs: i32, rhs: i32, name: const u8[:], before: i32) -> i32 {
    let bo = create_inst(o, vals[lhs].ty, [lhs, rhs]);
    inst_insert_before(bo, before);
    set_name(bo, name);
    return bo;
}

// ---------------------------------------------------------------------------------------------
// SimplifyIndvar

var si_l: i32 = -1;
var si_changed: bool = false;
var si_unswitch: bool = false;
var si_visitor: bool = false;       // an IVVisitor is given (IndVarSimplifyVisitor)
// IndVarSimplifyVisitor's WideIVInfo
var wi_narrow: i32 = -1;
var wi_widest: i32 = -1;            // WidestNativeType (-1 = none)
var wi_signed: bool = false;

// foldIVUser(UseInst, IVOperand): the new operand, or -1
fn si_fold_iv_user(use: i32, ivop: i32) -> i32 {
    var ivsrc: i32 = -1;
    var folded: i32 = -1;
    var drop_exact = false;
    let o = iop(use);
    if o == OP_UDIV || o == OP_LSHR {
        if ivop != op(use, 0) || !is_cint(op(use, 1)) { return -1; }
        if !iv_is_binop(ivop) || !is_cint(op(ivop, 1)) { return -1; }
        ivsrc = op(ivop, 0);
        var d = op(use, 1);
        if o == OP_LSHR {
            let bw = ty_bits(vals[use].ty);
            if ap_uge_u64(ci_ap(d), bw as u64) { return -1; }
            d = ap_to_cint(vals[use].ty, ap_one_bit(bw, ap_lo64(ci_ap(d)) as i64));
        }
        let lhs = sc_get_scev(ivsrc);
        let rhs = sc_get_scev(d);
        folded = sc_get_udiv(lhs, rhs);
        if has_flag(use, FL_EXACT) && lhs != sc_mul(folded, rhs) { drop_exact = true; }
    }
    if !sc_is_scevable(vals[use].ty) { return -1; }
    if sc_get_scev(use) != folded { return -1; }
    if folded < 0 { return -1; }
    set_op(use, 0, ivsrc);
    if drop_exact { drop_poison_generating_flags(use); }
    si_changed = true;
    if vals[ivop].first_use < 0 { iv_dead_push(ivop); }
    return ivsrc;
}

// makeIVComparisonInvariant(ICmp, IVOperand)
fn si_make_iv_comparison_invariant(icmp: i32, ivop: i32) -> bool {
    let ph = loop_preheader(si_l);
    if ph < 0 { return false; }
    var idx: i64 = 0;
    var p = iv_cmp_pred(icmp);
    if ivop != op(icmp, 0) { idx = 1; p = cp_swapped(p); }
    let il = li_loop_for(inst_parent(icmp));
    let s = sc_get_scev_at_scope(sc_get_scev(op(icmp, idx)), il);
    let x = sc_get_scev_at_scope(sc_get_scev(op(icmp, 1 - idx)), il);
    let lip = sc_get_loop_invariant_predicate(p, s, x, si_l, icmp);
    if !lip.ok { return false; }
    let term = block_terminator(ph);
    if sx_is_high_cost_expansion([lip.lhs, lip.rhs], si_l, 2 * sx_cheap_budget(), term) ||
       !sx_is_safe_to_expand_at(lip.lhs, term) || !sx_is_safe_to_expand_at(lip.rhs, term) { return false; }
    let nl = sx_expand_code_for_at(lip.lhs, vals[ivop].ty, term);
    let nr = sx_expand_code_for_at(lip.rhs, vals[ivop].ty, term);
    iv_set_pred(icmp, lip.pred);
    set_op(icmp, 0, nl);
    set_op(icmp, 1, nr);
    si_unswitch = true;
    return true;
}

// eliminateIVComparison(ICmp, IVOperand)
fn si_eliminate_iv_comparison(icmp: i32, ivop: i32) {
    var idx: i64 = 0;
    var p = iv_cmp_pred(icmp);
    let orig = cpp(p);
    if ivop != op(icmp, 0) { idx = 1; p = cp_swapped(p); }
    let il = li_loop_for(inst_parent(icmp));
    let s = sc_get_scev_at_scope(sc_get_scev(op(icmp, idx)), il);
    let x = sc_get_scev_at_scope(sc_get_scev(op(icmp, 1 - idx)), il);
    var users: i32[>..<] = [];
    var u = vals[icmp].first_use;
    while u >= 0 { users.push(uses[u].user); u = uses[u].next; }
    let cx = iv_find_common_dominator(users);
    let ev = sc_evaluate_predicate_at(p, s, x, cx);
    if ev >= 0 {
        sc_forget_value(icmp);
        rauw(icmp, c_bool_ty(T_I1, ev == 1));
        iv_dead_push(icmp);
        si_changed = true;
        return;
    }
    if si_make_iv_comparison_invariant(icmp, ivop) { si_changed = true; return; }
    if (sc_pred_is_signed(orig) || (sc_pred_is_unsigned(orig) && !has_flag(icmp, FL_SAMESIGN))) && sc_have_same_sign(s, x) {
        iv_set_pred(icmp, sc_pred_unsigned(orig));
        insts[inst_of(icmp)].flags |= FL_SAMESIGN;
        si_changed = true;
    }
}

// eliminateSDiv(SDiv)
fn si_eliminate_sdiv(sdiv: i32) -> bool {
    var n = sc_get_scev(op(sdiv, 0));
    var d = sc_get_scev(op(sdiv, 1));
    let l = li_loop_for(inst_parent(sdiv));
    n = sc_get_scev_at_scope(n, l);
    d = sc_get_scev_at_scope(d, l);
    if sc_is_known_non_negative(n) && sc_is_known_non_negative(d) {
        let nm = iv_name_plus(sdiv, ".udiv");
        let ud = iv_binop_before(OP_UDIV, op(sdiv, 0), op(sdiv, 1), nm, sdiv);
        iv_set_exact(ud, has_flag(sdiv, FL_EXACT));
        rauw(sdiv, ud);
        let dl = inst_get_md(sdiv, 0);
        if dl >= 0 { inst_set_md(ud, 0, dl); }
        si_changed = true;
        iv_dead_push(sdiv);
        return true;
    }
    return false;
}

// replaceSRemWithURem
fn si_replace_srem_with_urem(rem: i32) {
    let nm = iv_name_plus(rem, ".urem");
    let ur = iv_binop_before(OP_UREM, op(rem, 0), op(rem, 1), nm, rem);
    rauw(rem, ur);
    let dl = inst_get_md(rem, 0);
    if dl >= 0 { inst_set_md(ur, 0, dl); }
    si_changed = true;
    iv_dead_push(rem);
}
// replaceRemWithNumerator
fn si_replace_rem_with_numerator(rem: i32) {
    rauw(rem, op(rem, 0));
    si_changed = true;
    iv_dead_push(rem);
}
// replaceRemWithNumeratorOrZero
fn si_replace_rem_with_numerator_or_zero(rem: i32) {
    let t = vals[rem].ty;
    let n = op(rem, 0);
    let d = op(rem, 1);
    let ic = create_inst(OP_ICMP, cmp_result_ty(vals[n].ty), [n, d]);
    insts[inst_of(ic)].pred = P_EQ as u8;
    inst_insert_before(ic, rem);
    let dl = inst_get_md(rem, 0);
    if dl >= 0 { inst_set_md(ic, 0, dl); }
    let sel = create_inst(OP_SELECT, t, [ic, c_int_ty(t, 0), n]);
    inst_insert_before(sel, rem);
    set_name(sel, "iv.rem");
    rauw(rem, sel);
    if dl >= 0 { inst_set_md(sel, 0, dl); }
    si_changed = true;
    iv_dead_push(rem);
}

// simplifyIVRemainder(Rem, IVOperand, IsSigned)
fn si_simplify_iv_remainder(rem: i32, ivop: i32, signed: bool) {
    let nv = op(rem, 0);
    let dv = op(rem, 1);
    let as_num = ivop == nv;
    if !as_num && !signed { return; }
    var n = sc_get_scev(nv);
    let il = li_loop_for(inst_parent(rem));
    n = sc_get_scev_at_scope(n, il);
    let nonneg = !signed || sc_is_known_non_negative(n);
    if !nonneg { return; }
    var d = sc_get_scev(dv);
    d = sc_get_scev_at_scope(d, il);
    if as_num {
        let lt = if signed { P_SLT } else { P_ULT };
        if sc_is_known_predicate(lt, n, d) { si_replace_rem_with_numerator(rem); return; }
        let nl1 = sc_minus(n, sc_get_one(vals[rem].ty));
        if sc_is_known_predicate(lt, nl1, d) { si_replace_rem_with_numerator_or_zero(rem); return; }
    }
    if !signed || !sc_is_known_non_negative(d) { return; }
    si_replace_srem_with_urem(rem);
}

// eliminateOverflowIntrinsic(WO)
fn si_eliminate_overflow_intrinsic(wo: i32) -> bool {
    let bop, signed = iv_with_overflow(wo);
    let lhs = sc_get_scev(cb_arg(wo, 0));
    let rhs = sc_get_scev(cb_arg(wo, 1));
    if !sc_will_not_overflow(bop, signed, lhs, rhs, -1) { return false; }
    let nr = iv_binop_before(bop, cb_arg(wo, 0), cb_arg(wo, 1), "", wo);
    if signed { iv_set_nsw(nr, true); } else { iv_set_nuw(nr, true); }
    var todel: i32[>..<] = [];
    var u = vals[wo].first_use;
    while u >= 0 {
        let ev = uses[u].user;
        u = uses[u].next;
        if is_inst(ev) && iop(ev) == OP_EXTRACTVALUE {
            let x = insts[inst_of(ev)];
            if ints[x.aux] == 1 {
                rauw(ev, c_false());
            } else {
                rauw(ev, nr);
                let dl = inst_get_md(ev, 0);
                if dl >= 0 { inst_set_md(nr, 0, dl); } else { inst_erase_md(nr, 0); }
            }
            todel.push(ev);
        }
    }
    for ev in todel { inst_erase_from_parent(ev); }
    if vals[wo].first_use < 0 { inst_erase_from_parent(wo); }
    si_changed = true;
    return true;
}

// eliminateSaturatingIntrinsic(SI)
fn si_eliminate_saturating_intrinsic(si: i32) -> bool {
    let bop, signed = iv_saturating(si);
    let lhs = sc_get_scev(cb_arg(si, 0));
    let rhs = sc_get_scev(cb_arg(si, 1));
    if !sc_will_not_overflow(bop, signed, lhs, rhs, -1) { return false; }
    var nm: u8[>..] = [];
    nm.append(val_name(si));
    let bo = iv_binop_before(bop, cb_arg(si, 0), cb_arg(si, 1), nm, si);
    if signed { iv_set_nsw(bo, true); } else { iv_set_nuw(bo, true); }
    rauw(si, bo);
    let dl = inst_get_md(si, 0);
    if dl >= 0 { inst_set_md(bo, 0, dl); }
    iv_dead_push(si);
    si_changed = true;
    return true;
}

// eliminateTrunc(TI)
fn si_eliminate_trunc(ti: i32) -> bool {
    let iv = op(ti, 0);
    let ivty = vals[iv].ty;
    let ivs = sc_get_scev(iv);
    let tis = sc_get_scev(ti);
    var sext_c = false;
    var zext_c = false;
    if ivs == sc_get_sign_extend(tis, ivty, 0) { sext_c = true; }
    if ivs == sc_get_zero_extend(tis, ivty, 0) { zext_c = true; }
    if !sext_c && !zext_c { return false; }
    var icmps: i32[>..<] = [];
    var u = vals[ti].first_use;
    while u >= 0 {
        let user = uses[u].user;
        u = uses[u].next;
        if is_inst(user) && !dt_has_node(DT_DOM, inst_parent(user)) { continue; }
        if !iv_is_icmp(user) { return false; }
        if !(op(user, 0) == ti && sx_loop_invariant_v(si_l, op(user, 1))) &&
           !(op(user, 1) == ti && sx_loop_invariant_v(si_l, op(user, 0))) { return false; }
        let up = insts[inst_of(user)].pred as i64;
        if sc_pred_is_signed(up) && !sext_c { return false; }
        if sc_pred_is_unsigned(up) && !zext_c { return false; }
        icmps.push(user);
    }
    for ici in icmps {
        let swapped = sx_loop_invariant_v(si_l, op(ici, 0));
        let op1 = if swapped { op(ici, 0) } else { op(ici, 1) };
        ib_set(ici);
        var ext: i32 = -1;
        var p = insts[inst_of(ici)].pred as i64;
        if swapped { p = sc_swapped_pred(p); }
        // CanUseZExt(ICI)
        var can_zext = false;
        let ip = insts[inst_of(ici)].pred as i64;
        if sc_pred_is_unsigned(ip) { can_zext = true; }
        else if !zext_c { can_zext = false; }
        else if sc_pred_is_equality(ip) { can_zext = true; }
        else {
            let a = sc_get_scev(op(ici, 0));
            let b = sc_get_scev(op(ici, 1));
            can_zext = sc_is_known_non_negative(a) && sc_is_known_non_negative(b);
        }
        if can_zext {
            ext = ib_cast(OP_ZEXT, op1, ivty, "zext");
            p = sc_pred_unsigned(p);
        } else {
            ext = ib_cast(OP_SEXT, op1, ivty, "sext");
        }
        var ch = false;
        make_loop_invariant(si_l, ext, -1, ch);
        let nc = ib_icmp(p, iv, ext, "");
        rauw(ici, nc);
        iv_dead_push(ici);
    }
    rauw(ti, c_poison(vals[ti].ty));
    iv_dead_push(ti);
    return true;
}

// eliminateIVUser(UseInst, IVOperand)
fn si_eliminate_iv_user(use: i32, ivop: i32) -> bool {
    if iv_is_icmp(use) { si_eliminate_iv_comparison(use, ivop); return true; }
    if iv_is_binop(use) {
        let o = iop(use);
        if o == OP_SREM || o == OP_UREM { si_simplify_iv_remainder(use, ivop, o == OP_SREM); return true; }
        if o == OP_SDIV { return si_eliminate_sdiv(use); }
    }
    let wb, _ws = iv_with_overflow(use);
    if wb >= 0 && si_eliminate_overflow_intrinsic(use) { return true; }
    let sb, _ss = iv_saturating(use);
    if sb >= 0 && si_eliminate_saturating_intrinsic(use) { return true; }
    if iop(use) == OP_TRUNC && si_eliminate_trunc(use) { return true; }
    if si_eliminate_identity_scev(use, ivop) { return true; }
    return false;
}

// replaceIVUserWithLoopInvariant(I)
fn si_replace_iv_user_with_loop_invariant(i: i32) -> bool {
    if !sc_is_scevable(vals[i].ty) { return false; }
    let s = sc_get_scev(i);
    if !sc_is_loop_invariant(s, si_l) { return false; }
    if sx_is_high_cost_expansion([s], si_l, sx_cheap_budget(), i) { return false; }
    let ph = loop_preheader(si_l);
    let ip = if ph >= 0 { block_terminator(ph) } else { i };
    if !sx_is_safe_to_expand_at(s, ip) { return false; }
    let inv = sx_expand_code_for_at(s, vals[i].ty, ip);
    let need_lcssa = !li_replacement_preserves_lcssa(i, inv);
    rauw(i, inv);
    if need_lcssa {
        var wl: i32[>..<] = [];
        wl.push(inv);
        lcssa_se = true;
        form_lcssa_for_instructions(wl);
        lcssa_se = false;
    }
    si_changed = true;
    iv_dead_push(i);
    return true;
}

// replaceFloatIVWithIntegerIV(UseInst): returns the overall Changed flag (as LLVM does)
fn si_replace_float_iv_with_integer_iv(use: i32) -> bool {
    let o = iop(use);
    if o != OP_SITOFP && o != OP_UITOFP { return false; }
    let ivop = op(use, 0);
    let iv = sc_get_scev(ivop);
    var mask_bits: i64 = 0;
    if o == OP_SITOFP { mask_bits = rg_min_signed_bits(sc_get_signed_range(iv)); }
    else { mask_bits = rg_active_bits(sc_get_unsigned_range(iv)); }
    let dest = iv_fp_mantissa_width(vals[use].ty);
    if mask_bits <= dest {
        var users: i32[>..<] = [];
        var u = vals[use].first_use;
        while u >= 0 { users.push(uses[u].user); u = uses[u].next; }
        for ci in users {
            if !is_inst(ci) || !is_cast_op(iop(ci)) { continue; }
            let co = iop(ci);
            if co != OP_FPTOSI && co != OP_FPTOUI { continue; }
            var conv: i32 = -1;
            if vals[ivop].ty != vals[ci].ty {
                ib_set(ci);
                if sc_type_bits(vals[ivop].ty) > sc_type_bits(vals[ci].ty) {
                    let nm = iv_name_plus(ivop, ".trunc");
                    conv = ib_trunc(ivop, vals[ci].ty, nm, false, false);
                } else if co == OP_FPTOUI || o == OP_UITOFP {
                    let nm = iv_name_plus(ivop, ".zext");
                    conv = ib_cast(OP_ZEXT, ivop, vals[ci].ty, nm);
                } else {
                    let nm = iv_name_plus(ivop, ".sext");
                    conv = ib_cast(OP_SEXT, ivop, vals[ci].ty, nm);
                }
            } else { conv = ivop; }
            rauw(ci, conv);
            iv_dead_push(ci);
            si_changed = true;
        }
    }
    return si_changed;
}

// eliminateIdentitySCEV(UseInst, IVOperand)
fn si_eliminate_identity_scev(use: i32, ivop: i32) -> bool {
    if !sc_is_scevable(vals[use].ty) || vals[use].ty != vals[ivop].ty { return false; }
    let us = sc_get_scev(use);
    if us != sc_get_scev(ivop) { return false; }
    if iop(use) == OP_PHI {
        if !dt_value_dominates_inst(ivop, use) { return false; }
    }
    if !li_replacement_preserves_lcssa(use, ivop) { return false; }
    if !implies_poison(ivop, use) {
        var drop: i32[>..<] = [];
        if !sc_can_reuse_instruction(us, ivop, drop) { return false; }
        for d in drop { drop_poison_generating_annotations(d); }
    }
    sc_forget_value(use);
    rauw(use, ivop);
    si_changed = true;
    iv_dead_push(use);
    return true;
}

// strengthenOverflowingOperation(BO, IVOperand)
fn si_strengthen_overflowing_operation(bo: i32) -> bool {
    let ok, f = sc_get_strengthened_no_wrap_flags_from_binop(bo);
    if !ok { return false; }
    iv_set_nuw(bo, (f & SF_NUW) != 0);
    iv_set_nsw(bo, (f & SF_NSW) != 0);
    return true;
}
// strengthenRightShift(BO, IVOperand)
fn si_strengthen_right_shift(bo: i32, ivop: i32) -> bool {
    if iop(bo) != OP_SHL { return false; }
    var changed = false;
    let r = sc_get_unsigned_range(sc_get_scev(ivop));
    var u = vals[bo].first_use;
    while u >= 0 {
        let user = uses[u].user;
        u = uses[u].next;
        if !is_inst(user) { continue; }
        let uo = iop(user);
        if uo != OP_ASHR && uo != OP_LSHR { continue; }
        let sh = op(user, 0);
        if !is_inst(sh) || iop(sh) != OP_SHL || op(sh, 1) != ivop { continue; }
        let c = op(user, 1);
        if !is_cint(c) { continue; }
        if !has_flag(user, FL_EXACT) && ap_uge(rg_umin(r), ci_ap(c)) {
            iv_set_exact(user, true);
            changed = true;
        }
    }
    return changed;
}
// strengthenBinaryOp(BO, IVOperand)
fn si_strengthen_binary_op(bo: i32, ivop: i32) -> bool {
    return (iv_is_obo(bo) && si_strengthen_overflowing_operation(bo)) || (iop(bo) == OP_SHL && si_strengthen_right_shift(bo, ivop));
}

// pushIVUsers(Def, Simplified, SimpleIVUsers): pairs (user, def) on `wl`
fn si_push_iv_users(def: i32, simplified: HMap&, wl: i64[>..<]&) {
    var u = vals[def].first_use;
    while u >= 0 {
        let ui = uses[u].user;
        u = uses[u].next;
        if ui == def { continue; }
        if !loop_contains(si_l, inst_parent(ui)) { continue; }
        if hm_has(simplified, ui as u64) { continue; }
        hm_put(simplified, ui as u64, 1);
        wl.push(((ui as i64) << 32) | ((def as i64) & 0xFFFFFFFF));
    }
}

// isSimpleIVUser(I, L, SE)
fn si_is_simple_iv_user(i: i32) -> bool {
    if !sc_is_scevable(vals[i].ty) { return false; }
    let s = sc_get_scev(i);
    return sc_is_addrec(s) && sc_loop(s) == si_l;
}

// IndVarSimplify.cpp visitIVCast(Cast, WI, SE, TTI)
fn iv_visit_iv_cast(cast: i32) {
    let o = iop(cast);
    let signed = o == OP_SEXT;
    if !signed && o != OP_ZEXT { return; }
    let ty = vals[cast].ty;
    let width = sc_type_bits(ty);
    if !dl_is_legal_integer(width) { return; }
    let nw = sc_type_bits(vals[wi_narrow].ty);
    if nw >= width { return; }
    if tti_arith_cost(OP_ADD, ty, TCK_RECIP_THROUGHPUT, []) > tti_arith_cost(OP_ADD, vals[op(cast, 0)].ty, TCK_RECIP_THROUGHPUT, []) { return; }
    if wi_widest < 0 || width > sc_type_bits(wi_widest) {
        wi_widest = sc_effective_ty(ty);
        wi_signed = signed;
        return;
    }
    wi_signed = wi_signed || signed;
}

// simplifyUsers(CurrIV, V)
fn si_simplify_users(cur: i32) {
    if !sc_is_scevable(vals[cur].ty) { return; }
    var simplified = hm_new();
    var wl: i64[>..<] = [];
    si_push_iv_users(cur, simplified, wl);
    while wl.len > 0 {
        let pr = wl.pop();
        let use = (pr >> 32) as i32;
        let oper = (pr & 0xFFFFFFFF) as i32;
        if is_trivially_dead_without_tli(use) { iv_dead_push(use); continue; }
        if use == cur { continue; }
        if si_replace_iv_user_with_loop_invariant(use) { continue; }
        if iop(use) == OP_PTRTOINT || iop(use) == OP_TRUNC {
            var users: i32[>..<] = [];
            var u = vals[use].first_use;
            while u >= 0 { users.push(uses[u].user); u = uses[u].next; }
            for user in users { if si_replace_iv_user_with_loop_invariant(user) { break; } }
        }
        var ivop = oper;
        while ivop >= 0 {
            let nop = si_fold_iv_user(use, ivop);
            if nop < 0 { break; }
            ivop = if is_inst(nop) { nop } else { -1 };
        }
        if ivop < 0 { continue; }
        if si_eliminate_iv_user(use, ivop) { si_push_iv_users(ivop, simplified, wl); continue; }
        if iv_is_binop(use) {
            if si_strengthen_binary_op(use, ivop) { si_push_iv_users(ivop, simplified, wl); }
        }
        if si_replace_float_iv_with_integer_iv(use) { si_push_iv_users(ivop, simplified, wl); continue; }
        if si_visitor && is_cast_op(iop(use)) { iv_visit_iv_cast(use); continue; }
        if si_is_simple_iv_user(use) { si_push_iv_users(use, simplified, wl); }
    }
}

// simplifyUsersOfIV(CurrIV, SE, DT, LI, TTI, Dead, Rewriter, V): (changed, run unswitching)
fn simplify_users_of_iv(cur: i32, with_visitor: bool) -> bool, bool {
    si_l = li_loop_for(inst_parent(cur));
    si_changed = false;
    si_unswitch = false;
    si_visitor = with_visitor;
    si_simplify_users(cur);
    return si_changed, si_unswitch;
}

// ---------------------------------------------------------------------------------------------
// WidenIV

let EK_ZERO: i64 = 0;
let EK_SIGN: i64 = 1;
let EK_UNKNOWN: i64 = 2;

struct NDU { def: i32, use: i32, wide: i32, nonneg: bool }

var wv_orig: i32 = -1;          // OrigPhi
var wv_ty: i32 = -1;            // WideType
var wv_l: i32 = -1;
var wv_has_guards: bool = false;
var wv_post_inc_ranges: bool = true;
var wv_phi: i32 = -1;           // WidePhi
var wv_inc: i32 = -1;           // WideInc
var wv_inc_expr: i32 = -1;      // WideIncExpr
var wv_ek = hm_new();           // ExtendKindMap
var wv_widened = hm_new();      // Widened
var wv_pir = hm_new();          // PostIncRangeInfos: (def, user) -> index in wv_pir_ranges
var wv_pir_ranges: CRange[>..<];
var wv_users: NDU[>..<];        // NarrowIVUsers

fn wv_get_ek(i: i32) -> i64 {
    let k = hm_get(wv_ek, i as u64, -1);
    if k < 0 { fatal("internal: WidenIV: instruction not yet extended"); }
    return k;
}

// getInsertPointForUses(User, Def, DT, LI)
fn wv_insert_point_for_uses(user: i32, def: i32) -> i32 {
    if iop(user) != OP_PHI { return user; }
    var ip: i32 = -1;
    for i in nops(user) {
        if phi_value(user, i) != def { continue; }
        var ibb = phi_block(user, i);
        if !dt_has_node(DT_DOM, ibb) { continue; }
        if ip < 0 { ip = block_terminator(ibb); continue; }
        ibb = dt_find_ncd(DT_DOM, inst_parent(ip), ibb);
        ip = block_terminator(ibb);
    }
    if ip < 0 { return -1; }
    if !is_inst(def) { return ip; }
    let l = li_loop_for(inst_parent(def));
    var b = inst_parent(ip);
    while b >= 0 {
        if li_loop_for(b) == l { return block_terminator(b); }
        b = dt_idom(DT_DOM, b);
    }
    fatal("DefI dominates InsertPt!");
    return -1;
}

// createExtendInst(NarrowOper, WideType, IsSigned, Use)
fn wv_create_extend_inst(narrow: i32, wty: i32, signed: bool, use: i32) -> i32 {
    ib_set(use);
    var l = li_loop_for(inst_parent(use));
    while l >= 0 && loop_preheader(l) >= 0 && sx_loop_invariant_v(l, narrow) {
        ib_set(block_terminator(loop_preheader(l)));
        l = loop_parent(l);
    }
    return ib_cast(if signed { OP_SEXT } else { OP_ZEXT }, narrow, wty, "");
}

// getSCEVByOpCode
fn wv_scev_by_opcode(l: i32, r: i32, o: i64) -> i32 {
    if o == OP_ADD { return sc_add(l, r); }
    if o == OP_SUB { return sc_minus(l, r); }
    if o == OP_MUL { return sc_mul(l, r); }
    if o == OP_UDIV { return sc_get_udiv(l, r); }
    fatal("Unsupported opcode.");
    return -1;
}

// cloneBitwiseIVUser(DU)
fn wv_clone_bitwise(du: NDU) -> i32 {
    let signed = wv_get_ek(du.def) == EK_SIGN;
    let lhs = if op(du.use, 0) == du.def { du.wide } else { wv_create_extend_inst(op(du.use, 0), wv_ty, signed, du.use) };
    let rhs = if op(du.use, 1) == du.def { du.wide } else { wv_create_extend_inst(op(du.use, 1), wv_ty, signed, du.use) };
    let bo = iv_insert_clone_binop(iop(du.use), lhs, rhs, du.use, du.use);
    iv_copy_ir_flags(bo, du.use);
    return bo;
}

// cloneArithmeticIVUser(DU, WideAR)
fn wv_clone_arith(du: NDU, wide_ar: i32) -> i32 {
    let ividx: i64 = if op(du.use, 0) == du.def { 0 } else { 1 };
    var signed = wv_get_ek(du.def) == EK_SIGN;
    if !wv_guess_non_iv_operand(du, ividx, signed, wide_ar) {
        signed = !signed;
        if !wv_guess_non_iv_operand(du, ividx, signed, wide_ar) { return -1; }
    }
    let lhs = if op(du.use, 0) == du.def { du.wide } else { wv_create_extend_inst(op(du.use, 0), wv_ty, signed, du.use) };
    let rhs = if op(du.use, 1) == du.def { du.wide } else { wv_create_extend_inst(op(du.use, 1), wv_ty, signed, du.use) };
    let bo = iv_insert_clone_binop(iop(du.use), lhs, rhs, du.use, du.use);
    iv_copy_ir_flags(bo, du.use);
    return bo;
}
// GuessNonIVOperand(SignExt)
fn wv_guess_non_iv_operand(du: NDU, ividx: i64, sext: bool, wide_ar: i32) -> bool {
    var wl: i32 = -1;
    var wr: i32 = -1;
    if ividx == 0 {
        wl = sc_get_scev(du.wide);
        let nr = sc_get_scev(op(du.use, 1));
        wr = if sext { sc_get_sign_extend(nr, wv_ty, 0) } else { sc_get_zero_extend(nr, wv_ty, 0) };
    } else {
        let nl = sc_get_scev(op(du.use, 0));
        wl = if sext { sc_get_sign_extend(nl, wv_ty, 0) } else { sc_get_zero_extend(nl, wv_ty, 0) };
        wr = sc_get_scev(du.wide);
    }
    return wv_scev_by_opcode(wl, wr, iop(du.use)) == wide_ar;
}

// cloneIVUser(DU, WideAR)
fn wv_clone_iv_user(du: NDU, wide_ar: i32) -> i32 {
    let o = iop(du.use);
    if o == OP_ADD || o == OP_MUL || o == OP_UDIV || o == OP_SUB { return wv_clone_arith(du, wide_ar); }
    if o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_SHL || o == OP_LSHR || o == OP_ASHR { return wv_clone_bitwise(du); }
    return -1;
}

// matchBinaryOp(Op): (opcode or -1, lhs, rhs, nsw, nuw)
fn wv_match_binary_op(i: i32) -> i64, i32, i32, bool, bool {
    let o = iop(i);
    if o == OP_ADD || o == OP_SUB || o == OP_MUL { return o, op(i, 0), op(i, 1), op_nsw(i), op_nuw(i); }
    if o == OP_OR {
        if op_disjoint(i) { return OP_ADD, op(i, 0), op(i, 1), true, true; }
        return -1, -1, -1, false, false;
    }
    if o == OP_SHL {
        let sa = op(i, 1);
        if is_cint(sa) {
            let bw = ty_bits(vals[sa].ty);
            let a = ci_ap(sa);
            if ap_ult_u64(a, bw as u64) {
                let nuw = op_nuw(i);
                let nsw = op_nsw(i) && (nuw || ap_ult_u64(a, (bw - 1) as u64));
                let x = ap_to_cint(vals[sa].ty, ap_one_bit(bw, ap_lo64(a) as i64));
                return OP_MUL, op(i, 0), x, nsw, nuw;
            }
        }
    }
    return -1, -1, -1, false, false;
}

// getExtendedOperandRecurrence(DU): (AddRec or -1, ExtendKind)
fn wv_extended_operand_recurrence(du: NDU) -> i32, i64 {
    let o, a0, a1, nsw, nuw = wv_match_binary_op(du.use);
    if o < 0 { return -1, EK_UNKNOWN; }
    let ext_idx: i64 = if a0 == du.def { 1 } else { 0 };
    var ek = wv_get_ek(du.def);
    if !(ek == EK_SIGN && nsw) && !(ek == EK_ZERO && nuw) {
        ek = EK_UNKNOWN;
        if du.nonneg {
            if nsw { ek = EK_SIGN; } else if nuw { ek = EK_ZERO; }
        }
    }
    var ext = sc_get_scev(if ext_idx == 0 { a0 } else { a1 });
    if ek == EK_SIGN { ext = sc_get_sign_extend(ext, wv_ty, 0); }
    else if ek == EK_ZERO { ext = sc_get_zero_extend(ext, wv_ty, 0); }
    else { return -1, EK_UNKNOWN; }
    var lhs = sc_get_scev(du.wide);
    var rhs = ext;
    if ext_idx == 0 { let t = lhs; lhs = rhs; rhs = t; }
    let ar = wv_scev_by_opcode(lhs, rhs, o);
    if !sc_is_addrec(ar) || sc_loop(ar) != wv_l { return -1, EK_UNKNOWN; }
    return ar, ek;
}

// getWideRecurrence(DU)
fn wv_wide_recurrence(du: NDU) -> i32, i64 {
    if !ty_is_int(vals[du.use].ty) { return -1, EK_UNKNOWN; }
    let ne = sc_get_scev(du.use);
    if sc_bits(ne) >= sc_type_bits(wv_ty) { return -1, EK_UNKNOWN; }
    var we: i32 = -1;
    var ek = EK_UNKNOWN;
    if du.nonneg {
        we = sc_get_sign_extend(ne, wv_ty, 0);
        if sc_is_addrec(we) { ek = EK_SIGN; }
        else { we = sc_get_zero_extend(ne, wv_ty, 0); ek = EK_ZERO; }
    } else if wv_get_ek(du.def) == EK_SIGN {
        we = sc_get_sign_extend(ne, wv_ty, 0);
        ek = EK_SIGN;
    } else {
        we = sc_get_zero_extend(ne, wv_ty, 0);
        ek = EK_ZERO;
    }
    if !sc_is_addrec(we) || sc_loop(we) != wv_l { return -1, EK_UNKNOWN; }
    return we, ek;
}

// Instruction::replaceUsesOfWith(From, To)
fn wv_replace_uses_of_with(i: i32, from: i32, to: i32) {
    for k in nops(i) { if op(i, k) == from { set_op(i, k, to); } }
}

// truncateIVUse(DU)
fn wv_truncate_iv_use(du: NDU) {
    let ip = wv_insert_point_for_uses(du.use, du.def);
    if ip < 0 { return; }
    let ek = wv_get_ek(du.def);
    ib_set(ip);
    let tr = ib_trunc(du.wide, vals[du.def].ty, "", du.nonneg || ek == EK_ZERO, du.nonneg || ek == EK_SIGN);
    wv_replace_uses_of_with(du.use, du.def, tr);
}

// widenLoopCompare(DU)
fn wv_widen_loop_compare(du: NDU) -> bool {
    let cmp = du.use;
    if !iv_is_icmp(cmp) { return false; }
    let signed = wv_get_ek(du.def) == EK_SIGN;
    let cp = insts[inst_of(cmp)].pred as i64;
    var pref_signed = if has_flag(cmp, FL_SAMESIGN) { signed } else { sc_pred_is_signed(cp) };
    if !du.nonneg && signed != pref_signed { return false; }
    let o = op(cmp, if op(cmp, 0) == du.def { 1 } else { 0 });
    let cw = sc_type_bits(vals[o].ty);
    let ivw = sc_type_bits(wv_ty);
    wv_replace_uses_of_with(du.use, du.def, du.wide);
    if cw < ivw {
        if du.nonneg && is_inst(o) && iop(o) == OP_SEXT && !sc_pred_is_signed(cp) { pref_signed = true; }
        let ext = wv_create_extend_inst(o, wv_ty, pref_signed, cmp);
        wv_replace_uses_of_with(du.use, o, ext);
    }
    return true;
}

// widenWithVariantUse(DU)
fn wv_widen_with_variant_use(du: NDU) -> bool {
    let nu = du.use;
    let nd = du.def;
    let wd = du.wide;
    let o = iop(nu);
    if o != OP_ADD && o != OP_SUB && o != OP_MUL { return false; }
    let ek = wv_get_ek(nd);
    let can_sext = ek == EK_SIGN && op_nsw(nu);
    let can_zext = ek == EK_ZERO && op_nuw(nu);
    var other_ek = ek;
    var ext_users: i32[>..<] = [];
    var lcssa_users: i32[>..<] = [];
    var icmp_users: i32[>..<] = [];
    var u = vals[nu].first_use;
    while u >= 0 {
        let user = uses[u].user;
        u = uses[u].next;
        if user == nd { continue; }
        if !loop_contains(wv_l, inst_parent(user)) {
            if iop(user) != OP_PHI { fatal("internal: widenWithVariantUse: a non-PHI user outside the loop"); }
            if nops(user) != 1 { return false; }
            lcssa_users.push(user);
            continue;
        }
        if iv_is_icmp(user) {
            let p = insts[inst_of(user)].pred as i64;
            if ek == EK_ZERO && sc_pred_is_signed(p) { return false; }
            if ek == EK_SIGN && sc_pred_is_unsigned(p) { return false; }
            icmp_users.push(user);
            continue;
        }
        let want = if ek == EK_SIGN { OP_SEXT } else { OP_ZEXT };
        if !is_inst(user) || iop(user) != want || vals[user].ty != wv_ty { return false; }
        ext_users.push(user);
    }
    if ext_users.len == 0 { iv_dead_push(nu); return true; }
    let cx = iv_find_common_dominator(ext_users);
    if !can_sext && !can_zext {
        if o != OP_ADD { return false; }
        if ek != EK_ZERO { return false; }
        let lhs = sc_get_scev(op(nu, 0));
        let rhs = sc_get_scev(op(nu, 1));
        if op(nu, 0) != nd { return false; }
        if op(nu, 1) == nd { return false; }
        if !sc_is_known_negative(rhs) { return false; }
        if !sc_is_known_predicate_at(P_UGE, lhs, sc_get_negative(rhs, SF_ANY), cx) { return false; }
        other_ek = EK_SIGN;
    }
    let op1 = sc_get_scev(wd);
    if !sc_is_addrec(op1) || sc_loop(op1) != wv_l { return false; }
    let lhs = if op(nu, 0) == nd { wd } else { wv_create_extend_inst(op(nu, 0), wv_ty, other_ek == EK_SIGN, nu) };
    let rhs = if op(nu, 1) == nd { wd } else { wv_create_extend_inst(op(nu, 1), wv_ty, other_ek == EK_SIGN, nu) };
    let wbo = iv_insert_clone_binop(o, lhs, rhs, nu, nu);
    iv_copy_ir_flags(wbo, nu);
    hm_put(wv_ek, nu as u64, ek);
    for user in ext_users {
        rauw(user, wbo);
        iv_dead_push(user);
    }
    for user in lcssa_users {
        ib_set(user);
        let nm = iv_name_plus(user, ".wide");
        let wpn = ib_phi(vals[wbo].ty, 1, nm);
        let exiting = single_pred(inst_parent(user));
        phi_add_incoming(wpn, wbo, exiting);
        let fi = sx_first_insertion_pt(inst_parent(user));
        ib_set_it(inst_parent(user), fi.pos, true);
        let tpn = ib_trunc(wpn, vals[user].ty, "", false, false);
        rauw(user, tpn);
        iv_dead_push(user);
    }
    for user in icmp_users {
        ib_set(user);
        let p = insts[inst_of(user)].pred as i64;
        let el = wv_extended_op(op(user, 0), nu, wbo, ek);
        let er = wv_extended_op(op(user, 1), nu, wbo, ek);
        let nm = iv_name_plus(user, ".wide");
        let wc = ib_icmp(p, el, er, nm);
        rauw(user, wc);
        iv_dead_push(user);
    }
    return true;
}
// widenWithVariantUse's ExtendedOp
fn wv_extended_op(v: i32, nu: i32, wbo: i32, ek: i64) -> i32 {
    if v == nu { return wbo; }
    if ek == EK_ZERO { return ib_cast(OP_ZEXT, v, vals[wbo].ty, ""); }
    return ib_cast(OP_SEXT, v, vals[wbo].ty, "");
}

// m_SExtLike(m_Value()): sext, or zext nneg
fn wv_is_sext_like(i: i32) -> bool { iop(i) == OP_SEXT || (iop(i) == OP_ZEXT && has_flag(i, FL_NNEG)) }

// widenIVUse(DU, Rewriter, OrigPhi, WidePhi): the wide use to follow, or -1
fn wv_widen_iv_use(du: NDU) -> i32 {
    let can_sext = du.nonneg || wv_get_ek(du.def) == EK_SIGN;
    let can_zext = du.nonneg || wv_get_ek(du.def) == EK_ZERO;
    if iop(du.use) == OP_PHI {
        let up = du.use;
        if li_loop_for(inst_parent(up)) != wv_l {
            if nops(up) != 1 { wv_truncate_iv_use(du); }
            else {
                let t = block_terminator(inst_parent(up));
                if t >= 0 && iop(t) == OP_CATCHSWITCH { return -1; }
                let nm = iv_name_plus(up, ".wide");
                let wpn = new_inst(OP_PHI, vals[du.wide].ty, 1);
                vals[wpn].nops = 0;
                inst_insert_before(wpn, up);
                set_name(wpn, nm);
                phi_add_incoming(wpn, du.wide, phi_block(up, 0));
                let wbb = inst_parent(wpn);
                let fi = sx_first_insertion_pt(wbb);
                ib_set_it(wbb, fi.pos, true);
                let tr = ib_trunc(wpn, vals[du.def].ty, "", can_zext, can_sext);
                rauw(up, tr);
                iv_dead_push(up);
            }
            return -1;
        }
    }
    if (wv_is_sext_like(du.use) && can_sext) || (iop(du.use) == OP_ZEXT && can_zext) {
        var nd = du.wide;
        if vals[du.use].ty != wv_ty {
            let cw = sc_type_bits(vals[du.use].ty);
            let ivw = sc_type_bits(wv_ty);
            if cw < ivw {
                ib_set(du.use);
                nd = ib_trunc(du.wide, vals[du.use].ty, "", can_zext, can_sext);
            } else {
                wv_replace_uses_of_with(du.use, du.def, du.wide);
                nd = du.use;
            }
        }
        if nd != du.use {
            rauw(du.use, nd);
            iv_dead_push(du.use);
        }
        return -1;
    }
    // tryAddRecExpansion
    var war, wek = wv_extended_operand_recurrence(du);
    if war < 0 {
        let a, b = wv_wide_recurrence(du);
        war = a;
        wek = b;
    }
    if war >= 0 {
        var wide_use: i32 = -1;
        var reuse = false;
        if wv_inc >= 0 {
            let need = !sx_can_reuse_flags_from_original_iv_inc(wv_orig, wv_phi, du.use, wv_inc) ||
                       op_nuw(du.use) != op_nuw(wv_inc) || op_nsw(du.use) != op_nsw(wv_inc);
            reuse = war == wv_inc_expr && sx_hoist_iv_inc(wv_inc, du.use, need);
        }
        if reuse { wide_use = wv_inc; }
        else {
            wide_use = wv_clone_iv_user(du, war);
        }
        if wide_use >= 0 {
            if war != sc_get_scev(wide_use) {
                iv_dead_push(wide_use);
                return -1;
            }
            replace_all_dbg_uses_with(du.use, wide_use, wide_use);
            hm_put(wv_ek, du.use as u64, wek);
            return wide_use;
        }
    }
    if wv_widen_loop_compare(du) { return -1; }
    if wv_widen_with_variant_use(du) { return -1; }
    wv_truncate_iv_use(du);
    return -1;
}

// pushNarrowIVUsers(NarrowDef, WideDef)
fn wv_push_narrow_iv_users(nd: i32, wd: i32) {
    let ns = sc_get_scev(nd);
    let nonneg_def = sc_is_known_predicate(P_SGE, ns, sc_get_zero(sc_ty(ns)));
    var u = vals[nd].first_use;
    while u >= 0 {
        let nu = uses[u].user;
        u = uses[u].next;
        if hm_has(wv_widened, nu as u64) { continue; }
        hm_put(wv_widened, nu as u64, 1);
        var nonneg_use = false;
        if !nonneg_def {
            let ri = hm_get(wv_pir, hk2(nd, nu), -1);
            if ri >= 0 { nonneg_use = ap_is_nonneg(rg_smin(wv_pir_ranges[ri])); }
        }
        wv_users.push(NDU { def: nd, use: nu, wide: wd, nonneg: nonneg_def || nonneg_use });
    }
}

// updatePostIncRangeInfo(Def, UseI, R)
fn wv_update_post_inc_range_info(def: i32, use: i32, r: CRange) {
    let k = hk2(def, use);
    let ri = hm_get(wv_pir, k, -1);
    if ri < 0 { hm_put(wv_pir, k, wv_pir_ranges.len); wv_pir_ranges.push(r); return; }
    wv_pir_ranges[ri] = rg_intersect(r, wv_pir_ranges[ri]);
}

// calculatePostIncRange's UpdateRangeFromCondition
fn wv_update_range_from_condition(cond: i32, true_dest: bool, nd: i32, nlhs: i32, nrhs: AP, nu: i32) {
    if !iv_is_icmp(cond) || op(cond, 0) != nlhs { return; }
    let pr = iv_cmp_pred(cond);
    let p = if true_dest { pr } else { cp_inverse(pr) };
    let rr = sc_get_signed_range(sc_get_scev(op(cond, 1)));
    let lr = rg_allowed_icmp(cpp(p), rr);
    let ndr = rg_add_nw(lr, rg_single(nrhs), NW_NSW, RG_SMALLEST);
    wv_update_post_inc_range_info(nd, nu, ndr);
}
// calculatePostIncRange's UpdateRangeFromGuards
fn wv_update_range_from_guards(ctx: i32, nd: i32, nlhs: i32, nrhs: AP, nu: i32) {
    if !wv_has_guards { return; }
    var i = ctx;
    while i >= 0 {
        if inst_iid(i) == IID_experimental_guard { wv_update_range_from_condition(cb_arg(i, 0), true, nd, nlhs, nrhs, nu); }
        i = inst_prev(i);
    }
}
// calculatePostIncRange(NarrowDef, NarrowUser)
fn wv_calculate_post_inc_range(nd: i32, nu: i32) {
    if iop(nd) != OP_ADD || !op_nsw(nd) || !is_cint(op(nd, 1)) { return; }
    let nlhs = op(nd, 0);
    let nrhs = ci_ap(op(nd, 1));
    if !ap_is_nonneg(nrhs) { return; }
    wv_update_range_from_guards(nu, nd, nlhs, nrhs, nu);
    let ubb = inst_parent(nu);
    if !dt_has_node(DT_DOM, ubb) { return; }
    var b = dt_idom(DT_DOM, ubb);
    while loop_contains(wv_l, b) {
        let ti = block_terminator(b);
        wv_update_range_from_guards(ti, nd, nlhs, nrhs, nu);
        if iop(ti) == OP_CONDBR {
            let ts = term_succ(ti, 0);
            let fs = term_succ(ti, 1);
            if dom_edge(b, ts, ubb) { wv_update_range_from_condition(op(ti, 0), true, nd, nlhs, nrhs, nu); }
            if dom_edge(b, fs, ubb) { wv_update_range_from_condition(op(ti, 0), false, nd, nlhs, nrhs, nu); }
        }
        b = dt_idom(DT_DOM, b);
    }
}
// calculatePostIncRanges(OrigPhi)
fn wv_calculate_post_inc_ranges(orig: i32) {
    var visited = hm_new();
    var wl: i32[>..<] = [];
    wl.push(orig);
    hm_put(visited, orig as u64, 1);
    while wl.len > 0 {
        let nd = wl.pop();
        var u = vals[nd].first_use;
        while u >= 0 {
            let nu = uses[u].user;
            u = uses[u].next;
            let nul = li_loop_for(inst_parent(nu));
            if nul < 0 || !loop_contains_loop(wv_l, nul) { continue; }
            if hm_has(visited, nu as u64) { continue; }
            hm_put(visited, nu as u64, 1);
            wl.push(nu);
            wv_calculate_post_inc_range(nd, nu);
        }
    }
}

// WidenIV::createWideIV(Rewriter)
fn wv_create_wide_iv() -> i32 {
    let ar0 = sc_get_scev(wv_orig);
    if !sc_is_addrec(ar0) { return -1; }
    let we = if wv_get_ek(wv_orig) == EK_SIGN { sc_get_sign_extend(ar0, wv_ty, 0) } else { sc_get_zero_extend(ar0, wv_ty, 0) };
    if !sc_is_addrec(we) || sc_loop(we) != wv_l { return -1; }
    if wv_post_inc_ranges { wv_calculate_post_inc_ranges(wv_orig); }
    let fi = sx_first_insertion_pt(loop_header(wv_l));
    let ei = sx_expand_code_for_at(we, wv_ty, fi.pos);
    if !is_inst(ei) || iop(ei) != OP_PHI {
        if vals[ei].first_use < 0 && sx_is_inserted(ei) { iv_dead_push(ei); }
        return -1;
    }
    wv_phi = ei;
    let latch = loop_latch(wv_l);
    if latch >= 0 {
        let wi = sx_phi_in(wv_phi, latch);
        wv_inc = if is_inst(wi) { wi } else { -1 };
        if wv_inc >= 0 {
            wv_inc_expr = sc_get_scev(wv_inc);
            let orig_inc = sx_phi_in(wv_orig, latch);
            let dl = inst_get_md(orig_inc, 0);
            if dl >= 0 { inst_set_md(wv_inc, 0, dl); } else { inst_erase_md(wv_inc, 0); }
            if sx_can_reuse_flags_from_original_iv_inc(wv_orig, wv_phi, orig_inc, wv_inc) && iv_is_obo(orig_inc) && iv_is_obo(wv_inc) {
                iv_set_nuw(wv_inc, op_nuw(wv_inc) || op_nuw(orig_inc));
                iv_set_nsw(wv_inc, op_nsw(wv_inc) || op_nsw(orig_inc));
            }
        }
    }
    hm_put(wv_widened, wv_orig as u64, 1);
    wv_push_narrow_iv_users(wv_orig, wv_phi);
    while wv_users.len > 0 {
        let du = wv_users.pop();
        let wu = wv_widen_iv_use(du);
        if wu >= 0 { wv_push_narrow_iv_users(du.use, wu); }
        if vals[du.def].first_use < 0 { iv_dead_push(du.def); }
    }
    replace_all_dbg_uses_with(wv_orig, wv_phi, wv_phi);
    return wv_phi;
}

// createWideIV(WI, LI, SE, Rewriter, DT, DeadInsts, NumElimExt, NumWidened, HasGuards, UsePostIncrementRanges)
fn create_wide_iv(narrow: i32, widest: i32, signed: bool, has_guards: bool, post_inc_ranges: bool) -> i32 {
    wv_orig = narrow;
    wv_ty = widest;
    wv_l = li_loop_for(inst_parent(narrow));
    wv_has_guards = has_guards;
    wv_post_inc_ranges = post_inc_ranges;
    wv_phi = -1;
    wv_inc = -1;
    wv_inc_expr = -1;
    hm_clear(wv_ek);
    hm_clear(wv_widened);
    hm_clear(wv_pir);
    wv_pir_ranges.clear();
    wv_users.clear();
    hm_put(wv_ek, narrow as u64, if signed { EK_SIGN } else { EK_ZERO });
    return wv_create_wide_iv();
}
