// Loop safety information: port of the LoopSafetyInfo / ICFLoopSafetyInfo half of llvm/lib/Analysis/MustExecute.cpp
// (computeLoopSafetyInfo, allLoopPathsLeadToBlock, CanProveNotTakenFirstIteration, collectTransitivePredecessors,
// isGuaranteedToExecute, doesNotWriteMemoryBefore, insertInstructionTo / removeInstruction) and of
// llvm/lib/Analysis/InstructionPrecedenceTracking.cpp (ImplicitControlFlowTracking, MemoryWriteTracking).
// SimpleLoopSafetyInfo, the must-execute printers and MustBeExecutedContextExplorer are not ported.
//
// The two InstructionPrecedenceTracking subclasses are one struct with a `kind`; isSpecialInstruction switches on it.
// The cache keeps LLVM's (possibly stale) semantics: an entry is only dropped by insertInstructionTo of a special
// instruction or removeInstruction of the cached instruction.
//
// computeBlockColors uses colorEHFunclets (llvm/lib/IR/EHPersonalities.cpp) for scoped EH personalities.

IID_EXPERIMENTAL_WIDENABLE_CONDITION :: #run iid_by_name("llvm.experimental.widenable.condition");

Ipt_Kind :: enum u8 { IMPLICIT_CONTROL_FLOW; MEMORY_WRITE; }

Instruction_Precedence_Tracking :: struct {
    kind: Ipt_Kind;
    first_special: Table(Value_Id, Value_Id);   // FirstSpecialInsts (NONE = the block has none)
}

ipt_init :: (t: *Instruction_Precedence_Tracking, kind: Ipt_Kind) {
    t.kind = kind;
    t.first_special.allocator = temp;
}
// isSpecialInstruction
ipt_is_special :: (t: *Instruction_Precedence_Tracking, i: Value_Id) -> bool {
    if t.kind == {
        case .IMPLICIT_CONTROL_FLOW; return !is_guaranteed_to_transfer_execution(i);
        case .MEMORY_WRITE;
            if call_iid(i) == IID_EXPERIMENTAL_WIDENABLE_CONDITION return false;
            return may_write_to_memory(i);
    }
    return false;
}
// getFirstSpecialInstruction
ipt_first_special :: (t: *Instruction_Precedence_Tracking, bb: Value_Id) -> Value_Id {
    found, v := table_find(*t.first_special, bb);
    if found return v;
    r: Value_Id = NONE;
    for block_insts(bb) if ipt_is_special(t, it) { r = it; break; }
    table_set(*t.first_special, bb, r);
    return r;
}
ipt_has_special :: (t: *Instruction_Precedence_Tracking, bb: Value_Id) -> bool { return ipt_first_special(t, bb) != NONE; }
// isPreceededBySpecialInstruction
ipt_is_preceded_by_special :: (t: *Instruction_Precedence_Tracking, i: Value_Id) -> bool {
    f := ipt_first_special(t, inst_block(i));
    return f != NONE && comes_before(f, i);
}
// insertInstructionTo
ipt_insert_instruction_to :: (t: *Instruction_Precedence_Tracking, i: Value_Id, bb: Value_Id) {
    if ipt_is_special(t, i) table_remove(*t.first_special, bb);
}
// removeInstruction
ipt_remove_instruction :: (t: *Instruction_Precedence_Tracking, i: Value_Id) {
    bb := inst_block(i);
    found, v := table_find(*t.first_special, bb);
    if found && v == i table_remove(*t.first_special, bb);
}

// ICFLoopSafetyInfo
Loop_Safety_Info :: struct {
    may_throw: bool;
    icf: Instruction_Precedence_Tracking;
    mw: Instruction_Precedence_Tracking;
    li: *Loop_Info;
    block_colors: Table(Value_Id, [..] Value_Id);   // BlockColors (empty unless the personality is scoped)
}

// colorEHFunclets
color_eh_funclets :: (f: Value_Id, colors: *Table(Value_Id, [..] Value_Id)) {
    Item :: struct { visiting: Value_Id; color: Value_Id; }
    wl: [..] Item; wl.allocator = temp;
    entry := fn_entry(f);
    array_add(*wl, .{entry, entry});
    succs: [..] Value_Id; succs.allocator = temp;
    while wl.count {
        it := pop(*wl);
        visiting := it.visiting; color := it.color;
        if block_is_eh_pad(visiting) color = visiting;
        cv := table_find_pointer(colors, visiting);
        if !cv { e: [..] Value_Id; e.allocator = temp; table_set(colors, visiting, e); cv = table_find_pointer(colors, visiting); }
        dup := false;
        for cv.* if it == color { dup = true; break; }
        if dup continue;
        array_add(cv, color);
        succ_color := color;
        t := block_terminator(visiting);
        if inst_op(t) == .CATCHRET {
            cp := op(t, 0);
            cs := op(cp, nops(cp) - 1);
            parent := op(cs, 0);
            if vkind(parent) == .C_TOKEN_NONE succ_color = entry;
            else succ_color = inst_block(parent);
        }
        block_successors(visiting, *succs);
        for s: succs array_add(*wl, .{s, succ_color});
    }
}
lsi_has_colors :: (s: *Loop_Safety_Info) -> bool { return s.block_colors.count > 0; }
// copyColors(New, Old)
lsi_copy_colors :: (s: *Loop_Safety_Info, new: Value_Id, old: Value_Id) {
    src := table_find_pointer(*s.block_colors, old);
    e: [..] Value_Id; e.allocator = temp;
    if src for src.* array_add(*e, it);
    table_set(*s.block_colors, new, e);
}

// computeLoopSafetyInfo
lsi_compute :: (s: *Loop_Safety_Info, li: *Loop_Info, l: Loop_Id) {
    s.li = li;
    ipt_init(*s.icf, .IMPLICIT_CONTROL_FLOW);
    ipt_init(*s.mw, .MEMORY_WRITE);
    s.may_throw = false;
    for li.loops[l].blocks if ipt_has_special(*s.icf, it) { s.may_throw = true; break; }
    // computeBlockColors
    f := block_fn(li_header(li, l));
    p := fn_personality(f);
    s.block_colors.allocator = temp;
    if p != NONE && is_scoped_eh_personality(classify_eh_personality(p)) color_eh_funclets(f, *s.block_colors);
}
lsi_block_may_throw :: (s: *Loop_Safety_Info, bb: Value_Id) -> bool { return ipt_has_special(*s.icf, bb); }
lsi_insert_instruction_to :: (s: *Loop_Safety_Info, i: Value_Id, bb: Value_Id) {
    ipt_insert_instruction_to(*s.icf, i, bb);
    ipt_insert_instruction_to(*s.mw, i, bb);
}
lsi_remove_instruction :: (s: *Loop_Safety_Info, i: Value_Id) {
    ipt_remove_instruction(*s.icf, i);
    ipt_remove_instruction(*s.mw, i);
}

// CanProveNotTakenFirstIteration
can_prove_not_taken_first_iteration :: (exit: Value_Id, dt: *Dom_Tree, li: *Loop_Info, l: Loop_Id) -> bool {
    cond_exit := block_single_predecessor(exit);
    if cond_exit == NONE return false;
    bi := block_terminator(cond_exit);
    if inst_op(bi) != .CONDBR return false;
    c := op(bi, 0);
    if is_const_int(c) return get_successor(bi, ifx !ap_is_zero(const_ap(c)) then cast(u32) 1 else 0) == exit;
    if !is_inst(c) || (inst_op(c) != .ICMP && inst_op(c) != .FCMP) return false;
    pred := inst_pred(c);
    lhs := op(c, 0);
    rhs := op(c, 1);
    header := li_header(li, l);
    if !is_inst(lhs) || inst_op(lhs) != .PHI || inst_block(lhs) != header {
        pred = cmp_swapped(pred);
        lhs = op(c, 1);
        rhs = op(c, 0);
        if !is_inst(lhs) || inst_op(lhs) != .PHI || inst_block(lhs) != header return false;
    }
    iv_start := phi_incoming_value_for_block(lhs, li_loop_preheader(li, l));
    q: Simplify_Query; q.dt = dt; q.cxt = bi; q.have_tli = false;
    sv := simplify_cmp_inst(pred, false, iv_start, rhs, q);
    if sv == NONE || !is_constant_kind(vkind(sv)) return false;
    if exit == get_successor(bi, 0) return is_null_value(sv);
    return cf_is_all_ones(sv);
}

// collectTransitivePredecessors
collect_transitive_predecessors :: (li: *Loop_Info, l: Loop_Id, bb: Value_Id, preds: *Table(Value_Id, bool), order: *[..] Value_Id) {
    header := li_header(li, l);
    if bb == header return;
    wl: [..] Value_Id; wl.allocator = temp;
    ps: [..] Value_Id; ps.allocator = temp;
    block_predecessors(bb, *ps);
    for p: ps {
        if !li_contains(li, l, p) continue;
        if !table_contains(preds, p) { table_set(preds, p, true); array_add(order, p); }
        array_add(*wl, p);
    }
    pp: [..] Value_Id; pp.allocator = temp;
    while wl.count {
        p := pop(*wl);
        if p == header continue;
        block_predecessors(p, *pp);
        for x: pp {
            if li_contains(li, l, x) && !table_contains(preds, x) {
                table_set(preds, x, true); array_add(order, x);
                array_add(*wl, x);
            }
        }
    }
}

// allLoopPathsLeadToBlock
lsi_all_loop_paths_lead_to_block :: (s: *Loop_Safety_Info, l: Loop_Id, bb: Value_Id, dt: *Dom_Tree) -> bool {
    li := s.li;
    header := li_header(li, l);
    if bb == header return true;
    preds: Table(Value_Id, bool); preds.allocator = temp;
    order: [..] Value_Id; order.allocator = temp;   // the SmallPtrSet's iteration order doesn't change the answer
    collect_transitive_predecessors(li, l, bb, *preds, *order);
    hp: [..] Value_Id; hp.allocator = temp;
    block_predecessors(header, *hp);
    for hp if table_contains(*preds, it) return false;
    checked: Table(Value_Id, bool); checked.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    for p: order {
        if lsi_block_may_throw(s, p) return false;
        if dt_dominates(dt, bb, p) continue;
        block_successors(p, *succs);
        for sc: succs {
            if table_contains(*checked, sc) continue;
            table_set(*checked, sc, true);
            if sc != bb && !table_contains(*preds, sc)
                if li_contains(li, l, sc) || !can_prove_not_taken_first_iteration(sc, dt, li, l) return false;
        }
    }
    return true;
}

// ICFLoopSafetyInfo::isGuaranteedToExecute
lsi_is_guaranteed_to_execute :: (s: *Loop_Safety_Info, i: Value_Id, dt: *Dom_Tree, l: Loop_Id) -> bool {
    return !ipt_is_preceded_by_special(*s.icf, i) && lsi_all_loop_paths_lead_to_block(s, l, inst_block(i), dt);
}
// doesNotWriteMemoryBefore(BB, CurLoop)
lsi_does_not_write_memory_before_block :: (s: *Loop_Safety_Info, bb: Value_Id, l: Loop_Id) -> bool {
    li := s.li;
    if bb == li_header(li, l) return true;
    preds: Table(Value_Id, bool); preds.allocator = temp;
    order: [..] Value_Id; order.allocator = temp;
    collect_transitive_predecessors(li, l, bb, *preds, *order);
    for order if ipt_has_special(*s.mw, it) return false;
    return true;
}
// doesNotWriteMemoryBefore(I, CurLoop)
lsi_does_not_write_memory_before :: (s: *Loop_Safety_Info, i: Value_Id, l: Loop_Id) -> bool {
    return !ipt_is_preceded_by_special(*s.mw, i) && lsi_does_not_write_memory_before_block(s, inst_block(i), l);
}
