// IVUsers and print<iv-users>, with the SCEV post-increment normalization.
// Port of llvm/lib/Analysis/IVUsers.cpp (LLVM 23.1.5: isInteresting, IVUseShouldUsePostIncValue,
// AddUsersIfInteresting, AddUser, IVUsers::IVUsers, print, getReplacementExpr), llvm/lib/Transforms/Scalar/
// IVUsersPrinter.cpp and llvm/lib/Analysis/ScalarEvolutionNormalization.cpp (NormalizeDenormalizeRewriter,
// normalizeForPostIncUse(If), denormalizeForPostIncUse).

Iv_Stride_Use :: struct { user: Value_Id; operand: Value_Id; post_inc_loops: [..] Loop_Id; }
Iv_Users :: struct {
    l: Loop_Id;
    processed: Table(Value_Id, bool);
    eph: Table(Value_Id, bool);
    uses: [..] Iv_Stride_Use;
}

// NormalizeDenormalizeRewriter: pred(AR) is "AR's loop is in `loops`", or (normalizeForPostIncUseIf) the
// IVUseShouldUsePostIncValue predicate, which also records the loop
Norm_Ctx :: struct {
    denormalize: bool;
    loops: *[..] Loop_Id;        // PostIncLoopSet (pred: membership), or the use's set (pred: post-inc test)
    by_post_inc: bool;
    user: Value_Id; operand: Value_Id;
}
norm_pred :: (c: *Norm_Ctx, ar: Scev_Id) -> bool {
    l := sc_loop(ar);
    if !c.by_post_inc { for c.loops.* if it == l return true; return false; }
    r := iv_use_should_use_post_inc_value(c.user, c.operand, l);
    if r { found := false; for c.loops.* if it == l found = true; if !found array_add(c.loops, l); }
    return r;
}
normalize_rewrite :: (s: Scev_Id, c: *Norm_Ctx) -> Scev_Id {
    rw: Sc_Rewriter; sc_rewriter_init(*rw);
    rw.data = c;
    rw.hook = (rw: *Sc_Rewriter, s: Scev_Id) -> (bool, Scev_Id) {
        if !sc_is_addrec(s) return false, 0;
        c := cast(*Norm_Ctx) rw.data;
        ops: [..] Scev_Id; ops.allocator = temp;
        for i: 0..cast(s64) sc_nops(s) - 1 array_add(*ops, sc_rewrite(rw, sc_op(s, cast(u32) i)));
        if !norm_pred(c, s) return true, sc_get_add_rec_ops(*ops, sc_loop(s), SF_ANY);
        if c.denormalize {
            for i: 0..ops.count-2 ops[i] = sc_get_add2(ops[i], ops[i+1]);
        } else {
            i := ops.count - 2;
            while i >= 0 { ops[i] = sc_get_minus(ops[i], ops[i+1]); i -= 1; }
        }
        return true, sc_get_add_rec_ops(*ops, sc_loop(s), SF_ANY);
    };
    return sc_rewrite(*rw, s);
}
denormalize_for_post_inc_use :: (s: Scev_Id, loops: *[..] Loop_Id) -> Scev_Id {
    if loops.count == 0 return s;
    c: Norm_Ctx; c.denormalize = true; c.loops = loops;
    return normalize_rewrite(s, *c);
}

// isInteresting
iv_is_interesting :: (s: Scev_Id, i: Value_Id, l: Loop_Id) -> bool {
    if sc_is_addrec(s) {
        if sc_loop(s) == l
            return sc_is_affine(s) || (!li_contains(se.li, l, inst_block(i)) && sc_get_scev_at_scope(s, li_loop_for(se.li, inst_block(i))) != s);
        return iv_is_interesting(sc_start(s), i, l) && !iv_is_interesting(sc_step_recurrence(s), i, l);
    }
    if sc_is_add(s) {
        any := false;
        for k: 0..cast(s64) sc_nops(s) - 1 {
            if iv_is_interesting(sc_op(s, cast(u32) k), i, l) {
                if any return false;
                any = true;
            }
        }
        return any;
    }
    return false;
}

// IVUseShouldUsePostIncValue
iv_use_should_use_post_inc_value :: (user: Value_Id, operand: Value_Id, l: Loop_Id) -> bool {
    if li_contains(se.li, l, inst_block(user)) return false;
    latch := li_loop_latch(se.li, l);
    if latch == NONE return false;
    if dt_dominates(se.dt, latch, inst_block(user)) return true;
    if inst_op(user) != .PHI || operand == NONE return false;
    for k: 0..cast(s64) nops(user) - 1 {
        if phi_value(user, cast(u32) k) == operand && !dt_dominates(se.dt, latch, phi_block(user, cast(u32) k)) return false;
    }
    return true;
}

// AddUsersIfInteresting
iv_add_users_if_interesting :: (iu: *Iv_Users, i: Value_Id) -> bool {
    if table_contains(*iu.processed, i) return true;
    table_set(*iu.processed, i, true);
    if !sc_is_scevable(vtype(i)) return false;
    if inst_op(i) != .PHI && !is_safe_to_speculatively_execute_full(i) return false;
    width := sc_type_bits(vtype(i));
    if width > 64 || !dl_is_legal_integer(cast(u64) width) return false;
    if table_contains(*iu.eph, i) return false;
    ise := sc_get_scev(i);
    if !iv_is_interesting(ise, i, iu.l) return false;
    unique_users: Table(Value_Id, bool); unique_users.allocator = temp;
    u := ir.v_first_use[i];
    while u != NONE {
        user := ir.u_user[u];
        u = ir.u_next[u];
        if table_contains(*unique_users, user) continue;
        table_set(*unique_users, user, true);
        if inst_op(user) == .PHI && table_contains(*iu.processed, user) continue;
        add_user := false;
        if li_loop_for(se.li, inst_block(user)) != iu.l {
            if inst_op(user) == .PHI || table_contains(*iu.processed, user) || !iv_add_users_if_interesting(iu, user) add_user = true;
        } else if table_contains(*iu.processed, user) || !iv_add_users_if_interesting(iu, user) add_user = true;
        if add_user {
            nu: Iv_Stride_Use;
            nu.user = user; nu.operand = i;
            nu.post_inc_loops.allocator = temp;
            array_add(*iu.uses, nu);
            new_use := *iu.uses[iu.uses.count - 1];
            original := ise;
            c: Norm_Ctx; c.by_post_inc = true; c.loops = *new_use.post_inc_loops; c.user = user; c.operand = i;
            ise = normalize_rewrite(ise, *c);
            if original != ise {
                denorm := denormalize_for_post_inc_use(ise, *new_use.post_inc_loops);
                if original != denorm {
                    iu.uses.count -= 1;
                    return false;
                }
            }
        }
    }
    return true;
}

// LoopAnalysisManager::getResult<IVUsersAnalysis>(L, AR), then IVUsers::print (IVUsersPrinterPass)
iv_users_printer_run :: (l: Loop_Id, lar: *Loop_Std_Results) -> Preserved {
    se = lar.se;
    iu: Iv_Users;
    iu.l = l;
    iu.processed.allocator = temp; iu.eph.allocator = temp; iu.uses.allocator = temp;
    collect_ephemeral_values(lar.li, l, lar.ac, *iu.eph);
    i := block_first(li_header(lar.li, l));
    while i != NONE && inst_op(i) == .PHI {
        iv_add_users_if_interesting(*iu, i);
        i = inst_next(i);
    }
    sb: String_Builder; sb.allocator = temp;
    append(*sb, "IV Users for loop ");
    append(*sb, value_as_operand(li_header(lar.li, l)));
    if sc_has_loop_invariant_backedge_taken_count(l) {
        append(*sb, " with backedge-taken count ");
        sc_print(*sb, sc_get_backedge_taken_count(l));
    }
    append(*sb, ":\n");
    for * use: iu.uses {
        append(*sb, "  ");
        append(*sb, value_as_operand(use.operand));
        append(*sb, " = ");
        sc_print(*sb, sc_get_scev(use.operand));
        for pl: use.post_inc_loops {
            append(*sb, " (post-inc with loop ");
            append(*sb, value_as_operand(li_header(lar.li, pl)));
            append(*sb, ")");
        }
        append(*sb, " in  ");
        append(*sb, inst_to_string(use.user));
        append(*sb, "\n");
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}
