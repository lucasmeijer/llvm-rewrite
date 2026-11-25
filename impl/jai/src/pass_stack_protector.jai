// StackProtector, the IR part: a port of llvm/lib/CodeGen/StackProtector.cpp (SSPLayoutAnalysis::requiresStackProtector,
// ContainsProtectableArray, HasAddressTaken, InsertStackProtectors, CreatePrologue, getStackGuard, CreateFailBB) and of
// isInTailCallPosition / returnTypeIsEligibleForTailCall / attributesPermitTailCall (llvm/lib/CodeGen/Analysis.cpp; the
// aggregate return-value path of slotOnlyDiscardsData fails loudly). The x86 target hooks are in hardening_target.jai.
// The SSP layout map (MachineFrameInfo's object layouts) only feeds codegen and is not built.

sp_cl: struct {
    enable_selectiondag_sp := true;   // -enable-selectiondag-sp
    disable_check_noreturn := false;  // -disable-check-noreturn-call
};
stack_protector_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "enable-selectiondag-sp"; sp_cl.enable_selectiondag_sp = smisc_bool(name, value, has_value);
        case "disable-check-noreturn-call"; sp_cl.disable_check_noreturn = smisc_bool(name, value, has_value);
        case "safe-stack-coloring"; ss_cl.coloring = smisc_bool(name, value, has_value);
        case "safe-stack-layout"; ss_cl.layout = smisc_bool(name, value, has_value);
        case "safestack-use-pointer-address"; ss_cl.use_pointer_address = smisc_bool(name, value, has_value);
        case; return false;
    }
    return true;
}

// Function::getFnAttributeAsParsedInteger: fn_attr_as_parsed_integer (omp_ir_builder.jai)

// ContainsProtectableArray
sp_contains_protectable_array :: (ty: Type_Id, ssp_buffer_size: u64, is_large: *bool, strong: bool, in_struct: bool) -> bool {
    if ty == NONE return false;
    if type_kind(ty) == .ARRAY {
        et := type_elem(ty);
        if !(type_kind(et) == .INT && ir.types[et].a == 8) {
            t := triple_parse(ir.triple);
            if !strong && (in_struct || !triple_is_os_darwin(*t)) return false;
        }
        if ssp_buffer_size <= dl_type_alloc_size(ty) { is_large.* = true; return true; }
        if strong return true;
    }
    if type_kind(ty) != .STRUCT return false;
    needs := false;
    n := type_nsub(ty);
    for k: 0..cast(s64) n - 1 {
        if sp_contains_protectable_array(type_sub(ty, cast(u32) k), ssp_buffer_size, is_large, strong, true) {
            if is_large.* return true;
            needs = true;
        }
    }
    return needs;
}

// TypeSize: a known minimum and the scalable flag (TypeSize::isKnownGE / isKnownGT)
Sp_Size :: struct { min: u64; scalable: bool; }
ts_known_ge :: (l: Sp_Size, r: Sp_Size) -> bool { if l.scalable || !r.scalable return l.min >= r.min; return false; }
ts_known_gt :: (l: Sp_Size, r: Sp_Size) -> bool { if l.scalable || !r.scalable return l.min > r.min; return false; }

Sp_Phi_Info :: struct { size: Sp_Size; num_decreased: u32; }

// HasAddressTaken
sp_has_address_taken :: (ai: Value_Id, alloc_size: Sp_Size, phis: *Table(Value_Id, Sp_Phi_Info)) -> bool {
    u := ir.v_first_use[ai];
    while u != NONE {
        defer u = ir.u_next[u];
        i := ir.u_user[u];
        if !is_inst(i) fatal("stack-protector: a non-instruction user of an alloca");
        okm, ml := mloc_get_or_none(i);
        if okm && ls_has_value(ml.size) {
            ms := Sp_Size.{ls_value(ml.size), ls_is_scalable(ml.size)};
            if !ts_known_ge(alloc_size, ms) return true;
        }
        o := inst_op(i);
        if o == {
            case .STORE; if op(i, 0) == ai return true;
            case .CMPXCHG; if op(i, 2) == ai return true;
            case .ATOMICRMW; if op(i, 1) == ai return true;
            case .PTRTOINT; if op(i, 0) == ai return true;
            case .CALL; if !is_debug_or_pseudo_inst(i) && !is_lifetime_start_or_end(i) return true;
            case .INVOKE; return true;
            case .GEP;
                bits := dl_index_bits(vtype(i));
                ok, off := gep_accumulate_constant_offset(i, ap_zero(bits));
                if !ok return true;
                offset_size := Sp_Size.{ap_limited_u64(off), false};
                if !ts_known_gt(alloc_size, offset_size) return true;
                // TypeSize::getFixed(AllocSize.getKnownMinValue()) - OffsetSize: a fixed size
                if sp_has_address_taken(i, .{alloc_size.min - offset_size.min, false}, phis) return true;
            case .BITCAST; #through; case .SELECT; #through; case .ADDRSPACECAST;
                if sp_has_address_taken(i, alloc_size, phis) return true;
            case .PHI;
                p := table_find_pointer(phis, i);
                if p {
                    if ts_known_ge(alloc_size, p.size) continue;
                    if p.num_decreased == 3 return true;
                    p.size = alloc_size;
                    p.num_decreased += 1;
                } else table_set(phis, i, .{alloc_size, 0});
                if sp_has_address_taken(i, alloc_size, phis) return true;
            case .LOAD; #through; case .RET;
            case; return true;
        }
    }
    return false;
}
ap_limited_u64 :: (a: APInt) -> u64 { if !ap_fits_u64(a) return 0xFFFF_FFFF_FFFF_FFFF; return ap_word(a, 0); }

// SSPLayoutAnalysis::requiresStackProtector (with a Layout map: no early return once a protector is needed)
sp_requires_stack_protector :: (f: Value_Id) -> bool {
    strong, needs := false, false;
    ssp_buffer_size := fn_attr_as_parsed_integer(f, "stack-protector-buffer-size", 8);
    if fn_has_fn_attr(f, .SafeStack) return false;
    if fn_has_fn_attr(f, .StackProtectReq) { needs = true; strong = true; }
    else if fn_has_fn_attr(f, .StackProtectStrong) strong = true;
    else if !fn_has_fn_attr(f, .StackProtect) return false;
    phis: Table(Value_Id, Sp_Phi_Info); phis.allocator = temp;
    spk := md_kind_id_lookup("stack-protector");
    for i: fn_insts(f) {
        if inst_op(i) != .ALLOCA continue;
        if spk != NONE {
            m := get_metadata(i, spk);
            if m != NONE {
                v := md_value_of(md_op(m, 0));
                if v != NONE && vkind(v) == .C_INT && const_int_zext(v) == 0 continue;
            }
        }
        n := op(i, 0);
        if !(vkind(n) == .C_INT && const_int_zext(n) == 1) {   // isArrayAllocation
            if vkind(n) == .C_INT {
                if ap_limited_u64(const_ap(n)) >= ssp_buffer_size needs = true;
                else if strong needs = true;
            } else needs = true;
            continue;
        }
        is_large := false;
        if sp_contains_protectable_array(inst(i).ty2, ssp_buffer_size, *is_large, strong, false) { needs = true; continue; }
        if strong {
            // AllocaInst::getAllocationSize: the type's alloc size times a constant array size (scalable kept)
            ty := inst(i).ty2;
            ok, size := alloca_allocation_size(i);
            if !ok || sp_has_address_taken(i, .{size, type_is_scalable(ty)}, *phis) needs = true;
        }
        table_reset(*phis);
    }
    return needs;
}

// getStackGuard
sp_get_stack_guard :: (h: *Hd_Target, b: *Irb, supports_sdag: *bool) -> Value_Id {
    guard := hd_ir_stack_guard(h);
    mode := module_flag_string("stack-protector-guard");
    if (mode == "tls" || mode.count == 0) && guard != NONE
        return irb_load(b, type_ptr(0), guard, dl_abi_align(type_ptr(0)), true, "StackGuard");
    if supports_sdag supports_sdag.* = true;
    hd_insert_ssp_declarations(h);
    return irb_call(b, get_or_insert_intrinsic_declaration(intrinsic_id_by_name("llvm.stackguard")), .[]);
}

// isInTailCallPosition(Call, TM) for the call right before the check location
sp_is_in_tail_call_position :: (call: Value_Id) -> bool {
    bb := inst_block(call);
    term := block_terminator(bb);
    is_ret := inst_op(term) == .RET;
    if !is_ret {
        cc := inst(call).cc;
        if (cc != CC_TAIL && cc != CC_SWIFTTAIL) || inst_op(term) != .UNREACHABLE return false;
    }
    x := inst(term).prev;
    while true {
        if x == call break;
        if !is_debug_or_pseudo_inst(x) {
            id := call_iid(x);
            if !(id == IID_LIFETIME_END || id == IID_ASSUME || id == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL || id == intrinsic_id_by_name("llvm.fake.use")) {
                if may_have_side_effects(x) || may_read_from_memory(x) || !is_safe_to_speculatively_execute(x) return false;
            }
        }
        x = inst(x).prev;
    }
    // returnTypeIsEligibleForTailCall
    if !is_ret || nops(term) == 0 return true;
    rv := op(term, 0);
    if vkind(rv) == .C_UNDEF || vkind(rv) == .C_POISON return true;
    // attributesPermitTailCall
    benign :: Attr_Kind.[.Alignment, .Dereferenceable, .DereferenceableOrNull, .NoAlias, .NonNull, .NoUndef, .Range, .NoFPClass];
    f := inst_fn(call);
    caller := attr_list_ret(glob(f).attrs);
    callee := attr_list_ret(inst(call).attrs);
    for benign { caller = attr_set_remove(caller, it); callee = attr_set_remove(callee, it); }
    if attr_set_has(caller, .ZExt) {
        if !attr_set_has(callee, .ZExt) return false;
        caller = attr_set_remove(caller, .ZExt); callee = attr_set_remove(callee, .ZExt);
    } else if attr_set_has(caller, .SExt) {
        if !attr_set_has(callee, .SExt) return false;
        caller = attr_set_remove(caller, .SExt); callee = attr_set_remove(callee, .SExt);
    }
    if !has_uses(call) { callee = attr_set_remove(callee, .SExt); callee = attr_set_remove(callee, .ZExt); }
    if caller != callee return false;
    k := type_kind(vtype(rv));
    if k == .STRUCT || k == .ARRAY fatal("stack-protector: tail-call position of an aggregate return value is not supported yet");
    if rv == call return true;
    fatal("stack-protector: tail-call position check of a returned value other than the call is not supported yet");
    return false;
}
CC_TAIL :: 18; CC_SWIFTTAIL :: 20;

// CreateFailBB
sp_create_fail_bb :: (h: *Hd_Target, f: Value_Id) -> Value_Id {
    fb := create_block(f, "CallStackCheckFailBlk");
    b: Irb; irb_set_end(*b, fb);
    sp := fn_subprogram(f);
    if sp != NONE b.dbg = di_location_get(0, 0, sp, NONE);
    chk := hd_stack_chk_fail_name(h);
    args: [..] Value_Id; args.allocator = temp;
    fty: Type_Id;
    name: string;
    if chk.count { name = chk; fty = type_func(ir.t_void, .[], false); }
    else {
        ssh := hd_stack_smash_handler_name(h);
        if ssh.count == 0 fatal("no libcall available for stack protector");
        name = ssh; fty = type_func(ir.t_void, .[type_ptr(0)], false);
        array_add(*args, icb_global_string(vname(f), "SSH"));
    }
    // Module::getOrInsertFunction: an existing global value of that name (also an alias) is the callee
    callee := lookup_global(name);
    if callee == NONE callee = get_or_insert_function(name, fty);
    c := irb_call_callee(*b, callee, fty, args);
    call_add_fn_attr(c, .NoReturn);
    u := new_inst(.UNREACHABLE, ir.t_void, 0);
    irb_insert(*b, u);
    return fb;
}
// IRBuilder::CreateCall(FunctionCallee{FTy, Callee}, Args)
irb_call_callee :: (b: *Irb, callee: Value_Id, fty: Type_Id, args: [] Value_Id) -> Value_Id {
    i := new_inst(.CALL, func_ret(fty), cast(u32)(args.count + 1));
    inst(i).ty2 = fty;
    for args set_op(i, cast(u32) it_index, it);
    set_op(i, cast(u32) args.count, callee);
    return irb_insert(b, i);
}

// InsertStackProtectors
sp_insert_stack_protectors :: (h: *Hd_Target, f: Value_Id) -> bool {
    has_prologue := false;
    supports_sdag := hd_use_stack_guard_mix_fp(h) || sp_cl.enable_selectiondag_sp;   // !EnableFastISel in opt
    ai: Value_Id = NONE;
    fail_bb: Value_Id = NONE;
    weights := md_tuple(.[md_string("branch_weights"), md_value(const_int(ir.t_i32, 2048)), md_value(const_int(ir.t_i32, 2147481600))], false);
    bb := glob(f).first_block;
    while bb != NONE {
        next_bb := block(bb).next;
        defer bb = next_bb;
        if bb == fail_bb continue;
        check_loc := block_terminator(bb);
        if check_loc != NONE && inst_op(check_loc) != .RET check_loc = NONE;
        if check_loc == NONE && !sp_cl.disable_check_noreturn {
            for i: block_insts(bb) {
                if call_iid(i) == intrinsic_id_by_name("llvm.eh.sjlj.callsite") { check_loc = i; break; }
                if is_call_base(i) && call_does_not_return(i) && !call_does_not_throw(i) { check_loc = i; break; }
            }
        }
        if check_loc == NONE continue;
        if !has_prologue {
            has_prologue = true;
            // CreatePrologue
            sdag := false;
            entry := fn_entry(f);
            b: Irb; irb_set_before(*b, block_first(entry));
            ai = irb_alloca(*b, type_ptr(0), NONE, "StackGuardSlot");
            gs := sp_get_stack_guard(h, *b, *sdag);
            irb_call(*b, get_or_insert_intrinsic_declaration(intrinsic_id_by_name("llvm.stackprotector")), .[gs, ai]);
            supports_sdag = supports_sdag && sdag;
        }
        if supports_sdag break;
        prev := inst(check_loc).prev;
        if prev != NONE && inst_op(prev) == .CALL && arc_is_tail_call(prev) && sp_is_in_tail_call_position(prev) check_loc = prev;
        if hd_ssp_stack_guard_check(h) != NONE fatal("stack-protector: the MSVC guard check function is not supported yet");
        if fail_bb == NONE fail_bb = sp_create_fail_bb(h, f);
        b: Irb; irb_set_before(*b, check_loc);
        guard := sp_get_stack_guard(h, *b, null);
        li2 := irb_load(*b, type_ptr(0), ai, dl_abi_align(type_ptr(0)), true);
        cmp := irb_icmp(*b, ICMP_NE, guard, li2);
        sbi_if_then_existing(cmp, check_loc, weights, fail_bb);
        bi := block_terminator(inst_block(cmp));
        new_bb := get_successor(bi, 1);
        set_name(new_bb, "SP_return");
        block_move_after(new_bb, bb);
        inst(cmp).pred = icmp_inverse(inst(cmp).pred);
        swap_successors(bi);
    }
    return has_prologue;
}

stack_protector_run :: (f: Value_Id) -> Preserved {
    h := hd_target("stack-protector");
    if !sp_requires_stack_protector(f) return PRESERVE_ALL;
    p := fn_personality(f);
    if p != NONE && is_funclet_eh_personality(classify_eh_personality(p)) return PRESERVE_ALL;
    if !libcall_lowering_info_cached fatal("'LibcallLoweringModuleAnalysis' analysis required");
    changed := sp_insert_stack_protectors(*h, f);
    if !changed return PRESERVE_ALL;
    return PRESERVE_NONE;
}
