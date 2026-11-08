// CFG utilities shared by SimplifyCFG and later passes (JumpThreading, LoopSimplify's exit merging, ...).
// Ports from llvm/lib/Transforms/Utils/Local.cpp: ConstantFoldTerminator, RecursivelyDeleteTriviallyDeadInstructions,
//   MergeBasicBlockIntoOnlyPred, TryToSimplifyUncondBranchFromEmptyBlock (CanPropagatePredecessorsForPHIs,
//   CanRedirectPredsOfEmptyBBToSucc, introduceTooManyPhiEntries, redirectValuesFromPredecessorsToPhi and its
//   helpers), EliminateDuplicatePHINodes, changeToUnreachable, changeToCall (createCallMatchingInvoke),
//   removeUnwindEdge, markAliveBlocks, removeUnreachableBlocks, hoistAllInstructionsInto,
//   canReplaceOperandWithVariable;
// from llvm/lib/Transforms/Utils/BasicBlockUtils.cpp: detachDeadBlocks/emptyAndDetachBlock, DeleteDeadBlock(s),
//   FoldSingleEntryPHINodes, MergeBlockIntoPredecessor, GetIfCondition, InvertBranch,
//   IsBlockFollowedByDeoptOrUnreachable, SplitBlockPredecessors with a DomTreeUpdater;
// from llvm/lib/IR/Instruction.cpp: isIdenticalTo, isIdenticalToWhenDefined, isSameOperationAs,
//   hasSameSpecialState; from llvm/lib/IR/Value.cpp: replaceAllUsesWith for blocks;
// from llvm/lib/Analysis/CFG.cpp: FindFunctionBackedges.
//
// The DomTreeUpdater is the active one of dtu.goose; cu_dtu says whether the caller passed one (LLVM's DTU
// pointer). Debug records: erasing an instruction a record uses fails loudly (inst_erase_from_parent).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import domtree;
import dtu;
import local;
import loopsimplify;
import profdata;
import pm;
import vt;
import constfold;
import dinfo;
import earlycse;
import instident;
import fpu;

var cu_dtu: bool = false;

fn cu_not_ported(what: const u8[:]) { fatal(str("CFG utilities: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// Small CFG queries

// predecessors(BB) into out (one entry per edge, use-list order)
fn cu_preds(bb: i32, out: i32[>..<]&) {
    out.clear();
    each_pred(bb) { p => out.push(p); };
}
// successors(BB)
fn cu_succs(bb: i32, out: i32[>..<]&) {
    out.clear();
    let t = block_terminator(bb);
    if t < 0 { return; }
    for k in term_nsucc(t) { out.push(term_succ(t, k)); }
}
fn cu_push_unique(xs: i32[>..<]&, x: i32) -> bool {
    if position(xs, x) >= 0 { return false; }
    xs.push(x);
    return true;
}
// BasicBlock::getUniquePredecessor
fn cu_unique_pred(bb: i32) -> i32 {
    var r: i32 = -1;
    var ok = true;
    each_pred(bb) { p => if r < 0 { r = p; } else if r != p { ok = false; } };
    return if ok { r } else { -1 };
}
// BasicBlock::getSingleSuccessor
fn cu_single_succ(bb: i32) -> i32 {
    let t = block_terminator(bb);
    if t < 0 || term_nsucc(t) != 1 { return -1; }
    return term_succ(t, 0);
}
// BasicBlock::getUniqueSuccessor
fn cu_unique_succ(bb: i32) -> i32 {
    let t = block_terminator(bb);
    if t < 0 { return -1; }
    let n = term_nsucc(t);
    if n == 0 { return -1; }
    let s = term_succ(t, 0);
    for k in 1..n { if term_succ(t, k) != s { return -1; } }
    return s;
}
// BasicBlock::hasNPredecessorsOrMore
fn cu_has_n_preds_or_more(bb: i32, n: i64) -> bool {
    var c = 0;
    each_pred(bb) { p => c++; };
    return c >= n;
}
fn cu_has_n_preds(bb: i32, n: i64) -> bool { pred_count(bb) == n }
fn cu_pred_empty(bb: i32) -> bool { pred_count(bb) == 0 }
fn cu_is_succ(bb: i32, s: i32) -> bool {
    let t = block_terminator(bb);
    if t < 0 { return false; }
    for k in term_nsucc(t) { if term_succ(t, k) == s { return true; } }
    return false;
}
fn cu_has_phis(bb: i32) -> bool { let f = block_first(bb); return f >= 0 && iop(f) == OP_PHI; }
fn cu_block_size(bb: i32) -> i64 { var n = 0; var i = block_first(bb); while i >= 0 { n++; i = inst_next(i); } return n; }
fn cu_is_entry(bb: i32) -> bool { func_entry(block_func(bb)) == bb }

// BlockAddresses that were destroyed (BlockAddress::destroyConstant): no longer count as taking the address.
var cu_dead_ba: i32[>..<];
// BasicBlock::hasAddressTaken: a BlockAddress for the block exists (LLVM keeps a reference count of them).
fn cu_has_address_taken(bb: i32) -> bool { cu_block_address(bb) >= 0 }
fn cu_block_address(bb: i32) -> i32 {
    var u = first_use(bb);
    while u >= 0 {
        let us = uses[u].user;
        if vals[us].kind == VK_BLOCKADDR && position(cu_dead_ba, us) < 0 { return us; }
        u = use_next(u);
    }
    return -1;
}
fn cu_destroy_block_address(ba: i32) {
    if position(cu_dead_ba, ba) < 0 { cu_dead_ba.push(ba); }
    // the constant no longer refers to the function and block (it is dead and never printed)
    drop_all_refs(ba);
}

// Value::replaceAllUsesWith for a BasicBlock: users (not BlockAddresses, which aren't users in LLVM) are set
// head-first, then the successors' PHIs see the new block; a live BlockAddress fails loudly.
fn cu_block_rauw(old: i32, nw: i32) {
    var u = first_use(old);
    while u >= 0 {
        let nu = use_next(u);
        if vals[uses[u].user].kind != VK_BLOCKADDR { use_set(u, nw); }
        u = nu;
    }
    block_replace_successors_phi_uses_with(old, old, nw);
    if cu_has_address_taken(old) { cu_not_ported("replacing the uses of a block whose address is taken"); }
}

// Instruction::isSpecialTerminator: invoke, callbr, catchswitch, cleanupret, catchret... (the EH and callbr ones)
fn cu_is_special_terminator(t: i32) -> bool {
    let o = iop(t);
    return o == OP_INVOKE || o == OP_CALLBR || o == OP_CATCHSWITCH || o == OP_CATCHRET || o == OP_CLEANUPRET ||
           o == OP_RESUME;
}

// dtu helpers
fn cu_upd(ups: DTUpdate[>..<]&, kind: i32, from: i32, to: i32) { ups.push(DTUpdate { kind: kind, from: from, to: to }); }
fn cu_apply(ups: const DTUpdate[:]) { if cu_dtu { dtu_apply_updates(ups); } }
fn cu_apply1(kind: i32, from: i32, to: i32) {
    if !cu_dtu { return; }
    let ups: DTUpdate[1] = [DTUpdate { kind: kind, from: from, to: to }];
    dtu_apply_updates(ups);
}

// ---------------------------------------------------------------------------------------------
// Instruction identity (Instruction.cpp)

fn cu_ints_equal(a: i32, b: i32) -> bool {
    let x = insts[inst_of(a)];
    let y = insts[inst_of(b)];
    if x.naux != y.naux { return false; }
    for k in x.naux { if ints[x.aux + k] != ints[y.aux + k] { return false; } }
    return true;
}

// CallBase::hasIdenticalOperandBundleSchema
fn cu_same_bundle_schema(a: i32, b: i32) -> bool {
    let n = cb_nbundles(a);
    if n != cb_nbundles(b) { return false; }
    for k in n {
        if cb_bundle_tag(a, k) != cb_bundle_tag(b, k) || cb_bundle_begin(a, k) != cb_bundle_begin(b, k) ||
           cb_bundle_count(a, k) != cb_bundle_count(b, k) { return false; }
    }
    return true;
}

// The call's attributes compare equal, or (IntersectAttrs) intersect.
fn cu_call_attrs_same(a: i32, b: i32, intersect: bool) -> bool {
    let la = insts[inst_of(a)].attrs;
    let lb = insts[inst_of(b)].attrs;
    if la == lb { return true; }
    if !intersect { return false; }
    let r, ok = cu_alist_intersect(la, lb);
    return ok;
}

// hasSameSpecialState(I2, IgnoreAlignment, IntersectAttrs)
fn cu_same_special_state(a: i32, b: i32, ignore_align: bool, intersect: bool) -> bool {
    let o = iop(a);
    let x = insts[inst_of(a)];
    let y = insts[inst_of(b)];
    if o == OP_ALLOCA { return x.ty2 == y.ty2 && (x.align == y.align || ignore_align); }
    if o == OP_LOAD || o == OP_STORE {
        return (x.bits & 1) == (y.bits & 1) && (x.align == y.align || ignore_align) && x.ord == y.ord && x.ss == y.ss;
    }
    if o == OP_ICMP || o == OP_FCMP { return x.pred == y.pred; }
    if o == OP_CALL {
        let ta = x.pred == 1 || x.pred == 2;
        let tb = y.pred == 1 || y.pred == 2;
        return ta == tb && x.cc == y.cc && cu_call_attrs_same(a, b, intersect) && cu_same_bundle_schema(a, b);
    }
    if o == OP_INVOKE || o == OP_CALLBR {
        return x.cc == y.cc && cu_call_attrs_same(a, b, intersect) && cu_same_bundle_schema(a, b);
    }
    if o == OP_SWITCH { return true; }       // case values are operands here, compared with them
    if o == OP_INSERTVALUE || o == OP_EXTRACTVALUE || o == OP_SHUFFLEVECTOR { return cu_ints_equal(a, b); }
    if o == OP_FENCE { return x.ord == y.ord && x.ss == y.ss; }
    if o == OP_CMPXCHG {
        return x.bits == y.bits && (x.align == y.align || ignore_align) && x.ord == y.ord && x.ord2 == y.ord2 && x.ss == y.ss;
    }
    if o == OP_ATOMICRMW {
        return x.pred == y.pred && x.bits == y.bits && (x.align == y.align || ignore_align) && x.ord == y.ord && x.ss == y.ss;
    }
    if o == OP_GEP { return x.ty2 == y.ty2; }
    return true;
}

// Instruction::isIdenticalToWhenDefined(I, IntersectAttrs)
fn cu_identical_when_defined(a: i32, b: i32, intersect: bool) -> bool {
    if iop(a) != iop(b) || nops(a) != nops(b) || vals[a].ty != vals[b].ty { return false; }
    if nops(a) == 0 { return cu_same_special_state(a, b, false, intersect); }
    for k in nops(a) { if op(a, k) != op(b, k) { return false; } }
    if iop(a) == OP_PHI {
        for k in nops(a) { if phi_block(a, k) != phi_block(b, k) { return false; } }
        return true;
    }
    return cu_same_special_state(a, b, false, intersect);
}
// SubclassOptionalData: poison-generating flags and fast-math flags
fn cu_same_optional_data(a: i32, b: i32) -> bool {
    let x = insts[inst_of(a)];
    let y = insts[inst_of(b)];
    return x.flags == y.flags && x.fmf == y.fmf;
}
// Instruction::isIdenticalTo
fn cu_identical(a: i32, b: i32) -> bool { cu_identical_when_defined(a, b, false) && cu_same_optional_data(a, b) }

let CU_IGNORE_ALIGN = 1;
let CU_SCALAR_TYPES = 2;
let CU_INTERSECT_ATTRS = 4;
// Instruction::isSameOperationAs(I, flags)
fn cu_same_operation_as(a: i32, b: i32, flags: i64) -> bool {
    let scal = (flags & CU_SCALAR_TYPES) != 0;
    if iop(a) != iop(b) || nops(a) != nops(b) { return false; }
    if scal { if ty_scalar(vals[a].ty) != ty_scalar(vals[b].ty) { return false; } }
    else if vals[a].ty != vals[b].ty { return false; }
    for k in nops(a) {
        let ta = vals[op(a, k)].ty;
        let tb = vals[op(b, k)].ty;
        if scal { if ty_scalar(ta) != ty_scalar(tb) { return false; } } else if ta != tb { return false; }
    }
    return cu_same_special_state(a, b, (flags & CU_IGNORE_ALIGN) != 0, (flags & CU_INTERSECT_ATTRS) != 0);
}

// AttributeList::intersectWith (instident.goose)
fn cu_alist_intersect(a: i32, b: i32) -> i32, bool {
    let ok, l = ii_alist_intersect(a, b);
    return l, ok;
}

// ---------------------------------------------------------------------------------------------
// RecursivelyDeleteTriviallyDeadInstructions(V, TLI = null)

fn cu_recursively_delete_dead(v: i32) -> bool {
    if !is_inst(v) || is_dead(v) { return false; }
    let save = local_have_tli;
    local_have_tli = false;
    if !is_instruction_trivially_dead(v) { local_have_tli = save; return false; }
    var dead: i32[>..<] = [];
    dead.push(v);
    cu_recursively_delete_dead_list(dead);
    local_have_tli = save;
    return true;
}

fn cu_recursively_delete_dead_list(dead: i32[>..<]&) {
    while dead.len > 0 {
        let i = dead.pop();
        if i < 0 || is_dead(i) { continue; }
        for k in nops(i) {
            let ov = op(i, k);
            set_op(i, k, -1);
            if ov < 0 || !has_use_list(ov) || vals[ov].first_use >= 0 { continue; }
            if is_inst(ov) && is_instruction_trivially_dead(ov) { dead.push(ov); }
        }
        inst_erase_from_parent(i);
    }
}

// ---------------------------------------------------------------------------------------------
// Block deletion (BasicBlockUtils.cpp)

// emptyAndDetachBlock(BB, Updates, KeepOneInputPHIs)
fn cu_empty_and_detach_block(bb: i32, ups: DTUpdate[>..<]&, keep_one_input_phis: bool) {
    var uniq: i32[>..<] = [];
    var succs: i32[>..<] = [];
    cu_succs(bb, succs);
    for s in succs {
        block_remove_predecessor(s, bb, keep_one_input_phis);
        if cu_dtu && cu_push_unique(uniq, s) { cu_upd(ups, DT_DELETE, bb, s); }
    }
    loop {
        let i = block_last(bb);
        if i < 0 { break; }
        if vals[i].first_use >= 0 { rauw(i, c_poison(vals[i].ty)); }
        inst_erase_from_parent(i);
    }
    block_append_inst(bb, create_inst(OP_UNREACHABLE, T_VOID, []));
}

// detachDeadBlocks
fn cu_detach_dead_blocks(bbs: const i32[:], ups: DTUpdate[>..<]&, keep_one_input_phis: bool) {
    for bb in bbs {
        let fnp = first_non_phi(bb);
        if fnp >= 0 && (iop(fnp) == OP_CLEANUPPAD || iop(fnp) == OP_CATCHPAD) {
            var rets: i32[>..<] = [];
            var u = first_use(fnp);
            while u >= 0 {
                let us = uses[u].user;
                if is_inst(us) && (iop(us) == OP_CATCHRET || iop(us) == OP_CLEANUPRET) { cu_push_unique(rets, inst_parent(us)); }
                u = use_next(u);
            }
            for r in rets { cu_empty_and_detach_block(r, ups, keep_one_input_phis); }
        }
        cu_empty_and_detach_block(bb, ups, keep_one_input_phis);
    }
}

// BasicBlock::eraseFromParent for an emptied block
fn cu_erase_block(bb: i32) {
    if cu_has_address_taken(bb) { cu_not_ported("deleting a block whose address is taken"); }
    block_erase(bb);
}

// DeleteDeadBlocks(BBs, DTU, KeepOneInputPHIs)
fn cu_delete_dead_blocks(bbs: const i32[:], keep_one_input_phis: bool) {
    var ups: DTUpdate[>..<] = [];
    cu_detach_dead_blocks(bbs, ups, keep_one_input_phis);
    cu_apply(ups);
    for bb in bbs {
        if cu_has_address_taken(bb) { cu_not_ported("deleting a block whose address is taken"); }
        if cu_dtu { dtu_delete_bb(bb); } else { block_erase(bb); }
    }
}
fn cu_delete_dead_block(bb: i32) {
    let one: i32[1] = [bb];
    cu_delete_dead_blocks(one, false);
}

// FoldSingleEntryPHINodes(BB)
fn cu_fold_single_entry_phis(bb: i32) -> bool {
    if !cu_has_phis(bb) { return false; }
    loop {
        let pn = block_first(bb);
        if pn < 0 || iop(pn) != OP_PHI { break; }
        let v = phi_value(pn, 0);
        if v != pn { rauw(pn, v); } else { rauw(pn, c_poison(vals[pn].ty)); }
        inst_erase_from_parent(pn);
    }
    return true;
}

// Move instructions [from, upto) of src before pos (BasicBlock::splice); upto = -1 means to the end.
fn cu_splice_before(pos: i32, from: i32, upto: i32) {
    var i = from;
    while i >= 0 && i != upto {
        let ni = inst_next(i);
        inst_move_before(i, pos);
        i = ni;
    }
}
// Move instructions [from, upto) to the end of bb.
fn cu_splice_to_end(bb: i32, from: i32, upto: i32) {
    var i = from;
    while i >= 0 && i != upto {
        let ni = inst_next(i);
        inst_move_to_end(i, bb);
        i = ni;
    }
}

// HasLoopOrEntryConvergenceToken
fn cu_has_loop_or_entry_convergence_token(bb: i32) -> bool {
    var i = block_first(bb);
    while i >= 0 {
        let id = inst_iid(i);
        if id == IID_experimental_convergence_loop || id == IID_experimental_convergence_entry { return true; }
        i = inst_next(i);
    }
    return false;
}

// MergeBlockIntoPredecessor(BB, DTU, LI = null, MSSAU = null, MemDep = null, PredecessorWithTwoSuccessors = false)
fn cu_merge_block_into_predecessor(bb: i32) -> bool {
    if cu_has_address_taken(bb) { return false; }
    let pred = cu_unique_pred(bb);
    if pred < 0 { return false; }
    if pred == bb { return false; }
    let pti = block_terminator(pred);
    if cu_is_special_terminator(pti) || inst_may_have_side_effects(pti) { return false; }
    if cu_unique_succ(pred) != bb { return false; }
    var i = block_first(bb);
    while i >= 0 && iop(i) == OP_PHI {
        for k in nops(i) { if op(i, k) == i { return false; } }
        i = inst_next(i);
    }
    if cu_has_loop_or_entry_convergence_token(bb) && cu_has_loop_or_entry_convergence_token(pred) { return false; }
    if cu_has_phis(bb) { cu_fold_single_entry_phis(bb); }
    var ups: DTUpdate[>..<] = [];
    if cu_dtu {
        var seen: i32[>..<] = [];
        var succs_of_pred: i32[>..<] = [];
        cu_succs(pred, succs_of_pred);
        var succs: i32[>..<] = [];
        cu_succs(bb, succs);
        for s in succs { if position(succs_of_pred, s) < 0 && cu_push_unique(seen, s) { cu_upd(ups, DT_INSERT, pred, s); } }
        seen.clear();
        for s in succs { if cu_push_unique(seen, s) { cu_upd(ups, DT_DELETE, bb, s); } }
        cu_upd(ups, DT_DELETE, pred, bb);
    }
    let sti = block_terminator(bb);
    // Move all definitions in the successor to the predecessor
    cu_splice_before(pti, block_first(bb), sti);
    cu_block_rauw(bb, pred);
    // Delete the unconditional branch from the predecessor; move the terminator.
    inst_erase_from_parent(pti);
    inst_move_to_end(sti, pred);
    block_append_inst(bb, create_inst(OP_UNREACHABLE, T_VOID, []));
    if vals[pred].name < 0 && vals[bb].name >= 0 { cu_take_name(pred, bb); }
    cu_apply(ups);
    cu_delete_dead_block(bb);
    return true;
}

// Value::takeName(V)
fn cu_take_name(dst: i32, src: i32) {
    if vals[src].name < 0 { if vals[dst].name >= 0 { set_name(dst, ""); } return; }
    var buf: u8[>..] = [];
    buf.append(sbytes(vals[src].name));
    set_name(src, "");
    set_name(dst, buf);
}

// MergeBasicBlockIntoOnlyPred(DestBB, DTU)
fn cu_merge_basic_block_into_only_pred(dest: i32) {
    loop {
        let pn = block_first(dest);
        if pn < 0 || iop(pn) != OP_PHI { break; }
        var nv = phi_value(pn, 0);
        if nv == pn { nv = c_poison(vals[pn].ty); }
        rauw(pn, nv);
        inst_erase_from_parent(pn);
    }
    let pred = single_pred(dest);
    if pred < 0 { fatal("internal: MergeBasicBlockIntoOnlyPred: block doesn't have a single predecessor"); }
    let replace_entry = cu_is_entry(pred);
    var ups: DTUpdate[>..<] = [];
    if cu_dtu {
        var seen: i32[>..<] = [];
        var pp: i32[>..<] = [];
        cu_preds(pred, pp);
        for p in pp { if p != pred && cu_push_unique(seen, p) { cu_upd(ups, DT_INSERT, p, dest); } }
        seen.clear();
        for p in pp { if cu_push_unique(seen, p) { cu_upd(ups, DT_DELETE, p, pred); } }
        cu_upd(ups, DT_DELETE, pred, dest);
    }
    if cu_has_address_taken(dest) { cu_not_ported("MergeBasicBlockIntoOnlyPred of an address-taken block"); }
    cu_block_rauw(pred, dest);
    inst_erase_from_parent(block_terminator(pred));
    let first = block_first(dest);
    if first >= 0 {
        var i = block_first(pred);
        while i >= 0 { let ni = inst_next(i); inst_move_before(i, first); i = ni; }
    } else {
        cu_splice_to_end(dest, block_first(pred), -1);
    }
    block_append_inst(pred, create_inst(OP_UNREACHABLE, T_VOID, []));
    if replace_entry { block_move_after(dest, pred); }
    if cu_dtu {
        dtu_apply_updates_permissive(ups);
        dtu_delete_bb(pred);
        if replace_entry && dtu_dt { dtu_recalculate(); }
    } else {
        block_erase(pred);
    }
}

// ---------------------------------------------------------------------------------------------
// ConstantFoldTerminator(BB, DeleteDeadConditions, TLI = null, DTU)

// copyMetadata(*BI, {MD_loop, MD_dbg, MD_annotation})
fn cu_copy_md_kinds(dst: i32, src: i32, kinds: const i32[:]) {
    for k in kinds {
        let m = inst_get_md(src, k);
        if m >= 0 { inst_set_md(dst, k, m); }
    }
}
let MDK_DBG: i32 = 0;
let MDK_LOOP_CU: i32 = 18;
fn mdk_annotation() -> i32 { md_kind_id("annotation") }
fn mdk_make_implicit() -> i32 { md_kind_id("make.implicit") }

// IRBuilder<> Builder(T) + CreateBr(Dest): an unconditional branch before t with t's debug location
fn cu_create_br_before(dest: i32, t: i32) -> i32 {
    let br = create_inst(OP_BR, T_VOID, [dest]);
    inst_insert_before(br, t);
    let dl = inst_get_md(t, MDK_DBG);
    if dl >= 0 { inst_set_md(br, MDK_DBG, dl); }
    return br;
}

fn cu_cint_eq(a: i32, b: i32) -> bool { a == b }

fn cu_constant_fold_terminator(bb: i32, delete_dead_conds: bool) -> bool {
    let t = block_terminator(bb);
    let o = iop(t);
    if o == OP_CONDBR {
        let d1 = term_succ(t, 0);
        let d2 = term_succ(t, 1);
        if d1 == d2 {
            block_remove_predecessor(d1, bb, false);
            let nb = cu_create_br_before(d1, t);
            let kinds: i32[3] = [MDK_LOOP_CU, MDK_DBG, mdk_annotation()];
            cu_copy_md_kinds(nb, t, kinds);
            let c = op(t, 0);
            inst_erase_from_parent(t);
            if delete_dead_conds { cu_recursively_delete_dead(c); }
            return true;
        }
        let c = op(t, 0);
        if vals[c].kind == VK_CINT {
            let taken = !cint_is_zero(c);
            let dest = if taken { d1 } else { d2 };
            let old = if taken { d2 } else { d1 };
            block_remove_predecessor(old, bb, false);
            let nb = cu_create_br_before(dest, t);
            let kinds: i32[3] = [MDK_LOOP_CU, MDK_DBG, mdk_annotation()];
            cu_copy_md_kinds(nb, t, kinds);
            inst_erase_from_parent(t);
            cu_apply1(DT_DELETE, bb, old);
            return true;
        }
        return false;
    }
    if o == OP_SWITCH {
        let si = t;
        var ci = op(si, 0);
        if vals[ci].kind != VK_CINT { ci = -1; }
        let def = sw_default(si);
        var only = def;
        if cu_default_dest_unreachable(si) && sw_ncases(si) > 0 { only = sw_case_dest(si, 0); }
        var changed = false;
        var k: i64 = 0;
        while k < sw_ncases(si) {
            if ci >= 0 && sw_case_val(si, k) == ci { only = sw_case_dest(si, k); break; }
            if sw_case_dest(si, k) == def {
                let md = pd_valid_md(si);
                let n = sw_ncases(si);
                if n > 1 && md >= 0 {
                    var ws: u64[>..<] = [];
                    pd_extract_md(md, ws);
                    if ws[0] > 0xFFFFFFFFFFFFFFFF - ws[k + 1] { pd_fit(ws); }
                    ws[0] += ws[k + 1];
                    let last = ws.len - 1;
                    let tmp = ws[k + 1];
                    ws[k + 1] = ws[last];
                    ws[last] = tmp;
                    ws.resize(last);
                    pd_set_fitted(si, ws, pd_has_origin(md), false);
                }
                block_remove_predecessor(def, bb, false);
                sw_remove_case_raw(si, k);
                let nc = op(si, 0);
                if vals[nc].kind == VK_CINT { ci = nc; k = 0; }
                changed = true;
                continue;
            }
            if sw_case_dest(si, k) != only { only = -1; }
            k++;
        }
        if ci >= 0 && only < 0 { only = sw_default(si); }
        if only >= 0 {
            cu_create_br_before(only, si);
            var removed: i32[>..<] = [];
            var keep = only;
            var succs: i32[>..<] = [];
            cu_succs(bb, succs);
            for s in succs {
                if cu_dtu && s != only { cu_push_unique(removed, s); }
                if s == keep { keep = -1; } else { block_remove_predecessor(s, bb, false); }
            }
            let c = op(si, 0);
            inst_erase_from_parent(si);
            if delete_dead_conds { cu_recursively_delete_dead(c); }
            if cu_dtu {
                var ups: DTUpdate[>..<] = [];
                for r in removed { cu_upd(ups, DT_DELETE, bb, r); }
                dtu_apply_updates(ups);
            }
            return true;
        }
        if sw_ncases(si) == 1 {
            let cv = sw_case_val(si, 0);
            let cd = sw_case_dest(si, 0);
            let cond = cu_build_icmp_before(P_EQ, op(si, 0), cv, "cond", si);
            let nb = create_inst(OP_CONDBR, T_VOID, [cond, cd, sw_default(si)]);
            inst_insert_before(nb, si);
            let dl = inst_get_md(si, MDK_DBG);
            if dl >= 0 { inst_set_md(nb, MDK_DBG, dl); }
            var ws: u64[>..<] = [];
            if pd_extract(si, ws) && ws.len == 2 {
                let both: u64[2] = [ws[1] & 0xFFFFFFFF, ws[0] & 0xFFFFFFFF];
                inst_set_md(nb, MDK_PROF, pd_create(both, false));
            }
            let mi = inst_get_md(si, mdk_make_implicit());
            if mi >= 0 { inst_set_md(nb, mdk_make_implicit(), mi); }
            inst_erase_from_parent(si);
            return true;
        }
        return changed;
    }
    if o == OP_INDIRECTBR {
        let addr = op(t, 0);
        let ba = cu_strip_pointer_casts(addr);
        if vals[ba].kind == VK_BLOCKADDR {
            let only = op(ba, 1);
            var removed: i32[>..<] = [];
            cu_create_br_before(only, t);
            var keep = only;
            for k in nops(t) - 1 {
                let d = op(t, 1 + k);
                if cu_dtu && d != only { cu_push_unique(removed, d); }
                if d == keep { keep = -1; } else { block_remove_predecessor(d, bb, false); }
            }
            inst_erase_from_parent(t);
            if delete_dead_conds { cu_recursively_delete_dead(addr); }
            if cu_ba_use_empty(ba) { cu_destroy_block_address(ba); }
            if keep >= 0 {
                inst_erase_from_parent(block_terminator(bb));
                block_append_inst(bb, create_inst(OP_UNREACHABLE, T_VOID, []));
            }
            if cu_dtu {
                var ups: DTUpdate[>..<] = [];
                for r in removed { cu_upd(ups, DT_DELETE, bb, r); }
                dtu_apply_updates(ups);
            }
            return true;
        }
    }
    return false;
}

fn cu_ba_use_empty(ba: i32) -> bool { vals[ba].first_use < 0 }

// SwitchInst::defaultDestUnreachable: the default block starts with unreachable (getFirstNonPHIOrDbg)
fn cu_default_dest_unreachable(si: i32) -> bool {
    let f = first_non_phi(sw_default(si));
    return f >= 0 && iop(f) == OP_UNREACHABLE;
}

// Value::stripPointerCasts
fn cu_strip_pointer_casts(v0: i32) -> i32 {
    var v = v0;
    loop {
        let o = opcode_of(v);
        if o == OP_BITCAST || o == OP_ADDRSPACECAST { v = op(v, 0); continue; }
        if o == OP_GEP {
            var allz = true;
            for k in 1..nops(v) { let x = op(v, k); if !(is_constant(x) && is_null_value(x)) { allz = false; } }
            if allz { v = op(v, 0); continue; }
        }
        return v;
    }
}

// IRBuilder<> (ConstantFolder) CreateICmp(P, L, R, Name) before `before` with its debug location.
fn cu_build_icmp_before(p: i64, l: i32, r: i32, name: const u8[:], before: i32) -> i32 {
    if is_constant(l) && is_constant(r) {
        let f = cf_fold_icmp_const(p, l, r);
        if f >= 0 { return f; }
    }
    let c = create_inst(OP_ICMP, cmp_result_ty(vals[l].ty), [l, r]);
    insts[inst_of(c)].pred = p as u8;
    inst_insert_before(c, before);
    if name.len > 0 { set_name(c, name); }
    let dl = inst_get_md(before, MDK_DBG);
    if dl >= 0 { inst_set_md(c, MDK_DBG, dl); }
    return c;
}
fn cf_fold_icmp_const(p: i64, l: i32, r: i32) -> i32 { cf_compare(p, l, r) }

// ---------------------------------------------------------------------------------------------
// EliminateDuplicatePHINodes(BB)

fn cu_eliminate_duplicate_phis(bb: i32) -> bool {
    var to_remove: i32[>..<] = [];
    var changed = false;
    var i = block_first(bb);
    while i >= 0 && iop(i) == OP_PHI {
        let pn = i;
        i = inst_next(i);
        var j = i;
        var restarted = false;
        while j >= 0 && iop(j) == OP_PHI {
            let dup = j;
            j = inst_next(j);
            if position(to_remove, dup) >= 0 { continue; }
            if !cu_identical_when_defined(dup, pn, false) { continue; }
            rauw(dup, pn);
            to_remove.push(dup);
            changed = true;
            restarted = true;
            break;
        }
        if restarted { i = block_first(bb); }
    }
    for p in to_remove { inst_erase_from_parent(p); }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// TryToSimplifyUncondBranchFromEmptyBlock(BB, DTU)

var cu_max_phi_entries_increase: i64 = 1000;

fn cu_can_merge_values(a: i32, b: i32) -> bool { a == b || is_undef_or_poison(a) || is_undef_or_poison(b) }

// CanPropagatePredecessorsForPHIs
fn cu_can_propagate_preds_for_phis(bb: i32, succ: i32, bbpreds: const i32[:]) -> bool {
    if single_pred(succ) >= 0 { return true; }
    var i = block_first(succ);
    while i >= 0 && iop(i) == OP_PHI {
        let pn = i;
        i = inst_next(i);
        let bv = phi_value_for_block(pn, bb);
        if is_inst(bv) && iop(bv) == OP_PHI && inst_parent(bv) == bb {
            for k in nops(pn) {
                let ib = phi_block(pn, k);
                if position(bbpreds, ib) >= 0 && !cu_can_merge_values(phi_value_for_block(bv, ib), phi_value(pn, k)) { return false; }
            }
        } else {
            for k in nops(pn) {
                let ib = phi_block(pn, k);
                if position(bbpreds, ib) >= 0 && !cu_can_merge_values(bv, phi_value(pn, k)) { return false; }
            }
        }
    }
    return true;
}

// CanRedirectPredsOfEmptyBBToSucc; returns (ok, CommonPred)
fn cu_can_redirect_preds(bb: i32, succ: i32, bbpreds: const i32[:]) -> bool, i32 {
    if !cu_has_phis(bb) || !cu_has_phis(succ) { return false, -1; }
    if !cu_has_n_preds_or_more(bb, 2) { return false, -1; }
    for p in bbpreds { if iop(block_terminator(p)) == OP_INDIRECTBR { return false, -1; } }
    var common: i32 = -1;
    var ok = true;
    each_pred(succ) { sp =>
        if ok && position(bbpreds, sp) >= 0 {
            if common >= 0 { ok = false; } else { common = sp; }
        }
    };
    if !ok { return false, common; }
    return true, common;
}

// introduceTooManyPhiEntries
fn cu_too_many_phi_entries(bb: i32, succ: i32) -> bool {
    if cu_has_n_preds(bb, 1) { return false; }
    let npreds = pred_count(bb);
    var nchanged: i64 = 0;
    var i = block_first(succ);
    while i >= 0 && iop(i) == OP_PHI {
        let iv = phi_value_for_block(i, bb);
        i = inst_next(i);
        if is_inst(iv) && iop(iv) == OP_PHI && inst_parent(iv) == bb { continue; }
        nchanged++;
    }
    return (npreds - 1) * nchanged > cu_max_phi_entries_increase;
}

// IncomingValueMap: SmallDenseMap<BasicBlock*, Value*> as parallel lists; -1 value = nullptr
struct CuIV { bb: i32, v: i32 }

fn cu_ivm_find(m: CuIV[>..<]&, bb: i32) -> i64 {
    for k in m.len { if m[k].bb == bb { return k; } }
    return -1;
}

// selectIncomingValueForBlock
fn cu_select_incoming(old: i32, bb: i32, m: CuIV[>..<]&) -> i32 {
    let k = cu_ivm_find(m, bb);
    if !is_undef_or_poison(old) {
        if k >= 0 { m[k].v = old; } else { m.push(CuIV { bb: bb, v: old }); }
        return old;
    }
    if k >= 0 && m[k].v >= 0 { return m[k].v; }
    return old;
}

// gatherIncomingValuesToPhi
fn cu_gather_incoming(pn: i32, bbpreds: const i32[:], m: CuIV[>..<]&) {
    for p in bbpreds {
        let k = cu_ivm_find(m, p);
        if k >= 0 { m[k].v = -1; } else { m.push(CuIV { bb: p, v: -1 }); }
    }
    for k in nops(pn) {
        let v = phi_value(pn, k);
        if is_undef_or_poison(v) { continue; }
        let j = cu_ivm_find(m, phi_block(pn, k));
        if j >= 0 { m[j].v = v; }
    }
}

// replaceUndefValuesInPhi
fn cu_replace_undef_in_phi(pn: i32, m: CuIV[>..<]&) {
    var true_undef: i64[>..<] = [];
    for k in nops(pn) {
        let v = phi_value(pn, k);
        if !is_undef_or_poison(v) { continue; }
        let j = cu_ivm_find(m, phi_block(pn, k));
        if j < 0 { continue; }
        if m[j].v < 0 { true_undef.push(k); continue; }
        set_op(pn, k, m[j].v);
    }
    var npoison = 0;
    for k in true_undef { if is_poison(phi_value(pn, k)) { npoison++; } }
    if npoison != 0 && npoison != true_undef.len {
        for k in true_undef { set_op(pn, k, c_undef(vals[pn].ty)); }
    }
}

// redirectValuesFromPredecessorsToPhi
fn cu_redirect_values_to_phi(bb: i32, bbpreds: const i32[:], pn: i32, common: i32) {
    let old = phi_remove_incoming_block(pn, bb, false);
    var m: CuIV[>..<] = [];
    cu_gather_incoming(pn, bbpreds, m);
    if is_inst(old) && iop(old) == OP_PHI && inst_parent(old) == bb {
        for k in nops(old) {
            let pb = phi_block(old, k);
            if pb == common { continue; }
            let sel = cu_select_incoming(phi_value(old, k), pb, m);
            phi_add_incoming(pn, sel, pb);
        }
        if common >= 0 { phi_add_incoming(pn, phi_value_for_block(old, common), bb); }
    } else {
        for pb in bbpreds {
            if pb == common { continue; }
            let sel = cu_select_incoming(old, pb, m);
            phi_add_incoming(pn, sel, pb);
        }
        if common >= 0 { phi_add_incoming(pn, old, bb); }
    }
    cu_replace_undef_in_phi(pn, m);
}

// Instruction::hasNonDebugLocLoopMetadata
fn cu_has_non_debug_loc_loop_md(t: i32) -> bool {
    let md = inst_get_md(t, MDK_LOOP_CU);
    if md < 0 { return false; }
    for k in 1..(mds[md].nops as i64) {
        let o = md_op(md, k);
        if !cu_is_dilocation(o) { return true; }
    }
    return false;
}

fn cu_try_simplify_uncond_branch_from_empty_block(bb: i32) -> bool {
    let succ = op(block_terminator(bb), 0);
    if bb == succ { return false; }
    var bbpreds: i32[>..<] = [];     // SmallPtrSet: membership only
    each_pred(bb) { p => cu_push_unique(bbpreds, p); };
    let killable = cu_can_propagate_preds_for_phis(bb, succ, bbpreds);
    var common: i32 = -1;
    var mergeable = killable;
    if !killable {
        let ok, c = cu_can_redirect_preds(bb, succ, bbpreds);
        mergeable = ok;
        common = c;
    }
    if (!killable && !mergeable) || cu_too_many_phi_entries(bb, succ) { return false; }
    if single_pred(succ) < 0 {
        var i = block_first(bb);
        while i >= 0 && iop(i) == OP_PHI {
            var u = first_use(i);
            while u >= 0 {
                let us = uses[u].user;
                if !(is_inst(us) && iop(us) == OP_PHI) { return false; }
                if use_aux[u] != bb { return false; }
                u = use_next(u);
            }
            i = inst_next(i);
        }
    }
    let ti = block_terminator(bb);
    if ti >= 0 && cu_has_non_debug_loc_loop_md(ti) {
        var bad = false;
        each_pred(bb) { p => let pt = block_terminator(p); if pt >= 0 && cu_has_non_debug_loc_loop_md(pt) { bad = true; } };
        if bad { return false; }
    }
    var ups: DTUpdate[>..<] = [];
    if cu_dtu {
        var seen: i32[>..<] = [];
        var succ_preds: i32[>..<] = [];
        each_pred(succ) { p => succ_preds.push(p); };
        var pb: i32[>..<] = [];
        cu_preds(bb, pb);
        for p in pb { if position(succ_preds, p) < 0 && cu_push_unique(seen, p) { cu_upd(ups, DT_INSERT, p, succ); } }
        seen.clear();
        for p in pb { if cu_push_unique(seen, p) && p != common { cu_upd(ups, DT_DELETE, p, bb); } }
        if killable { cu_upd(ups, DT_DELETE, bb, succ); }
    }
    if cu_has_phis(succ) {
        var pv: i32[>..<] = [];
        cu_preds(bb, pv);
        var i = block_first(succ);
        while i >= 0 && iop(i) == OP_PHI {
            let pn = i;
            i = inst_next(i);
            cu_redirect_values_to_phi(bb, pv, pn, common);
        }
    }
    if single_pred(succ) >= 0 {
        inst_erase_from_parent(block_terminator(bb));
        let pos = first_non_phi(succ);
        cu_splice_before(pos, block_first(bb), -1);
    } else {
        loop {
            let pn = block_first(bb);
            if pn < 0 || iop(pn) != OP_PHI { break; }
            inst_erase_from_parent(pn);
        }
    }
    let ti2 = block_terminator(bb);
    if ti2 >= 0 && cu_has_non_debug_loc_loop_md(ti2) {
        let lmd = inst_get_md(ti2, MDK_LOOP_CU);
        each_pred(bb) { p => inst_set_md(block_terminator(p), MDK_LOOP_CU, lmd); };
    }
    if killable {
        cu_block_rauw(bb, succ);
        if vals[succ].name < 0 { cu_take_name(succ, bb); }
        let t3 = block_terminator(bb);
        if t3 >= 0 { inst_erase_from_parent(t3); }
        block_append_inst(bb, create_inst(OP_UNREACHABLE, T_VOID, []));
    } else if mergeable {
        var u = first_use(bb);
        while u >= 0 {
            let nu = use_next(u);
            let us = uses[u].user;
            if is_inst(us) {
                let ub = inst_parent(us);
                if ub != common && position(bbpreds, ub) >= 0 { use_set(u, succ); }
            }
            u = nu;
        }
    }
    cu_apply(ups);
    if killable { cu_delete_dead_block(bb); }
    return true;
}

// ---------------------------------------------------------------------------------------------
// changeToUnreachable(I, PreserveLCSSA = false, DTU), changeToCall, removeUnwindEdge

fn cu_change_to_unreachable(iv: i32) -> i64 {
    let bb = inst_parent(iv);
    var uniq: i32[>..<] = [];
    var succs: i32[>..<] = [];
    cu_succs(bb, succs);
    for s in succs {
        block_remove_predecessor(s, bb, false);
        if cu_dtu { cu_push_unique(uniq, s); }
    }
    let ui = create_inst(OP_UNREACHABLE, T_VOID, []);
    inst_insert_before(ui, iv);
    let dl = inst_get_md(iv, MDK_DBG);
    if dl >= 0 { inst_set_md(ui, MDK_DBG, dl); }
    var n: i64 = 0;
    var i = iv;
    while i >= 0 {
        let ni = inst_next(i);
        if vals[i].first_use >= 0 { rauw(i, c_poison(vals[i].ty)); }
        inst_erase_from_parent(i);
        n++;
        i = ni;
    }
    if cu_dtu {
        var ups: DTUpdate[>..<] = [];
        for s in uniq { cu_upd(ups, DT_DELETE, bb, s); }
        dtu_apply_updates(ups);
    }
    return n;
}

// createCallMatchingInvoke + changeToCall(II, DTU)
fn cu_change_to_call(ii: i32) -> i32 {
    let bb = inst_parent(ii);
    let nd = invoke_normal_dest(ii);
    let ud = invoke_unwind_dest(ii);
    // operands: args..., bundle operands..., callee (the invoke has normal, unwind before the callee)
    let n = nops(ii);
    var opsv: i32[>..<] = [];
    for k in n - 3 { opsv.push(op(ii, k)); }
    opsv.push(op(ii, n - 1));
    let c = create_inst(OP_CALL, vals[ii].ty, opsv);
    let ci = inst_of(c);
    let src = insts[inst_of(ii)];
    insts[ci].cc = src.cc;
    insts[ci].attrs = src.attrs;
    insts[ci].ty2 = src.ty2;
    insts[ci].fmf = src.fmf;
    // operand bundles: same layout (they precede the callee)
    cu_copy_bundles(c, ii);
    // copyMetadata(*II)
    for k in src.nmd { inst_set_md(c, md_att[src.md + 2 * k], md_att[src.md + 2 * k + 1]); }
    let m = pd_prof(c);
    if m >= 0 {
        // extractProfTotalWeight
        if mds[m].nops > 0 {
            let s0 = md_op(m, 0);
            if pd_md_string_is(s0, "branch_weights") {
                var tot: u64 = 0;
                for k in pd_offset(m)..(mds[m].nops as i64) { tot += pd_md_weight(m, k); }
                if (tot & 0xFFFFFFFF) != tot { inst_erase_md(c, MDK_PROF); }
                else { let one: u64[1] = [tot]; inst_set_md(c, MDK_PROF, pd_create(one, false)); }
            } else if pd_md_string_is(s0, "VP") && mds[m].nops > 3 {
                cu_not_ported("value-profile metadata on an invoke turned into a call");
            }
        }
    }
    cu_take_name(c, ii);
    inst_insert_before(c, ii);
    rauw(ii, c);
    let br = create_inst(OP_BR, T_VOID, [nd]);
    inst_insert_before(br, ii);
    let dl = inst_get_md(ii, MDK_DBG);
    if dl >= 0 { inst_set_md(br, MDK_DBG, dl); }
    block_remove_predecessor(ud, bb, false);
    inst_erase_from_parent(ii);
    cu_apply1(DT_DELETE, bb, ud);
    return c;
}

// Copy the operand-bundle descriptor of an invoke to a call with the same argument/bundle operand layout.
fn cu_copy_bundles(c: i32, ii: i32) {
    let nb = cb_nbundles(ii);
    if nb == 0 { insts[inst_of(c)].aux = 0; insts[inst_of(c)].naux = 0; return; }
    var pairs: i32[>..<] = [];
    for k in nb {
        pairs.push(cb_bundle_tag(ii, k));
        pairs.push(cb_bundle_count(ii, k) as i32);
    }
    cb_set_bundles(c, cb_bundle_begin(ii, 0), pairs, 0);
}

// removeUnwindEdge(BB, DTU)
fn cu_remove_unwind_edge(bb: i32) -> i32 {
    let ti = block_terminator(bb);
    if iop(ti) == OP_INVOKE { return cu_change_to_call(ti); }
    var nt: i32 = -1;
    var ud: i32 = -1;
    if iop(ti) == OP_CLEANUPRET {
        nt = create_inst(OP_CLEANUPRET, T_VOID, [op(ti, 0)]);
        ud = if nops(ti) >= 2 { op(ti, 1) } else { -1 };
    } else if iop(ti) == OP_CATCHSWITCH {
        let has_ud = (insts[inst_of(ti)].bits & 1) != 0;
        let first = if has_ud { 2 } else { 1 };
        ud = if has_ud { op(ti, 1) } else { -1 };
        var opsv: i32[>..<] = [];
        opsv.push(op(ti, 0));
        for k in first..nops(ti) { opsv.push(op(ti, k)); }
        nt = create_inst(OP_CATCHSWITCH, vals[ti].ty, opsv);
    } else {
        fatal("internal: removeUnwindEdge: could not find unwind successor");
    }
    inst_insert_before(nt, ti);
    cu_take_name(nt, ti);
    let dl = inst_get_md(ti, MDK_DBG);
    if dl >= 0 { inst_set_md(nt, MDK_DBG, dl); }
    block_remove_predecessor(ud, bb, false);
    if vals[ti].first_use >= 0 { rauw(ti, nt); }
    inst_erase_from_parent(ti);
    cu_apply1(DT_DELETE, bb, ud);
    return nt;
}

// CatchSwitchInst::removeHandler(HI): later handlers move up one slot
fn cu_catchswitch_remove_handler(cs: i32, opidx: i64) {
    let n = nops(cs);
    var k = opidx;
    while k < n - 1 { set_op(cs, k, op(cs, k + 1)); k++; }
    set_op(cs, n - 1, -1);
    vals[cs].nops = (n - 1) as i32;
}

// ---------------------------------------------------------------------------------------------
// markAliveBlocks / removeUnreachableBlocks

// classifyEHPersonality for canSimplifyInvokeNoUnwind: true if invokes of nounwind callees may become calls.
fn cu_can_simplify_invoke_no_unwind(fv: i32) -> bool {
    let p = cu_personality(fv);
    if p < 0 { return true; }
    let pf = cu_strip_pointer_casts(p);
    if !is_func(pf) { return true; }
    let nm = val_name(pf);
    if nm == "_except_handler3" || nm == "_except_handler4" || nm == "__C_specific_handler" { return false; }
    if nm == "__CxxFrameHandler3" { cu_not_ported("the eh-asynch module flag check for MSVC C++ personalities"); }
    return true;
}
fn cu_personality(fv: i32) -> i32 {
    if globs[glob_of(fv)].has_personality == 0 { return -1; }
    return op(fv, 0);
}

fn cu_null_ptr_defined(fv: i32, as_: i64) -> bool { null_pointer_is_defined(fv, as_) }

fn cu_mark_alive_blocks(fv: i32, reach: bool[>..<]&) -> bool {
    var wl: i32[>..<] = [];
    let entry = func_entry(fv);
    wl.push(entry);
    cu_reach_set(reach, entry);
    var changed = false;
    loop {
        if wl.len == 0 { break; }
        let bb = wl.pop();
        var i = block_first(bb);
        while i >= 0 {
            let ni = inst_next(i);
            if iop(i) == OP_CALL {
                let callee = cb_callee(i);
                var brk = false;
                if is_func(callee) {
                    let id = func_iid(callee);
                    if id == IID_assume {
                        let a = cb_arg(i, 0);
                        if m_zero(a) || m_undef(a) {
                            cu_change_to_unreachable(i);
                            changed = true;
                            break;
                        }
                    } else if id == IID_experimental_guard {
                        if m_zero(cb_arg(i, 0)) {
                            let nx = inst_next(i);
                            if iop(nx) != OP_UNREACHABLE {
                                cu_change_to_unreachable(nx);
                                changed = true;
                                break;
                            }
                        }
                    }
                } else if (vals[callee].kind == VK_CNULL && !cu_null_ptr_defined(fv, ptr_as(vals[callee].ty))) || is_undef_or_poison(callee) {
                    cu_change_to_unreachable(i);
                    changed = true;
                    break;
                }
                if call_has_fn_attr(i, AK_NoReturn) && insts[inst_of(i)].pred != 2 {
                    let nx = inst_next(i);
                    if iop(nx) != OP_UNREACHABLE {
                        cu_change_to_unreachable(nx);
                        changed = true;
                    }
                    brk = true;
                }
                if brk { break; }
            } else if iop(i) == OP_STORE {
                if !inst_is_volatile(i) {
                    let p = op(i, 1);
                    if is_undef_or_poison(p) || (vals[p].kind == VK_CNULL && !cu_null_ptr_defined(fv, ptr_as(vals[p].ty))) {
                        cu_change_to_unreachable(i);
                        changed = true;
                        break;
                    }
                }
            }
            i = ni;
        }
        let t = block_terminator(bb);
        if iop(t) == OP_INVOKE {
            let callee = cb_callee(t);
            if (vals[callee].kind == VK_CNULL && !cu_null_ptr_defined(fv, 0)) || is_undef_or_poison(callee) {
                cu_change_to_unreachable(t);
                changed = true;
            } else {
                let ii = t;
                if call_has_fn_attr(ii, AK_NoReturn) {
                    let nd = invoke_normal_dest(ii);
                    let f0 = block_first(nd);
                    if !(f0 >= 0 && iop(f0) == OP_UNREACHABLE) {
                        block_remove_predecessor(nd, bb, false);
                        var nm: u8[>..] = [];
                        nm.append(val_name(nd));
                        nm.append(".unreachable");
                        let unb = create_block_before(fv, nd, nm);
                        block_append_inst(unb, create_inst(OP_UNREACHABLE, T_VOID, []));
                        set_op(ii, nops(ii) - 3, unb);
                        if cu_dtu {
                            var ups: DTUpdate[>..<] = [];
                            cu_upd(ups, DT_DELETE, bb, nd);
                            cu_upd(ups, DT_INSERT, bb, unb);
                            dtu_apply_updates(ups);
                        }
                        changed = true;
                    }
                }
                if call_has_fn_attr(ii, AK_NoUnwind) && cu_can_simplify_invoke_no_unwind(fv) {
                    if vals[ii].first_use < 0 && !inst_may_have_side_effects(ii) {
                        let nd = invoke_normal_dest(ii);
                        let ud = invoke_unwind_dest(ii);
                        let br = create_inst(OP_BR, T_VOID, [nd]);
                        inst_insert_before(br, ii);
                        block_remove_predecessor(ud, bb, false);
                        inst_erase_from_parent(ii);
                        cu_apply1(DT_DELETE, bb, ud);
                    } else {
                        cu_change_to_call(ii);
                    }
                    changed = true;
                }
            }
        } else if iop(t) == OP_CATCHSWITCH {
            // Remove catchpads which cannot be reached (identical catchpads).
            let cs = t;
            let first = if (insts[inst_of(cs)].bits & 1) != 0 { 2 } else { 1 };
            var seen: i32[>..<] = [];
            var succ_b: i32[>..<] = [];
            var succ_n: i64[>..<] = [];
            var k = first;
            while k < nops(cs) {
                let hb = op(cs, k);
                if cu_dtu {
                    let j = position(succ_b, hb);
                    if j < 0 { succ_b.push(hb); succ_n.push(1); } else { succ_n[j] += 1; }
                }
                let cp = first_non_phi(hb);
                var dup = false;
                for x in seen { if cu_identical(x, cp) { dup = true; } }
                if dup {
                    if cu_dtu { let j = position(succ_b, hb); succ_n[j] -= 1; }
                    cu_catchswitch_remove_handler(cs, k);
                    changed = true;
                    continue;
                }
                seen.push(cp);
                k++;
            }
            if cu_dtu {
                var ups: DTUpdate[>..<] = [];
                for j in succ_b.len { if succ_n[j] == 0 { cu_upd(ups, DT_DELETE, bb, succ_b[j]); } }
                dtu_apply_updates(ups);
            }
        }
        if cu_constant_fold_terminator(bb, true) { changed = true; }
        var succs: i32[>..<] = [];
        cu_succs(bb, succs);
        for s in succs {
            if !cu_reach_has(reach, s) { wl.push(s); cu_reach_set(reach, s); }
        }
    }
    return changed;
}

fn cu_reach_set(reach: bool[>..<]&, bb: i32) {
    let n = block_number(bb) as i64;
    while reach.len <= n { reach.push(false); }
    reach[n] = true;
}
fn cu_reach_has(reach: bool[>..<]&, bb: i32) -> bool {
    let n = block_number(bb) as i64;
    return n < reach.len && reach[n];
}

// removeUnreachableBlocks(F, DTU)
fn cu_remove_unreachable_blocks(fv: i32) -> bool {
    var reach: bool[>..<] = [];
    var changed = cu_mark_alive_blocks(fv, reach);
    var to_remove: i32[>..<] = [];
    var b = func_first_block(fv);
    while b >= 0 {
        if !cu_reach_has(reach, b) && !(cu_dtu && dtu_is_bb_pending_deletion(b)) { to_remove.push(b); }
        b = block_next(b);
    }
    if to_remove.len == 0 { return changed; }
    cu_delete_dead_blocks(to_remove, false);
    return true;
}

// ---------------------------------------------------------------------------------------------
// GetIfCondition(BB, IfTrue, IfFalse): returns (branch, IfTrue, IfFalse); branch = -1 if none

fn cu_get_if_condition(bb: i32) -> i32, i32, i32 {
    let some = block_first(bb);
    var p1: i32 = -1;
    var p2: i32 = -1;
    if some >= 0 && iop(some) == OP_PHI {
        if nops(some) != 2 { return -1, -1, -1; }
        p1 = phi_block(some, 0);
        p2 = phi_block(some, 1);
    } else {
        var ps: i32[>..<] = [];
        cu_preds(bb, ps);
        if ps.len != 2 { return -1, -1, -1; }
        p1 = ps[0];
        p2 = ps[1];
    }
    var t1 = block_terminator(p1);
    var t2 = block_terminator(p2);
    if iop(t2) == OP_CONDBR {
        if iop(t1) == OP_CONDBR { return -1, -1, -1; }
        let tp = p1; p1 = p2; p2 = tp;
        let tt = t1; t1 = t2; t2 = tt;
    }
    if iop(t2) != OP_BR { return -1, -1, -1; }
    if iop(t1) == OP_CONDBR {
        if single_pred(p2) < 0 { return -1, -1, -1; }
        if term_succ(t1, 0) == bb && term_succ(t1, 1) == p2 { return t1, p1, p2; }
        if term_succ(t1, 0) == p2 && term_succ(t1, 1) == bb { return t1, p2, p1; }
        return -1, -1, -1;
    }
    if iop(t1) != OP_BR { return -1, -1, -1; }
    let cp = single_pred(p1);
    if cp < 0 || cp != single_pred(p2) { return -1, -1, -1; }
    let bi = block_terminator(cp);
    if iop(bi) != OP_CONDBR { return -1, -1, -1; }
    if term_succ(bi, 0) == p1 { return bi, p1, p2; }
    return bi, p2, p1;
}

// IsBlockFollowedByDeoptOrUnreachable
fn cu_followed_by_deopt_or_unreachable(bb0: i32) -> bool {
    var visited: i32[>..<] = [];
    var bb = bb0;
    var depth = 0;
    while bb >= 0 && depth < 8 && cu_push_unique(visited, bb) {
        depth++;
        let t = block_terminator(bb);
        if iop(t) == OP_UNREACHABLE { return true; }
        if cu_terminating_deoptimize_call(bb) >= 0 { return true; }
        bb = cu_unique_succ(bb);
    }
    return false;
}

// BasicBlock::getTerminatingDeoptimizeCall
fn cu_terminating_deoptimize_call(bb: i32) -> i32 {
    let t = block_terminator(bb);
    if t < 0 || iop(t) != OP_RET || t == block_first(bb) { return -1; }
    let p = inst_prev(t);
    if p < 0 || iop(p) != OP_CALL { return -1; }
    let f = called_function(p);
    if f >= 0 && func_iid(f) == IID_experimental_deoptimize { return p; }
    return -1;
}

// BasicBlock::getTerminatingMustTailCall
fn cu_terminating_musttail_call(bb: i32) -> i32 {
    let t = block_terminator(bb);
    if t < 0 || iop(t) != OP_RET || t == block_first(bb) { return -1; }
    let p = inst_prev(t);
    if p < 0 { return -1; }
    if nops(t) > 0 && op(t, 0) != p { return -1; }
    if iop(p) == OP_CALL && insts[inst_of(p)].pred == 2 { return p; }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// hoistAllInstructionsInto(DomBlock, InsertPt, BB)

fn cu_hoist_all_instructions_into(dom: i32, ins_pt: i32, bb: i32) {
    var i = block_first(bb);
    while i >= 0 {
        let ni = inst_next(i);
        cu_drop_ub_implying_attrs_and_metadata(i);
        if inst_first_dbg(i) >= 0 || cu_used_by_debug_record(i) { cu_not_ported("hoistAllInstructionsInto with debug records"); }
        if cu_is_debug_or_pseudo(i) { inst_erase_from_parent(i); i = ni; continue; }
        let dl = inst_get_md(ins_pt, MDK_DBG);
        if dl >= 0 { inst_set_md(i, MDK_DBG, dl); } else { inst_erase_md(i, MDK_DBG); }
        i = ni;
    }
    let t = block_terminator(bb);
    cu_splice_before(ins_pt, block_first(bb), t);
}

fn cu_used_by_debug_record(i: i32) -> bool { dbgrecs.len > 0 && dbg_records_use_value(i) }
fn cu_is_debug_or_pseudo(i: i32) -> bool {
    let id = inst_iid(i);
    return id == IID_pseudoprobe || id == IID_dbg_value || id == IID_dbg_declare || id == IID_dbg_label || id == IID_dbg_assign;
}

// Instruction::dropUBImplyingAttrsAndMetadata(Keep): keep !dbg, DIAssignID and the known kinds.
fn cu_drop_ub_implying_attrs_and_metadata(i: i32) {
    let keep: const u8[:][] = ["annotation", "range", "nonnull", "align", "fpmath", "prof", "mem.cache_hint", "nofpclass", "DIAssignID"];
    var ids: i32[>..<] = [];
    for k in keep { ids.push(md_kind_id(k)); }
    cu_drop_ub_implying_attrs_and_unknown_md(i, ids);
}
fn cu_drop_ub_implying_attrs_and_unknown_md(i: i32, keep_ids: const i32[:]) {
    let ii = inst_of(i);
    let at = insts[ii].md;
    var w: i32 = 0;
    let n = insts[ii].nmd;
    for k in n {
        let kind = md_att[at + 2 * k];
        if kind == MDK_DBG || position(keep_ids, kind) >= 0 {
            md_att[at + 2 * w] = kind;
            md_att[at + 2 * w + 1] = md_att[at + 2 * k + 1];
            w++;
        }
    }
    insts[ii].nmd = w;
    if !is_callbase(i) { return; }
    let al = insts[ii].attrs;
    if al == 0 || alists[al].n == 0 { return; }
    let kinds: i64[3] = [AK_NoUndef, AK_Dereferenceable, AK_DereferenceableOrNull];
    var sets: i32[>..<] = [];
    let na = alists[al].n as i64;
    for k in na {
        let st = alist_runs[alists[al].at + k];
        sets.push(if k == 0 { st } else { aset_without(st, kinds) });
    }
    insts[ii].attrs = alist_get(sets);
}

// ---------------------------------------------------------------------------------------------
// SplitBlockPredecessors(BB, Preds, Suffix, DTU)

fn cu_split_block_predecessors(bb: i32, preds: const i32[:], suffix: const u8[:]) -> i32 {
    let fnp = first_non_phi(bb);
    if fnp >= 0 && iop(fnp) == OP_LANDINGPAD && cu_dtu { cu_not_ported("SplitLandingPadPredecessors with a DomTreeUpdater"); }
    let was_entry = cu_is_entry(bb);
    let nb = split_block_predecessors(bb, preds, suffix, false, false, false);
    if nb < 0 { return -1; }
    if cu_dtu {
        if was_entry && dtu_dt { dtu_recalculate(); }
        else {
            var ups: DTUpdate[>..<] = [];
            var uniq: i32[>..<] = [];
            cu_upd(ups, DT_INSERT, nb, bb);
            for p in preds {
                if cu_push_unique(uniq, p) { cu_upd(ups, DT_INSERT, p, nb); cu_upd(ups, DT_DELETE, p, bb); }
            }
            dtu_apply_updates(ups);
        }
    }
    return nb;
}

// ---------------------------------------------------------------------------------------------
// FindFunctionBackedges(F, Result): (from, to) pairs into out (flattened), in LLVM's DFS order

fn cu_find_function_backedges(fv: i32, out: i32[>..<]&) {
    out.clear();
    let entry = func_entry(fv);
    if block_nsucc(entry) == 0 { return; }
    var visited: bool[>..<] = [];
    var inpath: bool[>..<] = [];
    var stk_b: i32[>..<] = [];
    var stk_k: i64[>..<] = [];
    fn mark(xs: bool[>..<]&, b: i32, v: bool) {
        let n = block_number(b) as i64;
        while xs.len <= n { xs.push(false); }
        xs[n] = v;
    }
    fn has(xs: bool[>..<]&, b: i32) -> bool { let n = block_number(b) as i64; return n < xs.len && xs[n]; }
    mark(visited, entry, true);
    stk_b.push(entry);
    stk_k.push(0);
    mark(inpath, entry, true);
    loop {
        if stk_b.len == 0 { break; }
        let top = stk_b.len - 1;
        let parent = stk_b[top];
        let k = stk_k[top];
        var found_new = false;
        let n = block_nsucc(parent);
        var kk = k;
        while kk < n {
            let s = block_succ(parent, kk);
            kk++;
            if !has(visited, s) {
                mark(visited, s, true);
                stk_k[top] = kk;
                stk_b.push(s);
                stk_k.push(0);
                mark(inpath, s, true);
                found_new = true;
                break;
            } else if has(inpath, s) {
                out.push(parent);
                out.push(s);
            }
        }
        if !found_new {
            mark(inpath, stk_b[top], false);
            stk_b.pop();
            stk_k.pop();
        }
    }
}

// canReplaceOperandWithVariable(I, OpIdx) (Local.cpp)
fn cu_can_replace_operand_with_variable(i: i32, k: i64) -> bool {
    let v = op(i, k);
    let tk = ty_kind(vals[v].ty);
    if tk == TK_METADATA || tk == TK_TOKEN { return false; }
    if tk == TK_TARGETEXT { cu_not_ported("canReplaceOperandWithVariable on target extension types"); }
    // swifterror pointers
    if is_arg(v) && aset_has(alist_param(func_attrs(args_parent[vals[v].sub]), args_no[vals[v].sub] as i64), AK_SwiftError) { return false; }
    if is_inst(v) && iop(v) == OP_ALLOCA && (insts[inst_of(v)].bits & 2) != 0 { return false; }
    if inst_is_lifetime_start_or_end(i) { return false; }
    if !is_constant(v) && !is_inline_asm_v(v) { return true; }
    let o = iop(i);
    if o == OP_CALL || o == OP_INVOKE {
        if cb_is_inline_asm_cu(i) { return false; }
        let na = cb_nargs(i);
        if k >= na && k < na + cb_bundle_ops_cu(i) { return false; }
        if k < na {
            let id = inst_iid(i);
            if id != 0 && k >= ty_fn_nparams(insts[inst_of(i)].ty2) { return id == IID_experimental_stackmap; }
            if id == IID_gcroot { return false; }
            return !cb_param_has_immarg(i, k);
        }
        return inst_iid(i) == 0;
    }
    if o == OP_SHUFFLEVECTOR { return k != 2; }
    if o == OP_SWITCH || o == OP_EXTRACTVALUE { return k == 0; }
    if o == OP_INSERTVALUE { return k < 2; }
    if o == OP_ALLOCA { return !ml_is_static_alloca_cu(i); }
    if o == OP_GEP {
        if k == 0 { return true; }
        // gep_type_iterator: index j >= 2 is a struct index if the type it indexes is a struct
        var t = insts[inst_of(i)].ty2;
        for j in 2..(k + 1) {
            if ty_is_struct(t) { return false; }
            if j < k { t = cu_ty_index_type(t, op(i, j)); }
        }
        return true;
    }
    return true;
}
fn cb_is_inline_asm_cu(c: i32) -> bool { vals[cb_callee(c)].kind == VK_INLINEASM }
fn cb_bundle_ops_cu(c: i32) -> i64 { var n: i64 = 0; for k in cb_nbundles(c) { n += cb_bundle_count(c, k); } return n; }
fn ml_is_static_alloca_cu(a: i32) -> bool {
    if vals[op(a, 0)].kind != VK_CINT { return false; }
    let b = inst_parent(a);
    if func_entry(block_func(b)) != b { return false; }
    return (insts[inst_of(a)].bits & 1) == 0;
}
fn is_inline_asm_v(v: i32) -> bool { vals[v].kind == VK_INLINEASM }
fn cb_param_has_immarg(c: i32, k: i64) -> bool {
    let f = called_function(c);
    if f >= 0 && aset_has(alist_param(func_attrs(f), k), AK_ImmArg) { return true; }
    return aset_has(alist_param(insts[inst_of(c)].attrs, k), AK_ImmArg);
}
fn is_lifetime_or_statepoint(c: i32) -> bool {
    let id = inst_iid(c);
    return id == IID_lifetime_start || id == IID_lifetime_end || id == IID_experimental_gc_statepoint;
}
fn cu_ty_index_type(t: i32, ix: i32) -> i32 {
    if ty_is_struct(t) {
        var c = m_constant_int(ix);
        if c < 0 { c = m_apint(ix); }
        return ty_field(t, ci_val(c) as i64);
    }
    return types[t].a;
}

// InvertBranch(PBI, Builder): Builder inserts before PBI
fn cu_invert_branch(pbi: i32) {
    var nc = op(pbi, 0);
    let fu = vals[nc].first_use;
    if is_inst(nc) && (iop(nc) == OP_ICMP || iop(nc) == OP_FCMP) && fu >= 0 && uses[fu].next < 0 {
        insts[inst_of(nc)].pred = cmp_inverse_pred(inst_pred(nc)) as u8;
    } else {
        var nm: u8[>..] = [];
        nm.append(val_name(nc));
        nm.append(".not");
        nc = cu_create_not_before(nc, nm, pbi);
    }
    set_op(pbi, 0, nc);
    cu_swap_successors(pbi);
}

fn cmp_inverse_pred(p: i64) -> i64 {
    // CmpInst::getInversePredicate: FCMP 0..15 -> 15 - p; ICMP eq<->ne, ugt<->ule, uge<->ult, sgt<->sle, sge<->slt
    if p <= 15 { return 15 - p; }
    match p {
        32 => 33, 33 => 32, 34 => 37, 37 => 34, 35 => 36, 36 => 35,
        38 => 41, 41 => 38, 39 => 40, 40 => 39, _ => p,
    }
}

// IRBuilder CreateNot(V, Name) before `before` (ConstantFolder)
fn cu_create_not_before(v: i32, name: const u8[:], before: i32) -> i32 {
    let ones = c_all_ones(vals[v].ty);
    if is_constant(v) { return ce_binop(OP_XOR, v, ones, 0); }
    let x = create_inst(OP_XOR, vals[v].ty, [v, ones]);
    inst_insert_before(x, before);
    if name.len > 0 { set_name(x, name); }
    let dl = inst_get_md(before, MDK_DBG);
    if dl >= 0 { inst_set_md(x, MDK_DBG, dl); }
    return x;
}

// Function::renumberBlocks: numbers 0..n-1 in function order; NextBlockNum = n
fn cu_renumber_blocks(fv: i32) {
    var n: i32 = 0;
    var b = func_first_block(fv);
    while b >= 0 { block_nums[block_of(b)] = n; n++; b = block_next(b); }
    let g = glob_of(fv) as i64;
    while fn_next_bnum.len <= g { fn_next_bnum.push(0); }
    fn_next_bnum[g] = n;
}

// Use::swap(RHS): the two uses exchange their values and their positions in the values' use lists.
fn cu_use_swap(a: i32, b: i32) {
    let va = uses[a].val;
    let vb = uses[b].val;
    if va == vb { return; }
    let na = uses[a].next;
    let pa = uses[a].prev;
    let nb = uses[b].next;
    let pb = uses[b].prev;
    let la = va >= 0 && has_use_list(va);
    let lb = vb >= 0 && has_use_list(vb);
    uses[a].val = vb;
    uses[b].val = va;
    if lb {
        uses[a].next = nb;
        uses[a].prev = pb;
        if pb >= 0 { uses[pb].next = a; } else { vals[vb].first_use = a; }
        if nb >= 0 { uses[nb].prev = a; }
    } else { uses[a].next = -1; uses[a].prev = -1; }
    if la {
        uses[b].next = na;
        uses[b].prev = pa;
        if pa >= 0 { uses[pa].next = b; } else { vals[va].first_use = b; }
        if na >= 0 { uses[na].prev = b; }
    } else { uses[b].next = -1; uses[b].prev = -1; }
}
// CondBrInst::swapSuccessors (+ swapProfMetadata)
fn cu_swap_successors(bi: i32) {
    cu_use_swap(vals[bi].ops + 1, vals[bi].ops + 2);
    cu_swap_prof_metadata(bi);
}
// Instruction::swapProfMetadata
fn cu_swap_prof_metadata(bi: i32) {
    let m = pd_prof(bi);
    if pd_is_branch_weight_md(m) && mds[m].nops as i64 == 2 + pd_offset(m) {
        var ops: i32[>..<] = [];
        let f = pd_offset(m);
        for k in f { ops.push(md_op(m, k)); }
        ops.push(md_op(m, f + 1));
        ops.push(md_op(m, f));
        inst_set_md(bi, MDK_PROF, md_get(MK_TUPLE, -1, ops, false));
    }
}

fn cu_is_dilocation(m: i32) -> bool { m >= 0 && mds[m].kind == MK_DI && di_kind(m) == DIK_LOCATION }

// ---------------------------------------------------------------------------------------------
// combineMetadata(K, J, DoesKMove, AAOnly) (Local.cpp) and the MDNode merge helpers (Metadata.cpp)

fn cu_md_cint(m: i32, k: i64) -> i32 {
    let o = md_op(m, k);
    if o < 0 || mds[o].kind != MK_VALUE { fatal("internal: expected a ConstantAsMetadata operand"); }
    return mds[o].extra;
}

// getOrSelfReference(Ctx, Ops)
fn cu_get_or_self_reference(ops: const i32[:]) -> i32 {
    if ops.len > 0 {
        let n = ops[0];
        if n >= 0 && md_is_node(n) && mds[n].nops as i64 == ops.len && md_op(n, 0) == n {
            for k in 1..ops.len { if ops[k] != md_op(n, k) { return md_get(MK_TUPLE, -1, ops, false); } }
            return n;
        }
    }
    return md_get(MK_TUPLE, -1, ops, false);
}

// MDNode::intersect(A, B)
fn cu_md_intersect(a: i32, b: i32) -> i32 {
    if a < 0 || b < 0 { return -1; }
    var xs: i32[>..<] = [];
    for k in mds[a].nops {
        let o = md_op(a, k);
        if position(xs, o) >= 0 { continue; }
        var inb = false;
        for j in mds[b].nops { if md_op(b, j) == o { inb = true; } }
        if inb { xs.push(o); }
    }
    return cu_get_or_self_reference(xs);
}

// MDNode::getMostGenericAliasScope(A, B)
fn cu_scope_domain(n: i32) -> i32 { if mds[n].nops < 2 { -1 } else { md_op(n, 1) } }
fn cu_most_generic_alias_scope(a: i32, b: i32) -> i32 {
    if a < 0 || b < 0 { return -1; }
    var adom: i32[>..<] = [];
    var idom: i32[>..<] = [];
    var xs: i32[>..<] = [];
    for k in mds[a].nops {
        let o = md_op(a, k);
        if o >= 0 && md_is_node(o) { let d = cu_scope_domain(o); if d >= 0 { cu_push_unique(adom, d); } }
    }
    for k in mds[b].nops {
        let o = md_op(b, k);
        if o >= 0 && md_is_node(o) {
            let d = cu_scope_domain(o);
            if d >= 0 && position(adom, d) >= 0 { cu_push_unique(idom, d); cu_push_unique(xs, o); }
        }
    }
    for k in mds[a].nops {
        let o = md_op(a, k);
        if o >= 0 && md_is_node(o) {
            let d = cu_scope_domain(o);
            if d >= 0 && position(idom, d) >= 0 { cu_push_unique(xs, o); }
        }
    }
    if xs.len == 0 { return -1; }
    return cu_get_or_self_reference(xs);
}

// intersectAccessGroups(Inst1, Inst2)
fn cu_intersect_access_groups(i1: i32, i2: i32) -> i32 {
    let kind = md_kind_id("llvm.access.group");
    let m1a = inst_may_read_or_write_memory(i1);
    let m2a = inst_may_read_or_write_memory(i2);
    if !m1a && !m2a { return -1; }
    if !m1a { return inst_get_md(i2, kind); }
    if !m2a { return inst_get_md(i1, kind); }
    let m1 = inst_get_md(i1, kind);
    let m2 = inst_get_md(i2, kind);
    if m1 < 0 || m2 < 0 { return -1; }
    if m1 == m2 { return m1; }
    // the access groups: a node with no operands is one group, else a list of groups
    var s2: i32[>..<] = [];
    if mds[m2].nops == 0 { s2.push(m2); } else { for k in mds[m2].nops { s2.push(md_op(m2, k)); } }
    var inter: i32[>..<] = [];
    if mds[m1].nops == 0 { if position(s2, m1) >= 0 { inter.push(m1); } }
    else { for k in mds[m1].nops { let g = md_op(m1, k); if position(s2, g) >= 0 { inter.push(g); } } }
    if inter.len == 0 { return -1; }
    if inter.len == 1 { return inter[0]; }
    return md_get(MK_TUPLE, -1, inter, false);
}

// MDNode::getMostGenericFPMath
fn cu_most_generic_fpmath(a: i32, b: i32) -> i32 {
    if a < 0 || b < 0 { return -1; }
    if a == b { return a; }
    // the node with the smaller accuracy (APFloat operator<)
    let ca = mds[md_op(a, 0)].extra;
    let cb = mds[md_op(b, 0)].extra;
    let r = fp_compare(cfp_kind(ca), cint_lo(ca), cint_hi(ca), cint_lo(cb), cint_hi(cb));
    if vals[ca].ty != vals[cb].ty { cu_not_ported("MDNode::getMostGenericFPMath of differently typed accuracies"); }
    return if r == 0 { a } else { b };
}

// MDNode::getMostGenericAlignmentOrDereferenceable
fn cu_most_generic_align_deref(a: i32, b: i32) -> i32 {
    if a < 0 || b < 0 { return -1; }
    if cint_lo(cu_md_cint(a, 0)) < cint_lo(cu_md_cint(b, 0)) { return a; }
    return b;
}

// MDNode::getMergedCalleeTypeMetadata
fn cu_merged_callee_type(a: i32, b: i32) -> i32 {
    if a < 0 || b < 0 { return -1; }
    var xs: i32[>..<] = [];
    for k in mds[a].nops { cu_push_unique(xs, md_op(a, k)); }
    for k in mds[b].nops { cu_push_unique(xs, md_op(b, k)); }
    return md_get(MK_TUPLE, -1, xs, false);
}

// MDNode::toCaptureComponents / fromCaptureComponents
fn cu_to_capture_components(m: i32) -> i64 {
    if m < 0 { return CC_ALL_CU; }
    var cc: i64 = 0;
    for k in mds[m].nops {
        let s = sbytes(mds[md_op(m, k)].extra);
        if s == "address" { cc |= 3; } else if s == "address_is_null" { cc |= 1; }
        else if s == "provenance" { cc |= 12; } else if s == "read_provenance" { cc |= 4; }
    }
    return cc;
}
let CC_ALL_CU: i64 = 15;
fn cu_from_capture_components(cc: i64) -> i32 {
    if cc == CC_ALL_CU { return -1; }
    var xs: i32[>..<] = [];
    if (cc & 3) == 1 { xs.push(md_string("address_is_null")); }
    else if (cc & 3) == 3 { xs.push(md_string("address")); }
    if (cc & 12) == 4 { xs.push(md_string("read_provenance")); }
    else if (cc & 12) == 12 { xs.push(md_string("provenance")); }
    return md_get(MK_TUPLE, -1, xs, false);
}

// MDNode::getMostGenericNoaliasAddrspace: ConstantRangeList intersection
fn cu_most_generic_noalias_addrspace(a: i32, b: i32) -> i32 {
    if a < 0 || b < 0 { return -1; }
    if a == b { return a; }
    // ConstantRangeList::intersectWith over the (lo, hi) pairs
    let na = mds[a].nops as i64 / 2;
    let nb = mds[b].nops as i64 / 2;
    var res: i32[>..<] = [];
    var i: i64 = 0;
    var j: i64 = 0;
    while i < na && j < nb {
        let al = ap_from_cint(mds[md_op(a, 2 * i)].extra);
        let ah = ap_from_cint(mds[md_op(a, 2 * i + 1)].extra);
        let bl = ap_from_cint(mds[md_op(b, 2 * j)].extra);
        let bh = ap_from_cint(mds[md_op(b, 2 * j + 1)].extra);
        let st = if ap_slt(al, bl) { bl } else { al };
        let en = if ap_slt(ah, bh) { ah } else { bh };
        if ap_slt(st, en) {
            let t = ty_int(st.w as i64);
            res.push(md_value(ap_to_cint(t, st)));
            res.push(md_value(ap_to_cint(t, en)));
        }
        if ap_slt(ah, bh) { i += 1; } else { j += 1; }
    }
    if res.len == 0 { return -1; }
    return md_get(MK_TUPLE, -1, res, false);
}

// MDNode::getMergedProfMetadata(A, B, AInstr, BInstr)
fn cu_merged_prof(a: i32, b: i32, ai: i32, bi: i32) -> i32 {
    fn legal(i: i32) -> bool {
        let o = iop(i);
        return o == OP_INVOKE || o == OP_CONDBR || o == OP_SWITCH || o == OP_CALL || o == OP_INDIRECTBR || o == OP_SELECT || o == OP_CALLBR;
    }
    if !legal(ai) || !legal(bi) { return -1; }
    if a < 0 || b < 0 { return if a >= 0 { a } else { b }; }
    if iop(ai) == OP_CALL && iop(bi) == OP_CALL && called_function(ai) >= 0 && called_function(bi) >= 0 {
        // mergeDirectCallProfMetadata
        if pd_md_string_is(md_op(a, 0), "branch_weights") && pd_md_string_is(md_op(b, 0), "branch_weights") {
            let wa = pd_md_weight(a, pd_offset(a));
            let wb = pd_md_weight(b, pd_offset(b));
            var s = wa + wb;
            if s < wa { s = 0xFFFFFFFFFFFFFFFF; }
            let ops: i32[2] = [md_string("branch_weights"), md_value(c_int(T_I64, s as! i64))];
            return md_get(MK_TUPLE, -1, ops, false);
        }
        return -1;
    }
    if a == b { return a; }
    return -1;
}

fn cu_set_md(i: i32, kind: i32, node: i32) { if node >= 0 { inst_set_md(i, kind, node); } else { inst_erase_md(i, kind); } }

fn cu_combine_metadata(k: i32, j: i32, does_k_move: bool, aa_only: bool) {
    var kinds: i32[>..<] = [];
    var nodes: i32[>..<] = [];
    let ki = inst_of(k);
    for x in insts[ki].nmd {
        let kind = md_att[insts[ki].md + 2 * x];
        if kind == 0 { continue; }
        kinds.push(kind);
        nodes.push(md_att[insts[ki].md + 2 * x + 1]);
    }
    let noundef_k = md_kind_id("noundef");
    for x in kinds.len {
        let kind = kinds[x];
        let kmd = nodes[x];
        let jmd = inst_get_md(j, kind);
        let nm = sbytes(md_kind_names[kind]);
        let has_noundef = inst_get_md(k, noundef_k) >= 0;
        if nm == "DIAssignID" { if !aa_only && jmd != kmd { cu_not_ported("mergeDIAssignID"); } }
        else if nm == "tbaa" {
            if does_k_move && jmd != kmd {
                if jmd < 0 { cu_set_md(k, kind, -1); } else { cu_not_ported("MDNode::getMostGenericTBAA of different tags"); }
            }
        }
        else if nm == "alias.scope" { if does_k_move { cu_set_md(k, kind, cu_most_generic_alias_scope(jmd, kmd)); } }
        else if nm == "noalias" || nm == "llvm.mem.parallel_loop_access" { if does_k_move { cu_set_md(k, kind, cu_md_intersect(jmd, kmd)); } }
        else if nm == "llvm.access.group" { if does_k_move { cu_set_md(k, kind, cu_intersect_access_groups(k, j)); } }
        else if nm == "range" { if !aa_only && (does_k_move || !has_noundef) { cu_set_md(k, kind, ec_most_generic_range(jmd, kmd)); } }
        else if nm == "nofpclass" { if !aa_only && (does_k_move || !has_noundef) { cu_set_md(k, kind, ec_most_generic_nofpclass(jmd, kmd)); } }
        else if nm == "fpmath" { if !aa_only { cu_set_md(k, kind, cu_most_generic_fpmath(jmd, kmd)); } }
        else if nm == "invariant.load" || nm == "invariant.group" { if does_k_move { cu_set_md(k, kind, jmd); } }
        else if nm == "nonnull" { if !aa_only && (does_k_move || !has_noundef) { cu_set_md(k, kind, jmd); } }
        else if nm == "prof" || nm == "mmra" || nm == "memprof" || nm == "callsite" { }
        else if nm == "callee_type" { if !aa_only { cu_set_md(k, kind, cu_merged_callee_type(kmd, jmd)); } }
        else if nm == "align" { if !aa_only && (does_k_move || !has_noundef) { cu_set_md(k, kind, cu_most_generic_align_deref(jmd, kmd)); } }
        else if nm == "dereferenceable" || nm == "dereferenceable_or_null" { if !aa_only && does_k_move { cu_set_md(k, kind, cu_most_generic_align_deref(jmd, kmd)); } }
        else if nm == "llvm.preserve.access.index" { }
        else if nm == "noundef" { if !aa_only && does_k_move { cu_set_md(k, kind, jmd); } }
        else if nm == "nontemporal" { if !aa_only { cu_set_md(k, kind, jmd); } }
        else if nm == "mem.cache_hint" { if !aa_only && kmd != jmd { cu_set_md(k, kind, -1); } }
        else if nm == "noalias.addrspace" { if does_k_move { cu_set_md(k, kind, cu_most_generic_noalias_addrspace(jmd, kmd)); } }
        else if nm == "nosanitize" { cu_set_md(k, kind, jmd); }
        else if nm == "captures" { cu_set_md(k, kind, cu_from_capture_components(cu_to_capture_components(jmd) | cu_to_capture_components(kmd))); }
        else if nm == "alloc_token" { if kmd != jmd { cu_set_md(k, kind, -1); } }
        else { cu_set_md(k, kind, -1); }
    }
    let mmra = md_kind_id("mmra");
    let jm = inst_get_md(j, mmra);
    let km = inst_get_md(k, mmra);
    if jm >= 0 || km >= 0 {
        if jm != km { cu_not_ported("MMRAMetadata::combine"); }
    }
    let memprof = md_kind_id("memprof");
    // MDNode::getMergedMemProfMetadata / getMergedCallsiteMetadata keep K's node, else J's
    let jmp = inst_get_md(j, memprof);
    let kmp = inst_get_md(k, memprof);
    if !aa_only && (jmp >= 0 || kmp >= 0) { cu_set_md(k, memprof, if kmp >= 0 { kmp } else { jmp }); }
    let callsite = md_kind_id("callsite");
    let jcs = inst_get_md(j, callsite);
    let kcs = inst_get_md(k, callsite);
    if !aa_only && (jcs >= 0 || kcs >= 0) { cu_set_md(k, callsite, if kcs >= 0 { kcs } else { jcs }); }
    let jp = inst_get_md(j, MDK_PROF);
    let kp = inst_get_md(k, MDK_PROF);
    if !aa_only && (jp >= 0 || kp >= 0) { cu_set_md(k, MDK_PROF, cu_merged_prof(kp, jp, k, j)); }
}
