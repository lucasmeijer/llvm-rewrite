// IR mutation and CFG API shared by all passes.
// Ported from llvm/lib/IR/{BasicBlock,Instructions,Instruction,User}.cpp (removePredecessor, splitBasicBlock,
// PHINode::removeIncomingValue/hasConstantValue, dropPoisonGenerating*), llvm/include/llvm/IR/CFG.h
// (pred/succ iteration order), llvm/lib/Analysis/CFG.cpp (FindFunctionBackedges, isCriticalEdge) and the IRBuilder
// conventions passes rely on (insert, then setName; see DESIGN.md "Pass infrastructure").
//
// Low-level primitives (new_inst, set_op, add_op, replace_all_uses_with, erase_inst, inst_insert_before, ...) are in
// ir.jai; this file builds the operations passes actually call on top of them.

// ---------------------------------------------------------------- iteration

// for b: fn_blocks(f)      blocks in layout order (next block read after the body: don't erase `b` in the body)
// for i: block_insts(b)    instructions in order (same rule)
// for :early_inc i: block_insts(b) / fn_insts(f)    next read before the body (make_early_inc_range): may erase `i`
Fn_Blocks :: struct { f: Value_Id; }
Block_Insts :: struct { b: Value_Id; }
Fn_Insts :: struct { f: Value_Id; }
fn_blocks :: inline (f: Value_Id) -> Fn_Blocks { return .{f}; }
block_insts :: inline (b: Value_Id) -> Block_Insts { return .{b}; }
fn_insts :: inline (f: Value_Id) -> Fn_Insts { return .{f}; }

for_expansion :: (r: Fn_Blocks, body: Code, flags: For_Flags) #expand {
    `it := glob(r.f).first_block;
    `it_index := 0;
    while it != NONE {
        defer { it = block(it).next; it_index += 1; }
        #insert body;
    }
}
for_expansion :: (r: Block_Insts, body: Code, flags: For_Flags) #expand {
    `it := block(r.b).first;
    `it_index := 0;
    while it != NONE {
        defer { it = inst(it).next; it_index += 1; }
        #insert body;
    }
}
for_expansion :: (r: Fn_Insts, body: Code, flags: For_Flags) #expand {
    _b := glob(r.f).first_block;
    `it_index := 0;
    while _b != NONE {
        `it := block(_b).first;
        while it != NONE {
            defer { it = inst(it).next; it_index += 1; }
            #insert body;
        }
        _b = block(_b).next;
    }
}
early_inc :: (r: Block_Insts, body: Code, flags: For_Flags) #expand {
    `it := block(r.b).first;
    `it_index := 0;
    while it != NONE {
        _next := inst(it).next;
        defer { it = _next; it_index += 1; }
        #insert body;
    }
}
early_inc :: (r: Fn_Insts, body: Code, flags: For_Flags) #expand {
    _b := glob(r.f).first_block;
    `it_index := 0;
    while _b != NONE {
        _nb := block(_b).next;
        `it := block(_b).first;
        while it != NONE {
            _next := inst(it).next;
            defer { it = _next; it_index += 1; }
            #insert body;
        }
        _b = _nb;
    }
}
// reverse(instructions(F)) with early increment (prev read before the body)
reverse_early_inc :: (r: Fn_Insts, body: Code, flags: For_Flags) #expand {
    _b := glob(r.f).last_block;
    `it_index := 0;
    while _b != NONE {
        _pb := block(_b).prev;
        `it := block(_b).last;
        while it != NONE {
            _prev := inst(it).prev;
            defer { it = _prev; it_index += 1; }
            #insert body;
        }
        _b = _pb;
    }
}

is_inst :: inline (v: Value_Id) -> bool { return v != NONE && vkind(v) == .INST; }
is_block :: inline (v: Value_Id) -> bool { return v != NONE && vkind(v) == .BLOCK; }
is_phi :: inline (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .PHI; }
inst_block :: inline (i: Value_Id) -> Value_Id { return inst(i).parent; }
inst_next :: inline (i: Value_Id) -> Value_Id { return inst(i).next; }
inst_prev :: inline (i: Value_Id) -> Value_Id { return inst(i).prev; }
block_first :: inline (b: Value_Id) -> Value_Id { return block(b).first; }
block_last :: inline (b: Value_Id) -> Value_Id { return block(b).last; }
block_fn :: inline (b: Value_Id) -> Value_Id { return block(b).parent; }
fn_entry :: inline (f: Value_Id) -> Value_Id { return glob(f).first_block; }
block_size :: (b: Value_Id) -> int { n := 0; for block_insts(b) n += 1; return n; }
fn_num_blocks :: (f: Value_Id) -> int { n := 0; for fn_blocks(f) n += 1; return n; }

// BasicBlock::getTerminator: the last instruction if it is a terminator
block_terminator :: (b: Value_Id) -> Value_Id {
    l := block(b).last;
    if l == NONE || !is_terminator(inst_op(l)) return NONE;
    return l;
}

// getFirstNonPHI
block_first_non_phi :: (b: Value_Id) -> Value_Id {
    for block_insts(b) if inst_op(it) != .PHI return it;
    return NONE;
}

// ---------------------------------------------------------------- successors (Instruction::getSuccessor)

// Operand index of successor `i` of terminator `t`.
succ_operand_index :: (t: Value_Id, i: u32) -> u32 {
    opc := inst_op(t);
    if opc == {
        case .BR; return i;
        case .CONDBR; return 1 + i;
        case .SWITCH; return 1 + i;
        case .INDIRECTBR; return 1 + i;
        case .INVOKE; return nops(t) - 3 + i;
    }
    fatal("successors of '%' are not supported yet", opcode_name(opc));
    return 0;
}

num_successors :: (t: Value_Id) -> u32 {
    opc := inst_op(t);
    if opc == {
        case .RET; #through;
        case .UNREACHABLE; #through;
        case .RESUME; return 0;
        case .BR; return 1;
        case .CONDBR; return 2;
        case .SWITCH; return nops(t) - 1;
        case .INDIRECTBR; return nops(t) - 1;
        case .INVOKE; return 2;
    }
    fatal("successors of '%' are not supported yet", opcode_name(opc));
    return 0;
}
get_successor :: inline (t: Value_Id, i: u32) -> Value_Id { return op(t, succ_operand_index(t, i)); }
set_successor :: inline (t: Value_Id, i: u32, b: Value_Id) { set_op(t, succ_operand_index(t, i), b); }

// successors(BB) in terminator order (with duplicates)
block_successors :: (b: Value_Id, out: *[..] Value_Id) {
    out.count = 0;
    t := block_terminator(b);
    if t == NONE return;
    n := num_successors(t);
    if n > 0 for i: 0..n-1 array_add(out, get_successor(t, i));
}
block_num_successors :: (b: Value_Id) -> u32 {
    t := block_terminator(b);
    if t == NONE return 0;
    return num_successors(t);
}
succ_contains :: (b: Value_Id, s: Value_Id) -> bool {
    t := block_terminator(b);
    if t == NONE return false;
    n := num_successors(t);
    if n > 0 for i: 0..n-1 if get_successor(t, i) == s return true;
    return false;
}

// predecessors(BB): users of the block that are terminators, in use-list order (with duplicates), like pred_begin.
block_predecessors :: (b: Value_Id, out: *[..] Value_Id) {
    out.count = 0;
    u := ir.v_first_use[b];
    while u != NONE {
        user := ir.u_user[u];
        if is_inst(user) && is_terminator(inst_op(user)) array_add(out, inst(user).parent);
        u = ir.u_next[u];
    }
}
block_has_predecessors :: (b: Value_Id) -> bool {
    u := ir.v_first_use[b];
    while u != NONE {
        user := ir.u_user[u];
        if is_inst(user) && is_terminator(inst_op(user)) return true;
        u = ir.u_next[u];
    }
    return false;
}
// getSinglePredecessor / getUniquePredecessor
block_single_predecessor :: (b: Value_Id) -> Value_Id {
    p: Value_Id = NONE;
    u := ir.v_first_use[b];
    while u != NONE {
        user := ir.u_user[u];
        if is_inst(user) && is_terminator(inst_op(user)) {
            if p != NONE return NONE;
            p = inst(user).parent;
        }
        u = ir.u_next[u];
    }
    return p;
}

// ---------------------------------------------------------------- phis

phi_num_incoming :: inline (p: Value_Id) -> u32 { return nops(p); }
phi_value :: inline (p: Value_Id, i: u32) -> Value_Id { return op(p, i); }
phi_block :: inline (p: Value_Id, i: u32) -> Value_Id { return ir.u_aux[ir.v_ops[p] + i]; }
phi_set_value :: inline (p: Value_Id, i: u32, v: Value_Id) { set_op(p, i, v); }
phi_set_block :: inline (p: Value_Id, i: u32, b: Value_Id) { ir.u_aux[ir.v_ops[p] + i] = b; }
phi_add_incoming :: inline (p: Value_Id, v: Value_Id, b: Value_Id) { add_op(p, v, b); }
phi_block_index :: (p: Value_Id, b: Value_Id) -> s64 {
    n := nops(p);
    if n > 0 for i: 0..n-1 if phi_block(p, i) == b return cast(s64) i;
    return -1;
}

// PHINode::removeIncomingValue(Idx, DeletePHIIfEmpty): the last entry moves into the hole (Use::set).
phi_remove_incoming :: (p: Value_Id, idx: u32, delete_if_empty := true) -> Value_Id {
    removed := phi_value(p, idx);
    last := nops(p) - 1;
    if idx != last {
        phi_set_value(p, idx, phi_value(p, last));
        phi_set_block(p, idx, phi_block(p, last));
    }
    use_set(op_use(p, last), NONE);
    ir.u_aux[op_use(p, last)] = NONE;
    ir.v_nops[p] = last;
    if last == 0 && delete_if_empty {
        replace_all_uses_with(p, const_poison(vtype(p)));
        erase_inst(p);
    }
    return removed;
}
phi_remove_incoming_block :: (p: Value_Id, b: Value_Id, delete_if_empty := true) -> Value_Id {
    idx := phi_block_index(p, b);
    assert(idx >= 0, "phi has no entry for the block");
    return phi_remove_incoming(p, cast(u32) idx, delete_if_empty);
}

// PHINode::hasConstantValue
phi_has_constant_value :: (p: Value_Id) -> Value_Id {
    c := phi_value(p, 0);
    n := nops(p);
    if n > 1 for i: 1..n-1 {
        v := phi_value(p, i);
        if v != c && v != p {
            if c != p return NONE;
            c = v;
        }
    }
    if c == p return const_poison(vtype(p));
    return c;
}

phi_replace_incoming_block :: (p: Value_Id, old: Value_Id, new: Value_Id) {
    n := nops(p);
    if n > 0 for i: 0..n-1 if phi_block(p, i) == old phi_set_block(p, i, new);
}
// BasicBlock::replacePhiUsesWith
block_replace_phi_uses_with :: (b: Value_Id, old: Value_Id, new: Value_Id) {
    for block_insts(b) {
        if inst_op(it) != .PHI break;
        phi_replace_incoming_block(it, old, new);
    }
}
// BasicBlock::replaceSuccessorsPhiUsesWith
block_replace_successors_phi_uses_with :: (b: Value_Id, old: Value_Id, new: Value_Id) {
    t := block_terminator(b);
    if t == NONE return;
    n := num_successors(t);
    if n > 0 for i: 0..n-1 block_replace_phi_uses_with(get_successor(t, i), old, new);
}

// BasicBlock::removePredecessor
block_remove_predecessor :: (b: Value_Id, pred: Value_Id, keep_one_input_phis := false) {
    first := block(b).first;
    if first == NONE || inst_op(first) != .PHI return;
    num_preds := nops(first);
    for :early_inc block_insts(b) {
        if inst_op(it) != .PHI break;
        phi_remove_incoming_block(it, pred, !keep_one_input_phis);
        if keep_one_input_phis continue;
        if num_preds == 1 continue;
        c := phi_has_constant_value(it);
        if c != NONE {
            replace_all_uses_with(it, c);
            erase_inst(it);
        }
    }
}

// ---------------------------------------------------------------- creating and placing values

// Insert `i` before `pos` and name it (IRBuilder::Insert: insert first, then setName, so uniquing sees the
// function's symbol table).
insert_before_named :: (i: Value_Id, pos: Value_Id, name: string) -> Value_Id {
    inst_insert_before(i, pos);
    if name.count set_name(i, name);
    return i;
}
insert_at_end_named :: (i: Value_Id, b: Value_Id, name: string) -> Value_Id {
    block_append_inst(b, i);
    if name.count set_name(i, name);
    return i;
}
inst_insert_after :: (i: Value_Id, pos: Value_Id) {
    nx := inst(pos).next;
    if nx != NONE { inst_insert_before(i, nx); return; }
    block_append_inst(inst(pos).parent, i);
}
// Instruction::moveBefore
inst_move_before :: (i: Value_Id, pos: Value_Id) {
    inst_unlink(i);
    inst_insert_before(i, pos);
}
inst_move_to_end :: (i: Value_Id, b: Value_Id) {
    inst_unlink(i);
    block_append_inst(b, i);
}

// Instruction::eraseFromParent for instructions whose uses were already dropped by the caller as a group
// (ADCE/BDCE drop all references of every dead instruction first).
erase_dead_inst :: (i: Value_Id) { erase_inst(i); }

// Instruction::dropAllReferences
inst_drop_all_references :: (i: Value_Id) { drop_all_references(i); }

// UncondBrInst::Create(Dest)
create_br :: (dest: Value_Id) -> Value_Id {
    i := new_inst(.BR, ir.t_void, 1);
    set_op(i, 0, dest);
    return i;
}
// CondBrInst::Create(Cond, IfTrue, IfFalse)
create_cond_br :: (c: Value_Id, t: Value_Id, f: Value_Id) -> Value_Id {
    i := new_inst(.CONDBR, ir.t_void, 3);
    set_op(i, 0, c); set_op(i, 1, t); set_op(i, 2, f);
    return i;
}
// CastInst::Create
create_cast :: (opc: Opcode, v: Value_Id, ty: Type_Id) -> Value_Id {
    i := new_inst(opc, ty, 1);
    set_op(i, 0, v);
    return i;
}
// BinaryOperator::Create
create_binop :: (opc: Opcode, a: Value_Id, b: Value_Id) -> Value_Id {
    i := new_inst(opc, vtype(a), 2);
    set_op(i, 0, a); set_op(i, 1, b);
    return i;
}
// PHINode::Create(Ty, NumReservedValues)
create_phi :: (ty: Type_Id, reserved: u32) -> Value_Id {
    i := new_inst(.PHI, ty, 0);
    grow_ops(i, reserved);
    return i;
}

// Copy the !dbg attachment (Instruction::setDebugLoc(Other->getDebugLoc()))
copy_debug_loc :: (to: Value_Id, from: Value_Id) {
    dbg := get_metadata(from, 0);
    if dbg != NONE set_metadata(to, 0, dbg);
}

// ---------------------------------------------------------------- blocks

fn_insert_block_after :: (f: Value_Id, after: Value_Id, b: Value_Id) {
    g := glob(f);
    br := block(b);
    br.parent = f;
    if after == NONE {    // insert at the front
        br.prev = NONE; br.next = g.first_block;
        if g.first_block != NONE block(g.first_block).prev = b; else g.last_block = b;
        g.first_block = b;
        return;
    }
    nx := block(after).next;
    br.prev = after; br.next = nx;
    block(after).next = b;
    if nx != NONE block(nx).prev = b; else g.last_block = b;
}
fn_insert_block_before :: (f: Value_Id, before: Value_Id, b: Value_Id) {
    if before == NONE { fn_append_block(f, b); return; }
    fn_insert_block_after(f, block(before).prev, b);
}

// BasicBlock::Create(Ctx, Name, Parent, InsertBefore): a new empty block in f before `before` (NONE = at the end).
create_block :: (f: Value_Id, name: string, before: Value_Id = NONE) -> Value_Id {
    b := new_block(f);
    fn_insert_block_before(f, before, b);
    if name.count set_name(b, name);
    return b;
}

// BasicBlock::splitBasicBlock(I, Name): instructions from `at` to the end move to a new block placed after `old`,
// `old` gets an unconditional branch to it, successor phis are rewired.
split_basic_block :: (old: Value_Id, at: Value_Id, name: string) -> Value_Id {
    f := block(old).parent;
    nb := create_block(f, name, block(old).next);
    loc := get_metadata(at, 0);
    // splice [at, end) into nb
    i := at;
    while i != NONE {
        nx := inst(i).next;
        inst_unlink(i);
        block_append_inst(nb, i);
        i = nx;
    }
    br := create_br(nb);
    block_append_inst(old, br);
    if loc != NONE set_metadata(br, 0, loc);
    block_replace_successors_phi_uses_with(nb, old, nb);
    return nb;
}

// Replace the terminator of `b` with `new_term` (created, unlinked); the old one is erased.
// Mirrors the IRBuilder(PredTerm).CreateBr(...) + PredTerm->eraseFromParent() idiom.
replace_terminator :: (old_term: Value_Id, new_term: Value_Id) {
    inst_insert_before(new_term, old_term);
    drop_all_references(old_term);
    erase_inst(old_term);
}

// ---------------------------------------------------------------- CFG queries (llvm/lib/Analysis/CFG.cpp)

// isCriticalEdge(TI, SuccNum, AllowIdenticalEdges)
is_critical_edge :: (t: Value_Id, succ: u32, allow_identical_edges := false) -> bool {
    if num_successors(t) == 1 return false;
    dest := get_successor(t, succ);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(dest, *preds);
    // pred_begin(Dest) is guaranteed to be non-empty (TI is one of them)
    if preds.count < 1 return false;
    first := preds[0];
    if !allow_identical_edges return preds.count > 1;
    for k: 1..preds.count-1 if preds[k] != first return true;
    return false;
}

// FindFunctionBackedges: (From, To) edges of a DFS, in discovery order.
Block_Edge :: struct { from: Value_Id; to: Value_Id; }
find_function_backedges :: (f: Value_Id, out: *[..] Block_Edge) {
    out.count = 0;
    bb := fn_entry(f);
    if block_num_successors(bb) == 0 return;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    in_stack: Table(Value_Id, bool); in_stack.allocator = temp;
    Frame :: struct { b: Value_Id; next: u32; }
    stack: [..] Frame; stack.allocator = temp;
    table_set(*visited, bb, true);
    array_add(*stack, .{bb, 0});
    table_set(*in_stack, bb, true);
    while stack.count > 0 {
        top := *stack[stack.count - 1];
        parent := top.b;
        t := block_terminator(parent);
        n := ifx t == NONE then cast(u32) 0 else num_successors(t);
        found_new := false;
        while top.next < n {
            s := get_successor(t, top.next);
            top.next += 1;
            if !table_contains(*visited, s) {
                table_set(*visited, s, true);
                found_new = true;
                array_add(*stack, .{s, 0});
                table_set(*in_stack, s, true);
                break;
            }
            if table_contains(*in_stack, s) array_add(out, .{parent, s});
        }
        if !found_new {
            table_remove(*in_stack, parent);
            stack.count -= 1;
        }
    }
}

// ---------------------------------------------------------------- poison-generating annotations (Instruction.cpp)

is_fp_math_operator :: (i: Value_Id) -> bool { return is_fp_math_inst(i); }

// Instruction::dropPoisonGeneratingFlags
drop_poison_generating_flags :: (i: Value_Id) {
    r := inst(i);
    if r.op == {
        case .ADD; #through;
        case .SUB; #through;
        case .MUL; #through;
        case .SHL; #through;
        case .TRUNC; r.flags &= ~cast(u32)(F_NUW | F_NSW);
        case .UDIV; #through;
        case .SDIV; #through;
        case .ASHR; #through;
        case .LSHR; #through;
        case .OR; #through;
        case .UITOFP; #through;
        case .ZEXT; #through;
        case .ICMP; r.flags &= ~cast(u32) F_EXACT;
        case .GEP; r.flags &= ~cast(u32)(F_INBOUNDS | F_NUSW | F_GEP_NUW);
        case .CALL;
            id := intrinsic_id_of_call(i);
            if id == "llvm.ctlz" || id == "llvm.cttz" || id == "llvm.abs" set_op(i, 1, const_int(ir.t_i1, 0));
    }
    if is_fp_math_operator(i) r.flags &= ~(cast(u32)(FMF_NNAN | FMF_NINF) << FMF_SHIFT);
}

// Instruction::dropPoisonGeneratingAttributes
drop_poison_generating_attributes :: (i: Value_Id) {
    r := inst(i);
    if r.op != .CALL && r.op != .INVOKE && r.op != .CALLBR return;
    if r.attrs == 0 return;
    l := ir.attr_lists[r.attrs];
    strip :: (s: u32) -> u32 {
        s = attr_set_remove(s, .Range);
        s = attr_set_remove(s, .Alignment);
        s = attr_set_remove(s, .NonNull);
        s = attr_set_remove(s, .NoFPClass);
        return s;
    }
    ps: [..] u32; ps.allocator = temp;
    for l.params array_add(*ps, strip(it));
    r.attrs = attr_list_get(l.fn, strip(l.ret), ps);
}

// Instruction::dropPoisonGeneratingMetadata
drop_poison_generating_metadata :: (i: Value_Id) {
    for name: string.["range", "nonnull", "align", "nofpclass"] {
        found, k := table_find(*ir.md_kind_map, name);
        if found set_metadata(i, k, NONE);
    }
}

drop_poison_generating_annotations :: (i: Value_Id) {
    drop_poison_generating_flags(i);
    drop_poison_generating_attributes(i);
    drop_poison_generating_metadata(i);
}
