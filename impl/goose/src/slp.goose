// SLPVectorizer, milestone 1 (the pass driver): port of the SLPVectorizerPass part of
// llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp (run, runImpl, collectSeedInstructions, vectorizeStoreChains,
// vectorizeChainsInBlock, vectorizeHorReduction, tryToVectorize, vectorizeRootInstruction, vectorizeInserts,
// vectorizeInsert{Value,Element}Inst / findBuildAggregate, vectorizeCmpInsts, vectorizeNonVectorizableInsts /
// isNonVectorizableInst / forEachOperandChainCandidate, isPoorThroughputOp's cache, vectorizeGEPIndices) and the
// static helpers they use (isValidElementType, getReductionInstr, matchRdxBop, isReductionCandidate,
// tryGetSecondaryReductionRoot, getNonPhiOperand, getAggregateSize).
//
// BoUpSLP (tree building, scheduling, reordering, the cost model, code generation), HorizontalReduction,
// getSameOpcode / InstructionsState, StoreChainContext and canConvertToFMA are NOT ported yet. The driver follows
// LLVM's control flow and fails loudly (slp_not_ported) at the first point where LLVM would enter one of them, so
// it never changes the IR: a function that reaches no such point is left as LLVM leaves it (it only vectorizes
// through BoUpSLP::vectorizeTree). Where the exact entry condition would need unported code to decide (e.g.
// whether two stores form a chain), the check is conservative: it fails loudly whenever LLVM *might* enter.
// See NOTES.md "SLPVectorizer" for the next steps.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import gen_attrs;
import intrinsics;
import datalayout;
import pm;
import vt;
import cfold;
import domtree;
import loopinfo;
import analyses;
import aa;
import bpi;
import laa;
import scev;
import flags;
import tti;
import tti_x86;
import tti_vec;
import vecutils;
import slp_util;
import slp_tree;
import slp_ops;
import slp_sched;
import slp_loads;
import slp_build;
import slp_stores;
import slp_hr;
import slp_phis;
import slp_transform;
import slp_treecost;

fn slp_not_ported(what: const u8[:]) { fatal(str("SLPVectorizer: ", what, " is not ported yet")); }

var slp_fv: i32 = -1;
// Stores / GEPs: MapVector<Value *, SmallVector<...>>: keys in insertion order, (key index, instruction) pairs
var slp_store_keys: i32[>..<];
var slp_store_k: i32[>..<];
var slp_store_i: i32[>..<];
var slp_gep_keys: i32[>..<];
var slp_gep_k: i32[>..<];
var slp_gep_i: i32[>..<];

fn slp_recursion_max_depth() -> i64 { flag_int("slp-recursion-max-depth", 12) }

// ---------------------------------------------------------------- static helpers

// matchRdxBop(I, V0, V1)
fn slp_match_rdx_bop(i: i32) -> bool, i32, i32 {
    if is_inst(i) && is_binary_op(iop(i)) { return true, op(i, 0), op(i, 1); }
    let id = inst_iid(i);
    if id == IID_maxnum || id == IID_minnum || id == IID_maximum || id == IID_minimum || id == IID_smax || id == IID_smin ||
       id == IID_umax || id == IID_umin {
        if cb_nargs(i) == 2 { return true, cb_arg(i, 0), cb_arg(i, 1); }
    }
    return false, -1, -1;
}
// isReductionCandidate(I)
fn slp_is_reduction_candidate(i: i32) -> bool {
    let ok, a, b = slp_match_rdx_bop(i);
    return ok || is_inst_op(i, OP_SELECT);
}

// getReductionInstr(DT, P, ParentBB, LI)
fn slp_reduction_instr(p: i32, bb: i32) -> i32 {
    fn dominated(p: i32, r: i32) -> bool { is_inst(r) && dt_dominates_block(DT_DOM, inst_parent(p), inst_parent(r)) }
    var rdx: i32 = -1;
    if phi_block(p, 0) == bb { rdx = if is_inst(phi_value(p, 0)) { phi_value(p, 0) } else { -1 }; }
    else if phi_block(p, 1) == bb { rdx = if is_inst(phi_value(p, 1)) { phi_value(p, 1) } else { -1 }; }
    if rdx >= 0 && dominated(p, rdx) { return rdx; }
    let l = li_loop_for(bb);
    if l < 0 { return -1; }
    let latch = loop_latch(l);
    if latch < 0 { return -1; }
    rdx = -1;
    if phi_block(p, 0) == latch { rdx = if is_inst(phi_value(p, 0)) { phi_value(p, 0) } else { -1 }; }
    else if phi_block(p, 1) == latch { rdx = if is_inst(phi_value(p, 1)) { phi_value(p, 1) } else { -1 }; }
    if rdx >= 0 && dominated(p, rdx) { return rdx; }
    return -1;
}

// HorizontalReduction::getFirstOperandIndex(I): 1 for a select, 0 otherwise
fn slp_first_operand_index(i: i32) -> i64 { hr_first_operand_index(i) }
// tryGetSecondaryReductionRoot(Phi, Root)
fn slp_secondary_reduction_root(phi: i32, root: i32) -> i32 {
    let k = slp_first_operand_index(root);
    let l = op(root, k);
    let r = op(root, k + 1);
    if l == phi { return if is_inst(r) { r } else { -1 }; }
    if r == phi { return if is_inst(l) { l } else { -1 }; }
    return -1;
}
// getNonPhiOperand(I, Phi)
fn slp_non_phi_operand(i: i32, phi: i32) -> i32 {
    let ok, a, b = slp_match_rdx_bop(i);
    if !ok { return -1; }
    let x = if a == phi { b } else { a };
    return if is_inst(x) { x } else { -1 };
}

// ---------------------------------------------------------------- seeds

// collectSeedInstructions(BB)
fn slp_collect_seeds(bb: i32) {
    slp_store_keys.clear(); slp_store_k.clear(); slp_store_i.clear();
    slp_gep_keys.clear(); slp_gep_k.clear(); slp_gep_i.clear();
    var i = block_first(bb);
    while i >= 0 {
        let o = iop(i);
        if o == OP_STORE {
            if ld_simple_slp(i) && slp_is_valid_element_type(vals[op(i, 0)].ty) {
                let key = get_underlying_object(op(i, 1), 6);
                var ki: i64 = -1;
                for k in slp_store_keys.len { if slp_store_keys[k] == key { ki = k; } }
                if ki < 0 { ki = slp_store_keys.len; slp_store_keys.push(key); }
                slp_store_k.push(ki as i32);
                slp_store_i.push(i);
            }
        } else if o == OP_GEP {
            if nops(i) == 2 {
                let idx = op(i, 1);
                if !is_constant(idx) && slp_is_valid_element_type(vals[idx].ty) && !ty_is_vector(vals[i].ty) {
                    let key = op(i, 0);
                    var ki: i64 = -1;
                    for k in slp_gep_keys.len { if slp_gep_keys[k] == key { ki = k; } }
                    if ki < 0 { ki = slp_gep_keys.len; slp_gep_keys.push(key); }
                    slp_gep_k.push(ki as i32);
                    slp_gep_i.push(i);
                }
            }
        }
        i = inst_next(i);
    }
}
fn ld_simple_slp(i: i32) -> bool { (insts[inst_of(i)].bits & 1) == 0 && insts[inst_of(i)].ord == 0 }

// vectorizeStoreChains(R) (slp_stores.goose)
fn slp_vectorize_store_chains() {
    slp_vectorize_store_chains_r(slp_store_keys.len, slp_store_k, slp_store_i);
}

// vectorizeGEPIndices(BB, R): a list of two or more GEPs asks BoUpSLP::getVectorElementSize
fn slp_vectorize_gep_indices() {
    for k in slp_gep_keys.len {
        var n: i64 = 0;
        for j in slp_gep_k.len { if slp_gep_k[j] as i64 == k { n++; } }
        if n < 2 { continue; }
        slp_not_ported("vectorizeGEPIndices (BoUpSLP::getVectorElementSize)");
    }
}

// ---------------------------------------------------------------- roots

// tryToVectorizeList(VL, R, MaxVFOnly, LimitToRegisterVF) (slp_stores.goose)
fn slp_try_to_vectorize_list(vl: const i32[:]) -> bool {
    return slp_try_to_vectorize_list_r(vl, false, false);
}

// vectorizeHorReduction(P, Root, BB, R, PostponedInsts)
fn slp_vectorize_hor_reduction(p: i32, root: i32, bb: i32, postponed: i32[>..<]&) -> bool {
    if !flag_bool("slp-vectorize-hor", true) { return false; }
    let try_ops_as_new_seeds = p >= 0 && is_inst(root) && is_binary_op(iop(root));
    if inst_parent(root) != bb || is_inst_op(root, OP_PHI) { return false; }
    var start = root;
    if try_ops_as_new_seeds && slp_is_reduction_candidate(root) && hr_rdx_kind(root) != RK_NONE {
        let nr = slp_secondary_reduction_root(p, root);
        if nr >= 0 { start = nr; }
    }
    // std::queue<std::pair<Instruction *, unsigned>> Stack
    var q_i: i32[>..<] = [];
    var q_l: i64[>..<] = [];
    var qh: i64 = 0;
    q_i.push(start);
    q_l.push(0);
    var visited: i32[>..<] = [];
    let maxd = slp_recursion_max_depth();
    while qh < q_i.len {
        let inst = q_i[qh];
        var level = q_l[qh];
        qh++;
        if slp_is_deleted(inst) { continue; }
        // TryToReduce(Inst): nothing is vectorized yet (a tree that is not tiny fails loudly), so it never returns
        // a value
        let red = slp_try_to_reduce_inst(inst);
        if red >= 0 { fatal("internal: SLP: unexpected reduced value"); }
        // TryAppendToPostponedInsts(Inst)
        var seed = inst;
        if try_ops_as_new_seeds && seed == root {
            seed = slp_non_phi_operand(root, p);
            if seed < 0 { break; }
        }
        let so = iop(seed);
        if so != OP_ICMP && so != OP_FCMP && so != OP_INSERTELEMENT && so != OP_INSERTVALUE { postponed.push(seed); }
        level++;
        if level < maxd {
            for k in nops(inst) {
                let o = op(inst, k);
                var seen = false;
                for x in visited { if x == o { seen = true; } }
                if seen { continue; }
                visited.push(o);
                if !is_inst(o) { continue; }
                let oo = iop(o);
                if oo != OP_PHI && oo != OP_ICMP && oo != OP_FCMP && oo != OP_INSERTELEMENT && oo != OP_INSERTVALUE &&
                   inst_parent(o) == bb {
                    q_i.push(o);
                    q_l.push(level);
                }
            }
        }
    }
    return false;
}

// tryToVectorize(I, R, FMACandidates, AllowFMACandidates)
var slp_fma_cands: i32[>..<];     // FMACandidates (SetVector, per block)
// TryToReduce(Inst, Ops) of tryToVectorize(I, ...): HorizontalReduction(Inst, Ops)
fn slp_try_to_reduce_pair(inst: i32, a: i32, b: i32) -> bool {
    if !slp_is_reduction_candidate(inst) { return false; }
    let ty: i32 = vals[inst].ty;
    if !slp_is_valid_element_type(ty) || ty_kind(ty) == TK_PTR { return false; }
    // HorizontalReduction(I, Ops): ReductionLimit 2
    hr_reset();
    hr_limit = 2;
    hr_root = inst;
    hr_kind = hr_rdx_kind(inst);
    hr_nops_lists = 1;
    hr_ops0.push(inst);
    hr_new_group();
    hr_group_push(a);
    hr_group_push(b);
    hr_r2o_add(a);
    hr_r2o_add(b);
    // matchReductionForOperands()
    hr_rk = hr_is_vectorizable(hr_kind, inst, true);
    if hr_rk == RO_NONE { return false; }
    let vt = slp_widened_type(ty, 2);
    var dem: bool[>..<] = [];
    for k in slp_num_elements(vt) { dem.push(true); }
    let sc = tc_add(tv_scalarization_overhead(vt, dem, false, true, TCK_RECIP_THROUGHPUT), tv_inst_cost(inst, TCK_RECIP_THROUGHPUT));
    let k = hr_kind;
    var rc: i64 = 0;
    if k == RK_ADD || k == RK_MUL || k == RK_OR || k == RK_AND || k == RK_XOR || k == RK_FADD || k == RK_FMUL {
        let fmf: u8 = if is_fp_math_operator(inst) { insts[inst_of(inst)].fmf } else { 0 };
        rc = tv_arith_reduction(iop(inst), vt, (fmf & FMF_REASSOC) == 0, TCK_RECIP_THROUGHPUT);
    } else {
        return false;
    }
    if rc >= sc { return false; }
    return hr_try_to_reduce() >= 0;
}
// tryToVectorize(I, R, FMACandidates, AllowFMACandidates)
fn slp_try_to_vectorize(i: i32, allow_fma: bool) -> bool {
    if i < 0 || is_dead(i) { return false; }
    let o = iop(i);
    if !(is_binary_op(o) || o == OP_ICMP || o == OP_FCMP) || ty_is_vector(vals[i].ty) { return false; }
    if !allow_fma && (o == OP_FADD || o == OP_FSUB) {
        let one: i32[1] = [i];
        if tc_valid(slp_can_convert_to_fma(one[..], slp_same_opcode1(i))) {
            var seen = false;
            for x in slp_fma_cands { if x == i { seen = true; } }
            if !seen { slp_fma_cands.push(i); }
            return false;
        }
    }
    let p = inst_parent(i);
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    if !is_inst(op0) || !is_inst(op1) || inst_parent(op0) != p || inst_parent(op1) != p || slp_is_deleted(op0) || slp_is_deleted(op1) {
        return false;
    }
    var ca: i32[>..<] = [];
    var cb: i32[>..<] = [];
    ca.push(op0); cb.push(op1);
    let a_bo = slp_is_binop(op0);
    let b_bo = slp_is_binop(op1);
    if a_bo && b_bo && slp_has_one_use(op1) {
        let b0 = op(op1, 0);
        let b1 = op(op1, 1);
        if slp_is_binop(b0) && inst_parent(b0) == p && !slp_is_deleted(b0) { ca.push(op0); cb.push(b0); }
        if slp_is_binop(b1) && inst_parent(b1) == p && !slp_is_deleted(b1) { ca.push(op0); cb.push(b1); }
    }
    if b_bo && a_bo && slp_has_one_use(op0) {
        let a0 = op(op0, 0);
        let a1 = op(op0, 1);
        if slp_is_binop(a0) && inst_parent(a0) == p && !slp_is_deleted(a0) { ca.push(a0); cb.push(op1); }
        if slp_is_binop(a1) && inst_parent(a1) == p && !slp_is_deleted(a1) { ca.push(a1); cb.push(op1); }
    }
    if ca.len == 1 {
        if slp_try_to_reduce_pair(i, op0, op1) { return true; }
        if allow_fma { return false; }
        let pr: i32[2] = [op0, op1];
        return slp_try_to_vectorize_list_r(pr[..], false, false);
    }
    let best, score = slp_find_best_root_pair(ca, cb, LA_FAIL);
    if best < 0 { return false; }
    if best == 0 && slp_try_to_reduce_pair(i, ca[best], cb[best]) { return true; }
    if allow_fma { return false; }
    let pr2: i32[2] = [ca[best], cb[best]];
    return slp_try_to_vectorize_list_r(pr2[..], false, false);
}

// vectorizeRootInstruction(P, Root, BB, R, FMACandidates)
fn slp_vectorize_root_instruction(p: i32, root: i32, bb: i32) -> bool {
    var postponed: i32[>..<] = [];
    var res = slp_vectorize_hor_reduction(p, root, bb, postponed);
    for x in postponed { if slp_try_to_vectorize(x, false) { res = true; } }
    return res;
}

// getAggregateSize(InsertInst)
fn slp_aggregate_size(i: i32) -> i64 {
    if iop(i) == OP_INSERTELEMENT { return ty_count(vals[i].ty); }
    var size: i64 = 1;
    var t: i32 = vals[i].ty;
    loop {
        if ty_is_struct(t) {
            let n = ty_count(t);
            // LLVM reads getElementType(0) of an empty struct out of bounds; treat it as not mappable (the
            // caller's canMapToVector rejects such types first)
            if n == 0 { return -1; }
            for k in n { if ty_field(t, k) != ty_field(t, 0) { return -1; } }
            size *= n;
            t = ty_field(t, 0);
        } else if ty_is_array(t) {
            size *= ty_count(t);
            t = ty_elem(t);
        } else if ty_kind(t) == TK_FVEC {
            size *= ty_count(t);
            return size;
        } else if ty_is_first_class(t) && !ty_is_aggregate(t) && ty_kind(t) != TK_LABEL && ty_kind(t) != TK_METADATA &&
                  ty_kind(t) != TK_TOKEN {
            return size;
        } else {
            return -1;
        }
    }
    return -1;
}

// BoUpSLP's MaxVecRegSize / MinVecRegSize (-slp-max-reg-size / -slp-min-reg-size override the TTI)
fn slp_max_vec_reg_size() -> i64 { if flag_given("slp-max-reg-size") { flag_int("slp-max-reg-size", 128) } else { tv_register_bit_width(1) } }
fn slp_min_vec_reg_size() -> i64 { if flag_given("slp-min-reg-size") { flag_int("slp-min-reg-size", 128) } else { tv_min_vector_register_bit_width() } }

// Type::isEmptyTy
recursive fn slp_is_empty_ty(t: i32) -> bool {
    if ty_is_array(t) { return ty_count(t) == 0 || slp_is_empty_ty(ty_elem(t)); }
    if ty_is_struct(t) {
        for k in ty_count(t) { if !slp_is_empty_ty(ty_field(t, k)) { return false; } }
        return true;
    }
    return false;
}
// BoUpSLP::canMapToVector(T)
fn slp_can_map_to_vector(t0: i32) -> i64 {
    var n: i64 = 1;
    var et = t0;
    while ty_is_struct(et) || ty_is_array(et) || ty_kind(et) == TK_FVEC {
        if slp_is_empty_ty(et) { return 0; }
        if ty_is_struct(et) {
            for k in ty_count(et) { if ty_field(et, k) != ty_field(et, 0) { return 0; } }
            n *= ty_count(et);
            et = ty_field(et, 0);
        } else {
            n *= ty_count(et);
            et = ty_elem(et);
        }
    }
    if !slp_is_valid_element_type(et) { return 0; }
    let vts = dl_store_size(ty_vector(et, n, false)) * 8;
    if vts < slp_min_vec_reg_size() || vts > slp_max_vec_reg_size() || vts != dl_store_size(t0) * 8 { return 0; }
    return n;
}

// findBuildAggregateRec(LastInsertInst, TTI, BuildVectorOpds, InsertElts, OperandOffset, R)
recursive fn slp_find_build_aggregate_rec(last0: i32, opds: i32[>..<]&, elts: i32[>..<]&, offset: i64) {
    var last = last0;
    loop {
        let ins = op(last, 1);
        let idx = slp_element_index(last, offset);
        if idx < 0 || slp_is_deleted(last) { return; }
        if is_inst_op(ins, OP_INSERTELEMENT) || is_inst_op(ins, OP_INSERTVALUE) {
            slp_find_build_aggregate_rec(ins, opds, elts, idx);
        } else {
            opds[idx] = ins;
            elts[idx] = last;
        }
        let nx = op(last, 0);
        if !(is_inst_op(nx, OP_INSERTVALUE) || is_inst_op(nx, OP_INSERTELEMENT)) || !slp_has_one_use(nx) { return; }
        last = nx;
    }
}
// findBuildAggregate(LastInsertInst, TTI, BuildVectorOpds, InsertElts, R)
fn slp_find_build_aggregate(last: i32, opds: i32[>..<]&, elts: i32[>..<]&) -> bool {
    let sz = slp_aggregate_size(last);
    if sz < 0 { return false; }
    var o: i32[>..<] = [];
    var e: i32[>..<] = [];
    for k in sz { o.push(-1); e.push(-1); }
    slp_find_build_aggregate_rec(last, o, e, 0);
    opds.clear();
    elts.clear();
    for x in o { if x >= 0 { opds.push(x); } }
    for x in e { if x >= 0 { elts.push(x); } }
    return opds.len >= 2;
}
// vectorizeInsertValueInst(IVI, BB, R, MaxVFOnly)
fn slp_vectorize_insert_value(ivi: i32, max_vf_only: bool) -> bool {
    if slp_can_map_to_vector(vals[ivi].ty) == 0 { return false; }
    var opds: i32[>..<] = [];
    var elts: i32[>..<] = [];
    if !slp_find_build_aggregate(ivi, opds, elts) { return false; }
    if max_vf_only && opds.len == 2 { return false; }
    if slp_dbg_on { errs("SLP: array mappable to vector: "); slp_dv(ivi); errs("\n"); slp_dbg_flush(); }
    let bvt: i32 = vals[elts[0]].ty;
    // getContainedTypes(BVType): the elements of a struct, else the type itself
    var nct: i64 = 1;
    var ct0: i32 = bvt;
    var same = true;
    if ty_is_struct(bvt) {
        nct = ty_count(bvt);
        ct0 = ty_field(bvt, 0);
        for k in nct { if ty_field(bvt, k) != ct0 { same = false; } }
    }
    if nct == elts.len && slp_is_valid_element_type(ct0) && same {
        if slp_try_to_vectorize_list_r(elts, max_vf_only, false) { return true; }
    }
    return slp_try_to_vectorize_list_r(opds, max_vf_only, false);
}
// vectorizeInsertElementInst(IEI, BB, R, MaxVFOnly)
fn slp_vectorize_insert_element(iei: i32, max_vf_only: bool) -> bool {
    var opds: i32[>..<] = [];
    var elts: i32[>..<] = [];
    if !slp_find_build_aggregate(iei, opds, elts) { return false; }
    var all_ee = true;
    for x in opds { if !(is_inst_op(x, OP_EXTRACTELEMENT) || is_undef_or_poison(x)) { all_ee = false; break; } }
    if all_ee {
        var m: i32[>..<] = [];
        if slp_is_fixed_vector_shuffle(opds, m) >= 0 { return false; }
    }
    if max_vf_only && elts.len == 2 { return false; }
    if slp_dbg_on { errs("SLP: array mappable to vector: "); slp_dv(iei); errs("\n"); slp_dbg_flush(); }
    return slp_try_to_vectorize_list_r(elts, max_vf_only, false);
}
fn slp_vectorize_insert(i: i32, max_vf_only: bool) -> bool {
    if iop(i) == OP_INSERTVALUE { return slp_vectorize_insert_value(i, max_vf_only); }
    return slp_vectorize_insert_element(i, max_vf_only);
}

// vectorizeInserts(Instructions, BB, R, FMACandidates)
fn slp_vectorize_inserts(insts_: i32[>..<]&, bb: i32) -> bool {
    var postponed: i32[>..<] = [];
    var k = insts_.len;
    while k > 0 {
        k--;
        let i = insts_[k];
        if slp_is_deleted(i) { continue; }
        slp_vectorize_insert(i, true);
        if slp_is_deleted(i) { continue; }
        slp_vectorize_hor_reduction(-1, i, bb, postponed);
        if slp_is_deleted(i) { continue; }
        slp_vectorize_insert(i, false);
    }
    for x in postponed { slp_try_to_vectorize(x, false); }
    insts_.clear();
    return false;
}

// vectorizeCmpInsts(reverse(CmpInsts), BB, R, FMACandidates)
fn slp_vectorize_cmp_insts(cmps: const i32[:], bb: i32) -> bool {
    var k = cmps.len;
    while k > 0 {
        k--;
        let i = cmps[k];
        if slp_is_deleted(i) { continue; }
        for j in nops(i) {
            if is_inst(op(i, j)) {
                slp_vectorize_root_instruction(-1, op(i, j), bb);
                if slp_is_deleted(i) { break; }
            }
        }
    }
    k = cmps.len;
    while k > 0 { k--; if !slp_is_deleted(cmps[k]) { slp_try_to_vectorize(cmps[k], false); } }
    var vals_: i32[>..<] = [];
    k = cmps.len;
    while k > 0 {
        k--;
        let c = cmps[k];
        if !slp_is_deleted(c) && slp_is_valid_element_type(slp_value_type(c, true)) { vals_.push(c); }
    }
    if vals_.len <= 1 { return false; }
    return slp_try_vectorize_value_sequence(vals_, 1);
}

// AnyMemIntrinsic
fn slp_is_any_mem_intrinsic(id: i32) -> bool {
    return id == IID_memcpy || id == IID_memmove || id == IID_memset || id == IID_memcpy_inline || id == IID_memset_inline ||
        id == IID_experimental_memset_pattern || id == IID_memcpy_element_unordered_atomic ||
        id == IID_memmove_element_unordered_atomic || id == IID_memset_element_unordered_atomic;
}
fn slp_is_assume_like(id: i32) -> bool {
    return id == IID_assume || id == IID_sideeffect || id == IID_pseudoprobe || id == IID_dbg_assign || id == IID_dbg_declare ||
        id == IID_dbg_value || id == IID_dbg_label || id == IID_invariant_start || id == IID_invariant_end ||
        id == IID_lifetime_start || id == IID_lifetime_end || id == IID_experimental_noalias_scope_decl ||
        id == IID_objectsize || id == IID_ptr_annotation || id == IID_var_annotation;
}
// VFDatabase::getMappings(CI) non-empty: a "vector-function-abi-variant" attribute (call site or callee)
fn slp_has_vf_mappings(c: i32) -> bool {
    if call_has_fn_str_attr(c, "vector-function-abi-variant") { slp_not_ported("VFDatabase::getMappings"); }
    return false;
}
// isNonVectorizableInst(I, TLI)
fn slp_is_non_vectorizable_inst(i: i32) -> bool {
    let o = iop(i);
    if is_callbase(i) {
        if vals[cb_callee(i)].kind == VK_INLINEASM { return false; }
        let id = inst_iid(i);
        if id != 0 && tti_is_intrinsic_inst(i) {
            if slp_is_assume_like(id) { return false; }
            if slp_is_any_mem_intrinsic(id) { return false; }
        }
        if o == OP_CALL {
            let vid = laa_vector_intrinsic_id_for_call(i);
            if is_trivially_vectorizable(vid) { return false; }
            if slp_has_vf_mappings(i) { return false; }
            var all_trivial = true;
            var any_ptr = false;
            for k in cb_nargs(i) {
                let a = cb_arg(i, k);
                if is_inst(a) && ty_kind(vals[a].ty) != TK_PTR { all_trivial = false; }
                if ty_kind(vals[a].ty) == TK_PTR { any_ptr = true; }
            }
            if all_trivial { return false; }
            if any_ptr { return false; }
        }
        return !ty_is_vector(vals[i].ty);
    }
    if o == OP_ATOMICRMW || o == OP_CMPXCHG { return true; }
    if o == OP_EXTRACTVALUE {
        let a = op(i, 0);
        if is_inst_op(a, OP_CALL) {
            if is_trivially_vectorizable(laa_vector_intrinsic_id_for_call(a)) { return true; }
            if slp_has_vf_mappings(a) { return true; }
            return false;
        }
    }
    if o == OP_RET {
        return nops(i) > 0 && !ty_is_vector(vals[op(i, 0)].ty) && is_inst(op(i, 0));
    }
    return false;
}

// forEachOperandChainCandidate(I, F, ForReduction): the (operand, position) pairs
fn slp_operand_chain_candidates(i: i32, for_reduction: bool, out: i32[>..<]&) {
    out.clear();
    let nonvect = flag_bool("slp-non-vectorizables-as-reductions", false);
    let o = iop(i);
    if is_callbase(i) {
        if for_reduction && !nonvect && cb_nargs(i) > 1 { return; }
        for k in cb_nargs(i) { out.push(cb_arg(i, k)); }
        return;
    }
    if o == OP_ATOMICRMW { out.push(op(i, 1)); return; }
    if o == OP_CMPXCHG { out.push(op(i, 1)); out.push(op(i, 2)); return; }
    if o == OP_EXTRACTVALUE { out.push(op(i, 0)); return; }
    if for_reduction && !nonvect { return; }
    if o == OP_STORE { out.push(op(i, 0)); return; }
    if o == OP_RET { if nops(i) > 0 { out.push(op(i, 0)); } return; }
    fatal("internal: SLP: unexpected instruction kind for operand-chain seeding");
}

// vectorizeNonVectorizableInsts(reverse(InstRange), BB, R, FMACandidates)
fn slp_vectorize_non_vectorizable_insts(range: const i32[:], bb: i32) -> bool {
    var insts_: i32[>..<] = [];
    var k = range.len;
    while k > 0 { k--; insts_.push(range[k]); }
    if insts_.len == 0 { return false; }
    // stable_sort by opcode
    for a in 1..insts_.len {
        var j = a;
        while j > 0 && iop(insts_[j]) < iop(insts_[j - 1]) { let t = insts_[j]; insts_[j] = insts_[j - 1]; insts_[j - 1] = t; j--; }
    }
    var cands: i32[>..<] = [];
    var seen: i32[>..<] = [];
    for i in insts_ {
        slp_operand_chain_candidates(i, true, cands);
        for x in cands {
            if !is_inst(x) || inst_parent(x) != bb || iop(x) == OP_SHUFFLEVECTOR || !slp_is_valid_element_type(vals[x].ty) { continue; }
            var s = false;
            for y in seen { if y == x { s = true; } }
            if s { continue; }
            seen.push(x);
            slp_vectorize_root_instruction(-1, x, bb);
        }
    }
    if insts_.len < 2 { return false; }
    // OperandGroupKey (RootKind, KindID, SubOp, FuncName, Position) per operand, as parallel arrays
    var ops_: i32[>..<] = [];
    var kk: i64[>..<] = [];
    var kid: i64[>..<] = [];
    var ksub: i64[>..<] = [];
    var kfn: i32[>..<] = [];
    var kpos: i64[>..<] = [];
    var seen2: i32[>..<] = [];
    for i in insts_ {
        if slp_is_deleted(i) { continue; }
        slp_operand_chain_candidates(i, false, cands);
        for pos in cands.len {
            let x = cands[pos];
            if !is_inst(x) || inst_parent(x) != bb || slp_is_deleted(x) || iop(x) == OP_SHUFFLEVECTOR ||
               (!slp_is_valid_element_type(vals[x].ty) && !tti_is_intrinsic_inst(x)) { continue; }
            var s = false;
            for y in seen2 { if y == x { s = true; } }
            if s { continue; }
            seen2.push(x);
            // BuildKey(I, Position)
            var rk: i64 = 0;
            var id: i64 = 0;
            var sub: i64 = 0;
            var fname: i32 = -1;
            if is_callbase(i) {
                if inst_iid(i) != 0 { rk = 1; id = inst_iid(i) as i64; }
                else if called_function(i) >= 0 { rk = 2; fname = called_function(i); }
                else { rk = 3; id = slp_value_id(cb_callee(i)); }
            } else {
                id = iop(i);
                if iop(i) == OP_ATOMICRMW { sub = insts[inst_of(i)].pred as i64; }
            }
            ops_.push(x); kk.push(rk); kid.push(id); ksub.push(sub); kfn.push(fname); kpos.push(pos);
        }
    }
    if ops_.len <= 1 { return false; }
    slp_nv_keys_set(ops_, kk, kid, ksub, kfn, kpos);
    return slp_try_vectorize_value_sequence(ops_, 2);
}

// isPoorThroughputOp's cache: (opcode or intrinsic id or callee, type key) pairs found cheap
// vectorizeChainsInBlock(BB, R)
fn slp_vectorize_chains_in_block(bb: i32) {
    slp_fma_cands.clear();
    // the PHI pass (slp_phis.goose)
    slp_vectorize_block_phis(bb);
    var p_inserts: i32[>..<] = [];
    var p_cmps: i32[>..<] = [];
    var p_insts: i32[>..<] = [];
    var p_stores: i32[>..<] = [];
    var poor: i64 = 0;
    slp_cheap_kind.clear(); slp_cheap_a.clear(); slp_cheap_b.clear();
    fn contains(xs: const i32[:], v: i32) -> bool { for y in xs { if y == v { return true; } } return false; }
    var i = block_first(bb);
    while i >= 0 {
        let cur = i;
        i = inst_next(i);
        if ty_kind(vals[cur].ty) == TK_SVEC { continue; }
        let o = iop(cur);
        if o == OP_PHI {
            if phi_nincoming(cur) == 2 {
                let root = slp_reduction_instr(cur, bb);
                if root >= 0 { slp_vectorize_root_instruction(cur, root, bb); }
            }
            for k in phi_nincoming(cur) {
                let ib = phi_block(cur, k);
                if bb == ib || !dt_has_node(DT_DOM, ib) { continue; }
                let pi = phi_value(cur, k);
                if is_inst(pi) && !(contains(p_cmps, pi) || contains(p_insts, pi) || contains(p_stores, pi) || contains(p_inserts, pi)) {
                    slp_vectorize_root_instruction(-1, pi, ib);
                }
            }
            continue;
        }
        let no_users = vals[cur].first_use < 0 && (vals[cur].ty == T_VOID || o == OP_CALL || o == OP_INVOKE);
        if no_users {
            var try_root = flag_bool("slp-vectorize-hor-store", false) || o != OP_STORE;
            if o == OP_STORE {
                let key = get_underlying_object(op(cur, 1), 6);
                var ki: i64 = -1;
                for k in slp_store_keys.len { if slp_store_keys[k] == key { ki = k; } }
                var cnt: i64 = 0;
                if ki >= 0 { for j in slp_store_k.len { if slp_store_k[j] as i64 == ki { cnt++; } } }
                let v = op(cur, 0);
                let one_use = vals[v].first_use >= 0 && uses[vals[v].first_use].next < 0;
                if (ki < 0 || cnt == 1) && one_use { try_root = true; }
            }
            if try_root {
                for k in nops(cur) {
                    let v = op(cur, k);
                    if is_inst(v) && !(contains(p_cmps, v) || contains(p_insts, v) || contains(p_stores, v) || contains(p_inserts, v)) {
                        slp_vectorize_root_instruction(-1, v, bb);
                    }
                }
            }
            // VectorizeInsertsAndCmps(AtTerminator)
            slp_vectorize_inserts(p_inserts, bb);
            if is_terminator_op(o) {
                slp_vectorize_cmp_insts(p_cmps, bb);
                p_cmps.clear();
                if p_insts.len > 0 { slp_vectorize_non_vectorizable_insts(p_insts, bb); }
                p_insts.clear();
            }
        }
        if o == OP_INSERTELEMENT || o == OP_INSERTVALUE { if !contains(p_inserts, cur) { p_inserts.push(cur); } }
        else if o == OP_ICMP || o == OP_FCMP { if !contains(p_cmps, cur) { p_cmps.push(cur); } }
        else if o == OP_STORE && !ty_is_vector(vals[op(cur, 0)].ty) && is_inst(op(cur, 0)) { if !contains(p_stores, cur) { p_stores.push(cur); } }
        else if slp_is_non_vectorizable_inst(cur) { if !contains(p_insts, cur) { p_insts.push(cur); } }
        else if flag_bool("slp-vectorize-poor-throughput", true) && slp_is_poor_throughput_op(cur) { poor++; }
    }
    // late post-process of the stores' operand chains
    let nonvect = flag_bool("slp-non-vectorizables-as-reductions", false);
    if p_stores.len > 0 && (nonvect || p_stores.len >= 2) {
        var tryv = true;
        if !flag_bool("slp-postprocess-stores-operands", false) && flag_int("slp-threshold", 0) >= 0 {
            var sty = slp_value_type(p_stores[0], false);
            if !slp_is_valid_element_type(sty) {
                tryv = false;
            } else {
                let fi = op(p_stores[0], 0);
                let bi = op(p_stores[p_stores.len - 1], 0);
                if !nonvect && p_stores.len == 2 && (!is_inst(fi) || !is_inst(bi) || iop(fi) != iop(bi)) {
                    tryv = false;
                } else {
                    sty = ty_int(dl_size_bits(ty_scalar(sty)));
                    let vt = ty_vector(sty, p_stores.len, false);
                    var dem: bool[>..<] = [];
                    for k in p_stores.len { dem.push(true); }
                    let ec = tv_scalarization_overhead(vt, dem, false, true, TCK_RECIP_THROUGHPUT);
                    tryv = ec <= p_stores.len + 1;
                }
            }
        }
        if tryv { slp_vectorize_non_vectorizable_insts(p_stores, bb); }
    }
    // the FMA candidates, now with AllowFMACandidates
    var fk: i64 = 0;
    while fk < slp_fma_cands.len {
        let fi = slp_fma_cands[fk];
        fk++;
        if slp_is_deleted(fi) { continue; }
        slp_try_to_vectorize(fi, true);
    }
    if poor >= 2 { slp_not_ported("vectorizeChainsInBlock's poor-throughput seeds (tryToVectorizeSequence)"); }
}

// ---------------------------------------------------------------- the pass

// SLPVectorizerPass::run(F, AM)
fn slp_vectorizer_run(fv: i32) -> u32 {
    // the analyses LLVM requests first: ScalarEvolution, TTI, (cached) TLI, AA, LoopInfo, DT, AC, DemandedBits
    tli_cur_fn = fv;
    tti_init_function(fv, globs[glob_of(fv)].module);
    aa_begin(fv);
    li_get(fv);
    dt_get(fv, DT_DOM);
    if !flag_bool("vectorize-slp", true) { return PA_ALL; }
    slp_fv = fv;
    if tv_number_of_registers(tv_register_class_for_type(true, -1)) == 0 { return PA_ALL; }
    if func_has_fn_attr(fv, AK_NoImplicitFloat) { return PA_ALL; }
    dt_update_dfs_numbers(fv, DT_DOM);
    scev_get(fv);
    slp_dbg_init();
    slp_r_begin(fv);
    slp_aaq = aq_push(CA_SIMPLE);
    if slp_dbg_on { errs("SLP: Analyzing blocks in "); errs(sbytes(vals[fv].name)); errs(".\n"); slp_dbg_flush(); }
    var po: i32[>..<] = [];
    bpi_post_order(fv, po);
    for bb in po {
        let t = block_terminator(bb);
        if inst_is_eh_pad(first_non_phi(bb)) || (t >= 0 && iop(t) == OP_UNREACHABLE) { continue; }
        slp_clear_reduction_data();
        slp_collect_seeds(bb);
        if slp_store_keys.len > 0 {
            if slp_dbg_on { errs("SLP: Found stores for "); errs_int(slp_store_keys.len); errs(" underlying objects.\n"); slp_dbg_flush(); }
            slp_vectorize_store_chains();
        }
        slp_vectorize_chains_in_block(bb);
        if slp_gep_keys.len > 0 { slp_vectorize_gep_indices(); }
    }
    aq_pop(slp_aaq);
    slp_aaq = -1;
    slp_delete_tree();
    return PA_ALL;
}
