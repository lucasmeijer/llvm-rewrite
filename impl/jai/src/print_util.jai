// Printing single values for analysis printers and diagnostics: Value::printAsOperand(OS, /*PrintType=*/false) and
// `OS << *I` (Instruction::print), llvm/lib/IR/AsmWriter.cpp. Both build a SlotTracker for the value's function, so
// numbering is the same as in the module printer.
//
// The AsmWriter state (`W` in printer.jai) is module-wide; printer_begin_function(f) (re)initialises it when the
// IR may have changed since the last use (passes call printer_note_ir_changed through the pass manager).

print_state: struct {
    module_ready: bool;
    all_md: bool;
    fn: Value_Id = NONE;
    dirty: bool = true;
    module_md_count: s64;   // W.md_order / W.as_order after process_module: the per-function slots come after
    module_as_count: s64;
};

printer_note_ir_changed :: () { print_state.dirty = true; verifier_analysis.valid = false; }

printer_reset :: () {
    W = .{};
    print_state.module_ready = false;
    print_state.fn = NONE;
}

// Each LLVM print call builds a fresh SlotTracker, so metadata numbering restarts per printed function: we reset the
// AsmWriter state when the function changes (or the IR changed). `all_md` = ShouldInitializeAllMetadata (an
// instruction that references an MDNode through an intrinsic operand): every function's metadata is numbered first.
// Switching to another function of an unchanged module keeps the module part (TypeFinder, module slots, module
// metadata and attribute groups) and drops only the previous function's slots, which gives the same numbering as a
// fresh SlotTracker without redoing the module-wide work per printed function.
printer_begin_function :: (f: Value_Id, all_md := false) {
    if print_state.dirty || all_md != print_state.all_md || (print_state.fn != f && all_md) {
        printer_reset();
        print_state.dirty = false;
        print_state.all_md = all_md;
    }
    if !print_state.module_ready {
        type_printing_init();
        process_module();
        if all_md for g: ir.m_functions process_function(g);
        print_state.module_ready = true;
        print_state.module_md_count = W.md_order.count;
        print_state.module_as_count = W.as_order.count;
    }
    if print_state.fn != f {
        for k: print_state.module_md_count..W.md_order.count-1 table_remove(*W.md_slot, W.md_order[k]);
        W.md_order.count = print_state.module_md_count;
        for k: print_state.module_as_count..W.as_order.count-1 table_remove(*W.as_slot, W.as_order[k]);
        W.as_order.count = print_state.module_as_count;
        process_function(f);
        print_state.fn = f;
    }
    current_function = f;
}

// Value::printAsOperand(O, false): the slot tracker is built for the value's function.
value_as_operand :: (v: Value_Id) -> string {
    f := value_function(v);
    if f != NONE printer_begin_function(f);
    start := W.buf.count;
    write_operand(v, false);
    s := copy_string(slice_of_buf(start),, allocator = temp);
    W.buf.count = start;
    return s;
}
value_as_operand_typed :: (v: Value_Id) -> string {
    f := value_function(v);
    if f != NONE printer_begin_function(f);
    start := W.buf.count;
    write_operand(v, true);
    s := copy_string(slice_of_buf(start),, allocator = temp);
    W.buf.count = start;
    return s;
}

// OS << *I
inst_to_string :: (i: Value_Id) -> string {
    printer_begin_function(value_function(i), is_referencing_md_node(i));
    start := W.buf.count;
    print_instruction(i);
    s := copy_string(slice_of_buf(start),, allocator = temp);
    W.buf.count = start;
    return s;
}

slice_of_buf :: (start: s64) -> string {
    s: string;
    s.data = W.buf.data + start;
    s.count = W.buf.count - start;
    return s;
}

// The module printer for -S output: always from a fresh AsmWriter state.
print_module_fresh :: () -> string {
    printer_reset();
    print_state.dirty = true;
    return print_module();
}

// isReferencingMDNode (AsmWriter.cpp): a call to an intrinsic with an MDNode operand
is_referencing_md_node :: (i: Value_Id) -> bool {
    if inst_op(i) != .CALL return false;
    f := call_called_function(i);
    if f == NONE || !glob(f).intrinsic return false;
    n := nops(i);
    for k: 0..n-1 {
        o := op(i, k);
        if o == NONE || vkind(o) != .MD_VALUE continue;
        m := ir.v_aux[o];
        if m != NONE && (ir.mds[m].kind == .TUPLE || ir.mds[m].kind == .DI) return true;
    }
    return false;
}
