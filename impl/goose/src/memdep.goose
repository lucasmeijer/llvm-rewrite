// MemoryDependenceAnalysis: port of llvm/lib/Analysis/MemoryDependenceAnalysis.cpp (MemoryDependenceResults: the
// local, non-local call and non-local pointer queries with all their caches, the reverse maps, the invariant.group
// dependency, removeInstruction / invalidateCachedPointerInfo / invalidateCachedPredecessors), with
// PredIteratorCache (llvm/include/llvm/IR/PredIteratorCache.h).
//
// One MemoryDependenceResults at a time (GVN's): mdep_begin(fv) = MemoryDependenceAnalysis::run. Its
// EarliestEscapeAnalysis is the single EEA instance of aa.goose (ea_begin(false, false)): its cache lives as long
// as the results, as in LLVM. Every BatchAAResults(AA, &EEA) is an aq_push(CA_EARLIEST) query info, every direct
// AAResults query an aa_*_simple one.
//
// Data: MemDepResult = MDR { k, i } (k: MDR_*). DenseMaps are HMaps (scev.goose) from ids to record indices;
// vectors of NonLocalDepEntry are runs (with capacity) in md_ents; the reverse maps (DenseMap<Instruction*,
// SmallPtrSet<..>>) are one set of (map, key, member) triples with a per-key intrusive list (their iteration
// order never affects results). NonLocalDepEntry sorts by block value id (LLVM: by pointer).
import std;
import ir;
import irutil;
import instinfo;
import analyses;
import gen_iids;
import domtree;
import memloc;
import aa;
import aautil;
import vt;
import tli;
import local;
import flags;
import scev;
import knownbits;
import phitrans;
import instident;

let MDR_INVALID: i32 = 0;      // dirty (with the instruction to rescan from, or -1)
let MDR_CLOBBER: i32 = 1;
let MDR_DEF: i32 = 2;
let MDR_NONLOCAL: i32 = 3;
let MDR_NONFUNCLOCAL: i32 = 4;
let MDR_SELECT: i32 = 5;
let MDR_UNKNOWN: i32 = 6;

struct MDR { k: i32, i: i32 }
fn mdr(k: i32, i: i32) -> MDR { MDR { k: k, i: i } }
fn mdr_unknown() -> MDR { mdr(MDR_UNKNOWN, -1) }
fn mdr_nonlocal() -> MDR { mdr(MDR_NONLOCAL, -1) }
fn mdr_nonfunclocal() -> MDR { mdr(MDR_NONFUNCLOCAL, -1) }
fn mdr_inst(r: MDR) -> i32 { if r.k <= MDR_DEF { r.i } else { -1 } }
fn mdr_is_local(r: MDR) -> bool { r.k == MDR_CLOBBER || r.k == MDR_DEF }
fn mdr_is_dirty(r: MDR) -> bool { r.k == MDR_INVALID }
fn mdr_eq(a: MDR, b: MDR) -> bool { a.k == b.k && mdr_inst(a) == mdr_inst(b) }

// NonLocalDepEntry
struct NLE { bb: i32, r: MDR }
// NonLocalDepResult: SelectAddr is (v, a1, a2): v = Addr (a1 = a2 = -1), or v = the select condition
struct NLR { bb: i32, r: MDR, v: i32, a1: i32, a2: i32 }
// a vector of NonLocalDepEntry: a run in md_ents
struct MVec { start: i32, len: i32, cap: i32 }
// NonLocalPointerInfo
struct NLPI { pair_bb: i32, pair_skip: bool, size: u64, tags: ML, deps: i32, alive: bool }

var md_on: bool = false;
var md_fn: i32 = -1;
var md_ents: NLE[>..<];
var md_vecs: MVec[>..<];
var md_nlpis: NLPI[>..<];
var md_nldefs: NLR[>..<];

var md_local = hm_new();       // LocalDeps: inst -> index into md_local_r
var md_local_r: MDR[>..<];
var md_nldeps = hm_new();      // NonLocalDepsMap: inst -> vec << 1 | dirty
var md_nlptr = hm_new();       // NonLocalPointerDeps: (ptr << 1 | isLoad) -> NLPI index
var md_nldefs_map = hm_new();  // NonLocalDefsCache: load -> NLR index
var md_clobber_off = hm_new(); // ClobberOffsets
var md_predc = hm_new();       // PredIteratorCache: block -> (start << 32 | len) in md_preds
var md_preds: i32[>..<];

// Reverse maps
let RM_LOCAL: u64 = 0;
let RM_NONLOCAL: u64 = 1;
let RM_PTR: u64 = 2;
let RM_DEFS: u64 = 3;
struct RNode { key: i32, mem: i64, prev: i32, next: i32, map: u8 }
var md_rnodes: RNode[>..<];
var md_rfree: i32[>..<];
var md_rhead = hm_new();       // (map, key) -> first node
var md_rpair = hm_new();       // hash of (map, key, member) -> node (chained through md_rpair_next on collision)

// NonLocalPointerDepVisited (per block number: value and epoch)
var md_vis_val: i32[>..];
var md_vis_ep: i64[>..];
var md_vis_epoch: i64 = 0;

// options
var md_scan_limit: i64 = 100;
var md_block_limit: i64 = 200;
var md_cache_limit: i64 = 10000;
let MD_NUM_RESULTS_LIMIT: i64 = 100;

fn md_not_ported(what: const u8[:]) { fatal(str("MemoryDependenceAnalysis: ", what, " is not ported yet")); }

// MemoryDependenceAnalysis::run
fn mdep_begin(fv: i32) {
    md_on = true;
    md_fn = fv;
    md_scan_limit = flag_int("memdep-block-scan-limit", 100);
    md_block_limit = flag_int("memdep-block-number-limit", 200);
    md_cache_limit = flag_int("memdep-cache-global-limit", 10000);
    md_ents.clear();
    md_vecs.clear();
    md_nlpis.clear();
    md_nldefs.clear();
    md_local_r.clear();
    hm_clear(md_local);
    hm_clear(md_nldeps);
    hm_clear(md_nlptr);
    hm_clear(md_nldefs_map);
    hm_clear(md_clobber_off);
    hm_clear(md_predc);
    md_preds.clear();
    md_rnodes.clear();
    md_rfree.clear();
    hm_clear(md_rhead);
    hm_clear(md_rpair);
    aa_begin(fv);
    ea_begin(false, false);
}
fn mdep_end() { md_on = false; }

// ---------------------------------------------------------------------------------------------
// Containers

fn mv_new() -> i32 {
    let v = md_vecs.len as i32;
    md_vecs.push(MVec { start: md_ents.len as i32, len: 0, cap: 0 });
    return v;
}
fn mv_len(v: i32) -> i64 { md_vecs[v].len as i64 }
fn mv_at(v: i32, k: i64) -> i64 { md_vecs[v].start as i64 + k }
fn mv_push(v: i32, e: NLE) {
    if md_vecs[v].len == md_vecs[v].cap {
        var ncap = md_vecs[v].cap * 2;
        if ncap < 4 { ncap = 4; }
        let st = md_ents.len as i32;
        for k in md_vecs[v].len { let x = md_ents[md_vecs[v].start + k]; md_ents.push(x); }
        for k in ncap - md_vecs[v].len { md_ents.push(NLE { bb: -1, r: mdr_unknown() }); }
        md_vecs[v].start = st;
        md_vecs[v].cap = ncap;
    }
    md_ents[md_vecs[v].start + md_vecs[v].len] = e;
    md_vecs[v].len++;
}
fn mv_clear(v: i32) { md_vecs[v].len = 0; }
fn mv_pop(v: i32) -> NLE { md_vecs[v].len--; return md_ents[md_vecs[v].start + md_vecs[v].len]; }
// insert e at position k (std::vector::insert)
fn mv_insert(v: i32, k: i64, e: NLE) {
    mv_push(v, e);
    var j = mv_len(v) - 1;
    while j > k { md_ents[mv_at(v, j)] = md_ents[mv_at(v, j - 1)]; j--; }
    md_ents[mv_at(v, k)] = e;
}

// std::sort over [0, n) by block id
fn mv_sort_prefix(v: i32, n: i64) {
    if n < 2 { return; }
    var tmp: NLE[>..<] = [];
    for k in n { tmp.push(md_ents[mv_at(v, k)]); }
    sort(tmp) { a, b => a.bb < b.bb };
    for k in n { md_ents[mv_at(v, k)] = tmp[k]; }
}
fn mv_sort(v: i32) { mv_sort_prefix(v, mv_len(v)); }

// std::upper_bound(begin, begin + n, NonLocalDepEntry(bb))
fn mv_upper_bound(v: i32, n: i64, bb: i32) -> i64 {
    var lo: i64 = 0;
    var hi = n;
    while lo < hi {
        let mid = (lo + hi) / 2;
        if bb < md_ents[mv_at(v, mid)].bb { hi = mid; } else { lo = mid + 1; }
    }
    return lo;
}

fn rm_head_key(map: u64, key: i32) -> u64 { (map << 62) | ((key as i64) as u64) }
fn rm_pair_key(map: u64, key: i32, mem: i64) -> u64 {
    if key >= 0x40000000 || mem >= 0x100000000 { md_not_ported("more than 2^30 values"); }
    return (map << 62) | (((key as i64) as u64) << 32) | (mem as u64);
}
// ReverseMap[key].insert(mem)
fn rm_insert(map: u64, key: i32, mem: i64) {
    let pk = rm_pair_key(map, key, mem);
    if hm_has(md_rpair, pk) { return; }
    var n: i32 = -1;
    if md_rfree.len > 0 { n = md_rfree.pop(); } else { n = md_rnodes.len as i32; md_rnodes.push(RNode { key: 0, mem: 0, prev: -1, next: -1, map: 0 }); }
    let hk = rm_head_key(map, key);
    let h = hm_get(md_rhead, hk, -1) as i32;
    md_rnodes[n] = RNode { key: key, mem: mem, prev: -1, next: h, map: map as u8 };
    if h >= 0 { md_rnodes[h].prev = n; }
    hm_put(md_rhead, hk, n as i64);
    hm_put(md_rpair, pk, n as i64);
}
// ReverseMap[key].erase(mem) (RemoveFromReverseMap also erases the key when the set becomes empty: same here)
fn rm_erase(map: u64, key: i32, mem: i64) {
    let pk = rm_pair_key(map, key, mem);
    let n = hm_get(md_rpair, pk, -1) as i32;
    if n < 0 { return; }
    hm_del(md_rpair, pk);
    let p = md_rnodes[n].prev;
    let nx = md_rnodes[n].next;
    if p >= 0 { md_rnodes[p].next = nx; } else {
        let hk = rm_head_key(map, key);
        if nx >= 0 { hm_put(md_rhead, hk, nx as i64); } else { hm_del(md_rhead, hk); }
    }
    if nx >= 0 { md_rnodes[nx].prev = p; }
    md_rfree.push(n);
}
// take the whole set of key (ReverseMap.find + erase): members appended to out
fn rm_take(map: u64, key: i32, out: i64[>..<]&) {
    let hk = rm_head_key(map, key);
    var n = hm_get(md_rhead, hk, -1) as i32;
    while n >= 0 {
        out.push(md_rnodes[n].mem);
        let nx = md_rnodes[n].next;
        hm_del(md_rpair, rm_pair_key(map, key, md_rnodes[n].mem));
        md_rfree.push(n);
        n = nx;
    }
    hm_del(md_rhead, hk);
}

// PredIteratorCache::get(BB)
fn md_pred_run(bb: i32) -> i64, i64 {
    let e = hm_get(md_predc, (bb as i64) as u64, -1);
    if e >= 0 { return e >> 32, e & 0xFFFFFFFF; }
    let st = md_preds.len;
    each_pred(bb) { p => md_preds.push(p); };
    let n = md_preds.len - st;
    hm_put(md_predc, (bb as i64) as u64, (st << 32) | n);
    return st, n;
}
// invalidateCachedPredecessors
fn mdep_invalidate_cached_predecessors() {
    hm_clear(md_predc);
    md_preds.clear();
}

fn md_vis_set(bb: i32, v: i32) {
    let k = block_number(bb) as i64;
    while md_vis_val.len <= k { md_vis_val.push(-1); md_vis_ep.push(0); }
    md_vis_val[k] = v;
    md_vis_ep[k] = md_vis_epoch;
}
fn md_vis_has(bb: i32) -> bool {
    let k = block_number(bb) as i64;
    return k < md_vis_ep.len && md_vis_ep[k] == md_vis_epoch;
}
fn md_vis_get(bb: i32) -> i32 { md_vis_val[block_number(bb) as i64] }

fn md_is_entry(bb: i32) -> bool { func_entry(block_func(bb)) == bb }

// ---------------------------------------------------------------------------------------------
// GetLocation(Inst, Loc, TLI): (ModRefInfo, Loc); Loc.ptr == ML_NULL when there is none

fn md_get_location(i: i32) -> i64, ML {
    let o = iop(i);
    if o == OP_LOAD {
        if ldst_is_unordered(i) { return MR_REF, ml_get(i); }
        if insts[inst_of(i)].ord == 2 { return MR_MODREF, ml_get(i); }
        return MR_MODREF, ml_null();
    }
    if o == OP_STORE {
        if ldst_is_unordered(i) { return MR_MOD, ml_get(i); }
        if insts[inst_of(i)].ord == 2 { return MR_MODREF, ml_get(i); }
        return MR_MODREF, ml_null();
    }
    if o == OP_VAARG { return MR_MODREF, ml_get(i); }
    if is_callbase(i) {
        let fo = get_freed_operand(i);
        if fo >= 0 { return MR_MOD, ml_after(fo); }
    }
    if o == OP_CALL {
        let id = call_iid(i);
        if id == IID_lifetime_start || id == IID_lifetime_end { return MR_MOD, ml_for_argument(i, 0, true); }
        if id == IID_invariant_start { return MR_MOD, ml_for_argument(i, 1, true); }
        if id == IID_invariant_end { return MR_MOD, ml_for_argument(i, 2, true); }
        if id == IID_masked_load { return MR_REF, ml_for_argument(i, 0, true); }
        if id == IID_masked_store { return MR_MOD, ml_for_argument(i, 1, true); }
    }
    if inst_may_write_memory(i) { return MR_MODREF, ml_null(); }
    if inst_may_read_memory(i) { return MR_REF, ml_null(); }
    return MR_NO, ml_null();
}

// AAResults::onlyReadsMemory(Call)
fn md_only_reads(c: i32) -> bool { me_only_reads(aa_call_me_simple(c)) }

// the instruction before the iterator `pos` (-1 = end()) in bb; -1 at begin()
fn md_prev(bb: i32, pos: i32) -> i32 { if pos < 0 { block_last(bb) } else { inst_prev(pos) } }

// getCallDependencyFrom
fn md_call_dep_from(call: i32, is_ro: bool, pos: i32, bb: i32) -> MDR {
    var limit = md_scan_limit;
    let inv_load = inst_get_md(call, MDK_INVARIANT_LOAD) >= 0;
    var cur = pos;
    loop {
        let inst = md_prev(bb, cur);
        if inst < 0 { break; }
        cur = inst;
        limit--;
        if limit == 0 { return mdr_unknown(); }
        let mr, loc = md_get_location(inst);
        if loc.ptr != ML_NULL {
            if mr_any(aa_inst_loc_mr_simple(call, loc)) {
                if inv_load { continue; }
                return mdr(MDR_CLOBBER, inst);
            }
            continue;
        }
        if is_callbase(inst) {
            let ident_ro = is_ro && !mr_is_mod(mr) && cu_identical_when_defined_md(call, inst);
            if inv_load && ident_ro { return mdr(MDR_DEF, inst); }
            if aa_inst_call_mr_simple(call, inst) == MR_NO {
                if ident_ro { return mdr(MDR_DEF, inst); }
                continue;
            } else if inv_load {
                continue;
            } else {
                return mdr(MDR_CLOBBER, inst);
            }
        }
        if mr_any(mr) { return mdr(MDR_CLOBBER, inst); }
    }
    if !md_is_entry(bb) { return mdr_nonlocal(); }
    return mdr_nonfunclocal();
}

// Instruction::isIdenticalToWhenDefined (no attribute intersection)
fn cu_identical_when_defined_md(a: i32, b: i32) -> bool { ii_is_identical_when_defined(a, b, false) }

// getPointerDependencyFrom(MemLoc, isLoad, ScanIt, BB, QueryInst, Limit, BatchAA); limit: the caller's counter
fn md_ptr_dep_from_q(loc: ML, is_load: bool, pos: i32, bb: i32, qi: i32, limit: i64&, q: i32) -> MDR {
    var igd = mdr_unknown();
    if qi >= 0 && iop(qi) == OP_LOAD {
        igd = md_invariant_group_dep(qi, bb);
        if igd.k == MDR_DEF { return igd; }
    }
    let sd = md_simple_ptr_dep_from(loc, is_load, pos, bb, qi, limit, q);
    if sd.k == MDR_DEF { return sd; }
    if igd.k == MDR_NONLOCAL { return igd; }
    return sd;
}
// getPointerDependencyFrom(MemLoc, isLoad, ScanIt, BB, QueryInst, Limit) with its own BatchAAResults(AA, &EEA)
fn md_ptr_dep_from(loc: ML, is_load: bool, pos: i32, bb: i32, qi: i32) -> MDR {
    let q = aq_push(CA_EARLIEST);
    var limit = md_scan_limit;
    let r = md_ptr_dep_from_q(loc, is_load, pos, bb, qi, limit, q);
    aq_pop(q);
    return r;
}

// getInvariantGroupPointerDependency
fn md_invariant_group_dep(li: i32, bb: i32) -> MDR {
    if inst_get_md(li, MDK_INVARIANT_GROUP) < 0 { return mdr_unknown(); }
    let lop = strip_pointer_casts(op(li, 0));
    if is_global(lop) { return mdr_unknown(); }
    if !has_use_list(lop) { return mdr_unknown(); }
    var closest: i32 = -1;
    var u = vals[lop].first_use;
    while u >= 0 {
        let x = uses[u].user;
        u = uses[u].next;
        if !is_inst(x) || x == li || !dt_value_dominates_inst(x, li) { continue; }
        if (iop(x) == OP_LOAD || (iop(x) == OP_STORE && op(x, 1) == lop)) && inst_get_md(x, MDK_INVARIANT_GROUP) >= 0 {
            if closest < 0 || dt_value_dominates_inst(closest, x) { closest = x; }
        }
    }
    if closest < 0 { return mdr_unknown(); }
    if inst_parent(closest) == bb { return mdr(MDR_DEF, closest); }
    if !hm_has(md_nldefs_map, (li as i64) as u64) {
        let k = md_nldefs.len;
        md_nldefs.push(NLR { bb: inst_parent(closest), r: mdr(MDR_DEF, closest), v: -1, a1: -1, a2: -1 });
        hm_put(md_nldefs_map, (li as i64) as u64, k);
    }
    rm_insert(RM_DEFS, closest, li as i64);
    return mdr_nonlocal();
}

fn md_ldst_align(i: i32) -> i64 { let a = insts[inst_of(i)].align; return if a == 0 { 1 } else { 1 << (a - 1) as i64 }; }

// canSkipClobberingStore
fn md_can_skip_clobbering_store(si: i32, loc: ML, loc_align: i64, q: i32, scan_limit: i64) -> bool {
    if !ls_has_value(loc.size) { return false; }
    if ml_get(si).size != loc.size { return false; }
    if ls_is_scalable(loc.size) { return false; }
    var a = loc_align;
    let sa = md_ldst_align(si);
    if sa < a { a = sa; }
    if (a as u64) < ls_value(loc.size) { return false; }
    let li = op(si, 0);
    if !is_inst_op(li, OP_LOAD) || inst_parent(li) != inst_parent(si) { return false; }
    if aa_alias(ml_get(li), loc, q, -1).k != AR_MUST as u8 { return false; }
    var n: i64 = 0;
    var i = li;
    while i != si {
        n++;
        if n > scan_limit || mr_is_mod(aa_inst_loc_mr(i, loc, q)) { return false; }
        i = inst_next(i);
    }
    return true;
}

// isStrongerThan(AO, Other)
fn md_stronger(a: u8, b: u8) -> bool {
    let t: const u8[:] = "0000000010000000110000001110000011110000111000001111110011111110";
    return t[(a as i64) * 8 + (b as i64)] == '1';
}

fn md_complex_for_reordering(i: i32, ao: u8) -> bool {
    if inst_is_volatile(i) { return true; }
    if iop(i) == OP_LOAD || iop(i) == OP_STORE { return md_stronger(insts[inst_of(i)].ord, ao); }
    return inst_may_read_memory(i) || inst_may_write_memory(i);
}

fn md_must_alias(a: ML, b: ML, q: i32) -> bool { aa_alias(a, b, q, -1).k == AR_MUST as u8 }

// getSimplePointerDependencyFrom
fn md_simple_ptr_dep_from(loc: ML, is_load: bool, pos: i32, bb: i32, qi: i32, limit: i64&, q: i32) -> MDR {
    var inv_load = false;
    var loc_align = pointer_alignment(loc.ptr);
    if is_load && qi >= 0 {
        inv_load = inst_get_md(qi, MDK_INVARIANT_LOAD) >= 0;
        if iop(qi) == OP_LOAD { loc_align = md_ldst_align(qi); }
    }
    var cur = pos;
    loop {
        let inst = md_prev(bb, cur);
        if inst < 0 { break; }
        cur = inst;
        limit--;
        if limit == 0 { return mdr_unknown(); }
        let o = iop(inst);
        if o == OP_CALL {
            let id = call_iid(inst);
            if id == IID_lifetime_start {
                if md_must_alias(ml_after(cb_arg(inst, 0)), loc, q) { return mdr(MDR_DEF, inst); }
                continue;
            }
            if id == IID_masked_load || id == IID_masked_store {
                let mr, l2 = md_get_location(inst);
                let r = aa_alias(l2, loc, q, -1);
                if r.k == AR_NO as u8 { continue; }
                if r.k == AR_MUST as u8 { return mdr(MDR_DEF, inst); }
                if id == IID_masked_load { continue; }
                return mdr(MDR_CLOBBER, inst);
            }
        }
        if o == OP_LOAD {
            if inst_is_volatile(inst) {
                if qi < 0 { return mdr(MDR_CLOBBER, inst); }
                if inst_is_volatile(qi) { return mdr(MDR_CLOBBER, inst); }
            }
            let ord = insts[inst_of(inst)].ord;
            if ord != 0 && ord > 1 {
                if qi < 0 || md_complex_for_reordering(qi, 0) { return mdr(MDR_CLOBBER, inst); }
                if ord != 2 { return mdr(MDR_CLOBBER, inst); }
            }
            let lloc = ml_get(inst);
            let r = aa_alias(lloc, loc, q, -1);
            if r.k == AR_NO as u8 { continue; }
            if is_load {
                if r.k == AR_MUST as u8 { return mdr(MDR_DEF, inst); }
                if r.k == AR_PARTIAL as u8 && r.has_off {
                    hm_put(md_clobber_off, (inst as i64) as u64, r.off as i64);
                    return mdr(MDR_CLOBBER, inst);
                }
                continue;
            }
            if !mr_is_mod(aa_mod_ref_mask(lloc, q, false)) { continue; }
            return mdr(MDR_DEF, inst);
        }
        if o == OP_STORE {
            let ord = insts[inst_of(inst)].ord;
            if !ldst_is_unordered(inst) && ord != 0 {
                if qi < 0 || md_complex_for_reordering(qi, 1) { return mdr(MDR_CLOBBER, inst); }
            }
            if inst_is_volatile(inst) {
                if qi < 0 || inst_is_volatile(qi) { return mdr(MDR_CLOBBER, inst); }
            }
            if !mr_any(aa_inst_loc_mr(inst, loc, q)) { continue; }
            let sloc = ml_get(inst);
            let r = aa_alias(sloc, loc, q, -1);
            if r.k == AR_NO as u8 { continue; }
            if r.k == AR_MUST as u8 { return mdr(MDR_DEF, inst); }
            if inv_load { continue; }
            if md_can_skip_clobbering_store(inst, loc, loc_align, q, limit) { continue; }
            return mdr(MDR_CLOBBER, inst);
        }
        if o == OP_ALLOCA || aa_is_noalias_call(inst) {
            let ap = get_underlying_object(loc.ptr, 10);
            if ap == inst || md_must_alias(ml_before_or_after(inst), ml_before_or_after(ap), q) { return mdr(MDR_DEF, inst); }
        }
        if o == OP_SELECT && loc.ptr == inst { return mdr(MDR_DEF, inst); }
        if inv_load { continue; }
        if o == OP_FENCE && is_load && insts[inst_of(inst)].ord == 5 { continue; }
        let mr = aa_inst_loc_mr(inst, loc, q);
        if mr == MR_NO { continue; }
        if mr == MR_MOD { return mdr(MDR_CLOBBER, inst); }
        if mr == MR_REF && is_load { continue; }
        return mdr(MDR_CLOBBER, inst);
    }
    if !md_is_entry(bb) { return mdr_nonlocal(); }
    return mdr_nonfunclocal();
}

// ---------------------------------------------------------------------------------------------
// getDependency

fn md_local_get(i: i32) -> i64 {
    let k = hm_get(md_local, (i as i64) as u64, -1);
    if k >= 0 { return k; }
    let n = md_local_r.len;
    md_local_r.push(mdr(MDR_INVALID, -1));
    hm_put(md_local, (i as i64) as u64, n);
    return n;
}

fn mdep_get_dependency(qi: i32) -> MDR {
    hm_clear(md_clobber_off);
    var scan_pos = qi;
    let lc = md_local_get(qi);
    if !mdr_is_dirty(md_local_r[lc]) { return md_local_r[lc]; }
    let old = mdr_inst(md_local_r[lc]);
    if old >= 0 {
        scan_pos = old;
        rm_erase(RM_LOCAL, old, qi as i64);
    }
    let qp = inst_parent(qi);
    var res = mdr_unknown();
    if block_first(qp) == qi {
        res = if !md_is_entry(qp) { mdr_nonlocal() } else { mdr_nonfunclocal() };
    } else {
        let mr, loc = md_get_location(qi);
        if loc.ptr != ML_NULL {
            var is_load = !mr_is_mod(mr);
            if call_iid_or0(qi) == IID_lifetime_start { is_load = true; }
            res = md_ptr_dep_from(loc, is_load, scan_pos, qp, qi);
        } else if is_callbase(qi) {
            let ro = md_only_reads(qi);
            res = md_call_dep_from(qi, ro, scan_pos, qp);
        } else {
            res = mdr_unknown();
        }
    }
    md_local_r[lc] = res;
    let ri = mdr_inst(res);
    if ri >= 0 { rm_insert(RM_LOCAL, ri, qi as i64); }
    return res;
}

fn call_iid_or0(i: i32) -> i32 { if iop(i) == OP_CALL { call_iid(i) } else { 0 } }

// getClobberOffset(DepInst)
fn mdep_clobber_offset(li: i32) -> i64, bool {
    let k = hm_find(md_clobber_off, (li as i64) as u64);
    if k < 0 { return 0, false; }
    return md_clobber_off.slots[k].val, true;
}

// ---------------------------------------------------------------------------------------------
// getNonLocalCallDependency: the vector id of the cache

fn mdep_nonlocal_call_dependency(qc: i32) -> i32 {
    var e = hm_get(md_nldeps, (qc as i64) as u64, -1);
    if e < 0 {
        let v = mv_new();
        e = (v as i64) << 1;
        hm_put(md_nldeps, (qc as i64) as u64, e);
    }
    let cache = (e >> 1) as i32;
    var dirty: i32[>..<] = [];
    if mv_len(cache) > 0 {
        if (e & 1) == 0 { return cache; }
        for k in mv_len(cache) {
            let x = md_ents[mv_at(cache, k)];
            if mdr_is_dirty(x.r) { dirty.push(x.bb); }
        }
        mv_sort(cache);
    } else {
        let st, n = md_pred_run(inst_parent(qc));
        for k in n { dirty.push(md_preds[st + k]); }
    }
    // CacheP.second is not reset here in LLVM either (only a fresh entry starts clean)
    let is_ro = md_only_reads(qc);
    var visited: i32[>..<] = [];
    let nsorted = mv_len(cache);
    while dirty.len > 0 {
        let dbb = dirty.pop();
        if position(visited, dbb) >= 0 { continue; }
        visited.push(dbb);
        var ent = mv_upper_bound(cache, nsorted, dbb);
        if ent != 0 && md_ents[mv_at(cache, ent - 1)].bb == dbb { ent--; }
        var existing: i64 = -1;
        if ent != nsorted && md_ents[mv_at(cache, ent)].bb == dbb {
            if !mdr_is_dirty(md_ents[mv_at(cache, ent)].r) { continue; }
            existing = ent;
        }
        var scan_pos: i32 = -1;
        if existing >= 0 {
            let ei = mdr_inst(md_ents[mv_at(cache, existing)].r);
            if ei >= 0 {
                scan_pos = ei;
                rm_erase(RM_NONLOCAL, ei, qc as i64);
            }
        }
        var dep = mdr_unknown();
        if scan_pos != block_first(dbb) {
            dep = md_call_dep_from(qc, is_ro, scan_pos, dbb);
        } else if !md_is_entry(dbb) {
            dep = mdr_nonlocal();
        } else {
            dep = mdr_nonfunclocal();
        }
        if existing >= 0 { md_ents[mv_at(cache, existing)].r = dep; }
        else { mv_push(cache, NLE { bb: dbb, r: dep }); }
        if dep.k != MDR_NONLOCAL {
            let di = mdr_inst(dep);
            if di >= 0 { rm_insert(RM_NONLOCAL, di, qc as i64); }
        } else {
            let st, n = md_pred_run(dbb);
            for k in n { dirty.push(md_preds[st + k]); }
        }
    }
    return cache;
}

// ---------------------------------------------------------------------------------------------
// getNonLocalPointerDependency(QueryInst, Result)

var md_result: NLR[>..<];   // the Result vector of the outermost query (read by GVN)

fn md_res_push(bb: i32, r: MDR, addr: i32) { md_result.push(NLR { bb: bb, r: r, v: addr, a1: -1, a2: -1 }); }

fn mdep_nonlocal_pointer_dependency(qi: i32) {
    let loc = ml_get(qi);
    let is_load = iop(qi) == OP_LOAD;
    let from = inst_parent(qi);
    md_result.clear();
    let dk = hm_get(md_nldefs_map, (qi as i64) as u64, -1);
    if dk >= 0 {
        let x = md_nldefs[dk];
        md_result.push(x);
        rm_erase(RM_DEFS, mdr_inst(x.r), qi as i64);
        hm_del(md_nldefs_map, (qi as i64) as u64);
        return;
    }
    var ordered = false;
    if iop(qi) == OP_LOAD || iop(qi) == OP_STORE { ordered = !ldst_is_unordered(qi); }
    if inst_is_volatile(qi) || ordered {
        md_res_push(from, mdr_unknown(), loc.ptr);
        return;
    }
    let pm = pta_mark();
    let addr = pta_new(loc.ptr, true);
    md_vis_epoch++;
    let ok = md_nonlocal_ptr_dep_from_bb(qi, addr, loc, is_load, from, true, false);
    pta_release(pm);
    if ok { return; }
    md_result.clear();
    md_res_push(from, mdr_unknown(), loc.ptr);
}

fn md_ptr_key(p: i32, is_load: bool) -> u64 { (((p as i64) as u64) << 1) | (if is_load { 1 as u64 } else { 0 as u64 }) }

fn md_tags_eq(a: ML, b: ML) -> bool {
    a.tbaa == b.tbaa && a.tbaa_struct == b.tbaa_struct && a.scope == b.scope && a.noalias == b.noalias && a.noalias_as == b.noalias_as
}
fn md_tags_any(a: ML) -> bool { a.tbaa >= 0 || a.tbaa_struct >= 0 || a.scope >= 0 || a.noalias >= 0 || a.noalias_as >= 0 }
fn md_without_tags(l: ML) -> ML { ml_make(l.ptr, l.size) }

// NonLocalPointerDeps[key] (inserting a default NonLocalPointerInfo)
fn md_nlpi_get(key: u64) -> i64 {
    let k = hm_get(md_nlptr, key, -1);
    if k >= 0 { return k; }
    let n = md_nlpis.len;
    md_nlpis.push(NLPI { pair_bb: -1, pair_skip: false, size: LS_MAP_EMPTY, tags: ml_null(), deps: mv_new(), alive: true });
    hm_put(md_nlptr, key, n);
    return n;
}

// getNonLocalInfoForBlock
fn md_nonlocal_info_for_block(qi: i32, loc: ML, is_load: bool, bb: i32, cache: i32, nsorted: i64, q: i32) -> MDR {
    var inv_load = false;
    if qi >= 0 { inv_load = inst_get_md(qi, MDK_INVARIANT_LOAD) >= 0; }
    var ent = mv_upper_bound(cache, nsorted, bb);
    if ent != 0 && md_ents[mv_at(cache, ent - 1)].bb == bb { ent--; }
    var existing: i64 = -1;
    if ent != nsorted && md_ents[mv_at(cache, ent)].bb == bb { existing = ent; }
    if existing >= 0 && inv_load && md_ents[mv_at(cache, existing)].r.k != MDR_NONFUNCLOCAL { existing = -1; }
    if existing >= 0 && !mdr_is_dirty(md_ents[mv_at(cache, existing)].r) { return md_ents[mv_at(cache, existing)].r; }
    var scan_pos: i32 = -1;
    if existing >= 0 && mdr_inst(md_ents[mv_at(cache, existing)].r) >= 0 {
        scan_pos = mdr_inst(md_ents[mv_at(cache, existing)].r);
        rm_erase(RM_PTR, scan_pos, md_ptr_key(loc.ptr, is_load) as i64);
    }
    var limit = md_scan_limit;
    let dep = md_ptr_dep_from_q(loc, is_load, scan_pos, bb, qi, limit, q);
    if inv_load { return dep; }
    if existing >= 0 { md_ents[mv_at(cache, existing)].r = dep; }
    else { mv_push(cache, NLE { bb: bb, r: dep }); }
    if !mdr_is_local(dep) { return dep; }
    rm_insert(RM_PTR, mdr_inst(dep), md_ptr_key(loc.ptr, is_load) as i64);
    return dep;
}

fn md_log2_32(x: i64) -> i64 { var r: i64 = -1; var v = x; while v > 0 { r++; v = v >> 1; } return r; }

// SortNonLocalDepInfoCache
fn md_sort_cache(cache: i32, nsorted: i64) {
    let n = mv_len(cache);
    if n < 2 { return; }
    var s = n - nsorted;
    if s == 0 { return; }
    if nsorted == 0 { mv_sort(cache); return; }
    if s < md_log2_32(n) {
        while s > 0 {
            let val = mv_pop(cache);
            // upper_bound(begin, end - s + 1, Val) over the shrunken vector
            let lim = mv_len(cache) - s + 1;
            let at = mv_upper_bound(cache, lim, val.bb);
            mv_insert(cache, at, val);
            s--;
        }
    } else {
        mv_sort(cache);
    }
}

fn md_clear_nlpi_deps(ni: i64, key: u64) {
    let v = md_nlpis[ni].deps;
    for k in mv_len(v) {
        let ei = mdr_inst(md_ents[mv_at(v, k)].r);
        if ei >= 0 { rm_erase(RM_PTR, ei, key as i64); }
    }
    mv_clear(v);
}

var md_wl: i32[>..<];
var md_pl_bb: i32[>..<];
var md_pl_pta: i32[>..<];

// getNonLocalPointerDepFromBB (results appended to md_result)
recursive fn md_nonlocal_ptr_dep_from_bb(qi: i32, pointer: i32, loc: ML, is_load: bool, start_bb: i32, skip_first0: bool, incomplete0: bool) -> bool {
    var skip_first = skip_first0;
    var incomplete = incomplete0;
    let key = md_ptr_key(pta_get_addr(pointer), is_load);
    var inv_load = false;
    if qi >= 0 { inv_load = inst_get_md(qi, MDK_INVARIANT_LOAD) >= 0; }
    let existed = hm_has(md_nlptr, key);
    var ci = md_nlpi_get(key);
    if !existed {
        md_nlpis[ci].size = loc.size;
        md_nlpis[ci].tags = loc;
    }
    if !inv_load && existed {
        if md_nlpis[ci].size != loc.size {
            md_nlpis[ci].pair_bb = -1;
            md_nlpis[ci].pair_skip = false;
            md_nlpis[ci].size = loc.size;
            md_clear_nlpi_deps(ci, key);
            incomplete = true;
        }
        if !md_tags_eq(md_nlpis[ci].tags, loc) {
            if md_tags_any(md_nlpis[ci].tags) {
                md_nlpis[ci].pair_bb = -1;
                md_nlpis[ci].pair_skip = false;
                md_nlpis[ci].tags = ml_null();
                md_clear_nlpi_deps(ci, key);
                incomplete = true;
            }
            if md_tags_any(loc) {
                return md_nonlocal_ptr_dep_from_bb(qi, pointer, md_without_tags(loc), is_load, start_bb, skip_first, incomplete);
            }
        }
    }
    var cache = md_nlpis[ci].deps;
    if !incomplete && !inv_load && md_nlpis[ci].pair_bb == start_bb && md_nlpis[ci].pair_skip == skip_first && start_bb >= 0 {
        for k in mv_len(cache) {
            let ebb = md_ents[mv_at(cache, k)].bb;
            if !md_vis_has(ebb) { continue; }
            if md_vis_get(ebb) == pta_get_addr(pointer) { continue; }
            return false;
        }
        let addr = pta_get_addr(pointer);
        for k in mv_len(cache) {
            let e = md_ents[mv_at(cache, k)];
            md_vis_set(e.bb, addr);
            if e.r.k == MDR_NONLOCAL { continue; }
            if dt_has_node(DT_DOM, e.bb) { md_res_push(e.bb, e.r, addr); }
        }
        return true;
    }
    if mv_len(cache) > md_cache_limit { return false; }
    if !inv_load {
        if !incomplete && mv_len(cache) == 0 { md_nlpis[ci].pair_bb = start_bb; md_nlpis[ci].pair_skip = skip_first; }
        else { md_nlpis[ci].pair_bb = -1; md_nlpis[ci].pair_skip = false; }
    }
    // Worklist and PredList live on global stacks (the function is recursive): ours start at wbase / pbase
    let wbase = md_wl.len;
    md_wl.push(start_bb);
    let pbase = md_pl_bb.len;
    var nsorted = mv_len(cache);
    var wl_entries = md_block_limit;
    var cache_valid = true;     // Cache != nullptr
    let q = aq_push(CA_EARLIEST);
    while md_wl.len > wbase {
        let bb = md_wl.pop();
        if (md_result.len as i64) > MD_NUM_RESULTS_LIMIT {
            if cache_valid && nsorted != mv_len(cache) { md_sort_cache(cache, nsorted); }
            md_nlpis[ci].pair_bb = -1;
            md_nlpis[ci].pair_skip = false;
            md_wl.resize(wbase);
            md_pl_bb.resize(pbase);
            md_pl_pta.resize(pbase);
            aq_pop(q);
            return false;
        }
        var failure = false;
        var done = false;
        if !skip_first {
            let dep = md_nonlocal_info_for_block(qi, loc, is_load, bb, cache, nsorted, q);
            if dep.k != MDR_NONLOCAL {
                if dt_has_node(DT_DOM, bb) {
                    md_res_push(bb, dep, pta_get_addr(pointer));
                    continue;
                }
            }
        }
        if !pta_needs_translation_from_block(pointer, bb) {
            skip_first = false;
            var newb: i32[>..<] = [];
            let st, n = md_pred_run(bb);
            for k in n {
                let p = md_preds[st + k];
                if !md_vis_has(p) {
                    md_vis_set(p, pta_get_addr(pointer));
                    newb.push(p);
                    continue;
                }
                let prev = md_vis_get(p);
                if prev != pta_get_addr(pointer) {
                    for nb in newb { md_vis_set(nb, -1); }
                    failure = true;
                    break;
                }
            }
            if !failure {
                if (newb.len as i64) > wl_entries {
                    for nb in newb { md_vis_set(nb, -1); }
                    failure = true;
                } else {
                    wl_entries -= newb.len as i64;
                    for nb in newb { md_wl.push(nb); }
                    done = true;
                }
            }
        } else if !pta_is_potentially_translatable(pointer) {
            failure = true;
        } else {
            if cache_valid && nsorted != mv_len(cache) {
                md_sort_cache(cache, nsorted);
                nsorted = mv_len(cache);
            }
            cache_valid = false;
            md_pl_bb.resize(pbase);
            md_pl_pta.resize(pbase);
            let st, n = md_pred_run(bb);
            for k in n {
                let p = md_preds[st + k];
                md_pl_bb.push(p);
                let pp = pta_copy(pointer);
                md_pl_pta.push(pp);
                let ppv = pta_translate_value(pp, bb, p, false);
                if !md_vis_has(p) {
                    md_vis_set(p, ppv);
                    continue;
                }
                let prevv = md_vis_get(p);
                md_pl_bb.pop();
                md_pl_pta.pop();
                if prevv == ppv { continue; }
                for j in pbase..md_pl_bb.len { md_vis_set(md_pl_bb[j], -1); }
                failure = true;
                break;
            }
            if !failure {
                let pend = md_pl_bb.len;
                for j in pbase..pend {
                    let p = md_pl_bb[j];
                    let pp = md_pl_pta[j];
                    let ppv = pta_get_addr(pp);
                    var can = true;
                    if ppv < 0 {
                        let cond = pta_get_select_condition(pp);
                        if cond >= 0 {
                            let a1, a2 = pta_translate_select(pointer, bb, p, cond);
                            if a1 >= 0 && a2 >= 0 {
                                md_result.push(NLR { bb: p, r: mdr(MDR_SELECT, -1), v: cond, a1: a1, a2: a2 });
                                let ni = md_nlpi_get(key);
                                md_nlpis[ni].pair_bb = -1;
                                md_nlpis[ni].pair_skip = false;
                                continue;
                            }
                        }
                        can = false;
                    }
                    var ok = false;
                    if can {
                        var nl = loc;
                        nl.ptr = ppv;
                        ok = md_nonlocal_ptr_dep_from_bb(qi, pp, nl, is_load, p, false, false);
                    }
                    if !ok {
                        md_res_push(p, mdr_unknown(), ppv);
                        let ni = md_nlpi_get(key);
                        md_nlpis[ni].pair_bb = -1;
                        md_nlpis[ni].pair_skip = false;
                        continue;
                    }
                }
                ci = md_nlpi_get(key);
                cache = md_nlpis[ci].deps;
                cache_valid = true;
                nsorted = mv_len(cache);
                md_nlpis[ci].pair_bb = -1;
                md_nlpis[ci].pair_skip = false;
                skip_first = false;
                done = true;
            }
        }
        if done { continue; }
        // PredTranslationFailure:
        if !cache_valid {
            ci = md_nlpi_get(key);
            cache = md_nlpis[ci].deps;
            cache_valid = true;
            nsorted = mv_len(cache);
        }
        md_nlpis[ci].pair_bb = -1;
        md_nlpis[ci].pair_skip = false;
        if skip_first { md_pl_bb.resize(pbase); md_pl_pta.resize(pbase); md_wl.resize(wbase); aq_pop(q); return false; }
        if !inv_load {
            var k = mv_len(cache) - 1;
            while k >= 0 {
                if md_ents[mv_at(cache, k)].bb == bb {
                    md_ents[mv_at(cache, k)].r = mdr_unknown();
                    break;
                }
                k--;
            }
        }
        md_res_push(bb, mdr_unknown(), pta_get_addr(pointer));
    }
    md_pl_bb.resize(pbase);
    md_pl_pta.resize(pbase);
    md_sort_cache(cache, nsorted);
    aq_pop(q);
    return true;
}

// ---------------------------------------------------------------------------------------------
// Invalidation

// removeCachedNonLocalPointerDependencies(P)
fn md_remove_cached_nonlocal_ptr_deps(key: u64) {
    let p = (key >> 1) as i32;
    if md_nldefs_map.n > 0 {
        let dk = hm_get(md_nldefs_map, (p as i64) as u64, -1);
        if dk >= 0 {
            rm_erase(RM_DEFS, mdr_inst(md_nldefs[dk].r), p as i64);
            hm_del(md_nldefs_map, (p as i64) as u64);
        }
        if is_inst(p) {
            var users: i64[>..<] = [];
            rm_take(RM_DEFS, p, users);
            for x in users { hm_del(md_nldefs_map, x as u64); }
        }
    }
    let ni = hm_get(md_nlptr, key, -1);
    if ni < 0 { return; }
    let v = md_nlpis[ni].deps;
    for k in mv_len(v) {
        let t = mdr_inst(md_ents[mv_at(v, k)].r);
        if t < 0 { continue; }
        rm_erase(RM_PTR, t, key as i64);
    }
    md_nlpis[ni].alive = false;
    hm_del(md_nlptr, key);
}

// invalidateCachedPointerInfo(Ptr)
fn mdep_invalidate_cached_pointer_info(p: i32) {
    if !md_on { return; }
    if ty_kind(vals[p].ty) != TK_PTR { return; }
    md_remove_cached_nonlocal_ptr_deps(md_ptr_key(p, false));
    md_remove_cached_nonlocal_ptr_deps(md_ptr_key(p, true));
}

// removeInstruction(RemInst): before it leaves the IR
fn mdep_remove_instruction(rem: i32) {
    if !md_on { return; }
    ea_remove_instruction(rem);
    let rk = (rem as i64) as u64;
    let nld = hm_get(md_nldeps, rk, -1);
    if nld >= 0 {
        let v = (nld >> 1) as i32;
        for k in mv_len(v) {
            let ei = mdr_inst(md_ents[mv_at(v, k)].r);
            if ei >= 0 { rm_erase(RM_NONLOCAL, ei, rem as i64); }
        }
        hm_del(md_nldeps, rk);
    }
    let lk = hm_get(md_local, rk, -1);
    if lk >= 0 {
        let ei = mdr_inst(md_local_r[lk]);
        if ei >= 0 { rm_erase(RM_LOCAL, ei, rem as i64); }
        hm_del(md_local, rk);
    }
    if ty_kind(vals[rem].ty) == TK_PTR {
        md_remove_cached_nonlocal_ptr_deps(md_ptr_key(rem, false));
        md_remove_cached_nonlocal_ptr_deps(md_ptr_key(rem, true));
    } else {
        let dk = hm_get(md_nldefs_map, rk, -1);
        if dk >= 0 {
            rm_erase(RM_DEFS, mdr_inst(md_nldefs[dk].r), rem as i64);
            hm_del(md_nldefs_map, rk);
        }
    }
    var new_dirty = mdr(MDR_INVALID, -1);
    if !is_terminator(rem) { new_dirty = mdr(MDR_INVALID, inst_next(rem)); }
    var deps: i64[>..<] = [];
    rm_take(RM_LOCAL, rem, deps);
    if deps.len > 0 {
        for d in deps {
            let lc = md_local_get(d as i32);
            md_local_r[lc] = new_dirty;
        }
        var j = deps.len - 1;
        while j >= 0 { rm_insert(RM_LOCAL, new_dirty.i, deps[j]); j--; }
    }
    deps.clear();
    rm_take(RM_NONLOCAL, rem, deps);
    if deps.len > 0 {
        var toadd: i64[>..<] = [];
        for d in deps {
            var e = hm_get(md_nldeps, (d as u64), -1);
            if e < 0 { let nv = mv_new(); e = (nv as i64) << 1; }
            e = e | 1;
            hm_put(md_nldeps, d as u64, e);
            let v = (e >> 1) as i32;
            for k in mv_len(v) {
                if mdr_inst(md_ents[mv_at(v, k)].r) != rem { continue; }
                md_ents[mv_at(v, k)].r = new_dirty;
                if new_dirty.i >= 0 { toadd.push(d); }
            }
        }
        var j = toadd.len - 1;
        while j >= 0 { rm_insert(RM_NONLOCAL, new_dirty.i, toadd[j]); j--; }
    }
    deps.clear();
    rm_take(RM_PTR, rem, deps);
    if deps.len > 0 {
        var toadd: i64[>..<] = [];
        for p in deps {
            let ni = md_nlpi_get(p as u64);
            let v = md_nlpis[ni].deps;
            md_nlpis[ni].pair_bb = -1;
            md_nlpis[ni].pair_skip = false;
            for k in mv_len(v) {
                if mdr_inst(md_ents[mv_at(v, k)].r) != rem { continue; }
                md_ents[mv_at(v, k)].r = new_dirty;
                if new_dirty.i >= 0 { toadd.push(p); }
            }
            mv_sort(v);
        }
        var j = toadd.len - 1;
        while j >= 0 { rm_insert(RM_PTR, new_dirty.i, toadd[j]); j--; }
    }
}
