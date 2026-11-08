// LoopRotate: turn a loop with a top test into one with a bottom test.
// Port of llvm/lib/Transforms/Scalar/LoopRotation.cpp (LoopRotatePass::run) and
// llvm/lib/Transforms/Utils/LoopRotationUtils.cpp (LoopRotate::processLoop/rotateLoop/simplifyLoopLatch,
// RewriteUsesOfClonedInstructions, profitableToRotateLoopExitingLatch, updateBranchWeights, shouldSpeculateInstrs),
// with CodeMetrics (collectEphemeralValues, analyzeBasicBlock; llvm/lib/Analysis/CodeMetrics.cpp),
// insertDebugValuesForPHIs (Local.cpp), MergeBlockIntoPredecessor / FoldSingleEntryPHINodes /
// RemoveRedundantDbgInstrs (BasicBlockUtils.cpp), Loop::setLoopID (LoopInfo.cpp).
//
// The x86 code-size cost of the header (TTI::getInstructionCost(TCK_CodeSize)) is not fully ported: see
// tti_code_size_bounds. The decision "NumInsts > MaxHeaderSize" is made from lower/upper bounds and fails loudly
// when the bounds don't decide it.

lr_opts: struct {
    rotation_max_header_size: s64 = 16;            // -rotation-max-header-size
    rotation_prepare_for_lto := false;             // -rotation-prepare-for-lto
    enable_header_dup_at_minsize := false;         // -enable-loop-header-duplication-at-minsize
};

Loop_Rotate :: struct {
    max_header_size: s64;
    li: *Loop_Info;
    ac: *Assumption_Cache;
    dt: *Dom_Tree;
    mssau: *Mssa_Updater;
    rotation_only: bool;
    is_util_mode: bool;
    prepare_for_lto: bool;
    check_exit_count: bool;
}

// ---------------------------------------------------------------- small IR utilities

// BasicBlock::hasAddressTaken: a blockaddress constant refers to the block
block_has_address_taken :: (b: Value_Id) -> bool {
    u := ir.v_first_use[b];
    while u != NONE {
        if vkind(ir.u_user[u]) == .C_BLOCKADDR return true;
        u = ir.u_next[u];
    }
    return false;
}

// getUniquePredecessor (duplicate edges from one block allowed)
block_unique_predecessor :: (b: Value_Id) -> Value_Id {
    p: Value_Id = NONE;
    u := ir.v_first_use[b];
    while u != NONE {
        user := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(user) || !is_terminator(inst_op(user)) continue;
        q := inst(user).parent;
        if p != NONE && p != q return NONE;
        p = q;
    }
    return p;
}
// getUniqueSuccessor
block_unique_successor :: (b: Value_Id) -> Value_Id {
    t := block_terminator(b);
    if t == NONE return NONE;
    n := num_successors(t);
    if n == 0 return NONE;
    s := get_successor(t, 0);
    for k: 1..n-1 if get_successor(t, k) != s return NONE;
    return s;
}

// Debug-record lists: `inst(i).records` are the records before i.
records_take :: (i: Value_Id) -> u32 { r := inst(i).records; inst(i).records = 0; return r; }
records_prepend :: (i: Value_Id, first: u32) {
    if first == 0 return;
    x := first;
    while true {
        dbgr(x).owner = i;
        if dbgr(x).next == 0 break;
        x = dbgr(x).next;
    }
    dbgr(x).next = inst(i).records;
    inst(i).records = first;
}
records_append :: (i: Value_Id, first: u32) { attach_records_before(i, first); }

// Instruction::moveBefore(I) (not moveBeforePreserving): the records of i stay where they were (they fall onto the
// next instruction), and i absorbs the records attached to the position it is inserted at.
inst_move_before_dbg :: (i: Value_Id, pos: Value_Id) {
    if inst(i).records && inst_next(i) != pos {
        nx := inst_next(i);
        assert(nx != NONE, "moving a terminator with debug records");
        records_prepend(nx, records_take(i));
    }
    inst_unlink(i);
    inst_insert_before(i, pos);
    if inst(pos).records records_append(i, records_take(pos));
}

// Instruction::clone: operands (with phi blocks / case values), flags, payload, attributes and all metadata; no
// name, no parent, no debug records
inst_clone :: (i: Value_Id) -> Value_Id {
    n := nops(i);
    c := new_inst(inst_op(i), vtype(i), n);
    r := inst(i).*;
    r.parent = NONE; r.prev = NONE; r.next = NONE; r.records = 0;
    inst(c).* = r;
    if n > 0 for k: 0..n-1 {
        ir.u_aux[op_use(c, k)] = ir.u_aux[op_use(i, k)];
        set_op(c, k, op(i, k));
    }
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(i, *all);
    for all set_metadata(c, it.kind, it.md);
    return c;
}

// AssumptionCache::registerAssumption
ac_register_assumption :: (ac: *Assumption_Cache, ci: Value_Id) {
    array_add(*ac.assumes, ci);
    ac_update_affected_values(ac, ci);
}

// DbgRecord::clone, attached at the end of `to`'s records
dbgr_clone_onto :: (r: u32, to: Value_Id) -> u32 {
    nr := dbgr(r).*;
    nr.next = 0;
    nr.owner = NONE;
    array_add(*ir.dbg_records, nr);
    id := cast(u32) ir.dbg_records.count;
    dbgr_restamp(id);
    attach_records_before(to, id);
    if dbg_index.fn != NONE dbgr_index_record(id);
    return id;
}

// Instruction::cloneDebugInfoFrom(From, FromHere): clones From's records starting at `from_here` onto the end of
// `to`'s records; returns the new records
clone_debug_info_from :: (to: Value_Id, from: Value_Id, from_here: u32, out: *[..] u32) {
    out.count = 0;
    // from_here must be one of from's records
    x := inst(from).records;
    while x != 0 && x != from_here x = dbgr(x).next;
    while x != 0 {
        nx := dbgr(x).next;
        array_add(out, dbgr_clone_onto(x, to));
        x = nx;
    }
}

// The location operands of a record (location_ops())
dbgr_location_ops :: (r: u32, out: *[..] Value_Id) {
    out.count = 0;
    dbgr_values_of_loc(dbgr(r).loc, out);
}

// RemapDbgRecordRange(M, Range, VM, RF_NoModuleLevelChanges | RF_IgnoreMissingLocals)
remap_dbg_records :: (recs: [] u32, vm: *Table(Value_Id, Value_Id)) {
    for r: recs {
        rec := dbgr(r);
        if rec.kind == .LABEL continue;
        if rec.kind == .ASSIGN fatal("remapping a #dbg_assign record is not implemented yet");
        loc := rec.loc;
        if loc == NONE continue;
        if ir.mds[loc].kind == .VALUE {
            found, nv := table_find(vm, ir.mds[loc].value);
            if found && nv != ir.mds[loc].value {
                rec.loc = md_value(nv);
                if dbg_index.fn != NONE dbgr_index_add(nv, r);
            }
            continue;
        }
        vals: [..] Value_Id; vals.allocator = temp;
        dbgr_values_of_loc(loc, *vals);
        for vals if table_contains(vm, it) fatal("remapping a DIArgList debug location is not implemented yet");
    }
}

// ---------------------------------------------------------------- CodeMetrics

// CodeMetrics::collectEphemeralValues(L, AC, EphValues)
collect_ephemeral_values :: (li: *Loop_Info, l: Loop_Id, ac: *Assumption_Cache, eph: *Table(Value_Id, bool)) {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    append_spec_ops :: (v: Value_Id, visited: *Table(Value_Id, bool), work: *[..] Value_Id) {
        if !is_inst(v) return;
        n := nops(v);
        if n > 0 for k: 0..n-1 {
            o := op(v, k);
            if o == NONE || table_contains(visited, o) continue;
            table_set(visited, o, true);
            if is_inst(o) && !may_have_side_effects(o) && !is_terminator(inst_op(o)) array_add(work, o);
        }
    }
    for a: ac.assumes {
        if vkind(a) != .INST continue;   // a null handle (erased)
        if !li_contains(li, l, inst_block(a)) continue;
        if table_contains(eph, a) continue;
        table_set(eph, a, true);
        append_spec_ops(a, *visited, *work);
    }
    i := 0;
    while i < work.count {
        v := work[i];
        i += 1;
        all := true;
        u := ir.v_first_use[v];
        while u != NONE { if !table_contains(eph, ir.u_user[u]) { all = false; break; } u = ir.u_next[u]; }
        if !all continue;
        table_set(eph, v, true);
        append_spec_ops(v, *visited, *work);
    }
}

// TTI::isLoweredToCall (TargetTransformInfoImpl.h)
tti_is_lowered_to_call :: (f: Value_Id) -> bool {
    if glob(f).intrinsic return false;
    if is_local_linkage(glob(f).linkage) || vname(f).count == 0 return true;
    NOT_CALLS :: string.["copysign", "copysignf", "copysignl", "fabs", "fabsf", "fabsl", "fmin", "fminf", "fminl",
        "fmax", "fmaxf", "fmaxl", "sin", "sinf", "sinl", "cos", "cosf", "cosl", "tan", "tanf", "tanl", "asin", "asinf",
        "asinl", "acos", "acosf", "acosl", "atan", "atanf", "atanl", "atan2", "atan2f", "atan2l", "sinh", "sinhf",
        "sinhl", "cosh", "coshf", "coshl", "tanh", "tanhf", "tanhl", "sqrt", "sqrtf", "sqrtl", "exp10", "exp10l",
        "exp10f", "pow", "powf", "powl", "exp2", "exp2l", "exp2f", "floor", "floorf", "ceil", "round", "ffs", "ffsl",
        "abs", "labs", "llabs"];
    for NOT_CALLS if vname(f) == it return false;
    return true;
}

TTI_UNBOUNDED :: 1 << 40;

// Bounds of TTI.getInstructionCost(I, TCK_CodeSize) on x86-64. Exact where the rule is ported (calls, CF
// instructions, free intrinsics, the TCC_Basic default); scalar integer (<= 64 bits), pointer and float/double
// arithmetic, compares, selects, casts, GEPs, loads and stores are bounded by [0, 2]: X86TTIImpl answers these
// from BasicTTIImpl's "legal = LT.first * 1, custom = 2" rules or code-size table entries of 1 (see NOTES.md);
// everything else is unbounded.
tti_code_size_bounds :: (i: Value_Id) -> (lo: s64, hi: s64) {
    opc := inst_op(i);
    if is_call_base(i) {
        callee := call_called_function(i);
        if callee != NONE && glob(callee).intrinsic {
            id := call_iid(i);
            if id == IID_ALLOW_RUNTIME_CHECK || id == IID_ALLOW_UBSAN_CHECK || id == IID_ASSUME || id == IID_SIDEEFFECT ||
               id == IID_PSEUDOPROBE || id == IID_ARITHMETIC_FENCE || id == IID_DBG_ASSIGN || id == IID_DBG_DECLARE ||
               id == IID_DBG_VALUE || id == IID_DBG_LABEL || id == IID_INVARIANT_START || id == IID_INVARIANT_END ||
               id == IID_LAUNDER_INVARIANT_GROUP || id == IID_STRIP_INVARIANT_GROUP || id == IID_IS_CONSTANT ||
               id == IID_LIFETIME_START || id == IID_LIFETIME_END || id == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL ||
               id == IID_OBJECTSIZE || id == IID_PTR_ANNOTATION || id == IID_VAR_ANNOTATION || id == IID_ANNOTATION ||
               id == IID_EXPERIMENTAL_GC_RESULT || id == IID_EXPERIMENTAL_GC_RELOCATE || id == IID_THREADLOCAL_ADDRESS ||
               id == IID_SSA_COPY
                return 0, 0;
            return 0, TTI_UNBOUNDED;
        }
        if callee != NONE {
            if !tti_is_lowered_to_call(callee) return 1, 1;
            np := cast(s64) func_nparams(glob(callee).value_type);
            return np + 1, np + 1;
        }
        a := cast(s64) call_num_args(i);
        return a + 1, a + 1;
    }
    if opc == {
        case .PHI; return 0, 0;
        case .BR; #through;
        case .CONDBR; #through;
        case .RET; #through;
        case .SWITCH; return 1, 1;
        case .FREEZE; return 0, 0;
        case .ALLOCA; if is_static_alloca(i) return 0, 0; return 1, 1;
        // not in getInstructionCost's switch: "everything remaining is basic"
        case .VAARG; #through; case .LANDINGPAD; #through; case .CATCHPAD; #through; case .CLEANUPPAD; #through;
        case .FENCE; #through; case .CMPXCHG; #through; case .ATOMICRMW; #through; case .RESUME; #through;
        case .UNREACHABLE; #through; case .INDIRECTBR; #through; case .CATCHSWITCH; #through; case .CATCHRET; #through;
        case .CLEANUPRET; return 1, 1;
    }
    simple_ty :: (t: Type_Id) -> bool {
        k := type_kind(t);
        if k == .INT return type_int_width(t) <= 64;
        return k == .PTR || k == .FLOAT || k == .DOUBLE;
    }
    if opc == {
        case .ADD; #through; case .SUB; #through; case .AND; #through; case .OR; #through; case .XOR; #through;
        case .SHL; #through; case .LSHR; #through; case .ASHR; #through; case .MUL; #through;
        case .FADD; #through; case .FSUB; #through; case .FMUL; #through; case .FNEG; #through;
        case .TRUNC; #through; case .ZEXT; #through; case .SEXT; #through; case .PTRTOINT; #through;
        case .INTTOPTR; #through; case .BITCAST; #through; case .SELECT; #through; case .GEP; #through;
        case .LOAD;
            if simple_ty(vtype(i)) return 0, 2;
        case .ICMP; #through; case .FCMP; #through; case .STORE;
            if simple_ty(vtype(op(i, 0))) return 0, 2;
    }
    return 0, TTI_UNBOUNDED;
}

Code_Metrics :: struct {
    not_duplicatable: bool;
    convergent: bool;
    num_insts_lo: s64;
    num_insts_hi: s64;
    num_inline_candidates: s64;
}

// CodeMetrics::analyzeBasicBlock(BB, TTI, EphValues, PrepareForLTO)
analyze_basic_block :: (m: *Code_Metrics, b: Value_Id, eph: *Table(Value_Id, bool), prepare_for_lto: bool) {
    for i: block_insts(b) {
        if table_contains(eph, i) continue;
        if is_call_base(i) {
            callee := call_called_function(i);
            if callee != NONE {
                lowered := tti_is_lowered_to_call(callee);
                if !call_has_fn_attr(i, .NoInline) && lowered &&
                   ((glob(callee).linkage == .INTERNAL && fn_has_one_live_use(callee)) || prepare_for_lto)
                    m.num_inline_candidates += 1;
            }
        }
        if type_kind(vtype(i)) == .TOKEN {
            // isUsedOutsideOfBlock (convergence-control tokens are not special-cased here)
            u := ir.v_first_use[i];
            while u != NONE {
                user := ir.u_user[u];
                ub := inst_block(user);
                if inst_op(user) == .PHI ub = ir.u_aux[u];
                if ub != b { m.not_duplicatable = true; break; }
                u = ir.u_next[u];
            }
        }
        if is_call_base(i) {
            if call_has_fn_attr(i, .NoDuplicate) m.not_duplicatable = true;
            if call_has_fn_attr(i, .Convergent) {
                if call_num_bundles(i) > 0 fatal("loop-rotate: convergence control tokens are not implemented yet");
                m.convergent = true;
            }
        }
        lo, hi := tti_code_size_bounds(i);
        m.num_insts_lo += lo;
        m.num_insts_hi += hi;
    }
    t := block_terminator(b);
    if t != NONE && inst_op(t) == .INDIRECTBR m.not_duplicatable = true;
}

// Function::hasOneLiveUse: one use that is not a dead constant user
fn_has_one_live_use :: (f: Value_Id) -> bool {
    n := 0;
    u := ir.v_first_use[f];
    while u != NONE {
        user := ir.u_user[u];
        dead_const := is_constant_kind(vkind(user)) && !is_global_value(vkind(user)) && !has_uses(user);
        if !dead_const n += 1;
        u = ir.u_next[u];
    }
    return n == 1;
}

// ---------------------------------------------------------------- block merging (BasicBlockUtils.cpp)

// FoldSingleEntryPHINodes
fold_single_entry_phi_nodes :: (b: Value_Id) -> bool {
    first := block_first(b);
    if first == NONE || inst_op(first) != .PHI return false;
    while true {
        pn := block_first(b);
        if pn == NONE || inst_op(pn) != .PHI break;
        if phi_value(pn, 0) != pn rauw_with_metadata(pn, phi_value(pn, 0));
        else rauw_with_metadata(pn, const_poison(vtype(pn)));
        erase_inst_with_metadata(pn);
    }
    return true;
}

// BasicBlock::eraseFromParent for an emptied block (validateDeleteBB already left only `unreachable`)
erase_block :: (b: Value_Id) {
    while block_last(b) != NONE {
        i := block_last(b);
        if has_uses(i) rauw_with_metadata(i, const_poison(vtype(i)));
        if inst(i).records { while inst(i).records dbgr_erase(inst(i).records); }
        erase_inst_with_metadata(i);
    }
    f := block_fn(b);
    fn_unlink_block(f, b);
    if vname(b).count set_name(b, "");
    ir.v_kind[b] = .DEAD;
}

// MergeBlockIntoPredecessor(BB, DTU (eager), LI, MSSAU, MemDep = null, PredecessorWithTwoSuccessors)
merge_block_into_predecessor :: (bb: Value_Id, dt: *Dom_Tree, li: *Loop_Info, mssau: *Mssa_Updater, pred_with_two_succs := false) -> bool {
    if block_has_address_taken(bb) return false;
    pred := block_unique_predecessor(bb);
    if pred == NONE return false;
    if pred == bb return false;
    pti := block_terminator(pred);
    po := inst_op(pti);
    if po == .CATCHSWITCH || po == .CATCHRET || po == .CLEANUPRET || po == .INVOKE || po == .RESUME || po == .CALLBR return false;
    if may_have_side_effects(pti) return false;
    if !pred_with_two_succs && block_unique_successor(pred) != bb return false;
    new_succ: Value_Id = NONE;
    fall_thru: u32 = 0;
    if pred_with_two_succs {
        if po != .CONDBR return false;
        jmp := block_terminator(bb);
        if inst_op(jmp) != .BR return false;
        new_succ = get_successor(jmp, 0);
        fall_thru = ifx get_successor(pti, 0) == bb then cast(u32) 0 else 1;
    }
    for pn: block_insts(bb) {
        if inst_op(pn) != .PHI break;
        n := nops(pn);
        for k: 0..n-1 if phi_value(pn, k) == pn return false;
    }
    // HasLoopOrEntryConvergenceToken
    for i: block_insts(bb) if call_iid(i) == IID_EXPERIMENTAL_CONVERGENCE_LOOP || call_iid(i) == IID_EXPERIMENTAL_CONVERGENCE_ENTRY
        fatal("MergeBlockIntoPredecessor with convergence tokens is not implemented yet");

    first := block_first(bb);
    if first != NONE && inst_op(first) == .PHI fold_single_entry_phi_nodes(bb);

    // DTU updates: inserts first, then deletes
    updates: [..] Dom_Update; updates.allocator = temp;
    if dt {
        succ_pred: [..] Value_Id; succ_pred.allocator = temp;
        block_successors(pred, *succ_pred);
        succs: [..] Value_Id; succs.allocator = temp;
        block_successors(bb, *succs);
        seen: [..] Value_Id; seen.allocator = temp;
        for s: succs {
            in_pred := false;
            for succ_pred if it == s in_pred = true;
            if in_pred continue;
            dup := false;
            for seen if it == s dup = true;
            if dup continue;
            array_add(*seen, s);
            array_add(*updates, .{true, pred, s});
        }
        seen.count = 0;
        for s: succs {
            dup := false;
            for seen if it == s dup = true;
            if dup continue;
            array_add(*seen, s);
            array_add(*updates, .{false, bb, s});
        }
        array_add(*updates, .{false, pred, bb});
    }

    sti := block_terminator(bb);
    start := block_first(bb);
    if start == sti start = pti;

    // PredBB->splice(PTI, BB, BB->begin(), STI) with its debug-record rules (Dest = PTI without head bit,
    // First = begin() with head bit, Last = STI reading its records)
    if block_first(bb) == sti {
        // spliceDebugInfoEmptyBlock: STI's records go to the end of PTI's
        if inst(sti).records records_append(pti, records_take(sti));
    } else {
        dest_recs := records_take(pti);
        if inst(sti).records records_prepend(pti, records_take(sti));
        move_first := block_first(bb);
        x := move_first;
        while x != sti {
            nx := inst_next(x);
            inst_unlink(x);
            inst_insert_before(x, pti);
            x = nx;
        }
        if dest_recs records_prepend(move_first, dest_recs);
    }
    if mssau mssau_move_all_after_merge_blocks(mssau, bb, pred, start);

    // BB->replaceAllUsesWith(PredBB): uses, then replaceSuccessorsPhiUsesWith
    replace_all_uses_with(bb, pred);
    block_replace_successors_phi_uses_with(bb, bb, pred);

    if pred_with_two_succs {
        erase_inst_with_metadata(block_last(bb));
        block_append_inst(bb, new_inst(.UNREACHABLE, ir.t_void, 0));
        set_successor(pti, fall_thru, new_succ);
    } else {
        // PredBB->back().eraseFromParent(): its records fall off the end and are flushed onto the moved terminator
        pend := records_take(pti);
        erase_inst_with_metadata(pti);
        t := block_last(bb);
        inst_unlink(t);
        block_append_inst(pred, t);
        if pend records_append(t, pend);
        block_append_inst(bb, new_inst(.UNREACHABLE, ir.t_void, 0));
        if mssau mssau_move_terminator_to_end(mssau, pred);
    }
    if vname(pred).count == 0 && vname(bb).count take_name(pred, bb);
    if li li_remove_block(li, bb);
    if dt && updates.count dt_apply_updates(dt, updates);
    // DeleteDeadBlock(BB, DTU): detachDeadBlocks (no successors left), DTU->deleteBB
    if dt && dt_node(dt, bb) >= 0 dt_erase_node(dt, bb);
    erase_block(bb);
    return true;
}

// DebugVariable key (variable, fragment, inlinedAt) as a string
dbg_variable_key :: (r: u32, with_fragment: bool) -> string {
    rec := dbgr(r);
    has, off, size := false, cast(u64) 0, cast(u64) 0;
    if with_fragment has, off, size = diexpr_fragment(rec.expr);
    ia := ifx rec.dbg != NONE then diloc_inlined_at(rec.dbg) else NONE;
    return tprint("%:%:%:%:%", rec.var, has, off, size, ia);
}

// RemoveRedundantDbgInstrs(BB) (assignment tracking: fails loudly)
remove_redundant_dbg_instrs :: (b: Value_Id) -> bool {
    changed := false;
    // removeRedundantDbgInstrsUsingBackwardScan (the variable set is per instruction)
    to_remove: [..] u32; to_remove.allocator = temp;
    recs: [..] u32; recs.allocator = temp;
    i := block_last(b);
    while i != NONE {
        recs.count = 0;
        x := inst(i).records;
        while x != 0 { array_add(*recs, x); x = dbgr(x).next; }
        seen: Table(string, bool); seen.allocator = temp;
        for < r: recs {
            if dbgr(r).kind == .LABEL continue;
            if dbgr(r).kind == .ASSIGN fatal("RemoveRedundantDbgInstrs with #dbg_assign is not implemented yet");
            key := dbg_variable_key(r, true);
            if !table_contains(*seen, key) { table_set(*seen, key, true); continue; }
            array_add(*to_remove, r);
        }
        i = inst_prev(i);
    }
    for to_remove dbgr_erase(it);
    changed |= to_remove.count > 0;
    // removeRedundantDbgInstrsUsingForwardScan
    Vm :: struct { vals: [..] Value_Id; expr: Md_Id; }
    vmap: Table(string, Vm); vmap.allocator = temp;
    vals: [..] Value_Id; vals.allocator = temp;
    for i2: block_insts(b) {
        x := inst(i2).records;
        while x != 0 {
            nx := dbgr(x).next;
            rec := dbgr(x);
            if rec.kind != .LABEL && rec.kind != .DECLARE {
                key := dbg_variable_key(x, false);
                dbgr_location_ops(x, *vals);
                e := table_find_pointer(*vmap, key);
                same := false;
                if e && e.expr == rec.expr && e.vals.count == vals.count {
                    same = true;
                    for vals if e.vals[it_index] != it { same = false; break; }
                }
                if !same {
                    nv: Vm; nv.vals.allocator = temp;
                    for vals array_add(*nv.vals, it);
                    nv.expr = rec.expr;
                    table_set(*vmap, key, nv);
                } else {
                    dbgr_erase(x);
                    changed = true;
                }
            }
            x = nx;
        }
    }
    return changed;
}

// Loop::setLoopID
li_set_loop_id :: (li: *Loop_Info, l: Loop_Id, id: Md_Id) {
    latches: [..] Value_Id; latches.allocator = temp;
    li_loop_latches(li, l, *latches);
    for latches set_metadata(block_terminator(it), MD_LOOP_KIND, id);
}

// insertDebugValuesForPHIs (Local.cpp)
insert_debug_values_for_phis :: (bb: Value_Id, inserted: [] Value_Id) {
    if inserted.count == 0 return;
    phi_rec: Table(Value_Id, u32); phi_rec.allocator = temp;
    vals: [..] Value_Id; vals.allocator = temp;
    for i: block_insts(bb) {
        x := inst(i).records;
        while x != 0 {
            if dbgr(x).kind != .LABEL {
                dbgr_location_ops(x, *vals);
                for v: vals if is_phi(v) && !table_contains(*phi_rec, v) table_set(*phi_rec, v, x);
            }
            x = dbgr(x).next;
        }
    }
    if phi_rec.count == 0 return;
    New :: struct { parent: Value_Id; old: u32; rec: Dbg_Record; }
    news: [..] New; news.allocator = temp;
    for phi: inserted {
        parent := inst_block(phi);
        fnp := block_first_non_phi(parent);
        if fnp != NONE && is_eh_pad(fnp) continue;
        n := nops(phi);
        for k: 0..n-1 {
            vi := phi_value(phi, k);
            found, old := table_find(*phi_rec, vi);
            if !found continue;
            idx := -1;
            for news if it.parent == parent && it.old == old { idx = it_index; break; }
            if idx < 0 {
                nr: New; nr.parent = parent; nr.old = old; nr.rec = dbgr(old).*;
                nr.rec.next = 0; nr.rec.owner = NONE;
                array_add(*news, nr);
                idx = news.count - 1;
            }
            rec := *news[idx].rec;
            if rec.loc != NONE && ir.mds[rec.loc].kind == .VALUE {
                if ir.mds[rec.loc].value == vi rec.loc = md_value(phi);
            } else fatal("insertDebugValuesForPHIs with a DIArgList location is not implemented yet");
        }
    }
    for news {
        array_add(*ir.dbg_records, it.rec);
        id := cast(u32) ir.dbg_records.count;
        dbgr_restamp(id);
        // insertDbgRecordBefore(DR, getFirstInsertionPt()) with the head bit: at the front
        pt := block_first_insertion_pt(it.parent);
        records_prepend(pt, id);
        if dbg_index.fn != NONE dbgr_index_record(id);
    }
}

// ---------------------------------------------------------------- LoopRotationUtils.cpp

// RewriteUsesOfClonedInstructions
rewrite_uses_of_cloned_instructions :: (orig_header: Value_Id, orig_ph: Value_Id, vm: *Table(Value_Id, Value_Id), inserted: *[..] Value_Id) {
    for :early_inc block_insts(orig_header) {
        if inst_op(it) != .PHI break;
        phi_remove_incoming_block(it, orig_ph);
    }
    ssa: Ssa_Updater;
    ssa.inserted_phis = inserted;
    f := block_fn(orig_header);
    i := block_first(orig_header);
    while i != NONE {
        v := i;
        i = inst_next(i);
        if !has_uses(v) continue;
        found, pre := table_find(vm, v);
        if !found pre = NONE;
        ssa_init(*ssa, vtype(v), vname(v));
        ssa_add_available(*ssa, orig_header, v);
        ssa_add_available(*ssa, orig_ph, pre);
        u := ir.v_first_use[v];
        while u != NONE {
            nx := ir.u_next[u];
            user := ir.u_user[u];
            if inst_op(user) != .PHI {
                ub := inst_block(user);
                if ub == orig_header { u = nx; continue; }
                if ub == orig_ph { use_set(u, pre); u = nx; continue; }
            }
            ssa_rewrite_use(*ssa, u);
            u = nx;
        }
        dvrs: [..] u32; dvrs.allocator = temp;
        find_dbg_users(f, v, *dvrs, true);
        for r: dvrs {
            ub := inst_block(dbgr(r).owner);
            if ub == orig_header continue;
            nv: Value_Id;
            if ub == orig_ph nv = pre;
            else if ssa_has_value(*ssa, ub) nv = ssa_value_in_middle(*ssa, ub);
            else nv = const_poison(vtype(v));
            dbgr_replace_variable_location_op(r, v, nv);
        }
        // the SSAUpdater may have inserted phis at the front of orig_header: they precede `i`, as in LLVM
    }
}

// profitableToRotateLoopExitingLatch(L, SE)
profitable_to_rotate_loop_exiting_latch :: (li: *Loop_Info, l: Loop_Id, check_exit_count: bool) -> bool {
    header := li_header(li, l);
    bi := block_terminator(header);
    header_exit := get_successor(bi, 0);
    if li_contains(li, l, header_exit) header_exit = get_successor(bi, 1);
    for pn: block_insts(header) {
        if inst_op(pn) != .PHI break;
        other := false;
        u := ir.v_first_use[pn];
        while u != NONE { if inst_block(ir.u_user[u]) != header_exit { other = true; break; } u = ir.u_next[u]; }
        if other continue;
        return true;
    }
    if check_exit_count fatal("loop-rotate<check-exit-count> needs ScalarEvolution (getExitCount), which is not implemented yet");
    return false;
}

// getBranchWeightMDNode + extractFromBranchWeightMD32 (isBranchWeightMD: >= 3 operands, "branch_weights" first,
// an optional "expected" origin)
branch_weights_of :: (t: Value_Id) -> (md: Md_Id, w: [] u32) {
    m := get_metadata(t, md_kind_id("prof"));
    if m == NONE || !md_is_node(m) || md_nops(m) < 3 return NONE, .[];
    s := md_op(m, 0);
    if s == NONE || ir.mds[s].kind != .STRING || ir.mds[s].str != "branch_weights" return NONE, .[];
    first: u32 = 1;
    o1 := md_op(m, 1);
    if o1 != NONE && ir.mds[o1].kind == .STRING && ir.mds[o1].str == "expected" first = 2;
    w := NewArray(md_nops(m) - first, u32,, allocator = temp);
    for k: first..md_nops(m)-1 {
        c := md_const_int_op(m, k);
        assert(c != NONE, "Malformed branch_weight in MD_prof node");
        w[k - first] = cast(u32) const_int_zext(c);
    }
    return m, w;
}

// setBranchWeights(I, Weights, IsExpected = false)
set_branch_weights :: (t: Value_Id, w: [] u32) {
    ops: [..] Md_Id; ops.allocator = temp;
    array_add(*ops, md_string("branch_weights"));
    i32 := type_int(32);
    for w array_add(*ops, md_value(const_int(i32, it)));
    set_metadata(t, md_kind_id("prof"), md_tuple(ops, false));
}

// updateBranchWeights
update_branch_weights :: (phbi: Value_Id, loop_bi: Value_Id, has_cond_ph: bool, swapped: bool) {
    wmd, w := branch_weights_of(phbi);
    if wmd == NONE return;
    lmd := branch_weights_of(loop_bi);
    if wmd != lmd return;
    if w.count != 2 return;
    exit_w := w[0]; back_w := w[1];
    if swapped { t := exit_w; exit_w = back_w; back_w = t; }
    ew0, ew1, enter_w, loopback_w: u32;
    if exit_w > 0 && back_w > 0 {
        ew0 = 0;
        if has_cond_ph {
            if back_w >= exit_w {
                ew0 = 1;
                while exit_w < 127 + ew0 {
                    hb: u32 = 0x8000_0000;
                    if (back_w & hb) != 0 || (exit_w & hb) != 0 break;
                    back_w <<= 1;
                    exit_w <<= 1;
                }
            } else ew0 = exit_w - back_w;
        } else {
            if exit_w > back_w back_w = exit_w;
        }
        ew1 = exit_w - ew0;
        enter_w = ew1;
        loopback_w = back_w - enter_w;
    } else if exit_w == 0 {
        if back_w == 0 { ew0 = 0; ew1 = 0; enter_w = 0; loopback_w = 0; }
        else { ew0 = 0; ew1 = 0; enter_w = 1; loopback_w = back_w; }
    } else {
        ew0 = 1; ew1 = 1; enter_w = 0; loopback_w = 0;
    }
    lw: [2] u32;
    lw[0] = ifx swapped then loopback_w else ew1;
    lw[1] = ifx swapped then ew1 else loopback_w;
    set_branch_weights(loop_bi, lw);
    if has_cond_ph {
        pw: [2] u32;
        pw[0] = ifx swapped then enter_w else ew0;
        pw[1] = ifx swapped then ew0 else enter_w;
        set_branch_weights(phbi, pw);
    }
}

// Loop::hasLoopInvariantOperands
li_has_loop_invariant_operands :: (li: *Loop_Info, l: Loop_Id, i: Value_Id) -> bool {
    n := nops(i);
    if n > 0 for k: 0..n-1 if !li_is_loop_invariant(li, l, op(i, k)) return false;
    return true;
}

// Hash key of a debug record for duplicate detection: (location ops, variable, expression)
dbg_record_hash :: (r: u32) -> string {
    vals: [..] Value_Id; vals.allocator = temp;
    dbgr_location_ops(r, *vals);
    sb: String_Builder; sb.allocator = temp;
    for vals print_to_builder(*sb, "%,", it);
    print_to_builder(*sb, "|%|%", dbgr(r).var, dbgr(r).expr);
    return builder_to_string(*sb,, allocator = temp);
}

// LoopRotate::rotateLoop
lr_rotate_loop :: (lr: *Loop_Rotate, l: Loop_Id, simplified_latch: bool) -> bool {
    li := lr.li;
    if li_num_blocks(li, l) == 1 return false;
    orig_header := li_header(li, l);
    orig_latch := li_loop_latch(li, l);
    bi := block_terminator(orig_header);
    if inst_op(bi) != .CONDBR return false;
    if !li_is_loop_exiting(li, l, orig_header) return false;
    if orig_latch == NONE return false;
    if li_is_loop_exiting(li, l, orig_latch) && !simplified_latch && !lr.is_util_mode &&
       !profitable_to_rotate_loop_exiting_latch(li, l, lr.check_exit_count) return false;
    {
        eph: Table(Value_Id, bool); eph.allocator = temp;
        collect_ephemeral_values(li, l, lr.ac, *eph);
        m: Code_Metrics;
        analyze_basic_block(*m, orig_header, *eph, lr.prepare_for_lto);
        if m.not_duplicatable return false;
        if m.convergent return false;
        if m.num_insts_lo > lr.max_header_size return false;
        if m.num_insts_hi > lr.max_header_size
            fatal("loop-rotate: the x86 code-size cost of header '%' (between % and % against a threshold of %) is not ported precisely enough to decide",
                  vname(orig_header), m.num_insts_lo, ifx m.num_insts_hi >= TTI_UNBOUNDED then -1 else m.num_insts_hi, lr.max_header_size);
        if lr.prepare_for_lto && m.num_inline_candidates > 0 return false;
    }
    orig_ph := li_loop_preheader(li, l);
    if orig_ph == NONE || !li_has_dedicated_exits(li, l) return false;

    exit := get_successor(bi, 0);
    new_header := get_successor(bi, 1);
    swapped := li_contains(li, l, exit);
    if swapped { t := exit; exit = new_header; new_header = t; }
    assert(block_single_predecessor(new_header) != NONE, "New header doesn't have one pred!");
    fold_single_entry_phi_nodes(new_header);

    vm: Table(Value_Id, Value_Id); vm.allocator = temp;
    vm_mssa: Table(Value_Id, Value_Id); vm_mssa.allocator = temp;
    i := block_first(orig_header);
    while i != NONE && inst_op(i) == .PHI {
        table_set(*vm, i, phi_value(i, cast(u32) phi_block_index(i, orig_ph)));
        i = inst_next(i);
    }
    leb := block_terminator(orig_ph);
    seen_hashes: Table(string, bool); seen_hashes.allocator = temp;
    {
        x := inst(leb).records;
        while x != 0 { if dbgr(x).kind != .LABEL table_set(*seen_hashes, dbg_record_hash(x), true); x = dbgr(x).next; }
    }
    for x: block_insts(orig_header) if call_iid(x) == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL
        fatal("loop-rotate: cloning llvm.experimental.noalias.scope.decl scopes is not implemented yet");
    f := block_fn(orig_header);
    presplit := fn_has_fn_attr(f, .PresplitCoroutine);
    q: Simplify_Query;
    q.dt = lr.dt; q.ac = lr.ac;
    next_dbg: u32 = ifx i != NONE then inst(i).records else 0;
    cloned: [..] u32; cloned.allocator = temp;
    erase_seen :: (cloned: [] u32, seen: *Table(string, bool)) {
        for cloned if dbgr(it).kind != .LABEL && table_contains(seen, dbg_record_hash(it)) dbgr_erase(it);
    }
    while i != NONE {
        cur := i;
        i = inst_next(i);
        if li_has_loop_invariant_operands(li, l, cur) && !may_read_from_memory(cur) && !may_write_to_memory(cur) &&
           !is_terminator(inst_op(cur)) && inst_op(cur) != .ALLOCA && !presplit {
            if next_dbg != 0 {
                clone_debug_info_from(leb, cur, next_dbg, *cloned);
                remap_dbg_records(cloned, *vm);
                erase_seen(cloned, *seen_hashes);
            }
            next_dbg = inst(i).records;
            inst_move_before_dbg(cur, leb);
            continue;
        }
        c := inst_clone(cur);
        dl := get_metadata(c, 0);
        if dl != NONE && di_int(dl, 3) != 0 fatal("loop-rotate: key-instruction atom groups (mapAtomInstance) are not implemented yet");
        insert_at_position(c, orig_ph, leb, false);
        if next_dbg != 0 {
            clone_debug_info_from(c, cur, next_dbg, *cloned);
            remap_dbg_records(cloned, *vm);
            next_dbg = 0;
            erase_seen(cloned, *seen_hashes);
        }
        // RemapInstruction(C, ValueMap, RF_NoModuleLevelChanges | RF_IgnoreMissingLocals)
        n := nops(c);
        if n > 0 for k: 0..n-1 {
            o := op(c, k);
            if o == NONE continue;
            if vkind(o) == .MD_VALUE {
                m := ir.v_aux[o];
                if m != NONE && ir.mds[m].kind == .VALUE && table_contains(*vm, ir.mds[m].value)
                    fatal("loop-rotate: remapping a metadata-as-value operand is not implemented yet");
                continue;
            }
            found, nv := table_find(*vm, o);
            if found set_op(c, k, nv);
        }
        v := simplify_instruction(c, q);
        if v != NONE && li_replacement_preserves_lcssa_form(li, c, v) {
            table_set(*vm, cur, v);
            if !may_have_side_effects(c) {
                erase_inst_with_metadata(c);
                c = NONE;
            }
        } else table_set(*vm, cur, c);
        if c != NONE {
            if vname(cur).count set_name(c, vname(cur));
            if is_intrinsic_call(c, IID_ASSUME) ac_register_assumption(lr.ac, c);
            if lr.mssau table_set(*vm_mssa, cur, c);
        }
    }

    // fix up the phis of orig_header's successors
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(orig_header, *succs);
    for s: succs for pn: block_insts(s) {
        if inst_op(pn) != .PHI break;
        phi_add_incoming(pn, phi_value(pn, cast(u32) phi_block_index(pn, orig_header)), orig_ph);
    }
    // LoopEntryBranch->eraseFromParent(); OrigPreheader->flushTerminatorDbgRecords()
    {
        pend := records_take(leb);
        erase_inst_with_metadata(leb);
        if pend records_append(block_last(orig_ph), pend);
    }
    if lr.mssau {
        table_set(*vm_mssa, orig_header, orig_ph);
        mssau_update_for_cloned_block_into_pred(lr.mssau, orig_header, orig_ph, *vm_mssa);
    }
    inserted: [..] Value_Id; inserted.allocator = temp;
    rewrite_uses_of_cloned_instructions(orig_header, orig_ph, *vm, *inserted);
    if inserted.count insert_debug_values_for_phis(orig_header, inserted);

    li_move_to_header(li, l, new_header);
    dt := lr.dt;
    if dt {
        updates: [..] Dom_Update; updates.allocator = temp;
        array_add(*updates, .{true, orig_ph, exit});
        array_add(*updates, .{true, orig_ph, new_header});
        array_add(*updates, .{false, orig_ph, orig_header});
        if lr.mssau mssau_apply_updates(lr.mssau, updates, dt, true);
        else dt_apply_updates(dt, updates);
    }
    phbi := block_terminator(orig_ph);
    cond := op(phbi, 0);
    has_cond_ph := vkind(cond) != .C_INT || get_successor(phbi, ifx const_int_zext(cond) == 0 then cast(u32) 1 else 0) != new_header;
    update_branch_weights(phbi, bi, has_cond_ph, swapped);
    if has_cond_ph {
        o: Crit_Edge_Options;
        o.dt = dt; o.li = li; o.mssau = lr.mssau; o.preserve_lcssa = true;
        k: u32 = 0;
        while get_successor(phbi, k) != new_header k += 1;
        new_ph := split_critical_edge(phbi, k, *o);
        set_name(new_ph, tprint("%.lr.ph", vname(new_header)));
        exit_preds: [..] Value_Id; exit_preds.allocator = temp;
        block_predecessors(exit, *exit_preds);
        for ep: exit_preds {
            pl := li_loop_for(li, ep);
            if pl == NONE || li_contains(li, pl, exit) || inst_op(block_terminator(ep)) == .INDIRECTBR continue;
            et := block_terminator(ep);
            j: u32 = 0;
            while get_successor(et, j) != exit j += 1;
            split := split_critical_edge(et, j, *o);
            // ExitSplit->moveBefore(Exit)
            fn_unlink_block(f, split);
            fn_insert_block_before(f, exit, split);
        }
    } else {
        block_remove_predecessor(exit, orig_ph, true);
        nbi := create_br(new_header);
        insert_at_position(nbi, orig_ph, phbi, false);
        copy_debug_loc(nbi, phbi);
        erase_inst_with_metadata(phbi);
        if dt dt_delete_edge(dt, orig_ph, exit);
        if lr.mssau mssau_remove_edge(lr.mssau, orig_ph, exit);
    }
    pred_bb := block_unique_predecessor(orig_header);
    if merge_block_into_predecessor(orig_header, dt, li, lr.mssau) remove_redundant_dbg_instrs(pred_bb);
    return true;
}

// shouldSpeculateInstrs(Begin, End, L)
should_speculate_instrs :: (li: *Loop_Info, l: Loop_Id, begin: Value_Id, end: Value_Id) -> bool {
    seen_increment := false;
    multi_exit := li_exiting_block(li, l) == NONE;
    i := begin;
    while i != end {
        opc := inst_op(i);
        // isSafeToSpeculativelyExecute is true for every opcode the switch below accepts; the rest return false
        // either way
        if !(opc == .GEP || opc == .ADD || opc == .SUB || opc == .AND || opc == .OR || opc == .XOR || opc == .SHL ||
             opc == .LSHR || opc == .ASHR || opc == .TRUNC || opc == .ZEXT || opc == .SEXT) return false;
        if opc == {
            case .GEP; #through;
            case .ADD; #through; case .SUB; #through; case .AND; #through; case .OR; #through; case .XOR; #through;
            case .SHL; #through; case .LSHR; #through; case .ASHR;
                if opc == .GEP && !gep_has_all_constant_indices(i) return false;
                iv: Value_Id = NONE;
                if !is_constant_kind(vkind(op(i, 0))) iv = op(i, 0);
                else if !is_constant_kind(vkind(op(i, 1))) iv = op(i, 1);
                if iv == NONE return false;
                if multi_exit {
                    u := ir.v_first_use[iv];
                    while u != NONE {
                        if !li_contains_inst(li, l, ir.u_user[u]) return false;
                        u = ir.u_next[u];
                    }
                }
                if seen_increment return false;
                seen_increment = true;
            case .TRUNC; #through; case .ZEXT; #through; case .SEXT;
            case; return false;
        }
        i = inst_next(i);
    }
    return true;
}


// LoopRotate::simplifyLoopLatch
lr_simplify_loop_latch :: (lr: *Loop_Rotate, l: Loop_Id) -> bool {
    li := lr.li;
    latch := li_loop_latch(li, l);
    if latch == NONE || block_has_address_taken(latch) return false;
    jmp := block_terminator(latch);
    if inst_op(jmp) != .BR return false;
    last_exit := block_single_predecessor(latch);
    if last_exit == NONE || !li_is_loop_exiting(li, l, last_exit) return false;
    lo := inst_op(block_terminator(last_exit));
    if lo != .BR && lo != .CONDBR return false;
    if !should_speculate_instrs(li, l, block_first(latch), jmp) return false;
    merge_block_into_predecessor(latch, lr.dt, li, lr.mssau, true);
    return true;
}

// LoopRotate::processLoop
lr_process_loop :: (lr: *Loop_Rotate, l: Loop_Id) -> bool {
    loop_md := li_loop_id(lr.li, l);
    simplified := false;
    if !lr.rotation_only simplified = lr_simplify_loop_latch(lr, l);
    made := lr_rotate_loop(lr, l, simplified);
    if (made || simplified) && loop_md != NONE li_set_loop_id(lr.li, l, loop_md);
    return made || simplified;
}

// LoopRotatePass::run
loop_rotate_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    header_dup := true; prepare_for_lto := false; check_exit_count := false;
    name := node.name;
    if name.count > "loop-rotate".count {
        params := slice(name, "loop-rotate<".count, name.count - "loop-rotate<".count - 1);
        for p: split(params, ";") {
            enable := !begins_with(p, "no-");
            pn := ifx enable then p else slice(p, 3, p.count - 3);
            if pn == "header-duplication" header_dup = enable;
            else if pn == "prepare-for-lto" prepare_for_lto = enable;
            else if pn == "check-exit-count" check_exit_count = enable;
            else fatal("invalid LoopRotate pass parameter '%'", pn);
        }
    }
    f := lar.fn;
    minsize := fn_has_fn_attr(f, .MinSize);
    if minsize && li_loop_id(lar.li, l) != NONE fatal("loop-rotate: hasVectorizeTransformation on a minsize function is not implemented yet");
    threshold: s64 = 0;
    if header_dup && (!minsize || lr_opts.enable_header_dup_at_minsize) threshold = lr_opts.rotation_max_header_size;
    mssau_storage: Mssa_Updater;
    lr: Loop_Rotate;
    lr.max_header_size = threshold;
    lr.li = lar.li; lr.ac = lar.ac; lr.dt = lar.dt;
    if lar.mssa { mssau_storage.mssa = lar.mssa; lr.mssau = *mssau_storage; }
    lr.rotation_only = false;
    lr.is_util_mode = false;
    lr.prepare_for_lto = prepare_for_lto || lr_opts.rotation_prepare_for_lto;
    lr.check_exit_count = check_exit_count;
    if !lr_process_loop(*lr, l) return PRESERVE_ALL;
    pa := loop_pass_preserved();
    if lar.mssa preserve(*pa, .MEMORYSSA);
    return pa;
}
