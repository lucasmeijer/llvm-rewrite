// SCEVExpander: generate IR that computes a SCEV.
// Port of llvm/lib/Transforms/Utils/ScalarEvolutionExpander.cpp and
// llvm/include/llvm/Transforms/Utils/ScalarEvolutionExpander.h (LLVM 23.1.5): PoisonFlags, ReuseOrCreateCast,
// findInsertPointAfter, eraseDeadInstructions, GetOptimalInsertionPointForCastOf, InsertNoopCastOfTo, InsertBinop,
// expandAddToGEP, getRelevantLoop / PickMostRelevantLoop / LoopCompare, the visit* methods, isNormalAddRecExprPHI,
// getIVIncOperand, fixupInsertPoints, hoistIVInc, canReuseFlagsFromOriginalIVInc, isExpandedAddRecExprPHI,
// expandIVInc, canBeCheaplyTransformed, IsIncrementNSW/NUW, getAddRecExprPHILiterally, expandAddRecExprLiterally,
// tryToReuseLCSSAPhi, expandMinMaxExpr, expandCodeFor, FindValueInExprValueMap, expand, rememberInstruction,
// rememberFlags, dropPoisonGeneratingAnnotationsAndReinfer, replaceCongruentIVInc, replaceCongruentIVs,
// hasRelatedExistingExpansion, costAndCollectOperands, isHighCostExpansion(Helper), expandCodeForPredicate and
// the predicate expansions, generateOverflowCheck, fixupLCSSAFormFor, SCEVFindUnsafe / isSafeToExpand(At),
// SCEVExpanderCleaner::cleanup.
// Also the ScalarEvolution.cpp queries only the expander and IndVarSimplify use: canReuseInstruction,
// getStrengthenedNoWrapFlagsFromBinOp, getWiderType, and Loop::getCanonicalInductionVariable (LoopInfo.cpp),
// LoopInfo::movementPreservesLCSSAForm (LoopInfo.h), normalizeForPostIncUse (ScalarEvolutionNormalization.cpp).
//
// Data-oriented: a `Scev_Expander` struct on the caller's stack holds all of SCEVExpander's state (the maps are temp
// tables; InsertedExpressions' TrackingVH values are value_handles.jai slots). The IRBuilder is an `Irb` used with
// InstSimplifyFolder semantics (sx_create_*: fold with InstSimplify, else insert at the builder's position and
// rememberInstruction, the IRBuilderCallbackInserter). SCEVInsertPointGuard is sx_guard_push/sx_guard_pop around a
// region; the guard stack lets fixupInsertPoints move saved insertion points. The visitor is the `if sc_kind(s) ==`
// switch in sx_visit. The ScalarEvolution is the global `se`; its DominatorTree and LoopInfo are se.dt / se.li.

// cl::opt scev-cheap-expansion-budget
scev_cheap_expansion_budget: s64 = 4;

// BasicBlock::iterator: `pt` is the instruction (NONE = end()), `head` the head-inclusive bit
Sx_It :: struct { bb: Value_Id = NONE; pt: Value_Id = NONE; head: bool; }

Sx_Guard :: struct { bb: Value_Id; pt: Value_Id; head: bool; dbg: Md_Id; }

// SCEVOperand
Sx_Operand :: struct { parent_op: Opcode; has_parent: bool; operand_idx: s32; s: Scev_Id; }

// PoisonFlags: the poison-generating flag bits of an instruction (nuw/nsw on binops and trunc, exact, disjoint,
// nneg, samesign share F_EXACT, GEP no-wrap flags)
SX_POISON_FLAG_BITS :: F_NUW | F_NSW | F_EXACT | F_INBOUNDS | F_NUSW | F_GEP_NUW;

Scev_Expander :: struct {
    ivname: string;
    preserve_lcssa: bool = true;
    inserted_expressions: Table(u64, Vh);          // (SCEV, insert point) -> TrackingVH<Value>
    inserted_values: Table(Value_Id, bool);        // DenseSet<AssertingVH<Value>>
    inserted_values_order: [..] Value_Id;          // insertion order (getAllInsertedInstructions iterates the set)
    inserted_post_inc_values: Table(Value_Id, bool);
    inserted_post_inc_order: [..] Value_Id;
    reused_values: Table(Value_Id, bool);
    orig_flags: Table(Value_Id, u32);              // DenseMap<PoisoningVH<Instruction>, PoisonFlags>
    orig_flags_order: [..] Value_Id;
    inserted_ivs: [..] Value_Id;                   // SmallVector<WeakVH>
    relevant_loops: Table(Scev_Id, Loop_Id);
    post_inc_loops: [..] Loop_Id;                  // PostIncLoopSet
    iv_inc_insert_loop: Loop_Id = NONE;
    iv_inc_insert_pos: Value_Id = NONE;
    chained_phis: Table(Value_Id, bool);
    canonical_mode := true;
    lsr_mode: bool;
    safe_udiv_mode: bool;
    b: Irb;
    guards: [..] Sx_Guard;                         // InsertPointGuards
}

// SCEVExpander(SE, Name, PreserveLCSSA)
sx_init :: (x: *Scev_Expander, name: string, preserve_lcssa := true) {
    x.ivname = name;
    x.preserve_lcssa = preserve_lcssa;
    x.inserted_expressions.allocator = temp; x.inserted_values.allocator = temp; x.inserted_values_order.allocator = temp;
    x.inserted_post_inc_values.allocator = temp; x.inserted_post_inc_order.allocator = temp;
    x.reused_values.allocator = temp; x.orig_flags.allocator = temp; x.orig_flags_order.allocator = temp;
    x.inserted_ivs.allocator = temp; x.relevant_loops.allocator = temp; x.post_inc_loops.allocator = temp;
    x.chained_phis.allocator = temp; x.guards.allocator = temp;
}

// clear()
sx_clear :: (x: *Scev_Expander) {
    table_reset(*x.inserted_expressions);
    table_reset(*x.inserted_values); x.inserted_values_order.count = 0;
    table_reset(*x.inserted_post_inc_values); x.inserted_post_inc_order.count = 0;
    table_reset(*x.reused_values);
    table_reset(*x.orig_flags); x.orig_flags_order.count = 0;
    table_reset(*x.chained_phis);
    x.inserted_ivs.count = 0;
}

sx_disable_canonical_mode :: (x: *Scev_Expander) { x.canonical_mode = false; }
sx_enable_lsr_mode :: (x: *Scev_Expander) { x.lsr_mode = true; }
sx_set_iv_inc_insert_pos :: (x: *Scev_Expander, l: Loop_Id, pos: Value_Id) {
    assert(!x.canonical_mode, "IV increment positions are not supported in CanonicalMode");
    x.iv_inc_insert_loop = l; x.iv_inc_insert_pos = pos;
}
sx_set_post_inc :: (x: *Scev_Expander, loops: [] Loop_Id) {
    assert(!x.canonical_mode, "Post-inc expansion is not supported in CanonicalMode");
    x.post_inc_loops.count = 0;
    for loops array_add(*x.post_inc_loops, it);
}
sx_clear_post_inc :: (x: *Scev_Expander) {
    x.post_inc_loops.count = 0;
    table_reset(*x.inserted_post_inc_values); x.inserted_post_inc_order.count = 0;
}
sx_set_chained_phi :: (x: *Scev_Expander, pn: Value_Id) { table_set(*x.chained_phis, pn, true); }
// setInsertPoint(Instruction *)
sx_set_insert_point :: (x: *Scev_Expander, i: Value_Id) { irb_set_before(*x.b, i); }
// setInsertPoint(BasicBlock::iterator)
sx_set_insert_point_it :: (x: *Scev_Expander, it: Sx_It) { irb_set_at(*x.b, it.bb, it.pt, it.head); }
// clearInsertPoint()
sx_clear_insert_point :: (x: *Scev_Expander) { x.b.bb = NONE; x.b.pt = NONE; x.b.head = false; }
sx_builder_it :: (x: *Scev_Expander) -> Sx_It { return .{x.b.bb, x.b.pt, x.b.head}; }

sx_post_inc_contains :: (x: *Scev_Expander, l: Loop_Id) -> bool { for x.post_inc_loops if it == l return true; return false; }

// isInsertedInstruction
sx_is_inserted_instruction :: (x: *Scev_Expander, i: Value_Id) -> bool {
    if i == NONE return false;
    return table_contains(*x.inserted_values, i) || table_contains(*x.inserted_post_inc_values, i);
}

// getAllInsertedInstructions
sx_all_inserted_instructions :: (x: *Scev_Expander, out: *[..] Value_Id) {
    for x.inserted_values_order {
        if !table_contains(*x.inserted_values, it) continue;
        if table_contains(*x.reused_values, it) continue;
        if is_inst(it) array_add(out, it);
    }
    for x.inserted_post_inc_order {
        if !table_contains(*x.inserted_post_inc_values, it) continue;
        if table_contains(*x.reused_values, it) continue;
        if is_inst(it) array_add(out, it);
    }
}

sx_set_insert :: (set: *Table(Value_Id, bool), order: *[..] Value_Id, v: Value_Id) {
    if table_contains(set, v) return;
    table_set(set, v, true);
    array_add(order, v);
}

// rememberInstruction
sx_remember_instruction :: (x: *Scev_Expander, i: Value_Id) {
    if x.post_inc_loops.count sx_set_insert(*x.inserted_post_inc_values, *x.inserted_post_inc_order, i);
    else sx_set_insert(*x.inserted_values, *x.inserted_values_order, i);
}
// rememberFlags: keep the first recorded flags
sx_remember_flags :: (x: *Scev_Expander, i: Value_Id) {
    if table_contains(*x.orig_flags, i) return;
    table_set(*x.orig_flags, i, inst(i).flags & SX_POISON_FLAG_BITS);
    array_add(*x.orig_flags_order, i);
}

// ---------------------------------------------------------------- insertion point guards

// SCEVInsertPointGuard constructor
sx_guard_push :: (x: *Scev_Expander) -> s64 {
    array_add(*x.guards, .{x.b.bb, x.b.pt, x.b.head, x.b.dbg});
    return x.guards.count - 1;
}
// ~SCEVInsertPointGuard: restoreIP(Block, Point), then the saved debug location
sx_guard_pop :: (x: *Scev_Expander, idx: s64) {
    assert(idx == x.guards.count - 1, "SCEVInsertPointGuard destroyed out of order");
    g := x.guards[idx];
    x.guards.count -= 1;
    if g.bb != NONE irb_set_at(*x.b, g.bb, g.pt, g.head);
    else { x.b.bb = NONE; x.b.pt = NONE; x.b.head = false; }
    x.b.dbg = g.dbg;
}

// fixupInsertPoints
sx_fixup_insert_points :: (x: *Scev_Expander, i: Value_Id) {
    nxt := inst_next(i);
    if x.b.pt == i {
        if nxt == NONE fatal("SCEVExpander: insertion point moved past the end of its block");
        irb_set_before(*x.b, nxt);
    }
    for * g: x.guards if g.pt == i { g.pt = nxt; g.head = false; }
}

// ---------------------------------------------------------------- IRBuilder<InstSimplifyFolder, IRBuilderCallbackInserter>

sx_q :: () -> Simplify_Query { q: Simplify_Query; q.have_tli = false; return q; }   // SimplifyQuery(DL)

sx_insert :: (x: *Scev_Expander, i: Value_Id, name: string = "") -> Value_Id {
    irb_insert(*x.b, i, name);
    sx_remember_instruction(x, i);
    return i;
}
// CreateNoWrapBinOp / CreateAdd / CreateSub / CreateBinOp
sx_create_binop :: (x: *Scev_Expander, opc: Opcode, l: Value_Id, r: Value_Id, name: string = "", nuw := false, nsw := false) -> Value_Id {
    f := simplify_binop(opc, l, r, sx_q());
    if f != NONE return f;
    i := new_inst(opc, vtype(l), 2);
    set_op(i, 0, l); set_op(i, 1, r);
    if nuw inst(i).flags |= F_NUW;
    if nsw inst(i).flags |= F_NSW;
    return sx_insert(x, i, name);
}
// CreateCast
sx_create_cast :: (x: *Scev_Expander, opc: Opcode, v: Value_Id, ty: Type_Id, name: string = "") -> Value_Id {
    if vtype(v) == ty return v;
    f := simplify_cast_inst(opc, v, ty, sx_q());
    if f != NONE return f;
    i := new_inst(opc, ty, 1);
    set_op(i, 0, v);
    return sx_insert(x, i, name);
}
// CreateTrunc(V, DestTy, Name, IsNUW, IsNSW)
sx_create_trunc :: (x: *Scev_Expander, v: Value_Id, ty: Type_Id, name: string = "", nuw := false, nsw := false) -> Value_Id {
    if vtype(v) == ty return v;
    f := simplify_cast_inst(.TRUNC, v, ty, sx_q());
    if f != NONE return f;
    i := new_inst(.TRUNC, ty, 1);
    set_op(i, 0, v);
    if nuw inst(i).flags |= F_NUW;
    if nsw inst(i).flags |= F_NSW;
    return sx_insert(x, i, name);
}
// CreateZExt(V, DestTy, Name, IsNonNeg)
sx_create_zext :: (x: *Scev_Expander, v: Value_Id, ty: Type_Id, name: string = "", nneg := false) -> Value_Id {
    if vtype(v) == ty return v;
    f := simplify_cast_inst(.ZEXT, v, ty, sx_q());
    if f != NONE return f;
    i := new_inst(.ZEXT, ty, 1);
    set_op(i, 0, v);
    sx_insert(x, i, name);
    if nneg inst(i).flags |= F_EXACT;
    return i;
}
// CreateICmp
sx_create_icmp :: (x: *Scev_Expander, pred: u8, l: Value_Id, r: Value_Id, name: string = "") -> Value_Id {
    f := simplify_cmp_inst(pred, false, l, r, sx_q());
    if f != NONE return f;
    return sx_insert(x, create_icmp(pred, l, r), name);
}
// CreateSelect
sx_create_select :: (x: *Scev_Expander, c: Value_Id, t: Value_Id, f: Value_Id, name: string = "") -> Value_Id {
    s := simplify_select_inst(c, t, f, 0, sx_q());
    if s != NONE return s;
    i := new_inst(.SELECT, vtype(t), 3);
    set_op(i, 0, c); set_op(i, 1, t); set_op(i, 2, f);
    return sx_insert(x, i, name);
}
// CreatePtrAdd(Ptr, Offset, Name, NW) = CreateGEP(i8, ...)
sx_create_ptr_add :: (x: *Scev_Expander, ptr: Value_Id, off: Value_Id, name: string = "", nw: u32 = 0) -> Value_Id {
    f := simplify_gep_inst(ir.t_i8, ptr, .[off], nw, sx_q());
    if f != NONE return f;
    i := new_inst(.GEP, irb_gep_result_type(ptr, .[off]), 2);
    inst(i).flags = nw; inst(i).ty2 = ir.t_i8;
    set_op(i, 0, ptr); set_op(i, 1, off);
    return sx_insert(x, i, name);
}
// CreateFreeze (never folded)
sx_create_freeze :: (x: *Scev_Expander, v: Value_Id, name: string = "") -> Value_Id {
    i := new_inst(.FREEZE, vtype(v), 1);
    set_op(i, 0, v);
    return sx_insert(x, i, name);
}
// CreateIntrinsic(ID, OverloadTypes, Args, FMFSource, Name): FoldIntrinsic = simplifyIntrinsic
sx_create_intrinsic :: (x: *Scev_Expander, name: string, otys: [] Type_Id, args: [] Value_Id, vname_: string = "") -> Value_Id {
    id := intrinsic_id_by_name(name);
    rt := func_ret(intrinsic_type(id, otys));   // Intrinsic::getType: no declaration unless the call is created
    f := simplify_intrinsic(id, rt, args, 0, sx_q(), block_fn(x.b.bb), 0, 0);
    if f != NONE return f;
    decl := get_or_insert_intrinsic_declaration(id, otys);
    i := new_inst(.CALL, rt, cast(u32)(args.count + 1));
    inst(i).ty2 = glob(decl).value_type;
    for args set_op(i, cast(u32) it_index, it);
    set_op(i, cast(u32) args.count, decl);
    return sx_insert(x, i, vname_);
}
// CreatePHI
sx_create_phi :: (x: *Scev_Expander, ty: Type_Id, reserved: u32, name: string = "") -> Value_Id {
    return sx_insert(x, create_phi(ty, reserved), name);
}

// ---------------------------------------------------------------- iterators

// std::next(iterator): the head bit is cleared
sx_it_next :: (it: Sx_It) -> Sx_It { r := it; r.pt = inst_next(it.pt); r.head = false; return r; }
// Instruction::getIterator()
sx_it_of :: (i: Value_Id) -> Sx_It { return .{inst_block(i), i, false}; }
// BasicBlock::getFirstInsertionPt()
sx_first_insertion_pt :: (b: Value_Id) -> Sx_It { return .{b, block_first_insertion_pt(b), true}; }
// BasicBlock::begin()
sx_block_begin :: (b: Value_Id) -> Sx_It { return .{b, block_first(b), true}; }

// Instruction::getInsertionPointAfterDef: (ok, iterator)
sx_insertion_point_after_def :: (i: Value_Id) -> (bool, Sx_It) {
    it: Sx_It;
    o := inst_op(i);
    if o == .PHI it = sx_first_insertion_pt(inst_block(i));
    else if o == .INVOKE it = sx_first_insertion_pt(get_successor(i, 0));
    else if o == .CALLBR return false, .{};
    else { it.bb = inst_block(i); it.pt = inst_next(i); it.head = true; }
    if it.pt == NONE return false, .{};
    return true, it;
}

// ---------------------------------------------------------------- ScalarEvolution / LoopInfo helpers

// ScalarEvolution::getWiderType
sc_get_wider_type :: (t1: Type_Id, t2: Type_Id) -> Type_Id { return ifx sc_type_bits(t1) >= sc_type_bits(t2) then t1 else t2; }

// ScalarEvolution::canReuseInstruction
sc_can_reuse_instruction :: (s: Scev_Id, i: Value_Id, drops: *[..] Value_Id) -> bool {
    if program_undefined_if_poison(i) return true;
    poison_vals: [..] Value_Id; poison_vals.allocator = temp;
    sc_get_poison_generating_values(*poison_vals, s);
    work: [..] Value_Id; work.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    array_add(*work, i);
    while work.count {
        v := pop(*work);
        if table_contains(*visited, v) continue;
        table_set(*visited, v, true);
        if visited.count > 16 return false;
        in_pv := false;
        for poison_vals if it == v { in_pv = true; break; }
        if in_pv || is_guaranteed_not_to_be_poison(v) continue;
        if !is_inst(v) return false;
        if inst_op(v) == .OR && (inst(v).flags & F_EXACT) return false;   // disjoint or
        if call_iid(v) == IID_VSCALE continue;
        if can_create_poison(v, false) return false;
        if has_poison_generating_annotations(v) array_add(drops, v);
        for k: 0..cast(s64) nops(v) - 1 array_add(*work, op(v, cast(u32) k));
    }
    return true;
}

// ScalarEvolution::getStrengthenedNoWrapFlagsFromBinOp: (has_value, flags)
sc_get_strengthened_no_wrap_flags_from_bin_op :: (obo: Value_Id) -> (bool, u8) {
    fl := inst(obo).flags;
    if (fl & F_NUW) && (fl & F_NSW) return false, 0;
    flags := SF_ANY;
    if fl & F_NUW flags |= SF_NUW;
    if fl & F_NSW flags |= SF_NSW;
    deduced := false;
    opc := inst_op(obo);
    if opc != .ADD && opc != .SUB && opc != .MUL return false, 0;
    lhs := sc_get_scev(op(obo, 0));
    rhs := sc_get_scev(op(obo, 1));
    cxt: Value_Id = ifx scev_opts.use_context_for_no_wrap_flag_inference then obo else NONE;
    if !(fl & F_NUW) && sc_will_not_overflow(opc, false, lhs, rhs, cxt) { flags |= SF_NUW; deduced = true; }
    if !(fl & F_NSW) && sc_will_not_overflow(opc, true, lhs, rhs, cxt) { flags |= SF_NSW; deduced = true; }
    if deduced return true, flags;
    return false, 0;
}

// is `i` an OverflowingBinaryOperator (add, sub, mul, shl)?
sx_is_obo :: (i: Value_Id) -> bool {
    if !is_inst(i) return false;
    o := inst_op(i);
    return o == .ADD || o == .SUB || o == .MUL || o == .SHL;
}
// setHasNoUnsignedWrap / setHasNoSignedWrap
sx_set_nuw :: (i: Value_Id, b: bool) { if b inst(i).flags |= F_NUW; else inst(i).flags &= ~cast(u32) F_NUW; }
sx_set_nsw :: (i: Value_Id, b: bool) { if b inst(i).flags |= F_NSW; else inst(i).flags &= ~cast(u32) F_NSW; }
sx_has_nuw :: (i: Value_Id) -> bool { return (inst(i).flags & F_NUW) != 0; }
sx_has_nsw :: (i: Value_Id) -> bool { return (inst(i).flags & F_NSW) != 0; }

// Loop::getCanonicalInductionVariable
li_canonical_induction_variable :: (li: *Loop_Info, l: Loop_Id) -> Value_Id {
    h := li_header(li, l);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(h, *preds);
    // getIncomingAndBackEdge
    if preds.count != 2 return NONE;
    incoming := preds[0]; backedge := preds[1];
    if li_contains(li, l, incoming) {
        if li_contains(li, l, backedge) return NONE;
        incoming, backedge = backedge, incoming;
    } else if !li_contains(li, l, backedge) return NONE;
    for pn: block_insts(h) {
        if inst_op(pn) != .PHI break;
        ci := phi_incoming_value_for_block(pn, incoming);
        if vkind(ci) != .C_INT || !ap_is_zero(const_ap(ci)) continue;
        inc := phi_incoming_value_for_block(pn, backedge);
        if !is_inst(inc) || inst_op(inc) != .ADD || op(inc, 0) != pn continue;
        c := op(inc, 1);
        if vkind(c) == .C_INT && ap_is_one(const_ap(c)) return pn;
    }
    return NONE;
}

// LoopInfo::movementPreservesLCSSAForm
li_movement_preserves_lcssa_form :: (li: *Loop_Info, i: Value_Id, new_loc: Value_Id) -> bool {
    old_bb := inst_block(i);
    new_bb := inst_block(new_loc);
    if old_bb == new_bb return true;
    old_l := li_loop_for(li, old_bb);
    new_l := li_loop_for(li, new_bb);
    if old_l == new_l return true;
    contains :: (li: *Loop_Info, outer: Loop_Id, inner: Loop_Id) -> bool { return outer == NONE || li_contains_loop(li, outer, inner); }
    if !contains(li, new_l, old_l) {
        u := ir.v_first_use[i];
        while u != NONE {
            ui := ir.u_user[u];
            ubb := ifx inst_op(ui) == .PHI then ir.u_aux[u] else inst_block(ui);
            if ubb != new_bb && li_loop_for(li, ubb) != new_l return false;
            u = ir.u_next[u];
        }
    }
    if !contains(li, old_l, new_l) {
        if inst_op(i) == .PHI return false;
        for k: 0..cast(s64) nops(i) - 1 {
            d := op(i, cast(u32) k);
            if !is_inst(d) return false;
            db := inst_block(d);
            if db != new_bb && li_loop_for(li, db) != new_l return false;
        }
    }
    return true;
}

// normalizeForPostIncUse(S, Loops, SE, CheckInvertible)
normalize_for_post_inc_use :: (s: Scev_Id, loops: *[..] Loop_Id, check_invertible: bool) -> Scev_Id {
    if loops.count == 0 return s;
    c: Norm_Ctx; c.denormalize = false; c.loops = loops;
    normalized := normalize_rewrite(s, *c);
    if !check_invertible return normalized;
    if denormalize_for_post_inc_use(normalized, loops) != s return SCEV_NULL;
    return normalized;
}

// the users of v in use-list order (Value::users())
sx_users :: (v: Value_Id) -> [..] Value_Id {
    r: [..] Value_Id; r.allocator = temp;
    u := ir.v_first_use[v];
    while u != NONE { array_add(*r, ir.u_user[u]); u = ir.u_next[u]; }
    return r;
}

// ---------------------------------------------------------------- casts

// ReuseOrCreateCast
sx_reuse_or_create_cast :: (x: *Scev_Expander, v: Value_Id, ty: Type_Id, opc: Opcode, ip: Sx_It) -> Value_Id {
    bip := x.b.pt;
    ret: Value_Id = NONE;
    if !is_constant_kind(vkind(v)) {
        for ci: sx_users(v) {
            if vtype(ci) != ty continue;
            if !is_inst(ci) || inst_op(ci) != opc continue;
            if ip.pt == NONE continue;
            if inst_block(ip.pt) == inst_block(ci) && bip != ci && (ip.pt == ci || comes_before(ci, ip.pt)) { ret = ci; break; }
        }
    }
    if ret == NONE {
        g := sx_guard_push(x);
        if ip.pt == NONE fatal("SCEVExpander: cast insertion point at the end of a block");
        irb_set_before(*x.b, ip.pt);
        ret = sx_create_cast(x, opc, v, ty, name_ref(vname(v)));
        sx_guard_pop(x, g);
    }
    return ret;
}

// findInsertPointAfter
sx_find_insert_point_after :: (x: *Scev_Expander, i: Value_Id, must_dominate: Value_Id) -> Sx_It {
    ok, ip := sx_insertion_point_after_def(i);
    if !ok ip = sx_it_of(must_dominate);
    while sx_is_inserted_instruction(x, ip.pt) && ip.pt != must_dominate ip = sx_it_next(ip);
    return ip;
}

// eraseDeadInstructions
sx_erase_dead_instructions :: (x: *Scev_Expander, root: Value_Id) {
    work: [..] Value_Id; work.allocator = temp;
    sx_all_inserted_instructions(x, *work);
    deleted: Table(Value_Id, bool); deleted.allocator = temp;
    while work.count {
        v := pop(*work);
        if table_contains(*deleted, v) continue;
        if !is_inst(v) || v == root || !sx_is_inserted_instruction(x, v) || !is_instruction_trivially_dead(v) continue;
        for k: 0..cast(s64) nops(v) - 1 array_add(*work, op(v, cast(u32) k));
        table_remove(*x.inserted_values, v);
        table_remove(*x.inserted_post_inc_values, v);
        table_set(*deleted, v, true);
        erase_inst_with_metadata(v);
    }
}

// GetOptimalInsertionPointForCastOf
sx_optimal_insertion_point_for_cast_of :: (x: *Scev_Expander, v: Value_Id) -> Sx_It {
    if vkind(v) == .ARGUMENT {
        f := value_function(v);
        ip := sx_block_begin(fn_entry(f));
        while ip.pt != NONE && inst_op(ip.pt) == .BITCAST && vkind(op(ip.pt, 0)) == .ARGUMENT && op(ip.pt, 0) != v ip = sx_it_next(ip);
        return ip;
    }
    if is_inst(v) return sx_find_insert_point_after(x, v, x.b.pt);
    return sx_first_insertion_pt(fn_entry(block_fn(x.b.bb)));
}

// CastInst::getCastOpcode(V, false, Ty, false) for the no-op casts the expander needs
sx_noop_cast_opcode :: (src: Type_Id, dst: Type_Id) -> Opcode {
    sk := type_kind(src); dk := type_kind(dst);
    if sk == .INT && dk == .PTR return .INTTOPTR;
    if sk == .PTR && dk == .INT return .PTRTOINT;
    if sk == .PTR && dk == .PTR {
        if ir.types[src].a != ir.types[dst].a return .ADDRSPACECAST;
        return .BITCAST;
    }
    return .BITCAST;
}

// InsertNoopCastOfTo
sx_insert_noop_cast_of_to :: (x: *Scev_Expander, v: Value_Id, ty: Type_Id) -> Value_Id {
    opc := sx_noop_cast_opcode(vtype(v), ty);
    assert(opc == .BITCAST || opc == .PTRTOINT || opc == .INTTOPTR, "InsertNoopCastOfTo cannot perform non-noop casts!");
    if opc == .INTTOPTR && dl_is_non_integral_pointer_type(ty)
        return sx_create_ptr_add(x, const_null_value(ty), v, "scevgep");
    if opc == .BITCAST {
        if vtype(v) == ty return v;
        if is_inst(v) && is_cast_op(inst_op(v)) && vtype(op(v, 0)) == ty return op(v, 0);
    }
    if (opc == .PTRTOINT || opc == .INTTOPTR) && sc_type_bits(ty) == sc_type_bits(vtype(v)) {
        if is_inst(v) {
            o := inst_op(v);
            if (o == .PTRTOINT || o == .INTTOPTR) && sc_type_bits(vtype(v)) == sc_type_bits(vtype(op(v, 0))) return op(v, 0);
        }
        if vkind(v) == .C_EXPR {
            o := cexpr(v).op;
            if (o == .PTRTOINT || o == .INTTOPTR) && sc_type_bits(vtype(v)) == sc_type_bits(vtype(op(v, 0))) return op(v, 0);
        }
    }
    if is_constant_kind(vkind(v)) return ce_cast(opc, v, ty);
    return sx_reuse_or_create_cast(x, v, ty, opc, sx_optimal_insertion_point_for_cast_of(x, v));
}

// ---------------------------------------------------------------- binops and GEPs

// InsertBinop
sx_insert_binop :: (x: *Scev_Expander, opc: Opcode, lhs: Value_Id, rhs: Value_Id, flags: u8, is_safe_to_hoist: bool) -> Value_Id {
    if is_constant_kind(vkind(lhs)) && is_constant_kind(vkind(rhs)) {
        r := cfo_binary_op_operands(opc, lhs, rhs);
        if r != NONE return r;
    }
    // a quick scan for this binop nearby
    scan_limit := 6;
    ip := x.b.pt;
    begin := block_first(x.b.bb);
    if ip != begin {
        ip = ifx ip == NONE then block_last(x.b.bb) else inst_prev(ip);
        while scan_limit > 0 {
            incompatible := false;
            if sx_is_obo(ip) {
                if sx_has_nsw(ip) != ((flags & SF_NSW) != 0) incompatible = true;
                if sx_has_nuw(ip) != ((flags & SF_NUW) != 0) incompatible = true;
            }
            o := inst_op(ip);
            if !incompatible && (o == .UDIV || o == .SDIV || o == .LSHR || o == .ASHR) && (inst(ip).flags & F_EXACT) incompatible = true;
            if o == opc && nops(ip) >= 2 && op(ip, 0) == lhs && op(ip, 1) == rhs && !incompatible return ip;
            if ip == begin break;
            ip = inst_prev(ip);
            scan_limit -= 1;
        }
    }
    loc: Md_Id = ifx x.b.pt != NONE then get_metadata(x.b.pt, 0) else x.b.dbg;
    g := sx_guard_push(x);
    defer sx_guard_pop(x, g);
    if is_safe_to_hoist {
        while true {
            l := li_loop_for(se.li, x.b.bb);
            if l == NONE break;
            if !li_is_loop_invariant(se.li, l, lhs) || !li_is_loop_invariant(se.li, l, rhs) break;
            ph := li_loop_preheader(se.li, l);
            if ph == NONE break;
            irb_set_before(*x.b, block_terminator(ph));
        }
    }
    x.b.dbg = loc;
    nuw := (flags & SF_NUW) != 0;
    nsw := (flags & SF_NSW) != 0;
    if x.lsr_mode && x.post_inc_loops.count {
        all_outside := true;
        for x.post_inc_loops if li_contains(se.li, it, x.b.bb) { all_outside = false; break; }
        if all_outside {
            bo := create_binop(opc, lhs, rhs);
            if nuw inst(bo).flags |= F_NUW;
            if nsw inst(bo).flags |= F_NSW;
            return sx_insert(x, bo);
        }
    }
    return sx_create_binop(x, opc, lhs, rhs, "", nuw, nsw);
}

// expandAddToGEP
sx_expand_add_to_gep :: (x: *Scev_Expander, offset: Scev_Id, v: Value_Id, flags: u8) -> Value_Id {
    idx := sx_expand(x, offset);
    nw: u32 = ifx (flags & SF_NUW) then cast(u32) F_GEP_NUW else 0;
    if is_constant_kind(vkind(v)) && is_constant_kind(vkind(idx)) return sx_create_ptr_add(x, v, idx, "", nw);
    scan_limit := 6;
    ip := x.b.pt;
    begin := block_first(x.b.bb);
    if ip != begin {
        ip = ifx ip == NONE then block_last(x.b.bb) else inst_prev(ip);
        while scan_limit > 0 {
            if inst_op(ip) == .GEP && op(ip, 0) == v && inst(ip).ty2 == ir.t_i8 && nops(ip) > 1 && op(ip, 1) == idx {
                sx_remember_flags(x, ip);
                gf := inst(ip).flags;
                gf &= ~cast(u32)(F_INBOUNDS | F_NUSW | F_GEP_NUW);
                if (inst(ip).flags & F_GEP_NUW) && (nw & F_GEP_NUW) gf |= F_GEP_NUW;
                inst(ip).flags = gf;
                return ip;
            }
            if ip == begin break;
            ip = inst_prev(ip);
            scan_limit -= 1;
        }
    }
    g := sx_guard_push(x);
    defer sx_guard_pop(x, g);
    while true {
        l := li_loop_for(se.li, x.b.bb);
        if l == NONE break;
        if !li_is_loop_invariant(se.li, l, v) || !li_is_loop_invariant(se.li, l, idx) break;
        ph := li_loop_preheader(se.li, l);
        if ph == NONE break;
        irb_set_before(*x.b, block_terminator(ph));
    }
    return sx_create_ptr_add(x, v, idx, "scevgep", nw);
}

// ---------------------------------------------------------------- relevant loops

// PickMostRelevantLoop
sx_pick_most_relevant_loop :: (a: Loop_Id, b: Loop_Id) -> Loop_Id {
    if a == NONE return b;
    if b == NONE return a;
    if li_contains_loop(se.li, a, b) return b;
    if li_contains_loop(se.li, b, a) return a;
    if dt_dominates(se.dt, li_header(se.li, a), li_header(se.li, b)) return b;
    if dt_dominates(se.dt, li_header(se.li, b), li_header(se.li, a)) return a;
    return a;
}

// getRelevantLoop
sx_relevant_loop :: (x: *Scev_Expander, s: Scev_Id) -> Loop_Id {
    found, cached := table_find(*x.relevant_loops, s);
    if found return cached;
    table_set(*x.relevant_loops, s, NONE);   // try_emplace
    k := sc_kind(s);
    if k == .CONSTANT || k == .VSCALE return NONE;
    if k == .UNKNOWN {
        v := sc_value(s);
        r: Loop_Id = NONE;
        if is_inst(v) r = li_loop_for(se.li, inst_block(v));
        table_set(*x.relevant_loops, s, r);
        return r;
    }
    if k == .CNC fatal("Attempt to use a SCEVCouldNotCompute object!");
    l: Loop_Id = NONE;
    if k == .ADDREC l = sc_loop(s);
    for i: 0..cast(s64) sc_nops(s) - 1 l = sx_pick_most_relevant_loop(l, sx_relevant_loop(x, sc_op(s, cast(u32) i)));
    table_set(*x.relevant_loops, s, l);
    return l;
}

Sx_Op_Loop :: struct { l: Loop_Id; s: Scev_Id; }
sx_sort_items: [] Sx_Op_Loop;
// LoopCompare (on indices into sx_sort_items)
sx_loop_compare :: (ai: Scev_Id, bi: Scev_Id) -> bool {
    a := sx_sort_items[ai]; b := sx_sort_items[bi];
    ap := type_kind(sc_type(a.s)) == .PTR;
    bp := type_kind(sc_type(b.s)) == .PTR;
    if ap != bp return ap;
    if a.l != b.l return sx_pick_most_relevant_loop(a.l, b.l) != a.l;
    if sc_is_non_constant_negative(a.s) {
        if !sc_is_non_constant_negative(b.s) return false;
    } else if sc_is_non_constant_negative(b.s) return true;
    return false;
}
// collect the operands in reverse with their loops and stable_sort them by LoopCompare
sx_sorted_ops_and_loops :: (x: *Scev_Expander, s: Scev_Id) -> [..] Sx_Op_Loop {
    items: [..] Sx_Op_Loop; items.allocator = temp;
    n := cast(s64) sc_nops(s);
    for < i: 0..n - 1 {
        o := sc_op(s, cast(u32) i);
        array_add(*items, .{sx_relevant_loop(x, o), o});
    }
    idx := NewArray(items.count, Scev_Id,, allocator = temp);
    for * idx it.* = cast(Scev_Id) it_index;
    saved := sx_sort_items;
    sx_sort_items = items;
    gnu_stable_sort(idx, sx_loop_compare);
    sx_sort_items = saved;
    out: [..] Sx_Op_Loop; out.allocator = temp;
    for idx array_add(*out, items[it]);
    return out;
}

// ---------------------------------------------------------------- visitors

sx_visit :: (x: *Scev_Expander, s: Scev_Id) -> Value_Id {
    k := sc_kind(s);
    if k == {
        case .CONSTANT; return sc_value(s);
        case .VSCALE; return sx_create_intrinsic(x, "llvm.vscale", .[sc_type(s)], .[]);
        case .TRUNC;
            v := sx_expand(x, sc_op(s, 0));
            return sx_create_trunc(x, v, sc_type(s));
        case .ZEXT;
            v := sx_expand(x, sc_op(s, 0));
            return sx_create_zext(x, v, sc_type(s), "", sc_is_known_non_negative(sc_op(s, 0)));
        case .SEXT;
            v := sx_expand(x, sc_op(s, 0));
            return sx_create_cast(x, .SEXT, v, sc_type(s));
        case .ADD; return sx_visit_add(x, s);
        case .MUL; return sx_visit_mul(x, s);
        case .UDIV; return sx_visit_udiv(x, s);
        case .ADDREC; return sx_visit_add_rec(x, s);
        case .SMAX; return sx_expand_min_max(x, s, "llvm.smax", "smax", false);
        case .UMAX; return sx_expand_min_max(x, s, "llvm.umax", "umax", false);
        case .SMIN; return sx_expand_min_max(x, s, "llvm.smin", "smin", false);
        case .UMIN; return sx_expand_min_max(x, s, "llvm.umin", "umin", false);
        case .SEQ_UMIN; return sx_expand_min_max(x, s, "llvm.umin", "umin", true);
        case .PTRTOADDR; return sx_visit_ptr_to_addr(x, s);
        case .PTRTOINT;
            v := sx_expand(x, sc_op(s, 0));
            return sx_reuse_or_create_cast(x, v, sc_type(s), .PTRTOINT, sx_optimal_insertion_point_for_cast_of(x, v));
        case .UNKNOWN; return sc_value(s);
        case .CNC; fatal("Attempt to use a SCEVCouldNotCompute object!");
    }
    return NONE;
}

// visitAddExpr
sx_visit_add :: (x: *Scev_Expander, s: Scev_Id) -> Value_Id {
    ok, ul, ur := match_urem(s);
    if ok {
        lhs := sx_expand(x, ul);
        rhs := sx_expand(x, ur);
        return sx_insert_binop(x, .UREM, lhs, rhs, SF_ANY, false);
    }
    ops := sx_sorted_ops_and_loops(x, s);
    sum: Value_Id = NONE;
    i := 0;
    while i < ops.count {
        cur_loop := ops[i].l;
        o := ops[i].s;
        if sum == NONE {
            sum = sx_expand(x, o);
            i += 1;
            continue;
        }
        assert(type_kind(sc_type(o)) != .PTR, "Only first op can be pointer");
        if type_kind(vtype(sum)) == .PTR {
            new_ops: [..] Scev_Id; new_ops.allocator = temp;
            while i < ops.count && ops[i].l == cur_loop {
                xs := ops[i].s;
                if sc_is_unknown(xs) && !is_inst(sc_value(xs)) xs = sc_get_scev(sc_value(xs));
                array_add(*new_ops, xs);
                i += 1;
            }
            sum = sx_expand_add_to_gep(x, sc_get_add(*new_ops), sum, sc_flags(s));
        } else if sc_is_non_constant_negative(o) {
            w := sx_expand(x, sc_get_negative(o));
            sum = sx_insert_binop(x, .SUB, sum, w, SF_ANY, true);
            i += 1;
        } else {
            w := sx_expand(x, o);
            if is_constant_kind(vkind(sum)) sum, w = w, sum;
            sum = sx_insert_binop(x, .ADD, sum, w, sc_flags(s), true);
            i += 1;
        }
    }
    return sum;
}

// visitMulExpr
sx_visit_mul :: (x: *Scev_Expander, s: Scev_Id) -> Value_Id {
    ty := sc_type(s);
    ops := sx_sorted_ops_and_loops(x, s);
    prod: Value_Id = NONE;
    i := 0;
    // ExpandOpBinPowN
    expand_op_bin_pow_n :: (x: *Scev_Expander, ops: [..] Sx_Op_Loop, i: *s64) -> Value_Id {
        e := i.*;
        exponent: u64 = 0;
        MAX_EXPONENT :: 0xFFFF_FFFF_FFFF_FFFF >> 1;
        while e < ops.count && ops[i.*].l == ops[e].l && ops[i.*].s == ops[e].s && exponent != MAX_EXPONENT {
            exponent += 1;
            e += 1;
        }
        p := sx_expand(x, ops[i.*].s);
        result: Value_Id = NONE;
        if exponent & 1 result = p;
        bin_exp: u64 = 2;
        while bin_exp <= exponent {
            p = sx_insert_binop(x, .MUL, p, p, SF_ANY, true);
            if exponent & bin_exp {
                if result != NONE result = sx_insert_binop(x, .MUL, result, p, SF_ANY, true);
                else result = p;
            }
            bin_exp <<= 1;
        }
        i.* = e;
        return result;
    }
    while i < ops.count {
        if prod == NONE {
            prod = expand_op_bin_pow_n(x, ops, *i);
        } else if sc_is_all_ones(ops[i].s) {
            prod = sx_insert_binop(x, .SUB, const_null_value(ty), prod, SF_ANY, true);
            i += 1;
        } else {
            w := expand_op_bin_pow_n(x, ops, *i);
            if is_constant_kind(vkind(prod)) prod, w = w, prod;
            is_p2, rhs := pm_power2_ap(w);
            if is_p2 {
                nw := sc_flags(s);
                if ap_log2(rhs) == rhs.bits - 1 nw = clear_flags(nw, SF_NSW);
                prod = sx_insert_binop(x, .SHL, prod, const_int(ty, ap_log2(rhs)), nw, true);
            } else {
                prod = sx_insert_binop(x, .MUL, prod, w, sc_flags(s), true);
            }
        }
    }
    return prod;
}

// visitUDivExpr
sx_visit_udiv :: (x: *Scev_Expander, s: Scev_Id) -> Value_Id {
    lhs := sx_expand(x, sc_op(s, 0));
    rs := sc_op(s, 1);
    if sc_is_const(rs) {
        r := sc_ap(rs);
        if ap_is_power_of_2(r) return sx_insert_binop(x, .LSHR, lhs, const_int(sc_type(rs), ap_log2(r)), SF_ANY, true);
    }
    rhs := sx_expand(x, rs);
    if x.safe_udiv_mode {
        guaranteed_not_poison := sc_is_guaranteed_not_to_be_poison(rs);
        if !guaranteed_not_poison rhs = sx_create_freeze(x, rhs);
        if !sc_is_known_non_zero(rs) || !guaranteed_not_poison
            rhs = sx_create_intrinsic(x, "llvm.umax", .[vtype(rhs)], .[rhs, const_int(vtype(rhs), 1)]);
    }
    return sx_insert_binop(x, .UDIV, lhs, rhs, SF_ANY, sc_is_known_non_zero(sc_op(s, 1)));
}

// isNormalAddRecExprPHI
sx_is_normal_add_rec_expr_phi :: (x: *Scev_Expander, pn: Value_Id, inc_v_in: Value_Id, l: Loop_Id) -> bool {
    inc_v := inc_v_in;
    while true {
        o := inst_op(inc_v);
        if nops(inc_v) == 0 || o == .PHI || (is_cast_op(o) && o != .BITCAST) return false;
        if l == x.iv_inc_insert_loop {
            for k: 1..cast(s64) nops(inc_v) - 1 {
                oi := op(inc_v, cast(u32) k);
                if is_inst(oi) && !dt_dominates_inst(se.dt, oi, x.iv_inc_insert_pos) return false;
            }
        }
        nxt := op(inc_v, 0);
        if !is_inst(nxt) return false;
        inc_v = nxt;
        if may_have_side_effects(inc_v) return false;
        if inc_v == pn return true;
    }
    return false;
}

// getIVIncOperand
sx_get_iv_inc_operand :: (x: *Scev_Expander, inc_v: Value_Id, insert_pos: Value_Id, allow_scale: bool) -> Value_Id {
    if inc_v == insert_pos return NONE;
    o := inst_op(inc_v);
    if o == .ADD || o == .SUB {
        oi := op(inc_v, 1);
        if !is_inst(oi) || dt_dominates_inst(se.dt, oi, insert_pos) {
            r := op(inc_v, 0);
            return ifx is_inst(r) then r else NONE;
        }
        return NONE;
    }
    if o == .BITCAST { r := op(inc_v, 0); return ifx is_inst(r) then r else NONE; }
    if o == .GEP {
        for k: 1..cast(s64) nops(inc_v) - 1 {
            u := op(inc_v, cast(u32) k);
            if is_constant_kind(vkind(u)) continue;
            if is_inst(u) && !dt_dominates_inst(se.dt, u, insert_pos) return NONE;
            if allow_scale continue;
            if inst(inc_v).ty2 != ir.t_i8 return NONE;
            break;
        }
        r := op(inc_v, 0);
        return ifx is_inst(r) then r else NONE;
    }
    return NONE;
}

// hoistIVInc
sx_hoist_iv_inc :: (x: *Scev_Expander, inc_v_in: Value_Id, insert_pos: Value_Id, recompute_poison_flags := false) -> bool {
    fixup_poison_flags :: (x: *Scev_Expander, i: Value_Id) {
        sx_remember_flags(x, i);
        drop_poison_generating_flags(i);
        if sx_is_obo(i) {
            has, f := sc_get_strengthened_no_wrap_flags_from_bin_op(i);
            if has {
                sx_set_nuw(i, mask_flags(f, SF_NUW) == SF_NUW);
                sx_set_nsw(i, mask_flags(f, SF_NSW) == SF_NSW);
            }
        }
    }
    inc_v := inc_v_in;
    if dt_dominates_inst(se.dt, inc_v, insert_pos) {
        if recompute_poison_flags fixup_poison_flags(x, inc_v);
        return true;
    }
    if inst_op(insert_pos) == .PHI || !dt_dominates(se.dt, inst_block(insert_pos), inst_block(inc_v)) return false;
    if !li_movement_preserves_lcssa_form(se.li, inc_v, insert_pos) return false;
    incs: [..] Value_Id; incs.allocator = temp;
    while true {
        oper := sx_get_iv_inc_operand(x, inc_v, insert_pos, true);
        if oper == NONE return false;
        array_add(*incs, inc_v);
        inc_v = oper;
        if dt_dominates_inst(se.dt, inc_v, insert_pos) break;
    }
    for < incs {
        sx_fixup_insert_points(x, it);
        inst_move_before_dbg(it, insert_pos);
        if recompute_poison_flags fixup_poison_flags(x, it);
    }
    return true;
}

// match(I, m_c_BinOp(m_Specific(P), m_Value()))
sx_is_commutative_binop_of :: (i: Value_Id, p: Value_Id) -> bool {
    if !is_inst(i) || !is_binary_op(inst_op(i)) return false;
    return op(i, 0) == p || op(i, 1) == p;
}
// canReuseFlagsFromOriginalIVInc
sx_can_reuse_flags_from_original_iv_inc :: (orig_phi: Value_Id, wide_phi: Value_Id, orig_inc: Value_Id, wide_inc: Value_Id) -> bool {
    return sx_is_commutative_binop_of(orig_inc, orig_phi) && sx_is_commutative_binop_of(wide_inc, wide_phi) &&
           inst_op(orig_inc) == inst_op(wide_inc);
}

// isExpandedAddRecExprPHI
sx_is_expanded_add_rec_expr_phi :: (x: *Scev_Expander, pn: Value_Id, inc_v: Value_Id, l: Loop_Id) -> bool {
    pos := block_terminator(li_loop_preheader(se.li, l));
    iv_oper := inc_v;
    while true {
        iv_oper = sx_get_iv_inc_operand(x, iv_oper, pos, false);
        if iv_oper == NONE break;
        if iv_oper == pn return true;
    }
    return false;
}

// expandIVInc
sx_expand_iv_inc :: (x: *Scev_Expander, pn: Value_Id, step_v: Value_Id, l: Loop_Id, use_subtract: bool) -> Value_Id {
    if type_kind(vtype(pn)) == .PTR return sx_create_ptr_add(x, pn, step_v, "scevgep");
    nm := tprint("%.iv.next", x.ivname);
    if use_subtract return sx_create_binop(x, .SUB, pn, step_v, nm);
    return sx_create_binop(x, .ADD, pn, step_v, nm);
}

// canBeCheaplyTransformed: (ok, invert_step)
sx_can_be_cheaply_transformed :: (phi_in: Scev_Id, requested: Scev_Id) -> (bool, bool) {
    phi_ty := sc_type(phi_in); req_ty := sc_type(requested);
    if type_kind(phi_ty) == .PTR || type_kind(req_ty) == .PTR return false, false;
    if type_int_width(req_ty) > type_int_width(phi_ty) return false, false;
    phi := sc_get_truncate_or_noop(phi_in, req_ty);
    if !sc_is_addrec(phi) return false, false;
    if phi == requested return true, false;
    if sc_get_minus(sc_start(requested), requested) == phi return true, true;
    return false, false;
}

// IsIncrementNSW / IsIncrementNUW
sx_is_increment_nw :: (ar: Scev_Id, signed: bool) -> bool {
    if type_kind(sc_type(ar)) != .INT return false;
    bw := type_int_width(sc_type(ar));
    wide := type_int(cast(u64) bw * 2);
    step := sc_step_recurrence(ar);
    ext :: (s: Scev_Id, t: Type_Id, signed: bool) -> Scev_Id { if signed return sc_get_sign_extend(s, t); return sc_get_zero_extend(s, t); }
    op_after_extend := sc_get_add2(ext(step, wide, signed), ext(ar, wide, signed));
    extend_after_op := ext(sc_get_add2(ar, step), wide, signed);
    return extend_after_op == op_after_extend;
}

// getAddRecExprPHILiterally: (phi, trunc_ty, invert_step)
sx_get_add_rec_expr_phi_literally :: (x: *Scev_Expander, normalized: Scev_Id, l: Loop_Id) -> (Value_Id, Type_Id, bool) {
    assert(x.iv_inc_insert_loop == NONE || x.iv_inc_insert_pos != NONE, "Uninitialized insert position");
    trunc_ty: Type_Id = NONE;
    invert_step := false;
    latch := li_loop_latch(se.li, l);
    if latch != NONE {
        match: Value_Id = NONE;
        inc_v: Value_Id = NONE;
        try_non_matching := x.iv_inc_insert_loop != NONE && dt_properly_dominates(se.dt, latch, li_header(se.li, x.iv_inc_insert_loop));
        for pn: block_insts(li_header(se.li, l)) {
            if inst_op(pn) != .PHI break;
            if !sc_is_scevable(vtype(pn)) continue;
            if !sx_phi_is_complete(pn) continue;
            phi_scev := sc_get_scev(pn);
            if !sc_is_addrec(phi_scev) continue;
            is_matching := phi_scev == normalized;
            if !is_matching && !try_non_matching continue;
            temp_inc := phi_incoming_value_for_block(pn, latch);
            if !is_inst(temp_inc) continue;
            if x.lsr_mode { if !sx_is_expanded_add_rec_expr_phi(x, pn, temp_inc, l) continue; }
            else if !sx_is_normal_add_rec_expr_phi(x, pn, temp_inc, l) continue;
            if is_matching {
                inc_v = temp_inc; trunc_ty = NONE; invert_step = false; match = pn;
                break;
            }
            if trunc_ty == NONE || invert_step {
                ok, inv := sx_can_be_cheaply_transformed(phi_scev, normalized);
                if ok {
                    invert_step = inv;
                    match = pn; inc_v = temp_inc; trunc_ty = sc_type(normalized);
                }
            }
        }
        if match != NONE {
            sx_set_insert(*x.inserted_values, *x.inserted_values_order, match);
            sx_remember_instruction(x, inc_v);
            table_set(*x.reused_values, match, true);
            table_set(*x.reused_values, inc_v, true);
            return match, trunc_ty, invert_step;
        }
    }
    g := sx_guard_push(x);
    defer sx_guard_pop(x, g);
    saved_post_inc: [..] Loop_Id; saved_post_inc.allocator = temp;
    for x.post_inc_loops array_add(*saved_post_inc, it);
    x.post_inc_loops.count = 0;

    ph := li_loop_preheader(se.li, l);
    assert(ph != NONE, "Can't expand add recurrences without a loop preheader!");
    sx_set_insert_point(x, block_terminator(ph));
    start_v := sx_expand(x, sc_start(normalized));

    step := sc_step_recurrence(normalized);
    expand_ty := sc_type(normalized);
    use_subtract := type_kind(expand_ty) != .PTR && sc_is_non_constant_negative(step);
    if use_subtract step = sc_get_negative(step);
    header := li_header(se.li, l);
    sx_set_insert_point_it(x, sx_first_insertion_pt(header));
    step_v := sx_expand(x, step);

    inc_nuw := !use_subtract && sx_is_increment_nw(normalized, false);
    inc_nsw := !use_subtract && sx_is_increment_nw(normalized, true);

    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(header, *preds);
    irb_set_at(*x.b, header, block_first(header), true);   // SetInsertPoint(Header, Header->begin())
    pn := sx_create_phi(x, expand_ty, cast(u32) preds.count, tprint("%.iv", x.ivname));
    for pred: preds {
        if !li_contains(se.li, l, pred) {
            phi_add_incoming(pn, start_v, pred);
            continue;
        }
        insert_pos := ifx l == x.iv_inc_insert_loop then x.iv_inc_insert_pos else block_terminator(pred);
        irb_set_before(*x.b, insert_pos);
        inc_v := sx_expand_iv_inc(x, pn, step_v, l, use_subtract);
        if sx_is_obo(inc_v) {
            if inc_nuw inst(inc_v).flags |= F_NUW;
            if inc_nsw inst(inc_v).flags |= F_NSW;
        }
        phi_add_incoming(pn, inc_v, pred);
    }
    x.post_inc_loops.count = 0;
    for saved_post_inc array_add(*x.post_inc_loops, it);
    sx_set_insert(*x.inserted_values, *x.inserted_values_order, pn);
    array_add(*x.inserted_ivs, pn);
    return pn, NONE, false;
}

// PHINode::isComplete: an incoming value for every predecessor
sx_phi_is_complete :: (pn: Value_Id) -> bool {
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(inst_block(pn), *preds);
    for p: preds if phi_block_index(pn, p) < 0 return false;
    return true;
}

// expandAddRecExprLiterally
sx_expand_add_rec_expr_literally :: (x: *Scev_Expander, s: Scev_Id) -> Value_Id {
    l := sc_loop(s);
    normalized := s;
    if sx_post_inc_contains(x, l) {
        loops: [..] Loop_Id; loops.allocator = temp;
        array_add(*loops, l);
        normalized = normalize_for_post_inc_use(s, *loops, false);
    }
    step := sc_step_recurrence(normalized);
    pn, trunc_ty, invert_step := sx_get_add_rec_expr_phi_literally(x, normalized, l);
    result: Value_Id;
    if !sx_post_inc_contains(x, l) result = pn;
    else {
        latch := li_loop_latch(se.li, l);
        assert(latch != NONE, "PostInc mode requires a unique loop latch!");
        result = phi_incoming_value_for_block(pn, latch);
        if sx_is_obo(result) {
            if !sc_has_nuw(s) sx_set_nuw(result, false);
            if !sc_has_nsw(s) sx_set_nsw(result, false);
        }
        if is_inst(result) && !dt_dominates_inst(se.dt, result, x.b.pt) {
            use_subtract := type_kind(sc_type(s)) != .PTR && sc_is_non_constant_negative(step);
            if use_subtract step = sc_get_negative(step);
            step_v: Value_Id;
            {
                g := sx_guard_push(x);
                sx_set_insert_point_it(x, sx_first_insertion_pt(li_header(se.li, l)));
                step_v = sx_expand(x, step);
                sx_guard_pop(x, g);
            }
            result = sx_expand_iv_inc(x, pn, step_v, l, use_subtract);
        }
    }
    if trunc_ty != NONE {
        if trunc_ty != vtype(result) || invert_step result = sx_fixup_lcssa_form_for(x, result);
        if trunc_ty != vtype(result) result = sx_create_trunc(x, result, trunc_ty);
        if invert_step result = sx_create_binop(x, .SUB, sx_expand(x, sc_start(normalized)), result);
    }
    return result;
}

// tryToReuseLCSSAPhi
sx_try_to_reuse_lcssa_phi :: (x: *Scev_Expander, s: Scev_Id) -> Value_Id {
    sty := sc_type(s);
    l := sc_loop(s);
    eb := li_exit_block(se.li, l);
    if eb == NONE || block_single_predecessor(eb) == NONE || !dt_dominates(se.dt, eb, x.b.bb) return NONE;
    can_reuse :: (s: Scev_Id, exit_scev: Scev_Id) -> Scev_Id {
        if exit_scev == SCEV_CNC return SCEV_NULL;
        diff := sc_get_minus(s, exit_scev);
        o := diff;
        if sc_is_add(o) && sc_nops(o) == 2 && sc_is_const(sc_op(o, 0)) o = sc_op(o, 1);
        if sc_is_mul(o) && sc_nops(o) == 2 && sc_is_all_ones(sc_op(o, 0)) o = sc_op(o, 1);
        if sc_kind(o) == .PTRTOADDR || sc_kind(o) == .PTRTOINT o = sc_op(o, 0);
        if !sc_is_const(o) && !sc_is_unknown(o) return SCEV_NULL;
        return diff;
    }
    for pn: block_insts(eb) {
        if inst_op(pn) != .PHI break;
        if !sc_is_scevable(vtype(pn)) continue;
        exit_scev := sc_get_scev(pn);
        if !sc_is_addrec(exit_scev) continue;
        phi_ty := vtype(pn);
        diff := SCEV_NULL;
        if type_kind(sty) == .INT && type_kind(phi_ty) == .PTR && dl_address_type(phi_ty) == sty {
            diff = can_reuse(s, sc_get_ptr_to_addr(exit_scev));
            if diff == SCEV_NULL diff = can_reuse(s, sc_get_ptr_to_int(exit_scev, sty));
        } else if sty == phi_ty {
            diff = can_reuse(s, exit_scev);
        }
        if diff == SCEV_NULL continue;
        diff_v := sx_expand(x, diff);
        base_v := sx_fixup_lcssa_form_for(x, pn);
        if type_kind(phi_ty) == .PTR {
            if type_kind(sty) == .PTR return sx_create_ptr_add(x, base_v, diff_v);
            base_v = sx_create_cast(x, .PTRTOADDR, base_v, dl_address_type(phi_ty));
        }
        return sx_create_binop(x, .ADD, base_v, diff_v);
    }
    return NONE;
}

// visitAddRecExpr
sx_visit_add_rec :: (x: *Scev_Expander, s: Scev_Id) -> Value_Id {
    if !x.canonical_mode || sc_nops(s) > 2 return sx_expand_add_rec_expr_literally(x, s);
    ty := sc_effective_type(sc_type(s));
    l := sc_loop(s);
    canonical_iv: Value_Id = NONE;
    pn := li_canonical_induction_variable(se.li, l);
    if pn != NONE && sc_type_bits(vtype(pn)) >= sc_type_bits(ty) canonical_iv = pn;

    if canonical_iv != NONE && sc_type_bits(vtype(canonical_iv)) > sc_type_bits(ty) && type_kind(sc_type(s)) != .PTR {
        new_ops: [..] Scev_Id; new_ops.allocator = temp;
        for i: 0..cast(s64) sc_nops(s) - 1 array_add(*new_ops, sc_get_any_extend(sc_op(s, cast(u32) i), vtype(canonical_iv)));
        v := sx_expand(x, sc_get_add_rec_ops(*new_ops, sc_loop(s), sc_flags(s, SF_NW)));
        new_ip := ifx is_inst(v) then sx_find_insert_point_after(x, v, x.b.pt) else sx_builder_it(x);
        sx_set_insert_point_it(x, new_ip);
        return sx_expand(x, sc_get_truncate(sc_get_unknown(v), ty));
    }
    r := sx_try_to_reuse_lcssa_phi(x, s);
    if r != NONE return r;
    if !sc_is_zero(sc_start(s)) {
        if type_kind(sc_type(s)) == .PTR {
            start_v := sx_expand(x, sc_get_pointer_base(s));
            return sx_expand_add_to_gep(x, sc_remove_pointer_base(s), start_v, sc_flags(s, SF_NUW));
        }
        new_ops := sc_operands(s);
        new_ops[0] = sc_get_zero(ty);
        rest := sc_get_add_rec_ops(*new_ops, l, sc_flags(s, SF_NW));
        lhs := sc_get_unknown(sx_expand(x, sc_start(s)));
        rhs := sc_get_unknown(sx_expand(x, rest));
        return sx_expand(x, sc_get_add2(lhs, rhs));
    }
    if canonical_iv == NONE {
        header := li_header(se.li, l);
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(header, *preds);
        canonical_iv = create_phi(ty, cast(u32) preds.count);
        insert_at_position(canonical_iv, header, block_first(header), true);
        set_name(canonical_iv, "indvar");
        sx_remember_instruction(x, canonical_iv);
        seen: [..] Value_Id; seen.allocator = temp;
        one := const_int(ty, 1);
        for hp: preds {
            dup := false;
            for seen if it == hp { dup = true; break; }
            if dup { phi_add_incoming(canonical_iv, phi_incoming_value_for_block(canonical_iv, hp), hp); continue; }
            array_add(*seen, hp);
            if li_contains(se.li, l, hp) {
                add := create_binop(.ADD, canonical_iv, one);
                t := block_terminator(hp);
                insert_at_position(add, hp, t, false);
                set_name(add, "indvar.next");
                set_metadata(add, 0, get_metadata(t, 0));
                sx_remember_instruction(x, add);
                phi_add_incoming(canonical_iv, add, hp);
            } else {
                phi_add_incoming(canonical_iv, const_null_value(ty), hp);
            }
        }
    }
    if sc_is_affine(s) && sc_is_one(sc_op(s, 1)) return canonical_iv;
    if sc_is_affine(s)
        return sx_expand(x, sc_get_truncate_or_noop(sc_get_mul2(sc_get_unknown(canonical_iv), sc_get_noop_or_any_extend(sc_op(s, 1), vtype(canonical_iv))), ty));
    ih := sc_get_unknown(canonical_iv);
    new_s := s;
    ext := sc_get_noop_or_any_extend(s, vtype(canonical_iv));
    if sc_is_addrec(ext) new_s = ext;
    v := evaluate_at_iteration(new_s, ih);
    return sx_expand(x, sc_get_truncate_or_noop(v, ty));
}

// visitPtrToAddrExpr
sx_visit_ptr_to_addr :: (x: *Scev_Expander, s: Scev_Id) -> Value_Id {
    v := sx_expand(x, sc_op(s, 0));
    ty := sc_type(s);
    if !is_constant_kind(vkind(v)) {
        bip := x.b.pt;
        for ci: sx_users(v) {
            if !is_inst(ci) || vtype(ci) != ty continue;
            o := inst_op(ci);
            if (o == .PTRTOADDR || o == .PTRTOINT) && bip != ci && dt_dominates_inst(se.dt, ci, bip) return ci;
        }
    }
    return sx_reuse_or_create_cast(x, v, ty, .PTRTOADDR, sx_optimal_insertion_point_for_cast_of(x, v));
}

// expandMinMaxExpr
sx_expand_min_max :: (x: *Scev_Expander, s: Scev_Id, iid: string, name: string, is_sequential: bool) -> Value_Id {
    prev_safe := x.safe_udiv_mode;
    x.safe_udiv_mode |= is_sequential;
    n := cast(s64) sc_nops(s);
    lhs := sx_expand(x, sc_op(s, cast(u32)(n - 1)));
    ty := vtype(lhs);
    if is_sequential lhs = sx_create_freeze(x, lhs);
    i := n - 2;
    while i >= 0 {
        x.safe_udiv_mode = (is_sequential && i != 0) || prev_safe;
        rhs := sx_expand(x, sc_op(s, cast(u32) i));
        if is_sequential && i != 0 rhs = sx_create_freeze(x, rhs);
        sel: Value_Id;
        if type_kind(ty) == .INT sel = sx_create_intrinsic(x, iid, .[ty], .[lhs, rhs], name);
        else {
            pred: u8;
            if iid == "llvm.smax" pred = ICMP_SGT; else if iid == "llvm.umax" pred = ICMP_UGT;
            else if iid == "llvm.smin" pred = ICMP_SLT; else pred = ICMP_ULT;
            c := sx_create_icmp(x, pred, lhs, rhs);
            sel = sx_create_select(x, c, lhs, rhs, name);
        }
        lhs = sel;
        i -= 1;
    }
    x.safe_udiv_mode = prev_safe;
    return lhs;
}

// ---------------------------------------------------------------- expand / expandCodeFor

// expandCodeFor(SH, Ty, IP)
sx_expand_code_for_at :: (x: *Scev_Expander, s: Scev_Id, ty: Type_Id, ip: Value_Id) -> Value_Id {
    sx_set_insert_point(x, ip);
    return sx_expand_code_for(x, s, ty);
}
// expandCodeFor(SH, Ty)
sx_expand_code_for :: (x: *Scev_Expander, s: Scev_Id, ty: Type_Id = NONE) -> Value_Id {
    v := sx_expand(x, s);
    if ty != NONE && ty != vtype(v) {
        assert(sc_type_bits(ty) == sc_type_bits(sc_type(s)), "non-trivial casts should be done with the SCEVs directly!");
        v = sx_insert_noop_cast_of_to(x, v, ty);
    }
    return v;
}

// FindValueInExprValueMap
sx_find_value_in_expr_value_map :: (x: *Scev_Expander, s: Scev_Id, insert_pt: Value_Id, drops: *[..] Value_Id) -> Value_Id {
    if !x.canonical_mode && sc_contains_add_recurrence(s) return NONE;
    if sc_is_const(s) || sc_is_unknown(s) return NONE;
    vals: [..] Value_Id; vals.allocator = temp;
    for sc_get_scev_values(s) array_add(*vals, it);
    for v: vals {
        if !is_inst(v) continue;
        if sc_type(s) != vtype(v) || !dt_dominates_inst(se.dt, v, insert_pt) continue;
        vl := li_loop_for(se.li, inst_block(v));
        if !(vl == NONE || li_contains(se.li, vl, inst_block(insert_pt))) continue;
        if sc_can_reuse_instruction(s, v, drops) return v;
        drops.count = 0;
    }
    return NONE;
}

sx_key :: (s: Scev_Id, it: Sx_It) -> u64 {
    p: u64 = ifx it.pt != NONE then cast(u64) it.pt else (cast(u64) it.bb) | 0x8000_0000;
    return ((cast(u64) s) << 32) | p;
}

// SafeToHoist: no udiv by something other than a non-zero constant
sx_safe_to_hoist :: (s: Scev_Id) -> bool { return !sc_expr_contains(s, .CONTAINS_UNSAFE_UDIV_FOR_HOIST); }
sx_vis_unsafe_udiv_follow :: (s: Scev_Id) -> bool {
    if !sc_is_udiv(s) return false;
    r := sc_op(s, 1);
    if sc_is_const(r) return sc_is_zero(r);
    return true;
}

// expand
sx_expand :: (x: *Scev_Expander, s: Scev_Id) -> Value_Id {
    insert_pt := sx_builder_it(x);
    if sx_safe_to_hoist(s) {
        l := li_loop_for(se.li, x.b.bb);
        while true {
            if sc_is_loop_invariant(s, l) {
                if l == NONE break;
                ph := li_loop_preheader(se.li, l);
                if ph != NONE insert_pt = sx_it_of(block_terminator(ph));
                else insert_pt = sx_first_insertion_pt(li_header(se.li, l));
            } else {
                if l != NONE && sc_has_computable_loop_evolution(s, l) && !sx_post_inc_contains(x, l)
                    insert_pt = sx_first_insertion_pt(li_header(se.li, l));
                while insert_pt.pt != x.b.pt && sx_is_inserted_instruction(x, insert_pt.pt) insert_pt = sx_it_next(insert_pt);
                break;
            }
            l = li_parent(se.li, l);
        }
    }
    key := sx_key(s, insert_pt);
    found, h := table_find(*x.inserted_expressions, key);
    if found {
        v := vh_get(h);
        if v == NONE fatal("SCEVExpander: a cached expansion was deleted");
        return v;
    }
    g := sx_guard_push(x);
    defer sx_guard_pop(x, g);
    irb_set_at(*x.b, insert_pt.bb, insert_pt.pt, insert_pt.head);
    drops: [..] Value_Id; drops.allocator = temp;
    if insert_pt.pt == NONE fatal("SCEVExpander: expansion at the end of a block is not supported");
    v := sx_find_value_in_expr_value_map(x, s, insert_pt.pt, *drops);
    if v == NONE {
        v = sx_visit(x, s);
        if v == NONE fatal("SCEVExpander: internal: expanding a % produced no value", sc_kind(s));
        v = sx_fixup_lcssa_form_for(x, v);
    } else {
        for drops {
            sx_remember_flags(x, it);
            sx_drop_poison_generating_annotations_and_reinfer(it);
        }
    }
    table_set(*x.inserted_expressions, key, vh_new(v));
    return v;
}

// dropPoisonGeneratingAnnotationsAndReinfer
sx_drop_poison_generating_annotations_and_reinfer :: (i: Value_Id) {
    drop_poison_generating_annotations(i);
    if sx_is_obo(i) {
        has, f := sc_get_strengthened_no_wrap_flags_from_bin_op(i);
        if has {
            sx_set_nuw(i, mask_flags(f, SF_NUW) == SF_NUW);
            sx_set_nsw(i, mask_flags(f, SF_NSW) == SF_NSW);
        }
    }
    o := inst_op(i);
    if o == .ZEXT || o == .UITOFP {
        src := op(i, 0);
        if is_implied_by_dom_condition_pred(ICMP_SGE, false, src, const_null_value(vtype(src)), i) == 1 inst(i).flags |= F_EXACT;
    }
}

// ---------------------------------------------------------------- congruent IVs

// replaceCongruentIVInc (Phi and OrigPhi may be swapped)
sx_replace_congruent_iv_inc :: (x: *Scev_Expander, phi_p: *Value_Id, orig_phi_p: *Value_Id, l: Loop_Id, dead: *[..] Vh) {
    latch := li_loop_latch(se.li, l);
    if latch == NONE return;
    orig_inc := phi_incoming_value_for_block(orig_phi_p.*, latch);
    iso_inc := phi_incoming_value_for_block(phi_p.*, latch);
    if !is_inst(orig_inc) || !is_inst(iso_inc) return;
    if vtype(orig_phi_p.*) == vtype(phi_p.*) {
        chained := table_contains(*x.chained_phis, phi_p.*);
        if !(chained || sx_is_expanded_add_rec_expr_phi(x, orig_phi_p.*, orig_inc, l)) &&
           (chained || sx_is_expanded_add_rec_expr_phi(x, phi_p.*, iso_inc, l)) {
            phi_p.*, orig_phi_p.* = orig_phi_p.*, phi_p.*;
            orig_inc, iso_inc = iso_inc, orig_inc;
        }
    }
    trunc_expr := sc_get_truncate_or_noop(sc_get_scev(orig_inc), vtype(iso_inc));
    if orig_inc == iso_inc || trunc_expr != sc_get_scev(iso_inc) || !li_replacement_preserves_lcssa_form(se.li, iso_inc, orig_inc) return;
    both_nuw := false; both_nsw := false;
    obo_inc := sx_is_obo(orig_inc);
    if obo_inc && sx_is_obo(iso_inc) {
        both_nuw = sx_has_nuw(orig_inc) && sx_has_nuw(iso_inc);
        both_nsw = sx_has_nsw(orig_inc) && sx_has_nsw(iso_inc);
    }
    if !sx_hoist_iv_inc(x, orig_inc, iso_inc, true) return;
    if both_nuw || both_nsw {
        sx_set_nuw(orig_inc, sx_has_nuw(orig_inc) || both_nuw);
        sx_set_nsw(orig_inc, sx_has_nsw(orig_inc) || both_nsw);
    }
    new_inc := orig_inc;
    if vtype(orig_inc) != vtype(iso_inc) {
        ip: Sx_It;
        if inst_op(orig_inc) == .PHI ip = sx_first_insertion_pt(inst_block(orig_inc));
        else ip = sx_it_of(inst_next(orig_inc));
        b: Irb;
        irb_set_at(*b, ip.bb, ip.pt, ip.head);
        b.dbg = get_metadata(iso_inc, 0);
        new_inc = irb_trunc_or_bitcast_named(*b, orig_inc, vtype(iso_inc), x.ivname);
    }
    rauw_with_metadata(iso_inc, new_inc);
    array_add(dead, vh_new(iso_inc));
}

// replaceCongruentIVs: returns the number of phis eliminated
sx_replace_congruent_ivs :: (x: *Scev_Expander, l: Loop_Id, dead: *[..] Vh, tti: *Tti) -> u32 {
    phis: [..] Value_Id; phis.allocator = temp;
    for pn: block_insts(li_header(se.li, l)) { if inst_op(pn) != .PHI break; array_add(*phis, pn); }
    if tti {
        // stable_sort: integers by decreasing width, pointers (and other types) last
        less :: (a: Value_Id, b: Value_Id) -> bool {
            ai := type_kind(vtype(a)) == .INT; bi := type_kind(vtype(b)) == .INT;
            if !ai || !bi return bi && !ai;
            return type_int_width(vtype(b)) < type_int_width(vtype(a));
        }
        // insertion sort is stable
        for i: 1..phis.count - 1 {
            v := phis[i];
            j := i - 1;
            while j >= 0 && less(v, phis[j]) { phis[j + 1] = phis[j]; j -= 1; }
            phis[j + 1] = v;
        }
    }
    num_elim: u32 = 0;
    expr_to_iv: Table(Scev_Id, Value_Id); expr_to_iv.allocator = temp;
    for phi_in: phis {
        phi := phi_in;
        // SimplifyPHINode
        simplify_phi_node :: (pn: Value_Id) -> Value_Id {
            q: Simplify_Query; q.dt = se.dt; q.ac = se.ac;
            v := simplify_instruction(pn, q);
            if v != NONE return v;
            if !sc_is_scevable(vtype(pn)) return NONE;
            c := sc_get_scev(pn);
            if !sc_is_const(c) return NONE;
            return sc_value(c);
        }
        v := simplify_phi_node(phi);
        if v != NONE {
            if vtype(v) != vtype(phi) continue;
            sc_forget_value(phi);
            rauw_with_metadata(phi, v);
            array_add(dead, vh_new(phi));
            num_elim += 1;
            continue;
        }
        if !sc_is_scevable(vtype(phi)) continue;
        key := sc_get_scev(phi);
        found, orig := table_find(*expr_to_iv, key);
        if !found || orig == NONE {
            table_set(*expr_to_iv, key, phi);
            if type_kind(vtype(phi)) == .INT && tti && tti_is_truncate_free(tti, vtype(phi), vtype(phis[phis.count - 1])) {
                phi_expr := sc_get_scev(phi);
                if sc_is_addrec(phi_expr) {
                    trunc_expr := sc_get_truncate(phi_expr, vtype(phis[phis.count - 1]));
                    table_set(*expr_to_iv, trunc_expr, phi);
                }
            }
            continue;
        }
        if (type_kind(vtype(orig)) == .PTR) != (type_kind(vtype(phi)) == .PTR) continue;
        sx_replace_congruent_iv_inc(x, *phi, *orig, l, dead);
        table_set(*expr_to_iv, key, orig);   // OrigPhiRef may have been swapped
        num_elim += 1;
        new_iv := orig;
        if vtype(orig) != vtype(phi) {
            b: Irb;
            h := li_header(se.li, l);
            fip := sx_first_insertion_pt(h);
            irb_set_at(*b, fip.bb, fip.pt, fip.head);
            b.dbg = get_metadata(phi, 0);
            new_iv = irb_trunc_or_bitcast_named(*b, orig, vtype(phi), x.ivname);
        }
        rauw_with_metadata(phi, new_iv);
        array_add(dead, vh_new(phi));
    }
    return num_elim;
}

// IRBuilder<>::CreateTruncOrBitCast(V, DestTy, Name) with ConstantFolder
irb_trunc_or_bitcast_named :: (b: *Irb, v: Value_Id, t: Type_Id, name: string) -> Value_Id {
    opc: Opcode = ifx type_bits(scalar_type(vtype(v))) == type_bits(scalar_type(t)) then .BITCAST else .TRUNC;
    return irb_cast(b, opc, v, t, name);
}

// TargetTransformInfo::isTruncateFree
tti_is_truncate_free :: (t: *Tti, ty1: Type_Id, ty2: Type_Id) -> bool {
    if t.kind != .X86 return false;
    // X86TargetLowering::isTruncateFree(Type *, Type *)
    if type_kind(ty1) != .INT || type_kind(ty2) != .INT return false;
    return type_int_width(ty1) > type_int_width(ty2);
}

// ---------------------------------------------------------------- cost model

// hasRelatedExistingExpansion
sx_has_related_existing_expansion :: (x: *Scev_Expander, s: Scev_Id, at: Value_Id, l: Loop_Id) -> bool {
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(se.li, l, *exiting);
    for bb: exiting {
        t := block_terminator(bb);
        if inst_op(t) != .CONDBR continue;
        c := op(t, 0);
        if !is_inst(c) || inst_op(c) != .ICMP continue;
        lhs := op(c, 0); rhs := op(c, 1);
        if !is_inst(lhs) || !is_inst(rhs) continue;
        if sc_get_scev(lhs) == s && dt_dominates_inst(se.dt, lhs, at) return true;
        if sc_get_scev(rhs) == s && dt_dominates_inst(se.dt, rhs, at) return true;
    }
    drops: [..] Value_Id; drops.allocator = temp;
    return sx_find_value_in_expr_value_map(x, s, at, *drops) != NONE;
}

// costAndCollectOperands
sx_cost_and_collect_operands :: (w: Sx_Operand, tti: *Tti, kind: s64, worklist: *[..] Sx_Operand) -> Cost {
    s := w.s;
    cost: Cost = 0;
    Op_Indices :: struct { opc: Opcode; min_idx: s64; max_idx: s64; }
    operations: [..] Op_Indices; operations.allocator = temp;
    ty := sc_type(s);
    cast_cost :: (opc: Opcode, s: Scev_Id, tti: *Tti, kind: s64, operations: *[..] Op_Indices) -> Cost {
        array_add(operations, .{opc, 0, 0});
        return tti_cast_cost(tti, opc, sc_type(s), sc_type(sc_op(s, 0)), CCH_NONE, kind);
    }
    arith_cost :: (opc: Opcode, n: s64, s: Scev_Id, tti: *Tti, kind: s64, operations: *[..] Op_Indices, min_idx: s64 = 0, max_idx: s64 = 1) -> Cost {
        array_add(operations, .{opc, min_idx, max_idx});
        return cost_mul(n, tti_arith_cost(tti, opc, sc_type(s), kind));
    }
    cmp_sel_cost :: (opc: Opcode, n: s64, min_idx: s64, max_idx: s64, s: Scev_Id, tti: *Tti, kind: s64, operations: *[..] Op_Indices) -> Cost {
        array_add(operations, .{opc, min_idx, max_idx});
        t := sc_type(s);
        return cost_mul(n, tti_cmp_sel_cost(tti, opc, t, make_cmp_result_type(t), BAD_ICMP_PREDICATE, kind));
    }
    n := cast(s64) sc_nops(s);
    if sc_kind(s) == {
        case .CNC; fatal("Attempt to use a SCEVCouldNotCompute object!");
        case .UNKNOWN; #through;
        case .CONSTANT; #through;
        case .VSCALE; return 0;
        case .PTRTOADDR; cost = cast_cost(.PTRTOADDR, s, tti, kind, *operations);
        case .PTRTOINT; cost = cast_cost(.PTRTOINT, s, tti, kind, *operations);
        case .TRUNC; cost = cast_cost(.TRUNC, s, tti, kind, *operations);
        case .ZEXT; cost = cast_cost(.ZEXT, s, tti, kind, *operations);
        case .SEXT; cost = cast_cost(.SEXT, s, tti, kind, *operations);
        case .UDIV;
            opc := Opcode.UDIV;
            r := sc_op(s, 1);
            if sc_is_const(r) && ap_is_power_of_2(sc_ap(r)) opc = .LSHR;
            cost = arith_cost(opc, 1, s, tti, kind, *operations);
        case .ADD; cost = arith_cost(.ADD, n - 1, s, tti, kind, *operations);
        case .MUL;
            opc := Opcode.MUL;
            if n == 2 && sc_is_const(sc_op(s, 0)) {
                c := sc_ap(sc_op(s, 0));
                if ap_is_all_ones(c) opc = .SUB;
                else if ap_is_power_of_2(c) opc = .SHL;
            }
            cost = arith_cost(opc, n - 1, s, tti, kind, *operations);
        case .SMAX; #through;
        case .UMAX; #through;
        case .SMIN; #through;
        case .UMIN; #through;
        case .SEQ_UMIN;
            cost = cost_add(cost, cmp_sel_cost(.ICMP, n - 1, 0, 1, s, tti, kind, *operations));
            cost = cost_add(cost, cmp_sel_cost(.SELECT, n - 1, 0, 2, s, tti, kind, *operations));
            if sc_kind(s) == .SEQ_UMIN {
                cost = cost_add(cost, cmp_sel_cost(.ICMP, n - 1, 0, 0, s, tti, kind, *operations));
                cost = cost_add(cost, arith_cost(.OR, ifx n > 2 then n - 2 else 0, s, tti, kind, *operations));
                cost = cost_add(cost, cmp_sel_cost(.SELECT, 1, 0, 1, s, tti, kind, *operations));
            }
        case .ADDREC;
            num_rec := n - 1;
            cost = cost_add(cost, cost_mul(tti_cf_cost(tti, .PHI, kind), num_rec));
            cost = cost_add(cost, cost_mul(tti_arith_cost(tti, .ADD, ty, kind), num_rec));
            array_add(worklist, .{.PHI, true, 0, sc_op(s, 0)});
            for i: 1..n - 1 array_add(worklist, .{.ADD, true, 1, sc_op(s, cast(u32) i)});
    }
    for co: operations {
        for i: 0..n - 1 {
            min_idx := ifx i > co.min_idx then i else co.min_idx;
            op_idx := ifx min_idx < co.max_idx then min_idx else co.max_idx;
            array_add(worklist, .{co.opc, true, cast(s32) op_idx, sc_op(s, cast(u32) i)});
        }
    }
    return cost;
}

// isHighCostExpansionHelper
sx_is_high_cost_expansion_helper :: (x: *Scev_Expander, w: Sx_Operand, l: Loop_Id, at: Value_Id, cost: *Cost, budget: Cost, tti: *Tti,
                                     processed: *Table(Scev_Id, bool), worklist: *[..] Sx_Operand) -> bool {
    if cost.* > budget return true;
    s := w.s;
    if !sc_is_const(s) {
        if table_contains(processed, s) return false;
        table_set(processed, s, true);
    }
    if sx_has_related_existing_expansion(x, s, at, l) return false;
    kind := ifx fn_has_fn_attr(block_fn(li_header(se.li, l)), .MinSize) then TCK_CODE_SIZE else TCK_RECIP_THROUGHPUT;
    if sc_kind(s) == {
        case .CNC; fatal("Attempt to use a SCEVCouldNotCompute object!");
        case .UNKNOWN; #through;
        case .VSCALE; return false;
        case .CONSTANT;
            if kind != TCK_CODE_SIZE return false;
            cost.* = cost_add(cost.*, tti_int_imm_cost_inst(tti, w.parent_op, w.has_parent, w.operand_idx, sc_ap(s), sc_type(s), kind));
            return cost.* > budget;
        case .TRUNC; #through;
        case .PTRTOADDR; #through;
        case .PTRTOINT; #through;
        case .ZEXT; #through;
        case .SEXT;
            cost.* = cost_add(cost.*, sx_cost_and_collect_operands(w, tti, kind, worklist));
            return false;
        case .UDIV;
            if sx_has_related_existing_expansion(x, sc_get_add2(s, sc_get_constant_t(sc_type(s), 1)), at, l) return false;
            cost.* = cost_add(cost.*, sx_cost_and_collect_operands(w, tti, kind, worklist));
            return false;
        case;
            cost.* = cost_add(cost.*, sx_cost_and_collect_operands(w, tti, kind, worklist));
            return cost.* > budget;
    }
    return false;
}

// isHighCostExpansion(Exprs, L, Budget, TTI, At)
sx_is_high_cost_expansion :: (x: *Scev_Expander, exprs: [] Scev_Id, l: Loop_Id, budget: s64, tti: *Tti, at: Value_Id) -> bool {
    assert(tti != null && at != NONE);
    worklist: [..] Sx_Operand; worklist.allocator = temp;
    processed: Table(Scev_Id, bool); processed.allocator = temp;
    cost: Cost = 0;
    scaled_budget := cast(Cost) budget * TCC_BASIC;
    for exprs array_add(*worklist, .{.RET, false, -1, it});
    while worklist.count {
        w := pop(*worklist);
        if sx_is_high_cost_expansion_helper(x, w, l, at, *cost, scaled_budget, tti, *processed, *worklist) return true;
    }
    return false;
}

// ---------------------------------------------------------------- LCSSA

// fixupLCSSAFormFor
sx_fixup_lcssa_form_for :: (x: *Scev_Expander, v: Value_Id) -> Value_Id {
    if !x.preserve_lcssa || !is_inst(v) return v;
    ip := x.b.pt;
    if ip == NONE fatal("SCEVExpander: fixupLCSSAFormFor at the end of a block");
    def_loop := li_loop_for(se.li, inst_block(v));
    use_loop := li_loop_for(se.li, inst_block(ip));
    if def_loop == NONE || use_loop == def_loop || li_contains_loop(se.li, def_loop, use_loop) return v;
    to_ty: Type_Id = ifx type_kind(vtype(v)) == .INT then type_ptr(0) else ir.t_i32;
    opc: Opcode = ifx type_kind(vtype(v)) == .INT then .INTTOPTR else .PTRTOINT;
    user := new_inst(opc, to_ty, 1);
    set_op(user, 0, v);
    insert_at_position(user, x.b.bb, ip, x.b.head);
    set_name(user, "tmp.lcssa.user");
    to_update: [..] Value_Id; to_update.allocator = temp;
    array_add(*to_update, v);
    phis_to_remove: [..] Value_Id; phis_to_remove.allocator = temp;
    inserted_phis: [..] Value_Id; inserted_phis.allocator = temp;
    cache: Lcssa_Exit_Cache;
    saved := scev_pass_se;
    scev_pass_se = se;
    form_lcssa_for_instructions(*to_update, se.dt, se.li, *cache, *phis_to_remove, *inserted_phis);
    scev_pass_se = saved;
    for inserted_phis sx_remember_instruction(x, it);
    for pn: phis_to_remove {
        if has_uses(pn) continue;
        table_remove(*x.inserted_values, pn);
        table_remove(*x.inserted_post_inc_values, pn);
        erase_inst_with_metadata(pn);
    }
    r := op(user, 0);
    erase_inst_with_metadata(user);
    return r;
}

// ---------------------------------------------------------------- safety

// SCEVFindUnsafe
sx_vis_find_unsafe_follow :: (v: *Sc_Visitor, s: Scev_Id) -> bool {
    if sc_is_udiv(s) {
        r := sc_op(s, 1);
        if !sc_is_known_non_zero(r) || !sc_is_guaranteed_not_to_be_poison(r) { v.found = true; return false; }
    }
    if sc_is_addrec(s) {
        if li_loop_preheader(se.li, sc_loop(s)) == NONE && (!v.canonical_mode || !sc_is_affine(s)) { v.found = true; return false; }
    }
    return true;
}

// isSafeToExpand
sx_is_safe_to_expand :: (x: *Scev_Expander, s: Scev_Id) -> bool {
    vis: Sc_Visitor;
    vis.kind = .FIND_UNSAFE_EXPAND;
    vis.canonical_mode = x.canonical_mode;
    sc_visit_all(s, *vis);
    return !vis.found;
}

// isSafeToExpandAt
sx_is_safe_to_expand_at :: (x: *Scev_Expander, s: Scev_Id, ip: Value_Id) -> bool {
    if !sx_is_safe_to_expand(x, s) return false;
    bb := inst_block(ip);
    if sc_properly_dominates(s, bb) return true;
    if sc_dominates(s, bb) {
        if block_terminator(bb) == ip return true;
        if sc_is_unknown(s) {
            u := sc_value(s);
            for k: 0..cast(s64) nops(ip) - 1 if op(ip, cast(u32) k) == u return true;
        }
    }
    return false;
}

// SCEVExpanderCleaner::cleanup (ResultUsed = false)
sx_cleanup :: (x: *Scev_Expander) {
    for i: x.orig_flags_order {
        if vkind(i) == .DEAD continue;
        _, f := table_find(*x.orig_flags, i);
        inst(i).flags = (inst(i).flags & ~cast(u32) SX_POISON_FLAG_BITS) | f;
    }
    insts: [..] Value_Id; insts.allocator = temp;
    sx_all_inserted_instructions(x, *insts);
    sx_clear(x);
    for < i: insts {
        rauw_with_metadata(i, const_poison(vtype(i)));
        erase_inst_with_metadata(i);
    }
}

// ---------------------------------------------------------------- predicates

// expandComparePredicate / expandWrapPredicate / generateOverflowCheck / expandUnionPredicate are LoopVectorize /
// LoopVersioning entry points; nothing ported uses them yet.
sx_expand_code_for_predicate :: (x: *Scev_Expander, pred: u32, ip: Value_Id) -> Value_Id {
    fatal("SCEVExpander::expandCodeForPredicate is not supported yet");
    return NONE;
}

// TargetTransformInfo::getIntImmCostInst (X86TTIImpl::getIntImmCostInst; NoTTIImpl: TCC_Free). The expander's
// root work items have no parent opcode (LLVM's ~0U), which takes the default case.
tti_int_imm_cost_inst :: (t: *Tti, opc: Opcode, has_parent: bool, idx_in: s32, imm: APInt, ty: Type_Id, kind: s64) -> Cost {
    if !t || t.kind != .X86 return TCC_FREE;
    st := *t.xl;
    idx: u32 = cast,no_check(u32) idx_in;
    bit_size := type_int_width(ty);
    imm_bw := imm.bits;
    if bit_size == 0 return TCC_FREE;
    imm_idx: u32 = 0xFFFF_FFFF;
    if !has_parent return TCC_FREE;
    if opc == {
        case .GEP;
            if idx == 0 return 2 * TCC_BASIC;
            return TCC_FREE;
        case .STORE; imm_idx = 0;
        case .ICMP;
            if idx == 1 && imm_bw == 64 {
                v := ap_zext_value(imm);
                if v == 0x1_0000_0000 || v == 0xffff_ffff return TCC_FREE;
            }
            imm_idx = 1;
        case .AND;
            if idx == 1 && imm_bw == 64 && ap_is_int_n_unsigned(imm, 32) return TCC_FREE;
            if idx == 1 && imm_bw == 64 && st_is64Bit(st) && st_hasBMI(st) && ap_is_mask(imm)
                return x86_int_imm_cost_val(ifx st_hasBMI2(st) then 255 else 65535);
            imm_idx = 1;
        case .ADD; #through;
        case .SUB;
            if idx == 1 && imm_bw == 64 && ap_zext_value(imm) == 0x8000_0000 return TCC_FREE;
            imm_idx = 1;
        case .UDIV; #through;
        case .SDIV; #through;
        case .UREM; #through;
        case .SREM; return TCC_FREE;
        case .MUL; #through;
        case .OR; #through;
        case .XOR; imm_idx = 1;
        case .SHL; #through;
        case .LSHR; #through;
        case .ASHR; if idx == 1 return TCC_FREE;
        case .TRUNC; case .ZEXT; case .SEXT; case .INTTOPTR; case .PTRTOINT; case .BITCAST; case .PHI; case .CALL;
        case .SELECT; case .RET; case .LOAD;
        case; return TCC_FREE;
    }
    if idx == imm_idx {
        num_constants := cast(Cost)((bit_size + 63) / 64);
        c := x86_int_imm_cost(imm, ty);
        return ifx c <= num_constants * TCC_BASIC then TCC_FREE else c;
    }
    return x86_int_imm_cost(imm, ty);
}
// X86TTIImpl::getIntImmCost(int64_t)
x86_int_imm_cost_val :: (v: s64) -> Cost {
    if v == 0 return TCC_FREE;
    if v >= -0x8000_0000 && v <= 0x7fff_ffff return TCC_BASIC;
    return 2 * TCC_BASIC;
}
// X86TTIImpl::getIntImmCost(const APInt &, Type *, CostKind)
x86_int_imm_cost :: (imm: APInt, ty: Type_Id) -> Cost {
    bit_size := type_int_width(ty);
    if bit_size == 0 return 0xFFFF_FFFF;
    if bit_size > 128 return TCC_FREE;
    if ap_is_zero(imm) return TCC_FREE;
    v := imm;
    if bit_size % 64 != 0 v = ap_sext(imm, ((bit_size + 63) / 64) * 64);
    cost: Cost = 0;
    sh: u32 = 0;
    while sh < bit_size {
        tmp := ap_sext_or_trunc(ap_ashr(v, sh), 64);
        cost += x86_int_imm_cost_val(ap_sext_value(tmp));
        sh += 64;
    }
    return ifx cost > 1 then cost else 1;
}
// APInt::isIntN(N): the value fits in N bits unsigned
ap_is_int_n_unsigned :: (a: APInt, n: u32) -> bool { return ap_active_bits(a) <= n; }
