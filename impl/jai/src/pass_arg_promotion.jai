// ArgumentPromotion (CGSCC): pass pointer arguments that are only loaded (or stored, for byval) by value.
// Ported from llvm/lib/Transforms/IPO/ArgumentPromotion.cpp, with AAResults::canInstructionRangeModRef /
// canBasicBlockModify (llvm/lib/Analysis/AliasAnalysis.cpp) and AttributeFuncs::updateMinLegalVectorWidthAttr.

Ap_Arg_Part :: struct { offset: s64; ty: Type_Id; align: u64; must_exec: Value_Id = NONE; }
Ap_Promote :: struct { arg: Value_Id; parts: [..] Ap_Arg_Part; }

ap_find_promote :: (list: [] Ap_Promote, a: Value_Id) -> s64 {
    for list if it.arg == a return it_index;
    return -1;
}
// a function's users other than blockaddresses (Value::users() in LLVM 23)
ap_fn_users :: (f: Value_Id) -> [..] Value_Id {
    out: [..] Value_Id; out.allocator = temp;
    u := ir.v_first_use[f];
    while u != NONE { usr := ir.u_user[u]; if vkind(usr) != .C_BLOCKADDR array_add(*out, usr); u = ir.u_next[u]; }
    return out;
}

// AAResults::canInstructionRangeModRef(I1, I2, Loc, Mod)
ap_can_instruction_range_modify :: (aar: *Aa_Results, i1: Value_Id, i2: Value_Id, loc: Mem_Loc) -> bool {
    i := i1;
    while true {
        q := aa_query_new(aar);
        if (aa_mod_ref_inst_loc(q, i, loc) & MR_MOD) != 0 return true;
        if i == i2 break;
        i = inst_next(i);
    }
    return false;
}

// isArgUnmodifiedByAllCalls
ap_is_arg_unmodified_by_all_calls :: (arg: Value_Id) -> bool {
    for call: ap_fn_users(arg_parent(arg)) {
        loc := mloc_for_argument(call, arg_no(arg), false);
        aar := aa_results_for(inst_fn(call));
        q := aa_query_new(*aar);
        if (aa_mod_ref_call_loc(q, call, loc) & MR_MOD) != 0 return false;
    }
    return true;
}

// allCallersPassValidPointerForArgument
ap_all_callers_pass_valid_pointer :: (arg: Value_Id, recursive_calls: [] Value_Id, align: u64, bytes: u64) -> bool {
    callee := arg_parent(arg);
    size := ap_from_u64(64, bytes);
    q: Simplify_Query;
    q.cxt = block_first(fn_entry(callee));
    if is_dereferenceable_and_aligned_pointer(arg, align, size, q) return true;
    for cb: ap_fn_users(callee) {
        rec := false;
        for recursive_calls if it == cb rec = true;
        if rec continue;
        q2: Simplify_Query;
        q2.cxt = cb;
        if !is_dereferenceable_and_aligned_pointer(call_arg(cb, arg_no(arg)), align, size, q2) return false;
    }
    return true;
}

// findArgParts: (ok, parts sorted by offset)
ap_find_arg_parts :: (arg: Value_Id, aar: *Aa_Results, max_elements: u32, is_recursive: bool, parts_out: *[..] Ap_Arg_Part) -> bool {
    if !has_uses(arg) return true;
    parts: [..] Ap_Arg_Part; parts.allocator = temp;
    needed_align: u64 = 1;
    needed_deref_bytes: u64 = 0;
    pa := arg_attrs(arg);
    byval := attr_set_find(pa, .ByVal);
    palign := attr_set_find(pa, .Alignment);
    are_stores_allowed := byval != null && palign != null;

    // HandleEndUser: 0 = not based on the argument (nullopt), 1 = promotable, 2 = not promotable
    handle_end_user :: (arg: Value_Id, i: Value_Id, ty: Type_Id, guaranteed: bool, parts: *[..] Ap_Arg_Part,
                        max_elements: u32, is_recursive: bool, needed_align: *u64, needed_deref_bytes: *u64) -> u8 {
        r := inst(i);
        if r.ord1 != 0 || (r.flags & F_VOLATILE) != 0 return 2;
        ptr := load_store_pointer_operand(i);
        off := ap_zero(dl_index_type_size_bits(vtype(ptr)));
        ptr, off = strip_and_accumulate_constant_offsets(ptr, off, true);
        if ptr != arg return 0;
        if ap_min_signed_bits(off) >= 64 return 2;
        if type_is_scalable(ty) return 2;
        size := dl_type_store_size(ty);
        if is_recursive && is_ptr_type(ty) return 2;
        o := ap_sext_value(off);
        idx := -1;
        for parts.* if it.offset == o { idx = it_index; break; }
        not_seen := idx < 0;
        if not_seen {
            array_add(parts, .{offset = o, ty = ty, align = r.align, must_exec = ifx guaranteed then i else NONE});
            idx = parts.count - 1;
        }
        if max_elements > 0 && cast(u32) parts.count > max_elements return 2;
        part := *parts.*[idx];
        if part.ty != ty return 2;
        if !guaranteed && (not_seen || part.align < r.align) {
            if o < 0 return 2;
            if (o % cast(s64) r.align) != 0 return 2;
            needed_deref_bytes.* = max(needed_deref_bytes.*, cast(u64) o + size);
            needed_align.* = max(needed_align.*, r.align);
        }
        part.align = max(part.align, r.align);
        return 1;
    }

    f := arg_parent(arg);
    for i: block_insts(fn_entry(f)) {
        res: u8 = 0;
        if inst_op(i) == .LOAD res = handle_end_user(arg, i, vtype(i), true, *parts, max_elements, is_recursive, *needed_align, *needed_deref_bytes);
        else if inst_op(i) == .STORE res = handle_end_user(arg, i, vtype(op(i, 0)), true, *parts, max_elements, is_recursive, *needed_align, *needed_deref_bytes);
        if res == 2 return false;
        if !is_guaranteed_to_transfer_execution(i) break;
    }

    worklist: [..] Use_Id; worklist.allocator = temp;
    visited: Table(Use_Id, bool); visited.allocator = temp;
    loads: [..] Value_Id; loads.allocator = temp;
    recursive_calls: [..] Value_Id; recursive_calls.allocator = temp;
    append_uses :: (v: Value_Id, worklist: *[..] Use_Id, visited: *Table(Use_Id, bool)) {
        u := ir.v_first_use[v];
        while u != NONE {
            if !table_contains(visited, u) { table_add(visited, u, true); array_add(worklist, u); }
            u = ir.u_next[u];
        }
    }
    append_uses(arg, *worklist, *visited);
    while worklist.count {
        u := pop(*worklist);
        v := ir.u_user[u];
        if is_inst(v) && inst_op(v) == .GEP {
            if !gep_has_all_constant_indices(v) return false;
            append_uses(v, *worklist, *visited);
            continue;
        }
        if is_inst(v) && inst_op(v) == .LOAD {
            if handle_end_user(arg, v, vtype(v), false, *parts, max_elements, is_recursive, *needed_align, *needed_deref_bytes) != 1 return false;
            array_add(*loads, v);
            continue;
        }
        if are_stores_allowed && is_inst(v) && inst_op(v) == .STORE && opno_of(u) == 1 {
            if handle_end_user(arg, v, vtype(op(v, 0)), false, *parts, max_elements, is_recursive, *needed_align, *needed_deref_bytes) != 1 return false;
            continue;
        }
        if is_inst(v) && is_call_base(v) && call_called_function(v) == inst_fn(v) {
            ptr_arg := ir.u_val[u];
            if ptr_arg != arg return false;
            if opno_of(u) != arg_no(arg) return false;
            if max_elements > 0 && cast(u32) parts.count > max_elements return false;
            array_add(*recursive_calls, v);
            continue;
        }
        return false;
    }
    if needed_deref_bytes != 0 || needed_align > 1 {
        if !ap_all_callers_pass_valid_pointer(arg, recursive_calls, needed_align, needed_deref_bytes) return false;
    }
    if parts.count == 0 return true;
    for i: 1..parts.count-1 {
        x := parts[i]; j := i - 1;
        while j >= 0 && parts[j].offset > x.offset { parts[j + 1] = parts[j]; j -= 1; }
        parts[j + 1] = x;
    }
    for parts array_add(parts_out, it);
    offset := parts[0].offset;
    for parts {
        if it.offset < offset return false;
        offset = it.offset + cast(s64) dl_type_store_size(it.ty);
    }
    if are_stores_allowed return true;
    if ap_is_arg_unmodified_by_all_calls(arg) return true;
    for ld: loads {
        bb := inst_block(ld);
        loc := mloc_get(ld);
        if ap_can_instruction_range_modify(aar, block_first(bb), ld, loc) return false;
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(bb, *preds);
        for p: preds {
            // inverse_depth_first(P)
            seen: Table(Value_Id, bool); seen.allocator = temp;
            stack: [..] Value_Id; stack.allocator = temp;
            array_add(*stack, p);
            table_add(*seen, p, true);
            while stack.count {
                t := pop(*stack);
                if ap_can_instruction_range_modify(aar, block_first(t), block_last(t), loc) return false;
                tp: [..] Value_Id; tp.allocator = temp;
                block_predecessors(t, *tp);
                for pp: tp if !table_contains(*seen, pp) { table_add(*seen, pp, true); array_add(*stack, pp); }
            }
        }
    }
    return true;
}

// areTypesABICompatible (TTI::areTypesABICompatible for every caller)
ap_are_types_abi_compatible :: (types: [] Type_Id, f: Value_Id) -> bool {
    for cb: ap_fn_users(f) {
        if !(is_inst(cb) && is_call_base(cb)) return false;
        caller := inst_fn(cb);
        callee := call_called_function(cb);
        tc := tti_get(caller);
        if tc.kind != .X86 {
            // TargetTransformInfoImplBase: the same target-cpu and target-features attributes
            if !ap_same_str_attr(caller, callee, "target-cpu") || !ap_same_str_attr(caller, callee, "target-features") return false;
            continue;
        }
        te := tti_get(callee);
        if tc == te continue;   // one subtarget: the same register types
        // X86TTIImpl::areTypesABICompatible: getRegisterTypeForCallingConv of every value type must agree
        cc := glob(callee).cc;
        for ty: types {
            vts: [..] Evt; vts.allocator = temp;
            ap_compute_value_vts(*tc.xl, ty, *vts);
            for vt: vts {
                if ap_x86_register_type_for_cc(*tc.xl, cc, vt) != ap_x86_register_type_for_cc(*te.xl, cc, vt) return false;
            }
        }
    }
    return true;
}
// ComputeValueVTs: the leaf types of an aggregate
ap_compute_value_vts :: (st: *X86_Lowering, ty: Type_Id, out: *[..] Evt) {
    k := type_kind(ty);
    if k == .STRUCT { for e: 0..cast(s64) type_nsub(ty) - 1 ap_compute_value_vts(st, type_sub(ty, cast(u32) e), out); return; }
    if k == .ARRAY { for e: 0..cast(s64) type_count(ty) - 1 ap_compute_value_vts(st, type_elem(ty), out); return; }
    ok, vt := x86_value_type(st, ty, false);
    if !ok fatal("argpromotion: no value type for a promoted argument part");
    array_add(out, vt);
}
// X86TargetLowering::getRegisterTypeForCallingConv (x86-64) for simple value types
ap_x86_register_type_for_cc :: (st: *X86_Lowering, cc: u32, vt: Evt) -> u32 {
    if !evt_is_simple(vt) fatal("argpromotion: register types of extended value types (getVectorTypeBreakdown) are not supported yet");
    m := vt.m;
    if mvt_is_vec(m) {
        if mvt_elt(m) == MVE_I1 && st_hasAVX512(st) fatal("argpromotion: AVX-512 mask register calling conventions are not supported yet");
        if mvt_elt(m) == MVE_F16 && mvt_n(m) < 8 return MVT_v8f16;
    }
    if xl_is_type_legal(st, evt_simple(MVT_f16)) {
        if (mvt_is_vec(m) && mvt_elt(m) == MVE_BF16) || m == MVT_bf16 fatal("argpromotion: bf16 calling-convention register types are not supported yet");
    }
    o := xl_ord(m);
    if o < 0 fatal("argpromotion: unknown value type");
    return st.register_type[o];
}
ap_same_str_attr :: (a: Value_Id, b: Value_Id, key: string) -> bool {
    x := fn_find_str_attr(a, key);
    y := fn_find_str_attr(b, key);
    if x == null || y == null return x == y;
    return x.val == y.val;
}

// promoteArguments
ap_promote_arguments :: (f: Value_Id, max_elements: u32, is_recursive_in: bool) -> Value_Id {
    is_recursive := is_recursive_in;
    if fn_has_fn_attr(f, .Naked) return NONE;
    if !gv_has_local_linkage(f) return NONE;
    if !gv_is_definition_exact(f) return NONE;
    if func_vararg(glob(f).value_type) return NONE;
    if fn_has_attr_somewhere(f, .InAlloca) return NONE;
    pointer_args: [..] Value_Id; pointer_args.allocator = temp;
    for k: 0..cast(s64) glob(f).nargs - 1 { a := fn_arg(f, cast(u32) k); if is_ptr_type(vtype(a)) array_add(*pointer_args, a); }
    if pointer_args.count == 0 return NONE;
    u := ir.v_first_use[f];
    while u != NONE {
        defer u = ir.u_next[u];
        cb := ir.u_user[u];
        if vkind(cb) == .C_BLOCKADDR continue;
        if !(is_inst(cb) && is_call_base(cb)) || opno_of(u) != nops(cb) - 1 || inst(cb).ty2 != glob(f).value_type return NONE;
        if inst_op(cb) == .CALL && ((inst(cb).flags >> 16) & 3) == 2 return NONE;
        if inst_fn(cb) == f is_recursive = true;
    }
    for b: fn_blocks(f) if block_terminating_must_tail_call(b) != NONE return NONE;
    aar := aa_results_for(f);
    to_promote: [..] Ap_Promote; to_promote.allocator = temp;
    num_after := func_nparams(glob(f).value_type);
    for pa: pointer_args {
        if attr_set_has(arg_attrs(pa), .StructRet) {
            argno := arg_no(pa);
            fn_set_param_attrs(f, argno, attr_set_add_kind(attr_set_remove(attr_list_param(glob(f).attrs, argno), .StructRet), .NoAlias));
            for cb: ap_fn_users(f) {
                l := inst(cb).attrs;
                inst(cb).attrs = attr_list_with_param(l, argno, attr_set_add_kind(attr_set_remove(attr_list_param(l, argno), .StructRet), .NoAlias));
            }
        }
        parts: [..] Ap_Arg_Part; parts.allocator = temp;
        if ap_find_arg_parts(pa, *aar, max_elements, is_recursive, *parts) {
            types: [..] Type_Id; types.allocator = temp;
            for parts array_add(*types, it.ty);
            if ap_are_types_abi_compatible(types, f) {
                num_after += cast(u32) parts.count - 1;
                array_add(*to_promote, .{arg = pa, parts = parts});
            }
        }
    }
    if to_promote.count == 0 return NONE;
    // TTI::getMaxNumArgs is UINT_MAX on X86
    return ap_do_promotion(f, to_promote);
}
attr_set_add_kind :: (s: u32, k: Attr_Kind) -> u32 {
    if attr_set_has(s, k) return s;
    all: [..] Attr; all.allocator = temp;
    for attr_set_items(s) array_add(*all, it);
    a: Attr; a.kind = k;
    array_add(*all, a);
    return attr_set_get(all);
}

// createByteGEP with IRBuilder<NoFolder>
ap_create_byte_gep :: (b: *Irb, ptr: Value_Id, offset: s64) -> Value_Id {
    if offset == 0 return ptr;
    bits := dl_index_type_size_bits(vtype(ptr));
    idx := const_int_ap(type_int(bits), ap_from_s64(bits, offset));
    i := new_inst(.GEP, vtype(ptr), 2);
    inst(i).ty2 = ir.t_i8;
    set_op(i, 0, ptr); set_op(i, 1, idx);
    return irb_insert(b, i);
}

// doPromotion
ap_do_promotion :: (f: Value_Id, to_promote: [] Ap_Promote) -> Value_Id {
    fty := glob(f).value_type;
    params: [..] Type_Id; params.allocator = temp;
    arg_attr_vec: [..] u32; arg_attr_vec.allocator = temp;
    new_arg_indices: [..] u32; new_arg_indices.allocator = temp;
    pal := glob(f).attrs;
    new_argno: u32 = 0;
    for k: 0..cast(s64) glob(f).nargs - 1 {
        a := fn_arg(f, cast(u32) k);
        pi := ap_find_promote(to_promote, a);
        if pi < 0 {
            array_add(*params, vtype(a));
            array_add(*arg_attr_vec, attr_list_param(pal, cast(u32) k));
            array_add(*new_arg_indices, new_argno);
            new_argno += 1;
        } else if !has_uses(a) {
            array_add(*new_arg_indices, 0xFFFF_FFFF);
        } else {
            for to_promote[pi].parts { array_add(*params, it.ty); array_add(*arg_attr_vec, 0); }
            array_add(*new_arg_indices, 0xFFFF_FFFF);
            new_argno += cast(u32) to_promote[pi].parts.count;
        }
    }
    ret_ty := func_ret(fty);
    nfty := type_func(ret_ty, params, func_vararg(fty));
    nf := ipo_fn_create(nfty, glob(f).linkage, glob(f).addrspace);
    // Function::Create(..., F->getName()): the name is only stored (no module yet); takeName below replaces it
    ipo_fn_copy_attributes_from(nf, f);
    {   // NF->copyMetadata(F, 0)
        mds: [..] Kind_Md; mds.allocator = temp;
        get_all_metadata(f, *mds);
        for mds add_metadata(nf, it.kind, it.md);
    }
    set_metadata(f, MDK_DBG, NONE);   // F->setSubprogram(nullptr)
    largest_vector_width: u64 = 0;
    for params if is_vector_type(it) largest_vector_width = max(largest_vector_width, dl_type_size_bits(it));
    glob(nf).attrs = attr_list_get(attr_list_fn(pal), attr_list_ret(pal), arg_attr_vec);
    {   // remap allocsize
        fa := attr_list_fn(glob(nf).attrs);
        a := attr_set_find(fa, .AllocSize);
        if a {
            arg1 := new_arg_indices[a.ival >> 32];
            assert(arg1 != 0xFFFF_FFFF, "allocsize cannot be promoted argument");
            n := a.ival & 0xFFFF_FFFF;
            arg2: u64 = 0xFFFF_FFFF;
            if n != 0xFFFF_FFFF { arg2 = new_arg_indices[n]; assert(arg2 != 0xFFFF_FFFF); }
            all: [..] Attr; all.allocator = temp;
            for attr_set_items(fa) if it.kind != .AllocSize array_add(*all, it);
            na: Attr; na.kind = .AllocSize; na.ival = ((cast(u64) arg1) << 32) | arg2;
            array_add(*all, na);
            glob(nf).attrs = attr_list_with_fn(glob(nf).attrs, attr_set_get(all));
        }
    }
    ipo_update_min_legal_vector_width_attr(nf, largest_vector_width);
    ipo_fn_insert_before(nf, f);
    gv_take_name(nf, f);

    dead_args: [..] Value_Id; dead_args.allocator = temp;
    while true {
        cb := dae_first_call_user(f);
        if cb == NONE break;
        assert(is_inst(cb) && is_call_base(cb) && call_called_function(cb) == f);
        call_pal := inst(cb).attrs;
        b: Irb;
        irb_set_before(*b, cb);
        args: [..] Value_Id; args.allocator = temp;
        av: [..] u32; av.allocator = temp;
        argno: u32 = 0;
        nparams := glob(f).nargs;
        while argno < nparams {
            a := fn_arg(f, argno);
            av_ := call_arg(cb, argno);
            pi := ap_find_promote(to_promote, a);
            if pi < 0 {
                array_add(*args, av_);
                array_add(*av, attr_list_param(call_pal, argno));
            } else if has_uses(a) {
                for part: to_promote[pi].parts {
                    ptr := ap_create_byte_gep(*b, av_, part.offset);
                    li := new_inst(.LOAD, part.ty, 1);
                    set_op(li, 0, ptr);
                    inst(li).align = part.align;
                    irb_insert(*b, li, tconcat(vname(av_), ".val"));
                    if part.must_exec != NONE {
                        me := part.must_exec;
                        set_aa_metadata(li, get_aa_metadata(me));
                        for kn: string.["dereferenceable", "dereferenceable_or_null", "noundef", "nontemporal"] {
                            kk := md_kind_id(kn);
                            m := get_metadata(me, kk);
                            if m != NONE set_metadata(li, kk, m);
                        }
                        if get_metadata(li, md_fixed("noundef")) != NONE {
                            for kn: string.["range", "nonnull", "align", "nofpclass"] {
                                kk := md_kind_id(kn);
                                set_metadata(li, kk, get_metadata(me, kk));
                            }
                        }
                    }
                    array_add(*args, li);
                    array_add(*av, 0);
                }
            } else {
                array_add(*dead_args, av_);
            }
            argno += 1;
        }
        na := call_num_args(cb);
        while argno < na {
            array_add(*args, call_arg(cb, argno));
            array_add(*av, attr_list_param(call_pal, argno));
            argno += 1;
        }
        ncs := ipo_create_call_like(cb, nfty, nf, args, cb);
        if inst_op(cb) == .CALL inst(ncs).flags = inst(cb).flags & ((cast(u32) 3) << 16);
        inst(ncs).cc = inst(cb).cc;
        inst(ncs).attrs = attr_list_get(attr_list_fn(call_pal), attr_list_ret(call_pal), av);
        ipo_copy_prof_dbg(ncs, cb);
        ipo_update_min_legal_vector_width_attr(inst_fn(cb), largest_vector_width);
        if has_uses(cb) {
            rauw_with_metadata(cb, ncs);
            ic_take_name(ncs, cb);
        }
        erase_inst_with_metadata(cb);
    }
    go_recursively_delete_permissive(dead_args);

    ipo_fn_splice_body(nf, f);

    allocas: [..] Value_Id; allocas.allocator = temp;
    k2: u32 = 0;
    for k: 0..cast(s64) glob(f).nargs - 1 {
        a := fn_arg(f, cast(u32) k);
        pi := ap_find_promote(to_promote, a);
        if pi < 0 {
            a2 := fn_arg(nf, k2);
            rauw_with_metadata(a, a2);
            ic_take_name(a2, a);
            k2 += 1;
            continue;
        }
        defer rauw_with_metadata(a, const_poison(vtype(a)));   // metadata uses (dbg records)
        if !has_uses(a) continue;
        b: Irb;
        irb_set_before(*b, block_first(fn_entry(nf)));
        offset_to_alloca: [..] [2] s64; offset_to_alloca.allocator = temp;
        for part: to_promote[pi].parts {
            na := fn_arg(nf, k2);
            k2 += 1;
            set_name(na, tconcat(vname(a), ".", tprint("%", part.offset), ".val"));
            ai := new_inst(.ALLOCA, type_ptr(dl.alloca_as), 1);
            set_op(ai, 0, const_int(type_int(32), 1));
            inst(ai).ty2 = part.ty;
            inst(ai).align = dl_pref_align(part.ty);
            inst(ai).addrspace = dl.alloca_as;
            irb_insert(*b, ai, tconcat(vname(a), ".", tprint("%", part.offset), ".allc"));
            inst(ai).align = part.align;
            irb_store(*b, na, ai, part.align);
            array_add(*offset_to_alloca, .[part.offset, cast(s64) ai]);
        }
        get_alloca :: (a: Value_Id, ptr_in: Value_Id, table: [] [2] s64) -> Value_Id {
            off := ap_zero(dl_index_type_size_bits(vtype(ptr_in)));
            ptr, o := strip_and_accumulate_constant_offsets(ptr_in, off, true);
            assert(ptr == a);
            ov := ap_sext_value(o);
            for table if it[0] == ov return cast(Value_Id) it[1];
            fatal("argpromotion: no alloca for a promoted offset");
            return NONE;
        }
        worklist: [..] Value_Id; worklist.allocator = temp;
        uu := ir.v_first_use[a];
        while uu != NONE { array_add(*worklist, ir.u_user[uu]); uu = ir.u_next[uu]; }
        dead_insts: [..] Value_Id; dead_insts.allocator = temp;
        while worklist.count {
            v := pop(*worklist);
            o := inst_op(v);
            if o == .GEP {
                array_add(*dead_insts, v);
                x := ir.v_first_use[v];
                while x != NONE { array_add(*worklist, ir.u_user[x]); x = ir.u_next[x]; }
                continue;
            }
            if o == .LOAD { set_op(v, 0, get_alloca(a, op(v, 0), offset_to_alloca)); continue; }
            if o == .STORE { set_op(v, 1, get_alloca(a, op(v, 1), offset_to_alloca)); continue; }
            fatal("argpromotion: unexpected user of a promoted argument");
        }
        for i: dead_insts {
            rauw_with_metadata(i, const_poison(vtype(i)));
            erase_inst_with_metadata(i);
        }
        for offset_to_alloca array_add(*allocas, cast(Value_Id) it[1]);
    }
    if allocas.count {
        dt := get_domtree(nf);
        ac := get_assumption_cache(nf);
        promote_mem_to_reg(allocas, dt, ac);
    }
    ipo_mark_subprogram_nocall(nf);
    return nf;
}

// ArgumentPromotionPass::run
arg_promotion_run_scc :: (node: *Pass_Node, c: s32) -> Preserved {
    max_elements: u32 = 2;
    if node.name != "argpromotion" fatal("invalid argpromotion pass parameter in '%'", node.name);
    changed := false;
    while true {
        local_change := false;
        nodes := lcg.sccs[c].nodes;
        is_recursive := nodes.count > 1;
        for n: nodes {
            old_f := lcg_fn(n);
            new_f := ap_promote_arguments(old_f, max_elements, is_recursive);
            if new_f == NONE continue;
            local_change = true;
            lcg_replace_node_function(n, new_f);
            { table_remove(*fam, old_f); ac_virtual_clear(old_f); }
            gv_erase_from_parent(old_f);
            func_pa := preserved_cfg();
            for u: ap_fn_users(new_f) fam_invalidate(inst_fn(u), func_pa);
        }
        changed |= local_change;
        if !local_change break;
    }
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    pa: Preserved;
    pa.all_fn = true;
    return pa;
}
