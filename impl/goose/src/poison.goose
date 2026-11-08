// Poison/undef analysis: ports of canCreateUndefOrPoison, impliesPoison, directlyImpliesPoison,
// isGuaranteedNotToBeUndefOrPoison (and the PoisonOnly/UndefOnly variants), propagatesPoison,
// intrinsicPropagatesPoison, programUndefinedIfUndefOrPoison (llvm/lib/Analysis/ValueTracking.cpp), and
// Operator::hasPoisonGeneratingFlags / hasPoisonGeneratingAnnotations (llvm/lib/IR/Operator.cpp).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import domtree;
import knownbits;
import pm;
import vt;
import constfold;
import assume;

let UPK_POISON = 1;
let UPK_UNDEF = 2;
let UPK_BOTH = 3;

// Operator::hasPoisonGeneratingFlags
fn has_poison_generating_flags(v: i32) -> bool {
    let o = opcode_of(v);
    if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL { return op_nuw(v) || op_nsw(v); }
    if o == OP_TRUNC { return is_inst(v) && (op_nuw(v) || op_nsw(v)); }
    if o == OP_UDIV || o == OP_SDIV || o == OP_ASHR || o == OP_LSHR { return op_exact(v); }
    if o == OP_OR { return op_disjoint(v); }
    if o == OP_GEP {
        if (op_flags(v) & (GEP_INBOUNDS | GEP_NUSW | GEP_NUW)) != 0 { return true; }
        if vals[v].kind == VK_CEXPR && csts[vals[v].sub].inr >= 0 { return true; }
        return false;
    }
    if o == OP_UITOFP || o == OP_ZEXT { return has_flag(v, FL_NNEG); }
    if o == OP_ICMP { return has_flag(v, FL_SAMESIGN); }
    if o == OP_CALL {
        let id = inst_iid(v);
        if id == IID_ctlz || id == IID_cttz || id == IID_abs { return is_one_value(cb_arg(v, 1)); }
    }
    if is_inst(v) && is_fp_math_operator(v) {
        let f = insts[inst_of(v)].fmf;
        return (f & (FMF_NNAN | FMF_NINF)) != 0;
    }
    return false;
}

fn aset_has_poison_attr(s: i32) -> bool {
    return aset_has(s, AK_Range) || aset_has(s, AK_Alignment) || aset_has(s, AK_NonNull) || aset_has(s, AK_NoFPClass);
}
// Instruction::hasPoisonGeneratingAttributes
fn has_poison_generating_attributes(v: i32) -> bool {
    if !is_callbase(v) { return false; }
    let l = insts[inst_of(v)].attrs;
    if aset_has_poison_attr(alist_ret(l)) { return true; }
    for k in cb_nargs(v) { if aset_has_poison_attr(alist_param(l, k)) { return true; } }
    return false;
}
fn has_poison_generating_metadata(v: i32) -> bool {
    return inst_get_md(v, md_kind_id("range")) >= 0 || inst_get_md(v, md_kind_id("nonnull")) >= 0 ||
           inst_get_md(v, md_kind_id("align")) >= 0 || inst_get_md(v, md_kind_id("nofpclass")) >= 0;
}
fn has_poison_generating_annotations(v: i32) -> bool {
    if has_poison_generating_flags(v) { return true; }
    return is_inst(v) && (has_poison_generating_attributes(v) || has_poison_generating_metadata(v));
}

fn shift_amount_known_in_range(a: i32) -> bool {
    if !is_constant(a) { return false; }
    let t = vals[a].ty;
    if ty_kind(t) == TK_SVEC { return false; }
    if ty_kind(t) == TK_FVEC {
        for i in ty_count(t) {
            let e = agg_elem(a, i);
            if e < 0 || vals[e].kind != VK_CINT { return false; }
            if ap_uge_u64(ci_ap(e), ty_bits(vals[e].ty) as u64) { return false; }
        }
        return true;
    }
    if vals[a].kind != VK_CINT { return false; }
    return ap_ult_u64(ci_ap(a), ty_bits(t) as u64);
}

fn call_has_ret_attr(c: i32, k: i64) -> bool { call_ret_has_attr(c, k) }

// canCreateUndefOrPoison(Op, Kind, ConsiderFlagsAndMetadata)
fn can_create_undef_or_poison_k(v: i32, kind: i64, consider_flags: bool) -> bool {
    let inc_poison = (kind & UPK_POISON) != 0;
    if consider_flags && inc_poison && has_poison_generating_annotations(v) { return true; }
    let o = opcode_of(v);
    if o == OP_SHL || o == OP_ASHR || o == OP_LSHR { return inc_poison && !shift_amount_known_in_range(op(v, 1)); }
    if o == OP_FPTOSI || o == OP_FPTOUI { return true; }
    if o == OP_CALL || o == OP_CALLBR || o == OP_INVOKE {
        if o == OP_CALL {
            let id = call_iid(v);
            if id == IID_ctlz || id == IID_cttz || id == IID_abs { return false; }
            if id == IID_sshl_sat || id == IID_ushl_sat {
                if !inc_poison || shift_amount_known_in_range(cb_arg(v, 1)) { return false; }
            }
        }
        return !call_has_ret_attr(v, AK_NoUndef) && !call_has_fn_attr(v, AK_NoCreateUndefOrPoison);
    }
    if o == OP_INSERTELEMENT || o == OP_EXTRACTELEMENT {
        let vt0 = vals[op(v, 0)].ty;
        let ix = op(v, if o == OP_INSERTELEMENT { 2 } else { 1 });
        let ci = m_constant_int(ix);
        if inc_poison { return ci < 0 || ap_uge_u64(ci_ap(ci), ty_count(vt0) as u64); }
        return false;
    }
    if o == OP_SHUFFLEVECTOR {
        if !inc_poison { return false; }
        var aux: i32 = 0;
        var naux: i32 = 0;
        if is_inst(v) { aux = insts[inst_of(v)].aux; naux = insts[inst_of(v)].naux; }
        else { aux = csts[vals[v].sub].aux; naux = csts[vals[v].sub].naux; }
        for k in naux { if ints[aux + k] < 0 { return true; } }
        return false;
    }
    if o == OP_FNEG || o == OP_PHI || o == OP_SELECT || o == OP_EXTRACTVALUE || o == OP_INSERTVALUE ||
       o == OP_FREEZE || o == OP_ICMP || o == OP_FCMP || o == OP_GEP { return false; }
    if o == OP_ADDRSPACECAST { return true; }
    if is_cast_op(o) { return false; }
    if is_binary_op(o) { return false; }
    return true;
}
fn can_create_undef_or_poison(v: i32, consider_flags: bool) -> bool { can_create_undef_or_poison_k(v, UPK_BOTH, consider_flags) }
fn can_create_poison(v: i32, consider_flags: bool) -> bool { can_create_undef_or_poison_k(v, UPK_POISON, consider_flags) }

// intrinsicPropagatesPoison
fn intrinsic_propagates_poison(id: i32) -> bool {
    return id == IID_sadd_with_overflow || id == IID_ssub_with_overflow || id == IID_smul_with_overflow ||
        id == IID_uadd_with_overflow || id == IID_usub_with_overflow || id == IID_umul_with_overflow ||
        id == IID_ctpop || id == IID_ctlz || id == IID_cttz || id == IID_abs || id == IID_smax || id == IID_smin ||
        id == IID_umax || id == IID_umin || id == IID_scmp || id == IID_is_fpclass || id == IID_ptrmask ||
        id == IID_ucmp || id == IID_bitreverse || id == IID_bswap || id == IID_sadd_sat || id == IID_ssub_sat ||
        id == IID_sshl_sat || id == IID_uadd_sat || id == IID_usub_sat || id == IID_ushl_sat || id == IID_smul_fix ||
        id == IID_smul_fix_sat || id == IID_umul_fix || id == IID_umul_fix_sat || id == IID_pow || id == IID_powi ||
        id == IID_sin || id == IID_sinh || id == IID_cos || id == IID_cosh || id == IID_sincos || id == IID_sincospi ||
        id == IID_tan || id == IID_tanh || id == IID_asin || id == IID_acos || id == IID_atan || id == IID_atan2 ||
        id == IID_canonicalize || id == IID_sqrt || id == IID_exp || id == IID_exp2 || id == IID_exp10 ||
        id == IID_log || id == IID_log2 || id == IID_log10 || id == IID_modf || id == IID_floor || id == IID_ceil ||
        id == IID_trunc || id == IID_rint || id == IID_nearbyint || id == IID_round || id == IID_roundeven ||
        id == IID_lrint || id == IID_llrint || id == IID_fshl || id == IID_fshr || id == IID_frexp ||
        id == IID_get_active_lane_mask;
}

// propagatesPoison(Use): user u, operand number k
fn propagates_poison(u: i32, k: i64) -> bool {
    let o = opcode_of(u);
    if o == OP_FREEZE || o == OP_PHI || o == OP_INVOKE { return false; }
    if o == OP_SELECT { return k == 0; }
    if o == OP_CALL {
        let id = inst_iid(u);
        if id != 0 { return intrinsic_propagates_poison(id); }
        return false;
    }
    if o == OP_ICMP || o == OP_FCMP || o == OP_GEP { return true; }
    if is_binary_op(o) || o == OP_FNEG || is_cast_op(o) { return true; }
    return false;
}

recursive fn directly_implies_poison(vap: i32, v: i32, depth: i64) -> bool {
    if vap == v { return true; }
    if depth >= 2 { return false; }
    if is_inst(v) {
        for k in nops(v) {
            if propagates_poison(v, k) && directly_implies_poison(vap, op(v, k), depth + 1) { return true; }
        }
        if iop(v) == OP_EXTRACTVALUE && is_with_overflow(op(v, 0)) {
            let ii = op(v, 0);
            if is_inst_op(vap, OP_EXTRACTVALUE) && op(vap, 0) == ii { return true; }
            for k in cb_nargs(ii) { if cb_arg(ii, k) == vap { return true; } }
        }
    }
    return false;
}
fn is_with_overflow(v: i32) -> bool {
    let id = inst_iid(v);
    return id == IID_sadd_with_overflow || id == IID_ssub_with_overflow || id == IID_smul_with_overflow ||
           id == IID_uadd_with_overflow || id == IID_usub_with_overflow || id == IID_umul_with_overflow;
}

recursive fn implies_poison_d(vap: i32, v: i32, depth: i64) -> bool {
    if is_guaranteed_not_to_be_poison(vap, -1, 0) { return true; }
    if directly_implies_poison(vap, v, 0) { return true; }
    if depth >= 2 { return false; }
    if is_inst(vap) && !can_create_poison(vap, true) {
        for k in nops(vap) { if !implies_poison_d(op(vap, k), v, depth + 1) { return false; } }
        return true;
    }
    return false;
}
// impliesPoison(ValAssumedPoison, V)
fn implies_poison(vap: i32, v: i32) -> bool { implies_poison_d(vap, v, 0) }

// Constant::containsUndefElement / containsPoisonElement / containsConstantExpression (vectors)
fn vec_contains_kind(c: i32, kind: i64) -> bool {
    let t = vals[c].ty;
    if ty_kind(t) != TK_FVEC { return false; }
    if vals[c].kind == VK_CINT || vals[c].kind == VK_CFP { return false; }
    for i in ty_count(t) {
        let e = agg_elem(c, i);
        if e < 0 { continue; }
        let ek = vals[e].kind;
        if kind == 0 && ek == VK_UNDEF { return true; }
        if kind == 1 && ek == VK_POISON { return true; }
        if kind == 2 && ek == VK_CEXPR { return true; }
    }
    return false;
}
fn contains_undef_element(c: i32) -> bool {
    // Constant::containsUndefElement: an UndefValue element that is not poison (Constants.cpp)
    let t = vals[c].ty;
    if ty_kind(t) != TK_FVEC { return false; }
    if vals[c].kind == VK_UNDEF { return true; }
    if vals[c].kind == VK_POISON { return false; }
    for i in ty_count(t) {
        let e = agg_elem(c, i);
        if e >= 0 && vals[e].kind == VK_UNDEF { return true; }
    }
    return false;
}

// stripPointerCastsSameRepresentation
fn strip_ptr_casts_same_repr(v0: i32) -> i32 {
    var v = v0;
    if ty_kind(vals[v].ty) != TK_PTR { return v; }
    var n = 0;
    while n < 10000 {
        n++;
        let o = opcode_of(v);
        if o == OP_GEP {
            for k in 1..nops(v) { if !(is_constant(op(v, k)) && is_null_value(op(v, k))) { return v; } }
            v = op(v, 0);
        } else if o == OP_BITCAST {
            let nv = op(v, 0);
            if ty_kind(vals[nv].ty) != TK_PTR { return v; }
            v = nv;
        } else if is_callbase(v) {
            let rv = returned_arg_operand(v);
            if rv >= 0 { v = rv; continue; }
            return v;
        } else { return v; }
        if v == v0 { return v; }
    }
    return v;
}

recursive fn guaranteed_not_undef_or_poison(v: i32, cxt: i32, depth: i64, kind: i64) -> bool {
    if depth >= VT_MAX_DEPTH { return false; }
    let k = vals[v].kind;
    if k == VK_MDVAL { return false; }
    let inc_poison = (kind & UPK_POISON) != 0;
    let inc_undef = (kind & UPK_UNDEF) != 0;
    if k == VK_ARG {
        if arg_has_attr(v, AK_NoUndef) || arg_has_attr(v, AK_Dereferenceable) || arg_has_attr(v, AK_DereferenceableOrNull) { return true; }
    }
    if is_constant(v) {
        if k == VK_POISON { return !inc_poison; }
        if k == VK_UNDEF { return !inc_undef; }
        if (k == VK_CINT && !ty_is_vector(vals[v].ty)) || k == VK_GVAR || (k == VK_CFP && !ty_is_vector(vals[v].ty)) || (k == VK_CNULL && !ty_is_vector(vals[v].ty)) || k == VK_FUNC { return true; }
        if ty_is_vector(vals[v].ty) {
            if k == VK_CEXPR {
                let s = splat_value(v, false);
                if s >= 0 && (vals[s].kind == VK_CINT || vals[s].kind == VK_CFP) { return true; }
            } else {
                if inc_undef && contains_undef_element(v) { return false; }
                if inc_poison && vec_contains_kind(v, 1) { return false; }
                return !vec_contains_kind(v, 2);
            }
        }
    }
    let sv = strip_ptr_casts_same_repr(v);
    let sk = vals[sv].kind;
    if is_inst_op(sv, OP_ALLOCA) || sk == VK_GVAR || sk == VK_FUNC || (sk == VK_CNULL && !ty_is_vector(vals[sv].ty)) { return true; }
    if k == VK_INST || k == VK_CEXPR {
        if is_inst_op(v, OP_FREEZE) { return true; }
        if is_callbase(v) {
            if call_has_ret_attr(v, AK_NoUndef) || call_has_ret_attr(v, AK_Dereferenceable) || call_has_ret_attr(v, AK_DereferenceableOrNull) { return true; }
        }
        if !can_create_undef_or_poison_k(v, kind, true) {
            if is_inst_op(v, OP_PHI) {
                var well = true;
                for i in nops(v) {
                    let iv = op(v, i);
                    if iv == v { continue; }
                    let ti = block_terminator(phi_block(v, i));
                    if !guaranteed_not_undef_or_poison(iv, ti, depth + 1, kind) { well = false; break; }
                }
                if well { return true; }
            } else if is_inst_op(v, OP_SHUFFLEVECTOR) && shuffle_splat_value(v) >= 0 {
                if guaranteed_not_undef_or_poison(shuffle_splat_value(v), cxt, depth + 1, kind) { return true; }
            } else {
                var all = true;
                for i in nops(v) { if !guaranteed_not_undef_or_poison(op(v, i), cxt, depth + 1, kind) { all = false; break; } }
                if all { return true; }
            }
        }
    }
    if is_inst_op(v, OP_LOAD) {
        if inst_get_md(v, md_kind_id("noundef")) >= 0 || inst_get_md(v, md_kind_id("dereferenceable")) >= 0 ||
           inst_get_md(v, md_kind_id("dereferenceable_or_null")) >= 0 { return true; }
    }
    if program_undefined_if_undef_or_poison(v, !inc_undef) { return true; }
    if cxt < 0 || sq_no_dt { return false; }
    let cbb = inst_parent(cxt);
    if cbb < 0 { return false; }
    if !block_reachable(cbb) { return false; }
    if !inc_undef || ty_is_int(vals[v].ty) {
        var d = dt_idom(DT_DOM, cbb);
        while d >= 0 {
            let ti = block_terminator(d);
            var cond: i32 = -1;
            if ti >= 0 && iop(ti) == OP_CONDBR { cond = op(ti, 0); }
            else if ti >= 0 && iop(ti) == OP_SWITCH { cond = op(ti, 0); }
            if cond >= 0 {
                if cond == v { return true; }
                if !inc_undef && (vals[cond].kind == VK_INST || vals[cond].kind == VK_CEXPR) {
                    for i in nops(cond) { if op(cond, i) == v && propagates_poison(cond, i) { return true; } }
                }
            }
            d = dt_idom(DT_DOM, d);
        }
    }
    // getKnowledgeValidInContext(V, {NoUndef}, AC, CtxI, DT): assume operand bundles
    if noundef_from_assume(v, cxt) { return true; }
    return false;
}

// getSplatValue for a shufflevector instruction: splat of an insertelement at index 0
fn shuffle_splat_value(v: i32) -> i32 {
    // llvm::getSplatValue(V): shuffle (insertelement ?, X, 0), ?, zeroinitializer-mask -> X
    let x = insts[inst_of(v)];
    for k in x.naux { if ints[x.aux + k] != 0 { return -1; } }
    let ie = op(v, 0);
    if !is_op(ie, OP_INSERTELEMENT) { return -1; }
    let ix = op(ie, 2);
    if !m_zero_int(ix) || !is_constant(ix) { return -1; }
    return op(ie, 1);
}

recursive fn is_guaranteed_not_to_be_undef_or_poison(v: i32, cxt: i32, depth: i64) -> bool { guaranteed_not_undef_or_poison(v, cxt, depth, UPK_BOTH) }
recursive fn is_guaranteed_not_to_be_poison(v: i32, cxt: i32, depth: i64) -> bool { guaranteed_not_undef_or_poison(v, cxt, depth, UPK_POISON) }
recursive fn is_guaranteed_not_to_be_undef(v: i32, cxt: i32, depth: i64) -> bool { guaranteed_not_undef_or_poison(v, cxt, depth, UPK_UNDEF) }

// handleGuaranteedWellDefinedOps / handleGuaranteedNonPoisonOps with "op == x" or "op in set" checks.
fn well_defined_ops_contain(i: i32, set_mode: bool, x: i32, non_poison: bool) -> bool {
    let o = iop(i);
    if o == OP_STORE { if pz_has(op(i, 1), set_mode, x) { return true; } }
    else if o == OP_LOAD || o == OP_CMPXCHG || o == OP_ATOMICRMW { if pz_has(op(i, 0), set_mode, x) { return true; } }
    else if o == OP_CALL || o == OP_INVOKE {
        let c = cb_callee(i);
        if !is_func(c) && !(vals[c].kind == VK_INLINEASM) && pz_has(c, set_mode, x) { return true; }
        for k in cb_nargs(i) {
            if (call_param_has_attr(i, k, AK_NoUndef) || call_param_has_attr(i, k, AK_Dereferenceable) ||
                call_param_has_attr(i, k, AK_DereferenceableOrNull)) && pz_has(cb_arg(i, k), set_mode, x) { return true; }
        }
    } else if o == OP_RET {
        let f = inst_func(i);
        if nops(i) > 0 && aset_has(alist_ret(globs[glob_of(f)].attrs), AK_NoUndef) && pz_has(op(i, 0), set_mode, x) { return true; }
    } else if o == OP_SWITCH || o == OP_CONDBR {
        if pz_has(op(i, 0), set_mode, x) { return true; }
    }
    if non_poison {
        if o == OP_UDIV || o == OP_SDIV || o == OP_UREM || o == OP_SREM { return pz_has(op(i, 1), set_mode, x); }
    }
    return false;
}
// poison set: scratch set VS_ANA1 when set_mode, else equality with x
fn pz_has(v: i32, set_mode: bool, x: i32) -> bool { if set_mode { vs_has(VS_ANA1, v) } else { v == x } }

fn program_undefined_if_undef_or_poison(v: i32, poison_only: bool) -> bool {
    var bb: i32 = -1;
    var it: i32 = -1;
    if is_inst(v) { bb = inst_parent(v); it = inst_next(v); }
    else if is_arg(v) {
        let f = args_parent[vals[v].sub];
        if func_is_decl(f) { return false; }
        bb = func_entry(f);
        it = block_first(bb);
    } else { return false; }
    var limit = 32;
    if !poison_only {
        while it >= 0 {
            limit--;
            if limit == 0 { break; }
            if well_defined_ops_contain(it, false, v, false) { return true; }
            if !guaranteed_to_transfer(it) { break; }
            it = inst_next(it);
        }
        return false;
    }
    vs_clear(VS_ANA1);
    vs_add(VS_ANA1, v);
    var visited: i32[>..<] = [];
    visited.push(bb);
    loop {
        while it >= 0 {
            limit--;
            if limit == 0 { return false; }
            if well_defined_ops_contain(it, true, -1, true) { return true; }
            if !guaranteed_to_transfer(it) { return false; }
            for k in nops(it) {
                if vs_has(VS_ANA1, op(it, k)) && propagates_poison(it, k) { vs_add(VS_ANA1, it); break; }
            }
            if iop(it) == OP_SELECT && vs_has(VS_ANA1, op(it, 1)) && vs_has(VS_ANA1, op(it, 2)) { vs_add(VS_ANA1, it); }
            it = inst_next(it);
        }
        // BB->getSingleSuccessor()
        let t = block_terminator(bb);
        if t < 0 { break; }
        let ns = term_nsucc(t);
        if ns == 0 { break; }
        let s0 = term_succ(t, 0);
        var single = true;
        for k in 1..ns { if term_succ(t, k) != s0 { single = false; } }
        if !single { break; }
        for b in visited { if b == s0 { return false; } }
        visited.push(s0);
        bb = s0;
        it = first_non_phi(bb);
    }
    return false;
}
