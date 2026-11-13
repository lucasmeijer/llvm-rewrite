// ProfileSummaryInfo: ported from llvm/lib/Analysis/ProfileSummaryInfo.cpp (+ include/llvm/Analysis/ProfileSummaryInfo.h),
// ProfileSummary::getFromMD from llvm/lib/IR/ProfileSummary.cpp, ProfileSummaryBuilder::getEntryForPercentile /
// get{Hot,Cold}CountThreshold from llvm/lib/ProfileData/ProfileSummaryBuilder.cpp, and the block query of
// shouldOptimizeForSize from llvm/lib/Transforms/Utils/SizeOpts.cpp (+ SizeOpts.h).
//
// The module has one ProfileSummaryInfo (ProfileSummaryAnalysis is never invalidated). It is computed on first use
// (psi_get); `psi_cached` (passes.jai) says whether the module analysis result exists, which is what passes that use
// getCachedResult<ProfileSummaryAnalysis> see: psi_cached_or_null.

Psi_Kind :: enum u8 { SAMPLE; INSTR; CS_INSTR; }
Psi_Entry :: struct { cutoff: u64; min_count: u64; num_counts: u64; }

Psi :: struct {
    computed: bool;
    has_summary: bool;
    kind: Psi_Kind;
    is_partial: bool;
    partial_ratio: float64;
    detailed: [..] Psi_Entry;
    has_hot: bool; hot: u64;
    has_cold: bool; cold: u64;
    has_huge: bool; huge: bool;
    has_large: bool; large: bool;
    threshold_cache: Table(s64, u64);
}
psi_state: Psi;

Psi_Opts :: struct {
    cutoff_hot: u64 = 990000;                 // -profile-summary-cutoff-hot
    cutoff_cold: u64 = 999999;                // -profile-summary-cutoff-cold
    huge_wss_threshold: u64 = 15000;          // -profile-summary-huge-working-set-size-threshold
    large_wss_threshold: u64 = 12500;         // -profile-summary-large-working-set-size-threshold
    hot_count_given: bool; hot_count: u64;    // -profile-summary-hot-count
    cold_count_given: bool; cold_count: u64;  // -profile-summary-cold-count
    partial_profile: bool;                    // -partial-profile
    scale_partial_wss := true;                // -scale-partial-sample-profile-working-set-size
    partial_wss_scale_factor: float64 = 0.008; // -partial-sample-profile-working-set-size-scale-factor
    // SizeOpts.cpp
    enable_pgso := true;                      // -pgso
    pgso_lwss_only := true;                   // -pgso-lwss-only
    pgso_cold_code_only: bool;                // -pgso-cold-code-only
    pgso_cold_code_only_instr: bool;          // -pgso-cold-code-only-for-instr-pgo
    pgso_cold_code_only_sample: bool;         // -pgso-cold-code-only-for-sample-pgo
    pgso_cold_code_only_partial_sample: bool; // -pgso-cold-code-only-for-partial-sample-pgo
    force_pgso: bool;                         // -force-pgso
    pgso_cutoff_instr: s64 = 950000;          // -pgso-cutoff-instr-prof
    pgso_cutoff_sample: s64 = 990000;         // -pgso-cutoff-sample-prof
}
psi_opts: Psi_Opts;

psi_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    int_opt :: (name: string, value: string, has_value: bool) -> s64 {
        if !has_value fatal("option -% needs a value", name);
        v, ok, rest := string_to_int(value);
        if !ok || rest.count fatal("invalid integer value '%' for option -%", value, name);
        return v;
    }
    bool_opt :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("invalid boolean value '%' for option -%", value, name);
        return false;
    }
    o := *psi_opts;
    if name == {
        case "profile-summary-cutoff-hot"; o.cutoff_hot = cast(u64) int_opt(name, value, has_value);
        case "profile-summary-cutoff-cold"; o.cutoff_cold = cast(u64) int_opt(name, value, has_value);
        case "profile-summary-huge-working-set-size-threshold"; o.huge_wss_threshold = cast(u64) int_opt(name, value, has_value);
        case "profile-summary-large-working-set-size-threshold"; o.large_wss_threshold = cast(u64) int_opt(name, value, has_value);
        case "profile-summary-hot-count"; o.hot_count_given = true; o.hot_count = cast(u64) int_opt(name, value, has_value);
        case "profile-summary-cold-count"; o.cold_count_given = true; o.cold_count = cast(u64) int_opt(name, value, has_value);
        case "partial-profile"; o.partial_profile = bool_opt(name, value, has_value);
        case "scale-partial-sample-profile-working-set-size"; o.scale_partial_wss = bool_opt(name, value, has_value);
        case "partial-sample-profile-working-set-size-scale-factor";
            if !has_value fatal("option -% needs a value", name);
            v, ok := string_to_float64(value);
            if !ok fatal("invalid floating-point value '%' for option -%", value, name);
            o.partial_wss_scale_factor = v;
        case "pgso"; o.enable_pgso = bool_opt(name, value, has_value);
        case "pgso-lwss-only"; o.pgso_lwss_only = bool_opt(name, value, has_value);
        case "pgso-cold-code-only"; o.pgso_cold_code_only = bool_opt(name, value, has_value);
        case "pgso-cold-code-only-for-instr-pgo"; o.pgso_cold_code_only_instr = bool_opt(name, value, has_value);
        case "pgso-cold-code-only-for-sample-pgo"; o.pgso_cold_code_only_sample = bool_opt(name, value, has_value);
        case "pgso-cold-code-only-for-partial-sample-pgo"; o.pgso_cold_code_only_partial_sample = bool_opt(name, value, has_value);
        case "force-pgso"; o.force_pgso = bool_opt(name, value, has_value);
        case "pgso-cutoff-instr-prof"; o.pgso_cutoff_instr = int_opt(name, value, has_value);
        case "pgso-cutoff-sample-prof"; o.pgso_cutoff_sample = int_opt(name, value, has_value);
        case; return false;
    }
    return true;
}

// Module::getModuleFlag(Key)
module_flag :: (key: string) -> Md_Id {
    for * ir.named_md {
        if it.name != "llvm.module.flags" continue;
        for m: it.ops {
            if ir.mds[m].nops < 3 continue;
            k := md_op(m, 1);
            if k != NONE && ir.mds[k].kind == .STRING && ir.mds[k].str == key return md_op(m, 2);
        }
    }
    return NONE;
}

// ProfileSummary.cpp: getValMD / getVal / isKeyValuePair
psi_val_md :: (m: Md_Id, key: string) -> Value_Id {
    if m == NONE || ir.mds[m].kind != .TUPLE || md_nops(m) != 2 return NONE;
    k := md_op(m, 0); v := md_op(m, 1);
    if k == NONE || ir.mds[k].kind != .STRING || v == NONE || ir.mds[v].kind != .VALUE return NONE;
    if ir.mds[k].str != key return NONE;
    return ir.mds[v].value;
}
psi_get_val :: (m: Md_Id, key: string) -> (bool, u64) {
    v := psi_val_md(m, key);
    if v == NONE return false, 0;
    if !is_scalar_const_int(v) fatal("internal: profile summary field '%' is not a ConstantInt", key);
    return true, const_int_zext(v);
}
psi_is_key_value_pair :: (m: Md_Id, key: string, val: string) -> bool {
    if m == NONE || ir.mds[m].kind != .TUPLE || md_nops(m) != 2 return false;
    k := md_op(m, 0); v := md_op(m, 1);
    if k == NONE || ir.mds[k].kind != .STRING || v == NONE || ir.mds[v].kind != .STRING return false;
    return ir.mds[k].str == key && ir.mds[v].str == val;
}

// ProfileSummary::getFromMD into p (false = no summary)
psi_from_md :: (p: *Psi, m: Md_Id) -> bool {
    if m == NONE || ir.mds[m].kind != .TUPLE || md_nops(m) < 8 || md_nops(m) > 10 return false;
    i: u32 = 0;
    fm := md_op(m, i); i += 1;
    if psi_is_key_value_pair(fm, "ProfileFormat", "SampleProfile") p.kind = .SAMPLE;
    else if psi_is_key_value_pair(fm, "ProfileFormat", "InstrProf") p.kind = .INSTR;
    else if psi_is_key_value_pair(fm, "ProfileFormat", "CSInstrProf") p.kind = .CS_INSTR;
    else return false;
    for key: string.["TotalCount", "MaxCount", "MaxInternalCount", "MaxFunctionCount", "NumCounts", "NumFunctions"] {
        ok, _ := psi_get_val(md_op(m, i), key); i += 1;
        if !ok return false;
    }
    // optional fields
    ok, ipp := psi_get_val(md_op(m, i), "IsPartialProfile");
    if ok { i += 1; if i >= md_nops(m) return false; }
    p.is_partial = ok && ipp != 0;
    p.partial_ratio = 0;
    rv := psi_val_md(md_op(m, i), "PartialProfileRatio");
    if rv != NONE {
        r, rok := fp_const_as_f64(rv);
        if !rok fatal("internal: PartialProfileRatio is not a double");
        p.partial_ratio = r;
        i += 1;
        if i >= md_nops(m) return false;
    }
    // getSummaryFromMD
    d := md_op(m, i);
    if d == NONE || ir.mds[d].kind != .TUPLE || md_nops(d) != 2 return false;
    k := md_op(d, 0);
    if k == NONE || ir.mds[k].kind != .STRING || ir.mds[k].str != "DetailedSummary" return false;
    es := md_op(d, 1);
    if es == NONE || ir.mds[es].kind != .TUPLE return false;
    p.detailed.count = 0;
    for j: 0..cast(s64) md_nops(es) - 1 {
        e := md_op(es, cast(u32) j);
        if e == NONE || ir.mds[e].kind != .TUPLE || md_nops(e) != 3 return false;
        vals: [3] u64;
        for q: 0..2 {
            o := md_op(e, cast(u32) q);
            if o == NONE || ir.mds[o].kind != .VALUE return false;
            vals[q] = const_int_zext(ir.mds[o].value);
        }
        array_add(*p.detailed, .{vals[0], vals[1], vals[2]});
    }
    return true;
}

// ProfileSummaryBuilder::getEntryForPercentile
psi_entry_for_percentile :: (p: *Psi, percentile: u64) -> Psi_Entry {
    if percentile == 0 return .{0, 0xFFFF_FFFF_FFFF_FFFF, 0};   // ZeroCutoffEntry
    for p.detailed if it.cutoff >= percentile return it;
    fatal("Desired percentile exceeds the maximum cutoff");
    return .{};
}

// ProfileSummaryInfo(M) / refresh() + computeThresholds()
psi_get :: () -> *Psi {
    p := *psi_state;
    if p.computed return p;
    p.computed = true;
    p.has_summary = psi_from_md(p, module_flag("CSProfileSummary"));
    if !p.has_summary p.has_summary = psi_from_md(p, module_flag("ProfileSummary"));
    if !p.has_summary return p;
    hot_entry := psi_entry_for_percentile(p, psi_opts.cutoff_hot);
    p.has_hot = true; p.hot = hot_entry.min_count;
    if psi_opts.hot_count_given p.hot = psi_opts.hot_count;
    p.has_cold = true; p.cold = psi_entry_for_percentile(p, psi_opts.cutoff_cold).min_count;
    if psi_opts.cold_count_given p.cold = psi_opts.cold_count;
    if p.hot == p.cold {
        if p.cold > 0 p.cold -= 1;
        else p.hot += 1;
    }
    p.has_huge = true; p.has_large = true;
    if !psi_has_partial_sample_profile(p) || !psi_opts.scale_partial_wss {
        p.huge = hot_entry.num_counts > psi_opts.huge_wss_threshold;
        p.large = hot_entry.num_counts > psi_opts.large_wss_threshold;
    } else {
        scaled := cast(u64) (cast(float64) hot_entry.num_counts * p.partial_ratio * psi_opts.partial_wss_scale_factor);
        p.huge = scaled > psi_opts.huge_wss_threshold;
        p.large = scaled > psi_opts.large_wss_threshold;
    }
    return p;
}
// MAM.getCachedResult<ProfileSummaryAnalysis>(M)
psi_cached_or_null :: () -> *Psi { return ifx psi_cached then psi_get() else null; }
// MAM.getResult<ProfileSummaryAnalysis>(M)
psi_require :: () -> *Psi { psi_cached = true; return psi_get(); }

psi_has_partial_sample_profile :: (p: *Psi) -> bool { return p.has_summary && p.kind == .SAMPLE && (psi_opts.partial_profile || p.is_partial); }
psi_has_sample_profile :: (p: *Psi) -> bool { return p.has_summary && p.kind == .SAMPLE; }
psi_has_instrumentation_profile :: (p: *Psi) -> bool { return p.has_summary && p.kind == .INSTR; }
psi_has_large_working_set_size :: (p: *Psi) -> bool { return p.has_large && p.large; }
psi_is_hot_count :: (p: *Psi, c: u64) -> bool { return p.has_hot && c >= p.hot; }
psi_is_cold_count :: (p: *Psi, c: u64) -> bool { return p.has_cold && c <= p.cold; }
psi_or_comp_hot_count_threshold :: (p: *Psi) -> u64 { return ifx p.has_hot then p.hot else 0xFFFF_FFFF_FFFF_FFFF; }
// computeThreshold(PercentileCutoff)
psi_compute_threshold :: (p: *Psi, cutoff: s64) -> (bool, u64) {
    if !p.has_summary return false, 0;
    found, v := table_find(*p.threshold_cache, cutoff);
    if found return true, v;
    v = psi_entry_for_percentile(p, cast(u64) cutoff).min_count;
    table_set(*p.threshold_cache, cutoff, v);
    return true, v;
}
psi_is_hot_count_nth_percentile :: (p: *Psi, cutoff: s64, c: u64) -> bool { ok, t := psi_compute_threshold(p, cutoff); return ok && c >= t; }
psi_is_cold_count_nth_percentile :: (p: *Psi, cutoff: s64, c: u64) -> bool { ok, t := psi_compute_threshold(p, cutoff); return ok && c <= t; }

// isFunctionEntryHot / isFunctionEntryCold
psi_is_function_entry_hot :: (p: *Psi, f: Value_Id) -> bool {
    if f == NONE || !p.has_summary return false;
    ok, c := function_entry_count(f);
    return ok && psi_is_hot_count(p, c);
}
psi_is_function_entry_cold :: (p: *Psi, f: Value_Id) -> bool {
    if f == NONE return false;
    if fn_has_fn_attr(f, .Cold) return true;
    if !p.has_summary return false;
    ok, c := function_entry_count(f);
    return ok && psi_is_cold_count(p, c);
}

// BlockFrequencyInfo::getBlockProfileCount(BB)
bfi_block_profile_count :: (b: *Bfi, bb: Value_Id) -> (bool, u64) {
    ok, c := bfi_profile_count_from_freq(b, b.f, bfi_get_block_freq(b, bb));
    return ok, c;
}
// extractProfTotalWeight(I, TotalVal)
prof_extract_total_weight :: (i: Value_Id) -> (bool, u64) {
    m := prof_md(i);
    if m == NONE || md_nops(m) == 0 return false, 0;
    s := md_op(m, 0);
    if s == NONE || ir.mds[s].kind != .STRING return false, 0;
    if ir.mds[s].str == "branch_weights" {
        total: u64 = 0;
        off: u32 = ifx prof_has_branch_weight_origin(m) then cast(u32) 2 else 1;
        for k: off..md_nops(m) - 1 total += const_int_zext(md_const_int_op(m, k));
        return true, total;
    }
    if ir.mds[s].str == "VP" && md_nops(m) > 3 return true, const_int_zext(md_const_int_op(m, 2));
    return false, 0;
}
// getProfileCount(CallBase, BFI)
psi_profile_count :: (p: *Psi, call: Value_Id, bfi: *Bfi) -> (bool, u64) {
    if psi_has_sample_profile(p) { ok, c := prof_extract_total_weight(call); return ok, c; }
    if bfi { ok, c := bfi_block_profile_count(bfi, inst_block(call)); return ok, c; }
    return false, 0;
}
psi_is_hot_call_site :: (p: *Psi, call: Value_Id, bfi: *Bfi) -> bool {
    ok, c := psi_profile_count(p, call, bfi);
    return ok && psi_is_hot_count(p, c);
}
psi_is_cold_call_site :: (p: *Psi, call: Value_Id, bfi: *Bfi) -> bool {
    ok, c := psi_profile_count(p, call, bfi);
    if ok return psi_is_cold_count(p, c);
    if !psi_has_sample_profile(p) return false;
    // Function::hasProfileData()
    ok2, _ := function_entry_count(inst_fn(call));
    return ok2;
}

// ProfileSummaryInfo::getTotalCallCount<Function>: sample profiles only
psi_total_call_count :: (p: *Psi, f: Value_Id) -> (bool, u64) {
    if !psi_has_sample_profile(p) return false, 0;
    total: u64 = 0;
    for bb: fn_blocks(f) for i: block_insts(bb) {
        o := inst_op(i);
        if o != .CALL && o != .INVOKE continue;
        ok, c := psi_profile_count(p, i, null);
        if ok total += c;
    }
    return true, total;
}
// isFunctionHotInCallGraph(F, BFI)
psi_is_function_hot_in_call_graph :: (p: *Psi, f: Value_Id, bfi: *Bfi) -> bool {
    if f == NONE || !p.has_summary return false;
    ok, c := function_entry_count(f);
    if ok && psi_is_hot_count(p, c) return true;
    ok2, t := psi_total_call_count(p, f);
    if ok2 && psi_is_hot_count(p, t) return true;
    for bb: fn_blocks(f) { okb, cb := bfi_block_profile_count(bfi, bb); if okb && psi_is_hot_count(p, cb) return true; }
    return false;
}
// isFunctionColdInCallGraph(F, BFI)
psi_is_function_cold_in_call_graph :: (p: *Psi, f: Value_Id, bfi: *Bfi) -> bool {
    if f == NONE || !p.has_summary return false;
    ok, c := function_entry_count(f);
    if ok && !psi_is_cold_count(p, c) return false;
    ok2, t := psi_total_call_count(p, f);
    if ok2 && !psi_is_cold_count(p, t) return false;
    for bb: fn_blocks(f) { okb, cb := bfi_block_profile_count(bfi, bb); if !(okb && psi_is_cold_count(p, cb)) return false; }
    return true;
}

// What a function pass gets from `PSI = MAMProxy.getCachedResult<ProfileSummaryAnalysis>(M);
// BFI = (PSI && PSI->hasProfileSummary()) ? &AM.getResult<BlockFrequencyAnalysis>(F) : nullptr`
psi_pass_bfi :: (f: Value_Id) -> (*Psi, *Bfi) {
    p := psi_cached_or_null();
    if !p || !p.has_summary return p, null;
    return p, get_bfi(f);
}

// SizeOpts.h isPGSOColdCodeOnly
psi_is_pgso_cold_code_only :: (p: *Psi) -> bool {
    o := *psi_opts;
    return o.pgso_cold_code_only || (psi_has_instrumentation_profile(p) && o.pgso_cold_code_only_instr) ||
           (psi_has_sample_profile(p) && ((!psi_has_partial_sample_profile(p) && o.pgso_cold_code_only_sample) ||
                                          (psi_has_partial_sample_profile(p) && o.pgso_cold_code_only_partial_sample))) ||
           (o.pgso_lwss_only && !psi_has_large_working_set_size(p));
}
// shouldOptimizeForSize(BB, PSI, BFI): optsize, else shouldOptimizeForSizeImpl
should_optimize_for_size_bb :: (bb: Value_Id, p: *Psi, bfi: *Bfi) -> bool {
    if fn_has_opt_size(block_fn(bb)) return true;
    if !p || !bfi || !p.has_summary return false;
    if psi_opts.force_pgso return true;
    if !psi_opts.enable_pgso return false;
    ok, c := bfi_block_profile_count(bfi, bb);
    if psi_is_pgso_cold_code_only(p) return ok && psi_is_cold_count(p, c);
    if psi_has_sample_profile(p) return ok && psi_is_cold_count_nth_percentile(p, psi_opts.pgso_cutoff_sample, c);
    return !(ok && psi_is_hot_count_nth_percentile(p, psi_opts.pgso_cutoff_instr, c));
}
