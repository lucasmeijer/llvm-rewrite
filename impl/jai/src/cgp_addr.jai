// CodeGenPrepare, part 2: addressing modes. Port of llvm/lib/CodeGen/CodeGenPrepare.cpp: ExtAddrMode,
// TypePromotionTransaction (its actions are rows of `Cgp_Tpa` with a kind; undo is a switch), PhiNodeSet,
// SimplificationTracker, AddressingModeCombiner, AddressingModeMatcher (matchScaledValue, matchOperationAddr,
// matchAddr, valueAlreadyLiveAtInst, isProfitableToFoldIntoAddressingMode, isPromotionProfitable),
// TypePromotionHelper, FindAllMemoryUses, IsNonLocalValue, findInsertPos and optimizeMemoryInst.

// ---------------------------------------------------------------- ExtAddrMode

Cgp_Addr_Mode :: struct {
    base_gv: Value_Id = NONE;
    base_offs: s64;
    has_base_reg: bool;
    scale: s64;
    base_reg: Value_Id = NONE;
    scaled_reg: Value_Id = NONE;
    original_value: Value_Id = NONE;
    in_bounds := true;
}
AMF_NO :: 0x00; AMF_BASE_REG :: 0x01; AMF_BASE_GV :: 0x02; AMF_BASE_OFFS :: 0x04; AMF_SCALED_REG :: 0x08; AMF_SCALE :: 0x10;
AMF_MULTIPLE :: 0xff;

am_replace_with :: (am: *Cgp_Addr_Mode, from: Value_Id, to: Value_Id) { if am.scaled_reg == from am.scaled_reg = to; }

am_compare :: (a: *Cgp_Addr_Mode, o: *Cgp_Addr_Mode) -> u32 {
    if a.base_reg != NONE && o.base_reg != NONE && vtype(a.base_reg) != vtype(o.base_reg) return AMF_MULTIPLE;
    if a.base_gv != NONE && o.base_gv != NONE && vtype(a.base_gv) != vtype(o.base_gv) return AMF_MULTIPLE;
    if a.scaled_reg != NONE && o.scaled_reg != NONE && vtype(a.scaled_reg) != vtype(o.scaled_reg) return AMF_MULTIPLE;
    if a.in_bounds != o.in_bounds return AMF_MULTIPLE;
    r: u32 = AMF_NO;
    if a.base_reg != o.base_reg r |= AMF_BASE_REG;
    if a.base_gv != o.base_gv r |= AMF_BASE_GV;
    if a.base_offs != o.base_offs r |= AMF_BASE_OFFS;
    if a.scaled_reg != o.scaled_reg r |= AMF_SCALED_REG;
    if a.scale != 0 && o.scale != 0 && a.scale != o.scale r |= AMF_SCALE;
    n := 0;
    x := r;
    while x { n += cast(int)(x & 1); x >>= 1; }
    if n > 1 return AMF_MULTIPLE;
    return r;
}
am_is_trivial :: (a: *Cgp_Addr_Mode) -> bool { return a.base_offs == 0 && a.scale == 0 && !(a.base_gv != NONE && a.base_reg != NONE); }
am_get_field_as_value :: (a: *Cgp_Addr_Mode, field: u32, int_ptr_ty: Type_Id) -> Value_Id {
    if field == {
        case AMF_BASE_REG; return a.base_reg;
        case AMF_BASE_GV; return a.base_gv;
        case AMF_SCALED_REG; return a.scaled_reg;
        case AMF_BASE_OFFS; return const_int(int_ptr_ty, cast,no_check(u64) a.base_offs);
    }
    return NONE;
}
am_set_combined_field :: (a: *Cgp_Addr_Mode, field: u32, v: Value_Id, modes: [] Cgp_Addr_Mode) {
    if field == {
        case AMF_BASE_REG; a.base_reg = v;
        case AMF_BASE_GV; a.base_reg = v; a.base_gv = NONE;
        case AMF_SCALED_REG;
            a.scaled_reg = v;
            if a.scale == 0 for modes if it.scale != 0 { a.scale = it.scale; break; }
        case AMF_BASE_OFFS;
            a.scaled_reg = v; a.scale = 1; a.base_offs = 0;
        case; fatal("codegenprepare: unhandled address-mode field");
    }
}

// TargetLowering::isLegalAddressingMode (X86TargetLowering)
cgp_is_legal_addressing_mode :: (am: *Cgp_Addr_Mode, access_ty: Type_Id, as: u32) -> bool {
    return x86_is_legal_addressing_mode(cgp.xl, access_ty, am.base_gv, am.base_offs, am.has_base_reg, am.scale, as);
}

// ---------------------------------------------------------------- TypePromotionTransaction

Cgp_Tpa_Kind :: enum u8 { SET_OPERAND; TRUNC_BUILDER; SEXT_BUILDER; ZEXT_BUILDER; TYPE_MUTATOR; USES_REPLACER; INSTRUCTION_REMOVER; }
Cgp_Tpa :: struct {
    kind: Cgp_Tpa_Kind;
    inst: Value_Id;
    // SET_OPERAND
    idx: u32; origin: Value_Id;
    // builders
    val: Value_Id;
    // TYPE_MUTATOR
    orig_ty: Type_Id;
    // USES_REPLACER (also the replacer of INSTRUCTION_REMOVER when has_replacer)
    uses_user: [..] Value_Id; uses_idx: [..] u32; dbg_users: [..] u32; new: Value_Id;
    // INSTRUCTION_REMOVER: InsertionHandler, OperandsHider
    has_prev: bool; prev_inst: Value_Id; bb: Value_Id; before_rec: u32;
    hidden: [..] Value_Id;
    has_replacer: bool;
}
cgp_tpt: [..] Cgp_Tpa;   // TypePromotionTransaction::Actions (one transaction at a time)

tpt_restoration_point :: () -> s64 { return cgp_tpt.count; }
tpt_push :: (a: Cgp_Tpa) { array_add(*cgp_tpt, a); }

// setOperand
tpt_set_operand :: (i: Value_Id, idx: u32, v: Value_Id) {
    a: Cgp_Tpa; a.kind = .SET_OPERAND; a.inst = i; a.idx = idx;
    a.origin = op(i, idx);
    set_op(i, idx, v);
    tpt_push(a);
}
// UsesReplacer's constructor (into `a`)
tpa_replace_uses :: (a: *Cgp_Tpa, i: Value_Id, new: Value_Id) {
    a.new = new;
    a.uses_user.allocator = temp; a.uses_idx.allocator = temp; a.dbg_users.allocator = temp;
    u := ir.v_first_use[i];
    while u != NONE { array_add(*a.uses_user, ir.u_user[u]); array_add(*a.uses_idx, use_operand_no(u)); u = ir.u_next[u]; }
    find_dbg_users(inst_fn_or_none(i), i, *a.dbg_users, true);
    rauw_with_metadata(i, new);
}
inst_fn_or_none :: (i: Value_Id) -> Value_Id { if inst_block(i) == NONE return cgp.f; return inst_fn(i); }
tpa_replace_uses_undo :: (a: *Cgp_Tpa, i: Value_Id) {
    for a.uses_user set_op(it, a.uses_idx[it_index], i);
    for a.dbg_users dbgr_replace_variable_location_op(it, a.new, i);
}
tpt_replace_all_uses_with :: (i: Value_Id, new: Value_Id) {
    a: Cgp_Tpa; a.kind = .USES_REPLACER; a.inst = i;
    tpa_replace_uses(*a, i, new);
    tpt_push(a);
}
tpt_mutate_type :: (i: Value_Id, t: Type_Id) {
    a: Cgp_Tpa; a.kind = .TYPE_MUTATOR; a.inst = i; a.orig_ty = vtype(i);
    ir.v_type[i] = t;
    tpt_push(a);
}
// TruncBuilder: IRBuilder<> at Opnd, no debug location, "promoted"
tpt_create_trunc :: (opnd: Value_Id, t: Type_Id) -> Value_Id {
    b: Irb; irb_set_before(*b, opnd); b.dbg = NONE;
    v := irb_cast(*b, .TRUNC, opnd, t, "promoted");
    a: Cgp_Tpa; a.kind = .TRUNC_BUILDER; a.inst = opnd; a.val = v;
    tpt_push(a);
    return v;
}
// SExtBuilder: IRBuilder<> at InsertPt (its debug location), "promoted"
tpt_create_sext :: (insert_pt: Value_Id, opnd: Value_Id, t: Type_Id) -> Value_Id {
    b: Irb; irb_set_before(*b, insert_pt);
    v := irb_cast(*b, .SEXT, opnd, t, "promoted");
    a: Cgp_Tpa; a.kind = .SEXT_BUILDER; a.inst = insert_pt; a.val = v;
    tpt_push(a);
    return v;
}
// ZExtBuilder: IRBuilder<> at InsertPt, no debug location, "promoted"
tpt_create_zext :: (insert_pt: Value_Id, opnd: Value_Id, t: Type_Id) -> Value_Id {
    b: Irb; irb_set_before(*b, insert_pt); b.dbg = NONE;
    v := irb_cast(*b, .ZEXT, opnd, t, "promoted");
    a: Cgp_Tpa; a.kind = .ZEXT_BUILDER; a.inst = insert_pt; a.val = v;
    tpt_push(a);
    return v;
}

// Instruction::removeFromParent: the name leaves the function's symbol table (the Value keeps it), debug records
// fall onto the next instruction
cgp_remove_from_parent :: (i: Value_Id) {
    n := vname(i);
    if n.count {
        st := value_symtab(i);
        if st >= 0 {
            found, v := table_find(*ir.symtabs[st], n);
            if found && v == i table_remove(*ir.symtabs[st], n);
        }
    }
    if inst(i).records {
        nx := inst_next(i);
        if nx == NONE fatal("codegenprepare: removing a terminator with debug records");
        records_prepend(nx, records_take(i));
    }
    inst_unlink(i);
}
// re-adding the name of a re-linked instruction (ValueSymbolTable::reinsertValue)
cgp_reinsert_name :: (i: Value_Id) {
    n := vname(i);
    if n.count == 0 return;
    st := value_symtab(i);
    if st < 0 return;
    found, v := table_find(*ir.symtabs[st], n);
    if found && v == i return;
    ir.v_name[i] = "";
    set_name(i, n);
}

// eraseInstruction (InstructionRemover)
tpt_erase_instruction :: (i: Value_Id, new: Value_Id = NONE) {
    a: Cgp_Tpa; a.kind = .INSTRUCTION_REMOVER; a.inst = i;
    // InsertionHandler
    bb := inst_block(i);
    a.has_prev = i != block_first(bb);
    nx := inst_next(i);
    a.before_rec = ifx nx != NONE then inst(nx).records else 0;   // getDbgReinsertionPosition
    if a.has_prev a.prev_inst = inst_prev(i); else a.bb = bb;
    // OperandsHider
    a.hidden.allocator = temp;
    n := nops(i);
    for k: 0..cast(s64) n - 1 {
        v := op(i, cast(u32) k);
        array_add(*a.hidden, v);
        set_op(i, cast(u32) k, const_poison(vtype(v)));
    }
    if new != NONE { a.has_replacer = true; tpa_replace_uses(*a, i, new); }
    table_set(*cgp_removed_set, i, true);
    array_add(*cgp.removed_insts, i);
    cgp_remove_from_parent(i);
    tpt_push(a);
}
cgp_removed_set: Table(Value_Id, bool);

// InsertionHandler::insert
tpa_reinsert :: (a: *Cgp_Tpa, i: Value_Id) {
    if a.has_prev {
        if inst_block(i) != NONE inst_unlink(i);
        inst_insert_after(i, a.prev_inst);
    } else {
        pos := block_first_insertion_pt(a.bb);
        if inst_block(i) != NONE inst_move_before_dbg(i, pos);
        else insert_at_position(i, a.bb, pos, true);
    }
    cgp_reinsert_name(i);
    // reinsertInstInDbgRecords(Inst, BeforeDbgRecord)
    nx := inst_next(i);
    if nx == NONE || inst(nx).records == 0 return;
    if a.before_rec == 0 {
        records_prepend(i, records_take(nx));
        return;
    }
    // the records of nx in front of before_rec fell from i
    first := inst(nx).records;
    if first == a.before_rec return;
    x := first;
    while dbgr(x).next != a.before_rec && dbgr(x).next != 0 x = dbgr(x).next;
    if dbgr(x).next == 0 return;
    dbgr(x).next = 0;
    inst(nx).records = a.before_rec;
    y := first;
    while y != 0 { dbgr(y).owner = i; y = dbgr(y).next; }
    records_append(i, first);
}

tpa_undo :: (a: *Cgp_Tpa) {
    if a.kind == {
        case .SET_OPERAND; set_op(a.inst, a.idx, a.origin);
        case .TRUNC_BUILDER; #through;
        case .SEXT_BUILDER; #through;
        case .ZEXT_BUILDER;
            if is_inst(a.val) erase_inst_with_metadata(a.val);
        case .TYPE_MUTATOR; ir.v_type[a.inst] = a.orig_ty;
        case .USES_REPLACER; tpa_replace_uses_undo(a, a.inst);
        case .INSTRUCTION_REMOVER;
            tpa_reinsert(a, a.inst);
            if a.has_replacer tpa_replace_uses_undo(a, a.inst);
            for a.hidden set_op(a.inst, cast(u32) it_index, it);
            table_remove(*cgp_removed_set, a.inst);
            for cgp.removed_insts if it == a.inst { array_ordered_remove_by_index(*cgp.removed_insts, it_index); break; }
    }
}
// commit
tpt_commit :: () -> bool {
    modified := cgp_tpt.count > 0;
    cgp_tpt.count = 0;
    return modified;
}
// rollback(Point)
tpt_rollback :: (point: s64) {
    while cgp_tpt.count > point {
        a := cgp_tpt[cgp_tpt.count - 1];
        cgp_tpt.count -= 1;
        tpa_undo(*a);
    }
}
// `for (Instruction *I : RemovedInsts) I->deleteValue()`: the removed instructions die
cgp_delete_removed_insts :: () {
    for i: cgp.removed_insts {
        if vkind(i) == .DEAD continue;
        scev_note_erase(i);
        vh_note_erase(i);
        if vname(i).count ir.v_name[i] = "";
        drop_all_references(i);
        ir.v_md[i] = NONE;
        ir.v_kind[i] = .DEAD;
    }
    cgp.removed_insts.count = 0;
    table_reset(*cgp_removed_set);
}

// ---------------------------------------------------------------- PhiNodeSet / SimplificationTracker

Cgp_Phi_Set :: struct {
    list: [..] Value_Id;
    map: Table(Value_Id, s64);
    first_valid: s64;
}
phiset_init :: (s: *Cgp_Phi_Set) { s.list.allocator = temp; s.map.allocator = temp; }
phiset_insert :: (s: *Cgp_Phi_Set, p: Value_Id) -> bool {
    if table_contains(*s.map, p) return false;
    table_set(*s.map, p, s.list.count);
    array_add(*s.list, p);
    return true;
}
phiset_skip :: (s: *Cgp_Phi_Set, cur: *s64) {
    while cur.* < s.list.count {
        found, idx := table_find(*s.map, s.list[cur.*]);
        if found && idx == cur.* break;
        cur.* += 1;
    }
}
phiset_erase :: (s: *Cgp_Phi_Set, p: Value_Id) -> bool {
    if !table_contains(*s.map, p) return false;
    table_remove(*s.map, p);
    phiset_skip(s, *s.first_valid);
    return true;
}
phiset_begin :: (s: *Cgp_Phi_Set) -> s64 {
    if s.first_valid == 0 phiset_skip(s, *s.first_valid);
    return s.first_valid;
}
phiset_next :: (s: *Cgp_Phi_Set, cur: s64) -> s64 { c := cur + 1; phiset_skip(s, *c); return c; }
phiset_size :: (s: *Cgp_Phi_Set) -> s64 { return s.map.count; }
phiset_count :: (s: *Cgp_Phi_Set, p: Value_Id) -> bool { return table_contains(*s.map, p); }

Cgp_Simpl_Tracker :: struct {
    storage: Table(Value_Id, Value_Id);
    all_phis: Cgp_Phi_Set;
    all_selects: [..] Value_Id;   // SmallPtrSet: only counted and destroyed
}
st_get :: (st: *Cgp_Simpl_Tracker, v_in: Value_Id) -> Value_Id {
    v := v_in;
    while true {
        found, n := table_find(*st.storage, v);
        if !found return v;
        v = n;
    }
    return v;
}
st_put :: (st: *Cgp_Simpl_Tracker, from: Value_Id, to: Value_Id) { if !table_contains(*st.storage, from) table_set(*st.storage, from, to); }
st_replace_phi :: (st: *Cgp_Simpl_Tracker, from_in: Value_Id, to_in: Value_Id) {
    from := from_in; to := to_in;
    old := st_get(st, from);
    while old != from {
        from = to;
        to = ifx is_phi(old) then old else NONE;
        old = st_get(st, from);
    }
    st_put(st, from, to);
    rauw_with_metadata(from, to);
    phiset_erase(*st.all_phis, from);
    erase_inst_with_metadata(from);
}
st_destroy_new_nodes :: (st: *Cgp_Simpl_Tracker, common_ty: Type_Id) {
    dummy := const_poison(common_ty);
    c := phiset_begin(*st.all_phis);
    while c < st.all_phis.list.count {
        i := st.all_phis.list[c];
        rauw_with_metadata(i, dummy);
        erase_inst_with_metadata(i);
        c = phiset_next(*st.all_phis, c);
    }
    st.all_phis.list.count = 0; table_reset(*st.all_phis.map); st.all_phis.first_valid = 0;
    for st.all_selects {
        rauw_with_metadata(it, dummy);
        erase_inst_with_metadata(it);
    }
    st.all_selects.count = 0;
}

// ---------------------------------------------------------------- AddressingModeCombiner

Cgp_Am_Combiner :: struct {
    modes: [..] Cgp_Addr_Mode;
    different_field: u32 = AMF_NO;
    all_trivial := true;
    common_type: Type_Id = NONE;
    original: Value_Id;
    common_value: Value_Id = NONE;
}

amc_add_new_addr_mode :: (c: *Cgp_Am_Combiner, nm: *Cgp_Addr_Mode) -> bool {
    c.all_trivial = c.all_trivial && am_is_trivial(nm);
    if c.modes.count == 0 { array_add(*c.modes, nm.*); return true; }
    this_field := am_compare(*c.modes[0], nm);
    if c.different_field == AMF_NO c.different_field = this_field;
    else if c.different_field != this_field c.different_field = AMF_MULTIPLE;
    can := c.different_field != AMF_MULTIPLE;
    can = can && c.different_field != AMF_SCALE;
    can = can && (c.different_field != AMF_BASE_OFFS || nm.scaled_reg == NONE);
    can = can && (c.different_field != AMF_BASE_GV || !nm.has_base_reg);
    if can array_add(*c.modes, nm.*);
    else c.modes.count = 0;
    return can;
}

amc_combine_addr_modes :: (c: *Cgp_Am_Combiner) -> bool {
    if c.modes.count == 0 return false;
    if c.modes.count == 1 || c.different_field == AMF_NO return true;
    if c.all_trivial return false;
    if !amc_combining_allowed(c) return false;
    map: Table(Value_Id, Value_Id); map.allocator = temp;
    if !amc_initialize_map(c, *map) return false;
    c.common_value = amc_find_common(c, *map);
    if c.common_value != NONE am_set_combined_field(*c.modes[0], c.different_field, c.common_value, c.modes);
    return c.common_value != NONE;
}
// ~AddressingModeCombiner: eraseCommonValueIfDead
amc_destroy :: (c: *Cgp_Am_Combiner) {
    if c.common_value != NONE && vkind(c.common_value) != .DEAD && !has_uses(c.common_value) && is_inst(c.common_value)
        erase_inst_with_metadata(c.common_value);
}
amc_combining_allowed :: (c: *Cgp_Am_Combiner) -> bool {
    if cgp_cl.disable_complex_addr_modes return false;
    if c.different_field == {
        case AMF_BASE_REG; return cgp_cl.addr_sink_combine_base_reg;
        case AMF_BASE_GV; return cgp_cl.addr_sink_combine_base_gv;
        case AMF_BASE_OFFS; return cgp_cl.addr_sink_combine_base_offs;
        case AMF_SCALED_REG; return cgp_cl.addr_sink_combine_scaled_reg;
    }
    return false;
}
amc_initialize_map :: (c: *Cgp_Am_Combiner, map: *Table(Value_Id, Value_Id)) -> bool {
    null_values: [..] Value_Id; null_values.allocator = temp;
    int_ptr_ty := dl_int_ptr_type(vtype(c.modes[0].original_value));
    for * am: c.modes {
        dv := am_get_field_as_value(am, c.different_field, int_ptr_ty);
        if dv != NONE {
            t := vtype(dv);
            if c.common_type != NONE && c.common_type != t return false;
            c.common_type = t;
            table_set(map, am.original_value, dv);
        } else array_add(*null_values, am.original_value);
    }
    for null_values table_set(map, it, const_null_value(c.common_type));
    return true;
}
amc_find_common :: (c: *Cgp_Am_Combiner, map: *Table(Value_Id, Value_Id)) -> Value_Id {
    st: Cgp_Simpl_Tracker;
    st.storage.allocator = temp; phiset_init(*st.all_phis); st.all_selects.allocator = temp;
    traverse: [..] Value_Id; traverse.allocator = temp;
    amc_insert_placeholders(c, map, *traverse, *st);
    amc_fill_placeholders(map, *traverse, *st);
    if !cgp_cl.addr_sink_new_selects && st.all_selects.count > 0 {
        st_destroy_new_nodes(*st, c.common_type);
        return NONE;
    }
    not_matched: u32 = 0;
    if !amc_match_phi_set(*st, cgp_cl.addr_sink_new_phis, *not_matched) {
        st_destroy_new_nodes(*st, c.common_type);
        return NONE;
    }
    _, v := table_find(map, c.original);
    return st_get(*st, v);
}

Phi_Pair :: struct { a: Value_Id; b: Value_Id; }

amc_match_phi_node :: (phi: Value_Id, cand: Value_Id, matcher: *[..] Phi_Pair, to_match: *Cgp_Phi_Set) -> bool {
    worklist: [..] Phi_Pair; worklist.allocator = temp;
    pp_insert :: (m: *[..] Phi_Pair, p: Phi_Pair) { for m.* if it.a == p.a && it.b == p.b return; array_add(m, p); }
    pp_contains :: (m: [] Phi_Pair, p: Phi_Pair) -> bool { for m if it.a == p.a && it.b == p.b return true; return false; }
    pp_insert(matcher, .{phi, cand});
    matched: [..] Value_Id; matched.allocator = temp;
    array_add(*matched, phi);
    array_add(*worklist, .{phi, cand});
    visited: [..] Phi_Pair; visited.allocator = temp;
    while worklist.count {
        item := pop(*worklist);
        if pp_contains(visited, item) continue;
        array_add(*visited, item);
        n := nops(item.a);
        for k: 0..cast(s64) n - 1 {
            b := phi_block(item.a, cast(u32) k);
            first := phi_incoming_value_for_block(item.a, b);
            second := phi_incoming_value_for_block(item.b, b);
            if first == second continue;
            if !is_phi(first) || !is_phi(second) || !phiset_count(to_match, first) || inst_block(first) != inst_block(second) return false;
            if pp_contains(matcher.*, .{first, second}) continue;
            already := false;
            for matched if it == first { already = true; break; }
            if !already { array_add(*matched, first); pp_insert(matcher, .{first, second}); }
            array_add(*worklist, .{first, second});
        }
    }
    return true;
}

amc_match_phi_set :: (st: *Cgp_Simpl_Tracker, allow_new_phis: bool, not_matched: *u32) -> bool {
    matched: [..] Phi_Pair; matched.allocator = temp;
    will_not_match: [..] Value_Id; will_not_match.allocator = temp;
    to_match := *st.all_phis;
    while phiset_size(to_match) {
        phi := to_match.list[phiset_begin(to_match)];
        will_not_match.count = 0;
        array_add(*will_not_match, phi);
        is_matched := false;
        for p: block_insts(inst_block(phi)) {
            if inst_op(p) != .PHI break;
            if phiset_count(to_match, p) continue;
            is_matched = amc_match_phi_node(phi, p, *matched, to_match);
            if is_matched break;
            for matched {
                dup := false;
                for w: will_not_match if w == it.a { dup = true; break; }
                if !dup array_add(*will_not_match, it.a);
            }
            matched.count = 0;
        }
        if is_matched {
            for matched st_replace_phi(st, it.a, it.b);
            matched.count = 0;
            continue;
        }
        if !allow_new_phis return false;
        not_matched.* += cast(u32) will_not_match.count;
        for will_not_match phiset_erase(to_match, it);
    }
    return true;
}

amc_fill_placeholders :: (map: *Table(Value_Id, Value_Id), traverse: *[..] Value_Id, st: *Cgp_Simpl_Tracker) {
    while traverse.count {
        cur := pop(traverse);
        _, v := table_find(map, cur);
        if inst_op(v) == .SELECT {
            tv := op(cur, 1);
            _, mt := table_find(map, tv);
            set_op(v, 1, st_get(st, mt));
            fv := op(cur, 2);
            _, mf := table_find(map, fv);
            set_op(v, 2, st_get(st, mf));
        } else {
            preds: [..] Value_Id; preds.allocator = temp;
            block_predecessors(inst_block(v), *preds);
            for b: preds {
                pv := phi_incoming_value_for_block(cur, b);
                _, mp := table_find(map, pv);
                phi_add_incoming(v, st_get(st, mp), b);
            }
        }
    }
}

amc_insert_placeholders :: (c: *Cgp_Am_Combiner, map: *Table(Value_Id, Value_Id), traverse: *[..] Value_Id, st: *Cgp_Simpl_Tracker) {
    worklist: [..] Value_Id; worklist.allocator = temp;
    dummy := const_poison(c.common_type);
    array_add(*worklist, c.original);
    while worklist.count {
        cur := pop(*worklist);
        if table_contains(map, cur) continue;
        array_add(traverse, cur);
        if inst_op(cur) == .SELECT {
            // SelectInst::Create(Cond, Dummy, Dummy, Name, InsertBefore = CurrentSelect, MDFrom = CurrentSelect)
            s := create_select(op(cur, 0), dummy, dummy);
            insert_at_position(s, inst_block(cur), cur, false);
            set_name(s, vname(cur));
            copy_metadata_kinds(s, cur, .[md_kind_id("prof"), md_kind_id("unpredictable")]);
            table_set(map, cur, s);
            array_add(*st.all_selects, s);
            array_add(*worklist, op(cur, 1));
            array_add(*worklist, op(cur, 2));
        } else {
            n := nops(cur);
            p := create_phi(c.common_type, n);
            insert_at_position(p, inst_block(cur), cur, false);
            set_name(p, "sunk_phi");
            table_set(map, cur, p);
            phiset_insert(*st.all_phis, p);
            for k: 0..cast(s64) n - 1 array_add(*worklist, phi_value(cur, cast(u32) k));
        }
    }
}

// ---------------------------------------------------------------- AddressingModeMatcher

Cgp_Am_Matcher :: struct {
    addr_mode_insts: *[..] Value_Id;
    access_ty: Type_Id;
    addr_space: u32;
    memory_inst: Value_Id;
    am: *Cgp_Addr_Mode;
    large_offset_gep: *Cgp_Gep_Off;
    ignore_profitability: bool;
}

// AddressingModeMatcher::Match
cgp_am_match :: (v: Value_Id, access_ty: Type_Id, as: u32, mi: Value_Id, insts: *[..] Value_Id, lgep: *Cgp_Gep_Off) -> Cgp_Addr_Mode {
    result: Cgp_Addr_Mode;
    m: Cgp_Am_Matcher;
    m.addr_mode_insts = insts; m.access_ty = access_ty; m.addr_space = as; m.memory_inst = mi; m.am = *result;
    m.large_offset_gep = lgep;
    ok := am_match_addr(*m, v, 0);
    if !ok fatal("codegenprepare: Couldn't select *anything*?");
    return result;
}

am_match_scaled_value :: (m: *Cgp_Am_Matcher, scale_reg: Value_Id, scale: s64, depth: u32) -> bool {
    if scale == 1 return am_match_addr(m, scale_reg, depth);
    if scale == 0 return true;
    if m.am.scale != 0 && m.am.scaled_reg != scale_reg return false;
    test := m.am.*;
    test.scale += scale;
    test.scaled_reg = scale_reg;
    if !cgp_is_legal_addressing_mode(*test, m.access_ty, m.addr_space) return false;
    m.am.* = test;
    if is_inst(scale_reg) {
        ok, add_lhs, ci := pm_binop(scale_reg, .ADD);
        if ok && vkind(ci) == .C_INT && !cgp_is_iv_increment(scale_reg) {
            cv := const_ap(ci);
            if ap_is_signed_int_n(cv, 64) {
                test.in_bounds = false;
                test.scaled_reg = add_lhs;
                test.base_offs += ap_sext_value(cv) * test.scale;
                if cgp_is_legal_addressing_mode(*test, m.access_ty, m.addr_space) {
                    array_add(m.addr_mode_insts, scale_reg);
                    m.am.* = test;
                    return true;
                }
                test = m.am.*;
            }
        }
    }
    if m.am.base_offs != 0 {
        ok, iv_inc, step := am_get_constant_step(scale_reg);
        if ok {
            offset := ap_mul(step, ap_from_u64(step.bits, cast,no_check(u64) m.am.scale));
            if ap_is_signed_int_n(offset, 64) {
                test.in_bounds = false;
                test.scaled_reg = iv_inc;
                test.base_offs -= cast,no_check(s64) ap_limited_value(offset);
                if cgp_is_legal_addressing_mode(*test, m.access_ty, m.addr_space) && dt_dominates_inst(cgp_get_dt(), iv_inc, m.memory_inst) {
                    array_add(m.addr_mode_insts, iv_inc);
                    m.am.* = test;
                    return true;
                }
                test = m.am.*;
            }
        }
    }
    return true;
}
// GetConstantStep -> (ok, IVInc, Step)
am_get_constant_step :: (v: Value_Id) -> (bool, Value_Id, APInt) {
    z: APInt;
    if !is_phi(v) return false, NONE, z;
    ok, inc, step := cgp_get_iv_increment(v);
    if !ok return false, NONE, z;
    o := inst_op(inc);
    if (o == .ADD || o == .SUB || o == .MUL || o == .SHL) && (inst(inc).flags & (F_NSW | F_NUW)) != 0 return false, NONE, z;
    if vkind(step) == .C_INT return true, inc, const_ap(step);
    return false, NONE, z;
}
// MightBeFoldableInst
cgp_might_be_foldable_inst :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .BITCAST || o == .ADDRSPACECAST {
        if vtype(i) == vtype(op(i, 0)) return false;
        k := type_kind(vtype(i));
        return k == .INT || k == .PTR;
    }
    if o == .PTRTOINT || o == .INTTOPTR || o == .ADD || o == .GEP return true;
    if o == .MUL || o == .SHL return vkind(op(i, 1)) == .C_INT;
    return false;
}

// TargetLoweringBase::InstructionOpcodeToISD with LLVM's 0 for the opcodes that have no node
cgp_instruction_opcode_to_isd :: (o: Opcode) -> u32 {
    if is_terminator(o) || o == .ALLOCA || o == .GEP || o == .FENCE || o == .CMPXCHG || o == .ATOMICRMW || o == .PHI ||
       o == .CALL || o == .USEROP1 || o == .USEROP2 || o == .VAARG || o == .LANDINGPAD || o == .CATCHPAD || o == .CLEANUPPAD return 0;
    if o == .EXTRACTVALUE || o == .INSERTVALUE fatal("codegenprepare: InstructionOpcodeToISD(MERGE_VALUES) is not supported yet");
    return isd_of_opcode(o);
}
// isPromotedInstructionLegal
cgp_is_promoted_instruction_legal :: (v: Value_Id) -> bool {
    if !is_inst(v) return false;
    isd := cgp_instruction_opcode_to_isd(inst_op(v));
    if isd == 0 return true;
    return cgp_is_operation_legal_or_custom(isd, cgp_evt(vtype(v)));
}

// TargetLoweringBase::isExtFree(const Instruction *I) (X86: isZExtFree(Type, Type); isExtFreeImpl false)
cgp_is_ext_free :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .ZEXT && cgp_is_zext_free(vtype(op(i, 0)), vtype(i)) return true;
    if o == .FPEXT fatal("codegenprepare: isExtFree(fpext) is not supported yet");
    return false;
}

// ---------------------------------------------------------------- TypePromotionHelper

tph_add_promoted_inst :: (ext_opnd: Value_Id, is_sext: bool) {
    ext_ty: u8 = ifx is_sext then cast(u8) CGP_SEXT else cast(u8) CGP_ZEXT;
    found, e := table_find(*cgp.promoted_insts, ext_opnd);
    if found {
        if e.ext == ext_ty return;
        ext_ty = CGP_BOTH_EXT;
    }
    table_set(*cgp.promoted_insts, ext_opnd, .{vtype(ext_opnd), ext_ty});
}
tph_get_orig_type :: (opnd: Value_Id, is_sext: bool) -> Type_Id {
    ext_ty: u8 = ifx is_sext then cast(u8) CGP_SEXT else cast(u8) CGP_ZEXT;
    found, e := table_find(*cgp.promoted_insts, opnd);
    if found && e.ext == ext_ty return e.ty;
    return NONE;
}
tph_can_get_through :: (i: Value_Id, considered_ext_ty: Type_Id, is_sext: bool) -> bool {
    if is_vector_type(vtype(i)) return false;
    o := inst_op(i);
    if o == .ZEXT return true;
    if is_sext && o == .SEXT return true;
    if is_binary_op(o) && (o == .ADD || o == .SUB || o == .MUL || o == .SHL) {
        f := inst(i).flags;
        if (!is_sext && (f & F_NUW) != 0) || (is_sext && (f & F_NSW) != 0) return true;
    }
    if o == .AND || o == .OR return true;
    if o == .XOR {
        c := op(i, 1);
        if vkind(c) == .C_INT && !ap_is_all_ones(const_ap(c)) return true;
    }
    if o == .LSHR && !is_sext return true;
    if o == .SHL && has_one_use(i) {
        ext_inst := ir.u_user[ir.v_first_use[i]];
        if has_one_use(ext_inst) {
            and_inst := ir.u_user[ir.v_first_use[ext_inst]];
            if is_inst(and_inst) && inst_op(and_inst) == .AND {
                c := op(and_inst, 1);
                if vkind(c) == .C_INT && ap_is_int_n(const_ap(c), type_bits(vtype(i))) return true;
            }
        }
    }
    if o != .TRUNC return false;
    opnd_val := op(i, 0);
    if type_kind(vtype(opnd_val)) != .INT || type_bits(vtype(opnd_val)) > type_bits(considered_ext_ty) return false;
    if !is_inst(opnd_val) return false;
    opnd_type := tph_get_orig_type(opnd_val, is_sext);
    if opnd_type != NONE { }
    else if (is_sext && inst_op(opnd_val) == .SEXT) || (!is_sext && inst_op(opnd_val) == .ZEXT) opnd_type = vtype(op(opnd_val, 0));
    else return false;
    return type_bits(vtype(i)) >= type_bits(opnd_type);
}

Tph_Action :: enum u8 { NONE; TRUNC_AND_ANY_EXT; SEXT_OTHER; ZEXT_OTHER; }

tph_get_action :: (ext: Value_Id) -> Tph_Action {
    ext_opnd := op(ext, 0);
    ext_ty := vtype(ext);
    is_sext := inst_op(ext) == .SEXT;
    if !is_inst(ext_opnd) || !tph_can_get_through(ext_opnd, ext_ty, is_sext) return .NONE;
    eo := inst_op(ext_opnd);
    if eo == .TRUNC && table_contains(*cgp.inserted_insts, ext_opnd) return .NONE;
    if eo == .SEXT || eo == .TRUNC || eo == .ZEXT return .TRUNC_AND_ANY_EXT;
    if !has_one_use(ext_opnd) && !cgp_is_truncate_free(ext_ty, vtype(ext_opnd)) return .NONE;
    return ifx is_sext then Tph_Action.SEXT_OTHER else .ZEXT_OTHER;
}

// the Action function pointer: one switch
tph_run :: (a: Tph_Action, ext: Value_Id, created_cost: *u32, exts: *[..] Value_Id, truncs: *[..] Value_Id) -> Value_Id {
    if a == {
        case .TRUNC_AND_ANY_EXT; return tph_promote_operand_for_trunc_and_any_ext(ext, created_cost, exts, truncs);
        case .SEXT_OTHER; return tph_promote_operand_for_other(ext, created_cost, exts, truncs, true);
        case .ZEXT_OTHER; return tph_promote_operand_for_other(ext, created_cost, exts, truncs, false);
    }
    return NONE;
}

tph_promote_operand_for_trunc_and_any_ext :: (sext: Value_Id, created_cost: *u32, exts: *[..] Value_Id, truncs: *[..] Value_Id) -> Value_Id {
    sext_opnd := op(sext, 0);
    ext_val := sext;
    has_merged_non_free_ext := false;
    if inst_op(sext_opnd) == .ZEXT {
        has_merged_non_free_ext = !cgp_is_ext_free(sext_opnd);
        zext := tpt_create_zext(sext, op(sext_opnd, 0), vtype(sext));
        tpt_replace_all_uses_with(sext, zext);
        tpt_erase_instruction(sext);
        ext_val = zext;
    } else {
        tpt_set_operand(sext, 0, op(sext_opnd, 0));
    }
    created_cost.* = 0;
    if !has_uses(sext_opnd) tpt_erase_instruction(sext_opnd);
    ext_inst := ifx is_inst(ext_val) then ext_val else NONE;
    if ext_inst == NONE || vtype(ext_inst) != vtype(op(ext_inst, 0)) {
        if ext_inst != NONE {
            if exts array_add(exts, ext_inst);
            created_cost.* = ifx !cgp_is_ext_free(ext_inst) && !has_merged_non_free_ext then cast(u32) 1 else 0;
        }
        return ext_val;
    }
    next_val := op(ext_inst, 0);
    tpt_erase_instruction(ext_inst, next_val);
    return next_val;
}

tph_promote_operand_for_other :: (ext: Value_Id, created_cost: *u32, exts: *[..] Value_Id, truncs: *[..] Value_Id, is_sext: bool) -> Value_Id {
    ext_opnd := op(ext, 0);
    created_cost.* = 0;
    if !has_one_use(ext_opnd) {
        trunc := tpt_create_trunc(ext, vtype(ext_opnd));
        if is_inst(trunc) {
            // moveAfter(ExtOpnd): Instruction::moveAfter -> moveBeforeImpl(next(ExtOpnd)) with preserve=false
            inst_move_after(trunc, ext_opnd);
            if truncs array_add(truncs, trunc);
        }
        tpt_replace_all_uses_with(ext_opnd, trunc);
        tpt_set_operand(ext, 0, ext_opnd);
    }
    tph_add_promoted_inst(ext_opnd, is_sext);
    tpt_mutate_type(ext_opnd, vtype(ext));
    tpt_replace_all_uses_with(ext, ext_opnd);
    n := nops(ext_opnd);
    for k: 0..cast(s64) n - 1 {
        kk := cast(u32) k;
        if vtype(op(ext_opnd, kk)) == vtype(ext) || (inst_op(ext_opnd) == .SELECT && kk == 0) continue;
        opnd := op(ext_opnd, kk);
        if vkind(opnd) == .C_INT {
            bw := type_bits(vtype(ext));
            cv := const_ap(opnd);
            nv := ifx is_sext then ap_sext(cv, bw) else ap_zext(cv, bw);
            tpt_set_operand(ext_opnd, kk, const_int_ap(vtype(ext), nv));
            continue;
        }
        if vkind(opnd) == .C_UNDEF || vkind(opnd) == .C_POISON {
            // isa<UndefValue> (poison too): UndefValue::get(Ext->getType())
            tpt_set_operand(ext_opnd, kk, const_undef(vtype(ext)));
            continue;
        }
        v := ifx is_sext then tpt_create_sext(ext_opnd, opnd, vtype(ext)) else tpt_create_zext(ext_opnd, opnd, vtype(ext));
        tpt_set_operand(ext_opnd, kk, v);
        if !is_inst(v) continue;
        if exts array_add(exts, v);
        created_cost.* += ifx !cgp_is_ext_free(v) then cast(u32) 1 else 0;
    }
    tpt_erase_instruction(ext);
    return ext_opnd;
}

// Instruction::moveAfter(MovePos): moveBeforeImpl(*MovePos->getParent(), std::next(MovePos), Preserve = false)
inst_move_after :: (i: Value_Id, pos: Value_Id) {
    nx := inst_next(pos);
    if nx == i return;   // already there
    if nx != NONE inst_move_before_dbg(i, nx);
    else { inst_unlink(i); block_append_inst(inst_block(pos), i); }
}

am_is_promotion_profitable :: (new_cost: u32, old_cost: u32, promoted: Value_Id) -> bool {
    if new_cost > old_cost return false;
    if new_cost < old_cost return true;
    return cgp_is_promoted_instruction_legal(promoted);
}

// matchOperationAddr (AddrInst is an instruction or a constant expression)
am_match_operation_addr :: (m: *Cgp_Am_Matcher, addr_inst: Value_Id, opc: Opcode, depth: u32, moved_away: *bool = null) -> bool {
    if depth >= 5 return false;
    if moved_away moved_away.* = false;
    if opc == {
        case .PTRTOINT;
            return am_match_addr(m, op(addr_inst, 0), depth);
        case .INTTOPTR;
            as := ptr_addrspace(vtype(addr_inst));
            ptr_vt := evt_int(cast(u32) dl_type_size_bits(type_ptr(as)));
            if evt_eq(cgp_evt(vtype(op(addr_inst, 0))), ptr_vt) return am_match_addr(m, op(addr_inst, 0), depth);
            return false;
        case .BITCAST;
            st := vtype(op(addr_inst, 0));
            k := type_kind(st);
            if (k == .INT || k == .PTR) && st != vtype(addr_inst) return am_match_addr(m, op(addr_inst, 0), depth);
            return false;
        case .ADDRSPACECAST;
            // X86TargetMachine::isNoopAddrSpaceCast: SrcAS < 256 && DestAS < 256
            src_as := ptr_addrspace(vtype(op(addr_inst, 0)));
            dst_as := ptr_addrspace(vtype(addr_inst));
            if src_as < 256 && dst_as < 256 return am_match_addr(m, op(addr_inst, 0), depth);
            return false;
        case .ADD;
            backup := m.am.*;
            old_size := m.addr_mode_insts.count;
            last_known_good := tpt_restoration_point();
            first: u32 = 0; second: u32 = 1;
            if vkind(op(addr_inst, first)) == .C_INT && vkind(op(addr_inst, second)) != .C_INT { first = 1; second = 0; }
            m.am.in_bounds = false;
            if am_match_addr(m, op(addr_inst, first), depth + 1) && am_match_addr(m, op(addr_inst, second), depth + 1) return true;
            m.am.* = backup;
            m.addr_mode_insts.count = old_size;
            tpt_rollback(last_known_good);
            if am_match_addr(m, op(addr_inst, second), depth + 1) && am_match_addr(m, op(addr_inst, first), depth + 1) return true;
            m.am.* = backup;
            m.addr_mode_insts.count = old_size;
            tpt_rollback(last_known_good);
        case .MUL; #through;
        case .SHL;
            m.am.in_bounds = false;
            rhs := op(addr_inst, 1);
            if vkind(rhs) != .C_INT || type_bits(vtype(rhs)) > 64 return false;
            cv := const_ap(rhs);
            scale: s64;
            if opc == .SHL {
                lim := ap_limited_value(cv);
                if lim > cast(u64) (cv.bits - 1) lim = cast(u64) (cv.bits - 1);
                scale = cast,no_check(s64) ((cast(u64) 1) << lim);
            } else scale = ap_sext_value(cv);
            return am_match_scaled_value(m, op(addr_inst, 0), scale, depth);
        case .GEP;
            return am_match_gep(m, addr_inst, depth);
        case .SEXT; #through;
        case .ZEXT;
            if !is_inst(addr_inst) return false;
            ext := addr_inst;
            tph := tph_get_action(ext);
            if tph == .NONE return false;
            last_known_good := tpt_restoration_point();
            created_cost: u32 = 0;
            ext_cost: u32 = ifx !cgp_is_ext_free(ext) then cast(u32) 1 else 0;
            promoted := tph_run(tph, ext, *created_cost, null, null);
            if moved_away moved_away.* = true;
            backup := m.am.*;
            old_size := m.addr_mode_insts.count;
            if !am_match_addr(m, promoted, depth) ||
               !am_is_promotion_profitable(created_cost, ext_cost + cast(u32) (m.addr_mode_insts.count - old_size), promoted) {
                m.am.* = backup;
                m.addr_mode_insts.count = old_size;
                tpt_rollback(last_known_good);
                return false;
            }
            am_replace_with(m.am, ext, promoted);
            return true;
        case .CALL;
            if is_inst(addr_inst) && call_iid(addr_inst) == IID_THREADLOCAL_ADDRESS {
                if cgp_addressing_mode_supports_tls(call_arg(addr_inst, 0)) return am_match_addr(m, op(addr_inst, 0), depth);
            }
    }
    return false;
}

am_match_gep :: (m: *Cgp_Am_Matcher, addr_inst: Value_Id, depth: u32) -> bool {
    variable_operand: s64 = -1;
    variable_scale: s64 = 0;
    constant_offset: s64 = 0;
    is_ce := !is_inst(addr_inst);
    src_ty := ifx is_ce then cexpr(addr_inst).ty2 else inst(addr_inst).ty2;
    flags := opr_flags(addr_inst);
    cur_ty := src_ty;   // gep_type_iterator: the type indexed by operand i
    n := nops(addr_inst);
    for i: 1..cast(s64) n - 1 {
        idx := op(addr_inst, cast(u32) i);
        if i == 1 {
            // the first index steps over the source element type
            ts := dl_type_alloc_size(src_ty);
            if !am_gep_seq(m, idx, i, ts, *constant_offset, *variable_operand, *variable_scale) return false;
            continue;
        }
        if type_kind(cur_ty) == .STRUCT {
            k := const_int_zext(idx);
            constant_offset += cast(s64) dl_struct_offset(cur_ty, cast(u32) k);
            cur_ty = type_sub(cur_ty, cast(u32) k);
        } else {
            et := type_elem(cur_ty);
            if type_kind(cur_ty) == .SVECTOR return false;
            ts := dl_type_alloc_size(et);
            if !am_gep_seq(m, idx, i, ts, *constant_offset, *variable_operand, *variable_scale) return false;
            cur_ty = et;
            continue;
        }
    }
    in_bounds := (flags & F_INBOUNDS) != 0;
    if variable_operand == -1 {
        m.am.base_offs += constant_offset;
        if am_match_addr(m, op(addr_inst, 0), depth + 1) {
            if !in_bounds m.am.in_bounds = false;
            return true;
        }
        m.am.base_offs -= constant_offset;
        // EnableGEPOffsetSplit && TLI.shouldConsiderGEPOffsetSplit() (false on X86) -> no LargeOffsetGEP
        return false;
    }
    backup := m.am.*;
    old_size := m.addr_mode_insts.count;
    m.am.base_offs += constant_offset;
    if !in_bounds m.am.in_bounds = false;
    if !am_match_addr(m, op(addr_inst, 0), depth + 1) {
        if m.am.has_base_reg {
            m.am.* = backup;
            m.addr_mode_insts.count = old_size;
            return false;
        }
        m.am.has_base_reg = true;
        m.am.base_reg = op(addr_inst, 0);
    }
    if !am_match_scaled_value(m, op(addr_inst, cast(u32) variable_operand), variable_scale, depth) {
        m.am.* = backup;
        m.addr_mode_insts.count = old_size;
        if m.am.has_base_reg return false;
        m.am.has_base_reg = true;
        m.am.base_reg = op(addr_inst, 0);
        m.am.base_offs += constant_offset;
        if !am_match_scaled_value(m, op(addr_inst, cast(u32) variable_operand), variable_scale, depth) {
            m.am.* = backup;
            m.addr_mode_insts.count = old_size;
            return false;
        }
    }
    return true;
}
// a sequential GEP index with element stride `ts` (non-zero)
am_gep_seq :: (m: *Cgp_Am_Matcher, idx: Value_Id, i: s64, ts: u64, constant_offset: *s64, variable_operand: *s64, variable_scale: *s64) -> bool {
    if ts == 0 return true;
    if vkind(idx) == .C_INT {
        cv := const_ap(idx);
        if ap_significant_bits(cv) <= 64 {
            constant_offset.* += ap_sext_value(cv) * cast(s64) ts;
            return true;
        }
    }
    if variable_operand.* != -1 return false;
    variable_operand.* = i;
    variable_scale.* = cast(s64) ts;
    return true;
}

// matchAddr
am_match_addr :: (m: *Cgp_Am_Matcher, addr: Value_Id, depth: u32) -> bool {
    last_known_good := tpt_restoration_point();
    k := vkind(addr);
    if k == .C_INT {
        cv := const_ap(addr);
        if ap_is_signed_int_n(cv, 64) {
            c := ap_sext_value(cv);
            result: s64;
            overflow := add_overflow_s64(m.am.base_offs, c, *result);
            if !overflow {
                m.am.base_offs = result;
                if cgp_is_legal_addressing_mode(m.am, m.access_ty, m.addr_space) return true;
                m.am.base_offs -= c;
            }
        }
    } else if is_global_value(k) {
        if m.am.base_gv == NONE {
            m.am.base_gv = addr;
            if cgp_is_legal_addressing_mode(m.am, m.access_ty, m.addr_space) return true;
            m.am.base_gv = NONE;
        }
    } else if k == .INST {
        backup := m.am.*;
        old_size := m.addr_mode_insts.count;
        moved_away := false;
        if am_match_operation_addr(m, addr, inst_op(addr), depth, *moved_away) {
            if moved_away return true;
            if has_one_use(addr) || am_is_profitable_to_fold_into_addressing_mode(m, addr, *backup, m.am) {
                array_add(m.addr_mode_insts, addr);
                return true;
            }
            m.am.* = backup;
            m.addr_mode_insts.count = old_size;
            tpt_rollback(last_known_good);
        }
    } else if k == .C_EXPR {
        if am_match_operation_addr(m, addr, cexpr(addr).op, depth) return true;
        tpt_rollback(last_known_good);
    } else if k == .C_NULL && type_kind(vtype(addr)) == .PTR {
        return true;
    }
    if !m.am.has_base_reg {
        m.am.has_base_reg = true;
        m.am.base_reg = addr;
        if cgp_is_legal_addressing_mode(m.am, m.access_ty, m.addr_space) return true;
        m.am.has_base_reg = false;
        m.am.base_reg = NONE;
    }
    if m.am.scale == 0 {
        m.am.scale = 1;
        m.am.scaled_reg = addr;
        if cgp_is_legal_addressing_mode(m.am, m.access_ty, m.addr_space) return true;
        m.am.scale = 0;
        m.am.scaled_reg = NONE;
    }
    tpt_rollback(last_known_good);
    return false;
}
add_overflow_s64 :: (a: s64, b: s64, r: *s64) -> bool {
    s := cast,no_check(s64) (cast,no_check(u64) a + cast,no_check(u64) b);
    r.* = s;
    return (a >= 0 && b >= 0 && s < 0) || (a < 0 && b < 0 && s >= 0);
}

// FindAllMemoryUses -> true when a non-foldable use is found
Cgp_Mem_Use :: struct { u: Use_Id; ty: Type_Id; }
cgp_find_all_memory_uses :: (i: Value_Id, uses: *[..] Cgp_Mem_Use, considered: *Table(Value_Id, bool), seen: *u64) -> bool {
    if table_contains(considered, i) return false;
    table_set(considered, i, true);
    if !cgp_might_be_foldable_inst(i) return true;
    u := ir.v_first_use[i];
    while u != NONE {
        defer u = ir.u_next[u];
        old := seen.*;
        seen.* += 1;
        if old >= cgp_cl.max_address_users_to_scan return true;
        user := ir.u_user[u];
        o := inst_op(user);
        if o == .LOAD { array_add(uses, .{u, vtype(user)}); continue; }
        if o == .STORE {
            if use_operand_no(u) != 1 return true;
            array_add(uses, .{u, vtype(op(user, 0))});
            continue;
        }
        if o == .ATOMICRMW {
            if use_operand_no(u) != 0 return true;
            array_add(uses, .{u, vtype(op(user, 1))});
            continue;
        }
        if o == .CMPXCHG {
            if use_operand_no(u) != 0 return true;
            array_add(uses, .{u, vtype(op(user, 1))});
            continue;
        }
        if o == .CALL && call_iid(user) != NOT_INTRINSIC {
            // TLI.getAddrModeArguments: false on X86
            return true;
        }
        if o == .CALL {
            if call_has_fn_attr(user, .Cold) {
                // shouldOptimizeForSize(CI->getParent(), PSI, BFI): false without a profile / size attributes
                if !fn_has_fn_attr(cgp.f, .MinSize) && !fn_has_fn_attr(cgp.f, .OptimizeForSize) continue;
            }
            if vkind(call_callee(user)) != .INLINE_ASM return true;
            fatal("codegenprepare: inline asm memory operands (IsOperandAMemoryOperand) are not supported yet");
        }
        if cgp_find_all_memory_uses(user, uses, considered, seen) return true;
    }
    return false;
}

// valueAlreadyLiveAtInst
am_value_already_live_at_inst :: (m: *Cgp_Am_Matcher, v: Value_Id, k1: Value_Id, k2: Value_Id) -> bool {
    if v == NONE || v == k1 || v == k2 return true;
    k := vkind(v);
    if k != .INST && k != .ARGUMENT return true;
    if k == .INST && inst_op(v) == .ALLOCA && is_static_alloca(v) return true;
    // Value::isUsedInBasicBlock
    bb := inst_block(m.memory_inst);
    u := ir.v_first_use[v];
    while u != NONE {
        usr := ir.u_user[u];
        if is_inst(usr) && inst_block(usr) == bb return true;
        u = ir.u_next[u];
    }
    return false;
}

// isProfitableToFoldIntoAddressingMode
am_is_profitable_to_fold_into_addressing_mode :: (m: *Cgp_Am_Matcher, i: Value_Id, before: *Cgp_Addr_Mode, after: *Cgp_Addr_Mode) -> bool {
    if m.ignore_profitability return true;
    base_reg := after.base_reg; scaled_reg := after.scaled_reg;
    if am_value_already_live_at_inst(m, base_reg, before.base_reg, before.scaled_reg) base_reg = NONE;
    if am_value_already_live_at_inst(m, scaled_reg, before.base_reg, before.scaled_reg) scaled_reg = NONE;
    if base_reg == NONE && scaled_reg == NONE return true;
    uses: [..] Cgp_Mem_Use; uses.allocator = temp;
    considered: Table(Value_Id, bool); considered.allocator = temp;
    seen: u64 = 0;
    if cgp_find_all_memory_uses(i, *uses, *considered, *seen) return false;
    matched: [..] Value_Id; matched.allocator = temp;
    for p: uses {
        address := ir.u_val[p.u];
        user_i := ir.u_user[p.u];
        as := ptr_addrspace(vtype(address));
        result: Cgp_Addr_Mode;
        lgep: Cgp_Gep_Off;
        last_known_good := tpt_restoration_point();
        sub: Cgp_Am_Matcher;
        sub.addr_mode_insts = *matched; sub.access_ty = p.ty; sub.addr_space = as; sub.memory_inst = user_i;
        sub.am = *result; sub.large_offset_gep = *lgep;
        sub.ignore_profitability = true;
        if !am_match_addr(*sub, address, 0) fatal("codegenprepare: Couldn't select *anything*?");
        tpt_rollback(last_known_good);
        found := false;
        for matched if it == i { found = true; break; }
        if !found return false;
        matched.count = 0;
    }
    return true;
}

// ---------------------------------------------------------------- optimizeMemoryInst

cgp_is_non_local_value :: (v: Value_Id, bb: Value_Id) -> bool {
    if is_inst(v) return inst_block(v) != bb;
    return false;
}

// findInsertPos
cgp_find_insert_pos :: (addr: Value_Id, mi: Value_Id, sunk_addr: Value_Id) -> Value_Id {
    if has_one_use(addr) return mi;
    if sunk_addr != NONE && is_inst(sunk_addr) return inst_next(sunk_addr);
    earliest := mi;
    u := ir.v_first_use[addr];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if is_inst(usr) && inst_block(usr) == inst_block(mi) {
            if inst_op(usr) == .PHI || is_debug_or_pseudo_inst(usr) continue;
            if comes_before(usr, earliest) earliest = usr;
        }
    }
    return earliest;
}

// IRBuilder<> pieces used by the sinking code (ConstantFolder)
cgp_create_int_cast :: (b: *Irb, v: Value_Id, t: Type_Id, signed: bool, name: string) -> Value_Id {
    vb := type_bits(scalar_type(vtype(v))); tb := type_bits(scalar_type(t));
    opc := ifx vb == tb then Opcode.BITCAST else ifx vb > tb then Opcode.TRUNC else ifx signed then Opcode.SEXT else .ZEXT;
    if vtype(v) == t return v;
    return irb_cast(b, opc, v, t, name);
}
// CreatePointerCast
cgp_create_pointer_cast :: (b: *Irb, v: Value_Id, t: Type_Id, name := "") -> Value_Id {
    if vtype(v) == t return v;
    return irb_pointer_bitcast_or_addrspacecast(b, v, t, name);
}

cgp_optimize_memory_inst :: (mi: Value_Id, addr: Value_Id, access_ty: Type_Id, as: u32) -> bool {
    repl := addr;
    worklist: [..] Value_Id; worklist.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    array_add(*worklist, addr);
    phi_or_select_seen := false;
    addr_mode_insts: [..] Value_Id; addr_mode_insts.allocator = temp;
    modes: Cgp_Am_Combiner;
    modes.modes.allocator = temp;
    modes.original = addr;
    defer amc_destroy(*modes);
    cgp_tpt.count = 0;
    last_known_good := tpt_restoration_point();
    while worklist.count {
        v := pop(*worklist);
        if table_contains(*visited, v) continue;
        table_set(*visited, v, true);
        if is_phi(v) {
            for k: 0..cast(s64) nops(v) - 1 array_add(*worklist, phi_value(v, cast(u32) k));
            phi_or_select_seen = true;
            continue;
        }
        if is_inst(v) && inst_op(v) == .SELECT {
            array_add(*worklist, op(v, 2));
            array_add(*worklist, op(v, 1));
            phi_or_select_seen = true;
            continue;
        }
        addr_mode_insts.count = 0;
        lgep: Cgp_Gep_Off;
        lgep.gep = NONE;
        new_am := cgp_am_match(v, access_ty, as, mi, *addr_mode_insts, *lgep);
        // LargeOffsetGEP is never set on X86 (shouldConsiderGEPOffsetSplit is false)
        new_am.original_value = v;
        if !amc_add_new_addr_mode(*modes, *new_am) break;
    }
    if !amc_combine_addr_modes(*modes) {
        tpt_rollback(last_known_good);
        return false;
    }
    modified := tpt_commit();
    am := modes.modes[0];
    if !phi_or_select_seen {
        any_non_local := false;
        for addr_mode_insts if cgp_is_non_local_value(it, inst_block(mi)) { any_non_local = true; break; }
        if !any_non_local return modified;
    }
    sunk_addr: Value_Id = NONE;
    {
        found, h := table_find(*cgp.sunk_addrs, addr);
        if found { s := vh_get(h); if s != NONE && vkind(s) != .DEAD sunk_addr = s; }
    }
    int_ptr_ty := dl_int_ptr_type(vtype(addr));
    insert_pos := cgp_find_insert_pos(addr, mi, sunk_addr);
    if sunk_addr == NONE {
        dt := cgp_get_dt();
        if (am.base_reg != NONE && !cgp_dominates_value(dt, am.base_reg, insert_pos)) ||
           (am.scaled_reg != NONE && !cgp_dominates_value(dt, am.scaled_reg, insert_pos)) return modified;
    }
    b: Irb;
    irb_set_at(*b, inst_block(mi), insert_pos, false);
    if insert_pos == NONE b.dbg = NONE;
    if sunk_addr != NONE {
        if vtype(sunk_addr) != vtype(addr) {
            if ptr_addrspace(vtype(sunk_addr)) != ptr_addrspace(vtype(addr)) && !dl_is_non_integral_pointer_type(vtype(addr)) {
                sunk_addr = irb_cast(*b, .PTRTOINT, sunk_addr, int_ptr_ty, "sunkaddr");
                sunk_addr = irb_cast(*b, .INTTOPTR, sunk_addr, vtype(addr), "sunkaddr");
            } else sunk_addr = cgp_create_pointer_cast(*b, sunk_addr, vtype(addr));
        }
    } else if cgp_cl.addr_sink_using_geps {
        result_ptr, result_index: Value_Id = NONE;
        if am.base_reg != NONE && type_kind(vtype(am.base_reg)) == .PTR { result_ptr = am.base_reg; am.base_reg = NONE; }
        if am.scale != 0 && type_kind(vtype(am.scaled_reg)) == .PTR {
            if result_ptr != NONE || am.scale != 1 return modified;
            result_ptr = am.scaled_reg;
            am.scale = 0;
        }
        if am.scale != 0 {
            if type_bits(int_ptr_ty) > type_bits(vtype(am.scaled_reg)) return modified;
        }
        base_gv := am.base_gv;
        if base_gv != NONE {
            if result_ptr != NONE return modified;
            if gv_is_thread_local(base_gv) result_ptr = cgp_create_thread_local_address(*b, base_gv);
            else result_ptr = base_gv;
        }
        if !dl_is_non_integral_pointer_type(vtype(addr)) {
            if result_ptr == NONE && am.base_reg != NONE {
                result_ptr = irb_cast(*b, .INTTOPTR, am.base_reg, vtype(addr), "sunkaddr");
                am.base_reg = NONE;
            } else if result_ptr == NONE && am.scale == 1 {
                result_ptr = irb_cast(*b, .INTTOPTR, am.scaled_reg, vtype(addr), "sunkaddr");
                am.scale = 0;
            }
        }
        if result_ptr == NONE && am.base_reg == NONE && am.scale == 0 && am.base_offs == 0 {
            sunk_addr = const_null_value(vtype(addr));
        } else if result_ptr == NONE {
            return modified;
        } else {
            i8_ptr_ty := type_ptr(ptr_addrspace(vtype(addr)));
            gep_flags: u32 = ifx am.in_bounds then cast(u32) F_INBOUNDS else 0;
            if am.base_reg != NONE {
                v := am.base_reg;
                if vtype(v) != int_ptr_ty v = cgp_create_int_cast(*b, v, int_ptr_ty, true, "sunkaddr");
                result_index = v;
            }
            if am.scale != 0 {
                v := am.scaled_reg;
                if vtype(v) != int_ptr_ty v = irb_cast(*b, .TRUNC, v, int_ptr_ty, "sunkaddr");
                if am.scale != 1 v = irb_binop(*b, .MUL, v, const_int(int_ptr_ty, cast,no_check(u64) am.scale), "sunkaddr");
                if result_index != NONE result_index = irb_binop(*b, .ADD, result_index, v, "sunkaddr");
                else result_index = v;
            }
            if am.base_offs != 0 {
                v := const_int(int_ptr_ty, cast,no_check(u64) am.base_offs);
                if result_index != NONE {
                    if vtype(result_ptr) != i8_ptr_ty result_ptr = cgp_create_pointer_cast(*b, result_ptr, i8_ptr_ty);
                    result_ptr = irb_gep(*b, ir.t_i8, result_ptr, .[result_index], "sunkaddr", gep_flags);
                }
                result_index = v;
            }
            if result_index == NONE {
                if is_inst(result_ptr) && inst_block(result_ptr) != inst_block(mi) return modified;
                sunk_addr = result_ptr;
            } else {
                if vtype(result_ptr) != i8_ptr_ty result_ptr = cgp_create_pointer_cast(*b, result_ptr, i8_ptr_ty);
                sunk_addr = irb_gep(*b, ir.t_i8, result_ptr, .[result_index], "sunkaddr", gep_flags);
            }
            if vtype(sunk_addr) != vtype(addr) {
                if ptr_addrspace(vtype(sunk_addr)) != ptr_addrspace(vtype(addr)) && !dl_is_non_integral_pointer_type(vtype(addr)) {
                    sunk_addr = irb_cast(*b, .PTRTOINT, sunk_addr, int_ptr_ty, "sunkaddr");
                    sunk_addr = irb_cast(*b, .INTTOPTR, sunk_addr, vtype(addr), "sunkaddr");
                } else sunk_addr = cgp_create_pointer_cast(*b, sunk_addr, vtype(addr));
            }
        }
    } else {
        fatal("codegenprepare: -addr-sink-using-gep=false is not supported yet");
    }
    replace_uses_of_with(mi, repl, sunk_addr);
    h := vh_new(sunk_addr);
    table_set(*cgp.sunk_addrs, addr, h);
    if !has_uses(repl) {
        cgp_reset_iterator_if_invalidated_while_calling(cgp.cur_bb, repl, 0);
    }
    return true;
}

// DT.dominates(Value *Def, Instruction *User) for a BaseReg / ScaledReg (non-instructions dominate everything)
cgp_dominates_value :: (dt: *Dom_Tree, def: Value_Id, user: Value_Id) -> bool {
    if !is_inst(def) return true;
    return dt_dominates_inst(dt, def, user);
}

// APInt::isSignedIntN / isIntN
ap_is_signed_int_n :: (a: APInt, n: u32) -> bool { return ap_significant_bits(a) <= n; }
ap_is_int_n :: (a: APInt, n: u32) -> bool { return ap_active_bits(a) <= n; }

// X86TargetLowering::addressingModeSupportsTLS: x86-64 ELF with the LocalExec / InitialExec model
// (TargetMachine::getTLSModel)
cgp_addressing_mode_supports_tls :: (gv: Value_Id) -> bool {
    st := cgp.xl;
    if !(st_is64Bit(st) && !st_is_macho(st) && !st_is_coff(st)) return false;
    pie := module_flag("PIE Level") != NONE;
    shared := x86_reloc_model(st) == RELOC_PIC && !pie;
    local := x86_should_assume_dso_local(st, gv);
    // TLSModel: GeneralDynamic 0, LocalDynamic 1, InitialExec 2, LocalExec 3
    model := ifx shared then (ifx local then 1 else 0) else (ifx local then 3 else 2);
    sel := cast(int) glob(gv).tls - 1;
    if sel > model model = sel;
    return model == 2 || model == 3;
}

// IRBuilderBase::CreateThreadLocalAddress: the global's alignment on the argument and the result
cgp_create_thread_local_address :: (b: *Irb, gv: Value_Id) -> Value_Id {
    ci := irb_intrinsic(b, "llvm.threadlocal.address", .[vtype(gv)], .[gv]);
    a := glob(gv).align;
    if a != 0 {
        add_param_align(ci, 0, a);
        at: Attr; at.kind = .Alignment; at.ty = NONE; at.ival = a;
        call_add_ret_attr(ci, at);
    }
    return ci;
}
