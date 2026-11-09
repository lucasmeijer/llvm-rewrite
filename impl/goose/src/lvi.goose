// LazyValueInfo: a port of llvm/lib/Analysis/LazyValueInfo.cpp (LazyValueInfoCache, LazyValueInfoImpl, the
// LazyValueInfo query interface and LazyValueInfoPrinterPass with its annotated writer).
// ValueLatticeElement is valuelattice.goose (VL), ConstantRange constrange.goose.
//
// One LazyValueInfo result exists at a time, for the function lv_fn (LazyValueAnalysis result). Like LLVM's it is
// fully lazy: the Impl (cache, guard declaration) is created by the first query (lv_impl), and the printer prints
// only its header when nothing queried LVI before. The result survives passes that preserve it (JumpThreading),
// so cached lattice values must not hold APInt pool words: wide ranges are stored as IR constants (lv_store).
//
// Cache: BlockCacheEntry per block (lv_blks, found through lv_bmap), its LatticeElements / OverDefined /
// NonNullPointers members are entries in lv_ents keyed by (block, value, kind) in lv_emap. LVIValueHandle:
// lv_vmap holds the values with a handle (the head of their entry list); ir.goose's rauw and val_set_dead call
// lvi_vh_event while handles exist (CallbackVH::allUsesReplacedWith / deleted -> eraseValue).
//
// Not ported: -lvi-per-pred-ranges (fails loudly), the legacy pass wrapper.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_attrs;
import gen_iids;
import apint;
import constrange;
import valuelattice;
import constfold;
import cfold;
import instsimplify;
import knownbits;
import pm;
import vt;
import poison;
import assume;
import speculate;
import datalayout;
import domtree;
import scev;
import flags;
import printer;
import memoryssa;

fn lv_not_ported(what: const u8[:]) { fatal(str("LazyValueInfo: ", what, " is not ported yet")); }

let LV_MAX_PROCESSED_PER_VALUE = 500;
let LV_MDK_RANGE: i32 = 4;        // FixedMetadataKinds: MD_range
let LV_K_LATTICE: i64 = 0;
let LV_K_OVERDEF: i64 = 1;
let LV_K_NONNULL: i64 = 2;

struct LvEnt { bb: i32, v: i32, kind: u8, alive: bool, vnext: i32, bnext: i32, l: VL }
struct LvBlk { head: i32, nover: i32, nn_done: bool }

var lv_fn: i32 = -1;              // function of the current LazyValueInfo result (-1: none)
var lv_impl: bool = false;        // PImpl != nullptr
var lv_guard: i32 = -1;           // GuardDecl
var lv_ents: LvEnt[>..<];
var lv_blks: LvBlk[>..<];
var lv_emap = hm_new();           // (bb, v * 4 + kind) -> entry
var lv_bmap = hm_new();           // bb -> block entry
var lv_vmap = hm_new();           // ValueHandles: v -> head of the value's entry list
var lv_stack: i64[>..<];          // BlockValueStack: (bb << 32) | v
var lv_stack_set = hm_new();      // BlockValueSet
var lv_tmp: i32[>..<];            // scratch stack (mark-based) for the recursive part of the solver

fn lv_key(bb: i32, v: i32, kind: i64) -> u64 { hk2(bb, (v * 4) + (kind as i32)) }
fn lv_pack(bb: i32, v: i32) -> i64 { ((bb as i64) << 32) | (v as i64) }
fn lv_pbb(x: i64) -> i32 { (x >> 32) as i32 }
fn lv_pv(x: i64) -> i32 { (x & 0xFFFFFFFF) as i32 }

// ---------------------------------------------------------------------------------------------
// Result lifetime (LazyValueAnalysis::run, LazyValueInfo::getOrCreateImpl, clear, invalidate)

fn lv_reset_cache() {
    lv_ents.clear();
    lv_blks.clear();
    hm_clear(lv_emap);
    hm_clear(lv_bmap);
    hm_clear(lv_vmap);
    lv_stack.clear();
    hm_clear(lv_stack_set);
    vh_lvi_n = 0;
    vh_lvi_events.clear();
}

// AM.getResult<LazyValueAnalysis>(F)
fn lvi_get(fv: i32) {
    if lv_fn == fv { return; }
    lvi_invalidate();
    lv_fn = fv;
    ac_build(fv);
}
fn lvi_valid(fv: i32) -> bool { lv_fn == fv }
fn lvi_invalidate() {
    if lv_fn < 0 { return; }
    lv_reset_cache();
    lv_fn = -1;
    lv_impl = false;
    lv_guard = -1;
}
// LazyValueInfo::getOrCreateImpl
fn lv_get_impl() {
    lvi_drain();
    if lv_impl { return; }
    lv_impl = true;
    lv_guard = lv_find_guard_decl(lv_fn);
}
// Intrinsic::getDeclarationIfExists(M, experimental_guard): a module symbol table lookup
fn lv_find_guard_decl(fv: i32) -> i32 {
    let st = modules[globs[glob_of(fv)].module].symtab;
    let f = symtab_lookup(st, intern("llvm.experimental.guard"));
    if f >= 0 && is_func(f) && func_iid(f) == IID_experimental_guard { return f; }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// Storing lattice values across passes: APInts wider than 64 bits live in the pass-local pool.

fn lv_store_ap(a: AP) -> AP {
    if a.ix < 0 { return a; }
    let c = ap_to_cint(ty_int(a.w as i64), a);
    return AP { lo: 0, w: a.w, ix: -2 - c };
}
fn lv_load_ap(a: AP) -> AP {
    if a.ix >= -1 { return a; }
    return ap_from_cint(-2 - a.ix);
}
fn lv_store(l: VL) -> VL {
    var r = l;
    r.r = CRange { lo: lv_store_ap(l.r.lo), hi: lv_store_ap(l.r.hi) };
    return r;
}
fn lv_load(l: VL) -> VL {
    var r = l;
    r.r = CRange { lo: lv_load_ap(l.r.lo), hi: lv_load_ap(l.r.hi) };
    return r;
}

// ---------------------------------------------------------------------------------------------
// LazyValueInfoCache

fn lv_block_entry(bb: i32) -> i64 { hm_get(lv_bmap, (bb as i64) as u64, -1) }
fn lv_get_or_create_block_entry(bb: i32) -> i64 {
    let e = lv_block_entry(bb);
    if e >= 0 { return e; }
    let n = lv_blks.len;
    lv_blks.push(LvBlk { head: -1, nover: 0, nn_done: false });
    hm_put(lv_bmap, (bb as i64) as u64, n);
    return n;
}
fn lv_add_value_handle(v: i32) {
    if hm_has(lv_vmap, (v as i64) as u64) { return; }
    hm_put(lv_vmap, (v as i64) as u64, -1);
    vh_lvi_n++;
}
fn lv_add_entry(bb: i32, v: i32, kind: i64, l: VL) {
    let be = lv_get_or_create_block_entry(bb);
    let k = lv_key(bb, v, kind);
    if hm_has(lv_emap, k) { return; }      // DenseMap/DenseSet insert: an existing entry stays
    lv_add_value_handle(v);
    let n = lv_ents.len as i32;
    let vh = hm_get(lv_vmap, (v as i64) as u64, -1) as i32;
    lv_ents.push(LvEnt { bb: bb, v: v, kind: kind as u8, alive: true, vnext: vh, bnext: lv_blks[be].head, l: lv_store(l) });
    lv_blks[be].head = n;
    if kind == LV_K_OVERDEF { lv_blks[be].nover = lv_blks[be].nover + 1; }
    hm_put(lv_vmap, (v as i64) as u64, n as i64);
    hm_put(lv_emap, k, n as i64);
}
fn lv_kill_entry(e: i64) {
    if !lv_ents[e].alive { return; }
    lv_ents[e].alive = false;
    let bb = lv_ents[e].bb;
    hm_del(lv_emap, lv_key(bb, lv_ents[e].v, lv_ents[e].kind as i64));
    if lv_ents[e].kind as i64 == LV_K_OVERDEF {
        let be = lv_block_entry(bb);
        if be >= 0 { lv_blks[be].nover = lv_blks[be].nover - 1; }
    }
}

// insertResult
fn lv_insert_result(v: i32, bb: i32, r: VL) {
    if vl_is_overdefined(r) { lv_add_entry(bb, v, LV_K_OVERDEF, r); }
    else { lv_add_entry(bb, v, LV_K_LATTICE, r); }
}

// getCachedValueInfo: (found, value)
fn lv_cached(v: i32, bb: i32) -> bool, VL {
    if lv_block_entry(bb) < 0 { return false, vl_unknown(); }
    if hm_has(lv_emap, lv_key(bb, v, LV_K_OVERDEF)) { return true, vl_overdefined(); }
    let e = hm_get(lv_emap, lv_key(bb, v, LV_K_LATTICE), -1);
    if e < 0 { return false, vl_unknown(); }
    return true, lv_load(lv_ents[e].l);
}

// eraseValue
fn lv_erase_value(v: i32) {
    let k = (v as i64) as u64;
    if !hm_has(lv_vmap, k) { return; }
    var e = hm_get(lv_vmap, k, -1);
    while e >= 0 {
        // only entries of live block entries are reachable through the block cache
        if lv_ents[e].alive { lv_kill_entry(e); }
        e = lv_ents[e].vnext as i64;
    }
    hm_del(lv_vmap, k);
    vh_lvi_n--;
}

// LVIValueHandle::deleted / allUsesReplacedWith: ir.goose's rauw and val_set_dead queue the value while handles
// exist (vh_lvi_events); every entry point drains the queue first, before it reads the cache.
fn lvi_drain() {
    if vh_lvi_events.len == 0 { return; }
    var i: i64 = 0;
    while i < vh_lvi_events.len {
        let v = vh_lvi_events[i];
        if lv_fn >= 0 { lv_erase_value(v); }
        i++;
    }
    vh_lvi_events.clear();
}

// eraseBlock
fn lvi_erase_block(bb: i32) {
    if lv_fn < 0 || !lv_impl { return; }
    lvi_drain();
    let be = lv_block_entry(bb);
    if be < 0 { return; }
    var e = lv_blks[be].head as i64;
    while e >= 0 {
        if lv_ents[e].alive { lv_kill_entry(e); }
        e = lv_ents[e].bnext as i64;
    }
    hm_del(lv_bmap, (bb as i64) as u64);
}

// threadEdgeImpl (LazyValueInfo::threadEdge)
fn lvi_thread_edge(pred: i32, old_succ: i32, new_succ: i32) {
    if lv_fn < 0 || !lv_impl { return; }
    lvi_drain();
    let be = lv_block_entry(old_succ);
    if be < 0 || lv_blks[be].nover == 0 { return; }
    var vals_to_clear: i32[>..<] = [];
    var e = lv_blks[be].head as i64;
    while e >= 0 {
        if lv_ents[e].alive && lv_ents[e].kind as i64 == LV_K_OVERDEF { vals_to_clear.push(lv_ents[e].v); }
        e = lv_ents[e].bnext as i64;
    }
    var wl: i32[>..<] = [];
    wl.push(old_succ);
    while wl.len > 0 {
        let to_update = wl.pop();
        if to_update == new_succ { continue; }
        let we = lv_block_entry(to_update);
        if we < 0 || lv_blks[we].nover == 0 { continue; }
        var changed = false;
        for v in vals_to_clear {
            let x = hm_get(lv_emap, lv_key(to_update, v, LV_K_OVERDEF), -1);
            if x < 0 { continue; }
            lv_kill_entry(x);
            changed = true;
        }
        if !changed { continue; }
        let t = block_terminator(to_update);
        if t >= 0 { for k in term_nsucc(t) { wl.push(term_succ(t, k)); } }
    }
}

// forgetValue
fn lvi_forget_value(v: i32) {
    if lv_fn < 0 || !lv_impl { return; }
    lvi_drain();
    lv_erase_value(v);
}

// ---------------------------------------------------------------------------------------------
// Small IR helpers

fn lv_cint(ty: i32, a: AP) -> i32 { ap_to_cint(ty, a) }
fn lv_null(ty: i32) -> i32 { c_null(ty) }
fn lv_is_undef_value(v: i32) -> bool { vals[v].kind == VK_UNDEF || vals[v].kind == VK_POISON }
fn lv_scalar_bits(ty: i32) -> i64 { ty_bits(ty_scalar(ty)) }
fn lv_is_ptr(ty: i32) -> bool { ty_kind(ty) == TK_PTR }

// isKnownNonZero(V, SimplifyQuery(DL)): no context, DT or AC
fn lv_known_non_zero_noctx(v: i32) -> bool {
    let sc = kb_cxt;
    let s1 = sq_no_dt; let s2 = sq_no_ac; let s3 = sq_no_tli;
    kb_cxt = -1; sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    let r = is_known_non_zero(v, 0);
    kb_cxt = sc; sq_no_dt = s1; sq_no_ac = s2; sq_no_tli = s3;
    return r;
}
// isGuaranteedNotToBeUndef(V, AC): no context instruction
fn lv_not_undef(v: i32) -> bool {
    let sc = kb_cxt;
    kb_cxt = -1;
    let r = is_guaranteed_not_to_be_undef(v, -1, 0);
    kb_cxt = sc;
    return r;
}

// GEPOperator::hasAllZeroIndices
fn lv_gep_all_zero(v: i32) -> bool {
    for j in 1..nops(v) { let x = op(v, j); if !(vals[x].kind == VK_CINT && cint_is_zero(x)) { return false; } }
    return true;
}
// Value::stripInBoundsOffsets
fn lv_strip_in_bounds_offsets(v: i32) -> i32 { lv_strip_ptr_casts_kind(v, 2) }
// Value::stripPointerCasts (same_rep = false) / stripPointerCastsSameRepresentation (same_rep = true)
fn lv_strip_ptr_casts(v0: i32, same_rep: bool) -> i32 { lv_strip_ptr_casts_kind(v0, if same_rep { 1 } else { 0 }) }
// stripPointerCastsAndOffsets: kind 0 = PSK_ZeroIndices, 1 = PSK_ZeroIndicesSameRepresentation, 2 = PSK_InBounds
fn lv_strip_ptr_casts_kind(v0: i32, kind: i64) -> i32 {
    let same_rep = kind == 1;
    var v = v0;
    if !lv_is_ptr(vals[v].ty) { return v; }
    var visited: i32[>..<] = [];
    visited.push(v);
    loop {
        let o = opcode_of(v);
        if o == OP_GEP {
            if kind == 2 { if (op_flags(v) & GEP_INBOUNDS) == 0 { return v; } }
            else if !lv_gep_all_zero(v) { return v; }
            v = op(v, 0);
        } else if o == OP_BITCAST {
            let nv = op(v, 0);
            if !lv_is_ptr(vals[nv].ty) { return v; }
            v = nv;
        } else if !same_rep && o == OP_ADDRSPACECAST {
            v = op(v, 0);
        } else if is_inst(v) && is_callbase(v) {
            let rv = returned_arg_operand(v);
            if rv < 0 { return v; }
            v = rv;
        } else {
            return v;
        }
        for x in visited { if x == v { return v; } }
        visited.push(v);
    }
    return v;
}

// BinaryOpIntrinsic (with.overflow and saturating add/sub)
fn lv_is_with_overflow(i: i32) -> bool {
    if !is_inst(i) { return false; }
    let id = inst_iid(i);
    return id == IID_uadd_with_overflow || id == IID_sadd_with_overflow || id == IID_usub_with_overflow ||
        id == IID_ssub_with_overflow || id == IID_umul_with_overflow || id == IID_smul_with_overflow;
}
fn lv_is_saturating(i: i32) -> bool {
    if !is_inst(i) { return false; }
    let id = inst_iid(i);
    return id == IID_uadd_sat || id == IID_sadd_sat || id == IID_usub_sat || id == IID_ssub_sat;
}
fn lv_bo_intr_binop(i: i32) -> i64 {
    let id = inst_iid(i);
    if id == IID_uadd_with_overflow || id == IID_sadd_with_overflow || id == IID_uadd_sat || id == IID_sadd_sat { return OP_ADD; }
    if id == IID_usub_with_overflow || id == IID_ssub_with_overflow || id == IID_usub_sat || id == IID_ssub_sat { return OP_SUB; }
    return OP_MUL;
}
fn lv_bo_intr_signed(i: i32) -> bool {
    let id = inst_iid(i);
    return id == IID_sadd_with_overflow || id == IID_ssub_with_overflow || id == IID_smul_with_overflow ||
        id == IID_sadd_sat || id == IID_ssub_sat;
}
fn lv_bo_intr_nwk(i: i32) -> i64 { if lv_bo_intr_signed(i) { NW_NSW } else { NW_NUW } }

// OverflowingBinaryOperator::getNoWrapKind (add/sub/mul/shl) and TruncInst::getNoWrapKind
fn lv_nowrap_kind(i: i32) -> i64 {
    var k: i64 = 0;
    if has_flag(i, FL_NUW) { k |= NW_NUW; }
    if has_flag(i, FL_NSW) { k |= NW_NSW; }
    return k;
}

fn lv_is_cast_op(o: i64) -> bool { is_cast_op(o) }

// Function::getEntryCount()->getCount() (0 when absent)
fn lv_fn_entry_count(fv: i32) -> u64 {
    let g = glob_of(fv);
    let k = md_kind_id("prof");
    for j in globs[g].nmd {
        if md_att[globs[g].md + 2 * j] != k { continue; }
        let m = md_att[globs[g].md + 2 * j + 1];
        if mds[m].nops < 2 { return 0; }
        let s = md_op(m, 0);
        if s < 0 || mds[s].kind != MK_STRING { return 0; }
        if sbytes(mds[s].extra) != "function_entry_count" { return 0; }
        let o = md_op(m, 1);
        if o < 0 || mds[o].kind != MK_VALUE { return 0; }
        let c = mds[o].extra;
        if vals[c].kind != VK_CINT { return 0; }
        return ap_zext64(ci_ap(c));
    }
    return 0;
}

// ---------------------------------------------------------------------------------------------
// LazyValueInfoImpl: the solver

// pushBlockValue
fn lv_push(bb: i32, v: i32) -> bool {
    let k = lv_pack(bb, v);
    if hm_has(lv_stack_set, k as u64) { return false; }
    hm_put(lv_stack_set, k as u64, 1);
    lv_stack.push(k);
    return true;
}

// solve()
fn lv_solve() {
    var starting: i64[>..<] = [];
    for x in lv_stack { starting.push(x); }
    var processed: i64 = 0;
    while lv_stack.len > 0 {
        processed++;
        if processed > LV_MAX_PROCESSED_PER_VALUE {
            while starting.len > 0 {
                let e = starting.pop();
                lv_insert_result(lv_pv(e), lv_pbb(e), vl_overdefined());
            }
            hm_clear(lv_stack_set);
            lv_stack.clear();
            return;
        }
        let e = lv_stack[lv_stack.len - 1];
        if lv_solve_block_value(lv_pv(e), lv_pbb(e)) {
            lv_stack.pop();
            hm_del(lv_stack_set, e as u64);
        }
    }
}

// getBlockValue: (ok, value); !ok = work was pushed
recursive fn lv_get_block_value(v: i32, bb: i32, cxt: i32) -> bool, VL {
    if is_constant(v) { return true, vl_get(v); }
    let found, c = lv_cached(v, bb);
    if found {
        var x = c;
        lv_intersect_assume_or_guard(v, x, cxt);
        return true, x;
    }
    if !lv_push(bb, v) { return true, vl_overdefined(); }
    return false, vl_unknown();
}

// getFromRangeMetadata
fn lv_from_range_metadata(i: i32) -> VL {
    let o = iop(i);
    if o == OP_CALL || o == OP_INVOKE {
        if call_range(i) { return vl_get_range(vt_cr, false); }
    }
    if o == OP_CALL || o == OP_INVOKE || o == OP_LOAD {
        let md = inst_get_md(i, LV_MDK_RANGE);
        if md >= 0 && ty_is_int(vals[i].ty) { return vl_get_range(rg_from_range_md(md), false); }
    }
    return vl_overdefined();
}

// solveBlockValue
fn lv_solve_block_value(v: i32, bb: i32) -> bool {
    let ok, r = lv_solve_block_value_impl(v, bb);
    if !ok { return false; }
    lv_insert_result(v, bb, r);
    return true;
}

// solveBlockValueImpl
fn lv_solve_block_value_impl(v: i32, bb: i32) -> bool, VL {
    if !is_inst(v) || inst_parent(v) != bb { let a, b = lv_solve_non_local(v, bb); return a, b; }
    let o = iop(v);
    if o == OP_PHI { let a, b = lv_solve_phi(v, bb); return a, b; }
    if o == OP_SELECT { let a, b = lv_solve_select(v, bb); return a, b; }
    let ty = vals[v].ty;
    if lv_is_ptr(ty) && lv_known_non_zero_noctx(v) { return true, vl_get_not(c_null(ty)); }
    if is_int_or_int_vec(ty) {
        if is_cast_op(o) { let a, b = lv_solve_cast(v, bb); return a, b; }
        if is_binary_op(o) { let a, b = lv_solve_binop(v, bb); return a, b; }
        if o == OP_INSERTELEMENT { let a, b = lv_solve_insert_element(v, bb); return a, b; }
        if o == OP_EXTRACTVALUE { let a, b = lv_solve_extract_value(v, bb); return a, b; }
        if is_intrinsic_inst(v) { let a, b = lv_solve_intrinsic(v, bb); return a, b; }
    }
    return true, lv_from_range_metadata(v);
}

// AddNonNullPointer: the set is a list of values (NonNullPointerSet)
fn lv_add_non_null_pointer(p: i32, set: i32[>..<]&, deref: bool) {
    if ptr_as(vals[p].ty) != 0 { return; }
    let x = if deref { get_underlying_object(p, 10) } else { lv_strip_in_bounds_offsets(p) };
    for y in set { if y == x { return; } }
    set.push(x);
}
fn lv_is_mem_intrinsic(i: i32) -> bool {
    let id = inst_iid(i);
    return id == IID_memcpy || id == IID_memmove || id == IID_memset || id == IID_memset_inline || id == IID_memcpy_inline;
}
fn lv_add_non_null_pointers_by_instruction(i: i32, set: i32[>..<]&) {
    let o = iop(i);
    if o == OP_LOAD { lv_add_non_null_pointer(op(i, 0), set, true); return; }
    if o == OP_STORE { lv_add_non_null_pointer(op(i, 1), set, true); return; }
    if is_inst(i) && is_intrinsic_inst(i) && lv_is_mem_intrinsic(i) {
        let vol = cb_arg(i, 3);
        if !(vals[vol].kind == VK_CINT && cint_is_zero(vol)) { return; }
        let len = cb_arg(i, 2);
        if vals[len].kind != VK_CINT || ty_is_vector(vals[len].ty) || cint_is_zero(len) { return; }
        lv_add_non_null_pointer(cb_arg(i, 0), set, true);
        let id = inst_iid(i);
        if id == IID_memcpy || id == IID_memmove || id == IID_memcpy_inline { lv_add_non_null_pointer(cb_arg(i, 1), set, true); }
        return;
    }
    if is_callbase(i) {
        for k in cb_nargs(i) {
            let a = cb_arg(i, k);
            if lv_is_ptr(vals[a].ty) && cb_param_has_nonnull_attr_lv(i, k) { lv_add_non_null_pointer(a, set, false); }
        }
    }
}
// CallBase::paramHasNonNullAttr(ArgNo, AllowUndefOrPoison = false)
fn cb_param_has_nonnull_attr_lv(c: i32, k: i64) -> bool {
    if cb_param_has_attr(c, k, AK_NonNull) && cb_param_has_attr(c, k, AK_NoUndef) { return true; }
    if cb_param_has_attr(c, k, AK_Dereferenceable) && !null_pointer_is_defined(inst_func(c), ptr_as(vals[cb_arg(c, k)].ty)) { return true; }
    return false;
}

// isNonNullAtEndOfBlock
fn lv_is_non_null_at_end_of_block(v0: i32, bb: i32) -> bool {
    if null_pointer_is_defined(block_func(bb), ptr_as(vals[v0].ty)) { return false; }
    let v = lv_strip_in_bounds_offsets(v0);
    let be = lv_get_or_create_block_entry(bb);
    if !lv_blks[be].nn_done {
        lv_blks[be].nn_done = true;
        var set: i32[>..<] = [];
        var i = block_first(bb);
        while i >= 0 { lv_add_non_null_pointers_by_instruction(i, set); i = inst_next(i); }
        for x in set { lv_add_entry(bb, x, LV_K_NONNULL, vl_unknown()); }
    }
    return hm_has(lv_emap, lv_key(bb, v, LV_K_NONNULL));
}

// solveBlockValueNonLocal
fn lv_solve_non_local(v: i32, bb: i32) -> bool, VL {
    var result = vl_unknown();
    if func_entry(block_func(bb)) == bb {
        if !is_arg(v) { fatal("LazyValueInfo: unknown live-in to the entry block"); }
        if arg_range(v) { return true, vl_get_range(vt_cr, false); }
        return true, vl_overdefined();
    }
    var preds: i32[>..<] = [];
    each_pred(bb) { p => preds.push(p); };
    for p in preds {
        if p == bb { continue; }
        let ok, er = lv_get_edge_value(v, p, bb, -1);
        if !ok { return false, vl_unknown(); }
        vl_merge_in(result, er, vl_opts());
        if vl_is_overdefined(result) { return true, result; }
    }
    return true, result;
}

// solveBlockValuePHINode
fn lv_solve_phi(pn: i32, bb: i32) -> bool, VL {
    var result = vl_unknown();
    for i in phi_nincoming(pn) {
        let pb = phi_block(pn, i);
        let pv = phi_value(pn, i);
        let ok, er = lv_get_edge_value(pv, pb, bb, pn);
        if !ok { return false, vl_unknown(); }
        vl_merge_in(result, er, vl_opts());
        if vl_is_overdefined(result) { return true, result; }
    }
    return true, result;
}

// intersectAssumeOrGuardBlockValueConstantRange
recursive fn lv_intersect_assume_or_guard(v: i32, bblv: VL&, bbi0: i32) {
    var bbi = bbi0;
    if bbi < 0 { if is_inst(v) { bbi = v; } else { return; } }
    let bb = inst_parent(bbi);
    ac_build(lv_fn);
    // AC->assumptionsFor(Val), in the cache's order (copied first: lv_tmp is a stack with a mark, as this is
    // part of the recursive solver)
    let mark = lv_tmp.len;
    for k in ac_val.len { if ac_val[k] == v { lv_tmp.push(ac_asm[k]); lv_tmp.push(ac_idx[k]); } }
    let end = lv_tmp.len;
    var j = mark;
    while j < end {
        let a = lv_tmp[j];
        let ixj = lv_tmp[j + 1];
        j += 2;
        if a < 0 || is_dead(a) { continue; }
        if inst_parent(a) != bb || !valid_assume_for_context(a, bbi) { continue; }
        if ixj >= 0 {
            if bundle_implies_nonnull(v, inst_func(bbi), a, ixj as i64) {
                bblv = vl_intersect(bblv, vl_get_not(c_null(vals[v].ty)));
            }
        } else {
            let ok, c = lv_get_value_from_condition(v, cb_arg(a, 0), true, false, 0);
            bblv = vl_intersect(bblv, c);
        }
    }
    lv_tmp.resize(mark);
    if lv_guard >= 0 && is_func(lv_guard) && vals[lv_guard].first_use >= 0 && block_first(bb) != bbi {
        var i = inst_prev(bbi);
        while i >= 0 {
            if inst_iid(i) == IID_experimental_guard {
                let ok, c = lv_get_value_from_condition(v, cb_arg(i, 0), true, false, 0);
                bblv = vl_intersect(bblv, c);
            }
            i = inst_prev(i);
        }
    }
    if vl_is_overdefined(bblv) {
        let ty = vals[v].ty;
        if lv_is_ptr(ty) && block_terminator(bb) == bbi && lv_is_non_null_at_end_of_block(v, bb) {
            bblv = vl_get_not(c_null(ty));
        }
    }
}

// solveBlockValueSelect
fn lv_solve_select(si: i32, bb: i32) -> bool, VL {
    let tv = op(si, 1);
    let fv = op(si, 2);
    let ok1, t0 = lv_get_block_value(tv, bb, si);
    if !ok1 { return false, vl_unknown(); }
    let ok2, f0 = lv_get_block_value(fv, bb, si);
    if !ok2 { return false, vl_unknown(); }
    var t = t0;
    var f = f0;
    let ty = vals[si].ty;
    if vl_is_range(t, true) || vl_is_range(f, true) {
        let tcr = vl_as_range_ty(t, ty, false);
        let fcr = vl_as_range_ty(f, ty, false);
        let spf = match_select_pattern_v(si, 0);
        let l = sp_lhs;
        let r = sp_rhs;
        if spf_is_minmax(spf) && ((l == tv && r == fv) || (r == tv && l == fv)) {
            var res = tcr;
            if spf == SPF_SMIN { res = rg_smin_op(tcr, fcr); }
            else if spf == SPF_UMIN { res = rg_umin_op(tcr, fcr); }
            else if spf == SPF_SMAX { res = rg_smax_op(tcr, fcr); }
            else if spf == SPF_UMAX { res = rg_umax_op(tcr, fcr); }
            else { fatal("LazyValueInfo: unexpected minmax type"); }
            return true, vl_get_range(res, vl_is_range_including_undef(t) || vl_is_range_including_undef(f));
        }
        if spf == SPF_ABS {
            if l == tv { return true, vl_get_range(rg_abs(tcr, false), vl_is_range_including_undef(t)); }
            if l == fv { return true, vl_get_range(rg_abs(fcr, false), vl_is_range_including_undef(f)); }
        }
        if spf == SPF_NABS {
            let zero = rg_single(ap_zero(rg_w(tcr)));
            if l == tv { return true, vl_get_range(rg_sub(zero, rg_abs(tcr, false)), vl_is_range_including_undef(f)); }
            if l == fv { return true, vl_get_range(rg_sub(zero, rg_abs(fcr, false)), vl_is_range_including_undef(f)); }
        }
    }
    let cond = op(si, 0);
    if lv_not_undef(cond) {
        let o1, c1 = lv_get_value_from_condition(tv, cond, true, false, 0);
        t = vl_intersect(t, c1);
        let o2, c2 = lv_get_value_from_condition(fv, cond, false, false, 0);
        f = vl_intersect(f, c2);
    }
    vl_merge_in(t, f, vl_opts());
    return true, t;
}

// getRangeFor
fn lv_get_range_for(v: i32, cxt: i32, bb: i32) -> bool, CRange {
    let ok, l = lv_get_block_value(v, bb, cxt);
    if !ok { return false, rg_empty(1); }
    return true, vl_as_range_ty(l, vals[v].ty, false);
}

// solveBlockValueCast
fn lv_solve_cast(ci: i32, bb: i32) -> bool, VL {
    let o = iop(ci);
    if o != OP_TRUNC && o != OP_SEXT && o != OP_ZEXT { return true, vl_overdefined(); }
    let ok, lr = lv_get_range_for(op(ci, 0), ci, bb);
    if !ok { return false, vl_unknown(); }
    let rw = lv_scalar_bits(vals[ci].ty);
    var res = rg_empty(rw);
    if o == OP_TRUNC { res = rg_truncate_nw(lr, rw, lv_nowrap_kind(ci)); }
    else { res = rg_cast(o, lr, rw); }
    return true, vl_get_range(res, false);
}

// The OpFn of solveBlockValueBinaryOpImpl: kind 0 = binaryOp(opc), 1 = overflowingBinaryOp(opc, nwk)
fn lv_opfn(kind: i64, o: i64, nwk: i64, a: CRange, b: CRange) -> CRange {
    if kind == 1 { return rg_overflowing_binop(o, a, b, nwk); }
    return rg_binop(o, a, b);
}

// ThreadBinOpOverSelect: (handled, value)
fn lv_thread_binop_over_select(kind: i64, o: i64, nwk: i64, x: i32, crx: CRange, y: i32, x_is_lhs: bool) -> bool, VL {
    let cond = op(y, 0);
    let tc = op(y, 1);
    let fc = op(y, 2);
    if !is_constant(tc) { return false, vl_unknown(); }
    if !is_constant(fc) { return false, vl_unknown(); }
    if !lv_not_undef(cond) { return false, vl_unknown(); }
    let xt = vals[x].ty;
    let o1, c1 = lv_get_value_from_condition(x, cond, true, false, 0);
    let truex = rg_intersect(crx, vl_as_range_ty(c1, xt, false));
    let o2, c2 = lv_get_value_from_condition(x, cond, false, false, 0);
    let falsex = rg_intersect(crx, vl_as_range_ty(c2, xt, false));
    let truey = rg_of_const(tc);
    let falsey = rg_of_const(fc);
    if x_is_lhs {
        return true, vl_get_range(rg_union(lv_opfn(kind, o, nwk, truex, truey), lv_opfn(kind, o, nwk, falsex, falsey)), false);
    }
    return true, vl_get_range(rg_union(lv_opfn(kind, o, nwk, truey, truex), lv_opfn(kind, o, nwk, falsey, falsex)), false);
}

// solveBlockValueBinaryOpImpl
fn lv_solve_binop_impl(i: i32, bb: i32, kind: i64, o: i64, nwk: i64) -> bool, VL {
    let l = op(i, 0);
    let r = op(i, 1);
    let ok1, lres = lv_get_range_for(l, i, bb);
    if !ok1 { return false, vl_unknown(); }
    if is_inst_op(r, OP_SELECT) {
        let h, res = lv_thread_binop_over_select(kind, o, nwk, l, lres, r, true);
        if h { return true, res; }
    }
    let ok2, rres = lv_get_range_for(r, i, bb);
    if !ok2 { return false, vl_unknown(); }
    if is_inst_op(l, OP_SELECT) {
        let h, res = lv_thread_binop_over_select(kind, o, nwk, r, rres, l, false);
        if h { return true, res; }
    }
    return true, vl_get_range(lv_opfn(kind, o, nwk, lres, rres), false);
}

// solveBlockValueBinaryOp
fn lv_solve_binop(bo: i32, bb: i32) -> bool, VL {
    let o = iop(bo);
    if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL {
        let a, b = lv_solve_binop_impl(bo, bb, 1, o, lv_nowrap_kind(bo));
        return a, b;
    }
    let a, b = lv_solve_binop_impl(bo, bb, 0, o, 0);
    return a, b;
}

// solveBlockValueOverflowIntrinsic
fn lv_solve_overflow_intrinsic(wo: i32, bb: i32) -> bool, VL {
    let a, b = lv_solve_binop_impl(wo, bb, 0, lv_bo_intr_binop(wo), 0);
    return a, b;
}

// solveBlockValueIntrinsic
fn lv_solve_intrinsic(ii: i32, bb: i32) -> bool, VL {
    let mdv = lv_from_range_metadata(ii);
    let id = inst_iid(ii);
    if !rg_is_intrinsic_supported(id) { return true, mdv; }
    var ranges: CRange[>..<] = [];
    for k in cb_nargs(ii) {
        let ok, r = lv_get_range_for(cb_arg(ii, k), ii, bb);
        if !ok { return false, vl_unknown(); }
        ranges.push(r);
    }
    return true, vl_intersect(vl_get_range(rg_intrinsic(id, ranges), false), mdv);
}

// solveBlockValueInsertElement
fn lv_solve_insert_element(iei: i32, bb: i32) -> bool, VL {
    let ok1, e = lv_get_block_value(op(iei, 1), bb, iei);
    if !ok1 { return false, vl_unknown(); }
    var res = e;
    let ok2, vv = lv_get_block_value(op(iei, 0), bb, iei);
    if !ok2 { return false, vl_unknown(); }
    if vl_is_constant(e) { return true, vl_overdefined(); }
    vl_merge_in(res, vv, vl_opts());
    return true, res;
}

// solveBlockValueExtractValue
fn lv_solve_extract_value(evi: i32, bb: i32) -> bool, VL {
    let agg = op(evi, 0);
    if lv_is_with_overflow(agg) && lv_ev_nidx(evi) == 1 && lv_ev_idx(evi, 0) == 0 {
        let a, b = lv_solve_overflow_intrinsic(agg, bb);
        return a, b;
    }
    let s1 = sq_no_dt; let s2 = sq_no_ac; let s3 = sq_no_tli;
    let sc = kb_cxt;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true; kb_cxt = -1;
    let v = simplify_extractvalue(evi, agg, sq_new(-1));
    sq_no_dt = s1; sq_no_ac = s2; sq_no_tli = s3; kb_cxt = sc;
    if v >= 0 { let a, b = lv_get_block_value(v, bb, evi); return a, b; }
    return true, vl_overdefined();
}
fn lv_ev_nidx(evi: i32) -> i64 { insts[inst_of(evi)].naux as i64 }
fn lv_ev_idx(evi: i32, k: i64) -> i64 { ints[insts[inst_of(evi)].aux + k] as i64 }

// ---------------------------------------------------------------------------------------------
// Conditions

// matchICmpOperand: (matched, Offset)
fn lv_match_icmp_operand(off0: AP, lhs: i32, val: i32, p: i64) -> bool, AP {
    if lhs == val { return true, off0; }
    if (is_inst_op(lhs, OP_ADD) || (is_inst_op(lhs, OP_OR) && op_disjoint(lhs))) && op(lhs, 0) == val {
        let c = m_apint(op(lhs, 1));
        if c >= 0 { return true, ci_ap(c); }
    }
    if (is_inst_op(val, OP_ADD) || (is_inst_op(val, OP_OR) && op_disjoint(val))) && op(val, 0) == lhs {
        let c = m_apint(op(val, 1));
        if c >= 0 { return true, ap_neg(ci_ap(c)); }
    }
    if is_inst_op(lhs, OP_OR) && (op(lhs, 0) == val || op(lhs, 1) == val) && (p == P_ULT || p == P_ULE) { return true, off0; }
    if is_inst_op(lhs, OP_AND) && (op(lhs, 0) == val || op(lhs, 1) == val) && (p == P_UGT || p == P_UGE) { return true, off0; }
    return false, off0;
}

// getValueFromSimpleICmpCondition
recursive fn lv_value_from_simple_icmp(p: i64, rhs: i32, off: AP, cxt: i32, use_block_value: bool) -> bool, VL {
    var rr = rg_full(lv_scalar_bits(vals[rhs].ty));
    if is_constant(rhs) {
        rr = rg_of_const(rhs);
    } else if use_block_value {
        let ok, r = lv_get_block_value(rhs, inst_parent(cxt), cxt);
        if !ok { return false, vl_unknown(); }
        rr = vl_as_range_ty(r, vals[rhs].ty, false);
    }
    let tv = rg_allowed_icmp(p, rr);
    return true, vl_get_range(rg_subtract(tv, off), false);
}

// getRangeViaSLT for the ashr case: (ok, range)
fn lv_ashr_slt_fn(rhs: AP, sh: AP) -> bool, CRange {
    let nw = ap_shl_ap(rhs, sh);
    if !ap_eq(ap_ashr_ap(nw, sh), rhs) { return false, rg_empty(1); }
    return true, rg_nonempty(ap_smin_val(nw.w as i64), nw);
}
fn lv_range_via_slt(p0: i64, rhs0: AP, sh: AP) -> bool, CRange {
    var p = p0;
    var rhs = rhs0;
    var invert = false;
    if p == P_SGT || p == P_SGE { p = rg_icmp_inverse(p); invert = true; }
    if p == P_SLE {
        p = P_SLT;
        if ap_is_max_signed(rhs) { return false, rg_empty(1); }
        rhs = ap_inc(rhs);
    }
    let ok, cr = lv_ashr_slt_fn(rhs, sh);
    if !ok { return false, cr; }
    if invert { return true, rg_inverse(cr); }
    return true, cr;
}

// getValueFromICmpCtpop
fn lv_value_from_icmp_ctpop(p: i64, rhs: i32) -> VL {
    let bw = lv_scalar_bits(vals[rhs].ty);
    if vals[rhs].kind != VK_CINT || ty_is_vector(vals[rhs].ty) { return vl_overdefined(); }
    let rv = rg_exact_icmp(p, ci_ap(rhs));
    let rmin = ap_limited(rg_umin(rv), bw as u64) as i64;
    let rmax = ap_limited(rg_umax(rv), bw as u64) as i64;
    let vmin = ap_low_bits(bw, rmin);
    let vmax = ap_high_bits(bw, rmax);
    return vl_get_range(rg_nonempty(vmin, ap_inc(vmax)), false);
}

fn lv_is_signed_pred(p: i64) -> bool { p == P_SGT || p == P_SGE || p == P_SLT || p == P_SLE }
fn lv_swap_pred(p: i64) -> i64 { pred_swap_i(p) }

// m_PtrToIntSameSize(DL, m_Value(X)): the operand or the value itself
fn lv_peek_ptrtoint_same_size(x: i32) -> i32 {
    if opcode_of(x) != OP_PTRTOINT { return x; }
    let src = op(x, 0);
    if lv_size_bits(vals[x].ty) == lv_size_bits(vals[src].ty) { return src; }
    return x;
}
fn lv_size_bits(t: i32) -> i64 {
    let s = ty_scalar(t);
    var b: i64 = 0;
    if ty_is_int(s) { b = ty_bits(s); }
    else if ty_kind(s) == TK_PTR { b = dl_ptr(types[s].n as i64).bits; }
    else { lv_not_ported("DataLayout::getTypeSizeInBits of this type"); }
    if ty_is_vector(t) { return b * ty_count(t); }
    return b;
}

// getValueFromICmpCondition
recursive fn lv_value_from_icmp_condition(val: i32, ici: i32, is_true_dest: bool, use_block_value: bool) -> bool, VL {
    let lhs = op(ici, 0);
    let rhs = op(ici, 1);
    let ip = inst_pred(ici);
    let edge = if is_true_dest { ip } else { rg_icmp_inverse(ip) };
    if is_constant(rhs) {
        if (ip == P_EQ || ip == P_NE) && lhs == val {
            if edge == P_EQ { return true, vl_get(rhs); }
            if !lv_is_undef_value(rhs) { return true, vl_get_not(rhs); }
        }
    }
    let ty = vals[val].ty;
    if !is_int_or_int_vec(ty) { return true, vl_overdefined(); }
    let bw = lv_scalar_bits(ty);
    let off0 = ap_zero(bw);
    let m1, off1 = lv_match_icmp_operand(off0, lhs, val, edge);
    if m1 { let a, b = lv_value_from_simple_icmp(edge, rhs, off1, ici, use_block_value); return a, b; }
    let sw = lv_swap_pred(edge);
    let m2, off2 = lv_match_icmp_operand(off0, rhs, val, sw);
    if m2 { let a, b = lv_value_from_simple_icmp(sw, lhs, off2, ici, use_block_value); return a, b; }
    if is_inst(lhs) && inst_iid(lhs) == IID_ctpop && op(lhs, 0) == val { return true, lv_value_from_icmp_ctpop(edge, rhs); }
    if is_inst_op(lhs, OP_AND) && op(lhs, 0) == val {
        let mk = m_apint(op(lhs, 1));
        let c = m_apint(rhs);
        if mk >= 0 && c >= 0 {
            let mask = ci_ap(mk);
            let cv = ci_ap(c);
            if edge == P_EQ {
                let known = KB { z: ap_and(ap_not(cv), mask), o: ap_and(cv, mask) };
                return true, vl_get_range(rg_from_kb(known, false), false);
            }
            if edge == P_NE { return true, vl_get_range(rg_mask_not_equal(mask, cv), false); }
        }
    }
    if (is_inst_op(lhs, OP_UREM) || is_inst_op(lhs, OP_TRUNC)) && op(lhs, 0) == val {
        let c = m_apint(rhs);
        if c >= 0 {
            let cr = rg_exact_icmp(edge, ci_ap(c));
            if !rg_is_empty(cr) {
                return true, vl_get_range(rg_nonempty(ap_zext(rg_umin(cr), bw), ap_zero(bw)), false);
            }
        }
    }
    if lv_is_signed_pred(edge) && is_inst_op(lhs, OP_ASHR) && op(lhs, 0) == val {
        let sh = m_apint(op(lhs, 1));
        let c = m_apint(rhs);
        if sh >= 0 && c >= 0 {
            let ok, cr = lv_range_via_slt(edge, ci_ap(c), ci_ap(sh));
            if ok { return true, vl_get_range(cr, false); }
        }
    }
    if (ip == P_EQ || ip == P_NE) && is_inst_op(val, OP_SUB) {
        let x = lv_peek_ptrtoint_same_size(op(val, 0));
        let y = lv_peek_ptrtoint_same_size(op(val, 1));
        if (x == lhs && y == rhs) || (x == rhs && y == lhs) {
            let nv = c_null(ty);
            if edge == P_EQ { return true, vl_get(nv); }
            return true, vl_get_not(nv);
        }
    }
    return true, vl_overdefined();
}

// getValueFromTrunc
fn lv_value_from_trunc(val: i32, tr: i32, is_true_dest: bool) -> VL {
    if op(tr, 0) != val { return vl_overdefined(); }
    let ty = vals[val].ty;
    if has_flag(tr, FL_NUW) {
        if is_true_dest { return vl_get(lv_cint(ty, ap_u64(1, lv_scalar_bits(ty)))); }
        return vl_get(c_null(ty));
    }
    if is_true_dest { return vl_get_not(c_null(ty)); }
    return vl_get_not(lv_cint(ty, ap_ones(lv_scalar_bits(ty))));
}

// getValueFromOverflowCondition
fn lv_value_from_overflow_condition(val: i32, wo: i32, is_true_dest: bool) -> VL {
    let c = m_apint(cb_arg(wo, 1));
    if cb_arg(wo, 0) != val || c < 0 { return vl_overdefined(); }
    var nwr = rg_exact_no_wrap(lv_bo_intr_binop(wo), ci_ap(c), lv_bo_intr_nwk(wo));
    if is_true_dest { nwr = rg_inverse(nwr); }
    return vl_get_range(nwr, false);
}

// getValueFromCondition
recursive fn lv_get_value_from_condition(val: i32, cond: i32, is_true_dest: bool, use_block_value: bool, depth0: i64) -> bool, VL {
    if is_inst_op(cond, OP_ICMP) { let a, b = lv_value_from_icmp_condition(val, cond, is_true_dest, use_block_value); return a, b; }
    if is_inst_op(cond, OP_TRUNC) { return true, lv_value_from_trunc(val, cond, is_true_dest); }
    if is_inst_op(cond, OP_EXTRACTVALUE) {
        let agg = op(cond, 0);
        if lv_is_with_overflow(agg) && lv_ev_nidx(cond) == 1 && lv_ev_idx(cond, 0) == 1 {
            return true, lv_value_from_overflow_condition(val, agg, is_true_dest);
        }
    }
    let depth = depth0 + 1;
    if depth == 6 { return true, vl_overdefined(); }
    let n = m_not(cond);
    if n >= 0 { let a, b = lv_get_value_from_condition(val, n, !is_true_dest, use_block_value, depth); return a, b; }
    var is_and = false;
    var l: i32 = -1;
    var r: i32 = -1;
    if m_logical(cond, true) { is_and = true; l = lg_a; r = lg_b; }
    else if m_logical(cond, false) { is_and = false; l = lg_a; r = lg_b; }
    else { return true, vl_overdefined(); }
    let okl, lv0 = lv_get_value_from_condition(val, l, is_true_dest, use_block_value, depth);
    if !okl { return false, vl_unknown(); }
    let okr, rv = lv_get_value_from_condition(val, r, is_true_dest, use_block_value, depth);
    if !okr { return false, vl_unknown(); }
    var lv = lv0;
    if is_true_dest != is_and {
        vl_merge_in(lv, rv, vl_opts());
        return true, lv;
    }
    return true, vl_intersect(lv, rv);
}

// isOperationFoldable
fn lv_is_operation_foldable(u: i32) -> bool {
    if !is_inst(u) { return false; }
    let o = iop(u);
    return is_cast_op(o) || is_binary_op(o) || o == OP_FREEZE;
}
fn lv_uses_operand(u: i32, x: i32) -> bool {
    for k in nops(u) { if op(u, k) == x { return true; } }
    return false;
}

// constantFoldUser
fn lv_constant_fold_user(u: i32, opv: i32, cval: AP) -> VL {
    let oc = lv_cint(vals[opv].ty, cval);
    let o = iop(u);
    let s1 = sq_no_dt; let s2 = sq_no_ac; let s3 = sq_no_tli;
    let sc = kb_cxt;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true; kb_cxt = -1;
    var res = vl_overdefined();
    if is_cast_op(o) {
        let c = simplify_cast(o, oc, vals[u].ty, sq_new(-1), RECURSION_LIMIT);
        if c >= 0 && vals[c].kind == VK_CINT && !ty_is_vector(vals[c].ty) { res = vl_get_range(rg_single(ci_ap(c)), false); }
    } else if is_binary_op(o) {
        let l = if op(u, 0) == opv { oc } else { op(u, 0) };
        let r = if op(u, 1) == opv { oc } else { op(u, 1) };
        let c = simplify_binop(o, l, r, sq_new(-1), RECURSION_LIMIT);
        if c >= 0 && vals[c].kind == VK_CINT && !ty_is_vector(vals[c].ty) { res = vl_get_range(rg_single(ci_ap(c)), false); }
    } else if o == OP_FREEZE {
        res = vl_get_range(rg_single(cval), false);
    }
    sq_no_dt = s1; sq_no_ac = s2; sq_no_tli = s3; kb_cxt = sc;
    return res;
}

// getEdgeValueLocal
fn lv_get_edge_value_local(val: i32, from: i32, to: i32, use_block_value: bool) -> bool, VL {
    let t = block_terminator(from);
    if t >= 0 && iop(t) == OP_CONDBR {
        if term_succ(t, 0) != term_succ(t, 1) {
            let is_true_dest = term_succ(t, 0) == to;
            let cond = op(t, 0);
            if cond == val { return true, vl_get(if is_true_dest { c_true() } else { c_false() }); }
            let ok, r0 = lv_get_value_from_condition(val, cond, is_true_dest, use_block_value, 0);
            if !ok { return false, vl_unknown(); }
            if !vl_is_overdefined(r0) { return true, r0; }
            var result = r0;
            if is_inst(val) && ty_kind(vals[val].ty) == TK_INT && lv_is_operation_foldable(val) {
                let o = iop(val);
                if lv_uses_operand(val, cond) {
                    result = lv_constant_fold_user(val, cond, ap_u64(if is_true_dest { 1 } else { 0 }, 1));
                } else if o == OP_TRUNC || o == OP_ZEXT || o == OP_SEXT {
                    let o1, opl = lv_get_value_from_condition(op(val, 0), cond, is_true_dest, false, 0);
                    if vl_is_range(opl, true) {
                        let rw = lv_scalar_bits(vals[val].ty);
                        if o == OP_TRUNC { return true, vl_get_range(rg_truncate_nw(opl.r, rw, lv_nowrap_kind(val)), false); }
                        return true, vl_get_range(rg_cast(o, opl.r, rw), false);
                    }
                    if vl_is_constant(opl) {
                        let cc = cf_fold_cast_operand(o, opl.c, vals[val].ty);
                        if cc >= 0 { return true, vl_get(cc); }
                    }
                    return true, vl_overdefined();
                } else {
                    for k in nops(val) {
                        let x = op(val, k);
                        let o2, opl = lv_get_value_from_condition(x, cond, is_true_dest, false, 0);
                        let has, cv = vl_as_constant_integer(opl);
                        if has {
                            result = lv_constant_fold_user(val, x, cv);
                            break;
                        }
                    }
                }
            }
            if !vl_is_overdefined(result) { return true, result; }
        }
    }
    if t >= 0 && iop(t) == OP_SWITCH {
        let cond = op(t, 0);
        if ty_kind(vals[val].ty) != TK_INT { return true, vl_overdefined(); }
        var foldable = false;
        if cond != val {
            foldable = lv_is_operation_foldable(val) && lv_uses_operand(val, cond);
            if !foldable { return true, vl_overdefined(); }
        }
        let default_case = op(t, 1) == to;
        let bw = ty_bits(vals[val].ty);
        var edges = if default_case { rg_full(bw) } else { rg_empty(bw) };
        let n = (nops(t) - 2) / 2;
        for k in n {
            let cv = op(t, 2 + 2 * k);
            let cdest = op(t, 3 + 2 * k);
            let caseval = ci_ap(cv);
            var ev = rg_single(caseval);
            if foldable {
                let el = lv_constant_fold_user(val, cond, caseval);
                if vl_is_overdefined(el) { return true, vl_overdefined(); }
                ev = el.r;
            }
            if default_case {
                if cdest != to && cond == val { edges = rg_difference(edges, ev); }
            } else if cdest == to {
                edges = rg_union(edges, ev);
            }
        }
        return true, vl_get_range(edges, false);
    }
    return true, vl_overdefined();
}

// getEdgeValue
fn lv_get_edge_value(val: i32, from: i32, to: i32, cxt: i32) -> bool, VL {
    if is_constant(val) { return true, vl_get(val); }
    let ok1, local = lv_get_edge_value_local(val, from, to, true);
    if !ok1 { return false, vl_unknown(); }
    if vl_has_single_value(local) { return true, local; }
    let ok2, inb0 = lv_get_block_value(val, from, block_terminator(from));
    if !ok2 { return false, vl_unknown(); }
    var inb = inb0;
    lv_intersect_assume_or_guard(val, inb, cxt);
    return true, vl_intersect(local, inb);
}

// getValueInBlock
fn lv_get_value_in_block(v: i32, bb: i32, cxt: i32) -> VL {
    let ok, r = lv_get_block_value(v, bb, cxt);
    if ok { return r; }
    lv_solve();
    let ok2, r2 = lv_get_block_value(v, bb, cxt);
    if !ok2 { fatal("LazyValueInfo: value not available after solving"); }
    return r2;
}

// getValueAt
fn lv_get_value_at(v: i32, cxt: i32) -> VL {
    if is_constant(v) { return vl_get(v); }
    var r = vl_overdefined();
    if is_inst(v) { r = lv_from_range_metadata(v); }
    lv_intersect_assume_or_guard(v, r, cxt);
    return r;
}

// getValueOnEdge
fn lv_get_value_on_edge(v: i32, from: i32, to: i32, cxt: i32) -> VL {
    let ok0, r0 = lv_get_edge_value(v, from, to, cxt);
    var ok = ok0;
    var r = r0;
    while !ok {
        lv_solve();
        let ok2, r2 = lv_get_edge_value(v, from, to, cxt);
        ok = ok2;
        r = r2;
    }
    return r;
}

// isSafeToSpeculativelyExecuteWithVariableReplaced(I, IgnoreUBImplyingAttrs = false)
fn lv_safe_with_variable_replaced(i: i32) -> bool {
    if iop(i) == OP_LOAD { return false; }
    return spec_safe_opc(iop(i), i, -1, false, false);
}

// getValueAtUse (u is a use id)
fn lv_get_value_at_use(u: i32) -> VL {
    let v = uses[u].val;
    let cxt = uses[u].user;
    var vl = lv_get_value_in_block(v, inst_parent(cxt), cxt);
    var cu = u;
    for it in 3 {
        var has = false;
        var cv = vl_unknown();
        let ci = uses[cu].user;
        let opno = (cu - vals[ci].ops) as i64;
        if iop(ci) == OP_SELECT {
            if !lv_not_undef(op(ci, 0)) { break; }
            if opno == 1 { let o, x = lv_get_value_from_condition(v, op(ci, 0), true, false, 0); cv = x; has = true; }
            else if opno == 2 { let o, x = lv_get_value_from_condition(v, op(ci, 0), false, false, 0); cv = x; has = true; }
        } else if iop(ci) == OP_PHI {
            let o, x = lv_get_edge_value_local(v, phi_block(ci, opno), inst_parent(ci), false);
            cv = x;
            has = true;
        }
        if has { vl = vl_intersect(vl, cv); }
        let fu = vals[ci].first_use;
        if fu < 0 || uses[fu].next >= 0 || !lv_safe_with_variable_replaced(ci) { break; }
        if ty_is_vector(vals[v].ty) && !is_not_cross_lane(ci) { break; }
        cu = fu;
    }
    return vl;
}

// ---------------------------------------------------------------------------------------------
// LazyValueInfo: the query interface (each creates the Impl first)

// isKnownNonConstant
fn lv_is_known_non_constant(v: i32) -> bool { is_inst_op(lv_strip_ptr_casts(v, false), OP_ALLOCA) }

fn lv_single_or_constant(r: VL, ty: i32) -> i32 {
    if vl_is_constant(r) { return r.c; }
    if vl_is_range(r, true) && rg_is_single(r.r) { return lv_cint(ty, r.r.lo); }
    return -1;
}

// getConstant
fn lvi_get_constant(v: i32, cxt: i32) -> i32 {
    if lv_is_known_non_constant(v) { return -1; }
    lv_get_impl();
    let r = lv_get_value_in_block(v, inst_parent(cxt), cxt);
    return lv_single_or_constant(r, vals[v].ty);
}
// getConstantRange
fn lvi_get_constant_range(v: i32, cxt: i32, undef_allowed: bool) -> CRange {
    lv_get_impl();
    let r = lv_get_value_in_block(v, inst_parent(cxt), cxt);
    return vl_as_range_ty(r, vals[v].ty, undef_allowed);
}
// getConstantRangeAtUse
fn lvi_get_constant_range_at_use(u: i32, undef_allowed: bool) -> CRange {
    lv_get_impl();
    let r = lv_get_value_at_use(u);
    return vl_as_range_ty(r, vals[uses[u].val].ty, undef_allowed);
}
// getConstantOnEdge
fn lvi_get_constant_on_edge(v: i32, from: i32, to: i32, cxt: i32) -> i32 {
    lv_get_impl();
    let r = lv_get_value_on_edge(v, from, to, cxt);
    return lv_single_or_constant(r, vals[v].ty);
}
// getConstantRangeOnEdge
fn lvi_get_constant_range_on_edge(v: i32, from: i32, to: i32, cxt: i32) -> CRange {
    lv_get_impl();
    let r = lv_get_value_on_edge(v, from, to, cxt);
    return vl_as_range_ty(r, vals[v].ty, true);
}

fn lv_bool_for(ty: i32, b: bool) -> i32 { vl_bool_const(ty, b) }
fn lv_cmp_result_type(t: i32) -> i32 { if ty_is_vector(t) { ty_vector(ty_int(1), ty_count(t), ty_kind(t) == TK_SVEC) } else { ty_int(1) } }

// getPredicateResult
fn lv_predicate_result(p: i64, c: i32, val: VL) -> i32 {
    if vl_is_constant(val) { return cf_fold_cmp_operands(p, val.c, c, -1); }
    let rty = lv_cmp_result_type(vals[c].ty);
    if vl_is_range(val, true) {
        let rhs = rg_of_const(c);
        if rg_icmp(p, val.r, rhs) { return lv_bool_for(rty, true); }
        if rg_icmp(rg_icmp_inverse(p), val.r, rhs) { return lv_bool_for(rty, false); }
        return -1;
    }
    if vl_is_not_constant(val) {
        if p == P_EQ {
            let r = cf_fold_cmp_operands(P_NE, val.c, c, -1);
            if r >= 0 && is_null_value(r) { return lv_bool_for(rty, false); }
        } else if p == P_NE {
            let r = cf_fold_cmp_operands(P_NE, val.c, c, -1);
            if r >= 0 && is_null_value(r) { return lv_bool_for(rty, true); }
        }
        return -1;
    }
    return -1;
}

// getPredicateOnEdge
fn lvi_get_predicate_on_edge(p: i64, v: i32, c: i32, from: i32, to: i32, cxt: i32) -> i32 {
    lv_get_impl();
    let r = lv_get_value_on_edge(v, from, to, cxt);
    return lv_predicate_result(p, c, r);
}

// getPredicateAt(Pred, V, C, CxtI, UseBlockValue)
fn lvi_get_predicate_at(p: i64, v: i32, c: i32, cxt: i32, use_block_value: bool) -> i32 {
    if lv_is_ptr(vals[v].ty) && is_null_value(c) && lv_known_non_zero_noctx(lv_strip_ptr_casts(v, true)) {
        let rty = lv_cmp_result_type(vals[c].ty);
        if p == P_EQ { return lv_bool_for(rty, false); }
        if p == P_NE { return lv_bool_for(rty, true); }
    }
    lv_get_impl();
    let r = if use_block_value { lv_get_value_in_block(v, inst_parent(cxt), cxt) } else { lv_get_value_at(v, cxt) };
    let ret = lv_predicate_result(p, c, r);
    if ret >= 0 { return ret; }
    let bb = inst_parent(cxt);
    var preds: i32[>..<] = [];
    each_pred(bb) { x => preds.push(x); };
    if preds.len == 0 { return -1; }
    if is_inst_op(v, OP_PHI) && inst_parent(v) == bb {
        var baseline: i32 = -1;
        for i in phi_nincoming(v) {
            let inc = phi_value(v, i);
            let pb = phi_block(v, i);
            let res = lvi_get_predicate_on_edge(p, inc, c, pb, bb, cxt);
            baseline = if i == 0 { res } else { if baseline == res { baseline } else { -1 } };
            if baseline < 0 { break; }
        }
        if baseline >= 0 { return baseline; }
    }
    if !is_inst(v) || inst_parent(v) != bb {
        let baseline = lvi_get_predicate_on_edge(p, v, c, preds[0], bb, cxt);
        if baseline >= 0 {
            var all = true;
            for k in 1..preds.len {
                let r2 = lvi_get_predicate_on_edge(p, v, c, preds[k], bb, cxt);
                if r2 != baseline { all = false; break; }
            }
            if all { return baseline; }
        }
    }
    return -1;
}

// getPredicateAt(Pred, LHS, RHS, CxtI, UseBlockValue)
fn lvi_get_predicate_at2(p: i64, lhs: i32, rhs: i32, cxt: i32, use_block_value: bool) -> i32 {
    if is_constant(rhs) { return lvi_get_predicate_at(p, lhs, rhs, cxt, use_block_value); }
    if is_constant(lhs) { return lvi_get_predicate_at(lv_swap_pred_any(p), rhs, lhs, cxt, use_block_value); }
    if use_block_value {
        lv_get_impl();
        let l = lv_get_value_in_block(lhs, inst_parent(cxt), cxt);
        if vl_is_overdefined(l) { return -1; }
        let r = lv_get_value_in_block(rhs, inst_parent(cxt), cxt);
        let ty = lv_cmp_result_type(vals[lhs].ty);
        return vl_get_compare(l, p, ty, r);
    }
    return -1;
}
// CmpInst::getSwappedPredicate for fcmp and icmp predicates
fn lv_swap_pred_any(p: i64) -> i64 {
    if p >= 32 { return pred_swap_i(p); }
    // fcmp: FCMP_OGT(2)<->OLT(4), OGE(3)<->OLE(5), UGT(10)<->ULT(12), UGE(11)<->ULE(13)
    return match p { 2 => 4, 4 => 2, 3 => 5, 5 => 3, 10 => 12, 12 => 10, 11 => 13, 13 => 11, _ => p };
}

// ---------------------------------------------------------------------------------------------
// print<lazy-value-info> (LazyValueInfoPrinterPass, LazyValueInfoAnnotatedWriter)

// operator<<(raw_ostream &, const ValueLatticeElement &)
fn lv_format_vl(out: u8[>..]&, l: VL, fv: i32) {
    if vl_is_unknown(l) { out.append("unknown"); return; }
    if vl_is_undef(l) { out.append("undef"); return; }
    if vl_is_overdefined(l) { out.append("overdefined"); return; }
    if vl_is_not_constant(l) { out.append("notconstant<"); lv_format_value(out, l.c, fv); out.append(">"); return; }
    if vl_is_range_including_undef(l) {
        out.append("constantrange incl. undef <"); ap_format(out, l.r.lo, true); out.append(", "); ap_format(out, l.r.hi, true); out.append(">");
        return;
    }
    if vl_is_range(l, true) {
        out.append("constantrange<"); ap_format(out, l.r.lo, true); out.append(", "); ap_format(out, l.r.hi, true); out.append(">");
        return;
    }
    out.append("constant<"); lv_format_value(out, l.c, fv); out.append(">");
}

// Value::print of a constant: a global variable / function prints its definition, other constants "<type> <value>"
fn lv_format_value(dst: u8[>..]&, c: i32, fv: i32) {
    let k = vals[c].kind;
    let mark = errbuf.len;
    if k == VK_GVAR {
        slots_begin(fv);
        let pm = out.len;
        print_global_var(c);
        var end = out.len;
        if end > pm && out[end - 1] == '\n' { end--; }
        dst.append(out[pm..end]);
        out.resize(pm);
        return;
    }
    if k == VK_FUNC {
        // Value::print of a Function: AssemblyWriter::printFunction with its own function slots
        slots_begin(fv);
        slots_end();
        let md_mark = md_order.len;
        let as_mark = as_order.len;
        let pm = out.len;
        print_function(c);
        dst.append(out[pm..]);
        out.resize(pm);
        while md_order.len > md_mark { mdslot[md_order[md_order.len - 1]] = -1; md_order.resize(md_order.len - 1); }
        while as_order.len > as_mark { asslot[as_order[as_order.len - 1]] = -1; as_order.resize(as_order.len - 1); }
        return;
    }
    if is_global(c) { lv_not_ported("printing an alias in a lattice value"); }
    errs_operand(c, fv, true);
    dst.append(errbuf[mark..]);
    errbuf.resize(mark);
}

fn lv_annot_result(line: u8[>..]&, i: i32, bb: i32, fv: i32) {
    let r = lv_get_value_in_block(i, bb, -1);
    line.append("; LatticeVal for: '");
    let mark = errbuf.len;
    errs_inst(i, fv);
    line.append(errbuf[mark..]);
    errbuf.resize(mark);
    line.append("' in BB: '");
    let m2 = errbuf.len;
    errs_operand(bb, fv, false);
    line.append(errbuf[m2..]);
    errbuf.resize(m2);
    line.append("' is: ");
    lv_format_vl(line, r, fv);
    line.append("\n");
}

// LazyValueInfoPrinterPass::run
fn lvi_print(fv: i32) {
    errs("LVI for function '");
    errs(val_name(fv));
    errs("':\n");
    lvi_get(fv);
    dt_get(fv, DT_DOM);
    if !lv_impl { return; }
    lvi_drain();
    var line: u8[>..] = [];
    var b = func_entry(fv);
    while b >= 0 {
        // emitBasicBlockStartAnnot
        line.clear();
        for k in func_nargs(fv) {
            let a = func_arg(fv, k);
            let r = lv_get_value_in_block(a, b, -1);
            if vl_is_unknown(r) { continue; }
            line.append("; LatticeVal for: '");
            let mark = errbuf.len;
            errs_operand(a, fv, true);
            line.append(errbuf[mark..]);
            errbuf.resize(mark);
            line.append("' is: ");
            lv_format_vl(line, r, fv);
            line.append("\n");
        }
        if line.len > 0 { pr_annot_set(b, line); }
        var i = block_first(b);
        while i >= 0 {
            // emitInstructionAnnot
            line.clear();
            var printed: i32[>..<] = [];
            let parent = b;
            printed.push(parent);
            lv_annot_result(line, i, parent, fv);
            let t = block_terminator(parent);
            if t >= 0 {
                for k in term_nsucc(t) {
                    let s = term_succ(t, k);
                    if dt_dominates_block(DT_DOM, parent, s) {
                        var seen = false;
                        for x in printed { if x == s { seen = true; } }
                        if !seen { printed.push(s); lv_annot_result(line, i, s, fv); }
                    }
                }
            }
            var u = vals[i].first_use;
            while u >= 0 {
                let ui = uses[u].user;
                if is_inst(ui) {
                    if iop(ui) != OP_PHI || dt_dominates_block(DT_DOM, parent, inst_parent(ui)) {
                        let ub = inst_parent(ui);
                        var seen = false;
                        for x in printed { if x == ub { seen = true; } }
                        if !seen { printed.push(ub); lv_annot_result(line, i, ub, fv); }
                    }
                }
                u = uses[u].next;
            }
            pr_annot_set(i, line);
            i = inst_next(i);
        }
        b = block_next(b);
    }
    mssa_print_function(fv);
}
