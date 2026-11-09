// DeadStoreElimination: port of llvm/lib/Transforms/Scalar/DeadStoreElimination.cpp (the MemorySSA-backed
// DSEState: getDomMemoryDef, isOverwrite / isPartialOverwrite with the overlap intervals, partial store merging,
// shortening of memory intrinsics, calloc / alloc-variant-zeroed folding, no-op stores, redundant stores of
// existing values and via dominating conditions, dead writes at the end of the function, the `initializes`
// attribute with ConstantRangeList::intersectWith (llvm/lib/IR/ConstantRangeList.cpp), memoryIsNotModifiedBetween,
// emitCalloc (llvm/lib/Transforms/Utils/BuildLibCalls.cpp) and every dse cl::opt).
//
// Data: DSEState is the ds_* globals (one run at a time). Maps and sets keyed by values or blocks are fields of
// a per-value-id record (ds_v) stamped with the run's epoch; sets keyed by memory accesses are fields of a
// per-access record (ds_a), each set with its own stamp from one counter (ds_tick), so creating a set is O(1).
// Access and value ids are never reused, so the "reused MemoryAccess address" caveats of the LLVM code don't apply.
// InstOverlapIntervalsTy (MapVector<BasicBlock *, MapVector<Instruction *, std::map<int64_t, int64_t>>>) is a list
// of blocks in first-insertion order, entries linked per block in insertion order (erased entries are dead), and
// each entry's interval map a sorted linked list of (end, start) nodes.
// Not ported (fail loudly): assignment tracking (shortenAssignment's dbg_assign updates), -debug-counter.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import gen_tli;
import datalayout;
import domtree;
import cycleinfo;
import analyses;
import flags;
import tli;
import local;
import pm;
import vt;
import apint;
import dinfo;
import memloc;
import aautil;
import aa;
import capture;
import memorybuiltins;
import memoryssa;
import mssaupdater;
import phitrans;
import instident;
import instsimplify;
import build_libcalls;
import salvage;
import knowledge;
import memintr;

// cl::opts
var ds_opt_partial_overwrite_tracking = true;
var ds_opt_partial_store_merging = true;
var ds_opt_scan_limit: i64 = 150;
var ds_opt_walk_limit: i64 = 90;
var ds_opt_partial_store_limit: i64 = 5;
var ds_opt_defs_per_block_limit: i64 = 5000;
var ds_opt_same_bb_cost: i64 = 1;
var ds_opt_other_bb_cost: i64 = 5;
var ds_opt_path_check_limit: i64 = 50;
var ds_opt_optimize_mssa = true;
var ds_opt_initializes = true;
var ds_opt_max_depth: i64 = 1024;

fn ds_read_flags() {
    ds_opt_partial_overwrite_tracking = flag_bool("enable-dse-partial-overwrite-tracking", true);
    ds_opt_partial_store_merging = flag_bool("enable-dse-partial-store-merging", true);
    ds_opt_scan_limit = flag_int("dse-memoryssa-scanlimit", 150);
    ds_opt_walk_limit = flag_int("dse-memoryssa-walklimit", 90);
    ds_opt_partial_store_limit = flag_int("dse-memoryssa-partial-store-limit", 5);
    ds_opt_defs_per_block_limit = flag_int("dse-memoryssa-defs-per-block-limit", 5000);
    ds_opt_same_bb_cost = flag_int("dse-memoryssa-samebb-cost", 1);
    ds_opt_other_bb_cost = flag_int("dse-memoryssa-otherbb-cost", 5);
    ds_opt_path_check_limit = flag_int("dse-memoryssa-path-check-limit", 50);
    ds_opt_optimize_mssa = flag_bool("dse-optimize-memoryssa", true);
    ds_opt_initializes = flag_bool("enable-dse-initializes-attr-improvement", true);
    ds_opt_max_depth = flag_int("dse-max-dom-cond-depth", 1024);
}

// OverwriteResult
let OW_BEGIN = 0;
let OW_COMPLETE = 1;
let OW_END = 2;
let OW_PARTIAL_EARLIER_WITH_FULL_LATER = 3;
let OW_MAYBE_PARTIAL = 4;
let OW_NONE = 5;
let OW_UNKNOWN = 6;

// ---------------------------------------------------------------------------------------------
// State

// per value id (blocks and values); fields valid when st == ds_epoch, set fields are stamps
struct DsV { st: i32, po: i32, has_po: bool, thr: bool,
             cbr_has: bool, cbr: bool, inv_has: bool, inv: bool, bnd_has: bool, bnd: u64,
             iol_has: bool, iol_first: i32, iol_last: i32, iol_ent: i32,
             kb: i32, wl: i32, vis: i32, vis_ptr: i32 }
var ds_v: DsV[>..];
// per memory access id
struct DsA { skip: i32, del: i32, vis: i32, tc: i32, tc2: i32 }
var ds_a: DsA[>..];
var ds_epoch: i32 = 0;
var ds_tick: i32 = 0;
fn ds_new_tick() -> i32 { ds_tick++; return ds_tick; }

var ds_fn: i32 = -1;
var ds_q: i32 = -1;                    // the BatchAAResults (with the EarliestEscapeAnalysis)
var ds_memdefs: i32[>..<];
var ds_any_throwing: bool = false;     // !ThrowingBlocks.empty()
var ds_any_unreachable_exit: bool = false;
var ds_iterate_eof: bool = false;      // ShouldIterateEndOfFunctionDSE
var ds_to_remove: i32[>..<];
var ds_skip_count: i64 = 0;

// IOLs
struct DsIolE { bb: i32, inst: i32, alive: bool, head: i32, next: i32 }
struct DsIv { end: i64, start: i64, next: i32 }
var ds_iol_blocks: i32[>..<];
var ds_iol: DsIolE[>..<];
var ds_iv: DsIv[>..<];

fn ds_vr(v: i32) -> i64 {
    let k = v as i64;
    while ds_v.len <= k {
        ds_v.push(DsV { st: 0, po: 0, has_po: false, thr: false, cbr_has: false, cbr: false, inv_has: false, inv: false,
                        bnd_has: false, bnd: 0, iol_has: false, iol_first: -1, iol_last: -1, iol_ent: -1,
                        kb: 0, wl: 0, vis: 0, vis_ptr: -1 });
    }
    if ds_v[k].st != ds_epoch {
        ds_v[k] = DsV { st: ds_epoch, po: 0, has_po: false, thr: false, cbr_has: false, cbr: false, inv_has: false,
                        inv: false, bnd_has: false, bnd: 0, iol_has: false, iol_first: -1, iol_last: -1, iol_ent: -1,
                        kb: 0, wl: 0, vis: 0, vis_ptr: -1 };
    }
    return k;
}
fn ds_ar(a: i32) -> i64 {
    let k = a as i64;
    while ds_a.len <= k { ds_a.push(DsA { skip: 0, del: 0, vis: 0, tc: 0, tc2: 0 }); }
    return k;
}
fn ds_skipped(a: i32) -> bool { let r = ds_ar(a); return ds_a[r].skip == ds_epoch; }

// PostOrderNumbers[BB] (operator[] inserts 0; find() of an unreachable block never happens in LLVM)
fn ds_po(bv: i32) -> i32 { let r = ds_vr(bv); return ds_v[r].po; }

// ---------------------------------------------------------------------------------------------
// Helpers

fn ds_is_shortenable_at_the_end(i: i32) -> bool {
    if iop(i) == OP_STORE { return false; }
    let id = inst_iid(i);
    if id == 0 { return false; }
    return id == IID_memset || id == IID_memcpy || id == IID_memcpy_element_unordered_atomic ||
        id == IID_memset_element_unordered_atomic;
}
fn ds_is_shortenable_at_the_beginning(i: i32) -> bool { mi_is_any_memset(i) }

// getPointerSize(V, DL, TLI, F)
fn ds_pointer_size(v: i32) -> bool, u64 {
    let nd = null_pointer_is_defined(ds_fn, ptr_as(vals[v].ty));
    return mb_get_object_size(v, OSM_EXACT_SIZE_FROM_OFFSET, false, nd, false);
}

fn ds_uo(p: i32) -> i32 { get_underlying_object(p, 10) }
fn ds_is_dsef(a: i32) -> bool { a >= 0 && (macc[a].kind == MAK_DEF || macc[a].kind == MAK_LIVE) }

// GetPointerBaseWithConstantOffset(Ptr, Offset, DL)
fn ds_base_offset(p: i32) -> i32, i64 {
    let b = strip_and_accumulate_offsets(p, true, false, false);
    return b, vt_off;
}

// isMaskedStoreOverwrite
fn ds_masked_store_overwrite(ki: i32, di: i32) -> i64 {
    let kid = inst_iid(ki);
    let did = inst_iid(di);
    if kid == 0 || did == 0 { return OW_UNKNOWN; }
    if kid != did { return OW_UNKNOWN; }
    if kid != IID_masked_store && kid != IID_vp_store { return OW_UNKNOWN; }
    let kt = vals[cb_arg(ki, 0)].ty;
    let dt = vals[cb_arg(di, 0)].ty;
    if dl_size_bits(kt) != dl_size_bits(dt) || ty_size_scalable(kt) != ty_size_scalable(dt) { return OW_UNKNOWN; }
    if ty_count(kt) != ty_count(dt) || (ty_kind(kt) == TK_SVEC) != (ty_kind(dt) == TK_SVEC) { return OW_UNKNOWN; }
    let kp = cb_arg(ki, 1);
    let dp = cb_arg(di, 1);
    if kp != dp && !aa_is_must_alias_vals(kp, dp, ds_q) { return OW_UNKNOWN; }
    if kid == IID_masked_store {
        if cb_arg(ki, 2) != cb_arg(di, 2) { return OW_UNKNOWN; }
    } else {
        if cb_arg(ki, 2) != cb_arg(di, 2) { return OW_UNKNOWN; }
        if cb_arg(ki, 3) != cb_arg(di, 3) { return OW_UNKNOWN; }
    }
    return OW_COMPLETE;
}

// IOLs[BB] (creates the block's map)
fn ds_iol_block(bb: i32) {
    let r = ds_vr(bb);
    if !ds_v[r].iol_has { ds_v[r].iol_has = true; ds_iol_blocks.push(bb); }
}
// IOL[DeadI] (creates the entry)
fn ds_iol_entry(bb: i32, i: i32) -> i32 {
    let r = ds_vr(i);
    let e = ds_v[r].iol_ent;
    if e >= 0 { return e; }
    let ne = ds_iol.len as i32;
    ds_iol.push(DsIolE { bb: bb, inst: i, alive: true, head: -1, next: -1 });
    ds_v[r].iol_ent = ne;
    let br = ds_vr(bb);
    if ds_v[br].iol_last >= 0 { ds_iol[ds_v[br].iol_last].next = ne; } else { ds_v[br].iol_first = ne; }
    ds_v[br].iol_last = ne;
    return ne;
}
// IOLs.find(BB)->second.erase(I)
fn ds_iol_erase(i: i32) {
    let r = ds_vr(i);
    let e = ds_v[r].iol_ent;
    if e < 0 { return; }
    let br = ds_vr(ds_iol[e].bb);
    if !ds_v[br].iol_has { return; }
    ds_iol[e].alive = false;
    ds_v[r].iol_ent = -1;
}

// isPartialOverwrite
fn ds_is_partial_overwrite(kloc: ML, dloc: ML, koff: i64, doff: i64, di: i32) -> i64 {
    let ksize = ls_value(kloc.size);
    let dsize = ls_value(dloc.size);
    let dend = ((doff as! u64) + dsize) as! i64;
    let kend = ((koff as! u64) + ksize) as! i64;
    if ds_opt_partial_overwrite_tracking && koff < dend && kend >= doff {
        let e = ds_iol_entry(inst_parent(di), di);
        var ks = koff;
        var ke = kend;
        // lower_bound(ks): the first interval whose end >= ks
        var prev: i32 = -1;
        var it = ds_iol[e].head;
        while it >= 0 && ds_iv[it].end < ks { prev = it; it = ds_iv[it].next; }
        if it >= 0 && ds_iv[it].start <= ke {
            ks = min(ks, ds_iv[it].start);
            ke = max(ke, ds_iv[it].end);
            it = ds_iv[it].next;
            while it >= 0 && ds_iv[it].start <= ke {
                ke = max(ke, ds_iv[it].end);
                it = ds_iv[it].next;
            }
            if prev >= 0 { ds_iv[prev].next = it; } else { ds_iol[e].head = it; }
        }
        // IM[ke] = ks
        var p2: i32 = -1;
        var x = ds_iol[e].head;
        while x >= 0 && ds_iv[x].end < ke { p2 = x; x = ds_iv[x].next; }
        if x >= 0 && ds_iv[x].end == ke {
            ds_iv[x].start = ks;
        } else {
            let n = ds_iv.len as i32;
            ds_iv.push(DsIv { end: ke, start: ks, next: x });
            if p2 >= 0 { ds_iv[p2].next = n; } else { ds_iol[e].head = n; }
        }
        let f = ds_iol[e].head;
        if ds_iv[f].start <= doff && ds_iv[f].end >= dend { return OW_COMPLETE; }
    }
    if ds_opt_partial_store_merging && koff >= doff && dend > koff && ((koff - doff) as! u64) + ksize <= dsize {
        return OW_PARTIAL_EARLIER_WITH_FULL_LATER;
    }
    if !ds_opt_partial_overwrite_tracking && koff > doff && koff < dend && kend >= dend { return OW_END; }
    if !ds_opt_partial_overwrite_tracking && koff <= doff && kend > doff { return OW_BEGIN; }
    return OW_UNKNOWN;
}

// memoryIsNotModifiedBetween(FirstI, SecondI, AA, DL, DT)
fn ds_mem_not_modified_between(first: i32, second: i32) -> bool {
    var wl_bb: i32[>..<] = [];
    var wl_addr: i32[>..<] = [];
    var wl_in_at: i64[>..<] = [];
    var wl_in_n: i64[>..<] = [];
    var pool: i32[>..<] = [];
    let vtick = ds_new_tick();
    let fbb = inst_parent(first);
    let sbb = inst_parent(second);
    let loc = if mi_is_memset(second) { ml_for_dest(second) } else { ml_get(second) };
    pta_init(loc.ptr);
    wl_bb.push(sbb);
    wl_addr.push(pta_addr);
    wl_in_at.push(pool.len);
    for x in pta_inputs { pool.push(x); }
    wl_in_n.push(pta_inputs.len);
    var is_first = true;
    var preds: i32[>..<] = [];
    while wl_bb.len > 0 {
        let b = wl_bb.pop();
        let ptr = wl_addr.pop();
        let in_at = wl_in_at.pop();
        let in_n = wl_in_n.pop();
        var bi = if b == fbb { inst_next(first) } else { block_first(b) };
        var ei: i32 = -1;
        if is_first { ei = second; is_first = false; }
        while bi != ei && bi >= 0 {
            if inst_may_write_memory(bi) && bi != second {
                var l = loc;
                l.ptr = ptr;
                if mr_is_mod(aa_inst_loc_mr(bi, l, ds_q)) { return false; }
            }
            bi = inst_next(bi);
        }
        if b != fbb {
            preds.clear();
            each_pred(b) { p => preds.push(p); };
            for pred in preds {
                // PHITransAddr PredAddr = Addr
                pta_addr = ptr;
                pta_inputs.clear();
                for j in in_n { pta_inputs.push(pool[in_at + j]); }
                var needs = false;
                for x in pta_inputs { if inst_parent(x) == b { needs = true; } }
                if needs {
                    if is_inst(pta_addr) && !pta_can_trans(pta_addr) { return false; }
                    if pta_translate_value(b, pred, false) < 0 { return false; }
                }
                let tp = pta_addr;
                let r = ds_vr(pred);
                if ds_v[r].vis == vtick {
                    if tp != ds_v[r].vis_ptr { return false; }
                    continue;
                }
                ds_v[r].vis = vtick;
                ds_v[r].vis_ptr = tp;
                wl_bb.push(pred);
                wl_addr.push(tp);
                wl_in_at.push(pool.len);
                for x in pta_inputs { pool.push(x); }
                wl_in_n.push(pta_inputs.len);
            }
        }
    }
    return true;
}

// adjustArgAttributes(Intrinsic, ArgNo, PtrOffset)
fn ds_adjust_arg_attributes(i: i32, k: i64, off: u64) {
    let s0 = alist_param(insts[inst_of(i)].attrs, k);
    var keep: i32[>..<] = [];
    for j in aset_n(s0) {
        let a = aset_attr(s0, j);
        let kind = attrs[a].kind as i64;
        if kind > 0 {
            if kind == AK_Alignment {
                let al = attrs[a].i1;
                let alv = if al == 0 { 1 as u64 } else { al };
                if off % alv == 0 { keep.push(a); continue; }
            } else if kind == AK_NonNull || kind == AK_NoUndef {
                keep.push(a);
                continue;
            }
        }
    }
    if keep.len == aset_n(s0) { return; }
    mi_set_param_set(i, k, aset_get(keep));
}

// offsetToAlignment(Value, Alignment)
fn ds_offset_to_alignment(v: u64, al: u64) -> u64 { ((al - (v % al)) % al) }

fn ds_has_dbg_assign(i: i32) -> bool {
    // at::getDVRAssignmentMarkers(Inst): records linked through the instruction's DIAssignID
    return inst_get_md(i, md_kind_id("DIAssignID")) >= 0;
}

// tryToShorten(DeadI, DeadStart, DeadSize, KillingStart, KillingSize, IsOverwriteEnd) -> changed, start, size
fn ds_try_to_shorten(di: i32, dstart0: i64, dsize0: u64, kstart: i64, ksize: u64, is_end: bool) -> bool, i64, u64 {
    var dstart = dstart0;
    var dsize = dsize0;
    let pa0 = mi_dest_align(di);
    let pref = if pa0 == 0 { 1 as u64 } else { pa0 };
    var rm_start: i64 = 0;
    var rm_size: u64 = 0;
    if is_end {
        let off = ds_offset_to_alignment((kstart - dstart) as! u64, pref);
        rm_start = ((kstart as! u64) + off) as! i64;
        if dsize <= ((rm_start - dstart) as! u64) { return false, dstart0, dsize0; }
        rm_size = dsize - ((rm_start - dstart) as! u64);
    } else {
        rm_start = dstart;
        rm_size = ksize - ((dstart - kstart) as! u64);
        let off = ds_offset_to_alignment(rm_size, pref);
        if off != 0 {
            if rm_size <= pref - off { return false, dstart0, dsize0; }
            rm_size -= pref - off;
        }
    }
    let new_size = dsize - rm_size;
    if mi_is_atomic(di) {
        let es = mi_element_size(di);
        if new_size % es != 0 { return false, dstart0, dsize0; }
    }
    if ds_has_dbg_assign(di) { fatal("DSE: shortenAssignment (dbg_assign records) is not ported yet"); }
    mi_set_length(di, new_size);
    mi_set_param_align(di, 0, pref);
    let orig = mi_raw_dest(di);
    if !is_end {
        let lt = vals[mi_length(di)].ty;
        let g = create_inst(OP_GEP, vals[orig].ty, [orig, c_int(lt, rm_size as! i64)]);
        insts[inst_of(g)].ty2 = ty_int(8);
        insts[inst_of(g)].flags = GEP_INBOUNDS | GEP_NUSW;
        inst_insert_before(g, di);
        let dl = inst_get_md(di, 0);
        if dl >= 0 { inst_set_md(g, 0, dl); }
        set_op(di, 0, g);
        ds_adjust_arg_attributes(di, 0, rm_size);
    }
    if !is_end { dstart += rm_size as! i64; }
    dsize = new_size;
    return true, dstart, dsize;
}

// tryToShortenEnd / tryToShortenBegin on entry e
fn ds_try_to_shorten_end(di: i32, e: i32, dstart: i64, dsize: u64) -> bool, i64, u64 {
    if ds_iol[e].head < 0 || !ds_is_shortenable_at_the_end(di) { return false, dstart, dsize; }
    // --IntervalMap.end()
    var prev: i32 = -1;
    var last = ds_iol[e].head;
    while ds_iv[last].next >= 0 { prev = last; last = ds_iv[last].next; }
    let kstart = ds_iv[last].start;
    let ksize = (ds_iv[last].end - kstart) as! u64;
    if kstart > dstart && ((kstart - dstart) as! u64) < dsize && ksize >= dsize - ((kstart - dstart) as! u64) {
        let ok, ns, nz = ds_try_to_shorten(di, dstart, dsize, kstart, ksize, true);
        if ok {
            if prev >= 0 { ds_iv[prev].next = -1; } else { ds_iol[e].head = -1; }
            return true, ns, nz;
        }
    }
    return false, dstart, dsize;
}
fn ds_try_to_shorten_begin(di: i32, e: i32, dstart: i64, dsize: u64) -> bool, i64, u64 {
    if ds_iol[e].head < 0 || !ds_is_shortenable_at_the_beginning(di) { return false, dstart, dsize; }
    let f = ds_iol[e].head;
    let kstart = ds_iv[f].start;
    let ksize = (ds_iv[f].end - kstart) as! u64;
    if kstart <= dstart && ksize > ((dstart - kstart) as! u64) {
        let ok, ns, nz = ds_try_to_shorten(di, dstart, dsize, kstart, ksize, false);
        if ok {
            ds_iol[e].head = ds_iv[f].next;
            return true, ns, nz;
        }
    }
    return false, dstart, dsize;
}

// tryToMergePartialOverlappingStores: the merged constant or -1
fn ds_try_merge_partial_stores(ki: i32, di: i32, koff: i64, doff: i64) -> i32 {
    let dv = op(di, 0);
    let kv = op(ki, 0);
    let dt = vals[dv].ty;
    let kt = vals[kv].ty;
    if vals[dv].kind != VK_CINT || ty_is_vector(dt) || dl_size_bits(dt) != dl_store_size(dt) * 8 ||
       vals[kv].kind != VK_CINT || ty_is_vector(kt) || dl_size_bits(kt) != dl_store_size(kt) * 8 ||
       !ds_mem_not_modified_between(di, ki) { return -1; }
    if !ldst_is_unordered(ki) || !ldst_is_unordered(di) || insts[inst_of(ki)].ord != insts[inst_of(di)].ord { return -1; }
    let dval = ci_ap(dv);
    var kval = ci_ap(kv);
    let kbits = kval.w as i64;
    let w = dval.w as i64;
    kval = ap_zext(kval, w);
    let bit_off = ((koff - doff) * 8) as! u32 as i64;
    let lsh = if dl_big_endian { w - bit_off - kbits } else { bit_off };
    let mask = ap_bits_set(w, lsh, lsh + kbits);
    let merged = ap_or(ap_and(dval, ap_not(mask)), ap_shl(kval, lsh));
    return ap_to_cint(dt, merged);
}

// isNoopIntrinsic
fn ds_is_noop_intrinsic(i: i32) -> bool {
    let id = inst_iid(i);
    if id == 0 { return false; }
    return id == IID_lifetime_start || id == IID_lifetime_end || id == IID_invariant_end ||
        id == IID_launder_invariant_group || id == IID_assume;
}

fn ds_only_inaccessible(i: i32) -> bool { me_without(call_memory_effects(i), LOC_INACCESSIBLE) == 0 }
fn ds_only_inaccessible_or_arg(i: i32) -> bool {
    return me_without(me_without(call_memory_effects(i), LOC_INACCESSIBLE), LOC_ARG) == 0;
}

// canSkipDef(D, DefVisibleToCaller)
fn ds_can_skip_def(d: i32, visible: bool) -> bool {
    let di = macc[d].inst;
    if is_callbase(di) && ds_only_inaccessible(di) { return true; }
    if inst_may_throw(di) && !visible { return true; }
    if iop(di) == OP_FENCE { return true; }
    if ds_is_noop_intrinsic(di) { return true; }
    return false;
}

fn ds_has_initializes_attr(i: i32) -> bool { is_callbase(i) && call_arg_with_attr(i, AK_Initializes) >= 0 }

// ---------------------------------------------------------------------------------------------
// DSEState queries

// strengthenLocationSize
fn ds_strengthen_size(i: i32, size: u64) -> u64 {
    if is_callbase(i) {
        let lf = ml_call_libfunc(i);
        if lf >= 0 && tli_has(lf) && (lf == LF_memset_chk as i32 || lf == LF_memcpy_chk as i32) {
            let l = cb_arg(i, 2);
            if vals[l].kind == VK_CINT && !ty_is_vector(vals[l].ty) { return ls_precise(cint_lo(l)); }
        }
    }
    return size;
}

// isOverwrite -> (result, KillingOff, DeadOff)
fn ds_is_overwrite(ki: i32, di: i32, kloc: ML, dloc: ML) -> i64, i64, i64 {
    var koff: i64 = 0;
    var doff: i64 = 0;
    if !ds_loop_independent(di, ki, dloc) { return OW_UNKNOWN, koff, doff; }
    let ksz = ds_strengthen_size(ki, kloc.size);
    let dptr = strip_ptr_casts(dloc.ptr);
    let kptr = strip_ptr_casts(kloc.ptr);
    let duo = ds_uo(dptr);
    let kuo = ds_uo(kptr);
    if duo == kuo && ls_has_value(ksz) && ls_is_precise(ksz) && aa_is_identified_object(kuo) {
        let ok, osz = ds_pointer_size(kuo);
        if ok && !ls_is_scalable(ksz) && osz == ls_value(ksz) { return OW_COMPLETE, koff, doff; }
    }
    if !(ls_has_value(ksz) && ls_is_precise(ksz)) || !(ls_has_value(dloc.size) && ls_is_precise(dloc.size)) {
        if mi_is_mem_intrinsic(ki) && mi_is_mem_intrinsic(di) {
            if mi_length(ki) == mi_length(di) && aa_is_must_alias(dloc, kloc, ds_q) { return OW_COMPLETE, koff, doff; }
        }
        return ds_masked_store_overwrite(ki, di), koff, doff;
    }
    let ksize = ls_value(ksz);
    let dsize = ls_value(dloc.size);
    if ls_is_scalable(dloc.size) || ls_is_scalable(ksz) { return OW_UNKNOWN, koff, doff; }
    let aar = aa_alias(kloc, dloc, ds_q, -1);
    if ar_k(aar) == AR_MUST {
        if ksize >= dsize { return OW_COMPLETE, koff, doff; }
    }
    if ar_k(aar) == AR_PARTIAL && aar.has_off {
        let off = aar.off as i64;
        if off >= 0 && (off as! u64) + dsize <= ksize { return OW_COMPLETE, koff, doff; }
    }
    if duo != kuo {
        if ar_k(aar) == AR_NO { return OW_NONE, koff, doff; }
        return OW_UNKNOWN, koff, doff;
    }
    let dbase, dofs = ds_base_offset(dptr);
    let kbase, kofs = ds_base_offset(kptr);
    doff = dofs;
    koff = kofs;
    if dbase != kbase { return OW_UNKNOWN, koff, doff; }
    if doff >= koff {
        if ((doff - koff) as! u64) + dsize <= ksize { return OW_COMPLETE, koff, doff; }
        else if ((doff - koff) as! u64) < ksize { return OW_MAYBE_PARTIAL, koff, doff; }
    } else if ((koff - doff) as! u64) < dsize {
        return OW_MAYBE_PARTIAL, koff, doff;
    }
    return OW_NONE, koff, doff;
}

// isInvisibleToCallerOnUnwind(V)
fn ds_invisible_on_unwind(v: i32) -> bool {
    let nv, req = aa_is_not_visible_on_unwind(v);
    if !nv { return false; }
    if !req { return true; }
    let r = ds_vr(v);
    if !ds_v[r].cbr_has {
        ds_v[r].cbr_has = true;
        let wo, wr = ct_pointer_may_be_captured(v, CC_PROVENANCE, CT_STOP_FULL_PROV, 0);
        ds_v[r].cbr = cc_anything(wo);
    }
    return !ds_v[r].cbr;
}

// isInvisibleToCallerAfterRet(V, Ptr, StoreSize)
fn ds_invisible_after_ret(v: i32, p: i32, size: u64) -> bool {
    if is_inst_op(v, OP_ALLOCA) { return true; }
    let r = ds_vr(v);
    if ds_v[r].bnd_has {
        let base, off = ds_base_offset(p);
        if base != v { return false; }
        if ls_has_value(size) && (off as! u64) + ls_value(size) <= ds_v[r].bnd && off >= 0 { return true; }
    }
    if !ds_v[r].inv_has {
        ds_v[r].inv_has = true;
        ds_v[r].inv = false;
        if ds_invisible_on_unwind(v) && aa_is_noalias_call(v) {
            let wo, wr = ct_pointer_may_be_captured(v, CC_PROVENANCE, CT_STOP_FULL_PROV, 0);
            let r2 = ds_vr(v);
            ds_v[r2].inv = cc_nothing(wr);
        }
    }
    let r3 = ds_vr(v);
    return ds_v[r3].inv;
}

// getLocForWrite: ML_NONE = std::nullopt
fn ds_loc_for_write(i: i32) -> ML {
    if !inst_may_write_memory(i) { return ml_none(); }
    if is_callbase(i) { return ml_for_dest_call(i); }
    return ml_get_or_none(i);
}
fn ml_is_none(l: ML) -> bool { l.ptr == ML_NONE }

// isMemTerminatorInst
fn ds_is_mem_terminator_inst(i: i32) -> bool {
    if !is_callbase(i) { return false; }
    return inst_iid(i) == IID_lifetime_end || get_freed_operand(i) >= 0;
}
// getLocForTerminator -> (loc or ML_NONE, is_free)
fn ds_loc_for_terminator(i: i32) -> ML, bool {
    if is_callbase(i) {
        if inst_iid(i) == IID_lifetime_end { return ml_for_argument(i, 0, true), false; }
        let fo = get_freed_operand(i);
        if fo >= 0 { return ml_after(fo), true; }
    }
    return ml_none(), false;
}

// isRemovable
fn ds_is_removable(i: i32) -> bool {
    if iop(i) == OP_STORE { return ldst_is_unordered(i); }
    if is_callbase(i) {
        if mi_is_mem_intrinsic(i) { return !mi_is_volatile(i); }
        if inst_is_lifetime_start_or_end(i) { return false; }
        return vals[i].first_use < 0 && inst_will_return(i) && call_has_fn_attr(i, AK_NoUnwind) && !is_terminator(i);
    }
    return false;
}

// isCompleteOverwrite(DefLoc, DefInst, UseInst)
fn ds_is_complete_overwrite(dloc: ML, di: i32, ui: i32) -> bool {
    if !inst_may_write_memory(ui) { return false; }
    if is_callbase(ui) && ds_only_inaccessible(ui) { return false; }
    let cc = ds_loc_for_write(ui);
    if !ml_is_none(cc) {
        let r, a, b = ds_is_overwrite(ui, di, cc, dloc);
        return r == OW_COMPLETE;
    }
    return false;
}

// pushMemUses(Acc, WorkList, Visited)
fn ds_push_mem_uses(acc: i32, wl: i32[>..<]&, vt: i32) {
    var u = mssa_first_use(acc);
    while u >= 0 {
        let ma = mssa_use_user(u);
        let r = ds_ar(ma);
        if ds_a[r].vis != vt { ds_a[r].vis = vt; wl.push(ma); }
        u = mssa_use_next(u);
    }
}

// isWriteAtEndOfFunction
fn ds_is_write_at_end_of_function(def: i32, dloc: ML) -> bool {
    var wl: i32[>..<] = [];
    let vt = ds_new_tick();
    ds_push_mem_uses(def, wl, vt);
    var k: i64 = 0;
    while k < wl.len {
        if wl.len >= ds_opt_scan_limit { return false; }
        let ua = wl[k];
        k++;
        if macc[ua].kind == MAK_PHI {
            if !ds_loop_invariant(dloc.ptr) { return false; }
            ds_push_mem_uses(ua, wl, vt);
            continue;
        }
        let ui = macc[ua].inst;
        if ds_is_read_clobber(dloc, ui) { return false; }
        if macc[ua].kind == MAK_DEF { ds_push_mem_uses(ua, wl, vt); }
    }
    return true;
}

// isMemTerminator(Loc, AccessI, MaybeTerm)
fn ds_is_mem_terminator(loc: ML, ai: i32, mt: i32) -> bool {
    let tloc, is_free = ds_loc_for_terminator(mt);
    if ml_is_none(tloc) { return false; }
    if ds_uo(loc.ptr) != ds_uo(tloc.ptr) { return false; }
    if is_free {
        let luo = ds_uo(loc.ptr);
        return aa_is_must_alias_vals(tloc.ptr, luo, ds_q);
    }
    let r, a, b = ds_is_overwrite(mt, ai, tloc, loc);
    return r == OW_COMPLETE;
}

// isReadClobber(DefLoc, UseInst)
fn ds_is_read_clobber(dloc: ML, ui: i32) -> bool {
    if ds_is_noop_intrinsic(ui) { return false; }
    if iop(ui) == OP_STORE { return ord_stronger_than_monotonic(insts[inst_of(ui)].ord); }
    if !inst_may_read_memory(ui) { return false; }
    if is_callbase(ui) && ds_only_inaccessible(ui) { return false; }
    return mr_is_ref(aa_inst_loc_mr(ui, dloc, ds_q));
}

// isGuaranteedLoopIndependent(Current, KillingDef, CurrentLoc)
fn ds_loop_independent(cur: i32, kd: i32, cloc: ML) -> bool {
    let cb = inst_parent(cur);
    let kb = inst_parent(kd);
    if cb == kb { return true; }
    let cc = ci_cycle_for(cb);
    if cc >= 0 && cc == ci_cycle_for(kb) { return true; }
    return ds_loop_invariant(cloc.ptr);
}

// GEPOperator::hasAllConstantIndices
fn ds_gep_all_constant_indices(g: i32) -> bool {
    for k in 1..nops(g) {
        let x = op(g, k);
        if vals[x].kind != VK_CINT || ty_is_vector(vals[x].ty) { return false; }
    }
    return true;
}

// isGuaranteedLoopInvariant(Ptr)
fn ds_loop_invariant(p0: i32) -> bool {
    var p = strip_ptr_casts(p0);
    if opcode_of(p) == OP_GEP && ds_gep_all_constant_indices(p) { p = strip_ptr_casts(op(p, 0)); }
    if is_inst(p) {
        let b = inst_parent(p);
        return func_entry(block_func(b)) == b || ci_cycle_for(b) < 0;
    }
    return true;
}

// mayThrowBetween(KillingI, DeadI, KillingUndObj)
fn ds_may_throw_between(ki: i32, di: i32, kuo: i32) -> bool {
    if kuo >= 0 && ds_invisible_on_unwind(kuo) { return false; }
    if inst_parent(ki) == inst_parent(di) { let r = ds_vr(inst_parent(ki)); return ds_v[r].thr; }
    return ds_any_throwing;
}

// isDSEBarrier(KillingUndObj, DeadI)
fn ds_is_barrier(kuo: i32, di: i32) -> bool {
    if inst_may_throw(di) && !ds_invisible_on_unwind(kuo) { return true; }
    if inst_is_atomic(di) {
        let o = iop(di);
        let x = insts[inst_of(di)];
        if o == OP_LOAD || o == OP_STORE || o == OP_ATOMICRMW { return ord_stronger_than_monotonic(x.ord); }
        if o == OP_CMPXCHG { return ord_stronger_than_monotonic(x.ord) || ord_stronger_than_monotonic(x.ord2); }
        fatal("internal: DSE: unexpected atomic instruction in MemorySSA");
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// getDomMemoryDef

// results of getDomMemoryDef: -1 = std::nullopt
var ds_scan_limit: i64 = 0;
var ds_walker_limit: i64 = 0;
var ds_partial_limit: i64 = 0;

fn ds_get_dom_memory_def(kdef: i32, start: i32, kloc: ML, kuo: i32, is_mem_term: bool, is_init_loc: bool) -> i32 {
    if ds_scan_limit == 0 || ds_walker_limit == 0 { return -1; }
    var cur = start;
    let ki = macc[kdef].inst;
    var can_optimize = ds_opt_optimize_mssa && ma_def(kdef) == start && !inst_may_read_memory(ki);
    var cur_loc = ml_none();
    loop {
        if mssa_is_live(cur) {
            if can_optimize && cur != ma_def(kdef) { ma_set_optimized(kdef, cur); }
            return -1;
        }
        let step = if macc[kdef].bb == macc[cur].bb { ds_opt_same_bb_cost } else { ds_opt_other_bb_cost };
        if ds_walker_limit <= step { return -1; }
        ds_walker_limit -= step;
        if macc[cur].kind == MAK_PHI { return cur; }
        let ci = macc[cur].inst;
        if ds_can_skip_def(cur, !ds_invisible_on_unwind(kuo)) {
            can_optimize = false;
            cur = ma_def(cur);
            continue;
        }
        if ds_may_throw_between(ki, ci, kuo) { return -1; }
        if ds_is_barrier(kuo, ci) { return -1; }
        if inst_iid(ci) == 0 && ds_is_read_clobber(kloc, ci) { return -1; }
        // direct uses that are read clobbers
        var u = mssa_first_use(cur);
        while u >= 0 {
            let us = mssa_use_user(u);
            if macc[us].kind != MAK_PHI {
                if !mssa_dominates(start, us) && ds_is_read_clobber(kloc, macc[us].inst) { return -1; }
            }
            u = mssa_use_next(u);
        }
        cur_loc = ds_loc_for_write(ci);
        if ml_is_none(cur_loc) || !ds_is_removable(ci) {
            can_optimize = false;
            cur = ma_def(cur);
            continue;
        }
        if !ds_loop_independent(ci, ki, cur_loc) {
            can_optimize = false;
            cur = ma_def(cur);
            continue;
        }
        if is_mem_term {
            if !ds_is_mem_terminator(cur_loc, ci, ki) {
                can_optimize = false;
                cur = ma_def(cur);
                continue;
            }
        } else {
            let orr, ko, dof = ds_is_overwrite(ki, ci, kloc, cur_loc);
            if can_optimize {
                if cur != ma_def(kdef) && (orr == OW_COMPLETE || orr == OW_MAYBE_PARTIAL) { ma_set_optimized(kdef, cur); }
                if orr != OW_NONE { can_optimize = false; }
            }
            if orr == OW_UNKNOWN || orr == OW_NONE { cur = ma_def(cur); continue; }
            if orr == OW_MAYBE_PARTIAL {
                if ds_partial_limit <= 1 {
                    ds_walker_limit -= 1;
                    cur = ma_def(cur);
                    continue;
                }
                ds_partial_limit -= 1;
            }
        }
        break;
    }

    // Reads of MaybeDeadAccess
    var kdefs: i32[>..<] = [];
    kdefs.push(ki);
    let mda = cur;
    let mdloc = cur_loc;
    let mdi = macc[mda].inst;
    var wl: i32[>..<] = [];
    let vt = ds_new_tick();
    ds_push_mem_uses(mda, wl, vt);
    var k: i64 = 0;
    while k < wl.len {
        let ua = wl[k];
        if ds_scan_limit < wl.len - k { return -1; }
        ds_scan_limit -= 1;
        k++;
        if macc[ua].kind == MAK_PHI {
            var dom = false;
            for kd in kdefs { if dt_properly_dominates_block(DT_DOM, inst_parent(kd), macc[ua].bb) { dom = true; break; } }
            if dom { continue; }
            ds_push_mem_uses(ua, wl, vt);
            continue;
        }
        let ui = macc[ua].inst;
        var dom = false;
        for kd in kdefs { if dt_value_dominates_inst(kd, ui) { dom = true; break; } }
        if dom { continue; }
        if ds_is_mem_terminator(mdloc, mdi, ui) { continue; }
        if ds_is_noop_intrinsic(ui) { ds_push_mem_uses(ua, wl, vt); continue; }
        if inst_may_throw(ui) && !ds_invisible_on_unwind(kuo) { return -1; }
        var from_init = false;
        if is_init_loc {
            if ki == ui && kuo == ds_uo(mdloc.ptr) { from_init = true; }
        }
        if ds_is_read_clobber(mdloc, ui) && !from_init { return -1; }
        if mda == ua && !ds_loop_invariant(mdloc.ptr) { return -1; }
        if kdef == ua || mda == ua { continue; }
        if macc[ua].kind == MAK_DEF {
            if ds_is_complete_overwrite(mdloc, mdi, ui) {
                let mkb = inst_parent(ui);
                if ds_po(mkb) < ds_po(macc[mda].bb) {
                    if !ds_invisible_after_ret(kuo, kloc.ptr, kloc.size) {
                        var seen = false;
                        for kd in kdefs { if kd == ui { seen = true; } }
                        if !seen { kdefs.push(ui); }
                    }
                } else {
                    return -1;
                }
            } else {
                ds_push_mem_uses(ua, wl, vt);
            }
        }
    }

    if !ds_invisible_after_ret(kuo, kloc.ptr, kloc.size) {
        let kbt = ds_new_tick();
        var kblocks: i32[>..<] = [];
        for kd in kdefs {
            let b = inst_parent(kd);
            let r = ds_vr(b);
            if ds_v[r].kb != kbt { ds_v[r].kb = kbt; kblocks.push(b); }
        }
        // the common post-dominator; -1 = nullptr (the virtual root)
        var common = kblocks[0];
        for j in 1..kblocks.len {
            if common < 0 { break; }
            let n = dt_find_ncd(DT_POST, common, kblocks[j]);
            common = if n == DT_VROOT { -1 } else { n };
        }
        let mdb = macc[mda].bb;
        let cnode = if common < 0 { DT_VROOT } else { common };
        if !dt_dominates_nodes(ds_fn, DT_POST, cnode, if dt_has_node(DT_POST, mdb) { mdb } else { -1 }) {
            if !ds_any_unreachable_exit { return -1; }
            common = -1;
        }
        if common >= 0 { let r = ds_vr(common); if ds_v[r].kb == kbt { return mda; } }
        var bwl: i32[>..<] = [];
        let wt = ds_new_tick();
        if common >= 0 {
            bwl.push(common);
            let r = ds_vr(common);
            ds_v[r].wl = wt;
        } else {
            for j in dt_nroots(ds_fn, DT_POST) {
                let rb = dt_root_at(ds_fn, DT_POST, j);
                if iop(block_terminator(rb)) != OP_UNREACHABLE {
                    let r = ds_vr(rb);
                    if ds_v[r].wl != wt { ds_v[r].wl = wt; bwl.push(rb); }
                }
            }
        }
        var j: i64 = 0;
        while j < bwl.len {
            let c = bwl[j];
            j++;
            let rc = ds_vr(c);
            if ds_v[rc].kb == kbt { continue; }
            if c == mdb { return -1; }
            if !dt_has_node(DT_DOM, c) { continue; }
            each_pred(c) { p =>
                let r = ds_vr(p);
                if ds_v[r].wl != wt { ds_v[r].wl = wt; bwl.push(p); }
            };
            if bwl.len >= ds_opt_path_check_limit { return -1; }
        }
    }
    return mda;
}

// ---------------------------------------------------------------------------------------------
// Deletion

// deleteDeadInstruction(SI, Deleted): del_tick = the Deleted set's stamp (0 = none)
fn ds_delete_dead_instruction(si: i32, del_tick: i32) {
    var now_dead: i32[>..<] = [];
    now_dead.push(si);
    while now_dead.len > 0 {
        let dead = now_dead.pop();
        salvage_debug_info(dead);
        salvage_knowledge(dead, false);
        let ma = mssa_access_of(dead);
        let is_def = ma >= 0 && macc[ma].kind == MAK_DEF;
        if ma >= 0 {
            if is_def {
                let r = ds_ar(ma);
                if ds_a[r].skip != ds_epoch { ds_a[r].skip = ds_epoch; ds_skip_count++; }
                if del_tick != 0 { ds_a[r].del = del_tick; }
                let mi = macc[ma].inst;
                if iop(mi) == OP_STORE && ty_kind(vals[op(mi, 0)].ty) == TK_PTR {
                    let uo = ds_uo(op(mi, 0));
                    let vr = ds_vr(uo);
                    if ds_v[vr].cbr_has { ds_v[vr].cbr_has = false; ds_iterate_eof = true; }
                    ds_v[vr].inv_has = false;
                    ds_v[vr].bnd_has = false;
                }
            }
            msu_remove_memory_access(ma, false);
        }
        ds_iol_erase(dead);
        for k in nops(dead) {
            let o = op(dead, k);
            if is_inst(o) {
                set_op(dead, k, c_poison(vals[o].ty));
                if is_instruction_trivially_dead(o) { now_dead.push(o); }
            }
        }
        ea_remove_instruction(dead);
        if is_def && vals[dead].ty == T_VOID { inst_erase_from_parent(dead); }
        else { ds_to_remove.push(dead); }
    }
}

// ---------------------------------------------------------------------------------------------
// eliminateDeadWritesAtEndOfFunction

fn ds_eliminate_dead_writes_at_end() -> bool {
    var changed = false;
    loop {
        ds_iterate_eof = false;
        var k = ds_memdefs.len - 1;
        while k >= 0 {
            let def = ds_memdefs[k];
            k--;
            if ds_skipped(def) { continue; }
            let di = macc[def].inst;
            let dloc = ds_loc_for_write(di);
            if ml_is_none(dloc) || !ds_is_removable(di) { continue; }
            let uo = ds_uo(dloc.ptr);
            if !ds_invisible_after_ret(uo, dloc.ptr, dloc.size) { continue; }
            if ds_is_write_at_end_of_function(def, dloc) {
                ds_delete_dead_instruction(di, 0);
                changed = true;
            }
        }
        if !ds_iterate_eof { break; }
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// eliminateRedundantStoresViaDominatingConditions

// GetDominatingCondition(BB) -> (ptr, val, load, implied successor) or ptr = -1
fn ds_dominating_condition(bb: i32) -> i32, i32, i32, i32 {
    let t = block_terminator(bb);
    if t < 0 || iop(t) != OP_CONDBR { return -1, -1, -1, -1; }
    if term_succ(t, 0) == term_succ(t, 1) { return -1, -1, -1, -1; }
    let c = op(t, 0);
    if !is_inst_op(c, OP_ICMP) { return -1, -1, -1, -1; }
    var l: i32 = -1;
    var sv: i32 = -1;
    if is_inst_op(op(c, 0), OP_LOAD) { l = op(c, 0); sv = op(c, 1); }
    else if is_inst_op(op(c, 1), OP_LOAD) { l = op(c, 1); sv = op(c, 0); }
    if l < 0 { return -1, -1, -1, -1; }
    let p = insts[inst_of(c)].pred as i64;
    if p != 32 && p != 33 { return -1, -1, -1, -1; }
    if ty_kind(vals[sv].ty) == TK_PTR && !can_replace_pointers_if_equal(sv, l) { return -1, -1, -1, -1; }
    let idx = if p == 32 { 0 } else { 1 };
    return op(l, 0), sv, l, term_succ(t, idx);
}

struct DsCond { ptr: i32, val: i32, li: i32 }
struct DsNode { bb: i32, depth: i64, child: i32, mark: i64, cptr: i32, cval: i32, cli: i32, csucc: i32, started: bool }

fn ds_eliminate_via_dominating_conditions() -> bool {
    var changed = false;
    var active: DsCond[>..<] = [];
    var stk: DsNode[>..<] = [];
    let root = dt_root(ds_fn, DT_DOM);
    stk.push(DsNode { bb: root, depth: 0, child: -1, mark: 0, cptr: -1, cval: -1, cli: -1, csucc: -1, started: false });
    while stk.len > 0 {
        let t = stk.len - 1;
        if !stk[t].started {
            stk[t].started = true;
            if stk[t].depth > ds_opt_max_depth { stk.pop(); continue; }
            let bb = stk[t].bb;
            var a = mb_dfirst(bb);
            while a >= 0 {
                let nx = macc[a].dnext;
                if macc[a].kind == MAK_DEF {
                    let si = macc[a].inst;
                    if iop(si) == OP_STORE && ldst_is_unordered(si) {
                        var li: i32 = -1;
                        var j = active.len - 1;
                        while j >= 0 {
                            if active[j].ptr == op(si, 1) && active[j].val == op(si, 0) { li = active[j].li; break; }
                            j--;
                        }
                        if li >= 0 {
                            let la = mssa_access_of(li);
                            cw_limit = mssa_max_check_limit();
                            let clob = mssa_clobbering_access(a, ds_q, true, true);
                            if mssa_dominates(clob, la) {
                                ds_delete_dead_instruction(si, 0);
                                changed = true;
                            }
                        }
                    }
                }
                a = nx;
            }
            let cp, cv, cl, cs = ds_dominating_condition(bb);
            stk[t].cptr = cp;
            stk[t].cval = cv;
            stk[t].cli = cl;
            stk[t].csucc = cs;
            stk[t].child = dt_first_child(ds_fn, DT_DOM, bb);
            stk[t].mark = active.len;
            continue;
        }
        // leaving the previous child's scope
        active.resize(stk[t].mark);
        let c = stk[t].child;
        if c < 0 { stk.pop(); continue; }
        stk[t].child = dt_next_sibling(DT_DOM, c);
        if stk[t].cptr >= 0 {
            if dom_edge(stk[t].bb, stk[t].csucc, c) {
                active.push(DsCond { ptr: stk[t].cptr, val: stk[t].cval, li: stk[t].cli });
            }
        }
        let d = stk[t].depth + 1;
        stk.push(DsNode { bb: c, depth: d, child: -1, mark: 0, cptr: -1, cval: -1, cli: -1, csucc: -1, started: false });
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// tryFoldIntoCalloc, storeIsNoop

// emitCalloc(Num, Size, IRB, TLI, AddrSpace) inserting before `before`: the call or -1
fn ds_emit_calloc(num: i32, size: i32, before: i32, as_: i64) -> i32 {
    if !blc_is_emittable(LF_calloc) { return -1; }
    let st = ty_int(tli_sizet_bits());
    let fty = ty_func_of(ty_ptr(as_), [st, st], false);
    let f = blc_get_or_insert(LF_calloc, fty, 0);
    var nm: u8[>..] = [];
    nm.append(tli_name(LF_calloc));
    blc_infer_by_name(nm);
    let ftyf = globs[glob_of(f)].vty;
    let c = create_inst(OP_CALL, ty_fn_ret(ftyf), [num, size, f]);
    insts[inst_of(c)].ty2 = ftyf;
    inst_insert_before(c, before);
    let dl = inst_get_md(before, 0);
    if dl >= 0 { inst_set_md(c, 0, dl); }
    set_name(c, nm);
    insts[inst_of(c)].cc = globs[glob_of(f)].cc;
    return c;
}

// tryFoldIntoCalloc(Def, DefUO)
fn ds_try_fold_into_calloc(def: i32, uo: i32) -> bool {
    let di = macc[def].inst;
    if !mi_is_memset(di) { return false; }
    let sc = mi_value(di);
    if !is_constant(sc) || !is_null_value(sc) { return false; }
    if !ds_is_removable(di) { return false; }
    if func_has_fn_attr(ds_fn, AK_SanitizeMemory) || func_has_fn_attr(ds_fn, AK_SanitizeAddress) ||
       func_has_fn_attr(ds_fn, AK_SanitizeHWAddress) || val_name(ds_fn) == "calloc" { return false; }
    if !is_inst_op(uo, OP_CALL) { return false; }
    let malloc = uo;
    let inner = called_function(malloc);
    if inner < 0 { return false; }
    var zeroed: u8[>..] = [];
    let lf = tli_get_libfunc(inner);
    if lf < 0 || !tli_has(lf) || lf != LF_malloc as i32 {
        let a = aset_find_str(alist_fn(insts[inst_of(malloc)].attrs), "alloc-variant-zeroed");
        var a2 = a;
        if a2 < 0 { a2 = aset_find_str(alist_fn(globs[glob_of(inner)].attrs), "alloc-variant-zeroed"); }
        if a2 < 0 { return false; }
        if attrs[a2].sval < 0 { return false; }
        zeroed.append(sbytes(attrs[a2].sval));
        if zeroed.len == 0 { return false; }
    }
    let mdef = mssa_access_of(malloc);
    if mdef < 0 || macc[mdef].kind != MAK_DEF { return false; }
    // shouldCreateCalloc
    let mbb = inst_parent(malloc);
    let sbb = inst_parent(di);
    var should = true;
    if mbb != sbb {
        should = false;
        let p = cb_arg(di, 0);
        let t = block_terminator(mbb);
        if t >= 0 && iop(t) == OP_CONDBR {
            let c = op(t, 0);
            if is_inst_op(c, OP_ICMP) && insts[inst_of(c)].pred == 32 && op(c, 0) == p && is_constant(op(c, 1)) &&
               ds_is_zero_int_or_null(op(c, 1)) && term_succ(t, 1) == sbb { should = true; }
        }
    }
    if op(malloc, 0) != mi_length(di) { return false; }
    if !should || !dt_value_dominates_inst(malloc, di) || !ds_mem_not_modified_between(malloc, di) { return false; }
    var calloc: i32 = -1;
    if zeroed.len > 0 {
        // AllocKind | Zeroed & ~Uninitialized, without "alloc-variant-zeroed"
        let fl = globs[glob_of(inner)].attrs;
        let fs = alist_fn(fl);
        let aka = aset_find(fs, AK_AllocKind);
        var ak: u64 = if aka >= 0 { attrs[aka].i1 } else { 0 };
        ak = (ak | 16) & ~(8 as u64);
        var xs: i32[>..<] = [];
        for j in aset_n(fs) {
            let a = aset_attr(fs, j);
            if attrs[a].kind as i64 == AK_AllocKind { continue; }
            if attrs[a].kind == 0 && sbytes(attrs[a].skey) == "alloc-variant-zeroed" { continue; }
            xs.push(a);
        }
        xs.push(attr_int(AK_AllocKind, ak));
        var ls: i32[>..<] = [];
        ls.push(aset_get(xs));
        let nl = if fl == 0 { 0 } else { alists[fl].n as i64 };
        for j in 1..nl { ls.push(alist_runs[alists[fl].at + j]); }
        let nf = module_get_or_insert_function(zeroed, globs[glob_of(inner)].vty, alist_get(ls));
        globs[glob_of(nf)].cc = insts[inst_of(malloc)].cc;
        var opsv: i32[>..<] = [];
        for j in cb_nargs(malloc) { opsv.push(cb_arg(malloc, j)); }
        opsv.push(nf);
        let fty = globs[glob_of(nf)].vty;
        let c = create_inst(OP_CALL, ty_fn_ret(fty), opsv);
        insts[inst_of(c)].ty2 = fty;
        inst_insert_before(c, malloc);
        let dl = inst_get_md(malloc, 0);
        if dl >= 0 { inst_set_md(c, 0, dl); }
        set_name(c, zeroed);
        insts[inst_of(c)].cc = insts[inst_of(malloc)].cc;
        calloc = c;
    } else {
        let st = vals[cb_arg(malloc, 0)].ty;
        calloc = ds_emit_calloc(c_int(st, 1), cb_arg(malloc, 0), malloc, ptr_as(vals[malloc].ty));
    }
    if calloc < 0 { return false; }
    let na = msu_create_access_after(calloc, -1, mdef);
    msu_insert_def(na, true);
    rauw(malloc, calloc);
    ds_delete_dead_instruction(malloc, 0);
    return true;
}

// m_Zero(): a null value (integer or pointer, splats included)
fn ds_is_zero_int_or_null(v: i32) -> bool { is_null_value(v) }

// storeIsNoop(Def, DefUO)
fn ds_store_is_noop(def: i32, uo: i32) -> bool {
    let di = macc[def].inst;
    let is_store = iop(di) == OP_STORE;
    let is_mset = mi_is_memset(di);
    var sc: i32 = -1;
    if is_store { if is_constant(op(di, 0)) { sc = op(di, 0); } }
    else if is_mset { if is_constant(mi_value(di)) { sc = mi_value(di); } }
    else { return false; }
    if !ds_is_removable(di) { return false; }
    if sc >= 0 {
        let initc = mb_initial_value_of_allocation(uo, vals[sc].ty);
        if initc >= 0 && initc == sc {
            cw_limit = mssa_max_check_limit();
            return mssa_is_live(mssa_clobbering_access(def, ds_q, true, true));
        }
    }
    if !is_store { return false; }
    let li = op(di, 0);
    if is_inst_op(li, OP_LOAD) && op(li, 0) == op(di, 1) {
        let la = ma_def(mssa_access_of(li));
        if la == ma_def(def) { return true; }
        var tc: i32[>..<] = [];
        let tt = ds_new_tick();
        let cur0 = mssa_get_clobbering(def, ds_q);
        tc.push(def);
        let rd = ds_ar(def);
        ds_a[rd].tc2 = tt;
        let rc = ds_ar(cur0);
        if ds_a[rc].tc2 != tt { ds_a[rc].tc2 = tt; tc.push(cur0); }
        var k: i64 = 1;
        while k < tc.len {
            let c = tc[k];
            k++;
            if macc[c].kind == MAK_PHI {
                for j in mphi_n(c) {
                    let v = mphi_val(c, j);
                    let r = ds_ar(v);
                    if ds_a[r].tc2 != tt { ds_a[r].tc2 = tt; tc.push(v); }
                }
                continue;
            }
            if la != c { return false; }
        }
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// removePartiallyOverlappedStores, eliminateRedundantStoresOfExistingValues

fn ds_remove_partially_overlapped_stores(bb: i32) -> bool {
    var changed = false;
    let rb = ds_vr(bb);
    var e = ds_v[rb].iol_first;
    while e >= 0 {
        let nx = ds_iol[e].next;
        if ds_iol[e].alive {
            let di = ds_iol[e].inst;
            let loc = ds_loc_for_write(di);
            let p = strip_ptr_casts(loc.ptr);
            var dstart: i64 = 0;
            var dsize = ls_value(loc.size);
            let base, off = ds_base_offset(p);
            dstart = off;
            // the map is a copy in LLVM (for (auto OI : IOL)); ours is not read afterwards
            let c1, s1, z1 = ds_try_to_shorten_end(di, e, dstart, dsize);
            if c1 { changed = true; }
            dstart = s1;
            dsize = z1;
            if ds_iol[e].head >= 0 {
                let c2, s2, z2 = ds_try_to_shorten_begin(di, e, dstart, dsize);
                if c2 { changed = true; }
            }
        }
        e = nx;
    }
    return changed;
}

fn ds_eliminate_redundant_stores_of_existing_values() -> bool {
    var changed = false;
    for def in ds_memdefs {
        if ds_skipped(def) || mssa_is_live(def) { continue; }
        let di = macc[def].inst;
        let dloc = ds_loc_for_write(di);
        if ml_is_none(dloc) || !ds_is_removable(di) { continue; }
        var upper: i32 = -1;
        if ma_is_optimized(def) {
            let o = ma_get_optimized(def);
            if ds_is_dsef(o) { upper = o; }
        } else {
            let d = ma_def(def);
            if ds_is_dsef(d) { upper = d; }
        }
        if upper < 0 || mssa_is_live(upper) { continue; }
        let ui = macc[upper].inst;
        var redundant = false;
        if ii_is_identical_when_defined(di, ui, true) {
            redundant = true;
        } else if mi_is_memset(ui) && iop(di) == OP_STORE {
            let uloc = ds_loc_for_write(ui);
            if !ml_is_none(uloc) {
                let orr, a, b = ds_is_overwrite(ui, di, uloc, dloc);
                let sb = is_bytewise_value(op(di, 0));
                redundant = sb >= 0 && sb == op(ui, 1) && orr == OW_COMPLETE;
            }
        }
        if !redundant || ds_is_read_clobber(dloc, di) { continue; }
        ds_delete_dead_instruction(di, 0);
        changed = true;
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// getInitializesArgMemLoc

// CallBase::getParamAttr(ArgNo, Initializes): the attribute or -1 (call site first, then the callee)
fn ds_param_attr(c: i32, k: i64, kind: i64) -> i32 {
    let a = aset_find(alist_param(insts[inst_of(c)].attrs, k), kind);
    if a >= 0 { return a; }
    let f = called_function(c);
    if f >= 0 { return aset_find(alist_param(globs[glob_of(f)].attrs, k), kind); }
    return -1;
}

// ArgumentInitInfo lists: Arguments (SmallMapVector) is groups of members; ranges are runs in rp
struct DsArgInfo { idx: i64, dead_or_inv: bool, at: i64, n: i64, group: i64 }

fn ds_initializes_locs(i: i32, out: ML[>..<]&) {
    if !is_callbase(i) { return; }
    var group_key: i32[>..<] = [];
    var infos: DsArgInfo[>..<] = [];
    var rp: i64[>..<] = [];
    for idx in cb_nargs(i) {
        let cur = cb_arg(i, idx);
        if ty_kind(vals[cur].ty) != TK_PTR { continue; }
        let at = rp.len;
        var n: i64 = 0;
        let ia = ds_param_attr(i, idx, AK_Initializes);
        if ia >= 0 && !cb_is_byval_arg(i, idx) {
            let w = attrs[ia].i1 as! i64;
            let cnt = words[w] as! i64;
            for j in cnt {
                rp.push(words[w + 1 + 2 * j] as! i64);
                rp.push(words[w + 2 + 2 * j] as! i64);
            }
            n = cnt;
        }
        if n > 0 && !ds_only_inaccessible_or_arg(i) {
            let uobj = ds_uo(cur);
            let fl = aa_is_identified_function_local(uobj) && cc_nothing(aq_captures_before(ds_q, uobj, i, true, false));
            if !fl { rp.resize(at); n = 0; }
        }
        let dead_or_inv = cb_param_has_attr(i, idx, AK_DeadOnUnwind) || (iop(i) == OP_CALL && ds_invisible_on_unwind(cur));
        var found = false;
        for g in group_key.len {
            let key = group_key[g];
            let r = aa_alias(ml_before_or_after(key), ml_before_or_after(cur), ds_q, -1);
            if ar_k(r) == AR_NO { continue; }
            found = true;
            if ar_k(r) == AR_MUST {
                infos.push(DsArgInfo { idx: idx, dead_or_inv: dead_or_inv, at: at, n: n, group: g as i64 });
            } else {
                infos.push(DsArgInfo { idx: idx, dead_or_inv: dead_or_inv, at: at, n: 0, group: g as i64 });
            }
        }
        if !found {
            infos.push(DsArgInfo { idx: idx, dead_or_inv: dead_or_inv, at: at, n: n, group: group_key.len });
            group_key.push(cur);
        }
    }
    let nounwind = call_has_fn_attr(i, AK_NoUnwind);
    let tags = ml_aa_tags(i);
    var acc: i64[>..<] = [];
    var tmp: i64[>..<] = [];
    for g in group_key.len {
        // getIntersectedInitRangeList(Args, CallHasNoUnwindAttr)
        acc.clear();
        var first = true;
        var empty = false;
        var nmem: i64 = 0;
        for x in infos {
            if x.group != g as i64 { continue; }
            nmem++;
            if !nounwind && !x.dead_or_inv { empty = true; break; }
            if x.n == 0 { empty = true; break; }
        }
        if nmem == 0 || empty { continue; }
        for x in infos {
            if x.group != g as i64 { continue; }
            if first {
                for j in 2 * x.n { acc.push(rp[x.at + j]); }
                first = false;
                continue;
            }
            // ConstantRangeList::intersectWith
            if acc.len == 0 { continue; }
            if x.n == 0 { acc.clear(); continue; }
            tmp.clear();
            var a: i64 = 0;
            var b: i64 = 0;
            let na = acc.len / 2;
            while a < na && b < x.n {
                let lo = max(acc[2 * a], rp[x.at + 2 * b]);
                let hi = min(acc[2 * a + 1], rp[x.at + 2 * b + 1]);
                if lo < hi { tmp.push(lo); tmp.push(hi); }
                if acc[2 * a + 1] < rp[x.at + 2 * b + 1] { a++; } else { b++; }
            }
            acc.clear();
            for v in tmp { acc.push(v); }
        }
        if acc.len == 0 { continue; }
        for x in infos {
            if x.group != g as i64 { continue; }
            var j: i64 = 0;
            while j < acc.len {
                let s = acc[j];
                let e = acc[j + 1];
                if s == 0 { out.push(ml_with_tags(cb_arg(i, x.idx), ls_precise((e - s) as! u64), tags)); }
                j += 2;
            }
        }
    }
}

// getLocForInst(I, ConsiderInitializesAttr)
fn ds_locs_for_inst(i: i32, consider_init: bool, locs: ML[>..<]&, by_init: bool[>..<]&) {
    if ds_is_mem_terminator_inst(i) {
        let l, f = ds_loc_for_terminator(i);
        if !ml_is_none(l) { locs.push(l); by_init.push(false); }
        return;
    }
    let l = ds_loc_for_write(i);
    if !ml_is_none(l) { locs.push(l); by_init.push(false); }
    if consider_init {
        var xs: ML[>..<] = [];
        ds_initializes_locs(i, xs);
        for x in xs { locs.push(x); by_init.push(true); }
    }
}

// ---------------------------------------------------------------------------------------------
// eliminateDeadDefs

// eliminateDeadDefs(KillingLocWrapper) -> (Changed, DeletedKillingLoc)
fn ds_eliminate_dead_defs_loc(kdef: i32, kloc: ML, by_init: bool) -> bool, bool {
    var changed = false;
    var deleted_killing = false;
    ds_scan_limit = ds_opt_scan_limit;
    ds_walker_limit = ds_opt_walk_limit;
    ds_partial_limit = ds_opt_partial_store_limit;
    let ki = macc[kdef].inst;
    let kuo = ds_uo(kloc.ptr);
    let is_term = ds_is_mem_terminator_inst(ki);
    var tc: i32[>..<] = [];
    let tct = ds_new_tick();
    let del = ds_new_tick();
    let d0 = ma_def(kdef);
    tc.push(d0);
    let r0 = ds_ar(d0);
    ds_a[r0].tc = tct;
    var k: i64 = 0;
    while k < tc.len {
        let cur = tc[k];
        k++;
        let rcur = ds_ar(cur);
        if ds_a[rcur].del == del { continue; }
        let dead = ds_get_dom_memory_def(kdef, cur, kloc, kuo, is_term, by_init);
        if dead < 0 { continue; }
        if macc[dead].kind == MAK_PHI {
            for j in mphi_n(dead) {
                let inc = mphi_val(dead, j);
                let ib = macc[inc].bb;
                let pb = macc[dead].bb;
                if ds_po(ib) > ds_po(pb) {
                    let r = ds_ar(inc);
                    if ds_a[r].tc != tct { ds_a[r].tc = tct; tc.push(inc); }
                }
            }
            continue;
        }
        let di = macc[dead].inst;
        var dlocs: ML[>..<] = [];
        var dinit: bool[>..<] = [];
        ds_locs_for_inst(di, false, dlocs, dinit);
        if dlocs.len != 1 { fatal("internal: DSE: a dead def without exactly one location"); }
        let dloc = dlocs[0];
        let duo = ds_uo(dloc.ptr);
        let dd = ma_def(dead);
        let rr = ds_ar(dd);
        if ds_a[rr].tc != tct { ds_a[rr].tc = tct; tc.push(dd); }
        if is_term {
            if kuo != duo { continue; }
            ds_delete_dead_instruction(di, del);
            changed = true;
        } else {
            var orr, koff, doff = ds_is_overwrite(ki, di, kloc, dloc);
            if orr == OW_MAYBE_PARTIAL {
                ds_iol_block(inst_parent(di));
                orr = ds_is_partial_overwrite(kloc, dloc, koff, doff, di);
            }
            if ds_opt_partial_store_merging && orr == OW_PARTIAL_EARLIER_WITH_FULL_LATER {
                if iop(di) == OP_STORE && iop(ki) == OP_STORE && dt_value_dominates_inst(di, ki) {
                    let merged = ds_try_merge_partial_stores(ki, di, koff, doff);
                    if merged >= 0 {
                        set_op(di, 0, merged);
                        changed = true;
                        deleted_killing = true;
                        ds_delete_dead_instruction(ki, del);
                        ds_iol_erase(di);
                        break;
                    }
                }
            }
            if orr == OW_COMPLETE {
                ds_delete_dead_instruction(di, del);
                changed = true;
            }
        }
    }
    return changed, deleted_killing;
}

// eliminateDeadDefs(KillingDefWrapper)
fn ds_eliminate_dead_defs(kdef: i32, locs: const ML[:], by_init: const bool[:]) -> bool {
    if locs.len == 0 { return false; }
    var changed = false;
    let ki = macc[kdef].inst;
    for j in locs.len {
        let kloc = locs[j];
        let kuo = ds_uo(kloc.ptr);
        let c, deleted_killing = ds_eliminate_dead_defs_loc(kdef, kloc, by_init[j]);
        if c { changed = true; }
        if !deleted_killing && ds_store_is_noop(kdef, kuo) {
            ds_delete_dead_instruction(ki, 0);
            changed = true;
            continue;
        }
        if !deleted_killing && ds_try_fold_into_calloc(kdef, kuo) {
            ds_delete_dead_instruction(ki, 0);
            changed = true;
            continue;
        }
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// DSEState constructor and eliminateDeadStores

// post_order(&F): blocks reachable from the entry, successors visited in order
fn ds_post_order(fv: i32, out: i32[>..<]&) {
    let vt = ds_new_tick();
    var stk_b: i32[>..<] = [];
    var stk_k: i64[>..<] = [];
    let e = func_entry(fv);
    let re = ds_vr(e);
    ds_v[re].wl = vt;
    stk_b.push(e);
    stk_k.push(0);
    while stk_b.len > 0 {
        let t = stk_b.len - 1;
        let b = stk_b[t];
        let k = stk_k[t];
        if k < block_nsucc(b) {
            stk_k[t] = k + 1;
            let s = block_succ(b, k);
            let r = ds_vr(s);
            if ds_v[r].wl != vt { ds_v[r].wl = vt; stk_b.push(s); stk_k.push(0); }
            continue;
        }
        out.push(b);
        stk_b.pop();
        stk_k.pop();
    }
}

fn ds_init_state(fv: i32) {
    ds_memdefs.clear();
    ds_to_remove.clear();
    ds_iol_blocks.clear();
    ds_iol.clear();
    ds_iv.clear();
    ds_any_throwing = false;
    ds_iterate_eof = false;
    ds_skip_count = 0;
    var po: i32[>..<] = [];
    ds_post_order(fv, po);
    var n: i32 = 0;
    for bb in po {
        let r = ds_vr(bb);
        ds_v[r].po = n;
        ds_v[r].has_po = true;
        n++;
        var i = block_first(bb);
        while i >= 0 {
            let ma = mssa_access_of(i);
            if inst_may_throw(i) && ma < 0 {
                let rbb = ds_vr(bb);
                ds_v[rbb].thr = true;
                ds_any_throwing = true;
            }
            if ma >= 0 && macc[ma].kind == MAK_DEF && ds_memdefs.len < ds_opt_defs_per_block_limit {
                if !ml_is_none(ds_loc_for_write(i)) || ds_is_mem_terminator_inst(i) ||
                   (ds_opt_initializes && ds_has_initializes_attr(i)) { ds_memdefs.push(ma); }
            }
            i = inst_next(i);
        }
    }
    for k in func_nargs(fv) {
        let a = func_arg(fv, k);
        if ml_arg_has(a, AK_ByVal) || ml_arg_has(a, AK_InAlloca) || ml_arg_has(a, AK_Preallocated) {
            let r = ds_vr(a);
            ds_v[r].inv_has = true;
            ds_v[r].inv = true;
            continue;
        }
        if ty_kind(vals[a].ty) != TK_PTR { continue; }
        let at = aset_find(ml_arg_attrs(a), AK_DeadOnReturn);
        if at >= 0 {
            let nb = attrs[at].i1;
            let r = ds_vr(a);
            if nb == 0xFFFFFFFFFFFFFFFF { ds_v[r].inv_has = true; ds_v[r].inv = true; }
            else if nb != 0 { ds_v[r].bnd_has = true; ds_v[r].bnd = nb; }
        }
    }
    ds_any_unreachable_exit = false;
    for j in dt_nroots(fv, DT_POST) {
        let rb = dt_root_at(fv, DT_POST, j);
        if iop(block_terminator(rb)) == OP_UNREACHABLE { ds_any_unreachable_exit = true; }
    }
}

// DSEPass::run(F, AM)
fn dse_run(fv: i32) -> u32 {
    ds_read_flags();
    ds_fn = fv;
    tli_cur_fn = fv;
    local_have_tli = true;
    aa_begin(fv);
    dt_get(fv, DT_DOM);
    mssa_get(fv);
    msu_reset();
    dt_get(fv, DT_POST);
    ci_get(fv);
    vt_invalidate_assumes();
    ac_invalidate();
    ds_epoch = ds_new_tick();
    ds_q = aq_push(CA_EARLIEST);
    ea_begin(false, true);
    ds_init_state(fv);
    var changed = false;
    var locs: ML[>..<] = [];
    var by_init: bool[>..<] = [];
    var k: i64 = 0;
    while k < ds_memdefs.len {
        let kdef = ds_memdefs[k];
        k++;
        if ds_skipped(kdef) { continue; }
        locs.clear();
        by_init.clear();
        ds_locs_for_inst(macc[kdef].inst, ds_opt_initializes, locs, by_init);
        if ds_eliminate_dead_defs(kdef, locs, by_init) { changed = true; }
    }
    if ds_opt_partial_overwrite_tracking {
        for bb in ds_iol_blocks { if ds_remove_partially_overlapped_stores(bb) { changed = true; } }
    }
    if ds_eliminate_redundant_stores_of_existing_values() { changed = true; }
    if ds_eliminate_dead_writes_at_end() { changed = true; }
    if ds_eliminate_via_dominating_conditions() { changed = true; }
    while ds_to_remove.len > 0 {
        let d = ds_to_remove.pop();
        inst_erase_from_parent(d);
    }
    aq_pop(ds_q);
    ds_q = -1;
    if !changed { return PA_ALL; }
    return PA_CFG | ((1 as u32) << A_MEMORYSSA);
}
