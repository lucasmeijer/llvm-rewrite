// SLPVectorizer: memory-access analysis and the small TTI cost wrappers of the tree builder. Port of
// llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp: arePointersCompatible, computeCommonAlignment, isReverseOrder,
// getShuffleCost / getScalarizationOverhead / getVectorInstrCost (the SLP wrappers, 7026-7110), buildCompressMask,
// isMaskedLoadCompress, isMaskedStoreCompress, isStridedLoad / analyzeConstantStrideCandidate /
// analyzeRtStrideCandidate (always false: X86 and the base TTI have no legal strided accesses),
// BoUpSLP::canVectorizeLoads with CheckForShuffledLoads, getGEPCosts, buildIntrinsicArgTypes, getVectorCallCosts;
// llvm::sortPtrAccesses (llvm/lib/Analysis/LoopAccessAnalysis.cpp); TTI::getPointersChainCost
// (TargetTransformInfoImpl.h, X86TargetTransformInfo.cpp).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import gen_x86target;
import datalayout;
import apint;
import pm;
import flags;
import vt;
import laa;
import loads;
import loopinfo;
import tti;
import tti_x86;
import tti_x86_vec;
import tti_x86_intr;
import tti_vec;
import vecutils;
import slp_util;
import slp_tree;
import slp_ops;

let LS_GATHER: i64 = 0;
let LS_VECTORIZE: i64 = 1;
let LS_SCATTER: i64 = 2;
let LS_STRIDED: i64 = 3;
let LS_COMPRESS: i64 = 4;
let LS_CHECK: i64 = 5;      // internal: canVectorizeLoads would run CheckForShuffledLoads

fn slp_threshold() -> i64 { flag_int("slp-threshold", 0) }
fn slp_ld_align(i: i32) -> i64 { let a = insts[inst_of(i)].align; return if a == 0 { 1 } else { (1 as i64) << ((a - 1) as i64) }; }
fn slp_ptr_as(v: i32) -> i64 { ty_bits(ty_scalar(vals[v].ty)) }

// ---------------------------------------------------------------- TTI wrappers
// ::getShuffleCost(TTI, Kind, Tp, Mask, CostKind, Index, SubTp)
fn slp_shuffle_cost(sk: i64, tp: i32, mask: const i32[:], index: i64, subtp: i32) -> i64 {
    let kind = TCK_RECIP_THROUGHPUT;
    var dst = tp;
    if mask.len > 0 { dst = ty_vector(ty_scalar(tp), mask.len, false); }
    if sk != SK_PERMUTETWOSRC { return tv_shuffle(sk, dst, tp, mask, kind, index, subtp, -1, -1, 0, -1); }
    let nsrc = ty_count(tp);
    if mask.len > 2 {
        let m = mk_mark();
        let s = mk_pool.len;
        for x in mask { mk_pool.push(x); }
        let ok, nsub, idx = sv_is_insert_subvector(s, mask.len, nsrc);
        mk_release(m);
        if ok && idx + nsub > nsrc && idx + nsrc <= mask.len {
            return tv_shuffle(SK_INSERTSUBVECTOR, dst, tp, mask, TCK_RECIP_THROUGHPUT, idx, tp, -1, -1, 0, -1);
        }
    }
    return tv_shuffle(sk, dst, tp, mask, kind, index, subtp, -1, -1, 0, -1);
}
// ::getScalarizationOverhead(TTI, ScalarTy, Ty, DemandedElts, Insert, Extract, CostKind, ForPoisonSrc, VL)
fn slp_scalarization_overhead(sty: i32, ty: i32, dem: const bool[:], insert: bool, extract: bool, for_poison: bool) -> i64 {
    if ty_kind(sty) == TK_FVEC { slp_fail("REVEC scalarization overhead"); }
    if tti_kind != TTI_X86 { return 0; }
    let m = mk_mark();
    let im = ica_mark();
    let ds = mk_pool.len;
    for d in dem { mk_pool.push(if d { 1 } else { 0 }); }
    let c = x86_scalarization_overhead(ty, ds, insert, extract, TCK_RECIP_THROUGHPUT, for_poison);
    mk_release(m);
    ica_release(im);
    return c;
}
fn slp_scalarization_overhead_all(sty: i32, ty: i32, n: i64, insert: bool, extract: bool) -> i64 {
    var dem: bool[>..<] = [];
    for k in n { dem.push(true); }
    return slp_scalarization_overhead(sty, ty, dem, insert, extract, true);
}
fn slp_scalarization_overhead_bit0(sty: i32, ty: i32, n: i64) -> i64 {
    var dem: bool[>..<] = [];
    for k in n { dem.push(k == 0); }
    return slp_scalarization_overhead(sty, ty, dem, true, false, true);
}
// getMemIntrinsicInstrCost(MemIntrinsicCostAttributes(...))
fn slp_mem_intrinsic_cost(id: i32, data: i32, ptr: i32, variable_mask: bool, align: i64, as_: i64) -> i64 {
    if tti_kind != TTI_X86 { slp_fail("getMemIntrinsicInstrCost without a target"); }
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_mem_intrinsic_cost(id, data, ptr, variable_mask, align, as_, TCK_RECIP_THROUGHPUT);
    mk_release(m);
    ica_release(im);
    return c;
}
// getPointersChainCost(Ptrs, Base, Info, AccessTy, CostKind): info 0 unit stride, 1 known stride, 2 unknown stride
fn slp_pointers_chain_cost(ptrs: const i32[:], base: i32, info: i64, access_ty: i32) -> i64 {
    let kind = TCK_RECIP_THROUGHPUT;
    if tti_kind == TTI_X86 && info != 2 {
        if is_inst_op(base, OP_GEP) { return tti_gep_cost(insts[inst_of(base)].ty2, op(base, 0), base, -1, kind); }
        return TCC_FREE;
    }
    var c: i64 = 0;
    for v in ptrs {
        if !is_inst_op(v, OP_GEP) { continue; }
        if v != base {
            if slp_gep_all_constant_indices(v) { continue; }
            c = tc_add(c, tv_arith0(OP_ADD, vals[v].ty, kind));
        } else {
            c = tc_add(c, tti_gep_cost(insts[inst_of(v)].ty2, op(v, 0), v, access_ty, kind));
        }
    }
    return c;
}
fn slp_gep_all_constant_indices(g: i32) -> bool {
    for k in 1..nops(g) { if !is_cint(op(g, k)) { return false; } }
    return true;
}
fn slp_is_gep_operator(v: i32) -> bool { is_inst_op(v, OP_GEP) || (vals[v].kind == VK_CEXPR && vals[v].op as i64 == OP_GEP) }
fn slp_gep_source_type(g: i32) -> i32 {
    if is_inst(g) { return insts[inst_of(g)].ty2; }
    return gep_ce_source_type(g);
}
// getGEPCosts(TTI, Ptrs, BasePtr, Opcode, CostKind, ScalarTy, VecTy): (scalar, vector)
fn slp_gep_costs(ptrs: const i32[:], base: i32, o: i64, sty: i32, vty: i32) -> i64, i64 {
    let kind = TCK_RECIP_THROUGHPUT;
    var sc: i64 = 0;
    var vc: i64 = 0;
    if o == OP_LOAD || o == OP_STORE {
        sc = slp_pointers_chain_cost(ptrs, base, 0, sty);
        var retained: i32[>..<] = [];
        for v in ptrs {
            if v == base { retained.push(v); continue; }
            if !is_inst_op(v, OP_GEP) || !slp_has_one_use(v) { retained.push(v); }
        }
        if retained.len == ptrs.len { return TCC_FREE, TCC_FREE; }
        vc = slp_pointers_chain_cost(retained, base, 1, vty);
    } else {
        var all_nonconst = true;
        for v in ptrs { if !(is_inst_op(v, OP_GEP) && !slp_gep_all_constant_indices(v)) { all_nonconst = false; break; } }
        sc = slp_pointers_chain_cost(ptrs, base, if all_nonconst { 2 } else { 1 }, sty);
        var bg: i32 = if slp_is_gep_operator(base) { base } else { -1 };
        if bg < 0 { for v in ptrs { if slp_is_gep_operator(v) { bg = v; break; } } }
        if bg >= 0 { vc = tti_gep_cost(slp_gep_source_type(bg), op(bg, 0), bg, vty, kind); }
    }
    return sc, vc;
}
fn gep_ce_source_type(g: i32) -> i32 { slp_fail("getGEPCosts of a GEP constant expression"); return -1; }

// buildIntrinsicArgTypes(CI, ID, VF, MinBW, TTI)
fn slp_intrinsic_arg_types(ci: i32, id: i32, vf: i64, minbw: i64, out: i32[>..<]&) {
    out.clear();
    for k in cb_nargs(ci) {
        let a = cb_arg(ci, k);
        if id != 0 {
            if vu_scalar_op_at_arg(id, k, true) { out.push(vals[a].ty); continue; }
            if minbw > 0 { out.push(slp_widened_type(ty_int(minbw), vf)); continue; }
        }
        out.push(slp_widened_type(vals[a].ty, vf));
    }
}
// getVectorCallCosts(CI, VecTy, TTI, TLI, ArgTys): (intrinsic cost, library cost). VFDatabase mappings are not
// supported (slp_is_vf_mapped_call fails loudly on them), so the library cost is always invalid.
fn slp_vector_call_costs(ci: i32, vecty: i32, argtys: const i32[:]) -> i64, i64 {
    if slp_is_vf_mapped_call(ci) { return TTI_INVALID, TTI_INVALID; }
    if tti_kind != TTI_X86 { slp_fail("getVectorCallCosts without a target"); }
    let id = laa_vector_intrinsic_id_for_call(ci);
    let fmf: u8 = if is_fp_math_operator(ci) { insts[inst_of(ci)].fmf } else { 0 };
    var ic: i64 = 0;
    {
        let m = mk_mark();
        let im = ica_mark();
        let a = ica_new(id as i64, vecty, fmf, -1, 10000);
        for t in argtys { ica_add_type(a, t); }
        ic = x86_intrinsic_cost(a, TCK_RECIP_THROUGHPUT);
        mk_release(m);
        ica_release(im);
    }
    if ic > 10000 {
        let m = mk_mark();
        let im = ica_mark();
        let ii = if id != 0 && is_intrinsic_inst(ci) { ci } else { -1 };
        let a = ica_new(id as i64, vecty, fmf, ii, 10000);
        for k in cb_nargs(ci) { ica_add_arg(a, cb_arg(ci, k)); }
        for t in argtys { ica_add_type(a, t); }
        ic = x86_intrinsic_cost(a, TCK_RECIP_THROUGHPUT);
        mk_release(m);
        ica_release(im);
        if ic > 10000 { ic = TTI_INVALID; }
    }
    return ic, TTI_INVALID;
}

// ---------------------------------------------------------------- pointers
// arePointersCompatible(Ptr1, Ptr2, TLI, CompareOpcodes)
fn slp_pointers_compatible(p1: i32, p2: i32, compare_opcodes: bool) -> bool {
    let rmd = flag_int("slp-recursion-max-depth", 12);
    if get_underlying_object(p1, rmd) != get_underlying_object(p2, rmd) { return false; }
    let g1 = is_inst_op(p1, OP_GEP);
    let g2 = is_inst_op(p2, OP_GEP);
    if g1 && nops(p1) != 2 { return false; }
    if g2 && nops(p2) != 2 { return false; }
    if (!g1 || slp_is_constant(op(p1, 1))) && (!g2 || slp_is_constant(op(p2, 1))) { return true; }
    if !compare_opcodes { return true; }
    if g1 && g2 { return sis_valid(slp_same_opcode2(op(p1, 1), op(p2, 1))); }
    return false;
}
fn slp_common_alignment(vl: const i32[:]) -> i64 {
    var a = slp_ld_align(vl[0]);
    for k in 1..vl.len { let b = slp_ld_align(vl[k]); if b < a { a = b; } }
    return a;
}
fn slp_is_reverse_order(order: const i32[:]) -> bool {
    let sz = order.len;
    for k in sz { let v = order[k] as i64; if !(v == sz || sz - k - 1 == v) { return false; } }
    return true;
}
// llvm::sortPtrAccesses(VL, ElemTy, DL, SE, SortedIndices)
fn slp_sort_ptr_accesses(vl: const i32[:], ety: i32, sorted: i32[>..<]&) -> bool {
    let p0 = vl[0];
    // std::set<(offset, index)> ordered by offset
    var offs: i64[>..<] = [];
    var idxs: i32[>..<] = [];
    offs.push(0);
    idxs.push(0);
    var consecutive = true;
    for k in 1..vl.len {
        let ok, d = laa_get_pointers_diff(ety, p0, ety, vl[k], true, true);
        if !ok { return false; }
        var pos: i64 = 0;
        while pos < offs.len && offs[pos] < d { pos++; }
        if pos < offs.len && offs[pos] == d { return false; }
        offs.push(0); idxs.push(0);
        var j = offs.len - 1;
        while j > pos { offs[j] = offs[j - 1]; idxs[j] = idxs[j - 1]; j--; }
        offs[pos] = d;
        idxs[pos] = k as i32;
        consecutive = consecutive && pos == offs.len - 1;
    }
    sorted.clear();
    if !consecutive { for x in idxs { sorted.push(x); } }
    return true;
}
fn slp_ptrs_diff(ety: i32, a: i32, b: i32) -> bool, i64 { let ok, d = laa_get_pointers_diff(ety, a, ety, b, false, true); return ok, d; }

// buildCompressMask(PointerOps, Order, ScalarTy, DL, SE, CompressMask)
fn slp_build_compress_mask(ptrs: const i32[:], order: const i32[:], sty: i32, mask: i32[>..<]&) -> bool {
    let sz = ptrs.len;
    mask.clear();
    for k in sz { mask.push(-1); }
    mask[0] = 0;
    var stride_valid = true;
    var stride: i64 = 0;
    let p0 = if order.len == 0 { ptrs[0] } else { ptrs[order[0] as i64] };
    for i in 1..sz {
        let p = if order.len == 0 { ptrs[i] } else { ptrs[order[i] as i64] };
        let ok, pos = slp_ptrs_diff(sty, p0, p);
        if !ok || pos > 0xFFFFFFFF { return false; }
        let upos = pos & 0xFFFFFFFF;
        mask[i] = upos as i32;
        if !stride_valid { continue; }
        if stride == 0 { stride = upos; continue; }
        if upos != stride * i { stride_valid = false; }
    }
    return stride_valid;
}
// isMaskedLoadCompress(VL, PointerOps, Order, ...): (ok, IsMasked, InterleaveFactor), CompressMask in `cmask`,
// LoadVecTy in slp_lc_vecty
var slp_lc_vecty: i32 = -1;
fn slp_is_masked_load_compress(vl: const i32[:], ptrs: const i32[:], order: const i32[:], cmask: i32[>..<]&) -> bool, bool, i64 {
    let sty: i32 = vals[vl[0]].ty;
    let sz = vl.len;
    let vecty = slp_widened_type(sty, sz);
    var mask: i32[>..<] = [];
    if order.len > 0 { slp_inverse_permutation(order, mask); }
    for i in vl.len {
        let v = vl[i];
        if slp_are_all_users_vectorized(v, slp_uil_on) { continue; }
        let ec = tv_vec_inst(OP_EXTRACTELEMENT, vecty, if mask.len == 0 { i } else { mask[i] as i64 }, -1, -1, TCK_RECIP_THROUGHPUT);
        let scost = tv_inst_cost(v, TCK_RECIP_THROUGHPUT);
        if ec <= scost { return false, false, 0; }
    }
    let p0 = if order.len == 0 { ptrs[0] } else { ptrs[order[0] as i64] };
    let pn = if order.len == 0 { ptrs[ptrs.len - 1] } else { ptrs[order[order.len - 1] as i64] };
    let ok, diff = slp_ptrs_diff(sty, p0, pn);
    if !ok { return false, false, 0; }
    let maxreg = tv_register_bit_width(1);
    if diff / sz >= maxreg / 8 { return false, false, 0; }
    var lvt = slp_widened_type(sty, diff + 1);
    let li = if order.len == 0 { vl[0] } else { vl[order[0] as i64] };
    let calign = slp_ld_align(li);
    let last = if order.len == 0 { vl[vl.len - 1] } else { vl[order[order.len - 1] as i64] };
    let masked = !ld_safe_to_load_unconditionally_ty_acdt(p0, lvt, calign, last);
    if masked && !slp_tti_legal_masked_load(lvt) { return false, false, 0; }
    let strided = slp_build_compress_mask(ptrs, order, sty, cmask);
    var optrs: i32[>..<] = [];
    for p in ptrs { optrs.push(p); }
    if order.len > 0 { slp_reorder_scalars(optrs, mask); }
    let sgep, vgep = slp_gep_costs(optrs, optrs[0], OP_LOAD, sty, lvt);
    var sloads: i64 = 0;
    for v in vl { sloads = tc_add(sloads, tv_inst_cost(v, TCK_RECIP_THROUGHPUT)); }
    sloads = tc_add(sloads, sgep);
    let gather = tc_add(slp_scalarization_overhead_all(sty, vecty, sz, true, false), sloads);
    var lc: i64 = 0;
    if masked {
        lc = slp_mem_intrinsic_cost(IID_masked_load, lvt, -1, false, calign, slp_ptr_as(op(li, 0)));
    } else {
        lc = tv_mem(OP_LOAD, lvt, calign, slp_ptr_as(op(li, 0)), TCK_RECIP_THROUGHPUT);
    }
    if strided && !masked && order.len == 0 {
        // isLegalInterleavedAccessType is false on X86 and in the base TTI: no segmented loads
        var alvt = slp_widened_type(sty, slp_full_vector_number_of_elements(sty, diff + 1));
        if !ld_safe_to_load_unconditionally_ty_acdt(p0, alvt, calign, vl[vl.len - 1]) { alvt = lvt; }
    }
    if tc_add(vgep, lc) >= gather { return false, false, 0; }
    let cc = slp_shuffle_cost(SK_PERMUTESINGLESRC, lvt, cmask, 0, -1);
    if order.len > 0 {
        var nm: i32[>..<] = [];
        for i in sz { nm.push(cmask[mask[i] as i64]); }
        cmask.clear();
        for x in nm { cmask.push(x); }
    }
    slp_lc_vecty = lvt;
    let total = tc_add(tc_add(vgep, lc), cc);
    return total < gather, masked, 0;
}
// isMaskedStoreCompress(VL, PointerOps, Order, ..., CommonAlignment, ReuseShuffleIndices, StoreVecTy)
fn slp_is_masked_store_compress(vl: const i32[:], ptrs: const i32[:], order: const i32[:], calign: i64, reuse: i32[>..<]&) -> bool, i32 {
    let sty: i32 = vals[op(vl[0], 0)].ty;
    let sz = vl.len;
    if sz < 2 || (!ty_is_int(sty) && ty_kind(sty) != TK_PTR && !ty_is_fp(sty)) { return false, -1; }
    let p0 = if order.len == 0 { ptrs[0] } else { ptrs[order[0] as i64] };
    let pn = if order.len == 0 { ptrs[ptrs.len - 1] } else { ptrs[order[order.len - 1] as i64] };
    let ok, diff = slp_ptrs_diff(sty, p0, pn);
    if !ok || diff <= 0 { return false, -1; }
    let maxreg = tv_register_bit_width(1);
    let sbits = dl_size_bits(sty);
    if sbits == 0 || diff / sz >= maxreg / sbits { return false, -1; }
    let svt = slp_widened_type(sty, diff + 1);
    if !slp_tti_legal_masked_store(svt) { return false, -1; }
    reuse.clear();
    for k in diff + 1 { reuse.push(-1); }
    var prev: i64 = -1;
    for i in sz {
        let p = if order.len == 0 { ptrs[i] } else { ptrs[order[i] as i64] };
        let ok2, off = slp_ptrs_diff(sty, p0, p);
        if !ok2 || off <= prev || off > diff { return false, -1; }
        reuse[off] = i as i32;
        prev = off;
    }
    return true, svt;
}

// ---------------------------------------------------------------- canVectorizeLoads
var slp_cvl_best_vf: i64 = 0;
// The part of canVectorizeLoads before CheckForShuffledLoads: LS_CHECK when it would be called (then
// slp_cvl_pgp = ProfitableGatherPointers).
var slp_cvl_pgp: bool = false;
fn slp_cvl_base(vl: const i32[:], vl0: i32, order: i32[>..<]&, ptrs: i32[>..<]&) -> i64 {
    if slp_known_nonvect_loads(vl) { return LS_GATHER; }
    let sty: i32 = vals[vl0].ty;
    if dl_size_bits(sty) != dl_alloc_size(sty) * 8 { return LS_GATHER; }
    ptrs.clear();
    let sz = vl.len;
    for v in vl {
        if !is_inst_op(v, OP_LOAD) || !ld_is_simple(v) { return LS_GATHER; }
        ptrs.push(op(v, 0));
    }
    order.clear();
    let sorted = slp_sort_ptr_accesses(ptrs, sty, order);
    let vecty = slp_widened_type(sty, sz);
    let calign = slp_common_alignment(vl);
    var mg_known = false;
    var mg_legal = false;
    fn mgl() -> bool {
        if !mg_known { mg_legal = slp_tti_legal_masked_gather(vecty) && !slp_tti_force_scalarize_masked_gather(vecty); mg_known = true; }
        return mg_legal;
    }
    if !sorted {
        // analyzeRtStrideCandidate: no legal strided loads
        if !mgl() { return LS_GATHER; }
        for p in ptrs { if !slp_pointers_compatible(p, ptrs[0], true) { return LS_GATHER; } }
    } else {
        let p0 = if order.len == 0 { ptrs[0] } else { ptrs[order[0] as i64] };
        let pn = if order.len == 0 { ptrs[ptrs.len - 1] } else { ptrs[order[order.len - 1] as i64] };
        let ok0, d0 = slp_ptrs_diff(sty, ptrs[0], p0);
        let okn, dn = slp_ptrs_diff(sty, ptrs[0], pn);
        if !ok0 || !okn { fatal("internal: SLP: sortPtrAccesses should have validated these pointers"); }
        let diff = dn - d0;
        if diff == sz - 1 { return LS_VECTORIZE; }
        var cm: i32[>..<] = [];
        let c, m, f = slp_is_masked_load_compress(vl, ptrs, order, cm);
        if c { return LS_COMPRESS; }
        // analyzeConstantStrideCandidate: no legal strided loads
    }
    if !mgl() { return LS_GATHER; }
    let l = li_loop_for(inst_parent(vl0));
    var pgp = false;
    if l >= 0 && sz > 2 {
        var ninv: i64 = 0;
        for p in ptrs { if slp_loop_invariant(l, p) { ninv++; } }
        pgp = ninv <= sz / 2;
    }
    var allg = true;
    for p in ptrs {
        let g = is_inst_op(p, OP_GEP);
        let ok = (!g && slp_does_not_need_to_be_scheduled(p)) || (g && nops(p) == 2 && (is_constant(op(p, 1)) || is_inst(op(p, 1))));
        if !ok { allg = false; break; }
    }
    if pgp || allg {
        slp_cvl_pgp = pgp;
        return LS_CHECK;
    }
    return LS_GATHER;
}
// canVectorizeLoads(VL, VL0, Order, PointerOps, SPtrInfo, BestVF, TryRecursiveCheck); best_vf_req = BestVF != null
// (the result is in slp_cvl_best_vf)
fn slp_can_vectorize_loads(vl: const i32[:], vl0: i32, order: i32[>..<]&, ptrs: i32[>..<]&, best_vf_req: bool, try_rec: bool) -> i64 {
    if best_vf_req { slp_cvl_best_vf = 0; }
    let r = slp_cvl_base(vl, vl0, order, ptrs);
    if r != LS_CHECK { return r; }
    if !try_rec { return LS_SCATTER; }
    let pgp = slp_cvl_pgp;
    if !slp_check_for_shuffled_loads(vl, vl0, ptrs, best_vf_req, pgp) { return LS_SCATTER; }
    return LS_GATHER;
}
// CheckForShuffledLoads(CommonAlignment, BestVF, ProfitableGatherPointers)
fn slp_check_for_shuffled_loads(vl: const i32[:], vl0: i32, ptrs: const i32[:], best_vf_req: bool, pgp: bool) -> bool {
    if best_vf_req { slp_cvl_best_vf = 0; }
    let sty: i32 = vals[vl0].ty;
    let sz0 = vl.len;
    let vecty = slp_widened_type(sty, sz0);
    let calign = slp_common_alignment(vl);
    let thr = slp_threshold();
    var sgep, vgep = slp_gep_costs(ptrs, ptrs[0], OP_LOAD, sty, vecty);
    let pty = ty_scalar(vals[ptrs[0]].ty);
    let pvt = slp_widened_type(pty, sz0);
    let front_uo = get_underlying_object(ptrs[0], 6);
    var ngep: i64 = 0;
    for p in ptrs { if is_inst_op(p, OP_GEP) { ngep++; } }
    var any_other_uo = false;
    for p in ptrs { if get_underlying_object(p, 6) != front_uo { any_other_uo = true; break; } }
    if ngep < ptrs.len - 1 || any_other_uo {
        vgep = tc_add(vgep, slp_scalarization_overhead_all(pty, pvt, sz0, true, false));
    } else {
        vgep = tc_add(vgep, tc_add(slp_scalarization_overhead_bit0(pty, pvt, sz0), slp_shuffle_cost(SK_BROADCAST, pvt, slp_no_mask(), 0, -1)));
    }
    var sloads: i64 = 0;
    for v in vl { sloads = tc_add(sloads, tv_inst_cost(v, TCK_RECIP_THROUGHPUT)); }
    sloads = tc_add(sloads, sgep);
    let mgc = tc_add(slp_mem_intrinsic_cost(IID_masked_gather, vecty, op(vl0, 0), false, calign, 0), if pgp { 0 } else { vgep });
    let gc = tc_add(slp_scalarization_overhead_all(sty, vecty, sz0, true, false), sloads);
    if vl.len < 4 { return tc_sub(mgc, gc) >= -thr; }
    let bits = dl_size_bits(sty);
    let minvf = slp_min_vf(2 * bits);
    var dem: bool[>..<] = [];
    for k in vl.len { dem.push(false); }
    var vf = slp_floor_full_vector_number_of_elements(sty, vl.len - 1);
    while vf >= minvf {
        var st_start: i64[>..<] = [];
        var st_ls: i64[>..<] = [];
        var cnt: i64 = 0;
        var all_dem = false;
        while cnt < vl.len {
            let svf = if vf < vl.len - cnt { vf } else { vl.len - cnt };
            let slice = vl[cnt..cnt + svf];
            var o2: i32[>..<] = [];
            var p2: i32[>..<] = [];
            if best_vf_req { slp_cvl_best_vf = 0; }
            var ls = slp_cvl_base(slice, slice[0], o2, p2);
            if ls == LS_CHECK { ls = LS_SCATTER; }
            if ls == LS_GATHER {
                if best_vf_req {
                    for k in dem.len { dem[k] = true; }
                    break;
                }
                for k in cnt..cnt + svf { dem[k] = true; }
                cnt += vf;
                continue;
            }
            if (ls == LS_VECTORIZE || ls == LS_STRIDED || ls == LS_COMPRESS) && o2.len > 0 && !slp_is_reverse_order(o2) { ls = LS_SCATTER; }
            st_start.push(cnt);
            st_ls.push(ls);
            cnt += vf;
        }
        var all_ones = true;
        for d in dem { if !d { all_ones = false; break; } }
        if all_ones {
            vf = slp_floor_full_vector_number_of_elements(sty, vf - 1);
            continue;
        }
        var vldc: i64 = 0;
        var any_dem = false;
        for d in dem { if d { any_dem = true; break; } }
        if any_dem {
            vldc = tc_add(slp_scalarization_overhead(sty, vecty, dem, true, false, true), sgep);
            for idx in vl.len { if dem[idx] { vldc = tc_add(vldc, tv_inst_cost(vl[idx], TCK_RECIP_THROUGHPUT)); } }
        }
        for si in st_start.len {
            let ss = st_start[si];
            let ls = st_ls[si];
            let svf = if vf < vl.len - ss { vf } else { vl.len - ss };
            let subvt = slp_widened_type(sty, svf);
            let li0 = vl[ss];
            var vg: i64 = 0;
            if !(ls == LS_SCATTER && pgp) {
                let a, b = slp_gep_costs(ptrs[ss..ss + svf], op(li0, 0), OP_LOAD, sty, subvt);
                vg = b;
            }
            if ls == LS_SCATTER {
                if ngep < ptrs.len - 1 || any_other_uo {
                    vg = tc_add(vg, slp_scalarization_overhead_all(sty, subvt, svf, true, false));
                } else {
                    vg = tc_add(vg, tc_add(slp_scalarization_overhead_bit0(sty, subvt, svf), slp_shuffle_cost(SK_BROADCAST, subvt, slp_no_mask(), 0, -1)));
                }
            }
            if ls == LS_VECTORIZE {
                vldc = tc_add(vldc, tc_add(tv_mem(OP_LOAD, subvt, slp_ld_align(li0), slp_ptr_as(op(li0, 0)), TCK_RECIP_THROUGHPUT), vg));
            } else if ls == LS_STRIDED {
                vldc = tc_add(vldc, tc_add(slp_mem_intrinsic_cost(IID_experimental_vp_strided_load, subvt, op(li0, 0), false, calign, 0), vg));
            } else if ls == LS_COMPRESS {
                vldc = tc_add(vldc, tc_add(slp_mem_intrinsic_cost(IID_masked_load, subvt, -1, false, calign, slp_ptr_as(op(li0, 0))),
                                           slp_shuffle_cost(SK_PERMUTESINGLESRC, subvt, slp_no_mask(), 0, -1)));
            } else {
                vldc = tc_add(vldc, tc_add(slp_mem_intrinsic_cost(IID_masked_gather, subvt, op(li0, 0), false, calign, 0), vg));
            }
            var sm: i32[>..<] = [];
            let sidx = ss / vf;
            for idx in vl.len { sm.push(if idx / vf == sidx { (vl.len + idx % vf) as i32 } else { idx as i32 }); }
            if ss > 0 { vldc = tc_add(vldc, slp_shuffle_cost(SK_INSERTSUBVECTOR, vecty, sm, ss, subvt)); }
        }
        if mgc >= vldc && tc_sub(vldc, gc) < -thr {
            if best_vf_req { slp_cvl_best_vf = vf; }
            return true;
        }
        vf = slp_floor_full_vector_number_of_elements(sty, vf - 1);
    }
    return tc_sub(mgc, gc) >= -thr;
}
var slp_no_mask_buf: i32[1];
fn slp_no_mask() -> const i32[:] { slp_no_mask_buf[..0] }
fn slp_min_vf(sz: i64) -> i64 { let x = slp_min_vreg / sz; return if x > 2 { x } else { 2 }; }
