// pgo-icall-prom (PGOIndirectCallPromotion): indirect call promotion from !prof "VP" value profiles.
// Ported from llvm/lib/Transforms/Instrumentation/IndirectCallPromotion.cpp (promoteIndirectCalls,
// IndirectCallPromoter: getPromotionCandidatesForCallSite, isValidTarget, tryToPromoteWithFuncCmp,
// updateFuncValueProfiles), llvm/lib/Analysis/IndirectCallPromotionAnalysis.cpp (ICallPromotionAnalysis) and
// InstrProfSymtab::create(Module) / addFuncWithName / getCanonicalName / getFunction (llvm/lib/ProfileData/
// InstrProf.cpp). The vtable-comparison mode (-enable-vtable-profile-use) is not ported: it fails loudly.
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
                "icp-minimum-count-threshold", "icp-max-prom"] if n == it return true;
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

Icp_Candidate :: struct { f: Value_Id; count: u64; index: u32; }

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
        array_add(*ret, .{target_fn, count, cast(u32) k});
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
icp_try_to_promote_with_func_cmp :: (cb: Value_Id, candidates: [] Icp_Candidate, total_in: u64, vds: [] Vp_Data, num_candidates: u32, sample_pgo: bool) -> bool {
    total := total_in;
    num_promoted := 0;
    for c: candidates {
        pgo_promote_indirect_call(cb, c.f, c.count, total, sample_pgo);
        total -= c.count;
        icp_num_promotions += 1;
        num_promoted += 1;
        vds[c.index].count = 0;
    }
    if num_promoted == 0 return false;
    icp_update_func_value_profiles(cb, vds, total, num_candidates);
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
        // computeVTableInfos / isProfitableToCompareVTables return early without -enable-vtable-profile-use; with it
        // but no type tests, a candidate of count 0 would pass isProfitableToCompareVTables (not ported)
        if icp_cl.enable_vtable_profile_use for candidates if it.count == 0
            fatal("pgo-icall-prom: -enable-vtable-profile-use with a zero-count candidate is not implemented yet");
        if icp_try_to_promote_with_func_cmp(cb, candidates, total, vds, num_candidates, sample_pgo) changed = true;
    }
    return changed;
}

// PGOIndirectCallPromotion::run / promoteIndirectCalls
pgo_icall_prom_run :: (in_lto_in: bool, sample_pgo_in: bool) -> Preserved {
    psi := psi_require();
    in_lto := in_lto_in || icp_cl.lto_mode;
    sample_pgo := sample_pgo_in || icp_cl.sample_pgo_mode;
    if icp_cl.disable return PRESERVE_ALL;
    if icp_cl.enable_vtable_profile_use {
        tt := lookup_global("llvm.type.test");
        if tt != NONE && vkind(tt) == .FUNCTION && ir.v_first_use[tt] != NONE
            fatal("pgo-icall-prom: -enable-vtable-profile-use (vtable comparison) is not implemented yet");
    }
    tab := icp_symtab_create(in_lto);
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
