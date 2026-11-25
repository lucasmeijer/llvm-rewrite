// LoopVersioningPass (loop-versioning): the pass part of llvm/lib/Transforms/Utils/LoopVersioning.cpp (runImpl,
// LoopVersioningPass::run). The LoopVersioning utility itself is loop_versioning.jai.

// runImpl + LoopVersioningPass::run
loop_versioning_run :: (f: Value_Id) -> Preserved {
    s := get_scev(f);
    li := get_loop_info(f);
    dt := get_domtree(f);
    ac := get_assumption_cache(f);
    se = s;
    saved := scev_pass_se;
    scev_pass_se = s;
    defer scev_pass_se = saved;
    worklist: [..] Loop_Id; worklist.allocator = temp;
    tops: [..] Loop_Id; tops.allocator = temp;
    for li.top_level array_add(*tops, it);
    for top: tops {
        pre: [..] Loop_Id; pre.allocator = temp;
        li_loops_in_preorder_of(li, top, *pre);   // depth_first(TopLevelLoop)
        for pre if li_subloops(li, it).count == 0 array_add(*worklist, it);
    }
    changed := false;
    for l: worklist {
        if !li_is_loop_simplify_form(li, l) || !li_is_rotated_form(li, l) || li_exiting_block(li, l) == NONE continue;
        // LAIs.getInfo(*L): the manager is cleared after every versioning, so each loop's info is computed here
        lai := New(Laa,, allocator = temp);
        laa_compute(lai, l, li, dt, ac);
        if !lai.has_convergent_op && (lai.rt.checks.count != 0 || !sc_union_is_always_true(lai.pse.preds)) {
            if !li_is_recursively_lcssa_form(li, l, dt) form_lcssa_recursively(li, l, dt);
            checks: [..] s64; checks.allocator = temp;
            for 0..lai.rt.checks.count - 1 array_add(*checks, it);
            lv: Lver;
            lv.versioned = l; lv.lai = lai; lv.checks = checks; lv.li = li; lv.dt = dt;
            lver_version_loop(*lv, find_defs_used_outside_of_loop(li, l));
            lver_annotate_loop_with_no_alias(*lv);
            changed = true;
        }
    }
    if changed return PRESERVE_NONE;
    return PRESERVE_ALL;
}
