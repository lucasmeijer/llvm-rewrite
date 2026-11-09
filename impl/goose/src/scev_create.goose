// ScalarEvolution: building SCEVs from IR (getSCEV, createSCEVIter, getOperandsToCreate, createSCEV,
// createNodeForPHI and the AddRec-from-PHI recognizers, selects, GEPs), the value <-> SCEV maps,
// forgetMemoizedResults, the SCEVRewriteVisitor subclasses used here, and the poison/scope helpers.
// Port of the corresponding parts of llvm/lib/Analysis/ScalarEvolution.cpp.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import pm;
import vt;
import poison;
import knownbits;
import instsimplify;
import gen_iids;
import apint;
import constrange;
import loopinfo;
import domtree;
import scev;
import scev_range;
import scev_btc;
import scev_pred;
import scev_eval;
import scev_lt;
import scev_guards;

// ---------------------------------------------------------------------------------------------
// Lists in a pool (SCEVUsers, ExprValueMap, BECountUsers, LoopUsers)

struct LNode { val: i32, next: i32 }
var sc_lpool: LNode[>..];
var sc_users_head: i32[>..];      // per SCEV: users (SCEVUsers[S])
var sc_values_head: i32[>..];     // per SCEV: values mapped to it (ExprValueMap[S])
var sc_becusers_head: i32[>..];   // per SCEV: (loop << 1 | predicated) of the BTCs using it (BECountUsers)
var sc_side2: ScSide2[>..];
// generation; Unsigned/SignedWrapViaInductionTried; disposition generations, epochs and stamps (scev_eval.goose)
struct ScSide2 { gen: i32, uwit: bool, swit: bool, ldg: i32, bdg: i32, lde: i32, bde: i32, lds: i32, bds: i32 }
var sc_loop_users = hm_new();     // loop -> head of a list of AddRecs (LoopUsers)

recursive fn scev_reset_create() {
    sc_lpool.resize(0);
    sc_users_head.resize(0);
    sc_values_head.resize(0);
    sc_becusers_head.resize(0);
    sc_side2.resize(0);
    hm_clear(sc_loop_users);
    hm_clear(sc_rw_cache);
    sc_rw_serial = 0;
    sc_cstack.resize(0);
    hm_clear(sc_loop_props);
}

recursive fn sc_side2_grow() {
    while sc_users_head.len < scevs.len { sc_users_head.push(-1); }
    while sc_values_head.len < scevs.len { sc_values_head.push(-1); }
    while sc_becusers_head.len < scevs.len { sc_becusers_head.push(-1); }
    while sc_side2.len < scevs.len { sc_side2.push(ScSide2 { gen: 0, uwit: false, swit: false, ldg: 0, bdg: 0, lde: 0, bde: 0, lds: 0, bds: 0 }); }
}
recursive fn sc_gen(s: i32) -> i32 { sc_side2_grow(); return sc_side2[s].gen; }

recursive fn sc_list_push(head: i32, v: i32) -> i32 { let id = sc_lpool.len as i32; sc_lpool.push(LNode { val: v, next: head }); return id; }

// registerUser(User, Ops)
recursive fn sc_register_users(u: i32) {
    sc_side2_grow();
    for k in sc_nops(u) {
        let o = sc_op(u, k);
        sc_users_head[o] = sc_list_push(sc_users_head[o], u);
    }
}
recursive fn sc_loop_users_add(l: i32, s: i32) {
    let h = hm_get(sc_loop_users, l as u64, -1) as i32;
    hm_put(sc_loop_users, l as u64, sc_list_push(h, s) as i64);
}

// ---------------------------------------------------------------------------------------------
// ValueExprMap / ExprValueMap

recursive fn sc_get_existing(v: i32) -> i32 { hm_get(sc_vmap, v as u64, -1) as i32 }
recursive fn sc_insert_value_to_map(v: i32, s: i32) {
    if hm_has(sc_vmap, v as u64) { return; }
    hm_put(sc_vmap, v as u64, s as i64);
    sc_side2_grow();
    sc_values_head[s] = sc_list_push(sc_values_head[s], v);
}
recursive fn sc_erase_value_from_map(v: i32) { hm_del(sc_vmap, v as u64); }

// forgetMemoizedResults(SCEVs): the transitive users through SCEVUsers, then forgetMemoizedResultsImpl
recursive fn sc_forget_memoized(s0: i32) {
    sc_side2_grow();
    let mark = sc_seen.len;
    sc_seen.push(s0);
    let wl0 = sc_newops.len;
    sc_newops.push(s0);
    while sc_newops.len > wl0 {
        let c = sc_newops.pop();
        var u = sc_users_head[c];
        while u >= 0 {
            let us = sc_lpool[u].val;
            var seen = false;
            for k in mark..sc_seen.len { if sc_seen[k] == us { seen = true; break; } }
            if !seen { sc_seen.push(us); sc_newops.push(us); }
            u = sc_lpool[u].next;
        }
    }
    let n = sc_seen.len;
    for k in mark..n { sc_forget_memoized_impl(sc_seen[k]); }
    sc_seen.resize(mark);
    sc_forget_predicated_rewrites();
}

recursive fn sc_forget_memoized_impl(s: i32) {
    sc_side2_grow();
    sc_side2[s].gen += 1;          // LoopDispositions, BlockDispositions, ValuesAtScopes(Users), FoldCache users
    sc_side[s].ur_valid = false;
    sc_side[s].sr_valid = false;
    sc_side[s].has_rec = -1;
    sc_side[s].mtz = -1;
    sc_side2[s].uwit = false;
    sc_side2[s].swit = false;
    var v = sc_values_head[s];
    while v >= 0 {
        let x = sc_lpool[v].val;
        if sc_get_existing(x) == s { sc_erase_value_from_map(x); }
        v = sc_lpool[v].next;
    }
    sc_values_head[s] = -1;
    var b = sc_becusers_head[s];
    sc_becusers_head[s] = -1;
    while b >= 0 {
        // the BTC that registered this user (by the start of its exit entries), if it is still the cached one
        // (forgetBackedgeTakenCounts erased its BECountUsers entries otherwise)
        let at = sc_lpool[b].val;
        let x = hm_get(sc_bti_tag, at as u64, -1);
        if x >= 0 {
            let cur = hm_get(sc_bti_map, x as u64, -1);
            if cur >= 0 && sc_btis[cur].n > 0 && sc_btis[cur].at == at { sc_forget_backedge_taken_counts((x >> 1) as i32, (x & 1) != 0); }
        }
        b = sc_lpool[b].next;
    }
}

// ---------------------------------------------------------------------------------------------
// getSCEV / createSCEVIter

var sc_cstack: i64[>..<];       // createSCEVIter's Stack: value | (int << 32)

recursive fn sc_get_scev(v: i32) -> i32 {
    let e = sc_get_existing(v);
    if e >= 0 { return e; }
    return sc_create_scev_iter(v);
}

recursive fn sc_create_scev_iter(v: i32) -> i32 {
    let base = sc_cstack.len;
    sc_cstack.push(v as i64);
    while sc_cstack.len > base {
        let e = sc_cstack[sc_cstack.len - 1];
        let cur = (e & 0xFFFFFFFF) as i32;
        let flag = (e >> 32) != 0;
        if sc_get_existing(cur) >= 0 { sc_cstack.pop(); continue; }
        let ob = sc_vops.len;
        var created: i32 = -1;
        if flag { created = sc_create_scev(cur); } else { created = sc_get_operands_to_create(cur); }
        if created >= 0 {
            sc_insert_value_to_map(cur, created);
            sc_cstack.pop();
            sc_vops.resize(ob);
        } else {
            sc_cstack[sc_cstack.len - 1] = (cur as i64) | (1 << 32);
            for k in ob..sc_vops.len { sc_cstack.push(sc_vops[k] as i64); }
            sc_vops.resize(ob);
        }
    }
    return sc_get_existing(v);
}

var sc_vops: i32[>..<];         // getOperandsToCreate's Ops

// BinaryOp (MatchBinaryOp's result)
struct BinOp { opc: i64, lhs: i32, rhs: i32, nsw: bool, nuw: bool, op: i32 }
recursive fn binop_none() -> BinOp { BinOp { opc: -1, lhs: -1, rhs: -1, nsw: false, nuw: false, op: -1 } }
recursive fn binop_of(v: i32) -> BinOp {
    var b = BinOp { opc: opcode_of(v), lhs: op(v, 0), rhs: op(v, 1), nsw: false, nuw: false, op: v };
    let o = b.opc;
    if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL { b.nsw = op_nsw(v); b.nuw = op_nuw(v); }
    return b;
}

recursive fn sc_is_operator(v: i32) -> bool { let k = vals[v].kind as i64; k == VK_INST || k == VK_CEXPR }

// MatchBinaryOp
recursive fn sc_match_binary_op(v: i32) -> BinOp {
    if !sc_is_operator(v) { return binop_none(); }
    let o = opcode_of(v);
    if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_UDIV || o == OP_UREM || o == OP_AND || o == OP_ASHR || o == OP_SHL {
        return binop_of(v);
    }
    if o == OP_OR {
        if op_disjoint(v) { return BinOp { opc: OP_ADD, lhs: op(v, 0), rhs: op(v, 1), nsw: true, nuw: true, op: v }; }
        return binop_of(v);
    }
    if o == OP_XOR {
        let r = op(v, 1);
        if vals[r].kind as i64 == VK_CINT && ap_eq(ap_from_cint(r), ap_smin_val(ty_bits(vals[r].ty))) {
            return BinOp { opc: OP_ADD, lhs: op(v, 0), rhs: r, nsw: false, nuw: false, op: -1 };
        }
        if ty_is_int(vals[v].ty) && ty_bits(vals[v].ty) == 1 { return BinOp { opc: OP_ADD, lhs: op(v, 0), rhs: r, nsw: false, nuw: false, op: -1 }; }
        return binop_of(v);
    }
    if o == OP_LSHR {
        let sa = op(v, 1);
        if vals[sa].kind as i64 == VK_CINT {
            let bw = ty_bits(vals[v].ty);
            let a = ap_from_cint(sa);
            if ap_ult_u64(a, bw as u64) {
                let x = ap_to_cint(vals[v].ty, ap_one_bit(bw, ap_lo64(a) as i64));
                return BinOp { opc: OP_UDIV, lhs: op(v, 0), rhs: x, nsw: false, nuw: false, op: -1 };
            }
        }
        return binop_of(v);
    }
    if o == OP_EXTRACTVALUE && vals[v].kind as i64 == VK_INST {
        let x = insts[inst_of(v)];
        if x.naux == 1 && ints[x.aux] == 0 {
            let wo = op(v, 0);
            let id = inst_iid(wo);
            var bop: i64 = -1;
            var signed = false;
            if id == IID_sadd_with_overflow { bop = OP_ADD; signed = true; }
            else if id == IID_uadd_with_overflow { bop = OP_ADD; }
            else if id == IID_ssub_with_overflow { bop = OP_SUB; signed = true; }
            else if id == IID_usub_with_overflow { bop = OP_SUB; }
            else if id == IID_smul_with_overflow { bop = OP_MUL; signed = true; }
            else if id == IID_umul_with_overflow { bop = OP_MUL; }
            if bop >= 0 {
                if bop == OP_MUL || !sc_is_overflow_intrinsic_no_wrap(wo) {
                    return BinOp { opc: bop, lhs: cb_arg(wo, 0), rhs: cb_arg(wo, 1), nsw: false, nuw: false, op: -1 };
                }
                return BinOp { opc: bop, lhs: cb_arg(wo, 0), rhs: cb_arg(wo, 1), nsw: signed, nuw: !signed, op: -1 };
            }
        }
    }
    if vals[v].kind as i64 == VK_INST && inst_iid(v) == IID_loop_decrement_reg {
        return BinOp { opc: OP_SUB, lhs: op(v, 0), rhs: op(v, 1), nsw: false, nuw: false, op: -1 };
    }
    return binop_none();
}

// dominates(BasicBlockEdge(start, end), Use) for the use `k` of `user`
recursive fn sc_dom_edge_use(start: i32, end: i32, user: i32, k: i64) -> bool {
    if is_phi(user) && inst_parent(user) == end && phi_block(user, k) == start { return true; }
    let ubb = if is_phi(user) { phi_block(user, k) } else { inst_parent(user) };
    return dom_edge(start, end, ubb);
}

// isOverflowIntrinsicNoWrap (ValueTracking.cpp)
fn sc_is_overflow_intrinsic_no_wrap(wo: i32) -> bool {
    var branches: i32[>..<] = [];
    var results: i32[>..<] = [];
    var u = vals[wo].first_use;
    while u >= 0 {
        let ui = uses[u].user;
        if is_inst(ui) && iop(ui) == OP_EXTRACTVALUE {
            let x = insts[inst_of(ui)];
            if ints[x.aux] == 0 { results.push(ui); }
            else {
                var u2 = vals[ui].first_use;
                while u2 >= 0 {
                    let b = uses[u2].user;
                    if is_inst(b) && iop(b) == OP_CONDBR { branches.push(b); }
                    u2 = uses[u2].next;
                }
            }
        } else { return false; }
        u = uses[u].next;
    }
    for bi in branches {
        let s = inst_parent(bi);
        let e = term_succ(bi, 1);
        var ok = true;
        for r in results {
            if dom_edge(s, e, inst_parent(r)) { continue; }
            var u3 = vals[r].first_use;
            while u3 >= 0 {
                let ru = uses[u3].user;
                let k = u3 - vals[ru].ops;
                if !is_inst(ru) || !sc_dom_edge_use(s, e, ru, k as i64) { ok = false; break; }
                u3 = uses[u3].next;
            }
            if !ok { break; }
        }
        if ok { return true; }
    }
    return false;
}

recursive fn sc_is_cint(v: i32) -> bool { vals[v].kind as i64 == VK_CINT }
recursive fn sc_cint_is_zero(v: i32) -> bool { sc_is_cint(v) && ap_is_zero(ap_from_cint(v)) }
recursive fn sc_is_binary_operator(v: i32) -> bool { is_inst(v) && iop(v) >= OP_ADD && iop(v) <= OP_XOR }
recursive fn sc_is_icmp(v: i32) -> bool { is_inst(v) && iop(v) == OP_ICMP }

// getCommonInstForPHI
recursive fn sc_get_common_inst_for_phi(pn: i32) -> i32 {
    var common: i32 = -1;
    for k in phi_nincoming(pn) {
        let inc = phi_value(pn, k);
        if !sc_is_binary_operator(inc) { return -1; }
        if common >= 0 {
            if !sc_is_identical_when_defined(common, inc) { return -1; }
        } else { common = inc; }
    }
    return common;
}

// Instruction::isIdenticalToWhenDefined for binary operators
recursive fn sc_is_identical_when_defined(a: i32, b: i32) -> bool {
    if iop(a) != iop(b) || vals[a].ty != vals[b].ty || nops(a) != nops(b) { return false; }
    for k in nops(a) { if op(a, k) != op(b, k) { return false; } }
    return true;
}

// getOperandsForSelectLikePHI: (ok, cond, lhs, rhs)
recursive fn sc_operands_for_select_like_phi(pn: i32) -> bool, i32, i32, i32 {
    if phi_nincoming(pn) != 2 { return false, -1, -1, -1; }
    for k in 2 { if !dt_has_node(DT_DOM, phi_block(pn, k)) { return false, -1, -1, -1; } }
    let idom = dt_idom(DT_DOM, inst_parent(pn));
    let bi = block_last(idom);
    if iop(bi) != OP_CONDBR { return false, -1, -1, -1; }
    let c = op(bi, 0);
    let bb = inst_parent(bi);
    let s0 = term_succ(bi, 0);
    let s1 = term_succ(bi, 1);
    if sc_dom_edge_use(bb, s0, pn, 0) && sc_dom_edge_use(bb, s1, pn, 1) { return true, c, phi_value(pn, 0), phi_value(pn, 1); }
    if sc_dom_edge_use(bb, s0, pn, 1) && sc_dom_edge_use(bb, s1, pn, 0) { return true, c, phi_value(pn, 1), phi_value(pn, 0); }
    return false, -1, -1, -1;
}

// RangeRefPHIAllowedOperands
recursive fn sc_range_ref_phi_allowed_operands(pn: i32) -> bool {
    let ok, c, l, r = sc_operands_for_select_like_phi(pn);
    if ok { return true; }
    for k in phi_nincoming(pn) { if !dt_value_dominates_inst(phi_value(pn, k), pn) { return false; } }
    return true;
}

// simplifyInstruction(PN, {..., CanUseUndef=false})
recursive fn sc_simplify_phi(pn: i32) -> i32 {
    let mark = is_ops.len;
    let n = nops(pn);
    for k in n { is_ops.push(op(pn, k)); }
    let r = simplify_phi(pn, mark, n, sq_without_undef(sq_new(-1)));
    is_ops.resize(mark);
    if r == pn { return c_poison(vals[pn].ty); }
    return r;
}

// getOperandsToCreate: -1 = operands pushed on sc_vops (create later)
recursive fn sc_get_operands_to_create(v: i32) -> i32 {
    if !sc_is_scevable(vals[v].ty) { return sc_get_unknown(v); }
    let k = vals[v].kind as i64;
    if k == VK_INST {
        if !dt_has_node(DT_DOM, inst_parent(v)) { return sc_get_unknown(c_poison(vals[v].ty)); }
    } else if k == VK_CINT { return sc_get_constant_v(v); }
    else if k == VK_ALIAS { return sc_get_unknown(v); }
    else if k != VK_CEXPR { return sc_get_unknown(v); }
    var bo = sc_match_binary_op(v);
    if bo.opc >= 0 {
        let const_arg = sc_is_cint(bo.rhs);
        let o = bo.opc;
        if o == OP_ADD || o == OP_MUL {
            loop {
                if bo.op >= 0 && bo.op != v && sc_get_existing(bo.op) >= 0 { sc_vops.push(bo.op); break; }
                sc_vops.push(bo.rhs);
                let nb = sc_match_binary_op(bo.lhs);
                if nb.opc < 0 || (bo.opc == OP_ADD && nb.opc != OP_ADD && nb.opc != OP_SUB) || (bo.opc == OP_MUL && nb.opc != OP_MUL) {
                    sc_vops.push(bo.lhs);
                    break;
                }
                if bo.op >= 0 && (bo.nsw || bo.nuw) {
                    if is_inst(bo.op) && program_undefined_if_undef_or_poison(bo.op, true) { sc_vops.push(bo.lhs); break; }
                }
                bo = nb;
            }
            return -1;
        }
        if o == OP_SUB || o == OP_UDIV || o == OP_UREM { }
        else if o == OP_ASHR || o == OP_SHL || o == OP_XOR { if !const_arg { return -1; } }
        else if o == OP_AND || o == OP_OR { if !const_arg && !(ty_is_int(vals[bo.lhs].ty) && ty_bits(vals[bo.lhs].ty) == 1) { return -1; } }
        else if o == OP_LSHR { return sc_get_unknown(v); }
        sc_vops.push(bo.lhs);
        sc_vops.push(bo.rhs);
        return -1;
    }
    let o = opcode_of(v);
    if o == OP_TRUNC || o == OP_ZEXT || o == OP_SEXT || o == OP_PTRTOADDR || o == OP_PTRTOINT { sc_vops.push(op(v, 0)); return -1; }
    if o == OP_BITCAST {
        if sc_is_scevable(vals[v].ty) && sc_is_scevable(vals[op(v, 0)].ty) { sc_vops.push(op(v, 0)); return -1; }
        return sc_get_unknown(v);
    }
    if o == OP_SDIV || o == OP_SREM { sc_vops.push(op(v, 0)); sc_vops.push(op(v, 1)); return -1; }
    if o == OP_GEP { for i in nops(v) { sc_vops.push(op(v, i)); } return -1; }
    if o == OP_INTTOPTR { return sc_get_unknown(v); }
    if o == OP_PHI {
        let sv = sc_simplify_phi(v);
        if sv >= 0 { sc_vops.push(sv); return -1; }
        let ci = sc_get_common_inst_for_phi(v);
        if ci >= 0 { sc_vops.push(ci); return -1; }
        let ok, c, l, r = sc_operands_for_select_like_phi(v);
        if ok {
            if sc_is_icmp(c) { sc_vops.push(op(c, 0)); sc_vops.push(op(c, 1)); }
            sc_vops.push(c);
            sc_vops.push(l);
            sc_vops.push(r);
            return -1;
        }
        if sc_range_ref_phi_allowed_operands(v) { for i in nops(v) { sc_vops.push(op(v, i)); } return -1; }
        return -1;
    }
    if o == OP_SELECT {
        // CanSimplifyToUnknown
        var to_unknown = false;
        let c = op(v, 0);
        if !(ty_bits(vals[v].ty) == 1 && ty_is_int(vals[v].ty)) && !sc_is_cint(c) && sc_is_icmp(c) {
            let p = inst_pred(c);
            if p == P_EQ || p == P_NE {
                if !sc_cint_is_zero(op(c, 1)) { to_unknown = true; }
            } else if sc_type_bits(vals[op(c, 0)].ty) > sc_type_bits(vals[v].ty) { to_unknown = true; }
        }
        if to_unknown { return sc_get_unknown(v); }
        for i in nops(v) { sc_vops.push(op(v, i)); }
        return -1;
    }
    if o == OP_CALL || o == OP_INVOKE {
        let rv = returned_arg_operand(v);
        if rv >= 0 { sc_vops.push(rv); return -1; }
        let id = inst_iid(v);
        if id == IID_abs || id == IID_start_loop_iterations || id == IID_annotation || id == IID_ptr_annotation { sc_vops.push(cb_arg(v, 0)); return -1; }
        if id == IID_umax || id == IID_umin || id == IID_smax || id == IID_smin || id == IID_usub_sat || id == IID_uadd_sat {
            sc_vops.push(cb_arg(v, 0));
            sc_vops.push(cb_arg(v, 1));
            return -1;
        }
    }
    return -1;
}

// getNoWrapFlagsFromUB
recursive fn sc_get_nowrap_flags_from_ub(v: i32) -> u32 {
    if vals[v].kind as i64 == VK_CEXPR { return SF_ANY; }
    var f = SF_ANY;
    if iop(v) == OP_OR && op_disjoint(v) { f = SF_NUW | SF_NSW; }
    else {
        if op_nuw(v) { f |= SF_NUW; }
        if op_nsw(v) { f |= SF_NSW; }
    }
    if f == SF_ANY { return SF_ANY; }
    return if sc_is_scev_expr_never_poison(v) { f } else { SF_ANY };
}

// getNonTrivialDefiningScopeBound
recursive fn sc_non_trivial_defining_scope_bound(s: i32) -> i32 {
    if sc_is_addrec(s) { return block_first(loop_header(sc_loop(s))); }
    if sc_is_unknown(s) && is_inst(sc_value(s)) { return sc_value(s); }
    return -1;
}

// getDefiningScopeBound(Ops = ss[b..b+n], Precise): (bound, precise)
recursive fn sc_get_defining_scope_bound2(b: i64, n: i64) -> i32, bool {
    var precise = true;
    let vm = sc_seen.len;
    let wl = sc_newops.len;
    fn push_op(s: i32) {
        for k in vm..sc_seen.len { if sc_seen[k] == s { return; } }
        sc_seen.push(s);
        if sc_seen.len - vm > 30 { precise = false; return; }
        sc_newops.push(s);
    }
    for k in n { push_op(ss[b + k]); }
    var bound: i32 = -1;
    while sc_newops.len > wl {
        let s = sc_newops.pop();
        let d = sc_non_trivial_defining_scope_bound(s);
        if d >= 0 {
            if bound < 0 || dom_inst(bound, d) { bound = d; }
        } else {
            if sc_kind(s) != SC_UNKNOWN && sc_kind(s) != SC_CONST && sc_kind(s) != SC_VSCALE {
                for i in sc_nops(s) { push_op(sc_op(s, i)); }
            }
        }
    }
    sc_seen.resize(vm);
    sc_newops.resize(wl);
    if bound < 0 { bound = block_first(func_entry(sc_fv)); }
    return bound, precise;
}
recursive fn sc_get_defining_scope_bound(b: i64, n: i64) -> i32 { let r, p = sc_get_defining_scope_bound2(b, n); return r; }

// isGuaranteedToTransferExecutionToSuccessor(Begin, End) over [a, end) of a block (end = -1: the block end)
recursive fn sc_transfer_range(a: i32, e: i32) -> bool {
    var i = a;
    var budget: i64 = 32;     // ScanLimit of isGuaranteedToTransferExecutionToSuccessor(iterator range)
    while i >= 0 && i != e {
        budget--;
        if budget == 0 { return false; }
        if !guaranteed_to_transfer(i) { return false; }
        i = inst_next(i);
    }
    return true;
}

// ScalarEvolution::isGuaranteedToTransferExecutionTo
recursive fn sc_guaranteed_transfer_to(a: i32, b: i32) -> bool {
    if inst_parent(a) == inst_parent(b) && sc_transfer_range(a, b) { return true; }
    let bl = li_loop_for(inst_parent(b));
    if bl >= 0 && loop_header(bl) == inst_parent(b) && loop_preheader(bl) == inst_parent(a) &&
       sc_transfer_range(a, -1) && sc_transfer_range(block_first(inst_parent(b)), b) { return true; }
    return false;
}

// isSCEVExprNeverPoison
recursive fn sc_is_scev_expr_never_poison(i: i32) -> bool {
    if !program_undefined_if_undef_or_poison(i, true) { return false; }
    let b = ss.len;
    for k in nops(i) {
        let o = op(i, k);
        if sc_is_scevable(vals[o].ty) { let s = sc_get_scev(o); ss.push(s); }
    }
    let d = sc_get_defining_scope_bound(b, ss_n(b));
    ss.resize(b);
    return sc_guaranteed_transfer_to(d, i);
}

// isAddRecNeverPoison
recursive fn sc_is_addrec_never_poison(i: i32, l: i32) -> bool {
    if sc_is_scev_expr_never_poison(i) { return true; }
    let exiting = loop_exiting_block(l);
    if exiting < 0 || !sc_loop_has_no_abnormal_exits(l) { return false; }
    // KnownPoison: scratch set VS_ANA1 (handleGuaranteedNonPoisonOps reads it); Worklist on sc_tmp
    vs_clear(VS_ANA1);
    vs_add(VS_ANA1, i);
    let wm = sc_tmp.len;
    sc_tmp.push(i);
    while sc_tmp.len > wm {
        let p = sc_tmp.pop();
        var u = vals[p].first_use;
        while u >= 0 {
            let pu = uses[u].user;
            let k = (u - vals[pu].ops) as i64;
            if well_defined_ops_contain(pu, true, -1, true) && dt_dominates_block(DT_DOM, inst_parent(pu), exiting) {
                sc_tmp.resize(wm);
                return true;
            }
            if propagates_poison(pu, k) && loop_contains(l, inst_parent(pu)) {
                if vs_add(VS_ANA1, pu) { sc_tmp.push(pu); }
            }
            u = uses[u].next;
        }
    }
    return false;
}

recursive fn loop_exiting_block(l: i32) -> i32 {
    var r: i32 = -1;
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        if loop_is_exiting(l, bb) { if r >= 0 { return -1; } r = bb; }
    }
    return r;
}

// getLoopProperties: bit 0 HasNoAbnormalExits, bit 1 HasNoSideEffects
var sc_loop_props = hm_new();
recursive fn sc_loop_properties(l: i32) -> i64 {
    let c = hm_get(sc_loop_props, l as u64, -1);
    if c >= 0 { return c; }
    var abn = true;
    var side = true;
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        var i = block_first(bb);
        while i >= 0 {
            if !guaranteed_to_transfer(i) { abn = false; }
            if sc_has_side_effects(i) { side = false; }
            if !abn && !side { break; }
            i = inst_next(i);
        }
        if !abn && !side { break; }
    }
    let r = (if abn { 1 } else { 0 }) | (if side { 2 } else { 0 });
    hm_put(sc_loop_props, l as u64, r);
    return r;
}
recursive fn sc_has_side_effects(i: i32) -> bool {
    if iop(i) == OP_STORE { return !ldst_is_unordered(i) || inst_is_volatile(i); }
    if inst_may_throw(i) { return true; }
    if is_mem_intrinsic_id(inst_iid(i)) && !inst_is_volatile(i) { return false; }
    return inst_may_write_memory(i);
}
recursive fn sc_loop_has_no_abnormal_exits(l: i32) -> bool { (sc_loop_properties(l) & 1) != 0 }
recursive fn sc_loop_has_no_side_effects(l: i32) -> bool { (sc_loop_properties(l) & 2) != 0 }

// ---------------------------------------------------------------------------------------------
// SCEVRewriteVisitor subclasses

let RW_INIT = 0;          // SCEVInitRewriter
let RW_POSTINC = 1;       // SCEVPostIncRewriter
let RW_BECOND = 2;        // SCEVBackedgeConditionFolder
let RW_SHIFT = 3;         // SCEVShiftRewriter
let RW_LOOP_ADDREC = 4;   // SCEVLoopAddRecRewriter (map in sc_rw_map: loop -> value)
let RW_GUARDS = 5;        // applyLoopGuards' rewriter (scev_btc.goose)
let RW_PREDICATE = 6;     // SCEVPredicateRewriter

struct RW { kind: i32, l: i32, serial: i32, seen_variant: bool, seen_other: bool, valid: bool, becond: i32, pos: bool }
var sc_rw_cache = hm_new();
var sc_rw_serial: i32 = 0;

recursive fn rw_new(kind: i64, l: i32) -> RW {
    sc_rw_serial++;
    return RW { kind: kind as i32, l: l, serial: sc_rw_serial, seen_variant: false, seen_other: false, valid: true, becond: -1, pos: false };
}

// SCEVRewriteVisitor::visit (with RewriteResults)
recursive fn sc_rw_visit(rw: RW&, s: i32) -> i32 {
    let key = hk2(rw.serial, s);
    let c = hm_get(sc_rw_cache, key, -1);
    if c >= 0 { return c as i32; }
    let r = sc_rw_visit_impl(rw, s);
    hm_put(sc_rw_cache, key, r as i64);
    return r;
}

recursive fn sc_rw_visit_impl(rw: RW&, s: i32) -> i32 {
    let k = sc_kind(s);
    if k == SC_CONST || k == SC_VSCALE || k == SC_CNC { return s; }
    if k == SC_UNKNOWN { return sc_rw_visit_unknown(rw, s); }
    if k == SC_ADDREC && (rw.kind as i64 == RW_INIT || rw.kind as i64 == RW_POSTINC || rw.kind as i64 == RW_SHIFT) {
        if rw.kind as i64 == RW_INIT {
            if sc_loop(s) == rw.l { return sc_op(s, 0); }
            rw.seen_other = true;
            return s;
        }
        if rw.kind as i64 == RW_POSTINC {
            if sc_loop(s) == rw.l { return sc_get_post_inc(s); }
            rw.seen_other = true;
            return s;
        }
        if sc_loop(s) == rw.l && sc_is_affine(s) { return sc_minus(s, sc_get_step_recurrence(s)); }
        rw.valid = false;
        return s;
    }
    if rw.kind as i64 == RW_GUARDS { return sc_guards_visit(rw, s); }
    if rw.kind as i64 == RW_PREDICATE && (k == SC_ZEXT || k == SC_SEXT) { return sc_rw_predicate_ext(rw, s); }
    return sc_rw_default(rw, s);
}

// The default SCEVRewriteVisitor visit* for non-leaf nodes
recursive fn sc_rw_default(rw: RW&, s: i32) -> i32 {
    let k = sc_kind(s);
    if sc_is_cast_kind(k) {
        let o = sc_rw_visit(rw, sc_op(s, 0));
        if o == sc_op(s, 0) { return s; }
        if k == SC_PTRTOADDR { return sc_get_ptr_to_addr(o); }
        if k == SC_PTRTOINT { return sc_get_ptr_to_int(o, sc_ty(s)); }
        if k == SC_TRUNC { return sc_get_truncate(o, sc_ty(s), 0); }
        if k == SC_ZEXT { return sc_get_zero_extend(o, sc_ty(s), 0); }
        return sc_get_sign_extend(o, sc_ty(s), 0);
    }
    if k == SC_UDIV {
        let l = sc_rw_visit(rw, sc_op(s, 0));
        let r = sc_rw_visit(rw, sc_op(s, 1));
        if l == sc_op(s, 0) && r == sc_op(s, 1) { return s; }
        return sc_get_udiv(l, r);
    }
    let b = ss.len;
    var changed = false;
    for i in sc_nops(s) {
        let x = sc_rw_visit(rw, sc_op(s, i));
        ss.push(x);
        if x != sc_op(s, i) { changed = true; }
    }
    if !changed { ss.resize(b); return s; }
    if k == SC_ADD { return sc_add_n(b, SF_ANY, 0); }
    if k == SC_MUL { return sc_mul_n(b, SF_ANY, 0); }
    if k == SC_ADDREC { return sc_addrec_n(b, sc_loop(s), sc_flags(s)); }
    if k == SC_SEQUMIN { return sc_seq_minmax_n(SC_SEQUMIN, b); }
    return sc_minmax_n(k, b);
}

recursive fn sc_rw_visit_unknown(rw: RW&, s: i32) -> i32 {
    let kind = rw.kind as i64;
    if kind == RW_INIT || kind == RW_POSTINC {
        if !sc_is_loop_invariant(s, rw.l) { rw.seen_variant = true; }
        return s;
    }
    if kind == RW_SHIFT {
        if !sc_is_loop_invariant(s, rw.l) { rw.valid = false; }
        return s;
    }
    if kind == RW_BECOND {
        if sc_is_loop_invariant(s, rw.l) { return s; }
        let i = sc_value(s);
        if iop(i) == OP_SELECT {
            let c = op(i, 0);
            if rw.becond == c {
                return sc_get_scev(if rw.pos { op(i, 1) } else { op(i, 2) });
            }
            return s;
        }
        if rw.becond == i { return if rw.pos { sc_get_one(ty_int(1)) } else { sc_get_zero(ty_int(1)) }; }
        return s;
    }
    if kind == RW_LOOP_ADDREC { return s; }
    return sc_rw_visit_unknown_ext(rw, s);
}

// SCEVInitRewriter::rewrite
recursive fn sc_rewrite_init(s: i32, l: i32, ignore_other_loops: bool) -> i32 {
    var rw = rw_new(RW_INIT, l);
    let r = sc_rw_visit(rw, s);
    if rw.seen_variant { return SCEV_CNC; }
    return if rw.seen_other && !ignore_other_loops { SCEV_CNC } else { r };
}
// SCEVPostIncRewriter::rewrite
recursive fn sc_rewrite_post_inc(s: i32, l: i32) -> i32 {
    var rw = rw_new(RW_POSTINC, l);
    let r = sc_rw_visit(rw, s);
    return if rw.seen_variant { SCEV_CNC } else { r };
}
// SCEVShiftRewriter::rewrite
recursive fn sc_rewrite_shift(s: i32, l: i32) -> i32 {
    var rw = rw_new(RW_SHIFT, l);
    let r = sc_rw_visit(rw, s);
    return if rw.valid { r } else { SCEV_CNC };
}
// SCEVBackedgeConditionFolder::rewrite
recursive fn sc_rewrite_becond(s: i32, l: i32) -> i32 {
    var becond: i32 = -1;
    var pos = false;
    let latch = loop_latch(l);
    if latch >= 0 {
        let bi = block_last(latch);
        if iop(bi) == OP_CONDBR {
            becond = op(bi, 0);
            pos = term_succ(bi, 0) == loop_header(l);
        } else { return s; }
    }
    var rw = rw_new(RW_BECOND, l);
    rw.becond = becond;
    rw.pos = pos;
    return sc_rw_visit(rw, s);
}

// ---------------------------------------------------------------------------------------------
// PHIs

// The (BEValueV, StartValueV) of a loop header PHI, or (-1, -1)
recursive fn sc_phi_be_and_start(pn: i32, l: i32) -> i32, i32 {
    var bev: i32 = -1;
    var stv: i32 = -1;
    for i in phi_nincoming(pn) {
        let v = phi_value(pn, i);
        if loop_contains(l, phi_block(pn, i)) {
            if bev < 0 { bev = v; } else if bev != v { bev = -1; break; }
        } else if stv < 0 { stv = v; }
        else if stv != v { stv = -1; break; }
    }
    return bev, stv;
}

// Loop::isLoopInvariant(Value)
recursive fn sc_value_loop_invariant(l: i32, v: i32) -> bool { !is_inst(v) || !loop_contains(l, inst_parent(v)) }

// createSimpleAffineAddRec
recursive fn sc_create_simple_affine_addrec(pn: i32, bev: i32, stv: i32) -> i32 {
    let l = li_loop_for(inst_parent(pn));
    let bo = sc_match_binary_op(bev);
    if bo.opc != OP_ADD { return -1; }
    var accum: i32 = -1;
    if bo.lhs == pn && sc_value_loop_invariant(l, bo.rhs) { accum = sc_get_scev(bo.rhs); }
    else if bo.rhs == pn && sc_value_loop_invariant(l, bo.lhs) { accum = sc_get_scev(bo.lhs); }
    if accum < 0 { return -1; }
    var f = SF_ANY;
    if bo.nuw { f |= SF_NUW; }
    if bo.nsw { f |= SF_NSW; }
    let sv = sc_get_scev(stv);
    let phis = sc_addrec2(sv, accum, l, f);
    sc_insert_value_to_map(pn, phis);
    if sc_is_addrec(phis) { sc_infer_nowrap_via_constant_ranges(phis); }
    if is_inst(bev) {
        if sc_is_addrec_never_poison(bev, l) { let x = sc_addrec2(sc_add(sv, accum), accum, l, f); }
    }
    return phis;
}

// createAddRecFromPHI
recursive fn sc_create_addrec_from_phi(pn: i32) -> i32 {
    let l = li_loop_for(inst_parent(pn));
    if l < 0 || loop_header(l) != inst_parent(pn) { return -1; }
    let bev, stv = sc_phi_be_and_start(pn, l);
    if bev < 0 || stv < 0 { return -1; }
    {
        let s = sc_create_simple_affine_addrec(pn, bev, stv);
        if s >= 0 { return s; }
    }
    let sym = sc_get_unknown(pn);
    sc_insert_value_to_map(pn, sym);
    let be = sc_get_scev(bev);
    if sc_kind(be) == SC_ADD {
        let add = be;
        var found = sc_nops(add);
        for i in sc_nops(add) { if sc_op(add, i) == sym { found = i; break; } }
        if found != sc_nops(add) {
            let b = ss.len;
            for i in sc_nops(add) { if i != found { let x = sc_rewrite_becond(sc_op(add, i), l); ss.push(x); } }
            let accum = sc_add_n(b, SF_ANY, 0);
            if sc_is_loop_invariant(accum, l) || (sc_is_addrec(accum) && sc_loop(accum) == l) {
                var f = SF_ANY;
                let bo = sc_match_binary_op(bev);
                if bo.opc >= 0 {
                    if bo.opc == OP_ADD && bo.lhs == pn {
                        if bo.nuw { f |= SF_NUW; }
                        if bo.nsw { f |= SF_NSW; }
                    }
                } else if sc_is_operator(bev) && opcode_of(bev) == OP_GEP {
                    if op(bev, 0) == pn {
                        let nw = gep_flags(bev);
                        if nw != 0 { f |= SF_NW; }
                        if (nw & GEP_NUW) != 0 || ((nw & (GEP_NUSW | GEP_INBOUNDS)) != 0 && sc_is_known_non_negative(accum)) { f |= SF_NUW; }
                    }
                }
                let sv = sc_get_scev(stv);
                let phis = sc_addrec2(sv, accum, l, f);
                sc_forget_memoized(sym);
                sc_insert_value_to_map(pn, phis);
                if sc_is_addrec(phis) { sc_infer_nowrap_via_constant_ranges(phis); }
                if is_inst(bev) {
                    if sc_is_loop_invariant(accum, l) && sc_is_addrec_never_poison(bev, l) { let x = sc_addrec2(sc_add(sv, accum), accum, l, f); }
                }
                return phis;
            }
        }
    } else {
        let shifted = sc_rewrite_shift(be, l);
        let start = sc_rewrite_init(shifted, l, false);
        if shifted != SCEV_CNC && start != SCEV_CNC && sc_is_guaranteed_not_to_cause_ub(shifted) && sc_implies_poison(shifted, start) {
            let sv = sc_get_scev(stv);
            if start == sv {
                sc_forget_memoized(sym);
                sc_insert_value_to_map(pn, shifted);
                return shifted;
            }
        }
    }
    sc_erase_value_from_map(pn);
    return -1;
}

// createNodeForPHIWithIdenticalOperands
recursive fn sc_create_node_for_phi_identical(pn: i32) -> i32 {
    let ci = sc_get_common_inst_for_phi(pn);
    if ci < 0 { return -1; }
    let cs = sc_get_scev(ci);
    for k in 1..phi_nincoming(pn) { if cs != sc_get_scev(phi_value(pn, k)) { return -1; } }
    return cs;
}

// createNodeFromSelectLikePHI
recursive fn sc_create_node_from_select_like_phi(pn: i32) -> i32 {
    let ok, c, l, r = sc_operands_for_select_like_phi(pn);
    if ok && sc_properly_dominates(sc_get_scev(l), inst_parent(pn)) && sc_properly_dominates(sc_get_scev(r), inst_parent(pn)) {
        return sc_create_node_for_select_or_phi(pn, c, l, r);
    }
    return -1;
}

recursive fn sc_create_node_for_phi(pn: i32) -> i32 {
    {
        let s = sc_create_addrec_from_phi(pn);
        if s >= 0 { return s; }
    }
    {
        let v = sc_simplify_phi(pn);
        if v >= 0 { return sc_get_scev(v); }
    }
    {
        let s = sc_create_node_for_phi_identical(pn);
        if s >= 0 { return s; }
    }
    {
        let s = sc_create_node_from_select_like_phi(pn);
        if s >= 0 { return s; }
    }
    return sc_get_unknown(pn);
}

// SCEVMinMaxExprContains(Root, OperandToFind, scSequentialUMinExpr)
recursive fn sc_minmax_expr_contains(root: i32, x: i32) -> bool {
    let mark = sc_seen.len;
    let r = sc_mmc_walk(root, x, mark);
    sc_seen.resize(mark);
    return r;
}
recursive fn sc_mmc_walk(s: i32, x: i32, mark: i64) -> bool {
    for k in mark..sc_seen.len { if sc_seen[k] == s { return false; } }
    sc_seen.push(s);
    if s == x { return true; }
    let k = sc_kind(s);
    if !(k == SC_SEQUMIN || k == SC_UMIN || k == SC_ZEXT) { return false; }
    for i in sc_nops(s) { if sc_mmc_walk(sc_op(s, i), x, mark) { return true; } }
    return false;
}

// createNodeForSelectOrPHIInstWithICmpInstCond: -1 = std::nullopt
recursive fn sc_create_node_select_icmp(ty: i32, ici: i32, tv0: i32, fv0: i32) -> i32 {
    var lhs = op(ici, 0);
    var rhs = op(ici, 1);
    var tv = tv0;
    var fv = fv0;
    let p = inst_pred(ici);
    if p == P_SLT || p == P_SLE || p == P_ULT || p == P_ULE || p == P_SGT || p == P_SGE || p == P_UGT || p == P_UGE {
        if p == P_SLT || p == P_SLE || p == P_ULT || p == P_ULE { let t = lhs; lhs = rhs; rhs = t; }
        if sc_type_bits(vals[lhs].ty) <= sc_type_bits(ty) {
            let signed = p == P_SLT || p == P_SLE || p == P_SGT || p == P_SGE;
            let la = sc_get_scev(tv);
            let ra = sc_get_scev(fv);
            var ls = sc_get_scev(lhs);
            var rs = sc_get_scev(rhs);
            if sc_is_ptr(la) {
                if la == ls && ra == rs { return if signed { sc_smax(ls, rs) } else { sc_umax(ls, rs) }; }
                if la == rs && ra == ls { return if signed { sc_smin(ls, rs) } else { sc_umin(ls, rs) }; }
            }
            ls = sc_coerce_operand(ls, ty, signed);
            rs = sc_coerce_operand(rs, ty, signed);
            if sc_is_cnc(ls) || sc_is_cnc(rs) { return -1; }
            var ld = sc_minus(la, ls);
            var rd = sc_minus(ra, rs);
            if ld == rd { return sc_add(if signed { sc_smax(ls, rs) } else { sc_umax(ls, rs) }, ld); }
            ld = sc_minus(la, rs);
            rd = sc_minus(ra, ls);
            if ld == rd { return sc_add(if signed { sc_smin(ls, rs) } else { sc_umin(ls, rs) }, ld); }
        }
        return -1;
    }
    if p == P_NE || p == P_EQ {
        if p == P_NE { let t = tv; tv = fv; fv = t; }
        if sc_type_bits(vals[lhs].ty) <= sc_type_bits(ty) && sc_cint_is_zero(rhs) {
            let x = sc_get_noop_or_zero_extend(sc_get_scev(lhs), ty);
            let tve = sc_get_scev(tv);
            let fve = sc_get_scev(fv);
            let y = sc_minus(fve, x);
            let c = sc_minus(tve, y);
            if sc_is_const(c) && ap_ule(sc_ap(c), ap_u64(1, sc_bits(c))) { return sc_add(sc_umax(x, c), y); }
        }
        if sc_cint_is_zero(rhs) && sc_cint_is_zero(tv) {
            var x = sc_get_scev(lhs);
            while sc_kind(x) == SC_ZEXT { x = sc_op(x, 0); }
            if sc_bits(x) <= sc_type_bits(ty) {
                let fve = sc_get_scev(fv);
                if sc_minmax_expr_contains(fve, x) { return sc_umin_seq(sc_get_noop_or_zero_extend(x, ty), fve); }
            }
        }
    }
    return -1;
}

recursive fn sc_coerce_operand(o0: i32, ty: i32, signed: bool) -> i32 {
    var o = o0;
    if sc_is_ptr(o) {
        o = sc_get_lossless_ptr_to_int(o);
        if sc_is_cnc(o) { return o; }
    }
    if signed { return sc_get_noop_or_sign_extend(o, ty); }
    return sc_get_noop_or_zero_extend(o, ty);
}

// createNodeForSelectViaUMinSeq(SE, CondExpr, TrueExpr, FalseExpr)
recursive fn sc_select_via_umin_seq(cond0: i32, te: i32, fe: i32) -> i32 {
    if !sc_is_const(te) && !sc_is_const(fe) { return -1; }
    var cond = cond0;
    var x: i32 = -1;
    var c: i32 = -1;
    if sc_is_const(te) { cond = sc_get_not(cond); x = fe; c = te; } else { x = te; c = fe; }
    return sc_add(c, sc_umin_seq(cond, sc_minus(x, c)));
}

recursive fn sc_create_node_for_select_or_phi_via_umin_seq(v: i32, c: i32, tv: i32, fv: i32) -> i32 {
    if !(ty_is_int(vals[v].ty) && ty_bits(vals[v].ty) == 1) { return sc_get_unknown(v); }
    if sc_is_cint(tv) || sc_is_cint(fv) {
        let sc = sc_get_scev(c);
        let st = sc_get_scev(tv);
        let sf = sc_get_scev(fv);
        let r = sc_select_via_umin_seq(sc, st, sf);
        if r >= 0 { return r; }
    }
    return sc_get_unknown(v);
}

recursive fn sc_create_node_for_select_or_phi(v: i32, c: i32, tv: i32, fv: i32) -> i32 {
    if sc_is_cint(c) { return sc_get_scev(if ap_is_one(ap_from_cint(c)) { tv } else { fv }); }
    if is_inst(v) && sc_is_icmp(c) {
        let s = sc_create_node_select_icmp(vals[v].ty, c, tv, fv);
        if s >= 0 { return s; }
    }
    return sc_create_node_for_select_or_phi_via_umin_seq(v, c, tv, fv);
}

recursive fn sc_create_node_for_gep(g: i32) -> i32 {
    let b = ss.len;
    for k in 1..nops(g) { let s = sc_get_scev(op(g, k)); ss.push(s); }
    let base = sc_get_scev(op(g, 0));
    var nw = gep_flags(g);
    if nw != 0 {
        if !is_inst(g) || !sc_is_scev_expr_never_poison(g) { nw = 0; }
    }
    let nusw = (nw & (GEP_NUSW | GEP_INBOUNDS)) != 0;
    let nuw = (nw & GEP_NUW) != 0;
    return sc_get_gep_expr(base, b, gep_src_ty(g), nusw, nuw);
}

// ---------------------------------------------------------------------------------------------
// createSCEV

recursive fn sc_create_scev(v: i32) -> i32 {
    if !sc_is_scevable(vals[v].ty) { return sc_get_unknown(v); }
    let k = vals[v].kind as i64;
    if k == VK_INST {
        if !dt_has_node(DT_DOM, inst_parent(v)) { return sc_get_unknown(c_poison(vals[v].ty)); }
    } else if k == VK_CINT { return sc_get_constant_v(v); }
    else if k == VK_ALIAS { return sc_get_unknown(v); }
    else if k != VK_CEXPR { return sc_get_unknown(v); }
    var bo = sc_match_binary_op(v);
    if bo.opc >= 0 {
        let o = bo.opc;
        if o == OP_ADD {
            let b = ss.len;
            loop {
                if bo.op >= 0 {
                    let e = sc_get_existing(bo.op);
                    if e >= 0 { ss.push(e); break; }
                    let r = sc_get_scev(bo.rhs);
                    let f = sc_get_nowrap_flags_from_ub(bo.op);
                    if f != SF_ANY {
                        let l = sc_get_scev(bo.lhs);
                        if bo.opc == OP_SUB { let x = sc_get_minus(l, r, f, 0); ss.push(x); }
                        else { let x = sc_add2(l, r, f, 0); ss.push(x); }
                        break;
                    }
                }
                if bo.opc == OP_SUB { let x = sc_get_negative(sc_get_scev(bo.rhs), SF_ANY); ss.push(x); }
                else { let x = sc_get_scev(bo.rhs); ss.push(x); }
                let nb = sc_match_binary_op(bo.lhs);
                if nb.opc < 0 || (nb.opc != OP_ADD && nb.opc != OP_SUB) { let x = sc_get_scev(bo.lhs); ss.push(x); break; }
                bo = nb;
            }
            return sc_add_n(b, SF_ANY, 0);
        }
        if o == OP_MUL {
            let b = ss.len;
            loop {
                if bo.op >= 0 {
                    let e = sc_get_existing(bo.op);
                    if e >= 0 { ss.push(e); break; }
                    let f = sc_get_nowrap_flags_from_ub(bo.op);
                    if f != SF_ANY {
                        let l = sc_get_scev(bo.lhs);
                        let r = sc_get_scev(bo.rhs);
                        let x = sc_mul2(l, r, f, 0);
                        ss.push(x);
                        break;
                    }
                }
                let x = sc_get_scev(bo.rhs);
                ss.push(x);
                let nb = sc_match_binary_op(bo.lhs);
                if nb.opc < 0 || nb.opc != OP_MUL { let y = sc_get_scev(bo.lhs); ss.push(y); break; }
                bo = nb;
            }
            return sc_mul_n(b, SF_ANY, 0);
        }
        if o == OP_UDIV { let l = sc_get_scev(bo.lhs); let r = sc_get_scev(bo.rhs); return sc_get_udiv(l, r); }
        if o == OP_UREM { let l = sc_get_scev(bo.lhs); let r = sc_get_scev(bo.rhs); return sc_get_urem(l, r); }
        if o == OP_SUB {
            var f = SF_ANY;
            if bo.op >= 0 { f = sc_get_nowrap_flags_from_ub(bo.op); }
            let l = sc_get_scev(bo.lhs);
            let r = sc_get_scev(bo.rhs);
            return sc_get_minus(l, r, f, 0);
        }
        if o == OP_AND {
            if sc_is_cint(bo.rhs) {
                let a = ap_from_cint(bo.rhs);
                if ap_is_zero(a) { return sc_get_scev(bo.rhs); }
                if ap_is_all_ones(a) { return sc_get_scev(bo.lhs); }
                let lz = ap_countl_zero(a);
                let tz = ap_countr_zero(a);
                let bw = a.w as i64;
                let known = sc_compute_known_bits_ap(bo.lhs);
                let em = ap_shl(ap_low_bits(bw, bw - lz - tz), tz);
                if (lz != 0 || tz != 0) && ap_is_zero(ap_and(ap_and(ap_not(a), ap_not(known.z)), em)) {
                    let mc = sc_get_constant(ap_one_bit(bw, tz));
                    let lhs = sc_get_scev(bo.lhs);
                    var shifted: i32 = -1;
                    if sc_kind(lhs) == SC_MUL && sc_is_const(sc_op(lhs, 0)) {
                        let opc = sc_ap(sc_op(lhs, 0));
                        let mz = ap_countr_zero(opc);
                        let g = if mz < tz { mz } else { tz };
                        let da = ap_one_bit(bw, tz - g);
                        let mb = ss.len;
                        ss.push(sc_get_constant(ap_ashr(opc, g)));
                        for i in 1..sc_nops(lhs) { ss.push(sc_op(lhs, i)); }
                        let nm = sc_mul_n(mb, sc_flags(lhs) & (SF_NUW | SF_NSW), 0);
                        shifted = sc_get_udiv(nm, sc_get_constant(da));
                    }
                    if shifted < 0 { shifted = sc_get_udiv(lhs, mc); }
                    return sc_mul(sc_get_zero_extend(sc_get_truncate(shifted, ty_int(bw - lz - tz), 0), vals[bo.lhs].ty, 0), mc);
                }
            }
            if ty_is_int(vals[bo.lhs].ty) && ty_bits(vals[bo.lhs].ty) == 1 {
                let l = sc_get_scev(bo.lhs);
                let r = sc_get_scev(bo.rhs);
                return sc_umin(l, r);
            }
        } else if o == OP_OR {
            if ty_is_int(vals[bo.lhs].ty) && ty_bits(vals[bo.lhs].ty) == 1 {
                let l = sc_get_scev(bo.lhs);
                let r = sc_get_scev(bo.rhs);
                return sc_umax(l, r);
            }
        } else if o == OP_XOR {
            if sc_is_cint(bo.rhs) {
                let ci = ap_from_cint(bo.rhs);
                if ap_is_all_ones(ci) { return sc_get_not(sc_get_scev(bo.lhs)); }
                let lbo = bo.lhs;
                if sc_is_binary_operator(lbo) && sc_is_cint(op(lbo, 1)) && iop(lbo) == OP_AND && ap_eq(ap_from_cint(op(lbo, 1)), ci) {
                    let z = sc_get_scev(bo.lhs);
                    if sc_kind(z) == SC_ZEXT {
                        let uty = vals[bo.lhs].ty;
                        let z0 = sc_op(z, 0);
                        let z0s = sc_bits(z0);
                        if ap_eq(ci, ap_low_bits(ci.w as i64, z0s)) { return sc_get_zero_extend(sc_get_not(z0), uty, 0); }
                        let tr = ap_trunc(ci, z0s);
                        if ap_eq(ap_zext(tr, sc_type_bits(uty)), ci) && ap_eq(tr, ap_smin_val(z0s)) {
                            return sc_get_zero_extend(sc_add(z0, sc_get_constant(tr)), uty, 0);
                        }
                    }
                }
            }
        } else if o == OP_SHL {
            if sc_is_cint(bo.rhs) {
                let sa = ap_from_cint(bo.rhs);
                let bw = sa.w as i64;
                if !ap_uge_u64(sa, bw as u64) {
                    var f = SF_ANY;
                    if bo.op >= 0 {
                        let mf = sc_get_nowrap_flags_from_ub(bo.op);
                        if (mf & SF_NSW) != 0 && ((mf & SF_NUW) != 0 || ap_ult_u64(sa, (bw - 1) as u64)) { f |= SF_NSW; }
                        if (mf & SF_NUW) != 0 { f |= SF_NUW; }
                    }
                    let x = sc_get_constant(ap_one_bit(bw, ap_lo64(sa) as i64));
                    return sc_mul2(sc_get_scev(bo.lhs), x, f, 0);
                }
            }
        } else if o == OP_ASHR {
            if sc_is_cint(bo.rhs) {
                let ci = ap_from_cint(bo.rhs);
                let outer = vals[bo.lhs].ty;
                let bw = sc_type_bits(outer);
                if !ap_uge_u64(ci, bw as u64) {
                    if ap_is_zero(ci) { return sc_get_scev(bo.lhs); }
                    let amt = ap_lo64(ci) as i64;
                    let trty = ty_int(bw - amt);
                    let l = bo.lhs;
                    var ate: i32 = -1;
                    var shl_amt: i32 = -1;
                    var addc: i32 = -1;
                    let lop = if sc_is_operator(l) { opcode_of(l) } else { -1 };
                    if lop == OP_ADD {
                        let lsh = op(l, 0);
                        let aoc = op(l, 1);
                        if sc_is_operator(lsh) && opcode_of(lsh) == OP_SHL {
                            if sc_is_cint(aoc) {
                                let s0 = sc_get_scev(op(lsh, 0));
                                shl_amt = if sc_is_cint(op(lsh, 1)) { op(lsh, 1) } else { -1 };
                                let ao = ap_ashr(ap_from_cint(aoc), amt);
                                addc = sc_get_constant(ap_trunc(ao, bw - amt));
                                ate = sc_get_truncate(s0, trty, 0);
                            }
                        }
                    } else if lop == OP_SHL {
                        let s0 = sc_get_scev(op(l, 0));
                        shl_amt = if sc_is_cint(op(l, 1)) { op(l, 1) } else { -1 };
                        ate = sc_get_truncate(s0, trty, 0);
                    }
                    if ate >= 0 && shl_amt >= 0 {
                        let sh = ap_from_cint(shl_amt);
                        if ap_ult_u64(sh, bw as u64) && ap_uge_u64(sh, amt as u64) {
                            let mul = ap_one_bit(bw - amt, (ap_lo64(sh) as i64) - amt);
                            var comp = sc_mul(ate, sc_get_constant(mul));
                            if lop != OP_SHL { comp = sc_add(comp, addc); }
                            return sc_get_sign_extend(comp, outer, 0);
                        }
                    }
                }
            }
        }
    }
    let o = opcode_of(v);
    if o == OP_TRUNC { return sc_get_truncate(sc_get_scev(op(v, 0)), vals[v].ty, 0); }
    if o == OP_ZEXT { return sc_get_zero_extend(sc_get_scev(op(v, 0)), vals[v].ty, 0); }
    if o == OP_SEXT {
        let b2 = sc_match_binary_op(op(v, 0));
        if b2.opc == OP_SUB && b2.nsw {
            let t = vals[v].ty;
            let v1 = sc_get_sign_extend(sc_get_scev(b2.lhs), t, 0);
            let v2 = sc_get_sign_extend(sc_get_scev(b2.rhs), t, 0);
            return sc_get_minus(v1, v2, SF_NSW, 0);
        }
        return sc_get_sign_extend(sc_get_scev(op(v, 0)), vals[v].ty, 0);
    }
    if o == OP_BITCAST {
        if sc_is_scevable(vals[v].ty) && sc_is_scevable(vals[op(v, 0)].ty) { return sc_get_scev(op(v, 0)); }
        return sc_get_unknown(v);
    }
    if o == OP_PTRTOADDR {
        let io = sc_get_ptr_to_addr(sc_get_scev(op(v, 0)));
        if sc_is_cnc(io) { return sc_get_unknown(v); }
        return io;
    }
    if o == OP_PTRTOINT {
        let so = sc_get_scev(op(v, 0));
        let io = sc_get_ptr_to_int(so, vals[v].ty);
        if sc_is_cnc(io) { return sc_get_unknown(v); }
        return io;
    }
    if o == OP_INTTOPTR { return sc_get_unknown(v); }
    if o == OP_SDIV {
        if sc_is_known_non_negative(sc_get_scev(op(v, 0))) && sc_is_known_non_negative(sc_get_scev(op(v, 1))) {
            return sc_get_udiv(sc_get_scev(op(v, 0)), sc_get_scev(op(v, 1)));
        }
        return sc_get_unknown(v);
    }
    if o == OP_SREM {
        if sc_is_known_non_negative(sc_get_scev(op(v, 0))) && sc_is_known_non_negative(sc_get_scev(op(v, 1))) {
            return sc_get_urem(sc_get_scev(op(v, 0)), sc_get_scev(op(v, 1)));
        }
        return sc_get_unknown(v);
    }
    if o == OP_GEP { return sc_create_node_for_gep(v); }
    if o == OP_PHI { return sc_create_node_for_phi(v); }
    if o == OP_SELECT { return sc_create_node_for_select_or_phi(v, op(v, 0), op(v, 1), op(v, 2)); }
    if o == OP_CALL || o == OP_INVOKE {
        let rv = returned_arg_operand(v);
        if rv >= 0 { return sc_get_scev(rv); }
        let id = inst_iid(v);
        if id == IID_abs { return sc_get_abs(sc_get_scev(cb_arg(v, 0)), ap_is_one(ap_from_cint(cb_arg(v, 1)))); }
        if id == IID_umax { let l = sc_get_scev(cb_arg(v, 0)); let r = sc_get_scev(cb_arg(v, 1)); return sc_umax(l, r); }
        if id == IID_umin { let l = sc_get_scev(cb_arg(v, 0)); let r = sc_get_scev(cb_arg(v, 1)); return sc_umin(l, r); }
        if id == IID_smax { let l = sc_get_scev(cb_arg(v, 0)); let r = sc_get_scev(cb_arg(v, 1)); return sc_smax(l, r); }
        if id == IID_smin { let l = sc_get_scev(cb_arg(v, 0)); let r = sc_get_scev(cb_arg(v, 1)); return sc_smin(l, r); }
        if id == IID_usub_sat {
            let x = sc_get_scev(cb_arg(v, 0));
            let y = sc_get_scev(cb_arg(v, 1));
            let cy = sc_umin(x, y);
            return sc_get_minus(x, cy, SF_NUW, 0);
        }
        if id == IID_uadd_sat {
            let x = sc_get_scev(cb_arg(v, 0));
            let y = sc_get_scev(cb_arg(v, 1));
            let cx = sc_umin(x, sc_get_not(y));
            return sc_add2(cx, y, SF_NUW, 0);
        }
        if id == IID_start_loop_iterations || id == IID_annotation || id == IID_ptr_annotation { return sc_get_scev(cb_arg(v, 0)); }
        if id == IID_vscale { return sc_get_vscale(vals[v].ty); }
    }
    return sc_get_unknown(v);
}

// inferNoWrapViaConstantRanges
recursive fn sc_infer_nowrap_via_constant_ranges(ar: i32) {
    if !sc_is_affine(ar) { return; }
    if !sc_has_nsw(ar) { let r = sc_get_signed_range(ar); }
    if !sc_has_nuw(ar) { let r = sc_get_unsigned_range(ar); }
    if !sc_has_nw(ar) {
        let bec = sc_get_constant_max_backedge_taken_count(sc_loop(ar));
        if sc_is_const(bec) {
            let scr = sc_get_signed_range(sc_get_step_recurrence(ar));
            let nobw = ap_active_bits(sc_ap(bec)) + rg_min_signed_bits(scr);
            if nobw <= sc_bits(ar) { sc_or_flags(ar, SF_NW); }
        }
    }
}

// proveNoSignedWrapViaInduction
recursive fn sc_prove_no_signed_wrap_via_induction(ar: i32) -> u32 {
    var res = sc_flags(ar);
    if sc_has_nsw(ar) || !sc_is_affine(ar) { return res; }
    sc_side2_grow();
    if sc_side2[ar].swit { return res; }
    sc_side2[ar].swit = true;
    let step = sc_get_step_recurrence(ar);
    let l = sc_loop(ar);
    let maxbe = sc_get_constant_max_backedge_taken_count(l);
    if sc_is_cnc(maxbe) && !sc_has_guards && !sc_has_assumptions() { return res; }
    let lim, pred = sc_overflow_limit_for_step(step, true);
    if lim >= 0 && (sc_is_loop_backedge_guarded_by_cond(l, pred, ar, lim) || sc_is_known_on_every_iteration(pred, ar, lim)) { res |= SF_NSW; }
    return res;
}

// proveNoUnsignedWrapViaInduction
recursive fn sc_prove_no_unsigned_wrap_via_induction(ar: i32) -> u32 {
    var res = sc_flags(ar);
    if sc_has_nuw(ar) || !sc_is_affine(ar) { return res; }
    sc_side2_grow();
    if sc_side2[ar].uwit { return res; }
    sc_side2[ar].uwit = true;
    let step = sc_get_step_recurrence(ar);
    let bw = sc_bits(ar);
    let l = sc_loop(ar);
    let maxbe = sc_get_constant_max_backedge_taken_count(l);
    if sc_is_cnc(maxbe) && !sc_has_guards && !sc_has_assumptions() { return res; }
    if sc_is_known_positive(step) {
        let n = sc_get_constant(ap_sub(ap_zero(bw), sc_get_unsigned_range_max(step)));
        if sc_is_loop_backedge_guarded_by_cond(l, P_ULT, ar, n) || sc_is_known_on_every_iteration(P_ULT, ar, n) { res |= SF_NUW; }
    }
    return res;
}
