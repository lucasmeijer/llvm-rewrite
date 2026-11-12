// Alias analysis: the AAResults aggregation (llvm/lib/Analysis/AliasAnalysis.cpp), AAQueryInfo with its alias
// cache and assumption tracking, the capture analyses (SimpleCaptureAnalysis, EarliestEscapeAnalysis) and
// BasicAA (llvm/lib/Analysis/BasicAliasAnalysis.cpp: aliasCheck, aliasGEP with DecomposeGEPExpression and
// GetLinearExpression, aliasPHI, aliasSelect, getModRefInfo, getModRefInfoMask, getMemoryEffects), plus the
// MemoryBuiltins.cpp parts BasicAA uses (getBaseObjectSize, isMallocOrCallocLikeFn).
//
// Everything is in one file because the aggregator and BasicAA are mutually recursive (AAQI.AAR.alias).
// Recursion rules (DESIGN.md §1): the recursive functions keep no growable locals; decomposed GEP indices live
// on the global stack bas_vars, aliasPHI's sources on bas_srcs, both truncated back to a mark.
//
// API for passes (see DESIGN.md §8.6):
//   aa_begin(fv)                      AM.getResult<AAManager>(F): sets the function, TLI, computes the DT
//   q = aq_push(CA_SIMPLE) / aq_pop(q) an AAQueryInfo (BatchAAResults) with its own cache
//   aa_alias(a, b, q, cxt)            AAResults::alias(LocA, LocB, AAQI, CtxI)
//   aa_inst_loc_mr(i, loc, q)         getModRefInfo(I, OptLoc, AAQI)   (loc.ptr == ML_NONE: std::nullopt)
//   aa_inst_call_mr / aa_inst_inst_mr / aa_call_call_mr / aa_call_loc_mr / aa_mod_ref_mask / aa_call_me
//   aa_alias_simple(a, b) etc.        the AAResults entry points that make a fresh SimpleAAQueryInfo
import std;
import scevaa;
import scev;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import gen_tli;
import datalayout;
import domtree;
import tli;
import pm;
import knownbits;
import crange;
import vt;
import flags;
import memloc;
import aautil;
import capture;
import tbaa;
import globalsaa;
import assume;

// ---------------------------------------------------------------------------------------------
// AliasResult

let AR_NO = 0;
let AR_MAY = 1;
let AR_PARTIAL = 2;
let AR_MUST = 3;

struct AR { k: u8, has_off: bool, off: i32 }

fn ar(k: i64) -> AR { AR { k: k as u8, has_off: false, off: 0 } }
fn ar_k(r: AR) -> i64 { r.k as i64 }
// AliasResult::setOffset (only if it fits in 23 signed bits)
fn ar_set_offset(r: AR, off: i64) -> AR {
    if off >= -4194304 && off < 4194304 { return AR { k: r.k, has_off: true, off: off as i32 }; }
    return r;
}
fn ar_swap(r: AR, do_swap: bool) -> AR {
    if do_swap && r.has_off { return ar_set_offset(r, -(r.off as i64)); }
    return r;
}
fn ar_format(out: u8[>..]&, r: AR) {
    let k = r.k as i64;
    if k == AR_NO { out.append("NoAlias"); }
    else if k == AR_MUST { out.append("MustAlias"); }
    else if k == AR_MAY { out.append("MayAlias"); }
    else {
        out.append("PartialAlias");
        if r.has_off { out.append(" (off "); format(out, r.off); out.push(')'); }
    }
}

// ---------------------------------------------------------------------------------------------
// The AA pipeline (-aa-pipeline): AAManager's registered results in priority order.

let AAK_BASIC = 0;
let AAK_SCOPED = 1;
let AAK_TBAA = 2;
let AAK_GLOBALS = 3;
let AAK_SCEV = 4;

var aa_kinds: i32[>..];
var aa_pipeline_done: bool = false;
var aa_cur_fn: i32 = -1;

fn aa_pipeline_init() {
    if aa_pipeline_done { return; }
    aa_pipeline_done = true;
    var text: u8[>..] = [];
    text.append("default");
    for f in cl_flags { if sbytes(f.name) == "aa-pipeline" { text.clear(); text.append(sbytes(f.value)); } }
    tbaa_flag_enabled = flag_bool("enable-tbaa", true);
    sna_flag_enabled = flag_bool("enable-scoped-noalias", true);
    if text == "default" {
        aa_kinds.push(AAK_BASIC as i32);
        aa_kinds.push(AAK_SCOPED as i32);
        aa_kinds.push(AAK_TBAA as i32);
        aa_kinds.push(AAK_GLOBALS as i32);
        return;
    }
    var st: i64 = 0;
    for i in 0..text.len + 1 {
        if i < text.len && text[i] != ',' { continue; }
        let nm = text[st..i];
        st = i + 1;
        if nm == "basic-aa" { aa_kinds.push(AAK_BASIC as i32); }
        else if nm == "scoped-noalias-aa" { aa_kinds.push(AAK_SCOPED as i32); }
        else if nm == "tbaa" { aa_kinds.push(AAK_TBAA as i32); }
        else if nm == "globals-aa" { aa_kinds.push(AAK_GLOBALS as i32); }
        else if nm == "scev-aa" { aa_kinds.push(AAK_SCEV as i32); }
        else if nm == "objc-arc-aa" { fatal(str("opt: alias analysis '", nm, "' is not implemented yet in the Goose opt")); }
        else { fatal(str("opt: unknown alias analysis name '", nm, "'")); }
    }
}

fn aa_kind_active(k: i64) -> bool {
    // GlobalsAA is a module analysis: the AAManager uses it only when it is cached
    if k == AAK_GLOBALS { return gm_valid; }
    return true;
}

// AM.getResult<AAManager>(F): BasicAA needs TLI, the AssumptionCache and the DominatorTree.
fn aa_begin(fv: i32) {
    aa_pipeline_init();
    aa_cur_fn = fv;
    tli_cur_fn = fv;
    dt_get(fv, DT_DOM);
    bas_check_separate_storage(fv);
}

// ---------------------------------------------------------------------------------------------
// AAQueryInfo. A stack of query infos (SimpleAAQueryInfo / BatchAAResults); each has its own cache region in
// the shared chained hash table aent/abuck (entries of a query info are appended after its mark and removed
// when it is popped).

let CA_SIMPLE = 0;
let CA_EARLIEST = 1;

struct AQ { depth: i32, nau: i32, abr_base: i32, ent_mark: i32, cross: bool, use_dt: bool, ca: u8 }
var aqs: AQ[>..<];

let AEK_ALIAS: u8 = 0;
let AEK_CAPTURE: u8 = 1;       // SimpleCaptureAnalysis::IsCapturedCache

struct AE { q: i32, kind: u8, alive: bool, cross: bool, p1: i32, p2: i32, s1: u64, s2: u64, res: AR, nau: i32,
            next: i32, c1: i64, c2: i64, inst: i32 }
var aent: AE[>..<];
var abuck: i32[>..];
var aq_abr: i32[>..<];          // AssumptionBasedResults (entry indices; erased by key, like LLVM)

let AE_DEFINITIVE: i32 = -2;
let AE_ASSUMPTION_BASED: i32 = -1;

fn aq_push(ca: i64) -> i32 {
    let q = aqs.len as i32;
    aqs.push(AQ { depth: 0, nau: 0, abr_base: aq_abr.len as i32, ent_mark: aent.len as i32, cross: false, use_dt: true, ca: ca as u8 });
    return q;
}

fn aq_pop(q: i32) {
    if (q as i64) != aqs.len - 1 { fatal("internal: AAQueryInfo popped out of order"); }
    let mark = aqs[q].ent_mark as i64;
    var i = aent.len - 1;
    while i >= mark {
        if aent[i].alive { ae_unlink(i as i32); }
        i--;
    }
    aent.resize(mark);
    aq_abr.resize(aqs[q].abr_base as i64);
    aqs.pop();
}
fn aq_set_cross(q: i32, c: bool) { aqs[q].cross = c; }
fn aq_disable_dt(q: i32) { aqs[q].use_dt = false; }

fn ae_hash(q: i32, kind: u8, p1: i32, s1: u64, p2: i32, s2: u64, cross: bool) -> u64 {
    var h: u64 = 0xcbf29ce484222325;
    fn mix(x: u64) { h = (h ^ x) * 0x100000001b3; h = h ^ (h >> 29); }
    mix(q as! u64);
    mix(kind as u64);
    mix(p1 as! u64);
    mix(s1);
    mix(p2 as! u64);
    mix(s2);
    mix(if cross { 1 } else { 0 });
    return h;
}
fn ae_bucket(e: AE) -> i64 {
    let h = ae_hash(e.q, e.kind, e.p1, e.s1, e.p2, e.s2, e.cross);
    return (h & ((abuck.len - 1) as u64)) as i64;
}
fn ae_rehash() {
    var n = abuck.len * 2;
    if n < 64 { n = 64; }
    abuck.resize(n, -1);
    for k in n { abuck[k] = -1; }
    for i in aent.len {
        if !aent[i].alive { continue; }
        let b = ae_bucket(aent[i]);
        aent[i].next = abuck[b];
        abuck[b] = i as i32;
    }
}
fn ae_find(q: i32, kind: u8, p1: i32, s1: u64, p2: i32, s2: u64, cross: bool) -> i32 {
    if abuck.len == 0 { return -1; }
    let b = (ae_hash(q, kind, p1, s1, p2, s2, cross) & ((abuck.len - 1) as u64)) as i64;
    var i = abuck[b];
    while i >= 0 {
        let e = aent[i];
        if e.q == q && e.kind == kind && e.p1 == p1 && e.s1 == s1 && e.p2 == p2 && e.s2 == s2 && e.cross == cross { return i; }
        i = e.next;
    }
    return -1;
}
fn ae_insert(q: i32, kind: u8, p1: i32, s1: u64, p2: i32, s2: u64, cross: bool) -> i32 {
    if (aent.len + 1) * 2 > abuck.len { ae_rehash(); }
    let i = aent.len as i32;
    aent.push(AE { q: q, kind: kind, alive: true, cross: cross, p1: p1, p2: p2, s1: s1, s2: s2, res: ar(AR_NO), nau: 0,
                   next: -1, c1: 0, c2: 0, inst: -1 });
    let b = ae_bucket(aent[i]);
    aent[i].next = abuck[b];
    abuck[b] = i;
    return i;
}
fn ae_unlink(i: i32) {
    let b = ae_bucket(aent[i]);
    if abuck[b] == i { abuck[b] = aent[i].next; }
    else {
        var j = abuck[b];
        while j >= 0 && aent[j].next != i { j = aent[j].next; }
        if j >= 0 { aent[j].next = aent[i].next; }
    }
    aent[i].alive = false;
}
// AliasCache.erase(Locs) for the key of entry i
fn ae_erase_key_of(i: i32) {
    let e = aent[i];
    let j = ae_find(e.q, e.kind, e.p1, e.s1, e.p2, e.s2, e.cross);
    if j >= 0 { ae_unlink(j); }
}

// ---------------------------------------------------------------------------------------------
// Identified objects (AliasAnalysis.cpp)

fn aa_is_base_of_object(v: i32) -> bool { is_inst_op(v, OP_ALLOCA) || vals[v].kind == VK_GVAR }

fn aa_is_escape_source(v: i32) -> bool {
    if is_callbase(v) {
        if ct_intrinsic_returns_aliasing_arg(v, false) { return false; }
        return !cb_has_arg_with_extra_ret_captures(v);
    }
    if is_inst_op(v, OP_LOAD) || is_inst_op(v, OP_INTTOPTR) { return true; }
    if is_inst_op(v, OP_EXTRACTVALUE) || is_inst_op(v, OP_EXTRACTELEMENT) { return true; }
    if vals[v].kind == VK_CEXPR && csts[vals[v].sub].op as i64 == OP_INTTOPTR { return true; }
    return false;
}

// isNotVisibleOnUnwind: (result, RequiresNoCaptureBeforeUnwind)
fn aa_is_not_visible_on_unwind(obj: i32) -> bool, bool {
    if is_inst_op(obj, OP_ALLOCA) { return true, false; }
    if is_arg(obj) { return ml_arg_has(obj, AK_ByVal) || ml_arg_has(obj, AK_DeadOnUnwind), false; }
    if aa_is_noalias_call(obj) { return true, true; }
    return false, false;
}

// isWritableObject: (result, ExplicitlyDereferenceableOnly)
fn aa_is_writable_object(obj: i32) -> bool, bool {
    if is_inst_op(obj, OP_ALLOCA) { return true, false; }
    if is_arg(obj) {
        if ml_arg_has(obj, AK_Writable) && aa_arg_noalias(obj) { return true, true; }
        return ml_arg_has(obj, AK_ByVal), false;
    }
    return aa_is_noalias_call(obj), false;
}

// ---------------------------------------------------------------------------------------------
// Capture analyses (CaptureAnalysis::getCapturesBefore), cached per query info

fn aq_captures_before(q: i32, obj: i32, i: i32, or_at: bool, return_captures: bool) -> i64 {
    if !aa_is_identified_function_local(obj) { return CC_PROVENANCE; }
    if aqs[q].ca == CA_SIMPLE as u8 {
        var e = ae_find(q, AEK_CAPTURE, obj, 0, -1, 0, false);
        if e < 0 {
            let wo, wr = ct_pointer_may_be_captured(obj, CC_PROVENANCE, CT_STOP_FULL_PROV, 0);
            e = ae_insert(q, AEK_CAPTURE, obj, 0, -1, 0, false);
            aent[e].c1 = wo;
            aent[e].c2 = wr;
        }
        return if return_captures { aent[e].c2 } else { aent[e].c1 };
    }
    // EarliestEscapeAnalysis (one instance: ea_*)
    if !ea_has(obj) {
        let ei, wo, wr = ct_find_earliest_capture(obj, aa_cur_fn, CC_PROVENANCE);
        ea_put(obj, ei, wo, wr);
    }
    if return_captures {
        if i >= 0 { fatal("internal: context instruction not supported with ReturnCaptures"); }
        return ea_with_ret[obj];
    }
    let ci = ea_inst[obj];
    var not_before = false;
    if ci < 0 { not_before = true; }
    else if i < 0 { not_before = false; }
    else if i == ci {
        not_before = if or_at { false } else { cfr_not_in_cycle(i, true, ea_use_li, ea_use_ci) };
    } else {
        not_before = !cfr_inst_reachable(ci, i, true, ea_use_li, ea_use_ci);
    }
    if not_before { return CC_NONE; }
    return ea_without_ret[obj];
}

// EarliestEscapeAnalysis: one instance at a time (DSE and MemCpyOpt keep one per function and hand it to
// their BatchAAResults). ea_begin(use_li, use_ci) = EarliestEscapeAnalysis(DT, LI, CI) (LoopInfo / CycleInfo
// must be computed); the cache (EarliestEscapes) is keyed by object value id with an epoch.
var ea_epoch: i32 = 0;
var ea_stamp: i32[>..];
var ea_inst: i32[>..];
var ea_without_ret: i64[>..];
var ea_with_ret: i64[>..];
var ea_objs: i32[>..<];
var ea_use_li: bool = false;
var ea_use_ci: bool = false;
fn ea_begin(use_li: bool, use_ci: bool) { ea_epoch++; ea_objs.clear(); ea_use_li = use_li; ea_use_ci = use_ci; }
fn ea_has(obj: i32) -> bool { (obj as i64) < ea_stamp.len && ea_stamp[obj] == ea_epoch }
fn ea_put(obj: i32, i: i32, wo: i64, wr: i64) {
    while ea_stamp.len <= (obj as i64) { ea_stamp.push(0); ea_inst.push(-1); ea_without_ret.push(0); ea_with_ret.push(0); }
    ea_stamp[obj] = ea_epoch;
    ea_inst[obj] = i;
    ea_without_ret[obj] = wo;
    ea_with_ret[obj] = wr;
    ea_objs.push(obj);
}
// EarliestEscapeAnalysis::removeInstruction: forget the objects whose earliest capture was I
fn ea_remove_instruction(iv: i32) {
    for o in ea_objs { if ea_has(o) && ea_inst[o] == iv { ea_stamp[o] = 0; } }
}

// ---------------------------------------------------------------------------------------------
// The aggregation (AAResults)

recursive fn aa_alias(a: ML, b: ML, q: i32, cxt: i32) -> AR {
    var r = ar(AR_MAY);
    aqs[q].depth += 1;
    var i: i64 = 0;
    while i < aa_kinds.len {
        let k = aa_kinds[i] as i64;
        i++;
        if !aa_kind_active(k) { continue; }
        if k == AAK_BASIC { r = bas_alias_check(a.ptr, a.size, b.ptr, b.size, q, cxt); }
        else if k == AAK_SCOPED { r = if sna_alias_may(a, b) { ar(AR_MAY) } else { ar(AR_NO) }; }
        else if k == AAK_TBAA { r = if tbaa_alias_may(aa_cur_fn, a, b) { ar(AR_MAY) } else { ar(AR_NO) }; }
        else if k == AAK_GLOBALS { r = if gm_alias_may(a, b, cxt) { ar(AR_MAY) } else { ar(AR_NO) }; }
        else if k == AAK_SCEV {
            // SCEVAA::run: AM.getResult<ScalarEvolutionAnalysis>(F)
            scev_get(aa_cur_fn);
            let x = scaa_alias(a, b);
            r = if x == 0 { ar(AR_NO) } else if x == 3 { ar(AR_MUST) } else { ar(AR_MAY) };
        }
        if r.k != AR_MAY as u8 { break; }
    }
    aqs[q].depth -= 1;
    return r;
}

// AAResults::aliasErrno: true = MayAlias
fn aa_alias_errno_may(loc: ML) -> bool {
    let m = globs[glob_of(aa_cur_fn)].module;
    var i: i64 = 0;
    while i < aa_kinds.len {
        let k = aa_kinds[i] as i64;
        i++;
        if !aa_kind_active(k) { continue; }
        var may = true;
        if k == AAK_BASIC { may = bas_alias_errno_may(loc); }
        else if k == AAK_TBAA { may = tbaa_alias_errno_may(aa_cur_fn, loc, m); }
        if !may { return false; }
    }
    return true;
}

fn aa_mod_ref_mask(loc: ML, q: i32, ignore_locals: bool) -> i64 {
    var r = MR_MODREF;
    var i: i64 = 0;
    while i < aa_kinds.len {
        let k = aa_kinds[i] as i64;
        i++;
        if !aa_kind_active(k) { continue; }
        if k == AAK_BASIC { r &= bas_mod_ref_mask(loc, ignore_locals); }
        else if k == AAK_TBAA { r &= tbaa_mod_ref_mask(aa_cur_fn, loc); }
        if r == MR_NO { return MR_NO; }
    }
    return r;
}

fn aa_arg_mod_ref(c: i32, k0: i64) -> i64 {
    var r = MR_MODREF;
    var i: i64 = 0;
    while i < aa_kinds.len {
        let k = aa_kinds[i] as i64;
        i++;
        if !aa_kind_active(k) { continue; }
        if k == AAK_BASIC { r &= bas_arg_mod_ref(c, k0); }
        if r == MR_NO { return MR_NO; }
    }
    return r;
}

fn aa_fn_me(f: i32) -> u64 {
    var r = me_of(MR_MODREF);
    var i: i64 = 0;
    while i < aa_kinds.len {
        let k = aa_kinds[i] as i64;
        i++;
        if !aa_kind_active(k) { continue; }
        if k == AAK_BASIC { r &= bas_fn_me(f); }
        else if k == AAK_GLOBALS { r &= gm_fn_me(f); }
        if r == 0 { return r; }
    }
    return r;
}

fn aa_call_me(c: i32, q: i32) -> u64 {
    var r = me_of(MR_MODREF);
    var i: i64 = 0;
    while i < aa_kinds.len {
        let k = aa_kinds[i] as i64;
        i++;
        if !aa_kind_active(k) { continue; }
        if k == AAK_BASIC { r &= bas_call_me(c, q); }
        else if k == AAK_TBAA { r &= tbaa_call_memory_effects(aa_cur_fn, c); }
        if r == 0 { return r; }
    }
    return r;
}

// getModRefInfo(const CallBase *Call, const MemoryLocation &Loc, AAQueryInfo &AAQI)
recursive fn aa_call_loc_mr(c: i32, loc: ML, q: i32) -> i64 {
    var r = MR_MODREF;
    var i: i64 = 0;
    while i < aa_kinds.len {
        let k = aa_kinds[i] as i64;
        i++;
        if !aa_kind_active(k) { continue; }
        if k == AAK_BASIC { r &= bas_call_loc_mr(c, loc, q); }
        else if k == AAK_SCOPED { r &= sna_call_mod_ref(c, loc); }
        else if k == AAK_TBAA { r &= tbaa_call_mod_ref(aa_cur_fn, c, loc); }
        else if k == AAK_GLOBALS { r &= gm_call_loc_mr(c, loc); }
        if r == MR_NO { return MR_NO; }
    }
    if r != MR_NO { r &= aa_mod_ref_mask(loc, q, false); }
    return r;
}

// getModRefInfoInaccessibleAndTargetMemLoc
fn aa_inaccessible_target_mr(use_me: u64, def_me: u64) -> i64 {
    var r = MR_NO;
    for loc in [LOC_INACCESSIBLE, LOC_TARGET0, LOC_TARGET1] {
        let um = me_get(use_me, loc);
        if um == MR_NO { continue; }
        let dm = me_get(def_me, loc);
        if dm == MR_NO { continue; }
        if dm == MR_REF && dm == um { continue; }
        r |= um;
    }
    return r;
}

// getModRefInfo(const CallBase *Call1, const CallBase *Call2, AAQueryInfo &AAQI)
recursive fn aa_call_call_mr(c1: i32, c2: i32, q: i32) -> i64 {
    var result = MR_MODREF;
    var i: i64 = 0;
    while i < aa_kinds.len {
        let k = aa_kinds[i] as i64;
        i++;
        if !aa_kind_active(k) { continue; }
        if k == AAK_BASIC { result &= bas_call_call_mr(c1, c2, q); }
        else if k == AAK_SCOPED { result &= sna_call_call_mod_ref(c1, c2); }
        else if k == AAK_TBAA { result &= tbaa_call_call_mod_ref(aa_cur_fn, c1, c2); }
        if result == MR_NO { return MR_NO; }
    }
    let b1 = aa_call_me(c1, q);
    if b1 == 0 { return MR_NO; }
    let b2 = aa_call_me(c2, q);
    if b2 == 0 { return MR_NO; }
    if !mr_is_mod(me_modref(b1)) && !mr_is_mod(me_modref(b2)) { return MR_NO; }
    if !mr_is_mod(me_modref(b1)) { result &= MR_REF; }
    else if !mr_is_ref(me_modref(b1)) { result &= MR_MOD; }
    if me_only_arg(b2) {
        if !me_does_access_arg(b2) { return MR_NO; }
        var r = MR_NO;
        let n = cb_nargs(c2);
        var k: i64 = 0;
        while k < n {
            let arg = cb_arg(c2, k);
            if ty_kind(vals[arg].ty) != TK_PTR { k++; continue; }
            let aloc = ml_for_argument(c2, k, true);
            let amr2 = aa_arg_mod_ref(c2, k);
            var mask = MR_NO;
            if mr_is_mod(amr2) { mask = MR_MODREF; } else if mr_is_ref(amr2) { mask = MR_MOD; }
            mask &= aa_call_loc_mr(c1, aloc, q);
            r = (r | mask) & result;
            if r == result { break; }
            k++;
        }
        return r;
    }
    if me_only_arg(b1) {
        if !me_does_access_arg(b1) { return MR_NO; }
        var r = MR_NO;
        let n = cb_nargs(c1);
        var k: i64 = 0;
        while k < n {
            let arg = cb_arg(c1, k);
            if ty_kind(vals[arg].ty) != TK_PTR { k++; continue; }
            let aloc = ml_for_argument(c1, k, true);
            let amr1 = aa_arg_mod_ref(c1, k);
            let mr2 = aa_call_loc_mr(c2, aloc, q);
            if (mr_is_mod(amr1) && mr_any(mr2)) || (mr_is_ref(amr1) && mr_is_mod(mr2)) { r = (r | amr1) & result; }
            if r == result { break; }
            k++;
        }
        return r;
    }
    if me_only_inaccessible_or_target(b1) && me_only_inaccessible_or_target(b2) { return aa_inaccessible_target_mr(b1, b2); }
    return result;
}

// getSyncEffects
fn aa_sync_effects(loc: ML, q: i32) -> i64 {
    if loc.ptr < 0 { return MR_MODREF; }
    let obj = get_underlying_object(loc.ptr, BAS_MAX_LOOKUP);
    let cc = aq_captures_before(q, obj, -1, true, true);
    if cc_nothing(cc) { return MR_NO; }
    let mr = if cc_read_provenance_only(cc) { MR_REF } else { MR_MODREF };
    return mr & aa_mod_ref_mask(loc, q, false);
}

recursive fn aa_load_mr(l: i32, loc: ML, q: i32) -> i64 {
    let o = insts[inst_of(l)].ord;
    if loc.ptr >= 0 {
        let r = aa_alias(ml_get(l), loc, q, l);
        if r.k == AR_NO as u8 {
            if ord_stronger_than_monotonic(o) { return aa_sync_effects(loc, q); }
            return MR_NO;
        }
    }
    if ord_stronger_than_unordered(o) { return MR_MODREF; }
    return MR_REF;
}

recursive fn aa_store_mr(s: i32, loc: ML, q: i32) -> i64 {
    let o = insts[inst_of(s)].ord;
    if loc.ptr >= 0 {
        let r = aa_alias(ml_get(s), loc, q, s);
        if r.k == AR_NO as u8 {
            if ord_stronger_than_monotonic(o) { return aa_sync_effects(loc, q); }
            return MR_NO;
        }
        if !mr_is_mod(aa_mod_ref_mask(loc, q, false)) { return MR_NO; }
    }
    if ord_stronger_than_unordered(o) { return MR_MODREF; }
    return MR_MOD;
}

fn aa_fence_mr(f: i32, loc: ML, q: i32) -> i64 {
    if loc.ptr >= 0 {
        var r = MR_MODREF;
        var i: i64 = 0;
        while i < aa_kinds.len {
            let k = aa_kinds[i] as i64;
            i++;
            if !aa_kind_active(k) { continue; }
            if k == AAK_SCOPED { r &= sna_call_mod_ref(f, loc); }
            if r == MR_NO { return MR_NO; }
        }
        return r & aa_sync_effects(loc, q);
    }
    return MR_MODREF;
}

recursive fn aa_vaarg_mr(v: i32, loc: ML, q: i32) -> i64 {
    if loc.ptr >= 0 {
        let r = aa_alias(ml_get(v), loc, q, v);
        if r.k == AR_NO as u8 { return MR_NO; }
        return aa_mod_ref_mask(loc, q, false);
    }
    return MR_MODREF;
}

fn aa_catch_mr(loc: ML, q: i32) -> i64 {
    if loc.ptr >= 0 { return aa_mod_ref_mask(loc, q, false); }
    return MR_MODREF;
}

recursive fn aa_cmpxchg_mr(x: i32, loc: ML, q: i32, success_ord: u8) -> i64 {
    if loc.ptr >= 0 {
        let r = aa_alias(ml_get(x), loc, q, x);
        if r.k == AR_NO as u8 {
            if ord_stronger_than_monotonic(success_ord) { return aa_sync_effects(loc, q); }
            return MR_NO;
        }
    }
    return MR_MODREF;
}

// getModRefInfo(const Instruction *I, const std::optional<MemoryLocation> &OptLoc, AAQueryInfo &AAQIP)
recursive fn aa_inst_loc_mr(iv: i32, loc0: ML, q: i32) -> i64 {
    let o = iop(iv);
    if loc0.ptr == ML_NONE && (o == OP_CALL || o == OP_INVOKE || o == OP_CALLBR) { return me_modref(aa_call_me(iv, q)); }
    var loc = loc0;
    if loc.ptr == ML_NONE { loc = ml_null(); }
    if o == OP_VAARG { return aa_vaarg_mr(iv, loc, q); }
    if o == OP_LOAD { return aa_load_mr(iv, loc, q); }
    if o == OP_STORE { return aa_store_mr(iv, loc, q); }
    if o == OP_FENCE { return aa_fence_mr(iv, loc, q); }
    if o == OP_CMPXCHG { return aa_cmpxchg_mr(iv, loc, q, insts[inst_of(iv)].ord); }
    if o == OP_ATOMICRMW { return aa_cmpxchg_mr(iv, loc, q, insts[inst_of(iv)].ord); }
    if o == OP_CALL || o == OP_CALLBR || o == OP_INVOKE { return aa_call_loc_mr(iv, loc, q); }
    if o == OP_CATCHPAD || o == OP_CATCHRET { return aa_catch_mr(loc, q); }
    return MR_NO;
}

// getModRefInfo(const Instruction *I, const CallBase *Call2, AAQueryInfo &AAQIP)
recursive fn aa_inst_call_mr(iv: i32, c2: i32, q: i32) -> i64 {
    if is_callbase(iv) { return aa_call_call_mr(iv, c2, q); }
    if inst_is_fence_like(iv) { return MR_MODREF; }
    let dl = ml_get(iv);
    let mr = aa_call_loc_mr(c2, dl, q);
    return if mr_any(mr) { MR_MODREF } else { MR_NO };
}

// getModRefInfo(const Instruction *I1, const Instruction *I2, AAQueryInfo &AAQI)
recursive fn aa_inst_inst_mr(i1: i32, i2: i32, q: i32) -> i64 {
    if !inst_may_read_or_write_memory(i1) || !inst_may_read_or_write_memory(i2) { return MR_NO; }
    if is_callbase(i2) { return aa_inst_call_mr(i1, i2, q); }
    let mr = aa_inst_loc_mr(i1, ml_get_or_none(i2), q);
    return if mr_any(mr) { MR_MODREF } else { MR_NO };
}

// callCapturesBefore(I, MemLoc, DT, AAQI)
fn aa_call_captures_before(iv: i32, loc: ML, q: i32) -> i64 {
    let obj = get_underlying_object(loc.ptr, BAS_MAX_LOOKUP);
    if !aa_is_identified_function_local(obj) { return MR_MODREF; }
    if !is_callbase(iv) || iv == obj { return MR_MODREF; }
    if cc_anything(ct_may_be_captured_before(obj, true, iv, true, CC_PROVENANCE, CT_STOP_ANY, false)) { return MR_MODREF; }
    var r = MR_NO;
    let n = cb_nargs(iv) + cb_bundle_ops(iv);
    for k in n {
        let a = op(iv, k);
        if ty_kind(vals[a].ty) != TK_PTR { continue; }
        let ci = cb_capture_info(iv, k);
        if cc_any_provenance(ci_other(ci)) { continue; }
        let res = aa_alias(ml_before_or_after(a), ml_before_or_after(obj), q, iv);
        if res.k == AR_NO as u8 { continue; }
        if cb_arg_no_memory(iv, k) { continue; }
        if cb_arg_only_reads(iv, k) { r = MR_REF; continue; }
        return MR_MODREF;
    }
    return r;
}

// Entry points with a fresh SimpleAAQueryInfo (AAResults::alias(LocA, LocB), getModRefInfo(I, OptLoc), ...)
fn aa_alias_simple(a: ML, b: ML) -> AR {
    let q = aq_push(CA_SIMPLE);
    let r = aa_alias(a, b, q, -1);
    aq_pop(q);
    return r;
}
fn aa_inst_loc_mr_simple(iv: i32, loc: ML) -> i64 {
    let q = aq_push(CA_SIMPLE);
    let r = aa_inst_loc_mr(iv, loc, q);
    aq_pop(q);
    return r;
}
fn aa_inst_inst_mr_simple(i1: i32, i2: i32) -> i64 {
    let q = aq_push(CA_SIMPLE);
    let r = aa_inst_inst_mr(i1, i2, q);
    aq_pop(q);
    return r;
}
fn aa_inst_call_mr_simple(i1: i32, c2: i32) -> i64 {
    let q = aq_push(CA_SIMPLE);
    let r = aa_inst_call_mr(i1, c2, q);
    aq_pop(q);
    return r;
}
fn aa_mod_ref_mask_simple(loc: ML, ignore_locals: bool) -> i64 {
    let q = aq_push(CA_SIMPLE);
    let r = aa_mod_ref_mask(loc, q, ignore_locals);
    aq_pop(q);
    return r;
}
fn aa_call_me_simple(c: i32) -> u64 {
    let q = aq_push(CA_SIMPLE);
    let r = aa_call_me(c, q);
    aq_pop(q);
    return r;
}
// pointsToConstantMemory(Loc, OrLocal)
fn aa_points_to_constant_memory(loc: ML, q: i32, or_local: bool) -> bool { aa_mod_ref_mask(loc, q, or_local) == MR_NO }

// ===========================================================================================
// BasicAA

let BAS_MAX_LOOKUP = 10;     // MaxLookupSearchDepth (ValueTracking.h)

fn bas_enable_recphi() -> bool { flag_bool("basic-aa-recphi", true) }

// The separate_storage assumptions are read through the AssumptionCache (bas_separate_storage).
fn bas_check_separate_storage(fv: i32) { }

// EnableSeparateStorageAnalysis: an assume's "separate_storage"(Hint1, Hint2) bundle whose hints' underlying
// objects are O1 and O2, valid at the context instruction or at V1 / V2 (an argument: the entry block's first
// instruction), proves NoAlias
fn bas_separate_storage(o1: i32, o2: i32, v1: i32, v2: i32, cxt: i32) -> bool {
    if !flag_bool("basic-aa-separate-storage", true) { return false; }
    ac_build(aa_cur_fn);
    let n = ac_val.len;
    for k in n {
        if ac_val[k] != o1 || ac_idx[k] < 0 { continue; }
        let a = ac_asm[k];
        if is_dead(a) { continue; }
        let bi = ac_idx[k] as i64;
        if sbytes(cb_bundle_tag(a, bi)) != "separate_storage" { continue; }
        let b = cb_bundle_begin(a, bi);
        let h1 = get_underlying_object(op(a, b), 10);
        let h2 = get_underlying_object(op(a, b + 1), 10);
        if !((o1 == h1 && o2 == h2) || (o1 == h2 && o2 == h1)) { continue; }
        let save = vt_allow_ephemerals;
        vt_allow_ephemerals = true;
        let ok = (cxt >= 0 && valid_assume_for_context(a, cxt)) || bas_valid_assume_for_ptr(a, v1) || bas_valid_assume_for_ptr(a, v2);
        vt_allow_ephemerals = save;
        if ok { return true; }
    }
    return false;
}
fn bas_valid_assume_for_ptr(a: i32, p: i32) -> bool {
    if is_inst(p) { return valid_assume_for_context(a, p); }
    if is_arg(p) { return valid_assume_for_context(a, block_first(func_entry(args_parent[vals[p].sub]))); }
    return false;
}

// ---------------------------------------------------------------------------------------------
// Object sizes (MemoryBuiltins.cpp getBaseObjectSize; BasicAA getObjectSize / isObjectSmallerThan / isObjectSize)

// GlobalValue::isInterposable (without the SemanticInterposition module flag)
fn bas_glob_interposable(v: i32) -> bool {
    let l = globs[glob_of(v)].linkage as i64;
    return l == LK_WEAK_ANY || l == LK_LINKONCE_ANY || l == LK_COMMON || l == LK_EXTERN_WEAK;
}
fn bas_gvar_has_initializer(v: i32) -> bool { nops(v) > 0 }
fn bas_align_bytes(lg: u8) -> u64 { if lg == 0 { 0 } else { (1 as u64) << ((lg - 1) as u64) } }
fn bas_align_to(x: u64, a: u64) -> u64 { if a <= 1 { x } else { (x + a - 1) / a * a } }

// allocation data: index into TLI_ALLOC_DATA rows (6 ints each) or -1; mask = AllocType bits wanted
fn bas_alloc_data_for_fn(f: i32, mask: i64) -> i64 {
    let fty = func_type(f);
    if ty_kind(ty_fn_ret(fty)) != TK_PTR { return -1; }
    let lf = tli_get_libfunc(f);
    if lf < 0 || !tli_has(lf) { return -1; }
    var k: i64 = 0;
    while k < TLI_ALLOC_DATA.len {
        if TLI_ALLOC_DATA[k] == lf {
            let at = TLI_ALLOC_DATA[k + 1] as i64;
            if (at & mask) != at { return -1; }
            let np = TLI_ALLOC_DATA[k + 2] as i64;
            let fst = TLI_ALLOC_DATA[k + 3] as i64;
            let snd = TLI_ALLOC_DATA[k + 4] as i64;
            fn int3264(t: i32) -> bool { ty_is_int(t) && (ty_bits(t) == 32 || ty_bits(t) == 64) }
            if ty_fn_nparams(fty) == np && (fst < 0 || int3264(ty_fn_param(fty, fst))) && (snd < 0 || int3264(ty_fn_param(fty, snd))) { return k; }
            return -1;
        }
        k += 6;
    }
    return -1;
}
// MemoryBuiltins getCalledFunction: not an IntrinsicInst, not nobuiltin
fn bas_alloc_called_fn(c: i32) -> i32 {
    if !is_callbase(c) { return -1; }
    if inst_iid(c) != 0 { return -1; }
    if call_is_nobuiltin(c) { return -1; }
    return called_function(c);
}
// isMallocOrCallocLikeFn
fn bas_is_malloc_or_calloc_like(c: i32) -> bool {
    let f = bas_alloc_called_fn(c);
    if f < 0 { return false; }
    return bas_alloc_data_for_fn(f, 3) >= 0;
}

// getAllocSize(CB, TLI) (no mapper): (size, ok)
fn bas_get_alloc_size(c: i32) -> u64, bool {
    var fst: i64 = -1;
    var snd: i64 = -1;
    var strdup = false;
    let f = bas_alloc_called_fn(c);
    var found = false;
    if f >= 0 {
        let k = bas_alloc_data_for_fn(f, 7);
        if k >= 0 {
            found = true;
            fst = TLI_ALLOC_DATA[k + 3] as i64;
            snd = TLI_ALLOC_DATA[k + 4] as i64;
            strdup = TLI_ALLOC_DATA[k + 1] == 4;
        }
    }
    if !found {
        var a = aset_find(alist_fn(insts[inst_of(c)].attrs), AK_AllocSize);
        let cal = cb_callee(c);
        if a < 0 && is_func(cal) { a = aset_find(alist_fn(func_attrs(cal)), AK_AllocSize); }
        if a < 0 { return 0, false; }
        fst = (attrs[a].i1 >> 32) as i64;
        let n = attrs[a].i1 & 0xFFFFFFFF;
        snd = if n == 0xFFFFFFFF { -1 } else { n as i64 };
    }
    if strdup { fatal("BasicAA: the size of strdup-like allocations (GetStringLength) is not ported yet"); }
    let iw = dl_ptr(ptr_as(vals[c].ty)).idx;
    if iw > 64 { fatal("BasicAA: index widths over 64 bits are not supported"); }
    fn arg_val(k: i64) -> u64, bool {
        let x = cb_arg(c, k);
        if vals[x].kind != VK_CINT || ty_is_vector(vals[x].ty) { return 0, false; }
        let w = ty_bits(vals[x].ty);
        if w > 64 { if cint_hi(x) != 0 { return 0, false; } }
        let v = cint_lo(x);
        // checkedZextOrTrunc: fails if the value doesn't fit in the index width
        if iw < 64 && w > iw && (v >> (iw as u64)) != 0 { return 0, false; }
        return v, true;
    }
    let s, ok = arg_val(fst);
    if !ok { return 0, false; }
    if snd < 0 { return s, true; }
    let n, ok2 = arg_val(snd);
    if !ok2 { return 0, false; }
    if n != 0 && s > wmask64(iw) / n { return 0, false; }
    return s * n, true;
}

// getBaseObjectSize(V, DL, TLI, Opts{RoundToAlign, NullIsUnknownSize}): (size, ok, scalable)
fn bas_base_object_size(v: i32, null_unknown: bool, round: bool) -> u64, bool, bool {
    let k = vals[v].kind;
    if k == VK_UNDEF || k == VK_POISON { return 0, true, false; }
    if k == VK_CNULL {
        if null_unknown || ptr_as(vals[v].ty) != 0 { return 0, false, false; }
        return 0, true, false;
    }
    if k == VK_GVAR {
        let vt0 = globs[glob_of(v)].vty;
        if globs[glob_of(v)].linkage as i64 == LK_EXTERN_WEAK || !bas_gvar_has_initializer(v) || bas_glob_interposable(v) { return 0, false, false; }
        var s = dl_alloc_size(vt0) as u64;
        if round { s = bas_align_to(s, bas_align_bytes(globs[glob_of(v)].align)); }
        return s, true, false;
    }
    if k == VK_ARG {
        let mt = ml_arg_mem_type(v);
        if mt < 0 { return 0, false, false; }
        var s = dl_alloc_size(mt) as u64;
        let sc = ty_size_scalable(mt);
        if round && !sc { s = bas_align_to(s, ml_arg_int(v, AK_Alignment)); }
        return s, true, sc;
    }
    if is_inst_op(v, OP_ALLOCA) {
        let s, ok, sc = ml_alloca_size(v);
        if !ok { return 0, false, false; }
        if round && !sc { return bas_align_to(s, bas_align_bytes(insts[inst_of(v)].align)), true, sc; }
        return s, true, sc;
    }
    if is_callbase(v) {
        let s, ok = bas_get_alloc_size(v);
        if ok { return s, true, false; }
        return 0, false, false;
    }
    return 0, false, false;
}

// getObjectSize (BasicAA.cpp): scalable sizes are unknown
fn bas_object_size(v: i32, null_valid: bool, round: bool) -> u64, bool {
    let s, ok, sc = bas_base_object_size(v, null_valid, round);
    if !ok || sc { return 0, false; }
    return s, true;
}

// isObjectSmallerThan(V, Size (fixed), ...)
fn bas_object_smaller_than(v: i32, size: u64, null_valid: bool) -> bool {
    if !aa_is_identified_object(v) { return false; }
    let s, ok = bas_object_size(v, null_valid, true);
    return ok && s < size;
}

// isObjectSize(V, Size)
fn bas_is_object_size(v: i32, ls: u64, null_valid: bool) -> bool {
    let s, ok = bas_object_size(v, null_valid, false);
    return ok && !ls_is_scalable(ls) && s == ls_value(ls);
}

// Value::getPointerDereferenceableBytes (CanBeFreed = nullptr): (bytes, CanBeNull)
fn bas_deref_bytes(v: i32) -> u64, bool {
    var d: u64 = 0;
    var can_be_null = false;
    let k = vals[v].kind;
    if k == VK_ARG {
        d = ml_arg_int(v, AK_Dereferenceable);
        if d == 0 {
            let mt = ml_arg_mem_type(v);
            if mt >= 0 { d = dl_store_size(mt) as u64; }
        }
        if d == 0 { d = ml_arg_int(v, AK_DereferenceableOrNull); can_be_null = true; }
    } else if is_callbase(v) {
        d = cb_ret_attr_int(v, AK_Dereferenceable);
        if d == 0 { d = cb_ret_attr_int(v, AK_DereferenceableOrNull); can_be_null = true; }
    } else if is_inst_op(v, OP_LOAD) || is_inst_op(v, OP_INTTOPTR) {
        let m = inst_get_md(v, MDK_DEREFERENCEABLE);
        if m >= 0 { d = bas_md_int(m); }
        if d == 0 {
            let m2 = inst_get_md(v, MDK_DEREFERENCEABLE_OR_NULL);
            if m2 >= 0 { d = bas_md_int(m2); }
            can_be_null = true;
        }
    } else if is_inst_op(v, OP_ALLOCA) {
        let s, ok, sc = ml_alloca_size(v);
        if ok { d = s; can_be_null = false; }
    } else if k == VK_GVAR {
        if globs[glob_of(v)].linkage as i64 != LK_EXTERN_WEAK {
            d = dl_store_size(globs[glob_of(v)].vty) as u64;
            can_be_null = false;
        }
    }
    return d, can_be_null;
}
fn bas_md_int(m: i32) -> u64 {
    let o = md_op(m, 0);
    if o < 0 || mds[o].kind != MK_VALUE { return 0; }
    let v = mds[o].extra;
    if vals[v].kind != VK_CINT { return 0; }
    if ty_bits(vals[v].ty) > 64 && cint_hi(v) != 0 { return 0xFFFFFFFFFFFFFFFF; }
    return cint_lo(v);
}

// getMinimalExtentFrom
fn bas_minimal_extent(v: i32, ls: u64, null_valid: bool) -> u64 {
    var d, can_be_null = bas_deref_bytes(v);
    if can_be_null && null_valid { d = 0; }
    if ls_is_precise(ls) { d = max(d, ls_value(ls)); }
    return d;
}

// ---------------------------------------------------------------------------------------------
// GEP decomposition

// CastedValue: zext(sext(trunc(V)))
struct CV { v: i32, zext: i32, sext: i32, trunc: i32, nonneg: bool }
// LinearExpression: CV * scale + off (at the CV's bit width)
struct LE { val: CV, scale: u64, off: u64, nuw: bool, nsw: bool }
// VariableGEPIndex
struct VGI { val: CV, scale: u64, cxt: i32, nsw: bool, neg: bool }
// DecomposedGEP: vars at bas_vars[at .. at + n)
struct DG { base: i32, off: u64, w: i32, at: i32, n: i32, nw: u8 }

var bas_vars: VGI[>..<];
var bas_srcs: i32[>..<];

fn bas_prim_bits(v: i32) -> i64 {
    let t = vals[v].ty;
    if ty_is_int(t) { return ty_bits(t); }
    fatal("internal: BasicAA: non-integer index");
    return 0;
}
fn bas_w(v: i32) -> i64 {
    let w = bas_prim_bits(v);
    if w > 64 { fatal("BasicAA: integers wider than 64 bits in GEP indices are not supported yet"); }
    return w;
}
fn bas_m64(w: i64) -> u64 { wmask64(w) }
fn bas_s64(x: u64, w: i64) -> i64 { sext64(x & bas_m64(w), w) }
fn bas_neg_w(x: u64, w: i64) -> u64 { ((0 as u64) - x) & bas_m64(w) }
fn bas_is_neg_w(x: u64, w: i64) -> bool { (x & sbit64(w)) != 0 }
fn bas_abs_w(x: u64, w: i64) -> u64 { if bas_is_neg_w(x, w) { bas_neg_w(x, w) } else { x & bas_m64(w) } }
fn bas_slt_w(a: u64, b: u64, w: i64) -> bool { bas_s64(a, w) < bas_s64(b, w) }
fn bas_sge_w(a: u64, b: u64, w: i64) -> bool { !bas_slt_w(a, b, w) }

fn cv_new(v: i32) -> CV { CV { v: v, zext: 0, sext: 0, trunc: 0, nonneg: false } }
fn cv_bw(c: CV) -> i64 { bas_prim_bits(c.v) - (c.trunc as i64) + (c.zext as i64) + (c.sext as i64) }
fn cv_with_value(c: CV, nv: i32, preserve_nonneg: bool) -> CV {
    CV { v: nv, zext: c.zext, sext: c.sext, trunc: c.trunc, nonneg: c.nonneg && preserve_nonneg }
}
fn cv_with_zext_of(c: CV, nv: i32, zext_nonneg: bool) -> CV {
    var ext = bas_prim_bits(c.v) - bas_prim_bits(nv);
    if ext <= (c.trunc as i64) { return CV { v: nv, zext: c.zext, sext: c.sext, trunc: c.trunc - (ext as i32), nonneg: c.nonneg }; }
    ext -= c.trunc as i64;
    return CV { v: nv, zext: c.zext + c.sext + (ext as i32), sext: 0, trunc: 0, nonneg: zext_nonneg };
}
fn cv_with_sext_of(c: CV, nv: i32) -> CV {
    var ext = bas_prim_bits(c.v) - bas_prim_bits(nv);
    if ext <= (c.trunc as i64) { return CV { v: nv, zext: c.zext, sext: c.sext, trunc: c.trunc - (ext as i32), nonneg: c.nonneg }; }
    ext -= c.trunc as i64;
    return CV { v: nv, zext: c.zext, sext: c.sext + (ext as i32), trunc: 0, nonneg: c.nonneg };
}
// evaluateWith(APInt N), N at V's width
fn cv_eval(c: CV, n: u64) -> u64 {
    var w = bas_w(c.v);
    var x = n & bas_m64(w);
    if c.trunc > 0 { w -= c.trunc as i64; x &= bas_m64(w); }
    if c.sext > 0 { let nw = w + (c.sext as i64); x = (sext64(x, w) as! u64) & bas_m64(nw); w = nw; }
    if c.zext > 0 { w += c.zext as i64; }
    return x & bas_m64(w);
}
// evaluateWith(ConstantRange N)
fn cv_eval_cr(c: CV, n0: CR) -> CR {
    var n = n0;
    var w = n.w as i64;
    if c.trunc > 0 { w -= c.trunc as i64; n = cr_truncate(n, w); }
    if c.nonneg && !cr_is_all_nonneg(n) { n = cr_intersect(n, cr_new(0, sbit64(w), w)); }
    if c.sext > 0 { w += c.sext as i64; n = cr_sext(n, w); }
    if c.zext > 0 { w += c.zext as i64; n = cr_zext(n, w); }
    return n;
}
// evaluateWith(ConstantRange N) on an any-width CRange
fn rg_cv_eval(c: CV, n0: CRange) -> CRange {
    var n = n0;
    var w = rg_w(n);
    if c.trunc > 0 { w -= c.trunc as i64; n = rg_truncate(n, w); }
    if c.nonneg && !rg_is_all_nonneg(n) { n = rg_intersect(n, rg_new(ap_zero(w), ap_smin_val(w))); }
    if c.sext > 0 { w += c.sext as i64; n = rg_sext(n, w); }
    if c.zext > 0 { w += c.zext as i64; n = rg_zext(n, w); }
    return n;
}
fn cv_can_distribute(c: CV, nuw: bool, nsw: bool) -> bool { (c.zext == 0 || nuw) && (c.sext == 0 || nsw) }
fn cv_same_casts(a: CV, b: CV) -> bool {
    if vals[a.v].ty != vals[b.v].ty { return false; }
    if a.zext == b.zext && a.sext == b.sext && a.trunc == b.trunc { return true; }
    if a.nonneg || b.nonneg { return a.zext + a.sext == b.zext + b.sext && a.trunc == b.trunc; }
    return false;
}

fn le_of(c: CV) -> LE { LE { val: c, scale: 1, off: 0, nuw: true, nsw: true } }
fn le_mul(e: LE, other: u64, mul_nuw: bool, mul_nsw: bool) -> LE {
    let w = cv_bw(e.val);
    let one = (other & bas_m64(w)) == 1;
    let nsw = e.nsw && (one || (mul_nsw && (e.off & bas_m64(w)) == 0));
    let nuw = e.nuw && (one || mul_nuw);
    return LE { val: e.val, scale: (e.scale * other) & bas_m64(w), off: (e.off * other) & bas_m64(w), nuw: nuw, nsw: nsw };
}

// GetLinearExpression
recursive fn bas_linear_expression(c: CV, depth: i64) -> LE {
    if depth == 6 { return le_of(c); }
    let v = c.v;
    let w = cv_bw(c);
    if vals[v].kind == VK_CINT && !ty_is_vector(vals[v].ty) {
        bas_w(v);
        return LE { val: c, scale: 0, off: cv_eval(c, cint_lo(v)), nuw: true, nsw: true };
    }
    if is_inst(v) && is_binary_op(iop(v)) {
        let rc = op(v, 1);
        if vals[rc].kind == VK_CINT && !ty_is_vector(vals[rc].ty) {
            bas_w(rc);
            let rhs = cv_eval(c, cint_lo(rc));
            let o = iop(v);
            var nuw = true;
            var nsw = true;
            // OverflowingBinaryOperator: add, sub, mul, shl
            if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL { nuw = nuw && op_nuw(v); nsw = nsw && op_nsw(v); }
            if !cv_can_distribute(c, nuw, nsw) { return le_of(c); }
            if c.trunc > 0 { nuw = false; nsw = false; }
            if o == OP_OR && !op_disjoint(v) { return le_of(c); }
            if o == OP_OR || o == OP_ADD {
                var e = bas_linear_expression(cv_with_value(c, op(v, 0), false), depth + 1);
                e.off = (e.off + rhs) & bas_m64(w);
                e.nuw = e.nuw && nuw;
                e.nsw = e.nsw && nsw;
                return e;
            }
            if o == OP_SUB {
                var e = bas_linear_expression(cv_with_value(c, op(v, 0), false), depth + 1);
                e.off = (e.off - rhs) & bas_m64(w);
                e.nuw = false;
                e.nsw = e.nsw && nsw;
                return e;
            }
            if o == OP_MUL {
                let e = bas_linear_expression(cv_with_value(c, op(v, 0), false), depth + 1);
                return le_mul(e, rhs, nuw, nsw);
            }
            if o == OP_SHL {
                // getLimitedValue() > bitwidth
                if rhs > (w as u64) { return le_of(c); }
                var e = bas_linear_expression(cv_with_value(c, op(v, 0), nsw), depth + 1);
                let sh = rhs;
                e.off = if sh >= 64 { 0 } else { (e.off << sh) & bas_m64(w) };
                e.scale = if sh >= 64 { 0 } else { (e.scale << sh) & bas_m64(w) };
                e.nuw = e.nuw && nuw;
                e.nsw = e.nsw && nsw;
                return e;
            }
            return le_of(c);
        }
    }
    if is_inst_op(v, OP_ZEXT) {
        return bas_linear_expression(cv_with_zext_of(c, op(v, 0), (op_flags(v) & FL_NNEG) != 0), depth + 1);
    }
    if is_inst_op(v, OP_SEXT) {
        return bas_linear_expression(cv_with_sext_of(c, op(v, 0)), depth + 1);
    }
    return le_of(c);
}

fn bas_is_vscale(v: i32) -> bool { inst_iid(v) == IID_vscale }
fn bas_both_vscale(a: i32, b: i32) -> bool { bas_is_vscale(a) && bas_is_vscale(b) }

// GEPNoWrapFlags of a GEP operator (inbounds implies nusw)
fn bas_gep_nw(g: i32) -> u8 {
    var f = op_flags(g) & (GEP_INBOUNDS | GEP_NUSW | GEP_NUW);
    if (f & GEP_INBOUNDS) != 0 { f |= GEP_NUSW; }
    return f;
}

fn bas_gep_src_ty(g: i32) -> i32 { if vals[g].kind == VK_INST { insts[inst_of(g)].ty2 } else { csts[vals[g].sub].ty2 } }

fn bas_index_width(v: i32) -> i64 {
    let w = dl_ptr(ptr_as(vals[v].ty)).idx;
    if w > 64 { fatal("BasicAA: pointer index widths over 64 bits are not supported yet"); }
    return w;
}

// erase var i (relative) from a DG whose vars are at the top of bas_vars
fn dg_erase(d: DG&, i: i64) {
    let at = d.at as i64;
    var k = at + i;
    while k + 1 < at + (d.n as i64) { bas_vars[k] = bas_vars[k + 1]; k++; }
    d.n -= 1;
    bas_vars.resize(at + (d.n as i64));
}
fn dg_var(d: DG, i: i64) -> VGI { bas_vars[(d.at as i64) + i] }
fn dg_set_var(d: DG, i: i64, x: VGI) { bas_vars[(d.at as i64) + i] = x; }

// DecomposeGEPExpression; the result's vars are pushed on bas_vars
recursive fn bas_decompose_gep(v0: i32) -> DG {
    var v = v0;
    var max_lookup = BAS_MAX_LOOKUP;
    let cxt = if is_inst(v0) { v0 } else { -1 };
    let w = bas_index_width(v0);
    var d = DG { base: -1, off: 0, w: w as i32, at: bas_vars.len as i32, n: 0, nw: GEP_INBOUNDS | GEP_NUSW | GEP_NUW };
    loop {
        let k = vals[v].kind;
        if k != VK_INST && k != VK_CEXPR {
            if k == VK_ALIAS && !bas_glob_interposable(v) {
                v = op(v, 0);
                max_lookup--;
                if max_lookup == 0 { break; }
                continue;
            }
            d.base = v;
            return d;
        }
        let o = opcode_of(v);
        if o == OP_BITCAST || o == OP_ADDRSPACECAST {
            let nv = op(v, 0);
            if ty_kind(vals[nv].ty) != TK_PTR || dl_ptr(ptr_as(vals[nv].ty)).idx != w { d.base = v; return d; }
            v = nv;
            max_lookup--;
            if max_lookup == 0 { break; }
            continue;
        }
        if o != OP_GEP {
            if is_inst_op(v, OP_PHI) {
                if nops(v) == 1 {
                    v = op(v, 0);
                    max_lookup--;
                    if max_lookup == 0 { break; }
                    continue;
                }
            } else if is_callbase(v) {
                let rp = arg_aliasing_returned_ptr(v, true);
                if rp >= 0 {
                    v = rp;
                    max_lookup--;
                    if max_lookup == 0 { break; }
                    continue;
                }
            }
            d.base = v;
            return d;
        }
        d.nw &= bas_gep_nw(v);
        var t = bas_gep_src_ty(v);
        let n = nops(v);
        var i: i64 = 1;
        while i < n {
            let ix = op(v, i);
            // GTI: index 1 steps over the source element type; later indices go into t
            var stride: u64 = 0;
            var scalable = false;
            if i > 1 {
                if ty_is_struct(t) {
                    let fno = cint_lo(ix) as i64;
                    if fno != 0 { d.off = (d.off + (dl_struct_offset(t, fno) as u64)) & bas_m64(w); }
                    t = ty_field(t, fno);
                    i++;
                    continue;
                }
                let et = ty_elem(t);
                if ty_is_vector(t) { stride = dl_store_size(et) as u64; } else { stride = dl_alloc_size(et) as u64; }
                scalable = ty_size_scalable(et);
                t = et;
            } else {
                stride = dl_alloc_size(t) as u64;
                scalable = ty_size_scalable(t);
            }
            if vals[ix].kind == VK_CINT && !ty_is_vector(vals[ix].ty) {
                if cint_is_zero(ix) { i++; continue; }
                if scalable { d.base = v; return d; }
                // CIdx->getValue().sextOrTrunc(IndexSize)
                let cw = ty_bits(vals[ix].ty);
                let cv = if cw >= 64 { cint_lo(ix) } else { sext64(cint_lo(ix), cw) as! u64 };
                d.off = (d.off + stride * cv) & bas_m64(w);
                i++;
                continue;
            }
            if scalable { d.base = v; return d; }
            let gf = bas_gep_nw(v);
            let nusw = (gf & GEP_NUSW) != 0;
            let nuw = (gf & GEP_NUW) != 0;
            let nonneg = nusw && nuw;
            let iw = bas_prim_bits(ix);
            let sx: i32 = if w > iw { (w - iw) as i32 } else { 0 };
            let tr: i32 = if w < iw { (iw - w) as i32 } else { 0 };
            var le = bas_linear_expression(CV { v: ix, zext: 0, sext: sx, trunc: tr, nonneg: nonneg }, 0);
            le = le_mul(le, stride & bas_m64(w), nuw, nusw);
            d.off = (d.off + le.off) & bas_m64(w);
            var scale = le.scale;
            if !le.nuw { d.nw &= ~GEP_NUW; }
            var j: i64 = 0;
            while j < (d.n as i64) {
                let x = dg_var(d, j);
                if (x.val.v == le.val.v || bas_both_vscale(x.val.v, le.val.v)) && cv_same_casts(x.val, le.val) {
                    scale = (scale + x.scale) & bas_m64(w);
                    le.nsw = false;
                    le.nuw = false;
                    dg_erase(d, j);
                    break;
                }
                j++;
            }
            if scale != 0 {
                bas_vars.push(VGI { val: le.val, scale: scale, cxt: cxt, nsw: le.nsw, neg: false });
                d.n += 1;
            }
            i++;
        }
        v = op(v, 0);
        max_lookup--;
        if max_lookup == 0 { break; }
    }
    d.base = v;
    return d;
}

// isValueEqualInPotentialCycles
fn bas_value_equal(v: i32, v2: i32, q: i32) -> bool {
    if v != v2 { return false; }
    if !aqs[q].cross { return true; }
    if !is_inst(v) { return true; }
    let bb = inst_parent(v);
    if func_entry(block_func(bb)) == bb { return true; }
    return cfr_not_in_cycle(v, aqs[q].use_dt, false, false);
}

// subtractDecomposedGEPs (Dest's vars must be at the top of bas_vars)
fn bas_subtract_gep(dest: DG&, src: DG, q: i32) {
    let w = dest.w as i64;
    if (dest.off & bas_m64(w)) < (src.off & bas_m64(w)) { dest.nw &= ~GEP_NUW; }
    dest.off = (dest.off - src.off) & bas_m64(w);
    for si in src.n as i64 {
        let s = dg_var(src, si);
        var found = false;
        var j: i64 = 0;
        while j < (dest.n as i64) {
            var dv = dg_var(dest, j);
            if (!bas_value_equal(dv.val.v, s.val.v, q) && !bas_both_vscale(dv.val.v, s.val.v)) || !cv_same_casts(dv.val, s.val) { j++; continue; }
            if dv.neg {
                dv.scale = bas_neg_w(dv.scale, w);
                dv.neg = false;
                dv.nsw = false;
            }
            if dv.scale != s.scale {
                if dv.scale < s.scale { dest.nw &= ~GEP_NUW; }
                dv.scale = (dv.scale - s.scale) & bas_m64(w);
                dv.nsw = false;
                dg_set_var(dest, j, dv);
            } else {
                dg_erase(dest, j);
            }
            found = true;
            break;
        }
        if !found {
            bas_vars.push(VGI { val: s.val, scale: s.scale, cxt: s.cxt, nsw: s.nsw, neg: true });
            dest.n += 1;
            dest.nw &= ~GEP_NUW;
        }
    }
}

fn vgi_has_negated_scale_of(a: VGI, b: VGI, w: i64) -> bool {
    if a.neg == b.neg { return a.scale == bas_neg_w(b.scale, w); }
    return a.scale == b.scale;
}

// constantOffsetHeuristic
fn bas_constant_offset_heuristic(d: DG, s1: u64, s2: u64, q: i32) -> bool {
    if d.n != 2 || !ls_has_value(s1) || !ls_has_value(s2) { return false; }
    let w = d.w as i64;
    let v1s = ls_value(s1);
    let v2s = ls_value(s2);
    let x0 = dg_var(d, 0);
    let x1 = dg_var(d, 1);
    if x0.val.trunc != 0 || !cv_same_casts(x0.val, x1.val) || !vgi_has_negated_scale_of(x0, x1, w) ||
       vals[x0.val.v].ty != vals[x1.val.v].ty { return false; }
    let e0 = bas_linear_expression(cv_new(x0.val.v), 0);
    let e1 = bas_linear_expression(cv_new(x1.val.v), 0);
    if e0.scale != e1.scale || !cv_same_casts(e0.val, e1.val) || !bas_value_equal(e0.val.v, e1.val.v, q) { return false; }
    let ew = cv_bw(e0.val);
    var mindiff = (e0.off - e1.off) & bas_m64(ew);
    let wrapped = bas_neg_w(mindiff, ew);
    if wrapped < mindiff { mindiff = wrapped; }
    // zextOrTrunc to the scale's width, times |Scale|
    let md = mindiff & bas_m64(w);
    let bytes = (md * bas_abs_w(x0.scale, w)) & bas_m64(w);
    let aoff = bas_abs_w(d.off, w);
    return bytes >= ((v1s + aoff) & bas_m64(w)) && bytes >= ((v2s + aoff) & bas_m64(w));
}

// getVScaleRange(F, BitWidth)
fn bas_vscale_range(w: i64) -> CR {
    let a = aset_find(alist_fn(func_attrs(aa_cur_fn)), AK_VScaleRange);
    if a < 0 { return cr_new(1, 0, w); }
    let mn = attrs[a].i1 >> 32;
    let mx = attrs[a].i1 & 0xFFFFFFFF;
    fn bitw(x: u64) -> i64 { if x == 0 { 0 } else { 64 - clz(x) } }
    if bitw(mn) > w { return cr_empty(w); }
    if mx == 0 || bitw(mx) > w { return cr_new(mn, 0, w); }
    return cr_nonempty(mn, mx + 1, w);
}

// unsigned GCD
fn bas_gcd_u(a0: u64, b0: u64) -> u64 {
    var a = a0;
    var b = b0;
    while b != 0 { let t = a % b; a = b; b = t; }
    return a;
}
// APInt::srem at width w
fn bas_srem_w(a: u64, b: u64, w: i64) -> u64 {
    let x = bas_s64(a, w);
    let y = bas_s64(b, w);
    if y == -1 { return 0; }
    let r = x - (x / y) * y;
    return (r as! u64) & bas_m64(w);
}
fn bas_sig_bits(x: u64, w: i64) -> i64 {
    // getSignificantBits: BitWidth - getNumSignBits() + 1
    let v = x & bas_m64(w);
    let y = if bas_is_neg_w(v, w) { ~v & bas_m64(w) } else { v };
    return w - clz_w(y, w) + 1;
}

// aliasGEP
recursive fn bas_alias_gep(gep1: i32, s1: u64, v2: i32, s2: u64, u1: i32, u2: i32, q: i32) -> AR {
    let mark = bas_vars.len;
    let r = bas_alias_gep_impl(gep1, s1, v2, s2, u1, u2, q);
    bas_vars.resize(mark);
    return r;
}

fn bas_is_gep_operator(v: i32) -> bool { opcode_of(v) == OP_GEP }
fn bas_is_phi_or_select(v: i32) -> bool { is_inst_op(v, OP_PHI) || is_inst_op(v, OP_SELECT) }

recursive fn bas_base_objects_alias(u1: i32, u2: i32, q: i32) -> AR {
    let r = aa_alias(ml_before_or_after(u1), ml_before_or_after(u2), q, -1);
    return if r.k == AR_NO as u8 { ar(AR_NO) } else { ar(AR_MAY) };
}

recursive fn bas_alias_gep_impl(gep1: i32, s1_0: u64, v2: i32, s2_0: u64, u1_0: i32, u2_0: i32, q: i32) -> AR {
    var s1 = s1_0;
    var s2 = s2_0;
    var u1 = u1_0;
    var u2 = u2_0;
    if !ls_has_value(s1) && !ls_has_value(s2) {
        if bas_is_phi_or_select(v2) { return ar(AR_MAY); }
        if bas_is_gep_operator(v2) || bas_is_gep_operator(u1) || bas_is_phi_or_select(u1) || bas_is_gep_operator(u2) || bas_is_phi_or_select(u2) {
            return bas_base_objects_alias(u1, u2, q);
        }
        return ar(AR_MAY);
    }
    var d1 = bas_decompose_gep(gep1);
    var d2 = bas_decompose_gep(v2);
    if d1.base == gep1 && d2.base == v2 { return ar(AR_MAY); }
    if d1.w != d2.w { return bas_base_objects_alias(u1, u2, q); }
    if d1.n < d2.n {
        let t = d1; d1 = d2; d2 = t;
        let ts = s1; s1 = s2; s2 = ts;
        let tu = u1; u1 = u2; u2 = tu;
    }
    // move d1's vars to the top so the subtraction can append to them
    let nat = bas_vars.len as i32;
    for i in d1.n as i64 { bas_vars.push(dg_var(d1, i)); }
    d1.at = nat;
    bas_subtract_gep(d1, d2, q);
    let w = d1.w as i64;
    let off = d1.off & bas_m64(w);
    // APInt::sge(int64_t) / sle(int64_t): signed comparison with the size as an int64
    if (d1.nw & GEP_INBOUNDS) != 0 && d1.n == 0 && ls_has_value(s2) && !ls_is_scalable(s2) &&
       bas_s64(off, w) >= (ls_value(s2) as i64) && aa_is_base_of_object(d2.base) {
        return ar(AR_NO);
    }
    if (d2.nw & GEP_INBOUNDS) != 0 && d1.n == 0 && ls_has_value(s1) && !ls_is_scalable(s1) &&
       bas_s64(off, w) <= -(ls_value(s1) as i64) && aa_is_base_of_object(d1.base) {
        return ar(AR_NO);
    }
    if off == 0 && d1.n == 0 {
        return aa_alias(ml_make(d1.base, s1), ml_make(d2.base, s2), q, -1);
    }
    let base_alias = aa_alias(ml_before_or_after(d1.base), ml_before_or_after(d2.base), q, -1);
    if base_alias.k != AR_MUST as u8 { return base_alias; }
    if d1.n == 0 {
        var o = off;
        var lsz = s2;
        var rsz = s1;
        let swapped = bas_is_neg_w(o, w);
        if swapped {
            lsz = s1;
            rsz = s2;
            o = bas_neg_w(o, w);
        }
        if !ls_has_value(lsz) { return ar(AR_MAY); }
        if !ls_is_scalable(lsz) {
            let l = ls_value(lsz);
            if bas_ult_size(o, l, w) {
                var res = ar(AR_PARTIAL);
                if ls_has_value(rsz) && !ls_is_scalable(rsz) && o <= 0x7FFFFFFF && bas_ule_size((o + ls_value(rsz)) & bas_m64(w), l, w) {
                    res = ar_set_offset(res, -bas_s64(o, w));
                    res = ar_swap(res, swapped);
                }
                return res;
            }
            return ar(AR_NO);
        } else {
            let cr = bas_vscale_range(w);
            let up, ov = bas_cr_umul_ov(cr_umax(cr), ls_value(lsz) & bas_m64(w), w);
            if !ov && o >= up { return ar(AR_NO); }
        }
    }
    if d1.n == 1 {
        let x = dg_var(d1, 0);
        if x.val.trunc == 0 && off == 0 && bas_is_vscale(x.val.v) {
            let scale = if x.neg { bas_neg_w(x.scale, w) } else { x.scale };
            let lsz = if bas_is_neg_w(scale, w) { s1 } else { s2 };
            var overflows = !x.nsw;
            if overflows {
                let cr = bas_vscale_range(w);
                let p, ov = cr_smul_ov(cr_smax(cr), scale, w);
                overflows = ov;
            }
            if !overflows {
                if ls_has_value(lsz) && bas_uge_size(bas_abs_w(scale, w), ls_value(lsz), w) { return ar(AR_NO); }
            }
        }
    }
    if d1.n > 0 && (d1.nw & GEP_NUW) != 0 && ls_has_value(s2) && !ls_is_scalable(s2) && bas_uge_size(off, ls_value(s2), w) { return ar(AR_NO); }
    if ls_is_scalable(s1) || ls_is_scalable(s2) { return ar(AR_MAY); }
    if !ls_has_value(s1) || !ls_has_value(s2) || !bas_fits_uint(ls_value(s1), w) || !bas_fits_uint(ls_value(s2), w) { return ar(AR_MAY); }
    let v1s = ls_value(s1);
    let v2s = ls_value(s2);
    var gcd: u64 = 0;
    var orange = cr_single(off, w);
    for i in d1.n as i64 {
        let x = dg_var(d1, i);
        let scale = x.scale & bas_m64(w);
        kb_cxt = x.cxt;
        let known = kb_compute_all(x.val.v, 0);
        var sgcd = scale;
        if !x.nsw { sgcd = (1 as u64) << (ctz_w(scale, w) as u64); }
        let vtz = kb_min_tz(known);
        if vtz > 0 {
            let max_shift = w - bas_sig_bits(sgcd, w);
            let sh = min(vtz, max_shift);
            sgcd = if sh >= 64 { 0 } else { (sgcd << (sh as u64)) & bas_m64(w) };
        }
        if i == 0 { gcd = bas_abs_w(sgcd, w); } else { gcd = bas_gcd_u(gcd, bas_abs_w(sgcd, w)); }
        kb_cxt = x.cxt;
        var cr = cr_new(0, 0, w);
        if bas_prim_bits(x.val.v) > 64 {
            // a value wider than 64 bits (truncated to the index width): the range in APInt arithmetic first
            var rg = compute_constant_range(x.val.v, false, true, 0);
            rg = rg_intersect_t(rg, rg_from_kb(known, true), RG_SIGNED);
            cr = rg_to_cr(rg_sext_or_trunc(rg_cv_eval(x.val, rg), w));
        } else {
            cr = rg_to_cr(compute_constant_range(x.val.v, false, true, 0));
            cr = cr_intersect_t(cr, cr_from_kb(known, true), CR_SIGNED);
            cr = cr_sext_or_trunc(cv_eval_cr(x.val, cr), w);
        }
        if x.nsw { cr = cr_smul_sat(cr, cr_single(scale, w)); } else { cr = cr_smul_fast(cr, cr_single(scale, w)); }
        if x.neg { orange = cr_sub(orange, cr); } else { orange = cr_add(orange, cr); }
    }
    var modoff = bas_srem_w(off, gcd, w);
    if bas_is_neg_w(modoff, w) { modoff = (modoff + gcd) & bas_m64(w); }
    if modoff >= v2s && ((gcd - modoff) & bas_m64(w)) >= v1s { return ar(AR_NO); }
    let range1 = cr_add(orange, cr_new(0, v1s, w));
    let range2 = cr_new(0, v2s, w);
    if cr_is_empty(cr_intersect(range1, range2)) { return ar(AR_NO); }
    fn mul_no_wrap(x: VGI) -> bool {
        if x.nsw { return true; }
        let orig = bas_prim_bits(x.val.v);
        let mx = cv_bw(x.val) - orig;
        if mx <= 0 { return false; }
        return (x.scale & bas_m64(w)) <= bas_m64(mx);
    }
    var have_min = false;
    var min_abs: u64 = 0;
    if d1.n == 1 {
        let x = dg_var(d1, 0);
        kb_cxt = x.cxt;
        if x.val.trunc == 0 && is_known_non_zero(x.val.v, 0) {
            if mul_no_wrap(x) { have_min = true; min_abs = bas_abs_w(x.scale, w); }
        }
    } else if d1.n == 2 {
        let x0 = dg_var(d1, 0);
        let x1 = dg_var(d1, 1);
        if vgi_has_negated_scale_of(x0, x1, w) && x0.val.trunc == 0 && cv_same_casts(x0.val, x1.val) && !aqs[q].cross &&
           mul_no_wrap(x0) && mul_no_wrap(x1) {
            kb_cxt = if x0.cxt >= 0 { x0.cxt } else { x1.cxt };
            if is_known_non_equal(x0.val.v, x1.val.v, 0) { have_min = true; min_abs = bas_abs_w(x0.scale, w); }
        }
    }
    if have_min {
        let lo = (off - min_abs) & bas_m64(w);
        let hi = (off + min_abs) & bas_m64(w);
        if bas_is_neg_w(lo, w) && bas_neg_w(lo, w) >= v1s && !bas_is_neg_w(hi, w) && hi >= v2s { return ar(AR_NO); }
    }
    if bas_constant_offset_heuristic(d1, s1, s2, q) { return ar(AR_NO); }
    return ar(AR_MAY);
}

// comparisons of a w-bit APInt with a uint64 (APInt::ult/ule/uge(uint64_t))
fn bas_ult_size(off: u64, size: u64, w: i64) -> bool {
    // APInt::ult(uint64_t RHS): false if the APInt doesn't fit... both fit in 64 bits here
    return (off & bas_m64(w)) < size;
}
fn bas_ule_size(off: u64, size: u64, w: i64) -> bool { (off & bas_m64(w)) <= size }
fn bas_uge_size(off: u64, size: u64, w: i64) -> bool { (off & bas_m64(w)) >= size }
fn bas_fits_uint(x: u64, w: i64) -> bool { w >= 64 || (x >> (w as u64)) == 0 }
// APInt::umul_ov at width w
fn bas_cr_umul_ov(a: u64, b: u64, w: i64) -> u64, bool {
    let m = bas_m64(w);
    let r = (a * b) & m;
    if a == 0 || b == 0 { return r, false; }
    // overflow if a * b doesn't fit in w bits
    if (a & m) > m / (b & m) { return r, true; }
    return r, false;
}

// MergeAliasResults
fn bas_merge(a: AR, b: AR) -> AR {
    if a == b { return a; }
    let ak = a.k as i64;
    let bk = b.k as i64;
    if (ak == AR_PARTIAL && bk == AR_MUST) || (bk == AR_PARTIAL && ak == AR_MUST) { return ar(AR_PARTIAL); }
    return ar(AR_MAY);
}

// aliasSelect
recursive fn bas_alias_select(si: i32, sisize: u64, v2: i32, v2size: u64, q: i32) -> AR {
    if is_inst_op(v2, OP_SELECT) && bas_value_equal(op(si, 0), op(v2, 0), q) {
        let a = aa_alias(ml_make(op(si, 1), sisize), ml_make(op(v2, 1), v2size), q, -1);
        if a.k == AR_MAY as u8 { return ar(AR_MAY); }
        let t = aa_alias(ml_make(op(si, 2), sisize), ml_make(op(v2, 2), v2size), q, -1);
        return bas_merge(t, a);
    }
    let a = aa_alias(ml_make(op(si, 1), sisize), ml_make(v2, v2size), q, -1);
    if a.k == AR_MAY as u8 { return ar(AR_MAY); }
    let t = aa_alias(ml_make(op(si, 2), sisize), ml_make(v2, v2size), q, -1);
    return bas_merge(t, a);
}

// PHINode::getIncomingValueForBlock
fn bas_phi_value_for_block(p: i32, b: i32) -> i32 {
    for k in nops(p) { if phi_block(p, k) == b { return op(p, k); } }
    fatal("internal: PHI has no entry for the block");
    return -1;
}

// aliasPHI
recursive fn bas_alias_phi(pn: i32, pnsize0: u64, v2: i32, v2size: u64, q: i32) -> AR {
    var pnsize = pnsize0;
    let n = nops(pn);
    if n == 0 { return ar(AR_NO); }
    if is_inst_op(v2, OP_PHI) && inst_parent(v2) == inst_parent(pn) && !aqs[q].cross {
        var have = false;
        var a = ar(AR_MAY);
        var i: i64 = 0;
        while i < n {
            let t = aa_alias(ml_make(op(pn, i), pnsize), ml_make(bas_phi_value_for_block(v2, phi_block(pn, i)), v2size), q, -1);
            if have { a = bas_merge(a, t); } else { a = t; have = true; }
            if a.k == AR_MAY as u8 { break; }
            i++;
        }
        return a;
    }
    let mark = bas_srcs.len;
    var is_rec = false;
    var one_phi: i32 = -1;
    let recphi = bas_enable_recphi();
    for k in n {
        let pv = op(pn, k);
        if pv == pn { continue; }
        if is_inst_op(pv, OP_PHI) {
            if one_phi >= 0 && one_phi != pv { bas_srcs.resize(mark); return ar(AR_MAY); }
            one_phi = pv;
        }
        if recphi && get_underlying_object(pv, BAS_MAX_LOOKUP) == pn { is_rec = true; continue; }
        var dup = false;
        var j = mark;
        while j < bas_srcs.len { if bas_srcs[j] == pv { dup = true; } j++; }
        if !dup { bas_srcs.push(pv); }
    }
    let nsrc = bas_srcs.len - mark;
    if one_phi >= 0 && nsrc > 1 { bas_srcs.resize(mark); return ar(AR_MAY); }
    if nsrc == 0 { bas_srcs.resize(mark); return ar(AR_MAY); }
    if is_rec { pnsize = LS_BEFORE_OR_AFTER; }
    let saved = aqs[q].cross;
    aqs[q].cross = true;
    var a = aa_alias(ml_make(bas_srcs[mark], pnsize), ml_make(v2, v2size), q, -1);
    if a.k == AR_MAY as u8 { aqs[q].cross = saved; bas_srcs.resize(mark); return ar(AR_MAY); }
    if is_rec && a.k != AR_NO as u8 { aqs[q].cross = saved; bas_srcs.resize(mark); return ar(AR_MAY); }
    var i: i64 = 1;
    while i < nsrc {
        let v = bas_srcs[mark + i];
        let t = aa_alias(ml_make(v, pnsize), ml_make(v2, v2size), q, -1);
        a = bas_merge(t, a);
        if a.k == AR_MAY as u8 { break; }
        i++;
    }
    aqs[q].cross = saved;
    bas_srcs.resize(mark);
    return a;
}

fn bas_is_argument_like(v: i32) -> bool {
    if is_arg(v) { return true; }
    return is_inst_op(v, OP_EXTRACTVALUE) && is_arg(op(v, 0));
}

fn bas_null_defined(as_: i64) -> bool { null_pointer_is_defined(aa_cur_fn, as_) }

// aliasCheck
recursive fn bas_alias_check(v1_0: i32, s1_0: u64, v2_0: i32, s2_0: u64, q: i32, cxt: i32) -> AR {
    var s1 = s1_0;
    var s2 = s2_0;
    if ls_is_zero(s1) || ls_is_zero(s2) { return ar(AR_NO); }
    let v1 = bas_strip(v1_0);
    let v2 = bas_strip(v2_0);
    if is_undef_or_poison(v1) || is_undef_or_poison(v2) { return ar(AR_NO); }
    if bas_value_equal(v1, v2, q) { return ar(AR_MUST); }
    let o1 = get_underlying_object(v1, BAS_MAX_LOOKUP);
    let o2 = get_underlying_object(v2, BAS_MAX_LOOKUP);
    if vals[o1].kind == VK_CNULL && ty_kind(vals[o1].ty) == TK_PTR && !bas_null_defined(ptr_as(vals[o1].ty)) { return ar(AR_NO); }
    if vals[o2].kind == VK_CNULL && ty_kind(vals[o2].ty) == TK_PTR && !bas_null_defined(ptr_as(vals[o2].ty)) { return ar(AR_NO); }
    if o1 != o2 {
        if aa_is_identified_object(o1) && aa_is_identified_object(o2) { return ar(AR_NO); }
        if (bas_is_argument_like(o1) && aa_is_identified_function_local(o2)) ||
           (bas_is_argument_like(o2) && aa_is_identified_function_local(o1)) { return ar(AR_NO); }
        if aa_is_escape_source(o1) && cc_nothing(aq_captures_before(q, o2, if is_inst(o1) { o1 } else { -1 }, true, false)) { return ar(AR_NO); }
        if aa_is_escape_source(o2) && cc_nothing(aq_captures_before(q, o1, if is_inst(o2) { o2 } else { -1 }, true, false)) { return ar(AR_NO); }
    }
    let null_valid = bas_null_defined(0);
    if bas_object_smaller_than(o2, bas_minimal_extent(v1, s1, null_valid), null_valid) ||
       bas_object_smaller_than(o1, bas_minimal_extent(v2, s2, null_valid), null_valid) { return ar(AR_NO); }
    if bas_separate_storage(o1, o2, v1, v2, cxt) { return ar(AR_NO); }
    if ls_may_be_before(s1) || ls_may_be_before(s2) { s1 = LS_AFTER; s2 = LS_AFTER; }
    if aqs[q].depth >= 512 { return ar(AR_MAY); }
    let cross = aqs[q].cross;
    let swapped = v1 > v2;
    var k1 = v1;
    var k2 = v2;
    var ks1 = s1;
    var ks2 = s2;
    if swapped { k1 = v2; k2 = v1; ks1 = s2; ks2 = s1; }
    let found = ae_find(q, AEK_ALIAS, k1, ks1, k2, ks2, cross);
    if found >= 0 {
        if aent[found].nau != AE_DEFINITIVE {
            aqs[q].nau += 1;
            if aent[found].nau >= 0 { aent[found].nau += 1; }
        }
        return ar_swap(aent[found].res, swapped);
    }
    let e = ae_insert(q, AEK_ALIAS, k1, ks1, k2, ks2, cross);
    let orig_nau = aqs[q].nau;
    let orig_abr = aq_abr.len;
    var result = bas_alias_check_recursive(v1, s1, v2, s2, q, o1, o2);
    let disproven = aent[e].nau > 0 && result.k != AR_NO as u8;
    if disproven { result = ar(AR_MAY); }
    aqs[q].nau -= aent[e].nau;
    aent[e].res = ar_swap(result, swapped);
    if disproven {
        while aq_abr.len > orig_abr { let x = aq_abr.pop(); ae_erase_key_of(x); }
    }
    if orig_nau != aqs[q].nau && result.k != AR_MAY as u8 {
        aq_abr.push(e);
        aent[e].nau = AE_ASSUMPTION_BASED;
    } else {
        aent[e].nau = AE_DEFINITIVE;
    }
    if aqs[q].depth == 1 {
        var i = aqs[q].abr_base as i64;
        while i < aq_abr.len {
            let x = aq_abr[i];
            let ex = aent[x];
            let j = ae_find(ex.q, ex.kind, ex.p1, ex.s1, ex.p2, ex.s2, ex.cross);
            if j >= 0 { aent[j].nau = AE_DEFINITIVE; }
            i++;
        }
        aq_abr.resize(aqs[q].abr_base as i64);
        aqs[q].nau = 0;
    }
    return result;
}

// aliasCheckRecursive
recursive fn bas_alias_check_recursive(v1: i32, s1: u64, v2: i32, s2: u64, q: i32, o1: i32, o2: i32) -> AR {
    if bas_is_gep_operator(v1) {
        let r = bas_alias_gep(v1, s1, v2, s2, o1, o2, q);
        if r.k != AR_MAY as u8 { return r; }
    } else if bas_is_gep_operator(v2) {
        let r = ar_swap(bas_alias_gep(v2, s2, v1, s1, o2, o1, q), true);
        if r.k != AR_MAY as u8 { return r; }
    }
    if is_inst_op(v1, OP_PHI) {
        let r = bas_alias_phi(v1, s1, v2, s2, q);
        if r.k != AR_MAY as u8 { return r; }
    } else if is_inst_op(v2, OP_PHI) {
        let r = ar_swap(bas_alias_phi(v2, s2, v1, s1, q), true);
        if r.k != AR_MAY as u8 { return r; }
    }
    if is_inst_op(v1, OP_SELECT) {
        let r = bas_alias_select(v1, s1, v2, s2, q);
        if r.k != AR_MAY as u8 { return r; }
    } else if is_inst_op(v2, OP_SELECT) {
        let r = ar_swap(bas_alias_select(v2, s2, v1, s1, q), true);
        if r.k != AR_MAY as u8 { return r; }
    }
    if o1 == o2 {
        let null_valid = bas_null_defined(0);
        if ls_is_precise(s1) && ls_is_precise(s2) &&
           (bas_is_object_size(o1, s1, null_valid) || bas_is_object_size(o2, s2, null_valid)) { return ar(AR_PARTIAL); }
    }
    return ar(AR_MAY);
}

// BasicAAResult::aliasErrno: true = MayAlias
fn bas_alias_errno_may(loc: ML) -> bool {
    if ls_has_value(loc.size) && ls_value(loc.size) * 8 > (tli_int_bits() as u64) { return false; }
    if aa_is_identified_function_local(get_underlying_object(loc.ptr, BAS_MAX_LOOKUP)) { return false; }
    return true;
}

// BasicAAResult::getModRefInfoMask
fn bas_mod_ref_mask(loc: ML, ignore_locals: bool) -> i64 {
    var max_lookup = 8;
    var wl: i32[>..<] = [];
    wl.push(loc.ptr);
    var result = MR_NO;
    ss_clear(SS_MASK);
    loop {
        let v = get_underlying_object(wl.pop(), BAS_MAX_LOOKUP);
        var skip = !ss_add(SS_MASK, v);
        if !skip && ignore_locals && is_inst_op(v, OP_ALLOCA) { skip = true; }
        if !skip {
            if is_arg(v) && aa_arg_noalias(v) && ml_arg_only_reads(v) {
                result |= MR_REF;
            } else if vals[v].kind == VK_GVAR {
                if globs[glob_of(v)].is_const == 0 { return MR_MODREF; }
            } else if is_inst_op(v, OP_SELECT) {
                wl.push(op(v, 1));
                wl.push(op(v, 2));
            } else if is_inst_op(v, OP_PHI) {
                if nops(v) > max_lookup { return MR_MODREF; }
                for k in nops(v) { wl.push(op(v, k)); }
            } else {
                return MR_MODREF;
            }
        }
        if wl.len == 0 { break; }
        max_lookup--;
        if max_lookup == 0 { break; }
    }
    if wl.len > 0 { return MR_MODREF; }
    return result;
}

// BasicAAResult::getMemoryEffects(Call)
fn bas_call_me(c: i32, q: i32) -> u64 {
    var mn = aset_memory(alist_fn(insts[inst_of(c)].attrs));
    let f = cb_callee(c);
    if is_func(f) {
        var fme = aa_fn_me(f);
        if call_has_reading_bundles(c) { fme |= me_of(MR_REF); }
        if call_has_clobbering_bundles(c) { fme |= me_of(MR_MOD); }
        if inst_is_volatile(c) { fme |= me_loc_only(LOC_INACCESSIBLE, MR_MODREF); }
        mn &= fme;
    }
    return mn;
}

// BasicAAResult::getMemoryEffects(F)
fn bas_fn_me(f: i32) -> u64 {
    let id = func_iid(f) as i32;
    if id == IID_experimental_guard || id == IID_experimental_deoptimize {
        return me_of(MR_REF) | me_loc_only(LOC_INACCESSIBLE, MR_MODREF);
    }
    return ml_func_memory_effects(f);
}

// BasicAAResult::getArgModRefInfo
fn bas_arg_mod_ref(c: i32, k: i64) -> i64 {
    if cb_arg_no_memory(c, k) { return MR_NO; }
    if cb_arg_only_writes(c, k) { return MR_MOD; }
    if cb_arg_only_reads(c, k) { return MR_REF; }
    return MR_MODREF;
}

// BasicAAResult::getModRefInfo(Call, Loc)
recursive fn bas_call_loc_mr(c: i32, loc: ML, q: i32) -> i64 {
    let obj = get_underlying_object(loc.ptr, BAS_MAX_LOOKUP);
    if is_inst_op(obj, OP_ALLOCA) && iop(c) == OP_CALL && cb_is_tail_call(c) && !cb_has_attr_somewhere(c, AK_ByVal) { return MR_NO; }
    if is_inst_op(obj, OP_ALLOCA) && !ml_is_static_alloca(obj) && inst_iid(c) == IID_stackrestore { return MR_MOD; }
    let me = me_without(aa_call_me(c, q), LOC_INACCESSIBLE);
    if me == 0 { return MR_NO; }
    var arg_mr = me_get(me, LOC_ARG);
    let errno_mr = me_get(me, LOC_ERRNO);
    var other_mr = me_get(me, LOC_OTHER);
    var sync_mr = MR_NO;
    if other_mr == MR_MODREF && inst_may_synchronize(c) && cb_is_inline_asm(c) {
        sync_mr = aa_sync_effects(loc, q);
        if sync_mr == MR_MODREF { return sync_mr; }
    }
    if mr_any(other_mr) && !is_constant(obj) && c != obj && (is_inst_op(obj, OP_ALLOCA) || !call_has_fn_attr(c, AK_ReturnsTwice)) {
        let cc = aq_captures_before(q, obj, c, false, false);
        if cc_nothing(cc) { other_mr = MR_NO; }
        else if cc_read_provenance_only(cc) { other_mr = MR_REF; }
    }
    if (arg_mr | other_mr) != other_mr {
        var new_arg = MR_NO;
        let n = cb_nargs(c) + cb_bundle_ops(c);
        let na = cb_nargs(c);
        var k: i64 = 0;
        while k < n {
            let a = op(c, k);
            if ty_kind(vals[a].ty) != TK_PTR { k++; continue; }
            let aloc = if k < na { ml_for_argument(c, k, true) } else { ml_before_or_after(a) };
            let r = aa_alias(aloc, loc, q, c);
            if r.k != AR_NO as u8 { new_arg |= arg_mr & aa_arg_mod_ref(c, k); }
            if new_arg == arg_mr { break; }
            k++;
        }
        arg_mr = new_arg;
    }
    var result = arg_mr | other_mr | sync_mr;
    if (errno_mr | result) != result {
        if aa_alias_errno_may(loc) { result |= errno_mr; }
    }
    if result != MR_MODREF { return result; }
    if bas_is_malloc_or_calloc_like(c) {
        let r = aa_alias(ml_before_or_after(c), loc, q, -1);
        if r.k == AR_NO as u8 { return MR_NO; }
    }
    if inst_iid(c) == IID_invariant_start { return MR_REF; }
    return MR_MODREF;
}

// BasicAAResult::getModRefInfo(Call1, Call2)
fn bas_call_call_mr(c1: i32, c2: i32, q: i32) -> i64 {
    if inst_iid(c1) == IID_experimental_guard {
        return if mr_is_mod(me_modref(bas_call_me(c2, q))) { MR_REF } else { MR_NO };
    }
    if inst_iid(c2) == IID_experimental_guard {
        return if mr_is_mod(me_modref(bas_call_me(c1, q))) { MR_MOD } else { MR_NO };
    }
    return MR_MODREF;
}
