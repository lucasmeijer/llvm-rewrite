// The abstract attributes of llvm/lib/Transforms/IPO/OpenMPOpt.cpp: AAICVTracker (Function, FunctionReturned,
// CallSite, CallSiteReturned), AAExecutionDomainFunction (with the ExecutionDomainTy of
// llvm/include/llvm/Transforms/IPO/Attributor.h), AAHeapToSharedFunction, AAFoldRuntimeCallCallSiteReturned,
// and OpenMPOpt::registerAAs / registerAAsForFunction / registerFoldRuntimeCall. AAKernelInfo is
// openmp_kernel_info.jai. Each AA is an Abs_Attr row of the Attributor (kinds ICV_TRACKER, EXECUTION_DOMAIN,
// HEAP_TO_SHARED, KERNEL_INFO, FOLD_RUNTIME_CALL); its state beyond the BooleanState lives in the extension behind
// `x`, and the virtual calls are the omp_aa_* switches below (called from attributor_aas.jai's).

// ---------------------------------------------------------------- dispatch

omp_aa_construct :: (i: u32) {
    if aa(i).kind == {
        case .ICV_TRACKER; aa(i).x = atr_new(Icv_Ext); icv_construct_defaults(icv_ext(i));
        case .EXECUTION_DOMAIN; aa(i).x = atr_new(Ed_Ext);
        case .HEAP_TO_SHARED; aa(i).x = atr_new(H2sh_Ext);
        case .KERNEL_INFO; aa(i).x = atr_new(Kis_Ext); kis_init(kis_ext(i));
        case .FOLD_RUNTIME_CALL; aa(i).x = atr_new(Frc_Ext);
    }
}
omp_aa_initialize :: (i: u32) {
    if aa(i).kind == {
        case .ICV_TRACKER; if aa(i).pk == .CALL_SITE icv_cs_initialize(i);
        case .EXECUTION_DOMAIN; ed_initialize(i);
        case .HEAP_TO_SHARED; h2sh_initialize(i);
        case .KERNEL_INFO; if aa(i).pk == .FUNCTION ki_fn_initialize(i); else ki_cs_initialize(i);
        case .FOLD_RUNTIME_CALL; frc_initialize(i);
    }
}
omp_aa_update :: (i: u32) -> bool {
    if aa(i).kind == {
        case .ICV_TRACKER;
            if aa(i).pk == {
                case .FUNCTION; return icv_fn_update(i);
                case .RETURNED; return icv_fn_ret_update(i);
                case .CALL_SITE; return icv_cs_update(i);
                case .CALL_SITE_RETURNED; return icv_cs_ret_update(i);
            }
        case .EXECUTION_DOMAIN; return ed_update(i);
        case .HEAP_TO_SHARED; return h2sh_update(i);
        case .KERNEL_INFO; if aa(i).pk == .FUNCTION return ki_fn_update(i); else return ki_cs_update(i);
        case .FOLD_RUNTIME_CALL; return frc_update(i);
    }
    return ATR_UNCHANGED;
}
omp_aa_manifest :: (i: u32) -> bool {
    if aa(i).kind == {
        case .ICV_TRACKER; if aa(i).pk == .CALL_SITE return icv_cs_manifest(i);
        case .EXECUTION_DOMAIN; return ed_manifest(i);
        case .HEAP_TO_SHARED; return h2sh_manifest(i);
        case .KERNEL_INFO; if aa(i).pk == .FUNCTION return ki_fn_manifest(i);
        case .FOLD_RUNTIME_CALL; return frc_manifest(i);
    }
    return ATR_UNCHANGED;
}

// ---------------------------------------------------------------- AAICVTracker

ICV_COUNT :: 4;   // ICV___last
Icv_Ext :: struct {
    values_map: [ICV_COUNT] Table(Value_Id, Value_Id);   // AAICVTrackerFunction::ICVReplacementValuesMap
    repl_vals: [ICV_COUNT] Value_Id;                     // the returned / call-site-returned ICVReplacementValuesMap
    associated_icv: s64;                                 // AAICVTrackerCallSite::AssociatedICV
    repl_val: Value_Id = OV_NOVAL;                       // AAICVTrackerCallSite::ReplVal
}
icv_ext :: inline (i: u32) -> *Icv_Ext { return cast(*Icv_Ext) aa(i).x; }
OMP_TRACKABLE_ICVS :: s64.[0];   // TrackableICVs = {ICV_nthreads}
icv_is_assumed_tracked :: (i: u32) -> bool { return bs_is_assumed(aa(i).s, 1); }

icv_construct_defaults :: (e: *Icv_Ext) { for * e.repl_vals it.* = OV_NOVAL; }

// getUniqueReplacementValue
icv_unique_replacement_value :: (i: u32, icv: s64) -> Value_Id {
    e := icv_ext(i);
    if aa(i).pk == {
        case .FUNCTION; return OV_NOVAL;
        case .CALL_SITE; return e.repl_val;
    }
    return e.repl_vals[icv];
}

// AAICVTrackerFunction::getValueForCall
icv_value_for_call :: (i: u32, x: Value_Id, icv: s64) -> Value_Id {
    if !is_call_base(x) || call_has_fn_str_attr(x, "no_openmp") || call_has_fn_str_attr(x, "no_openmp_routines") ||
       call_has_fn_str_attr(x, "no_openmp_constructs") return OV_NOVAL;
    getter := omp_rfi(cast(Omp_Rtl) OMP_ICVS[icv].getter);
    setter := omp_rfi(cast(Omp_Rtl) OMP_ICVS[icv].setter);
    called := call_called_function(x);
    if called == NONE return NONE;
    if called == getter.declaration return OV_NOVAL;
    if called == setter.declaration {
        found, v := table_find(*icv_ext(i).values_map[icv], x);
        if found return v;
        return NONE;
    }
    if is_declaration(called) return NONE;
    t := atr_get_aa(.ICV_TRACKER, irp_cs_returned(x), i, DEP_REQUIRED);
    if t == NONE fatal("internal: openmp-opt: no AAICVTracker for a call site");
    if icv_is_assumed_tracked(t) {
        urv := icv_unique_replacement_value(t, icv);
        if urv == OV_NOVAL || (urv != NONE && atr_is_valid_at_position(urv, x)) return urv;
    }
    return NONE;
}

// AAICVTrackerFunction::updateImpl
icv_fn_update :: (i: u32) -> bool {
    has_changed := ATR_UNCHANGED;
    f := irp_anchor_scope(aa(i).pos);
    for icv: OMP_TRACKABLE_ICVS {
        setter := omp_rfi(cast(Omp_Rtl) OMP_ICVS[icv].setter);
        vm := *icv_ext(i).values_map[icv];
        for u: omp_rfi_uses_in(setter, *f) {
            ci := omp_call_if_regular_call_use(u);
            if ci == NONE continue;
            if !table_contains(vm, ci) { table_set(vm, ci, call_arg(ci, 0)); has_changed = ATR_CHANGED; }
        }
        uai := false;
        ok := true;
        for x: atr_insts(i, .[.CALL], *uai, *ok, true) {
            r := icv_value_for_call(i, x, icv);
            if r != OV_NOVAL && !table_contains(vm, x) { table_set(vm, x, r); has_changed = ATR_CHANGED; }
        }
        entry := block_first(fn_entry(f));
        if has_changed && !table_contains(vm, entry) table_set(vm, entry, NONE);
    }
    return has_changed;
}

// AAICVTrackerFunction::getReplacementValue
icv_fn_replacement_value :: (i: u32, icv: s64, x: Value_Id) -> Value_Id {
    vm := *icv_ext(i).values_map[icv];
    found, v := table_find(vm, x);
    if found return v;
    work: [..] Value_Id; work.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    array_add(*work, x);
    repl := OV_NOVAL;
    preds: [..] Value_Id; preds.allocator = temp;
    while work.count {
        cur := pop(*work);
        if table_contains(*visited, cur) continue;
        table_set(*visited, cur, true);
        cur_bb := inst_block(cur);
        while true {
            cur = inst_prev(cur);
            if cur == NONE break;
            f2, nv := table_find(vm, cur);
            if f2 {
                if repl == OV_NOVAL { repl = nv; break; }
                if repl != nv return NONE;   // a new (engaged) value differs
                break;
            }
            nv2 := icv_value_for_call(i, cur, icv);
            if nv2 == OV_NOVAL continue;
            if repl == OV_NOVAL { repl = nv2; break; }
            if repl != nv2 return NONE;
        }
        if cur_bb == inst_block(x) && repl != OV_NOVAL return repl;
        preds.count = 0;
        block_predecessors(cur_bb, *preds);
        for p: preds {
            t := block_terminator(p);
            if t != NONE array_add(*work, t);
        }
    }
    return repl;
}

// AAICVTrackerFunctionReturned::updateImpl
icv_fn_ret_update :: (i: u32) -> bool {
    changed := ATR_UNCHANGED;
    t := atr_get_aa(.ICV_TRACKER, irp_function(irp_anchor_scope(aa(i).pos)), i, DEP_REQUIRED);
    if t == NONE fatal("internal: openmp-opt: no AAICVTracker for a function");
    if !icv_is_assumed_tracked(t) return aa_pessimistic(i);
    for icv: OMP_TRACKABLE_ICVS {
        unique := OV_NOVAL;
        uai := false;
        ok := true;
        for x: atr_insts(i, .[.RET], *uai, *ok, true) {
            nv := icv_fn_replacement_value(t, icv, x);
            if unique != OV_NOVAL && unique != nv { ok = false; break; }
            unique = nv;
        }
        if !ok unique = NONE;
        e := icv_ext(i);
        if unique == e.repl_vals[icv] continue;
        e.repl_vals[icv] = unique;
        changed = ATR_CHANGED;
    }
    return changed;
}

// AAICVTrackerCallSite::initialize / updateImpl / manifest
icv_cs_initialize :: (i: u32) {
    for icv: OMP_TRACKABLE_ICVS {
        getter := omp_rfi(cast(Omp_Rtl) OMP_ICVS[icv].getter);
        if getter.declaration == irp_assoc_fn(aa(i).pos) { icv_ext(i).associated_icv = icv; return; }
    }
    aa_pessimistic(i);
}
icv_cs_update :: (i: u32) -> bool {
    t := atr_get_aa(.ICV_TRACKER, irp_function(irp_anchor_scope(aa(i).pos)), i, DEP_REQUIRED);
    if t == NONE fatal("internal: openmp-opt: no AAICVTracker for a function");
    if !icv_is_assumed_tracked(t) return aa_pessimistic(i);
    e := icv_ext(i);
    nv := icv_fn_replacement_value(t, e.associated_icv, irp_ctx_i(aa(i).pos));
    if e.repl_val == nv return ATR_UNCHANGED;
    e.repl_val = nv;
    return ATR_CHANGED;
}
icv_cs_manifest :: (i: u32) -> bool {
    e := icv_ext(i);
    if e.repl_val == OV_NOVAL || e.repl_val == NONE return ATR_UNCHANGED;
    ctx := irp_ctx_i(aa(i).pos);
    atr_change_after_manifest(irp_inst(ctx), e.repl_val);
    atr_delete_inst_after_manifest(ctx);
    return ATR_CHANGED;
}
// AAICVTrackerCallSiteReturned::updateImpl
icv_cs_ret_update :: (i: u32) -> bool {
    changed := ATR_UNCHANGED;
    t := atr_get_aa(.ICV_TRACKER, irp_returned(irp_assoc_fn(aa(i).pos)), i, DEP_REQUIRED);
    if t == NONE fatal("internal: openmp-opt: no AAICVTracker for a returned position");
    if !icv_is_assumed_tracked(t) return aa_pessimistic(i);
    e := icv_ext(i);
    for icv: OMP_TRACKABLE_ICVS {
        nv := icv_unique_replacement_value(t, icv);
        if e.repl_vals[icv] == nv continue;
        e.repl_vals[icv] = nv;
        changed = ATR_CHANGED;
    }
    return changed;
}

// ---------------------------------------------------------------- AAExecutionDomain

// AAExecutionDomain::ExecutionDomainTy. AlignedBarriers / EncounteredAssumes are SmallPtrSets in LLVM: they are
// only tested, merged and deleted from, never in an order that shows (kept in insertion order here).
Ed :: struct {
    initial_thread_only := true;            // IsExecutedByInitialThreadOnly
    reached_from_aligned_barrier_only := true;
    reaching_aligned_barrier_only := true;
    encountered_non_local_side_effect := false;
    aligned_barriers: [..] Value_Id;
    encountered_assumes: [..] Value_Id;
}
ed_set_add :: (l: *[..] Value_Id, v: Value_Id) {
    for l.* if it == v return;
    if !l.allocator.proc l.allocator = atr_allocator();
    array_add(l, v);
}
ed_clear_assumes_and_barriers :: (e: *Ed) { e.aligned_barriers.count = 0; e.encountered_assumes.count = 0; }
// a fresh copy whose sets do not share storage with `e`
ed_copy :: (e: Ed) -> Ed {
    r := e;
    fresh_a: [..] Value_Id; fresh_b: [..] Value_Id;
    r.aligned_barriers = fresh_a; r.encountered_assumes = fresh_b;
    r.aligned_barriers.allocator = atr_allocator(); r.encountered_assumes.allocator = atr_allocator();
    for e.aligned_barriers array_add(*r.aligned_barriers, it);
    for e.encountered_assumes array_add(*r.encountered_assumes, it);
    return r;
}

ED_PRE :: cast(u64) 0;
ED_POST :: cast(u64) 1;
Ed_Ext :: struct {
    inter_procedural_ed: Ed;                 // InterProceduralED
    bed_map: Table(Value_Id, *Ed);           // BEDMap (NONE: the function's entry/exit domain)
    ced_map: Table(u64, *Ed);                // CEDMap: (call << 1) | PRE/POST
    aligned_barriers: [..] Value_Id;         // SmallSetVector<CallBase *>
    rpot: [..] Value_Id;                     // ReversePostOrderTraversal<Function *> from initialize
    non_noop_fences: Table(Value_Id, bool);
}
ed_ext :: inline (i: u32) -> *Ed_Ext { return cast(*Ed_Ext) aa(i).x; }
// BEDMap[BB] / CEDMap[{CB, Dir}] (default-constructed on first access)
ed_bed :: (i: u32, bb: Value_Id) -> *Ed {
    e := ed_ext(i);
    found, p := table_find(*e.bed_map, bb);
    if found return p;
    p = atr_new(Ed);
    table_set(*e.bed_map, bb, p);
    return p;
}
ed_ced :: (i: u32, cb: Value_Id, dir: u64) -> *Ed {
    e := ed_ext(i);
    k := ((cast(u64) cb) << 1) | dir;
    found, p := table_find(*e.ced_map, k);
    if found return p;
    p = atr_new(Ed);
    table_set(*e.ced_map, k, p);
    return p;
}
// BEDMap.lookup(BB) / CEDMap.lookup: a default ExecutionDomainTy if absent
ed_bed_lookup :: (i: u32, bb: Value_Id) -> Ed {
    found, p := table_find(*ed_ext(i).bed_map, bb);
    if found return p.*;
    d: Ed;
    return d;
}
ed_ced_lookup :: (i: u32, cb: Value_Id, dir: u64) -> (bool, Ed) {
    found, p := table_find(*ed_ext(i).ced_map, ((cast(u64) cb) << 1) | dir);
    if found return true, p.*;
    d: Ed;
    return false, d;
}

ed_initialize :: (i: u32) {
    f := irp_anchor_scope(aa(i).pos);
    e := ed_ext(i);
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(f), *po);
    for < po array_add(*e.rpot, it);
}

// isExecutedByInitialThreadOnly(BB)
ed_is_executed_by_initial_thread_only :: (i: u32, bb: Value_Id) -> bool {
    if !aa_is_valid(i) return false;
    return ed_bed_lookup(i, bb).initial_thread_only;
}
// isNoOpFence
ed_is_no_op_fence :: (i: u32, fi: Value_Id) -> bool {
    return aa_is_valid(i) && !table_contains(*ed_ext(i).non_noop_fences, fi);
}
// getFunctionExecutionDomain
ed_function_execution_domain :: (i: u32) -> *Ed { return *ed_ext(i).inter_procedural_ed; }

// isExecutedInAlignedRegion
ed_is_executed_in_aligned_region :: (i: u32, x: Value_Id) -> bool {
    if !aa_is_valid(i) return false;
    e := ed_ext(i);
    forward_ok := true;
    cur := x;
    while cur != NONE {
        defer cur = inst_next(cur);
        if !is_call_base(cur) continue;
        if cur != x && omp_contains(e.aligned_barriers, cur) return true;
        found, ced := ed_ced_lookup(i, cur, ED_PRE);
        if !found continue;
        if !ced.reaching_aligned_barrier_only forward_ok = false;
        break;
    }
    if cur == NONE && !ed_bed_lookup(i, inst_block(x)).reaching_aligned_barrier_only forward_ok = false;
    cur = x;
    while cur != NONE {
        defer cur = inst_prev(cur);
        if !is_call_base(cur) continue;
        if cur != x && omp_contains(e.aligned_barriers, cur) return true;
        found, ced := ed_ced_lookup(i, cur, ED_POST);
        if !found continue;
        if ced.reached_from_aligned_barrier_only break;
        return false;
    }
    if !forward_ok return false;
    if cur == NONE {
        bb := inst_block(x);
        if bb == fn_entry(block_fn(bb)) return ed_bed_lookup(i, NONE).reached_from_aligned_barrier_only;
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(bb, *preds);
        for preds if !ed_bed_lookup(i, it).reached_from_aligned_barrier_only return false;
    }
    return true;
}

ed_set_and_record :: (r: *bool, v: bool) -> bool { eq := r.* == v; r.* = v; return !eq; }

// mergeInPredecessorBarriersAndAssumptions
ed_merge_barriers_and_assumptions :: (ed: *Ed, pred: *Ed) {
    for pred.encountered_assumes ed_set_add(*ed.encountered_assumes, it);
    for pred.aligned_barriers ed_set_add(*ed.aligned_barriers, it);
}
// mergeInPredecessor
ed_merge_in_predecessor :: (ed: *Ed, pred: *Ed, initial_edge_only := false) -> bool {
    changed := false;
    changed |= ed_set_and_record(*ed.initial_thread_only, initial_edge_only || (pred.initial_thread_only && ed.initial_thread_only));
    changed |= ed_set_and_record(*ed.reached_from_aligned_barrier_only, ed.reached_from_aligned_barrier_only && pred.reached_from_aligned_barrier_only);
    changed |= ed_set_and_record(*ed.encountered_non_local_side_effect, ed.encountered_non_local_side_effect || pred.encountered_non_local_side_effect);
    if ed.reached_from_aligned_barrier_only ed_merge_barriers_and_assumptions(ed, pred);
    else ed_clear_assumes_and_barriers(ed);
    return changed;
}

// handleCallees
ed_handle_callees :: (i: u32, entry_ed: *Ed) -> bool {
    pre: [..] Ed; pre.allocator = temp;
    post: [..] Ed; post.allocator = temp;
    uai := false;
    ok := true;
    for cb: atr_call_sites(i, true, *uai, *ok) {
        eda := atr_get_aa(.EXECUTION_DOMAIN, irp_function(inst_fn(cb)), i, DEP_OPTIONAL);
        if eda == NONE || !aa_is_valid(eda) { ok = false; break; }
        _, a := ed_ced_lookup(eda, cb, ED_PRE);
        _, b := ed_ced_lookup(eda, cb, ED_POST);
        array_add(*pre, ed_copy(a));
        array_add(*post, ed_copy(b));
    }
    exit_ed: Ed;
    f := irp_anchor_scope(aa(i).pos);
    if ok {
        for k: 0..pre.count - 1 {
            ed_merge_in_predecessor(entry_ed, *pre[k]);
            exit_ed.reaching_aligned_barrier_only &= post[k].reaching_aligned_barrier_only;
        }
    } else if omp_is_kernel(f) {
        entry_ed.initial_thread_only = false;
        entry_ed.reached_from_aligned_barrier_only = true;
        entry_ed.encountered_non_local_side_effect = false;
        exit_ed.reaching_aligned_barrier_only = false;
    } else {
        entry_ed.initial_thread_only = false;
        entry_ed.reached_from_aligned_barrier_only = false;
        entry_ed.encountered_non_local_side_effect = true;
        exit_ed.reaching_aligned_barrier_only = false;
    }
    changed := false;
    fn_ed := ed_bed(i, NONE);
    changed |= ed_set_and_record(*fn_ed.reached_from_aligned_barrier_only, fn_ed.reached_from_aligned_barrier_only & entry_ed.reached_from_aligned_barrier_only);
    changed |= ed_set_and_record(*fn_ed.reaching_aligned_barrier_only, fn_ed.reaching_aligned_barrier_only & exit_ed.reaching_aligned_barrier_only);
    changed |= ed_set_and_record(*fn_ed.initial_thread_only, entry_ed.initial_thread_only);
    return changed;
}

// isInitialThreadOnlyEdge
ed_is_initial_thread_only_edge :: (edge: Value_Id, succ: Value_Id) -> bool {
    if edge == NONE || inst_op(edge) != .CONDBR return false;
    if get_successor(edge, 0) != succ return false;
    cmp := op(edge, 0);
    if !is_inst(cmp) || (inst_op(cmp) != .ICMP && inst_op(cmp) != .FCMP) return false;
    if !cmp_is_true_when_equal(cmp) || !cmp_is_equality(cmp) return false;
    c := op(cmp, 1);
    if vkind(c) != .C_INT return false;
    if ap_is_all_ones(const_ap(c)) {
        cb := op(cmp, 0);
        rfi := omp_rfi(.__kmpc_target_init);
        cb = ifx is_inst(cb) && is_call_base(cb) then omp_call_if_regular_call(cb, rfi) else NONE;
        if cb == NONE return false;
        env := omp_kernel_env_from_init_cb(cb);
        exec_mode := omp_kernel_env_config_field(env, KE_EXEC_MODE);
        return (const_int_sext(exec_mode) & OMP_TGT_EXEC_MODE_GENERIC) != 0;
    }
    if ap_is_zero(const_ap(c)) {
        // 0 == llvm.nvvm.read.ptx.sreg.tid.x() / llvm.amdgcn.workitem.id.x()
        x := op(cmp, 0);
        if is_inst(x) && inst_op(x) == .CALL {
            n := intrinsic_id_of_call(x);
            if n == "llvm.nvvm.read.ptx.sreg.tid.x" || n == "llvm.amdgcn.workitem.id.x" return true;
        }
    }
    return false;
}
// CmpInst::isTrueWhenEqual / isEquality (icmp eq/ne, fcmp oeq/one/ueq/une)
cmp_is_true_when_equal :: (c: Value_Id) -> bool {
    p := inst(c).pred;
    if inst_op(c) == .ICMP return p == ICMP_EQ || p == ICMP_UGE || p == ICMP_ULE || p == ICMP_SGE || p == ICMP_SLE;
    return p == FCMP_TRUE || p == FCMP_UEQ || p == FCMP_UGE || p == FCMP_ULE;
}
cmp_is_equality :: (c: Value_Id) -> bool {
    p := inst(c).pred;
    if inst_op(c) == .ICMP return p == ICMP_EQ || p == ICMP_NE;
    return p == FCMP_OEQ || p == FCMP_ONE || p == FCMP_UEQ || p == FCMP_UNE;
}

// hasFunctionEndAsUniqueSuccessor
has_function_end_as_unique_successor :: (bb: Value_Id) -> bool {
    b := bb;
    while true {
        if block_num_successors(b) == 0 return true;
        s := block_unique_successor(b);
        if s == NONE return false;
        b = s;
    }
    return false;
}

// AANoSync::isAlignedBarrier
is_aligned_barrier :: (cb: Value_Id, executed_aligned: bool) -> bool {
    n := intrinsic_id_of_call(cb);
    if begins_with(n, "llvm.nvvm.barrier.cta.") && (ends_with(n, "aligned.all") || ends_with(n, "aligned.count")) {
        if n == "llvm.nvvm.barrier.cta.sync.aligned.all" || n == "llvm.nvvm.barrier.cta.sync.aligned.count" ||
           n == "llvm.nvvm.barrier.cta.red.and.aligned.all" || n == "llvm.nvvm.barrier.cta.red.and.aligned.count" ||
           n == "llvm.nvvm.barrier.cta.red.or.aligned.all" || n == "llvm.nvvm.barrier.cta.red.or.aligned.count" ||
           n == "llvm.nvvm.barrier.cta.red.popc.aligned.all" || n == "llvm.nvvm.barrier.cta.red.popc.aligned.count" return true;
    }
    if n == "llvm.amdgcn.s.barrier" && executed_aligned return true;
    return call_has_assumption(cb, "ompx_aligned_barrier");
}
// hasAssumption(const CallBase &, KnownAssumptionString): the callee's "llvm.assume", then the call's
call_has_assumption :: (cb: Value_Id, s: string) -> bool {
    has_in :: (set: u32, s: string) -> bool {
        for attr_set_items(set) if it.kind == .STRING_ATTR && it.key == "llvm.assume" {
            for part: split(it.val, ",",, temp) if part == s return true;
            return false;
        }
        return false;
    }
    f := call_called_function(cb);
    if f != NONE && has_in(attr_list_fn(glob(f).attrs), s) return true;
    return has_in(call_fn_attrs(cb), s);
}

// AA::isPotentiallyAffectedByBarrier(A, I, QueryingAA)
atr_is_potentially_affected_by_barrier_inst :: (x: Value_Id, q: u32) -> bool {
    if !may_have_side_effects(x) && !may_read_from_memory(x) return false;
    ptrs: [..] Value_Id; ptrs.allocator = temp;
    if is_mem_intrinsic_call(x) {
        ed_set_add(*ptrs, call_arg(x, 0));   // MemoryLocation::getForDest
        n := intrinsic_id_of_call(x);
        if n == "llvm.memcpy" || n == "llvm.memmove" || n == "llvm.memcpy.inline" ed_set_add(*ptrs, call_arg(x, 1));   // getForSource
    } else {
        o := inst_op(x);
        if o == .LOAD ed_set_add(*ptrs, op(x, 0));
        else if o == .STORE ed_set_add(*ptrs, op(x, 1));
        else if o == .VAARG ed_set_add(*ptrs, op(x, 0));
        else if o == .CMPXCHG || o == .ATOMICRMW ed_set_add(*ptrs, op(x, 0));
        else return true;   // MemoryLocation::getOrNone: no location
    }
    return atr_is_potentially_affected_by_barrier(ptrs, q);
}
// AA::isPotentiallyAffectedByBarrier(A, Ptrs, QueryingAA, CtxI)
atr_is_potentially_affected_by_barrier :: (ptrs: [] Value_Id, q: u32) -> bool {
    for p: ptrs {
        if p == NONE return true;
        uo := atr_get_aa(.UNDERLYING_OBJECTS, irp_value(p), q, DEP_OPTIONAL);
        if uo == NONE return true;
        objs: [..] Value_Id; objs.allocator = temp;
        uo_objects(uo, false, *objs);
        all := true;
        for obj: objs if !atr_is_assumed_thread_local_object(obj, q) { all = false; break; }
        if !all return true;
    }
    return false;
}

// AAExecutionDomainFunction::updateImpl
ed_update :: (i: u32) -> bool {
    changed := false;
    e := ed_ext(i);
    handle_aligned_barrier :: (i: u32, cb: Value_Id, ed: *Ed, changed: *bool) {
        e := ed_ext(i);
        if !omp_contains(e.aligned_barriers, cb) { array_add(*e.aligned_barriers, cb); changed.* = true; }
        call_in := ed_ced(i, cb, ED_PRE);
        changed.* |= ed_merge_in_predecessor(call_in, ed);
        call_in.reaching_aligned_barrier_only = true;
        ed.encountered_non_local_side_effect = false;
        ed.reached_from_aligned_barrier_only = true;
        ed_clear_assumes_and_barriers(ed);
        ed_set_add(*ed.aligned_barriers, cb);
        call_out := ed_ced(i, cb, ED_POST);
        changed.* |= ed_merge_in_predecessor(call_out, ed);
    }
    lv := atr_get_aa(.IS_DEAD, aa(i).pos, i, DEP_OPTIONAL);
    f := irp_anchor_scope(aa(i).pos);
    entry_bb := fn_entry(f);
    is_kernel := omp_is_kernel(f);
    sync_worklist: [..] Value_Id; sync_worklist.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    for bb: e.rpot {
        is_entry := bb == entry_bb;
        aligned_barrier_last_in_block := is_entry && is_kernel;
        is_explicitly_aligned := is_entry && is_kernel;
        ed: Ed;
        ed.aligned_barriers.allocator = atr_allocator();
        ed.encountered_assumes.allocator = atr_allocator();
        if is_entry {
            changed |= ed_handle_callees(i, *ed);
        } else {
            if lv != NONE && dead_is_assumed_dead_bb(lv, bb) continue;
            preds.count = 0;
            block_predecessors(bb, *preds);
            for pb: preds {
                if lv != NONE && dead_is_edge_dead(lv, pb, bb) continue;
                initial_edge_only := ed_is_initial_thread_only_edge(block_terminator(pb), bb);
                ed_merge_in_predecessor(*ed, ed_bed(i, pb), initial_edge_only);
            }
        }
        for x: block_insts(bb) {
            uai := false;
            if atr_is_assumed_dead_inst(x, i, lv, *uai, false, DEP_OPTIONAL, true) continue;
            iid := ifx inst_op(x) == .CALL then call_iid(x) else NOT_INTRINSIC;
            if iid != NOT_INTRINSIC {
                if iid == IID_ASSUME { ed_set_add(*ed.encountered_assumes, x); continue; }
                if is_assume_like_intrinsic(x) continue;
            }
            if inst_op(x) == .FENCE {
                skip := false;
                if !ed.encountered_non_local_side_effect {
                    if ed.reached_from_aligned_barrier_only skip = true;
                    else {
                        ord := inst(x).ord1;
                        if ord == 0 || ord == ORD_UNORDERED || ord == ORD_MONOTONIC || ord == ORD_RELEASE skip = true;
                    }
                }
                if skip continue;
                table_set(*e.non_noop_fences, x, true);
            }
            cb := ifx is_call_base(x) then x else NONE;
            is_no_sync := atr_is_no_sync_inst(x, i);
            is_aligned := !is_no_sync && cb != NONE && is_aligned_barrier(cb, aligned_barrier_last_in_block);
            aligned_barrier_last_in_block &= is_no_sync;
            is_explicitly_aligned &= is_no_sync;
            if cb != NONE {
                if is_aligned {
                    handle_aligned_barrier(i, cb, *ed, *changed);
                    aligned_barrier_last_in_block = true;
                    is_explicitly_aligned = true;
                    continue;
                }
                if is_mem_intrinsic_call(x) {
                    if !ed.encountered_non_local_side_effect && atr_is_potentially_affected_by_barrier_inst(x, i)
                        ed.encountered_non_local_side_effect = true;
                    if !is_no_sync {
                        ed.reached_from_aligned_barrier_only = false;
                        array_add(*sync_worklist, x);
                    }
                    continue;
                }
                call_in := ed_ced(i, cb, ED_PRE);
                changed |= ed_merge_in_predecessor(call_in, *ed);
                callee := call_called_function(cb);
                handled := false;
                if !is_no_sync && callee != NONE && !is_declaration(callee) {
                    eda := atr_get_aa(.EXECUTION_DOMAIN, irp_function(callee), i, DEP_OPTIONAL);
                    if eda != NONE && aa_is_valid(eda) {
                        callee_ed := ed_function_execution_domain(eda);
                        ed.reached_from_aligned_barrier_only = callee_ed.reached_from_aligned_barrier_only;
                        aligned_barrier_last_in_block = ed.reached_from_aligned_barrier_only;
                        if is_no_sync || !callee_ed.reached_from_aligned_barrier_only
                            ed.encountered_non_local_side_effect |= callee_ed.encountered_non_local_side_effect;
                        else
                            ed.encountered_non_local_side_effect = callee_ed.encountered_non_local_side_effect;
                        if !callee_ed.reaching_aligned_barrier_only {
                            changed |= ed_set_and_record(*ed_ced(i, cb, ED_PRE).reaching_aligned_barrier_only, false);
                            array_add(*sync_worklist, x);
                        }
                        if callee_ed.reached_from_aligned_barrier_only ed_merge_barriers_and_assumptions(*ed, callee_ed);
                        call_out := ed_ced(i, cb, ED_POST);
                        changed |= ed_merge_in_predecessor(call_out, *ed);
                        handled = true;
                    }
                }
                if handled continue;
                if !is_no_sync {
                    ed.reached_from_aligned_barrier_only = false;
                    changed |= ed_set_and_record(*ed_ced(i, cb, ED_PRE).reaching_aligned_barrier_only, false);
                    array_add(*sync_worklist, x);
                }
                aligned_barrier_last_in_block &= ed.reached_from_aligned_barrier_only;
                ed.encountered_non_local_side_effect |= !call_does_not_access_memory(cb);
                call_out := ed_ced(i, cb, ED_POST);
                changed |= ed_merge_in_predecessor(call_out, *ed);
            }
            if !may_have_side_effects(x) && !may_read_from_memory(x) continue;
            if cb != NONE {
                ml := atr_get_aa(.MEM_LOCATION, irp_cs_function(cb), i, DEP_OPTIONAL);
                if ml != NONE && aa_is_valid(ml) {
                    accs: [..] Ml_Access_Loc; accs.allocator = temp;
                    if ml_accesses(ml, 0, *accs) {   // ALL_LOCATIONS
                        all := true;
                        for accs if atr_is_potentially_affected_by_barrier(.[it.a.ptr], i) { all = false; break; }
                        if all continue;
                    }
                }
            }
            if !may_have_side_effects(x) && atr_is_only_used_by_assume(x) continue;
            if inst_op(x) == .LOAD && get_metadata(x, MDK_INVARIANT_LOAD) != NONE continue;
            if !ed.encountered_non_local_side_effect && atr_is_potentially_affected_by_barrier_inst(x, i)
                ed.encountered_non_local_side_effect = true;
        }
        is_end_not_reaching := false;
        term := block_terminator(bb);
        if inst_op(term) != .UNREACHABLE && num_successors(term) == 0 {
            changed |= ed_merge_in_predecessor(*e.inter_procedural_ed, *ed);
            fn_ed := ed_bed(i, NONE);
            if is_kernel && !is_explicitly_aligned fn_ed.reaching_aligned_barrier_only = false;
            changed |= ed_merge_in_predecessor(fn_ed, *ed);
            if !fn_ed.reaching_aligned_barrier_only {
                is_end_not_reaching = true;
                array_add(*sync_worklist, term);
                changed |= ed_set_and_record(*ed_bed(i, bb).reaching_aligned_barrier_only, false);
            }
        }
        stored := ed_bed(i, bb);
        ed.reaching_aligned_barrier_only = stored.reaching_aligned_barrier_only & !is_end_not_reaching;
        if ed.initial_thread_only != stored.initial_thread_only ||
           ed.reached_from_aligned_barrier_only != stored.reached_from_aligned_barrier_only ||
           ed.encountered_non_local_side_effect != stored.encountered_non_local_side_effect changed = true;
        stored.* = ed;
    }
    // propagate (non-aligned) sync instruction effects backwards
    visited: [..] Value_Id; visited.allocator = temp;
    while sync_worklist.count {
        sync := pop(*sync_worklist);
        cur := sync;
        hit := false;
        while true {
            cur = inst_prev(cur);
            if cur == NONE break;
            if !is_call_base(cur) continue;
            changed |= ed_set_and_record(*ed_ced(i, cur, ED_POST).reaching_aligned_barrier_only, false);
            call_in := ed_ced(i, cur, ED_PRE);
            hit = omp_contains(e.aligned_barriers, cur) || !call_in.reaching_aligned_barrier_only;
            if hit break;
            changed |= ed_set_and_record(*call_in.reaching_aligned_barrier_only, false);
        }
        if hit continue;
        sync_bb := inst_block(sync);
        preds.count = 0;
        block_predecessors(sync_bb, *preds);
        for pb: preds {
            if lv != NONE && dead_is_edge_dead(lv, pb, sync_bb) continue;
            if omp_contains(visited, pb) continue;
            array_add(*visited, pb);
            if ed_set_and_record(*ed_bed(i, pb).reaching_aligned_barrier_only, false) {
                changed = true;
                array_add(*sync_worklist, block_terminator(pb));
            }
        }
        if sync_bb != entry_bb continue;
        changed |= ed_set_and_record(*e.inter_procedural_ed.reaching_aligned_barrier_only, false);
    }
    return ifx changed then ATR_CHANGED else ATR_UNCHANGED;
}

// AAExecutionDomainFunction::manifest
ed_manifest :: (i: u32) -> bool {
    changed := ATR_UNCHANGED;
    if omp_opts.disable_barrier_elimination return changed;
    e := ed_ext(i);
    deleted: [..] Value_Id; deleted.allocator = temp;
    f := irp_anchor_scope(aa(i).pos);
    handle :: (i: u32, cb: Value_Id, deleted: *[..] Value_Id, changed: *bool, f: Value_Id) {
        ed: *Ed;
        if cb != NONE ed = ed_ced(i, cb, ED_PRE); else ed = ed_bed(i, NONE);
        if !ed.reached_from_aligned_barrier_only || ed.encountered_non_local_side_effect return;
        if ed.encountered_assumes.count && !atr.is_module_pass return;
        if cb != NONE {
            array_add(deleted, cb);
            atr_delete_inst_after_manifest(cb);
            changed.* = ATR_CHANGED;
        } else if ed.aligned_barriers.count {
            changed.* = ATR_CHANGED;
            work: [..] Value_Id; work.allocator = temp;
            for ed.aligned_barriers array_add(*work, it);
            visited: [..] Value_Id; visited.allocator = temp;
            while work.count {
                last := pop(*work);
                if omp_contains(visited, last) continue;
                array_add(*visited, last);
                if inst_fn(last) != f continue;
                if !has_function_end_as_unique_successor(inst_block(last)) continue;
                if !omp_contains(deleted.*, last) { atr_delete_inst_after_manifest(last); continue; }
                last_ed := ed_ced(i, last, ED_PRE);
                for last_ed.aligned_barriers array_add(*work, it);
            }
        }
        if ed.encountered_assumes.count && (cb != NONE || ed.aligned_barriers.count)
            for ed.encountered_assumes atr_delete_inst_after_manifest(it);
    }
    for cb: e.aligned_barriers handle(i, cb, *deleted, *changed, f);
    if omp_is_kernel(f) handle(i, NONE, *deleted, *changed, f);
    return changed;
}

// ---------------------------------------------------------------- AAHeapToShared

H2sh_Ext :: struct {
    malloc_calls: [..] Value_Id;                 // SmallSetVector<CallBase *>
    potential_removed_free_calls: [..] Value_Id; // SmallPtrSet (membership only)
    shared_memory_used: u64;
}
h2sh_ext :: inline (i: u32) -> *H2sh_Ext { return cast(*H2sh_Ext) aa(i).x; }

// The __kmpc_free_shared calls among the users of `cb`
h2sh_free_calls :: (cb: Value_Id, out: *[..] Value_Id) {
    free_decl := omp_rfi(.__kmpc_free_shared).declaration;
    u := ir.v_first_use[cb];
    while u != NONE {
        c := ir.u_user[u];
        if is_inst(c) && is_call_base(c) && call_called_function(c) == free_decl array_add(out, c);
        u = ir.u_next[u];
    }
}
// findPotentialRemovedFreeCalls
h2sh_find_potential_removed_free_calls :: (i: u32) {
    e := h2sh_ext(i);
    e.potential_removed_free_calls.count = 0;
    for cb: e.malloc_calls {
        frees: [..] Value_Id; frees.allocator = temp;
        h2sh_free_calls(cb, *frees);
        if frees.count != 1 continue;
        ed_set_add(*e.potential_removed_free_calls, frees[0]);
    }
}
h2sh_initialize :: (i: u32) {
    if omp_opts.disable_deglobalization { aa_pessimistic(i); return; }
    rfi := omp_rfi(.__kmpc_alloc_shared);
    if rfi.declaration == NONE return;
    f := irp_anchor_scope(aa(i).pos);
    uses := omp_get_use_vector(rfi, f);
    if !uses return;
    e := h2sh_ext(i);
    for u: uses.* {
        cb := ir.u_user[u];
        if is_inst(cb) && is_call_base(cb) {
            ed_set_add(*e.malloc_calls, cb);
            atr_register_simplification_callback(irp_cs_returned(cb));
        }
    }
    h2sh_find_potential_removed_free_calls(i);
}
h2sh_is_assumed_heap_to_shared :: (i: u32, cb: Value_Id) -> bool { return aa_is_valid(i) && omp_contains(h2sh_ext(i).malloc_calls, cb); }
h2sh_is_assumed_removed_free :: (i: u32, cb: Value_Id) -> bool { return aa_is_valid(i) && omp_contains(h2sh_ext(i).potential_removed_free_calls, cb); }

h2sh_manifest :: (i: u32) -> bool {
    e := h2sh_ext(i);
    if e.malloc_calls.count == 0 return ATR_UNCHANGED;
    f := irp_anchor_scope(aa(i).pos);
    hs := atr_lookup(.HEAP_TO_STACK, irp_function(f), i, DEP_OPTIONAL);
    changed := ATR_UNCHANGED;
    for cb: e.malloc_calls {
        if hs != NONE && h2s_is_assumed_heap_to_stack(hs, cb) continue;
        frees: [..] Value_Id; frees.allocator = temp;
        h2sh_free_calls(cb, *frees);
        if frees.count != 1 continue;
        alloc_size := call_arg(cb, 0);
        if vkind(alloc_size) != .C_INT fatal("internal: openmp-opt: a non-constant __kmpc_alloc_shared size");
        sz := const_int_zext(alloc_size);
        if sz + e.shared_memory_used > omp_opts.shared_limit continue;
        arr_ty := type_array(sz, ir.t_i8);
        shared := gv_create(arr_ty, false, .INTERNAL, const_poison(arr_ty), tconcat(vname(cb), "_shared"), NONE, 0, OMP_AS_SHARED);
        new_buffer := ce_pointer_bitcast_or_addrspacecast(shared, ir.t_ptr);   // ConstantExpr::getPointerCast
        align := call_ret_align(cb);
        if align == 0 fatal("internal: openmp-opt: HeapToShared on an allocation without alignment");
        glob(shared).align = align;
        atr_change_after_manifest(irp_cs_returned(cb), new_buffer);
        atr_delete_inst_after_manifest(cb);
        atr_delete_inst_after_manifest(frees[0]);
        e.shared_memory_used += sz;
        changed = ATR_CHANGED;
    }
    return changed;
}
OMP_AS_SHARED :: cast(u32) 3;   // omp::AddressSpace::Shared

h2sh_update :: (i: u32) -> bool {
    e := h2sh_ext(i);
    if e.malloc_calls.count == 0 return aa_pessimistic(i);
    rfi := omp_rfi(.__kmpc_alloc_shared);
    if rfi.declaration == NONE return ATR_UNCHANGED;
    f := irp_anchor_scope(aa(i).pos);
    n := e.malloc_calls.count;
    // the users of the declaration (use-list order)
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[rfi.declaration];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    remove_from :: (l: *[..] Value_Id, v: Value_Id) { for l.* if it == v { array_ordered_remove_by_index(l, it_index); return; } }
    for cb: users {
        if !is_inst(cb) || !is_call_base(cb) continue;
        if inst_fn(cb) != f continue;
        if !omp_contains(e.malloc_calls, cb) continue;
        if vkind(call_arg(cb, 0)) != .C_INT { remove_from(*e.malloc_calls, cb); continue; }
        ed := atr_get_aa(.EXECUTION_DOMAIN, irp_function(f), i, DEP_REQUIRED);
        if ed == NONE || !ed_is_executed_by_initial_thread_only(ed, inst_block(cb)) remove_from(*e.malloc_calls, cb);
    }
    h2sh_find_potential_removed_free_calls(i);
    if n != e.malloc_calls.count return ATR_CHANGED;
    return ATR_UNCHANGED;
}

// ---------------------------------------------------------------- AAFoldRuntimeCall

Frc_Ext :: struct {
    simplified: Value_Id = OV_NOVAL;   // std::optional<Value *> SimplifiedValue
    rf_kind: Omp_Rtl;
}
frc_ext :: inline (i: u32) -> *Frc_Ext { return cast(*Frc_Ext) aa(i).x; }

frc_initialize :: (i: u32) {
    if omp_opts.disable_folding aa_pessimistic(i);
    callee := irp_assoc_fn(aa(i).pos);
    found, r := table_find(*omp_ic.rtf_id, callee);
    if !found fatal("internal: openmp-opt: expected a known OpenMP runtime function");
    frc_ext(i).rf_kind = r;
    atr_register_simplification_callback(irp_cs_returned(irp_assoc_value(aa(i).pos)), SCB_FOLD_RUNTIME_CALL, i);
}
frc_update :: (i: u32) -> bool {
    r := frc_ext(i).rf_kind;
    if r == {
        case .__kmpc_is_spmd_exec_mode; return frc_fold_is_spmd_exec_mode(i);
        case .__kmpc_parallel_level; return frc_fold_parallel_level(i);
        case .__kmpc_get_hardware_num_threads_in_block; return frc_fold_kernel_fn_attribute(i, "omp_target_thread_limit");
        case .__kmpc_get_hardware_num_blocks; return frc_fold_kernel_fn_attribute(i, "omp_target_num_teams");
    }
    fatal("internal: openmp-opt: unhandled OpenMP runtime function");
    return ATR_UNCHANGED;
}
frc_manifest :: (i: u32) -> bool {
    v := frc_ext(i).simplified;
    if v == OV_NOVAL || v == NONE return ATR_UNCHANGED;
    x := irp_ctx_i(aa(i).pos);
    atr_change_after_manifest(irp_inst(x), v);
    atr_delete_inst_after_manifest(x);
    return ATR_CHANGED;
}
// counts of the reaching kernels' SPMD modes: (assumed SPMD, known SPMD, assumed non-SPMD, known non-SPMD)
frc_count_modes :: (i: u32, kernels: [] Value_Id, require_valid_state: bool) -> (bool, s64, s64, s64, s64) {
    a_spmd, k_spmd, a_non, k_non: s64;
    for k: kernels {
        ka := atr_get_aa(.KERNEL_INFO, irp_function(k), i, DEP_REQUIRED);
        if ka == NONE return false, 0, 0, 0, 0;
        t := *kis_ext(ka).spmd;
        if require_valid_state { if !aa_is_valid(ka) return false, 0, 0, 0, 0; }
        else if !bsv_is_valid(t) return false, 0, 0, 0, 0;
        if bsv_is_assumed(t) { if bsv_is_fix(t) k_spmd += 1; else a_spmd += 1; }
        else { if bsv_is_fix(t) k_non += 1; else a_non += 1; }
    }
    return true, a_spmd, k_spmd, a_non, k_non;
}
// foldIsSPMDExecMode
frc_fold_is_spmd_exec_mode :: (i: u32) -> bool {
    e := frc_ext(i);
    before := e.simplified;
    caller := atr_get_aa(.KERNEL_INFO, irp_function(irp_anchor_scope(aa(i).pos)), i, DEP_REQUIRED);
    if caller == NONE || !bsv_is_valid(*kis_ext(caller).reaching_kernel_entries) return aa_pessimistic(i);
    ok, a_spmd, k_spmd, a_non, k_non := frc_count_modes(i, kis_ext(caller).reaching_kernel_entries.set, true);
    if !ok { e.simplified = NONE; return aa_pessimistic(i); }
    if (a_spmd + k_spmd) != 0 && (a_non + k_non) != 0 return aa_pessimistic(i);
    if k_spmd != 0 || a_spmd != 0 e.simplified = const_int(ir.t_i8, 1);
    else if k_non != 0 || a_non != 0 e.simplified = const_int(ir.t_i8, 0);
    return ifx e.simplified == before then ATR_UNCHANGED else ATR_CHANGED;
}
// foldParallelLevel
frc_fold_parallel_level :: (i: u32) -> bool {
    e := frc_ext(i);
    before := e.simplified;
    caller := atr_get_aa(.KERNEL_INFO, irp_function(irp_anchor_scope(aa(i).pos)), i, DEP_REQUIRED);
    if caller == NONE || !bsv_is_valid(*kis_ext(caller).parallel_levels) return aa_pessimistic(i);
    ke := *kis_ext(caller).reaching_kernel_entries;
    if !bsv_is_valid(ke) return aa_pessimistic(i);
    if ke.set.count == 0 return ATR_UNCHANGED;
    ok, a_spmd, k_spmd, a_non, k_non := frc_count_modes(i, ke.set, false);
    if !ok return aa_pessimistic(i);
    if (a_spmd + k_spmd) != 0 && (a_non + k_non) != 0 return aa_pessimistic(i);
    if a_spmd != 0 || k_spmd != 0 e.simplified = const_int(ir.t_i8, 1);
    else e.simplified = const_int(ir.t_i8, 0);
    return ifx e.simplified == before then ATR_UNCHANGED else ATR_CHANGED;
}
// foldKernelFnAttribute
frc_fold_kernel_fn_attribute :: (i: u32, attr: string) -> bool {
    e := frc_ext(i);
    current: s32 = -1;
    before := e.simplified;
    caller := atr_get_aa(.KERNEL_INFO, irp_function(irp_anchor_scope(aa(i).pos)), i, DEP_REQUIRED);
    if caller == NONE || !bsv_is_valid(*kis_ext(caller).reaching_kernel_entries) return aa_pessimistic(i);
    for k: kis_ext(caller).reaching_kernel_entries.set {
        next := cast,no_check(s32) fn_attr_as_parsed_integer(k, attr, 0xFFFF_FFFF_FFFF_FFFF);
        if next == -1 || (current != -1 && current != next) return aa_pessimistic(i);
        current = next;
    }
    if current != -1 e.simplified = const_int(type_int(32), cast,no_check(u64) cast(s64) current);
    return ifx e.simplified == before then ATR_UNCHANGED else ATR_CHANGED;
}

// ---------------------------------------------------------------- registration

// OpenMPOpt::registerFoldRuntimeCall
omp_register_fold_runtime_call :: (r: Omp_Rtl) {
    rfi := omp_rfi(r);
    for u: omp_rfi_uses(rfi, oo.scc) {
        ci := omp_call_if_regular_call_use(u, rfi);
        if ci == NONE continue;
        atr_get_aa(.FOLD_RUNTIME_CALL, irp_cs_returned(ci), NONE, DEP_NONE, false, false);
    }
}

// OpenMPOpt::registerAAs
omp_register_aas :: (is_module_pass: bool) {
    if oo.scc.count == 0 return;
    if is_module_pass {
        init_rfi := omp_rfi(.__kmpc_target_init);
        for u: omp_rfi_uses(init_rfi, oo.scc) {
            atr_get_aa(.KERNEL_INFO, irp_function(use_fn), NONE, DEP_NONE, false, false);
        }
        omp_register_fold_runtime_call(.__kmpc_is_spmd_exec_mode);
        omp_register_fold_runtime_call(.__kmpc_parallel_level);
        omp_register_fold_runtime_call(.__kmpc_get_hardware_num_threads_in_block);
        omp_register_fold_runtime_call(.__kmpc_get_hardware_num_blocks);
    }
    if omp_opts.deduce_icv_values {
        for k: 0..ICV_COUNT - 1 {
            getter := omp_rfi(cast(Omp_Rtl) OMP_ICVS[k].getter);
            for u: omp_rfi_uses(getter, oo.scc) {
                ci := omp_call_if_regular_call_use(u, getter);
                if ci == NONE continue;
                atr_get_aa(.ICV_TRACKER, irp_cs_function(ci), NONE, DEP_REQUIRED);
            }
        }
    }
    if !omp_is_device() return;
    for f: oo.scc {
        if is_declaration(f) continue;
        if gv_has_local_linkage(f) {
            all := true;
            u := ir.v_first_use[f];
            while u != NONE {
                usr := ir.u_user[u];
                if !(is_inst(usr) && is_call_base(usr) && u == op_use(usr, nops(usr) - 1) && atr_is_run_on(inst_fn(usr))) { all = false; break; }
                u = ir.u_next[u];
            }
            if all continue;
        }
        omp_register_aas_for_function(f);
    }
}

// OpenMPOpt::registerAAsForFunction (also the Attributor's InitializationCallback for live internal functions)
omp_register_aas_for_function :: (f: Value_Id) {
    fpos := irp_function(f);
    atr_get_aa(.EXECUTION_DOMAIN, fpos, NONE, DEP_REQUIRED);
    if fn_has_fn_attr(f, .Convergent) atr_get_aa(.NON_CONVERGENT, fpos, NONE, DEP_REQUIRED);
    uses_shared_alloc := false;
    if !omp_opts.disable_deglobalization {
        uv := omp_get_use_vector(omp_rfi(.__kmpc_alloc_shared), f);
        uses_shared_alloc = uv != null && uv.count != 0;
    }
    has_h2s_candidate := false;
    for x: fn_insts(f) {
        o := inst_op(x);
        if o == .LOAD {
            uai := false;
            atr_get_assumed_simplified(irp_value(x), NONE, *uai, AA_INTER);
            atr_get_aa(.ADDRESS_SPACE, irp_value(op(x, 0)), NONE, DEP_REQUIRED);
            continue;
        }
        if is_call_base(x) {
            if !omp_opts.disable_deglobalization && !has_h2s_candidate
                has_h2s_candidate = is_removable_alloc(x) || get_freed_operand(x) != NONE;
            if atr_call_is_indirect(x) atr_get_aa(.INDIRECT_CALL_INFO, irp_cs_function(x), NONE, DEP_REQUIRED);
        }
        if o == .STORE {
            atr_get_aa(.IS_DEAD, irp_value(x), NONE, DEP_REQUIRED);
            atr_get_aa(.ADDRESS_SPACE, irp_value(op(x, 1)), NONE, DEP_REQUIRED);
            continue;
        }
        if o == .FENCE {
            atr_get_aa(.IS_DEAD, irp_value(x), NONE, DEP_REQUIRED);
            continue;
        }
        if o == .CALL && call_iid(x) == IID_ASSUME {
            atr_get_aa(.POTENTIAL_VALUES, irp_value(call_arg(x, 0)), NONE, DEP_REQUIRED);
            continue;
        }
    }
    if uses_shared_alloc atr_get_aa(.HEAP_TO_SHARED, fpos, NONE, DEP_REQUIRED);
    if has_h2s_candidate atr_get_aa(.HEAP_TO_STACK, fpos, NONE, DEP_REQUIRED);
}
