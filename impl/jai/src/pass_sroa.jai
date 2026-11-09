// SROA: port of llvm/lib/Transforms/Scalar/SROA.cpp (SROAPass) with the parts of
// llvm/include/llvm/Analysis/PtrUseVisitor.h + llvm/lib/Analysis/PtrUseVisitor.cpp it builds on, and
// llvm/lib/Analysis/Loads.cpp (isSafeToLoadUnconditionally) in sroa_loads.jai.
//
// Data layout: slices are rows {begin, end, use, splittable} (use NONE = dead); partitions are formed on the fly
// by the partition iterator (Sroa_Part_It); instructions are visited by `switch` on the opcode.
// Not ported (fail loudly): scalable vectors, assignment tracking (dbg_assign), the escaped-read-only path
// (propagateStoredValuesToLoads / SSAUpdater), CFG-modifying select rewriting (modify-cfg with selects that cannot
// be speculated), fake uses of split aggregates.

Sroa_Slice :: struct {
    begin: u64;
    end: u64;
    use: Use_Id = NONE;
    splittable: bool;
}

// Slice::operator<
slice_less :: (a: Sroa_Slice, b: Sroa_Slice) -> bool {
    if a.begin < b.begin return true;
    if a.begin > b.begin return false;
    if a.splittable != b.splittable return !a.splittable;
    if a.end > b.end return true;
    return false;
}

// std::stable_sort (merge sort)
stable_sort_slices :: (s: [] Sroa_Slice) {
    if s.count < 2 return;
    tmp := NewArray(s.count, Sroa_Slice,, allocator = temp);
    width := 1;
    src := s; dst := tmp;
    while width < s.count {
        i := 0;
        while i < s.count {
            mid := min(i + width, s.count);
            hi := min(i + 2 * width, s.count);
            a := i; b := mid; k := i;
            while a < mid && b < hi {
                if slice_less(src[b], src[a]) { dst[k] = src[b]; b += 1; }
                else { dst[k] = src[a]; a += 1; }
                k += 1;
            }
            while a < mid { dst[k] = src[a]; a += 1; k += 1; }
            while b < hi { dst[k] = src[b]; b += 1; k += 1; }
            i += 2 * width;
        }
        t := src; src = dst; dst = t;
        width *= 2;
    }
    if src.data != s.data for i: 0..s.count-1 s[i] = src[i];
}

Sroa_Slices :: struct {
    slices: [..] Sroa_Slice;
    dead_users: [..] Value_Id;
    dead_use_if_promotable: [..] Use_Id;
    dead_operands: [..] Use_Id;
    escaping: Value_Id = NONE;
    escaping_ro: Value_Id = NONE;
}

use_user :: inline (u: Use_Id) -> Value_Id { return ir.u_user[u]; }
use_value :: inline (u: Use_Id) -> Value_Id { return ir.u_val[u]; }
use_operand_no :: inline (u: Use_Id) -> u32 { return u - ir.v_ops[ir.u_user[u]]; }

// SmallSetVector<Value*>
Set_Vec :: struct {
    items: [..] Value_Id;
    set: Table(Value_Id, bool);
}
svec_init :: (s: *Set_Vec) { s.items.allocator = temp; s.set.allocator = temp; }
svec_insert :: (s: *Set_Vec, v: Value_Id) -> bool {
    if table_contains(*s.set, v) return false;
    table_set(*s.set, v, true);
    array_add(*s.items, v);
    return true;
}
svec_contains :: (s: *Set_Vec, v: Value_Id) -> bool { return table_contains(*s.set, v); }
svec_pop :: (s: *Set_Vec) -> Value_Id {
    v := pop(*s.items);
    table_remove(*s.set, v);
    return v;
}
svec_remove :: (s: *Set_Vec, v: Value_Id) {
    if !table_contains(*s.set, v) return;
    table_remove(*s.set, v);
    for s.items if it == v { array_ordered_remove_by_index(*s.items, it_index); break; }
}
svec_clear :: (s: *Set_Vec) { s.items.count = 0; table_reset(*s.set); }
svec_assign :: (dst: *Set_Vec, src: *Set_Vec) { svec_clear(dst); for src.items svec_insert(dst, it); }

// ---------------------------------------------------------------- small helpers

call_intrinsic :: (i: Value_Id) -> string {
    if !is_inst(i) || inst_op(i) != .CALL return "";
    return intrinsic_id_of_call(i);
}
is_mem_intrinsic :: (i: Value_Id) -> bool { return is_mem_intrinsic_name(call_intrinsic(i)); }
is_memset_intrinsic :: (i: Value_Id) -> bool { id := call_intrinsic(i); return id == "llvm.memset" || id == "llvm.memset.inline"; }
is_memtransfer_intrinsic :: (i: Value_Id) -> bool { id := call_intrinsic(i); return id == "llvm.memcpy" || id == "llvm.memmove" || id == "llvm.memcpy.inline"; }
mem_is_volatile :: (i: Value_Id) -> bool { v := call_arg(i, 3); return vkind(v) == .C_INT && !is_null_value(v); }
mem_length :: (i: Value_Id) -> Value_Id { return call_arg(i, 2); }
// MemIntrinsic alignment of a pointer parameter (0 = none)
call_param_align :: (i: Value_Id, k: u32) -> u64 {
    a := attr_set_find(attr_list_param(inst(i).attrs, k), .Alignment);
    if a return a.ival;
    return 0;
}

// isInstructionTriviallyDead(I) without TLI
sroa_trivially_dead :: (i: Value_Id) -> bool {
    if !is_inst(i) return false;
    if has_uses(i) return false;
    return would_instruction_be_trivially_dead(i, false);
}

// Type::isSingleValueType
is_single_value_type :: (t: Type_Id) -> bool {
    k := type_kind(t);
    return k == .INT || k == .BYTE || is_fp_kind(k) || k == .PTR || k == .VECTOR || k == .SVECTOR || k == .X86_AMX || k == .TARGET_EXT;
}

// AllocaInst::getAllocationSize (bytes); false if not a constant
sroa_alloca_allocation_size :: (ai: Value_Id) -> (bool, u64) {
    t := inst(ai).ty2;
    sz := dl_type_alloc_size(t);   // the known minimum for scalable types
    n := op(ai, 0);
    if !(vkind(n) == .C_INT && const_int_zext(n) == 1) {
        if vkind(n) != .C_INT return false, 0;
        sz *= const_int_zext(n);
    }
    return true, sz;
}
type_has_scalable :: (t: Type_Id) -> bool {
    k := type_kind(t);
    if k == .SVECTOR return true;
    if k == .ARRAY return type_has_scalable(type_elem(t));
    if k == .STRUCT { n := type_nsub(t); if n > 0 for i: 0..n-1 if type_has_scalable(type_sub(t, i)) return true; }
    return false;
}
alloca_is_array_allocation :: (ai: Value_Id) -> bool {
    n := op(ai, 0);
    return !(vkind(n) == .C_INT && const_int_zext(n) == 1);
}
alloca_is_static :: (ai: Value_Id) -> bool {
    if vkind(op(ai, 0)) != .C_INT return false;
    return inst(ai).parent == fn_entry(block_fn(inst(ai).parent)) && (inst(ai).flags & F_INALLOCA) == 0;
}

common_alignment :: (a: u64, offset: u64) -> u64 {
    // commonAlignment(A, Offset) = MinAlign(A, Offset)
    x := a | offset;
    return x & (~x + 1);
}

// ---------------------------------------------------------------- AllocaSlices::SliceBuilder

Sroa_Visit :: struct { use: Use_Id; known: bool; offset: u64; }

Sroa_Builder :: struct {
    fn: Value_Id;
    as: *Sroa_Slices;
    alloc_size: u64;
    width: u32;
    wl: [..] Sroa_Visit;
    visited_uses: Table(Use_Id, bool);
    u: Use_Id;
    known: bool;
    offset: u64;
    aborted: Value_Id = NONE;
    escaped: Value_Id = NONE;
    escaped_ro: Value_Id = NONE;
    mem_transfer_slice: Table(Value_Id, s64);
    phi_sel_sizes: Table(Value_Id, u64);
    visited_dead: Table(Value_Id, bool);
}

sb_enqueue_users :: (b: *Sroa_Builder, v: Value_Id) {
    u := ir.v_first_use[v];
    while u != NONE {
        if !table_contains(*b.visited_uses, u) {
            table_set(*b.visited_uses, u, true);
            array_add(*b.wl, .{u, b.known, b.offset});
        }
        u = ir.u_next[u];
    }
}

sb_mark_dead :: (b: *Sroa_Builder, i: Value_Id) {
    if table_contains(*b.visited_dead, i) return;
    table_set(*b.visited_dead, i, true);
    array_add(*b.as.dead_users, i);
}

sb_insert_use :: (b: *Sroa_Builder, i: Value_Id, offset: u64, size: u64, splittable := false) {
    if size == 0 || offset >= b.alloc_size { sb_mark_dead(b, i); return; }
    begin := offset;
    end := begin + size;
    if size > b.alloc_size - begin end = b.alloc_size;
    array_add(*b.as.slices, .{begin, end, b.u, splittable});
}

sb_load_or_store :: (b: *Sroa_Builder, ty: Type_Id, i: Value_Id, size: u64, volatile: bool) {
    splittable := is_int_type(ty) && !volatile && dl_size_eq_store_size(ty);
    sb_insert_use(b, i, b.offset, size, splittable);
}

// hasUnsafePHIOrSelectUse: returns the unsafe instruction (or NONE) and the max access size
sb_unsafe_phi_or_select_use :: (b: *Sroa_Builder, root: Value_Id) -> (Value_Id, u64) {
    Pair :: struct { used: Value_Id; i: Value_Id; }
    visited: Table(Value_Id, bool); visited.allocator = temp;
    uses: [..] Pair; uses.allocator = temp;
    table_set(*visited, root, true);
    array_add(*uses, .{use_value(b.u), root});
    size: u64 = 0;
    while uses.count {
        p := pop(*uses);
        i := p.i;
        o := inst_op(i);
        if o == .LOAD {
            if type_kind(vtype(i)) == .SVECTOR { b.aborted = i; return NONE, size; }
            size = max(size, dl_type_store_size(vtype(i)));
            continue;
        }
        if o == .STORE {
            x := op(i, 0);
            if x == p.used return i, size;
            if type_kind(vtype(x)) == .SVECTOR { b.aborted = i; return NONE, size; }
            size = max(size, dl_type_store_size(vtype(x)));
            continue;
        }
        if o == .GEP {
            if !gep_has_all_zero_indices(i) return i, size;
        } else if o != .BITCAST && o != .PHI && o != .SELECT && o != .ADDRSPACECAST {
            return i, size;
        }
        u := ir.v_first_use[i];
        while u != NONE {
            usr := ir.u_user[u];
            if !table_contains(*visited, usr) { table_set(*visited, usr, true); array_add(*uses, .{i, usr}); }
            u = ir.u_next[u];
        }
    }
    return NONE, size;
}

// foldSelectInst / foldPHINodeOrSelectInst
fold_phi_or_select :: (i: Value_Id) -> Value_Id {
    if inst_op(i) == .PHI return phi_has_constant_value(i);
    c := op(i, 0);
    if vkind(c) == .C_INT && type_kind(vtype(c)) == .INT return op(i, ifx is_null_value(c) then cast(u32) 2 else 1);
    if op(i, 1) == op(i, 2) return op(i, 1);
    return NONE;
}

block_has_insertion_pt :: (bb: Value_Id) -> bool { return block_first_insertion_pt(bb) != NONE; }

sb_visit_phi_or_select :: (b: *Sroa_Builder, i: Value_Id) {
    if !has_uses(i) { sb_mark_dead(b, i); return; }
    if inst_op(i) == .PHI && !block_has_insertion_pt(inst(i).parent) { b.aborted = i; return; }
    r := fold_phi_or_select(i);
    if r != NONE {
        if r == use_value(b.u) sb_enqueue_users(b, i);
        else array_add(*b.as.dead_operands, b.u);
        return;
    }
    if !b.known { b.aborted = i; return; }
    found, size := table_find(*b.phi_sel_sizes, i);
    if !found || size == 0 {
        unsafe, sz := sb_unsafe_phi_or_select_use(b, i);
        table_set(*b.phi_sel_sizes, i, sz);
        size = sz;
        if b.aborted != NONE return;
        if unsafe != NONE { b.aborted = unsafe; return; }
    }
    if b.offset >= b.alloc_size { array_add(*b.as.dead_operands, b.u); return; }
    sb_insert_use(b, i, b.offset, size);
}

sb_visit_mem_transfer :: (b: *Sroa_Builder, i: Value_Id) {
    len := mem_length(i);
    has_len := vkind(len) == .C_INT;
    if has_len && is_null_value(len) { sb_mark_dead(b, i); return; }
    if table_contains(*b.visited_dead, i) return;
    if !b.known { b.aborted = i; return; }
    if b.offset >= b.alloc_size {
        found, idx := table_find(*b.mem_transfer_slice, i);
        if found b.as.slices[idx].use = NONE;
        sb_mark_dead(b, i);
        return;
    }
    raw := b.offset;
    size := ifx has_len then const_int_zext_limited(len) else b.alloc_size - raw;
    v := use_value(b.u);
    if v == op(i, 0) && v == op(i, 1) {
        if !mem_is_volatile(i) { sb_mark_dead(b, i); return; }
        sb_insert_use(b, i, b.offset, size, false);
        return;
    }
    found, prev := table_find(*b.mem_transfer_slice, i);
    inserted := !found;
    if inserted { prev = b.as.slices.count; table_set(*b.mem_transfer_slice, i, prev); }
    else {
        ps := *b.as.slices[prev];
        if !mem_is_volatile(i) && ps.begin == raw {
            ps.use = NONE;
            sb_mark_dead(b, i);
            return;
        }
        ps.splittable = false;
    }
    sb_insert_use(b, i, b.offset, size, inserted && has_len);
}

const_int_zext_limited :: (c: Value_Id) -> u64 {
    w := const_int_value(c);
    for k: 1..w.count-1 if w[k] != 0 return 0xFFFF_FFFF_FFFF_FFFF;
    return w[0];
}

// CallBase::getCaptureInfo(OpNo) as CaptureComponents (other | ret)
call_capture_components :: (c: Value_Id, opno: u32) -> u64 {
    n := call_arg_count(c);
    if opno < n {
        r := inst(c);
        if call_is_byval_arg(c, opno) return 0;
        cc_of :: (s: u32) -> u64 {
            a := attr_set_find(s, .Captures);
            if !a return 0xF;   // CaptureInfo::all()
            return a.ival;      // other | ret << 4
        }
        ci := cc_of(attr_list_param(r.attrs, opno));
        callee := call_callee(c);
        if vkind(callee) == .FUNCTION ci &= cc_of(attr_list_param(glob(callee).attrs, opno));
        // implicit conversion to CaptureComponents: Other | Ret
        return (ci & 0xF) | ((ci >> 4) & 0xF);
    }
    if intrinsic_id_of_call(c) == "llvm.assume" return 0;
    if call_bundle_tag_of_operand(c, opno) == "deopt" return 0;
    return 0xF;
}
// CallBase::isByValArgument (paramHasAttr: call site or callee)
call_is_byval_arg :: (c: Value_Id, k: u32) -> bool {
    if attr_set_has(attr_list_param(inst(c).attrs, k), .ByVal) return true;
    f := call_called_function(c);
    return f != NONE && attr_set_has(attr_list_param(glob(f).attrs, k), .ByVal);
}
// getBundleOpInfoForOperand(OpNo).Tag
call_bundle_tag_of_operand :: (c: Value_Id, opno: u32) -> string {
    r := inst(c);
    if r.nidx > 0 for k: 0..r.nidx-1 {
        b := ir.u32_pool[r.idx + 3 * k + 1]; e := ir.u32_pool[r.idx + 3 * k + 2];
        if opno >= b && opno < e return bundle_tags[ir.u32_pool[r.idx + 3 * k]];
    }
    fatal("internal: operand is not a bundle operand");
    return "";
}
// CallBase::onlyReadsMemory(OpNo)
call_param_only_reads :: (c: Value_Id, opno: u32) -> bool {
    n := call_arg_count(c);
    r := inst(c);
    if opno >= n {
        // bundleOperandHasAttr: only deopt bundles imply readonly (for pointer operands)
        return call_bundle_tag_of_operand(c, opno) == "deopt" && is_ptr_type(vtype(op(c, opno)));
    }
    if call_is_byval_arg(c, opno) return true;
    has :: (c: Value_Id, opno: u32, k: Attr_Kind) -> bool {
        if attr_set_has(attr_list_param(inst(c).attrs, opno), k) return true;
        f := call_called_function(c);
        if f == NONE return false;
        if !attr_set_has(attr_list_param(glob(f).attrs, opno), k) return false;
        return true;
    }
    // paramHasAttr(ReadOnly / ReadNone) accounts for the mod/ref of operand bundles
    return call_param_has_mem_attr(c, opno, .ReadOnly) || call_param_has_mem_attr(c, opno, .ReadNone);
}

sb_visit_call_base :: (b: *Sroa_Builder, c: Value_Id) {
    opno := use_operand_no(b.u);
    callee_ops := ifx inst_op(c) == .INVOKE then cast(u32) 3 else ifx inst_op(c) == .CALLBR then 2 + inst(c).addrspace else 1;
    is_data := opno < nops(c) - callee_ops;
    if is_data {
        cc := call_capture_components(c, opno);
        if (cc & 0xC) != 0xC && call_param_only_reads(c, opno) { b.escaped_ro = c; return; }
    }
    b.escaped = c;
    b.aborted = c;
}

sb_visit :: (b: *Sroa_Builder, i: Value_Id) {
    o := inst_op(i);
    if o == {
      case .LOAD;
        if !b.known { b.escaped_ro = i; return; }
        t := vtype(i);
        if type_has_scalable(t) {
            if fn_vscale_value(b.fn) == 0 { b.aborted = i; return; }
            fatal("SROA: scalable loads with a known vscale are not supported yet");
        }
        sb_load_or_store(b, t, i, dl_type_store_size(t), (inst(i).flags & F_VOLATILE) != 0);
      case .STORE;
        v := op(i, 0);
        if v == use_value(b.u) { b.escaped = i; b.aborted = i; return; }
        if !b.known { b.aborted = i; return; }
        t := vtype(v);
        if type_has_scalable(t) {
            if fn_vscale_value(b.fn) == 0 { b.aborted = i; return; }
            fatal("SROA: scalable stores with a known vscale are not supported yet");
        }
        size := dl_type_store_size(t);
        if size > b.alloc_size || b.offset > b.alloc_size - size { sb_mark_dead(b, i); return; }
        sb_load_or_store(b, t, i, size, (inst(i).flags & F_VOLATILE) != 0);
      case .BITCAST; #through;
      case .ADDRSPACECAST;
        if !has_uses(i) { sb_mark_dead(b, i); return; }
        sb_enqueue_users(b, i);
      case .GEP;
        if !has_uses(i) { sb_mark_dead(b, i); return; }
        // adjustOffsetForGEP
        ok := false;
        if b.known {
            gw := dl_index_type_size_bits(vtype(i));
            tmp: u64 = 0;
            if sv_gep_accumulate_of(i, *tmp, gw) {
                if gw < b.width && gw > 0 && ((tmp >> (gw - 1)) & 1) tmp |= ~sv_mask(gw);
                b.offset = (b.offset + tmp) & sv_mask(b.width);
                ok = true;
            }
        }
        if !ok { b.known = false; b.offset = 0; }
        sb_enqueue_users(b, i);
      case .PTRTOINT;
        b.escaped = i;
        b.aborted = i;   // the slices are discarded once escaped; stop early
      case .PHI; #through;
      case .SELECT;
        sb_visit_phi_or_select(b, i);
      case .CALL;
        id := intrinsic_id_of_call(i);
        if id == "llvm.memset" || id == "llvm.memset.inline" {
            len := mem_length(i);
            has_len := vkind(len) == .C_INT;
            if (has_len && is_null_value(len)) || (b.known && b.offset >= b.alloc_size) { sb_mark_dead(b, i); return; }
            if !b.known { b.aborted = i; return; }
            sb_insert_use(b, i, b.offset, ifx has_len then const_int_zext_limited(len) else b.alloc_size - b.offset, has_len);
            return;
        }
        if id == "llvm.memcpy" || id == "llvm.memmove" || id == "llvm.memcpy.inline" { sb_visit_mem_transfer(b, i); return; }
        if id != "" {
            if is_droppable_user(i) { array_add(*b.as.dead_use_if_promotable, b.u); return; }
            if !b.known { b.aborted = i; return; }
            if is_lifetime_intrinsic(id) { sb_insert_use(b, i, b.offset, b.alloc_size, true); return; }
            if id == "llvm.fake.use" { b.escaped = i; b.aborted = i; return; }
        }
        sb_visit_call_base(b, i);
      case .INVOKE; #through;
      case .CALLBR;
        sb_visit_call_base(b, i);
      case;
        b.aborted = i;
    }
}

// AllocaSlices::AllocaSlices
build_alloca_slices :: (ai: Value_Id, as: *Sroa_Slices) {
    as.slices.allocator = temp; as.dead_users.allocator = temp;
    as.dead_use_if_promotable.allocator = temp; as.dead_operands.allocator = temp;
    b: Sroa_Builder;
    b.as = as;
    b.fn = block_fn(inst(ai).parent);
    ok, sz := sroa_alloca_allocation_size(ai);
    b.alloc_size = sz;
    b.width = dl_index_type_size_bits(vtype(ai));
    b.wl.allocator = temp; b.visited_uses.allocator = temp; b.mem_transfer_slice.allocator = temp;
    b.phi_sel_sizes.allocator = temp; b.visited_dead.allocator = temp;
    b.known = true; b.offset = 0;
    sb_enqueue_users(*b, ai);
    while b.wl.count {
        v := pop(*b.wl);
        b.u = v.use;
        b.known = v.known;
        if b.known b.offset = v.offset;
        sb_visit(*b, use_user(b.u));
        if b.aborted != NONE break;
    }
    if b.escaped != NONE || b.aborted != NONE {
        as.escaping = ifx b.escaped != NONE then b.escaped else b.aborted;
        return;
    }
    as.escaping_ro = b.escaped_ro;
    k := 0;
    for as.slices if it.use != NONE { as.slices[k] = it; k += 1; }
    as.slices.count = k;
    stable_sort_slices(as.slices);
}

// ---------------------------------------------------------------- partitions (AllocaSlices::partition_iterator)

Sroa_Part :: struct {
    begin: u64;
    end: u64;
    si: s64;   // first slice index
    sj: s64;   // one past the last
    tails: [..] s64;   // split slice tails (indices into the slices)
}

Sroa_Part_It :: struct {
    p: Sroa_Part;
    se: s64;
    max_split_end: u64;
    slices: *[..] Sroa_Slice;
    done: bool;
}

part_it_init :: (it: *Sroa_Part_It, slices: *[..] Sroa_Slice) {
    it.slices = slices;
    it.p.tails.allocator = temp;
    it.p.si = 0; it.p.sj = 0;
    it.se = slices.count;
    it.max_split_end = 0;
    it.done = it.p.si == it.se;
    if !it.done part_it_advance(it);
}
part_it_at_end :: (it: *Sroa_Part_It) -> bool { return it.p.si == it.se && it.p.tails.count == 0; }

part_it_advance :: (it: *Sroa_Part_It) {
    P := *it.p;
    S := it.slices;
    if P.tails.count {
        if P.end >= it.max_split_end { P.tails.count = 0; it.max_split_end = 0; }
        else {
            k := 0;
            for P.tails if S.*[it].end > P.end { P.tails[k] = it; k += 1; }
            P.tails.count = k;
        }
    }
    if P.si == it.se return;
    if P.si != P.sj {
        for x: P.si..P.sj-1 {
            s := S.*[x];
            if s.splittable && s.end > P.end {
                array_add(*P.tails, x);
                it.max_split_end = max(s.end, it.max_split_end);
            }
        }
        P.si = P.sj;
        if P.si == it.se {
            P.begin = P.end;
            P.end = it.max_split_end;
            return;
        }
        if P.tails.count && S.*[P.si].begin != P.end && !S.*[P.si].splittable {
            P.begin = P.end;
            P.end = S.*[P.si].begin;
            return;
        }
    }
    P.begin = ifx P.tails.count == 0 then S.*[P.si].begin else P.end;
    P.end = S.*[P.si].end;
    P.sj += 1;
    if !S.*[P.si].splittable {
        while P.sj != it.se && S.*[P.sj].begin < P.end {
            if !S.*[P.sj].splittable P.end = max(P.end, S.*[P.sj].end);
            P.sj += 1;
        }
        return;
    }
    while P.sj != it.se && S.*[P.sj].begin < P.end && S.*[P.sj].splittable {
        P.end = max(P.end, S.*[P.sj].end);
        P.sj += 1;
    }
    if P.sj != it.se && S.*[P.sj].begin < P.end P.end = S.*[P.sj].begin;
}

// ---------------------------------------------------------------- type selection helpers

// findCommonType
find_common_type :: (S: [] Sroa_Slice, b: s64, e: s64, end_offset: u64) -> (Type_Id, Type_Id) {
    ty: Type_Id = NONE;
    common := true;
    ity: Type_Id = NONE;
    if e > b for x: b..e-1 {
        s := S[x];
        user := use_user(s.use);
        if call_intrinsic(user) != "" continue;
        if s.begin != S[b].begin || s.end != end_offset continue;
        user_ty: Type_Id = NONE;
        if inst_op(user) == .LOAD user_ty = vtype(user);
        else if inst_op(user) == .STORE user_ty = vtype(op(user, 0));
        if user_ty != NONE && is_int_type(user_ty) {
            w := type_int_width(user_ty);
            if w % 8 != 0 || w / 8 > (end_offset - S[b].begin) continue;
            if ity == NONE || type_int_width(ity) < w ity = user_ty;
        }
        if user_ty == NONE || (ty != NONE && ty != user_ty) common = false;
        else ty = user_ty;
    }
    return ifx common then ty else NONE, ity;
}

// canConvertValue (fixed-size types)
can_convert_value :: (old_ty: Type_Id, new_ty: Type_Id) -> bool {
    if old_ty == new_ty return true;
    if is_int_type(old_ty) && is_int_type(new_ty) return false;
    if type_kind(old_ty) == .SVECTOR || type_kind(new_ty) == .SVECTOR {
        if type_kind(old_ty) == .VECTOR || type_kind(new_ty) == .VECTOR return false;   // no vscale known
    }
    if dl_type_size_bits(new_ty) != dl_type_size_bits(old_ty) return false;
    if !is_single_value_type(new_ty) || !is_single_value_type(old_ty) return false;
    o := scalar_type(old_ty);
    n := scalar_type(new_ty);
    if is_ptr_type(n) || is_ptr_type(o) {
        if is_ptr_type(n) && is_ptr_type(o) {
            oas := cast(u32) ir.types[o].a; nas := cast(u32) ir.types[n].a;
            return oas == nas || (!dl_ni_as(oas) && !dl_ni_as(nas) && dl_ptr_spec(oas).bits == dl_ptr_spec(nas).bits);
        }
        if is_int_type(o) return !dl_ni_ptr_type(n);
        if !dl_ni_ptr_type(o) return is_int_type(n);
        return false;
    }
    if type_kind(o) == .TARGET_EXT || type_kind(n) == .TARGET_EXT return false;
    return true;
}

fixed_vec :: (elt: Type_Id, n: u64) -> Type_Id { return type_vector(n, elt, false); }

// isVectorPromotionViableForSlice
vector_viable_for_slice :: (P: *Sroa_Part, s: Sroa_Slice, vty: Type_Id, elt_size: u64) -> bool {
    begin_off := max(s.begin, P.begin) - P.begin;
    begin_idx := begin_off / elt_size;
    n := type_count(vty);
    if begin_idx * elt_size != begin_off || begin_idx >= n return false;
    end_off := min(s.end, P.end) - P.begin;
    end_idx := end_off / elt_size;
    if end_idx * elt_size != end_off || end_idx > n return false;
    num := end_idx - begin_idx;
    et := type_elem(vty);
    slice_ty := ifx num == 1 then et else fixed_vec(et, num);
    split_int_ty := type_int(num * elt_size * 8);
    user := use_user(s.use);
    if is_mem_intrinsic(user) {
        if mem_is_volatile(user) return false;
        if !s.splittable return false;
    } else if call_intrinsic(user) != "" {
        if !is_lifetime_start_or_end(user) && !is_droppable_user(user) return false;
    } else if inst_op(user) == .LOAD {
        if inst(user).flags & F_VOLATILE return false;
        lty := vtype(user);
        if type_kind(lty) == .STRUCT return false;
        if P.begin > s.begin || P.end < s.end lty = split_int_ty;
        if !can_convert_value(slice_ty, lty) return false;
    } else if inst_op(user) == .STORE {
        if inst(user).flags & F_VOLATILE return false;
        sty := vtype(op(user, 0));
        if type_kind(sty) == .STRUCT return false;
        if P.begin > s.begin || P.end < s.end sty = split_int_ty;
        if !can_convert_value(sty, slice_ty) return false;
    } else return false;
    return true;
}

Vec_Cands :: struct {
    tys: [..] Type_Id;
    common_elt: Type_Id = NONE;
    common_vec_ptr: Type_Id = NONE;
    have_vec_ptr := false;
    have_common_elt := true;
    have_common_vec_ptr := true;
}

vc_check_candidate :: (c: *Vec_Cands, ty: Type_Id) {
    if type_kind(ty) != .VECTOR return;
    if c.tys.count {
        if dl_type_size_bits(ty) != dl_type_size_bits(c.tys[0]) { c.tys.count = 0; return; }
    }
    array_add(*c.tys, ty);
    et := type_elem(ty);
    if c.common_elt == NONE c.common_elt = et;
    else if c.common_elt != et c.have_common_elt = false;
    if is_ptr_type(et) {
        c.have_vec_ptr = true;
        if c.common_vec_ptr == NONE c.common_vec_ptr = ty;
        else if c.common_vec_ptr != ty c.have_common_vec_ptr = false;
    }
}

// checkVectorTypesForPromotion
check_vector_types_for_promotion :: (P: *Sroa_Part, S: [] Sroa_Slice, c: *Vec_Cands) -> Type_Id {
    if c.tys.count == 0 return NONE;
    if c.have_vec_ptr && !c.have_common_vec_ptr return NONE;
    if !c.have_common_elt && c.have_vec_ptr {
        c.tys.count = 0;
        array_add(*c.tys, c.common_vec_ptr);
    } else if !c.have_common_elt && !c.have_vec_ptr {
        for * c.tys {
            if !is_int_type(type_elem(it.*)) it.* = fixed_vec(type_int(dl_type_size_bits(type_elem(it.*))), type_count(it.*));
        }
        // llvm::sort by element count, then unique (equal counts are the same type)
        for i: 1..c.tys.count-1 {
            x := c.tys[i];
            j := i - 1;
            while j >= 0 && type_count(c.tys[j]) > type_count(x) { c.tys[j + 1] = c.tys[j]; j -= 1; }
            c.tys[j + 1] = x;
        }
        k := 0;
        for c.tys { if k == 0 || type_count(c.tys[k - 1]) != type_count(it) { c.tys[k] = it; k += 1; } }
        c.tys.count = k;
    } else {
        c.tys.count = 1;
    }
    k := 0;
    for c.tys if type_count(it) <= 0xFFFF { c.tys[k] = it; k += 1; }
    c.tys.count = k;
    for vty: c.tys {
        es := dl_type_size_bits(type_elem(vty));
        if es % 8 continue;
        es /= 8;
        ok := true;
        if P.sj > P.si for x: P.si..P.sj-1 if !vector_viable_for_slice(P, S[x], vty, es) { ok = false; break; }
        if ok for t: P.tails if !vector_viable_for_slice(P, S[t], vty, es) { ok = false; break; }
        if ok return vty;
    }
    return NONE;
}

// VectorType::isValidElementType
is_valid_vector_elt :: (t: Type_Id) -> bool {
    k := type_kind(t);
    return k == .INT || k == .BYTE || is_fp_kind(k) || k == .PTR || (k == .TARGET_EXT && false);
}

// createAndCheckVectorTypesForPromotion
create_and_check_vector_types :: (P: *Sroa_Part, S: [] Sroa_Slice, other: [] Type_Id, copy: [] Type_Id, c: *Vec_Cands) -> Type_Id {
    for ty: other {
        if !is_valid_vector_elt(ty) continue;
        tsize := dl_type_size_bits(ty);
        for vty: copy {
            vsize := dl_type_size_bits(vty);
            esize := dl_type_size_bits(type_elem(vty));
            if tsize != vsize && tsize != esize && vsize % tsize == 0 vc_check_candidate(c, fixed_vec(ty, vsize / tsize));
        }
    }
    return check_vector_types_for_promotion(P, S, c);
}

// isVectorPromotionViable
is_vector_promotion_viable :: (P: *Sroa_Part, S: [] Sroa_Slice) -> Type_Id {
    c: Vec_Cands; c.tys.allocator = temp;
    ls_tys: [..] Type_Id; ls_tys.allocator = temp;
    deferred: [..] Type_Id; deferred.allocator = temp;
    add_unique :: (a: *[..] Type_Id, t: Type_Id) { for a.* if it == t return; array_add(a, t); }
    if P.sj > P.si for x: P.si..P.sj-1 {
        s := S[x];
        user := use_user(s.use);
        ty: Type_Id;
        if inst_op(user) == .LOAD ty = vtype(user);
        else if inst_op(user) == .STORE ty = vtype(op(user, 0));
        else continue;
        if is_ptr_type(scalar_type(ty)) && (s.begin != P.begin || s.end != P.end) { add_unique(*deferred, ty); continue; }
        add_unique(*ls_tys, ty);
        if s.begin == P.begin && s.end == P.end vc_check_candidate(*c, ty);
    }
    copy: [..] Type_Id; copy.allocator = temp;
    for c.tys array_add(*copy, it);
    v := create_and_check_vector_types(P, S, ls_tys, copy, *c);
    if v != NONE return v;
    c.tys.count = 0;
    return create_and_check_vector_types(P, S, deferred, copy, *c);
}

// isIntegerWideningViableForSlice
int_widening_viable_for_slice :: (s: Sroa_Slice, alloc_begin: u64, alloca_ty: Type_Id, whole: *bool) -> bool {
    size := dl_type_store_size(alloca_ty);
    rel_begin := s.begin - alloc_begin;
    rel_end := s.end - alloc_begin;
    user := use_user(s.use);
    if call_intrinsic(user) != "" && (is_lifetime_start_or_end(user) || is_droppable_user(user)) return true;
    if rel_end > size return false;
    if inst_op(user) == .LOAD {
        if inst(user).flags & F_VOLATILE return false;
        lt := vtype(user);
        if type_has_scalable(lt) || dl_type_store_size(lt) > size return false;
        if s.begin < alloc_begin return false;
        if !is_vector_type(lt) && rel_begin == 0 && rel_end == size whole.* = true;
        if is_int_type(lt) {
            if type_int_width(lt) < dl_type_store_size(lt) * 8 return false;
        } else if rel_begin != 0 || rel_end != size || !can_convert_value(alloca_ty, lt) return false;
    } else if inst_op(user) == .STORE {
        vt := vtype(op(user, 0));
        if inst(user).flags & F_VOLATILE return false;
        if type_has_scalable(vt) || dl_type_store_size(vt) > size return false;
        if s.begin < alloc_begin return false;
        if !is_vector_type(vt) && rel_begin == 0 && rel_end == size whole.* = true;
        if is_int_type(vt) {
            if type_int_width(vt) < dl_type_store_size(vt) * 8 return false;
        } else if rel_begin != 0 || rel_end != size || !can_convert_value(vt, alloca_ty) return false;
    } else if is_mem_intrinsic(user) {
        if mem_is_volatile(user) || !is_constant_kind(vkind(mem_length(user))) return false;
        if !s.splittable return false;
    } else return false;
    return true;
}

MAX_INT_BITS :: 1 << 23;

// isIntegerWideningViable
is_integer_widening_viable :: (P: *Sroa_Part, S: [] Sroa_Slice, alloca_ty: Type_Id) -> bool {
    bits := dl_type_size_bits(alloca_ty);
    if bits > MAX_INT_BITS return false;
    if bits != dl_type_store_size(alloca_ty) * 8 return false;
    int_ty := type_int(bits);
    if !can_convert_value(alloca_ty, int_ty) || !can_convert_value(int_ty, alloca_ty) return false;
    whole := P.si == P.sj && dl_is_legal_integer(bits);
    if P.sj > P.si for x: P.si..P.sj-1 if !int_widening_viable_for_slice(S[x], P.begin, alloca_ty, *whole) return false;
    for t: P.tails if !int_widening_viable_for_slice(S[t], P.begin, alloca_ty, *whole) return false;
    return whole;
}

// extractInteger
extract_integer :: (b: *Irb, v_in: Value_Id, ty: Type_Id, offset: u64, name: string) -> Value_Id {
    v := v_in;
    int_ty := vtype(v);
    sh := 8 * offset;
    if dl.big_endian sh = 8 * (dl_type_store_size(int_ty) - dl_type_store_size(ty) - offset);
    if sh v = irb_binop(b, .LSHR, v, const_int(int_ty, sh), tprint("%.shift", name));
    if ty != int_ty v = irb_cast(b, .TRUNC, v, ty, tprint("%.trunc", name));
    return v;
}

// insertInteger
insert_integer :: (b: *Irb, old_in: Value_Id, v_in: Value_Id, offset: u64, name: string) -> Value_Id {
    old := old_in; v := v_in;
    int_ty := vtype(old);
    ty := vtype(v);
    if ty != int_ty v = irb_cast(b, .ZEXT, v, int_ty, tprint("%.ext", name));
    sh := 8 * offset;
    if dl.big_endian sh = 8 * (dl_type_store_size(int_ty) - dl_type_store_size(ty) - offset);
    if sh v = irb_binop(b, .SHL, v, const_int(int_ty, sh), tprint("%.shift", name));
    if sh || type_int_width(ty) < type_int_width(int_ty) {
        // ~Ty->getMask().zext(IntTy->getBitWidth()).shl(ShAmt)
        iw := type_int_width(int_ty);
        m := ap_zext(ap_all_ones(type_int_width(ty)), iw);
        m = ap_not(ap_shl(m, cast(u32) sh));
        old = irb_binop(b, .AND, old, cf_int(int_ty, m), tprint("%.mask", name));
        v = irb_binop(b, .OR, old, v, tprint("%.insert", name));
    }
    return v;
}

seq_mask :: (begin: u64, n: u64) -> [] u32 {
    m := NewArray(cast(s64) n, u32,, allocator = temp);
    for i: 0..cast(s64) n - 1 m[i] = cast(u32)(begin + cast(u64) i);
    return m;
}
POISON_MASK :: 0xFFFF_FFFF;

// extractVector
extract_vector :: (b: *Irb, v: Value_Id, begin: u64, end: u64, name: string) -> Value_Id {
    n := end - begin;
    if n == type_count(vtype(v)) return v;
    if n == 1 return irb_extract_element(b, v, begin, tprint("%.extract", name));
    return irb_shuffle(b, v, NONE, seq_mask(begin, n), tprint("%.extract", name));
}

// insertVector
insert_vector :: (b: *Irb, old: Value_Id, v_in: Value_Id, begin: u64, name: string) -> Value_Id {
    v := v_in;
    vt := vtype(old);
    if !is_vector_type(vtype(v)) return irb_insert_element(b, old, v, begin, tprint("%.insert", name));
    nsub := type_count(vtype(v));
    n := type_count(vt);
    if nsub == n return v;
    end := begin + nsub;
    mask := NewArray(cast(s64) n, u32,, allocator = temp);
    for i: 0..cast(s64) n - 1 { idx := cast(u64) i; mask[i] = ifx idx >= begin && idx < end then cast(u32)(idx - begin) else POISON_MASK; }
    v = irb_shuffle(b, v, NONE, mask, tprint("%.expand", name));
    mask2 := NewArray(cast(s64) n, u32,, allocator = temp);
    for i: 0..cast(s64) n - 1 { idx := cast(u64) i; mask2[i] = ifx idx >= begin && idx < end then cast(u32) idx else cast(u32)(idx + n); }
    return irb_shuffle(b, v, old, mask2, tprint("%blend", name));
}

// mergeTwoVectors (an IRBuilder<> without name prefix)
merge_two_vectors :: (b: *Irb, v0_in: Value_Id, v1_in: Value_Id, elt: Type_Id) -> Value_Id {
    v0 := v0_in; v1 := v1_in;
    fix :: (b: *Irb, v: Value_Id, elt: Type_Id) -> Value_Id {
        vt := vtype(v);
        et := type_elem(vt);
        if et == elt return v;
        total := type_count(vt) * dl_type_size_bits(et);
        return irb_bitcast(b, v, fixed_vec(elt, total / dl_type_size_bits(elt)));
    }
    v0 = fix(b, v0, elt);
    v1 = fix(b, v1, elt);
    n0 := type_count(vtype(v0)); n1 := type_count(vtype(v1));
    mask: [..] u32; mask.allocator = temp;
    if n0 == n1 {
        for i: 0..cast(s64)(n0 + n1) - 1 array_add(*mask, cast(u32) i);
    } else {
        small := min(n0, n1); large := max(n0, n1);
        ext: [..] u32; ext.allocator = temp;
        for i: 0..cast(s64) small - 1 array_add(*ext, cast(u32) i);
        for i: cast(s64) small..cast(s64) large - 1 array_add(*ext, POISON_MASK);
        if n0 < n1 v0 = irb_shuffle(b, v0, const_poison(vtype(v0)), ext);
        else v1 = irb_shuffle(b, v1, const_poison(vtype(v1)), ext);
        for i: 0..cast(s64) n0 - 1 array_add(*mask, cast(u32) i);
        for i: 0..cast(s64) n1 - 1 array_add(*mask, cast(u32)(large + cast(u64) i));
    }
    return irb_shuffle(b, v0, v1, mask);
}

// ---------------------------------------------------------------- Loads.cpp: isSafeToLoadUnconditionally (subset)

// Value::getPointerAlignment
sroa_pointer_alignment :: (v: Value_Id) -> u64 {
    k := vkind(v);
    if k == .GLOBAL_VAR {
        g := glob(v);
        if g.align == 0 {
            t := g.value_type;
            if type_is_sized(t) {
                strong := g.has_init && g.linkage != .LINKONCE_ANY && g.linkage != .LINKONCE_ODR && g.linkage != .WEAK_ANY &&
                          g.linkage != .WEAK_ODR && g.linkage != .COMMON && g.linkage != .EXTERN_WEAK && g.linkage != .AVAILABLE_EXTERNALLY;
                if strong {
                    // DataLayout::getPreferredAlign(GV)
                    a := dl_pref_align(t);
                    if a < 16 && dl_type_alloc_size(t) * 8 > 128 a = 16;
                    return a;
                }
                return dl_abi_align(t);
            }
        }
        return max(g.align, 1);
    }
    if k == .ARGUMENT {
        f := arg_parent(v);
        s := attr_list_param(glob(f).attrs, v - glob(f).arg_start);
        a := attr_set_find(s, .Alignment);
        if a return a.ival;
        sr := attr_set_find(s, .StructRet);
        if sr && sr.ty != NONE && type_is_sized(sr.ty) return dl_abi_align(sr.ty);
        return 1;
    }
    if k == .INST {
        o := inst_op(v);
        if o == .ALLOCA return inst(v).align;
        if is_call_base(v) {
            a := attr_set_find(attr_list_ret(inst(v).attrs), .Alignment);
            if a return a.ival;
            f := call_called_function(v);
            if f != NONE { a = attr_set_find(attr_list_ret(glob(f).attrs), .Alignment); if a return a.ival; }
            return 1;
        }
        if o == .LOAD {
            m := get_metadata(v, md_kind_id("align"));
            if m != NONE fatal("SROA: !align metadata is not supported yet");
        }
        return 1;
    }
    if k == .FUNCTION fatal("SROA: alignment of function pointers is not supported yet");
    if k == .C_EXPR && cexpr(v).op == .INTTOPTR fatal("SROA: alignment of inttoptr constants is not supported yet");
    return 1;
}

// Value::getPointerDereferenceableBytes
sroa_pointer_dereferenceable_bytes :: (v: Value_Id) -> (bytes: u64, can_be_null: bool) {
    k := vkind(v);
    if k == .ARGUMENT {
        f := arg_parent(v);
        s := attr_list_param(glob(f).attrs, v - glob(f).arg_start);
        a := attr_set_find(s, .Dereferenceable);
        if a return a.ival, false;
        for kind: Attr_Kind.[.ByVal, .ByRef, .InAlloca, .Preallocated] {
            x := attr_set_find(s, kind);
            if x && x.ty != NONE && type_is_sized(x.ty) { n := dl_type_store_size(x.ty); if n return n, false; }
        }
        a = attr_set_find(s, .DereferenceableOrNull);
        if a return a.ival, true;
        return 0, true;
    }
    if k == .INST {
        o := inst_op(v);
        if is_call_base(v) {
            fatal("SROA: dereferenceability of call results is not supported yet");
        }
        if o == .LOAD || o == .INTTOPTR {
            if get_metadata(v, md_kind_id("dereferenceable")) != NONE || get_metadata(v, md_kind_id("dereferenceable_or_null")) != NONE
                fatal("SROA: !dereferenceable metadata is not supported yet");
            return 0, true;
        }
        if o == .ALLOCA {
            ok, sz := sroa_alloca_allocation_size(v);
            if ok return sz, false;
        }
        return 0, false;
    }
    if k == .GLOBAL_VAR {
        g := glob(v);
        if type_is_sized(g.value_type) && g.linkage != .EXTERN_WEAK return dl_type_store_size(g.value_type), false;
    }
    return 0, false;
}

// isDereferenceableAndAlignedPointer
deref_and_aligned :: (v: Value_Id, align: u64, size: u64, ctx: Value_Id, visited: *[..] Value_Id, depth: s64) -> bool {
    if depth == 0 return false;
    for visited.* if it == v return false;
    array_add(visited, v);
    o := sv_opcode(v);
    if o == .GEP {
        base := op(v, 0);
        w := dl_index_type_size_bits(vtype(v));
        off: u64 = 0;
        if !sv_gep_accumulate_of(v, *off, w) return false;
        if (off >> (w - 1)) & 1 return false;   // negative
        if off % align != 0 return false;
        return deref_and_aligned(base, align, off + size, ctx, visited, depth - 1);
    }
    if o == .BITCAST && is_ptr_type(vtype(op(v, 0))) return deref_and_aligned(op(v, 0), align, size, ctx, visited, depth - 1);
    if o == .SELECT && vkind(v) == .INST
        return deref_and_aligned(op(v, 1), align, size, ctx, visited, depth - 1) && deref_and_aligned(op(v, 2), align, size, ctx, visited, depth - 1);
    bytes, can_be_null := sroa_pointer_dereferenceable_bytes(v);
    known := size <= bytes;
    if known && can_be_null {
        fatal("SROA: isKnownNonZero for dereferenceable_or_null pointers is not supported yet");
    }
    if known && is_inst(v) && inst_op(v) != .ALLOCA {
        fatal("SROA: dereferenceability context checks (isValidAssumeForContext) are not supported yet");
    }
    if known return sroa_pointer_alignment(v) >= align;
    if is_inst(v) && is_call_base(v) {
        if sv_call_returned_arg(v) != NONE fatal("SROA: dereferenceability through returned arguments is not supported yet");
        fatal("SROA: getObjectSize of calls is not supported yet");
    }
    if o == .ADDRSPACECAST return deref_and_aligned(op(v, 0), align, size, ctx, visited, depth - 1);
    // isDereferenceableAndAlignedPointerViaAssumption: needs assume operand bundles
    if ctx != NONE && fn_has_assume_bundles(block_fn(inst(ctx).parent)) fatal("SROA: dereferenceability from assumes is not supported yet");
    return false;
}

fn_has_assume_bundles :: (f: Value_Id) -> bool {
    for b: fn_blocks(f) for i: block_insts(b) if call_intrinsic(i) == "llvm.assume" && call_num_bundles(i) > 0 return true;
    return false;
}

// AreEquivalentAddressValues
equivalent_address_values :: (a: Value_Id, b: Value_Id) -> bool {
    if a == b return true;
    if is_inst(a) && is_inst(b) {
        oa := inst_op(a);
        if (oa == .LOAD || oa == .PHI || oa == .GEP || is_cast_op(oa)) && inst_identical(a, b) return true;
    }
    return false;
}
// Instruction::isIdenticalTo (the subset AreEquivalentAddressValues needs)
inst_identical :: (a: Value_Id, b: Value_Id) -> bool {
    if inst_op(a) != inst_op(b) || vtype(a) != vtype(b) || nops(a) != nops(b) return false;
    n := nops(a);
    if n > 0 for k: 0..n-1 if op(a, k) != op(b, k) return false;
    ra := inst(a); rb := inst(b);
    if ra.flags != rb.flags || ra.ty2 != rb.ty2 || ra.align != rb.align || ra.ord1 != rb.ord1 || ra.sync != rb.sync return false;
    if inst_op(a) == .PHI { if n > 0 for k: 0..n-1 if phi_block(a, k) != phi_block(b, k) return false; }
    return true;
}

// isSafeToLoadUnconditionally(V, Alignment, Size, DL, ScanFrom)
is_safe_to_load_unconditionally :: (v_in: Value_Id, align: u64, size: u64, scan_from: Value_Id) -> bool {
    visited: [..] Value_Id; visited.allocator = temp;
    if deref_and_aligned(v_in, align, size, scan_from, *visited, 16) {
        // suppressSpeculativeLoadForSanitizers
        if scan_from == NONE return true;
        fa := attr_list_fn(glob(block_fn(inst(scan_from).parent)).attrs);
        if !(attr_set_has(fa, .SanitizeThread) || attr_set_has(fa, .SanitizeAddress) || attr_set_has(fa, .SanitizeHWAddress)) return true;
    }
    if scan_from == NONE return false;
    v := strip_pointer_casts(v_in);
    x := inst(scan_from).prev;
    while x != NONE {
        cur := x;
        x = inst(x).prev;
        o := inst_op(cur);
        if o == .CALL && may_write_to_memory(cur) && !is_lifetime_start_or_end(cur) return false;
        ptr: Value_Id; ty: Type_Id; al: u64;
        if o == .LOAD {
            if inst(cur).flags & F_VOLATILE continue;
            ptr = op(cur, 0); ty = vtype(cur); al = inst(cur).align;
        } else if o == .STORE {
            if inst(cur).flags & F_VOLATILE continue;
            ptr = op(cur, 1); ty = vtype(op(cur, 0)); al = inst(cur).align;
        } else continue;
        if al < align continue;
        if ptr == v && size <= dl_type_store_size(ty) return true;
        if equivalent_address_values(strip_pointer_casts(ptr), v) && size <= dl_type_store_size(ty) return true;
    }
    return false;
}

// ---------------------------------------------------------------- PHI / select speculation

// isSafePHIToSpeculate
is_safe_phi_to_speculate :: (pn: Value_Id) -> bool {
    bb := inst(pn).parent;
    max_align: u64 = 1;
    load_ty: Type_Id = NONE;
    u := ir.v_first_use[pn];
    while u != NONE {
        li := ir.u_user[u];
        u = ir.u_next[u];
        if inst_op(li) != .LOAD || !inst_is_simple(li) return false;
        if inst(li).parent != bb return false;
        if load_ty != NONE { if load_ty != vtype(li) return false; }
        else load_ty = vtype(li);
        x := pn;
        while x != li { if may_write_to_memory(x) return false; x = inst(x).next; }
        max_align = max(max_align, inst(li).align);
    }
    if load_ty == NONE return false;
    size := dl_type_store_size(load_ty);
    n := nops(pn);
    if n > 0 for k: 0..n-1 {
        ti := block_terminator(phi_block(pn, k));
        inval := op(pn, k);
        if ti == inval || may_have_side_effects(ti) return false;
        if num_successors(ti) == 1 continue;
        if is_safe_to_load_unconditionally(inval, max_align, size, ti) continue;
        return false;
    }
    return true;
}

inst_is_simple :: (i: Value_Id) -> bool { r := inst(i); return r.ord1 == 0 && (r.flags & F_VOLATILE) == 0; }

// Instruction::getAAMetadata / setAAMetadata
AA_Tags :: struct { tbaa: Md_Id = NONE; tbaa_struct: Md_Id = NONE; scope: Md_Id = NONE; noalias: Md_Id = NONE; noalias_as: Md_Id = NONE; }
aa_any :: (a: AA_Tags) -> bool { return a.tbaa != NONE || a.tbaa_struct != NONE || a.scope != NONE || a.noalias != NONE || a.noalias_as != NONE; }
get_aa_metadata :: (i: Value_Id) -> AA_Tags {
    a: AA_Tags;
    a.tbaa = get_metadata(i, MDK_TBAA);
    a.tbaa_struct = get_metadata(i, MDK_TBAA_STRUCT);
    a.scope = get_metadata(i, MDK_ALIAS_SCOPE);
    a.noalias = get_metadata(i, MDK_NOALIAS);
    a.noalias_as = get_metadata(i, MDK_NOALIAS_ADDRSPACE);
    return a;
}
set_aa_metadata :: (i: Value_Id, a: AA_Tags) {
    set_metadata(i, MDK_TBAA, a.tbaa);
    set_metadata(i, MDK_TBAA_STRUCT, a.tbaa_struct);
    set_metadata(i, MDK_ALIAS_SCOPE, a.scope);
    set_metadata(i, MDK_NOALIAS, a.noalias);
    set_metadata(i, MDK_NOALIAS_ADDRSPACE, a.noalias_as);
}
md_const_u64 :: (m: Md_Id) -> u64 {
    if m == NONE || ir.mds[m].kind != .VALUE fatal("internal: expected a constant metadata operand");
    return const_int_zext(ir.mds[m].value);
}
// AAMDNodes::shiftTBAAStruct
shift_tbaa_struct :: (m: Md_Id, offset: u64) -> Md_Id {
    if offset == 0 return m;
    sub: [..] Md_Id; sub.allocator = temp;
    n := ir.mds[m].nops;
    i: u32 = 0;
    while i + 2 < n {
        o0 := md_op(m, i); o1 := md_op(m, i + 1);
        io := md_const_u64(o0); is := md_const_u64(o1);
        if io + is <= offset { i += 3; continue; }
        nsz := is;
        noff := io - offset;
        if io < offset { noff = 0; nsz -= offset - io; }
        array_add(*sub, md_value(const_int(vtype(ir.mds[o0].value), noff)));
        array_add(*sub, md_value(const_int(vtype(ir.mds[o1].value), nsz)));
        array_add(*sub, md_op(m, i + 2));
        i += 3;
    }
    return md_tuple(sub, false);
}
// AAMDNodes::shift
aa_shift :: (a: AA_Tags, offset: u64) -> AA_Tags {
    r := a;
    if a.tbaa_struct != NONE r.tbaa_struct = shift_tbaa_struct(a.tbaa_struct, offset);
    return r;
}
// AAMDNodes::adjustForAccess(unsigned AccessSize)
aa_adjust_size :: (a: AA_Tags, access_size: u64) -> AA_Tags {
    r := a;
    m := r.tbaa_struct;
    if r.tbaa == NONE && m != NONE && ir.mds[m].nops >= 3 {
        o0 := md_op(m, 0); o1 := md_op(m, 1); o2 := md_op(m, 2);
        if o0 != NONE && ir.mds[o0].kind == .VALUE && vkind(ir.mds[o0].value) == .C_INT && is_null_value(ir.mds[o0].value) &&
           o1 != NONE && ir.mds[o1].kind == .VALUE && vkind(ir.mds[o1].value) == .C_INT && const_int_zext(ir.mds[o1].value) == access_size &&
           o2 != NONE && is_md_node(o2)
            r.tbaa = o2;
    }
    r.tbaa_struct = NONE;
    return r;
}
// adjustForAccess(Offset, AccessTy, DL)
aa_adjust_for_access_ty :: (a: AA_Tags, offset: u64, ty: Type_Id) -> AA_Tags {
    r := aa_shift(a, offset);
    if !dl_size_eq_store_size(ty) return r;
    if type_has_scalable(ty) return r;
    return aa_adjust_size(r, dl_type_store_size(ty));
}
aa_adjust_for_access_size :: (a: AA_Tags, offset: u64, size: u64) -> AA_Tags { return aa_adjust_size(aa_shift(a, offset), size); }

// Instruction::copyMetadata(Src, WL) with WL = {mem_parallel_loop_access, access_group}
copy_loop_metadata :: (dst: Value_Id, src: Value_Id) {
    for name: string.["llvm.mem.parallel_loop_access", "llvm.access.group"] {
        k := md_kind_id(name);
        m := get_metadata(src, k);
        if m != NONE set_metadata(dst, k, m);
    }
}

// copyMetadataForLoad
copy_metadata_for_load :: (dst: Value_Id, src: Value_Id) {
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(src, *all);
    nt := vtype(dst);
    for all {
        name := ir.md_kind_names[it.kind];
        if name == "dbg" || name == "tbaa" || name == "prof" || name == "fpmath" || name == "tbaa.struct" ||
           name == "invariant.load" || name == "alias.scope" || name == "noalias" || name == "nontemporal" ||
           name == "mem.cache_hint" || name == "llvm.mem.parallel_loop_access" || name == "llvm.access.group" ||
           name == "noundef" || name == "noalias.addrspace" || name == "invariant.group" {
            set_metadata(dst, it.kind, it.md);
        } else if name == "nonnull" {
            if is_ptr_type(nt) set_metadata(dst, it.kind, it.md);
            else if is_int_type(nt) {
                // copyNonnullMetadata: !range [ptrtoint(null) + 1, ptrtoint(null))
                null_int := ce_cast(.PTRTOINT, const_null_value(vtype(op(src, 0))), nt);
                nonnull := ce_binop(.ADD, null_int, const_int(nt, 1), 0);
                set_metadata(dst, md_kind_id("range"), md_tuple(.[md_value(nonnull), md_value(null_int)], false));
            }
        } else if name == "align" || name == "dereferenceable" || name == "dereferenceable_or_null" {
            if is_ptr_type(nt) set_metadata(dst, it.kind, it.md);
        } else if name == "range" {
            if nt == vtype(src) set_metadata(dst, it.kind, it.md);
            else if is_ptr_type(nt) {
                // copyRangeMetadata: !nonnull when the range excludes 0
                if dl_type_size_bits(nt) == type_int_width(scalar_type(vtype(src))) && !md_range_contains_zero(it.md)
                    set_metadata(dst, md_kind_id("nonnull"), md_tuple(.[], false));
            }
        } else if name == "nofpclass" {
            if scalar_type(nt) == scalar_type(vtype(src)) set_metadata(dst, it.kind, it.md);
        }
    }
}

// speculatePHINodeLoads
speculate_phi_node_loads :: (b: *Irb, pn: Value_Id) {
    some := ir.u_user[ir.v_first_use[pn]];
    lty := vtype(some);
    irb_set_before(b, pn);
    b.head = true;   // inserting a phi before a phi: never adopt debug records
    new_pn := irb_phi(b, lty, nops(pn), tprint("%.sroa.speculated", vname(pn)));
    tags := get_aa_metadata(some);
    al := inst(some).align;
    while has_uses(pn) {
        li := ir.u_user[ir.v_first_use[pn]];
        rauw_with_metadata(li, new_pn);
        erase_inst_with_metadata(li);
    }
    injected: Table(Value_Id, Value_Id); injected.allocator = temp;
    n := nops(pn);
    if n > 0 for k: 0..n-1 {
        pred := phi_block(pn, k);
        inval := op(pn, k);
        found, v := table_find(*injected, pred);
        if found { phi_add_incoming(new_pn, v, pred); continue; }
        irb_set_before(b, block_terminator(pred));
        ld := irb_load(b, lty, inval, al, false, tprint("%.sroa.speculate.load.%", vname(pn), vname(pred)));
        if aa_any(tags) set_aa_metadata(ld, tags);
        phi_add_incoming(new_pn, ld, pred);
        table_set(*injected, pred, ld);
    }
    erase_inst_with_metadata(pn);
}

SPEC_TRUE :: 1;
SPEC_FALSE :: 2;
Sroa_Mem_Op :: struct { i: Value_Id; is_store: bool; spec: u8; }

// isSafeLoadOfSelectToSpeculate
safe_load_of_select_spec :: (li: Value_Id, si: Value_Id, preserve_cfg: bool) -> u8 {
    spec: u8 = 0;
    for v: Value_Id.[op(si, 1), op(si, 2)] {
        if is_safe_to_load_unconditionally(v, inst(li).align, dl_type_store_size(vtype(li)), li) {
            spec |= ifx v == op(si, 1) then cast(u8) SPEC_TRUE else SPEC_FALSE;
        } else if preserve_cfg return spec;
    }
    return spec;
}

// SROA::isSafeSelectToSpeculate; ok = false: std::nullopt
is_safe_select_to_speculate :: (si: Value_Id, preserve_cfg: bool, ops: *[..] Sroa_Mem_Op) -> bool {
    u := ir.v_first_use[si];
    while u != NONE {
        user := ir.u_user[u];
        u = ir.u_next[u];
        if inst_op(user) == .BITCAST && num_uses(user) == 1 user = ir.u_user[ir.v_first_use[user]];
        if inst_op(user) == .STORE {
            if (inst(user).flags & F_VOLATILE) || preserve_cfg return false;
            array_add(ops, .{user, true, 0});
            continue;
        }
        if inst_op(user) != .LOAD || (inst(user).flags & F_VOLATILE) return false;
        if !inst_is_simple(user) {
            if preserve_cfg return false;
            array_add(ops, .{user, false, 0});
            continue;
        }
        spec := safe_load_of_select_spec(user, si, preserve_cfg);
        if preserve_cfg && spec != SPEC_TRUE | SPEC_FALSE return false;
        array_add(ops, .{user, false, spec});
    }
    return true;
}

// speculateSelectInstLoads
speculate_select_inst_loads :: (b: *Irb, si: Value_Id, li: Value_Id) {
    tv := op(si, 1); fv := op(si, 2);
    irb_set_before(b, li);
    al := inst(li).align;
    tl := irb_load(b, vtype(li), tv, al, false, tprint("%.sroa.speculate.load.true", vname(li)));
    fl := irb_load(b, vtype(li), fv, al, false, tprint("%.sroa.speculate.load.false", vname(li)));
    tags := get_aa_metadata(li);
    if aa_any(tags) { set_aa_metadata(tl, tags); set_aa_metadata(fl, tags); }
    v := irb_select(b, op(si, 0), tl, fl, tprint("%.sroa.speculated", vname(li)), si);
    rauw_with_metadata(li, v);
}

// rewriteSelectInstMemOps
rewrite_select_inst_mem_ops :: (b: *Irb, si: Value_Id, ops: [] Sroa_Mem_Op, preserve_cfg: bool) -> bool {
    cfg_changed := false;
    for o: ops {
        if !o.is_store && o.spec == SPEC_TRUE | SPEC_FALSE {
            speculate_select_inst_loads(b, si, o.i);
        } else {
            rewrite_mem_op_of_select(si, o.i, o.spec);
            cfg_changed = true;
        }
        erase_inst_with_metadata(o.i);
    }
    u := ir.v_first_use[si];
    while u != NONE { nu := ir.u_next[u]; erase_inst_with_metadata(ir.u_user[u]); u = nu; }
    erase_inst_with_metadata(si);
    return cfg_changed;
}

// getAdjustedPtr
get_adjusted_ptr :: (b: *Irb, ptr_in: Value_Id, offset: u64, width: u32, ptr_ty: Type_Id, prefix: string) -> Value_Id {
    ptr := ptr_in;
    if offset != 0 ptr = irb_inbounds_ptr_add(b, ptr, const_int(type_int(width), offset), tprint("%sroa_idx", prefix));
    return irb_pointer_bitcast_or_addrspacecast(b, ptr, ptr_ty, tprint("%sroa_cast", prefix));
}
// getLoadStoreAlignment
load_store_align :: (i: Value_Id) -> u64 { return inst(i).align; }

// ---------------------------------------------------------------- the pass state

Sroa_Select_Rw :: struct { sel: Value_Id; ops: [..] Sroa_Mem_Op; }

Sroa :: struct {
    f: Value_Id;
    dt: *Dom_Tree;
    preserve_cfg: bool;
    agg_to_vec: bool;
    worklist: Set_Vec;
    post_promotion: Set_Vec;
    promotable: Set_Vec;
    dead_insts: [..] Value_Id;
    spec_phis: Set_Vec;
    selects: [..] Sroa_Select_Rw;   // SmallMapVector<SelectInst*, RewriteableMemOps>
    cfg_changed: bool;
}

// DomTreeUpdater (lazy): updates queued by SplitBlockAndInsertIfThen(Else), applied on getDomTree() / at the end
sroa_pending_dt_updates: [..] Dom_Update;
sroa_flush_dt :: (dt: *Dom_Tree) {
    if sroa_pending_dt_updates.count == 0 return;
    dt_apply_updates(dt, sroa_pending_dt_updates);
    sroa_pending_dt_updates.count = 0;
}

// ---------------------------------------------------------------- AllocaSliceRewriter

Sroa_Rewriter :: struct {
    pass: *Sroa;
    S: [] Sroa_Slice;
    old_ai: Value_Id;
    new_ai: Value_Id;
    na_begin: u64;      // NewAllocaBeginOffset
    na_end: u64;
    na_ty: Type_Id;     // NewAllocaTy
    int_ty: Type_Id = NONE;
    vec_ty: Type_Id = NONE;
    elt_ty: Type_Id = NONE;
    elt_size: u64;
    begin: u64; end: u64;
    nbegin: u64; nend: u64;
    slice_size: u64;
    splittable: bool;
    is_split: bool;
    old_use: Use_Id = NONE;
    old_ptr: Value_Id = NONE;
    phi_users: *Set_Vec;
    select_users: *Set_Vec;
    irb: Irb;
}

rw_slice_align :: (r: *Sroa_Rewriter) -> u64 { return common_alignment(inst(r.new_ai).align, r.nbegin - r.na_begin); }

rw_index :: (r: *Sroa_Rewriter, off: u64) -> u64 { return (off - r.na_begin) / r.elt_size; }

rw_delete_if_trivially_dead :: (r: *Sroa_Rewriter, v: Value_Id) {
    if sroa_trivially_dead(v) array_add(*r.pass.dead_insts, v);
}

// getPtrToNewAI
rw_ptr_to_new_ai :: (r: *Sroa_Rewriter, as: u32, volatile: bool) -> Value_Id {
    if !volatile || as == cast(u32) ir.types[vtype(r.new_ai)].a return r.new_ai;
    return irb_cast(*r.irb, .ADDRSPACECAST, r.new_ai, type_ptr(as));
}

ptr_as :: (v: Value_Id) -> u32 { return cast(u32) ir.types[scalar_type(vtype(v))].a; }

// getNewAllocaSlicePtr
rw_new_alloca_slice_ptr :: (r: *Sroa_Rewriter, b: *Irb, ptr_ty: Type_Id) -> Value_Id {
    offset := r.nbegin - r.na_begin;
    name := vname(r.old_ptr);
    p := find_last(name, ".sroa.");
    if p >= 0 {
        name = slice(name, p + 6, name.count - p - 6);
        ie := first_non_digit(name);
        if ie >= 0 && name[ie] == #char "." {
            name = slice(name, ie + 1, name.count - ie - 1);
            oe := first_non_digit(name);
            if oe >= 0 && name[oe] == #char "." name = slice(name, oe + 1, name.count - oe - 1);
        }
    }
    q := find_first(name, ".sroa_");
    if q >= 0 name = slice(name, 0, q);
    return get_adjusted_ptr(b, r.new_ai, offset, dl_index_type_size_bits(ptr_ty), ptr_ty, tprint("%.", name));
}
find_last :: (s: string, pat: string) -> s64 {
    if pat.count > s.count return -1;
    i := s.count - pat.count;
    while i >= 0 { if slice(s, i, pat.count) == pat return i; i -= 1; }
    return -1;
}
find_first :: (s: string, pat: string) -> s64 {
    if pat.count > s.count return -1;
    for i: 0..s.count - pat.count if slice(s, i, pat.count) == pat return i;
    return -1;
}
first_non_digit :: (s: string) -> s64 {
    for i: 0..s.count-1 if s[i] < #char "0" || s[i] > #char "9" return i;
    return -1;
}

set_atomic_from :: (dst: Value_Id, src: Value_Id) { inst(dst).ord1 = inst(src).ord1; inst(dst).sync = inst(src).sync; }

rw_visit :: (r: *Sroa_Rewriter, si: s64, sl: Sroa_Slice) -> bool {
    r.begin = sl.begin; r.end = sl.end;
    r.splittable = sl.splittable;
    r.is_split = r.begin < r.na_begin || r.end > r.na_end;
    r.nbegin = max(r.begin, r.na_begin);
    r.nend = min(r.end, r.na_end);
    r.slice_size = r.nend - r.nbegin;
    r.old_use = sl.use;
    r.old_ptr = use_value(sl.use);
    user := use_user(sl.use);
    irb_set_before(*r.irb, user);
    r.irb.dbg = get_metadata(user, 0);
    r.irb.prefix = tconcat(vname(r.new_ai), ".", tdec(r.begin), ".");
    o := inst_op(user);
    if o == .LOAD return rw_visit_load(r, user);
    if o == .STORE return rw_visit_store(r, user);
    if o == .PHI return rw_visit_phi(r, user);
    if o == .SELECT return rw_visit_select(r, user);
    if is_memset_intrinsic(user) return rw_visit_memset(r, user);
    if is_memtransfer_intrinsic(user) return rw_visit_memtransfer(r, user);
    if call_intrinsic(user) != "" return rw_visit_intrinsic(r, user);
    fatal("internal: SROA: no rewrite rule for this instruction");
    return false;
}

rw_vectorized_load :: (r: *Sroa_Rewriter, li: Value_Id) -> Value_Id {
    bi := rw_index(r, r.nbegin); ei := rw_index(r, r.nend);
    ld := irb_load(*r.irb, r.na_ty, r.new_ai, inst(r.new_ai).align, false, "load");
    copy_loop_metadata(ld, li);
    return extract_vector(*r.irb, ld, bi, ei, "vec");
}

rw_integer_load :: (r: *Sroa_Rewriter, li: Value_Id) -> Value_Id {
    v := irb_load(*r.irb, r.na_ty, r.new_ai, inst(r.new_ai).align, false, "load");
    v = irb_bit_preserving_cast_chain(*r.irb, v, r.int_ty);
    off := r.nbegin - r.na_begin;
    if off > 0 || r.nend < r.na_end v = extract_integer(*r.irb, v, type_int(r.slice_size * 8), off, "extract");
    if type_int_width(vtype(li)) > r.slice_size * 8 v = irb_cast(*r.irb, .ZEXT, v, vtype(li));
    return v;
}

rw_visit_load :: (r: *Sroa_Rewriter, li: Value_Id) -> bool {
    old_op := op(li, 0);
    tags := get_aa_metadata(li);
    as := ptr_as(old_op);
    volatile := (inst(li).flags & F_VOLATILE) != 0;
    target_ty := ifx r.is_split then type_int(r.slice_size * 8) else vtype(li);
    ptr_adjusted := false;
    v: Value_Id;
    if r.vec_ty != NONE {
        v = rw_vectorized_load(r, li);
    } else if r.int_ty != NONE && is_int_type(vtype(li)) {
        v = rw_integer_load(r, li);
    } else if r.nbegin == r.na_begin && r.nend == r.na_end &&
              (can_convert_value(r.na_ty, target_ty) ||
               (is_int_type(r.na_ty) && is_int_type(target_ty) && dl_type_store_size(target_ty) > r.slice_size && !volatile)) {
        new_ptr := rw_ptr_to_new_ai(r, as, volatile);
        nli := irb_load(*r.irb, r.na_ty, new_ptr, inst(r.new_ai).align, volatile, name_ref(vname(li)));
        if volatile set_atomic_from(nli, li);
        if inst(nli).ord1 != 0 inst(nli).align = inst(li).align;
        copy_metadata_for_load(nli, li);
        if aa_any(tags) set_aa_metadata(nli, aa_adjust_for_access_ty(tags, r.nbegin - r.begin, vtype(nli)));
        v = nli;
        if is_int_type(r.na_ty) && is_int_type(target_ty) && type_int_width(r.na_ty) < type_int_width(target_ty) {
            v = irb_cast(*r.irb, .ZEXT, v, target_ty, "load.ext");
            if dl.big_endian v = irb_binop(*r.irb, .SHL, v, const_int(target_ty, type_int_width(target_ty) - type_int_width(r.na_ty)), "endian_shift");
        }
    } else {
        lty := type_ptr(as);
        nli := irb_load(*r.irb, target_ty, rw_new_alloca_slice_ptr(r, *r.irb, lty), rw_slice_align(r), volatile, name_ref(vname(li)));
        if aa_any(tags) set_aa_metadata(nli, aa_adjust_for_access_ty(tags, r.nbegin - r.begin, vtype(nli)));
        if volatile set_atomic_from(nli, li);
        copy_loop_metadata(nli, li);
        v = nli;
        ptr_adjusted = true;
    }
    v = irb_bit_preserving_cast_chain(*r.irb, v, target_ty);
    if r.is_split {
        nx := inst(li).next;
        irb_set_at(*r.irb, inst(li).parent, nx, true);
        ph := new_inst(.LOAD, vtype(li), 1);
        set_op(ph, 0, const_poison(type_ptr(as)));
        inst(ph).align = 1;
        v = insert_integer(*r.irb, ph, v, r.nbegin - r.begin, "insert");
        rauw_with_metadata(li, v);
        replace_all_uses_with(ph, li);
        erase_inst(ph);
    } else {
        rauw_with_metadata(li, v);
    }
    array_add(*r.pass.dead_insts, li);
    rw_delete_if_trivially_dead(r, old_op);
    return !volatile && !ptr_adjusted;
}

rw_vectorized_store :: (r: *Sroa_Rewriter, v_in: Value_Id, si: Value_Id, tags: AA_Tags) -> bool {
    v := v_in;
    if vtype(v) != r.vec_ty {
        bi := rw_index(r, r.nbegin); ei := rw_index(r, r.nend);
        n := ei - bi;
        slice_ty := ifx n == 1 then r.elt_ty else fixed_vec(r.elt_ty, n);
        if vtype(v) != slice_ty v = irb_bit_preserving_cast_chain(*r.irb, v, slice_ty);
        old := irb_load(*r.irb, r.na_ty, r.new_ai, inst(r.new_ai).align, false, "load");
        v = insert_vector(*r.irb, old, v, bi, "vec");
    }
    st := irb_store(*r.irb, v, r.new_ai, inst(r.new_ai).align);
    copy_loop_metadata(st, si);
    if aa_any(tags) set_aa_metadata(st, aa_adjust_for_access_ty(tags, r.nbegin - r.begin, vtype(v)));
    array_add(*r.pass.dead_insts, si);
    return true;
}

rw_integer_store :: (r: *Sroa_Rewriter, v_in: Value_Id, si: Value_Id, tags: AA_Tags) -> bool {
    v := v_in;
    if dl_type_size_bits(vtype(v)) != type_int_width(r.int_ty) {
        old := irb_load(*r.irb, r.na_ty, r.new_ai, inst(r.new_ai).align, false, "oldload");
        old = irb_bit_preserving_cast_chain(*r.irb, old, r.int_ty);
        off := r.begin - r.na_begin;
        v = insert_integer(*r.irb, old, op(si, 0), off, "insert");
    }
    v = irb_bit_preserving_cast_chain(*r.irb, v, r.na_ty);
    st := irb_store(*r.irb, v, r.new_ai, inst(r.new_ai).align);
    copy_loop_metadata(st, si);
    if aa_any(tags) set_aa_metadata(st, aa_adjust_for_access_ty(tags, r.nbegin - r.begin, vtype(v)));
    array_add(*r.pass.dead_insts, si);
    return true;
}

rw_visit_store :: (r: *Sroa_Rewriter, si: Value_Id) -> bool {
    old_op := op(si, 1);
    tags := get_aa_metadata(si);
    v := op(si, 0);
    volatile := (inst(si).flags & F_VOLATILE) != 0;
    if is_ptr_type(vtype(v)) {
        base := sv_strip_in_bounds_offsets(v);
        if is_inst(base) && inst_op(base) == .ALLOCA svec_insert(*r.pass.post_promotion, base);
    }
    ssize := dl_type_store_size(vtype(v));
    if !type_has_scalable(vtype(v)) && r.slice_size < ssize {
        v = extract_integer(*r.irb, v, type_int(r.slice_size * 8), r.nbegin - r.begin, "extract");
    }
    if r.vec_ty != NONE return rw_vectorized_store(r, v, si, tags);
    if r.int_ty != NONE && is_int_type(vtype(v)) return rw_integer_store(r, v, si, tags);
    nsi: Value_Id;
    if r.nbegin == r.na_begin && r.nend == r.na_end && can_convert_value(vtype(v), r.na_ty) {
        v = irb_bit_preserving_cast_chain(*r.irb, v, r.na_ty);
        new_ptr := rw_ptr_to_new_ai(r, ptr_as(old_op), volatile);
        nsi = irb_store(*r.irb, v, new_ptr, inst(r.new_ai).align, volatile);
    } else {
        new_ptr := rw_new_alloca_slice_ptr(r, *r.irb, type_ptr(ptr_as(old_op)));
        nsi = irb_store(*r.irb, v, new_ptr, rw_slice_align(r), volatile);
    }
    copy_loop_metadata(nsi, si);
    if aa_any(tags) set_aa_metadata(nsi, aa_adjust_for_access_ty(tags, r.nbegin - r.begin, vtype(v)));
    if volatile set_atomic_from(nsi, si);
    if inst(nsi).ord1 != 0 inst(nsi).align = inst(si).align;
    array_add(*r.pass.dead_insts, si);
    rw_delete_if_trivially_dead(r, old_op);
    return op(nsi, 1) == r.new_ai && vtype(op(nsi, 0)) == r.na_ty && !volatile;
}

// getIntegerSplat
rw_integer_splat :: (r: *Sroa_Rewriter, v: Value_Id, size: u64) -> Value_Id {
    if size == 1 return v;
    st := type_int(size * 8);
    z := irb_cast(*r.irb, .ZEXT, v, st, "zext");
    d := irb_binop(*r.irb, .UDIV, cf_all_ones(st), irb_cast(*r.irb, .ZEXT, cf_all_ones(vtype(v)), st));
    return irb_binop(*r.irb, .MUL, z, d, "isplat");
}

set_param_align :: (ci: Value_Id, k: u32, a: u64) { add_param_align(ci, k, a); }

rw_visit_memset :: (r: *Sroa_Rewriter, ii: Value_Id) -> bool {
    tags := get_aa_metadata(ii);
    len := mem_length(ii);
    volatile := mem_is_volatile(ii);
    if vkind(len) != .C_INT {
        set_op(ii, 0, rw_new_alloca_slice_ptr(r, *r.irb, vtype(r.old_ptr)));
        set_param_align(ii, 0, rw_slice_align(r));
        rw_delete_if_trivially_dead(r, r.old_ptr);
        return false;
    }
    array_add(*r.pass.dead_insts, ii);
    scalar_ty := scalar_type(r.na_ty);
    can_continue := false;
    if r.vec_ty != NONE || r.int_ty != NONE can_continue = true;
    else if !(r.begin > r.na_begin || r.end < r.na_end) {
        l := const_int_zext_limited(len);
        if l <= 0xFFFF_FFFF {
            src_ty := fixed_vec(ir.t_i8, l);
            can_continue = can_convert_value(src_ty, r.na_ty) && dl_is_legal_integer(dl_type_size_bits(scalar_ty));
        }
    }
    if !can_continue {
        sz := r.nend - r.nbegin;
        size := const_int(vtype(len), sz);
        nw := irb_memset(*r.irb, rw_new_alloca_slice_ptr(r, *r.irb, vtype(r.old_ptr)), op(ii, 1), size, rw_slice_align(r), volatile);
        if aa_any(tags) set_aa_metadata(nw, aa_adjust_for_access_size(tags, r.nbegin - r.begin, sz));
        return false;
    }
    v: Value_Id;
    if r.vec_ty != NONE {
        bi := rw_index(r, r.nbegin); ei := rw_index(r, r.nend);
        n := ei - bi;
        splat := rw_integer_splat(r, op(ii, 1), dl_type_size_bits(r.elt_ty) / 8);
        splat = irb_bit_preserving_cast_chain(*r.irb, splat, r.elt_ty);
        if n > 1 splat = irb_vector_splat(*r.irb, n, splat, "vsplat");
        old := irb_load(*r.irb, r.na_ty, r.new_ai, inst(r.new_ai).align, false, "oldload");
        v = insert_vector(*r.irb, old, splat, bi, "vec");
    } else if r.int_ty != NONE {
        size := r.nend - r.nbegin;
        v = rw_integer_splat(r, op(ii, 1), size);
        if r.nbegin != r.na_begin || r.nend != r.na_end {
            old := irb_load(*r.irb, r.na_ty, r.new_ai, inst(r.new_ai).align, false, "oldload");
            old = irb_bit_preserving_cast_chain(*r.irb, old, r.int_ty);
            v = insert_integer(*r.irb, old, v, r.nbegin - r.na_begin, "insert");
        }
        v = irb_bit_preserving_cast_chain(*r.irb, v, r.na_ty);
    } else {
        v = rw_integer_splat(r, op(ii, 1), dl_type_size_bits(scalar_ty) / 8);
        if is_vector_type(r.na_ty) v = irb_vector_splat(*r.irb, type_count(r.na_ty), v, "vsplat");
        v = irb_bit_preserving_cast_chain(*r.irb, v, r.na_ty);
    }
    new_ptr := rw_ptr_to_new_ai(r, ptr_as(op(ii, 0)), volatile);
    st := irb_store(*r.irb, v, new_ptr, inst(r.new_ai).align, volatile);
    copy_loop_metadata(st, ii);
    if aa_any(tags) set_aa_metadata(st, aa_adjust_for_access_ty(tags, r.nbegin - r.begin, vtype(v)));
    return !volatile;
}

rw_visit_memtransfer :: (r: *Sroa_Rewriter, ii: Value_Id) -> bool {
    tags := get_aa_metadata(ii);
    is_dest := r.old_use == op_use(ii, 0);
    slice_align := rw_slice_align(r);
    volatile := mem_is_volatile(ii);
    if !r.splittable {
        adj := rw_new_alloca_slice_ptr(r, *r.irb, vtype(r.old_ptr));
        if is_dest { set_op(ii, 0, adj); set_param_align(ii, 0, slice_align); }
        else { set_op(ii, 1, adj); set_param_align(ii, 1, slice_align); }
        rw_delete_if_trivially_dead(r, r.old_ptr);
        return false;
    }
    emit_memcpy := r.vec_ty == NONE && r.int_ty == NONE &&
        (r.begin > r.na_begin || r.end < r.na_end || r.slice_size != dl_type_store_size(r.na_ty) ||
         !dl_size_eq_store_size(r.na_ty) || !is_single_value_type(r.na_ty));
    if emit_memcpy && r.old_ai == r.new_ai {
        if r.nend != r.end set_op(ii, 2, const_int(vtype(mem_length(ii)), r.nend - r.nbegin));
        return false;
    }
    array_add(*r.pass.dead_insts, ii);
    other_ptr := ifx is_dest then op(ii, 1) else op(ii, 0);
    base := sv_strip_in_bounds_offsets(other_ptr);
    if is_inst(base) && inst_op(base) == .ALLOCA svec_insert(*r.pass.worklist, base);
    other_ptr_ty := vtype(other_ptr);
    other_as := ptr_as(other_ptr);
    ow := dl_index_size_bits(other_as);
    other_offset := (r.nbegin - r.begin) & sv_mask(ow);
    other_align := call_param_align(ii, ifx is_dest then cast(u32) 1 else 0);
    if other_align == 0 other_align = 1;
    other_align = common_alignment(other_align, other_offset);
    if emit_memcpy {
        other_ptr = get_adjusted_ptr(*r.irb, other_ptr, other_offset, ow, other_ptr_ty, tprint("%.", vname(other_ptr)));
        our := rw_new_alloca_slice_ptr(r, *r.irb, vtype(r.old_ptr));
        size := const_int(vtype(mem_length(ii)), r.nend - r.nbegin);
        dst, src: Value_Id; da, sa: u64;
        if is_dest { dst = our; da = slice_align; src = other_ptr; sa = other_align; }
        else { dst = other_ptr; da = other_align; src = our; sa = slice_align; }
        nw := irb_memcpy(*r.irb, dst, da, src, sa, size, volatile);
        if aa_any(tags) set_aa_metadata(nw, aa_shift(tags, r.nbegin - r.begin));
        return false;
    }
    whole := r.nbegin == r.na_begin && r.nend == r.na_end;
    size := r.nend - r.nbegin;
    bi: u64 = ifx r.vec_ty != NONE then rw_index(r, r.nbegin) else 0;
    ei: u64 = ifx r.vec_ty != NONE then rw_index(r, r.nend) else 0;
    n := ei - bi;
    sub_int_ty: Type_Id = ifx r.int_ty != NONE then type_int(size * 8) else NONE;
    other_ty: Type_Id;
    if r.vec_ty != NONE && !whole other_ty = ifx n == 1 then type_elem(r.vec_ty) else fixed_vec(type_elem(r.vec_ty), n);
    else if r.int_ty != NONE && !whole other_ty = sub_int_ty;
    else other_ty = r.na_ty;
    adj := get_adjusted_ptr(*r.irb, other_ptr, other_offset, ow, other_ptr_ty, tprint("%.", vname(other_ptr)));
    src_align := other_align; dst_align := slice_align;
    if !is_dest { t := src_align; src_align = dst_align; dst_align = t; }
    src_ptr, dst_ptr: Value_Id;
    if is_dest { dst_ptr = rw_ptr_to_new_ai(r, ptr_as(op(ii, 0)), volatile); src_ptr = adj; }
    else { dst_ptr = adj; src_ptr = rw_ptr_to_new_ai(r, ptr_as(op(ii, 1)), volatile); }
    src: Value_Id;
    if r.vec_ty != NONE && !whole && !is_dest {
        src = irb_load(*r.irb, r.na_ty, r.new_ai, inst(r.new_ai).align, false, "load");
        src = extract_vector(*r.irb, src, bi, ei, "vec");
    } else if r.int_ty != NONE && !whole && !is_dest {
        src = irb_load(*r.irb, r.na_ty, r.new_ai, inst(r.new_ai).align, false, "load");
        src = irb_bit_preserving_cast_chain(*r.irb, src, r.int_ty);
        src = extract_integer(*r.irb, src, sub_int_ty, r.nbegin - r.na_begin, "extract");
    } else {
        ld := irb_load(*r.irb, other_ty, src_ptr, src_align, volatile, "copyload");
        copy_loop_metadata(ld, ii);
        if aa_any(tags) set_aa_metadata(ld, aa_adjust_for_access_ty(tags, r.nbegin - r.begin, vtype(ld)));
        src = ld;
    }
    if r.vec_ty != NONE && !whole && is_dest {
        old := irb_load(*r.irb, r.na_ty, r.new_ai, inst(r.new_ai).align, false, "oldload");
        src = insert_vector(*r.irb, old, src, bi, "vec");
    } else if r.int_ty != NONE && !whole && is_dest {
        old := irb_load(*r.irb, r.na_ty, r.new_ai, inst(r.new_ai).align, false, "oldload");
        old = irb_bit_preserving_cast_chain(*r.irb, old, r.int_ty);
        src = insert_integer(*r.irb, old, src, r.nbegin - r.na_begin, "insert");
        src = irb_bit_preserving_cast_chain(*r.irb, src, r.na_ty);
    }
    st := irb_store(*r.irb, src, dst_ptr, dst_align, volatile);
    copy_loop_metadata(st, ii);
    if aa_any(tags) set_aa_metadata(st, aa_adjust_for_access_ty(tags, r.nbegin - r.begin, vtype(src)));
    return !volatile;
}

rw_visit_intrinsic :: (r: *Sroa_Rewriter, ii: Value_Id) -> bool {
    array_add(*r.pass.dead_insts, ii);
    if is_droppable_user(ii) {
        // Value::dropDroppableUsesIn
        n := nops(ii);
        if n > 0 for k: 0..n-1 if op(ii, k) == r.old_ptr drop_droppable_use(op_use(ii, k));
        return true;
    }
    pty := type_ptr(ptr_as(r.old_ptr));
    p := rw_new_alloca_slice_ptr(r, *r.irb, pty);
    id := call_intrinsic(ii);
    irb_intrinsic(*r.irb, id, .[vtype(p)], .[p]);
    return true;
}

// fixLoadStoreAlign
rw_fix_load_store_align :: (r: *Sroa_Rewriter, root: Value_Id) {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    wl: [..] Value_Id; wl.allocator = temp;
    table_set(*visited, root, true);
    array_add(*wl, root);
    while wl.count {
        i := pop(*wl);
        o := inst_op(i);
        if o == .LOAD || o == .STORE { inst(i).align = min(inst(i).align, rw_slice_align(r)); continue; }
        u := ir.v_first_use[i];
        while u != NONE {
            usr := ir.u_user[u];
            if !table_contains(*visited, usr) { table_set(*visited, usr, true); array_add(*wl, usr); }
            u = ir.u_next[u];
        }
    }
}

rw_visit_phi :: (r: *Sroa_Rewriter, pn: Value_Id) -> bool {
    saved := r.irb;
    if inst_op(r.old_ptr) == .PHI {
        bb := inst(r.old_ptr).parent;
        irb_set_at(*r.irb, bb, block_first_insertion_pt(bb), true);
    } else irb_set_before(*r.irb, r.old_ptr);
    r.irb.dbg = get_metadata(r.old_ptr, 0);
    new_ptr := rw_new_alloca_slice_ptr(r, *r.irb, vtype(r.old_ptr));
    n := nops(pn);
    if n > 0 for k: 0..n-1 if op(pn, k) == r.old_ptr set_op(pn, k, new_ptr);
    r.irb = saved;
    rw_delete_if_trivially_dead(r, r.old_ptr);
    rw_fix_load_store_align(r, pn);
    svec_insert(r.phi_users, pn);
    return true;
}

rw_visit_select :: (r: *Sroa_Rewriter, si: Value_Id) -> bool {
    new_ptr := rw_new_alloca_slice_ptr(r, *r.irb, vtype(r.old_ptr));
    if op(si, 1) == r.old_ptr set_op(si, 1, new_ptr);
    if op(si, 2) == r.old_ptr set_op(si, 2, new_ptr);
    rw_delete_if_trivially_dead(r, r.old_ptr);
    rw_fix_load_store_align(r, si);
    svec_insert(r.select_users, si);
    return true;
}

comes_before_in_block :: (a: Value_Id, b: Value_Id) -> bool {
    x := inst(a).next;
    while x != NONE { if x == b return true; x = inst(x).next; }
    return false;
}

// rewriteTreeStructuredMerge; returns false for std::nullopt
rw_tree_structured_merge :: (r: *Sroa_Rewriter, P: *Sroa_Part, deleted: *[..] Value_Id) -> bool {
    if P.tails.count > 0 return false;
    Store_Info :: struct { st: Value_Id; b: u64; e: u64; v: Value_Id; }
    Load_Info :: struct { ld: Value_Id; b: u64; e: u64; }
    stores: [..] Store_Info; stores.allocator = temp;
    loads: [..] Load_Info; loads.allocator = temp;
    full_load: Value_Id = NONE;
    init_store: Value_Id = NONE;
    alloc_elt := ifx type_kind(r.na_ty) == .VECTOR then type_elem(r.na_ty) else ir.t_i8;
    alloc_elt_size := dl_type_size_bits(alloc_elt);
    valid_ty :: (t: Type_Id) -> bool {
        return type_kind(t) == .VECTOR && dl_type_size_bits(type_elem(t)) % 8 == 0 && !is_ptr_type(type_elem(t));
    }
    if P.sj > P.si for x: P.si..P.sj-1 {
        s := r.S[x];
        user := use_user(s.use);
        full := s.begin == r.na_begin && s.end == r.na_end;
        if inst_op(user) == .LOAD {
            if !inst_is_simple(user) || !valid_ty(vtype(user)) return false;
            if full { if full_load != NONE return false; full_load = user; }
            else array_add(*loads, .{user, s.begin, s.end});
        } else if inst_op(user) == .STORE {
            vt := vtype(op(user, 0));
            if !inst_is_simple(user) || !valid_ty(vt) return false;
            if (type_count(vt) * dl_type_size_bits(type_elem(vt))) % alloc_elt_size != 0 return false;
            if full { if init_store != NONE return false; init_store = user; }
            else array_add(*stores, .{user, s.begin, s.end, op(user, 0)});
        } else return false;
    }
    if stores.count < 2 return false;
    is_rmw := init_store != NONE && r.vec_ty != NONE && loads.count > 0;
    is_stores_only := init_store == NONE && full_load != NONE && loads.count == 0;
    if !is_rmw && !is_stores_only return false;
    store_bb := inst(stores[0].st).parent;
    for stores if inst(it.st).parent != store_bb return false;

    tree_merge :: (b: *Irb, vals: *[..] Value_Id, elt: Type_Id) -> Value_Id {
        while vals.count > 1 {
            nxt: [..] Value_Id; nxt.allocator = temp;
            i := 0;
            while i + 1 < vals.count { array_add(*nxt, merge_two_vectors(b, vals.*[i], vals.*[i + 1], elt)); i += 2; }
            if vals.count % 2 == 1 array_add(*nxt, vals.*[vals.count - 1]);
            vals.* = nxt;
        }
        return vals.*[0];
    }
    replace_full_load :: (r: *Sroa_Rewriter, ld: Value_Id, merged: Value_Id, deleted: *[..] Value_Id) {
        b: Irb;
        irb_set_before(*b, ld);
        nl := irb_load(*b, vtype(merged), r.new_ai, rw_slice_align(r), (inst(ld).flags & F_VOLATILE) != 0, tprint("%.sroa.new.load", vname(ld)));
        if vtype(nl) != vtype(ld) nl = irb_bitcast(*b, nl, vtype(ld));
        rauw_with_metadata(ld, nl);
        array_add(deleted, ld);
    }

    if is_stores_only {
        // llvm::sort by begin offset
        for i: 1..stores.count-1 {
            x := stores[i]; j := i - 1;
            while j >= 0 && stores[j].b > x.b { stores[j + 1] = stores[j]; j -= 1; }
            stores[j + 1] = x;
        }
        expected := r.na_begin;
        for stores { if it.b != expected return false; expected = it.e; }
        if expected != r.na_end return false;
        load_bb := inst(full_load).parent;
        if load_bb == store_bb for stores if !comes_before_in_block(it.st, full_load) return false;
        b: Irb;
        irb_set_before(*b, ifx load_bb == store_bb then full_load else block_terminator(store_bb));
        vals: [..] Value_Id; vals.allocator = temp;
        for stores { array_add(deleted, it.st); array_add(*vals, it.v); }
        merged := tree_merge(*b, *vals, alloc_elt);
        irb_store(*b, merged, r.new_ai, rw_slice_align(r));
        replace_full_load(r, full_load, merged, deleted);
        return true;
    }

    if inst(init_store).parent != store_bb return false;
    for loads if inst(it.ld).parent != store_bb return false;
    Access :: struct { i: Value_Id; b: u64; e: u64; is_store: bool; }
    acc: [..] Access; acc.allocator = temp;
    for loads array_add(*acc, .{it.ld, it.b, it.e, false});
    for stores array_add(*acc, .{it.st, it.b, it.e, true});
    for i: 1..acc.count-1 {
        x := acc[i]; j := i - 1;
        while j >= 0 && comes_before_in_block(x.i, acc[j].i) { acc[j + 1] = acc[j]; j -= 1; }
        acc[j + 1] = x;
    }
    if !comes_before_in_block(init_store, acc[0].i) return false;
    if full_load != NONE && inst(full_load).parent == store_bb && !comes_before_in_block(acc[acc.count - 1].i, full_load) return false;
    Range :: struct { b: u64; e: u64; }
    ranges: [..] Range; ranges.allocator = temp;
    for acc array_add(*ranges, .{it.b, it.e});
    for i: 1..ranges.count-1 {
        x := ranges[i]; j := i - 1;
        while j >= 0 && (ranges[j].b > x.b || (ranges[j].b == x.b && ranges[j].e > x.e)) { ranges[j + 1] = ranges[j]; j -= 1; }
        ranges[j + 1] = x;
    }
    k := 0;
    for ranges { if k == 0 || ranges[k - 1].b != it.b || ranges[k - 1].e != it.e { ranges[k] = it; k += 1; } }
    ranges.count = k;
    expected := r.na_begin;
    for ranges { if it.b != expected return false; expected = it.e; }
    if expected != r.na_end return false;

    irb_set_before(*r.irb, inst(init_store).next);
    init_vec := op(init_store, 0);
    if vtype(init_vec) != r.na_ty init_vec = irb_bitcast(*r.irb, init_vec, r.na_ty, "init.cast");
    vals_of: [..] Value_Id; vals_of.allocator = temp;
    for ranges {
        bi := rw_index(r, it.b); ei := rw_index(r, it.e);
        array_add(*vals_of, irb_shuffle(*r.irb, init_vec, NONE, seq_mask(bi, ei - bi), "init.extract"));
    }
    array_add(deleted, init_store);
    range_index :: (ranges: [] Range, b: u64, e: u64) -> s64 { for ranges if it.b == b && it.e == e return it_index; return -1; }
    for a: acc {
        ri := range_index(ranges, a.b, a.e);
        if !a.is_store {
            v := vals_of[ri];
            if vtype(v) != vtype(a.i) {
                irb_set_before(*r.irb, a.i);
                v = irb_bitcast(*r.irb, v, vtype(a.i));
            }
            rauw_with_metadata(a.i, v);
        } else {
            vals_of[ri] = op(a.i, 0);
        }
        array_add(deleted, a.i);
    }
    b: Irb;
    irb_set_before(*b, ifx full_load != NONE && inst(full_load).parent == store_bb then full_load else block_terminator(store_bb));
    vals: [..] Value_Id; vals.allocator = temp;
    for vals_of array_add(*vals, it);
    merged := tree_merge(*b, *vals, alloc_elt);
    irb_store(*b, merged, r.new_ai, rw_slice_align(r));
    if full_load != NONE replace_full_load(r, full_load, merged, deleted);
    return true;
}

// ---------------------------------------------------------------- AggLoadStoreRewriter

Agg_Rw :: struct {
    queue: [..] Use_Id;
    visited: Table(Value_Id, bool);
    u: Use_Id;
    irb: *Irb;
}

agg_enqueue_users :: (a: *Agg_Rw, i: Value_Id) {
    u := ir.v_first_use[i];
    while u != NONE {
        usr := ir.u_user[u];
        if !table_contains(*a.visited, usr) { table_set(*a.visited, usr, true); array_add(*a.queue, u); }
        u = ir.u_next[u];
    }
}

Op_Splitter :: struct {
    irb: *Irb;
    indices: [..] u32;
    gep_indices: [..] Value_Id;
    ptr: Value_Id;
    base_ty: Type_Id;
    base_align: u64;
    is_store: bool;
    tags: AA_Tags;
    agg_store: Value_Id;
    components: [..] Value_Id;
}

splitter_init :: (s: *Op_Splitter, b: *Irb, at: Value_Id, ptr: Value_Id, base_ty: Type_Id, base_align: u64) {
    s.irb = b;
    s.indices.allocator = temp; s.gep_indices.allocator = temp;
    array_add(*s.gep_indices, const_int(ir.t_i32, 0));
    s.ptr = ptr; s.base_ty = base_ty; s.base_align = base_align;
    irb_set_before(b, at);
}

// OpSplitter::emitSplitOps
emit_split_ops :: (s: *Op_Splitter, ty: Type_Id, agg: *Value_Id, name: string) {
    if is_single_value_type(ty) {
        off := cast(u64) sv_indexed_offset_in_type(s.base_ty, s.gep_indices);
        al := common_alignment(s.base_align, off);
        if s.is_store {
            ev := irb_extract_value(s.irb, agg.*, s.indices, tprint("%.extract", name));
            gep := irb_gep(s.irb, s.base_ty, s.ptr, s.gep_indices, tprint("%.gep", name), F_INBOUNDS);
            st := irb_store(s.irb, ev, gep, al);
            if aa_any(s.tags) set_aa_metadata(st, aa_adjust_for_access_ty(s.tags, off, vtype(ev)));
        } else {
            gep := irb_gep(s.irb, s.base_ty, s.ptr, s.gep_indices, tprint("%.gep", name), F_INBOUNDS);
            ld := irb_load(s.irb, ty, gep, al, false, tprint("%.load", name));
            if aa_any(s.tags) set_aa_metadata(ld, aa_adjust_for_access_ty(s.tags, off, vtype(ld)));
            array_add(*s.components, ld);
            agg.* = irb_insert_value(s.irb, agg.*, ld, s.indices, tprint("%.insert", name));
        }
        return;
    }
    k := type_kind(ty);
    n: u64;
    if k == .ARRAY n = type_count(ty);
    else if k == .STRUCT n = type_nsub(ty);
    else fatal("internal: Only arrays and structs are aggregate loadable types");
    if n > 0 for idx: 0..cast(s64) n - 1 {
        array_add(*s.indices, cast(u32) idx);
        array_add(*s.gep_indices, const_int(ir.t_i32, cast(u64) idx));
        et := ifx k == .ARRAY then type_elem(ty) else type_sub(ty, cast(u32) idx);
        emit_split_ops(s, et, agg, tprint("%.%", name, idx));
        s.gep_indices.count -= 1;
        s.indices.count -= 1;
    }
}

agg_visit_load :: (a: *Agg_Rw, li: Value_Id) -> bool {
    if !inst_is_simple(li) || is_single_value_type(vtype(li)) return false;
    s: Op_Splitter;
    splitter_init(*s, a.irb, li, use_value(a.u), vtype(li), common_alignment(load_store_align(li), 0));
    s.tags = get_aa_metadata(li);
    s.components.allocator = temp;
    // recordFakeUses
    fake: [..] Value_Id; fake.allocator = temp;
    u := ir.v_first_use[li];
    while u != NONE { if call_intrinsic(ir.u_user[u]) == "llvm.fake.use" array_add(*fake, ir.u_user[u]); u = ir.u_next[u]; }
    v := const_poison(vtype(li));
    emit_split_ops(*s, vtype(li), *v, tprint("%.fca", vname(li)));
    // emitFakeUses
    for fu: fake {
        irb_set_before(a.irb, fu);
        for c: s.components irb_intrinsic(a.irb, "llvm.fake.use", .[], .[c]);
        erase_inst_with_metadata(fu);
    }
    table_remove(*a.visited, li);
    rauw_with_metadata(li, v);
    erase_inst_with_metadata(li);
    return true;
}

agg_visit_store :: (a: *Agg_Rw, si: Value_Id) -> bool {
    if !inst_is_simple(si) || op(si, 1) != use_value(a.u) return false;
    v := op(si, 0);
    if is_single_value_type(vtype(v)) return false;
    s: Op_Splitter;
    splitter_init(*s, a.irb, si, use_value(a.u), vtype(v), common_alignment(load_store_align(si), 0));
    s.is_store = true;
    s.tags = get_aa_metadata(si);
    s.agg_store = si;
    vv := v;
    emit_split_ops(*s, vtype(v), *vv, tprint("%.fca", vname(v)));
    table_remove(*a.visited, si);
    erase_inst_with_metadata(si);
    return true;
}

gep_set_flags_copy :: (dst: Value_Id, src: Value_Id) { inst(dst).flags = inst(src).flags; }

// unfoldGEPSelect
agg_unfold_gep_select :: (a: *Agg_Rw, g: Value_Id) -> bool {
    sel: Value_Id = NONE;
    p := op(g, 0);
    if is_inst(p) && inst_op(p) == .SELECT sel = p;
    n := nops(g);
    if n > 1 for k: 1..n-1 {
        x := op(g, k);
        if is_inst(x) && inst_op(x) == .SELECT {
            if sel != NONE return false;
            sel = x;
            if vkind(op(x, 1)) != .C_INT || vkind(op(x, 2)) != .C_INT return false;
            continue;
        }
        if is_inst(x) && inst_op(x) == .ZEXT {
            if sel != NONE return false;
            sel = x;
            if vtype(op(x, 0)) != ir.t_i1 return false;
            continue;
        }
        if vkind(x) != .C_INT return false;
    }
    if sel == NONE return false;
    cond, tv, fv: Value_Id;
    md_from: Value_Id = NONE;
    if inst_op(sel) == .SELECT { cond = op(sel, 0); tv = op(sel, 1); fv = op(sel, 2); md_from = sel; }
    else { cond = op(sel, 0); tv = const_int(vtype(sel), 1); fv = const_int(vtype(sel), 0); }
    new_ops :: (g: Value_Id, sel: Value_Id, x: Value_Id) -> [..] Value_Id {
        r: [..] Value_Id; r.allocator = temp;
        n := nops(g);
        for k: 0..n-1 { o := op(g, k); array_add(*r, ifx o == sel then x else o); }
        return r;
    }
    tops := new_ops(g, sel, tv);
    fops := new_ops(g, sel, fv);
    irb_set_before(a.irb, g);
    nw := inst(g).flags;
    ty := inst(g).ty2;
    tidx: [] Value_Id; tidx.data = tops.data + 1; tidx.count = tops.count - 1;
    fidx: [] Value_Id; fidx.data = fops.data + 1; fidx.count = fops.count - 1;
    nt := irb_gep(a.irb, ty, tops[0], tidx, tprint("%.sroa.gep", vname(tv)), nw);
    nf := irb_gep(a.irb, ty, fops[0], fidx, tprint("%.sroa.gep", vname(fv)), nw);
    nsel: Value_Id;
    if md_from != NONE nsel = irb_select(a.irb, cond, nt, nf, tprint("%.sroa.sel", vname(sel)), md_from);
    else {
        // CreateSelectWithUnknownProfile(Cond, T, F, DEBUG_TYPE, Name)
        nsel = irb_select(a.irb, cond, nt, nf, tprint("%.sroa.sel", vname(sel)));
        if is_inst(nsel) && inst_op(nsel) == .SELECT {
            ec_ok, ec := function_entry_count(block_fn(inst(nsel).parent));
            if ec_ok && ec > 0 set_metadata(nsel, md_kind_id("prof"), md_tuple(.[md_string("unknown"), md_string("sroa")], false));
        }
    }
    table_remove(*a.visited, g);
    rauw_with_metadata(g, nsel);
    erase_inst_with_metadata(g);
    if is_inst(nsel) { table_set(*a.visited, nsel, true); agg_enqueue_users(a, nsel); }
    return true;
}

// unfoldGEPPhi
agg_unfold_gep_phi :: (a: *Agg_Rw, g: Value_Id) -> bool {
    phi: Value_Id = NONE;
    p := op(g, 0);
    if is_inst(p) && inst_op(p) == .PHI phi = p;
    invalid_ptr :: (v: Value_Id) -> bool {
        if !is_inst(v) return false;
        if inst_op(v) == .ALLOCA return !alloca_is_static(v);
        return true;
    }
    if phi != NONE {
        n := nops(phi);
        if n > 0 for k: 0..n-1 if invalid_ptr(op(phi, k)) return false;
    } else if invalid_ptr(p) return false;
    n := nops(g);
    if n > 1 for k: 1..n-1 {
        x := op(g, k);
        if is_inst(x) && inst_op(x) == .PHI {
            if phi != NONE return false;
            phi = x;
            m := nops(phi);
            if m > 0 for j: 0..m-1 if vkind(op(phi, j)) != .C_INT return false;
            continue;
        }
        if vkind(x) != .C_INT return false;
    }
    if phi == NONE return false;
    irb_set_before(a.irb, phi);
    a.irb.head = true;   // phi insertion
    new_phi := irb_phi(a.irb, vtype(g), nops(phi), tprint("%.sroa.phi", vname(phi)));
    src_ty := inst(g).ty2;
    entry := fn_entry(block_fn(inst(g).parent));
    irb_set_before(a.irb, block_terminator(entry));
    m := nops(phi);
    if m > 0 for j: 0..m-1 {
        o := op(phi, j);
        bb := phi_block(phi, j);
        ni := phi_block_index(new_phi, bb);
        ng: Value_Id;
        if ni >= 0 ng = op(new_phi, cast(u32) ni);
        else {
            ops: [..] Value_Id; ops.allocator = temp;
            for k: 0..n-1 { x := op(g, k); array_add(*ops, ifx x == phi then o else x); }
            idx: [] Value_Id; idx.data = ops.data + 1; idx.count = ops.count - 1;
            ng = irb_gep(a.irb, src_ty, ops[0], idx, tprint("%.sroa.gep", vname(phi)), inst(g).flags);
        }
        phi_add_incoming(new_phi, ng, bb);
    }
    table_remove(*a.visited, g);
    rauw_with_metadata(g, new_phi);
    erase_inst_with_metadata(g);
    table_set(*a.visited, new_phi, true);
    agg_enqueue_users(a, new_phi);
    return true;
}

agg_visit :: (a: *Agg_Rw, i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .LOAD return agg_visit_load(a, i);
    if o == .STORE return agg_visit_store(a, i);
    if o == .BITCAST || o == .ADDRSPACECAST || o == .PHI || o == .SELECT { agg_enqueue_users(a, i); return false; }
    if o == .GEP {
        if agg_unfold_gep_select(a, i) return true;
        if agg_unfold_gep_phi(a, i) return true;
        agg_enqueue_users(a, i);
        return false;
    }
    return false;
}

agg_rewrite :: (b: *Irb, i: Value_Id) -> bool {
    a: Agg_Rw;
    a.queue.allocator = temp; a.visited.allocator = temp;
    a.irb = b;
    agg_enqueue_users(*a, i);
    changed := false;
    while a.queue.count {
        a.u = pop(*a.queue);
        if agg_visit(*a, use_user(a.u)) changed = true;
    }
    return changed;
}

// ---------------------------------------------------------------- partition types

// StructLayout::getElementContainingOffset
struct_element_containing :: (t: Type_Id, off: u64) -> u32 {
    n := type_nsub(t);
    idx: u32 = 0;
    for k: 0..n-1 { if dl_struct_offset(t, k) <= off idx = k; else break; }
    // upper_bound - 1 over the offsets (several zero-size fields can share an offset: the last one wins)
    return idx;
}

// stripAggregateTypeWrapping
strip_aggregate_type_wrapping :: (ty: Type_Id) -> Type_Id {
    if is_single_value_type(ty) return ty;
    alloc := dl_type_alloc_size(ty);
    tsize := dl_type_size_bits(ty);
    inner: Type_Id;
    if type_kind(ty) == .ARRAY inner = type_elem(ty);
    else if type_kind(ty) == .STRUCT {
        if type_nsub(ty) == 0 return ty;
        inner = type_sub(ty, struct_element_containing(ty, 0));
    } else return ty;
    if alloc > dl_type_alloc_size(inner) || tsize > dl_type_size_bits(inner) return ty;
    return strip_aggregate_type_wrapping(inner);
}

// getTypePartition
get_type_partition :: (ty: Type_Id, off_in: u64, size: u64) -> Type_Id {
    off := off_in;
    asz := dl_type_alloc_size(ty);
    if off == 0 && asz == size return strip_aggregate_type_wrapping(ty);
    if off > asz || (asz - off) < size return NONE;
    k := type_kind(ty);
    if k == .ARRAY || k == .VECTOR || k == .SVECTOR {
        if k == .SVECTOR fatal("SROA: scalable vector partitions are not supported yet");
        et := type_elem(ty);
        n := type_count(ty);
        es := dl_type_alloc_size(et);
        skip := off / es;
        if skip >= n return NONE;
        off -= skip * es;
        if off > 0 || size < es {
            if off + size > es return NONE;
            return get_type_partition(et, off, size);
        }
        if size == es return strip_aggregate_type_wrapping(et);
        ne := size / es;
        if ne * es != size return NONE;
        return type_array(ne, et);
    }
    if k != .STRUCT return NONE;
    ssize, sal := dl_struct_layout(ty);
    if off >= ssize return NONE;
    end := off + size;
    if end > ssize return NONE;
    idx := struct_element_containing(ty, off);
    off -= dl_struct_offset(ty, idx);
    et := type_sub(ty, idx);
    es := dl_type_alloc_size(et);
    if off >= es return NONE;
    if off > 0 || size < es {
        if off + size > es return NONE;
        return get_type_partition(et, off, size);
    }
    if size == es return strip_aggregate_type_wrapping(et);
    ee := type_nsub(ty);
    if end < ssize {
        eidx := struct_element_containing(ty, end);
        if idx == eidx return NONE;
        if dl_struct_offset(ty, eidx) != end return NONE;
        ee = eidx;
    }
    elts: [..] Type_Id; elts.allocator = temp;
    for k2: idx..ee-1 array_add(*elts, type_sub(ty, k2));
    sub := type_literal_struct(elts, (ir.types[ty].flags & TYF_PACKED) != 0);
    sub_size, sub_al := dl_struct_layout(sub);
    if size != sub_size return NONE;
    return sub;
}

// tryCanonicalizeStructToVector
try_struct_to_vector :: (sty: Type_Id, P: *Sroa_Part, S: [] Sroa_Slice) -> Type_Id {
    n := type_nsub(sty);
    if n == 0 return NONE;
    et := type_sub(sty, 0);
    for k: 1..n-1 if type_sub(sty, k) != et return NONE;
    integral_ptr := is_ptr_type(et) && !dl_ni_ptr_type(et);
    if !is_int_type(et) && !is_fp_type(et) && !integral_ptr return NONE;
    if dl_type_size_bits(et) != dl_type_alloc_size(et) * 8 return NONE;
    vty := fixed_vec(et, n);
    ssize, sal := dl_struct_layout(sty);
    if ssize != dl_type_store_size(vty) return NONE;
    ok :: (s: Sroa_Slice) -> bool {
        if s.use == NONE return true;
        usr := use_user(s.use);
        if is_lifetime_start_or_end(usr) return true;
        return is_mem_intrinsic(usr);
    }
    if P.sj > P.si for x: P.si..P.sj-1 if !ok(S[x]) return NONE;
    for P.tails if !ok(S[it]) return NONE;
    return vty;
}

// selectPartitionType: (type, integer widening, vector type)
select_partition_type :: (P: *Sroa_Part, S: [] Sroa_Slice, ai: Value_Id, agg_to_vec: bool) -> (Type_Id, bool, Type_Id) {
    psize := P.end - P.begin;
    vty := is_vector_promotion_viable(P, S);
    if vty != NONE && is_fp_type(type_elem(vty)) && type_count(vty) > 1 return vty, false, vty;
    common, largest := find_common_type(S, P.si, P.sj, P.end);
    if common != NONE {
        if !type_has_scalable(common) && dl_type_alloc_size(common) >= psize {
            if vty != NONE return vty, false, vty;
            return common, is_integer_widening_viable(P, S, common), NONE;
        }
    }
    tp := get_type_partition(inst(ai).ty2, P.begin, psize);
    if tp != NONE {
        if type_kind(tp) == .ARRAY && is_int_type(type_elem(tp)) && dl_is_legal_integer(psize * 8) tp = type_int(psize * 8);
        if is_integer_widening_viable(P, S, tp) return tp, true, NONE;
        if vty != NONE return vty, false, vty;
        if largest != NONE && dl_type_alloc_size(largest) >= psize && is_integer_widening_viable(P, S, largest) return largest, true, NONE;
        if agg_to_vec && type_kind(tp) == .STRUCT {
            v := try_struct_to_vector(tp, P, S);
            if v != NONE return v, false, NONE;
        }
        return tp, false, NONE;
    }
    if largest != NONE && dl_type_alloc_size(largest) >= psize return largest, false, NONE;
    if dl_is_legal_integer(psize * 8) return type_int(psize * 8), false, NONE;
    return type_array(psize, ir.t_i8), false, NONE;
}

// ---------------------------------------------------------------- presplitLoadsAndStores

Split_Offsets :: struct { s: s64; splits: [..] u64; }

presplit_loads_and_stores :: (pass: *Sroa, ai: Value_Id, as: *Sroa_Slices) -> bool {
    S := *as.slices;
    loads: [..] Value_Id; loads.allocator = temp;
    stores: [..] Value_Id; stores.allocator = temp;
    offsets: Table(Value_Id, Split_Offsets); offsets.allocator = temp;
    unsplittable: Table(Value_Id, bool); unsplittable.allocator = temp;
    it: Sroa_Part_It;
    part_it_init(*it, S);
    while !part_it_at_end(*it) {
        P := *it.p;
        if P.sj > P.si for x: P.si..P.sj-1 {
            s := S.*[x];
            i := use_user(s.use);
            if !s.splittable || s.end <= P.end {
                if inst_op(i) == .LOAD table_set(*unsplittable, i, true);
                else if inst_op(i) == .STORE {
                    v := op(i, 0);
                    if is_inst(v) && inst_op(v) == .LOAD table_set(*unsplittable, v, true);
                }
                continue;
            }
            if inst_op(i) == .LOAD {
                simply_stored := true;
                u := ir.v_first_use[i];
                while u != NONE {
                    lu := ir.u_user[u];
                    if inst_op(lu) != .STORE || !inst_is_simple(lu) { simply_stored = false; break; }
                    u = ir.u_next[u];
                }
                if !simply_stored { table_set(*unsplittable, i, true); continue; }
                array_add(*loads, i);
            } else if inst_op(i) == .STORE {
                if s.use != op_use(i, 1) continue;
                sl := op(i, 0);
                if !(is_inst(sl) && inst_op(sl) == .LOAD) || !inst_is_simple(sl) continue;
                array_add(*stores, i);
            } else continue;
            so: Split_Offsets;
            so.s = x;
            so.splits.allocator = temp;
            array_add(*so.splits, P.end - s.begin);
            table_set(*offsets, i, so);
        }
        for t: P.tails {
            usr := use_user(S.*[t].use);
            so := table_find_pointer(*offsets, usr);
            if !so continue;
            if S.*[t].end > P.end array_add(*so.splits, P.end - S.*[so.s].begin);
        }
        part_it_advance(*it);
    }
    // erase_if over Stores (mismatched splits)
    {
        k := 0;
        for si: stores {
            li := op(si, 0);
            drop_it := false;
            if table_contains(*unsplittable, li) drop_it = true;
            else {
                lo := table_find_pointer(*offsets, li);
                if lo {
                    so := table_find_pointer(*offsets, si);
                    same := lo.splits.count == so.splits.count;
                    if same for lo.splits if it != so.splits[it_index] { same = false; break; }
                    if !same { table_set(*unsplittable, li, true); drop_it = true; }
                }
            }
            if !drop_it { stores[k] = si; k += 1; }
        }
        stores.count = k;
        k = 0;
        for si: stores if !table_contains(*unsplittable, op(si, 0)) { stores[k] = si; k += 1; }
        stores.count = k;
        k = 0;
        for li: loads if !table_contains(*unsplittable, li) { loads[k] = li; k += 1; }
        loads.count = k;
    }
    if loads.count == 0 && stores.count == 0 return false;
    b: Irb;
    irb_set_before(*b, ai);
    new_slices: [..] Sroa_Slice; new_slices.allocator = temp;
    resplit: Table(Value_Id, bool); resplit.allocator = temp;
    split_loads_map: Table(Value_Id, [..] Value_Id); split_loads_map.allocator = temp;
    for li: loads {
        split_loads: [..] Value_Id; split_loads.allocator = temp;
        so := table_find_pointer(*offsets, li);
        slice_size := S.*[so.s].end - S.*[so.s].begin;
        base_off := S.*[so.s].begin;
        base_ptr := op(li, 0);
        irb_set_before(*b, li);
        part_off: u64 = 0;
        part_size := so.splits[0];
        idx := 0; size := so.splits.count;
        while true {
            pty := type_int(part_size * 8);
            as_ := ptr_as(base_ptr);
            pl := irb_load(*b, pty, get_adjusted_ptr(*b, base_ptr, part_off, dl_index_size_bits(as_), vtype(base_ptr), tprint("%.", vname(base_ptr))),
                           common_alignment(load_store_align(li), part_off), false, vname(li));
            copy_loop_metadata(pl, li);
            array_add(*split_loads, pl);
            array_add(*new_slices, .{base_off + part_off, base_off + part_off + part_size, op_use(pl, 0), false});
            if idx >= size break;
            part_off = so.splits[idx];
            idx += 1;
            part_size = (ifx idx < size then so.splits[idx] else slice_size) - part_off;
        }
        deferred := false;
        u := ir.v_first_use[li];
        while u != NONE {
            si := ir.u_user[u];
            u = ir.u_next[u];
            if stores.count && table_contains(*offsets, si) { deferred = true; continue; }
            sbase := op(si, 1);
            irb_set_before(*b, si);
            tags := get_aa_metadata(si);
            for pl, pi: split_loads {
                po: u64 = ifx pi == 0 then 0 else so.splits[pi - 1];
                as_ := ptr_as(sbase);
                ps := irb_store(*b, pl, get_adjusted_ptr(*b, sbase, po, dl_index_size_bits(as_), vtype(sbase), tprint("%.", vname(sbase))),
                                common_alignment(load_store_align(si), po));
                copy_loop_metadata(ps, si);
                dai := get_metadata(si, md_kind_id("DIAssignID"));
                if dai != NONE set_metadata(ps, md_kind_id("DIAssignID"), dai);
                if aa_any(tags) set_aa_metadata(ps, aa_adjust_for_access_ty(tags, po, vtype(pl)));
            }
            if is_inst(sbase) && inst_op(sbase) == .ALLOCA { table_set(*resplit, sbase, true); svec_insert(*pass.worklist, sbase); }
            else {
                x := sv_strip_in_bounds_offsets(sbase);
                if is_inst(x) && inst_op(x) == .ALLOCA svec_insert(*pass.worklist, x);
            }
            array_add(*pass.dead_insts, si);
        }
        if deferred table_set(*split_loads_map, li, split_loads);
        array_add(*pass.dead_insts, li);
        S.*[so.s].use = NONE;
    }
    for si: stores {
        li := op(si, 0);
        ty := vtype(li);
        store_size := type_int_width(ty) / 8;
        so := table_find_pointer(*offsets, si);
        base_off := S.*[so.s].begin;
        lbase := op(li, 0);
        sbase := op(si, 1);
        found, sl := table_find(*split_loads_map, li);
        part_off: u64 = 0;
        part_size := so.splits[0];
        idx := 0; size := so.splits.count;
        while true {
            pty := type_int(part_size * 8);
            pl: Value_Id;
            if found pl = sl[idx];
            else {
                irb_set_before(*b, li);
                as_ := ptr_as(lbase);
                pl = irb_load(*b, pty, get_adjusted_ptr(*b, lbase, part_off, dl_index_size_bits(as_), vtype(lbase), tprint("%.", vname(lbase))),
                              common_alignment(load_store_align(li), part_off), false, vname(li));
                copy_loop_metadata(pl, li);
            }
            irb_set_before(*b, si);
            as_ := ptr_as(sbase);
            ps := irb_store(*b, pl, get_adjusted_ptr(*b, sbase, part_off, dl_index_size_bits(as_), vtype(sbase), tprint("%.", vname(sbase))),
                            common_alignment(load_store_align(si), part_off));
            copy_loop_metadata(ps, si);
            array_add(*new_slices, .{base_off + part_off, base_off + part_off + part_size, op_use(ps, 1), false});
            if idx >= size break;
            part_off = so.splits[idx];
            idx += 1;
            part_size = (ifx idx < size then so.splits[idx] else store_size) - part_off;
        }
        if !found {
            if is_inst(lbase) && inst_op(lbase) == .ALLOCA { table_set(*resplit, lbase, true); svec_insert(*pass.worklist, lbase); }
            else {
                x := sv_strip_in_bounds_offsets(lbase);
                if is_inst(x) && inst_op(x) == .ALLOCA svec_insert(*pass.worklist, x);
            }
        }
        if num_uses(li) == 1 array_add(*pass.dead_insts, li);
        array_add(*pass.dead_insts, si);
        S.*[so.s].use = NONE;
    }
    k := 0;
    for S.* if it.use != NONE { S.*[k] = it; k += 1; }
    S.count = k;
    old := S.count;
    for new_slices array_add(S, it);
    tail: [] Sroa_Slice; tail.data = S.data + old; tail.count = S.count - old;
    stable_sort_slices(tail);
    stable_sort_slices(S.*);   // inplace_merge of two sorted runs == stable sort of the whole
    for resplit svec_remove(*pass.promotable, it_index);
    return true;
}

// ---------------------------------------------------------------- rewritePartition

rewrite_partition :: (pass: *Sroa, ai: Value_Id, as: *Sroa_Slices, P: *Sroa_Part) -> (Value_Id, u64) {
    S := as.slices;
    pty, int_widen, vty := select_partition_type(P, S, ai, pass.agg_to_vec);
    new_ai: Value_Id;
    if pty == inst(ai).ty2 && P.begin == 0 {
        new_ai = ai;
    } else {
        al := common_alignment(inst(ai).align, P.begin);
        unconstrained := al <= dl_abi_align(pty);
        new_ai = new_inst(.ALLOCA, vtype(ai), 1);
        r := inst(new_ai);
        r.ty2 = pty;
        r.align = ifx unconstrained then dl_pref_align(pty) else al;
        r.addrspace = inst(ai).addrspace;
        set_op(new_ai, 0, const_int(ir.t_i32, 1));
        insert_at_position(new_ai, inst(ai).parent, ai, false);
        set_name(new_ai, tprint("%.sroa.%", vname(ai), P.si));
        dbg := get_metadata(ai, 0);
        if dbg != NONE set_metadata(new_ai, 0, dbg);
    }
    ppw_old := pass.post_promotion.items.count;
    phi_users: Set_Vec; svec_init(*phi_users);
    select_users: Set_Vec; svec_init(*select_users);
    rw: Sroa_Rewriter;
    rw.pass = pass; rw.S = S;
    rw.old_ai = ai; rw.new_ai = new_ai;
    rw.na_begin = P.begin; rw.na_end = P.end; rw.na_ty = pty;
    if int_widen rw.int_ty = type_int(dl_type_size_bits(pty));
    rw.vec_ty = vty;
    if vty != NONE { rw.elt_ty = type_elem(vty); rw.elt_size = dl_type_size_bits(rw.elt_ty) / 8; }
    rw.phi_users = *phi_users; rw.select_users = *select_users;
    promotable := true;
    deleted: [..] Value_Id; deleted.allocator = temp;
    if rw_tree_structured_merge(*rw, P, *deleted) {
        for deleted array_add(*pass.dead_insts, it);
    } else {
        for t: P.tails if !rw_visit(*rw, t, S[t]) promotable = false;
        if P.sj > P.si for x: P.si..P.sj-1 if !rw_visit(*rw, x, S[x]) promotable = false;
    }
    for phi: phi_users.items if !is_safe_phi_to_speculate(phi) {
        promotable = false;
        svec_clear(*phi_users); svec_clear(*select_users);
        break;
    }
    new_selects: [..] Sroa_Select_Rw; new_selects.allocator = temp;
    for sel: select_users.items {
        ops: [..] Sroa_Mem_Op; ops.allocator = temp;
        if !is_safe_select_to_speculate(sel, pass.preserve_cfg, *ops) {
            promotable = false;
            svec_clear(*phi_users); svec_clear(*select_users);
            new_selects.count = 0;
            break;
        }
        array_add(*new_selects, .{sel, ops});
    }
    if promotable {
        for u: as.dead_use_if_promotable {
            old := use_value(u);
            drop_droppable_use(u);
            if is_inst(old) && sroa_trivially_dead(old) array_add(*pass.dead_insts, old);
        }
        if phi_users.items.count == 0 && select_users.items.count == 0 {
            svec_insert(*pass.promotable, new_ai);
        } else {
            for phi_users.items svec_insert(*pass.spec_phis, it);
            for ns: new_selects {
                dup := false;
                for pass.selects if it.sel == ns.sel { dup = true; break; }
                if !dup array_add(*pass.selects, ns);
            }
            svec_insert(*pass.worklist, new_ai);
        }
    } else {
        while pass.post_promotion.items.count > ppw_old svec_pop(*pass.post_promotion);
        if new_ai == ai return NONE, 0;
        svec_insert(*pass.worklist, new_ai);
    }
    return new_ai, dl_type_size_bits(pty);
}

// ---------------------------------------------------------------- debug info migration (splitAlloca)

// DbgVariableRecord::isKillLocation
dbgr_is_kill_location :: (r: u32) -> bool {
    rec := dbgr(r);
    loc := rec.loc;
    if loc == NONE return true;
    if ir.mds[loc].kind != .VALUE && !is_di(loc, .ARG_LIST) return true;   // an MDNode location
    vals: [..] Value_Id; vals.allocator = temp;
    dbgr_values_of_loc(loc, *vals);
    if vals.count == 0 fatal("SROA: debug records without location operands are not supported yet");
    for vals { k := vkind(it); if k == .C_UNDEF || k == .C_POISON return true; }
    return false;
}

// DIExpression::getFragmentInfo: (ok, offset, size)
diexpr_fragment :: (m: Md_Id) -> (bool, u64, u64) {
    e := diexpr_elts(m);
    i := 0;
    while i < e.count {
        if e[i] == DW_OP_LLVM_FRAGMENT_ return true, e[i + 1], e[i + 2];
        i += expr_op_size(e[i]);
    }
    return false, 0, 0;
}

// DIExpression::extractLeadingOffset
diexpr_extract_leading_offset :: (m: Md_Id) -> (ok: bool, offset: s64, rest: [] u64) {
    ok, e := diexpr_single_location_elts(m);
    if !ok return false, 0, .[];
    off: s64 = 0;
    i := 0;
    while i < e.count {
        o := e[i];
        if o == DW_OP_DEREF_ || o == 0x94 || o == 0xa6 || o == DW_OP_LLVM_FRAGMENT_ || o == DW_OP_LLVM_EXTRACT_BITS_ZEXT || o == DW_OP_LLVM_EXTRACT_BITS_SEXT break;
        if o == 0x23 { off += cast,no_check(s64) e[i + 1]; }           // DW_OP_plus_uconst
        else if o == 0x10 {                                            // DW_OP_constu
            v := cast,no_check(s64) e[i + 1];
            i += expr_op_size(o);
            if i < e.count && e[i] == 0x22 off += v;                   // DW_OP_plus
            else if i < e.count && e[i] == 0x1c off -= v;              // DW_OP_minus
            else return false, 0, .[];
        } else return false, 0, .[];
        i += expr_op_size(e[i]);
    }
    r: [] u64; r.data = e.data + i; r.count = e.count - i;
    return true, off, r;
}

// createOrReplaceFragment
create_or_replace_fragment :: (m: Md_Id, foff: u64, fsize: u64, bit_extract_off: s64) -> Md_Id {
    e := diexpr_elts(m);
    ops: [..] u64; ops.allocator = temp;
    has_frag := false; has_extract := false;
    i := 0;
    while i < e.count {
        o := e[i];
        sz := expr_op_size(o);
        if o == DW_OP_LLVM_FRAGMENT_ { has_frag = true; i += sz; continue; }
        if o == DW_OP_LLVM_EXTRACT_BITS_ZEXT || o == DW_OP_LLVM_EXTRACT_BITS_SEXT {
            has_extract = true;
            eo := cast,no_check(s64) e[i + 1];
            es := cast,no_check(s64) e[i + 2];
            if fsize < cast(u64) es return NONE;
            adj := eo + bit_extract_off;
            if adj < 0 return NONE;
            array_add(*ops, o); array_add(*ops, cast(u64) max(0, adj)); array_add(*ops, cast(u64) es);
            i += sz;
            continue;
        }
        for k: 0..sz-1 array_add(*ops, e[i + k]);
        i += sz;
    }
    if has_frag && has_extract return NONE;
    if !has_extract { array_add(*ops, DW_OP_LLVM_FRAGMENT_); array_add(*ops, foff); array_add(*ops, fsize); }
    return di_get(.EXPRESSION, false, .[], ops);
}

Sroa_Fragment :: struct { ai: Value_Id; offset: u64; size: u64; }

// Value::getPointerOffsetFrom (constant-offset case)
pointer_offset_from :: (a: Value_Id, b: Value_Id) -> (bool, s64) {
    w := dl_index_type_size_bits(vtype(a));
    oa: u64 = 0; ob: u64 = 0;
    ba := sv_strip_and_accumulate(a, *oa, w, true);
    bb := sv_strip_and_accumulate(b, *ob, w, true);
    if ba != bb return false, 0;
    d := (oa - ob) & sv_mask(w);
    sd := cast,no_check(s64) d;
    if w < 64 && ((d >> (w - 1)) & 1) sd = cast,no_check(s64)(d | ~sv_mask(w));
    return true, sd;
}

migrate_one :: (pass: *Sroa, ai: Value_Id, r: u32, frags: [] Sroa_Fragment) {
    if dbgr_is_kill_location(r) return;
    rec := dbgr(r);
    dbg_ptr := ir.mds[rec.loc].value;
    has_frag, fo, fs := diexpr_fragment(rec.expr);
    var_off, var_size := fo, fs;
    if !has_frag {
        ok, sz := divar_size_bits(rec.var);
        var_off = 0; var_size = ifx ok then sz else 0;
    }
    ok, cur_off, post_ops := diexpr_extract_leading_offset(rec.expr);
    if !ok return;
    extract_off: s64 = 0;
    {
        e := diexpr_elts(rec.expr);
        i := 0;
        while i < e.count {
            if e[i] == DW_OP_LLVM_EXTRACT_BITS_ZEXT || e[i] == DW_OP_LLVM_EXTRACT_BITS_SEXT { extract_off = cast,no_check(s64) e[i + 1]; break; }
            i += expr_op_size(e[i]);
        }
    }
    post: [..] u64; post.allocator = temp;
    for post_ops array_add(*post, it);
    for fr: frags {
        // DIExpression::calculateFragmentIntersect
        if var_size == 0 continue;
        okp, mem_off := pointer_offset_from(ai, dbg_ptr);
        if !okp continue;
        mem_start := mem_off * 8 + cast,no_check(s64) fr.offset - (cur_off * 8 + extract_off);
        off_from_loc := -mem_start;
        new_has: bool; new_off, new_size: u64;
        mem_end := mem_start + cast(s64) fr.size;
        if mem_end < 0 { new_has = true; new_off = 0; new_size = 0; }
        else {
            mstart := mem_start + cast,no_check(s64) var_off;
            mend := mstart + cast,no_check(s64) fr.size;
            fstart := max(0, mstart);
            fsize := max(0, mend - fstart);
            // FragmentInfo::intersect
            a0 := cast(u64) fstart; a1 := a0 + cast(u64) fsize;
            b0 := var_off; b1 := var_off + var_size;
            s0 := max(a0, b0); s1 := min(a1, b1);
            isz: u64 = ifx s1 > s0 then s1 - s0 else 0;
            ioff: u64 = ifx isz then s0 else 0;
            if isz == var_size && ioff == var_off { new_has = false; }
            else { new_has = true; new_off = ioff; new_size = isz; }
        }
        if new_has && new_size == 0 continue;
        if !new_has { new_has = has_frag; new_off = fo; new_size = fs; }
        off_new := off_from_loc - extract_off;
        bit_extract := min(0, off_new);
        off_new = max(0, off_new);
        new_expr: Md_Id;
        if off_new > 0 {
            ops: [..] u64; ops.allocator = temp;
            array_add(*ops, 0x23); array_add(*ops, cast(u64)((off_new + 7) / 8));
            for post array_add(*ops, it);
            new_expr = di_get(.EXPRESSION, false, .[], ops);
        } else new_expr = di_get(.EXPRESSION, false, .[], post);
        // RemoveOne over findDVRDeclares / findDVRValues of the new alloca
        users: [..] u32; users.allocator = temp;
        find_dbg_users(pass.f, fr.ai, *users);
        for kind: Dbg_Record_Kind.[.DECLARE, .VALUE] for x: users {
            xr := dbgr(x);
            if xr.kind != kind || xr.owner == NONE continue;
            if !(xr.loc != NONE && ir.mds[xr.loc].kind == .VALUE && ir.mds[xr.loc].value == fr.ai) continue;
            if xr.var == rec.var && diloc_inlined_at(xr.dbg) == diloc_inlined_at(rec.dbg) dbgr_erase(x);
        }
        // insertNewDbgInst
        fe := new_expr;
        if new_has fe = create_or_replace_fragment(new_expr, new_off, new_size, bit_extract);
        if fe == NONE continue;
        nr: Dbg_Record;
        nr.kind = rec.kind;
        nr.loc = md_value(fr.ai);
        nr.var = rec.var; nr.expr = fe; nr.dbg = rec.dbg;
        array_add(*ir.dbg_records, nr);
        id := cast(u32) ir.dbg_records.count;
        dbgr_restamp(id);
        attach_records_before(ai, id);
        if dbg_index.fn != NONE dbgr_index_record(id);
    }
}

// ---------------------------------------------------------------- splitAlloca

split_alloca :: (pass: *Sroa, ai: Value_Id, as: *Sroa_Slices) -> bool {
    if as.slices.count == 0 return false;
    changed := presplit_loads_and_stores(pass, ai, as);
    S := *as.slices;
    sorted := true;
    ok, alloca_size := sroa_alloca_allocation_size(ai);
    if alloca_size <= 1024 {
        splittable_off := NewArray(cast(s64) alloca_size + 1, bool,, allocator = temp);
        for * splittable_off it.* = true;
        for s: S.* {
            o := s.begin + 1;
            while o < s.end && o < alloca_size { splittable_off[o] = false; o += 1; }
        }
        for * s: S.* {
            if !s.splittable continue;
            if (s.begin > alloca_size || splittable_off[s.begin]) && (s.end > alloca_size || splittable_off[s.end]) continue;
            o := inst_op(use_user(s.use));
            if o == .LOAD || o == .STORE { s.splittable = false; sorted = false; }
        }
    } else {
        for * s: S.* {
            if !s.splittable continue;
            if s.begin == 0 && s.end >= alloca_size continue;
            o := inst_op(use_user(s.use));
            if o == .LOAD || o == .STORE { s.splittable = false; sorted = false; }
        }
    }
    if !sorted stable_sort_slices(S.*);
    frags: [..] Sroa_Fragment; frags.allocator = temp;
    it: Sroa_Part_It;
    part_it_init(*it, S);
    while !part_it_at_end(*it) {
        P := *it.p;
        new_ai, active_bits := rewrite_partition(pass, ai, as, P);
        if new_ai != NONE {
            changed = true;
            if new_ai != ai {
                size := min(active_bits, (P.end - P.begin) * 8);
                array_add(*frags, .{new_ai, P.begin * 8, size});
            }
        }
        part_it_advance(*it);
    }
    users: [..] u32; users.allocator = temp;
    find_dbg_users(pass.f, ai, *users);
    declares: [..] u32; declares.allocator = temp;
    values: [..] u32; values.allocator = temp;
    for users {
        rec := dbgr(it);
        if !(rec.loc != NONE && ir.mds[rec.loc].kind == .VALUE && ir.mds[rec.loc].value == ai) continue;
        if rec.kind == .DECLARE array_add(*declares, it);
        else if rec.kind == .VALUE array_add(*values, it);
        else if rec.kind == .ASSIGN fatal("SROA: assignment tracking (dbg_assign) is not supported yet");
    }
    for declares migrate_one(pass, ai, it, frags);
    for values migrate_one(pass, ai, it, frags);
    return changed;
}

// ---------------------------------------------------------------- runOnAlloca / deleteDeadInstructions

clobber_use :: (pass: *Sroa, u: Use_Id) {
    old := use_value(u);
    use_set(u, const_poison(vtype(old)));
    if is_inst(old) && sroa_trivially_dead(old) array_add(*pass.dead_insts, old);
}

run_on_alloca :: (pass: *Sroa, ai: Value_Id) -> bool {
    changed := false;
    if !has_uses(ai) {
        erase_inst_with_metadata(ai);
        return true;
    }
    ok, size := sroa_alloca_allocation_size(ai);
    if alloca_is_array_allocation(ai) || !ok || type_has_scalable(inst(ai).ty2) || size == 0 return changed;
    b: Irb;
    irb_set_before(*b, ai);
    if agg_rewrite(*b, ai) changed = true;
    as: Sroa_Slices;
    build_alloca_slices(ai, *as);
    if as.escaping != NONE return changed;
    if as.escaping_ro != NONE {
        propagate_stored_values_to_loads(ai, *as);
        return true;
    }
    for du: as.dead_users {
        n := nops(du);
        if n > 0 for k: 0..n-1 clobber_use(pass, op_use(du, k));
        rauw_with_metadata(du, const_poison(vtype(du)));
        array_add(*pass.dead_insts, du);
        changed = true;
    }
    for u: as.dead_operands { clobber_use(pass, u); changed = true; }
    if as.slices.count == 0 return changed;
    if split_alloca(pass, ai, *as) changed = true;
    while pass.spec_phis.items.count speculate_phi_node_loads(*b, svec_pop(*pass.spec_phis));
    remaining := pass.selects;
    empty: [..] Sroa_Select_Rw; empty.allocator = temp;
    pass.selects = empty;
    while remaining.count {
        kv := pop(*remaining);
        if rewrite_select_inst_mem_ops(*b, kv.sel, kv.ops, pass.preserve_cfg) pass.cfg_changed = true;
    }
    return changed;
}

delete_dead_instructions :: (pass: *Sroa, deleted_allocas: *[..] Value_Id) -> bool {
    changed := false;
    while pass.dead_insts.count {
        i := pop(*pass.dead_insts);
        if vkind(i) != .INST continue;   // WeakVH: already deleted
        if inst_op(i) == .ALLOCA {
            array_add(deleted_allocas, i);
            users: [..] u32; users.allocator = temp;
            find_dbg_users(pass.f, i, *users);
            for x: users {
                xr := dbgr(x);
                if xr.kind == .DECLARE && xr.owner != NONE && xr.loc != NONE && ir.mds[xr.loc].kind == .VALUE && ir.mds[xr.loc].value == i dbgr_erase(x);
            }
        }
        rauw_with_metadata(i, const_undef(vtype(i)));
        n := nops(i);
        if n > 0 for k: 0..n-1 {
            o := op(i, k);
            if is_inst(o) {
                set_op(i, k, NONE);
                if sroa_trivially_dead(o) array_add(*pass.dead_insts, o);
            }
        }
        erase_inst_with_metadata(i);
        changed = true;
    }
    return changed;
}

promote_allocas :: (pass: *Sroa) -> bool {
    if pass.promotable.items.count == 0 return false;
    if !opts.sroa_skip_mem2reg {
        list: [..] Value_Id; list.allocator = temp;
        for pass.promotable.items array_add(*list, it);
        sroa_flush_dt(pass.dt);
        promote_mem_to_reg(list, pass.dt, get_assumption_cache(pass.f));
    }
    svec_clear(*pass.promotable);
    return true;
}

// SROAPass::run; `name` is the pipeline element (sroa, sroa<preserve-cfg>, ...)
sroa_run :: (f: Value_Id, name: string) -> Preserved {
    pass: Sroa;
    pass.f = f;
    pass.preserve_cfg = false;
    if begins_with(name, "sroa<") {
        params := slice(name, 5, name.count - 6);
        saw_cfg := false;
        for p: split(params, ";",, allocator = temp) {
            if p == "modify-cfg" { if saw_cfg fatal("multiple SROA CFG options specified"); pass.preserve_cfg = false; saw_cfg = true; }
            else if p == "preserve-cfg" { if saw_cfg fatal("multiple SROA CFG options specified"); pass.preserve_cfg = true; saw_cfg = true; }
            else if p == "aggregate-to-vector" pass.agg_to_vec = true;
            else fatal("invalid SROA pass parameter '%'", p);
        }
    }
    pass.dt = get_domtree(f);
    svec_init(*pass.worklist); svec_init(*pass.post_promotion); svec_init(*pass.promotable); svec_init(*pass.spec_phis);
    pass.dead_insts.allocator = temp; pass.selects.allocator = temp;
    dbgr_index_reset();
    sroa_pending_dt_updates.allocator = temp;
    sroa_pending_dt_updates.count = 0;
    for b: fn_blocks(f) for i: block_insts(b) {
        x := inst(i).records;
        while x != 0 { if dbgr(x).kind == .ASSIGN fatal("SROA: assignment tracking (dbg_assign) is not supported yet"); x = dbgr(x).next; }
    }
    entry := fn_entry(f);
    last := block(entry).last;
    i := block(entry).first;
    while i != NONE && i != last {
        if inst_op(i) == .ALLOCA {
            ok, sz := sroa_alloca_allocation_size(i);
            if ok && type_has_scalable(inst(i).ty2) && is_alloca_promotable(i) svec_insert(*pass.promotable, i);
            else svec_insert(*pass.worklist, i);
        }
        i = inst(i).next;
    }
    changed := false;
    deleted: [..] Value_Id; deleted.allocator = temp;
    while true {
        while pass.worklist.items.count {
            if run_on_alloca(*pass, svec_pop(*pass.worklist)) changed = true;
            if delete_dead_instructions(*pass, *deleted) changed = true;
            if deleted.count {
                for deleted { svec_remove(*pass.worklist, it); svec_remove(*pass.post_promotion, it); svec_remove(*pass.promotable, it); }
                deleted.count = 0;
            }
        }
        if promote_allocas(*pass) changed = true;
        svec_assign(*pass.worklist, *pass.post_promotion);
        svec_clear(*pass.post_promotion);
        if pass.worklist.items.count == 0 break;
    }
    sroa_flush_dt(pass.dt);
    if !changed return PRESERVE_ALL;
    if module_has_flag("debug-info-assignment-tracking") fatal("SROA: assignment tracking (RemoveRedundantDbgInstrs) is not supported yet");
    pa: Preserved;
    if !pass.cfg_changed pa = preserved_cfg();
    preserve(*pa, .DOMTREE);
    return pa;
}

module_has_flag :: (key: string) -> bool {
    for nm: ir.named_md {
        if nm.name != "llvm.module.flags" continue;
        for f: nm.ops {
            if f == NONE || ir.mds[f].kind != .TUPLE || ir.mds[f].nops < 3 continue;
            k := md_op(f, 1);
            if k != NONE && ir.mds[k].kind == .STRING && ir.mds[k].str == key return true;
        }
    }
    return false;
}

// SROA::propagateStoredValuesToLoads
propagate_stored_values_to_loads :: (ai: Value_Id, as: *Sroa_Slices) {
    all_same := true;
    pty: Type_Id = NONE;
    insts: [..] Value_Id; insts.allocator = temp;
    begin: u64 = 0; end: u64 = 0;
    flush :: () #expand {
        if all_same && insts.count {
            new_phis: [..] Value_Id; new_phis.allocator = temp;
            ssa: Ssa_Updater;
            ssa.inserted_phis = *new_phis;
            array_add(*insts, ai);
            // LoadAndStorePromoter's constructor: the base name comes from Insts[0]
            some := ifx inst_op(insts[0]) == .LOAD then insts[0] else op(insts[0], 0);
            ssa_init(*ssa, vtype(some), vname(some));
            load_and_store_promote(insts, *ssa, pty);
        }
        all_same = true;
        pty = NONE;
        insts.count = 0;
    }
    for s: as.slices {
        user := use_user(s.use);
        if is_assume_like_intrinsic(user) continue;
        if s.begin >= end {
            flush();
            begin = s.begin; end = s.end;
        } else if s.begin != begin || s.end != end {
            all_same = false;
            end = max(end, s.end);
            continue;
        }
        o := inst_op(user);
        if o == .LOAD {
            t := vtype(user);
            if !inst_is_simple(user) || (pty != NONE && t != pty) all_same = false;
            pty = t;
            array_add(*insts, user);
        } else if o == .STORE {
            t := vtype(op(user, 0));
            if !inst_is_simple(user) || (pty != NONE && t != pty) all_same = false;
            pty = t;
            array_add(*insts, user);
        } else all_same = false;
    }
    flush();
}

// Use::swap: the two uses exchange values and positions in their use lists
use_swap :: (a: Use_Id, b: Use_Id) {
    if ir.u_val[a] == ir.u_val[b] return;
    // relink by hand: detach both, then insert each where the other was
    va := ir.u_val[a]; vb := ir.u_val[b];
    pa := ir.u_prev[a]; na := ir.u_next[a];
    pb := ir.u_prev[b]; nb := ir.u_next[b];
    ir.u_val[a] = vb; ir.u_val[b] = va;
    ir.u_prev[a] = pb; ir.u_next[a] = nb;
    ir.u_prev[b] = pa; ir.u_next[b] = na;
    // a took b's place in vb's list
    if pb == NONE ir.v_first_use[vb] = a; else ir.u_next[pb] = a;
    if nb != NONE ir.u_prev[nb] = a;
    if pa == NONE ir.v_first_use[va] = b; else ir.u_next[pa] = b;
    if na != NONE ir.u_prev[na] = b;
}

// CondBrInst::swapSuccessors
condbr_swap_successors :: (br: Value_Id) {
    use_swap(op_use(br, 1), op_use(br, 2));
    // Instruction::swapProfMetadata
    k := md_kind_id("prof");
    m := get_metadata(br, k);
    if m == NONE || ir.mds[m].kind != .TUPLE || ir.mds[m].nops == 0 return;
    o0 := md_op(m, 0);
    if o0 == NONE || ir.mds[o0].kind != .STRING || ir.mds[o0].str != "branch_weights" return;
    first: u32 = 1;
    if ir.mds[m].nops > 1 { o1 := md_op(m, 1); if o1 != NONE && ir.mds[o1].kind == .STRING && ir.mds[o1].str == "expected" first = 2; }
    if ir.mds[m].nops != 2 + first return;
    ops: [..] Md_Id; ops.allocator = temp;
    for x: 0..first-1 array_add(*ops, md_op(m, x));
    array_add(*ops, md_op(m, first + 1));
    array_add(*ops, md_op(m, first));
    set_metadata(br, k, md_tuple(ops, false));
}

// Instruction::clone for a load or store (no name, no parent, same metadata)
clone_load_store :: (i: Value_Id) -> Value_Id {
    n := nops(i);
    c := new_inst(inst_op(i), vtype(i), n);
    r := inst(i).*;
    r.parent = NONE; r.prev = NONE; r.next = NONE; r.records = 0;
    inst(c).* = r;
    for k: 0..n-1 set_op(c, k, op(i, k));
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(i, *all);
    for all set_metadata(c, it.kind, it.md);
    return c;
}

// Instruction::dropUBImplyingAttrsAndMetadata (loads and stores: drop unknown non-debug metadata)
drop_ub_implying_metadata :: (i: Value_Id) {
    keep := string.["annotation", "range", "nonnull", "align", "fpmath", "prof", "mem.cache_hint", "nofpclass"];
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(i, *all);
    for all {
        if it.kind == 0 continue;
        name := ir.md_kind_names[it.kind];
        kept := false;
        for keep if it == name { kept = true; break; }
        if !kept set_metadata(i, it.kind, NONE);
    }
}

// SplitBlockAndInsertIfThenElse(Cond, SplitBefore, ThenBlock?, ElseBlock?) with a lazy DomTreeUpdater
split_block_and_insert_if_then_else :: (cond: Value_Id, split_before: Value_Id, want_then: bool, want_else: bool, weights: Md_Id) -> (Value_Id, Value_Id) {
    head := inst(split_before).parent;
    orig_succs: [..] Value_Id; orig_succs.allocator = temp;
    {
        tmp: [..] Value_Id; tmp.allocator = temp;
        block_successors(head, *tmp);
        for tmp { dup := false; for x: orig_succs if x == it dup = true; if !dup array_add(*orig_succs, it); }
    }
    f := block_fn(head);
    tail := split_basic_block(head, split_before, "");
    tb := tail; fb := tail;
    then_edge := false; else_edge := false;
    dl := get_metadata(split_before, 0);
    mk :: (f: Value_Id, tail: Value_Id, dl: Md_Id) -> Value_Id {
        bb := create_block(f, "", tail);
        br := create_br(tail);
        block_append_inst(bb, br);
        if dl != NONE set_metadata(br, 0, dl);
        return bb;
    }
    if want_then { tb = mk(f, tail, dl); then_edge = true; }
    if want_else { fb = mk(f, tail, dl); else_edge = true; }
    old := block_terminator(head);
    nt := create_cond_br(cond, tb, fb);
    if weights != NONE set_metadata(nt, md_kind_id("prof"), weights);
    // ReplaceInstWithInst
    if get_metadata(nt, 0) == NONE { d := get_metadata(old, 0); if d != NONE set_metadata(nt, 0, d); }
    insert_at_position(nt, head, old, false);   // insertInto(BB, BI): adopts the old terminator's records
    drop_all_references(old);
    erase_inst(old);
    ups := *sroa_pending_dt_updates;
    array_add(ups, .{true, head, tb});
    array_add(ups, .{true, head, fb});
    if then_edge array_add(ups, .{true, tb, tail});
    if else_edge array_add(ups, .{true, fb, tail});
    for orig_succs array_add(ups, .{true, tail, it});
    for orig_succs array_add(ups, .{false, head, it});
    return tb, fb;
}

// rewriteMemOpOfSelect
rewrite_mem_op_of_select :: (sel: Value_Id, i: Value_Id, spec: u8) {
    head := inst(i).parent;
    prof := get_metadata(sel, md_kind_id("prof"));
    if spec == 0 {
        split_block_and_insert_if_then_else(op(sel, 0), i, true, true, prof);
    } else {
        split_block_and_insert_if_then_else(op(sel, 0), i, true, false, prof);
        if spec & SPEC_TRUE condbr_swap_successors(block_terminator(head));
    }
    head_br := block_terminator(head);
    tail := inst(i).parent;
    set_name(tail, tprint("%.cont", vname(head)));
    is_load := inst_op(i) == .LOAD;
    pn: Value_Id = NONE;
    if is_load {
        pn = create_phi(vtype(i), 2);
        insert_at_position(pn, tail, i, false);
    }
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(head, *succs);
    for sb: succs {
        is_then := sb == get_successor(head_br, 0);
        idx: u32 = ifx is_then then cast(u32) 0 else 1;
        nbb := ifx sb == tail then head else sb;
        c := clone_load_store(i);
        if nbb != head set_name(nbb, tprint("%.%", vname(head), ifx is_then then "then" else "else"));
        else drop_ub_implying_metadata(c);
        insert_at_position(c, nbb, block_terminator(nbb), false);
        ptr := op(sel, 1 + idx);
        set_op(c, ifx is_load then cast(u32) 0 else 1, ptr);
        if is_load {
            set_name(c, tprint("%.%.val", vname(i), ifx is_then then "then" else "else"));
            phi_add_incoming(pn, c, nbb);
        }
    }
    if is_load {
        nm := vname(i);
        set_name(i, "");
        set_name(pn, nm);
        rauw_with_metadata(i, pn);
    }
}

// Function::getEntryCount
function_entry_count :: (f: Value_Id) -> (bool, u64) {
    m := get_metadata(f, md_kind_id("prof"));
    if m == NONE || ir.mds[m].kind != .TUPLE || ir.mds[m].nops < 2 return false, 0;
    o0 := md_op(m, 0);
    if o0 == NONE || ir.mds[o0].kind != .STRING || ir.mds[o0].str != "function_entry_count" return false, 0;
    c := md_const_u64(md_op(m, 1));
    if c == 0xFFFF_FFFF_FFFF_FFFF return false, 0;
    return true, c;
}

// getConstantRangeFromMetadata(N).contains(0)
md_range_contains_zero :: (m: Md_Id) -> bool {
    n := ir.mds[m].nops;
    i: u32 = 0;
    while i + 1 < n {
        lo := ir.mds[md_op(m, i)].value; hi := ir.mds[md_op(m, i + 1)].value;
        if type_int_width(vtype(lo)) > 64 fatal("SROA: wide !range metadata is not supported yet");
        l := const_int_zext(lo); h := const_int_zext(hi);
        if l == h return true;              // full set
        if l < h { if l == 0 return true; }  // [l, h) contains 0 only if l == 0
        else return true;                    // wrapped: contains 0
        i += 2;
    }
    return false;
}

// Function::getVScaleValue: vscale_range(N, N) gives N, else 0
fn_vscale_value :: (f: Value_Id) -> u64 {
    a := attr_set_find(attr_list_fn(glob(f).attrs), .VScaleRange);
    if !a return 0;
    mn := a.ival >> 32; mx := a.ival & 0xFFFF_FFFF;
    if mn != 0 && mn == mx return mn;
    return 0;
}
