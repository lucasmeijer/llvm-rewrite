// salvageDebugInfo and replaceAllDbgUsesWith with the DIExpression / DbgVariableRecord operations they need.
// Ported from llvm/lib/Transforms/Utils/Local.cpp (salvageDebugInfo, salvageDbgAssignAddress,
// salvageDebugInfoForDbgValues, getSalvageOpsForGEP/BinOp/IcmpOp, getDwarfOpForBinOp/IcmpPred,
// handleSSAValueOperands, salvageDebugInfoImpl, rewriteDebugUsers, isBitCastSemanticsPreserving,
// replaceAllDbgUsesWith), llvm/lib/IR/DebugInfoMetadata.cpp (DIExpression::appendOffset, appendOpsToArg,
// prependOpcodes, append, appendToStack, getExtOps, appendExt, getNumLocationOperands),
// llvm/lib/IR/DIExpressionOptimizer.cpp (foldConstantMath), llvm/lib/IR/Operator.cpp (GEPOperator::collectOffset)
// and llvm/lib/IR/DebugProgramInstruction.cpp (DbgVariableRecord::location_ops, replaceVariableLocationOp,
// addVariableLocationOps, setKillLocation, setKillAddress).

DW_OP_CONSTU :: 0x10; DW_OP_CONSTS :: 0x11; DW_OP_PLUS_UCONST :: 0x23; DW_OP_LIT0 :: 0x30; DW_OP_LIT31 :: 0x4f;
DW_OP_PLUS :: 0x22; DW_OP_MINUS :: 0x1c; DW_OP_MUL :: 0x1e; DW_OP_DIV :: 0x1b; DW_OP_MOD :: 0x1d; DW_OP_OR :: 0x21;
DW_OP_AND :: 0x1a; DW_OP_XOR :: 0x27; DW_OP_SHL :: 0x24; DW_OP_SHR :: 0x25; DW_OP_SHRA :: 0x26;
DW_OP_EQ :: 0x29; DW_OP_NE :: 0x2e; DW_OP_GT :: 0x2b; DW_OP_GE :: 0x2a; DW_OP_LT :: 0x2d; DW_OP_LE :: 0x2c;
DW_ATE_SIGNED_ :: 0x05; DW_ATE_UNSIGNED_ :: 0x07;

diexpr_get :: (elts: [] u64) -> Md_Id { return di_get(.EXPRESSION, false, .[], elts); }

// DIExpression::appendOffset
diexpr_append_offset :: (ops: *[..] u64, offset: s64) {
    if offset > 0 { array_add(ops, DW_OP_PLUS_UCONST); array_add(ops, cast(u64) offset); }
    else if offset < 0 {
        array_add(ops, DW_OP_CONSTU);
        abs_minus_one := cast,no_check(u64) (-(offset + 1));
        array_add(ops, abs_minus_one + 1);
        array_add(ops, DW_OP_MINUS);
    }
}

// expr_ops contains DW_OP_LLVM_arg
diexpr_has_arg_op :: (e: [] u64) -> bool {
    i := 0;
    while i < e.count { if e[i] == DW_OP_LLVM_ARG return true; i += expr_op_size(e[i]); }
    return false;
}

// DIExpression::getNumLocationOperands
diexpr_num_location_operands :: (m: Md_Id) -> u64 {
    e := diexpr_elts(m);
    r: u64 = 0;
    i := 0;
    while i < e.count { if e[i] == DW_OP_LLVM_ARG r = max(r, e[i + 1] + 1); i += expr_op_size(e[i]); }
    return r;
}

// DIExpression::prependOpcodes (ops is extended in place, as in LLVM)
diexpr_prepend_opcodes :: (expr: Md_Id, ops: *[..] u64, stack_value_in: bool, entry_value := false) -> Md_Id {
    stack_value := stack_value_in;
    if entry_value { array_add(ops, DW_OP_LLVM_ENTRY_VALUE); array_add(ops, 1); }
    if ops.count == 0 stack_value = false;
    e := diexpr_elts(expr);
    i := 0;
    while i < e.count {
        o := e[i];
        if stack_value {
            if o == DW_OP_STACK_VALUE stack_value = false;
            else if o == DW_OP_LLVM_FRAGMENT { array_add(ops, DW_OP_STACK_VALUE); stack_value = false; }
        }
        sz := expr_op_size(o);
        for k: 0..sz-1 array_add(ops, e[i + k]);
        i += sz;
    }
    if stack_value array_add(ops, DW_OP_STACK_VALUE);
    return diexpr_get(ops.*);
}

// DIExpression::appendOpsToArg
diexpr_append_ops_to_arg :: (expr: Md_Id, ops: [] u64, arg_no: u64, stack_value_in: bool) -> Md_Id {
    e := diexpr_elts(expr);
    if !diexpr_has_arg_op(e) {
        new_ops: [..] u64; new_ops.allocator = temp;
        for ops array_add(*new_ops, it);
        return diexpr_prepend_opcodes(expr, *new_ops, stack_value_in);
    }
    stack_value := stack_value_in;
    new_ops: [..] u64; new_ops.allocator = temp;
    i := 0;
    while i < e.count {
        o := e[i];
        if stack_value {
            if o == DW_OP_STACK_VALUE stack_value = false;
            else if o == DW_OP_LLVM_FRAGMENT { array_add(*new_ops, DW_OP_STACK_VALUE); stack_value = false; }
        }
        sz := expr_op_size(o);
        for k: 0..sz-1 array_add(*new_ops, e[i + k]);
        if o == DW_OP_LLVM_ARG && e[i + 1] == arg_no for ops array_add(*new_ops, it);
        i += sz;
    }
    if stack_value array_add(*new_ops, DW_OP_STACK_VALUE);
    return diexpr_get(new_ops);
}

// DIExpression::append
diexpr_append :: (expr: Md_Id, ops_in: [] u64) -> Md_Id {
    ops := ops_in;
    e := diexpr_elts(expr);
    new_ops: [..] u64; new_ops.allocator = temp;
    i := 0;
    while i < e.count {
        o := e[i];
        if o == DW_OP_STACK_VALUE || o == DW_OP_LLVM_FRAGMENT {
            for ops array_add(*new_ops, it);
            ops = .[];
        }
        sz := expr_op_size(o);
        for k: 0..sz-1 array_add(*new_ops, e[i + k]);
        i += sz;
    }
    for ops array_add(*new_ops, it);
    return diexpr_fold_constant_math(diexpr_get(new_ops));
}

// DIExpression::appendToStack
diexpr_append_to_stack :: (expr: Md_Id, ops: [] u64) -> Md_Id {
    e := diexpr_elts(expr);
    has_frag := diexpr_fragment(expr);
    drop := ifx has_frag then 3 else 0;
    before := e.count - drop;
    needs_deref := e.count > drop && e[before - 1] != DW_OP_STACK_VALUE;
    needs_stack_value := needs_deref || before == 0;
    new_ops: [..] u64; new_ops.allocator = temp;
    if needs_deref array_add(*new_ops, DW_OP_DEREF_);
    for ops array_add(*new_ops, it);
    if needs_stack_value array_add(*new_ops, DW_OP_STACK_VALUE);
    return diexpr_append(expr, new_ops);
}

// DIExpression::getExtOps
diexpr_ext_ops :: (from: u64, to: u64, signed: bool) -> [6] u64 {
    tk: u64 = ifx signed then cast(u64) DW_ATE_SIGNED_ else DW_ATE_UNSIGNED_;
    r: [6] u64;
    r[0] = DW_OP_LLVM_CONVERT; r[1] = from; r[2] = tk; r[3] = DW_OP_LLVM_CONVERT; r[4] = to; r[5] = tk;
    return r;
}
// DIExpression::appendExt
diexpr_append_ext :: (expr: Md_Id, from: u64, to: u64, signed: bool) -> Md_Id {
    ops := diexpr_ext_ops(from, to, signed);
    return diexpr_append_to_stack(expr, ops);
}

// ---------------------------------------------------------------- DIExpression::foldConstantMath

dfold_is_neutral :: (op: u64, v: u64) -> bool {
    if op == DW_OP_PLUS || op == DW_OP_MINUS || op == DW_OP_SHL || op == DW_OP_SHR return v == 0;
    if op == DW_OP_MUL || op == DW_OP_DIV return v == 1;
    return false;
}
dfold_operation :: (c1: u64, c2: u64, op: u64) -> (bool, u64) {
    if op == {
      case DW_OP_PLUS;
        r := c1 + c2;
        if r < c1 return false, 0;
        return true, r;
      case DW_OP_MINUS;
        if c1 < c2 return false, 0;
        return true, c1 - c2;
      case DW_OP_SHL;
        if c2 >= 64 || cast(u64) dfold_clz(c1) < c2 return false, 0;
        return true, c1 << c2;
      case DW_OP_SHR;
        if c2 >= 64 || cast(u64) dfold_ctz(c1) < c2 return false, 0;
        return true, c1 >> c2;
      case DW_OP_MUL;
        if c1 != 0 && c2 > 0xFFFF_FFFF_FFFF_FFFF / c1 return false, 0;
        return true, c1 * c2;
      case DW_OP_DIV;
        if c2 return true, c1 / c2;
        return false, 0;
    }
    return false, 0;
}
dfold_clz :: (x: u64) -> s64 { if x == 0 return 64; n := 0; v := x; while !(v & 0x8000_0000_0000_0000) { v <<= 1; n += 1; } return n; }
dfold_ctz :: (x: u64) -> s64 { if x == 0 return 64; n := 0; v := x; while !(v & 1) { v >>= 1; n += 1; } return n; }
dfold_foldable_commutative :: (a: u64, b: u64) -> bool { return a == b && (a == DW_OP_PLUS || a == DW_OP_MUL); }

// position of the k-th operation after `loc` (DIExpressionCursor::peekNextN), -1 if none
dfold_peek :: (ops: [] u64, loc: s64, k: s64) -> s64 {
    p := loc;
    for 1..k {
        if p >= ops.count return -1;
        p += expr_op_size(ops[p]);
    }
    if p >= ops.count return -1;
    return p;
}
dfold_erase :: (ops: *[..] u64, from: s64, to: s64) {
    n := to - from;
    for i: from..ops.count - n - 1 ops.*[i] = ops.*[i + n];
    ops.count -= n;
}

diexpr_fold_constant_math :: (expr: Md_Id) -> Md_Id {
    e := diexpr_elts(expr);
    // canonicalizeDwarfOperations
    res: [..] u64; res.allocator = temp;
    loc := 0;
    while loc < e.count {
        o := e[loc];
        if o >= DW_OP_LIT0 && o <= DW_OP_LIT31 { array_add(*res, DW_OP_CONSTU); array_add(*res, o - DW_OP_LIT0); loc += 1; continue; }
        if o == DW_OP_PLUS_UCONST {
            array_add(*res, DW_OP_CONSTU); array_add(*res, e[loc + 1]); array_add(*res, DW_OP_PLUS);
            loc += 2;
            continue;
        }
        sz := expr_op_size(o);
        for k: 0..sz-1 if loc + k < e.count array_add(*res, e[loc + k]);
        loc += sz;
    }
    is_const :: (ops: [] u64, p: s64) -> bool { return ops[p] == DW_OP_CONSTU; }
    loc = 0;
    while loc < res.count {
        p0 := loc;
        if !is_const(res, p0) { loc += expr_op_size(res[p0]); continue; }
        c1 := res[p0 + 1];
        p1 := dfold_peek(res, loc, 1);
        if p1 < 0 break;
        // tryFoldNoOpMath
        if dfold_is_neutral(res[p1], c1) { dfold_erase(*res, loc, loc + 3); loc = 0; continue; }
        p2 := dfold_peek(res, loc, 2);
        if p2 < 0 { loc += expr_op_size(res[p0]); continue; }
        // tryFoldConstants
        if is_const(res, p1) {
            ok, r := dfold_operation(c1, res[p1 + 1], res[p2]);
            if !ok { loc += expr_op_size(res[p0]); continue; }
            dfold_erase(*res, loc + 2, loc + 5);
            res[loc] = DW_OP_CONSTU; res[loc + 1] = r;
            loc = 0;
            continue;
        }
        p3 := dfold_peek(res, loc, 3);
        if p3 < 0 { loc += expr_op_size(res[p0]); continue; }
        // tryFoldCommutativeMath
        if is_const(res, p2) && dfold_foldable_commutative(res[p1], res[p3]) {
            ok, r := dfold_operation(c1, res[p2 + 1], res[p1]);
            if !ok { loc += expr_op_size(res[p0]); continue; }
            dfold_erase(*res, loc + 3, loc + 6);
            res[loc] = DW_OP_CONSTU; res[loc + 1] = r;
            loc = 0;
            continue;
        }
        p4 := dfold_peek(res, loc, 4);
        if p4 < 0 { loc += expr_op_size(res[p0]); continue; }
        p5 := dfold_peek(res, loc, 5);
        if p5 < 0 { loc += expr_op_size(res[p0]); continue; }
        // tryFoldCommutativeMathWithArgInBetween
        if is_const(res, p4) && res[p2] == DW_OP_LLVM_ARG && dfold_foldable_commutative(res[p1], res[p3]) &&
           dfold_foldable_commutative(res[p3], res[p5]) {
            ok, r := dfold_operation(c1, res[p4 + 1], res[p1]);
            if !ok { loc += expr_op_size(res[p0]); continue; }
            dfold_erase(*res, loc + 6, loc + 9);
            res[loc] = DW_OP_CONSTU; res[loc + 1] = r;
            loc = 0;
            continue;
        }
        loc += expr_op_size(res[p0]);
    }
    // optimizeDwarfOperations
    out: [..] u64; out.allocator = temp;
    loc = 0;
    while loc < res.count {
        o := res[loc];
        if o == DW_OP_CONSTU && res[loc + 1] == 0 { array_add(*out, DW_OP_LIT0); loc += 2; continue; }
        p1 := dfold_peek(res, loc, 1);
        if p1 < 0 {
            sz := expr_op_size(o);
            for k: 0..sz-1 if loc + k < res.count array_add(*out, res[loc + k]);
            break;
        }
        if o == DW_OP_CONSTU && res[p1] == DW_OP_PLUS {
            array_add(*out, DW_OP_PLUS_UCONST); array_add(*out, res[loc + 1]);
            loc = p1 + 1;
            continue;
        }
        sz := expr_op_size(o);
        for k: 0..sz-1 array_add(*out, res[loc + k]);
        loc += sz;
    }
    return diexpr_get(out);
}

// ---------------------------------------------------------------- DbgVariableRecord location operations

// dbgr_location_ops (DbgVariableRecord::location_ops) is in pass_loop_rotate.jai

// DIArgList::get: a new list is tracked by its arguments now (arglist_stamp orders findDbgUsers' arg-list users)
arglist_stamps: Table(Md_Id, u64);
di_arg_list_get :: (mds: [] Md_Id) -> Md_Id {
    n := ir.mds.count;
    m := di_get(.ARG_LIST, false, mds, .[]);
    if ir.mds.count != n { table_set(*arglist_stamps, m, dbg_stamp_next); dbg_stamp_next += 1; }
    return m;
}
arglist_stamp :: (m: Md_Id) -> u64 {
    found, s := table_find(*arglist_stamps, m);
    if found return s;
    return cast(u64) m;   // parsed lists: creation order
}
arglist_restamp :: (m: Md_Id) { table_set(*arglist_stamps, m, dbg_stamp_next); dbg_stamp_next += 1; }

// setRawLocation: the record is re-tracked (MetadataTracking gives it a new use-map index)
dbgr_set_raw_location :: (r: u32, loc: Md_Id) {
    dbgr(r).loc = loc;
    if dbgr(r).owner != NONE dbgr_restamp(r);
    if dbg_index.fn != NONE dbgr_index_record(r);
}

// DbgVariableRecord::replaceVariableLocationOp(OldValue, NewValue, AllowEmpty)
dbgr_replace_variable_location_op :: (r: u32, old: Value_Id, new: Value_Id, allow_empty := false) {
    vals: [..] Value_Id; vals.allocator = temp;
    dbgr_location_ops(r, *vals);
    found := false;
    for vals if it == old { found = true; break; }
    if !found {
        if allow_empty return;
        fatal("internal: replaceVariableLocationOp: the value is not a location operand");
    }
    loc := dbgr(r).loc;
    nm := md_value(new);
    if !is_di(loc, .ARG_LIST) { dbgr_set_raw_location(r, nm); return; }
    mds: [..] Md_Id; mds.allocator = temp;
    for vals array_add(*mds, ifx it == old then nm else md_op(loc, cast(u32) it_index));
    dbgr_set_raw_location(r, di_arg_list_get(mds));
}

// DbgVariableRecord::addVariableLocationOps
dbgr_add_variable_location_ops :: (r: u32, new_values: [] Value_Id, new_expr: Md_Id) {
    dbgr(r).expr = new_expr;
    vals: [..] Value_Id; vals.allocator = temp;
    dbgr_location_ops(r, *vals);
    mds: [..] Md_Id; mds.allocator = temp;
    for vals array_add(*mds, md_value(it));
    for new_values array_add(*mds, md_value(it));
    dbgr_set_raw_location(r, di_arg_list_get(mds));
}

// DbgVariableRecord::setKillLocation
dbgr_set_kill_location :: (r: u32) {
    vals: [..] Value_Id; vals.allocator = temp;
    dbgr_location_ops(r, *vals);
    removed: [..] Value_Id; removed.allocator = temp;
    for vals {
        dup := false;
        for x: removed if x == it { dup = true; break; }
        if dup continue;
        array_add(*removed, it);
        dbgr_replace_variable_location_op(r, it, const_poison(vtype(it)));
    }
}

// ---------------------------------------------------------------- salvageDebugInfo

// GEPOperator::collectOffset (offsets modulo 2^bits)
gep_collect_offset :: (g: Value_Id, bits: u32, vars: *[..] Value_Id, var_scale: *[..] u64) -> (bool, u64) {
    mask: u64 = ifx bits >= 64 then 0xFFFF_FFFF_FFFF_FFFF else ((cast(u64) 1) << bits) - 1;
    off: u64 = 0;
    cur := opr_gep_source_type(g);
    n := nops(g);
    for k: 1..cast(s64) n - 1 {
        index := op(g, cast(u32) k);
        is_struct := k > 1 && type_kind(cur) == .STRUCT;
        container := cur;
        indexed := gep_indexed_type(cur, k, index);
        defer cur = indexed;
        scalable := type_is_scalable(indexed);
        if is_scalar_const_int(index) {
            ci := const_ap(index);
            if ap_is_zero(ci) continue;
            if scalable return false, 0;
            if is_struct {
                off = (off + dl_struct_offset(container, cast(u32) ap_zext_value(ci))) & mask;
                continue;
            }
            idx := ap_zext_value(ap_sext_or_trunc(ci, bits));
            off = (off + idx * (gep_seq_stride(container, k, indexed) & mask)) & mask;
            continue;
        }
        if is_struct || scalable return false, 0;
        size := gep_seq_stride(container, k, indexed) & mask;
        if size != 0 {
            slot := -1;
            for vars.* if it == index { slot = it_index; break; }
            if slot < 0 { array_add(vars, index); array_add(var_scale, 0); slot = vars.count - 1; }
            var_scale.*[slot] = (var_scale.*[slot] + size) & mask;
        }
    }
    return true, off;
}

sext_bits :: (x: u64, bits: u32) -> s64 {
    if bits >= 64 return cast,no_check(s64) x;
    sh := 64 - bits;
    return (cast,no_check(s64) (x << sh)) >> sh;
}

// getSalvageOpsForGEP
salvage_ops_for_gep :: (g: Value_Id, cur_loc_ops_in: u64, ops: *[..] u64, additional: *[..] Value_Id) -> Value_Id {
    cur_loc_ops := cur_loc_ops_in;
    bits := dl_index_type_size_bits(vtype(op(g, 0)));
    vars: [..] Value_Id; vars.allocator = temp;
    scales: [..] u64; scales.allocator = temp;
    ok, coff := gep_collect_offset(g, bits, *vars, *scales);
    if !ok return NONE;
    if vars.count && !cur_loc_ops {
        // Opcodes.insert(begin, {DW_OP_LLVM_arg, 0})
        array_insert_at(ops, DW_OP_LLVM_ARG, 0); array_insert_at(ops, 0, 1);
        cur_loc_ops = 1;
    }
    for vars {
        array_add(additional, it);
        array_add(ops, DW_OP_LLVM_ARG); array_add(ops, cur_loc_ops); cur_loc_ops += 1;
        array_add(ops, DW_OP_CONSTU); array_add(ops, scales[it_index]); array_add(ops, DW_OP_MUL); array_add(ops, DW_OP_PLUS);
    }
    diexpr_append_offset(ops, sext_bits(coff, bits));
    return op(g, 0);
}

dwarf_op_for_binop :: (o: Opcode) -> u64 {
    if o == {
        case .ADD; return DW_OP_PLUS; case .SUB; return DW_OP_MINUS; case .MUL; return DW_OP_MUL;
        case .SDIV; return DW_OP_DIV; case .SREM; return DW_OP_MOD; case .OR; return DW_OP_OR;
        case .AND; return DW_OP_AND; case .XOR; return DW_OP_XOR; case .SHL; return DW_OP_SHL;
        case .LSHR; return DW_OP_SHR; case .ASHR; return DW_OP_SHRA;
    }
    return 0;
}

// handleSSAValueOperands
salvage_handle_ssa_value_operands :: (cur_loc_ops_in: u64, ops: *[..] u64, additional: *[..] Value_Id, i: Value_Id) {
    cur_loc_ops := cur_loc_ops_in;
    if !cur_loc_ops { array_add(ops, DW_OP_LLVM_ARG); array_add(ops, 0); cur_loc_ops = 1; }
    array_add(ops, DW_OP_LLVM_ARG); array_add(ops, cur_loc_ops);
    array_add(additional, op(i, 1));
}

// getSalvageOpsForBinOp
salvage_ops_for_binop :: (bi: Value_Id, cur_loc_ops: u64, ops: *[..] u64, additional: *[..] Value_Id) -> Value_Id {
    c := op(bi, 1);
    is_ci := is_scalar_const_int(c);
    if is_ci && type_bits(vtype(c)) > 64 return NONE;
    o := inst_op(bi);
    if is_ci {
        val := cast,no_check(u64) const_int_sext(c);
        if o == .ADD || o == .SUB {
            offset := ifx o == .ADD then cast,no_check(s64) val else -cast,no_check(s64) val;
            diexpr_append_offset(ops, offset);
            return op(bi, 0);
        }
        array_add(ops, DW_OP_CONSTU); array_add(ops, val);
    } else {
        salvage_handle_ssa_value_operands(cur_loc_ops, ops, additional, bi);
    }
    d := dwarf_op_for_binop(o);
    if !d return NONE;
    array_add(ops, d);
    return op(bi, 0);
}

dwarf_op_for_icmp_pred :: (p: u8) -> u64 {
    if p == ICMP_EQ return DW_OP_EQ;
    if p == ICMP_NE return DW_OP_NE;
    if p == ICMP_UGT || p == ICMP_SGT return DW_OP_GT;
    if p == ICMP_UGE || p == ICMP_SGE return DW_OP_GE;
    if p == ICMP_ULT || p == ICMP_SLT return DW_OP_LT;
    if p == ICMP_ULE || p == ICMP_SLE return DW_OP_LE;
    return 0;
}

// getSalvageOpsForIcmpOp
salvage_ops_for_icmp :: (ic: Value_Id, cur_loc_ops: u64, ops: *[..] u64, additional: *[..] Value_Id) -> Value_Id {
    c := op(ic, 1);
    is_ci := is_scalar_const_int(c);
    if is_ci && type_bits(vtype(c)) > 64 return NONE;
    if is_ci {
        array_add(ops, cast(u64) ifx icmp_is_signed(inst_pred(ic)) then DW_OP_CONSTS else DW_OP_CONSTU);
        array_add(ops, cast,no_check(u64) const_int_sext(c));
    } else {
        salvage_handle_ssa_value_operands(cur_loc_ops, ops, additional, ic);
    }
    d := dwarf_op_for_icmp_pred(inst_pred(ic));
    if !d return NONE;
    array_add(ops, d);
    return op(ic, 0);
}

// salvageDebugInfoImpl
salvage_debug_info_impl :: (i: Value_Id, cur_loc_ops: u64, ops: *[..] u64, additional: *[..] Value_Id) -> Value_Id {
    o := inst_op(i);
    if is_cast_op(o) {
        from := op(i, 0);
        if cast_is_noop(i) return from;
        ty := vtype(i);
        if type_kind(ty) == .PTR ty = dl_int_ptr_type(ty);
        if is_vector_type(ty) || !(o == .TRUNC || o == .SEXT || o == .ZEXT || o == .INTTOPTR || o == .PTRTOINT) return NONE;
        fty := vtype(from);
        if type_kind(fty) == .PTR fty = dl_int_ptr_type(fty);
        ext := diexpr_ext_ops(type_bits(scalar_type(fty)), type_bits(scalar_type(ty)), o == .SEXT);
        for ext array_add(ops, it);
        return from;
    }
    if o == .GEP return salvage_ops_for_gep(i, cur_loc_ops, ops, additional);
    if is_binary_op(o) return salvage_ops_for_binop(i, cur_loc_ops, ops, additional);
    if o == .ICMP return salvage_ops_for_icmp(i, cur_loc_ops, ops, additional);
    return NONE;
}

// salvageDbgAssignAddress
salvage_dbg_assign_address :: (r: u32) {
    rec := dbgr(r);
    a := rec.addr;
    if a == NONE || ir.mds[a].kind != .VALUE || !is_inst(ir.mds[a].value) return;
    i := ir.mds[a].value;
    ops: [..] u64; ops.allocator = temp;
    additional: [..] Value_Id; additional.allocator = temp;
    nv := salvage_debug_info_impl(i, 0, *ops, *additional);
    if nv == NONE return;
    e := diexpr_fold_constant_math(diexpr_append_ops_to_arg(rec.addr_expr, ops, 0, false));
    if additional.count == 0 {
        dbgr(r).addr = md_value(nv);
        dbgr(r).addr_expr = e;
        if dbgr(r).owner != NONE dbgr_restamp(r);
        if dbg_index.fn != NONE dbgr_index_record(r);
    } else {
        dbgr(r).addr = md_value(const_poison(vtype(i)));   // setKillAddress
    }
}

// salvageDebugInfo(I)
salvage_debug_info :: (i: Value_Id) {
    users: [..] u32; users.allocator = temp;
    find_dbg_users(inst_fn(i), i, *users);
    salvage_debug_info_for_dbg_values(i, users);
}

// salvageDebugInfoForDbgValues
salvage_debug_info_for_dbg_values :: (i: Value_Id, users: [] u32) {
    MAX_DEBUG_ARGS :: 16;
    MAX_EXPRESSION_SIZE :: 128;
    salvaged := false;
    for r: users {
        rec := dbgr(r);
        if rec.kind == .ASSIGN {
            if rec.addr != NONE && ir.mds[rec.addr].kind == .VALUE && ir.mds[rec.addr].value == i {
                salvage_dbg_assign_address(r);
                salvaged = true;
            }
            vals0: [..] Value_Id; vals0.allocator = temp;
            dbgr_location_ops(r, *vals0);
            if vals0.count == 0 || vals0[0] != i continue;
        }
        stack_value := rec.kind != .DECLARE;
        locs: [..] Value_Id; locs.allocator = temp;
        dbgr_location_ops(r, *locs);
        additional: [..] Value_Id; additional.allocator = temp;
        op0: Value_Id = NONE;
        expr := dbgr(r).expr;
        k := 0;
        while k < locs.count && locs[k] != i k += 1;
        while k < locs.count {
            ops: [..] u64; ops.allocator = temp;
            cur := diexpr_num_location_operands(expr);
            op0 = salvage_debug_info_impl(i, cur, *ops, *additional);
            if op0 == NONE break;
            expr = diexpr_append_ops_to_arg(expr, ops, cast(u64) k, stack_value);
            k += 1;
            while k < locs.count && locs[k] != i k += 1;
        }
        if op0 == NONE break;
        expr = diexpr_fold_constant_math(expr);
        dbgr_replace_variable_location_op(r, i, op0);
        valid := ir.mds[expr].nints <= MAX_EXPRESSION_SIZE;
        if additional.count == 0 && valid {
            dbgr(r).expr = expr;
        } else if dbgr(r).kind != .DECLARE && valid && locs.count + additional.count <= MAX_DEBUG_ARGS {
            dbgr_add_variable_location_ops(r, additional, expr);
        } else {
            dbgr_set_kill_location(r);
        }
        salvaged = true;
    }
    if salvaged return;
    for users dbgr_set_kill_location(it);
}

// ---------------------------------------------------------------- replaceAllDbgUsesWith

Dbg_Rewrite_Kind :: enum u8 { IDENTITY; SIGN_OR_ZERO_EXT; }

// rewriteDebugUsers (the RewriteDVRExpr lambda is a kind: identity, or sign/zero extension from from_bits)
rewrite_debug_users :: (from: Value_Id, to: Value_Id, dom_point: Value_Id, dt: *Dom_Tree, kind: Dbg_Rewrite_Kind,
                        to_bits: u64 = 0, from_bits: u64 = 0) -> bool {
    users: [..] u32; users.allocator = temp;
    find_dbg_users(inst_fn(from), from, *users);
    if users.count == 0 return false;
    changed := false;
    undef_or_salvage: [..] u32; undef_or_salvage.allocator = temp;
    if is_inst(to) {
        dom_after_from := inst(from).next == dom_point;
        for r: users {
            marked := dbgr(r).owner;
            if dom_after_from && marked == dom_point {
                // removeFromParent + insertDbgRecordAfter(DVR, DomPoint): head of the next instruction's records
                dbgr_erase(r);
                nx := inst(dom_point).next;
                if nx == NONE fatal("rewriteDebugUsers: moving a debug record to the end of a block is not supported yet");
                dbgr(r).next = inst(nx).records;
                dbgr(r).owner = nx;
                inst(nx).records = r;
                changed = true;
            } else if !dt_dominates_inst(dt, dom_point, marked) {
                array_add(*undef_or_salvage, r);
            }
        }
    }
    for r: users {
        skip := false;
        for undef_or_salvage if it == r { skip = true; break; }
        if skip continue;
        new_expr := dbgr(r).expr;
        if kind == .SIGN_OR_ZERO_EXT {
            known, signed := divar_signedness(dbgr(r).var);
            if !known continue;
            new_expr = diexpr_append_ext(dbgr(r).expr, to_bits, from_bits, signed);
        }
        dbgr_replace_variable_location_op(r, from, to);
        dbgr(r).expr = new_expr;
        changed = true;
    }
    if undef_or_salvage.count {
        salvage_debug_info(from);
        changed = true;
    }
    return changed;
}

// isBitCastSemanticsPreserving
bitcast_semantics_preserving :: (from_ty: Type_Id, to_ty: Type_Id) -> bool {
    if from_ty == to_ty return true;
    int_or_ptr :: (t: Type_Id) -> bool { k := type_kind(t); return k == .INT || k == .PTR; }
    if int_or_ptr(from_ty) && int_or_ptr(to_ty) {
        same := dl_type_size_bits(from_ty) == dl_type_size_bits(to_ty);
        return same && !dl_ni_ptr_type(from_ty) && !dl_ni_ptr_type(to_ty);
    }
    return false;
}

// llvm::replaceAllDbgUsesWith(From, To, DomPoint, DT)
replace_all_dbg_uses_with :: (from: Value_Id, to: Value_Id, dom_point: Value_Id, dt: *Dom_Tree) -> bool {
    if !md_value_exists(from) return false;   // isUsedByMetadata
    fty := vtype(from); tty := vtype(to);
    if bitcast_semantics_preserving(fty, tty) return rewrite_debug_users(from, to, dom_point, dt, .IDENTITY);
    if type_kind(fty) == .INT && type_kind(tty) == .INT {
        fb := cast(u64) type_bits(fty); tb := cast(u64) type_bits(tty);
        if fb < tb return rewrite_debug_users(from, to, dom_point, dt, .IDENTITY);
        return rewrite_debug_users(from, to, dom_point, dt, .SIGN_OR_ZERO_EXT, tb, fb);
    }
    return false;
}

// Value::isUsedByMetadata: a ValueAsMetadata exists for the value
md_value_exists :: (v: Value_Id) -> bool {
    k := *md_key; key_reset(k); key_u8(k, 1); key_u32(k, v);
    return table_contains(*ir.md_map, key_view(k));
}

// ---------------------------------------------------------------- LowerDbgDeclare (Local.cpp)

// ConvertDebugDeclareToDebugValue(DVR, LoadInst *LI, DIB): the new record goes after the load
convert_debug_declare_to_debug_value_load :: (r: u32, li: Value_Id) {
    if !value_covers_entire_fragment(vtype(li), r) return;
    rec := dbgr(r);
    nr: Dbg_Record;
    nr.kind = .VALUE;
    nr.loc = md_value(li);
    nr.var = rec.var; nr.expr = rec.expr; nr.dbg = debug_value_loc(r);
    array_add(*ir.dbg_records, nr);
    id := cast(u32) ir.dbg_records.count;
    dbgr_restamp(id);
    // insertDbgRecordAfter(DV, LI): at the head of the next instruction's records
    nx := inst(li).next;
    assert(nx != NONE, "a load is never a terminator");
    dbgr(id).owner = nx;
    dbgr(id).next = inst(nx).records;
    inst(nx).records = id;
    if dbg_index.fn != NONE dbgr_index_record(id);
}

// isCompositeType: the variable's type, through modifiers, is not a DIBasicType (pointers count as scalars)
dbg_var_is_composite_type :: (r: u32) -> bool {
    t := di_op(dbgr(r).var, 3);
    if t == NONE return true;
    while is_di(t, .DERIVED_TYPE) {
        tag := di_int(t, 0);
        if tag == 0x0f || tag == 0x10 || tag == 0x42 || tag == 0x1f || tag == DW_TAG_LLVM_PTRAUTH_TYPE return false;
        // typedef, const, volatile, restrict, atomic, immutable
        if tag == 0x16 || tag == 0x26 || tag == 0x35 || tag == 0x37 || tag == 0x47 || tag == 0x4b { t = di_op(t, 5); continue; }
        break;
    }
    return !is_di(t, .BASIC_TYPE);
}

// llvm::LowerDbgDeclare
lower_dbg_declare :: (f: Value_Id) -> bool {
    changed := false;
    dvrs: [..] u32; dvrs.allocator = temp;
    for b: fn_blocks(f) for i: block_insts(b) {
        r := inst(i).records;
        while r { if dbgr(r).kind == .DECLARE array_add(*dvrs, r); r = dbgr(r).next; }
    }
    if dvrs.count == 0 return false;
    for ddi: dvrs {
        loc := dbgr(ddi).loc;
        ai: Value_Id = NONE;
        if loc != NONE && ir.mds[loc].kind == .VALUE { v := ir.mds[loc].value; if is_inst(v) && inst_op(v) == .ALLOCA ai = v; }
        if ai == NONE || !is_constant_kind(vkind(op(ai, 0))) || dbg_var_is_composite_type(ddi) continue;
        volatile_use := false;
        u := ir.v_first_use[ai];
        while u != NONE {
            us := ir.u_user[u];
            if (inst_op(us) == .LOAD || inst_op(us) == .STORE) && is_volatile(us) { volatile_use = true; break; }
            u = ir.u_next[u];
        }
        if volatile_use continue;
        wl: [..] Value_Id; wl.allocator = temp;
        array_add(*wl, ai);
        while wl.count {
            v := pop(*wl);
            u := ir.v_first_use[v];
            while u != NONE {
                us := ir.u_user[u];
                o := inst_op(us);
                if o == .STORE {
                    if u == op_use(us, 1) convert_debug_declare_to_debug_value_store(ddi, us);
                } else if o == .LOAD {
                    convert_debug_declare_to_debug_value_load(ddi, us);
                } else if o == .CALL {
                    if !is_intrinsic_call(us, IID_LIFETIME_START) && !is_intrinsic_call(us, IID_LIFETIME_END) {
                        deref := u64.[DW_OP_DEREF_];
                        e := diexpr_append(dbgr(ddi).expr, deref);
                        dbgr_insert_value_before(ai, dbgr(ddi).var, e, debug_value_loc(ddi), us);
                    }
                } else if o == .BITCAST {
                    if type_kind(vtype(us)) == .PTR array_add(*wl, us);
                }
                u = ir.u_next[u];
            }
        }
        dbgr_erase(ddi);
        changed = true;
    }
    if changed for b: fn_blocks(f) remove_redundant_dbg_instrs(b);
    return changed;
}

// ---------------------------------------------------------------- RemoveRedundantDbgInstrs (BasicBlockUtils.cpp)

// DebugVariable(Var, fragment of Expr, InlinedAt)
Debug_Variable :: struct { var: Md_Id; has_frag: bool; foff: u64; fsize: u64; inlined: Md_Id; }
debug_variable_of :: (r: u32, with_fragment: bool) -> Debug_Variable {
    k: Debug_Variable;
    k.var = dbgr(r).var;
    if with_fragment {
        k.has_frag, k.foff, k.fsize = diexpr_fragment(dbgr(r).expr);
        if !k.has_frag { k.foff = 0; k.fsize = 0; }
    }
    k.inlined = diloc_inlined_at(dbgr(r).dbg);
    return k;
}
debug_variable_eq :: (a: Debug_Variable, b: Debug_Variable) -> bool {
    return a.var == b.var && a.has_frag == b.has_frag && a.foff == b.foff && a.fsize == b.fsize && a.inlined == b.inlined;
}

// at::getAssignmentInsts(DVR) is non-empty: an instruction of the function carries the record's DIAssignID
dbg_assign_has_linked_insts :: (r: u32) -> bool {
    id := dbgr(r).assign_id;
    if id == NONE return false;
    k := md_fixed("DIAssignID");
    o := dbgr(r).owner;
    if o == NONE return false;
    for b: fn_blocks(inst_fn(o)) for i: block_insts(b) if get_metadata(i, k) == id return true;
    return false;
}

// removeRedundantDbgInstrsUsingBackwardScan
remove_redundant_dbg_backward :: (bb: Value_Id) -> bool {
    to_remove: [..] u32; to_remove.allocator = temp;
    i := block(bb).last;
    while i != NONE {
        seen: [..] Debug_Variable; seen.allocator = temp;
        recs: [..] u32; recs.allocator = temp;
        r := inst(i).records;
        while r { if dbgr(r).kind != .LABEL array_add(*recs, r); r = dbgr(r).next; }
        for < recs {
            key := debug_variable_of(it, true);
            dup := false;
            for s: seen if debug_variable_eq(s, key) { dup = true; break; }
            if !dup { array_add(*seen, key); continue; }
            if dbgr(it).kind == .ASSIGN && dbg_assign_has_linked_insts(it) continue;
            array_add(*to_remove, it);
        }
        i = inst(i).prev;
    }
    for to_remove dbgr_erase(it);
    return to_remove.count > 0;
}

// removeRedundantDbgInstrsUsingForwardScan
remove_redundant_dbg_forward :: (bb: Value_Id) -> bool {
    removed := false;
    Entry :: struct { key: Debug_Variable; vals: [..] Value_Id; expr: Md_Id; }
    map: [..] Entry; map.allocator = temp;
    for i: block_insts(bb) {
        r := inst(i).records;
        while r {
            nr := dbgr(r).next;
            defer r = nr;
            if dbgr(r).kind == .LABEL || dbgr(r).kind == .DECLARE continue;
            key := debug_variable_of(r, false);
            slot := -1;
            for map if debug_variable_eq(it.key, key) { slot = it_index; break; }
            inserted := slot < 0;
            if inserted { e: Entry; e.key = key; e.vals.allocator = temp; array_add(*map, e); slot = map.count - 1; }
            is_value_kind := dbgr(r).kind != .ASSIGN || !dbg_assign_has_linked_insts(r);
            vals: [..] Value_Id; vals.allocator = temp;
            dbgr_location_ops(r, *vals);
            e := *map[slot];
            same := !inserted && e.vals.count == vals.count && e.expr == dbgr(r).expr;
            if same for vals if e.vals[it_index] != it { same = false; break; }
            if !same {
                e.vals.count = 0;
                for vals array_add(*e.vals, it);
                e.expr = ifx is_value_kind then dbgr(r).expr else NONE;
                continue;
            }
            if !is_value_kind continue;
            dbgr_erase(r);
            removed = true;
        }
    }
    return removed;
}

// removeUndefDbgAssignsFromEntryBlock
remove_undef_dbg_assigns_from_entry_block :: (bb: Value_Id) -> bool {
    removed := false;
    Agg :: struct { var: Md_Id; inlined: Md_Id; }
    seen: [..] Agg; seen.allocator = temp;
    for i: block_insts(bb) {
        r := inst(i).records;
        while r {
            nr := dbgr(r).next;
            defer r = nr;
            k := dbgr(r).kind;
            if k != .VALUE && k != .ASSIGN continue;
            is_value_kind := k == .VALUE || !dbg_assign_has_linked_insts(r);
            a := Agg.{dbgr(r).var, diloc_inlined_at(dbgr(r).dbg)};
            found := false;
            for seen if it.var == a.var && it.inlined == a.inlined { found = true; break; }
            if found continue;
            is_kill := dbgr_is_kill_location(r) && is_value_kind;
            if !is_kill array_add(*seen, a);
            else if k == .ASSIGN { dbgr_erase(r); removed = true; }
        }
    }
    return removed;
}

// isAssignmentTrackingEnabled: the "debug-info-assignment-tracking" module flag is set
assignment_tracking_enabled :: () -> bool {
    for nm: ir.named_md {
        if nm.name != "llvm.module.flags" continue;
        for fl: nm.ops {
            if fl == NONE || ir.mds[fl].kind != .TUPLE || ir.mds[fl].nops < 3 continue;
            k := md_op(fl, 1);
            if k == NONE || ir.mds[k].kind != .STRING || ir.mds[k].str != "debug-info-assignment-tracking" continue;
            v := md_op(fl, 2);
            return v != NONE && ir.mds[v].kind == .VALUE && vkind(ir.mds[v].value) == .C_INT && const_int_zext(ir.mds[v].value) != 0;
        }
    }
    return false;
}

// llvm::RemoveRedundantDbgInstrs
remove_redundant_dbg_instrs :: (bb: Value_Id) -> bool {
    changed := remove_redundant_dbg_backward(bb);
    if bb == fn_entry(block_fn(bb)) && assignment_tracking_enabled() changed |= remove_undef_dbg_assigns_from_entry_block(bb);
    changed |= remove_redundant_dbg_forward(bb);
    return changed;
}

// RedundantDbgInstEliminationPass::run
redundant_dbg_inst_elim_run :: (f: Value_Id) -> Preserved {
    changed := false;
    for b: fn_blocks(f) changed |= remove_redundant_dbg_instrs(b);
    if !changed return PRESERVE_ALL;
    return preserved_cfg();
}
