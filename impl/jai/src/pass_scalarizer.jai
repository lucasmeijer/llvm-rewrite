// ScalarizerPass: a port of llvm/lib/Transforms/Scalar/Scalarizer.cpp (complete), with the parameter parser
// parseScalarizerOptions (llvm/lib/Passes/PassBuilder.cpp).
//
// The ScatterMap is a std::map keyed by (Value *, Type *): only looked up (and cleared), so a Table is equivalent.
// The InstVisitor is the opcode switch in sz_visit; the Splitter functors are the `kind` of sz_split_unary/binary.

Sz_Options :: struct {
    variable_insert_extract := true;   // ScalarizeVariableInsertExtract
    load_store := false;               // ScalarizeLoadStore
    min_bits: u32 = 0;                 // ScalarizeMinBits
}

// VectorSplit
Sz_Split :: struct {
    vec_ty: Type_Id = NONE;
    num_packed: u32;
    num_fragments: u32;
    split_ty: Type_Id = NONE;
    rem_ty: Type_Id = NONE;
}
sz_fragment_type :: (vs: Sz_Split, i: u32) -> Type_Id {
    if vs.rem_ty != NONE && i == vs.num_fragments - 1 return vs.rem_ty;
    return vs.split_ty;
}

// Scatterer
Sz_Scatterer :: struct {
    bb: Value_Id;
    pt: Value_Id;    // BBI (NONE = end)
    head: bool;      // BBI's head bit
    v: Value_Id;
    vs: Sz_Split;
    is_pointer: bool;
    cache: *[..] Value_Id;   // CachePtr, or `tmp`
    tmp: [..] Value_Id;
}

Sz_Gathered :: struct { op: Value_Id; cv: *[..] Value_Id; }

Sz :: struct {
    f: Value_Id;
    dt: *Dom_Tree;
    o: Sz_Options;
    scattered: Table(u64, *[..] Value_Id);   // (Value, SplitTy) -> fragments
    gathered: [..] Sz_Gathered;
    scalarized: bool;
    potentially_dead: [..] Vh;               // WeakTrackingVH
}

sz_key :: (v: Value_Id, t: Type_Id) -> u64 { return ((cast(u64) v) << 32) | cast(u64) t; }
sz_scattered :: (s: *Sz, v: Value_Id, t: Type_Id) -> *[..] Value_Id {
    k := sz_key(v, t);
    found, p := table_find(*s.scattered, k);
    if found return p;
    p = New([..] Value_Id,, allocator = temp);
    p.allocator = temp;
    table_set(*s.scattered, k, p);
    return p;
}

sz_scatterer :: (bb: Value_Id, pt: Value_Id, head: bool, v: Value_Id, vs: Sz_Split, cache: *[..] Value_Id) -> Sz_Scatterer {
    sc: Sz_Scatterer;
    sc.bb = bb; sc.pt = pt; sc.head = head; sc.v = v; sc.vs = vs; sc.cache = cache;
    sc.is_pointer = type_kind(vtype(v)) == .PTR;
    sc.tmp.allocator = temp;
    if !cache {
        array_resize(*sc.tmp, vs.num_fragments);
        for * sc.tmp it.* = NONE;
    } else if vs.num_fragments > cache.count {
        old := cache.count;
        array_resize(cache, vs.num_fragments);
        for k: old..cache.count - 1 cache.*[k] = NONE;
    }
    return sc;
}

// Scatterer::operator[]
sz_get :: (sc: *Sz_Scatterer, frag: u32) -> Value_Id {
    cv := ifx sc.cache then sc.cache else *sc.tmp;
    if cv.*[frag] != NONE return cv.*[frag];
    b: Irb;
    irb_set_at(*b, sc.bb, sc.pt, sc.head);
    if sc.is_pointer {
        if frag == 0 cv.*[frag] = sc.v;
        else cv.*[frag] = irb_gep(*b, sc.vs.split_ty, sc.v, .[const_int(type_int(cast(u64) 32), frag)], tconcat(vname(sc.v), ".i", tdec(frag)));
        return cv.*[frag];
    }
    fty := sz_fragment_type(sc.vs, frag);
    if type_kind(fty) == .VECTOR {
        mask: [..] u32; mask.allocator = temp;
        for j: 0..cast(s64) type_count(fty) - 1 array_add(*mask, cast(u32)(frag * sc.vs.num_packed + cast(u32) j));
        cv.*[frag] = irb_shuffle(*b, sc.v, const_poison(vtype(sc.v)), mask, tconcat(vname(sc.v), ".i", tdec(frag)));
    } else {
        while true {
            ins := sc.v;
            if !is_inst(ins) || inst_op(ins) != .INSERTELEMENT break;
            idx := op(ins, 2);
            if vkind(idx) != .C_INT || is_vector_type(vtype(idx)) break;
            j := cast(u32) ap_zext_value(const_ap(idx));
            sc.v = op(ins, 0);
            if frag * sc.vs.num_packed == j {
                cv.*[frag] = op(ins, 1);
                return cv.*[frag];
            }
            if sc.vs.num_packed == 1 && cv.*[j] == NONE cv.*[j] = op(ins, 1);
        }
        if !is_vector_type(vtype(sc.v)) fatal("scalarizer: scattering a non-vector value (LLVM would create an invalid extractelement)");
        cv.*[frag] = irb_extract_element(*b, sc.v, cast(u64)(frag * sc.vs.num_packed), tconcat(vname(sc.v), ".i", tdec(frag)));
    }
    return cv.*[frag];
}

// skipPastPhiNodesAndDbg(std::next(VOp))
sz_point_after :: (i: Value_Id) -> Value_Id, bool {
    nx := inst_next(i);
    if nx != NONE && inst_op(nx) == .PHI return block_first_insertion_pt(inst_block(i)), true;
    return nx, false;
}

// scatter
sz_scatter :: (s: *Sz, point: Value_Id, v: Value_Id, vs: Sz_Split) -> Sz_Scatterer {
    if vkind(v) == .ARGUMENT {
        bb := fn_entry(s.f);
        return sz_scatterer(bb, block_first(bb), true, v, vs, sz_scattered(s, v, vs.split_ty));
    }
    if is_inst(v) {
        if !dt_is_reachable_from_entry(s.dt, inst_block(v))
            return sz_scatterer(inst_block(point), point, false, const_poison(vtype(v)), vs, null);
        if is_terminator(inst_op(v)) fatal("scalarizer: scattering the result of a terminator is not supported");
        pt, head := sz_point_after(v);
        return sz_scatterer(inst_block(v), pt, head, v, vs, sz_scattered(s, v, vs.split_ty));
    }
    return sz_scatterer(inst_block(point), point, false, v, vs, null);
}

// Value::takeName (a constant cannot take a name: V just loses its own)
sz_take_name :: (dst: Value_Id, src: Value_Id) {
    if dst == src return;
    k := vkind(dst);
    if is_constant_kind(k) && !is_global_value(k) { if vname(src).count set_name(src, ""); return; }
    ic_take_name(dst, src);
}

// canTransferMetadata
sz_can_transfer_metadata :: (k: u32) -> bool {
    return k == md_fixed("tbaa") || k == md_fixed("fpmath") || k == md_fixed("tbaa.struct") || k == md_fixed("invariant.load") ||
           k == md_fixed("alias.scope") || k == md_fixed("noalias") || k == md_fixed("llvm.mem.parallel_loop_access") ||
           k == md_fixed("llvm.access.group");
}
// transferMetadataAndIRFlags
sz_transfer_metadata_and_ir_flags :: (op: Value_Id, cv: [] Value_Id) {
    mds: [..] Kind_Md; mds.allocator = temp;
    get_all_metadata(op, *mds);
    dl := get_metadata(op, 0);
    for v: cv {
        if !is_inst(v) continue;
        for mds if it.kind != 0 && sz_can_transfer_metadata(it.kind) set_metadata(v, it.kind, it.md);
        copy_ir_flags(v, op);
        if dl != NONE && get_metadata(v, 0) == NONE set_metadata(v, 0, dl);
    }
}

// gather
sz_gather :: (s: *Sz, op: Value_Id, cv: [] Value_Id, vs: Sz_Split) {
    sz_transfer_metadata_and_ir_flags(op, cv);
    sv := sz_scattered(s, op, vs.split_ty);
    if sv.count {
        for i: 0..sv.count - 1 {
            v := sv.*[i];
            if v == NONE || v == cv[i] continue;
            if is_inst(cv[i]) sz_take_name(cv[i], v);
            rauw_with_metadata(v, cv[i]);
            array_add(*s.potentially_dead, vh_new(v));
        }
    }
    sv.count = 0;
    for cv array_add(sv, it);
    array_add(*s.gathered, .{op, sv});
}

// replaceUses
sz_replace_uses :: (s: *Sz, op: Value_Id, cv: Value_Id) {
    if cv != op {
        rauw_with_metadata(op, cv);
        array_add(*s.potentially_dead, vh_new(op));
        s.scalarized = true;
    }
}

// getVectorSplit
sz_get_vector_split :: (s: *Sz, ty: Type_Id) -> bool, Sz_Split {
    vs: Sz_Split;
    if type_kind(ty) != .VECTOR return false, vs;
    vs.vec_ty = ty;
    num_elems := cast(u32) type_count(ty);
    elem_ty := type_elem(ty);
    elem_bits := type_bits(elem_ty);
    if num_elems == 1 || type_kind(elem_ty) == .PTR || 2 * elem_bits > s.o.min_bits {
        vs.num_packed = 1;
        vs.num_fragments = num_elems;
        vs.split_ty = elem_ty;
    } else {
        vs.num_packed = s.o.min_bits / elem_bits;
        if vs.num_packed >= num_elems return false, vs;
        vs.num_fragments = (num_elems + vs.num_packed - 1) / vs.num_packed;
        vs.split_ty = type_vector(cast(u64) vs.num_packed, elem_ty, false);
        rem := num_elems % vs.num_packed;
        if rem > 1 vs.rem_ty = type_vector(cast(u64) rem, elem_ty, false);
        else if rem == 1 vs.rem_ty = elem_ty;
    }
    return true, vs;
}

// isStructOfMatchingFixedVectors
sz_is_struct_of_matching_fixed_vectors :: (ty: Type_Id) -> bool {
    if type_kind(ty) != .STRUCT return false;
    n := type_nsub(ty);
    if n < 1 return false;
    v := type_sub(ty, 0);
    if type_kind(v) != .VECTOR return false;
    sz := type_count(v);
    for i: 1..cast(s64) n - 1 {
        v = type_sub(ty, cast(u32) i);
        if type_kind(v) != .VECTOR || sz != type_count(v) return false;
    }
    return true;
}

// concatenate
sz_concatenate :: (b: *Irb, fragments: [] Value_Id, vs: Sz_Split, name: string) -> Value_Id {
    num_elements := cast(u32) type_count(vs.vec_ty);
    extend_mask: [..] u32; extend_mask.allocator = temp;
    insert_mask: [..] u32; insert_mask.allocator = temp;
    if vs.num_packed > 1 {
        array_resize(*extend_mask, num_elements);
        for * extend_mask it.* = POISON_MASK_ELEM;
        for i: 0..vs.num_packed - 1 extend_mask[i] = i;
        array_resize(*insert_mask, num_elements);
        for i: 0..num_elements - 1 insert_mask[i] = i;
    }
    res := const_poison(vs.vec_ty);
    for i: 0..vs.num_fragments - 1 {
        fragment := fragments[i];
        num_packed := vs.num_packed;
        if i == vs.num_fragments - 1 && vs.rem_ty != NONE {
            if type_kind(vs.rem_ty) == .VECTOR num_packed = cast(u32) type_count(vs.rem_ty);
            else num_packed = 1;
        }
        if num_packed == 1 {
            res = irb_insert_element(b, res, fragment, cast(u64)(i * vs.num_packed), tconcat(name, ".upto", tdec(i)));
        } else {
            if num_packed < vs.num_packed {
                extend_mask.count = num_packed;
                old := extend_mask.count;
                array_resize(*extend_mask, num_elements);
                for k: old..cast(s64) num_elements - 1 extend_mask[k] = POISON_MASK_ELEM;
            }
            fragment = irb_shuffle(b, fragment, const_poison(vtype(fragment)), extend_mask);
            if i == 0 {
                res = fragment;
            } else {
                for j: 0..num_packed - 1 insert_mask[i * vs.num_packed + j] = num_elements + j;
                res = irb_shuffle(b, res, fragment, insert_mask, tconcat(name, ".upto", tdec(i)));
                for j: 0..num_packed - 1 insert_mask[i * vs.num_packed + j] = i * vs.num_packed + j;
            }
        }
    }
    return res;
}

// The splitters (FCmpSplitter, ICmpSplitter, UnarySplitter, BinarySplitter, the freeze lambda)
Sz_Split_Kind :: enum u8 { FCMP; ICMP; UNARY; BINARY; FREEZE; }
sz_apply_splitter :: (b: *Irb, kind: Sz_Split_Kind, i: Value_Id, op0: Value_Id, op1: Value_Id, name: string) -> Value_Id {
    if #complete kind == {
        case .FCMP;
            if irb_is_const(op0) && irb_is_const(op1) { x := cf_compare(inst(i).pred, op0, op1); if x != NONE return x; }
            return irb_insert(b, create_fcmp(inst(i).pred, op0, op1), name);
        case .ICMP;
            return irb_icmp(b, inst(i).pred, op0, op1, name);
        case .UNARY;
            if irb_is_const(op0) { x := cf_unary(inst_op(i), op0); if x != NONE return x; }
            u := new_inst(inst_op(i), vtype(op0), 1);
            set_op(u, 0, op0);
            return irb_insert(b, u, name);
        case .BINARY;
            return irb_binop(b, inst_op(i), op0, op1, name);
        case .FREEZE;
            return irb_freeze(b, op0, name);
    }
    return NONE;
}

// splitUnary
sz_split_unary :: (s: *Sz, i: Value_Id, kind: Sz_Split_Kind) -> bool {
    ok, vs := sz_get_vector_split(s, vtype(i));
    if !ok return false;
    op_vs := vs;
    if vtype(op(i, 0)) != vtype(i) {
        ok2, ovs := sz_get_vector_split(s, vtype(op(i, 0)));
        if !ok2 || vs.num_packed != ovs.num_packed return false;
        op_vs = ovs;
    }
    b: Irb; irb_set_before(*b, i);
    o := sz_scatter(s, i, op(i, 0), op_vs);
    res := NewArray(vs.num_fragments, Value_Id,, allocator = temp);
    for frag: 0..vs.num_fragments - 1 res[frag] = sz_apply_splitter(*b, kind, i, sz_get(*o, frag), NONE, tconcat(vname(i), ".i", tdec(frag)));
    sz_gather(s, i, res, vs);
    return true;
}

// splitBinary
sz_split_binary :: (s: *Sz, i: Value_Id, kind: Sz_Split_Kind) -> bool {
    ok, vs := sz_get_vector_split(s, vtype(i));
    if !ok return false;
    op_vs := vs;
    if vtype(op(i, 0)) != vtype(i) {
        ok2, ovs := sz_get_vector_split(s, vtype(op(i, 0)));
        if !ok2 || vs.num_packed != ovs.num_packed return false;
        op_vs = ovs;
    }
    b: Irb; irb_set_before(*b, i);
    v0 := sz_scatter(s, i, op(i, 0), op_vs);
    v1 := sz_scatter(s, i, op(i, 1), op_vs);
    res := NewArray(vs.num_fragments, Value_Id,, allocator = temp);
    for frag: 0..vs.num_fragments - 1 {
        a := sz_get(*v0, frag);
        c := sz_get(*v1, frag);
        res[frag] = sz_apply_splitter(*b, kind, i, a, c, tconcat(vname(i), ".i", tdec(frag)));
    }
    sz_gather(s, i, res, vs);
    return true;
}

// isTriviallyScalarizable (no target intrinsic of ours has IntrTriviallyScalarizable)
sz_is_trivially_scalarizable :: (id: Intrinsic_Id) -> bool {
    if is_trivially_vectorizable(id) return true;
    return false;   // Intrinsic::isTriviallyScalarizable: only DirectX / SPIR-V intrinsics have IntrTriviallyScalarizable
}
// isVectorIntrinsicWithStructReturnOverloadAtField
sz_struct_return_overload_at_field :: (id: Intrinsic_Id, ret_idx: s64) -> bool {
    if id == IID_FREXP return ret_idx == 0 || ret_idx == 1;
    return ret_idx == 0;
}

// splitCall
sz_split_call :: (s: *Sz, ci: Value_Id) -> bool {
    call_ty := vtype(ci);
    all_matching := sz_is_struct_of_matching_fixed_vectors(call_ty);
    ok: bool; vs: Sz_Split;
    if all_matching ok, vs = sz_get_vector_split(s, type_sub(call_ty, 0));
    else ok, vs = sz_get_vector_split(s, call_ty);
    if !ok return false;
    f := call_called_function(ci);
    if f == NONE return false;
    id := fn_iid(f);
    if id == NOT_INTRINSIC || !sz_is_trivially_scalarizable(id) return false;
    num_args := call_arg_count(ci);
    scalar_operands := NewArray(num_args, Value_Id,, allocator = temp);
    for * scalar_operands it.* = NONE;
    scattered := NewArray(num_args, Sz_Scatterer,, allocator = temp);
    has_scattered := NewArray(num_args, bool,, allocator = temp);
    overload_idx := NewArray(num_args, s64,, allocator = temp);
    for * overload_idx it.* = -1;
    tys: [..] Type_Id; tys.allocator = temp;
    if is_vector_intrinsic_with_overload_type_at_arg(id, -1) array_add(*tys, vs.split_ty);
    if all_matching {
        for k: 1..cast(s64) type_nsub(call_ty) - 1 {
            ok2, cur := sz_get_vector_split(s, type_sub(call_ty, cast(u32) k));
            if !ok2 || cur.num_packed != vs.num_packed return false;
            if sz_struct_return_overload_at_field(id, k) array_add(*tys, cur.split_ty);
        }
    }
    for k: 0..cast(s64) num_args - 1 {
        o := op(ci, cast(u32) k);
        if type_kind(vtype(o)) == .VECTOR {
            ok3, ovs := sz_get_vector_split(s, vtype(o));
            if !ok3 || ovs.num_packed != vs.num_packed return false;
            scattered[k] = sz_scatter(s, ci, o, ovs);
            has_scattered[k] = true;
            if is_vector_intrinsic_with_overload_type_at_arg(id, k) {
                overload_idx[k] = tys.count;
                array_add(*tys, ovs.split_ty);
            }
        } else {
            scalar_operands[k] = o;
            if is_vector_intrinsic_with_overload_type_at_arg(id, k) array_add(*tys, vtype(o));
        }
    }
    res := NewArray(vs.num_fragments, Value_Id,, allocator = temp);
    ops: [..] Value_Id; ops.allocator = temp;
    new_intrin := get_or_insert_intrinsic_declaration(id, tys);
    b: Irb; irb_set_before(*b, ci);
    for i: 0..vs.num_fragments - 1 {
        is_remainder := i == vs.num_fragments - 1 && vs.rem_ty != NONE;
        ops.count = 0;
        if is_remainder tys[0] = vs.rem_ty;
        for j: 0..cast(s64) num_args - 1 {
            if is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) j) {
                array_add(*ops, scalar_operands[j]);
            } else {
                if !has_scattered[j] fatal("scalarizer: scalar operand of a vector intrinsic in a vector position");
                x := sz_get(*scattered[j], i);
                array_add(*ops, x);
                if is_remainder && overload_idx[j] >= 0 tys[overload_idx[j]] = vtype(x);
            }
        }
        if is_remainder new_intrin = get_or_insert_intrinsic_declaration(id, tys);
        res[i] = irb_call(*b, new_intrin, ops, tconcat(vname(ci), ".i", tdec(i)));
    }
    sz_gather(s, ci, res, vs);
    return true;
}

sz_visit_select :: (s: *Sz, si: Value_Id) -> bool {
    ok, vs := sz_get_vector_split(s, vtype(si));
    if !ok return false;
    has_cond_vs := false; cond_vs: Sz_Split;
    if type_kind(vtype(op(si, 0))) == .VECTOR {
        ok2, cvs := sz_get_vector_split(s, vtype(op(si, 0)));
        if !ok2 || cvs.num_packed != vs.num_packed return false;
        has_cond_vs = true; cond_vs = cvs;
    }
    b: Irb; irb_set_before(*b, si);
    v1 := sz_scatter(s, si, op(si, 1), vs);
    v2 := sz_scatter(s, si, op(si, 2), vs);
    res := NewArray(vs.num_fragments, Value_Id,, allocator = temp);
    if has_cond_vs {
        v0 := sz_scatter(s, si, op(si, 0), cond_vs);
        for i: 0..vs.num_fragments - 1 {
            a := sz_get(*v0, i); c := sz_get(*v1, i); d := sz_get(*v2, i);
            res[i] = irb_select(*b, a, c, d, tconcat(vname(si), ".i", tdec(i)));
        }
    } else {
        a := op(si, 0);
        for i: 0..vs.num_fragments - 1 {
            c := sz_get(*v1, i); d := sz_get(*v2, i);
            res[i] = irb_select(*b, a, c, d, tconcat(vname(si), ".i", tdec(i)));
        }
    }
    sz_gather(s, si, res, vs);
    return true;
}

sz_visit_gep :: (s: *Sz, gepi: Value_Id) -> bool {
    ok, vs := sz_get_vector_split(s, vtype(gepi));
    if !ok return false;
    b: Irb; irb_set_before(*b, gepi);
    n := cast(s64) nops(gepi);
    scalar_ops := NewArray(n, Value_Id,, allocator = temp);
    scatter_ops := NewArray(n, Sz_Scatterer,, allocator = temp);
    for k: 0..n - 1 {
        o := op(gepi, cast(u32) k);
        if type_kind(vtype(o)) == .VECTOR {
            ok2, ovs := sz_get_vector_split(s, vtype(o));
            if !ok2 || ovs.num_packed != vs.num_packed return false;
            scatter_ops[k] = sz_scatter(s, gepi, o, ovs);
            scalar_ops[k] = NONE;
        } else {
            scalar_ops[k] = o;
        }
    }
    res := NewArray(vs.num_fragments, Value_Id,, allocator = temp);
    split_ops := NewArray(n, Value_Id,, allocator = temp);
    for i: 0..vs.num_fragments - 1 {
        for j: 0..n - 1 {
            if scalar_ops[j] != NONE split_ops[j] = scalar_ops[j];
            else split_ops[j] = sz_get(*scatter_ops[j], i);
        }
        res[i] = irb_gep(*b, inst(gepi).ty2, split_ops[0], array_view(split_ops, 1, n - 1), tconcat(vname(gepi), ".i", tdec(i)));
        if (inst(gepi).flags & F_INBOUNDS) && is_inst(res[i]) && inst_op(res[i]) == .GEP inst(res[i]).flags |= F_INBOUNDS;
    }
    sz_gather(s, gepi, res, vs);
    return true;
}

sz_visit_cast :: (s: *Sz, ci: Value_Id) -> bool {
    ok, dvs := sz_get_vector_split(s, vtype(ci));
    if !ok return false;
    ok2, svs := sz_get_vector_split(s, vtype(op(ci, 0)));
    if !ok2 || svs.num_packed != dvs.num_packed return false;
    b: Irb; irb_set_before(*b, ci);
    o := sz_scatter(s, ci, op(ci, 0), svs);
    res := NewArray(dvs.num_fragments, Value_Id,, allocator = temp);
    for i: 0..dvs.num_fragments - 1 {
        x := sz_get(*o, i);
        res[i] = irb_cast(*b, inst_op(ci), x, sz_fragment_type(dvs, i), tconcat(vname(ci), ".i", tdec(i)));
    }
    sz_gather(s, ci, res, dvs);
    return true;
}

// getPrimitiveSizeInBits of a fragment type
sz_primitive_bits :: (t: Type_Id) -> u32 {
    if type_kind(t) == .VECTOR return type_bits(type_elem(t)) * cast(u32) type_count(t);
    return type_bits(t);
}

sz_visit_bitcast :: (s: *Sz, bci: Value_Id) -> bool {
    okd, dvs := sz_get_vector_split(s, vtype(bci));
    oks, svs := sz_get_vector_split(s, vtype(op(bci, 0)));
    if !okd || !oks || dvs.rem_ty != NONE || svs.rem_ty != NONE return false;
    is_ptr := type_kind(type_elem(dvs.vec_ty)) == .PTR;
    b: Irb; irb_set_before(*b, bci);
    o := sz_scatter(s, bci, op(bci, 0), svs);
    res := NewArray(dvs.num_fragments, Value_Id,, allocator = temp);
    dst_bits := sz_primitive_bits(dvs.split_ty);
    src_bits := sz_primitive_bits(svs.split_ty);
    if is_ptr || dst_bits == src_bits {
        for i: 0..dvs.num_fragments - 1 {
            x := sz_get(*o, i);
            res[i] = irb_bitcast(*b, x, sz_fragment_type(dvs, i), tconcat(vname(bci), ".i", tdec(i)));
        }
    } else if src_bits % dst_bits == 0 {
        mid: Sz_Split;
        mid.num_packed = dvs.num_packed;
        mid.num_fragments = src_bits / dst_bits;
        mid.vec_ty = type_vector(cast(u64)(mid.num_packed * mid.num_fragments), type_elem(dvs.vec_ty), false);
        mid.split_ty = dvs.split_ty;
        res_i := 0;
        for i: 0..svs.num_fragments - 1 {
            v := sz_get(*o, i);
            while is_inst(v) && inst_op(v) == .BITCAST v = op(v, 0);
            v = irb_bitcast(*b, v, mid.vec_ty, tconcat(vname(v), ".cast"));
            m := sz_scatter(s, bci, v, mid);
            for j: 0..mid.num_fragments - 1 { res[res_i] = sz_get(*m, j); res_i += 1; }
        }
    } else if dst_bits % src_bits == 0 {
        mid: Sz_Split;
        mid.num_fragments = dst_bits / src_bits;
        mid.num_packed = svs.num_packed;
        mid.vec_ty = type_vector(cast(u64)(mid.num_packed * mid.num_fragments), type_elem(svs.vec_ty), false);
        mid.split_ty = svs.split_ty;
        src_i: u32 = 0;
        concat_ops := NewArray(mid.num_fragments, Value_Id,, allocator = temp);
        for i: 0..dvs.num_fragments - 1 {
            for j: 0..mid.num_fragments - 1 { concat_ops[j] = sz_get(*o, src_i); src_i += 1; }
            v := sz_concatenate(*b, concat_ops, mid, tconcat(vname(bci), ".i", tdec(i)));
            res[i] = irb_bitcast(*b, v, sz_fragment_type(dvs, i), tconcat(vname(bci), ".i", tdec(i)));
        }
    } else {
        return false;
    }
    sz_gather(s, bci, res, dvs);
    return true;
}

sz_visit_insert_element :: (s: *Sz, iei: Value_Id) -> bool {
    ok, vs := sz_get_vector_split(s, vtype(iei));
    if !ok return false;
    b: Irb; irb_set_before(*b, iei);
    o := sz_scatter(s, iei, op(iei, 0), vs);
    new_elt := op(iei, 1);
    ins_idx := op(iei, 2);
    res := NewArray(vs.num_fragments, Value_Id,, allocator = temp);
    if vkind(ins_idx) == .C_INT {
        idx := cast,trunc(u32) ap_word(const_ap(ins_idx), 0);   // unsigned Idx = CI->getZExtValue()
        fragment := idx / vs.num_packed;
        for i: 0..vs.num_fragments - 1 {
            if i == fragment {
                is_packed := vs.num_packed > 1;
                if fragment == vs.num_fragments - 1 && vs.rem_ty != NONE && !is_vector_type(vs.rem_ty) is_packed = false;
                if is_packed res[i] = irb_insert_element(*b, sz_get(*o, i), new_elt, cast(u64)(idx % vs.num_packed));
                else res[i] = new_elt;
            } else {
                res[i] = sz_get(*o, i);
            }
        }
    } else {
        if !s.o.variable_insert_extract || vs.num_packed > 1 return false;
        for i: 0..vs.num_fragments - 1 {
            should := irb_icmp(*b, ICMP_EQ, ins_idx, sz_const_int_untruncated(vtype(ins_idx), i), tconcat(vname(ins_idx), ".is.", tdec(i)));
            old := sz_get(*o, i);
            res[i] = irb_select(*b, should, new_elt, old, tconcat(vname(iei), ".i", tdec(i)));
        }
    }
    sz_gather(s, iei, res, vs);
    return true;
}

// ConstantInt::get(Ty, V) with ImplicitTrunc = false: a value that does not fit makes LLVM's release build keep an
// APInt with bits above its width (an i1 "2" that prints as `true` but is neither true nor false); fail loudly.
sz_const_int_untruncated :: (t: Type_Id, v: u32) -> Value_Id {
    w := type_int_width(t);
    if w < 32 && (cast(u64) v) >= ((cast(u64) 1) << w)
        fatal(tprint("scalarizer: index constant % does not fit i%: LLVM's ConstantInt::get keeps the untruncated APInt (release build)", v, w));
    return const_int(t, v);
}

sz_visit_extract_value :: (s: *Sz, evi: Value_Id) -> bool {
    o := op(evi, 0);
    op_ty := vtype(o);
    if !sz_is_struct_of_matching_fixed_vectors(op_ty) return false;
    if !is_inst(o) || inst_op(o) != .CALL return false;
    f := call_called_function(o);
    if f == NONE return false;
    id := fn_iid(f);
    if id == NOT_INTRINSIC || !sz_is_trivially_scalarizable(id) return false;
    ok, vs := sz_get_vector_split(s, type_sub(op_ty, 0));
    if !ok return false;
    for k: 1..cast(s64) type_nsub(op_ty) - 1 {
        ok2, cur := sz_get_vector_split(s, type_sub(op_ty, cast(u32) k));
        if !ok2 || cur.num_packed != vs.num_packed return false;
    }
    b: Irb; irb_set_before(*b, evi);
    o0 := sz_scatter(s, evi, o, vs);
    index := ir.u32_pool[inst(evi).idx];
    res: [..] Value_Id; res.allocator = temp;
    for k: 0..vs.num_fragments - 1 {
        x := sz_get(*o0, k);
        array_add(*res, irb_extract_value(*b, x, .[index], tconcat(vname(evi), ".elem", tdec(index))));
    }
    _, avs := sz_get_vector_split(s, type_sub(op_ty, index));
    sz_gather(s, evi, res, avs);
    return true;
}

sz_visit_extract_element :: (s: *Sz, eei: Value_Id) -> bool {
    ok, vs := sz_get_vector_split(s, vtype(op(eei, 0)));
    if !ok return false;
    b: Irb; irb_set_before(*b, eei);
    o := sz_scatter(s, eei, op(eei, 0), vs);
    ext_idx := op(eei, 1);
    if vkind(ext_idx) == .C_INT {
        idx := cast,trunc(u32) ap_word(const_ap(ext_idx), 0);   // unsigned Idx = CI->getZExtValue()
        if idx >= type_count(vs.vec_ty) return false;
        fragment := idx / vs.num_packed;
        res := sz_get(*o, fragment);
        is_packed := vs.num_packed > 1;
        if fragment == vs.num_fragments - 1 && vs.rem_ty != NONE && !is_vector_type(vs.rem_ty) is_packed = false;
        if is_packed res = irb_extract_element(*b, res, idx % vs.num_packed);
        sz_replace_uses(s, eei, res);
        return true;
    }
    if !s.o.variable_insert_extract || vs.num_packed > 1 return false;
    res := const_poison(type_elem(vs.vec_ty));
    for i: 0..vs.num_fragments - 1 {
        should := irb_icmp(*b, ICMP_EQ, ext_idx, sz_const_int_untruncated(vtype(ext_idx), i), tconcat(vname(ext_idx), ".is.", tdec(i)));
        elt := sz_get(*o, i);
        res = irb_select(*b, should, elt, res, tconcat(vname(eei), ".upto", tdec(i)));
    }
    sz_replace_uses(s, eei, res);
    return true;
}

sz_visit_shuffle_vector :: (s: *Sz, svi: Value_Id) -> bool {
    ok, vs := sz_get_vector_split(s, vtype(svi));
    ok2, vs_op := sz_get_vector_split(s, vtype(op(svi, 0)));
    if !ok || !ok2 || vs.num_packed > 1 || vs_op.num_packed > 1 return false;
    o0 := sz_scatter(s, svi, op(svi, 0), vs_op);
    o1 := sz_scatter(s, svi, op(svi, 1), vs_op);
    res := NewArray(vs.num_fragments, Value_Id,, allocator = temp);
    mask := shuffle_mask(svi);
    for i: 0..vs.num_fragments - 1 {
        sel := mask[i];
        if sel == POISON_MASK_ELEM res[i] = const_poison(type_elem(vs.vec_ty));
        else if sel < o0.vs.num_fragments res[i] = sz_get(*o0, sel);
        else res[i] = sz_get(*o1, sel - o0.vs.num_fragments);
    }
    sz_gather(s, svi, res, vs);
    return true;
}

sz_visit_phi :: (s: *Sz, phi: Value_Id) -> bool {
    ok, vs := sz_get_vector_split(s, vtype(phi));
    if !ok return false;
    b: Irb; irb_set_before(*b, phi);
    res := NewArray(vs.num_fragments, Value_Id,, allocator = temp);
    n := nops(phi);
    for i: 0..vs.num_fragments - 1 res[i] = irb_phi(*b, sz_fragment_type(vs, i), n, tconcat(vname(phi), ".i", tdec(i)));
    for i: 0..cast(s64) n - 1 {
        o := sz_scatter(s, phi, phi_value(phi, cast(u32) i), vs);
        inc := phi_block(phi, cast(u32) i);
        for j: 0..vs.num_fragments - 1 phi_add_incoming(res[j], sz_get(*o, j), inc);
    }
    sz_gather(s, phi, res, vs);
    return true;
}

// getVectorLayout: (ok, split, fragment size)
sz_get_vector_layout :: (s: *Sz, ty: Type_Id) -> bool, Sz_Split, u64 {
    ok, vs := sz_get_vector_split(s, ty);
    if !ok return false, vs, 0;
    if !dl_size_eq_store_size(vs.split_ty) || (vs.rem_ty != NONE && !dl_size_eq_store_size(vs.rem_ty)) return false, vs, 0;
    return true, vs, dl_type_store_size(vs.split_ty);
}
// commonAlignment(VecAlign, Frag * SplitSize)
sz_fragment_align :: (vec_align: u64, offset: u64) -> u64 {
    x := vec_align | offset;
    return x & (~x + 1);
}

sz_visit_load :: (s: *Sz, li: Value_Id) -> bool {
    if !s.o.load_store return false;
    if !is_simple_load_store(li) return false;
    ok, vs, split_size := sz_get_vector_layout(s, vtype(li));
    if !ok return false;
    b: Irb; irb_set_before(*b, li);
    ptr := sz_scatter(s, li, op(li, 0), vs);
    res := NewArray(vs.num_fragments, Value_Id,, allocator = temp);
    align := inst(li).align;
    for i: 0..vs.num_fragments - 1 {
        p := sz_get(*ptr, i);
        res[i] = irb_load(*b, sz_fragment_type(vs, i), p, sz_fragment_align(align, i * split_size), false, tconcat(vname(li), ".i", tdec(i)));
    }
    sz_gather(s, li, res, vs);
    return true;
}

sz_visit_store :: (s: *Sz, si: Value_Id) -> bool {
    if !s.o.load_store return false;
    if !is_simple_load_store(si) return false;
    full := op(si, 0);
    ok, vs, split_size := sz_get_vector_layout(s, vtype(full));
    if !ok return false;
    b: Irb; irb_set_before(*b, si);
    vptr := sz_scatter(s, si, op(si, 1), vs);
    vval := sz_scatter(s, si, full, vs);
    stores := NewArray(vs.num_fragments, Value_Id,, allocator = temp);
    align := inst(si).align;
    for i: 0..vs.num_fragments - 1 {
        v := sz_get(*vval, i);
        p := sz_get(*vptr, i);
        stores[i] = irb_store(*b, v, p, sz_fragment_align(align, i * split_size));
    }
    sz_transfer_metadata_and_ir_flags(si, stores);
    return true;
}

// InstVisitor::visit
sz_visit :: (s: *Sz, i: Value_Id) -> bool {
    o := inst_op(i);
    if o == {
        case .SELECT; return sz_visit_select(s, i);
        case .ICMP; return sz_split_binary(s, i, .ICMP);
        case .FCMP; return sz_split_binary(s, i, .FCMP);
        case .FNEG; return sz_split_unary(s, i, .UNARY);
        case .GEP; return sz_visit_gep(s, i);
        case .BITCAST; return sz_visit_bitcast(s, i);
        case .INSERTELEMENT; return sz_visit_insert_element(s, i);
        case .EXTRACTELEMENT; return sz_visit_extract_element(s, i);
        case .EXTRACTVALUE; return sz_visit_extract_value(s, i);
        case .SHUFFLEVECTOR; return sz_visit_shuffle_vector(s, i);
        case .PHI; return sz_visit_phi(s, i);
        case .LOAD; return sz_visit_load(s, i);
        case .STORE; return sz_visit_store(s, i);
        case .CALL; return sz_split_call(s, i);
        case .FREEZE; return sz_split_unary(s, i, .FREEZE);
    }
    if is_binary_op(o) return sz_split_binary(s, i, .BINARY);
    if is_cast_op(o) return sz_visit_cast(s, i);
    return false;
}

// finish
sz_finish :: (s: *Sz) -> bool {
    if s.gathered.count == 0 && s.scattered.count == 0 && !s.scalarized return false;
    for g: s.gathered {
        o := g.op;
        cv := g.cv.*;
        if has_uses(o) {
            res: Value_Id;
            ty := vtype(o);
            if type_kind(ty) == .VECTOR {
                bb := inst_block(o);
                b: Irb; irb_set_before(*b, o);
                if inst_op(o) == .PHI irb_set_at(*b, bb, block_first_insertion_pt(bb), true);
                _, vs := sz_get_vector_split(s, ty);
                res = sz_concatenate(*b, cv, vs, vname(o));
                sz_take_name(res, o);
            } else if type_kind(ty) == .STRUCT {
                bb := inst_block(o);
                b: Irb; irb_set_before(*b, o);
                if inst_op(o) == .PHI irb_set_at(*b, bb, block_first_insertion_pt(bb), true);
                n := type_nsub(ty);
                elem_cv := NewArray(n, [..] Value_Id,, allocator = temp);
                for k: 0..cast(s64) n - 1 {
                    elem_cv[k].allocator = temp;
                    for e: cv array_add(*elem_cv[k], irb_extract_value(*b, e, .[cast(u32) k], tconcat(vname(o), ".elem", tdec(cast(u64) k))));
                }
                res = const_poison(ty);
                for k: 0..cast(s64) n - 1 {
                    _, vs := sz_get_vector_split(s, type_sub(ty, cast(u32) k));
                    c := sz_concatenate(*b, elem_cv[k], vs, vname(o));
                    res = irb_insert_value(*b, res, c, .[cast(u32) k], tconcat(vname(o), ".insert"));
                }
            } else {
                res = cv[0];
                if o == res continue;
            }
            rauw_with_metadata(o, res);
        }
        array_add(*s.potentially_dead, vh_new(o));
    }
    s.gathered.count = 0;
    table_reset(*s.scattered);
    s.scalarized = false;
    // RecursivelyDeleteTriviallyDeadInstructionsPermissive(PotentiallyDeadInstrs) (no TLI)
    dead: [..] Value_Id; dead.allocator = temp;
    for h: s.potentially_dead {
        v := vh_get(h);
        if v == NONE || !is_inst(v) || !is_instruction_trivially_dead_tli(v, false) { array_add(*dead, NONE); continue; }
        array_add(*dead, v);
    }
    while dead.count {
        i := pop(*dead);
        if i == NONE || vkind(i) == .DEAD continue;
        salvage_debug_info(i);
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            o := op(i, cast(u32) k);
            set_op(i, cast(u32) k, NONE);
            if o == NONE || has_uses(o) continue;
            if is_inst(o) && is_instruction_trivially_dead_tli(o, false) array_add(*dead, o);
        }
        erase_inst_with_metadata(i);
    }
    return true;
}

// scalarizer<load-store;variable-insert-extract;min-bits=N> (parseScalarizerOptions)
sz_parse_options :: (name: string) -> Sz_Options {
    o: Sz_Options;
    if name == "scalarizer" return o;
    params := slice(name, "scalarizer<".count, name.count - "scalarizer<".count - 1);
    while params.count {
        p := params;
        k := find_index_from_left(params, #char ";");
        if k >= 0 { p = slice(params, 0, k); params = slice(params, k + 1, params.count - k - 1); } else params = "";
        if begins_with(p, "min-bits=") {
            v, ok, rest := string_to_int(slice(p, 9, p.count - 9));
            if !ok || rest.count fatal(tprint("invalid argument to Scalarizer pass min-bits parameter: '%'", slice(p, 9, p.count - 9)));
            o.min_bits = cast(u32) v;
            continue;
        }
        enable := true;
        if begins_with(p, "no-") { enable = false; p = slice(p, 3, p.count - 3); }
        if p == "load-store" o.load_store = enable;
        else if p == "variable-insert-extract" o.variable_insert_extract = enable;
        else fatal(tprint("invalid Scalarizer pass parameter '%'", p));
    }
    return o;
}
scalarizer_run :: (f: Value_Id, node: *Pass_Node) -> Preserved {
    s: Sz;
    s.f = f;
    s.dt = get_domtree(f);
    tti_get(f);   // AM.getResult<TargetIRAnalysis>(F) (only target intrinsics would query it)
    s.o = sz_parse_options(node.name);
    s.scattered.allocator = temp; s.gathered.allocator = temp; s.potentially_dead.allocator = temp;
    rpo: [..] Value_Id; rpo.allocator = temp;
    cfg_post_order(fn_entry(f), *rpo);
    for < bb: rpo {
        i := block_first(bb);
        while i != NONE {
            done := sz_visit(*s, i);
            nx := inst_next(i);
            if done && vtype(i) == ir.t_void {
                erase_inst_with_metadata(i);
                s.scalarized = true;
            }
            i = nx;
        }
    }
    changed := sz_finish(*s);
    vh_release_all();
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    return pa;
}
