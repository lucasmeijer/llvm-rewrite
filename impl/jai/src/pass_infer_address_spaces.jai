// InferAddressSpaces (`infer-address-spaces`): port of llvm/lib/Transforms/Scalar/InferAddressSpaces.cpp
// (InferAddressSpacesImpl: run, collectFlatAddressExpressions, inferAddressSpaces, updateAddressSpace,
// rewriteWithNewAddressSpaces, cloneValueWithNewAddressSpace and its instruction / constant-expression / ptrmask
// helpers, performPointerReplacement, rewriteIntrinsicOperands, handleMemIntrinsicPtrUse, isSafeToCastConstAddrSpace).
//
// Target hooks: X86 and NoTTI have no flat address space (getFlatAddressSpace = -1: the pass does nothing unless
// -assume-default-is-flat-addrspace makes address space 0 flat), no assumed or predicated address spaces, no
// preserved pointer mask for addrspacecasts (so inttoptr(logic(ptrtoint(addrspacecast))) is never an address
// expression), no volatile variants, no target intrinsics to rewrite. isNoopAddrSpaceCast is
// X86TargetMachine's (both address spaces below 256; x86's pointer size does not depend on the address space here),
// false without a target.
// Maps keyed by pointers (Visited, InferredAddrSpace, ValueWithNewAddrSpace, PredicatedAS) are only looked up.

ias_cl: struct {
    assume_default_is_flat := false;   // -assume-default-is-flat-addrspace
}

IAS_UNINIT :: 0xFFFF_FFFF;

Ias :: struct {
    f: Value_Id;
    tti: *Tti;
    fas: u32;                                  // FlatAddrSpace
    visited: Table(Value_Id, bool);
    inferred: Table(Value_Id, u32);            // InferredAddrSpace
    new_as: Value_Map;                         // ValueWithNewAddrSpace
}
Ias_Poison_Use :: struct { user: Value_Id; opno: u32; val: Value_Id; }
Ias_Stack_Elem :: struct { v: Value_Id; explored: bool; }

ias_ptr_as :: (v: Value_Id) -> u32 { return ptr_addrspace(vtype(v)); }
ias_is_ptr_or_ptr_vec :: (t: Type_Id) -> bool { return is_ptr_type(scalar_type(t)); }
// getPtrOrVecOfPtrsWithNewAS
ias_with_new_as :: (t: Type_Id, as: u32) -> Type_Id {
    p := type_ptr(as);
    if is_vector_type(t) return type_vector(type_count(t), p, type_kind(t) == .SVECTOR);
    return p;
}
ias_is_operator :: (v: Value_Id) -> bool { return is_inst(v) || vkind(v) == .C_EXPR; }
ias_opcode :: (v: Value_Id) -> Opcode { if is_inst(v) return inst_op(v); return cexpr(v).op; }

ias_is_noop_addrspace_cast :: (s: *Ias, from: u32, to: u32) -> bool {
    if s.tti.kind != .X86 return false;
    return from < 256 && to < 256;
}

// CastInst::isNoopCast for ptrtoint / inttoptr: the integer is as wide as the pointer
ias_is_noop_int_ptr_cast :: (opc: Opcode, src: Type_Id, dst: Type_Id) -> bool {
    pt := ifx opc == .INTTOPTR then dst else src;
    it := ifx opc == .INTTOPTR then src else dst;
    return type_bits(scalar_type(dl_int_ptr_type(pt))) == type_bits(scalar_type(it));
}

// isNoopPtrIntCastPair
ias_is_noop_ptr_int_cast_pair :: (s: *Ias, i2p: Value_Id) -> bool {
    p2i := op(i2p, 0);
    if !ias_is_operator(p2i) || ias_opcode(p2i) != .PTRTOINT return false;
    p2i_as := ias_ptr_as(op(p2i, 0));
    i2p_as := ias_ptr_as(i2p);
    return ias_is_noop_int_ptr_cast(.INTTOPTR, vtype(op(i2p, 0)), vtype(i2p)) &&
           ias_is_noop_int_ptr_cast(.PTRTOINT, vtype(op(p2i, 0)), vtype(p2i)) &&
           (p2i_as == i2p_as || ias_is_noop_addrspace_cast(s, p2i_as, i2p_as));
}

// isAddressExpression (arguments: getAssumedAddrSpace is always -1 here)
ias_is_address_expression :: (s: *Ias, v: Value_Id) -> bool {
    if !ias_is_operator(v) return false;
    if ias_opcode(v) == {
        case .PHI; return true;
        case .BITCAST; #through;
        case .ADDRSPACECAST; #through;
        case .GEP; return true;
        case .SELECT; return ias_is_ptr_or_ptr_vec(vtype(v));
        case .CALL; return call_iid(v) == IID_PTRMASK;
        case .INTTOPTR; return ias_is_noop_ptr_int_cast_pair(s, v);   // || isSafeToCastIntToPtrAddrSpace: never on x86
    }
    return false;
}

// getPointerOperands
ias_pointer_operands :: (s: *Ias, v: Value_Id) -> [..] Value_Id {
    r: [..] Value_Id; r.allocator = temp;
    if vkind(v) == .ARGUMENT return r;
    if ias_opcode(v) == {
        case .PHI; for k: 0..cast(s64) nops(v) - 1 array_add(*r, op(v, cast(u32) k));
        case .BITCAST; #through;
        case .ADDRSPACECAST; #through;
        case .GEP; array_add(*r, op(v, 0));
        case .SELECT; array_add(*r, op(v, 1)); array_add(*r, op(v, 2));
        case .CALL; array_add(*r, op(v, 0));
        case .INTTOPTR; array_add(*r, op(op(v, 0), 0));   // a no-op ptrtoint/inttoptr pair
        case; fatal("internal: infer-address-spaces: unexpected address expression");
    }
    return r;
}

// appendsFlatAddressExpressionToPostorderStack
ias_append :: (s: *Ias, v: Value_Id, stack: *[..] Ias_Stack_Elem) {
    if vkind(v) == .C_EXPR {
        if ias_is_address_expression(s, v) && !table_contains(*s.visited, v) {
            table_set(*s.visited, v, true);
            array_add(stack, .{v, false});
        }
        return;
    }
    if ias_ptr_as(v) == s.fas && ias_is_address_expression(s, v) {
        if !table_contains(*s.visited, v) {
            table_set(*s.visited, v, true);
            array_add(stack, .{v, false});
            if ias_is_operator(v) for k: 0..cast(s64) nops(v) - 1 {
                o := op(v, cast(u32) k);
                if vkind(o) == .C_EXPR && ias_is_address_expression(s, o) && !table_contains(*s.visited, o) {
                    table_set(*s.visited, o, true);
                    array_add(stack, .{o, false});
                }
            }
        }
    }
}

// collectRewritableIntrinsicOperands
ias_collect_intrinsic_operands :: (s: *Ias, ii: Value_Id, stack: *[..] Ias_Stack_Elem) {
    id := call_iid(ii);
    n := iid_name(id);
    if id == IID_PTRMASK || n == "llvm.objectsize" || id == IID_MASKED_LOAD || n == "llvm.masked.gather" || n == "llvm.prefetch" ||
       n == "llvm.lifetime.start" || n == "llvm.lifetime.end" {
        ias_append(s, call_arg(ii, 0), stack);
    } else if n == "llvm.is.constant" {
        p := call_arg(ii, 0);
        if ias_is_ptr_or_ptr_vec(vtype(p)) ias_append(s, p, stack);
    } else if id == IID_MASKED_STORE || n == "llvm.masked.scatter" {
        ias_append(s, call_arg(ii, 1), stack);
    } else if n == "llvm.fake.use" {
        for k: 0..cast(s64) nops(ii) - 1 {
            o := op(ii, cast(u32) k);
            if ias_is_ptr_or_ptr_vec(vtype(o)) ias_append(s, o, stack);
        }
    }
    // default: collectFlatAddressOperands is false on x86
}

// collectFlatAddressExpressions
ias_collect_flat_address_expressions :: (s: *Ias) -> [..] Value_Id {
    stack: [..] Ias_Stack_Elem; stack.allocator = temp;
    for i: fn_insts(s.f) {
        o := inst_op(i);
        if o == .GEP ias_append(s, op(i, 0), *stack);
        else if o == .LOAD ias_append(s, op(i, 0), *stack);
        else if o == .STORE ias_append(s, op(i, 1), *stack);
        else if o == .ATOMICRMW || o == .CMPXCHG ias_append(s, op(i, 0), *stack);
        else if o == .CALL && is_mem_intrinsic(i) {
            ias_append(s, call_arg(i, 0), *stack);
            if is_memtransfer_intrinsic(i) ias_append(s, call_arg(i, 1), *stack);
        } else if o == .CALL && call_iid(i) != NOT_INTRINSIC ias_collect_intrinsic_operands(s, i, *stack);
        else if o == .ICMP {
            if ias_is_ptr_or_ptr_vec(vtype(op(i, 0))) { ias_append(s, op(i, 0), *stack); ias_append(s, op(i, 1), *stack); }
        } else if o == .ADDRSPACECAST ias_append(s, op(i, 0), *stack);
        else if o == .INTTOPTR {
            if ias_is_noop_ptr_int_cast_pair(s, i) ias_append(s, op(op(i, 0), 0), *stack);
        } else if o == .RET {
            if nops(i) > 0 && ias_is_ptr_or_ptr_vec(vtype(op(i, 0))) ias_append(s, op(i, 0), *stack);
        }
    }
    post: [..] Value_Id; post.allocator = temp;
    while stack.count {
        top := stack[stack.count - 1].v;
        if stack[stack.count - 1].explored {
            if ias_ptr_as(top) == s.fas array_add(*post, top);
            stack.count -= 1;
            continue;
        }
        stack[stack.count - 1].explored = true;
        for p: ias_pointer_operands(s, top) ias_append(s, p, *stack);
    }
    return post;
}

// joinAddressSpaces
ias_join :: (s: *Ias, a: u32, b: u32) -> u32 {
    if a == s.fas || b == s.fas return s.fas;
    if a == IAS_UNINIT return b;
    if b == IAS_UNINIT return a;
    return ifx a == b then a else s.fas;
}

// isSafeToCastConstAddrSpace
ias_is_safe_to_cast_const :: (s: *Ias, c: Value_Id, new_as: u32) -> bool {
    src := ias_ptr_as(c);
    k := vkind(c);
    if src == new_as || k == .C_UNDEF || k == .C_POISON return true;
    if src != s.fas && new_as != s.fas return false;
    if k == .C_NULL || k == .C_ZERO return true;
    if k == .C_EXPR {
        if cexpr(c).op == .ADDRSPACECAST return ias_is_safe_to_cast_const(s, op(c, 0), new_as);
        if cexpr(c).op == .INTTOPTR && ias_ptr_as(c) == s.fas return true;
    }
    return false;
}

// updateAddressSpace (no assumed or predicated address spaces on x86)
ias_update_address_space :: (s: *Ias, v: Value_Id) -> bool {
    new_as: u32 = IAS_UNINIT;
    const_ops: [..] Value_Id; const_ops.allocator = temp;
    ptr_ops := ias_pointer_operands(s, v);
    for p: ptr_ops {
        found, oas := table_find(*s.inferred, p);
        if !found {
            oas = ias_ptr_as(p);
            if is_constant_kind(vkind(p)) && oas == s.fas { array_add(*const_ops, p); continue; }
            // getPredicatedAddrSpace: TTI->getPredicatedAddrSpace is (nullptr, -1) on x86
        }
        new_as = ias_join(s, new_as, oas);
        if new_as == s.fas break;
    }
    if new_as != s.fas && new_as != IAS_UNINIT {
        for c: const_ops if !ias_is_safe_to_cast_const(s, c, new_as) { new_as = s.fas; break; }
    }
    if new_as == IAS_UNINIT && ptr_ops.count == const_ops.count new_as = s.fas;
    _, old := table_find(*s.inferred, v);
    if old == new_as return false;
    table_set(*s.inferred, v, new_as);
    return true;
}

// inferAddressSpaces: a SetVector worklist popped from the back
ias_infer :: (s: *Ias, post: [] Value_Id) {
    work: [..] Value_Id; work.allocator = temp;
    in_work: Table(Value_Id, bool); in_work.allocator = temp;
    for post { if !table_contains(*in_work, it) { table_set(*in_work, it, true); array_add(*work, it); } }
    for post table_set(*s.inferred, it, IAS_UNINIT);
    while work.count {
        v := pop(*work);
        table_remove(*in_work, v);
        if !ias_update_address_space(s, v) continue;
        for user: sx_users(v) {
            if table_contains(*in_work, user) continue;
            found, a := table_find(*s.inferred, user);
            if !found continue;
            if a == s.fas continue;
            table_set(*in_work, user, true);
            array_add(*work, user);
        }
    }
}

// operandWithNewAddressSpaceOrCreatePoison
ias_operand_with_new_as :: (s: *Ias, user: Value_Id, opno: u32, new_as: u32, poison_uses: *[..] Ias_Poison_Use) -> Value_Id {
    o := op(user, opno);
    nt := ias_with_new_as(vtype(o), new_as);
    if is_constant_kind(vkind(o)) return ce_cast(.ADDRSPACECAST, o, nt);
    nv := vmap_lookup(*s.new_as, o);
    if nv != NONE return nv;
    // PredicatedAS is empty on x86
    array_add(poison_uses, .{user, opno, o});
    return const_poison(nt);
}

// clonePtrMaskWithNewAddressSpace
ias_clone_ptrmask :: (s: *Ias, i: Value_Id, new_as: u32, poison_uses: *[..] Ias_Poison_Use) -> Value_Id {
    old_as := ias_ptr_as(op(i, 0));
    mask_op := call_arg(i, 1);
    mask_ty := vtype(mask_op);
    old_bits := cast(u32) dl_ptr_size_bits_as(old_as);
    new_bits := cast(u32) dl_ptr_size_bits_as(new_as);
    if !ias_is_noop_addrspace_cast(s, old_as, new_as) {
        // computeKnownBitsAddrSpaceCast(NewAS, PtrOp): the bit widths are the data layout's pointer sizes
        if old_bits > new_bits fatal("infer-address-spaces: ptrmask into a narrower address space (KnownBits of the mask) is not supported yet");
    }
    b: Irb; irb_set_before(*b, i);
    if new_bits < type_bits(scalar_type(mask_ty)) {
        mask_ty = ifx is_vector_type(mask_ty) then vector_with_elt(mask_ty, type_int(new_bits)) else type_int(new_bits);
        mask_op = irb_cast(*b, .TRUNC, mask_op, mask_ty);
    }
    np := ias_operand_with_new_as(s, i, 0, new_as, poison_uses);
    return vp_intrinsic(*b, IID_PTRMASK, .[vtype(np), mask_ty], .[np, mask_op]);
}

// cloneInstructionWithNewAddressSpace (returns the clone, not yet inserted unless it says so)
ias_clone_instruction :: (s: *Ias, i: Value_Id, new_as: u32, poison_uses: *[..] Ias_Poison_Use) -> Value_Id {
    npt := ias_with_new_as(vtype(i), new_as);
    o := inst_op(i);
    if o == .ADDRSPACECAST return op(i, 0);
    if o == .CALL return ias_clone_ptrmask(s, i, new_as, poison_uses);
    n := nops(i);
    nops_new := NewArray(n, Value_Id,, allocator = temp);
    for k: 0..cast(s64) n - 1 {
        if !ias_is_ptr_or_ptr_vec(vtype(op(i, cast(u32) k)))
            nops_new[k] = NONE;
        else nops_new[k] = ias_operand_with_new_as(s, i, cast(u32) k, new_as, poison_uses);
    }
    if o == {
        case .BITCAST; return create_cast(.BITCAST, nops_new[0], npt);
        case .PHI;
            p := create_phi(npt, n);
            for k: 0..cast(s64) n - 1 phi_add_incoming(p, nops_new[k], phi_block(i, cast(u32) k));
            return p;
        case .GEP;
            g := new_inst(.GEP, npt, n);
            inst(g).ty2 = inst(i).ty2;
            set_op(g, 0, nops_new[0]);
            for k: 1..cast(s64) n - 1 set_op(g, cast(u32) k, op(i, cast(u32) k));
            if inst(i).flags & F_INBOUNDS inst(g).flags = F_INBOUNDS;   // setIsInBounds
            return g;
        case .SELECT;
            // SelectInst::Create(C, S1, S2, "", nullptr, MDFrom = I)
            sel := new_inst(.SELECT, vtype(nops_new[1]), 3);
            set_op(sel, 0, op(i, 0)); set_op(sel, 1, nops_new[1]); set_op(sel, 2, nops_new[2]);
            copy_metadata_kinds(sel, i, .[md_kind("prof"), md_kind("unpredictable")]);
            return sel;
        case .INTTOPTR;
            src := op(op(i, 0), 0);
            if vtype(src) == npt return src;
            return create_cast(.ADDRSPACECAST, src, npt);
    }
    fatal("internal: infer-address-spaces: unexpected opcode");
    return NONE;
}

// cloneConstantExprWithNewAddressSpace
ias_clone_constant_expr :: (s: *Ias, ce: Value_Id, new_as: u32) -> Value_Id {
    tt := ifx ias_is_ptr_or_ptr_vec(vtype(ce)) then ias_with_new_as(vtype(ce), new_as) else vtype(ce);
    opc := cexpr(ce).op;
    if opc == .ADDRSPACECAST return op(ce, 0);
    if opc == .BITCAST {
        nv := vmap_lookup(*s.new_as, op(ce, 0));
        if nv != NONE return ce_cast(.BITCAST, nv, tt);
        return ce_cast(.ADDRSPACECAST, ce, tt);
    }
    if opc == .INTTOPTR {
        if ias_is_noop_ptr_int_cast_pair(s, ce) return op(op(ce, 0), 0);
        fatal("internal: infer-address-spaces: unexpected inttoptr expression");
    }
    is_new := false;
    n := nops(ce);
    ops := NewArray(n, Value_Id,, allocator = temp);
    for k: 0..cast(s64) n - 1 {
        o := op(ce, cast(u32) k);
        nv := vmap_lookup(*s.new_as, o);
        if nv != NONE { is_new = true; ops[k] = nv; continue; }
        if vkind(o) == .C_EXPR {
            c := ias_clone_constant_expr(s, o, new_as);
            if c != NONE { is_new = true; ops[k] = c; continue; }
        }
        ops[k] = o;
    }
    if !is_new return NONE;
    return ce_with_operands(ce, ops);   // the new type follows from the operands (GEP) or is unchanged (other casts)
}

// cloneValueWithNewAddressSpace
ias_clone_value :: (s: *Ias, v: Value_Id, new_as: u32, poison_uses: *[..] Ias_Poison_Use) -> Value_Id {
    if vkind(v) == .ARGUMENT {
        entry := fn_entry(s.f);
        c := create_cast(.ADDRSPACECAST, v, type_ptr(new_as));
        insert_at_position(c, entry, block_first_non_phi(entry), true);
        return c;
    }
    if is_inst(v) {
        nv := ias_clone_instruction(s, v, new_as, poison_uses);
        if nv != NONE && is_inst(nv) && inst(nv).parent == NONE {
            inst_insert_before_adopt(nv, v);
            take_name(nv, v);
            set_metadata(nv, MDK_DBG, get_metadata(v, MDK_DBG));
        }
        return nv;
    }
    return ias_clone_constant_expr(s, v, new_as);
}

// rewriteIntrinsicOperands
ias_rewrite_intrinsic_operands :: (ii: Value_Id, old_v: Value_Id, new_v_in: Value_Id) -> bool {
    new_v := new_v_in;
    id := call_iid(ii);
    n := iid_name(id);
    if n == "llvm.objectsize" || id == IID_MASKED_LOAD || n == "llvm.masked.gather" {
        decl := get_or_insert_intrinsic_declaration(id, .[vtype(ii), vtype(new_v)]);
        call_set_arg(ii, 0, new_v);
        call_set_called_function(ii, decl);
        return true;
    }
    if id == IID_PTRMASK return false;
    if id == IID_MASKED_STORE || n == "llvm.masked.scatter" {
        decl := get_or_insert_intrinsic_declaration(id, .[vtype(op(ii, 0)), vtype(new_v)]);
        call_set_arg(ii, 1, new_v);
        call_set_called_function(ii, decl);
        return true;
    }
    if n == "llvm.prefetch" || n == "llvm.is.constant" {
        decl := get_or_insert_intrinsic_declaration(id, .[vtype(new_v)]);
        call_set_arg(ii, 0, new_v);
        call_set_called_function(ii, decl);
        return true;
    }
    if n == "llvm.fake.use" { replace_uses_of_with(ii, old_v, new_v); return true; }
    if n == "llvm.lifetime.start" || n == "llvm.lifetime.end" {
        new_v = strip_pointer_casts(new_v);
        decl := get_or_insert_intrinsic_declaration(id, .[vtype(new_v)]);
        call_set_arg(ii, 0, new_v);
        call_set_called_function(ii, decl);
        return true;
    }
    return false;   // TTI->rewriteIntrinsicWithAddressSpace: nullptr
}

// handleMemIntrinsicPtrUse
ias_handle_mem_intrinsic :: (mi: Value_Id, old_v: Value_Id, new_v: Value_Id) -> bool {
    b: Irb; irb_set_before(*b, mi);
    aa := get_aa_metadata(mi);
    id := call_intrinsic(mi);
    nc: Value_Id;
    if is_memset_intrinsic(mi) {
        if id == "llvm.memset.inline" fatal("internal: infer-address-spaces: memset.inline is a MemSetInst (CreateMemSet makes a plain memset)");
        nc = irb_memset(*b, new_v, call_arg(mi, 1), mem_length(mi), call_param_align(mi, 0), false);
    } else {
        src := call_arg(mi, 1); dst := call_arg(mi, 0);
        if src == old_v src = new_v;
        if dst == old_v dst = new_v;
        name := ifx id == "llvm.memcpy.inline" then "llvm.memcpy.inline" else ifx id == "llvm.memmove" then "llvm.memmove" else "llvm.memcpy";
        size := mem_length(mi);
        nc = irb_intrinsic(*b, name, .[vtype(dst), vtype(src), vtype(size)], .[dst, src, size, const_int(ir.t_i1, 0)]);
        da := call_param_align(mi, 0); sa := call_param_align(mi, 1);
        if da add_param_align(nc, 0, da);
        if sa add_param_align(nc, 1, sa);
    }
    set_aa_metadata(nc, aa);
    erase_inst_with_metadata(mi);
    return true;
}

// performPointerReplacement
ias_perform_pointer_replacement :: (s: *Ias, v: Value_Id, new_v: Value_Id, u: Use_Id, dead: *[..] Value_Id) {
    cur := ir.u_user[u];
    // replaceIfSimplePointerUse (hasVolatileVariant is false: volatile accesses keep their pointer)
    if is_inst(cur) {
        o := inst_op(cur);
        pidx: s64 = -1;
        if o == .LOAD pidx = 0;
        else if o == .STORE pidx = 1;
        else if o == .ATOMICRMW || o == .CMPXCHG pidx = 0;
        if pidx >= 0 && !is_volatile(cur) && op(cur, cast(u32) pidx) == v { set_op(cur, cast(u32) pidx, new_v); return; }
    }
    if cur == new_v return;
    if !is_inst(cur) || inst_fn(cur) != s.f return;
    if inst_op(cur) == .CALL && is_mem_intrinsic(cur) {
        if !mem_is_volatile(cur) && ias_handle_mem_intrinsic(cur, v, new_v) return;
    }
    if inst_op(cur) == .CALL && call_iid(cur) != NOT_INTRINSIC {
        if ias_rewrite_intrinsic_operands(cur, v, new_v) return;
    }
    if inst_op(cur) == .ICMP {
        new_as := ias_ptr_as(new_v);
        src_idx := use_operand_no(u);
        other_idx: u32 = ifx src_idx == 0 then cast(u32) 1 else 0;
        other := op(cur, other_idx);
        onv := vmap_lookup(*s.new_as, other);
        if onv != NONE && ias_ptr_as(onv) == new_as {
            set_op(cur, other_idx, onv);
            set_op(cur, src_idx, new_v);
            return;
        }
        if is_constant_kind(vkind(other)) && ias_is_safe_to_cast_const(s, other, new_as) {
            set_op(cur, src_idx, new_v);
            set_op(cur, other_idx, ce_cast(.ADDRSPACECAST, other, vtype(new_v)));
            return;
        }
    }
    if inst_op(cur) == .ADDRSPACECAST {
        if ias_ptr_as(cur) == ias_ptr_as(new_v) {
            rauw_with_metadata(cur, new_v);
            array_add(dead, cur);
            return;
        }
    }
    if is_inst(v) || is_inst(new_v) {
        if is_inst(v) && inst_op(v) == .ADDRSPACECAST return;   // `U == V && isa<AddrSpaceCastInst>(V)`
        pos := ifx is_inst(new_v) then inst(new_v).next else inst(v).next;
        while pos != NONE && inst_op(pos) == .PHI pos = inst(pos).next;
        c := create_cast(.ADDRSPACECAST, new_v, vtype(v));
        bb := ifx is_inst(new_v) then inst_block(new_v) else inst_block(v);
        insert_at_position(c, bb, pos, false);
        replace_uses_of_with(cur, v, c);
    } else {
        replace_uses_of_with(cur, v, ce_cast(.ADDRSPACECAST, new_v, vtype(v)));
    }
}

// rewriteWithNewAddressSpaces
ias_rewrite :: (s: *Ias, post: [] Value_Id) -> bool {
    poison_uses: [..] Ias_Poison_Use; poison_uses.allocator = temp;
    any := false;
    for v: post {
        _, nas := table_find(*s.inferred, v);
        if nas == IAS_UNINIT continue;
        if ias_ptr_as(v) != nas {
            nv := ias_clone_value(s, v, nas, *poison_uses);
            if nv != NONE { vmap_set(*s.new_as, v, nv); any = true; }
        }
    }
    if !any return false;
    for pu: poison_uses {
        nv := vmap_lookup(*s.new_as, pu.user);
        if nv == NONE continue;
        assert(vkind(op(nv, pu.opno)) == .C_POISON);
        set_op(nv, pu.opno, vmap_lookup(*s.new_as, pu.val));
    }
    dead: [..] Value_Id; dead.allocator = temp;
    for v_in: post {
        v := v_in;
        nv := vmap_lookup(*s.new_as, v);
        if nv == NONE continue;
        if is_constant_kind(vkind(v)) {
            c := v;
            rep := ce_cast(.ADDRSPACECAST, nv, vtype(c));
            if c != rep {
                work: [..] Value_Id; work.allocator = temp;
                for user: sx_users(c) {
                    if is_inst(user) { if inst_fn(user) == s.f replace_uses_of_with(user, c, rep); }
                    else for uu: sx_users(user) array_add(*work, uu);
                }
                if work.count {
                    vm: Value_Map; vmap_init(*vm);
                    vmap_set(*vm, c, rep);
                    seen: Table(Value_Id, bool); seen.allocator = temp;
                    for work table_set(*seen, it, true);
                    while work.count {
                        uu := pop(*work);
                        if is_inst(uu) {
                            if inst_fn(uu) == s.f remap_instruction(*vm, uu, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
                            continue;
                        }
                        for u2: sx_users(uu) if !table_contains(*seen, u2) { table_set(*seen, u2, true); array_add(*work, u2); }
                    }
                }
                v = rep;
            }
        }
        u := ir.v_first_use[v];
        while u != NONE {
            cur_use := u;
            user := ir.u_user[u];
            u = ir.u_next[u];
            while u != NONE && ir.u_user[u] == user u = ir.u_next[u];   // skipToNextUser
            ias_perform_pointer_replacement(s, v, nv, cur_use, *dead);
        }
        if !has_uses(v) && is_inst(v) array_add(*dead, v);
    }
    for dead recursively_delete_trivially_dead_value(it);
    return true;
}

infer_address_spaces_run :: (f: Value_Id) -> Preserved {
    s: Ias;
    s.f = f;
    get_assumption_cache(f);   // AM.getResult<AssumptionAnalysis>(F)
    s.tti = tti_get(f);
    s.fas = IAS_UNINIT;
    if ias_cl.assume_default_is_flat s.fas = 0;
    if s.fas == IAS_UNINIT return PRESERVE_ALL;   // getFlatAddressSpace: -1 on x86 and without a target
    s.visited.allocator = temp; s.inferred.allocator = temp;
    vmap_init(*s.new_as);
    post := ias_collect_flat_address_expressions(*s);
    ias_infer(*s, post);
    if !ias_rewrite(*s, post) return PRESERVE_ALL;
    pa := preserved_cfg();
    preserve(*pa, .DOMTREE);
    return pa;
}
