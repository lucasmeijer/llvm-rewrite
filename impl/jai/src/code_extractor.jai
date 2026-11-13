// CodeExtractor: a port of llvm/lib/Transforms/Utils/CodeExtractor.cpp (CodeExtractor::extractCodeRegion and its
// helpers: buildExtractionBlockSet, isBlockValidForExtraction, isEligible, CodeExtractorAnalysisCache, findAllocas,
// getLifetimeMarkers, findInputsOutputs, the PHI severing of entry and exits, splitReturnBlocks,
// constructFunctionDeclaration, emitFunctionBody, emitReplacerCall, insertReplacerCall,
// calculateNewCallTerminatorWeights).
//
// Debug info: applyFirstDebugLoc, the replacer call's location, fixupDebugInfoPostExtraction (new DISubprogram,
// DIBuilder records for inputs, variable / label / scope cloning with cloneScopeForSubprogram,
// replaceInlinedAtSubprogram, loop metadata locations, remapAssignID), stripDebugInfo(Function) and
// eraseDebugIntrinsicsWithNonLocalRefs.
//
// Not ported (fail loudly): aggregate arguments (-aggregate-extracted-args / AggregateArgs; no caller asks for
// them), explicit allocation/deallocation blocks, and the out-of-region lifetime markers on in-region casts of an
// alloca (findAllocas' LifetimeBitcastUsers).

Code_Extractor :: struct {
    dt: *Dom_Tree;
    bfi: *Bfi;
    bpi: *Bpi;
    ac: *Assumption_Cache;
    allow_varargs: bool;
    suffix: string;                    // Suffix ("" = the header's name, or "extracted")
    void_return_with_single_output: bool;   // VoidReturnWithSingleOutput
    blocks: [..] Value_Id;             // SetVector<BasicBlock *> Blocks
    in_blocks: Table(Value_Id, bool);
    func_ret_val: Value_Id = NONE;
    exits: [..] Value_Id;              // ExtractedFuncRetVals
}

// CodeExtractorAnalysisCache
Ce_Cache :: struct {
    allocas: [..] Value_Id;
    side_effecting: Table(Value_Id, bool);
    base_addrs: Table(u64, bool);      // (block, base alloca)
}

ce_contains :: inline (ce: *Code_Extractor, b: Value_Id) -> bool { return table_contains(*ce.in_blocks, b); }
ce_insert :: (ce: *Code_Extractor, b: Value_Id) -> bool {
    if ce_contains(ce, b) return false;
    table_set(*ce.in_blocks, b, true);
    array_add(*ce.blocks, b);
    return true;
}
ce_remove :: (ce: *Code_Extractor, b: Value_Id) {
    table_remove(*ce.in_blocks, b);
    for ce.blocks if it == b { array_ordered_remove_by_index(*ce.blocks, it_index); break; }
}
// definedInRegion / definedInCaller
ce_defined_in_region :: (ce: *Code_Extractor, v: Value_Id) -> bool { return is_inst(v) && ce_contains(ce, inst_block(v)); }
ce_defined_in_caller :: (ce: *Code_Extractor, v: Value_Id) -> bool {
    if vkind(v) == .ARGUMENT return true;
    return is_inst(v) && !ce_contains(ce, inst_block(v));
}

// CodeExtractorAnalysisCache::CodeExtractorAnalysisCache
ce_cache_new :: (f: Value_Id) -> Ce_Cache {
    c: Ce_Cache;
    for bb: fn_blocks(f) {
        for i: block_insts(bb) if inst_op(i) == .ALLOCA array_add(*c.allocas, i);
        // findSideEffectInfoForBlock
        for i: block_insts(bb) {
            o := inst_op(i);
            if o == .STORE || o == .LOAD {
                addr := ifx o == .STORE then op(i, 1) else op(i, 0);
                if is_constant_kind(vkind(addr)) continue;
                base := strip_in_bounds_constant_offsets(addr);
                if !(is_inst(base) && inst_op(base) == .ALLOCA) { table_set(*c.side_effecting, bb, true); break; }
                table_set(*c.base_addrs, ((cast(u64) bb) << 32) | base, true);
                continue;
            }
            if o == .CALL && call_iid(i) != NOT_INTRINSIC {
                id := call_iid(i);
                if id == IID_LIFETIME_START || id == IID_LIFETIME_END || id == IID_PSEUDOPROBE continue;
                table_set(*c.side_effecting, bb, true);
                break;
            }
            if may_have_side_effects(i) { table_set(*c.side_effecting, bb, true); break; }
        }
    }
    return c;
}
ce_cache_block_clobbers_addr :: (c: *Ce_Cache, bb: Value_Id, addr: Value_Id) -> bool {
    if table_contains(*c.side_effecting, bb) return true;
    return table_contains(*c.base_addrs, ((cast(u64) bb) << 32) | addr);
}

// isBlockValidForExtraction
ce_is_block_valid :: (ce: *Code_Extractor, bb: Value_Id, allow_varargs: bool, allow_alloca: bool) -> bool {
    if block_has_address_taken(bb) return false;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    for block_insts(bb) array_add(*work, it);
    while work.count {
        cur := pop(*work);
        if table_contains(*visited, cur) continue;
        table_set(*visited, cur, true);
        k := vkind(cur);
        if k == .C_BLOCKADDR return false;
        if k == .INST && inst_block(cur) != bb continue;
        n := nops(cur);
        for x: 0..cast(s64) n - 1 {
            o := op(cur, cast(u32) x);
            if o == NONE continue;
            ok := vkind(o);
            // Users: instructions, constants and globals (not blocks, arguments, metadata or inline asm)
            if ok == .INST || is_constant_kind(ok) array_add(*work, o);
        }
    }
    for i: block_insts(bb) {
        o := inst_op(i);
        if o == .ALLOCA { if !allow_alloca return false; continue; }
        if o == .INVOKE { if !ce_contains(ce, op(i, nops(i) - 2)) return false; continue; }
        if o == .CATCHSWITCH {
            // unwind destination and every handler must be in the region
            for s: ce_terminator_successors(i) if !ce_contains(ce, s) return false;
            continue;
        }
        if o == .CATCHPAD || o == .CLEANUPPAD {
            // the blocks of the catchret / cleanupret users must be in the region
            u := ir.v_first_use[i];
            while u != NONE {
                usr := ir.u_user[u];
                u = ir.u_next[u];
                if !is_inst(usr) continue;
                uo := inst_op(usr);
                if (o == .CATCHPAD && uo == .CATCHRET) || (o == .CLEANUPPAD && uo == .CLEANUPRET)
                    if !ce_contains(ce, inst_block(usr)) return false;
            }
            continue;
        }
        if o == .CLEANUPRET {
            for s: ce_terminator_successors(i) if !ce_contains(ce, s) return false;
            continue;
        }
        if o == .CALL {
            if ((inst(i).flags >> TAIL_SHIFT) & 3) == 2 return false;   // musttail
            f := call_called_function(i);
            if f != NONE {
                id := call_iid(i);
                if id == IID_VASTART { if allow_varargs continue; return false; }
                if id == intrinsic_id_by_name("llvm.eh.typeid.for") return false;
            }
        }
    }
    return true;
}

ce_terminator_successors :: (t: Value_Id) -> [..] Value_Id {
    r: [..] Value_Id; r.allocator = temp;
    for k: 0..cast(s64) num_successors(t) - 1 array_add(*r, get_successor(t, cast(u32) k));
    return r;
}

// CodeExtractor::CodeExtractor (buildExtractionBlockSet)
ce_new :: (bbs: [] Value_Id, dt: *Dom_Tree, bfi: *Bfi, bpi: *Bpi, ac: *Assumption_Cache, allow_varargs: bool, allow_alloca: bool,
           suffix := "", void_return_with_single_output := true) -> Code_Extractor {
    ce: Code_Extractor;
    ce.dt = dt; ce.bfi = bfi; ce.bpi = bpi; ce.ac = ac; ce.allow_varargs = allow_varargs;
    ce.suffix = suffix; ce.void_return_with_single_output = void_return_with_single_output;
    for bb: bbs {
        if dt && !dt_is_reachable_from_entry(dt, bb) continue;
        if !ce_insert(*ce, bb) fatal("internal: code extractor: repeated basic blocks in extraction input");
    }
    valid := true;
    for bb, k: ce.blocks {
        if !ce_is_block_valid(*ce, bb, allow_varargs, allow_alloca) { valid = false; break; }
        if k == 0 {
            if block_is_eh_pad(bb) { valid = false; break; }
            continue;
        }
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(bb, *preds);
        for p: preds if !ce_contains(*ce, p) { valid = false; break; }
        if !valid break;
    }
    if !valid { ce.blocks.count = 0; table_reset(*ce.in_blocks); }
    return ce;
}

// isEligible
ce_is_eligible :: (ce: *Code_Extractor) -> bool {
    if ce.blocks.count == 0 return false;
    header := ce.blocks[0];
    f := block_fn(header);
    if ce.allow_varargs && func_vararg(glob(f).value_type) {
        for bb: fn_blocks(f) {
            if ce_contains(ce, bb) continue;
            for i: block_insts(bb) if inst_op(i) == .CALL && call_called_function(i) != NONE {
                id := call_iid(i);
                if id == IID_VASTART || id == IID_VAEND return false;
            }
        }
    }
    for bb: ce.blocks for i: block_insts(bb) {
        if !(inst_op(i) == .CALL && call_called_function(i) != NONE && glob(call_called_function(i)).intrinsic) continue;
        id := call_iid(i);
        if id == IID_STACKSAVE {
            u := ir.v_first_use[i];
            while u != NONE { if !ce_defined_in_region(ce, ir.u_user[u]) return false; u = ir.u_next[u]; }
        }
        if id == IID_STACKRESTORE && !ce_defined_in_region(ce, call_arg(i, 0)) return false;
    }
    return true;
}

// getCommonExitBlock
ce_common_exit_block :: (ce: *Code_Extractor) -> Value_Id {
    common: Value_Id = NONE;
    succs: [..] Value_Id; succs.allocator = temp;
    for b: ce.blocks {
        succs.count = 0;
        block_successors(b, *succs);
        for s: succs {
            if ce_contains(ce, s) continue;
            if common == NONE { common = s; continue; }
            if common != s return NONE;
        }
    }
    return common;
}

// computeExtractedFuncRetVals
ce_compute_exits :: (ce: *Code_Extractor) {
    ce.exits.count = 0;
    succs: [..] Value_Id; succs.allocator = temp;
    for b: ce.blocks {
        succs.count = 0;
        block_successors(b, *succs);
        for s: succs {
            if ce_contains(ce, s) continue;
            seen := false;
            for ce.exits if it == s { seen = true; break; }
            if !seen array_add(*ce.exits, s);
        }
    }
}

// getSwitchType
ce_switch_type :: (ce: *Code_Extractor) -> Type_Id {
    n := ce.exits.count;
    if n <= 1 return ir.t_void;
    if n == 2 return ir.t_i1;
    return type_int(16);
}

// splitReturnBlocks
ce_split_return_blocks :: (ce: *Code_Extractor) {
    snapshot: [..] Value_Id; snapshot.allocator = temp;
    for ce.blocks array_add(*snapshot, it);
    for b: snapshot {
        t := block_terminator(b);
        if t == NONE || inst_op(t) != .RET continue;
        nb := split_basic_block(b, t, tconcat(vname(b), ".ret"));
        if ce.dt {
            old_node := dt_node(ce.dt, b);
            children: [..] Value_Id; children.allocator = temp;
            c := ce.dt.nodes[old_node].first_child;
            while c >= 0 { array_add(*children, ce.dt.nodes[c].block); c = ce.dt.nodes[c].sibling; }
            dt_add_new_block(ce.dt, nb, b);
            for children dt_change_idom(ce.dt, it, nb);
        }
    }
}

// severSplitPHINodesOfEntry
ce_sever_split_phi_nodes_of_entry :: (ce: *Code_Extractor, header_in: Value_Id) -> Value_Id {
    header := header_in;
    from_region := 0;
    outside := 0;
    if header != fn_entry(block_fn(header)) {
        pn := block_first(header);
        if pn == NONE || inst_op(pn) != .PHI return header;
        for k: 0..cast(s64) nops(pn) - 1 {
            if ce_contains(ce, phi_block(pn, cast(u32) k)) from_region += 1;
            else outside += 1;
        }
        if outside <= 1 return header;
    }
    nb := split_block(header, block_first_non_phi(header), ce.dt, null, head = true);   // getFirstNonPHIIt: head bit
    old_pred := header;
    ce_remove(ce, old_pred);
    ce_insert(ce, nb);
    header = nb;
    if from_region {
        pn := block_first(old_pred);
        for k: 0..cast(s64) nops(pn) - 1 {
            ib := phi_block(pn, cast(u32) k);
            if ce_contains(ce, ib) replace_uses_of_with(block_terminator(ib), old_pred, nb);
        }
        p := block_first(old_pred);
        while p != NONE && inst_op(p) == .PHI {
            next := inst_next(p);
            npn := create_phi(vtype(p), cast(u32) (1 + from_region));
            first := block_first(nb);
            insert_before_named(npn, first, tconcat(vname(p), ".ce"));
            replace_all_uses_with(p, npn);
            phi_add_incoming(npn, p, old_pred);
            // removeIncomingValueIf: the kept entries are compacted in order
            k: u32 = 0;
            keep_v: [..] Value_Id; keep_v.allocator = temp;
            keep_b: [..] Value_Id; keep_b.allocator = temp;
            for x: 0..cast(s64) nops(p) - 1 {
                v := phi_value(p, cast(u32) x); b := phi_block(p, cast(u32) x);
                if ce_contains(ce, b) phi_add_incoming(npn, v, b);
                else { array_add(*keep_v, v); array_add(*keep_b, b); }
            }
            if keep_v.count != nops(p) phi_keep_only(p, keep_v, keep_b);
            p = next;
        }
    }
    return header;
}
// PHINode::removeIncomingValueIf: survivors keep their relative order (copied down with Use::set)
phi_keep_only :: (p: Value_Id, vals: [] Value_Id, blocks: [] Value_Id) {
    for v, k: vals { phi_set_value(p, cast(u32) k, v); phi_set_block(p, cast(u32) k, blocks[k]); }
    while nops(p) > cast(u32) vals.count phi_remove_incoming(p, nops(p) - 1, false);
}

// severSplitPHINodesOfExits
ce_sever_split_phi_nodes_of_exits :: (ce: *Code_Extractor) {
    exits: [..] Value_Id; exits.allocator = temp;
    for ce.exits array_add(*exits, it);
    for exit_bb: exits {
        nb: Value_Id = NONE;
        p := block_first(exit_bb);
        while p != NONE && inst_op(p) == .PHI {
            next := inst_next(p);
            idx: [..] u32; idx.allocator = temp;
            for k: 0..cast(s64) nops(p) - 1 if ce_contains(ce, phi_block(p, cast(u32) k)) array_add(*idx, cast(u32) k);
            if idx.count <= 1 { p = next; continue; }
            if nb == NONE {
                nb = create_block(block_fn(exit_bb), tconcat(vname(exit_bb), ".split"), exit_bb);
                preds: [..] Value_Id; preds.allocator = temp;
                block_predecessors(exit_bb, *preds);
                for pb: preds if ce_contains(ce, pb) replace_uses_of_with(block_terminator(pb), exit_bb, nb);
                block_append_inst(nb, create_br(exit_bb));
                ce_insert(ce, nb);
            }
            npn := create_phi(vtype(p), cast(u32) idx.count);
            insert_before_named(npn, block_first_non_phi(nb), tconcat(vname(p), ".ce"));
            for k: idx phi_add_incoming(npn, phi_value(p, k), phi_block(p, k));
            for < k: idx phi_remove_incoming(p, k, false);
            phi_add_incoming(p, npn, nb);
            p = next;
        }
    }
}

// normalizeCFGForExtraction
ce_normalize_cfg :: (ce: *Code_Extractor, header: Value_Id) -> Value_Id {
    ce_split_return_blocks(ce);
    h := ce_sever_split_phi_nodes_of_entry(ce, header);
    ce_compute_exits(ce);
    ce_sever_split_phi_nodes_of_exits(ce);
    return h;
}

// Lifetime markers of an address (getLifetimeMarkers)
Ce_Lifetime_Info :: struct { life_start: Value_Id = NONE; life_end: Value_Id = NONE; sink_life_start: bool; hoist_life_end: bool; }
ce_lifetime_markers :: (ce: *Code_Extractor, cache: *Ce_Cache, addr: Value_Id, exit_block: Value_Id) -> Ce_Lifetime_Info {
    info: Ce_Lifetime_Info;
    none: Ce_Lifetime_Info;
    u := ir.v_first_use[addr];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if is_inst(usr) && inst_op(usr) == .CALL {
            id := call_iid(usr);
            if id == IID_LIFETIME_START { if info.life_start != NONE return none; info.life_start = usr; continue; }
            if id == IID_LIFETIME_END { if info.life_end != NONE return none; info.life_end = usr; continue; }
        }
        if !ce_defined_in_region(ce, usr) return none;
    }
    if info.life_start == NONE || info.life_end == NONE return none;
    info.sink_life_start = !ce_defined_in_region(ce, info.life_start);
    info.hoist_life_end = !ce_defined_in_region(ce, info.life_end);
    if (info.sink_life_start || info.hoist_life_end) && !ce_legal_to_shrinkwrap(ce, cache, addr) return none;
    if info.hoist_life_end && exit_block == NONE return none;
    return info;
}
// isLegalToShrinkwrapLifetimeMarkers
ce_legal_to_shrinkwrap :: (ce: *Code_Extractor, cache: *Ce_Cache, addr: Value_Id) -> bool {
    ai := strip_in_bounds_constant_offsets(addr);
    f := block_fn(ce.blocks[0]);
    for bb: fn_blocks(f) {
        if ce_contains(ce, bb) continue;
        if ce_cache_block_clobbers_addr(cache, bb, ai) return false;
    }
    return true;
}
Value_Set :: struct { list: [..] Value_Id; member: Table(Value_Id, bool); }
vset_insert :: (s: *Value_Set, v: Value_Id) -> bool {
    if table_contains(*s.member, v) return false;
    table_set(*s.member, v, true);
    array_add(*s.list, v);
    return true;
}
vset_contains :: inline (s: *Value_Set, v: Value_Id) -> bool { return table_contains(*s.member, v); }
vset_init :: (s: *Value_Set) { s.list.allocator = temp; s.member.allocator = temp; }

// findAllocas
ce_find_allocas :: (ce: *Code_Extractor, cache: *Ce_Cache, sink: *Value_Set, hoist: *Value_Set) -> Value_Id {
    f := block_fn(ce.blocks[0]);
    exit_block := ce_common_exit_block(ce);
    move_or_ignore :: (lmi: Ce_Lifetime_Info, sink: *Value_Set, hoist: *Value_Set) -> bool {
        if lmi.life_start == NONE return false;
        if lmi.sink_life_start vset_insert(sink, lmi.life_start);
        if lmi.hoist_life_end vset_insert(hoist, lmi.life_end);
        return true;
    }
    for ai: cache.allocas {
        if vkind(ai) != .INST continue;
        bb := inst_block(ai);
        if ce_contains(ce, bb) continue;
        if block_fn(bb) != f continue;
        lmi := ce_lifetime_markers(ce, cache, ai, exit_block);
        if move_or_ignore(lmi, sink, hoist) { vset_insert(sink, ai); continue; }
        u := ir.v_first_use[ai];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if !ce_defined_in_region(ce, usr) continue;
            if strip_in_bounds_constant_offsets(usr) != ai continue;
            x := ir.v_first_use[usr];
            while x != NONE {
                bu := ir.u_user[x];
                x = ir.u_next[x];
                if !(is_inst(bu) && inst_op(bu) == .CALL && (call_iid(bu) == IID_LIFETIME_START || call_iid(bu) == IID_LIFETIME_END)) continue;
                if ce_defined_in_region(ce, bu) continue;
                fatal("code extractor: an out-of-region lifetime marker on an in-region cast of an alloca is not supported yet");
            }
        }
        casts: [..] Value_Id; casts.allocator = temp;
        infos: [..] Ce_Lifetime_Info; infos.allocator = temp;
        u = ir.v_first_use[ai];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if strip_in_bounds_constant_offsets(usr) == ai {
                l2 := ce_lifetime_markers(ce, cache, usr, exit_block);
                if l2.life_start != NONE { array_add(*casts, usr); array_add(*infos, l2); continue; }
            }
            if !ce_defined_in_region(ce, usr) { casts.count = 0; break; }
        }
        if casts.count == 0 continue;
        vset_insert(sink, ai);
        for c, k: casts {
            move_or_ignore(infos[k], sink, hoist);
            if !ce_defined_in_region(ce, c) vset_insert(sink, c);
        }
    }
    return exit_block;
}

// findInputsOutputs
ce_find_inputs_outputs :: (ce: *Code_Extractor, inputs: *Value_Set, outputs: *Value_Set, sink: *Value_Set, collect_global_inputs := false) {
    for bb: ce.blocks for i: block_insts(bb) {
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            v := op(i, cast(u32) k);
            if v == NONE continue;
            if !vset_contains(sink, v) && (ce_defined_in_caller(ce, v) || (collect_global_inputs && vkind(v) == .GLOBAL_VAR))
                vset_insert(inputs, v);
        }
        u := ir.v_first_use[i];
        while u != NONE {
            if !ce_defined_in_region(ce, ir.u_user[u]) { vset_insert(outputs, i); break; }
            u = ir.u_next[u];
        }
    }
    ce.func_ret_val = NONE;
    if !ce.void_return_with_single_output && outputs.list.count == 1 && ce_common_exit_block(ce) != NONE {
        ce.func_ret_val = outputs.list[0];
        outputs.list.count = 0;
        table_reset(*outputs.member);
    }
}

// eraseLifetimeMarkersOnInputs
ce_erase_lifetime_markers_on_inputs :: (ce: *Code_Extractor, sunk: *Value_Set, starts: *Value_Set) {
    for bb: ce.blocks {
        i := block_first(bb);
        while i != NONE {
            next := inst_next(i);
            defer i = next;
            if !(inst_op(i) == .CALL && (call_iid(i) == IID_LIFETIME_START || call_iid(i) == IID_LIFETIME_END)) continue;
            mem := call_arg(i, 0);
            if vset_contains(sunk, mem) || ce_defined_in_region(ce, mem) continue;
            if call_iid(i) == IID_LIFETIME_START vset_insert(starts, mem);
            erase_inst(i);
        }
    }
}

// findOrCreateBlockForHoisting
ce_find_or_create_block_for_hoisting :: (ce: *Code_Extractor, common_exit: Value_Id) -> Value_Id {
    single: Value_Id = NONE;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(common_exit, *preds);
    multiple := false;
    for p: preds {
        if !ce_contains(ce, p) continue;
        if single == NONE single = p;
        else if single != p { single = NONE; multiple = true; break; }
    }
    if single != NONE return single;
    nb := split_basic_block(common_exit, block_first_non_phi(common_exit), "", head = true);   // getFirstNonPHIIt
    preds.count = 0;
    block_predecessors(common_exit, *preds);
    for p: preds {
        if ce_contains(ce, p) continue;
        replace_uses_of_with(block_terminator(p), common_exit, nb);
    }
    ce_insert(ce, common_exit);
    return common_exit;
}

// Move `i` (any function) to the front of `bb` (moveBefore(*BB, getFirstInsertionPt())), re-registering its name
// in the destination function's symbol table.
ce_move_inst_to_front :: (i: Value_Id, bb: Value_Id) {
    name := vname(i);
    if name.count set_name(i, "");
    // moveBefore(BB, getFirstInsertionPt()): the iterator has the head bit, so i's records stay behind (they fall
    // onto the next instruction) and none are adopted at the destination
    if inst(i).records {
        nx := inst_next(i);
        if nx == NONE fatal("code extractor: moving a terminator with debug records");
        records_prepend(nx, records_take(i));
    }
    inst_unlink(i);
    pt := block_first_insertion_pt(bb);
    if pt != NONE inst_insert_before(i, pt); else block_append_inst(bb, i);
    if name.count set_name(i, name);
}
// moveCodeToFunction: Block->removeFromParent(); NewFunction->insert(after the previous)
ce_move_code_to_function :: (ce: *Code_Extractor, nf: Value_Id) {
    after := fn_entry(nf);
    for b: ce.blocks {
        of := block_fn(b);
        // removeFromParent drops the instruction and block names from the old symbol table; inserting into the
        // new function adds the instruction names (BasicBlock::setParent) and then the block's name
        inames: [..] string; inames.allocator = temp;
        ivals: [..] Value_Id; ivals.allocator = temp;
        for i: block_insts(b) if vname(i).count { array_add(*inames, vname(i)); array_add(*ivals, i); }
        bname := vname(b);
        for ivals set_name(it, "");
        if bname.count set_name(b, "");
        fn_unlink_block(of, b);
        fn_insert_block_after(nf, after, b);
        block(b).parent = nf;
        note_block_created(nf, b);
        for ivals set_name(it, inames[it_index]);
        if bname.count set_name(b, bname);
        after = b;
    }
}

// constructFunctionDeclaration
ce_construct_function_declaration :: (ce: *Code_Extractor, inputs: *Value_Set, outputs: *Value_Set, entry_freq: u64, name: string) -> Value_Id {
    old := block_fn(ce.blocks[0]);
    params: [..] Type_Id; params.allocator = temp;
    for inputs.list array_add(*params, vtype(it));
    for outputs.list array_add(*params, type_ptr(dl_alloca_addrspace()));
    ret := ifx ce.func_ret_val != NONE then vtype(ce.func_ret_val) else ce_switch_type(ce);
    ft := type_func(ret, params, ce.allow_varargs && func_vararg(glob(old).value_type));
    nf := new_function(ft, "", glob(old).addrspace);
    gv_set_linkage(nf, .INTERNAL);
    array_add(*ir.m_functions, nf);
    set_name(nf, name);
    if glob(old).has_personality {
        set_op(nf, 0, op(old, 0));
        glob(nf).has_personality = true;
    }
    fn_set: [..] Attr; fn_set.allocator = temp;
    for at: attr_set_items(attr_list_fn(glob(old).attrs)) {
        if at.kind == .STRING_ATTR {
            if at.key == "thunk" continue;
        } else {
            if at.kind == {
                case .AllocSize; #through; case .Builtin; #through; case .Convergent; #through; case .JumpTable; #through;
                case .Naked; #through; case .NoBuiltin; #through; case .NoMerge; #through; case .NoReturn; #through;
                case .NoSync; #through; case .ReturnsTwice; #through; case .Speculatable; #through;
                case .StackAlignment; #through; case .WillReturn; #through; case .AllocKind; #through;
                case .PresplitCoroutine; #through; case .Memory; #through; case .NoFPClass; #through;
                case .CoroDestroyOnlyWhenComplete; #through; case .CoroElideSafe; #through;
                case .NoDivergenceSource; #through; case .NoCreateUndefOrPoison;
                    continue;
            }
        }
        array_add(*fn_set, at);
    }
    if fn_set.count glob(nf).attrs = attr_list_with_fn(glob(nf).attrs, attr_set_get(fn_set));
    for v, k: inputs.list {
        a := fn_arg(nf, cast(u32) k);
        if vname(v).count set_name(a, vname(v));
        if is_swift_error(v) fn_add_param_attr_kind(nf, cast(u32) k, .SwiftError);
    }
    for v, k: outputs.list set_name(fn_arg(nf, cast(u32) (inputs.list.count + k)), tconcat(vname(v), ".out"));
    if ce.bfi {
        ok, count := bfi_profile_count_from_freq(ce.bfi, old, entry_freq);
        if ok fn_set_entry_count(nf, count);
    }
    return nf;
}

// emitFunctionBody
ce_emit_function_body :: (ce: *Code_Extractor, inputs: *Value_Set, outputs: *Value_Set, nf: Value_Id, header: Value_Id, sink: *Value_Set) {
    old := block_fn(header);
    root := create_block(nf, "newFuncRoot");
    for v: sink.list if !(is_inst(v) && inst_op(v) == .ALLOCA) ce_move_inst_to_front(v, root);
    for v: sink.list if is_inst(v) && inst_op(v) == .ALLOCA ce_move_inst_to_front(v, root);
    new_values: [..] Value_Id; new_values.allocator = temp;
    for v, k: inputs.list array_add(*new_values, fn_arg(nf, cast(u32) k));
    ce_move_code_to_function(ce, nf);
    for v, k: inputs.list {
        users: [..] Value_Id; users.allocator = temp;
        u := ir.v_first_use[v];
        while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
        for usr: users if is_inst(usr) && ce_contains(ce, inst_block(usr)) replace_uses_of_with(usr, v, new_values[k]);
    }
    stubs: [..] Value_Id; stubs.allocator = temp;
    n := ce.exits.count;
    for old_target, k: ce.exits {
        nt := create_block(nf, tconcat(vname(old_target), ".exitStub"));
        array_add(*stubs, nt);
        brv: Value_Id = NONE;
        if n == 1 { if ce.func_ret_val != NONE brv = ce.func_ret_val; }
        else if n == 2 brv = const_int(ir.t_i1, ifx k == 0 then cast(u64) 1 else 0);
        else brv = const_int(type_int(16), cast(u64) k);
        ret := new_inst(.RET, ir.t_void, ifx brv != NONE then cast(u32) 1 else 0);
        if brv != NONE set_op(ret, 0, brv);
        block_append_inst(nt, ret);
    }
    for b: ce.blocks {
        t := block_terminator(b);
        ns := num_successors(t);
        for k: 0..cast(s64) ns - 1 {
            s := get_successor(t, cast(u32) k);
            if ce_contains(ce, s) continue;
            idx := -1;
            for ce.exits if it == s { idx = it_index; break; }
            set_successor(t, cast(u32) k, stubs[idx]);
        }
    }
    p := block_first(header);
    while p != NONE && inst_op(p) == .PHI {
        for k: 0..cast(s64) nops(p) - 1 if !ce_contains(ce, phi_block(p, cast(u32) k)) phi_set_block(p, cast(u32) k, root);
        p = inst_next(p);
    }
    br := create_br(header);
    block_append_inst(root, br);
    // applyFirstDebugLoc
    if get_metadata(old, MDK_DBG) != NONE {
        done := false;
        for b: ce.blocks {
            for i: block_insts(b) {
                dl := get_metadata(i, MDK_DBG);
                if dl != NONE { set_metadata(br, MDK_DBG, dl); done = true; break; }
            }
            if done break;
        }
    }
    for v, k: outputs.list {
        a := fn_arg(nf, cast(u32) (inputs.list.count + k));
        pt: Value_Id = NONE;
        o := inst_op(v);
        if o == .INVOKE pt = block_first_insertion_pt(op(v, nops(v) - 3));
        else if o == .PHI pt = block_first_insertion_pt(inst_block(v));
        else pt = inst_next(v);
        st := new_inst(.STORE, ir.t_void, 2);
        set_op(st, 0, v); set_op(st, 1, a);
        inst(st).align = dl_alignment(vtype(v), true);
        inst_insert_before(st, pt);
        // inserting at std::next(Output) (no head bit) adopts the records attached there
        if o != .INVOKE && o != .PHI && inst(pt).records records_append(st, records_take(pt));
    }
    if n == 0 {
        any_ret := false;
        for b: ce.blocks { t := block_terminator(b); if inst_op(t) == .RET || inst_op(t) == .RESUME any_ret = true; }
        if !any_ret fn_add_fn_attr_kind(nf, .NoReturn);
    }
}

// emitReplacerCall
ce_emit_replacer_call :: (ce: *Code_Extractor, inputs: *Value_Set, outputs: *Value_Set, nf: Value_Id, old: Value_Id, repl_ip: Value_Id, entry_freq: u64, lifetimes_start: [] Value_Id) -> Value_Id {
    code_replacer := create_block(old, "codeRepl", repl_ip);
    alloca_block := fn_entry(old);
    if ce.bfi bfi_set_block_freq(ce.bfi, code_replacer, entry_freq);
    params: [..] Value_Id; params.allocator = temp;
    for inputs.list array_add(*params, it);
    reload_outputs: [..] Value_Id; reload_outputs.allocator = temp;
    for v: outputs.list {
        t := vtype(v);
        a := create_alloca_unlinked(t, dl_alloca_addrspace(), dl_pref_align(t));
        pt := block_first_insertion_pt(alloca_block);
        insert_before_named(a, pt, tconcat(vname(v), ".loc"));
        array_add(*params, a);
        array_add(*reload_outputs, a);
    }
    fty := glob(nf).value_type;
    call := new_inst(.CALL, func_ret(fty), cast(u32) (params.count + 1));
    inst(call).ty2 = fty;
    for params set_op(call, cast(u32) it_index, it);
    set_op(call, cast(u32) params.count, nf);
    insert_at_end_named(call, code_replacer, ifx ce.exits.count > 1 then "targetBlock" else "");
    if get_metadata(old, MDK_DBG) != NONE {
        dl := get_metadata(block_terminator(fn_entry(nf)), MDK_DBG);
        if dl != NONE set_metadata(call, MDK_DBG, dl);
    }
    for v, k: inputs.list if is_swift_error(v) call_add_param_attr_kind(call, cast(u32) k, .SwiftError);
    for v, k: outputs.list {
        t := vtype(v);
        ld := new_inst(.LOAD, t, 1);
        set_op(ld, 0, reload_outputs[k]);
        inst(ld).align = dl_alignment(t, true);
        insert_at_end_named(ld, code_replacer, tconcat(vname(v), ".reload"));
    }
    old_ret := fn_ret_type(old);
    n := ce.exits.count;
    if n == 0 {
        term: Value_Id;
        if fn_has_fn_attr(nf, .NoReturn) term = new_inst(.UNREACHABLE, ir.t_void, 0);
        else if type_kind(old_ret) == .VOID term = new_inst(.RET, ir.t_void, 0);
        else {
            term = new_inst(.RET, ir.t_void, 1);
            set_op(term, 0, const_null_value(old_ret));   // i16 0 when the old function returns i16, else its null
        }
        block_append_inst(code_replacer, term);
    } else if n == 1 {
        block_append_inst(code_replacer, create_br(ce.exits[0]));
    } else if n == 2 {
        block_append_inst(code_replacer, create_cond_br(call, ce.exits[0], ce.exits[1]));
    } else {
        // SwitchInst on the call: the default destination is the last exit, whose case is removed
        sw := create_switch(call, ce.exits[n - 1], cast(u32) (n - 1));
        for k: 0..n - 2 sw_add_case(sw, const_int(type_int(16), cast(u64) k), ce.exits[k]);
        block_append_inst(code_replacer, sw);
    }
    // insertLifetimeMarkersSurroundingCall (outputs), then for the inputs' lifetime starts
    term := block_terminator(code_replacer);
    for a: reload_outputs {
        f := get_or_insert_intrinsic_declaration(IID_LIFETIME_START, .[vtype(a)]);
        m := ce_new_call(f, a);
        inst_insert_before(m, call);
    }
    for a: reload_outputs {
        f := get_or_insert_intrinsic_declaration(IID_LIFETIME_END, .[vtype(a)]);
        m := ce_new_call(f, a);
        inst_insert_before(m, term);
    }
    for a: lifetimes_start {
        f := get_or_insert_intrinsic_declaration(IID_LIFETIME_START, .[vtype(a)]);
        m := ce_new_call(f, a);
        inst_insert_before(m, call);
    }
    return call;
}
ce_new_call :: (f: Value_Id, a: Value_Id) -> Value_Id {
    fty := glob(f).value_type;
    c := new_inst(.CALL, func_ret(fty), 2);
    inst(c).ty2 = fty;
    set_op(c, 0, a); set_op(c, 1, f);
    return c;
}

// insertReplacerCall
ce_insert_replacer_call :: (ce: *Code_Extractor, old: Value_Id, header: Value_Id, call: Value_Id, outputs: *Value_Set, reloads: [] Value_Id, exit_weights: *Table(Value_Id, u64)) {
    code_replacer := inst_block(call);
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[header];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for usr: users {
        if !is_inst(usr) || !is_terminator(inst_op(usr)) continue;
        if inst_fn(usr) != old || ce_contains(ce, inst_block(usr)) continue;
        replace_uses_of_with(usr, header, code_replacer);
    }
    for exit_bb: ce.exits {
        p := block_first(exit_bb);
        while p != NONE && inst_op(p) == .PHI {
            done := false;
            for k: 0..cast(s64) nops(p) - 1 {
                if !ce_contains(ce, phi_block(p, cast(u32) k)) continue;
                if !done { phi_set_block(p, cast(u32) k, code_replacer); done = true; }
            }
            p = inst_next(p);
        }
    }
    for v, k: outputs.list {
        users.count = 0;
        u := ir.v_first_use[v];
        while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
        for usr: users if is_inst(usr) && inst_fn(usr) == old replace_uses_of_with(usr, v, reloads[k]);
    }
    if ce.func_ret_val != NONE {
        u := ir.v_first_use[ce.func_ret_val];
        while u != NONE {
            nx := ir.u_next[u];
            if inst_fn(ir.u_user[u]) == old use_set(u, call);
            u = nx;
        }
    }
    if ce.bfi && ce.exits.count > 1 ce_calculate_new_call_terminator_weights(ce, code_replacer, exit_weights);
}

// calculateNewCallTerminatorWeights
ce_calculate_new_call_terminator_weights :: (ce: *Code_Extractor, code_replacer: Value_Id, exit_weights: *Table(Value_Id, u64)) {
    t := block_terminator(code_replacer);
    ns := num_successors(t);
    weights := NewArray(ns, u32,, temp);
    probs := NewArray(ns, u32,, temp);
    for * probs it.* = BP_UNKNOWN;
    dist: Bfi_Dist; dist.weights.allocator = temp;
    for k: 0..cast(s64) ns - 1 {
        _, f := table_find(exit_weights, get_successor(t, cast(u32) k));
        if f != 0 bfi_dist_add(*dist, cast(u32) k, f, .EXIT);
        else probs[k] = 0;
    }
    if dist.total == 0 { bpi_set_edge_probability(ce.bpi, code_replacer, probs); return; }
    bfi_dist_normalize(*dist);
    for w: dist.weights {
        weights[w.target] = cast(u32) w.amount;
        probs[w.target] = bp_make(w.amount, dist.total);
    }
    bpi_set_edge_probability(ce.bpi, code_replacer, probs);
    set_branch_weights(t, weights);
}

// CodeExtractor::extractCodeRegion
ce_extract_code_region :: (ce: *Code_Extractor, cache: *Ce_Cache) -> Value_Id {
    if !ce_is_eligible(ce) return NONE;
    header := ce.blocks[0];
    old := block_fn(header);
    // fixupDebugInfoPostExtraction / stripDebugInfo: not ported
    header = ce_normalize_cfg(ce, header);
    for b: ce.blocks {
        i := block_first(b);
        while i != NONE {
            next := inst_next(i);
            if inst_op(i) == .CALL && call_iid(i) == IID_ASSUME {
                if ce.ac ac_unregister_assumption(ce.ac, i);
                erase_inst(i);
            }
            i = next;
        }
    }
    sink: Value_Set; vset_init(*sink);
    hoist: Value_Set; vset_init(*hoist);
    common_exit := ce_find_allocas(ce, cache, *sink, *hoist);
    inputs: Value_Set; vset_init(*inputs);
    outputs: Value_Set; vset_init(*outputs);
    ce_find_inputs_outputs(ce, *inputs, *outputs, *sink);
    lifetimes_start: Value_Set; vset_init(*lifetimes_start);
    ce_erase_lifetime_markers_on_inputs(ce, *sink, *lifetimes_start);
    if hoist.list.count {
        hb := ce_find_or_create_block_for_hoisting(ce, common_exit);
        t := block_terminator(hb);
        for hoist.list inst_move_before_dbg(it, t);
        ce_compute_exits(ce);
    }
    entry_freq: u64 = 0;
    exit_weights: Table(Value_Id, u64); exit_weights.allocator = temp;
    if ce.bfi {
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(header, *preds);
        for p: preds {
            if ce_contains(ce, p) continue;
            entry_freq = freq_add(entry_freq, bp_scale(bpi_edge_probability(ce.bpi, p, header), bfi_get_block_freq(ce.bfi, p)));
        }
        for s: ce.exits {
            preds.count = 0;
            block_predecessors(s, *preds);
            for b: preds {
                if !ce_contains(ce, b) continue;
                _, cur := table_find(*exit_weights, s);
                table_set(*exit_weights, s, freq_add(cur, bp_scale(bpi_edge_probability(ce.bpi, b, s), bfi_get_block_freq(ce.bfi, b))));
            }
        }
    }
    repl_ip := header;
    while repl_ip != NONE && ce_contains(ce, repl_ip) repl_ip = block(repl_ip).next;
    suffix := ce.suffix;
    if !suffix.count suffix = ifx vname(header).count then vname(header) else "extracted";
    nf := ce_construct_function_declaration(ce, *inputs, *outputs, entry_freq, tconcat(vname(old), ".", suffix));
    ce_emit_function_body(ce, *inputs, *outputs, nf, header, *sink);
    call := ce_emit_replacer_call(ce, *inputs, *outputs, nf, old, repl_ip, entry_freq, lifetimes_start.list);
    reloads: [..] Value_Id; reloads.allocator = temp;
    for i: block_insts(inst_block(call)) if inst_op(i) == .LOAD array_add(*reloads, i);
    ce_insert_replacer_call(ce, old, header, call, *outputs, reloads, *exit_weights);
    new_values: [..] Value_Id; new_values.allocator = temp;
    for v, k: inputs.list array_add(*new_values, fn_arg(nf, cast(u32) k));
    ce_fixup_debug_info_post_extraction(old, nf, call, inputs.list, new_values);
    { table_remove(*fam, old); ac_virtual_clear(old); }
    return nf;
}
// BlockFrequency::operator+= (saturating)
freq_add :: (a: u64, b: u64) -> u64 { s := a + b; if s < a return 0xFFFF_FFFF_FFFF_FFFF; return s; }

// ---------------------------------------------------------------- debug info

// findDbgUsers(V) over the whole module: the records of `fs` whose location (or dbg_assign address) refers to v,
// direct users first, in reverse tracking order (find_dbg_users per function, merged)
ce_find_dbg_users_in :: (fs: [] Value_Id, v: Value_Id) -> [..] u32 {
    all: [..] u32; all.allocator = temp;
    one: [..] u32; one.allocator = temp;
    for f: fs {
        find_dbg_users(f, v, *one);
        for one array_add(*all, it);
    }
    is_direct :: (r: u32, v: Value_Id) -> bool {
        rec := dbgr(r);
        return (rec.loc != NONE && ir.mds[rec.loc].kind == .VALUE && ir.mds[rec.loc].value == v) ||
               (rec.kind == .ASSIGN && rec.addr != NONE && ir.mds[rec.addr].kind == .VALUE && ir.mds[rec.addr].value == v);
    }
    // order: direct users by stamp (descending), then the arg-list users by (list stamp, stamp) descending
    before :: (a: u32, b: u32, v: Value_Id) -> bool {
        da := is_direct(a, v); db := is_direct(b, v);
        if da != db return da;
        if da return dbgr_stamp(a) > dbgr_stamp(b);
        la := arglist_stamp(dbgr(a).loc); lb := arglist_stamp(dbgr(b).loc);
        if la != lb return la > lb;
        return dbgr_stamp(a) > dbgr_stamp(b);
    }
    for i: 1..all.count - 1 {
        x := all[i];
        j := i - 1;
        while j >= 0 && before(x, all[j], v) { all[j + 1] = all[j]; j -= 1; }
        all[j + 1] = x;
    }
    return all;
}

// stripDebugInfo(Function &)
ce_strip_debug_info_function :: (f: Value_Id) {
    set_metadata(f, MDK_DBG, NONE);
    loop_kind := md_fixed("llvm.loop");
    heap := md_kind_id("heapallocsite");
    assign := md_fixed("DIAssignID");
    loop_map: Table(Md_Id, Md_Id); loop_map.allocator = temp;
    for b: fn_blocks(f) for i: block_insts(b) {
        set_metadata(i, MDK_DBG, NONE);
        lid := get_metadata(i, loop_kind);
        if lid != NONE {
            found, nl := table_find(*loop_map, lid);
            if !found { nl = strip_debug_loc_from_loop_id(lid); table_add(*loop_map, lid, nl); }
            if nl != lid set_metadata(i, loop_kind, nl);
        }
        set_metadata(i, heap, NONE);
        set_metadata(i, assign, NONE);
        // dropDbgRecords
        while inst(i).records dbgr_erase(inst(i).records);
    }
}

// eraseDebugIntrinsicsWithNonLocalRefs(F): records outside F that refer to an instruction of F (only the function the
// code was extracted from can have them)
ce_erase_debug_records_with_non_local_refs :: (nf: Value_Id, old: Value_Id) {
    doomed: [..] u32; doomed.allocator = temp;
    vals: [..] Value_Id; vals.allocator = temp;
    for b: fn_blocks(old) for i: block_insts(b) {
        r := inst(i).records;
        while r != 0 {
            vals.count = 0;
            rec := dbgr(r);
            dbgr_values_of_loc(rec.loc, *vals);
            if rec.kind == .ASSIGN dbgr_values_of_loc(rec.addr, *vals);
            for vals if is_inst(it) && inst_fn(it) == nf { array_add(*doomed, r); break; }
            r = rec.next;
        }
    }
    for doomed dbgr_erase(it);
    if doomed.count dbgr_index_reset();
}

// DILocalScope::cloneScopeForSubprogram
ce_clone_scope_for_subprogram :: (root: Md_Id, new_sp: Md_Id, cache: *Table(Md_Id, Md_Id)) -> Md_Id {
    chain: [..] Md_Id; chain.allocator = temp;
    cached: Md_Id = NONE;
    sc := root;
    while !is_di(sc, .SUBPROGRAM) {
        found, c := table_find(cache, sc);
        if found { cached = c; break; }
        array_add(*chain, sc);
        sc = di_op(sc, 1);   // DILexicalBlockBase::getScope
    }
    updated := ifx cached != NONE then cached else new_sp;
    for < x: chain {
        // cloneAndReplaceParentScope: clone, replace the scope, replaceWithUniqued
        ops: [..] Md_Id; ops.allocator = temp;
        for k: 0..cast(s64) ir.mds[x].nops - 1 array_add(*ops, md_op(x, cast(u32) k));
        ops[1] = updated;
        ints: [..] u64; ints.allocator = temp;
        for k: 0..cast(s64) ir.mds[x].nints - 1 array_add(*ints, di_int(x, cast(u32) k));
        updated = di_get(di_kind(x), false, ops, ints);
        table_set(cache, x, updated);
    }
    return updated;
}

// DebugLoc::replaceInlinedAtSubprogram
ce_replace_inlined_at_subprogram :: (root: Md_Id, new_sp: Md_Id, cache: *Table(Md_Id, Md_Id)) -> Md_Id {
    chain: [..] Md_Id; chain.allocator = temp;
    cached: Md_Id = NONE;
    l := root;
    while l != NONE {
        found, c := table_find(cache, l);
        if found { cached = c; break; }
        array_add(*chain, l);
        l = diloc_inlined_at(l);
    }
    updated := cached;
    if updated == NONE {
        last := pop(*chain);
        ns := ce_clone_scope_for_subprogram(diloc_scope(last), new_sp, cache);
        updated = di_location_get(diloc_line(last), diloc_col(last), ns, NONE);
        table_set(cache, last, updated);
    }
    for < x: chain {
        updated = di_location_get(diloc_line(x), diloc_col(x), diloc_scope(x), updated);
        table_set(cache, x, updated);
    }
    return updated;
}

// updateLoopMetadataDebugLocations(I, replaceInlinedAtSubprogram of DILocations)
ce_update_loop_metadata_debug_locations :: (i: Value_Id, new_sp: Md_Id, cache: *Table(Md_Id, Md_Id)) {
    k_loop := md_fixed("llvm.loop");
    orig := get_metadata(i, k_loop);
    if orig == NONE return;
    updater :: (m: Md_Id, new_sp: Md_Id, cache: *Table(Md_Id, Md_Id)) -> Md_Id {
        if m != NONE && is_di(m, .LOCATION) return ce_replace_inlined_at_subprogram(m, new_sp, cache);
        return m;
    }
    recursive :: (m: Md_Id, new_sp: Md_Id, cache: *Table(Md_Id, Md_Id)) -> Md_Id {
        if m == NONE || ir.mds[m].kind != .TUPLE || md_nops(m) < 1 return m;
        o0 := md_op(m, 0);
        if o0 == NONE || ir.mds[o0].kind != .STRING return m;
        updated := false;
        ops: [..] Md_Id; ops.allocator = temp;
        array_add(*ops, o0);
        for k: 1..cast(s64) md_nops(m) - 1 {
            x := md_op(m, cast(u32) k);
            if x == NONE { array_add(*ops, NONE); continue; }
            nx := updater(recursive(x, new_sp, cache), new_sp, cache);
            if nx != NONE array_add(*ops, nx);
            updated |= nx != x;
        }
        if updated return md_tuple(ops, false);
        return m;
    }
    ops: [..] Md_Id; ops.allocator = temp;
    array_add(*ops, NONE);
    // LLVM's operand count: a DILocation has its inlinedAt operand only when there is one
    n := cast(s64) md_nops(orig);
    if is_di(orig, .LOCATION) && diloc_inlined_at(orig) == NONE n = 1;
    for k: 1..n - 1 {
        x := md_op(orig, cast(u32) k);
        if x == NONE { array_add(*ops, NONE); continue; }
        nx := updater(recursive(x, new_sp, cache), new_sp, cache);
        if nx != NONE array_add(*ops, nx);
    }
    nl := md_tuple(ops, true);
    ir.md_ops[ir.mds[nl].ops] = nl;
    set_metadata(i, k_loop, nl);
}

// at::remapAssignID
ce_remap_assign_id :: (map: *Table(Md_Id, Md_Id), i: Value_Id) {
    get_new_id :: (map: *Table(Md_Id, Md_Id), old_id: Md_Id) -> Md_Id {
        found, n := table_find(map, old_id);
        if found && n != NONE return n;
        n = di_get(.ASSIGN_ID, true, .[], .[]);
        table_set(map, old_id, n);
        return n;
    }
    r := inst(i).records;
    while r != 0 {
        rec := dbgr(r);
        if rec.kind == .ASSIGN rec.assign_id = get_new_id(map, rec.assign_id);
        r = rec.next;
    }
    k_assign := md_fixed("DIAssignID");
    id := get_metadata(i, k_assign);
    if id != NONE set_metadata(i, k_assign, get_new_id(map, id));
}

// new DbgVariableRecord of `kind` (value or declare) inserted before `before`
ce_insert_record_before :: (kind: Dbg_Record_Kind, v: Value_Id, var: Md_Id, expr: Md_Id, dbg: Md_Id, before: Value_Id) {
    r := dbgr_insert_value_before(v, var, expr, dbg, before);
    dbgr(r).kind = kind;
}

// fixupDebugInfoPostExtraction
ce_fixup_debug_info_post_extraction :: (old: Value_Id, nf: Value_Id, the_call: Value_Id, inputs: [] Value_Id, new_values: [] Value_Id) {
    dbgr_index_reset();
    old_sp := get_metadata(old, MDK_DBG);
    if old_sp == NONE {
        ce_strip_debug_info_function(nf);
        ce_erase_debug_records_with_non_local_refs(nf, old);
        dbgr_index_reset();
        return;
    }
    // DIBuilder::createFunction(Unit, Name, Name, File, 0, createSubroutineType({}), 0, FlagZero,
    // Definition | Optimized | LocalToUnit): distinct, scope null (getNonCompileUnitScope(CU)), no retained nodes yet
    unit := di_op(old_sp, 5);
    file := di_op(old_sp, 0);
    sp_type := di_get(.SUBROUTINE_TYPE, false, .[NONE, NONE, NONE, NONE, NONE, md_tuple(.[], false)], .[0, 0]);
    name := md_string(vname(nf));
    sp_flags: u64 = SPFLAG_DEFINITION | SPFLAG_OPTIMIZED | SPFLAG_LOCAL_TO_UNIT;
    new_sp := di_get(.SUBPROGRAM, true, .[file, NONE, name, name, sp_type, unit, NONE, NONE, NONE, NONE, NONE, NONE, NONE],
                     .[0, 0, 0, 0, 0, sp_flags, 0]);
    set_metadata(nf, MDK_DBG, new_sp);
    tracked := false;   // DIBuilder::SubprogramTrackedNodes has an entry for new_sp (createAutoVariable was called)

    empty_expr := di_get(.EXPRESSION, false, .[], .[]);
    fs: [2] Value_Id = .[old, nf];
    for input, k: inputs {
        users := ce_find_dbg_users_in(fs, input);
        nv := new_values[k];
        for r: users {
            rec := dbgr(r);
            if inst_fn(rec.owner) == nf { dbgr_replace_variable_location_op(r, input, nv); continue; }
            entry := fn_entry(nf);
            if rec.kind == .DECLARE {
                // insertDeclare(.., BasicBlock *InsertAtEnd): before the terminator
                ce_insert_record_before(.DECLARE, nv, rec.var, empty_expr, rec.dbg, block_terminator(entry));
                continue;
            }
            ce_insert_record_before(.VALUE, nv, rec.var, empty_expr, rec.dbg, block_terminator(entry));
        }
    }
    dbgr_index_reset();

    is_invalid_location :: (v: Value_Id, nf: Value_Id) -> bool {
        if v == NONE return true;
        k := vkind(v);
        if k == .ARGUMENT return arg_parent(v) != nf;
        if k == .INST return inst_fn(v) != nf;
        return !is_constant_kind(k);
    }
    remapped: Table(Md_Id, Md_Id); remapped.allocator = temp;
    cache: Table(Md_Id, Md_Id); cache.allocator = temp;
    to_delete: [..] u32; to_delete.allocator = temp;
    vals: [..] Value_Id; vals.allocator = temp;
    for b: fn_blocks(nf) for i: block_insts(b) {
        r := inst(i).records;
        while r != 0 {
            rec := dbgr(r);
            defer r = rec.next;
            if rec.kind == .LABEL {
                if diloc_inlined_at(rec.dbg) != NONE continue;
                old_label := rec.loc;
                found, nl := table_find(*remapped, old_label);
                if !found || nl == NONE {
                    ns := ce_clone_scope_for_subprogram(di_op(old_label, 0), new_sp, *cache);
                    ops: [3] Md_Id = .[ns, di_op(old_label, 1), di_op(old_label, 2)];
                    ints: [..] u64; ints.allocator = temp;
                    for x: 0..cast(s64) ir.mds[old_label].nints - 1 array_add(*ints, di_int(old_label, cast(u32) x));
                    nl = di_get(.LABEL, false, ops, ints);
                    table_set(*remapped, old_label, nl);
                }
                rec.loc = nl;
                continue;
            }
            vals.count = 0;
            invalid := false;
            loc := rec.loc;
            if loc != NONE && ir.mds[loc].kind == .VALUE {
                invalid = is_invalid_location(ir.mds[loc].value, nf);
            } else if is_di(loc, .ARG_LIST) {
                n := ir.mds[loc].nops;
                for x: 0..cast(s64) n - 1 {
                    o := md_op(loc, cast(u32) x);
                    if o == NONE || ir.mds[o].kind != .VALUE { invalid = true; break; }
                    if is_invalid_location(ir.mds[o].value, nf) { invalid = true; break; }
                }
            }
            if invalid { array_add(*to_delete, r); continue; }
            if rec.kind == .ASSIGN {
                a := rec.addr;
                av: Value_Id = NONE;
                if a != NONE && ir.mds[a].kind == .VALUE av = ir.mds[a].value;
                if is_invalid_location(av, nf) { array_add(*to_delete, r); continue; }
            }
            if diloc_inlined_at(rec.dbg) == NONE {
                old_var := rec.var;
                found, nvar := table_find(*remapped, old_var);
                if !found || nvar == NONE {
                    ns := ce_clone_scope_for_subprogram(di_op(old_var, 0), new_sp, *cache);
                    tracked = true;
                    // createAutoVariable(Scope, Name, File, Line, Type, false, FlagZero, AlignInBits): ArgNo 0
                    nvar = di_get(.LOCAL_VARIABLE, false, .[ns, di_op(old_var, 1), di_op(old_var, 2), di_op(old_var, 3), NONE],
                                  .[di_int(old_var, 0), 0, 0, di_int(old_var, 3)]);
                    table_set(*remapped, old_var, nvar);
                }
                rec.var = nvar;
            }
        }
    }
    for to_delete dbgr_erase(it);
    // DIBuilder::finalizeSubprogram: retainedNodes = !{} once the subprogram is tracked
    if tracked ir.md_ops[ir.mds[new_sp].ops + 7] = md_tuple(.[], false);

    assign_map: Table(Md_Id, Md_Id); assign_map.allocator = temp;
    for b: fn_blocks(nf) for i: block_insts(b) {
        dl := get_metadata(i, MDK_DBG);
        if dl != NONE set_metadata(i, MDK_DBG, ce_replace_inlined_at_subprogram(dl, new_sp, *cache));
        r := inst(i).records;
        while r != 0 {
            if dbgr(r).dbg != NONE dbgr(r).dbg = ce_replace_inlined_at_subprogram(dbgr(r).dbg, new_sp, *cache);
            r = dbgr(r).next;
        }
        ce_update_loop_metadata_debug_locations(i, new_sp, *cache);
        ce_remap_assign_id(*assign_map, i);
    }
    if get_metadata(the_call, MDK_DBG) == NONE set_metadata(the_call, MDK_DBG, di_location_get(0, 0, old_sp, NONE));
    ce_erase_debug_records_with_non_local_refs(nf, old);
    dbgr_index_reset();
}
