// The query side of llvm/lib/Transforms/IPO/Attributor.cpp: the isAssumedDead overloads, checkForAllUses /
// CallSites / Callees / ReturnedValues / Instructions / ReadWriteInstructions, getAssumedSimplified(Values),
// getAssumedConstant, translateArgumentToCallSiteContent, and the AA:: helpers (isNoSyncInst, isDynamicallyUnique,
// getInitialValueForObj, isValidInScope, isValidAtPosition, getWithType, combineOptionalValuesInAAValueLatice,
// getPotentialCopiesOfMemoryValue, isAssumedReadOnly / ReadNone, isPotentiallyReachable,
// isAssumedThreadLocalObject), and llvm/lib/IR/AbstractCallSite.cpp (Acs). The framework is attributor.jai.

AA_INTRA :: cast(u8) 1;
AA_INTER :: cast(u8) 2;
AA_ANY :: cast(u8) 3;

// AA::ValueAndContext
Vac :: struct { v: Value_Id; ctx: Value_Id = NONE; }

// ---------------------------------------------------------------- liveness

// Attributor::isAssumedDead(const AbstractAttribute &AA, ...)
atr_is_assumed_dead_aa :: (i: u32, lv: u32, uai: *bool, bb_only := false, dep := DEP_OPTIONAL) -> bool {
    if !atr.use_liveness return false;
    p := aa(i).pos;
    if !atr_fn_in_set(irp_anchor_scope(p)) return false;
    return atr_is_assumed_dead_irp(p, i, lv, uai, bb_only, dep);
}

// Attributor::isAssumedDead(const Use &U, ...)
atr_is_assumed_dead_use :: (u: Use_Id, q: u32, lv: u32, uai: *bool, bb_only := false, dep := DEP_OPTIONAL) -> bool {
    if !atr.use_liveness return false;
    user := ir.u_user[u];
    if !is_inst(user) return atr_is_assumed_dead_irp(irp_value(ir.u_val[u]), q, lv, uai, bb_only, dep);
    o := inst_op(user);
    if is_call_base(user) {
        if call_is_arg_operand(user, u) return atr_is_assumed_dead_irp(irp_cs_argument(user, use_arg_no(u)), q, lv, uai, bb_only, dep);
    } else if o == .RET {
        return atr_is_assumed_dead_irp(irp_returned(inst_fn(user)), q, lv, uai, bb_only, dep);
    } else if o == .PHI {
        inc := phi_block(user, use_arg_no(u));
        return atr_is_assumed_dead_inst(block_terminator(inc), q, lv, uai, bb_only, dep);
    } else if o == .STORE {
        if !bb_only && op(user, 1) != ir.u_val[u] {
            d := atr_get_aa(.IS_DEAD, irp_inst(user), q, DEP_NONE);
            if d != NONE && dead_is_removable_store(d) {
                if q != NONE atr_record_dependence(d, q, dep);
                if !bs_is_known(aa(d).s, DEAD_IS_REMOVABLE) uai.* = true;
                return true;
            }
        }
    }
    return atr_is_assumed_dead_irp(irp_inst(user), q, lv, uai, bb_only, dep);
}

// Attributor::isAssumedDead(const Instruction &I, ...)
atr_is_assumed_dead_inst :: (x: Value_Id, q: u32, lv_in: u32, uai: *bool, bb_only := false, dep := DEP_OPTIONAL, check_dead_store := false) -> bool {
    if !atr.use_liveness return false;
    if table_contains(*atr.manifest_added_blocks, inst_block(x)) return false;
    f := inst_fn(x);
    lv := lv_in;
    if lv == NONE || irp_anchor_scope(aa(lv).pos) != f lv = atr_get_aa(.IS_DEAD, irp_function(f), q, DEP_NONE);
    if lv == NONE || q == lv return false;
    dead := ifx bb_only then dead_is_assumed_dead_bb(lv, inst_block(x)) else dead_is_assumed_dead_inst(lv, x);
    if dead {
        if q != NONE atr_record_dependence(lv, q, dep);
        if !dead_is_known_dead_inst(lv, x) uai.* = true;
        return true;
    }
    if bb_only return false;
    d := atr_get_aa(.IS_DEAD, irp_inst(x), q, DEP_NONE);
    if d == NONE || q == d return false;
    if dead_is_assumed_dead(d) {
        if q != NONE atr_record_dependence(d, q, dep);
        if !dead_is_known_dead(d) uai.* = true;
        return true;
    }
    if check_dead_store && inst_op(x) == .STORE && dead_is_removable_store(d) {
        if q != NONE atr_record_dependence(d, q, dep);
        if !dead_is_known_dead(d) uai.* = true;
        return true;
    }
    return false;
}

// Attributor::isAssumedDead(const IRPosition &IRP, ...)
atr_is_assumed_dead_irp :: (p: Irp, q: u32, lv: u32, uai: *bool, bb_only := false, dep := DEP_OPTIONAL) -> bool {
    if !atr.use_liveness return false;
    pk := irp_kind(p);
    if pk == .FLOAT && is_constant_kind(vkind(irp_assoc_value(p))) return false;
    ctx := irp_ctx_i(p);
    if ctx != NONE && atr_is_assumed_dead_inst(ctx, q, lv, uai, true, ifx bb_only then dep else DEP_OPTIONAL) return true;
    if bb_only return false;
    d: u32;
    if pk == .CALL_SITE d = atr_get_aa(.IS_DEAD, irp_cs_returned(irp_assoc_value(p)), q, DEP_NONE);
    else d = atr_get_aa(.IS_DEAD, p, q, DEP_NONE);
    if d == NONE || q == d return false;
    if dead_is_assumed_dead(d) {
        if q != NONE atr_record_dependence(d, q, dep);
        if !dead_is_known_dead(d) uai.* = true;
        return true;
    }
    return false;
}

// Attributor::isAssumedDead(const BasicBlock &BB, ...)
atr_is_assumed_dead_bb :: (bb: Value_Id, q: u32, lv_in: u32, dep := DEP_OPTIONAL) -> bool {
    if !atr.use_liveness return false;
    f := block_fn(bb);
    lv := lv_in;
    if lv == NONE || irp_anchor_scope(aa(lv).pos) != f lv = atr_get_aa(.IS_DEAD, irp_function(f), q, DEP_NONE);
    if lv == NONE || q == lv return false;
    if dead_is_assumed_dead_bb(lv, bb) {
        if q != NONE atr_record_dependence(lv, q, dep);
        return true;
    }
    return false;
}

// ---------------------------------------------------------------- checkForAllInstructions / ReadWriteInstructions

// An iteration over instructions that skips the assumed dead ones right before the predicate (the body) runs.
Atr_Insts :: struct { list: [..] Value_Id; q: u32 = NONE; lv: u32 = NONE; uai: *bool; bb_only: bool; pot_dead: bool; }
for_expansion :: (r: Atr_Insts, body: Code, flags: For_Flags) #expand {
    `it_index := 0;
    _k := 0;
    while _k < r.list.count {
        `it := r.list[_k];
        _k += 1;
        if !r.pot_dead && atr_is_assumed_dead_irp(irp_inst(it), r.q, r.lv, r.uai, r.bb_only) continue;
        #insert body;
    }
}

// Attributor::checkForAllInstructions(Pred, Fn, QueryingAA, Opcodes, ...): `ok` is cleared if there is no definition
atr_fn_insts :: (f: Value_Id, q: u32, opcodes: [] Opcode, uai: *bool, ok: *bool, bb_only := false, pot_dead := false) -> Atr_Insts {
    r: Atr_Insts;
    r.q = q; r.uai = uai; r.bb_only = bb_only; r.pot_dead = pot_dead;
    if f == NONE || is_declaration(f) { ok.* = false; return r; }
    if pot_dead && q != NONE r.lv = atr_get_aa(.IS_DEAD, irp_function(f), q, DEP_NONE);
    r.list = atr_opcode_insts(f, opcodes);
    return r;
}
// checkForAllInstructions with the querying AA's associated function
atr_insts :: (q: u32, opcodes: [] Opcode, uai: *bool, ok: *bool, bb_only := false, pot_dead := false) -> Atr_Insts {
    return atr_fn_insts(irp_assoc_fn(aa(q).pos), q, opcodes, uai, ok, bb_only, pot_dead);
}
atr_call_like_insts :: (q: u32, uai: *bool, ok: *bool, bb_only := false, pot_dead := false) -> Atr_Insts {
    return atr_insts(q, CALL_LIKE_OPCODES, uai, ok, bb_only, pot_dead);
}
// checkForAllReadWriteInstructions
atr_rw_insts :: (q: u32, uai: *bool, ok: *bool) -> Atr_Insts {
    r: Atr_Insts;
    r.q = q; r.uai = uai;
    f := irp_assoc_fn(aa(q).pos);
    if f == NONE { ok.* = false; return r; }
    r.lv = atr_get_aa(.IS_DEAD, irp_function(f), q, DEP_NONE);
    r.list.allocator = temp;
    for atr_fn_info(f).rw_insts array_add(*r.list, it);
    return r;
}

// ---------------------------------------------------------------- AbstractCallSite (llvm/lib/IR/AbstractCallSite.cpp)

// A direct/indirect call (enc empty) or a callback call through a broker's !callback encoding (enc[0]: the
// broker operand of the callback callee, enc[1 + k]: the broker operand passed as callback argument k, -1: none).
Acs :: struct { cb: Value_Id = NONE; enc: [..] s32; }
acs_md_int :: (m: Md_Id) -> s64 { ok, v := md_const_int_value(m); return cast,no_check(s64) v; }
// AbstractCallSite::getCallbackUses
acs_callback_uses :: (cb: Value_Id, out: *[..] Use_Id) {
    callee := call_callee(cb);
    if vkind(callee) != .FUNCTION return;
    md := get_metadata(callee, md_fixed("callback"));
    if md == NONE return;
    for k: 0..cast(s64) md_nops(md) - 1 {
        idx := acs_md_int(md_op(md_node_op(md, cast(u32) k), 0));
        if idx >= 0 && idx < cast(s64) call_num_args(cb) array_add(out, op_use(cb, cast(u32) idx));
    }
}
// AbstractCallSite(const Use *U)
acs_from_use :: (use: Use_Id) -> Acs {
    a: Acs;
    a.enc.allocator = temp;
    u := use;
    usr := ir.u_user[u];
    if !irp_is_call(usr) {
        if vkind(usr) == .C_EXPR && num_uses(usr) == 1 && is_cast_op(cexpr(usr).op) {
            u = ir.v_first_use[usr];
            usr = ir.u_user[u];
        }
        if !irp_is_call(usr) return a;
    }
    a.cb = usr;
    if u == op_use(usr, nops(usr) - 1) return a;
    callee := call_callee(usr);
    if vkind(callee) != .FUNCTION { a.cb = NONE; return a; }
    md := get_metadata(callee, md_fixed("callback"));
    if md == NONE { a.cb = NONE; return a; }
    use_idx := cast(s64) use_arg_no(u);
    enc: Md_Id = NONE;
    for k: 0..cast(s64) md_nops(md) - 1 {
        om := md_node_op(md, cast(u32) k);
        if acs_md_int(md_op(om, 0)) != use_idx continue;
        enc = om;
        break;
    }
    if enc == NONE { a.cb = NONE; return a; }
    for k: 0..cast(s64) md_nops(enc) - 2 array_add(*a.enc, cast(s32) acs_md_int(md_op(enc, cast(u32) k)));
    if !func_vararg(glob(callee).value_type) return a;
    ok, flag := md_const_int_value(md_op(enc, md_nops(enc) - 1));
    if flag == 0 return a;
    na := call_num_args(usr);
    for k: fn_nargs(callee)..na - 1 array_add(*a.enc, cast(s32) k);
    return a;
}
acs_is_callback :: inline (a: Acs) -> bool { return a.enc.count != 0; }
acs_num_args :: (a: Acs) -> s64 { if !acs_is_callback(a) return call_num_args(a.cb); return a.enc.count - 1; }
acs_arg_no :: (a: Acs, k: u32) -> s64 { if !acs_is_callback(a) return k; return a.enc[k + 1]; }
acs_arg :: (a: Acs, k: u32) -> Value_Id {
    if !acs_is_callback(a) return call_arg(a.cb, k);
    n := a.enc[k + 1];
    return ifx n >= 0 then call_arg(a.cb, cast(u32) n) else NONE;
}
acs_called_operand :: (a: Acs) -> Value_Id {
    if !acs_is_callback(a) return call_callee(a.cb);
    return call_arg(a.cb, cast(u32) a.enc[0]);
}
acs_called_function :: (a: Acs) -> Value_Id {
    v := acs_called_operand(a);
    if v == NONE return NONE;
    f := strip_pointer_casts(v);
    return ifx vkind(f) == .FUNCTION then f else NONE;
}
// isCallee(U)
acs_is_callee :: (a: Acs, use: Use_Id) -> bool {
    if !acs_is_callback(a) return use == op_use(a.cb, nops(a.cb) - 1);
    u := use;
    usr := ir.u_user[u];
    if vkind(usr) == .C_EXPR && num_uses(usr) == 1 && is_cast_op(cexpr(usr).op) u = ir.v_first_use[usr];
    if ir.u_user[u] != a.cb return false;
    return cast(s64) use_arg_no(u) == a.enc[0];
}

// ---------------------------------------------------------------- checkForAllCallSites

// The abstract call sites of `f` (the body runs for each, with `it` the call instruction and `acs` the
// AbstractCallSite); `ok` is cleared when the walk fails (not all call sites known, a non-call use, an argument
// type mismatch). The body clears `ok` and breaks when its predicate fails.
Atr_Call_Sites :: struct { f: Value_Id; require_all: bool; q: u32 = NONE; uai: *bool; pot_dead: bool; ok: *bool; }
for_expansion :: (r: Atr_Call_Sites, body: Code, flags: For_Flags) #expand {
    `it_index := 0;
    `it: Value_Id = NONE;
    `acs: Acs;
    _uses: [..] Use_Id; _uses.allocator = temp;
    if r.require_all && !gv_has_local_linkage(r.f) r.ok.* = false;
    else {
        // a blockaddress has no operands in LLVM 23 (here it uses its function): not a use of the function
        _u := ir.v_first_use[r.f];
        while _u != NONE { if vkind(ir.u_user[_u]) != .C_BLOCKADDR array_add(*_uses, _u); _u = ir.u_next[_u]; }
        _k := 0;
        while _k < _uses.count {
            _cu := _uses[_k];
            _k += 1;
            if !r.pot_dead && atr_is_assumed_dead_use(_cu, r.q, NONE, r.uai, true) continue;
            _user := ir.u_user[_cu];
            if vkind(_user) == .C_EXPR && is_cast_op(cexpr(_user).op) && is_ptr_type(vtype(_user)) {
                _x := ir.v_first_use[_user];
                while _x != NONE { array_add(*_uses, _x); _x = ir.u_next[_x]; }
                continue;
            }
            acs = acs_from_use(_cu);
            if acs.cb == NONE { r.ok.* = false; break; }
            _eu := ifx acs_is_callback(acs) then op_use(acs.cb, cast(u32) acs.enc[0]) else _cu;
            if !acs_is_callee(acs, _eu) {
                if !r.require_all continue;
                r.ok.* = false; break;
            }
            _n := min(acs_num_args(acs), cast(s64) fn_nargs(r.f));
            _mismatch := false;
            for _a: 0.._n - 1 {
                _o := acs_arg(acs, cast(u32) _a);
                if _o != NONE && vtype(fn_arg(r.f, cast(u32) _a)) != vtype(_o) { _mismatch = true; break; }
            }
            if _mismatch { r.ok.* = false; break; }
            it = acs.cb;
            #insert body;
        }
    }
}
atr_call_sites_of :: (f: Value_Id, require_all: bool, q: u32, uai: *bool, ok: *bool, pot_dead := false) -> Atr_Call_Sites {
    r: Atr_Call_Sites;
    r.f = f; r.require_all = require_all; r.q = q; r.uai = uai; r.pot_dead = pot_dead; r.ok = ok;
    return r;
}
// checkForAllCallSites(Pred, QueryingAA, RequireAllCallSites, UAI): the querying AA's associated function
atr_call_sites :: (q: u32, require_all: bool, uai: *bool, ok: *bool) -> Atr_Call_Sites {
    f := irp_assoc_fn(aa(q).pos);
    r := atr_call_sites_of(f, require_all, q, uai, ok);
    if f == NONE { ok.* = false; r.require_all = true; r.f = NONE; }
    return r;
}
// a call-site walk that only answers whether it succeeds without a predicate
atr_all_call_sites_known :: (q: u32, uai: *bool) -> bool {
    ok := true;
    if irp_assoc_fn(aa(q).pos) == NONE return false;
    for cb: atr_call_sites(q, true, uai, *ok) {}
    return ok;
}

// checkForAllCallees: the possible callees of `cb` (false: unknown)
atr_callees :: (q: u32, cb: Value_Id) -> (bool, [..] Value_Id) {
    r: [..] Value_Id; r.allocator = temp;
    c := call_callee(cb);
    if vkind(c) == .FUNCTION { array_add(*r, c); return true, r; }
    e := atr_get_aa(.CALL_EDGES, irp_cs_function(cb), q, DEP_OPTIONAL);
    if e == NONE || aa(e).unknown_callee return false, r;
    for aa(e).callees array_add(*r, it);
    return true, r;
}

// ---------------------------------------------------------------- checkForAllUses

// The EquivalentUseCB kinds
EQU_NONE :: cast(u8) 0;
EQU_POINTER_INFO :: cast(u8) 1;   // AAPointerInfoFloating (ctx: *Pi_Offset_Map)
EQU_INSTANCE_INFO :: cast(u8) 2;  // AAInstanceInfoImpl
EQU_GLOBAL_VALUE_INFO :: cast(u8) 3;   // AAGlobalValueInfoFloating (inserts the old use)
EQU_HEAP_TO_STACK :: cast(u8) 4;  // AAHeapToStackFunction's UsesCheck

// Attributor::checkForAllUses as an explicit walk: atr_uses_next returns the next use for the predicate (or NONE
// when done or failed); after the predicate, atr_uses_follow adds the users' uses when it asked to follow.
Uses_Walk :: struct {
    work: [..] Use_Id;
    visited: Table(Use_Id, bool);
    q: u32;
    lv: u32 = NONE;
    bb_only: bool;
    dep: u8;
    ignore_droppable: bool;
    equiv: u8;
    equiv_ctx: *void;
    failed: bool;
}
atr_uses_begin :: (q: u32, v: Value_Id, bb_only := false, dep := DEP_OPTIONAL, ignore_droppable := true, equiv := EQU_NONE, equiv_ctx: *void = null) -> (bool, Uses_Walk) {
    w: Uses_Walk;
    w.work.allocator = temp;
    w.visited.allocator = temp;
    w.q = q; w.bb_only = bb_only; w.dep = dep; w.ignore_droppable = ignore_droppable; w.equiv = equiv; w.equiv_ctx = equiv_ctx;
    if is_constant_data(v) return false, w;
    if !has_uses(v) return true, w;
    atr_uses_add(*w, v, NONE);
    scope := irp_anchor_scope(aa(q).pos);
    if scope != NONE w.lv = atr_get_aa(.IS_DEAD, irp_function(scope), q, DEP_NONE);
    return true, w;
}
// AddUsers
atr_uses_add :: (w: *Uses_Walk, v: Value_Id, old: Use_Id) -> bool {
    u := ir.v_first_use[v];
    while u != NONE {
        if old != NONE && w.equiv != EQU_NONE && !atr_equivalent_use(w, old, u) return false;
        array_add(*w.work, u);
        u = ir.u_next[u];
    }
    return true;
}
atr_uses_next :: (w: *Uses_Walk) -> Use_Id {
    while w.work.count {
        u := pop(*w.work);
        user := ir.u_user[u];
        can_mark := !is_inst(user) || inst_op(user) == .PHI;
        if can_mark {
            if table_contains(*w.visited, u) continue;
            table_set(*w.visited, u, true);
        }
        uai := false;
        if atr_is_assumed_dead_use(u, w.q, w.lv, *uai, w.bb_only, w.dep) continue;
        if w.ignore_droppable && is_droppable_user(user) continue;
        if is_inst(user) && inst_op(user) == .STORE && u == op_use(user, 0) {
            if table_contains(*w.visited, u) continue;
            table_set(*w.visited, u, true);
            copies: [..] Value_Id; copies.allocator = temp;
            if atr_get_potential_copies_of_stored_value(user, *copies, w.q, *uai, true) {
                for c: copies if !atr_uses_add(w, c, u) { w.failed = true; w.work.count = 0; return NONE; }
                continue;
            }
        }
        return u;
    }
    return NONE;
}
atr_uses_follow :: (w: *Uses_Walk, u: Use_Id) { atr_uses_add(w, ir.u_user[u], NONE); }

atr_equivalent_use :: (w: *Uses_Walk, old: Use_Id, nu: Use_Id) -> bool {
    if w.equiv == {
        case EQU_POINTER_INFO; return pi_equivalent_use(cast(*Pi_Offset_Map) w.equiv_ctx, old, nu);
        case EQU_INSTANCE_INFO;
            si := ir.u_user[old];
            if is_inst(si) && inst_op(si) == .STORE {
                ptr := atr_strip_pointer_casts(op(si, 1));
                if ((is_inst(ptr) && inst_op(ptr) == .ALLOCA) || is_no_alias_call(ptr)) && atr_is_dynamically_unique(w.q, ptr) return true;
            }
            return false;
        case EQU_GLOBAL_VALUE_INFO;
            gvi_insert_use(w.q, old);
            return true;
        case EQU_HEAP_TO_STACK;
            si := ir.u_user[old];
            if !is_inst(si) || inst_op(si) != .STORE return true;
            if atr_stack_is_accessible_by_other_threads() return true;
            return atr_is_assumed_thread_local_object(op(si, 1), w.q);
    }
    return true;
}

atr_stack_is_accessible_by_other_threads :: () -> bool { return !atr_is_target_gpu(); }

// ---------------------------------------------------------------- simplification

atr_has_simplification_callback :: (p: Irp) -> bool { return table_contains(*atr.simplification_cbs, irp_key(p)); }
atr_register_simplification_callback :: (p: Irp) { table_set(*atr.simplification_cbs, irp_key(p), true); }

// Attributor::getAssumedSimplifiedValues
atr_get_assumed_simplified_values :: (p0: Irp, q: u32, out: *[..] Vac, s: u8, uai: *bool, recurse := true) -> bool {
    seen: Table(Value_Id, bool); seen.allocator = temp;
    work: [..] Irp; work.allocator = temp;
    array_add(*work, p0);
    while work.count {
        p := pop(*work);
        nv := out.count;
        if atr_has_simplification_callback(p) {
            // the only callbacks (AAHeapToStack's) return nullptr
            return false;
        }
        pv := atr_get_aa(.POTENTIAL_VALUES, p, q, DEP_OPTIONAL);
        if pv != NONE && pv_get_assumed_simplified_values(pv, out, s, false) {
            uai.* |= !aa_is_fix(pv);
        } else if irp_kind(p) != .RETURNED {
            array_add(out, .{irp_assoc_value(p), irp_ctx_i(p)});
        } else {
            return false;
        }
        if !recurse break;
        k := nv;
        e := out.count;
        while k < e {
            v := out.*[k].v;
            if !is_phi(v) && !(is_inst(v) && inst_op(v) == .SELECT) { k += 1; continue; }
            if table_contains(*seen, v) { k += 1; continue; }
            table_set(*seen, v, true);
            out.*[k] = out.*[e - 1];
            out.count -= 1;
            e -= 1;
            array_add(*work, irp_value(v));
        }
    }
    return true;
}

// Attributor::getAssumedSimplified: NONE is nullptr, OV_NOVAL is std::nullopt
atr_get_assumed_simplified :: (p: Irp, q: u32, uai: *bool, s: u8) -> Value_Id {
    if atr_has_simplification_callback(p) return NONE;
    vals: [..] Vac; vals.allocator = temp;
    if !atr_get_assumed_simplified_values(p, q, *vals, s, uai) return irp_assoc_value(p);
    if vals.count == 0 return OV_NOVAL;
    if q != NONE {
        v := pv_get_single_value(p, vals);
        if v != NONE return v;
    }
    pk := irp_kind(p);
    if pk == .RETURNED || pk == .CALL_SITE_RETURNED return NONE;
    return irp_assoc_value(p);
}
atr_get_assumed_simplified_value :: (v: Value_Id, q: u32, uai: *bool, s: u8) -> Value_Id { return atr_get_assumed_simplified(irp_value(v), q, uai, s); }

// Attributor::getAssumedConstant
atr_get_assumed_constant :: (p: Irp, q: u32, uai: *bool) -> Value_Id {
    if atr_has_simplification_callback(p) return NONE;
    v := irp_assoc_value(p);
    if is_constant_kind(vkind(v)) return v;
    vals: [..] Vac; vals.allocator = temp;
    if atr_get_assumed_simplified_values(p, q, *vals, AA_INTER, uai) {
        if vals.count == 0 return OV_NOVAL;
        c := pv_get_single_value(p, vals);
        if c != NONE && is_constant_kind(vkind(c)) return c;
    }
    return NONE;
}
atr_get_assumed_constant_value :: (v: Value_Id, q: u32, uai: *bool) -> Value_Id { return atr_get_assumed_constant(irp_value(v), q, uai); }

// Attributor::translateArgumentToCallSiteContent
atr_translate_argument_to_call_site_content :: (v: Value_Id, cb: Value_Id, q: u32, uai: *bool) -> Value_Id {
    if v == OV_NOVAL || v == NONE || is_constant_kind(vkind(v)) return v;
    if vkind(v) == .ARGUMENT {
        if call_callee(cb) == arg_parent(v) && call_num_args(cb) > arg_no(v) && !arg_has_pointee_in_memory_value_attr(v)
            return atr_get_assumed_simplified(irp_cs_argument(cb, arg_no(v)), q, uai, AA_INTRA);
    }
    return NONE;
}
// Argument::hasPointeeInMemoryValueAttr
arg_has_pointee_in_memory_value_attr :: (a: Value_Id) -> bool {
    if !is_ptr_type(vtype(a)) return false;
    s := arg_attrs(a);
    return attr_set_has(s, .ByVal) || attr_set_has(s, .StructRet) || attr_set_has(s, .InAlloca) || attr_set_has(s, .Preallocated) || attr_set_has(s, .ByRef);
}

// ---------------------------------------------------------------- AA:: helpers

// AA::isValidInScope
atr_is_valid_in_scope :: (v: Value_Id, scope: Value_Id) -> bool {
    k := vkind(v);
    if is_constant_kind(k) return true;
    if k == .INST return inst_fn(v) == scope;
    if k == .ARGUMENT return arg_parent(v) == scope;
    return false;
}
// AA::isValidAtPosition
atr_is_valid_at_position :: (v: Value_Id, ctx: Value_Id) -> bool {
    if is_constant_kind(vkind(v)) || v == ctx return true;
    scope: Value_Id = NONE;
    if ctx != NONE scope = inst_fn(ctx);
    if vkind(v) == .ARGUMENT return arg_parent(v) == scope;
    if is_inst(v) && inst_fn(v) == scope {
        dt := atr_dt(scope);
        if dt return dt_dominates_inst(dt, v, ctx);
        if ctx != NONE && inst_block(v) == inst_block(ctx) {
            x := v;
            while x != NONE { if x == ctx return true; x = inst_next(x); }
        }
    }
    return false;
}
// AA::getWithType
atr_get_with_type :: (v: Value_Id, ty: Type_Id) -> Value_Id {
    if vtype(v) == ty return v;
    k := vkind(v);
    if k == .C_POISON return const_poison(ty);
    if k == .C_UNDEF return const_undef(ty);
    if is_constant_kind(k) {
        if is_null_value(v) && !is_ptr_or_ptr_vector(ty) return const_null_value(ty);
        if is_ptr_type(vtype(v)) && is_ptr_type(ty) return ce_pointer_cast_any(v, ty);
        if ic_primitive_size_bits(vtype(v)) >= ic_primitive_size_bits(ty) {
            if is_int_type(vtype(v)) && is_int_type(ty) return cf_cast(.TRUNC, v, ty);   // getTrunc(OnlyIfReduced)
            if is_fp_type(vtype(v)) && is_fp_type(ty) return cf_cast(.FPTRUNC, v, ty);
        }
    }
    return NONE;
}
// ConstantExpr::getPointerCast for pointer to pointer (an addrspacecast across address spaces)
ce_pointer_cast_any :: (c: Value_Id, t: Type_Id) -> Value_Id {
    if vtype(c) == t return c;
    if type_addrspace(vtype(c)) != type_addrspace(t) return ce_cast(.ADDRSPACECAST, c, t);
    return ce_cast(.BITCAST, c, t);
}
// AA::combineOptionalValuesInAAValueLatice (OV_NOVAL is std::nullopt, NONE is nullptr)
atr_combine_optional_values :: (a: Value_Id, b: Value_Id, ty: Type_Id) -> Value_Id {
    if a == b return a;
    if b == OV_NOVAL return a;
    if b == NONE return NONE;
    if a == OV_NOVAL { if ty != NONE return atr_get_with_type(b, ty); return NONE; }
    if a == NONE return NONE;
    t := ty;
    if t == NONE t = vtype(a);
    if is_undef_value(a) return atr_get_with_type(b, t);
    if is_undef_value(b) return a;
    if a == atr_get_with_type(b, t) return a;
    return NONE;
}

// AA::isDynamicallyUnique (ForAnalysisOnly)
atr_is_dynamically_unique :: (q: u32, v: Value_Id) -> bool {
    ii := atr_get_aa(.INSTANCE_INFO, irp_value(v), q, DEP_OPTIONAL);
    return ii != NONE && bs_is_assumed(aa(ii).s, 1);
}

// AA::isNoSyncInst
atr_is_no_sync_inst :: (i: Value_Id, q: u32) -> bool {
    if is_call_base(i) {
        if call_has_fn_attr(i, .NoSync) return true;
        if !call_has_fn_attr(i, .Convergent) && !may_read_or_write_memory(i) return true;
        ok, _ := atr_has_assumed_ir_attr(.NoSync, q, irp_cs_function(i), DEP_OPTIONAL);
        return ok;
    }
    if !may_read_or_write_memory(i) return true;
    return !aa_is_non_relaxed_atomic(i);
}
// AANoSync::isNonRelaxedAtomic
aa_is_non_relaxed_atomic :: (i: Value_Id) -> bool {
    if !inst_is_atomic(i) return false;
    r := inst(i);
    if r.op == .FENCE return r.sync != SYNC_SCOPE_SINGLE_THREAD;
    if r.op == .CMPXCHG return r.ord1 != ORD_MONOTONIC || r.ord2 != ORD_MONOTONIC;
    if r.op == .ATOMICRMW || r.op == .STORE || r.op == .LOAD return r.ord1 != ORD_UNORDERED && r.ord1 != ORD_MONOTONIC;
    fatal("internal: attributor: new atomic operation");
    return true;
}

// isAssumedReadOnlyOrReadNone
atr_is_assumed_read_only_or_none :: (p: Irp, q: u32, require_read_none: bool) -> (bool, bool) {
    if require_read_none {
        ok, known := atr_has_assumed_ir_attr(.ReadNone, q, p, DEP_OPTIONAL, true);
        if ok return true, known;
    } else {
        ok, known := atr_has_assumed_ir_attr(.ReadOnly, q, p, DEP_OPTIONAL, true);
        if ok return true, known;
    }
    k := irp_kind(p);
    if k == .FUNCTION || k == .CALL_SITE {
        ml := atr_get_aa(.MEM_LOCATION, p, q, DEP_NONE);
        if ml != NONE && ml_is_assumed_read_none(aa(ml).s) {
            known := ml_is_known_read_none(aa(ml).s);
            if !known atr_record_dependence(ml, q, DEP_OPTIONAL);
            return true, known;
        }
    }
    mb := atr_get_aa(.MEM_BEHAVIOR, p, q, DEP_NONE);
    if mb != NONE {
        s := aa(mb).s;
        if bs_is_assumed(s, MB_NO_ACCESSES) || (!require_read_none && bs_is_assumed(s, MB_NO_WRITES)) {
            known := ifx require_read_none then bs_is_known(s, MB_NO_ACCESSES) else bs_is_known(s, MB_NO_WRITES);
            if !known atr_record_dependence(mb, q, DEP_OPTIONAL);
            return true, known;
        }
    }
    return false, false;
}
atr_is_assumed_read_only :: (p: Irp, q: u32) -> (bool, bool) { a, k := atr_is_assumed_read_only_or_none(p, q, false); return a, k; }
atr_is_assumed_read_none :: (p: Irp, q: u32) -> (bool, bool) { a, k := atr_is_assumed_read_only_or_none(p, q, true); return a, k; }

// AA::getInitialValueForObj (range: RangePtr, or null)
atr_get_initial_value_for_obj :: (q: u32, obj: Value_Id, ty: Type_Id, range: *Pi_Range) -> Value_Id {
    init := get_initial_value_of_allocation(obj, ty);
    if init != NONE return init;
    if vkind(obj) != .GLOBAL_VAR return NONE;
    if !gv_has_local_linkage(obj) {
        if !gv_has_definitive_initializer(obj) || !glob(obj).is_const return NONE;
    }
    initializer := gv_initializer(obj);
    if range && !pi_range_offset_or_size_unknown(range.*) {
        storage := cast(s64) dl_type_store_size(ty);
        if storage != range.size return NONE;
        return cfo_load_from_const(initializer, ty, ap_from_s64(64, range.offset));
    }
    return cfo_load_from_uniform_value(initializer, ty);
}

// AA::isAssumedThreadLocalObject
atr_is_assumed_thread_local_object :: (obj: Value_Id, q: u32) -> bool {
    k := vkind(obj);
    if k == .C_UNDEF || k == .C_POISON return true;
    if is_inst(obj) && inst_op(obj) == .ALLOCA {
        if atr_stack_is_accessible_by_other_threads() == false return true;
        ok, _ := atr_has_assumed_ir_attr(.Captures, q, irp_value(obj), DEP_OPTIONAL);
        return ok;
    }
    if k == .GLOBAL_VAR {
        if glob(obj).is_const return true;
        if glob(obj).tls != 0 return true;
    }
    if atr_is_target_gpu() fatal("attributor: GPU address spaces are not supported");
    return false;
}

// The GoBackwardsCB of isPotentiallyReachable: none, or "Fn != f"
Go_Back :: struct { kind: u8; f: Value_Id = NONE; }
GOBACK_NONE :: cast(u8) 0;
GOBACK_NOT_FN :: cast(u8) 1;
go_back_ok :: (g: Go_Back, f: Value_Id) -> bool { return f != g.f; }

// isPotentiallyReachable (FromI, ToI or NONE, ToFn); es: the exclusion set (instructions) or null
atr_is_potentially_reachable_impl :: (from_i: Value_Id, to_i: Value_Id, to_fn: Value_Id, q: u32, es: *[..] Value_Id, gb: Go_Back) -> bool {
    if gb.kind != GOBACK_NONE && to_fn != inst_fn(from_i) && !go_back_ok(gb, inst_fn(from_i)) && atr_is_kernel(to_fn) && atr_is_kernel(inst_fn(from_i))
        return false;
    if gb.kind == GOBACK_NONE && es == null return true;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    array_add(*work, from_i);
    esv: [] Value_Id;
    if es esv = es.*;
    while work.count {
        cur := pop(*work);
        if table_contains(*visited, cur) continue;
        table_set(*visited, cur, true);
        from_fn := inst_fn(cur);
        if from_fn == to_fn {
            if to_i == NONE return true;
            ra := atr_get_aa(.INTRA_REACH, irp_function(to_fn), q, DEP_OPTIONAL);
            result := ra == NONE || intra_is_assumed_reachable(ra, cur, to_i, esv);
            if result return true;
        }
        result := true;
        if !is_declaration(to_fn) && to_i != NONE {
            tra := atr_get_aa(.INTRA_REACH, irp_function(to_fn), q, DEP_OPTIONAL);
            entry := block_first(fn_entry(to_fn));
            result = tra == NONE || intra_is_assumed_reachable(tra, entry, to_i, esv);
        }
        if result {
            fra := atr_get_aa(.INTER_REACH, irp_function(from_fn), q, DEP_OPTIONAL);
            result = fra == NONE || inter_instruction_can_reach(fra, cur, to_fn, esv);
            if result return true;
        }
        ra := atr_get_aa(.INTRA_REACH, irp_function(from_fn), q, DEP_OPTIONAL);
        uai := false;
        ok := true;
        for ret: atr_fn_insts(from_fn, q, .[.RET], *uai, *ok) {
            r := ra == NONE || intra_is_assumed_reachable(ra, cur, ret, esv);
            if r { ok = false; break; }
        }
        if ok continue;
        if gb.kind == GOBACK_NONE return true;
        if !go_back_ok(gb, from_fn) continue;
        ok2 := true;
        for cb: atr_call_sites_of(from_fn, true, q, *uai, *ok2) {
            if inst_op(cb) == .INVOKE { ok2 = false; break; }
            array_add(*work, inst_next(cb));
        }
        if !ok2 return true;
    }
    return false;
}
atr_is_potentially_reachable :: (from_i: Value_Id, to_i: Value_Id, q: u32, es: *[..] Value_Id = null, gb := Go_Back.{}) -> bool {
    return atr_is_potentially_reachable_impl(from_i, to_i, inst_fn(to_i), q, es, gb);
}
atr_is_potentially_reachable_fn :: (from_i: Value_Id, to_fn: Value_Id, q: u32, es: *[..] Value_Id = null, gb := Go_Back.{}) -> bool {
    return atr_is_potentially_reachable_impl(from_i, NONE, to_fn, q, es, gb);
}

// ---------------------------------------------------------------- potential copies of memory values

// The state of getPotentialCopiesOfMemoryValue's lambdas for one underlying object
Copies_Ctx :: struct {
    is_load: bool;
    only_exact: bool;
    want_origins: bool;
    i: Value_Id;               // the load or store
    new_copies: *[..] Value_Id;      // SmallSetVector
    new_origins: *[..] Value_Id;     // SmallSetVector (NONE: the initial value)
    null_only: bool;
    null_required: bool;
}
copies_insert :: (l: *[..] Value_Id, v: Value_Id) -> bool { for l.* if it == v return false; array_add(l, v); return true; }
copies_contains :: (l: *[..] Value_Id, v: Value_Id) -> bool { for l.* if it == v return true; return false; }

// CheckForNullOnlyAndUndef
copies_check_null_only_and_undef :: (c: *Copies_Ctx, v: Value_Id, is_exact: bool) {
    if v == OV_NOVAL || v == NONE c.null_only = false;
    else if is_undef_value(v) {}
    else if is_constant_kind(vkind(v)) && is_null_value(v) c.null_required = !is_exact;
    else c.null_only = false;
}
// SkipCB
copies_skip :: (c: *Copies_Ctx, acc: *Pi_Access) -> bool {
    if (c.is_load && !pi_acc_is_write_or_assumption(acc)) || (!c.is_load && !pi_acc_is_read(acc)) return true;
    if c.is_load {
        if acc.content == OV_NOVAL return true;
        if c.want_origins && !(inst_op(acc.remote) == .CALL && call_iid(acc.remote) == IID_ASSUME) return false;
        if acc.content != NONE {
            v := atr_get_with_type(acc.content, vtype(c.i));
            if v != NONE && copies_contains(c.new_copies, v) { copies_insert(c.new_origins, acc.remote); return true; }
        }
        if inst_op(acc.remote) == .STORE {
            v := atr_get_with_type(op(acc.remote, 0), vtype(c.i));
            if v != NONE && copies_contains(c.new_copies, v) { copies_insert(c.new_origins, acc.remote); return true; }
        }
    }
    return false;
}
// CheckAccess
copies_check_access :: (c: *Copies_Ctx, acc: *Pi_Access, is_exact: bool) -> bool {
    if (c.is_load && !pi_acc_is_write_or_assumption(acc)) || (!c.is_load && !pi_acc_is_read(acc)) return true;
    if c.is_load && acc.content == OV_NOVAL return true;
    copies_check_null_only_and_undef(c, acc.content, is_exact);
    wv_undef := acc.content != OV_NOVAL && acc.content != NONE && is_undef_value(acc.content);
    if c.only_exact && !is_exact && !c.null_only && !wv_undef return false;
    if c.null_required && !c.null_only return false;
    if c.is_load {
        if acc.content != NONE {
            v := atr_get_with_type(acc.content, vtype(c.i));
            if v == NONE return false;
            copies_insert(c.new_copies, v);
            if c.want_origins copies_insert(c.new_origins, acc.remote);
            return true;
        }
        if inst_op(acc.remote) != .STORE return false;
        v := atr_get_with_type(op(acc.remote, 0), vtype(c.i));
        if v == NONE return false;
        copies_insert(c.new_copies, v);
        if c.want_origins copies_insert(c.new_origins, acc.remote);
    } else {
        is_li := inst_op(acc.remote) == .LOAD;
        if !is_li && c.only_exact return false;
        copies_insert(c.new_copies, acc.remote);
    }
    return true;
}

// getPotentialCopiesOfMemoryValue<IsLoad>
atr_get_potential_copies_of_memory_value :: (is_load: bool, i: Value_Id, copies: *[..] Value_Id, origins: *[..] Value_Id, q: u32, uai: *bool, only_exact: bool) -> bool {
    ptr := ifx is_load then op(i, 0) else op(i, 1);
    pis: [..] u32; pis.allocator = temp;
    new_copies: [..] Value_Id; new_copies.allocator = temp;
    new_origins: [..] Value_Id; new_origins.allocator = temp;
    uo := atr_get_aa(.UNDERLYING_OBJECTS, irp_value(ptr), q, DEP_OPTIONAL);
    if uo == NONE return false;
    objs: [..] Value_Id; objs.allocator = temp;
    uo_objects(uo, false, *objs);
    for obj: objs {
        k := vkind(obj);
        if k == .C_UNDEF || k == .C_POISON continue;
        if k == .C_NULL {
            if !null_pointer_is_defined(inst_fn(i), ptr_addrspace(vtype(ptr))) && atr_get_assumed_simplified_value(ptr, q, uai, AA_INTER) == obj continue;
            return false;
        }
        is_alloca := is_inst(obj) && inst_op(obj) == .ALLOCA;
        if !is_alloca && k != .GLOBAL_VAR {
            supported := ifx is_load then is_allocation_fn(obj) else is_no_alias_call(obj);
            if !supported return false;
        }
        if k == .GLOBAL_VAR && !gv_has_local_linkage(obj) && !(glob(obj).is_const && gv_initializer(obj) != NONE) return false;
        c: Copies_Ctx;
        c.is_load = is_load; c.only_exact = only_exact; c.want_origins = origins != null; c.i = i;
        c.new_copies = *new_copies; c.new_origins = *new_origins;
        c.null_only = true; c.null_required = false;
        written := false;
        range := pi_range_unassigned();
        pi := atr_get_aa(.POINTER_INFO, irp_value(obj), q, DEP_NONE);
        if pi == NONE || !pi_forall_interfering_accesses_for_inst(pi, q, i, is_load, !is_load, *c, *written, *range) return false;
        if is_load && !written && !pi_range_is_unassigned(range) {
            iv := atr_get_initial_value_for_obj(q, obj, vtype(i), *range);
            if iv == NONE return false;
            copies_check_null_only_and_undef(*c, iv, true);
            if c.null_required && !c.null_only return false;
            copies_insert(*new_copies, iv);
            if origins copies_insert(*new_origins, NONE);
        }
        array_add(*pis, pi);
    }
    for pi: pis {
        if !aa_is_fix(pi) uai.* = true;
        atr_record_dependence(pi, q, DEP_OPTIONAL);
    }
    for new_copies copies_insert(copies, it);
    if origins for new_origins copies_insert(origins, it);
    return true;
}
// AA::getPotentiallyLoadedValues
atr_get_potentially_loaded_values :: (li: Value_Id, values: *[..] Value_Id, origins: *[..] Value_Id, q: u32, uai: *bool, only_exact := false) -> bool {
    return atr_get_potential_copies_of_memory_value(true, li, values, origins, q, uai, only_exact);
}
// AA::getPotentialCopiesOfStoredValue
atr_get_potential_copies_of_stored_value :: (si: Value_Id, copies: *[..] Value_Id, q: u32, uai: *bool, only_exact := false) -> bool {
    return atr_get_potential_copies_of_memory_value(false, si, copies, null, q, uai, only_exact);
}

// Value::stripPointerCasts (PSK_ZeroIndices, through `returned` arguments; the autoupgrade helper does not look
// through calls)
atr_strip_pointer_casts :: (v: Value_Id) -> Value_Id { return strip_pointer_casts_kind(v, .ZERO_INDICES); }
