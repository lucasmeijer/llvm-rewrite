// ControlHeightReductionPass (`chr`): merges biased conditional blocks and selects of a hot function into one
// speculative branch whose hot side has the merged branches constant-folded, and whose cold side is a clone of the
// original code. Ported from llvm/lib/Transforms/Instrumentation/ControlHeightReduction.cpp (the whole file except
// the optimization remarks and the debug dumps; region trees from region_info.jai).
//
// Address order: the DenseSets/DenseMaps of the pass are only queried for membership, and the std::set<Value *> of
// getBaseValues only for an empty intersection, so nothing here depends on pointer order.

chr_cl: struct {
    disable := false;                 // -disable-chr
    force := false;                   // -force-chr
    bias_threshold: float64 = 0.99;   // -chr-bias-threshold
    merge_threshold: u32 = 2;         // -chr-merge-threshold
    module_list: string;              // -chr-module-list
    function_list: string;            // -chr-function-list
    dup_threshold: u32 = 3;           // -chr-dup-threshold
    lists_parsed := false;
    modules: [..] string;
    functions: [..] string;
}

chr_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    o := *chr_cl;
    if name == {
        case "disable-chr"; o.disable = smisc_bool(name, value, has_value);
        case "force-chr"; o.force = smisc_bool(name, value, has_value);
        case "chr-bias-threshold";
            if !has_value fatal("opt: option -chr-bias-threshold needs a value");
            v, ok := string_to_float64(value);
            if !ok fatal(tprint("opt: invalid floating-point value '%' for -chr-bias-threshold", value));
            o.bias_threshold = v;
        case "chr-merge-threshold"; o.merge_threshold = cast(u32) smisc_int(name, value, has_value);
        case "chr-dup-threshold"; o.dup_threshold = cast(u32) smisc_int(name, value, has_value);
        case "chr-module-list"; o.module_list = copy_string(prof_str(name, value, has_value));
        case "chr-function-list"; o.function_list = copy_string(prof_str(name, value, has_value));
        case; return false;
    }
    return true;
}
chr_takes_value :: (n: string) -> bool {
    return n == "chr-bias-threshold" || n == "chr-merge-threshold" || n == "chr-dup-threshold" ||
           n == "chr-module-list" || n == "chr-function-list";
}

// parseCHRFilterFiles (the pass constructor)
chr_parse_filter_files :: () {
    if chr_cl.lists_parsed return;
    chr_cl.lists_parsed = true;
    read_list :: (path: string, what: string, out: *[..] string) {
        if !path.count return;
        text, ok := read_entire_file(path, log_errors = false);
        if !ok {
            write_string(tprint("Error: Couldn't read the % file %\n", what, path), to_standard_error = true);
            exit(1);
        }
        for line: split(text, "\n") {
            l := trim(line);
            if l.count array_add(out, copy_string(l));
        }
    }
    read_list(chr_cl.module_list, "chr-module-list", *chr_cl.modules);
    read_list(chr_cl.function_list, "chr-function-list", *chr_cl.functions);
}

Chr_Reg_Info :: struct {
    r: Region_Id;
    has_branch: bool;
    selects: [..] Value_Id;
}

Chr_Scope :: struct {
    reg_infos: [..] Chr_Reg_Info;
    subs: [..] s32;
    branch_insert_point: Value_Id = NONE;
    true_biased_regions: Table(Region_Id, bool);
    false_biased_regions: Table(Region_Id, bool);
    chr_regions: [..] Chr_Reg_Info;
    true_biased_selects: Table(Value_Id, bool);
    false_biased_selects: Table(Value_Id, bool);
    hoist_stop_map: Table(Region_Id, Table(Value_Id, bool));
}

Chr :: struct {
    f: Value_Id;
    dt: *Dom_Tree;
    ri: *Region_Info;
    scopes: [..] Chr_Scope;
    true_biased_regions_global: Table(Region_Id, bool);
    false_biased_regions_global: Table(Region_Id, bool);
    true_biased_selects_global: Table(Value_Id, bool);
    false_biased_selects_global: Table(Value_Id, bool);
    branch_bias_map: Table(Region_Id, Bprob);
    select_bias_map: Table(Value_Id, Bprob);
    duplication_count: Table(Region_Id, u32);
}

chr_new_scope :: (c: *Chr, ri: Chr_Reg_Info) -> s32 {
    s: Chr_Scope;
    s.reg_infos.allocator = temp; s.subs.allocator = temp; s.chr_regions.allocator = temp;
    s.true_biased_regions.allocator = temp; s.false_biased_regions.allocator = temp;
    s.true_biased_selects.allocator = temp; s.false_biased_selects.allocator = temp;
    s.hoist_stop_map.allocator = temp;
    array_add(*s.reg_infos, ri);
    id := cast(s32) c.scopes.count;
    array_add(*c.scopes, s);
    return id;
}
chr_sc :: inline (c: *Chr, s: s32) -> *Chr_Scope { return *c.scopes[s]; }

chr_region_entry :: inline (c: *Chr, r: Region_Id) -> Value_Id { return c.ri.regions[r].entry; }
chr_region_exit :: inline (c: *Chr, r: Region_Id) -> Value_Id { return c.ri.regions[r].exit; }
chr_region_parent :: inline (c: *Chr, r: Region_Id) -> Region_Id { return c.ri.regions[r].parent; }
// RegionBase::getDepth
chr_region_depth :: (c: *Chr, r: Region_Id) -> u32 {
    d: u32 = 0;
    p := chr_region_parent(c, r);
    while p >= 0 { d += 1; p = chr_region_parent(c, p); }
    return d;
}
// RegionBase::replaceEntryRecursive
chr_replace_entry_recursive :: (c: *Chr, r: Region_Id, new_entry: Value_Id) {
    old_entry := chr_region_entry(c, r);
    queue: [..] Region_Id; queue.allocator = temp;
    array_add(*queue, r);
    while queue.count {
        x := pop(*queue);
        ri_replace_entry(c.ri, x, new_entry);
        for ch: c.ri.regions[x].children if c.ri.regions[ch].entry == old_entry array_add(*queue, ch);
    }
}

chr_scope_parent_region :: (c: *Chr, s: s32) -> Region_Id { return chr_region_parent(c, chr_sc(c, s).reg_infos[0].r); }
chr_scope_entry_block :: (c: *Chr, s: s32) -> Value_Id { return chr_region_entry(c, chr_sc(c, s).reg_infos[0].r); }
chr_scope_exit_block :: (c: *Chr, s: s32) -> Value_Id {
    sc := chr_sc(c, s);
    return chr_region_exit(c, sc.reg_infos[sc.reg_infos.count - 1].r);
}

// CHRScope::appendable
chr_scope_appendable :: (c: *Chr, s: s32, next: s32) -> bool {
    next_entry := chr_scope_entry_block(c, next);
    if chr_scope_exit_block(c, s) != next_entry return false;
    sc := chr_sc(c, s);
    last := sc.reg_infos[sc.reg_infos.count - 1].r;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(next_entry, *preds);
    for p: preds if !ri_contains(c.ri, last, p) return false;
    return true;
}
// CHRScope::append
chr_scope_append :: (c: *Chr, s: s32, next: s32) {
    sc := chr_sc(c, s); nx := chr_sc(c, next);
    for nx.reg_infos array_add(*sc.reg_infos, it);
    for nx.subs array_add(*sc.subs, it);
}
// CHRScope::split
chr_scope_split :: (c: *Chr, s: s32, boundary: Region_Id) -> s32 {
    sc := chr_sc(c, s);
    bi := -1;
    for sc.reg_infos if it.r == boundary { bi = it_index; break; }
    if bi < 0 return -1;
    tail_set: Table(Region_Id, bool); tail_set.allocator = temp;
    for k: bi..sc.reg_infos.count - 1 table_set(*tail_set, sc.reg_infos[k].r, true);
    // std::stable_partition: head subs (parent not in the tail) first
    head_subs: [..] s32; head_subs.allocator = temp;
    tail_subs: [..] s32; tail_subs.allocator = temp;
    for sub: sc.subs {
        if table_contains(*tail_set, chr_scope_parent_region(c, sub)) array_add(*tail_subs, sub);
        else array_add(*head_subs, sub);
    }
    tail_infos: [..] Chr_Reg_Info; tail_infos.allocator = temp;
    for k: bi..sc.reg_infos.count - 1 array_add(*tail_infos, sc.reg_infos[k]);
    t := chr_new_scope(c, tail_infos[0]);
    sc = chr_sc(c, s);
    ts := chr_sc(c, t);
    ts.reg_infos.count = 0;
    for tail_infos array_add(*ts.reg_infos, it);
    for tail_subs array_add(*ts.subs, it);
    sc.reg_infos.count = bi;
    sc.subs.count = 0;
    for head_subs array_add(*sc.subs, it);
    return t;
}
// CHRScope::contains(Instruction *)
chr_scope_contains :: (c: *Chr, s: s32, i: Value_Id) -> bool {
    p := inst_block(i);
    for chr_sc(c, s).reg_infos if ri_contains(c.ri, it.r, p) return true;
    return false;
}

// isHoistableInstructionType
chr_is_hoistable_instruction_type :: (i: Value_Id) -> bool {
    o := inst_op(i);
    return is_binary_op(o) || is_cast_op(o) || o == .SELECT || o == .GEP || o == .ICMP || o == .FCMP ||
           o == .INSERTELEMENT || o == .EXTRACTELEMENT || o == .SHUFFLEVECTOR || o == .EXTRACTVALUE ||
           o == .INSERTVALUE;
}
// isHoistable
chr_is_hoistable :: (i: Value_Id) -> bool {
    if !chr_is_hoistable_instruction_type(i) return false;
    return is_safe_to_speculatively_execute(i);
}

// getBaseValues: the result sets are only intersected, so a value list per key is enough
chr_get_base_values :: (v: Value_Id, visited: *Table(Value_Id, [..] Value_Id)) -> [] Value_Id {
    p := table_find_pointer(visited, v);
    if p return p.*;
    result: [..] Value_Id; result.allocator = temp;
    add :: (r: *[..] Value_Id, x: Value_Id) { for r.* if it == x return; array_add(r, x); }
    if is_inst(v) {
        if !chr_is_hoistable(v) {
            array_add(*result, v);
            table_set(visited, v, result);
            return result;
        }
        for k: 0..cast(s64) nops(v) - 1 {
            o := op(v, cast(u32) k);
            if o == NONE continue;
            for chr_get_base_values(o, visited) add(*result, it);
        }
        table_set(visited, v, result);
        return result;
    }
    if vkind(v) == .ARGUMENT array_add(*result, v);
    table_set(visited, v, result);
    return result;
}

// checkHoistValue
chr_check_hoist_value :: (c: *Chr, v: Value_Id, insert_point: Value_Id, unhoistables: *Table(Value_Id, bool),
                          hoist_stops: *Table(Value_Id, bool), visited: *Table(Value_Id, bool)) -> bool {
    if !is_inst(v) return true;
    found, r := table_find(visited, v);
    if found return r;
    if table_contains(unhoistables, v) { table_set(visited, v, false); return false; }
    if dt_dominates_inst(c.dt, v, insert_point) {
        if hoist_stops table_set(hoist_stops, v, true);
        table_set(visited, v, true);
        return true;
    }
    if chr_is_hoistable(v) {
        ops_stops: Table(Value_Id, bool); ops_stops.allocator = temp;
        all := true;
        for k: 0..cast(s64) nops(v) - 1 {
            o := op(v, cast(u32) k);
            if !chr_check_hoist_value(c, o, insert_point, unhoistables, *ops_stops, visited) { all = false; break; }
        }
        if all {
            if hoist_stops for _, k: ops_stops table_set(hoist_stops, k, true);
            table_set(visited, v, true);
            return true;
        }
    }
    table_set(visited, v, false);
    return false;
}

// extractBranchProbabilities
chr_extract_branch_probabilities :: (i: Value_Id) -> (bool, Bprob, Bprob) {
    ok, tw, fw := prof_extract_branch_weights_2(i);
    if !ok return false, 0, 0;
    sum := tw + fw;
    if sum == 0 return false, 0, 0;
    return true, bprob_get(tw, sum), bprob_get(fw, sum);
}
chr_bias_threshold :: () -> Bprob { return bprob_get(cast(u64) (chr_cl.bias_threshold * 1000000), 1000000); }

// checkBiasedBranch
chr_check_biased_branch :: (c: *Chr, bi: Value_Id, r: Region_Id) -> bool {
    ok, then_prob, else_prob := chr_extract_branch_probabilities(bi);
    if !ok return false;
    if get_successor(bi, 0) == chr_region_exit(c, r) { t := then_prob; then_prob = else_prob; else_prob = t; }
    th := chr_bias_threshold();
    if then_prob >= th { table_set(*c.true_biased_regions_global, r, true); table_set(*c.branch_bias_map, r, then_prob); return true; }
    if else_prob >= th { table_set(*c.false_biased_regions_global, r, true); table_set(*c.branch_bias_map, r, else_prob); return true; }
    return false;
}
// checkBiasedSelect
chr_check_biased_select :: (c: *Chr, si: Value_Id) -> bool {
    ok, tp, fp := chr_extract_branch_probabilities(si);
    if !ok return false;
    th := chr_bias_threshold();
    if tp >= th { table_set(*c.true_biased_selects_global, si, true); table_set(*c.select_bias_map, si, tp); return true; }
    if fp >= th { table_set(*c.false_biased_selects_global, si, true); table_set(*c.select_bias_map, si, fp); return true; }
    return false;
}

// getBranchInsertPoint
chr_get_branch_insert_point :: (c: *Chr, ri: *Chr_Reg_Info) -> Value_Id {
    entry := chr_region_entry(c, ri.r);
    hp := block_terminator(entry);
    for si: ri.selects if inst_block(si) == entry return si;
    return hp;
}

chr_is_cond_br :: (t: Value_Id) -> bool { return t != NONE && inst_op(t) == .CONDBR; }

// CHR::findScope
chr_find_scope :: (c: *Chr, r: Region_Id) -> s32 {
    result: s32 = -1;
    entry := chr_region_entry(c, r);
    exit := chr_region_exit(c, r);
    if ri_get_region_for(c.ri, entry) != r return -1;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(entry, *preds);
    for p: preds if ri_contains(c.ri, r, p) return -1;
    blocks: [..] Value_Id; blocks.allocator = temp;
    ri_blocks(c.ri, r, *blocks);
    for bb: blocks {
        if block_has_address_taken(bb) return -1;
        for i: block_insts(bb) {
            o := inst_op(i);
            if o == .CALL && call_iid(i) == IID_CORO_ID return -1;
            if o == .CALL || o == .INVOKE || o == .CALLBR {
                if call_cannot_duplicate(i) || call_is_convergent(i) return -1;
            }
        }
    }
    if exit != NONE {
        bi := block_terminator(entry);
        if chr_is_cond_br(bi) {
            s0 := get_successor(bi, 0); s1 := get_successor(bi, 1);
            if s0 != s1 && (s0 == exit || s1 == exit) {
                info: Chr_Reg_Info; info.r = r; info.selects.allocator = temp;
                info.has_branch = chr_check_biased_branch(c, bi, r);
                result = chr_new_scope(c, info);
            }
        }
    }
    {
        selects: [..] Value_Id; selects.allocator = temp;
        elems: [..] Rn_Id; elems.allocator = temp;
        ri_elements(c.ri, r, *elems);
        for e: elems {
            if c.ri.nodes[e].sub continue;
            bb := rn_entry(c.ri, e);
            for i: block_insts(bb) if inst_op(i) == .SELECT array_add(*selects, i);
        }
        if selects.count {
            add_selects :: (c: *Chr, info: *Chr_Reg_Info, selects: [] Value_Id) {
                for si: selects if chr_check_biased_select(c, si) array_add(*info.selects, si);
            }
            if result < 0 {
                info: Chr_Reg_Info; info.r = r; info.selects.allocator = temp;
                add_selects(c, *info, selects);
                result = chr_new_scope(c, info);
            } else {
                add_selects(c, *chr_sc(c, result).reg_infos[0], selects);
            }
        }
    }
    if result >= 0 chr_check_scope_hoistable(c, result);
    return result;
}

// CHR::checkScopeHoistable
chr_check_scope_hoistable :: (c: *Chr, s: s32) {
    ri := *chr_sc(c, s).reg_infos[0];
    entry := chr_region_entry(c, ri.r);
    branch := ifx ri.has_branch then block_terminator(entry) else NONE;
    if !ri.has_branch && ri.selects.count == 0 return;
    insert_point := chr_get_branch_insert_point(c, ri);
    unhoistables: Table(Value_Id, bool); unhoistables.allocator = temp;
    for ri.selects table_set(*unhoistables, it, true);
    k := 0;
    while k < ri.selects.count {
        si := ri.selects[k];
        if si == insert_point { k += 1; continue; }
        visited: Table(Value_Id, bool); visited.allocator = temp;
        if !chr_check_hoist_value(c, op(si, 0), insert_point, *unhoistables, null, *visited) {
            array_ordered_remove_by_index(*ri.selects, k);
            table_remove(*unhoistables, si);
        } else k += 1;
    }
    insert_point = chr_get_branch_insert_point(c, ri);
    if ri.has_branch && insert_point != branch {
        visited: Table(Value_Id, bool); visited.allocator = temp;
        if !chr_check_hoist_value(c, op(branch, 0), insert_point, *unhoistables, null, *visited) {
            k = 0;
            while k < ri.selects.count {
                if inst_block(ri.selects[k]) == entry array_ordered_remove_by_index(*ri.selects, k);
                else k += 1;
            }
        }
    }
}

// CHR::findScopes(R, NextRegion, ParentRegion, Scopes)
chr_find_scopes :: (c: *Chr, r: Region_Id, out: *[..] s32) -> s32 {
    result := chr_find_scope(c, r);
    consecutive: s32 = -1;
    subscopes: [..] s32; subscopes.allocator = temp;
    children := c.ri.regions[r].children;
    for sub_r: children {
        sub := chr_find_scopes(c, sub_r, out);
        if sub >= 0 {
            if consecutive < 0 consecutive = sub;
            else if !chr_scope_appendable(c, consecutive, sub) {
                array_add(*subscopes, consecutive);
                consecutive = sub;
            } else chr_scope_append(c, consecutive, sub);
        } else {
            if consecutive >= 0 array_add(*subscopes, consecutive);
            consecutive = -1;
        }
    }
    if consecutive >= 0 array_add(*subscopes, consecutive);
    for sub: subscopes {
        if result >= 0 array_add(*chr_sc(c, result).subs, sub);
        else array_add(out, sub);
    }
    return result;
}

Chr_Vset :: Table(Value_Id, bool);

// getCHRConditionValuesForRegion
chr_condition_values :: (c: *Chr, ri: *Chr_Reg_Info) -> Chr_Vset {
    cv: Chr_Vset; cv.allocator = temp;
    if ri.has_branch table_set(*cv, op(block_terminator(chr_region_entry(c, ri.r)), 0), true);
    for ri.selects table_set(*cv, op(it, 0), true);
    return cv;
}
chr_vset_copy :: (s: *Chr_Vset) -> Chr_Vset {
    r: Chr_Vset; r.allocator = temp;
    for _, k: s.* table_set(*r, k, true);
    return r;
}

// shouldSplit
chr_should_split :: (c: *Chr, insert_point: Value_Id, prev: *Chr_Vset, cur: *Chr_Vset, unhoistables: *Table(Value_Id, bool)) -> bool {
    for _, v: cur.* {
        visited: Table(Value_Id, bool); visited.allocator = temp;
        if !chr_check_hoist_value(c, v, insert_point, unhoistables, null, *visited) return true;
    }
    if prev.count && cur.count {
        visited: Table(Value_Id, [..] Value_Id); visited.allocator = temp;
        prev_bases: Table(Value_Id, bool); prev_bases.allocator = temp;
        for _, v: prev.* for chr_get_base_values(v, *visited) table_set(*prev_bases, it, true);
        any := false;
        for _, v: cur.* {
            for chr_get_base_values(v, *visited) if table_contains(*prev_bases, it) { any = true; break; }
            if any break;
        }
        if !any return true;
    }
    return false;
}

// getSelectsInScope
chr_get_selects_in_scope :: (c: *Chr, s: s32, out: *Table(Value_Id, bool)) {
    for ri: chr_sc(c, s).reg_infos for ri.selects table_set(out, it, true);
    for sub: chr_sc(c, s).subs chr_get_selects_in_scope(c, sub, out);
}

// CHR::splitScopes
chr_split_scopes :: (c: *Chr, input: [] s32, out: *[..] s32) {
    for s: input {
        unhoistables: Table(Value_Id, bool); unhoistables.allocator = temp;
        chr_get_selects_in_scope(c, s, *unhoistables);
        chr_split_scope(c, s, -1, null, NONE, out, *unhoistables);
    }
}

// CHR::splitScope
chr_split_scope :: (c: *Chr, scope_in: s32, outer: s32, outer_cv: *Chr_Vset, outer_insert_point: Value_Id,
                    out: *[..] s32, unhoistables: *Table(Value_Id, bool)) -> [..] s32 {
    scope := scope_in;
    prev_split_from_outer := true;
    prev_cv: Chr_Vset; prev_cv.allocator = temp;
    prev_insert_point: Value_Id = NONE;
    splits: [..] s32; splits.allocator = temp;
    splits_from_outer: [..] bool; splits_from_outer.allocator = temp;
    splits_cv: [..] Chr_Vset; splits_cv.allocator = temp;
    splits_ip: [..] Value_Id; splits_ip.allocator = temp;
    infos: [..] Chr_Reg_Info; infos.allocator = temp;
    for chr_sc(c, scope).reg_infos array_add(*infos, it);
    for * ri: infos {
        insert_point := chr_get_branch_insert_point(c, ri);
        cv := chr_condition_values(c, ri);
        if ri.r == infos[0].r {
            if outer >= 0 {
                if chr_should_split(c, outer_insert_point, outer_cv, *cv, unhoistables) {
                    prev_cv = cv;
                    prev_insert_point = insert_point;
                } else {
                    prev_split_from_outer = false;
                    prev_cv = chr_vset_copy(outer_cv);
                    for _, k: cv table_set(*prev_cv, k, true);
                    prev_insert_point = outer_insert_point;
                }
            } else {
                prev_cv = cv;
                prev_insert_point = insert_point;
            }
        } else {
            if chr_should_split(c, prev_insert_point, *prev_cv, *cv, unhoistables) {
                tail := chr_scope_split(c, scope, ri.r);
                array_add(*splits, scope);
                array_add(*splits_from_outer, prev_split_from_outer);
                array_add(*splits_cv, prev_cv);
                array_add(*splits_ip, prev_insert_point);
                scope = tail;
                prev_cv = cv;
                prev_insert_point = insert_point;
                prev_split_from_outer = true;
            } else {
                for _, k: cv table_set(*prev_cv, k, true);
            }
        }
    }
    array_add(*splits, scope);
    array_add(*splits_from_outer, prev_split_from_outer);
    array_add(*splits_cv, prev_cv);
    array_add(*splits_ip, prev_insert_point);
    for split, i: splits {
        new_subs: [..] s32; new_subs.allocator = temp;
        split_unhoistables: Table(Value_Id, bool); split_unhoistables.allocator = temp;
        chr_get_selects_in_scope(c, split, *split_unhoistables);
        subs := chr_sc(c, split).subs;
        for sub: subs {
            r := chr_split_scope(c, sub, split, *splits_cv[i], splits_ip[i], out, *split_unhoistables);
            for r array_add(*new_subs, it);
        }
        chr_sc(c, split).subs = new_subs;
    }
    result: [..] s32; result.allocator = temp;
    for split, i: splits {
        if splits_from_outer[i] {
            array_add(out, split);
            chr_sc(c, split).branch_insert_point = splits_ip[i];
        } else array_add(*result, split);
    }
    return result;
}

// CHR::classifyBiasedScopes(Scope, OutermostScope)
chr_classify_biased_scopes :: (c: *Chr, s: s32, outermost: s32) {
    om := chr_sc(c, outermost);
    for ri: chr_sc(c, s).reg_infos {
        if ri.has_branch {
            if table_contains(*c.true_biased_regions_global, ri.r) table_set(*om.true_biased_regions, ri.r, true);
            else if table_contains(*c.false_biased_regions_global, ri.r) table_set(*om.false_biased_regions, ri.r, true);
            else fatal("chr: internal: Must be biased");
        }
        for si: ri.selects {
            if table_contains(*c.true_biased_selects_global, si) table_set(*om.true_biased_selects, si, true);
            else if table_contains(*c.false_biased_selects_global, si) table_set(*om.false_biased_selects, si, true);
            else fatal("chr: internal: Must be biased");
        }
    }
    for sub: chr_sc(c, s).subs chr_classify_biased_scopes(c, sub, outermost);
}

// CHR::setCHRRegions(Scope, OutermostScope)
chr_set_chr_regions :: (c: *Chr, s: s32, outermost: s32) {
    unhoistables: Table(Value_Id, bool); unhoistables.allocator = temp;
    for ri: chr_sc(c, s).reg_infos for ri.selects table_set(*unhoistables, it, true);
    insert_point := chr_sc(c, outermost).branch_insert_point;
    for ri: chr_sc(c, s).reg_infos {
        hoist_stops: Table(Value_Id, bool); hoist_stops.allocator = temp;
        is_hoisted := false;
        if ri.has_branch {
            bi := block_terminator(chr_region_entry(c, ri.r));
            visited: Table(Value_Id, bool); visited.allocator = temp;
            chr_check_hoist_value(c, op(bi, 0), insert_point, *unhoistables, *hoist_stops, *visited);
            is_hoisted = true;
        }
        for si: ri.selects {
            visited: Table(Value_Id, bool); visited.allocator = temp;
            chr_check_hoist_value(c, op(si, 0), insert_point, *unhoistables, *hoist_stops, *visited);
            is_hoisted = true;
        }
        if is_hoisted {
            om := chr_sc(c, outermost);
            array_add(*om.chr_regions, ri);
            table_set(*om.hoist_stop_map, ri.r, hoist_stops);
        }
    }
    for sub: chr_sc(c, s).subs chr_set_chr_regions(c, sub, outermost);
}

// hoistValue
chr_hoist_value :: (c: *Chr, v: Value_Id, hoist_point: Value_Id, r: Region_Id, s: s32,
                    hoisted: *Table(Value_Id, bool), trivial_phis: *Table(Value_Id, bool)) {
    stops := table_find_pointer(*chr_sc(c, s).hoist_stop_map, r);
    assert(stops != null, "Region must be in hoist stop map");
    if !is_inst(v) return;
    if v == hoist_point return;
    if table_contains(stops, v) return;
    if inst_op(v) == .PHI && table_contains(trivial_phis, v) return;
    if table_contains(hoisted, v) return;
    if !chr_is_hoistable_instruction_type(v) fatal("chr: internal: Unhoistable instruction type");
    if dt_dominates_inst(c.dt, v, hoist_point) return;
    for k: 0..cast(s64) nops(v) - 1 chr_hoist_value(c, op(v, cast(u32) k), hoist_point, r, s, hoisted, trivial_phis);
    inst_move_before_dbg(v, hoist_point);
    table_set(hoisted, v, true);
}

// hoistScopeConditions
chr_hoist_scope_conditions :: (c: *Chr, s: s32, hoist_point: Value_Id, trivial_phis: *Table(Value_Id, bool)) {
    hoisted: Table(Value_Id, bool); hoisted.allocator = temp;
    n := chr_sc(c, s).chr_regions.count;
    for k: 0..n - 1 {
        ri := chr_sc(c, s).chr_regions[k];
        sc := chr_sc(c, s);
        tb := table_contains(*sc.true_biased_regions, ri.r);
        fb := table_contains(*sc.false_biased_regions, ri.r);
        if ri.has_branch && (tb || fb) {
            bi := block_terminator(chr_region_entry(c, ri.r));
            chr_hoist_value(c, op(bi, 0), hoist_point, ri.r, s, *hoisted, trivial_phis);
        }
        for si: ri.selects {
            sc = chr_sc(c, s);
            if !(table_contains(*sc.true_biased_selects, si) || table_contains(*sc.false_biased_selects, si)) continue;
            chr_hoist_value(c, op(si, 0), hoist_point, ri.r, s, *hoisted, trivial_phis);
        }
    }
}

// negateICmpIfUsedByBranchOrSelectOnly
chr_negate_icmp_if_used_by_branch_or_select_only :: (c: *Chr, icmp: Value_Id, excluded: Value_Id, s: s32) -> bool {
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[icmp];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for x: users {
        if x == excluded continue;
        if chr_is_cond_br(x) continue;
        if inst_op(x) == .SELECT && op(x, 0) == icmp continue;
        return false;
    }
    sc := chr_sc(c, s);
    for x: users {
        if x == excluded continue;
        if chr_is_cond_br(x) { swap_successors(x); continue; }
        if inst_op(x) == .SELECT {
            // SelectInst::swapValues + swapProfMetadata
            use_swap(op_use(x, 1), op_use(x, 2));
            swap_prof_metadata(x);
            if table_contains(*sc.true_biased_selects, x) table_set(*sc.false_biased_selects, x, true);
            else if table_contains(*sc.false_biased_selects, x) table_set(*sc.true_biased_selects, x, true);
            continue;
        }
        fatal("chr: internal: Must be a branch or a select");
    }
    inst(icmp).pred = cmp_inverse(inst(icmp).pred);
    return true;
}

// insertTrivialPHIs
chr_insert_trivial_phis :: (c: *Chr, s: s32, entry_block: Value_Id, exit_block: Value_Id, trivial_phis: *Table(Value_Id, bool)) {
    in_scope: Table(Value_Id, bool); in_scope.allocator = temp;
    blocks_in_scope: [..] Value_Id; blocks_in_scope.allocator = temp;
    bl: [..] Value_Id; bl.allocator = temp;
    for ri: chr_sc(c, s).reg_infos {
        ri_blocks(c.ri, ri.r, *bl);
        for bl if !table_contains(*in_scope, it) { table_set(*in_scope, it, true); array_add(*blocks_in_scope, it); }
    }
    preds: [..] Value_Id; preds.allocator = temp;
    for bb: blocks_in_scope {
        for i: block_insts(bb) {
            users: [..] Value_Id; users.allocator = temp;
            u := ir.v_first_use[i];
            while u != NONE {
                ui := ir.u_user[u];
                u = ir.u_next[u];
                if !is_inst(ui) continue;
                if !table_contains(*in_scope, inst_block(ui)) && !(inst_op(ui) == .PHI && inst_block(ui) == exit_block) {
                    array_add(*users, ui);
                } else if inst_block(ui) == entry_block && inst_op(ui) == .PHI {
                    array_add(*users, ui);
                }
            }
            if users.count == 0 continue;
            block_predecessors(exit_block, *preds);
            pn := create_phi(vtype(i), cast(u32) preds.count);
            insert_at_position(pn, exit_block, block_first(exit_block), true);
            for p: preds phi_add_incoming(pn, i, p);
            table_set(trivial_phis, pn, true);
            found_lifetime := false;
            for ui: users {
                if inst_block(ui) == NONE continue;   // an erased lifetime marker listed twice
                if is_lifetime_start_or_end(ui) {
                    erase_inst(ui);
                    found_lifetime = true;
                    continue;
                }
                for j: 0..cast(s64) nops(ui) - 1 if op(ui, cast(u32) j) == i set_op(ui, cast(u32) j, pn);
            }
            if found_lifetime {
                lu: [..] Value_Id; lu.allocator = temp;
                u = ir.v_first_use[i];
                while u != NONE { array_add(*lu, ir.u_user[u]); u = ir.u_next[u]; }
                for x: lu if is_inst(x) && is_lifetime_start_or_end(x) erase_inst(x);
            }
        }
    }
}

// getRegionDuplicationCount
chr_region_duplication_count :: (c: *Chr, r_in: Region_Id) -> u32 {
    count: u32 = 0;
    r := r_in;
    while r >= 0 {
        _, n := table_find(*c.duplication_count, r);
        count += n;
        r = chr_region_parent(c, r);
    }
    return count;
}

// CHR::transformScopes(Scope, TrivialPHIs)
chr_transform_scope :: (c: *Chr, s: s32, trivial_phis: *Table(Value_Id, bool)) {
    for ri: chr_sc(c, s).reg_infos if chr_region_duplication_count(c, ri.r) >= chr_cl.dup_threshold return;
    for ri: chr_sc(c, s).reg_infos {
        _, n := table_find(*c.duplication_count, ri.r);
        table_set(*c.duplication_count, ri.r, n + 1);
    }
    sc := chr_sc(c, s);
    first_region := sc.reg_infos[0].r;
    entry_block := chr_region_entry(c, first_region);
    last_region := sc.reg_infos[sc.reg_infos.count - 1].r;
    exit_block := chr_region_exit(c, last_region);

    static_allocas: [..] Value_Id; static_allocas.allocator = temp;
    for i: block_insts(entry_block) if inst_op(i) == .ALLOCA && is_static_alloca(i) array_add(*static_allocas, i);

    new_entry := split_block(entry_block, sc.branch_insert_point, c.dt, null);
    chr_replace_entry_recursive(c, first_region, new_entry);
    pre_entry := entry_block;
    for ai: static_allocas {
        pos := block_first(entry_block);
        if pos == ai {
            if inst(ai).records { nx := inst_next(ai); records_prepend(nx, records_take(ai)); }
        } else inst_move_before_at(ai, pos, true);
    }
    if exit_block != NONE chr_insert_trivial_phis(c, s, entry_block, exit_block, trivial_phis);

    vm: Value_Map; vmap_init(*vm);
    chr_clone_scope_blocks(c, s, pre_entry, exit_block, last_region, *vm);
    merged := chr_create_merged_branch(c, pre_entry, entry_block, new_entry, *vm);
    chr_hoist_scope_conditions(c, s, block_terminator(pre_entry), trivial_phis);
    chr_fixup_branches_and_selects(c, s, pre_entry, merged);
}

// CHR::cloneScopeBlocks
chr_clone_scope_blocks :: (c: *Chr, s: s32, pre_entry: Value_Id, exit_block: Value_Id, last_region: Region_Id, vm: *Value_Map) {
    new_blocks: [..] Value_Id; new_blocks.allocator = temp;
    bl: [..] Value_Id; bl.allocator = temp;
    for ri: chr_sc(c, s).reg_infos {
        ri_blocks(c.ri, ri.r, *bl);
        for bb: bl {
            nb := clone_basic_block(bb, vm, ".nonchr", c.f);
            array_add(*new_blocks, nb);
            vmap_set(vm, bb, nb);
            phis: [..] Value_Id; phis.allocator = temp;
            for i: block_insts(nb) { if inst_op(i) != .PHI break; array_add(*phis, i); }
            for pn: phis {
                pred :: (p: Value_Id, idx: u32, data: *void) -> bool {
                    dt := cast(*Dom_Tree) data;
                    return !dt_is_reachable_from_entry(dt, phi_block(p, idx));
                }
                phi_remove_incoming_if(pn, pred, c.dt);
            }
        }
    }
    if exit_block != NONE fn_splice_blocks(c.f, exit_block, new_blocks[0]);
    for nb: new_blocks for i: block_insts(nb) remap_instruction(vm, i, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
    if exit_block != NONE {
        for pn: block_insts(exit_block) {
            if inst_op(pn) != .PHI break;
            n := phi_num_incoming(pn);
            for k: 0..cast(s64) n - 1 {
                p := phi_block(pn, cast(u32) k);
                if ri_contains(c.ri, last_region, p) {
                    v := phi_value(pn, cast(u32) k);
                    found, mv := vmap_find(vm, v);
                    if found v = mv;
                    pfound, np := vmap_find(vm, p);
                    assert(pfound, "Pred must have been cloned");
                    phi_add_incoming(pn, v, np);
                }
            }
        }
    }
}

// CHR::createMergedBranch
chr_create_merged_branch :: (c: *Chr, pre_entry: Value_Id, entry_block: Value_Id, new_entry: Value_Id, vm: *Value_Map) -> Value_Id {
    old := block_terminator(pre_entry);
    inst_drop_all_references(old);
    erase_inst(old);
    _, cloned := vmap_find(vm, new_entry);
    br := create_cond_br(const_int(ir.t_i1, 1), new_entry, cloned);
    block_append_inst(pre_entry, br);
    return br;
}

// CHR::fixupBranchesAndSelects
chr_fixup_branches_and_selects :: (c: *Chr, s: s32, pre_entry: Value_Id, merged_br: Value_Id) {
    merged_cond := const_int(ir.t_i1, 1);
    bias := bprob_one();
    irb: Irb;
    irb_set_before(*irb, block_terminator(pre_entry));
    n := chr_sc(c, s).chr_regions.count;
    for k: 0..n - 1 {
        ri := chr_sc(c, s).chr_regions[k];
        if ri.has_branch chr_fixup_branch(c, ri.r, s, *irb, *merged_cond, *bias);
        for si: ri.selects chr_fixup_select(c, si, s, *irb, *merged_cond, *bias);
    }
    set_op(merged_br, 0, merged_cond);
    w: [2] u32;
    w[0] = cast(u32) bp_scale(bias, 1000);
    w[1] = cast(u32) bp_scale(bprob_compl(bias), 1000);
    prof_set_branch_weights(merged_br, w, false);
}

// CHR::fixupBranch
chr_fixup_branch :: (c: *Chr, r: Region_Id, s: s32, irb: *Irb, merged_cond: *Value_Id, chr_bias: *Bprob) {
    is_true_biased := table_contains(*chr_sc(c, s).true_biased_regions, r);
    bi := block_terminator(chr_region_entry(c, r));
    _, b := table_find(*c.branch_bias_map, r);
    if chr_bias.* > b chr_bias.* = b;
    if_then := get_successor(bi, 1);
    if_else := get_successor(bi, 0);
    if if_then == chr_region_exit(c, r) { t := if_then; if_then = if_else; if_else = t; }
    cond := op(bi, 0);
    hot := ifx is_true_biased then if_then else if_else;
    condition_true := hot == get_successor(bi, 0);
    chr_add_to_merged_condition(c, condition_true, cond, bi, s, irb, merged_cond);
    set_op(bi, 0, const_int(ir.t_i1, ifx condition_true then cast(u64) 1 else 0));
}

// CHR::fixupSelect
chr_fixup_select :: (c: *Chr, si: Value_Id, s: s32, irb: *Irb, merged_cond: *Value_Id, chr_bias: *Bprob) {
    is_true_biased := table_contains(*chr_sc(c, s).true_biased_selects, si);
    _, b := table_find(*c.select_bias_map, si);
    if chr_bias.* > b chr_bias.* = b;
    cond := op(si, 0);
    chr_add_to_merged_condition(c, is_true_biased, cond, si, s, irb, merged_cond);
    set_op(si, 0, const_int(ir.t_i1, ifx is_true_biased then cast(u64) 1 else 0));
}

// CHR::addToMergedCondition
chr_add_to_merged_condition :: (c: *Chr, is_true_biased: bool, cond_in: Value_Id, branch_or_select: Value_Id, s: s32,
                                irb: *Irb, merged_cond: *Value_Id) {
    cond := cond_in;
    if !is_true_biased {
        is_icmp := is_inst(cond) && inst_op(cond) == .ICMP;
        if !is_icmp || !chr_negate_icmp_if_used_by_branch_or_select_only(c, cond, branch_or_select, s)
            cond = irb_binop(irb, .XOR, const_int(ir.t_i1, 1), cond);
    }
    if !is_guaranteed_not_to_be_undef_or_poison(cond) {
        fr := new_inst(.FREEZE, vtype(cond), 1);
        set_op(fr, 0, cond);
        cond = irb_insert(irb, fr);
    }
    // CreateLogicalAnd = CreateSelect(Cond1, Cond2, false)
    merged_cond.* = irb_select(irb, merged_cond.*, cond, const_int(ir.t_i1, 0));
    if is_inst(merged_cond.*) set_explicitly_unknown_branch_weights_if_profiled(merged_cond.*, "chr");
}

// CHR::run
chr_run_impl :: (f: Value_Id, psi: *Psi) -> bool {
    // shouldApply
    if chr_cl.disable return false;
    if !chr_cl.force {
        if chr_cl.module_list.count || chr_cl.function_list.count {
            in_list := false;
            for chr_cl.modules if it == ir.module_id in_list = true;
            if !in_list for chr_cl.functions if it == vname(f) in_list = true;
            if !in_list return false;
        } else if !psi_is_function_entry_hot(psi, f) return false;
    }
    c: Chr;
    c.f = f;
    c.ri = ri_get(f);
    c.dt = c.ri.dt;
    c.scopes.allocator = temp;
    c.true_biased_regions_global.allocator = temp; c.false_biased_regions_global.allocator = temp;
    c.true_biased_selects_global.allocator = temp; c.false_biased_selects_global.allocator = temp;
    c.branch_bias_map.allocator = temp; c.select_bias_map.allocator = temp; c.duplication_count.allocator = temp;

    all_scopes: [..] s32; all_scopes.allocator = temp;
    top := chr_find_scopes(*c, c.ri.top, *all_scopes);
    if top >= 0 array_add(*all_scopes, top);

    split_scopes: [..] s32; split_scopes.allocator = temp;
    chr_split_scopes(*c, all_scopes, *split_scopes);

    for s: split_scopes chr_classify_biased_scopes(*c, s, s);

    filtered: [..] s32; filtered.allocator = temp;
    for s: split_scopes {
        sc := chr_sc(*c, s);
        nb := sc.true_biased_regions.count + sc.false_biased_regions.count + sc.true_biased_selects.count +
              sc.false_biased_selects.count;
        if nb >= cast(s64) chr_cl.merge_threshold array_add(*filtered, s);
    }

    for s: filtered chr_set_chr_regions(*c, s, s);

    // sortScopes: llvm::stable_sort by region depth
    sorted: [..] s32; sorted.allocator = temp;
    for filtered array_add(*sorted, it);
    for i: 1..sorted.count - 1 {
        x := sorted[i];
        dx := chr_region_depth(*c, chr_sc(*c, x).reg_infos[0].r);
        j := i;
        while j > 0 && chr_region_depth(*c, chr_sc(*c, sorted[j - 1]).reg_infos[0].r) > dx {
            sorted[j] = sorted[j - 1];
            j -= 1;
        }
        sorted[j] = x;
    }

    if sorted.count == 0 return false;
    trivial_phis: Table(Value_Id, bool); trivial_phis.allocator = temp;
    for s: sorted chr_transform_scope(*c, s, *trivial_phis);
    return true;
}

// ControlHeightReductionPass::run
chr_run :: (f: Value_Id) -> Preserved {
    chr_parse_filter_files();
    if !psi_has_profile_summary() return PRESERVE_ALL;
    psi := psi_get();
    if !psi.has_summary return PRESERVE_ALL;
    if !chr_run_impl(f, psi) return PRESERVE_ALL;
    return PRESERVE_NONE;
}
