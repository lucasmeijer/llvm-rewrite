// Building the coroutine frame: normalization (splitting around suspend points, PHI rewriting, swifterror),
// rematerialization, frame layout (FrameTypeBuilder + performOptimizedStructLayout, alloca storage reuse with
// StackLifetime), spills / reloads with their debug records, local coro.alloca lowering.
// Ported from llvm/lib/Transforms/Coroutines/CoroFrame.cpp and llvm/lib/Support/OptimizedStructLayout.cpp.

// ---------------------------------------------------------------- performOptimizedStructLayout

OSL_FLEXIBLE :: 0xFFFF_FFFF_FFFF_FFFF;
Osl_Field :: struct { offset: u64 = OSL_FLEXIBLE; size: u64; align: u64; id: s64; scratch: s64; }

// performOptimizedStructLayout: reorders `fields` (a fixed-offset prefix, then flexible fields) and assigns offsets
perform_optimized_struct_layout :: (fields: [] Osl_Field) -> (size: u64, align: u64) {
    max_align: u64 = 1;
    n := fields.count;
    first_flex := 0;
    while first_flex < n && fields[first_flex].offset != OSL_FLEXIBLE { max_align = max(max_align, fields[first_flex].align); first_flex += 1; }
    if first_flex == n {
        size: u64 = 0;
        if n > 0 size = fields[n - 1].offset + fields[n - 1].size;
        return size, max_align;
    }
    for k: first_flex..n - 1 { fields[k].scratch = k - first_flex; max_align = max(max_align, fields[k].align); }
    // array_pod_sort: alignment descending, size descending, original order
    for i: first_flex + 1..n - 1 {
        x := fields[i];
        j := i - 1;
        before :: (a: Osl_Field, b: Osl_Field) -> bool {
            if a.align != b.align return a.align > b.align;
            if a.size != b.size return a.size > b.size;
            return a.scratch < b.scratch;
        }
        while j >= first_flex && before(x, fields[j]) { fields[j + 1] = fields[j]; j -= 1; }
        fields[j + 1] = x;
    }
    {
        has_padding := false;
        last_end: u64 = 0;
        for k: 0..first_flex - 1 {
            if last_end != fields[k].offset { has_padding = true; break; }
            last_end = fields[k].offset + fields[k].size;
        }
        if !has_padding {
            for k: first_flex..n - 1 {
                off := align_to(last_end, fields[k].align);
                if last_end != off { has_padding = true; break; }
                fields[k].offset = off;
                last_end = off + fields[k].size;
            }
        }
        if !has_padding return last_end, max_align;
    }
    Queue :: struct { min_size: u64; head: s64; align: u64; }
    queues: [..] Queue; queues.allocator = temp;
    i := first_flex;
    while i < n {
        head := i;
        al := fields[i].align;
        min_size := fields[i].size;
        last_in := i;
        i += 1;
        while i < n && fields[i].align == al {
            fields[last_in].scratch = i;
            last_in = i;
            min_size = min(min_size, fields[i].size);
            i += 1;
        }
        fields[last_in].scratch = -1;
        array_add(*queues, .{min_size, head, al});
    }
    layout: [..] Osl_Field; layout.allocator = temp;
    last_end: u64 = 0;
    splice_from_queue :: (queues: *[..] Queue, fields: [] Osl_Field, q: s64, last: s64, cur: s64) {
        if last >= 0 {
            fields[last].scratch = fields[cur].scratch;
            if fields[cur].scratch < 0 queues.*[q].min_size = fields[last].size;
        } else {
            nh := fields[cur].scratch;
            if nh >= 0 queues.*[q].head = nh;
            else array_ordered_remove_by_index(queues, q);
        }
    }
    add_to_layout :: (q: s64, last: s64, cur: s64, offset: u64) #expand {
        splice_from_queue(*queues, fields, q, last, cur);
        f := fields[cur];
        f.offset = offset;
        array_add(*layout, f);
        last_end = offset + f.size;
    }
    try_add_filler_from_queue :: (q: s64, start: u64, has_end: bool, end: u64) -> bool #expand {
        max_viable := ifx has_end then end - start else OSL_FLEXIBLE;
        if queues[q].min_size > max_viable return false;
        last := -1;
        cur := queues[q].head;
        while cur >= 0 {
            if fields[cur].size <= max_viable { add_to_layout(q, last, cur, start); return true; }
            last = cur;
            cur = fields[cur].scratch;
        }
        fatal("internal: didn't find a match in queue despite its MinSize");
        return false;
    }
    try_add_best_field :: (has_before: bool, before: u64) -> bool #expand {
        qb := 0;
        qe := queues.count;
        first_q := qb;
        while first_q != qe { if last_end % queues[first_q].align == 0 break; first_q += 1; }
        offset := last_end;
        while true {
            for q: first_q..qe - 1 if try_add_filler_from_queue(q, offset, has_before, before) return true;
            qe = first_q;
            if first_q == qb return false;
            first_q -= 1;
            offset = align_to(last_end, queues[first_q].align);
            if has_before && offset >= before return false;
            while first_q != qb && offset == align_to(last_end, queues[first_q - 1].align) first_q -= 1;
        }
        return false;
    }
    for k: 0..first_flex - 1 {
        while last_end != fields[k].offset {
            if !try_add_best_field(true, fields[k].offset) break;
        }
        array_add(*layout, fields[k]);
        last_end = fields[k].offset + fields[k].size;
    }
    while queues.count {
        ok := try_add_best_field(false, 0);
        assert(ok, "didn't find a field with no fixed limit?");
    }
    for k: 0..n - 1 fields[k] = layout[k];
    return last_end, max_align;
}

// ---------------------------------------------------------------- FrameTypeBuilder / FrameDataInfo

Ftb_Field :: struct { size: u64; offset: u64; align: u64; dyn_buf: u64; }
Ftb :: struct {
    fields: [..] Ftb_Field;
    struct_size: u64;
    struct_align: u64 = 1;
    max_frame_align: u64;   // 0 = none
    finished: bool;
}

// addField(FieldSize, FieldAlignment, IsHeader)
ftb_add_field_sized :: (b: *Ftb, size_in: u64, align_in: u64, is_header := false) -> s64 {
    if size_in == 0 return 0;
    size := size_in; al := align_in;
    dyn: u64 = 0;
    if b.max_frame_align && al > b.max_frame_align {
        dyn = align_to(b.max_frame_align, al) - b.max_frame_align;   // offsetToAlignment(MaxFrameAlignment, FieldAlignment)
        al = b.max_frame_align;
        size += dyn;
    }
    off: u64;
    if is_header { off = align_to(b.struct_size, al); b.struct_size = off + size; }
    else off = OSL_FLEXIBLE;
    array_add(*b.fields, .{size, off, al, dyn});
    return b.fields.count - 1;
}
// addField(Ty, MaybeFieldAlignment, IsHeader, IsSpillOfValue)
ftb_add_field_type :: (b: *Ftb, ty: Type_Id, maybe_align: u64, is_header := false, is_spill_of_value := false) -> s64 {
    size := dl_type_alloc_size(ty);
    abi := dl_abi_align(ty);
    ty_align := abi;
    if is_spill_of_value && b.max_frame_align && b.max_frame_align < abi ty_align = b.max_frame_align;
    al := ifx maybe_align then maybe_align else ty_align;
    return ftb_add_field_sized(b, size, al, is_header);
}
// AllocaInst::getAllocationSize (0, false when not static)
coro_alloca_allocation_size :: (ai: Value_Id) -> (u64, bool) {
    sz := dl_type_alloc_size(inst(ai).ty2);
    if sz == 0 return 0, true;
    n := op(ai, 0);
    if vkind(n) == .C_INT && const_int_zext(n) == 1 && !is_vector_type(vtype(n)) return sz, true;
    if vkind(n) != .C_INT return 0, false;
    if type_int_width(vtype(n)) > 64 return 0, false;
    return sz * const_int_zext(n), true;
}
ftb_add_field_for_alloca :: (b: *Ftb, ai: Value_Id, is_header := false) -> s64 {
    if type_kind(inst(ai).ty2) == .SVECTOR fatal("Coroutines cannot handle non static or vscale allocas yet");
    sz, ok := coro_alloca_allocation_size(ai);
    if !ok fatal("Coroutines cannot handle non static or vscale allocas yet");
    return ftb_add_field_sized(b, sz, inst(ai).align, is_header);
}
// FrameTypeBuilder::finish
ftb_finish :: (b: *Ftb) {
    lf := NewArray(b.fields.count, Osl_Field,, allocator = temp);
    for b.fields { lf[it_index].offset = it.offset; lf[it_index].size = it.size; lf[it_index].align = it.align; lf[it_index].id = it_index; }
    b.struct_size, b.struct_align = perform_optimized_struct_layout(lf);
    for lf b.fields[it.id].offset = it.offset;
    b.finished = true;
}

Frame_Data :: struct {
    spills: *Spill_Info;
    allocas: *[..] Coro_Alloca_Info;
    field_index: Table(Value_Id, s64);
    align: Table(Value_Id, u64);
    dyn_align: Table(Value_Id, u64);
    offset: Table(Value_Id, u64);
}
fd_init :: (fd: *Frame_Data, spills: *Spill_Info, allocas: *[..] Coro_Alloca_Info) {
    fd.spills = spills; fd.allocas = allocas;
    fd.field_index.allocator = temp; fd.align.allocator = temp; fd.dyn_align.allocator = temp; fd.offset.allocator = temp;
}
fd_all_defs :: (fd: *Frame_Data) -> [..] Value_Id {
    r: [..] Value_Id; r.allocator = temp;
    for fd.spills.keys array_add(*r, it);
    for fd.allocas.* array_add(*r, it.alloca);
    return r;
}
fd_get :: (t: *Table(Value_Id, u64), v: Value_Id) -> u64 { found, x := table_find(t, v); assert(found); return x; }
// FrameDataInfo::updateLayoutInfo
fd_update_layout_info :: (fd: *Frame_Data, b: *Ftb) {
    upd :: (fd: *Frame_Data, b: *Ftb, v: Value_Id) {
        found, idx := table_find(*fd.field_index, v);
        assert(found, "Value does not have a frame field index");
        f := b.fields[idx];
        table_set(*fd.align, v, f.align);
        table_set(*fd.dyn_align, v, ifx f.dyn_buf then f.dyn_buf + f.align else 0);
        table_set(*fd.offset, v, f.offset);
    }
    for fd.spills.keys upd(fd, b, it);
    for fd.allocas.* upd(fd, b, it.alloca);
}

// FrameTypeBuilder::addFieldForAllocas
ftb_add_field_for_allocas :: (b: *Ftb, f: Value_Id, fd: *Frame_Data, shape: *Coro_Shape, optimize_frame: bool) {
    sets: [..] [..] Value_Id; sets.allocator = temp;
    defer {
        // AddFieldForAllocasAtExit
        for set: sets {
            id := ftb_add_field_for_alloca(b, set[0]);
            for set table_set(*fd.field_index, it, id);
        }
    }
    if !optimize_frame {
        for fd.allocas.* { s: [..] Value_Id; s.allocator = temp; array_add(*s, it.alloca); array_add(*sets, s); }
        return;
    }
    // the default destination of the suspend switches is the "suspended" exit: make the resume path the default
    // while computing liveness
    sw_list: [..] Value_Id; sw_list.allocator = temp;
    sw_default: [..] Value_Id; sw_default.allocator = temp;
    for csi: shape.coro_suspends {
        u := ir.v_first_use[csi];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if is_inst(usr) && inst_op(usr) == .SWITCH {
                idx := -1;
                for sw_list if it == usr { idx = it_index; break; }
                if idx < 0 { array_add(*sw_list, usr); array_add(*sw_default, get_successor(usr, 0)); }
                else sw_default[idx] = get_successor(usr, 0);
                set_successor(usr, 0, get_successor(usr, 1));
            }
        }
    }
    alloca_list: [..] Value_Id; alloca_list.allocator = temp;
    for fd.allocas.* array_add(*alloca_list, it.alloca);
    sl := stack_lifetime_run(f, alloca_list, may_liveness = true);
    // sort(FrameData.Allocas, size descending): std::sort
    coro_sort_allocas_by_size(fd.allocas.*);
    for a: fd.allocas.* {
        merged := false;
        for * set: sets {
            no_interference := true;
            for x: set.* if stack_lifetime_interfere(*sl, a.alloca, x) { no_interference = false; break; }
            alignable := inst(set.*[0]).align % inst(a.alloca).align == 0;
            if !(no_interference && alignable) continue;
            array_add(set, a.alloca);
            merged = true;
            break;
        }
        if !merged { s: [..] Value_Id; s.allocator = temp; array_add(*s, a.alloca); array_add(*sets, s); }
    }
    for sw_list set_successor(it, 0, sw_default[it_index]);
}

// sort(FrameData.Allocas, [](a, b) { return size(a) > size(b); }): libstdc++ std::sort on 40-byte AllocaInfo values
coro_sort_allocas_by_size :: (a: [] Coro_Alloca_Info) {
    if a.count < 2 return;
    idx := NewArray(a.count, Value_Id,, allocator = temp);
    for k: 0..a.count - 1 idx[k] = cast(Value_Id) k;
    Ctx :: struct { a: [] Coro_Alloca_Info; }
    c: Ctx; c.a = a;
    std_sort_by(idx, (x: Value_Id, y: Value_Id, d: *void) -> bool {
        cc := cast(*Ctx) d;
        sx, _ := coro_alloca_allocation_size(cc.a[x].alloca);
        sy, _ := coro_alloca_allocation_size(cc.a[y].alloca);
        return sx > sy;
    }, *c);
    copy := NewArray(a.count, Coro_Alloca_Info,, allocator = temp);
    for k: 0..a.count - 1 copy[k] = a[idx[k]];
    for k: 0..a.count - 1 a[k] = copy[k];
}

// hasAccessingPromiseBeforeCB
coro_has_accessing_promise_before_cb :: (dt: *Dom_Tree, shape: *Coro_Shape) -> bool {
    pa := shape.sw_promise_alloca;
    u := ir.v_first_use[pa];
    while u != NONE {
        usr := ir.u_user[u];
        uu := u;
        u = ir.u_next[u];
        if !is_inst(usr) || dt_dominates_inst(dt, shape.coro_begin, usr) continue;
        o := inst_op(usr);
        if o == .CALL {
            if call_only_reads_memory(usr) continue;
            argno := cast(u32)(uu - op_use(usr, 0));
            if argno < call_arg_count(usr) && call_only_reads_memory_arg(usr, argno) continue;
            return true;
        }
        if o == .STORE || o == .GEP || o == .BITCAST return true;
    }
    return false;
}

// buildFrameLayout
coro_build_frame_layout :: (f: Value_Id, dt: *Dom_Tree, shape: *Coro_Shape, fd: *Frame_Data, optimize_frame: bool) {
    b: Ftb; b.fields.allocator = temp;
    if shape.abi == .ASYNC b.max_frame_align = shape.as_context_alignment;
    promise := ifx shape.abi == .SWITCH then shape.sw_promise_alloca else NONE;
    switch_index_field := -1;
    switch_index_type: Type_Id = NONE;
    if shape.abi == .SWITCH {
        ftb_add_field_type(*b, ir.t_ptr, 0, true);
        ftb_add_field_type(*b, ir.t_ptr, 0, true);
        if promise != NONE table_set(*fd.field_index, promise, ftb_add_field_for_alloca(*b, promise, true));
        bits: u32 = 1;
        ns := cast(u64) shape.coro_suspends.count;
        // Log2_64_Ceil(N) = 64 - countl_zero(N - 1): 64 for N = 0
        lg: u32 = 64;
        x := ns - 1;   // wraps for N = 0
        while lg > 0 && (x >> cast(u64)(lg - 1)) & 1 == 0 lg -= 1;
        if lg > bits bits = lg;
        switch_index_type = type_int(bits);
        switch_index_field = ftb_add_field_type(*b, switch_index_type, 0);
    }
    ftb_add_field_for_allocas(*b, f, fd, shape, optimize_frame);
    if shape.abi == .SWITCH && promise != NONE {
        info: Coro_Alloca_Info; info.alloca = promise;
        info.alias_insts.allocator = temp; info.alias_offsets.allocator = temp;
        info.may_write_before_coro_begin = coro_has_accessing_promise_before_cb(dt, shape);
        array_add(fd.allocas, info);
    }
    for def: fd.spills.keys {
        field_ty := vtype(def);
        ma: u64 = 0;
        if vkind(def) == .ARGUMENT {
            pf := arg_parent(def); k := arg_no(def);
            byval := attr_set_find(attr_list_param(glob(pf).attrs, k), .ByVal);
            if byval { field_ty = byval.ty; ma = fn_param_align(pf, k); }
        }
        id := ftb_add_field_type(*b, field_ty, ma, false, true);
        table_set(*fd.field_index, def, id);
    }
    ftb_finish(*b);
    fd_update_layout_info(fd, *b);
    shape.frame_align = b.struct_align;
    shape.frame_size = b.struct_size;
    if shape.abi == {
      case .SWITCH;
        shape.sw_destroy_offset = dl_ptr_spec(0).bits / 8;
        idx := b.fields[switch_index_field];
        shape.sw_index_type = switch_index_type;
        shape.sw_index_align = idx.align;
        shape.sw_index_offset = idx.offset;
        shape.frame_size = align_to(shape.frame_size, shape.frame_align);
      case .RETCON; #through;
      case .RETCON_ONCE;
        id := coro_shape_id(shape);
        shape.rc_is_frame_inline_in_storage = b.struct_size <= coro_retcon_storage_size(id) && b.struct_align <= coro_retcon_storage_align(id);
      case .ASYNC;
        shape.as_frame_offset = align_to(shape.as_context_header_size, shape.frame_align);
        shape.as_context_size = align_to(shape.as_frame_offset + shape.frame_size, shape.as_context_alignment);
        if shape.as_context_alignment < shape.frame_align
            fatal("The alignment requirment of frame variables cannot be higher than the alignment of the async function context");
    }
}

// ---------------------------------------------------------------- spills and reloads

// extractByvalIfArgument
coro_extract_byval_if_argument :: (v: Value_Id) -> Type_Id {
    if vkind(v) != .ARGUMENT return NONE;
    pf := arg_parent(v); k := arg_no(v);
    coro_fn_remove_param_attr(pf, k, .Captures);
    byval := attr_set_find(attr_list_param(glob(pf).attrs, k), .ByVal);
    if byval return byval.ty;
    return NONE;
}

// createStoreIntoFrame
coro_create_store_into_frame :: (b: *Irb, def: Value_Id, byval_ty: Type_Id, shape: *Coro_Shape, fd: *Frame_Data) {
    offset := fd_get(*fd.offset, def);
    g := shape.frame_ptr;
    if offset != 0 g = irb_inbounds_ptr_add(b, g, const_int(ir.t_i64, offset), tconcat(vname(def), ".spill.addr"));
    al := fd_get(*fd.align, def);
    if byval_ty != NONE irb_memcpy(b, g, al, def, al, const_int(ir.t_i64, dl_type_store_size(byval_ty)), false);
    else irb_store(b, def, g, al);
}

// createGEPToFramePointer
coro_create_gep_to_frame_pointer :: (fd: *Frame_Data, b: *Irb, shape: *Coro_Shape, orig: Value_Id) -> Value_Id {
    offset := fd_get(*fd.offset, orig);
    ptr := irb_inbounds_ptr_add(b, shape.frame_ptr, const_int(ir.t_i64, offset));
    if is_inst(orig) && inst_op(orig) == .ALLOCA {
        da := fd_get(*fd.dyn_align, orig);
        if da != 0 {
            int_ptr_ty := irb_int_ptr_type(vtype(orig));
            pv := irb_cast(b, .PTRTOINT, ptr, int_ptr_ty);
            mask := const_int(int_ptr_ty, inst(orig).align - 1);
            pv = irb_binop(b, .ADD, pv, mask);
            pv = irb_binop(b, .AND, pv, irb_not(b, mask));
            return irb_cast(b, .INTTOPTR, pv, vtype(orig));
        }
        if vtype(ptr) != vtype(orig) ptr = irb_pointer_bitcast_or_addrspacecast(b, ptr, vtype(orig), tconcat(vname(orig), ".cast"));
    }
    return ptr;
}

// findDbgRecordsThroughLoads<record_type>
coro_find_dbg_records_through_loads :: (f: Value_Id, def: Value_Id, kind: Dbg_Record_Kind, out: *[..] u32) {
    coro_find_dbg_records(f, def, kind, out);
    if get_metadata(f, MDK_DBG) == NONE return;
    cur := def;
    while out.count == 0 && is_inst(cur) && inst_op(cur) == .LOAD {
        if !is_ptr_type(vtype(cur)) break;
        cur = op(cur, 0);
        if !(is_inst(cur) && (inst_op(cur) == .ALLOCA || inst_op(cur) == .LOAD)) break;
        coro_find_dbg_records(f, cur, kind, out);
    }
}

// a new DbgVariableRecord inserted with BasicBlock::insertDbgRecordBefore(DR, Where): at the head of Where's records
// when the iterator has the head bit, else at their end
coro_new_dbg_record :: (kind: Dbg_Record_Kind, v: Value_Id, var: Md_Id, expr: Md_Id, dbg: Md_Id, where: Value_Id, head: bool) -> u32 {
    r: Dbg_Record;
    r.kind = kind; r.loc = md_value(v); r.var = var; r.expr = expr; r.dbg = dbg;
    array_add(*ir.dbg_records, r);
    id := cast(u32) ir.dbg_records.count;
    dbgr_restamp(id);
    if head records_prepend(where, id); else attach_records_before(where, id);
    if dbg_index.fn != NONE dbgr_index_record(id);
    return id;
}
// DbgRecord::removeFromParent
coro_dbgr_remove_from_parent :: (r: u32) {
    rec := dbgr(r);
    o := rec.owner;
    if o == NONE return;
    x := inst(o).records;
    if x == r inst(o).records = rec.next;
    else {
        while dbgr(x).next != r x = dbgr(x).next;
        dbgr(x).next = rec.next;
    }
    rec.next = 0;
    rec.owner = NONE;
}

// DIExpression::prepend(Expr, Flags)
DIEXPR_DEREF_BEFORE :: 1;
DIEXPR_ENTRY_VALUE :: 8;
coro_diexpr_prepend :: (expr: Md_Id, flags: u32) -> Md_Id {
    ops: [..] u64; ops.allocator = temp;
    if flags & DIEXPR_DEREF_BEFORE array_add(*ops, DW_OP_DEREF_);
    return diexpr_prepend_opcodes(expr, *ops, false, (flags & DIEXPR_ENTRY_VALUE) != 0);
}

// salvageDebugInfoImpl (CoroFrame.cpp): (storage, expression), NONE storage = nullopt
coro_salvage_debug_info_impl :: (arg_to_alloca: *Table(Value_Id, Value_Id), use_entry_value: bool, f: Value_Id, storage_in: Value_Id,
                                 expr_in: Md_Id, skip_outermost_load_in: bool) -> (Value_Id, Md_Id) {
    storage := storage_in; expr := expr_in; skip_outermost_load := skip_outermost_load_in;
    b: Irb;
    entry := fn_entry(f);
    ip := block_first_insertion_pt(entry);
    head := true;   // getFirstInsertionPt carries the head bit; ++ clears it
    while ip != NONE && call_iid(ip) != NOT_INTRINSIC && inst_op(ip) == .CALL { ip = inst_next(ip); head = false; }
    irb_set_at(*b, entry, ip, head);
    while storage != NONE && is_inst(storage) {
        o := inst_op(storage);
        if o == .LOAD {
            storage = op(storage, 0);
            if !skip_outermost_load expr = coro_diexpr_prepend(expr, DIEXPR_DEREF_BEFORE);
        } else if o == .STORE {
            storage = op(storage, 0);
        } else {
            ops: [..] u64; ops.allocator = temp;
            additional: [..] Value_Id; additional.allocator = temp;
            nlo := ifx expr != NONE then diexpr_num_location_operands(expr) else 0;
            o2 := salvage_debug_info_impl(storage, nlo, *ops, *additional);
            if o2 == NONE || additional.count != 0 break;
            storage = o2;
            expr = diexpr_append_ops_to_arg(expr, ops, 0, false);
        }
        skip_outermost_load = false;
    }
    if storage == NONE return NONE, NONE;
    is_arg := vkind(storage) == .ARGUMENT;
    single_ok, _ := diexpr_single_location_elts(expr);
    will_use_entry_value := use_entry_value && is_arg && fn_has_param_attr(arg_parent(storage), arg_no(storage), .SwiftAsync) &&
                            !coro_diexpr_is_entry_value(expr) && single_ok;
    if will_use_entry_value expr = coro_diexpr_prepend(expr, DIEXPR_ENTRY_VALUE);
    if is_arg && !will_use_entry_value && single_ok {
        found, cached := table_find(arg_to_alloca, storage);
        if !found {
            a := new_inst(.ALLOCA, ir.t_ptr, 1);
            inst(a).ty2 = vtype(storage);
            set_op(a, 0, const_int(ir.t_i32, 1));
            inst(a).align = dl_pref_align(vtype(storage));
            inst(a).addrspace = 0;
            irb_insert(*b, a, tconcat(vname(storage), ".debug"));
            irb_store(*b, storage, a, dl_abi_align(vtype(storage)));
            cached = a;
            table_set(arg_to_alloca, storage, a);
        }
        storage = cached;
        expr = coro_diexpr_prepend(expr, DIEXPR_DEREF_BEFORE);
    }
    expr = diexpr_fold_constant_math(expr);
    return storage, expr;
}
// DIExpression::isEntryValue
coro_diexpr_is_entry_value :: (expr: Md_Id) -> bool {
    e := diexpr_elts(expr);
    return e.count > 0 && e[0] == DW_OP_LLVM_ENTRY_VALUE;
}

// coro::salvageDebugInfo
coro_salvage_debug_info :: (arg_to_alloca: *Table(Value_Id, Value_Id), r: u32, use_entry_value: bool) {
    f := inst_fn(dbgr(r).owner);
    kind := dbgr(r).kind;
    skip := kind == .DECLARE || kind == .DECLARE_VALUE;
    vals: [..] Value_Id; vals.allocator = temp;
    dbgr_location_ops(r, *vals);
    original: Value_Id = ifx vals.count then vals[0] else NONE;
    storage, expr := coro_salvage_debug_info_impl(arg_to_alloca, use_entry_value, f, original, dbgr(r).expr, skip);
    if storage == NONE return;
    if original != storage dbgr_replace_variable_location_op(r, original, storage);
    dbgr(r).expr = expr;
    if kind == .DECLARE || kind == .DECLARE_VALUE {
        has_pt := false; pt: Value_Id = NONE; head := false;
        if is_inst(storage) {
            ip, _, h := inst_insertion_point_after_def(storage);
            has_pt = true; pt = ip; head = h;
            iloc := get_metadata(storage, MDK_DBG);
            dloc := dbgr(r).dbg;
            if iloc != NONE && dloc != NONE && diloc_subprogram(dloc) == diloc_subprogram(iloc) dbgr(r).dbg = iloc;
        } else if vkind(storage) == .ARGUMENT {
            has_pt = true; pt = block_first(fn_entry(f)); head = false;
        }
        if has_pt {
            if pt == NONE fatal("internal: coroutines: inserting a debug record at the end of a block is not supported");
            coro_dbgr_remove_from_parent(r);
            if kind == .DECLARE_VALUE {
                loc := dbgr(r).loc;
                if loc != NONE && ir.mds[loc].kind == .VALUE
                    dbgr(r).kind = ifx is_ptr_type(vtype(ir.mds[loc].value)) then Dbg_Record_Kind.DECLARE else .VALUE;
            }
            if head records_prepend(pt, r); else attach_records_before(pt, r);
            dbgr_restamp(r);
        }
    }
}

// handleAccessBeforeCoroBegin
coro_handle_access_before_coro_begin :: (fd: *Frame_Data, shape: *Coro_Shape, b: *Irb, ai: Value_Id) {
    // CreateAllocationSize(i64, Alloca)
    size := const_int(ir.t_i64, dl_type_alloc_size(inst(ai).ty2));
    n := op(ai, 0);
    if !(vkind(n) == .C_INT && const_int_zext(n) == 1) {
        nz := coro_irb_int_cast(b, n, ir.t_i64, false);
        size = irb_binop(b, .MUL, nz, size);
    }
    g := coro_create_gep_to_frame_pointer(fd, b, shape, ai);
    irb_memcpy(b, g, fd_get(*fd.align, ai), ai, inst(ai).align, size, false);
}

// MDString::getIfExists + MDNode::getIfExists for the "Simple C++ TBAA" root
coro_tbaa_root_if_exists :: () -> Md_Id {
    s := md_string_if_exists("Simple C++ TBAA");
    if s == NONE return NONE;
    return md_tuple_if_exists(.[s]);
}

// insertSpills
coro_insert_spills :: (fd: *Frame_Data, shape: *Coro_Shape) {
    f := inst_fn(shape.coro_begin);
    b: Irb;
    dt := dt_new(false); dt_recalculate(dt, f);
    defer dt_free(dt);
    arg_to_alloca: Table(Value_Id, Value_Id); arg_to_alloca.allocator = temp;
    tbaa_tag: Md_Id = NONE;
    root := coro_tbaa_root_if_exists();
    if md_string_if_exists("Simple C++ TBAA") != NONE {
        // MDB.createTBAAScalarTypeNode(F.Frame Slot, TBAARoot) + createTBAAStructTagNode(Scalar, Scalar, 0)
        scalar := md_tuple(.[md_string(tconcat(vname(f), ".Frame Slot")), root, md_value(const_int(ir.t_i64, 0))], false);
        tbaa_tag = md_tuple(.[scalar, scalar, md_value(const_int(ir.t_i64, 0))], false);
    }
    dvrs: [..] u32; dvrs.allocator = temp;
    for def: fd.spills.keys {
        byval_ty := coro_extract_byval_if_argument(def);
        sbb, spt, shead := coro_get_spill_insertion_pt(shape, def, dt);
        irb_set_at(*b, sbb, spt, shead);
        coro_create_store_into_frame(*b, def, byval_ty, shape, fd);
        cur_block: Value_Id = NONE;
        cur_reload: Value_Id = NONE;
        for u: fd.spills.uses[it_index] {
            if cur_block != inst_block(u) {
                cur_block = inst_block(u);
                irb_set_at(*b, cur_block, block_first_insertion_pt(cur_block), true);
                gep := coro_create_gep_to_frame_pointer(fd, *b, shape, def);
                set_name(gep, tconcat(vname(def), ".reload.addr"));
                if byval_ty != NONE cur_reload = gep;
                else {
                    li := irb_load(*b, vtype(def), gep, fd_get(*fd.align, def), false, tconcat(vname(def), ".reload"));
                    if tbaa_tag != NONE set_metadata(li, MDK_TBAA, tbaa_tag);
                    cur_reload = li;
                }
                coro_find_dbg_records_through_loads(f, def, .DECLARE, *dvrs);
                for ddi: dvrs {
                    coro_new_dbg_record(.DECLARE, cur_reload, dbgr(ddi).var, dbgr(ddi).expr, dbgr(ddi).dbg, b.pt, b.head);
                    coro_salvage_debug_info(*arg_to_alloca, ddi, false);
                }
            }
            coro_find_dbg_records_through_loads(f, def, .DECLARE_VALUE, *dvrs);
            for ddi: dvrs {
                k: Dbg_Record_Kind = ifx is_ptr_type(vtype(cur_reload)) then .DECLARE else .VALUE;
                coro_new_dbg_record(k, cur_reload, dbgr(ddi).var, dbgr(ddi).expr, dbgr(ddi).dbg, b.pt, b.head);
                coro_salvage_debug_info(*arg_to_alloca, ddi, false);
            }
            if inst_op(u) == .PHI {
                if vkind(u) == .DEAD continue;
                coro_rauw(u, cur_reload);
                coro_erase(u);
                continue;
            }
            replace_uses_of_with(u, def, cur_reload);
            r := inst(u).records;
            while r != 0 {
                nx := dbgr(r).next;
                if dbgr(r).kind != .LABEL dbgr_replace_variable_location_op(r, def, cur_reload, true);
                r = nx;
            }
        }
    }
    fbb, fpt, fhead := coro_insert_pt_after_frame_ptr(shape);
    spill_block := split_basic_block(fbb, fpt, "AllocaSpillBB", fhead);
    split_basic_block(spill_block, block_first(spill_block), "PostSpill");
    shape.alloca_spill_block = spill_block;
    if shape.abi == .RETCON || shape.abi == .RETCON_ONCE || shape.abi == .ASYNC {
        irb_set_at(*b, spill_block, block_first(spill_block), false);
        for p: fd.allocas.* {
            ai := p.alloca;
            g := coro_create_gep_to_frame_pointer(fd, *b, shape, ai);
            for :early_inc_uses usr: ai if call_is_lifetime_start_or_end(usr) coro_erase(usr);
            coro_take_name(g, ai);
            coro_rauw(ai, g);
            coro_erase(ai);
        }
        return;
    }
    irb_set_at(*b, spill_block, block_first(spill_block), false);
    to_update: [..] Value_Id; to_update.allocator = temp;
    users: [..] u32; users.allocator = temp;
    for a: fd.allocas.* {
        ai := a.alloca;
        to_update.count = 0;
        for :early_inc_uses usr: ai {
            if call_is_lifetime_start_or_end(usr) coro_erase(usr);
            else if dt_dominates_inst(dt, shape.coro_begin, usr) array_add(*to_update, usr);
        }
        if to_update.count == 0 continue;
        g := coro_create_gep_to_frame_pointer(fd, *b, shape, ai);
        set_name(g, tconcat(vname(ai), ".reload.addr"));
        find_dbg_users(f, ai, *users);
        for users dbgr_replace_variable_location_op(it, ai, g);
        for to_update replace_uses_of_with(it, ai, g);
        if !has_uses(ai) coro_erase(ai);
    }
    _, ipt, _ := coro_insert_pt_after_frame_ptr(shape);
    irb_set_before(*b, ipt);
    for a: fd.allocas.* {
        ai := a.alloca;
        if a.may_write_before_coro_begin coro_handle_access_before_coro_begin(fd, shape, *b, ai);
        for alias: a.alias_insts {
            fp := coro_create_gep_to_frame_pointer(fd, *b, shape, ai);
            alias_ptr := irb_inbounds_ptr_add(*b, fp, const_int(ir.t_i64, cast(u64) a.alias_offsets[it_index]));
            // Alias.first->replaceUsesWithIf(AliasPtr, dominated by CoroBegin)
            u := ir.v_first_use[alias];
            while u != NONE {
                nx := ir.u_next[u];
                if dt_dominates_use(dt, shape.coro_begin, u) use_set(u, alias_ptr);
                u = nx;
            }
        }
    }
}

// for :early_inc_uses usr: v  (users() with make_early_inc_range)
early_inc_uses :: (v: *Value_Id, body: Code, flags: For_Flags) #expand {
    u := ir.v_first_use[v.*];
    while u != NONE {
        nx := ir.u_next[u];
        `it := ir.u_user[u];
        `it_index := 0;
        #insert body;
        u = nx;
    }
}

// Value::takeName for an instruction or a constant-folded value
coro_take_name :: (dst: Value_Id, src: Value_Id) {
    if !is_inst(dst) return;
    n := vname(src);
    set_name(src, "");
    set_name(dst, n);
}

// ---------------------------------------------------------------- normalization

// movePHIValuesToInsertedBlock
coro_move_phi_values_to_inserted_block :: (succ: Value_Id, inserted: Value_Id, pred: Value_Id, until: Value_Id = NONE) {
    pn := block_first(succ);
    while true {
        idx := phi_block_index(pn, inserted);
        v := phi_value(pn, cast(u32) idx);
        input := create_phi(vtype(v), 1);
        insert_at_position(input, inserted, block_first(inserted), false);
        set_name(input, tconcat(vname(v), ".", vname(succ)));
        phi_add_incoming(input, v, pred);
        phi_set_value(pn, cast(u32) idx, input);
        nx := inst_next(pn);
        pn = ifx nx != NONE && inst_op(nx) == .PHI then nx else NONE;
        if pn == until break;
    }
}

// rewritePHIsForCleanupPad
coro_rewrite_phis_for_cleanup_pad :: (pad_bb: Value_Id, pad: Value_Id) {
    f := block_fn(pad_bb);
    unreach := create_block(f, "unreachable");
    block_append_inst(unreach, new_inst(.UNREACHABLE, ir.t_void, 0));
    dispatch := create_block(f, tconcat(vname(pad_bb), ".corodispatch"), pad_bb);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(pad_bb, *preds);
    set_dispatch := create_phi(ir.t_i8, cast(u32) preds.count);
    block_append_inst(dispatch, set_dispatch);
    inst_unlink(pad);
    inst_insert_after(pad, set_dispatch);
    sw := create_switch(set_dispatch, unreach, cast(u32) preds.count);
    block_append_inst(dispatch, sw);
    k: u64 = 0;
    for pred: preds {
        case_bb := create_block(f, tconcat(vname(pad_bb), ".from.", vname(pred)), pad_bb);
        coro_update_phi_nodes(pad_bb, pred, case_bb);
        set_name(case_bb, tconcat(vname(pad_bb), ".from.", vname(pred)));
        block_append_inst(case_bb, create_br(pad_bb));
        coro_move_phi_values_to_inserted_block(pad_bb, case_bb, dispatch);
        coro_set_unwind_edge_to(block_terminator(pred), dispatch);
        c := const_int(ir.t_i8, k);
        phi_add_incoming(set_dispatch, c, pred);
        sw_add_case(sw, c, case_bb);
        k += 1;
    }
}

// cleanupSinglePredPHIs
coro_cleanup_single_pred_phis :: (f: Value_Id) {
    worklist: [..] Value_Id; worklist.allocator = temp;
    for bb: fn_blocks(f) for i: block_insts(bb) {
        if inst_op(i) != .PHI break;
        if phi_num_incoming(i) == 1 array_add(*worklist, i);
        else break;
    }
    while worklist.count {
        phi := pop(*worklist);
        coro_rauw(phi, phi_value(phi, 0));
    }
}

// rewritePHIs(BasicBlock &)
coro_rewrite_phis_block :: (bb: Value_Id) {
    fnp := block_first_non_phi(bb);
    preds: [..] Value_Id; preds.allocator = temp;
    if fnp != NONE && inst_op(fnp) == .CLEANUPPAD {
        block_predecessors(bb, *preds);
        for pred: preds {
            if inst_op(block_terminator(pred)) == .CATCHSWITCH { coro_rewrite_phis_for_cleanup_pad(bb, fnp); return; }
        }
    }
    landing_pad: Value_Id = NONE;
    repl_phi: Value_Id = NONE;
    if fnp != NONE && inst_op(fnp) == .LANDINGPAD {
        landing_pad = fnp;
        repl_phi = create_phi(vtype(fnp), 1);
        insert_at_position(repl_phi, bb, fnp, false);
        coro_take_name(repl_phi, fnp);
        coro_rauw(fnp, repl_phi);
    }
    block_predecessors(bb, *preds);
    for pred: preds {
        inc := coro_eh_aware_split_edge(pred, bb, landing_pad, repl_phi);
        set_name(inc, tconcat(vname(bb), ".from.", vname(pred)));
        coro_move_phi_values_to_inserted_block(bb, inc, pred, repl_phi);
    }
    if landing_pad != NONE coro_erase(landing_pad);
}

coro_rewrite_phis :: (f: Value_Id) {
    worklist: [..] Value_Id; worklist.allocator = temp;
    for bb: fn_blocks(f) {
        fi := block_first(bb);
        if fi != NONE && inst_op(fi) == .PHI && phi_num_incoming(fi) > 1 array_add(*worklist, bb);
    }
    for worklist coro_rewrite_phis_block(it);
}

// setUnwindEdgeTo
coro_set_unwind_edge_to :: (ti: Value_Id, succ: Value_Id) {
    o := inst_op(ti);
    if o == .INVOKE set_successor(ti, 1, succ);
    else if o == .CATCHSWITCH || o == .CLEANUPRET coro_set_eh_unwind_dest(ti, succ);
    else fatal("internal: unexpected terminator instruction");
}
// updatePhiNodes(DestBB, OldPred, NewPred, Until)
coro_update_phi_nodes :: (dest: Value_Id, old_pred: Value_Id, new_pred: Value_Id, until: Value_Id = NONE) {
    bb_idx := 0;
    for pn: block_insts(dest) {
        if inst_op(pn) != .PHI break;
        if pn == until break;
        if bb_idx >= cast(s64) phi_num_incoming(pn) || phi_block(pn, cast(u32) bb_idx) != old_pred bb_idx = phi_block_index(pn, old_pred);
        assert(bb_idx >= 0, "Invalid PHI Index!");
        phi_set_block(pn, cast(u32) bb_idx, new_pred);
    }
}

// ehAwareSplitEdge(BB, Succ, OriginalPad, LandingPadReplacement)
coro_eh_aware_split_edge :: (bb: Value_Id, succ: Value_Id, original_pad: Value_Id, repl: Value_Id) -> Value_Id {
    pad := block_first_non_phi(succ);
    if repl == NONE && !is_eh_pad(pad) return split_edge(bb, succ, null, null);
    f := block_fn(bb);
    nb := create_block(f, "", succ);
    coro_set_unwind_edge_to(block_terminator(bb), nb);
    coro_update_phi_nodes(succ, bb, nb, repl);
    if repl != NONE {
        nlp := inst_clone(original_pad);
        t := create_br(succ);
        block_append_inst(nb, t);
        insert_at_position(nlp, nb, t, false);
        phi_add_incoming(repl, nlp, nb);
    } else {
        o := inst_op(pad);
        parent: Value_Id = NONE;
        if o == .CATCHPAD || o == .CLEANUPPAD parent = op(pad, nops(pad) - 1);
        else if o == .CATCHSWITCH parent = op(pad, 0);
        else if o == .LANDINGPAD parent = inst_block(pad);
        else fatal("handling for other EHPads not implemented yet");
        np := new_inst(.CLEANUPPAD, ir.t_token, 1);
        set_op(np, 0, parent);
        block_append_inst(nb, np);
        ret := new_inst(.CLEANUPRET, ir.t_void, 2);
        set_op(ret, 0, np); set_op(ret, 1, succ);
        block_append_inst(nb, ret);
    }
    return nb;
}

// splitBlockIfNotFirst
coro_split_block_if_not_first :: (i: Value_Id, name: string) -> Value_Id {
    bb := inst_block(i);
    if block_first(bb) == i && block_single_predecessor(bb) != NONE { set_name(bb, name); return bb; }
    return split_basic_block(bb, i, name);
}
// splitAround
coro_split_around :: (i: Value_Id, name: string) {
    coro_split_block_if_not_first(i, name);
    coro_split_block_if_not_first(inst_next(i), tconcat("After", name));
}

// willLeaveFunctionImmediatelyAfter
coro_will_leave_function_immediately_after :: (bb: Value_Id, depth: s64 = 3) -> bool {
    if depth == 0 return false;
    if coro_is_suspend_block(bb) return true;
    t := block_terminator(bb);
    n := num_successors(t);
    for k: 0..cast(s64) n - 1 if !coro_will_leave_function_immediately_after(get_successor(t, cast(u32) k), depth - 1) return false;
    return true;
}
// localAllocaNeedsStackSave
coro_local_alloca_needs_stack_save :: (ai: Value_Id) -> bool {
    u := ir.v_first_use[ai];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if call_iid(usr) != IID_CORO_ALLOCA_FREE continue;
        if !coro_will_leave_function_immediately_after(inst_block(usr)) return true;
    }
    return false;
}
// lowerLocalAllocas
coro_lower_local_allocas :: (local_allocas: [] Value_Id, dead: *[..] Value_Id) {
    for ai: local_allocas {
        b: Irb; irb_set_before(*b, ai);
        stack_save: Value_Id = NONE;
        if coro_local_alloca_needs_stack_save(ai)
            stack_save = irb_insert(*b, coro_new_intrinsic_call("llvm.stacksave", .[ir.t_ptr], .[]));
        a := new_inst(.ALLOCA, ir.t_ptr, 1);
        inst(a).ty2 = ir.t_i8;
        set_op(a, 0, call_arg(ai, 0));
        inst(a).addrspace = dl_alloca_addrspace();
        inst(a).align = max(const_int_zext(call_arg(ai, 1)), 1);
        irb_insert(*b, a);
        users: [..] Value_Id; users.allocator = temp;
        u := ir.v_first_use[ai];
        while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
        for usr: users {
            if call_iid(usr) == IID_CORO_ALLOCA_GET coro_rauw(usr, a);
            else if stack_save != NONE {
                irb_set_before(*b, usr);
                irb_insert(*b, coro_new_intrinsic_call("llvm.stackrestore", .[ir.t_ptr], .[stack_save]));
            }
            array_add(dead, usr);
        }
        array_add(dead, ai);
    }
}
// an unlinked call to an intrinsic (CreateIntrinsic without the insertion)
coro_new_intrinsic_call :: (name: string, otys: [] Type_Id, args: [] Value_Id) -> Value_Id {
    callee := get_or_insert_intrinsic_declaration(intrinsic_id_by_name(name), otys);
    fty := glob(callee).value_type;
    i := new_inst(.CALL, func_ret(fty), cast(u32)(args.count + 1));
    inst(i).ty2 = fty;
    for args set_op(i, cast(u32) it_index, it);
    set_op(i, cast(u32) args.count, callee);
    return i;
}

// ---------------------------------------------------------------- swifterror

coro_emit_swift_error_call :: (b: *Irb, ret_ty: Type_Id, args: [] Value_Id, shape: *Coro_Shape) -> Value_Id {
    ptys: [..] Type_Id; ptys.allocator = temp;
    for args array_add(*ptys, vtype(it));
    fty := type_func(ret_ty, ptys, false);
    i := new_inst(.CALL, ret_ty, cast(u32)(args.count + 1));
    inst(i).ty2 = fty;
    for args set_op(i, cast(u32) it_index, it);
    set_op(i, cast(u32) args.count, const_null(ir.t_ptr));
    irb_insert(b, i);
    array_add(*shape.swift_error_ops, i);
    return i;
}
// emitSetAndGetSwiftErrorValueAround
coro_emit_set_and_get_swift_error_value_around :: (call: Value_Id, ai: Value_Id, shape: *Coro_Shape) -> Value_Id {
    vt := inst(ai).ty2;
    b: Irb; irb_set_before(*b, call);
    before := irb_load(*b, vt, ai, dl_abi_align(vt));
    addr := coro_emit_swift_error_call(*b, ir.t_ptr, .[before], shape);
    if inst_op(call) == .CALL irb_set_before(*b, inst_next(call));
    else irb_set_before(*b, block_first_non_phi_or_dbg(get_successor(call, 0)));
    after := coro_emit_swift_error_call(*b, vt, .[], shape);
    irb_store(*b, after, ai, dl_abi_align(vt));
    return addr;
}
// eliminateSwiftErrorAlloca
coro_eliminate_swift_error_alloca :: (ai: Value_Id, shape: *Coro_Shape) {
    u := ir.v_first_use[ai];
    while u != NONE {
        nx := ir.u_next[u];
        usr := ir.u_user[u];
        o := inst_op(usr);
        if o != .LOAD && o != .STORE {
            addr := coro_emit_set_and_get_swift_error_value_around(usr, ai, shape);
            use_set(u, addr);
        }
        u = nx;
    }
}
// eliminateSwiftError
coro_eliminate_swift_error :: (f: Value_Id, shape: *Coro_Shape) {
    to_promote: [..] Value_Id; to_promote.allocator = temp;
    na := glob(f).nargs;
    for k: 0..cast(s64) na - 1 {
        if !fn_has_param_attr(f, cast(u32) k, .SwiftError) continue;
        arg := fn_arg(f, cast(u32) k);
        entry := fn_entry(f);
        b: Irb; irb_set_at(*b, entry, block_first_non_phi_or_dbg(entry), false);
        a := new_inst(.ALLOCA, ir.t_ptr, 1);
        inst(a).ty2 = ir.t_ptr;
        set_op(a, 0, const_int(ir.t_i32, 1));
        inst(a).addrspace = cast(u32) ir.types[vtype(arg)].a;
        inst(a).align = dl_pref_align(ir.t_ptr);
        irb_insert(*b, a);
        coro_rauw(arg, a);
        irb_store(*b, const_null(ir.t_ptr), a, dl_abi_align(ir.t_ptr));
        for susp: shape.coro_suspends coro_emit_set_and_get_swift_error_value_around(susp, a, shape);
        for e: shape.coro_ends {
            irb_set_before(*b, e);
            fin := irb_load(*b, ir.t_ptr, a, dl_abi_align(ir.t_ptr));
            coro_emit_swift_error_call(*b, ir.t_ptr, .[fin], shape);
        }
        array_add(*to_promote, a);
        coro_eliminate_swift_error_alloca(a, shape);
        break;
    }
    for i: block_insts(fn_entry(f)) {
        if inst_op(i) != .ALLOCA || (inst(i).flags & F_SWIFTERR) == 0 continue;
        inst(i).flags &= ~cast(u32) F_SWIFTERR;
        array_add(*to_promote, i);
        coro_eliminate_swift_error_alloca(i, shape);
    }
    if to_promote.count {
        dt := dt_new(false); dt_recalculate(dt, f);
        promote_mem_to_reg(to_promote, dt, null);
        dt_free(dt);
    }
}

// ---------------------------------------------------------------- sinkLifetimeStartMarkers

coro_sink_lifetime_start_markers :: (f: Value_Id, shape: *Coro_Shape, sci: *Sci, dt: *Dom_Tree) {
    if fn_has_fn_attr(f, .OptimizeNone) return;
    // SmallPtrSet<BasicBlock *, 4> DomSet: insertion order while small
    dom_set: [..] Value_Id; dom_set.allocator = temp;
    array_add(*dom_set, fn_entry(f));
    for csi: shape.coro_suspends {
        s := block_single_successor(inst_block(csi));
        found := false;
        for dom_set if it == s { found = true; break; }
        if !found array_add(*dom_set, s);
    }
    // With more than 4 blocks the SmallPtrSet iterates in pointer-hash order, which cannot be reproduced: then the
    // result must not depend on the order (at most one candidate block is valid for each alloca), else fail loudly.
    hashed := dom_set.count > 4;
    lifetimes: [..] Value_Id; lifetimes.allocator = temp;
    chosen_lifetimes: [..] Value_Id; chosen_lifetimes.allocator = temp;
    for ai: fn_insts(f) {
        if inst_op(ai) != .ALLOCA continue;
        chosen: Value_Id = NONE;
        for dom_bb: dom_set {
            valid := true;
            lifetimes.count = 0;
            u := ir.v_first_use[ai];
            while u != NONE {
                ui := ir.u_user[u];
                u = ir.u_next[u];
                if !dt_dominates(dt, dom_bb, inst_block(ui)) || sci_def_bb_across_suspend(sci, dom_bb, ui) {
                    // collectLifetimeStart
                    if call_iid(ui) == IID_LIFETIME_START { array_add(*lifetimes, ui); continue; }
                    if has_one_use(ui) && strip_pointer_casts(ui) == ai {
                        ub := ir.u_user[ir.v_first_use[ui]];
                        if call_iid(ub) == IID_LIFETIME_START { array_add(*lifetimes, ub); continue; }
                    }
                    valid = false;
                    break;
                }
            }
            if valid && lifetimes.count {
                if chosen != NONE fatal("coro-split: sinking lifetime markers when several blocks qualify and there are more than 3 suspend points (SmallPtrSet pointer order) is not supported");
                chosen = dom_bb;
                chosen_lifetimes.count = 0;
                for lifetimes array_add(*chosen_lifetimes, it);
                if !hashed break;
            }
        }
        if chosen != NONE {
            nl := inst_clone(chosen_lifetimes[0]);
            replace_uses_of_with(nl, op(nl, 0), ai);
            insert_at_position(nl, chosen, block_terminator(chosen), false);
            for chosen_lifetimes coro_erase(it);
        }
    }
}

// ---------------------------------------------------------------- normalizeCoroutine / buildCoroutineFrame

// coro::normalizeCoroutine
coro_normalize_coroutine :: (f: Value_Id, shape: *Coro_Shape) {
    if shape.abi != .ASYNC || shape.coro_suspends.count != 0 coro_eliminate_swift_error(f, shape);
    if shape.abi == .SWITCH && shape.sw_promise_alloca != NONE coro_id_clear_promise(coro_shape_id(shape));
    for csi: shape.coro_suspends {
        save := coro_suspend_save(csi);
        if save != NONE coro_split_around(save, "CoroSave");
        coro_split_around(csi, "CoroSuspend");
    }
    for ce: shape.coro_ends {
        coro_split_around(ce, "CoroEnd");
        if call_iid(ce) == IID_CORO_END_ASYNC {
            mt := coro_async_end_must_tail_fn(ce);
            if mt == NONE continue;
            b: Irb; irb_set_before(*b, ce);
            args: [..] Value_Id; args.allocator = temp;
            n := call_arg_count(ce);
            for k: 3..cast(s64) n - 1 array_add(*args, call_arg(ce, cast(u32) k));
            call := coro_create_must_tail_call(get_metadata(ce, MDK_DBG), mt, args, *b);
            coro_split_around(call, "MustTailCall.Before.CoroEnd");
        }
    }
    coro_cleanup_single_pred_phis(f);
    coro_rewrite_phis(f);
}

// coro::BaseABI::buildCoroutineFrame
coro_build_coroutine_frame :: (f: Value_Id, shape: *Coro_Shape, optimize_frame: bool) {
    sci: Sci;
    sci_build(*sci, f, shape);
    coro_do_rematerializations(f, *sci);
    dt := dt_new(false); dt_recalculate(dt, f);
    defer dt_free(dt);
    if shape.abi != .ASYNC && shape.abi != .RETCON && shape.abi != .RETCON_ONCE coro_sink_lifetime_start_markers(f, shape, *sci, dt);
    spills: Spill_Info; spill_init(*spills);
    allocas: [..] Coro_Alloca_Info; allocas.allocator = temp;
    coro_collect_spills_from_args(*spills, f, *sci);
    dead: [..] Value_Id; dead.allocator = temp;
    local_allocas: [..] Value_Id; local_allocas.allocator = temp;
    coro_collect_spills_and_allocas_from_insts(*spills, *allocas, *dead, *local_allocas, f, *sci, dt, shape);
    coro_collect_spills_from_dbg_info(*spills, f, *sci);
    if shape.abi == .RETCON || shape.abi == .RETCON_ONCE || shape.abi == .ASYNC
        coro_sink_spill_uses_after_coro_begin(dt, shape.coro_begin, *spills, allocas);
    fd: Frame_Data;
    fd_init(*fd, *spills, *allocas);
    coro_build_frame_layout(f, dt, shape, *fd, optimize_frame);
    shape.frame_ptr = shape.coro_begin;
    coro_build_frame_debug_info(f, shape, *fd);
    coro_insert_spills(*fd, shape);
    coro_lower_local_allocas(local_allocas, *dead);
    for dead coro_erase(it);
}

