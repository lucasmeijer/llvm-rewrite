// WholeProgramDevirtPass: whole program optimization of virtual calls made through llvm.assume(llvm.type.test) and
// llvm.type.checked.load[.relative]: single implementation devirtualization, uniform and unique return value
// optimization, virtual constant propagation, branch funnels, and the ThinLTO import / export phases with the
// YAML summaries of -wholeprogramdevirt-read-summary (module_summary.jai).
// Ported from llvm/lib/Transforms/IPO/WholeProgramDevirt.cpp (DevirtModule, findLowestOffset,
// setBeforeReturnValues / setAfterReturnValues, updateVCallVisibilityInModule, hasWholeProgramVisibility),
// llvm/include/llvm/Transforms/IPO/WholeProgramDevirt.h (AccumBitVector, VTableBits, TypeMemberInfo,
// VirtualCallTarget) and the devirtualization half of llvm/lib/Analysis/TypeMetadataUtils.cpp
// (findDevirtualizableCallsForTypeTest, findDevirtualizableCallsForTypeCheckedLoad, getFunctionAtVTableOffset;
// getPointerAtOffset is in pass_global_dce.jai).
// Not ported (each fails loudly): DevirtIndex (index-only ThinLTO devirtualization; opt never runs it), writing
// summaries (-wholeprogramdevirt-write-summary), bitcode summaries, speculative devirtualization
// (-devirtualize-speculatively) and -wholeprogramdevirt-check=fallback (both need versionCallSite), devirtualizing
// a call with a ptrauth bundle, optimization remarks (-pass-remarks is not an option here).

// ---------------------------------------------------------------- command line

Wpd_Check_Mode :: enum u8 { None; Trap; Fallback; }
wpd_cl: struct {
    summary_action: Pass_Summary_Action;
    read_summary: string;
    write_summary: string;
    speculative: bool;                  // -devirtualize-speculatively
    threshold: u64 = 10;                // -wholeprogramdevirt-branch-funnel-threshold
    whole_program_visibility: bool;     // -whole-program-visibility
    disable_whole_program_visibility: bool;
    skip: [..] string;                  // -wholeprogramdevirt-skip (glob patterns)
    keep_unreachable := true;           // -wholeprogramdevirt-keep-unreachable-function
    check_mode: Wpd_Check_Mode;         // -wholeprogramdevirt-check
};

wpd_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    parse_bool :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("invalid boolean value '%' for option -%", value, name);
        return false;
    }
    if name == "wholeprogramdevirt-summary-action" {
        if value == {
            case "none"; wpd_cl.summary_action = .None;
            case "import"; wpd_cl.summary_action = .Import;
            case "export"; wpd_cl.summary_action = .Export;
            case; fatal("invalid value '%' for option -wholeprogramdevirt-summary-action", value);
        }
        return true;
    }
    if name == "wholeprogramdevirt-read-summary" { wpd_cl.read_summary = copy_string(value); return true; }
    if name == "wholeprogramdevirt-write-summary" { wpd_cl.write_summary = copy_string(value); return true; }
    if name == "devirtualize-speculatively" { wpd_cl.speculative = parse_bool(name, value, has_value); return true; }
    if name == "whole-program-visibility" { wpd_cl.whole_program_visibility = parse_bool(name, value, has_value); return true; }
    if name == "disable-whole-program-visibility" { wpd_cl.disable_whole_program_visibility = parse_bool(name, value, has_value); return true; }
    if name == "wholeprogramdevirt-keep-unreachable-function" { wpd_cl.keep_unreachable = parse_bool(name, value, has_value); return true; }
    if name == "wholeprogramdevirt-print-index-based" { parse_bool(name, value, has_value); return true; }   // DevirtIndex only
    if name == "wholeprogramdevirt-branch-funnel-threshold" {
        v, ok := str_to_u64_auto(value);
        if !has_value || !ok fatal("invalid value '%' for option -wholeprogramdevirt-branch-funnel-threshold", value);
        wpd_cl.threshold = v;
        return true;
    }
    if name == "wholeprogramdevirt-skip" {
        // cl::CommaSeparated
        rest := value;
        while true {
            c := find_index_from_left(rest, #char ",");
            if c < 0 { array_add(*wpd_cl.skip, copy_string(rest)); break; }
            array_add(*wpd_cl.skip, copy_string(slice(rest, 0, c)));
            advance(*rest, c + 1);
        }
        return true;
    }
    if name == "wholeprogramdevirt-check" {
        if value == {
            case "none"; wpd_cl.check_mode = .None;
            case "trap"; wpd_cl.check_mode = .Trap;
            case "fallback"; wpd_cl.check_mode = .Fallback;
            case; fatal("invalid value '%' for option -wholeprogramdevirt-check", value);
        }
        return true;
    }
    return false;
}

// hasWholeProgramVisibility(WholeProgramVisibilityEnabledInLTO = false)
wpd_has_whole_program_visibility :: () -> bool {
    return wpd_cl.whole_program_visibility && !wpd_cl.disable_whole_program_visibility;
}

// optdriver.cpp before the pipeline: AssignGUIDPass::runOnModule when whole program visibility is on, then
// updateVCallVisibilityInModule(M, false, {}, false, ...): vtables with public vcall visibility become linkage unit
wpd_opt_startup :: () {
    if !wpd_has_whole_program_visibility() return;
    for ir.m_globals if !is_declaration(it) gv_assign_guid(it);
    for ir.m_functions if !is_declaration(it) gv_assign_guid(it);
    kt := md_fixed("type");
    for gv: ir.m_globals {
        if !wpd_has_type_md(gv, kt) continue;
        if wpd_vcall_visibility(gv) != 0 continue;
        // setVCallVisibilityMetadata(VCallVisibilityLinkageUnit): eraseMetadata, then addMetadata
        set_metadata(gv, md_fixed("vcall_visibility"), NONE);
        add_metadata(gv, md_fixed("vcall_visibility"), md_tuple(.[md_value(const_int(ir.t_i64, 1))], false));
    }
}

wpd_has_type_md :: (gv: Value_Id, kt: u32) -> bool {
    a := ir.v_md[gv];
    while a != NONE { if ir.attaches[a].kind == kt return true; a = ir.attaches[a].next; }
    return false;
}
// GlobalObject::getVCallVisibility: 0 public, 1 linkage unit, 2 translation unit
wpd_vcall_visibility :: (gv: Value_Id) -> u64 {
    m := get_metadata(gv, md_fixed("vcall_visibility"));
    if m == NONE return 0;
    return const_int_zext(ir.mds[md_op(m, 0)].value);
}

// ---------------------------------------------------------------- data

WPD_IID_TYPE_TEST :: #run iid_by_name("llvm.type.test");
WPD_IID_PUBLIC_TYPE_TEST :: #run iid_by_name("llvm.public.type.test");
WPD_IID_TYPE_CHECKED_LOAD :: #run iid_by_name("llvm.type.checked.load");
WPD_IID_TYPE_CHECKED_LOAD_RELATIVE :: #run iid_by_name("llvm.type.checked.load.relative");
WPD_IID_ICALL_BRANCH_FUNNEL :: #run iid_by_name("llvm.icall.branch.funnel");

// AccumBitVector
Wpd_Acc :: struct { bytes: [..] u8; used: [..] u8; }
// VTableBits
Wpd_Bits :: struct { gv: Value_Id; object_size: u64; before: Wpd_Acc; after: Wpd_Acc; }
// TypeMemberInfo (ordered by (Bits, Offset); Bits points into a vector filled in global order)
Wpd_Tm :: struct { bits: s32; offset: u64; }
// VirtualCallTarget
Wpd_Target :: struct { fn: Value_Id; tm: Wpd_Tm; ret_val: u64; was_devirt: bool; }
// VirtualCallSite
Wpd_Call_Site :: struct { vtable: Value_Id; cb: Value_Id; unsafe: s32 = -1; }
// a FunctionSummary of the export summary: (GlobalValueMap entry, summary)
Wpd_Fs_Ref :: struct { gi: s64; si: s64; }
// CallSiteInfo
Wpd_Csi :: struct {
    call_sites: [..] Wpd_Call_Site;
    all_devirted := true;
    tcl_users: [..] Wpd_Fs_Ref;   // SummaryTypeCheckedLoadUsers
    tta_users: [..] Wpd_Fs_Ref;   // SummaryTypeTestAssumeUsers
}
Wpd_Const_Csi :: struct { args: [..] u64; csi: Wpd_Csi; }
// VTableSlot + VTableSlotInfo (ConstCSInfo is a std::map: kept sorted by the argument vector)
Wpd_Slot :: struct {
    type_id: Md_Id;
    byte_offset: u64;
    cs: Wpd_Csi;
    const_cs: [..] Wpd_Const_Csi;
}
// a WholeProgramDevirtResolution of the export summary: TypeIdMap entry + WPDRes key (-1 = no resolution)
Wpd_Res_Ref :: struct { tk: s64 = -1; offset: u64; }

Wpd :: struct {
    export_summary: *Summary_Index;
    import_summary: *Summary_Index;
    int_ptr_ty: Type_Id;
    arch: Triple_Arch;
    obj: Triple_Object_Format;
    bits: [..] Wpd_Bits;
    tid_map: Table(Md_Id, s64);       // TypeIdMap: type id -> index into tid_members
    tid_members: [..] [..] Wpd_Tm;    // std::set<TypeMemberInfo>, sorted
    slots: [..] Wpd_Slot;             // CallSlots (MapVector: insertion order)
    slot_map: Table(string, s64);
    optimized: Table(Value_Id, bool); // OptimizedCalls
    unsafe_tt: [..] Value_Id;         // NumUnsafeUsesForTypeTest: the type test call ...
    unsafe_n: [..] s64;               // ... and its unsafe use count
    removed_ptrauth: [..] Value_Id;   // CallsWithPtrAuthBundleRemoved
}

wpd_slot :: (w: *Wpd, type_id: Md_Id, byte_offset: u64) -> s64 {
    key := tprint("%:%", type_id, byte_offset);
    found, k := table_find(*w.slot_map, key);
    if found return k;
    s: Wpd_Slot; s.type_id = type_id; s.byte_offset = byte_offset;
    array_add(*w.slots, s);
    table_add(*w.slot_map, copy_string(key), w.slots.count - 1);
    return w.slots.count - 1;
}
// ConstCSInfo[Args]
wpd_const_csi :: (s: *Wpd_Slot, args: [] u64) -> *Wpd_Csi {
    pos := s.const_cs.count;
    for * s.const_cs {
        if u64_vec_less(args, it.args) { pos = it_index; break; }
        if !u64_vec_less(it.args, args) return *it.csi;   // equal
    }
    e: Wpd_Const_Csi;
    for args array_add(*e.args, it);
    array_insert_at(*s.const_cs, e, pos);
    return *s.const_cs[pos].csi;
}
wpd_csi_is_exported :: (c: *Wpd_Csi) -> bool { return c.tcl_users.count > 0 || c.tta_users.count > 0; }

// VTableSlotInfo::findCallSiteInfo + addCallSite
wpd_add_call_site :: (w: *Wpd, slot: s64, vtable: Value_Id, cb: Value_Id, unsafe: s32) {
    s := *w.slots[slot];
    csi := *s.cs;
    rt := vtype(cb);
    if type_kind(rt) == .INT && type_int_width(rt) <= 64 && call_num_args(cb) != 0 {
        args: [..] u64; args.allocator = temp;
        all := true;
        for k: 1..cast(s64) call_num_args(cb) - 1 {
            a := call_arg(cb, cast(u32) k);
            if vkind(a) != .C_INT || type_int_width(vtype(a)) > 64 { all = false; break; }
            array_add(*args, const_int_zext(a));
        }
        if all csi = wpd_const_csi(s, args);
    }
    csi.all_devirted = false;
    array_add(*csi.call_sites, .{vtable, cb, unsafe});
}

// WholeProgramDevirtResolution of the export summary
wpd_res :: (w: *Wpd, r: Wpd_Res_Ref) -> *Wpd_Res {
    if r.tk < 0 return null;
    t := *w.export_summary.type_ids[r.tk];
    for * t.wpd if it.offset == r.offset return *it.res;
    pos := t.wpd.count;
    for t.wpd if r.offset < it.offset { pos = it_index; break; }
    e: Wpd_Entry; e.offset = r.offset;
    array_insert_at(*t.wpd, e, pos);
    return *t.wpd[pos].res;
}
// Res->ResByArg[Args]
wpd_res_by_arg :: (res: *Wpd_Res, args: [] u64) -> *By_Arg {
    pos := res.res_by_arg.count;
    for * res.res_by_arg {
        if u64_vec_less(args, it.args) { pos = it_index; break; }
        if !u64_vec_less(it.args, args) return *it.res;
    }
    e: By_Arg_Entry;
    for args array_add(*e.args, it);
    array_insert_at(*res.res_by_arg, e, pos);
    return *res.res_by_arg[pos].res;
}

wpd_skip :: (name: string) -> bool {
    for wpd_cl.skip if glob_match(it, name) return true;
    return false;
}

// ---------------------------------------------------------------- AccumBitVector / findLowestOffset

wpd_acc_data :: (a: *Wpd_Acc, pos: u64, size: u64) {
    if cast(u64) a.bytes.count < pos + size {
        old := a.bytes.count;
        array_resize(*a.bytes, cast(s64)(pos + size));
        array_resize(*a.used, cast(s64)(pos + size));
        for k: old..a.bytes.count-1 { a.bytes[k] = 0; a.used[k] = 0; }
    }
}
wpd_acc_set_le :: (a: *Wpd_Acc, pos: u64, val: u64, size: u64) {
    p := pos / 8;
    wpd_acc_data(a, p, size);
    for i: 0..cast(s64) size - 1 {
        a.bytes[p + cast(u64) i] = cast,trunc(u8) (val >> (cast(u64) i * 8));
        a.used[p + cast(u64) i] = 0xff;
    }
}
wpd_acc_set_be :: (a: *Wpd_Acc, pos: u64, val: u64, size: u64) {
    p := pos / 8;
    wpd_acc_data(a, p, size);
    for i: 0..cast(s64) size - 1 {
        a.bytes[p + size - cast(u64) i - 1] = cast,trunc(u8) (val >> (cast(u64) i * 8));
        a.used[p + size - cast(u64) i - 1] = 0xff;
    }
}
wpd_acc_set_bit :: (a: *Wpd_Acc, pos: u64, b: bool) {
    wpd_acc_data(a, pos / 8, 1);
    if b a.bytes[pos / 8] |= cast(u8) (1 << (pos % 8));
    a.used[pos / 8] |= cast(u8) (1 << (pos % 8));
}

wpd_min_before :: (w: *Wpd, t: *Wpd_Target) -> u64 { return t.tm.offset; }
wpd_min_after :: (w: *Wpd, t: *Wpd_Target) -> u64 { return w.bits[t.tm.bits].object_size - t.tm.offset; }
wpd_allocated_before :: (w: *Wpd, t: *Wpd_Target) -> u64 { return wpd_min_before(w, t) + cast(u64) w.bits[t.tm.bits].before.bytes.count; }
wpd_allocated_after :: (w: *Wpd, t: *Wpd_Target) -> u64 { return wpd_min_after(w, t) + cast(u64) w.bits[t.tm.bits].after.bytes.count; }

// findLowestOffset
wpd_find_lowest_offset :: (w: *Wpd, targets: [] Wpd_Target, is_after: bool, size: u64) -> u64 {
    min_byte: u64 = 0;
    for * t: targets {
        m := ifx is_after then wpd_min_after(w, t) else wpd_min_before(w, t);
        if m > min_byte min_byte = m;
    }
    used: [..] [] u8; used.allocator = temp;
    for * t: targets {
        b := *w.bits[t.tm.bits];
        vt_used := ifx is_after then b.after.used else b.before.used;
        offset := min_byte - (ifx is_after then wpd_min_after(w, t) else wpd_min_before(w, t));
        if cast(u64) vt_used.count > offset {
            s: [] u8;
            s.data = vt_used.data + offset;
            s.count = vt_used.count - cast(s64) offset;
            array_add(*used, s);
        }
    }
    if size == 1 {
        i: u64 = 0;
        while true {
            bits_used: u8 = 0;
            for used if i < cast(u64) it.count bits_used |= it[i];
            if bits_used != 0xff {
                inv := ~bits_used;
                tz: u64 = 0;
                while ((inv >> tz) & 1) == 0 tz += 1;
                return (min_byte + i) * 8 + tz;
            }
            i += 1;
        }
    }
    i: u64 = 0;
    while true {
        ok := true;
        for used {
            byte: u64 = 0;
            while i + byte < cast(u64) it.count && byte < size / 8 {
                if it[i + byte] { ok = false; break; }
                byte += 1;
            }
            if !ok break;
        }
        if ok return align_to((min_byte + i) * 8, size);
        i += 1;
    }
    return 0;
}

// setBeforeReturnValues
wpd_set_before_return_values :: (w: *Wpd, targets: [] Wpd_Target, alloc_before: u64, bit_width: u32) -> (s64, u64) {
    offset_byte: s64;
    if bit_width == 1 offset_byte = -(cast(s64) (alloc_before / 8) + 1);
    else offset_byte = -(cast(s64) ((alloc_before + 7) / 8) + cast(s64) ((bit_width + 7) / 8));
    offset_bit := alloc_before % 8;
    big := dl.big_endian;
    for * t: targets {
        b := *w.bits[t.tm.bits];
        pos := alloc_before - 8 * wpd_min_before(w, t);
        if bit_width == 1 wpd_acc_set_bit(*b.before, pos, t.ret_val != 0);
        else {
            // the Before bytes are stored in reverse order: the opposite endianness of the target
            size := cast(u64) (bit_width + 7) / 8;
            if big wpd_acc_set_le(*b.before, pos, t.ret_val, size);
            else wpd_acc_set_be(*b.before, pos, t.ret_val, size);
        }
    }
    return offset_byte, offset_bit;
}
// setAfterReturnValues
wpd_set_after_return_values :: (w: *Wpd, targets: [] Wpd_Target, alloc_after: u64, bit_width: u32) -> (s64, u64) {
    offset_byte: s64;
    if bit_width == 1 offset_byte = cast(s64) (alloc_after / 8);
    else offset_byte = cast(s64) ((alloc_after + 7) / 8);
    offset_bit := alloc_after % 8;
    big := dl.big_endian;
    for * t: targets {
        b := *w.bits[t.tm.bits];
        pos := alloc_after - 8 * wpd_min_after(w, t);
        if bit_width == 1 wpd_acc_set_bit(*b.after, pos, t.ret_val != 0);
        else {
            size := cast(u64) (bit_width + 7) / 8;
            if big wpd_acc_set_be(*b.after, pos, t.ret_val, size);
            else wpd_acc_set_le(*b.after, pos, t.ret_val, size);
        }
    }
    return offset_byte, offset_bit;
}

// ---------------------------------------------------------------- TypeMetadataUtils

// findCallsAtConstantOffset
wpd_find_calls_at_constant_offset :: (calls: *[..] Wpd_Devirt_Call, has_non_call_uses: *bool, fptr: Value_Id, offset: u64, ci: Value_Id, dt: *Dom_Tree) {
    u := ir.v_first_use[fptr];
    while u != NONE {
        defer u = ir.u_next[u];
        usr := ir.u_user[u];
        if !is_inst(usr) fatal("wholeprogramdevirt: a loaded function pointer has a non-instruction user");
        if block_fn(inst_block(ci)) != block_fn(inst_block(usr)) continue;
        if !dt_dominates_inst(dt, ci, usr) continue;
        o := inst_op(usr);
        if o == .BITCAST wpd_find_calls_at_constant_offset(calls, has_non_call_uses, usr, offset, ci, dt);
        else if o == .CALL || o == .INVOKE array_add(calls, .{offset, usr});
        else if has_non_call_uses has_non_call_uses.* = true;
    }
}
Wpd_Devirt_Call :: struct { offset: u64; cb: Value_Id; }

// findLoadCallsAtConstantOffset
wpd_find_load_calls_at_constant_offset :: (calls: *[..] Wpd_Devirt_Call, vptr: Value_Id, offset: s64, ci: Value_Id, dt: *Dom_Tree) {
    if is_constant_data_kind(vkind(vptr)) return;   // !hasUseList()
    u := ir.v_first_use[vptr];
    while u != NONE {
        defer u = ir.u_next[u];
        usr := ir.u_user[u];
        if !is_inst(usr) continue;
        o := inst_op(usr);
        if o == .BITCAST wpd_find_load_calls_at_constant_offset(calls, usr, offset, ci, dt);
        else if o == .LOAD wpd_find_calls_at_constant_offset(calls, null, usr, cast(u64) offset, ci, dt);
        else if o == .GEP {
            if vptr == op(usr, 0) && gep_has_all_constant_indices(usr) {
                idxs: [..] Value_Id; idxs.allocator = temp;
                for k: 1..cast(s64) nops(usr) - 1 array_add(*idxs, op(usr, cast(u32) k));
                gep_offset := dl_indexed_offset_in_type(inst(usr).ty2, idxs);
                wpd_find_load_calls_at_constant_offset(calls, usr, offset + gep_offset, ci, dt);
            }
        } else if o == .CALL {
            if call_iid(usr) == IID_LOAD_RELATIVE {
                lo := op(usr, 1);
                if vkind(lo) == .C_INT
                    wpd_find_calls_at_constant_offset(calls, null, usr, cast(u64) (offset + const_int_sext(lo)), ci, dt);
            }
        }
    }
}

wpd_is_assume :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .CALL && call_iid(v) == IID_ASSUME; }

// getFunctionAtVTableOffset: (function, the constant stored in the vtable)
wpd_function_at_vtable_offset :: (gv: Value_Id, offset: u64) -> (Value_Id, Value_Id) {
    ptr := get_pointer_at_offset(gv_initializer(gv), offset, gv);
    if ptr == NONE return NONE, NONE;
    c := strip_pointer_casts(ptr);
    fn: Value_Id = NONE;
    if vkind(c) == .FUNCTION fn = c;
    else if vkind(c) == .ALIAS && vkind(op(c, 0)) == .FUNCTION fn = op(c, 0);
    if fn == NONE return NONE, NONE;
    return fn, c;
}

// ---------------------------------------------------------------- scanning

// buildTypeIdentifierMap
wpd_build_type_identifier_map :: (w: *Wpd) {
    kt := md_fixed("type");
    types: [..] Md_Id; types.allocator = temp;
    for gv: ir.m_globals {
        ltt_type_mds(gv, *types);
        if is_declaration(gv) || types.count == 0 continue;
        b: Wpd_Bits;
        b.gv = gv;
        b.object_size = dl_type_alloc_size(vtype(gv_initializer(gv)));
        array_add(*w.bits, b);
        bi := cast(s32) w.bits.count - 1;
        for t: types {
            tid := md_op(t, 1);
            off := ltt_type_offset(t);
            found, k := table_find(*w.tid_map, tid);
            if !found {
                m: [..] Wpd_Tm;
                array_add(*w.tid_members, m);
                k = w.tid_members.count - 1;
                table_add(*w.tid_map, tid, k);
            }
            set := *w.tid_members[k];
            // std::set insert ordered by (Bits, Offset)
            pos := set.count;
            dup := false;
            for set.* {
                if it.bits == bi && it.offset == off { dup = true; break; }
                if it.bits > bi || (it.bits == bi && it.offset > off) { pos = it_index; break; }
            }
            if !dup array_insert_at(set, .{bi, off}, pos);
        }
    }
}

// scanTypeTestUsers
wpd_scan_type_test_users :: (w: *Wpd, tt_fn: Value_Id) {
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[tt_fn];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for ci: users {
        if !is_inst(ci) || inst_op(ci) != .CALL continue;
        calls: [..] Wpd_Devirt_Call; calls.allocator = temp;
        assumes: [..] Value_Id; assumes.allocator = temp;
        dt := get_domtree(block_fn(inst_block(ci)));
        // findDevirtualizableCallsForTypeTest
        x := ir.v_first_use[ci];
        while x != NONE { if wpd_is_assume(ir.u_user[x]) array_add(*assumes, ir.u_user[x]); x = ir.u_next[x]; }
        if assumes.count wpd_find_load_calls_at_constant_offset(*calls, strip_pointer_casts(call_arg(ci, 0)), 0, ci, dt);
        a := call_arg(ci, 1);
        if vkind(a) != .MD_VALUE fatal("wholeprogramdevirt: the second argument of a type test must be metadata");
        type_id := ir.v_aux[a];
        if assumes.count {
            ptr := strip_pointer_casts(call_arg(ci, 0));
            for calls wpd_add_call_site(w, wpd_slot(w, type_id, it.offset), ptr, it.cb, -1);
        }
        remove_tt :: (assumes: [] Value_Id, ci: Value_Id) {
            for assumes erase_inst(it);
            if !has_uses(ci) erase_inst(ci);
        }
        if !table_contains(*w.tid_map, type_id) remove_tt(assumes, ci);
        else if w.import_summary && ir.mds[type_id].kind == .STRING {
            if si_type_id_summary(w.import_summary, ir.mds[type_id].str) < 0 remove_tt(assumes, ci);
        }
    }
}

// scanTypeCheckedLoadUsers
wpd_scan_type_checked_load_users :: (w: *Wpd, tcl_fn: Value_Id) {
    tt_fn := get_or_insert_intrinsic_declaration(WPD_IID_TYPE_TEST);
    relative := fn_iid(tcl_fn) == WPD_IID_TYPE_CHECKED_LOAD_RELATIVE;
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[tcl_fn];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for ci: users {
        if !is_inst(ci) || inst_op(ci) != .CALL continue;
        ptr := call_arg(ci, 0);
        offset := call_arg(ci, 1);
        tid_val := call_arg(ci, 2);
        if vkind(tid_val) != .MD_VALUE fatal("wholeprogramdevirt: the type id of a type.checked.load must be metadata");
        type_id := ir.v_aux[tid_val];
        calls: [..] Wpd_Devirt_Call; calls.allocator = temp;
        loaded: [..] Value_Id; loaded.allocator = temp;
        preds: [..] Value_Id; preds.allocator = temp;
        has_non_call_uses := false;
        dt := get_domtree(block_fn(inst_block(ci)));
        // findDevirtualizableCallsForTypeCheckedLoad
        if vkind(offset) != .C_INT has_non_call_uses = true;
        else {
            x := ir.v_first_use[ci];
            while x != NONE {
                defer x = ir.u_next[x];
                usr := ir.u_user[x];
                if is_inst(usr) && inst_op(usr) == .EXTRACTVALUE {
                    idx := inst_indices(usr);
                    if idx.count == 1 && idx[0] == 0 { array_add(*loaded, usr); continue; }
                    if idx.count == 1 && idx[0] == 1 { array_add(*preds, usr); continue; }
                }
                has_non_call_uses = true;
            }
            for loaded wpd_find_calls_at_constant_offset(*calls, *has_non_call_uses, it, const_int_zext(offset), ci, dt);
        }

        load_b: Irb;
        irb_set_before(*load_b, ifx loaded.count == 1 && !has_non_call_uses then loaded[0] else ci);
        loaded_value: Value_Id;
        if relative {
            load_rel := get_or_insert_intrinsic_declaration(IID_LOAD_RELATIVE, .[ir.t_i32]);
            loaded_value = irb_call(*load_b, load_rel, .[ptr, offset]);
        } else {
            gep := irb_gep(*load_b, ir.t_i8, ptr, .[offset]);
            pty := type_ptr(0);
            loaded_value = irb_load(*load_b, pty, gep, dl_alignment(pty, true));
        }
        for loaded { ipo_rauw(it, loaded_value); erase_inst(it); }

        call_b: Irb;
        irb_set_before(*call_b, ifx preds.count == 1 && !has_non_call_uses then preds[0] else ci);
        tt_call := irb_call(*call_b, tt_fn, .[ptr, tid_val]);
        for preds { ipo_rauw(it, tt_call); erase_inst(it); }

        if has_uses(ci) {
            b: Irb;
            irb_set_before(*b, ci);
            pair := const_poison(vtype(ci));
            pair = irb_insert_value(*b, pair, loaded_value, .[0]);
            pair = irb_insert_value(*b, pair, tt_call, .[1]);
            ipo_rauw(ci, pair);
        }

        array_add(*w.unsafe_tt, tt_call);
        array_add(*w.unsafe_n, calls.count + ifx has_non_call_uses then 1 else 0);
        ui := cast(s32) w.unsafe_tt.count - 1;
        for calls wpd_add_call_site(w, wpd_slot(w, type_id, it.offset), ptr, it.cb, ui);
        erase_inst(ci);
    }
}

// ---------------------------------------------------------------- the optimizations

wpd_mark_optimized :: (w: *Wpd, cb: Value_Id) -> bool {
    if table_contains(*w.optimized, cb) return false;
    table_add(*w.optimized, cb, true);
    return true;
}
wpd_unsafe_done :: (w: *Wpd, cs: *Wpd_Call_Site) { if cs.unsafe >= 0 w.unsafe_n[cs.unsafe] -= 1; }

// VirtualCallSite::replaceAndErase
wpd_replace_and_erase :: (w: *Wpd, cs: *Wpd_Call_Site, new: Value_Id) {
    cb := cs.cb;
    ipo_rauw(cb, new);
    if inst_op(cb) == .INVOKE {
        br := create_br(get_successor(cb, 0));
        insert_at_position(br, inst_block(cb), cb, false);
        block_remove_predecessor(get_successor(cb, 1), inst_block(cb));
    }
    erase_inst(cb);
    wpd_unsafe_done(w, cs);
}

// applySingleImplDevirt
wpd_apply_single_impl_devirt :: (w: *Wpd, s: *Wpd_Slot, the_fn: Value_Id) -> bool {
    if wpd_skip(vname(strip_pointer_casts(the_fn))) return false;
    is_exported := false;
    apply :: (w: *Wpd, csi: *Wpd_Csi, the_fn: Value_Id, is_exported: *bool) {
        for * cs: csi.call_sites {
            if !wpd_mark_optimized(w, cs.cb) continue;
            cb := cs.cb;
            b: Irb;
            irb_set_before(*b, cb);
            callee := irb_bitcast(*b, the_fn, vtype(call_callee(cb)));
            if wpd_cl.check_mode == .Trap {
                cond := irb_icmp(*b, ICMP_NE, call_callee(cb), callee);
                then_term := mu_split_block_and_insert_if_then(cond, cb, false, create_unlikely_branch_weights());
                tb: Irb;
                irb_set_before(*tb, then_term);
                trap := irb_call(*tb, get_or_insert_intrinsic_declaration(IID_DEBUGTRAP), .[]);
                set_metadata(trap, MDK_DBG, get_metadata(cb, MDK_DBG));
            }
            if wpd_cl.check_mode == .Fallback || wpd_cl.speculative
                fatal("wholeprogramdevirt: -wholeprogramdevirt-check=fallback / speculative devirtualization (versionCallSite) is not supported yet");
            set_op(cb, nops(cb) - 1, callee);
            set_metadata(cb, md_fixed("prof"), NONE);
            set_metadata(cb, md_fixed("callees"), NONE);
            if call_has_bundle(cb, "ptrauth")
                fatal("wholeprogramdevirt: devirtualizing a call with a ptrauth bundle is not supported yet");
            wpd_unsafe_done(w, cs);
        }
        if wpd_csi_is_exported(csi) is_exported.* = true;
        csi.all_devirted = true;
    }
    apply(w, *s.cs, the_fn, *is_exported);
    for * s.const_cs apply(w, *it.csi, the_fn, *is_exported);
    return is_exported;
}

// trySingleImplDevirt
wpd_try_single_impl_devirt :: (w: *Wpd, targets: [] Wpd_Target, s: *Wpd_Slot, res: Wpd_Res_Ref) -> bool {
    the_fn := targets[0].fn;
    for targets if it.fn != the_fn return false;
    if !wpd_apply_single_impl_devirt(w, s, the_fn) return false;
    // export phase
    if gv_has_local_linkage(the_fn) {
        new_name := tconcat(vname(the_fn), ".llvm.merged");
        c := glob(the_fn).comdat;
        if c >= 0 && ir.comdats[c].name == vname(the_fn) {
            nc := lk_dst_comdat(new_name);
            ir.comdats[nc].kind = ir.comdats[c].kind;
            for ir.m_globals if glob(it).comdat == c glob(it).comdat = nc;
            for ir.m_functions if glob(it).comdat == c glob(it).comdat = nc;
        }
        gv_set_linkage(the_fn, .EXTERNAL);
        gv_set_visibility(the_fn, 1);
        set_name(the_fn, new_name);
    }
    // addCalls(SlotInfo, ExportSummary->getValueInfo(TheFn->getGUID())) only edits the function summaries
    r := wpd_res(w, res);
    if r { r.kind = .SingleImpl; r.single_impl_name = copy_string(vname(the_fn)); }
    return true;
}

// getGlobalName
wpd_global_name :: (s: *Wpd_Slot, args: [] u64, name: string) -> string {
    sb: String_Builder;
    sb.allocator = temp;
    print_to_builder(*sb, "__typeid_%_%", ir.mds[s.type_id].str, s.byte_offset);
    for args print_to_builder(*sb, "_%", it);
    print_to_builder(*sb, "_%", name);
    return builder_to_string(*sb,, allocator = temp);
}
wpd_should_export_constants_as_absolute_symbols :: (w: *Wpd) -> bool {
    return (w.arch == .x86 || w.arch == .x86_64) && w.obj == .ELF;
}
// exportGlobal
wpd_export_global :: (s: *Wpd_Slot, args: [] u64, name: string, c: Value_Id) {
    ga := ltt_alias_create(ir.t_i8, .EXTERNAL, wpd_global_name(s, args, name), c);
    gv_set_visibility(ga, 1);
}
// exportConstant: the value goes to the summary unless it is exported as an absolute symbol
wpd_export_constant :: (w: *Wpd, s: *Wpd_Slot, args: [] u64, name: string, cnst: u32, storage: *u32) {
    if wpd_should_export_constants_as_absolute_symbols(w) {
        wpd_export_global(s, args, name, ce_cast(.INTTOPTR, const_int(ir.t_i32, cnst), type_ptr(0)));
        return;
    }
    storage.* = cnst;
}
// importGlobal
wpd_import_global :: (s: *Wpd_Slot, args: [] u64, name: string) -> Value_Id {
    gv := module_get_or_insert_global(wpd_global_name(s, args, name), type_array(0, ir.t_i8));
    gv_set_visibility(gv, 1);
    return gv;
}
// importConstant
wpd_import_constant :: (w: *Wpd, s: *Wpd_Slot, args: [] u64, name: string, int_ty: Type_Id, storage: u32) -> Value_Id {
    if !wpd_should_export_constants_as_absolute_symbols(w) return const_int(int_ty, storage);
    c := wpd_import_global(s, args, name);
    gv := strip_pointer_casts(c);
    if vkind(gv) != .GLOBAL_VAR fatal("wholeprogramdevirt: '%' is not a global variable", vname(gv));
    c = ce_cast(.PTRTOINT, c, int_ty);
    ak := md_fixed("absolute_symbol");
    if get_metadata(gv, ak) != NONE return c;
    set_abs_range :: (w: *Wpd, gv: Value_Id, mn: u64, mx: u64) {
        set_metadata(gv, md_fixed("absolute_symbol"), md_tuple(.[md_value(const_int(w.int_ptr_ty, mn)), md_value(const_int(w.int_ptr_ty, mx))], false));
    }
    abs_width := type_int_width(int_ty);
    if abs_width == type_int_width(w.int_ptr_ty) {
        all_ones: u64 = ifx abs_width >= 64 then 0xFFFF_FFFF_FFFF_FFFF else ((cast(u64) 1) << abs_width) - 1;
        set_abs_range(w, gv, all_ones, all_ones);
    } else {
        set_abs_range(w, gv, 0, (cast(u64) 1) << abs_width);
    }
    return c;
}

// getMemberAddr: ConstantExpr::getPtrAdd(GV, i64 Offset)
wpd_member_addr :: (w: *Wpd, tm: Wpd_Tm) -> Value_Id {
    return ce_gep(ir.t_i8, w.bits[tm.bits].gv, .[const_int(ir.t_i64, tm.offset)], 0);
}

// tryICallBranchFunnel
wpd_try_icall_branch_funnel :: (w: *Wpd, targets: [] Wpd_Target, s: *Wpd_Slot, res: Wpd_Res_Ref) {
    if w.arch != .x86_64 return;
    if cast(u64) targets.count > wpd_cl.threshold return;
    has_non_devirt := !s.cs.all_devirted;
    if !has_non_devirt for s.const_cs if !it.csi.all_devirted { has_non_devirt = true; break; }
    if !has_non_devirt return;
    for targets if glob(w.bits[it.tm.bits].gv).linkage == .AVAILABLE_EXTERNALLY return;

    pty := type_ptr(0);
    ft := type_func(ir.t_void, .[pty], true);
    jt: Value_Id;
    if ir.mds[s.type_id].kind == .STRING {
        jt = ltt_fn_create(ft, .EXTERNAL, dl.program_as, wpd_global_name(s, .[], "branch_funnel"));
        gv_set_visibility(jt, 1);
    } else {
        jt = ltt_fn_create(ft, .INTERNAL, dl.program_as, "branch_funnel");
    }
    fn_add_param_attr_kind(jt, 0, .Nest);
    jt_args: [..] Value_Id; jt_args.allocator = temp;
    array_add(*jt_args, fn_arg(jt, 0));
    for targets {
        array_add(*jt_args, wpd_member_addr(w, it.tm));
        array_add(*jt_args, it.fn);
    }
    bb := create_block(jt, "");
    intr := get_or_insert_intrinsic_declaration(WPD_IID_ICALL_BRANCH_FUNNEL);
    b: Irb;
    irb_set_end(*b, bb);
    ci := irb_call(*b, intr, jt_args);
    call_set_tail_kind(ci, 2);
    irb_insert(*b, new_inst(.RET, ir.t_void, 0));

    if wpd_apply_icall_branch_funnel(w, s, jt) {
        r := wpd_res(w, res);
        if r r.kind = .BranchFunnel;
    }
    ok, _ := ic_fn_entry_count(jt);
    if !ok set_metadata(jt, md_fixed("prof"), md_tuple(.[md_string("unknown"), md_string("wholeprogramdevirt")], false));
}

// applyICallBranchFunnel: is exported
wpd_apply_icall_branch_funnel :: (w: *Wpd, s: *Wpd_Slot, jt: Value_Id) -> bool {
    is_exported := false;
    have_count := false;
    count: float64 = 0;
    apply :: (w: *Wpd, csi: *Wpd_Csi, jt: Value_Id, is_exported: *bool, have_count: *bool, count: *float64) {
        if wpd_csi_is_exported(csi) is_exported.* = true;
        if csi.all_devirted return;
        olds: [..] Value_Id; olds.allocator = temp;   // std::map<CallBase *, CallBase *> CallBases
        news: [..] Value_Id; news.allocator = temp;
        for * cs: csi.call_sites {
            cb := cs.cb;
            dup := false;
            for olds if it == cb { dup = true; break; }
            if dup continue;
            caller := block_fn(inst_block(cb));
            fs := fn_find_str_attr(caller, "target-features");
            if !fs || !contains(fs.val, "+retpoline") continue;

            fty := inst(cb).ty2;
            params: [..] Type_Id; params.allocator = temp;
            array_add(*params, type_ptr(0));
            for k: 0..cast(s64) func_nparams(fty) - 1 array_add(*params, func_param(fty, cast(u32) k));
            new_ft := type_func(func_ret(fty), params, func_vararg(fty));
            args: [..] Value_Id; args.allocator = temp;
            array_add(*args, cs.vtable);
            for k: 0..cast(s64) call_num_args(cb) - 1 array_add(*args, call_arg(cb, cast(u32) k));

            if !is_declaration(jt) {
                // accumulate the call frequencies of the original call sites as the funnel's entry count
                bfi := get_bfi(caller);
                ec := bfi_get_block_freq(bfi, fn_entry(caller));
                cok, cc := ic_fn_entry_count(caller);
                call_count: float64 = 0;
                if ec != 0 && cok && cc != 0 {
                    call_freq := cast(float64) bfi_get_block_freq(bfi, inst_block(cb)) / cast(float64) ec;
                    call_count = call_freq * cast(float64) cc;
                }
                count.* += call_count;
                have_count.* = true;
            }
            b: Irb;
            irb_set_before(*b, cb);
            new_cs: Value_Id;
            is_invoke := inst_op(cb) == .INVOKE;
            n := cast(u32) args.count + ifx is_invoke then cast(u32) 3 else 1;
            new_cs = new_inst(ifx is_invoke then Opcode.INVOKE else .CALL, func_ret(new_ft), n);
            inst(new_cs).ty2 = new_ft;
            for args set_op(new_cs, cast(u32) it_index, it);
            k := cast(u32) args.count;
            if is_invoke {
                set_op(new_cs, k, get_successor(cb, 0)); k += 1;
                set_op(new_cs, k, get_successor(cb, 1)); k += 1;
            }
            set_op(new_cs, k, jt);
            irb_insert(*b, new_cs);
            inst(new_cs).cc = inst(cb).cc;
            attrs := inst(cb).attrs;
            nest: Attr; nest.kind = .Nest; nest.ty = NONE;
            new_params: [..] u32; new_params.allocator = temp;
            array_add(*new_params, attr_set_get(.[nest]));
            if attrs != 0 for ir.attr_lists[attrs].params array_add(*new_params, it);
            inst(new_cs).attrs = attr_list_get(attr_list_fn(attrs), attr_list_ret(attrs), new_params);
            array_add(*olds, cb);
            array_add(*news, new_cs);
            wpd_unsafe_done(w, cs);
        }
        for olds { ipo_rauw(it, news[it_index]); erase_inst(it); }
    }
    apply(w, *s.cs, jt, *is_exported, *have_count, *count);
    for * s.const_cs apply(w, *it.csi, jt, *is_exported, *have_count, *count);
    if have_count fn_set_entry_count(jt, cast(u64) (count + 0.5));   // std::round of a non-negative count
    return is_exported;
}


// tryEvaluateFunctionsWithArgs
wpd_try_evaluate_functions_with_args :: (targets: [] Wpd_Target, args: [] u64) -> bool {
    for * t: targets {
        fn := t.fn;
        if vkind(fn) != .FUNCTION return false;
        if cast(s64) glob(fn).nargs != args.count + 1 return false;
        fty := glob(fn).value_type;
        eval_args: [..] Value_Id; eval_args.allocator = temp;
        array_add(*eval_args, const_null_value(func_param(fty, 0)));
        for a, i: args {
            aty := func_param(fty, cast(u32) i + 1);
            if type_kind(aty) != .INT return false;
            array_add(*eval_args, const_int(aty, a));
        }
        // Evaluator Eval(DL, /*TLI=*/nullptr)
        ev: Evaluator;
        ev_init(*ev);
        old := cfo_no_tli;
        cfo_no_tli = true;
        ok, ret := ev_evaluate_function(*ev, fn, eval_args);
        cfo_no_tli = old;
        ev_destroy(*ev);
        if !ok || ret == NONE || vkind(ret) != .C_INT return false;
        t.ret_val = const_int_zext(ret);
    }
    return true;
}

// applyUniformRetValOpt
wpd_apply_uniform_ret_val_opt :: (w: *Wpd, csi: *Wpd_Csi, the_ret_val: u64) {
    for * cs: csi.call_sites {
        if !wpd_mark_optimized(w, cs.cb) continue;
        wpd_replace_and_erase(w, cs, const_int(vtype(cs.cb), the_ret_val));
    }
    csi.all_devirted = true;
}
// tryUniformRetValOpt
wpd_try_uniform_ret_val_opt :: (w: *Wpd, targets: [] Wpd_Target, csi: *Wpd_Csi, res: *By_Arg) -> bool {
    the_ret_val := targets[0].ret_val;
    for targets if it.ret_val != the_ret_val return false;
    if wpd_csi_is_exported(csi) { res.kind = .UniformRetVal; res.info = the_ret_val; }
    wpd_apply_uniform_ret_val_opt(w, csi, the_ret_val);
    return true;
}

// applyUniqueRetValOpt
wpd_apply_unique_ret_val_opt :: (w: *Wpd, csi: *Wpd_Csi, is_one: bool, unique_member_addr: Value_Id) {
    for * cs: csi.call_sites {
        if !wpd_mark_optimized(w, cs.cb) continue;
        b: Irb;
        irb_set_before(*b, cs.cb);
        cmp := irb_icmp(*b, ifx is_one then cast(u8) ICMP_EQ else ICMP_NE, cs.vtable, irb_bitcast(*b, unique_member_addr, vtype(cs.vtable)));
        cmp = irb_cast(*b, .ZEXT, cmp, vtype(cs.cb));
        wpd_replace_and_erase(w, cs, cmp);
    }
    csi.all_devirted = true;
}
// tryUniqueRetValOpt
wpd_try_unique_ret_val_opt :: (w: *Wpd, bit_width: u32, targets: [] Wpd_Target, csi: *Wpd_Csi, res: *By_Arg, s: *Wpd_Slot, args: [] u64) -> bool {
    try_for :: (w: *Wpd, targets: [] Wpd_Target, csi: *Wpd_Csi, res: *By_Arg, s: *Wpd_Slot, args: [] u64, is_one: bool) -> bool {
        unique: Wpd_Tm;
        found := false;
        for targets {
            if it.ret_val == (ifx is_one then cast(u64) 1 else 0) {
                if found return false;
                unique = it.tm;
                found = true;
            }
        }
        if !found fatal("wholeprogramdevirt: internal: no unique member");
        addr := wpd_member_addr(w, unique);
        if wpd_csi_is_exported(csi) {
            res.kind = .UniqueRetVal;
            res.info = ifx is_one then cast(u64) 1 else 0;
            wpd_export_global(s, args, "unique_member", addr);
        }
        wpd_apply_unique_ret_val_opt(w, csi, is_one, addr);
        return true;
    }
    if bit_width == 1 {
        if try_for(w, targets, csi, res, s, args, true) return true;
        if try_for(w, targets, csi, res, s, args, false) return true;
    }
    return false;
}

// applyVirtualConstProp
wpd_apply_virtual_const_prop :: (w: *Wpd, csi: *Wpd_Csi, byte: Value_Id, bit: Value_Id) {
    for * cs: csi.call_sites {
        if !wpd_mark_optimized(w, cs.cb) continue;
        rt := vtype(cs.cb);
        b: Irb;
        irb_set_before(*b, cs.cb);
        addr := irb_gep(*b, ir.t_i8, cs.vtable, .[byte]);
        if type_int_width(rt) == 1 {
            bits := irb_load(*b, ir.t_i8, addr, 1);
            bits_and_bit := irb_binop(*b, .AND, bits, bit);
            is_bit_set := irb_icmp(*b, ICMP_NE, bits_and_bit, const_int(ir.t_i8, 0));
            wpd_replace_and_erase(w, cs, is_bit_set);
        } else {
            val := irb_load(*b, rt, addr, dl_alignment(rt, true));
            wpd_replace_and_erase(w, cs, val);
        }
    }
    csi.all_devirted = true;
}

// tryVirtualConstProp
wpd_try_virtual_const_prop :: (w: *Wpd, targets: [] Wpd_Target, s: *Wpd_Slot, res: Wpd_Res_Ref) -> bool {
    fn0 := targets[0].fn;
    if vkind(fn0) != .FUNCTION return false;
    ret_ty := func_ret(glob(fn0).value_type);
    if type_kind(ret_ty) != .INT return false;
    bit_width := type_int_width(ret_ty);
    if bit_width > 64 return false;
    type_alignment := dl_int_align(bit_width, true);
    empty_scc: Fa_Set; empty_scc.list.allocator = temp;
    for * t: targets {
        fn := t.fn;
        if vkind(fn) != .FUNCTION return false;
        if is_declaration(fn) || gv_is_interposable(fn) return false;
        aar := aa_results_for(fn);
        me, _ := fa_check_function_memory_access(fn, true, *aar, *empty_scc);
        if me != ME_NONE return false;
        if glob(fn).nargs == 0 || has_uses(fn_arg(fn, 0)) return false;
        if func_ret(glob(fn).value_type) != ret_ty return false;
        gv := w.bits[t.tm.bits].gv;
        table_alignment := glob(gv).align;
        if table_alignment == 0 table_alignment = dl_alignment(glob(gv).value_type, true);
        if type_alignment > table_alignment return false;
    }

    for ci: 0..s.const_cs.count - 1 {
        args := s.const_cs[ci].args;
        csi := *s.const_cs[ci].csi;
        if !wpd_try_evaluate_functions_with_args(targets, args) continue;
        dummy: By_Arg;
        res_by_arg := *dummy;
        r := wpd_res(w, res);
        if r res_by_arg = wpd_res_by_arg(r, args);
        if wpd_try_uniform_ret_val_opt(w, targets, csi, res_by_arg) continue;
        if wpd_try_unique_ret_val_opt(w, bit_width, targets, csi, res_by_arg, s, args) continue;

        alloc_before := wpd_find_lowest_offset(w, targets, false, bit_width);
        alloc_after := wpd_find_lowest_offset(w, targets, true, bit_width);
        total_before: s64 = 0;
        total_after: s64 = 0;
        for * t: targets {
            total_before += max(cast(s64) ((alloc_before + 7) / 8) - cast(s64) wpd_allocated_before(w, t) - 1, 0);
            total_after += max(cast(s64) ((alloc_after + 7) / 8) - cast(s64) wpd_allocated_after(w, t) - 1, 0);
        }
        if min(cast(u64) total_before, cast(u64) total_after) > 128 continue;
        offset_byte: s64; offset_bit: u64;
        if total_before <= total_after offset_byte, offset_bit = wpd_set_before_return_values(w, targets, alloc_before, bit_width);
        else offset_byte, offset_bit = wpd_set_after_return_values(w, targets, alloc_after, bit_width);
        if offset_byte % cast(s64) type_alignment != 0 fatal("wholeprogramdevirt: internal: misaligned virtual constant");

        if wpd_csi_is_exported(csi) {
            res_by_arg.kind = .VirtualConstProp;
            res_by_arg.byte = cast,no_check(u32) offset_byte;
            wpd_export_constant(w, s, args, "bit", cast(u32) (1 << offset_bit), *res_by_arg.bit);
        }
        byte_c := const_int(ir.t_i32, cast,no_check(u64) offset_byte);
        bit_c := const_int(ir.t_i8, cast(u64) 1 << offset_bit);
        // the summary may have grown: look the call site info up again
        wpd_apply_virtual_const_prop(w, *s.const_cs[ci].csi, byte_c, bit_c);
    }
    return true;
}

// rebuildGlobal
wpd_rebuild_global :: (w: *Wpd, b: *Wpd_Bits) {
    if b.before.bytes.count == 0 && b.after.bytes.count == 0 return;
    gv := b.gv;
    alignment := glob(gv).align;
    if alignment == 0 alignment = dl_alignment(glob(gv).value_type, true);
    nsize := align_to(cast(u64) b.before.bytes.count, alignment);
    old := b.before.bytes.count;
    array_resize(*b.before.bytes, cast(s64) nsize);
    for k: old..b.before.bytes.count-1 b.before.bytes[k] = 0;
    size := b.before.bytes.count;
    for i: 0..size / 2 - 1 {
        t := b.before.bytes[i];
        b.before.bytes[i] = b.before.bytes[size - 1 - i];
        b.before.bytes[size - 1 - i] = t;
    }
    data_array :: (bytes: [] u8) -> Value_Id {
        aty := type_array(cast(u64) bytes.count, ir.t_i8);
        elts := NewArray(bytes.count, u64,, allocator = temp);
        all_zero := true;
        for bytes { elts[it_index] = it; if it != 0 all_zero = false; }
        if all_zero return const_zero(aty);
        return const_data(aty, elts);
    }
    init := gv_initializer(gv);
    inits: [3] Value_Id;
    inits[0] = data_array(b.before.bytes);
    inits[1] = init;
    inits[2] = data_array(b.after.bytes);
    etys: [3] Type_Id;
    for inits etys[it_index] = vtype(it);
    sty := type_literal_struct(etys, false);
    new_init := const_aggregate(.C_STRUCT, sty, inits);
    new_gv := gv_create(sty, glob(gv).is_const, .PRIVATE, new_init, "", gv, 0, glob(gv).addrspace);
    glob(new_gv).section = glob(gv).section;
    glob(new_gv).comdat = glob(gv).comdat;
    glob(new_gv).align = glob(gv).align;
    wpd_copy_metadata(new_gv, gv, cast(u64) b.before.bytes.count);
    idxs: [2] Value_Id;
    idxs[0] = const_int(ir.t_i32, 0);
    idxs[1] = const_int(ir.t_i32, 1);
    alias := ltt_alias_create(vtype(init), glob(gv).linkage, "", ce_gep(sty, new_gv, idxs, F_INBOUNDS));
    gv_set_visibility(alias, glob(gv).visibility);
    gv_take_name(alias, gv);
    ipo_rauw(gv, alias);
    gv_erase_from_parent(gv);
}

// GlobalObject::copyMetadata(Other, Offset)
wpd_copy_metadata :: (dst: Value_Id, src: Value_Id, offset: u64) {
    mds: [..] Kind_Md; mds.allocator = temp;
    get_all_metadata(src, *mds);
    kt := md_fixed("type");
    for mds {
        if offset != 0 && it.kind == kt {
            oc := ir.mds[md_op(it.md, 0)].value;
            nc := const_int(vtype(oc), const_int_zext(oc) + offset);
            add_metadata(dst, kt, md_tuple(.[md_value(nc), md_op(it.md, 1)], false));
            continue;
        }
        attachment := it.md;
        if offset != 0 && it.kind == MDK_DBG {
            gvar := attachment;
            elts: [] u64;
            if di_kind(attachment) == .GLOBAL_VARIABLE_EXPRESSION {
                gvar = md_op(attachment, 0);
                e := md_op(attachment, 1);
                if e != NONE elts = diexpr_elts(e);
            }
            ne: [..] u64; ne.allocator = temp;
            array_add(*ne, 0x23);   // DW_OP_plus_uconst
            array_add(*ne, offset);
            for elts array_add(*ne, it);
            attachment = di_gve_get(gvar, diexpr_get(ne));
        }
        add_metadata(dst, it.kind, attachment);
    }
}

// importResolution
wpd_import_resolution :: (w: *Wpd, s: *Wpd_Slot) {
    if ir.mds[s.type_id].kind != .STRING return;
    tk := si_type_id_summary(w.import_summary, ir.mds[s.type_id].str);
    if tk < 0 return;
    t := *w.import_summary.type_ids[tk];
    res: *Wpd_Res;
    for * t.wpd if it.offset == s.byte_offset { res = *it.res; break; }
    if !res return;
    if res.kind == .SingleImpl {
        if res.single_impl_name.count == 0 fatal("wholeprogramdevirt: a SingleImpl resolution without a name");
        single := module_get_or_insert_function(res.single_impl_name, type_func(ir.t_void, .[], false));
        wpd_apply_single_impl_devirt(w, s, single);
    }
    for ci: 0..s.const_cs.count - 1 {
        args := s.const_cs[ci].args;
        found: *By_Arg;
        for * res.res_by_arg if !u64_vec_less(it.args, args) && !u64_vec_less(args, it.args) { found = *it.res; break; }
        if !found continue;
        if found.kind == {
            case .UniformRetVal;
                wpd_apply_uniform_ret_val_opt(w, *s.const_cs[ci].csi, found.info);
            case .UniqueRetVal;
                addr := wpd_import_global(s, args, "unique_member");
                wpd_apply_unique_ret_val_opt(w, *s.const_cs[ci].csi, found.info != 0, addr);
            case .VirtualConstProp;
                byte := const_int(ir.t_i32, found.byte);
                bit := wpd_import_constant(w, s, args, "bit", ir.t_i8, found.bit);
                wpd_apply_virtual_const_prop(w, *s.const_cs[ci].csi, byte, bit);
        }
    }
    if res.kind == .BranchFunnel {
        jt := module_get_or_insert_function(wpd_global_name(s, .[], "branch_funnel"), type_func(ir.t_void, .[], false));
        if vkind(jt) != .FUNCTION fatal("wholeprogramdevirt: '%' is not a function", vname(jt));
        wpd_apply_icall_branch_funnel(w, s, jt);
    }
}

// removeRedundantTypeTests
wpd_remove_redundant_type_tests :: (w: *Wpd) {
    t := const_int(ir.t_i1, 1);
    for w.unsafe_tt {
        if w.unsafe_n[it_index] != 0 continue;
        if ir.v_kind[it] == .DEAD continue;
        ipo_rauw(it, t);
        erase_inst(it);
        w.unsafe_n[it_index] = -1;   // erased (the std::map keeps the dangling key; it is never seen again)
    }
}

// tryFindVirtualCallTargets
wpd_try_find_virtual_call_targets :: (w: *Wpd, targets: *[..] Wpd_Target, members: [] Wpd_Tm, byte_offset: u64) -> bool {
    for tm: members {
        gv := w.bits[tm.bits].gv;
        if !glob(gv).is_const return false;
        if !wpd_cl.speculative && wpd_vcall_visibility(gv) == 0 return false;
        fn, c := wpd_function_at_vtable_offset(gv, tm.offset + byte_offset);
        if fn == NONE return false;
        if wpd_skip(vname(fn)) return false;
        if vname(fn) == "__cxa_pure_virtual" continue;
        // mustBeUnreachableFunction (with -wholeprogramdevirt-keep-unreachable-function=false; the YAML summaries
        // carry no MustBeUnreachable flags, so a declaration is never known to be unreachable)
        if !wpd_cl.keep_unreachable && !is_declaration(fn) && inst_op(block_terminator(fn_entry(fn))) == .UNREACHABLE continue;
        t: Wpd_Target; t.fn = c; t.tm = tm;
        array_add(targets, t);
    }
    return targets.count > 0;
}

// ---------------------------------------------------------------- DevirtModule::run

wpd_intrinsic_decl :: (name: string) -> Value_Id {
    f := lookup_global(name);
    if f == NONE || vkind(f) != .FUNCTION return NONE;
    return f;
}

wpd_run_module :: (export_summary: *Summary_Index, import_summary: *Summary_Index) -> bool {
    if (export_summary && export_summary.partially_split) || (import_summary && import_summary.partially_split) return false;
    if wpd_cl.speculative fatal("wholeprogramdevirt: speculative devirtualization (-devirtualize-speculatively) is not supported yet");
    tt_fn := wpd_intrinsic_decl("llvm.type.test");
    tcl_fn := wpd_intrinsic_decl("llvm.type.checked.load");
    tclr_fn := wpd_intrinsic_decl("llvm.type.checked.load.relative");
    assume_fn := wpd_intrinsic_decl("llvm.assume");
    if !export_summary &&
       ((tt_fn == NONE || !has_uses(tt_fn)) || assume_fn == NONE || !has_uses(assume_fn)) &&
       (tcl_fn == NONE || !has_uses(tcl_fn)) && (tclr_fn == NONE || !has_uses(tclr_fn))
        return false;

    w: Wpd;
    w.export_summary = export_summary;
    w.import_summary = import_summary;
    w.int_ptr_ty = type_int(dl_ptr_spec(0).bits);
    t := triple_parse(ir.triple);
    w.arch = t.arch;
    w.obj = t.obj;
    w.tid_map.allocator = temp;
    w.slot_map.allocator = temp;
    w.optimized.allocator = temp;

    wpd_build_type_identifier_map(*w);
    if tt_fn != NONE && assume_fn != NONE wpd_scan_type_test_users(*w, tt_fn);
    if tcl_fn != NONE wpd_scan_type_checked_load_users(*w, tcl_fn);
    if tclr_fn != NONE wpd_scan_type_checked_load_users(*w, tclr_fn);

    vk := md_fixed("vcall_visibility");
    if import_summary {
        for * w.slots wpd_import_resolution(*w, it);
        wpd_remove_redundant_type_tests(*w);
        for ir.m_globals set_metadata(it, vk, NONE);
        return true;
    }

    if w.tid_map.count == 0 return true;

    if export_summary {
        si := export_summary;
        // MetadataByGUID over the MDString type ids of TypeIdMap
        by_guid: Table(u64, [..] Md_Id); by_guid.allocator = temp;
        for k, tid: w.tid_map {
            if ir.mds[tid].kind != .STRING continue;
            g := guid_of_name(ir.mds[tid].str);
            p := table_find_pointer(*by_guid, g);
            if !p { e: [..] Md_Id; e.allocator = temp; table_add(*by_guid, g, e); p = table_find_pointer(*by_guid, g); }
            array_add(p, tid);
        }
        if by_guid.count > 0 for * gi, gx: si.gvs for * fs, sx: gi.sums {
            if fs.is_alias continue;   // dyn_cast<FunctionSummary>: only function summaries carry vcalls
            ref := Wpd_Fs_Ref.{gx, sx};
            for vf: fs.tt_assume_vcalls {
                p := table_find_pointer(*by_guid, vf.guid);
                if p for md: p.* { s := *w.slots[wpd_slot(*w, md, vf.offset)]; array_add(*s.cs.tta_users, ref); s.cs.all_devirted = false; }
            }
            for vf: fs.tcl_vcalls {
                p := table_find_pointer(*by_guid, vf.guid);
                if p for md: p.* { s := *w.slots[wpd_slot(*w, md, vf.offset)]; array_add(*s.cs.tcl_users, ref); s.cs.all_devirted = false; }
            }
            for vc: fs.tt_assume_const_vcalls {
                p := table_find_pointer(*by_guid, vc.vfunc.guid);
                if p for md: p.* { c := wpd_const_csi(*w.slots[wpd_slot(*w, md, vc.vfunc.offset)], vc.args); array_add(*c.tta_users, ref); c.all_devirted = false; }
            }
            for vc: fs.tcl_const_vcalls {
                p := table_find_pointer(*by_guid, vc.vfunc.guid);
                if p for md: p.* { c := wpd_const_csi(*w.slots[wpd_slot(*w, md, vc.vfunc.offset)], vc.args); array_add(*c.tcl_users, ref); c.all_devirted = false; }
            }
        }
    }

    did_vcp := false;
    for si: 0..w.slots.count - 1 {
        s := *w.slots[si];
        targets: [..] Wpd_Target; targets.allocator = temp;
        res: Wpd_Res_Ref;
        found, mk := table_find(*w.tid_map, s.type_id);
        members: [] Wpd_Tm;
        if found members = w.tid_members[mk];
        if export_summary && ir.mds[s.type_id].kind == .STRING && members.count {
            res.tk = si_get_or_insert_type_id_summary(export_summary, ir.mds[s.type_id].str);
            res.offset = s.byte_offset;
            wpd_res(*w, res);
        }
        if wpd_try_find_virtual_call_targets(*w, *targets, members, s.byte_offset) {
            single := wpd_try_single_impl_devirt(*w, targets, s, res);
            if !single {
                if wpd_try_virtual_const_prop(*w, targets, s, res) did_vcp = true;
                wpd_try_icall_branch_funnel(*w, targets, s, res);
            }
        }
        // CFI: undevirtualized type.checked.load users get a type test in their summaries (FS->addTypeTest)
        if export_summary && ir.mds[s.type_id].kind == .STRING {
            g := guid_of_name(ir.mds[s.type_id].str);
            add :: (si: *Summary_Index, c: *Wpd_Csi, g: u64) {
                if c.all_devirted return;
                for r: c.tcl_users {
                    fs := *si.gvs[r.gi].sums[r.si];
                    dup := false;
                    for fs.type_tests if it == g { dup = true; break; }
                    if !dup array_add(*fs.type_tests, g);
                }
            }
            add(export_summary, *s.cs, g);
            for * s.const_cs add(export_summary, *it.csi, g);
        }
    }

    wpd_remove_redundant_type_tests(*w);
    if did_vcp for * w.bits wpd_rebuild_global(*w, it);
    for ir.m_globals set_metadata(it, vk, NONE);
    return true;
}

// WholeProgramDevirtPass::run (use_cl: named on the command line, DevirtModule::runForTesting)
whole_program_devirt_run :: (use_cl := true) -> Preserved {
    changed: bool;
    if use_cl {
        summary: Summary_Index;
        summary.gv_map.allocator = temp;
        if wpd_cl.read_summary.count read_summary_yaml(wpd_cl.read_summary, *summary, tconcat("-wholeprogramdevirt-read-summary: ", wpd_cl.read_summary));
        if wpd_cl.write_summary.count fatal("-wholeprogramdevirt-write-summary is not supported (writing summaries is not ported)");
        changed = wpd_run_module(ifx wpd_cl.summary_action == .Export then *summary else null,
                                 ifx wpd_cl.summary_action == .Import then *summary else null);
    } else {
        changed = wpd_run_module(null, null);
    }
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
