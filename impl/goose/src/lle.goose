// LoopLoadElimination: port of llvm/lib/Transforms/Scalar/LoopLoadElimination.cpp (whole).
// The LoadEliminationForLoop object is the lle_* globals; its PSE is a copy of the LAI's (pse_copy).
import std;
import ir;
import irutil;
import instinfo;
import analyses;
import flags;
import gen_attrs;
import datalayout;
import loads;
import domtree;
import loopinfo;
import loopsimplify;
import loopsimplify_pass;
import lcssa;
import aa;
import tli;
import scev;
import scev_create;
import scev_update;
import scev_lt;
import scev_expander;
import pse;
import laa;
import loop_utils;
import loop_versioning;
import psi;

var lle_l: i32 = -1;
var lle_pse: i32 = -1;
var lle_cand_ld: i32[>..<];      // the candidates (forward_list: front = index 0)
var lle_cand_st: i32[>..<];
var lle_order = hm_new();        // InstOrder

// getPtrStride(PSE, LoadType, Ptr, L, DT) with the LLE's PSE and no symbolic strides: 0 = std::nullopt
fn lle_ptr_stride(at: i32, ptr: i32) -> i64 {
    let save_pse = lai_pse;
    let save_ns = laa_no_strides;
    lai_pse = lle_pse;
    laa_no_strides = true;
    let ok, s = laa_get_ptr_stride_assume(at, ptr, lle_l, false, true);
    lai_pse = save_pse;
    laa_no_strides = save_ns;
    return if ok { s } else { 0 };
}

// StoreToLoadForwardingCandidate::isDependenceDistanceOfOne
fn lle_distance_of_one(ld: i32, st: i32) -> bool {
    let lp = op(ld, 0);
    let sp = op(st, 1);
    let lt: i32 = vals[ld].ty;
    let sl = lle_ptr_stride(lt, lp);
    let ss = lle_ptr_stride(lt, sp);
    if sl == 0 || ss == 0 || sl != ss { return false; }
    if sl != 1 && sl != -1 { return false; }
    let tbs = dl_alloc_size(lt);
    let la = pse_get_scev(lle_pse, lp);
    let sa = pse_get_scev(lle_pse, sp);
    let d = sc_minus(sa, la);
    if !sc_is_const(d) { return false; }
    // Val == TypeByteSize * StrideLoad (APInt == uint64_t: the product wraps as an unsigned 64-bit value)
    let want = ((tbs as i64) * sl) as! u64;
    let a = sc_ap(d);
    return ap_active_bits(a) <= 64 && ap_zext64(a) == want;
}

// findStoreToLoadDependences(LAI)
fn lle_find_store_to_load_dependences() {
    lle_cand_ld.clear();
    lle_cand_st.clear();
    if !mdc_record { return; }
    var unknown: i32[>..<] = [];
    for d in mdc_deps {
        var src = mdc_inst[d.src];
        var dst = mdc_inst[d.dst];
        let t = d.ty as i64;
        if t == DT_UNKNOWN || t == DT_INDIRECT_UNSAFE || t == DT_INVARIANT_UNSAFE {
            if iop(src) == OP_LOAD { unknown.push(src); }
            if iop(dst) == OP_LOAD { unknown.push(dst); }
            continue;
        }
        if dep_is_backward(t) { let x = src; src = dst; dst = x; }
        if iop(src) != OP_STORE { continue; }
        if iop(dst) != OP_LOAD { continue; }
        if !ld_is_bit_or_noop_ptr_castable(vals[op(src, 0)].ty, vals[dst].ty) { continue; }
        // emplace_front: reversed below
        lle_cand_ld.push(dst);
        lle_cand_st.push(src);
    }
    var a: i64 = 0;
    var b = lle_cand_ld.len - 1;
    while a < b {
        let x = lle_cand_ld[a]; lle_cand_ld[a] = lle_cand_ld[b]; lle_cand_ld[b] = x;
        let y = lle_cand_st[a]; lle_cand_st[a] = lle_cand_st[b]; lle_cand_st[b] = y;
        a++; b--;
    }
    if unknown.len > 0 {
        var w: i64 = 0;
        for k in lle_cand_ld.len {
            var u = false;
            for x in unknown { if x == lle_cand_ld[k] { u = true; } }
            if !u { lle_cand_ld[w] = lle_cand_ld[k]; lle_cand_st[w] = lle_cand_st[k]; w++; }
        }
        lle_cand_ld.resize(w);
        lle_cand_st.resize(w);
    }
}

fn lle_index(i: i32) -> i64 { hm_get(lle_order, i as u64, -1) }

// removeDependencesFromMultipleStores
fn lle_remove_dependences_from_multiple_stores() {
    var keys: i32[>..<] = [];     // LoadToSingleCand: load -> candidate index (-1 = nullptr)
    var vals_: i64[>..<] = [];
    for c in lle_cand_ld.len {
        let ld = lle_cand_ld[c];
        var f: i64 = -1;
        for j in keys.len { if keys[j] == ld { f = j; } }
        if f < 0 { keys.push(ld); vals_.push(c); continue; }
        let other = vals_[f];
        if other < 0 { continue; }
        if inst_parent(lle_cand_st[c]) == inst_parent(lle_cand_st[other]) &&
           lle_distance_of_one(lle_cand_ld[c], lle_cand_st[c]) && lle_distance_of_one(lle_cand_ld[other], lle_cand_st[other]) {
            if lle_index(lle_cand_st[other]) < lle_index(lle_cand_st[c]) { vals_[f] = c; }
        } else { vals_[f] = -1; }
    }
    var w: i64 = 0;
    for c in lle_cand_ld.len {
        var keep = false;
        for j in keys.len { if keys[j] == lle_cand_ld[c] { keep = vals_[j] == c; } }
        if keep { lle_cand_ld[w] = lle_cand_ld[c]; lle_cand_st[w] = lle_cand_st[c]; w++; }
    }
    lle_cand_ld.resize(w);
    lle_cand_st.resize(w);
}

// collectMemchecks(Candidates)
fn lle_collect_memchecks(cl: const i32[:], cs: const i32[:], out: i64[>..<]&) {
    // findPointersWrittenOnForwardingPath
    var last_load = cl[0];
    for x in cl { if lle_index(x) > lle_index(last_load) { last_load = x; } }
    var first_store = cs[0];
    for x in cs { if lle_index(x) < lle_index(first_store) { first_store = x; } }
    var written: i32[>..<] = [];
    let fsi = lle_index(first_store);
    let lli = lle_index(last_load);
    for k in fsi + 1..mdc_inst.len { let i = mdc_inst[k]; if iop(i) == OP_STORE { written.push(op(i, 1)); } }
    for k in lli { let i = mdc_inst[k]; if iop(i) == OP_STORE { written.push(op(i, 1)); } }
    var loadptrs: i32[>..<] = [];
    for x in cl { loadptrs.push(op(x, 0)); }
    out.clear();
    for c in rpc_checks {
        let g1 = rpc_groups[c / 4294967296];
        let g2 = rpc_groups[c % 4294967296];
        var need = false;
        for a in g1.n as i64 {
            for b in g2.n as i64 {
                let p1 = rpc_ptrs[rpc_gmem[(g1.at as i64) + a]].ptr;
                let p2 = rpc_ptrs[rpc_gmem[(g2.at as i64) + b]].ptr;
                if (lle_in(written, p1) && lle_in(loadptrs, p2)) || (lle_in(written, p2) && lle_in(loadptrs, p1)) { need = true; }
            }
        }
        if need { out.push(c); }
    }
}
fn lle_in(xs: const i32[:], v: i32) -> bool { for x in xs { if x == v { return true; } } return false; }

// propagateStoredValueToLoadUsers(Cand, SEE)
fn lle_propagate(ld: i32, st: i32) {
    let ptr = op(ld, 0);
    let ps = pse_get_scev(lle_pse, ptr);
    let ph = loop_preheader(lle_l);
    let ip = sx_expand_code_for_at(sc_op(ps, 0), vals[ptr].ty, block_terminator(ph));
    let init = create_inst(OP_LOAD, vals[ld].ty, [ip]);
    insts[inst_of(init)].align = insts[inst_of(ld)].align;
    inst_insert_before(init, block_terminator(ph));
    set_name(init, "load_initial");
    inst_erase_md(init, 0);
    let header = loop_header(lle_l);
    let phi = new_inst(OP_PHI, vals[init].ty, 2);
    vals[phi].nops = 0;
    inst_insert_before_head(phi, block_first(header));
    set_name(phi, "store_forwarded");
    phi_add_incoming(phi, init, ph);
    let lt: i32 = vals[init].ty;
    var sv = op(st, 0);
    if lt != vals[sv].ty {
        // CastInst::CreateBitOrPointerCast(StoreValue, LoadType, "store_forward_cast", Store)
        var o = OP_BITCAST;
        if ty_kind(vals[sv].ty) == TK_PTR && ty_kind(lt) == TK_INT { o = OP_PTRTOINT; }
        else if ty_kind(vals[sv].ty) == TK_INT && ty_kind(lt) == TK_PTR { o = OP_INTTOPTR; }
        let c = create_inst(o, lt, [sv]);
        inst_insert_before(c, st);
        set_name(c, "store_forward_cast");
        let dl = inst_get_md(ld, 0);
        if dl >= 0 { inst_set_md(c, 0, dl); } else { inst_erase_md(c, 0); }
        sv = c;
    }
    phi_add_incoming(phi, sv, loop_latch(lle_l));
    rauw(ld, phi);
    let dl = inst_get_md(ld, 0);
    if dl >= 0 { inst_set_md(phi, 0, dl); }
}

// doesStoreDominatesAllLatches
fn lle_store_dominates_all_latches(bb: i32) -> bool {
    var ls: i32[>..<] = [];
    loop_latches(lle_l, ls);
    for lt in ls { if !dt_dominates_block(DT_DOM, bb, lt) { return false; } }
    return true;
}

// processLoop
fn lle_process_loop() -> bool {
    lle_find_store_to_load_dependences();
    if lle_cand_ld.len == 0 { return false; }
    // generateInstructionOrderMap
    hm_clear(lle_order);
    for k in mdc_inst.len { hm_put(lle_order, mdc_inst[k] as u64, k); }
    lle_remove_dependences_from_multiple_stores();
    if lle_cand_ld.len == 0 { return false; }
    var cl: i32[>..<] = [];
    var cs: i32[>..<] = [];
    for k in lle_cand_ld.len {
        let ld = lle_cand_ld[k];
        let st = lle_cand_st[k];
        if !lle_store_dominates_all_latches(inst_parent(st)) { continue; }
        if inst_parent(ld) != loop_header(lle_l) { continue; }
        if !lle_distance_of_one(ld, st) { continue; }
        cl.push(ld);
        cs.push(st);
    }
    if cl.len == 0 { return false; }
    var checks: i64[>..<] = [];
    lle_collect_memchecks(cl, cs, checks);
    if checks.len > cl.len * flag_int("runtime-check-per-loop-load-elim", 1) { return false; }
    let u = pse_union(lai_pse);
    if su_n(u) > flag_int("loop-load-elimination-scev-check-threshold", 8) { return false; }
    if !loop_is_simplify_form(lle_l) { return false; }
    if checks.len != 0 || !su_always_true(u) {
        if lai_has_convergent { return false; }
        // shouldOptimizeForSize(HeaderBB, PSI, BFI): optsize / minsize functions
        let fv = block_func(loop_header(lle_l));
        if func_has_fn_attr(fv, AK_OptimizeForSize) || func_has_fn_attr(fv, AK_MinSize) { return false; }
        // with a cached ProfileSummaryInfo the PGSO queries need BlockFrequencyInfo and the profile summary
        if psi_valid { fatal("LoopLoadElimination: shouldOptimizeForSize with a ProfileSummaryInfo (PGSO) is not ported yet"); }
        if !lver_is_lcssa_form(lle_l) { let s = lcssa_se; lcssa_se = true; form_lcssa_recursively(lle_l); lcssa_se = s; }
        lver_init(lle_l, checks);
        var defs: i32[>..<] = [];
        lver_defs_used_outside(lle_l, defs);
        lver_version_loop(defs);
        var w: i64 = 0;
        for k in cl.len {
            if !sc_is_addrec(pse_get_scev(lle_pse, op(cl[k], 0))) || !sc_is_addrec(pse_get_scev(lle_pse, op(cs[k], 1))) { continue; }
            cl[w] = cl[k]; cs[w] = cs[k]; w++;
        }
        cl.resize(w);
        cs.resize(w);
    }
    sx_begin("storeforward", true);
    for k in cl.len { lle_propagate(cl[k], cs[k]); }
    sx_end();
    return true;
}

// LoopLoadEliminationPass::run / eliminateLoadsAcrossLoops
fn loop_load_elim_run(fv: i32) -> u32 {
    li_get(fv);
    if li_ntop(fv) == 0 { return PA_ALL; }
    scev_get(fv);
    dt_get(fv, DT_DOM);
    aa_begin(fv);
    tli_cur_fn = fv;
    var wl: i32[>..<] = [];
    var changed = false;
    for k in li_ntop(fv) {
        var st: i32[>..<] = [];
        st.push(li_top(fv, k));
        var pre: i32[>..<] = [];
        while st.len > 0 {
            let l = st.pop();
            pre.push(l);
            var c = loop_nsubs(l) - 1;
            while c >= 0 { st.push(loop_sub(l, c)); c--; }
        }
        for l in pre {
            // simplifyLoop(L, &DT, &LI, SE, AC, nullptr, false)
            let save_se = ls_se; let save_ms = ls_mssau;
            ls_se = true; ls_mssau = false;
            if simplify_loop(l, false) { changed = true; }
            ls_se = save_se; ls_mssau = save_ms;
            if loop_is_innermost(l) { wl.push(l); }
        }
    }
    for l in wl {
        if !lver_is_rotated_form(l) || loop_exiting_block(l) < 0 { continue; }
        lai_compute(l, false);
        lle_l = l;
        lle_pse = pse_copy(lai_pse);
        if lle_process_loop() { changed = true; }
    }
    pse_reset();
    if !changed { return PA_ALL; }
    return ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_LOOPS);
}
