// Negator: port of llvm/lib/Transforms/InstCombine/InstCombineNegator.cpp.
//
// The Negator has its own IRBuilder (TargetFolder + a callback inserter that records the new instructions).
// Here it is the global InstCombine builder with ng_active set: icb_insert then records the instruction in
// ng_new instead of adding it to the worklist. Each visit sets the insertion point to the instruction being
// negated (InsertPointGuard = save/restore of icb_pos/icb_bb/icb_dl). On failure the new instructions are
// erased in reverse order; on success they go to the worklist in creation order (IC.Builder.Insert with no
// insertion point). NegationsCache: (value, result) pairs of the current run.
namespace ic;
import std;
import ir;
import irutil;
import instinfo;
import gen_iids;
import constfold;
import pm;
import vt;
import apint;
import flags;
import domtree;
import ic;
import ic_builder;
import cfgutil;
import ic_common;

var ng_active: bool = false;
var ng_truly: bool = false;
var ng_new: i32[>..<];
var ng_cache_k: i32[>..<];
var ng_cache_v: i32[>..<];

fn ng_cache_find(v: i32) -> i64 {
    for k in ng_cache_k.len { if ng_cache_k[k] == v { return k; } }
    return -1;
}

// Negator::getSortedOperandsOfBinOp: results in ng_o0 / ng_o1
var ng_o0: i32 = -1;
var ng_o1: i32 = -1;
fn ng_sorted_ops(i: i32) {
    ng_o0 = op(i, 0);
    ng_o1 = op(i, 1);
    if is_commutative(iop(i)) && get_complexity(op(i, 0)) < get_complexity(op(i, 1)) { let t = ng_o0; ng_o0 = ng_o1; ng_o1 = t; }
}

// give a value the Negator just created the name I->getName() + ".neg" (IRBuilder names on insertion; naming
// right after insertion uniques the same way)
fn ng_nm(v: i32, i: i32) -> i32 {
    if !is_inst(v) || ng_new.len == 0 || ng_new[ng_new.len - 1] != v { return v; }
    var b: u8[>..] = [];
    b.append(val_name(i));
    b.append(".neg");
    set_name(v, b);
    return v;
}

// Constant::containsUndefOrPoisonElement
fn contains_undef_or_poison_element(c: i32) -> bool {
    if is_undef_or_poison(c) { return true; }
    if ty_kind(vals[c].ty) == TK_FVEC {
        for k in ty_count(vals[c].ty) { let e = agg_elem(c, k); if e >= 0 && is_undef_or_poison(e) { return true; } }
    }
    return false;
}
// Constant::isNotOneValue
fn is_not_one_value(c: i32) -> bool {
    if vals[c].kind == VK_CINT && !ty_is_vector(vals[c].ty) { return !ap_is_one(ci_ap(c)); }
    if ty_is_vector(vals[c].ty) {
        let s = splat_value(c, false);
        if s >= 0 && vals[s].kind == VK_CINT { return !ap_is_one(ci_ap(s)); }
        if ty_kind(vals[c].ty) == TK_FVEC {
            for k in ty_count(vals[c].ty) {
                let e = agg_elem(c, k);
                if e < 0 || vals[e].kind != VK_CINT || ap_is_one(ci_ap(e)) { return false; }
            }
            return true;
        }
    }
    return false;
}
// m_AnyIntegralConstant: a ConstantInt or a vector of them (splat or not; no undef)
fn m_any_integral_constant(v: i32) -> bool {
    if !is_constant(v) { return false; }
    if vals[v].kind == VK_CINT { return true; }
    if !ty_is_vector(vals[v].ty) || !ty_is_int(ty_scalar(vals[v].ty)) { return false; }
    let s = splat_value(v, false);
    if s >= 0 && vals[s].kind == VK_CINT { return true; }
    if ty_kind(vals[v].ty) != TK_FVEC { return false; }
    for k in ty_count(vals[v].ty) { let e = agg_elem(v, k); if e < 0 || vals[e].kind != VK_CINT { return false; } }
    return vals[v].kind == VK_CDVECTOR || vals[v].kind == VK_CVECTOR;
}

// Negator::visitImpl(V, IsNSW, Depth)
recursive fn ng_visit(v: i32, nsw0: bool, depth: i64) -> i32 {
    var nsw = nsw0;
    if m_undef(v) { return v; }
    if is_int_ty1(vals[v].ty) { return v; }
    let x0 = m_neg(v);
    if x0 >= 0 { return x0; }
    if m_any_integral_constant(v) { return ce_binop(OP_SUB, c_null(vals[v].ty), v, 0); }
    if !is_inst(v) { return -1; }
    if !has_one_use(v) && !ng_truly { return -1; }
    let i = v;
    let bw = ty_scalar_bits(vals[i].ty);
    let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
    icb_set_insert_point(i);
    let r = ng_visit_inner(i, nsw, depth, bw);
    icb_pos = sp; icb_bb = sb; icb_dl = sd;
    return r;
}

recursive fn ng_visit_inner(i: i32, nsw0: bool, depth: i64, bw: i64) -> i32 {
    var nsw = nsw0;
    let o = iop(i);
    if o == OP_ADD {
        ng_sorted_ops(i);
        if m_one(ng_o1) { return ng_nm(icb_not(ng_o0, ""), i); }
    } else if o == OP_XOR {
        let x = m_not(i);
        if x >= 0 { return ng_nm(icb_add(x, c_int_ty(vals[x].ty, 1), ""), i); }
    } else if o == OP_ASHR || o == OP_LSHR {
        if has_apint(op(i, 1)) && ap_eq_u64(ap_c(op(i, 1)), (bw - 1) as u64) {
            let b = if o == OP_ASHR { icb_lshr(op(i, 0), op(i, 1), "", false) } else { icb_ashr(op(i, 0), op(i, 1), "", false) };
            if is_inst(b) { copy_ir_flags(b, i); ng_nm(b, i); }
            return b;
        }
    } else if o == OP_SEXT || o == OP_ZEXT {
        if is_int_ty1(vals[op(i, 0)].ty) {
            return ng_nm(if o == OP_SEXT { icb_zext(op(i, 0), vals[i].ty, "") } else { icb_sext(op(i, 0), vals[i].ty, "") }, i);
        }
    } else if o == OP_SELECT {
        if is_imm_c(op(i, 1)) && is_imm_c(op(i, 2)) {
            let nt = ce_binop(OP_SUB, c_null(vals[i].ty), op(i, 1), 0);
            let nf = ce_binop(OP_SUB, c_null(vals[i].ty), op(i, 2), 0);
            return ng_nm(icb_select(op(i, 0), nt, nf, "", i), i);
        }
    } else if o == OP_CALL {
        let id = inst_iid(i);
        if (id == IID_scmp || id == IID_ucmp) && has_one_use(i) {
            return icb_intrinsic(id, [vals[i].ty as i32, vals[op(i, 1)].ty as i32], [op(i, 1), op(i, 0)], "");
        }
    }
    if o == OP_SUB && (has_one_use(i) || is_imm_c(op(i, 0))) {
        return ng_nm(icb_sub_nw(op(i, 1), op(i, 0), "", false, nsw && op_nsw(i)), i);
    }
    if !has_one_use(i) { return -1; }
    if o == OP_ZEXT {
        let src = op(i, 0);
        let sw = ty_scalar_bits(vals[src].ty);
        if ng_truly && bo(src, OP_LSHR) && m_specific_int_allow_poison_ng(op(src, 1), (sw - 1) as u64) {
            let x = op(src, 0);
            let a = icb_ashr(x, c_int_ty(vals[x].ty, (sw - 1) as u64), "", false);
            return icb_sext(a, vals[i].ty, "");
        }
    } else if o == OP_AND {
        var t = op(i, 0);
        if one_use(t) && m_one(op(i, 1)) {
            let tt = m_trunc(t);
            var sh = t;
            if tt >= 0 { sh = tt; }
            if bo(sh, OP_LSHR) && is_imm_c(op(sh, 1)) && (tt < 0 || true) {
                let x = op(sh, 0);
                let shamt = op(sh, 1);
                let xbw = ty_scalar_bits(vals[x].ty);
                let bwm1 = c_int_ty(vals[x].ty, (xbw - 1) as u64);
                var rr = icb_shl(x, icb_sub(bwm1, shamt, ""), "");
                rr = icb_ashr(rr, bwm1, "", false);
                return ng_trunc_or_bitcast(rr, vals[i].ty);
            }
        }
    } else if o == OP_SDIV {
        let c = op(i, 1);
        if is_constant(c) {
            if !contains_undef_or_poison_element(c) && ic_is_not_min_signed_value(c) && is_not_one_value(c) {
                let b = ng_nm(icb_sdiv(op(i, 0), ce_binop(OP_SUB, c_null(vals[c].ty), c, 0), "", false), i);
                if is_inst(b) { set_exact(b, op_exact(i)); }
                return b;
            }
        }
    }
    if depth > flag_int("instcombine-negator-max-depth", 6) { return -1; }
    if o == OP_FREEZE {
        let n = ng_negate(op(i, 0), nsw, depth + 1);
        if n < 0 { return -1; }
        return ng_nm(icb_freeze(n, ""), i);
    }
    if o == OP_PHI {
        let mark = ng_tmp.len;
        for k in nops(i) {
            let inv = op(i, k);
            // DT.dominates(PHI->getParent(), Use): a PHI use is dominated by the end of its incoming block
            if dt_dominates_block(DT_DOM, inst_parent(i), phi_block(i, k)) { ng_tmp.resize(mark); return -1; }
            let n = ng_negate(inv, nsw, depth + 1);
            if n < 0 { ng_tmp.resize(mark); return -1; }
            ng_tmp.push(n);
        }
        let np = new_inst(OP_PHI, vals[i].ty, nops(i));
        vals[np].nops = 0;
        icb_insert(np, "");
        ng_nm(np, i);
        for k in nops(i) { phi_add_incoming(np, ng_tmp[mark + k], phi_block(i, k)); }
        ng_tmp.resize(mark);
        return np;
    }
    if o == OP_SELECT {
        if is_known_negation(op(i, 1), op(i, 2), false, false) {
            let ns = inst_clone(i);
            // swapValues (Use::swap); setName(I.getName() + ".neg") is undone by Builder.Insert(NewSelect),
            // which names the instruction "" on insertion, so the select stays unnamed
            cu_use_swap(vals[ns].ops + 1, vals[ns].ops + 2);
            let tv = op(ns, 1);
            let fv = op(ns, 2);
            if m_neg(tv) == fv && is_inst(tv) { drop_poison_generating_flags(tv); }
            else if m_neg(fv) == tv && is_inst(fv) { drop_poison_generating_flags(fv); }
            else {
                if is_inst(tv) { drop_poison_generating_flags(tv); }
                if is_inst(fv) { drop_poison_generating_flags(fv); }
            }
            icb_insert(ns, "");
            return ns;
        }
        let n1 = ng_negate(op(i, 1), nsw, depth + 1);
        if n1 < 0 { return -1; }
        let n2 = ng_negate(op(i, 2), nsw, depth + 1);
        if n2 < 0 { return -1; }
        return ng_nm(icb_select(op(i, 0), n1, n2, "", i), i);
    }
    if o == OP_SHUFFLEVECTOR || o == OP_EXTRACTELEMENT || o == OP_INSERTELEMENT {
        ic_not_ported("Negator through vector element operations");
        return -1;
    }
    if o == OP_TRUNC {
        let n = ng_negate(op(i, 0), false, depth + 1);
        if n < 0 { return -1; }
        return ng_nm(icb_trunc(n, vals[i].ty, ""), i);
    }
    if o == OP_SHL {
        nsw = nsw && op_nsw(i);
        let n0 = ng_negate(op(i, 0), nsw, depth + 1);
        if n0 >= 0 { return ng_nm(icb_shl_nw(n0, op(i, 1), "", false, nsw), i); }
        let c = op(i, 1);
        if !is_imm_c(c) || !ng_truly { return -1; }
        let m = icb_shl(c_all_ones(vals[c].ty), c, "");
        return ng_nm(icb_mul_nw(op(i, 0), m, "", false, nsw), i);
    }
    if o == OP_OR || o == OP_ADD {
        if o == OP_OR {
            if !op_disjoint(i) { return -1; }
            ng_sorted_ops(i);
            if m_one(ng_o1) { return ng_nm(icb_not(ng_o0, ""), i); }
        }
        var negated: i32[..2] = [];
        var nonneg: i32[..2] = [];
        for k in 2 {
            let x = op(i, k);
            let n = ng_negate(x, false, depth + 1);
            if n >= 0 { negated.push(n); continue; }
            if !ng_truly { return -1; }
            nonneg.push(x);
        }
        if negated.len == 2 { return ng_nm(icb_add(negated[0], negated[1], ""), i); }
        if nonneg.len == 2 { return -1; }
        return ng_nm(icb_sub(negated[0], nonneg[0], ""), i);
    }
    if o == OP_XOR {
        ng_sorted_ops(i);
        if is_constant(ng_o1) && ng_truly {
            let x = icb_xor(ng_o0, ce_not(ng_o1), "");
            return ng_nm(icb_add(x, c_int_ty(vals[x].ty, 1), ""), i);
        }
        return -1;
    }
    if o == OP_MUL {
        ng_sorted_ops(i);
        let a = ng_o0;
        let b = ng_o1;
        var negated: i32 = -1;
        var other: i32 = -1;
        let n1 = ng_negate(b, false, depth + 1);
        if n1 >= 0 { negated = n1; other = a; }
        else {
            let n0 = ng_negate(a, false, depth + 1);
            if n0 >= 0 { negated = n0; other = b; } else { return -1; }
        }
        return ng_nm(icb_mul_nw(negated, other, "", false, nsw && op_nsw(i)), i);
    }
    return -1;
}
var ng_tmp: i32[>..<];

fn m_specific_int_allow_poison_ng(v: i32, x: u64) -> bool {
    let c = m_apint_ap(v, true);
    return c >= 0 && ap_eq_u64(ci_ap(c), x);
}
// CreateTruncOrBitCast
fn ng_trunc_or_bitcast(v: i32, ty: i32) -> i32 {
    if ty_scalar_bits(vals[v].ty) == ty_scalar_bits(ty) { return icb_cast(OP_BITCAST, v, ty, ""); }
    return icb_trunc(v, ty, "");
}
// Negator::negate(V, IsNSW, Depth)
recursive fn ng_negate(v: i32, nsw: bool, depth: i64) -> i32 {
    let k = ng_cache_find(v);
    if k >= 0 { return ng_cache_v[k]; }
    let r = ng_visit(v, nsw, depth);
    ng_cache_k.push(v);
    ng_cache_v.push(r);
    return r;
}

// Negator::Negate(LHSIsZero, IsNSW, Root, IC)
fn negator_negate(lhs_is_zero: bool, nsw: bool, root: i32, cur: i32) -> i32 {
    if !flag_bool("instcombine-negator-enabled", true) { return -1; }
    if ng_active { fatal("internal: nested Negator"); }
    ng_active = true;
    ng_truly = lhs_is_zero;
    ng_new.resize(0);
    ng_cache_k.resize(0);
    ng_cache_v.resize(0);
    let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
    let r = ng_negate(root, nsw, 0);
    icb_pos = sp; icb_bb = sb; icb_dl = sd;
    ng_active = false;
    if r < 0 {
        var k = ng_new.len - 1;
        while k >= 0 {
            let x = ng_new[k];
            k--;
            if !use_empty(x) { fatal("internal: Negator cleanup of a used instruction"); }
            inst_erase_from_parent(x);
        }
        ng_new.resize(0);
        return -1;
    }
    for x in ng_new {
        icw_add(x);
        if inst_iid(x) == IID_assume { ic_register_assumption(x); }
        if ic_annot_src >= 0 { ic_copy_annotation_md(x, ic_annot_src); }
    }
    ng_new.resize(0);
    return r;
}
