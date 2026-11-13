// AAIsDead (AAIsDeadValueImpl, AAIsDeadFloating, AAIsDeadArgument, AAIsDeadCallSiteArgument,
// AAIsDeadCallSiteReturned, AAIsDeadReturned, AAIsDeadFunction with identifyAliveSuccessors) and
// AAUndefinedBehavior: a port of their parts of llvm/lib/Transforms/IPO/AttributorAttributes.cpp.

DEAD_HAS_NO_EFFECT :: cast(u64) 1;
DEAD_IS_REMOVABLE :: cast(u64) 2;
DEAD_IS_DEAD :: cast(u64) 3;

// AAIsDeadFunction's state
Dead_Fn_Ext :: struct {
    to_be_explored_from: [..] Value_Id;   // SmallSetVector
    known_dead_ends: [..] Value_Id;       // SmallSetVector
    known_dead_ends_set: Table(Value_Id, bool);
    to_be_explored_set: Table(Value_Id, bool);
    live_edges: Table(u64, bool);         // AssumedLiveEdges
    live_blocks: Table(Value_Id, bool);   // AssumedLiveBlocks
}
// AAIsDeadFloating / AAIsDeadCallSiteReturned
Dead_Val_Ext :: struct {
    potential_copies: [..] Value_Id;      // AAIsDeadFloating::PotentialCopies
    side_effect_free: bool;               // AAIsDeadCallSiteReturned::IsAssumedSideEffectFree
}
dead_fn_ext :: inline (i: u32) -> *Dead_Fn_Ext { return cast(*Dead_Fn_Ext) aa(i).x; }
dead_val_ext :: inline (i: u32) -> *Dead_Val_Ext { return cast(*Dead_Val_Ext) aa(i).x; }
dead_is_fn :: inline (i: u32) -> bool { pk := aa(i).pk; return pk == .FUNCTION || pk == .CALL_SITE; }

dead_edge_key :: inline (from: Value_Id, to: Value_Id) -> u64 { return ((cast(u64) from) << 32) | cast(u64) to; }

// ---------------------------------------------------------------- the AAIsDead interface

// isAssumedDead()
dead_is_assumed_dead :: (i: u32) -> bool {
    if dead_is_fn(i) return false;
    r := bs_is_assumed(aa(i).s, DEAD_IS_DEAD);
    if aa(i).pk == .CALL_SITE_RETURNED return r && dead_val_ext(i).side_effect_free;
    return r;
}
// isKnownDead()
dead_is_known_dead :: (i: u32) -> bool {
    if dead_is_fn(i) return false;
    return bs_is_known(aa(i).s, DEAD_IS_DEAD);
}
// isAssumedDead(const BasicBlock *)
dead_is_assumed_dead_bb :: (i: u32, bb: Value_Id) -> bool {
    if !dead_is_fn(i) return false;
    if aa(i).s.assumed == 0 return false;
    return !table_contains(*dead_fn_ext(i).live_blocks, bb);
}
dead_is_known_dead_bb :: (i: u32, bb: Value_Id) -> bool {
    if !dead_is_fn(i) return false;
    return aa(i).s.known != 0 && dead_is_assumed_dead_bb(i, bb);
}
// isAssumedDead(const Instruction *)
dead_is_assumed_dead_inst :: (i: u32, x: Value_Id) -> bool {
    if !dead_is_fn(i) return x == irp_ctx_i(aa(i).pos) && dead_is_assumed_dead(i);
    if aa(i).s.assumed == 0 return false;
    e := dead_fn_ext(i);
    if !table_contains(*e.live_blocks, inst_block(x)) return true;
    p := inst_prev(x);
    while p != NONE {
        if table_contains(*e.known_dead_ends_set, p) || table_contains(*e.to_be_explored_set, p) return true;
        p = inst_prev(p);
    }
    return false;
}
dead_is_known_dead_inst :: (i: u32, x: Value_Id) -> bool {
    if !dead_is_fn(i) return dead_is_assumed_dead_inst(i, x) && dead_is_known_dead(i);
    return aa(i).s.known != 0 && dead_is_assumed_dead_inst(i, x);
}
// isRemovableStore
dead_is_removable_store :: (i: u32) -> bool {
    if dead_is_fn(i) return false;
    pk := aa(i).pk;
    if pk != .FLOAT && pk != .ARGUMENT && pk != .CALL_SITE_RETURNED return false;
    v := irp_assoc_value(aa(i).pos);
    return bs_is_assumed(aa(i).s, DEAD_IS_REMOVABLE) && is_inst(v) && inst_op(v) == .STORE;
}
// isEdgeDead
dead_is_edge_dead :: (i: u32, from: Value_Id, to: Value_Id) -> bool {
    if !dead_is_fn(i) return false;
    return aa_is_valid(i) && !table_contains(*dead_fn_ext(i).live_edges, dead_edge_key(from, to));
}
// AAIsDead::mayCatchAsynchronousExceptions
dead_may_catch_asynchronous_exceptions :: (f: Value_Id) -> bool {
    return glob(f).has_personality && !can_simplify_invoke_no_unwind(f);
}

// ---------------------------------------------------------------- AAIsDeadValueImpl

// areAllUsesAssumedDead
dead_are_all_uses_assumed_dead :: (i: u32, v: Value_Id) -> bool {
    if type_kind(vtype(v)) == .VOID || !has_uses(v) return true;
    if !is_constant_kind(vkind(v)) {
        if is_inst(v) && !atr_is_run_on(inst_fn(v)) return false;
        uai := false;
        c := atr_get_assumed_constant_value(v, i, *uai);
        if c == OV_NOVAL || c != NONE return true;
    }
    ok, w := atr_uses_begin(i, v, false, DEP_REQUIRED, false);
    if !ok return false;
    u := atr_uses_next(*w);
    if w.failed return false;
    return u == NONE;
}
// isAssumedSideEffectFree
dead_is_assumed_side_effect_free :: (i: u32, x: Value_Id) -> bool {
    if x == NONE || would_instruction_be_trivially_dead(x, false) return true;
    if !is_terminator(inst_op(x)) && !may_have_side_effects(x) return true;
    if !is_call_base(x) || call_is_intrinsic(x) return false;
    cpos := irp_cs_function(x);
    nu, _ := atr_has_assumed_ir_attr(.NoUnwind, i, cpos, DEP_OPTIONAL);
    if !nu return false;
    ro, _ := atr_is_assumed_read_only(cpos, i);
    return ro;
}
// isa<IntrinsicInst>: a call whose callee is an intrinsic function
call_is_intrinsic :: (cb: Value_Id) -> bool {
    if inst_op(cb) != .CALL return false;
    c := call_callee(cb);
    return vkind(c) == .FUNCTION && fn_is_intrinsic_name(c);
}
fn_is_intrinsic_name :: (f: Value_Id) -> bool { return glob(f).intrinsic; }

dead_initialize :: (i: u32) {
    pk := aa(i).pk;
    if pk == .FUNCTION || pk == .CALL_SITE {
        aa(i).x = New(Dead_Fn_Ext);
        if pk == .CALL_SITE fatal("internal: attributor: AAIsDead for a call site");
        dead_fn_initialize(i);
        return;
    }
    aa(i).x = New(Dead_Val_Ext);
    v := irp_assoc_value(aa(i).pos);
    if pk == .CALL_SITE_ARGUMENT || pk == .RETURNED {
        if pk == .CALL_SITE_ARGUMENT && is_undef_value(v) aa_pessimistic(i);
        return;
    }
    // AAIsDeadFloating::initialize (also the argument and call site returned positions)
    if is_undef_value(v) { aa_pessimistic(i); return; }
    x := ifx is_inst(v) then v else NONE;
    if !dead_is_assumed_side_effect_free(i, x) {
        if !(x != NONE && (inst_op(x) == .STORE || inst_op(x) == .FENCE)) aa_pessimistic(i);
        else bs_remove_assumed(*aa(i).s, DEAD_HAS_NO_EFFECT);
    }
    if pk == .CALL_SITE_RETURNED {
        if is_undef_value(v) { aa_pessimistic(i); return; }
        dead_val_ext(i).side_effect_free = dead_is_assumed_side_effect_free(i, irp_ctx_i(aa(i).pos));
    }
}

// AAIsDeadFloating::isDeadStore
dead_is_dead_store :: (i: u32, si: Value_Id, assume_only: *[..] Value_Id) -> bool {
    if is_volatile(si) return false;
    uai := false;
    e := dead_val_ext(i);
    if !assume_only {
        e.potential_copies.count = 0;
        if !atr_get_potential_copies_of_stored_value(si, *e.potential_copies, i, *uai) return false;
    }
    for v: e.potential_copies {
        if atr_is_assumed_dead_irp(irp_value(v), i, NONE, *uai) continue;
        if is_inst(v) && inst_op(v) == .LOAD {
            all := true;
            u := ir.v_first_use[v];
            while u != NONE {
                user := ir.u_user[u];
                if atr_is_only_used_by_assume(user) {
                    if assume_only copies_insert(assume_only, user);
                } else if !atr_is_assumed_dead_use(u, i, NONE, *uai) { all = false; break; }
                u = ir.u_next[u];
            }
            if all continue;
        }
        return false;
    }
    return true;
}
// AAIsDeadFloating::isDeadFence: no AAExecutionDomain outside OpenMPOpt
dead_is_dead_fence :: (i: u32, fi: Value_Id) -> bool { return false; }

dead_update :: (i: u32) -> bool {
    pk := aa(i).pk;
    if pk == .FUNCTION return dead_fn_update(i);
    if pk == .CALL_SITE return aa_pessimistic(i);
    p := aa(i).pos;
    if pk == .CALL_SITE_ARGUMENT {
        arg := irp_assoc_arg(p);
        if arg == NONE return aa_pessimistic(i);
        o := atr_get_aa(.IS_DEAD, irp_argument(arg), i, DEP_REQUIRED);
        if o == NONE return aa_pessimistic(i);
        return bs_clamp_and_indicate(*aa(i).s, aa(o).s);
    }
    if pk == .RETURNED {
        uai := false;
        ok := true;
        for x: atr_insts(i, .[.RET], *uai, *ok) {}
        ok = true;
        for cb: atr_call_sites(i, true, *uai, *ok) {
            if acs_is_callback(acs) || !dead_are_all_uses_assumed_dead(i, cb) { ok = false; break; }
        }
        if !ok return aa_pessimistic(i);
        return ATR_UNCHANGED;
    }
    if pk == .CALL_SITE_RETURNED {
        changed := ATR_UNCHANGED;
        e := dead_val_ext(i);
        if e.side_effect_free && !dead_is_assumed_side_effect_free(i, irp_ctx_i(p)) {
            e.side_effect_free = false;
            changed = ATR_CHANGED;
        }
        if !dead_are_all_uses_assumed_dead(i, irp_assoc_value(p)) return aa_pessimistic(i);
        return changed;
    }
    // AAIsDeadFloating::updateImpl (also arguments)
    v := irp_assoc_value(p);
    x := ifx is_inst(v) then v else NONE;
    if x != NONE && inst_op(x) == .STORE {
        if !dead_is_dead_store(i, x, null) return aa_pessimistic(i);
    } else if x != NONE && inst_op(x) == .FENCE {
        if !dead_is_dead_fence(i, x) return aa_pessimistic(i);
    } else {
        if !dead_is_assumed_side_effect_free(i, x) return aa_pessimistic(i);
        if !dead_are_all_uses_assumed_dead(i, v) return aa_pessimistic(i);
    }
    return ATR_UNCHANGED;
}

dead_manifest :: (i: u32) -> bool {
    pk := aa(i).pk;
    p := aa(i).pos;
    if pk == .FUNCTION return dead_fn_manifest(i);
    if pk == .CALL_SITE_ARGUMENT {
        cb := irp_anchor(p);
        u := op_use(cb, cast(u32) irp_cs_arg_no(p));
        uv := const_undef(vtype(ir.u_val[u]));
        if atr_change_use_after_manifest(u, uv) return ATR_CHANGED;
        return ATR_UNCHANGED;
    }
    if pk == .RETURNED {
        any := false;
        uv := const_undef(fn_ret_type(irp_assoc_fn(p)));
        uai := false;
        ok := true;
        for ri: atr_insts(i, .[.RET], *uai, *ok) {
            if !is_undef_value(op(ri, 0)) any |= atr_change_use_after_manifest(op_use(ri, 0), uv);
        }
        return any;
    }
    if pk == .ARGUMENT {
        // AAIsDeadArgument::manifest
        arg := irp_assoc_arg(p);
        if atr_is_valid_function_signature_rewrite(arg, .[]) {
            if atr_register_function_signature_rewrite(arg, .[], ARI_NONE) return ATR_CHANGED;
        }
        return ATR_UNCHANGED;
    }
    // AAIsDeadFloating::manifest (also the call site returned position)
    v := irp_assoc_value(p);
    if is_inst(v) {
        if inst_op(v) == .STORE {
            assume_only: [..] Value_Id; assume_only.allocator = temp;
            if !dead_is_dead_store(i, v, *assume_only) fatal("internal: attributor: store was assumed to be dead");
            atr_delete_inst_after_manifest(v);
            k := 0;
            while k < assume_only.count {
                aoi := assume_only[k];
                k += 1;
                u := ir.v_first_use[aoi];
                while u != NONE { copies_insert(*assume_only, ir.u_user[u]); u = ir.u_next[u]; }
                atr_delete_inst_after_manifest(aoi);
            }
            return ATR_CHANGED;
        }
        if inst_op(v) == .FENCE {
            atr_delete_inst_after_manifest(v);
            return ATR_CHANGED;
        }
        if dead_is_assumed_side_effect_free(i, v) && !is_terminator(inst_op(v)) {
            atr_delete_inst_after_manifest(v);
            return ATR_CHANGED;
        }
    }
    return ATR_UNCHANGED;
}

// ---------------------------------------------------------------- AAIsDeadFunction

dead_fn_initialize :: (i: u32) {
    f := irp_anchor_scope(aa(i).pos);
    if !dead_fn_is_assumed_dead_internal_function(i) {
        dead_fn_insert_explore(i, block_first(fn_entry(f)));
        dead_fn_assume_live(i, fn_entry(f));
    }
}
dead_fn_insert_explore :: (i: u32, x: Value_Id) -> bool {
    e := dead_fn_ext(i);
    if table_contains(*e.to_be_explored_set, x) return false;
    table_set(*e.to_be_explored_set, x, true);
    array_add(*e.to_be_explored_from, x);
    return true;
}
dead_fn_insert_dead_end :: (i: u32, x: Value_Id) -> bool {
    e := dead_fn_ext(i);
    if table_contains(*e.known_dead_ends_set, x) return false;
    table_set(*e.known_dead_ends_set, x, true);
    array_add(*e.known_dead_ends, x);
    return true;
}
// isAssumedDeadInternalFunction
dead_fn_is_assumed_dead_internal_function :: (i: u32) -> bool {
    if !gv_has_local_linkage(irp_anchor_scope(aa(i).pos)) return false;
    uai := false;
    ok := true;
    for cb: atr_call_sites(i, true, *uai, *ok) { ok = false; break; }
    return ok;
}
// assumeLive
dead_fn_assume_live :: (i: u32, bb: Value_Id) -> bool {
    e := dead_fn_ext(i);
    if table_contains(*e.live_blocks, bb) return false;
    table_set(*e.live_blocks, bb, true);
    for x: block_insts(bb) {
        if !is_call_base(x) continue;
        f := call_callee(x);
        if vkind(f) == .FUNCTION && gv_has_local_linkage(f) atr_mark_live_internal_function(f);
    }
    return true;
}
// Attributor::markLiveInternalFunction (DefaultInitializeLiveInternals)
atr_mark_live_internal_function :: (f: Value_Id) {
    atr_identify_default_abstract_attributes(f);
}

// identifyAliveSuccessors for calls: true if assumed information was used
dead_alive_successors_call :: (i: u32, cb: Value_Id, out: *[..] Value_Id) -> bool {
    nr, known := atr_has_assumed_ir_attr(.NoReturn, i, irp_cs_function(cb), DEP_OPTIONAL);
    if nr return !known;
    if is_terminator(inst_op(cb)) array_add(out, block_first(get_successor(cb, 0)));
    else array_add(out, inst_next(cb));
    return false;
}
dead_alive_successors_invoke :: (i: u32, ii: Value_Id, out: *[..] Value_Id) -> bool {
    uai := dead_alive_successors_call(i, ii, out);
    if dead_may_catch_asynchronous_exceptions(inst_fn(ii)) {
        array_add(out, block_first(invoke_unwind_dest(ii)));
    } else {
        nu, known := atr_has_assumed_ir_attr(.NoUnwind, i, irp_cs_function(ii), DEP_OPTIONAL);
        if nu uai |= !known;
        else array_add(out, block_first(invoke_unwind_dest(ii)));
    }
    return uai;
}
dead_alive_successors_condbr :: (i: u32, br: Value_Id, out: *[..] Value_Id) -> bool {
    uai := false;
    c := atr_get_assumed_constant_value(op(br, 0), i, *uai);
    if c == OV_NOVAL || (c != NONE && is_undef_value(c)) {
        // no value yet: assume no successor is alive
    } else if c != NONE && vkind(c) == .C_INT {
        succ := get_successor(br, cast(u32) (1 - const_int_zext(c)));
        array_add(out, block_first(succ));
    } else {
        array_add(out, block_first(get_successor(br, 0)));
        array_add(out, block_first(get_successor(br, 1)));
        uai = false;
    }
    return uai;
}
dead_alive_successors_switch :: (i: u32, sw: Value_Id, out: *[..] Value_Id) -> bool {
    uai := false;
    vals: [..] Vac; vals.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    if !atr_get_assumed_simplified_values(irp_value(op(sw, 0)), i, *vals, AA_ANY, *uai) {
        block_successors(inst_block(sw), *succs);
        for succs array_add(out, block_first(it));
        return false;
    }
    if vals.count == 0 || (vals.count == 1 && is_undef_value(vals[0].v)) return uai;
    ty := vtype(op(sw, 0));
    constants: [..] Value_Id; constants.allocator = temp;
    for vals {
        c := atr_get_with_type(it.v, ty);
        if c == NONE || vkind(c) != .C_INT {
            block_successors(inst_block(sw), *succs);
            for succs array_add(out, block_first(it));
            return uai;
        }
        copies_insert(*constants, c);
    }
    matched := 0;
    for k: 0..cast(s64) switch_num_cases(sw) - 1 {
        cv := switch_case_value_at(sw, cast(u32) k);
        if copies_contains(*constants, cv) {
            matched += 1;
            array_add(out, block_first(get_successor(sw, cast(u32) (k + 1))));
        }
    }
    if matched < constants.count array_add(out, block_first(get_successor(sw, 0)));
    return uai;
}

// AAIsDeadFunction::updateImpl
dead_fn_update :: (i: u32) -> bool {
    change := ATR_UNCHANGED;
    e := dead_fn_ext(i);
    f := irp_anchor_scope(aa(i).pos);
    if e.live_blocks.count == 0 {
        if dead_fn_is_assumed_dead_internal_function(i) return ATR_UNCHANGED;
        dead_fn_insert_explore(i, block_first(fn_entry(f)));
        dead_fn_assume_live(i, fn_entry(f));
        change = ATR_CHANGED;
    }
    work: [..] Value_Id; work.allocator = temp;
    for e.to_be_explored_from array_add(*work, it);
    new_tbe: [..] Value_Id; new_tbe.allocator = temp;
    new_tbe_set: Table(Value_Id, bool); new_tbe_set.allocator = temp;
    alive: [..] Value_Id; alive.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    while work.count {
        x := pop(*work);
        while !is_terminator(inst_op(x)) && !is_call_base(x) x = inst_next(x);
        alive.count = 0;
        uai := false;
        o := inst_op(x);
        if o == {
            case .CALL; uai = dead_alive_successors_call(i, x, *alive);
            case .INVOKE; uai = dead_alive_successors_invoke(i, x, *alive);
            case .BR; array_add(*alive, block_first(get_successor(x, 0)));
            case .CONDBR; uai = dead_alive_successors_condbr(i, x, *alive);
            case .SWITCH; uai = dead_alive_successors_switch(i, x, *alive);
            case;
                block_successors(inst_block(x), *succs);
                for succs array_add(*alive, block_first(it));
        }
        if uai {
            if !table_contains(*new_tbe_set, x) { table_set(*new_tbe_set, x, true); array_add(*new_tbe, x); }
        } else if alive.count == 0 || (is_terminator(o) && cast(u32) alive.count < num_successors(x)) {
            if dead_fn_insert_dead_end(i, x) change = ATR_CHANGED;
        }
        for as: alive {
            if !is_terminator(o) {
                array_add(*work, as);
            } else {
                key := dead_edge_key(inst_block(x), inst_block(as));
                if !table_contains(*e.live_edges, key) { table_set(*e.live_edges, key, true); change = ATR_CHANGED; }
                if dead_fn_assume_live(i, inst_block(as)) array_add(*work, as);
            }
        }
    }
    differ := new_tbe.count != e.to_be_explored_from.count;
    if !differ for new_tbe if !table_contains(*e.to_be_explored_set, it) { differ = true; break; }
    if differ {
        change = ATR_CHANGED;
        e.to_be_explored_from.count = 0;
        table_reset(*e.to_be_explored_set);
        for new_tbe { array_add(*e.to_be_explored_from, it); table_set(*e.to_be_explored_set, it, true); }
    }
    if e.to_be_explored_from.count == 0 && cast(s64) fn_num_blocks(f) == e.live_blocks.count {
        all := true;
        for d: e.known_dead_ends if !(is_terminator(inst_op(d)) && num_successors(d) == 0) { all = false; break; }
        if all return aa_pessimistic(i);
    }
    return change;
}

// AAIsDeadFunction::manifest
dead_fn_manifest :: (i: u32) -> bool {
    changed := ATR_UNCHANGED;
    f := irp_anchor_scope(aa(i).pos);
    e := dead_fn_ext(i);
    if e.live_blocks.count == 0 {
        atr_delete_fn_after_manifest(f);
        return ATR_CHANGED;
    }
    invoke2call := !dead_may_catch_asynchronous_exceptions(f);
    // KnownDeadEnds.set_union(ToBeExploredFrom)
    for e.to_be_explored_from dead_fn_insert_dead_end(i, it);
    for d: e.known_dead_ends {
        if !is_call_base(d) continue;
        nr, _ := atr_has_assumed_ir_attr(.NoReturn, i, irp_cs_function(d), DEP_OPTIONAL);
        may_return := !nr;
        if may_return && (!invoke2call || inst_op(d) != .INVOKE) continue;
        if inst_op(d) == .INVOKE atr_register_invoke_with_dead_successor(d);
        else atr_change_to_unreachable_after_manifest(inst_next(d));
        changed = ATR_CHANGED;
    }
    for bb: fn_blocks(f) {
        if !table_contains(*e.live_blocks, bb) {
            atr_delete_block_after_manifest(bb);
            changed = ATR_CHANGED;
        }
    }
    return changed;
}

// ---------------------------------------------------------------- AAUndefinedBehavior

Ub_Ext :: struct {
    known_ub: [..] Value_Id;            // MapVector<Instruction *, UBInfo> (the keys)
    known_ub_set: Table(Value_Id, bool);
    assumed_no_ub: Table(Value_Id, bool);
}
ub_ext :: inline (i: u32) -> *Ub_Ext { return cast(*Ub_Ext) aa(i).x; }
ub_add_known :: (i: u32, x: Value_Id) {
    e := ub_ext(i);
    if table_contains(*e.known_ub_set, x) return;
    table_set(*e.known_ub_set, x, true);
    array_add(*e.known_ub, x);
}
ub_seen :: (i: u32, x: Value_Id) -> bool {
    e := ub_ext(i);
    return table_contains(*e.assumed_no_ub, x) || table_contains(*e.known_ub_set, x);
}
// stopOnUndefOrAssumed: OV_NOVAL for "known UB / not yet", NONE for unknown, else the value
ub_stop_on_undef_or_assumed :: (i: u32, v_in: Value_Id, x: Value_Id) -> Value_Id {
    v := v_in;
    uai := false;
    sv := atr_get_assumed_simplified_value(v, i, *uai, AA_INTER);
    if !uai {
        if sv == OV_NOVAL { ub_add_known(i, x); return OV_NOVAL; }
        if sv == NONE return NONE;
        v = sv;
    }
    if is_undef_value(v) { ub_add_known(i, x); return OV_NOVAL; }
    return v;
}
ub_pointer_operand :: (x: Value_Id) -> Value_Id {
    o := inst_op(x);
    if o == .STORE return op(x, 1);
    return op(x, 0);
}
ub_update :: (i: u32) -> bool {
    e := ub_ext(i);
    ub_prev := e.known_ub.count;
    noub_prev := e.assumed_no_ub.count;
    uai := false;
    ok := true;
    for x: atr_insts(i, .[.LOAD, .STORE, .CMPXCHG, .ATOMICRMW], *uai, *ok, true) {
        if is_volatile(x) continue;
        if ub_seen(i, x) continue;
        ptr := ub_pointer_operand(x);
        sp := ub_stop_on_undef_or_assumed(i, ptr, x);
        if sp == OV_NOVAL || sp == NONE continue;
        if vkind(sp) != .C_NULL { table_set(*e.assumed_no_ub, x, true); continue; }
        if null_pointer_is_defined(inst_fn(x), ptr_addrspace(vtype(sp))) table_set(*e.assumed_no_ub, x, true);
        else ub_add_known(i, x);
    }
    ok = true;
    for x: atr_insts(i, .[.CONDBR], *uai, *ok, true) {
        if ub_seen(i, x) continue;
        sc := ub_stop_on_undef_or_assumed(i, op(x, 0), x);
        if sc == OV_NOVAL || sc == NONE continue;
        table_set(*e.assumed_no_ub, x, true);
    }
    ok = true;
    for cb: atr_call_like_insts(i, *uai, *ok) {
        if ub_seen(i, cb) continue;
        callee := call_callee(cb);
        if vkind(callee) != .FUNCTION continue;
        stop := false;
        for idx: 0..cast(s64) call_num_args(cb) - 1 {
            if idx >= cast(s64) fn_nargs(callee) break;
            av := call_arg(cb, cast(u32) idx);
            cpos := irp_cs_argument(cb, cast(u32) idx);
            _, known_nu := atr_has_assumed_ir_attr(.NoUndef, i, cpos, DEP_NONE);
            if !known_nu continue;
            uai2 := false;
            sv := atr_get_assumed_simplified_value(av, i, *uai2, AA_INTER);
            if uai2 continue;
            if sv == NONE { stop = true; break; }
            if sv == OV_NOVAL || is_undef_value(sv) { ub_add_known(i, cb); continue; }
            if !is_ptr_type(vtype(av)) || vkind(sv) != .C_NULL continue;
            _, known_nn := atr_has_assumed_ir_attr(.NonNull, i, cpos, DEP_NONE);
            if known_nn ub_add_known(i, cb);
        }
    }
    f := irp_anchor_scope(aa(i).pos);
    if type_kind(fn_ret_type(f)) != .VOID {
        rpos := irp_returned(f);
        if !atr_is_assumed_dead_irp(rpos, i, NONE, *uai) {
            _, known_nu := atr_has_assumed_ir_attr(.NoUndef, i, rpos, DEP_NONE);
            if known_nu {
                ok = true;
                for ri: atr_insts(i, .[.RET], *uai, *ok, true) {
                    sv := ub_stop_on_undef_or_assumed(i, op(ri, 0), ri);
                    if sv == OV_NOVAL || sv == NONE continue;
                    if vkind(sv) == .C_NULL {
                        _, known_nn := atr_has_assumed_ir_attr(.NonNull, i, rpos, DEP_NONE);
                        if known_nn ub_add_known(i, ri);
                    }
                }
            }
        }
    }
    if noub_prev != e.assumed_no_ub.count || ub_prev != e.known_ub.count return ATR_CHANGED;
    return ATR_UNCHANGED;
}
// isKnownToCauseUB / isAssumedToCauseUB
ub_is_known_to_cause_ub :: (i: u32, x: Value_Id) -> bool { return table_contains(*ub_ext(i).known_ub_set, x); }
ub_is_assumed_to_cause_ub :: (i: u32, x: Value_Id) -> bool {
    o := inst_op(x);
    if o == .LOAD || o == .STORE || o == .CMPXCHG || o == .ATOMICRMW || o == .CONDBR return !table_contains(*ub_ext(i).assumed_no_ub, x);
    return false;
}
ub_manifest :: (i: u32) -> bool {
    e := ub_ext(i);
    if e.known_ub.count == 0 return ATR_UNCHANGED;
    for e.known_ub {
        atr_emit_ub_remark(it);
        atr_change_to_unreachable_after_manifest(it);
    }
    return ATR_CHANGED;
}
