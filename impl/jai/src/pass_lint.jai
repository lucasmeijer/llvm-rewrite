// Lint: a port of llvm/lib/Analysis/Lint.cpp (LintPass::run, the Lint InstVisitor, findValue/findValueImpl, isZero)
// plus FindInsertedValue (llvm/lib/Analysis/ValueTracking.cpp; without InsertBefore) and the
// FindAvailableLoadedValue(Load, ScanBB, ScanFrom, ...) overload (llvm/lib/Analysis/Loads.cpp).
// The messages go to stderr (dbgs()) after each function. `lint<abort-on-error>` reports a fatal error when a
// function produced any message.

Lint_State :: struct {
    f: Value_Id;
    sb: String_Builder;
    aar: Aa_Results;
    dt: *Dom_Tree;
    ac: *Assumption_Cache;
    amdgpu: bool;
}

LINT_READ :: 1; LINT_WRITE :: 2; LINT_CALLEE :: 4; LINT_BRANCHEE :: 8;

lint_check_failed :: (l: *Lint_State, msg: string, v: Value_Id = NONE) {
    append(*l.sb, msg); append(*l.sb, "\n");
    if v == NONE return;
    if is_inst(v) {
        append(*l.sb, inst_to_string(v));
    } else {
        // printAsOperand(OS, true, Mod)
        printer_begin_function(l.f);
        start := W.buf.count;
        write_operand(v, true);
        append(*l.sb, slice_of_buf(start));
        W.buf.count = start;
    }
    append(*l.sb, "\n");
}

// CastInst::isNoopCast(Opcode, SrcTy, DstTy, DL)
lint_is_noop_cast :: (o: Opcode, src: Type_Id, dst: Type_Id) -> bool {
    if o == .BITCAST return true;
    if o == .PTRTOINT || o == .PTRTOADDR return dl_type_size_bits(scalar_type(dl_int_ptr_type(src))) == dl_type_size_bits(scalar_type(dst));
    if o == .INTTOPTR return dl_type_size_bits(scalar_type(dl_int_ptr_type(dst))) == dl_type_size_bits(scalar_type(src));
    return false;
}

// FindInsertedValue(V, idx_range) without an insertion point
find_inserted_value :: (v: Value_Id, idx: [] u32) -> Value_Id {
    if idx.count == 0 return v;
    if is_const(v) {
        c := cf_elt(v, idx[0]);
        if c == NONE return NONE;
        return find_inserted_value(c, array_view(idx, 1));
    }
    if is_inst(v) && inst_op(v) == .INSERTVALUE {
        r := inst(v);
        req := 0;
        for k: 0..cast(s64) r.nidx - 1 {
            if req == idx.count return NONE;   // a nested part: needs inserted insertvalues
            if idx[req] != ir.u32_pool[r.idx + k] return find_inserted_value(op(v, 0), idx);
            req += 1;
        }
        return find_inserted_value(op(v, 1), array_view(idx, req));
    }
    if is_inst(v) && inst_op(v) == .EXTRACTVALUE {
        r := inst(v);
        all: [..] u32; all.allocator = temp;
        for k: 0..cast(s64) r.nidx - 1 array_add(*all, ir.u32_pool[r.idx + k]);
        for idx array_add(*all, it);
        return find_inserted_value(op(v, 0), all);
    }
    return NONE;
}

// findValue / findValueImpl
lint_find_value :: (l: *Lint_State, v: Value_Id, offset_ok: bool) -> Value_Id {
    visited: [..] Value_Id; visited.allocator = temp;
    return lint_find_value_impl(l, v, offset_ok, *visited);
}
lint_find_value_impl :: (l: *Lint_State, v_in: Value_Id, offset_ok: bool, visited: *[..] Value_Id) -> Value_Id {
    if array_find(visited.*, v_in) return const_poison(vtype(v_in));
    array_add(visited, v_in);
    v := ifx offset_ok then get_underlying_object(v_in) else strip_pointer_casts(v_in);
    if is_inst(v) {
        o := inst_op(v);
        if o == .LOAD {
            // FindAvailableLoadedValue(L, BB, BBI, DefMaxInstsToScan, &BatchAA) walking up unique predecessors
            bbi := v;
            bb := inst_block(v);
            visited_blocks: [..] Value_Id; visited_blocks.allocator = temp;
            aaq := aa_query_new(*l.aar);
            while true {
                if array_find(visited_blocks, bb) break;
                array_add(*visited_blocks, bb);
                u: Value_Id = NONE;
                if is_unordered(v) {
                    u, bbi = find_available_ptr_load_store(mloc_get(v), vtype(v), inst(v).ord1 != 0, bb, bbi, def_max_insts_to_scan, aaq, null, null);
                }
                if u != NONE return lint_find_value_impl(l, u, offset_ok, visited);
                if bbi != block_first(bb) break;
                bb = block_unique_predecessor(bb);
                if bb == NONE break;
                bbi = NONE;
            }
        } else if o == .PHI {
            w := phi_has_constant_value(v);
            if w != NONE return lint_find_value_impl(l, w, offset_ok, visited);
        } else if is_cast_op(o) {
            if cast_is_noop(v) return lint_find_value_impl(l, op(v, 0), offset_ok, visited);
        } else if o == .EXTRACTVALUE {
            r := inst(v);
            idx: [..] u32; idx.allocator = temp;
            for k: 0..cast(s64) r.nidx - 1 array_add(*idx, ir.u32_pool[r.idx + k]);
            w := find_inserted_value(op(v, 0), idx);
            if w != NONE && w != v return lint_find_value_impl(l, w, offset_ok, visited);
        }
    } else if vkind(v) == .C_EXPR {
        o := cexpr(v).op;
        if is_cast_op(o) && lint_is_noop_cast(o, vtype(op(v, 0)), vtype(v)) return lint_find_value_impl(l, op(v, 0), offset_ok, visited);
    }
    if is_inst(v) {
        q: Simplify_Query; q.dt = l.dt; q.ac = l.ac;
        w := simplify_instruction(v, sq_with_instruction(q, v));
        if w != NONE return lint_find_value_impl(l, w, offset_ok, visited);
    } else if is_const(v) {
        w := cfo_constant(v);
        if w != v return lint_find_value_impl(l, w, offset_ok, visited);
    }
    return v;
}

lint_is_const_int_eq :: (v: Value_Id, minus_one: bool) -> bool {
    if vkind(v) != .C_INT || type_kind(vtype(v)) != .INT return false;
    a := const_ap(v);
    return ifx minus_one then ap_is_all_ones(a) else ap_is_one(a);
}

// AMDGPU::isConstantAddressSpace
lint_amdgpu_const_as :: (as: u32) -> bool { return as == 4 || as == 6; }

// visitMemoryReference. `align` 0 = none; `ty` NONE = none.
lint_visit_memory_reference :: (l: *Lint_State, i: Value_Id, loc: Mem_Loc, align_in: u64, ty: Type_Id, flags: u32) {
    if ls_is_zero(loc.size) return;
    ptr := loc.ptr;
    uo := lint_find_value(l, ptr, true);
    if vkind(uo) == .C_NULL { lint_check_failed(l, "Undefined behavior: Null pointer dereference", i); return; }
    if is_undef_value(uo) { lint_check_failed(l, "Undefined behavior: Undef pointer dereference", i); return; }
    if lint_is_const_int_eq(uo, true) { lint_check_failed(l, "Unusual: All-ones pointer dereference", i); return; }
    if lint_is_const_int_eq(uo, false) { lint_check_failed(l, "Unusual: Address one pointer dereference", i); return; }
    uk := vkind(uo);
    if flags & LINT_WRITE {
        if l.amdgpu && is_ptr_type(vtype(uo)) && lint_amdgpu_const_as(cast(u32) type_addrspace(vtype(uo))) {
            lint_check_failed(l, "Undefined behavior: Write to memory in const addrspace", i); return;
        }
        if uk == .GLOBAL_VAR && glob(uo).is_const { lint_check_failed(l, "Undefined behavior: Write to read-only memory", i); return; }
        if uk == .FUNCTION || uk == .C_BLOCKADDR { lint_check_failed(l, "Undefined behavior: Write to text section", i); return; }
    }
    if flags & LINT_READ {
        if uk == .FUNCTION { lint_check_failed(l, "Unusual: Load from function body", i); return; }
        if uk == .C_BLOCKADDR { lint_check_failed(l, "Undefined behavior: Load from block address", i); return; }
    }
    if flags & LINT_CALLEE {
        if uk == .C_BLOCKADDR { lint_check_failed(l, "Undefined behavior: Call to block address", i); return; }
    }
    if flags & LINT_BRANCHEE {
        if is_const(uo) && uk != .C_BLOCKADDR { lint_check_failed(l, "Undefined behavior: Branch to non-blockaddress", i); return; }
    }
    base, offset := get_pointer_base_with_constant_offset(ptr);
    if base != NONE {
        UNKNOWN :: 0xFFFF_FFFF_FFFF_FFFF;
        base_size: u64 = UNKNOWN;
        base_align: u64 = 0;
        if is_inst(base) && inst_op(base) == .ALLOCA {
            if !type_is_scalable(inst(base).ty2) {
                ok, sz := alloca_allocation_size(base);
                if ok base_size = sz;
            }
            base_align = inst(base).align;
        } else if vkind(base) == .GLOBAL_VAR {
            if gv_has_definitive_initializer(base) {
                gty := glob(base).value_type;
                if type_is_sized(gty) base_size = dl_type_alloc_size(gty);
                base_align = glob(base).align;
                if base_align == 0 && type_is_sized(gty) base_align = dl_abi_align(gty);
            }
        }
        sz := loc.size;
        if !(!ls_has_value(sz) || ls_is_scalable(sz) || base_size == UNKNOWN || (offset >= 0 && cast(u64) offset + ls_value(sz) <= base_size)) {
            lint_check_failed(l, "Undefined behavior: Buffer overflow", i); return;
        }
        align := align_in;
        if align == 0 && ty != NONE && type_is_sized(ty) align = dl_abi_align(ty);
        if base_align != 0 && align != 0 {
            if !(align <= common_alignment(base_align, cast(u64) offset)) {
                lint_check_failed(l, "Undefined behavior: Memory reference address is misaligned", i); return;
            }
        }
    }
}

LINT_ABI_ATTRS :: Attr_Kind.[.ZExt, .SExt, .InReg, .ByVal, .ByRef, .InAlloca, .Preallocated, .StructRet];
LINT_ABI_ATTR_NAMES :: string.["zeroext", "signext", "inreg", "byval", "byref", "inalloca", "preallocated", "sret"];

lint_visit_call_base :: (l: *Lint_State, i: Value_Id) {
    callee := call_callee(i);
    lint_visit_memory_reference(l, i, mloc_after(callee), 0, NONE, LINT_CALLEE);
    f := lint_find_value(l, callee, false);
    nargs := call_num_args(i);
    if vkind(f) == .FUNCTION {
        if inst(i).cc != glob(f).cc { lint_check_failed(l, "Undefined behavior: Caller and callee calling convention differ", i); return; }
        ft := glob(f).value_type;
        np := func_nparams(ft);
        if !(ifx func_vararg(ft) then np <= nargs else np == nargs) {
            lint_check_failed(l, "Undefined behavior: Call argument count mismatches callee argument count", i); return;
        }
        if func_ret(ft) != vtype(i) { lint_check_failed(l, "Undefined behavior: Call return type mismatches callee return type", i); return; }
        for a: 0..cast(s64) nargs - 1 {
            if a >= cast(s64) glob(f).nargs break;
            actual := call_arg(i, cast(u32) a);
            formal := fn_arg(f, cast(u32) a);
            if vtype(formal) != vtype(actual) { lint_check_failed(l, "Undefined behavior: Call argument type mismatches callee parameter type", i); return; }
            fset := fn_param_attr_set(f, cast(u32) a);
            if attr_set_has(fset, .NoAlias) && is_ptr_type(vtype(actual)) {
                formal_ro := attr_set_has(fset, .ReadOnly) || attr_set_has(fset, .ReadNone);
                for b: 0..cast(s64) nargs - 1 {
                    if attr_set_has(attr_list_param(inst(i).attrs, cast(u32) b), .ByVal) continue;
                    if formal_ro && call_data_operand_only_reads(i, cast(u32) b) continue;
                    if call_data_operand_does_not_access(i, cast(u32) b) continue;
                    bv := call_arg(i, cast(u32) b);
                    if a != b && is_ptr_type(vtype(bv)) && vkind(bv) != .C_NULL {
                        r := aa_alias(aa_query_new(*l.aar), mloc_before_or_after(actual), mloc_before_or_after(bv));
                        if r.kind == AR_MUST || r.kind == AR_PARTIAL { lint_check_failed(l, "Unusual: noalias argument aliases another argument", i); return; }
                    }
                }
            }
            sret := attr_set_find(fset, .StructRet);
            if sret && is_ptr_type(vtype(actual)) {
                ty := sret.ty;
                lint_visit_memory_reference(l, i, mloc(actual, ls_precise(dl_type_store_size(ty))), dl_abi_align(ty), ty, LINT_READ | LINT_WRITE);
            }
            cset := attr_list_param(inst(i).attrs, cast(u32) a);
            for kind, ki: LINT_ABI_ATTRS {
                ca := attr_set_find(cset, kind);
                fa := attr_set_find(fset, kind);
                if (ca != null) != (fa != null) {
                    lint_check_failed(l, tprint("Undefined behavior: ABI attribute % not present on both function and call-site", LINT_ABI_ATTR_NAMES[ki]), i); return;
                }
                if ca && fa && !attr_equal(ca, fa) {
                    lint_check_failed(l, tprint("Undefined behavior: ABI attribute % does not have same argument for function and call-site", LINT_ABI_ATTR_NAMES[ki]), i); return;
                }
            }
        }
    }
    tail_kind := (inst(i).flags >> TAIL_SHIFT) & 3;
    if inst_op(i) == .CALL && (tail_kind == 1 || tail_kind == 2) {   // CallInst::isTailCall
        for a: 0..cast(s64) nargs - 1 {
            if attr_set_has(attr_list_param(inst(i).attrs, cast(u32) a), .ByVal) continue;
            obj := lint_find_value(l, call_arg(i, cast(u32) a), true);
            if is_inst(obj) && inst_op(obj) == .ALLOCA { lint_check_failed(l, "Undefined behavior: Call with \"tail\" keyword references alloca", i); return; }
        }
    }
    if inst_op(i) != .CALL return;   // IntrinsicInst is a CallInst
    id := call_iid(i);
    if id == {
        case IID_MEMCPY; #through;
        case IID_MEMCPY_INLINE;
            lint_visit_memory_reference(l, i, mloc_for_dest(i), mi_param_align(i, 0), NONE, LINT_WRITE);
            lint_visit_memory_reference(l, i, mloc_for_source(i), mi_param_align(i, 1), NONE, LINT_READ);
            size := LS_AFTER;
            len := lint_find_value(l, call_arg(i, 2), false);
            if vkind(len) == .C_INT && type_kind(vtype(len)) == .INT && ap_active_bits(const_ap(len)) <= 32 size = ls_precise(ap_zext_value(const_ap(len)));
            r := aa_alias(aa_query_new(*l.aar), mloc(call_arg(i, 1), size), mloc(call_arg(i, 0), size));
            if r.kind == AR_MUST { lint_check_failed(l, "Undefined behavior: memcpy source and destination overlap", i); return; }
        case IID_MEMMOVE;
            lint_visit_memory_reference(l, i, mloc_for_dest(i), mi_param_align(i, 0), NONE, LINT_WRITE);
            lint_visit_memory_reference(l, i, mloc_for_source(i), mi_param_align(i, 1), NONE, LINT_READ);
        case IID_MEMSET; #through;
        case IID_MEMSET_INLINE;
            lint_visit_memory_reference(l, i, mloc_for_dest(i), mi_param_align(i, 0), NONE, LINT_WRITE);
        case IID_VASTART;
            lint_visit_memory_reference(l, i, mloc_for_argument(i, 0, true), 0, NONE, LINT_READ | LINT_WRITE);
        case IID_VACOPY;
            lint_visit_memory_reference(l, i, mloc_for_argument(i, 0, true), 0, NONE, LINT_WRITE);
            lint_visit_memory_reference(l, i, mloc_for_argument(i, 1, true), 0, NONE, LINT_READ);
        case IID_VAEND;
            lint_visit_memory_reference(l, i, mloc_for_argument(i, 0, true), 0, NONE, LINT_READ | LINT_WRITE);
        case IID_STACKRESTORE;
            lint_visit_memory_reference(l, i, mloc_for_argument(i, 0, true), 0, NONE, LINT_READ | LINT_WRITE);
    }
}

// isZero
lint_is_zero :: (l: *Lint_State, v: Value_Id) -> bool {
    if is_undef_value(v) return true;
    t := vtype(v);
    tk := type_kind(t);
    if tk != .VECTOR && tk != .SVECTOR {
        q: Simplify_Query; q.dt = l.dt; q.ac = l.ac;
        if is_inst(v) q.cxt = v;
        return kb_is_zero(known_bits(v, q));
    }
    if !is_const(v) return false;
    if is_null_value(v) return true;
    if tk == .SVECTOR fatal("lint: isZero of a non-null scalable vector constant (cast<FixedVectorType> in LLVM)");
    for k: 0..cast(s64) type_count(t) - 1 {
        e := cf_elt(v, cast(u64) k);
        if is_undef_value(e) return true;
        q: Simplify_Query;
        if kb_is_zero(known_bits(e, q)) return true;
    }
    return false;
}

lint_visit_inst :: (l: *Lint_State, i: Value_Id) {
    o := inst_op(i);
    if o == {
        case .CALL; #through;
        case .INVOKE; #through;
        case .CALLBR; lint_visit_call_base(l, i);
        case .RET;
            if fn_has_fn_attr(l.f, .NoReturn) { lint_check_failed(l, "Unusual: Return statement in function with noreturn attribute", i); return; }
            if nops(i) > 0 {
                obj := lint_find_value(l, op(i, 0), true);
                if is_inst(obj) && inst_op(obj) == .ALLOCA { lint_check_failed(l, "Unusual: Returning alloca value", i); return; }
            }
        case .LOAD; lint_visit_memory_reference(l, i, mloc_get(i), inst(i).align, vtype(i), LINT_READ);
        case .STORE; #through;
        case .CMPXCHG; #through;
        case .ATOMICRMW; lint_visit_memory_reference(l, i, mloc_get(i), inst(i).align, vtype(op(i, 0)), LINT_WRITE);
        case .XOR;
            if is_undef_value(op(i, 0)) && is_undef_value(op(i, 1)) lint_check_failed(l, "Undefined result: xor(undef, undef)", i);
        case .SUB;
            if is_undef_value(op(i, 0)) && is_undef_value(op(i, 1)) lint_check_failed(l, "Undefined result: sub(undef, undef)", i);
        case .LSHR; #through;
        case .ASHR; #through;
        case .SHL;
            c := lint_find_value(l, op(i, 1), false);
            ct := vtype(c);
            if vkind(c) == .C_INT && type_kind(ct) == .SVECTOR && !opts.use_constant_int_for_scalable_splat {
                // a ConstantExpr splat in LLVM: not a ConstantInt
            } else if vkind(c) == .C_INT && type_kind(scalar_type(ct)) == .INT {
                // a vector ConstantInt (-use-constant-int-for-*-splat): cast<IntegerType>(I.getType()) of a vector
                // type is undefined behaviour in LLVM
                if type_kind(vtype(i)) != .INT fatal("lint: shift of a vector by a vector ConstantInt splat (cast<IntegerType> of a vector type in LLVM)");
                if !ap_ult_u64(const_ap(c), type_bits(vtype(i))) lint_check_failed(l, "Undefined result: Shift count out of range", i);
            }
        case .SDIV; #through;
        case .UDIV; #through;
        case .SREM; #through;
        case .UREM;
            if lint_is_zero(l, op(i, 1)) lint_check_failed(l, "Undefined behavior: Division by zero", i);
        case .ALLOCA;
            if vkind(op(i, 0)) == .C_INT && inst_block(i) != fn_entry(l.f) lint_check_failed(l, "Pessimization: Static alloca outside of entry block", i);
        case .VAARG; lint_visit_memory_reference(l, i, mloc_get(i), 0, NONE, LINT_READ | LINT_WRITE);
        case .INDIRECTBR;
            lint_visit_memory_reference(l, i, mloc_after(op(i, 0)), 0, NONE, LINT_BRANCHEE);
            if nops(i) <= 1 lint_check_failed(l, "Undefined behavior: indirectbr with no destinations", i);
        case .EXTRACTELEMENT;
            c := lint_find_value(l, op(i, 1), false);
            if vkind(c) == .C_INT && type_kind(vtype(c)) == .INT {
                vt := vtype(op(i, 0));
                if !(type_kind(vt) == .SVECTOR || ap_ult_u64(const_ap(c), type_count(vt))) lint_check_failed(l, "Undefined result: extractelement index out of range", i);
            }
        case .INSERTELEMENT;
            c := lint_find_value(l, op(i, 2), false);
            if vkind(c) == .C_INT && type_kind(vtype(c)) == .INT {
                vt := vtype(i);
                if !(type_kind(vt) == .SVECTOR || ap_ult_u64(const_ap(c), type_count(vt))) lint_check_failed(l, "Undefined result: insertelement index out of range", i);
            }
        case .UNREACHABLE;
            p := inst_prev(i);
            if !(p == NONE || may_have_side_effects(p))
                lint_check_failed(l, "Unusual: unreachable immediately preceded by instruction without side effects", i);
    }
}

lint_run :: (f: Value_Id, abort_on_error: bool) -> Preserved {
    l: Lint_State;
    l.f = f;
    l.sb.allocator = temp;
    l.aar = aa_results_for(f);
    l.ac = get_assumption_cache(f);
    l.dt = get_domtree(f);
    l.amdgpu = begins_with(ir.triple, "amdgcn") || begins_with(ir.triple, "r600");
    // visitFunction
    if vname(f) == "" && !is_local_linkage(glob(f).linkage) lint_check_failed(*l, "Unusual: Unnamed function with non-local linkage", f);
    for bb: fn_blocks(f) for i: block_insts(bb) lint_visit_inst(*l, i);
    msg := builder_to_string(*l.sb,, allocator = temp);
    write_string(msg, to_standard_error = true);
    if abort_on_error && msg.count > 0 {
        write_string("LLVM ERROR: linter found errors, aborting. (enabled by abort-on-error)\n", to_standard_error = true);
        exit(1);
    }
    return PRESERVE_ALL;
}
