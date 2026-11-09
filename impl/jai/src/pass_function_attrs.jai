// FunctionAttrs: a port of llvm/lib/Transforms/IPO/FunctionAttrs.cpp (PostOrderFunctionAttrsPass = the CGSCC pass
// `function-attrs[<skip-non-recursive-function-attrs>]`, ReversePostOrderFunctionAttrsPass = `rpo-function-attrs`,
// NoRecurseLTOInferencePass = `norecurse-lto-inference`: memory effects, argument attributes (captures, returned,
// readonly/readnone/writeonly, nofree, initializes, attributes from call sites), noalias / nonnull / noundef returns,
// convergent removal, noreturn, cold, willreturn, nounwind / nofree / nosync, norecurse, nofpclass top-down) and
// llvm/lib/IR/ConstantRangeList.cpp (insert, subtract, unionWith, intersectWith on 64-bit ranges).
//
// Not ported: thinLTOPropagateFunctionAttrs (summary-based; opt never runs it).
//
// AttributeInferer's InferenceDescriptors (std::function members) are the `Fa_Infer` enum: one switch per predicate.

fa_opts: struct {
    enable_poison_arg_attr_prop := true;   // -enable-poison-arg-attr-prop
    disable_nounwind_inference := false;   // -disable-nounwind-inference
    disable_nofree_inference := false;     // -disable-nofree-inference
};

// SCCNodeSet (SmallSetVector<Function *, 8>)
Fa_Set :: struct { list: [..] Value_Id; }
fa_set_contains :: (s: *Fa_Set, f: Value_Id) -> bool { if f == NONE return false; for s.list if it == f return true; return false; }

fa_changed: [..] Value_Id;   // SmallPtrSet<Function *, 8> Changed (order irrelevant: only membership is used)
fa_mark_changed :: (f: Value_Id) { for fa_changed if it == f return; array_add(*fa_changed, f); }

// Function::hasExactDefinition
fn_has_exact_definition :: (f: Value_Id) -> bool { return !is_declaration(f) && gv_is_definition_exact(f); }
fn_does_not_throw :: (f: Value_Id) -> bool { return fn_has_fn_attr(f, .NoUnwind); }
fn_will_return :: (f: Value_Id) -> bool { return fn_has_fn_attr(f, .WillReturn); }
fn_only_reads_memory :: (f: Value_Id) -> bool { return mem_only_reads(fn_memory_effects(f)); }
fn_does_not_recurse :: (f: Value_Id) -> bool { return fn_has_fn_attr(f, .NoRecurse); }
// AttributeList::hasAttrSomewhere(Kind) over the parameters (and return / function sets)
fn_has_attr_somewhere :: (f: Value_Id, k: Attr_Kind) -> bool {
    l := glob(f).attrs;
    if l == 0 return false;
    if attr_set_has(attr_list_fn(l), k) || attr_set_has(attr_list_ret(l), k) return true;
    for ir.attr_lists[l].params if attr_set_has(it, k) return true;
    return false;
}
arg_add_attr :: (a: Value_Id, at: Attr) { fn_add_param_attr(arg_parent(a), arg_no(a), at); }
arg_add_attr_kind :: (a: Value_Id, k: Attr_Kind) { fn_add_param_attr_kind(arg_parent(a), arg_no(a), k); }
arg_remove_attr :: (a: Value_Id, k: Attr_Kind) {
    f := arg_parent(a);
    l := glob(f).attrs;
    s := attr_list_param(l, arg_no(a));
    if !attr_set_has(s, k) return;
    fn_set_attr_list(f, attr_list_with_param(l, arg_no(a), attr_set_remove(s, k)));
}
// Argument::getAttributes().getCaptureInfo() as (other, ret)
arg_capture_info :: (a: Value_Id) -> (u8, u8) { o, r := capture_info_of_attrs(arg_attrs(a)); return o, r; }
// Attribute::getWithCaptureInfo
attr_captures :: (other: u8, ret: u8) -> Attr { at: Attr; at.kind = .Captures; at.ty = NONE; at.ival = cast(u64) other | ((cast(u64) ret) << 4); return at; }
attr_nofpclass :: (m: u32) -> Attr { at: Attr; at.kind = .NoFPClass; at.ty = NONE; at.ival = m; return at; }
// Argument::onlyReadsMemory: readonly or readnone
arg_attr_only_reads_memory :: (a: Value_Id) -> bool { return arg_has_attr(a, .ReadOnly) || arg_has_attr(a, .ReadNone); }
fa_dl_query :: () -> Simplify_Query { q: Simplify_Query; q.have_tli = false; return q; }

// ---------------------------------------------------------------- memory effects

// addLocAccess
fa_add_loc_access :: (me: *u64, loc: Mem_Loc, mr_in: u8, q: *Aa_Query) {
    mr := mr_in & aa_mod_ref_mask(q, loc, true);
    if mr == MR_NO return;
    uo := get_underlying_object_aggressive(loc.ptr);
    if vkind(uo) == .INST && inst_op(uo) == .ALLOCA return;
    if vkind(uo) == .ARGUMENT { me.* |= me_loc(LOC_ARG, mr); return; }
    if !is_identified_object(uo) me.* |= me_loc(LOC_ARG, mr);
    me.* |= me_loc(LOC_ERRNO, mr);
    me.* |= me_loc(LOC_OTHER, mr);
}
// addArgLocs
fa_add_arg_locs :: (me: *u64, call: Value_Id, arg_mr: u8, q: *Aa_Query) {
    n := call_num_args(call);
    for k: 0..cast(s64) n - 1 {
        a := call_arg(call, cast(u32) k);
        if !is_ptr_or_ptr_vector_type(vtype(a)) continue;
        fa_add_loc_access(me, mloc_before_or_after(a, aa_metadata(call)), arg_mr, q);
    }
}
is_ptr_or_ptr_vector_type :: (t: Type_Id) -> bool { return is_ptr_type(scalar_type(t)); }
// Instruction::getMemoryEffects (non-call instructions)
inst_memory_effects :: (i: Value_Id) -> u64 {
    get_effects :: (base: u8, ord: u8, volatile: bool) -> u64 {
        if is_stronger_than_monotonic(ord) return MEM_UNKNOWN;
        if volatile return me_inaccessible_or_arg_mem_only();
        if ord > ORD_UNORDERED return me_arg_mem_only();
        return me_arg_mem_only(base);
    }
    r := inst(i);
    vol := (r.flags & F_VOLATILE) != 0;
    if r.op == {
        case .VAARG; return me_arg_mem_only();
        case .CATCHPAD; #through;
        case .CATCHRET; #through;
        case .FENCE; return MEM_UNKNOWN;
        case .CALL; #through;
        case .INVOKE; #through;
        case .CALLBR; return call_memory_effects(i);
        case .LOAD; return get_effects(MR_REF, r.ord1, vol);
        case .STORE; return get_effects(MR_MOD, r.ord1, vol);
        case .ATOMICRMW; return get_effects(MR_MODREF, r.ord1, vol);
        case .CMPXCHG; return get_effects(MR_MODREF, r.ord1, vol);
    }
    return ME_NONE;
}

// checkFunctionMemoryAccess: (memory effects, additional effects if the SCC accesses argmem)
fa_check_function_memory_access :: (f: Value_Id, this_body: bool, aar: *Aa_Results, scc: *Fa_Set) -> (u64, u64) {
    orig_me := aa_memory_effects_fn(aa_query_new(aar), f);
    if orig_me == ME_NONE return orig_me, ME_NONE;
    if !this_body return orig_me, ME_NONE;
    me: u64 = ME_NONE;
    recursive_arg_me: u64 = ME_NONE;
    add_non_arg :: (me: *u64, inst_me: u64) {
        me.* |= me_without_loc(inst_me, LOC_ARG);
        other_mr := me_get(inst_me, LOC_OTHER);
        me.* |= me_loc(LOC_ARG, other_mr);
    }
    if fn_has_attr_somewhere(f, .InAlloca) || fn_has_attr_somewhere(f, .Preallocated) me |= me_arg_mem_only(MR_MODREF);
    for i: fn_insts(f) {
        if is_call_base(i) {
            callee := call_called_function(i);
            if call_num_bundles(i) == 0 && callee != NONE && fa_set_contains(scc, callee) {
                fa_add_arg_locs(*recursive_arg_me, i, MR_MODREF, aa_query_new(aar));
                continue;
            }
            call_me := aa_memory_effects_call(aa_query_new(aar), i);
            if call_me == ME_NONE continue;
            if call_iid(i) == IID_PSEUDOPROBE continue;
            add_non_arg(*me, call_me);
            arg_mr := me_get(call_me, LOC_ARG);
            if arg_mr != MR_NO fa_add_arg_locs(*me, i, arg_mr, aa_query_new(aar));
            continue;
        }
        inst_me := inst_memory_effects(i);
        if inst_me == ME_NONE continue;
        ok, loc := mloc_get_or_none(i);
        if !ok { me |= mem_all(me_mod_ref(inst_me)); continue; }
        add_non_arg(*me, inst_me);
        fa_add_loc_access(*me, loc, me_get(inst_me, LOC_ARG), aa_query_new(aar));
    }
    return orig_me & me, recursive_arg_me;
}

// addMemoryAttrs
fa_add_memory_attrs :: (scc: *Fa_Set) {
    me: u64 = ME_NONE;
    recursive_arg_me: u64 = ME_NONE;
    for f: scc.list {
        aar := aa_results_for(f);
        fn_me, fn_rec := fa_check_function_memory_access(f, fn_has_exact_definition(f), *aar, scc);
        me |= fn_me;
        recursive_arg_me |= fn_rec;
        if me == MEM_UNKNOWN return;
    }
    arg_mr := me_get(me, LOC_ARG);
    if arg_mr != MR_NO me |= recursive_arg_me & mem_all(arg_mr);
    for f: scc.list {
        old_me := fn_memory_effects(f);
        new_me := me & old_me;
        if new_me != old_me {
            fn_set_memory_effects(f, new_me);
            if (me_get(new_me, LOC_ARG) & MR_MOD) == 0
                for k: 0..cast(s64) glob(f).nargs - 1 arg_remove_attr(fn_arg(f, cast(u32) k), .Writable);
            fa_mark_changed(f);
        }
    }
}

// ---------------------------------------------------------------- argument attributes

// ArgumentGraph: node 0 is the synthetic root
Ag_Node :: struct { def: Value_Id = NONE; cc: u8; uses: [..] s32; }
Arg_Graph :: struct { nodes: [..] Ag_Node; map: Table(Value_Id, s32); }
ag_get :: (g: *Arg_Graph, a: Value_Id) -> s32 {   // ArgumentGraph::operator[]
    found, n := table_find(*g.map, a);
    if !found {
        nd: Ag_Node; nd.def = a; nd.uses.allocator = temp;
        n = cast(s32) g.nodes.count;
        array_add(*g.nodes, nd);
        table_set(*g.map, a, n);
    }
    array_add(*g.nodes[0].uses, n);
    return n;
}

// The ArgumentUsesTracker kind of Capture_Tracker: its state lives here (the tracker's `captured` is
// fa_arg_uses_captured, called from ct_captured)
fa_tracker: struct {
    scc: *Fa_Set;
    other: u8;
    ret: u8;
    uses: [..] Value_Id;
};
fa_arg_uses_too_many :: () { fa_tracker.other = CC_ALL; fa_tracker.ret = CC_ALL; }
// ArgumentUsesTracker::captured
fa_arg_uses_captured :: (u: Use_Id, use_cc: u8) -> Ct_Action {
    if fa_update_capture_info(u, use_cc) {
        if fa_tracker.other == CC_ALL return .STOP;
        return .CONTINUE;
    }
    return .CONTINUE_IGNORING_RETURN;
}
// ArgumentUsesTracker::updateCaptureInfo
fa_update_capture_info :: (u: Use_Id, cc: u8) -> bool {
    user := ir.u_user[u];
    if !(vkind(user) == .INST && is_call_base(user)) {
        if vkind(user) == .INST && inst_op(user) == .RET fa_tracker.ret |= cc;
        else { fa_tracker.other |= cc; fa_tracker.ret |= cc; }
        return true;
    }
    f := call_called_function(user);
    if f == NONE || !fn_has_exact_definition(f) || !fa_set_contains(fa_tracker.scc, f) {
        fa_tracker.other |= cc; fa_tracker.ret |= cc;
        return true;
    }
    use_index := u - ir.v_ops[user];   // getDataOperandNo
    if use_index >= call_num_args(user) { fa_tracker.other |= cc; fa_tracker.ret |= cc; return true; }
    if use_index >= glob(f).nargs { fa_tracker.other |= cc; fa_tracker.ret |= cc; return true; }
    array_add(*fa_tracker.uses, fn_arg(f, use_index));
    return false;
}

Arg_Access :: struct { read: bool; write: bool; free: bool; }
aap_has_all :: (p: Arg_Access) -> bool { return p.read && p.write && p.free; }

// determinePointerAccessAttrs
fa_determine_pointer_access_attrs :: (a: Value_Id, scc_args: [] Value_Id) -> Arg_Access {
    ALL :: Arg_Access.{true, true, true};
    if arg_has_attr(a, .InAlloca) || arg_has_attr(a, .Preallocated) return ALL;
    props: Arg_Access;
    worklist: [..] Use_Id; worklist.allocator = temp;
    visited: Table(Use_Id, bool); visited.allocator = temp;
    u := ir.v_first_use[a];
    while u != NONE { table_set(*visited, u, true); array_add(*worklist, u); u = ir.u_next[u]; }
    while worklist.count {
        if aap_has_all(props) return props;
        u := pop(*worklist);
        i := ir.u_user[u];
        if inst_op(i) == .RET continue;
        use_cc, result_cc := ct_use_capture_kind(u, a);
        if is_call_base(i) && call_only_reads_memory(i) use_cc &= CC_ADDRESS;
        if cc_captures_any_provenance(use_cc) {
            if !cc_captures_read_provenance_only(use_cc) return ALL;
            props.read = true;
        }
        if cc_captures_any_provenance(result_cc) {
            uu := ir.v_first_use[i];
            while uu != NONE {
                if !table_contains(*visited, uu) { table_set(*visited, uu, true); array_add(*worklist, uu); }
                uu = ir.u_next[uu];
            }
        }
        if is_call_base(i) {
            opno := u - ir.v_ops[i];
            if opno == nops(i) - 1 { props.read = true; continue; }   // isCallee
            use_index := opno;
            arg_mr := me_get(call_memory_effects(i), LOC_ARG);
            if arg_mr == MR_NO continue;
            f := call_called_function(i);
            if f != NONE && use_index < call_num_args(i) && use_index < glob(f).nargs {
                fa := fn_arg(f, use_index);
                in_scc := false;
                for scc_args if it == fa { in_scc = true; break; }
                if in_scc continue;
            }
            if (arg_mr & MR_REF) != 0 && !call_data_operand_only_writes(i, use_index) props.read = true;
            if (arg_mr & MR_MOD) != 0 && !call_data_operand_only_reads(i, use_index) {
                props.write = true;
                if use_index < call_num_args(i) && !call_has_fn_attr(i, .NoFree) && !call_param_has_attr(i, use_index, .NoFree)
                    props.free = true;
            }
        } else {
            if inst_op(i) == .STORE && (u - ir.v_ops[i]) != 1 continue;
            props.read |= may_read_from_memory(i);
            props.write |= may_write_to_memory(i);
        }
    }
    return props;
}

// addArgumentReturnedAttrs
fa_add_argument_returned_attrs :: (scc: *Fa_Set) {
    for f: scc.list {
        if !fn_has_exact_definition(f) continue;
        rt := fn_ret_type(f);
        if type_kind(rt) == .VOID continue;
        if fn_has_attr_somewhere(f, .Returned) continue;
        ret_arg: Value_Id = NONE;
        ok := true;
        for b: fn_blocks(f) {
            t := block_terminator(b);
            if t == NONE || inst_op(t) != .RET continue;
            rv := strip_pointer_casts_kind(op(t, 0), .ZERO_INDICES);
            if vkind(rv) != .ARGUMENT || vtype(rv) != rt { ok = false; break; }
            if ret_arg == NONE ret_arg = rv;
            else if ret_arg != rv { ok = false; break; }
        }
        if ok && ret_arg != NONE {
            arg_add_attr_kind(ret_arg, .Returned);
            fa_mark_changed(f);
        }
    }
}

// addArgumentAttrsFromCallsites
fa_add_argument_attrs_from_callsites :: (f: Value_Id) -> bool {
    if !fa_opts.enable_poison_arg_attr_prop return false;
    changed := false;
    for i: block_insts(fn_entry(f)) {
        if is_call_base(i) {
            callee := call_called_function(i);
            if callee != NONE {
                for k: 0..cast(s64) glob(callee).nargs - 1 {
                    argno := cast(u32) k;
                    cs_arg := fn_arg(callee, argno);
                    farg := call_arg(i, argno);
                    if vkind(farg) != .ARGUMENT continue;
                    if arg_has_nonnull_attr(cs_arg, false) {
                        if !arg_has_nonnull_attr(farg) { arg_add_attr_kind(farg, .NonNull); changed = true; }
                    } else {
                        cs_nofp := call_param_no_fp_class(i, argno);
                        if cs_nofp != 0 && call_param_has_attr(i, argno, .NoUndef) {
                            arg_nofp := fpc_arg_no_fp_class(farg);
                            if (cs_nofp | arg_nofp) != arg_nofp {
                                arg_add_attr(farg, attr_nofpclass(cs_nofp | arg_nofp));
                                changed = true;
                            }
                        }
                    }
                }
            }
        }
        if !is_guaranteed_to_transfer_execution(i) break;
    }
    return changed;
}
// CallBase::getParamNoFPClass
call_param_no_fp_class :: (c: Value_Id, k: u32) -> u32 {
    m: u32 = 0;
    a := attr_set_find(attr_list_param(inst(c).attrs, k), .NoFPClass);
    if a m |= cast(u32) a.ival;
    f := call_called_function(c);
    if f != NONE { b := attr_set_find(attr_list_param(glob(f).attrs, k), .NoFPClass); if b m |= cast(u32) b.ival; }
    return m;
}

// addAccessAttrs
fa_add_access_attrs :: (a: Value_Id, props: Arg_Access) -> bool {
    changed := false;
    if !props.free && !arg_has_attr(a, .NoFree) { arg_add_attr_kind(a, .NoFree); changed = true; }
    if props.read && props.write return changed;
    k: Attr_Kind;
    if props.read k = .ReadOnly;
    else if props.write k = .WriteOnly;
    else k = .ReadNone;
    if arg_has_attr(a, k) return false;
    arg_remove_attr(a, .WriteOnly);
    arg_remove_attr(a, .ReadOnly);
    arg_remove_attr(a, .ReadNone);
    if k == .ReadNone || k == .ReadOnly arg_remove_attr(a, .Writable);
    arg_add_attr_kind(a, k);
    return true;
}

// ---- ConstantRangeList (64-bit, signed order)
Crange :: struct { lo: s64; hi: s64; }
crl_is_empty_range :: (r: Crange) -> bool { return r.lo == r.hi && r.lo == 0; }
// ConstantRange::contains(ConstantRange) (unsigned, wrapping)
crange_contains :: (a: Crange, b: Crange) -> bool {
    al := cast,no_check(u64) a.lo; ah := cast,no_check(u64) a.hi;
    bl := cast,no_check(u64) b.lo; bh := cast,no_check(u64) b.hi;
    a_full := al == ah && al == 0xFFFF_FFFF_FFFF_FFFF;
    b_empty := bl == bh && bl == 0;
    if a_full || b_empty return true;
    a_empty := al == ah && al == 0;
    b_full := bl == bh && bl == 0xFFFF_FFFF_FFFF_FFFF;
    if a_empty || b_full return false;
    a_wrapped := al > ah;
    b_wrapped := bl > bh;
    if !a_wrapped {
        if b_wrapped return false;
        return al <= bl && bh <= ah;
    }
    if !b_wrapped return bh <= ah || al <= bl;
    return bh <= ah && al <= bl;
}
crl_insert :: (l: *[..] Crange, nr: Crange) {
    if crl_is_empty_range(nr) return;
    if l.count == 0 || l.*[l.count - 1].hi < nr.lo { array_add(l, nr); return; }
    if nr.hi < l.*[0].lo { array_insert_at(l, nr, 0); return; }
    lb := 0;
    while lb < l.count && l.*[lb].lo < nr.lo lb += 1;
    if lb < l.count && crange_contains(l.*[lb], nr) return;
    tail: [..] Crange; tail.allocator = temp;
    for k: lb..l.count-1 array_add(*tail, l.*[k]);
    l.count = lb;
    if l.count && nr.lo <= l.*[l.count - 1].hi {
        l.*[l.count - 1].hi = max(nr.hi, l.*[l.count - 1].hi);
    } else array_add(l, nr);
    for t: tail {
        if l.*[l.count - 1].hi < t.lo array_add(l, t);
        else l.*[l.count - 1].hi = max(t.hi, l.*[l.count - 1].hi);
    }
}
crl_subtract :: (l: *[..] Crange, sub: Crange) {
    if crl_is_empty_range(sub) || l.count == 0 return;
    if l.*[l.count - 1].hi <= sub.lo return;
    if sub.hi <= l.*[0].lo return;
    result: [..] Crange; result.allocator = temp;
    add_if :: (r: *[..] Crange, s: s64, e: s64) { if s < e array_add(r, .{s, e}); }
    for r: l.* {
        if sub.hi <= r.lo || r.hi <= sub.lo array_add(*result, r);
        else if r.lo <= sub.lo && sub.hi <= r.hi { add_if(*result, r.lo, sub.lo); add_if(*result, sub.hi, r.hi); }
        else if sub.lo <= r.lo && r.hi <= sub.hi continue;
        else if r.lo >= sub.lo && r.lo <= sub.hi add_if(*result, sub.hi, r.hi);
        else add_if(*result, r.lo, sub.lo);
    }
    l.count = 0;
    for result array_add(l, it);
}
crl_union :: (a: [] Crange, b: [] Crange) -> [..] Crange {
    result: [..] Crange; result.allocator = temp;
    if a.count == 0 { for b array_add(*result, it); return result; }
    if b.count == 0 { for a array_add(*result, it); return result; }
    i := 0; j := 0;
    prev: Crange;
    if a[i].lo < b[j].lo { prev = a[i]; i += 1; } else { prev = b[j]; j += 1; }
    merge :: (prev: *Crange, result: *[..] Crange, cr: Crange) {
        if prev.hi < cr.lo { array_add(result, prev.*); prev.* = cr; }
        else prev.* = .{prev.lo, max(prev.hi, cr.hi)};
    }
    while i < a.count || j < b.count {
        if j == b.count || (i < a.count && a[i].lo < b[j].lo) { merge(*prev, *result, a[i]); i += 1; }
        else { merge(*prev, *result, b[j]); j += 1; }
    }
    array_add(*result, prev);
    return result;
}
crl_intersect :: (a: [] Crange, b: [] Crange) -> [..] Crange {
    result: [..] Crange; result.allocator = temp;
    if a.count == 0 return result;
    if b.count == 0 return result;
    i := 0; j := 0;
    while i < a.count && j < b.count {
        s := max(a[i].lo, b[j].lo);
        e := min(a[i].hi, b[j].hi);
        if s < e array_add(*result, .{s, e});
        if a[i].hi < b[j].hi i += 1; else j += 1;
    }
    return result;
}
crl_eq :: (a: [] Crange, b: [] Crange) -> bool {
    if a.count != b.count return false;
    for a if it.lo != b[it_index].lo || it.hi != b[it_index].hi return false;
    return true;
}

Access_Type :: enum u8 { WRITE; WRITE_WITH_SIDE_EFFECT; READ; UNKNOWN; }
Arg_Access_Info :: struct { kind: Access_Type; ranges: [..] Crange; }
Uses_Per_Block :: struct { insts: [..] Value_Id; infos: [..] Arg_Access_Info; has_writes: bool; has_unknown: bool; }
Arg_Uses_Summary :: struct {
    has_any_write: bool;
    has_write_outside_entry: bool;
    blocks: Table(Value_Id, s32);   // block -> index into per_block
    per_block: [..] Uses_Per_Block;
}

// getArgumentAccessInfo
fa_get_argument_access_info :: (i: Value_Id, u: Use_Id, has_off: bool, off: s64) -> Arg_Access_Info {
    r: Arg_Access_Info; r.ranges.allocator = temp;
    type_range :: (ty: Type_Id, has_off: bool, off: s64) -> (bool, Crange) {
        if type_is_scalable(ty) || !has_off return false, .{};
        size := cast(s64) dl_type_store_size(ty);
        hi, ov := add_ov_s64(off, size);
        if ov return false, .{};
        return true, .{off, hi};
    }
    int_range :: (len: Value_Id, has_off: bool, off: s64) -> (bool, Crange) {
        if vkind(len) != .C_INT || !has_off return false, .{};
        l := const_int_sext(len);
        if l <= 0 return false, .{};
        hi, ov := add_ov_s64(off, l);
        if ov return false, .{};
        return true, .{off, hi};
    }
    opno := u - ir.v_ops[i];
    o := inst_op(i);
    if o == .STORE {
        if is_simple_load_store(i) && opno == 1 {
            ok, cr := type_range(vtype(op(i, 0)), has_off, off);
            if ok crl_insert(*r.ranges, cr);
            r.kind = .WRITE;
            return r;
        }
    } else if o == .LOAD {
        if is_simple_load_store(i) {
            ok, cr := type_range(vtype(i), has_off, off);
            if ok { r.kind = .READ; array_add(*r.ranges, cr); return r; }
        }
    } else if is_call_base(i) && (call_iid(i) == IID_MEMSET || call_iid(i) == IID_MEMSET_INLINE) {
        if !is_volatile(i) {
            ok, cr := int_range(call_arg(i, 2), has_off, off);
            if ok crl_insert(*r.ranges, cr);
            r.kind = .WRITE;
            return r;
        }
    } else if is_call_base(i) && (call_iid(i) == IID_MEMCPY || call_iid(i) == IID_MEMMOVE || call_iid(i) == IID_MEMCPY_INLINE) {
        if !is_volatile(i) {
            if opno == 0 {
                ok, cr := int_range(call_arg(i, 2), has_off, off);
                if ok crl_insert(*r.ranges, cr);
                r.kind = .WRITE;
                return r;
            } else if opno == 1 {
                ok, cr := int_range(call_arg(i, 2), has_off, off);
                if ok { r.kind = .READ; array_add(*r.ranges, cr); return r; }
            }
        }
    } else if is_call_base(i) {
        if opno < call_num_args(i) && !call_is_byval_arg(i, opno) {
            argno := opno;
            init := call_param_attr(i, argno, .Initializes);
            if init && has_off {
                writes := call_data_operand_only_writes(i, argno) && fa_call_does_not_capture(i, argno);
                r.kind = ifx writes then Access_Type.WRITE else .WRITE_WITH_SIDE_EFFECT;
                for lo, j: init.lo crl_insert(*r.ranges, .{cast,no_check(s64) lo + off, cast,no_check(s64) init.hi[j] + off});
                return r;
            }
        }
    }
    r.kind = .UNKNOWN;
    return r;
}
// CallBase::doesNotCapture(OpNo): capturesNothing(getCaptureInfo(OpNo))
fa_call_does_not_capture :: (c: Value_Id, k: u32) -> bool { o, r := call_capture_info(c, k); return o == CC_NONE && r == CC_NONE; }

// collectArgumentUsesPerBlock
fa_collect_argument_uses_per_block :: (a: Value_Id, f: Value_Id) -> Arg_Uses_Summary {
    pointer_size := dl_index_size_bits(cast(u32) ir.types[vtype(a)].a);
    res: Arg_Uses_Summary;
    res.blocks.allocator = temp; res.per_block.allocator = temp;
    entry := fn_entry(f);
    Arg_Use :: struct { u: Use_Id; has_off: bool; off: s64; }
    worklist: [..] Arg_Use; worklist.allocator = temp;
    u := ir.v_first_use[a];
    while u != NONE { array_add(*worklist, .{u, true, 0}); u = ir.u_next[u]; }
    update_use_info :: (res: *Arg_Uses_Summary, i: Value_Id, info: Arg_Access_Info) -> bool {
        bb := inst_block(i);
        found, bi := table_find(*res.blocks, bb);
        if !found {
            bi = cast(s32) res.per_block.count;
            e: Uses_Per_Block; e.insts.allocator = temp; e.infos.allocator = temp;
            array_add(*res.per_block, e);
            table_set(*res.blocks, bb, bi);
        }
        b := *res.per_block[bi];
        for b.insts if it == i {
            b.infos[it_index].kind = .UNKNOWN;
            b.infos[it_index].ranges.count = 0;
            b.has_unknown = true;
            return false;
        }
        array_add(*b.insts, i);
        array_add(*b.infos, info);
        b.has_unknown |= info.kind == .UNKNOWN;
        has_writes := (info.kind == .WRITE || info.kind == .WRITE_WITH_SIDE_EFFECT) && info.ranges.count != 0;
        b.has_writes |= has_writes;
        return has_writes;
    }
    while worklist.count {
        au := pop(*worklist);
        user := ir.u_user[au.u];
        if opr_code(user) == .GEP {
            has_new := false; new_off: s64 = 0;
            if au.has_off {
                ok, off := gep_accumulate_constant_offset(user, ap_zero(pointer_size));
                if ok { has_new = true; new_off = au.off + ap_sext_value(off); }
            }
            uu := ir.v_first_use[user];
            while uu != NONE { array_add(*worklist, .{uu, has_new, new_off}); uu = ir.u_next[uu]; }
            continue;
        }
        has_write := update_use_info(*res, user, fa_get_argument_access_info(user, au.u, au.has_off, au.off));
        res.has_any_write |= has_write;
        if has_write && inst_block(user) != entry res.has_write_outside_entry = true;
    }
    return res;
}

// inferInitializes
fa_infer_initializes :: (a: Value_Id, f: Value_Id) -> bool {
    uses := fa_collect_argument_uses_per_block(a, f);
    if !uses.has_any_write return false;
    entry := fn_entry(f);
    initialized: Table(Value_Id, [..] Crange); initialized.allocator = temp;
    visit_block :: (bb: Value_Id, uses: *Arg_Uses_Summary, initialized: *Table(Value_Id, [..] Crange)) -> [..] Crange {
        crl: [..] Crange; crl.allocator = temp;
        found, bi := table_find(*uses.blocks, bb);
        if !found || !uses.per_block[bi].has_unknown {
            added := false;
            succs: [..] Value_Id; succs.allocator = temp;
            block_successors(bb, *succs);
            for s: succs {
                sf, sr := table_find(initialized, s);
                if sf {
                    if added crl = crl_intersect(crl, sr);
                    else { crl.count = 0; for sr array_add(*crl, it); added = true; }
                } else { crl.count = 0; break; }
            }
        }
        if found {
            b := *uses.per_block[bi];
            // sort by instruction order
            order: [..] s64; order.allocator = temp;
            for b.insts array_add(*order, it_index);
            for x: 1..order.count-1 {
                y := x;
                while y > 0 && comes_before(b.insts[order[y]], b.insts[order[y - 1]]) {
                    t := order[y]; order[y] = order[y - 1]; order[y - 1] = t; y -= 1;
                }
            }
            for < k: 0..order.count-1 {
                info := *b.infos[order[k]];
                if info.kind == .UNKNOWN || info.kind == .WRITE_WITH_SIDE_EFFECT crl.count = 0;
                if info.ranges.count {
                    if info.kind == .WRITE || info.kind == .WRITE_WITH_SIDE_EFFECT crl = crl_union(crl, info.ranges);
                    else for info.ranges crl_subtract(*crl, it);
                }
            }
        }
        return crl;
    }
    entry_crl: [..] Crange; entry_crl.allocator = temp;
    only_entry := !uses.has_write_outside_entry;
    if !only_entry {
        found, bi := table_find(*uses.blocks, entry);
        if found only_entry = uses.per_block[bi].has_unknown;
    }
    if only_entry {
        entry_crl = visit_block(entry, *uses, *initialized);
        if entry_crl.count == 0 return false;
    } else {
        po: [..] Value_Id; po.allocator = temp;
        fa_post_order(f, *po);
        for bb: po {
            crl := visit_block(bb, *uses, *initialized);
            if crl.count table_set(*initialized, bb, crl);
        }
        found, ec := table_find(*initialized, entry);
        if !found return false;
        entry_crl = ec;
    }
    prev := call_or_arg_initializes(a);
    if prev {
        pl: [..] Crange; pl.allocator = temp;
        for lo, j: prev.lo array_add(*pl, .{cast,no_check(s64) lo, cast,no_check(s64) prev.hi[j]});
        if crl_eq(pl, entry_crl) return false;
        entry_crl = crl_union(entry_crl, pl);
    }
    at: Attr; at.kind = .Initializes; at.ty = NONE;
    lo := NewArray(entry_crl.count, u64,, allocator = temp);
    hi := NewArray(entry_crl.count, u64,, allocator = temp);
    for entry_crl { lo[it_index] = cast,no_check(u64) it.lo; hi[it_index] = cast,no_check(u64) it.hi; }
    at.lo = lo; at.hi = hi;
    arg_add_attr(a, at);
    return true;
}
call_or_arg_initializes :: (a: Value_Id) -> *Attr { return attr_set_find(arg_attrs(a), .Initializes); }

// post_order(&F): the blocks reachable from the entry in DFS post-order (successor order)
fa_post_order :: (f: Value_Id, out: *[..] Value_Id) {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    Frame :: struct { b: Value_Id; succs: [..] Value_Id; i: s64; }
    stack: [..] Frame; stack.allocator = temp;
    push :: (stack: *[..] Frame, b: Value_Id) {
        fr: Frame; fr.b = b; fr.succs.allocator = temp; block_successors(b, *fr.succs); array_add(stack, fr);
    }
    e := fn_entry(f);
    table_set(*visited, e, true);
    push(*stack, e);
    while stack.count {
        top := *stack[stack.count - 1];
        if top.i < top.succs.count {
            s := top.succs[top.i];
            top.i += 1;
            if !table_contains(*visited, s) { table_set(*visited, s, true); push(*stack, s); }
            continue;
        }
        array_add(out, top.b);
        stack.count -= 1;
    }
}

// addArgumentAttrs
fa_add_argument_attrs :: (scc: *Fa_Set, skip_initializes: bool) {
    ag: Arg_Graph; ag.nodes.allocator = temp; ag.map.allocator = temp;
    root: Ag_Node; root.uses.allocator = temp;
    array_add(*ag.nodes, root);
    determine_singleton :: (a: Value_Id) -> bool {
        return fa_add_access_attrs(a, fa_determine_pointer_access_attrs(a, .[a]));
    }
    for f: scc.list {
        if !fn_has_exact_definition(f) continue;
        if fa_add_argument_attrs_from_callsites(f) fa_mark_changed(f);
        if fn_only_reads_memory(f) && fn_does_not_throw(f) && fn_will_return(f) && type_kind(fn_ret_type(f)) == .VOID {
            for k: 0..cast(s64) glob(f).nargs - 1 {
                a := fn_arg(f, cast(u32) k);
                o, r := arg_capture_info(a);
                if is_ptr_type(vtype(a)) && !(o == CC_NONE && r == CC_NONE) {
                    arg_add_attr(a, attr_captures(CC_NONE, CC_NONE));
                    fa_mark_changed(f);
                }
            }
            continue;
        }
        for k: 0..cast(s64) glob(f).nargs - 1 {
            a := fn_arg(f, cast(u32) k);
            if !is_ptr_type(vtype(a)) continue;
            has_non_local_uses := false;
            orig_o, orig_r := arg_capture_info(a);
            if !(orig_o == CC_NONE && orig_r == CC_NONE) {
                fa_tracker.scc = scc;
                fa_tracker.other = CC_NONE; fa_tracker.ret = CC_NONE;
                fa_tracker.uses.data = null; fa_tracker.uses.count = 0; fa_tracker.uses.allocated = 0;
                fa_tracker.uses.allocator = temp;
                t: Capture_Tracker; t.kind = .ARG_USES;
                ct_run(a, *t);
                new_o := fa_tracker.other & orig_o;
                new_r := fa_tracker.ret & orig_r;
                if new_o != orig_o || new_r != orig_r {
                    if fa_tracker.uses.count == 0 {
                        arg_add_attr(a, attr_captures(new_o, new_r));
                        fa_mark_changed(f);
                    } else {
                        node := ag_get(*ag, a);
                        ag.nodes[node].cc = new_o | new_r;
                        tuses: [..] Value_Id; tuses.allocator = temp;
                        for fa_tracker.uses array_add(*tuses, it);
                        for use: tuses {
                            un := ag_get(*ag, use);
                            array_add(*ag.nodes[node].uses, un);
                            if use != a has_non_local_uses = true;
                        }
                    }
                }
            }
            if !has_non_local_uses && !arg_attr_only_reads_memory(a) {
                if determine_singleton(a) fa_mark_changed(f);
            }
            if !skip_initializes && !arg_attr_only_reads_memory(a) {
                if fa_infer_initializes(a, f) fa_mark_changed(f);
            }
        }
    }
    // scc_iterator over the argument graph from the synthetic root
    sccs := ag_scc_iterate(*ag);
    for arg_scc: sccs {
        if arg_scc.count == 1 {
            n0 := arg_scc[0];
            if ag.nodes[n0].def == NONE continue;
            if ag.nodes[n0].uses.count == 1 && ag.nodes[n0].uses[0] == n0 {
                a := ag.nodes[n0].def;
                oo, orr := arg_capture_info(a);
                no := ag.nodes[n0].cc & oo; nr := ag.nodes[n0].cc & orr;
                if no != oo || nr != orr {
                    arg_add_attr(a, attr_captures(no, nr));
                    fa_mark_changed(arg_parent(a));
                }
                if determine_singleton(a) fa_mark_changed(arg_parent(a));
            }
            continue;
        }
        scc_args: [..] Value_Id; scc_args.allocator = temp;
        for arg_scc array_add(*scc_args, ag.nodes[it].def);
        cc: u8 = CC_NONE;
        for n: arg_scc {
            for un: ag.nodes[n].uses {
                a := ag.nodes[un].def;
                in_set := false;
                for scc_args if it == a { in_set = true; break; }
                if in_set cc |= ag.nodes[un].cc;
                else { o, r := arg_capture_info(a); cc |= o | r; }
                break;
            }
            if cc == CC_ALL break;
        }
        if cc != CC_ALL {
            for n: arg_scc {
                a := ag.nodes[n].def;
                oo, orr := arg_capture_info(a);
                c := ag.nodes[n].cc | cc;
                no := c & oo; nr := c & orr;
                if no != oo || nr != orr {
                    arg_add_attr(a, attr_captures(no, nr));
                    fa_mark_changed(arg_parent(a));
                }
            }
        }
        if cc_captures_any_provenance(cc) {
            for n: arg_scc if determine_singleton(ag.nodes[n].def) fa_mark_changed(arg_parent(ag.nodes[n].def));
            continue;
        }
        props: Arg_Access;
        for n: arg_scc {
            p := fa_determine_pointer_access_attrs(ag.nodes[n].def, scc_args);
            props.read |= p.read; props.write |= p.write; props.free |= p.free;
            if aap_has_all(props) break;
        }
        if !aap_has_all(props) {
            for n: arg_scc {
                a := ag.nodes[n].def;
                if fa_add_access_attrs(a, props) fa_mark_changed(arg_parent(a));
            }
        }
    }
}

// scc_iterator<ArgumentGraph *> (SCCIterator.h): the SCCs reachable from the root, in post-order; nodes of an SCC in
// the order they leave the SCC node stack
ag_scc_iterate :: (g: *Arg_Graph) -> [..] [..] s32 {
    result: [..] [..] s32; result.allocator = temp;
    visit_num: u32 = 0;
    numbers: Table(s32, u32); numbers.allocator = temp;
    node_stack: [..] s32; node_stack.allocator = temp;
    Elem :: struct { n: s32; next: s64; min_visited: u32; }
    visit_stack: [..] Elem; visit_stack.allocator = temp;
    visit_one :: (n: s32, visit_num: *u32, numbers: *Table(s32, u32), node_stack: *[..] s32, visit_stack: *[..] Elem) {
        visit_num.* += 1;
        table_set(numbers, n, visit_num.*);
        array_add(node_stack, n);
        array_add(visit_stack, .{n, 0, visit_num.*});
    }
    visit_one(0, *visit_num, *numbers, *node_stack, *visit_stack);
    while visit_stack.count {
        // DFSVisitChildren
        while true {
            top := *visit_stack[visit_stack.count - 1];
            if top.next >= g.nodes[top.n].uses.count break;
            child := g.nodes[top.n].uses[top.next];
            top.next += 1;
            found, num := table_find(*numbers, child);
            if !found { visit_one(child, *visit_num, *numbers, *node_stack, *visit_stack); continue; }
            top2 := *visit_stack[visit_stack.count - 1];
            if top2.min_visited > num top2.min_visited = num;
        }
        top := visit_stack[visit_stack.count - 1];
        visit_stack.count -= 1;
        if visit_stack.count && visit_stack[visit_stack.count - 1].min_visited > top.min_visited
            visit_stack[visit_stack.count - 1].min_visited = top.min_visited;
        num := table_find_pointer(*numbers, top.n).*;
        if top.min_visited != num continue;
        scc: [..] s32; scc.allocator = temp;
        while true {
            x := pop(*node_stack);
            array_add(*scc, x);
            table_set(*numbers, x, 0xFFFF_FFFF);
            if x == top.n break;
        }
        array_add(*result, scc);
    }
    return result;
}

// ---------------------------------------------------------------- return attributes

// isFunctionMallocLike
fa_is_function_malloc_like :: (f: Value_Id, scc: *Fa_Set) -> bool {
    flows: [..] Value_Id; flows.allocator = temp;
    add :: (flows: *[..] Value_Id, v: Value_Id) { for flows.* if it == v return; array_add(flows, v); }
    for b: fn_blocks(f) { t := block_terminator(b); if t != NONE && inst_op(t) == .RET add(*flows, op(t, 0)); }
    i := 0;
    while i < flows.count {
        rv := flows[i];
        i += 1;
        if is_constant_kind(vkind(rv)) {
            if !is_null_value(rv) && vkind(rv) != .C_UNDEF && vkind(rv) != .C_POISON return false;
            continue;
        }
        if vkind(rv) == .ARGUMENT return false;
        if vkind(rv) == .INST {
            o := inst_op(rv);
            if o == .BITCAST || o == .GEP || o == .ADDRSPACECAST { add(*flows, op(rv, 0)); continue; }
            if o == .SELECT { add(*flows, op(rv, 1)); add(*flows, op(rv, 2)); continue; }
            if o == .PHI { for k: 0..cast(s64) nops(rv) - 1 add(*flows, op(rv, cast(u32) k)); continue; }
            if o == .ALLOCA {
            } else if o == .CALL || o == .INVOKE {
                callee := call_called_function(rv);
                if !(call_has_ret_attr(rv, .NoAlias) || (callee != NONE && fa_set_contains(scc, callee))) return false;
            } else return false;
        }
        if pointer_may_be_captured_bool(rv, false) return false;
    }
    return true;
}
// addNoAliasAttrs
fa_add_no_alias_attrs :: (scc: *Fa_Set) {
    for f: scc.list {
        if fn_has_ret_attr(f, .NoAlias) continue;
        if !fn_has_exact_definition(f) return;
        if !is_ptr_type(fn_ret_type(f)) continue;
        if !fa_is_function_malloc_like(f, scc) return;
    }
    for f: scc.list {
        if fn_has_ret_attr(f, .NoAlias) || !is_ptr_type(fn_ret_type(f)) continue;
        fn_add_ret_attr_kind(f, .NoAlias);
        fa_mark_changed(f);
    }
}

// isReturnNonNull: (non-null, speculative)
fa_is_return_non_null :: (f: Value_Id, scc: *Fa_Set) -> (bool, bool) {
    speculative := false;
    flows: [..] Value_Id; flows.allocator = temp;
    add :: (flows: *[..] Value_Id, v: Value_Id) { for flows.* if it == v return; array_add(flows, v); }
    for b: fn_blocks(f) { t := block_terminator(b); if t != NONE && inst_op(t) == .RET add(*flows, op(t, 0)); }
    i := 0;
    while i < flows.count {
        rv := flows[i];
        i += 1;
        if is_known_non_zero(rv, fa_dl_query()) continue;
        if vkind(rv) != .INST return false, speculative;
        o := inst_op(rv);
        if o == .BITCAST || o == .ADDRSPACECAST { add(*flows, op(rv, 0)); continue; }
        if o == .GEP {
            if (inst(rv).flags & F_INBOUNDS) != 0 { add(*flows, op(rv, 0)); continue; }
            return false, speculative;
        }
        if o == .SELECT { add(*flows, op(rv, 1)); add(*flows, op(rv, 2)); continue; }
        if o == .PHI { for k: 0..cast(s64) nops(rv) - 1 add(*flows, op(rv, cast(u32) k)); continue; }
        if o == .CALL || o == .INVOKE {
            callee := call_called_function(rv);
            if callee != NONE && fa_set_contains(scc, callee) { speculative = true; continue; }
            return false, speculative;
        }
        return false, speculative;
    }
    return true, speculative;
}

// addNonNullAttrs
fa_add_non_null_attrs :: (scc: *Fa_Set) {
    scc_returns_non_null := true;
    for f: scc.list {
        if fn_has_ret_attr(f, .NonNull) continue;
        if !fn_has_exact_definition(f) return;
        if !is_ptr_type(fn_ret_type(f)) continue;
        ok, speculative := fa_is_return_non_null(f, scc);
        if ok {
            if !speculative { fn_add_ret_attr_kind(f, .NonNull); fa_mark_changed(f); }
            continue;
        }
        scc_returns_non_null = false;
    }
    if scc_returns_non_null {
        for f: scc.list {
            if fn_has_ret_attr(f, .NonNull) || !is_ptr_type(fn_ret_type(f)) continue;
            fn_add_ret_attr_kind(f, .NonNull);
            fa_mark_changed(f);
        }
    }
}

// addNoUndefAttrs
fa_add_no_undef_attrs :: (scc: *Fa_Set) {
    for f: scc.list {
        l := glob(f).attrs;
        if attr_set_has(attr_list_ret(l), .NoUndef) continue;
        if !fn_has_exact_definition(f) return;
        if fn_has_fn_attr(f, .SanitizeMemory) continue;
        if type_kind(fn_ret_type(f)) == .VOID continue;
        all_ok := true;
        for b: fn_blocks(f) {
            t := block_terminator(b);
            if t == NONE || inst_op(t) != .RET continue;
            rv := op(t, 0);
            if !is_guaranteed_not_to_be_undef_or_poison(rv) { all_ok = false; break; }
            rs := attr_list_ret(l);
            if attr_set_has(rs, .NonNull) && !is_known_non_zero(rv, fa_dl_query()) { all_ok = false; break; }
            al := attr_set_find(rs, .Alignment);
            if al && pointer_alignment(rv) < al.ival { all_ok = false; break; }
            ra := attr_set_find(rs, .Range);
            if ra && !cr_contains_range(attr_range(ra), compute_constant_range(rv, false, fa_dl_query())) { all_ok = false; break; }
            nf := attr_set_find(rs, .NoFPClass);
            if nf && nf.ival != 0 {
                k := compute_known_fp_class(rv, FC_ALL_FLAGS, fa_dl_query());
                if (k.known_fp_classes & cast(u32) nf.ival) != 0 { all_ok = false; break; }
            }
        }
        if all_ok {
            fn_add_ret_attr_kind(f, .NoUndef);
            fa_mark_changed(f);
        }
    }
}

// ---------------------------------------------------------------- AttributeInferer

Fa_Infer :: enum u8 { CONVERGENT; NOUNWIND; NOFREE; NOSYNC; }
fa_infer_skip :: (k: Fa_Infer, f: Value_Id) -> bool {
    if k == {
        case .CONVERGENT; return !fn_has_fn_attr(f, .Convergent);
        case .NOUNWIND; return fn_does_not_throw(f);
        case .NOFREE; return fn_has_fn_attr(f, .NoFree) || fn_only_reads_memory(f);   // doesNotFreeMemory
        case .NOSYNC; return fn_has_fn_attr(f, .NoSync);
    }
    return false;
}
fa_infer_requires_exact :: (k: Fa_Infer) -> bool { return k != .CONVERGENT; }
fa_infer_breaks :: (k: Fa_Infer, i: Value_Id, scc: *Fa_Set) -> bool {
    if k == {
        case .CONVERGENT;
            return is_call_base(i) && call_is_convergent(i) && !fa_set_contains(scc, call_called_function(i));
        case .NOUNWIND;
            if !may_throw(i, true) return false;
            if inst_op(i) == .CALL {
                callee := call_called_function(i);
                if callee != NONE && fa_set_contains(scc, callee) return false;
            }
            return true;
        case .NOFREE;
            if !is_call_base(i) return may_synchronize(i);
            if call_has_fn_attr(i, .NoFree) return false;
            callee := call_called_function(i);
            if callee != NONE && fa_set_contains(scc, callee) return false;
            return true;
        case .NOSYNC;
            if !may_synchronize(i) return false;
            if is_call_base(i) {
                callee := call_called_function(i);
                if callee != NONE && fa_set_contains(scc, callee) return false;
            }
            return true;
    }
    return true;
}
fa_infer_set :: (k: Fa_Infer, f: Value_Id) {
    if k == {
        case .CONVERGENT;
            l := glob(f).attrs;
            fn_set_attr_list(f, attr_list_with_fn(l, attr_set_remove(attr_list_fn(l), .Convergent)));
        case .NOUNWIND; fn_add_fn_attr_kind(f, .NoUnwind);
        case .NOFREE; fn_add_fn_attr_kind(f, .NoFree);
        case .NOSYNC; fn_add_fn_attr_kind(f, .NoSync);
    }
}
// AttributeInferer::run
fa_attribute_inferer_run :: (descs: [] Fa_Infer, scc: *Fa_Set) {
    in_scc: [..] Fa_Infer; in_scc.allocator = temp;
    for descs array_add(*in_scc, it);
    for f: scc.list {
        if in_scc.count == 0 return;
        k := 0;
        while k < in_scc.count {
            d := in_scc[k];
            drop := false;
            if !fa_infer_skip(d, f) drop = is_declaration(f) || (fa_infer_requires_exact(d) && !fn_has_exact_definition(f));
            if drop array_ordered_remove_by_index(*in_scc, k); else k += 1;
        }
        in_this: [..] Fa_Infer; in_this.allocator = temp;
        for in_scc if !fa_infer_skip(it, f) array_add(*in_this, it);
        if in_this.count == 0 continue;
        for i: fn_insts(f) {
            j := 0;
            while j < in_this.count {
                d := in_this[j];
                if !fa_infer_breaks(d, i, scc) { j += 1; continue; }
                m := 0;
                while m < in_scc.count { if in_scc[m] == d array_ordered_remove_by_index(*in_scc, m); else m += 1; }
                array_ordered_remove_by_index(*in_this, j);
            }
            if in_this.count == 0 break;
        }
    }
    if in_scc.count == 0 return;
    for f: scc.list for d: in_scc {
        if fa_infer_skip(d, f) continue;
        fa_mark_changed(f);
        fa_infer_set(d, f);
    }
}

// inferConvergent / inferAttrsFromFunctionBodies
fa_infer_convergent :: (scc: *Fa_Set) { fa_attribute_inferer_run(.[Fa_Infer.CONVERGENT], scc); }
fa_infer_attrs_from_function_bodies :: (scc: *Fa_Set) {
    descs: [..] Fa_Infer; descs.allocator = temp;
    if !fa_opts.disable_nounwind_inference array_add(*descs, .NOUNWIND);
    if !fa_opts.disable_nofree_inference array_add(*descs, .NOFREE);
    array_add(*descs, .NOSYNC);
    fa_attribute_inferer_run(descs, scc);
}

// ---------------------------------------------------------------- norecurse, noreturn, cold, willreturn

// mayHaveRecursiveCallee
fa_may_have_recursive_callee :: (f: Value_Id, any_address_taken := true) -> bool {
    for i: fn_insts(f) {
        if !is_call_base(i) continue;
        callee := call_called_function(i);
        if callee == NONE || callee == f return true;
        if fn_does_not_recurse(callee) continue;
        if !any_address_taken || (is_declaration(callee) && fn_has_fn_attr(callee, .NoCallback)) continue;
        return true;
    }
    return false;
}
// addNoRecurseAttrs
fa_add_no_recurse_attrs :: (scc: *Fa_Set) {
    if scc.list.count != 1 return;
    f := scc.list[0];
    if !fn_has_exact_definition(f) || fn_does_not_recurse(f) return;
    if !fa_may_have_recursive_callee(f) {
        fn_add_fn_attr_kind(f, .NoRecurse);
        fa_mark_changed(f);
    }
}
// canReturn (CFG.cpp)
fn_can_return :: (f: Value_Id) -> bool {
    worklist: [..] Value_Id; worklist.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    e := fn_entry(f);
    table_set(*visited, e, true);
    array_add(*worklist, e);
    succs: [..] Value_Id; succs.allocator = temp;
    while worklist.count {
        bb := pop(*worklist);
        t := block_terminator(bb);
        if t != NONE && inst_op(t) == .RET {
            no_ret := false;
            for i: block_insts(bb) if is_call_base(i) && call_has_fn_attr(i, .NoReturn) { no_ret = true; break; }
            if !no_ret return true;
        }
        block_successors(bb, *succs);
        for s: succs if !table_contains(*visited, s) { table_set(*visited, s, true); array_add(*worklist, s); }
    }
    return false;
}
// addNoReturnAttrs
fa_add_no_return_attrs :: (scc: *Fa_Set) {
    for f: scc.list {
        if !fn_has_exact_definition(f) || fn_has_fn_attr(f, .Naked) || fn_has_fn_attr(f, .NoReturn) continue;
        if !fn_can_return(f) { fn_add_fn_attr_kind(f, .NoReturn); fa_mark_changed(f); }
    }
}
// allPathsGoThroughCold
fa_all_paths_go_through_cold :: (f: Value_Id) -> bool {
    cold: Table(Value_Id, bool); cold.allocator = temp;
    e := fn_entry(f);
    table_set(*cold, e, false);
    jobs: [..] Value_Id; jobs.allocator = temp;
    array_add(*jobs, e);
    succs: [..] Value_Id; succs.allocator = temp;
    while jobs.count {
        bb := pop(*jobs);
        has_cold := false;
        for i: block_insts(bb) if is_call_base(i) && call_has_fn_attr(i, .Cold) { has_cold = true; break; }
        if has_cold { table_set(*cold, bb, true); continue; }
        block_successors(bb, *succs);
        if succs.count == 0 return false;
        for s: succs {
            found, v := table_find(*cold, s);
            if found { if v continue; return false; }
            table_set(*cold, s, false);
            array_add(*jobs, s);
        }
    }
    return true;
}
// addColdAttrs
fa_add_cold_attrs :: (scc: *Fa_Set) {
    for f: scc.list {
        if !fn_has_exact_definition(f) || fn_has_fn_attr(f, .Naked) || fn_has_fn_attr(f, .Cold) || fn_has_fn_attr(f, .Hot) continue;
        if fa_all_paths_go_through_cold(f) { fn_add_fn_attr_kind(f, .Cold); fa_mark_changed(f); }
    }
}
// functionWillReturn
fa_function_will_return :: (f: Value_Id) -> bool {
    if !fn_has_exact_definition(f) return false;
    if fn_has_fn_attr(f, .MustProgress) && fn_only_reads_memory(f) return true;
    if is_declaration(f) return false;
    be: [..] Block_Edge; be.allocator = temp;
    find_function_backedges(f, *be);
    if be.count return false;
    for i: fn_insts(f) if !will_return(i) return false;
    return true;
}
// addWillReturn
fa_add_will_return :: (scc: *Fa_Set) {
    for f: scc.list {
        if fn_will_return(f) || !fa_function_will_return(f) continue;
        fn_add_fn_attr_kind(f, .WillReturn);
        fa_mark_changed(f);
    }
}

// ---------------------------------------------------------------- the passes

// deriveAttrsInPostOrder
fa_derive_attrs_in_post_order :: (functions: [] Value_Id, arg_attrs_only: bool) {
    scc: Fa_Set; scc.list.allocator = temp;
    for f: functions {
        if fn_has_fn_attr(f, .OptimizeNone) || fn_has_fn_attr(f, .Naked) || fn_has_fn_attr(f, .PresplitCoroutine) continue;
        array_add(*scc.list, f);
    }
    if scc.list.count == 0 return;
    if arg_attrs_only { fa_add_argument_attrs(*scc, true); return; }
    fa_add_argument_returned_attrs(*scc);
    fa_add_memory_attrs(*scc);
    fa_add_argument_attrs(*scc, false);
    fa_infer_convergent(*scc);
    fa_add_no_return_attrs(*scc);
    fa_add_cold_attrs(*scc);
    fa_add_will_return(*scc);
    fa_add_no_undef_attrs(*scc);
    fa_add_no_alias_attrs(*scc);
    fa_add_non_null_attrs(*scc);
    fa_infer_attrs_from_function_bodies(*scc);
    fa_add_no_recurse_attrs(*scc);
    for f: scc.list if infer_attributes_from_others(f) fa_mark_changed(f);
}

// PostOrderFunctionAttrsPass::run
function_attrs_run_scc :: (node: *Pass_Node, c: s32) -> Preserved {
    skip_non_recursive := false;
    if node.name != "function-attrs" {
        if node.name == "function-attrs<skip-non-recursive-function-attrs>" skip_non_recursive = true;
        else fatal("invalid function-attrs pass parameter in '%'", node.name);
    }
    arg_attrs_only := false;
    nodes := lcg.sccs[c].nodes;
    if nodes.count == 1 && skip_non_recursive {
        n := nodes[0];
        if lcg_seq_lookup(lcg_seq(n), n) < 0 arg_attrs_only = true;
    }
    functions: [..] Value_Id; functions.allocator = temp;
    for nodes array_add(*functions, lcg_fn(it));
    fa_changed.data = null; fa_changed.count = 0; fa_changed.allocated = 0;
    fa_changed.allocator = temp;
    fa_derive_attrs_in_post_order(functions, arg_attrs_only);
    if fa_changed.count == 0 return PRESERVE_ALL;
    printer_note_ir_changed();
    func_pa := preserved_cfg();
    for ch: fa_changed {
        fam_invalidate(ch, func_pa);
        u := ir.v_first_use[ch];
        while u != NONE {
            user := ir.u_user[u];
            if vkind(user) == .INST && is_call_base(user) && call_callee(user) == ch fam_invalidate(inst_fn(user), func_pa);
            u = ir.u_next[u];
        }
    }
    pa: Preserved;
    pa.all_fn = true;
    return pa;
}

// addNoRecurseAttrsTopDown
fa_add_no_recurse_attrs_top_down :: (f: Value_Id) -> bool {
    if fn_does_not_recurse(f) return false;
    u := ir.v_first_use[f];
    while u != NONE {
        user := ir.u_user[u];
        if !(vkind(user) == .INST && is_call_base(user)) return false;
        if u - ir.v_ops[user] != nops(user) - 1 return false;   // isCallee
        if !fn_does_not_recurse(inst_fn(user)) return false;
        u = ir.u_next[u];
    }
    fn_add_fn_attr_kind(f, .NoRecurse);
    return true;
}
// addNoFPClassAttrsTopDown
fa_add_no_fp_class_attrs_top_down :: (f: Value_Id) -> bool {
    nargs := glob(f).nargs;
    args_nofp := NewArray(nargs, u32,, allocator = temp);
    for * args_nofp it.* = FC_ALL_FLAGS;
    ret_nofp: u32 = FC_ALL_FLAGS;
    u := ir.v_first_use[f];
    while u != NONE {
        user := ir.u_user[u];
        if !(vkind(user) == .INST && is_call_base(user)) || call_called_function(user) != f return false;
        ret_nofp &= fpc_ret_no_fp_class(user);
        for k: 0..cast(s64) nargs - 1 {
            ok, cst := pm_apfloat(call_arg(user, cast(u32) k));
            if ok args_nofp[k] &= ~apf_classify(cst) & FC_ALL_FLAGS;
            else args_nofp[k] &= call_param_no_fp_class(user, cast(u32) k);
        }
        u = ir.u_next[u];
    }
    changed := false;
    if ret_nofp != 0 {
        old := attr_set_find(attr_list_ret(glob(f).attrs), .NoFPClass);
        old_m: u32 = ifx old then cast(u32) old.ival else 0;
        if old_m != ret_nofp {
            l := glob(f).attrs;
            ps := ifx l == 0 then .[] else ir.attr_lists[l].params;
            fn_set_attr_list(f, attr_list_get(attr_list_fn(l), attr_set_with(attr_list_ret(l), attr_nofpclass(ret_nofp)), ps));
            changed = true;
        }
    }
    for k: 0..cast(s64) nargs - 1 {
        m := args_nofp[k];
        if m == 0 continue;
        if fpc_arg_no_fp_class(fn_arg(f, cast(u32) k)) == m continue;
        fn_add_param_attr(f, cast(u32) k, attr_nofpclass(m));
        changed = true;
    }
    return changed;
}

// ReversePostOrderFunctionAttrsPass::run
rpo_function_attrs_run :: () -> Preserved {
    lcg_get();
    worklist: [..] Value_Id; worklist.allocator = temp;
    lcg_build_ref_sccs();
    rc := lcg_postorder_from(0);
    while rc >= 0 {
        for c: lcg.rcs[rc].sccs {
            if lcg.sccs[c].nodes.count != 1 continue;
            f := lcg_fn(lcg.sccs[c].nodes[0]);
            if !is_declaration(f) && glob(f).linkage == .INTERNAL && has_uses(f) array_add(*worklist, f);
        }
        rc = lcg_postorder_next(rc);
    }
    changed := false;
    for < f: worklist {
        changed |= fa_add_no_recurse_attrs_top_down(f);
        changed |= fa_add_no_fp_class_attrs_top_down(f);
    }
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    pa: Preserved;
    pa.lcg = true;
    return pa;
}

// NoRecurseLTOInferencePass::run
norecurse_lto_inference_run :: () -> Preserved {
    any_taken := false;
    for f: ir.m_functions {
        if is_declaration(f) || fn_does_not_recurse(f) continue;
        if !gv_has_local_linkage(f) || fn_has_address_taken(f) { any_taken = true; break; }
    }
    changed := false;
    lcg_get();
    lcg_build_ref_sccs();
    rc := lcg_postorder_from(0);
    while rc >= 0 {
        defer rc = lcg_postorder_next(rc);
        if lcg.rcs[rc].sccs.count > 1 continue;
        c := lcg.rcs[rc].sccs[0];
        if lcg.sccs[c].nodes.count > 1 continue;
        f := lcg_fn(lcg.sccs[c].nodes[0]);
        if !fn_has_exact_definition(f) || fn_does_not_recurse(f) continue;
        if !fa_may_have_recursive_callee(f, any_taken) {
            fn_add_fn_attr_kind(f, .NoRecurse);
            changed = true;
        }
    }
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    pa: Preserved;
    pa.lcg = true;
    return pa;
}

// Function::hasAddressTaken() with the default arguments (IgnoreAssumeLikeCalls = true)
fn_has_address_taken :: (f: Value_Id) -> bool {
    u := ir.v_first_use[f];
    while u != NONE {
        defer u = ir.u_next[u];
        usr := ir.u_user[u];
        if !(is_inst(usr) && is_call_base(usr)) {
            o := opr_code(usr);
            if o == .BITCAST || o == .ADDRSPACECAST {
                all_assume_like := true;
                x := ir.v_first_use[usr];
                while x != NONE {
                    uu := ir.u_user[x];
                    if !(is_inst(uu) && is_assume_like_intrinsic(uu)) { all_assume_like = false; break; }
                    x = ir.u_next[x];
                }
                if all_assume_like continue;
            }
            return true;
        }
        if is_assume_like_intrinsic(usr) continue;
        if opno_of(u) != nops(usr) - 1 || inst(usr).ty2 != glob(f).value_type return true;
    }
    return false;
}

// cl::opts of the IPO passes (FunctionAttrs.cpp, CGSCCPassManager.cpp, the inliner files)
ipo_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    parse_bool :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("invalid boolean value '%' for option -%", value, name);
        return false;
    }
    if name == "enable-poison-arg-attr-prop" { fa_opts.enable_poison_arg_attr_prop = parse_bool(name, value, has_value); return true; }
    if name == "disable-nounwind-inference" { fa_opts.disable_nounwind_inference = parse_bool(name, value, has_value); return true; }
    if name == "disable-nofree-inference" { fa_opts.disable_nofree_inference = parse_bool(name, value, has_value); return true; }
    if name == "abort-on-max-devirt-iterations-reached" { cgscc_opts.abort_on_max_devirt = parse_bool(name, value, has_value); return true; }
    return inliner_parse_cl_opt(name, value, has_value);
}
