// InstCombine framework: a port of llvm/lib/Transforms/InstCombine/InstructionCombining.cpp (the driver: worklist,
// prepareWorklist, run, sinking, combineInstructionsOverFunction, InstCombinePass::run), of the InstCombiner /
// InstCombinerImpl helpers in InstCombiner.h / InstCombineInternal.h, of llvm/include/llvm/Transforms/Utils/
// InstructionWorklist.h, and of the IRBuilder<TargetFolder, IRBuilderInstCombineInserter> the combiner uses.
//
// Structure (DESIGN.md "InstCombine"): one global state `ic` per function run; `ic_visit` dispatches on the opcode
// to the visitor ported from the matching InstCombine*.cpp file (ic_addsub.jai, ic_muldivrem.jai, ic_misc.jai, ...).
// A visitor returns NONE (no change), the instruction itself (changed in place, or its uses were replaced), or a new
// *unlinked* instruction that replaces it (the driver inserts it, moves the name and erases the old one), exactly
// like `Instruction *visitX(...)` in LLVM.

// ---------------------------------------------------------------- InstructionWorklist

Ic_Worklist :: struct {
    list: [..] Value_Id;                 // NONE = removed slot
    map: Table(Value_Id, s64);
    deferred: [..] Value_Id;             // SmallSetVector
    deferred_set: Table(Value_Id, bool);
}

wl_is_empty :: () -> bool { return ic.wl.list.count == 0 && ic.wl.deferred.count == 0; }
// add: deferred, visited in the order added
wl_add :: (i: Value_Id) {
    if table_contains(*ic.wl.deferred_set, i) return;
    table_set(*ic.wl.deferred_set, i, true);
    array_add(*ic.wl.deferred, i);
}
wl_add_value :: (v: Value_Id) { if is_inst(v) wl_add(v); }
// push: visited last-in first-out
wl_push :: (i: Value_Id) {
    if table_contains(*ic.wl.map, i) return;
    table_set(*ic.wl.map, i, ic.wl.list.count);
    array_add(*ic.wl.list, i);
}
wl_push_value :: (v: Value_Id) { if is_inst(v) wl_push(v); }
wl_pop_deferred :: () -> Value_Id {
    if ic.wl.deferred.count == 0 return NONE;
    i := pop(*ic.wl.deferred);
    table_remove(*ic.wl.deferred_set, i);
    return i;
}
wl_remove :: (i: Value_Id) {
    found, idx := table_find(*ic.wl.map, i);
    if found {
        ic.wl.list[idx] = NONE;
        table_remove(*ic.wl.map, i);
    }
    if table_contains(*ic.wl.deferred_set, i) {
        table_remove(*ic.wl.deferred_set, i);
        for ic.wl.deferred if it == i { array_ordered_remove_by_index(*ic.wl.deferred, it_index); break; }
    }
}
wl_remove_one :: () -> Value_Id {
    if ic.wl.list.count == 0 return NONE;
    i := pop(*ic.wl.list);
    if i != NONE table_remove(*ic.wl.map, i);
    return i;
}
// pushUsersToWorkList: users in use-list order
wl_push_users :: (i: Value_Id) {
    u := ir.v_first_use[i];
    while u != NONE { wl_push(ir.u_user[u]); u = ir.u_next[u]; }
}
// handleUseCountDecrement
wl_handle_use_count_decrement :: (v: Value_Id) {
    if !is_inst(v) return;
    wl_add(v);
    if has_one_use(v) wl_add(ir.u_user[ir.v_first_use[v]]);
}

has_one_use :: (v: Value_Id) -> bool { u := ir.v_first_use[v]; return u != NONE && ir.u_next[u] == NONE; }
has_n_uses :: (v: Value_Id, n: int) -> bool {
    u := ir.v_first_use[v]; k := 0;
    while u != NONE { k += 1; if k > n return false; u = ir.u_next[u]; }
    return k == n;
}
has_n_uses_or_more :: (v: Value_Id, n: int) -> bool {
    u := ir.v_first_use[v]; k := 0;
    while u != NONE { k += 1; if k >= n return true; u = ir.u_next[u]; }
    return k >= n;
}
// Value::hasOneUser: all uses by the same user
has_one_user :: (v: Value_Id) -> bool {
    u := ir.v_first_use[v];
    if u == NONE return false;
    first := ir.u_user[u];
    u = ir.u_next[u];
    while u != NONE { if ir.u_user[u] != first return false; u = ir.u_next[u]; }
    return true;
}
// m_OneUse for constants: Constant::hasOneUse is a use-list property too, as for any value
one_use :: inline (v: Value_Id) -> bool { return has_one_use(v); }
first_user :: (v: Value_Id) -> Value_Id { u := ir.v_first_use[v]; if u == NONE return NONE; return ir.u_user[u]; }

// ---------------------------------------------------------------- state

Ic_Options :: struct {
    max_iterations: u32 = 1;   // InstCombineDefaultMaxIterations
    verify_fixpoint := true;   // PassBuilder's parseInstCombineOptions starts with setVerifyFixpoint(true)
}

Ic_State :: struct {
    f: Value_Id;
    dt: *Dom_Tree;
    ac: *Assumption_Cache;
    sq: Simplify_Query;
    dc: Dom_Cond_Cache;
    wl: Ic_Worklist;
    b: Irb;                       // Builder
    b_fmf: u32;                   // Builder's default fast-math flags (FMF_* bits)
    made_ir_change: bool;
    dead_edges: Table(u64, bool); // (from, to) pairs known never taken
    back_edges: Table(u64, bool);
    computed_back_edges: bool;
    rpot: [..] Value_Id;
    annotation_src: Value_Id = NONE;
    default_bundles_src: Value_Id = NONE;   // IRBuilder::setDefaultOperandBundles: the call whose bundles new calls get
    max_array_size: u64 = 1024;   // -instcombine-maxarray-size
    min_size: bool;
    pred_order: Table(Value_Id, [..] Value_Id);
}
ic: Ic_State;

edge_key :: inline (a: Value_Id, b: Value_Id) -> u64 { return ((cast(u64) a) << 32) | cast(u64) b; }

// SQ.getWithInstruction(I)
ic_q :: (i: Value_Id) -> Simplify_Query { return sq_with_instruction(ic.sq, i); }

// ---------------------------------------------------------------- IR helpers used by the combiner

// Value::takeName: this loses its own name first, even when `src` has none.
ic_take_name :: (dst: Value_Id, src: Value_Id) {
    if dst == src return;
    if vname(dst).count set_name(dst, "");
    n := vname(src);
    if n.count == 0 return;
    // getSymTab fails for values that cannot have a name (constants): nothing happens, src keeps its name
    if is_constant_kind(vkind(dst)) return;
    set_name(src, "");
    set_name(dst, n);
}

// ValueSymbolTable::reinsertValue after an unlinked, named instruction was put into a function.
ic_reinsert_name :: (i: Value_Id) {
    n := vname(i);
    if n.count == 0 return;
    ir.v_name[i] = "";
    set_name(i, n);
}

// Instruction::insertBefore / insertInto for a new instruction (debug records of `pos` are adopted unless `head`)
ic_link_before :: (i: Value_Id, pos: Value_Id, head := false) {
    insert_at_position(i, inst(pos).parent, pos, head);
    ic_reinsert_name(i);
}
ic_link_at_end :: (i: Value_Id, bb: Value_Id) {
    block_append_inst(bb, i);
    ic_reinsert_name(i);
}

// Instruction::clone (no name, no debug records; metadata and payload copied)
ic_clone_inst :: (i: Value_Id) -> Value_Id {
    n := nops(i);
    c := new_inst(inst_op(i), vtype(i), n);
    src := inst(i).*;
    r := inst(c);
    r.* = src;
    r.parent = NONE; r.prev = NONE; r.next = NONE; r.records = 0;
    if src.nidx > 0 {
        // call-like instructions keep three entries per operand bundle (tag, begin, end)
        cnt := src.nidx;
        o := inst_op(i);
        if o == .CALL || o == .INVOKE || o == .CALLBR cnt *= 3;
        r.idx = cast(u32) ir.u32_pool.count;
        for k: 0..cnt-1 array_add(*ir.u32_pool, ir.u32_pool[src.idx + k]);
    }
    if inst_op(i) == .PHI {
        for k: 0..cast(s64) n - 1 { set_op(c, cast(u32) k, op(i, cast(u32) k)); ir.u_aux[ir.v_ops[c] + cast(u32) k] = ir.u_aux[ir.v_ops[i] + cast(u32) k]; }
    } else {
        for k: 0..cast(s64) n - 1 set_op(c, cast(u32) k, op(i, cast(u32) k));
        if inst_op(i) == .SWITCH for k: 0..cast(s64) n - 1 ir.u_aux[ir.v_ops[c] + cast(u32) k] = ir.u_aux[ir.v_ops[i] + cast(u32) k];
    }
    copy_metadata(c, i);
    return c;
}

// User::replaceUsesOfWith
replace_uses_of_with :: (user: Value_Id, from: Value_Id, to: Value_Id) {
    n := nops(user);
    for k: 0..cast(s64) n - 1 if op(user, cast(u32) k) == from set_op(user, cast(u32) k, to);
}

// Instruction::dropUnknownNonDebugMetadata(KnownIDs)
drop_unknown_non_debug_metadata :: (i: Value_Id, keep: [] u32) {
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(i, *all);
    assign := md_kind_id("DIAssignID");   // a DIAssignID attachment is debug metadata, never dropped
    for all {
        if it.kind == 0 || it.kind == assign continue;
        kept := false;
        for k: keep if k == it.kind { kept = true; break; }
        if !kept set_metadata(i, it.kind, NONE);
    }
}
// Instruction::dropUBImplyingAttrsAndMetadata
drop_ub_implying_attrs_and_metadata :: (i: Value_Id) {
    keep: [8] u32;
    keep[0] = md_kind_id("annotation"); keep[1] = md_kind_id("range"); keep[2] = md_kind_id("nonnull");
    keep[3] = md_kind_id("align"); keep[4] = md_kind_id("fpmath"); keep[5] = md_kind_id("prof");
    keep[6] = md_kind_id("mem.cache_hint"); keep[7] = md_kind_id("nofpclass");
    drop_unknown_non_debug_metadata(i, keep);
    if is_call_base(i) && inst(i).attrs != 0 {
        // AttributeFuncs::getUBImplyingAttributes: noundef, dereferenceable, dereferenceable_or_null
        strip :: (s: u32) -> u32 {
            r := attr_set_remove(s, .NoUndef);
            r = attr_set_remove(r, .Dereferenceable);
            r = attr_set_remove(r, .DereferenceableOrNull);
            return r;
        }
        l := inst(i).attrs;
        row := ir.attr_lists[l];
        params := NewArray(row.params.count, u32,, allocator = temp);
        na := call_arg_count(i);
        for row.params params[it_index] = ifx cast(u32) it_index < na then strip(it) else it;
        inst(i).attrs = attr_list_get(row.fn, strip(row.ret), params);
    }
}

// isa<FPMathOperator>
is_fp_math_op_value :: (v: Value_Id) -> bool {
    if !is_inst(v) return false;
    return is_fp_math_inst(v);
}
inst_flags :: inline (i: Value_Id) -> u32 { return inst(i).flags; }
has_nsw :: inline (i: Value_Id) -> bool { return (opr_flags(i) & F_NSW) != 0; }
has_nuw :: inline (i: Value_Id) -> bool { return (opr_flags(i) & F_NUW) != 0; }
is_exact :: inline (i: Value_Id) -> bool { return (opr_flags(i) & F_EXACT) != 0; }
set_flag :: (i: Value_Id, f: u32, on: bool) { if on inst(i).flags |= f; else inst(i).flags &= ~f; }
set_nsw :: (i: Value_Id, on := true) { set_flag(i, F_NSW, on); }
set_nuw :: (i: Value_Id, on := true) { set_flag(i, F_NUW, on); }
set_exact :: (i: Value_Id, on := true) { set_flag(i, F_EXACT, on); }
get_fmf :: (i: Value_Id) -> u32 { return (opr_flags(i) >> FMF_SHIFT) & FMF_ALL; }
set_fmf :: (i: Value_Id, fmf: u32) { inst(i).flags = (inst(i).flags & ~(cast(u32) FMF_ALL << FMF_SHIFT)) | ((fmf & FMF_ALL) << FMF_SHIFT); }

// Instruction::copyIRFlags(V, IncludeWrapFlags = true)
copy_ir_flags :: (dst: Value_Id, src: Value_Id) {
    if !is_inst(dst) return;
    sf := opr_flags(src);
    so := opr_code(src);
    d := inst(dst);
    dop := d.op;
    if is_overflowing_binop(src) && is_overflowing_binop(dst) {
        d.flags = (d.flags & ~cast(u32)(F_NSW | F_NUW)) | (sf & (F_NSW | F_NUW));
    }
    if is_possibly_exact_op(src) && is_possibly_exact_op(dst) set_flag(dst, F_EXACT, (sf & F_EXACT) != 0);
    if so == .OR && dop == .OR set_flag(dst, F_EXACT, (sf & F_EXACT) != 0);   // disjoint
    if is_fp_math_op_value(src) && is_fp_math_op_value(dst) set_fmf(dst, (sf >> FMF_SHIFT) & FMF_ALL);
    if (so == .ZEXT || so == .UITOFP) && (dop == .ZEXT || dop == .UITOFP) set_flag(dst, F_EXACT, (sf & F_EXACT) != 0);
    if so == .GEP && dop == .GEP d.flags = (d.flags & ~cast(u32)(F_INBOUNDS | F_NUSW | F_GEP_NUW)) | (sf & (F_INBOUNDS | F_NUSW | F_GEP_NUW));
    if so == .TRUNC && dop == .TRUNC d.flags = (d.flags & ~cast(u32)(F_NSW | F_NUW)) | (sf & (F_NSW | F_NUW));
    if so == .ICMP && dop == .ICMP set_flag(dst, F_EXACT, (sf & F_EXACT) != 0);
}
// Instruction::andIRFlags
and_ir_flags :: (dst: Value_Id, src: Value_Id) {
    sf := opr_flags(src);
    d := inst(dst);
    if is_overflowing_binop(src) && is_overflowing_binop(dst) {
        if (sf & F_NSW) == 0 d.flags &= ~cast(u32) F_NSW;
        if (sf & F_NUW) == 0 d.flags &= ~cast(u32) F_NUW;
    }
    if is_possibly_exact_op(src) && is_possibly_exact_op(dst) && (sf & F_EXACT) == 0 d.flags &= ~cast(u32) F_EXACT;
    if opr_code(src) == .OR && d.op == .OR && (sf & F_EXACT) == 0 d.flags &= ~cast(u32) F_EXACT;
    if is_fp_math_op_value(src) && is_fp_math_op_value(dst) set_fmf(dst, get_fmf(dst) & ((sf >> FMF_SHIFT) & FMF_ALL));
    // TruncInst nuw/nsw, PossiblyNonNegInst (zext, uitofp) nneg, ICmpInst samesign
    so := ifx is_inst(src) then inst_op(src) else Opcode.NONE_OP;
    if so == .TRUNC && d.op == .TRUNC {
        if (sf & F_NSW) == 0 d.flags &= ~cast(u32) F_NSW;
        if (sf & F_NUW) == 0 d.flags &= ~cast(u32) F_NUW;
    }
    if (so == .ZEXT || so == .UITOFP) && (d.op == .ZEXT || d.op == .UITOFP) && (sf & F_EXACT) == 0 d.flags &= ~cast(u32) F_EXACT;
    if so == .ICMP && d.op == .ICMP && (sf & F_EXACT) == 0 d.flags &= ~cast(u32) F_EXACT;
    if so == .GEP && d.op == .GEP {
        // DestGEP->setNoWrapFlags(DestGEP->getNoWrapFlags() & SrcGEP->getNoWrapFlags())
        nw := ic_gep_nw_intersect(dst, src);
        d.flags = (d.flags & ~cast(u32) (F_INBOUNDS | F_NUSW | F_GEP_NUW)) | nw;
    }
}

// Instruction::isIdenticalTo (same opcode, type, operands and "special state")
is_identical_to :: (a: Value_Id, b: Value_Id) -> bool {
    if inst_op(a) != inst_op(b) || vtype(a) != vtype(b) || nops(a) != nops(b) return false;
    for k: 0..cast(s64) nops(a) - 1 if op(a, cast(u32) k) != op(b, cast(u32) k) return false;
    ra := inst(a); rb := inst(b);
    if ra.flags != rb.flags || ra.pred != rb.pred || ra.ty2 != rb.ty2 || ra.align != rb.align || ra.attrs != rb.attrs ||
       ra.cc != rb.cc || ra.ord1 != rb.ord1 || ra.ord2 != rb.ord2 || ra.nidx != rb.nidx || ra.sync != rb.sync return false;
    if ra.nidx > 0 for k: 0..ra.nidx-1 if ir.u32_pool[ra.idx + k] != ir.u32_pool[rb.idx + k] return false;
    if inst_op(a) == .PHI for k: 0..cast(s64) nops(a) - 1 if phi_block(a, cast(u32) k) != phi_block(b, cast(u32) k) return false;
    return true;
}

// ---------------------------------------------------------------- InstCombiner helpers

// replaceInstUsesWith: returns `i` (changed) or NONE when there were no uses
ic_replace_inst_uses_with :: (i: Value_Id, v_in: Value_Id) -> Value_Id {
    if !has_uses(i) return NONE;
    wl_push_users(i);
    v := v_in;
    if i == v v = const_poison(vtype(i));
    if !has_uses(v) && is_inst(v) && vname(v).count == 0 && vname(i).count ic_take_name(v, i);
    rauw_with_metadata(i, v);
    return i;
}
// replaceOperand
ic_replace_operand :: (i: Value_Id, k: u32, v: Value_Id) -> Value_Id {
    old := op(i, k);
    set_op(i, k, v);
    wl_handle_use_count_decrement(old);
    return i;
}
// replaceUse
ic_replace_use :: (u: Use_Id, v: Value_Id) {
    old := ir.u_val[u];
    use_set(u, v);
    wl_handle_use_count_decrement(old);
}
// InsertNewInstBefore / InsertNewInstWith (the latter also copies the debug location of `pos`)
ic_insert_new_inst_before :: (new: Value_Id, pos: Value_Id, head := false) -> Value_Id {
    ic_link_before(new, pos, head);
    wl_add(new);
    return new;
}
ic_insert_new_inst_with :: (new: Value_Id, pos: Value_Id, head := false) -> Value_Id {
    copy_debug_loc_or_clear(new, pos);
    return ic_insert_new_inst_before(new, pos, head);
}
copy_debug_loc_or_clear :: (to: Value_Id, from: Value_Id) { set_metadata(to, 0, get_metadata(from, 0)); }

// eraseInstFromFunction: always returns NONE
ic_erase_inst :: (i: Value_Id) -> Value_Id {
    assert(!has_uses(i), "instcombine: erasing an instruction that is used");
    salvage_debug_info(i);
    ops: [..] Value_Id; ops.allocator = temp;
    for k: 0..cast(s64) nops(i) - 1 array_add(*ops, op(i, cast(u32) k));
    wl_remove(i);
    dc_remove_value(*ic.dc, i);
    erase_inst_with_metadata(i);
    for ops wl_handle_use_count_decrement(it);
    ic.made_ir_change = true;
    return NONE;
}

// getComplexity
ic_complexity :: (v: Value_Id) -> u32 {
    if is_const(v) return ifx pm_undef_value(v) then cast(u32) 0 else 1;
    if is_inst(v) && is_cast_op(inst_op(v)) return 2;
    ok, x := pm_neg(v); if ok return 2;
    ok, x = pm_not(v); if ok return 2;
    ok, x = pm_fneg(v); if ok return 2;
    return 3;
}
// isCanonicalPredicate
is_canonical_predicate :: (p: u8) -> bool {
    return !(p == ICMP_NE || p == ICMP_ULE || p == ICMP_SLE || p == ICMP_UGE || p == ICMP_SGE ||
             p == FCMP_ONE || p == FCMP_OLE || p == FCMP_OGE);
}

// AddOne / SubOne (ConstantExpr::getAdd(C, ConstantInt::get(C->getType(), 1)))
ic_add_one :: (c: Value_Id) -> Value_Id { return ce_binop(.ADD, c, const_int_of(vtype(c), 1), 0); }
ic_sub_one :: (c: Value_Id) -> Value_Id { return ce_binop(.SUB, c, const_int_of(vtype(c), 1), 0); }
// ConstantExpr::getNeg / getNot
ce_neg :: (c: Value_Id, nsw := false) -> Value_Id { return ce_binop(.SUB, const_null_value(vtype(c)), c, ifx nsw then cast(u32) F_NSW else 0); }

// ConstantInt::get(Ty, APInt) for scalar or vector types: const_int_ap (memoryssa.jai)
const_int_signed :: (t: Type_Id, v: s64) -> Value_Id { return const_int_ap(t, ap_from_s64(type_bits(scalar_type(t)), v)); }
scalar_bits :: (v: Value_Id) -> u32 { return type_bits(scalar_type(vtype(v))); }
is_int_or_int_vector_n :: (t: Type_Id, n: u32) -> bool { st := scalar_type(t); return is_int_type(st) && type_int_width(st) == n; }

// shouldChangeType / isDesirableIntType
ic_is_desirable_int_type :: (bits: u32) -> bool {
    if bits == 8 || bits == 16 || bits == 32 return true;
    return dl_is_legal_integer(bits);
}
ic_should_change_type_widths :: (from: u32, to: u32) -> bool {
    from_legal := from == 1 || dl_is_legal_integer(from);
    to_legal := to == 1 || dl_is_legal_integer(to);
    if to < from && ic_is_desirable_int_type(to) return true;
    if (from_legal || ic_is_desirable_int_type(from)) && !to_legal return false;
    if !from_legal && !to_legal && to > from return false;
    return true;
}
ic_should_change_type :: (from: Type_Id, to: Type_Id) -> bool {
    if !is_int_type(from) || !is_int_type(to) return false;
    return ic_should_change_type_widths(type_int_width(from), type_int_width(to));
}

// isBackEdge (computeBackEdges over the RPOT)
ic_is_back_edge :: (from: Value_Id, to: Value_Id) -> bool {
    if !ic.computed_back_edges {
        visited: Table(Value_Id, bool); visited.allocator = temp;
        succs: [..] Value_Id; succs.allocator = temp;
        for bb: ic.rpot {
            table_set(*visited, bb, true);
            succs.count = 0;
            block_successors(bb, *succs);
            for s: succs if table_contains(*visited, s) table_set(*ic.back_edges, edge_key(bb, s), true);
        }
        ic.computed_back_edges = true;
    }
    return table_contains(*ic.back_edges, edge_key(from, to));
}

// ---------------------------------------------------------------- Builder (IRBuilder<TargetFolder, IRBuilderInstCombineInserter>)

// IRBuilderInstCombineInserter::InsertHelper + IRBuilder::Insert
icb_insert :: (i_in: Value_Id, name: string = "") -> Value_Id {
    i := i_in;
    if ic.default_bundles_src != NONE && inst_op(i) == .CALL && inst(i).nidx == 0 i = call_with_default_bundles(i, ic.default_bundles_src);
    irb_insert(*ic.b, i, name);
    if negator { array_add(*negator.new_insts, i); return i; }   // the Negator's IRBuilderCallbackInserter
    wl_add(i);
    if is_intrinsic_call(i, IID_ASSUME) ic_register_assumption(i);
    if ic.annotation_src != NONE {
        k := md_kind_id("annotation");
        a := get_metadata(ic.annotation_src, k);
        if a != NONE fatal("instcombine: !annotation metadata is not supported yet");
    }
    return i;
}
// CallInst::Create(..., DefaultOperandBundles): a copy of the unlinked call `i` with the operand bundles of `src`
// (operands: args, bundle operands, callee)
call_with_default_bundles :: (i: Value_Id, src: Value_Id) -> Value_Id {
    na := nops(i) - 1;
    sr := inst(src);
    sa := call_arg_count(src);
    nbo := nops(src) - 1 - sa;
    c := new_inst(.CALL, vtype(i), na + nbo + 1);
    keep := inst(i).*;
    r := inst(c);
    r.* = keep;
    r.parent = NONE; r.prev = NONE; r.next = NONE; r.records = 0;
    for k: 0..cast(s64) na - 1 set_op(c, cast(u32) k, op(i, cast(u32) k));
    for k: 0..cast(s64) nbo - 1 set_op(c, na + cast(u32) k, op(src, sa + cast(u32) k));
    set_op(c, na + nbo, op(i, na));
    r = inst(c);
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = sr.nidx;
    for x: 0..cast(s64) sr.nidx - 1 {
        t := ir.u32_pool[sr.idx + 3 * cast(u32) x]; b := ir.u32_pool[sr.idx + 3 * cast(u32) x + 1]; e := ir.u32_pool[sr.idx + 3 * cast(u32) x + 2];
        array_add(*ir.u32_pool, t); array_add(*ir.u32_pool, b - sa + na); array_add(*ir.u32_pool, e - sa + na);
    }
    erase_unlinked_inst(i);
    return c;
}
ic_register_assumption :: (i: Value_Id) {
    if !ic.ac return;
    array_add(*ic.ac.assumes, i);
    ac_update_affected_values(ic.ac, i);
}
icb_set_insert_point :: (i: Value_Id) { irb_set_before(*ic.b, i); }
icb_set_insert_point_after :: (i: Value_Id) {   // SetInsertPoint(I->getNextNode()) style: before the next instruction
    nx := inst(i).next;
    if nx == NONE { irb_set_end(*ic.b, inst(i).parent); return; }
    irb_set_before(*ic.b, nx);
}

// FoldBinOp/FoldNoWrapBinOp/FoldExactBinOp of TargetFolder
tf_fold_binop :: (opc: Opcode, l: Value_Id, r: Value_Id, flags: u32) -> Value_Id {
    if !is_const(l) || !is_const(r) return NONE;
    if is_desirable_bin_op(opc) return cfo_constant(ce_binop(opc, l, r, flags & (F_NUW | F_NSW | F_EXACT)));
    return cfo_binary_op_operands(opc, l, r);
}
// CreateBinOp(Opc, L, R, Name) and CreateAdd/CreateSub/... with wrap flags (flags: F_NUW/F_NSW/F_EXACT/F_EXACT as disjoint)
icb_binop :: (opc: Opcode, l: Value_Id, r: Value_Id, name: string = "", flags: u32 = 0) -> Value_Id {
    f := tf_fold_binop(opc, l, r, flags);
    if f != NONE return f;
    i := new_inst(opc, vtype(l), 2);
    set_op(i, 0, l); set_op(i, 1, r);
    inst(i).flags = flags;
    if is_fp_math_inst(i) set_fmf(i, ic.b_fmf);
    return icb_insert(i, name);
}
icb_add :: (l: Value_Id, r: Value_Id, name: string = "", nuw := false, nsw := false) -> Value_Id {
    return icb_binop(.ADD, l, r, name, (ifx nuw then cast(u32) F_NUW else 0) | (ifx nsw then cast(u32) F_NSW else 0));
}
icb_sub :: (l: Value_Id, r: Value_Id, name: string = "", nuw := false, nsw := false) -> Value_Id {
    return icb_binop(.SUB, l, r, name, (ifx nuw then cast(u32) F_NUW else 0) | (ifx nsw then cast(u32) F_NSW else 0));
}
icb_mul :: (l: Value_Id, r: Value_Id, name: string = "", nuw := false, nsw := false) -> Value_Id {
    return icb_binop(.MUL, l, r, name, (ifx nuw then cast(u32) F_NUW else 0) | (ifx nsw then cast(u32) F_NSW else 0));
}
icb_shl :: (l: Value_Id, r: Value_Id, name: string = "", nuw := false, nsw := false) -> Value_Id {
    return icb_binop(.SHL, l, r, name, (ifx nuw then cast(u32) F_NUW else 0) | (ifx nsw then cast(u32) F_NSW else 0));
}
icb_shl_c :: (l: Value_Id, amt: u64, name: string = "") -> Value_Id { return icb_shl(l, const_int_of(vtype(l), amt), name); }
icb_lshr :: (l: Value_Id, r: Value_Id, name: string = "", exact := false) -> Value_Id { return icb_binop(.LSHR, l, r, name, ifx exact then cast(u32) F_EXACT else 0); }
icb_ashr :: (l: Value_Id, r: Value_Id, name: string = "", exact := false) -> Value_Id { return icb_binop(.ASHR, l, r, name, ifx exact then cast(u32) F_EXACT else 0); }
icb_and :: (l: Value_Id, r: Value_Id, name: string = "") -> Value_Id { return icb_binop(.AND, l, r, name); }
icb_or :: (l: Value_Id, r: Value_Id, name: string = "") -> Value_Id { return icb_binop(.OR, l, r, name); }
icb_xor :: (l: Value_Id, r: Value_Id, name: string = "") -> Value_Id { return icb_binop(.XOR, l, r, name); }
icb_disjoint_or :: (l: Value_Id, r: Value_Id, name: string = "") -> Value_Id { return icb_binop(.OR, l, r, name, F_EXACT); }
icb_udiv :: (l: Value_Id, r: Value_Id, name: string = "", exact := false) -> Value_Id { return icb_binop(.UDIV, l, r, name, ifx exact then cast(u32) F_EXACT else 0); }
icb_sdiv :: (l: Value_Id, r: Value_Id, name: string = "", exact := false) -> Value_Id { return icb_binop(.SDIV, l, r, name, ifx exact then cast(u32) F_EXACT else 0); }
icb_neg :: (v: Value_Id, name: string = "", nsw := false) -> Value_Id { return icb_sub(const_null_value(vtype(v)), v, name, false, nsw); }
icb_not :: (v: Value_Id, name: string = "") -> Value_Id { return icb_xor(v, const_all_ones_of(vtype(v)), name); }
// CreateFNeg / CreateFNegFMF
icb_fneg :: (v: Value_Id, name: string = "", fmf_src: Value_Id = NONE) -> Value_Id {
    if is_const(v) { f := cfo_unary_op_operand(.FNEG, v); if f != NONE return f; }
    i := new_inst(.FNEG, vtype(v), 1);
    set_op(i, 0, v);
    set_fmf(i, ifx fmf_src != NONE then get_fmf(fmf_src) else ic.b_fmf);
    return icb_insert(i, name);
}
// CreateBinOpFMF(Opc, L, R, FMFSource)
icb_binop_fmf :: (opc: Opcode, l: Value_Id, r: Value_Id, fmf: u32, name: string = "") -> Value_Id {
    f := tf_fold_binop(opc, l, r, 0);
    if f != NONE return f;
    i := new_inst(opc, vtype(l), 2);
    set_op(i, 0, l); set_op(i, 1, r);
    set_fmf(i, fmf);
    return icb_insert(i, name);
}

// CreateCast (FoldCast = ConstantFoldCastOperand)
icb_cast :: (opc: Opcode, v: Value_Id, dt: Type_Id, name: string = "", flags: u32 = 0) -> Value_Id {
    if vtype(v) == dt return v;
    if is_const(v) { f := cfo_cast_operand(opc, v, dt); if f != NONE return f; }
    i := new_inst(opc, dt, 1);
    set_op(i, 0, v);
    inst(i).flags = flags;
    if is_fp_math_inst(i) set_fmf(i, ic.b_fmf);
    return icb_insert(i, name);
}
icb_zext :: (v: Value_Id, dt: Type_Id, name: string = "", nneg := false) -> Value_Id { return icb_cast(.ZEXT, v, dt, name, ifx nneg then cast(u32) F_EXACT else 0); }
icb_sext :: (v: Value_Id, dt: Type_Id, name: string = "") -> Value_Id { return icb_cast(.SEXT, v, dt, name); }
icb_trunc :: (v: Value_Id, dt: Type_Id, name: string = "", nuw := false, nsw := false) -> Value_Id {
    return icb_cast(.TRUNC, v, dt, name, (ifx nuw then cast(u32) F_NUW else 0) | (ifx nsw then cast(u32) F_NSW else 0));
}
// CreateZExtOrTrunc / CreateSExtOrTrunc
icb_zext_or_trunc :: (v: Value_Id, dt: Type_Id, name: string = "") -> Value_Id {
    vb := type_bits(scalar_type(vtype(v))); db := type_bits(scalar_type(dt));
    if vb < db return icb_zext(v, dt, name);
    if vb > db return icb_trunc(v, dt, name);
    return v;
}
icb_sext_or_trunc :: (v: Value_Id, dt: Type_Id, name: string = "") -> Value_Id {
    vb := type_bits(scalar_type(vtype(v))); db := type_bits(scalar_type(dt));
    if vb < db return icb_sext(v, dt, name);
    if vb > db return icb_trunc(v, dt, name);
    return v;
}
// CreateIntCast(V, DestTy, isSigned)
icb_int_cast :: (v: Value_Id, dt: Type_Id, is_signed: bool, name: string = "") -> Value_Id {
    if vtype(v) == dt return v;
    vb := type_bits(scalar_type(vtype(v))); db := type_bits(scalar_type(dt));
    opc: Opcode = ifx vb > db then .TRUNC else ifx is_signed then .SEXT else .ZEXT;
    return icb_cast(opc, v, dt, name);
}

// CreateICmp / CreateFCmp (FoldCmp = ConstantFoldCompareInstOperands)
icb_cmp :: (pred: u8, l: Value_Id, r: Value_Id, name: string = "") -> Value_Id {
    if is_const(l) && is_const(r) { f := cfo_compare_inst_operands(pred, l, r); if f != NONE return f; }
    t := make_cmp_result_type(vtype(l));
    i := new_inst(ifx is_int_predicate(pred) then Opcode.ICMP else .FCMP, t, 2);
    set_op(i, 0, l); set_op(i, 1, r);
    inst(i).pred = pred;
    if !is_int_predicate(pred) set_fmf(i, ic.b_fmf);
    return icb_insert(i, name);
}
make_cmp_result_type :: (t: Type_Id) -> Type_Id {
    if is_vector_type(t) return type_vector(type_count(t), ir.t_i1, type_kind(t) == .SVECTOR);
    return ir.t_i1;
}
// CreateIsNull / CreateIsNotNull
icb_is_null :: (v: Value_Id, name: string = "") -> Value_Id { return icb_cmp(ICMP_EQ, v, const_null_value(vtype(v)), name); }
icb_is_not_null :: (v: Value_Id, name: string = "") -> Value_Id { return icb_cmp(ICMP_NE, v, const_null_value(vtype(v)), name); }

// CreateSelect(C, T, F, Name, MDFrom)
icb_select :: (c: Value_Id, t: Value_Id, f: Value_Id, name: string = "", md_from: Value_Id = NONE) -> Value_Id {
    if is_const(c) && is_const(t) && is_const(f) { x := cf_select(c, t, f); if x != NONE return x; }
    i := create_select(c, t, f);
    if md_from != NONE copy_prof_unpredictable(i, md_from);
    if is_fp_math_inst(i) set_fmf(i, ic.b_fmf);
    return icb_insert(i, name);
}
create_select :: (c: Value_Id, t: Value_Id, f: Value_Id) -> Value_Id {
    i := new_inst(.SELECT, vtype(t), 3);
    set_op(i, 0, c); set_op(i, 1, t); set_op(i, 2, f);
    return i;
}
copy_prof_unpredictable :: (dst: Value_Id, src: Value_Id) {
    prof := get_metadata(src, md_kind_id("prof"));
    unpred := get_metadata(src, md_kind_id("unpredictable"));
    if prof != NONE set_metadata(dst, md_kind_id("prof"), prof);
    if unpred != NONE set_metadata(dst, md_kind_id("unpredictable"), unpred);
}
// Function::getEntryCount: !prof !{!"function_entry_count" | !"synthetic_function_entry_count", i64 N}
ic_fn_entry_count :: (f: Value_Id) -> (bool, u64) {
    m := get_metadata(f, md_kind_id("prof"));
    if m == NONE || ir.mds[m].kind != .TUPLE || ir.mds[m].nops < 2 return false, 0;
    tag := md_op(m, 0);
    if tag == NONE || ir.mds[tag].kind != .STRING return false, 0;
    t := ir.mds[tag].str;
    if t != "function_entry_count" && t != "synthetic_function_entry_count" return false, 0;
    vm := md_op(m, 1);
    if vm == NONE || ir.mds[vm].kind != .VALUE || vkind(ir.mds[vm].value) != .C_INT return false, 0;
    v := const_int_zext(ir.mds[vm].value);
    if v == 0xFFFF_FFFF_FFFF_FFFF return false, 0;
    return true, v;
}
// setExplicitlyUnknownBranchWeightsIfProfiled(I, "instcombine")
ic_set_unknown_profile_if_profiled :: (i: Value_Id) {
    ok, ec := ic_fn_entry_count(ic.f);
    if !ok || ec == 0 return;
    ops: [2] Md_Id;
    ops[0] = md_string("unknown"); ops[1] = md_string("instcombine");
    set_metadata(i, md_kind_id("prof"), md_tuple(ops, false));
}
// createSelectInstWithUnknownProfile (an unlinked select)
ic_create_select_unknown_profile :: (c: Value_Id, t: Value_Id, f: Value_Id) -> Value_Id {
    s := create_select(c, t, f);
    ic_set_unknown_profile_if_profiled(s);
    return s;
}

// CreateIntrinsic(RetTy or overload types, ID, Args) / CreateBinaryIntrinsic / CreateUnaryIntrinsic
icb_intrinsic :: (id: Intrinsic_Id, otys: [] Type_Id, args: [] Value_Id, name: string = "", fmf_src: Value_Id = NONE) -> Value_Id {
    f := get_or_insert_intrinsic_declaration(id, otys);
    fty := glob(f).value_type;
    i := new_inst(.CALL, func_ret(fty), cast(u32)(args.count + 1));
    inst(i).ty2 = fty;
    inst(i).attrs = glob(f).attrs & 0;   // call-site attributes: none
    for args set_op(i, cast(u32) it_index, it);
    set_op(i, cast(u32) args.count, f);
    if is_fp_math_inst(i) set_fmf(i, ifx fmf_src != NONE then get_fmf(fmf_src) else ic.b_fmf);
    return icb_insert(i, name);
}
// CreateBinaryIntrinsic(ID, L, R): constant folds through FoldIntrinsic first
icb_binary_intrinsic :: (id: Intrinsic_Id, l: Value_Id, r: Value_Id, name: string = "", fmf_src: Value_Id = NONE) -> Value_Id {
    if is_const(l) && is_const(r) {
        x := cfo_intrinsic(id, .[l, r], vtype(l));
        if x != NONE return x;
    }
    return icb_intrinsic(id, .[vtype(l)], .[l, r], name, fmf_src);
}
icb_unary_intrinsic :: (id: Intrinsic_Id, v: Value_Id, name: string = "", fmf_src: Value_Id = NONE) -> Value_Id {
    if is_const(v) {
        x := cfo_intrinsic(id, .[v], vtype(v));
        if x != NONE return x;
    }
    return icb_intrinsic(id, .[vtype(v)], .[v], name, fmf_src);
}
// CallInst::Create(F, Args): an unlinked intrinsic call
create_intrinsic_call :: (id: Intrinsic_Id, otys: [] Type_Id, args: [] Value_Id) -> Value_Id {
    f := get_or_insert_intrinsic_declaration(id, otys);
    fty := glob(f).value_type;
    i := new_inst(.CALL, func_ret(fty), cast(u32)(args.count + 1));
    inst(i).ty2 = fty;
    for args set_op(i, cast(u32) it_index, it);
    set_op(i, cast(u32) args.count, f);
    return i;
}

// CreateShuffleVector(V1, V2, Mask) / CreateShuffleVector(V, Mask) (V2 = poison)
icb_shuffle :: (v1: Value_Id, v2_in: Value_Id, mask: [] u32, name: string = "") -> Value_Id {
    v2 := v2_in;
    if v2 == NONE v2 = const_poison(vtype(v1));
    if is_const(v1) && is_const(v2) return cfo_constant(ce_shuffle_vector(v1, v2, mask));
    return icb_insert(create_shuffle(v1, v2, mask), name);
}
create_shuffle :: (v1: Value_Id, v2_in: Value_Id, mask: [] u32) -> Value_Id {
    v2 := v2_in;
    if v2 == NONE v2 = const_poison(vtype(v1));
    vt := vtype(v1);
    rt := type_vector(cast(u64) mask.count, type_elem(vt), type_kind(vt) == .SVECTOR);
    i := new_inst(.SHUFFLEVECTOR, rt, 2);
    set_op(i, 0, v1); set_op(i, 1, v2);
    // `mask` may be a view into ir.u32_pool (another shuffle's mask): copy it before the pool can grow
    m := NewArray(mask.count, u32,, allocator = temp);
    for mask m[it_index] = it;
    r := inst(i);
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) m.count;
    for m array_add(*ir.u32_pool, it);
    return i;
}
icb_extract_element :: (v: Value_Id, idx: Value_Id, name: string = "") -> Value_Id {
    if is_const(v) && is_const(idx) return cfo_constant(ce_extract_element(v, idx));
    i := new_inst(.EXTRACTELEMENT, type_elem(vtype(v)), 2);
    set_op(i, 0, v); set_op(i, 1, idx);
    return icb_insert(i, name);
}
icb_insert_element :: (v: Value_Id, e: Value_Id, idx: Value_Id, name: string = "") -> Value_Id {
    if is_const(v) && is_const(e) && is_const(idx) return cfo_constant(ce_insert_element(v, e, idx));
    i := new_inst(.INSERTELEMENT, vtype(v), 3);
    set_op(i, 0, v); set_op(i, 1, e); set_op(i, 2, idx);
    return icb_insert(i, name);
}

// BinaryOperator::Create(Opc, L, R) (unlinked), with flags
create_binop_flags :: (opc: Opcode, l: Value_Id, r: Value_Id, flags: u32 = 0) -> Value_Id {
    i := create_binop(opc, l, r);
    inst(i).flags = flags;
    return i;
}
create_neg :: (v: Value_Id) -> Value_Id { return create_binop(.SUB, const_null_value(vtype(v)), v); }
create_not :: (v: Value_Id) -> Value_Id { return create_binop(.XOR, v, const_all_ones_of(vtype(v))); }
// BinaryOperator::CreateFNegFMF / UnaryOperator::CreateFNegFMF
create_fneg_fmf :: (v: Value_Id, fmf_src: Value_Id) -> Value_Id {
    i := new_inst(.FNEG, vtype(v), 1);
    set_op(i, 0, v);
    set_fmf(i, get_fmf(fmf_src));
    return i;
}
create_binop_fmf :: (opc: Opcode, l: Value_Id, r: Value_Id, fmf: u32) -> Value_Id {
    i := create_binop(opc, l, r);
    set_fmf(i, fmf);
    return i;
}
create_cast_flags :: (opc: Opcode, v: Value_Id, t: Type_Id, flags: u32 = 0) -> Value_Id {
    i := create_cast(opc, v, t);
    inst(i).flags = flags;
    return i;
}
create_icmp :: (pred: u8, l: Value_Id, r: Value_Id) -> Value_Id {
    i := new_inst(.ICMP, make_cmp_result_type(vtype(l)), 2);
    set_op(i, 0, l); set_op(i, 1, r);
    inst(i).pred = pred;
    return i;
}
create_fcmp :: (pred: u8, l: Value_Id, r: Value_Id, fmf: u32 = 0) -> Value_Id {
    i := new_inst(.FCMP, make_cmp_result_type(vtype(l)), 2);
    set_op(i, 0, l); set_op(i, 1, r);
    inst(i).pred = pred;
    set_fmf(i, fmf);
    return i;
}

// ---------------------------------------------------------------- the driver

// tryToSinkInstruction
ic_try_to_sink :: (i: Value_Id, dest: Value_Id) -> bool {
    src_block := inst_block(i);
    o := inst_op(i);
    if o == .PHI || is_eh_pad(i) || may_throw(i) || !will_return(i) || is_terminator(o) return false;
    if o == .ALLOCA return false;
    if inst_op(block_terminator(dest)) == .CATCHSWITCH return false;
    if o == .CALL && call_has_fn_attr(i, .Convergent) return false;
    if o == .CALL && fn_has_fn_attr(ic.f, .Convergent) && false return false;
    if may_write_to_memory(i) && !sole_write_to_dead_local(i) return false;
    if may_read_from_memory(i) && get_metadata(i, md_kind_id("invariant.load")) == NONE {
        if block_unique_predecessor(dest) != src_block return false;
        s := inst(i).next;
        while s != NONE {
            if may_write_to_memory(s) && !is_intrinsic_call(s, IID_ASSUME) return false;
            s = inst(s).next;
        }
    }
    // dropDroppableUses for users outside DestBlock
    u := ir.v_first_use[i];
    while u != NONE {
        nu := ir.u_next[u];
        user := ir.u_user[u];
        if is_droppable_user(user) && inst_block(user) != dest {
            wl_add(user);
            drop_droppable_use(u);
        }
        u = nu;
    }
    pos := block_first_insertion_pt(dest);
    ic_move_inst(i, dest, pos, true);
    users: [..] u32; users.allocator = temp;
    find_dbg_users(ic.f, i, *users);
    if users.count ic_try_to_sink_inst_dbg_variable_records(i, pos, src_block, dest, users);
    return true;
}

// tryToSinkInstructionDbgVariableRecords
ic_try_to_sink_inst_dbg_variable_records :: (i: Value_Id, pos: Value_Id, src_block: Value_Id, dest: Value_Id, users: [] u32) {
    to_salvage: [..] u32; to_salvage.allocator = temp;
    for users if inst_block(dbgr(it).owner) != dest array_add(*to_salvage, it);
    to_sink: [..] u32; to_sink.allocator = temp;
    for to_salvage if inst_block(dbgr(it).owner) == src_block array_add(*to_sink, it);
    // stable_sort by Order(A, B) = B's instruction comes before A's (later instructions first)
    for k: 1..to_sink.count-1 {
        x := to_sink[k];
        j := k - 1;
        while j >= 0 && dbgr(to_sink[j]).owner != dbgr(x).owner && comes_before(dbgr(to_sink[j]).owner, dbgr(x).owner) {
            to_sink[j + 1] = to_sink[j]; j -= 1;
        }
        to_sink[j + 1] = x;
    }
    // DebugVariable(Var, fragment of Expr, InlinedAt)
    Dbg_Var_Key :: struct { var: Md_Id; has_frag: bool; foff: u64; fsize: u64; inlined: Md_Id; }
    key_of :: (r: u32) -> Dbg_Var_Key {
        k: Dbg_Var_Key;
        k.var = dbgr(r).var;
        k.has_frag, k.foff, k.fsize = diexpr_fragment(dbgr(r).expr);
        if !k.has_frag { k.foff = 0; k.fsize = 0; }
        k.inlined = diloc_inlined_at(dbgr(r).dbg);
        return k;
    }
    same :: (a: Dbg_Var_Key, b: Dbg_Var_Key) -> bool {
        return a.var == b.var && a.has_frag == b.has_frag && a.foff == b.foff && a.fsize == b.fsize && a.inlined == b.inlined;
    }
    // FilterOutMap: (instruction, variable) pairs with several assignments -> the last one on that instruction
    Filter :: struct { owner: Value_Id; key: Dbg_Var_Key; last: u32; }
    filters: [..] Filter; filters.allocator = temp;
    if to_sink.count > 1 {
        for a, ai: to_sink {
            ka := key_of(a);
            count := 0;
            for b: to_sink if dbgr(b).owner == dbgr(a).owner && same(key_of(b), ka) count += 1;
            if count <= 1 continue;
            dup := false;
            for filters if it.owner == dbgr(a).owner && same(it.key, ka) { dup = true; break; }
            if dup continue;
            // the last record of that variable attached to the instruction (all records, reverse order)
            last: u32 = 0;
            x := inst(dbgr(a).owner).records;
            while x != 0 {
                if dbgr(x).kind != .LABEL && same(key_of(x), ka) last = x;
                x = dbgr(x).next;
            }
            array_add(*filters, .{dbgr(a).owner, ka, last});
        }
    }
    clones: [..] u32; clones.allocator = temp;
    sunk: [..] Dbg_Var_Key; sunk.allocator = temp;
    for r: to_sink {
        if dbgr(r).kind == .DECLARE continue;
        k := key_of(r);
        filtered := false;
        for filters if it.owner == dbgr(r).owner && same(it.key, k) && it.last != r { filtered = true; break; }
        if filtered continue;
        seen := false;
        for sunk if same(it, k) { seen = true; break; }
        if seen continue;
        array_add(*sunk, k);
        if dbgr(r).kind == .ASSIGN continue;
        c := dbgr(r).*;
        c.next = 0; c.owner = NONE;
        array_add(*ir.dbg_records, c);
        array_add(*clones, cast(u32) ir.dbg_records.count);
    }
    if clones.count == 0 return;
    salvage_debug_info_for_dbg_values(i, to_salvage);
    if pos == NONE fatal("instcombine: sinking debug records to the end of a block is not supported yet");
    for c: clones {
        dbgr(c).owner = pos;
        dbgr(c).next = inst(pos).records;
        inst(pos).records = c;
        dbgr_restamp(c);
        if dbg_index.fn != NONE dbgr_index_record(c);
    }
}
// Instruction::moveBefore(BB, It): the moved instruction's debug records stay behind (on the next instruction)
ic_move_inst :: (i: Value_Id, bb: Value_Id, pos: Value_Id, head: bool) {
    if inst(i).records {
        nx := inst(i).next;
        if nx == NONE fatal("instcombine: moving an instruction with trailing debug records is not supported yet");
        first := inst(i).records;
        x := first;
        ir.dbg_records[x - 1].owner = nx;
        while ir.dbg_records[x - 1].next != 0 { x = ir.dbg_records[x - 1].next; ir.dbg_records[x - 1].owner = nx; }
        ir.dbg_records[x - 1].next = inst(nx).records;
        inst(nx).records = first;
        inst(i).records = 0;
    }
    inst_unlink(i);
    insert_at_position(i, bb, pos, head);
}
block_unique_predecessor :: (b: Value_Id) -> Value_Id {
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(b, *preds);
    if preds.count == 0 return NONE;
    p := preds[0];
    for preds if it != p return NONE;
    return p;
}
// SoleWriteToDeadLocal
sole_write_to_dead_local :: (i: Value_Id) -> bool {
    if !is_call_base(i) return false;
    ok, loc := mloc_for_dest_call(i);
    if !ok return false;
    ai := get_underlying_object(loc.ptr);
    if !is_inst(ai) || inst_op(ai) != .ALLOCA return false;
    stack: [..] Value_Id; stack.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    push_users :: (v: Value_Id, stack: *[..] Value_Id, visited: *Table(Value_Id, bool)) {
        u := ir.v_first_use[v];
        while u != NONE {
            us := ir.u_user[u];
            if !table_contains(visited, us) { table_set(visited, us, true); array_add(stack, us); }
            u = ir.u_next[u];
        }
    }
    push_users(ai, *stack, *visited);
    while stack.count {
        ui := pop(*stack);
        if inst_op(ui) == .GEP || inst_op(ui) == .ADDRSPACECAST { push_users(ui, *stack, *visited); continue; }
        if ui == i continue;
        return false;
    }
    return true;
}

// getOptionalSinkBlockForInst
ic_sink_block :: (i: Value_Id) -> Value_Id {
    bb := inst_block(i);
    user_parent: Value_Id = NONE;
    num_users := 0;
    u := ir.v_first_use[i];
    while u != NONE {
        defer u = ir.u_next[u];
        user := ir.u_user[u];
        if is_droppable_user(user) {
            if !is_intrinsic_call(user, IID_ASSUME) || !call_has_bundle(user, "dereferenceable") continue;
        }
        if num_users > opts.instcombine_max_sink_users return NONE;
        user_bb := inst_block(user);
        if inst_op(user) == .PHI user_bb = ir.u_aux[u];
        if user_parent != NONE && user_parent != user_bb return NONE;
        user_parent = user_bb;
        if num_users == 0 {
            if user_parent == bb || !dt_is_reachable_from_entry(ic.dt, user_parent) return NONE;
            term := block_terminator(user_parent);
            if block_unique_predecessor(user_parent) != bb && num_successors(term) != 0 return NONE;
        }
        num_users += 1;
    }
    return user_parent;
}
call_has_bundle :: (i: Value_Id, tag: string) -> bool {
    nb := call_num_bundles(i);
    if nb > 0 for k: 0..nb-1 if call_bundle_tag(i, k) == tag return true;
    return false;
}

// InstCombinerImpl::run
ic_run_worklist :: () -> bool {
    while !wl_is_empty() {
        while true {
            i := wl_pop_deferred();
            if i == NONE break;
            if vkind(i) == .DEAD continue;
            if is_instruction_trivially_dead(i) { ic_erase_inst(i); continue; }
            wl_push(i);
        }
        i := wl_remove_one();
        if i == NONE continue;
        if vkind(i) == .DEAD continue;
        if is_instruction_trivially_dead(i) { ic_erase_inst(i); continue; }

        sink_bb: Value_Id = NONE;
        if opts.instcombine_code_sinking sink_bb = ic_sink_block(i);
        if sink_bb != NONE {
            if ic_try_to_sink(i, sink_bb) {
                ic.made_ir_change = true;
                for k: 0..cast(s64) nops(i) - 1 { o := op(i, cast(u32) k); if is_inst(o) wl_push(o); }
            }
        }

        icb_set_insert_point(i);
        ic.b_fmf = 0;
        ic.annotation_src = i;

        result := ic_visit(i);
        if result == NONE continue;
        if result != i {
            if get_metadata(result, 0) == NONE { d := get_metadata(i, 0); if d != NONE set_metadata(result, 0, d); }
            ann := md_kind_id("annotation");
            if get_metadata(i, ann) != NONE fatal("instcombine: !annotation metadata is not supported yet");
            rauw_with_metadata(i, result);
            ic_take_name(result, i);
            parent := inst_block(i);
            pos := i;
            head := false;   // getFirstInsertionPt / getFirstNonPHIIt return iterators with the head bit set
            if (inst_op(result) == .PHI) != (inst_op(i) == .PHI) {
                if inst_op(i) == .PHI pos = block_first_insertion_pt(parent);
                else pos = block_first_non_phi(parent);
                head = true;
            }
            if pos == NONE ic_link_at_end(result, parent);
            else ic_link_before(result, pos, head);
            if is_intrinsic_call(result, IID_ASSUME) ic_register_assumption(result);
            wl_push_users(result);
            wl_push(result);
            ic_erase_inst(i);
        } else {
            if is_instruction_trivially_dead(i) ic_erase_inst(i);
            else { wl_push_users(i); wl_push(i); }
        }
        ic.made_ir_change = true;
    }
    table_reset(*ic.wl.map);
    return ic.made_ir_change;
}

// removeAllNonTerminatorAndEHPadInstructions (llvm/lib/Transforms/Utils/Local.cpp); returns the number deleted
remove_all_non_terminator_and_eh_pad_instructions :: (bb: Value_Id) -> int {
    n := 0;
    end := block_terminator(bb);
    // handleUnreachableTerminator
    drop_dbg_records(end);
    for k: 0..cast(s64) nops(end) - 1 {
        o := op(end, cast(u32) k);
        if is_inst(o) && type_kind(vtype(o)) != .TOKEN set_op(end, cast(u32) k, const_poison(vtype(o)));
    }
    while end != block_first(bb) {
        x := inst(end).prev;
        if has_uses(x) && type_kind(vtype(x)) != .TOKEN rauw_with_metadata(x, const_poison(vtype(x)));
        if is_eh_pad(x) || type_kind(vtype(x)) == .TOKEN { drop_dbg_records(x); end = x; continue; }
        n += 1;
        drop_dbg_records(x);
        erase_inst_with_metadata(x);
    }
    return n;
}
// Instruction::dropDbgRecords
drop_dbg_records :: (i: Value_Id) {
    while inst(i).records { dbgr_erase(inst(i).records); }
}

// isDebugOrPseudoInst
is_debug_or_pseudo_inst :: (i: Value_Id) -> bool {
    if inst_op(i) != .CALL return false;
    id := intrinsic_id_of_call(i);
    return begins_with(id, "llvm.dbg.") || id == "llvm.pseudoprobe";
}

// AliasScopeTracker
Alias_Scope_Tracker :: struct {
    used_alias: Table(Md_Id, bool);
    used_noalias: Table(Md_Id, bool);
}
ast_analyse :: (t: *Alias_Scope_Tracker, i: Value_Id) {
    track :: (m: Md_Id, c: *Table(Md_Id, bool)) {
        if m == NONE || ir.mds[m].kind == .STRING || ir.mds[m].kind == .VALUE return;
        if table_contains(c, m) return;
        table_set(c, m, true);
        n := ir.mds[m].nops;
        for k: 0..cast(s64) n - 1 {
            x := md_op(m, cast(u32) k);
            if x != NONE && ir.mds[x].kind != .STRING && ir.mds[x].kind != .VALUE table_set(c, x, true);
        }
    }
    track(get_metadata(i, md_kind_id("alias.scope")), *t.used_alias);
    track(get_metadata(i, md_kind_id("noalias")), *t.used_noalias);
}
ast_is_noalias_scope_decl_dead :: (t: *Alias_Scope_Tracker, i: Value_Id) -> bool {
    if !is_intrinsic_call(i, IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL) return false;
    mv := op(i, 0);
    if vkind(mv) != .MD_VALUE return true;
    msl := cast(Md_Id) ir.v_aux[mv];
    if ir.mds[msl].nops == 0 return true;
    m := md_op(msl, 0);
    if m == NONE || ir.mds[m].kind == .STRING || ir.mds[m].kind == .VALUE return true;
    return !table_contains(*t.used_alias, m) || !table_contains(*t.used_noalias, m);
}

// prepareWorklist
ic_prepare_worklist :: () -> bool {
    made := false;
    live: Table(Value_Id, bool); live.allocator = temp;
    for_wl: [..] Value_Id; for_wl.allocator = temp;
    folded: Table(Value_Id, Value_Id); folded.allocator = temp;
    scopes: Alias_Scope_Tracker; scopes.used_alias.allocator = temp; scopes.used_noalias.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;

    handle_only_live_successor :: (bb: Value_Id, live_succ: Value_Id, made: *bool, succs: *[..] Value_Id) {
        succs.count = 0;
        block_successors(bb, succs);
        for s: succs.* {
            if s == live_succ continue;
            key := edge_key(bb, s);
            if table_contains(*ic.dead_edges, key) continue;
            table_set(*ic.dead_edges, key, true);
            for p: block_insts(s) {
                if inst_op(p) != .PHI break;
                n := nops(p);
                for k: 0..cast(s64) n - 1 {
                    if phi_block(p, cast(u32) k) == bb && !pm_poison(op(p, cast(u32) k)) {
                        set_op(p, cast(u32) k, const_poison(vtype(p)));
                        made.* = true;
                    }
                }
            }
        }
    }

    entry := fn_entry(ic.f);
    for bb: ic.rpot {
        if bb != entry {
            preds.count = 0;
            block_predecessors(bb, *preds);
            all_dead := true;
            for p: preds if !(table_contains(*ic.dead_edges, edge_key(p, bb)) || dt_dominates(ic.dt, bb, p)) { all_dead = false; break; }
            if all_dead { handle_only_live_successor(bb, NONE, *made, *succs); continue; }
        }
        table_set(*live, bb, true);

        for :early_inc i: block_insts(bb) {
            if has_uses(i) && (nops(i) == 0 || is_const(op(i, 0))) {
                c := cfo_instruction(i);
                if c != NONE {
                    rauw_with_metadata(i, c);
                    if is_instruction_trivially_dead(i) erase_inst_with_metadata(i);
                    made = true;
                    continue;
                }
            }
            n := nops(i);
            for k: 0..cast(s64) n - 1 {
                c := op(i, cast(u32) k);
                if c == NONE continue;
                ck := vkind(c);
                if ck != .C_VECTOR && ck != .C_EXPR continue;
                found, fr := table_find(*folded, c);
                if !found { fr = cfo_constant(c); table_set(*folded, c, fr); }
                if fr != c { set_op(i, cast(u32) k, fr); made = true; }
            }
            if !is_debug_or_pseudo_inst(i) {
                array_add(*for_wl, i);
                ast_analyse(*scopes, i);
            }
        }

        ti := block_terminator(bb);
        if inst_op(ti) == .CONDBR {
            c := op(ti, 0);
            if pm_undef_value(c) { handle_only_live_successor(bb, NONE, *made, *succs); continue; }
            if vkind(c) == .C_INT {
                cv := !ap_is_zero(const_ap(c));
                handle_only_live_successor(bb, get_successor(ti, ifx cv then cast(u32) 0 else 1), *made, *succs);
                continue;
            }
        } else if inst_op(ti) == .SWITCH {
            c := op(ti, 0);
            if pm_undef_value(c) { handle_only_live_successor(bb, NONE, *made, *succs); continue; }
            if vkind(c) == .C_INT {
                handle_only_live_successor(bb, switch_find_case_dest(ti, c), *made, *succs);
                continue;
            }
        }
    }

    for bb: fn_blocks(ic.f) {
        if table_contains(*live, bb) continue;
        nd := remove_all_non_terminator_and_eh_pad_instructions(bb);
        if nd != 0 made = true;
    }

    for < k: 0..for_wl.count-1 {
        i := for_wl[k];
        if is_instruction_trivially_dead(i) || ast_is_noalias_scope_decl_dead(*scopes, i) {
            salvage_debug_info(i);
            erase_inst_with_metadata(i);
            made = true;
            continue;
        }
        wl_push(i);
    }
    return made;
}
// SwitchInst::findCaseValue(C)->getCaseSuccessor(): operands [cond, default, dest...], case values in u_aux
switch_find_case_dest :: (sw: Value_Id, c: Value_Id) -> Value_Id {
    n := nops(sw);
    k: u32 = 2;
    while k < n {
        if ir.u_aux[ir.v_ops[sw] + k] == c return op(sw, k);
        k += 1;
    }
    return op(sw, 1);
}

// combineInstructionsOverFunction
ic_combine_function :: (f: Value_Id, icopts: Ic_Options) -> bool {
    verify := icopts.verify_fixpoint && !fn_has_str_attr(f, "instcombine-no-verify-fixpoint");
    rpo: [..] Value_Id; rpo.allocator = temp;
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(f), *po);
    for < k: 0..po.count-1 array_add(*rpo, po[k]);
    made := false;
    // LowerDbgDeclare (-instcombine-lower-dbg-declare)
    if opts.instcombine_lower_dbg_declare made = lower_dbg_declare(f);
    iteration: u32 = 0;
    dt := get_domtree(f);
    ac := get_assumption_cache(f);
    while true {
        if iteration >= icopts.max_iterations && !verify break;
        iteration += 1;
        // a fresh InstCombinerImpl per iteration
        ic = .{};
        ic.f = f; ic.dt = dt; ic.ac = ac;
        ic.wl.list.allocator = temp; ic.wl.map.allocator = temp; ic.wl.deferred.allocator = temp; ic.wl.deferred_set.allocator = temp;
        ic.dc.affected.allocator = temp;
        ic.dead_edges.allocator = temp; ic.back_edges.allocator = temp; ic.pred_order.allocator = temp;
        ic.rpot = rpo;
        ic.min_size = fn_has_fn_attr(f, .MinSize);
        ic.max_array_size = cast(u64) opts.instcombine_maxarray_size;
        ic.sq.dt = dt; ic.sq.ac = ac; ic.sq.dc = *ic.dc;
        changed := ic_prepare_worklist();
        changed |= ic_run_worklist();
        if !changed break;
        made = true;
        if iteration > icopts.max_iterations
            fatal("Instruction Combining on % did not reach a fixpoint after % iterations. Use 'instcombine<no-verify-fixpoint>' or function attribute 'instcombine-no-verify-fixpoint' to suppress this error.", vname(f), icopts.max_iterations);
    }
    return made;
}

// InstCombinePass::run with the parameters of `instcombine<...>` (PassBuilder parseInstCombineOptions)
instcombine_run :: (f: Value_Id, name: string) -> Preserved {
    icopts: Ic_Options;
    if name != "instcombine" {
        if !begins_with(name, "instcombine<") || name[name.count - 1] != #char ">" fatal("invalid pass name '%'", name);
        params := slice(name, 12, name.count - 13);
        for p: split(params, ";") {
            if p == "" continue;
            if p == "verify-fixpoint" { icopts.verify_fixpoint = true; continue; }
            if p == "no-verify-fixpoint" { icopts.verify_fixpoint = false; continue; }
            if begins_with(p, "max-iterations=") {
                v, ok := string_to_int(slice(p, 15, p.count - 15));
                if !ok fatal("invalid argument to InstCombine pass max-iterations parameter: '%'", p);
                icopts.max_iterations = cast(u32) v;
                continue;
            }
            fatal("invalid InstCombine pass parameter '%'", p);
        }
    }
    if !ic_combine_function(f, icopts) return PRESERVE_ALL;
    return preserved_cfg();
}
