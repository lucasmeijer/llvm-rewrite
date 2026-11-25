// IRNormalizerPass (`normalize`, `normalize<...>`): a port of llvm/lib/Transforms/Utils/IRNormalizer.cpp
// (complete), with parseIRNormalizerPassOptions (llvm/lib/Passes/PassBuilder.cpp).
//
// Address order: reorderInstructionOperandsByNames sorts (name, Value *) pairs, so two different operands of a
// commutative instruction with the same name / text are ordered by pointer: fails loudly.

irn_guess_address_order := false;   // -normalize-guess-address-order (ours)

Irn_Options :: struct {
    preserve_order := false;
    rename_all := true;
    fold_pre_outputs := true;
    reorder_operands := true;
}
IRN_MAGIC :: 0x6acaa36bef8325c5;

irn_hash_16_bytes :: (low: u64, high: u64) -> u64 {
    K_MUL :: 0x9ddfea08eb382d69;
    a := (low ^ high) * K_MUL;
    a ^= (a >> 47);
    b := (high ^ a) * K_MUL;
    b ^= (b >> 47);
    b *= K_MUL;
    return b;
}
// Instruction::getOpcode(): LLVM's numbering (Instruction.def), which the hashes see
irn_opcode :: (i: Value_Id) -> u64 {
    o := inst_op(i);
    // impl/jai splits `br` into BR / CONDBR (LLVM 23: UncondBr = 2, CondBr = 3); every other value is LLVM's
    return cast(u64) o;
}
// std::to_string(Hash).substr(0, 5)
irn_hash5 :: (h: u64) -> string {
    s := tdec(h);
    if s.count > 5 s = slice(s, 0, 5);
    return s;
}
// StringRef operator<
irn_str_less :: (a: string, b: string) -> bool {
    n := min(a.count, b.count);
    for i: 0..n - 1 if a[i] != b[i] return a[i] < b[i];
    return a.count < b.count;
}

Irn :: struct {
    f: Value_Id;
    o: Irn_Options;
    named: Table(Value_Id, bool);   // NamedInstructions
    outputs: [..] Value_Id;
    index: Table(Value_Id, s64);    // position of each instruction in the function (getOutputFootprint's Count)
}

irn_is_output :: (i: Value_Id) -> bool { return may_have_side_effects(i) || inst_op(i) == .RET; }
irn_has_only_immediate_operands :: (i: Value_Id) -> bool {
    for k: 0..cast(s64) nops(i) - 1 if is_inst(op(i, cast(u32) k)) return false;
    return true;
}
irn_is_initial :: (i: Value_Id) -> bool { return has_uses(i) && irn_has_only_immediate_operands(i); }

// sortCommutativeOperands on strings: llvm::sort of the first two
irn_sort_commutative_strings :: (i: Value_Id, ops: *[..] string) {
    if !(inst_is_commutative(i) && ops.count >= 2) return;
    if irn_str_less(ops.*[1], ops.*[0]) { x := ops.*[0]; ops.*[0] = ops.*[1]; ops.*[1] = x; }
}
irn_sort_commutative_ints :: (i: Value_Id, ops: *[..] u64) {
    if !(inst_is_commutative(i) && ops.count >= 2) return;
    if ops.*[1] < ops.*[0] { x := ops.*[0]; ops.*[0] = ops.*[1]; ops.*[1] = x; }
}

// printAsOperand(Stream, false). A metadata operand prints its slot number from a module slot tracker that numbers
// all metadata (impl/jai's printer has no such tracker here): fails loudly.
irn_operand_text :: (v: Value_Id) -> string {
    if vkind(v) == .MD_VALUE fatal("normalize: printAsOperand of a metadata operand (its module-wide slot number) is not supported");
    // printAsOperand builds a module slot tracker (unnamed globals print as @N)
    printer_begin_function(irn_current_fn);
    start := W.buf.count;
    write_operand(v, false);
    t := copy_string(slice_of_buf(start),, allocator = temp);
    W.buf.count = start;
    // a type printer without the module's type numbering prints an unnamed struct type as its address
    if contains(t, "\"type 0x") fatal("normalize: printAsOperand of a constant with an unnamed struct type prints the type's address");
    // impl/jai's printer numbers unnamed struct types (%0); LLVM's operand printer has no type numbering here and
    // prints the type's address instead. In a constant, '%' followed by a digit is such a type (or a numbered block).
    if !is_inst(v) && vkind(v) != .ARGUMENT && vkind(v) != .BLOCK {
        for k: 0..t.count - 2 if t[k] == #char "%" && t[k + 1] >= #char "0" && t[k + 1] <= #char "9"
            fatal("normalize: printAsOperand of a constant with an unnamed struct type prints the type's address");
    }
    return t;
}
irn_current_fn: Value_Id = NONE;

// getOutputFootprint
irn_output_footprint :: (s: *Irn, i: Value_Id, visited: *Table(Value_Id, bool), out: *[..] s64) {
    if table_contains(visited, i) return;
    table_set(visited, i, true);
    add :: (out: *[..] s64, x: s64) { for out.* if it == x return; array_add(out, x); }
    if irn_is_output(i) {
        _, idx := table_find(*s.index, i);
        add(out, idx);
        return;
    }
    u := ir.v_first_use[i];
    while u != NONE {
        user := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(user) continue;
        sub: [..] s64; sub.allocator = temp;
        irn_output_footprint(s, user, visited, *sub);
        for sub add(out, it);
    }
}

irn_callee_name :: (i: Value_Id) -> string {
    if inst_op(i) != .CALL return "";
    f := call_called_function(i);
    if f == NONE return "";
    return vname(f);
}

irn_join :: (head: string, ops: [] string) -> string {
    sb: String_Builder; sb.allocator = temp;
    append(*sb, head);
    append(*sb, "(");
    for ops { if it_index append(*sb, ", "); append(*sb, it); }
    append(*sb, ")");
    return builder_to_string(*sb,, allocator = temp);
}

// nameAsInitialInstruction
irn_name_as_initial :: (s: *Irn, i: Value_Id) {
    if vtype(i) == ir.t_void return;
    if !(vname(i).count == 0 || s.o.rename_all) return;
    ops: [..] string; ops.allocator = temp;
    for k: 0..cast(s64) nops(i) - 1 {
        x := op(i, cast(u32) k);
        if vkind(x) != .FUNCTION array_add(*ops, irn_operand_text(x));
    }
    irn_sort_commutative_strings(i, *ops);
    h: u64 = IRN_MAGIC;
    h = irn_hash_16_bytes(h, irn_opcode(i));
    visited: Table(Value_Id, bool); visited.allocator = temp;
    fp: [..] s64; fp.allocator = temp;
    irn_output_footprint(s, i, *visited, *fp);
    for fp h = irn_hash_16_bytes(h, cast,no_check(u64) it);
    name := tconcat("vl", irn_hash5(h), irn_callee_name(i));
    set_name(i, irn_join(name, ops));
}

// nameAsRegularInstruction
irn_name_as_regular :: (s: *Irn, i: Value_Id) {
    ops: [..] string; ops.allocator = temp;
    for k: 0..cast(s64) nops(i) - 1 {
        x := op(i, cast(u32) k);
        if is_inst(x) {
            irn_name_instruction(s, x);
            array_add(*ops, vname(x));
        } else if vkind(x) != .FUNCTION {
            array_add(*ops, irn_operand_text(x));
        }
    }
    irn_sort_commutative_strings(i, *ops);
    h: u64 = IRN_MAGIC;
    h = irn_hash_16_bytes(h, irn_opcode(i));
    codes: [..] u64; codes.allocator = temp;
    for k: 0..cast(s64) nops(i) - 1 { x := op(i, cast(u32) k); if is_inst(x) array_add(*codes, irn_opcode(x)); }
    irn_sort_commutative_ints(i, *codes);
    for codes h = irn_hash_16_bytes(h, it);
    name := tconcat("op", irn_hash5(h), irn_callee_name(i));
    if (vname(i).count == 0 || s.o.rename_all) && vtype(i) != ir.t_void set_name(i, irn_join(name, ops));
}

// nameInstruction
irn_name_instruction :: (s: *Irn, i: Value_Id) {
    if table_contains(*s.named, i) return;
    table_set(*s.named, i, true);
    if irn_is_initial(i) irn_name_as_initial(s, i);
    else irn_name_as_regular(s, i);
}

// foldInstructionName
irn_fold_instruction_name :: (s: *Irn, i: Value_Id) {
    if !s.o.fold_pre_outputs {
        u := ir.v_first_use[i];
        while u != NONE {
            user := ir.u_user[u];
            if is_inst(user) && irn_is_output(user) return;
            u = ir.u_next[u];
        }
    }
    if irn_is_output(i) || !begins_with(vname(i), "op") return;
    ops: [..] string; ops.allocator = temp;
    pre7 :: (n: string) -> string { return ifx n.count > 7 then slice(n, 0, 7) else n; }
    for k: 0..cast(s64) nops(i) - 1 {
        x := op(i, cast(u32) k);
        if !is_inst(x) continue;
        n := vname(x);
        normal := begins_with(n, "op") || begins_with(n, "vl");
        array_add(*ops, ifx normal then pre7(n) else n);
    }
    irn_sort_commutative_strings(i, *ops);
    set_name(i, irn_join(pre7(vname(i)), ops));
}

// BasicBlock::getFirstNonPHIOrDbgOrAlloca (NONE = end)
irn_first_non_phi_or_dbg_or_alloca :: (bb: Value_Id) -> Value_Id {
    p := block_first_non_phi(bb);
    if p == NONE return NONE;
    if is_eh_pad(p) p = inst_next(p);
    if bb == fn_entry(block_fn(bb)) {
        while p != NONE && (inst_op(p) == .ALLOCA || call_iid(p) == IID_PSEUDOPROBE) {
            if inst_op(p) == .ALLOCA && !is_static_alloca(p) break;
            p = inst_next(p);
        }
    }
    return p;
}

// reorderDefinition
irn_reorder_definition :: (def: Value_Id, topo: *[..] Value_Id, visited: *Table(Value_Id, bool)) {
    if table_contains(visited, def) return;
    table_set(visited, def, true);
    bb := inst_block(def);
    first := irn_first_non_phi_or_dbg_or_alloca(bb);
    if first == NONE return;
    if comes_before(def, first) return;
    for k: 0..cast(s64) nops(def) - 1 {
        x := op(def, cast(u32) k);
        if is_inst(x) {
            if inst_block(x) != bb continue;
            irn_reorder_definition(x, topo, visited);
        }
    }
    if is_terminator(inst_op(def)) return;
    if inst_op(def) == .CALL {
        if call_is_must_tail(def) return;
        id := call_iid(def);
        if id == IID_EXPERIMENTAL_DEOPTIMIZE || id == IID_EXPERIMENTAL_CONVERGENCE_ENTRY || id == IID_EXPERIMENTAL_CONVERGENCE_LOOP return;
    }
    if inst_op(def) == .BITCAST {
        c := op(def, 0);
        if is_inst(c) && inst_op(c) == .CALL && call_is_must_tail(c) return;
    }
    array_add(topo, def);
}

// reorderInstructions
irn_reorder_instructions :: (s: *Irn) {
    for bb: fn_blocks(s.f) {
        topo: [..] Value_Id; topo.allocator = temp;
        visited: Table(Value_Id, bool); visited.allocator = temp;
        for i: block_insts(bb) {
            if !(irn_is_output(i) || is_terminator(inst_op(i))) continue;
            irn_reorder_definition(i, *topo, *visited);
        }
        for i: block_insts(bb) {
            if table_contains(*visited, i) continue;
            irn_reorder_definition(i, *topo, *visited);
        }
        while topo.count {
            x := pop(*topo);
            first := irn_first_non_phi_or_dbg_or_alloca(bb);
            if first != NONE && inst_op(first) == .CALL {
                id := call_iid(first);
                if id == IID_EXPERIMENTAL_CONVERGENCE_ENTRY || id == IID_EXPERIMENTAL_CONVERGENCE_LOOP first = inst_next(first);
            }
            if first == x continue;   // moveBefore itself: no change
            inst_move_before_dbg(x, first);
        }
    }
}

// reorderInstructionOperandsByNames
irn_reorder_operands_by_names :: (i: Value_Id) {
    Op :: struct { s: string; v: Value_Id; }
    ops: [..] Op; ops.allocator = temp;
    n := nops(i);
    comm := inst_is_commutative(i);
    for k: 0..cast(s64) n - 1 {
        x := op(i, cast(u32) k);
        if x == NONE continue;
        if is_inst(x) array_add(*ops, .{vname(x), x});
        else if comm && k < 2 array_add(*ops, .{irn_operand_text(x), x});   // the text only matters for the sort
        else array_add(*ops, .{"", x});
    }
    if comm && ops.count >= 2 {
        a := ops[0]; b := ops[1];
        if a.s == b.s && a.v != b.v {
            if !irn_guess_address_order
                fatal("%", tprint("normalize: two different operands with the same name (\"%\") are ordered by pointer address (std::pair<std::string, Value *> sort) in % (use -normalize-guess-address-order to guess)", a.s, inst_to_string(i)));
            // guess: values are allocated in creation order
            if b.v < a.v { ops[0] = b; ops[1] = a; }
        }
        if irn_str_less(b.s, a.s) { ops[0] = b; ops[1] = a; }
    }
    for k: 0..cast(s64) n - 1 set_op(i, cast(u32) k, ops[k].v);   // Op.set: every use moves to the front
}

// reorderPHIIncomingValues
irn_reorder_phi_incoming_values :: (phi: Value_Id) {
    Pv :: struct { v: Value_Id; b: Value_Id; }
    vals: [..] Pv; vals.allocator = temp;
    n := nops(phi);
    for k: 0..cast(s64) n - 1 {
        b := phi_block(phi, cast(u32) k);
        array_add(*vals, .{phi_value(phi, cast(u32) phi_block_index(phi, b)), b});
    }
    // llvm::sort by block name: equal names are the same block (same value), so the unstable sort is harmless
    for i: 1..vals.count - 1 {
        x := vals[i];
        j := i - 1;
        while j >= 0 && irn_str_less(vname(x.b), vname(vals[j].b)) { vals[j + 1] = vals[j]; j -= 1; }
        vals[j + 1] = x;
    }
    for vals {
        phi_set_block(phi, cast(u32) it_index, it.b);
        phi_set_value(phi, cast(u32) it_index, it.v);
    }
}

irn_parse_options :: (name: string) -> Irn_Options {
    o: Irn_Options;
    if name == "normalize" return o;
    params := slice(name, "normalize<".count, name.count - "normalize<".count - 1);
    while params.count {
        p := params;
        k := find_index_from_left(params, #char ";");
        if k >= 0 { p = slice(params, 0, k); params = slice(params, k + 1, params.count - k - 1); } else params = "";
        enable := true;
        if begins_with(p, "no-") { enable = false; p = slice(p, 3, p.count - 3); }
        if p == "preserve-order" o.preserve_order = enable;
        else if p == "rename-all" o.rename_all = enable;
        else if p == "fold-all" o.fold_pre_outputs = enable;
        else if p == "reorder-operands" o.reorder_operands = enable;
        else fatal(tprint("invalid normalize pass parameter '%'", p));
    }
    return o;
}

normalize_run :: (f: Value_Id, node: *Pass_Node) -> Preserved {
    s: Irn;
    s.f = f;
    irn_current_fn = f;
    s.o = irn_parse_options(node.name);
    s.named.allocator = temp; s.outputs.allocator = temp; s.index.allocator = temp;
    printer_note_ir_changed();
    // nameFunctionArguments
    g := glob(f);
    counter := 0;
    if g.nargs > 0 for k: 0..g.nargs - 1 {
        a := fn_arg(f, k);
        if s.o.rename_all || vname(a).count == 0 { set_name(a, tconcat("a", tdec(cast(u64) counter))); counter += 1; }
    }
    // nameBasicBlocks
    for bb: fn_blocks(f) {
        h: u64 = IRN_MAGIC;
        for i: block_insts(bb) if irn_is_output(i) h = irn_hash_16_bytes(h, irn_opcode(i));
        if s.o.rename_all || vname(bb).count == 0 set_name(bb, tconcat("bb", irn_hash5(h)));
    }
    for i: fn_insts(f) if irn_is_output(i) array_add(*s.outputs, i);
    if !s.o.preserve_order irn_reorder_instructions(*s);
    n := 0;
    for bb: fn_blocks(f) for i: block_insts(bb) { table_set(*s.index, i, n); n += 1; }
    for s.outputs irn_name_instruction(*s, it);
    for i: fn_insts(f) {
        if !s.o.preserve_order {
            if s.o.reorder_operands irn_reorder_operands_by_names(i);
            if inst_op(i) == .PHI irn_reorder_phi_incoming_values(i);
        }
        irn_fold_instruction_name(*s, i);
    }
    printer_note_ir_changed();
    return preserved_cfg();
}
