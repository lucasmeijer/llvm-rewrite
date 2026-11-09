// Reassociate: port of llvm/lib/Transforms/Scalar/Reassociate.cpp (+ include/llvm/Transforms/Scalar/Reassociate.h,
// OverflowTracking from llvm/lib/Transforms/Utils/Local.cpp, mayHaveNonDefUseDependency from ValueTracking.cpp).
//
// ReassociatePass's members are globals (`ra_*`), reset per function:
//   RankMap / ValueRankMap   HMaps keyed by value id. Both are read with DenseMap::operator[], which inserts a 0
//                            entry; `ValueRankMap.contains` (EraseInst) sees those entries, so ra_vrm_get inserts.
//   RedoInsts (OrderedSet = SetVector over a deque): `ra_redo` (items, -1 = removed, `ra_redo_head` = deque front)
//                            + `ra_redo_ix` (membership). ToRedo is a second instance (`ra_tor`, `ra_tor_ix`).
//   PairMap[opcode]          one HMap keyed by (opcode, id, id); ids are canonicalized by value (LLVM: std::less on
//                            pointers; only membership and counts are read). Its WeakVH validity test can't fail
//                            for a lookup of live values because ids are never reused.
// Recursion: OptimizeExpression's tail call is a loop; EmitAddTreeOfValues and FindSingleUseMultiplyFactors are
// iterative with the same visiting order; buildMinimalMultiplyDAG and getNegatibleInsts keep their vectors on
// global stacks with marks (Goose forbids growable locals across a recursive call).
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import local;
import salvage;
import pm;
import vt;
import knownbits;
import overflow;
import constfold;
import cfold;
import apint;
import fpu;
import speculate;
import instident;
import wvh;
import scev;
import stdsort;
import flags;

struct RaVE { rank: u32, op: i32 }           // reassociate::ValueEntry
struct RaRV { v: i32, w: u64 }               // RepeatedValue
struct RaFactor { base: i32, power: u32 }    // reassociate::Factor

var ra_rank_map = hm_new();
var ra_vrm = hm_new();
var ra_redo: i32[>..<];
var ra_redo_head: i64 = 0;
var ra_redo_ix = hm_new();
var ra_tor: i32[>..<];
var ra_tor_ix = hm_new();
var ra_pairs = hm_new();
var ra_made_change: bool = false;
var ra_fv: i32 = -1;
let RA_GLOBAL_REASSOCIATE_LIMIT = 10;

// LinearizeExprTree's Leaves map (never live twice)
var ra_leaves = hm_new();
// global stacks for the recursive helpers
var ra_dag_outer: i32[>..<];
var ra_dag_inner: i32[>..<];
var ra_neg_cands: i32[>..<];

fn ra_fail(msg: const u8[:]) { fatal(str("reassociate: ", msg, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// OrderedSet

fn rs_insert(items: i32[>..<]&, ix: HMap&, v: i32) {
    if hm_has(ix, v as u64) { return; }
    hm_put(ix, v as u64, items.len);
    items.push(v);
}
fn rs_remove(items: i32[>..<]&, ix: HMap&, v: i32) {
    let p = hm_get(ix, v as u64, -1);
    if p < 0 { return; }
    items[p] = -1;
    hm_del(ix, v as u64);
}
fn rs_empty(ix: HMap&) -> bool { ix.n == 0 }
fn rs_pop_back(items: i32[>..<]&, ix: HMap&) -> i32 {
    while items.len > 0 && items[items.len - 1] < 0 { items.pop(); }
    let v = items.pop();
    hm_del(ix, v as u64);
    return v;
}
fn redo_insert(v: i32) { rs_insert(ra_redo, ra_redo_ix, v); }
fn redo_remove(v: i32) { rs_remove(ra_redo, ra_redo_ix, v); }
fn redo_pop_front() -> i32 {
    while ra_redo[ra_redo_head] < 0 { ra_redo_head++; }
    let v = ra_redo[ra_redo_head];
    ra_redo[ra_redo_head] = -1;
    ra_redo_head++;
    hm_del(ra_redo_ix, v as u64);
    if ra_redo_ix.n == 0 { ra_redo.resize(0); ra_redo_head = 0; }
    return v;
}

// ---------------------------------------------------------------------------------------------
// Small helpers

fn ra_vrm_get(v: i32) -> u32 {
    let j = hm_find(ra_vrm, v as u64);
    if j >= 0 { return ra_vrm.slots[j].val as u32; }
    hm_put(ra_vrm, v as u64, 0);
    return 0;
}
fn ra_rm_get(b: i32) -> u32 {
    let j = hm_find(ra_rank_map, b as u64);
    if j >= 0 { return ra_rank_map.slots[j].val as u32; }
    hm_put(ra_rank_map, b as u64, 0);
    return 0;
}

// Value::hasOneUse (ConstantData has no use list)
fn ra_one_use(v: i32) -> bool { if is_constant_data(v) { return false; } let u = vals[v].first_use; return u >= 0 && uses[u].next < 0; }
fn ra_user_back(v: i32) -> i32 { uses[vals[v].first_use].user }
fn ra_is_binop(v: i32) -> bool { is_inst(v) && is_binary_op(iop(v)) }
fn ra_is_unop(v: i32) -> bool { is_inst(v) && iop(v) == OP_FNEG }
// isa<ConstantInt>: also a vector-typed splat ConstantInt (-use-constant-int-for-*-splat)
fn ra_isa_cint(v: i32) -> bool { vals[v].kind == VK_CINT }
// isa<ConstantFP>: a scalar, or a vector splat (ConstantVector::getSplat gives a ConstantFP). Scalable FP
// splats are shufflevector constant expressions here (c_splat), ConstantFPs in LLVM.
fn ra_isa_cfp(v: i32) -> bool {
    if (vals[v].kind == VK_CFP && !ty_is_vector(vals[v].ty)) || c_is_vector_cfp(v) { return true; }
    let ty = vals[v].ty;
    return types[ty].kind == TK_SVEC && ty_is_fp(types[ty].a) && vals[v].kind == VK_CEXPR && m_apfloat(v) >= 0;
}
// the scalar ConstantFP value of an isa<ConstantFP> constant
fn ra_cfp_scalar(v: i32) -> i32 {
    if !ty_is_vector(vals[v].ty) { return v; }
    let s = m_apfloat(v);
    if s < 0 { return c_null(ty_scalar(vals[v].ty)); }   // the FP zero vector
    return s;
}
fn ra_fp_is_neg(c: i32) -> bool { cfp_parts(c).neg }
fn ra_fp_neg(c: i32, ty: i32) -> i32 { let lo, hi = fp_neg_bits(cfp_kind(c), cint_lo(c), cint_hi(c)); return c_fp_bits_ty(ty, lo, hi); }
fn ra_fp_abs(c: i32, ty: i32) -> i32 { let lo, hi = fp_with_sign(cfp_kind(c), cint_lo(c), cint_hi(c), false); return c_fp_bits_ty(ty, lo, hi); }
fn ra_is_int_or_int_vec(t: i32) -> bool { ty_is_int(ty_scalar(t)) }
fn ra_is_commutative(o: i64) -> bool { o == OP_ADD || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_FADD || o == OP_FMUL }
// Instruction::isAssociative (binary operators)
fn ra_is_associative(i: i32) -> bool {
    let o = iop(i);
    if o == OP_ADD || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR { return true; }
    if o == OP_FADD || o == OP_FMUL { return ra_has_fp_assoc(i); }
    if is_intrinsic_inst(i) { ra_fail("Instruction::isAssociative of an intrinsic"); }
    return false;
}
fn ra_set_dl(i: i32, dl: i32) { if dl < 0 { inst_erase_md(i, 0); } else { inst_set_md(i, 0, dl); } }
fn ra_dl(i: i32) -> i32 { inst_get_md(i, 0) }
fn ra_fmf(i: i32) -> u8 { insts[inst_of(i)].fmf }
fn ra_set_fmf(i: i32, f: u8) { insts[inst_of(i)].fmf = f; }
fn ra_flags(i: i32) -> u8 { insts[inst_of(i)].flags }
fn ra_set_flag(i: i32, f: u8, on: bool) { let ii = inst_of(i); if on { insts[ii].flags |= f; } else { insts[ii].flags &= ~f; } }

// Value::takeName
fn ra_take_name(dst: i32, src: i32) {
    if dst == src { return; }
    if vals[dst].name >= 0 { set_name(dst, ""); }
    if vals[src].name < 0 { return; }
    var buf: u8[>..] = [];
    buf.append(sbytes(vals[src].name));
    set_name(src, "");
    set_name(dst, buf);
}
fn ra_name_plus(v: i32, suffix: const u8[:]) -> u8[>..] {
    var buf: u8[>..] = [];
    if vals[v].name >= 0 { buf.append(sbytes(vals[v].name)); }
    buf.append(suffix);
    return buf;
}

// hasFPAssociativeFlags
fn ra_has_fp_assoc(i: i32) -> bool { let f = ra_fmf(i); (f & FMF_REASSOC) != 0 && (f & FMF_NSZ) != 0 }

// isReassociableOp(V, Opcode[, Opcode2]); -1 = null
fn ra_reassociable2(v: i32, o1: i64, o2: i64) -> i32 {
    if !ra_is_binop(v) || !ra_one_use(v) { return -1; }
    let o = iop(v);
    if o != o1 && o != o2 { return -1; }
    if !is_fp_math_operator(v) || ra_has_fp_assoc(v) { return v; }
    return -1;
}
fn ra_reassociable(v: i32, o1: i64) -> i32 { ra_reassociable2(v, o1, o1) }

// isInstructionTriviallyDead(I) without a TargetLibraryInfo
fn ra_trivially_dead(i: i32) -> bool {
    local_have_tli = false;
    let r = is_instruction_trivially_dead(i);
    local_have_tli = true;
    return r;
}

// mayHaveNonDefUseDependency (ValueTracking.cpp)
fn ra_may_have_non_def_use_dependency(i: i32) -> bool {
    if inst_may_read_or_write_memory(i) { return true; }
    if !spec_safe(i, -1, false) { return true; }
    if !guaranteed_to_transfer(i) { return true; }
    return false;
}

// ValueTracking queries with SimplifyQuery(DL[, CxtI]) (no DT, AC, TLI)
var ra_save_cxt: i32 = -1;
var ra_save_dt: bool = false;
var ra_save_ac: bool = false;
var ra_save_tli: bool = false;
fn ra_sq_begin(cx: i32) {
    ra_save_cxt = kb_cxt; ra_save_dt = sq_no_dt; ra_save_ac = sq_no_ac; ra_save_tli = sq_no_tli;
    kb_cxt = cx; sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
}
fn ra_sq_end() { kb_cxt = ra_save_cxt; sq_no_dt = ra_save_dt; sq_no_ac = ra_save_ac; sq_no_tli = ra_save_tli; }
fn ra_known_non_negative(v: i32) -> bool {
    ra_sq_begin(-1);
    let r = kb_is_nonneg(kb_compute_all(v, 0));
    ra_sq_end();
    return r;
}
fn ra_known_non_zero(v: i32) -> bool {
    ra_sq_begin(-1);
    let r = is_known_non_zero(v, 0);
    ra_sq_end();
    return r;
}

// Constant::containsUndefOrPoisonElement
fn ra_contains_undef_or_poison_element(c: i32) -> bool {
    let ty = vals[c].ty;
    if !ty_is_vector(ty) { return false; }
    if is_undef_or_poison(c) { return true; }
    if vals[c].kind == VK_AGGZERO { return false; }
    if types[ty].kind == TK_SVEC { return false; }
    for k in types[ty].cnt as i64 {
        let e = agg_elem(c, k);
        if e >= 0 && is_undef_or_poison(e) { return true; }
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// OverflowTracking (Local.h / Local.cpp)

struct RaOT { nuw: bool, nsw: bool, disjoint: bool, nonneg: bool, nonzero: bool }
fn ra_ot_new() -> RaOT { RaOT { nuw: true, nsw: true, disjoint: true, nonneg: true, nonzero: true } }
fn ra_ot_merge(f: RaOT&, i: i32) {
    let o = iop(i);
    if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL {
        let fl = ra_flags(i);
        f.nuw = f.nuw && (fl & FL_NUW) != 0;
        f.nsw = f.nsw && (fl & FL_NSW) != 0;
    }
    if o == OP_OR { f.disjoint = f.disjoint && (ra_flags(i) & FL_DISJOINT) != 0; }
}
fn ra_ot_apply(f: RaOT, i: i32) {
    drop_poison_generating_flags(i);
    let o = iop(i);
    if o == OP_ADD || (o == OP_MUL && f.nonzero) {
        if f.nuw { ra_set_flag(i, FL_NUW, true); }
        if f.nsw && (f.nonneg || f.nuw) { ra_set_flag(i, FL_NSW, true); }
    }
    if o == OP_OR { ra_set_flag(i, FL_DISJOINT, f.disjoint); }
}

// ---------------------------------------------------------------------------------------------
// Instruction creation (BinaryOperator::Create(..., Name, InsertBefore = X->getIterator()))

fn ra_insert(i: i32, pos: i32, name: const u8[:]) -> i32 {
    inst_insert_before(i, pos);
    if name.len > 0 { set_name(i, name); }
    return i;
}
fn ra_new_binop(o: i64, a: i32, b: i32) -> i32 { create_inst(o, vals[a].ty, [a, b]) }
fn ra_create_add(s1: i32, s2: i32, name: const u8[:], pos: i32, flags_op: i32) -> i32 {
    if ra_is_int_or_int_vec(vals[s1].ty) { return ra_insert(ra_new_binop(OP_ADD, s1, s2), pos, name); }
    let r = ra_new_binop(OP_FADD, s1, s2);
    ra_set_fmf(r, ra_fmf(flags_op));
    return ra_insert(r, pos, name);
}
fn ra_create_mul(s1: i32, s2: i32, name: const u8[:], pos: i32, flags_op: i32) -> i32 {
    if ra_is_int_or_int_vec(vals[s1].ty) { return ra_insert(ra_new_binop(OP_MUL, s1, s2), pos, name); }
    let r = ra_new_binop(OP_FMUL, s1, s2);
    ra_set_fmf(r, ra_fmf(flags_op));
    return ra_insert(r, pos, name);
}
fn ra_create_neg(s1: i32, name: const u8[:], pos: i32, flags_op: i32) -> i32 {
    let ty = vals[s1].ty;
    if ra_is_int_or_int_vec(ty) { return ra_insert(create_inst(OP_SUB, ty, [c_null(ty), s1]), pos, name); }
    let r = create_inst(OP_FNEG, ty, [s1]);
    if is_inst(flags_op) { ra_set_fmf(r, ra_fmf(flags_op)); }
    return ra_insert(r, pos, name);
}

// IRBuilder<> Builder(I) (ConstantFolder; inserts before I with I's debug location)
var rb_pos: i32 = -1;
var rb_fmf: u8 = 0;
fn rb_binop(o: i64, a: i32, b: i32) -> i32 {
    if is_constant(a) && is_constant(b) {
        let c = binop_dispatch(o, a, b);
        if c >= 0 { return c; }
    }
    let r = ra_new_binop(o, a, b);
    if o == OP_FADD || o == OP_FSUB || o == OP_FMUL { ra_set_fmf(r, rb_fmf); }
    inst_insert_before(r, rb_pos);
    let dl = ra_dl(rb_pos);
    if dl >= 0 { inst_set_md(r, 0, dl); }
    return r;
}

// ---------------------------------------------------------------------------------------------
// Ranks

// BuildRankMap
fn ra_build_rank_map(fv: i32, rpot: const i32[:]) {
    var rank: u32 = 2;
    for k in func_nargs(fv) {
        rank++;
        hm_put(ra_vrm, func_arg(fv, k) as u64, rank as i64);
    }
    for bb in rpot {
        rank++;
        var bb_rank: u32 = rank << 16;
        hm_put(ra_rank_map, bb as u64, bb_rank as i64);
        var i = block_first(bb);
        while i >= 0 {
            if ra_may_have_non_def_use_dependency(i) {
                bb_rank++;
                hm_put(ra_vrm, i as u64, bb_rank as i64);
            }
            i = inst_next(i);
        }
    }
}

struct RaRankItem { v: i32, op_no: i64, rank: u32 }

// getRank (explicit worklist)
fn ra_get_rank(v: i32) -> u32 {
    var wl: RaRankItem[>..<] = [];
    wl.push(RaRankItem { v: v, op_no: 0, rank: 0 });
    loop {
        let t = wl.len - 1;
        let item = wl[t];
        let iv = item.v;
        var r: u32 = 0;
        if !is_inst(iv) {
            r = if is_arg(iv) { ra_vrm_get(iv) } else { 0 };
        } else {
            let known = ra_vrm_get(iv);
            if known != 0 {
                r = known;
            } else if item.op_no == nops(iv) || item.rank == ra_rm_get(inst_parent(iv)) {
                r = item.rank;
                if m_not(iv) < 0 && m_neg(iv) < 0 && m_fneg(iv) < 0 { r++; }
                hm_put(ra_vrm, iv as u64, r as i64);
            } else {
                wl.push(RaRankItem { v: op(iv, item.op_no), op_no: 0, rank: 0 });
                continue;
            }
        }
        wl.pop();
        if wl.len == 0 { return r; }
        let p = wl.len - 1;
        if r > wl[p].rank { wl[p].rank = r; }
        wl[p].op_no++;
    }
    return 0;
}

// canonicalizeOperands
fn ra_canonicalize_operands(i: i32) {
    let lhs = op(i, 0);
    let rhs = op(i, 1);
    if lhs == rhs || is_constant(rhs) { return; }
    if is_constant(lhs) || ra_get_rank(rhs) < ra_get_rank(lhs) {
        set_op(i, 0, rhs);
        set_op(i, 1, lhs);
        ra_made_change = true;
    }
}

// Instruction::swapOperands of a binary operator
fn ra_swap(i: i32) { let a = op(i, 0); let b = op(i, 1); set_op(i, 0, b); set_op(i, 1, a); }

// LowerNegateToMultiply: replace 0-X with X*-1
fn ra_lower_negate_to_multiply(neg: i32) -> i32 {
    let opno: i64 = if ra_is_binop(neg) { 1 } else { 0 };
    let ty = vals[neg].ty;
    let neg_one = if ra_is_int_or_int_vec(ty) { c_all_ones(ty) } else { c_fp_from_f64(ty, -1.0) };
    let res = ra_create_mul(op(neg, opno), neg_one, "", neg, neg);
    set_op(neg, opno, c_null(ty));
    ra_take_name(res, neg);
    rauw(neg, res);
    ra_set_dl(res, ra_dl(neg));
    return res;
}

// ---------------------------------------------------------------------------------------------
// LinearizeExprTree

struct RaWl { i: i32, w: u64 }

// to_tor: the ToRedo set is RedoInsts (false) or nothing else in LLVM (always RedoInsts)
fn ra_linearize_expr_tree(root: i32, ops: RaRV[>..<]&, f: RaOT&) -> bool {
    let opcode = iop(root);
    var wl: RaWl[>..<] = [];
    wl.push(RaWl { i: root, w: 1 });
    var changed = false;
    hm_clear(ra_leaves);
    var leaf_order: i32[>..<] = [];
    while wl.len > 0 {
        let top = wl.pop();
        let i = top.i;
        var weight = top.w;
        ra_ot_merge(f, i);
        var opi: i64 = 0;
        while opi < nops(i) {
            let o = op(i, opi);
            opi++;
            let bo = ra_reassociable(o, opcode);
            if bo >= 0 { wl.push(RaWl { i: bo, w: weight }); continue; }
            let j = hm_find(ra_leaves, o as u64);
            if j < 0 {
                if !ra_one_use(o) {
                    leaf_order.push(o);
                    hm_put(ra_leaves, o as u64, weight as i64);
                    continue;
                }
            } else {
                let nw = (ra_leaves.slots[j].val as u64) + weight;
                ra_leaves.slots[j].val = nw as i64;
                if !ra_one_use(o) { continue; }
                weight = nw;
                hm_del(ra_leaves, o as u64);
            }
            var is_neg = false;
            if opcode == OP_MUL { is_neg = m_neg(o) >= 0; }
            else if opcode == OP_FMUL { is_neg = m_fneg(o) >= 0; }
            if is_neg && is_inst(o) {
                let mul = ra_lower_negate_to_multiply(o);
                wl.push(RaWl { i: mul, w: weight });
                var u = vals[mul].first_use;
                while u >= 0 {
                    let us = uses[u].user;
                    if ra_is_binop(us) { redo_insert(us); }
                    u = uses[u].next;
                }
                redo_insert(o);
                changed = true;
                continue;
            }
            leaf_order.push(o);
            hm_put(ra_leaves, o as u64, weight as i64);
        }
    }
    for v in leaf_order {
        let j = hm_find(ra_leaves, v as u64);
        if j < 0 { continue; }
        let weight = ra_leaves.slots[j].val as u64;
        ra_leaves.slots[j].val = 0;
        ops.push(RaRV { v: v, w: weight });
        if opcode == OP_ADD && f.nonneg && f.nsw {
            f.nonneg = f.nonneg && ra_known_non_negative(v);
        } else if opcode == OP_MUL {
            if f.nonzero && (f.nuw || (f.nsw && f.nonneg)) {
                f.nonzero = f.nonzero && ra_known_non_zero(v);
                if f.nsw && f.nonneg { f.nonneg = f.nonneg && ra_known_non_negative(v); }
            }
        }
    }
    if ops.len == 0 {
        let id = binop_identity(opcode, vals[root].ty, false);
        if id < 0 { fatal("reassociate: associative operation without identity"); }
        ops.push(RaRV { v: id, w: 1 });
    }
    return changed;
}

fn ra_ops_from_tree(tree: const RaRV[:], out: RaVE[>..<]&) {
    for e in tree {
        let r = ra_get_rank(e.v);
        var k: u64 = 0;
        while k < e.w { out.push(RaVE { rank: r, op: e.v }); k++; }
    }
}

// ---------------------------------------------------------------------------------------------
// RewriteExprTree

fn ra_in(xs: const RaVE[:], v: i32) -> bool { for e in xs { if e.op == v { return true; } } return false; }

fn ra_rewrite_expr_tree(root: i32, ops: const RaVE[:], f: RaOT) {
    var nodes: i32[>..<] = [];
    let opcode = iop(root);
    var o = root;
    // NotRewritable: the future leaves (a hash set for long expressions)
    var nr = hm_new();
    let big = ops.len > 16;
    if big { for e in ops { hm_put(nr, e.op as u64, 1); } }
    fn not_rewritable(v: i32) -> bool { if big { return hm_has(nr, v as u64); } return ra_in(ops, v); }
    var cs: i32 = -1;
    var ce: i32 = -1;
    var i: i64 = 0;
    loop {
        if i + 2 == ops.len {
            let new_lhs = ops[i].op;
            let new_rhs = ops[i + 1].op;
            let old_lhs = op(o, 0);
            let old_rhs = op(o, 1);
            if new_lhs == old_lhs && new_rhs == old_rhs { break; }
            if new_lhs == old_rhs && new_rhs == old_lhs {
                ra_swap(o);
                ra_made_change = true;
                break;
            }
            if new_lhs != old_lhs {
                let bo = ra_reassociable(old_lhs, opcode);
                if bo >= 0 && !not_rewritable(bo) { nodes.push(bo); }
                salvage_debug_info(o);
                set_op(o, 0, new_lhs);
            }
            if new_rhs != old_rhs {
                let bo = ra_reassociable(old_rhs, opcode);
                if bo >= 0 && !not_rewritable(bo) { nodes.push(bo); }
                salvage_debug_info(o);
                set_op(o, 1, new_rhs);
            }
            cs = o;
            if ce < 0 { ce = o; }
            ra_made_change = true;
            break;
        }
        let new_rhs = ops[i].op;
        if new_rhs != op(o, 1) {
            if new_rhs == op(o, 0) {
                ra_swap(o);
            } else {
                let bo = ra_reassociable(op(o, 1), opcode);
                if bo >= 0 && !not_rewritable(bo) { nodes.push(bo); }
                salvage_debug_info(o);
                set_op(o, 1, new_rhs);
                cs = o;
                if ce < 0 { ce = o; }
            }
            ra_made_change = true;
        }
        let bo = ra_reassociable(op(o, 0), opcode);
        if bo >= 0 && !not_rewritable(bo) {
            o = bo;
            i++;
            continue;
        }
        var new_op: i32 = -1;
        if nodes.len == 0 {
            let p = c_poison(vals[root].ty);
            new_op = create_inst(opcode, vals[root].ty, [p, p]);
            inst_insert_before(new_op, root);
            if is_fp_math_operator(new_op) { ra_set_fmf(new_op, ra_fmf(root)); }
        } else {
            new_op = nodes.pop();
        }
        salvage_debug_info(o);
        set_op(o, 0, new_op);
        cs = o;
        if ce < 0 { ce = o; }
        ra_made_change = true;
        o = new_op;
        i++;
    }
    if cs >= 0 {
        var clear = true;
        loop {
            if clear {
                if is_fp_math_operator(root) { ra_set_fmf(cs, ra_fmf(root)); }
                else { ra_ot_apply(f, cs); }
            }
            if cs == ce { clear = false; }
            if cs == root { break; }
            inst_move_before(cs, root);
            cs = ra_user_back(cs);
        }
    }
    for n in nodes { redo_insert(n); }
}

// ---------------------------------------------------------------------------------------------
// NegateValue

// BasicBlock::getFirstInsertionPt
fn ra_first_insertion_pt(bb: i32) -> i32 {
    var i = block_first(bb);
    while i >= 0 && iop(i) == OP_PHI { i = inst_next(i); }
    if i >= 0 && inst_is_eh_pad(i) { i = inst_next(i); }
    return i;
}

recursive fn ra_negate_value(v: i32, bi: i32) -> i32 {
    if is_constant(v) {
        var res: i32 = -1;
        if ty_is_fp(ty_scalar(vals[v].ty)) { res = cf_unary(OP_FNEG, v); }
        else { res = ce_binop(OP_SUB, c_null(vals[v].ty), v, 0); }
        if res >= 0 { return res; }
    }
    let i = ra_reassociable2(v, OP_ADD, OP_FADD);
    if i >= 0 {
        let a = ra_negate_value(op(i, 0), bi);
        set_op(i, 0, a);
        let b = ra_negate_value(op(i, 1), bi);
        set_op(i, 1, b);
        if iop(i) == OP_ADD { ra_set_flag(i, FL_NUW, false); ra_set_flag(i, FL_NSW, false); }
        inst_move_before(i, bi);
        let nm = ra_name_plus(i, ".neg");
        set_name(i, nm);
        redo_insert(i);
        return i;
    }
    if has_use_list(v) {
        var u = vals[v].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if m_neg(us) < 0 && m_fneg(us) < 0 { continue; }
            let the_neg = us;
            if ra_is_binop(the_neg) && is_constant(op(the_neg, 0)) && ra_contains_undef_or_poison_element(op(the_neg, 0)) { continue; }
            if inst_func(the_neg) != inst_func(bi) { continue; }
            var pos: i32 = -1;
            var pbb: i32 = -1;
            var head = false;
            if is_inst(v) {
                let o = iop(v);
                if o == OP_PHI { pbb = inst_parent(v); pos = ra_first_insertion_pt(pbb); }
                else if o == OP_INVOKE { pbb = term_succ(v, 0); pos = ra_first_insertion_pt(pbb); }
                else if o == OP_CALLBR { continue; }
                else { pbb = inst_parent(v); pos = inst_next(v); }
                head = true;
                if pos < 0 { continue; }
            } else {
                pbb = func_entry(inst_func(the_neg));
                pos = block_first(pbb);
                while pos >= 0 && iop(pos) == OP_PHI { pos = inst_next(pos); }
                head = false;
            }
            if inst_parent(the_neg) != pbb { inst_erase_md(the_neg, 0); }
            inst_move_impl(the_neg, pbb, pos, head, false);
            if iop(the_neg) == OP_SUB { ra_set_flag(the_neg, FL_NUW, false); ra_set_flag(the_neg, FL_NSW, false); }
            else { ii_and_ir_flags(the_neg, bi); }
            redo_insert(the_neg);
            return the_neg;
        }
    }
    let nm = ra_name_plus(v, ".neg");
    let nn = ra_create_neg(v, nm, bi, bi);
    ra_set_dl(nn, ra_dl(bi));
    redo_insert(nn);
    return nn;
}

// ---------------------------------------------------------------------------------------------
// or / mul / sub / shl conversions

// isLoadCombineCandidate
fn ra_is_load_combine_candidate(orv: i32) -> bool {
    var wl: i32[>..<] = [];
    var visited = hm_new();
    fn enqueue(v: i32) -> bool {
        if !is_inst(v) { return false; }
        if !hm_has(visited, v as u64) { hm_put(visited, v as u64, 1); wl.push(v); }
        return true;
    }
    if !enqueue(orv) { return false; }
    while wl.len > 0 {
        let i = wl.pop();
        let o = iop(i);
        if o == OP_OR {
            for k in nops(i) { if !enqueue(op(i, k)) { return false; } }
            continue;
        }
        if o == OP_SHL || o == OP_ZEXT {
            if !enqueue(op(i, 0)) { return false; }
            continue;
        }
        if o == OP_LOAD { continue; }
        return false;
    }
    return true;
}

fn ra_interesting_for_or(v: i32) -> bool {
    return ra_reassociable(v, OP_ADD) >= 0 || ra_reassociable(v, OP_SUB) >= 0 || ra_reassociable(v, OP_MUL) >= 0 ||
           ra_reassociable(v, OP_SHL) >= 0;
}

// shouldConvertOrWithNoCommonBitsToAdd
fn ra_should_convert_or_to_add(orv: i32) -> bool {
    for k in nops(orv) { if ra_interesting_for_or(op(orv, k)) { return true; } }
    if vals[orv].first_use < 0 { return false; }   // user_back of an unused or: LLVM reads garbage only if
    let vb = ra_user_back(orv);                     // hasOneUse() is false, so the result is the same
    if ra_one_use(orv) && ra_interesting_for_or(vb) { return true; }
    return false;
}

// convertOrWithNoCommonBitsToAdd
fn ra_convert_or_to_add(orv: i32) -> i32 {
    let n = ra_create_add(op(orv, 0), op(orv, 1), "", orv, orv);
    ra_set_flag(n, FL_NSW, true);
    ra_set_flag(n, FL_NUW, true);
    ra_take_name(n, orv);
    rauw(orv, n);
    ra_set_dl(n, ra_dl(orv));
    return n;
}

// ShouldBreakUpDistribution
fn ra_should_break_up_distribution(mul: i32) -> bool {
    if !ra_one_use(mul) || !is_inst_op(mul, OP_MUL) { return false; }
    let l = op(mul, 0);
    if !ra_one_use(l) || !(is_inst_op(l, OP_ADD) || is_inst_op(l, OP_SUB)) { return false; }
    if !m_imm_constant(op(mul, 1)) { return false; }
    let a = op(l, 0);
    let b = op(l, 1);
    let mu = ra_user_back(mul);
    if iop(mu) != OP_ADD && iop(mu) != OP_SUB { return false; }
    for k in nops(mu) {
        let sib = op(mu, k);
        if sib == mul || !ra_one_use(sib) { continue; }
        if is_inst_op(sib, OP_MUL) && m_imm_constant(op(sib, 1)) {
            let nc = op(sib, 0);
            if (nc == a || nc == b) && !is_constant(nc) { return true; }
        }
    }
    return false;
}

// BreakUpDistribute
fn ra_break_up_distribute(mul: i32) -> i32 {
    let addsub = op(mul, 0);
    let c = op(mul, 1);
    let c2 = if iop(addsub) == OP_SUB { ce_binop(OP_SUB, c_null(vals[c].ty), c, 0) } else { c };
    let m1 = ra_insert(ra_new_binop(OP_MUL, op(addsub, 0), c), mul, "Mul1");
    let m2 = ra_insert(ra_new_binop(OP_MUL, op(addsub, 1), c2), mul, "Mul2");
    let res = ra_insert(ra_new_binop(OP_ADD, m1, m2), mul, "DistAdd");
    rauw(mul, res);
    ra_set_dl(res, ra_dl(mul));
    redo_insert(m1);
    redo_insert(m2);
    redo_insert(res);
    return res;
}

// ShouldBreakUpSubtract
fn ra_should_break_up_subtract(sub: i32) -> bool {
    if m_neg(sub) >= 0 || m_fneg(sub) >= 0 { return false; }
    if is_undef_or_poison(op(sub, 1)) { return false; }
    let v0 = op(sub, 0);
    if ra_reassociable2(v0, OP_ADD, OP_FADD) >= 0 || ra_reassociable2(v0, OP_SUB, OP_FSUB) >= 0 { return true; }
    let v1 = op(sub, 1);
    if ra_reassociable2(v1, OP_ADD, OP_FADD) >= 0 || ra_reassociable2(v1, OP_SUB, OP_FSUB) >= 0 { return true; }
    if !ra_one_use(sub) { return false; }
    let vb = ra_user_back(sub);
    if ra_reassociable2(vb, OP_ADD, OP_FADD) >= 0 || ra_reassociable2(vb, OP_SUB, OP_FSUB) >= 0 { return true; }
    return false;
}

// BreakUpSubtract
fn ra_break_up_subtract(sub: i32) -> i32 {
    let nv = ra_negate_value(op(sub, 1), sub);
    let n = ra_create_add(op(sub, 0), nv, "", sub, sub);
    set_op(sub, 0, c_null(vals[sub].ty));
    set_op(sub, 1, c_null(vals[sub].ty));
    ra_take_name(n, sub);
    rauw(sub, n);
    ra_set_dl(n, ra_dl(sub));
    return n;
}

// ConvertShiftToMul
fn ra_convert_shift_to_mul(shl: i32) -> i32 {
    let ty = vals[shl].ty;
    let sa = op(shl, 1);
    let mc = cf_binop(OP_SHL, c_int_ty(ty, 1), sa);
    if mc < 0 { fatal("reassociate: constant folding of immediate constants failed"); }
    let mul = ra_insert(ra_new_binop(OP_MUL, op(shl, 0), mc), shl, "");
    set_op(shl, 0, c_poison(ty));
    ra_take_name(mul, shl);
    rauw(shl, mul);
    ra_set_dl(mul, ra_dl(shl));
    let nsw = (ra_flags(shl) & FL_NSW) != 0;
    let nuw = (ra_flags(shl) & FL_NUW) != 0;
    let bw = ty_bits(ty_scalar(ty));
    if nsw && (nuw || ap_ult_u64(ci_ap(sa), (bw - 1) as u64)) { ra_set_flag(mul, FL_NSW, true); }
    ra_set_flag(mul, FL_NUW, nuw);
    return mul;
}

// Instruction::isIdenticalTo
fn ra_identical(a: i32, b: i32) -> bool {
    if !ii_is_identical_when_defined(a, b, false) { return false; }
    let x = insts[inst_of(a)];
    let y = insts[inst_of(b)];
    if x.flags != y.flags { return false; }
    if is_fp_math_operator(a) && x.fmf != y.fmf { return false; }
    return true;
}

// FindInOperandList
fn ra_find_in_operand_list(ops: const RaVE[:], i: i64, x: i32) -> i64 {
    let xr = ops[i].rank;
    var j = i + 1;
    while j < ops.len && ops[j].rank == xr {
        if ops[j].op == x { return j; }
        if is_inst(ops[j].op) && is_inst(x) && ra_identical(ops[j].op, x) { return j; }
        j++;
    }
    j = i - 1;
    while j >= 0 && ops[j].rank == xr {
        if ops[j].op == x { return j; }
        if is_inst(ops[j].op) && is_inst(x) && ra_identical(ops[j].op, x) { return j; }
        j--;
    }
    return i;
}

// ---------------------------------------------------------------------------------------------
// RemoveFactorFromExpression / FindSingleUseMultiplyFactors

fn ra_remove_factor_from_expression(v0: i32, factor: i32, dl: i32) -> i32 {
    let bo = ra_reassociable2(v0, OP_MUL, OP_FMUL);
    if bo < 0 { return -1; }
    var tree: RaRV[>..<] = [];
    var f = ra_ot_new();
    if ra_linearize_expr_tree(bo, tree, f) { ra_made_change = true; }
    var factors: RaVE[>..<] = [];
    ra_ops_from_tree(tree, factors);
    var found = false;
    var needs_negate = false;
    var k: i64 = 0;
    while k < factors.len {
        let fk = factors[k].op;
        if fk == factor { found = true; remove_at(factors, k); break; }
        if ra_isa_cint(factor) {
            if ra_isa_cint(fk) && ap_eq(ci_ap(factor), ap_neg(ci_ap(fk))) {
                found = true; needs_negate = true; remove_at(factors, k); break;
            }
        } else if ra_isa_cfp(factor) {
            if ra_isa_cfp(fk) {
                let a = ra_cfp_scalar(factor);
                let b = ra_cfp_scalar(fk);
                let kind = cfp_kind(a);
                let nlo, nhi = fp_neg_bits(kind, cint_lo(b), cint_hi(b));
                if fp_compare(kind, cint_lo(a), cint_hi(a), nlo, nhi) == 1 {
                    found = true; needs_negate = true; remove_at(factors, k); break;
                }
            }
        }
        k++;
    }
    if !found {
        ra_rewrite_expr_tree(bo, factors, f);
        return -1;
    }
    let ipt = inst_next(bo);
    var v = v0;
    if factors.len == 1 {
        redo_insert(bo);
        v = factors[0].op;
    } else {
        ra_rewrite_expr_tree(bo, factors, f);
        v = bo;
    }
    if needs_negate {
        v = ra_create_neg(v, "neg", ipt, bo);
        ra_set_dl(v, dl);
    }
    return v;
}

fn ra_find_single_use_multiply_factors(v: i32, out: i32[>..<]&) {
    var stk: i32[>..<] = [];
    stk.push(v);
    while stk.len > 0 {
        let x = stk.pop();
        let bo = ra_reassociable2(x, OP_MUL, OP_FMUL);
        if bo < 0 { out.push(x); continue; }
        stk.push(op(bo, 0));
        stk.push(op(bo, 1));
    }
}

// ---------------------------------------------------------------------------------------------
// OptimizeAndOrXor / OptimizeXor

fn ra_optimize_and_or_xor(opcode: i64, ops: RaVE[>..<]&) -> i32 {
    var i: i64 = 0;
    var e = ops.len;
    while i != e {
        let x = m_not(ops[i].op);
        if x >= 0 {
            let fx = ra_find_in_operand_list(ops, i, x);
            if fx != i {
                if opcode == OP_AND { return c_null(vals[x].ty); }
                if opcode == OP_OR { return c_all_ones(vals[x].ty); }
            }
        }
        if i + 1 != ops.len && ops[i + 1].op == ops[i].op {
            if opcode == OP_AND || opcode == OP_OR {
                remove_at(ops, i);
                e--;
                continue;   // --i; ++i
            }
            if e == 2 { return c_null(vals[ops[0].op].ty); }
            remove_at(ops, i);
            remove_at(ops, i);
            e -= 2;
            continue;       // i -= 1; ++i
        }
        i++;
    }
    return -1;
}

struct RaXor { orig: i32, sym: i32, cpart: AP, rank: u32, is_or: bool }

// XorOpnd::XorOpnd(V)
fn ra_xor_opnd(v: i32) -> RaXor {
    if is_inst(v) && (iop(v) == OP_OR || iop(v) == OP_AND) {
        var v0 = op(v, 0);
        var v1 = op(v, 1);
        if m_apint(v0) >= 0 { let t = v0; v0 = v1; v1 = t; }
        let c = m_apint(v1);
        if c >= 0 { return RaXor { orig: v, sym: v0, cpart: ci_ap(c), rank: 0, is_or: iop(v) == OP_OR }; }
    }
    return RaXor { orig: v, sym: v, cpart: ap_zero(ty_bits(ty_scalar(vals[v].ty))), rank: 0, is_or: true };
}

// createAndInstr
fn ra_create_and_instr(pos: i32, opnd: i32, c: AP) -> i32 {
    if ap_is_zero(c) { return -1; }
    if ap_is_all_ones(c) { return opnd; }
    let i = ra_insert(ra_new_binop(OP_AND, opnd, c_int_ap(vals[opnd].ty, c)), pos, "and.ra");
    ra_set_dl(i, ra_dl(pos));
    return i;
}

fn ra_optimize_xor(root: i32, ops: RaVE[>..<]&) -> i32 {
    let v = ra_optimize_and_or_xor(OP_XOR, ops);
    if v >= 0 { return v; }
    if ops.len == 1 { return -1; }
    var opnds: RaXor[>..<] = [];
    let ty = vals[ops[0].op].ty;
    var cst = ap_zero(ty_bits(ty_scalar(ty)));
    for e in ops {
        let c = m_apint(e.op);
        if c >= 0 { cst = ap_xor(cst, ci_ap(c)); }
        else {
            var o = ra_xor_opnd(e.op);
            o.rank = ra_get_rank(o.sym);
            opnds.push(o);
        }
    }
    var ptrs: i64[>..<] = [];
    for k in opnds.len { ptrs.push(k); }
    std_stable_sort(ptrs, 0, ptrs.len) { a, b => opnds[a].rank < opnds[b].rank };
    var prev: i64 = -1;
    var changed = false;
    for k in opnds.len {
        let cur = ptrs[k];
        // Step 3.1: CurrOpnd ^ ConstOpnd (CombineXorOpnd with one operand)
        if !ap_is_zero(cst) {
            let o1 = opnds[cur];
            if o1.is_or && !ap_is_zero(o1.cpart) && ra_one_use(o1.orig) && ap_eq(o1.cpart, cst) {
                let cv = ra_create_and_instr(root, o1.sym, ap_not(o1.cpart));
                cst = ap_xor(cst, o1.cpart);
                if is_inst(o1.orig) { redo_insert(o1.orig); }
                changed = true;
                if cv >= 0 { opnds[cur] = ra_xor_opnd(cv); }
                else { opnds[cur].sym = -1; opnds[cur].orig = -1; continue; }
            }
        }
        if prev < 0 || opnds[cur].sym != opnds[prev].sym { prev = cur; continue; }
        // Step 3.2: PrevOpnd ^ CurrOpnd ^ ConstOpnd (CombineXorOpnd(It, CurrOpnd, PrevOpnd, ...))
        var o1i = cur;
        var o2i = prev;
        let x = opnds[o1i].sym;
        var dead: i64 = 1;
        if ra_one_use(opnds[o1i].orig) { dead++; }
        if ra_one_use(opnds[o2i].orig) { dead++; }
        var ok = true;
        var cv: i32 = -1;
        if opnds[o1i].is_or != opnds[o2i].is_or {
            if opnds[o2i].is_or { let t = o1i; o1i = o2i; o2i = t; }
            let c1 = opnds[o1i].cpart;
            let c2 = opnds[o2i].cpart;
            let c3 = ap_xor(ap_not(c1), c2);
            if !ap_is_zero(c3) && !ap_is_all_ones(c3) {
                let ni: i64 = if !ap_is_zero(cst) { 1 } else { 2 };
                if ni > dead { ok = false; }
            }
            if ok { cv = ra_create_and_instr(root, x, c3); cst = ap_xor(cst, c1); }
        } else if opnds[o1i].is_or {
            let c3 = ap_xor(opnds[o1i].cpart, opnds[o2i].cpart);
            if !ap_is_zero(c3) && !ap_is_all_ones(c3) {
                let ni: i64 = if !ap_is_zero(cst) { 1 } else { 2 };
                if ni > dead { ok = false; }
            }
            if ok { cv = ra_create_and_instr(root, x, c3); cst = ap_xor(cst, c3); }
        } else {
            let c3 = ap_xor(opnds[o1i].cpart, opnds[o2i].cpart);
            cv = ra_create_and_instr(root, x, c3);
        }
        if ok {
            if is_inst(opnds[o1i].orig) { redo_insert(opnds[o1i].orig); }
            if is_inst(opnds[o2i].orig) { redo_insert(opnds[o2i].orig); }
            opnds[prev].sym = -1; opnds[prev].orig = -1;
            if cv >= 0 { opnds[cur] = ra_xor_opnd(cv); prev = cur; }
            else { opnds[cur].sym = -1; opnds[cur].orig = -1; prev = -1; }
            changed = true;
        }
    }
    if changed {
        ops.resize(0);
        for o in opnds {
            if o.sym < 0 { continue; }
            ops.push(RaVE { rank: ra_get_rank(o.orig), op: o.orig });
        }
        if !ap_is_zero(cst) {
            let c = c_int_ap(ty, cst);
            ops.push(RaVE { rank: ra_get_rank(c), op: c });
        }
        if ops.len == 1 { return ops[0].op; }
        if ops.len == 0 { return c_int_ap(ty, cst); }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// OptimizeAdd

fn ra_better_factor(fac: i32, maxv: i32, occ: u32, maxocc: u32) -> bool {
    if occ > maxocc { return true; }
    return occ == maxocc && (is_inst(fac) || is_arg(fac)) && is_constant(maxv) && !is_undef_or_poison(maxv);
}

fn ra_optimize_add(root: i32, ops: RaVE[>..<]&) -> i32 {
    var i: i64 = 0;
    var e = ops.len;
    while i != e {
        let the_op = ops[i].op;
        if i + 1 != ops.len && ops[i + 1].op == the_op {
            var num: u64 = 0;
            loop {
                remove_at(ops, i);
                num++;
                if !(i != ops.len && ops[i].op == the_op) { break; }
            }
            let ty = vals[the_op].ty;
            let c = if ra_is_int_or_int_vec(ty) { c_int_ap(ty, ap_u64(num, ty_bits(ty_scalar(ty)))) } else { c_fp_from_f64(ty, num as f64) };
            let mul = ra_create_mul(the_op, c, "factor", root, root);
            ra_set_dl(mul, ra_dl(root));
            redo_insert(mul);
            if ops.len == 0 { return mul; }
            insert_at(ops, 0, RaVE { rank: ra_get_rank(mul), op: mul });
            e = ops.len;
            continue;   // --i; ++i
        }
        let xn = m_neg(the_op);
        let xt = m_not(the_op);
        let xf = m_fneg(the_op);
        var x: i32 = -1;
        if xn >= 0 { x = xn; } else if xt >= 0 { x = xt; } else if xf >= 0 { x = xf; }
        if x < 0 { i++; continue; }
        var fx = ra_find_in_operand_list(ops, i, x);
        if fx == i { i++; continue; }
        if ops.len == 2 && (xn >= 0 || xf >= 0) { return c_null(vals[x].ty); }
        if ops.len == 2 && xt >= 0 { return c_all_ones(vals[x].ty); }
        remove_at(ops, i);
        if i < fx { fx--; } else { i--; }
        remove_at(ops, fx);
        i--;
        e -= 2;
        if xt >= 0 {
            let v = c_all_ones(vals[x].ty);
            ops.push(RaVE { rank: ra_get_rank(v), op: v });
            e++;
        }
        i++;
    }

    var occ_map = hm_new();
    var max_occ: u32 = 0;
    var max_occ_val: i32 = -1;
    fn bump(fac: i32) {
        let occ = (hm_get(occ_map, fac as u64, 0) + 1) as u32;
        hm_put(occ_map, fac as u64, occ as i64);
        if ra_better_factor(fac, max_occ_val, occ, max_occ) { max_occ = occ; max_occ_val = fac; }
    }
    for en in ops {
        let bop = ra_reassociable2(en.op, OP_MUL, OP_FMUL);
        if bop < 0 { continue; }
        var factors: i32[>..<] = [];
        ra_find_single_use_multiply_factors(bop, factors);
        var dups: i32[>..<] = [];
        fn dup_insert(v: i32) -> bool { for d in dups { if d == v { return false; } } dups.push(v); return true; }
        for fac0 in factors {
            var fac = fac0;
            if !dup_insert(fac) { continue; }
            bump(fac);
            if ra_isa_cint(fac) {
                let a = ci_ap(fac);
                if ap_is_neg(a) && !ap_is_min_signed(a) {
                    fac = c_int_ap(vals[fac].ty, ap_neg(a));
                    if !dup_insert(fac) { continue; }
                    bump(fac);
                }
            } else if ra_isa_cfp(fac) {
                let s = ra_cfp_scalar(fac);
                if ra_fp_is_neg(s) {
                    fac = ra_fp_neg(s, vals[fac].ty);
                    if !dup_insert(fac) { continue; }
                    bump(fac);
                }
            }
        }
    }
    if max_occ > 1 {
        let dummy = create_inst(if ra_is_int_or_int_vec(vals[root].ty) { OP_ADD } else { OP_FADD }, vals[max_occ_val].ty,
                                [max_occ_val, max_occ_val]);
        let mark = wvh_mark();
        var new_mul_ops: i32[>..<] = [];    // WeakTrackingVH handles
        var j: i64 = 0;
        while j != ops.len {
            let bop = ra_reassociable2(ops[j].op, OP_MUL, OP_FMUL);
            if bop < 0 { j++; continue; }
            let v = ra_remove_factor_from_expression(ops[j].op, max_occ_val, ra_dl(root));
            if v >= 0 {
                let target = ops[j].op;
                var m = ops.len;
                while m != j {
                    m--;
                    if ops[m].op == target {
                        new_mul_ops.push(wvh_new(v, WVH_WEAK_TRACKING));
                        remove_at(ops, m);
                    }
                }
                continue;   // --i; ++i
            }
            j++;
        }
        drop_all_refs(dummy);
        val_set_dead(dummy);
        // EmitAddTreeOfValues: ((Ops[0] + Ops[1]) + Ops[2]) + ..., innermost first
        var v = wvh_get(new_mul_ops[0]);
        for k in 1..new_mul_ops.len {
            let na = ra_create_add(v, wvh_get(new_mul_ops[k]), "reass.add", root, root);
            ra_set_dl(na, ra_dl(root));
            v = na;
        }
        wvh_release(mark);
        if is_inst(v) { redo_insert(v); }
        let v2 = ra_create_mul(v, max_occ_val, "reass.mul", root, root);
        ra_set_dl(v2, ra_dl(root));
        redo_insert(v2);
        if ops.len == 0 { return v2; }
        insert_at(ops, 0, RaVE { rank: ra_get_rank(v2), op: v2 });
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// OptimizeMul

fn ra_collect_multiply_factors(ops: RaVE[>..<]&, factors: RaFactor[>..<]&) -> bool {
    var sum: u32 = 0;
    var idx: i64 = 1;
    let size = ops.len;
    while idx < size {
        let o = ops[idx - 1].op;
        var count: u32 = 1;
        while idx < size && ops[idx].op == o { count++; idx++; }
        if count > 1 { sum += count; }
        idx++;
    }
    if sum < 4 { return false; }
    idx = 1;
    while idx < ops.len {
        let o = ops[idx - 1].op;
        var count: u32 = 1;
        while idx < ops.len && ops[idx].op == o { count++; idx++; }
        if count == 1 { idx++; continue; }
        count &= 0xFFFFFFFE;
        idx -= count as i64;
        factors.push(RaFactor { base: o, power: count });
        for c in count as i64 { remove_at(ops, idx); }
        idx++;
    }
    std_stable_sort(factors, 0, factors.len) { a, b => a.power > b.power };
    return true;
}

fn rb_mul(l: i32, r: i32) -> i32 {
    if ra_is_int_or_int_vec(vals[l].ty) { return rb_binop(OP_MUL, l, r); }
    return rb_binop(OP_FMUL, l, r);
}

// buildMultiplyTree over ra_dag_outer/ra_dag_inner[b..]: pops from the back, consumes the run
fn ra_build_multiply_tree_inner(b: i64) -> i32 {
    if ra_dag_inner.len - b == 1 { return ra_dag_inner.pop(); }
    var lhs = ra_dag_inner.pop();
    loop {
        let r = ra_dag_inner.pop();
        lhs = rb_mul(lhs, r);
        if ra_dag_inner.len == b { break; }
    }
    return lhs;
}
fn ra_build_multiply_tree_outer(b: i64) -> i32 {
    if ra_dag_outer.len - b == 1 { return ra_dag_outer.pop(); }
    var lhs = ra_dag_outer.pop();
    loop {
        let r = ra_dag_outer.pop();
        lhs = rb_mul(lhs, r);
        if ra_dag_outer.len == b { break; }
    }
    return lhs;
}

recursive fn ra_build_minimal_multiply_dag(factors: RaFactor[>..<]&) -> i32 {
    let ob = ra_dag_outer.len;
    var last: i64 = 0;
    var idx: i64 = 1;
    let size = factors.len;
    while idx < size && factors[idx].power > 0 {
        if factors[idx].power != factors[last].power { last = idx; idx++; continue; }
        let ib = ra_dag_inner.len;
        ra_dag_inner.push(factors[last].base);
        loop {
            ra_dag_inner.push(factors[idx].base);
            idx++;
            if !(idx < size && factors[idx].power == factors[last].power) { break; }
        }
        let m = ra_build_multiply_tree_inner(ib);
        factors[last].base = m;
        if is_inst(m) { redo_insert(m); }
        last = idx;
        idx++;
    }
    // llvm::unique by equal power
    if factors.len > 0 {
        var w: i64 = 1;
        for k in 1..factors.len {
            if factors[k].power == factors[w - 1].power { continue; }
            factors[w] = factors[k];
            w++;
        }
        factors.resize(w);
    }
    for k in factors.len {
        if (factors[k].power & 1) != 0 { ra_dag_outer.push(factors[k].base); }
        factors[k].power = factors[k].power >> 1;
    }
    if factors[0].power != 0 {
        let sq = ra_build_minimal_multiply_dag(factors);
        ra_dag_outer.push(sq);
        ra_dag_outer.push(sq);
    }
    if ra_dag_outer.len - ob == 1 { return ra_dag_outer.pop(); }
    return ra_build_multiply_tree_outer(ob);
}

fn ra_optimize_mul(root: i32, ops: RaVE[>..<]&) -> i32 {
    if ops.len < 4 { return -1; }
    var factors: RaFactor[>..<] = [];
    if !ra_collect_multiply_factors(ops, factors) { return -1; }
    rb_pos = root;
    rb_fmf = if is_fp_math_operator(root) { ra_fmf(root) } else { 0 };
    let v = ra_build_minimal_multiply_dag(factors);
    if ops.len == 0 { return v; }
    let ne = RaVE { rank: ra_get_rank(v), op: v };
    var pos: i64 = 0;
    while pos < ops.len && ops[pos].rank > ne.rank { pos++; }   // lower_bound with operator< (rank descending)
    insert_at(ops, pos, ne);
    return -1;
}

// ---------------------------------------------------------------------------------------------
// OptimizeExpression

fn ra_optimize_expression(root: i32, ops: RaVE[>..<]&) -> i32 {
    let opcode = iop(root);
    let ty = vals[root].ty;
    loop {
        var cst: i32 = -1;
        while ops.len > 0 {
            let c = ops[ops.len - 1].op;
            if !is_constant(c) { break; }
            if cst < 0 { ops.pop(); cst = c; continue; }
            let res = cf_fold_binop_operands(opcode, c, cst);
            if res < 0 { break; }
            ops.pop();
            cst = res;
        }
        if ops.len == 0 { return cst; }
        if cst >= 0 && cst != binop_identity(opcode, ty, false) {
            if cst == binop_absorber(opcode, ty, false) { return cst; }
            ops.push(RaVE { rank: 0, op: cst });
        }
        if ops.len == 1 { return ops[0].op; }
        let num = ops.len;
        if opcode == OP_AND || opcode == OP_OR {
            let r = ra_optimize_and_or_xor(opcode, ops);
            if r >= 0 { return r; }
        } else if opcode == OP_XOR {
            let r = ra_optimize_xor(root, ops);
            if r >= 0 { return r; }
        } else if opcode == OP_ADD || opcode == OP_FADD {
            let r = ra_optimize_add(root, ops);
            if r >= 0 { return r; }
        } else if opcode == OP_MUL || opcode == OP_FMUL {
            let r = ra_optimize_mul(root, ops);
            if r >= 0 { return r; }
        }
        if ops.len == num { return -1; }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// Erasing

// RecursivelyEraseDeadInsts(I, ToRedo)
fn ra_recursively_erase_dead_insts(i: i32) {
    var ops: i32[>..<] = [];
    for k in nops(i) { ops.push(op(i, k)); }
    hm_del(ra_vrm, i as u64);
    rs_remove(ra_tor, ra_tor_ix, i);
    redo_remove(i);
    salvage_debug_info(i);
    inst_erase_from_parent(i);
    for o in ops { if is_inst(o) && vals[o].first_use < 0 { rs_insert(ra_tor, ra_tor_ix, o); } }
}

// EraseInst
fn ra_erase_inst(i: i32) {
    var ops: i32[>..<] = [];
    for k in nops(i) { ops.push(op(i, k)); }
    hm_del(ra_vrm, i as u64);
    redo_remove(i);
    salvage_debug_info(i);
    inst_erase_from_parent(i);
    var visited: i32[>..<] = [];
    fn visit(v: i32) -> bool { for x in visited { if x == v { return false; } } visited.push(v); return true; }
    for v in ops {
        if !is_inst(v) || is_dead(v) { continue; }
        var o = v;
        let opcode = iop(o);
        while ra_one_use(o) && iop(ra_user_back(o)) == opcode && visit(o) { o = ra_user_back(o); }
        if hm_has(ra_vrm, o as u64) { redo_insert(o); }
    }
    ra_made_change = true;
}

// ---------------------------------------------------------------------------------------------
// Negative FP constants

recursive fn ra_get_negatible_insts(v: i32) {
    if !is_inst(v) || !ra_one_use(v) { return; }
    let i = v;
    let o = iop(i);
    if o == OP_FMUL {
        if is_constant(op(i, 0)) { return; }
        let c = m_apfloat(op(i, 1));
        if c >= 0 && ra_fp_is_neg(c) { ra_neg_cands.push(i); }
        ra_get_negatible_insts(op(i, 0));
        ra_get_negatible_insts(op(i, 1));
    } else if o == OP_FDIV {
        if is_constant(op(i, 0)) && is_constant(op(i, 1)) { return; }
        let c0 = m_apfloat(op(i, 0));
        let c1 = m_apfloat(op(i, 1));
        if (c0 >= 0 && ra_fp_is_neg(c0)) || (c1 >= 0 && ra_fp_is_neg(c1)) { ra_neg_cands.push(i); }
        ra_get_negatible_insts(op(i, 0));
        ra_get_negatible_insts(op(i, 1));
    }
}

// canonicalizeNegFPConstantsForOp; -1 = null
fn ra_canon_neg_fp_for_op(i: i32, o: i32, other: i32) -> i32 {
    ra_neg_cands.resize(0);
    ra_get_negatible_insts(o);
    let n = ra_neg_cands.len;
    if n == 0 { return -1; }
    let is_fsub = iop(i) == OP_FSUB;
    let needs_sub = !is_fsub && n % 2 == 1;
    if needs_sub && ra_should_break_up_subtract(i) { return -1; }
    for k in n {
        let ng = ra_neg_cands[k];
        for j in 2 {
            let c = m_apfloat(op(ng, j));
            if c >= 0 {
                set_op(ng, j, ra_fp_abs(c, vals[ng].ty));
                ra_made_change = true;
            }
        }
    }
    if n % 2 == 0 { return i; }
    rb_pos = i;
    rb_fmf = ra_fmf(i);
    let ni = rb_binop(if is_fsub { OP_FADD } else { OP_FSUB }, other, o);
    rauw(i, ni);
    redo_insert(i);
    return if is_inst(ni) { ni } else { -1 };
}

// canonicalizeNegFPConstants
fn ra_canon_neg_fp(i0: i32) -> i32 {
    var i = i0;
    if is_inst_op(i, OP_FADD) && is_inst(op(i, 1)) && ra_one_use(op(i, 1)) {
        let r = ra_canon_neg_fp_for_op(i, op(i, 1), op(i, 0));
        if r >= 0 { i = r; }
    }
    if is_inst_op(i, OP_FADD) && is_inst(op(i, 0)) && ra_one_use(op(i, 0)) {
        let r = ra_canon_neg_fp_for_op(i, op(i, 0), op(i, 1));
        if r >= 0 { i = r; }
    }
    if is_inst_op(i, OP_FSUB) && is_inst(op(i, 1)) && ra_one_use(op(i, 1)) {
        let r = ra_canon_neg_fp_for_op(i, op(i, 1), op(i, 0));
        if r >= 0 { i = r; }
    }
    return i;
}

// ---------------------------------------------------------------------------------------------
// OptimizeInst

fn ra_redo_binop_users(ni: i32) {
    var u = vals[ni].first_use;
    while u >= 0 {
        let us = uses[u].user;
        if ra_is_binop(us) { redo_insert(us); }
        u = uses[u].next;
    }
}

fn ra_optimize_inst(i0: i32) {
    var i = i0;
    if !ra_is_binop(i) && !ra_is_unop(i) { return; }
    if iop(i) == OP_SHL && ra_isa_cint(op(i, 1)) {
        if ra_reassociable(op(i, 0), OP_MUL) >= 0 ||
           (ra_one_use(i) && (ra_reassociable(ra_user_back(i), OP_MUL) >= 0 || ra_reassociable(ra_user_back(i), OP_ADD) >= 0)) {
            let ni = ra_convert_shift_to_mul(i);
            redo_insert(i);
            ra_made_change = true;
            i = ni;
        }
    }
    if ra_is_commutative(iop(i)) { ra_canonicalize_operands(i); }
    let res = ra_canon_neg_fp(i);
    if res >= 0 { i = res; }
    if is_fp_math_operator(i) && !ra_has_fp_assoc(i) { return; }
    let ty = vals[i].ty;
    if ty_is_int(ty_scalar(ty)) && ty_bits(ty_scalar(ty)) == 1 { return; }
    if iop(i) == OP_OR && ra_should_convert_or_to_add(i) && !ra_is_load_combine_candidate(i) {
        var disjoint = (ra_flags(i) & FL_DISJOINT) != 0;
        if !disjoint {
            ra_sq_begin(i);
            disjoint = have_no_common_bits_set(op(i, 0), op(i, 1), i);
            ra_sq_end();
        }
        if disjoint {
            let ni = ra_convert_or_to_add(i);
            redo_insert(i);
            ra_made_change = true;
            i = ni;
        }
    }
    if iop(i) == OP_MUL && ra_should_break_up_distribution(i) {
        let mu = ra_user_back(i);
        let ni = ra_break_up_distribute(i);
        redo_insert(i);
        redo_insert(mu);
        ra_made_change = true;
        i = ni;
    }
    let o = iop(i);
    if o == OP_SUB {
        if ra_should_break_up_subtract(i) {
            let ni = ra_break_up_subtract(i);
            redo_insert(i);
            ra_made_change = true;
            i = ni;
        } else if m_neg(i) >= 0 {
            if ra_reassociable(op(i, 1), OP_MUL) >= 0 && (!ra_one_use(i) || ra_reassociable(ra_user_back(i), OP_MUL) < 0) {
                let ni = ra_lower_negate_to_multiply(i);
                ra_redo_binop_users(ni);
                redo_insert(i);
                ra_made_change = true;
                i = ni;
            }
        }
    } else if o == OP_FNEG || o == OP_FSUB {
        if ra_should_break_up_subtract(i) {
            let ni = ra_break_up_subtract(i);
            redo_insert(i);
            ra_made_change = true;
            i = ni;
        } else if m_fneg(i) >= 0 {
            let x = if ra_is_binop(i) { op(i, 1) } else { op(i, 0) };
            if ra_reassociable(x, OP_FMUL) >= 0 && (!ra_one_use(i) || ra_reassociable(ra_user_back(i), OP_FMUL) < 0) {
                let ni = ra_lower_negate_to_multiply(i);
                ra_redo_binop_users(ni);
                redo_insert(i);
                ra_made_change = true;
                i = ni;
            }
        }
    }
    if !ra_is_binop(i) || !ra_is_associative(i) { return; }
    let bo = i;
    let opcode = iop(bo);
    if ra_one_use(bo) && iop(ra_user_back(bo)) == opcode {
        let u = ra_user_back(bo);
        if u != bo && inst_parent(bo) == inst_parent(u) { redo_insert(u); }
        return;
    }
    if ra_one_use(bo) && opcode == OP_ADD && iop(ra_user_back(bo)) == OP_SUB { return; }
    if ra_one_use(bo) && opcode == OP_FADD && iop(ra_user_back(bo)) == OP_FSUB { return; }
    ra_reassociate_expression(bo);
}

// ---------------------------------------------------------------------------------------------
// ReassociateExpression

fn ra_pair_key(opc: i64, a: i32, b: i32) -> u64 {
    var x = a;
    var y = b;
    if y < x { let t = x; x = y; y = t; }
    if y >= 0x10000000 { fatal("reassociate: more than 2^28 values"); }
    return ((opc as u64) << 56) | ((x as u64) << 28) | (y as u64);
}

fn ra_reassociate_expression(i: i32) {
    var tree: RaRV[>..<] = [];
    var f = ra_ot_new();
    if ra_linearize_expr_tree(i, tree, f) { ra_made_change = true; }
    var ops: RaVE[>..<] = [];
    ra_ops_from_tree(tree, ops);
    std_stable_sort(ops, 0, ops.len) { a, b => a.rank > b.rank };

    let v = ra_optimize_expression(i, ops);
    if v >= 0 {
        if v == i { return; }
        rauw(i, v);
        if is_inst(v) {
            let d = ra_dl(i);
            if d >= 0 { inst_set_md(v, 0, d); }
        }
        redo_insert(i);
        return;
    }
    if ra_one_use(i) {
        let u = ra_user_back(i);
        let last = ops[ops.len - 1].op;
        if iop(i) == OP_MUL && iop(u) == OP_ADD && ra_isa_cint(last) && ap_is_all_ones(ci_ap(last)) {
            let t = ops.pop();
            insert_at(ops, 0, t);
        } else if iop(i) == OP_FMUL && iop(u) == OP_FADD && ra_isa_cfp(last) && fp_is_exactly(ra_cfp_scalar(last), -1.0) {
            let t = ops.pop();
            insert_at(ops, 0, t);
        }
    }
    if ops.len == 1 {
        if ops[0].op == i { return; }
        rauw(i, ops[0].op);
        if is_inst(ops[0].op) { ra_set_dl(ops[0].op, ra_dl(i)); }
        redo_insert(i);
        return;
    }
    if ops.len > 2 && ops.len <= RA_GLOBAL_REASSOCIATE_LIMIT {
        var max_score: u32 = 1;
        var best_rank: u32 = 0;
        var bf: i64 = 0;
        var bs: i64 = 0;
        let idx = iop(i);
        var limit: i64 = 0;
        if flag_bool("reassociate-use-cse-local", true) {
            var first_seen: i32 = -1;
            let start = ops.len - 1;
            var k = start - 1;
            while k != -1 {
                let val = ops[k].op;
                let seen = if !is_inst(val) { func_entry(inst_func(i)) } else { inst_parent(val) };
                if first_seen < 0 { first_seen = seen; k--; continue; }
                if first_seen != seen { limit = k + 1; break; }
                k--;
            }
        }
        var k = ops.len - 1;
        while k > limit {
            var j = k - 1;
            while j >= limit {
                var score: u32 = 0;
                let jj = hm_find(ra_pairs, ra_pair_key(idx, ops[k].op, ops[j].op));
                if jj >= 0 { score += ra_pairs.slots[jj].val as u32; }
                let mr = if ops[k].rank > ops[j].rank { ops[k].rank } else { ops[j].rank };
                if score > max_score || (score == max_score && mr < best_rank) {
                    bf = j; bs = k; max_score = score; best_rank = mr;
                }
                j--;
            }
            k--;
        }
        if max_score > 1 {
            let o0 = ops[bf];
            let o1 = ops[bs];
            remove_at(ops, bs);
            remove_at(ops, bf);
            ops.push(o0);
            ops.push(o1);
        }
    }
    ra_rewrite_expr_tree(i, ops, f);
}

// BuildPairMap
fn ra_build_pair_map(rpot: const i32[:]) {
    for bb in rpot {
        var i = block_first(bb);
        while i >= 0 {
            let cur = i;
            i = inst_next(i);
            if !ra_is_binop(cur) || !ra_is_associative(cur) { continue; }
            if ra_one_use(cur) && iop(ra_user_back(cur)) == iop(cur) { continue; }
            var wl: i32[>..<] = [];
            wl.push(op(cur, 0));
            wl.push(op(cur, 1));
            var ops: i32[>..<] = [];
            while wl.len > 0 && ops.len <= RA_GLOBAL_REASSOCIATE_LIMIT {
                let o = wl.pop();
                if !is_inst(o) || iop(o) != iop(cur) || !ra_one_use(o) { ops.push(o); continue; }
                if op(o, 0) != o { wl.push(op(o, 0)); }
                if op(o, 1) != o { wl.push(op(o, 1)); }
            }
            if ops.len > RA_GLOBAL_REASSOCIATE_LIMIT { continue; }
            let idx = iop(cur);
            var visited: u64[>..<] = [];
            for a in ops.len - 1 {
                for b in a + 1..ops.len {
                    let key = ra_pair_key(idx, ops[a], ops[b]);
                    var seen = false;
                    for x in visited { if x == key { seen = true; break; } }
                    if seen { continue; }
                    visited.push(key);
                    hm_put(ra_pairs, key, hm_get(ra_pairs, key, 0) + 1);
                }
            }
        }
    }
}

// ReversePostOrderTraversal<Function *>
fn ra_rpo(fv: i32, out: i32[>..<]&) {
    var seen = hm_new();
    var stk: i32[>..<] = [];
    var idx: i64[>..<] = [];
    var po: i32[>..<] = [];
    let entry = func_entry(fv);
    hm_put(seen, entry as u64, 1);
    stk.push(entry);
    idx.push(0);
    while stk.len > 0 {
        let t = stk.len - 1;
        let bb = stk[t];
        if idx[t] < block_nsucc(bb) {
            let s = block_succ(bb, idx[t]);
            idx[t]++;
            if !hm_has(seen, s as u64) { hm_put(seen, s as u64, 1); stk.push(s); idx.push(0); }
            continue;
        }
        po.push(bb);
        stk.pop();
        idx.pop();
    }
    var k = po.len - 1;
    while k >= 0 { out.push(po[k]); k--; }
}

fn reassociate_run(fv: i32) -> u32 {
    ra_fv = fv;
    hm_clear(ra_rank_map);
    hm_clear(ra_vrm);
    hm_clear(ra_pairs);
    hm_clear(ra_redo_ix);
    ra_redo.resize(0);
    ra_redo_head = 0;
    var rpot: i32[>..<] = [];
    ra_rpo(fv, rpot);
    ra_build_rank_map(fv, rpot);
    ra_build_pair_map(rpot);
    ra_made_change = false;
    for bb in rpot {
        var ii = block_first(bb);
        while ii >= 0 {
            if ra_trivially_dead(ii) {
                let nx = inst_next(ii);
                ra_erase_inst(ii);
                ii = nx;
            } else {
                ra_optimize_inst(ii);
                ii = inst_next(ii);
            }
        }
        // ToRedo(RedoInsts)
        ra_tor.resize(0);
        hm_clear(ra_tor_ix);
        for k in ra_redo_head..ra_redo.len { if ra_redo[k] >= 0 { rs_insert(ra_tor, ra_tor_ix, ra_redo[k]); } }
        while !rs_empty(ra_tor_ix) {
            let i = rs_pop_back(ra_tor, ra_tor_ix);
            if ra_trivially_dead(i) {
                ra_recursively_erase_dead_insts(i);
                ra_made_change = true;
            }
        }
        while !rs_empty(ra_redo_ix) {
            let i = redo_pop_front();
            if ra_trivially_dead(i) { ra_erase_inst(i); }
            else { ra_optimize_inst(i); }
        }
    }
    hm_clear(ra_rank_map);
    hm_clear(ra_vrm);
    hm_clear(ra_pairs);
    if ra_made_change { return PA_CFG; }
    return PA_ALL;
}
