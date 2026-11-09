// IVDescriptors: RecurrenceDescriptor and InductionDescriptor.
// Ported from llvm/lib/Analysis/IVDescriptors.cpp (LLVM 23.1.5) and llvm/include/llvm/Analysis/IVDescriptors.h.
// Plus PredicatedScalarEvolution::areAddRecsEqualWithPreds (ScalarEvolution.cpp).
//
// Sets of instructions (SmallPtrSet) are temp `Table(Value_Id, bool)`; only membership is observable, except where
// noted (getMinMaxRecurrence iterates its Chain in insertion order; LLVM iterates it in pointer order, which only
// changes which of several equivalent early returns is taken).

Recur_Kind :: enum u8 {
    NONE; ADD; SUB; ADD_CHAIN_WITH_SUBS; MUL; OR; AND; XOR; SMIN; SMAX; UMIN; UMAX;
    FADD; FADD_CHAIN_WITH_SUBS; FSUB; FMUL; FMIN; FMAX; FMINNUM; FMAXNUM; FMINIMUM; FMAXIMUM; FMINIMUMNUM; FMAXIMUMNUM;
    FMULADD; ANYOF; FINDIV; FINDLAST;
}

// RecurrenceDescriptor
Rdx_Desc :: struct {
    intermediate_store: Value_Id = NONE;
    start: Value_Id = NONE;            // StartValue (TrackingVH: callers that RAUW it must update)
    exit: Value_Id = NONE;             // LoopExitInstr
    kind: Recur_Kind;
    fmf: u32;                          // FastMathFlags (FMF_* bits)
    exact_fp: Value_Id = NONE;         // ExactFPMathInst
    recur_type: Type_Id;
    is_signed: bool;
    is_ordered: bool;
    phi_has_uses_outside_chain: bool;
    casts: [..] Value_Id;              // CastInsts
    min_width_cast: u32 = 0xFFFF_FFFF; // MinWidthCastToRecurrenceType
}

rk_is_integer :: (k: Recur_Kind) -> bool {
    if k == {
        case .ADD_CHAIN_WITH_SUBS; #through; case .SUB; #through; case .ADD; #through; case .MUL; #through; case .OR; #through;
        case .AND; #through; case .XOR; #through; case .SMAX; #through; case .SMIN; #through; case .UMAX; #through;
        case .UMIN; #through; case .ANYOF; #through; case .FINDIV; #through; case .FINDLAST; return true;
    }
    return false;
}
rk_is_floating_point :: (k: Recur_Kind) -> bool { return k != .NONE && !rk_is_integer(k); }
rk_is_sub :: (k: Recur_Kind) -> bool { return k == .SUB || k == .FSUB; }
rk_is_int_min_max :: (k: Recur_Kind) -> bool { return k == .UMIN || k == .UMAX || k == .SMIN || k == .SMAX; }
rk_is_fp_min_max_num :: (k: Recur_Kind) -> bool { return k == .FMINNUM || k == .FMAXNUM; }
rk_is_fp_min_max :: (k: Recur_Kind) -> bool {
    return k == .FMIN || k == .FMAX || k == .FMINIMUM || k == .FMAXIMUM || k == .FMINIMUMNUM || k == .FMAXIMUMNUM || rk_is_fp_min_max_num(k);
}
rk_is_min_max :: (k: Recur_Kind) -> bool { return rk_is_int_min_max(k) || rk_is_fp_min_max(k); }
rk_is_any_of :: (k: Recur_Kind) -> bool { return k == .ANYOF; }
rk_is_find_iv :: (k: Recur_Kind) -> bool { return k == .FINDIV; }
rk_is_find_last :: (k: Recur_Kind) -> bool { return k == .FINDLAST; }
rk_is_find :: (k: Recur_Kind) -> bool { return k == .FINDLAST || k == .FINDIV; }

// RecurrenceDescriptor::getOpcode
rk_opcode :: (k: Recur_Kind) -> Opcode {
    if k == {
        case .SUB; return .SUB;
        case .ADD_CHAIN_WITH_SUBS; #through; case .ADD; return .ADD;
        case .MUL; return .MUL;
        case .OR; return .OR;
        case .AND; return .AND;
        case .XOR; return .XOR;
        case .FMUL; return .FMUL;
        case .FMULADD; #through; case .FADD_CHAIN_WITH_SUBS; #through; case .FADD; return .FADD;
        case .FSUB; return .FSUB;
        case .SMAX; #through; case .SMIN; #through; case .UMAX; #through; case .UMIN; return .ICMP;
        case .FMAX; #through; case .FMIN; #through; case .FMAXIMUM; #through; case .FMINIMUM; #through;
        case .FMAXIMUMNUM; #through; case .FMINIMUMNUM; return .FCMP;
    }
    fatal("internal: Unknown recurrence operation");
    return .ADD;
}

is_fmul_add_intrinsic :: (i: Value_Id) -> bool { return is_inst(i) && inst_op(i) == .CALL && call_iid(i) == IID_FMULADD; }
ivd_has_allow_reassoc :: (i: Value_Id) -> bool { return (inst_fmf(i) & FMF_REASSOC) != 0; }
ivd_is_fast :: (i: Value_Id) -> bool { return is_fp_math_operator(i) && inst_fmf(i) == FMF_ALL; }

Iset :: Table(Value_Id, bool);
iset_new :: () -> Iset { s: Iset; s.allocator = temp; return s; }
iset_has :: (s: *Iset, v: Value_Id) -> bool { if v == NONE return false; return table_contains(s, v); }
iset_insert :: (s: *Iset, v: Value_Id) -> bool { if table_contains(s, v) return false; table_set(s, v, true); return true; }

// RecurrenceDescriptor::areAllUsesIn (the operands, despite the name)
rdx_are_all_uses_in :: (i: Value_Id, set: *Iset) -> bool {
    for k: 0..cast(s64) nops(i) - 1 {
        o := op(i, cast(u32) k);
        if !is_inst(o) || !iset_has(set, o) return false;
    }
    return true;
}
rdx_has_multiple_uses_of :: (i: Value_Id, set: *Iset, max_uses: u32) -> bool {
    n: u32 = 0;
    for k: 0..cast(s64) nops(i) - 1 {
        o := op(i, cast(u32) k);
        if is_inst(o) && iset_has(set, o) n += 1;
        if n > max_uses return true;
    }
    return false;
}

// lookThroughAnd
rdx_look_through_and :: (phi: Value_Id, rt: *Type_Id, visited: *Iset, ci: *[..] Value_Id) -> Value_Id {
    if !has_one_use(phi) return phi;
    j := ir.u_user[ir.v_first_use[phi]];
    if is_inst(j) && inst_op(j) == .AND && is_inst(op(j, 0)) {
        ok, m := pm_apint(op(j, 1));
        if ok {
            bits := ap_exact_log2(ap_add(m, ap_one(m.bits)));
            if bits > 0 {
                rt.* = type_int(cast(u32) bits);
                iset_insert(visited, phi);
                if !array_find(ci.*, j) array_add(ci, j);
                return j;
            }
        }
    }
    return phi;
}

// computeRecurrenceType
rdx_compute_recurrence_type :: (exit: Value_Id, db: *Demanded_Bits, ac: *Assumption_Cache, dt: *Dom_Tree) -> (Type_Id, bool) {
    is_signed := false;
    ty_bits := dl_type_size_bits(vtype(exit));
    max_bw := ty_bits;
    if db {
        mask := db_demanded_bits(db, exit);
        max_bw = cast(u64) (mask.bits - ap_clz(mask));
    }
    if max_bw == ty_bits && ac && dt {
        nsb := num_sign_bits_ctx(exit, NONE, dt, ac);
        max_bw = ty_bits - nsb;
        kb := known_bits(exit, .{});
        if !kb_is_non_negative(kb) { is_signed = true; max_bw += 1; }
    }
    max_bw = bit_ceil(max_bw);
    return type_int(cast(u32) max_bw), is_signed;
}

// collectCastInstrs
rdx_collect_cast_instrs :: (li: *Loop_Info, l: Loop_Id, exit: Value_Id, rt: Type_Id, casts: *[..] Value_Id) -> u32 {
    wl: [..] Value_Id; wl.allocator = temp;
    visited := iset_new();
    array_add(*wl, exit);
    min_w: u32 = 0xFFFF_FFFF;
    while wl.count {
        val := pop(*wl);
        iset_insert(*visited, val);
        if is_cast_op(inst_op(val)) {
            src_ty := vtype(op(val, 0));
            if src_ty == rt { if !array_find(casts.*, val) array_add(casts, val); continue; }
            if vtype(val) == rt { min_w = min(min_w, type_bits(scalar_type(src_ty))); continue; }
        }
        for k: 0..cast(s64) nops(val) - 1 {
            o := op(val, cast(u32) k);
            if is_inst(o) && li_contains_inst(li, l, o) && !iset_has(*visited, o) array_add(*wl, o);
        }
    }
    return min_w;
}

// checkOrderedReduction
rdx_check_ordered :: (kind: Recur_Kind, exact_fp: Value_Id, exit: Value_Id, phi: Value_Id) -> bool {
    if kind != .FADD && kind != .FMULADD return false;
    if kind == .FADD && inst_op(exit) != .FADD return false;
    if kind == .FMULADD && !is_fmul_add_intrinsic(exit) return false;
    if exit != exact_fp || has_n_uses_or_more(exit, 3) return false;
    op0 := op(exit, 0); op1 := op(exit, 1);
    if kind == .FADD && op0 != phi && op1 != phi return false;
    if kind == .FMULADD && op(exit, 2) != phi return false;
    return true;
}

// collectMinMaxFMF
rdx_collect_min_max_fmf :: (v: Value_Id) -> u32 {
    fmf := inst_fmf(v);
    if inst_op(v) == .SELECT {
        c := op(v, 0);
        if is_inst(c) && inst_op(c) == .FCMP fmf |= inst_fmf(c);
    }
    return fmf;
}

// hasRequiredFastMathFlags: (ok, fmf); may change rk
rdx_has_required_fmf :: (fpop: Value_Id, rk: *Recur_Kind) -> (bool, u32) {
    f := inst_fmf(fpop);
    if (f & FMF_NNAN) && (f & FMF_NSZ) return true, rdx_collect_min_max_fmf(fpop);
    if rk.* == {
        case .FMINIMUM; #through; case .FMAXIMUM; #through; case .FMINIMUMNUM; #through; case .FMAXIMUMNUM;
        case .FMAX;
            ok, _, _ := pm_intrinsic2(fpop, IID_MAXNUM);
            if !ok return false, 0;
            rk.* = .FMAXNUM;
        case .FMIN;
            ok, _, _ := pm_intrinsic2(fpop, IID_MINNUM);
            if !ok return false, 0;
            rk.* = .FMINNUM;
        case; return false, 0;
    }
    return true, rdx_collect_min_max_fmf(fpop);
}

// getMinMaxRecurrence's GetMinMaxRK
rdx_min_max_rk :: (v: Value_Id) -> (Recur_Kind, Value_Id, Value_Id) {
    if !is_inst(v) return .NONE, NONE, NONE;
    ok, a, b := pm_max_min(v, IID_UMIN); if ok return .UMIN, a, b;
    ok, a, b = pm_max_min(v, IID_UMAX); if ok return .UMAX, a, b;
    ok, a, b = pm_max_min(v, IID_SMAX); if ok return .SMAX, a, b;
    ok, a, b = pm_max_min(v, IID_SMIN); if ok return .SMIN, a, b;
    ok, a, b = pm_ord_or_unord_fmin(v); if ok return .FMIN, a, b;
    ok, a, b = pm_intrinsic2(v, IID_MINNUM); if ok return .FMIN, a, b;
    ok, a, b = pm_ord_or_unord_fmax(v); if ok return .FMAX, a, b;
    ok, a, b = pm_intrinsic2(v, IID_MAXNUM); if ok return .FMAX, a, b;
    ok, a, b = pm_intrinsic2(v, IID_MINIMUM); if ok return .FMINIMUM, a, b;
    ok, a, b = pm_intrinsic2(v, IID_MAXIMUM); if ok return .FMAXIMUM, a, b;
    ok, a, b = pm_intrinsic2(v, IID_MINIMUMNUM); if ok return .FMINIMUMNUM, a, b;
    ok, a, b = pm_intrinsic2(v, IID_MAXIMUMNUM); if ok return .FMAXIMUMNUM, a, b;
    return .NONE, NONE, NONE;
}

// getMinMaxRecurrence
rdx_get_min_max_recurrence :: (phi: Value_Id, li: *Loop_Info, l: Loop_Id) -> Rdx_Desc {
    none: Rdx_Desc;
    ty := vtype(phi);
    latch := li_loop_latch(li, l);
    if phi_num_incoming(phi) != 2 || inst_block(phi) != li_header(li, l) ||
       (type_kind(ty) != .INT && !is_fp_type(ty)) || latch == NONE return none;
    fmf: u32 = FMF_ALL;
    be := phi_incoming_value_for_block(phi, latch);
    rk := Recur_Kind.NONE;
    wl: [..] Value_Id; wl.allocator = temp;
    array_add(*wl, be);
    chain := iset_new();
    chain_order: [..] Value_Id; chain_order.allocator = temp;
    chain_add :: (s: *Iset, order: *[..] Value_Id, v: Value_Id) -> bool {
        if !iset_insert(s, v) return false;
        array_add(order, v);
        return true;
    }
    chain_add(*chain, *chain_order, phi);
    while wl.count {
        cur := pop(*wl);
        if !chain_add(*chain, *chain_order, cur) continue;
        if !is_inst(cur) || !li_contains_inst(li, l, cur) return none;
        if inst_op(cur) == .PHI {
            for k: 0..cast(s64) nops(cur) - 1 array_add(*wl, op(cur, cast(u32) k));
            continue;
        }
        cur_rk, a, b := rdx_min_max_rk(cur);
        if cur_rk == .NONE || (rk != .NONE && cur_rk != rk) return none;
        rk = cur_rk;
        if rk_is_fp_min_max(cur_rk) {
            ok, cf := rdx_has_required_fmf(cur, *rk);
            if !ok return none;
            fmf &= cf;
        }
        if inst_op(cur) == .SELECT chain_add(*chain, *chain_order, op(cur, 0));
        if a == phi || b == phi continue;
        a_rk, _, _ := rdx_min_max_rk(a);
        b_rk, _, _ := rdx_min_max_rk(b);
        am := is_inst(a) && li_contains_inst(li, l, a) && a_rk == rk;
        bm := is_inst(b) && li_contains_inst(li, l, b) && b_rk == rk;
        if am == bm return none;
        array_add(*wl, ifx am then a else b);
    }
    // argmin/argmax: phi users outside the chain that are not min/max operations
    invalid := false;
    u := ir.v_first_use[phi];
    while u != NONE {
        usr := ir.u_user[u];
        urk, _, _ := rdx_min_max_rk(usr);
        if !iset_has(*chain, usr) && li_contains_inst(li, l, usr) && urk == .NONE { invalid = true; break; }
        u = ir.u_next[u];
    }
    pre := li_loop_preheader(li, l);
    if invalid {
        if !rk_is_int_min_max(rk) || !has_one_use(be) return none;
        r: Rdx_Desc;
        r.start = phi_incoming_value_for_block(phi, pre);
        r.kind = rk; r.fmf = 0; r.recur_type = vtype(phi); r.phi_has_uses_outside_chain = true;
        r.casts.allocator = temp;
        return r;
    }
    stores: [..] Value_Id; stores.allocator = temp;
    for v: chain_order {
        uu := ir.v_first_use[v];
        while uu != NONE {
            usr := ir.u_user[uu];
            uu = ir.u_next[uu];
            if iset_has(*chain, usr) continue;
            if !is_inst(usr) || (!li_contains_inst(li, l, usr) && v != be) return none;
            if !li_contains_inst(li, l, usr) continue;
            if inst_op(usr) == .STORE { array_add(*stores, usr); continue; }
            urk, _, _ := rdx_min_max_rk(usr);
            if urk != rk return none;
            w := ir.v_first_use[usr];
            while w != NONE {
                iu := ir.u_user[w];
                if is_inst(iu) && inst_op(iu) == .STORE array_add(*stores, iu);
                else if !iset_has(*chain, iu) return none;
                w = ir.u_next[w];
            }
        }
    }
    istore: Value_Id = NONE;
    store_ptr: Scev_Id = SCEV_NULL;
    for si: stores {
        p := sc_get_scev(op(si, 1));
        if !sc_is_loop_invariant(p, l) || (store_ptr != SCEV_NULL && store_ptr != p) return none;
        store_ptr = p;
        if istore == NONE istore = si;
        else if inst_block(istore) != inst_block(si) return none;
        else if comes_before(istore, si) istore = si;
    }
    r: Rdx_Desc;
    r.start = phi_incoming_value_for_block(phi, pre);
    r.exit = be; r.intermediate_store = istore; r.kind = rk; r.fmf = fmf; r.recur_type = vtype(phi);
    r.casts.allocator = temp;
    return r;
}

// isFindLastLikePhi
rdx_is_find_last_like_phi :: (phi: Value_Id, header_phi: Value_Id, rdx: *Iset) -> bool {
    n := 0;
    for k: 0..cast(s64) nops(phi) - 1 {
        o := op(phi, cast(u32) k);
        if !(is_inst(o) && iset_has(rdx, o)) {
            n += 1;
            if n > 1 return false;
        } else if o != header_phi return false;
    }
    return n == 1;
}

// InstDesc
Rdx_Inst_Desc :: struct { is_recurrence: bool; pattern_last: Value_Id = NONE; kind: Recur_Kind; exact_fp: Value_Id = NONE; }
idesc :: (is_recur: bool, i: Value_Id, exact_fp: Value_Id = NONE) -> Rdx_Inst_Desc { return .{is_recur, i, .NONE, exact_fp}; }
idesc_kind :: (i: Value_Id, k: Recur_Kind, exact_fp: Value_Id = NONE) -> Rdx_Inst_Desc { return .{true, i, k, exact_fp}; }

// isAnyOfPattern
rdx_is_any_of_pattern :: (li: *Loop_Info, l: Loop_Id, orig_phi: Value_Id, i: Value_Id, prev: Rdx_Inst_Desc) -> Rdx_Inst_Desc {
    if is_cmp_inst(i) && has_one_use(i) {
        usr := ir.u_user[ir.v_first_use[i]];
        if is_inst(usr) && inst_op(usr) == .SELECT return idesc_kind(usr, prev.kind);
    }
    if !(is_inst(i) && inst_op(i) == .SELECT && is_cmp_inst(op(i, 0))) return idesc(false, i);
    non_phi: Value_Id = NONE;
    if op(i, 1) == orig_phi non_phi = op(i, 2);
    else if op(i, 2) == orig_phi non_phi = op(i, 1);
    else return idesc(false, i);
    if !li_is_loop_invariant(li, l, non_phi) return idesc(false, i);
    return idesc_kind(i, .ANYOF);
}

// isFindPattern
rdx_is_find_pattern :: (orig_phi: Value_Id, i: Value_Id) -> Rdx_Inst_Desc {
    if !has_one_use(orig_phi) return idesc(false, i);
    if !(inst_op(i) == .SELECT && is_cmp_inst(op(i, 0)) && (op(i, 2) == orig_phi || op(i, 1) == orig_phi)) return idesc(false, i);
    return idesc_kind(i, .FINDLAST);
}

// isConditionalRdxPattern
rdx_is_conditional_rdx_pattern :: (i: Value_Id) -> Rdx_Inst_Desc {
    if !(is_inst(i) && inst_op(i) == .SELECT && is_cmp_inst(op(i, 0)) && has_one_use(op(i, 0))) return idesc(false, i);
    tv := op(i, 1); fv := op(i, 2);
    tphi := is_phi(tv); fphi := is_phi(fv);
    if (tphi && fphi) || (!tphi && !fphi) return idesc(false, i);
    i1 := ifx tphi then fv else tv;
    if !is_inst(i1) || !is_binary_op(inst_op(i1)) return idesc(false, i);
    o := inst_op(i1);
    if !(((o == .FADD || o == .FSUB) && ivd_is_fast(i1)) || (o == .FMUL && ivd_is_fast(i1)) || o == .ADD || o == .SUB || o == .MUL)
        return idesc(false, i);
    op1 := op(i1, 0); op2 := op(i1, 1);
    iphi := ifx is_phi(op1) then op1 else op2;
    if !is_inst(iphi) || iphi != fv return idesc(false, i);
    return idesc(true, i);
}

// isRecurrenceInstr
rdx_is_recurrence_instr :: (li: *Loop_Info, l: Loop_Id, orig_phi: Value_Id, i: Value_Id, kind: Recur_Kind, prev: Rdx_Inst_Desc, has_se: bool) -> Rdx_Inst_Desc {
    reassoc_exact :: (i: Value_Id) -> Value_Id { return ifx ivd_has_allow_reassoc(i) then NONE else i; }
    o := inst_op(i);
    if o == {
        case .PHI; return idesc_kind(i, prev.kind, prev.exact_fp);
        case .SUB; return idesc(kind == .SUB || kind == .ADD_CHAIN_WITH_SUBS, i);
        case .ADD; return idesc(kind == .ADD || kind == .ADD_CHAIN_WITH_SUBS, i);
        case .MUL; return idesc(kind == .MUL, i);
        case .AND; return idesc(kind == .AND, i);
        case .OR; return idesc(kind == .OR, i);
        case .XOR; return idesc(kind == .XOR, i);
        case .FDIV; #through;
        case .FMUL; return idesc(kind == .FMUL, i, reassoc_exact(i));
        case .FSUB; return idesc(kind == .FSUB || kind == .FADD_CHAIN_WITH_SUBS, i, reassoc_exact(i));
        case .FADD; return idesc(kind == .FADD || kind == .FADD_CHAIN_WITH_SUBS, i, reassoc_exact(i));
        case .SELECT;
            if rk_is_sub(kind) || kind == .FADD || kind == .FMUL || kind == .ADD || kind == .MUL || kind == .ADD_CHAIN_WITH_SUBS ||
               kind == .FADD_CHAIN_WITH_SUBS
                return rdx_is_conditional_rdx_pattern(i);
            if rk_is_find(kind) && has_se return rdx_is_find_pattern(orig_phi, i);
            #through;
        case .FCMP; #through; case .ICMP; #through; case .CALL;
            if rk_is_any_of(kind) return rdx_is_any_of_pattern(li, l, orig_phi, i, prev);
            if is_fmul_add_intrinsic(i) return idesc(kind == .FMULADD, i, reassoc_exact(i));
            return idesc(false, i);
    }
    return idesc(false, i);
}

// RecurrenceDescriptor::AddReductionVar
rdx_add_reduction_var :: (phi: Value_Id, kind_in: Recur_Kind, li: *Loop_Info, l: Loop_Id, out: *Rdx_Desc, db: *Demanded_Bits,
                          ac: *Assumption_Cache, dt: *Dom_Tree, has_se: bool) -> bool {
    kind := kind_in;
    if phi_num_incoming(phi) != 2 return false;
    if inst_block(phi) != li_header(li, l) return false;
    pre := li_loop_preheader(li, l);
    if pre == NONE return false;
    rdx_start := phi_incoming_value_for_block(phi, pre);
    exit_inst: Value_Id = NONE;
    istore: Value_Id = NONE;
    found_redux_op := false;
    found_start_phi := false;
    num_cmp_select := 0;
    redux := idesc(false, NONE);
    found_find_last_like_phi := false;
    rt := vtype(phi);
    casts: [..] Value_Id; casts.allocator = temp;
    start := phi;
    is_signed := false;
    visited := iset_new();
    wl: [..] Value_Id; wl.allocator = temp;
    sty := scalar_type(rt);
    if kind == .FINDLAST {
        if !is_fp_type(sty) && type_kind(sty) != .INT && type_kind(sty) != .PTR return false;
    } else if is_fp_type(sty) {
        if !rk_is_floating_point(kind) return false;
    } else if type_kind(sty) == .INT {
        if !rk_is_integer(kind) return false;
        start = rdx_look_through_and(phi, *rt, *visited, *casts);
    } else return false;
    array_add(*wl, start);
    iset_insert(*visited, start);
    fmf: u32 = FMF_ALL;
    exact_fp: Value_Id = NONE;
    while wl.count {
        cur := pop(*wl);
        if inst_op(cur) == .STORE {
            if !has_se return false;
            ptr_s := sc_get_scev(op(cur, 1));
            if istore != NONE {
                other := sc_get_scev(op(istore, 1));
                if other != ptr_s return false;
            }
            if !sc_is_loop_invariant(ptr_s, l) return false;
            istore = cur;
            continue;
        }
        if ir.v_first_use[cur] == NONE return false;
        is_a_phi := inst_op(cur) == .PHI;
        if cur != phi && is_a_phi && inst_block(cur) == inst_block(phi) return false;
        if !ic_inst_is_commutative(cur) && !is_a_phi && inst_op(cur) != .SELECT && !is_cmp_inst(cur) {
            o0 := op(cur, 0);
            if !(is_inst(o0) && iset_has(*visited, o0)) return false;
        }
        if cur != start {
            redux = rdx_is_recurrence_instr(li, l, phi, cur, kind, redux, has_se);
            if exact_fp == NONE exact_fp = redux.exact_fp;
            if !redux.is_recurrence return false;
            if is_fp_math_operator(redux.pattern_last) && !is_a_phi fmf &= rdx_collect_min_max_fmf(redux.pattern_last);
            if redux.kind != .NONE kind = redux.kind;
        }
        is_a_select := inst_op(cur) == .SELECT;
        if is_a_select && (kind == .FADD || kind == .FMUL) && rdx_has_multiple_uses_of(cur, *visited, 2) return false;
        if !is_a_phi && !is_a_select && !rk_is_any_of(kind) && rdx_has_multiple_uses_of(cur, *visited, 1) return false;
        if is_a_phi && cur != phi {
            if !rdx_are_all_uses_in(cur, *visited) {
                found_find_last_like_phi = kind == .FINDLAST && !found_find_last_like_phi && rdx_is_find_last_like_phi(cur, phi, *visited);
                if !found_find_last_like_phi return false;
            }
        }
        if rk_is_any_of(kind) && is_a_select num_cmp_select += 1;
        found_redux_op |= (!is_a_phi || found_find_last_like_phi) && cur != start;
        non_phis: [..] Value_Id; non_phis.allocator = temp;
        phis: [..] Value_Id; phis.allocator = temp;
        u := ir.v_first_use[cur];
        while u != NONE {
            ui := ir.u_user[u];
            u = ir.u_next[u];
            if is_fmul_add_intrinsic(ui) && (cur == op(ui, 0) || cur == op(ui, 1)) return false;
            if !li_contains(li, l, inst_block(ui)) {
                if exit_inst == cur continue;
                if exit_inst != NONE || cur == phi return false;
                in_phi := false;
                for k: 0..cast(s64) nops(phi) - 1 if op(phi, cast(u32) k) == cur in_phi = true;
                if !in_phi return false;
                exit_inst = cur;
                continue;
            }
            if iset_insert(*visited, ui) {
                if inst_op(ui) == .PHI array_add(*phis, ui);
                else {
                    if inst_op(ui) == .STORE && op(ui, 1) == cur return false;
                    array_add(*non_phis, ui);
                }
            } else if inst_op(ui) != .PHI && !rdx_is_conditional_rdx_pattern(ui).is_recurrence &&
                      !rdx_is_any_of_pattern(li, l, phi, ui, idesc(false, NONE)).is_recurrence
                return false;
            if ui == phi found_start_phi = true;
        }
        for phis array_add(*wl, it);
        for non_phis array_add(*wl, it);
    }
    if rk_is_any_of(kind) && num_cmp_select != 1 return false;
    if istore != NONE {
        sv := op(istore, 0);
        in_phi := false;
        for k: 0..cast(s64) nops(phi) - 1 if op(phi, cast(u32) k) == sv in_phi = true;
        if !in_phi return false;
        if exit_inst != NONE && sv != exit_inst return false;
        if exit_inst == NONE exit_inst = sv;
    }
    if !found_start_phi || !found_redux_op || exit_inst == NONE return false;
    is_ordered := rdx_check_ordered(kind, exact_fp, exit_inst, phi);
    if start != phi {
        computed, sgn := rdx_compute_recurrence_type(exit_inst, db, ac, dt);
        is_signed = sgn;
        if computed != rt return false;
    }
    min_w := rdx_collect_cast_instrs(li, l, exit_inst, rt, *casts);
    r: Rdx_Desc;
    r.start = rdx_start; r.exit = exit_inst; r.intermediate_store = istore; r.kind = kind; r.fmf = fmf; r.exact_fp = exact_fp;
    r.recur_type = rt; r.is_signed = is_signed; r.is_ordered = is_ordered; r.casts = casts; r.min_width_cast = min_w;
    out.* = r;
    return true;
}

// RecurrenceDescriptor::isReductionPHI
rdx_is_reduction_phi :: (phi: Value_Id, li: *Loop_Info, l: Loop_Id, out: *Rdx_Desc, db: *Demanded_Bits, ac: *Assumption_Cache,
                         dt: *Dom_Tree, has_se: bool) -> bool {
    for k: Recur_Kind.[.ADD, .SUB, .ADD_CHAIN_WITH_SUBS, .MUL, .OR, .AND, .XOR]
        if rdx_add_reduction_var(phi, k, li, l, out, db, ac, dt, has_se) return true;
    rd := rdx_get_min_max_recurrence(phi, li, l);
    if rd.kind != .NONE { out.* = rd; return true; }
    for k: Recur_Kind.[.ANYOF, .FINDLAST, .FMUL, .FSUB, .FADD, .FADD_CHAIN_WITH_SUBS, .FMULADD]
        if rdx_add_reduction_var(phi, k, li, l, out, db, ac, dt, has_se) return true;
    return false;
}

// RecurrenceDescriptor::isFixedOrderRecurrence
rdx_is_fixed_order_recurrence :: (phi: Value_Id, li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree) -> bool {
    if inst_block(phi) != li_header(li, l) || phi_num_incoming(phi) != 2 return false;
    pre := li_loop_preheader(li, l);
    latch := li_loop_latch(li, l);
    if pre == NONE || latch == NONE return false;
    if phi_block_index(phi, pre) < 0 || phi_block_index(phi, latch) < 0 return false;
    previous := phi_incoming_value_for_block(phi, latch);
    if !is_inst(previous) previous = NONE;
    seen_phis := iset_new();
    while previous != NONE && inst_op(previous) == .PHI {
        if inst_block(previous) != inst_block(phi) return false;
        if !iset_insert(*seen_phis, previous) return false;
        previous = phi_incoming_value_for_block(previous, latch);
        if !is_inst(previous) previous = NONE;
    }
    if previous == NONE || !li_contains_inst(li, l, previous) || inst_op(previous) == .PHI return false;
    seen := iset_new();
    phi_bb := inst_block(phi);
    wl: [..] Value_Id; wl.allocator = temp;
    array_add(*wl, phi);
    while wl.count {
        cur := pop(*wl);
        u := ir.v_first_use[cur];
        while u != NONE {
            sc := ir.u_user[u];
            u = ir.u_next[u];
            if previous == sc return false;
            if !iset_insert(*seen, sc) continue;
            if dt_dominates_inst(dt, previous, sc) continue;
            if inst_block(sc) != phi_bb || may_have_side_effects(sc) || may_read_from_memory(sc) || is_terminator(inst_op(sc)) return false;
            if inst_op(sc) == .PHI continue;
            array_add(*wl, sc);
        }
    }
    return true;
}

// RecurrenceDescriptor::getReductionOpChain
rdx_get_reduction_op_chain :: (r: *Rdx_Desc, phi: Value_Id) -> [..] Value_Id {
    ops: [..] Value_Id; ops.allocator = temp;
    is_mm := rk_is_min_max(r.kind);
    expected: s64 = ifx is_mm then 2 else 1;
    next_inst :: (cur: Value_Id, is_mm: bool) -> Value_Id {
        u := ir.v_first_use[cur];
        while u != NONE {
            ui := ir.u_user[u];
            u = ir.u_next[u];
            if inst_op(ui) == .PHI continue;
            if is_mm { if inst_op(ui) == .SELECT return ui; continue; }
            return ui;
        }
        return NONE;
    }
    correct_opcode :: (cur: Value_Id, r: *Rdx_Desc, is_mm: bool) -> bool {
        if is_mm { sp, _, _ := match_select_pattern(cur); return spf_is_min_or_max(sp.flavor); }
        if is_fmul_add_intrinsic(cur) return true;
        if inst_op(cur) == .SUB && r.kind == .ADD_CHAIN_WITH_SUBS return true;
        if inst_op(cur) == .FSUB && r.kind == .FADD_CHAIN_WITH_SUBS return true;
        return inst_op(cur) == rk_opcode(r.kind);
    }
    extra: s64 = 0;
    rdx := r.exit;
    if inst_op(r.exit) == .PHI {
        ep := r.exit;
        if phi_num_incoming(ep) != 2 return ops;
        inc0 := op(ep, 0); inc1 := op(ep, 1);
        chain: Value_Id = NONE;
        if inc0 == phi chain = inc1;
        else if inc1 == phi chain = inc0;
        else return ops;
        if !is_inst(chain) chain = NONE;
        rdx = chain;
        extra = 1;
    }
    if rdx == NONE || !correct_opcode(rdx, r, is_mm) || !has_n_uses(r.exit, 2) return ops;
    if !has_n_uses(phi, expected + extra) return ops;
    cur := next_inst(phi, is_mm);
    while cur != rdx {
        if cur == NONE || !correct_opcode(cur, r, is_mm) || !has_n_uses(cur, expected) { ops.count = 0; return ops; }
        array_add(*ops, cur);
        cur = next_inst(cur, is_mm);
    }
    array_add(*ops, cur);
    return ops;
}

// ---------------------------------------------------------------- InductionDescriptor

Ind_Kind :: enum u8 { NONE; INT; PTR; FP; }
Ind_Desc :: struct {
    start: Value_Id = NONE;
    kind: Ind_Kind;
    step: Scev_Id = SCEV_NULL;
    bop: Value_Id = NONE;            // InductionBinOp (a BinaryOperator) or NONE
    casts: [..] Value_Id;            // RedundantCasts
    preds: [..] u32;                 // NoWrapPredicates
}
ind_const_int_step :: (d: *Ind_Desc) -> Value_Id {
    if d.step != SCEV_NULL && sc_is_const(d.step) return sc_value(d.step);
    return NONE;
}
ind_exact_fp_math_inst :: (d: *Ind_Desc) -> Value_Id {
    if d.kind == .FP && d.bop != NONE && !ivd_has_allow_reassoc(d.bop) return d.bop;
    return NONE;
}
ind_opcode :: (d: *Ind_Desc) -> (bool, Opcode) { if d.bop == NONE return false, .ADD; return true, inst_op(d.bop); }
ind_new :: (start: Value_Id, k: Ind_Kind, step: Scev_Id, bop: Value_Id = NONE, casts: [] Value_Id = .[], preds: [] u32 = .[]) -> Ind_Desc {
    d: Ind_Desc;
    d.start = start; d.kind = k; d.step = step; d.bop = bop;
    d.casts.allocator = temp; d.preds.allocator = temp;
    for casts array_add(*d.casts, it);
    for preds array_add(*d.preds, it);
    return d;
}
// InductionDescriptor::getCanonicalIntInduction
ind_canonical_int :: (ty: Type_Id) -> Ind_Desc { return ind_new(const_null_value(ty), .INT, sc_get_one(ty)); }

ivd_is_binary_operator :: (v: Value_Id) -> bool { return is_inst(v) && is_binary_op(inst_op(v)); }

// InductionDescriptor::isFPInductionPHI
ind_is_fp_induction_phi :: (phi: Value_Id, li: *Loop_Info, l: Loop_Id, d: *Ind_Desc) -> bool {
    if li_header(li, l) != inst_block(phi) return false;
    if phi_num_incoming(phi) != 2 return false;
    be, sv: Value_Id;
    if li_contains(li, l, phi_block(phi, 0)) { be = phi_value(phi, 0); sv = phi_value(phi, 1); }
    else { be = phi_value(phi, 1); sv = phi_value(phi, 0); }
    if !ivd_is_binary_operator(be) return false;
    addend: Value_Id = NONE;
    if inst_op(be) == .FADD {
        if op(be, 0) == phi addend = op(be, 1);
        else if op(be, 1) == phi addend = op(be, 0);
    } else if inst_op(be) == .FSUB {
        if op(be, 0) == phi addend = op(be, 1);
    }
    if addend == NONE return false;
    if is_inst(addend) && li_contains_inst(li, l, addend) return false;
    d.* = ind_new(sv, .FP, sc_get_unknown(addend), be);
    return true;
}

// PredicatedScalarEvolution::areAddRecsEqualWithPreds
pse_are_add_recs_equal_with_preds :: (p: *Pse, ar1: Scev_Id, ar2: Scev_Id, no_wrap: [] u32) -> bool {
    if ar1 == ar2 return true;
    all: [..] u32; all.allocator = temp;
    for p.preds array_add(*all, it);
    for no_wrap sc_union_add(*all, it);
    eq :: (a: Scev_Id, b: Scev_Id, all: [] u32) -> bool {
        if a != b && !sc_union_implies(all, sc_get_equal_predicate(a, b)) && !sc_union_implies(all, sc_get_equal_predicate(b, a)) return false;
        return true;
    }
    return eq(sc_start(ar1), sc_start(ar2), all) && eq(sc_step_recurrence(ar1), sc_step_recurrence(ar2), all);
}

// getCastsForInductionPHI
ind_get_casts_for_induction_phi :: (pse: *Pse, li: *Loop_Info, phi_scev: Scev_Id, ar: Scev_Id, casts: *[..] Value_Id, preds: [] u32) -> bool {
    pn := sc_value(phi_scev);
    l := sc_loop(ar);
    get_def :: (v: Value_Id, li: *Loop_Info, l: Loop_Id) -> Value_Id {
        if !ivd_is_binary_operator(v) return NONE;
        o0 := op(v, 0); o1 := op(v, 1);
        if li_is_loop_invariant(li, l, o0) return o1;
        if li_is_loop_invariant(li, l, o1) return o0;
        return NONE;
    }
    latch := li_loop_latch(li, l);
    if latch == NONE return false;
    val := phi_incoming_value_for_block(pn, latch);
    if val == NONE return false;
    in_cast := false;
    i := ifx is_inst(val) then val else NONE;
    while val != pn {
        if i == NONE || !li_contains_inst(li, l, i) return false;
        rw := sc_rewrite_using_predicate(sc_get_scev(val), l, preds);
        if sc_is_addrec(rw) && pse_are_add_recs_equal_with_preds(pse, rw, ar, preds) in_cast = true;
        if in_cast {
            if casts.count && !has_one_use(i) return false;
            array_add(casts, i);
        }
        val = get_def(val, li, l);
        if val == NONE return false;
        i = ifx is_inst(val) then val else NONE;
    }
    return in_cast;
}

// InductionDescriptor::isInductionPHI(Phi, L, SE, D, Preds, Expr, CastsToIgnore)
ind_is_induction_phi_se :: (phi: Value_Id, li: *Loop_Info, l: Loop_Id, d: *Ind_Desc, preds: [] u32, expr: Scev_Id, casts: [] Value_Id = .[]) -> bool {
    ty := vtype(phi);
    if !sc_is_scevable(ty) return false;
    phi_scev := ifx expr != SCEV_NULL then expr else sc_get_scev(phi);
    if !(sc_is_addrec(phi_scev) && sc_is_affine(phi_scev) && sc_loop(phi_scev) == l) return false;
    step := sc_op(phi_scev, 1);
    pre := li_loop_preheader(li, l);
    if pre == NONE return false;
    sv := phi_incoming_value_for_block(phi, pre);
    latch := li_loop_latch(li, l);
    if latch == NONE return false;
    if type_kind(ty) == .INT {
        b := phi_incoming_value_for_block(phi, latch);
        bop := ifx ivd_is_binary_operator(b) then b else NONE;
        d.* = ind_new(sv, .INT, step, bop, casts, preds);
        return true;
    }
    d.* = ind_new(sv, .PTR, step, NONE, .[], preds);
    return true;
}

// InductionDescriptor::isInductionPHI(Phi, L, PSE, D, Assume)
ind_is_induction_phi :: (phi: Value_Id, li: *Loop_Info, l: Loop_Id, pse: *Pse, d: *Ind_Desc, assume := false) -> bool {
    ty := vtype(phi);
    k := type_kind(ty);
    if k != .INT && k != .PTR && k != .FLOAT && k != .DOUBLE && k != .HALF return false;
    if is_fp_type(ty) return ind_is_fp_induction_phi(phi, li, l, d);
    phi_scev := pse_get_scev(pse, phi);
    ar: Scev_Id = ifx sc_is_addrec(phi_scev) then phi_scev else SCEV_NULL;
    preds: [..] u32; preds.allocator = temp;
    if assume && ar == SCEV_NULL {
        ar = pse_get_as_add_rec(pse, phi, *preds);
        if ar == SCEV_CNC ar = SCEV_NULL;
    }
    if ar == SCEV_NULL return false;
    if phi_scev != ar && sc_is_unknown(phi_scev) {
        casts: [..] Value_Id; casts.allocator = temp;
        if ind_get_casts_for_induction_phi(pse, li, phi_scev, ar, *casts, preds)
            return ind_is_induction_phi_se(phi, li, l, d, preds, ar, casts);
    }
    return ind_is_induction_phi_se(phi, li, l, d, preds, ar);
}
