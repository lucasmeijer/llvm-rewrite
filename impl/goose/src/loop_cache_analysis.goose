// LoopCacheAnalysis: port of llvm/lib/Analysis/LoopCacheAnalysis.cpp (IndexedReference, CacheCost and the
// print<loop-cache-cost> printer). One CacheCost at a time: lcc_* globals. CacheCostTy (InstructionCost) is
// (valid, value) with LLVM's saturating int64 arithmetic. TTI::getCacheLineSize is 0 for NoTTI and X86 (no cache
// model in the X86 subtarget), unless -cache-line-size is given.
import std;
import ir;
import irutil;
import flags;
import apint;
import loopinfo;
import memloc;
import aa;
import scev;
import scev_create;
import scev_range;
import scev_btc;
import scev_pred;
import scev_eval;
import implied;
import delinearization;
import dependence_analysis;
import subtarget;

// InstructionCost: fixed point with CostGranularity 4 (`v` is the raw Value), saturating int64 arithmetic
struct LCost { ok: bool, v: i64 }
let LCC_MAX: i64 = 0x7fffffffffffffff;
let LCC_MIN: i64 = -0x7fffffffffffffff - 1;
fn lcc_mul_ov(a: i64, b: i64) -> i64, bool {
    let r, o = ap_smul_ov(ap_i64(a, 64), ap_i64(b, 64));
    return r.lo as! i64, o;
}
fn lcost(v: i64) -> LCost {
    let r, o = lcc_mul_ov(v, 4);
    if o { return LCost { ok: true, v: if v > 0 { LCC_MAX } else { LCC_MIN } }; }
    return LCost { ok: true, v: r };
}
fn lcost_invalid() -> LCost { LCost { ok: false, v: 0 } }
fn lcost_add(a: LCost, b: LCost) -> LCost {
    var v: i64 = 0;
    if b.v > 0 && a.v > LCC_MAX - b.v { v = LCC_MAX; }
    else if b.v < 0 && a.v < LCC_MIN - b.v { v = LCC_MIN; }
    else { v = a.v + b.v; }
    return LCost { ok: a.ok && b.ok, v: v };
}
fn lcost_mul(a: LCost, b: LCost) -> LCost {
    let r, o = lcc_mul_ov(a.v, b.v);
    var v: i64 = 0;
    if o { v = if (a.v > 0 && b.v > 0) || (a.v < 0 && b.v < 0) { LCC_MAX } else { LCC_MIN }; }
    else { v = r / 4; }
    return LCost { ok: a.ok && b.ok, v: v };
}
// InstructionCost::operator< / ==
fn lcost_lt(a: LCost, b: LCost) -> bool {
    if a.ok != b.ok { return a.ok; }
    return a.v < b.v;
}
fn lcost_eq(a: LCost, b: LCost) -> bool { a.ok == b.ok && a.v == b.v }
// InstructionCost::print
fn lcost_print(c: LCost) {
    if !c.ok { errs("Invalid"); return; }
    let neg = c.v < 0;
    let abs: u64 = if neg { (0 as u64) - (c.v as! u64) } else { c.v as! u64 };
    let whole = abs / 4;
    let rem = abs % 4;
    if neg { errs("-"); }
    var h = (rem * 100) / 4;
    while h % 10 == 0 && h != 0 { h = h / 10; }
    errs_u64(whole);
    if h != 0 { errs("."); errs_u64(h); }
}

fn lc_cache_line_size() -> i64 { if flag_given("cache-line-size") { flag_int("cache-line-size", 0) } else { 0 } }

// IndexedReference rows; subscripts / sizes are runs in lir_pool
struct LIRef { inst: i32, valid: bool, base: i32, sub_at: i32, sub_n: i32, size_at: i32, size_n: i32 }
var lir: LIRef[>..<];
var lir_pool: i32[>..<];
fn lir_sub(r: i64, k: i64) -> i32 { lir_pool[(lir[r].sub_at as i64) + k] }
fn lir_nsub(r: i64) -> i64 { lir[r].sub_n as i64 }
fn lir_size_back(r: i64) -> i32 { lir_pool[(lir[r].size_at as i64) + (lir[r].size_n as i64) - 1] }
fn lc_ptr_operand(i: i32) -> i32 { if iop(i) == OP_STORE { op(i, 1) } else { op(i, 0) } }

// isOneDimensionalArray
fn lc_is_one_dimensional_array(afn: i32, es: i32, l: i32) -> bool {
    if sc_kind(afn) != SC_ADDREC || !sc_is_affine(afn) { return false; }
    let start = sc_op(afn, 0);
    let step = sc_get_step_recurrence(afn);
    if sc_kind(start) == SC_ADDREC || sc_kind(step) == SC_ADDREC { return false; }
    if !sc_is_loop_invariant(start, l) || !sc_is_loop_invariant(step, l) { return false; }
    var sr = sc_get_step_recurrence(afn);
    if sc_is_known_negative(sr) { sr = sc_get_negative(sr, SF_ANY); }
    return sr == es;
}

// computeTripCount
fn lc_compute_trip_count(l: i32, es: i32) -> i32 {
    let btc = sc_get_backedge_taken_count(l, BTC_EXACT);
    if !sc_is_cnc(btc) && sc_kind(btc) == SC_CONST { return sc_trip_count_from_exit_count(btc); }
    return sc_get_constant_ty(sc_ty(es), flag_int("default-trip-count", 100) as u64, false);
}

// isSimpleAddRecurrence
fn lc_is_simple_add_recurrence(s: i32, l: i32) -> bool {
    if sc_kind(s) != SC_ADDREC { return false; }
    if !sc_is_affine(s) { return false; }
    return sc_is_loop_invariant(sc_op(s, 0), l) && sc_is_loop_invariant(sc_get_step_recurrence(s), l);
}

// IndexedReference(I, LI, SE) with delinearize(LI)
fn lir_new(i: i32) -> i64 {
    lir.push(LIRef { inst: i, valid: false, base: -1, sub_at: 0, sub_n: 0, size_at: 0, size_n: 0 });
    let r = lir.len - 1;
    let es = sc_get_element_size(i);
    let l = li_loop_for(inst_parent(i));
    if l < 0 { return r; }
    var afn = sc_get_scev_at_scope(sc_get_scev(lc_ptr_operand(i)), l);
    let base = sc_get_pointer_base(afn);
    if sc_kind(base) != SC_UNKNOWN { return r; }
    lir[r].base = base;
    afn = sc_minus(afn, base);
    var subs: i32[>..<] = [];
    var sizes: i32[>..<] = [];
    var fixed = false;
    if dl_delinearize_fixed_size_array(afn, subs, sizes, es) { fixed = true; }
    if !fixed {
        sizes.clear();
        dl_delinearize(afn, subs, sizes, sc_get_element_size(i));
    }
    if subs.len == 0 || sizes.len == 0 || subs.len != sizes.len {
        if !lc_is_one_dimensional_array(afn, es, l) { return r; }
        var a = afn;
        let sr = if sc_kind(afn) == SC_ADDREC { sc_get_step_recurrence(afn) } else { -1 };
        if sr >= 0 && sc_is_known_negative(sr) { a = sc_addrec2(sc_op(afn, 0), sc_get_negative(sr, SF_ANY), sc_loop(afn), SF_ANY); }
        subs.push(sc_get_udiv(a, es));
        sizes.push(es);
    }
    lir[r].sub_at = lir_pool.len as i32;
    for s in subs { lir_pool.push(s); }
    lir[r].sub_n = subs.len as i32;
    lir[r].size_at = lir_pool.len as i32;
    for s in sizes { lir_pool.push(s); }
    lir[r].size_n = sizes.len as i32;
    var all = true;
    for s in subs { if !lc_is_simple_add_recurrence(s, l) { all = false; } }
    lir[r].valid = all;
    return r;
}

fn lir_is_aliased(a: i64, b: i64) -> bool {
    let q = aq_push(CA_SIMPLE);
    let x = aa_alias(ml_get(lir[a].inst), ml_get(lir[b].inst), q, -1);
    aq_pop(q);
    return x.k == AR_MUST as u8;
}

// hasSpacialReuse: -1 = nullopt
fn lir_has_spacial_reuse(a: i64, b: i64, cls: i64) -> i64 {
    if lir[a].base != lir[b].base && !lir_is_aliased(a, b) { return 0; }
    let n = lir_nsub(a);
    if n != lir_nsub(b) { return 0; }
    for k in 0..n - 1 { if lir_sub(a, k) != lir_sub(b, k) { return 0; } }
    let d = sc_minus(lir_sub(a, n - 1), lir_sub(b, n - 1));
    if sc_kind(d) != SC_CONST { return -1; }
    let dv = ap_sext(sc_ap(d), 64).lo as! i64;
    return if dv < cls { 1 } else { 0 };
}

// hasTemporalReuse
fn lir_has_temporal_reuse(a: i64, b: i64, max_dist: i64, l: i32) -> i64 {
    if lir[a].base != lir[b].base && !lir_is_aliased(a, b) { return 0; }
    da_depends(lir[a].inst, lir[b].inst, false);
    if da_res_kind == 0 { return 0; }
    if da_res_li { return 1; }
    let depth = loop_depth(l);
    let levels = if da_res_kind == 2 { da_res_levels } else { 0 };
    for level in 1..levels + 1 {
        let dist = da_distance(level);
        if dist < 0 || sc_kind(dist) != SC_CONST { return -1; }
        let cv = sc_ap(dist);
        if level != depth && !ap_is_zero(cv) { return 0; }
        if level == depth && (ap_sext(cv, 64).lo as! i64) > max_dist { return 0; }
    }
    return 1;
}

fn lir_coeff_zero_or_invariant(s: i32, l: i32) -> bool {
    if sc_kind(s) == SC_ADDREC { return sc_loop(s) != l; }
    return sc_is_loop_invariant(s, l);
}

// computeRefCost(L, CLS)
fn lir_compute_ref_cost(r: i64, l: i32, cls: i64) -> LCost {
    // isLoopInvariant(L)
    if sc_is_loop_invariant(sc_get_scev(lc_ptr_operand(lir[r].inst)), l) { return lcost(1); }
    var inv = true;
    for k in lir_nsub(r) { if !lir_coeff_zero_or_invariant(lir_sub(r, k), l) { inv = false; } }
    if inv { return lcost(1); }
    var tc = lc_compute_trip_count(l, lir_size_back(r));
    var cost: i32 = -1;
    // isConsecutive(L, Stride, CLS)
    let n = lir_nsub(r);
    let last = lir_sub(r, n - 1);
    var consecutive = true;
    for k in n { let s = lir_sub(r, k); if s == last { continue; } if !lir_coeff_zero_or_invariant(s, l) { consecutive = false; } }
    var stride: i32 = -1;
    if consecutive {
        let coeff = sc_get_step_recurrence(last);
        let es = lir_size_back(r);
        let wt = sc_get_wider_type(sc_ty(coeff), sc_ty(es));
        stride = sc_mul(sc_get_noop_or_sign_extend(coeff, wt), sc_get_noop_or_sign_extend(es, wt));
        let cl = sc_get_constant_ty(sc_ty(stride), cls as u64, false);
        if sc_is_known_negative(stride) { stride = sc_get_negative(stride, SF_ANY); }
        consecutive = sc_is_known_predicate(P_ULT, stride, cl);
    }
    if consecutive {
        let wt = sc_get_wider_type(sc_ty(stride), sc_ty(tc));
        let cl = sc_get_constant_ty(wt, cls as u64, false);
        stride = sc_get_noop_or_any_extend(stride, wt);
        tc = sc_get_noop_or_zero_extend(tc, wt);
        cost = sc_get_udiv_ceil(sc_mul(stride, tc), cl);
    } else {
        cost = tc;
        var idx: i64 = -1;
        for k in n { let s = lir_sub(r, k); if sc_kind(s) == SC_ADDREC && sc_loop(s) == l { idx = k; break; } }
        if idx < 0 { fatal("internal: loop cache analysis: no subscript for the loop"); }
        var i = idx + 1;
        while i < n - 1 {
            let ar = lir_sub(r, i);
            let tc2 = lc_compute_trip_count(sc_loop(ar), lir_size_back(r));
            var wt = sc_get_wider_type(sc_ty(cost), sc_ty(tc2));
            wt = ty_int(ty_bits(wt) * 2);
            cost = sc_mul(sc_get_noop_or_zero_extend(cost, wt), sc_get_noop_or_zero_extend(tc2, wt));
            i++;
        }
    }
    if sc_kind(cost) == SC_CONST {
        let a = sc_ap(cost);
        if ap_active_bits(a) > 63 { return lcost(LCC_MAX); }   // getLimitedValue(INT64_MAX)
        return lcost(a.lo as! i64);
    }
    return lcost_invalid();
}

// CacheCost results: loops in getLoopCosts() order with their costs
var lcc_loops: i32[>..<];
var lcc_costs: LCost[>..<];
var lcc_valid: bool = false;       // the unique_ptr is non-null

// getCacheCostImpl(Root, ...) + CacheCost(Loops, ...)
fn lcc_compute(root: i32) {
    lcc_loops.clear();
    lcc_costs.clear();
    lcc_valid = false;
    if loop_parent(root) >= 0 { return; }
    var loops: i32[>..<] = [];
    loops.push(root);
    var k: i64 = 0;
    while k < loops.len { let x = loops[k]; for s in loop_nsubs(x) { loops.push(loop_sub(x, s)); } k++; }
    // getInnerMostLoop: breadth-first order is sorted by depth
    let inner = loops[loops.len - 1];
    lcc_valid = true;
    var tcs: i64[>..<] = [];
    for l in loops { var t = sc_get_small_constant_trip_count(l); if t == 0 { t = flag_int("default-trip-count", 100); } tcs.push(t); }
    // populateReferenceGroups: groups are runs of reference rows (gfirst = representative)
    let cls = lc_cache_line_size();
    let trt = flag_int("temporal-reuse-threshold", 2);
    lir.clear(); lir_pool.clear();
    var greps: i64[>..<] = [];
    for b in loop_nblocks(inner) {
        var i = block_first(loop_block(inner, b));
        while i >= 0 {
            if iop(i) == OP_STORE || iop(i) == OP_LOAD {
                let r = lir_new(i);
                if lir[r].valid {
                    var added = false;
                    for g in greps {
                        let t = lir_has_temporal_reuse(r, g, trt, inner);
                        let s = lir_has_spacial_reuse(r, g, cls);
                        if t == 1 || s == 1 { added = true; break; }
                    }
                    if !added { greps.push(r); }
                }
            }
            i = inst_next(i);
        }
    }
    if greps.len == 0 { return; }
    for li in loops.len {
        let l = loops[li];
        var prod = lcost(1);
        for j in loops.len { if loops[j] != l { prod = lcost_mul(prod, lcost(tcs[j])); } }
        var c = lcost(0);
        for g in greps { c = lcost_add(c, lcost_mul(lir_compute_ref_cost(g, l, cls), prod)); }
        lcc_loops.push(l);
        lcc_costs.push(c);
    }
    // sortLoopCosts: stable, larger cost first
    for i in 1..lcc_loops.len {
        let tl = lcc_loops[i];
        let tcst = lcc_costs[i];
        var j = i;
        while j > 0 && lcost_lt(lcc_costs[j - 1], tcst) { lcc_loops[j] = lcc_loops[j - 1]; lcc_costs[j] = lcc_costs[j - 1]; j--; }
        lcc_loops[j] = tl;
        lcc_costs[j] = tcst;
    }
}

fn lcc_index_of(l: i32) -> i64 { for k in lcc_loops.len { if lcc_loops[k] == l { return k; } } return -1; }
// CacheCost::getLoopCost (-1 when absent)
fn lcc_loop_cost(l: i32) -> LCost { let k = lcc_index_of(l); return if k >= 0 { lcc_costs[k] } else { lcost(-1) }; }

// print<loop-cache-cost>
fn print_loop_cache_cost(fv: i32) {
    errs("Printing analysis 'Loop Cache Analysis' for function '");
    errs(val_name(fv));
    errs("':\n");
    st_touch(fv);
    li_get(fv);
    scev_get(fv);
    aa_begin(fv);
    da_read_options();
    for k in li_ntop(fv) {
        lcc_compute(li_top(fv, k));
        if !lcc_valid { continue; }
        for j in lcc_loops.len {
            errs("Loop '");
            // Loop::getName: the header's name, or "<unnamed loop>"
            let h = loop_header(lcc_loops[j]);
            errs(if vals[h].name >= 0 { val_name(h) } else { "<unnamed loop>" });
            errs("' has cost = ");
            lcost_print(lcc_costs[j]);
            errs("\n");
        }
    }
}
