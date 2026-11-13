// Delinearization: port of llvm/lib/Analysis/Delinearization.cpp (collectParametricTerms, findArrayDimensions,
// computeAccessFunctions, delinearize, findFixedSizeArrayDimensions, delinearizeFixedSizeArray,
// validateDelinearizationResult, getIndexExpressionsFromGEP, the print<delinearization> printer) and
// llvm/lib/Analysis/ScalarEvolutionDivision.cpp (SCEVDivision::divide and its printer print<scev-division>), plus
// ScalarEvolution::getElementSize (ScalarEvolution.cpp).
//
// SCEVTraversal (visitAll) is written out per visitor: a worklist popped from the back, `follow` asked when a node
// is pushed, each node visited once. SCEV lists live in global stacks with marks (the division recurses).
import std;
import ir;
import irutil;
import flags;
import apint;
import loopinfo;
import scev;
import scev_create;
import scev_range;
import scev_lt;
import scev_pred;
import scev_eval;
import implied;
import vt;

// ---------------------------------------------------------------------------------------------
// SCEV traversal helpers

// The operands SCEVTraversal walks (casts: one; udiv: two; n-ary and AddRecs: all)
fn dl_push_children(s: i32, out: i32[>..<]&) {
    let k = sc_kind(s);
    if k == SC_CONST || k == SC_VSCALE || k == SC_UNKNOWN || k == SC_CNC { return; }
    for i in sc_nops(s) { out.push(sc_op(s, i)); }
}

// SCEVExprContains(S, isa<SCEVUnknown> of an UndefValue) when undef_only, else isa<SCEVUnknown>
fn dl_contains_unknown(root: i32, undef_only: bool) -> bool {
    var seen = hm_new();
    var wl: i32[>..<] = [];
    var kids: i32[>..<] = [];
    fn pred(s: i32) -> bool {
        if sc_kind(s) != SC_UNKNOWN { return false; }
        if !undef_only { return true; }
        let v = sc_value(s);
        return vals[v].kind == VK_UNDEF || vals[v].kind == VK_POISON;
    }
    hm_put(seen, (root as i64) as u64, 1);
    if pred(root) { return true; }
    wl.push(root);
    while wl.len > 0 {
        let s = wl.pop();
        kids.clear();
        dl_push_children(s, kids);
        for c in kids {
            if hm_has(seen, (c as i64) as u64) { continue; }
            hm_put(seen, (c as i64) as u64, 1);
            if pred(c) { return true; }
            wl.push(c);
        }
    }
    return false;
}

// sizeOfSCEV: the number of distinct nodes
fn dl_size_of_scev(root: i32) -> i64 {
    var seen = hm_new();
    var wl: i32[>..<] = [];
    var kids: i32[>..<] = [];
    var n: i64 = 1;
    hm_put(seen, (root as i64) as u64, 1);
    wl.push(root);
    while wl.len > 0 {
        let s = wl.pop();
        kids.clear();
        dl_push_children(s, kids);
        for c in kids {
            if hm_has(seen, (c as i64) as u64) { continue; }
            hm_put(seen, (c as i64) as u64, 1);
            n++;
            wl.push(c);
        }
    }
    return n;
}

// ---------------------------------------------------------------------------------------------
// SCEVDivision

var dv_stk: i32[>..<];          // Qs / Rs runs of the recursive division

// SCEVParameterRewriter::rewrite(S, SE, {V -> To})
recursive fn dl_rewrite_param(s: i32, v: i32, to: i32) -> i32 {
    var rw = rw_new(RW_PARAM, to);
    rw.becond = v;
    return sc_rw_visit(rw, s);
}

// SCEVDivision::divide(SE, Numerator, Denominator) -> (Quotient, Remainder)
recursive fn sc_divide(num: i32, den: i32) -> i32, i32 {
    let zero = sc_get_zero(sc_ty(den));
    let one = sc_get_one(sc_ty(den));
    if num == den { return one, zero; }
    if sc_is_zero(num) { return zero, zero; }
    if sc_is_one(den) { return num, zero; }
    if sc_kind(den) == SC_MUL {
        var q = num;
        for i in sc_nops(den) {
            let qq, rr = sc_divide(q, sc_op(den, i));
            q = qq;
            if !sc_is_zero(rr) { return zero, num; }
        }
        return q, zero;
    }
    // D.visit(Numerator), starting from cannotDivide(Numerator)
    let ty = sc_ty(den);
    let k = sc_kind(num);
    if k == SC_CONST {
        if sc_kind(den) == SC_CONST {
            let q, r = ap_sdivrem(sc_ap(num), sc_ap(den));
            return sc_get_constant(q), sc_get_constant(r);
        }
        return zero, num;
    }
    if k == SC_ADDREC {
        if !sc_is_affine(num) { return zero, num; }
        let sq, sr = sc_divide(sc_op(num, 0), den);
        let tq, tr = sc_divide(sc_get_step_recurrence(num), den);
        if ty != sc_ty(sq) || ty != sc_ty(sr) || ty != sc_ty(tq) || ty != sc_ty(tr) { return zero, num; }
        let l = sc_loop(num);
        let q = sc_addrec2(sq, tq, l, SF_ANY);
        let r = sc_addrec2(sr, tr, l, SF_ANY);
        return q, r;
    }
    if k == SC_ADD {
        let b = dv_stk.len;
        let n = sc_nops(num);
        for i in n {
            let q, r = sc_divide(sc_op(num, i), den);
            if ty != sc_ty(q) || ty != sc_ty(r) { dv_stk.resize(b); return zero, num; }
            dv_stk.push(q);
            dv_stk.push(r);
        }
        if n == 1 {
            let q = dv_stk[b];
            let r = dv_stk[b + 1];
            dv_stk.resize(b);
            return q, r;
        }
        let sb = ss.len;
        for i in n { ss.push(dv_stk[b + 2 * i]); }
        let q = sc_add_n(sb, SF_ANY, 0);
        let sb2 = ss.len;
        for i in n { ss.push(dv_stk[b + 2 * i + 1]); }
        let r = sc_add_n(sb2, SF_ANY, 0);
        dv_stk.resize(b);
        return q, r;
    }
    if k == SC_MUL {
        let b = dv_stk.len;
        var found = false;
        for i in sc_nops(num) {
            let o = sc_op(num, i);
            if ty != sc_ty(o) { dv_stk.resize(b); return zero, num; }
            if found { dv_stk.push(o); continue; }
            let q, r = sc_divide(o, den);
            if !sc_is_zero(r) { dv_stk.push(o); continue; }
            if ty != sc_ty(q) { dv_stk.resize(b); return zero, num; }
            found = true;
            dv_stk.push(q);
        }
        if found {
            var q: i32 = -1;
            if dv_stk.len - b == 1 { q = dv_stk[b]; }
            else {
                let sb = ss.len;
                for j in b..dv_stk.len { ss.push(dv_stk[j]); }
                q = sc_mul_n(sb, SF_ANY, 0);
            }
            dv_stk.resize(b);
            return q, zero;
        }
        dv_stk.resize(b);
        if sc_kind(den) != SC_UNKNOWN { return zero, num; }
        let rem = dl_rewrite_param(num, sc_value(den), zero);
        if sc_is_zero(rem) {
            return dl_rewrite_param(num, sc_value(den), one), rem;
        }
        let diff = sc_minus(num, rem);
        if dl_size_of_scev(diff) > dl_size_of_scev(num) { return zero, num; }
        let q, r = sc_divide(diff, den);
        if r != zero { return zero, num; }
        return q, rem;
    }
    // VScale and every other kind: cannot divide
    return zero, num;
}

// ---------------------------------------------------------------------------------------------
// collectParametricTerms (Terms appended to `terms`)

fn dl_collect_parametric_terms(expr: i32, terms: i32[>..<]&) {
    var strides: i32[>..<] = [];
    var seen = hm_new();
    var wl: i32[>..<] = [];
    var kids: i32[>..<] = [];
    // SCEVCollectStrides
    fn follow_stride(s: i32) -> bool {
        if sc_kind(s) != SC_ADDREC || !sc_is_affine(s) { return false; }
        strides.push(sc_get_step_recurrence(s));
        return true;
    }
    hm_put(seen, (expr as i64) as u64, 1);
    if follow_stride(expr) { wl.push(expr); }
    while wl.len > 0 {
        let s = wl.pop();
        kids.clear();
        dl_push_children(s, kids);
        for c in kids {
            if hm_has(seen, (c as i64) as u64) { continue; }
            hm_put(seen, (c as i64) as u64, 1);
            if follow_stride(c) { wl.push(c); }
        }
    }
    // SCEVCollectTerms over each stride
    fn follow_term(s: i32) -> bool {
        let k = sc_kind(s);
        if k == SC_UNKNOWN || k == SC_MUL || k == SC_SEXT {
            if !dl_contains_unknown(s, true) { terms.push(s); }
        }
        return k == SC_ADD || k == SC_ADDREC;
    }
    for st in strides {
        hm_clear(seen);
        wl.clear();
        hm_put(seen, (st as i64) as u64, 1);
        if follow_term(st) { wl.push(st); }
        while wl.len > 0 {
            let s = wl.pop();
            kids.clear();
            dl_push_children(s, kids);
            for c in kids {
                if hm_has(seen, (c as i64) as u64) { continue; }
                hm_put(seen, (c as i64) as u64, 1);
                if follow_term(c) { wl.push(c); }
            }
        }
    }
    // SCEVCollectAddRecMultiplies over Expr
    fn has_addrec(root: i32) -> bool {
        var seen2 = hm_new();
        var wl2: i32[>..<] = [];
        var kids2: i32[>..<] = [];
        hm_put(seen2, (root as i64) as u64, 1);
        if sc_kind(root) == SC_ADDREC { return true; }
        wl2.push(root);
        var found = false;
        while wl2.len > 0 {
            let s = wl2.pop();
            kids2.clear();
            dl_push_children(s, kids2);
            for c in kids2 {
                if hm_has(seen2, (c as i64) as u64) { continue; }
                hm_put(seen2, (c as i64) as u64, 1);
                if sc_kind(c) == SC_ADDREC { found = true; continue; }
                wl2.push(c);
            }
        }
        return found;
    }
    fn follow_mul(s: i32) -> bool {
        if sc_kind(s) == SC_MUL {
            var has = false;
            var opsv: i32[>..<] = [];
            for i in sc_nops(s) {
                let o = sc_op(s, i);
                let unk = sc_kind(o) == SC_UNKNOWN;
                if unk && !(is_inst(sc_value(o)) && iop(sc_value(o)) == OP_CALL) { opsv.push(o); }
                else if unk { has = true; }
                else if has_addrec(o) { has = true; }
            }
            if opsv.len == 0 { return true; }
            if !has { return false; }
            let sb = ss.len;
            for o in opsv { ss.push(o); }
            terms.push(sc_mul_n(sb, SF_ANY, 0));
        }
        let k = sc_kind(s);
        return k == SC_ADD || k == SC_ADDREC;
    }
    hm_clear(seen);
    wl.clear();
    hm_put(seen, (expr as i64) as u64, 1);
    if follow_mul(expr) { wl.push(expr); }
    while wl.len > 0 {
        let s = wl.pop();
        kids.clear();
        dl_push_children(s, kids);
        for c in kids {
            if hm_has(seen, (c as i64) as u64) { continue; }
            hm_put(seen, (c as i64) as u64, 1);
            if follow_mul(c) { wl.push(c); }
        }
    }
}

fn dl_number_of_terms(s: i32) -> i64 { if sc_kind(s) == SC_MUL { sc_nops(s) } else { 1 } }

// SE.getMulExpr of the non-constant operands of a MulExpr
fn dl_mul_of_non_constants(m: i32) -> i32 {
    let sb = ss.len;
    for i in sc_nops(m) { let o = sc_op(m, i); if sc_kind(o) != SC_CONST { ss.push(o); } }
    return sc_mul_n(sb, SF_ANY, 0);
}

// findArrayDimensions(SE, Terms, Sizes, ElementSize). `terms` is consumed.
fn dl_find_array_dimensions(terms: i32[>..<]&, sizes: i32[>..<]&, elsize: i32) {
    if terms.len < 1 || elsize < 0 { return; }
    var params = false;
    for t in terms { if dl_contains_unknown(t, false) { params = true; break; } }
    if !params { return; }
    // array_pod_sort by pointer value (SCEV creation order) + unique
    var srt: i32[>..<] = [];
    for t in terms {
        var j = srt.len;
        srt.push(t);
        while j > 0 && srt[j - 1] > t { srt[j] = srt[j - 1]; j--; }
        srt[j] = t;
    }
    terms.clear();
    for t in srt { if terms.len == 0 || terms[terms.len - 1] != t { terms.push(t); } }
    // llvm::sort by number of factors, larger first: libstdc++'s insertion sort up to 16 elements
    if terms.len > 16 { fatal("delinearization: more than 16 parametric terms (std::sort order) is not ported"); }
    for i in 1..terms.len {
        let t = terms[i];
        var j = i;
        while j > 0 && dl_number_of_terms(t) > dl_number_of_terms(terms[j - 1]) { terms[j] = terms[j - 1]; j--; }
        terms[j] = t;
    }
    for i in terms.len {
        let q, r = sc_divide(terms[i], elsize);
        if !sc_is_zero(q) { terms[i] = q; }
    }
    var nt: i32[>..<] = [];
    for t in terms {
        // removeConstantFactors
        let k = sc_kind(t);
        if k == SC_CONST { continue; }
        if k == SC_MUL { nt.push(dl_mul_of_non_constants(t)); } else { nt.push(t); }
    }
    if nt.len == 0 || !dl_find_array_dimensions_rec(nt, sizes) { sizes.clear(); return; }
    sizes.push(elsize);
}

// findArrayDimensionsRec, unrolled: the steps are pushed innermost first
fn dl_find_array_dimensions_rec(terms: i32[>..<]&, sizes: i32[>..<]&) -> bool {
    var steps: i32[>..<] = [];
    loop {
        let last = terms.len - 1;
        var step = terms[last];
        if last == 0 {
            if sc_kind(step) == SC_MUL { step = dl_mul_of_non_constants(step); }
            sizes.push(step);
            break;
        }
        for i in terms.len {
            let q, r = sc_divide(terms[i], step);
            if !sc_is_zero(r) { return false; }
            terms[i] = q;
        }
        var n: i64 = 0;
        for i in terms.len { if sc_kind(terms[i]) != SC_CONST { terms[n] = terms[i]; n++; } }
        terms.resize(n);
        steps.push(step);
        if n == 0 { break; }
    }
    var k = steps.len;
    while k > 0 { k--; sizes.push(steps[k]); }
    return true;
}

// computeAccessFunctions(SE, Expr, Subscripts, Sizes)
fn dl_compute_access_functions(expr: i32, subs: i32[>..<]&, sizes: i32[>..<]&) {
    if sizes.len == 0 { return; }
    if sc_kind(expr) == SC_ADDREC && !sc_is_affine(expr) { return; }
    subs.clear();
    var res = expr;
    let last = sizes.len - 1;
    var i = last;
    while i >= 0 {
        let q, r = sc_divide(res, sizes[i]);
        res = q;
        if i == last {
            if !sc_is_zero(r) { subs.clear(); sizes.clear(); return; }
            i--;
            continue;
        }
        subs.push(r);
        i--;
    }
    subs.push(res);
    // std::reverse
    var a: i64 = 0;
    var b = subs.len - 1;
    while a < b { let t = subs[a]; subs[a] = subs[b]; subs[b] = t; a++; b--; }
}

// delinearize(SE, Expr, Subscripts, Sizes, ElementSize)
fn dl_delinearize(expr: i32, subs: i32[>..<]&, sizes: i32[>..<]&, elsize: i32) {
    subs.clear();
    sizes.clear();
    var terms: i32[>..<] = [];
    dl_collect_parametric_terms(expr, terms);
    if terms.len == 0 { return; }
    dl_find_array_dimensions(terms, sizes, elsize);
    if sizes.len == 0 { return; }
    dl_compute_access_functions(expr, subs, sizes);
}

// findFixedSizeArrayDimensions(SE, Expr, Sizes, ElementSize)
fn dl_find_fixed_size_array_dimensions(expr: i32, sizes: u64[>..<]&, elsize: i32) -> bool {
    if elsize < 0 || sc_kind(elsize) != SC_CONST { return false; }
    let ea = sc_ap(elsize);
    if ap_is_zero(ea) { return false; }
    if !ap_fits_u64(ea) { return false; }
    let es = ea.lo;
    // collectConstantAbsSteps
    var e = expr;
    var ok = false;
    loop {
        if sc_kind(e) == SC_CONST {
            let w = sc_ap(e).w as i64;
            ok = ap_is_zero(ap_urem(sc_ap(e), ap_u64(es, w)));
            break;
        }
        if sc_kind(e) != SC_ADDREC || !sc_is_affine(e) { break; }
        let st = sc_get_step_recurrence(e);
        if sc_kind(st) != SC_CONST { break; }
        let a = ap_abs(sc_ap(st));
        let q, r = ap_udivrem(a, ap_u64(es, a.w as i64));
        if !ap_is_zero(r) { break; }
        if !ap_fits_u64(q) { break; }
        sizes.push(q.lo);
        e = sc_op(e, 0);
    }
    if !ok || sizes.len == 0 { sizes.clear(); return false; }
    // sort descending, unique
    for i in 1..sizes.len {
        let t = sizes[i];
        var j = i;
        while j > 0 && sizes[j - 1] < t { sizes[j] = sizes[j - 1]; j--; }
        sizes[j] = t;
    }
    var n: i64 = 0;
    for i in sizes.len { if n == 0 || sizes[n - 1] != sizes[i] { sizes[n] = sizes[i]; n++; } }
    sizes.resize(n);
    sizes[sizes.len - 1] = 1;
    var i: i64 = 0;
    while i + 1 < sizes.len {
        let prev = sizes[i + 1];
        if sizes[i] % prev != 0 { sizes.clear(); return false; }
        sizes[i] = sizes[i] / prev;
        i++;
    }
    sizes[sizes.len - 1] = es;
    return true;
}

// delinearizeFixedSizeArray(SE, Expr, Subscripts, Sizes, ElementSize)
fn dl_delinearize_fixed_size_array(expr: i32, subs: i32[>..<]&, sizes: i32[>..<]&, elsize: i32) -> bool {
    subs.clear();
    sizes.clear();
    var cs: u64[>..<] = [];
    if !dl_find_fixed_size_array_dimensions(expr, cs, elsize) { sizes.clear(); return false; }
    for c in cs { sizes.push(sc_get_constant_ty(sc_ty(expr), c, false)); }
    dl_compute_access_functions(expr, subs, sizes);
    return subs.len > 0;
}

// validateDelinearizationResult(SE, Sizes, Subscripts)
fn dl_validate(sizes: const i32[:], subs: const i32[:]) -> bool {
    for i in 1..sizes.len {
        var size = sizes[i - 1];
        var sub = subs[i];
        if !sc_is_known_non_negative(sub) { return false; }
        let wt = sc_get_wider_type(sc_ty(sub), sc_ty(size));
        sub = sc_get_noop_or_sign_extend(sub, wt);
        size = sc_get_noop_or_sign_extend(size, wt);
        if !sc_is_known_predicate(P_SLT, sub, size) { return false; }
    }
    var prod = sc_get_one(sc_ty(sizes[0]));
    for size in sizes {
        if !sc_will_not_overflow(OP_MUL, true, prod, size, -1) { return false; }
        prod = sc_mul(prod, size);
    }
    if !sc_will_not_overflow(OP_MUL, true, prod, subs[0], -1) { return false; }
    let mn = sc_mul(prod, subs[0]);
    if !sc_will_not_overflow(OP_ADD, true, mn, prod, -1) { return false; }
    let mx1 = sc_add(mn, prod);
    if !sc_will_not_overflow(OP_SUB, true, mx1, sc_get_one(sc_ty(mx1)), -1) { return false; }
    return true;
}

// getIndexExpressionsFromGEP(SE, GEP, Subscripts, Sizes)
fn dl_index_expressions_from_gep(gep: i32, subs: i32[>..<]&, sizes: i32[>..<]&) -> bool {
    var t: i32 = -1;
    let ity = sc_effective_ty(vals[op(gep, 0)].ty);
    var dropped = false;
    for i in 1..nops(gep) {
        let e = sc_get_scev(op(gep, i));
        if i == 1 {
            t = gep_src_ty(gep);
            if sc_kind(e) == SC_CONST && sc_is_zero(e) { dropped = true; continue; }
            subs.push(e);
            continue;
        }
        if ty_kind(t) != TK_ARRAY { subs.clear(); sizes.clear(); return false; }
        subs.push(e);
        if !(dropped && i == 2) { sizes.push(sc_get_constant_ty(ity, ty_count(t) as u64, false)); }
        t = ty_elem(t);
    }
    return subs.len > 0;
}

// ScalarEvolution::getElementSize(Inst): nullptr (-1) unless a load or store
fn sc_get_element_size(i: i32) -> i32 {
    var t: i32 = -1;
    if iop(i) == OP_STORE { t = vals[op(i, 0)].ty; }
    else if iop(i) == OP_LOAD { t = vals[i].ty; }
    else { return -1; }
    return sc_get_size_of(sc_effective_ty(ty_ptr(0)), t);
}

// ---------------------------------------------------------------------------------------------
// Printers

fn dl_pointer_operand(i: i32) -> i32 { if iop(i) == OP_STORE { op(i, 1) } else { op(i, 0) } }

// print<delinearization>
fn print_delinearization(fv: i32) {
    li_get(fv);
    scev_get(fv);
    st_touch(fv);
    errs("Printing analysis 'Delinearization' for function '");
    errs(val_name(fv));
    errs("':");
    let heur = flag_bool("delinearize-use-fixed-size-array-heuristic", true);
    var subs: i32[>..<] = [];
    var sizes: i32[>..<] = [];
    fn failed() -> bool { subs.len == 0 || sizes.len == 0 || subs.len != sizes.len }
    var bb = func_first_block(fv);
    while bb >= 0 {
        var i = block_first(bb);
        while i >= 0 {
            let o = iop(i);
            if o != OP_STORE && o != OP_LOAD { i = inst_next(i); continue; }
            let l = li_loop_for(bb);
            if l < 0 { i = inst_next(i); continue; }
            var afn = sc_get_scev_at_scope(sc_get_scev(dl_pointer_operand(i)), l);
            let base = sc_get_pointer_base(afn);
            if sc_kind(base) != SC_UNKNOWN { return; }
            afn = sc_minus(afn, base);
            errs("\nInst:");
            errs_inst(i, fv);
            errs("\nAccessFunction: ");
            sc_print(afn);
            errs("\n");
            dl_delinearize(afn, subs, sizes, sc_get_element_size(i));
            if heur && failed() {
                subs.clear(); sizes.clear();
                dl_delinearize_fixed_size_array(afn, subs, sizes, sc_get_element_size(i));
            }
            if failed() { errs("failed to delinearize\n"); i = inst_next(i); continue; }
            errs("Base offset: ");
            sc_print(base);
            errs("\nArrayDecl[UnknownSize]");
            let n = subs.len;
            for k in 0..n - 1 { errs("["); sc_print(sizes[k]); errs("]"); }
            errs(" with elements of ");
            sc_print(sizes[n - 1]);
            errs(" bytes.\nArrayRef");
            for k in n { errs("["); sc_print(subs[k]); errs("]"); }
            errs("\n");
            let valid = dl_validate(sizes, subs);
            errs("Delinearization validation: ");
            errs(if valid { "Succeeded" } else { "Failed" });
            errs("\n");
            i = inst_next(i);
        }
        bb = block_next(bb);
    }
}

// print<scev-division>
fn print_scev_division(fv: i32) {
    scev_get(fv);
    st_touch(fv);
    errs("Printing analysis 'Scalar Evolution Division' for function '");
    errs(val_name(fv));
    errs("':\n");
    var bb = func_first_block(fv);
    while bb >= 0 {
        var i = block_first(bb);
        while i >= 0 {
            if iop(i) == OP_SDIV {
                if !ty_is_int(vals[i].ty) { fatal("print<scev-division>: an sdiv of vectors (getZero of a vector type) is not ported"); }
                let num = sc_get_scev(op(i, 0));
                let den = sc_get_scev(op(i, 1));
                let q, r = sc_divide(num, den);
                errs("Instruction: ");
                errs_inst(i, fv);
                errs("\n  Numerator: "); sc_print(num);
                errs("\n  Denominator: "); sc_print(den);
                errs("\n  Quotient: "); sc_print(q);
                errs("\n  Remainder: "); sc_print(r);
                errs("\n");
            }
            i = inst_next(i);
        }
        bb = block_next(bb);
    }
}
