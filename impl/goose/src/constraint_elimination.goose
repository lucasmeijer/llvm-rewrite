// ConstraintElimination: port of llvm/lib/Transforms/Scalar/ConstraintElimination.cpp and the constraint system of
// llvm/lib/Analysis/ConstraintSystem.cpp (+ include/llvm/Analysis/ConstraintSystem.h).
//
// Data layout:
//   ConstraintSystem (two instances, s = 0 unsigned, 1 signed): rows are records in `cs_rows` linked to the previous
//     row of the same system (`prev`, head `cs_head[s]`), their sparse (coefficient, id) entries runs in `cs_pool`.
//     Rows are only pushed and popped at the back, so a row is never edited; mayHaveSolution works on a list of row
//     descriptors (`fm_rows`, `fm_rem`): shrinking a row is shrinking its descriptor, new rows are appended to the
//     pool and the pool is truncated afterwards. Value2Index is an HMap per system (`cs_v2i_u`, `cs_v2i_s`).
//   Decompositions, constraint coefficient vectors and preconditions live on global stacks (`dc_vars`, `ce_coef`,
//     `ce_pre`): decompose is recursive and doesHold/isValid are mutually recursive, and Goose forbids growable
//     locals across a recursive call. A constraint (ConstraintTy) is a `CT` naming its runs.
//   DFSInStack: `st_ent` + the ValuesToRelease runs in `st_rel`. The worklist is `ce_wl` (FactOrCheck = `CFact`).
// CmpPredicate = predicate | samesign << 8 (implied.goose `cp`). The reproducer (-constraint-elimination-dump-
// reproducers) is not ported: the option is not accepted.
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import pm;
import vt;
import knownbits;
import poison;
import implied;
import constfold;
import apint;
import datalayout;
import domtree;
import loopinfo;
import scev;
import scev_create;
import scev_range;
import scev_update;
import aa;
import tli;
import dinfo;
import salvage;
import flags;
import stdsort;
import gen_iids;
import calls;

fn ce_fail(msg: const u8[:]) { fatal(str("constraint-elimination: ", msg, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// int64 arithmetic with overflow (llvm/Support/MathExtras.h AddOverflow / SubOverflow / MulOverflow):
// the wrapped result and whether it overflowed

fn ce_add_ov(a: i64, b: i64) -> i64, bool {
    let r = ((a as! u64) + (b as! u64)) as! i64;
    return r, (a >= 0) == (b >= 0) && (r >= 0) != (a >= 0);
}
fn ce_sub_ov(a: i64, b: i64) -> i64, bool {
    let r = ((a as! u64) - (b as! u64)) as! i64;
    return r, (a >= 0) != (b >= 0) && (r >= 0) != (a >= 0);
}
fn ce_uabs(a: i64) -> u64 { if a >= 0 { a as! u64 } else { 0 - (a as! u64) } }
fn ce_mul_ov(a: i64, b: i64) -> i64, bool {
    let r = ((a as! u64) * (b as! u64)) as! i64;
    if a == 0 || b == 0 { return 0, false; }
    let ua = ce_uabs(a);
    let ub = ce_uabs(b);
    let neg = (a < 0) != (b < 0);
    let lim: u64 = if neg { 0x8000000000000000 } else { 0x7FFFFFFFFFFFFFFF };
    return r, ua > lim / ub;
}
let CE_I64_MAX: i64 = 0x7FFFFFFFFFFFFFFF;

// ---------------------------------------------------------------------------------------------
// ConstraintSystem

struct CsEnt { c: i64, id: i32 }
struct CsRow { at: i64, n: i64, prev: i32 }
struct FmRow { at: i64, n: i64 }
var cs_pool: CsEnt[>..<];
var cs_rows: CsRow[>..<];
var cs_head: i32[2] = [-1, -1];
var cs_nrows: i64[2] = [0, 0];
var cs_nv: i64[2] = [0, 0];          // NumVariables
var cs_v2i_u = hm_new();
var cs_v2i_s = hm_new();
var fm_rows: FmRow[>..<];
var fm_rem: FmRow[>..<];

fn cs_v2i_get(s: i64, v: i32) -> i64 { if s == 0 { hm_get(cs_v2i_u, v as u64, -1) } else { hm_get(cs_v2i_s, v as u64, -1) } }
fn cs_v2i_size(s: i64) -> i64 { if s == 0 { cs_v2i_u.n } else { cs_v2i_s.n } }
fn cs_v2i_put(s: i64, v: i32, idx: i64) { if s == 0 { hm_put(cs_v2i_u, v as u64, idx); } else { hm_put(cs_v2i_s, v as u64, idx); } }
fn cs_v2i_erase(s: i64, v: i32) { if s == 0 { hm_del(cs_v2i_u, v as u64); } else { hm_del(cs_v2i_s, v as u64); } }

fn cs_reset() {
    cs_pool.resize(0);
    cs_rows.resize(0);
    cs_head[0] = -1; cs_head[1] = -1;
    cs_nrows[0] = 0; cs_nrows[1] = 0;
    cs_nv[0] = 0; cs_nv[1] = 0;
    hm_clear(cs_v2i_u);
    hm_clear(cs_v2i_s);
}

fn cs_all_zero_tail(r: const i64[:]) -> bool { for k in 1..r.len { if r[k] != 0 { return false; } } return true; }

// addVariableRow
fn cs_add_row(s: i64, r: const i64[:]) -> bool {
    if cs_all_zero_tail(r) { return false; }
    let at = cs_pool.len;
    for k in r.len { if r[k] != 0 { cs_pool.push(CsEnt { c: r[k], id: k as i32 }); } }
    if cs_nrows[s] == 0 { cs_nv[s] = r.len; }
    cs_rows.push(CsRow { at: at, n: cs_pool.len - at, prev: cs_head[s] });
    cs_head[s] = (cs_rows.len - 1) as i32;
    cs_nrows[s] = cs_nrows[s] + 1;
    return true;
}
// addVariableRowFill
fn cs_add_row_fill(s: i64, r: const i64[:]) -> bool {
    if cs_all_zero_tail(r) { return false; }
    if r.len > cs_nv[s] { cs_nv[s] = r.len; }
    return cs_add_row(s, r);
}
fn cs_pop_last(s: i64) {
    let h = cs_head[s];
    cs_head[s] = cs_rows[h].prev;
    cs_nrows[s] = cs_nrows[s] - 1;
    // the row is the newest of all rows unless the other system pushed later; drop it when it is on top
    if h as i64 == cs_rows.len - 1 { cs_pool.resize(cs_rows[h].at); cs_rows.pop(); }
}
fn cs_pop_vars(s: i64, n: i64) { cs_nv[s] = cs_nv[s] - n; }

fn fm_last_coef(r: FmRow, id: i64) -> i64 {
    if r.n == 0 { return 0; }
    let e = cs_pool[r.at + r.n - 1];
    if e.id as i64 == id { return e.c; }
    return 0;
}

// eliminateUsingFM on fm_rows with `nv` variables; false = gave up (system too big)
fn fm_eliminate(nv: i64) -> bool {
    let last = nv - 1;
    fm_rem.resize(0);
    var r1: i64 = 0;
    while r1 < fm_rows.len {
        let row = fm_rows[r1];
        if fm_last_coef(row, last) == 0 {
            if row.n > 0 && cs_pool[row.at + row.n - 1].id as i64 == last { fm_rows[r1].n = row.n - 1; }
            r1++;
        } else {
            let b = fm_rows.len - 1;
            let t = fm_rows[r1];
            fm_rows[r1] = fm_rows[b];
            fm_rows[b] = t;
            fm_rem.push(fm_rows.pop());
        }
    }
    let nrem = fm_rem.len;
    for i1 in nrem {
        for i2 in i1 + 1..nrem {
            var upper_last = fm_last_coef(fm_rem[i2], last);
            var lower_last = fm_last_coef(fm_rem[i1], last);
            if (lower_last < 0 && upper_last < 0) || (lower_last > 0 && upper_last > 0) { continue; }
            var lr = i1;
            var ur = i2;
            if upper_last < 0 {
                let t = lr; lr = ur; ur = t;
                let tl = lower_last; lower_last = upper_last; upper_last = tl;
            }
            let lrow = fm_rem[lr];
            let urow = fm_rem[ur];
            let start = cs_pool.len;
            var iu: i64 = 0;
            var il: i64 = 0;
            var overflow = false;
            let neg_lower = ((0 as u64) - (lower_last as! u64)) as! i64;   // -1 * LowerLast
            loop {
                if iu >= urow.n || il >= lrow.n { break; }
                var cur: i64 = 0xFFFF;
                let uid = cs_pool[urow.at + iu].id as i64;
                let lid = cs_pool[lrow.at + il].id as i64;
                if uid < cur { cur = uid; }
                if lid < cur { cur = lid; }
                var uv: i64 = 0;
                var lv: i64 = 0;
                if uid == cur { uv = cs_pool[urow.at + iu].c; iu++; }
                let m1, o1 = ce_mul_ov(uv, neg_lower);
                if o1 { overflow = true; break; }
                if lid == cur { lv = cs_pool[lrow.at + il].c; il++; }
                let m2, o2 = ce_mul_ov(lv, upper_last);
                if o2 { overflow = true; break; }
                let nn, o3 = ce_add_ov(m1, m2);
                if o3 { overflow = true; break; }
                if nn == 0 { continue; }
                cs_pool.push(CsEnt { c: nn, id: cur as i32 });
            }
            if overflow || cs_pool.len == start { cs_pool.resize(start); continue; }
            fm_rows.push(FmRow { at: start, n: cs_pool.len - start });
            if fm_rows.len > 500 { return false; }
        }
    }
    return true;
}

// isConditionImplied(R) on system s
fn cs_is_condition_implied(s: i64, r: const i64[:]) -> bool {
    if cs_all_zero_tail(r) { return r[0] >= 0; }
    // negate(R)
    var nr: i64[>..<] = [];
    for x in r { nr.push(x); }
    let c0, o0 = ce_add_ov(nr[0], 1);
    if o0 { return false; }
    nr[0] = c0;
    for k in nr.len {
        let m, o = ce_mul_ov(nr[k], -1);
        if o { return false; }
        nr[k] = m;
    }
    // NewSystem = *this; addVariableRow(R); !mayHaveSolution()
    let mark = cs_pool.len;
    fm_rows.resize(0);
    var h = cs_head[s];
    while h >= 0 { fm_rows.push(FmRow { at: cs_rows[h].at, n: cs_rows[h].n }); h = cs_rows[h].prev; }
    // the list was walked newest first
    var a: i64 = 0;
    var b = fm_rows.len - 1;
    while a < b { let t = fm_rows[a]; fm_rows[a] = fm_rows[b]; fm_rows[b] = t; a++; b--; }
    var nv = cs_nv[s];
    if !cs_all_zero_tail(nr) {
        let at = cs_pool.len;
        for k in nr.len { if nr[k] != 0 { cs_pool.push(CsEnt { c: nr[k], id: k as i32 }); } }
        if fm_rows.len == 0 { nv = nr.len; }
        fm_rows.push(FmRow { at: at, n: cs_pool.len - at });
    }
    let has = fm_may_have_solution(nv);
    cs_pool.resize(mark);
    return !has;
}

// mayHaveSolutionImpl
fn fm_may_have_solution(nv0: i64) -> bool {
    var nv = nv0;
    while fm_rows.len > 0 && nv > 1 {
        if !fm_eliminate(nv) { return true; }
        nv--;
    }
    if fm_rows.len == 0 || nv > 1 { return true; }
    for r in fm_rows {
        if r.n == 0 { continue; }
        if cs_pool[r.at].id == 0 && cs_pool[r.at].c < 0 { return false; }
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// ConditionTy, ConstraintTy, Decomposition

struct CCond { pred: i64, a: i32, b: i32 }      // pred -1 = BAD_ICMP_PREDICATE
struct DEnt { c: i64, v: i32 }
struct CT { cb: i64, cn: i64, pb: i64, pn: i64, signed: bool, eq: bool, ne: bool }

var dc_vars: DEnt[>..<];
var ce_coef: i64[>..<];
var ce_pre: CCond[>..<];
var ce_fv: i32 = -1;

fn ct_empty() -> CT { CT { cb: ce_coef.len, cn: 0, pb: ce_pre.len, pn: 0, signed: false, eq: false, ne: false } }
// release a constraint's runs (and everything pushed after them)
fn ct_release(c: CT) { ce_coef.resize(c.cb); ce_pre.resize(c.pb); }

// isa<ConstantInt>
fn ce_isa_cint(v: i32) -> bool { vals[v].kind == VK_CINT }   // also a vector-typed splat ConstantInt
// canUseSExt
fn ce_can_use_sext(ci: i32) -> bool {
    let a = ci_ap(ci);
    if a.w > 64 { if ap_num_sign_bits(a) < a.w - 63 { return false; } }
    let x = ap_sext64(a);
    return x != (0x8000000000000000 as! i64) && x != CE_I64_MAX;
}
fn ce_sext(ci: i32) -> i64 { ap_sext64(ci_ap(ci)) }

// isKnownNonNegative(V, DL, Depth)
fn ce_known_nonneg(v: i32, depth: i64) -> bool {
    let sc = kb_cxt; let sdt = sq_no_dt; let sac = sq_no_ac; let stli = sq_no_tli;
    kb_cxt = -1; sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    let r = kb_is_nonneg(kb_compute_all(v, depth));
    kb_cxt = sc; sq_no_dt = sdt; sq_no_ac = sac; sq_no_tli = stli;
    return r;
}
// isGuaranteedNotToBePoison(V) (no AC, context, DT)
fn ce_not_poison(v: i32) -> bool {
    let sc = kb_cxt; let sdt = sq_no_dt; let sac = sq_no_ac;
    kb_cxt = -1; sq_no_dt = true; sq_no_ac = true;
    let r = is_guaranteed_not_to_be_poison(v, -1, 0);
    kb_cxt = sc; sq_no_dt = sdt; sq_no_ac = sac;
    return r;
}

fn ce_mask(w: i64) -> u64 { if w >= 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << (w as u64)) - 1 } }
fn ce_sext_w(x: u64, w: i64) -> i64 {
    if w >= 64 { return x as! i64; }
    let sh = (64 - w) as u64;
    return ((x << sh) as! i64) >> sh;
}

// GEPNoWrapFlags (inbounds implies nusw)
let CE_NUSW: u8 = 2;
let CE_NUW: u8 = 4;
fn ce_gep_nw(g: i32) -> u8 {
    var f = gep_flags(g) & (GEP_INBOUNDS | GEP_NUSW | GEP_NUW);
    if (f & GEP_INBOUNDS) != 0 { f |= GEP_NUSW; }
    return f;
}

// GEPOperator::collectOffset(DL, BitWidth, VariableOffsets, ConstantOffset) for instructions and constant
// expressions: the variable offsets (MapVector order) are appended to co_vals/co_scale from the current top;
// returns (ok, constant offset)
var co_vals: i32[>..<];
var co_scale: AP[>..<];
fn ce_collect_offset(g: i32, w: i64) -> bool, AP {
    let base = co_vals.len;
    var cst = ap_zero(w);
    let src = gep_src_ty(g);
    var t = src;
    for k in 1..nops(g) {
        let x = op(g, k);
        var indexed = t;
        var stride: i64 = 0;
        var is_struct = false;
        if k == 1 { indexed = src; stride = dl_alloc_size(src); }
        else if ty_is_struct(t) {
            is_struct = true;
            var sx = x;
            if vals[sx].kind != VK_CINT { sx = splat_value(x, false); }
            if sx < 0 || vals[sx].kind != VK_CINT { co_vals.resize(base); co_scale.resize(base); return false, cst; }
            indexed = ty_field(t, cint_lo(sx) as! i64);
        } else { indexed = types[t].a; stride = dl_gep_stride(t, indexed); }
        let scalable = vt_is_scalable_ty(indexed);
        if ce_isa_cint(x) && ty_kind(vals[x].ty) == TK_INT {
            if cint_is_zero(x) { t = indexed; continue; }
            if scalable { co_vals.resize(base); co_scale.resize(base); return false, cst; }
            if is_struct {
                cst = ap_add(cst, ap_u64(dl_struct_offset(t, cint_lo(x) as! i64) as! u64, w));
            } else {
                cst = ap_add(cst, ap_mul(ap_sext_or_trunc(ci_ap(x), w), ap_u64(stride as! u64, w)));
            }
            t = indexed;
            continue;
        }
        if is_struct || scalable { co_vals.resize(base); co_scale.resize(base); return false, cst; }
        let sz = ap_u64(stride as! u64, w);
        if !ap_is_zero(sz) {
            var found: i64 = -1;
            for j in base..co_vals.len { if co_vals[j] == x { found = j; } }
            if found < 0 { co_vals.push(x); co_scale.push(ap_zero(w)); found = co_vals.len - 1; }
            co_scale[found] = ap_add(co_scale[found], sz);
        }
        t = indexed;
    }
    return true, cst;
}

// collectOffsets(GEP, DL): (base ptr or -1, constant offset, nw); the variable offsets are co_vals/co_scale[mark..]
struct COR { base: i32, cst: AP, nw: u8, w: i64 }
fn ce_collect_offsets(g: i32) -> COR {
    let bp = op(g, 0);
    let w = dl_ptr(ptr_as(vals[bp].ty)).idx;
    let mark = co_vals.len;
    let ok, cst = ce_collect_offset(g, w);
    if !ok { return COR { base: -1, cst: cst, nw: 0, w: w }; }
    var r = COR { base: bp, cst: cst, nw: ce_gep_nw(g), w: w };
    if is_inst_op(bp, OP_GEP) {
        let n1 = co_vals.len - mark;
        let m2 = co_vals.len;
        let ok2, cst2 = ce_collect_offset(bp, w);
        let n2 = co_vals.len - m2;
        if !ok2 || n1 > 1 || n2 > 1 || (n1 >= 1 && n2 >= 1) {
            co_vals.resize(m2); co_scale.resize(m2);
            return r;
        }
        r.base = op(bp, 0);
        r.cst = ap_add(r.cst, cst2);
        // the inner offsets are kept only when the outer GEP has none (they are then the only run)
        if !(n1 == 0 && n2 == 1) { co_vals.resize(m2); co_scale.resize(m2); }
        r.nw = r.nw & ce_gep_nw(bp);
    }
    return r;
}

// Decomposition results: (offset, vars = dc_vars[mark..]) where mark is dc_vars.len on entry
fn dc_var(mark: i64, v: i32) -> i64 { dc_vars.resize(mark); dc_vars.push(DEnt { c: 1, v: v }); return 0; }
fn dc_const(mark: i64, c: i64) -> i64 { dc_vars.resize(mark); return c; }
// Decomposition::mul on dc_vars[b..]: (new offset, overflowed)
fn dc_mul(b: i64, off: i64, f: i64) -> i64, bool {
    let no, o = ce_mul_ov(off, f);
    if o { return no, true; }
    for k in b..dc_vars.len {
        let c, o2 = ce_mul_ov(dc_vars[k].c, f);
        dc_vars[k].c = c;
        if o2 { return no, true; }
    }
    return no, false;
}

// m_*Add & co (OverflowingBinaryOperator: instructions and constant expressions)
fn ce_obo(v: i32, o: i64, fl: u8) -> bool { opcode_of(v) == o && (op_flags(v) & fl) == fl }

// decomposeGEP
recursive fn ce_decompose_gep(g: i32, is_signed: bool) -> i64 {
    let mark = dc_vars.len;
    if dl_ptr(ptr_as(vals[op(g, 0)].ty)).idx > 64 { return dc_var(mark, g); }
    let cm = co_vals.len;
    let r = ce_collect_offsets(g);
    if r.base < 0 || r.nw == 0 { co_vals.resize(cm); co_scale.resize(cm); return dc_var(mark, g); }
    if (r.nw & CE_NUSW) == 0 && ap_is_neg(r.cst) { co_vals.resize(cm); co_scale.resize(cm); return dc_var(mark, g); }
    var off = ap_sext64(r.cst);
    dc_vars.push(DEnt { c: 1, v: r.base });
    let ce = co_vals.len;
    for k in cm..ce {
        let idx = co_vals[k];
        let scale = ap_sext64(co_scale[k]);
        let ib = dc_vars.len;
        let ioff0 = ce_decompose(idx, is_signed);
        let ioff, o1 = dc_mul(ib, ioff0, scale);
        if o1 { co_vals.resize(cm); co_scale.resize(cm); return dc_var(mark, g); }
        let no, o2 = ce_add_ov(off, ioff);
        if o2 { co_vals.resize(cm); co_scale.resize(cm); return dc_var(mark, g); }
        off = no;
        if (r.nw & CE_NUW) == 0 {
            if !ce_known_nonneg(idx, 0) { ce_pre.push(CCond { pred: P_SGE, a: idx, b: c_int_ty(vals[idx].ty, 0) }); }
        }
    }
    co_vals.resize(cm); co_scale.resize(cm);
    return off;
}

// decompose(V, Preconditions, IsSigned, DL): the offset; the variables are dc_vars[entry mark..]
recursive fn ce_decompose(v0: i32, is_signed: bool) -> i64 {
    let mark = dc_vars.len;
    var v = v0;
    let ty = ty_scalar(vals[v].ty);
    if ty_kind(ty) == TK_PTR && !is_signed {
        if opcode_of(v) == OP_GEP { return ce_decompose_gep(v, is_signed); }
        if vals[v].kind == VK_CNULL { return dc_const(mark, 0); }
        return dc_var(mark, v);
    }
    if !ty_is_int(ty) || ty_bits(ty) > 64 { return dc_var(mark, v); }

    if is_signed {
        if ce_isa_cint(v) && ce_can_use_sext(v) { return dc_const(mark, ce_sext(v)); }
        if is_inst_op(v, OP_SEXT) { v = op(v, 0); }
        else if is_inst_op(v, OP_ZEXT) && (op_flags(v) & FL_NNEG) != 0 { v = op(v, 0); }
        else if is_inst_op(v, OP_TRUNC) && (op_flags(v) & FL_NSW) != 0 {
            if ty_bits(ty_scalar(vals[op(v, 0)].ty)) <= 64 { v = op(v, 0); }
        }
        if ce_obo(v, OP_ADD, FL_NSW) {
            let a = op(v, 0);
            let b = op(v, 1);
            let oa = ce_decompose(a, is_signed);
            let ob = ce_decompose(b, is_signed);
            let s, o = ce_add_ov(oa, ob);
            if !o { return s; }
            return dc_var(mark, v);
        }
        if ce_obo(v, OP_SUB, FL_NSW) {
            let a = op(v, 0);
            let b = op(v, 1);
            let oa = ce_decompose(a, is_signed);
            let bb = dc_vars.len;
            let ob = ce_decompose(b, is_signed);
            let nb, o1 = dc_mul(bb, ob, -1);
            if o1 { return dc_var(mark, v); }
            let s, o2 = ce_add_ov(oa, nb);
            if o2 { return dc_var(mark, v); }
            return s;
        }
        if ce_obo(v, OP_MUL, FL_NSW) && ce_isa_cint(op(v, 1)) && ce_can_use_sext(op(v, 1)) {
            let f = ce_sext(op(v, 1));
            let b = dc_vars.len;
            let o0 = ce_decompose(op(v, 0), is_signed);
            let no, o = dc_mul(b, o0, f);
            if !o { return no; }
            return dc_var(mark, v);
        }
        if ce_obo(v, OP_SHL, FL_NSW) && ce_isa_cint(op(v, 1)) {
            let sh = ap_limited(ci_ap(op(v, 1)), 0xFFFFFFFFFFFFFFFF);
            if sh < ((ty_bits(ty) - 1) as u64) {
                let b = dc_vars.len;
                let o0 = ce_decompose(op(v, 0), is_signed);
                let no, o = dc_mul(b, o0, (1 as i64) << (sh as i64));
                if !o { return no; }
                return dc_var(mark, v);
            }
        }
        return dc_var(mark, v);
    }

    if ce_isa_cint(v) {
        let a = ci_ap(v);
        if ap_uge_u64(a, CE_I64_MAX as u64) { return dc_var(mark, v); }
        return dc_const(mark, ap_lo64(a) as! i64);
    }
    if is_inst_op(v, OP_ZEXT) {
        v = op(v, 0);
    } else if is_inst_op(v, OP_SEXT) {
        v = op(v, 0);
        ce_pre.push(CCond { pred: P_SGE, a: v, b: c_int_ty(vals[v].ty, 0) });
    } else if is_inst_op(v, OP_TRUNC) {
        if ty_bits(ty_scalar(vals[op(v, 0)].ty)) <= 64 {
            let fl = op_flags(v);
            if (fl & FL_NUW) != 0 || (fl & FL_NSW) != 0 {
                v = op(v, 0);
                if (fl & FL_NUW) == 0 { ce_pre.push(CCond { pred: P_SGE, a: v, b: c_int_ty(vals[v].ty, 0) }); }
            }
        }
    }
    if ce_obo(v, OP_ADD, FL_NUW) {
        let oa = ce_decompose(op(v, 0), is_signed);
        let ob = ce_decompose(op(v, 1), is_signed);
        let s, o = ce_add_ov(oa, ob);
        if !o { return s; }
        return dc_var(mark, v);
    }
    if is_inst_op(v, OP_ADD) && ce_isa_cint(op(v, 1)) && ap_is_neg(ci_ap(op(v, 1))) && ce_can_use_sext(op(v, 1)) {
        let a = op(v, 0);
        let ci = op(v, 1);
        ce_pre.push(CCond { pred: P_UGE, a: a, b: c_int_ty(vals[a].ty, (0 - (ce_sext(ci) as! u64))) });
        let oa = ce_decompose(a, is_signed);
        let ob = ce_decompose(ci, true);
        let s, o = ce_add_ov(oa, ob);
        if !o { return s; }
        return dc_var(mark, v);
    }
    if ce_obo(v, OP_ADD, FL_NSW) {
        let a = op(v, 0);
        let b = op(v, 1);
        if !ce_known_nonneg(a, 0) { ce_pre.push(CCond { pred: P_SGE, a: a, b: c_int_ty(vals[a].ty, 0) }); }
        if !ce_known_nonneg(b, 0) { ce_pre.push(CCond { pred: P_SGE, a: b, b: c_int_ty(vals[b].ty, 0) }); }
        let oa = ce_decompose(a, is_signed);
        let ob = ce_decompose(b, is_signed);
        let s, o = ce_add_ov(oa, ob);
        if !o { return s; }
        return dc_var(mark, v);
    }
    if is_inst_op(v, OP_OR) && (op_flags(v) & FL_DISJOINT) != 0 && ce_isa_cint(op(v, 1)) {
        let oa = ce_decompose(op(v, 0), is_signed);
        let ob = ce_decompose(op(v, 1), is_signed);
        let s, o = ce_add_ov(oa, ob);
        if !o { return s; }
        return dc_var(mark, v);
    }
    if ce_obo(v, OP_SHL, FL_NUW) && ce_isa_cint(op(v, 1)) && ce_can_use_sext(op(v, 1)) {
        let sh = ce_sext(op(v, 1));
        if sh < 0 || sh >= 64 { return dc_var(mark, v); }
        let b = dc_vars.len;
        let o0 = ce_decompose(op(v, 0), is_signed);
        let no, o = dc_mul(b, o0, (1 as i64) << sh);
        if !o { return no; }
        return dc_var(mark, v);
    }
    if ce_obo(v, OP_MUL, FL_NUW) && ce_isa_cint(op(v, 1)) && ce_can_use_sext(op(v, 1)) && !ap_is_neg(ci_ap(op(v, 1))) {
        let f = ce_sext(op(v, 1));
        let b = dc_vars.len;
        let o0 = ce_decompose(op(v, 0), is_signed);
        let no, o = dc_mul(b, o0, f);
        if !o { return no; }
        return dc_var(mark, v);
    }
    if ce_obo(v, OP_SUB, FL_NUW) {
        let oa = ce_decompose(op(v, 0), is_signed);
        let bb = dc_vars.len;
        let ob = ce_decompose(op(v, 1), is_signed);
        let nb, o1 = dc_mul(bb, ob, -1);
        if o1 { return dc_var(mark, v); }
        let s, o2 = ce_add_ov(oa, nb);
        if o2 { return dc_var(mark, v); }
        return s;
    }
    return dc_var(mark, v);
}

// ---------------------------------------------------------------------------------------------
// ConstraintInfo

// getConstraint(Pred, Op0, Op1, NewVariables, ForceSignedSystem): the result's runs are pushed on ce_coef / ce_pre
fn ce_get_constraint(pred0: i64, op00: i32, op10: i32, nvars: i32[>..<]&, force_signed: bool) -> CT {
    var pred = pred0;
    var op0 = op00;
    var op1 = op10;
    var is_eq = false;
    var is_ne = false;
    if pred == P_UGT || pred == P_UGE || pred == P_SGT || pred == P_SGE {
        pred = pred_swapped(pred);
        let t = op0; op0 = op1; op1 = t;
    } else if pred == P_EQ {
        if !force_signed && m_zero(op1) { pred = P_ULE; }
        else { is_eq = true; pred = P_ULE; }
    } else if pred == P_NE {
        if !force_signed && m_zero(op1) {
            pred = pred_swapped(P_UGT);
            let t = op0; op0 = op1; op1 = t;
        } else { is_ne = true; pred = P_ULE; }
    }
    if pred != P_ULE && pred != P_ULT && pred != P_SLE && pred != P_SLT { return ct_empty(); }

    let pb = ce_pre.len;
    let is_signed = force_signed || pred_is_signed(pred);
    let s: i64 = if is_signed { 1 } else { 0 };
    let dm = dc_vars.len;
    let adec_off = ce_decompose(strip_ptr_casts_same_repr(op0), is_signed);
    let am = dc_vars.len;
    let bdec_off = ce_decompose(strip_ptr_casts_same_repr(op1), is_signed);
    let bm = dc_vars.len;
    let off1 = ((0 as u64) - (adec_off as! u64)) as! i64;   // Offset1 *= -1
    let off2 = bdec_off;

    var nidx = hm_new();
    fn get_or_add(v: i32) -> i64 {
        let x = cs_v2i_get(s, v);
        if x >= 0 { return x; }
        let y = hm_get(nidx, v as u64, -1);
        if y >= 0 { return y; }
        let idx = cs_v2i_size(s) + nvars.len + 1;
        hm_put(nidx, v as u64, idx);
        nvars.push(v);
        return idx;
    }
    for k in dm..bm { get_or_add(dc_vars[k].v); }
    let cb = ce_coef.len;
    let total = cs_v2i_size(s) + nvars.len + 1;
    for k in total { ce_coef.push(0); }
    var res = CT { cb: cb, cn: total, pb: pb, pn: 0, signed: is_signed, eq: is_eq, ne: is_ne };
    for k in dm..am {
        let i = get_or_add(dc_vars[k].v);
        ce_coef[cb + i] = ((ce_coef[cb + i] as! u64) + (dc_vars[k].c as! u64)) as! i64;
    }
    for k in am..bm {
        let i = get_or_add(dc_vars[k].v);
        let r, o = ce_sub_ov(ce_coef[cb + i], dc_vars[k].c);
        ce_coef[cb + i] = r;
        if o { dc_vars.resize(dm); ce_coef.resize(cb); ce_pre.resize(pb); return ct_empty(); }
    }
    dc_vars.resize(dm);
    var sum, o = ce_add_ov(off1, off2);
    if o { ce_coef.resize(cb); ce_pre.resize(pb); return ct_empty(); }
    if pred == P_SLT || pred == P_ULT {
        let s2, o2 = ce_add_ov(sum, -1);
        if o2 { ce_coef.resize(cb); ce_pre.resize(pb); return ct_empty(); }
        sum = s2;
    }
    ce_coef[cb] = sum;
    // the preconditions were pushed by decompose (between pb and now)
    res.pn = ce_pre.len - pb;
    // move the coefficients behind the preconditions? both are separate stacks: nothing to move
    while nvars.len > 0 {
        let last = ce_coef[cb + res.cn - 1];
        if last != 0 { break; }
        ce_coef.pop();
        res.cn = res.cn - 1;
        let rv = nvars.pop();
        hm_del(nidx, rv as u64);
    }
    return res;
}

// getConstraintForSolving
fn ce_get_constraint_for_solving(pred0: i64, op0: i32, op1: i32) -> CT {
    var pred = pred0;
    let nullc = c_null(vals[op0].ty);
    if (pred == P_ULE && op0 == nullc) || (pred == P_UGE && op1 == nullc) {
        var r = ct_empty();
        let n = cs_v2i_size(0);
        for k in n { ce_coef.push(0); }
        r.cn = n;
        return r;
    }
    if pred_is_signed(pred) && ce_known_nonneg(op0, 5) && ce_known_nonneg(op1, 5) { pred = pred_unsigned(pred); }
    var nvars: i32[>..<] = [];
    let r = ce_get_constraint(pred, op0, op1, nvars, false);
    if nvars.len > 0 { ct_release(r); return ct_empty(); }
    return r;
}

// ConstraintTy::isValid
recursive fn ce_is_valid(c: CT) -> bool {
    if c.cn == 0 { return false; }
    for k in c.pn {
        let pc = ce_pre[c.pb + k];
        if !ce_does_hold(pc.pred, pc.a, pc.b) { return false; }
    }
    return true;
}

// doesHold
recursive fn ce_does_hold(pred: i64, a: i32, b: i32) -> bool {
    let r = ce_get_constraint_for_solving(pred, a, b);
    var res = ce_is_valid(r);
    if res { res = cs_is_condition_implied(if r.signed { 1 } else { 0 }, ce_coef[r.cb..r.cb + r.cn]); }
    ct_release(r);
    return res;
}

// ConstraintTy::isImpliedBy: 0 = nullopt, 1 = true, 2 = false
fn ce_is_implied_by(c: CT) -> i64 {
    let s: i64 = if c.signed { 1 } else { 0 };
    let co = ce_coef[c.cb..c.cb + c.cn];
    let implied = cs_is_condition_implied(s, co);
    var tmp: i64[>..<] = [];
    if c.eq || c.ne {
        // negateOrEqual
        tmp.resize(0);
        var ok = true;
        for x in co { let m, o = ce_mul_ov(x, -1); if o { ok = false; } tmp.push(m); }
        let nimp = ok && cs_is_condition_implied(s, tmp);
        if implied && nimp { return if c.eq { 1 } else { 2 }; }
        let neg_implied = ce_negated_implied(s, co);
        // toStrictLessThan
        tmp.resize(0);
        for x in co { tmp.push(x); }
        let t0, o0 = ce_sub_ov(tmp[0], 1);
        tmp[0] = t0;
        let strict_implied = !o0 && cs_is_condition_implied(s, tmp);
        if neg_implied || strict_implied { return if c.ne { 1 } else { 2 }; }
        return 0;
    }
    if implied { return 1; }
    if ce_negated_implied(s, co) { return 2; }
    return 0;
}
// !negate(R).empty() && isConditionImplied(negate(R))
fn ce_negated_implied(s: i64, co: const i64[:]) -> bool {
    var t: i64[>..<] = [];
    for x in co { t.push(x); }
    let c0, o0 = ce_add_ov(t[0], 1);
    if o0 { return false; }
    t[0] = c0;
    for k in t.len { let m, o = ce_mul_ov(t[k], -1); if o { return false; } t[k] = m; }
    return cs_is_condition_implied(s, t);
}

// DFSInStack
struct StEnt { num_in: u32, num_out: u32, signed: bool, rel_at: i64, rel_n: i64 }
var st_ent: StEnt[>..<];
var st_rel: i32[>..<];
fn st_push(ni: u32, no: u32, signed: bool) { st_ent.push(StEnt { num_in: ni, num_out: no, signed: signed, rel_at: st_rel.len, rel_n: 0 }); }

// addFact
fn ce_add_fact(pred: i64, a: i32, b: i32, ni: u32, no: u32) {
    ce_add_fact_impl(pred, a, b, ni, no, false);
    if pred_is_equality(pred) { ce_add_fact_impl(pred, a, b, ni, no, true); }
}

// addFactImpl
fn ce_add_fact_impl(pred: i64, a: i32, b: i32, ni: u32, no: u32, force_signed: bool) {
    var nvars: i32[>..<] = [];
    let r = ce_get_constraint(pred, a, b, nvars, force_signed);
    if !ce_is_valid(r) || r.ne { ct_release(r); return; }
    let s: i64 = if r.signed { 1 } else { 0 };
    if r.cn == 0 { ct_release(r); return; }
    var coef: i64[>..<] = [];
    for k in r.cn { coef.push(ce_coef[r.cb + k]); }
    ct_release(r);
    if !cs_add_row_fill(s, coef) { return; }
    let rel_at = st_rel.len;
    for v in nvars {
        if cs_v2i_get(s, v) < 0 { cs_v2i_put(s, v, cs_v2i_size(s) + 1); }
        st_rel.push(v);
    }
    st_ent.push(StEnt { num_in: ni, num_out: no, signed: r.signed, rel_at: rel_at, rel_n: nvars.len });
    if !r.signed {
        for v in nvars {
            var vp: i64[>..<] = [];
            for k in cs_v2i_size(s) + 1 { vp.push(0); }
            vp[cs_v2i_get(s, v)] = -1;
            cs_add_row(s, vp);
            st_push(ni, no, r.signed);
        }
    }
    if r.eq {
        for k in coef.len { coef[k] = ((0 as u64) - (coef[k] as! u64)) as! i64; }
        cs_add_row_fill(s, coef);
        st_push(ni, no, r.signed);
    }
}

// transferToOtherSystem
fn ce_transfer_to_other_system(pred: i64, a: i32, b: i32, ni: u32, no: u32) {
    fn known_nonneg(v: i32) -> bool {
        return ce_does_hold(P_SGE, v, c_int_ty(vals[v].ty, 0)) || ce_known_nonneg(v, 5);
    }
    if !ty_is_int(vals[a].ty) { return; }
    if pred == P_ULT || pred == P_ULE {
        if known_nonneg(b) {
            ce_add_fact(P_SGE, a, c_int_ty(vals[b].ty, 0), ni, no);
            ce_add_fact(pred_signed(pred), a, b, ni, no);
        }
    } else if pred == P_UGE || pred == P_UGT {
        if known_nonneg(a) {
            ce_add_fact(P_SGE, b, c_int_ty(vals[b].ty, 0), ni, no);
            ce_add_fact(pred_signed(pred), a, b, ni, no);
        }
    } else if pred == P_SLT {
        if known_nonneg(a) { ce_add_fact(P_ULT, a, b, ni, no); }
    } else if pred == P_SGT {
        if ce_does_hold(P_SGE, b, c_all_ones(vals[b].ty)) { ce_add_fact(P_UGE, a, c_int_ty(vals[b].ty, 0), ni, no); }
        if known_nonneg(b) { ce_add_fact(P_UGT, a, b, ni, no); }
    } else if pred == P_SGE {
        if known_nonneg(b) { ce_add_fact(P_UGE, a, b, ni, no); }
    }
}

// ---------------------------------------------------------------------------------------------
// The worklist (FactOrCheck)

let FK_COND = 0;      // ConditionFact
let FK_IFACT = 1;     // InstFact
let FK_ICHECK = 2;    // InstCheck
let FK_UCHECK = 3;    // UseCheck
struct CFact { kind: i64, inst: i32, u: i32, pred: i64, a: i32, b: i32, hpred: i64, ha: i32, hb: i32, num_in: u32, num_out: u32 }
var ce_wl: CFact[>..<];
var ce_pos = hm_new();      // instruction -> position in its block (Instruction::comesBefore for the sort)

fn ce_dfs_in(bb: i32) -> u32 { dt_dfs_in(ce_fv, DT_DOM, bb) }
fn ce_dfs_out(bb: i32) -> u32 { dt_dfs_out(ce_fv, DT_DOM, bb) }
fn ce_cond_fact(bb: i32, pred: i64, a: i32, b: i32, hp: i64, ha: i32, hb: i32) {
    ce_wl.push(CFact { kind: FK_COND, inst: -1, u: -1, pred: pred, a: a, b: b, hpred: hp, ha: ha, hb: hb,
                       num_in: ce_dfs_in(bb), num_out: ce_dfs_out(bb) });
}
fn ce_inst_entry(bb: i32, kind: i64, i: i32) {
    ce_wl.push(CFact { kind: kind, inst: i, u: -1, pred: -1, a: -1, b: -1, hpred: -1, ha: -1, hb: -1,
                       num_in: ce_dfs_in(bb), num_out: ce_dfs_out(bb) });
}

// getContextInstForUse
fn ce_use_context(u: i32) -> i32 {
    let user = uses[u].user;
    if iop(user) == OP_PHI {
        let k = (u - vals[user].ops) as i64;
        return block_terminator(phi_block(user, k));
    }
    return user;
}
fn ce_fact_context(f: CFact) -> i32 { if f.kind == FK_UCHECK { ce_use_context(f.u) } else { f.inst } }
fn ce_fact_to_simplify(f: CFact) -> i32 {
    if f.kind == FK_ICHECK { return f.inst; }
    let v = uses[f.u].val;
    return if v >= 0 && is_inst(v) { v } else { -1 };
}

// m_ICmpLike(Pred, m_Value(A), m_Value(B)): (ok, CmpPredicate, A, B)
fn ce_icmp_like(v: i32) -> bool, i64, i32, i32 {
    if is_inst_op(v, OP_ICMP) { return true, icmp_cp(v), op(v, 0), op(v, 1); }
    if is_int_or_int_vec_w(vals[v].ty, 1) && is_inst_op(v, OP_TRUNC) && (op_flags(v) & FL_NUW) != 0 {
        let x = op(v, 0);
        return true, P_NE, x, c_null(vals[x].ty);
    }
    return false, 0, -1, -1;
}

// DT.dominates(BasicBlockEdge(BB, Succ), Succ)
fn ce_can_add_successor(bb: i32, succ: i32) -> bool { dt_edge_dominates_block(bb, succ, succ) }

// addInfoForInductions
fn ce_add_info_for_inductions(bb: i32) {
    let l = li_loop_for(bb);
    if l < 0 || loop_header(l) != bb { return; }
    let term = block_terminator(bb);
    if term < 0 || iop(term) != OP_CONDBR { return; }
    let cmp = op(term, 0);
    if !is_inst_op(cmp, OP_ICMP) { return; }
    // IndValue = m_Value(A, m_CombineOr(m_Phi(PN), m_c_Add(m_Phi(PN), m_APInt(IncStep))))
    var pn: i32 = -1;
    var inc: i32 = -1;   // the IncStep constant (scalar ConstantInt), -1 = none
    fn ind_value(v: i32) -> bool {
        if is_inst_op(v, OP_PHI) { pn = v; return true; }
        if is_inst_op(v, OP_ADD) {
            for side in 2 {
                let x = op(v, side);
                let y = op(v, 1 - side);
                if is_inst_op(x, OP_PHI) {
                    pn = x;
                    let c = m_apint(y);
                    if c >= 0 { inc = c; return true; }
                }
            }
        }
        return false;
    }
    var a: i32 = -1;
    var b: i32 = -1;
    var pred = inst_pred(cmp);
    if ind_value(op(cmp, 0)) { a = op(cmp, 0); b = op(cmp, 1); }
    else if ind_value(op(cmp, 1)) { a = op(cmp, 1); b = op(cmp, 0); pred = pred_swapped(pred); }
    else { return; }
    if inst_parent(pn) != bb || nops(pn) != 2 || !sc_is_scevable(vals[pn].ty) { return; }
    var in_loop_succ: i32 = -1;
    if pred == P_NE { in_loop_succ = term_succ(term, 0); }
    else if pred == P_EQ { in_loop_succ = term_succ(term, 1); }
    else { return; }
    if !loop_contains(l, in_loop_succ) || !loop_is_exiting(l, bb) || in_loop_succ == bb { return; }
    let lpred = loop_predecessor(l);
    if lpred < 0 { return; }
    if is_inst(b) && loop_contains(l, inst_parent(b)) { return; }   // !L->isLoopInvariant(B)
    let ar = sc_get_scev(pn);
    if !sc_is_addrec(ar) || sc_loop(ar) != l { return; }
    let start_scev = sc_op(ar, 0);
    var start: i32 = -1;
    if sc_kind(start_scev) == SC_CONST { start = sc_value(start_scev); }
    else { start = phi_value(pn, phi_block_index(pn, lpred)); }
    let dtn = in_loop_succ;
    let mono_u = sc_get_monotonic_predicate_type(ar, P_UGT) == SC_MONO_INC;
    let mono_s = sc_get_monotonic_predicate_type(ar, P_SGT) == SC_MONO_INC;
    if mono_u { ce_cond_fact(dtn, P_UGE, pn, start, -1, -1, -1); }
    if mono_s { ce_cond_fact(dtn, P_SGE, pn, start, -1, -1, -1); }
    let step = sc_get_step_recurrence(ar);
    if sc_kind(step) != SC_CONST { return; }
    let so = sc_ap(step);
    if inc >= 0 && (!ap_eq(ci_ap(inc), so) || ap_is_neg(so)) { return; }
    if ap_is_neg(so) {
        if !ap_is_one(ap_neg(so)) { return; }
        ce_cond_fact(dtn, P_UGE, start, pn, P_ULE, b, start);
        ce_cond_fact(dtn, P_SGE, start, pn, P_SLE, b, start);
        ce_cond_fact(dtn, P_UGT, pn, b, P_ULE, b, start);
        ce_cond_fact(dtn, P_SGT, pn, b, P_SLE, b, start);
        return;
    }
    if ap_is_zero(so) || ap_is_neg(so) { return; }
    if !ap_is_one(so) {
        let bms = sc_minus(sc_get_scev(b), start_scev);
        if sc_is_cnc(bms) || !ap_is_zero(ap_urem(sc_get_constant_multiple(bms, -1), so)) { return; }
    }
    var lower = start;
    if inc >= 0 {
        if !ce_isa_cint(start) { return; }
        let sum, ov = ap_uadd_ov(ci_ap(start), so);
        if ov { return; }
        lower = c_int_ap(vals[start].ty, sum);
    }
    if !mono_u { ce_cond_fact(dtn, P_UGE, pn, start, P_ULE, lower, b); }
    if !mono_s && inc < 0 { ce_cond_fact(dtn, P_SGE, pn, start, P_SLE, start, b); }
    ce_cond_fact(dtn, P_ULT, pn, b, P_ULE, lower, b);
    if inc < 0 { ce_cond_fact(dtn, P_SLT, pn, b, P_SLE, start, b); }
    var exits: i32[>..<] = [];
    loop_exit_blocks(l, exits);
    for eb in exits {
        if dt_dominates_block(DT_DOM, bb, eb) { ce_cond_fact(eb, P_ULE, a, b, P_ULE, lower, b); }
    }
}

// getConstraintFromMemoryAccess: (ok, pred, A, B)
fn ce_constraint_from_memory_access(g: i32, access_size: u64) -> bool, i64, i32, i32 {
    let cm = co_vals.len;
    let r = ce_collect_offsets(g);
    let nvar = co_vals.len - cm;
    if r.base < 0 || (r.nw & CE_NUW) == 0 || nvar != 1 { co_vals.resize(cm); co_scale.resize(cm); return false, 0, -1, -1; }
    let index = co_vals[cm];
    let scale = co_scale[cm];
    co_vals.resize(cm); co_scale.resize(cm);
    let bw = r.w;
    if ty_bits(ty_scalar(vals[index].ty)) != bw { return false, 0, -1, -1; }
    let size, ok, scal = bas_base_object_size(r.base, true, true);
    if !ok || scal { return false, 0, -1, -1; }
    let mi = ap_udiv(ap_sub(ap_u64(size - access_size, bw), r.cst), scale);
    return true, P_ULE, index, c_int_ap(vals[index].ty, mi);
}

// State::addInfoFor
fn ce_add_info_for(bb: i32) {
    ce_add_info_for_inductions(bb);
    var guaranteed = true;
    var i = block_first(bb);
    while i >= 0 {
        let cur = i;
        i = inst_next(i);
        let o = iop(cur);
        if o == OP_ICMP {
            var u = vals[cur].first_use;
            while u >= 0 {
                let ui = ce_use_context(u);
                let ubb = inst_parent(ui);
                if dt_has_node(DT_DOM, ubb) {
                    ce_wl.push(CFact { kind: FK_UCHECK, inst: -1, u: u, pred: -1, a: -1, b: -1, hpred: -1, ha: -1, hb: -1,
                                       num_in: ce_dfs_in(ubb), num_out: ce_dfs_out(ubb) });
                }
                u = uses[u].next;
            }
            continue;
        }
        if (o == OP_LOAD || o == OP_STORE) && !inst_is_volatile(cur) {
            let ptr = if o == OP_LOAD { op(cur, 0) } else { op(cur, 1) };
            let aty = if o == OP_LOAD { vals[cur].ty } else { vals[op(cur, 0)].ty };
            if is_inst_op(ptr, OP_GEP) && !vt_is_scalable_ty(aty) {
                if guaranteed {
                    let ok, p, a, b = ce_constraint_from_memory_access(ptr, dl_store_size(aty) as u64);
                    if ok { ce_cond_fact(bb, p, a, b, -1, -1, -1); }
                } else {
                    ce_inst_entry(bb, FK_IFACT, cur);
                }
            }
        }
        let id = inst_iid(cur);
        if id == IID_assume {
            let ok, p, a, b = ce_icmp_like(op(cur, 0));
            if ok {
                if guaranteed { ce_cond_fact(bb, p, a, b, -1, -1, -1); }
                else { ce_inst_entry(bb, FK_IFACT, cur); }
            }
        } else if id == IID_ssub_with_overflow || id == IID_ucmp || id == IID_scmp {
            ce_inst_entry(bb, FK_ICHECK, cur);
        } else if id == IID_umin || id == IID_umax || id == IID_smin || id == IID_smax {
            ce_inst_entry(bb, FK_ICHECK, cur);
            if ce_not_poison(cur) { ce_inst_entry(bb, FK_IFACT, cur); }
        } else if id == IID_uadd_sat || id == IID_usub_sat {
            if ce_not_poison(cur) { ce_inst_entry(bb, FK_IFACT, cur); }
        } else if id == IID_abs {
            ce_inst_entry(bb, FK_IFACT, cur);
        }
        if (o == OP_UREM || o == OP_UDIV) && ce_not_poison(cur) { ce_inst_entry(bb, FK_IFACT, cur); }
        guaranteed = guaranteed && guaranteed_to_transfer(cur);
    }
    let term = block_terminator(bb);
    if term < 0 { return; }
    if iop(term) == OP_SWITCH {
        let cond = op(term, 0);
        for k in sw_ncases(term) {
            let succ = op(term, 3 + 2 * k);
            let v = op(term, 2 + 2 * k);
            if !ce_can_add_successor(bb, succ) { continue; }
            ce_cond_fact(succ, P_EQ, cond, v, -1, -1, -1);
        }
        return;
    }
    if iop(term) != OP_CONDBR { return; }
    let cond = op(term, 0);
    let is_or0 = m_logical(cond, false);
    let o_a = lg_a; let o_b = lg_b;
    let is_and0 = m_logical(cond, true);
    let a_a = lg_a; let a_b = lg_b;
    if is_or0 || is_and0 {
        let is_or = is_or0;
        var is_and = is_and0;
        if is_or && is_and { is_and = false; }
        let op0 = if is_or0 { o_a } else { a_a };
        let op1 = if is_or0 { o_b } else { a_b };
        let succ = term_succ(term, if is_or { 1 } else { 0 });
        if ce_can_add_successor(bb, succ) {
            var wl: i32[>..<] = [];
            var seen = hm_new();
            fn queue(v: i32) { if !hm_has(seen, v as u64) { hm_put(seen, v as u64, 1); wl.push(v); } }
            queue(op1);
            queue(op0);
            while wl.len > 0 {
                let c = wl.pop();
                let ok, p, a, b = ce_icmp_like(c);
                if ok {
                    ce_cond_fact(succ, if is_or { cp(pred_inverse(cp_pred(p)), cp_ss(p)) } else { p }, a, b, -1, -1, -1);
                    continue;
                }
                if is_or && m_logical(c, false) { let x = lg_a; let y = lg_b; queue(y); queue(x); continue; }
                if is_and && m_logical(c, true) { let x = lg_a; let y = lg_b; queue(y); queue(x); continue; }
            }
        }
        return;
    }
    let ok, p, a, b = ce_icmp_like(cond);
    if !ok { return; }
    let s0 = term_succ(term, 0);
    let s1 = term_succ(term, 1);
    if ce_can_add_successor(bb, s0) { ce_cond_fact(s0, p, a, b, -1, -1, -1); }
    if ce_can_add_successor(bb, s1) { ce_cond_fact(s1, cp(pred_inverse(cp_pred(p)), cp_ss(p)), a, b, -1, -1, -1); }
}

// ---------------------------------------------------------------------------------------------
// Checks

var ce_to_remove: i32[>..<];

// checkCondition: 0 = nullopt, 1 = true, 2 = false
fn ce_check_condition(pred: i64, a: i32, b: i32) -> i64 {
    let r = ce_get_constraint_for_solving(pred, a, b);
    if r.cn == 0 || !ce_is_valid(r) { ct_release(r); return 0; }
    let x = ce_is_implied_by(r);
    ct_release(r);
    return x;
}

fn ce_dfs_ok(bb: i32, ni: u32, no: u32) -> bool {
    if !dt_has_node(DT_DOM, bb) { return false; }
    return !(ce_dfs_in(bb) < ni || ce_dfs_out(bb) > no);
}

// checkAndReplaceCondition (ReplaceCmpWithConstant)
fn ce_replace_cmp_with_constant(cmp: i32, is_true: bool, ni: u32, no: u32, ctx: i32) -> bool {
    let c = c_bool_ty(vals[cmp].ty, is_true);
    var changed = false;
    var u = vals[cmp].first_use;
    while u >= 0 {
        let nx = uses[u].next;
        let ui = ce_use_context(u);
        var ok = ce_dfs_ok(inst_parent(ui), ni, no);
        if ok && inst_parent(ui) == inst_parent(ctx) && comes_before(ui, ctx) { ok = false; }
        if ok && inst_iid(uses[u].user) == IID_assume { ok = false; }
        if ok { use_set(u, c); changed = true; }
        u = nx;
    }
    var users: i32[>..<] = [];
    find_dbg_users(cmp, users);
    for r in users {
        if dbgrecs[r].kind as i64 == DR_ASSIGN { ce_fail("replaceVariableLocationOp of a dbg_assign record"); }
        let owner = dbgrecs[r].owner;
        if owner < 0 { ce_fail("debug records at the end of a block"); }
        if !ce_dfs_ok(inst_parent(owner), ni, no) { continue; }
        if inst_parent(owner) == inst_parent(ctx) && comes_before(owner, ctx) { continue; }
        sv_replace_location_op(r, cmp, c);
    }
    if vals[cmp].first_use < 0 { ce_to_remove.push(cmp); }
    return changed;
}

fn ce_check_and_replace_condition(cmp: i32, ni: u32, no: u32, ctx: i32) -> bool {
    let p = inst_pred(cmp);
    let x = ce_check_condition(p, op(cmp, 0), op(cmp, 1));
    if x != 0 { return ce_replace_cmp_with_constant(cmp, x == 1, ni, no, ctx); }
    if (op_flags(cmp) & FL_SAMESIGN) != 0 && pred_is_unsigned(p) {
        let y = ce_check_condition(pred_signed(p), op(cmp, 0), op(cmp, 1));
        if y != 0 { return ce_replace_cmp_with_constant(cmp, y == 1, ni, no, ctx); }
    }
    return false;
}

fn ce_minmax_pred(id: i32) -> i64 {
    if id == IID_smax { return P_SGT; }
    if id == IID_smin { return P_SLT; }
    if id == IID_umax { return P_UGT; }
    return P_ULT;
}
fn ce_non_strict(p: i64) -> i64 { match p { 34 => 35, 36 => 37, 38 => 39, 40 => 41, _ => p } }

// checkAndReplaceMinMax
fn ce_check_and_replace_minmax(mm: i32) -> bool {
    let p = ce_non_strict(ce_minmax_pred(inst_iid(mm)));
    let l = cb_arg(mm, 0);
    let r = cb_arg(mm, 1);
    let x = ce_check_condition(p, l, r);
    if x != 0 { rauw(mm, if x == 1 { l } else { r }); ce_to_remove.push(mm); return true; }
    let y = ce_check_condition(p, r, l);
    if y != 0 { rauw(mm, if y != 1 { l } else { r }); ce_to_remove.push(mm); return true; }
    return false;
}

// checkAndReplaceCmp
fn ce_check_and_replace_cmp(i: i32) -> bool {
    let l = cb_arg(i, 0);
    let r = cb_arg(i, 1);
    let signed = inst_iid(i) == IID_scmp;
    let ty = vals[i].ty;
    if ce_check_condition(if signed { P_SGT } else { P_UGT }, l, r) == 1 { rauw(i, c_int_ty(ty, 1)); ce_to_remove.push(i); return true; }
    if ce_check_condition(if signed { P_SLT } else { P_ULT }, l, r) == 1 { rauw(i, c_all_ones(ty)); ce_to_remove.push(i); return true; }
    if ce_check_condition(P_EQ, l, r) == 1 { rauw(i, c_int_ty(ty, 0)); ce_to_remove.push(i); return true; }
    return false;
}

// removeEntryFromStack
fn ce_remove_entry_from_stack() {
    let e = st_ent[st_ent.len - 1];
    let s: i64 = if e.signed { 1 } else { 0 };
    cs_pop_last(s);
    for k in e.rel_n { cs_v2i_erase(s, st_rel[e.rel_at + k]); }
    cs_pop_vars(s, e.rel_n);
    st_rel.resize(e.rel_at);
    st_ent.pop();
}

// checkOrAndOpImpliedByOther
fn ce_check_or_and_op_implied_by_other(cb: CFact) -> bool {
    let join = ce_fact_context(cb);
    if vals[join].first_use < 0 { return false; }
    let cmp = ce_fact_to_simplify(cb);
    let other: i64 = if op(join, 0) == cmp { 1 } else { 0 };
    if other != 0 && iop(join) == OP_SELECT { return false; }
    let old = st_ent.len;
    let is_or = m_logical(join, false);
    var wl: i32[>..<] = [];
    wl.push(op(join, other));
    while wl.len > 0 {
        let v = wl.pop();
        if is_inst_op(v, OP_ICMP) {
            var p = inst_pred(v);
            if is_or { p = pred_inverse(p); }
            ce_add_fact(p, op(v, 0), op(v, 1), cb.num_in, cb.num_out);
            continue;
        }
        if is_or && m_logical(v, false) { let x = lg_a; let y = lg_b; wl.push(x); wl.push(y); }
        else if !is_or && m_logical(v, true) { let x = lg_a; let y = lg_b; wl.push(x); wl.push(y); }
    }
    var res = false;
    if old != st_ent.len {
        let x = ce_check_condition(inst_pred(cmp), op(cmp, 0), op(cmp, 1));
        if x != 0 {
            if is_or == (x == 1) { rauw(join, c_bool_ty(vals[join].ty, x == 1)); }
            else { rauw(join, op(join, other)); }
            ce_to_remove.push(join);
            res = true;
        }
    }
    while old < st_ent.len { ce_remove_entry_from_stack(); }
    return res;
}

// replaceSubOverflowUses
fn ce_replace_sub_overflow_uses(ii: i32, a: i32, b: i32) -> bool {
    var changed = false;
    var sub: i32 = -1;
    var u = vals[ii].first_use;
    while u >= 0 {
        let nx = uses[u].next;
        let usr = uses[u].user;
        u = nx;
        var idx: i64 = -1;
        if is_inst_op(usr, OP_EXTRACTVALUE) && insts[inst_of(usr)].naux == 1 { idx = ints[insts[inst_of(usr)].aux] as i64; }
        if idx == 0 {
            if sub < 0 {
                if is_constant(a) && is_constant(b) { sub = binop_dispatch(OP_SUB, a, b); }
                if sub < 0 {
                    sub = create_inst(OP_SUB, vals[a].ty, [a, b]);
                    inst_insert_before(sub, ii);
                    let dl = inst_get_md(ii, 0);
                    if dl >= 0 { inst_set_md(sub, 0, dl); }
                }
            }
            rauw(usr, sub);
            changed = true;
        } else if idx == 1 {
            rauw(usr, c_false());
            changed = true;
        } else { continue; }
        if vals[usr].first_use < 0 {
            ce_to_remove.push(usr);
            set_op(usr, 0, c_poison(vals[ii].ty));
            changed = true;
        }
    }
    if vals[ii].first_use < 0 { inst_erase_from_parent(ii); changed = true; }
    return changed;
}

// tryToSimplifyOverflowMath
fn ce_does_condition_hold(pred: i64, a: i32, b: i32) -> bool {
    let r = ce_get_constraint_for_solving(pred, a, b);
    var res = r.cn >= 2 && ce_is_valid(r);
    if res { res = cs_is_condition_implied(if r.signed { 1 } else { 0 }, ce_coef[r.cb..r.cb + r.cn]); }
    ct_release(r);
    return res;
}
fn ce_try_to_simplify_overflow_math(ii: i32) -> bool {
    if inst_iid(ii) != IID_ssub_with_overflow { return false; }
    let a = cb_arg(ii, 0);
    let b = cb_arg(ii, 1);
    if !ce_does_condition_hold(P_SGE, a, b) || !ce_does_condition_hold(P_SGE, b, c_int_ty(vals[a].ty, 0)) { return false; }
    return ce_replace_sub_overflow_uses(ii, a, b);
}

// ---------------------------------------------------------------------------------------------
// eliminateConstraints

// the AddFact lambda
fn ce_add_fact_cb(cb: CFact, pred: i64, a: i32, b: i32) {
    let p = cp_pred(pred);
    let s: i64 = if pred_is_signed(p) { 1 } else { 0 };
    if cs_nrows[s] > flag_int("constraint-elimination-max-rows", 500) { return; }
    ce_add_fact(p, a, b, cb.num_in, cb.num_out);
    if pred_is_signed(p) || pred_is_unsigned(p) {
        if cp_ss(pred) { ce_add_fact(pred_flipped_signedness(p), a, b, cb.num_in, cb.num_out); }
        else { ce_transfer_to_other_system(p, a, b, cb.num_in, cb.num_out); }
    }
}

fn ce_has_no_const_op(f: CFact) -> bool { !ce_isa_cint(f.a) && !ce_isa_cint(f.b) }
fn ce_fact_less(x: CFact, y: CFact) -> bool {
    if x.num_in == y.num_in {
        if x.kind == FK_COND && y.kind == FK_COND { return !ce_has_no_const_op(x) && ce_has_no_const_op(y); }
        if x.kind == FK_COND { return true; }
        if y.kind == FK_COND { return false; }
        return hm_get(ce_pos, ce_fact_context(x) as u64, 0) < hm_get(ce_pos, ce_fact_context(y) as u64, 0);
    }
    return x.num_in < y.num_in;
}

fn ce_eliminate_constraints(fv: i32) -> bool {
    var changed = false;
    dt_update_dfs_numbers(fv, DT_DOM);
    cs_reset();
    dc_vars.resize(0);
    ce_coef.resize(0);
    ce_pre.resize(0);
    co_vals.resize(0);
    co_scale.resize(0);
    st_ent.resize(0);
    st_rel.resize(0);
    ce_wl.resize(0);
    ce_to_remove.resize(0);
    hm_clear(ce_pos);
    // ConstraintInfo(DL, FunctionArgs)
    let na = func_nargs(fv);
    cs_nv[0] = na;
    cs_nv[1] = na;
    for k in na {
        cs_v2i_put(0, func_arg(fv, k), k + 1);
        cs_v2i_put(1, func_arg(fv, k), k + 1);
    }
    for k in na {
        var vp: i64[>..<] = [];
        for j in cs_v2i_size(0) + 1 { vp.push(0); }
        vp[cs_v2i_get(0, func_arg(fv, k))] = -1;
        cs_add_row(0, vp);
    }
    var bb = func_entry(fv);
    while bb >= 0 {
        if dt_has_node(DT_DOM, bb) { ce_add_info_for(bb); }
        var i = block_first(bb);
        var n: i64 = 0;
        while i >= 0 { hm_put(ce_pos, i as u64, n); n++; i = inst_next(i); }
        bb = block_next(bb);
    }
    std_stable_sort(ce_wl, 0, ce_wl.len) { x, y => ce_fact_less(x, y) };

    for wi in ce_wl.len {
        let cb = ce_wl[wi];
        while st_ent.len > 0 {
            let e = st_ent[st_ent.len - 1];
            if cb.num_out <= e.num_out { break; }
            ce_remove_entry_from_stack();
        }
        if cb.kind == FK_ICHECK || cb.kind == FK_UCHECK {
            let inst = ce_fact_to_simplify(cb);
            if inst < 0 { continue; }
            let id = inst_iid(inst);
            if id == IID_sadd_with_overflow || id == IID_uadd_with_overflow || id == IID_ssub_with_overflow ||
               id == IID_usub_with_overflow || id == IID_smul_with_overflow || id == IID_umul_with_overflow {
                if ce_try_to_simplify_overflow_math(inst) { changed = true; }
            } else if is_inst_op(inst, OP_ICMP) {
                var simplified = ce_check_and_replace_condition(inst, cb.num_in, cb.num_out, ce_fact_context(cb));
                let ctx = ce_fact_context(cb);
                if !simplified && (m_logical(ctx, true) || m_logical(ctx, false)) {
                    simplified = ce_check_or_and_op_implied_by_other(cb);
                }
                if simplified { changed = true; }
            } else if id == IID_umin || id == IID_umax || id == IID_smin || id == IID_smax {
                if ce_check_and_replace_minmax(inst) { changed = true; }
            } else if id == IID_ucmp || id == IID_scmp {
                if ce_check_and_replace_cmp(inst) { changed = true; }
            }
            continue;
        }
        if cb.kind != FK_COND {
            let ci = cb.inst;
            let id = inst_iid(ci);
            if id == IID_abs {
                let x = cb_arg(ci, 0);
                if ap_is_one(ci_ap(cb_arg(ci, 1))) { ce_add_fact_cb(cb, P_SGE, ci, c_int_ty(vals[ci].ty, 0)); }
                ce_add_fact_cb(cb, P_SGE, ci, x);
                continue;
            }
            if id == IID_umin || id == IID_umax || id == IID_smin || id == IID_smax {
                let p = ce_non_strict(ce_minmax_pred(id));
                ce_add_fact_cb(cb, p, ci, cb_arg(ci, 0));
                ce_add_fact_cb(cb, p, ci, cb_arg(ci, 1));
                continue;
            }
            if id == IID_uadd_sat {
                ce_add_fact_cb(cb, P_UGE, ci, cb_arg(ci, 0));
                ce_add_fact_cb(cb, P_UGE, ci, cb_arg(ci, 1));
                continue;
            }
            if id == IID_usub_sat {
                ce_add_fact_cb(cb, P_ULE, ci, cb_arg(ci, 0));
                continue;
            }
            if is_inst_op(ci, OP_UREM) {
                ce_add_fact_cb(cb, P_ULT, ci, op(ci, 1));
                ce_add_fact_cb(cb, P_ULE, ci, op(ci, 0));
                continue;
            }
            if is_inst_op(ci, OP_UDIV) {
                ce_add_fact_cb(cb, P_ULE, ci, op(ci, 0));
                continue;
            }
            if is_inst_op(ci, OP_LOAD) || is_inst_op(ci, OP_STORE) {
                let isl = iop(ci) == OP_LOAD;
                let ptr = if isl { op(ci, 0) } else { op(ci, 1) };
                let aty = if isl { vals[ci].ty } else { vals[op(ci, 0)].ty };
                let ok, p, a, b = ce_constraint_from_memory_access(ptr, dl_store_size(aty) as u64);
                if ok { ce_add_fact_cb(cb, p, a, b); }
                continue;
            }
        }
        var pred: i64 = -1;
        var a: i32 = -1;
        var b: i32 = -1;
        if cb.kind == FK_COND {
            pred = cb.pred; a = cb.a; b = cb.b;
            if cb.hpred >= 0 && !ce_does_hold(cb.hpred, cb.ha, cb.hb) { continue; }
        } else {
            if inst_iid(cb.inst) != IID_assume { fatal("constraint-elimination: unexpected instruction fact"); }
            let ok, p, x, y = ce_icmp_like(op(cb.inst, 0));
            if !ok { fatal("constraint-elimination: assume without an icmp-like operand"); }
            pred = p; a = x; b = y;
        }
        ce_add_fact_cb(cb, pred, a, b);
    }
    for i in ce_to_remove { inst_erase_from_parent(i); }
    return changed;
}

fn constraint_elimination_run(fv: i32) -> u32 {
    if flag_bool("constraint-elimination-dump-reproducers", false) { ce_fail("-constraint-elimination-dump-reproducers"); }
    ce_fv = fv;
    tli_cur_fn = fv;
    dt_get(fv, DT_DOM);
    li_get(fv);
    scev_get(fv);
    if !ce_eliminate_constraints(fv) { return PA_ALL; }
    return PA_CFG | ((1 as u32) << (A_SCEV as u32));
}
