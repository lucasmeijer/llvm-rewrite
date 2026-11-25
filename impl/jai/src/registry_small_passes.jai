// Small transform passes from the registry gaps (NOTES.md "Pass registry gaps"):
//   strip-gc-relocates   llvm/lib/Transforms/Utils/StripGCRelocates.cpp

// StripGCRelocates::run / stripGCRelocates
strip_gc_relocates_run :: (f: Value_Id) -> Preserved {
    rels: [..] Value_Id; rels.allocator = temp;
    for i: fn_insts(f) {
        // dyn_cast<GCRelocateInst> (an IntrinsicInst: a CallInst) bound to a GCStatepointInst token
        if inst_op(i) != .CALL || call_iid(i) != IID_EXPERIMENTAL_GC_RELOCATE continue;
        if call_iid(op(i, 0)) == IID_EXPERIMENTAL_GC_STATEPOINT array_add(*rels, i);
    }
    for r: rels {
        orig := gc_relocate_derived_ptr(r);
        repl := orig;
        if vtype(r) != vtype(orig) repl = insert_before_named(create_cast(.BITCAST, orig, vtype(r)), r, "cast");
        replace_all_uses_with(r, repl);
        erase_inst_with_metadata(r);
    }
    if !rels.count return PRESERVE_ALL;
    return preserved_cfg();
}

// ---------------------------------------------------------------- flatten-cfg
// llvm/lib/Transforms/Scalar/FlattenCFGPass.cpp (FlattenCFGPass::run, iterativelyFlattenCFG) and
// llvm/lib/Transforms/Utils/FlattenCFG.cpp (FlattenCFGOpt: FlattenParallelAndOr, MergeIfRegion, CompareIfRegionBlock)

flatten_cfg_run :: (f: Value_Id) -> Preserved {
    aar := aa_results_for(f);   // AM.getResult<AAManager>(F), held while the CFG changes (like LLVM's)
    ever := false;
    while true {
        // iterativelyFlattenCFG
        blocks: [..] Value_Id; blocks.allocator = temp;
        for b: fn_blocks(f) array_add(*blocks, b);
        changed := false;
        local := true;
        while local {
            local = false;
            for b: blocks {
                if vkind(b) == .DEAD continue;   // WeakVH of an erased block
                if fcfg_flatten_parallel_and_or(b) || fcfg_merge_if_region(b, *aar) local = true;
            }
            changed |= local;
        }
        if !changed break;
        remove_unreachable_blocks(f, null);
        ever = true;
    }
    return ifx ever then PRESERVE_NONE else PRESERVE_ALL;
}

fcfg_flatten_parallel_and_or :: (bb: Value_Id) -> bool {
    if inst_op(block_first(bb)) == .PHI return false;
    last_cond, first_cond, uncond: Value_Id = NONE, NONE, NONE;
    idx := -1;
    // SmallPtrSet<BasicBlock *, 16> Preds(predecessors(BB)): iterated in insertion order while small
    preds_all: [..] Value_Id; preds_all.allocator = temp;
    block_predecessors(bb, *preds_all);
    preds: [..] Value_Id; preds.allocator = temp;
    for p: preds_all array_add_if_unique(*preds, p);
    // Beyond 16 elements the set iterates in pointer order. Every early `return false` below is a property of one
    // predecessor or a count, so only the choice of LastCondBlock can depend on the order: fail loudly when more
    // than one predecessor qualifies for it.
    big := preds.count > 16;
    last_cond_candidates := 0;
    contains :: (s: [] Value_Id, b: Value_Id) -> bool { for s if it == b return true; return false; }
    for pred: preds {
        pp := block_single_predecessor(pred);
        t := block_terminator(pred);
        if inst_op(t) == .BR {
            if uncond != NONE || pp == NONE || !contains(preds, pp) || block_has_address_taken(pred) return false;
            uncond = pred;
            continue;
        }
        if inst_op(t) != .CONDBR return false;
        pc := op(t, 0);
        if !has_one_use(pc) return false;
        if pp != NONE && contains(preds, pp) {
            if block_has_address_taken(pred) return false;
            i := block_first(pred);
            while i != t {
                if inst_op(i) == .PHI || !is_safe_to_speculatively_execute_cx(i, NONE, null) return false;
                i = inst(i).next;
            }
        } else {
            if first_cond != NONE return false;
            first_cond = pred;
        }
        ps1 := get_successor(t, 0); ps2 := get_successor(t, 1);
        ps := ifx ps1 == bb then ps2 else ps1;
        cidx := ifx ps1 == bb then 0 else 1;
        if idx == -1 idx = cidx;
        else if cidx != idx return false;
        if !contains(preds, ps) { last_cond = pred; last_cond_candidates += 1; }
        else if inst_op(block_terminator(ps)) == .BR { last_cond = pred; last_cond_candidates += 1; }
    }
    if big && last_cond_candidates > 1 && first_cond != NONE
        fatal("flatten-cfg: more than 16 predecessors and several LastCondBlock candidates: LLVM iterates its SmallPtrSet in pointer order");
    if first_cond == NONE || last_cond == NONE || first_cond == last_cond return false;

    tbb := block_terminator(last_cond);
    ps1 := get_successor(tbb, 0); ps2 := get_successor(tbb, 1);
    pbi1 := inst_op(block_terminator(ps1)) == .BR;
    pbi2 := inst_op(block_terminator(ps2)) == .BR;
    if !pbi1 || get_successor(block_terminator(ps1), 0) != ps2 {
        if !pbi2 || get_successor(block_terminator(ps2), 0) != ps1 return false;
        cur := last_cond;
        ever := false;
        while cur != first_cond {
            bi := block_terminator(cur);
            ci := op(bi, 0);
            if is_inst(ci) && (inst_op(ci) == .ICMP || inst_op(ci) == .FCMP) {
                p := inst(ci).pred;
                if p == ICMP_NE || p == FCMP_ONE {
                    inst(ci).pred = cmp_inverse(p);
                    condbr_swap_successors(bi);
                    ever = true;
                }
            }
            cur = block_single_predecessor(cur);
        }
        return ever;
    }
    if inst_op(block_first(ps2)) == .PHI return false;

    pbi := block_terminator(first_cond);
    pc := op(pbi, 0);
    b: Irb;
    while true {
        cb := get_successor(pbi, cast(u32) (1 - idx));
        erase_inst_with_metadata(block_last(first_cond));
        block_splice_whole(first_cond, NONE, false, cb);
        pbi = block_terminator(first_cond);
        cc := op(pbi, 0);
        irb_set_before(*b, pbi);
        nc := irb_binop(*b, ifx idx == 0 then Opcode.OR else .AND, pc, cc);
        replace_uses_of_with(pbi, cc, nc);
        pc = nc;
        done := cb == last_cond;
        // CB->dropAllReferences() (now empty); new UnreachableInst(Ctx, CB)
        block_append_inst(cb, new_inst(.UNREACHABLE, ir.t_void, 0));
        if done break;
    }
    return true;
}

fcfg_compare_if_region_block :: (b1: Value_Id, b2: Value_Id, head2: Value_Id, aar: *Aa_Results) -> bool {
    pti2 := block_terminator(head2);
    pbi2 := block_first(head2);
    i1 := block_first(b1); e1 := block_terminator(b1);
    i2 := block_first(b2); e2 := block_terminator(b2);
    while true {
        if i1 == e1 {
            if i2 != e2 return false;
            break;
        }
        if !is_identical_to(i1, i2) return false;
        if may_have_side_effects(i1) {
            if inst_op(i1) != .STORE || is_volatile(i1) return false;
        }
        if may_read_from_memory(i1) return false;
        if may_write_to_memory(i1) {
            x := pbi2;
            while x != pti2 {
                if may_read_from_memory(x) || may_write_to_memory(x) {
                    if aa_mod_ref_inst_inst(aa_query_new(aar), i1, x) != MR_NO return false;
                }
                x = inst(x).next;
            }
        }
        i1 = inst(i1).next;
        i2 = inst(i2).next;
    }
    return true;
}

fcfg_merge_if_region :: (bb: Value_Id, aar: *Aa_Results) -> bool {
    if inst_op(block_first(bb)) == .PHI return false;
    dom_bi2, if_true2, if_false2 := get_if_condition(bb);
    if dom_bi2 == NONE return false;
    cinst2 := op(dom_bi2, 0);
    if !is_inst(cinst2) return false;
    second := inst_block(cinst2);
    if block_has_address_taken(second) return false;
    dom_bi1, if_true1, if_false1 := get_if_condition(second);
    if dom_bi1 == NONE return false;
    cinst1 := op(dom_bi1, 0);
    if !is_inst(cinst1) return false;
    first := inst_block(cinst1);
    if first == second return false;
    invert2 := false;
    combine: Opcode;
    if if_false1 == first {
        combine = .OR;
        if if_false2 != second {
            if if_true2 != second return false;
            invert2 = true;
            x := if_true2; if_true2 = if_false2; if_false2 = x;
        }
        if !fcfg_compare_if_region_block(if_true1, if_true2, second, aar) return false;
    } else if if_true1 == first {
        combine = .AND;
        if if_true2 != second {
            if if_false2 != second return false;
            invert2 = true;
            x := if_true2; if_true2 = if_false2; if_false2 = x;
        }
        if !fcfg_compare_if_region_block(if_false1, if_false2, second, aar) return false;
    } else return false;

    pti2 := block_terminator(second);
    x := block_first(second);
    while x != pti2 {
        if inst_op(x) == .PHI || may_have_side_effects(x) || !is_safe_to_speculatively_execute_cx(x, NONE, null) return false;
        x = inst(x).next;
    }
    erase_inst_with_metadata(block_last(first));
    block_splice_whole(first, NONE, false, second);
    pbi := block_terminator(first);
    b: Irb;
    irb_set_before(*b, pbi);
    if invert2 invert_branch(pbi, *b);
    nc := irb_binop(*b, combine, cinst1, op(pbi, 0));
    replace_uses_of_with(pbi, op(pbi, 0), nc);
    if if_true1 != first fcfg_erase_block(if_true1);
    if if_false1 != first fcfg_erase_block(if_false1);
    fcfg_erase_block(second);
    return true;
}

// BB->dropAllReferences(); BB->eraseFromParent()
fcfg_erase_block :: (bb: Value_Id) {
    for i: block_insts(bb) drop_all_references(i);
    block_erase_from_parent(bb);
}

// ---------------------------------------------------------------- lower-emutls
// llvm/lib/CodeGen/LowerEmuTLS.cpp (LowerEmuTLSPass::run, addEmuTlsVar, copyLinkageVisibility). The new-PM pass
// lowers every thread-local global (it does not ask the TargetMachine whether TLS is emulated).

lower_emutls_run :: () -> Preserved {
    tls: [..] Value_Id; tls.allocator = temp;
    for ir.m_globals if glob(it).tls != 0 array_add(*tls, it);
    changed := false;
    for tls changed |= emutls_add_var(it);
    if !changed return PRESERVE_ALL;
    pa := PRESERVE_ALL;
    pa.abandon_globals_aa = true;   // PA.abandon<GlobalsAA>() (and ModuleSummaryIndex, StackSafetyGlobal)
    return pa;
}

emutls_copy_linkage_visibility :: (from: Value_Id, to: Value_Id) {
    gv_set_linkage(to, glob(from).linkage);
    glob(to).visibility = glob(from).visibility;
    glob(to).dso_local = glob(from).dso_local;
    if glob(from).comdat >= 0 {
        c := get_comdat(vname(to));   // M.getOrInsertComdat(to->getName())
        glob(to).comdat = c;
        ir.comdats[c].kind = ir.comdats[glob(from).comdat].kind;
    }
}

// addEmuTlsVar
emutls_add_var :: (gv: Value_Id) -> bool {
    name := tprint("__emutls_v.%", vname(gv));
    ev := lookup_global(name);
    if ev != NONE && vkind(ev) == .GLOBAL_VAR return false;   // M.getNamedGlobal: added before
    if ev != NONE fatal("lower-emutls: '%' exists and is not a global variable", name);
    null_ptr := const_null_value(ir.t_ptr);
    init: Value_Id = NONE;
    if glob(gv).has_init {
        init = op(gv, 0);
        if vkind(init) == .C_ZERO || (vkind(init) == .C_INT && !is_vector_type(vtype(init)) && is_null_value(init)) init = NONE;
    }
    word := dl_int_ptr_type(ir.t_ptr);
    st := type_named_struct("");   // StructType::create(ElementTypes)
    set_struct_body(st, .[word, word, ir.t_ptr, ir.t_ptr], false);
    ev = module_get_or_insert_global(name, st);
    emutls_copy_linkage_visibility(gv, ev);
    if !glob(gv).has_init return true;
    gty := glob(gv).value_type;
    galign := pointer_alignment(gv);
    tmpl: Value_Id = NONE;
    if init != NONE {
        tname := tprint("__emutls_t.%", vname(gv));
        tmpl = module_get_or_insert_global(tname, gty);
        glob(tmpl).is_const = true;
        gv_set_initializer(tmpl, init);
        glob(tmpl).align = galign;
        emutls_copy_linkage_visibility(gv, tmpl);
    }
    vals := Value_Id.[const_int(word, dl_type_store_size(gty)), const_int(word, galign), null_ptr, ifx tmpl != NONE then tmpl else null_ptr];
    gv_set_initializer(ev, const_aggregate(.C_STRUCT, st, vals));
    glob(ev).align = max(dl_abi_align(word), dl_abi_align(ir.t_ptr));
    return true;
}

// ---------------------------------------------------------------- gc-lowering, collector-metadata
// llvm/lib/CodeGen/GCRootLowering.cpp (GCLoweringPass::run, DoLowering, InsertRootInitializers,
// CouldBecomeSafePoint), llvm/lib/CodeGen/GCMetadata.cpp (CollectorMetadataAnalysis::run, GCFunctionAnalysis::run),
// llvm/lib/IR/GCStrategy.cpp (getGCStrategy) with the builtin strategies of llvm/lib/IR/BuiltinGCs.cpp.

collector_metadata_cached := false;
BUILTIN_GC_STRATEGIES :: string.["erlang", "ocaml", "shadow-stack", "statepoint-example", "coreclr"];

// CollectorMetadataAnalysis::run: a strategy for every GC name of a defined function
collector_metadata_compute :: () {
    for f: ir.m_functions {
        if is_declaration(f) || glob(f).gc.count == 0 continue;
        known := false;
        for BUILTIN_GC_STRATEGIES if it == glob(f).gc known = true;
        if !known verifier_fatal(tprint("unsupported GC: %", glob(f).gc));
    }
    collector_metadata_cached = true;
}

gc_lowering_run :: (f: Value_Id) -> Preserved {
    if glob(f).gc.count == 0 return PRESERVE_ALL;
    // GCFunctionAnalysis::run: the cached CollectorMetadataAnalysis must exist (an assertion in LLVM)
    if !collector_metadata_cached fatal("gc-lowering: the collector-metadata module analysis must be cached (require<collector-metadata>)");
    // DoLowering
    roots: [..] Value_Id; roots.allocator = temp;
    changed := false;
    iid_gcwrite := iid_by_name("llvm.gcwrite");
    iid_gcread := iid_by_name("llvm.gcread");
    iid_gcroot := iid_by_name("llvm.gcroot");
    for bb: fn_blocks(f) for :early_inc i: block_insts(bb) {
        if inst_op(i) != .CALL continue;
        id := call_iid(i);
        if id == NOT_INTRINSIC continue;
        if id == iid_gcwrite {
            st := new_inst(.STORE, ir.t_void, 2);
            set_op(st, 0, call_arg(i, 0));
            set_op(st, 1, call_arg(i, 2));
            inst(st).align = dl_abi_align(vtype(call_arg(i, 0)));   // new StoreInst(Val, Ptr, InsertBefore): ABI alignment
            insert_before_named(st, i, "");
            replace_all_uses_with(i, st);
            erase_inst_with_metadata(i);
            changed = true;
        } else if id == iid_gcread {
            ld := new_inst(.LOAD, vtype(i), 1);
            set_op(ld, 0, call_arg(i, 1));
            inst(ld).align = dl_abi_align(vtype(i));
            insert_before_named(ld, i, "");
            take_name(ld, i);
            replace_all_uses_with(i, ld);
            erase_inst_with_metadata(i);
            changed = true;
        } else if id == iid_gcroot {
            r := strip_pointer_casts(call_arg(i, 0));
            if !is_inst(r) || inst_op(r) != .ALLOCA fatal("gc-lowering: llvm.gcroot of something that is not an alloca");
            array_add(*roots, r);
        }
    }
    if roots.count changed |= gc_insert_root_initializers(f, roots, iid_gcroot);
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    return pa;
}

// InsertRootInitializers
gc_insert_root_initializers :: (f: Value_Id, roots: [] Value_Id, iid_gcroot: Intrinsic_Id) -> bool {
    ip := block_first(fn_entry(f));
    while ip != NONE && inst_op(ip) == .ALLOCA ip = inst(ip).next;
    // CouldBecomeSafePoint
    could_be_safe_point :: (i: Value_Id, iid_gcroot: Intrinsic_Id) -> bool {
        o := inst_op(i);
        if o == .ALLOCA || o == .GEP || o == .STORE || o == .LOAD return false;
        if o == .CALL && call_iid(i) == iid_gcroot return false;
        return true;
    }
    inited: [..] Value_Id; inited.allocator = temp;
    while ip != NONE && !could_be_safe_point(ip, iid_gcroot) {
        if inst_op(ip) == .STORE {
            a := strip_pointer_casts(op(ip, 1));
            if is_inst(a) && inst_op(a) == .ALLOCA array_add_if_unique(*inited, a);
        }
        ip = inst(ip).next;
    }
    changed := false;
    for root: roots {
        found := false;
        for inited if it == root found = true;
        if found continue;
        aty := inst(root).ty2;   // getAllocatedType
        st := new_inst(.STORE, ir.t_void, 2);
        set_op(st, 0, const_null_value(aty));
        set_op(st, 1, root);
        inst(st).align = dl_abi_align(aty);
        // new StoreInst(..., std::next(Root->getIterator()))
        nx := inst(root).next;
        insert_at_position(st, inst_block(root), nx, false);
        changed = true;
    }
    return changed;
}

// ---------------------------------------------------------------- shadow-stack-gc-lowering
// llvm/lib/CodeGen/ShadowStackGCLowering.cpp (ShadowStackGCLoweringPass::run, ShadowStackGCLoweringImpl:
// doInitialization, CollectRoots, ComputeFrameLayout, GetFrameMap, runOnFunction) with EscapeEnumerator
// (pass_tsan.jai, which has no DomTreeUpdater: a cached dominator tree with new invokes fails loudly).

Ssgc :: struct {
    head: Value_Id;
    frame_map_ty: Type_Id;
    roots: [..] struct { call: Value_Id; alloca: Value_Id; };
    offsets: [..] struct { off: u64; size: u64; };
}

shadow_stack_gc_lowering_run :: () -> Preserved {
    // MAM.getResult<CollectorMetadataAnalysis>(M): Map.contains("shadow-stack")
    collector_metadata_compute();
    active := false;
    for f: ir.m_functions if !is_declaration(f) && glob(f).gc == "shadow-stack" active = true;
    if !active return PRESERVE_ALL;
    s: Ssgc;
    s.roots.allocator = temp; s.offsets.allocator = temp;
    changed := ssgc_do_initialization(*s);
    for f: ir.m_functions {
        if ssgc_run_on_function(*s, f) { changed = true; fam_invalidate(f, ssgc_function_pa()); }
    }
    if !changed return PRESERVE_ALL;
    pa := ssgc_function_pa();
    pa.all_fn = true;   // the function analyses were invalidated per function above
    return pa;
}
ssgc_function_pa :: () -> Preserved { pa: Preserved; preserve(*pa, .DOMTREE); return pa; }

// doInitialization (only reached when a function uses gc "shadow-stack"; LLVM checks declarations too)
ssgc_do_initialization :: (s: *Ssgc) -> bool {
    any := false;
    for f: ir.m_functions if glob(f).gc == "shadow-stack" any = true;
    if !any return false;
    s.frame_map_ty = type_named_struct("");
    set_struct_body(s.frame_map_ty, .[ir.t_i32, ir.t_i32], false);
    ctx_set_struct_name(s.frame_map_ty, "gc_map");
    // M.getGlobalVariable("llvm_gc_root_chain"): AllowInternal = false
    h := lookup_global("llvm_gc_root_chain");
    if h != NONE && (vkind(h) != .GLOBAL_VAR || gv_has_local_linkage(h)) h = NONE;
    if h == NONE {
        h = gv_create(ir.t_ptr, false, .LINKONCE_ANY, const_null_value(ir.t_ptr), "llvm_gc_root_chain", NONE, 0, 0);
    } else if glob(h).linkage == .EXTERNAL && !glob(h).has_init {
        gv_set_initializer(h, const_null_value(ir.t_ptr));
        gv_set_linkage(h, .LINKONCE_ANY);
    }
    s.head = h;
    return true;
}

ssgc_run_on_function :: (s: *Ssgc, f: Value_Id) -> bool {
    if glob(f).gc != "shadow-stack" return false;
    // CollectRoots: roots with metadata first
    s.roots.count = 0; s.offsets.count = 0;
    meta: [..] type_of(s.roots[0]); meta.allocator = temp;
    plain: [..] type_of(s.roots[0]); plain.allocator = temp;
    iid_gcroot := iid_by_name("llvm.gcroot");
    for i: fn_insts(f) {
        if inst_op(i) != .CALL || call_iid(i) != iid_gcroot continue;
        a := strip_pointer_casts(call_arg(i, 0));
        if !is_inst(a) || inst_op(a) != .ALLOCA fatal("shadow-stack-gc-lowering: llvm.gcroot of something that is not an alloca");
        m := call_arg(i, 1);
        if is_constant_kind(vkind(m)) && is_null_value(m) array_add(*plain, .{i, a}); else array_add(*meta, .{i, a});
    }
    for meta array_add(*s.roots, it);
    for plain array_add(*s.roots, it);
    if !s.roots.count return false;
    // ComputeFrameLayout
    ptr_size := dl_type_store_size(ir.t_ptr);
    ptr_align := dl_abi_align(ir.t_ptr);
    max_align := ptr_align;
    offset := 2 * ptr_size;
    for s.roots {
        ok, size := alloca_allocation_size_bytes(it.alloca);
        if !ok verifier_fatal("Intrinsic::gcroot requires a fixed size stack object");
        ra := inst(it.alloca).align;
        max_align = max(max_align, ra);
        aligned := align_to(offset, ra);
        array_add(*s.offsets, .{aligned, size});
        offset = aligned + size;
    }
    frame_size := align_to(offset, max_align);
    frame_map := ssgc_get_frame_map(s, f, frame_size / ptr_size - 2);
    cached_dt := cached_domtree(f);
    nblocks := fn_num_blocks(f);

    entry := fn_entry(f);
    b: Irb;
    irb_set_at(*b, entry, block_first(entry), true);   // IRBuilder<> AtEntry(IP->getParent(), IP), IP = begin()
    frame := irb_alloca(*b, type_array(frame_size, ir.t_i8), NONE, "gc_frame");
    inst(frame).align = max_align;
    // SetInsertPointPastAllocas(&F) (the debug location stays)
    b.bb = entry; b.pt = block_first_non_phi_or_dbg_or_alloca(entry); b.head = false;
    ip := b.pt;
    cur_head := irb_load(*b, ir.t_ptr, s.head, dl_abi_align(ir.t_ptr), name = "gc_currhead");
    map_ptr := irb_ptr_add(*b, frame, const_int(ir.t_i64, ptr_size), "gc_frame.map");
    irb_store(*b, frame_map, map_ptr, dl_abi_align(ir.t_ptr));
    last_end := 2 * ptr_size;
    for r, k: s.roots {
        o := s.offsets[k];
        if o.off > last_end {
            pad := irb_ptr_add(*b, frame, const_int(ir.t_i64, last_end));
            irb_memset(*b, pad, const_int(ir.t_i8, 0), const_int(ir.t_i64, o.off - last_end), 1, false);
        }
        slot := irb_ptr_add(*b, frame, const_int(ir.t_i64, o.off), "gc_root");
        take_name(slot, r.alloca);
        replace_all_uses_with(r.alloca, slot);
        last_end = o.off + o.size;
    }
    if frame_size > last_end {
        pad := irb_ptr_add(*b, frame, const_int(ir.t_i64, last_end));
        irb_memset(*b, pad, const_int(ir.t_i8, 0), const_int(ir.t_i64, frame_size - last_end), 1, false);
    }
    while ip != NONE && inst_op(ip) == .STORE ip = inst(ip).next;
    irb_set_at(*b, entry, ip, false);
    irb_store(*b, cur_head, frame, dl_abi_align(ir.t_ptr));
    irb_store(*b, frame, s.head, dl_abi_align(ir.t_ptr));
    // EscapeEnumerator EE(F, "gc_cleanup", /*HandleExceptions=*/true, DTU)
    ee := escape_enumerator(f, "gc_cleanup", true);
    while true {
        pt := escape_enumerator_next(*ee);
        if pt == NONE break;
        x: Irb; irb_set_before(*x, pt);
        saved := irb_load(*x, ir.t_ptr, frame, dl_abi_align(ir.t_ptr), name = "gc_savedhead");
        irb_store(*x, saved, s.head, dl_abi_align(ir.t_ptr));
    }
    if cached_dt && fn_num_blocks(f) != nblocks fatal("shadow-stack-gc-lowering: updating a cached dominator tree for new invokes is not supported yet");
    for s.roots { erase_inst_with_metadata(it.call); erase_inst_with_metadata(it.alloca); }
    s.roots.count = 0; s.offsets.count = 0;
    return true;
}

// GetFrameMap
ssgc_get_frame_map :: (s: *Ssgc, f: Value_Id, frame_size_in_ptrs: u64) -> Value_Id {
    num_meta := 0;
    md: [..] Value_Id; md.allocator = temp;
    for s.roots {
        c := call_arg(it.call, 1);
        if !is_null_value(c) num_meta = it_index + 1;
        array_add(*md, c);
    }
    md.count = num_meta;
    base := const_aggregate(.C_STRUCT, s.frame_map_ty, .[const_int(ir.t_i32, frame_size_in_ptrs), const_int(ir.t_i32, cast(u64) num_meta)]);
    arr_ty := type_array(cast(u64) num_meta, ir.t_ptr);
    arr := const_aggregate(.C_ARRAY, arr_ty, md);
    sty := type_named_struct("");
    set_struct_body(sty, .[s.frame_map_ty, arr_ty], false);
    ctx_set_struct_name(sty, tprint("gc_map.%", num_meta));
    fm := const_aggregate(.C_STRUCT, sty, .[base, arr]);
    return gv_create(sty, true, .INTERNAL, fm, tprint("__gc_%", vname(f)), NONE, 0, 0);
}

// ---------------------------------------------------------------- inline-asm-prepare
// llvm/lib/CodeGen/InlineAsmPrepare.cpp (InlineAsmPreparePass::run, findCallBrs, splitCriticalEdges,
// insertIntrinsicCalls, updateSSA): a callbr whose result is used gets llvm.callbr.landingpad calls in its indirect
// destinations (critical edges split first) and SSAUpdater rewrites the uses.

inline_asm_prepare_opt_run :: (f: Value_Id) -> Preserved {
    cbrs: [..] Value_Id; cbrs.allocator = temp;
    for bb: fn_blocks(f) {
        t := block_terminator(bb);
        if t != NONE && inst_op(t) == .CALLBR && vtype(t) != ir.t_void && has_uses(t) array_add(*cbrs, t);
    }
    if !cbrs.count return PRESERVE_ALL;
    dt := get_domtree(f);
    changed := false;
    for cbr: cbrs {
        // splitCriticalEdges
        o: Crit_Edge_Options; o.dt = dt; o.merge_identical_edges = true;
        n := num_successors(cbr);
        for k: 1..cast(s64) n - 1 {
            i := cast(u32) k;
            if get_successor(cbr, i) == get_successor(cbr, 0) || is_critical_edge(cbr, i, true)
                if split_known_critical_edge(cbr, i, *o) != NONE changed = true;
        }
        changed |= iap_insert_intrinsic_calls(cbr, dt);
    }
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    return pa;
}

// insertIntrinsicCalls
iap_insert_intrinsic_calls :: (cbr: Value_Id, dt: *Dom_Tree) -> bool {
    n := num_successors(cbr);
    if n <= 1 return false;   // getNumIndirectDests() == 0
    s: Ssa_Updater;
    ssa_init(*s, vtype(cbr), vname(cbr));
    ssa_add_available(*s, inst_block(cbr), cbr);
    default_dest := get_successor(cbr, 0);
    ssa_add_available(*s, default_dest, cbr);
    visited: [..] Value_Id; visited.allocator = temp;
    iid := iid_by_name("llvm.callbr.landingpad");
    changed := false;
    for k: 1..cast(s64) n - 1 {
        ind := get_successor(cbr, cast(u32) k);
        if array_find(visited, ind) continue;
        array_add(*visited, ind);
        // Builder.SetInsertPoint(&*IndDest->begin()); CreateIntrinsicWithoutFolding(RetTy, callbr_landingpad, {CBR})
        b: Irb; irb_set_before(*b, block_first(ind));
        decl := get_or_insert_intrinsic_declaration(iid, .[vtype(cbr)]);
        lp := irb_call(*b, decl, .[cbr]);
        ssa_add_available(*s, ind, lp);
        iap_update_ssa(dt, cbr, lp, *s, default_dest, iid);
        changed = true;
    }
    return changed;
}

// updateSSA
iap_update_ssa :: (dt: *Dom_Tree, cbr: Value_Id, lp: Value_Id, s: *Ssa_Updater, default_dest: Value_Id, iid: Intrinsic_Id) {
    uses: [..] Use_Id; uses.allocator = temp;
    u := ir.v_first_use[cbr];
    while u != NONE { array_add(*uses, u); u = ir.u_next[u]; }
    landing := inst_block(lp);
    for u: uses {
        user := ir.u_user[u];
        if inst_op(user) == .CALL && call_iid(user) == iid continue;
        if is_inst(user) && inst_block(user) == landing { use_set(u, lp); continue; }
        // DT.dominates(DefaultDest, U)
        dom: bool;
        if inst_op(user) == .PHI dom = dt_dominates(dt, default_dest, ir.u_aux[u]);
        else dom = dt_properly_dominates(dt, default_dest, inst_block(user));
        if dom continue;
        ssa_rewrite_use(s, u);
    }
}

// ---------------------------------------------------------------- cfguard
// llvm/lib/Transforms/CFGuard/CFGuard.cpp (CFGuardPass::run, CFGuardImpl::doInitialization, runOnFunction,
// insertCFGuardCheck, insertCFGuardDispatch)

cfguard_run :: (f: Value_Id) -> Preserved {
    // doInitialization: Module::getControlFlowGuardMode() == Enabled (2)
    if module_flag_int("cfguard", 0) != 2 return PRESERVE_ALL;
    mech := module_flag_int("cfguard-mechanism", 0);   // ControlFlowGuardMechanism: Automatic 0, Check 1, Dispatch 2
    t := triple_parse(ifx opts.mtriple.count then opts.mtriple else ir.triple);
    dispatch := ifx mech == 1 then false else ifx mech == 2 then true else t.arch == .x86_64;
    name := ifx dispatch then "__guard_dispatch_icall_fptr" else "__guard_check_icall_fptr";
    // M.getOrInsertGlobal(Name, ptr, create an external dso_local declaration)
    g := lookup_global(name);
    if g == NONE {
        g = gv_create(ir.t_ptr, false, .EXTERNAL, NONE, name, NONE, 0, 0);
        glob(g).dso_local = true;
    } else if vkind(g) != .GLOBAL_VAR fatal("cfguard: '%' is not a global variable", name);
    // runOnFunction
    calls: [..] Value_Id; calls.allocator = temp;
    for i: fn_insts(f) {
        if !is_call_base(i) continue;
        callee := call_callee(i);
        indirect := vkind(callee) != .FUNCTION && !is_constant_kind(vkind(callee)) && vkind(callee) != .INLINE_ASM;
        if indirect && !call_has_fn_str_attr(i, "guard_nocf") array_add(*calls, i);
    }
    for cb: calls {
        if t.os != .Win32 fatal("cfguard: Control Flow Guard checks are only applicable for Windows targets");
        callee := call_callee(cb);
        b: Irb; irb_set_before(*b, cb);
        if !dispatch {
            // insertCFGuardCheck: load the check function and call it with the target (keeping a funclet bundle)
            if call_num_bundles(cb) > 0 && call_bundle_index(cb, "funclet") >= 0 fatal("cfguard: funclet bundles are not supported yet");
            ld := irb_load(*b, ir.t_ptr, g, dl_abi_align(ir.t_ptr));
            fty := type_func(ir.t_void, .[ir.t_ptr], false);
            c := new_inst(.CALL, ir.t_void, 2);
            inst(c).ty2 = fty;
            set_op(c, 0, callee); set_op(c, 1, ld);
            irb_insert(*b, c);
            inst(c).cc = 19;   // CallingConv::CFGuard_Check
        } else {
            // insertCFGuardDispatch: the call through the dispatch function with a "cfguardtarget" bundle
            if inst_op(cb) != .CALL && inst_op(cb) != .INVOKE fatal("cfguard: unknown indirect call type");
            ld := irb_load(*b, vtype(callee), g, dl_abi_align(vtype(callee)));
            nc := call_add_bundle(cb, "cfguardtarget", .[callee]);
            // CallInst::Create(CI, OpB) / InvokeInst::Create(II, OpB) keep only the debug location
            mds: [..] Kind_Md; mds.allocator = temp;
            get_all_metadata(nc, *mds);
            for mds if it.kind != 0 set_metadata(nc, it.kind, NONE);
            set_op(nc, nops(nc) - 1, ld);   // setCalledOperand (the callee is the last operand)
            insert_at_position(nc, inst_block(cb), cb, false);
            if vname(cb).count set_name(nc, vname(cb));   // the name is taken while CB still has it
            replace_all_uses_with(cb, nc);
            erase_inst_with_metadata(cb);
        }
    }
    return PRESERVE_NONE;   // doInitialization created the guard global: Changed
}
