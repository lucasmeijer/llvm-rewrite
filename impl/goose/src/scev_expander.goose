// SCEVExpander: generate IR that computes a SCEV.
// Port of llvm/lib/Transforms/Utils/ScalarEvolutionExpander.cpp and
// llvm/include/llvm/Transforms/Utils/ScalarEvolutionExpander.h (LLVM 23.1.5): PoisonFlags, ReuseOrCreateCast,
// findInsertPointAfter, eraseDeadInstructions, GetOptimalInsertionPointForCastOf, InsertNoopCastOfTo, InsertBinop,
// expandAddToGEP, PickMostRelevantLoop / getRelevantLoop / LoopCompare, the visit* methods,
// isNormalAddRecExprPHI, getIVIncOperand, fixupInsertPoints, hoistIVInc, canReuseFlagsFromOriginalIVInc,
// isExpandedAddRecExprPHI, expandIVInc, canBeCheaplyTransformed, IsIncrementNSW/NUW, getAddRecExprPHILiterally,
// expandAddRecExprLiterally, tryToReuseLCSSAPhi, expandMinMaxExpr, expandCodeFor, FindValueInExprValueMap,
// expand, rememberInstruction, rememberFlags, dropPoisonGeneratingAnnotationsAndReinfer, replaceCongruentIVInc,
// replaceCongruentIVs, hasRelatedExistingExpansion, costAndCollectOperands, isHighCostExpansion(Helper),
// fixupLCSSAFormFor, SCEVFindUnsafe / isSafeToExpand(At), SCEVExpanderCleaner::cleanup.
// Also Loop::getCanonicalInductionVariable and LoopInfo::replacementPreservesLCSSAForm /
// movementPreservesLCSSAForm (LoopInfo.cpp, LoopInfo.h), Loop::isLoopSimplifyForm.
// Not ported (fail loudly): the predicate expansions (expandCodeForPredicate, generateOverflowCheck: used by the
// vectorizers' runtime checks) and post-increment normalization (normalizeForPostIncUse: LSR).
//
// One expander exists at a time (`sx_begin` / `sx_end`; SCEVExpander's members are the sx_* globals). The
// expansion functions form one recursive cycle (expand -> visit* -> expand), so their SmallVectors are runs on
// global scratch stacks (sx_ol for OpsAndLoops, sx_tmp) truncated to a mark before returning.
// The IRBuilder<InstSimplifyFolder, IRBuilderCallbackInserter> is sxb_*: an insertion iterator (block,
// instruction or -1 = end(), head bit) and a debug location; every Create* first tries InstSimplify with a bare
// SimplifyQuery(DL) and otherwise inserts, names and calls rememberInstruction. SCEVInsertPointGuard is
// sx_guard_push / sx_guard_pop (the stack lets fixupInsertPoints move a saved position).
// InsertedExpressions' TrackingVHs and InsertedIVs' WeakVHs are value handles (wvh.goose).
import std;
import ir;
import irutil;
import instinfo;
import calls;
import pm;
import gen_iids;
import intrinsics;
import autoupgrade;
import constfold;
import cfold;
import datalayout;
import vt;
import implied;
import poison;
import domcond;
import instsimplify;
import local;
import apint;
import loopinfo;
import loopnest;
import domtree;
import lcssa;
import tti;
import flags;
import wvh;
import stdsort;
import scev;
import scev_create;
import scev_range;
import scev_eval;
import scev_btc;
import scev_pred;
import scev_update;

// cl::opt scev-cheap-expansion-budget
fn sx_cheap_budget() -> i64 { flag_int("scev-cheap-expansion-budget", 4) }

// BasicBlock::iterator: the instruction (-1 = end()) and the head bit
struct SxIt { bb: i32, pos: i32, head: bool }
struct SxGuard { bb: i32, pos: i32, head: bool, dl: i32 }
struct SxOL { l: i32, s: i32 }

// ---------------------------------------------------------------------------------------------
// State (SCEVExpander's members)

var sx_active: bool = false;
var sx_ivname: u8[>..];
var sx_preserve_lcssa: bool = true;
var sx_iexpr = hm_new();               // InsertedExpressions: (SCEV, insert point) -> TrackingVH handle
var sx_ivals = hm_new();               // InsertedValues (set); order in sx_ivals_order
var sx_ivals_order: i32[>..<];
var sx_ipvals = hm_new();              // InsertedPostIncValues
var sx_ipvals_order: i32[>..<];
var sx_reused = hm_new();              // ReusedValues
var sx_oflags = hm_new();              // OrigFlags: instruction -> its poison-generating flag byte
var sx_oflags_order: i32[>..<];
var sx_inserted_ivs: i32[>..<];        // InsertedIVs (WeakVH handles)
var sx_rel = hm_new();                 // RelevantLoops: SCEV -> loop + 1 (0 = null)
var sx_post_inc: i32[>..<];            // PostIncLoops
var sx_ivinc_loop: i32 = -1;           // IVIncInsertLoop
var sx_ivinc_pos: i32 = -1;            // IVIncInsertPos
var sx_chained = hm_new();             // ChainedPhis
var sx_canonical: bool = true;         // CanonicalMode
var sx_lsr: bool = false;              // LSRMode
var sx_safe_udiv: bool = false;        // SafeUDivMode
var sx_guards: SxGuard[>..<];          // InsertPointGuards
var sx_wvh_mark: i64 = 0;
// scratch
var sx_ol: SxOL[>..<];                 // OpsAndLoops runs
var sx_tmp: i32[>..<];
var sx_seen: i32[>..<];
var sx_nm: u8[>..];                    // names under construction

// SCEVExpander(SE, Name, PreserveLCSSA)
fn sx_begin(name: const u8[:], preserve_lcssa: bool) {
    if sx_active { fatal("internal: a second SCEVExpander while one is alive is not supported"); }
    sx_active = true;
    sx_ivname.resize(0);
    sx_ivname.append(name);
    sx_preserve_lcssa = preserve_lcssa;
    sx_clear();
    hm_clear(sx_rel);
    sx_post_inc.clear();
    sx_ivinc_loop = -1;
    sx_ivinc_pos = -1;
    sx_canonical = true;
    sx_lsr = false;
    sx_safe_udiv = false;
    sx_guards.clear();
    sx_wvh_mark = wvh_mark();
    sxb_bb = -1; sxb_pos = -1; sxb_head = false; sxb_dl = -1;
}
// ~SCEVExpander
fn sx_end() {
    if sx_guards.len != 0 { fatal("internal: SCEVExpander insert point guards are unbalanced"); }
    sx_clear();
    wvh_release(sx_wvh_mark);
    sx_active = false;
}
// clear()
fn sx_clear() {
    hm_clear(sx_iexpr);
    hm_clear(sx_ivals); sx_ivals_order.clear();
    hm_clear(sx_ipvals); sx_ipvals_order.clear();
    hm_clear(sx_reused);
    hm_clear(sx_oflags); sx_oflags_order.clear();
    hm_clear(sx_chained);
    sx_inserted_ivs.clear();
}
fn sx_disable_canonical_mode() { sx_canonical = false; }
fn sx_enable_lsr_mode() { sx_lsr = true; }
fn sx_set_iv_inc_insert_pos(l: i32, pos: i32) { sx_ivinc_loop = l; sx_ivinc_pos = pos; }
fn sx_set_chained_phi(pn: i32) { hm_put(sx_chained, pn as u64, 1); }
fn sx_clear_post_inc() { sx_post_inc.clear(); hm_clear(sx_ipvals); sx_ipvals_order.clear(); }
recursive fn sx_post_inc_has(l: i32) -> bool { for x in sx_post_inc { if x == l { return true; } } return false; }

// isInsertedInstruction
recursive fn sx_is_inserted(i: i32) -> bool { i >= 0 && (hm_has(sx_ivals, i as u64) || hm_has(sx_ipvals, i as u64)) }
recursive fn sx_set_add(m: HMap&, order: i32[>..<]&, v: i32) {
    if hm_has(m, v as u64) { return; }
    hm_put(m, v as u64, 1);
    order.push(v);
}
// rememberInstruction
recursive fn sx_remember_instruction(i: i32) {
    if sx_post_inc.len > 0 { sx_set_add(sx_ipvals, sx_ipvals_order, i); } else { sx_set_add(sx_ivals, sx_ivals_order, i); }
}
// rememberFlags: OrigFlags.try_emplace(I, PoisonFlags(I))
fn sx_remember_flags(i: i32) {
    if hm_has(sx_oflags, i as u64) { return; }
    hm_put(sx_oflags, i as u64, insts[inst_of(i)].flags as i64);
    sx_oflags_order.push(i);
}
// getAllInsertedInstructions (DenseSet iteration order: we use insertion order)
fn sx_all_inserted_instructions(out: i32[>..<]&) {
    out.clear();
    for v in sx_ivals_order {
        if !hm_has(sx_ivals, v as u64) || hm_has(sx_reused, v as u64) { continue; }
        if is_inst(v) { out.push(v); }
    }
    for v in sx_ipvals_order {
        if !hm_has(sx_ipvals, v as u64) || hm_has(sx_reused, v as u64) { continue; }
        if is_inst(v) { out.push(v); }
    }
}
fn sx_inserted_ivs_get(out: i32[>..<]&) { out.clear(); for h in sx_inserted_ivs { out.push(wvh_get(h)); } }

// ---------------------------------------------------------------------------------------------
// IRBuilder<InstSimplifyFolder, IRBuilderCallbackInserter>

var sxb_bb: i32 = -1;
var sxb_pos: i32 = -1;       // insert before this instruction; -1 = end()
var sxb_head: bool = false;
var sxb_dl: i32 = -1;        // StoredDL (!dbg md id, -1 = none)

// SetInsertPoint(Instruction *I): DL = I's
recursive fn sxb_set_before(i: i32) { sxb_bb = inst_parent(i); sxb_pos = i; sxb_head = false; sxb_dl = inst_get_md(i, 0); }
// SetInsertPoint(BB, It) / SetInsertPoint(It): DL = the instruction's unless end()
recursive fn sxb_set_it(it: SxIt) {
    sxb_bb = it.bb; sxb_pos = it.pos; sxb_head = it.head;
    if it.pos >= 0 { sxb_dl = inst_get_md(it.pos, 0); }
}
recursive fn sxb_it() -> SxIt { SxIt { bb: sxb_bb, pos: sxb_pos, head: sxb_head } }
recursive fn sxb_clear() { sxb_bb = -1; sxb_pos = -1; sxb_head = false; }

// SCEVInsertPointGuard
recursive fn sx_guard_push() { sx_guards.push(SxGuard { bb: sxb_bb, pos: sxb_pos, head: sxb_head, dl: sxb_dl }); }
recursive fn sx_guard_pop() {
    let g = sx_guards.pop();
    // restoreIP(InsertPoint(Block, Point)); SetCurrentDebugLocation(DbgLoc)
    sxb_bb = g.bb; sxb_pos = g.pos; sxb_head = g.head; sxb_dl = g.dl;
}

// IRBuilderBase::Insert(I, Name) with the callback inserter
recursive fn sxb_insert(iv: i32, name: const u8[:]) -> i32 {
    if sxb_bb < 0 { fatal("internal: SCEVExpander builder without an insertion point"); }
    inst_insert_at(iv, sxb_bb, sxb_pos, sxb_head);
    if vals[iv].ty != T_VOID { set_name(iv, name); }
    sx_remember_instruction(iv);
    // SetInstDebugLocation: StoredDL.orElse(I->getDebugLoc())
    if sxb_dl >= 0 { inst_set_md(iv, 0, sxb_dl); }
    return iv;
}

// InstSimplifyFolder: SimplifyQuery(DL) (no DT, AC, TLI, context, DomConditionCache)
var sxf_save_dt: bool = false;
var sxf_save_ac: bool = false;
var sxf_save_tli: bool = false;
var sxf_save_dc: bool = false;
recursive fn sxf_begin() -> SQ {
    sxf_save_dt = sq_no_dt; sxf_save_ac = sq_no_ac; sxf_save_tli = sq_no_tli; sxf_save_dc = dc_active;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true; dc_active = false;
    return sq_new(-1);
}
recursive fn sxf_end() { sq_no_dt = sxf_save_dt; sq_no_ac = sxf_save_ac; sq_no_tli = sxf_save_tli; dc_active = sxf_save_dc; }
recursive fn sxf_binop(o: i64, a: i32, b: i32) -> i32 {
    let q = sxf_begin();
    let r = simplify_binop(o, a, b, q, RECURSION_LIMIT);
    sxf_end();
    return r;
}
recursive fn sxf_cast(o: i64, v: i32, ty: i32) -> i32 {
    let q = sxf_begin();
    let r = simplify_cast(o, v, ty, q, RECURSION_LIMIT);
    sxf_end();
    return r;
}
recursive fn sxf_cmp(p: i64, a: i32, b: i32) -> i32 {
    let q = sxf_begin();
    let r = simplify_cmp(p, a, b, q, RECURSION_LIMIT);
    sxf_end();
    return r;
}
recursive fn sxf_select(c: i32, t: i32, f: i32) -> i32 {
    let q = sxf_begin();
    let r = simplify_select(c, t, f, 0, q, RECURSION_LIMIT);
    sxf_end();
    return r;
}

// CreateNoWrapBinOp / CreateAdd / CreateSub / CreateMul (FoldNoWrapBinOp ignores the flags)
recursive fn sxb_binop(o: i64, a: i32, b: i32, nuw: bool, nsw: bool, name: const u8[:]) -> i32 {
    let f = sxf_binop(o, a, b);
    if f >= 0 { return f; }
    let iv = create_inst(o, vals[a].ty, [a, b]);
    sxb_insert(iv, name);
    var fl: u8 = 0;
    if nuw { fl |= FL_NUW; }
    if nsw { fl |= FL_NSW; }
    insts[inst_of(iv)].flags = fl;
    return iv;
}
// CreateCast(Op, V, DestTy, Name) (and CreateSExt / CreatePtrToInt / CreateIntToPtr / CreateBitCast)
recursive fn sxb_cast(o: i64, v: i32, ty: i32, name: const u8[:]) -> i32 {
    if vals[v].ty == ty { return v; }
    let f = sxf_cast(o, v, ty);
    if f >= 0 { return f; }
    return sxb_insert(create_inst(o, ty, [v]), name);
}
// CreateTrunc(V, DestTy, Name, IsNUW, IsNSW)
recursive fn sxb_trunc(v: i32, ty: i32, name: const u8[:], nuw: bool, nsw: bool) -> i32 {
    if vals[v].ty == ty { return v; }
    let f = sxf_cast(OP_TRUNC, v, ty);
    if f >= 0 { return f; }
    let iv = create_inst(OP_TRUNC, ty, [v]);
    var fl: u8 = 0;
    if nuw { fl |= FL_NUW; }
    if nsw { fl |= FL_NSW; }
    insts[inst_of(iv)].flags = fl;
    return sxb_insert(iv, name);
}
// CreateZExt(V, DestTy, Name, IsNonNeg)
recursive fn sxb_zext(v: i32, ty: i32, name: const u8[:], nneg: bool) -> i32 {
    if vals[v].ty == ty { return v; }
    let f = sxf_cast(OP_ZEXT, v, ty);
    if f >= 0 { return f; }
    let iv = sxb_insert(create_inst(OP_ZEXT, ty, [v]), name);
    if nneg { insts[inst_of(iv)].flags |= FL_NNEG; }
    return iv;
}
// CreateICmp
recursive fn sxb_icmp(p: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    let f = sxf_cmp(p, a, b);
    if f >= 0 { return f; }
    let iv = create_inst(OP_ICMP, cmp_result_ty(vals[a].ty), [a, b]);
    insts[inst_of(iv)].pred = p as u8;
    return sxb_insert(iv, name);
}
// CreateSelect(C, True, False, Name)
recursive fn sxb_select(c: i32, t: i32, f: i32, name: const u8[:]) -> i32 {
    let r = sxf_select(c, t, f);
    if r >= 0 { return r; }
    return sxb_insert(create_inst(OP_SELECT, vals[t].ty, [c, t, f]), name);
}
// CreateFreeze (no folder call)
recursive fn sxb_freeze(v: i32, name: const u8[:]) -> i32 { sxb_insert(create_inst(OP_FREEZE, vals[v].ty, [v]), name) }
// CreatePtrAdd(Ptr, Offset, Name, NW) = CreateGEP(i8, Ptr, Offset, Name, NW)
recursive fn sxb_ptr_add(p: i32, off: i32, name: const u8[:], nw: u8) -> i32 {
    let mark = is_ops.len;
    is_ops.push(p);
    is_ops.push(off);
    let q = sxf_begin();
    let f = simplify_gep(T_I8, p, mark + 1, 1, nw, q, RECURSION_LIMIT);
    sxf_end();
    is_ops.resize(mark);
    if f >= 0 { return f; }
    let iv = create_inst(OP_GEP, vals[p].ty, [p, off]);
    insts[inst_of(iv)].ty2 = T_I8;
    insts[inst_of(iv)].flags = nw;
    return sxb_insert(iv, name);
}
// CreateIntrinsic(ID, {OverloadTy}, Args, nullptr, Name): FoldIntrinsic first, the declaration only if needed
recursive fn sxb_intrinsic(id: i64, ovt: i32, a: i32, b: i32, nargs: i64, name: const u8[:]) -> i32 {
    var ov: i32[1] = [ovt];
    let rty = ty_fn_ret(intr_get_type(id, ov));
    let mark = is_ops.len;
    if nargs >= 1 { is_ops.push(a); }
    if nargs >= 2 { is_ops.push(b); }
    let q = sxf_begin();
    let fv = block_func(sxb_bb);
    let f = simplify_intrinsic_args(id as i32, rty, mark, nargs, 0, q, fv, EB_IGNORE, RM_NEAREST);
    sxf_end();
    is_ops.resize(mark);
    if f >= 0 { return f; }
    let decl = au_get_declaration(id, ov);
    let fty = globs[glob_of(decl)].vty;
    var iv: i32 = -1;
    if nargs == 0 { iv = create_inst(OP_CALL, ty_fn_ret(fty), [decl]); }
    else if nargs == 1 { iv = create_inst(OP_CALL, ty_fn_ret(fty), [a, decl]); }
    else { iv = create_inst(OP_CALL, ty_fn_ret(fty), [a, b, decl]); }
    insts[inst_of(iv)].ty2 = fty;
    return sxb_insert(iv, name);
}
// CreatePHI(Ty, NumReservedValues, Name)
recursive fn sxb_phi(ty: i32, reserve: i64, name: const u8[:]) -> i32 {
    let pn = new_inst(OP_PHI, ty, reserve);
    vals[pn].nops = 0;
    return sxb_insert(pn, name);
}

// sx_nm = a + b (a name built from pieces; copy names out of the string pool before inserting)
recursive fn sx_name2(a: const u8[:], b: const u8[:]) -> const u8[:] {
    sx_nm.resize(0);
    sx_nm.append(a);
    sx_nm.append(b);
    return sx_nm;
}

// ---------------------------------------------------------------------------------------------
// Small IR helpers

// BasicBlock::getFirstInsertionPt (head bit set)
recursive fn sx_first_insertion_pt(bb: i32) -> SxIt {
    var i = block_first(bb);
    while i >= 0 && iop(i) == OP_PHI { i = inst_next(i); }
    if i >= 0 && inst_is_eh_pad(i) { i = inst_next(i); }
    return SxIt { bb: bb, pos: i, head: true };
}
// std::next(It): the head bit is cleared
recursive fn sx_next(it: SxIt) -> SxIt { SxIt { bb: it.bb, pos: if it.pos >= 0 { inst_next(it.pos) } else { -1 }, head: false } }
recursive fn sx_term_it(bb: i32) -> SxIt { SxIt { bb: bb, pos: block_terminator(bb), head: false } }

// Loop::isLoopInvariant(V)
recursive fn sx_loop_invariant_v(l: i32, v: i32) -> bool { !is_inst(v) || !loop_contains(l, inst_parent(v)) }
// Loop::isLoopSimplifyForm
fn loop_is_simplify_form(l: i32) -> bool { loop_preheader(l) >= 0 && loop_latch(l) >= 0 && loop_has_dedicated_exits(l) }
// Loop::hasLoopInvariantOperands
fn loop_has_loop_invariant_operands(l: i32, i: i32) -> bool {
    for k in nops(i) { if !sx_loop_invariant_v(l, op(i, k)) { return false; } }
    return true;
}

// LoopInfo::replacementPreservesLCSSAForm(From, To)
recursive fn li_replacement_preserves_lcssa(from: i32, to: i32) -> bool {
    if !is_inst(to) { return true; }
    if inst_parent(to) == inst_parent(from) { return true; }
    let tl = li_loop_for(inst_parent(to));
    if tl < 0 { return true; }
    let fl = li_loop_for(inst_parent(from));
    return fl >= 0 && loop_contains_loop(tl, fl);
}
// LoopInfo::movementPreservesLCSSAForm(Inst, NewLoc)
fn li_movement_preserves_lcssa(i: i32, newloc: i32) -> bool {
    let obb = inst_parent(i);
    let nbb = inst_parent(newloc);
    if obb == nbb { return true; }
    let ol = li_loop_for(obb);
    let nl = li_loop_for(nbb);
    if ol == nl { return true; }
    // Contains(Outer, Inner) with null as the outermost loop
    let nl_contains_ol = nl < 0 || (ol >= 0 && loop_contains_loop(nl, ol));
    if !nl_contains_ol {
        var u = vals[i].first_use;
        while u >= 0 {
            let ui = uses[u].user;
            let ubb = if iop(ui) == OP_PHI { use_aux[u] } else { inst_parent(ui) };
            if ubb != nbb && li_loop_for(ubb) != nl { return false; }
            u = uses[u].next;
        }
    }
    let ol_contains_nl = ol < 0 || (nl >= 0 && loop_contains_loop(ol, nl));
    if !ol_contains_nl {
        if iop(i) == OP_PHI { return false; }
        for k in nops(i) {
            let d = op(i, k);
            if !is_inst(d) { return false; }
            let db = inst_parent(d);
            if db != nbb && li_loop_for(db) != nl { return false; }
        }
    }
    return true;
}

// Loop::getIncomingAndBackEdge
fn loop_incoming_and_back_edge(l: i32) -> i32, i32 {
    let h = loop_header(l);
    var incoming: i32 = -1;
    var backedge: i32 = -1;
    var n = 0;
    var ok = true;
    each_pred(h) { p =>
        n++;
        if n == 1 { incoming = p; } else if n == 2 { backedge = p; } else { ok = false; }
    };
    if !ok || n != 2 { return -1, -1; }
    if loop_contains(l, incoming) {
        if loop_contains(l, backedge) { return -1, -1; }
        let t = incoming; incoming = backedge; backedge = t;
    } else if !loop_contains(l, backedge) { return -1, -1; }
    return incoming, backedge;
}
// Loop::getCanonicalInductionVariable
recursive fn loop_canonical_induction_variable(l: i32) -> i32 {
    let incoming, backedge = loop_incoming_and_back_edge(l);
    if incoming < 0 { return -1; }
    var p = block_first(loop_header(l));
    while p >= 0 && iop(p) == OP_PHI {
        let c = phi_value(p, phi_block_index(p, incoming));
        if is_cint(c) && ap_is_zero(ci_ap(c)) {
            let inc = phi_value(p, phi_block_index(p, backedge));
            if is_inst(inc) && iop(inc) == OP_ADD && op(inc, 0) == p {
                let c1 = op(inc, 1);
                if is_cint(c1) && ap_is_one(ci_ap(c1)) { return p; }
            }
        }
        p = inst_next(p);
    }
    return -1;
}

// PHINode::getIncomingValueForBlock
recursive fn sx_phi_in(p: i32, bb: i32) -> i32 { phi_value(p, phi_block_index(p, bb)) }
// PHINode::isComplete
recursive fn sx_phi_complete(p: i32) -> bool {
    var ok = true;
    each_pred(inst_parent(p)) { b => if phi_block_index(p, b) < 0 { ok = false; } };
    return ok;
}
// SCEV::isNonConstantNegative
recursive fn sx_non_constant_negative(s: i32) -> bool {
    if sc_kind(s) != SC_MUL { return false; }
    let c = sc_op(s, 0);
    if !sc_is_const(c) { return false; }
    return ap_is_neg(sc_ap(c));
}
recursive fn sx_is_cast_op(i: i32) -> bool { is_inst(i) && is_cast_op(iop(i)) }

// ---------------------------------------------------------------------------------------------
// Casts

// ReuseOrCreateCast(V, Ty, Op, IP)
recursive fn sx_reuse_or_create_cast(v: i32, ty: i32, o: i64, ip: SxIt) -> i32 {
    let bip = sxb_pos;
    var ret: i32 = -1;
    if !is_constant(v) {
        var u = vals[v].first_use;
        while u >= 0 {
            let ci = uses[u].user;
            u = uses[u].next;
            if vals[ci].ty != ty { continue; }
            if !sx_is_cast_op(ci) || iop(ci) != o { continue; }
            if ip.bb == inst_parent(ci) && bip != ci && (ip.pos == ci || (ip.pos >= 0 && comes_before(ci, ip.pos))) { ret = ci; break; }
        }
    }
    if ret < 0 {
        sx_guard_push();
        sxb_set_before(ip.pos);
        var nm: u8[>..] = [];
        nm.append(val_name(v));
        ret = sxb_cast(o, v, ty, nm);
        sx_guard_pop();
    }
    return ret;
}

// findInsertPointAfter(I, MustDominate)
recursive fn sx_find_insert_point_after(i: i32, must_dominate: i32) -> SxIt {
    var ip = SxIt { bb: -1, pos: -1, head: false };
    // getInsertionPointAfterDef
    var ok = true;
    if iop(i) == OP_PHI { ip = sx_first_insertion_pt(inst_parent(i)); }
    else if iop(i) == OP_INVOKE { ip = sx_first_insertion_pt(term_succ(i, 0)); }
    else if iop(i) == OP_CALLBR { ok = false; }
    else { ip = SxIt { bb: inst_parent(i), pos: inst_next(i), head: true }; }
    if ok && ip.pos < 0 { ok = false; }
    if !ok { ip = SxIt { bb: inst_parent(must_dominate), pos: must_dominate, head: false }; }
    while sx_is_inserted(ip.pos) && ip.pos != must_dominate { ip = sx_next(ip); }
    return ip;
}

// eraseDeadInstructions(Root)
fn sx_erase_dead_instructions(root: i32) {
    var wl: i32[>..<] = [];
    sx_all_inserted_instructions(wl);
    var deleted = hm_new();
    while wl.len > 0 {
        let v = wl.pop();
        if hm_has(deleted, v as u64) { continue; }
        if !is_inst(v) || v == root || !sx_is_inserted(v) || !is_instruction_trivially_dead(v) { continue; }
        for k in nops(v) { wl.push(op(v, k)); }
        hm_del(sx_ivals, v as u64);
        hm_del(sx_ipvals, v as u64);
        hm_put(deleted, v as u64, 1);
        inst_erase_from_parent(v);
    }
}

// GetOptimalInsertionPointForCastOf(V)
recursive fn sx_optimal_cast_point(v: i32) -> SxIt {
    if is_arg(v) {
        let entry = func_entry(args_parent[vals[v].sub]);
        var i = block_first(entry);
        var head = true;
        while i >= 0 && iop(i) == OP_BITCAST && is_arg(op(i, 0)) && op(i, 0) != v { i = inst_next(i); head = false; }
        return SxIt { bb: entry, pos: i, head: head };
    }
    if is_inst(v) { return sx_find_insert_point_after(v, sxb_pos); }
    return sx_first_insertion_pt(func_entry(block_func(sxb_bb)));
}

// CastInst::getCastOpcode for the no-op casts InsertNoopCastOfTo is asked for
recursive fn sx_noop_cast_opcode(v: i32, ty: i32) -> i64 {
    let st = vals[v].ty;
    if ty_kind(st) == TK_PTR && ty_kind(ty) != TK_PTR { return OP_PTRTOINT; }
    if ty_kind(st) != TK_PTR && ty_kind(ty) == TK_PTR { return OP_INTTOPTR; }
    if ty_kind(st) == TK_PTR && ty_kind(ty) == TK_PTR && types[st].n != types[ty].n { return OP_ADDRSPACECAST; }
    return OP_BITCAST;
}

// InsertNoopCastOfTo(V, Ty)
recursive fn sx_insert_noop_cast_of_to(v: i32, ty: i32) -> i32 {
    let o = sx_noop_cast_opcode(v, ty);
    if o != OP_BITCAST && o != OP_PTRTOINT && o != OP_INTTOPTR { fatal("InsertNoopCastOfTo cannot perform non-noop casts!"); }
    if o == OP_INTTOPTR && dl_is_nonintegral_as(types[ty].n as i64) {
        return sxb_ptr_add(c_null(ty), v, "scevgep", 0);
    }
    if o == OP_BITCAST {
        if vals[v].ty == ty { return v; }
        if sx_is_cast_op(v) && vals[op(v, 0)].ty == ty { return op(v, 0); }
    }
    if (o == OP_PTRTOINT || o == OP_INTTOPTR) && sc_type_bits(ty) == sc_type_bits(vals[v].ty) {
        if sx_is_cast_op(v) && (iop(v) == OP_PTRTOINT || iop(v) == OP_INTTOPTR) &&
           sc_type_bits(vals[v].ty) == sc_type_bits(vals[op(v, 0)].ty) { return op(v, 0); }
        if vals[v].kind == VK_CEXPR && (csts[vals[v].sub].op as i64 == OP_PTRTOINT || csts[vals[v].sub].op as i64 == OP_INTTOPTR) &&
           sc_type_bits(vals[v].ty) == sc_type_bits(vals[op(v, 0)].ty) { return op(v, 0); }
    }
    if is_constant(v) { return ce_cast(o, v, ty); }
    return sx_reuse_or_create_cast(v, ty, o, sx_optimal_cast_point(v));
}

// ---------------------------------------------------------------------------------------------
// Binary operators and GEPs

recursive fn sx_incompatible_poison(i: i32, flags: u32) -> bool {
    let o = iop(i);
    if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL {
        if op_nsw(i) != ((flags & SF_NSW) != 0) { return true; }
        if op_nuw(i) != ((flags & SF_NUW) != 0) { return true; }
    }
    if (o == OP_SDIV || o == OP_UDIV || o == OP_ASHR || o == OP_LSHR) && has_flag(i, FL_EXACT) { return true; }
    return false;
}

// InsertBinop(Opcode, LHS, RHS, Flags, IsSafeToHoist)
recursive fn sx_insert_binop(o: i64, lhs: i32, rhs: i32, flags: u32, safe_to_hoist: bool) -> i32 {
    if is_constant(lhs) && is_constant(rhs) {
        let r = cf_fold_binop_operands(o, lhs, rhs);
        if r >= 0 { return r; }
    }
    // a quick scan for this binop nearby
    var scan: i64 = 6;
    let begin = block_first(sxb_bb);
    var ip = sxb_pos;
    if ip != begin {
        ip = if ip < 0 { block_last(sxb_bb) } else { inst_prev(ip) };
        while scan > 0 {
            if iop(ip) == o && nops(ip) >= 2 && op(ip, 0) == lhs && op(ip, 1) == rhs && !sx_incompatible_poison(ip, flags) { return ip; }
            if ip == begin { break; }
            ip = inst_prev(ip);
            scan--;
        }
    }
    let loc = if sxb_pos >= 0 { inst_get_md(sxb_pos, 0) } else { -1 };
    sx_guard_push();
    if safe_to_hoist {
        loop {
            let l = li_loop_for(sxb_bb);
            if l < 0 { break; }
            if !sx_loop_invariant_v(l, lhs) || !sx_loop_invariant_v(l, rhs) { break; }
            let ph = loop_preheader(l);
            if ph < 0 { break; }
            sxb_set_before(block_terminator(ph));
        }
    }
    sxb_dl = loc;
    let nuw = (flags & SF_NUW) != 0;
    let nsw = (flags & SF_NSW) != 0;
    var r: i32 = -1;
    var all_out = sx_lsr && sx_post_inc.len > 0;
    if all_out { for pl in sx_post_inc { if loop_contains(pl, sxb_bb) { all_out = false; } } }
    if all_out {
        let bo = create_inst(o, vals[lhs].ty, [lhs, rhs]);
        var fl: u8 = 0;
        if nuw { fl |= FL_NUW; }
        if nsw { fl |= FL_NSW; }
        insts[inst_of(bo)].flags = fl;
        r = sxb_insert(bo, "");
    } else {
        r = sxb_binop(o, lhs, rhs, nuw, nsw, "");
    }
    sx_guard_pop();
    return r;
}

// expandAddToGEP(Offset, V, Flags)
recursive fn sx_expand_add_to_gep(offset: i32, v: i32, flags: u32) -> i32 {
    let idx = sx_expand(offset);
    let nw: u8 = if (flags & SF_NUW) != 0 { GEP_NUW } else { 0 };
    if is_constant(v) && is_constant(idx) { return sxb_ptr_add(v, idx, "", nw); }
    var scan: i64 = 6;
    let begin = block_first(sxb_bb);
    var ip = sxb_pos;
    if ip != begin {
        ip = if ip < 0 { block_last(sxb_bb) } else { inst_prev(ip) };
        while scan > 0 {
            if iop(ip) == OP_GEP && op(ip, 0) == v && insts[inst_of(ip)].ty2 == T_I8 && nops(ip) >= 2 && op(ip, 1) == idx {
                sx_remember_flags(ip);
                insts[inst_of(ip)].flags = insts[inst_of(ip)].flags & nw;
                return ip;
            }
            if ip == begin { break; }
            ip = inst_prev(ip);
            scan--;
        }
    }
    sx_guard_push();
    loop {
        let l = li_loop_for(sxb_bb);
        if l < 0 { break; }
        if !sx_loop_invariant_v(l, v) || !sx_loop_invariant_v(l, idx) { break; }
        let ph = loop_preheader(l);
        if ph < 0 { break; }
        sxb_set_before(block_terminator(ph));
    }
    let r = sxb_ptr_add(v, idx, "scevgep", nw);
    sx_guard_pop();
    return r;
}

// ---------------------------------------------------------------------------------------------
// Relevant loops

// PickMostRelevantLoop(A, B, DT)
recursive fn sx_pick_most_relevant_loop(a: i32, b: i32) -> i32 {
    if a < 0 { return b; }
    if b < 0 { return a; }
    if loop_contains_loop(a, b) { return b; }
    if loop_contains_loop(b, a) { return a; }
    if dt_dominates_block(DT_DOM, loop_header(a), loop_header(b)) { return b; }
    if dt_dominates_block(DT_DOM, loop_header(b), loop_header(a)) { return a; }
    return a;
}

// getRelevantLoop(S)
recursive fn sx_relevant_loop(s: i32) -> i32 {
    let f = hm_get(sx_rel, s as u64, -1);
    if f >= 0 { return (f - 1) as i32; }
    hm_put(sx_rel, s as u64, 0);          // try_emplace(S): null while computing
    let k = sc_kind(s);
    if k == SC_CONST || k == SC_VSCALE { return -1; }
    if k == SC_UNKNOWN {
        let v = sc_value(s);
        if is_inst(v) {
            let l = li_loop_for(inst_parent(v));
            hm_put(sx_rel, s as u64, (l + 1) as i64);
            return l;
        }
        return -1;
    }
    if k == SC_CNC { fatal("Attempt to use a SCEVCouldNotCompute object!"); }
    var l: i32 = if k == SC_ADDREC { sc_loop(s) } else { -1 };
    for i in sc_nops(s) { l = sx_pick_most_relevant_loop(l, sx_relevant_loop(sc_op(s, i))); }
    hm_put(sx_rel, s as u64, (l + 1) as i64);
    return l;
}

// LoopCompare
fn sx_loop_compare(a: SxOL, b: SxOL) -> bool {
    let ap = sc_is_ptr(a.s);
    let bp = sc_is_ptr(b.s);
    if ap != bp { return ap; }
    if a.l != b.l { return sx_pick_most_relevant_loop(a.l, b.l) != a.l; }
    if sx_non_constant_negative(a.s) {
        if !sx_non_constant_negative(b.s) { return false; }
    } else if sx_non_constant_negative(b.s) { return true; }
    return false;
}
// llvm::stable_sort(OpsAndLoops, LoopCompare(SE.DT)) on sx_ol[b..]
fn sx_sort_ol(b: i64) {
    std_stable_sort(sx_ol, b, sx_ol.len - b) { x, y => sx_loop_compare(x, y) };
}
// OpsAndLoops for reverse(S->operands()), sorted
recursive fn sx_push_ops_and_loops(s: i32) -> i64 {
    let b = sx_ol.len;
    var k = sc_nops(s) - 1;
    while k >= 0 {
        let o = sc_op(s, k);
        let l = sx_relevant_loop(o);
        sx_ol.push(SxOL { l: l, s: o });
        k--;
    }
    sx_sort_ol(b);
    return b;
}

// ---------------------------------------------------------------------------------------------
// visit*

recursive fn sx_visit(s: i32) -> i32 {
    let k = sc_kind(s);
    if k == SC_CONST { return sc_cval(s); }
    if k == SC_VSCALE { return sxb_intrinsic(IID_vscale, sc_ty(s), -1, -1, 0, ""); }
    if k == SC_TRUNC { let v = sx_expand(sc_op(s, 0)); return sxb_trunc(v, sc_ty(s), "", false, false); }
    if k == SC_ZEXT {
        let v = sx_expand(sc_op(s, 0));
        return sxb_zext(v, sc_ty(s), "", sc_is_known_non_negative(sc_op(s, 0)));
    }
    if k == SC_SEXT { let v = sx_expand(sc_op(s, 0)); return sxb_cast(OP_SEXT, v, sc_ty(s), ""); }
    if k == SC_ADD { return sx_visit_add(s); }
    if k == SC_MUL { return sx_visit_mul(s); }
    if k == SC_UDIV { return sx_visit_udiv(s); }
    if k == SC_ADDREC { return sx_visit_addrec(s); }
    if k == SC_SMAX { return sx_expand_minmax(s, IID_smax, "smax", false); }
    if k == SC_UMAX { return sx_expand_minmax(s, IID_umax, "umax", false); }
    if k == SC_SMIN { return sx_expand_minmax(s, IID_smin, "smin", false); }
    if k == SC_UMIN { return sx_expand_minmax(s, IID_umin, "umin", false); }
    if k == SC_SEQUMIN { return sx_expand_minmax(s, IID_umin, "umin", true); }
    if k == SC_PTRTOADDR { return sx_visit_ptr_to_addr(s); }
    if k == SC_PTRTOINT {
        let v = sx_expand(sc_op(s, 0));
        return sx_reuse_or_create_cast(v, sc_ty(s), OP_PTRTOINT, sx_optimal_cast_point(v));
    }
    if k == SC_UNKNOWN { return sc_value(s); }
    fatal("Attempt to use a SCEVCouldNotCompute object!");
    return -1;
}

// visitAddExpr
recursive fn sx_visit_add(s: i32) -> i32 {
    let ul, ur, is_urem = sc_match_urem(s);
    if is_urem {
        let a = sx_expand(ul);
        let b = sx_expand(ur);
        return sx_insert_binop(OP_UREM, a, b, SF_ANY, false);
    }
    let b = sx_push_ops_and_loops(s);
    let e = sx_ol.len;
    var sum: i32 = -1;
    var i = b;
    while i < e {
        let cur_l = sx_ol[i].l;
        let o = sx_ol[i].s;
        if sum < 0 { sum = sx_expand(o); i++; continue; }
        if ty_kind(vals[sum].ty) == TK_PTR {
            // a getelementptr at this level with the running sum as the base
            let sb = ss.len;
            while i < e && sx_ol[i].l == cur_l {
                var x = sx_ol[i].s;
                if sc_is_unknown(x) && !is_inst(sc_value(x)) { x = sc_get_scev(sc_value(x)); }
                ss.push(x);
                i++;
            }
            let add = sc_add_n(sb, SF_ANY, 0);
            sum = sx_expand_add_to_gep(add, sum, sc_flags(s));
        } else if sx_non_constant_negative(o) {
            let w = sx_expand(sc_get_negative(o, SF_ANY));
            sum = sx_insert_binop(OP_SUB, sum, w, SF_ANY, true);
            i++;
        } else {
            var w = sx_expand(o);
            if is_constant(sum) { let t = sum; sum = w; w = t; }
            sum = sx_insert_binop(OP_ADD, sum, w, sc_flags(s), true);
            i++;
        }
    }
    sx_ol.resize(b);
    return sum;
}

// visitMulExpr's ExpandOpBinPowN: (result, next index)
recursive fn sx_expand_op_bin_pow_n(i0: i64, e: i64) -> i32, i64 {
    var j = i0;
    var exponent: u64 = 0;
    let max_exp: u64 = 0x7FFFFFFFFFFFFFFF;
    while j != e && sx_ol[j].l == sx_ol[i0].l && sx_ol[j].s == sx_ol[i0].s && exponent != max_exp { exponent++; j++; }
    var p = sx_expand(sx_ol[i0].s);
    var result: i32 = -1;
    if (exponent & 1) != 0 { result = p; }
    var bin: u64 = 2;
    while bin <= exponent {
        p = sx_insert_binop(OP_MUL, p, p, SF_ANY, true);
        if (exponent & bin) != 0 {
            result = if result >= 0 { sx_insert_binop(OP_MUL, result, p, SF_ANY, true) } else { p };
        }
        bin = bin << 1;
    }
    return result, j;
}

// visitMulExpr
recursive fn sx_visit_mul(s: i32) -> i32 {
    let ty = sc_ty(s);
    let b = sx_push_ops_and_loops(s);
    let e = sx_ol.len;
    var prod: i32 = -1;
    var i = b;
    while i != e {
        if prod < 0 {
            let r, ni = sx_expand_op_bin_pow_n(i, e);
            prod = r;
            i = ni;
        } else if sc_is_all_ones(sx_ol[i].s) {
            prod = sx_insert_binop(OP_SUB, c_null(ty), prod, SF_ANY, true);
            i++;
        } else {
            let r, ni = sx_expand_op_bin_pow_n(i, e);
            var w = r;
            i = ni;
            if is_constant(prod) { let t = prod; prod = w; w = t; }
            if is_cint(w) && ap_is_pow2(ci_ap(w)) {
                let rhs = ci_ap(w);
                var nwf = sc_flags(s);
                let lg = ap_log2(rhs);
                if lg == (rhs.w as i64) - 1 { nwf = nwf & ~SF_NSW; }
                prod = sx_insert_binop(OP_SHL, prod, c_int_ty(ty, lg as u64), nwf, true);
            } else {
                prod = sx_insert_binop(OP_MUL, prod, w, sc_flags(s), true);
            }
        }
    }
    sx_ol.resize(b);
    return prod;
}

// visitUDivExpr
recursive fn sx_visit_udiv(s: i32) -> i32 {
    let lhs = sx_expand(sc_op(s, 0));
    let rs = sc_op(s, 1);
    if sc_is_const(rs) && ap_is_pow2(sc_ap(rs)) {
        return sx_insert_binop(OP_LSHR, lhs, c_int_ty(sc_ty(rs), ap_log2(sc_ap(rs)) as u64), SF_ANY, true);
    }
    var rhs = sx_expand(rs);
    if sx_safe_udiv {
        let gnp = sc_is_guaranteed_not_to_be_poison(rs);
        if !gnp { rhs = sxb_freeze(rhs, ""); }
        if !sc_is_known_non_zero(rs) || !gnp {
            rhs = sxb_intrinsic(IID_umax, vals[rhs].ty, rhs, c_int_ty(vals[rhs].ty, 1), 2, "");
        }
    }
    return sx_insert_binop(OP_UDIV, lhs, rhs, SF_ANY, sc_is_known_non_zero(rs));
}

// isNormalAddRecExprPHI(PN, IncV, L)
recursive fn sx_is_normal_addrec_phi(pn: i32, inc0: i32, l: i32) -> bool {
    var inc = inc0;
    loop {
        if nops(inc) == 0 || iop(inc) == OP_PHI || (sx_is_cast_op(inc) && iop(inc) != OP_BITCAST) { return false; }
        if l == sx_ivinc_loop {
            for k in 1..nops(inc) {
                let o = op(inc, k);
                if is_inst(o) && !dt_value_dominates_inst(o, sx_ivinc_pos) { return false; }
            }
        }
        let nx = op(inc, 0);
        if !is_inst(nx) { return false; }
        if inst_may_have_side_effects(nx) { return false; }
        if nx == pn { return true; }
        inc = nx;
    }
    return false;
}

// getIVIncOperand(IncV, InsertPos, allowScale)
fn sx_iv_inc_operand(inc: i32, pos: i32, allow_scale: bool) -> i32 {
    if inc == pos { return -1; }
    let o = iop(inc);
    if o == OP_ADD || o == OP_SUB {
        let oi = op(inc, 1);
        if !is_inst(oi) || dt_value_dominates_inst(oi, pos) { return if is_inst(op(inc, 0)) { op(inc, 0) } else { -1 }; }
        return -1;
    }
    if o == OP_BITCAST { return if is_inst(op(inc, 0)) { op(inc, 0) } else { -1 }; }
    if o == OP_GEP {
        for k in 1..nops(inc) {
            let u = op(inc, k);
            if is_constant(u) { continue; }
            if is_inst(u) && !dt_value_dominates_inst(u, pos) { return -1; }
            if allow_scale { continue; }
            if insts[inst_of(inc)].ty2 != T_I8 { return -1; }
            break;
        }
        return if is_inst(op(inc, 0)) { op(inc, 0) } else { -1 };
    }
    return -1;
}

// fixupInsertPoints(I)
fn sx_fixup_insert_points(i: i32) {
    let nx = inst_next(i);
    if sxb_pos == i { sxb_set_before(nx); }
    for k in sx_guards.len {
        if sx_guards[k].pos == i { sx_guards[k].pos = nx; sx_guards[k].head = false; }
    }
}

// hoistIVInc's FixupPoisonFlags
fn sx_fixup_poison_flags(i: i32) {
    sx_remember_flags(i);
    drop_poison_generating_flags(i);
    let o = iop(i);
    if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL {
        let ok, f = sc_get_strengthened_no_wrap_flags_from_binop(i);
        if ok { sx_set_nuw(i, (f & SF_NUW) != 0); sx_set_nsw(i, (f & SF_NSW) != 0); }
    }
}
fn sx_set_nuw(i: i32, b: bool) { let ii = inst_of(i); if b { insts[ii].flags |= FL_NUW; } else { insts[ii].flags &= ~FL_NUW; } }
fn sx_set_nsw(i: i32, b: bool) { let ii = inst_of(i); if b { insts[ii].flags |= FL_NSW; } else { insts[ii].flags &= ~FL_NSW; } }

// hoistIVInc(IncV, InsertPos, RecomputePoisonFlags)
fn sx_hoist_iv_inc(inc0: i32, pos: i32, recompute: bool) -> bool {
    var inc = inc0;
    if dt_value_dominates_inst(inc, pos) {
        if recompute { sx_fixup_poison_flags(inc); }
        return true;
    }
    if iop(pos) == OP_PHI || !dt_dominates_block(DT_DOM, inst_parent(pos), inst_parent(inc)) { return false; }
    if !li_movement_preserves_lcssa(inc, pos) { return false; }
    var incs: i32[>..<] = [];
    loop {
        let oper = sx_iv_inc_operand(inc, pos, true);
        if oper < 0 { return false; }
        incs.push(inc);
        inc = oper;
        if dt_value_dominates_inst(inc, pos) { break; }
    }
    var k = incs.len - 1;
    while k >= 0 {
        let i = incs[k];
        sx_fixup_insert_points(i);
        inst_move_before(i, pos);
        if recompute { sx_fixup_poison_flags(i); }
        k--;
    }
    return true;
}

// m_c_BinOp(m_Specific(P), m_Value())
fn sx_is_binop_of(i: i32, p: i32) -> bool { is_inst(i) && is_binary_op(iop(i)) && (op(i, 0) == p || op(i, 1) == p) }
// canReuseFlagsFromOriginalIVInc
fn sx_can_reuse_flags_from_original_iv_inc(orig_phi: i32, wide_phi: i32, orig_inc: i32, wide_inc: i32) -> bool {
    return sx_is_binop_of(orig_inc, orig_phi) && sx_is_binop_of(wide_inc, wide_phi) && iop(orig_inc) == iop(wide_inc);
}

// isExpandedAddRecExprPHI(PN, IncV, L)
fn sx_is_expanded_addrec_phi(pn: i32, inc: i32, l: i32) -> bool {
    let pt = block_terminator(loop_preheader(l));
    var o = inc;
    loop {
        o = sx_iv_inc_operand(o, pt, false);
        if o < 0 { return false; }
        if o == pn { return true; }
    }
    return false;
}

// expandIVInc(PN, StepV, L, useSubtract)
recursive fn sx_expand_iv_inc(pn: i32, stepv: i32, use_subtract: bool) -> i32 {
    if ty_kind(vals[pn].ty) == TK_PTR { return sxb_ptr_add(pn, stepv, "scevgep", 0); }
    let nm = sx_name2(sx_ivname, ".iv.next");
    if use_subtract { return sxb_binop(OP_SUB, pn, stepv, false, false, nm); }
    return sxb_binop(OP_ADD, pn, stepv, false, false, nm);
}

// canBeCheaplyTransformed(SE, Phi, Requested, InvertStep): (ok, invert)
recursive fn sx_can_be_cheaply_transformed(phi0: i32, req: i32) -> bool, bool {
    let pt = sc_ty(phi0);
    let rt = sc_ty(req);
    if ty_kind(pt) == TK_PTR || ty_kind(rt) == TK_PTR { return false, false; }
    if ty_bits(rt) > ty_bits(pt) { return false, false; }
    let phi = sc_get_truncate_or_noop(phi0, rt);
    if !sc_is_addrec(phi) { return false, false; }
    if phi == req { return true, false; }
    if sc_minus(sc_op(req, 0), req) == phi { return true, true; }
    return false, false;
}

// IsIncrementNSW / IsIncrementNUW
recursive fn sx_is_increment_nw(ar: i32, signed: bool) -> bool {
    if !ty_is_int(sc_ty(ar)) { return false; }
    let bw = ty_bits(sc_ty(ar));
    let wide = ty_int(bw * 2);
    let step = sc_get_step_recurrence(ar);
    if signed {
        let a = sc_add(sc_get_sign_extend(step, wide, 0), sc_get_sign_extend(ar, wide, 0));
        let b = sc_get_sign_extend(sc_add(ar, step), wide, 0);
        return a == b;
    }
    let a = sc_add(sc_get_zero_extend(step, wide, 0), sc_get_zero_extend(ar, wide, 0));
    let b = sc_get_zero_extend(sc_add(ar, step), wide, 0);
    return a == b;
}

// getAddRecExprPHILiterally(Normalized, L, TruncTy, InvertStep): (PN, TruncTy or -1, InvertStep)
recursive fn sx_addrec_phi_literally(norm: i32, l: i32) -> i32, i32, bool {
    let latch = loop_latch(l);
    if latch >= 0 {
        var match_pn: i32 = -1;
        var inc: i32 = -1;
        var trunc_ty: i32 = -1;
        var invert = false;
        let try_non_matching = sx_ivinc_loop >= 0 && dt_properly_dominates_block(DT_DOM, latch, loop_header(sx_ivinc_loop));
        var pn = block_first(loop_header(l));
        while pn >= 0 && iop(pn) == OP_PHI {
            let cur = pn;
            pn = inst_next(pn);
            if !sc_is_scevable(vals[cur].ty) { continue; }
            if !sx_phi_complete(cur) { continue; }
            let ps = sc_get_scev(cur);
            if !sc_is_addrec(ps) { continue; }
            let matching = ps == norm;
            if !matching && !try_non_matching { continue; }
            let tinc = sx_phi_in(cur, latch);
            if !is_inst(tinc) { continue; }
            if sx_lsr {
                if !sx_is_expanded_addrec_phi(cur, tinc, l) { continue; }
            } else {
                if !sx_is_normal_addrec_phi(cur, tinc, l) { continue; }
            }
            if matching {
                inc = tinc;
                trunc_ty = -1;
                invert = false;
                match_pn = cur;
                break;
            }
            if trunc_ty < 0 || invert {
                let ok, inv = sx_can_be_cheaply_transformed(ps, norm);
                if ok {
                    invert = inv;
                    match_pn = cur;
                    inc = tinc;
                    trunc_ty = sc_ty(norm);
                }
            }
        }
        if match_pn >= 0 {
            sx_set_add(sx_ivals, sx_ivals_order, match_pn);
            sx_remember_instruction(inc);
            hm_put(sx_reused, match_pn as u64, 1);
            hm_put(sx_reused, inc as u64, 1);
            return match_pn, trunc_ty, invert;
        }
    }
    sx_guard_push();
    // SavedPostIncLoops = PostIncLoops; PostIncLoops.clear()
    let pim = sx_tmp.len;
    for x in sx_post_inc { sx_tmp.push(x); }
    sx_post_inc.clear();
    let ph = loop_preheader(l);
    if ph < 0 { fatal("Can't expand add recurrences without a loop preheader!"); }
    sxb_set_before(block_terminator(ph));
    let startv = sx_expand(sc_op(norm, 0));
    var step = sc_get_step_recurrence(norm);
    let ety = sc_ty(norm);
    let use_subtract = ty_kind(ety) != TK_PTR && sx_non_constant_negative(step);
    if use_subtract { step = sc_get_negative(step, SF_ANY); }
    sxb_set_it(sx_first_insertion_pt(loop_header(l)));
    let stepv = sx_expand(step);
    let inc_nuw = !use_subtract && sx_is_increment_nw(norm, false);
    let inc_nsw = !use_subtract && sx_is_increment_nw(norm, true);
    let header = loop_header(l);
    sxb_set_it(SxIt { bb: header, pos: block_first(header), head: true });
    let npred = pred_count(header);
    let pn = sxb_phi(ety, npred, sx_name2(sx_ivname, ".iv"));
    // the step instructions, one per predecessor (predecessors(Header) in use-list order)
    let pm = sx_tmp.len;
    each_pred(header) { p => sx_tmp.push(p); };
    let pe = sx_tmp.len;
    var k = pm;
    while k < pe {
        let pred = sx_tmp[k];
        k++;
        if !loop_contains(l, pred) { phi_add_incoming(pn, startv, pred); continue; }
        let ipos = if l == sx_ivinc_loop { sx_ivinc_pos } else { block_terminator(pred) };
        sxb_set_before(ipos);
        let incv = sx_expand_iv_inc(pn, stepv, use_subtract);
        let io = if is_inst(incv) { iop(incv) } else { -1 };
        if io == OP_ADD || io == OP_SUB || io == OP_MUL || io == OP_SHL {
            if inc_nuw { insts[inst_of(incv)].flags |= FL_NUW; }
            if inc_nsw { insts[inst_of(incv)].flags |= FL_NSW; }
        }
        phi_add_incoming(pn, incv, pred);
    }
    sx_tmp.resize(pm);
    // PostIncLoops = SavedPostIncLoops
    for j in pim..sx_tmp.len { sx_post_inc.push(sx_tmp[j]); }
    sx_tmp.resize(pim);
    sx_set_add(sx_ivals, sx_ivals_order, pn);
    sx_inserted_ivs.push(wvh_new(pn, WVH_WEAK));
    sx_guard_pop();
    return pn, -1, false;
}

// expandAddRecExprLiterally(S)
recursive fn sx_expand_addrec_literally(s: i32) -> i32 {
    let l = sc_loop(s);
    if sx_post_inc_has(l) { fatal("SCEVExpander: post-increment expansion (normalizeForPostIncUse) is not ported yet"); }
    let norm = s;
    var step = sc_get_step_recurrence(norm);
    let pn, trunc_ty, invert = sx_addrec_phi_literally(norm, l);
    var result = pn;
    if trunc_ty >= 0 {
        if trunc_ty != vals[result].ty || invert { result = sx_fixup_lcssa_form_for(result); }
        if trunc_ty != vals[result].ty { result = sxb_trunc(result, trunc_ty, "", false, false); }
        if invert {
            let st = sx_expand(sc_op(norm, 0));
            result = sxb_binop(OP_SUB, st, result, false, false, "");
        }
    }
    return result;
}

// tryToReuseLCSSAPhi(S)
recursive fn sx_try_to_reuse_lcssa_phi(s: i32) -> i32 {
    let sty = sc_ty(s);
    let l = sc_loop(s);
    let eb = ln_exit_block(l, false);
    if eb < 0 || single_pred(eb) < 0 || !dt_dominates_block(DT_DOM, eb, sxb_bb) { return -1; }
    var pn = block_first(eb);
    while pn >= 0 && iop(pn) == OP_PHI {
        let cur = pn;
        pn = inst_next(pn);
        if !sc_is_scevable(vals[cur].ty) { continue; }
        let es = sc_get_scev(cur);
        if !sc_is_addrec(es) { continue; }
        let phity = vals[cur].ty;
        var diff: i32 = -1;
        if ty_is_int(sty) && ty_kind(phity) == TK_PTR && ty_int(dl_ptr(types[phity].n as i64).idx) == sty {
            diff = sx_lcssa_can_reuse(s, sc_get_ptr_to_addr(es));
            if diff < 0 { diff = sx_lcssa_can_reuse(s, sc_get_ptr_to_int(es, sty)); }
        } else if sty == phity {
            diff = sx_lcssa_can_reuse(s, es);
        }
        if diff < 0 { continue; }
        let diffv = sx_expand(diff);
        var basev = sx_fixup_lcssa_form_for(cur);
        if ty_kind(phity) == TK_PTR {
            if ty_kind(sty) == TK_PTR { return sxb_ptr_add(basev, diffv, "", 0); }
            basev = sxb_cast(OP_PTRTOADDR, basev, ty_int(dl_ptr(types[phity].n as i64).idx), "");
        }
        return sxb_binop(OP_ADD, basev, diffv, false, false, "");
    }
    return -1;
}
// tryToReuseLCSSAPhi's CanReuse(ExitSCEV): the difference, or -1
recursive fn sx_lcssa_can_reuse(s: i32, exit: i32) -> i32 {
    if sc_is_cnc(exit) { return -1; }
    let diff = sc_minus(s, exit);
    var o = diff;
    if sc_kind(o) == SC_ADD && sc_nops(o) == 2 && sc_is_const(sc_op(o, 0)) { o = sc_op(o, 1); }
    if sc_kind(o) == SC_MUL && sc_nops(o) == 2 && sc_is_all_ones(sc_op(o, 0)) { o = sc_op(o, 1); }
    if sc_kind(o) == SC_PTRTOADDR || sc_kind(o) == SC_PTRTOINT { o = sc_op(o, 0); }
    if !sc_is_const(o) && !sc_is_unknown(o) { return -1; }
    return diff;
}

// visitAddRecExpr
recursive fn sx_visit_addrec(s: i32) -> i32 {
    if !sx_canonical || sc_nops(s) > 2 { return sx_expand_addrec_literally(s); }
    let ty = sc_effective_ty(sc_ty(s));
    let l = sc_loop(s);
    var civ: i32 = -1;
    let pn0 = loop_canonical_induction_variable(l);
    if pn0 >= 0 && sc_type_bits(vals[pn0].ty) >= sc_type_bits(ty) { civ = pn0; }
    if civ >= 0 && sc_type_bits(vals[civ].ty) > sc_type_bits(ty) && !sc_is_ptr(s) {
        let b = ss.len;
        for i in sc_nops(s) { let x = sc_get_any_extend(sc_op(s, i), vals[civ].ty); ss.push(x); }
        let ar = sc_addrec_n(b, l, sc_flags(s) & SF_NW);
        let v = sx_expand(ar);
        let nip = if is_inst(v) { sx_find_insert_point_after(v, sxb_pos) } else { sxb_it() };
        sxb_set_it(nip);
        return sx_expand(sc_get_truncate(sc_get_unknown(v), ty, 0));
    }
    let lv = sx_try_to_reuse_lcssa_phi(s);
    if lv >= 0 { return lv; }
    if !sc_is_zero(sc_op(s, 0)) {
        if sc_is_ptr(s) {
            let startv = sx_expand(sc_get_pointer_base(s));
            return sx_expand_add_to_gep(sc_remove_pointer_base(s), startv, sc_flags(s) & SF_NUW);
        }
        let b = ss.len;
        ss.push(sc_get_constant_ty(ty, 0, false));
        for i in 1..sc_nops(s) { ss.push(sc_op(s, i)); }
        let rest = sc_addrec_n(b, l, sc_flags(s) & SF_NW);
        let lhs = sc_get_unknown(sx_expand(sc_op(s, 0)));
        let rhs = sc_get_unknown(sx_expand(rest));
        return sx_expand(sc_add(lhs, rhs));
    }
    if civ < 0 {
        let header = loop_header(l);
        let npred = pred_count(header);
        civ = new_inst(OP_PHI, ty, npred);
        vals[civ].nops = 0;
        inst_insert_at(civ, header, block_first(header), true);
        set_name(civ, "indvar");
        sx_remember_instruction(civ);
        let one = c_int_ty(ty, 1);
        let pm = sx_tmp.len;
        each_pred(header) { p => sx_tmp.push(p); };
        let pe = sx_tmp.len;
        var k = pm;
        while k < pe {
            let hp = sx_tmp[k];
            var seen = false;
            for j in pm..k { if sx_tmp[j] == hp { seen = true; } }
            k++;
            if seen { phi_add_incoming(civ, sx_phi_in(civ, hp), hp); continue; }
            if loop_contains(l, hp) {
                let t = block_terminator(hp);
                let add = create_inst(OP_ADD, ty, [civ, one]);
                inst_insert_before(add, t);
                set_name(add, "indvar.next");
                let dl = inst_get_md(t, 0);
                if dl >= 0 { inst_set_md(add, 0, dl); }
                sx_remember_instruction(add);
                phi_add_incoming(civ, add, hp);
            } else {
                phi_add_incoming(civ, c_null(ty), hp);
            }
        }
        sx_tmp.resize(pm);
    }
    if sc_is_affine(s) && sc_is_one(sc_op(s, 1)) { return civ; }
    if sc_is_affine(s) {
        let m = sc_mul(sc_get_unknown(civ), sc_get_noop_or_any_extend(sc_op(s, 1), vals[civ].ty));
        return sx_expand(sc_get_truncate_or_noop(m, ty));
    }
    let ih = sc_get_unknown(civ);
    var news = s;
    let ext = sc_get_noop_or_any_extend(s, vals[civ].ty);
    if sc_is_addrec(ext) { news = ext; }
    let v = sc_evaluate_at_iteration(news, ih);
    let t = sc_get_truncate_or_noop(v, ty);
    return sx_expand(t);
}

// visitPtrToAddrExpr
recursive fn sx_visit_ptr_to_addr(s: i32) -> i32 {
    let v = sx_expand(sc_op(s, 0));
    let ty = sc_ty(s);
    if !is_constant(v) {
        let bip = sxb_pos;
        var u = vals[v].first_use;
        while u >= 0 {
            let ci = uses[u].user;
            u = uses[u].next;
            if sx_is_cast_op(ci) && vals[ci].ty == ty && (iop(ci) == OP_PTRTOADDR || iop(ci) == OP_PTRTOINT) &&
               bip != ci && bip >= 0 && dt_value_dominates_inst(ci, bip) { return ci; }
        }
    }
    return sx_reuse_or_create_cast(v, ty, OP_PTRTOADDR, sx_optimal_cast_point(v));
}

// expandMinMaxExpr(S, IntrinID, Name, IsSequential)
recursive fn sx_expand_minmax(s: i32, id: i64, name: const u8[:], seq: bool) -> i32 {
    let prev = sx_safe_udiv;
    sx_safe_udiv = sx_safe_udiv || seq;
    let n = sc_nops(s);
    var lhs = sx_expand(sc_op(s, n - 1));
    let ty = vals[lhs].ty;
    if seq { lhs = sxb_freeze(lhs, ""); }
    var i = n - 2;
    while i >= 0 {
        sx_safe_udiv = (seq && i != 0) || prev;
        var rhs = sx_expand(sc_op(s, i));
        if seq && i != 0 { rhs = sxb_freeze(rhs, ""); }
        var sel: i32 = -1;
        if ty_is_int(ty) {
            sel = sxb_intrinsic(id, ty, lhs, rhs, 2, name);
        } else {
            var p = P_UGT;
            if id == IID_smax { p = P_SGT; } else if id == IID_smin { p = P_SLT; } else if id == IID_umin { p = P_ULT; }
            let c = sxb_icmp(p, lhs, rhs, "");
            sel = sxb_select(c, lhs, rhs, name);
        }
        lhs = sel;
        i--;
    }
    sx_safe_udiv = prev;
    return lhs;
}

// ---------------------------------------------------------------------------------------------
// expand

// expand's SafeToHoist: no udiv by a non-constant or by zero
recursive fn sx_safe_to_hoist(s: i32) -> bool {
    let mark = sx_seen.len;
    let r = !sx_has_unsafe_udiv(s, mark);
    sx_seen.resize(mark);
    return r;
}
recursive fn sx_has_unsafe_udiv(s: i32, mark: i64) -> bool {
    for k in mark..sx_seen.len { if sx_seen[k] == s { return false; } }
    sx_seen.push(s);
    let k = sc_kind(s);
    if k == SC_UDIV {
        let r = sc_op(s, 1);
        if sc_is_const(r) { if sc_is_zero(r) { return true; } }
        else { return true; }
    }
    if k == SC_CONST || k == SC_VSCALE || k == SC_UNKNOWN || k == SC_CNC { return false; }
    for i in sc_nops(s) { if sx_has_unsafe_udiv(sc_op(s, i), mark) { return true; } }
    return false;
}

// FindValueInExprValueMap(S, InsertPt, DropPoisonGeneratingInsts): the value, or -1; the instructions whose
// flags must be dropped are left on sx_tmp from `dmark`
recursive fn sx_find_value_in_expr_value_map(s: i32, ip: i32, dmark: i64) -> i32 {
    if !sx_canonical && sc_contains_addrec(s) { return -1; }
    if sc_is_const(s) || sc_is_unknown(s) { return -1; }
    let r = sx_find_value_body(s, ip);
    if r >= 0 { for d in sx_drop { sx_tmp.push(d); } }
    return r;
}
var sx_drop: i32[>..<];
fn sx_find_value_body(s: i32, ip: i32) -> i32 {
    var vs: i32[>..<] = [];
    sc_get_scev_values(s, vs);
    var drop: i32[>..<] = [];
    for v in vs {
        if !is_inst(v) { continue; }
        if sc_ty(s) != vals[v].ty || !dt_value_dominates_inst(v, ip) { continue; }
        let vl = li_loop_for(inst_parent(v));
        if !(vl < 0 || loop_contains(vl, inst_parent(ip))) { continue; }
        drop.clear();
        if sc_can_reuse_instruction(s, v, drop) {
            sx_drop.clear();
            for d in drop { sx_drop.push(d); }
            return v;
        }
    }
    return -1;
}

// dropPoisonGeneratingAnnotationsAndReinfer(SE, I)
fn sx_drop_poison_annotations_and_reinfer(i: i32) {
    drop_poison_generating_annotations(i);
    let o = iop(i);
    if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL {
        let ok, f = sc_get_strengthened_no_wrap_flags_from_binop(i);
        if ok { sx_set_nuw(i, (f & SF_NUW) != 0); sx_set_nsw(i, (f & SF_NSW) != 0); }
    }
    if o == OP_ZEXT || o == OP_UITOFP {
        let src = op(i, 0);
        if implied_by_dom_condition(P_SGE, src, c_null(vals[src].ty), i) == 1 { insts[inst_of(i)].flags |= FL_NNEG; }
    }
}

recursive fn sx_expand(s: i32) -> i32 {
    var ip = sxb_it();
    if sx_safe_to_hoist(s) {
        var l = if sxb_bb >= 0 { li_loop_for(sxb_bb) } else { -1 };
        loop {
            if sc_is_loop_invariant(s, l) {
                if l < 0 { break; }
                let ph = loop_preheader(l);
                if ph >= 0 { ip = sx_term_it(ph); } else { ip = sx_first_insertion_pt(loop_header(l)); }
            } else {
                if l >= 0 && sc_has_computable_loop_evolution(s, l) && !sx_post_inc_has(l) { ip = sx_first_insertion_pt(loop_header(l)); }
                while !(ip.bb == sxb_bb && ip.pos == sxb_pos) && sx_is_inserted(ip.pos) { ip = sx_next(ip); }
                break;
            }
            l = loop_parent(l);
        }
    }
    let key = hk2(s, ip.pos);
    let h = hm_get(sx_iexpr, key, -1);
    if h >= 0 { return wvh_get(h as i32); }
    sx_guard_push();
    sxb_set_it(ip);
    let dmark = sx_tmp.len;
    var v = sx_find_value_in_expr_value_map(s, ip.pos, dmark);
    if v < 0 {
        v = sx_visit(s);
        v = sx_fixup_lcssa_form_for(v);
    } else {
        for k in dmark..sx_tmp.len {
            let d = sx_tmp[k];
            sx_remember_flags(d);
            sx_drop_poison_annotations_and_reinfer(d);
        }
    }
    sx_tmp.resize(dmark);
    // InsertedExpressions[(S, &*InsertPt)] = V (a TrackingVH)
    let oh = hm_get(sx_iexpr, key, -1);
    if oh >= 0 { wvh_set(oh as i32, v); } else { hm_put(sx_iexpr, key, wvh_new(v, WVH_TRACKING) as i64); }
    sx_guard_pop();
    return v;
}

// expandCodeFor(SH, Ty) at the current insertion point
recursive fn sx_expand_code_for(s: i32, ty: i32) -> i32 {
    var v = sx_expand(s);
    if ty >= 0 && ty != vals[v].ty {
        if sc_type_bits(ty) != sc_type_bits(sc_ty(s)) { fatal("non-trivial casts should be done with the SCEVs directly!"); }
        v = sx_insert_noop_cast_of_to(v, ty);
    }
    return v;
}
// expandCodeFor(SH, Ty, Instruction *I)
fn sx_expand_code_for_at(s: i32, ty: i32, i: i32) -> i32 { sxb_set_before(i); return sx_expand_code_for(s, ty); }
// expandCodeFor(SH, Ty, BasicBlock::iterator I)
fn sx_expand_code_for_it(s: i32, ty: i32, it: SxIt) -> i32 { sxb_set_it(it); return sx_expand_code_for(s, ty); }
// setInsertPoint / clearInsertPoint
fn sx_set_insert_point(i: i32) { sxb_set_before(i); }
fn sx_clear_insert_point() { sxb_clear(); }

// fixupLCSSAFormFor(V)
recursive fn sx_fixup_lcssa_form_for(v: i32) -> i32 {
    if !sx_preserve_lcssa || !is_inst(v) { return v; }
    let ip = sxb_it();
    let defl = li_loop_for(inst_parent(v));
    let usel = if ip.pos >= 0 { li_loop_for(inst_parent(ip.pos)) } else { li_loop_for(ip.bb) };
    if defl < 0 || usel == defl || (usel >= 0 && loop_contains_loop(defl, usel)) { return v; }
    return sx_fixup_lcssa_body(v, ip);
}
fn sx_fixup_lcssa_body(v: i32, ip: SxIt) -> i32 {
    let toty = if ty_is_int(vals[v].ty) { ty_ptr(0) } else { T_I32 };
    // CastInst::CreateBitOrPointerCast(DefI, ToTy, "tmp.lcssa.user", InsertPt)
    let co = if ty_is_int(vals[v].ty) { OP_INTTOPTR } else if ty_kind(vals[v].ty) == TK_PTR { OP_PTRTOINT } else { OP_BITCAST };
    let user = create_inst(co, toty, [v]);
    inst_insert_at(user, ip.bb, ip.pos, ip.head);
    set_name(user, "tmp.lcssa.user");
    var wl: i32[>..<] = [];
    wl.push(v);
    lcssa_phis_to_remove.clear();
    lcssa_inserted.clear();
    lcssa_collect = true;
    lcssa_se = true;
    form_lcssa_for_instructions(wl);
    lcssa_collect = false;
    lcssa_se = false;
    var ins: i32[>..<] = [];
    for p in lcssa_inserted { ins.push(p); }
    var rem: i32[>..<] = [];
    for p in lcssa_phis_to_remove { rem.push(p); }
    for p in ins { sx_remember_instruction(p); }
    for p in rem {
        if vals[p].first_use >= 0 { continue; }
        hm_del(sx_ivals, p as u64);
        hm_del(sx_ipvals, p as u64);
        inst_erase_from_parent(p);
    }
    let r = op(user, 0);
    inst_erase_from_parent(user);
    return r;
}

// ---------------------------------------------------------------------------------------------
// replaceCongruentIVs

// replaceCongruentIVInc(Phi, OrigPhi, L, DT, DeadInsts): may swap Phi and OrigPhi; returns them
fn sx_replace_congruent_iv_inc(phi0: i32, orig0: i32, l: i32, dead: i32[>..<]&) -> i32, i32 {
    var phi = phi0;
    var orig = orig0;
    let latch = loop_latch(l);
    if latch < 0 { return phi, orig; }
    var orig_inc = sx_phi_in(orig, latch);
    var iso_inc = sx_phi_in(phi, latch);
    if !is_inst(orig_inc) || !is_inst(iso_inc) { return phi, orig; }
    if vals[orig].ty == vals[phi].ty {
        let chained = hm_has(sx_chained, phi as u64);
        if !(chained || sx_is_expanded_addrec_phi(orig, orig_inc, l)) && (chained || sx_is_expanded_addrec_phi(phi, iso_inc, l)) {
            let t = orig; orig = phi; phi = t;
            let t2 = orig_inc; orig_inc = iso_inc; iso_inc = t2;
        }
    }
    let trunc = sc_get_truncate_or_noop(sc_get_scev(orig_inc), vals[iso_inc].ty);
    if orig_inc == iso_inc || trunc != sc_get_scev(iso_inc) || !li_replacement_preserves_lcssa(iso_inc, orig_inc) { return phi, orig; }
    var both_nuw = false;
    var both_nsw = false;
    let obo1 = sx_is_obo(orig_inc);
    let obo2 = sx_is_obo(iso_inc);
    if obo1 && obo2 {
        both_nuw = op_nuw(orig_inc) && op_nuw(iso_inc);
        both_nsw = op_nsw(orig_inc) && op_nsw(iso_inc);
    }
    if !sx_hoist_iv_inc(orig_inc, iso_inc, true) { return phi, orig; }
    if both_nuw || both_nsw {
        sx_set_nuw(orig_inc, op_nuw(orig_inc) || both_nuw);
        sx_set_nsw(orig_inc, op_nsw(orig_inc) || both_nsw);
    }
    var new_inc = orig_inc;
    if vals[orig_inc].ty != vals[iso_inc].ty {
        var pos: i32 = -1;
        var head = false;
        if iop(orig_inc) == OP_PHI {
            let fi = sx_first_insertion_pt(inst_parent(orig_inc));
            pos = fi.pos;
            head = true;
        } else { pos = inst_next(orig_inc); }
        new_inc = sx_trunc_or_bitcast_at(orig_inc, vals[iso_inc].ty, inst_parent(orig_inc), pos, head, inst_get_md(iso_inc, 0));
    }
    rauw(iso_inc, new_inc);
    dead.push(wvh_new(iso_inc, WVH_WEAK_TRACKING));
    return phi, orig;
}
fn sx_is_obo(i: i32) -> bool { let o = iop(i); o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL }

// IRBuilder<> Builder(BB, IP); SetCurrentDebugLocation(DL); CreateTruncOrBitCast(V, Ty, IVName) (ConstantFolder)
fn sx_trunc_or_bitcast_at(v: i32, ty: i32, bb: i32, pos: i32, head: bool, dl: i32) -> i32 {
    let o = if ty_scalar_bits(vals[v].ty) == ty_scalar_bits(ty) { OP_BITCAST } else { OP_TRUNC };
    if vals[v].ty == ty { return v; }
    if is_constant(v) { let f = ce_cast(o, v, ty); if f >= 0 { return f; } }
    let c = create_inst(o, ty, [v]);
    inst_insert_at(c, bb, pos, head);
    set_name(c, sx_ivname);
    if dl >= 0 { inst_set_md(c, 0, dl); }
    return c;
}

// replaceCongruentIVs(L, DT, DeadInsts, TTI): DeadInsts are WeakTrackingVH handles; returns NumElim
fn sx_replace_congruent_ivs(l: i32, dead: i32[>..<]&, has_tti: bool) -> i64 {
    var phis: i32[>..<] = [];
    var p = block_first(loop_header(l));
    while p >= 0 && iop(p) == OP_PHI { phis.push(p); p = inst_next(p); }
    if has_tti {
        std_stable_sort(phis, 0, phis.len) { a, b =>
            let at = vals[a].ty;
            let bt = vals[b].ty;
            if !ty_is_int(at) || !ty_is_int(bt) { ty_is_int(bt) && !ty_is_int(at) }
            else { ty_bits(bt) < ty_bits(at) }
        };
    }
    var nelim: i64 = 0;
    var expr_to_iv = hm_new();
    for phi0 in phis {
        var phi = phi0;
        // SimplifyPHINode: simplifyInstruction(PN, {DL, TLI, DT, AC}), else a constant SCEV
        var sv = simplify_instruction(phi);
        if sv < 0 && sc_is_scevable(vals[phi].ty) {
            let cs = sc_get_scev(phi);
            if sc_is_const(cs) { sv = sc_cval(cs); }
        }
        if sv >= 0 {
            if vals[sv].ty != vals[phi].ty { continue; }
            sc_forget_value(phi);
            rauw(phi, sv);
            dead.push(wvh_new(phi, WVH_WEAK_TRACKING));
            nelim++;
            continue;
        }
        if !sc_is_scevable(vals[phi].ty) { continue; }
        let key = sc_get_scev(phi) as u64;
        var orig = hm_get(expr_to_iv, key, -1) as i32;
        if orig < 0 {
            hm_put(expr_to_iv, key, phi as i64);
            if ty_is_int(vals[phi].ty) && has_tti && tti_is_truncate_free(vals[phi].ty, vals[phis[phis.len - 1]].ty) {
                let pe = sc_get_scev(phi);
                if sc_is_addrec(pe) {
                    let te = sc_get_truncate(pe, vals[phis[phis.len - 1]].ty, 0);
                    hm_put(expr_to_iv, te as u64, phi as i64);
                }
            }
            continue;
        }
        if (ty_kind(vals[orig].ty) == TK_PTR) != (ty_kind(vals[phi].ty) == TK_PTR) { continue; }
        let np, no = sx_replace_congruent_iv_inc(phi, orig, l, dead);
        phi = np;
        orig = no;
        hm_put(expr_to_iv, key, orig as i64);      // OrigPhiRef is a reference into the map
        nelim++;
        var newiv = orig;
        if vals[orig].ty != vals[phi].ty {
            let h = loop_header(l);
            let fi = sx_first_insertion_pt(h);
            newiv = sx_trunc_or_bitcast_at(orig, vals[phi].ty, h, fi.pos, true, inst_get_md(phi, 0));
        }
        rauw(phi, newiv);
        dead.push(wvh_new(phi, WVH_WEAK_TRACKING));
    }
    return nelim;
}

// hasRelatedExistingExpansion(S, At, L)
fn sx_has_related_existing_expansion(s: i32, at: i32, l: i32) -> bool {
    var exiting: i32[>..<] = [];
    loop_exiting_blocks(l, exiting);
    for bb in exiting {
        let t = block_terminator(bb);
        if iop(t) != OP_CONDBR { continue; }
        let c = op(t, 0);
        if !is_inst(c) || iop(c) != OP_ICMP { continue; }
        let lhs = op(c, 0);
        let rhs = op(c, 1);
        if !is_inst(lhs) || !is_inst(rhs) { continue; }
        if sc_get_scev(lhs) == s && dt_value_dominates_inst(lhs, at) { return true; }
        if sc_get_scev(rhs) == s && dt_value_dominates_inst(rhs, at) { return true; }
    }
    let dmark = sx_tmp.len;
    let r = sx_find_value_in_expr_value_map(s, at, dmark);
    sx_tmp.resize(dmark);
    return r >= 0;
}

// ---------------------------------------------------------------------------------------------
// isHighCostExpansion

// SCEVOperand
struct SxOp { parent: i64, idx: i64, s: i32 }

// costAndCollectOperands<T>(WorkItem, TTI, CostKind, Worklist)
fn sx_cost_and_collect(w: SxOp, kind: i64, wl: SxOp[>..<]&) -> i64 {
    let s = w.s;
    var cost: i64 = 0;
    // Operations: (Opcode, MinIdx, MaxIdx)
    var opc: i64[4] = [0, 0, 0, 0];
    var mins: i64[4] = [0, 0, 0, 0];
    var maxs: i64[4] = [0, 0, 0, 0];
    var nops_: i64 = 0;
    let k = sc_kind(s);
    let ty = sc_ty(s);
    let n = sc_nops(s);
    if k == SC_PTRTOADDR || k == SC_PTRTOINT || k == SC_TRUNC || k == SC_ZEXT || k == SC_SEXT {
        let o = if k == SC_PTRTOADDR { OP_PTRTOADDR } else if k == SC_PTRTOINT { OP_PTRTOINT } else if k == SC_TRUNC { OP_TRUNC } else if k == SC_ZEXT { OP_ZEXT } else { OP_SEXT };
        opc[0] = o; mins[0] = 0; maxs[0] = 0; nops_ = 1;
        cost = tti_cast_cost(o, ty, sc_ty(sc_op(s, 0)), kind);
    } else if k == SC_UDIV {
        var o = OP_UDIV;
        let r = sc_op(s, 1);
        if sc_is_const(r) && ap_is_pow2(sc_ap(r)) { o = OP_LSHR; }
        opc[0] = o; mins[0] = 0; maxs[0] = 1; nops_ = 1;
        cost = tti_arith_cost(o, ty, kind, []);
    } else if k == SC_ADD {
        opc[0] = OP_ADD; mins[0] = 0; maxs[0] = 1; nops_ = 1;
        cost = (n - 1) * tti_arith_cost(OP_ADD, ty, kind, []);
    } else if k == SC_MUL {
        var o = OP_MUL;
        if n == 2 && sc_is_const(sc_op(s, 0)) {
            let c = sc_ap(sc_op(s, 0));
            if ap_is_all_ones(c) { o = OP_SUB; } else if ap_is_pow2(c) { o = OP_SHL; }
        }
        opc[0] = o; mins[0] = 0; maxs[0] = 1; nops_ = 1;
        cost = (n - 1) * tti_arith_cost(o, ty, kind, []);
    } else if k == SC_SMAX || k == SC_UMAX || k == SC_SMIN || k == SC_UMIN || k == SC_SEQUMIN {
        let ct = cmp_result_ty(ty);
        opc[0] = OP_ICMP; mins[0] = 0; maxs[0] = 1;
        cost += (n - 1) * tti_cmpsel_cost(OP_ICMP, ty, ct, -1, kind);
        opc[1] = OP_SELECT; mins[1] = 0; maxs[1] = 2;
        cost += (n - 1) * tti_cmpsel_cost(OP_SELECT, ty, ct, -1, kind);
        nops_ = 2;
        if k == SC_SEQUMIN {
            opc[2] = OP_ICMP; mins[2] = 0; maxs[2] = 0;
            cost += (n - 1) * tti_cmpsel_cost(OP_ICMP, ty, ct, -1, kind);
            opc[3] = OP_OR; mins[3] = 0; maxs[3] = 1;
            cost += (if n > 2 { n - 2 } else { 0 }) * tti_arith_cost(OP_OR, ty, kind, []);
            nops_ = 4;
            // the final CmpSelCost(Select, 1, 0, 1)
            cost += tti_cmpsel_cost(OP_SELECT, ty, ct, -1, kind);
        }
    } else if k == SC_ADDREC {
        let nrec = n - 1;
        cost += tti_cf_cost(OP_PHI, kind) * nrec;
        cost += tti_arith_cost(OP_ADD, ty, kind, []) * nrec;
        wl.push(SxOp { parent: OP_PHI, idx: 0, s: sc_op(s, 0) });
        for i in 1..n { wl.push(SxOp { parent: OP_ADD, idx: 1, s: sc_op(s, i) }); }
    }
    for c in nops_ {
        // the sequential umin's last Select (MinIdx 0, MaxIdx 1) is pushed after the Or
        sx_push_cost_ops(s, opc[c], mins[c], maxs[c], wl);
    }
    if k == SC_SEQUMIN { sx_push_cost_ops(s, OP_SELECT, 0, 1, wl); }
    return cost;
}
fn sx_push_cost_ops(s: i32, o: i64, mn: i64, mx: i64, wl: SxOp[>..<]&) {
    for i in sc_nops(s) {
        let a = if i > mn { i } else { mn };
        let idx = if a < mx { a } else { mx };
        wl.push(SxOp { parent: o, idx: idx, s: sc_op(s, i) });
    }
}

// isHighCostExpansionHelper
fn sx_high_cost_helper(w: SxOp, l: i32, at: i32, cost: i64&, budget: i64, wl: SxOp[>..<]&, processed: HMap&) -> bool {
    if cost > budget { return true; }
    let s = w.s;
    if !sc_is_const(s) {
        if hm_has(processed, s as u64) { return false; }
        hm_put(processed, s as u64, 1);
    }
    if sx_has_related_existing_expansion(s, at, l) { return false; }
    let fv = block_func(loop_header(l));
    let min_size = aset_has(alist_fn(globs[glob_of(fv)].attrs), AK_MinSize);
    let kind = if min_size { TCK_CODE_SIZE } else { TCK_RECIP_THROUGHPUT };
    let k = sc_kind(s);
    if k == SC_UNKNOWN || k == SC_VSCALE { return false; }
    if k == SC_CONST {
        if kind != TCK_CODE_SIZE { return false; }
        cost += tti_int_imm_cost_inst(w.parent, w.idx, sc_ap(s), sc_ty(s), kind);
        return cost > budget;
    }
    if k == SC_TRUNC || k == SC_PTRTOADDR || k == SC_PTRTOINT || k == SC_ZEXT || k == SC_SEXT {
        cost += sx_cost_and_collect(w, kind, wl);
        return false;
    }
    if k == SC_UDIV {
        if sx_has_related_existing_expansion(sc_add(s, sc_get_constant_ty(sc_ty(s), 1, false)), at, l) { return false; }
        cost += sx_cost_and_collect(w, kind, wl);
        return false;
    }
    cost += sx_cost_and_collect(w, kind, wl);
    return cost > budget;
}

// isHighCostExpansion(Exprs, L, Budget, TTI, At)
fn sx_is_high_cost_expansion(exprs: const i32[:], l: i32, budget: i64, at: i32) -> bool {
    var wl: SxOp[>..<] = [];
    var processed = hm_new();
    var cost: i64 = 0;
    let scaled = budget * TCC_BASIC;
    for e in exprs { wl.push(SxOp { parent: -1, idx: -1, s: e }); }
    while wl.len > 0 {
        let w = wl.pop();
        if sx_high_cost_helper(w, l, at, cost, scaled, wl, processed) { return true; }
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// isSafeToExpand

// SCEVFindUnsafe (visitAll, each node once, stops when unsafe)
recursive fn sx_find_unsafe(s: i32, seen: HMap&) -> bool {
    if hm_has(seen, s as u64) { return false; }
    hm_put(seen, s as u64, 1);
    let k = sc_kind(s);
    if k == SC_UDIV {
        let r = sc_op(s, 1);
        if !sc_is_known_non_zero(r) || !sc_is_guaranteed_not_to_be_poison(r) { return true; }
    }
    if k == SC_ADDREC {
        if loop_preheader(sc_loop(s)) < 0 && (!sx_canonical || !sc_is_affine(s)) { return true; }
    }
    if k == SC_CONST || k == SC_VSCALE || k == SC_UNKNOWN || k == SC_CNC { return false; }
    for i in sc_nops(s) { if sx_find_unsafe(sc_op(s, i), seen) { return true; } }
    return false;
}
// isSafeToExpand(S)
fn sx_is_safe_to_expand(s: i32) -> bool {
    var seen = hm_new();
    return !sx_find_unsafe(s, seen);
}
// isSafeToExpandAt(S, InsertionPoint)
fn sx_is_safe_to_expand_at(s: i32, ip: i32) -> bool {
    if !sx_is_safe_to_expand(s) { return false; }
    let bb = inst_parent(ip);
    if sc_properly_dominates(s, bb) { return true; }
    if sc_dominates(s, bb) {
        if block_terminator(bb) == ip { return true; }
        if sc_is_unknown(s) {
            for k in nops(ip) { if op(ip, k) == sc_value(s) { return true; } }
        }
    }
    return false;
}

// SCEVExpanderCleaner::cleanup (ResultUsed = false)
fn sx_cleanup() {
    for i in sx_oflags_order {
        if is_dead(i) { continue; }
        insts[inst_of(i)].flags = hm_get(sx_oflags, i as u64, 0) as u8;
    }
    var ins: i32[>..<] = [];
    sx_all_inserted_instructions(ins);
    sx_clear();
    var k = ins.len - 1;
    while k >= 0 {
        let i = ins[k];
        rauw(i, c_poison(vals[i].ty));
        inst_erase_from_parent(i);
        k--;
    }
}
