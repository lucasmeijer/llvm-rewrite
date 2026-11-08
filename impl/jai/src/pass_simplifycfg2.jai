// SimplifyCFG.cpp, second part: hoisting, sinking, speculation, threading, two-entry phi folding,
// FoldBranchToCommonDest (see pass_simplifycfg.jai for the file map).

// ---------------------------------------------------------------- Instruction.cpp comparisons

// the bits of Inst_Row.flags that are SubclassOptionalData (poison-generating flags, fast-math flags)
OPTIONAL_FLAG_MASK :: cast(u32) (F_NUW | F_NSW | F_EXACT | F_INBOUNDS | F_NUSW | F_GEP_NUW) | (cast(u32) FMF_ALL << FMF_SHIFT);

// Instruction::hasSameSpecialState(I2, IgnoreAlignment, IntersectAttrs)
has_same_special_state :: (a: Value_Id, b: Value_Id, ignore_alignment: bool, intersect_attrs: bool) -> bool {
    ra := inst(a); rb := inst(b);
    attrs_same :: (a: Value_Id, b: Value_Id, intersect: bool) -> bool {
        if inst(a).attrs == inst(b).attrs return true;
        if !intersect return false;
        ok, _ := attr_list_intersect(inst(a).attrs, inst(b).attrs);
        return ok;
    }
    al := ignore_alignment || ra.align == rb.align;
    vol :: (r: *Inst_Row) -> bool { return (r.flags & F_VOLATILE) != 0; }
    tail :: (r: *Inst_Row) -> bool { k := (r.flags >> TAIL_SHIFT) & 3; return k == 1 || k == 2; }
    if ra.op == {
        case .ALLOCA; return ra.ty2 == rb.ty2 && al;
        case .LOAD; #through;
        case .STORE; return vol(ra) == vol(rb) && al && ra.ord1 == rb.ord1 && ra.sync == rb.sync;
        case .ICMP; #through;
        case .FCMP; return ra.pred == rb.pred;
        case .CALL;
            return tail(ra) == tail(rb) && ra.cc == rb.cc && attrs_same(a, b, intersect_attrs) && same_bundle_schema(a, b);
        case .INVOKE; #through;
        case .CALLBR;
            return ra.cc == rb.cc && attrs_same(a, b, intersect_attrs) && same_bundle_schema(a, b);
        case .SWITCH;
            n := min(sw_num_cases(a), sw_num_cases(b));
            for k: 0..cast(s64) n - 1 if sw_case_value(a, cast(u32) k) != sw_case_value(b, cast(u32) k) return false;
            return true;
        case .INSERTVALUE; #through;
        case .EXTRACTVALUE; #through;
        case .SHUFFLEVECTOR;
            if ra.nidx != rb.nidx return false;
            for k: 0..cast(s64) ra.nidx - 1 if ir.u32_pool[ra.idx + cast(u32) k] != ir.u32_pool[rb.idx + cast(u32) k] return false;
            return true;
        case .FENCE; return ra.ord1 == rb.ord1 && ra.sync == rb.sync;
        case .CMPXCHG;
            return vol(ra) == vol(rb) && al && (ra.flags & F_WEAK) == (rb.flags & F_WEAK) && ra.ord1 == rb.ord1 && ra.ord2 == rb.ord2 && ra.sync == rb.sync;
        case .ATOMICRMW;
            return ra.ord2 == rb.ord2 && (ra.flags & F_ELEMENTWISE) == (rb.flags & F_ELEMENTWISE) && vol(ra) == vol(rb) && al && ra.ord1 == rb.ord1 && ra.sync == rb.sync;
        case .GEP; return ra.ty2 == rb.ty2;
    }
    return true;
}
// CallBase::hasIdenticalOperandBundleSchema: the bundle descriptors (tags and operand ranges) match
same_bundle_schema :: (a: Value_Id, b: Value_Id) -> bool {
    na := call_num_bundles(a); nb := call_num_bundles(b);
    if na != nb return false;
    if na == 0 return true;
    ra := inst(a); rb := inst(b);
    if ra.nidx != rb.nidx return false;
    for k: 0..cast(s64) ra.nidx - 1 if ir.u32_pool[ra.idx + cast(u32) k] != ir.u32_pool[rb.idx + cast(u32) k] return false;
    return true;
}
// Instruction::isIdenticalToWhenDefined(I, IntersectAttrs)
inst_identical_when_defined :: (a: Value_Id, b: Value_Id, intersect_attrs := false) -> bool {
    if inst_op(a) != inst_op(b) || nops(a) != nops(b) || vtype(a) != vtype(b) return false;
    for k: 0..cast(s64) nops(a) - 1 if op(a, cast(u32) k) != op(b, cast(u32) k) return false;
    if inst_op(a) == .PHI {
        for k: 0..cast(s64) nops(a) - 1 if phi_block(a, cast(u32) k) != phi_block(b, cast(u32) k) return false;
        return true;
    }
    return has_same_special_state(a, b, false, intersect_attrs);
}
// Instruction::isSameOperationAs(I, flags)
is_same_operation_as :: (a: Value_Id, b: Value_Id, ignore_alignment := false, use_scalar_types := false, intersect_attrs := false) -> bool {
    if inst_op(a) != inst_op(b) || nops(a) != nops(b) return false;
    ta := vtype(a); tb := vtype(b);
    if use_scalar_types { ta = scalar_type(ta); tb = scalar_type(tb); }
    if ta != tb return false;
    for k: 0..cast(s64) nops(a) - 1 {
        x := vtype(op(a, cast(u32) k)); y := vtype(op(b, cast(u32) k));
        if use_scalar_types { x = scalar_type(x); y = scalar_type(y); }
        if x != y return false;
    }
    return has_same_special_state(a, b, ignore_alignment, intersect_attrs);
}
// Instruction::isCommutative
inst_is_commutative :: (i: Value_Id) -> bool {
    id := call_iid(i);
    if id != NOT_INTRINSIC {
        n := iid_name(id);
        for string.["llvm.maxnum", "llvm.minnum", "llvm.maximum", "llvm.minimum", "llvm.maximumnum", "llvm.minimumnum",
                    "llvm.smax", "llvm.smin", "llvm.umax", "llvm.umin", "llvm.sadd.sat", "llvm.uadd.sat",
                    "llvm.sadd.with.overflow", "llvm.uadd.with.overflow", "llvm.smul.with.overflow",
                    "llvm.umul.with.overflow", "llvm.smul.fix", "llvm.umul.fix", "llvm.smul.fix.sat",
                    "llvm.umul.fix.sat", "llvm.fma", "llvm.fmuladd"] if n == it return true;
        return false;
    }
    return is_commutative_op(inst_op(i));
}
// CallBase::tryIntersectAttributes
try_intersect_attributes :: (a: Value_Id, b: Value_Id) {
    ok, l := attr_list_intersect(inst(a).attrs, inst(b).attrs);
    if ok inst(a).attrs = l;
}
// MMRAMetadata(I1) != MMRAMetadata(I2)
mmra_differ :: (a: Value_Id, b: Value_Id) -> bool {
    k := md_kind("mmra");
    ma := get_metadata(a, k); mb := get_metadata(b, k);
    return !mmra_equal(ma, mb);
}
// Instruction::applyMergedLocation(A, B)
apply_merged_location :: (i: Value_Id, a: Md_Id, b: Md_Id) { set_metadata(i, 0, merged_location(a, b)); }

// ---------------------------------------------------------------- hoisting

// isSafeToHoistInvoke
is_safe_to_hoist_invoke :: (bb1: Value_Id, bb2: Value_Id, i1: Value_Id, i2: Value_Id) -> bool {
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb1, *succs);
    for s: succs for pn: block_insts(s) {
        if inst_op(pn) != .PHI break;
        v1 := phi_incoming_value_for_block(pn, bb1);
        v2 := phi_incoming_value_for_block(pn, bb2);
        if v1 != v2 && (v1 == i1 || v2 == i2) return false;
    }
    return true;
}
SKIP_READ_MEM :: 1; SKIP_SIDE_EFFECT :: 2; SKIP_IMPLICIT_CONTROL_FLOW :: 4;
skipped_instr_flags :: (i: Value_Id) -> u32 {
    if is_pseudo_probe(i) return 0;
    f: u32 = 0;
    if may_read_from_memory(i) f |= SKIP_READ_MEM;
    if may_have_side_effects(i) || inst_op(i) == .ALLOCA f |= SKIP_SIDE_EFFECT;
    if !is_guaranteed_to_transfer_execution(i) f |= SKIP_IMPLICIT_CONTROL_FLOW;
    return f;
}
is_safe_to_hoist_instr :: (i: Value_Id, flags: u32) -> bool {
    if (flags & SKIP_READ_MEM) && may_write_to_memory(i) return false;
    if (flags & SKIP_SIDE_EFFECT) && (may_read_from_memory(i) || may_have_side_effects(i) || inst_op(i) == .ALLOCA) return false;
    if (flags & SKIP_IMPLICIT_CONTROL_FLOW) && !is_safe_to_speculatively_execute_cx(i, NONE, null) return false;
    if is_call_base(i) && call_iid(i) != NOT_INTRINSIC && iid_name(call_iid(i)) == "llvm.experimental.deoptimize" return false;
    bb := inst_block(i);
    for k: 0..cast(s64) nops(i) - 1 { o := op(i, cast(u32) k); if is_inst(o) && inst_block(o) == bb return false; }
    return true;
}
should_hoist_common_instructions :: (s: *Scfg, i1: Value_Id, i2: Value_Id) -> bool {
    if inst_op(i1) == .CALL && inst_op(i2) == .CALL && call_is_must_tail(i1) != call_is_must_tail(i2) return false;
    if !tti_is_profitable_to_hoist(s.tti, i1) || !tti_is_profitable_to_hoist(s.tti, i2) return false;
    if is_call_base(i1) && (call_cannot_merge(i1) || call_is_convergent(i1)) return false;
    if is_call_base(i2) && (call_cannot_merge(i2) || call_is_convergent(i2)) return false;
    return true;
}
// DbgRecord::isIdenticalToWhenDefined (the debug location is not compared)
dbgr_identical :: (a: u32, b: u32) -> bool {
    ra := dbgr(a); rb := dbgr(b);
    // ValueAsMetadata is unique per value in LLVM; here two rows can denote the same value after a RAUW
    same_md :: (x: Md_Id, y: Md_Id) -> bool {
        if x == y return true;
        if x == NONE || y == NONE return false;
        return ir.mds[x].kind == .VALUE && ir.mds[y].kind == .VALUE && ir.mds[x].value == ir.mds[y].value;
    }
    return ra.kind == rb.kind && same_md(ra.loc, rb.loc) && ra.var == rb.var && ra.expr == rb.expr &&
           ra.assign_id == rb.assign_id && same_md(ra.addr, rb.addr) && ra.addr_expr == rb.addr_expr;
}
// hoistLockstepIdenticalDbgVariableRecords
hoist_lockstep_identical_dbg_records :: (ti: Value_Id, i1: Value_Id, others: [] Value_Id) {
    if inst(i1).records == 0 return;
    its: [..] u32; its.allocator = temp;
    array_add(*its, inst(i1).records);
    for others { if inst(it).records == 0 return; array_add(*its, inst(it).records); }
    while true {
        for its if it == 0 return;
        same := true;
        for k: 1..its.count-1 if !dbgr_identical(its[0], its[k]) same = false;
        for *its {
            r := it.*;
            it.* = dbgr(r).next;
            if same { dbgr_erase(r); attach_records_before(ti, r); }
        }
    }
}
// areIdenticalUpToCommutativity
are_identical_up_to_commutativity :: (a: Value_Id, b: Value_Id) -> bool {
    if inst_identical_when_defined(a, b, true) return true;
    oa := inst_op(a); ob := inst_op(b);
    if (oa == .ICMP || oa == .FCMP) && (ob == .ICMP || ob == .FCMP)
        return oa == ob && inst(a).pred == cmp_swapped(inst(b).pred) && op(a, 0) == op(b, 1) && op(a, 1) == op(b, 0);
    if inst_is_commutative(a) && is_same_operation_as(a, b) {
        if op(a, 0) != op(b, 1) || op(a, 1) != op(b, 0) return false;
        for k: 2..cast(s64) nops(a) - 1 if op(a, cast(u32) k) != op(b, cast(u32) k) return false;
        return true;
    }
    return false;
}

// hoistCommonCodeFromSuccessors
hoist_common_code_from_successors :: (s: *Scfg, ti: Value_Id, all_insts_eq_only: bool) -> bool {
    bb := inst_block(ti);
    if block_num_successors(bb) < 2 return false;
    uniq := unique_successors(bb);
    for succ: uniq {
        if block_has_address_taken(succ) return false;
        if block_unique_predecessor(succ) != NONE continue;
        if inst_op(block_first(succ)) == .UNREACHABLE continue;
        return false;
    }
    Pair :: struct { i: Value_Id; flags: u32; }
    pairs: [..] Pair; pairs.allocator = temp;
    for succ: uniq {
        f := block_first(succ);
        if inst_op(f) == .PHI return false;
        array_add(*pairs, .{f, 0});
    }
    if all_insts_eq_only {
        size0 := block_size(uniq[0]);
        term0 := block_terminator(uniq[0]);
        for k: 1..uniq.count-1 {
            if !is_identical_to(block_terminator(uniq[k]), term0) || block_size(uniq[k]) != size0 return false;
        }
        // LockstepReverseIterator over the unique successors
        cur: [..] Value_Id; cur.allocator = temp;
        valid := true;
        for u: uniq { p := inst_prev(block_terminator(u)); if p == NONE { valid = false; break; } array_add(*cur, p); }
        while valid {
            i0 := cur[0];
            for cur if !are_identical_up_to_commutativity(i0, it) return false;
            for *cur { p := inst_prev(it.*); if p == NONE { valid = false; break; } it.* = p; }
        }
    }
    num_skipped := 0;
    if pairs.count > 2 {
        k := 0;
        while k < pairs.count { if inst_op(pairs[k].i) == .UNREACHABLE array_ordered_remove_by_index(*pairs, k); else k += 1; }
        if pairs.count < 2 return false;
    }
    changed := false;
    while true {
        i1 := pairs[0].i;
        all_identical := true;
        has_term := is_terminator(inst_op(i1));
        for k: 1..pairs.count-1 {
            i2 := pairs[k].i;
            has_term |= is_terminator(inst_op(i2));
            if all_identical && (!are_identical_up_to_commutativity(i1, i2) || mmra_differ(i1, i2)) all_identical = false;
        }
        others: [..] Value_Id; others.allocator = temp;
        for k: 1..pairs.count-1 array_add(*others, pairs[k].i);
        if has_term {
            if num_skipped != 0 || !all_identical {
                hoist_lockstep_identical_dbg_records(ti, i1, others);
                return changed;
            }
            return hoist_succ_identical_terminator_to_switch_or_if(s, ti, i1, others, uniq) || changed;
        }
        if all_identical {
            all_identical = is_safe_to_hoist_instr(i1, pairs[0].flags);
            if all_identical for k: 1..pairs.count-1 {
                i2 := pairs[k].i;
                if !is_safe_to_hoist_instr(i2, pairs[k].flags) || !should_hoist_common_instructions(s, i1, i2) { all_identical = false; break; }
            }
        }
        if all_identical && inst_op(i1) == .CALL && call_is_must_tail(i1) {
            all_identical = num_skipped == 0;
            if all_identical for pairs if inst_op(inst_next(it.i)) != .RET { all_identical = false; break; }
        }
        if all_identical {
            pairs[0].i = inst_next(pairs[0].i);
            hoist_lockstep_identical_dbg_records(ti, i1, others);
            inst_move_before_dbg(i1, ti);
            for k: 1..pairs.count-1 {
                i2 := pairs[k].i;
                pairs[k].i = inst_next(i2);
                if has_uses(i2) rauw_with_metadata(i2, i1);
                and_ir_flags(i1, i2);
                if is_call_base(i1) try_intersect_attributes(i1, i2);
                combine_metadata_for_cse(i1, i2, true);
                apply_merged_location(i1, get_metadata(i1, 0), get_metadata(i2, 0));
                erase_inst_with_metadata(i2);
            }
            changed = true;
        } else {
            if num_skipped >= scfg_cl.hoist_common_skip_limit {
                hoist_lockstep_identical_dbg_records(ti, i1, others);
                return changed;
            }
            for *pairs {
                i := it.i;
                it.i = inst_next(i);
                it.flags |= skipped_instr_flags(i);
            }
            num_skipped += 1;
        }
    }
    return changed;
}

// IRBuilder::CreateSelectFMF with NoFolder (MDFrom copies !prof / !unpredictable)
irb_select_fmf_nofold :: (b: *Irb, c: Value_Id, t: Value_Id, f: Value_Id, fmf_src: Value_Id, name: string, md_from: Value_Id) -> Value_Id {
    i := new_inst(.SELECT, vtype(t), 3);
    set_op(i, 0, c); set_op(i, 1, t); set_op(i, 2, f);
    if md_from != NONE {
        prof := get_metadata(md_from, md_kind(MD_PROF_NAME));
        unpred := get_metadata(md_from, md_kind("unpredictable"));
        if prof != NONE set_metadata(i, md_kind(MD_PROF_NAME), prof);
        if unpred != NONE set_metadata(i, md_kind("unpredictable"), unpred);
    }
    if is_fp_math_inst(i) && fmf_src != NONE set_fmf(i, inst_fmf(fmf_src));
    return irb_insert(b, i, name);
}

// hoistSuccIdenticalTerminatorToSwitchOrIf
hoist_succ_identical_terminator_to_switch_or_if :: (s: *Scfg, ti: Value_Id, i1: Value_Id, others: [] Value_Id, uniq: [] Value_Id) -> bool {
    bi: Value_Id = ifx inst_op(ti) == .CONDBR then ti else NONE;
    tip := inst_block(ti);
    bb1 := inst_block(i1);
    i2 := others[0];
    bb2 := inst_block(i2);
    if inst_op(i1) == .INVOKE && (bi == NONE || !is_safe_to_hoist_invoke(bb1, bb2, i1, i2)) return false;
    if inst_op(i1) == .CALLBR return false;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb1, *succs);
    for sc: succs for pn: block_insts(sc) {
        if inst_op(pn) != .PHI break;
        v1 := phi_incoming_value_for_block(pn, bb1);
        for o: others {
            v2 := phi_incoming_value_for_block(pn, inst_block(o));
            if v1 == v2 continue;
            if bi == NONE || passing_value_is_always_undefined(v1, pn) || passing_value_is_always_undefined(v2, pn) return false;
        }
    }
    hoist_lockstep_identical_dbg_records(ti, i1, others);
    nt := inst_clone(i1);
    insert_at_position(nt, tip, ti, false);
    if type_kind(vtype(nt)) != .VOID {
        rauw_with_metadata(i1, nt);
        for others rauw_with_metadata(it, nt);
        take_name(nt, i1);
    }
    loc := get_metadata(i1, 0);
    for others loc = merged_location(loc, get_metadata(it, 0));
    set_metadata(nt, 0, loc);
    b: Irb;
    irb_set_before(*b, nt);
    if bi != NONE {
        keys: [..] Value_Id; keys.allocator = temp;     // (BB1V, BB2V) pairs, flattened
        sels: [..] Value_Id; sels.allocator = temp;
        for sc: succs for pn: block_insts(sc) {
            if inst_op(pn) != .PHI break;
            v1 := phi_incoming_value_for_block(pn, bb1);
            v2 := phi_incoming_value_for_block(pn, bb2);
            if v1 == v2 continue;
            sel: Value_Id = NONE;
            for k: 0..sels.count-1 if keys[2 * k] == v1 && keys[2 * k + 1] == v2 sel = sels[k];
            if sel == NONE {
                sel = irb_select_fmf_nofold(*b, op(bi, 0), v1, v2, ifx is_fp_math_inst(pn) then pn else NONE,
                                            tprint("%.%", vname(v1), vname(v2)), bi);
                array_add(*keys, v1); array_add(*keys, v2); array_add(*sels, sel);
            }
            for k: 0..cast(s64) nops(pn) - 1 {
                pb := phi_block(pn, cast(u32) k);
                if pb == bb1 || pb == bb2 phi_set_value(pn, cast(u32) k, sel);
            }
        }
    }
    updates: [..] Dom_Update; updates.allocator = temp;
    for sc: succs {
        add_predecessor_to_block(sc, tip, bb1);
        if s.dtu array_add(*updates, .{true, tip, sc});
    }
    if s.dtu for uniq array_add(*updates, .{false, tip, it});
    erase_terminator_and_dce_cond(ti);
    if s.dtu dtu_apply(s.dtu, updates);
    return true;
}

// ---------------------------------------------------------------- sinking

replacing_operand_with_variable_is_cheap :: (i: Value_Id, op_idx: u32) -> bool {
    if is_int_div_rem(inst_op(i)) return op_idx != 1;
    return call_iid(i) == NOT_INTRINSIC;
}

Phi_Ops :: struct { use_keys: [..] Use_Id; vals: [..] [..] Value_Id; }   // DenseMap<const Use *, SmallVector<Value *>>
phi_ops_find :: (p: *Phi_Ops, u: Use_Id) -> s64 { for p.use_keys if it == u return it_index; return -1; }
phi_ops_get :: (p: *Phi_Ops, u: Use_Id) -> *[..] Value_Id {
    k := phi_ops_find(p, u);
    if k >= 0 return *p.vals[k];
    array_add(*p.use_keys, u);
    v: [..] Value_Id; v.allocator = temp;
    array_add(*p.vals, v);
    return *p.vals[p.vals.count - 1];
}

// canSinkInstructions
can_sink_instructions :: (insts: [] Value_Id, phi_ops: *Phi_Ops) -> bool {
    num_uses_v := -1;
    for i: insts {
        o := inst_op(i);
        if o == .PHI || is_eh_pad(i) || o == .ALLOCA || type_kind(vtype(i)) == .TOKEN return false;
        if block_single_successor_of(inst_block(i)) == inst_block(i) return false;
        if is_call_base(i) {
            if vkind(op(i, nops(i) - 1)) == .INLINE_ASM || call_cannot_merge(i) || call_is_convergent(i) return false;
        }
        n := num_uses(i);
        if num_uses_v < 0 num_uses_v = n;
        else if num_uses_v != n return false;
    }
    i0 := insts[0];
    for i: insts {
        if !is_same_operation_as(i, i0, intersect_attrs = true) return false;
        if mmra_differ(i, i0) return false;
    }
    u := ir.v_first_use[i0];
    while u != NONE {
        k := phi_ops_find(phi_ops, u);
        if k < 0 return false;
        l := phi_ops.vals[k];
        if l.count != insts.count return false;
        for insts if l[it_index] != it return false;
        u = ir.u_next[u];
    }
    if is_call_base(i0) {
        is_indirect :: (i: Value_Id) -> bool { return vkind(op(i, nops(i) - 1)) != .FUNCTION; }
        have := false; all := true;
        for insts { if is_indirect(it) have = true; else all = false; }
        if have { if !all return false; }
        else {
            callee: Value_Id = NONE;
            for insts {
                c := op(it, nops(it) - 1);
                if callee == NONE callee = c;
                else if callee != c return false;
            }
        }
    }
    for oi: 0..cast(s64) nops(i0) - 1 {
        o := op(i0, cast(u32) oi);
        same := true;
        for insts if op(it, cast(u32) oi) != o { same = false; break; }
        if !same {
            if (is_constant_kind(vkind(o)) && !replacing_operand_with_variable_is_cheap(i0, cast(u32) oi)) ||
               !can_replace_operand_with_variable(i0, cast(u32) oi) return false;
            l := phi_ops_get(phi_ops, op_use(i0, cast(u32) oi));
            for insts array_add(l, op(it, cast(u32) oi));
        }
    }
    return true;
}

// sinkLastInstruction
sink_last_instruction :: (blocks: [] Value_Id) {
    bb_end := get_successor(block_terminator(blocks[0]), 0);
    insts: [..] Value_Id; insts.allocator = temp;
    for blocks array_add(*insts, inst_prev(block_terminator(it)));
    i0 := insts[0];
    new_ops: [..] Value_Id; new_ops.allocator = temp;
    for o: 0..cast(s64) nops(i0) - 1 {
        need := false;
        for insts if op(it, cast(u32) o) != op(i0, cast(u32) o) need = true;
        if !need { array_add(*new_ops, op(i0, cast(u32) o)); continue; }
        x := op(i0, cast(u32) o);
        pn := create_phi(vtype(x), cast(u32) insts.count);
        insert_at_position(pn, bb_end, block_first(bb_end), true);
        set_name(pn, tprint("%.sink", vname(x)));
        for insts phi_add_incoming(pn, op(it, cast(u32) o), inst_block(it));
        array_add(*new_ops, pn);
    }
    for o: 0..cast(s64) nops(i0) - 1 set_op(i0, cast(u32) o, new_ops[o]);
    // moveBefore(*BBEnd, BBEnd->getFirstInsertionPt())
    inst_move_before_dbg(i0, block_first_insertion_pt(bb_end));
    for i: insts if i != i0 {
        apply_merged_location(i0, get_metadata(i0, 0), get_metadata(i, 0));
        combine_metadata_for_cse(i0, i, true);
        and_ir_flags(i0, i);
        if is_call_base(i0) try_intersect_attributes(i0, i);
    }
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[i0];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for pn: users {
        rauw_with_metadata(pn, i0);
        erase_inst_with_metadata(pn);
    }
    for i: insts if i != i0 {
        rauw_with_metadata(i, i0);
        erase_inst_with_metadata(i);
    }
}

// IsBlockFollowedByDeoptOrUnreachable (BasicBlockUtils.cpp)
is_block_followed_by_deopt_or_unreachable :: (bb_in: Value_Id) -> bool {
    visited: [..] Value_Id; visited.allocator = temp;
    bb := bb_in;
    depth := 0;
    while bb != NONE && depth < 8 && !block_set_contains(visited, bb) {
        depth += 1;
        array_add(*visited, bb);
        t := block_terminator(bb);
        if inst_op(t) == .UNREACHABLE || block_terminating_deoptimize_call(bb) != NONE return true;
        bb = block_unique_successor_of(bb);
    }
    return false;
}
// BasicBlock::getTerminatingDeoptimizeCall
block_terminating_deoptimize_call :: (bb: Value_Id) -> Value_Id {
    t := block_terminator(bb);
    if t == NONE || inst_op(t) != .RET return NONE;
    p := inst_prev(t);
    if p == NONE || call_iid(p) == NOT_INTRINSIC || iid_name(call_iid(p)) != "llvm.experimental.deoptimize" return NONE;
    if nops(t) > 0 && op(t, 0) != p return NONE;
    return p;
}

// sinkCommonCodeFromPredecessors
sink_common_code_from_predecessors :: (s: *Scfg, bb: Value_Id) -> bool {
    uncond: [..] Value_Id; uncond.allocator = temp;
    have_non_uncond := false;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    for p: preds {
        if inst_op(block_terminator(p)) == .BR array_add(*uncond, p);
        else have_non_uncond = true;
    }
    if uncond.count < 2 return false;
    phi_ops: Phi_Ops; phi_ops.use_keys.allocator = temp; phi_ops.vals.allocator = temp;
    for pn: block_insts(bb) {
        if inst_op(pn) != .PHI break;
        // IncomingVals: the first use per incoming block
        first_use :: (pn: Value_Id, b: Value_Id) -> Use_Id {
            for k: 0..cast(s64) nops(pn) - 1 if phi_block(pn, cast(u32) k) == b return op_use(pn, cast(u32) k);
            return NONE;
        }
        l := phi_ops_get(*phi_ops, first_use(pn, uncond[0]));
        for p: uncond array_add(l, ir.u_val[first_use(pn, p)]);
    }
    // LockstepReverseIterator<true>
    Lri :: struct { insts: [..] Value_Id; fail: bool; }
    lri_reset :: (l: *Lri, blocks: [] Value_Id) {
        l.fail = false; l.insts.count = 0;
        for blocks { p := inst_prev(block_terminator(it)); if p == NONE { l.fail = true; return; } array_add(*l.insts, p); }
        if l.insts.count == 0 l.fail = true;
    }
    lri_dec :: (l: *Lri) {
        if l.fail return;
        for l.insts if inst_prev(it) == NONE { l.fail = true; return; }
        for *l.insts it.* = inst_prev(it.*);
    }
    lri_inc :: (l: *Lri) {
        if l.fail return;
        for l.insts if inst_next(it) == NONE { l.fail = true; return; }
        for *l.insts it.* = inst_next(it.*);
    }
    lri: Lri; lri.insts.allocator = temp;
    lri_reset(*lri, uncond);
    scan_idx := 0;
    to_sink: [..] Value_Id; to_sink.allocator = temp;
    while !lri.fail && can_sink_instructions(lri.insts, *phi_ops) {
        for lri.insts array_add(*to_sink, it);
        scan_idx += 1;
        lri_dec(*lri);
    }
    if scan_idx == 0 return false;
    followed := is_block_followed_by_deopt_or_unreachable(bb);
    if !followed {
        is_mem_operand :: (user: Value_Id, k: u32) -> bool {
            if inst_op(user) == .LOAD return k == 0;
            if inst_op(user) == .STORE return k == 1;
            return false;
        }
        profitable :: (l: *Lri, phi_ops: *Phi_Ops, to_sink: [] Value_Id) -> bool {
            num_phi := 0;
            i0 := l.insts[0];
            for k: 0..cast(s64) nops(i0) - 1 {
                idx := phi_ops_find(phi_ops, op_use(i0, cast(u32) k));
                if idx < 0 continue;
                all_in := true;
                for phi_ops.vals[idx] if !block_set_contains(to_sink, it) { all_in = false; break; }
                if all_in continue;
                num_phi += 1;
                if is_mem_operand(i0, cast(u32) k) {
                    for phi_ops.vals[idx] if opr_code(it) == .GEP && (is_inst(it) || vkind(it) == .C_EXPR) return false;
                }
            }
            return num_phi <= 1;
        }
        lri_reset(*lri, uncond);
        idx := 0;
        prof_set: [..] Value_Id; prof_set.allocator = temp;
        while idx < scan_idx {
            if !profitable(*lri, *phi_ops, to_sink) break;
            for lri.insts array_add(*prof_set, it);
            lri_dec(*lri);
            idx += 1;
        }
        if idx == 0 return false;
        if idx < scan_idx {
            scan_idx = idx;
            to_sink.count = 0; for prof_set array_add(*to_sink, it);
            lri_inc(*lri);
            idx -= 1;
            while idx >= 0 {
                for i: lri.insts {
                    for prof_set if it == i { array_unordered_remove_by_index(*prof_set, it_index); break; }
                }
                if !profitable(*lri, *phi_ops, to_sink) {
                    scan_idx = idx;
                    to_sink.count = 0; for prof_set array_add(*to_sink, it);
                }
                lri_inc(*lri);
                idx -= 1;
            }
        }
        if scan_idx == 0 return false;
    }
    changed := false;
    if have_non_uncond {
        if !followed {
            lri_reset(*lri, uncond);
            idx := 0;
            ok := false;
            while idx < scan_idx {
                if !is_safe_to_speculatively_execute_cx(lri.insts[0], NONE, null) { ok = true; break; }
                lri_dec(*lri);
                idx += 1;
            }
            if !ok return false;
        }
        if scfg_split_block_predecessors(s, bb, uncond, ".sink.split") == NONE return false;
        changed = true;
    }
    for 0..scan_idx-1 {
        sink_last_instruction(uncond);
        changed = true;
    }
    return changed;
}

// ---------------------------------------------------------------- speculation

// EphemeralValueTracker
Eph_Tracker :: struct { vals: [..] Value_Id; }
eph_is_ephemeral :: (e: *Eph_Tracker, i: Value_Id) -> bool {
    if call_iid(i) == IID_ASSUME return true;
    if may_have_side_effects(i) || is_terminator(inst_op(i)) return false;
    u := ir.v_first_use[i];
    while u != NONE { if !block_set_contains(e.vals, ir.u_user[u]) return false; u = ir.u_next[u]; }
    return true;
}
eph_track :: (e: *Eph_Tracker, i: Value_Id) -> bool {
    if eph_is_ephemeral(e, i) { array_add(*e.vals, i); return true; }
    return false;
}

// isSafeToSpeculateStore
is_safe_to_speculate_store :: (i: Value_Id, br_bb: Value_Id, store_bb: Value_Id, end_bb: Value_Id) -> Value_Id {
    if inst_op(i) != .STORE return NONE;
    if !inst_is_simple(i) return NONE;
    ptr := op(i, 1);
    sty := vtype(op(i, 0));
    max_look := 9;
    x := block_last(br_bb);
    while x != NONE {
        cur := x;
        x = inst_prev(x);
        if max_look == 0 break;
        max_look -= 1;
        if is_pseudo_probe(cur) continue;
        if may_write_to_memory(cur) && inst_op(cur) != .STORE return NONE;
        if inst_op(cur) == .STORE {
            if op(cur, 1) == ptr && vtype(op(cur, 0)) == sty && inst_is_simple(cur) && inst(cur).align >= inst(i).align return op(cur, 0);
            return NONE;
        }
        if inst_op(cur) == .LOAD {
            if op(cur, 0) == ptr && vtype(cur) == sty && inst_is_simple(cur) && inst(cur).align >= inst(i).align {
                obj := get_underlying_object(ptr);
                writable, explicitly_deref_only := is_writable_object(obj);
                if writable {
                    wo, _ := pointer_may_be_captured(obj, CC_PROVENANCE, .ANYTHING);
                    if wo == CC_NONE && (!explicitly_deref_only || is_dereferenceable_pointer_ty(ptr, sty, Simplify_Query.{have_tli = false}, true)) return cur;
                }
            }
        }
    }
    return NONE;
}
scfg_np_bool :: (what: string) -> bool { scfg_np(what); return false; }

// passingValueIsAlwaysUndefined
passing_value_is_always_undefined :: (v: Value_Id, i: Value_Id, ptr_value_may_be_modified_in := false) -> bool {
    ptr_mod := ptr_value_may_be_modified_in;
    if !is_constant_kind(vkind(v)) return false;
    if !has_uses(i) return false;
    c := v;
    if !(is_null_value(c) || is_undef_value(c)) return false;
    use: Use_Id = NONE;
    u := ir.v_first_use[i];
    while u != NONE {
        user := ir.u_user[u];
        if is_inst(user) && inst_block(user) == inst_block(i) && user != i && !comes_before(user, i) {
            o := inst_op(user);
            if o == .GEP || o == .RET || o == .BITCAST || o == .LOAD || o == .STORE || o == .CALL || o == .CALLBR ||
               o == .INVOKE || o == .UDIV || o == .UREM || o == .SDIV || o == .SREM { use = u; break; }
        }
        u = ir.u_next[u];
    }
    if use == NONE return false;
    user := ir.u_user[use];
    x := inst_next(i);
    while x != user { if !is_guaranteed_to_transfer_execution(x) return false; x = inst_next(x); }
    f := inst_fn(i);
    if inst_op(user) == .GEP && op(user, 0) == i {
        if is_vector_type(vtype(user)) return false;
        if !gep_has_all_zero_indices(user) && ((inst(user).flags & F_INBOUNDS) == 0 || null_pointer_is_defined(f, ptr_addrspace(vtype(user)))) ptr_mod = true;
        return passing_value_is_always_undefined(v, user, ptr_mod);
    }
    if inst_op(user) == .RET {
        ra := attr_list_ret(glob(f).attrs);
        has_noundef := attr_set_has(ra, .NoUndef);
        if is_undef_value(c) && has_noundef return true;
        if is_null_value(c) && has_noundef && attr_set_has(ra, .NonNull) return !ptr_mod;
    }
    if inst_op(user) == .LOAD && (inst(user).flags & F_VOLATILE) == 0 return !null_pointer_is_defined(f, ptr_addrspace(vtype(op(user, 0))));
    if inst_op(user) == .STORE && (inst(user).flags & F_VOLATILE) == 0
        return !null_pointer_is_defined(f, ptr_addrspace(vtype(op(user, 1)))) && op(user, 1) == i;
    if call_iid(user) == IID_ASSUME && op(user, 0) == i return true;
    if is_call_base(user) {
        if is_null_value(c) && null_pointer_is_defined(f) return false;
        if op(user, nops(user) - 1) == i return true;
        k := use - ir.v_ops[user];
        if k < call_num_args(user) {
            if vkind(c) == .C_NULL && type_kind(vtype(c)) == .PTR && call_param_has_nonnull_attr(user, k, false) return !ptr_mod;
            if is_undef_value(c) && (call_param_has_attr(user, k, .NoUndef) || call_param_has_attr(user, k, .Dereferenceable) ||
                                     call_param_has_attr(user, k, .DereferenceableOrNull)) return true;
        }
    }
    if is_binary_op(inst_op(user)) && op(user, 1) == i && is_int_div_rem(inst_op(user)) return true;
    return false;
}
// CallBase::paramHasNonNullAttr: call_param_has_nonnull_attr (value_tracking.jai)

// validateAndCostRequiredSelects
validate_and_cost_required_selects :: (s: *Scfg, bb: Value_Id, then_bb: Value_Id, end_bb: Value_Id, spec: *s64, cost: *Cost) -> bool {
    kind := ifx fn_has_min_size(block_fn(bb)) then TCK_CODE_SIZE else TCK_SIZE_AND_LATENCY;
    have := false;
    for pn: block_insts(end_bb) {
        if inst_op(pn) != .PHI break;
        ov := phi_incoming_value_for_block(pn, bb);
        tv := phi_incoming_value_for_block(pn, then_bb);
        if tv == ov continue;
        cost.* = cost_add(cost.*, tti_cmp_sel_cost(s.tti, .SELECT, vtype(pn), make_cmp_result_type(vtype(pn)), BAD_ICMP_PREDICATE, kind));
        if passing_value_is_always_undefined(ov, pn) || passing_value_is_always_undefined(tv, pn) return false;
        have = true;
        oce := vkind(ov) == .C_EXPR; tce := vkind(tv) == .C_EXPR;
        if !oce && !tce continue;
        oc: Cost = ifx oce then compute_speculation_cost(s, ov) else 0;
        tc: Cost = ifx tce then compute_speculation_cost(s, tv) else 0;
        if cost_add(oc, tc) > 2 * scfg_cl.phi_node_folding_threshold * TCC_BASIC return false;
        spec.* += 1;
        if spec.* > 1 return false;
    }
    return have;
}
// isProfitableToSpeculate (Invert: 0 false, 1 true, -1 none)
is_profitable_to_speculate :: (s: *Scfg, bi: Value_Id, invert: s64) -> bool {
    if get_metadata(bi, md_kind("unpredictable")) != NONE return true;
    ok, tw, fw := prof_extract_branch_weights_2(bi);
    if !ok || tw + fw == 0 return true;
    if invert < 0 return false;
    ew := ifx invert == 1 then tw else fw;
    return bp_get(ew, tw + fw) < tti_likely(s);
}

// speculativelyExecuteBB
speculatively_execute_bb :: (s: *Scfg, bi: Value_Id, then_bb: Value_Id) -> bool {
    if !s.opts.speculate_blocks return false;
    br_cond := op(bi, 0);
    if is_inst(br_cond) && inst_op(br_cond) == .FCMP return false;
    bb := inst_block(bi);
    end_bb := get_successor(block_terminator(then_bb), 0);
    budget := scfg_cl.phi_node_folding_threshold * TCC_BASIC;
    invert := then_bb != get_successor(bi, 0);
    if !is_profitable_to_speculate(s, bi, ifx invert then 1 else 0) return false;
    sink_keys: [..] Value_Id; sink_keys.allocator = temp;
    sink_cnt: [..] s64; sink_cnt.allocator = temp;
    probes: [..] Value_Id; probes.allocator = temp;
    spec: s64 = 0;
    hoist_ls := s.opts.hoist_loads_stores_with_cond_faulting;
    cond_ls: [..] Value_Id; cond_ls.allocator = temp;
    spec_store_val: Value_Id = NONE;
    spec_store: Value_Id = NONE;
    eph: Eph_Tracker; eph.vals.allocator = temp;
    i := inst_prev(block_terminator(then_bb));
    while i != NONE {
        cur := i;
        i = inst_prev(i);
        if is_pseudo_probe(cur) { array_add(*probes, cur); continue; }
        if eph_track(*eph, cur) continue;
        safe_cheap := hoist_ls && is_safe_cheap_load_store(s, cur) && cond_ls.count < scfg_cl.hoist_loads_stores_with_cond_faulting_threshold;
        if safe_cheap array_add(*cond_ls, cur);
        else spec += 1;
        if spec > 1 return false;
        if !safe_cheap && !is_safe_to_speculatively_execute_cx(cur, bi, s.opts.ac) {
            if !(scfg_cl.hoist_cond_stores && spec_store_val == NONE) return false;
            spec_store_val = is_safe_to_speculate_store(cur, bb, then_bb, end_bb);
            if spec_store_val == NONE return false;
        }
        if !safe_cheap && spec_store_val == NONE && compute_speculation_cost(s, cur) > scfg_cl.phi_node_folding_threshold * TCC_BASIC return false;
        if spec_store == NONE && spec_store_val != NONE spec_store = cur;
        for k: 0..cast(s64) nops(cur) - 1 {
            o := op(cur, cast(u32) k);
            if !is_inst(o) || inst_block(o) != bb || may_have_side_effects(o) continue;
            idx := -1;
            for sink_keys if it == o idx = it_index;
            if idx < 0 { array_add(*sink_keys, o); array_add(*sink_cnt, 0); idx = sink_keys.count - 1; }
            sink_cnt[idx] += 1;
        }
    }
    for sink_keys if num_uses(it) == sink_cnt[it_index] {
        spec += 1;
        if spec > 1 return false;
    }
    convert := spec_store != NONE || cond_ls.count > 0;
    cost: Cost = 0;
    convert |= validate_and_cost_required_selects(s, bb, then_bb, end_bb, *spec, *cost);
    if !convert || cost > budget return false;
    sel: Value_Id = NONE;
    if spec_store_val != NONE {
        b: Irb; irb_set_before(*b, bi);
        tv := op(spec_store, 0);
        fv := spec_store_val;
        if invert { t := tv; tv = fv; fv = t; }
        sel = irb_select_fmf_nofold(*b, br_cond, tv, fv, NONE, "spec.store.select", bi);
        orig_v := op(spec_store, 0);
        set_op(spec_store, 0, sel);
        apply_merged_location(spec_store, get_metadata(bi, 0), get_metadata(spec_store, 0));
        dbg_assign_replace_location(spec_store, orig_v, sel);
    }
    for :early_inc x: block_insts(then_bb) {
        if spec_store_val == NONE || x != spec_store drop_location(x);
        drop_ub_implying_attrs_and_metadata(x);
        if block_set_contains(eph.vals, x) {
            rauw_with_metadata(x, const_poison(vtype(x)));
            erase_inst_with_metadata(x);
        }
    }
    for x: block_insts(then_bb) {
        r := inst(x).records;
        while r != 0 {
            nx := dbgr(r).next;
            if dbgr(r).kind != .ASSIGN dbgr_erase(r);
            r = nx;
        }
    }
    // BB->splice(BI, ThenBB, begin, prev(end))
    block_splice(bi, false, then_bb, block_first(then_bb), true, block_terminator(then_bb));
    // cond_ls was collected bottom-up; LLVM's SmallVector is in the same (reverse) order
    if cond_ls.count hoist_conditional_loads_stores(bi, cond_ls, ifx invert then 1 else 0, sel);
    b: Irb; irb_set_before(*b, bi);
    for pn: block_insts(end_bb) {
        if inst_op(pn) != .PHI break;
        oi := cast(u32) phi_block_index(pn, bb);
        ti := cast(u32) phi_block_index(pn, then_bb);
        ov := phi_value(pn, oi);
        tv := phi_value(pn, ti);
        if ov == tv continue;
        tvv := tv; fvv := ov;
        if invert { tt := tvv; tvv = fvv; fvv = tt; }
        v := irb_select_fmf_nofold(*b, br_cond, tvv, fvv, NONE, "spec.select", bi);
        phi_set_value(pn, oi, v);
        phi_set_value(pn, ti, v);
    }
    for probes erase_inst_with_metadata(it);
    return true;
}
// Instruction::dropLocation
drop_location :: (i: Value_Id) {
    if get_metadata(i, 0) == NONE return;
    may_lower_to_call := false;
    if is_call_base(i) {
        id := call_iid(i);
        may_lower_to_call = id == NOT_INTRINSIC || begins_with(iid_name(id), "llvm.objc.");
    }
    if !may_lower_to_call { set_metadata(i, 0, NONE); return; }
    sp := get_metadata(inst_fn(i), 0);
    if sp != NONE set_metadata(i, 0, di_location_get(0, 0, sp, NONE));
    else set_metadata(i, 0, NONE);
}
// isSafeCheapLoadStore
is_safe_cheap_load_store :: (s: *Scfg, i: Value_Id) -> bool {
    is_store := false;
    if inst_op(i) == .LOAD { if !inst_is_simple(i) || !scfg_cl.hoist_loads_with_cond_faulting return false; }
    else if inst_op(i) == .STORE { if !inst_is_simple(i) || !scfg_cl.hoist_stores_with_cond_faulting return false; is_store = true; }
    else return false;
    ty := ifx is_store then vtype(op(i, 0)) else vtype(i);
    return tti_has_conditional_load_store_for_type(s.tti, ty, is_store) && inst(i).align < (cast(u64) 1 << 32);
}

// ---------------------------------------------------------------- threading through blocks with known conditions

find_reaching :: (bb: Value_Id, def_bb: Value_Id, reaches: *[..] Value_Id) -> bool {
    if bb == def_bb return true;
    if block_set_contains(reaches.*, bb) return true;
    array_add(reaches, bb);
    if reaches.count > scfg_cl.max_jump_threading_live_blocks return false;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    for preds if !find_reaching(it, def_bb, reaches) return false;
    return true;
}
block_is_simple_enough_to_thread_through :: (bb: Value_Id, non_local: *[..] Value_Id) -> bool {
    size := 0;
    eph: Eph_Tracker; eph.vals.allocator = temp;
    x := block_last(bb);
    while x != NONE {
        i := x;
        x = inst_prev(x);
        if inst_op(i) == .CALL && (call_cannot_duplicate(i) || call_is_convergent(i)) return false;
        if !eph_track(*eph, i) && inst_op(i) != .PHI {
            if size > scfg_cl.max_small_block_size return false;
            size += 1;
        }
        u := ir.v_first_use[i];
        while u != NONE {
            ui := ir.u_user[u];
            ub := inst_block(ui);
            if ub == bb { if inst_op(ui) == .PHI return false; }
            else if !block_set_contains(non_local.*, ub) array_add(non_local, ub);
            u = ir.u_next[u];
        }
    }
    return true;
}
get_known_value_on_edge :: (v: Value_Id, from: Value_Id, to: Value_Id) -> Value_Id {
    if is_inst(v) && inst_block(v) == to return NONE;
    bi := block_terminator(from);
    if inst_op(bi) == .CONDBR && op(bi, 0) == v && get_successor(bi, 0) != get_successor(bi, 1)
        return const_int(ir.t_i1, ifx get_successor(bi, 0) == to then cast(u64) 1 else 0);
    return NONE;
}

// foldCondBranchOnValueKnownInPredecessorImpl: 1 = changed, 0 = no change, -1 = changed, run again (nullopt)
fold_cond_branch_on_value_known_in_predecessor_impl :: (s: *Scfg, bi: Value_Id) -> s64 {
    kv_keys: [..] Value_Id; kv_keys.allocator = temp;
    kv_preds: [..] [..] Value_Id; kv_preds.allocator = temp;
    add_kv :: (keys: *[..] Value_Id, preds: *[..] [..] Value_Id, c: Value_Id, p: Value_Id) {
        for keys.* if it == c { if !block_set_contains(preds.*[it_index], p) array_add(*preds.*[it_index], p); return; }
        array_add(keys, c);
        l: [..] Value_Id; l.allocator = temp; array_add(*l, p);
        array_add(preds, l);
    }
    bb := inst_block(bi);
    cond := op(bi, 0);
    if is_phi(cond) && inst_block(cond) == bb {
        if nops(cond) == 1 { fold_single_entry_phi_nodes(bb); return 1; }
        for k: 0..cast(s64) nops(cond) - 1 {
            v := phi_value(cond, cast(u32) k);
            if is_const_int(v) add_kv(*kv_keys, *kv_preds, v, phi_block(cond, cast(u32) k));
        }
    } else {
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(bb, *preds);
        for p: preds { c := get_known_value_on_edge(cond, p, bb); if c != NONE add_kv(*kv_keys, *kv_preds, c, p); }
    }
    if kv_keys.count == 0 return 0;
    non_local: [..] Value_Id; non_local.allocator = temp;
    reaches: [..] Value_Id; reaches.allocator = temp;
    if !block_is_simple_enough_to_thread_through(bb, *non_local) return 0;
    if block_set_contains(non_local, get_successor(bi, 0)) && block_set_contains(non_local, get_successor(bi, 1)) return 0;
    for non_local if !find_reaching(it, bb, *reaches) return 0;
    for cb, ki: kv_keys {
        pred_bbs := kv_preds[ki];
        real_dest := get_successor(bi, ifx ap_is_zero(cf_ap(cb)) then cast(u32) 1 else 0);
        if real_dest == bb continue;
        indirect := false;
        for pred_bbs if inst_op(block_terminator(it)) == .INDIRECTBR indirect = true;
        if indirect continue;
        if block_set_contains(reaches, real_dest) continue;
        edge_bb := scfg_split_block_predecessors(s, bb, pred_bbs, ".critedge");
        if edge_bb == NONE continue;
        set_name(edge_bb, tprint("%.critedge", vname(real_dest)));
        block_move_before(edge_bb, real_dest);
        add_predecessor_to_block(real_dest, edge_bb, bb);
        insert_pt := block_first_insertion_pt(edge_bb);
        tmap: Table(Value_Id, Value_Id); tmap.allocator = temp;
        table_set(*tmap, cond, cb);
        src_cursor := block_first(bb);
        x := block_first(bb);
        cloned: [..] u32; cloned.allocator = temp;
        while x != bi {
            cur := x;
            x = inst_next(x);
            if inst_op(cur) == .PHI { table_set(*tmap, cur, phi_incoming_value_for_block(cur, edge_bb)); continue; }
            n := inst_clone(cur);
            insert_at_position(n, edge_bb, insert_pt, false);
            if vname(cur).count set_name(n, tprint("%.c", vname(cur)));
            dl := get_metadata(cur, 0);
            if dl != NONE && di_int(dl, 3) != 0 scfg_np("key-instructions atom groups");
            for k: 0..cast(s64) nops(n) - 1 { found, nv := table_find(*tmap, op(n, cast(u32) k)); if found set_op(n, cast(u32) k, nv); }
            q: Simplify_Query; q.ac = s.opts.ac;
            sv := simplify_instruction(n, q);
            if sv != NONE {
                if has_uses(cur) table_set(*tmap, cur, sv);
                if !may_have_side_effects(n) { erase_inst_with_metadata(n); n = NONE; }
            } else if has_uses(cur) table_set(*tmap, cur, n);
            if n != NONE {
                while src_cursor != cur {
                    if inst(src_cursor).records { clone_debug_info_from(n, src_cursor, inst(src_cursor).records, *cloned); }
                    src_cursor = inst_next(src_cursor);
                }
                src_cursor = inst_next(cur);
                if inst(cur).records { clone_debug_info_from(n, cur, inst(cur).records, *cloned); }
                if call_iid(n) == IID_ASSUME && s.opts.ac ac_register_assumption(s.opts.ac, n);
            }
        }
        while src_cursor != bi {
            if inst(src_cursor).records { clone_debug_info_from(insert_pt, src_cursor, inst(src_cursor).records, *cloned); }
            src_cursor = inst_next(src_cursor);
        }
        if inst(bi).records { clone_debug_info_from(insert_pt, bi, inst(bi).records, *cloned); }
        block_remove_predecessor(bb, edge_bb);
        ebi := block_terminator(edge_bb);
        set_successor(ebi, 0, real_dest);
        copy_debug_loc_or_clear(ebi, bi);
        if s.dtu { ups := Dom_Update.[.{false, edge_bb, bb}, .{true, edge_bb, real_dest}]; dtu_apply(s.dtu, ups); }
        merge_block_into_predecessor(edge_bb, ifx s.dtu then s.dtu.dt else null, null, null);
        return -1;
    }
    return 0;
}
fold_cond_branch_on_value_known_in_predecessor :: (s: *Scfg, bi: Value_Id) -> bool {
    if s.opts.need_canonical_loop && is_loop_header(s, inst_block(bi)) return false;
    ever := false;
    while true {
        r := fold_cond_branch_on_value_known_in_predecessor_impl(s, bi);
        ever |= r != 0;
        if r != -1 break;
    }
    return ever;
}
// BasicBlock::moveBefore(MovePos)
block_move_before :: (b: Value_Id, pos: Value_Id) {
    f := block_fn(b);
    fn_unlink_block(f, b);
    fn_insert_block_before(f, pos, b);
}

// ---------------------------------------------------------------- two-entry phi nodes

// GetIfCondition (BasicBlockUtils.cpp): (DomBI, IfTrue, IfFalse)
get_if_condition :: (bb: Value_Id) -> (Value_Id, Value_Id, Value_Id) {
    some := block_first(bb);
    p1, p2: Value_Id = NONE, NONE;
    if inst_op(some) == .PHI {
        if nops(some) != 2 return NONE, NONE, NONE;
        p1 = phi_block(some, 0); p2 = phi_block(some, 1);
    } else {
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(bb, *preds);
        if preds.count != 2 return NONE, NONE, NONE;
        p1 = preds[0]; p2 = preds[1];
    }
    t1 := block_terminator(p1); t2 := block_terminator(p2);
    if inst_op(t2) == .CONDBR {
        if inst_op(t1) == .CONDBR return NONE, NONE, NONE;
        x := p1; p1 = p2; p2 = x;
        y := t1; t1 = t2; t2 = y;
    }
    if inst_op(t2) != .BR return NONE, NONE, NONE;
    if inst_op(t1) == .CONDBR {
        if block_single_predecessor(p2) == NONE return NONE, NONE, NONE;
        if get_successor(t1, 0) == bb && get_successor(t1, 1) == p2 return t1, p1, p2;
        if get_successor(t1, 0) == p2 && get_successor(t1, 1) == bb return t1, p2, p1;
        return NONE, NONE, NONE;
    }
    if inst_op(t1) != .BR return NONE, NONE, NONE;
    common := block_single_predecessor(p1);
    if common == NONE || common != block_single_predecessor(p2) return NONE, NONE, NONE;
    bi := block_terminator(common);
    if inst_op(bi) != .CONDBR return NONE, NONE, NONE;
    if get_successor(bi, 0) == p1 return bi, p1, p2;
    return bi, p2, p1;
}

// foldTwoEntryPHINode
fold_two_entry_phi_node :: (s: *Scfg, pn_in: Value_Id) -> bool {
    bb := inst_block(pn_in);
    dom_bi, if_true, if_false := get_if_condition(bb);
    if dom_bi == NONE return false;
    if_cond := op(dom_bi, 0);
    if is_const_int(if_cond) return false;
    dom_block := inst_block(dom_bi);
    if_blocks: [..] Value_Id; if_blocks.allocator = temp;
    for k: 0..cast(s64) nops(pn_in) - 1 { b := phi_block(pn_in, cast(u32) k); if inst_op(block_terminator(b)) == .BR array_add(*if_blocks, b); }
    unpredictable := get_metadata(dom_bi, md_kind("unpredictable")) != NONE;
    if !unpredictable {
        ok, tw, fw := prof_extract_branch_weights_2(dom_bi);
        if ok && tw + fw != 0 {
            tp := bp_get(tw, tw + fw);
            likely := tti_likely(s);
            fp := bp_compl(tp);
            if if_blocks.count == 1 {
                bbp := ifx get_successor(dom_bi, 0) == bb then tp else fp;
                if bbp >= likely return false;
            } else if tp >= likely || fp >= likely return false;
        }
    }
    if is_phi(if_cond) && inst_block(if_cond) == bb return false;
    nphis := 0;
    for block_insts(bb) { if inst_op(it) != .PHI break; if nphis > 2 return false; nphis += 1; }
    aggressive: [..] Value_Id; aggressive.allocator = temp;
    zero_cost: [..] Value_Id; zero_cost.allocator = temp;
    cost: Cost = 0;
    budget := scfg_cl.two_entry_phi_node_folding_threshold * TCC_BASIC;
    if s.opts.speculate_unpredictables && unpredictable budget = cost_add(budget, tti_branch_mispredict_penalty(s.tti));
    changed := false;
    ii := block_first(bb);
    while ii != NONE && inst_op(ii) == .PHI {
        pn := ii;
        ii = inst_next(ii);
        q: Simplify_Query; q.cxt = pn;
        v := simplify_instruction(pn, q);
        if v != NONE {
            rauw_with_metadata(pn, v);
            erase_inst_with_metadata(pn);
            changed = true;
            continue;
        }
        if !dominates_merge_point(s, phi_value(pn, 0), bb, dom_bi, *aggressive, *cost, budget, *zero_cost) ||
           !dominates_merge_point(s, phi_value(pn, 1), bb, dom_bi, *aggressive, *cost, budget, *zero_cost) return changed;
    }
    pn := block_first(bb);
    if inst_op(pn) != .PHI return true;
    is_bin_op_or_and_eq :: (v: Value_Id) -> bool {
        is_cmp :: (x: Value_Id) -> bool { return is_inst(x) && (inst_op(x) == .ICMP || inst_op(x) == .FCMP); }
        if is_inst(v) && is_binary_op(inst_op(v)) {
            if is_cmp(op(v, 0)) return is_equality_pred(inst(op(v, 0)).pred);
            if is_cmp(op(v, 1)) return is_equality_pred(inst(op(v, 1)).pred);
        }
        // m_c_Select(m_ImmConstant(), m_Cmp(...))
        if is_inst(v) && inst_op(v) == .SELECT {
            t := op(v, 1); f := op(v, 2);
            if is_imm_constant(t) && is_cmp(f) return is_equality_pred(inst(f).pred);
            if is_imm_constant(f) && is_cmp(t) return is_equality_pred(inst(t).pred);
        }
        return false;
    }
    pt := vtype(pn);
    if type_kind(pt) == .INT && type_int_width(pt) == 1 &&
       (is_bin_op_or_and_eq(phi_value(pn, 0)) || is_bin_op_or_and_eq(phi_value(pn, 1)) || is_bin_op_or_and_eq(if_cond)) return changed;
    for ib: if_blocks for i: block_insts(ib) {
        if is_terminator(inst_op(i)) break;
        if !block_set_contains(aggressive, i) && !is_debug_or_pseudo_inst(i) return changed;
    }
    for if_blocks if block_has_address_taken(it) return changed;
    for if_blocks hoist_all_instructions_into(dom_block, dom_bi, it);
    b: Irb; irb_set_before(*b, dom_bi);
    while inst_op(block_first(bb)) == .PHI {
        p := block_first(bb);
        tv := phi_incoming_value_for_block(p, if_true);
        fv := phi_incoming_value_for_block(p, if_false);
        sel := irb_select_fmf_nofold(*b, if_cond, tv, fv, ifx is_fp_math_inst(p) then p else NONE, "", dom_bi);
        rauw_with_metadata(p, sel);
        take_name(sel, p);
        erase_inst_with_metadata(p);
    }
    irb_br(*b, bb);
    updates: [..] Dom_Update; updates.allocator = temp;
    if s.dtu {
        array_add(*updates, .{true, dom_block, bb});
        succs: [..] Value_Id; succs.allocator = temp;
        block_successors(dom_block, *succs);
        for succs array_add(*updates, .{false, dom_block, it});
    }
    erase_terminator(dom_bi);
    if s.dtu dtu_apply(s.dtu, updates);
    return true;
}
// m_ImmConstant: a constant that is not a constant expression and contains none
is_imm_constant :: (v: Value_Id) -> bool {
    if !is_constant_kind(vkind(v)) || is_global_value(vkind(v)) return false;
    return !const_contains_constant_expression(v);
}
const_contains_constant_expression :: (c: Value_Id) -> bool {
    k := vkind(c);
    if k == .C_EXPR || k == .C_BLOCKADDR || k == .C_DSO_EQUIV || k == .C_NO_CFI || k == .C_PTRAUTH || is_global_value(k) return true;
    if k == .C_VECTOR || k == .C_ARRAY || k == .C_STRUCT {
        for j: 0..cast(s64) nops(c) - 1 if const_contains_constant_expression(op(c, cast(u32) j)) return true;
    }
    return false;
}

// ---------------------------------------------------------------- FoldBranchToCommonDest

// createLogicalOp (IRBuilder<ConstantFolder> + the annotation-copying inserter)
create_logical_op :: (b: *Irb, opc: Opcode, lhs: Value_Id, rhs: Value_Id, name: string, annot_from: Value_Id) -> Value_Id {
    r: Value_Id;
    if implies_poison(rhs, lhs) r = irb_binop(b, opc, lhs, rhs, name);
    else if opc == .AND r = irb_select(b, lhs, rhs, const_int(vtype(lhs), 0), name);
    else r = irb_select(b, lhs, const_int(vtype(lhs), 1), rhs, name);
    copy_annotation_from(r, annot_from);
    return r;
}
copy_annotation_from :: (i: Value_Id, from: Value_Id) {
    if !is_inst(i) || from == NONE return;
    a := get_metadata(from, MD_ANNOTATION_KIND);
    if a != NONE set_metadata(i, MD_ANNOTATION_KIND, a);   // Instruction::copyMetadata(Src, {MD_annotation})
}

// shouldFoldCondBranchesToCommonDestination: (ok, CommonSucc, Opc, InvertPredCond)
should_fold_cond_branches_to_common_destination_tti :: (s: *Scfg, bi: Value_Id, pbi: Value_Id) -> (bool, Value_Id, Opcode, bool) {
    known := false;
    ptp: u32 = 0; likely: u32 = 0;
    if s.tti && get_metadata(pbi, md_kind("unpredictable")) == NONE {
        ok, ptw, pfw := prof_extract_branch_weights_2(pbi);
        if ok && ptw + pfw != 0 { ptp = bp_get(ptw, ptw + pfw); likely = tti_likely(s); known = true; }
    }
    if get_successor(pbi, 0) == get_successor(bi, 0) {
        if !known || ptp < likely return true, get_successor(bi, 0), .OR, false;
    } else if get_successor(pbi, 1) == get_successor(bi, 1) {
        if !known || bp_compl(ptp) < likely return true, get_successor(bi, 1), .AND, false;
    } else if get_successor(pbi, 0) == get_successor(bi, 1) {
        if !known || ptp < likely return true, get_successor(bi, 1), .AND, true;
    } else if get_successor(pbi, 1) == get_successor(bi, 0) {
        if !known || bp_compl(ptp) < likely return true, get_successor(bi, 0), .OR, true;
    }
    return false, NONE, .AND, false;
}

// cloneInstructionsIntoPredecessorBlockAndUpdateSSAUses
clone_instructions_into_predecessor_block_and_update_ssa_uses :: (bb: Value_Id, pred: Value_Id, vm: *Table(Value_Id, Value_Id)) {
    pti := block_terminator(pred);
    cloned: [..] u32; cloned.allocator = temp;
    for bonus: block_insts(bb) {
        if is_terminator(inst_op(bonus)) continue;
        if is_pseudo_probe(bonus) continue;
        nb := inst_clone(bonus);
        nl := get_metadata(nb, 0); pl := get_metadata(pti, 0);
        same := nl == pl || (nl != NONE && pl != NONE && diloc_line(nl) == diloc_line(pl) && diloc_col(nl) == diloc_col(pl) &&
                             diloc_scope(nl) == diloc_scope(pl) && diloc_inlined_at(nl) == diloc_inlined_at(pl));
        if !same set_metadata(nb, 0, NONE);
        else if nl != NONE && di_int(nl, 3) != 0 scfg_np("key-instructions atom groups");
        for k: 0..cast(s64) nops(nb) - 1 { found, nv := table_find(vm, op(nb, cast(u32) k)); if found set_op(nb, cast(u32) k, nv); }
        drop_ub_implying_attrs_and_metadata(nb);
        insert_at_position(nb, pred, pti, false);
        if inst(bonus).records {
            clone_debug_info_from(nb, bonus, inst(bonus).records, *cloned);
            remap_dbg_records(cloned, vm);
        }
        take_name(nb, bonus);
        set_name(bonus, tprint("%.old", vname(nb)));
        table_set(vm, bonus, nb);
        u := ir.v_first_use[bonus];
        while u != NONE {
            nx := ir.u_next[u];
            user := ir.u_user[u];
            if inst_op(user) == .PHI && ir.u_aux[u] != bb use_set(u, nb);
            u = nx;
        }
    }
    pdl := get_metadata(pti, 0);
    if pdl != NONE {
        dl := get_metadata(block_terminator(bb), 0);
        if dl != NONE && di_int(dl, 3) != 0 && di_int(pdl, 3) == 0 scfg_np("key-instructions atom groups");
    }
}

// performBranchToCommonDestFolding
perform_branch_to_common_dest_folding_full :: (s: *Scfg, bi: Value_Id, pbi: Value_Id) -> bool {
    bb := inst_block(bi);
    pred := inst_block(pbi);
    _, common, opc, invert := should_fold_cond_branches_to_common_destination_tti(s, bi, pbi);
    b: Irb;
    irb_set_before(*b, pbi);
    annot := block_terminator(bb);
    if invert {
        // InvertBranch(PBI, Builder)
        nc := op(pbi, 0);
        if num_uses(nc) == 1 && is_inst(nc) && (inst_op(nc) == .ICMP || inst_op(nc) == .FCMP) inst(nc).pred = cmp_inverse(inst(nc).pred);
        else { nc = irb_not(*b, nc, tprint("%.not", vname(nc))); copy_annotation_from(nc, annot); }
        set_op(pbi, 0, nc);
        condbr_swap_successors(pbi);
    }
    unique_succ := ifx get_successor(pbi, 0) == bb then get_successor(bi, 0) else get_successor(bi, 1);
    add_predecessor_to_block(unique_succ, pred, bb);
    mdw: [..] u64; mdw.allocator = temp;
    ph, pt, pf := prof_extract_branch_weights_2(pbi);
    sh, st, sf := prof_extract_branch_weights_2(bi);
    if ph || sh {
        if !ph { pt = 1; pf = 1; }
        if !sh { st = 1; sf = 1; }
        if get_successor(pbi, 0) == bb {
            array_add(*mdw, pt * st);
            array_add(*mdw, pf * (sf + st) + pt * sf);
        } else {
            array_add(*mdw, pt * (sf + st) + pf * st);
            array_add(*mdw, pf * sf);
        }
        prof_set_fitted_branch_weights(pbi, mdw, false, true);
    } else set_metadata(pbi, md_kind(MD_PROF_NAME), NONE);
    set_successor(pbi, ifx get_successor(pbi, 0) != bb then cast(u32) 1 else 0, unique_succ);
    if s.dtu { ups := Dom_Update.[.{true, pred, unique_succ}, .{false, pred, bb}]; dtu_apply(s.dtu, ups); }
    lmd := get_metadata(bi, MD_LOOP_KIND);
    if lmd != NONE set_metadata(pbi, MD_LOOP_KIND, lmd);
    vm: Table(Value_Id, Value_Id); vm.allocator = temp;
    clone_instructions_into_predecessor_block_and_update_ssa_uses(bb, pred, *vm);
    if inst(bi).records {
        cloned: [..] u32; cloned.allocator = temp;
        clone_debug_info_from(block_terminator(pred), bi, inst(bi).records, *cloned);
        remap_dbg_records(cloned, *vm);
    }
    found, bic := table_find(*vm, op(bi, 0));
    if !found bic = NONE;   // VMap[BI->getCondition()]: a null mapping for values not cloned
    if bic == NONE bic = op(bi, 0);
    nc := create_logical_op(*b, opc, op(pbi, 0), bic, "or.cond", annot);
    set_op(pbi, 0, nc);
    if is_inst(nc) && inst_op(nc) == .SELECT && mdw.count {
        w := u64.[mdw[0], mdw[1]];
        prof_set_fitted_branch_weights(nc, w, false, true);
    }
    return true;
}
is_vector_op :: (i: Value_Id) -> bool {
    if is_vector_type(vtype(i)) return true;
    for k: 0..cast(s64) nops(i) - 1 if is_vector_type(vtype(op(i, cast(u32) k))) return true;
    return false;
}

// llvm::FoldBranchToCommonDest(BI, DTU, MSSAU = null, TTI, AC, BonusInstThreshold)
fold_branch_to_common_dest :: (s: *Scfg, bi: Value_Id, bonus_inst_threshold: s64) -> bool {
    bb := inst_block(bi);
    kind := ifx fn_has_min_size(block_fn(bb)) then TCK_CODE_SIZE else TCK_SIZE_AND_LATENCY;
    c := op(bi, 0);
    if !is_inst(c) return false;
    co := inst_op(c);
    if !(co == .ICMP || co == .FCMP || is_binary_op(co) || co == .SELECT || co == .TRUNC) || inst_block(c) != bb || num_uses(c) != 1 return false;
    if succ_contains(bb, bb) return false;
    preds_all: [..] Value_Id; preds_all.allocator = temp;
    block_predecessors(bb, *preds_all);
    preds: [..] Value_Id; preds.allocator = temp;
    for p: preds_all {
        pbi := block_terminator(p);
        if inst_op(pbi) != .CONDBR || !scfg_safe_to_merge_terminators(bi, pbi) continue;
        ok, _, opc, invert := should_fold_cond_branches_to_common_destination_tti(s, bi, pbi);
        if !ok continue;
        if s.tti {
            ty := vtype(op(bi, 0));
            cost := tti_arith_cost(s.tti, opc, ty, kind);
            pc := op(pbi, 0);
            if invert && (num_uses(pc) != 1 || !(is_inst(pc) && (inst_op(pc) == .ICMP || inst_op(pc) == .FCMP)))
                cost = cost_add(cost, tti_arith_cost(s.tti, .XOR, ty, kind));
            if cost > scfg_cl.branch_fold_threshold continue;
        }
        array_add(*preds, p);
    }
    if preds.count == 0 return false;
    num_bonus := 0;
    saw_vector := false;
    pred_count := preds.count;
    cxt: Value_Id = ifx pred_count == 1 then block_terminator(preds[0]) else NONE;
    for i: block_insts(bb) {
        if i == c continue;
        if inst_op(i) == .BR || inst_op(i) == .CONDBR continue;
        if is_pseudo_probe(i) continue;
        if !is_safe_to_speculatively_execute_cx(i, cxt, s.opts.ac) return false;
        saw_vector |= is_vector_op(i);
        if !s.tti || tti_instruction_cost(s.tti, i, kind) != TCC_FREE {
            num_bonus += pred_count;
            if num_bonus > bonus_inst_threshold * scfg_cl.branch_fold_to_common_dest_vector_multiplier return false;
        }
        u := ir.v_first_use[i];
        while u != NONE {
            ui := ir.u_user[u];
            ok: bool;
            if inst_op(ui) == .PHI ok = ir.u_aux[u] == bb;
            else ok = inst_block(ui) == bb && comes_before(i, ui);
            if !ok return false;
            u = ir.u_next[u];
        }
    }
    if num_bonus > bonus_inst_threshold * ifx saw_vector then scfg_cl.branch_fold_to_common_dest_vector_multiplier else 1 return false;
    return perform_branch_to_common_dest_folding_full(s, bi, block_terminator(preds[0]));
}

// hoistConditionalLoadsStores(BI, SpeculatedConditionalLoadsStores, Invert (-1 = nullopt, 0/1), Sel)
hoist_conditional_loads_stores :: (bi: Value_Id, lss: [] Value_Id, invert: s64, sel: Value_Id) {
    vcond_ty := type_vector(1, ir.t_i1, false);
    cond := op(bi, 0);
    bb := inst_block(bi);
    mask: Value_Id = NONE; mask_false: Value_Id = NONE; mask_true: Value_Id = NONE;
    if invert >= 0 {
        b: Irb; irb_set_before(*b, ifx sel != NONE then sel else lss[lss.count - 1]);
        c := ifx invert == 1 then irb_binop(*b, .XOR, cond, const_int(ir.t_i1, 1)) else cond;
        mask = irb_bitcast(*b, c, vcond_ty);
    } else {
        b: Irb; irb_set_before(*b, bi);
        mask_false = irb_bitcast(*b, irb_binop(*b, .XOR, cond, const_int(ir.t_i1, 1)), vcond_ty);
        mask_true = irb_bitcast(*b, cond, vcond_ty);
    }
    peek :: (v: Value_Id) -> Value_Id {
        x := v;
        while is_inst(x) && inst_op(x) == .BITCAST x = op(x, 0);
        return x;
    }
    for i: lss {
        b: Irb; irb_set_before(*b, ifx invert >= 0 then i else bi);
        if invert < 0 mask = ifx inst_block(i) == get_successor(bi, 0) then mask_true else mask_false;
        o0 := op(i, 0);
        mls: Value_Id;
        if inst_op(i) == .LOAD {
            ty := vtype(i);
            pn: Value_Id = NONE;
            pass_thru: Value_Id = NONE;
            if invert >= 0 {
                u := ir.v_first_use[i];
                while u != NONE {
                    usr := ir.u_user[u];
                    if inst_op(usr) == .PHI {
                        pn = usr;
                        pass_thru = irb_bitcast(*b, peek(phi_incoming_value_for_block(pn, bb)), type_vector(1, ty, false));
                    } else if sel != NONE && inst_block(usr) == bb {
                        irb_set_before(*b, usr);
                    }
                    u = ir.u_next[u];
                }
            }
            vty := type_vector(1, ty, false);
            if pass_thru == NONE pass_thru = const_poison(vty);
            mls = irb_intrinsic(*b, "llvm.masked.load", .[vty, vtype(o0)], .[o0, mask, pass_thru]);
            add_param_align(mls, 0, inst(i).align);
            nls := irb_bitcast(*b, mls, ty);
            if pn != NONE phi_set_value(pn, cast(u32) phi_block_index(pn, bb), nls);
            rauw_with_metadata(i, nls);
        } else {
            sv := irb_bitcast(*b, peek(o0), type_vector(1, vtype(o0), false));
            mls = irb_intrinsic(*b, "llvm.masked.store", .[vtype(sv), vtype(op(i, 1))], .[sv, op(i, 1), mask]);
            add_param_align(mls, 1, inst(i).align);
        }
        rng := get_metadata(i, md_kind("range"));
        if rng != NONE call_add_range_ret_attr(mls, cr_from_range_md(rng));
        drop_ub_implying_attrs_and_unknown_metadata(i, false, MD_ANNOTATION_KIND);
        // at::deleteAssignmentMarkers(I), then drop the DIAssignID attachment
        aid := get_metadata(i, md_kind_id("DIAssignID"));
        if aid != NONE {
            for * rec, ri: ir.dbg_records if rec.kind == .ASSIGN && rec.assign_id == aid && rec.owner != NONE dbgr_erase(cast(u32) (ri + 1));
            set_metadata(i, md_kind_id("DIAssignID"), NONE);
        }
        copy_metadata(mls, i);
        erase_inst_with_metadata(i);
    }
}
