// ProfileSummaryInfo: port of llvm/lib/Analysis/ProfileSummaryInfo.cpp (+ include/llvm/Analysis/ProfileSummaryInfo.h),
// ProfileSummary::getFromMD (llvm/lib/IR/ProfileSummary.cpp), ProfileSummaryBuilder::getEntryForPercentile /
// getHotCountThreshold / getColdCountThreshold (llvm/lib/ProfileData/ProfileSummaryBuilder.cpp), the block query of
// shouldOptimizeForSize (llvm/lib/Transforms/Utils/SizeOpts.cpp, SizeOpts.h), BlockFrequencyInfo's
// getBlockProfileCount / getProfileCountFromFreq (BlockFrequencyInfoImpl.cpp), extractProfTotalWeight
// (ProfDataUtils.cpp).
//
// ProfileSummaryAnalysis is a module analysis that is never invalidated. `psi_valid` says whether the result is
// cached (what getCachedResult<ProfileSummaryAnalysis> sees): require<profile-summary> and always-inline
// (MAM.getResult) compute it. The summary is read once per module.
import std;
import ir;
import irutil;
import instinfo;
import gen_attrs;
import flags;
import apint;
import bfi;
import tli;

var psi_valid: bool = false;       // the module analysis result is cached
var psi_module: i32 = -1;
var psi_has_summary: bool = false;
var psi_kind: i64 = 0;             // 0 sample, 1 instr, 2 cs-instr
var psi_is_partial: bool = false;
var psi_partial_ratio: f64 = 0.0;
struct PsiEntry { cutoff: u64, min_count: u64, num_counts: u64 }
var psi_detailed: PsiEntry[>..];
var psi_has_hot: bool = false;
var psi_hot: u64 = 0;
var psi_has_cold: bool = false;
var psi_cold: u64 = 0;
var psi_huge: bool = false;
var psi_large: bool = false;

let PSI_SAMPLE: i64 = 0;
let PSI_INSTR: i64 = 1;
let PSI_CS_INSTR: i64 = 2;

fn psi_invalidate() { psi_valid = false; }

// Module::getModuleFlag(Key)
fn psi_module_flag(m: i32, key: const u8[:]) -> i32 {
    for &nm in named_mds {
        if nm.module != m || sbytes(nm.name) != "llvm.module.flags" { continue; }
        for i in nm.nops {
            let e = md_ops[nm.ops + i];
            if e < 0 || mds[e].kind != MK_TUPLE || mds[e].nops < 3 { continue; }
            let kk = md_op(e, 1);
            if kk < 0 || mds[kk].kind != MK_STRING || sbytes(mds[kk].extra) != key { continue; }
            return md_op(e, 2);
        }
    }
    return -1;
}

fn psi_is_tuple(m: i32, n: i64) -> bool { m >= 0 && mds[m].kind == MK_TUPLE && (mds[m].nops as i64) == n }
// getValMD
fn psi_val_md(m: i32, key: const u8[:]) -> i32 {
    if !psi_is_tuple(m, 2) { return -1; }
    let k = md_op(m, 0);
    let v = md_op(m, 1);
    if k < 0 || mds[k].kind != MK_STRING || v < 0 || mds[v].kind != MK_VALUE { return -1; }
    if sbytes(mds[k].extra) != key { return -1; }
    return mds[v].extra;
}
fn psi_get_val(m: i32, key: const u8[:]) -> bool, u64 {
    let v = psi_val_md(m, key);
    if v < 0 { return false, 0; }
    if vals[v].kind != VK_CINT { fatal("ProfileSummary: a summary field is not a ConstantInt"); }
    return true, cint_lo(v);
}
fn psi_is_key_value_pair(m: i32, key: const u8[:], val: const u8[:]) -> bool {
    if !psi_is_tuple(m, 2) { return false; }
    let k = md_op(m, 0);
    let v = md_op(m, 1);
    if k < 0 || mds[k].kind != MK_STRING || v < 0 || mds[v].kind != MK_STRING { return false; }
    return sbytes(mds[k].extra) == key && sbytes(mds[v].extra) == val;
}

// ProfileSummary::getFromMD
fn psi_from_md(m: i32) -> bool {
    if m < 0 || mds[m].kind != MK_TUPLE { return false; }
    let n = mds[m].nops as i64;
    if n < 8 || n > 10 { return false; }
    var i: i64 = 0;
    let fm = md_op(m, i);
    i++;
    if psi_is_key_value_pair(fm, "ProfileFormat", "SampleProfile") { psi_kind = PSI_SAMPLE; }
    else if psi_is_key_value_pair(fm, "ProfileFormat", "InstrProf") { psi_kind = PSI_INSTR; }
    else if psi_is_key_value_pair(fm, "ProfileFormat", "CSInstrProf") { psi_kind = PSI_CS_INSTR; }
    else { return false; }
    for key in ["TotalCount", "MaxCount", "MaxInternalCount", "MaxFunctionCount", "NumCounts", "NumFunctions"] {
        let ok, x = psi_get_val(md_op(m, i), key);
        i++;
        if !ok { return false; }
    }
    let okp, ipp = psi_get_val(md_op(m, i), "IsPartialProfile");
    if okp { i++; if i >= n { return false; } }
    psi_is_partial = okp && ipp != 0;
    psi_partial_ratio = 0.0;
    let rv = psi_val_md(md_op(m, i), "PartialProfileRatio");
    if rv >= 0 {
        if vals[rv].kind != VK_CFP { fatal("ProfileSummary: PartialProfileRatio is not a double"); }
        psi_partial_ratio = cfp_to_f64(rv);
        i++;
        if i >= n { return false; }
    }
    let d = md_op(m, i);
    if !psi_is_tuple(d, 2) { return false; }
    let k = md_op(d, 0);
    if k < 0 || mds[k].kind != MK_STRING || sbytes(mds[k].extra) != "DetailedSummary" { return false; }
    let es = md_op(d, 1);
    if es < 0 || mds[es].kind != MK_TUPLE { return false; }
    psi_detailed.resize(0);
    for j in mds[es].nops {
        let e = md_op(es, j);
        if !psi_is_tuple(e, 3) { return false; }
        var xs: u64[3] = [0, 0, 0];
        for q in 3 {
            let o = md_op(e, q);
            if o < 0 || mds[o].kind != MK_VALUE || vals[mds[o].extra].kind != VK_CINT { return false; }
            xs[q] = cint_lo(mds[o].extra);
        }
        psi_detailed.push(PsiEntry { cutoff: xs[0], min_count: xs[1], num_counts: xs[2] });
    }
    return true;
}

// ProfileSummaryBuilder::getEntryForPercentile
fn psi_entry_for_percentile(pct: u64) -> PsiEntry {
    if pct == 0 { return PsiEntry { cutoff: 0, min_count: 0xFFFFFFFFFFFFFFFF, num_counts: 0 }; }
    for e in psi_detailed { if e.cutoff >= pct { return e; } }
    fatal("Desired percentile exceeds the maximum cutoff");
    return psi_detailed[0];
}

fn psi_flag_u64(name: const u8[:], dflt: u64) -> u64 { flag_int(name, dflt as i64) as u64 }

// ProfileSummaryInfo(M): refresh() + computeThresholds()
fn psi_compute(m: i32) {
    psi_module = m;
    psi_has_summary = psi_from_md(psi_module_flag(m, "CSProfileSummary"));
    if !psi_has_summary { psi_has_summary = psi_from_md(psi_module_flag(m, "ProfileSummary")); }
    psi_has_hot = false;
    psi_has_cold = false;
    psi_huge = false;
    psi_large = false;
    if !psi_has_summary { return; }
    let hot_entry = psi_entry_for_percentile(psi_flag_u64("profile-summary-cutoff-hot", 990000));
    psi_has_hot = true;
    psi_hot = hot_entry.min_count;
    if flag_str("profile-summary-hot-count").len > 0 { psi_hot = psi_flag_u64("profile-summary-hot-count", 0); }
    psi_has_cold = true;
    psi_cold = psi_entry_for_percentile(psi_flag_u64("profile-summary-cutoff-cold", 999999)).min_count;
    if flag_str("profile-summary-cold-count").len > 0 { psi_cold = psi_flag_u64("profile-summary-cold-count", 0); }
    if psi_hot == psi_cold {
        if psi_cold > 0 { psi_cold -= 1; } else { psi_hot += 1; }
    }
    let huge_t = psi_flag_u64("profile-summary-huge-working-set-size-threshold", 15000);
    let large_t = psi_flag_u64("profile-summary-large-working-set-size-threshold", 12500);
    if !psi_has_partial_sample_profile() || !flag_bool("scale-partial-sample-profile-working-set-size", true) {
        psi_huge = hot_entry.num_counts > huge_t;
        psi_large = hot_entry.num_counts > large_t;
    } else {
        if flag_str("partial-sample-profile-working-set-size-scale-factor").len > 0 {
            fatal("opt: -partial-sample-profile-working-set-size-scale-factor is not supported yet in the Goose opt");
        }
        let scaled = ((hot_entry.num_counts as f64) * psi_partial_ratio * 0.008) as u64;
        psi_huge = scaled > huge_t;
        psi_large = scaled > large_t;
    }
}

// AM.getResult<ProfileSummaryAnalysis>(M)
fn psi_get(m: i32) {
    if psi_module != m { psi_compute(m); }
    psi_valid = true;
}
// AM.getCachedResult<ProfileSummaryAnalysis>(M) != nullptr
fn psi_cached() -> bool { psi_valid }

fn psi_has_sample_profile() -> bool { psi_has_summary && psi_kind == PSI_SAMPLE }
fn psi_has_instrumentation_profile() -> bool { psi_has_summary && psi_kind == PSI_INSTR }
fn psi_has_partial_sample_profile() -> bool {
    psi_has_summary && psi_kind == PSI_SAMPLE && (flag_bool("partial-profile", false) || psi_is_partial)
}
fn psi_is_hot_count(c: u64) -> bool { psi_has_hot && c >= psi_hot }
fn psi_is_cold_count(c: u64) -> bool { psi_has_cold && c <= psi_cold }
fn psi_hot_count_threshold_or_max() -> u64 { if psi_has_hot { psi_hot } else { 0xFFFFFFFFFFFFFFFF } }
// computeThreshold(PercentileCutoff)
fn psi_compute_threshold(cutoff: i64) -> bool, u64 {
    if !psi_has_summary { return false, 0; }
    return true, psi_entry_for_percentile(cutoff as u64).min_count;
}

// Function::getEntryCount (AllowSynthetic = false)
fn fn_entry_count(f: i32) -> bool, u64 { let a, b = bf_entry_count(f); return a, b; }

// isFunctionEntryHot / isFunctionEntryCold
fn psi_is_function_entry_hot(f: i32) -> bool {
    if f < 0 || !psi_has_summary { return false; }
    let ok, c = fn_entry_count(f);
    return ok && psi_is_hot_count(c);
}
fn psi_is_function_entry_cold(f: i32) -> bool {
    if f < 0 { return false; }
    if aset_has(alist_fn(globs[glob_of(f)].attrs), AK_Cold) { return true; }
    if !psi_has_summary { return false; }
    let ok, c = fn_entry_count(f);
    return ok && psi_is_cold_count(c);
}

// BlockFrequencyInfo::getBlockProfileCount(BB) for the BFI of bb's function (computed on demand)
fn bfi_block_profile_count(bb: i32) -> bool, u64 {
    let f = block_func(bb);
    bfi_get(f);
    let ok, ec = fn_entry_count(f);
    if !ok { return false, 0; }
    let bc = ap_mul(ap_u64(ec, 128), ap_u64(bfi_freq(bb), 128));
    let ef = ap_u64(bfi_freq(func_entry(f)), 128);
    let r = ap_udiv(ap_add(bc, ap_lshr(ef, 1)), ef);
    return true, ap_limited(r, 0xFFFFFFFFFFFFFFFF);
}

// extractProfTotalWeight
fn prof_extract_total_weight(i: i32) -> bool, u64 {
    let m = inst_get_md(i, md_kind_id("prof"));
    if m < 0 || mds[m].nops == 0 { return false, 0; }
    let s = md_op(m, 0);
    if s < 0 || mds[s].kind != MK_STRING { return false, 0; }
    let tag = sbytes(mds[s].extra);
    if tag == "branch_weights" {
        var total: u64 = 0;
        var off: i64 = 1;
        if mds[m].nops > 1 {
            let o = md_op(m, 1);
            if o >= 0 && mds[o].kind == MK_STRING && sbytes(mds[o].extra) == "expected" { off = 2; }
        }
        for k in off..(mds[m].nops as i64) {
            let c = md_op(m, k);
            total += cint_lo(mds[c].extra);
        }
        return true, total;
    }
    if tag == "VP" && mds[m].nops > 3 { return true, cint_lo(mds[md_op(m, 2)].extra); }
    return false, 0;
}

// getProfileCount(CallBase, BFI); has_bfi = a BFI was passed
fn psi_profile_count(call: i32, has_bfi: bool) -> bool, u64 {
    if psi_has_sample_profile() { return prof_extract_total_weight(call); }
    if has_bfi { return bfi_block_profile_count(inst_parent(call)); }
    return false, 0;
}
fn psi_is_hot_call_site(call: i32, has_bfi: bool) -> bool {
    let ok, c = psi_profile_count(call, has_bfi);
    return ok && psi_is_hot_count(c);
}
fn psi_is_cold_call_site(call: i32, has_bfi: bool) -> bool {
    let ok, c = psi_profile_count(call, has_bfi);
    if ok { return psi_is_cold_count(c); }
    if !psi_has_sample_profile() { return false; }
    return fn_has_profile_data(inst_func(call));
}
// Function::hasProfileData(): an entry count (synthetic too), not -1
fn fn_has_profile_data(f: i32) -> bool {
    let g = glob_of(f);
    let k = md_kind_id("prof");
    for j in globs[g].nmd {
        if md_att[globs[g].md + 2 * j] != k { continue; }
        let m = md_att[globs[g].md + 2 * j + 1];
        if mds[m].nops < 2 { return false; }
        let s = md_op(m, 0);
        if s < 0 || mds[s].kind != MK_STRING { return false; }
        let t = sbytes(mds[s].extra);
        if t != "function_entry_count" && t != "synthetic_function_entry_count" { return false; }
        let o = md_op(m, 1);
        if o < 0 || mds[o].kind != MK_VALUE { return false; }
        return cint_lo(mds[o].extra) != 0xFFFFFFFFFFFFFFFF;
    }
    return false;
}

// SizeOpts.h isPGSOColdCodeOnly
fn psi_is_pgso_cold_code_only() -> bool {
    return flag_bool("pgso-cold-code-only", false) ||
        (psi_has_instrumentation_profile() && flag_bool("pgso-cold-code-only-for-instr-pgo", false)) ||
        (psi_has_sample_profile() && ((!psi_has_partial_sample_profile() && flag_bool("pgso-cold-code-only-for-sample-pgo", false)) ||
                                       (psi_has_partial_sample_profile() && flag_bool("pgso-cold-code-only-for-partial-sample-pgo", false)))) ||
        (flag_bool("pgso-lwss-only", true) && !psi_large);
}
// shouldOptimizeForSize(BB, PSI, BFI, QueryType): optsize, else shouldOptimizeForSizeImpl (with_psi: a PSI exists)
fn should_optimize_for_size_bb(bb: i32, with_psi: bool, with_bfi: bool) -> bool {
    let f = block_func(bb);
    let s = alist_fn(globs[glob_of(f)].attrs);
    if aset_has(s, AK_OptimizeForSize) || aset_has(s, AK_MinSize) { return true; }
    if !with_psi || !with_bfi || !psi_has_summary { return false; }
    if flag_bool("force-pgso", false) { return true; }
    if !flag_bool("pgso", true) { return false; }
    let ok, c = bfi_block_profile_count(bb);
    if psi_is_pgso_cold_code_only() { return ok && psi_is_cold_count(c); }
    if psi_has_sample_profile() {
        let tok, t = psi_compute_threshold(flag_int("pgso-cutoff-sample-prof", 990000));
        return ok && tok && c <= t;
    }
    let tok, t = psi_compute_threshold(flag_int("pgso-cutoff-instr-prof", 950000));
    return !(ok && tok && c >= t);
}
