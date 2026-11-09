// SCEVAA (-aa-pipeline=scev-aa): ScalarEvolution-based alias analysis.
// Port of llvm/lib/Analysis/ScalarEvolutionAliasAnalysis.cpp (LLVM 23.1.5): canComputePointerDiff,
// SCEVAAResult::alias, GetBaseValue; and ScalarEvolution::instructionCouldExistWithOperands. The other
// AAResult queries are AAResultBase's (ModRef), so the aggregation only asks it for alias().
import std;
import ir;
import irutil;
import domtree;
import apint;
import constrange;
import memloc;
import scev;
import scev_create;
import scev_range;

// instructionCouldExistWithOperands(A, B)
fn scaa_could_exist_with_operands(a: i32, b: i32) -> bool {
    let sb = ss.len;
    ss.push(a);
    let sa, pa = sc_get_defining_scope_bound2(sb, 1);
    ss.resize(sb);
    ss.push(b);
    let sbb, pb = sc_get_defining_scope_bound2(sb, 1);
    ss.resize(sb);
    if !pa || !pb { return false; }
    return sa == sbb || dt_value_dominates_inst(sa, sbb) || dt_value_dominates_inst(sbb, sa);
}

// GetBaseValue(S): the value, or -1
recursive fn scaa_base_value(s: i32) -> i32 {
    if sc_is_addrec(s) { return scaa_base_value(sc_op(s, 0)); }
    if sc_kind(s) == SC_ADD {
        let last = sc_op(s, sc_nops(s) - 1);
        if sc_is_ptr(last) { return scaa_base_value(last); }
        return -1;
    }
    if sc_is_unknown(s) { return sc_value(s); }
    return -1;
}

// SCEVAAResult::alias(LocA, LocB): true = MayAlias, false = NoAlias / MustAlias via `must`
recursive fn scaa_alias(a: ML, b: ML) -> i64 {
    if ls_is_zero(a.size) || ls_is_zero(b.size) { return 0; }
    var as_ = sc_get_scev(a.ptr);
    var bs = sc_get_scev(b.ptr);
    if as_ == bs { return 3; }
    if sc_effective_ty(sc_ty(as_)) == sc_effective_ty(sc_ty(bs)) && scaa_could_exist_with_operands(as_, bs) {
        let bw = sc_bits(as_);
        let asz = ap_u64(if ls_has_value(a.size) { ls_value(a.size) } else { 0xFFFFFFFFFFFFFFFF }, bw);
        let bsz = ap_u64(if ls_has_value(b.size) { ls_value(b.size) } else { 0xFFFFFFFFFFFFFFFF }, bw);
        let ai = sc_get_ptr_to_int(as_, sc_effective_ty(sc_ty(as_)));
        let bi = sc_get_ptr_to_int(bs, sc_effective_ty(sc_ty(bs)));
        if !sc_is_cnc(ai) && !sc_is_cnc(bi) { as_ = ai; bs = bi; }
        let ba = sc_minus(bs, as_);
        if !sc_is_cnc(ba) && ap_ule(asz, rg_umin(sc_get_unsigned_range(ba))) && ap_uge(ap_neg(bsz), rg_umax(sc_get_unsigned_range(ba))) { return 0; }
        let ab = sc_minus(as_, bs);
        if !sc_is_cnc(ab) && ap_ule(bsz, rg_umin(sc_get_unsigned_range(ab))) && ap_uge(ap_neg(asz), rg_umax(sc_get_unsigned_range(ab))) { return 0; }
    }
    let ao = scaa_base_value(as_);
    let bo = scaa_base_value(bs);
    if (ao >= 0 && ao != a.ptr) || (bo >= 0 && bo != b.ptr) {
        let na = if ao >= 0 { ml_make(ao, LS_BEFORE_OR_AFTER) } else { a };
        let nb = if bo >= 0 { ml_make(bo, LS_BEFORE_OR_AFTER) } else { b };
        if scaa_alias(na, nb) == 0 { return 0; }
    }
    return 1;
}
