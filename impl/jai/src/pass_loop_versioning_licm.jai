// LoopVersioningLICM (loop-versioning-licm, a loop pass): port of llvm/lib/Transforms/Scalar/LoopVersioningLICM.cpp.
// A loop whose memory accesses may alias but have enough loop-invariant ones is versioned on runtime alias checks;
// the fast version is annotated noalias / llvm.mem.parallel_loop_access so that LICM can hoist from it. The
// optimization remarks are not emitted.

lvlicm_cl: struct {
    invariant_threshold: float32 = 25;   // -licm-versioning-invariant-threshold
    loop_depth_threshold: u32 = 2;       // -licm-versioning-max-depth-threshold
};

lvlicm_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "licm-versioning-invariant-threshold";
            if !has_value fatal("opt: for the --% option: requires a value!", name);
            v, ok := string_to_float64(value);
            if !ok fatal("opt: for the --% option: '%' value invalid for float argument!", name, value);
            lvlicm_cl.invariant_threshold = cast(float32) v;
        case "licm-versioning-max-depth-threshold";
            if !has_value fatal("opt: for the --% option: requires a value!", name);
            v, ok, rest := string_to_int(value);
            if !ok || rest.count || v < 0 fatal("opt: for the --% option: '%' value invalid for uint argument!", name, value);
            lvlicm_cl.loop_depth_threshold = cast(u32) v;
        case; return false;
    }
    return true;
}

Lv_Licm :: struct {
    aar: Aa_Results;
    li: *Loop_Info;
    dt: *Dom_Tree;
    ac: *Assumption_Cache;
    l: Loop_Id;
    lai: *Laa;
    load_and_store_counter: u32;
    invariant_counter: u32;
    is_read_only_loop: bool;
}

// legalLoopStructure
lvlicm_legal_loop_structure :: (c: *Lv_Licm) -> bool {
    li := c.li; l := c.l;
    if !li_is_loop_simplify_form(li, l) return false;
    if li_subloops(li, l).count != 0 return false;
    if li_num_back_edges(li, l) != 1 return false;
    if li_exiting_block(li, l) == NONE return false;
    if li_exiting_block(li, l) != li_loop_latch(li, l) return false;
    if li_is_annotated_parallel(li, l) return false;
    if li_depth(li, l) > lvlicm_cl.loop_depth_threshold return false;
    if sc_is_cnc(sc_get_backedge_taken_count(l)) return false;
    return true;
}

// legalLoopMemoryAccesses
lvlicm_legal_loop_memory_accesses :: (c: *Lv_Licm) -> bool {
    ast: Alias_Set_Tracker;
    ast_init(*ast, aa_query_new(*c.aar));   // BatchAAResults BAA(*AA)
    for b: li_blocks(c.li, c.l) {
        if li_loop_for(c.li, b) != c.l continue;
        for i: block_insts(b) ast_add(*ast, i);
    }
    has_may_alias := false; type_safety := false; has_mod := false;
    for * s: ast.sets {
        if s.removed continue;
        if s.forward >= 0 continue;   // isForwardingAliasSet
        if ast_is_must_alias(s) return false;
        if s.locs.count == 0 fatal("loop-versioning-licm: an alias set without memory locations (LLVM reads AS.begin()->Ptr of an empty set)");
        some_ptr := s.locs[0].ptr;
        type_check := true;
        has_may_alias |= s.may_alias;
        has_mod |= ast_is_mod(s);
        for loc: s.locs type_check = type_check && vtype(some_ptr) == vtype(loc.ptr);
        type_safety |= type_check;
    }
    if !type_safety return false;
    if !has_mod return false;
    if !has_may_alias return false;
    return true;
}

// instructionSafeForVersioning
lvlicm_instruction_safe_for_versioning :: (c: *Lv_Licm, i: Value_Id) -> bool {
    if is_call_base(i) {
        if call_is_convergent(i) || call_cannot_duplicate(i) return false;
        if aa_memory_effects_call(aa_query_new(*c.aar), i) != 0 return false;   // !AA->doesNotAccessMemory(Call)
    }
    if may_throw(i) return false;
    if may_read_from_memory(i) {
        if inst_op(i) != .LOAD || inst_is_atomic(i) || is_volatile(i) return false;
        c.load_and_store_counter += 1;
        if sc_is_loop_invariant(sc_get_scev(op(i, 0)), c.l) c.invariant_counter += 1;
    } else if may_write_to_memory(i) {
        if inst_op(i) != .STORE || inst_is_atomic(i) || is_volatile(i) return false;
        c.load_and_store_counter += 1;
        ptr := op(i, 1);
        found := false;
        for c.lai.rt.pointers if it.ptr == ptr { found = true; break; }
        if !found return false;
        if sc_is_loop_invariant(sc_get_scev(ptr), c.l) c.invariant_counter += 1;
        c.is_read_only_loop = false;
    }
    return true;
}

// legalLoopInstructions
lvlicm_legal_loop_instructions :: (c: *Lv_Licm) -> bool {
    c.load_and_store_counter = 0;
    c.invariant_counter = 0;
    c.is_read_only_loop = true;
    // LAIs.getInfo(*CurLoop, /*AllowPartial=*/true) of a manager built without TTI and TLI
    c.lai = New(Laa,, allocator = temp);
    laa_compute(c.lai, c.l, c.li, c.dt, c.ac, true, true, true);
    if c.lai.rt.checks.count == 0 return false;
    for b: li_blocks(c.li, c.l) for i: block_insts(b) if !lvlicm_instruction_safe_for_versioning(c, i) return false;
    if c.lai.rt.checks.count > laa_opts.runtime_memory_check_threshold return false;
    if c.invariant_counter == 0 return false;
    if c.is_read_only_loop return false;
    if cast(float32) (c.invariant_counter * 100) < lvlicm_cl.invariant_threshold * cast(float32) c.load_and_store_counter return false;
    return true;
}

// isLegalForVersioning
lvlicm_is_legal_for_versioning :: (c: *Lv_Licm) -> bool {
    // isLoopAlreadyVisited
    if find_option_md_for_loop_id(li_loop_id(c.li, c.l), "llvm.loop.licm_versioning.disable") != NONE return false;
    if !lvlicm_legal_loop_structure(c) return false;
    if !lvlicm_legal_loop_instructions(c) return false;
    if !lvlicm_legal_loop_memory_accesses(c) return false;
    return true;
}

// LoopVersioningLICMPass::run
loop_versioning_licm_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    se = lar.se;
    c: Lv_Licm;
    c.aar = aa_results_for(lar.fn);
    c.li = lar.li; c.dt = lar.dt; c.ac = lar.ac; c.l = l;
    // hasLICMVersioningTransformation(CurLoop) & TM_Disable
    if li_get_boolean_loop_attribute(c.li, l, "llvm.loop.licm_versioning.disable") return PRESERVE_ALL;
    if !lvlicm_is_legal_for_versioning(*c) return PRESERVE_ALL;
    checks: [..] s64; checks.allocator = temp;
    for 0..c.lai.rt.checks.count - 1 array_add(*checks, it);
    lv: Lver;
    lv.versioned = l; lv.lai = c.lai; lv.checks = checks; lv.li = c.li; lv.dt = c.dt;
    lver_version_loop(*lv, find_defs_used_outside_of_loop(c.li, l));
    add_string_metadata_to_loop(c.li, lv.non_versioned, "llvm.loop.licm_versioning.disable", 0);
    add_string_metadata_to_loop(c.li, lv.versioned, "llvm.loop.licm_versioning.disable", 0);
    add_string_metadata_to_loop(c.li, lv.versioned, "llvm.mem.parallel_loop_access", 0);
    lver_annotate_loop_with_no_alias(*lv);
    return loop_pass_preserved();
}
