// ScalarEvolution: a port of llvm/lib/Analysis/ScalarEvolution.cpp (LLVM 23.1.5).
//
// Data layout (DESIGN.md §8.6): every SCEV node is an id into `scevs` (uniqued like LLVM's FoldingSet, by kind,
// operands, value, loop and, for casts, type); operands are runs in `sc_ops`. Id 0 is SCEVCouldNotCompute.
// One ScalarEvolution instance exists at a time (the current function's); scev_get(fv) builds it, a different
// function or an invalidation resets every table.
//
// Recursion: the expression builders are one big recursive cycle (as in LLVM). Goose forbids growable locals
// across recursive calls, so every SmallVector<SCEVUse> of LLVM is a run on the global scratch stack `ss`:
// a function that LLVM gives `SmallVectorImpl<SCEVUse> &Ops` takes the base index `b` of a run that extends
// to the top of `ss`, owns it, and truncates `ss` back to `b` before returning (sc_add_n, sc_mul_n, ...).
// APInt and ConstantRange are fixed-size values (apint.goose, constrange.goose).
//
// Files: scev.goose (nodes, uniquing, folding constructors, printing), scev_create.goose (getSCEV/createSCEV),
// scev_range.goose (ranges, nowrap inference), scev_btc.goose (backedge-taken counts, exit limits),
// scev_pred.goose (isKnownPredicate / isImpliedCond), scev_print.goose (print<scalar-evolution>).
import std;
import scev_eval;
import scev_lt;
import scev_guards;
import implied;
import pm;
import ir;
import irutil;
import flags;
import printer;
import datalayout;
import apint;
import constrange;
import loopinfo;
import domtree;
import scev_create;
import scev_range;
import scev_btc;
import scev_pred;
import scev_print;

let SC_CONST = 0;
let SC_VSCALE = 1;
let SC_TRUNC = 2;
let SC_ZEXT = 3;
let SC_SEXT = 4;
let SC_ADD = 5;
let SC_MUL = 6;
let SC_UDIV = 7;
let SC_ADDREC = 8;
let SC_UMAX = 9;
let SC_SMAX = 10;
let SC_UMIN = 11;
let SC_SMIN = 12;
let SC_SEQUMIN = 13;
let SC_PTRTOADDR = 14;
let SC_PTRTOINT = 15;
let SC_UNKNOWN = 16;
let SC_CNC = 17;

let SF_ANY: u32 = 0;
let SF_NW: u32 = 1;
let SF_NUW: u32 = 2;
let SF_NSW: u32 = 4;
let SF_MASK: u32 = 7;

let SCEV_CNC: i32 = 0;

// cl::opts (ScalarEvolution.cpp)
var sc_max_brute_force_iterations: i64 = 100;   // scalar-evolution-max-iterations
var sc_max_value_compare_depth: i64 = 2;         // scalar-evolution-max-value-compare-depth
var sc_max_scev_compare_depth: i64 = 32;         // scalar-evolution-max-scev-compare-depth
var sc_max_scev_operations_implication_depth: i64 = 2;
var sc_max_arith_depth: i64 = 32;                // scalar-evolution-max-arith-depth
var sc_max_constant_evolving_depth: i64 = 32;
var sc_max_cast_depth: i64 = 8;                  // scalar-evolution-max-cast-depth
var sc_max_add_rec_size: i64 = 8;                // scalar-evolution-max-add-rec-size
var sc_huge_expr_threshold: i64 = 4096;          // scalar-evolution-huge-expr-threshold
var sc_mulops_inline_threshold: i64 = 32;        // scev-mulops-inline-threshold
var sc_addops_inline_threshold: i64 = 500;       // scev-addops-inline-threshold
var sc_range_iter_threshold: i64 = 32;           // scev-range-iter-threshold
var sc_max_loop_guard_collection_depth: i64 = 1;
var sc_classify_expressions: bool = true;        // scalar-evolution-classify-expressions
var sc_use_expensive_range_sharpening: bool = false;
var sc_max_phi_scc_analysis_size: i64 = 8;
var sc_use_context_for_nsw_add_rec: bool = true; // scalar-evolution-use-context-for-no-wrap-flag-strenghening
var sc_finite_loop_assumption: bool = true;

recursive fn sc_read_flags() {
    sc_max_brute_force_iterations = flag_int("scalar-evolution-max-iterations", 100);
    sc_max_arith_depth = flag_int("scalar-evolution-max-arith-depth", 32);
    sc_max_cast_depth = flag_int("scalar-evolution-max-cast-depth", 8);
    sc_max_add_rec_size = flag_int("scalar-evolution-max-add-rec-size", 8);
    sc_huge_expr_threshold = flag_int("scalar-evolution-huge-expr-threshold", 4096);
    sc_mulops_inline_threshold = flag_int("scev-mulops-inline-threshold", 32);
    sc_addops_inline_threshold = flag_int("scev-addops-inline-threshold", 500);
    sc_range_iter_threshold = flag_int("scev-range-iter-threshold", 32);
    sc_classify_expressions = flag_bool("scalar-evolution-classify-expressions", true);
    sc_trace = flag_bool("goose-scev-trace", false);
    sc_use_expensive_range_sharpening = flag_bool("scalar-evolution-use-expensive-range-sharpening", false);
}

// ---------------------------------------------------------------------------------------------
// Nodes

struct Scev { kind: u8, flags: u8, size: u16, ty: i32, at: i32, n: i32, v: i32, lp: i32, hash: u32, chain: i32 }
var scevs: Scev[>..];
var sc_ops: i32[>..];
var sc_tab: i32[>..];       // uniquing hash buckets (heads of `chain` lists)
var sc_count: i64 = 0;
var ss: i32[>..<];          // scratch operand stack (see the header)

var sc_fv: i32 = -1;        // the function this ScalarEvolution belongs to
var sc_valid: bool = false;

recursive fn sc_kind(s: i32) -> i64 { scevs[s].kind as i64 }
recursive fn sc_ty(s: i32) -> i32 { scevs[s].ty }
recursive fn sc_nops(s: i32) -> i64 { scevs[s].n as i64 }
recursive fn sc_op(s: i32, k: i64) -> i32 { sc_ops[scevs[s].at + k] }
recursive fn sc_flags(s: i32) -> u32 { scevs[s].flags as u32 }
recursive fn sc_value(s: i32) -> i32 { scevs[s].v }
recursive fn sc_loop(s: i32) -> i32 { scevs[s].lp }
recursive fn sc_size(s: i32) -> i64 { scevs[s].size as i64 }
recursive fn sc_is_cnc(s: i32) -> bool { s == SCEV_CNC }
recursive fn sc_is_const(s: i32) -> bool { scevs[s].kind as i64 == SC_CONST }
recursive fn sc_is_addrec(s: i32) -> bool { scevs[s].kind as i64 == SC_ADDREC }
recursive fn sc_is_unknown(s: i32) -> bool { scevs[s].kind as i64 == SC_UNKNOWN }
recursive fn sc_is_cast_kind(k: i64) -> bool { k == SC_TRUNC || k == SC_ZEXT || k == SC_SEXT || k == SC_PTRTOADDR || k == SC_PTRTOINT }
recursive fn sc_is_int_cast_kind(k: i64) -> bool { k == SC_TRUNC || k == SC_ZEXT || k == SC_SEXT }
recursive fn sc_is_minmax_kind(k: i64) -> bool { k == SC_UMAX || k == SC_SMAX || k == SC_UMIN || k == SC_SMIN }
recursive fn sc_is_nary_kind(k: i64) -> bool { k == SC_ADD || k == SC_MUL || k == SC_ADDREC || sc_is_minmax_kind(k) || k == SC_SEQUMIN }
recursive fn sc_is_commutative_kind(k: i64) -> bool { k == SC_ADD || k == SC_MUL || sc_is_minmax_kind(k) }
recursive fn sc_minmax_negate(k: i64) -> i64 {
    if k == SC_SMAX { return SC_SMIN; }
    if k == SC_SMIN { return SC_SMAX; }
    if k == SC_UMAX { return SC_UMIN; }
    return SC_UMAX;
}
recursive fn sc_has_nuw(s: i32) -> bool { (sc_flags(s) & SF_NUW) != 0 }
recursive fn sc_has_nsw(s: i32) -> bool { (sc_flags(s) & SF_NSW) != 0 }
recursive fn sc_has_nw(s: i32) -> bool { (sc_flags(s) & SF_NW) != 0 }
recursive fn sc_nowrap(s: i32, mask: u32) -> u32 { sc_flags(s) & mask }
// SCEVNAryExpr::setNoWrapFlags / SCEVAddRecExpr::setNoWrapFlags (an AddRec with nuw or nsw also has nw)
recursive fn sc_or_flags(s: i32, f0: u32) {
    var f = f0;
    if sc_kind(s) == SC_ADDREC && (f & (SF_NUW | SF_NSW)) != 0 { f |= SF_NW; }
    scevs[s].flags = (sc_flags(s) | f) as u8;
}

// ScalarEvolution::maskFlags / setFlags / clearFlags
recursive fn sc_mask_flags(f: u32, mask: u32) -> u32 { f & mask }
recursive fn sc_set_flags(f: u32, on: u32) -> u32 { f | on }
recursive fn sc_clear_flags(f: u32, off: u32) -> u32 { f & ~off }

// The constant's ConstantInt value id and APInt
recursive fn sc_cval(s: i32) -> i32 { scevs[s].v }
recursive fn sc_ap(s: i32) -> AP { ap_from_cint(scevs[s].v) }
recursive fn sc_is_zero(s: i32) -> bool { sc_is_const(s) && ap_is_zero(sc_ap(s)) }
recursive fn sc_is_one(s: i32) -> bool { sc_is_const(s) && ap_is_one(sc_ap(s)) }
recursive fn sc_is_all_ones(s: i32) -> bool { sc_is_const(s) && ap_is_all_ones(sc_ap(s)) }

recursive fn sc_hash_mix(h: u64, x: u64) -> u64 { (h ^ x) * 0x100000001B3 + 0x9E3779B97F4A7C15 }

// Uniquing key: kind, operands (ss[b..b+n]), v, lp, ty (ty = -1 when LLVM's FoldingSetNodeID omits it).
recursive fn sc_key_hash(kind: i64, b: i64, n: i64, v: i32, lp: i32, ty: i32) -> u32 {
    var h: u64 = 0xCBF29CE484222325;
    h = sc_hash_mix(h, kind as u64);
    for k in n { h = sc_hash_mix(h, (ss[b + k] as i64) as u64); }
    h = sc_hash_mix(h, ((v as i64) + 7) as u64);
    h = sc_hash_mix(h, ((lp as i64) + 11) as u64);
    h = sc_hash_mix(h, ((ty as i64) + 13) as u64);
    return ((h >> 32) ^ h) as! u32;
}

recursive fn sc_key_ty(kind: i64, ty: i32) -> i32 {
    if kind == SC_VSCALE || kind == SC_TRUNC || kind == SC_ZEXT || kind == SC_SEXT || kind == SC_PTRTOADDR { return ty; }
    return -1;
}

// FindNodeOrInsertPos; -1 if absent.
recursive fn sc_find(kind: i64, b: i64, n: i64, v: i32, lp: i32, ty0: i32) -> i32 {
    if sc_tab.len == 0 { return -1; }
    let ty = sc_key_ty(kind, ty0);
    let h = sc_key_hash(kind, b, n, v, lp, ty);
    var s = sc_tab[(h as i64) & (sc_tab.len - 1)];
    while s >= 0 {
        let r = scevs[s];
        if r.hash == h && r.kind as i64 == kind && r.n as i64 == n && r.v == v && r.lp == lp && sc_key_ty(kind, r.ty) == ty {
            var same = true;
            for k in n { if sc_ops[r.at + k] != ss[b + k] { same = false; break; } }
            if same { return s; }
        }
        s = r.chain;
    }
    return -1;
}

recursive fn sc_rehash() {
    var nb: i64 = 1024;
    while nb < sc_count * 2 { nb *= 2; }
    sc_tab.resize(0);
    sc_tab.resize(nb, -1);
    for s in scevs.len {
        let r = scevs[s];
        if r.hash == 0 && r.chain == -2 { continue; }     // removed from the uniquing map
        if s == SCEV_CNC as i64 { continue; }
        let j = (r.hash as i64) & (nb - 1);
        scevs[s].chain = sc_tab[j];
        sc_tab[j] = s as i32;
    }
}

// Creates and inserts a node (the caller has checked sc_find). Operands are ss[b..b+n].
recursive fn sc_insert(kind: i64, b: i64, n: i64, v: i32, lp: i32, ty: i32, flags: u32) -> i32 {
    let id = scevs.len as i32;
    let at = sc_ops.len as i32;
    // computeExpressionSize: 1 + sum of operand sizes, saturating at 16 bits
    var size: i64 = 1;
    for k in n { let o = ss[b + k]; sc_ops.push(o); size += sc_size(o); if size > 65535 { size = 65535; } }
    let h = sc_key_hash(kind, b, n, v, lp, sc_key_ty(kind, ty));
    scevs.push(Scev { kind: kind as u8, flags: flags as u8, size: size as u16, ty: ty, at: at, n: n as i32, v: v, lp: lp, hash: h, chain: -1 });
    sc_count++;
    sc_side_grow();
    if sc_count * 2 > sc_tab.len { sc_rehash(); }
    else {
        let j = (h as i64) & (sc_tab.len - 1);
        scevs[id].chain = sc_tab[j];
        sc_tab[j] = id;
    }
    return id;
}

// UniqueSCEVs.RemoveNode
recursive fn sc_remove_node(s: i32) {
    let j = (scevs[s].hash as i64) & (sc_tab.len - 1);
    var p = sc_tab[j];
    var prev: i32 = -1;
    while p >= 0 {
        if p == s {
            if prev < 0 { sc_tab[j] = scevs[s].chain; } else { scevs[prev].chain = scevs[s].chain; }
            break;
        }
        prev = p;
        p = scevs[p].chain;
    }
    scevs[s].chain = -2;
    scevs[s].hash = 0;
}

// ---------------------------------------------------------------------------------------------
// Types

recursive fn sc_is_scevable(t: i32) -> bool { ty_is_int(t) || ty_kind(t) == TK_PTR }
recursive fn sc_is_ptr_ty(t: i32) -> bool { ty_kind(t) == TK_PTR }
recursive fn sc_is_ptr(s: i32) -> bool { ty_kind(sc_ty(s)) == TK_PTR }
recursive fn sc_ptr_as(t: i32) -> i64 { types[t].n as i64 }
// DataLayout::getIndexTypeSizeInBits
recursive fn sc_index_bits(t: i32) -> i64 { dl_ptr(sc_ptr_as(t)).idx }
recursive fn sc_type_bits(t: i32) -> i64 { if sc_is_ptr_ty(t) { sc_index_bits(t) } else { ty_bits(t) } }
recursive fn sc_bits(s: i32) -> i64 { sc_type_bits(sc_ty(s)) }
// getEffectiveSCEVType: pointers become their index type
recursive fn sc_effective_ty(t: i32) -> i32 { if sc_is_ptr_ty(t) { ty_int(sc_index_bits(t)) } else { t } }
recursive fn sc_wider_ty(a: i32, b: i32) -> i32 { if sc_type_bits(a) >= sc_type_bits(b) { a } else { b } }
// DataLayout::getIntPtrType (pointer size, not index size)
recursive fn sc_intptr_ty(t: i32) -> i32 { ty_int(dl_ptr(sc_ptr_as(t)).bits) }

// ---------------------------------------------------------------------------------------------
// Leaves

recursive fn sc_get_constant_v(c: i32) -> i32 {
    let b = ss.len;
    var s = sc_find(SC_CONST, b, 0, c, -1, -1);
    if s < 0 { s = sc_insert(SC_CONST, b, 0, c, -1, vals[c].ty, 0); }
    return s;
}
recursive fn sc_get_constant(a: AP) -> i32 { sc_get_constant_v(ap_to_cint(ty_int(a.w as i64), a)) }
// getConstant(Ty, V, isSigned) (implicit truncation)
recursive fn sc_get_constant_ty(t: i32, x: u64, signed: bool) -> i32 {
    let it = sc_effective_ty(t);
    let w = ty_bits(it);
    var a = ap_u64(x, w);
    if signed && w > 64 { a = ap_sext(ap_u64(x, 64), w); }
    return sc_get_constant(a);
}
recursive fn sc_get_zero(t: i32) -> i32 { sc_get_constant(ap_zero(sc_type_bits(t))) }
recursive fn sc_get_one(t: i32) -> i32 { sc_get_constant(ap_u64(1, sc_type_bits(t))) }
recursive fn sc_get_minus_one(t: i32) -> i32 { sc_get_constant(ap_ones(sc_type_bits(t))) }
recursive fn sc_get_power_of_two(t: i32, k: i64) -> i32 { sc_get_constant(ap_one_bit(sc_type_bits(t), k)) }

recursive fn sc_get_vscale(t: i32) -> i32 {
    let b = ss.len;
    var s = sc_find(SC_VSCALE, b, 0, -1, -1, t);
    if s < 0 { s = sc_insert(SC_VSCALE, b, 0, -1, -1, t, 0); }
    return s;
}

var sc_first_unknown: i32 = -1;
recursive fn sc_get_unknown(v: i32) -> i32 {
    let b = ss.len;
    var s = sc_find(SC_UNKNOWN, b, 0, v, -1, -1);
    if s < 0 { s = sc_insert(SC_UNKNOWN, b, 0, v, -1, vals[v].ty, 0); }
    return s;
}

// ---------------------------------------------------------------------------------------------
// Side tables indexed by SCEV id (reset with the instance)

// Cached ranges are kept as IR constants (lower, upper): wide APInts don't outlive a pass (apint.goose).
struct ScSide { ur_valid: bool, sr_valid: bool, url: i32, urh: i32, srl: i32, srh: i32, mtz: i32, has_rec: i8, users: i32 }
var sc_side: ScSide[>..];
recursive fn sc_side_grow() {
    while sc_side.len < scevs.len {
        sc_side.push(ScSide { ur_valid: false, sr_valid: false, url: -1, urh: -1, srl: -1, srh: -1, mtz: -1, has_rec: -1, users: -1 });
    }
}

// u64 -> i64 open-addressing map (DenseMap stand-in; iteration order is never used)
struct HSlot { key: u64, val: i64 }
struct HMap { n: i64, used: i64, slots: HSlot[>..] }
let HM_EMPTY: u64 = 0xFFFFFFFFFFFFFFFF;
let HM_TOMB: u64 = 0xFFFFFFFFFFFFFFFE;
fn hm_new() -> HMap { HMap { n: 0, used: 0, slots: [] } }
recursive fn hm_hash(k: u64) -> u64 { var x = k * 0x9E3779B97F4A7C15; x ^= x >> 29; return x; }
recursive fn hm_clear(m: HMap&) { m.slots.resize(0); m.n = 0; m.used = 0; }
recursive fn hm_find(m: HMap&, k: u64) -> i64 {
    if m.slots.len == 0 { return -1; }
    let mask = m.slots.len - 1;
    var j = (hm_hash(k) as! i64) & mask;
    loop {
        let sk = m.slots[j].key;
        if sk == k { return j; }
        if sk == HM_EMPTY { return -1; }
        j = (j + 1) & mask;
    }
    return -1;
}
recursive fn hm_has(m: HMap&, k: u64) -> bool { hm_find(m, k) >= 0 }
recursive fn hm_get(m: HMap&, k: u64, dflt: i64) -> i64 { let j = hm_find(m, k); return if j < 0 { dflt } else { m.slots[j].val }; }
fn hm_grow(m: HMap&) {
    let old = m.slots.len;
    var nn: i64 = 64;
    while nn < m.n * 4 { nn *= 2; }
    var tmp: HSlot[>..] = [];
    for k in old { if m.slots[k].key != HM_EMPTY && m.slots[k].key != HM_TOMB { tmp.push(m.slots[k]); } }
    m.slots.resize(0);
    m.slots.resize(nn, HSlot { key: HM_EMPTY, val: 0 });
    m.used = 0;
    let mask = nn - 1;
    for e in tmp {
        var j = (hm_hash(e.key) as! i64) & mask;
        while m.slots[j].key != HM_EMPTY { j = (j + 1) & mask; }
        m.slots[j] = e;
        m.used++;
    }
}
recursive fn hm_put(m: HMap&, k: u64, v: i64) {
    let f = hm_find(m, k);
    if f >= 0 { m.slots[f].val = v; return; }
    if (m.used + 1) * 4 > m.slots.len * 3 { hm_grow(m); }
    let mask = m.slots.len - 1;
    var j = (hm_hash(k) as! i64) & mask;
    while m.slots[j].key != HM_EMPTY && m.slots[j].key != HM_TOMB { j = (j + 1) & mask; }
    if m.slots[j].key == HM_EMPTY { m.used++; }
    m.slots[j] = HSlot { key: k, val: v };
    m.n++;
}
recursive fn hm_del(m: HMap&, k: u64) {
    let f = hm_find(m, k);
    if f < 0 { return; }
    m.slots[f].key = HM_TOMB;
    m.n--;
}
recursive fn hk2(a: i32, b: i32) -> u64 { (((a as i64) as u64) << 32) | (((b as i64) as u64) & 0xFFFFFFFF) }

// Per-value maps: ValueExprMap
var sc_vmap = hm_new();          // value id -> SCEV
var sc_fold = hm_new();          // FoldCache: (kind, op, ty) -> SCEV
var sc_ldisp = hm_new();         // LoopDispositions: (S, loop) -> disposition
var sc_bdisp = hm_new();         // BlockDispositions: (S, block) -> disposition
var sc_atscope = hm_new();       // ValuesAtScopes: (S, loop+1) -> SCEV
var sc_atscope_users = hm_new(); // ValuesAtScopesUsers marker
var sc_pending_loop_preds = hm_new();
var sc_pending_phi_ranges = hm_new();
var sc_pending_merges = hm_new();

recursive fn sc_fold_key(kind: i64, op: i32, ty: i32) -> u64 { (((op as i64) as u64) << 32) | ((((ty as i64) as u64) & 0x3FFFFFFF) << 2) | ((kind as u64) & 3) }

// ---------------------------------------------------------------------------------------------
// Instance lifetime

recursive fn scev_reset() {
    scevs.resize(0);
    sc_ops.resize(0);
    sc_tab.resize(0);
    sc_count = 0;
    ss.resize(0);
    sc_side.resize(0);
    hm_clear(sc_vmap);
    hm_clear(sc_fold);
    sc_clear_ldisp();
    sc_clear_bdisp();
    hm_clear(sc_atscope);
    hm_clear(sc_atscope_users);
    hm_clear(sc_pending_loop_preds);
    hm_clear(sc_pending_phi_ranges);
    hm_clear(sc_pending_merges);
    sc_first_unknown = -1;
    scev_reset_create();
    scev_reset_btc();
    sc_cm.resize(0);
    hm_clear(sc_incoming_guards);
    sc_tmp.resize(0);
    sc_newops.resize(0);
    sc_cops.resize(0);
    sc_newscales.resize(0);
    sc_dscales.resize(0);
    sc_seen.resize(0);
    // SCEVCouldNotCompute
    scevs.push(Scev { kind: SC_CNC as u8, flags: 0, size: 0, ty: -1, at: 0, n: 0, v: -1, lp: -1, hash: 0, chain: -2 });
    sc_side_grow();
}

// LLVM keeps one ScalarEvolution per function in the FunctionAnalysisManager; we keep only the current one. A
// result that a transform kept up to date (preserved it while changing the IR: indvars, loop-rotate, ...) is not
// what a recomputation gives (cached trip counts in terms of the old values, inferred flags), so when another
// function's result replaces such a result and the first function asks again while LLVM would still have it
// cached (function(loop(indvars)),function(loop-unroll)), we fail loudly instead of answering from scratch.
var sc_dirty: bool = false;           // the current result survived an IR change
var sc_lost: i32[>..<];               // functions whose (dirty) result LLVM would still have
fn scev_note_preserved_change(fv: i32) { if sc_valid && sc_fv == fv { sc_dirty = true; } }

recursive fn scev_get(fv: i32) {
    if sc_valid && sc_fv == fv { return; }
    if sc_valid && sc_dirty { sc_lost.push(sc_fv); }
    for x in sc_lost {
        if x == fv { fatal("ScalarEvolution: this function's result was kept up to date by a transform and LLVM would reuse it across function adaptors; one ScalarEvolution per function is not ported yet"); }
    }
    sc_dirty = false;
    sc_read_flags();
    scev_reset();
    sc_fv = fv;
    sc_valid = true;
    dt_get(fv, DT_DOM);
    li_get(fv);
    sc_init_has_guards(fv);
}
recursive fn scev_valid(fv: i32) -> bool { sc_valid && sc_fv == fv }
recursive fn scev_invalidate(fv: i32) {
    if sc_fv == fv { sc_valid = false; sc_dirty = false; }
    var k: i64 = 0;
    while k < sc_lost.len { if sc_lost[k] == fv { sc_lost[k] = sc_lost[sc_lost.len - 1]; sc_lost.pop(); } else { k++; } }
}

// ---------------------------------------------------------------------------------------------
// Printing (SCEV::print)

recursive fn sc_errs_type(t: i32) {
    let mark = out.len;
    put_type(t);
    errbuf.append(out[mark..]);
    out.resize(mark);
}

recursive fn sc_print(s: i32) {
    let k = sc_kind(s);
    if k == SC_CONST { errs_operand(sc_cval(s), sc_fv, false); return; }
    if k == SC_VSCALE { errs("vscale"); return; }
    if k == SC_PTRTOADDR || k == SC_PTRTOINT || k == SC_TRUNC || k == SC_ZEXT || k == SC_SEXT {
        let o = sc_op(s, 0);
        errs(if k == SC_PTRTOADDR { "(ptrtoaddr " } else if k == SC_PTRTOINT { "(ptrtoint " } else if k == SC_TRUNC { "(trunc " }
             else if k == SC_ZEXT { "(zext " } else { "(sext " });
        sc_errs_type(sc_ty(o));
        errs(" ");
        sc_print(o);
        errs(" to ");
        sc_errs_type(sc_ty(s));
        errs(")");
        return;
    }
    if k == SC_ADDREC {
        errs("{");
        sc_print(sc_op(s, 0));
        for i in 1..sc_nops(s) { errs(",+,"); sc_print(sc_op(s, i)); }
        errs("}<");
        if sc_has_nuw(s) { errs("nuw><"); }
        if sc_has_nsw(s) { errs("nsw><"); }
        if sc_has_nw(s) && !sc_has_nuw(s) && !sc_has_nsw(s) { errs("nw><"); }
        errs_operand(loop_header(sc_loop(s)), sc_fv, false);
        errs(">");
        return;
    }
    if sc_is_nary_kind(k) {
        let sep = if k == SC_ADD { " + " } else if k == SC_MUL { " * " } else if k == SC_UMAX { " umax " } else if k == SC_SMAX { " smax " }
                  else if k == SC_UMIN { " umin " } else if k == SC_SMIN { " smin " } else { " umin_seq " };
        errs("(");
        for i in sc_nops(s) { if i > 0 { errs(sep); } sc_print(sc_op(s, i)); }
        errs(")");
        if k == SC_ADD || k == SC_MUL {
            if sc_has_nuw(s) { errs("<nuw>"); }
            if sc_has_nsw(s) { errs("<nsw>"); }
        }
        return;
    }
    if k == SC_UDIV { errs("("); sc_print(sc_op(s, 0)); errs(" /u "); sc_print(sc_op(s, 1)); errs(")"); return; }
    if k == SC_UNKNOWN { errs_operand(sc_value(s), sc_fv, false); return; }
    errs("***COULDNOTCOMPUTE***");
}

// APInt::print(OS, /*isSigned=*/true)
recursive fn sc_errs_ap_signed(a: AP) {
    if ap_is_neg(a) { errs("-"); ap_format_dec(errbuf, ap_neg(a)); } else { ap_format_dec(errbuf, a); }
}
// ConstantRange::print
recursive fn sc_errs_range(c: CRange) {
    if rg_is_full(c) { errs("full-set"); return; }
    if rg_is_empty(c) { errs("empty-set"); return; }
    errs("[");
    sc_errs_ap_signed(c.lo);
    errs(",");
    sc_errs_ap_signed(c.hi);
    errs(")");
}

// ---------------------------------------------------------------------------------------------
// SCEV utilities

// Value::getValueID in LLVM 23's Value.def order (instructions: InstructionVal + opcode).
recursive fn sc_value_id(v: i32) -> i64 {
    let k = vals[v].kind as i64;
    match k {
        VK_UNDEF => { return 0; },
        VK_POISON => { return 1; },
        VK_AGGZERO => { return 2; },
        VK_CDARRAY => { return 3; },
        VK_CDVECTOR => { return 4; },
        VK_CINT => { return if ty_kind(ty_scalar(vals[v].ty)) == TK_BYTE { 6 } else { 5 }; },
        VK_CFP => { return 7; },
        VK_CTARGETNONE => { return 8; },
        VK_CNULL => { return 9; },
        VK_CTOKENNONE => { return 10; },
        VK_CARRAY => { return 11; },
        VK_CSTRUCT => { return 12; },
        VK_CVECTOR => { return 13; },
        VK_FUNC => { return 14; },
        VK_ALIAS => { return 15; },
        VK_IFUNC => { return 16; },
        VK_GVAR => { return 17; },
        VK_BLOCKADDR => { return 18; },
        VK_CEXPR => { return 19; },
        VK_DSOLOCAL => { return 20; },
        VK_NOCFI => { return 21; },
        VK_PTRAUTH => { return 22; },
        VK_ARG => { return 23; },
        VK_BLOCK => { return 24; },
        VK_MDVAL => { return 25; },
        VK_INLINEASM => { return 26; },
        VK_INST => { return 30 + iop(v); },
        _ => { fatal("ScalarEvolution: unexpected value kind"); return 0; },
    }
}

recursive fn sc_is_global_value(v: i32) -> bool { let k = vals[v].kind as i64; k == VK_FUNC || k == VK_ALIAS || k == VK_IFUNC || k == VK_GVAR }

// LoopInfo::getLoopDepth (0 outside loops)
recursive fn sc_loop_depth_of_block(bv: i32) -> i64 { let l = li_loop_for(bv); return if l < 0 { 0 } else { loop_depth(l) }; }

recursive fn sc_cmp3(a: i64, b: i64) -> i64 { a - b }

// CompareValueComplexity
recursive fn sc_compare_value_complexity(lv: i32, rv: i32, depth: i64) -> i64 {
    if depth > sc_max_value_compare_depth { return 0; }
    let lp = sc_is_ptr_ty(vals[lv].ty);
    let rp = sc_is_ptr_ty(vals[rv].ty);
    if lp != rp { return (if lp { 1 } else { 0 }) - (if rp { 1 } else { 0 }); }
    let lid = sc_value_id(lv);
    let rid = sc_value_id(rv);
    if lid != rid { return lid - rid; }
    if vals[lv].kind as i64 == VK_ARG { return (vals[lv].sub as i64) - (vals[rv].sub as i64); }
    if sc_is_global_value(lv) {
        let ll = globs[glob_of(lv)].linkage as i64;
        let rl = globs[glob_of(rv)].linkage as i64;
        if ll != rl { return ll - rl; }
        // names are semantic unless private/internal
        if !sc_linkage_local(ll) && !sc_linkage_local(rl) { return sc_str_compare(val_name(lv), val_name(rv)); }
    }
    if vals[lv].kind as i64 == VK_INST {
        let lb = inst_parent(lv);
        let rb = inst_parent(rv);
        if lb != rb {
            let ld = sc_loop_depth_of_block(lb);
            let rd = sc_loop_depth_of_block(rb);
            if ld != rd { return ld - rd; }
        }
        let ln = vals[lv].nops as i64;
        let rn = vals[rv].nops as i64;
        if ln != rn { return ln - rn; }
        for idx in ln {
            let r = sc_compare_value_complexity(op(lv, idx), op(rv, idx), depth + 1);
            if r != 0 { return r; }
        }
    }
    return 0;
}

recursive fn sc_linkage_local(l: i64) -> bool { l == LK_PRIVATE || l == LK_INTERNAL }

// StringRef::compare: -1, 0, 1
fn sc_str_compare(a: const u8[:], b: const u8[:]) -> i64 {
    let n = if a.len < b.len { a.len } else { b.len };
    for i in n {
        if a[i] != b[i] { return if a[i] < b[i] { -1 } else { 1 }; }
    }
    if a.len == b.len { return 0; }
    return if a.len < b.len { -1 } else { 1 };
}

let SC_CMP_UNKNOWN: i64 = 0x7FFFFFFF;   // std::nullopt

// CompareSCEVComplexity: negative / 0 / positive, or SC_CMP_UNKNOWN when the depth limit was hit.
recursive fn sc_compare_complexity(l: i32, r: i32, depth: i64) -> i64 {
    if l == r { return 0; }
    let lt = sc_kind(l);
    let rt = sc_kind(r);
    if lt != rt { return lt - rt; }
    if depth > sc_max_scev_compare_depth { return SC_CMP_UNKNOWN; }
    if lt == SC_UNKNOWN { return sc_compare_value_complexity(sc_value(l), sc_value(r), depth + 1); }
    if lt == SC_CONST {
        let la = sc_ap(l);
        let ra = sc_ap(r);
        if la.w != ra.w { return (la.w as i64) - (ra.w as i64); }
        return if ap_ult(la, ra) { -1 } else { 1 };
    }
    if lt == SC_VSCALE { return ty_bits(sc_ty(l)) - ty_bits(sc_ty(r)); }
    if lt == SC_ADDREC {
        let ll = sc_loop(l);
        let rl = sc_loop(r);
        if ll != rl {
            if dt_dominates_block(DT_DOM, loop_header(ll), loop_header(rl)) { return 1; }
            return -1;
        }
    }
    let ln = sc_nops(l);
    let rn = sc_nops(r);
    if ln != rn { return ln - rn; }
    for i in ln {
        let x = sc_compare_complexity(sc_op(l, i), sc_op(r, i), depth + 1);
        if x != 0 { return x; }
    }
    return 0;
}

recursive fn sc_less_complex(a: i32, b: i32) -> bool {
    let c = sc_compare_complexity(a, b, 0);
    return c != SC_CMP_UNKNOWN && c < 0;
}

// GroupByComplexity over ss[b..b+n] (llvm::stable_sort is a merge sort: an insertion sort is stable too and
// gives the same order for a strict weak ordering; the comparison may be inconsistent at the depth limit,
// in which case std::stable_sort's exact merge order matters: ported below).
recursive fn sc_group_by_complexity(b: i64, n: i64) {
    if n < 2 { return; }
    if n == 2 {
        if sc_less_complex(ss[b + 1], ss[b]) { let t = ss[b]; ss[b] = ss[b + 1]; ss[b + 1] = t; }
        return;
    }
    sc_stable_sort(b, n);
    var i: i64 = 0;
    let e = n;
    while i != e - 2 {
        let s = ss[b + i];
        let cx = sc_kind(s);
        var j = i + 1;
        var done = false;
        while j != e && sc_kind(ss[b + j]) == cx {
            if ss[b + j] == s {
                let t = ss[b + i + 1]; ss[b + i + 1] = ss[b + j]; ss[b + j] = t;
                i++;
                if i == e - 2 { done = true; break; }
            }
            j++;
        }
        if done { return; }
        i++;
    }
}

// llvm::stable_sort. Any stable sort gives the same order for a strict weak ordering; the complexity order
// is one except at the depth limits, which the tests don't reach.
recursive fn sc_stable_sort(b: i64, n: i64) {
    var i: i64 = 1;
    while i < n {
        let v = ss[b + i];
        var k = i;
        while k > 0 && sc_less_complex(v, ss[b + k - 1]) { ss[b + k] = ss[b + k - 1]; k--; }
        ss[b + k] = v;
        i++;
    }
}

// hasHugeExpression
recursive fn sc_has_huge(b: i64, n: i64) -> bool {
    for k in n { if sc_size(ss[b + k]) >= sc_huge_expr_threshold { return true; } }
    return false;
}

// ss helpers
recursive fn ss_erase(b: i64, idx: i64) {
    var k = b + idx;
    while k + 1 < ss.len { ss[k] = ss[k + 1]; k++; }
    ss.pop();
}
recursive fn ss_insert(b: i64, idx: i64, x: i32) {
    ss.push(0);
    var k = ss.len - 1;
    while k > b + idx { ss[k] = ss[k - 1]; k--; }
    ss[b + idx] = x;
}
// Erases ss[b+from .. b+to)
recursive fn ss_erase_range(b: i64, from: i64, to: i64) {
    let d = to - from;
    if d <= 0 { return; }
    var k = b + from;
    while k + d < ss.len { ss[k] = ss[k + d]; k++; }
    ss.resize(ss.len - d);
}
recursive fn ss_push_ops(s: i32) { for k in sc_nops(s) { ss.push(sc_op(s, k)); } }

// ---------------------------------------------------------------------------------------------
// Commutative builders (getAddExpr, getMulExpr, ...)

recursive fn ss_ret(b: i64, r: i32) -> i32 { ss.resize(b); return r; }
recursive fn ss_n(b: i64) -> i64 { ss.len - b }

// constantFoldAndGroupOps over ss[b..]. kind: SC_ADD, SC_MUL or a min/max kind. Returns the folded value or -1.
recursive fn sc_constant_fold_and_group(b: i64, kind: i64) -> i32 {
    var folded: i32 = -1;
    var idx: i64 = 0;
    while idx < ss_n(b) {
        let o = ss[b + idx];
        if sc_is_const(o) {
            if folded < 0 { folded = o; }
            else {
                let x = sc_ap(folded);
                let y = sc_ap(o);
                var r = x;
                if kind == SC_ADD { r = ap_add(x, y); }
                else if kind == SC_MUL { r = ap_mul(x, y); }
                else if kind == SC_UMAX { r = ap_umax(x, y); }
                else if kind == SC_SMAX { r = ap_smax(x, y); }
                else if kind == SC_UMIN { r = ap_umin(x, y); }
                else { r = ap_smin(x, y); }
                folded = sc_get_constant(r);
            }
            ss_erase(b, idx);
            continue;
        }
        idx++;
    }
    if ss_n(b) == 0 { return folded; }
    if folded >= 0 && sc_fold_is_absorber(kind, sc_ap(folded)) { return folded; }
    sc_group_by_complexity(b, ss_n(b));
    if folded >= 0 && !sc_fold_is_identity(kind, sc_ap(folded)) { ss_insert(b, 0, folded); }
    if ss_n(b) == 1 { return ss[b]; }
    return -1;
}

recursive fn sc_fold_is_identity(kind: i64, c: AP) -> bool {
    if kind == SC_ADD { return ap_is_zero(c); }
    if kind == SC_MUL { return ap_is_one(c); }
    let w = c.w as i64;
    if kind == SC_UMAX { return ap_is_zero(c); }
    if kind == SC_SMAX { return ap_eq(c, ap_smin_val(w)); }
    if kind == SC_UMIN { return ap_is_all_ones(c); }
    return ap_eq(c, ap_smax_val(w));
}
recursive fn sc_fold_is_absorber(kind: i64, c: AP) -> bool {
    if kind == SC_ADD { return false; }
    if kind == SC_MUL { return ap_is_zero(c); }
    let w = c.w as i64;
    if kind == SC_UMAX { return ap_is_all_ones(c); }
    if kind == SC_SMAX { return ap_eq(c, ap_smax_val(w)); }
    if kind == SC_UMIN { return ap_is_zero(c); }
    return ap_eq(c, ap_smin_val(w));
}

// StrengthenNoWrapFlags over ss[b..b+n]
recursive fn sc_strengthen_flags(kind: i64, b: i64, n: i64, flags0: u32) -> u32 {
    var flags = flags0;
    let mask = SF_NUW | SF_NSW;
    var sw = flags & mask;
    if sw == SF_NSW {
        var all = true;
        for k in n { if !sc_is_known_non_negative(ss[b + k]) { all = false; break; } }
        if all { flags |= mask; }
    }
    sw = flags & mask;
    if sw != mask && (kind == SC_ADD || kind == SC_MUL) && n == 2 && sc_is_const(ss[b]) {
        let opc: i64 = if kind == SC_ADD { OP_ADD } else { OP_MUL };
        let c = sc_ap(ss[b]);
        if (sw & SF_NSW) == 0 {
            let reg = rg_guaranteed_no_wrap(opc, rg_single(c), NW_NSW);
            if rg_contains(reg, sc_get_signed_range(ss[b + 1])) { flags |= SF_NSW; }
        }
        if (sw & SF_NUW) == 0 {
            let reg = rg_guaranteed_no_wrap(opc, rg_single(c), NW_NUW);
            if rg_contains(reg, sc_get_unsigned_range(ss[b + 1])) { flags |= SF_NUW; }
        }
    }
    if kind == SC_ADDREC && (flags & SF_NW) != 0 && (flags & SF_NUW) == 0 && n == 2 && sc_is_zero(ss[b]) &&
       sc_is_known_non_negative(ss[b + 1]) {
        flags |= SF_NUW;
    }
    if kind == SC_MUL && (flags & SF_NUW) == 0 && n == 2 {
        let a = ss[b];
        let c = ss[b + 1];
        if sc_kind(a) == SC_UDIV && sc_op(a, 1) == c { flags |= SF_NUW; }
        if sc_kind(c) == SC_UDIV && sc_op(c, 1) == a { flags |= SF_NUW; }
    }
    return flags;
}

recursive fn sc_add_ty(b: i64, n: i64) -> i32 {
    for k in n { if sc_is_ptr(ss[b + k]) { return sc_ty(ss[b + k]); } }
    return sc_ty(ss[b]);
}

// getOrCreateAddExpr / getOrCreateMulExpr (consumes ss[b..])
recursive fn sc_get_or_create_comm(kind: i64, b: i64, flags: u32) -> i32 {
    let n = ss_n(b);
    var s = sc_find(kind, b, n, -1, -1, -1);
    if s < 0 {
        let ty = if kind == SC_ADD { sc_add_ty(b, n) } else { sc_ty(ss[b]) };
        s = sc_insert(kind, b, n, -1, -1, ty, 0);
        sc_register_users(s);
    }
    sc_or_flags(s, flags);
    return ss_ret(b, s);
}

recursive fn sc_add2(a: i32, c: i32, flags: u32, depth: i64) -> i32 { let b = ss.len; ss.push(a); ss.push(c); return sc_add_n(b, flags, depth); }
recursive fn sc_add3(a: i32, c: i32, d: i32, flags: u32, depth: i64) -> i32 { let b = ss.len; ss.push(a); ss.push(c); ss.push(d); return sc_add_n(b, flags, depth); }
recursive fn sc_mul2(a: i32, c: i32, flags: u32, depth: i64) -> i32 { let b = ss.len; ss.push(a); ss.push(c); return sc_mul_n(b, flags, depth); }
recursive fn sc_add(a: i32, c: i32) -> i32 { sc_add2(a, c, SF_ANY, 0) }
recursive fn sc_mul(a: i32, c: i32) -> i32 { sc_mul2(a, c, SF_ANY, 0) }

// Scratch for CollectAddOperandsWithScales (NewOps and their scales; marks per call)
var sc_newops: i32[>..<];   // general scratch (worklists, LIOps, AddRecOps, DeadIndices)
var sc_cops: i32[>..<];
var sc_newscales: AP[>..<];
var sc_dscales: AP[>..<];

recursive fn sc_cops_find(mark: i64, s: i32) -> i64 {
    var k = mark;
    while k < sc_cops.len { if sc_cops[k] == s { return k; } k++; }
    return -1;
}

// CollectAddOperandsWithScales. Operands: ss[at..at+n] if from_ss, else sc_ops[at..at+n].
recursive fn sc_collect_add_scales(mark: i64, acc0: AP, from_ss: bool, at: i64, n: i64, scale: AP) -> bool, AP {
    var acc = acc0;
    var interesting = false;
    var i: i64 = 0;
    loop {
        let o = if from_ss { ss[at + i] } else { sc_ops[at + i] };
        if !sc_is_const(o) { break; }
        i++;
        let c = sc_ap(o);
        if !ap_is_one(scale) || !ap_is_zero(acc) || ap_is_zero(c) { interesting = true; }
        acc = ap_add(acc, ap_mul(scale, c));
        if i == n { break; }
    }
    while i != n {
        let o = if from_ss { ss[at + i] } else { sc_ops[at + i] };
        if sc_kind(o) == SC_MUL && sc_is_const(sc_op(o, 0)) {
            let ns = ap_mul(scale, sc_ap(sc_op(o, 0)));
            if sc_nops(o) == 2 && sc_kind(sc_op(o, 1)) == SC_ADD {
                let add = sc_op(o, 1);
                let r, a2 = sc_collect_add_scales(mark, acc, false, scevs[add].at as i64, sc_nops(add), ns);
                acc = a2;
                if r { interesting = true; }
            } else {
                let b = ss.len;
                for k in 1..sc_nops(o) { ss.push(sc_op(o, k)); }
                let key = sc_mul_n(b, SF_ANY, 0);
                let f = sc_cops_find(mark, key);
                if f < 0 { sc_cops.push(key); sc_newscales.push(ns); }
                else { sc_newscales[f] = ap_add(sc_newscales[f], ns); interesting = true; }
            }
        } else {
            let f = sc_cops_find(mark, o);
            if f < 0 { sc_cops.push(o); sc_newscales.push(scale); }
            else { sc_newscales[f] = ap_add(sc_newscales[f], scale); interesting = true; }
        }
        i++;
    }
    return interesting, acc;
}

// getAddExpr(SmallVectorImpl &Ops, OrigFlags, Depth): Ops = ss[b..]
recursive fn sc_add_n(b: i64, orig: u32, depth: i64) -> i32 {
    if ss_n(b) == 1 { return ss_ret(b, ss[b]); }
    let folded = sc_constant_fold_and_group(b, SC_ADD);
    if folded >= 0 { return ss_ret(b, folded); }
    var idx: i64 = if sc_is_const(ss[b]) { 1 } else { 0 };
    if depth > sc_max_arith_depth || sc_has_huge(b, ss_n(b)) {
        return sc_get_or_create_comm(SC_ADD, b, sc_strengthen_flags(SC_ADD, b, ss_n(b), orig));
    }
    {
        let ex = sc_find(SC_ADD, b, ss_n(b), -1, -1, -1);
        if ex >= 0 {
            if sc_nowrap(ex, orig) != orig { sc_or_flags(ex, sc_strengthen_flags(SC_ADD, b, ss_n(b), orig)); }
            return ss_ret(b, ex);
        }
    }
    let ty = sc_ty(ss[b]);
    // X + Y + Y  -->  X + Y*2
    var found = false;
    var i: i64 = 0;
    var e = ss_n(b);
    while i != e - 1 {
        if ss[b + i] == ss[b + i + 1] {
            var count: i64 = 2;
            while i + count != e && ss[b + i + count] == ss[b + i] { count++; }
            let scale = sc_get_constant_ty(ty, count as u64, false);
            let mul = sc_mul2(scale, ss[b + i], SF_ANY, depth + 1);
            if ss_n(b) == count { return ss_ret(b, mul); }
            ss[b + i] = mul;
            ss_erase_range(b, i + 1, i + count);
            e -= count - 1;
            found = true;
            i--;
        }
        i++;
    }
    if found { return sc_add_n(b, orig, depth + 1); }

    // trunc(x) + trunc(y) folding
    let src_ty = sc_find_trunc_src_type(ss[b + idx]);
    if src_ty >= 0 {
        let lb = ss.len;
        var ok = true;
        let n0 = ss_n(b);
        // (the operands are re-read by index: LargeOps is pushed above Ops)
        for k in n0 {
            let o = ss[b + k];
            let ko = sc_kind(o);
            if ko == SC_TRUNC {
                if sc_ty(sc_op(o, 0)) != src_ty { ok = false; break; }
                ss.push(sc_op(o, 0));
            } else if ko == SC_CONST {
                let x = sc_get_any_extend(o, src_ty);
                ss.push(x);
            } else if ko == SC_MUL {
                let mb = ss.len;
                for j in sc_nops(o) {
                    let mo = sc_op(o, j);
                    if sc_kind(mo) == SC_TRUNC {
                        if sc_ty(sc_op(mo, 0)) != src_ty { ok = false; break; }
                        ss.push(sc_op(mo, 0));
                    } else if sc_is_const(mo) {
                        let x = sc_get_any_extend(mo, src_ty);
                        ss.push(x);
                    } else { ok = false; break; }
                }
                if ok { let m = sc_mul_n(mb, SF_ANY, depth + 1); ss.push(m); } else { ss.resize(mb); }
            } else { ok = false; break; }
            if !ok { break; }
        }
        if ok {
            let fold = sc_add_n(lb, SF_ANY, depth + 1);
            if sc_is_const(fold) || sc_is_unknown(fold) { let t = sc_get_truncate(fold, ty, 0); return ss_ret(b, t); }
        } else { ss.resize(lb); }
    }

    if ss_n(b) == 2 {
        let a = ss[b];
        let bb = ss[b + 1];
        if sc_kind(bb) == SC_ADD && sc_is_const(a) && sc_is_const(sc_op(bb, 0)) {
            let c1 = sc_ap(sc_op(bb, 0));
            let c2 = sc_ap(a);
            var pres = SF_ANY;
            let cadd = ap_add(c1, c2);
            let af = sc_flags(bb);
            if (af & SF_NUW) != 0 && ap_ule(cadd, c1) { pres |= SF_NUW; }
            if (af & SF_NSW) != 0 && ap_is_neg(c1) == ap_is_neg(cadd) && ap_ule(ap_abs(cadd), ap_abs(c1)) { pres |= SF_NSW; }
            if pres != SF_ANY {
                let nb = ss.len;
                ss.push(sc_get_constant(cadd));
                for k in 1..sc_nops(bb) { ss.push(sc_op(bb, k)); }
                let r = sc_add_n(nb, pres, 0);
                return ss_ret(b, r);
            }
        }
        // (-C1 + X) + zext(C1 + Y) style: A + zext(InnerAdd)
        if sc_kind(bb) == SC_ZEXT && sc_kind(sc_op(bb, 0)) == SC_ADD {
            let inner = sc_op(bb, 0);
            let narrow_a = sc_get_truncate(a, sc_ty(inner), 0);
            if narrow_a == sc_get_negative(sc_op(inner, 0), SF_ANY) && sc_get_zero_extend(narrow_a, sc_ty(bb), 0) == a {
                let tb = ss.len;
                ss.push(narrow_a);
                ss.push(inner);
                let fl = sc_strengthen_flags(SC_ADD, tb, 2, SF_ANY);
                ss.resize(tb);
                if (fl & SF_NUW) != 0 {
                    let r = sc_get_zero_extend(sc_add(narrow_a, inner), sc_ty(bb), 0);
                    return ss_ret(b, r);
                }
            }
        }
    }
    // (-1 * (X urem Y)) + X  -->  Y * (X /u Y)
    if ss_n(b) == 2 {
        let m = ss[b];
        if sc_kind(m) == SC_MUL && sc_nops(m) == 2 && sc_is_all_ones(sc_op(m, 0)) {
            let x, y, ok = sc_match_urem(sc_op(m, 1));
            if ok && x == ss[b + 1] {
                let r = sc_mul(y, sc_get_udiv(ss[b + 1], y));
                return ss_ret(b, r);
            }
        }
    }

    while idx < ss_n(b) && sc_kind(ss[b + idx]) < SC_ADD { idx++; }
    if idx < ss_n(b) {
        var deleted = false;
        var common = orig & SF_NUW;
        while idx < ss_n(b) && sc_kind(ss[b + idx]) == SC_ADD {
            let add = ss[b + idx];
            if ss_n(b) > sc_addops_inline_threshold || sc_nops(add) > sc_addops_inline_threshold { break; }
            ss_erase(b, idx);
            ss_push_ops(add);
            deleted = true;
            common = common & sc_flags(add);
        }
        if deleted { return sc_add_n(b, common, depth + 1); }
    }

    while idx < ss_n(b) && sc_kind(ss[b + idx]) < SC_MUL { idx++; }
    if idx < ss_n(b) && sc_kind(ss[b + idx]) == SC_MUL {
        let bw = sc_type_bits(ty);
        let mark = sc_cops.len;
        let interesting, acc = sc_collect_add_scales(mark, ap_zero(bw), true, b, ss_n(b), ap_u64(1, bw));
        if interesting {
            // MulOpLists: distinct scales in ascending unsigned order (on sc_dscales)
            let sb = sc_newscales.len;
            let dm = sc_dscales.len;
            for k in mark..sb {
                let sc = sc_newscales[k];
                var seen = false;
                for j in dm..sc_dscales.len { if ap_eq(sc_dscales[j], sc) { seen = true; break; } }
                if !seen { sc_dscales.push(sc); }
            }
            var x = dm + 1;
            while x < sc_dscales.len {
                let v = sc_dscales[x];
                var y = x;
                while y > dm && ap_ult(v, sc_dscales[y - 1]) { sc_dscales[y] = sc_dscales[y - 1]; y--; }
                sc_dscales[y] = v;
                x++;
            }
            ss.resize(b);
            if !ap_is_zero(acc) { ss.push(sc_get_constant(acc)); }
            var u = dm;
            while u < sc_dscales.len {
                let sc = sc_dscales[u];
                if !ap_is_zero(sc) {
                    let lb = ss.len;
                    for k in mark..sb { if ap_eq(sc_newscales[k], sc) { ss.push(sc_cops[k]); } }
                    let sum = sc_add_n(lb, SF_ANY, depth + 1);
                    if ap_is_one(sc) { ss.push(sum); }
                    else { let m = sc_mul2(sc_get_constant(sc), sum, SF_ANY, depth + 1); ss.push(m); }
                }
                u++;
            }
            sc_dscales.resize(dm);
            sc_cops.resize(mark);
            sc_newscales.resize(mark);
            if ss_n(b) == 0 { return ss_ret(b, sc_get_zero(ty)); }
            if ss_n(b) == 1 { return ss_ret(b, ss[b]); }
            return sc_add_n(b, SF_ANY, depth + 1);
        }
        sc_cops.resize(mark);
        sc_newscales.resize(mark);
    }

    // X*Y + X*Z  -->  X*(Y+Z)
    while idx < ss_n(b) && sc_kind(ss[b + idx]) == SC_MUL {
        let mul = ss[b + idx];
        for mop in sc_nops(mul) {
            let mos = sc_op(mul, mop);
            if sc_is_const(mos) { continue; }
            let cb = ss.len;            // Cofactors on ss, DeadIndices on sc_newops
            let dmark = sc_newops.len;
            let e2 = cb - b;
            for addop in e2 {
                if mos == ss[b + addop] {
                    ss.push(sc_get_one(ty));
                    sc_newops.push(addop as i32);
                    continue;
                }
                if addop <= idx || sc_kind(ss[b + addop]) != SC_MUL { continue; }
                let om = ss[b + addop];
                for omop in sc_nops(om) {
                    if sc_op(om, omop) == mos {
                        let f = sc_strip_factor(om, omop, depth);
                        ss.push(f);
                        sc_newops.push(addop as i32);
                        break;
                    }
                }
            }
            if ss.len > cb {
                let f = sc_strip_factor(mul, mop, depth);
                ss.push(f);
                let inner = sc_add_n(cb, SF_ANY, depth + 1);
                let outer = sc_mul2(mos, inner, SF_ANY, depth + 1);
                let ndead = sc_newops.len - dmark;
                if ss_n(b) == ndead + 1 { sc_newops.resize(dmark); return ss_ret(b, outer); }
                ss_erase(b, idx);
                var d = sc_newops.len - 1;
                while d >= dmark {
                    let dead = sc_newops[d] as i64;
                    ss_erase(b, if dead > idx { dead - 1 } else { dead });
                    d--;
                }
                sc_newops.resize(dmark);
                ss.push(outer);
                return sc_add_n(b, SF_ANY, depth + 1);
            }
            sc_newops.resize(dmark);
        }
        idx++;
    }

    while idx < ss_n(b) && sc_kind(ss[b + idx]) < SC_ADDREC { idx++; }
    while idx < ss_n(b) && sc_kind(ss[b + idx]) == SC_ADDREC {
        let ar = ss[b + idx];
        let arl = sc_loop(ar);
        // LIOps: the operands available at the loop's entry, moved out of Ops
        let lib0 = sc_newops.len;
        var i2: i64 = 0;
        var e3 = ss_n(b);
        while i2 != e3 {
            if sc_is_available_at_loop_entry(ss[b + i2], arl) {
                sc_newops.push(ss[b + i2]);
                ss_erase(b, i2);
                e3--;
                continue;
            }
            i2++;
        }
        if sc_newops.len > lib0 {
            let lb = ss.len;
            for k in lib0..sc_newops.len { ss.push(sc_newops[k]); }
            ss.push(ar);
            var fl = sc_strengthen_flags(SC_ADD, lb, ss_n(lb), orig);
            ss.pop();
            ss.push(sc_op(ar, 0));
            var addfl = fl;
            if addfl != SF_ANY {
                let defi = sc_get_defining_scope_bound(lb, ss_n(lb));
                let reach = block_first(loop_header(arl));
                if !sc_guaranteed_transfer_to(defi, reach) { addfl = SF_ANY; }
            }
            sc_newops.resize(lib0);
            let start = sc_add_n(lb, addfl, depth + 1);
            fl = sc_flags(ar) & (fl | SF_NW);
            let rb = ss.len;
            ss.push(start);
            for k in 1..sc_nops(ar) { ss.push(sc_op(ar, k)); }
            let newrec = sc_addrec_n(rb, arl, fl);
            if ss_n(b) == 1 { return ss_ret(b, newrec); }
            var q: i64 = 0;
            loop { if ss[b + q] == ar { ss[b + q] = newrec; break; } q++; }
            return sc_add_n(b, SF_ANY, depth + 1);
        }
        sc_newops.resize(lib0);
        // fold AddRecs of the same loop (AddRecOps on sc_newops)
        var oi = idx + 1;
        while oi < ss_n(b) && sc_kind(ss[b + oi]) == SC_ADDREC {
            if arl == sc_loop(ss[b + oi]) {
                let rm = sc_newops.len;
                for k in sc_nops(ar) { sc_newops.push(sc_op(ar, k)); }
                while oi != ss_n(b) && sc_kind(ss[b + oi]) == SC_ADDREC {
                    let other = ss[b + oi];
                    if sc_loop(other) == arl {
                        var i3: i64 = 0;
                        let e4 = sc_nops(other);
                        while i3 != e4 {
                            if i3 >= sc_newops.len - rm {
                                for k in i3..e4 { sc_newops.push(sc_op(other, k)); }
                                break;
                            }
                            let x = sc_add2(sc_newops[rm + i3], sc_op(other, i3), SF_ANY, depth + 1);
                            sc_newops[rm + i3] = x;
                            i3++;
                        }
                        ss_erase(b, oi);
                        continue;
                    }
                    oi++;
                }
                let rb = ss.len;
                for k in rm..sc_newops.len { ss.push(sc_newops[k]); }
                sc_newops.resize(rm);
                let rec = sc_addrec_n(rb, arl, SF_ANY);
                ss[b + idx] = rec;
                return sc_add_n(b, SF_ANY, depth + 1);
            }
            oi++;
        }
        idx++;
    }
    return sc_get_or_create_comm(SC_ADD, b, sc_strengthen_flags(SC_ADD, b, ss_n(b), orig));
}

recursive fn sc_find_trunc_src_type(o: i32) -> i32 {
    if sc_kind(o) == SC_TRUNC { return sc_ty(sc_op(o, 0)); }
    if sc_kind(o) == SC_MUL {
        let last = sc_op(o, sc_nops(o) - 1);
        if sc_kind(last) == SC_TRUNC { return sc_ty(sc_op(last, 0)); }
    }
    return -1;
}

// StripFactor (getAddExpr's lambda)
recursive fn sc_strip_factor(m: i32, opidx: i64, depth: i64) -> i32 {
    if sc_nops(m) == 2 { return sc_op(m, if opidx == 0 { 1 } else { 0 }); }
    let b = ss.len;
    for k in sc_nops(m) { if k != opidx { ss.push(sc_op(m, k)); } }
    return sc_mul_n(b, SF_ANY, depth + 1);
}


recursive fn sc_umul_ov(i: u64, j: u64, ov: bool) -> u64, bool {
    let k = i * j;
    if j > 1 && k / j != i { return k, true; }
    return k, ov;
}
// Choose(n, k)
recursive fn sc_choose(n: u64, k0: u64, ov0: bool) -> u64, bool {
    var ov = ov0;
    if n == 0 || n == k0 { return 1, ov; }
    if k0 > n { return 0, ov; }
    var k = k0;
    if k > n / 2 { k = n - k; }
    var r: u64 = 1;
    var i: u64 = 1;
    while i <= k {
        let x, o = sc_umul_ov(r, n - (i - 1), ov);
        r = x;
        ov = o;
        r = r / i;
        i++;
    }
    return r, ov;
}

// containsConstantInAddMulChain
recursive fn sc_contains_const_in_add_mul_chain(s: i32) -> bool {
    if sc_is_const(s) { return true; }
    let k = sc_kind(s);
    if k != SC_ADD && k != SC_MUL { return false; }
    for i in sc_nops(s) { if sc_contains_const_in_add_mul_chain(sc_op(s, i)) { return true; } }
    return false;
}

recursive fn sc_mul3(a: i32, c: i32, d: i32, flags: u32, depth: i64) -> i32 { let b = ss.len; ss.push(a); ss.push(c); ss.push(d); return sc_mul_n(b, flags, depth); }

// getMulExpr(SmallVectorImpl &Ops, OrigFlags, Depth): Ops = ss[b..]
recursive fn sc_mul_n(b: i64, orig: u32, depth: i64) -> i32 {
    if ss_n(b) == 1 { return ss_ret(b, ss[b]); }
    let folded = sc_constant_fold_and_group(b, SC_MUL);
    if folded >= 0 { return ss_ret(b, folded); }
    if depth > sc_max_arith_depth || sc_has_huge(b, ss_n(b)) {
        return sc_get_or_create_comm(SC_MUL, b, sc_strengthen_flags(SC_MUL, b, ss_n(b), orig));
    }
    {
        let ex = sc_find(SC_MUL, b, ss_n(b), -1, -1, -1);
        if ex >= 0 {
            if sc_nowrap(ex, orig) != orig { sc_or_flags(ex, sc_strengthen_flags(SC_MUL, b, ss_n(b), orig)); }
            return ss_ret(b, ex);
        }
    }
    if sc_is_const(ss[b]) && ss_n(b) == 2 {
        let lhsc = ss[b];
        let o1 = ss[b + 1];
        if sc_kind(o1) == SC_ADD && sc_nops(o1) == 2 && sc_contains_const_in_add_mul_chain(o1) {
            let l = sc_mul2(lhsc, sc_op(o1, 0), SF_ANY, depth + 1);
            let r = sc_mul2(lhsc, sc_op(o1, 1), SF_ANY, depth + 1);
            return ss_ret(b, sc_add2(l, r, SF_ANY, depth + 1));
        }
        if sc_is_all_ones(lhsc) {
            if sc_kind(o1) == SC_ADD {
                let nb = ss.len;
                var any = false;
                for k in sc_nops(o1) {
                    let m = sc_mul2(lhsc, sc_op(o1, k), SF_ANY, depth + 1);
                    if sc_kind(m) != SC_MUL { any = true; }
                    ss.push(m);
                }
                if any { let r = sc_add_n(nb, SF_ANY, depth + 1); return ss_ret(b, r); }
                ss.resize(nb);
            } else if sc_kind(o1) == SC_ADDREC {
                let nb = ss.len;
                for k in sc_nops(o1) { let m = sc_mul2(lhsc, sc_op(o1, k), SF_ANY, depth + 1); ss.push(m); }
                var mask = SF_NW;
                if sc_has_nsw(o1) {
                    let mn = ap_smin_val(sc_bits(o1));
                    if !ap_eq(sc_get_signed_range_min(o1), mn) { mask |= SF_NSW; }
                }
                let r = sc_addrec_n(nb, sc_loop(o1), sc_flags(o1) & mask);
                return ss_ret(b, r);
            }
        }
        if sc_kind(o1) == SC_ZEXT && sc_kind(sc_op(o1, 0)) == SC_ADD {
            let inner = sc_op(o1, 0);
            let narrow_c = sc_get_truncate(lhsc, sc_ty(inner), 0);
            if sc_is_const(sc_op(inner, 0)) && sc_get_zero_extend(narrow_c, sc_ty(o1), 0) == lhsc {
                let tb = ss.len;
                ss.push(narrow_c);
                ss.push(inner);
                let fl = sc_strengthen_flags(SC_MUL, tb, 2, SF_ANY);
                ss.resize(tb);
                if (fl & SF_NUW) != 0 {
                    let res = sc_mul2(narrow_c, inner, SF_NUW, depth + 1);
                    return ss_ret(b, sc_get_zero_extend(res, sc_ty(o1), depth + 1));
                }
            }
        }
        var c1v = sc_ap(lhsc);
        if ap_is_neg(c1v) && !ap_is_min_signed(c1v) && !ap_is_all_ones(c1v) { c1v = ap_abs(c1v); }
        if ap_is_pow2(c1v) && sc_kind(o1) == SC_UDIV && sc_is_const(sc_op(o1, 1)) && ap_is_pow2(sc_ap(sc_op(o1, 1))) {
            let d = sc_op(o1, 0);
            let c2 = sc_op(o1, 1);
            let log1 = ap_log2(c1v);
            if log1 <= sc_get_min_trailing_zeros(d) {
                var nm: i32 = -1;
                if ap_uge(c1v, sc_ap(c2)) { nm = sc_mul(sc_get_udiv(sc_get_constant(c1v), c2), d); }
                else if ap_log2(sc_ap(c2)) <= sc_get_min_trailing_zeros(d) {
                    nm = sc_get_udiv(d, sc_get_udiv(c2, sc_get_constant(c1v)));
                }
                if nm >= 0 {
                    return ss_ret(b, if ap_eq(c1v, sc_ap(lhsc)) { nm } else { sc_get_negative(nm, SF_ANY) });
                }
            }
        }
    }
    var idx: i64 = 0;
    while idx < ss_n(b) && sc_kind(ss[b + idx]) < SC_MUL { idx++; }
    if idx < ss_n(b) {
        var deleted = false;
        while idx < ss_n(b) && sc_kind(ss[b + idx]) == SC_MUL {
            if ss_n(b) > sc_mulops_inline_threshold { break; }
            let m = ss[b + idx];
            ss_erase(b, idx);
            ss_push_ops(m);
            deleted = true;
        }
        if deleted { return sc_mul_n(b, SF_ANY, depth + 1); }
    }
    while idx < ss_n(b) && sc_kind(ss[b + idx]) < SC_ADDREC { idx++; }
    while idx < ss_n(b) && sc_kind(ss[b + idx]) == SC_ADDREC {
        var ar = ss[b + idx];
        let arl = sc_loop(ar);
        let lib0 = sc_newops.len;
        var i2: i64 = 0;
        var e3 = ss_n(b);
        while i2 != e3 {
            if sc_is_available_at_loop_entry(ss[b + i2], arl) {
                sc_newops.push(ss[b + i2]);
                ss_erase(b, i2);
                e3--;
                continue;
            }
            i2++;
        }
        if sc_newops.len > lib0 {
            let lb = ss.len;
            for k in lib0..sc_newops.len { ss.push(sc_newops[k]); }
            sc_newops.resize(lib0);
            let scale = sc_mul_n(lb, SF_ANY, depth + 1);
            let tb = ss.len;
            ss.push(scale);
            ss.push(ar);
            // ComputeFlags runs first (it may add flags to the AddRec through its ranges)
            let cf = sc_strengthen_flags(SC_MUL, tb, 2, orig);
            var fl = sc_flags(ar) & cf;
            ss.resize(tb);
            let nb = ss.len;
            for i in sc_nops(ar) {
                let m = sc_mul2(scale, sc_op(ar, i), SF_ANY, depth + 1);
                ss.push(m);
                if (fl & SF_NSW) != 0 && (fl & SF_NUW) == 0 {
                    let reg = rg_guaranteed_no_wrap(OP_MUL, sc_get_signed_range(scale), NW_NSW);
                    if !rg_contains(reg, sc_get_signed_range(sc_op(ar, i))) { fl = fl & ~SF_NSW; }
                }
            }
            let newrec = sc_addrec_n(nb, arl, fl);
            if ss_n(b) == 1 { return ss_ret(b, newrec); }
            var q: i64 = 0;
            loop { if ss[b + q] == ar { ss[b + q] = newrec; break; } q++; }
            return sc_mul_n(b, SF_ANY, depth + 1);
        }
        sc_newops.resize(lib0);
        var modified = false;
        var oi = idx + 1;
        while oi != ss_n(b) && sc_kind(ss[b + oi]) == SC_ADDREC {
            let other = ss[b + oi];
            if sc_loop(other) != arl { oi++; continue; }
            if sc_nops(ar) + sc_nops(other) - 1 > sc_max_add_rec_size || sc_size(ar) >= sc_huge_expr_threshold ||
               sc_size(other) >= sc_huge_expr_threshold { oi++; continue; }
            var ov = false;
            let ty = sc_ty(ar);
            let large = sc_type_bits(ty) > 64;
            let rm = sc_newops.len;       // AddRecOps
            let xe = sc_nops(ar) + sc_nops(other) - 1;
            var x: i64 = 0;
            while x != xe && !ov {
                let sb = ss.len;            // SumOps
                var y = x;
                let ye = 2 * x + 1;
                while y != ye && !ov {
                    let c1, o1 = sc_choose(x as u64, (2 * x - y) as u64, ov);
                    ov = o1;
                    var z = if y - x > y - sc_nops(ar) + 1 { y - x } else { y - sc_nops(ar) + 1 };
                    let ze = if x + 1 < sc_nops(other) { x + 1 } else { sc_nops(other) };
                    while z < ze && !ov {
                        let c2, o2 = sc_choose((2 * x - y) as u64, (x - z) as u64, ov);
                        ov = o2;
                        var coeff: u64 = 0;
                        if large { let cc, o3 = sc_umul_ov(c1, c2, ov); coeff = cc; ov = o3; } else { coeff = c1 * c2; }
                        let ct = sc_get_constant_ty(ty, coeff, false);
                        let t = sc_mul3(ct, sc_op(ar, y - z), sc_op(other, z), SF_ANY, depth + 1);
                        ss.push(t);
                        z++;
                    }
                    y++;
                }
                if ss.len == sb { ss.push(sc_get_zero(ty)); }
                let sum = sc_add_n(sb, SF_ANY, depth + 1);
                sc_newops.push(sum);
                x++;
            }
            if !ov {
                let rb = ss.len;
                for k in rm..sc_newops.len { ss.push(sc_newops[k]); }
                sc_newops.resize(rm);
                let nar = sc_addrec_n(rb, arl, SF_ANY);
                if ss_n(b) == 2 { return ss_ret(b, nar); }
                ss[b + idx] = nar;
                ss_erase(b, oi);
                modified = true;
                if sc_kind(nar) != SC_ADDREC { break; }
                ar = nar;
                continue;
            }
            sc_newops.resize(rm);
            oi++;
        }
        if modified { return sc_mul_n(b, SF_ANY, depth + 1); }
        idx++;
    }
    return sc_get_or_create_comm(SC_MUL, b, sc_strengthen_flags(SC_MUL, b, ss_n(b), orig));
}


// getURemExpr
recursive fn sc_get_urem(l: i32, r: i32) -> i32 {
    if sc_is_const(r) {
        if sc_is_one(r) { return sc_get_zero(sc_ty(l)); }
        if ap_is_pow2(sc_ap(r)) {
            let full = sc_ty(l);
            let tt = ty_int(ap_log2(sc_ap(r)));
            return sc_get_zero_extend(sc_get_truncate(l, tt, 0), full, 0);
        }
    }
    let ud = sc_get_udiv(l, r);
    let mu = sc_mul2(ud, r, SF_NUW, 0);
    return sc_get_minus(l, mu, SF_NUW, 0);
}

recursive fn sc_udiv_find(l: i32, r: i32) -> i32 { let b = ss.len; ss.push(l); ss.push(r); let s = sc_find(SC_UDIV, b, 2, -1, -1, -1); ss.resize(b); return s; }
recursive fn sc_addrec2(start: i32, step: i32, l: i32, flags: u32) -> i32 {
    let b = ss.len;
    ss.push(start);
    if sc_kind(step) == SC_ADDREC && sc_loop(step) == l {
        ss_push_ops(step);
        return sc_addrec_n(b, l, flags & SF_NW);
    }
    ss.push(step);
    return sc_addrec_n(b, l, flags);
}

// getUDivExpr
recursive fn sc_get_udiv(l0: i32, r: i32) -> i32 {
    var l = l0;
    {
        let s = sc_udiv_find(l, r);
        if s >= 0 { return s; }
    }
    if sc_is_zero(l) { return l; }
    if sc_is_const(r) {
        let rc = sc_ap(r);
        if ap_is_one(rc) { return l; }
        if !ap_is_zero(rc) {
            let ty = sc_ty(l);
            let lz = ap_countl_zero(rc);
            var msa = sc_type_bits(ty) - lz - 1;
            if !ap_is_pow2(rc) { msa++; }
            let ext = ty_int(sc_type_bits(ty) + msa);
            if sc_kind(l) == SC_ADDREC {
                let ar = l;
                let step = sc_get_step_recurrence(ar);
                if sc_is_const(step) {
                    let si = sc_ap(step);
                    let di = rc;
                    if ap_is_zero(ap_urem(si, di)) &&
                       sc_get_zero_extend(ar, ext, 0) == sc_addrec2(sc_get_zero_extend(sc_op(ar, 0), ext, 0), sc_get_zero_extend(step, ext, 0), sc_loop(ar), SF_ANY) {
                        let b = ss.len;
                        for k in sc_nops(ar) { let d = sc_get_udiv(sc_op(ar, k), r); ss.push(d); }
                        return sc_addrec_n(b, sc_loop(ar), SF_NW);
                    }
                    if ap_is_zero(ap_urem(di, si)) {
                        let srem = sc_get_urem(sc_op(ar, 0), step);
                        if sc_is_const(srem) {
                            let sr = sc_ap(srem);
                            let nowrap = sc_get_zero_extend(ar, ext, 0) ==
                                sc_addrec2(sc_get_zero_extend(sc_op(ar, 0), ext, 0), sc_get_zero_extend(step, ext, 0), sc_loop(ar), SF_ANY);
                            let can_fold = ap_ule(si, di) && ap_is_pow2(si) && ap_is_pow2(di);
                            let ns = sc_get_minus(sc_op(ar, 0), sc_get_constant(sr), SF_ANY, 0);
                            if !ap_is_zero(sr) && (nowrap || can_fold) && sc_kind(ns) != SC_ADD {
                                let nl = sc_addrec2(ns, step, sc_loop(ar), if nowrap { SF_NW } else { SF_ANY });
                                if l != nl {
                                    l = nl;
                                    let s = sc_udiv_find(l, r);
                                    if s >= 0 { return s; }
                                }
                            }
                        }
                    }
                }
            }
            if sc_kind(l) == SC_MUL {
                let m = l;
                let b = ss.len;
                for k in sc_nops(m) { let z = sc_get_zero_extend(sc_op(m, k), ext, 0); ss.push(z); }
                let zm = sc_get_zero_extend(m, ext, 0);
                if zm == sc_mul_n(b, SF_ANY, 0) {
                    for i in sc_nops(m) {
                        let o = sc_op(m, i);
                        let dv = sc_get_udiv(o, r);
                        if sc_kind(dv) != SC_UDIV && sc_mul(dv, r) == o {
                            let nb = ss.len;
                            ss_push_ops(m);
                            ss[nb + i] = dv;
                            return sc_mul_n(nb, SF_ANY, 0);
                        }
                    }
                    if sc_is_const(sc_op(m, 0)) {
                        let factor = ap_gcd(sc_ap(sc_op(m, 0)), rc);
                        if ap_active_bits(factor) > 1 {
                            let nb = ss.len;
                            ss.push(sc_get_constant(ap_udiv(sc_ap(sc_op(m, 0)), factor)));
                            for k in 1..sc_nops(m) { ss.push(sc_op(m, k)); }
                            let nm = sc_mul_n(nb, SF_ANY, 0);
                            return sc_get_udiv(nm, sc_get_constant(ap_udiv(rc, factor)));
                        }
                    }
                }
            }
            if sc_kind(l) == SC_UDIV && sc_is_const(sc_op(l, 1)) {
                let nr, ov = ap_umul_ov(sc_ap(sc_op(l, 1)), rc);
                if ov { return sc_get_constant_ty(sc_ty(r), 0, false); }
                return sc_get_udiv(sc_op(l, 0), sc_get_constant(nr));
            }
            if sc_kind(l) == SC_ADD {
                let a = l;
                let b = ss.len;
                for k in sc_nops(a) { let z = sc_get_zero_extend(sc_op(a, k), ext, 0); ss.push(z); }
                let za = sc_get_zero_extend(a, ext, 0);
                if za == sc_add_n(b, SF_ANY, 0) {
                    let nb = ss.len;
                    for i in sc_nops(a) {
                        let o = sc_get_udiv(sc_op(a, i), r);
                        if sc_kind(o) == SC_UDIV || sc_mul(o, r) != sc_op(a, i) { break; }
                        ss.push(o);
                    }
                    if ss_n(nb) == sc_nops(a) { return sc_add_n(nb, SF_ANY, 0); }
                    ss.resize(nb);
                }
            }
            // (N - M) + M * A) /u N with N, M powers of 2
            if sc_kind(l) == SC_ADD && sc_nops(l) == 2 && sc_is_const(sc_op(l, 0)) {
                let m2 = sc_op(l, 1);
                if sc_kind(m2) == SC_MUL && sc_nops(m2) == 2 && sc_is_const(sc_op(m2, 0)) {
                    let n = rc;
                    let mm = sc_ap(sc_op(m2, 0));
                    let nmm = sc_ap(sc_op(l, 0));
                    if ap_is_pow2(n) && ap_is_pow2(mm) && ap_ult(mm, n) && ap_eq(nmm, ap_sub(n, mm)) {
                        let x = sc_add(sc_get_constant(ap_sub_u64(n, 1)), sc_mul(sc_get_constant(mm), sc_op(m2, 1)));
                        return sc_get_udiv(x, r);
                    }
                }
            }
            if sc_is_const(l) { return sc_get_constant(ap_udiv(sc_ap(l), rc)); }
        }
    }
    // (-C + (C smax RHS)) /u RHS --> 0
    if sc_kind(l) == SC_ADD && sc_nops(l) == 2 && sc_is_const(sc_op(l, 0)) {
        let sm = sc_op(l, 1);
        if sc_kind(sm) == SC_SMAX && sc_nops(sm) == 2 && sc_is_const(sc_op(sm, 0)) && sc_op(sm, 1) == r {
            let negc = sc_ap(sc_op(l, 0));
            if ap_is_neg(negc) && !ap_is_min_signed(negc) && ap_eq(sc_ap(sc_op(sm, 0)), ap_neg(negc)) { return sc_get_zero(sc_ty(l)); }
        }
    }
    if sc_kind(l) == SC_MUL && sc_has_nuw(l) {
        for i in sc_nops(l) {
            if sc_op(l, i) == r {
                let b = ss.len;
                for k in sc_nops(l) { if k != i { ss.push(sc_op(l, k)); } }
                return sc_mul_n(b, SF_ANY, 0);
            }
        }
    }
    // (A * vscale)<nuw> /u (B * vscale)<nuw>
    {
        let nl, okl = sc_match_nuw_mul_vscale(l);
        let nr, okr = sc_match_nuw_mul_vscale(r);
        if okl && okr { return sc_get_udiv(nl, nr); }
    }
    let s = sc_udiv_find(l, r);
    if s >= 0 { return s; }
    let b = ss.len;
    ss.push(l);
    ss.push(r);
    let n = sc_insert(SC_UDIV, b, 2, -1, -1, sc_ty(r), 0);
    ss.resize(b);
    sc_register_users(n);
    return n;
}

// m_scev_c_NUWMul(m_SCEV(X), m_SCEVVScale()): a 2-operand nuw mul with vscale as either operand
recursive fn sc_match_nuw_mul_vscale(s: i32) -> i32, bool {
    if sc_kind(s) != SC_MUL || sc_nops(s) != 2 || !sc_has_nuw(s) { return -1, false; }
    if sc_kind(sc_op(s, 1)) == SC_VSCALE { return sc_op(s, 0), true; }
    if sc_kind(sc_op(s, 0)) == SC_VSCALE { return sc_op(s, 1), true; }
    return -1, false;
}

// getAddRecExpr(SmallVectorImpl &Operands, L, Flags): Operands = ss[b..]
recursive fn sc_addrec_n(b: i64, l: i32, flags0: u32) -> i32 {
    if ss_n(b) == 1 { return ss_ret(b, ss[b]); }
    if sc_is_zero(ss[ss.len - 1]) { ss.pop(); return sc_addrec_n(b, l, SF_ANY); }
    var flags = sc_strengthen_flags(SC_ADDREC, b, ss_n(b), flags0);
    let nested = ss[b];
    if sc_kind(nested) == SC_ADDREC {
        let nl = sc_loop(nested);
        var cond = false;
        if loop_contains_loop(l, nl) { cond = loop_depth(l) < loop_depth(nl); }
        else { cond = !loop_contains_loop(nl, l) && dt_dominates_block(DT_DOM, loop_header(l), loop_header(nl)); }
        if cond {
            ss[b] = sc_op(nested, 0);
            var all = true;
            for k in ss_n(b) { if !sc_is_loop_invariant(ss[b + k], l) { all = false; break; } }
            if all {
                let outer = flags & (SF_NW | sc_flags(nested));
                // NestedOperands[0] = getAddRecExpr(Operands, L, OuterFlags); Operands is reused below only on failure
                let cb = ss.len;
                for k in cb - b { ss.push(ss[b + k]); }
                let nop0 = sc_addrec_n(cb, l, outer);
                let nb = ss.len;
                ss.push(nop0);
                for k in 1..sc_nops(nested) { ss.push(sc_op(nested, k)); }
                var all2 = true;
                for k in ss_n(nb) { if !sc_is_loop_invariant(ss[nb + k], nl) { all2 = false; break; } }
                if all2 {
                    let inner = sc_flags(nested) & (SF_NW | flags);
                    let r = sc_addrec_n(nb, nl, inner);
                    return ss_ret(b, r);
                }
                ss.resize(nb);
            }
            ss[b] = nested;
        }
    }
    // getOrCreateAddRecExpr
    let n = ss_n(b);
    var s = sc_find(SC_ADDREC, b, n, -1, l, -1);
    if s < 0 {
        s = sc_insert(SC_ADDREC, b, n, -1, l, sc_ty(ss[b]), 0);
        sc_loop_users_add(l, s);
        sc_register_users(s);
    }
    sc_set_nowrap_flags(s, flags);
    return ss_ret(b, s);
}

// SCEVAddRecExpr::getStepRecurrence
recursive fn sc_get_step_recurrence(ar: i32) -> i32 {
    if sc_nops(ar) == 2 { return sc_op(ar, 1); }
    let b = ss.len;
    for k in 1..sc_nops(ar) { ss.push(sc_op(ar, k)); }
    return sc_addrec_n(b, sc_loop(ar), sc_flags(ar) & SF_NW);
}
recursive fn sc_is_affine(ar: i32) -> bool { sc_nops(ar) == 2 }
recursive fn sc_is_quadratic(ar: i32) -> bool { sc_nops(ar) == 3 }

// SCEVAddRecExpr::getPostIncExpr
recursive fn sc_get_post_inc(ar: i32) -> i32 {
    let b = ss.len;
    for i in sc_nops(ar) - 1 { let x = sc_add(sc_op(ar, i), sc_op(ar, i + 1)); ss.push(x); }
    ss.push(sc_op(ar, sc_nops(ar) - 1));
    return sc_addrec_n(b, sc_loop(ar), SF_ANY);
}

recursive fn sc_minmax2(kind: i64, a: i32, c: i32) -> i32 { let b = ss.len; ss.push(a); ss.push(c); return sc_minmax_n(kind, b); }
recursive fn sc_smax(a: i32, c: i32) -> i32 { sc_minmax2(SC_SMAX, a, c) }
recursive fn sc_umax(a: i32, c: i32) -> i32 { sc_minmax2(SC_UMAX, a, c) }
recursive fn sc_smin(a: i32, c: i32) -> i32 { sc_minmax2(SC_SMIN, a, c) }
recursive fn sc_umin(a: i32, c: i32) -> i32 { sc_minmax2(SC_UMIN, a, c) }
recursive fn sc_umin_seq(a: i32, c: i32) -> i32 { let b = ss.len; ss.push(a); ss.push(c); return sc_seq_minmax_n(SC_SEQUMIN, b); }
// getUMinExpr(Ops, Sequential)
recursive fn sc_umin_n(b: i64, seq: bool) -> i32 { if seq { sc_seq_minmax_n(SC_SEQUMIN, b) } else { sc_minmax_n(SC_UMIN, b) } }
recursive fn sc_get_abs(o: i32, nsw: bool) -> i32 { sc_smax(o, sc_get_negative(o, if nsw { SF_NSW } else { SF_ANY })) }

// getMinMaxExpr(Kind, Ops): Ops = ss[b..]
recursive fn sc_minmax_n(kind: i64, b: i64) -> i32 {
    if ss_n(b) == 1 { return ss_ret(b, ss[b]); }
    let signed = kind == SC_SMAX || kind == SC_SMIN;
    let is_max = kind == SC_SMAX || kind == SC_UMAX;
    let folded = sc_constant_fold_and_group(b, kind);
    if folded >= 0 { return ss_ret(b, folded); }
    {
        let ex = sc_find(kind, b, ss_n(b), -1, -1, -1);
        if ex >= 0 { return ss_ret(b, ex); }
    }
    var idx: i64 = 0;
    while idx < ss_n(b) && sc_kind(ss[b + idx]) < kind { idx++; }
    if idx < ss_n(b) {
        var deleted = false;
        while sc_kind(ss[b + idx]) == kind {
            let m = ss[b + idx];
            ss_erase(b, idx);
            ss_push_ops(m);
            deleted = true;
        }
        if deleted { return sc_minmax_n(kind, b); }
    }
    let ge: i64 = if signed { P_SGE } else { P_UGE };
    let le: i64 = if signed { P_SLE } else { P_ULE };
    let first = if is_max { ge } else { le };
    let second = if is_max { le } else { ge };
    var i: i64 = 0;
    var e = ss_n(b) - 1;
    while i != e {
        if ss[b + i] == ss[b + i + 1] || sc_known_via_non_recursive_reasoning(first, ss[b + i], ss[b + i + 1]) {
            ss_erase(b, i + 1);
            i--;
            e--;
        } else if sc_known_via_non_recursive_reasoning(second, ss[b + i], ss[b + i + 1]) {
            ss_erase(b, i);
            i--;
            e--;
        }
        i++;
    }
    if ss_n(b) == 1 { return ss_ret(b, ss[b]); }
    let n = ss_n(b);
    let ex = sc_find(kind, b, n, -1, -1, -1);
    if ex >= 0 { return ss_ret(b, ex); }
    let s = sc_insert(kind, b, n, -1, -1, sc_ty(ss[b]), SF_NUW | SF_NSW);
    sc_register_users(s);
    return ss_ret(b, s);
}

// SCEVSequentialMinMaxDeduplicatingVisitor: SeenOps on sc_seen (from the mark of the top-level call)
var sc_seen: i32[>..<];
let SC_NONE: i32 = -2;      // std::nullopt

recursive fn sc_dedup_visit_one(root: i64, s: i32, sm: i64) -> i32 {
    for k in sm..sc_seen.len { if sc_seen[k] == s { return SC_NONE; } }
    sc_seen.push(s);
    let k = sc_kind(s);
    if !(sc_is_minmax_kind(k) || k == SC_SEQUMIN) { return s; }
    if !(k == root || k == SC_UMIN) { return s; }
    let nb = ss.len;
    let changed = sc_dedup_visit_ops(root, false, scevs[s].at as i64, sc_nops(s), sm);
    if !changed { ss.resize(nb); return s; }
    if ss_n(nb) == 0 { ss.resize(nb); return SC_NONE; }
    if k == SC_SEQUMIN { return sc_seq_minmax_n(k, nb); }
    return sc_minmax_n(k, nb);
}

// visit(Kind, OrigOps, NewOps): pushes the new operands on ss; returns Changed. OrigOps from ss or sc_ops.
recursive fn sc_dedup_visit_ops(root: i64, from_ss: bool, at: i64, n: i64, sm: i64) -> bool {
    var changed = false;
    let nb = ss.len;
    for i in n {
        let o = if from_ss { ss[at + i] } else { sc_ops[at + i] };
        let no = sc_dedup_visit_one(root, o, sm);
        if no != o { changed = true; }
        if no != SC_NONE { ss.push(no); }
    }
    return changed;
}

// impliesPoison (SCEV version) with SCEVPoisonCollector
recursive fn sc_poison_collect(s: i32, look_through: bool, mark: i64) {
    // SCEVTraversal visits each node once
    for k in mark..sc_seen.len { if sc_seen[k] == s { return; } }
    sc_seen.push(s);
    if !look_through && sc_kind(s) == SC_SEQUMIN { return; }
    if sc_is_unknown(s) {
        if !is_guaranteed_not_to_be_poison(sc_value(s), -1, 0) { sc_newops.push(s); }
        return;
    }
    if sc_kind(s) == SC_CONST || sc_kind(s) == SC_VSCALE { return; }
    for i in sc_nops(s) { sc_poison_collect(sc_op(s, i), look_through, mark); }
}

recursive fn sc_implies_poison(assumed: i32, s: i32) -> bool {
    let sm = sc_seen.len;
    let p1 = sc_newops.len;
    sc_poison_collect(assumed, true, sm);
    sc_seen.resize(sm);
    if sc_newops.len == p1 { return true; }
    let p2 = sc_newops.len;
    sc_poison_collect(s, false, sm);
    sc_seen.resize(sm);
    var sub = true;
    for k in p1..p2 {
        var found = false;
        for j in p2..sc_newops.len { if sc_newops[j] == sc_newops[k] { found = true; break; } }
        if !found { sub = false; break; }
    }
    sc_newops.resize(p1);
    return sub;
}

// getSequentialMinMaxExpr(Kind, Ops): Ops = ss[b..]
recursive fn sc_seq_minmax_n(kind: i64, b: i64) -> i32 {
    if ss_n(b) == 1 { return ss_ret(b, ss[b]); }
    {
        let ex = sc_find(kind, b, ss_n(b), -1, -1, -1);
        if ex >= 0 { return ss_ret(b, ex); }
    }
    {
        let sm = sc_seen.len;
        let nb = ss.len;
        let changed = sc_dedup_visit_ops(kind, true, b, nb - b, sm);
        sc_seen.resize(sm);
        if changed {
            let m = ss.len - nb;
            for k in m { ss[b + k] = ss[nb + k]; }
            ss.resize(b + m);
            return sc_seq_minmax_n(kind, b);
        }
        ss.resize(nb);
    }
    {
        var idx: i64 = 0;
        var deleted = false;
        while idx < ss_n(b) {
            if sc_kind(ss[b + idx]) != kind { idx++; continue; }
            let m = ss[b + idx];
            ss_erase(b, idx);
            var k = sc_nops(m) - 1;
            while k >= 0 { ss_insert(b, idx, sc_op(m, k)); k--; }
            deleted = true;
        }
        if deleted { return sc_seq_minmax_n(kind, b); }
    }
    if ss_n(b) == 0 { fatal("internal: empty sequential min/max"); }
    let sat = sc_get_zero(sc_ty(ss[b]));
    let pred = P_ULE;
    var i: i64 = 1;
    let e = ss_n(b);
    while i != e {
        if !sc_is_guaranteed_not_to_cause_ub(ss[b + i]) { i++; continue; }
        if sc_implies_poison(ss[b + i], ss[b + i - 1]) || sc_known_via_non_recursive_reasoning(P_NE, ss[b + i - 1], sat) {
            let m = sc_minmax2(SC_UMIN, ss[b + i - 1], ss[b + i]);
            ss[b + i - 1] = m;
            ss_erase(b, i);
            return sc_seq_minmax_n(kind, b);
        }
        if sc_known_via_non_recursive_reasoning(pred, ss[b + i - 1], ss[b + i]) {
            ss_erase(b, i);
            return sc_seq_minmax_n(kind, b);
        }
        i++;
    }
    let n = ss_n(b);
    let ex = sc_find(kind, b, n, -1, -1, -1);
    if ex >= 0 { return ss_ret(b, ex); }
    let s = sc_insert(kind, b, n, -1, -1, sc_ty(ss[b]), SF_NUW | SF_NSW);
    sc_register_users(s);
    return ss_ret(b, s);
}

// SCEVExprContains(S, UDiv whose divisor may be zero or poison)
recursive fn sc_is_guaranteed_not_to_cause_ub(s: i32) -> bool {
    let sm = sc_seen.len;
    let r = sc_ub_walk(s, sm);
    sc_seen.resize(sm);
    return !r;
}
recursive fn sc_ub_walk(s: i32, mark: i64) -> bool {
    for k in mark..sc_seen.len { if sc_seen[k] == s { return false; } }
    sc_seen.push(s);
    if sc_kind(s) == SC_UDIV {
        let d = sc_op(s, 1);
        if !sc_is_known_non_zero(d) || !sc_is_guaranteed_not_to_be_poison(d) { return true; }
    }
    if sc_kind(s) == SC_UNKNOWN || sc_kind(s) == SC_CONST || sc_kind(s) == SC_VSCALE { return false; }
    for i in sc_nops(s) { if sc_ub_walk(sc_op(s, i), mark) { return true; } }
    return false;
}

// ScalarEvolution::isGuaranteedNotToBePoison
recursive fn sc_is_guaranteed_not_to_be_poison(s: i32) -> bool {
    let sm = sc_seen.len;
    let p = sc_newops.len;
    sc_poison_collect(s, false, sm);
    sc_seen.resize(sm);
    let r = sc_newops.len == p;
    sc_newops.resize(p);
    return r;
}

// ---------------------------------------------------------------------------------------------
// Sizes and GEPs

recursive fn sc_get_size_of(int_ty: i32, t: i32) -> i32 {
    if ty_kind(t) == TK_SVEC {
        // getSizeOfExpr(IntTy, TypeSize): known minimum * vscale
        let r = sc_get_constant_ty(int_ty, dl_alloc_size(t) as u64, false);
        return sc_mul(r, sc_get_vscale(int_ty));
    }
    if sc_type_has_scalable(t) { fatal("ScalarEvolution: sizeof of an aggregate with scalable vectors is not ported"); }
    return sc_get_constant_ty(int_ty, dl_alloc_size(t) as u64, false);
}
recursive fn sc_get_store_size_of(int_ty: i32, t: i32) -> i32 {
    if ty_kind(t) == TK_SVEC {
        // getStoreSizeOfExpr -> getSizeOfExpr(IntTy, TypeSize): vscale * the known minimum store size
        let r = sc_get_constant_ty(int_ty, dl_store_size(t) as u64, false);
        return sc_mul(sc_get_vscale(int_ty), r);
    }
    if sc_type_has_scalable(t) { fatal("ScalarEvolution: store size of a scalable type is not ported"); }
    return sc_get_constant_ty(int_ty, dl_store_size(t) as u64, false);
}
recursive fn sc_type_has_scalable(t: i32) -> bool {
    let k = ty_kind(t);
    if k == TK_SVEC { return true; }
    if k == TK_ARRAY || k == TK_FVEC { return sc_type_has_scalable(ty_elem(t)); }
    if k == TK_STRUCT { for i in ty_count(t) { if sc_type_has_scalable(ty_field(t, i)) { return true; } } }
    return false;
}

// getGEPExpr(BaseExpr, IndexExprs, SrcElementTy, NW): indices = ss[b..]. nw: bit0 nusw, bit1 nuw (inbounds implies nusw)
recursive fn sc_get_gep_expr(base: i32, b: i64, src_ty: i32, nusw: bool, nuw: bool) -> i32 {
    var ow = SF_ANY;
    if nusw { ow |= SF_NSW; }
    if nuw { ow |= SF_NUW; }
    var cur = sc_ty(base);
    let idx_ty = sc_effective_ty(sc_ty(base));
    var first = true;
    let n = ss_n(b);
    let ob = ss.len;     // Offsets
    for k in n {
        let ie = ss[b + k];
        if ty_kind(cur) == TK_STRUCT {
            let fno = ap_lo64(sc_ap(ie)) as i64;
            ss.push(sc_get_constant_ty(idx_ty, dl_struct_offset(cur, fno) as u64, false));
            cur = ty_field(cur, fno);
        } else {
            if first { cur = src_ty; first = false; } else { cur = ty_elem(cur); }
            let es = sc_get_size_of(idx_ty, cur);
            let ie2 = sc_get_truncate_or_sign_extend(ie, idx_ty, 0);
            let lo = sc_mul2(ie2, es, ow, 0);
            ss.push(lo);
        }
    }
    if ss.len == ob { return ss_ret(b, base); }
    let off = sc_add_n(ob, ow, 0);
    let unw = nuw || (nusw && sc_is_known_non_negative(off));
    let r = sc_add2(base, off, if unw { SF_NUW } else { SF_ANY }, 0);
    return ss_ret(b, r);
}

// getNegativeSCEV
recursive fn sc_get_negative(v: i32, flags: u32) -> i32 {
    if sc_is_const(v) { return sc_get_constant(ap_neg(sc_ap(v))); }
    let t = sc_effective_ty(sc_ty(v));
    return sc_mul2(v, sc_get_minus_one(t), flags, 0);
}

// MatchNotExpr: (-1 + (-1 * X)) -> X
recursive fn sc_match_not_expr(e: i32) -> i32 {
    if sc_kind(e) == SC_ADD && sc_nops(e) == 2 && sc_is_all_ones(sc_op(e, 0)) {
        let m = sc_op(e, 1);
        if sc_kind(m) == SC_MUL && sc_nops(m) == 2 && sc_is_all_ones(sc_op(m, 0)) { return sc_op(m, 1); }
    }
    return -1;
}

recursive fn sc_get_not(v: i32) -> i32 {
    if sc_is_const(v) { return sc_get_constant(ap_not(sc_ap(v))); }
    if sc_is_minmax_kind(sc_kind(v)) {
        let b = ss.len;
        var ok = true;
        for k in sc_nops(v) {
            let m = sc_match_not_expr(sc_op(v, k));
            if m < 0 { ok = false; break; }
            ss.push(m);
        }
        if ok { return sc_minmax_n(sc_minmax_negate(sc_kind(v)), b); }
        ss.resize(b);
    }
    let t = sc_effective_ty(sc_ty(v));
    return sc_get_minus(sc_get_minus_one(t), v, SF_ANY, 0);
}

recursive fn sc_remove_pointer_base(p: i32) -> i32 {
    if sc_kind(p) == SC_ADDREC {
        let b = ss.len;
        ss_push_ops(p);
        let rpb = sc_remove_pointer_base(ss[b]);
        ss[b] = rpb;
        return sc_addrec_n(b, sc_loop(p), SF_ANY);
    }
    if sc_kind(p) == SC_ADD {
        let b = ss.len;
        ss_push_ops(p);
        for k in sc_nops(p) { if sc_is_ptr(ss[b + k]) { let rp = sc_remove_pointer_base(ss[b + k]); ss[b + k] = rp; break; } }
        return sc_add_n(b, SF_ANY, 0);
    }
    return sc_get_zero(sc_ty(p));
}

// getMinusSCEV
recursive fn sc_get_minus(l0: i32, r0: i32, flags: u32, depth: i64) -> i32 {
    var l = l0;
    var r = r0;
    if l == r { return sc_get_zero(sc_ty(l)); }
    if sc_is_ptr(r) {
        if !sc_is_ptr(l) || sc_get_pointer_base(l) != sc_get_pointer_base(r) { return SCEV_CNC; }
        l = sc_remove_pointer_base(l);
        r = sc_remove_pointer_base(r);
    }
    var af = SF_ANY;
    let not_min = !ap_is_min_signed(sc_get_signed_range_min(r));
    if (flags & SF_NSW) != 0 {
        if not_min || sc_is_known_non_negative(l) { af = SF_NSW; }
    }
    let nf = if not_min { SF_NSW } else { SF_ANY };
    return sc_add2(l, sc_get_negative(r, nf), af, depth);
}
recursive fn sc_minus(l: i32, r: i32) -> i32 { sc_get_minus(l, r, SF_ANY, 0) }

recursive fn sc_get_pointer_base(v0: i32) -> i32 {
    var v = v0;
    if !sc_is_ptr(v) { return v; }
    loop {
        if sc_kind(v) == SC_ADDREC { v = sc_op(v, 0); }
        else if sc_kind(v) == SC_ADD {
            var p: i32 = -1;
            for k in sc_nops(v) { if sc_is_ptr(sc_op(v, k)) { p = sc_op(v, k); } }
            v = p;
        } else { return v; }
    }
    return v;
}

recursive fn sc_get_truncate_or_zero_extend(v: i32, t: i32, depth: i64) -> i32 {
    let sb = sc_bits(v);
    let tb = sc_type_bits(t);
    if sb == tb { return v; }
    if sb > tb { return sc_get_truncate(v, t, depth); }
    return sc_get_zero_extend(v, t, depth);
}
recursive fn sc_get_truncate_or_sign_extend(v: i32, t: i32, depth: i64) -> i32 {
    let sb = sc_bits(v);
    let tb = sc_type_bits(t);
    if sb == tb { return v; }
    if sb > tb { return sc_get_truncate(v, t, depth); }
    return sc_get_sign_extend(v, t, depth);
}
recursive fn sc_get_noop_or_zero_extend(v: i32, t: i32) -> i32 { if sc_bits(v) == sc_type_bits(t) { v } else { sc_get_zero_extend(v, t, 0) } }
recursive fn sc_get_noop_or_sign_extend(v: i32, t: i32) -> i32 { if sc_bits(v) == sc_type_bits(t) { v } else { sc_get_sign_extend(v, t, 0) } }
recursive fn sc_get_noop_or_any_extend(v: i32, t: i32) -> i32 { if sc_bits(v) == sc_type_bits(t) { v } else { sc_get_any_extend(v, t) } }
recursive fn sc_get_truncate_or_noop(v: i32, t: i32) -> i32 { if sc_bits(v) == sc_type_bits(t) { v } else { sc_get_truncate(v, t, 0) } }

recursive fn sc_get_umax_from_mismatched(l: i32, r: i32) -> i32 {
    var pl = l;
    var pr = r;
    if sc_bits(l) > sc_bits(r) { pr = sc_get_zero_extend(r, sc_ty(l), 0); } else { pl = sc_get_noop_or_zero_extend(l, sc_ty(r)); }
    return sc_umax(pl, pr);
}
// getUMinFromMismatchedTypes(Ops = ss[b..], Sequential)
recursive fn sc_get_umin_from_mismatched_n(b: i64, seq: bool) -> i32 {
    if ss_n(b) == 1 { return ss_ret(b, ss[b]); }
    var mt = sc_ty(ss[b]);
    for k in 1..ss_n(b) { mt = sc_wider_ty(mt, sc_ty(ss[b + k])); }
    let pb = ss.len;
    for k in pb - b { let x = sc_get_noop_or_zero_extend(ss[b + k], mt); ss.push(x); }
    let r = sc_umin_n(pb, seq);
    return ss_ret(b, r);
}
recursive fn sc_get_umin_from_mismatched(l: i32, r: i32, seq: bool) -> i32 { let b = ss.len; ss.push(l); ss.push(r); return sc_get_umin_from_mismatched_n(b, seq); }

// ---------------------------------------------------------------------------------------------
// Casts

recursive fn sc_new_cast(kind: i64, o: i32, t: i32) -> i32 {
    let b = ss.len;
    ss.push(o);
    let s = sc_insert(kind, b, 1, -1, -1, t, 0);
    ss.resize(b);
    sc_register_users(s);
    return s;
}
recursive fn sc_find_cast(kind: i64, o: i32, t: i32) -> i32 { let b = ss.len; ss.push(o); let s = sc_find(kind, b, 1, -1, -1, t); ss.resize(b); return s; }

// getTruncateExpr
recursive fn sc_get_truncate(o: i32, t0: i32, depth: i64) -> i32 {
    let t = sc_effective_ty(t0);
    {
        let s = sc_find_cast(SC_TRUNC, o, t);
        if s >= 0 { return s; }
    }
    let k = sc_kind(o);
    if k == SC_CONST { return sc_get_constant(ap_trunc(sc_ap(o), ty_bits(t))); }
    if k == SC_TRUNC { return sc_get_truncate(sc_op(o, 0), t, depth + 1); }
    if k == SC_SEXT { return sc_get_truncate_or_sign_extend(sc_op(o, 0), t, depth + 1); }
    if k == SC_ZEXT { return sc_get_truncate_or_zero_extend(sc_op(o, 0), t, depth + 1); }
    if depth > sc_max_cast_depth { return sc_new_cast(SC_TRUNC, o, t); }
    if k == SC_ADD || k == SC_MUL {
        let b = ss.len;
        var ntr: i64 = 0;
        var i: i64 = 0;
        let e = sc_nops(o);
        while i != e && ntr < 2 {
            let x = sc_get_truncate(sc_op(o, i), t, depth + 1);
            if !sc_is_int_cast_kind(sc_kind(sc_op(o, i))) && sc_kind(x) == SC_TRUNC { ntr++; }
            ss.push(x);
            i++;
        }
        if ntr < 2 {
            if k == SC_ADD { return sc_add_n(b, SF_ANY, 0); }
            return sc_mul_n(b, SF_ANY, 0);
        }
        ss.resize(b);
        let s = sc_find_cast(SC_TRUNC, o, t);
        if s >= 0 { return s; }
    }
    if k == SC_ADDREC {
        let b = ss.len;
        for i in sc_nops(o) { let x = sc_get_truncate(sc_op(o, i), t, depth + 1); ss.push(x); }
        return sc_addrec_n(b, sc_loop(o), SF_ANY);
    }
    let mtz = sc_get_min_trailing_zeros(o);
    if mtz >= ty_bits(t) { return sc_get_zero(t); }
    return sc_new_cast(SC_TRUNC, o, t);
}

// getSignedOverflowLimitForStep / getUnsignedOverflowLimitForStep: (limit or -1, predicate)
recursive fn sc_overflow_limit_for_step(step: i32, signed: bool) -> i32, i64 {
    let bw = sc_bits(step);
    if signed {
        if sc_is_known_positive(step) { return sc_get_constant(ap_sub(ap_smin_val(bw), sc_get_signed_range_max(step))), P_SLT; }
        if sc_is_known_negative(step) { return sc_get_constant(ap_sub(ap_smax_val(bw), sc_get_signed_range_min(step))), P_SGT; }
        return -1, 0;
    }
    return sc_get_constant(ap_sub(ap_zero(bw), sc_get_unsigned_range_max(step))), P_ULT;
}

recursive fn sc_get_extend(o: i32, t: i32, depth: i64, signed: bool) -> i32 {
    if signed { return sc_get_sign_extend(o, t, depth); }
    return sc_get_zero_extend(o, t, depth);
}

// getPreStartForExtend
recursive fn sc_get_pre_start_for_extend(ar: i32, t: i32, depth: i64, signed: bool) -> i32 {
    let wrap = if signed { SF_NSW } else { SF_NUW };
    let l = sc_loop(ar);
    let start = sc_op(ar, 0);
    let step = sc_get_step_recurrence(ar);
    if sc_kind(start) != SC_ADD { return -1; }
    let sa = start;
    let b = ss.len;
    ss_push_ops(sa);
    for k in sc_nops(sa) { if ss[b + k] == step { ss_erase(b, k); break; } }
    if ss_n(b) == sc_nops(sa) { ss.resize(b); return -1; }
    let psf = sc_flags(sa) & SF_NUW;
    let pre_start = sc_add_n(b, psf, 0);
    let pre_ar0 = sc_addrec2(pre_start, step, l, SF_ANY);
    let pre_ar = if sc_kind(pre_ar0) == SC_ADDREC { pre_ar0 } else { -1 };
    let be = sc_get_backedge_taken_count(l, BTC_EXACT);
    if pre_ar >= 0 && (sc_flags(pre_ar) & wrap) != 0 && !sc_is_cnc(be) && sc_is_known_positive(be) { return pre_start; }
    let bw = sc_bits(ar);
    let wide = ty_int(bw * 2);
    let oes = sc_add(sc_get_extend(pre_start, wide, depth, signed), sc_get_extend(step, wide, depth, signed));
    if sc_get_extend(start, wide, depth, signed) == oes {
        if pre_ar >= 0 && (sc_flags(ar) & wrap) != 0 { sc_set_nowrap_flags(pre_ar, wrap); }
        return pre_start;
    }
    let lim, pred = sc_overflow_limit_for_step(step, signed);
    if lim >= 0 && sc_is_loop_entry_guarded_by_cond(l, pred, pre_start, lim) { return pre_start; }
    return -1;
}

// getExtendAddRecStart
recursive fn sc_get_extend_addrec_start(ar: i32, t: i32, depth: i64, signed: bool) -> i32 {
    let ps = sc_get_pre_start_for_extend(ar, t, depth, signed);
    if ps < 0 { return sc_get_extend(sc_op(ar, 0), t, depth, signed); }
    return sc_add(sc_get_extend(sc_get_step_recurrence(ar), t, depth, signed), sc_get_extend(ps, t, depth, signed));
}

// proveNoWrapByVaryingStart
recursive fn sc_prove_no_wrap_by_varying_start(start: i32, step: i32, l: i32, signed: bool) -> bool {
    let wrap = if signed { SF_NSW } else { SF_NUW };
    if !sc_is_const(start) { return false; }
    let sai = sc_ap(start);
    let deltas: i64[4] = [-2, -1, 1, 2];
    for d in deltas {
        // StartAI - Delta with Delta an unsigned (32-bit) value
        let dap = ap_zext_or_trunc(ap_u64((d as! u64) & 0xFFFFFFFF, 32), sai.w as i64);
        let pre = sc_get_constant(ap_sub(sai, dap));
        let b = ss.len;
        ss.push(pre);
        ss.push(step);
        let par = sc_find(SC_ADDREC, b, 2, -1, l, -1);
        ss.resize(b);
        if par >= 0 && (sc_flags(par) & wrap) != 0 {
            let ds = sc_get_constant_ty(sc_ty(start), (d as! u64) & 0xFFFFFFFF, false);
            let lim, pred = sc_overflow_limit_for_step(ds, signed);
            if lim >= 0 && sc_is_known_predicate(pred, par, lim) { return true; }
        }
    }
    return false;
}

// extractConstantWithoutWrapping(SE, ConstantTerm, WholeAddExpr)
recursive fn sc_extract_const_without_wrapping_add(c: AP, add: i32) -> AP {
    let bw = c.w as i64;
    var tz = bw;
    var i: i64 = 1;
    while i < sc_nops(add) && tz != 0 {
        let m = sc_get_min_trailing_zeros(sc_op(add, i));
        if m < tz { tz = m; }
        i++;
    }
    if tz != 0 { return if tz < bw { ap_zext(ap_trunc(c, tz), bw) } else { c }; }
    return ap_zero(bw);
}
recursive fn sc_extract_const_without_wrapping_step(c: AP, step: i32) -> AP {
    let bw = c.w as i64;
    let tz = sc_get_min_trailing_zeros(step);
    if tz != 0 { return if tz < bw { ap_zext(ap_trunc(c, tz), bw) } else { c }; }
    return ap_zero(bw);
}

// insertFoldCacheEntry. FoldCacheUser (forgetMemoizedResults erases the entries whose value is forgotten) is
// the value's generation stored with the entry: an entry is valid only while it matches.
recursive fn sc_fold_insert(kind: i64, o: i32, t: i32, s: i32) { hm_put(sc_fold, sc_fold_key(kind, o, t), (s as i64) | ((sc_gen(s) as i64) << 32)); }
recursive fn sc_fold_lookup(kind: i64, o: i32, t: i32) -> i32 {
    let key = sc_fold_key(kind, o, t);
    let c = hm_get(sc_fold, key, -1);
    if c < 0 { return -1; }
    let s = (c & 0xFFFFFFFF) as i32;
    if (c >> 32) as i32 != sc_gen(s) { hm_del(sc_fold, key); return -1; }
    return s;
}

recursive fn sc_get_zero_extend(o: i32, t0: i32, depth: i64) -> i32 {
    let t = sc_effective_ty(t0);
    let c = sc_fold_lookup(SC_ZEXT, o, t);
    if c >= 0 { return c; }
    let s = sc_get_zero_extend_impl(o, t, depth);
    if sc_kind(s) != SC_ZEXT { sc_fold_insert(SC_ZEXT, o, t, s); }
    return s;
}

recursive fn sc_get_zero_extend_impl(o: i32, t: i32, depth: i64) -> i32 {
    let k = sc_kind(o);
    if k == SC_CONST { return sc_get_constant(ap_zext(sc_ap(o), ty_bits(t))); }
    if k == SC_ZEXT { return sc_get_zero_extend(sc_op(o, 0), t, depth + 1); }
    {
        let s = sc_find_cast(SC_ZEXT, o, t);
        if s >= 0 { return s; }
    }
    if depth > sc_max_cast_depth { return sc_new_cast(SC_ZEXT, o, t); }
    if k == SC_TRUNC {
        let x = sc_op(o, 0);
        let cr = sc_get_unsigned_range(x);
        let tbits = sc_bits(o);
        let nbits = ty_bits(t);
        if rg_contains(rg_zext(rg_truncate(cr, tbits), nbits), rg_zext_or_trunc(cr, nbits)) {
            return sc_get_truncate_or_zero_extend(x, t, depth);
        }
    }
    if k == SC_ADDREC && sc_is_affine(o) {
        let ar = o;
        var start = sc_op(ar, 0);
        var step = sc_get_step_recurrence(ar);
        let bw = sc_bits(ar);
        let l = sc_loop(ar);
        if sc_has_nuw(ar) {
            start = sc_get_extend_addrec_start(ar, t, depth + 1, false);
            step = sc_get_zero_extend(step, t, depth + 1);
            return sc_addrec2(start, step, l, sc_flags(ar));
        }
        let maxbe = sc_get_constant_max_backedge_taken_count(l);
        if !sc_is_cnc(maxbe) {
            let casted = sc_get_truncate_or_zero_extend(maxbe, sc_ty(start), depth);
            let recasted = sc_get_truncate_or_zero_extend(casted, sc_ty(maxbe), depth);
            if maxbe == recasted {
                let wide = ty_int(bw * 2);
                let zmul = sc_mul2(casted, step, SF_ANY, depth + 1);
                let zadd = sc_get_zero_extend(sc_add2(start, zmul, SF_ANY, depth + 1), wide, depth + 1);
                let wstart = sc_get_zero_extend(start, wide, depth + 1);
                let wmax = sc_get_zero_extend(casted, wide, depth + 1);
                var oea = sc_add2(wstart, sc_mul2(wmax, sc_get_zero_extend(step, wide, depth + 1), SF_ANY, depth + 1), SF_ANY, depth + 1);
                if zadd == oea {
                    sc_set_nowrap_flags(ar, SF_NUW);
                    start = sc_get_extend_addrec_start(ar, t, depth + 1, false);
                    step = sc_get_zero_extend(step, t, depth + 1);
                    return sc_addrec2(start, step, l, sc_flags(ar));
                }
                oea = sc_add2(wstart, sc_mul2(wmax, sc_get_sign_extend(step, wide, depth + 1), SF_ANY, depth + 1), SF_ANY, depth + 1);
                if zadd == oea {
                    sc_set_nowrap_flags(ar, SF_NW);
                    start = sc_get_extend_addrec_start(ar, t, depth + 1, false);
                    step = sc_get_sign_extend(step, t, depth + 1);
                    return sc_addrec2(start, step, l, sc_flags(ar));
                }
            }
        }
        if !sc_is_cnc(maxbe) || sc_has_guards || sc_has_assumptions() {
            let nf = sc_prove_no_unsigned_wrap_via_induction(ar);
            sc_set_nowrap_flags(ar, nf);
            if sc_has_nuw(ar) {
                start = sc_get_extend_addrec_start(ar, t, depth + 1, false);
                step = sc_get_zero_extend(step, t, depth + 1);
                return sc_addrec2(start, step, l, sc_flags(ar));
            }
            if sc_is_known_negative(step) {
                let n = sc_get_constant(ap_sub(ap_ones(bw), sc_get_signed_range_min(step)));
                if sc_is_loop_backedge_guarded_by_cond(l, P_UGT, ar, n) || sc_is_known_on_every_iteration(P_UGT, ar, n) {
                    sc_set_nowrap_flags(ar, SF_NW);
                    start = sc_get_extend_addrec_start(ar, t, depth + 1, false);
                    step = sc_get_sign_extend(step, t, depth + 1);
                    return sc_addrec2(start, step, l, sc_flags(ar));
                }
            }
        }
        if sc_is_const(start) {
            let c = sc_ap(start);
            let d = sc_extract_const_without_wrapping_step(c, step);
            if !ap_is_zero(d) {
                let szd = sc_get_zero_extend(sc_get_constant(d), t, depth);
                let sres = sc_addrec2(sc_get_constant(ap_sub(c, d)), step, l, sc_flags(ar));
                let szr = sc_get_zero_extend(sres, t, depth + 1);
                return sc_add2(szd, szr, SF_NSW | SF_NUW, depth + 1);
            }
        }
        if sc_prove_no_wrap_by_varying_start(start, step, l, false) {
            sc_set_nowrap_flags(ar, SF_NUW);
            start = sc_get_extend_addrec_start(ar, t, depth + 1, false);
            step = sc_get_zero_extend(step, t, depth + 1);
            return sc_addrec2(start, step, l, sc_flags(ar));
        }
    }
    {
        let x, y, ok = sc_match_urem(o);
        if ok { return sc_get_urem(sc_get_zero_extend(x, t, depth + 1), sc_get_zero_extend(y, t, depth + 1)); }
    }
    if k == SC_UDIV { return sc_get_udiv(sc_get_zero_extend(sc_op(o, 0), t, depth + 1), sc_get_zero_extend(sc_op(o, 1), t, depth + 1)); }
    if k == SC_ADD {
        let sa = o;
        if sc_has_nuw(sa) {
            let b = ss.len;
            for i in sc_nops(sa) { let x = sc_get_zero_extend(sc_op(sa, i), t, depth + 1); ss.push(x); }
            return sc_add_n(b, SF_NUW, depth + 1);
        }
        // zext((-C) + (C2 smax X))<nsw> with C2 >= |C| -> sext of both
        if sc_has_nsw(sa) && sc_nops(sa) == 2 && sc_is_const(sc_op(sa, 0)) {
            let sm = sc_op(sa, 1);
            if sc_kind(sm) == SC_SMAX && sc_nops(sm) == 2 && sc_is_const(sc_op(sm, 0)) {
                let c = sc_ap(sc_op(sa, 0));
                let c2 = sc_ap(sc_op(sm, 0));
                if ap_is_neg(c) && !ap_is_min_signed(c) && ap_sge(c2, ap_abs(c)) {
                    return sc_add2(sc_get_sign_extend(sc_op(sa, 0), t, depth + 1), sc_get_sign_extend(sc_op(sa, 1), t, depth + 1), SF_NSW, depth + 1);
                }
            }
        }
        if sc_is_const(sc_op(sa, 0)) {
            let d = sc_extract_const_without_wrapping_add(sc_ap(sc_op(sa, 0)), sa);
            if !ap_is_zero(d) {
                let szd = sc_get_zero_extend(sc_get_constant(d), t, depth);
                let sres = sc_add2(sc_get_constant(ap_neg(d)), sa, SF_ANY, depth);
                let szr = sc_get_zero_extend(sres, t, depth + 1);
                return sc_add2(szd, szr, SF_NSW | SF_NUW, depth + 1);
            }
        }
    }
    if k == SC_MUL {
        let sm = o;
        if sc_has_nuw(sm) {
            let b = ss.len;
            for i in sc_nops(sm) { let x = sc_get_zero_extend(sc_op(sm, i), t, depth + 1); ss.push(x); }
            return sc_mul_n(b, SF_NUW, depth + 1);
        }
        if sc_nops(sm) == 2 && sc_is_const(sc_op(sm, 0)) && sc_kind(sc_op(sm, 1)) == SC_TRUNC && ap_is_pow2(sc_ap(sc_op(sm, 0))) {
            let nb = sc_bits(sc_op(sm, 1)) - ap_log2(sc_ap(sc_op(sm, 0)));
            let ntt = ty_int(nb);
            return sc_mul2(sc_get_zero_extend(sc_op(sm, 0), t, 0), sc_get_zero_extend(sc_get_truncate(sc_op(sc_op(sm, 1), 0), ntt, 0), t, 0), SF_NUW, depth + 1);
        }
    }
    if k == SC_UMIN || k == SC_UMAX {
        let b = ss.len;
        for i in sc_nops(o) { let x = sc_get_zero_extend(sc_op(o, i), t, 0); ss.push(x); }
        if k == SC_UMIN { return sc_minmax_n(SC_UMIN, b); }
        return sc_minmax_n(SC_UMAX, b);
    }
    if k == SC_SEQUMIN {
        let b = ss.len;
        for i in sc_nops(o) { let x = sc_get_zero_extend(sc_op(o, i), t, 0); ss.push(x); }
        return sc_seq_minmax_n(SC_SEQUMIN, b);
    }
    {
        let s = sc_find_cast(SC_ZEXT, o, t);
        if s >= 0 { return s; }
    }
    return sc_new_cast(SC_ZEXT, o, t);
}

recursive fn sc_get_sign_extend(o: i32, t0: i32, depth: i64) -> i32 {
    let t = sc_effective_ty(t0);
    let c = sc_fold_lookup(SC_SEXT, o, t);
    if c >= 0 { return c; }
    let s = sc_get_sign_extend_impl(o, t, depth);
    if sc_kind(s) != SC_SEXT { sc_fold_insert(SC_SEXT, o, t, s); }
    return s;
}

recursive fn sc_get_sign_extend_impl(o: i32, t: i32, depth: i64) -> i32 {
    let k = sc_kind(o);
    if k == SC_CONST { return sc_get_constant(ap_sext(sc_ap(o), ty_bits(t))); }
    if k == SC_SEXT { return sc_get_sign_extend(sc_op(o, 0), t, depth + 1); }
    if k == SC_ZEXT { return sc_get_zero_extend(sc_op(o, 0), t, depth + 1); }
    {
        let s = sc_find_cast(SC_SEXT, o, t);
        if s >= 0 { return s; }
    }
    if depth > sc_max_cast_depth { return sc_new_cast(SC_SEXT, o, t); }
    if k == SC_TRUNC {
        let x = sc_op(o, 0);
        let cr = sc_get_signed_range(x);
        let tbits = sc_bits(o);
        let nbits = ty_bits(t);
        if rg_contains(rg_sext(rg_truncate(cr, tbits), nbits), rg_sext_or_trunc(cr, nbits)) {
            return sc_get_truncate_or_sign_extend(x, t, depth);
        }
    }
    if k == SC_ADD {
        let sa = o;
        if sc_has_nsw(sa) {
            let b = ss.len;
            for i in sc_nops(sa) { let x = sc_get_sign_extend(sc_op(sa, i), t, depth + 1); ss.push(x); }
            return sc_add_n(b, SF_NSW, depth + 1);
        }
        if sc_is_const(sc_op(sa, 0)) {
            let d = sc_extract_const_without_wrapping_add(sc_ap(sc_op(sa, 0)), sa);
            if !ap_is_zero(d) {
                let ssd = sc_get_sign_extend(sc_get_constant(d), t, depth);
                let sres = sc_add2(sc_get_constant(ap_neg(d)), sa, SF_ANY, depth);
                let ssr = sc_get_sign_extend(sres, t, depth + 1);
                return sc_add2(ssd, ssr, SF_NSW | SF_NUW, depth + 1);
            }
        }
    }
    if k == SC_ADDREC && sc_is_affine(o) {
        let ar = o;
        var start = sc_op(ar, 0);
        var step = sc_get_step_recurrence(ar);
        let bw = sc_bits(ar);
        let l = sc_loop(ar);
        if sc_has_nsw(ar) {
            start = sc_get_extend_addrec_start(ar, t, depth + 1, true);
            step = sc_get_sign_extend(step, t, depth + 1);
            return sc_addrec2(start, step, l, SF_NSW);
        }
        let maxbe = sc_get_constant_max_backedge_taken_count(l);
        if !sc_is_cnc(maxbe) {
            let casted = sc_get_truncate_or_zero_extend(maxbe, sc_ty(start), depth);
            let recasted = sc_get_truncate_or_zero_extend(casted, sc_ty(maxbe), depth);
            if maxbe == recasted {
                let wide = ty_int(bw * 2);
                let smul = sc_mul2(casted, step, SF_ANY, depth + 1);
                let sadd = sc_get_sign_extend(sc_add2(start, smul, SF_ANY, depth + 1), wide, depth + 1);
                let wstart = sc_get_sign_extend(start, wide, depth + 1);
                let wmax = sc_get_zero_extend(casted, wide, depth + 1);
                var oea = sc_add2(wstart, sc_mul2(wmax, sc_get_sign_extend(step, wide, depth + 1), SF_ANY, depth + 1), SF_ANY, depth + 1);
                if sadd == oea {
                    sc_set_nowrap_flags(ar, SF_NSW);
                    start = sc_get_extend_addrec_start(ar, t, depth + 1, true);
                    step = sc_get_sign_extend(step, t, depth + 1);
                    return sc_addrec2(start, step, l, sc_flags(ar));
                }
                oea = sc_add2(wstart, sc_mul2(wmax, sc_get_zero_extend(step, wide, depth + 1), SF_ANY, depth + 1), SF_ANY, depth + 1);
                if sadd == oea {
                    sc_set_nowrap_flags(ar, SF_NW);
                    start = sc_get_extend_addrec_start(ar, t, depth + 1, true);
                    step = sc_get_zero_extend(step, t, depth + 1);
                    return sc_addrec2(start, step, l, sc_flags(ar));
                }
            }
        }
        let nf = sc_prove_no_signed_wrap_via_induction(ar);
        sc_set_nowrap_flags(ar, nf);
        if sc_has_nsw(ar) {
            start = sc_get_extend_addrec_start(ar, t, depth + 1, true);
            step = sc_get_sign_extend(step, t, depth + 1);
            return sc_addrec2(start, step, l, sc_flags(ar));
        }
        if sc_is_const(start) {
            let c = sc_ap(start);
            let d = sc_extract_const_without_wrapping_step(c, step);
            if !ap_is_zero(d) {
                let ssd = sc_get_sign_extend(sc_get_constant(d), t, depth);
                let sres = sc_addrec2(sc_get_constant(ap_sub(c, d)), step, l, sc_flags(ar));
                let ssr = sc_get_sign_extend(sres, t, depth + 1);
                return sc_add2(ssd, ssr, SF_NSW | SF_NUW, depth + 1);
            }
        }
        if sc_prove_no_wrap_by_varying_start(start, step, l, true) {
            sc_set_nowrap_flags(ar, SF_NSW);
            start = sc_get_extend_addrec_start(ar, t, depth + 1, true);
            step = sc_get_sign_extend(step, t, depth + 1);
            return sc_addrec2(start, step, l, sc_flags(ar));
        }
    }
    if sc_is_known_non_negative(o) { return sc_get_zero_extend(o, t, depth + 1); }
    if k == SC_SMIN || k == SC_SMAX {
        let b = ss.len;
        for i in sc_nops(o) { let x = sc_get_sign_extend(sc_op(o, i), t, 0); ss.push(x); }
        if k == SC_SMIN { return sc_minmax_n(SC_SMIN, b); }
        return sc_minmax_n(SC_SMAX, b);
    }
    {
        let s = sc_find_cast(SC_SEXT, o, t);
        if s >= 0 { return s; }
    }
    return sc_new_cast(SC_SEXT, o, t);
}

// getAnyExtendExpr
recursive fn sc_get_any_extend(o: i32, t0: i32) -> i32 {
    let t = sc_effective_ty(t0);
    if sc_is_const(o) && ap_is_neg(sc_ap(o)) { return sc_get_sign_extend(o, t, 0); }
    if sc_kind(o) == SC_TRUNC {
        let no = sc_op(o, 0);
        if sc_bits(no) < sc_type_bits(t) { return sc_get_any_extend(no, t); }
        return sc_get_truncate_or_noop(no, t);
    }
    let z = sc_get_zero_extend(o, t, 0);
    if sc_kind(z) != SC_ZEXT { return z; }
    let s = sc_get_sign_extend(o, t, 0);
    if sc_kind(s) != SC_SEXT { return s; }
    if sc_kind(o) == SC_ADDREC {
        let b = ss.len;
        for i in sc_nops(o) { let x = sc_get_any_extend(sc_op(o, i), t); ss.push(x); }
        return sc_addrec_n(b, sc_loop(o), SF_NW);
    }
    if sc_kind(o) == SC_SMAX { return s; }
    return z;
}

// SCEVCastSinkingRewriter + getLosslessPtrToIntExpr
recursive fn sc_cast_sink(s: i32, target: i32, addr: bool) -> i32 {
    if !sc_is_ptr(s) { return s; }
    let k = sc_kind(s);
    if k == SC_ADD || k == SC_MUL {
        let b = ss.len;
        var changed = false;
        for i in sc_nops(s) { let x = sc_cast_sink(sc_op(s, i), target, addr); ss.push(x); if x != sc_op(s, i) { changed = true; } }
        if !changed { ss.resize(b); return s; }
        if k == SC_ADD { return sc_add_n(b, sc_flags(s) & (SF_NUW | SF_NSW), 0); }
        return sc_mul_n(b, sc_flags(s) & (SF_NUW | SF_NSW), 0);
    }
    if k == SC_ADDREC {
        let b = ss.len;
        var changed = false;
        for i in sc_nops(s) { let x = sc_cast_sink(sc_op(s, i), target, addr); ss.push(x); if x != sc_op(s, i) { changed = true; } }
        if !changed { ss.resize(b); return s; }
        return sc_addrec_n(b, sc_loop(s), sc_flags(s));
    }
    if k == SC_UNKNOWN {
        if vals[sc_value(s)].kind as i64 == VK_CNULL { return sc_get_zero(target); }
        let kind = if addr { SC_PTRTOADDR } else { SC_PTRTOINT };
        let b = ss.len;
        ss.push(s);
        var r = sc_find(kind, b, 1, -1, -1, target);
        if r < 0 { r = sc_insert(kind, b, 1, -1, -1, target, 0); sc_register_users(r); }
        ss.resize(b);
        return r;
    }
    // SCEVRewriteVisitor for the other kinds: rebuild with rewritten operands
    if k == SC_UMAX || k == SC_SMAX || k == SC_UMIN || k == SC_SMIN || k == SC_SEQUMIN {
        let b = ss.len;
        var changed = false;
        for i in sc_nops(s) { let x = sc_cast_sink(sc_op(s, i), target, addr); ss.push(x); if x != sc_op(s, i) { changed = true; } }
        if !changed { ss.resize(b); return s; }
        if k == SC_SEQUMIN { return sc_seq_minmax_n(k, b); }
        return sc_minmax_n(k, b);
    }
    fatal("ScalarEvolution: SCEVCastSinkingRewriter case not ported");
    return s;
}

recursive fn sc_get_lossless_ptr_to_int(o: i32) -> i32 {
    let as_ = sc_ptr_as(sc_ty(o));
    if dl_is_nonintegral_as(as_) { return SCEV_CNC; }
    let ipt = sc_intptr_ty(sc_ty(o));
    if sc_type_bits(sc_effective_ty(sc_ty(o))) != ty_bits(ipt) { return SCEV_CNC; }
    return sc_cast_sink(o, ipt, false);
}
recursive fn sc_get_ptr_to_int(o: i32, t: i32) -> i32 {
    let io = sc_get_lossless_ptr_to_int(o);
    if sc_is_cnc(io) { return io; }
    return sc_get_truncate_or_zero_extend(io, t, 0);
}
recursive fn sc_get_ptr_to_addr(o: i32) -> i32 {
    if dl_has_unstable_repr(sc_ptr_as(sc_ty(o))) { return SCEV_CNC; }
    // DataLayout::getAddressType: the index type of the address space
    let t = ty_int(dl_ptr(sc_ptr_as(sc_ty(o))).idx);
    return sc_cast_sink(o, t, true);
}

// m_scev_URem(LHS, RHS) (SCEVURem_match in ScalarEvolutionPatternMatch.h; builds SCEVs like LLVM's)
recursive fn sc_match_urem(s: i32) -> i32, i32, bool {
    if sc_is_ptr(s) { return -1, -1, false; }
    if sc_kind(s) == SC_ZEXT && sc_kind(sc_op(s, 0)) == SC_TRUNC {
        let tr = sc_op(s, 0);
        var x = sc_op(tr, 0);
        if sc_bits(x) > sc_bits(s) { return -1, -1, false; }
        if sc_ty(x) != sc_ty(s) { x = sc_get_zero_extend(x, sc_ty(s), 0); }
        let r = sc_get_constant(ap_shl(ap_u64(1, sc_bits(s)), sc_bits(tr)));
        return x, r, true;
    }
    if sc_kind(s) != SC_ADD || sc_nops(s) != 2 || sc_kind(sc_op(s, 0)) != SC_MUL { return -1, -1, false; }
    let m = sc_op(s, 0);
    let a = sc_op(s, 1);
    if sc_nops(m) == 3 && sc_is_const(sc_op(m, 0)) {
        if s == sc_get_urem(a, sc_op(m, 1)) { return a, sc_op(m, 1), true; }
        if s == sc_get_urem(a, sc_op(m, 2)) { return a, sc_op(m, 2), true; }
        return -1, -1, false;
    }
    if sc_nops(m) == 2 {
        if s == sc_get_urem(a, sc_op(m, 1)) { return a, sc_op(m, 1), true; }
        if s == sc_get_urem(a, sc_op(m, 0)) { return a, sc_op(m, 0), true; }
        let n1 = sc_get_negative(sc_op(m, 1), SF_ANY);
        if s == sc_get_urem(a, n1) { return a, n1, true; }
        let n0 = sc_get_negative(sc_op(m, 0), SF_ANY);
        if s == sc_get_urem(a, n0) { return a, n0, true; }
    }
    return -1, -1, false;
}
