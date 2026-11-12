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
fn slp_first_operand_index(i: i32) -> i64 { if is_inst_op(i, OP_SELECT) { 1 } else { 0 } }
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
    if try_ops_as_new_seeds && slp_is_reduction_candidate(root) {
        // HorizontalReduction::getRdxKind(Root) != RecurKind::None
        slp_not_ported("HorizontalReduction::getRdxKind");
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
        // TryToReduce(Inst): R.isAnalyzedReductionRoot is empty while nothing was reduced
        if slp_is_reduction_candidate(inst) { slp_not_ported("HorizontalReduction::matchAssociativeReduction"); }
        if iop(inst) == OP_FADD { slp_not_ported("HorizontalReduction::matchOrderedReduction"); }
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
fn slp_try_to_vectorize(i: i32, allow_fma: bool) -> bool {
    if i < 0 || is_dead(i) { return false; }
    let o = iop(i);
    if !(is_binary_op(o) || o == OP_ICMP || o == OP_FCMP) || ty_is_vector(vals[i].ty) { return false; }
    if !allow_fma && (o == OP_FADD || o == OP_FSUB) { slp_not_ported("canConvertToFMA (FMA candidates)"); }
    let p = inst_parent(i);
    let op0 = op(i, 0);
    let op1 = op(i, 1);
    if !is_inst(op0) || !is_inst(op1) || inst_parent(op0) != p || inst_parent(op1) != p { return false; }
    slp_not_ported("tryToVectorize of an instruction pair (HorizontalReduction / findBestRootPair / tryToVectorizeList)");
    return false;
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

// findBuildAggregate(LastInsertInst, ...) >= 2 operands: vectorizeInsert{Value,Element}Inst then reach
// tryToVectorizeList (the shuffle check of insertelement chains needs isFixedVectorShuffle, not ported)
fn slp_vectorize_insert(i: i32) -> bool {
    if iop(i) == OP_INSERTVALUE && slp_can_map_to_vector(vals[i].ty) == 0 { return false; }
    if slp_aggregate_size(i) < 0 { return false; }
    // the chain walk: count the distinct operand slots filled by the insert chain
    var n: i64 = 0;
    var x = i;
    while x >= 0 && (iop(x) == OP_INSERTELEMENT || iop(x) == OP_INSERTVALUE) {
        n++;
        let nx = op(x, 0);
        if !is_inst(nx) || !(iop(nx) == OP_INSERTELEMENT || iop(nx) == OP_INSERTVALUE) || vals[nx].first_use < 0 { break; }
        let u = vals[nx].first_use;
        if uses[u].next >= 0 { break; }
        x = nx;
    }
    if n >= 2 || is_inst_op(op(i, 1), OP_INSERTELEMENT) || is_inst_op(op(i, 1), OP_INSERTVALUE) {
        slp_not_ported("vectorizeInsertElementInst / vectorizeInsertValueInst (findBuildAggregate, tryToVectorizeList)");
    }
    return false;
}

// vectorizeInserts(Instructions, BB, R, FMACandidates)
fn slp_vectorize_inserts(insts_: i32[>..<]&, bb: i32) -> bool {
    var postponed: i32[>..<] = [];
    var k = insts_.len;
    while k > 0 {
        k--;
        let i = insts_[k];
        slp_vectorize_insert(i);
        slp_vectorize_hor_reduction(-1, i, bb, postponed);
        slp_vectorize_insert(i);
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
        for j in nops(i) { if is_inst(op(i, j)) { slp_vectorize_root_instruction(-1, op(i, j), bb); } }
    }
    k = cmps.len;
    while k > 0 { k--; slp_try_to_vectorize(cmps[k], false); }
    var nvals: i64 = 0;
    for c in cmps { if slp_is_valid_element_type(slp_value_type(c, true)) { nvals++; } }
    if nvals > 1 { slp_not_ported("vectorizeCmpInsts (tryToVectorizeSequence of compares: compareCmp / getSameOpcode)"); }
    return false;
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
    var nops_: i64 = 0;
    var seen2: i32[>..<] = [];
    for i in insts_ {
        slp_operand_chain_candidates(i, false, cands);
        for x in cands {
            if !is_inst(x) || inst_parent(x) != bb || iop(x) == OP_SHUFFLEVECTOR ||
               (!slp_is_valid_element_type(vals[x].ty) && !tti_is_intrinsic_inst(x)) { continue; }
            var s = false;
            for y in seen2 { if y == x { s = true; } }
            if s { continue; }
            seen2.push(x);
            nops_++;
        }
    }
    if nops_ > 1 { slp_not_ported("vectorizeNonVectorizableInsts (tryToVectorizeSequence of root operands)"); }
    return false;
}

// isPoorThroughputOp's cache: (opcode or intrinsic id or callee, type key) pairs found cheap
var slp_cheap_kind: i64[>..<];
var slp_cheap_a: i64[>..<];
var slp_cheap_b: i64[>..<];
fn slp_cheap_has(kind: i64, a: i64, b: i64) -> bool {
    for k in slp_cheap_kind.len { if slp_cheap_kind[k] == kind && slp_cheap_a[k] == a && slp_cheap_b[k] == b { return true; } }
    return false;
}
// getPoorThroughputTypeKey(Ty): (TypeID << 16) | scalar size
fn slp_type_key(t: i32) -> i64 { (slp_type_id(t) << 16) | tt_scalar_bits(t) }
// isPoorThroughputOp(I, TTI, TLI, Cache)
fn slp_is_poor_throughput_op(i: i32) -> bool {
    let o = iop(i);
    if !is_binary_op(o) && o != OP_CALL { return false; }
    let ty = vals[i].ty as i32;
    if ty_is_vector(ty) || ty_is_aggregate(ty) || !slp_is_valid_element_type(ty) { return false; }
    fn analyze(i: i32) -> bool {
        let sc = tti_instruction_cost(i, TCK_RECIP_THROUGHPUT);
        if sc < TCC_EXPENSIVE { return false; }
        // getVectorOpCost(I, MinVF = 2, TTI, TLI)
        if iop(i) == OP_CALL { slp_not_ported("isPoorThroughputOp of a call (getVectorOpCost: getVectorCallCosts)"); }
        let vc = tv_arith0(iop(i), ty_vector(vals[i].ty, 2, false), TCK_RECIP_THROUGHPUT);
        return vc < tc_mul(sc, 2);
    }
    fn check(kind: i64, a: i64, b: i64, i: i32) -> bool {
        if slp_cheap_has(kind, a, b) { return false; }
        if analyze(i) { return true; }
        slp_cheap_kind.push(kind); slp_cheap_a.push(a); slp_cheap_b.push(b);
        return false;
    }
    if o == OP_CALL {
        for k in cb_nargs(i) { if !slp_is_valid_element_type(vals[cb_arg(i, k)].ty) { return false; } }
        let id = laa_vector_intrinsic_id_for_call(i);
        if id != 0 { return check(1, id as i64, slp_type_key(ty), i); }
        let f = called_function(i);
        if f < 0 { return analyze(i); }
        return check(2, f as i64, 0, i);
    }
    return check(0, o, slp_type_key(ty), i);
}

// vectorizeChainsInBlock(BB, R)
fn slp_vectorize_chains_in_block(bb: i32) {
    // the PHI pass: two or more vectorizable PHIs go to tryToVectorizeSequence (PHICompare uses getSameOpcode)
    var nin: i64 = 0;
    var x = block_first(bb);
    while x >= 0 && iop(x) == OP_PHI {
        if phi_nincoming(x) > 128 { break; }
        if slp_is_valid_element_type(vals[x].ty) { nin++; }
        x = inst_next(x);
    }
    if nin > 1 { slp_not_ported("vectorizeChainsInBlock's PHI sequence (PHICompare / getSameOpcode / tryToVectorizeList)"); }
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
