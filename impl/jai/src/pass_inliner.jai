// The inliners: a port of llvm/lib/Transforms/IPO/Inliner.cpp (InlinerPass::run, the CGSCC `inline` pass with
// -intra-scc-cost-multiplier and -inliner-forwarding-scan-limit, makeFunctionBodyUnreachable), of
// llvm/lib/Transforms/IPO/AlwaysInliner.cpp (`always-inline`), of the default advisor of
// llvm/lib/Analysis/InlineAdvisor.cpp (DefaultInlineAdvisor::getAdviceImpl, getDefaultInlineAdvice, shouldInline,
// shouldBeDeferred, InlineAdvisor::getAdvice / getMandatoryKind, setInlineRemark with -inline-remark-attribute,
// -inline-deferral, -inline-deferral-scale), of tryPromoteCall (CallPromotionUtils.cpp; promoteCall itself fails
// loudly) and of filterDeadComdatFunctions (ModuleUtils.cpp).
//
// The advisor's InlineAdvice objects only emit remarks and the inline-remark attribute here (opt prints no remarks
// without -pass-remarks*), so recordUnsuccessfulInlining is the only record call with an effect.
//
// Not ported (fail loudly when used): the replay advisor (-cgscc-inline-replay), the ML / plugin advisors,
// inliner-wrapper's InlineAdvisorAnalysis printing, InlineOrder / ModuleInliner (module-inline).

inl_opts: struct {
    intra_scc_cost_multiplier: s64 = 2;    // -intra-scc-cost-multiplier
    forwarding_scan_limit: u32 = 16;       // -inliner-forwarding-scan-limit
    inline_remark_attribute := false;      // -inline-remark-attribute
    enable_inline_deferral := false;       // -inline-deferral
    inline_deferral_scale: s64 = 2;        // -inline-deferral-scale
    max_devirt_iterations: s64 = 4;        // -max-devirt-iterations (PassBuilderPipelines.cpp)
};

inliner_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    int_opt :: (name: string, value: string, has_value: bool) -> s64 {
        if !has_value fatal("option -% needs a value", name);
        v, ok, rest := string_to_int(value);
        if !ok || rest.count fatal("invalid integer value '%' for option -%", value, name);
        return v;
    }
    bool_opt :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("invalid boolean value '%' for option -%", value, name);
        return false;
    }
    if name == {
        case "intra-scc-cost-multiplier"; inl_opts.intra_scc_cost_multiplier = int_opt(name, value, has_value);
        case "inliner-forwarding-scan-limit"; inl_opts.forwarding_scan_limit = cast(u32) int_opt(name, value, has_value);
        case "inline-remark-attribute"; inl_opts.inline_remark_attribute = bool_opt(name, value, has_value);
        case "inline-deferral"; inl_opts.enable_inline_deferral = bool_opt(name, value, has_value);
        case "inline-deferral-scale"; inl_opts.inline_deferral_scale = int_opt(name, value, has_value);
        case "max-devirt-iterations"; inl_opts.max_devirt_iterations = int_opt(name, value, has_value);
        case; return inline_cost_parse_cl_opt(name, value, has_value);
    }
    return true;
}

// setInlineRemark
set_inline_remark :: (cb: Value_Id, msg: string) {
    if !inl_opts.inline_remark_attribute return;
    a: Attr; a.kind = .STRING_ATTR; a.ty = NONE; a.key = "inline-remark"; a.val = msg;
    call_add_fn_attr(cb, a);
}
// CallBase::addFnAttr(Attribute)
call_add_fn_attr :: (cb: Value_Id, a: Attr) {
    l := inst(cb).attrs;
    items: [..] Attr; items.allocator = temp;
    for attr_set_items(attr_list_fn(l)) {
        same := ifx a.kind == .STRING_ATTR then (it.kind == .STRING_ATTR && it.key == a.key) else it.kind == a.kind;
        if !same array_add(*items, it);
    }
    array_add(*items, a);
    inst(cb).attrs = attr_list_with_fn(l, attr_set_get(items));
}

// shouldBeDeferred
should_be_deferred :: (caller: Value_Id, ic: Inline_Cost, params: Inline_Params, total_secondary_cost: *s64) -> bool {
    if !gv_has_local_linkage(caller) && glob(caller).linkage != .LINKONCE_ODR return false;
    if ic.cost <= 0 return false;
    total_secondary_cost.* = 0;
    candidate_cost := ic.cost - 1;
    apply_last_call_bonus := gv_has_local_linkage(caller) && !value_has_one_use(caller);
    prevents := false;
    num_caller_users: s64 = 0;
    u := ir.v_first_use[caller];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if !(vkind(usr) == .INST && is_call_base(usr)) || call_called_function(usr) != caller { apply_last_call_bonus = false; continue; }
        ic2 := get_inline_cost(usr, params);
        if !ic_bool(ic2) { apply_last_call_bonus = false; continue; }
        if ic_is_always(ic2) continue;
        if ic_cost_delta(ic2) <= candidate_cost {
            prevents = true;
            total_secondary_cost.* += ic2.cost;
            num_caller_users += 1;
        }
    }
    if !prevents return false;
    if apply_last_call_bonus total_secondary_cost.* -= IC_LAST_CALL_TO_STATIC_BONUS;
    if inl_opts.inline_deferral_scale < 0 return total_secondary_cost.* < ic.cost;
    total_cost := total_secondary_cost.* + ic.cost * num_caller_users;
    allowance := ic.cost * inl_opts.inline_deferral_scale;
    return total_cost < allowance;
}

// getDefaultInlineAdvice + shouldInline: (has advice, the cost)
default_inline_advice :: (cb: Value_Id, params: Inline_Params) -> (bool, Inline_Cost) {
    ic := get_inline_cost(cb, params);
    if ic_is_always(ic) return true, ic;
    if !ic_bool(ic) {
        set_inline_remark(cb, inline_cost_str(ic));
        return false, ic;
    }
    enable_deferral := ifx params.has_enable_deferral then params.enable_deferral else inl_opts.enable_inline_deferral;
    tsc: s64 = 0;
    if enable_deferral && should_be_deferred(inst_fn(cb), ic, params, *tsc) {
        set_inline_remark(cb, "deferred");
        return false, ic;
    }
    return true, ic;
}

// tryPromoteCall
try_promote_call :: (cb: Value_Id) -> bool {
    callee := call_callee(cb);
    if !(vkind(callee) == .INST && inst_op(callee) == .LOAD) return false;
    entry_ptr := op(callee, 0);
    base, voff := strip_and_accumulate_constant_offsets(entry_ptr, ap_zero(dl_index_type_size_bits(vtype(entry_ptr))), true);
    if !(vkind(base) == .INST && inst_op(base) == .LOAD) return false;
    object := op(base, 0);
    ob, ooff := strip_and_accumulate_constant_offsets(object, ap_zero(dl_index_type_size_bits(vtype(object))), true);
    if !(vkind(ob) == .INST && inst_op(ob) == .ALLOCA && ap_is_zero(ooff)) return false;
    loc := mloc_get(base);
    vtable_ptr, _ := find_available_ptr_load_store(loc, vtype(base), inst(base).ord1 != 0, inst_block(base), base, 0, null, null, null);
    if vtable_ptr == NONE || !is_ptr_type(vtype(vtable_ptr)) return false;
    gvb, gvoff := strip_and_accumulate_constant_offsets(vtable_ptr, ap_zero(dl_index_type_size_bits(vtype(vtable_ptr))), true);
    if !(vkind(gvb) == .GLOBAL_VAR && glob(gvb).is_const && gv_has_definitive_initializer(gvb)) return false;
    fatal("inline: promoting an indirect call through a constant vtable (tryPromoteCall / promoteCall) is not implemented yet");
    return false;
}
// makeFunctionBodyUnreachable
make_function_body_unreachable :: (f: Value_Id) {
    fn_drop_all_references(f);
    bb := create_block(f, "");
    block_append_inst(bb, new_inst(.UNREACHABLE, ir.t_void, 0));
}

// GlobalValue::isDiscardableIfUnused
gv_is_discardable_if_unused :: (g: Value_Id) -> bool {
    l := glob(g).linkage;
    return l == .LINKONCE_ANY || l == .LINKONCE_ODR || l == .INTERNAL || l == .PRIVATE || l == .AVAILABLE_EXTERNALLY;
}
fn_has_zero_live_uses :: (f: Value_Id) -> bool { return const_has_n_live_uses(f, 0); }

// The InlinerPass object: OwnedAdvisor's DefaultInlineAdvisor holds only the params
INLINER_NODE_PARAMS :: struct { only_mandatory: bool; }

// InlinerPass::run
inliner_run :: (node: *Pass_Node, initial_c: s32, ur: *Cgscc_Ur) -> Preserved {
    only_mandatory := false;
    if node.name == "inline<only-mandatory>" only_mandatory = true;
    else if node.name != "inline" fatal("invalid inline pass parameter in '%'", node.name);
    params := get_inline_params();
    changed := false;
    calls: [..] Value_Id;
    defer array_free(calls);
    for n: lcg.sccs[initial_c].nodes {
        f := lcg_fn(n);
        for i: fn_insts(f) {
            if !is_call_base(i) continue;
            callee := call_called_function(i);
            if callee == NONE continue;
            if !is_declaration(callee) array_add(*calls, i);
            else if !glob(callee).intrinsic set_inline_remark(i, "unavailable definition");
        }
    }
    c := initial_c;
    if calls.count == 0 return PRESERVE_ALL;
    inlined_callees: [..] Value_Id;
    defer array_free(inlined_callees);
    dead_functions: [..] Value_Id;
    defer array_free(dead_functions);
    dead_in_comdats: [..] Value_Id;
    defer array_free(dead_in_comdats);
    i := 0;
    while i < calls.count {
        f := inst_fn(calls[i]);
        nd := lcg_lookup(f);
        if lcg_lookup_scc(nd) != c { i += 1; continue; }
        did_inline := false;
        while i < calls.count && inst_fn(calls[i]) == f {
            defer i += 1;
            cb := calls[i];
            callee := call_called_function(cb);
            callee_n := lcg_lookup(callee);
            callee_scc := lcg_lookup_scc(callee_n);
            if callee_scc == c && table_contains(*ur.inlined_internal_edges, ie_key(nd, c)) {
                set_inline_remark(cb, "recursive SCC split");
                continue;
            }
            if did_inline {
                for k: 0..cast(s64) call_num_args(cb) - 1 {
                    li := call_arg(cb, cast(u32) k);
                    if !(vkind(li) == .INST && inst_op(li) == .LOAD && is_simple_load_store(li)) continue;
                    loc := mloc_get(li);
                    avail, _ := find_available_ptr_load_store(loc, vtype(li), inst(li).ord1 != 0, inst_block(li), li, inl_opts.forwarding_scan_limit, null, null, null);
                    if avail == NONE continue;
                    if !is_constant_kind(vkind(avail)) continue;
                    cst := avail;
                    if vtype(cst) != vtype(li) {
                        if is_null_value(cst) cst = const_null_value(vtype(li));
                        else continue;
                    }
                    replace_all_uses_with(li, cst);
                    erase_inst(li);
                }
            }
            // InlineAdvisor::getAdvice
            recommended: bool;
            if !only_mandatory {
                ok, ic := default_inline_advice(cb, params);
                recommended = ok;
                if !recommended continue;
                ifi: Inline_Function_Info;
                ifi.use_assumption_cache = true;
                ifi.caller_bfi = get_bfi(inst_fn(cb));
                ifi.callee_bfi = get_bfi(callee);
                if !inline_one(cb, callee, callee_n, callee_scc, c, *ifi, ic, ur, *calls, i, *inlined_callees, *dead_functions, *dead_in_comdats, f) continue;
                did_inline = true;
            } else {
                decided, r := get_attribute_based_inlining_decision(cb, callee);
                recommended = inst_fn(cb) != callee && decided && r.ok;
                if !recommended continue;
                ifi: Inline_Function_Info;
                ifi.use_assumption_cache = true;
                ifi.caller_bfi = get_bfi(inst_fn(cb));
                ifi.callee_bfi = get_bfi(callee);
                ic := inline_cost_always("always inline attribute");
                if !inline_one(cb, callee, callee_n, callee_scc, c, *ifi, ic, ur, *calls, i, *inlined_callees, *dead_functions, *dead_in_comdats, f) continue;
                did_inline = true;
            }
        }
        if !did_inline continue;
        changed = true;
        printer_note_ir_changed();
        old_c := c;
        c = update_cg_and_am_for_pass(c, nd, ur, false);
        if c != old_c || pwl_count(ur.cwl, old_c) {
            any := false;
            for ic: inlined_callees if lcg_lookup_scc(lcg_lookup(ic)) == old_c { any = true; break; }
            if any table_set(*ur.inlined_internal_edges, ie_key(nd, old_c), true);
        }
        inlined_callees.count = 0;
        fam_invalidate(f, PRESERVE_NONE);
    }
    if dead_in_comdats.count {
        filter_dead_comdat_functions(*dead_in_comdats);
        for dead_in_comdats make_function_body_unreachable(it);
        for dead_in_comdats array_add(*dead_functions, it);
    }
    for df: dead_functions {
        lcg_mark_dead_function(df);
        dn := lcg_lookup(df);
        dead_c := lcg_lookup_scc(dn);
        table_remove(*fam, df);
        table_set(*ur.invalidated, dead_c, true);
        array_add(*ur.dead_functions, df);
    }
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    pa.all_fn = true;
    return pa;
}

// The body of the inner loop of InlinerPass::run after the advice: returns whether the call was inlined
inline_one :: (cb: Value_Id, callee: Value_Id, callee_n: s32, callee_scc: s32, c: s32, ifi: *Inline_Function_Info, ic: Inline_Cost,
               ur: *Cgscc_Ur, calls: *[..] Value_Id, i: s64, inlined_callees: *[..] Value_Id,
               dead_functions: *[..] Value_Id, dead_in_comdats: *[..] Value_Id, f: Value_Id) -> bool {
    ok, mult := call_str_fn_attr_as_int(cb, "function-inline-cost-multiplier");
    cb_cost_mult: s64 = ifx ok then mult else 1;
    track := lcg.sccs[callee_scc].nodes.count != 1 || lcg.rcs[lcg.sccs[callee_scc].rc].sccs.count != 1 || lcg_seq_lookup(lcg_seq(callee_n), callee_n) >= 0;
    caller := inst_fn(cb);
    aar := aa_results_for(caller);
    r := inline_function(cb, ifi, true, *aar, true, track);
    if !r.ok {
        set_inline_remark(cb, tprint("%; %", r.reason, inline_cost_str(ic)));
        return false;
    }
    found := false;
    for inlined_callees.* if it == callee found = true;
    if !found array_add(inlined_callees, callee);
    if ifi.inlined_call_sites.count {
        for < icb: ifi.inlined_call_sites {
            new_callee := call_called_function(icb);
            if new_callee == NONE {
                if try_promote_call(icb) new_callee = call_called_function(icb);
            }
            if new_callee != NONE && !is_declaration(new_callee) {
                array_add(calls, icb);
                if callee_scc != c && callee_scc == lcg_lookup_scc(lcg_get_node(new_callee)) {
                    a: Attr; a.kind = .STRING_ATTR; a.ty = NONE; a.key = "function-inline-cost-multiplier";
                    a.val = tprint("%", cb_cost_mult * inl_opts.intra_scc_cost_multiplier);
                    call_add_fn_attr(icb, a);
                }
            }
        }
    }
    if gv_is_discardable_if_unused(callee) && fn_has_zero_live_uses(callee) && !lcg_is_lib_function(callee) {
        if gv_has_local_linkage(callee) || glob(callee).comdat < 0 {
            k := i + 1;
            while k < calls.count {
                if inst_fn(calls.*[k]) == callee array_ordered_remove_by_index(calls, k);
                else k += 1;
            }
            make_function_body_unreachable(callee);
            array_add(dead_functions, callee);
        } else array_add(dead_in_comdats, callee);
    }
    return true;
}

// filterDeadComdatFunctions (ModuleUtils.cpp): keep the functions whose comdat has no other live members
filter_dead_comdat_functions :: (dead: *[..] Value_Id) {
    fatal("inline: deleting dead functions in comdats (filterDeadComdatFunctions) is not implemented yet");
}

// ---------------------------------------------------------------- AlwaysInlinerPass

always_inliner_run :: () -> Preserved {
    changed := false;
    calls: [..] Value_Id; calls.allocator = temp;
    need_flattening: [..] Value_Id; need_flattening.allocator = temp;
    inlined_comdat: [..] Value_Id; inlined_comdat.allocator = temp;
    try_inline :: (cb: Value_Id, callee: Value_Id, new_call_sites: *[..] Value_Id) -> bool {
        decided, r := get_attribute_based_inlining_decision(cb, callee);
        if !decided || !r.ok return false;
        caller := inst_fn(cb);
        ifi: Inline_Function_Info;
        ifi.use_assumption_cache = true;
        aar := aa_results_for(callee);
        res := inline_function(cb, *ifi, true, *aar, true, new_call_sites != null);
        if !res.ok return false;
        printer_note_ir_changed();
        fam_invalidate(caller, PRESERVE_NONE);
        if new_call_sites { new_call_sites.count = 0; for ifi.inlined_call_sites array_add(new_call_sites, it); }
        return true;
    }
    fns: [..] Value_Id; fns.allocator = temp;
    for ir.m_functions array_add(*fns, it);
    for f: fns {
        if vkind(f) == .DEAD continue;
        if fn_has_fn_attr(f, .Flatten) array_add(*need_flattening, f);
        if fn_has_fn_attr(f, .PresplitCoroutine) continue;
        if is_declaration(f) || !is_inline_viable(f).ok continue;
        calls.count = 0;
        u := ir.v_first_use[f];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if !(vkind(usr) == .INST && is_call_base(usr)) continue;
            if call_called_function(usr) == f && call_has_fn_attr(usr, .AlwaysInline) && !attr_set_has(call_fn_attrs(usr), .NoInline) {
                found := false;
                for calls if it == usr found = true;
                if !found array_add(*calls, usr);
            }
        }
        for cb: calls changed |= try_inline(cb, f, null);
        remove_dead_constant_users(f);
        if fn_has_fn_attr(f, .AlwaysInline) && fn_is_def_trivially_dead(f) {
            if glob(f).comdat >= 0 array_add(*inlined_comdat, f);
            else {
                table_remove(*fam, f);
                erase_function(f);
                changed = true;
            }
        }
    }
    for f: need_flattening {
        Item :: struct { cb: Value_Id; hist: s64; }
        worklist: [..] Item; worklist.allocator = temp;
        Hist :: struct { f: Value_Id; parent: s64; }
        history: [..] Hist; history.allocator = temp;
        new_sites: [..] Value_Id; new_sites.allocator = temp;
        for i: fn_insts(f) {
            if !is_call_base(i) continue;
            callee := call_called_function(i);
            if callee == NONE || is_declaration(callee) continue;
            array_add(*worklist, .{i, -1});
        }
        while worklist.count {
            item := pop(*worklist);
            cb := item.cb;
            callee := call_called_function(cb);
            if callee == NONE continue;
            if callee == f continue;
            decided, r := get_attribute_based_inlining_decision(cb, callee);
            if !decided || !r.ok continue;
            if !try_inline(cb, callee, *new_sites) continue;
            changed = true;
            if new_sites.count {
                hid := history.count;
                array_add(*history, .{callee, item.hist});
                for ncb: new_sites {
                    nc := call_called_function(ncb);
                    if nc != NONE && !is_declaration(nc) array_add(*worklist, .{ncb, hid});
                }
            }
        }
    }
    if inlined_comdat.count fatal("always-inline: deleting inlined comdat functions (filterDeadComdatFunctions) is not implemented yet");
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    pa.all_fn = true;
    return pa;
}
// Function::isDefTriviallyDead
fn_is_def_trivially_dead :: (f: Value_Id) -> bool {
    l := glob(f).linkage;
    if !(l == .LINKONCE_ANY || l == .LINKONCE_ODR) && !gv_has_local_linkage(f) && l != .AVAILABLE_EXTERNALLY return false;
    return !has_uses(f);
}
