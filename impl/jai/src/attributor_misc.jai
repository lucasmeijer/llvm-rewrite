// The value AAs of llvm/lib/Transforms/IPO/AttributorAttributes.cpp that are not AttributorLight's: AANoAlias,
// AADereferenceable, AAAlign, AANoUndef, AAInstanceInfo, AAAssumptionInfo, AAGlobalValueInfo, AAIndirectCallInfo,
// AAInvariantLoadPointer, AAAddressSpace, AANoAliasAddrSpace, AAAllocationInfo and AANonConvergent, with the
// stripAndAccumulateOffsets / getMinimalBaseOfPointer helpers (Value::stripAndAccumulateConstantOffsets and
// GEPOperator::accumulateConstantOffset with an ExternalAnalysis, from llvm/lib/IR/Value.cpp and Operator.cpp).

// ---------------------------------------------------------------- stripAndAccumulateOffsets

// the AttributorAnalysis external analysis: the AAValueConstantRange of a GEP index
atr_offset_analysis :: (q: u32, v: Value_Id, use_assumed: bool, get_min: bool) -> (bool, APInt) {
    o := atr_get_aa(.VALUE_CONSTANT_RANGE, irp_value(v), q, ifx use_assumed then DEP_OPTIONAL else DEP_NONE);
    none: APInt;
    if o == NONE return false, none;
    r := ifx use_assumed then vcr_ext(o).assumed else vcr_ext(o).known;
    if cr_is_full_set(r) return false, none;
    if get_min return true, cr_smin(r);
    return true, cr_smax(r);
}
// GEPOperator::accumulateConstantOffset(DL, Offset, ExternalAnalysis)
atr_gep_accumulate_offset :: (q: u32, g: Value_Id, offset_in: APInt, use_assumed: bool, get_min: bool) -> (bool, APInt) {
    offset := offset_in;
    used_external := false;
    accumulate :: (offset: *APInt, index: APInt, size: u64, used_external: bool) -> bool {
        idx := ap_sext_or_trunc(index, offset.bits);
        sz := ap_from_u64(offset.bits, size);
        if !used_external { offset.* = ap_add(offset.*, ap_mul(idx, sz)); return true; }
        plus, ov := ap_smul_ov(idx, sz);
        if ov return false;
        r, ov2 := ap_sadd_ov(offset.*, plus);
        if ov2 return false;
        offset.* = r;
        return true;
    }
    cur := opr_gep_source_type(g);
    n := nops(g);
    for k: 1..cast(s64) n - 1 {
        index := op(g, cast(u32) k);
        is_struct := k > 1 && type_kind(cur) == .STRUCT;
        indexed := gep_indexed_type(cur, k, index);
        defer cur = indexed;
        scalable := type_is_scalable(indexed);
        if vkind(index) == .C_INT && is_int_type(vtype(index)) {
            ci := const_ap(index);
            if ap_is_zero(ci) continue;
            if scalable return false, offset;
            if is_struct {
                if !accumulate(*offset, ap_from_u64(offset.bits, dl_struct_offset(cur, cast(u32) ap_zext_value(ci))), 1, used_external) return false, offset;
                continue;
            }
            if !accumulate(*offset, ci, gep_seq_stride(cur, k, indexed), used_external) return false, offset;
            continue;
        }
        if is_struct || scalable return false, offset;
        ok, ai := atr_offset_analysis(q, index, use_assumed, get_min);
        if !ok return false, offset;
        used_external = true;
        if !accumulate(*offset, ai, gep_seq_stride(cur, k, indexed), used_external) return false, offset;
    }
    return true, offset;
}
// stripAndAccumulateOffsets: Value::stripAndAccumulateConstantOffsets(DL, Offset, AllowNonInbounds,
// AllowInvariant = true, AttributorAnalysis)
atr_strip_and_accumulate_offsets :: (q: u32, v_in: Value_Id, offset_in: APInt, get_min: bool, allow_non_inbounds: bool, use_assumed := false) -> (Value_Id, APInt) {
    v := v_in; offset := offset_in;
    if !is_ptr_type(scalar_type(vtype(v))) return v, offset;
    bw := offset.bits;
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*visited, v);
    while true {
        o := opr_code(v);
        if o == .GEP {
            if !allow_non_inbounds && (opr_flags(v) & F_INBOUNDS) == 0 return v, offset;
            ok, go := atr_gep_accumulate_offset(q, v, ap_zero(dl_index_bits(vtype(v))), use_assumed, get_min);
            if !ok return v, offset;
            if ap_min_signed_bits(go) > bw return v, offset;
            st := ap_sext_or_trunc(go, bw);
            r, ov := ap_sadd_ov(offset, st);
            if ov return v, offset;
            offset = r;
            v = op(v, 0);
        } else if o == .BITCAST {
            s := op(v, 0);
            if !is_ptr_type(scalar_type(vtype(s))) return v, offset;
            v = s;
        } else if o == .ADDRSPACECAST {
            v = op(v, 0);
        } else if vkind(v) == .ALIAS {
            if !gv_is_interposable(v) v = op(v, 0);
        } else if is_inst(v) && is_call_base(v) {
            rv := call_returned_arg(v);
            if rv != NONE v = rv;
            id := call_iid(v);
            if is_inst(v) && is_call_base(v) && (id == IID_LAUNDER_INVARIANT_GROUP || id == IID_STRIP_INVARIANT_GROUP) v = op(v, 0);
        } else return v, offset;
        for visited if it == v return v, offset;
        array_add(*visited, v);
    }
    return v, offset;
}
// getMinimalBaseOfPointer
atr_minimal_base_of_pointer :: (q: u32, ptr: Value_Id, allow_non_inbounds := false) -> (Value_Id, s64) {
    off := ap_zero(dl_index_type_size_bits(vtype(ptr)));
    base, o := atr_strip_and_accumulate_offsets(q, ptr, off, true, allow_non_inbounds);
    return base, ap_sext_value(o);
}

// ---------------------------------------------------------------- followUsesInMBEC

// the StateType of the AAs that follow uses (BooleanState, IncIntegerState, BitIntegerState, DerefState); the
// fields point at the AA's own state (followUsesInMBEC works on getState()) or at a branch's local state
Mbec_State :: struct { s: *Bstate; g: *Bstate; accessed: *[..] [2] s64; }
mbec_state_of :: (i: u32) -> Mbec_State {
    r: Mbec_State;
    r.s = *aa(i).s; r.g = *aa(i).g;
    if aa(i).kind == .DEREFERENCEABLE r.accessed = *deref_ext(i).accessed;
    else { r.accessed = New([..] [2] s64,, allocator = temp); r.accessed.allocator = temp; }
    return r;
}

// DerefState::computeKnownDerefBytesFromAccessedMap / addAccessedBytes / takeKnownDerefBytesMaximum
deref_compute_known_from_map :: (s: *Bstate, m: *[..] [2] s64) {
    kb := cast(s64) s.known;
    for m.* {
        if kb < it[0] break;
        kb = max(kb, it[0] + it[1]);
    }
    bs_take_known_max(s, (cast,no_check(u64) kb) & 0xFFFF_FFFF);
}
deref_add_accessed_bytes :: (s: *Bstate, m: *[..] [2] s64, off: s64, size: u64) {
    pos := 0;
    while pos < m.count && m.*[pos][0] < off pos += 1;
    if pos < m.count && m.*[pos][0] == off { m.*[pos][1] = max(m.*[pos][1], cast(s64) size); }
    else array_insert_at(m, .[off, cast(s64) size], pos);
    deref_compute_known_from_map(s, m);
}
deref_take_known_max :: (s: *Bstate, m: *[..] [2] s64, b: u64) { bs_take_known_max(s, b & 0xFFFF_FFFF); deref_compute_known_from_map(s, m); }

// followUsesInMBEC
aa_follow_uses_in_mbec :: (i: u32, ctx: Value_Id, st: *Mbec_State) {
    v := irp_assoc_value(aa(i).pos);
    if is_constant_data(v) return;
    uses: Use_Set;
    uses.list.allocator = temp; uses.member.allocator = temp;
    u := ir.v_first_use[v];
    while u != NONE { uset_insert(*uses, u); u = ir.u_next[u]; }
    aa_follow_uses_in_context(i, ctx, *uses, st);
    fix := ifx aa(i).kind == .DEREFERENCEABLE then (!bs_is_valid(st.s.*) || (bs_is_fix(st.s.*) && bs_is_fix(st.g.*))) else bs_is_fix(st.s.*);
    if fix return;
    brs: [..] Value_Id; brs.allocator = temp;
    it := mbe_begin(ctx);
    while !mbe_at_end(*it) {
        if inst_op(it.cur) == .CONDBR array_add(*brs, it.cur);
        mbe_advance(*it);
    }
    for br: brs {
        ps := bs_best_of(st.s.*); pg := bs_best_of(st.g.*);
        bs_optimistic(*ps);
        bs_optimistic(*pg);
        for k: 0..cast(s64) num_successors(br) - 1 {
            bb := get_successor(br, cast(u32) k);
            cs := bs_best_of(st.s.*); cg := bs_best_of(st.g.*);
            cacc: [..] [2] s64; cacc.allocator = temp;
            child := Mbec_State.{*cs, *cg, *cacc};
            before := uses.list.count;
            aa_follow_uses_in_context(i, block_first(bb), *uses, *child);
            for x: before..uses.list.count - 1 table_remove(*uses.member, uses.list[x]);
            uses.list.count = before;
            bs_join_and(*ps, cs);
            bs_join_and(*pg, cg);
        }
        bs_add_known_of(st.s, ps);
        bs_add_known_of(st.g, pg);
    }
}
// followUsesInContext
aa_follow_uses_in_context :: (i: u32, ctx: Value_Id, uses: *Use_Set, st: *Mbec_State) {
    it := mbe_begin(ctx);
    u := 0;
    while u < uses.list.count {
        cu := uses.list[u];
        u += 1;
        user := ir.u_user[cu];
        if !is_inst(user) continue;
        found := mbe_find_in_context_of(user, *it);
        if found && aa_follow_use_in_mbec(i, cu, user, st) {
            x := ir.v_first_use[user];
            while x != NONE { uset_insert(uses, x); x = ir.u_next[x]; }
        }
    }
}
Use_Set :: struct { list: [..] Use_Id; member: Table(Use_Id, bool); }
uset_insert :: (s: *Use_Set, u: Use_Id) { if table_contains(*s.member, u) return; table_set(*s.member, u, true); array_add(*s.list, u); }

// the followUseInMBEC of each AA
aa_follow_use_in_mbec :: (i: u32, u: Use_Id, user: Value_Id, st: *Mbec_State) -> bool {
    k := aa(i).kind;
    av := irp_assoc_value(aa(i).pos);
    if k == {
        case .NON_NULL;
            _, non_null, track := nn_known_non_null_and_deref_bytes_for_use(i, av, u, user);
            bs_set_known(st.s, non_null);
            return track;
        case .DEREFERENCEABLE;
            deref, _, track := nn_known_non_null_and_deref_bytes_for_use(i, av, u, user);
            deref_add_accessed_bytes_for_use(i, u, user, st);
            deref_take_known_max(st.s, st.accessed, cast(u64) deref);
            return track;
        case .ALIGN;
            ka, track := align_known_for_use(i, av, u, user);
            bs_take_known_max(st.s, ka);
            return track;
        case .NO_UNDEF;
            f := irp_anchor_scope(aa(i).pos);
            dt: *Dom_Tree = null;
            ac: *Assumption_Cache = null;
            if f != NONE { dt = atr_dt(f); ac = atr_ac(f); }
            bs_set_known(st.s, is_guaranteed_not_to_be_undef_or_poison(ir.u_val[u], ac, user, dt));
            o := inst_op(user);
            return is_cast_op(o) || o == .GEP;
        case .NO_FPCLASS;
            if !is_call_base(user) || !call_is_arg_operand(user, u) return false;
            o := atr_get_aa(.NO_FPCLASS, irp_cs_argument(user, use_arg_no(u)), i, DEP_NONE);
            if o != NONE bs_add_known(st.s, aa(o).s.known);
            return false;
    }
    fatal("internal: attributor: followUseInMBEC for %", aa_kind_name(k));
    return false;
}
// write a followed state back into the AA

// getKnownNonNullAndDerefBytesForUse: (deref bytes, IsNonNull, TrackUse)
nn_known_non_null_and_deref_bytes_for_use :: (q: u32, assoc: Value_Id, u: Use_Id, i: Value_Id) -> (s64, bool, bool) {
    use_v := ir.u_val[u];
    if !is_ptr_type(vtype(use_v)) return 0, false, false;
    o := inst_op(i);
    if is_cast_op(o) || o == .GEP return 0, false, true;
    npid := null_pointer_is_defined(inst_fn(i), ptr_addrspace(vtype(use_v)));
    if is_call_base(i) {
        if call_is_bundle_operand(i, u) {
            found, kind, arg := atr_knowledge_from_use(u);
            if found return cast(s64) arg, kind == .NonNull || !npid, false;
            return 0, false, false;
        }
        if call_is_callee_use(i, u) return 0, !npid, false;
        cpos := irp_cs_argument(i, use_arg_no(u));
        _, known := atr_has_assumed_ir_attr(.NonNull, q, cpos, DEP_NONE);
        d := atr_get_aa(.DEREFERENCEABLE, cpos, q, DEP_NONE);
        return ifx d != NONE then cast(s64) aa(d).s.known else 0, known, false;
    }
    ok, loc := mloc_get_or_none(i);
    if !ok || loc.ptr != use_v || !ls_has_value(loc.size) || !ls_is_precise(loc.size) || ls_is_scalable(loc.size) || is_volatile(i)
        return 0, false, false;
    base, offset := atr_minimal_base_of_pointer(q, loc.ptr);
    if base != NONE && base == assoc {
        deref := cast(s64) ls_value(loc.size) + offset;
        return max(0, deref), !npid, false;
    }
    base2, off2 := get_pointer_base_with_constant_offset(loc.ptr);
    if base2 != NONE && base2 == assoc && off2 == 0 return cast(s64) ls_value(loc.size), !npid, false;
    return 0, false, false;
}

// ---------------------------------------------------------------- AANoAlias

// AANoAlias::isImpliedByIR
aa_no_alias_implied_by_ir :: (p: Irp, ign_in: bool) -> bool {
    ign := ign_in;
    v := irp_assoc_value(p);
    if irp_kind(p) != .CALL_SITE_ARGUMENT {
        if is_inst(v) && inst_op(v) == .ALLOCA return true;
    } else {
        ign = true;
    }
    k := vkind(v);
    if k == .C_UNDEF || k == .C_POISON return true;
    if k == .C_NULL && !null_pointer_is_defined(irp_anchor_scope(p), ptr_addrspace(vtype(v))) return true;
    return atr_has_attr(p, .[.ByVal, .NoAlias], ign, .NoAlias);
}

na_update :: (i: u32) -> bool {
    p := aa(i).pos;
    pk := aa(i).pk;
    if pk == .FLOAT return aa_pessimistic(i);
    if pk == .ARGUMENT {
        ns, _ := atr_has_assumed_ir_attr(.NoSync, i, irp_function_scope(p), DEP_OPTIONAL);
        if ns return aa_argument_from_call_site_arguments(i, .NoAlias);
        ro, _ := atr_is_assumed_read_only(p, i);
        if ro return aa_argument_from_call_site_arguments(i, .NoAlias);
        uai := false;
        if atr_all_call_sites_known(i, *uai) return aa_argument_from_call_site_arguments(i, .NoAlias);
        return aa_pessimistic(i);
    }
    if pk == .CALL_SITE_ARGUMENT return na_cs_argument_update(i);
    if pk == .RETURNED {
        f := irp_assoc_fn(p);
        vals: [..] Vac; vals.allocator = temp;
        uai := false;
        if f == NONE || !atr_get_assumed_simplified_values(irp_returned(f), i, *vals, AA_INTRA, *uai, true) return aa_pessimistic(i);
        for vals {
            rv := it.v;
            if is_constant_kind(vkind(rv)) && (is_null_value(rv) || is_undef_value(rv)) continue;
            if !irp_is_call(rv) return aa_pessimistic(i);
            rp := irp_value(rv);
            na, _ := atr_has_assumed_ir_attr(.NoAlias, i, rp, DEP_REQUIRED);
            if !na return aa_pessimistic(i);
            nc, _, nca := atr_has_assumed_ir_attr(.Captures, i, rp, DEP_REQUIRED);
            if !(nc || (nca != NONE && nc_maybe_returned(nca))) return aa_pessimistic(i);
        }
        return ATR_UNCHANGED;
    }
    if pk == .CALL_SITE_RETURNED return aa_callee_to_call_site(i, .NoAlias);
    return aa_pessimistic(i);
}
// mayAliasWithArgument
na_may_alias_with_argument :: (i: u32, mb: u32, cb: Value_Id, other: u32) -> bool {
    p := aa(i).pos;
    if irp_callee_arg_no(p) == cast(s64) other return false;
    arg_op := call_arg(cb, other);
    if !is_ptr_or_ptr_vector(vtype(arg_op)) return false;
    omb := atr_get_aa(.MEM_BEHAVIOR, irp_cs_argument(cb, other), i, DEP_NONE);
    if omb != NONE && bs_is_assumed(aa(omb).s, MB_NO_ACCESSES) {
        atr_record_dependence(omb, i, DEP_OPTIONAL);
        return false;
    }
    is_ro := bs_is_assumed(aa(mb).s, MB_NO_WRITES);
    if omb != NONE && bs_is_assumed(aa(omb).s, MB_NO_WRITES) && is_ro {
        atr_record_dependence(mb, i, DEP_OPTIONAL);
        atr_record_dependence(omb, i, DEP_OPTIONAL);
        return false;
    }
    aar := aa_results_for(irp_anchor_scope(p));
    r := aa_alias_once(*aar, mloc_before_or_after(irp_assoc_value(p)), mloc_before_or_after(arg_op));
    return r.kind != AR_NO;
}
// isKnownNoAliasDueToNoAliasPreservation
na_known_no_alias_due_to_preservation :: (i: u32, mb: u32) -> bool {
    p := aa(i).pos;
    v := irp_assoc_value(p);
    vp := irp_value(v);
    scope_fn := irp_anchor_scope(vp);
    ctx := irp_ctx_i(p);
    nc, _, nca := atr_has_assumed_ir_attr(.Captures, i, vp, DEP_NONE);
    if !nc && (nca == NONE || !nc_maybe_returned(nca)) {
        ok, w := atr_uses_begin(i, v);
        if !ok return false;
        while true {
            u := atr_uses_next(*w);
            if u == NONE break;
            user := ir.u_user[u];
            follow := false;
            good := false;
            if user == ctx && nops(user) == 1 good = true;
            else {
                handled := false;
                if scope_fn != NONE {
                    if is_call_base(user) && call_is_arg_operand(user, u) {
                        c, _ := atr_has_assumed_ir_attr(.Captures, i, irp_cs_argument(user, use_arg_no(u)), DEP_OPTIONAL);
                        if c { good = true; handled = true; }
                    }
                    if !handled && !atr_is_potentially_reachable(user, ctx, i, null, .{GOBACK_NOT_FN, scope_fn}) { good = true; handled = true; }
                }
                if !handled {
                    ucc, rcc := ct_use_capture_kind(u, NONE);
                    if (ucc | rcc) == CC_NONE good = true;
                    else if ucc == CC_NONE && rcc != CC_NONE { follow = true; good = true; }
                }
            }
            if !good return false;
            if follow atr_uses_follow(*w, u);
        }
        if w.failed return false;
    }
    if nca != NONE atr_record_dependence(nca, i, DEP_OPTIONAL);
    cb := irp_anchor(p);
    for k: 0..cast(s64) call_num_args(cb) - 1 if na_may_alias_with_argument(i, mb, cb, cast(u32) k) return false;
    return true;
}
na_cs_argument_update :: (i: u32) -> bool {
    p := aa(i).pos;
    mb := atr_get_aa(.MEM_BEHAVIOR, p, i, DEP_NONE);
    if mb != NONE && bs_is_assumed(aa(mb).s, MB_NO_ACCESSES) {
        atr_record_dependence(mb, i, DEP_OPTIONAL);
        return ATR_UNCHANGED;
    }
    vp := irp_value(irp_assoc_value(p));
    na, _ := atr_has_assumed_ir_attr(.NoAlias, i, vp, DEP_REQUIRED);
    if !na return aa_pessimistic(i);
    if mb != NONE && na_known_no_alias_due_to_preservation(i, mb) return ATR_UNCHANGED;
    return aa_pessimistic(i);
}

// ---------------------------------------------------------------- AADereferenceable

Deref_Ext :: struct { accessed: [..] [2] s64; }   // AccessedBytesMap (std::map: sorted by offset)
deref_ext :: inline (i: u32) -> *Deref_Ext { return cast(*Deref_Ext) aa(i).x; }
deref_construct :: (i: u32) { aa(i).x = New(Deref_Ext); }

deref_initialize :: (i: u32) {
    p := aa(i).pos;
    v := atr_strip_pointer_casts(irp_assoc_value(p));
    attrs: [..] Attr; attrs.allocator = temp;
    atr_get_attrs(p, .[.Dereferenceable, .DereferenceableOrNull], *attrs);
    e := deref_ext(i);
    for attrs deref_take_known_max(*aa(i).s, *e.accessed, it.ival);
    atr_has_assumed_ir_attr(.NonNull, i, p, DEP_OPTIONAL);
    _, db := pointer_dereferenceable_bytes(v);
    deref_take_known_max(*aa(i).s, *e.accessed, db);
    ctx := irp_ctx_i(p);
    if ctx != NONE {
        st := mbec_state_of(i);
        aa_follow_uses_in_mbec(i, ctx, *st);
    }
}
// addAccessedBytesForUse
deref_add_accessed_bytes_for_use :: (i: u32, u: Use_Id, x: Value_Id, st: *Mbec_State) {
    use_v := ir.u_val[u];
    if !is_ptr_type(vtype(use_v)) return;
    ok, loc := mloc_get_or_none(x);
    if !ok || loc.ptr != use_v || !ls_has_value(loc.size) || !ls_is_precise(loc.size) || is_volatile(x) return;
    base, off := get_pointer_base_with_constant_offset(loc.ptr);
    if base != NONE && base == irp_assoc_value(aa(i).pos) deref_add_accessed_bytes(st.s, st.accessed, off, ls_value(loc.size));
}
deref_update :: (i: u32) -> bool {
    pk := aa(i).pk;
    if pk == .RETURNED return aa_returned_from_returned_values(i, .NONE_ATTR, true);
    if pk == .ARGUMENT return aa_argument_from_call_site_arguments(i, .NONE_ATTR);
    if pk == .CALL_SITE_RETURNED return aa_callee_to_call_site(i, .NONE_ATTR);
    return deref_floating_update(i);
}
// AADereferenceableFloating::updateImpl
deref_floating_update :: (i: u32) -> bool {
    p := aa(i).pos;
    av := irp_assoc_value(p);
    uai := false;
    vals: [..] Vac; vals.allocator = temp;
    stripped: bool;
    if !atr_get_assumed_simplified_values(p, i, *vals, AA_ANY, *uai) {
        array_add(*vals, .{av, irp_ctx_i(p)});
        stripped = false;
    } else {
        stripped = vals.count != 1 || vals[0].v != av;
    }
    t: Gstate;
    t.kind = .DEREFERENCEABLE;
    t.s = bs_new_inc(0xFFFF_FFFF, 0);
    t.g = bs_new(1);
    for vac: vals {
        v := vac.v;
        off := ap_zero(dl_index_type_size_bits(vtype(v)));
        base, offset := atr_strip_and_accumulate_offsets(i, v, off, false, true);
        o := atr_get_aa(.DEREFERENCEABLE, irp_value(base), i, DEP_REQUIRED);
        deref: s64 = 0;
        if o == NONE || (!stripped && i == o) {
            _, db := pointer_dereferenceable_bytes(base);
            deref = cast(s64) db;
            bs_pessimistic(*t.g);
        } else {
            deref = cast(s64) aa(o).s.assumed;
            bs_join_and(*t.g, aa(o).g);
        }
        os := ap_sext_value(offset);
        if os < 0 os = 0;
        bs_take_assumed_min(*t.s, (cast(u64) max(0, deref - os)) & 0xFFFF_FFFF);
        if i == o {
            if !stripped {
                bs_take_known_max(*t.s, (cast(u64) max(0, deref - os)) & 0xFFFF_FFFF);
                bs_pessimistic(*t.s); bs_pessimistic(*t.g);
            } else if os > 0 {
                bs_pessimistic(*t.s); bs_pessimistic(*t.g);
            }
        }
        if !bs_is_valid(t.s) return aa_pessimistic(i);
    }
    return aa_clamp_state_and_indicate(i, t);
}
deref_manifest :: (i: u32) -> bool {
    p := aa(i).pos;
    change := aa_ir_attribute_manifest(i);
    nn, _ := atr_has_assumed_ir_attr(.NonNull, i, p, DEP_NONE);
    if nn && atr_has_attr(p, .[.DereferenceableOrNull]) {
        atr_remove_attrs(p, .[.DereferenceableOrNull]);
        return ATR_CHANGED;
    }
    return change;
}

// ---------------------------------------------------------------- AAAlign

// getKnownAlignForUse: (alignment, TrackUse)
align_known_for_use :: (i: u32, assoc: Value_Id, u: Use_Id, x: Value_Id) -> (u64, bool) {
    o := inst_op(x);
    if is_cast_op(o) return 0, o != .PTRTOINT;
    if o == .GEP {
        return 0, gep_has_all_constant_indices(x);
    }
    if o == .CALL && call_is_intrinsic(x) {
        id := call_iid(x);
        if id == IID_PTRMASK {
            cv := atr_get_aa(.POTENTIAL_CONSTANT_VALUES, irp_value(op(x, 1)), i, DEP_NONE);
            al := atr_get_aa(.ALIGN, irp_value(x), i, DEP_NONE);
            if cv != NONE && aa_is_valid(cv) && aa_is_fix(cv) {
                shift := min(pcv_assumed_min_trailing_zeros(cv), 32);
                ca := (cast(u64) 1) << shift;
                if ca >= aa(al).s.known return 1, false;
            }
            if al != NONE return aa(al).s.known, false;
        }
    }
    ma: u64 = 0;
    if is_call_base(x) {
        if call_is_bundle_operand(x, u) || call_is_callee_use(x, u) return 0, false;
        a := atr_get_aa(.ALIGN, irp_cs_argument(x, use_arg_no(u)), i, DEP_NONE);
        if a != NONE ma = aa(a).s.known;
    }
    use_v := ir.u_val[u];
    if o == .STORE { if op(x, 1) == use_v ma = inst(x).align; }
    else if o == .LOAD { if op(x, 0) == use_v ma = inst(x).align; }
    else if o == .ATOMICRMW { if op(x, 0) == use_v ma = inst(x).align; }
    else if o == .CMPXCHG { if op(x, 0) == use_v ma = inst(x).align; }
    if ma == 0 || ma <= aa(i).s.known return 0, false;
    alignment := cast,no_check(u32) ma;
    base, offset := get_pointer_base_with_constant_offset(use_v);
    if base != NONE && base == assoc {
        g := gcd_u32(abs_s32_as_u32(cast,force(s32) offset), alignment);
        alignment = bit_floor_u32(g);
    }
    return cast(u64) alignment, false;
}
bit_floor_u32 :: (x: u32) -> u32 { if x == 0 return 0; r: u32 = 1; while r <= x / 2 r <<= 1; return r; }

align_initialize :: (i: u32) {
    p := aa(i).pos;
    attrs: [..] Attr; attrs.allocator = temp;
    atr_get_attrs(p, .[.Alignment], *attrs);
    for attrs bs_take_known_max(*aa(i).s, it.ival);
    v := atr_strip_pointer_casts(irp_assoc_value(p));
    bs_take_known_max(*aa(i).s, pointer_alignment(v));
    ctx := irp_ctx_i(p);
    if ctx != NONE {
        st := mbec_state_of(i);
        aa_follow_uses_in_mbec(i, ctx, *st);
    }
}
align_update :: (i: u32) -> bool {
    pk := aa(i).pk;
    p := aa(i).pos;
    if pk == .RETURNED return aa_returned_from_returned_values(i, .NONE_ATTR, true);
    if pk == .ARGUMENT return aa_argument_from_call_site_arguments(i, .NONE_ATTR);
    if pk == .CALL_SITE_RETURNED {
        cb := irp_ctx_i(p);
        if inst_op(cb) == .CALL && call_is_intrinsic(cb) && call_iid(cb) == IID_PTRMASK {
            alignment: u64 = 1;
            valid := false;
            cv := atr_get_aa(.POTENTIAL_CONSTANT_VALUES, irp_value(op(cb, 1)), i, DEP_REQUIRED);
            if cv != NONE && aa_is_valid(cv) {
                shift := min(pcv_assumed_min_trailing_zeros(cv), 32);
                alignment = (cast(u64) 1) << shift;
                valid = true;
            }
            al := atr_get_aa(.ALIGN, irp_value(op(cb, 0)), i, DEP_REQUIRED);
            if al != NONE { alignment = max(aa(al).s.assumed, alignment); valid = true; }
            if valid {
                r := bs_new_inc(1 << 32, 1);
                r.assumed = min(aa(i).s.assumed, alignment);
                return bs_clamp_and_indicate(*aa(i).s, r);
            }
        }
        return aa_callee_to_call_site(i, .NONE_ATTR);
    }
    changed := align_floating_update(i);
    if pk == .CALL_SITE_ARGUMENT {
        arg := irp_assoc_arg(p);
        if arg != NONE {
            a := atr_get_aa(.ALIGN, irp_argument(arg), i, DEP_NONE);
            if a != NONE bs_take_known_max(*aa(i).s, aa(a).s.known);
        }
    }
    return changed;
}
// AAAlignFloating::updateImpl
align_floating_update :: (i: u32) -> bool {
    p := aa(i).pos;
    av := irp_assoc_value(p);
    uai := false;
    vals: [..] Vac; vals.allocator = temp;
    stripped: bool;
    if !atr_get_assumed_simplified_values(p, i, *vals, AA_ANY, *uai) {
        array_add(*vals, .{av, irp_ctx_i(p)});
        stripped = false;
    } else {
        stripped = vals.count != 1 || vals[0].v != av;
    }
    t := bs_new_inc(1 << 32, 1);
    for vac: vals {
        v := vac.v;
        if is_undef_value(v) || vkind(v) == .C_NULL continue;
        o := atr_get_aa(.ALIGN, irp_value(v), i, DEP_REQUIRED);
        if o == NONE || (!stripped && i == o) {
            alignment: u32 = 1;
            base, offset := get_pointer_base_with_constant_offset(v);
            if base != NONE {
                pa := cast(u32) pointer_alignment(base);
                g := gcd_u32(abs_s32_as_u32(cast,force(s32) offset), pa);
                alignment = bit_floor_u32(g);
            } else {
                alignment = cast(u32) pointer_alignment(v);
            }
            bs_take_known_max(*t, alignment);
            bs_pessimistic(*t);
        } else {
            bs_clamp(*t, aa(o).s);
        }
        if !bs_is_valid(t) return aa_pessimistic(i);
    }
    return bs_clamp_and_indicate(*aa(i).s, t);
}
align_manifest :: (i: u32) -> bool {
    p := aa(i).pos;
    pk := aa(i).pk;
    if pk == .ARGUMENT {
        if atr_is_involved_in_must_tail_call(irp_assoc_arg(p)) return ATR_UNCHANGED;
    }
    if pk == .CALL_SITE_ARGUMENT {
        arg := irp_assoc_arg(p);
        if arg != NONE && atr_is_involved_in_must_tail_call(arg) return ATR_UNCHANGED;
        changed := align_impl_manifest(i);
        if pointer_alignment(irp_assoc_value(p)) >= aa(i).s.assumed changed = ATR_UNCHANGED;
        return changed;
    }
    return align_impl_manifest(i);
}
// AAAlignImpl::manifest
align_impl_manifest :: (i: u32) -> bool {
    p := aa(i).pos;
    instr_changed := ATR_UNCHANGED;
    av := irp_assoc_value(p);
    if is_constant_data(av) return ATR_UNCHANGED;
    assumed := aa(i).s.assumed;
    u := ir.v_first_use[av];
    while u != NONE {
        user := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(user) continue;
        o := inst_op(user);
        ptr_idx: u32 = ifx o == .STORE then cast(u32) 1 else 0;
        if o == .STORE || o == .LOAD || o == .ATOMICRMW || o == .CMPXCHG {
            if op(user, ptr_idx) == av && inst(user).align < assumed {
                inst(user).align = assumed;
                instr_changed = ATR_CHANGED;
            }
        }
    }
    changed := aa_ir_attribute_manifest(i);
    if pointer_alignment(av) >= assumed return instr_changed;
    return changed || instr_changed;
}

// ---------------------------------------------------------------- AANoUndef

// AANoUndef::isImpliedByIR
aa_no_undef_implied_by_ir :: (p: Irp, ign: bool) -> bool {
    if atr_has_attr(p, .[.NoUndef], ign, .NoUndef) return true;
    v := irp_assoc_value(p);
    if irp_kind(p) != .RETURNED && is_guaranteed_not_to_be_undef_or_poison(v) {
        atr_manifest_attrs(p, .[attr_enum(.NoUndef)]);
        return true;
    }
    return false;
}
nu_undef_initialize :: (i: u32) {
    p := aa(i).pos;
    if is_undef_value(irp_assoc_value(p)) aa_pessimistic(i);
    pk := aa(i).pk;
    if pk != .FLOAT && pk != .CALL_SITE_ARGUMENT return;
    f := irp_anchor_scope(p);
    if !aa_is_fix(i) && f != NONE && !is_declaration(f) {
        ctx := irp_ctx_i(p);
        if ctx != NONE {
            st := mbec_state_of(i);
            aa_follow_uses_in_mbec(i, ctx, *st);
            }
    }
}
nu_undef_update :: (i: u32) -> bool {
    pk := aa(i).pk;
    p := aa(i).pos;
    if pk == .RETURNED return aa_returned_from_returned_values(i, .NoUndef, true);
    if pk == .ARGUMENT return aa_argument_from_call_site_arguments(i, .NoUndef);
    if pk == .CALL_SITE_RETURNED return aa_callee_to_call_site(i, .NoUndef);
    av := irp_assoc_value(p);
    uai := false;
    vals: [..] Vac; vals.allocator = temp;
    stripped: bool;
    if !atr_get_assumed_simplified_values(p, i, *vals, AA_ANY, *uai) stripped = false;
    else stripped = vals.count != 1 || vals[0].v != av;
    if !stripped {
        avp := irp_value(av);
        if irp_eq(avp, p) return aa_pessimistic(i);
        ok, _ := atr_has_assumed_ir_attr(.NoUndef, i, avp, DEP_REQUIRED);
        if !ok return aa_pessimistic(i);
        return ATR_UNCHANGED;
    }
    for vals {
        ok, _ := atr_has_assumed_ir_attr(.NoUndef, i, irp_value(it.v), DEP_REQUIRED);
        if !ok return aa_pessimistic(i);
    }
    return ATR_UNCHANGED;
}
nu_undef_manifest :: (i: u32) -> bool {
    p := aa(i).pos;
    uai := false;
    if atr_is_assumed_dead_irp(p, NONE, NONE, *uai) return ATR_UNCHANGED;
    if atr_get_assumed_simplified(p, i, *uai, AA_INTER) == OV_NOVAL return ATR_UNCHANGED;
    return aa_ir_attribute_manifest(i);
}

// ---------------------------------------------------------------- AAInstanceInfo

ii_initialize :: (i: u32) {
    p := aa(i).pos;
    if aa(i).pk == .RETURNED fatal("internal: attributor: InstanceInfo is not applicable to function returns");
    v := irp_assoc_value(p);
    if is_constant_kind(vkind(v)) {
        if constant_is_thread_dependent(v) aa_pessimistic(i);
        else aa_optimistic(i);
        return;
    }
    if irp_is_call(v) && call_num_args(v) == 0 && !may_have_side_effects(v) && !may_read_from_memory(v) {
        aa_optimistic(i);
        return;
    }
    if is_inst(v) {
        ci := atr_ci(inst_fn(v));
        if atr_may_be_in_cycle(ci, v, false) { aa_pessimistic(i); return; }
    }
}
// Constant::isThreadDependent: a thread_local global reachable through the constant's operands
constant_is_thread_dependent :: (c: Value_Id) -> bool {
    work: [..] Value_Id; work.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    array_add(*work, c);
    while work.count {
        v := pop(*work);
        if vkind(v) == .GLOBAL_VAR && glob(v).tls != 0 return true;
        k := vkind(v);
        if k == .C_EXPR || k == .C_ARRAY || k == .C_STRUCT || k == .C_VECTOR || k == .C_PTRAUTH || k == .C_DSO_EQUIV || k == .C_NO_CFI {
            for x: 0..cast(s64) nops(v) - 1 {
                o := op(v, cast(u32) x);
                if is_constant_kind(vkind(o)) && !table_contains(*visited, o) { table_set(*visited, o, true); array_add(*work, o); }
            }
        }
    }
    return false;
}
ii_update :: (i: u32) -> bool {
    p := aa(i).pos;
    if aa(i).pk == .CALL_SITE_ARGUMENT {
        arg := irp_assoc_arg(p);
        if arg == NONE return aa_pessimistic(i);
        o := atr_get_aa(.INSTANCE_INFO, irp_argument(arg), i, DEP_REQUIRED);
        if o == NONE return aa_pessimistic(i);
        return bs_clamp_and_indicate(*aa(i).s, aa(o).s);
    }
    changed := ATR_UNCHANGED;
    v := irp_assoc_value(p);
    scope: Value_Id = NONE;
    if is_inst(v) scope = inst_fn(v);
    if vkind(v) == .ARGUMENT {
        scope = arg_parent(v);
        if !gv_has_local_linkage(scope) return changed;
    }
    if scope == NONE return aa_optimistic(i);
    nr, _ := atr_has_assumed_ir_attr(.NoRecurse, i, irp_function(scope), DEP_OPTIONAL);
    if nr return changed;
    ok, w := atr_uses_begin(i, v, true, DEP_OPTIONAL, true, EQU_INSTANCE_INFO);
    if !ok return aa_pessimistic(i);
    while true {
        u := atr_uses_next(*w);
        if u == NONE break;
        user := ir.u_user[u];
        follow := false;
        good := false;
        o := ifx is_inst(user) then inst_op(user) else Opcode.NONE_OP;
        if !is_inst(user) || o == .GEP || is_cast_op(o) || o == .PHI || o == .SELECT { follow = true; good = true; }
        else if o == .LOAD || o == .ICMP || o == .FCMP || (o == .STORE && op(user, 0) != ir.u_val[u]) good = true;
        else if is_call_base(user) {
            callee := call_callee(user);
            if vkind(callee) != .FUNCTION || !gv_has_local_linkage(callee) good = true;
            else if !call_is_arg_operand(user, u) good = false;
            else {
                a := atr_get_aa(.INSTANCE_INFO, irp_cs_argument(user, use_arg_no(u)), i, DEP_OPTIONAL);
                if a == NONE || !bs_is_assumed(aa(a).s, 1) good = false;
                else good = !atr_is_potentially_reachable_fn(user, scope, i, null, .{GOBACK_NOT_FN, scope});
            }
        }
        if !good return aa_pessimistic(i);
        if follow atr_uses_follow(*w, u);
    }
    if w.failed return aa_pessimistic(i);
    return changed;
}

// ---------------------------------------------------------------- AAAssumptionInfo (SetState<StringRef>)

Set_Contents :: struct { universal: bool; set: [..] string; }
Asi_Ext :: struct { known: Set_Contents; assumed: Set_Contents; fix: bool; }
asi_ext :: inline (i: u32) -> *Asi_Ext { return cast(*Asi_Ext) aa(i).x; }
sc_contains :: (s: *Set_Contents, k: string) -> bool { for s.set if it == k return true; return false; }
sc_empty :: (s: *Set_Contents) -> bool { return s.set.count == 0 && !s.universal; }
sc_copy :: (s: *Set_Contents) -> Set_Contents { r: Set_Contents; r.universal = s.universal; for s.set array_add(*r.set, it); return r; }
// SetContents::getIntersection
sc_intersection :: (s: *Set_Contents, rhs: *Set_Contents) -> bool {
    was_universal := s.universal;
    size := s.set.count;
    if rhs.universal return false;
    if s.universal {
        s.set.count = 0;
        for rhs.set array_add(*s.set, it);
    } else {
        n: [..] string;
        for s.set if sc_contains(rhs, it) array_add(*n, it);
        s.set = n;
    }
    s.universal = s.universal && rhs.universal;
    return was_universal != s.universal || size != s.set.count;
}
// SetContents::getUnion
sc_union :: (s: *Set_Contents, rhs: *Set_Contents) -> bool {
    was_universal := s.universal;
    size := s.set.count;
    if !rhs.universal && !s.universal for rhs.set if !sc_contains(s, it) array_add(*s.set, it);
    s.universal = s.universal || rhs.universal;
    return was_universal != s.universal || size != s.set.count;
}
asi_is_valid :: (i: u32) -> bool { return !sc_empty(*asi_ext(i).assumed); }
asi_optimistic :: (i: u32) { e := asi_ext(i); e.fix = true; e.known = sc_copy(*e.assumed); }
asi_pessimistic :: (i: u32) { e := asi_ext(i); e.fix = true; e.assumed = sc_copy(*e.known); }
// SetState::getIntersection
asi_get_intersection :: (i: u32, rhs: *Set_Contents) -> bool {
    e := asi_ext(i);
    was_universal := e.assumed.universal;
    size := e.assumed.set.count;
    r := sc_copy(rhs);
    sc_intersection(*e.assumed, *r);
    sc_union(*e.assumed, *e.known);
    return size != e.assumed.set.count || was_universal != e.assumed.universal;
}
// getAssumptions(F or CB): the "llvm.assume" string attribute, split on ','
assumptions_of_set :: (s: u32, out: *[..] string) {
    for attr_set_items(s) if it.kind == .STRING_ATTR && it.key == "llvm.assume" {
        parts := split(it.val, ",");
        for parts if !sc_list_contains(out.*, it) array_add(out, copy_string(it));
    }
}
sc_list_contains :: (l: [] string, k: string) -> bool { for l if it == k return true; return false; }
asi_construct :: (i: u32) {
    e := New(Asi_Ext);
    aa(i).x = e;
    e.assumed.universal = true;
    p := aa(i).pos;
    known: [..] string;
    if aa(i).pk == .FUNCTION {
        assumptions_of_set(attr_list_fn(glob(irp_assoc_fn(p)).attrs), *known);
    } else {
        cb := irp_assoc_value(p);
        assumptions_of_set(call_fn_attrs(cb), *known);
        assumptions_of_set(attr_list_fn(glob(inst_fn(cb)).attrs), *known);
        f := irp_assoc_fn(p);
        if f != NONE assumptions_of_set(attr_list_fn(glob(f).attrs), *known);
    }
    e.known.set = known;
}
asi_initialize :: (i: u32) {
    if aa(i).pk == .CALL_SITE atr_get_aa(.ASSUMPTION_INFO, irp_function(irp_anchor_scope(aa(i).pos)), i, DEP_REQUIRED);
}
asi_update :: (i: u32) -> bool {
    p := aa(i).pos;
    if aa(i).pk == .CALL_SITE {
        o := atr_get_aa(.ASSUMPTION_INFO, irp_function(irp_anchor_scope(p)), i, DEP_REQUIRED);
        if o == NONE return aa_pessimistic(i);
        return asi_get_intersection(i, *asi_ext(o).assumed);
    }
    changed := false;
    uai := false;
    ok := true;
    for cb: atr_call_sites(i, true, *uai, *ok) {
        o := atr_get_aa(.ASSUMPTION_INFO, irp_cs_function(cb), i, DEP_REQUIRED);
        if o == NONE { ok = false; break; }
        changed |= asi_get_intersection(i, *asi_ext(o).assumed);
        e := asi_ext(i);
        if !(!sc_empty(*e.assumed) || !sc_empty(*e.known)) { ok = false; break; }
    }
    if !ok return aa_pessimistic(i);
    return changed;
}
// hasAssumption
asi_has_assumption :: (i: u32, k: string) -> bool {
    if !aa_is_valid(i) return false;
    e := asi_ext(i);
    return sc_contains(*e.assumed, k) || sc_contains(*e.known, k);
}
asi_manifest :: (i: u32) -> bool {
    e := asi_ext(i);
    if e.known.universal return ATR_UNCHANGED;
    set: [..] string; set.allocator = temp;
    for e.assumed.set array_add(*set, it);
    quick_sort(set, compare_strings);
    sb: String_Builder;
    for set { if it_index > 0 append(*sb, ","); append(*sb, it); }
    return atr_manifest_attrs(aa(i).pos, .[attr_str("llvm.assume", builder_to_string(*sb))], true);
}

// ---------------------------------------------------------------- AAGlobalValueInfo

Gvi_Ext :: struct { uses: Table(Use_Id, bool); }
gvi_ext :: inline (i: u32) -> *Gvi_Ext { return cast(*Gvi_Ext) aa(i).x; }
gvi_insert_use :: (i: u32, u: Use_Id) { table_set(*gvi_ext(i).uses, u, true); }
gvi_is_potential_use :: (i: u32, u: Use_Id) -> bool { return !aa_is_valid(i) || table_contains(*gvi_ext(i).uses, u); }
gvi_update :: (i: u32) -> bool {
    e := gvi_ext(i);
    before := e.uses.count;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    anchor := irp_anchor(aa(i).pos);
    array_add(*work, anchor);
    while work.count {
        v := pop(*work);
        if table_contains(*visited, v) continue;
        table_set(*visited, v, true);
        ok, w := atr_uses_begin(i, v, true, DEP_OPTIONAL, true, EQU_GLOBAL_VALUE_INFO);
        if !ok return aa_pessimistic(i);
        while true {
            u := atr_uses_next(*w);
            if u == NONE break;
            gvi_insert_use(i, u);
            follow := false;
            ucc, rcc := ct_use_capture_kind(u, NONE);
            good := false;
            if ucc == CC_NONE && rcc != CC_NONE { follow = true; good = true; }
            else good = gvi_check_use(i, u, *follow, *work, anchor);
            if !good return aa_pessimistic(i);
            if follow atr_uses_follow(*w, u);
        }
        if w.failed return aa_pessimistic(i);
    }
    return e.uses.count != before;
}
gvi_check_use :: (i: u32, u: Use_Id, follow: *bool, work: *[..] Value_Id, anchor: Value_Id) -> bool {
    user := ir.u_user[u];
    if !is_inst(user) { follow.* = true; return true; }
    o := inst_op(user);
    if o == .ICMP {
        idx: u32 = ifx op_use(user, 0) == u then cast(u32) 1 else 0;
        if is_constant_kind(vkind(op(user, idx))) return true;
        return ir.u_val[u] == anchor;
    }
    if o == .RET {
        uai := false;
        ok := true;
        for cb: atr_call_sites_of(inst_fn(user), true, i, *uai, *ok) array_add(work, cb);
        return ok;
    }
    if !is_call_base(user) return false;
    if call_is_callee_use(user, u) return true;
    if !call_is_arg_operand(user, u) return false;
    f := call_callee(user);
    if vkind(f) != .FUNCTION || !atr_is_ipo_amendable(f) return false;
    array_add(work, fn_arg(f, use_arg_no(u)));
    return true;
}

// ---------------------------------------------------------------- AAIndirectCallInfo

Ici_Ext :: struct {
    filter: Table(Value_Id, u8);         // FilterResults: 1 false, 2 true
    potential: [..] Value_Id;            // PotentialCallees (SmallSetVector)
    assumed: [..] Value_Id;              // AssumedCallees (SmallSetVector)
    all_known: bool;
}
ici_ext :: inline (i: u32) -> *Ici_Ext { return cast(*Ici_Ext) aa(i).x; }
ici_construct :: (i: u32) { e := New(Ici_Ext); e.all_known = true; aa(i).x = e; }
ici_initialize :: (i: u32) {
    cb := irp_ctx_i(aa(i).pos);
    md := inst_md(cb, "callees");
    if md == NONE && !atr_is_closed_world() return;
    e := ici_ext(i);
    if md != NONE {
        for k: 0..cast(s64) md_nops(md) - 1 {
            f := md_op_value(md, cast(u32) k);
            if f != NONE && vkind(f) == .FUNCTION copies_insert(*e.potential, f);
        }
    } else {
        for atr.indirectly_callable copies_insert(*e.potential, it);
    }
    if e.potential.count == 0 aa_optimistic(i);
}
ici_check_potential_callee_use :: (i: u32, f: Value_Id, callee_use: Use_Id, uai: *bool) -> bool {
    g := atr_get_aa(.GLOBAL_VALUE_INFO, irp_value(f), i, DEP_OPTIONAL);
    if g == NONE || gvi_is_potential_use(g, callee_use) return true;
    uai.* = !aa_is_fix(g);
    return false;
}
ici_update :: (i: u32) -> bool {
    e := ici_ext(i);
    cb := irp_ctx_i(aa(i).pos);
    callee_use := op_use(cb, nops(cb) - 1);
    fp := call_callee(cb);
    now: [..] Value_Id; now.allocator = temp;
    all_known_now := e.all_known;
    add_potential :: (i: u32, e: *Ici_Ext, now: *[..] Value_Id, callee_use: Use_Id) {
        for pc: e.potential {
            uai := false;
            if ici_check_potential_callee_use(i, pc, callee_use, *uai) copies_insert(now, pc);
        }
    }
    uai := false;
    vals: [..] Vac; vals.allocator = temp;
    if !atr_get_assumed_simplified_values(irp_value(fp), i, *vals, AA_ANY, *uai) {
        if e.potential.count == 0 return aa_pessimistic(i);
        add_potential(i, e, *now, callee_use);
    }
    check_potential_callee :: (i: u32, e: *Ici_Ext, f: Value_Id, cb: Value_Id, callee_use: Use_Id) -> bool {
        if e.potential.count != 0 && !copies_contains(*e.potential, f) return false;
        found, cached := table_find(*e.filter, f);
        if found && cached != 0 return cached == 2;
        uai := false;
        if !ici_check_potential_callee_use(i, f, callee_use, *uai) {
            if !uai table_set(*e.filter, f, 1);
            return false;
        }
        nfa := cast(s64) fn_nargs(f);
        nca := cast(s64) call_num_args(cb);
        for k: nca..nfa - 1 {
            nu, known := atr_has_assumed_ir_attr(.NoUndef, i, irp_argument(fn_arg(f, cast(u32) k)), DEP_OPTIONAL);
            if nu {
                if known table_set(*e.filter, f, 1);
                return false;
            }
        }
        table_set(*e.filter, f, 2);
        return true;
    }
    for vac: vals {
        v := vac.v;
        if is_undef_value(v) continue;
        if vkind(v) == .C_NULL && ptr_addrspace(vtype(v)) == 0 continue;
        if vkind(v) == .FUNCTION {
            if check_potential_callee(i, e, v, cb, callee_use) copies_insert(*now, v);
            continue;
        }
        if e.potential.count != 0 { add_potential(i, e, *now, callee_use); break; }
        all_known_now = false;
    }
    same := now.count == e.assumed.count;
    if same for now if it != e.assumed[it_index] { same = false; break; }
    if same && e.all_known == all_known_now return ATR_UNCHANGED;
    e.assumed.count = 0;
    for now array_add(*e.assumed, it);
    e.all_known = all_known_now;
    return ATR_CHANGED;
}
// foreachCallee: the callees if all are known
ici_all_callees :: (i: u32) -> (bool, [] Value_Id) {
    e := ici_ext(i);
    if !aa_is_valid(i) || !e.all_known return false, .[];
    return true, e.assumed;
}
ici_manifest :: (i: u32) -> bool {
    e := ici_ext(i);
    if !e.all_known && e.assumed.count == 0 return ATR_UNCHANGED;
    cb := irp_ctx_i(aa(i).pos);
    uai := false;
    if atr_is_assumed_dead_inst(cb, i, NONE, *uai) return ATR_UNCHANGED;
    if e.assumed.count == 0 {
        atr_change_to_unreachable_after_manifest(cb);
        return ATR_CHANGED;
    }
    return ici_specialize(i, cb);
}

// ---------------------------------------------------------------- AAInvariantLoadPointer

ILP_IS_NOALIAS :: cast(u64) 1;
ILP_IS_NOEFFECT :: cast(u64) 2;
ILP_IS_LOCALLY_INVARIANT :: cast(u64) 4;
ILP_IS_LOCALLY_CONSTRAINED :: cast(u64) 8;
ilp_is_known_locally_invariant :: (i: u32) -> bool {
    s := aa(i).s;
    if bs_is_known(s, ILP_IS_LOCALLY_INVARIANT) return true;
    return bs_is_known(s, ILP_IS_NOALIAS | ILP_IS_NOEFFECT);
}
ilp_is_known_invariant :: (i: u32) -> bool { return ilp_is_known_locally_invariant(i) && bs_is_known(aa(i).s, ILP_IS_LOCALLY_CONSTRAINED); }
ilp_is_assumed_locally_invariant :: (i: u32) -> bool {
    s := aa(i).s;
    if bs_is_assumed(s, ILP_IS_LOCALLY_INVARIANT) return true;
    return bs_is_assumed(s, ILP_IS_NOALIAS | ILP_IS_NOEFFECT);
}
// isCallableCC: not a GPU kernel calling convention
is_callable_cc :: (cc: u32) -> bool {
    // CallingConv::AMDGPU_KERNEL (91), SPIR_KERNEL (76), PTX_Kernel (71), AMDGPU_CS/ES/GS/HS/LS/PS/VS... are not callable
    return !(cc == 71 || cc == 76 || cc == 91 || (cc >= 87 && cc <= 90) || cc == 93 || cc == 95 || cc == 96 || cc == 104 || cc == 105);
}
ilp_initialize :: (i: u32) {
    p := aa(i).pos;
    pk := aa(i).pk;
    if pk == .RETURNED { bs_remove_assumed(*aa(i).s, ILP_IS_LOCALLY_CONSTRAINED); return; }
    if pk == .CALL_SITE_RETURNED {
        f := irp_assoc_fn(p);
        if !is_declaration(f) && !fn_is_intrinsic_name(f) return;
        cb := irp_anchor(p);
        if argument_aliasing_to_returned_pointer(cb, false) != NONE && call_returned_arg(cb) == NONE return;
        if is_intrinsic_returning_pointer_aliasing_argument_without_capturing(cb) return;
        if fn_only_reads_memory(f) && fn_has_fn_attr(f, .NoSync) return;
        aa_pessimistic(i);
        return;
    }
    if pk == .ARGUMENT {
        f := irp_assoc_fn(p);
        if !is_callable_cc(glob(f).cc) { bs_add_known(*aa(i).s, ILP_IS_LOCALLY_CONSTRAINED); return; }
        if !gv_has_local_linkage(f) bs_remove_assumed(*aa(i).s, ILP_IS_LOCALLY_CONSTRAINED);
    }
}
// isIntrinsicReturningPointerAliasingArgumentWithoutCapturing (MustPreserveOffset = false)
is_intrinsic_returning_pointer_aliasing_argument_without_capturing :: (cb: Value_Id) -> bool {
    id := call_iid(cb);
    if id == IID_LAUNDER_INVARIANT_GROUP || id == IID_STRIP_INVARIANT_GROUP || id == IID_PTRMASK return true;
    if id == IID_THREADLOCAL_ADDRESS return !fn_has_fn_attr(inst_fn(cb), .PresplitCoroutine);
    return false;
}
ilp_requires_no_alias :: (i: u32) -> bool {
    pk := aa(i).pk;
    p := aa(i).pos;
    if pk == .FLOAT || pk == .RETURNED || pk == .CALL_SITE return false;
    if pk == .CALL_SITE_RETURNED return !is_intrinsic_returning_pointer_aliasing_argument_without_capturing(irp_anchor(p));
    if pk == .ARGUMENT return !is_callable_cc(glob(irp_assoc_fn(p)).cc);
    return true;
}
ilp_update :: (i: u32) -> bool {
    changed := ATR_UNCHANGED;
    changed |= ilp_update_no_alias(i);
    if ilp_requires_no_alias(i) && !bs_is_assumed(aa(i).s, ILP_IS_NOALIAS) return aa_pessimistic(i);
    changed |= ilp_update_no_effect(i);
    changed |= ilp_update_local_invariance(i);
    return changed;
}
ilp_update_no_alias :: (i: u32) -> bool {
    s := *aa(i).s;
    if bs_is_known(s.*, ILP_IS_NOALIAS) || !bs_is_assumed(s.*, ILP_IS_NOALIAS) return ATR_UNCHANGED;
    p := aa(i).pos;
    na := atr_get_aa(.NO_ALIAS, p, i, DEP_REQUIRED);
    if na != NONE {
        if bs_is_known(aa(na).s, 1) { bs_add_known(*aa(i).s, ILP_IS_NOALIAS); return ATR_CHANGED; }
        if !bs_is_assumed(aa(na).s, 1) { bs_remove_assumed(*aa(i).s, ILP_IS_NOALIAS); return ATR_CHANGED; }
        return ATR_UNCHANGED;
    }
    arg := irp_assoc_arg(p);
    if arg != NONE {
        if arg_has_attr(arg, .NoAlias) { bs_add_known(*aa(i).s, ILP_IS_NOALIAS); return ATR_UNCHANGED; }
        bs_remove_assumed(*aa(i).s, ILP_IS_NOALIAS);
        return ATR_CHANGED;
    }
    return ATR_UNCHANGED;
}
ilp_update_no_effect :: (i: u32) -> bool {
    s := aa(i).s;
    if bs_is_known(s, ILP_IS_NOEFFECT) || !bs_is_assumed(s, ILP_IS_NOEFFECT) return ATR_UNCHANGED;
    p := aa(i).pos;
    if irp_assoc_fn(p) == NONE return aa_pessimistic(i);
    av := irp_assoc_value(p);
    if is_inst(av) && inst_op(av) == .ALLOCA return aa_pessimistic(i);
    ok, w := atr_uses_begin(i, av);
    if !ok return aa_pessimistic(i);
    while true {
        u := atr_uses_next(*w);
        if u == NONE break;
        user := ir.u_user[u];
        if is_inst(user) && inst_op(user) == .LOAD && may_have_side_effects(user) return aa_pessimistic(i);
    }
    if w.failed return aa_pessimistic(i);
    mb := atr_get_aa(.MEM_BEHAVIOR, p, i, DEP_REQUIRED);
    if mb != NONE {
        if !bs_is_assumed(aa(mb).s, MB_NO_WRITES) return aa_pessimistic(i);
        if bs_is_known(aa(mb).s, MB_NO_WRITES) { bs_add_known(*aa(i).s, ILP_IS_NOEFFECT); return ATR_UNCHANGED; }
        return ATR_UNCHANGED;
    }
    arg := irp_assoc_arg(p);
    if arg != NONE {
        if arg_only_reads_memory(arg) { bs_add_known(*aa(i).s, ILP_IS_NOEFFECT); return ATR_UNCHANGED; }
        return aa_pessimistic(i);
    }
    return ATR_UNCHANGED;
}
ilp_update_local_invariance :: (i: u32) -> bool {
    s := aa(i).s;
    if bs_is_known(s, ILP_IS_LOCALLY_INVARIANT) || !bs_is_assumed(s, ILP_IS_LOCALLY_INVARIANT) return ATR_UNCHANGED;
    p := aa(i).pos;
    uo := atr_get_aa(.UNDERLYING_OBJECTS, p, i, DEP_REQUIRED);
    if uo == NONE return ATR_UNCHANGED;
    uai := false;
    check :: (i: u32, v: Value_Id, uai: *bool) -> bool {
        if !is_ptr_type(vtype(v)) return true;
        o := atr_get_aa(.INVARIANT_LOAD_POINTER, irp_value(v), i, DEP_REQUIRED);
        if o == NONE return false;
        if ilp_is_known_locally_invariant(o) return true;
        if !ilp_is_assumed_locally_invariant(o) return false;
        uai.* = true;
        return true;
    }
    objs: [..] Value_Id; objs.allocator = temp;
    uo_objects(uo, false, *objs);
    for objs if !check(i, it, *uai) return aa_pessimistic(i);
    anchor := irp_anchor(p);
    if irp_is_call(anchor) && is_intrinsic_returning_pointer_aliasing_argument_without_capturing(anchor) {
        for k: 0..cast(s64) call_num_args(anchor) - 1 if !check(i, call_arg(anchor, cast(u32) k), *uai) return aa_pessimistic(i);
    }
    if !uai { bs_add_known(*aa(i).s, ILP_IS_LOCALLY_INVARIANT); return ATR_CHANGED; }
    return ATR_UNCHANGED;
}
ilp_manifest :: (i: u32) -> bool {
    if !ilp_is_known_invariant(i) return ATR_UNCHANGED;
    changed := ATR_UNCHANGED;
    ptr := irp_assoc_value(aa(i).pos);
    ok, w := atr_uses_begin(i, ptr);
    if !ok return ATR_UNCHANGED;
    while true {
        u := atr_uses_next(*w);
        if u == NONE break;
        if ir.u_val[u] != ptr continue;
        user := ir.u_user[u];
        if !is_inst(user) continue;
        if !atr_is_run_on(inst_fn(user)) continue;
        if inst_md(user, "invariant.load") != NONE continue;
        if inst_op(user) == .LOAD {
            set_metadata(user, md_kind_id("invariant.load"), md_tuple(.[], false));
            changed = ATR_CHANGED;
        }
    }
    return changed;
}

// ---------------------------------------------------------------- AAAddressSpace, AANoAliasAddrSpace

// getFlatAddressSpace is nullopt outside GPU targets: both AAs give up in initialize
as_initialize :: (i: u32) {
    if atr_is_target_gpu() fatal("attributor: AAAddressSpace on a GPU target is not supported");
    aa_pessimistic(i);
}

// ---------------------------------------------------------------- AAAllocationInfo

Alloc_Info_Ext :: struct { size: s64 = -2; }   // AssumedAllocatedSize in bits (-2: HasNoAllocationSize)
alloc_info_ext :: inline (i: u32) -> *Alloc_Info_Ext { return cast(*Alloc_Info_Ext) aa(i).x; }
alloc_info_construct :: (i: u32) { aa(i).x = New(Alloc_Info_Ext); }
alloc_info_initialize :: (i: u32) {
    pk := aa(i).pk;
    if pk == .RETURNED || pk == .CALL_SITE_ARGUMENT aa_pessimistic(i);
}
alloc_info_change :: (i: u32, size: s64) -> bool {
    e := alloc_info_ext(i);
    if e.size == -2 || e.size != size { e.size = size; return true; }
    return false;
}
alloc_info_update :: (i: u32) -> bool {
    p := aa(i).pos;
    x := irp_ctx_i(p);
    if x == NONE || !is_inst(x) || inst_op(x) != .ALLOCA return aa_pessimistic(i);
    nc, _ := atr_has_assumed_ir_attr(.Captures, i, p, DEP_OPTIONAL);
    if !nc return aa_pessimistic(i);
    pi := atr_get_aa(.POINTER_INFO, p, i, DEP_REQUIRED);
    if pi == NONE return aa_pessimistic(i);
    if !aa_is_valid(pi) || pi_reaches_return(pi) return aa_pessimistic(i);
    ok, asize := alloca_allocation_size_bytes(x);
    if !ok return aa_pessimistic(i);
    if asize == 0 return aa_pessimistic(i);
    bins := pi_num_offset_bins(pi);
    if bins > 1 return aa_pessimistic(i);
    if bins == 0 {
        if !alloc_info_change(i, 0) return ATR_UNCHANGED;
        return ATR_CHANGED;
    }
    first := bins_order(*pi_ext(pi).bins)[0];
    r := pi_ext(pi).bins.keys[first];
    if r.offset != 0 return aa_pessimistic(i);
    size_of_bin := cast(u64) (r.offset + r.size);
    if size_of_bin >= asize return aa_pessimistic(i);
    if !alloc_info_change(i, cast(s64) (size_of_bin * 8)) return ATR_UNCHANGED;
    return ATR_CHANGED;
}
// AllocaInst::getAllocationSize (in bytes)
alloca_allocation_size_bytes :: (ai: Value_Id) -> (bool, u64) {
    sz := dl_type_alloc_size(inst(ai).ty2);
    n := op(ai, 0);
    if vkind(n) != .C_INT return false, 0;
    if type_is_scalable(inst(ai).ty2) return false, 0;
    return true, sz * ap_zext_value(const_ap(n));
}
alloc_info_manifest :: (i: u32) -> bool {
    p := aa(i).pos;
    x := irp_ctx_i(p);
    bits := cast(u64) alloc_info_ext(i).size;
    nbytes := (bits + 7) / 8;
    if inst_op(x) != .ALLOCA return ATR_UNCHANGED;
    na := create_alloca_after(x, type_int(8), const_int(type_int(32), nbytes), inst(x).align, vname(x));
    if atr_change_after_manifest(irp_inst(x), na) return ATR_CHANGED;
    return ATR_UNCHANGED;
}

// ---------------------------------------------------------------- AANonConvergent

nconv_update :: (i: u32) -> bool {
    uai := false;
    ok := true;
    for cb: atr_call_like_insts(i, *uai, *ok) {
        callee := call_callee(cb);
        good := false;
        if vkind(callee) != .FUNCTION || fn_is_intrinsic_name(callee) good = false;
        else if is_declaration(callee) good = !fn_has_fn_attr(callee, .Convergent);
        else {
            o := atr_get_aa(.NON_CONVERGENT, irp_function(callee), i, DEP_REQUIRED);
            good = o != NONE && bs_is_assumed(aa(o).s, 1);
        }
        if !good { ok = false; break; }
    }
    if !ok return aa_pessimistic(i);
    return ATR_UNCHANGED;
}
nconv_manifest :: (i: u32) -> bool {
    p := aa(i).pos;
    if bs_is_known(aa(i).s, 1) && atr_has_attr(p, .[.Convergent]) {
        atr_remove_attrs(p, .[.Convergent]);
        return ATR_CHANGED;
    }
    return ATR_UNCHANGED;
}
// uint32_t(abs((int32_t)Offset))
abs_s32_as_u32 :: (x: s32) -> u32 { if x < 0 return cast,no_check(u32) (-(cast(s64) x)); return cast(u32) x; }
// new AllocaInst(Ty, AI->getAddressSpace(), Size, Align, Name, std::next(AI->getIterator()))
create_alloca_after :: (x: Value_Id, ty: Type_Id, size: Value_Id, align: u64, name: string) -> Value_Id {
    as := inst(x).addrspace;
    a := new_inst(.ALLOCA, type_ptr(as), 1);
    set_op(a, 0, size);
    inst(a).ty2 = ty;
    inst(a).addrspace = as;
    inst(a).align = align;
    nx := inst_next(x);
    insert_at_position(a, inst_block(x), nx, false);
    if name.count set_name(a, name);
    return a;
}
// mdconst::dyn_extract_or_null<Value>(MD->getOperand(k))
md_op_value :: (md: Md_Id, k: u32) -> Value_Id {
    o := md_op(md, k);
    if o == NONE return NONE;
    if ir.mds[o].kind != .VALUE return NONE;
    return ir.mds[o].value;
}
