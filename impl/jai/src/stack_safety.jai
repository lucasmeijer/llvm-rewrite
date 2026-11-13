// StackSafetyAnalysis: a port of llvm/lib/Analysis/StackSafetyAnalysis.cpp (StackSafetyLocalAnalysis,
// StackSafetyDataFlowAnalysis, createGlobalStackSafetyInfo, StackSafetyGlobalInfo::getInfo / isSafe /
// stackAccessIsSafe) without a ModuleSummaryIndex (the in-module, non-ThinLTO case); StackLifetime is stack_lifetime.jai.
// The global info is computed on the first query (StackSafetyGlobalInfo::getInfo is lazy), from every defined
// function's StackSafetyInfo at that moment; each uses the function's cached ScalarEvolution (get_scev).
// Maps keyed by pointers in LLVM (std::map<const GlobalValue *, ...>, CallInfo::Less) are ordered by value id here;
// only the order of the fixpoint iteration depends on it.

SS_MAX_ITERATIONS :: 20;   // -stack-safety-max-iterations

Ss_Call :: struct { callee: Value_Id; param: u32; range: Const_Range; }
Ss_Use :: struct {
    range: Const_Range;
    unsafe: [..] Value_Id;
    calls: [..] Ss_Call;   // sorted by (param, callee)
}
Ss_Fn :: struct {
    f: Value_Id;
    allocas: [..] Value_Id;
    alloca_uses: [..] Ss_Use;
    params: [..] u32;      // sorted
    param_uses: [..] Ss_Use;
    update_count: s64;
}

Stack_Safety_Global :: struct {
    computed: bool;
    fns: [..] Ss_Fn;
    safe_allocas: Table(Value_Id, bool);
    unsafe_accesses: Table(Value_Id, bool);
}

stack_safety_global_init :: (g: *Stack_Safety_Global) {
    g.computed = false;
    g.fns.allocator = temp;
    g.safe_allocas.allocator = temp;
    g.unsafe_accesses.allocator = temp;
}

stack_safety_is_safe :: (g: *Stack_Safety_Global, ai: Value_Id) -> bool {
    ss_get_info(g);
    return table_find_pointer(*g.safe_allocas, ai) != null;
}
stack_safety_access_is_safe :: (g: *Stack_Safety_Global, i: Value_Id) -> bool {
    ss_get_info(g);
    return table_find_pointer(*g.unsafe_accesses, i) == null;
}

// ---------------------------------------------------------------- ConstantRange helpers

ss_is_unsafe :: (r: Const_Range) -> bool { return cr_is_empty_set(r) || cr_is_full_set(r) || cr_is_upper_sign_wrapped(r); }
ss_add_overflow_never :: (l: Const_Range, r: Const_Range) -> Const_Range {
    if cr_signed_add_may_overflow(l, r) != .NEVER_OVERFLOWS return cr_full(cr_bits(l));
    return cr_add(l, r);
}
ss_union_no_wrap :: (l: Const_Range, r: Const_Range) -> Const_Range {
    res := cr_union(l, r);
    if cr_is_sign_wrapped_set(res) res = cr_full(cr_bits(res));
    return res;
}
ss_use_new :: (bits: u32) -> Ss_Use {
    u: Ss_Use;
    u.range = cr_empty(bits);
    u.unsafe.allocator = temp; u.calls.allocator = temp;
    return u;
}
ss_add_range :: (u: *Ss_Use, i: Value_Id, r: Const_Range, safe: bool) {
    if !safe && !array_find(u.unsafe, i) array_add(*u.unsafe, i);
    u.range = ss_union_no_wrap(u.range, r);
}
ss_call_less :: (a: Ss_Call, param: u32, callee: Value_Id) -> bool {
    if a.param != param return a.param < param;
    return a.callee < callee;
}
// Calls.emplace(CallInfo(Callee, ArgNo), Offsets) (+ unionWith if present)
ss_add_call :: (u: *Ss_Use, callee: Value_Id, param: u32, r: Const_Range, union_if_present: bool) {
    pos := 0;
    while pos < u.calls.count && ss_call_less(u.calls[pos], param, callee) pos += 1;
    if pos < u.calls.count && u.calls[pos].param == param && u.calls[pos].callee == callee {
        if union_if_present u.calls[pos].range = cr_union(u.calls[pos].range, r);
        return;
    }
    array_insert_at(*u.calls, .{callee, param, r}, pos);
}

// getStaticAllocaSizeRange
ss_static_alloca_size_range :: (ai: Value_Id) -> Const_Range {
    ps := dl_ptr_spec(inst(ai).addrspace).bits;
    r := cr_empty(ps);
    ty := inst(ai).ty2;
    if type_is_scalable(ty) return r;
    sz := ap_from_u64(ps, dl_type_alloc_size(ty));
    if ap_is_non_positive(sz) return r;
    n := op(ai, 0);
    if !(vkind(n) == .C_INT && ap_is_one(const_ap(n))) {   // isArrayAllocation
        if vkind(n) != .C_INT return r;
        m := const_ap(n);
        if ap_is_non_positive(m) return r;
        m = ap_sext_or_trunc(m, ps);
        ov: bool;
        sz, ov = ap_smul_ov(sz, m);
        if ov return r;
    }
    return cr_new(ap_zero(ps), sz);
}

// ---------------------------------------------------------------- StackSafetyLocalAnalysis

Ss_Local :: struct {
    f: Value_Id;
    ps: u32;               // PointerSize
    unknown: Const_Range;  // UnknownRange (full)
    sl: *Stack_Lifetime;
}

ss_scev_as_pointer :: (v: Value_Id) -> Scev_Id {
    t := vtype(v);
    if !is_ptr_type(t) return sc_get_truncate_or_zero_extend(sc_get_scev(v), type_ptr(0));
    if ir.types[t].a != 0 return NONE;
    return sc_get_scev(v);
}

// offsetFrom(Addr, Base)
ss_offset_from :: (l: *Ss_Local, addr: Value_Id, base: Value_Id) -> Const_Range {
    if !sc_is_scevable(vtype(addr)) || !sc_is_scevable(vtype(base)) return l.unknown;
    ae := ss_scev_as_pointer(addr);
    be := ss_scev_as_pointer(base);
    if ae == NONE || be == NONE return l.unknown;
    diff := sc_get_minus(ae, be);
    if sc_is_cnc(diff) return l.unknown;
    off := sc_signed_range(diff);
    if ss_is_unsafe(off) return l.unknown;
    return cr_sext_or_trunc(off, l.ps);
}

ss_access_range_r :: (l: *Ss_Local, addr: Value_Id, base: Value_Id, size_range: Const_Range) -> Const_Range {
    if cr_is_empty_set(size_range) return cr_empty(l.ps);
    offs := ss_offset_from(l, addr, base);
    if ss_is_unsafe(offs) return l.unknown;
    offs = ss_add_overflow_never(offs, size_range);
    if ss_is_unsafe(offs) return l.unknown;
    return offs;
}
ss_access_range_size :: (l: *Ss_Local, addr: Value_Id, base: Value_Id, size: u64, scalable: bool) -> Const_Range {
    if scalable return l.unknown;
    aps := ap_from_u64(l.ps, size);
    if ap_is_negative(aps) return l.unknown;
    return ss_access_range_r(l, addr, base, cr_new(ap_zero(l.ps), aps));
}

ss_mem_intrinsic_access_range :: (l: *Ss_Local, mi: Value_Id, u: Use_Id, base: Value_Id) -> Const_Range {
    v := ir.u_val[u];
    id := call_iid(mi);
    is_transfer := id == IID_MEMCPY || id == IID_MEMCPY_INLINE || id == IID_MEMMOVE;
    if is_transfer { if op_use(mi, 1) != u && op_use(mi, 0) != u return cr_empty(l.ps); }
    else { if op_use(mi, 0) != u return cr_empty(l.ps); }
    len := op(mi, 2);
    if !sc_is_scevable(vtype(len)) return l.unknown;
    calc := type_int(l.ps);
    e := sc_get_truncate_or_zero_extend(sc_get_scev(len), calc);
    sizes := sc_signed_range(e);
    if !ap_is_strictly_positive(sizes.hi) || ss_is_unsafe(sizes) return l.unknown;
    sizes = cr_sext_or_trunc(sizes, l.ps);
    size_range := cr_new(ap_zero(l.ps), ap_sub(sizes.hi, ap_one(l.ps)));
    return ss_access_range_r(l, v, base, size_range);
}

// isSafeAccess(U, AI, AccessSize SCEV)
ss_is_safe_access_scev :: (l: *Ss_Local, u: Use_Id, ai: Value_Id, access_size: Scev_Id) -> bool {
    if ai == NONE return true;
    if sc_is_cnc(access_size) return false;
    i := ir.u_user[u];
    ae := ss_scev_as_pointer(ir.u_val[u]);
    be := ss_scev_as_pointer(ai);
    if ae == NONE || be == NONE return false;
    diff := sc_get_minus(ae, be);
    if sc_is_cnc(diff) return false;
    if sc_bits(diff) != l.ps fatal("stack-safety: pointers whose index width differs from their size are not supported (the SCEV types would mismatch)");
    size := ss_static_alloca_size_range(ai);
    calc := type_int(l.ps);
    to_diff :: (v: Scev_Id, t: Type_Id) -> Scev_Id { return sc_get_truncate_or_zero_extend(v, t); }
    mn := to_diff(sc_get_constant(size.lo), calc);
    mx := sc_get_minus(to_diff(sc_get_constant(size.hi), calc), to_diff(access_size, calc));
    k1, v1 := sc_evaluate_predicate_at(ICMP_SGE, diff, mn, i);
    if !(k1 && v1) return false;
    k2, v2 := sc_evaluate_predicate_at(ICMP_SLE, diff, mx, i);
    return k2 && v2;
}
ss_is_safe_access_size :: (l: *Ss_Local, u: Use_Id, ai: Value_Id, size: u64, scalable: bool) -> bool {
    if scalable return false;
    return ss_is_safe_access_scev(l, u, ai, sc_get_constant(ap_from_u64(l.ps, size)));
}

// analyzeAllUses(Ptr, US, SL)
ss_analyze_all_uses :: (l: *Ss_Local, ptr: Value_Id, us: *Ss_Use) {
    visited: [..] Value_Id; visited.allocator = temp;
    wl: [..] Value_Id; wl.allocator = temp;
    array_add(*wl, ptr);
    ai := ifx is_inst(ptr) && inst_op(ptr) == .ALLOCA then ptr else NONE;
    sl := l.sl;
    while wl.count {
        v := pop(*wl);
        u := ir.v_first_use[v];
        while u != NONE {
            defer u = ir.u_next[u];
            i := ir.u_user[u];
            if !is_inst(i) fatal("stack-safety: a non-instruction user of an address is not supported");
            if !stack_lifetime_is_reachable(sl, i) continue;
            record_store :: (l: *Ss_Local, us: *Ss_Use, v: Value_Id, i: Value_Id, u: Use_Id, ptr: Value_Id, ai: Value_Id, stored: Value_Id) {
                if v == stored { ss_add_range(us, i, l.unknown, false); return; }
                if ai != NONE && !stack_lifetime_is_alive_after(l.sl, ai, i) { ss_add_range(us, i, l.unknown, false); return; }
                ty := vtype(stored);
                sz := dl_type_store_size(ty); sc := type_is_scalable(ty);
                if sc sz = san_scalable_min_store_bits(ty) / 8;
                r := ss_access_range_size(l, ir.u_val[u], ptr, sz, sc);
                safe := ss_is_safe_access_size(l, u, ai, sz, sc);
                ss_add_range(us, i, r, safe);
            }
            o := inst_op(i);
            if o == {
                case .LOAD;
                    if ai != NONE && !stack_lifetime_is_alive_after(sl, ai, i) { ss_add_range(us, i, l.unknown, false); continue; }
                    ty := vtype(i);
                    sz := dl_type_store_size(ty); sc := type_is_scalable(ty);
                    if sc sz = san_scalable_min_store_bits(ty) / 8;
                    r := ss_access_range_size(l, v, ptr, sz, sc);
                    safe := ss_is_safe_access_size(l, u, ai, sz, sc);
                    ss_add_range(us, i, r, safe);
                case .VAARG;
                case .STORE; record_store(l, us, v, i, u, ptr, ai, op(i, 0));
                case .CMPXCHG; record_store(l, us, v, i, u, ptr, ai, op(i, 2));
                case .ATOMICRMW; record_store(l, us, v, i, u, ptr, ai, op(i, 1));
                case .RET; ss_add_range(us, i, l.unknown, false);
                case .CALL; #through;
                case .INVOKE;
                    if is_lifetime_start_or_end(i) continue;
                    if ai != NONE && !stack_lifetime_is_alive_after(sl, ai, i) { ss_add_range(us, i, l.unknown, false); continue; }
                    if asan_is_mem_intrinsic(i) {
                        r := ss_mem_intrinsic_access_range(l, i, u, ptr);
                        safe := false;
                        id := call_iid(i);
                        if id == IID_MEMCPY || id == IID_MEMCPY_INLINE || id == IID_MEMMOVE {
                            if op_use(i, 1) != u && op_use(i, 0) != u safe = true;
                        } else if op_use(i, 0) != u safe = true;
                        safe = safe || ss_is_safe_access_scev(l, u, ai, sc_get_scev(op(i, 2)));
                        ss_add_range(us, i, r, safe);
                        continue;
                    }
                    if call_returned_arg(i) == v {
                        if !array_find(visited, i) { array_add(*visited, i); array_add(*wl, i); }
                    }
                    opno := opno_of(u);
                    if opno >= call_arg_count(i) { ss_add_range(us, i, l.unknown, false); continue; }
                    if call_is_byval_arg(i, opno) {
                        ty := call_param_byval_type(i, opno);
                        sz := dl_type_store_size(ty); sc := type_is_scalable(ty);
                        r := ss_access_range_size(l, v, ptr, sz, sc);
                        safe := ss_is_safe_access_size(l, u, ai, sz, sc);
                        ss_add_range(us, i, r, safe);
                        continue;
                    }
                    callee := strip_pointer_casts(call_callee(i));
                    k := vkind(callee);
                    if !(k == .FUNCTION || k == .ALIAS || k == .GLOBAL_VAR) { ss_add_range(us, i, l.unknown, false); continue; }
                    offs := ss_offset_from(l, v, ptr);
                    ss_add_call(us, callee, opno, offs, true);
                case;
                    if !array_find(visited, i) { array_add(*visited, i); array_add(*wl, i); }
            }
        }
    }
}

// StackSafetyLocalAnalysis::run
ss_local_run :: (f: Value_Id) -> Ss_Fn {
    info: Ss_Fn;
    info.f = f;
    info.allocas.allocator = temp; info.alloca_uses.allocator = temp; info.params.allocator = temp; info.param_uses.allocator = temp;
    get_scev(f);
    l: Ss_Local;
    l.f = f;
    l.ps = dl_ptr_spec(0).bits;
    l.unknown = cr_full(l.ps);
    for i: fn_insts(f) if inst_op(i) == .ALLOCA array_add(*info.allocas, i);
    sl := stack_lifetime_run(f, info.allocas, false);
    l.sl = *sl;
    for ai: info.allocas {
        us := ss_use_new(l.ps);
        ss_analyze_all_uses(*l, ai, *us);
        array_add(*info.alloca_uses, us);
    }
    for k: 0..cast(s64) glob(f).nargs - 1 {
        a := fn_arg(f, cast(u32) k);
        if !is_ptr_type(vtype(a)) || fn_has_param_attr(f, cast(u32) k, .ByVal) continue;
        us := ss_use_new(l.ps);
        ss_analyze_all_uses(*l, a, *us);
        array_add(*info.params, cast(u32) k);
        array_add(*info.param_uses, us);
    }
    return info;
}

// ---------------------------------------------------------------- the module-level analysis

ss_copy_use :: (u: Ss_Use) -> Ss_Use {
    r := ss_use_new(cr_bits(u.range));
    r.range = u.range;
    for u.unsafe array_add(*r.unsafe, it);
    for u.calls array_add(*r.calls, it);
    return r;
}
ss_copy_fn :: (f: Ss_Fn) -> Ss_Fn {
    r: Ss_Fn;
    r.f = f.f; r.update_count = f.update_count;
    r.allocas.allocator = temp; r.alloca_uses.allocator = temp; r.params.allocator = temp; r.param_uses.allocator = temp;
    for f.allocas array_add(*r.allocas, it);
    for f.alloca_uses array_add(*r.alloca_uses, ss_copy_use(it));
    for f.params array_add(*r.params, it);
    for f.param_uses array_add(*r.param_uses, ss_copy_use(it));
    return r;
}

// findCalleeInModule
ss_find_callee_in_module :: (gv_in: Value_Id) -> Value_Id {
    gv := gv_in;
    while gv != NONE {
        if is_declaration(gv) || gv_is_interposable(gv) || !glob(gv).dso_local return NONE;
        if vkind(gv) == .FUNCTION return gv;
        if vkind(gv) != .ALIAS return NONE;
        a := gv_aliasee_object(op(gv, 0));
        if a == gv return NONE;
        gv = a;
    }
    return NONE;
}

// resolveAllCalls(Use, Index = nullptr)
ss_resolve_all_calls :: (u: *Ss_Use) {
    full := cr_full(cr_bits(u.range));
    tmp := u.calls;
    nc: [..] Ss_Call; nc.allocator = temp; u.calls = nc;
    for c: tmp {
        f := ss_find_callee_in_module(c.callee);
        if f != NONE { ss_add_call(u, f, c.param, c.range, false); continue; }
        u.range = ss_union_no_wrap(u.range, full);
        return;
    }
}

Ss_Dataflow :: struct {
    fns: [..] Ss_Fn;
    unknown: Const_Range;
    callers: Table(Value_Id, [..] Value_Id);
    worklist: [..] Value_Id;   // SetVector
}

ss_df_find :: (d: *Ss_Dataflow, f: Value_Id) -> *Ss_Fn { for * d.fns if it.f == f return it; return null; }

// getArgumentAccessRange
ss_argument_access_range :: (d: *Ss_Dataflow, callee: Value_Id, param: u32, offsets: Const_Range) -> Const_Range {
    fs := ss_df_find(d, callee);
    if !fs return d.unknown;
    pi := -1;
    for fs.params if it == param { pi = it_index; break; }
    if pi < 0 return d.unknown;
    access := fs.param_uses[pi].range;
    if cr_is_empty_set(access) return access;
    if cr_is_full_set(access) return d.unknown;
    return ss_add_overflow_never(access, offsets);
}

ss_update_one_use :: (d: *Ss_Dataflow, us: *Ss_Use, to_full: bool) -> bool {
    changed := false;
    for c: us.calls {
        cr := ss_argument_access_range(d, c.callee, c.param, c.range);
        if !cr_contains_range(us.range, cr) {
            changed = true;
            if to_full us.range = d.unknown;
            else us.range = ss_union_no_wrap(us.range, cr);
        }
    }
    return changed;
}

ss_update_one_node :: (d: *Ss_Dataflow, fs: *Ss_Fn) {
    to_full := fs.update_count > SS_MAX_ITERATIONS;
    changed := false;
    for * fs.param_uses if ss_update_one_use(d, it, to_full) changed = true;
    if changed {
        cl := table_find_pointer(*d.callers, fs.f);
        if cl for c: cl.* if !array_find(d.worklist, c) array_add(*d.worklist, c);
        fs.update_count += 1;
    }
}

ss_run_dataflow :: (d: *Ss_Dataflow) {
    for fs: d.fns {
        callees: [..] Value_Id; callees.allocator = temp;
        for u: fs.param_uses for c: u.calls if !array_find(callees, c.callee) array_add(*callees, c.callee);
        // llvm::sort(Callees) by pointer: by value id here
        for i: 1..callees.count-1 { x := callees[i]; j := i - 1; while j >= 0 && callees[j] > x { callees[j + 1] = callees[j]; j -= 1; } callees[j + 1] = x; }
        for c: callees {
            l := table_find_pointer(*d.callers, c);
            if !l { e: [..] Value_Id; e.allocator = temp; table_set(*d.callers, c, e); l = table_find_pointer(*d.callers, c); }
            array_add(l, fs.f);
        }
    }
    for * d.fns ss_update_one_node(d, it);
    while d.worklist.count {
        c := pop(*d.worklist);
        fs := ss_df_find(d, c);
        if fs ss_update_one_node(d, fs);
    }
}

// StackSafetyGlobalInfo::getInfo
ss_get_info :: (g: *Stack_Safety_Global) {
    if g.computed return;
    g.computed = true;
    // std::map<const GlobalValue *, FunctionInfo>: ordered by key (value id here)
    fns: [..] Ss_Fn; fns.allocator = temp;
    defined: [..] Value_Id; defined.allocator = temp;
    for f: ir.m_functions if !is_declaration(f) array_add(*defined, f);
    for i: 1..defined.count-1 { x := defined[i]; j := i - 1; while j >= 0 && defined[j] > x { defined[j + 1] = defined[j]; j -= 1; } defined[j + 1] = x; }
    for f: defined array_add(*fns, ss_local_run(f));
    if fns.count == 0 return;
    // createGlobalStackSafetyInfo
    d: Ss_Dataflow;
    d.fns.allocator = temp; d.callers.allocator = temp; d.worklist.allocator = temp;
    for fns array_add(*d.fns, ss_copy_fn(it));
    for * fs: d.fns for * u: fs.param_uses {
        ss_resolve_all_calls(u);
        if cr_is_full_set(u.range) u.calls.count = 0;
    }
    d.unknown = cr_full(dl_ptr_spec(0).bits);
    ss_run_dataflow(*d);
    for fs: d.fns {
        for * a, k: fs.alloca_uses {
            ss_resolve_all_calls(a);
            for c: a.calls a.range = ss_union_no_wrap(a.range, ss_argument_access_range(*d, c.callee, c.param, c.range));
            ai := fs.allocas[k];
            if cr_contains_range(ss_static_alloca_size_range(ai), a.range) table_set(*g.safe_allocas, ai, true);
            for x: a.unsafe table_set(*g.unsafe_accesses, x, true);
        }
    }
}
