// Transforms/Utils/Local.cpp helpers (and the EHPersonalities.cpp queries they need):
// ConstantFoldTerminator, RecursivelyDeleteTriviallyDeadInstructions(V), TryToSimplifyUncondBranchFromEmptyBlock
// (CanPropagatePredecessorsForPHIs, CanRedirectPredsOfEmptyBBToSucc, introduceTooManyPhiEntries,
// redirectValuesFromPredecessorsToPhi), EliminateDuplicatePHINodes, removeUnreachableBlocks (markAliveBlocks),
// changeToCall / createCallMatchingInvoke, removeUnwindEdge, canReplaceOperandWithVariable,
// hoistAllInstructionsInto, classifyEHPersonality / canSimplifyInvokeNoUnwind.
// changeToUnreachable is in pass_loop_simplify.jai (with an optional DTU).

local_opts: struct {
    max_phi_entries_increase_after_removing_empty_block: s64 = 1000;
    phicse_num_phi_small_size: s64 = 32;
};

// IRBuilder pieces SimplifyCFG needs (ConstantFolder semantics)
irb_icmp :: (b: *Irb, pred: u8, l: Value_Id, r: Value_Id, name: string = "") -> Value_Id {
    if irb_is_const(l) && irb_is_const(r) { f := cf_compare(pred, l, r); if f != NONE return f; }
    return irb_insert(b, create_icmp(pred, l, r), name);
}
irb_br :: (b: *Irb, dest: Value_Id) -> Value_Id { return irb_insert(b, create_br(dest)); }
irb_cond_br :: (b: *Irb, c: Value_Id, t: Value_Id, f: Value_Id) -> Value_Id { return irb_insert(b, create_cond_br(c, t, f)); }
// CreateNot: xor V, -1
irb_not :: (b: *Irb, v: Value_Id, name: string = "") -> Value_Id {
    return irb_binop(b, .XOR, v, cf_all_ones(vtype(v)), name);
}

// Instruction::copyMetadata(Src, {kinds})
copy_metadata_kinds :: (dst: Value_Id, src: Value_Id, kinds: [] u32) {
    for kinds {
        m := get_metadata(src, it);
        if m != NONE set_metadata(dst, it, m);
    }
}
MD_ANNOTATION_KIND :: 30;   // FixedMetadataKinds: annotation
md_kind :: (name: string) -> u32 { return md_kind_id(name); }

// RecursivelyDeleteTriviallyDeadInstructions(V)
recursively_delete_trivially_dead_value :: (v: Value_Id) -> bool {
    if !is_inst(v) || has_uses(v) || !is_instruction_trivially_dead(v) return false;
    l: [..] Value_Id; l.allocator = temp;
    array_add(*l, v);
    recursively_delete_trivially_dead_instructions(l);
    return true;
}

// ---------------------------------------------------------------- ConstantFoldTerminator

constant_fold_terminator :: (bb: Value_Id, delete_dead_conditions: bool, dtu: *Dtu) -> bool {
    t := block_terminator(bb);
    b: Irb;
    irb_set_before(*b, t);
    kinds := u32.[MD_LOOP_KIND, 0, MD_ANNOTATION_KIND];
    if inst_op(t) == .CONDBR {
        d1 := get_successor(t, 0);
        d2 := get_successor(t, 1);
        if d1 == d2 {
            block_remove_predecessor(d1, bb);
            nbi := irb_br(*b, d1);
            copy_metadata_kinds(nbi, t, kinds);
            c := op(t, 0);
            erase_terminator(t);
            if delete_dead_conditions recursively_delete_trivially_dead_value(c);
            return true;
        }
        c := op(t, 0);
        if is_const_int(c) {
            nz := !ap_is_zero(cf_ap(c));
            dest := ifx nz then d1 else d2;
            old := ifx nz then d2 else d1;
            block_remove_predecessor(old, bb);
            nbi := irb_br(*b, dest);
            copy_metadata_kinds(nbi, t, kinds);
            erase_terminator(t);
            dtu_apply1(dtu, false, bb, old);
            return true;
        }
        return false;
    }
    if inst_op(t) == .SWITCH {
        si := t;
        ci: Value_Id = ifx is_const_int(sw_cond(si)) then sw_cond(si) else NONE;
        def := sw_default(si);
        only := def;
        if sw_default_dest_unreachable(si) && sw_num_cases(si) > 0 only = sw_case_dest(si, 0);
        changed := false;
        k: u32 = 0;
        while k < sw_num_cases(si) {
            if sw_case_value(si, k) == ci { only = sw_case_dest(si, k); break; }
            if sw_case_dest(si, k) == def {
                md := prof_valid_branch_weight_md(si);
                ncases := sw_num_cases(si);
                if ncases > 1 && md != NONE {
                    w := prof_weights_of_md(md);
                    wl: [..] u64; wl.allocator = temp;
                    for w array_add(*wl, it);
                    if wl[0] > 0xFFFF_FFFF_FFFF_FFFF - wl[k + 1] {
                        f := prof_fit_weights(wl);
                        for f wl[it_index] = it;
                    }
                    wl[0] += wl[k + 1];
                    tmp := wl[k + 1]; wl[k + 1] = wl[wl.count - 1]; wl[wl.count - 1] = tmp;
                    wl.count -= 1;
                    prof_set_fitted_branch_weights(si, wl, prof_has_branch_weight_origin(md));
                }
                block_remove_predecessor(def, inst_block(si));
                sw_remove_case(si, k);
                if is_const_int(sw_cond(si)) { ci = sw_cond(si); k = 0; }
                changed = true;
                continue;
            }
            if sw_case_dest(si, k) != only only = NONE;
            k += 1;
        }
        if ci != NONE && only == NONE only = sw_default(si);
        if only != NONE {
            irb_br(*b, only);
            removed: [..] Value_Id; removed.allocator = temp;
            keep := only;
            n := num_successors(si);
            for s: 0..cast(s64) n - 1 {
                succ := get_successor(si, cast(u32) s);
                if dtu && succ != only {
                    seen := false; for removed if it == succ seen = true;
                    if !seen array_add(*removed, succ);
                }
                if succ == keep keep = NONE;
                else block_remove_predecessor(succ, bb);
            }
            c := sw_cond(si);
            erase_terminator(si);
            if delete_dead_conditions recursively_delete_trivially_dead_value(c);
            if dtu {
                ups: [..] Dom_Update; ups.allocator = temp;
                for removed array_add(*ups, .{false, bb, it});
                dtu_apply(dtu, ups);
            }
            return true;
        }
        if sw_num_cases(si) == 1 {
            cond := irb_icmp(*b, ICMP_EQ, sw_cond(si), sw_case_value(si, 0), "cond");
            nbr := irb_cond_br(*b, cond, sw_case_dest(si, 0), sw_default(si));
            ok, w := prof_extract_branch_weights(si);
            if ok && w.count == 2 {
                ws := u32.[cast(u32) w[1], cast(u32) w[0]];
                prof_set_branch_weights(nbr, ws, false, false);
            }
            mi := get_metadata(si, md_kind("make.implicit"));
            if mi != NONE set_metadata(nbr, md_kind("make.implicit"), mi);
            erase_terminator(si);
            return true;
        }
        return changed;
    }
    if inst_op(t) == .INDIRECTBR {
        ba := strip_pointer_casts(op(t, 0));
        if vkind(ba) == .C_BLOCKADDR {
            only := op(ba, 1);
            removed: [..] Value_Id; removed.allocator = temp;
            irb_br(*b, only);
            keep := only;
            nd := nops(t) - 1;
            for k: 0..cast(s64) nd - 1 {
                d := op(t, cast(u32) (k + 1));
                if dtu && d != only { seen := false; for removed if it == d seen = true; if !seen array_add(*removed, d); }
                if d == keep keep = NONE;
                else block_remove_predecessor(d, bb);
            }
            addr := op(t, 0);
            erase_terminator(t);
            if delete_dead_conditions recursively_delete_trivially_dead_value(addr);
            // BA->destroyConstant() when unused: our constants live for the run (no visible effect)
            if keep != NONE {
                bt := block_terminator(bb);
                erase_terminator(bt);
                block_append_inst(bb, new_inst(.UNREACHABLE, ir.t_void, 0));
            }
            if dtu {
                ups: [..] Dom_Update; ups.allocator = temp;
                for removed array_add(*ups, .{false, bb, it});
                dtu_apply(dtu, ups);
            }
            return true;
        }
    }
    return false;
}

// Instruction::eraseFromParent of a terminator (its debug records are trailing records of the block: deleted
// when the block gets a new terminator through the builder, they are adopted; we keep LLVM's net effect: records
// before the old terminator stay before the new one, which was inserted in front of it)
erase_terminator :: (t: Value_Id) {
    if inst(t).records {
        // records attached before `t` move to the instruction inserted right before it (the new terminator) when
        // there is one; otherwise they are dropped
        p := inst(t).prev;
        if p != NONE && is_terminator(inst_op(p)) {
            r := records_take(t);
            records_append(p, r);
        } else drop_dbg_records(t);
    }
    drop_all_references(t);
    erase_inst_with_metadata(t);
}

// ---------------------------------------------------------------- TryToSimplifyUncondBranchFromEmptyBlock

can_merge_values :: (a: Value_Id, b: Value_Id) -> bool {
    return a == b || vkind(a) == .C_UNDEF || vkind(a) == .C_POISON || vkind(b) == .C_UNDEF || vkind(b) == .C_POISON;
}
is_undef_value :: inline (v: Value_Id) -> bool { k := vkind(v); return k == .C_UNDEF || k == .C_POISON; }
block_set_contains :: (s: [] Value_Id, b: Value_Id) -> bool { for s if it == b return true; return false; }

// CanPropagatePredecessorsForPHIs
can_propagate_predecessors_for_phis :: (bb: Value_Id, succ: Value_Id, bb_preds: [] Value_Id) -> bool {
    if block_single_predecessor(succ) != NONE return true;
    for pn: block_insts(succ) {
        if inst_op(pn) != .PHI break;
        v := phi_incoming_value_for_block(pn, bb);
        if is_phi(v) && inst_block(v) == bb {
            for pi: 0..cast(s64) nops(pn) - 1 {
                ibb := phi_block(pn, cast(u32) pi);
                if block_set_contains(bb_preds, ibb) && !can_merge_values(phi_incoming_value_for_block(v, ibb), phi_value(pn, cast(u32) pi))
                    return false;
            }
        } else {
            for pi: 0..cast(s64) nops(pn) - 1 {
                ibb := phi_block(pn, cast(u32) pi);
                if block_set_contains(bb_preds, ibb) && !can_merge_values(v, phi_value(pn, cast(u32) pi)) return false;
            }
        }
    }
    return true;
}
block_has_phis :: (b: Value_Id) -> bool { f := block_first(b); return f != NONE && inst_op(f) == .PHI; }
block_num_preds :: (b: Value_Id) -> s64 { p: [..] Value_Id; p.allocator = temp; block_predecessors(b, *p); return p.count; }

// CanRedirectPredsOfEmptyBBToSucc: (ok, CommonPred)
can_redirect_preds_of_empty_bb_to_succ :: (bb: Value_Id, succ: Value_Id, bb_preds: [] Value_Id) -> (bool, Value_Id) {
    if !block_has_phis(bb) || !block_has_phis(succ) return false, NONE;
    if block_num_preds(bb) < 2 return false, NONE;
    for bb_preds if inst_op(block_terminator(it)) == .INDIRECTBR return false, NONE;
    common: Value_Id = NONE;
    sp: [..] Value_Id; sp.allocator = temp;
    block_predecessors(succ, *sp);
    for sp {
        if block_set_contains(bb_preds, it) {
            if common != NONE return false, NONE;
            common = it;
        }
    }
    return true, common;
}
// introduceTooManyPhiEntries
introduce_too_many_phi_entries :: (bb: Value_Id, succ: Value_Id) -> bool {
    np := block_num_preds(bb);
    if np == 1 return false;
    changed := 0;
    for phi: block_insts(succ) {
        if inst_op(phi) != .PHI break;
        v := phi_incoming_value_for_block(phi, bb);
        if is_phi(v) && inst_block(v) == bb continue;
        changed += 1;
    }
    return (np - 1) * changed > local_opts.max_phi_entries_increase_after_removing_empty_block;
}

Incoming_Map :: struct { keys: [..] Value_Id; vals: [..] Value_Id; }   // SmallDenseMap<BB, Value*> (lookups only)
im_find :: (m: *Incoming_Map, b: Value_Id) -> s64 { for m.keys if it == b return it_index; return -1; }
// selectIncomingValueForBlock
select_incoming_value_for_block :: (old: Value_Id, b: Value_Id, m: *Incoming_Map) -> Value_Id {
    k := im_find(m, b);
    if !is_undef_value(old) {
        if k >= 0 m.vals[k] = old; else { array_add(*m.keys, b); array_add(*m.vals, old); }
        return old;
    }
    if k >= 0 && m.vals[k] != NONE return m.vals[k];
    return old;
}
// redirectValuesFromPredecessorsToPhi
redirect_values_from_predecessors_to_phi :: (bb: Value_Id, bb_preds: [] Value_Id, pn: Value_Id, common: Value_Id) {
    old := phi_remove_incoming_block(pn, bb, false);
    m: Incoming_Map; m.keys.allocator = temp; m.vals.allocator = temp;
    // gatherIncomingValuesToPhi
    for bb_preds {
        k := im_find(*m, it);
        if k >= 0 m.vals[k] = NONE; else { array_add(*m.keys, it); array_add(*m.vals, NONE); }
    }
    for i: 0..cast(s64) nops(pn) - 1 {
        v := phi_value(pn, cast(u32) i);
        if is_undef_value(v) continue;
        k := im_find(*m, phi_block(pn, cast(u32) i));
        if k >= 0 m.vals[k] = v;
    }
    if is_phi(old) && inst_block(old) == bb {
        for i: 0..cast(s64) nops(old) - 1 {
            pb := phi_block(old, cast(u32) i);
            if pb == common continue;
            sel := select_incoming_value_for_block(phi_value(old, cast(u32) i), pb, *m);
            phi_add_incoming(pn, sel, pb);
        }
        if common != NONE phi_add_incoming(pn, phi_incoming_value_for_block(old, common), bb);
    } else {
        for pb: bb_preds {
            if pb == common continue;
            sel := select_incoming_value_for_block(old, pb, *m);
            phi_add_incoming(pn, sel, pb);
        }
        if common != NONE phi_add_incoming(pn, old, bb);
    }
    // replaceUndefValuesInPhi
    true_undef: [..] u32; true_undef.allocator = temp;
    for i: 0..cast(s64) nops(pn) - 1 {
        v := phi_value(pn, cast(u32) i);
        if !is_undef_value(v) continue;
        k := im_find(*m, phi_block(pn, cast(u32) i));
        if k < 0 continue;
        if m.vals[k] == NONE { array_add(*true_undef, cast(u32) i); continue; }
        phi_set_value(pn, cast(u32) i, m.vals[k]);
    }
    poison := 0;
    for true_undef if vkind(phi_value(pn, it)) == .C_POISON poison += 1;
    if poison != 0 && poison != true_undef.count {
        for true_undef phi_set_value(pn, it, const_undef(vtype(pn)));
    }
}
// Instruction::hasNonDebugLocLoopMetadata
has_non_debug_loc_loop_metadata :: (t: Value_Id) -> bool {
    m := get_metadata(t, MD_LOOP_KIND);
    if m == NONE return false;
    n := md_nops(m);
    for k: 1..cast(s64) n - 1 {
        o := md_op(m, cast(u32) k);
        if o == NONE || !is_di(o, .LOCATION) return true;
    }
    return false;
}

try_to_simplify_uncond_branch_from_empty_block :: (bb: Value_Id, dtu: *Dtu) -> bool {
    succ := get_successor(block_terminator(bb), 0);
    if bb == succ return false;
    preds_all: [..] Value_Id; preds_all.allocator = temp;
    block_predecessors(bb, *preds_all);
    bb_preds: [..] Value_Id; bb_preds.allocator = temp;    // SmallPtrSet
    for preds_all if !block_set_contains(bb_preds, it) array_add(*bb_preds, it);
    killable := can_propagate_predecessors_for_phis(bb, succ, bb_preds);
    common: Value_Id = NONE;
    mergeable := killable;
    if !killable { mergeable, common = can_redirect_preds_of_empty_bb_to_succ(bb, succ, bb_preds); }
    if (!killable && !mergeable) || introduce_too_many_phi_entries(bb, succ) return false;
    if block_single_predecessor(succ) == NONE {
        for i: block_insts(bb) {
            if inst_op(i) != .PHI break;
            u := ir.v_first_use[i];
            while u != NONE {
                user := ir.u_user[u];
                if !is_phi(user) return false;
                if ir.u_aux[u] != bb return false;
                u = ir.u_next[u];
            }
        }
    }
    ti := block_terminator(bb);
    if ti != NONE && has_non_debug_loc_loop_metadata(ti) {
        for p: preds_all {
            pti := block_terminator(p);
            if pti != NONE && has_non_debug_loc_loop_metadata(pti) return false;
        }
    }
    updates: [..] Dom_Update; updates.allocator = temp;
    if dtu {
        sp: [..] Value_Id; sp.allocator = temp;
        block_predecessors(succ, *sp);
        seen: [..] Value_Id; seen.allocator = temp;
        for p: preds_all {
            if !block_set_contains(sp, p) && !block_set_contains(seen, p) { array_add(*seen, p); array_add(*updates, .{true, p, succ}); }
        }
        seen.count = 0;
        for p: preds_all {
            if !block_set_contains(seen, p) { array_add(*seen, p); if p != common array_add(*updates, .{false, p, bb}); }
        }
        if killable array_add(*updates, .{false, bb, succ});
    }
    if block_has_phis(succ) {
        bp: [..] Value_Id; bp.allocator = temp;
        block_predecessors(bb, *bp);
        for pn: block_insts(succ) {
            if inst_op(pn) != .PHI break;
            redirect_values_from_predecessors_to_phi(bb, bp, pn, common);
        }
    }
    if block_single_predecessor(succ) != NONE {
        t := block_terminator(bb);
        drop_dbg_records(t);   // the terminator's records are trailing records once it's gone; splice moves them
        erase_inst_with_metadata(t);
        // Succ->splice(Succ->getFirstNonPHIIt(), BB)
        pos := block_first_non_phi(succ);
        while block_first(bb) != NONE {
            i := block_first(bb);
            inst_unlink(i);
            if pos == NONE block_append_inst(succ, i); else inst_insert_before(i, pos);
        }
    } else {
        while block_first(bb) != NONE && inst_op(block_first(bb)) == .PHI {
            pn := block_first(bb);
            erase_inst_with_metadata(pn);
        }
    }
    ti = block_terminator(bb);
    if ti != NONE && has_non_debug_loc_loop_metadata(ti) {
        lmd := get_metadata(ti, MD_LOOP_KIND);
        for p: preds_all set_metadata(block_terminator(p), MD_LOOP_KIND, lmd);
    }
    if killable {
        replace_all_uses_with(bb, succ);
        if vname(succ).count == 0 take_name(succ, bb);
        t := block_terminator(bb);
        if t != NONE { drop_dbg_records(t); erase_inst_with_metadata(t); }
        block_append_inst(bb, new_inst(.UNREACHABLE, ir.t_void, 0));
    } else if mergeable {
        u := ir.v_first_use[bb];
        while u != NONE {
            nx := ir.u_next[u];
            user := ir.u_user[u];
            if is_inst(user) && inst_block(user) != common && block_set_contains(bb_preds, inst_block(user)) use_set(u, succ);
            u = nx;
        }
    }
    if dtu dtu_apply(dtu, updates);
    if killable delete_dead_block(bb, dtu);
    return true;
}

// ---------------------------------------------------------------- EliminateDuplicatePHINodes

// Instruction::isIdenticalToWhenDefined for phis (the fast-math flags are not compared)
phi_identical_when_defined :: (a: Value_Id, b: Value_Id) -> bool {
    if vtype(a) != vtype(b) || nops(a) != nops(b) return false;
    for k: 0..cast(s64) nops(a) - 1 {
        if op(a, cast(u32) k) != op(b, cast(u32) k) return false;
        if phi_block(a, cast(u32) k) != phi_block(b, cast(u32) k) return false;
    }
    return true;
}
eliminate_duplicate_phi_nodes :: (bb: Value_Id) -> bool {
    to_remove: [..] Value_Id; to_remove.allocator = temp;
    changed := false;
    nphis := 0;
    for block_insts(bb) { if inst_op(it) != .PHI break; nphis += 1; }
    set_based := nphis > local_opts.phicse_num_phi_small_size;
    // EliminateDuplicatePHINodesNaiveImpl (the set-based version finds the same pairs: every phi is replaced by
    // the first identical phi before it)
    i := block_first(bb);
    while i != NONE && inst_op(i) == .PHI {
        pn := i;
        i = inst_next(i);
        if set_based && block_set_contains(to_remove, pn) continue;
        j := i;
        restarted := false;
        while j != NONE && inst_op(j) == .PHI {
            dup := j;
            j = inst_next(j);
            if block_set_contains(to_remove, dup) continue;
            same := ifx set_based then is_identical_to(dup, pn) else phi_identical_when_defined(dup, pn);
            if !same continue;
            replace_all_uses_with(dup, pn);
            array_add(*to_remove, dup);
            changed = true;
            restarted = true;
            break;
        }
        if restarted i = block_first(bb);
    }
    for to_remove erase_inst_with_metadata(it);
    return changed;
}

// ---------------------------------------------------------------- EH personalities

EH_UNKNOWN :: 0; EH_GNU_ADA :: 1; EH_GNU_C :: 2; EH_GNU_C_SJLJ :: 3; EH_GNU_CXX :: 4; EH_GNU_CXX_SJLJ :: 5;
EH_GNU_OBJC :: 6; EH_MSVC_X86SEH :: 7; EH_MSVC_TABLESEH :: 8; EH_MSVC_CXX :: 9; EH_CORECLR :: 10; EH_RUST :: 11;
EH_WASM_CXX :: 12; EH_XL_CXX :: 13; EH_ZOS_CXX :: 14;
// classifyEHPersonality(Pers)
classify_eh_personality :: (pers: Value_Id) -> s64 {
    if pers == NONE return EH_UNKNOWN;
    f := strip_pointer_casts(pers);
    if vkind(f) != .FUNCTION return EH_UNKNOWN;
    n := vname(f);
    if n == {
        case "__gnat_eh_personality"; return EH_GNU_ADA;
        case "__gxx_personality_v0"; return EH_GNU_CXX;
        case "__gxx_personality_seh0"; return EH_GNU_CXX;
        case "__gxx_personality_sj0"; return EH_GNU_CXX_SJLJ;
        case "__gcc_personality_v0"; return EH_GNU_C;
        case "__gcc_personality_seh0"; return EH_GNU_C;
        case "__gcc_personality_sj0"; return EH_GNU_C_SJLJ;
        case "__objc_personality_v0"; return EH_GNU_OBJC;
        case "_except_handler3"; return EH_MSVC_X86SEH;
        case "_except_handler4"; return EH_MSVC_X86SEH;
        case "__C_specific_handler"; return EH_MSVC_TABLESEH;
        case "__CxxFrameHandler3"; return EH_MSVC_CXX;
        case "ProcessCLRException"; return EH_CORECLR;
        case "__gxx_wasm_personality_v0"; return EH_WASM_CXX;
        case "__xlcxx_personality_v1"; return EH_XL_CXX;
        case "__zos_cxx_personality_v2"; return EH_ZOS_CXX;
    }
    if ends_with(n, "rust_eh_personality") return EH_RUST;
    return EH_UNKNOWN;
}
fn_personality :: (f: Value_Id) -> Value_Id { if glob(f).has_personality return op(f, 0); return NONE; }
is_scoped_eh_personality :: (p: s64) -> bool { return p == EH_MSVC_CXX || p == EH_MSVC_X86SEH || p == EH_MSVC_TABLESEH || p == EH_CORECLR || p == EH_WASM_CXX; }
is_funclet_eh_personality :: (p: s64) -> bool { return p == EH_MSVC_CXX || p == EH_MSVC_X86SEH || p == EH_MSVC_TABLESEH || p == EH_CORECLR; }
is_asynchronous_eh_personality :: (p: s64) -> bool { return p == EH_MSVC_X86SEH || p == EH_MSVC_TABLESEH; }
// Module::getModuleFlag(Key) != null: module_has_flag (pass_sroa.jai)
// canSimplifyInvokeNoUnwind
can_simplify_invoke_no_unwind :: (f: Value_Id) -> bool {
    p := classify_eh_personality(fn_personality(f));
    return !module_has_flag("eh-asynch") && !is_asynchronous_eh_personality(p);
}

// ---------------------------------------------------------------- invoke -> call

// CallBase::doesNotReturn / isMustTailCall
call_does_not_return :: (i: Value_Id) -> bool { return call_has_fn_attr(i, .NoReturn); }
call_is_must_tail :: (i: Value_Id) -> bool { return inst_op(i) == .CALL && ((inst(i).flags >> TAIL_SHIFT) & 3) == 2; }
invoke_normal_dest :: (ii: Value_Id) -> Value_Id { return get_successor(ii, 0); }
invoke_unwind_dest :: (ii: Value_Id) -> Value_Id { return get_successor(ii, 1); }

// createCallMatchingInvoke: a call with the invoke's callee, arguments, bundles, attributes, cc, metadata
create_call_matching_invoke :: (ii: Value_Id) -> Value_Id {
    n := nops(ii);   // [args..., normal, unwind, callee]
    c := new_inst(.CALL, vtype(ii), n - 2);
    for k: 0..cast(s64) n - 4 set_op(c, cast(u32) k, op(ii, cast(u32) k));
    set_op(c, n - 3, op(ii, n - 1));
    src := inst(ii);
    dst := inst(c);
    dst.ty2 = src.ty2; dst.attrs = src.attrs; dst.cc = src.cc;
    dst.idx = src.idx; dst.nidx = src.nidx;
    dst.flags = src.flags & ~(cast(u32) 3 << TAIL_SHIFT);
    copy_metadata(c, ii);
    // extractProfTotalWeight: a branch_weights/VP total becomes a single weight
    m := prof_md(c);
    if m != NONE && md_is_node(m) && md_nops(m) >= 2 {
        s := md_op(m, 0);
        if s != NONE && ir.mds[s].kind == .STRING && (ir.mds[s].str == "branch_weights" || ir.mds[s].str == "VP") {
            if ir.mds[s].str == "VP" fatal("changeToCall with value-profile metadata is not supported yet");
            total: u64 = 0;
            for prof_weights_of_md(m) total += it;
            if total != (total & 0xFFFF_FFFF) set_metadata(c, md_kind(MD_PROF_NAME), NONE);
            else { w := u32.[cast(u32) total]; prof_set_branch_weights(c, w, false, false); }
        }
    }
    return c;
}
// changeToCall(II, DTU)
change_to_call :: (ii: Value_Id, dtu: *Dtu) -> Value_Id {
    c := create_call_matching_invoke(ii);
    inst_insert_before(c, ii);
    take_name(c, ii);
    rauw_with_metadata(ii, c);
    normal := invoke_normal_dest(ii);
    bi := create_br(normal);
    inst_insert_before(bi, ii);
    copy_debug_loc(bi, ii);
    bb := inst_block(ii);
    unwind := invoke_unwind_dest(ii);
    block_remove_predecessor(unwind, bb);
    erase_terminator(ii);
    dtu_apply1(dtu, false, bb, unwind);
    return c;
}

// removeUnwindEdge(BB, DTU)
remove_unwind_edge :: (bb: Value_Id, dtu: *Dtu) -> Value_Id {
    ti := block_terminator(bb);
    if inst_op(ti) == .INVOKE return change_to_call(ti, dtu);
    nti: Value_Id;
    unwind: Value_Id;
    if inst_op(ti) == .CLEANUPRET {
        nti = new_inst(.CLEANUPRET, ir.t_void, 1);
        set_op(nti, 0, op(ti, 0));
        unwind = op(ti, 1);
    } else if inst_op(ti) == .CATCHSWITCH {
        // [parent, unwind?, handlers...]
        has_unwind := (inst(ti).flags & F_HAS_UNWIND) != 0;
        nh := nops(ti) - 1 - ifx has_unwind then cast(u32) 1 else 0;
        nti = new_inst(.CATCHSWITCH, vtype(ti), 1);
        grow_ops(nti, 1 + nh);
        set_op(nti, 0, op(ti, 0));
        first: u32 = ifx has_unwind then cast(u32) 2 else 1;
        for k: 0..cast(s64) nh - 1 add_op(nti, op(ti, first + cast(u32) k));
        unwind = op(ti, 1);
    } else {
        fatal("removeUnwindEdge: could not find unwind successor");
        return NONE;
    }
    inst_insert_before(nti, ti);
    take_name(nti, ti);
    copy_debug_loc(nti, ti);
    block_remove_predecessor(unwind, bb);
    rauw_with_metadata(ti, nti);
    erase_terminator(ti);
    dtu_apply1(dtu, false, bb, unwind);
    return nti;
}

// ---------------------------------------------------------------- removeUnreachableBlocks

// markAliveBlocks
mark_alive_blocks :: (f: Value_Id, reachable: *Table(Value_Id, bool), dtu: *Dtu) -> bool {
    work: [..] Value_Id; work.allocator = temp;
    bb := fn_entry(f);
    array_add(*work, bb);
    table_set(reachable, bb, true);
    changed := false;
    while work.count {
        bb = pop(*work);
        for :early_inc i: block_insts(bb) {
            o := inst_op(i);
            if o == .CALL {
                callee := op(i, nops(i) - 1);
                if vkind(callee) == .FUNCTION {
                    id := fn_iid(callee);
                    if id == IID_ASSUME {
                        a := op(i, 0);
                        if (is_const_int(a) && ap_is_zero(cf_ap(a))) || is_undef_value(a) {
                            change_to_unreachable(i, false, null, dtu);
                            changed = true;
                            break;
                        }
                    } else if id != NOT_INTRINSIC && iid_name(id) == "llvm.experimental.guard" {
                        a := op(i, 0);
                        if is_const_int(a) && ap_is_zero(cf_ap(a)) && inst_op(inst_next(i)) != .UNREACHABLE {
                            change_to_unreachable(inst_next(i), false, null, dtu);
                            changed = true;
                            break;
                        }
                    }
                } else if (vkind(callee) == .C_NULL && !null_pointer_is_defined(f, ptr_addrspace(vtype(callee)))) || is_undef_value(callee) {
                    change_to_unreachable(i, false, null, dtu);
                    changed = true;
                    break;
                }
                if call_does_not_return(i) && !call_is_must_tail(i) {
                    if inst_op(inst_next(i)) != .UNREACHABLE {
                        change_to_unreachable(inst_next(i), false, null, dtu);
                        changed = true;
                    }
                    break;
                }
            } else if o == .STORE {
                if inst(i).flags & F_VOLATILE continue;
                p := op(i, 1);
                if is_undef_value(p) || (vkind(p) == .C_NULL && !null_pointer_is_defined(f, ptr_addrspace(vtype(p)))) {
                    change_to_unreachable(i, false, null, dtu);
                    changed = true;
                    break;
                }
            }
        }
        t := block_terminator(bb);
        if inst_op(t) == .INVOKE {
            callee := op(t, nops(t) - 1);
            if (vkind(callee) == .C_NULL && !null_pointer_is_defined(f)) || is_undef_value(callee) {
                change_to_unreachable(t, false, null, dtu);
                changed = true;
            } else {
                if call_does_not_return(t) && inst_op(block_first(invoke_normal_dest(t))) != .UNREACHABLE {
                    orig := invoke_normal_dest(t);
                    block_remove_predecessor(orig, bb);
                    nd := create_block(f, tprint("%.unreachable", vname(orig)), orig);
                    block_append_inst(nd, new_inst(.UNREACHABLE, ir.t_void, 0));
                    set_successor(t, 0, nd);
                    if dtu { ups := Dom_Update.[.{false, bb, orig}, .{true, bb, nd}]; dtu_apply(dtu, ups); }
                    changed = true;
                }
                if call_does_not_throw(t) && can_simplify_invoke_no_unwind(f) {
                    if !has_uses(t) && !may_have_side_effects(t) {
                        normal := invoke_normal_dest(t);
                        unwind := invoke_unwind_dest(t);
                        nb := create_br(normal);
                        inst_insert_before(nb, t);
                        block_remove_predecessor(unwind, bb);
                        erase_terminator(t);
                        dtu_apply1(dtu, false, bb, unwind);
                    } else change_to_call(t, dtu);
                    changed = true;
                }
            }
        } else if inst_op(t) == .CATCHSWITCH {
            // duplicate handlers (catchpads identical to an earlier one) are removed
            has_unwind := (inst(t).flags & F_HAS_UNWIND) != 0;
            first: u32 = ifx has_unwind then cast(u32) 2 else 1;
            k := first;
            seen: [..] Value_Id; seen.allocator = temp;
            while k < nops(t) {
                h := op(t, k);
                cp := block_first_non_phi(h);
                dup := false;
                for seen if is_identical_to(it, cp) dup = true;
                if dup { fatal("markAliveBlocks: removing a duplicate catchswitch handler is not supported yet"); }
                array_add(*seen, cp);
                k += 1;
            }
        }
        changed |= constant_fold_terminator(bb, true, dtu);
        succs: [..] Value_Id; succs.allocator = temp;
        block_successors(bb, *succs);
        for s: succs {
            if !table_contains(reachable, s) { array_add(*work, s); table_set(reachable, s, true); }
        }
    }
    return changed;
}

remove_unreachable_blocks :: (f: Value_Id, dtu: *Dtu) -> bool {
    reachable: Table(Value_Id, bool); reachable.allocator = temp;
    changed := mark_alive_blocks(f, *reachable, dtu);
    dead: [..] Value_Id; dead.allocator = temp;
    for b: fn_blocks(f) if !table_contains(*reachable, b) array_add(*dead, b);
    if dead.count == 0 return changed;
    delete_dead_blocks(dead, dtu);
    return true;
}

// ---------------------------------------------------------------- canReplaceOperandWithVariable, hoistAllInstructionsInto

can_replace_operand_with_variable :: (i: Value_Id, op_idx: u32) -> bool {
    v := op(i, op_idx);
    if type_kind(vtype(v)) == .METADATA || type_kind(vtype(v)) == .TOKEN return false;
    if is_swift_error_value(v) return false;
    if is_lifetime_start_or_end(i) return false;
    if !is_constant_kind(vkind(v)) && vkind(v) != .INLINE_ASM return true;
    o := inst_op(i);
    if o == {
        case .CALL; #through;
        case .INVOKE;
            callee := op(i, nops(i) - 1);
            if vkind(callee) == .INLINE_ASM return false;
            nargs := call_num_args(i);
            bundles_end := ifx o == .CALL then nops(i) - 1 else nops(i) - 3;
            if op_idx >= nargs && op_idx < bundles_end return false;   // isBundleOperand
            is_intr := call_iid(i) != NOT_INTRINSIC;
            if op_idx < nargs {
                if is_intr && op_idx >= func_nparams(inst(i).ty2) return iid_name(call_iid(i)) == "llvm.experimental.stackmap";
                if is_intr && iid_name(call_iid(i)) == "llvm.gcroot" return false;
                return !call_param_has_attr(i, op_idx, .ImmArg);
            }
            return !is_intr;
        case .SHUFFLEVECTOR; return op_idx != 2;
        case .SWITCH; #through;
        case .EXTRACTVALUE; return op_idx == 0;
        case .INSERTVALUE; return op_idx < 2;
        case .ALLOCA; return !is_static_alloca(i);
        case .GEP;
            if op_idx == 0 return true;
            // gep_type_iterator over the first op_idx indices: none may step into a struct
            t := inst(i).ty2;
            for k: 1..cast(s64) op_idx {
                if k > 1 {
                    if type_kind(t) == .STRUCT return false;
                    nt := ifx is_vector_type(t) || type_kind(t) == .ARRAY then type_elem(t) else t;
                    t = nt;
                }
            }
            return true;
    }
    return true;
}
// Value::isSwiftError: a swifterror argument or alloca
is_swift_error_value :: (v: Value_Id) -> bool {
    if vkind(v) == .ARGUMENT return arg_has_attr(v, .SwiftError);
    if is_inst(v) && inst_op(v) == .ALLOCA return (inst(v).flags & F_SWIFTERR) != 0;
    return false;
}

// hoistAllInstructionsInto(DomBlock, InsertPt, BB)
hoist_all_instructions_into :: (dom: Value_Id, insert_pt: Value_Id, bb: Value_Id) {
    i := block_first(bb);
    while i != NONE {
        nx := inst_next(i);
        drop_ub_implying_attrs_and_metadata(i);
        users: [..] u32; users.allocator = temp;
        find_dbg_users(inst_fn(i), i, *users);
        for users dbgr_erase(it);
        drop_dbg_records(i);
        if is_debug_or_pseudo_inst(i) { erase_inst_with_metadata(i); i = nx; continue; }
        copy_debug_loc_or_clear(i, insert_pt);
        i = nx;
    }
    t := block_terminator(bb);
    while block_first(bb) != t {
        x := block_first(bb);
        inst_unlink(x);
        inst_insert_before(x, insert_pt);
    }
}
