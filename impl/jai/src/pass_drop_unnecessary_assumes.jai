// DropUnnecessaryAssumes: port of llvm/lib/Transforms/Scalar/DropUnnecessaryAssumes.cpp (affectedValuesAreEphemeral,
// DropUnnecessaryAssumesPass::run), with AssumptionCache::findValuesAffectedByOperandBundle / replaceAssumption
// (llvm/lib/Analysis/AssumptionCache.cpp) and CallInst::Create(CI, Bundles) (llvm/lib/IR/Instructions.cpp).
// Parameters: drop-unnecessary-assumes<drop-deref>.

dua_affected_values_are_ephemeral :: (affected: [] Value_Id) -> bool {
    wl: [..] Value_Id; wl.allocator = temp;   // SmallSetVector
    in_wl: Table(Value_Id, bool); in_wl.allocator = temp;
    add_users :: (v: Value_Id) -> bool #expand {
        u := ir.v_first_use[v];
        while u != NONE {
            if wl.count >= 32 return false;
            usr := ir.u_user[u];
            if !table_contains(*in_wl, usr) { table_set(*in_wl, usr, true); array_add(*wl, usr); }
            u = ir.u_next[u];
        }
        return true;
    }
    for v: affected {
        if !is_inst(v) && !is_argument(v) return false;
        if !add_users(v) return false;
    }
    idx := 0;
    while idx < wl.count {
        i := wl[idx];
        idx += 1;
        if call_iid(i) == IID_ASSUME continue;
        if may_have_side_effects(i) || is_terminator(inst_op(i)) return false;
        if !add_users(i) return false;
    }
    return true;
}

// AssumptionCache::findValuesAffectedByOperandBundle
dua_bundle_affected :: (ci: Value_Id, k: u32, out: *[..] Value_Id) {
    tag := call_bundle_tag(ci, k);
    b, e := call_bundle_range(ci, k);
    add :: (out: *[..] Value_Id, v: Value_Id) {
        kk := vkind(v);
        if kk == .ARGUMENT || is_global_value(kk) || kk == .INST array_add(out, v);
    }
    if tag == "separate_storage" {
        add(out, get_underlying_object(op(ci, b)));
        add(out, get_underlying_object(op(ci, b + 1)));
    } else if e - b > 0 && tag != "ignore" {
        add(out, op(ci, b));
    }
}

// CallInst::Create(CI, Bundles, InsertPt) keeping the bundles in `keep` (in order): same arguments, callee,
// attributes, calling convention, tail kind, optional flags and debug location; no other metadata, no name
dua_call_with_bundles :: (i: Value_Id, keep: [] u32) -> Value_Id {
    nargs := call_num_args(i);
    total: u32 = 0;
    for k: keep { b, e := call_bundle_range(i, k); total += e - b; }
    n := nargs + total + 1;
    c := new_inst(inst_op(i), vtype(i), n);
    src := inst(i).*;
    r := inst(c);
    r.* = src;
    r.parent = NONE; r.prev = NONE; r.next = NONE; r.records = 0;
    pos: u32 = 0;
    for x: 0..cast(s64) nargs - 1 { set_op(c, pos, op(i, cast(u32) x)); pos += 1; }
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) keep.count;
    for k: keep {
        b, e := call_bundle_range(i, k);
        t := ir.u32_pool[src.idx + 3 * k];
        nb := pos;
        for x: b..e-1 { set_op(c, pos, op(i, x)); pos += 1; }
        array_add(*ir.u32_pool, t); array_add(*ir.u32_pool, nb); array_add(*ir.u32_pool, pos);
    }
    set_op(c, pos, call_callee(i));
    copy_debug_loc(c, i);
    return c;
}

drop_unnecessary_assumes_run :: (f: Value_Id, name: string) -> Preserved {
    drop_deref := false;
    if name == "drop-unnecessary-assumes<drop-deref>" drop_deref = true;
    else if name != "drop-unnecessary-assumes" && name != "drop-unnecessary-assumes<>" fatal("invalid pass pipeline: invalid DropUnnecessaryAssumes parameter in '%'", name);
    ac := get_assumption_cache(f);
    changed := false;
    ac_scan(ac);
    for idx: 0..ac.assumes.count - 1 {
        assume := ac.assumes[idx];
        if assume == NONE || vkind(assume) == .DEAD || call_iid(assume) != IID_ASSUME continue;
        nb := call_num_bundles(assume);
        if nb > 0 {
            dead_args: [..] Value_Id; dead_args.allocator = temp;
            kept: [..] u32; kept.allocator = temp;
            for k: 0..nb - 1 {
                tag := call_bundle_tag(assume, k);
                b, e := call_bundle_range(assume, k);
                is_dead: bool;
                if tag == "ignore" is_dead = true;
                else if tag == "dereferenceable" is_dead = drop_deref;
                else if e == b is_dead = false;
                else {
                    aff: [..] Value_Id; aff.allocator = temp;
                    dua_bundle_affected(assume, k, *aff);
                    is_dead = dua_affected_values_are_ephemeral(aff);
                }
                if is_dead { for x: b..e-1 array_add(*dead_args, op(assume, x)); }
                else array_add(*kept, k);
            }
            if kept.count != nb {
                if kept.count == 0 {
                    erase_inst_with_metadata(assume);
                } else {
                    na := dua_call_with_bundles(assume, kept);
                    insert_at_position(na, inst_block(assume), assume, false);
                    // AC.replaceAssumption(Elem, NewAssume)
                    for * a: ac.affected {
                        k := 0;
                        while k < a.count { if a.*[k].assume == assume array_ordered_remove_by_index(a, k); else k += 1; }
                    }
                    ac.assumes[idx] = na;
                    vp := table_find_pointer(*ac_virtual, ac.fn);   // LLVM's long-lived cache holds the new one
                    if vp table_set(*vp.registered, na, true);
                    ac_update_affected_values(ac, na);
                    erase_inst_with_metadata(assume);
                }
                // RecursivelyDeleteTriviallyDeadInstructionsPermissive(DeadBundleArgs) (no TLI)
                dua_delete_dead_permissive(dead_args);
                changed = true;
            }
            continue;
        }
        cond := op(assume, 0);
        cid := call_iid(cond);
        if cid == intrinsic_id_by_name("llvm.type.test") || cid == intrinsic_id_by_name("llvm.public.type.test") continue;
        aff2: [..] Affected; aff2.allocator = temp;
        find_values_affected_by_condition(cond, true, *aff2, AC_EXPR_RESULT_IDX);
        aff: [..] Value_Id; aff.allocator = temp;
        for aff2 array_add(*aff, it.v);
        if !dua_affected_values_are_ephemeral(aff) continue;
        erase_inst_with_metadata(assume);
        recursively_delete_trivially_dead_value(cond);
        changed = true;
    }
    if !changed return PRESERVE_ALL;
    return preserved_cfg();
}

dua_delete_dead_permissive :: (vals: [] Value_Id) {
    dead: [..] Value_Id; dead.allocator = temp;
    for vals if is_inst(it) && !has_uses(it) && would_instruction_be_trivially_dead(it, false) array_add(*dead, it);
    while dead.count {
        i := pop(*dead);
        if vkind(i) == .DEAD continue;
        salvage_debug_info(i);
        for k: 0..cast(s64) nops(i) - 1 {
            o := op(i, cast(u32) k);
            set_op(i, cast(u32) k, NONE);
            if o != NONE && is_inst(o) && !has_uses(o) && would_instruction_be_trivially_dead(o, false) array_add(*dead, o);
        }
        erase_inst_with_metadata(i);
    }
}
