// SandboxIR, the parts the SandboxVectorizer uses: port of llvm/lib/SandboxIR/Tracker.cpp (the change log with
// save / accept / revert: UseSet, EraseFromParent, MoveInstr, CreateAndInsertInst), the callback registry and
// registerValue of llvm/lib/SandboxIR/Context.cpp, and the editing members of llvm/lib/SandboxIR/Instruction.cpp,
// Value.cpp, User.cpp and Use.cpp the vectorizer calls (eraseFromParent, moveBefore, replaceAllUsesWith, and the
// create() functions, which go through the context's IRBuilder<ConstantFolder>).
//
// Design (DESIGN.md "SandboxVectorizer"): there is no second object graph. A sandboxir::Value is the jai Value_Id
// of the llvm::Value it wraps; a sandboxir::Use is the Use_Id. The Tracker is a list of `Sbx_Change` rows undone
// in reverse by a `switch` on their kind. The context callbacks are `Sbx_Callback` rows in registration order
// (Context keeps them in a MapVector keyed by an increasing CallbackID), each naming the kind of its owner (a
// region, the seed collector, the dependency graph, the scheduler) and the owner's row; running them is a `switch`
// on the owner kind (sbv_run_*_callback in sandbox_vectorizer.jai / sandbox_sched.jai).
//
// An instruction erased while the tracker records is removed from its block (its name leaves the symbol table, its
// operands are dropped) but its row stays alive until the change is accepted, so a revert can put it back; only
// then is it deleted (`v_kind = DEAD`). LLVM frees the sandboxir object at that point, which matters for the seed
// collector's pointer-keyed lookups (sandbox_vectorizer.jai "address reuse").

Sbx_State :: enum u8 { DISABLED; RECORD; REVERTING; }
Sbx_Change_Kind :: enum u8 { USE_SET; ERASE_FROM_PARENT; MOVE_INSTR; CREATE_AND_INSERT; }
Sbx_Change :: struct {
    kind: Sbx_Change_Kind;
    inst: Value_Id = NONE;
    use: Use_Id = NONE;        // USE_SET: the use, and the value it had
    orig: Value_Id = NONE;
    next: Value_Id = NONE;     // ERASE_FROM_PARENT / MOVE_INSTR: the next instruction (NONE: inst was last in bb)
    bb: Value_Id = NONE;
    ops_start: s64;            // ERASE_FROM_PARENT: the operands, in sbx.saved_ops
    ops_count: s64;
}

Sbx_Cb_Kind :: enum u8 { CREATE; ERASE; MOVE; SET_USE; }
Sbx_Owner :: enum u8 { REGION; SEED_COLLECTOR; DAG; SCHEDULER; }
Sbx_Callback :: struct { id: s64; kind: Sbx_Cb_Kind; owner: Sbx_Owner; idx: s32; }

sbx: struct {
    state: Sbx_State;
    changes: [..] Sbx_Change;
    snapshots: [..] s64;
    saved_ops: [..] Value_Id;
    callbacks: [..] Sbx_Callback;
    next_cb_id: s64;
    irb: Irb;              // Context::LLVMIRBuilder: one builder for the whole run, its debug location persists
    initialized: bool;
}

// a [..] T living in temp for one pass run (temporary storage is reset between runs, so drop the old buffer)
sbv_temp_array :: (a: *[..] $T) {
    empty: [..] T;
    a.* = empty;
    a.allocator = temp;
}

sbx_init :: () {
    if sbx.initialized return;
    sbx.initialized = true;
    sbx.changes.allocator = context.default_allocator;
    sbx.snapshots.allocator = context.default_allocator;
    sbx.saved_ops.allocator = context.default_allocator;
    sbx.callbacks.allocator = context.default_allocator;
}

// ---------------------------------------------------------------- callbacks (Context.cpp)

sbx_register_callback :: (kind: Sbx_Cb_Kind, owner: Sbx_Owner, idx: s32) -> s64 {
    sbx.next_cb_id += 1;
    array_add(*sbx.callbacks, .{sbx.next_cb_id, kind, owner, idx});
    return sbx.next_cb_id;
}
sbx_unregister_callback :: (id: s64) {
    for sbx.callbacks if it.id == id { array_ordered_remove_by_index(*sbx.callbacks, it_index); return; }
    fatal("internal: sandbox-vectorizer: unregistering an unknown callback");
}

sbx_run_create_callbacks :: (i: Value_Id) {
    n := sbx.callbacks.count;
    for k: 0..n - 1 {
        cb := sbx.callbacks[k];
        if cb.kind != .CREATE continue;
        if cb.owner == {
            case .REGION; sbv_region_add_raw(cb.idx, i);
            case .DAG; sdag_notify_create_instr(i);
            case .SCHEDULER; ssch_notify_create_instr(i);
            case; fatal("internal: sandbox-vectorizer: bad create callback");
        }
    }
}
sbx_run_erase_callbacks :: (i: Value_Id) {
    n := sbx.callbacks.count;
    for k: 0..n - 1 {
        cb := sbx.callbacks[k];
        if cb.kind != .ERASE continue;
        if cb.owner == {
            case .REGION; sbv_region_on_erase(cb.idx, i);
            case .SEED_COLLECTOR; sbv_seeds_on_erase(i);
            case .DAG; sdag_notify_erase_instr(i);
            case; fatal("internal: sandbox-vectorizer: bad erase callback");
        }
    }
}
sbx_run_move_callbacks :: (i: Value_Id, bb: Value_Id, pt: Value_Id) {
    n := sbx.callbacks.count;
    for k: 0..n - 1 {
        cb := sbx.callbacks[k];
        if cb.kind != .MOVE continue;
        if cb.owner == {
            case .DAG; sdag_notify_move_instr(i, bb, pt);
            case; fatal("internal: sandbox-vectorizer: bad move callback");
        }
    }
}
sbx_run_set_use_callbacks :: (u: Use_Id, new_src: Value_Id) {
    n := sbx.callbacks.count;
    for k: 0..n - 1 {
        cb := sbx.callbacks[k];
        if cb.kind != .SET_USE continue;
        if cb.owner == {
            case .DAG; sdag_notify_set_use(u, new_src);
            case; fatal("internal: sandbox-vectorizer: bad set-use callback");
        }
    }
}

// ---------------------------------------------------------------- tracker (Tracker.cpp)

sbx_is_tracking :: inline () -> bool { return sbx.state == .RECORD; }

sbx_track :: (c: Sbx_Change) { if sbx_is_tracking() array_add(*sbx.changes, c); }

// Tracker::save
sbx_save :: () {
    sbx.state = .RECORD;
    array_add(*sbx.snapshots, sbx.changes.count);
}

// Tracker::revert(RevertAll = false)
sbx_revert :: () {
    if sbx.state != .RECORD || sbx.snapshots.count == 0
        fatal("sandbox-vectorizer: a transaction is reverted without tr-save (LLVM reads past its snapshot list)");
    sbx.state = .REVERTING;
    until := sbx.snapshots[sbx.snapshots.count - 1];
    k := sbx.changes.count - 1;
    while k >= until {
        sbx_revert_change(sbx.changes[k]);
        k -= 1;
    }
    sbx.changes.count = until;
    sbx.snapshots.count -= 1;
    sbx.state = ifx sbx.snapshots.count == 0 then .DISABLED else .RECORD;
}

// Tracker::accept(AcceptAll = false)
sbx_accept :: () {
    if sbx.snapshots.count > 1 { sbx.snapshots.count -= 1; return; }
    sbx.state = .DISABLED;
    for c: sbx.changes if c.kind == .ERASE_FROM_PARENT sbx_delete_removed(c.inst);   // EraseFromParent::accept
    sbx.changes.count = 0;
    sbx.saved_ops.count = 0;
    sbx.snapshots.count = 0;
}

sbx_revert_change :: (c: Sbx_Change) {
    if c.kind == {
        case .USE_SET;
            // UseSet::revert: Use::set(OrigV)
            use_set(c.use, c.orig);
        case .ERASE_FROM_PARENT;
            // EraseFromParent::revert: put it back before the instruction that followed it, restore its operands,
            // and register it again (which runs the create callbacks)
            i := c.inst;
            if c.next != NONE insert_at_position(i, inst_block(c.next), c.next, false);
            else block_append_inst(c.bb, i);
            cgp_reinsert_name(i);
            for k: 0..c.ops_count - 1 set_op(i, cast(u32) k, sbx.saved_ops[c.ops_start + k]);
            sbx_run_create_callbacks(i);
        case .MOVE_INSTR;
            // MoveInstr::revert
            if c.next != NONE sbx_move_before(c.inst, inst_block(c.next), c.next);
            else sbx_move_before(c.inst, c.bb, NONE);
        case .CREATE_AND_INSERT;
            // CreateAndInsertInst::revert: NewI->eraseFromParent()
            sbx_erase(c.inst);
    }
}

// ---------------------------------------------------------------- instructions

// Context::registerValue for a newly created instruction
sbx_register_instruction :: (i: Value_Id) {
    c: Sbx_Change; c.kind = .CREATE_AND_INSERT; c.inst = i;
    sbx_track(c);
    sbx_run_create_callbacks(i);
}

// Instruction::removeFromParent: the name leaves the symbol table (the value keeps it) and the debug records fall
// onto the next instruction
sbx_remove_from_parent :: (i: Value_Id) {
    if inst(i).records && inst_next(i) == NONE
        fatal("sandbox-vectorizer: removing the last instruction of a block that has debug records is not supported yet");
    cgp_remove_from_parent(i);
}

// The deleteValue of an instruction that was removed from its block earlier (EraseFromParent::accept)
sbx_delete_removed :: (i: Value_Id) {
    if vkind(i) != .INST || inst(i).parent != NONE fatal("internal: sandbox-vectorizer: deleting a live instruction");
    scev_note_erase(i);
    vh_note_erase(i);
    cg_vh_note_erase(i);
    vmap_note_erase(i);
    lvi_note_erase(i);
    sbv_note_freed(i, ir.v_kind.count);
    ir.v_name[i] = "";
    ir.v_md[i] = NONE;
    ir.v_kind[i] = .DEAD;
}

// Instruction::eraseFromParent
sbx_erase :: (i: Value_Id) {
    if has_uses(i) fatal("sandbox-vectorizer: erasing an instruction that still has users (LLVM asserts)");
    sbx_run_erase_callbacks(i);
    if sbx_is_tracking() {
        c: Sbx_Change; c.kind = .ERASE_FROM_PARENT; c.inst = i;
        c.next = inst_next(i); c.bb = inst_block(i);
        c.ops_start = sbx.saved_ops.count; c.ops_count = nops(i);
        for k: 0..cast(s64) nops(i) - 1 array_add(*sbx.saved_ops, op(i, cast(u32) k));
        array_add(*sbx.changes, c);
        sbx_remove_from_parent(i);
        drop_all_references(i);
    } else {
        sbv_note_freed(i, ir.v_kind.count);
        erase_inst(i);
    }
}

// Instruction::moveBefore(BB, WhereIt): pt = NONE is BB->end()
sbx_move_before :: (i: Value_Id, bb: Value_Id, pt: Value_Id) {
    if inst_block(i) == bb && inst_next(i) == pt return;   // std::next(getIterator()) == WhereIt
    sbx_run_move_callbacks(i, bb, pt);
    c: Sbx_Change; c.kind = .MOVE_INSTR; c.inst = i; c.next = inst_next(i); c.bb = inst_block(i);
    sbx_track(c);
    if pt != NONE inst_move_before_dbg(i, pt);
    else {
        if inst(i).records fatal("sandbox-vectorizer: moving an instruction with debug records to the end of a block is not supported yet");
        inst_move_to_end(i, bb);
    }
}

// Value::replaceAllUsesWith: every use is reported to the set-use callbacks and tracked, then LLVM's RAUW
sbx_rauw :: (old: Value_Id, new: Value_Id) {
    u := ir.v_first_use[old];
    while u != NONE {
        user := ir.u_user[u];
        if user != NONE && is_constant_kind(vkind(user))
            fatal("sandbox-vectorizer: replacing a value that constants use is not supported");
        sbx_run_set_use_callbacks(u, new);
        c: Sbx_Change; c.kind = .USE_SET; c.use = u; c.orig = old;
        sbx_track(c);
        u = ir.u_next[u];
    }
    replace_all_uses_with(old, new);
}

// ---------------------------------------------------------------- create() through the context's IRBuilder

// Instruction::setInsertPos: before pt (and its debug location), or at the end of bb (debug location unchanged)
sbx_set_insert_pos :: (bb: Value_Id, pt: Value_Id) {
    if pt != NONE irb_set_before(*sbx.irb, pt);
    else irb_set_end(*sbx.irb, bb);
}

// What the builder returned: a constant (folded), or a new instruction to register
sbx_created :: (r: Value_Id, first_new: s64) -> Value_Id {
    if is_inst(r) {
        if cast(s64) r < first_new fatal("sandbox-vectorizer: the builder returned an existing instruction (LLVM registers it twice)");
        sbx_register_instruction(r);
    }
    return r;
}

// CastInst::create
sbx_create_cast :: (dt: Type_Id, opc: Opcode, v: Value_Id, bb: Value_Id, pt: Value_Id, name: string) -> Value_Id {
    first := ir.v_kind.count;
    sbx_set_insert_pos(bb, pt);
    return sbx_created(irb_cast(*sbx.irb, opc, v, dt, name), first);
}

// CmpInst::create (no flags copied)
sbx_create_cmp :: (is_fcmp: bool, pred: u8, l: Value_Id, r: Value_Id, bb: Value_Id, pt: Value_Id, name: string) -> Value_Id {
    first := ir.v_kind.count;
    sbx_set_insert_pos(bb, pt);
    if is_const(l) && is_const(r) {
        f := cf_compare(pred, l, r);
        if f != NONE return f;
    }
    i := ifx is_fcmp then create_fcmp(pred, l, r) else create_icmp(pred, l, r);
    return sbx_created(irb_insert(*sbx.irb, i, name), first);
}

// SelectInst::create
sbx_create_select :: (c: Value_Id, t: Value_Id, f: Value_Id, bb: Value_Id, pt: Value_Id, name: string) -> Value_Id {
    first := ir.v_kind.count;
    sbx_set_insert_pos(bb, pt);
    return sbx_created(irb_select(*sbx.irb, c, t, f, name), first);
}

// UnaryOperator::createWithCopiedFlags
sbx_create_unop_copied_flags :: (opc: Opcode, v: Value_Id, from: Value_Id, bb: Value_Id, pt: Value_Id, name: string) -> Value_Id {
    first := ir.v_kind.count;
    sbx_set_insert_pos(bb, pt);
    if is_const(v) {
        f := cf_unary(opc, v);
        if f != NONE return f;
    }
    i := new_inst(opc, vtype(v), 1);
    set_op(i, 0, v);
    r := sbx_created(irb_insert(*sbx.irb, i, name), first);
    copy_ir_flags(r, from);
    return r;
}

// BinaryOperator::createWithCopiedFlags
sbx_create_binop_copied_flags :: (opc: Opcode, l: Value_Id, r: Value_Id, from: Value_Id, bb: Value_Id, pt: Value_Id, name: string) -> Value_Id {
    first := ir.v_kind.count;
    sbx_set_insert_pos(bb, pt);
    v := sbx_created(irb_binop(*sbx.irb, opc, l, r, name), first);
    if is_inst(v) copy_ir_flags(v, from);
    return v;
}

// LoadInst::create (not volatile)
sbx_create_load :: (ty: Type_Id, ptr: Value_Id, align: u64, bb: Value_Id, pt: Value_Id, name: string) -> Value_Id {
    first := ir.v_kind.count;
    sbx_set_insert_pos(bb, pt);
    return sbx_created(irb_load(*sbx.irb, ty, ptr, align, false, name), first);
}

// StoreInst::create (not volatile)
sbx_create_store :: (v: Value_Id, ptr: Value_Id, align: u64, bb: Value_Id, pt: Value_Id) -> Value_Id {
    first := ir.v_kind.count;
    sbx_set_insert_pos(bb, pt);
    return sbx_created(irb_store(*sbx.irb, v, ptr, align, false), first);
}

// ExtractElementInst::create(Vec, Idx)
sbx_create_extract_element :: (vec: Value_Id, idx: Value_Id, bb: Value_Id, pt: Value_Id, name: string) -> Value_Id {
    first := ir.v_kind.count;
    sbx_set_insert_pos(bb, pt);
    if is_const(vec) && is_const(idx) return ce_extract_element(vec, idx);
    i := new_inst(.EXTRACTELEMENT, type_elem(vtype(vec)), 2);
    set_op(i, 0, vec); set_op(i, 1, idx);
    return sbx_created(irb_insert(*sbx.irb, i, name), first);
}

// InsertElementInst::create(Vec, NewElt, Idx)
sbx_create_insert_element :: (vec: Value_Id, elt: Value_Id, idx: Value_Id, bb: Value_Id, pt: Value_Id, name: string) -> Value_Id {
    first := ir.v_kind.count;
    sbx_set_insert_pos(bb, pt);
    if is_const(vec) && is_const(elt) && is_const(idx) return ce_insert_element(vec, elt, idx);
    i := new_inst(.INSERTELEMENT, vtype(vec), 3);
    set_op(i, 0, vec); set_op(i, 1, elt); set_op(i, 2, idx);
    return sbx_created(irb_insert(*sbx.irb, i, name), first);
}

// ShuffleVectorInst::create(V1, V2, ArrayRef<int> Mask): -1 is a poison lane
sbx_create_shuffle :: (v1: Value_Id, v2: Value_Id, mask: [] s32, bb: Value_Id, pt: Value_Id, name: string) -> Value_Id {
    first := ir.v_kind.count;
    sbx_set_insert_pos(bb, pt);
    m := NewArray(mask.count, u32,, allocator = temp);
    for mask m[it_index] = ifx it < 0 then POISON_MASK_ELEM else cast(u32) it;
    return sbx_created(irb_shuffle(*sbx.irb, v1, v2, m, name), first);
}
