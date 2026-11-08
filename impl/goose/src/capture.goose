// CaptureTracking: port of llvm/lib/Analysis/CaptureTracking.cpp (PointerMayBeCaptured with the
// SimpleCaptureTracker, CapturesBefore and EarliestCaptures trackers, PointerMayBeCapturedBefore,
// FindEarliestCapture, DetermineUseCaptureKind) and isIntrinsicReturningPointerAliasingArgumentWithoutCapturing
// (ValueTracking.cpp). The tracker is data (a kind plus its state in ct_*); the virtual callbacks are a match.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import domtree;
import pm;
import memloc;
import aautil;
import flags;
import intrinsics;

let CT_MAX_USES_DEFAULT: i64 = 100;      // -capture-tracking-max-uses-to-explore

var ct_max_uses_flag: i64 = -1;
fn ct_max_uses() -> i64 {
    if ct_max_uses_flag < 0 { ct_max_uses_flag = flag_int("capture-tracking-max-uses-to-explore", CT_MAX_USES_DEFAULT); }
    return ct_max_uses_flag;
}

// isIntrinsicReturningPointerAliasingArgumentWithoutCapturing
fn ct_intrinsic_returns_aliasing_arg(c: i32, must_preserve_offset: bool) -> bool {
    let id = call_iid(c);
    if id == 0 { return false; }
    if id == IID_launder_invariant_group || id == IID_strip_invariant_group { return true; }
    if id == IID_ptrmask { return !must_preserve_offset; }
    if id == IID_threadlocal_address { return !func_has_fn_attr(inst_func(c), AK_PresplitCoroutine); }
    let nm = intr_name_of(id);
    if nm == "llvm.aarch64.irg" || nm == "llvm.aarch64.tagp" || nm == "llvm.amdgcn.make.buffer.rsrc" { return true; }
    return false;
}
fn intr_name_of(id: i32) -> const u8[:] { intr_name(id as i64) }

// MemIntrinsic (memcpy, memcpy.inline, memmove, memset, memset.inline, experimental.memset.pattern)
fn ct_is_mem_intrinsic(c: i32) -> bool {
    let id = inst_iid(c);
    return id != 0 && (is_mem_intrinsic_id(id) || id == IID_experimental_memset_pattern);
}

// MDNode::toCaptureComponents
fn ct_md_capture_components(md: i32) -> i64 {
    if md < 0 { return CC_ALL; }
    var cc: i64 = 0;
    for k in mds[md].nops {
        let s = md_op(md, k);
        if s < 0 || mds[s].kind != MK_STRING { continue; }
        let t = sbytes(mds[s].extra);
        if t == "address" { cc |= CC_ADDRESS; }
        else if t == "address_is_null" { cc |= CC_ADDRESS_IS_NULL; }
        else if t == "provenance" { cc |= CC_PROVENANCE; }
        else if t == "read_provenance" { cc |= CC_READ_PROVENANCE; }
    }
    return cc;
}

// UseCaptureInfo as (UseCC, ResultCC)
struct UCI { use_cc: i64, result_cc: i64 }
fn uci(u: i64) -> UCI { UCI { use_cc: u, result_cc: 0 } }
fn uci_passthrough() -> UCI { UCI { use_cc: 0, result_cc: CC_ALL } }

// DetermineUseCaptureKind(U, Base)
fn ct_use_capture_kind(u: i32, base: i32) -> UCI {
    let user = uses[u].user;
    if !is_inst(user) { return uci(CC_ALL); }
    let opno = (u - vals[user].ops) as i64;
    let o = iop(user);
    if o == OP_CALL || o == OP_INVOKE {
        if ct_intrinsic_returns_aliasing_arg(user, false) { return uci_passthrough(); }
        if opno == nops(user) - 1 { return uci(CC_NONE); }
        var vcc: i64 = 0;
        if ct_is_mem_intrinsic(user) && inst_is_volatile(user) { vcc |= CC_ADDRESS; }
        let ci = cb_capture_info(user, opno);
        var mask = CC_ALL;
        if call_only_reads_memory(user) && ty_kind(vals[user].ty) == TK_VOID { mask = CC_ADDRESS; }
        return UCI { use_cc: (ci_other(ci) & mask) | vcc, result_cc: ci_ret(ci) };
    }
    let vol = (insts[inst_of(user)].bits & 1) != 0;
    if o == OP_LOAD { return uci(if vol { CC_ADDRESS } else { CC_NONE }); }
    if o == OP_VAARG { return uci(CC_NONE); }
    if o == OP_STORE {
        if opno == 0 { return uci(ct_md_capture_components(inst_get_md(user, MDK_CAPTURES))); }
        return uci(if vol { CC_ADDRESS } else { CC_NONE });
    }
    if o == OP_ATOMICRMW {
        if opno == 1 { return uci(CC_ALL); }
        return uci(if vol { CC_ADDRESS } else { CC_NONE });
    }
    if o == OP_CMPXCHG {
        if opno == 1 || opno == 2 { return uci(CC_ALL); }
        return uci(if vol { CC_ADDRESS } else { CC_NONE });
    }
    if o == OP_GEP {
        if ty_is_vector(vals[user].ty) { return uci(CC_ALL); }
        return uci_passthrough();
    }
    if o == OP_BITCAST || o == OP_PHI || o == OP_SELECT || o == OP_ADDRSPACECAST { return uci_passthrough(); }
    if o == OP_PTRTOADDR { return uci(CC_ADDRESS); }
    if o == OP_ICMP {
        let other = op(user, 1 - opno);
        let p = inst_pred(user);
        if vals[other].kind == VK_CNULL && !ty_is_vector(vals[other].ty) && (p == 32 || p == 33) && uses[u].val == base {
            return uci(CC_ADDRESS_IS_NULL);
        }
        return uci(CC_ADDRESS);
    }
    return uci(CC_ALL);
}

// ---------------------------------------------------------------------------------------------
// Trackers

let CTK_SIMPLE = 0;
let CTK_BEFORE = 1;
let CTK_EARLIEST = 2;

let CT_STOP_ANY = 0;            // capturesAnything
let CT_STOP_FULL_PROV = 1;      // capturesFullProvenance
let CT_STOP_NEVER = 2;

let CTA_STOP = 0;
let CTA_CONTINUE = 1;
let CTA_CONTINUE_IGNORING_RETURN = 2;

var ct_kind: i64 = 0;
var ct_mask: i64 = 0;
var ct_stop: i64 = 0;
var ct_cc: i64 = 0;
var ct_cc_ret: i64 = 0;
var ct_before: i32 = -1;            // CapturesBefore::BeforeHere
var ct_return_captures: bool = false;
var ct_include_i: bool = false;
var ct_use_li: bool = false;
var ct_earliest: i32 = -1;          // EarliestCaptures::EarliestCapture
var ct_fn: i32 = -1;

fn ct_stop_fn(cc: i64) -> bool {
    if ct_stop == CT_STOP_ANY { return cc_anything(cc); }
    if ct_stop == CT_STOP_FULL_PROV { return cc_full_provenance(cc); }
    return false;
}

fn ct_too_many_uses() {
    if ct_kind == CTK_SIMPLE { ct_cc = ct_mask; ct_cc_ret = ct_mask; }
    else if ct_kind == CTK_BEFORE { ct_cc = ct_mask; }
    else {
        ct_cc = ct_mask;
        ct_cc_ret = ct_mask;
        ct_earliest = block_first(func_entry(ct_fn));
    }
}

// CapturesBefore::isSafeToPrune
fn ct_safe_to_prune(i: i32) -> bool {
    if ct_before == i { return !ct_include_i; }
    if !dt_has_node(DT_DOM, inst_parent(i)) { return true; }
    return !cfr_inst_reachable(i, ct_before, true, ct_use_li, false);
}

// DominatorTree::findNearestCommonDominator(Instruction, Instruction)
fn ct_ncd_inst(a: i32, b: i32) -> i32 {
    let ba = inst_parent(a);
    let bb = inst_parent(b);
    if ba == bb { return if comes_before(a, b) { a } else { b }; }
    if !dt_has_node(DT_DOM, bb) { return a; }
    if !dt_has_node(DT_DOM, ba) { return b; }
    let d = dt_find_ncd(DT_DOM, ba, bb);
    if d == ba { return a; }
    if d == bb { return b; }
    return block_terminator(d);
}

fn ct_captured(u: i32, c: UCI) -> i64 {
    let user = uses[u].user;
    let is_ret = is_inst_op(user, OP_RET);
    if ct_kind == CTK_SIMPLE {
        if cc_nothing(c.use_cc & ct_mask) { return CTA_CONTINUE; }
        ct_cc_ret |= c.use_cc & ct_mask;
        if !is_ret { ct_cc |= c.use_cc & ct_mask; }
        return if ct_stop_fn(ct_cc) { CTA_STOP } else { CTA_CONTINUE };
    }
    if ct_kind == CTK_BEFORE {
        if is_ret && !ct_return_captures { return CTA_CONTINUE_IGNORING_RETURN; }
        if ct_safe_to_prune(user) { return CTA_CONTINUE_IGNORING_RETURN; }
        if cc_nothing(c.use_cc & ct_mask) { return CTA_CONTINUE; }
        ct_cc |= c.use_cc & ct_mask;
        return if ct_stop_fn(ct_cc) { CTA_STOP } else { CTA_CONTINUE };
    }
    if cc_anything(c.use_cc & ct_mask) {
        ct_cc_ret |= c.use_cc & ct_mask;
        if !is_ret {
            ct_earliest = if ct_earliest < 0 { user } else { ct_ncd_inst(ct_earliest, user) };
            ct_cc |= c.use_cc & ct_mask;
        }
    }
    return CTA_CONTINUE;
}

// PointerMayBeCaptured(V, Tracker, MaxUsesToExplore) with the tracker in ct_*
fn ct_walk(v: i32, max_uses0: i64) {
    let max_uses = if max_uses0 == 0 { ct_max_uses() } else { max_uses0 };
    var wl: i32[>..<] = [];
    ss_clear(SS_CT_USES);
    fn add_uses(x: i32) -> bool {
        var u = vals[x].first_use;
        while u >= 0 {
            if ss_size(SS_CT_USES) >= max_uses { ct_too_many_uses(); return false; }
            if ss_add(SS_CT_USES, u) { wl.push(u); }
            u = uses[u].next;
        }
        return true;
    }
    if !add_uses(v) { return; }
    while wl.len > 0 {
        let u = wl.pop();
        let c = ct_use_capture_kind(u, v);
        if cc_anything(c.use_cc) {
            let a = ct_captured(u, c);
            if a == CTA_STOP { return; }
            if a == CTA_CONTINUE_IGNORING_RETURN { continue; }
            if cc_nothing(c.result_cc & ~c.use_cc & 15) { continue; }
        }
        if cc_anything(c.result_cc) && !add_uses(uses[u].user) { return; }
    }
}

// PointerMayBeCaptured(V, Mask, StopFn) -> (WithoutRet, WithRet)
fn ct_pointer_may_be_captured(v: i32, mask: i64, stop: i64, max_uses: i64) -> i64, i64 {
    ct_kind = CTK_SIMPLE;
    ct_mask = mask;
    ct_stop = stop;
    ct_cc = 0;
    ct_cc_ret = 0;
    ct_walk(v, max_uses);
    return ct_cc, ct_cc_ret;
}

// PointerMayBeCaptured(V, ReturnCaptures)
fn ct_may_be_captured_bool(v: i32, return_captures: bool) -> bool {
    let wo, wr = ct_pointer_may_be_captured(v, CC_ALL, CT_STOP_ANY, 0);
    return cc_anything(if return_captures { wr } else { wo });
}

// PointerMayBeCapturedBefore(V, ReturnCaptures, I, DT, IncludeI, Mask, StopFn, LI) (DT always given)
fn ct_may_be_captured_before(v: i32, return_captures: bool, i: i32, include_i: bool, mask: i64, stop: i64, use_li: bool) -> i64 {
    ct_kind = CTK_BEFORE;
    ct_mask = mask;
    ct_stop = stop;
    ct_cc = 0;
    ct_cc_ret = 0;
    ct_before = i;
    ct_return_captures = return_captures;
    ct_include_i = include_i;
    ct_use_li = use_li;
    ct_walk(v, 0);
    return ct_cc;
}

// FindEarliestCapture(V, F, DT, Mask) -> (EarliestCapture inst or -1, WithoutRet, WithRet)
fn ct_find_earliest_capture(v: i32, fv: i32, mask: i64) -> i32, i64, i64 {
    ct_kind = CTK_EARLIEST;
    ct_mask = mask;
    ct_stop = CT_STOP_NEVER;
    ct_cc = 0;
    ct_cc_ret = 0;
    ct_earliest = -1;
    ct_fn = fv;
    ct_walk(v, 0);
    return ct_earliest, ct_cc, ct_cc_ret;
}
