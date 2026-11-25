// SampleProfileMatcher: stale profile matching (anchors, longest common sequence, call-graph matching of renamed
// functions) and the staleness report. Ported from llvm/lib/Transforms/IPO/SampleProfileMatcher.cpp,
// llvm/include/llvm/Transforms/IPO/SampleProfileMatcher.h and llvm/include/llvm/Transforms/Utils/
// LongestCommonSequence.h. Not ported (loud): Itanium demangling of C++ names (getDemangledBaseName on a mangled
// name), context-sensitive profiles.

spm_cl: struct {
    func_profile_similarity_threshold: u64 = 80;     // -func-profile-similarity-threshold
    min_func_count_for_cg_matching: u64 = 5;         // -min-func-count-for-cg-matching
    min_call_count_for_cg_matching: u64 = 3;         // -min-call-count-for-cg-matching
    load_func_profile_for_cg_matching := true;       // -load-func-profile-for-cg-matching
    salvage_unused_profile_max_functions: u64 = 0xFFFF_FFFF;   // -salvage-unused-profile-max-functions
    salvage_stale_profile_max_callsites: u64 = 0xFFFF_FFFF;    // -salvage-stale-profile-max-callsites
}
spm_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    o := *spm_cl;
    if name == {
        case "func-profile-similarity-threshold"; o.func_profile_similarity_threshold = cast(u64) smisc_int(name, value, has_value);
        case "min-func-count-for-cg-matching"; o.min_func_count_for_cg_matching = cast(u64) smisc_int(name, value, has_value);
        case "min-call-count-for-cg-matching"; o.min_call_count_for_cg_matching = cast(u64) smisc_int(name, value, has_value);
        case "load-func-profile-for-cg-matching"; o.load_func_profile_for_cg_matching = smisc_bool(name, value, has_value);
        case "salvage-unused-profile-max-functions"; o.salvage_unused_profile_max_functions = cast(u64) smisc_int(name, value, has_value);
        case "salvage-stale-profile-max-callsites"; o.salvage_stale_profile_max_callsites = cast(u64) smisc_int(name, value, has_value);
        case; return false;
    }
    return true;
}
spm_takes_value :: (n: string) -> bool {
    for string.["func-profile-similarity-threshold", "min-func-count-for-cg-matching", "min-call-count-for-cg-matching",
                "salvage-unused-profile-max-functions", "salvage-stale-profile-max-callsites"] if n == it return true;
    return false;
}

SP_UNKNOWN_INDIRECT_CALLEE :: "unknown.indirect.callee";

// MatchState
MS_UNKNOWN :: 0; MS_INITIAL_MATCH :: 1; MS_INITIAL_MISMATCH :: 2; MS_UNCHANGED_MATCH :: 3; MS_UNCHANGED_MISMATCH :: 4;
MS_RECOVERED_MISMATCH :: 5; MS_REMOVED_MATCH :: 6;
spm_is_mismatch_state :: (s: u8) -> bool { return s == MS_INITIAL_MISMATCH || s == MS_UNCHANGED_MISMATCH || s == MS_REMOVED_MATCH; }

Spm_Anchor :: struct { loc: Line_Loc; f: Fid; }
Loc_Map :: Table(u64, Line_Loc);   // LocToLocMap (keyed by loc_hash)

Spm :: struct {
    flattened: *Sp_Reader;                            // FlattenedProfiles
    func_mappings: Table(string, *Loc_Map);           // FuncMappings
    matched_anchor_cache: Table(u64, Value_Id);       // MatchedAnchorCache (FunctionId -> Function)
    match_states: Table(string, *Table(u64, u8));     // FuncCallsiteMatchStates
    match_cache: Table(string, bool);                 // FuncProfileMatchCache ("<function id>:<FunctionId hash>")
    func_to_profile_name: [..] struct { f: Value_Id; name: Fid; };   // FuncToProfileNameMap (a MapVector)
    without_profile: Table(u64, Value_Id);            // FunctionsWithoutProfile
    salvage_unused: bool;
    // computeAndReportProfileStaleness
    total_profiled_func: u64; num_stale_profile_func: u64; total_function_samples: u64; mismatched_function_samples: u64;
    total_profiled_callsites: u64; num_mismatched_callsites: u64; num_recovered_callsites: u64;
    mismatched_callsite_samples: u64; recovered_callsite_samples: u64;
    num_cg_recovered_profiled_func: u64; num_cg_recovered_func_samples: u64;
}
spm: Spm;

spm_ftpn_find :: (f: Value_Id) -> (bool, Fid) {
    for spm.func_to_profile_name if it.f == f return true, it.name;
    e: Fid; return false, e;
}
spm_ftpn_set :: (f: Value_Id, name: Fid) {
    for * spm.func_to_profile_name if it.f == f { it.name = name; return; }
    array_add(*spm.func_to_profile_name, .{f, name});
}
spm_cache_key :: (f: Value_Id, p: Fid) -> string { return sprint("%:%", f, fid_hash(p)); }

// FunctionSamples::getFuncName
fs_func_name :: (fs: *Fs) -> string {
    f := fs_func(fs);
    if !f.md5 return f.s;
    found, n := table_find(*spl.guid_to_name, f.h);
    if found return n;
    return fid_str(f);
}

// the base name of an Itanium-mangled name (getDemangledBaseName): only names the demangler rejects are handled
spm_demangled_base_name :: (name: string) -> string {
    if begins_with(name, "_Z") || begins_with(name, "__Z") || begins_with(name, "___Z") || begins_with(name, "____Z")
        fatal("sample-profile: stale profile matching of the C++ name '%' needs the Itanium demangler (not ported)", name);
    return "";
}

// DILocation::getSubprogramLinkageName
sp_dil_subprogram_linkage_name :: (dil: Md_Id) -> string {
    sp := diloc_subprogram(dil);
    if sp == NONE return "";
    n := md_str_of(di_op(sp, 3));
    if n.count return n;
    return md_str_of(di_op(sp, 2));
}

// AnchorMap::emplace (a std::map: the first insertion wins)
spm_anchor_emplace :: (m: *[..] Spm_Anchor, loc: Line_Loc, f: Fid) -> (*Spm_Anchor, bool) {
    lo := 0; hi := m.count;
    while lo < hi { mid := (lo + hi) / 2; if loc_cmp(m.*[mid].loc, loc) < 0 lo = mid + 1; else hi = mid; }
    if lo < m.count && loc_eq(m.*[lo].loc, loc) return *m.*[lo], false;
    array_insert_at(m, .{loc, f}, lo);
    return *m.*[lo], true;
}
spm_anchor_find :: (m: [] Spm_Anchor, loc: Line_Loc) -> *Spm_Anchor {
    lo := 0; hi := m.count;
    while lo < hi { mid := (lo + hi) / 2; if loc_cmp(m[mid].loc, loc) < 0 lo = mid + 1; else hi = mid; }
    if lo < m.count && loc_eq(m[lo].loc, loc) return *m[lo];
    return null;
}

// findIRAnchors
spm_find_ir_anchors :: (f: Value_Id, out: *[..] Spm_Anchor) {
    top_level_inlined_callsite :: (dil_in: Md_Id) -> (Line_Loc, Fid) {
        dil := dil_in;
        prev: Md_Id = NONE;
        while true {
            prev = dil;
            dil = diloc_inlined_at(dil);
            if diloc_inlined_at(dil) == NONE break;
        }
        return sp_callsite_id(dil, sp_flags.fs), fid_of(sp_dil_subprogram_linkage_name(prev));
    }
    canonical_callee_name :: (cb: Value_Id) -> string {
        c := call_called_function(cb);
        if c != NONE return sp_canonical_fn_name(vname(c));
        return SP_UNKNOWN_INDIRECT_CALLEE;
    }
    for b: fn_blocks(f) for i: block_insts(b) {
        dil := get_metadata(i, 0);
        if dil == NONE continue;
        if sp_flags.probe_based {
            ok, probe := sp_extract_probe(i);
            if !ok continue;
            if diloc_inlined_at(dil) != NONE {
                l, n := top_level_inlined_callsite(dil);
                spm_anchor_emplace(out, l, n);
            } else {
                name := "";
                if is_call_base(i) && !sp_is_intrinsic_inst(i) name = canonical_callee_name(i);
                spm_anchor_emplace(out, .{probe.id, 0}, fid_of(name));
            }
        } else {
            if !is_call_base(i) || sp_is_intrinsic_inst(i) continue;
            if diloc_inlined_at(dil) != NONE {
                l, n := top_level_inlined_callsite(dil);
                spm_anchor_emplace(out, l, n);
            } else {
                spm_anchor_emplace(out, sp_callsite_id(dil, sp_flags.fs), fid_of(canonical_callee_name(i)));
            }
        }
    }
}

// findProfileAnchors
spm_find_profile_anchors :: (fs: *Fs, out: *[..] Spm_Anchor) {
    insert :: (out: *[..] Spm_Anchor, loc: Line_Loc, f: Fid) {
        a, inserted := spm_anchor_emplace(out, loc, f);
        if !inserted a.f = fid_of(SP_UNKNOWN_INDIRECT_CALLEE);
    }
    for fs.body {
        if it.loc.line & 0x8000 continue;
        for t: it.rec.targets insert(out, it.loc, t.f);   // CallTargetMap: a std::map sorted by FunctionId
    }
    for fs.callsites {
        if it.loc.line & 0x8000 continue;
        for c: it.callees insert(out, it.loc, c.f);
    }
}

spm_get_flattened_samples_for_id :: (f: Fid) -> *Fs {
    c: Sample_Context; c.func = f;
    return sp_profiles_find_ctx(spm.flattened, *c);
}
spm_get_flattened_samples_for :: (f: Value_Id) -> *Fs { return spm_get_flattened_samples_for_id(fid_of(sp_canonical_fn_name_of(f))); }

// PseudoProbeManager::getDesc(GUID): (found, CFG hash)
spm_probe_desc :: (guid: u64) -> (bool, u64) {
    found, h := table_find(*spl.probe_desc, guid);
    return found, h;
}

// functionHasProfile
spm_function_has_profile :: (ir_name: Fid) -> (bool, Value_Id) {
    found, f := table_find(*spm.without_profile, fid_hash(ir_name));
    if found && f != NONE return false, f;
    return true, NONE;
}
// isProfileUnused
spm_is_profile_unused :: (p: Fid) -> bool {
    if table_contains(*spl.symbol_map, fid_hash(p)) return false;
    if spl.phase == .THIN_PRE_LINK || !sp_flags.probe_based || p.md5 return true;
    found, _ := spm_probe_desc(md5_hash_u64(p.s));
    return !found;
}
// functionMatchesProfile(IRFuncName, ProfileFuncName, FindMatchedProfileOnly)
spm_function_matches_profile_ids :: (ir_name: Fid, prof_name: Fid, find_matched_only: bool) -> bool {
    if fid_eq(ir_name, prof_name) return true;
    if !spm.salvage_unused return false;
    has, ir_func := spm_function_has_profile(ir_name);
    if has || !spm_is_profile_unused(prof_name) return false;
    return spm_function_matches_profile(ir_func, prof_name, find_matched_only);
}

// llvm::longestCommonSequence (Myers' diff) into MatchedAnchors (try_emplace)
spm_longest_common_sequence :: (l1: [] Spm_Anchor, l2: [] Spm_Anchor, match_unused: bool, out: *Loc_Map) {
    size1 := cast(s32) l1.count; size2 := cast(s32) l2.count;
    max_depth := size1 + size2;
    if max_depth == 0 return;
    idx :: (i: s32) -> s64 #expand { return cast(s64) (i + max_depth); }
    insert :: (a: Line_Loc, b: Line_Loc) #expand { if !table_contains(out, loc_hash(a)) table_set(out, loc_hash(a), b); }
    v := NewArray(2 * max_depth + 1, s32,, allocator = temp);
    for * v it.* = -1;
    v[idx(1)] = 0;
    trace: [..] [] s32; trace.allocator = temp;
    for depth: 0..max_depth {
        snap := NewArray(v.count, s32,, allocator = temp);
        for v snap[it_index] = it;
        array_add(*trace, snap);
        k := -depth;
        while k <= depth {
            x: s32 = 0;
            if k == -depth || (k != depth && v[idx(k - 1)] < v[idx(k + 1)]) x = v[idx(k + 1)];
            else x = v[idx(k - 1)] + 1;
            y := x - k;
            while x < size1 && y < size2 && spm_function_matches_profile_ids(l1[x].f, l2[y].f, !match_unused) { x += 1; y += 1; }
            v[idx(k)] = x;
            if x >= size1 && y >= size2 {
                // Backtrack
                bx := size1; by := size2;
                d := cast(s32) trace.count - 1;
                while bx > 0 || by > 0 {
                    p := trace[d];
                    kk := bx - by;
                    prev_k: s32;
                    if kk == -d || (kk != d && p[idx(kk - 1)] < p[idx(kk + 1)]) prev_k = kk + 1;
                    else prev_k = kk - 1;
                    prev_x := p[idx(prev_k)];
                    prev_y := prev_x - prev_k;
                    while bx > prev_x && by > prev_y {
                        bx -= 1; by -= 1;
                        insert(l1[bx].loc, l2[by].loc);
                    }
                    if d == 0 break;
                    bx = prev_x; by = prev_y;
                    d -= 1;
                }
                return;
            }
            k += 2;
        }
    }
}

// matchNonCallsiteLocs
spm_match_non_callsite_locs :: (matched: *Loc_Map, ir_anchors: [] Spm_Anchor, map: *Loc_Map) {
    update :: (from: Line_Loc, to: Line_Loc) #expand {
        if !loc_eq(from, to) table_set(map, loc_hash(from), to);
        else table_remove(map, loc_hash(from));
    }
    delta: s32 = 0;
    last: [..] Line_Loc; last.allocator = temp;
    for ir: ir_anchors {
        loc := ir.loc;
        found, cand := table_find(matched, loc_hash(loc));
        if found {
            update(loc, cand);
            delta = cast(s32) cand.line - cast(s32) loc.line;
            for k: (last.count + 1) / 2..last.count - 1 {
                l := last[k];
                update(l, Line_Loc.{cast(u32) (cast(s32) l.line + delta), l.disc});
            }
            last.count = 0;
        } else {
            update(loc, Line_Loc.{cast(u32) (cast(s32) loc.line + delta), loc.disc});
            array_add(*last, loc);
        }
    }
}

// getFilteredAnchorList
spm_filtered_anchor_lists :: (ir: [] Spm_Anchor, prof: [] Spm_Anchor) -> ([..] Spm_Anchor, [..] Spm_Anchor) {
    fi: [..] Spm_Anchor; fi.allocator = temp;
    fp: [..] Spm_Anchor; fp.allocator = temp;
    for ir if it.f.md5 || it.f.s.count != 0 array_add(*fi, it);   // I.second.stringRef().empty()
    for prof array_add(*fp, it);
    return fi, fp;
}

// runStaleProfileMatching
spm_run_stale_profile_matching :: (f: Value_Id, ir_anchors: [] Spm_Anchor, prof_anchors: [] Spm_Anchor, map: *Loc_Map, run_cfg: bool, run_cg: bool) {
    if !run_cfg && !run_cg return;
    fi, fp := spm_filtered_anchor_lists(ir_anchors, prof_anchors);
    if fi.count == 0 || fp.count == 0 return;
    if cast(u64) fi.count > spm_cl.salvage_stale_profile_max_callsites || cast(u64) fp.count > spm_cl.salvage_stale_profile_max_callsites return;
    matched: Loc_Map; matched.allocator = temp;
    spm_longest_common_sequence(fi, fp, run_cg, *matched);
    for ir: ir_anchors {
        callee := module_get_function(ir.f.s);
        if ir.f.md5 || callee == NONE continue;
        prof_anchor: Fid;
        found, aloc := table_find(*matched, loc_hash(ir.loc));
        if !found {
            ok, pre := spm_ftpn_find(callee);
            if !ok continue;
            prof_anchor = pre;
        } else {
            p := spm_anchor_find(prof_anchors, aloc);
            if !p continue;
            prof_anchor = p.f;
        }
        conflicted := false;
        cf, cached := table_find(*spm.matched_anchor_cache, fid_hash(prof_anchor));
        if !cf table_set(*spm.matched_anchor_cache, fid_hash(prof_anchor), callee);
        else if cached != callee conflicted = true;
        if conflicted {
            fsm := spm_get_flattened_samples_for_id(prof_anchor);
            if !fsm fsm = sp_get_samples_for_name(fid_str(prof_anchor));
            if !fsm continue;
            new_anchor := fid_of(sp_canonical_fn_name(ir.f.s));
            key := spm_cache_key(callee, new_anchor);
            mf, mv := table_find(*spm.match_cache, key);
            if mf && mv continue;
            c: Sample_Context; c.func = new_anchor;
            nfs := sp_profiles_create(spm.flattened, c);
            fs_merge(nfs, fsm);
            spm_ftpn_set(callee, new_anchor);
            table_set(*spm.match_cache, key, true);
            // Profiles.try_emplace(FContext.getHashCode(), FContext, NewFS)
            if !sp_profiles_find_ctx(*sp_reader, *c) {
                p := sp_profiles_create(*sp_reader, c);
                cl := fs_clone(nfs);
                p.* = cl.*;
                p.ctx = c;
            }
        }
    }
    if run_cfg spm_match_non_callsite_locs(*matched, ir_anchors, map);
}

// getIRToProfileLocationMap
spm_loc_map_for :: (fs: *Fs) -> *Loc_Map {
    name := fs_func_name(fs);
    found, m := table_find(*spm.func_mappings, name);
    if found return m;
    m = New(Loc_Map);
    table_set(*spm.func_mappings, copy_string(name), m);
    return m;
}

// recordCallsiteMatchStates
spm_record_callsite_match_states :: (f: Value_Id, ir_anchors: [] Spm_Anchor, prof_anchors: [] Spm_Anchor, map: *Loc_Map) {
    is_post := map != null;
    name := sp_canonical_fn_name(vname(f));
    found, states := table_find(*spm.match_states, name);
    if !found { states = New(Table(u64, u8)); table_set(*spm.match_states, copy_string(name), states); }
    for ir: ir_anchors {
        ploc := ir.loc;
        if map { ok, m := table_find(map, loc_hash(ir.loc)); if ok ploc = m; }
        p := spm_anchor_find(prof_anchors, ploc);
        if !p continue;
        if fid_eq(ir.f, p.f) {
            ok, s := table_find(states, loc_hash(ploc));
            if !ok table_set(states, loc_hash(ploc), MS_INITIAL_MATCH);
            else if is_post {
                if s == MS_INITIAL_MATCH table_set(states, loc_hash(ploc), MS_UNCHANGED_MATCH);
                else if s == MS_INITIAL_MISMATCH table_set(states, loc_hash(ploc), MS_RECOVERED_MISMATCH);
            }
        }
    }
    for p: prof_anchors {
        ok, s := table_find(states, loc_hash(p.loc));
        if !ok table_set(states, loc_hash(p.loc), MS_INITIAL_MISMATCH);
        else if is_post {
            if s == MS_INITIAL_MISMATCH table_set(states, loc_hash(p.loc), MS_UNCHANGED_MISMATCH);
            else if s == MS_INITIAL_MATCH table_set(states, loc_hash(p.loc), MS_REMOVED_MATCH);
        }
    }
}

// runOnFunction
spm_run_on_function :: (f: Value_Id) {
    fsm := spm_get_flattened_samples_for(f);
    if spm.salvage_unused && !fsm {
        ok, n := spm_ftpn_find(f);
        if ok {
            fsm = spm_get_flattened_samples_for_id(n);
            if !fsm && spm_cl.load_func_profile_for_cg_matching fsm = sp_get_samples_for_name(fid_str(n));
        }
    }
    if !fsm return;
    ir_anchors: [..] Spm_Anchor; ir_anchors.allocator = temp;
    spm_find_ir_anchors(f, *ir_anchors);
    prof_anchors: [..] Spm_Anchor; prof_anchors.allocator = temp;
    spm_find_profile_anchors(fsm, *prof_anchors);
    if sp_opts.report_profile_staleness || sp_opts.persist_profile_staleness spm_record_callsite_match_states(f, ir_anchors, prof_anchors, null);
    if !sp_opts.salvage_stale_profile return;
    checksum_mismatch := sp_flags.probe_based && !spl_profile_is_valid(f, fsm);
    run_cfg := !sp_flags.probe_based || checksum_mismatch;
    run_cg := spm.salvage_unused;
    if checksum_mismatch && spl.phase == .THIN_PRE_LINK fn_add_fn_str_attr(f, "profile-checksum-mismatch", "");
    map := spm_loc_map_for(fsm);
    spm_run_stale_profile_matching(f, ir_anchors, prof_anchors, map, run_cfg, run_cg);
    if run_cfg && (sp_opts.report_profile_staleness || sp_opts.persist_profile_staleness)
        spm_record_callsite_match_states(f, ir_anchors, prof_anchors, map);
}

// SampleProfileReader::read(FuncsToUse): the text reader has no partial reading (not_implemented)
spm_reader_read :: (names: [] string) -> bool {
    if sp_reader.format == .TEXT return false;
    if sp_reader.format == .EXT_BINARY { spb_read_named_profiles(names); return true; }
    fatal("sample-profile: reading more profiles of a % profile for stale profile matching is not implemented yet", sp_reader.format);
    return false;
}

// functionMatchesProfileHelper
spm_function_matches_profile_helper :: (ir_func: Value_Id, prof: Fid) -> bool {
    ir_base := spm_demangled_base_name(vname(ir_func));
    prof_base := ifx prof.md5 then "" else spm_demangled_base_name(prof.s);
    if ir_base.count && ir_base == prof_base return true;
    fsm := spm_get_flattened_samples_for_id(prof);
    if !fsm && spm_cl.load_func_profile_for_cg_matching {
        if !spm_reader_read(.[fid_str(prof)]) return false;
        fsm = sp_get_samples_for_name(fid_str(prof));
        if fsm {
            tmp := New(Sp_Reader,, allocator = temp);
            c: Sample_Context; c.func = fs_func(fsm);
            t := sp_profiles_create(tmp, c);
            fs_merge(t, fsm);
            if sp_flags.cs {
                for tmp.profiles { cc: Sample_Context; cc.func = fs_func(it); x := sp_profiles_create(spm.flattened, cc); fs_merge(x, it, 1); }
            } else for tmp.profiles sp_flatten_nested(spm.flattened, it);
            fsm = spm_get_flattened_samples_for_id(prof);
        }
    }
    if !fsm return false;
    if cast(u64) fn_num_blocks(ir_func) < spm_cl.min_func_count_for_cg_matching || cast(u64) fsm.body.count < spm_cl.min_func_count_for_cg_matching return false;
    if sp_flags.probe_based {
        found, h := spm_probe_desc(sp_fn_guid(sp_canonical_fn_name_of(ir_func)));
        if found && h == fsm.function_hash return true;
    }
    ir_anchors: [..] Spm_Anchor; ir_anchors.allocator = temp;
    spm_find_ir_anchors(ir_func, *ir_anchors);
    prof_anchors: [..] Spm_Anchor; prof_anchors.allocator = temp;
    spm_find_profile_anchors(fsm, *prof_anchors);
    fi, fp := spm_filtered_anchor_lists(ir_anchors, prof_anchors);
    if cast(u64) fi.count < spm_cl.min_call_count_for_cg_matching || cast(u64) fp.count < spm_cl.min_call_count_for_cg_matching return false;
    matched: Loc_Map; matched.allocator = temp;
    spm_longest_common_sequence(fi, fp, false, *matched);
    similarity := cast(float32) matched.count / cast(float32) fp.count;
    return similarity * 100 > cast(float32) spm_cl.func_profile_similarity_threshold;
}
// functionMatchesProfile(IRFunc, ProfFunc, FindMatchedProfileOnly)
spm_function_matches_profile :: (ir_func: Value_Id, prof: Fid, find_matched_only: bool) -> bool {
    key := spm_cache_key(ir_func, prof);
    found, v := table_find(*spm.match_cache, key);
    if found return v;
    if find_matched_only return false;
    matched := spm_function_matches_profile_helper(ir_func, prof);
    table_set(*spm.match_cache, key, matched);
    if matched spm_ftpn_set(ir_func, prof);
    return matched;
}

// findFunctionsWithoutProfile
spm_find_functions_without_profile :: () {
    if sp_flags.use_md5 return;
    names: Table(string, bool); names.allocator = temp;
    for sp_reader.name_table if !it.md5 table_set(*names, it.s, true);
    for f: ir.m_functions {
        if is_declaration(f) continue;
        canon := sp_canonical_fn_name(vname(f));
        if spm_get_flattened_samples_for(f) continue;
        if table_contains(*names, canon) continue;
        if sp_psl_contains(canon) continue;
        table_set(*spm.without_profile, md5_hash_u64(canon), f);
    }
}
// matchFunctionsWithoutProfileByBasename
spm_match_functions_without_profile_by_basename :: () {
    if spm.without_profile.count == 0 || !spm_cl.load_func_profile_for_cg_matching return;
    if sp_reader.name_table.count == 0 return;
    any := false;
    for f: spm.without_profile if spm_demangled_base_name(vname(f)).count any = true;
    // every base name is empty (no mangled names): OrphansByBaseName is empty
    if any fatal("internal: demangled base names");
}

// UpdateWithSalvagedProfiles
spm_update_with_salvaged_profiles :: () {
    names: [..] string; names.allocator = temp;
    if !sp_reader.func_name_to_prof_name sp_reader.func_name_to_prof_name = New(Table(string, string));
    for spm.func_to_profile_name {
        fname := vname(it.f);
        pname := fid_str(it.name);
        dup := false;
        for n: names if n == pname dup = true;
        if !dup array_add(*names, pname);
        if !table_contains(sp_reader.func_name_to_prof_name, fname) table_set(sp_reader.func_name_to_prof_name, copy_string(fname), copy_string(pname));
        table_remove(*spl.symbol_map, md5_hash_u64(fname));
        if !table_contains(*spl.symbol_map, fid_hash(it.name)) table_set(*spl.symbol_map, fid_hash(it.name), it.f);
    }
    spm_reader_read(names);
}

// distributeIRToProfileLocationMap
spm_distribute :: (fs: *Fs) {
    found, m := table_find(*spm.func_mappings, fs_func_name(fs));
    if found fs.loc_map = m;
    for cs: fs.callsites for cs.callees spm_distribute(it.fs);
}

// countMismatchedFuncSamples
spm_count_mismatched_func_samples :: (fs: *Fs, top: bool) {
    found, h := spm_probe_desc(fs_guid(fs));
    if !found return;
    if h != fs.function_hash {
        if top spm.num_stale_profile_func += 1;
        spm.mismatched_function_samples += fs.total;
        return;
    }
    for cs: fs.callsites for cs.callees spm_count_mismatched_func_samples(it.fs, false);
}
spm_find_state :: (states: *Table(u64, u8), l: Line_Loc) -> u8 { ok, s := table_find(states, loc_hash(l)); return ifx ok then s else MS_UNKNOWN; }
// countMismatchedCallsiteSamples
spm_count_mismatched_callsite_samples :: (fs: *Fs) {
    found, states := table_find(*spm.match_states, fs_func_name(fs));
    if !found || states.count == 0 return;
    attribute :: (s: u8, n: u64) {
        if spm_is_mismatch_state(s) spm.mismatched_callsite_samples += n;
        else if s == MS_RECOVERED_MISMATCH spm.recovered_callsite_samples += n;
    }
    for fs.body attribute(spm_find_state(states, it.loc), it.rec.samples);
    for cs: fs.callsites {
        s := spm_find_state(states, cs.loc);
        n: u64 = 0;
        for cs.callees n += it.fs.total;
        attribute(s, n);
        if spm_is_mismatch_state(s) continue;
        for cs.callees spm_count_mismatched_callsite_samples(it.fs);
    }
}
// countMismatchCallsites
spm_count_mismatch_callsites :: (fs: *Fs) {
    found, states := table_find(*spm.match_states, fs_func_name(fs));
    if !found || states.count == 0 return;
    for s: states.* {
        spm.total_profiled_callsites += 1;
        if spm_is_mismatch_state(s) spm.num_mismatched_callsites += 1;
        else if s == MS_RECOVERED_MISMATCH spm.num_recovered_callsites += 1;
    }
}
// countCallGraphRecoveredSamples
spm_count_cg_recovered_samples :: (fs: *Fs, recovered: *Table(u64, bool)) {
    if table_contains(recovered, fs_guid(fs)) { spm.num_cg_recovered_func_samples += fs.total; return; }
    for cs: fs.callsites for cs.callees spm_count_cg_recovered_samples(it.fs, recovered);
}
// computeAndReportProfileStaleness
spm_compute_and_report_profile_staleness :: () {
    if !sp_opts.report_profile_staleness && !sp_opts.persist_profile_staleness return;
    recovered: Table(u64, bool); recovered.allocator = temp;
    if spm.salvage_unused {
        for spm.func_to_profile_name {
            table_set(*recovered, fid_hash(it.name), true);
            if glob(it.f).linkage == .AVAILABLE_EXTERNALLY continue;
            spm.num_cg_recovered_profiled_func += 1;
        }
    }
    for f: ir.m_functions {
        if sp_skip_profile_for_function(f) continue;
        if glob(f).linkage == .AVAILABLE_EXTERNALLY continue;
        fs := sp_get_samples_for(f);
        if !fs continue;
        spm.total_profiled_func += 1;
        spm.total_function_samples += fs.total;
        if spm.salvage_unused && recovered.count spm_count_cg_recovered_samples(fs, *recovered);
        if sp_flags.probe_based spm_count_mismatched_func_samples(fs, true);
        spm_count_mismatch_callsites(fs);
        spm_count_mismatched_callsite_samples(fs);
    }
    s := *spm;
    if sp_opts.report_profile_staleness {
        if sp_flags.probe_based
            print_to_stderr("(%/%) of functions' profile are invalid and (%/%) of samples are discarded due to function hash mismatch.\n",
                            s.num_stale_profile_func, s.total_profiled_func, s.mismatched_function_samples, s.total_function_samples);
        if s.salvage_unused
            print_to_stderr("(%/%) of functions' profile are matched and (%/%) of samples are reused by call graph matching.\n",
                            s.num_cg_recovered_profiled_func, s.total_profiled_func, s.num_cg_recovered_func_samples, s.total_function_samples);
        print_to_stderr("(%/%) of callsites' profile are invalid and (%/%) of samples are discarded due to callsite location mismatch.\n",
                        s.num_mismatched_callsites + s.num_recovered_callsites, s.total_profiled_callsites,
                        s.mismatched_callsite_samples + s.recovered_callsite_samples, s.total_function_samples);
        print_to_stderr("(%/%) of callsites and (%/%) of samples are recovered by stale profile matching.\n",
                        s.num_recovered_callsites, s.num_recovered_callsites + s.num_mismatched_callsites,
                        s.recovered_callsite_samples, s.recovered_callsite_samples + s.mismatched_callsite_samples);
    }
    if sp_opts.persist_profile_staleness {
        ops: [..] Md_Id; ops.allocator = temp;
        add :: (k: string, v: u64) #expand { array_add(*ops, md_string(k)); array_add(*ops, md_value(const_int(ir.t_i64, v))); }
        if sp_flags.probe_based {
            add("NumStaleProfileFunc", s.num_stale_profile_func);
            add("TotalProfiledFunc", s.total_profiled_func);
            add("MismatchedFunctionSamples", s.mismatched_function_samples);
            add("TotalFunctionSamples", s.total_function_samples);
        }
        if s.salvage_unused {
            add("NumCallGraphRecoveredProfiledFunc", s.num_cg_recovered_profiled_func);
            add("NumCallGraphRecoveredFuncSamples", s.num_cg_recovered_func_samples);
        }
        add("NumMismatchedCallsites", s.num_mismatched_callsites);
        add("NumRecoveredCallsites", s.num_recovered_callsites);
        add("TotalProfiledCallsites", s.total_profiled_callsites);
        add("MismatchedCallsiteSamples", s.mismatched_callsite_samples);
        add("RecoveredCallsiteSamples", s.recovered_callsite_samples);
        nmd := named_md_get_or_insert("llvm.stats");
        array_add(*ir.named_md[nmd].ops, md_tuple(ops, false));
    }
}

// SampleProfileMatcher(M, Reader, CG, ProbeManager, LTOPhase, SymbolMap, PSL, FuncNameToProfNameMap)
sp_matcher_init :: () {
    spm = .{};
}

// runOnModule
sp_matcher_run_on_module :: () {
    spm.flattened = sp_flatten_to(sp_reader.profiles, sp_flags.cs);
    spm.salvage_unused = sp_opts.salvage_unused_profile && cast(u64) ir.m_functions.count < spm_cl.salvage_unused_profile_max_functions;
    if spm.salvage_unused {
        spm_find_functions_without_profile();
        spm_match_functions_without_profile_by_basename();
    }
    // buildTopDownFuncOrder(CG)
    order: [..] Value_Id; order.allocator = temp;
    lcg_get();
    lcg_build_ref_sccs();
    for rc: lcg.postorder for c: lcg.rcs[rc].sccs for n: lcg.sccs[c].nodes {
        fn := lcg_fn(n);
        if !sp_skip_profile_for_function(fn) array_add(*order, fn);
    }
    k := order.count - 1;
    while k >= 0 {
        f := order[k];
        k -= 1;
        if sp_skip_profile_for_function(f) continue;
        spm_run_on_function(f);
    }
    if spm.salvage_unused spm_update_with_salvaged_profiles();
    if sp_opts.salvage_stale_profile for sp_reader.profiles spm_distribute(it);
    spm_compute_and_report_profile_staleness();
}
