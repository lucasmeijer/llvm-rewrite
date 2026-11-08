// InstCombine framework: port of llvm/lib/Transforms/InstCombine/InstructionCombining.cpp
// (InstCombinerImpl::run, prepareWorklist, combineInstructionsOverFunction, InstCombinePass::run,
// tryToSinkInstruction, visitReturnInst/visitUnreachableInst/visitUncondBrInst/visitCondBrInst and the dead-block
// handling), llvm/include/llvm/Transforms/Utils/InstructionWorklist.h, the InstCombiner helpers of
// InstCombiner.h / InstCombineInternal.h (replaceInstUsesWith, replaceOperand, replaceUse,
// eraseInstFromFunction, InsertNewInstBefore) and InstCombine's IRBuilder (IRBuilder<TargetFolder,
// IRBuilderInstCombineInserter>), in ic_builder.goose.
//
// Data, not objects: one InstCombinerImpl at a time, its state in the globals below. A visitor returns an
// instruction id: -1 (nullptr: no change), the visited instruction itself (modified in place), or a new,
// not yet inserted instruction that replaces it (run() inserts it, as LLVM does). Dispatch is the opcode
// switch in ic_visit. See DESIGN.md §10 for how to add a fold.
namespace ic;
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import intrinsics;
import datalayout;
import domtree;
import analyses;
import local;
import tli;
import assume;
import vt;
import pm;
import constfold;
import cfold;
import instsimplify;
import flags;
import apint;
import domcond;
import cfgutil;
import ic_builder;
import ic_common;
import ic_addsub;
import ic_muldivrem;
import ic_shifts;
import ic_casts;
import ic_compares;
import ic_andorxor;
import ic_demanded;
import ic_visit_misc;

fn ic_not_ported(what: const u8[:]) { fatal(str("InstCombine: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// Options (InstCombineOptions, parseInstCombineOptions) and cl::opts

var ic_opt_verify_fixpoint: bool = true;
var ic_opt_max_iterations: i64 = 1;

// ---------------------------------------------------------------------------------------------
// InstCombinerImpl state

var ic_fn: i32 = -1;
var ic_made_change: bool = false;   // MadeIRChange
var ic_dead_from: i32[>..<];        // DeadEdges (SmallDenseSet<pair<BB*, BB*>>), membership only
var ic_dead_to: i32[>..<];
var ic_rpo: i32[>..<];              // ReversePostOrderTraversal of the function (computed once per run)

// ---------------------------------------------------------------------------------------------
// InstructionWorklist

var icw: i32[>..<];          // Worklist (SmallVector); erased entries are -1
var icw_def: i32[>..<];      // Deferred (SmallSetVector)
var icw_idx: i32[>..];       // value id -> index in icw, -1 = not in the worklist (WorklistMap)
var icw_in_def: bool[>..];   // value id -> member of Deferred

fn icw_grow(v: i32) {
    while icw_idx.len <= (v as i64) { icw_idx.push(-1); icw_in_def.push(false); }
}
fn icw_is_empty() -> bool { icw.len == 0 && icw_def.len == 0 }
// add: deferred, visited in the order added
fn icw_add(i: i32) {
    icw_grow(i);
    if icw_in_def[i] { return; }
    icw_in_def[i] = true;
    icw_def.push(i);
}
fn icw_add_value(v: i32) { if is_inst(v) { icw_add(v); } }
// push: onto the stack
fn icw_push(i: i32) {
    icw_grow(i);
    if icw_idx[i] >= 0 { return; }
    icw_idx[i] = icw.len as i32;
    icw.push(i);
}
fn icw_push_value(v: i32) { if is_inst(v) { icw_push(v); } }
fn icw_pop_deferred() -> i32 {
    if icw_def.len == 0 { return -1; }
    let i = icw_def.pop();
    icw_in_def[i] = false;
    return i;
}
fn icw_remove(i: i32) {
    icw_grow(i);
    let k = icw_idx[i];
    if k >= 0 { icw[k] = -1; icw_idx[i] = -1; }
    if icw_in_def[i] {
        // SetVector::remove keeps the order of the others
        var w: i64 = 0;
        for j in icw_def.len { let x = icw_def[j]; if x != i { icw_def[w] = x; w++; } }
        icw_def.resize(w);
        icw_in_def[i] = false;
    }
}
fn icw_remove_one() -> i32 {
    if icw.len == 0 { return -1; }
    let i = icw.pop();
    if i >= 0 { icw_idx[i] = -1; }
    return i;
}
// pushUsersToWorkList: users in use-list order
fn icw_push_users(i: i32) {
    var u = vals[i].first_use;
    while u >= 0 { let us = uses[u].user; u = uses[u].next; icw_push(us); }
}
// handleUseCountDecrement (after the use count of v went down)
fn icw_handle_use_count_decrement(v: i32) {
    if !is_inst(v) { return; }
    icw_add(v);
    if has_one_use(v) { icw_add(uses[vals[v].first_use].user); }
}
fn icw_zap() {
    if icw.len != 0 || icw_def.len != 0 { fatal("internal: InstCombine worklist not empty at zap"); }
}

// ---------------------------------------------------------------------------------------------
// Use counts

fn has_one_use(v: i32) -> bool { let u = vals[v].first_use; u >= 0 && uses[u].next < 0 }
fn use_empty(v: i32) -> bool { vals[v].first_use < 0 }
fn has_n_uses_or_more(v: i32, n: i64) -> bool {
    var c: i64 = 0;
    var u = vals[v].first_use;
    while u >= 0 { c++; if c >= n { return true; } u = uses[u].next; }
    return false;
}
fn num_uses(v: i32) -> i64 { var c: i64 = 0; var u = vals[v].first_use; while u >= 0 { c++; u = uses[u].next; } return c; }
// hasOneUse for constants (ConstantData has no use list: never one use)
fn one_use(v: i32) -> bool { v >= 0 && !is_constant_data(v) && has_one_use(v) }

// ---------------------------------------------------------------------------------------------
// Names

// Value::takeName(src): dst gets src's name (src loses it). An unattached dst keeps the name unregistered
// until it is inserted (ic_register_name).
fn ic_take_name(dst: i32, src: i32) {
    if dst == src { return; }
    if vals[dst].name >= 0 { set_name(dst, ""); }
    if vals[src].name < 0 { return; }
    var buf: u8[>..] = [];
    buf.append(sbytes(vals[src].name));
    set_name(src, "");
    if is_constant(dst) { return; }
    set_name(dst, buf);
}
// ValueSymbolTable::reinsertValue on insertion: a name set while the instruction was not in a function
// is registered (and uniqued) now.
fn ic_register_name(iv: i32) {
    let n = vals[iv].name;
    if n < 0 { return; }
    let st = symtab_for(iv);
    if st < 0 { return; }
    if symtab_lookup(st, n) == iv { return; }
    var buf: u8[>..] = [];
    buf.append(sbytes(n));
    vals[iv].name = -1;
    set_name(iv, buf);
}
fn ic_set_name(iv: i32, name: const u8[:]) {
    if vals[iv].ty == T_VOID { return; }
    set_name(iv, name);
}

// ---------------------------------------------------------------------------------------------
// InstCombiner helpers

// Instruction::insertBefore(It) for a new instruction: it adopts the debug records at the position.
fn ic_insert_before_pos(iv: i32, pos: i32) {
    m2r_insert_before_adopting(iv, pos);
    ic_register_name(iv);
}
// InsertNewInstBefore(New, Old)
fn ic_insert_new_before(nw: i32, old: i32) -> i32 {
    ic_insert_before_pos(nw, old);
    icw_add(nw);
    return nw;
}
// InsertNewInstWith(New, Old): also takes Old's debug location
fn ic_insert_new_with(nw: i32, old: i32) -> i32 {
    let dl = inst_get_md(old, 0);
    if dl >= 0 { inst_set_md(nw, 0, dl); } else { inst_erase_md(nw, 0); }
    return ic_insert_new_before(nw, old);
}

// Value::replaceAllUsesWith with the AssumptionCache and DomConditionCache callbacks
fn ic_rauw(old: i32, nv: i32) {
    ac_rauw(old, nv);
    dbg_rauw_values(old, nv);
    rauw(old, nv);
}

// replaceInstUsesWith(I, V)
fn ic_replace_inst_uses_with(i: i32, v0: i32) -> i32 {
    if use_empty(i) { return -1; }
    icw_push_users(i);
    var v = v0;
    if i == v { v = c_poison(vals[i].ty); }
    if is_inst(v) && use_empty(v) && vals[v].name < 0 && vals[i].name >= 0 { ic_take_name(v, i); }
    ic_rauw(i, v);
    return i;
}
// replaceOperand(I, OpNum, V)
fn ic_replace_operand(i: i32, k: i64, v: i32) -> i32 {
    let old = op(i, k);
    set_op(i, k, v);
    icw_handle_use_count_decrement(old);
    return i;
}
// replaceUse(U, NewValue)
fn ic_replace_use(u: i32, v: i32) {
    let old = uses[u].val;
    use_set(u, v);
    icw_handle_use_count_decrement(old);
}
// eraseInstFromFunction(I)
fn ic_erase(i: i32) -> i32 {
    if !use_empty(i) { fatal("internal: InstCombine erasing an instruction that is used"); }
    let mark = ic_ops_tmp.len;
    for k in nops(i) { ic_ops_tmp.push(op(i, k)); }
    icw_remove(i);
    dc_remove_value(i);
    ic_erase_with_debug(i);
    for k in mark..ic_ops_tmp.len { let o = ic_ops_tmp[k]; if o >= 0 { icw_handle_use_count_decrement(o); } }
    ic_ops_tmp.resize(mark);
    ic_made_change = true;
    return -1;
}
var ic_ops_tmp: i32[>..<];

// salvageDebugInfo(I) + eraseFromParent: not ported; erasing a value that a debug record uses fails loudly.
fn ic_erase_with_debug(i: i32) { inst_erase_from_parent(i); }
fn dbg_rauw_values(old: i32, nv: i32) {
    if dbgrecs.len > 0 && dbg_records_use_value(old) { ic_not_ported("RAUW of a value used by debug records"); }
}

// CreateNonTerminatorUnreachable: store i1 true, ptr poison
fn ic_create_non_terminator_unreachable(at: i32) {
    let si = create_inst(OP_STORE, T_VOID, [c_true(), c_poison(ty_ptr(0))]);
    insts[inst_of(si)].align = 1;
    ic_insert_new_with(si, at);
}

// ---------------------------------------------------------------------------------------------
// Dead edges and blocks

fn ic_dead_edge_has(from: i32, to: i32) -> bool {
    for k in ic_dead_from.len { if ic_dead_from[k] == from && ic_dead_to[k] == to { return true; } }
    return false;
}
fn ic_dead_edge_insert(from: i32, to: i32) -> bool {
    if ic_dead_edge_has(from, to) { return false; }
    ic_dead_from.push(from);
    ic_dead_to.push(to);
    return true;
}
// all_of(predecessors(BB), Pred => DeadEdges.contains({Pred, BB}) || DT.dominates(BB, Pred))
fn ic_block_is_dead(bb: i32) -> bool {
    var dead = true;
    each_pred(bb) { p =>
        if dead && !ic_dead_edge_has(p, bb) && !dt_dominates_block(DT_DOM, bb, p) { dead = false; }
    };
    return dead;
}

// addDeadEdge(From, To, Worklist)
fn ic_add_dead_edge(from: i32, to: i32, wl: i32[>..<]&) {
    if !ic_dead_edge_insert(from, to) { return; }
    var p = block_first(to);
    while p >= 0 && iop(p) == OP_PHI {
        for k in nops(p) {
            if phi_block(p, k) == from && !is_poison(op(p, k)) {
                ic_replace_use(vals[p].ops + (k as i32), c_poison(vals[p].ty));
                icw_add(p);
                ic_made_change = true;
            }
        }
        p = inst_next(p);
    }
    wl.push(to);
}

// handleUnreachableTerminator(I, PoisonedValues)
fn ic_handle_unreachable_terminator(t: i32, poisoned: i32[>..<]&) -> bool {
    var changed = false;
    if dbgrecs.len > 0 && inst_first_dbg(t) >= 0 { ic_not_ported("dropDbgRecords on a terminator"); }
    for k in nops(t) {
        let o = op(t, k);
        if is_inst(o) && ty_kind(vals[o].ty) != TK_TOKEN {
            set_op(t, k, c_poison(vals[o].ty));
            poisoned.push(o);
            changed = true;
        }
    }
    return changed;
}

// handleUnreachableFrom(I, Worklist)
fn ic_handle_unreachable_from(first: i32, wl: i32[>..<]&) {
    let bb = inst_parent(first);
    let term = block_terminator(bb);
    // reverse order from before the terminator down to `first`
    var it = inst_prev(term);
    var stop = false;
    while it >= 0 && !stop {
        let inst = it;
        it = inst_prev(it);
        if inst == first { stop = true; }
        if !use_empty(inst) && ty_kind(vals[inst].ty) != TK_TOKEN {
            ic_replace_inst_uses_with(inst, c_poison(vals[inst].ty));
            ic_made_change = true;
        }
        if inst_is_eh_pad(inst) || ty_kind(vals[inst].ty) == TK_TOKEN { continue; }
        if dbgrecs.len > 0 && inst_first_dbg(inst) >= 0 { ic_not_ported("dropDbgRecords in handleUnreachableFrom"); }
        ic_erase(inst);
        ic_made_change = true;
    }
    var changed: i32[>..<] = [];
    if ic_handle_unreachable_terminator(term, changed) {
        ic_made_change = true;
        for v in changed { icw_add(v); }
    }
    for k in term_nsucc(term) { ic_add_dead_edge(bb, term_succ(term, k), wl); }
}

// handlePotentiallyDeadBlocks(Worklist)
fn ic_handle_potentially_dead_blocks(wl: i32[>..<]&) {
    while wl.len > 0 {
        let bb = wl.pop();
        if !ic_block_is_dead(bb) { continue; }
        ic_handle_unreachable_from(block_first(bb), wl);
    }
}

// handlePotentiallyDeadSuccessors(BB, LiveSucc)
fn ic_handle_potentially_dead_successors(bb: i32, live: i32) {
    var wl: i32[>..<] = [];
    let t = block_terminator(bb);
    for k in term_nsucc(t) {
        let s = term_succ(t, k);
        if s == live { continue; }
        ic_add_dead_edge(bb, s, wl);
    }
    ic_handle_potentially_dead_blocks(wl);
}

// ---------------------------------------------------------------------------------------------
// Sinking

// BasicBlock::getUniquePredecessor
fn unique_predecessor(bb: i32) -> i32 {
    var r: i32 = -1;
    var ok = true;
    each_pred(bb) { p =>
        if ok {
            if r < 0 { r = p; } else if r != p { ok = false; }
        }
    };
    return if ok { r } else { -1 };
}
// BasicBlock::getFirstInsertionPt (the instruction to insert before; -1 = end)
fn first_insertion_pt(bb: i32) -> i32 {
    var i = block_first(bb);
    while i >= 0 && (iop(i) == OP_PHI || inst_is_eh_pad(i)) { i = inst_next(i); }
    return i;
}
fn is_droppable_user(u: i32) -> bool { let id = inst_iid(u); id == IID_assume || id == IID_pseudoprobe }

// getOptionalSinkBlockForInst (the lambda in run()): -1 = none
fn ic_sink_block_for(i: i32) -> i32 {
    if !flag_bool("instcombine-code-sinking", true) { return -1; }
    let max_users = flag_int("instcombine-max-sink-users", 32);
    let bb = inst_parent(i);
    var user_parent: i32 = -1;
    var nusers: i64 = 0;
    var u = vals[i].first_use;
    while u >= 0 {
        let us = uses[u].user;
        let uk = u;
        u = uses[u].next;
        if is_droppable_user(us) {
            if inst_iid(us) != IID_assume || !cb_has_bundle_tag(us, "dereferenceable") { continue; }
        }
        if nusers > max_users { return -1; }
        var ubb = inst_parent(us);
        if iop(us) == OP_PHI { ubb = use_aux[uk]; }
        if user_parent >= 0 && user_parent != ubb { return -1; }
        user_parent = ubb;
        if nusers == 0 {
            if user_parent == bb || !dt_has_node(DT_DOM, user_parent) { return -1; }
            let term = block_terminator(user_parent);
            if unique_predecessor(user_parent) != bb && term_nsucc(term) != 0 { return -1; }
        }
        nusers++;
    }
    return user_parent;
}

// SoleWriteToDeadLocal(I, TLI)
fn ic_sole_write_to_dead_local(i: i32) -> bool {
    if !is_callbase(i) { return false; }
    ic_not_ported("SoleWriteToDeadLocal (sinking a call that writes memory)");
    return false;
}

// tryToSinkInstruction(I, DestBlock)
fn ic_try_to_sink(i: i32, dest: i32) -> bool {
    let src = inst_parent(i);
    if iop(i) == OP_PHI || inst_is_eh_pad(i) || inst_may_throw(i) || !inst_will_return(i) || is_terminator(i) { return false; }
    if iop(i) == OP_ALLOCA { return false; }
    if iop(block_terminator(dest)) == OP_CATCHSWITCH { return false; }
    if iop(i) == OP_CALL && call_has_fn_attr(i, AK_Convergent) { return false; }
    if inst_may_write_memory(i) {
        if !ic_sole_write_to_dead_local(i) { return false; }
    }
    if inst_may_read_memory(i) && inst_get_md(i, md_kind_id("invariant.load")) < 0 {
        if unique_predecessor(dest) != src { return false; }
        var s = inst_next(i);
        while s >= 0 {
            if inst_may_write_memory(s) && inst_iid(s) != IID_assume { return false; }
            s = inst_next(s);
        }
    }
    // dropDroppableUses: uses by assumes outside DestBlock
    var u = vals[i].first_use;
    while u >= 0 {
        let us = uses[u].user;
        u = uses[u].next;
        if is_droppable_user(us) && inst_parent(us) != dest { ic_not_ported("dropDroppableUses when sinking"); }
    }
    let pos = first_insertion_pt(dest);
    // moveBefore(*DestBlock, InsertPos)
    inst_remove(i);
    if pos >= 0 { m2r_insert_before_adopting(i, pos); } else { block_append_inst(dest, i); }
    if dbgrecs.len > 0 && dbg_records_use_value(i) { ic_not_ported("sinking an instruction with debug users"); }
    return true;
}

// ---------------------------------------------------------------------------------------------
// ConstantFoldInstruction(I, DL, TLI)

fn ic_constant_fold_instruction(i: i32) -> i32 {
    if iop(i) == OP_PHI {
        var common: i32 = -1;
        for k in nops(i) {
            let inc = op(i, k);
            if is_undef_or_poison(inc) { continue; }
            if !is_constant(inc) { return -1; }
            let c = cf_fold_constant(inc);
            if common >= 0 && c != common { return -1; }
            common = c;
        }
        return if common >= 0 { common } else { c_undef(vals[i].ty) };
    }
    for k in nops(i) { if !is_constant(op(i, k)) { return -1; } }
    let mark = is_ops.len;
    for k in nops(i) { let c = cf_fold_constant(op(i, k)); is_ops.push(c); }
    let r = cf_fold_inst_operands(i, mark, nops(i), true);
    is_ops.resize(mark);
    return r;
}

// ---------------------------------------------------------------------------------------------
// prepareWorklist(F)

fn ic_handle_only_live_successor(bb: i32, live: i32) {
    let t = block_terminator(bb);
    for k in term_nsucc(t) {
        let s = term_succ(t, k);
        if s != live && ic_dead_edge_insert(bb, s) {
            var p = block_first(s);
            while p >= 0 && iop(p) == OP_PHI {
                for j in nops(p) {
                    if phi_block(p, j) == bb && !is_poison(op(p, j)) {
                        set_op(p, j, c_poison(vals[p].ty));
                        ic_made_change = true;
                    }
                }
                p = inst_next(p);
            }
        }
    }
}

fn is_debug_or_pseudo_inst(i: i32) -> bool {
    let id = inst_iid(i);
    return id == IID_dbg_declare || id == IID_dbg_value || id == IID_dbg_label || id == IID_dbg_assign || id == IID_pseudoprobe;
}

fn ic_prepare_worklist(fv: i32) -> bool {
    ic_made_change = false;
    var live: i32[>..<] = [];          // LiveBlocks (membership through ic_live)
    var insts_for_wl: i32[>..<] = [];
    vs_clear(VS_PASS0);
    for bb in ic_rpo {
        if bb != func_entry(fv) && ic_block_is_dead(bb) {
            ic_handle_only_live_successor(bb, -1);
            continue;
        }
        vs_add(VS_PASS0, bb);
        live.push(bb);
        var it = block_first(bb);
        while it >= 0 {
            let inst = it;
            it = inst_next(it);
            if !use_empty(inst) && (nops(inst) == 0 || is_constant(op(inst, 0))) {
                let c = ic_constant_fold_instruction(inst);
                if c >= 0 {
                    ic_rauw(inst, c);
                    if is_instruction_trivially_dead(inst) { inst_erase_from_parent(inst); }
                    ic_made_change = true;
                    continue;
                }
            }
            for k in nops(inst) {
                let c = op(inst, k);
                if c < 0 { continue; }
                let kk = vals[c].kind;
                if kk != VK_CVECTOR && kk != VK_CEXPR { continue; }
                let fr = cf_fold_constant(c);
                if fr != c { set_op(inst, k, fr); ic_made_change = true; }
            }
            if !is_debug_or_pseudo_inst(inst) {
                insts_for_wl.push(inst);
                if inst_iid(inst) == IID_experimental_noalias_scope_decl { ic_not_ported("AliasScopeTracker (llvm.experimental.noalias.scope.decl)"); }
            }
        }
        let t = block_terminator(bb);
        if iop(t) == OP_CONDBR {
            let c = op(t, 0);
            if is_undef_or_poison(c) { ic_handle_only_live_successor(bb, -1); continue; }
            if is_cint(c) && !ty_is_vector(vals[c].ty) {
                let cv = cint_lo(c) != 0;
                ic_handle_only_live_successor(bb, term_succ(t, if cv { 0 } else { 1 }));
                continue;
            }
        } else if iop(t) == OP_SWITCH {
            let c = op(t, 0);
            if is_undef_or_poison(c) { ic_handle_only_live_successor(bb, -1); continue; }
            if is_cint(c) && !ty_is_vector(vals[c].ty) {
                ic_handle_only_live_successor(bb, switch_find_case_dest(t, c));
                continue;
            }
        }
    }
    // Remove instructions inside unreachable blocks
    var b = func_entry(fv);
    while b >= 0 {
        if !vs_has(VS_PASS0, b) {
            if remove_all_non_terminator_and_eh_pad(b) != 0 { ic_made_change = true; }
        }
        b = block_next(b);
    }
    var k = insts_for_wl.len - 1;
    while k >= 0 {
        let inst = insts_for_wl[k];
        k--;
        if is_instruction_trivially_dead(inst) {
            inst_erase_from_parent(inst);
            ic_made_change = true;
            continue;
        }
        icw_push(inst);
    }
    return ic_made_change;
}

// SwitchInst::findCaseValue(C)->getCaseSuccessor()
fn switch_find_case_dest(t: i32, c: i32) -> i32 {
    let n = nops(t);
    var k: i64 = 2;
    while k + 1 < n {
        if op(t, k) == c { return op(t, k + 1); }
        k += 2;
    }
    return op(t, 1);
}

// removeAllNonTerminatorAndEHPadInstructions(BB)
fn remove_all_non_terminator_and_eh_pad(bb: i32) -> i64 {
    var n: i64 = 0;
    var end_inst = block_terminator(bb);
    var poisoned: i32[>..<] = [];
    ic_handle_unreachable_terminator(end_inst, poisoned);
    while end_inst != block_first(bb) {
        let inst = inst_prev(end_inst);
        if !use_empty(inst) && ty_kind(vals[inst].ty) != TK_TOKEN { ic_rauw(inst, c_poison(vals[inst].ty)); }
        if inst_is_eh_pad(inst) || ty_kind(vals[inst].ty) == TK_TOKEN {
            if dbgrecs.len > 0 && inst_first_dbg(inst) >= 0 { ic_not_ported("dropDbgRecords on an EH pad"); }
            end_inst = inst;
            continue;
        }
        n++;
        if dbgrecs.len > 0 { dbg_drop_records(inst); }
        inst_erase_from_parent(inst);
    }
    return n;
}

// ReversePostOrderTraversal<BasicBlock *> from the entry
fn ic_compute_rpo(fv: i32) {
    ic_rpo.resize(0);
    vs_clear(VS_PASS0);
    var po: i32[>..<] = [];
    var st_b: i32[>..<] = [];
    var st_k: i64[>..<] = [];
    let e = func_entry(fv);
    vs_add(VS_PASS0, e);
    st_b.push(e); st_k.push(0);
    while st_b.len > 0 {
        let top = st_b.len - 1;
        let bb = st_b[top];
        let k = st_k[top];
        if k < block_nsucc(bb) {
            st_k[top] = k + 1;
            let s = block_succ(bb, k);
            if vs_add(VS_PASS0, s) { st_b.push(s); st_k.push(0); }
            continue;
        }
        po.push(bb);
        st_b.pop(); st_k.pop();
    }
    var j = po.len - 1;
    while j >= 0 { ic_rpo.push(po[j]); j--; }
}

// ---------------------------------------------------------------------------------------------
// run()

fn ic_run() -> bool {
    while !icw_is_empty() {
        loop {
            let i = icw_pop_deferred();
            if i < 0 { break; }
            if is_instruction_trivially_dead(i) { ic_erase(i); continue; }
            icw_push(i);
        }
        let i = icw_remove_one();
        if i < 0 { continue; }
        if is_instruction_trivially_dead(i) { ic_erase(i); continue; }

        let sink_to = ic_sink_block_for(i);
        if sink_to >= 0 {
            if ic_try_to_sink(i, sink_to) {
                ic_made_change = true;
                for k in nops(i) { icw_push_value(op(i, k)); }
            }
        }

        icb_set_insert_point(i);
        ic_annot_src = i;
        let res = ic_visit(i);
        ic_annot_src = -1;
        if res < 0 { continue; }
        if res != i {
            // Result->setDebugLoc(Result->getDebugLoc().orElse(I->getDebugLoc()))
            if inst_get_md(res, 0) < 0 { let dl = inst_get_md(i, 0); if dl >= 0 { inst_set_md(res, 0, dl); } }
            ic_copy_annotation_md(res, i);
            ic_rauw(i, res);
            ic_take_name(res, i);
            let parent = inst_parent(i);
            var pos = i;
            if (iop(res) == OP_PHI) != (iop(i) == OP_PHI) {
                if iop(i) == OP_PHI { pos = first_insertion_pt(parent); } else { pos = first_non_phi(parent); }
            }
            if pos >= 0 { ic_insert_before_pos(res, pos); } else { block_append_inst(parent, res); ic_register_name(res); }
            if inst_iid(res) == IID_assume { ic_register_assumption(res); }
            icw_push_users(res);
            icw_push(res);
            ic_erase(i);
        } else {
            if is_instruction_trivially_dead(i) { ic_erase(i); }
            else { icw_push_users(i); icw_push(i); }
        }
        ic_made_change = true;
    }
    icw_zap();
    return ic_made_change;
}

fn ic_register_assumption(a: i32) { ac_register_assumption(a); }
fn ic_copy_annotation_md(dst: i32, src: i32) {
    let k = md_kind_id("annotation");
    let m = inst_get_md(src, k);
    if m >= 0 { ic_not_ported("!annotation metadata"); }
}

// ---------------------------------------------------------------------------------------------
// The visitor dispatch (InstVisitor<InstCombinerImpl>::visit)

fn ic_visit(i: i32) -> i32 {
    let o = iop(i);
    match o {
        OP_ADD => { return visit_add(i); },
        OP_SUB => { return visit_sub(i); },
        OP_MUL => { return visit_mul(i); },
        OP_UDIV => { return visit_udiv(i); },
        OP_SDIV => { return visit_sdiv(i); },
        OP_UREM => { return visit_urem(i); },
        OP_SREM => { return visit_srem(i); },
        OP_SHL => { return visit_shl(i); },
        OP_LSHR => { return visit_lshr(i); },
        OP_ASHR => { return visit_ashr(i); },
        OP_AND => { return visit_and(i); },
        OP_OR => { return visit_or(i); },
        OP_XOR => { return visit_xor(i); },
        OP_TRUNC => { return visit_trunc(i); },
        OP_ZEXT => { return visit_zext(i); },
        OP_SEXT => { return visit_sext(i); },
        OP_ICMP => { return visit_icmp(i); },
        OP_FCMP => { return visit_fcmp(i); },
        OP_RET => { return visit_return(i); },
        OP_BR => { return visit_uncond_br(i); },
        OP_CONDBR => { return visit_cond_br(i); },
        OP_UNREACHABLE => { ic_remove_insts_before_unreachable(i); return -1; },
        _ => { return ic_visit_other(i); },
    }
}

// ---------------------------------------------------------------------------------------------
// combineInstructionsOverFunction + InstCombinePass::run

var ic_lrt_fn: i32[>..];   // LastRunTrackingAnalysis: per function value, 1 = "no change since last run"

fn ic_lrt_get(fv: i32) -> bool { (fv as i64) < ic_lrt_fn.len && ic_lrt_fn[fv] != 0 }
fn ic_lrt_set(fv: i32, b: bool) {
    while ic_lrt_fn.len <= (fv as i64) { ic_lrt_fn.push(0); }
    ic_lrt_fn[fv] = if b { 1 } else { 0 };
}
// invalidation by the pass manager (an analysis not preserved by other passes)
fn ic_lrt_invalidate(fv: i32) { ic_lrt_set(fv, false); }

fn instcombine_run(fv: i32, verify_fixpoint: bool, max_iter: i64) -> u32 {
    if ic_lrt_get(fv) && !flag_bool("disable-last-run-tracking", false) { return PA_ALL; }
    tli_cur_fn = fv;
    local_have_tli = true;
    dt_get(fv, DT_DOM);
    vt_invalidate_assumes();
    ac_invalidate();
    ic_fn = fv;
    ic_experiment_lenient = flag_bool("goose-ic-lenient", false);
    let vf = verify_fixpoint && aset_find_str(alist_fn(func_attrs(fv)), "instcombine-no-verify-fixpoint") < 0;
    if flag_bool("instcombine-lower-dbg-declare", true) {
        // LowerDbgDeclare: no dbg.declare records are lowered (not ported)
        ic_lower_dbg_declare_check(fv);
    }
    ic_compute_rpo(fv);
    var made = false;
    var iter: i64 = 0;
    loop {
        if iter >= max_iter && !vf { break; }
        iter++;
        ic_dead_from.resize(0);
        ic_dead_to.resize(0);
        dc_begin(fv);
        ic_backedges_valid = false;
        var ch = ic_prepare_worklist(fv);
        if ic_run() { ch = true; }
        dc_end();
        if !ch { break; }
        made = true;
        if iter > max_iter {
            fatal(str("Instruction Combining on ", val_name(fv), " did not reach a fixpoint after ", max_iter,
                      " iterations. Use 'instcombine<no-verify-fixpoint>' or function attribute 'instcombine-no-verify-fixpoint' to suppress this error."));
        }
    }
    ic_fn = -1;
    // LRT.update(&ID, Changed): InstCombine is tracked (no options are compared) and the result is preserved
    ic_lrt_set(fv, true);
    if !made { return PA_ALL; }
    return PA_CFG | ((1 as u32) << A_LRT);
}

fn ic_lower_dbg_declare_check(fv: i32) {
    for r in dbgrecs {
        if r.kind == DR_DECLARE && r.owner >= 0 && !is_dead(r.owner) && inst_func(r.owner) == fv {
            ic_not_ported("LowerDbgDeclare (#dbg_declare records)");
        }
    }
}

// computeBackEdges(): BackEdges set over the RPOT
var ic_backedges_valid: bool = false;
var ic_be_from: i32[>..<];
var ic_be_to: i32[>..<];
fn ic_compute_backedges() {
    ic_be_from.resize(0);
    ic_be_to.resize(0);
    vs_clear(VS_PASS0);
    for bb in ic_rpo {
        vs_add(VS_PASS0, bb);
        for k in block_nsucc(bb) {
            let s = block_succ(bb, k);
            if vs_has(VS_PASS0, s) { ic_be_from.push(bb); ic_be_to.push(s); }
        }
    }
    ic_backedges_valid = true;
}
fn ic_is_backedge(from: i32, to: i32) -> bool {
    if !ic_backedges_valid { ic_compute_backedges(); }
    for k in ic_be_from.len { if ic_be_from[k] == from && ic_be_to[k] == to { return true; } }
    return false;
}

// ---------------------------------------------------------------------------------------------
// Terminators (InstructionCombining.cpp)

// visitReturnInst
fn visit_return(ri: i32) -> i32 {
    if nops(ri) == 0 { return -1; }
    let rv = op(ri, 0);
    let fv = ic_fn;
    let rty = vals[rv].ty;
    if ty_kind(rty) == TK_PTR {
        let rset = alist_ret(func_attrs(fv));
        let deref = aset_int(rset, AK_Dereferenceable) > 0;
        if aset_has(rset, AK_NonNull) || (deref && !null_pointer_is_defined(fv, ptr_as(rty))) {
            let v = ic_simplify_non_null_operand(rv, deref, 0);
            if v >= 0 { return ic_replace_operand(ri, 0, v); }
        }
    }
    if !nofpclass_compatible_type(rty) { return -1; }
    let rc = aset_int(alist_ret(func_attrs(fv)), AK_NoFPClass);
    if rc == 0 { return -1; }
    ic_not_ported("SimplifyDemandedFPClass on a nofpclass return");
    return -1;
}

// AttributeFuncs::isNoFPClassCompatibleType
// (FPMathOperator::isSupportedFloatingPointType: FP or FP vector, or composed of homogeneous FP types: a literal
// struct whose elements are all one FP/FP-vector type, or nested arrays of one)
fn nofpclass_compatible_type(t0: i32) -> bool {
    var t = t0;
    if ty_kind(t) == TK_STRUCT {
        if types[t].name >= 0 || ty_count(t) == 0 { return false; }
        let f0 = ty_field(t, 0);
        for k in ty_count(t) { if ty_field(t, k) != f0 { return false; } }
        t = f0;
    } else {
        while ty_kind(t) == TK_ARRAY { t = ty_elem(t); }
    }
    return ty_is_fp(ty_scalar(t));
}

// removeInstructionsBeforeUnreachable(I)
fn ic_remove_insts_before_unreachable(i: i32) -> bool {
    var changed = false;
    loop {
        let prev = inst_prev(i);
        if prev < 0 { break; }
        if inst_is_eh_pad(prev) { break; }
        if !guaranteed_to_transfer(prev) { break; }
        ic_replace_inst_uses_with(prev, c_poison(vals[prev].ty));
        ic_erase(prev);
        changed = true;
    }
    return changed;
}

// visitUncondBrInst
fn visit_uncond_br(bi: i32) -> i32 {
    let first = block_first(inst_parent(bi));
    var b = bi;
    loop {
        if b != first { b = inst_prev(b); }
        if b == first || !is_debug_or_pseudo_inst(b) { break; }
    }
    if iop(b) == OP_STORE {
        if ic_merge_store_into_successor(b) { return bi; }
    }
    return -1;
}

// visitCondBrInst
fn visit_cond_br(bi: i32) -> i32 {
    let cond = op(bi, 0);
    let x = m_not(cond);
    if x >= 0 && !is_constant(x) {
        ic_swap_successors(bi);
        return ic_replace_operand(bi, 0, x);
    }
    if is_inst_op(cond, OP_SELECT) && one_use(cond) {
        if m_logical_and(cond) {
            let a = lg_a;
            let b = lg_b;
            if one_use(b) && m_not(b) >= 0 {
                let y = m_not(b);
                var nm: u8[>..] = [];
                nm.append("not.");
                nm.append(val_name(a));
                let notx = icb_not(a, nm);
                let orv = icb_logical_or(notx, y, "");
                if is_inst(orv) && is_inst(cond) && inst_get_md(cond, md_kind_id("prof")) >= 0 {
                    ic_not_ported("swapped branch weights on a canonicalized logical or");
                }
                ic_swap_successors(bi);
                return ic_replace_operand(bi, 0, orv);
            }
        }
    }
    if !is_cint(cond) && op(bi, 1) == op(bi, 2) {
        return ic_replace_operand(bi, 0, c_false());
    }
    if is_inst_op(cond, OP_FCMP) && one_use(cond) && !is_canonical_predicate(inst_pred(cond)) {
        insts[inst_of(cond)].pred = pred_inverse_any(inst_pred(cond)) as u8;
        ic_swap_successors(bi);
        icw_push(cond);
        return bi;
    }
    if is_undef_or_poison(cond) {
        ic_handle_potentially_dead_successors(inst_parent(bi), -1);
        return -1;
    }
    if is_cint(cond) {
        ic_handle_potentially_dead_successors(inst_parent(bi), term_succ(bi, if cint_lo(cond) != 0 { 0 } else { 1 }));
        return -1;
    }
    let s0 = term_succ(bi, 0);
    let s1 = term_succ(bi, 1);
    if !is_constant(cond) && s0 != s1 {
        let bb = inst_parent(bi);
        var u = vals[cond].first_use;
        while u >= 0 {
            let uu = u;
            u = uses[u].next;
            if dom_edge_use(bb, s0, uu) {
                ic_replace_use(uu, c_int_ty(vals[cond].ty, 1));
                icw_add(uses[uu].user);
                continue;
            }
            if dom_edge_use(bb, s1, uu) {
                ic_replace_use(uu, c_int_ty(vals[cond].ty, 0));
                icw_add(uses[uu].user);
            }
        }
    }
    dc_register_branch(bi);
    return -1;
}

// DominatorTree::dominates(const BasicBlockEdge &BBE, const Use &U)
fn dom_edge_use(start: i32, end: i32, u: i32) -> bool {
    let user = uses[u].user;
    var ubb = inst_parent(user);
    if iop(user) == OP_PHI {
        if ubb == end && use_aux[u] == start { return true; }
        ubb = use_aux[u];
    }
    return dom_edge(start, end, ubb);
}

// CondBrInst::swapSuccessors (+ prof metadata swap)
fn ic_swap_successors(bi: i32) { cu_swap_successors(bi); }

// InstCombiner::isCanonicalPredicate
fn is_canonical_predicate(p: i64) -> bool {
    match p {
        33, 37, 41, 35, 39 => { return false; },   // ICMP_NE, ULE, SLE, UGE, SGE
        6, 5, 3 => { return false; },              // FCMP_ONE, OLE, OGE
        _ => { return true; },
    }
}
fn pred_inverse_any(p: i64) -> i64 {
    if p >= 32 { return pred_inverse_i(p); }
    return 15 - p;
}
fn pred_inverse_i(p: i64) -> i64 {
    match p { 32 => 33, 33 => 32, 34 => 37, 37 => 34, 35 => 36, 36 => 35, 38 => 41, 41 => 38, 39 => 40, 40 => 39, _ => p }
}

fn cb_has_bundle_tag(ci: i32, name: const u8[:]) -> bool {
    for k in cb_nbundles(ci) { if sbytes(cb_bundle_tag(ci, k)) == name { return true; } }
    return false;
}
// Instruction::dropDbgRecords
fn dbg_drop_records(i: i32) {
    loop {
        let r = inst_first_dbg(i);
        if r < 0 { break; }
        dbg_erase_record(r);
    }
}
