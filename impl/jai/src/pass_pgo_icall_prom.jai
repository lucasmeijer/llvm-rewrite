// pgo-icall-prom (PGOIndirectCallPromotion): indirect call promotion from !prof "VP" value profiles.
// Ported from llvm/lib/Transforms/Instrumentation/IndirectCallPromotion.cpp (promoteIndirectCalls,
// IndirectCallPromoter: getPromotionCandidatesForCallSite, isValidTarget, tryToPromoteWithFuncCmp,
// updateFuncValueProfiles), llvm/lib/Analysis/IndirectCallPromotionAnalysis.cpp (ICallPromotionAnalysis) and
// InstrProfSymtab::create(Module) / addFuncWithName / getCanonicalName / getFunction (llvm/lib/ProfileData/
// InstrProf.cpp), with the vtable-comparison mode (-enable-vtable-profile-use: computeVirtualCallSiteTypeInfoMap,
// computeVTableInfos, isProfitableToCompareVTables, tryToPromoteWithVTableCmp, tryToSinkInstructions,
// updateVPtrValueProfiles; the vtable half of the symtab).
// pgo::promoteIndirectCall is in call_promotion.jai.

icp_cl: struct {
    disable := false;                    // -disable-icp
    cutoff: u32 = 0;                     // -icp-cutoff
    cs_skip: u32 = 0;                    // -icp-csskip
    allow_decls := false;                // -icp-allow-decls
    allow_hot_only := true;              // -icp-allow-hot-only
    allow_candidate_skip := false;       // -icp-allow-candidate-skip
    lto_mode := false;                   // -icp-lto
    sample_pgo_mode := false;            // -icp-samplepgo
    call_only := false;                  // -icp-call-only
    invoke_only := false;                // -icp-invoke-only
    enable_vtable_profile_use := false;  // -enable-vtable-profile-use (PGOInstrumentation.cpp)
    vtable_percentage_threshold: float32 = 0.995;   // -icp-vtable-percentage-threshold
    max_num_vtable_last_candidate: s32 = 1;         // -icp-max-num-vtable-last-candidate
    ignored_base_types: [..] string;                // -icp-ignored-base-types (cl::list)
    max_num_vtable_annotations: u32 = 6;            // -icp-max-num-vtables (IndirectCallPromotionAnalysis.cpp)
    // IndirectCallPromotionAnalysis.cpp
    remaining_percent_threshold: u64 = 30;   // -icp-remaining-percent-threshold
    total_percent_threshold: u64 = 5;        // -icp-total-percent-threshold
    minimum_count_threshold: u64 = 0;        // -icp-minimum-count-threshold
    max_num_promotions: u32 = 3;             // -icp-max-prom
}
// STATISTIC(NumOfPGOICallPromotion), STATISTIC(NumOfPGOICallsites): the cutoff and skip options read them
icp_num_promotions: u32 = 0;
icp_num_callsites: u32 = 0;

icp_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    o := *icp_cl;
    if name == {
        case "disable-icp"; o.disable = smisc_bool(name, value, has_value);
        case "icp-cutoff"; o.cutoff = cast(u32) smisc_int(name, value, has_value);
        case "icp-csskip"; o.cs_skip = cast(u32) smisc_int(name, value, has_value);
        case "icp-allow-decls"; o.allow_decls = smisc_bool(name, value, has_value);
        case "icp-allow-hot-only"; o.allow_hot_only = smisc_bool(name, value, has_value);
        case "icp-allow-candidate-skip"; o.allow_candidate_skip = smisc_bool(name, value, has_value);
        case "icp-lto"; o.lto_mode = smisc_bool(name, value, has_value);
        case "icp-samplepgo"; o.sample_pgo_mode = smisc_bool(name, value, has_value);
        case "icp-call-only"; o.call_only = smisc_bool(name, value, has_value);
        case "icp-invoke-only"; o.invoke_only = smisc_bool(name, value, has_value);
        case "icp-dumpafter"; if smisc_bool(name, value, has_value) fatal("unsupported option '-icp-dumpafter' (debug output)");
        case "enable-vtable-profile-use"; o.enable_vtable_profile_use = smisc_bool(name, value, has_value);
        case "icp-vtable-percentage-threshold";
            v, ok := string_to_float(prof_str(name, value, has_value));
            if !ok fatal("invalid value '%' for -icp-vtable-percentage-threshold", value);
            o.vtable_percentage_threshold = v;
        case "icp-max-num-vtable-last-candidate"; o.max_num_vtable_last_candidate = cast(s32) smisc_int(name, value, has_value);
        case "icp-ignored-base-types"; array_add(*o.ignored_base_types, copy_string(prof_str(name, value, has_value)));
        case "icp-max-num-vtables"; o.max_num_vtable_annotations = cast(u32) smisc_int(name, value, has_value);
        case "icp-remaining-percent-threshold"; o.remaining_percent_threshold = cast(u64) smisc_int(name, value, has_value);
        case "icp-total-percent-threshold"; o.total_percent_threshold = cast(u64) smisc_int(name, value, has_value);
        case "icp-minimum-count-threshold"; o.minimum_count_threshold = cast(u64) smisc_int(name, value, has_value);
        case "icp-max-prom"; o.max_num_promotions = cast(u32) smisc_int(name, value, has_value);
        case; return false;
    }
    return true;
}
icp_takes_value :: (n: string) -> bool {
    for string.["icp-cutoff", "icp-csskip", "icp-remaining-percent-threshold", "icp-total-percent-threshold",
                "icp-minimum-count-threshold", "icp-max-prom", "icp-vtable-percentage-threshold",
                "icp-max-num-vtable-last-candidate", "icp-ignored-base-types", "icp-max-num-vtables"] if n == it return true;
    return false;
}

// ---------------------------------------------------------------- InstrProfSymtab (functions only)

Icp_Symtab_Entry :: struct { md5: u64; f: Value_Id; }

// InstrProfSymtab::getCanonicalName
instrprof_canonical_name :: (pgo_name: string) -> string {
    return sp_canonical_fn_name_with(pgo_name, .[SUFFIX_LLVM, SUFFIX_PART]);
}

// getIRPGOObjectName(F, InLTO, getPGOFuncNameMetadata(F)) / getPGOFuncName(F, InLTO)
icp_pgo_name_from_metadata :: (f: Value_Id) -> (bool, string) {
    md := get_metadata(f, md_kind_id("PGOFuncName"));
    if md == NONE return false, "";
    s := md_op(md, 0);
    if s == NONE || ir.mds[s].kind != .STRING return false, "";
    return true, ir.mds[s].str;
}
icp_irpgo_func_name :: (f: Value_Id, in_lto: bool) -> string {
    if !in_lto return irpgo_object_name(f);
    ok, s := icp_pgo_name_from_metadata(f);
    if ok return s;
    return global_identifier_for(vname(f), .EXTERNAL, "");
}
icp_pgo_func_name :: (f: Value_Id, in_lto: bool) -> string {
    if !in_lto return pgo_func_name_legacy(f);
    ok, s := icp_pgo_name_from_metadata(f);
    if ok return s;
    name := vname(f);
    if name.count && name[0] == 1 name = slice(name, 1, name.count - 1);
    return name;
}

// InstrProfSymtab::create(M, InLTO) for functions, then finalizeSymtab (sort by MD5)
icp_symtab_create :: (in_lto: bool) -> [..] Icp_Symtab_Entry {
    tab: [..] Icp_Symtab_Entry; tab.allocator = temp;
    add :: (f: Value_Id, name: string) #expand {
        array_add(*tab, .{md5_hash_u64(name), f});
        c := instrprof_canonical_name(name);
        if c != name array_add(*tab, .{md5_hash_u64(c), f});
    }
    for f: ir.m_functions {
        if vname(f).count == 0 continue;
        irn := icp_irpgo_func_name(f, in_lto);
        add(f, irn);
        pn := icp_pgo_func_name(f, in_lto);
        if pn != irn add(f, pn);
    }
    // llvm::sort(MD5FuncMap, less_first()) is unstable: two different functions with one MD5 would make the
    // lookup depend on the sort's internals
    for a: 1..tab.count - 1 {
        x := tab[a]; b := a - 1;
        while b >= 0 && tab[b].md5 > x.md5 { tab[b + 1] = tab[b]; b -= 1; }
        tab[b + 1] = x;
    }
    for k: 1..tab.count - 1 if tab[k].md5 == tab[k - 1].md5 && tab[k].f != tab[k - 1].f
        fatal("pgo-icall-prom: two functions (%, %) with the same PGO name MD5: the symtab lookup is order dependent", vname(tab[k - 1].f), vname(tab[k].f));
    return tab;
}
// the vtable half of InstrProfSymtab::create: MD5VTableMap.try_emplace (the first vtable of a GUID wins)
icp_vtable_symtab: Table(u64, Value_Id);
icp_vtable_symtab_create :: (in_lto: bool) {
    icp_vtable_symtab = .{};
    icp_vtable_symtab.allocator = temp;
    for g: ir.m_globals {
        if vname(g).count == 0 || get_metadata(g, md_fixed("type")) == NONE continue;
        name := ifx in_lto then global_identifier_for(vname(g), .EXTERNAL, "") else irpgo_object_name(g);
        add :: (n: string, g: Value_Id) {
            h := md5_hash_u64(n);
            if !table_contains(*icp_vtable_symtab, h) table_set(*icp_vtable_symtab, h, g);
        }
        add(name, g);
        c := instrprof_canonical_name(name);
        if c != name add(c, g);
    }
}
icp_symtab_get_global_variable :: (md5: u64) -> Value_Id {
    found, g := table_find(*icp_vtable_symtab, md5);
    return ifx found then g else NONE;
}
icp_symtab_get_function :: (tab: [] Icp_Symtab_Entry, md5: u64) -> Value_Id {
    lo := 0; hi := tab.count;
    while lo < hi { m := (lo + hi) / 2; if tab[m].md5 < md5 lo = m + 1; else hi = m; }
    if lo < tab.count && tab[lo].md5 == md5 return tab[lo].f;
    return NONE;
}

// ---------------------------------------------------------------- ICallPromotionAnalysis

icp_is_promotion_profitable :: (count: u64, total: u64, remaining: u64) -> bool {
    return count >= icp_cl.minimum_count_threshold && count * 100 >= icp_cl.remaining_percent_threshold * remaining &&
           count * 100 >= icp_cl.total_percent_threshold * total;
}
// getPromotionCandidatesForInstruction(I, TotalCount, NumCandidates, MaxNumValueData = 0)
icp_candidates_for_instruction :: (i: Value_Id) -> ([..] Vp_Data, u64, u32) {
    vds, _, total := vp_get_value_prof_data(i, IPVK_INDIRECT_CALL_TARGET, icp_cl.max_num_promotions, false);
    if vds.count == 0 return vds, total, 0;
    k: u32 = 0;
    remaining := total;
    while k < icp_cl.max_num_promotions && k < cast(u32) vds.count {
        c := vds[k].count;
        if !icp_is_promotion_profitable(c, total, remaining) break;
        remaining -= c;
        k += 1;
    }
    return vds, total, k;
}

// ---------------------------------------------------------------- IndirectCallPromoter

Icp_Candidate :: struct {
    f: Value_Id; count: u64; index: u32;
    vtable_guid_and_counts: Dm_U64;   // VTableGUIDAndCounts
    address_points: [..] Value_Id;
}

// SmallDenseMap<uint64_t, uint64_t, 16> with LLVM 23's DenseMap layout (linear probing, mix() hash, growth at 3/4
// to max(64, ...)), so that iterating it gives LLVM's order
Dm_U64 :: struct {
    keys: [..] u64;
    vals: [..] u64;
    buckets: [..] s32;   // -1: empty, else an index into keys / vals
}
dm_u64_hash :: (k: u64) -> u32 { x := k * 0xbf58476d1ce4e5b9; x ^= x >> 31; return cast,no_check(u32) x; }
dm_u64_find :: (m: *Dm_U64, k: u64) -> s32 {
    n := m.buckets.count;
    if n == 0 return -1;
    mask := cast(u32) (n - 1);
    b := dm_u64_hash(k) & mask;
    while true {
        e := m.buckets[b];
        if e < 0 return -1;
        if m.keys[e] == k return e;
        b = (b + 1) & mask;
    }
    return -1;
}
dm_u64_place :: (m: *Dm_U64, e: s32) {
    mask := cast(u32) (m.buckets.count - 1);
    b := dm_u64_hash(m.keys[e]) & mask;
    while m.buckets[b] >= 0 b = (b + 1) & mask;
    m.buckets[b] = e;
}
// operator[]
dm_u64_get :: (m: *Dm_U64, k: u64) -> *u64 {
    if m.buckets.count == 0 {
        m.keys.allocator = temp; m.vals.allocator = temp; m.buckets.allocator = temp;
        for 0..15 array_add(*m.buckets, -1);
    }
    e := dm_u64_find(m, k);
    if e >= 0 return *m.vals[e];
    n := m.buckets.count;
    if (m.keys.count + 1) * 4 >= n * 3 {
        nn := max(64, n * 2);
        m.buckets.count = 0;
        for 0..nn - 1 array_add(*m.buckets, -1);
        for 0..m.keys.count - 1 dm_u64_place(m, cast(s32) it);
    }
    array_add(*m.keys, k);
    array_add(*m.vals, 0);
    ne := cast(s32) (m.keys.count - 1);
    dm_u64_place(m, ne);
    return *m.vals[ne];
}
// iteration order: the entries in bucket order
dm_u64_order :: (m: *Dm_U64) -> [..] s32 {
    r: [..] s32; r.allocator = temp;
    for m.buckets if it >= 0 array_add(*r, it);
    return r;
}

// a 128-bit (a * b) / d, the APInt arithmetic of tryToPromoteWithFuncCmp
mul_div_u128 :: (a: u64, b: u64, d: u64) -> u64 {
    // 64x64 -> 128 multiplication
    a_lo := a & 0xFFFF_FFFF; a_hi := a >> 32; b_lo := b & 0xFFFF_FFFF; b_hi := b >> 32;
    p0 := a_lo * b_lo; p1 := a_lo * b_hi; p2 := a_hi * b_lo; p3 := a_hi * b_hi;
    mid := (p0 >> 32) + (p1 & 0xFFFF_FFFF) + (p2 & 0xFFFF_FFFF);
    lo := (p0 & 0xFFFF_FFFF) | (mid << 32);
    hi := p3 + (p1 >> 32) + (p2 >> 32) + (mid >> 32);
    // long division of (hi, lo) by d, keeping the low 64 bits of the quotient
    q: u64 = 0; r: u64 = 0;
    for < bit: 0..127 {
        carry := (r >> 63) != 0;
        r = r << 1;
        if bit >= 64 r |= (hi >> cast(u64) (bit - 64)) & 1; else r |= (lo >> cast(u64) bit) & 1;
        if carry || r >= d {
            r -= d;
            if bit < 64 q |= cast(u64) 1 << cast(u64) bit;
        }
    }
    return q;
}

// VirtualCallSiteInfo
Icp_Vcs_Info :: struct { function_offset: u64; vptr: Value_Id; compatible_type: string; }
icp_virtual_cs_info: Table(Value_Id, Icp_Vcs_Info);
icp_vtable_address_points: Table(u64, Value_Id);   // VTableAddressPointOffsetVal: (vtable << 32 | offset) -> constant

// computeVirtualCallSiteTypeInfoMap
icp_compute_virtual_call_site_type_info_map :: () {
    icp_virtual_cs_info = .{}; icp_virtual_cs_info.allocator = temp;
    tt := module_get_function("llvm.type.test");
    if tt == NONE || ir.v_first_use[tt] == NONE return;
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[tt];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for ci: users {
        if !is_inst(ci) || inst_op(ci) != .CALL continue;
        a := call_arg(ci, 1);
        if vkind(a) != .MD_VALUE fatal("pgo-icall-prom: the second argument of a type test must be metadata");
        type_id := ir.v_aux[a];
        if ir.mds[type_id].kind != .STRING continue;
        calls: [..] Wpd_Devirt_Call; calls.allocator = temp;
        dt := get_domtree(block_fn(inst_block(ci)));
        // findDevirtualizableCallsForTypeTest
        has_assume := false;
        x := ir.v_first_use[ci];
        while x != NONE { if wpd_is_assume(ir.u_user[x]) has_assume = true; x = ir.u_next[x]; }
        if has_assume wpd_find_load_calls_at_constant_offset(*calls, strip_pointer_casts(call_arg(ci, 0)), 0, ci, dt);
        for c: calls {
            vt := icp_try_get_vtable_instruction(c.cb);
            if vt == NONE continue;
            table_set(*icp_virtual_cs_info, c.cb, .{c.offset, vt, ir.mds[type_id].str});
        }
    }
}
// PGOIndirectCallVisitor::tryGetVTableInstruction
icp_try_get_vtable_instruction :: (cb: Value_Id) -> Value_Id {
    if !pgo_is_indirect_call(cb) return NONE;
    ld := call_callee(cb);
    if !is_inst(ld) || inst_op(ld) != .LOAD return NONE;
    vt := strip_in_bounds_constant_offsets(op(ld, 0));
    if vt != NONE && is_inst(vt) return vt;
    return NONE;
}

// getAddressPointOffset
icp_address_point_offset :: (vt: Value_Id, compatible_type: string) -> (bool, u64) {
    types: [..] Md_Id; types.allocator = temp;
    ltt_type_mds(vt, *types);
    for t: types {
        tid := md_op(t, 1);
        if tid != NONE && ir.mds[tid].kind == .STRING && ir.mds[tid].str == compatible_type return true, ltt_type_offset(t);
    }
    return false, 0;
}
// getOrCreateVTableAddressPointVar / getVTableAddressPointOffset
icp_vtable_address_point :: (vt: Value_Id, offset: u64) -> Value_Id {
    key := ((cast(u64) vt) << 32) | (offset & 0xFFFF_FFFF);
    found, c := table_find(*icp_vtable_address_points, key);
    if found return c;
    c = ce_gep(ir.t_i8, vt, .[const_int(ir.t_i32, offset & 0xFFFF_FFFF)], F_INBOUNDS);
    table_set(*icp_vtable_address_points, key, c);
    return c;
}

// computeVTableInfos
icp_compute_vtable_infos :: (cb: Value_Id, guid_counts: *Dm_U64, candidates: [] Icp_Candidate) -> Value_Id {
    if !icp_cl.enable_vtable_profile_use return NONE;
    found, info := table_find(*icp_virtual_cs_info, cb);
    if !found return NONE;
    vptr := info.vptr;
    vds, _, _ := vp_get_value_prof_data(vptr, IPVK_VTABLE_TARGET, icp_cl.max_num_vtable_annotations, false);
    if vds.count == 0 return vptr;
    for v: vds {
        dm_u64_get(guid_counts, v.value).* = v.count;
        vt := icp_symtab_get_global_variable(v.value);
        if vt == NONE continue;
        ok, ap_off := icp_address_point_offset(vt, info.compatible_type);
        if !ok continue;
        callee, _ := wpd_function_at_vtable_offset(vt, ap_off + info.function_offset);
        if callee == NONE continue;
        idx := -1;
        for candidates if it.f == callee idx = it_index;   // CalleeIndexMap: the last candidate of a callee
        if idx < 0 continue;
        c := *candidates[idx];
        dm_u64_get(*c.vtable_guid_and_counts, v.value).* = v.count;
        if c.address_points.count == 0 c.address_points.allocator = temp;
        array_add(*c.address_points, icp_vtable_address_point(vt, ap_off));
    }
    return vptr;
}

// shouldSkipVTable
icp_should_skip_vtable :: (guid: u64) -> bool {
    if icp_cl.ignored_base_types.count == 0 return false;
    vt := icp_symtab_get_global_variable(guid);
    types: [..] Md_Id; types.allocator = temp;
    ltt_type_mds(vt, *types);
    for t: types {
        tid := md_op(t, 1);
        if tid != NONE && ir.mds[tid].kind == .STRING && array_find(icp_cl.ignored_base_types, ir.mds[tid].str) return true;
    }
    return false;
}
// isProfitableToCompareVTables
icp_is_profitable_to_compare_vtables :: (cb: Value_Id, candidates: [] Icp_Candidate) -> bool {
    if !icp_cl.enable_vtable_profile_use || candidates.count == 0 return false;
    for c, i: candidates {
        sum: u64 = 0;
        for e: c.vtable_guid_and_counts.keys {
            sum += c.vtable_guid_and_counts.vals[it_index];
        }
        // shouldSkipVTable is called per GUID in the map's order; it only returns early
        for e: c.vtable_guid_and_counts.keys if icp_should_skip_vtable(e) return false;
        if u64_to_f32(sum) < u64_to_f32(c.count) * icp_cl.vtable_percentage_threshold return false;
        max_num_vtable: s32 = 1;
        if i == candidates.count - 1 max_num_vtable = icp_cl.max_num_vtable_last_candidate;
        if cast(s32) c.address_points.count > max_num_vtable return false;
    }
    return true;
}

// updateVPtrValueProfiles
icp_update_vptr_value_profiles :: (vptr: Value_Id, guid_counts: *Dm_U64) {
    if !icp_cl.enable_vtable_profile_use || vptr == NONE || get_metadata(vptr, md_fixed("prof")) == NONE return;
    set_metadata(vptr, md_fixed("prof"), NONE);
    vps: [..] Vp_Data; vps.allocator = temp;
    total: u64 = 0;
    for e: dm_u64_order(guid_counts) {
        c := guid_counts.vals[e];
        if c == 0 continue;
        array_add(*vps, .{guid_counts.keys[e], c});
        total += c;
    }
    // llvm::sort by count, descending: std::sort is an insertion sort for up to 16 elements
    if vps.count > 16 {
        for a: 1..vps.count - 1 for b: 0..a - 1 if vps[b].count == vps[a].count
            fatal("pgo-icall-prom: more than 16 vtable profiles with equal counts (std::sort order)");
    }
    for a: 1..vps.count - 1 {
        x := vps[a]; b := a - 1;
        while b >= 0 && vps[b].count < x.count { vps[b + 1] = vps[b]; b -= 1; }
        vps[b + 1] = x;
    }
    vp_annotate_value_site(vptr, vps, total, IPVK_VTABLE_TARGET, cast(u32) vps.count);
}

// isDestBBSuitableForSink
icp_is_dest_bb_suitable_for_sink :: (i: Value_Id, dest: Value_Id) -> bool {
    user_bb: Value_Id = NONE;
    u := ir.v_first_use[i];
    while u != NONE {
        defer u = ir.u_next[u];
        usr := ir.u_user[u];
        if !is_inst(usr) fatal("pgo-icall-prom: a non-instruction user of an instruction");
        if is_debug_or_pseudo_inst(usr) continue;
        user_bb = ifx inst_op(usr) == .PHI then cast(Value_Id) ir.u_aux[u] else inst_block(usr);
        if user_bb != dest return false;
    }
    return user_bb != NONE;
}
// tryToSinkInstruction
icp_try_to_sink_instruction :: (i: Value_Id, dest: Value_Id) -> bool {
    if !icp_is_dest_bb_suitable_for_sink(i, dest) return false;
    o := inst_op(i);
    if o == .PHI || is_eh_pad(i) || may_throw(i) || !will_return(i) || o == .ALLOCA return false;
    if is_call_base(i) {
        if vkind(call_callee(i)) == .INLINE_ASM || call_has_fn_attr(i, .NoMerge) || call_is_convergent(i) return false;
    }
    if may_write_to_memory(i) return false;
    if may_read_from_memory(i) {
        s := inst_next(i);
        while s != NONE { if may_write_to_memory(s) return false; s = inst_next(s); }
    }
    // I->moveBefore(*DestBlock, DestBlock->getFirstInsertionPt())
    inst_move_before_at(i, block_first_insertion_pt(dest), true);
    return true;
}
// tryToSinkInstructions
icp_try_to_sink_instructions :: (orig_bb: Value_Id, icall_bb: Value_Id) -> s32 {
    n: s32 = 0;
    if block_unique_predecessor(icall_bb) != orig_bb return n;
    // make_early_inc_range(drop_begin(reverse(BB))): from the second-to-last instruction backwards
    i := inst_prev(block_last(orig_bb));
    while i != NONE {
        prev := inst_prev(i);
        if icp_try_to_sink_instruction(i, icall_bb) n += 1;
        i = prev;
    }
    return n;
}

// tryToPromoteWithVTableCmp
icp_try_to_promote_with_vtable_cmp :: (cb: Value_Id, vptr: Value_Id, candidates: [] Icp_Candidate, total_in: u64, num_candidates: u32,
                                       vds: [] Vp_Data, guid_counts: *Dm_U64) -> bool {
    total := total_in;
    Promoted :: struct { index: u32; count: u64; }
    promoted: [..] Promoted; promoted.allocator = temp;
    for c: candidates {
        for k: c.vtable_guid_and_counts.keys dm_u64_get(guid_counts, k).* -= c.vtable_guid_and_counts.vals[it_index];
        orig_bb := inst_block(cb);
        cp_promote_call_with_vtable_cmp(cb, vptr, c.f, c.address_points, pgo_create_branch_weights(c.count, total - c.count));
        icp_try_to_sink_instructions(orig_bb, inst_block(cb));
        array_add(*promoted, .{c.index, c.count});
        total -= min(total, c.count);
        icp_num_promotions += 1;
    }
    if promoted.count == 0 return false;
    for p: promoted vds[p.index].count -= max(p.count, vds[p.index].count);
    icp_update_func_value_profiles(cb, vds, total, num_candidates);
    icp_update_vptr_value_profiles(vptr, guid_counts);
    return true;
}

// isValidTarget
icp_is_valid_target :: (target_fn: Value_Id, cb: Value_Id) -> bool {
    if target_fn == NONE return false;
    if !icp_cl.allow_decls && is_declaration(target_fn) return false;
    return cp_is_legal_to_promote(cb, target_fn);
}

// getPromotionCandidatesForCallSite
icp_promotion_candidates :: (tab: [] Icp_Symtab_Entry, cb: Value_Id, vds: [] Vp_Data, total_in: u64, num_candidates: u32) -> [..] Icp_Candidate {
    ret: [..] Icp_Candidate; ret.allocator = temp;
    icp_num_callsites += 1;
    if icp_cl.cs_skip != 0 && icp_num_callsites <= icp_cl.cs_skip return ret;
    for k: 0..cast(s64) num_candidates - 1 {
        count := vds[k].count;
        if icp_cl.invoke_only && inst_op(cb) == .CALL break;
        if icp_cl.call_only && inst_op(cb) == .INVOKE break;
        if icp_cl.cutoff != 0 && icp_num_promotions >= icp_cl.cutoff break;
        target_fn := icp_symtab_get_function(tab, vds[k].value);
        if !icp_is_valid_target(target_fn, cb) {
            if icp_cl.allow_candidate_skip continue;
            break;
        }
        c: Icp_Candidate; c.f = target_fn; c.count = count; c.index = cast(u32) k;
        array_add(*ret, c);
    }
    return ret;
}

// updateFuncValueProfiles
icp_update_func_value_profiles :: (cb: Value_Id, vds: [] Vp_Data, total: u64, max_md_count: u32) {
    set_metadata(cb, md_fixed("prof"), NONE);
    // stable_sort by count, descending
    for a: 1..vds.count - 1 {
        x := vds[a]; b := a - 1;
        while b >= 0 && vds[b].count < x.count { vds[b + 1] = vds[b]; b -= 1; }
        vds[b + 1] = x;
    }
    n := 0;
    while n < vds.count && vds[n].count > 0 n += 1;
    if total != 0 vp_annotate_value_site(cb, array_view(vds, 0, n), total, IPVK_INDIRECT_CALL_TARGET, max_md_count);
}

// tryToPromoteWithFuncCmp
icp_try_to_promote_with_func_cmp :: (cb: Value_Id, vptr: Value_Id, candidates: [] Icp_Candidate, total_in: u64, vds: [] Vp_Data, num_candidates: u32,
                                     sample_pgo: bool, guid_counts: *Dm_U64) -> bool {
    total := total_in;
    num_promoted := 0;
    for c: candidates {
        func_count := c.count;
        pgo_promote_indirect_call(cb, c.f, func_count, total, sample_pgo);
        total -= func_count;
        icp_num_promotions += 1;
        num_promoted += 1;
        vds[c.index].count = 0;
        if !icp_cl.enable_vtable_profile_use || c.vtable_guid_and_counts.keys.count == 0 continue;
        sum: u64 = 0;
        for c.vtable_guid_and_counts.vals sum += it;
        for k: c.vtable_guid_and_counts.keys
            dm_u64_get(guid_counts, k).* -= mul_div_u128(func_count, c.vtable_guid_and_counts.vals[it_index], sum);
    }
    if num_promoted == 0 return false;
    icp_update_func_value_profiles(cb, vds, total, num_candidates);
    icp_update_vptr_value_profiles(vptr, guid_counts);
    return true;
}

// processFunction
icp_process_function :: (tab: [] Icp_Symtab_Entry, f: Value_Id, psi: *Psi, sample_pgo: bool) -> bool {
    changed := false;
    calls: [..] Value_Id; calls.allocator = temp;
    for b: fn_blocks(f) for i: block_insts(b) if is_call_base(i) && pgo_is_indirect_call(i) array_add(*calls, i);   // findIndirectCalls
    for cb: calls {
        vds, total, num_candidates := icp_candidates_for_instruction(cb);
        if num_candidates == 0 continue;
        if psi != null && psi.has_summary {
            if psi_is_cold_count(psi, total) continue;
            if icp_cl.allow_hot_only && !psi_is_hot_count(psi, total) continue;
        }
        candidates := icp_promotion_candidates(tab, cb, vds, total, num_candidates);
        guid_counts: Dm_U64;
        vptr := icp_compute_vtable_infos(cb, *guid_counts, candidates);
        if icp_is_profitable_to_compare_vtables(cb, candidates) {
            if icp_try_to_promote_with_vtable_cmp(cb, vptr, candidates, total, num_candidates, vds, *guid_counts) changed = true;
        } else {
            if icp_try_to_promote_with_func_cmp(cb, vptr, candidates, total, vds, num_candidates, sample_pgo, *guid_counts) changed = true;
        }
    }
    return changed;
}

// PGOIndirectCallPromotion::run / promoteIndirectCalls
pgo_icall_prom_run :: (in_lto_in: bool, sample_pgo_in: bool) -> Preserved {
    psi := psi_require();
    in_lto := in_lto_in || icp_cl.lto_mode;
    sample_pgo := sample_pgo_in || icp_cl.sample_pgo_mode;
    if icp_cl.disable return PRESERVE_ALL;
    tab := icp_symtab_create(in_lto);
    icp_vtable_symtab_create(in_lto);
    icp_virtual_cs_info = .{}; icp_virtual_cs_info.allocator = temp;
    icp_vtable_address_points = .{}; icp_vtable_address_points.allocator = temp;
    if icp_cl.enable_vtable_profile_use icp_compute_virtual_call_site_type_info_map();
    changed := false;
    for f: ir.m_functions {
        if is_declaration(f) || fn_has_fn_attr(f, .OptimizeNone) continue;
        if icp_process_function(tab, f, psi, sample_pgo) { changed = true; fam_invalidate(f, PRESERVE_NONE); }
        if icp_cl.cutoff != 0 && icp_num_promotions >= icp_cl.cutoff break;
    }
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
