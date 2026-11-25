// Assignment tracking helpers (#dbg_assign records linked to instructions through !DIAssignID).
// Ported from llvm/lib/IR/DebugInfo.cpp (at::getDVRAssignmentMarkers, at::deleteAssignmentMarkers, at::RAUW,
// at::remapAssignID, at::calculateFragmentIntersect), llvm/lib/IR/DebugInfoMetadata.cpp
// (DIExpression::calculateFragmentIntersect, DIExpression::FragmentInfo::intersect) and
// llvm/lib/IR/DebugProgramInstruction.cpp (DbgVariableRecord::setAssignId / setAddress / setKillAddress /
// isKillAddress / clone / insertAfter / moveBefore, createLinkedDVRAssign).
//
// Order of getDVRAssignmentMarkers: ReplaceableMetadataImpl::getAllDbgVariableRecordUsers of the DIAssignID, i.e.
// by descending use-map index of the DIAssignID operand (most recently tracked first). A record parsed from the
// input has its record index as that index; records created later have larger indices; setAssignId (and at::RAUW)
// re-track (a new, larger index). The stamps of the DIAssignID operand are kept apart from the location stamps
// (dbgr_stamp), because each tracked operand has its own use-map entry in LLVM.

at_assign_stamps: Table(u32, u64);

at_assign_stamp :: (r: u32) -> u64 {
    found, s := table_find(*at_assign_stamps, r);
    if found return s;
    return cast(u64) r;
}
at_assign_restamp :: (r: u32) { table_set(*at_assign_stamps, r, dbg_stamp_next); dbg_stamp_next += 1; }

// at::getDVRAssignmentMarkers(ID): the attached #dbg_assign records using `id`
at_markers_of_id :: (id: Md_Id, out: *[..] u32) {
    out.count = 0;
    if id == NONE return;
    for * rec, ri: ir.dbg_records {
        if rec.kind != .ASSIGN || rec.assign_id != id || rec.owner == NONE continue;
        array_add(out, cast(u32) (ri + 1));
    }
    // descending tracking index
    a := out.*;
    for i: 1..a.count-1 {
        x := a[i]; sx := at_assign_stamp(x);
        j := i - 1;
        while j >= 0 && at_assign_stamp(a[j]) < sx { a[j + 1] = a[j]; j -= 1; }
        a[j + 1] = x;
    }
}

// at::getDVRAssignmentMarkers(Inst)
at_markers :: (i: Value_Id, out: *[..] u32) {
    out.count = 0;
    id := get_metadata(i, md_fixed("DIAssignID"));
    if id == NONE return;
    at_markers_of_id(id, out);
}

at_has_markers :: (i: Value_Id) -> bool {
    m: [..] u32; m.allocator = temp;
    at_markers(i, *m);
    return m.count > 0;
}

// at::deleteAssignmentMarkers
at_delete_markers :: (i: Value_Id) {
    m: [..] u32; m.allocator = temp;
    at_markers(i, *m);
    for m dbgr_erase(it);
}

// DIAssignID::getDistinct
at_new_id :: () -> Md_Id { return di_get(.ASSIGN_ID, true, .[], .[]); }

// at::RAUW(Old, New): every instruction of the module with Old gets New, then Old->replaceAllUsesWith(New) (the
// records move over in their tracking order, re-tracked).
at_rauw :: (old: Md_Id, new: Md_Id) {
    if old == new return;
    k := md_fixed("DIAssignID");
    for f: ir.m_functions {
        if is_declaration(f) continue;
        for b: fn_blocks(f) for i: block_insts(b) if get_metadata(i, k) == old set_metadata(i, k, new);
    }
    users: [..] u32; users.allocator = temp;
    for * rec, ri: ir.dbg_records if rec.kind == .ASSIGN && rec.assign_id == old array_add(*users, cast(u32) (ri + 1));
    // ascending tracking index (ReplaceableMetadataImpl::replaceAllUsesWith sorts the uses by index)
    for i: 1..users.count-1 {
        x := users[i]; sx := at_assign_stamp(x);
        j := i - 1;
        while j >= 0 && at_assign_stamp(users[j]) > sx { users[j + 1] = users[j]; j -= 1; }
        users[j + 1] = x;
    }
    for users dbgr_set_assign_id(it, new);
}

// DbgVariableRecord::setAssignId
dbgr_set_assign_id :: (r: u32, id: Md_Id) {
    dbgr(r).assign_id = id;
    at_assign_restamp(r);
}

// DbgVariableRecord::setAddress
dbgr_set_address :: (r: u32, v: Value_Id) {
    dbgr(r).addr = md_value(v);
    if dbgr(r).owner != NONE dbgr_restamp(r);
    if dbg_index.fn != NONE dbgr_index_record(r);
}

// DbgVariableRecord::getAddress (NONE when the address is not a ValueAsMetadata)
dbgr_address :: (r: u32) -> Value_Id {
    a := dbgr(r).addr;
    if a == NONE || ir.mds[a].kind != .VALUE return NONE;
    return ir.mds[a].value;
}

// DbgVariableRecord::isKillAddress
dbgr_is_kill_address :: (r: u32) -> bool {
    a := dbgr_address(r);
    return a == NONE || is_undef_value(a);
}

// DbgVariableRecord::setKillAddress: the address becomes poison of its type
dbgr_set_kill_address :: (r: u32) {
    a := dbgr_address(r);
    if a == NONE fatal("internal: setKillAddress on a #dbg_assign without an address value");
    dbgr(r).addr = md_value(const_poison(vtype(a)));
}

// DbgVariableRecord::getVariableLocationOp(0) (getValue of a #dbg_assign); NONE for an MDNode location
dbgr_value :: (r: u32) -> Value_Id {
    loc := dbgr(r).loc;
    if loc == NONE return NONE;
    if ir.mds[loc].kind == .VALUE return ir.mds[loc].value;
    if is_di(loc, .ARG_LIST) {
        if ir.mds[loc].nops == 0 return NONE;
        o := md_op(loc, 0);
        if o != NONE && ir.mds[o].kind == .VALUE return ir.mds[o].value;
    }
    return NONE;
}

// hasArgList
dbgr_has_arg_list :: (r: u32) -> bool { return dbgr(r).loc != NONE && is_di(dbgr(r).loc, .ARG_LIST); }

// DbgRecord::clone: an unattached copy
dbgr_clone :: (r: u32) -> u32 {
    nr := dbgr(r).*;
    nr.next = 0;
    nr.owner = NONE;
    array_add(*ir.dbg_records, nr);
    return cast(u32) ir.dbg_records.count;
}

// A new unattached #dbg_assign (DbgVariableRecord::createDVRAssign)
dbgr_new_assign :: (val: Md_Id, var: Md_Id, expr: Md_Id, id: Md_Id, addr: Md_Id, addr_expr: Md_Id, dbg: Md_Id) -> u32 {
    nr: Dbg_Record;
    nr.kind = .ASSIGN;
    nr.loc = val; nr.var = var; nr.expr = expr; nr.assign_id = id; nr.addr = addr; nr.addr_expr = addr_expr; nr.dbg = dbg;
    array_add(*ir.dbg_records, nr);
    return cast(u32) ir.dbg_records.count;
}

dbgr_tracked :: (id: u32) {
    dbgr_restamp(id);
    if dbg_index.fn != NONE dbgr_index_record(id);
}

// DbgRecord::insertAfter(InsertAfter)
dbgr_insert_after_record :: (nr: u32, after: u32) {
    dbgr(nr).owner = dbgr(after).owner;
    dbgr(nr).next = dbgr(after).next;
    dbgr(after).next = nr;
}

// DbgRecord::insertBefore(InsertBefore)
dbgr_insert_before_record :: (nr: u32, before: u32) {
    o := dbgr(before).owner;
    dbgr(nr).owner = o;
    dbgr(nr).next = before;
    if inst(o).records == before { inst(o).records = nr; return; }
    x := inst(o).records;
    while dbgr(x).next != before x = dbgr(x).next;
    dbgr(x).next = nr;
}

// DbgRecord::moveBefore(MoveBefore)
dbgr_move_before_record :: (nr: u32, before: u32) {
    if dbgr(nr).owner != NONE dbgr_erase(nr);
    dbgr_insert_before_record(nr, before);
}

// BasicBlock::insertDbgRecordAfter(DR, I): at the head of the marker of the instruction after I
dbgr_insert_after_inst :: (nr: u32, i: Value_Id) {
    nx := inst(i).next;
    if nx == NONE fatal("internal: inserting a debug record after a block's last instruction is not supported yet");
    dbgr(nr).owner = nx;
    dbgr(nr).next = inst(nx).records;
    inst(nx).records = nr;
}

// DbgVariableRecord::createLinkedDVRAssign
at_create_linked_assign :: (linked: Value_Id, val: Value_Id, var: Md_Id, expr: Md_Id, addr: Value_Id, addr_expr: Md_Id, dbg: Md_Id) -> u32 {
    id := get_metadata(linked, md_fixed("DIAssignID"));
    assert(id != NONE, "createLinkedDVRAssign: the linked instruction has no DIAssignID");
    r := dbgr_new_assign(md_value(val), var, expr, id, md_value(addr), addr_expr, dbg);
    dbgr_insert_after_inst(r, linked);
    dbgr_tracked(r);
    return r;
}

// at::remapAssignID: give `i` (and the records attached to it) the IDs from `map`, creating new distinct ones
at_remap_assign_id :: (map: *Table(Md_Id, Md_Id), i: Value_Id) {
    get_new :: (map: *Table(Md_Id, Md_Id), old: Md_Id) -> Md_Id {
        found, n := table_find(map, old);
        if found return n;
        n = at_new_id();
        table_set(map, old, n);
        return n;
    }
    x := inst(i).records;
    while x != 0 {
        if dbgr(x).kind == .ASSIGN && dbgr(x).assign_id != NONE dbgr_set_assign_id(x, get_new(map, dbgr(x).assign_id));
        x = dbgr(x).next;
    }
    k := md_fixed("DIAssignID");
    id := get_metadata(i, k);
    if id != NONE set_metadata(i, k, get_new(map, id));
}

// DbgVariableRecord::getFragmentOrEntireVariable: (offset, size); size 0 if unknown
dbgr_fragment_or_entire_variable :: (r: u32) -> (u64, u64) {
    has, fo, fs := diexpr_fragment(dbgr(r).expr);
    if has return fo, fs;
    ok, sz := divar_size_bits(dbgr(r).var);
    if ok return 0, sz;
    return 0, 0;
}

Frag_Result :: struct { has: bool; offset: u64; size: u64; }   // std::optional<FragmentInfo>

// DIExpression::FragmentInfo::intersect
fragment_intersect :: (a_off: u64, a_size: u64, b_off: u64, b_size: u64) -> (u64, u64) {
    s := max(a_off, b_off);
    e := min(a_off + a_size, b_off + b_size);
    if e <= s return 0, 0;
    return s, e - s;
}

// DIExpression::calculateFragmentIntersect: (ok, result, offset from location in bits)
diexpr_calculate_fragment_intersect :: (slice_start: Value_Id, slice_off_bits: u64, slice_size_bits: u64, dbg_ptr: Value_Id,
                                        dbg_ptr_off_bits: s64, dbg_extract_off_bits: s64, var_off: u64, var_size: u64) -> (bool, Frag_Result, s64) {
    res: Frag_Result;
    if var_size == 0 return false, res, 0;
    okp, mem_off := pointer_offset_from(slice_start, dbg_ptr);
    if !okp return false, res, 0;
    mem_start := mem_off * 8 + cast,no_check(s64) slice_off_bits - (dbg_ptr_off_bits + dbg_extract_off_bits);
    off_from_loc := -mem_start;
    mem_end := mem_start + cast,no_check(s64) slice_size_bits;
    if mem_end < 0 { res.has = true; return true, res, off_from_loc; }
    mstart := mem_start + cast,no_check(s64) var_off;
    mend := mstart + cast,no_check(s64) slice_size_bits;
    fstart := max(0, mstart);
    fsize := max(0, mend - fstart);
    io, is := fragment_intersect(cast(u64) fstart, cast(u64) fsize, var_off, var_size);
    if !(io == var_off && is == var_size) { res.has = true; res.offset = io; res.size = is; }
    return true, res, off_from_loc;
}

// at::calculateFragmentIntersect(DL, Dest, SliceOffsetInBits, SliceSizeInBits, DVRAssign, Result)
at_calculate_fragment_intersect :: (dest: Value_Id, slice_off_bits: u64, slice_size_bits: u64, r: u32) -> (bool, Frag_Result) {
    res: Frag_Result;
    if dbgr_is_kill_address(r) return false, res;
    ok, off_bytes, _ := diexpr_extract_leading_offset(dbgr(r).addr_expr);
    if !ok return false, res;
    vo, vs := dbgr_fragment_or_entire_variable(r);
    ok2, rr, _ := diexpr_calculate_fragment_intersect(dest, slice_off_bits, slice_size_bits, dbgr_address(r), off_bytes * 8, 0, vo, vs);
    return ok2, rr;
}

// Instruction::mergeDIAssignID(SourceInstructions): one DIAssignID (the first of the sources', then k's) replaces
// the others on every attachment and record (at::RAUW)
merge_di_assign_id :: (k: Value_Id, sources: [] Value_Id) {
    kind := md_fixed("DIAssignID");
    ids: [..] Md_Id; ids.allocator = temp;
    for sources { a := get_metadata(it, kind); if a != NONE array_add(*ids, a); }
    b := get_metadata(k, kind); if b != NONE array_add(*ids, b);
    if ids.count == 0 return;
    merge := ids[0];
    for ids {
        if it_index == 0 || it == merge continue;
        // getAssignmentInsts also knows instructions that are not in a function (yet / any more)
        for s: sources if get_metadata(s, kind) == it set_metadata(s, kind, merge);
        if get_metadata(k, kind) == it set_metadata(k, kind, merge);
        at_rauw(it, merge);
    }
    set_metadata(k, kind, merge);
}

// ---------------------------------------------------------------- at::trackAssignments, AssignmentTrackingPass

// at::VarRecord: (variable, getDebugValueLoc of the record)
At_Var_Record :: struct { var: Md_Id; dl: Md_Id; }
// StorageToVarsMap entry: alloca -> SmallSetVector<VarRecord>
At_Storage_Vars :: struct { base: Value_Id; vars: [..] At_Var_Record; }

at_vars_insert :: (map: *[..] At_Storage_Vars, base: Value_Id, vr: At_Var_Record) {
    e: *At_Storage_Vars = null;
    for * map.* if it.base == base { e = it; break; }
    if !e { n: At_Storage_Vars; n.base = base; n.vars.allocator = temp; array_add(map, n); e = *map.*[map.count - 1]; }
    for e.vars if it.var == vr.var && it.dl == vr.dl return;
    array_add(*e.vars, vr);
}

At_Assignment_Info :: struct { ok: bool; base: Value_Id; offset_bits: u64; size_bits: u64; whole_alloca: bool; }

// getAssignmentInfoImpl
at_assignment_info_impl :: (dest: Value_Id, size_bits: u64, scalable: bool) -> At_Assignment_Info {
    r: At_Assignment_Info;
    if scalable return r;
    w := dl_index_type_size_bits(vtype(dest));
    off: u64 = 0;
    base := sv_strip_and_accumulate(dest, *off, w, true);
    if w > 0 && ((off >> (w - 1)) & 1) return r;   // GEPOffset.isNegative()
    if off == 0xFFFF_FFFF_FFFF_FFFF return r;
    if !(is_inst(base) && inst_op(base) == .ALLOCA) return r;
    aty := inst(base).ty2;
    if type_is_scalable(aty) return r;
    r.ok = true; r.base = base; r.offset_bits = off * 8; r.size_bits = size_bits;
    r.whole_alloca = r.offset_bits == 0 && size_bits == dl_type_size_bits(aty);
    return r;
}

// emitDbgAssign
at_emit_dbg_assign :: (info: At_Assignment_Info, val: Value_Id, dest: Value_Id, store_like: Value_Id, vr: At_Var_Record) {
    store_start := info.offset_bits;
    store_end := info.offset_bits + info.size_bits;
    frag_start := store_start; frag_end := store_end;
    whole := info.whole_alloca;
    ok, size := divar_size_bits(vr.var);
    if ok {
        frag_end = min(frag_end, size);
        if frag_start >= frag_end return;
        whole = frag_start <= 0 && frag_end >= size;
    }
    expr := diexpr_get(.[]);
    if !whole {
        okf, e := diexpr_create_fragment_expression(expr, frag_start, frag_end - frag_start);
        if !okf fatal("internal: trackAssignments failed to create a fragment expression");
        expr = e;
    }
    at_create_linked_assign(store_like, val, vr.var, expr, dest, diexpr_get(.[]), vr.dl);
}

// at::trackAssignments over the given blocks
at_track_assignments :: (blocks: [] Value_Id, vars: [] At_Storage_Vars) {
    if vars.count == 0 return;
    poison := const_poison(ir.t_i1);
    k_assign := md_fixed("DIAssignID");
    for bb: blocks for i: block_insts(bb) {
        info: At_Assignment_Info;
        val, dest: Value_Id;
        o := inst_op(i);
        if o == .ALLOCA {
            aty := inst(i).ty2;
            info = at_assignment_info_impl(i, dl_type_size_bits(aty), type_is_scalable(aty));
            val = poison; dest = i;
        } else if o == .STORE {
            vt := vtype(op(i, 0));
            info = at_assignment_info_impl(op(i, 1), dl_type_size_bits(vt), type_is_scalable(vt));
            val = op(i, 0); dest = op(i, 1);
        } else if o == .CALL && (is_memtransfer_intrinsic(i) || is_memset_intrinsic(i)) {
            len := call_arg(i, 2);
            if vkind(len) == .C_INT info = at_assignment_info_impl(call_arg(i, 0), 8 * const_int_zext(len), false);
            if is_memset_intrinsic(i) {
                c := call_arg(i, 1);
                val = ifx vkind(c) == .C_INT && const_int_zext(c) == 0 then c else poison;
            } else val = poison;
            dest = call_arg(i, 0);
        } else continue;
        if !info.ok continue;
        e: *At_Storage_Vars = null;
        for * vars if it.base == info.base { e = it; break; }
        if !e continue;
        if get_metadata(i, k_assign) == NONE set_metadata(i, k_assign, at_new_id());
        for e.vars at_emit_dbg_assign(info, val, dest, i, it);
    }
}

// AssignmentTrackingPass::runOnFunction
at_run_on_function :: (f: Value_Id) -> bool {
    if fn_has_fn_attr(f, .OptimizeNone) return false;
    Declares :: struct { ai: Value_Id; recs: [..] u32; }
    declares: [..] Declares; declares.allocator = temp;
    vars: [..] At_Storage_Vars; vars.allocator = temp;
    for b: fn_blocks(f) for i: block_insts(b) {
        r := inst(i).records;
        while r {
            defer r = dbgr(r).next;
            if dbgr(r).kind != .DECLARE continue;
            if ir.mds[dbgr(r).expr].nints != 0 continue;
            a := dbgr(r).loc;
            if a == NONE || ir.mds[a].kind != .VALUE continue;
            ai := strip_pointer_casts(ir.mds[a].value);
            if !(is_inst(ai) && inst_op(ai) == .ALLOCA) continue;
            if !alloca_is_static(ai) continue;
            if type_is_scalable(inst(ai).ty2) continue;
            d: *Declares = null;
            for * declares if it.ai == ai { d = it; break; }
            if !d { n: Declares; n.ai = ai; n.recs.allocator = temp; array_add(*declares, n); d = *declares[declares.count - 1]; }
            dup := false;
            for d.recs if it == r { dup = true; break; }
            if !dup array_add(*d.recs, r);
            at_vars_insert(*vars, ai, .{dbgr(r).var, debug_value_loc(r)});
        }
    }
    blocks: [..] Value_Id; blocks.allocator = temp;
    for b: fn_blocks(f) array_add(*blocks, b);
    at_track_assignments(blocks, vars);
    changed := false;
    for d: declares for d.recs { dbgr_erase(it); changed = true; }
    return changed;
}

// setAssignmentTrackingModuleFlag: Module::setModuleFlag(Max, "debug-info-assignment-tracking", i1 true)
at_set_module_flag :: () {
    key :: "debug-info-assignment-tracking";
    k := named_md_get_or_insert("llvm.module.flags");
    flag := md_tuple(.[md_value(const_int(ir.t_i32, 7)), md_string(key), md_value(const_int(ir.t_i1, 1))], false);
    for * ir.named_md[k].ops {
        fl := it.*;
        if fl == NONE || ir.mds[fl].nops < 2 continue;
        s := md_op(fl, 1);
        if s != NONE && ir.mds[s].kind == .STRING && ir.mds[s].str == key { it.* = flag; return; }
    }
    array_add(*ir.named_md[k].ops, flag);
}

// AssignmentTrackingPass::run(Function &F)
declare_to_assign_run :: (f: Value_Id) -> Preserved {
    if !at_run_on_function(f) return PRESERVE_ALL;
    at_set_module_flag();
    return preserved_cfg();
}
