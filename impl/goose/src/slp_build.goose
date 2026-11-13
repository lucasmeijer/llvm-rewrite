// SLPVectorizer: building the vectorizable tree. Port of llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp
// (lines 9882-13830): buildTree, getScalarsVectorizationState, PHIHandler, getMainAltOpsNoStateVL,
// tryToFindDuplicates, canBuildSplitNode, InstructionsCompatibilityAnalysis (findAndSetMainInstruction,
// selectBestIdempotentValue, getOperands, buildOriginalOperands, isCopyablePreferable, buildInstructionsState,
// buildOperands), getScalarsVectorizationLegality, buildTreeRec, canMapToVector (slp.goose), canReuseExtract,
// checkEVsForVecCalls (struct-returning calls fail loudly), findInnermostNonInvariantLoop, getLoopNest.
//
// buildTreeRec is recursive: its lists are runs of the tree pools (slp_vp, slp_ip, slp_opl), never locals, so no
// growable local is live at a recursive call. The operand lists built for a node become the node's operands
// (TreeEntry::setOperands copies them in LLVM; nothing modifies the local copy afterwards).
//
// Copyable elements (VectorizeCopyableElements): buildInstructionsState decides with the same profitability checks;
// the scheduler models them as ScheduleCopyableData (slp_sched.goose).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import datalayout;
import apint;
import pm;
import flags;
import vt;
import knownbits;
import demandedbits;
import constfold;
import cfold;
import laa;
import scev;
import loopinfo;
import domtree;
import tti;
import tti_x86;
import tti_x86_vec;
import tti_vec;
import vecutils;
import slp_util;
import slp_tree;
import slp_ops;
import slp_sched;
import slp_loads;

fn slp_recursion_max_depth_opt() -> i64 { flag_int("slp-recursion-max-depth", 12) }
fn slp_copyable_on() -> bool { flag_bool("slp-copyable-elements", true) }
fn slp_split_alternate_on() -> bool { flag_bool("slp-split-alternate-instructions", true) }
fn slp_phi_budget() -> i64 { flag_int("slp-phi-vectorization-budget", 1024) }
fn slp_masked_stores_on() -> bool { flag_bool("slp-enable-masked-stores", true) }

// a new run of operand lists: n lists of `lanes` values each (initialized to -1)
fn slp_opl_new(n: i64, lanes: i64) -> i32 {
    let at = slp_opl.len as i32;
    for k in n {
        let r = slp_vp.len as i32;
        for j in lanes { slp_vp.push(-1); }
        slp_opl.push(SRun { at: r, n: lanes as i32 });
    }
    return at;
}
fn opl_get(opl: i32, k: i64, lane: i64) -> i32 { slp_vp[slp_opl[opl as i64 + k].at as i64 + lane] }
fn opl_set(opl: i32, k: i64, lane: i64, v: i32) { slp_vp[slp_opl[opl as i64 + k].at as i64 + lane] = v; }
fn opl_list(opl: i32, k: i64) -> const i32[:] { let r = slp_opl[opl as i64 + k]; return slp_vp[(r.at as i64)..(r.at + r.n) as i64]; }
fn opl_swap(opl: i32, a: i64, b: i64, lane: i64) { let x = opl_get(opl, a, lane); opl_set(opl, a, lane, opl_get(opl, b, lane)); opl_set(opl, b, lane, x); }

// ---------------------------------------------------------------- small helpers
fn slp_loop_invariant_list(l: i32, vl: const i32[:]) -> bool {
    for v in vl { if !(is_constant(v) || !is_inst(v) || slp_loop_invariant(l, v)) { return false; } }
    return true;
}
// findInnermostNonInvariantLoop(L, VL)
fn slp_innermost_noninvariant_loop(l0: i32, vl: const i32[:]) -> i32 {
    var l = l0;
    while l >= 0 && slp_loop_invariant_list(l, vl) { l = loop_parent(l); }
    return l;
}
fn slp_loop_aware_trip_count() -> i64 { flag_int("slp-cost-loop-trip-count", 2) }
// getLoopNest(L): outermost first
fn slp_loop_nest(l0: i32, out: i32[>..<]&) {
    out.clear();
    if slp_loop_aware_trip_count() == 0 { return; }
    var tmp: i32[>..<] = [];
    var l = l0;
    while l >= 0 { tmp.push(l); l = loop_parent(l); }
    var k = tmp.len;
    while k > 0 { k--; out.push(tmp[k]); }
}
fn slp_num_sign_bits(v: i32) -> i64 {
    let sc = kb_cxt; let sd = sq_no_dt; let sa = sq_no_ac; let st = sq_no_tli;
    kb_cxt = -1; sq_no_dt = false; sq_no_ac = false; sq_no_tli = true;
    let r = num_sign_bits(v, 0);
    kb_cxt = sc; sq_no_dt = sd; sq_no_ac = sa; sq_no_tli = st;
    return r;
}
fn slp_dl_bits(t: i32) -> i64 { dl_size_bits(t) }

// canReuseExtract(VL, CurrentOrder, ResizeAllowed)
fn slp_can_reuse_extract(vl: const i32[:], order: i32[>..<]&, resize_allowed: bool) -> bool {
    var e0: i32 = -1;
    for v in vl { if is_inst_op(v, OP_EXTRACTELEMENT) || is_inst_op(v, OP_EXTRACTVALUE) { e0 = v; break; } }
    let vec = op(e0, 0);
    order.clear();
    var nelts: i64 = 0;
    if iop(e0) == OP_EXTRACTVALUE {
        nelts = slp_can_map_to_vector(vals[vec].ty);
        if nelts == 0 { return false; }
        if !is_inst_op(vec, OP_LOAD) || !ld_is_simple(vec) || slp_num_uses(vec) != vl.len { return false; }
    } else {
        nelts = ty_count(vals[vec].ty);
    }
    let e = vl.len;
    if !resize_allowed && nelts != e { return false; }
    var ind: i64[>..<] = [];
    for k in e { ind.push(-1); }
    var mn = nelts;
    var mx: i64 = 0;
    for i in e {
        let v = vl[i];
        if !is_inst(v) { continue; }
        if op(v, 0) != vec { return false; }
        if iop(v) == OP_EXTRACTELEMENT && is_undef_or_poison(op(v, 1)) { continue; }
        let idx = slp_extract_index(v);
        if idx < 0 { return false; }
        if idx >= nelts { continue; }
        ind[i] = idx;
        if mn > idx { mn = idx; }
        if mx < idx { mx = idx; }
    }
    if mx - mn + 1 > e { return false; }
    if mx + 1 <= e { mn = 0; }
    var keep = true;
    for k in e { order.push(e as i32); }
    for i in e {
        if ind[i] == -1 { continue; }
        let ei = ind[i] - mn;
        if order[ei] as i64 != e { order.clear(); return false; }
        keep = keep && ei == i;
        order[ei] = i as i32;
    }
    if keep { order.clear(); }
    return keep;
}
// checkEVsForVecCalls(VL, S, TLI, Indices, Calls): struct-returning call bundles are not ported
fn slp_check_evs_for_vec_calls(vl: const i32[:], s: SIS) -> bool {
    for v in vl { if !is_inst_op(v, OP_EXTRACTVALUE) { return false; } }
    let vl0 = s.main;
    var aggs: i32[>..<] = [];
    let x0 = insts[inst_of(vl0)];
    for v in vl {
        if v == vl0 { aggs.push(op(vl0, 0)); continue; }
        let x = insts[inst_of(v)];
        if x.naux != x0.naux { return false; }
        for k in x.naux as i64 { if ints[x.aux as i64 + k] != ints[x0.aux as i64 + k] { return false; } }
        if ty_kind(vals[v].ty) == TK_SVEC { return false; }
        aggs.push(op(v, 0));
    }
    let a = slp_get_same_opcode(aggs);
    if sis_valid(a) && sis_opcode(a) == OP_CALL && !sis_is_alt_shuffle(a) && ty_is_struct(vals[a.main].ty) && slp_all_same_block(aggs) {
        for g in aggs {
            var u = vals[g].first_use;
            while u >= 0 { if !is_inst_op(uses[u].user, OP_EXTRACTVALUE) { return false; } u = uses[u].next; }
        }
        slp_fail("struct-returning calls (checkEVsForVecCalls)");
    }
    return false;
}

// ---------------------------------------------------------------- getScalarsVectorizationState
// returns the EntryState; CurrentOrder in `order`, PointerOps in `ptrs`, ExpandShuffleMask in `expand`
fn slp_vectorization_state(s: SIS, vl: const i32[:], scatter_user: bool, order: i32[>..<]&, ptrs: i32[>..<]&,
                           expand: i32[>..<]&) -> i32 {
    let shuffle_or_op = if sis_is_alt_shuffle(s) { OP_SHUFFLEVECTOR } else { sis_opcode(s) };
    let vl0 = s.main;
    let o = shuffle_or_op;
    if o == OP_PHI {
        if nops(vl0) > 128 { return TE_GATHER; }
        for v in vl {
            if !is_inst_op(v, OP_PHI) { continue; }
            for k in phi_nincoming(v) {
                let inc = phi_value(v, k);
                if is_terminator(inc) {
                    if slp_dbg_on { errs("SLP: Need to swizzle PHINodes (terminator use).\n"); slp_dbg_flush(); }
                    return TE_GATHER;
                }
            }
        }
        return TE_VECTORIZE;
    }
    if o == OP_EXTRACTELEMENT || o == OP_EXTRACTVALUE {
        if o == OP_EXTRACTELEMENT {
            for v in vl {
                if !is_inst_op(v, OP_EXTRACTELEMENT) { return TE_GATHER; }
                let x = op(v, 0);
                if slp_is_vectorized(x) { return TE_GATHER; }
                if is_terminator(x) { return TE_GATHER; }
            }
        }
        let reuse = slp_can_reuse_extract(vl, order, false);
        if reuse || order.len > 0 { return TE_VECTORIZE; }
        if o == OP_EXTRACTVALUE && slp_check_evs_for_vec_calls(vl, s) { return TE_VECTORIZE; }
        if slp_dbg_on { errs("SLP: Gather extract sequence.\n"); slp_dbg_flush(); }
        return TE_GATHER;
    }
    if o == OP_INSERTVALUE || o == OP_INSERTELEMENT {
        if o == OP_INSERTVALUE {
            var bad = false;
            var any_undef = false;
            for v in vl {
                if !is_inst_op(v, OP_INSERTVALUE) { continue; }
                let t: i32 = vals[op(v, 1)].ty;
                if insts[inst_of(v)].naux != 1 || !slp_is_valid_element_type(t) || ty_is_vector(t) { bad = true; }
                if is_undef_or_poison(op(v, 0)) { any_undef = true; }
            }
            if bad || !any_undef { return TE_GATHER; }
        }
        sh_clear(SH_TMP0);   // SourceVectors
        for v in vl {
            if is_poison(v) {
                if slp_dbg_on { errs("SLP: Gather of insertelement/insertvalue/poison vector.\n"); slp_dbg_flush(); }
                return TE_GATHER;
            }
            sh_add(SH_TMP0, op(v, 0) as i64, 0);
        }
        var cnt: i64 = 0;
        for v in vl { if !sh_has(SH_TMP0, v as i64, 0) { cnt++; } }
        if cnt >= 2 {
            if slp_dbg_on { errs("SLP: Gather of insertelement/insertvalue vectors with different source vectors.\n"); slp_dbg_flush(); }
            return TE_GATHER;
        }
        for v in vl {
            if sh_has(SH_TMP0, v as i64, 0) && !slp_has_one_use(v) {
                if slp_dbg_on { errs("SLP: Gather of insertelement/insertvalue vectors with multiple uses.\n"); slp_dbg_flush(); }
                return TE_GATHER;
            }
        }
        return TE_VECTORIZE;
    }
    if o == OP_LOAD {
        fn is_gathered_node(vl: const i32[:]) -> bool {
            if slp_gathered_loads_first < 0 { return false; }
            for v in vl {
                if is_poison(v) { continue; }
                var found = false;
                var c = slp_tree_entries_head(v);
                while c >= 0 { if slp_lk[c].x as i64 >= slp_gathered_loads_first { found = true; break; } c = slp_lk[c].next; }
                if !found { return false; }
            }
            return true;
        }
        let ls = slp_can_vectorize_loads(vl, vl0, order, ptrs, false, true);
        if ls == LS_VECTORIZE { return TE_VECTORIZE; }
        if ls == LS_COMPRESS || ls == LS_SCATTER || ls == LS_STRIDED {
            if !slp_graph_transform_mode && slp_te.len > 1 {
                let idx = slp_te.len as i32;
                var seen = false;
                for x in slp_load_entries { if x == idx { seen = true; } }
                if !seen { slp_load_entries.push(idx); }
                return TE_GATHER;
            }
            if is_gathered_node(vl) { return TE_GATHER; }
            return if ls == LS_COMPRESS { TE_COMPRESS } else { if ls == LS_SCATTER { TE_SCATTER } else { TE_STRIDED } };
        }
        if slp_dbg_on {
            let sty: i32 = vals[vl0].ty;
            if dl_size_bits(sty) != dl_alloc_size(sty) * 8 { errs("SLP: Gathering loads of non-packed type.\n"); }
            else {
                var ns = false;
                for v in vl { if !is_inst_op(v, OP_LOAD) || !ld_is_simple(v) { ns = true; } }
                if ns { errs("SLP: Gathering non-simple loads.\n"); } else { errs("SLP: Gathering non-consecutive loads.\n"); }
            }
            slp_dbg_flush();
        }
        slp_register_nonvect_loads(vl);
        return TE_GATHER;
    }
    if is_cast_op(o) {
        let src: i32 = vals[op(vl0, 0)].ty;
        for v in vl {
            if is_poison(v) { continue; }
            let t: i32 = vals[op(v, 0)].ty;
            if t != src || !slp_is_valid_element_type(t) {
                if slp_dbg_on { errs("SLP: Gathering casts with different src types.\n"); slp_dbg_flush(); }
                return TE_GATHER;
            }
        }
        return TE_VECTORIZE;
    }
    if o == OP_ICMP || o == OP_FCMP {
        let p0 = inst_pred(vl0);
        let sp0 = slp_swapped_pred(p0);
        let ct: i32 = vals[op(vl0, 0)].ty;
        for v in vl {
            if is_poison(v) { continue; }
            if (inst_pred(v) != p0 && inst_pred(v) != sp0) || vals[op(v, 0)].ty as i32 != ct {
                if slp_dbg_on { errs("SLP: Gathering cmp with different predicate.\n"); slp_dbg_flush(); }
                return TE_GATHER;
            }
        }
        return TE_VECTORIZE;
    }
    if o == OP_SELECT || o == OP_FNEG || is_binary_op(o) || o == OP_FREEZE {
        // isFPVectorizationPotentiallyUnsafe is false on X86 and in the base TTI
        return TE_VECTORIZE;
    }
    if o == OP_GEP {
        for v in vl {
            if !is_inst_op(v, OP_GEP) { continue; }
            if nops(v) != 2 {
                if slp_dbg_on { errs("SLP: not-vectorizable GEP (nested indexes).\n"); slp_dbg_flush(); }
                return TE_GATHER;
            }
        }
        let ty0 = insts[inst_of(vl0)].ty2;
        for v in vl {
            if !slp_is_gep_operator(v) { continue; }
            if slp_gep_source_type(v) != ty0 {
                if slp_dbg_on { errs("SLP: not-vectorizable GEP (different types).\n"); slp_dbg_flush(); }
                return TE_GATHER;
            }
        }
        let ty1: i32 = vals[op(vl0, 1)].ty;
        for v in vl {
            if !is_inst_op(v, OP_GEP) { continue; }
            let x = op(v, 1);
            let ci = is_cint(x);
            if (!scatter_user && !ci) ||
               (vals[x].ty as i32 != ty1 && ((scatter_user && !ci) || tt_scalar_bits(vals[x].ty) > dl_ptr(slp_ptr_as(v)).idx)) {
                if slp_dbg_on { errs("SLP: not-vectorizable GEP (non-constant indexes).\n"); slp_dbg_flush(); }
                return TE_GATHER;
            }
        }
        return TE_VECTORIZE;
    }
    if o == OP_STORE {
        let sty: i32 = vals[op(vl0, 0)].ty;
        if dl_size_bits(sty) != dl_alloc_size(sty) * 8 {
            if slp_dbg_on { errs("SLP: Gathering stores of non-packed type.\n"); slp_dbg_flush(); }
            return TE_GATHER;
        }
        for v in vl {
            if !ld_is_simple(v) {
                if slp_dbg_on { errs("SLP: Gathering non-simple stores.\n"); slp_dbg_flush(); }
                return TE_GATHER;
            }
            ptrs.push(op(v, 1));
        }
        if slp_sort_ptr_accesses(ptrs, sty, order) {
            let p0 = if order.len == 0 { ptrs[0] } else { ptrs[order[0] as i64] };
            let pn = if order.len == 0 { ptrs[ptrs.len - 1] } else { ptrs[order[order.len - 1] as i64] };
            var calign = slp_ld_align(vl[0]);
            for v in vl { let a = slp_ld_align(v); if a < calign { calign = a; } }
            let ok, dist = slp_ptrs_diff(sty, p0, pn);
            if dist == vl.len - 1 { return TE_VECTORIZE; }
            // analyzeConstantStrideCandidate: no legal strided stores
            if slp_masked_stores_on() {
                let mc, svt = slp_is_masked_store_compress(vl, ptrs, order, calign, expand);
                if mc { return TE_EXPAND; }
            }
        }
        if slp_dbg_on { errs("SLP: Non-consecutive store.\n"); slp_dbg_flush(); }
        return TE_GATHER;
    }
    if o == OP_CALL {
        let ci = vl0;
        let id = laa_vector_intrinsic_id_for_call(ci);
        let mapped = slp_is_vf_mapped_call(ci);
        if !mapped && !is_trivially_vectorizable(id) {
            if slp_dbg_on { errs("SLP: Non-vectorizable call.\n"); slp_dbg_flush(); }
            return TE_GATHER;
        }
        if ty_is_struct(vals[ci].ty) { slp_fail("struct-returning calls in a bundle"); }
        let f = called_function(ci);
        let na = cb_nargs(ci);
        for v in vl {
            if !is_inst_op(v, OP_CALL) || called_function(v) != f || laa_vector_intrinsic_id_for_call(v) != id ||
               !slp_identical_bundle_schema(ci, v) {
                if slp_dbg_on { errs("SLP: mismatched calls:"); slp_dv(ci); errs("!="); slp_dv(v); errs("\n"); slp_dbg_flush(); }
                return TE_GATHER;
            }
            for j in na {
                if vu_scalar_op_at_arg(id, j, true) {
                    if cb_arg(v, j) != cb_arg(ci, j) {
                        if slp_dbg_on { errs("SLP: mismatched arguments in call:"); slp_dv(ci); errs(" argument "); errs_hex(cb_arg(ci, j) as u64); errs("!="); errs_hex(cb_arg(v, j) as u64); errs("\n"); slp_dbg_flush(); }
                        return TE_GATHER;
                    }
                }
            }
            if cb_nbundles(ci) > 0 && !slp_same_bundle_operands(ci, v) {
                if slp_dbg_on { errs("SLP: mismatched bundle operands in calls:"); slp_dv(ci); errs("!="); slp_dv(v); errs("\n"); slp_dbg_flush(); }
                return TE_GATHER;
            }
        }
        var argtys: i32[>..<] = [];
        slp_intrinsic_arg_types(ci, id, vl.len, 0, argtys);
        let vecty = slp_widened_type(vals[s.main].ty, vl.len);
        let ic, lc = slp_vector_call_costs(ci, vecty, argtys);
        if !tc_valid(ic) && !tc_valid(lc) { return TE_GATHER; }
        return TE_VECTORIZE;
    }
    if o == OP_SHUFFLEVECTOR {
        if !sis_is_alt_shuffle(s) {
            if slp_dbg_on { errs("SLP: ShuffleVector are not vectorized.\n"); slp_dbg_flush(); }
            return TE_GATHER;
        }
        return TE_VECTORIZE;
    }
    if slp_dbg_on { errs("SLP: Gathering unknown instruction.\n"); slp_dbg_flush(); }
    return TE_GATHER;
}
// CallBase::hasIdenticalOperandBundleSchema
fn slp_identical_bundle_schema(a: i32, b: i32) -> bool {
    let n = cb_nbundles(a);
    if n != cb_nbundles(b) { return false; }
    for k in n {
        if cb_bundle_tag(a, k) != cb_bundle_tag(b, k) || cb_bundle_begin(a, k) != cb_bundle_begin(b, k) ||
           cb_bundle_count(a, k) != cb_bundle_count(b, k) { return false; }
    }
    return true;
}

// ---------------------------------------------------------------- operands
// PHIHandler(DT, Main, Phis).buildOperands() into a new operand-list run
fn slp_phi_operands(main: i32, phis: const i32[:]) -> i32 {
    let ninc = phi_nincoming(main);
    let opl = slp_opl_new(ninc, phis.len);
    let pz = c_poison(vals[main].ty);
    if ninc <= 4 {
        for i in ninc {
            let inbb = phi_block(main, i);
            if !dt_has_node(DT_DOM, inbb) {
                for k in phis.len { opl_set(opl, i, k, pz); }
                continue;
            }
            for k in phis.len {
                let p = phis[k];
                if !is_inst_op(p, OP_PHI) { opl_set(opl, i, k, p); continue; }
                if phi_block(p, i) == inbb { opl_set(opl, i, k, phi_value(p, i)); }
                else { opl_set(opl, i, k, phi_value(p, phi_block_index(p, inbb))); }
            }
        }
        return opl;
    }
    // Blocks: MapVector<BasicBlock *, SmallVector<unsigned>>
    var bk: i32[>..<] = [];
    var bfirst: i64[>..<] = [];
    var bidx: i64[>..<] = [];     // incoming index -> block entry
    for i in ninc {
        let inbb = phi_block(main, i);
        bidx.push(-1);
        if !dt_has_node(DT_DOM, inbb) {
            for k in phis.len { opl_set(opl, i, k, pz); }
            continue;
        }
        var e: i64 = -1;
        for j in bk.len { if bk[j] == inbb { e = j; break; } }
        if e < 0 { e = bk.len; bk.push(inbb); bfirst.push(i); }
        bidx[i] = e;
    }
    for k in phis.len {
        let v = phis[k];
        if is_poison(v) {
            for i in ninc { opl_set(opl, i, k, v); }
            continue;
        }
        for i in phi_nincoming(v) {
            let inbb = phi_block(v, i);
            if inbb == phi_block(main, i) {
                let cur = opl_get(opl, i, k);
                if cur >= 0 && is_poison(cur) { continue; }
                opl_set(opl, i, k, phi_value(v, i));
                continue;
            }
            var e: i64 = -1;
            for j in bk.len { if bk[j] == inbb { e = j; break; } }
            if e < 0 { continue; }
            opl_set(opl, bfirst[e], k, phi_value(v, i));
        }
    }
    for e in bk.len {
        let basic = bfirst[e];
        for i in ninc {
            if bidx[i] != e || i == basic { continue; }
            for k in phis.len { opl_set(opl, i, k, opl_get(opl, basic, k)); }
        }
    }
    return opl;
}
// buildOriginalOperands(S, VL, Operands): (operand-list run, count)
fn slp_build_original_operands(s: SIS, vl: const i32[:]) -> i32, i64 {
    let shuffle_or_op = if sis_is_alt_shuffle(s) { OP_SHUFFLEVECTOR } else { sis_opcode(s) };
    let vl0 = s.main;
    let o = shuffle_or_op;
    let n = vl.len;
    if o == OP_PHI {
        let opl = slp_phi_operands(vl0, vl);
        return opl, nops(vl0);
    }
    if o == OP_EXTRACTVALUE && slp_check_evs_for_vec_calls(vl, s) { fatal("internal: SLP: unreachable"); }
    if o == OP_EXTRACTVALUE || o == OP_EXTRACTELEMENT {
        let opl = slp_opl_new(1, n);
        for k in n { opl_set(opl, 0, k, op(vl0, 0)); }
        return opl, 1;
    }
    if o == OP_INSERTVALUE || o == OP_INSERTELEMENT {
        let opl = slp_opl_new(2, n);
        for k in n { opl_set(opl, 0, k, op(vl[k], 0)); opl_set(opl, 1, k, op(vl[k], 1)); }
        return opl, 2;
    }
    if o == OP_LOAD {
        let opl = slp_opl_new(1, n);
        let pz = c_poison(vals[op(vl0, 0)].ty);
        for k in n { opl_set(opl, 0, k, if is_inst_op(vl[k], OP_LOAD) { op(vl[k], 0) } else { pz }); }
        return opl, 1;
    }
    if is_cast_op(o) || o == OP_ICMP || o == OP_FCMP || o == OP_FNEG || is_binary_op(o) || o == OP_FREEZE || o == OP_STORE ||
       o == OP_SHUFFLEVECTOR {
        let nop = nops(vl0);
        let opl = slp_opl_new(nop, n);
        for k in n {
            let v = vl[k];
            if !is_inst(v) {
                for j in nop { opl_set(opl, j, k, c_poison(vals[op(vl0, j)].ty)); }
                continue;
            }
            let sel, a, b = slp_convert_to(v, s);
            if slp_is_binop(v) { opl_set(opl, 0, k, a); opl_set(opl, 1, k, b); }
            else { for j in nop { opl_set(opl, j, k, op(v, j)); } }
        }
        return opl, nop;
    }
    if o == OP_SELECT {
        let nop = nops(vl0);
        let opl = slp_opl_new(nop, n);
        for k in n {
            let v = vl[k];
            if !is_inst(v) {
                for j in nop { opl_set(opl, j, k, c_poison(vals[op(vl0, j)].ty)); }
                continue;
            }
            if iop(v) == OP_ZEXT {
                opl_set(opl, 0, k, op(v, 0));
                opl_set(opl, 1, k, c_int(vals[v].ty, 1));
                opl_set(opl, 2, k, c_null(vals[v].ty));
                continue;
            }
            let sel, a, b = slp_convert_to(v, s);
            if slp_is_binop(v) { opl_set(opl, 0, k, a); opl_set(opl, 1, k, b); }
            else { for j in nop { opl_set(opl, j, k, op(v, j)); } }
        }
        return opl, nop;
    }
    if o == OP_GEP {
        let opl = slp_opl_new(2, n);
        let vl0ty: i32 = vals[op(vl0, 1)].ty;
        var same = true;
        for v in vl { if is_inst_op(v, OP_GEP) && vals[op(v, 1)].ty as i32 != vl0ty { same = false; break; } }
        let ty = if same { vl0ty } else { ty_int(dl_ptr(slp_ptr_as(op(vl0, 0))).idx) };
        for k in n {
            let v = vl[k];
            if !is_inst_op(v, OP_GEP) {
                opl_set(opl, 0, k, v);
                opl_set(opl, 1, k, c_null(ty));
                continue;
            }
            opl_set(opl, 0, k, op(v, 0));
            let x = op(v, 1);
            if is_cint(x) {
                let a = ap_from_cint(x);
                let w = ty_bits(ty);
                let r = if ap_is_neg(a) { ap_sext_or_trunc(a, w) } else { ap_zext_or_trunc(a, w) };
                opl_set(opl, 1, k, ap_to_cint(ty, r));
            } else {
                opl_set(opl, 1, k, x);
            }
        }
        return opl, 2;
    }
    if o == OP_CALL {
        let ci = vl0;
        let id = laa_vector_intrinsic_id_for_call(ci);
        var nv: i64 = 0;
        for j in cb_nargs(ci) { if !vu_scalar_op_at_arg(id, j, true) { nv++; } }
        let opl = slp_opl_new(nv, n);
        var li: i64 = 0;
        for j in cb_nargs(ci) {
            if vu_scalar_op_at_arg(id, j, true) { continue; }
            for k in n {
                let v = vl[k];
                opl_set(opl, li, k, if is_inst(v) { op(v, j) } else { c_poison(vals[op(vl0, j)].ty) });
            }
            li++;
        }
        return opl, nv;
    }
    fatal("internal: SLP: unexpected vectorization of the instructions");
    return 0, 0;
}

// ---------------------------------------------------------------- InstructionsCompatibilityAnalysis
fn slp_ica_supported_opcode(o: i64) -> bool {
    return o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_ASHR || o == OP_LSHR || o == OP_SHL || o == OP_SDIV || o == OP_UDIV ||
           o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_FADD || o == OP_FSUB || o == OP_FMUL || o == OP_FDIV;
}
// findAndSetMainInstruction(VL, R): the MainOp (-1 = none)
fn slp_ica_find_main(vl: const i32[:]) -> i32 {
    var parent: i32 = -1;
    sh_clear(SH_TMP1);   // Operands
    // Candidates: MapVector<opcode, instructions>
    var ck: i64[>..<] = [];
    var cl: i32[>..<] = [];    // (key index, inst) pairs in insertion order
    var cli: i64[>..<] = [];
    var any_undef = false;
    fn add_ops(i: i32) { for k in nops(i) { sh_add(SH_TMP1, op(i, k) as i64, 0); } }
    fn add_cand(i: i32) {
        var e: i64 = -1;
        for j in ck.len { if ck[j] == iop(i) { e = j; break; } }
        if e < 0 { e = ck.len; ck.push(iop(i)); }
        cli.push(e);
        cl.push(i);
    }
    for v in vl {
        if !is_inst(v) { any_undef = any_undef || is_undef_or_poison(v); continue; }
        if !dt_has_node(DT_DOM, inst_parent(v)) { continue; }
        if ck.len == 0 {
            add_cand(v);
            parent = inst_parent(v);
            add_ops(v);
            continue;
        }
        if parent == inst_parent(v) {
            add_cand(v);
            add_ops(v);
            continue;
        }
        let da = dt_dfs_in(slp_fn, DT_DOM, parent);
        let db = dt_dfs_in(slp_fn, DT_DOM, inst_parent(v));
        if da < db {
            ck.clear(); cl.clear(); cli.clear();
            add_cand(v);
            parent = inst_parent(v);
            sh_clear(SH_TMP1);
            add_ops(v);
        }
    }
    fn supported(i: i32) -> bool {
        if any_undef && (slp_is_int_div_rem(iop(i)) || slp_is_fp_div_rem(iop(i)) || iop(i) == OP_CALL) { return false; }
        return slp_ica_supported_opcode(iop(i)) && (!slp_does_not_need_to_be_scheduled(i) || !slp_is_vectorized(i));
    }
    var best_n: i64 = 0;
    var main: i32 = -1;
    var used_outside = false;
    for e in ck.len {
        var pn: i64 = 0;
        var pused = true;
        var first: i32 = -1;
        var inner = false;
        for k in cl.len {
            if cli[k] != e { continue; }
            pn++;
            if first < 0 { first = cl[k]; }
            if !slp_is_used_outside_block(cl[k]) { pused = false; }
            if sh_has(SH_TMP1, cl[k] as i64, 0) { inner = true; }
        }
        if used_outside && !pused { continue; }
        if !used_outside && pused { best_n = 0; }
        if pn < best_n { continue; }
        if !pused && inner { continue; }
        if pn == best_n && main >= 0 && slp_is_binop(main) {
            let i = first;
            let m0 = op(main, 0);
            let m1 = op(main, 1);
            if is_inst(m0) && iop(m0) == iop(i) && inst_parent(m0) == inst_parent(i) { continue; }
            if is_inst(m1) && iop(m1) == iop(i) && inst_parent(m1) == inst_parent(i) { continue; }
        }
        used_outside = pused;
        for k in cl.len {
            if cli[k] != e { continue; }
            if supported(cl[k]) { main = cl[k]; best_n = pn; break; }
        }
    }
    if main >= 0 {
        for v in vl { if is_inst(v) && inst_parent(v) == inst_parent(main) && is_terminator(v) { return -1; } }
    }
    return main;
}
// getOperands(S, V) of a lane: (a, b)
fn slp_ica_lane_operands(s: SIS, v: i32, main: i32) -> i32, i32 {
    if is_poison(v) { return v, v; }
    if !sis_is_copyable_element(s, v) {
        let sel, a, b = slp_convert_to(v, s);
        if slp_is_binop(v) { return a, b; }
        return op(v, 0), op(v, 1);
    }
    return v, binop_identity(iop(main), vals[main].ty, !slp_inst_is_commutative(main));
}
// buildOperands(S, VL): (operand-list run, count)
fn slp_build_operands(s: SIS, vl: const i32[:]) -> i32, i64 {
    if !s.copy { return slp_build_original_operands(s, vl); }
    let main = s.main;
    let commutative = slp_is_commutative(main) && nops(main) == 2;
    let nop = nops(main);
    let opl = slp_opl_new(nop, vl.len);
    for k in vl.len {
        let a, b = slp_ica_lane_operands(s, vl[k], main);
        opl_set(opl, 0, k, a);
        if nop > 1 { opl_set(opl, 1, k, b); }
    }
    if commutative {
        fn can_swap(v: i32) -> bool { slp_is_commutative_vu(sis_matching(s, v), v, false) }
        // PairCounts: MapVector<(min id, max id), (fwd, rev)>
        var pk0: i64[>..<] = [];
        var pk1: i64[>..<] = [];
        var pf: i64[>..<] = [];
        var pr: i64[>..<] = [];
        for k in vl.len {
            let v = vl[k];
            if sis_is_copyable_element(s, v) || is_poison(v) { continue; }
            let id0 = slp_value_id(opl_get(opl, 0, k));
            let id1 = slp_value_id(opl_get(opl, 1, k));
            if id0 == id1 { continue; }
            let mn = if id0 < id1 { id0 } else { id1 };
            let mx = if id0 < id1 { id1 } else { id0 };
            var e: i64 = -1;
            for j in pk0.len { if pk0[j] == mn && pk1[j] == mx { e = j; break; } }
            if e < 0 { e = pk0.len; pk0.push(mn); pk1.push(mx); pf.push(0); pr.push(0); }
            if id0 < id1 { pf[e] += 1; } else { pr[e] += 1; }
        }
        var best: i64 = 0;
        var maj0: i64 = 0;
        var maj1: i64 = 0;
        for j in pk0.len {
            let t = pf[j] + pr[j];
            if t > best {
                best = t;
                if pf[j] >= pr[j] { maj0 = pk0[j]; maj1 = pk1[j]; } else { maj0 = pk1[j]; maj1 = pk0[j]; }
            }
        }
        var lat0: i64 = 0;
        var lat1: i64 = 0;
        var total: i64 = 0;
        for k in vl.len {
            let v = vl[k];
            if sis_is_copyable_element(s, v) || is_poison(v) { continue; }
            if best > 0 {
                let id0 = slp_value_id(opl_get(opl, 0, k));
                let id1 = slp_value_id(opl_get(opl, 1, k));
                if id0 == maj1 && id1 == maj0 && can_swap(v) { opl_swap(opl, 0, 1, k); }
            }
            total++;
            if is_inst_op(opl_get(opl, 0, k), OP_LOAD) { lat0++; }
            if is_inst_op(opl_get(opl, 1, k), OP_LOAD) { lat1++; }
        }
        if total > 1 && lat1 > lat0 && lat1 * 2 > total {
            for k in vl.len {
                let v = vl[k];
                if sis_is_copyable_element(s, v) || is_poison(v) { continue; }
                if !is_inst_op(opl_get(opl, 0, k), OP_LOAD) && is_inst_op(opl_get(opl, 1, k), OP_LOAD) && can_swap(v) { opl_swap(opl, 0, 1, k); }
            }
        }
    }
    return opl, nop;
}
// the first value of each of the first two original operand lists of a single instruction: (count, a, b)
fn slp_orig_ops1(s: SIS, i: i32) -> i64, i32, i32 {
    let one: i32[1] = [i];
    let opl, n = slp_build_original_operands(s, one[..]);
    var a: i32 = -1;
    var b: i32 = -1;
    if n >= 1 { a = opl_get(opl, 0, 0); }
    if n >= 2 { b = opl_get(opl, 1, 0); }
    return n, a, b;
}
// isCopyablePreferable(VL, R, S, CopyableS) with the analysis' MainOp `mainop`
fn slp_ica_copyable_preferable(vl: const i32[:], s: SIS, cs: SIS, mainop: i32) -> bool {
    var all_vect = true;
    for v in vl { if !(is_poison(v) || slp_is_vectorized(v)) { all_vect = false; break; } }
    if all_vect { return false; }
    var smain = s.main;
    let salt: i32 = if sis_is_alt_shuffle(s) { s.alt } else { -1 };
    let is_comm = slp_is_commutative(smain);
    let is_alt_comm = if sis_is_alt_shuffle(s) { slp_is_commutative(salt) } else { false };
    let is_main_comm = slp_is_commutative(mainop);
    var on, o0, o1 = slp_orig_ops1(s, smain);
    if on != 2 { return false; }
    fn check_operands(o: i32, smainop: i32) -> bool {
        if !slp_is_binop(o) { return false; }
        if !slp_is_binop(smainop) { return true; }
        for k in nops(o) { let x = op(o, k); if is_inst(x) && iop(x) == iop(smainop) { return true; } }
        return false;
    }
    sh_clear(SH_TMP2);   // Operands
    for v in vl {
        if !is_inst(v) || v == smain { continue; }
        if sis_matching(s, v) != smain { continue; }
        let vn, v0, v1 = slp_orig_ops1(s, v);
        for k in nops(v) { sh_add(SH_TMP2, op(v, k) as i64, 0); }
        if check_operands(v0, o0) || check_operands(v1, o1) || (is_comm && (check_operands(v0, o1) || check_operands(v1, o0))) {
            smain = v;
            o0 = v0;
            o1 = v1;
            break;
        }
    }
    let mn, m0, m1 = slp_orig_ops1(s, mainop);
    fn find_best(ca: const i32[:], cb: const i32[:]) -> i64, bool, i64 {
        let idx, sc0 = slp_find_best_root_pair(ca, cb, LA_FAIL);
        var score = sc0;
        var res = idx;
        let i0 = if idx >= 0 { idx } else { 0 };
        var is_const = sc0 == LA_CONSTANTS && slp_is_constant(ca[i0]) && slp_is_constant(cb[i0]);
        if is_const {
            for k in ca.len {
                if !slp_is_constant(ca[k]) && !slp_is_constant(cb[k]) && cb[k] == ca[k] {
                    res = k;
                    is_const = false;
                    score = if is_inst_op(ca[k], OP_LOAD) { LA_SPLAT_LOADS } else { LA_SPLAT };
                    break;
                }
            }
        }
        return res, is_const, score;
    }
    for v in vl {
        if !is_inst(v) || (v == mainop && (!sis_is_alt_shuffle(s) || v == smain)) || (!sis_is_alt_shuffle(s) && v == smain) { continue; }
        let vn, v0, v1 = slp_orig_ops1(s, if v == smain { mainop } else { v });
        let c0, c1 = slp_ica_lane_operands(cs, if v == mainop { smain } else { v }, mainop);
        if 2 == vn && c0 == v0 && c1 == v1 { continue; }
        var ca: i32[>..<] = [];
        var cb: i32[>..<] = [];
        // BuildFirstOperandCandidates(MainOps, CopyableOps[0], CopyableOps[1], IsMainCommutative)
        ca.push(m0); cb.push(c0);
        if is_main_comm { ca.push(m0); cb.push(c1); }
        let opsize = ca.len;
        let matching = if sis_matching(s, v) == s.main { smain } else { salt };
        let comm_inst = (if matching == smain { is_comm } else { is_alt_comm }) || slp_is_commutative_vu(v, matching, false);
        if sis_is_alt_shuffle(s) && matching == salt {
            if (slp_is_binop(v0) && sh_has(SH_TMP2, v0 as i64, 0)) || (slp_is_binop(v1) && sh_has(SH_TMP2, v1 as i64, 0)) { return false; }
        }
        if sis_is_alt_shuffle(s) && matching == smain { for k in nops(v) { sh_add(SH_TMP2, op(v, k) as i64, 0); } }
        ca.push(o0); cb.push(v0);
        if comm_inst { ca.push(o0); cb.push(v1); }
        let best_op, best_const, score = find_best(ca, cb);
        let orig_better = (if best_op >= 0 { best_op } else { opsize }) >= opsize;
        ca.clear(); cb.clear();
        // BuildSecondOperandCandidates(MainOps, PrevBestIdx, CopyableOps[0], CopyableOps[1], IsMainCommutative)
        let pb1: i64 = if orig_better { -1 } else { best_op };
        if pb1 != 1 { ca.push(m1); cb.push(c1); }
        if pb1 != 0 && is_main_comm { ca.push(m1); cb.push(c0); }
        let sec_size = ca.len;
        let pb2: i64 = if orig_better { (if best_op >= 0 { best_op } else { opsize - 1 }) - opsize } else { -1 };
        if pb2 != 1 { ca.push(o1); cb.push(v1); }
        if pb2 != 0 && comm_inst { ca.push(o1); cb.push(v0); }
        let sbest, sbest_const, sscore = find_best(ca, cb);
        if best_op < 0 && sbest < 0 { return false; }
        let sorig_better = (if sbest >= 0 { sbest } else { sec_size }) >= sec_size;
        if orig_better && sorig_better { return false; }
        if best_op < 0 && sorig_better { return false; }
        if sbest < 0 && orig_better { return false; }
        if !orig_better && best_const && sorig_better && !sbest_const { return false; }
        if best_op >= 0 && orig_better && !best_const && !sorig_better && sbest_const { return false; }
        if ((score > sscore || (score <= LA_ALT_OPCODES && score == sscore)) && orig_better) ||
           (sorig_better && (sscore > score || (score <= LA_ALT_OPCODES && score == sscore))) { return false; }
    }
    return true;
}
// buildInstructionsState(VL, R, WithProfitabilityCheck, SkipSameCodeCheck)
fn slp_build_instructions_state(vl: const i32[:], with_prof: bool, skip_same: bool) -> SIS {
    let s, done, origs, mainop = slp_bis_core(vl, skip_same);
    if done || !with_prof { return s; }
    // the profitability of the copyable state
    // (the scratch operand lists stay in the tree pools until deleteTree)
    let opl, nop = slp_build_operands(s, vl);
    fn restore() { }
    fn build_cands(ca: i32[>..<]&, cb: i32[>..<]&, v1: i32, v2: i32) {
        if v1 != v2 && is_inst_op(v1, OP_PHI) { return; }
        let i1 = is_inst(v1);
        let i2 = is_inst(v2);
        if i1 && i2 && iop(v1) == iop(v2) && inst_parent(v1) != inst_parent(v2) { return; }
        ca.push(v1);
        cb.push(if i1 || i2 { v2 } else { v1 });
    }
    if vl.len == 2 {
        var a1: i32[>..<] = [];
        var b1: i32[>..<] = [];
        var a2: i32[>..<] = [];
        var b2: i32[>..<] = [];
        build_cands(a1, b1, opl_get(opl, 0, 0), opl_get(opl, 0, 1));
        build_cands(a2, b2, opl_get(opl, 1, 0), opl_get(opl, 1, 1));
        fn pair_ok(ca: const i32[:], cb: const i32[:]) -> bool { let i, sc = slp_find_best_root_pair(ca, cb, LA_FAIL); return i >= 0; }
        var res = a1.len > 0 && a2.len > 0 && pair_ok(a1, b1) && pair_ok(a2, b2);
        if !res && slp_is_commutative(mainop) {
            a1.clear(); b1.clear(); a2.clear(); b2.clear();
            build_cands(a1, b1, opl_get(opl, 0, 0), opl_get(opl, 1, 1));
            build_cands(a2, b2, opl_get(opl, 1, 0), opl_get(opl, 0, 1));
            res = a1.len > 0 && a2.len > 0 && pair_ok(a1, b1) && pair_ok(a2, b2);
        }
        restore();
        if !res { return origs; }
        let sc = tv_inst_cost(s.main, TCK_RECIP_THROUGHPUT);
        let vecty = slp_widened_type(vals[s.main].ty, vl.len);
        let mo = iop(mainop);
        if !slp_ica_supported_opcode(mo) { fatal("internal: SLP: unexpected instruction"); }
        let vc = tv_arith0(mo, vecty, TCK_RECIP_THROUGHPUT);
        if vc > sc { return origs; }
        return s;
    }
    var ncopy: i64 = 0;
    for v in vl { if sis_is_copyable_element(s, v) { ncopy++; } }
    if ncopy < vl.len / 2 { restore(); return s; }
    let lim = vl.len / 24;
    if ncopy >= vl.len - lim || (ncopy >= vl.len - 1 && vl.len > 4) || ncopy >= 128 {
        var all = true;
        for v in vl { if !(is_inst_op(v, OP_PHI) || !sis_is_copyable_element(s, v)) { all = false; break; } }
        if all { restore(); return origs; }
    }
    if slp_is_commutative(mainop) {
        var best_front: i32 = -1;
        for k in vl.len {
            let ol = opl_get(opl, 0, k);
            let orr = opl_get(opl, nop - 1, k);
            if !is_inst(ol) && is_inst(orr) {
                best_front = orr;
                opl_set(opl, 0, k, orr); opl_set(opl, nop - 1, k, ol);
                continue;
            }
            if (is_constant(ol) && !slp_m_zero(orr)) || slp_m_zero(ol) {
                if is_inst(orr) { best_front = orr; }
                opl_set(opl, 0, k, orr); opl_set(opl, nop - 1, k, ol);
                continue;
            }
            if is_inst(ol) { best_front = ol; }
        }
        if best_front >= 0 && is_inst(best_front) {
            let bo = iop(best_front);
            for k in vl.len {
                let orr = opl_get(opl, nop - 1, k);
                if !is_inst(orr) { continue; }
                if iop(orr) == bo { let ol = opl_get(opl, 0, k); opl_set(opl, 0, k, orr); opl_set(opl, nop - 1, k, ol); }
            }
        }
    }
    var ninst: i64 = 0;
    for v in opl_list(opl, nop - 1) { if is_inst(v) { ninst++; } }
    if ninst > 1 { restore(); return origs; }
    // CheckOperand(Operands.front())
    var ok = false;
    {
        var front: i32[>..<] = [];
        for v in opl_list(opl, 0) { front.push(v); }
        if slp_all_constant(front) || slp_is_splat(front) {
            ok = true;
        } else {
            if front.len >= 4 {
                var cv: i32[>..<] = [];
                var cc: i64[>..<] = [];
                for v in front {
                    if is_undef_or_poison(v) { continue; }
                    var e: i64 = -1;
                    for j in cv.len { if cv[j] == v { e = j; break; } }
                    if e < 0 { cv.push(v); cc.push(1); } else { cc[e] += 1; }
                }
                if cv.len == 2 && (cc[0] == 1 || cc[1] == 1) { ok = true; }
            }
            if !ok {
                restore();
                let os, d2, o2, m2 = slp_bis_core(front, false);
                if !sis_valid(os) || (sis_opcode(os) == OP_PHI && !slp_all_same_block(front)) {
                    ok = false;
                } else {
                    var cn: i64 = 0;
                    for v in front { if sis_is_copyable_element(os, v) { cn++; } }
                    ok = cn <= vl.len / 2;
                }
            }
        }
    }
    restore();
    if !ok { return origs; }
    return s;
}
fn slp_m_zero(v: i32) -> bool {
    // m_Zero: a null value (scalar or vector)
    return is_constant(v) && is_null_value(v);
}
// the part of buildInstructionsState without the profitability check: (S, done, OrigS, MainOp); done = the
// result is final (not a fresh copyable state)
fn slp_bis_core(vl: const i32[:], skip_same: bool) -> SIS, bool, SIS, i32 {
    var s = if skip_same || !slp_all_same_block(vl) { sis_invalid() } else { slp_get_same_opcode(vl) };
    if !sis_valid(s) && slp_all_same_block(vl) {
        var sel: i32 = -1;
        var all = true;
        for v in vl {
            if is_inst_op(v, OP_SELECT) { if sel < 0 { sel = v; } continue; }
            if (is_inst_op(v, OP_ZEXT) && ty_is_int(vals[op(v, 0)].ty) && ty_bits(vals[op(v, 0)].ty) == 1) || is_poison(v) { continue; }
            all = false;
            break;
        }
        if all && sel >= 0 { return SIS { main: sel, alt: sel, copy: false }, true, sis_invalid(), -1; }
    }
    if sis_valid(s) && sis_is_alt_shuffle(s) {
        let sty: i32 = vals[s.main].ty;
        let vecty = slp_widened_type(sty, vl.len);
        var mask: bool[>..<] = [];
        slp_alt_instr_mask(vl, sty, sis_alt_opcode(s), mask);
        if slp_tti_legal_alt_instr(vecty, sis_opcode(s), sis_alt_opcode(s), mask) { return s, true, sis_invalid(), -1; }
    } else if sis_valid(s) {
        var simple = !slp_copyable_on() || !slp_is_binop(s.main);
        if !simple {
            simple = true;
            for v in vl {
                if !is_inst(v) { continue; }
                if !(iop(v) == sis_opcode(s) || (sis_opcode(s) == OP_ADD && iop(v) == OP_SHL)) { simple = false; break; }
            }
        }
        if simple { return s, true, sis_invalid(), -1; }
    }
    if !slp_copyable_on() { return s, true, sis_invalid(), -1; }
    let mainop = slp_ica_find_main(vl);
    if mainop < 0 { return s, true, sis_invalid(), -1; }
    let origs = s;
    let cs = SIS { main: mainop, alt: mainop, copy: true };
    if sis_valid(origs) && !slp_ica_copyable_preferable(vl, origs, cs, mainop) { return origs, true, sis_invalid(), -1; }
    return cs, false, origs, mainop;
}

// ---------------------------------------------------------------- tryToFindDuplicates
// tryToFindDuplicates(VL, ReuseShuffleIndices, TTI, TLI, S, UserTreeIdx, R, BuildGatherOnly): (ok, new VL run, n,
// reuse run, n)
fn slp_try_to_find_duplicates(vl: const i32[:], s: SIS, ui_te: i32, build_gather_only: bool) -> bool, i32, i64, i32, i64 {
    let vl_at = slp_vrun(vl);
    let none_r = slp_ip.len as i32;
    if ty_is_struct(slp_value_type(vl[0], false)) {
        if slp_dbg_on { errs("SLP: struct type in bundle.\n"); slp_dbg_flush(); }
        return true, vl_at, vl.len, none_r, 0;
    }
    var uniq: i32[>..<] = [];
    var reuse: i32[>..<] = [];
    sh_clear(SH_TMP0);   // UniquePositions
    var npos: i64 = 0;
    for v in vl {
        if slp_is_constant(v) {
            reuse.push(if is_poison(v) { -1 } else { uniq.len as i32 });
            uniq.push(v);
            continue;
        }
        let p = sh_get(SH_TMP0, v as i64, 0, -1);
        if p >= 0 { reuse.push(p as i32); continue; }
        sh_set(SH_TMP0, v as i64, 0, uniq.len);
        npos++;
        reuse.push(uniq.len as i32);
        uniq.push(v);
    }
    let req_sched = sis_valid(s) && sis_opcode(s) != OP_PHI && !slp_is_vector_like_inst_with_const_ops(s.main) &&
                    (s.copy || !slp_does_not_need_to_schedule(uniq));
    let all_nonconst = npos == uniq.len;
    if req_sched {
        var e = uniq.len;
        while e > 0 && is_poison(uniq[e - 1]) { e--; }
        uniq.resize(e);
    }
    let nuniq = uniq.len;
    if nuniq == vl.len { return true, vl_at, vl.len, none_r, 0; }
    if vl.len == 4 && nuniq == 3 && !build_gather_only && !(sis_valid(s) && (sis_opcode(s) == OP_LOAD || sis_opcode(s) == OP_PHI)) {
        return true, vl_at, vl.len, none_r, 0;
    }
    // EstimatePackPlusShuffleVsInserts()
    var pack = false;
    var use_orig = false;
    block {
        var only_simple = true;
        for v in uniq { if !(is_undef_or_poison(v) || is_inst(v) || is_arg(v)) { only_simple = false; break; } }
        if npos == 1 && (nuniq == 1 || only_simple) { pack = false; use_orig = false; break; }
        if build_gather_only && vl.len > 4 && slp_is_pow2(vl.len) && !slp_is_pow2(nuniq) && npos * 2 < nuniq {
            pack = false; use_orig = false; break;
        }
        fn check_loads(loads: const i32[:], include_gather: bool) -> bool {
            var o: i32[>..<] = [];
            var p: i32[>..<] = [];
            let r = slp_can_vectorize_loads(loads, s.main, o, p, false, true);
            return (include_gather && r == LS_GATHER) || r == LS_SCATTER || r == LS_STRIDED || r == LS_COMPRESS;
        }
        let is_root_operand = ui_te >= 0 && ui_te == 0 && !build_gather_only;
        if is_root_operand {
            if sis_valid(s) && sis_opcode(s) == OP_LOAD {
                var ident = true;
                for k in reuse.len { if reuse[k] as i64 != k { ident = false; break; } }
                let uo = (check_loads(uniq, true) && check_loads(vl, false)) || ident;
                pack = true; use_orig = uo; break;
            }
            pack = true; use_orig = !req_sched; break;
        }
        var dem: bool[>..<] = [];
        for k in vl.len { dem.push(false); }
        for k in reuse.len {
            let r = reuse[k];
            if r != -1 && sh_has(SH_TMP0, uniq[r as i64] as i64, 0) { dem[k] = true; }
        }
        let sty = slp_value_type(uniq[0], false);
        let vecty = slp_widened_type(sty, vl.len);
        let uvecty = slp_widened_type(sty, nuniq);
        let np = slp_number_of_parts(vecty, sty, 0x7FFFFFFFFFFFFFFF);
        let unp = slp_number_of_parts(uvecty, sty, 0x7FFFFFFFFFFFFFFF);
        if !req_sched {
            if vl.len / nuniq == 1 && (np <= 1 || unp >= np) { pack = true; use_orig = true; break; }
            if sis_valid(s) && sis_opcode(s) == OP_PHI && nuniq > 1 && unp <= np { pack = true; use_orig = false; break; }
        }
        let rc = slp_shuffle_cost(SK_PERMUTESINGLESRC, vecty, if nuniq > vl.len / 2 { slp_no_mask() } else { reuse[..] }, 0, uvecty);
        if sis_valid(s) && !build_gather_only {
            let one_dup = sis_opcode(s) != OP_LOAD && nuniq + 1 == vl.len;
            let mostly = nuniq * 2 > vl.len;
            let half = nuniq * 2 == vl.len && (sis_opcode(s) == OP_GEP || (is_cast_op(iop(s.main)) && !sis_is_alt_shuffle(s)));
            let thr = np * (if vl.len > 4 { 1 } else { 2 });
            if one_dup || ((mostly || half) && rc > thr) { pack = true; use_orig = true; break; }
        }
        if sis_valid(s) && sis_opcode(s) == OP_LOAD {
            let uv = check_loads(uniq, false);
            if uv || check_loads(vl, false) { pack = true; use_orig = !uv; break; }
        }
        let skip_bv = (!build_gather_only && !req_sched) || slp_has_same_node(s, vl);
        let ins_cost = if skip_bv { TCC_FREE } else { slp_scalarization_overhead(sty, vecty, dem, true, false, all_nonconst) };
        var udem: bool[>..<] = [];
        for v in uniq { udem.push(!slp_is_constant(v)); }
        var ucost = if skip_bv { TCC_FREE } else { slp_scalarization_overhead(sty, uvecty, udem, true, false, all_nonconst) };
        ucost = tc_add(ucost, rc);
        if ucost <= ins_cost { pack = true; use_orig = false; break; }
        let diff = tc_sub(ucost, ins_cost);
        if diff < TCC_EXPENSIVE || (slp_te.len == 0 && slp_uil_on && diff == TCC_EXPENSIVE) {
            pack = sis_valid(s) && (!sis_is_alt_shuffle(s) || !build_gather_only);
            use_orig = false;
            break;
        }
        let keep = !build_gather_only && !req_sched;
        pack = keep; use_orig = keep;
    }
    if pack {
        if use_orig { return true, vl_at, vl.len, none_r, 0; }
        if slp_dbg_on { errs("SLP: Shuffle for reused scalars.\n"); slp_dbg_flush(); }
        let u_at = slp_vrun(uniq);
        let r_at = slp_irun(reuse);
        return true, u_at, uniq.len, r_at, reuse.len;
    }
    if slp_dbg_on { errs("SLP: Scalar used twice in bundle.\n"); slp_dbg_flush(); }
    return false, vl_at, vl.len, none_r, 0;
}

// ---------------------------------------------------------------- split nodes
// getMainAltOpsNoStateVL(VL)
fn slp_main_alt_no_state(vl: const i32[:]) -> i32, i32 {
    var main: i32 = -1;
    var alt: i32 = -1;
    for v in vl {
        if is_poison(v) { continue; }
        if !is_inst(v) { return -1, -1; }
        if main < 0 { main = v; continue; }
        if iop(main) == iop(v) { if inst_parent(v) != inst_parent(main) { return -1, -1; } continue; }
        if alt < 0 { alt = v; continue; }
        if iop(alt) == iop(v) { if inst_parent(v) != inst_parent(alt) { return -1, -1; } continue; }
        return -1, -1;
    }
    if alt < 0 { return -1, -1; }
    return main, alt;
}
// canBuildSplitNode(VL, LocalState, Op1, Op2, ReorderIndices): (ok, op1 run, n1, op2 run, n2, reorder run, nreorder)
fn slp_can_build_split_node(vl: const i32[:], ls: SIS) -> bool, i32, i64, i32, i64, i32, i64 {
    if vl.len <= 4 || slp_tti_prefer_alternate_opcode_vectorization() || !slp_split_alternate_on() { return false, 0, 0, 0, 0, 0, 0; }
    if ty_is_struct(slp_value_type(vl[0], false)) { return false, 0, 0, 0, 0, 0, 0; }
    if slp_dbg_on { errs("SLP: \tChecking bundle: "); slp_dv(ls.main); errs(".\n"); slp_dbg_flush(); }
    var c = slp_lk_head(SH_SPLIT, ls.main as i64);
    while c >= 0 {
        let e = slp_lk[c].x;
        c = slp_lk[c].next;
        if te_is_same(e, vl) {
            if slp_dbg_on { errs("SLP: Perfect diamond merge at "); slp_dv(ls.main); errs(".\n"); slp_dbg_flush(); }
            return false, 0, 0, 0, 0, 0, 0;
        }
        var all = true;
        for v in vl {
            if is_poison(v) { continue; }
            var found = false;
            for x in te_scalars(e) { if x == v { found = true; break; } }
            if !found { all = false; break; }
        }
        if all {
            if slp_dbg_on { errs("SLP: Gathering due to full overlap.\n"); slp_dbg_flush(); }
            return false, 0, 0, 0, 0, 0, 0;
        }
    }
    var reord: i32[>..<] = [];
    for k in vl.len { reord.push(vl.len as i32); }
    var op1: i32[>..<] = [];
    var op2: i32[>..<] = [];
    var in1: bool[>..<] = [];
    for k in vl.len { in1.push(false); }
    for k in vl.len {
        let v = vl[k];
        if !is_inst(v) { op1.push(v); in1[k] = true; continue; }
        if (sis_alt_opcode(ls) != sis_opcode(ls) && slp_is_main_instruction(v, ls.main, ls.alt)) ||
           (sis_alt_opcode(ls) == sis_opcode(ls) && !slp_is_alternate_instruction(v, ls.main, ls.alt)) {
            op1.push(v); in1[k] = true; continue;
        }
        op2.push(v);
    }
    let sty = slp_value_type(vl[0], false);
    let vecty = slp_widened_type(sty, vl.len);
    let o0 = sis_opcode(ls);
    let o1 = sis_alt_opcode(ls);
    var omask: bool[>..<] = [];
    slp_alt_instr_mask(vl, sty, o1, omask);
    fn n_unique(xs: const i32[:]) -> i64 {
        var u: i32[>..<] = [];
        for x in xs { var seen = false; for y in u { if y == x { seen = true; break; } } if !seen { u.push(x); } }
        return u.len;
    }
    if n_unique(op1) <= 1 || n_unique(op2) <= 1 || slp_tti_legal_alt_instr(vecty, o0, o1, omask) { return false, 0, 0, 0, 0, 0, 0; }
    var c1: i64 = 0;
    var c2: i64 = op1.len;
    for k in vl.len {
        if in1[k] { reord[c1] = k as i32; c1++; } else { reord[c2] = k as i32; c2++; }
    }
    var ident = true;
    for k in reord.len { if !(reord[k] as i64 == k || reord[k] as i64 == reord.len) { ident = false; break; } }
    if ident {
        reord.clear();
    } else if slp_has_full_vectors_or_pow2(vals[op1[0]].ty, vl.len) &&
              (!slp_has_full_vectors_or_pow2(vals[op1[0]].ty, op1.len) || !slp_has_full_vectors_or_pow2(vals[op2[0]].ty, op2.len)) {
        return false, 0, 0, 0, 0, 0, 0;
    }
    var mask: i32[>..<] = [];
    if reord.len > 0 { slp_inverse_permutation(reord, mask); }
    let np = slp_tti_number_of_parts(vecty);
    let op1vt = slp_widened_type(sty, op1.len);
    let op2vt = slp_widened_type(sty, op2.len);
    if np >= vl.len { return false, 0, 0, 0, 0, 0, 0; }
    let ins = slp_shuffle_cost(SK_INSERTSUBVECTOR, vecty, slp_no_mask(), op1.len, op2vt);
    let subvt = slp_widened_type(sty, if op1.len > op2.len { op1.len } else { op2.len });
    let nsc = slp_shuffle_cost(SK_PERMUTETWOSRC, subvt, mask, 0, -1);
    if !sis_is_cmp_op(ls) && np <= 1 && (mask.len == 0 || ins >= nsc) { return false, 0, 0, 0, 0, 0, 0; }
    let m = ls.main;
    let a = ls.alt;
    if (slp_is_binop(m) && slp_is_binop(a) && (sis_is_shift_op(ls) || sis_is_bitwise_logic_op(ls) || sis_is_addsub_like_op(ls) || sis_is_muldiv_like_op(ls))) ||
       (is_cast_op(iop(m)) && is_cast_op(iop(a))) || (iop(m) == OP_FNEG && iop(a) == OP_FNEG) {
        let ovc = tc_add(tv_arith0(o0, vecty, TCK_RECIP_THROUGHPUT), tv_arith0(o1, vecty, TCK_RECIP_THROUGHPUT));
        var om: i32[>..<] = [];
        for k in vl.len { om.push(-1); }
        for k in vl.len { if is_poison(vl[k]) { continue; } let add = if in1[k] { 0 } else { vl.len }; om[k] = (k + add) as i32; }
        let oc = tc_add(ovc, slp_shuffle_cost(SK_PERMUTETWOSRC, vecty, om, 0, -1));
        let nvc = tc_add(tv_arith0(o0, op1vt, TCK_RECIP_THROUGHPUT), tv_arith0(o1, op2vt, TCK_RECIP_THROUGHPUT));
        let st = slp_te.len > 0 && te_has_state(0) && te_opcode(0) == OP_STORE;
        let nc = tc_add(tc_add(nvc, ins), if st { nsc } else { 0 });
        if nc >= oc { return false, 0, 0, 0, 0, 0, 0; }
    }
    let r1 = slp_vrun(op1);
    let r2 = slp_vrun(op2);
    let rr = slp_irun(reord);
    return true, r1, op1.len, r2, op2.len, rr, reord.len;
}

// ---------------------------------------------------------------- legality
// getScalarsVectorizationLegality(VL, Depth, UserTreeIdx): (S, IsLegal, TryToFindDuplicates, TrySplitVectorize)
fn slp_vectorization_legality(vl: const i32[:], depth: i64, ui_te: i32) -> SIS, bool, bool, bool {
    var s = slp_build_instructions_state(vl, true, false);
    var scatter_gep = false;
    if !sis_valid(s) {
        let scatter_user = ui_te >= 0 && slp_te[ui_te].state == TE_SCATTER;
        if scatter_user && ty_kind(vals[vl[0]].ty) == TK_PTR && vl.len > 2 {
            var bb: i32 = -1;
            var ok = true;
            for v in vl {
                if !is_inst_op(v, OP_GEP) { if !slp_does_not_need_to_be_scheduled(v) { ok = false; break; } continue; }
                if bb < 0 { bb = inst_parent(v); }
                if !(bb == inst_parent(v) && nops(v) == 2) { ok = false; break; }
            }
            if ok && bb >= 0 {
                var si: i32[>..<] = [];
                scatter_gep = slp_sort_ptr_accesses(vl, vals[te_main(ui_te)].ty, si);
            }
        }
        if !scatter_gep {
            if slp_dbg_on { errs("SLP: Try split and if failed, gathering due to C,S,B,O, small shuffle. \n"); errs("["); for k in vl.len { if k > 0 { errs(", "); } slp_dv(vl[k]); } errs("]\n"); slp_dbg_flush(); }
            return s, false, true, true;
        }
        var g: i32 = -1;
        for v in vl { if is_inst_op(v, OP_GEP) { g = v; break; } }
        s = slp_same_opcode1(g);
    }
    if sis_opcode(s) == OP_PHI {
        let ninc = phi_nincoming(s.main);
        if vl.len * ninc > slp_phi_budget() {
            if slp_dbg_on { errs("SLP: Gathering due to wide PHI operand fan-out ("); errs_int(vl.len); errs(" lanes x "); errs_int(ninc); errs(" incoming values).\n"); slp_dbg_flush(); }
            return s, false, true, false;
        }
    }
    if ty_is_vector(slp_value_type(vl[0], false)) {
        if slp_dbg_on { errs("SLP: Gathering due to vector type.\n"); slp_dbg_flush(); }
        return s, false, false, false;
    }
    let bb = inst_parent(s.main);
    let term = block_terminator(bb);
    if inst_is_eh_pad(first_non_phi(bb)) || (term >= 0 && iop(term) == OP_UNREACHABLE) || !dt_has_node(DT_DOM, bb) {
        if slp_dbg_on { errs("SLP: bundle in unreachable block.\n"); slp_dbg_flush(); }
        return s, false, true, false;
    }
    if term >= 0 && iop(term) == OP_CATCHSWITCH {
        if slp_dbg_on { errs("SLP: bundle in catchswitch block.\n"); slp_dbg_flush(); }
        return s, false, false, false;
    }
    if sis_opcode(s) == OP_EXTRACTELEMENT && ty_kind(vals[op(s.main, 0)].ty) == TK_SVEC {
        if slp_dbg_on { errs("SLP: Gathering due to scalable vector type.\n"); slp_dbg_flush(); }
        return s, false, true, false;
    }
    if depth >= slp_recursion_max_depth_opt() {
        var peek = false;
        if !sis_is_alt_shuffle(s) && vl.len >= 4 {
            if iop(s.main) == OP_LOAD { peek = true; }
            else {
                peek = true;
                for v in vl {
                    let ok = is_inst(v) && (iop(v) == OP_ZEXT || iop(v) == OP_SEXT) && slp_has_one_use(v) &&
                             is_inst_op(op(v, 0), OP_LOAD) && slp_has_one_use(op(v, 0)) && iop(v) == sis_opcode(s);
                    if !ok { peek = false; break; }
                }
            }
        }
        if !peek {
            if slp_dbg_on { errs("SLP: Gathering due to max recursion depth.\n"); slp_dbg_flush(); }
            return s, false, true, false;
        }
    }
    if slp_dbg_on { errs("SLP: \tChecking bundle: "); slp_dv(s.main); errs(".\n"); slp_dbg_flush(); }
    let phi_loop = sis_opcode(s) == OP_PHI && li_loop_for(inst_parent(s.main)) >= 0;
    var c = slp_tree_entries_head(s.main);
    while c >= 0 {
        let e = slp_lk[c].x;
        c = slp_lk[c].next;
        if te_is_same(e, vl) {
            if slp_dbg_on { errs("SLP: Perfect diamond merge at "); slp_dv(s.main); errs(".\n"); slp_dbg_flush(); }
            return s, false, true, false;
        }
        var all = true;
        for v in vl {
            if is_poison(v) { continue; }
            var found = false;
            for x in te_scalars(e) { if x == v { found = true; break; } }
            if found { continue; }
            if phi_loop && is_inst_op(v, OP_PHI) && slp_is_vectorized(v) { continue; }
            all = false;
            break;
        }
        if all {
            if slp_dbg_on { errs("SLP: Gathering due to full overlap.\n"); slp_dbg_flush(); }
            return s, false, true, false;
        }
    }
    let same_insts = true;
    var vlike = true;
    let mo = iop(s.main);
    if mo == OP_INSERTELEMENT || mo == OP_EXTRACTVALUE || mo == OP_EXTRACTELEMENT {
        for v in vl { if !slp_is_vector_like_inst_with_const_ops(v) { vlike = false; break; } }
    }
    if !same_insts || slp_is_splat(vl) || !vlike {
        if slp_dbg_on { errs("SLP: Gathering due to C,S,B,O conditions. \n"); errs("["); for k in vl.len { if k > 0 { errs(", "); } slp_dv(vl[k]); } errs("]\n"); slp_dbg_flush(); }
        return s, false, true, false;
    }
    if slp_has_eph {
        for v in vl {
            if slp_is_ephemeral(v) {
                if slp_dbg_on { errs("SLP: The instruction ("); slp_dv(v); errs(") is ephemeral.\n"); slp_dbg_flush(); }
                return s, false, false, false;
            }
        }
    }
    if sis_is_alt_shuffle(s) {
        var ext: bool[>..<] = [];
        var vect: bool[>..<] = [];
        var all_vect = true;
        for k in vl.len { ext.push(false); vect.push(true); }
        for k in vl.len {
            let v = vl[k];
            if !is_inst(v) || slp_does_not_need_to_be_scheduled(v) { continue; }
            var all_ee = true;
            for j in nops(v) { if !is_inst_op(op(v, j), OP_EXTRACTELEMENT) { all_ee = false; break; } }
            if all_ee { continue; }
            if slp_is_vectorized(v) { vect[k] = false; all_vect = false; }
            else if !slp_has_one_user(v) && !slp_are_all_users_vectorized(v, slp_uil_on) { ext[k] = true; }
        }
        var prefer_scalar = !all_vect && vl.len == 2;
        if !all_vect && !prefer_scalar {
            let sty: i32 = vals[vl[0]].ty;
            let vecty = slp_widened_type(sty, vl.len);
            let vce = tc_add(slp_shuffle_cost(SK_PERMUTETWOSRC, vecty, slp_no_mask(), 0, -1), slp_scalarization_overhead(sty, vecty, ext, false, true, true));
            let sce = slp_scalarization_overhead(sty, vecty, vect, true, false, false);
            prefer_scalar = vce > sce;
        }
        if prefer_scalar {
            if slp_dbg_on { errs("SLP: The instructions are in tree and alternate node is not profitable.\n"); slp_dbg_flush(); }
            return s, false, true, false;
        }
    }
    if slp_uil_on && slp_uil_n > 0 {
        for v in vl {
            if slp_uil_contains(v) {
                if slp_dbg_on { errs("SLP: Gathering due to gathered scalar.\n"); slp_dbg_flush(); }
                return s, false, true, false;
            }
        }
    }
    return s, true, true, false;
}

// ---------------------------------------------------------------- buildTreeRec
fn slp_vl(at: i32, n: i64) -> const i32[:] { slp_vp[(at as i64)..at as i64 + n] }
fn slp_il(at: i32, n: i64) -> const i32[:] { slp_ip[(at as i64)..at as i64 + n] }
fn slp_dbg_added(what: const u8[:], te: i32) {
    if !slp_dbg_on || te < 0 { return; }
    errs("SLP: added a new TreeEntry ("); errs(what); errs(").\n");
    slp_dump_te(te);
    slp_dbg_flush();
}
fn slp_new_gather(vl: const i32[:], s: SIS, ui_te: i32, ui_edge: i64, reuse: const i32[:]) -> i32 {
    return slp_new_tree_entry(vl, TE_GATHER, -1, s, ui_te, ui_edge, reuse, slp_no_mask());
}
// TrySplitNode(LocalState)
recursive fn slp_try_split_node(vat: i32, vn: i64, ls: SIS, depth: i64, ui_te: i32, ui_edge: i64) -> bool {
    let ok, r1, n1, r2, n2, rr, nr = slp_can_build_split_node(slp_vl(vat, vn), ls);
    if !ok { return false; }
    let te = slp_new_tree_entry(slp_vl(vat, vn), TE_SPLIT, -1, ls, ui_te, ui_edge, slp_no_mask(), slp_il(rr, nr));
    if slp_dbg_on { errs("SLP: split alternate node.\n"); slp_dump_te(te); slp_dbg_flush(); }
    for idx in 2 {
        let at = if idx == 0 { r1 } else { r2 };
        let n = if idx == 0 { n1 } else { n2 };
        let s = slp_get_same_opcode(slp_vl(at, n));
        let off: i32 = if idx == 0 { 0 } else { n1 as i32 };
        if sis_valid(s) && (iop(s.main) == OP_LOAD || slp_same_values_tree_entry(s.main, slp_vl(at, n), true) >= 0) {
            te_comb_push(te, slp_te.len as i32, off);
            slp_new_tree_entry(slp_vl(at, n), TE_GATHER, -1, s, te, idx, slp_no_mask(), slp_no_mask());
        } else {
            te_comb_push(te, slp_te.len as i32, off);
            slp_build_tree_rec(at, n, depth, te, idx, 0);
        }
    }
    return true;
}
fn slp_only_consts_with_phis(vl: const i32[:]) -> bool {
    var consts = false;
    for v in vl {
        if is_poison(v) { continue; }
        if is_constant(v) { consts = true; continue; }
        if !is_inst_op(v, OP_PHI) { return false; }
    }
    return consts;
}
// the loop-nest bookkeeping of buildTreeRec: false = bail out to a gather node
fn slp_update_loop_nest(s: SIS, vl: const i32[:], ui_te: i32) -> bool {
    if slp_te.len == 0 {
        let l = li_loop_for(inst_parent(s.main));
        if l >= 0 {
            let l2 = slp_innermost_noninvariant_loop(l, vl);
            if l2 >= 0 { slp_loop_nest(l2, slp_loop_nest); }
        }
        return true;
    }
    if !(ui_te < 0 || slp_te[ui_te].state == TE_SPLIT || te_is_gather(ui_te) || inst_parent(te_main(ui_te)) != inst_parent(s.main)) { return true; }
    let l = li_loop_for(inst_parent(s.main));
    if l < 0 { return true; }
    let l2 = slp_innermost_noninvariant_loop(l, vl);
    if l2 < 0 { return true; }
    var nn: i32[>..<] = [];
    slp_loop_nest(l2, nn);
    var common: i64 = 0;
    while common < slp_loop_nest.len && common < nn.len && slp_loop_nest[common] == nn[common] { common++; }
    fn validate(start: i64) -> bool {
        let end = if nn.len < slp_merged_btcs.len { nn.len } else { slp_merged_btcs.len };
        for d in start..end {
            let c = slp_merged_btcs[d];
            if c < 0 { continue; }
            let nb = sc_get_backedge_taken_count(nn[d], BTC_EXACT);
            if scev_is_cnc(nb) || nb != c { return false; }
        }
        return true;
    }
    fn bail() -> bool {
        if slp_dbg_on { errs("SLP: Sibling loops have different trip counts.\n"); slp_dbg_flush(); }
        return false;
    }
    if slp_loop_nest.len == 0 {
        if !validate(0) { return bail(); }
        for x in nn { slp_loop_nest.push(x); }
    } else if common < slp_loop_nest.len && common < nn.len {
        let ba = sc_get_backedge_taken_count(slp_loop_nest[common], BTC_EXACT);
        let bb2 = sc_get_backedge_taken_count(nn[common], BTC_EXACT);
        if scev_is_cnc(ba) || ba != bb2 { return bail(); }
        if !validate(common + 1) { return bail(); }
        while slp_merged_btcs.len <= common { slp_merged_btcs.push(-1); }
        slp_merged_btcs[common] = ba;
        slp_loop_nest.resize(common);
    } else if nn.len > slp_loop_nest.len {
        if !validate(slp_loop_nest.len) { return bail(); }
        for k in slp_loop_nest.len..nn.len { slp_loop_nest.push(nn[k]); }
    }
    return true;
}
fn scev_is_cnc(s: i32) -> bool { s == 0 }
// the ExtraBitWidthNodes insertion (a DenseSet<unsigned>; the order of insertion is kept, minbw decides)
fn slp_extra_bw_insert(idx: i32) { ebw_insert(idx as i64); }
// buildTreeRec(VL, Depth, UserTreeIdx, InterleaveFactor)
recursive fn slp_build_tree_rec(vat0: i32, vn0: i64, depth: i64, ui_te: i32, ui_edge: i64, interleave: i64) {
    var vat = vat0;
    var vn = vn0;
    let none_ = slp_no_mask();
    if slp_only_consts_with_phis(slp_vl(vat, vn)) {
        if slp_dbg_on { errs("SLP: Gathering due to all constants and PHIs.\n"); slp_dbg_flush(); }
        slp_new_gather(slp_vl(vat, vn), sis_invalid(), ui_te, ui_edge, slp_no_mask());
        return;
    }
    let s, legal, try_dups, try_split = slp_vectorization_legality(slp_vl(vat, vn), depth, ui_te);
    if !legal {
        if try_split {
            let m, a = slp_main_alt_no_state(slp_vl(vat, vn));
            if m >= 0 && a >= 0 && slp_try_split_node(vat, vn, SIS { main: m, alt: a, copy: false }, depth, ui_te, ui_edge) { return; }
        }
        var rat: i32 = 0;
        var rn: i64 = 0;
        if try_dups {
            let ok, nvat, nvn, r1, r2 = slp_try_to_find_duplicates(slp_vl(vat, vn), s, ui_te, true);
            vat = nvat; vn = nvn; rat = r1; rn = r2;
        }
        slp_new_gather(slp_vl(vat, vn), s, ui_te, ui_edge, slp_il(rat, rn));
        return;
    }
    if sis_is_alt_shuffle(s) && slp_try_split_node(vat, vn, s, depth, ui_te, ui_edge) { return; }
    let dok, dvat, dvn, drat, drn = slp_try_to_find_duplicates(slp_vl(vat, vn), s, ui_te, false);
    vat = dvat; vn = dvn;
    let rat = drat;
    let rn = drn;
    if !dok {
        slp_new_gather(slp_vl(vat, vn), s, ui_te, ui_edge, slp_il(rat, rn));
        return;
    }
    let scatter_user = ui_te >= 0 && slp_te[ui_te].state == TE_SCATTER;
    let st, oat, on, pat, pn, eat, en = slp_state_runs(s, slp_vl(vat, vn), scatter_user);
    if st == TE_GATHER {
        slp_new_gather(slp_vl(vat, vn), s, ui_te, ui_edge, slp_il(rat, rn));
        return;
    }
    if !slp_update_loop_nest(s, slp_vl(vat, vn), ui_te) {
        slp_new_gather(slp_vl(vat, vn), s, ui_te, ui_edge, slp_il(rat, rn));
        return;
    }
    let vl0 = s.main;
    let bs = slp_get_bs(inst_parent(vl0));
    let uat, un = slp_unique_values(slp_vl(vat, vn));
    let bundle = slp_try_schedule_bundle(bs, slp_vl(uat, un), s, ui_te, ui_edge);
    if bundle == -2 {
        if slp_dbg_on { errs("SLP: We are not able to schedule this bundle!\n"); slp_dbg_flush(); }
        if sis_is_alt_shuffle(s) && rn == 0 && slp_try_split_node(vat, vn, s, depth, ui_te, ui_edge) { return; }
        if s.copy && rn == 0 {
            let alts = slp_get_same_opcode(slp_vl(vat, vn));
            if sis_valid(alts) && sis_is_alt_shuffle(alts) && slp_try_split_node(vat, vn, alts, depth, ui_te, ui_edge) { return; }
        }
        slp_new_gather(slp_vl(vat, vn), s, ui_te, ui_edge, slp_il(rat, rn));
        sh_add(SH_NSF, slp_vp[vat as i64] as i64, 0);
        if sis_opcode(s) == OP_LOAD && slp_bs[bs].region_size < slp_bs[bs].region_limit { slp_register_nonvect_loads(slp_vl(vat, vn)); }
        return;
    }
    let opl, nopl = slp_build_operands(s, slp_vl(vat, vn));
    if slp_dbg_on { errs("SLP: We are able to schedule this bundle.\n"); slp_dbg_flush(); }
    let shuffle_or_op = if sis_is_alt_shuffle(s) { OP_SHUFFLEVECTOR } else { sis_opcode(s) };
    let o = shuffle_or_op;
    fn set_operands(te: i32) {
        // TE->setOperands(Operands): the node takes the operand lists
        slp_te[te].ops = opl;
        slp_te[te].nops = nopl as i32;
    }
    if o == OP_PHI {
        let te = slp_new_tree_entry(slp_vl(vat, vn), TE_VECTORIZE, bundle, s, ui_te, ui_edge, slp_il(rat, rn), none_);
        slp_dbg_added("PHINode", te);
        set_operands(te);
        slp_create_operand_nodes(te, depth);
        return;
    }
    if o == OP_EXTRACTVALUE || o == OP_EXTRACTELEMENT {
        if slp_dbg_on {
            if on == 0 { errs("SLP: Reusing or shuffling extract sequence.\n"); }
            else { errs("SLP: Reusing or shuffling of reordered extract sequence with order"); for x in slp_il(oat, on) { errs(" "); errs_int(x as i64); } errs("\n"); }
            slp_dbg_flush();
        }
        let foat = slp_fixup_order_run(oat, on);
        let te = slp_new_tree_entry(slp_vl(vat, vn), TE_VECTORIZE, bundle, s, ui_te, ui_edge, slp_il(rat, rn), slp_il(foat, on));
        slp_dbg_added("ExtractValueInst/ExtractElementInst", te);
        set_operands(te);
        if o == OP_EXTRACTVALUE && slp_check_evs_for_vec_calls(slp_vl(vat, vn), s) { fatal("internal: SLP: unreachable"); }
        return;
    }
    if o == OP_INSERTVALUE || o == OP_INSERTELEMENT {
        let ioat, ion = slp_insert_order(slp_vl(vat, vn));
        let te = slp_new_tree_entry(slp_vl(vat, vn), TE_VECTORIZE, bundle, s, ui_te, ui_edge, none_, slp_il(ioat, ion));
        slp_dbg_added("InsertElementInst", te);
        set_operands(te);
        let r = te_operand_run(te, 1);
        slp_build_tree_rec(r.at, r.n as i64, depth + 1, te, 1, 0);
        return;
    }
    if o == OP_LOAD {
        let foat = slp_fixup_order_run(oat, on);
        var te: i32 = -1;
        if st == TE_VECTORIZE {
            te = slp_new_tree_entry(slp_vl(vat, vn), TE_VECTORIZE, bundle, s, ui_te, ui_edge, slp_il(rat, rn), slp_il(foat, on));
            if te >= 0 && interleave > 0 { slp_te[te].inter = interleave as i32; }
            slp_dbg_added(if on == 0 { "LoadInst" } else { "jumbled LoadInst" }, te);
        } else if st == TE_COMPRESS {
            te = slp_new_tree_entry(slp_vl(vat, vn), TE_COMPRESS, bundle, s, ui_te, ui_edge, slp_il(rat, rn), slp_il(foat, on));
            slp_dbg_added("masked LoadInst + compress", te);
        } else if st == TE_STRIDED {
            fatal("internal: SLP: strided loads are never legal on the supported targets");
        } else if st == TE_SCATTER {
            te = slp_new_tree_entry(slp_vl(vat, vn), TE_SCATTER, bundle, s, ui_te, ui_edge, slp_il(rat, rn), none_);
            slp_dbg_added("non-consecutive LoadInst", te);
        } else {
            fatal("internal: SLP: unexpected loads state");
        }
        if on > 0 && st != TE_SCATTER {
            slp_reorder_run_by_order(opl, 0, slp_il(foat, on));
        }
        set_operands(te);
        if st == TE_SCATTER { slp_build_tree_rec(slp_vrun(slp_vl(pat, pn)), pn, depth + 1, te, 0, 0); }
        return;
    }
    if is_cast_op(o) {
        let pmax: i64 = if slp_cast_bw_valid { slp_cast_bw_max } else { 0 };
        let pmin: i64 = if slp_cast_bw_valid { slp_cast_bw_min } else { 0xFFFFFFFF };
        if o == OP_ZEXT || o == OP_SEXT {
            let a = slp_dl_bits(vals[vl0].ty);
            let b = slp_dl_bits(vals[op(vl0, 0)].ty);
            slp_cast_bw_valid = true;
            slp_cast_bw_max = if a > pmax { a } else { pmax };
            slp_cast_bw_min = if b < pmin { b } else { pmin };
        } else if o == OP_TRUNC {
            let a = slp_dl_bits(vals[op(vl0, 0)].ty);
            let b = slp_dl_bits(vals[vl0].ty);
            slp_cast_bw_valid = true;
            slp_cast_bw_max = if a > pmax { a } else { pmax };
            slp_cast_bw_min = if b < pmin { b } else { pmin };
        }
        let te = slp_new_tree_entry(slp_vl(vat, vn), TE_VECTORIZE, bundle, s, ui_te, ui_edge, slp_il(rat, rn), none_);
        slp_dbg_added("CastInst", te);
        set_operands(te);
        for i in nops(vl0) {
            let r = te_operand_run(te, i);
            slp_build_tree_rec(r.at, r.n as i64, depth, te, i, 0);
        }
        if o == OP_TRUNC {
            slp_extra_bw_insert(slp_operand_entry(te, 0));
        } else if o == OP_SITOFP || o == OP_UITOFP {
            var nsb = slp_num_sign_bits(op(vl0, 0));
            if is_inst(op(vl0, 0)) {
                let w = ty_bits(ty_scalar(vals[op(vl0, 0)].ty));
                if w > 64 { slp_fail("DemandedBits of a value wider than 64 bits"); }
                let m = db_demanded_bits(op(vl0, 0));
                var lz: i64 = 0;
                var b = w - 1;
                while b >= 0 && ((m >> (b as u64)) & 1) == 0 { lz++; b--; }
                if lz > nsb { nsb = lz; }
            }
            if nsb * 2 >= slp_dl_bits(vals[op(vl0, 0)].ty) { slp_extra_bw_insert(slp_operand_entry(te, 0)); }
        }
        return;
    }
    if o == OP_ICMP || o == OP_FCMP {
        let p0 = inst_pred(vl0);
        let te = slp_new_tree_entry(slp_vl(vat, vn), TE_VECTORIZE, bundle, s, ui_te, ui_edge, slp_il(rat, rn), none_);
        slp_dbg_added("CmpInst", te);
        if slp_cmp_is_commutative(vl0) {
            slp_vlops_reorder(slp_vl(vat, vn), opl, nopl, s);
        } else {
            for k in vn {
                let v = slp_vp[vat as i64 + k];
                if is_poison(v) { continue; }
                if inst_pred(v) != p0 { opl_swap(opl, 0, nopl - 1, k); }
            }
        }
        set_operands(te);
        let r0 = te_operand_run(te, 0);
        slp_build_tree_rec(r0.at, r0.n as i64, depth, te, 0, 0);
        let r1 = te_operand_run(te, nopl - 1);
        slp_build_tree_rec(r1.at, r1.n as i64, depth, te, 1, 0);
        if o == OP_ICMP {
            let n0 = slp_num_sign_bits(op(vl0, 0));
            if n0 * 2 >= slp_dl_bits(vals[op(vl0, 0)].ty) { slp_extra_bw_insert(slp_operand_entry(te, 0)); }
            let n1 = slp_num_sign_bits(op(vl0, 1));
            if n1 * 2 >= slp_dl_bits(vals[op(vl0, 1)].ty) { slp_extra_bw_insert(slp_operand_entry(te, 1)); }
        }
        return;
    }
    if o == OP_SELECT || o == OP_FNEG || is_binary_op(o) || o == OP_FREEZE {
        let te = slp_new_tree_entry(slp_vl(vat, vn), TE_VECTORIZE, bundle, s, ui_te, ui_edge, slp_il(rat, rn), none_);
        slp_dbg_added("SelectInst/UnaryOperator/BinaryOperator/FreezeInst", te);
        if slp_is_binop(vl0) && slp_is_commutative(vl0) { slp_vlops_reorder(slp_vl(vat, vn), opl, nopl, s); }
        set_operands(te);
        for i in nops(vl0) {
            let r = te_operand_run(te, i);
            slp_build_tree_rec(r.at, r.n as i64, depth + 1, te, i, 0);
        }
        return;
    }
    if o == OP_GEP {
        let te = slp_new_tree_entry(slp_vl(vat, vn), TE_VECTORIZE, bundle, s, ui_te, ui_edge, slp_il(rat, rn), none_);
        slp_dbg_added("GetElementPtrInst", te);
        set_operands(te);
        for i in nopl {
            let r = te_operand_run(te, i);
            slp_build_tree_rec(r.at, r.n as i64, depth + 1, te, i, 0);
        }
        return;
    }
    if o == OP_STORE {
        if st == TE_EXPAND {
            let te = slp_new_tree_entry(slp_vl(vat, vn), TE_EXPAND, bundle, s, ui_te, ui_edge, slp_il(eat, en), slp_il(oat, on));
            slp_dbg_added("expanded masked StoreInst", te);
            set_operands(te);
            let r = te_operand_run(te, 0);
            slp_build_tree_rec(r.at, r.n as i64, depth + 1, te, 0, 0);
            return;
        }
        let te = slp_new_tree_entry(slp_vl(vat, vn), TE_VECTORIZE, bundle, s, ui_te, ui_edge, slp_il(rat, rn), slp_il(oat, on));
        slp_dbg_added("StoreInst", te);
        set_operands(te);
        let r = te_operand_run(te, 0);
        slp_build_tree_rec(r.at, r.n as i64, depth + 1, te, 0, 0);
        return;
    }
    if o == OP_CALL {
        let id = laa_vector_intrinsic_id_for_call(vl0);
        let te = slp_new_tree_entry(slp_vl(vat, vn), TE_VECTORIZE, bundle, s, ui_te, ui_edge, slp_il(rat, rn), none_);
        slp_dbg_added("CallInst", te);
        if slp_is_commutative(vl0) { slp_vlops_reorder(slp_vl(vat, vn), opl, nopl, s); }
        set_operands(te);
        for i in cb_nargs(vl0) {
            if vu_scalar_op_at_arg(id, i, true) { continue; }
            if i >= nopl { fatal("internal: SLP: a call operand list past the vector arguments"); }
            let r = te_operand_run(te, i);
            slp_build_tree_rec(r.at, r.n as i64, depth + 1, te, i, 0);
        }
        return;
    }
    if o == OP_SHUFFLEVECTOR {
        let te = slp_new_tree_entry(slp_vl(vat, vn), TE_VECTORIZE, bundle, s, ui_te, ui_edge, slp_il(rat, rn), none_);
        slp_dbg_added("isAltShuffle", te);
        let is_cmp = slp_is_cmp(vl0);
        var any_noncomm = false;
        if is_cmp { for k in vn { let v = slp_vp[vat as i64 + k]; if !is_poison(v) && !slp_cmp_is_commutative(v) { any_noncomm = true; } } }
        if is_cmp && any_noncomm {
            let mp = inst_pred(s.main);
            let ap = inst_pred(s.alt);
            for k in vn {
                let v = slp_vp[vat as i64 + k];
                if is_poison(v) { continue; }
                if slp_is_alternate_instruction(v, s.main, s.alt) {
                    if ap == slp_swapped_pred(inst_pred(v)) { opl_swap(opl, 0, nopl - 1, k); }
                } else {
                    if mp == slp_swapped_pred(inst_pred(v)) { opl_swap(opl, 0, nopl - 1, k); }
                }
            }
            set_operands(te);
            let r0 = te_operand_run(te, 0);
            slp_build_tree_rec(r0.at, r0.n as i64, depth + 1, te, 0, 0);
            let r1 = te_operand_run(te, nopl - 1);
            slp_build_tree_rec(r1.at, r1.n as i64, depth + 1, te, 1, 0);
            return;
        }
        if slp_is_binop(vl0) || is_cmp { slp_vlops_reorder(slp_vl(vat, vn), opl, nopl, s); }
        set_operands(te);
        for i in nops(vl0) {
            let r = te_operand_run(te, i);
            slp_build_tree_rec(r.at, r.n as i64, depth + 1, te, i, 0);
        }
        return;
    }
    fatal("internal: SLP: unexpected vectorization of the instructions");
}
// CreateOperandNodes(TE, Operands): PHI operands last
recursive fn slp_create_operand_nodes(te: i32, depth: i64) {
    let n = te_num_operands(te);
    for i in n {
        let r = te_operand_run(te, i);
        if r.n == 0 { continue; }
        let s = slp_get_same_opcode(te_operand(te, i));
        if !sis_valid(s) || sis_opcode(s) != OP_PHI || sis_is_alt_shuffle(s) { slp_build_tree_rec(r.at, r.n as i64, depth + 1, te, i, 0); }
    }
    for i in n {
        let r = te_operand_run(te, i);
        if r.n == 0 { continue; }
        let s = slp_get_same_opcode(te_operand(te, i));
        if !(!sis_valid(s) || sis_opcode(s) != OP_PHI || sis_is_alt_shuffle(s)) { slp_build_tree_rec(r.at, r.n as i64, depth + 1, te, i, 0); }
    }
}
// getScalarsVectorizationState with its out-lists as runs: (state, order run, n, pointer-ops run, n, expand run, n)
fn slp_state_runs(s: SIS, vl: const i32[:], scatter_user: bool) -> i32, i32, i64, i32, i64, i32, i64 {
    var order: i32[>..<] = [];
    var ptrs: i32[>..<] = [];
    var expand: i32[>..<] = [];
    let st = slp_vectorization_state(s, vl, scatter_user, order, ptrs, expand);
    let oat = slp_irun(order);
    let pat = slp_vrun(ptrs);
    let eat = slp_irun(expand);
    return st, oat, order.len, pat, ptrs.len, eat, expand.len;
}
fn slp_fixup_order_run(at: i32, n: i64) -> i32 {
    var o: i32[>..<] = [];
    for x in slp_il(at, n) { o.push(x); }
    slp_fixup_ordering_indices(o);
    return slp_irun(o);
}
// SetVector<Value *> UniqueValues(VL)
fn slp_unique_values(vl: const i32[:]) -> i32, i64 {
    var u: i32[>..<] = [];
    sh_clear(SH_TMP0);
    for v in vl { if sh_add(SH_TMP0, v as i64, 0) { u.push(v); } }
    return slp_vrun(u), u.len;
}
// the insertelement / insertvalue order (a priority queue of (index, lane), smallest index first)
fn slp_insert_order(vl: const i32[:]) -> i32, i64 {
    let n = vl.len;
    var idx: i64[>..<] = [];
    for v in vl { idx.push(slp_element_index(v, 0)); }
    var order: i32[>..<] = [];
    for k in n { order.push(n as i32); }
    var taken: bool[>..<] = [];
    for k in n { taken.push(false); }
    var ident = true;
    for i in n {
        // Indices.top(): the smallest index (ties: libstdc++ heap order; element indices are unique here)
        var best: i64 = -1;
        for k in n { if !taken[k] && (best < 0 || idx[k] < idx[best]) { best = k; } }
        taken[best] = true;
        order[best] = i as i32;
        ident = ident && best == i;
    }
    if ident { order.clear(); }
    return slp_irun(order), order.len;
}
// reorderScalars(Operands[k], inversePermutation(order))
fn slp_reorder_run_by_order(opl: i32, k: i64, order: const i32[:]) {
    var mask: i32[>..<] = [];
    slp_inverse_permutation(order, mask);
    var sc: i32[>..<] = [];
    for v in opl_list(opl, k) { sc.push(v); }
    slp_reorder_scalars(sc, mask);
    for j in sc.len { opl_set(opl, k, j, sc[j]); }
}

// buildTree(Roots, UserIgnoreLst): the ignore list is given in `uil` (empty slice = no list)
fn slp_build_tree(roots: const i32[:], has_uil: bool, uil: const i32[:]) {
    slp_delete_tree();
    if has_uil {
        slp_uil_on = true;
        slp_uil_n = uil.len;
        for v in uil { if sh_add(SH_UIL, v as i64, 0) { slp_uil_vals.push(v); } }
    }
    if !slp_all_same_type(roots) { return; }
    let at = slp_vrun(roots);
    slp_build_tree_rec(at, roots.len, 0, -1, -1, 0);
}

// ---------------------------------------------------------------- tree queries used by the driver
// getVectorElementSize(V)
fn slp_vector_element_size(v1: i32) -> i64 {
    var v = v1;
    if is_inst_op(v, OP_STORE) { return dl_size_bits(vals[op(v, 0)].ty); }
    while is_inst_op(v, OP_INSERTELEMENT) { v = op(v, 1); }
    if is_inst_op(v, OP_STORE) { return dl_size_bits(vals[op(v, 0)].ty); }
    let c = sh_get(SH_INSTRSZ, v as i64, 0, -1);
    if c >= 0 { return c; }
    var wl_i: i32[>..<] = [];
    var wl_p: i32[>..<] = [];
    var wl_l: i64[>..<] = [];
    var visited: i32[>..<] = [];
    sh_clear(SH_TMP0);
    if is_inst(v) { wl_i.push(v); wl_p.push(inst_parent(v)); wl_l.push(0); sh_add(SH_TMP0, v as i64, 0); visited.push(v); }
    var width: i64 = 0;
    var first_non_bool: i32 = -1;
    let i1 = ty_int(1);
    let rmd = slp_recursion_max_depth_opt();
    while wl_i.len > 0 {
        let i = wl_i.pop();
        let parent = wl_p.pop();
        let level = wl_l.pop();
        let ty: i32 = vals[i].ty;
        if ty_is_vector(ty) { continue; }
        if ty != i1 && first_non_bool < 0 { first_non_bool = i; }
        if level > rmd { continue; }
        let o = iop(i);
        let id = inst_iid(i);
        let compat = id == IID_abs || id == IID_fabs || id == IID_fma || id == IID_fmuladd;
        if o == OP_LOAD || o == OP_EXTRACTELEMENT || o == OP_EXTRACTVALUE {
            let w = dl_size_bits(ty);
            if w > width { width = w; }
        } else if o == OP_PHI || is_cast_op(o) || o == OP_GEP || o == OP_ICMP || o == OP_FCMP || o == OP_SELECT || is_binary_op(o) ||
                  o == OP_FNEG || compat {
            for k in nops(i) {
                let j = op(i, k);
                if is_inst(j) && !sh_has(SH_TMP0, j as i64, 0) && (o == OP_PHI || inst_parent(j) == parent) {
                    sh_add(SH_TMP0, j as i64, 0);
                    visited.push(j);
                    wl_i.push(j); wl_p.push(inst_parent(j)); wl_l.push(level + 1);
                    continue;
                }
                if first_non_bool < 0 && vals[j].ty as i32 != i1 { first_non_bool = j; }
            }
        } else {
            break;
        }
    }
    if width == 0 {
        if vals[v].ty as i32 == i1 && first_non_bool >= 0 { v = first_non_bool; }
        width = dl_size_bits(vals[v].ty);
    }
    for i in visited { sh_set(SH_INSTRSZ, i as i64, 0, width); }
    return width;
}
// isFixedVectorShuffle(VL, Mask, AC): the ShuffleKind (-1 = none)
fn slp_is_fixed_vector_shuffle(vl: const i32[:], mask: i32[>..<]&) -> i64 {
    var any_ee = false;
    for v in vl { if is_inst_op(v, OP_EXTRACTELEMENT) { any_ee = true; break; } }
    if !any_ee { return -1; }
    var size: i64 = 0;
    for v in vl {
        if !is_inst_op(v, OP_EXTRACTELEMENT) { continue; }
        let vt: i32 = vals[op(v, 0)].ty;
        if ty_kind(vt) != TK_FVEC { continue; }
        if ty_count(vt) > size { size = ty_count(vt); }
    }
    var vec1: i32 = -1;
    var vec2: i32 = -1;
    var has_non_undef = false;
    for v in vl {
        if !is_inst_op(v, OP_EXTRACTELEMENT) { continue; }
        let vec = op(v, 0);
        if is_undef_or_poison(vec) { continue; }
        if is_guaranteed_not_to_be_poison(vec, -1, 0) { has_non_undef = true; break; }
    }
    // ShuffleMode: 0 Unknown, 1 Select, 2 Permute
    var mode: i64 = 0;
    mask.clear();
    for k in vl.len { mask.push(-1); }
    for i in vl.len {
        let v = vl[i];
        if is_undef_or_poison(v) { continue; }
        let vec = op(v, 0);
        if ty_kind(vals[vec].ty) == TK_SVEC { return -1; }
        if slp_is_undef_vector_all(vec, true) { continue; }
        if is_undef_or_poison(vec) {
            mask[i] = i as i32;
        } else {
            let ix = op(v, 1);
            if is_undef_or_poison(ix) { continue; }
            if !is_cint(ix) { return -1; }
            let a = ap_from_cint(ix);
            if ap_uge_u64(a, size as u64) { continue; }
            mask[i] = a.lo as i32;
        }
        if slp_is_undef_vector_all(vec, false) && has_non_undef { continue; }
        if vec1 < 0 || vec1 == vec {
            vec1 = vec;
        } else if vec2 < 0 || vec2 == vec {
            vec2 = vec;
            mask[i] = mask[i] + size as i32;
        } else {
            return -1;
        }
        if mode == 2 { continue; }
        if (mask[i] as i64) % size != i { mode = 2; continue; }
        mode = 1;
    }
    if mode == 1 && vec2 >= 0 { return SK_SELECT; }
    return if vec2 >= 0 { SK_PERMUTETWOSRC } else { SK_PERMUTESINGLESRC };
}
fn slp_min_tree_size() -> i64 { flag_int("slp-min-tree-size", 3) }
// isFullyVectorizableTinyTree(ForReduction)
fn slp_is_fully_vectorizable_tiny_tree(for_reduction: bool) -> bool {
    if slp_dbg_on { errs("SLP: Check whether the tree with height "); errs_int(slp_te.len); errs(" is fully vectorizable .\n"); slp_dbg_flush(); }
    fn vectorizable_gathers(te: i32, limit: i64) -> bool {
        if !te_is_gather(te) { return false; }
        let sc = te_scalars(te);
        for v in sc { if slp_is_ephemeral(v) { return false; } }
        if slp_all_constant(sc) || slp_is_splat(sc) || sc.len < limit { return true; }
        var all_ee = true;
        for v in sc { if !(is_inst_op(v, OP_EXTRACTELEMENT) || is_undef_or_poison(v)) { all_ee = false; break; } }
        if (te_has_state(te) && te_opcode(te) == OP_EXTRACTELEMENT) || all_ee {
            var m: i32[>..<] = [];
            if slp_is_fixed_vector_shuffle(sc, m) >= 0 { return true; }
        }
        if te_has_state(te) && te_opcode(te) == OP_LOAD && !te_is_alt_shuffle(te) { return true; }
        for v in sc { if is_inst_op(v, OP_LOAD) { return true; } }
        return false;
    }
    let n = slp_te.len;
    let s0 = slp_te[0].state;
    if n == 1 && (s0 == TE_VECTORIZE || s0 == TE_STRIDED || s0 == TE_EXPAND || s0 == TE_COMPRESS ||
                  (for_reduction && vectorizable_gathers(0, te_nscalars(0)) && te_vector_factor(0) > 2)) { return true; }
    if n != 2 { return false; }
    if s0 == TE_VECTORIZE && vectorizable_gathers(1, te_nscalars(0)) { return true; }
    if te_is_gather(0) || (te_is_gather(1) && s0 != TE_SCATTER && s0 != TE_STRIDED && s0 != TE_EXPAND && s0 != TE_COMPRESS) { return false; }
    return true;
}
fn slp_count_ee(te: i32) -> i64 { var c: i64 = 0; for v in te_scalars(te) { if is_inst_op(v, OP_EXTRACTELEMENT) { c++; } } return c; }
// isTreeTinyAndNotFullyVectorizable(ForReduction)
fn slp_is_tree_tiny_and_not_fully_vectorizable(for_reduction: bool) -> bool {
    let n = slp_te.len;
    if n == 0 { return true; }
    for te in n {
        if te_is_gather(te as i32) && ty_is_struct(vals[te_scalar(te as i32, 0)].ty) {
            if slp_dbg_on { errs("SLP: rejecting tree with buildvector struct values of size "); errs_int(n); errs(".\n"); slp_dbg_flush(); }
            return true;
        }
    }
    let fg = te_is_gather(0);
    let fhs = te_has_state(0);
    let fop: i64 = if fhs { te_opcode(0) } else { 0 };
    let thr_set = flag_given("slp-threshold");
    let thr = slp_threshold();
    let thr_nonneg = thr >= 0;
    let limit: i64 = 4;
    let large: i64 = 20;
    let limit_tree: i64 = 36;
    let min_tree = slp_min_tree_size();
    if !for_reduction {
        if n == 1 && fg {
            if fhs && fop == OP_EXTRACTELEMENT { return true; }
            for v in te_scalars(0) { if is_inst(v) { return true; } }
        }
        if n <= min_tree {
            var all = true;
            for te in n { if !(te_is_gather(te as i32) || slp_te[te].state == TE_SPLIT) { all = false; break; } }
            if all { return true; }
        }
        if n == 1 && thr < 0 && fhs && fop == OP_EXTRACTELEMENT {
            var all = true;
            for v in te_scalars(0) { if is_inst(v) && slp_are_all_users_vectorized(v, slp_uil_on) { all = false; break; } }
            if te_vector_factor(0) == 2 || all { return true; }
        }
    }
    if n == 2 && is_inst_op(te_scalar(0, 0), OP_INSERTELEMENT) && te_is_gather(1) &&
       (te_vector_factor(1) <= 2 || !(slp_is_splat(te_scalars(1)) || slp_all_constant(te_scalars(1)))) { return true; }
    if n == 3 && thr == 0 && (!for_reduction || te_vector_factor(0) <= 2) {
        var all = true;
        for te in 1..n {
            let t = te as i32;
            var all_eu = true;
            for v in te_scalars(t) { if !(is_inst_op(v, OP_EXTRACTELEMENT) || is_undef_or_poison(v) || is_constant(v)) { all_eu = false; break; } }
            if !(te_is_gather(t) && te_vector_factor(t) <= limit && !all_eu) { all = false; break; }
        }
        if all { return true; }
    }
    if !for_reduction {
        if !thr_set {
            var all = true;
            for te in n {
                let t = te as i32;
                let ig = te_is_gather(t);
                let hs = te_has_state(t);
                let o: i64 = if hs { te_opcode(t) } else { 0 };
                if ig && (!hs || o != OP_EXTRACTELEMENT) && slp_count_ee(t) <= limit { continue; }
                if hs && o == OP_PHI { continue; }
                all = false;
                break;
            }
            if all { return true; }
        }
        if thr_set && n <= limit {
            var has_vphi = false;
            var all = true;
            for te in n {
                let t = te as i32;
                let ig = te_is_gather(t);
                let hs = te_has_state(t);
                let o: i64 = if hs { te_opcode(t) } else { 0 };
                if ig && (!hs || o != OP_EXTRACTELEMENT) && slp_count_ee(t) <= limit { continue; }
                if !hs { all = false; break; }
                if o == OP_INSERTELEMENT { continue; }
                if o != OP_PHI { all = false; break; }
                if slp_te[t].state == TE_VECTORIZE { has_vphi = true; }
                var ok = true;
                for v in te_scalars(t) { if !(is_poison(v) || slp_is_gathered(v)) { ok = false; break; } }
                if !ok { all = false; break; }
            }
            if all && has_vphi { return true; }
        }
        if thr_nonneg {
            let is_large = n >= large;
            var has_single_load = false;
            var all = true;
            for te in n {
                let t = te as i32;
                let ig = te_is_gather(t);
                let hs = te_has_state(t);
                let o: i64 = if hs { te_opcode(t) } else { 0 };
                var r = false;
                var decided = false;
                if is_large {
                    let prev = has_single_load;
                    has_single_load = has_single_load || (hs && !ig && (o == OP_LOAD || te_has_copyable_elements(t)) &&
                                                          (te_vector_factor(t) > 2 || slp_te[t].nreord == 0));
                    if hs {
                        if o == OP_PHI { r = true; decided = true; }
                        else if te_vector_factor(t) <= limit && (o == OP_STORE || (o == OP_LOAD && !prev)) { r = true; decided = true; }
                    }
                } else if hs && o == OP_PHI {
                    r = true; decided = true;
                }
                if !decided { r = ig && (!hs || o != OP_EXTRACTELEMENT); }
                if !r { all = false; break; }
            }
            if all { return true; }
            if n >= 5 && te_vector_factor(0) <= 2 && ty_is_int(vals[te_scalar(0, 0)].ty) {
                var vfound = false;
                var any_nonconst = false;
                var all2 = true;
                for te in n {
                    let t = te as i32;
                    if slp_te[t].state == TE_VECTORIZE && te_has_state(t) {
                        let o = te_opcode(t);
                        if o == OP_PHI || slp_te[t].nreord > 0 { continue; }
                        if vfound { all2 = false; break; }
                        vfound = true;
                        continue;
                    }
                    if !any_nonconst { any_nonconst = !slp_all_constant(te_scalars(t)); }
                    if !(te_is_gather(t) || slp_te[t].state == TE_SPLIT) { all2 = false; break; }
                }
                if all2 && any_nonconst { return true; }
            }
        }
        fn benign(t: i32, n: i64, limit_tree: i64) -> bool {
            if slp_te[t].state == TE_SPLIT { return true; }
            let ig = te_is_gather(t);
            if te_has_state(t) {
                let o = te_opcode(t);
                if o == OP_PHI { return true; }
                let ss = te_nscalars(t);
                if t == 0 && ss == 2 && o == OP_ICMP && n > limit_tree { return true; }
                if ss == 2 && (slp_te[t].nreuse > 0 || slp_te[t].nreord > 0 || te_is_alt_shuffle(t)) { return true; }
                if te_has_copyable_elements(t) {
                    var c: i64 = 0;
                    for v in te_scalars(t) { if is_inst_op(v, OP_PHI) || is_constant(v) { c++; } }
                    if c >= ss / 2 { return true; }
                }
            }
            if !ig { return false; }
            for v in te_scalars(t) { if is_inst_op(v, OP_EXTRACTELEMENT) { return false; } }
            return true;
        }
        if !thr_set {
            var sl: i32[>..<] = [];
            var ngathers: i64 = 0;
            var all = true;
            for te in n {
                let t = te as i32;
                let ig = te_is_gather(t);
                if !ig && te_has_state(t) {
                    let o = te_opcode(t);
                    if o == OP_LOAD || o == OP_STORE { sl.push(t); continue; }
                }
                if ig { ngathers++; }
                if !benign(t, n, limit_tree) { all = false; break; }
            }
            if all {
                var ok = sl.len == 0;
                if !ok && n > limit_tree * sl.len {
                    if ngathers > 0 { ok = true; }
                    else {
                        var none = true;
                        for t in sl {
                            if te_opcode(t) == OP_STORE { none = false; break; }
                            var allv = true;
                            for v in te_scalars(t) { if is_inst_op(v, OP_LOAD) && !slp_are_all_users_vectorized(v, false) { allv = false; break; } }
                            if allv { none = false; break; }
                        }
                        ok = none;
                    }
                }
                if ok { return true; }
            }
        }
        if thr_nonneg && n > limit_tree {
            var vnode: i32 = -1;
            var all = true;
            for te in n {
                let t = te as i32;
                if !te_is_gather(t) && te_has_state(t) && slp_te[t].state != TE_SPLIT && te_opcode(t) != OP_PHI {
                    if vnode >= 0 { all = false; break; }
                    vnode = t;
                    continue;
                }
                if !benign(t, n, limit_tree) { all = false; break; }
            }
            if all { return true; }
        }
        if thr_set && n >= limit && slp_te[0].state == TE_SPLIT {
            var cnt: i64 = 0;
            for te in 1..n { let t = te as i32; if !te_is_gather(t) && slp_te[t].ui_te >= 0 && slp_te[t].ui_te == 0 { cnt++; } }
            if cnt == 2 { return true; }
        }
        if thr_set && n > 2 && slp_te[0].state == TE_VECTORIZE && fop == OP_INSERTELEMENT && slp_te[1].state == TE_VECTORIZE &&
           te_opcode(1) == OP_PHI {
            var all = true;
            for te in 2..n { if !te_is_gather(te as i32) { all = false; break; } }
            if all { return true; }
        }
    }
    if n >= min_tree { return false; }
    if slp_is_fully_vectorizable_tiny_tree(for_reduction) { return false; }
    let allowed_bv = n > 1 || (fhs && !te_is_alt_shuffle(0) && fop != OP_PHI && fop != OP_GEP && slp_all_same_block(te_scalars(0)));
    for te in n {
        let t = te as i32;
        if !te_is_gather(t) { continue; }
        var all = true;
        for v in te_scalars(t) {
            if is_inst_op(v, OP_EXTRACTELEMENT) || is_constant(v) { continue; }
            var any_ie = false;
            if allowed_bv && !slp_has_n_uses_or_more(v, SLP_USES_LIMIT) {
                var u = vals[v].first_use;
                while u >= 0 { if is_inst_op(uses[u].user, OP_INSERTELEMENT) { any_ie = true; break; } u = uses[u].next; }
            }
            if !any_ie { all = false; break; }
        }
        if all { return false; }
    }
    let back = (n - 1) as i32;
    if te_is_gather(back) && te_has_state(back) && te_is_alt_shuffle(back) {
        let bvf = te_vector_factor(back);
        if bvf > 2 && slp_all_same_block(te_scalars(back)) && !ty_is_vector(vals[te_scalar(back, 0)].ty) {
            let vt = slp_widened_type(vals[te_scalar(back, 0)].ty, bvf);
            if slp_scalarization_overhead_all(vals[te_scalar(back, 0)].ty, vt, bvf, true, false) > -thr { return false; }
        }
    }
    return true;
}
