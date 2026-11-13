// AAPotentialValues, AAPotentialConstantValues and AAValueConstantRange: a port of their parts of
// llvm/lib/Transforms/IPO/AttributorAttributes.cpp (with PotentialValuesState / IntegerRangeState from
// llvm/include/llvm/Transforms/IPO/Attributor.h), plus the generic clamping helpers (clampReturnedValueStates,
// clampCallSiteArgumentStates, AACalleeToCallSite) over the state kinds they are instantiated with.

// ---------------------------------------------------------------- AAPotentialValues (PotentialLLVMValuesState)

Pv_Item :: struct { v: Value_Id; ctx: Value_Id; s: u8; }
Pv_State :: struct {
    set: [..] Pv_Item;         // SmallSetVector
    undef: bool;
}
Pv_Ext :: struct {
    st: Pv_State;              // the validity BooleanState is aa.s
    returned_arg: Value_Id = NONE;   // AAPotentialValuesReturned::ReturnedArg
}
pv_ext :: inline (i: u32) -> *Pv_Ext { return cast(*Pv_Ext) aa(i).x; }
pv_st :: inline (i: u32) -> *Pv_State { return *pv_ext(i).st; }

// PotentialValuesState::unionAssumed(MemberTy) (MaxPotentialValues is -1: never invalidates)
pv_union_item :: (bs: *Bstate, st: *Pv_State, item: Pv_Item) {
    if !bs_is_valid(bs.*) return;
    found := false;
    for x: st.set if x.v == item.v && x.ctx == item.ctx && x.s == item.s { found = true; break; }
    if !found array_add(*st.set, item);
    st.undef = st.undef && st.set.count == 0;
}

pv_set_equal :: (a: [] Pv_Item, b: [] Pv_Item) -> bool {
    if a.count != b.count return false;
    for a if it.v != b[it_index].v || it.ctx != b[it_index].ctx || it.s != b[it_index].s return false;
    return true;
}
Pv_Snapshot :: struct { valid: bool; undef: bool; set: [..] Pv_Item; }
pv_snapshot :: (i: u32) -> Pv_Snapshot {
    r: Pv_Snapshot;
    r.set.allocator = temp;
    r.valid = aa_is_valid(i);
    st := pv_st(i);
    r.undef = st.undef;
    for st.set array_add(*r.set, it);
    return r;
}
// PotentialValuesState::operator==
pv_same_as :: (i: u32, s: Pv_Snapshot) -> bool {
    valid := aa_is_valid(i);
    if valid != s.valid return false;
    if !valid return true;
    if pv_st(i).undef != s.undef return false;
    return pv_set_equal(pv_st(i).set, s.set);
}

// askForAssumedConstant<AAType>: OV_NOVAL (std::nullopt), NONE (nullptr) or the constant
atr_ask_for_assumed_constant :: (k: Atr_Kind, q: u32, p: Irp, ty: Type_Id) -> Value_Id {
    if !is_int_type(ty) return NONE;
    o := atr_get_aa(k, p, q, DEP_NONE);
    if o == NONE return NONE;
    c := ifx k == .VALUE_CONSTANT_RANGE then vcr_get_assumed_constant(o, NONE) else pcv_get_assumed_constant(o);
    if c == OV_NOVAL { atr_record_dependence(o, q, DEP_OPTIONAL); return OV_NOVAL; }
    if c != NONE { atr_record_dependence(o, q, DEP_OPTIONAL); return c; }
    return NONE;
}
// askOtherAA<AAType>
pv_ask_other_aa :: (k: Atr_Kind, q: u32, p: Irp, ty: Type_Id) -> Value_Id {
    v := irp_assoc_value(p);
    if is_constant_kind(vkind(v)) return v;
    c := atr_ask_for_assumed_constant(k, q, p, ty);
    if c == OV_NOVAL return OV_NOVAL;
    if c != NONE {
        cc := atr_get_with_type(c, ty);
        if cc != NONE return cc;
    }
    return NONE;
}

// AAPotentialValuesImpl::addValue
pv_add_value :: (i: u32, bs: *Bstate, st: *Pv_State, v: Value_Id, ctx_in: Value_Id, s_in: u8, anchor: Value_Id) {
    ctx := ctx_in;
    s := s_in;
    vp := irp_value(v);
    if ctx != NONE && irp_is_call(ctx) {
        for k: 0..cast(s64) call_num_args(ctx) - 1 {
            if call_arg(ctx, cast(u32) k) != v continue;
            vp = irp_cs_argument(ctx, cast(u32) k);
            break;
        }
    }
    vptr := v;
    if is_int_type(irp_assoc_type(vp)) {
        ty := irp_assoc_type(aa(i).pos);
        sv := pv_ask_other_aa(.VALUE_CONSTANT_RANGE, i, vp, ty);
        if sv == NONE {
            pc := atr_get_aa(.POTENTIAL_CONSTANT_VALUES, vp, i, DEP_OPTIONAL);
            if pc != NONE && aa_is_valid(pc) {
                for c: pcv_ext(pc).set pv_union_item(bs, st, .{const_int_ap(ty, c), NONE, s});
                if pcv_ext(pc).undef pv_union_item(bs, st, .{const_undef(ty), NONE, s});
                return;
            }
        }
        if sv == OV_NOVAL return;
        if sv != NONE vptr = sv;
    }
    if vkind(vptr) == .C_INT ctx = NONE;
    if !atr_is_valid_in_scope(vptr, anchor) s |= AA_INTER;
    pv_union_item(bs, st, .{vptr, ctx, s});
}
pv_add :: (i: u32, v: Value_Id, ctx: Value_Id, s: u8) { pv_add_value(i, *aa(i).s, pv_st(i), v, ctx, s, irp_anchor_scope(aa(i).pos)); }

// AAPotentialValuesImpl::indicatePessimisticFixpoint (the AA's state is reset to {assoc value, AnyScope})
pv_impl_pessimistic :: (i: u32) {
    st := pv_st(i);
    st.set.count = 0;
    st.undef = false;
    aa(i).s = bs_new(1);
    p := aa(i).pos;
    pv_union_item(*aa(i).s, st, .{irp_assoc_value(p), irp_ctx_i(p), AA_ANY});
    bs_optimistic(*aa(i).s);
}
pv_construct :: (i: u32) { aa(i).x = New(Pv_Ext); }

// recurseForValue
pv_recurse_for_value :: (i: u32, p: Irp, s: u8) -> bool {
    keys: [..] Vac; keys.allocator = temp;
    scopes: [..] u8; scopes.allocator = temp;
    for cs: u8.[AA_INTRA, AA_INTER] {
        if !(cs & s) continue;
        uai := false;
        vals: [..] Vac; vals.allocator = temp;
        if !atr_get_assumed_simplified_values(p, i, *vals, cs, *uai) return false;
        for it: vals {
            found := -1;
            for k: keys if k.v == it.v && k.ctx == it.ctx { found = it_index; break; }
            if found < 0 { array_add(*keys, it); array_add(*scopes, cs); }
            else scopes[found] += cs;
        }
    }
    for k: keys pv_add(i, k.v, k.ctx, scopes[it_index]);
    return true;
}
// giveUpOnIntraprocedural
pv_give_up_on_intraprocedural :: (i: u32) {
    ns: Pv_State;
    ns.set.allocator = temp;
    nbs := bs_new(1);
    anchor := irp_anchor_scope(aa(i).pos);
    for it: pv_st(i).set {
        if it.s == AA_INTRA continue;
        pv_add_value(i, *nbs, *ns, it.v, it.ctx, AA_INTER, anchor);
    }
    p := aa(i).pos;
    pv_add_value(i, *nbs, *ns, irp_assoc_value(p), irp_ctx_i(p), AA_INTRA, anchor);
    st := pv_st(i);
    st.set.count = 0;
    for ns.set array_add(*st.set, it);
    st.undef = ns.undef;
    aa(i).s = nbs;
}

// AAPotentialValuesImpl::getAssumedSimplifiedValues
pv_get_assumed_simplified_values :: (i: u32, out: *[..] Vac, s: u8, recurse: bool) -> bool {
    if !aa_is_valid(i) return false;
    uai := false;
    items: [..] Pv_Item; items.allocator = temp;
    for pv_st(i).set array_add(*items, it);
    for it: items {
        if !(it.s & s) continue;
        if recurse && (is_phi(it.v) || (is_inst(it.v) && inst_op(it.v) == .SELECT)) {
            if atr_get_assumed_simplified_values(irp_inst(it.v), i, out, s, *uai) continue;
        }
        array_add(out, .{it.v, it.ctx});
    }
    return true;
}
// AAPotentialValues::getSingleValue
pv_get_single_value :: (p: Irp, values: [] Vac) -> Value_Id {
    ty := irp_assoc_type(p);
    v := OV_NOVAL;
    for values {
        v = atr_combine_optional_values(v, it.v, ty);
        if v == NONE break;
    }
    if v == OV_NOVAL return const_undef(ty);
    return v;
}

pv_initialize :: (i: u32) {
    p := aa(i).pos;
    pk := aa(i).pk;
    if pk == .ARGUMENT {
        if arg_has_pointee_in_memory_value_attr(irp_assoc_value(p)) aa_pessimistic(i);
        return;
    }
    if pk == .RETURNED { pv_returned_initialize(i); return; }
    if atr_has_simplification_callback(p) { aa_pessimistic(i); return; }
    stripped := atr_strip_pointer_casts(irp_assoc_value(p));
    if is_constant_kind(vkind(stripped)) && vkind(stripped) != .C_EXPR {
        pv_add(i, stripped, irp_ctx_i(p), AA_ANY);
        aa_optimistic(i);
        return;
    }
}

pv_update :: (i: u32) -> bool {
    pk := aa(i).pk;
    if pk == .ARGUMENT return pv_argument_update(i);
    if pk == .RETURNED return pv_returned_update(i);
    if pk == .CALL_SITE_RETURNED return pv_cs_returned_update(i);
    if pk == .FUNCTION || pk == .CALL_SITE return aa_pessimistic(i);
    before := pv_snapshot(i);
    pv_generic_value_traversal(i, irp_assoc_value(aa(i).pos));
    return !pv_same_as(i, before);
}

// AAPotentialValuesFloating
Pv_Liveness :: struct { f: Value_Id; lv: u32; any_dead: bool; }
Pv_Work :: struct { v: Value_Id; ctx: Value_Id; s: u8; }

pv_handle_cmp :: (i: u32, cmp: Value_Id, lhs: Value_Id, rhs: Value_Id, pred: u8, ii: Pv_Work, work: *[..] Pv_Work) -> bool {
    uai := false;
    lvals: [..] Vac; lvals.allocator = temp;
    rvals: [..] Vac; rvals.allocator = temp;
    get_vals :: (i: u32, v: Value_Id, out: *[..] Vac, ii: Pv_Work, uai: *bool) -> bool {
        if !atr_get_assumed_simplified_values(irp_value(v), i, out, AA_INTRA, uai) {
            out.count = 0;
            array_add(out, .{v, ii.ctx});
        }
        return out.count == 0;
    }
    if get_vals(i, lhs, *lvals, ii, *uai) return true;
    if get_vals(i, rhs, *rvals, ii, *uai) return true;
    f: Value_Id = ifx is_inst(cmp) then inst_fn(cmp) else NONE;
    q: Simplify_Query;
    if f != NONE { q.dt = atr_dt(f); q.ac = atr_ac(f); }
    q.have_tli = f != NONE;
    q.cxt = ifx is_inst(cmp) then cmp else NONE;
    anchor := irp_anchor_scope(aa(i).pos);
    i1 := type_int(1);
    check_pair :: (i: u32, cmp: Value_Id, lhs: Value_Id, rhs: Value_Id, lv: Value_Id, rv: Value_Id, pred: u8, ii: Pv_Work, q: Simplify_Query, i1: Type_Id) -> bool {
        if is_undef_value(lv) || is_undef_value(rv) {
            pv_add(i, const_undef(vtype(cmp)), NONE, ii.s);
            return true;
        }
        if lv == rv && (cmp_is_true_when_equal(pred) || cmp_is_false_when_equal(pred)) {
            pv_add(i, const_int(i1, cast(u64) cmp_is_true_when_equal(pred)), NONE, ii.s);
            return true;
        }
        tl := atr_get_with_type(lv, vtype(lhs));
        tr := atr_get_with_type(rv, vtype(rhs));
        if tl != NONE && tr != NONE {
            nv := simplify_cmp_inst(pred, false, tl, tr, q);
            if nv != NONE && nv != cmp {
                pv_add(i, nv, NONE, ii.s);
                return true;
            }
        }
        if !icmp_is_equality(pred) return false;
        lnull := vkind(lv) == .C_NULL;
        rnull := vkind(rv) == .C_NULL;
        if !lnull && !rnull return false;
        ptr := ifx lnull then rv else lv;
        nn, _ := atr_has_assumed_ir_attr(.NonNull, i, irp_value(ptr), DEP_REQUIRED);
        if !nn return false;
        pv_add(i, const_int(i1, cast(u64) (pred == ICMP_NE)), NONE, ii.s);
        return true;
    }
    for l: lvals for r: rvals if !check_pair(i, cmp, lhs, rhs, l.v, r.v, pred, ii, q, i1) return false;
    return true;
}

pv_handle_select :: (i: u32, si: Value_Id, ii: Pv_Work, work: *[..] Pv_Work) -> bool {
    uai := false;
    c := atr_get_assumed_constant_value(op(si, 0), i, *uai);
    if c == OV_NOVAL || (c != NONE && is_undef_value(c)) return true;
    if c != NONE && vkind(c) == .C_INT {
        if ap_is_zero(const_ap(c)) array_add(work, .{op(si, 2), ii.ctx, ii.s});
        else array_add(work, .{op(si, 1), ii.ctx, ii.s});
    } else if si == irp_assoc_value(aa(i).pos) {
        array_add(work, .{op(si, 1), ii.ctx, ii.s});
        array_add(work, .{op(si, 2), ii.ctx, ii.s});
    } else {
        sv := atr_get_assumed_simplified(irp_inst(si), i, *uai, ii.s);
        if sv == OV_NOVAL return true;
        if sv != NONE { pv_add(i, sv, ii.ctx, ii.s); return true; }
        return false;
    }
    return true;
}

pv_handle_load :: (i: u32, li: Value_Id, ii: Pv_Work, work: *[..] Pv_Work) -> bool {
    copies: [..] Value_Id; copies.allocator = temp;
    origins: [..] Value_Id; origins.allocator = temp;
    uai := false;
    if !atr_get_potentially_loaded_values(li, *copies, *origins, i, *uai, true) return false;
    if atr_is_only_used_by_assume(li) {
        for o: origins {
            if o == NONE || (inst_op(o) == .CALL && call_iid(o) == IID_ASSUME) continue;
            if inst_op(o) == .STORE {
                if atr_is_assumed_dead_use(op_use(o, 0), i, NONE, *uai, false) continue;
                return false;
            }
            if atr_is_assumed_dead_inst(o, i, NONE, *uai, false) continue;
            return false;
        }
    }
    anchor := irp_anchor_scope(aa(i).pos);
    scope_is_local := (ii.s & AA_INTRA) != 0;
    all_local := scope_is_local;
    for pc: copies {
        all_local &= atr_is_valid_in_scope(pc, anchor);
        if !atr_is_dynamically_unique(i, pc) return false;
    }
    for pc: copies {
        if all_local array_add(work, .{pc, ii.ctx, ii.s});
        else array_add(work, .{pc, ii.ctx, AA_INTER});
    }
    if !all_local && scope_is_local pv_add(i, li, ii.ctx, AA_INTRA);
    return true;
}

pv_handle_phi :: (i: u32, phi: Value_Id, ii: Pv_Work, work: *[..] Pv_Work, livs: *[..] Pv_Liveness) -> bool {
    get_liveness :: (i: u32, f: Value_Id, livs: *[..] Pv_Liveness) -> *Pv_Liveness {
        for * livs.* if it.f == f {
            if it.lv == NONE it.lv = atr_get_aa(.IS_DEAD, irp_function(f), i, DEP_NONE);
            return it;
        }
        array_add(livs, .{f, NONE, false});
        l := *livs.*[livs.count - 1];
        l.lv = atr_get_aa(.IS_DEAD, irp_function(f), i, DEP_NONE);
        return l;
    }
    if phi == irp_assoc_value(aa(i).pos) {
        l := get_liveness(i, inst_fn(phi), livs);
        ci := atr_ci(inst_fn(phi));
        c: Cycle_Id = NONE;
        cycle_phi := atr_may_be_in_cycle(ci, phi, true, *c);
        for u: 0..cast(s64) phi_num_incoming(phi) - 1 {
            inc := phi_block(phi, cast(u32) u);
            if l.lv != NONE && dead_is_edge_dead(l.lv, inc, inst_block(phi)) { l.any_dead = true; continue; }
            v := phi_value(phi, cast(u32) u);
            if v == phi continue;
            if cycle_phi && is_inst(v) && (c == NONE || ci_contains(ci, c, inst_block(v))) return false;
            array_add(work, .{v, block_terminator(inc), ii.s});
        }
        return true;
    }
    uai := false;
    sv := atr_get_assumed_simplified(irp_inst(phi), i, *uai, ii.s);
    if sv == OV_NOVAL return true;
    if sv == NONE return false;
    pv_add(i, sv, phi, ii.s);
    return true;
}

pv_handle_generic_inst :: (i: u32, x: Value_Id, ii: Pv_Work, work: *[..] Pv_Work) -> bool {
    some := false;
    uai := false;
    n := nops(x);
    new_ops: [..] Value_Id; new_ops.allocator = temp;
    for k: 0..cast(s64) n - 1 {
        o := op(x, cast(u32) k);
        so := atr_get_assumed_simplified_value(o, i, *uai, AA_INTRA);
        if so == OV_NOVAL return true;
        nv := ifx so != NONE then so else o;
        array_add(*new_ops, nv);
        some |= nv != o;
    }
    if !some return false;
    f := inst_fn(x);
    q: Simplify_Query;
    q.dt = atr_dt(f); q.ac = atr_ac(f); q.cxt = x;
    nv := simplify_instruction_with_operands(x, new_ops, q);
    if nv == NONE || nv == x return false;
    array_add(work, .{nv, ii.ctx, ii.s});
    return true;
}

pv_simplify_instruction :: (i: u32, x: Value_Id, ii: Pv_Work, work: *[..] Pv_Work, livs: *[..] Pv_Liveness) -> bool {
    o := inst_op(x);
    if o == .ICMP || o == .FCMP return pv_handle_cmp(i, x, op(x, 0), op(x, 1), inst_pred(x), ii, work);
    if o == .SELECT return pv_handle_select(i, x, ii, work);
    if o == .PHI return pv_handle_phi(i, x, ii, work, livs);
    if o == .LOAD return pv_handle_load(i, x, ii, work);
    return pv_handle_generic_inst(i, x, ii, work);
}

// genericValueTraversal
pv_generic_value_traversal :: (i: u32, initial: Value_Id) {
    livs: [..] Pv_Liveness; livs.allocator = temp;
    visited: [..] Pv_Work; visited.allocator = temp;
    work: [..] Pv_Work; work.allocator = temp;
    p := aa(i).pos;
    actx := irp_ctx_i(p);
    array_add(*work, .{initial, actx, AA_ANY});
    iteration := 0;
    while true {
        ii := pop(*work);
        v := ii.v;
        ctx := ii.ctx;
        s := ii.s;
        seen := false;
        for visited if it.v == v && it.ctx == ctx && it.s == s { seen = true; break; }
        if seen { if work.count == 0 break; continue; }
        array_add(*visited, ii);
        iteration += 1;
        if iteration - 1 >= atr_max_potential_values_iterations {
            pv_add(i, v, ctx, s);
            if work.count == 0 break;
            continue;
        }
        nv: Value_Id = NONE;
        if is_ptr_type(vtype(v)) {
            nv = atr_get_with_type(atr_strip_pointer_casts(v), vtype(v));
        } else if irp_is_call(v) {
            callee := call_callee(v);
            if vkind(callee) == .FUNCTION {
                for k: 0..cast(s64) fn_nargs(callee) - 1 {
                    if arg_has_attr(fn_arg(callee, cast(u32) k), .Returned) { nv = call_arg(v, cast(u32) k); break; }
                }
            }
        }
        if nv != NONE && nv != v {
            array_add(*work, .{nv, ctx, s});
            if work.count == 0 break;
            continue;
        }
        if is_inst(v) {
            if pv_simplify_instruction(i, v, ii, *work, *livs) { if work.count == 0 break; continue; }
        }
        if v != initial || vkind(v) == .ARGUMENT {
            if pv_recurse_for_value(i, irp_value(v), ii.s) { if work.count == 0 break; continue; }
        }
        if v == initial && ctx == actx {
            aa_pessimistic(i);
            return;
        }
        pv_add(i, v, ctx, s);
        if work.count == 0 break;
    }
    for livs if it.any_dead atr_record_dependence(it.lv, i, DEP_OPTIONAL);
}

// AAPotentialValuesArgument::updateImpl
pv_argument_update :: (i: u32) -> bool {
    before := pv_snapshot(i);
    argno := cast(u32) irp_callee_arg_no(aa(i).pos);
    uai := false;
    vals: [..] Vac; vals.allocator = temp;
    ok := true;
    for cb: atr_call_sites(i, true, *uai, *ok) {
        cp := irp_acs_argument(acs, argno);
        if irp_kind(cp) == .INVALID { ok = false; break; }
        if !atr_get_assumed_simplified_values(cp, i, *vals, AA_INTER, *uai) { ok = false; break; }
        if !aa_is_valid(i) { ok = false; break; }
    }
    if !ok return aa_pessimistic(i);
    f := irp_assoc_fn(aa(i).pos);
    any_non_local := false;
    for it: vals {
        if is_constant_kind(vkind(it.v)) { pv_add(i, it.v, it.ctx, AA_ANY); continue; }
        if !atr_is_dynamically_unique(i, it.v) return aa_pessimistic(i);
        if vkind(it.v) == .ARGUMENT && arg_parent(it.v) == f { pv_add(i, it.v, it.ctx, AA_ANY); continue; }
        pv_add(i, it.v, it.ctx, AA_INTER);
        any_non_local = true;
    }
    if any_non_local pv_give_up_on_intraprocedural(i);
    return !pv_same_as(i, before);
}

// AAPotentialValuesReturned
pv_returned_initialize :: (i: u32) {
    f := irp_assoc_fn(aa(i).pos);
    if f == NONE || is_declaration(f) || type_kind(fn_ret_type(f)) == .VOID { aa_pessimistic(i); return; }
    for k: 0..cast(s64) fn_nargs(f) - 1 {
        a := fn_arg(f, cast(u32) k);
        if arg_has_attr(a, .Returned) {
            pv_add_value(i, *aa(i).s, pv_st(i), a, NONE, AA_ANY, f);
            pv_ext(i).returned_arg = a;
            break;
        }
    }
    if !atr_is_ipo_amendable(f) || atr_has_simplification_callback(aa(i).pos) {
        if pv_ext(i).returned_arg == NONE aa_pessimistic(i);
        else aa_optimistic(i);
    }
}
pv_returned_update :: (i: u32) -> bool {
    before := pv_snapshot(i);
    uai := false;
    anchor := irp_anchor_scope(aa(i).pos);
    handle :: (i: u32, v: Value_Id, ctx: Value_Id, add_values: bool, anchor: Value_Id, uai: *bool) -> bool {
        for s: u8.[AA_INTER, AA_INTRA] {
            vals: [..] Vac; vals.allocator = temp;
            if !atr_get_assumed_simplified_values(irp_value(v), i, *vals, s, uai, true) return false;
            if !add_values continue;
            all_inter_are_intra := false;
            if s == AA_INTER {
                all_inter_are_intra = true;
                for vals if !atr_is_valid_in_scope(it.v, anchor) { all_inter_are_intra = false; break; }
            }
            for vals pv_add_value(i, *aa(i).s, pv_st(i), it.v, ifx it.ctx != NONE then it.ctx else ctx, ifx all_inter_are_intra then AA_ANY else s, anchor);
            if all_inter_are_intra break;
        }
        return true;
    }
    ra := pv_ext(i).returned_arg;
    if ra != NONE {
        handle(i, ra, NONE, true, anchor, *uai);
    } else {
        ok := true;
        for ri: atr_insts(i, .[.RET], *uai, *ok, true) {
            add := true;
            rv := op(ri, 0);
            if is_phi(rv) || (is_inst(rv) && inst_op(rv) == .SELECT) {
                pv_add_value(i, *aa(i).s, pv_st(i), rv, ri, AA_ANY, anchor);
                add = false;
            }
            if !handle(i, rv, ri, add, anchor, *uai) { ok = false; break; }
        }
        if !ok return aa_pessimistic(i);
    }
    return !pv_same_as(i, before);
}

// AAPotentialValuesCallSiteReturned::updateImpl
pv_cs_returned_update :: (i: u32) -> bool {
    before := pv_snapshot(i);
    callee := irp_assoc_fn(aa(i).pos);
    if callee == NONE return aa_pessimistic(i);
    uai := false;
    cb := irp_ctx_i(aa(i).pos);
    if call_is_must_tail(cb) && !atr_is_assumed_dead_irp(irp_inst(cb), i, NONE, *uai) return aa_pessimistic(i);
    caller := inst_fn(cb);
    add_scope :: (i: u32, callee: Value_Id, cb: Value_Id, caller: Value_Id, s: u8, uai: *bool) -> bool {
        vals: [..] Vac; vals.allocator = temp;
        if !atr_get_assumed_simplified_values(irp_returned(callee), i, *vals, s, uai) return false;
        for it: vals {
            v := it.v;
            cv := atr_translate_argument_to_call_site_content(v, cb, i, uai);
            if cv == OV_NOVAL continue;
            if cv != NONE v = cv;
            if cv != NONE && atr_is_dynamically_unique(i, v) {
                if pv_recurse_for_value(i, irp_value(v), s) continue;
            }
            if s == AA_INTRA && !atr_is_valid_in_scope(v, caller) {
                pv_give_up_on_intraprocedural(i);
                return true;
            }
            pv_add(i, v, cb, s);
        }
        return true;
    }
    if !add_scope(i, callee, cb, caller, AA_INTRA, *uai) return aa_pessimistic(i);
    if !add_scope(i, callee, cb, caller, AA_INTER, *uai) return aa_pessimistic(i);
    return !pv_same_as(i, before);
}

pv_manifest :: (i: u32) -> bool {
    p := aa(i).pos;
    if aa(i).pk == .RETURNED return pv_returned_manifest(i);
    for s: u8.[AA_INTER, AA_INTRA] {
        vals: [..] Vac; vals.allocator = temp;
        if !pv_get_assumed_simplified_values(i, *vals, s, false) continue;
        old := irp_assoc_value(p);
        if is_undef_value(old) continue;
        nv := pv_get_single_value(p, vals);
        if nv == NONE || nv == old continue;
        ctx := irp_ctx_i(p);
        if ctx != NONE && !atr_is_valid_at_position(nv, ctx) continue;
        if atr_change_after_manifest(p, nv) return ATR_CHANGED;
    }
    return ATR_UNCHANGED;
}
pv_returned_manifest :: (i: u32) -> bool {
    if pv_ext(i).returned_arg != NONE return ATR_UNCHANGED;
    p := aa(i).pos;
    vals: [..] Vac; vals.allocator = temp;
    if !pv_get_assumed_simplified_values(i, *vals, AA_INTRA, true) return ATR_UNCHANGED;
    nv := pv_get_single_value(p, vals);
    if nv == NONE return ATR_UNCHANGED;
    changed := ATR_UNCHANGED;
    if vkind(nv) == .ARGUMENT changed |= atr_manifest_attrs(irp_argument(nv), .[attr_enum(.Returned)]);
    uai := false;
    ok := true;
    for ri: atr_insts(i, .[.RET], *uai, *ok, true) {
        ro := op(ri, 0);
        if is_undef_value(ro) || ro == nv continue;
        if atr_is_valid_at_position(nv, ri) {
            if atr_change_use_after_manifest(op_use(ri, 0), nv) changed = ATR_CHANGED;
        }
    }
    return changed;
}

// mayBeInCycle
atr_may_be_in_cycle :: (ci: *Cycle_Info, x: Value_Id, header_only: bool, cptr: *Cycle_Id = null) -> bool {
    if !ci return true;
    bb := inst_block(x);
    c := ci_cycle_for(ci, bb);
    if c == NONE return false;
    if cptr cptr.* = c;
    return !header_only || bb == ci_header(ci, c);
}

// ---------------------------------------------------------------- AAPotentialConstantValues (PotentialConstantIntValuesState)

Pcv_Ext :: struct { set: [..] APInt; undef: bool; }
pcv_ext :: inline (i: u32) -> *Pcv_Ext { return cast(*Pcv_Ext) aa(i).x; }
pcv_construct :: (i: u32) { aa(i).x = New(Pcv_Ext); }

// a PotentialConstantIntValuesState value (for the clamping helpers and the update functions)
Pcv_State :: struct { bs: Bstate; set: [..] APInt; undef: bool; }
pcv_state_of :: (i: u32) -> Pcv_State {
    r: Pcv_State;
    r.set.allocator = temp;
    r.bs = aa(i).s;
    for pcv_ext(i).set array_add(*r.set, it);
    r.undef = pcv_ext(i).undef;
    return r;
}
pcv_best :: () -> Pcv_State { r: Pcv_State; r.set.allocator = temp; r.bs = bs_new(1); return r; }
pcv_contains :: (l: [] APInt, v: APInt) -> bool { for l if ap_eq(it, v) return true; return false; }
// checkAndInvalidate
pcv_check_and_invalidate :: (s: *Pcv_State) {
    if cast(u32) s.set.count >= atr_max_potential_values bs_pessimistic(*s.bs);
    else s.undef = s.undef && s.set.count == 0;
}
pcv_s_insert :: (s: *Pcv_State, v: APInt) {
    if !bs_is_valid(s.bs) return;
    if !pcv_contains(s.set, v) array_add(*s.set, v);
    pcv_check_and_invalidate(s);
}
pcv_s_union_with :: (s: *Pcv_State, r: Pcv_State) {
    if !bs_is_valid(s.bs) return;
    if !bs_is_valid(r.bs) { bs_pessimistic(*s.bs); return; }
    for r.set if !pcv_contains(s.set, it) array_add(*s.set, it);
    s.undef |= r.undef;
    pcv_check_and_invalidate(s);
}
pcv_s_union_undef :: (s: *Pcv_State) { s.undef = true; s.undef = s.undef && s.set.count == 0; }
// operator&= / operator^=
pcv_s_and :: (s: *Pcv_State, r: Pcv_State) { bs_join_and(*s.bs, r.bs); pcv_s_union_with(s, r); }
pcv_s_clamp :: (s: *Pcv_State, r: Pcv_State) { bs_clamp(*s.bs, r.bs); pcv_s_union_with(s, r); }
pcv_s_equal :: (a: Pcv_State, b: Pcv_State) -> bool {
    if bs_is_valid(a.bs) != bs_is_valid(b.bs) return false;
    if !bs_is_valid(a.bs) return true;
    if a.undef != b.undef return false;
    if a.set.count != b.set.count return false;
    for a.set if !ap_eq(it, b.set[it_index]) return false;
    return true;
}
pcv_store :: (i: u32, s: Pcv_State) {
    aa(i).s = s.bs;
    e := pcv_ext(i);
    e.set.count = 0;
    for s.set array_add(*e.set, ap_heap_copy(it));
    e.undef = s.undef;
}

// the AA's own state operations
pcv_insert :: (i: u32, v: APInt) { s := pcv_state_of(i); pcv_s_insert(*s, v); pcv_store(i, s); }
pcv_union_undef :: (i: u32) { s := pcv_state_of(i); pcv_s_union_undef(*s); pcv_store(i, s); }

// AAPotentialConstantValues::getAssumedConstant
pcv_get_assumed_constant :: (i: u32) -> Value_Id {
    if !aa_is_valid(i) return NONE;
    e := pcv_ext(i);
    ty := vtype(irp_assoc_value(aa(i).pos));
    if e.set.count == 1 return atr_get_with_type(const_int_ap(type_int(e.set[0].bits), e.set[0]), ty);
    if e.set.count == 0 {
        if e.undef return const_undef(ty);
        return OV_NOVAL;
    }
    return NONE;
}
// getAssumedMinTrailingZeros
pcv_assumed_min_trailing_zeros :: (i: u32) -> u32 {
    if !aa_is_valid(i) return 0;
    e := pcv_ext(i);
    if e.set.count == 0 return 0;
    tz := e.set[0].bits + 1;
    for e.set if ap_ctz(it) < tz tz = ap_ctz(it);
    if tz > e.set[0].bits return 0;
    return tz;
}

pcv_initialize :: (i: u32) {
    p := aa(i).pos;
    pk := aa(i).pk;
    if pk == .RETURNED {
        if !atr_is_ipo_amendable(irp_assoc_fn(p)) aa_pessimistic(i);
    }
    // AAPotentialConstantValuesImpl::initialize
    if atr_has_simplification_callback(p) { aa_pessimistic(i); return; }
    if pk != .FLOAT && pk != .CALL_SITE_ARGUMENT return;
    if aa_is_fix(i) return;
    v := irp_assoc_value(p);
    if vkind(v) == .C_INT { pcv_insert(i, const_ap(v)); aa_optimistic(i); return; }
    if is_undef_value(v) { pcv_union_undef(i); aa_optimistic(i); return; }
    if pk == .CALL_SITE_ARGUMENT return;
    if is_inst(v) {
        o := inst_op(v);
        if is_binary_op(o) || o == .ICMP || is_cast_op(o) return;
        if o == .SELECT || o == .PHI || o == .LOAD return;
    }
    aa_pessimistic(i);
}

// fillSetWithConstantValues
pcv_fill_set :: (i: u32, p: Irp, s: *[..] APInt, contains_undef: *bool, for_self: bool) -> bool {
    vals: [..] Vac; vals.allocator = temp;
    uai := false;
    if !atr_get_assumed_simplified_values(p, i, *vals, AA_INTER, *uai) {
        if for_self return false;
        if !is_int_type(irp_assoc_type(p)) return false;
        o := atr_get_aa(.POTENTIAL_CONSTANT_VALUES, p, i, DEP_REQUIRED);
        if o == NONE || !aa_is_valid(o) return false;
        contains_undef.* = pcv_ext(o).undef;
        s.count = 0;
        for pcv_ext(o).set array_add(s, it);
        return true;
    }
    contains_undef.* = false;
    for it: vals {
        if is_undef_value(it.v) { contains_undef.* = true; continue; }
        if vkind(it.v) != .C_INT return false;
        c := const_ap(it.v);
        if !pcv_contains(s.*, c) array_add(s, c);
    }
    contains_undef.* &= s.count == 0;
    return true;
}

pcv_calc_binop :: (o: Opcode, l: APInt, r: APInt) -> (APInt, bool, bool) {
    if o == {
        case .ADD; return ap_add(l, r), false, false;
        case .SUB; return ap_sub(l, r), false, false;
        case .MUL; return ap_mul(l, r), false, false;
        case .UDIV; if ap_is_zero(r) return l, true, false; return ap_udiv(l, r), false, false;
        case .SDIV; if ap_is_zero(r) return l, true, false; return ap_sdiv(l, r), false, false;
        case .UREM; if ap_is_zero(r) return l, true, false; return ap_urem(l, r), false, false;
        case .SREM; if ap_is_zero(r) return l, true, false; return ap_srem(l, r), false, false;
        case .SHL; return ap_shl_ap(l, r), false, false;
        case .LSHR; return ap_lshr_ap(l, r), false, false;
        case .ASHR; return ap_ashr_ap(l, r), false, false;
        case .AND; return ap_and(l, r), false, false;
        case .OR; return ap_or(l, r), false, false;
        case .XOR; return ap_xor(l, r), false, false;
    }
    return l, false, true;
}

pcv_update :: (i: u32) -> bool {
    pk := aa(i).pk;
    p := aa(i).pos;
    if pk == .ARGUMENT return aa_argument_from_call_site_arguments(i, .NONE_ATTR);
    if pk == .RETURNED return aa_returned_from_returned_values(i, .NONE_ATTR, true);
    if pk == .CALL_SITE_RETURNED return aa_callee_to_call_site(i, .NONE_ATTR);
    if pk == .FUNCTION || pk == .CALL_SITE return aa_pessimistic(i);
    if pk == .CALL_SITE_ARGUMENT {
        before := pcv_state_of(i);
        o := atr_get_aa(.POTENTIAL_CONSTANT_VALUES, irp_value(irp_assoc_value(p)), i, DEP_REQUIRED);
        if o == NONE return aa_pessimistic(i);
        s := pcv_state_of(i);
        pcv_s_union_with(*s, pcv_state_of(o));
        pcv_store(i, s);
        return !pcv_s_equal(before, pcv_state_of(i));
    }
    v := irp_assoc_value(p);
    if !is_inst(v) return aa_pessimistic(i);
    o := inst_op(v);
    before := pcv_state_of(i);
    s := pcv_state_of(i);
    if o == .ICMP {
        lhs := op(v, 0); rhs := op(v, 1);
        lu, ru := false, false;
        ls: [..] APInt; ls.allocator = temp;
        rs: [..] APInt; rs.allocator = temp;
        if !pcv_fill_set(i, irp_value(lhs), *ls, *lu, false) || !pcv_fill_set(i, irp_value(rhs), *rs, *ru, false) return aa_pessimistic(i);
        maybe_true, maybe_false := false, false;
        zero := ap_zero(type_bits(vtype(rhs)));
        pred := inst_pred(v);
        if lu && ru {
            pcv_s_union_undef(*s);
        } else if lu {
            for r: rs { c := icmp_compare(zero, r, pred); maybe_true |= c; maybe_false |= !c; if maybe_true && maybe_false return aa_pessimistic(i); }
        } else if ru {
            for l: ls { c := icmp_compare(l, zero, pred); maybe_true |= c; maybe_false |= !c; if maybe_true && maybe_false return aa_pessimistic(i); }
        } else {
            for l: ls for r: rs { c := icmp_compare(l, r, pred); maybe_true |= c; maybe_false |= !c; if maybe_true && maybe_false return aa_pessimistic(i); }
        }
        if maybe_true pcv_s_insert(*s, ap_from_u64(1, 1));
        if maybe_false pcv_s_insert(*s, ap_from_u64(1, 0));
    } else if o == .SELECT {
        lhs := op(v, 1); rhs := op(v, 2);
        uai := false;
        c := atr_get_assumed_constant_value(op(v, 0), i, *uai);
        only_left, only_right := false, false;
        if c != OV_NOVAL && c != NONE && is_one_value(c) only_left = true;
        else if c != OV_NOVAL && c != NONE && is_null_value(c) only_right = true;
        lu, ru := false, false;
        ls: [..] APInt; ls.allocator = temp;
        rs: [..] APInt; rs.allocator = temp;
        if !only_right && !pcv_fill_set(i, irp_value(lhs), *ls, *lu, false) return aa_pessimistic(i);
        if !only_left && !pcv_fill_set(i, irp_value(rhs), *rs, *ru, false) return aa_pessimistic(i);
        if only_left || only_right {
            l := ifx only_left then ls else rs;
            u := ifx only_left then lu else ru;
            if u pcv_s_union_undef(*s);
            else for l pcv_s_insert(*s, it);
        } else if lu && ru {
            pcv_s_union_undef(*s);
        } else {
            for ls pcv_s_insert(*s, it);
            for rs pcv_s_insert(*s, it);
        }
    } else if is_cast_op(o) {
        if !(o == .TRUNC || o == .ZEXT || o == .SEXT || (o == .BITCAST && is_int_type(vtype(v)) && is_int_type(vtype(op(v, 0))))) return aa_pessimistic(i);
        rbw := type_bits(vtype(v));
        su := false;
        ss: [..] APInt; ss.allocator = temp;
        if !pcv_fill_set(i, irp_value(op(v, 0)), *ss, *su, false) return aa_pessimistic(i);
        if su pcv_s_union_undef(*s);
        else for x: ss {
            t: APInt;
            if o == .TRUNC t = ap_trunc(x, rbw);
            else if o == .SEXT t = ap_sext(x, rbw);
            else if o == .ZEXT t = ap_zext(x, rbw);
            else t = x;
            pcv_s_insert(*s, t);
        }
    } else if is_binary_op(o) {
        lhs := op(v, 0); rhs := op(v, 1);
        lu, ru := false, false;
        ls: [..] APInt; ls.allocator = temp;
        rs: [..] APInt; rs.allocator = temp;
        if !pcv_fill_set(i, irp_value(lhs), *ls, *lu, false) || !pcv_fill_set(i, irp_value(rhs), *rs, *ru, false) return aa_pessimistic(i);
        zero := ap_zero(type_bits(vtype(lhs)));
        take :: (s: *Pcv_State, o: Opcode, l: APInt, r: APInt) -> bool {
            res, skip, unsupported := pcv_calc_binop(o, l, r);
            if unsupported return false;
            if !skip pcv_s_insert(s, res);
            return bs_is_valid(s.bs);
        }
        if lu && ru {
            if !take(*s, o, zero, zero) return aa_pessimistic(i);
        } else if lu {
            for r: rs if !take(*s, o, zero, r) return aa_pessimistic(i);
        } else if ru {
            for l: ls if !take(*s, o, l, zero) return aa_pessimistic(i);
        } else {
            for l: ls for r: rs if !take(*s, o, l, r) return aa_pessimistic(i);
        }
    } else if o == .PHI || o == .LOAD {
        u := false;
        inc: [..] APInt; inc.allocator = temp;
        if !pcv_fill_set(i, irp_value(v), *inc, *u, true) return aa_pessimistic(i);
        if u pcv_s_union_undef(*s);
        else for inc pcv_s_insert(*s, it);
    } else {
        return aa_pessimistic(i);
    }
    pcv_store(i, s);
    return !pcv_s_equal(before, pcv_state_of(i));
}

// ---------------------------------------------------------------- AAValueConstantRange (IntegerRangeState)

Vcr_Ext :: struct { bw: u32; known: Const_Range; assumed: Const_Range; num_changes: s32; }
vcr_ext :: inline (i: u32) -> *Vcr_Ext { return cast(*Vcr_Ext) aa(i).x; }
vcr_construct :: (i: u32) {
    e := New(Vcr_Ext);
    e.bw = type_bits(irp_assoc_type(aa(i).pos));
    e.known = cr_heap(cr_full(e.bw));
    e.assumed = cr_heap(cr_empty(e.bw));
    aa(i).x = e;
}
vcr_is_valid :: (i: u32) -> bool { e := vcr_ext(i); return e.bw > 0 && !cr_is_full_set(e.assumed); }
vcr_is_fix :: (i: u32) -> bool { e := vcr_ext(i); return cr_eq(e.assumed, e.known); }
vcr_optimistic :: (i: u32) { e := vcr_ext(i); e.known = e.assumed; }
vcr_pessimistic :: (i: u32) { e := vcr_ext(i); e.assumed = e.known; }
vcr_union_assumed :: (i: u32, r: Const_Range) { e := vcr_ext(i); e.assumed = cr_heap(cr_intersect(cr_union(e.assumed, r), e.known)); }
vcr_intersect_known :: (i: u32, r: Const_Range) {
    e := vcr_ext(i);
    e.assumed = cr_heap(cr_intersect(e.assumed, r));
    e.known = cr_heap(cr_intersect(e.known, r));
}

// a range state value for the clamping helpers
Vcr_State :: struct { bw: u32; known: Const_Range; assumed: Const_Range; }
vcr_state_of :: (i: u32) -> Vcr_State { e := vcr_ext(i); return .{e.bw, e.known, e.assumed}; }
vcr_best :: (bw: u32) -> Vcr_State { return .{bw, cr_full(bw), cr_empty(bw)}; }
vcr_s_is_valid :: (s: Vcr_State) -> bool { return s.bw > 0 && !cr_is_full_set(s.assumed); }
vcr_s_union_assumed :: (s: *Vcr_State, r: Const_Range) { s.assumed = cr_intersect(cr_union(s.assumed, r), s.known); }
vcr_s_and :: (s: *Vcr_State, r: Vcr_State) { s.known = cr_union(s.known, r.known); s.assumed = cr_union(s.assumed, r.assumed); }
vcr_s_pessimistic :: (s: *Vcr_State) { s.assumed = s.known; }

// getConstantRangeFromSCEV
vcr_range_from_scev :: (i: u32, ctx: Value_Id) -> Const_Range {
    e := vcr_ext(i);
    f := irp_anchor_scope(aa(i).pos);
    if f == NONE return cr_full(e.bw);
    s := atr_se(f);
    li := atr_li(f);
    if !s || !li return cr_full(e.bw);
    old := se_current_swap(s);
    defer se_current_swap(old);
    sv := sc_get_scev(irp_assoc_value(aa(i).pos));
    if ctx != NONE sv = sc_get_scev_at_scope(sv, li_loop_for(li, inst_block(ctx)));
    return sc_unsigned_range(sv);
}
// getConstantRangeFromLVI
vcr_range_from_lvi :: (i: u32, ctx: Value_Id) -> Const_Range {
    e := vcr_ext(i);
    f := irp_anchor_scope(aa(i).pos);
    if f == NONE return cr_full(e.bw);
    lvi := atr_lvi(f);
    if !lvi || ctx == NONE return cr_full(e.bw);
    return lvi_get_constant_range(lvi, irp_assoc_value(aa(i).pos), ctx, false);
}
// isValidCtxInstructionForOutsideAnalysis
vcr_valid_ctx_for_outside_analysis :: (i: u32, ctx: Value_Id, allow_aa_ctx: bool) -> bool {
    if ctx == NONE || (!allow_aa_ctx && ctx == irp_ctx_i(aa(i).pos)) return false;
    v := irp_assoc_value(aa(i).pos);
    if !atr_is_valid_in_scope(v, inst_fn(ctx)) return false;
    if is_inst(v) {
        dt := atr_dt(inst_fn(v));
        return dt != null && dt_dominates_inst(dt, v, ctx);
    }
    return true;
}
vcr_get_known_range :: (i: u32, ctx: Value_Id) -> Const_Range {
    if !vcr_valid_ctx_for_outside_analysis(i, ctx, false) return vcr_ext(i).known;
    lr := vcr_range_from_lvi(i, ctx);
    sr := vcr_range_from_scev(i, ctx);
    return cr_intersect(cr_intersect(vcr_ext(i).known, sr), lr);
}
vcr_get_assumed_range :: (i: u32, ctx: Value_Id) -> Const_Range {
    if !vcr_valid_ctx_for_outside_analysis(i, ctx, false) return vcr_ext(i).assumed;
    lr := vcr_range_from_lvi(i, ctx);
    sr := vcr_range_from_scev(i, ctx);
    return cr_intersect(cr_intersect(vcr_ext(i).assumed, sr), lr);
}
// AAValueConstantRange::getAssumedConstant
vcr_get_assumed_constant :: (i: u32, ctx: Value_Id) -> Value_Id {
    r := vcr_get_assumed_range(i, ctx);
    ok, c := cr_single_element(r);
    if ok {
        ty := vtype(irp_assoc_value(aa(i).pos));
        return atr_get_with_type(const_int_ap(type_int(c.bits), c), ty);
    }
    if cr_is_empty_set(r) return OV_NOVAL;
    return NONE;
}

vcr_initialize :: (i: u32) {
    p := aa(i).pos;
    pk := aa(i).pk;
    if pk == .RETURNED {
        if !atr_is_ipo_amendable(irp_assoc_fn(p)) aa_pessimistic(i);
        return;
    }
    if pk == .CALL_SITE_RETURNED {
        cb := irp_assoc_value(p);
        if inst_op(cb) == .CALL {
            ok, r := call_range(cb);
            if ok vcr_intersect_known(i, r);
        }
    }
    // AAValueConstantRangeImpl::initialize
    if atr_has_simplification_callback(p) { aa_pessimistic(i); return; }
    ctx := irp_ctx_i(p);
    vcr_intersect_known(i, vcr_range_from_scev(i, ctx));
    vcr_intersect_known(i, vcr_range_from_lvi(i, ctx));
    if pk != .FLOAT && pk != .CALL_SITE_ARGUMENT return;
    // AAValueConstantRangeFloating::initialize
    if aa_is_fix(i) return;
    v := irp_assoc_value(p);
    if vkind(v) == .C_INT { vcr_union_assumed(i, cr_single(const_ap(v))); aa_optimistic(i); return; }
    if is_undef_value(v) { vcr_union_assumed(i, cr_single(ap_zero(vcr_ext(i).bw))); aa_optimistic(i); return; }
    if irp_is_call(v) return;
    if is_inst(v) {
        o := inst_op(v);
        if is_binary_op(o) || o == .ICMP || o == .FCMP || is_cast_op(o) return;
        if o == .LOAD {
            md := inst_md(v, "range");
            if md != NONE { vcr_intersect_known(i, cr_from_range_md(md)); return; }
        }
        if o == .SELECT || o == .PHI return;
    }
    aa_pessimistic(i);
}

vcr_simplified_operand :: (i: u32, v: Value_Id) -> (bool, Value_Id) {
    uai := false;
    sv := atr_get_assumed_simplified_value(v, i, *uai, AA_INTER);
    if sv == OV_NOVAL return true, OV_NOVAL;
    if sv == NONE return false, NONE;
    return true, sv;
}

// AAValueConstantRangeFloating::updateImpl
vcr_floating_update :: (i: u32) -> bool {
    p := aa(i).pos;
    e := vcr_ext(i);
    t := vcr_best(e.bw);
    v := irp_assoc_value(p);
    ctx := irp_ctx_i(p);
    queried: [..] u32; queried.allocator = temp;
    ok := true;
    if !is_inst(v) || is_call_base(v) {
        cont, sv := vcr_simplified_operand(i, v);
        if !cont ok = false;
        else if sv != OV_NOVAL {
            o := atr_get_aa(.VALUE_CONSTANT_RANGE, irp_value(sv), i, DEP_REQUIRED);
            if o != NONE { vcr_s_union_assumed(*t, vcr_get_assumed_range(o, ctx)); ok = vcr_s_is_valid(t); }
            else ok = false;
        }
    } else {
        o := inst_op(v);
        if is_binary_op(o) {
            ok = vcr_calc_binop(i, v, *t, ctx, *queried);
        } else if o == .ICMP || o == .FCMP {
            ok = vcr_calc_cmp(i, v, *t, ctx, *queried);
        } else if is_cast_op(o) {
            ok = vcr_calc_cast(i, v, *t, ctx, *queried);
        } else {
            vcr_s_pessimistic(*t);
            ok = false;
        }
        if ok {
            for q: queried {
                if q != i continue;
                if cr_eq(t.assumed, e.assumed) continue;
                vcr_s_pessimistic(*t);
            }
            ok = vcr_s_is_valid(t);
        }
    }
    if !ok return aa_pessimistic(i);
    before := e.assumed;
    vcr_union_assumed(i, t.assumed);
    if cr_eq(before, e.assumed) return ATR_UNCHANGED;
    e.num_changes += 1;
    if e.num_changes > 5 return aa_pessimistic(i);
    return ATR_CHANGED;
}
vcr_calc_binop :: (i: u32, bo: Value_Id, t: *Vcr_State, ctx: Value_Id, queried: *[..] u32) -> bool {
    c1, lhs := vcr_simplified_operand(i, op(bo, 0));
    if !c1 return false;
    if lhs == OV_NOVAL return true;
    c2, rhs := vcr_simplified_operand(i, op(bo, 1));
    if !c2 return false;
    if rhs == OV_NOVAL return true;
    if !is_int_type(vtype(lhs)) || !is_int_type(vtype(rhs)) return false;
    la := atr_get_aa(.VALUE_CONSTANT_RANGE, irp_value(lhs), i, DEP_REQUIRED);
    if la == NONE return false;
    array_add(queried, la);
    lr := vcr_get_assumed_range(la, ctx);
    ra := atr_get_aa(.VALUE_CONSTANT_RANGE, irp_value(rhs), i, DEP_REQUIRED);
    if ra == NONE return false;
    array_add(queried, ra);
    rr := vcr_get_assumed_range(ra, ctx);
    vcr_s_union_assumed(t, cr_binary_op(lr, inst_op(bo), rr));
    return vcr_s_is_valid(t.*);
}
vcr_calc_cast :: (i: u32, ci: Value_Id, t: *Vcr_State, ctx: Value_Id, queried: *[..] u32) -> bool {
    c1, ov := vcr_simplified_operand(i, op(ci, 0));
    if !c1 return false;
    if ov == OV_NOVAL return true;
    if !is_int_type(vtype(ov)) return false;
    oa := atr_get_aa(.VALUE_CONSTANT_RANGE, irp_value(ov), i, DEP_REQUIRED);
    if oa == NONE return false;
    array_add(queried, oa);
    vcr_s_union_assumed(t, cr_cast_op(vcr_ext(oa).assumed, inst_op(ci), vcr_ext(i).bw));
    return vcr_s_is_valid(t.*);
}
vcr_calc_cmp :: (i: u32, cmp: Value_Id, t: *Vcr_State, ctx: Value_Id, queried: *[..] u32) -> bool {
    c1, lhs := vcr_simplified_operand(i, op(cmp, 0));
    if !c1 return false;
    if lhs == OV_NOVAL return true;
    c2, rhs := vcr_simplified_operand(i, op(cmp, 1));
    if !c2 return false;
    if rhs == OV_NOVAL return true;
    if !is_int_type(vtype(lhs)) || !is_int_type(vtype(rhs)) return false;
    la := atr_get_aa(.VALUE_CONSTANT_RANGE, irp_value(lhs), i, DEP_REQUIRED);
    if la == NONE return false;
    array_add(queried, la);
    ra := atr_get_aa(.VALUE_CONSTANT_RANGE, irp_value(rhs), i, DEP_REQUIRED);
    if ra == NONE return false;
    array_add(queried, ra);
    lr := vcr_get_assumed_range(la, ctx);
    rr := vcr_get_assumed_range(ra, ctx);
    if cr_is_empty_set(lr) || cr_is_empty_set(rr) return true;
    pred := inst_pred(cmp);
    must_true, must_false := false, false;
    allowed := cr_allowed_icmp_region(pred, rr);
    if cr_is_empty_set(cr_intersect(allowed, lr)) must_false = true;
    if cr_icmp(lr, pred, rr) must_true = true;
    if must_true vcr_s_union_assumed(t, cr_single(ap_from_u64(1, 1)));
    else if must_false vcr_s_union_assumed(t, cr_single(ap_from_u64(1, 0)));
    else vcr_s_union_assumed(t, cr_full(1));
    return vcr_s_is_valid(t.*);
}

vcr_update :: (i: u32) -> bool {
    pk := aa(i).pk;
    if pk == .ARGUMENT return aa_argument_from_call_site_arguments(i, .NONE_ATTR);
    if pk == .RETURNED return aa_returned_from_returned_values(i, .NONE_ATTR, true);
    if pk == .CALL_SITE_RETURNED return aa_callee_to_call_site(i, .NONE_ATTR);
    if pk == .FUNCTION || pk == .CALL_SITE fatal("internal: attributor: AAValueConstantRange(Function|CallSite)::updateImpl");
    return vcr_floating_update(i);
}

// isBetterRange
vcr_is_better_range :: (assumed: Const_Range, x: Value_Id) -> bool {
    if cr_is_full_set(assumed) return false;
    have := false;
    known: Const_Range;
    if is_call_base(x) {
        have, known = call_range(x);
    } else {
        md := inst_md(x, "range");
        if md != NONE {
            if md_nops(md) > 2 return false;
            have = true;
            known = cr_from_range_md(md);
        }
    }
    return !have || (!cr_eq(known, assumed) && cr_contains_range(known, assumed));
}
vcr_manifest :: (i: u32) -> bool {
    pk := aa(i).pk;
    if pk == .CALL_SITE_ARGUMENT return ATR_UNCHANGED;
    changed := ATR_UNCHANGED;
    r := vcr_get_assumed_range(i, NONE);
    v := irp_assoc_value(aa(i).pos);
    if !cr_is_empty_set(r) && !cr_is_single_element(r) && is_inst(v) {
        if inst_op(v) == .LOAD && vcr_is_better_range(r, v) {
            set_range_metadata(v, r);
            changed = ATR_CHANGED;
        }
        if inst_op(v) == .CALL && vcr_is_better_range(r, v) {
            atr_manifest_attrs(aa(i).pos, .[attr_from_range(r)], true);
            changed = ATR_CHANGED;
        }
    }
    return changed;
}
// I->setMetadata(MD_range, {lo, hi})
set_range_metadata :: (x: Value_Id, r: Const_Range) {
    ty := vtype(x);
    lo := md_value(const_int_ap(ty, r.lo));
    hi := md_value(const_int_ap(ty, r.hi));
    set_metadata(x, md_kind_id("range"), md_tuple(.[lo, hi], false));
}

// ---------------------------------------------------------------- generic clamping

// the state of an AA as a value of its StateType (for clampReturnedValueStates / clampCallSiteArgumentStates)
Gstate :: struct { kind: Atr_Kind; s: Bstate; g: Bstate; vcr: Vcr_State; pcv: Pcv_State; }
gs_of :: (i: u32) -> Gstate {
    r: Gstate;
    r.kind = aa(i).kind;
    r.s = aa(i).s;
    r.g = aa(i).g;
    if r.kind == .VALUE_CONSTANT_RANGE r.vcr = vcr_state_of(i);
    if r.kind == .POTENTIAL_CONSTANT_VALUES r.pcv = pcv_state_of(i);
    return r;
}
gs_best :: (like: Gstate) -> Gstate {
    r := like;
    r.s = bs_best_of(like.s);
    r.g = bs_best_of(like.g);
    if like.kind == .VALUE_CONSTANT_RANGE r.vcr = vcr_best(like.vcr.bw);
    if like.kind == .POTENTIAL_CONSTANT_VALUES r.pcv = pcv_best();
    return r;
}
gs_is_valid :: (t: Gstate) -> bool {
    if t.kind == .VALUE_CONSTANT_RANGE return vcr_s_is_valid(t.vcr);
    if t.kind == .POTENTIAL_CONSTANT_VALUES return bs_is_valid(t.pcv.bs);
    return bs_is_valid(t.s);
}
gs_pessimistic :: (t: *Gstate) {
    if t.kind == .VALUE_CONSTANT_RANGE { vcr_s_pessimistic(*t.vcr); return; }
    if t.kind == .POTENTIAL_CONSTANT_VALUES { bs_pessimistic(*t.pcv.bs); return; }
    bs_pessimistic(*t.s);
    if t.kind == .DEREFERENCEABLE bs_pessimistic(*t.g);
}
// operator&=
gs_and :: (t: *Gstate, r: Gstate) {
    if t.kind == .VALUE_CONSTANT_RANGE { vcr_s_and(*t.vcr, r.vcr); return; }
    if t.kind == .POTENTIAL_CONSTANT_VALUES { pcv_s_and(*t.pcv, r.pcv); return; }
    bs_join_and(*t.s, r.s);
    if t.kind == .DEREFERENCEABLE bs_join_and(*t.g, r.g);
}
// operator^=
gs_clamp :: (t: *Gstate, r: Gstate) {
    if t.kind == .VALUE_CONSTANT_RANGE { vcr_s_union_assumed(*t.vcr, r.vcr.assumed); return; }
    if t.kind == .POTENTIAL_CONSTANT_VALUES { pcv_s_clamp(*t.pcv, r.pcv); return; }
    bs_clamp(*t.s, r.s);
    if t.kind == .DEREFERENCEABLE bs_clamp(*t.g, r.g);
}
// clampStateAndIndicateChange(getState(), R)
aa_clamp_state_and_indicate :: (i: u32, r: Gstate) -> bool {
    k := aa(i).kind;
    if k == .VALUE_CONSTANT_RANGE {
        if r.vcr.bw != vcr_ext(i).bw {
            // a call whose callee returns another type (LLVM mixes the bit widths in a release build; the full
            // range of the callee makes the state invalid): give up
            if cr_is_full_set(r.vcr.assumed) { vcr_pessimistic(i); return ATR_CHANGED; }
            fatal("attributor: value ranges of different bit widths are not supported");
        }
        before := vcr_ext(i).assumed;
        vcr_union_assumed(i, r.vcr.assumed);
        return !cr_eq(before, vcr_ext(i).assumed);
    }
    if k == .POTENTIAL_CONSTANT_VALUES {
        before := pcv_state_of(i);
        s := pcv_state_of(i);
        pcv_s_clamp(*s, r.pcv);
        pcv_store(i, s);
        return !pcv_s_equal(before, pcv_state_of(i));
    }
    c := bs_clamp_and_indicate(*aa(i).s, r.s);
    if k == .DEREFERENCEABLE c |= bs_clamp_and_indicate(*aa(i).g, r.g);
    return c;
}

// AAReturnedFromReturnedValues with clampReturnedValueStates; `ak` is the IR attribute kind (NONE_ATTR: clamp states)
aa_returned_from_returned_values :: (i: u32, ak: Attr_Kind, recurse: bool) -> bool {
    s := gs_best(gs_of(i));
    t: Gstate;
    have_t := false;
    failed := false;
    f := irp_assoc_fn(aa(i).pos);
    vals: [..] Vac; vals.allocator = temp;
    uai := false;
    if f == NONE || !atr_get_assumed_simplified_values(irp_returned(f), i, *vals, AA_INTRA, *uai, recurse) {
        failed = true;
    } else {
        for vals {
            rp := irp_value(it.v);
            if ak != .NONE_ATTR {
                has, _ := atr_has_assumed_ir_attr(ak, i, rp, DEP_REQUIRED);
                if !has { failed = true; break; }
                continue;
            }
            o := atr_get_aa(aa(i).kind, rp, i, DEP_REQUIRED);
            if o == NONE { failed = true; break; }
            if !have_t { t = gs_best(gs_of(o)); have_t = true; }
            gs_and(*t, gs_of(o));
            if !gs_is_valid(t) { failed = true; break; }
        }
    }
    if failed gs_pessimistic(*s);
    else if have_t gs_clamp(*s, t);
    return aa_clamp_state_and_indicate(i, s);
}

// AAArgumentFromCallSiteArguments with clampCallSiteArgumentStates
aa_argument_from_call_site_arguments :: (i: u32, ak: Attr_Kind) -> bool {
    p := aa(i).pos;
    kind := aa(i).kind;
    s := gs_best(gs_of(i));
    t: Gstate;
    have_t := false;
    argno := cast(u32) irp_cs_arg_no(p);
    uai := false;
    ok := true;
    for cb: atr_call_sites(i, true, *uai, *ok) {
        cpos := irp_acs_argument(acs, argno);
        if irp_kind(cpos) == .INVALID { ok = false; break; }
        if ak != .NONE_ATTR {
            has, _ := atr_has_assumed_ir_attr(ak, i, cpos, DEP_REQUIRED);
            if !has { ok = false; break; }
            continue;
        }
        o := atr_get_aa(kind, cpos, i, DEP_REQUIRED);
        if o == NONE { ok = false; break; }
        if !have_t { t = gs_best(gs_of(o)); have_t = true; }
        gs_and(*t, gs_of(o));
        if !gs_is_valid(t) { ok = false; break; }
    }
    if !ok gs_pessimistic(*s);
    else if have_t gs_clamp(*s, t);
    return aa_clamp_state_and_indicate(i, s);
}

// AACalleeToCallSite::updateImpl; `ak` is the IR attribute kind (NONE_ATTR: clamp states)
aa_callee_to_call_site :: (i: u32, ak: Attr_Kind) -> bool {
    p := aa(i).pos;
    pk := aa(i).pk;
    kind := aa(i).kind;
    cb := irp_anchor(p);
    ok, callees := atr_callees(i, cb);
    if !ok return aa_pessimistic(i);
    changed := ATR_UNCHANGED;
    for callee: callees {
        fpos := ifx pk == .CALL_SITE_RETURNED then irp_returned(callee) else irp_function(callee);
        if ak != .NONE_ATTR {
            has, _ := atr_has_assumed_ir_attr(ak, i, fpos, DEP_REQUIRED);
            if !has return aa_pessimistic(i);
            continue;
        }
        o := atr_get_aa(kind, fpos, i, DEP_REQUIRED);
        if o == NONE return aa_pessimistic(i);
        changed |= aa_clamp_state_and_indicate(i, gs_of(o));
        if aa_is_fix(i) {
            if aa_is_valid(i) return changed;
            return aa_pessimistic(i);
        }
    }
    return changed;
}
