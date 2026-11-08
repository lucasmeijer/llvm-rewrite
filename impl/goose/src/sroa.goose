// SROA: port of llvm/lib/Transforms/Scalar/SROA.cpp (SROAPass), with the parts of
// llvm/include/llvm/Analysis/PtrUseVisitor.h + llvm/lib/Analysis/PtrUseVisitor.cpp it builds on (the slice
// builder), and the IRBuilder<ConstantFolder, IRBuilderPrefixedInserter> behaviour it relies on
// (llvm/include/llvm/IR/IRBuilder.h, llvm/lib/IR/IRBuilder.cpp: insertion point, debug location, name prefix,
// constant folding; CreateBitPreservingCastChain, CreateVectorSplat, CreateMemSet/MemCpy, lifetime markers).
// AAMDNodes::adjustForAccess/shift come from llvm/lib/Analysis/TypeBasedAliasAnalysis.cpp, copyMetadataForLoad
// from llvm/lib/Transforms/Utils/Local.cpp.
//
// Not ported yet (fail loudly): debug-info migration for split allocas (dbg_declare/dbg_value/dbg_assign of a
// split alloca), propagateStoredValuesToLoads (escaped read-only allocas; needs SSAUpdater), select
// rewriting that changes the CFG (sroa<modify-cfg> with unspeculatable selects), isSafeToLoadUnconditionally
// beyond allocas/arguments with dereferenceable bytes, scalable vectors.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import local;
import tli;
import flags;
import domtree;
import dinfo;
import datalayout;
import gen_iids;
import autoupgrade;
import intrinsics;
import constfold;
import mem2reg;
import instsimplify;
import analyses;

fn sr_not_ported(what: const u8[:]) { fatal(str("SROA: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// Scratch sets and maps keyed by value or use ids (epoch-stamped, O(1) clear), private to SROA.

let SR_NS = 20;
var sr_stamp: i32[>..];
var sr_data: i64[>..];
var sr_epoch: i32[20] = [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1];
let S_VUSES = 0;       // PtrUseVisitor VisitedUses (use ids)
let S_VDEAD = 1;       // SliceBuilder VisitedDeadInsts
let S_MTMAP = 2;       // SliceBuilder MemTransferSliceMap (inst -> slice index)
let S_PHISZ = 3;       // SliceBuilder PHIOrSelectSizes
let S_WL = 4;          // Worklist membership
let S_PPWL = 5;        // PostPromotionWorklist membership
let S_PROM = 6;        // PromotableAllocas membership
let S_SPHI = 7;        // SpeculatablePHIs membership
let S_SEL = 8;         // SelectsToRewrite keys
let S_PHIU = 9;        // rewritePartition PHIUsers
let S_SELU = 10;       // rewritePartition SelectUsers
let S_TMP = 11;        // short-lived local sets (hasUnsafePHIOrSelectUse, fixLoadStoreAlign, ...)
let S_AGGV = 12;       // AggLoadStoreRewriter Visited (users)
let S_SPLIT = 13;      // presplit: SplitOffsetsMap (inst -> record index)
let S_UNSPL = 14;      // presplit: UnsplittableLoads
let S_DEL = 15;        // deleteDeadInstructions DeletedAllocas / misc
let S_AVAIL = 16;      // SSAUpdater AvailableVals (block -> value)
let S_BBMAP = 17;      // SSAUpdaterImpl BBMap (block -> info index)
let S_REPL = 18;       // LoadAndStorePromoter ReplacedLoads
let S_UBB = 19;        // LoadAndStorePromoter UsesByBlock (block -> count, -1 = processed)

fn sr_clear(s: i64) { sr_epoch[s] += 1; }
fn sr_has(s: i64, id: i32) -> bool {
    let k = (id as i64) * SR_NS + s;
    return k < sr_stamp.len && sr_stamp[k] == sr_epoch[s];
}
fn sr_grow(id: i32) {
    var n = sr_stamp.len / SR_NS;
    if n < 1024 { n = 1024; }
    while n <= id as i64 { n *= 2; }
    while sr_stamp.len < n * SR_NS { sr_stamp.push(0); sr_data.push(0); }
}
fn sr_add(s: i64, id: i32) -> bool {
    let k = (id as i64) * SR_NS + s;
    if k >= sr_stamp.len { sr_grow(id); }
    if sr_stamp[k] == sr_epoch[s] { return false; }
    sr_stamp[k] = sr_epoch[s];
    return true;
}
fn sr_del(s: i64, id: i32) {
    let k = (id as i64) * SR_NS + s;
    if k < sr_stamp.len && sr_stamp[k] == sr_epoch[s] { sr_stamp[k] = 0; }
}
fn sr_get(s: i64, id: i32, dflt: i64) -> i64 {
    let k = (id as i64) * SR_NS + s;
    if k < sr_stamp.len && sr_stamp[k] == sr_epoch[s] { return sr_data[k]; }
    return dflt;
}
fn sr_set(s: i64, id: i32, x: i64) {
    let k = (id as i64) * SR_NS + s;
    if k >= sr_stamp.len { sr_grow(id); }
    sr_stamp[k] = sr_epoch[s];
    sr_data[k] = x;
}

// ---------------------------------------------------------------------------------------------
// Small IR queries

fn sr_is_alloca(v: i32) -> bool { is_inst(v) && iop(v) == OP_ALLOCA }
fn sr_use_opno(u: i32) -> i64 { (u - vals[uses[u].user].ops) as i64 }
fn sr_inst_align(iv: i32) -> i64 { let a = insts[inst_of(iv)].align as i64; if a == 0 { 1 } else { 1 << (a - 1) } }
fn sr_set_inst_align(iv: i32, a: i64) { insts[inst_of(iv)].align = (log2_exact(a) + 1) as u8; }
fn sr_ldst_is_atomic(iv: i32) -> bool { insts[inst_of(iv)].ord != 0 }
// LoadInst/StoreInst::isSimple: not atomic, not volatile
fn sr_ldst_is_simple(iv: i32) -> bool { !sr_ldst_is_atomic(iv) && !inst_is_volatile(iv) }
fn sr_ptr_as_of(t: i32) -> i64 { types[ty_scalar(t)].n as i64 }
fn sr_alloca_ty(ai: i32) -> i32 { insts[inst_of(ai)].ty2 }
fn sr_alloca_as(ai: i32) -> i64 { types[vals[ai].ty].n as i64 }
// AllocaInst::isArrayAllocation
fn sr_alloca_is_array(ai: i32) -> bool { let n = op(ai, 0); return !(vals[n].kind == VK_CINT && sr_cint_u64(n) == 1); }
fn sr_cint_u64(c: i32) -> u64 { csts[vals[c].sub].lo }
fn cint_wide_nonzero_hi(c: i32) -> bool { csts[vals[c].sub].hi != 0 || ty_bits(vals[c].ty) > 128 }
// AllocaInst::getAllocationSize: -1 when unknown (non-constant array size); scalable sizes fail loudly.
fn sr_alloca_alloc_size(ai: i32) -> i64 {
    let t = sr_alloca_ty(ai);
    if sr_ty_is_scalable(t) { return -2; }
    var size = dl_alloc_size(t);
    if sr_alloca_is_array(ai) {
        let n = op(ai, 0);
        if vals[n].kind != VK_CINT { return -1; }
        size = size * (sr_cint_u64(n) as! i64);
    }
    return size;
}
recursive fn sr_ty_is_scalable(t: i32) -> bool {
    let k = types[t].kind;
    if k == TK_SVEC { return true; }
    if k == TK_ARRAY { return sr_ty_is_scalable(types[t].a); }
    if k == TK_STRUCT { for i in types[t].cnt { if sr_ty_is_scalable(ty_field(t, i)) { return true; } } }
    if k == TK_TARGETEXT { return sr_ty_is_scalable(target_layout_type(t)); }
    return false;
}
// AllocaInst::isStaticAlloca
fn sr_alloca_is_static(ai: i32) -> bool {
    let n = op(ai, 0);
    if vals[n].kind != VK_CINT { return false; }
    let bb = inst_parent(ai);
    return bb == func_entry(block_func(bb)) && (insts[inst_of(ai)].bits & 1) == 0;
}
fn sr_ty_is_single_value(t: i32) -> bool {
    let k = types[t].kind;
    return k == TK_INT || k == TK_PTR || ty_is_fp(t) || k == TK_FVEC || k == TK_SVEC || k == TK_X86_AMX || k == TK_TARGETEXT;
}
fn sr_ty_is_ptr(t: i32) -> bool { types[t].kind == TK_PTR }
fn sr_ty_is_ptr_or_ptr_vec(t: i32) -> bool { sr_ty_is_ptr(ty_scalar(t)) }
fn sr_ty_is_int_or_int_vec(t: i32) -> bool { ty_is_int(ty_scalar(t)) }
fn sr_ty_is_fixed_vector(t: i32) -> bool { types[t].kind == TK_FVEC }
// DataLayout::typeSizeEqualsStoreSize
fn sr_dl_size_eq_store(t: i32) -> bool { dl_size_bits(t) == dl_store_size(t) * 8 }
fn sr_dl_index_bits(as_: i64) -> i64 { dl_ptr(as_).idx }
fn sr_commonalign(a: i64, off: u64) -> i64 {
    // commonAlignment(A, Offset) = MinAlign(A, Offset)
    if off == 0 { return a; }
    let au = a as! u64;
    let m = (au | off) & (~(au | off) + 1);
    return m as! i64;
}

// GEPOperator::accumulateConstantOffset (DataLayout version): false if an index is not a ConstantInt.
fn sr_gep_const_offset(srcty: i32, g: i32, first_idx: i64) -> bool, i64 {
    var off: u64 = 0;
    var t = srcty;
    for k in first_idx..nops(g) {
        let x = op(g, k);
        if k == first_idx {
            if vals[x].kind != VK_CINT || ty_is_vector(vals[x].ty) { return false, 0; }
            off = off + (sr_cint_sext(x) * (dl_alloc_size(t) as! u64));
            continue;
        }
        if ty_is_struct(t) {
            if vals[x].kind != VK_CINT { return false, 0; }
            let fi = sr_cint_u64(x) as! i64;
            off = off + (dl_struct_offset(t, fi) as! u64);
            t = ty_field(t, fi);
        } else {
            if vals[x].kind != VK_CINT || ty_is_vector(vals[x].ty) { return false, 0; }
            let et = types[t].a;
            if types[t].kind == TK_SVEC { return false, 0; }
            off = off + (sr_cint_sext(x) * (dl_alloc_size(et) as! u64));
            t = et;
        }
    }
    return true, off as! i64;
}
fn sr_cint_sext(c: i32) -> u64 {
    let w = ty_bits(vals[c].ty);
    let lo = csts[vals[c].sub].lo;
    if w >= 64 { return lo; }
    let sh = (64 - w) as! u64;
    return ((lo << sh) as! i64 >> sh) as! u64;
}
fn sr_gep_src_type(g: i32) -> i32 { if vals[g].kind == VK_CEXPR { csts[vals[g].sub].ty2 } else { insts[inst_of(g)].ty2 } }
fn sr_gep_flags_of(g: i32) -> u8 { if vals[g].kind == VK_CEXPR { csts[vals[g].sub].flags } else { insts[inst_of(g)].flags } }
// Operator::getOpcode for instructions and constant expressions (-1 otherwise)
fn sr_operator_op(v: i32) -> i64 {
    if is_inst(v) { return iop(v); }
    if vals[v].kind == VK_CEXPR { return csts[vals[v].sub].op as i64; }
    return -1;
}

// Value::stripInBoundsOffsets
fn sr_strip_inbounds_offsets(v0: i32) -> i32 {
    var v = v0;
    if !sr_ty_is_ptr(vals[v].ty) { return v; }
    var steps = 0;
    loop {
        steps++;
        if steps > 100000 { return v; }
        let o = sr_operator_op(v);
        if o == OP_GEP {
            if (sr_gep_flags_of(v) & GEP_INBOUNDS) == 0 { return v; }
            v = op(v, 0);
        } else if o == OP_BITCAST {
            let nv = op(v, 0);
            if !sr_ty_is_ptr(vals[nv].ty) { return v; }
            v = nv;
        } else if o == OP_ADDRSPACECAST {
            v = op(v, 0);
        } else if is_callbase(v) {
            let r = sr_cb_returned_arg(v);
            if r < 0 { return v; }
            v = r;
        } else {
            return v;
        }
    }
    return v;
}
// CallBase::getReturnedArgOperand
fn sr_cb_returned_arg(c: i32) -> i32 {
    for k in cb_nargs(c) {
        if aset_has(alist_param(insts[inst_of(c)].attrs, k), AK_Returned) { return cb_arg(c, k); }
        let f = cb_callee(c);
        if f >= 0 && vals[f].kind == VK_FUNC && aset_has(alist_param(func_attrs(f), k), AK_Returned) { return cb_arg(c, k); }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// IRBuilder (insertion point + current debug location + name prefix) with ConstantFolder.

var irb_bb: i32 = -1;
var irb_pos: i32 = -1;        // insert before this instruction; -1 = at the end of irb_bb
var irb_head: bool = false;   // the iterator has its head bit set (don't adopt debug records)
var irb_dl: i32 = -1;
var irb_prefix: u8[>..];
var irb_prefixed: bool = true;

fn irb_set_before(i: i32) { irb_bb = inst_parent(i); irb_pos = i; irb_head = false; irb_dl = inst_get_md(i, 0); }
fn irb_set_end(bb: i32) { irb_bb = bb; irb_pos = -1; irb_head = false; }
// SetInsertPoint(BB, It) where It may carry the head bit; sets the debug location from It if not end().
fn irb_set_at(bb: i32, it: i32, head: bool) {
    irb_bb = bb; irb_pos = it; irb_head = head;
    if it >= 0 { irb_dl = inst_get_md(it, 0); }
}
fn irb_set_prefix(p: const u8[:]) { irb_prefix.clear(); irb_prefix.append(p); }

// Instruction::insertInto + setName (IRBuilderPrefixedInserter::InsertHelper) + SetInstDebugLocation.
// named = false for a trivially empty Twine (no prefix either).
fn irb_insert(iv: i32, name: const u8[:], named: bool) -> i32 {
    if irb_pos >= 0 {
        if irb_head { inst_insert_before(iv, irb_pos); } else { m2r_insert_before_adopting(iv, irb_pos); }
    } else {
        block_append_inst(irb_bb, iv);
    }
    if named {
        var nm: u8[>..] = [];
        if irb_prefixed { nm.append(irb_prefix); }
        nm.append(name);
        if nm.len > 0 && vals[iv].ty != T_VOID { set_name(iv, nm); }
    }
    if irb_dl >= 0 { inst_set_md(iv, 0, irb_dl); }
    return iv;
}

fn sr_c_i64(v: i64) -> i32 { c_int(T_I64, v) }
fn sr_c_i32(v: i64) -> i32 { c_int(T_I32, v) }

// CreateCast(Op, V, DestTy, Name): no-op if the type already matches; constants fold (ConstantFolder::FoldCast).
fn irb_cast(o: i64, v: i32, dty: i32, name: const u8[:], named: bool) -> i32 {
    if vals[v].ty == dty { return v; }
    if is_constant(v) {
        if is_desirable_cast_op(o) { return ce_cast(o, v, dty); }
        let r = cf_cast(o, v, dty);
        if r >= 0 { return r; }
    }
    let iv = create_inst(o, dty, [v]);
    return irb_insert(iv, name, named);
}
fn irb_bitcast(v: i32, t: i32) -> i32 { irb_cast(OP_BITCAST, v, t, "", false) }

fn irb_binop(o: i64, a: i32, b: i32, name: const u8[:], named: bool) -> i32 {
    if is_constant(a) && is_constant(b) {
        if is_desirable_binop(o) { return ce_binop(o, a, b, 0); }
        let r = cf_binop(o, a, b);
        if r >= 0 { return r; }
    }
    let iv = create_inst(o, vals[a].ty, [a, b]);
    return irb_insert(iv, name, named);
}

// CreateAlignedLoad(Ty, Ptr, Align, isVolatile, Name)
fn irb_load(t: i32, p: i32, align: i64, vol: bool, name: const u8[:], named: bool) -> i32 {
    let iv = create_inst(OP_LOAD, t, [p]);
    sr_set_inst_align(iv, align);
    if vol { insts[inst_of(iv)].bits = 1; }
    return irb_insert(iv, name, named);
}
// CreateAlignedStore(Val, Ptr, Align, isVolatile)
fn irb_store(v: i32, p: i32, align: i64, vol: bool) -> i32 {
    let iv = create_inst(OP_STORE, T_VOID, [v, p]);
    sr_set_inst_align(iv, align);
    if vol { insts[inst_of(iv)].bits = 1; }
    return irb_insert(iv, "", false);
}

// CreateGEP(Ty, Ptr, Indices, Name, NW)
fn irb_gep(srcty: i32, p: i32, idxs: const i32[:], flags: u8, name: const u8[:], named: bool) -> i32 {
    var allc = is_constant(p);
    for x in idxs { if !is_constant(x) { allc = false; } }
    if allc { return ce_gep(srcty, p, idxs, flags, -1); }
    var opsv: i32[>..<] = [];
    opsv.push(p);
    for x in idxs { opsv.push(x); }
    var rt = vals[p].ty;
    for x in idxs { if ty_is_vector(vals[x].ty) { rt = ty_vector(vals[p].ty, types[vals[x].ty].cnt, types[vals[x].ty].kind == TK_SVEC); } }
    if ty_is_vector(vals[p].ty) { rt = vals[p].ty; }
    let iv = create_inst(OP_GEP, rt, opsv);
    insts[inst_of(iv)].ty2 = srcty;
    insts[inst_of(iv)].flags = flags;
    return irb_insert(iv, name, named);
}

fn irb_extractelement(v: i32, idx: i32, name: const u8[:]) -> i32 {
    if is_constant(v) && is_constant(idx) { return ce_extractelement(v, idx); }
    let iv = create_inst(OP_EXTRACTELEMENT, types[vals[v].ty].a, [v, idx]);
    return irb_insert(iv, name, true);
}
fn irb_insertelement(v: i32, e: i32, idx: i32, name: const u8[:]) -> i32 {
    if is_constant(v) && is_constant(e) && is_constant(idx) { return ce_insertelement(v, e, idx); }
    let iv = create_inst(OP_INSERTELEMENT, vals[v].ty, [v, e, idx]);
    return irb_insert(iv, name, true);
}
// CreateShuffleVector(V1, V2, Mask, Name); V2 = -1 means poison (the single-operand form).
fn irb_shuffle(v1: i32, v2in: i32, mask: const i32[:], name: const u8[:], named: bool) -> i32 {
    let v2 = if v2in < 0 { c_poison(vals[v1].ty) } else { v2in };
    if is_constant(v1) && is_constant(v2) { return ce_shufflevector(v1, v2, mask); }
    let rt = ty_vector(types[vals[v1].ty].a, mask.len, false);
    let iv = create_inst(OP_SHUFFLEVECTOR, rt, [v1, v2]);
    let at = ints.len as i32;
    for m in mask { ints.push(m); }
    insts[inst_of(iv)].aux = at;
    insts[inst_of(iv)].naux = mask.len as i32;
    return irb_insert(iv, name, named);
}
fn irb_select(c: i32, a: i32, b: i32, name: const u8[:], mdfrom: i32) -> i32 {
    if is_constant(c) && is_constant(a) && is_constant(b) {
        sr_not_ported("constant-folded select in the IRBuilder");
    }
    let iv = create_inst(OP_SELECT, vals[a].ty, [c, a, b]);
    irb_insert(iv, name, true);
    if mdfrom >= 0 {
        // CreateSelect(..., MDFrom): copy !prof and !unpredictable
        let k1 = md_kind_id("prof");
        let k2 = md_kind_id("unpredictable");
        let p = inst_get_md(mdfrom, k1);
        if p >= 0 { inst_set_md(iv, k1, p); }
        let u = inst_get_md(mdfrom, k2);
        if u >= 0 { inst_set_md(iv, k2, u); }
    }
    return iv;
}
fn irb_extractvalue(agg: i32, idxs: const i32[:], name: const u8[:]) -> i32 {
    if is_constant(agg) { let r = cf_extractvalue(agg, idxs); if r >= 0 { return r; } }
    var t = vals[agg].ty;
    for x in idxs { t = ty_index(t, x as i64); }
    let iv = create_inst(OP_EXTRACTVALUE, t, [agg]);
    let at = ints.len as i32;
    for x in idxs { ints.push(x); }
    insts[inst_of(iv)].aux = at;
    insts[inst_of(iv)].naux = idxs.len as i32;
    return irb_insert(iv, name, true);
}
fn irb_insertvalue(agg: i32, v: i32, idxs: const i32[:], name: const u8[:]) -> i32 {
    if is_constant(agg) && is_constant(v) { sr_not_ported("constant-folded insertvalue in the IRBuilder"); }
    let iv = create_inst(OP_INSERTVALUE, vals[agg].ty, [agg, v]);
    let at = ints.len as i32;
    for x in idxs { ints.push(x); }
    insts[inst_of(iv)].aux = at;
    insts[inst_of(iv)].naux = idxs.len as i32;
    return irb_insert(iv, name, true);
}
fn irb_phi(t: i32, reserve: i64, name: const u8[:]) -> i32 {
    let pn = new_inst(OP_PHI, t, reserve);
    vals[pn].nops = 0;
    return irb_insert(pn, name, true);
}

// DataLayout::getIntPtrType(Ty): integer (or vector of integers) of the pointer size
fn sr_dl_intptr_type(t: i32) -> i32 {
    let it = ty_int(dl_ptr(sr_ptr_as_of(t)).bits);
    if ty_is_vector(t) { return ty_vector(it, types[t].cnt, types[t].kind == TK_SVEC); }
    return it;
}

// IRBuilderBase::CreateBitPreservingCastChain
fn irb_bit_cast_chain(v: i32, nt: i32) -> i32 {
    let ot = vals[v].ty;
    if ot == nt { return v; }
    if types[ot].kind == TK_SVEC || types[nt].kind == TK_SVEC { sr_not_ported("bit-preserving casts of scalable vectors"); }
    if sr_ty_is_int_or_int_vec(ot) && sr_ty_is_ptr_or_ptr_vec(nt) {
        return irb_cast(OP_INTTOPTR, irb_bitcast(v, sr_dl_intptr_type(nt)), nt, "", false);
    }
    if sr_ty_is_ptr_or_ptr_vec(ot) && sr_ty_is_int_or_int_vec(nt) {
        return irb_bitcast(irb_cast(OP_PTRTOINT, v, sr_dl_intptr_type(ot), "", false), nt);
    }
    if sr_ty_is_ptr_or_ptr_vec(ot) && sr_ty_is_ptr_or_ptr_vec(nt) {
        if sr_ptr_as_of(ot) != sr_ptr_as_of(nt) {
            let i1 = irb_cast(OP_PTRTOINT, v, sr_dl_intptr_type(ot), "", false);
            return irb_cast(OP_INTTOPTR, irb_bitcast(i1, sr_dl_intptr_type(nt)), nt, "", false);
        }
    }
    return irb_bitcast(v, nt);
}

// CreatePointerBitCastOrAddrSpaceCast
fn irb_ptr_cast(v: i32, t: i32, name: const u8[:]) -> i32 {
    if vals[v].ty == t { return v; }
    if sr_ptr_as_of(vals[v].ty) != sr_ptr_as_of(t) { return irb_cast(OP_ADDRSPACECAST, v, t, name, true); }
    return irb_cast(OP_BITCAST, v, t, name, true);
}

// getAdjustedPtr(IRB, DL, Ptr, Offset, PointerTy, NamePrefix)
fn sr_adjusted_ptr(p0: i32, offset: i64, ptrty: i32, prefix: const u8[:], w: i64) -> i32 {
    var p = p0;
    var nm: u8[>..] = [];
    if offset != 0 {
        nm.append(prefix); nm.append("sroa_idx");
        p = irb_gep(T_I8, p, [c_int(ty_int(w), offset)], GEP_INBOUNDS | GEP_NUSW, nm, true);
    }
    nm.clear(); nm.append(prefix); nm.append("sroa_cast");
    return irb_ptr_cast(p, ptrty, nm);
}

// Intrinsic call creation (IRBuilder::CreateIntrinsic / CreateCall): declaration via
// Intrinsic::getOrInsertDeclaration, then a call with the given argument attributes.
fn irb_intrinsic_call(id: i64, ov: const i32[:], argsv: const i32[:], pattrs: const i32[:]) -> i32 {
    let f = au_get_declaration(id, ov);
    let fty = globs[glob_of(f)].vty;
    var opsv: i32[>..<] = [];
    for a in argsv { opsv.push(a); }
    opsv.push(f);
    let iv = create_inst(OP_CALL, ty_fn_ret(fty), opsv);
    insts[inst_of(iv)].ty2 = fty;
    if pattrs.len > 0 {
        var sets: i32[>..<] = [];
        sets.push(0); sets.push(0);
        for s in pattrs { sets.push(s); }
        insts[inst_of(iv)].attrs = alist_get(sets);
    }
    return irb_insert(iv, "", false);
}
fn align_attr_set(a: i64) -> i32 { if a <= 0 { 0 } else { aset_get([attr_int(AK_Alignment, a as u64)]) } }

// CreateMemSet(Ptr, Val, Size, Align, isVolatile)
fn irb_memset(p: i32, v: i32, size: i32, align: i64, vol: bool) -> i32 {
    let vc = if vol { c_true() } else { c_false() };
    let aset = align_attr_set(align);
    let t1 = vals[p].ty;
    let t2 = vals[size].ty;
    return irb_intrinsic_call(IID_memset, [t1, t2], [p, v, size, vc], [aset]);
}
// CreateMemCpy(Dst, DstAlign, Src, SrcAlign, Size, isVolatile)
fn irb_memcpy(d: i32, dalign: i64, s: i32, salign: i64, size: i32, vol: bool) -> i32 {
    let vc = if vol { c_true() } else { c_false() };
    let a1 = align_attr_set(dalign);
    let a2 = align_attr_set(salign);
    let t1 = vals[d].ty;
    let t2 = vals[s].ty;
    let t3 = vals[size].ty;
    return irb_intrinsic_call(IID_memcpy, [t1, t2, t3], [d, s, size, vc], [a1, a2]);
}
fn irb_lifetime(start: bool, p: i32) -> i32 {
    return irb_intrinsic_call(if start { IID_lifetime_start } else { IID_lifetime_end }, [vals[p].ty], [p], []);
}

// ---------------------------------------------------------------------------------------------
// Slices (class Slice / AllocaSlices)

struct Slice { b: i64, e: i64, u: i32, split: bool }
var sl: Slice[>..<];
var as_dead_users: i32[>..<];
var as_dead_use_if_prom: i32[>..<];     // use ids
var as_dead_operands: i32[>..<];        // use ids
var as_escaped: i32 = -1;               // PointerEscapingInstr
var as_escaped_ro: i32 = -1;            // PointerEscapingInstrReadOnly

// Slice::operator<
fn slice_less(x: Slice, y: Slice) -> bool {
    if x.b < y.b { return true; }
    if x.b > y.b { return false; }
    if x.split != y.split { return !x.split; }
    if x.e > y.e { return true; }
    return false;
}
fn slices_stable_sort() { stable_sort(sl) { x, y => slice_less(x, y) }; }

// PtrUseVisitor state
var pv_wl_use: i32[>..<];
var pv_wl_known: bool[>..<];
var pv_wl_off: i64[>..<];
var pv_u: i32 = -1;
var pv_known: bool = true;
var pv_off: i64 = 0;
var pv_aborted: i32 = -1;
var pv_escaped: i32 = -1;
var pv_escaped_ro: i32 = -1;
var sb_alloc_size: i64 = 0;

// PtrUseVisitorBase::enqueueUsers
fn pv_enqueue_users(v: i32) {
    var u = first_use(v);
    while u >= 0 {
        if sr_add(S_VUSES, u) {
            pv_wl_use.push(u);
            pv_wl_known.push(pv_known);
            pv_wl_off.push(pv_off);
        }
        u = use_next(u);
    }
}

fn sb_mark_dead(i: i32) { if sr_add(S_VDEAD, i) { as_dead_users.push(i); } }

// SliceBuilder::insertUse
fn sb_insert_use(i: i32, size: i64, splittable: bool) {
    // Offset is unsigned (APInt uge): negative offsets are huge
    if size == 0 || pv_off < 0 || pv_off >= sb_alloc_size { sb_mark_dead(i); return; }
    let b = pv_off;
    var e = b + size;
    if size > sb_alloc_size - b { e = sb_alloc_size; }
    sl.push(Slice { b: b, e: e, u: pv_u, split: splittable });
}

fn sb_load_or_store(t: i32, i: i32, size: i64, vol: bool) {
    let splittable = ty_is_int(t) && !vol && sr_dl_size_eq_store(t);
    sb_insert_use(i, size, splittable);
}

fn sb_visit_load(li: i32) {
    if !pv_known { pv_escaped_ro = li; return; }
    let t = vals[li].ty;
    if sr_ty_is_scalable(t) { sr_not_ported("loads of scalable types"); }
    sb_load_or_store(t, li, dl_store_size(t), inst_is_volatile(li));
}

fn sb_visit_store(si: i32) {
    let v = op(si, 0);
    if v == uses[pv_u].val && sr_use_opno(pv_u) == 0 { pv_escaped = si; pv_aborted = si; return; }
    if !pv_known { pv_aborted = si; return; }
    let t = vals[v].ty;
    if sr_ty_is_scalable(t) { sr_not_ported("stores of scalable types"); }
    let size = dl_store_size(t);
    // Size > AllocSize || Offset.ugt(AllocSize - Size)
    if size > sb_alloc_size || pv_off < 0 || pv_off > sb_alloc_size - size { sb_mark_dead(si); return; }
    sb_load_or_store(t, si, size, inst_is_volatile(si));
}

fn sr_mi_length(ii: i32) -> i32 { op(ii, 2) }
fn sr_mi_is_volatile(ii: i32) -> bool { let v = op(ii, 3); return vals[v].kind == VK_CINT && sr_cint_u64(v) != 0; }
// getLimitedValue(): the value, saturated at UINT64_MAX
fn sr_cint_limited(c: i32) -> i64 {
    if cint_wide_nonzero_hi(c) { return 0x7FFFFFFFFFFFFFFF; }
    let x = sr_cint_u64(c);
    if x > 0x7FFFFFFFFFFFFFFF { return 0x7FFFFFFFFFFFFFFF; }
    return x as! i64;
}
fn sr_cint_is_zero(c: i32) -> bool { return vals[c].kind == VK_CINT && is_null_value(c); }

fn sb_visit_memset(ii: i32) {
    let len = sr_mi_length(ii);
    let is_c = vals[len].kind == VK_CINT;
    if (is_c && sr_cint_is_zero(len)) || (pv_known && (pv_off < 0 || pv_off >= sb_alloc_size)) { sb_mark_dead(ii); return; }
    if !pv_known { pv_aborted = ii; return; }
    let size = if is_c { sr_cint_limited(len) } else { sb_alloc_size - pv_off };
    sb_insert_use(ii, size, is_c);
}

fn sb_visit_memtransfer(ii: i32) {
    let len = sr_mi_length(ii);
    let is_c = vals[len].kind == VK_CINT;
    if is_c && sr_cint_is_zero(len) { sb_mark_dead(ii); return; }
    if sr_has(S_VDEAD, ii) { return; }
    if !pv_known { pv_aborted = ii; return; }
    if pv_off < 0 || pv_off >= sb_alloc_size {
        if sr_has(S_MTMAP, ii) {
            let k = sr_get(S_MTMAP, ii, 0);
            sl[k].u = -1;
        }
        sb_mark_dead(ii);
        return;
    }
    let raw = pv_off;
    let size = if is_c { sr_cint_limited(len) } else { sb_alloc_size - raw };
    let cur = uses[pv_u].val;
    if cur == op(ii, 0) && cur == op(ii, 1) {
        if !sr_mi_is_volatile(ii) { sb_mark_dead(ii); return; }
        sb_insert_use(ii, size, false);
        return;
    }
    let inserted = !sr_has(S_MTMAP, ii);
    if inserted { sr_set(S_MTMAP, ii, sl.len); }
    let prev = sr_get(S_MTMAP, ii, 0);
    if !inserted {
        if !sr_mi_is_volatile(ii) && sl[prev].b == raw {
            sl[prev].u = -1;
            sb_mark_dead(ii);
            return;
        }
        sl[prev].split = false;
    }
    sb_insert_use(ii, size, inserted && is_c);
}

// CallBase::isDataOperand / getCaptureInfo / onlyReadsMemory(OpNo) for a pointer use of a call.
fn sr_cb_param_has(c: i32, k: i64, kind: i64) -> bool {
    if aset_has(alist_param(insts[inst_of(c)].attrs, k), kind) { return true; }
    let f = cb_callee(c);
    if f < 0 || vals[f].kind != VK_FUNC { return false; }
    if !aset_has(alist_param(func_attrs(f), k), kind) { return false; }
    if kind == AK_ReadNone { return !call_has_reading_bundles(c) && !call_has_clobbering_bundles(c); }
    if kind == AK_ReadOnly { return !call_has_clobbering_bundles(c); }
    return true;
}
fn sr_aset_captures(s: i32) -> u64 {
    let a = aset_find(s, AK_Captures);
    if a < 0 { return 15 | (15 << 8); }
    return attrs[a].i1;
}
// SliceBuilder::visitCallBase: true if the use only escapes read-only.
fn sb_call_readonly_use(c: i32, opno: i64) -> bool {
    let nargs = cb_nargs(c);
    let ndata = nargs + cb_bundle_ops(c);
    if opno >= ndata { return false; }      // the callee (or callbr/invoke dests)
    var capt: u64 = 0;
    if opno < nargs {
        if sr_cb_param_has(c, opno, AK_ByVal) { capt = 0; }
        else {
            capt = sr_aset_captures(alist_param(insts[inst_of(c)].attrs, opno));
            let f = cb_callee(c);
            if f >= 0 && vals[f].kind == VK_FUNC { capt = capt & sr_aset_captures(alist_param(func_attrs(f), opno)); }
        }
    } else {
        // bundle operand: assume bundles are captures(none); deopt too; others all
        if call_iid(c) == IID_assume { capt = 0; } else { sr_not_ported("capture info of operand-bundle operands"); }
    }
    let cc = (capt & 15) | ((capt >> 8) & 15);
    if (cc & 12) == 12 { return false; }     // capturesFullProvenance
    if opno < nargs {
        if sr_cb_param_has(c, opno, AK_ByVal) { return true; }
        return sr_cb_param_has(c, opno, AK_ReadOnly) || sr_cb_param_has(c, opno, AK_ReadNone);
    }
    return false;
}

// SliceBuilder::hasUnsafePHIOrSelectUse: -1 if safe (and *size updated), else the unsafe instruction.
fn sb_unsafe_phi_or_select_use(root: i32) -> i32, i64 {
    sr_clear(S_TMP);
    sr_add(S_TMP, root);
    var w_used: i32[>..<] = [];
    var w_inst: i32[>..<] = [];
    w_used.push(uses[pv_u].user); w_inst.push(root);
    var size: i64 = 0;
    while w_inst.len > 0 {
        let used_i = w_used.pop();
        let i = w_inst.pop();
        let o = iop(i);
        if o == OP_LOAD {
            let t = vals[i].ty;
            if sr_ty_is_scalable(t) { pv_aborted = i; return -1, 0; }
            size = max(size, dl_store_size(t));
            continue;
        }
        if o == OP_STORE {
            let v = op(i, 0);
            if v == used_i { return i, size; }
            let t = vals[v].ty;
            if sr_ty_is_scalable(t) { pv_aborted = i; return -1, 0; }
            size = max(size, dl_store_size(t));
            continue;
        }
        if o == OP_GEP {
            if !gep_all_zero_ci(i) { return i, size; }
        } else if o != OP_BITCAST && o != OP_PHI && o != OP_SELECT && o != OP_ADDRSPACECAST {
            return i, size;
        }
        var u = first_use(i);
        while u >= 0 {
            let us = use_user(u);
            if sr_add(S_TMP, us) { w_used.push(i); w_inst.push(us); }
            u = use_next(u);
        }
    }
    return -1, size;
}

// foldPHINodeOrSelectInst
fn fold_phi_or_select(i: i32) -> i32 {
    if iop(i) == OP_PHI { return sr_phi_has_constant_value_or_null(i); }
    let c = op(i, 0);
    if vals[c].kind == VK_CINT && !ty_is_vector(vals[c].ty) { return op(i, if is_null_value(c) { 2 } else { 1 }); }
    if op(i, 1) == op(i, 2) { return op(i, 1); }
    return -1;
}
// PHINode::hasConstantValue (nullptr = -1)
fn sr_phi_has_constant_value_or_null(p: i32) -> i32 {
    var cv = op(p, 0);
    for k in 1..nops(p) {
        let v = op(p, k);
        if v != cv && v != p {
            if cv != p { return -1; }
            cv = v;
        }
    }
    if cv == p { return c_poison(vals[p].ty); }
    return cv;
}

// BasicBlock::hasInsertionPt: the first non-PHI is not a catchswitch... (getFirstInsertionPt != end)
fn sr_block_has_insertion_pt(bb: i32) -> bool {
    let f = first_non_phi(bb);
    if f < 0 { return false; }
    return !inst_is_eh_pad(f) || iop(f) == OP_LANDINGPAD || iop(f) == OP_CATCHPAD || iop(f) == OP_CLEANUPPAD;
}

fn sb_visit_phi_or_select(i: i32) {
    if !has_uses(i) { sb_mark_dead(i); return; }
    if iop(i) == OP_PHI && !sr_block_has_insertion_pt(inst_parent(i)) { pv_aborted = i; return; }
    let r = fold_phi_or_select(i);
    if r >= 0 {
        if r == uses[pv_u].val { pv_enqueue_users(i); } else { as_dead_operands.push(pv_u); }
        return;
    }
    if !pv_known { pv_aborted = i; return; }
    var size = sr_get(S_PHISZ, i, 0);
    if size == 0 {
        let unsafe_i, sz = sb_unsafe_phi_or_select_use(i);
        if pv_aborted >= 0 { return; }
        size = sz;
        sr_set(S_PHISZ, i, size);
        if unsafe_i >= 0 { pv_aborted = unsafe_i; return; }
    }
    if pv_off < 0 || pv_off >= sb_alloc_size { as_dead_operands.push(pv_u); return; }
    sb_insert_use(i, size, false);
}

fn sb_visit(i: i32) {
    let o = iop(i);
    if o == OP_LOAD { sb_visit_load(i); return; }
    if o == OP_STORE { sb_visit_store(i); return; }
    if o == OP_BITCAST || o == OP_ADDRSPACECAST {
        if !has_uses(i) { sb_mark_dead(i); return; }
        pv_enqueue_users(i);
        return;
    }
    if o == OP_GEP {
        if !has_uses(i) { sb_mark_dead(i); return; }
        // adjustOffsetForGEP
        if pv_known {
            let ok, off = sr_gep_const_offset(insts[inst_of(i)].ty2, i, 1);
            if ok { pv_off = pv_off + off; } else { pv_known = false; pv_off = 0; }
        }
        pv_enqueue_users(i);
        return;
    }
    if o == OP_PTRTOINT { pv_escaped = i; return; }
    if o == OP_PHI || o == OP_SELECT { sb_visit_phi_or_select(i); return; }
    if o == OP_CALL && call_iid(i) != 0 {
        let id = call_iid(i);
        if id == IID_memset || id == IID_memset_inline { sb_visit_memset(i); return; }
        if id == IID_memcpy || id == IID_memcpy_inline || id == IID_memmove { sb_visit_memtransfer(i); return; }
        if id == IID_experimental_memset_pattern { sr_not_ported("llvm.experimental.memset.pattern users"); }
        // SliceBuilder::visitIntrinsicInst
        if id == IID_assume || id == IID_pseudoprobe { as_dead_use_if_prom.push(pv_u); return; }
        if !pv_known { pv_aborted = i; return; }
        if id == IID_lifetime_start || id == IID_lifetime_end { sb_insert_use(i, sb_alloc_size, true); return; }
        if id == IID_fake_use { pv_escaped = i; return; }
        // fall through to visitCallBase
    }
    if o == OP_CALL || o == OP_INVOKE || o == OP_CALLBR {
        if sb_call_readonly_use(i, sr_use_opno(pv_u)) { pv_escaped_ro = i; return; }
        pv_escaped = i;
        pv_aborted = i;     // InstVisitor::visitCallBase -> visitInstruction -> setAborted
        return;
    }
    pv_aborted = i;
}

// AllocaSlices::AllocaSlices(DL, AI)
fn build_slices(ai: i32) {
    sl.clear(); as_dead_users.clear(); as_dead_use_if_prom.clear(); as_dead_operands.clear();
    as_escaped = -1; as_escaped_ro = -1;
    sr_clear(S_VUSES); sr_clear(S_VDEAD); sr_clear(S_MTMAP); sr_clear(S_PHISZ);
    sb_alloc_size = sr_alloca_alloc_size(ai);
    pv_wl_use.clear(); pv_wl_known.clear(); pv_wl_off.clear();
    pv_known = true; pv_off = 0;
    pv_aborted = -1; pv_escaped = -1; pv_escaped_ro = -1;
    pv_enqueue_users(ai);
    while pv_wl_use.len > 0 {
        pv_u = pv_wl_use.pop();
        pv_known = pv_wl_known.pop();
        let off = pv_wl_off.pop();
        if pv_known { pv_off = off; }
        sb_visit(uses[pv_u].user);
        if pv_aborted >= 0 { break; }
    }
    if pv_escaped >= 0 || pv_aborted >= 0 {
        as_escaped = if pv_escaped >= 0 { pv_escaped } else { pv_aborted };
        return;
    }
    as_escaped_ro = pv_escaped_ro;
    retain(sl) { s => s.u >= 0 };
    slices_stable_sort();
}

// ---------------------------------------------------------------------------------------------
// Partitions (AllocaSlices::partition_iterator), materialized up front: the slices don't change while
// the partitions of one walk are used.

struct Part { b: i64, e: i64, si: i64, sj: i64, tails: i32, ntails: i32 }
var parts: Part[>..<];
var part_tails: i64[>..<];      // slice indices

fn compute_partitions() {
    parts.clear(); part_tails.clear();
    let se = sl.len;
    if se == 0 { return; }
    var tails: i64[>..<] = [];
    var max_split_end: i64 = 0;
    var pb: i64 = 0;
    var pe: i64 = 0;
    var si: i64 = 0;
    var sj: i64 = 0;
    fn emit() {
        let at = part_tails.len as i32;
        for t in tails { part_tails.push(t); }
        parts.push(Part { b: pb, e: pe, si: si, sj: sj, tails: at, ntails: tails.len as i32 });
    }
    // advance(): returns false at the end
    fn advance() -> bool {
        if tails.len > 0 {
            if pe >= max_split_end { tails.clear(); max_split_end = 0; }
            else { retain(tails) { t => sl[t].e > pe }; }
        }
        if si == se { return false; }
        if si != sj {
            for k in si..sj {
                if sl[k].split && sl[k].e > pe { tails.push(k); max_split_end = max(sl[k].e, max_split_end); }
            }
            si = sj;
            if si == se { pb = pe; pe = max_split_end; return true; }
            if tails.len > 0 && sl[si].b != pe && !sl[si].split { pb = pe; pe = sl[si].b; return true; }
        }
        pb = if tails.len == 0 { sl[si].b } else { pe };
        pe = sl[si].e;
        sj++;
        if !sl[si].split {
            while sj != se && sl[sj].b < pe {
                if !sl[sj].split { pe = max(pe, sl[sj].e); }
                sj++;
            }
            return true;
        }
        while sj != se && sl[sj].b < pe && sl[sj].split { pe = max(pe, sl[sj].e); sj++; }
        if sj != se && sl[sj].b < pe { pe = sl[sj].b; }
        return true;
    }
    // operator== against the end iterator: SI == SE and no split tails.
    loop {
        if !advance() { break; }
        if si == se && tails.len == 0 { break; }
        emit();
    }
}

// ---------------------------------------------------------------------------------------------
// Partition type selection

fn sr_slice_user(k: i64) -> i32 { uses[sl[k].u].user }
fn sr_is_mem_intrinsic(i: i32) -> bool {
    if !is_inst(i) || iop(i) != OP_CALL { return false; }
    let id = call_iid(i);
    return id == IID_memset || id == IID_memset_inline || id == IID_memcpy || id == IID_memcpy_inline || id == IID_memmove;
}
fn sr_is_droppable_inst(i: i32) -> bool { m2r_is_droppable(i) }
fn sr_is_lifetime(i: i32) -> bool { is_inst(i) && iop(i) == OP_CALL && inst_is_lifetime_start_or_end(i) }

// findCommonType(B, E, EndOffset): (common type or -1, largest integer type or -1)
fn find_common_type(bi: i64, ei: i64, end_off: i64) -> i32, i32 {
    var t: i32 = -1;
    var common = true;
    var ity: i32 = -1;
    if bi == ei { return -1, -1; }
    let b0 = sl[bi].b;
    for k in bi..ei {
        let u = sr_slice_user(k);
        if is_intrinsic_inst(u) { continue; }
        if sl[k].b != b0 || sl[k].e != end_off { continue; }
        var ut: i32 = -1;
        if iop(u) == OP_LOAD { ut = vals[u].ty; }
        else if iop(u) == OP_STORE { ut = vals[op(u, 0)].ty; }
        if ut >= 0 && ty_is_int(ut) {
            let w = ty_bits(ut);
            if w % 8 != 0 || w / 8 > end_off - b0 { continue; }
            if ity < 0 || ty_bits(ity) < w { ity = ut; }
        }
        if ut < 0 || (t >= 0 && t != ut) { common = false; } else { t = ut; }
    }
    return if common { t } else { -1 }, ity;
}

// canConvertValue(DL, OldTy, NewTy)
fn can_convert_value(ot0: i32, nt0: i32) -> bool {
    if ot0 == nt0 { return true; }
    if ty_is_int(ot0) && ty_is_int(nt0) { return false; }
    if types[ot0].kind == TK_SVEC || types[nt0].kind == TK_SVEC {
        if (types[ot0].kind == TK_SVEC) != (types[nt0].kind == TK_SVEC) &&
           (sr_ty_is_fixed_vector(ot0) || sr_ty_is_fixed_vector(nt0)) {
            sr_not_ported("canConvertValue between fixed and scalable vectors");
        }
        sr_not_ported("canConvertValue of scalable vectors");
    }
    if !sr_ty_is_single_value(nt0) || !sr_ty_is_single_value(ot0) {
        // sizes are compared first in LLVM; unsized types never get here
        if dl_size_bits(nt0) != dl_size_bits(ot0) { return false; }
        return false;
    }
    if dl_size_bits(nt0) != dl_size_bits(ot0) { return false; }
    let ot = ty_scalar(ot0);
    let nt = ty_scalar(nt0);
    if sr_ty_is_ptr(nt) || sr_ty_is_ptr(ot) {
        if sr_ty_is_ptr(nt) && sr_ty_is_ptr(ot) {
            let oa = sr_ptr_as_of(ot);
            let na = sr_ptr_as_of(nt);
            return oa == na || (!dl_is_nonintegral_as(oa) && !dl_is_nonintegral_as(na) && dl_ptr(oa).bits == dl_ptr(na).bits);
        }
        if ty_is_int(ot) { return !dl_is_nonintegral_as(sr_ptr_as_of(nt)); }
        if !dl_is_nonintegral_as(sr_ptr_as_of(ot)) { return ty_is_int(nt); }
        return false;
    }
    if types[ot].kind == TK_TARGETEXT || types[nt].kind == TK_TARGETEXT { return false; }
    return true;
}

fn part_slices_each<F>(pi: i64) {
    let p = parts[pi];
    for k in p.si..p.sj { F(k); }
}

// isVectorPromotionViableForSlice
fn vec_viable_for_slice(pi: i64, k: i64, vty: i32, esize: i64) -> bool {
    let p = parts[pi];
    let s = sl[k];
    let bo = max(s.b, p.b) - p.b;
    let bidx = bo / esize;
    let nel = types[vty].cnt;
    if bidx * esize != bo || bidx >= nel { return false; }
    let eo = min(s.e, p.e) - p.b;
    let eidx = eo / esize;
    if eidx * esize != eo || eidx > nel { return false; }
    let n = eidx - bidx;
    let ety = types[vty].a;
    let slice_ty = if n == 1 { ety } else { ty_vector(ety, n, false) };
    let split_int = ty_int(n * esize * 8);
    let u = uses[s.u].user;
    if sr_is_mem_intrinsic(u) {
        if sr_mi_is_volatile(u) { return false; }
        if !s.split { return false; }
    } else if is_intrinsic_inst(u) {
        if !inst_is_lifetime_start_or_end(u) && !sr_is_droppable_inst(u) { return false; }
    } else if iop(u) == OP_LOAD {
        if inst_is_volatile(u) { return false; }
        var lt = vals[u].ty;
        if ty_is_struct(lt) { return false; }
        if p.b > s.b || p.e < s.e { lt = split_int; }
        if !can_convert_value(slice_ty, lt) { return false; }
    } else if iop(u) == OP_STORE {
        if inst_is_volatile(u) { return false; }
        var st = vals[op(u, 0)].ty;
        if ty_is_struct(st) { return false; }
        if p.b > s.b || p.e < s.e { st = split_int; }
        if !can_convert_value(st, slice_ty) { return false; }
    } else {
        return false;
    }
    return true;
}

// state of isVectorPromotionViable's CheckCandidateType closure
var vp_cands: i32[>..<];
var vp_common_elt: i32 = -1;
var vp_common_vecptr: i32 = -1;
var vp_have_vecptr: bool = false;
var vp_have_common_elt: bool = true;
var vp_have_common_vecptr: bool = true;

fn vp_check_candidate(t: i32) {
    if !sr_ty_is_fixed_vector(t) { return; }
    if vp_cands.len > 0 {
        if dl_size_bits(t) != dl_size_bits(vp_cands[0]) { vp_cands.clear(); return; }
    }
    vp_cands.push(t);
    let et = types[t].a;
    if vp_common_elt < 0 { vp_common_elt = et; } else if vp_common_elt != et { vp_have_common_elt = false; }
    if sr_ty_is_ptr(et) {
        vp_have_vecptr = true;
        if vp_common_vecptr < 0 { vp_common_vecptr = t; } else if vp_common_vecptr != t { vp_have_common_vecptr = false; }
    }
}

// checkVectorTypesForPromotion
fn vp_check_types(pi: i64) -> i32 {
    if vp_cands.len == 0 { return -1; }
    if vp_have_vecptr && !vp_have_common_vecptr { return -1; }
    if !vp_have_common_elt && vp_have_vecptr {
        vp_cands.clear();
        vp_cands.push(vp_common_vecptr);
    } else if !vp_have_common_elt && !vp_have_vecptr {
        for &v in vp_cands {
            if !ty_is_int(types[v].a) { v = ty_vector(ty_int(dl_size_bits(types[v].a)), types[v].cnt, false); }
        }
        // llvm::sort by ascending element count, then unique by element count (std::sort: equal-count
        // types are interchangeable here: same size and integer elements means the same type)
        sort(vp_cands) { a, b => types[a].cnt < types[b].cnt };
        var w: i64 = 0;
        for k in vp_cands.len {
            if w > 0 && types[vp_cands[w - 1]].cnt == types[vp_cands[k]].cnt { continue; }
            vp_cands[w] = vp_cands[k];
            w++;
        }
        vp_cands.resize(w);
    } else {
        vp_cands.resize(1);
    }
    retain(vp_cands) { v => types[v].cnt <= 65535 };
    for vty in vp_cands {
        var es = dl_size_bits(types[vty].a);
        if es % 8 != 0 { continue; }
        es = es / 8;
        var ok = true;
        let p = parts[pi];
        for k in p.si..p.sj { if ok && !vec_viable_for_slice(pi, k, vty, es) { ok = false; } }
        for t in p.tails..p.tails + p.ntails { if ok && !vec_viable_for_slice(pi, part_tails[t], vty, es) { ok = false; } }
        if ok { return vty; }
    }
    return -1;
}

// TypeSize-valid element types (VectorType::isValidElementType)
fn ty_valid_vector_elt(t: i32) -> bool {
    let k = types[t].kind;
    return k == TK_INT || ty_is_fp(t) || k == TK_PTR;
}

// createAndCheckVectorTypesForPromotion
fn vp_create_and_check(pi: i64, others: const i32[:], copy: const i32[:]) -> i32 {
    for t in others {
        if !ty_valid_vector_elt(t) { continue; }
        let tsz = dl_size_bits(t);
        for vty in copy {
            let vsz = dl_size_bits(vty);
            let esz = dl_size_bits(types[vty].a);
            if tsz != vsz && tsz != esz && vsz % tsz == 0 {
                vp_check_candidate(ty_vector(t, vsz / tsz, false));
            }
        }
    }
    return vp_check_types(pi);
}

// isVectorPromotionViable(P, DL, VScale)
fn vector_promotion_viable(pi: i64) -> i32 {
    vp_cands.clear();
    vp_common_elt = -1; vp_common_vecptr = -1;
    vp_have_vecptr = false; vp_have_common_elt = true; vp_have_common_vecptr = true;
    var ls_tys: i32[>..<] = [];       // SetVector
    var deferred: i32[>..<] = [];
    let p = parts[pi];
    for k in p.si..p.sj {
        let u = sr_slice_user(k);
        var t: i32 = -1;
        if iop(u) == OP_LOAD { t = vals[u].ty; }
        else if iop(u) == OP_STORE { t = vals[op(u, 0)].ty; }
        else { continue; }
        let ct = ty_scalar(t);
        if sr_ty_is_ptr(ct) && (sl[k].b != p.b || sl[k].e != p.e) {
            if !contains(deferred, t) { deferred.push(t); }
            continue;
        }
        if !contains(ls_tys, t) { ls_tys.push(t); }
        if sl[k].b == p.b && sl[k].e == p.e { vp_check_candidate(t); }
    }
    var copy: i32[>..<] = [];
    for c in vp_cands { copy.push(c); }
    let r = vp_create_and_check(pi, ls_tys, copy);
    if r >= 0 { return r; }
    vp_cands.clear();
    return vp_create_and_check(pi, deferred, copy);
}

// isIntegerWideningViableForSlice; whole = WholeAllocaOp (in/out)
fn int_widen_viable_for_slice(k: i64, alloc_begin: i64, aty: i32, whole: bool) -> bool, bool {
    var w = whole;
    let size = dl_store_size(aty);
    let s = sl[k];
    let rb = s.b - alloc_begin;
    let re = s.e - alloc_begin;
    let u = uses[s.u].user;
    if is_intrinsic_inst(u) && (inst_is_lifetime_start_or_end(u) || sr_is_droppable_inst(u)) { return true, w; }
    if re > size { return false, w; }
    if iop(u) == OP_LOAD {
        if inst_is_volatile(u) { return false, w; }
        let lt = vals[u].ty;
        if sr_ty_is_scalable(lt) || dl_store_size(lt) > size { return false, w; }
        if s.b < alloc_begin { return false, w; }
        if !ty_is_vector(lt) && rb == 0 && re == size { w = true; }
        if ty_is_int(lt) {
            if ty_bits(lt) < dl_store_size(lt) * 8 { return false, w; }
        } else if rb != 0 || re != size || !can_convert_value(aty, lt) {
            return false, w;
        }
    } else if iop(u) == OP_STORE {
        let vt = vals[op(u, 0)].ty;
        if inst_is_volatile(u) { return false, w; }
        if sr_ty_is_scalable(vt) || dl_store_size(vt) > size { return false, w; }
        if s.b < alloc_begin { return false, w; }
        if !ty_is_vector(vt) && rb == 0 && re == size { w = true; }
        if ty_is_int(vt) {
            if ty_bits(vt) < dl_store_size(vt) * 8 { return false, w; }
        } else if rb != 0 || re != size || !can_convert_value(vt, aty) {
            return false, w;
        }
    } else if sr_is_mem_intrinsic(u) {
        if sr_mi_is_volatile(u) || !is_constant(sr_mi_length(u)) { return false, w; }
        if !s.split { return false, w; }
    } else {
        return false, w;
    }
    return true, w;
}

// isIntegerWideningViable(P, AllocaTy, DL)
fn int_widening_viable(pi: i64, aty: i32) -> bool {
    let bits = dl_size_bits(aty);
    if bits > 8388608 { return false; }       // IntegerType::MAX_INT_BITS
    if bits != dl_store_size(aty) * 8 { return false; }
    let ity = ty_int(bits);
    if !can_convert_value(aty, ity) || !can_convert_value(ity, aty) { return false; }
    let p = parts[pi];
    var whole = p.si == p.sj && dl_is_legal_integer(bits);
    for k in p.si..p.sj {
        let ok, w = int_widen_viable_for_slice(k, p.b, aty, whole);
        whole = w;
        if !ok { return false; }
    }
    for t in p.tails..p.tails + p.ntails {
        let ok, w = int_widen_viable_for_slice(part_tails[t], p.b, aty, whole);
        whole = w;
        if !ok { return false; }
    }
    return whole;
}

// StructLayout::getElementContainingOffset
fn sr_struct_elem_containing(t: i32, off: i64) -> i64 {
    // the last element whose offset is <= off (upper_bound - 1)
    var r: i64 = 0;
    for i in types[t].cnt { if dl_struct_offset(t, i) <= off { r = i; } else { break; } }
    return r;
}

// stripAggregateTypeWrapping
recursive fn strip_aggregate_wrapping(t: i32) -> i32 {
    if sr_ty_is_single_value(t) { return t; }
    let asz = dl_alloc_size(t);
    let tsz = dl_size_bits(t);
    var inner: i32 = -1;
    if ty_is_array(t) { inner = types[t].a; }
    else if ty_is_struct(t) {
        if types[t].cnt == 0 { return t; }
        inner = ty_field(t, sr_struct_elem_containing(t, 0));
    } else { return t; }
    if asz > dl_alloc_size(inner) || tsz > dl_size_bits(inner) { return t; }
    return strip_aggregate_wrapping(inner);
}

// getTypePartition(DL, Ty, Offset, Size): -1 = nullptr
recursive fn type_partition(t: i32, off0: i64, size: i64) -> i32 {
    var off = off0;
    if sr_ty_is_scalable(t) { sr_not_ported("getTypePartition of a scalable type"); }
    let asz = dl_alloc_size(t);
    if off == 0 && asz == size { return strip_aggregate_wrapping(t); }
    if off > asz || asz - off < size { return -1; }
    if ty_is_array(t) || ty_is_vector(t) {
        let et = types[t].a;
        let n = types[t].cnt;
        let es = dl_alloc_size(et);
        let skipped = off / es;
        if skipped >= n { return -1; }
        off -= skipped * es;
        if off > 0 || size < es {
            if off + size > es { return -1; }
            return type_partition(et, off, size);
        }
        if size == es { return strip_aggregate_wrapping(et); }
        let ne = size / es;
        if ne * es != size { return -1; }
        return ty_array(et, ne);
    }
    if !ty_is_struct(t) { return -1; }
    let ssz = dl_struct_size(t);
    if off >= ssz { return -1; }
    let eoff = off + size;
    if eoff > ssz { return -1; }
    let idx = sr_struct_elem_containing(t, off);
    off -= dl_struct_offset(t, idx);
    let et = ty_field(t, idx);
    let es = dl_alloc_size(et);
    if off >= es { return -1; }
    if off > 0 || size < es {
        if off + size > es { return -1; }
        return type_partition(et, off, size);
    }
    if size == es { return strip_aggregate_wrapping(et); }
    var end_idx = types[t].cnt;
    if eoff < ssz {
        let ei = sr_struct_elem_containing(t, eoff);
        if idx == ei { return -1; }
        if dl_struct_offset(t, ei) != eoff { return -1; }
        end_idx = ei;
    }
    let at = ints.len as i32;
    for i in idx..end_idx { ints.push(ty_field(t, i)); }
    let sub = ty_struct_run(at, end_idx - idx, (types[t].flags & TF_PACKED) != 0);
    if size != dl_struct_size(sub) { return -1; }
    return sub;
}

// tryCanonicalizeStructToVector
fn struct_to_vector(sty: i32, pi: i64) -> i32 {
    let n = types[sty].cnt;
    let et = ty_field(sty, 0);
    for i in n { if ty_field(sty, i) != et { return -1; } }
    let int_ptr = sr_ty_is_ptr(et) && !dl_is_nonintegral_as(sr_ptr_as_of(et));
    if !ty_is_int(et) && !ty_is_fp(et) && !int_ptr { return -1; }
    if dl_size_bits(et) != dl_alloc_size(et) * 8 { return -1; }
    let vty = ty_vector(et, n, false);
    if dl_struct_size(sty) != dl_store_size(vty) { return -1; }
    let p = parts[pi];
    fn ok_slice(k: i64) -> bool {
        if sl[k].u < 0 { return true; }
        let u = uses[sl[k].u].user;
        if sr_is_lifetime(u) { return true; }
        return sr_is_mem_intrinsic(u);
    }
    for k in p.si..p.sj { if !ok_slice(k) { return -1; } }
    for t in p.tails..p.tails + p.ntails { if !ok_slice(part_tails[t]) { return -1; } }
    return vty;
}

// selectPartitionType: (type, integer widening, vector type or -1)
fn select_partition_type(pi: i64, ai: i32, agg_to_vec: bool) -> i32, bool, i32 {
    let p = parts[pi];
    let psize = p.e - p.b;
    let vty = vector_promotion_viable(pi);
    if vty >= 0 && ty_is_fp(types[vty].a) && types[vty].cnt > 1 { return vty, false, vty; }
    let cty, lity = find_common_type(p.si, p.sj, p.e);
    if cty >= 0 {
        if !sr_ty_is_scalable(cty) && dl_alloc_size(cty) >= psize {
            if vty >= 0 { return vty, false, vty; }
            return cty, int_widening_viable(pi, cty), -1;
        }
    }
    var tpt = type_partition(sr_alloca_ty(ai), p.b, psize);
    if tpt >= 0 {
        if ty_is_array(tpt) && ty_is_int(types[tpt].a) && dl_is_legal_integer(psize * 8) { tpt = ty_int(psize * 8); }
        if int_widening_viable(pi, tpt) { return tpt, true, -1; }
        if vty >= 0 { return vty, false, vty; }
        if lity >= 0 && dl_alloc_size(lity) >= psize && int_widening_viable(pi, lity) { return lity, true, -1; }
        if agg_to_vec && ty_is_struct(tpt) {
            let v = struct_to_vector(tpt, pi);
            if v >= 0 { return v, false, -1; }
        }
        return tpt, false, -1;
    }
    if lity >= 0 && dl_alloc_size(lity) >= psize { return lity, false, -1; }
    if dl_is_legal_integer(psize * 8) { return ty_int(psize * 8), false, -1; }
    return ty_array(T_I8, psize), false, -1;
}

// ---------------------------------------------------------------------------------------------
// Metadata helpers: AAMDNodes (tbaa, tbaa.struct, alias.scope, noalias, noalias.addrspace)

struct AAT { tbaa: i32, ts: i32, scope: i32, na: i32, naas: i32 }
fn aa_none() -> AAT { AAT { tbaa: -1, ts: -1, scope: -1, na: -1, naas: -1 } }
fn aa_any(a: AAT) -> bool { a.tbaa >= 0 || a.ts >= 0 || a.scope >= 0 || a.na >= 0 || a.naas >= 0 }
fn aa_get(i: i32) -> AAT {
    return AAT { tbaa: inst_get_md(i, md_kind_id("tbaa")), ts: inst_get_md(i, md_kind_id("tbaa.struct")),
        scope: inst_get_md(i, md_kind_id("alias.scope")), na: inst_get_md(i, md_kind_id("noalias")),
        naas: inst_get_md(i, md_kind_id("noalias.addrspace")) };
}
fn sr_md_set_or_erase(i: i32, kind: i32, m: i32) { if m < 0 { inst_erase_md(i, kind); } else { inst_set_md(i, kind, m); } }
fn aa_set(i: i32, a: AAT) {
    sr_md_set_or_erase(i, md_kind_id("tbaa"), a.tbaa);
    sr_md_set_or_erase(i, md_kind_id("tbaa.struct"), a.ts);
    sr_md_set_or_erase(i, md_kind_id("alias.scope"), a.scope);
    sr_md_set_or_erase(i, md_kind_id("noalias"), a.na);
    sr_md_set_or_erase(i, md_kind_id("noalias.addrspace"), a.naas);
}
fn sr_mdconst_int(m: i32) -> i32 {
    if m < 0 || mds[m].kind != MK_VALUE { return -1; }
    let v = mds[m].extra;
    if vals[v].kind != VK_CINT { return -1; }
    return v;
}
// AAMDNodes::shiftTBAAStruct
fn shift_tbaa_struct(m: i32, off: i64) -> i32 {
    if off == 0 { return m; }
    var sub: i32[>..<] = [];
    var i: i64 = 0;
    let n = mds[m].nops as i64;
    while i + 2 < n + 0 || i < n {
        if i + 2 >= n { break; }
        let io = sr_mdconst_int(md_op(m, i));
        let isz = sr_mdconst_int(md_op(m, i + 1));
        if io < 0 || isz < 0 { fatal("SROA: malformed tbaa.struct"); }
        let ov = sr_cint_u64(io) as! i64;
        let sv = sr_cint_u64(isz) as! i64;
        if ov + sv <= off { i += 3; continue; }
        var nsz = sv;
        var noff = ov - off;
        if ov < off { noff = 0; nsz -= off - ov; }
        sub.push(md_value(c_int(vals[io].ty, noff)));
        sub.push(md_value(c_int(vals[isz].ty, nsz)));
        sub.push(md_op(m, i + 2));
        i += 3;
    }
    return md_get(MK_TUPLE, -1, sub, false);
}
fn aa_shift(a0: AAT, off: i64) -> AAT {
    var a = a0;
    if a.ts >= 0 { a.ts = shift_tbaa_struct(a.ts, off); }
    return a;
}
// AAMDNodes::adjustForAccess(unsigned AccessSize)
fn aa_adjust_size(a0: AAT, size: i64) -> AAT {
    var a = a0;
    let m = a.ts;
    if a.tbaa < 0 && m >= 0 && mds[m].nops >= 3 {
        let o0 = sr_mdconst_int(md_op(m, 0));
        let o1 = sr_mdconst_int(md_op(m, 1));
        let o2 = md_op(m, 2);
        if o0 >= 0 && is_null_value(o0) && o1 >= 0 && (sr_cint_u64(o1) as! i64) == size && o2 >= 0 && md_is_node(o2) {
            a.tbaa = o2;
        }
    }
    a.ts = -1;
    return a;
}
// adjustForAccess(Offset, AccessTy, DL)
fn aa_adjust(a: AAT, off: i64, ty: i32) -> AAT {
    let n = aa_shift(a, off);
    if !sr_dl_size_eq_store(ty) { return n; }
    if sr_ty_is_scalable(ty) { return n; }
    return aa_adjust_size(n, dl_store_size(ty));
}
fn aa_adjust_n(a: AAT, off: i64, size: i64) -> AAT { return aa_adjust_size(aa_shift(a, off), size); }

// Instruction::copyMetadata(Src, {mem_parallel_loop_access, access_group[, DIAssignID]})
fn copy_loop_md(dst: i32, src: i32) {
    let k1 = md_kind_id("llvm.mem.parallel_loop_access");
    let k2 = md_kind_id("llvm.access.group");
    let a = inst_get_md(src, k1);
    if a >= 0 { inst_set_md(dst, k1, a); }
    let b = inst_get_md(src, k2);
    if b >= 0 { inst_set_md(dst, k2, b); }
}

// copyMetadataForLoad(Dest, Source)
fn copy_metadata_for_load(dst: i32, src: i32) {
    let si = inst_of(src);
    let nt = vals[dst].ty;
    let direct: const u8[:][] = ["dbg", "tbaa", "prof", "fpmath", "tbaa.struct", "invariant.load", "alias.scope", "noalias",
        "nontemporal", "mem.cache_hint", "llvm.mem.parallel_loop_access", "llvm.access.group", "noundef",
        "noalias.addrspace", "invariant.group"];
    // getAllMetadata: !dbg first, then the others by kind id (our attachments are kept sorted by kind)
    for k in insts[si].nmd {
        let kind = md_att[insts[si].md + 2 * k];
        let node = md_att[insts[si].md + 2 * k + 1];
        let nm = sbytes(md_kind_names[kind]);
        var is_direct = false;
        for d in direct { if d == nm { is_direct = true; } }
        if is_direct { inst_set_md(dst, kind, node); continue; }
        if nm == "nonnull" {
            if sr_ty_is_ptr(nt) { inst_set_md(dst, kind, node); }
            else if ty_is_int(nt) { sr_not_ported("copyNonnullMetadata to an integer load (!range)"); }
            continue;
        }
        if nm == "align" || nm == "dereferenceable" || nm == "dereferenceable_or_null" {
            if sr_ty_is_ptr(nt) { inst_set_md(dst, kind, node); }
            continue;
        }
        if nm == "range" {
            if nt == vals[src].ty { inst_set_md(dst, kind, node); }
            else if sr_ty_is_ptr(nt) { sr_not_ported("copyRangeMetadata to a pointer load"); }
            continue;
        }
        if nm == "nofpclass" {
            if ty_scalar(nt) == ty_scalar(vals[src].ty) { inst_set_md(dst, kind, node); }
            continue;
        }
    }
}

// Call-site parameter alignment (MemIntrinsic::setDestAlignment / setSourceAlignment, getDestAlign).
fn sr_call_param_align(ci: i32, k: i64) -> i64 {
    let s = alist_param(insts[inst_of(ci)].attrs, k);
    let a = aset_find(s, AK_Alignment);
    if a < 0 { return 0; }
    return attrs[a].i1 as! i64;
}
fn sr_call_set_param_align(ci: i32, k: i64, al: i64) {
    let ii = inst_of(ci);
    let l = insts[ii].attrs;
    var sets: i32[>..<] = [];
    let n = alists[l].n as i64;
    for j in max(n, k + 3) { sets.push(if j < n { alist_runs[alists[l].at + j] } else { 0 }); }
    let old = sets[k + 2];
    var xs: i32[>..<] = [];
    for j in aset_n(old) { let a = aset_attr(old, j); if attrs[a].kind as i64 != AK_Alignment { xs.push(a); } }
    xs.push(attr_int(AK_Alignment, al as u64));
    sets[k + 2] = aset_get(xs);
    insts[ii].attrs = alist_get(sets);
}

// Instruction::comesBefore (same block)
fn sr_comes_before(a: i32, b: i32) -> bool {
    var x = inst_next(a);
    while x >= 0 { if x == b { return true; } x = inst_next(x); }
    return false;
}

// ---------------------------------------------------------------------------------------------
// The pass state (class SROA)

var sroa_preserve_cfg: bool = true;
var sroa_agg_to_vec: bool = false;
var sr_wl: i32[>..<];          // Worklist (SmallSetVector; membership S_WL)
var sr_ppwl: i32[>..<];        // PostPromotionWorklist (S_PPWL)
var sr_prom: i32[>..<];        // PromotableAllocas (S_PROM)
var sr_sphis: i32[>..<];       // SpeculatablePHIs (S_SPHI)
var sr_sels: i32[>..<];        // SelectsToRewrite keys, with ops runs
var sr_sel_at: i32[>..<];
var sr_sel_n: i32[>..<];
var sr_sel_ops: i32[>..<];     // pairs (inst, spec) ; spec = -1 for an unspeculatable store
var sr_dead: i32[>..<];        // DeadInsts (WeakVH: erased ids are skipped)

fn setvec_insert(xs: i32[>..<]&, s: i64, v: i32) { if sr_add(s, v) { xs.push(v); } }
fn setvec_pop(xs: i32[>..<]&, s: i64) -> i32 { let v = xs.pop(); sr_del(s, v); return v; }

// ---------------------------------------------------------------------------------------------
// AllocaSliceRewriter

var rw_old_ai: i32 = -1;
var rw_new_ai: i32 = -1;
var rw_nab: i64 = 0;
var rw_nae: i64 = 0;
var rw_new_ty: i32 = -1;
var rw_int_ty: i32 = -1;
var rw_vec_ty: i32 = -1;
var rw_elem_ty: i32 = -1;
var rw_elem_size: i64 = 0;
var rw_bo: i64 = 0;
var rw_eo: i64 = 0;
var rw_nbo: i64 = 0;
var rw_neo: i64 = 0;
var rw_slice_size: i64 = 0;
var rw_splittable: bool = false;
var rw_is_split: bool = false;
var rw_old_use: i32 = -1;
var rw_old_ptr: i32 = -1;
var rw_phi_users: i32[>..<];   // SmallSetVector (S_PHIU)
var rw_sel_users: i32[>..<];   // SmallSetVector (S_SELU)

fn rw_init(old_ai: i32, new_ai: i32, nty: i32, nab: i64, nae: i64, int_prom: bool, vty: i32) {
    rw_old_ai = old_ai; rw_new_ai = new_ai; rw_new_ty = nty; rw_nab = nab; rw_nae = nae;
    rw_int_ty = if int_prom { ty_int(dl_size_bits(nty)) } else { -1 };
    rw_vec_ty = vty;
    rw_elem_ty = if vty >= 0 { types[vty].a } else { -1 };
    rw_elem_size = if vty >= 0 { dl_size_bits(rw_elem_ty) / 8 } else { 0 };
    rw_bo = 0; rw_eo = 0; rw_nbo = 0; rw_neo = 0; rw_slice_size = 0;
    rw_phi_users.clear(); rw_sel_users.clear();
    sr_clear(S_PHIU); sr_clear(S_SELU);
    irb_prefix.clear();
    irb_prefixed = true;
}

fn new_ai_align() -> i64 { sr_inst_align(rw_new_ai) }
fn slice_align() -> i64 { sr_commonalign(new_ai_align(), ((rw_nbo as! u64) - (rw_nab as! u64))) }
fn rw_index(off: i64) -> i64 { (off - rw_nab) / rw_elem_size }

fn rw_ptr_to_new_ai(as_: i64, vol: bool) -> i32 {
    if !vol || as_ == sr_alloca_as(rw_new_ai) { return rw_new_ai; }
    return irb_cast(OP_ADDRSPACECAST, rw_new_ai, ty_ptr(as_), "", false);
}

fn rw_delete_if_trivially_dead(v: i32) {
    if is_instruction_trivially_dead(v) { sr_dead.push(v); }
}

fn sr_find_first_not_digit(s: const u8[:], from: i64) -> i64 {
    for i in from..s.len { if s[i] < '0' || s[i] > '9' { return i; } }
    return -1;
}

// getNewAllocaSlicePtr(IRB, PointerTy)
fn rw_new_slice_ptr(ptrty: i32) -> i32 {
    let off = rw_nbo - rw_nab;
    var name: u8[>..] = [];
    name.append(val_name(rw_old_ptr));
    // skip through the last '.sroa.' component
    let lp = rfind(name, ".sroa.");
    var start: i64 = 0;
    var endp = name.len;
    if lp >= 0 {
        start = lp + 6;
        let ie = sr_find_first_not_digit(name[..], start);
        if ie >= 0 && name[ie] == '.' {
            start = ie + 1;
            let oe = sr_find_first_not_digit(name[..], start);
            if oe >= 0 && name[oe] == '.' { start = oe + 1; }
        }
    }
    var rest: u8[>..] = [];
    rest.append(name[start..endp]);
    let su = find(rest, ".sroa_");
    var pre: u8[>..] = [];
    if su >= 0 { pre.append(rest[..su]); } else { pre.append(rest); }
    pre.append(".");
    return sr_adjusted_ptr(rw_new_ai, off, ptrty, pre, sr_dl_index_bits(sr_ptr_as_of(ptrty)));
}

// extractInteger
fn extract_integer(v0: i32, ty: i32, off: i64, name: const u8[:]) -> i32 {
    var v = v0;
    let ity = vals[v].ty;
    var sh = 8 * off;
    if dl_big_endian { sh = 8 * (dl_store_size(ity) - dl_store_size(ty) - off); }
    var nm: u8[>..] = [];
    if sh != 0 {
        nm.append(name); nm.append(".shift");
        v = irb_binop(OP_LSHR, v, c_int(ity, sh), nm, true);
    }
    if ty != ity {
        nm.clear(); nm.append(name); nm.append(".trunc");
        v = irb_cast(OP_TRUNC, v, ty, nm, true);
    }
    return v;
}

fn c_int_mask_insert(ity: i32, tbits: i64, sh: i64) -> i32 {
    // ~(Ty->getMask().zext(IntTy).shl(ShAmt)) for widths up to 128
    let w = ty_bits(ity);
    if w > 128 { sr_not_ported("integer widening wider than 128 bits"); }
    var lo: u64 = 0;
    var hi: u64 = 0;
    // mask of tbits ones
    if tbits >= 128 { lo = 0xFFFFFFFFFFFFFFFF; hi = 0xFFFFFFFFFFFFFFFF; }
    else if tbits >= 64 { lo = 0xFFFFFFFFFFFFFFFF; hi = if tbits == 64 { 0 } else { (1 << ((tbits - 64) as! u64)) - 1 }; }
    else { lo = (1 << (tbits as! u64)) - 1; }
    // shl
    if sh >= 128 { lo = 0; hi = 0; }
    else if sh >= 64 { hi = lo << ((sh - 64) as! u64); lo = 0; }
    else if sh > 0 { hi = (hi << (sh as! u64)) | (lo >> ((64 - sh) as! u64)); lo = lo << (sh as! u64); }
    lo = ~lo; hi = ~hi;
    if w < 64 { lo = lo & ((1 << (w as! u64)) - 1); hi = 0; }
    else if w == 64 { hi = 0; }
    else if w < 128 { hi = hi & ((1 << ((w - 64) as! u64)) - 1); }
    if w <= 64 { return c_int(ity, lo as! i64); }
    return c_int_words(ity, lo, hi);
}

// insertInteger
fn insert_integer(old0: i32, v0: i32, off: i64, name: const u8[:]) -> i32 {
    var old = old0;
    var v = v0;
    let ity = vals[old].ty;
    let ty = vals[v].ty;
    var nm: u8[>..] = [];
    if ty != ity {
        nm.append(name); nm.append(".ext");
        v = irb_cast(OP_ZEXT, v, ity, nm, true);
    }
    var sh = 8 * off;
    if dl_big_endian { sh = 8 * (dl_store_size(ity) - dl_store_size(ty) - off); }
    if sh != 0 {
        nm.clear(); nm.append(name); nm.append(".shift");
        v = irb_binop(OP_SHL, v, c_int(ity, sh), nm, true);
    }
    if sh != 0 || ty_bits(ty) < ty_bits(ity) {
        let mask = c_int_mask_insert(ity, ty_bits(ty), sh);
        nm.clear(); nm.append(name); nm.append(".mask");
        old = irb_binop(OP_AND, old, mask, nm, true);
        nm.clear(); nm.append(name); nm.append(".insert");
        v = irb_binop(OP_OR, old, v, nm, true);
    }
    return v;
}

fn extract_vector(v: i32, bi: i64, ei: i64, name: const u8[:]) -> i32 {
    let n = ei - bi;
    if n == types[vals[v].ty].cnt { return v; }
    var nm: u8[>..] = [];
    nm.append(name); nm.append(".extract");
    if n == 1 { return irb_extractelement(v, sr_c_i64(bi), nm); }
    var mask: i32[>..<] = [];
    for i in bi..ei { mask.push(i as i32); }
    return irb_shuffle(v, -1, mask, nm, true);
}

fn insert_vector(old: i32, v0: i32, bi: i64, name: const u8[:]) -> i32 {
    var v = v0;
    var nm: u8[>..] = [];
    if !ty_is_vector(vals[v].ty) {
        nm.append(name); nm.append(".insert");
        return irb_insertelement(old, v, sr_c_i64(bi), nm);
    }
    let nsub = types[vals[v].ty].cnt;
    let nel = types[vals[old].ty].cnt;
    if nsub == nel { return v; }
    let ei = bi + nsub;
    var mask: i32[>..<] = [];
    for i in nel { if i >= bi && i < ei { mask.push((i - bi) as i32); } else { mask.push(-1); } }
    nm.append(name); nm.append(".expand");
    v = irb_shuffle(v, -1, mask, nm, true);
    mask.clear();
    for i in nel { if i >= bi && i < ei { mask.push(i as i32); } else { mask.push((i + nel) as i32); } }
    nm.clear(); nm.append(name); nm.append("blend");
    return irb_shuffle(v, old, mask, nm, true);
}

// mergeTwoVectors (IRBuilder<> Builder: no name prefix)
fn merge_two_vectors(v0in: i32, v1in: i32, elt: i32) -> i32 {
    var v0 = v0in;
    var v1 = v1in;
    fn bitcast_if_needed(v: i32) -> i32 {
        let vt = vals[v].ty;
        let et = types[vt].a;
        if et == elt { return v; }
        let total = types[vt].cnt * dl_size_bits(et);
        let nn = total / dl_size_bits(elt);
        return irb_bitcast(v, ty_vector(elt, nn, false));
    }
    v0 = bitcast_if_needed(v0);
    v1 = bitcast_if_needed(v1);
    let n0 = types[vals[v0].ty].cnt;
    let n1 = types[vals[v1].ty].cnt;
    var mask: i32[>..<] = [];
    if n0 == n1 {
        for i in n0 + n1 { mask.push(i as i32); }
    } else {
        let small = min(n0, n1);
        let large = max(n0, n1);
        var em: i32[>..<] = [];
        for i in small { em.push(i as i32); }
        for i in small..large { em.push(-1); }
        if n0 < n1 { v0 = irb_shuffle(v0, -1, em, "", false); } else { v1 = irb_shuffle(v1, -1, em, "", false); }
        for i in n0 { mask.push(i as i32); }
        for i in n1 { mask.push((large + i) as i32); }
    }
    return irb_shuffle(v0, v1, mask, "", false);
}

// rewriteTreeStructuredMerge(P): true if applied (deleted values pushed to sr_dead; *nuses set)
fn rw_tree_merge(pi: i64) -> bool, i64 {
    let p = parts[pi];
    if p.ntails > 0 { return false, 0; }
    var st_inst: i32[>..<] = [];
    var st_b: i64[>..<] = [];
    var st_e: i64[>..<] = [];
    var ld_inst: i32[>..<] = [];
    var ld_b: i64[>..<] = [];
    var ld_e: i64[>..<] = [];
    var full_load: i32 = -1;
    var init_store: i32 = -1;
    let aelt = if sr_ty_is_fixed_vector(rw_new_ty) { types[rw_new_ty].a } else { T_I8 };
    let aelt_size = dl_size_bits(aelt);
    fn valid_ty(t: i32) -> bool { return sr_ty_is_fixed_vector(t) && dl_size_bits(types[t].a) % 8 == 0 && !sr_ty_is_ptr(types[t].a); }
    for k in p.si..p.sj {
        let u = sr_slice_user(k);
        let full = sl[k].b == rw_nab && sl[k].e == rw_nae;
        if iop(u) == OP_LOAD {
            if !sr_ldst_is_simple(u) || !valid_ty(vals[u].ty) { return false, 0; }
            if full {
                if full_load >= 0 { return false, 0; }
                full_load = u;
            } else { ld_inst.push(u); ld_b.push(sl[k].b); ld_e.push(sl[k].e); }
        } else if iop(u) == OP_STORE {
            let vt = vals[op(u, 0)].ty;
            if !sr_ldst_is_simple(u) || !valid_ty(vt) { return false, 0; }
            if (types[vt].cnt * dl_size_bits(types[vt].a)) % aelt_size != 0 { return false, 0; }
            if full {
                if init_store >= 0 { return false, 0; }
                init_store = u;
            } else { st_inst.push(u); st_b.push(sl[k].b); st_e.push(sl[k].e); }
        } else {
            return false, 0;
        }
    }
    if st_inst.len < 2 { return false, 0; }
    let is_rmw = init_store >= 0 && rw_vec_ty >= 0 && ld_inst.len > 0;
    let is_st_only = init_store < 0 && full_load >= 0 && ld_inst.len == 0;
    if !is_rmw && !is_st_only { return false, 0; }
    let store_bb = inst_parent(st_inst[0]);
    for s in st_inst { if inst_parent(s) != store_bb { return false, 0; } }
    var ndeleted: i64 = 0;
    fn tree_merge(xs: i32[>..<]&) -> i32 {
        while xs.len > 1 {
            var next: i32[>..<] = [];
            var i: i64 = 0;
            while i + 1 < xs.len { next.push(merge_two_vectors(xs[i], xs[i + 1], aelt)); i += 2; }
            if xs.len % 2 == 1 { next.push(xs[xs.len - 1]); }
            xs.clear();
            for x in next { xs.push(x); }
        }
        return xs[0];
    }
    fn replace_full_load(ld: i32, merged: i32) {
        irb_set_before(ld);
        irb_prefixed = false;
        var nm: u8[>..] = [];
        nm.append(val_name(ld)); nm.append(".sroa.new.load");
        var nl = irb_load(vals[merged].ty, rw_new_ai, slice_align(), inst_is_volatile(ld), nm, true);
        if vals[nl].ty != vals[ld].ty { nl = irb_bitcast(nl, vals[ld].ty); }
        irb_prefixed = true;
        sr_rauw(ld, nl);
        sr_dead.push(ld);
        ndeleted++;
    }
    if is_st_only {
        var perm: i64[>..<] = [];
        for i in st_inst.len { perm.push(i); }
        sort(perm) { a, b => st_b[a] < st_b[b] };
        var expected = rw_nab;
        for i in perm { if st_b[i] != expected { return false, 0; } expected = st_e[i]; }
        if expected != rw_nae { return false, 0; }
        let load_bb = inst_parent(full_load);
        if load_bb == store_bb {
            for s in st_inst { if !sr_comes_before(s, full_load) { return false, 0; } }
        }
        if load_bb == store_bb { irb_set_before(full_load); } else { irb_set_before(block_terminator(store_bb)); }
        irb_prefixed = false;
        var xs: i32[>..<] = [];
        for i in perm { sr_dead.push(st_inst[i]); ndeleted++; xs.push(op(st_inst[i], 0)); }
        let merged = tree_merge(xs);
        irb_store(merged, rw_new_ai, slice_align(), false);
        irb_prefixed = true;
        replace_full_load(full_load, merged);
        return true, ndeleted;
    }
    // RMW pattern
    if inst_parent(init_store) != store_bb { return false, 0; }
    for l in ld_inst { if inst_parent(l) != store_bb { return false, 0; } }
    var acc_inst: i32[>..<] = [];
    var acc_b: i64[>..<] = [];
    var acc_e: i64[>..<] = [];
    var acc_st: bool[>..<] = [];
    for i in ld_inst.len { acc_inst.push(ld_inst[i]); acc_b.push(ld_b[i]); acc_e.push(ld_e[i]); acc_st.push(false); }
    for i in st_inst.len { acc_inst.push(st_inst[i]); acc_b.push(st_b[i]); acc_e.push(st_e[i]); acc_st.push(true); }
    var ord: i64[>..<] = [];
    for i in acc_inst.len { ord.push(i); }
    // block order
    var pos_of: i64[>..<] = [];
    for i in acc_inst.len {
        var n: i64 = 0;
        var x = block_first(store_bb);
        while x >= 0 && x != acc_inst[i] { n++; x = inst_next(x); }
        pos_of.push(n);
    }
    sort(ord) { a, b => pos_of[a] < pos_of[b] };
    if !sr_comes_before(init_store, acc_inst[ord[0]]) { return false, 0; }
    if full_load >= 0 && inst_parent(full_load) == store_bb && !sr_comes_before(acc_inst[ord[ord.len - 1]], full_load) { return false, 0; }
    var rb: i64[>..<] = [];
    var re: i64[>..<] = [];
    var rord: i64[>..<] = [];
    for i in acc_inst.len { rord.push(i); }
    sort(rord) { a, b => if acc_b[a] != acc_b[b] { acc_b[a] < acc_b[b] } else { acc_e[a] < acc_e[b] } };
    for i in rord {
        if rb.len > 0 && rb[rb.len - 1] == acc_b[i] && re[re.len - 1] == acc_e[i] { continue; }
        rb.push(acc_b[i]); re.push(acc_e[i]);
    }
    var expected = rw_nab;
    for i in rb.len { if rb[i] != expected { return false, 0; } expected = re[i]; }
    if expected != rw_nae { return false, 0; }
    irb_set_before(inst_next(init_store));
    var init_vec = op(init_store, 0);
    if vals[init_vec].ty != rw_new_ty { init_vec = irb_bitcast_named(init_vec, rw_new_ty, "init.cast"); }
    var slice_vals: i32[>..<] = [];
    for i in rb.len {
        let b = rw_index(rb[i]);
        let e = rw_index(re[i]);
        var mask: i32[>..<] = [];
        for j in e - b { mask.push((b + j) as i32); }
        slice_vals.push(irb_shuffle(init_vec, -1, mask, "init.extract", true));
    }
    sr_dead.push(init_store); ndeleted++;
    fn range_idx(b: i64, e: i64) -> i64 { for i in rb.len { if rb[i] == b && re[i] == e { return i; } } return -1; }
    for oi in ord {
        let ri = range_idx(acc_b[oi], acc_e[oi]);
        let ai = acc_inst[oi];
        if !acc_st[oi] {
            var v = slice_vals[ri];
            if vals[v].ty != vals[ai].ty {
                irb_set_before(ai);
                v = irb_bitcast(v, vals[ai].ty);
            }
            sr_rauw(ai, v);
        } else {
            slice_vals[ri] = op(ai, 0);
        }
        sr_dead.push(ai); ndeleted++;
    }
    if full_load >= 0 && inst_parent(full_load) == store_bb { irb_set_before(full_load); } else { irb_set_before(block_terminator(store_bb)); }
    irb_prefixed = false;
    var xs: i32[>..<] = [];
    for v in slice_vals { xs.push(v); }
    let merged = tree_merge(xs);
    irb_store(merged, rw_new_ai, slice_align(), false);
    irb_prefixed = true;
    if full_load >= 0 { replace_full_load(full_load, merged); }
    return true, ndeleted;
}
fn irb_bitcast_named(v: i32, t: i32, name: const u8[:]) -> i32 { irb_cast(OP_BITCAST, v, t, name, true) }

fn rw_load_new_alloca(name: const u8[:]) -> i32 { irb_load(rw_new_ty, rw_new_ai, new_ai_align(), false, name, true) }


// visitLoadInst
fn rw_visit_load(li: i32) -> bool {
    let old_op = op(li, 0);
    let tags = aa_get(li);
    let as_ = sr_ptr_as_of(vals[old_op].ty);
    let tty = if rw_is_split { ty_int(rw_slice_size * 8) } else { vals[li].ty };
    var adjusted = false;
    var v: i32 = -1;
    let vol = inst_is_volatile(li);
    if rw_vec_ty >= 0 {
        let bi = rw_index(rw_nbo);
        let ei = rw_index(rw_neo);
        let ld = rw_load_new_alloca("load");
        copy_loop_md(ld, li);
        v = extract_vector(ld, bi, ei, "vec");
    } else if rw_int_ty >= 0 && ty_is_int(vals[li].ty) {
        v = rw_load_new_alloca("load");
        v = irb_bit_cast_chain(v, rw_int_ty);
        let off = rw_nbo - rw_nab;
        if off > 0 || rw_neo < rw_nae { v = extract_integer(v, ty_int(rw_slice_size * 8), off, "extract"); }
        if ty_bits(vals[li].ty) > rw_slice_size * 8 { v = irb_cast(OP_ZEXT, v, vals[li].ty, "", false); }
    } else if rw_nbo == rw_nab && rw_neo == rw_nae &&
              (can_convert_value(rw_new_ty, tty) ||
               (ty_is_int(rw_new_ty) && ty_is_int(tty) && dl_store_size(tty) > rw_slice_size && !vol)) {
        let np = rw_ptr_to_new_ai(as_, vol);
        let nl = irb_load(rw_new_ty, np, new_ai_align(), vol, val_name(li), true);
        if vol { insts[inst_of(nl)].ord = insts[inst_of(li)].ord; insts[inst_of(nl)].ss = insts[inst_of(li)].ss; }
        if sr_ldst_is_atomic(nl) { sr_set_inst_align(nl, sr_inst_align(li)); }
        copy_metadata_for_load(nl, li);
        if aa_any(tags) { aa_set(nl, aa_adjust(tags, rw_nbo - rw_bo, vals[nl].ty)); }
        v = nl;
        if ty_is_int(rw_new_ty) && ty_is_int(tty) && ty_bits(rw_new_ty) < ty_bits(tty) {
            v = irb_cast(OP_ZEXT, v, tty, "load.ext", true);
            if dl_big_endian { v = irb_binop(OP_SHL, v, c_int(tty, ty_bits(tty) - ty_bits(rw_new_ty)), "endian_shift", true); }
        }
    } else {
        let lty = ty_ptr(as_);
        let np = rw_new_slice_ptr(lty);
        let nl = irb_load(tty, np, slice_align(), vol, val_name(li), true);
        if aa_any(tags) { aa_set(nl, aa_adjust(tags, rw_nbo - rw_bo, vals[nl].ty)); }
        if vol { insts[inst_of(nl)].ord = insts[inst_of(li)].ord; insts[inst_of(nl)].ss = insts[inst_of(li)].ss; }
        copy_loop_md(nl, li);
        v = nl;
        adjusted = true;
    }
    v = irb_bit_cast_chain(v, tty);
    if rw_is_split {
        let nx = inst_next(li);
        irb_set_at(inst_parent(li), nx, true);
        let ph = create_inst(OP_LOAD, vals[li].ty, [c_poison(ty_ptr(as_))]);
        v = insert_integer(ph, v, rw_nbo - rw_bo, "insert");
        if dbgrecs.len > 0 && m2r_recs.len > 0 { sr_not_ported("debug records using a split load"); }
        sr_rauw(li, v);
        rauw(ph, li);
        drop_all_refs(ph);
        vals[ph].kind = VK_DEAD;
    } else {
        sr_rauw(li, v);
    }
    sr_dead.push(li);
    rw_delete_if_trivially_dead(old_op);
    return !vol && !adjusted;
}

fn rw_vectorized_store(v0: i32, si: i32, tags: AAT) -> bool {
    var v = v0;
    if vals[v].ty != rw_vec_ty {
        let bi = rw_index(rw_nbo);
        let ei = rw_index(rw_neo);
        let n = ei - bi;
        let slice_ty = if n == 1 { rw_elem_ty } else { ty_vector(rw_elem_ty, n, false) };
        if vals[v].ty != slice_ty { v = irb_bit_cast_chain(v, slice_ty); }
        let old = rw_load_new_alloca("load");
        v = insert_vector(old, v, bi, "vec");
    }
    let st = irb_store(v, rw_new_ai, new_ai_align(), false);
    copy_loop_md(st, si);
    if aa_any(tags) { aa_set(st, aa_adjust(tags, rw_nbo - rw_bo, vals[v].ty)); }
    sr_dead.push(si);
    sr_migrate_debug_info(si);
    return true;
}

fn rw_integer_store(v0: i32, si: i32, tags: AAT) -> bool {
    var v = v0;
    if dl_size_bits(vals[v].ty) != ty_bits(rw_int_ty) {
        var old = rw_load_new_alloca("oldload");
        old = irb_bit_cast_chain(old, rw_int_ty);
        let off = rw_bo - rw_nab;
        v = insert_integer(old, op(si, 0), off, "insert");
    }
    v = irb_bit_cast_chain(v, rw_new_ty);
    let st = irb_store(v, rw_new_ai, new_ai_align(), false);
    copy_loop_md(st, si);
    if aa_any(tags) { aa_set(st, aa_adjust(tags, rw_nbo - rw_bo, vals[v].ty)); }
    sr_migrate_debug_info(si);
    sr_dead.push(si);
    return true;
}

// migrateDebugInfo: only dbg.assign markers need work, and assignment tracking is not ported.
fn sr_migrate_debug_info(old_inst: i32) {
    if inst_get_md(old_inst, md_kind_id("DIAssignID")) >= 0 { sr_not_ported("assignment tracking (DIAssignID) in SROA"); }
}

// visitStoreInst
fn rw_visit_store(si: i32) -> bool {
    let old_op = op(si, 1);
    let tags = aa_get(si);
    var v = op(si, 0);
    if sr_ty_is_ptr(vals[v].ty) {
        let base = sr_strip_inbounds_offsets(v);
        if sr_is_alloca(base) { setvec_insert(sr_ppwl, S_PPWL, base); }
    }
    let vt = vals[v].ty;
    if !sr_ty_is_scalable(vt) && rw_slice_size < dl_store_size(vt) {
        v = extract_integer(v, ty_int(rw_slice_size * 8), rw_nbo - rw_bo, "extract");
    }
    if rw_vec_ty >= 0 { return rw_vectorized_store(v, si, tags); }
    if rw_int_ty >= 0 && ty_is_int(vals[v].ty) { return rw_integer_store(v, si, tags); }
    let vol = inst_is_volatile(si);
    var nsi: i32 = -1;
    if rw_nbo == rw_nab && rw_neo == rw_nae && can_convert_value(vals[v].ty, rw_new_ty) {
        v = irb_bit_cast_chain(v, rw_new_ty);
        let np = rw_ptr_to_new_ai(sr_ptr_as_of(vals[old_op].ty), vol);
        nsi = irb_store(v, np, new_ai_align(), vol);
    } else {
        let np = rw_new_slice_ptr(ty_ptr(sr_ptr_as_of(vals[old_op].ty)));
        nsi = irb_store(v, np, slice_align(), vol);
    }
    copy_loop_md(nsi, si);
    if aa_any(tags) { aa_set(nsi, aa_adjust(tags, rw_nbo - rw_bo, vals[v].ty)); }
    if vol { insts[inst_of(nsi)].ord = insts[inst_of(si)].ord; insts[inst_of(nsi)].ss = insts[inst_of(si)].ss; }
    if sr_ldst_is_atomic(nsi) { sr_set_inst_align(nsi, sr_inst_align(si)); }
    sr_migrate_debug_info(si);
    sr_dead.push(si);
    rw_delete_if_trivially_dead(old_op);
    return op(nsi, 1) == rw_new_ai && vals[op(nsi, 0)].ty == rw_new_ty && !vol;
}

// getIntegerSplat(V, Size)
fn rw_integer_splat(v: i32, size: i64) -> i32 {
    if size == 1 { return v; }
    let st = ty_int(size * 8);
    let z = irb_cast(OP_ZEXT, v, st, "zext", true);
    let ones = c_all_ones(st);
    let z2 = irb_cast(OP_ZEXT, c_all_ones(vals[v].ty), st, "", false);
    let d = irb_binop(OP_UDIV, ones, z2, "", false);
    return irb_binop(OP_MUL, z, d, "isplat", true);
}
// CreateVectorSplat(NumElements, V, "vsplat")
fn rw_vector_splat(v: i32, n: i64) -> i32 {
    let ins = irb_insertelement(c_poison(ty_vector(vals[v].ty, n, false)), v, sr_c_i64(0), "vsplat.splatinsert");
    var mask: i32[>..<] = [];
    for i in n { mask.push(0); }
    return irb_shuffle(ins, -1, mask, "vsplat.splat", true);
}

// visitMemSetInst
fn rw_visit_memset(ii: i32) -> bool {
    let tags = aa_get(ii);
    let len = sr_mi_length(ii);
    if vals[len].kind != VK_CINT {
        set_op(ii, 0, rw_new_slice_ptr(vals[rw_old_ptr].ty));
        sr_call_set_param_align(ii, 0, slice_align());
        rw_delete_if_trivially_dead(rw_old_ptr);
        return false;
    }
    sr_dead.push(ii);
    let scalar_ty = ty_scalar(rw_new_ty);
    var can_continue = false;
    if rw_vec_ty >= 0 || rw_int_ty >= 0 { can_continue = true; }
    else if rw_bo > rw_nab || rw_eo < rw_nae { can_continue = false; }
    else {
        let l = sr_cint_limited(len);
        if l <= 0xFFFFFFFF {
            let src_ty = ty_vector(T_I8, l, false);
            can_continue = can_convert_value(src_ty, rw_new_ty) && dl_is_legal_integer(dl_size_bits(scalar_ty));
        }
    }
    if !can_continue {
        let sz = rw_neo - rw_nbo;
        let size = c_int(vals[len].ty, sz);
        let np = rw_new_slice_ptr(vals[rw_old_ptr].ty);
        let nw = irb_memset(np, op(ii, 1), size, slice_align(), sr_mi_is_volatile(ii));
        if aa_any(tags) { aa_set(nw, aa_adjust_n(tags, rw_nbo - rw_bo, sz)); }
        sr_migrate_debug_info(ii);
        return false;
    }
    var v: i32 = -1;
    if rw_vec_ty >= 0 {
        let bi = rw_index(rw_nbo);
        let ei = rw_index(rw_neo);
        let n = ei - bi;
        var splat = rw_integer_splat(op(ii, 1), dl_size_bits(rw_elem_ty) / 8);
        splat = irb_bit_cast_chain(splat, rw_elem_ty);
        if n > 1 { splat = rw_vector_splat(splat, n); }
        let old = rw_load_new_alloca("oldload");
        v = insert_vector(old, splat, bi, "vec");
    } else if rw_int_ty >= 0 {
        let size = rw_neo - rw_nbo;
        v = rw_integer_splat(op(ii, 1), size);
        if rw_nbo != rw_nab || rw_neo != rw_nae {
            var old = rw_load_new_alloca("oldload");
            old = irb_bit_cast_chain(old, rw_int_ty);
            v = insert_integer(old, v, rw_nbo - rw_nab, "insert");
        }
        v = irb_bit_cast_chain(v, rw_new_ty);
    } else {
        v = rw_integer_splat(op(ii, 1), dl_size_bits(scalar_ty) / 8);
        if ty_is_vector(rw_new_ty) { v = rw_vector_splat(v, types[rw_new_ty].cnt); }
        v = irb_bit_cast_chain(v, rw_new_ty);
    }
    let vol = sr_mi_is_volatile(ii);
    let np = rw_ptr_to_new_ai(sr_ptr_as_of(vals[op(ii, 0)].ty), vol);
    let nw = irb_store(v, np, new_ai_align(), vol);
    copy_loop_md(nw, ii);
    if aa_any(tags) { aa_set(nw, aa_adjust(tags, rw_nbo - rw_bo, vals[v].ty)); }
    sr_migrate_debug_info(ii);
    return !vol;
}

// visitMemTransferInst
fn rw_visit_memtransfer(ii: i32) -> bool {
    let tags = aa_get(ii);
    let is_dest = sr_use_opno(rw_old_use) == 0;
    let salign = slice_align();
    if !rw_splittable {
        let adj = rw_new_slice_ptr(vals[rw_old_ptr].ty);
        if is_dest {
            if inst_get_md(ii, md_kind_id("DIAssignID")) >= 0 { sr_not_ported("assignment tracking (DIAssignID) in SROA"); }
            set_op(ii, 0, adj);
            sr_call_set_param_align(ii, 0, salign);
        } else {
            set_op(ii, 1, adj);
            sr_call_set_param_align(ii, 1, salign);
        }
        rw_delete_if_trivially_dead(rw_old_ptr);
        return false;
    }
    let emit_memcpy = rw_vec_ty < 0 && rw_int_ty < 0 &&
        (rw_bo > rw_nab || rw_eo < rw_nae || rw_slice_size != dl_store_size(rw_new_ty) ||
         !sr_dl_size_eq_store(rw_new_ty) || !sr_ty_is_single_value(rw_new_ty));
    if emit_memcpy && rw_old_ai == rw_new_ai {
        if rw_neo != rw_eo { set_op(ii, 2, c_int(vals[sr_mi_length(ii)].ty, rw_neo - rw_nbo)); }
        return false;
    }
    sr_dead.push(ii);
    var other = if is_dest { op(ii, 1) } else { op(ii, 0) };
    let other_base = sr_strip_inbounds_offsets(other);
    if sr_is_alloca(other_base) { setvec_insert(sr_wl, S_WL, other_base); }
    let other_pty = vals[other].ty;
    let other_off = rw_nbo - rw_bo;
    var other_align = if is_dest { sr_call_param_align(ii, 1) } else { sr_call_param_align(ii, 0) };
    if other_align == 0 { other_align = 1; }
    other_align = sr_commonalign(other_align, other_off as! u64);
    var oname: u8[>..] = [];
    oname.append(val_name(other)); oname.append(".");
    if emit_memcpy {
        other = sr_adjusted_ptr(other, other_off, other_pty, oname, sr_dl_index_bits(sr_ptr_as_of(other_pty)));
        let our = rw_new_slice_ptr(vals[rw_old_ptr].ty);
        let size = c_int(vals[sr_mi_length(ii)].ty, rw_neo - rw_nbo);
        var nw: i32 = -1;
        if is_dest { nw = irb_memcpy(our, salign, other, other_align, size, sr_mi_is_volatile(ii)); }
        else { nw = irb_memcpy(other, other_align, our, salign, size, sr_mi_is_volatile(ii)); }
        if aa_any(tags) { aa_set(nw, aa_shift(tags, rw_nbo - rw_bo)); }
        sr_migrate_debug_info(ii);
        return false;
    }
    let whole = rw_nbo == rw_nab && rw_neo == rw_nae;
    let size = rw_neo - rw_nbo;
    let bi = if rw_vec_ty >= 0 { rw_index(rw_nbo) } else { 0 };
    let ei = if rw_vec_ty >= 0 { rw_index(rw_neo) } else { 0 };
    let nel = ei - bi;
    let sub_int = if rw_int_ty >= 0 { ty_int(size * 8) } else { -1 };
    var other_ty: i32 = -1;
    if rw_vec_ty >= 0 && !whole { other_ty = if nel == 1 { types[rw_vec_ty].a } else { ty_vector(types[rw_vec_ty].a, nel, false) }; }
    else if rw_int_ty >= 0 && !whole { other_ty = sub_int; }
    else { other_ty = rw_new_ty; }
    let adj = sr_adjusted_ptr(other, other_off, other_pty, oname, sr_dl_index_bits(sr_ptr_as_of(other_pty)));
    var src_align = other_align;
    var dst_align = salign;
    if !is_dest { let t = src_align; src_align = dst_align; dst_align = t; }
    var src_ptr: i32 = -1;
    var dst_ptr: i32 = -1;
    let vol = sr_mi_is_volatile(ii);
    if is_dest { dst_ptr = rw_ptr_to_new_ai(sr_ptr_as_of(vals[op(ii, 0)].ty), vol); src_ptr = adj; }
    else { dst_ptr = adj; src_ptr = rw_ptr_to_new_ai(sr_ptr_as_of(vals[op(ii, 1)].ty), vol); }
    var src: i32 = -1;
    if rw_vec_ty >= 0 && !whole && !is_dest {
        src = rw_load_new_alloca("load");
        src = extract_vector(src, bi, ei, "vec");
    } else if rw_int_ty >= 0 && !whole && !is_dest {
        src = rw_load_new_alloca("load");
        src = irb_bit_cast_chain(src, rw_int_ty);
        src = extract_integer(src, sub_int, rw_nbo - rw_nab, "extract");
    } else {
        let ld = irb_load(other_ty, src_ptr, src_align, vol, "copyload", true);
        copy_loop_md(ld, ii);
        if aa_any(tags) { aa_set(ld, aa_adjust(tags, rw_nbo - rw_bo, vals[ld].ty)); }
        src = ld;
    }
    if rw_vec_ty >= 0 && !whole && is_dest {
        let old = rw_load_new_alloca("oldload");
        src = insert_vector(old, src, bi, "vec");
    } else if rw_int_ty >= 0 && !whole && is_dest {
        var old = rw_load_new_alloca("oldload");
        old = irb_bit_cast_chain(old, rw_int_ty);
        src = insert_integer(old, src, rw_nbo - rw_nab, "insert");
        src = irb_bit_cast_chain(src, rw_new_ty);
    }
    let st = irb_store(src, dst_ptr, dst_align, vol);
    copy_loop_md(st, ii);
    if aa_any(tags) { aa_set(st, aa_adjust(tags, rw_nbo - rw_bo, vals[src].ty)); }
    sr_migrate_debug_info(ii);
    return !vol;
}

// visitIntrinsicInst (lifetime markers and droppable uses)
fn rw_visit_intrinsic(ii: i32) -> bool {
    sr_dead.push(ii);
    if sr_is_droppable_inst(ii) {
        // OldPtr->dropDroppableUsesIn(II)
        for k in nops(ii) { if op(ii, k) == rw_old_ptr { m2r_drop_droppable_use(vals[ii].ops + k as i32); } }
        return true;
    }
    let pty = ty_ptr(sr_ptr_as_of(vals[rw_old_ptr].ty));
    let p = rw_new_slice_ptr(pty);
    irb_lifetime(call_iid(ii) == IID_lifetime_start, p);
    return true;
}

// fixLoadStoreAlign
fn rw_fix_load_store_align(root: i32) {
    sr_clear(S_TMP);
    sr_add(S_TMP, root);
    var wl: i32[>..<] = [];
    wl.push(root);
    let sa = slice_align();
    while wl.len > 0 {
        let i = wl.pop();
        if iop(i) == OP_LOAD || iop(i) == OP_STORE {
            sr_set_inst_align(i, min(sr_inst_align(i), sa));
            continue;
        }
        var u = first_use(i);
        while u >= 0 { let us = use_user(u); if sr_add(S_TMP, us) { wl.push(us); } u = use_next(u); }
    }
}

fn rw_visit_phi(pn: i32) -> bool {
    // InsertPointGuard
    let sbb = irb_bb; let spos = irb_pos; let shead = irb_head; let sdl = irb_dl;
    if iop(rw_old_ptr) == OP_PHI {
        let bb = inst_parent(rw_old_ptr);
        irb_set_at(bb, first_non_phi(bb), true);
        if inst_is_eh_pad(first_non_phi(bb)) { sr_not_ported("PHI rewriting in a block starting with an EH pad"); }
    } else {
        irb_set_before(rw_old_ptr);
    }
    irb_dl = inst_get_md(rw_old_ptr, 0);
    let np = rw_new_slice_ptr(vals[rw_old_ptr].ty);
    for k in nops(pn) { if op(pn, k) == rw_old_ptr { set_op(pn, k, np); } }
    rw_delete_if_trivially_dead(rw_old_ptr);
    rw_fix_load_store_align(pn);
    setvec_insert(rw_phi_users, S_PHIU, pn);
    irb_bb = sbb; irb_pos = spos; irb_head = shead; irb_dl = sdl;
    return true;
}

fn rw_visit_select(si: i32) -> bool {
    let np = rw_new_slice_ptr(vals[rw_old_ptr].ty);
    if op(si, 1) == rw_old_ptr { set_op(si, 1, np); }
    if op(si, 2) == rw_old_ptr { set_op(si, 2, np); }
    rw_delete_if_trivially_dead(rw_old_ptr);
    rw_fix_load_store_align(si);
    setvec_insert(rw_sel_users, S_SELU, si);
    return true;
}

// AllocaSliceRewriter::visit(Slice)
fn rw_visit_slice(k: i64) -> bool {
    let s = sl[k];
    rw_bo = s.b; rw_eo = s.e;
    rw_splittable = s.split;
    rw_is_split = rw_bo < rw_nab || rw_eo > rw_nae;
    rw_nbo = max(rw_bo, rw_nab);
    rw_neo = min(rw_eo, rw_nae);
    rw_slice_size = rw_neo - rw_nbo;
    rw_old_use = s.u;
    rw_old_ptr = uses[s.u].val;
    let user = uses[s.u].user;
    irb_set_before(user);
    irb_dl = inst_get_md(user, 0);
    irb_prefixed = true;
    irb_prefix.clear();
    irb_prefix.append(val_name(rw_new_ai));
    irb_prefix.append(".");
    irb_prefix.append(str(rw_bo));
    irb_prefix.append(".");
    let o = iop(user);
    if o == OP_LOAD { return rw_visit_load(user); }
    if o == OP_STORE { return rw_visit_store(user); }
    if o == OP_PHI { return rw_visit_phi(user); }
    if o == OP_SELECT { return rw_visit_select(user); }
    if o == OP_CALL {
        let id = call_iid(user);
        if id == IID_memset || id == IID_memset_inline { return rw_visit_memset(user); }
        if id == IID_memcpy || id == IID_memcpy_inline || id == IID_memmove { return rw_visit_memtransfer(user); }
        return rw_visit_intrinsic(user);
    }
    fatal("internal: SROA: no rewrite rule for this instruction");
    return false;
}

// ---------------------------------------------------------------------------------------------
// isSafeToLoadUnconditionally (llvm/lib/Analysis/Loads.cpp), with AC = DT = nullptr as SROA calls it.

fn sr_ptr_alignment(v: i32) -> i64 {
    // Value::getPointerAlignment for the bases this port knows
    if sr_is_alloca(v) { return sr_inst_align(v); }
    if is_arg(v) {
        let fv = args_parent[vals[v].sub];
        let s = alist_param(func_attrs(fv), args_no[vals[v].sub] as i64);
        let a = aset_find(s, AK_Alignment);
        if a >= 0 { return attrs[a].i1 as! i64; }
        if aset_has(s, AK_StructRet) { sr_not_ported("getPointerAlignment of an sret argument"); }
        return 1;
    }
    if vals[v].kind == VK_GVAR {
        let al = globs[glob_of(v)].align;
        if al != 0 { return 1 << ((al as i64) - 1); }
        sr_not_ported("getPointerAlignment of a global without explicit alignment");
    }
    sr_not_ported("getPointerAlignment of this value");
    return 1;
}

// getPointerDereferenceableBytes: (bytes, can be null); -1 bytes = unknown kind (fail loudly)
fn sr_ptr_deref_bytes(v: i32) -> i64, bool {
    if sr_is_alloca(v) {
        if sr_alloca_is_array(v) { return 0, false; }
        return dl_store_size(sr_alloca_ty(v)), false;
    }
    if is_arg(v) {
        let fv = args_parent[vals[v].sub];
        let s = alist_param(func_attrs(fv), args_no[vals[v].sub] as i64);
        let a = aset_find(s, AK_Dereferenceable);
        if a >= 0 { return attrs[a].i1 as! i64, false; }
        let b = aset_find(s, AK_DereferenceableOrNull);
        if b >= 0 { sr_not_ported("dereferenceable_or_null arguments in isDereferenceableAndAlignedPointer"); }
        if aset_has(s, AK_ByVal) || aset_has(s, AK_StructRet) || aset_has(s, AK_InAlloca) || aset_has(s, AK_ByRef) || aset_has(s, AK_Preallocated) {
            sr_not_ported("byval/sret/byref arguments in isDereferenceableAndAlignedPointer");
        }
        return 0, false;
    }
    if vals[v].kind == VK_GVAR {
        sr_not_ported("dereferenceability of globals");
    }
    if is_inst(v) {
        let o = iop(v);
        if o == OP_LOAD {
            if inst_get_md(v, md_kind_id("dereferenceable")) >= 0 || inst_get_md(v, md_kind_id("dereferenceable_or_null")) >= 0 {
                sr_not_ported("!dereferenceable loads in isDereferenceableAndAlignedPointer");
            }
            return 0, false;
        }
        if is_callbase(v) { sr_not_ported("calls in isDereferenceableAndAlignedPointer"); }
        return 0, false;
    }
    if is_constant(v) && vals[v].kind != VK_CNULL && vals[v].kind != VK_UNDEF && vals[v].kind != VK_POISON {
        sr_not_ported("constants in isDereferenceableAndAlignedPointer");
    }
    return 0, false;
}

recursive fn deref_and_aligned(v: i32, align: i64, size: i64, depth: i64) -> bool {
    if depth == 0 { return false; }
    if !sr_add(S_DEL, v) { return false; }
    let o = sr_operator_op(v);
    if o == OP_GEP {
        let ok, off = sr_gep_const_offset(sr_gep_src_type(v), v, 1);
        if !ok || off < 0 || off % align != 0 { return false; }
        return deref_and_aligned(op(v, 0), align, off + size, depth - 1);
    }
    if o == OP_BITCAST && sr_ty_is_ptr(vals[op(v, 0)].ty) { return deref_and_aligned(op(v, 0), align, size, depth - 1); }
    if is_inst(v) && iop(v) == OP_SELECT {
        return deref_and_aligned(op(v, 1), align, size, depth - 1) && deref_and_aligned(op(v, 2), align, size, depth - 1);
    }
    let bytes, can_null = sr_ptr_deref_bytes(v);
    if size <= bytes && !can_null {
        return sr_ptr_alignment(v) >= align;
    }
    if o == OP_ADDRSPACECAST { return deref_and_aligned(op(v, 0), align, size, depth - 1); }
    return false;
}

// AreEquivalentAddressValues
fn sr_equivalent_address_values(a: i32, b: i32) -> bool {
    if a == b { return true; }
    if is_inst(a) && is_inst(b) {
        let o = iop(a);
        if is_binary_op(o) || is_cast_op(o) || o == OP_PHI || o == OP_GEP {
            if iop(b) == o && vals[a].ty == vals[b].ty && nops(a) == nops(b) {
                var same = true;
                for k in nops(a) { if op(a, k) != op(b, k) { same = false; } }
                if o == OP_GEP && insts[inst_of(a)].ty2 != insts[inst_of(b)].ty2 { same = false; }
                if o == OP_PHI { for k in nops(a) { if phi_block(a, k) != phi_block(b, k) { same = false; } } }
                if same { return true; }
            }
        }
    }
    return false;
}

fn safe_to_load_unconditionally(v: i32, align: i64, size: i64, scan_from: i32) -> bool {
    sr_clear(S_DEL);
    if deref_and_aligned(v, align, size, 16) {
        // suppressSpeculativeLoadForSanitizers(ScanFrom)
        if scan_from < 0 { return true; }
        let f = inst_func(scan_from);
        if !func_has_fn_attr(f, AK_SanitizeThread) && !func_has_fn_attr(f, AK_SanitizeAddress) && !func_has_fn_attr(f, AK_SanitizeHWAddress) { return true; }
    }
    if scan_from < 0 { return false; }
    let sv = strip_ptr_casts(v);
    var x = inst_prev(scan_from);
    while x >= 0 {
        let o = iop(x);
        if o == OP_CALL && inst_may_write_memory(x) && !inst_is_lifetime_start_or_end(x) { return false; }
        var ap: i32 = -1;
        var at: i32 = -1;
        var aal: i64 = 0;
        if o == OP_LOAD {
            if inst_is_volatile(x) { x = inst_prev(x); continue; }
            ap = op(x, 0); at = vals[x].ty; aal = sr_inst_align(x);
        } else if o == OP_STORE {
            if inst_is_volatile(x) { x = inst_prev(x); continue; }
            ap = op(x, 1); at = vals[op(x, 0)].ty; aal = sr_inst_align(x);
        } else { x = inst_prev(x); continue; }
        if aal < align { x = inst_prev(x); continue; }
        if ap == sv && size <= dl_store_size(at) { return true; }
        if sr_equivalent_address_values(strip_ptr_casts(ap), sv) && size <= dl_store_size(at) { return true; }
        x = inst_prev(x);
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// PHI and select speculation

// isSafePHIToSpeculate
fn safe_phi_to_speculate(pn: i32) -> bool {
    let bb = inst_parent(pn);
    var max_align: i64 = 1;
    var load_ty: i32 = -1;
    var u = first_use(pn);
    while u >= 0 {
        let li = use_user(u);
        u = use_next(u);
        if iop(li) != OP_LOAD || !sr_ldst_is_simple(li) { return false; }
        if inst_parent(li) != bb { return false; }
        if load_ty >= 0 { if load_ty != vals[li].ty { return false; } } else { load_ty = vals[li].ty; }
        var x = pn;
        while x != li { if inst_may_write_memory(x) { return false; } x = inst_next(x); }
        max_align = max(max_align, sr_inst_align(li));
    }
    if load_ty < 0 { return false; }
    let lsize = dl_store_size(load_ty);
    for k in nops(pn) {
        let ti = block_terminator(phi_block(pn, k));
        let inv = op(pn, k);
        if ti == inv || inst_may_have_side_effects(ti) { return false; }
        if term_nsucc(ti) == 1 { continue; }
        if safe_to_load_unconditionally(inv, max_align, lsize, ti) { continue; }
        return false;
    }
    return true;
}

// Value::sr_user_back(): the last use in the use list
fn sr_user_back(v: i32) -> i32 {
    var u = first_use(v);
    while use_next(u) >= 0 { u = use_next(u); }
    return use_user(u);
}

// speculatePHINodeLoads
fn speculate_phi_loads(pn: i32) {
    let some = sr_user_back(pn);
    let lty = vals[some].ty;
    irb_set_before(pn);
    irb_prefixed = true;
    irb_prefix.clear();
    var nm: u8[>..] = [];
    nm.append(val_name(pn)); nm.append(".sroa.speculated");
    let npn = irb_phi(lty, nops(pn), nm);
    let tags = aa_get(some);
    let align = sr_inst_align(some);
    while has_uses(pn) {
        let li = sr_user_back(pn);
        sr_rauw(li, npn);
        sr_erase(li);
    }
    sr_clear(S_TMP);
    var inj_pred: i32[>..<] = [];
    var inj_load: i32[>..<] = [];
    for k in nops(pn) {
        let pred = phi_block(pn, k);
        let inv = op(pn, k);
        var found: i32 = -1;
        for j in inj_pred.len { if inj_pred[j] == pred { found = inj_load[j]; } }
        if found >= 0 { phi_add_incoming(npn, found, pred); continue; }
        irb_set_before(block_terminator(pred));
        nm.clear(); nm.append(val_name(pn)); nm.append(".sroa.speculate.load."); nm.append(val_name(pred));
        let ld = irb_load(lty, inv, align, false, nm, true);
        if aa_any(tags) { aa_set(ld, tags); }
        phi_add_incoming(npn, ld, pred);
        inj_pred.push(pred); inj_load.push(ld);
    }
    sr_erase(pn);
}

// isSafeLoadOfSelectToSpeculate: bit 1 = true value speculatable, bit 2 = false value
fn safe_load_of_select(li: i32, si: i32) -> i64 {
    var spec: i64 = 0;
    let tv = op(si, 1);
    let fv = op(si, 2);
    let lt = vals[li].ty;
    if sr_ty_is_scalable(lt) { sr_not_ported("select speculation of scalable loads"); }
    let size = dl_store_size(lt);
    let al = sr_inst_align(li);
    if safe_to_load_unconditionally(tv, al, size, li) { spec |= if tv == tv { 1 } else { 0 }; }
    else if sroa_preserve_cfg { return spec; }
    if safe_to_load_unconditionally(fv, al, size, li) { spec |= if fv == tv { 1 } else { 2 }; }
    else if sroa_preserve_cfg { return spec; }
    return spec;
}

// SROA::isSafeSelectToSpeculate: ops appended to out (pairs inst, spec; spec -1 = store); false = give up
fn safe_select_to_speculate(si: i32, out: i32[>..<]&) -> bool {
    var u = first_use(si);
    while u >= 0 {
        var us = use_user(u);
        u = use_next(u);
        if iop(us) == OP_BITCAST && sr_has_one_use(us) { us = use_user(first_use(us)); }
        if iop(us) == OP_STORE {
            if inst_is_volatile(us) || sroa_preserve_cfg { return false; }
            out.push(us); out.push(-1);
            continue;
        }
        if iop(us) != OP_LOAD || inst_is_volatile(us) { return false; }
        if !sr_ldst_is_simple(us) {
            if sroa_preserve_cfg { return false; }
            out.push(us); out.push(0);
            continue;
        }
        let spec = safe_load_of_select(us, si);
        if sroa_preserve_cfg && spec != 3 { return false; }
        out.push(us); out.push(spec as i32);
    }
    return true;
}
fn sr_has_one_use(v: i32) -> bool { let u = first_use(v); return u >= 0 && use_next(u) < 0; }

// speculateSelectInstLoads
fn speculate_select_loads(si: i32, li: i32) {
    let tv = op(si, 1);
    let fv = op(si, 2);
    irb_set_before(li);
    irb_prefixed = true;
    irb_prefix.clear();
    var nm: u8[>..] = [];
    nm.append(val_name(li)); nm.append(".sroa.speculate.load.true");
    let tl = irb_load(vals[li].ty, tv, sr_inst_align(li), false, nm, true);
    nm.clear(); nm.append(val_name(li)); nm.append(".sroa.speculate.load.false");
    let fl = irb_load(vals[li].ty, fv, sr_inst_align(li), false, nm, true);
    let tags = aa_get(li);
    if aa_any(tags) { aa_set(tl, tags); aa_set(fl, tags); }
    nm.clear(); nm.append(val_name(li)); nm.append(".sroa.speculated");
    let v = irb_select(op(si, 0), tl, fl, nm, si);
    sr_rauw(li, v);
}

// rewriteSelectInstMemOps
fn rewrite_select_mem_ops(si: i32, at: i64, n: i64) -> bool {
    var cfg_changed = false;
    for j in n {
        let i = sr_sel_ops[at + 2 * j];
        let spec = sr_sel_ops[at + 2 * j + 1];
        if spec == 3 {
            speculate_select_loads(si, i);
        } else {
            rewrite_mem_op_of_select(si, i, spec);
            cfg_changed = true;
        }
        sr_erase(i);
    }
    var u = first_use(si);
    while u >= 0 { let nu = use_next(u); sr_erase(use_user(u)); u = nu; }
    sr_erase(si);
    return cfg_changed;
}

// Instruction::eraseFromParent inside SROA: debug records using the value become poison.
fn sr_erase(i: i32) { m2r_erase(i); }
fn sr_rauw(old: i32, nw: i32) { if dbgrecs.len > 0 { m2r_dbg_rauw(old, nw); } rauw(old, nw); }

// ---------------------------------------------------------------------------------------------
// rewritePartition / splitAlloca / presplitLoadsAndStores

// SROA::rewritePartition: (new alloca or -1, active bits)
fn rewrite_partition(ai: i32, pi: i64) -> i32, i64 {
    let p = parts[pi];
    let pty, int_widen, vty = select_partition_type(pi, ai, sroa_agg_to_vec);
    var nai: i32 = -1;
    if pty == sr_alloca_ty(ai) && p.b == 0 {
        nai = ai;
    } else {
        let al = sr_commonalign(sr_inst_align(ai), p.b as! u64);
        let unconstrained = al <= dl_align(pty, true);
        let na = create_inst(OP_ALLOCA, ty_ptr(sr_alloca_as(ai)), [c_int(T_I32, 1)]);
        let nii = inst_of(na);
        insts[nii].ty2 = pty;
        insts[nii].as_ = insts[inst_of(ai)].as_;
        sr_set_inst_align(na, if unconstrained { dl_align(pty, false) } else { al });
        inst_insert_before(na, ai);
        // new AllocaInst(..., InsertBefore = AI->getIterator()): not at the head, so AI's debug records move
        let ai_i = inst_of(ai);
        if ai_i < inst_dbg.len && inst_dbg[ai_i] >= 0 {
            while inst_dbg.len <= nii { inst_dbg.push(-1); }
            inst_dbg[nii] = inst_dbg[ai_i];
            inst_dbg[ai_i] = -1;
            var r = inst_dbg[nii];
            while r >= 0 { dbgrecs[r].owner = na; r = dbgrecs[r].next; }
        }
        var nm: u8[>..] = [];
        nm.append(val_name(ai)); nm.append(".sroa."); nm.append(str(p.si));
        set_name(na, nm);
        let dl = inst_get_md(ai, 0);
        if dl >= 0 { inst_set_md(na, 0, dl); }
        nai = na;
    }
    let ppw_old = sr_ppwl.len;
    rw_init(ai, nai, pty, p.b, p.e, int_widen, vty);
    var promotable = true;
    let merged, nd = rw_tree_merge(pi);
    if !merged {
        for t in p.tails..p.tails + p.ntails { if !rw_visit_slice(part_tails[t]) { promotable = false; } }
        for k in p.si..p.sj { if !rw_visit_slice(k) { promotable = false; } }
    }
    for ph in rw_phi_users {
        if !safe_phi_to_speculate(ph) {
            promotable = false;
            rw_phi_users.clear(); rw_sel_users.clear();
            break;
        }
    }
    var nsel: i32[>..<] = [];
    var nsel_at: i32[>..<] = [];
    var nsel_n: i32[>..<] = [];
    var nsel_ops: i32[>..<] = [];
    for s in rw_sel_users {
        let at = nsel_ops.len;
        if !safe_select_to_speculate(s, nsel_ops) {
            promotable = false;
            rw_phi_users.clear(); rw_sel_users.clear();
            nsel.clear(); nsel_at.clear(); nsel_n.clear(); nsel_ops.clear();
            break;
        }
        nsel.push(s); nsel_at.push(at as i32); nsel_n.push(((nsel_ops.len - at) / 2) as i32);
    }
    if promotable {
        for u in as_dead_use_if_prom {
            let old_v = uses[u].val;
            m2r_drop_droppable_use(u);
            if is_inst(old_v) && is_instruction_trivially_dead(old_v) { sr_dead.push(old_v); }
        }
        if rw_phi_users.len == 0 && rw_sel_users.len == 0 {
            setvec_insert(sr_prom, S_PROM, nai);
        } else {
            for ph in rw_phi_users { setvec_insert(sr_sphis, S_SPHI, ph); }
            for j in nsel.len {
                // MapVector::insert: keeps the first entry for a key
                if sr_add(S_SEL, nsel[j]) {
                    sr_sels.push(nsel[j]);
                    sr_sel_at.push(sr_sel_ops.len as i32);
                    sr_sel_n.push(nsel_n[j]);
                    for x in nsel_at[j]..nsel_at[j] + 2 * nsel_n[j] { sr_sel_ops.push(nsel_ops[x]); }
                }
            }
            setvec_insert(sr_wl, S_WL, nai);
        }
    } else {
        while sr_ppwl.len > ppw_old { setvec_pop(sr_ppwl, S_PPWL); }
        if nai == ai { return -1, 0; }
        setvec_insert(sr_wl, S_WL, nai);
    }
    return nai, dl_size_bits(pty);
}

// presplitLoadsAndStores
fn presplit_loads_and_stores(ai: i32) -> bool {
    var loads: i32[>..<] = [];
    var stores: i32[>..<] = [];
    // SplitOffsetsMap: inst -> record r; rec_slice[r], splits run (rec_at/rec_n in split_pool)
    sr_clear(S_SPLIT);
    sr_clear(S_UNSPL);
    var rec_slice: i64[>..<] = [];
    var rec_splits: i64[>..<] = [];   // per record: a run grown in place; records are appended in order
    var rec_first: i32[>..<] = [];
    var rec_next: i32[>..<] = [];     // linked list of split values per record (index into split_vals)
    var rec_last: i32[>..<] = [];
    var split_vals: i64[>..<] = [];
    var split_next: i32[>..<] = [];
    fn rec_for(i: i32) -> i64 {
        if sr_has(S_SPLIT, i) { return sr_get(S_SPLIT, i, 0); }
        let r = rec_slice.len;
        sr_set(S_SPLIT, i, r);
        rec_slice.push(-1); rec_first.push(-1); rec_last.push(-1);
        return r;
    }
    fn rec_push(r: i64, x: i64) {
        let id = split_vals.len as i32;
        split_vals.push(x); split_next.push(-1);
        if rec_last[r] < 0 { rec_first[r] = id; } else { split_next[rec_last[r]] = id; }
        rec_last[r] = id;
    }
    fn rec_list(r: i64, out: i64[>..<]&) {
        out.clear();
        var x = rec_first[r];
        while x >= 0 { out.push(split_vals[x]); x = split_next[x]; }
    }
    compute_partitions();
    for pi in parts.len {
        let p = parts[pi];
        for k in p.si..p.sj {
            let i = sr_slice_user(k);
            if !sl[k].split || sl[k].e <= p.e {
                if iop(i) == OP_LOAD { sr_add(S_UNSPL, i); }
                else if iop(i) == OP_STORE { let v = op(i, 0); if is_inst(v) && iop(v) == OP_LOAD { sr_add(S_UNSPL, v); } }
                continue;
            }
            if iop(i) == OP_LOAD {
                var simply_stored = true;
                var u = first_use(i);
                while u >= 0 { let us = use_user(u); if iop(us) != OP_STORE || !sr_ldst_is_simple(us) { simply_stored = false; } u = use_next(u); }
                if !simply_stored { sr_add(S_UNSPL, i); continue; }
                loads.push(i);
            } else if iop(i) == OP_STORE {
                if sr_use_opno(sl[k].u) != 1 { continue; }
                let sv = op(i, 0);
                if !(is_inst(sv) && iop(sv) == OP_LOAD) || !sr_ldst_is_simple(sv) { continue; }
                stores.push(i);
            } else {
                continue;
            }
            let r = rec_for(i);
            rec_slice[r] = k;
            rec_push(r, p.e - sl[k].b);
        }
        for t in p.tails..p.tails + p.ntails {
            let k = part_tails[t];
            let ui = sr_slice_user(k);
            if !sr_has(S_SPLIT, ui) { continue; }
            let r = sr_get(S_SPLIT, ui, 0);
            if sl[k].e > p.e { rec_push(r, p.e - sl[rec_slice[r]].b); }
        }
    }
    var la: i64[>..<] = [];
    var sa: i64[>..<] = [];
    retain(stores) { si =>
        let li = op(si, 0);
        var drop = false;
        if sr_has(S_UNSPL, li) { drop = true; }
        else if sr_has(S_SPLIT, li) {
            rec_list(sr_get(S_SPLIT, li, 0), la);
            let sr = rec_for(si);
            rec_list(sr, sa);
            var same = la.len == sa.len;
            if same { for j in la.len { if la[j] != sa[j] { same = false; } } }
            if !same { sr_add(S_UNSPL, li); drop = true; }
        }
        !drop
    };
    retain(stores) { si => !sr_has(S_UNSPL, op(si, 0)) };
    retain(loads) { li => !sr_has(S_UNSPL, li) };
    if loads.len == 0 && stores.len == 0 { return false; }

    irb_set_before(ai);
    irb_prefixed = true;
    irb_prefix.clear();
    var new_slices: Slice[>..<] = [];
    sr_clear(S_DEL);      // ResplitPromotableAllocas
    var resplit: i32[>..<] = [];
    // SplitLoadsMap: load -> run of split loads
    var slm_load: i32[>..<] = [];
    var slm_at: i32[>..<] = [];
    var slm_pool: i32[>..<] = [];
    var split_loads: i32[>..<] = [];
    var offs: i64[>..<] = [];
    for li in loads {
        split_loads.clear();
        let r = sr_get(S_SPLIT, li, 0);
        rec_list(r, offs);
        let s = sl[rec_slice[r]];
        let slice_size = s.e - s.b;
        let base_off = s.b;
        let base_ptr = op(li, 0);
        irb_set_before(li);
        var part_off: i64 = 0;
        var part_size = offs[0];
        var idx: i64 = 0;
        let size = offs.len;
        loop {
            let pty = ty_int(part_size * 8);
            let as_ = sr_ptr_as_of(vals[base_ptr].ty);
            var pre: u8[>..] = [];
            pre.append(val_name(base_ptr)); pre.append(".");
            let ptr = sr_adjusted_ptr(base_ptr, part_off, vals[base_ptr].ty, pre, sr_dl_index_bits(sr_ptr_as_of(vals[li].ty * 0 + vals[base_ptr].ty)));
            let pl = irb_load(pty, ptr, sr_commonalign(sr_inst_align(li), part_off as! u64), false, val_name(li), true);
            copy_loop_md(pl, li);
            split_loads.push(pl);
            new_slices.push(Slice { b: base_off + part_off, e: base_off + part_off + part_size, u: vals[pl].ops, split: false });
            if idx >= size { break; }
            part_off = offs[idx];
            idx++;
            part_size = (if idx < size { offs[idx] } else { slice_size }) - part_off;
            let _ = as_;
        }
        var deferred = false;
        var u = first_use(li);
        while u >= 0 {
            let si = use_user(u);
            u = use_next(u);
            if stores.len > 0 && sr_has(S_SPLIT, si) { deferred = true; continue; }
            let sbase = op(si, 1);
            irb_set_before(si);
            let tags = aa_get(si);
            for j in split_loads.len {
                let pl = split_loads[j];
                let po = if j == 0 { 0 } else { offs[j - 1] };
                var pre: u8[>..] = [];
                pre.append(val_name(sbase)); pre.append(".");
                let ptr = sr_adjusted_ptr(sbase, po, vals[sbase].ty, pre, sr_dl_index_bits(sr_ptr_as_of(vals[sbase].ty)));
                let ps = irb_store(pl, ptr, sr_commonalign(sr_inst_align(si), po as! u64), false);
                copy_loop_md(ps, si);
                let dk = md_kind_id("DIAssignID");
                let da = inst_get_md(si, dk);
                if da >= 0 { sr_not_ported("assignment tracking (DIAssignID) in SROA"); }
                if aa_any(tags) { aa_set(ps, aa_adjust(tags, po, vals[pl].ty)); }
            }
            if sr_is_alloca(sbase) {
                if sr_add(S_DEL, sbase) { resplit.push(sbase); }
                setvec_insert(sr_wl, S_WL, sbase);
            } else {
                let b = sr_strip_inbounds_offsets(sbase);
                if sr_is_alloca(b) { setvec_insert(sr_wl, S_WL, b); }
            }
            sr_dead.push(si);
        }
        if deferred {
            slm_load.push(li); slm_at.push(slm_pool.len as i32);
            for x in split_loads { slm_pool.push(x); }
        }
        sr_dead.push(li);
        sl[rec_slice[r]].u = -1;
    }
    for si in stores {
        let li = op(si, 0);
        let store_size = ty_bits(vals[li].ty) / 8;
        let r = sr_get(S_SPLIT, si, 0);
        rec_list(r, offs);
        let base_off = sl[rec_slice[r]].b;
        let lbase = op(li, 0);
        let sbase = op(si, 1);
        var have_split: i64 = -1;
        for j in slm_load.len { if slm_load[j] == li { have_split = slm_at[j] as i64; } }
        var part_off: i64 = 0;
        var part_size = offs[0];
        var idx: i64 = 0;
        let size = offs.len;
        loop {
            let pty = ty_int(part_size * 8);
            var pl: i32 = -1;
            if have_split >= 0 { pl = slm_pool[have_split + idx]; }
            else {
                irb_set_before(li);
                var pre: u8[>..] = [];
                pre.append(val_name(lbase)); pre.append(".");
                let ptr = sr_adjusted_ptr(lbase, part_off, vals[lbase].ty, pre, sr_dl_index_bits(sr_ptr_as_of(vals[lbase].ty)));
                pl = irb_load(pty, ptr, sr_commonalign(sr_inst_align(li), part_off as! u64), false, val_name(li), true);
                copy_loop_md(pl, li);
            }
            irb_set_before(si);
            var pre2: u8[>..] = [];
            pre2.append(val_name(sbase)); pre2.append(".");
            let sptr = sr_adjusted_ptr(sbase, part_off, vals[sbase].ty, pre2, sr_dl_index_bits(sr_ptr_as_of(vals[sbase].ty)));
            let ps = irb_store(pl, sptr, sr_commonalign(sr_inst_align(si), part_off as! u64), false);
            copy_loop_md(ps, si);
            new_slices.push(Slice { b: base_off + part_off, e: base_off + part_off + part_size, u: vals[ps].ops + 1, split: false });
            if idx >= size { break; }
            part_off = offs[idx];
            idx++;
            part_size = (if idx < size { offs[idx] } else { store_size }) - part_off;
        }
        if have_split < 0 {
            if sr_is_alloca(lbase) {
                if sr_add(S_DEL, lbase) { resplit.push(lbase); }
                setvec_insert(sr_wl, S_WL, lbase);
            } else {
                let b = sr_strip_inbounds_offsets(lbase);
                if sr_is_alloca(b) { setvec_insert(sr_wl, S_WL, b); }
            }
        }
        if sr_has_one_use(li) { sr_dead.push(li); }
        sr_dead.push(si);
        sl[rec_slice[r]].u = -1;
    }
    retain(sl) { s => s.u >= 0 };
    // AS.insert(NewSlices): stable_sort the new ones, then inplace_merge (stable: old before new on ties)
    stable_sort(new_slices) { x, y => slice_less(x, y) };
    var merged: Slice[>..<] = [];
    var a: i64 = 0;
    var b: i64 = 0;
    while a < sl.len || b < new_slices.len {
        if b >= new_slices.len || (a < sl.len && !slice_less(new_slices[b], sl[a])) { merged.push(sl[a]); a++; }
        else { merged.push(new_slices[b]); b++; }
    }
    sl.clear();
    for x in merged { sl.push(x); }
    // PromotableAllocas.set_subtract(ResplitPromotableAllocas)
    if resplit.len > 0 {
        retain(sr_prom) { x => !sr_has(S_DEL, x) };
        for x in resplit { sr_del(S_PROM, x); }
    }
    return true;
}

// splitAlloca
fn split_alloca(ai: i32) -> bool {
    if sl.len == 0 { return false; }
    var changed = presplit_loads_and_stores(ai);
    var sorted = true;
    let asize = sr_alloca_alloc_size(ai);
    if asize <= 1024 {
        var splittable_off: bool[>..<] = [];
        splittable_off.resize(asize + 1, true);
        for s in sl {
            var o = s.b + 1;
            while o < s.e && o < asize { splittable_off[o] = false; o++; }
        }
        for &s in sl {
            if !s.split { continue; }
            if (s.b > asize || splittable_off[s.b]) && (s.e > asize || splittable_off[s.e]) { continue; }
            let u = uses[s.u].user;
            if iop(u) == OP_LOAD || iop(u) == OP_STORE { s.split = false; sorted = false; }
        }
    } else {
        for &s in sl {
            if !s.split { continue; }
            if s.b == 0 && s.e >= asize { continue; }
            let u = uses[s.u].user;
            if iop(u) == OP_LOAD || iop(u) == OP_STORE { s.split = false; sorted = false; }
        }
    }
    if !sorted { slices_stable_sort(); }
    compute_partitions();
    var frag_ai: i32[>..<] = [];
    for pi in parts.len {
        let nai, bits = rewrite_partition(ai, pi);
        if nai >= 0 {
            changed = true;
            if nai != ai { frag_ai.push(nai); }
        }
    }
    // Debug-info migration (findDVRDeclares / findDVRValues / getDVRAssignmentMarkers of AI)
    if dbgrecs.len > 0 {
        var recs: i32[>..<] = [];
        m2r_find_dbg_users(ai, recs);
        if recs.len > 0 && frag_ai.len > 0 { sr_not_ported("debug-info migration for split allocas"); }
        if inst_get_md(ai, md_kind_id("DIAssignID")) >= 0 { sr_not_ported("assignment tracking (DIAssignID) in SROA"); }
    }
    return changed;
}

// clobberUse
fn clobber_use(u: i32) {
    let old = uses[u].val;
    if old < 0 { return; }
    use_set(u, c_poison(vals[old].ty));
    if is_inst(old) && is_instruction_trivially_dead(old) { sr_dead.push(old); }
}

// ---------------------------------------------------------------------------------------------
// AggLoadStoreRewriter

var agg_queue: i32[>..<];       // use ids
var agg_idx: i32[>..<];         // Indices
var agg_gep: i32[>..<];         // GEPIndices (values)
var agg_ptr: i32 = -1;
var agg_base_ty: i32 = -1;
var agg_base_align: i64 = 1;
var agg_tags: AAT;
var agg_components: i32[>..<];
var agg_is_load: bool = true;
var agg_store: i32 = -1;

fn agg_enqueue_users(i: i32) {
    var u = first_use(i);
    while u >= 0 {
        if sr_add(S_AGGV, use_user(u)) { agg_queue.push(u); }
        u = use_next(u);
    }
}

// DataLayout::getIndexedOffsetInType(BaseTy, GEPIndices)
fn sr_indexed_offset(t0: i32) -> i64 {
    var t = t0;
    var off: i64 = (sr_cint_sext(agg_gep[0]) as! i64) * dl_alloc_size(t);
    for k in 1..agg_gep.len {
        let x = sr_cint_u64(agg_gep[k]) as! i64;
        if ty_is_struct(t) { off += dl_struct_offset(t, x); t = ty_field(t, x); }
        else { t = types[t].a; off += x * dl_alloc_size(t); }
    }
    return off;
}

fn sr_suffix_name(base: const u8[:], idx: i64) -> u8[>..] { var n: u8[>..] = []; n.append(base); n.append("."); n.append(str(idx)); return n; }

// OpSplitter::emitSplitOps (recursive over the type; Name is in agg_name_stack)
var agg_names: u8[>..<];
fn push_decimal(i: i64) { let s = str(i); for c in s { agg_names.push(c); } }
var agg_name_ends: i32[>..<];
recursive fn agg_emit(t: i32, agg_in: i32) -> i32 {
    var agg = agg_in;
    if sr_ty_is_single_value(t) {
        let off = sr_indexed_offset(agg_base_ty);
        let al = sr_commonalign(agg_base_align, off as! u64);
        return agg_emit_leaf(t, agg, al);
    }
    if ty_is_array(t) || ty_is_struct(t) {
        let n = types[t].cnt;
        for i in n {
            agg_idx.push(i as i32);
            agg_gep.push(sr_c_i32(i));
            let mark = agg_names.len;
            agg_names.push('.');
            push_decimal(i);
            let et = if ty_is_array(t) { types[t].a } else { ty_field(t, i) };
            agg = agg_emit(et, agg);
            agg_names.resize(mark);
            agg_gep.pop();
            agg_idx.pop();
        }
        return agg;
    }
    fatal("internal: SROA: only arrays and structs are aggregate loadable types");
    return agg;
}

fn agg_emit_leaf(t: i32, agg: i32, al: i64) -> i32 {
    var nm: u8[>..] = [];
    if agg_is_load {
        nm.append(agg_names); nm.append(".gep");
        let g = irb_gep(agg_base_ty, agg_ptr, agg_gep, GEP_INBOUNDS | GEP_NUSW, nm, true);
        nm.clear(); nm.append(agg_names); nm.append(".load");
        let ld = irb_load(t, g, al, false, nm, true);
        if aa_any(agg_tags) {
            let ok, off = gep_const_offset_list(agg_base_ty);
            if ok { aa_set(ld, aa_adjust(agg_tags, off, vals[ld].ty)); }
        }
        agg_components.push(ld);
        nm.clear(); nm.append(agg_names); nm.append(".insert");
        return irb_insertvalue(agg, ld, agg_idx, nm);
    }
    nm.append(agg_names); nm.append(".extract");
    let ev = irb_extractvalue(agg, agg_idx, nm);
    nm.clear(); nm.append(agg_names); nm.append(".gep");
    let g = irb_gep(agg_base_ty, agg_ptr, agg_gep, GEP_INBOUNDS | GEP_NUSW, nm, true);
    let st = irb_store(ev, g, al, false);
    let ok, off = gep_const_offset_list(agg_base_ty);
    if aa_any(agg_tags) { aa_set(st, aa_adjust(agg_tags, off, vals[ev].ty)); }
    let base = sr_strip_inbounds_offsets(op(agg_store, 1));
    if sr_is_alloca(base) { sr_migrate_debug_info(agg_store); }
    return agg;
}
fn gep_const_offset_list(t: i32) -> bool, i64 { return true, sr_indexed_offset(t); }

fn agg_split(i: i32, ptr: i32, ty: i32, name: const u8[:], is_load: bool) {
    irb_set_before(i);
    irb_prefixed = true;
    irb_prefix.clear();
    agg_idx.clear();
    agg_gep.clear();
    agg_gep.push(sr_c_i32(0));
    agg_ptr = ptr;
    agg_base_ty = ty;
    agg_base_align = sr_commonalign(sr_inst_align(i), 0);
    agg_tags = aa_get(i);
    agg_components.clear();
    agg_is_load = is_load;
    agg_store = if is_load { -1 } else { i };
    agg_names.clear();
    for c in name { agg_names.push(c); }
}

fn agg_visit_load(li: i32, u: i32) -> bool {
    if !sr_ldst_is_simple(li) || sr_ty_is_single_value(vals[li].ty) { return false; }
    var nm: u8[>..] = [];
    nm.append(val_name(li)); nm.append(".fca");
    agg_split(li, uses[u].val, vals[li].ty, nm, true);
    // recordFakeUses
    var fakes: i32[>..<] = [];
    var x = first_use(li);
    while x >= 0 { let us = use_user(x); if is_inst(us) && iop(us) == OP_CALL && call_iid(us) == IID_fake_use { fakes.push(us); } x = use_next(x); }
    let v = agg_emit(vals[li].ty, c_poison(vals[li].ty));
    for f in fakes {
        irb_set_before(f);
        for c in agg_components { irb_intrinsic_call(IID_fake_use, [], [c], []); }
        sr_erase(f);
    }
    sr_del(S_AGGV, li);
    sr_rauw(li, v);
    sr_erase(li);
    return true;
}

fn agg_visit_store(si: i32, u: i32) -> bool {
    if !sr_ldst_is_simple(si) || op(si, 1) != uses[u].val { return false; }
    let v = op(si, 0);
    if sr_ty_is_single_value(vals[v].ty) { return false; }
    var nm: u8[>..] = [];
    nm.append(val_name(v)); nm.append(".fca");
    agg_split(si, uses[u].val, vals[v].ty, nm, false);
    agg_emit(vals[v].ty, v);
    sr_del(S_AGGV, si);
    sr_erase(si);
    return true;
}

fn agg_new_ops(g: i32, sel: i32, x: i32, out: i32[>..<]&) {
    out.clear();
    for k in nops(g) { let o = op(g, k); out.push(if o == sel { x } else { o }); }
}

// unfoldGEPSelect
fn agg_unfold_gep_select(g: i32) -> bool {
    var sel: i32 = if is_inst(op(g, 0)) && iop(op(g, 0)) == OP_SELECT { op(g, 0) } else { -1 };
    for k in 1..nops(g) {
        let o = op(g, k);
        if is_inst(o) && iop(o) == OP_SELECT {
            if sel >= 0 { return false; }
            sel = o;
            if vals[op(o, 1)].kind != VK_CINT || vals[op(o, 2)].kind != VK_CINT { return false; }
            continue;
        }
        if is_inst(o) && iop(o) == OP_ZEXT {
            if sel >= 0 { return false; }
            sel = o;
            if vals[op(o, 0)].ty != T_I1 { return false; }
            continue;
        }
        if vals[o].kind != VK_CINT { return false; }
    }
    if sel < 0 { return false; }
    var c: i32 = -1; var tv: i32 = -1; var fv: i32 = -1;
    var mdfrom: i32 = -1;
    if iop(sel) == OP_SELECT { c = op(sel, 0); tv = op(sel, 1); fv = op(sel, 2); mdfrom = sel; }
    else { c = op(sel, 0); tv = c_int(vals[sel].ty, 1); fv = c_int(vals[sel].ty, 0); }
    var tops: i32[>..<] = [];
    var fops: i32[>..<] = [];
    agg_new_ops(g, sel, tv, tops);
    agg_new_ops(g, sel, fv, fops);
    irb_set_before(g);
    let nw = insts[inst_of(g)].flags;
    let sty = insts[inst_of(g)].ty2;
    var nm: u8[>..] = [];
    nm.append(val_name(tv)); nm.append(".sroa.gep");
    let nt = irb_gep(sty, tops[0], tops[1..], nw, nm, true);
    nm.clear(); nm.append(val_name(fv)); nm.append(".sroa.gep");
    let nf = irb_gep(sty, fops[0], fops[1..], nw, nm, true);
    nm.clear(); nm.append(val_name(sel)); nm.append(".sroa.sel");
    var ns: i32 = -1;
    if mdfrom >= 0 { ns = irb_select(c, nt, nf, nm, mdfrom); }
    else {
        // CreateSelectWithUnknownProfile: adds !prof unknown when profcheck metadata fixes are enabled
        ns = irb_select(c, nt, nf, nm, -1);
        sr_select_unknown_profile(ns);
    }
    sr_del(S_AGGV, g);
    sr_rauw(g, ns);
    sr_erase(g);
    sr_add(S_AGGV, ns);
    agg_enqueue_users(ns);
    return true;
}
fn sr_select_unknown_profile(s: i32) {
    // setExplicitlyUnknownBranchWeightsIfProfiled: only when the function has an entry count
    let f = inst_func(s);
    let pk = md_kind_id("prof");
    let p = sr_func_get_md(f, pk);
    if p >= 0 { sr_not_ported("!prof unknown branch weights on SROA selects in profiled functions"); }
}
fn sr_func_get_md(f: i32, kind: i32) -> i32 {
    let g = glob_of(f);
    for k in globs[g].nmd { if md_att[globs[g].md + 2 * k] == kind { return md_att[globs[g].md + 2 * k + 1]; } }
    return -1;
}

// unfoldGEPPhi
fn agg_unfold_gep_phi(g: i32) -> bool {
    var phi: i32 = if is_inst(op(g, 0)) && iop(op(g, 0)) == OP_PHI { op(g, 0) } else { -1 };
    fn invalid_ptr(v: i32) -> bool {
        if !is_inst(v) { return false; }
        if sr_is_alloca(v) { return !sr_alloca_is_static(v); }
        return true;
    }
    if phi >= 0 {
        for k in nops(phi) { if invalid_ptr(op(phi, k)) { return false; } }
    } else {
        if invalid_ptr(op(g, 0)) { return false; }
    }
    for k in 1..nops(g) {
        let o = op(g, k);
        if is_inst(o) && iop(o) == OP_PHI {
            if phi >= 0 { return false; }
            phi = o;
            for j in nops(o) { if vals[op(o, j)].kind != VK_CINT { return false; } }
            continue;
        }
        if vals[o].kind != VK_CINT { return false; }
    }
    if phi < 0 { return false; }
    irb_set_before(phi);
    var nm: u8[>..] = [];
    nm.append(val_name(phi)); nm.append(".sroa.phi");
    let np = irb_phi(vals[g].ty, nops(phi), nm);
    let sty = insts[inst_of(g)].ty2;
    let entry = func_entry(inst_func(g));
    irb_set_before(block_terminator(entry));
    var nops_v: i32[>..<] = [];
    for k in nops(phi) {
        let o = op(phi, k);
        let bb = phi_block(phi, k);
        var ng: i32 = -1;
        let ni = phi_block_index(np, bb);
        if ni >= 0 { ng = op(np, ni); }
        else {
            agg_new_ops(g, phi, o, nops_v);
            nm.clear(); nm.append(val_name(phi)); nm.append(".sroa.gep");
            ng = irb_gep(sty, nops_v[0], nops_v[1..], insts[inst_of(g)].flags, nm, true);
        }
        phi_add_incoming(np, ng, bb);
    }
    sr_del(S_AGGV, g);
    sr_rauw(g, np);
    sr_erase(g);
    sr_add(S_AGGV, np);
    agg_enqueue_users(np);
    return true;
}

fn agg_rewrite(ai: i32) -> bool {
    irb_prefixed = true;
    irb_prefix.clear();
    agg_queue.clear();
    sr_clear(S_AGGV);
    agg_enqueue_users(ai);
    var changed = false;
    while agg_queue.len > 0 {
        let u = agg_queue.pop();
        let i = uses[u].user;
        if is_dead(i) { continue; }
        let o = iop(i);
        if o == OP_LOAD { if agg_visit_load(i, u) { changed = true; } }
        else if o == OP_STORE { if agg_visit_store(i, u) { changed = true; } }
        else if o == OP_BITCAST || o == OP_ADDRSPACECAST || o == OP_PHI || o == OP_SELECT { agg_enqueue_users(i); }
        else if o == OP_GEP {
            if agg_unfold_gep_select(i) { changed = true; }
            else if agg_unfold_gep_phi(i) { changed = true; }
            else { agg_enqueue_users(i); }
        }
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// runOnAlloca / deleteDeadInstructions / promoteAllocas / runSROA

fn run_on_alloca(ai: i32) -> bool, bool {
    var changed = false;
    var cfg_changed = false;
    if !has_uses(ai) {
        sr_erase_alloca(ai);
        return true, false;
    }
    let size = sr_alloca_alloc_size(ai);
    if sr_alloca_is_array(ai) || size < 0 || size == 0 { return false, false; }
    if size == -2 { return false, false; }
    if agg_rewrite(ai) { changed = true; }
    build_slices(ai);
    if as_escaped >= 0 { return changed, cfg_changed; }
    if as_escaped_ro >= 0 {
        propagate_stored_values_to_loads(ai);
        return true, cfg_changed;
    }
    for du in as_dead_users {
        for k in nops(du) { clobber_use(vals[du].ops + k as i32); }
        sr_rauw(du, c_poison(vals[du].ty));
        sr_dead.push(du);
        changed = true;
    }
    for u in as_dead_operands { clobber_use(u); changed = true; }
    if sl.len == 0 { return changed, cfg_changed; }
    if split_alloca(ai) { changed = true; }
    while sr_sphis.len > 0 { speculate_phi_loads(setvec_pop(sr_sphis, S_SPHI)); }
    // SelectsToRewrite.takeVector(), popped from the back
    var sels: i32[>..<] = [];
    var sat: i32[>..<] = [];
    var sn: i32[>..<] = [];
    for j in sr_sels.len { sels.push(sr_sels[j]); sat.push(sr_sel_at[j]); sn.push(sr_sel_n[j]); sr_del(S_SEL, sr_sels[j]); }
    sr_sels.clear(); sr_sel_at.clear(); sr_sel_n.clear();
    while sels.len > 0 {
        let s = sels.pop();
        let at = sat.pop();
        let n = sn.pop();
        if rewrite_select_mem_ops(s, at as i64, n as i64) { cfg_changed = true; }
    }
    sr_sel_ops.clear();
    return changed, cfg_changed;
}

// AllocaInst::eraseFromParent for a dead alloca (runOnAlloca's trivial case)
fn sr_erase_alloca(ai: i32) { sr_erase(ai); }

// deleteDeadInstructions; deleted allocas are collected in `deleted`.
fn delete_dead_instructions(deleted: i32[>..<]&) -> bool {
    var changed = false;
    while sr_dead.len > 0 {
        let i = sr_dead.pop();
        if i < 0 || !is_inst(i) { continue; }
        if sr_is_alloca(i) {
            deleted.push(i);
            var recs: i32[>..<] = [];
            m2r_find_dbg_users(i, recs);
            for r in recs { if dbgrecs[r].kind as i64 == DR_DECLARE { dbg_erase_record(r); } }
        }
        if inst_get_md(i, md_kind_id("DIAssignID")) >= 0 { sr_not_ported("assignment tracking (DIAssignID) in SROA"); }
        sr_rauw(i, c_undef(vals[i].ty));
        for k in nops(i) {
            let o = op(i, k);
            if is_inst(o) {
                set_op(i, k, -1);
                if is_instruction_trivially_dead(o) { sr_dead.push(o); }
            }
        }
        sr_erase(i);
        changed = true;
    }
    return changed;
}

fn promote_allocas(fv: i32) -> bool {
    if sr_prom.len == 0 { return false; }
    if !flag_bool("sroa-skip-mem2reg", false) {
        var xs: i32[>..<] = [];
        for a in sr_prom { xs.push(a); }
        dt_get(fv, DT_DOM);
        promote_mem_to_reg(fv, xs);
    }
    for a in sr_prom { sr_del(S_PROM, a); }
    sr_prom.clear();
    return true;
}

fn set_subtract(xs: i32[>..<]&, s: i64, del: const i32[:]) {
    if del.len == 0 { return; }
    sr_clear(S_TMP);
    for d in del { sr_add(S_TMP, d); }
    retain(xs) { x => !sr_has(S_TMP, x) };
    for d in del { sr_del(s, d); }
}

// SROAPass::run
fn sroa_run(fv: i32, preserve_cfg: bool, agg_to_vec: bool) -> u32 {
    tli_cur_fn = fv;
    sroa_preserve_cfg = preserve_cfg;
    sroa_agg_to_vec = agg_to_vec;
    m2r_collect_records(fv);
    dt_get(fv, DT_DOM);
    for s in SR_NS { sr_clear(s); }
    sr_wl.clear(); sr_ppwl.clear(); sr_prom.clear(); sr_sphis.clear(); sr_sels.clear();
    sr_sel_at.clear(); sr_sel_n.clear(); sr_sel_ops.clear(); sr_dead.clear();
    let entry = func_entry(fv);
    var i = block_first(entry);
    let last = block_last(entry);
    while i >= 0 && i != last {
        if sr_is_alloca(i) {
            if sr_ty_is_scalable(sr_alloca_ty(i)) && is_alloca_promotable(i) { setvec_insert(sr_prom, S_PROM, i); }
            else { setvec_insert(sr_wl, S_WL, i); }
        }
        i = inst_next(i);
    }
    var changed = false;
    var cfg_changed = false;
    var deleted: i32[>..<] = [];
    loop {
        while sr_wl.len > 0 {
            let a = setvec_pop(sr_wl, S_WL);
            let c1, c2 = run_on_alloca(a);
            if c1 { changed = true; }
            if c2 { cfg_changed = true; }
            if delete_dead_instructions(deleted) { changed = true; }
            if deleted.len > 0 {
                set_subtract(sr_wl, S_WL, deleted);
                set_subtract(sr_ppwl, S_PPWL, deleted);
                set_subtract(sr_prom, S_PROM, deleted);
                deleted.clear();
            }
        }
        if promote_allocas(fv) { changed = true; }
        sr_wl.clear();
        for x in sr_ppwl { sr_wl.push(x); }
        sr_clear(S_WL);
        for x in sr_wl { sr_add(S_WL, x); }
        sr_ppwl.clear();
        sr_clear(S_PPWL);
        if sr_wl.len == 0 { break; }
    }
    if changed && func_assignment_tracking(fv) { sr_not_ported("RemoveRedundantDbgInstrs after SROA with assignment tracking"); }
    if !changed { return 0xFFFFFFFF; }
    // CFGAnalyses preserved unless the CFG changed; the dominator tree is always preserved (DTU)
    if !cfg_changed { return PA_CFG; }
    return (1 as u32) << A_DOMTREE;
}

// isAssignmentTrackingEnabled(M): the "debug-info-assignment-tracking" module flag
fn func_assignment_tracking(fv: i32) -> bool { return false; }

// ---------------------------------------------------------------------------------------------
// SSAUpdater + SSAUpdaterImpl (llvm/lib/Transforms/Utils/SSAUpdater.cpp,
// llvm/include/llvm/Transforms/Utils/SSAUpdaterImpl.h) and LoadAndStorePromoter::run, as used by
// SROA::propagateStoredValuesToLoads (BasicLoadAndStorePromoter).

var su_ty: i32 = -1;
var su_name: u8[>..];
// BBInfo records
var bi_bb: i32[>..<];
var bi_aval: i32[>..<];
var bi_def: i32[>..<];
var bi_num: i32[>..<];
var bi_idom: i32[>..<];
var bi_pat: i32[>..<];
var bi_np: i32[>..<];
var bi_tag: i32[>..<];
var bi_preds: i32[>..<];

fn su_avail(bb: i32) -> i32 { return sr_get(S_AVAIL, bb, -1) as i32; }
fn su_set_avail(bb: i32, v: i32) { sr_set(S_AVAIL, bb, v); }
fn su_new_info(bb: i32, v: i32) -> i32 {
    let id = bi_bb.len as i32;
    bi_bb.push(bb); bi_aval.push(v); bi_def.push(if v >= 0 { id } else { -1 }); bi_num.push(0);
    bi_idom.push(-1); bi_pat.push(0); bi_np.push(0); bi_tag.push(-1);
    return id;
}
fn su_map(bb: i32) -> i32 { return sr_get(S_BBMAP, bb, -1) as i32; }

// FindPredecessorBlocks
fn su_preds(bb: i32, out: i32[>..<]&) {
    out.clear();
    let f = block_first(bb);
    if f >= 0 && iop(f) == OP_PHI { for k in nops(f) { out.push(phi_block(f, k)); } }
    else { each_pred(bb) { p => out.push(p); }; }
}

fn su_create_phi(bb: i32, np: i64) -> i32 {
    let pn = new_inst(OP_PHI, su_ty, np);
    vals[pn].nops = 0;
    inst_insert_before(pn, block_first(bb));
    if su_name.len > 0 { set_name(pn, su_name); }
    return pn;
}

// SSAUpdaterImpl::GetValue
fn su_get_value_impl(bb: i32) -> i32 {
    bi_bb.clear(); bi_aval.clear(); bi_def.clear(); bi_num.clear(); bi_idom.clear();
    bi_pat.clear(); bi_np.clear(); bi_tag.clear(); bi_preds.clear();
    sr_clear(S_BBMAP);
    var block_list: i32[>..<] = [];
    // BuildBlockList
    var roots: i32[>..<] = [];
    var wl: i32[>..<] = [];
    var info = su_new_info(bb, -1);
    sr_set(S_BBMAP, bb, info);
    wl.push(info);
    var preds: i32[>..<] = [];
    while wl.len > 0 {
        info = wl.pop();
        su_preds(bi_bb[info], preds);
        bi_np[info] = preds.len as i32;
        bi_pat[info] = bi_preds.len as i32;
        for k in preds.len { bi_preds.push(-1); }
        for k in preds.len {
            let pred = preds[k];
            let m = su_map(pred);
            if m >= 0 { bi_preds[bi_pat[info] + k] = m; continue; }
            let pv = su_avail(pred);
            let pi = su_new_info(pred, pv);
            sr_set(S_BBMAP, pred, pi);
            bi_preds[bi_pat[info] + k] = pi;
            if pv >= 0 { roots.push(pi); continue; }
            wl.push(pi);
        }
    }
    let pseudo = su_new_info(-1, -1);
    var num: i32 = 1;
    while roots.len > 0 {
        info = roots.pop();
        bi_idom[info] = pseudo;
        bi_num[info] = -1;
        wl.push(info);
    }
    while wl.len > 0 {
        info = wl[wl.len - 1];
        if bi_num[info] == -2 {
            bi_num[info] = num; num++;
            if bi_aval[info] < 0 { block_list.push(info); }
            wl.pop();
            continue;
        }
        bi_num[info] = -2;
        let t = block_terminator(bi_bb[info]);
        if t >= 0 {
            for k in term_nsucc(t) {
                let si = su_map(term_succ(t, k));
                if si < 0 || bi_num[si] != 0 { continue; }
                bi_num[si] = -1;
                wl.push(si);
            }
        }
    }
    bi_num[pseudo] = num;
    if block_list.len == 0 {
        let v = c_poison(su_ty);
        su_set_avail(bb, v);
        return v;
    }
    // FindDominators
    fn intersect(a0: i32, b0: i32) -> i32 {
        var a = a0; var b = b0;
        while a != b {
            while bi_num[a] < bi_num[b] { a = bi_idom[a]; if a < 0 { return b; } }
            while bi_num[b] < bi_num[a] { b = bi_idom[b]; if b < 0 { return a; } }
        }
        return a;
    }
    var changed = true;
    while changed {
        changed = false;
        var i = block_list.len;
        while i > 0 {
            i--;
            let inf = block_list[i];
            var nid: i32 = -1;
            for p in bi_np[inf] {
                let pr = bi_preds[bi_pat[inf] + p];
                if bi_num[pr] == 0 {
                    bi_aval[pr] = c_poison(su_ty);
                    su_set_avail(bi_bb[pr], bi_aval[pr]);
                    bi_def[pr] = pr;
                    bi_num[pr] = bi_num[pseudo];
                    bi_num[pseudo] += 1;
                }
                if nid < 0 { nid = pr; } else { nid = intersect(nid, pr); }
            }
            if nid >= 0 && nid != bi_idom[inf] { bi_idom[inf] = nid; changed = true; }
        }
    }
    // FindPHIPlacement
    fn def_in_frontier(p0: i32, idom: i32) -> bool {
        var p = p0;
        while p != idom { if bi_def[p] == p { return true; } p = bi_idom[p]; }
        return false;
    }
    changed = true;
    while changed {
        changed = false;
        var i = block_list.len;
        while i > 0 {
            i--;
            let inf = block_list[i];
            if bi_def[inf] == inf { continue; }
            var nd = bi_def[bi_idom[inf]];
            for p in bi_np[inf] { if def_in_frontier(bi_preds[bi_pat[inf] + p], bi_idom[inf]) { nd = inf; break; } }
            if nd != bi_def[inf] { bi_def[inf] = nd; changed = true; }
        }
    }
    // FindAvailableVals
    for inf in block_list {
        if bi_def[inf] != inf { continue; }
        // FindSingularVal
        if bi_np[inf] > 0 {
            let sv = bi_aval[bi_def[bi_preds[bi_pat[inf]]]];
            var ok = sv >= 0;
            if ok { for p in 1..bi_np[inf] { let pv = bi_aval[bi_def[bi_preds[bi_pat[inf] + p]]]; if pv < 0 || pv != sv { ok = false; } } }
            if ok {
                su_set_avail(bi_bb[inf], sv);
                bi_aval[inf] = sv;
                bi_def[inf] = bi_def[bi_preds[bi_pat[inf]]];
                continue;
            }
        }
        su_find_existing_phi(bi_bb[inf]);
        if bi_aval[inf] >= 0 { continue; }
        let ph = su_create_phi(bi_bb[inf], bi_np[inf]);
        bi_aval[inf] = ph;
        su_set_avail(bi_bb[inf], ph);
    }
    var i = block_list.len;
    while i > 0 {
        i--;
        let inf = block_list[i];
        if bi_def[inf] != inf { su_set_avail(bi_bb[inf], bi_aval[bi_def[inf]]); continue; }
        let ph = bi_aval[inf];
        if !(is_inst(ph) && iop(ph) == OP_PHI && nops(ph) == 0) { continue; }
        for p in bi_np[inf] {
            var pi = bi_preds[bi_pat[inf] + p];
            let pred = bi_bb[pi];
            if bi_def[pi] != pi { pi = bi_def[pi]; }
            phi_add_incoming(ph, bi_aval[pi], pred);
        }
    }
    return bi_aval[bi_def[su_map(bb)]];
}

fn su_find_existing_phi(bb: i32) {
    var count = 0;
    var x = block_first(bb);
    var tagged: i32[>..<] = [];
    while x >= 0 && iop(x) == OP_PHI {
        count++;
        if count > 80 { break; }
        if su_phi_matches(x, tagged) {
            for b in tagged {
                let ph = bi_tag[b];
                let pbb = inst_parent(ph);
                su_set_avail(pbb, ph);
                bi_aval[su_map(pbb)] = ph;
            }
            break;
        }
        x = inst_next(x);
    }
}

fn su_phi_matches(phi0: i32, tagged: i32[>..<]&) -> bool {
    tagged.clear();
    var wl: i32[>..<] = [];
    wl.push(phi0);
    let pb = su_map(inst_parent(phi0));
    bi_tag[pb] = phi0;
    tagged.push(pb);
    var ok = true;
    while ok && wl.len > 0 {
        let phi = wl.pop();
        for k in nops(phi) {
            let iv = op(phi, k);
            var pi = su_map(phi_block(phi, k));
            if pi < 0 { ok = false; break; }
            if bi_def[pi] != pi { pi = bi_def[pi]; }
            if bi_aval[pi] >= 0 {
                if iv == bi_aval[pi] { continue; }
                ok = false; break;
            }
            if !(is_inst(iv) && iop(iv) == OP_PHI) || inst_parent(iv) != bi_bb[pi] { ok = false; break; }
            if bi_tag[pi] >= 0 {
                if iv == bi_tag[pi] { continue; }
                ok = false; break;
            }
            bi_tag[pi] = iv;
            tagged.push(pi);
            wl.push(iv);
        }
    }
    if !ok {
        for b in tagged { bi_tag[b] = -1; }
        tagged.clear();
    }
    return ok;
}

fn su_get_value_at_end(bb: i32) -> i32 {
    let v = su_avail(bb);
    if v >= 0 { return v; }
    return su_get_value_impl(bb);
}

// SSAUpdater::GetValueInMiddleOfBlock
fn su_get_value_in_middle(bb: i32) -> i32 {
    if !sr_has(S_AVAIL, bb) { return su_get_value_at_end(bb); }
    var pb: i32[>..<] = [];
    var pv: i32[>..<] = [];
    var singular: i32 = -1;
    let f = block_first(bb);
    var preds: i32[>..<] = [];
    su_preds(bb, preds);
    for k in preds.len {
        let v = su_get_value_at_end(preds[k]);
        pb.push(preds[k]); pv.push(v);
        if k == 0 { singular = v; } else if v != singular { singular = -1; }
    }
    if pb.len == 0 { return c_poison(su_ty); }
    if singular >= 0 { return singular; }
    if f >= 0 && iop(f) == OP_PHI {
        var x = f;
        while x >= 0 && iop(x) == OP_PHI {
            // IsEquivalentPHI (ValueMapping keeps the last value per block)
            var nuniq: i64 = 0;
            for k in pb.len { var dup = false; for j in k { if pb[j] == pb[k] { dup = true; } } if !dup { nuniq++; } }
            if nops(x) == nuniq {
                var eq = true;
                for k in nops(x) {
                    var mv: i32 = -1;
                    for j in pb.len { if pb[j] == phi_block(x, k) { mv = pv[j]; } }
                    if mv != op(x, k) { eq = false; }
                }
                if eq { return x; }
            }
            x = inst_next(x);
        }
    }
    let ph = new_inst(OP_PHI, su_ty, pb.len);
    vals[ph].nops = 0;
    inst_insert_before(ph, block_first(bb));
    if su_name.len > 0 { set_name(ph, su_name); }
    for k in pb.len { phi_add_incoming(ph, pv[k], pb[k]); }
    let sv = simplify_instruction(ph);
    if sv >= 0 { sr_erase(ph); return sv; }
    let fnp = first_non_phi(bb);
    if fnp >= 0 { let dl = inst_get_md(fnp, 0); if dl >= 0 { inst_set_md(ph, 0, dl); } }
    return ph;
}

// LoadAndStorePromoter(Insts, SSA, BaseName = "") + run(Insts) with BasicLoadAndStorePromoter's hooks.
fn load_store_promote(insts: const i32[:], zero_ty: i32) {
    let first = insts[0];
    let some = if iop(first) == OP_LOAD { first } else { op(first, 0) };
    su_ty = vals[some].ty;
    su_name.clear();
    su_name.append(val_name(some));
    sr_clear(S_AVAIL);
    sr_clear(S_REPL);
    sr_clear(S_UBB);
    for u in insts { let b = inst_parent(u); sr_set(S_UBB, b, sr_get(S_UBB, b, 0) + 1); }
    var live_in: i32[>..<] = [];
    for u in insts {
        let bb = inst_parent(u);
        let cnt = sr_get(S_UBB, bb, 0);
        if cnt <= 0 { continue; }
        if cnt == 1 {
            if iop(u) == OP_STORE { su_set_avail(bb, op(u, 0)); }
            else if iop(u) == OP_ALLOCA { su_set_avail(bb, c_undef(zero_ty)); }
            else { live_in.push(u); }
            sr_set(S_UBB, bb, -1);
            continue;
        }
        var block_uses: i32[>..<] = [];
        for x in insts { if inst_parent(x) == bb { block_uses.push(x); } }
        var has_store = false;
        for x in block_uses { if iop(x) == OP_STORE || iop(x) == OP_ALLOCA { has_store = true; } }
        if !has_store {
            for x in block_uses { live_in.push(x); }
            sr_set(S_UBB, bb, -1);
            continue;
        }
        // sort by block order
        var pos: i64[>..<] = [];
        for x in block_uses { var n: i64 = 0; var y = block_first(bb); while y >= 0 && y != x { n++; y = inst_next(y); } pos.push(n); }
        var ord: i64[>..<] = [];
        for k in block_uses.len { ord.push(k); }
        sort(ord) { a, b => pos[a] < pos[b] };
        var stored: i32 = -1;
        for k in ord {
            let x = block_uses[k];
            if iop(x) == OP_LOAD {
                if stored >= 0 { sr_rauw(x, stored); sr_set(S_REPL, x, stored); }
                else { live_in.push(x); }
                continue;
            }
            if iop(x) == OP_STORE { stored = op(x, 0); }
            else if iop(x) == OP_ALLOCA { stored = c_undef(zero_ty); }
        }
        su_set_avail(bb, stored);
        sr_set(S_UBB, bb, -1);
    }
    for ld in live_in {
        var nv = su_get_value_in_middle(inst_parent(ld));
        if nv == ld { nv = c_poison(vals[nv].ty); }
        sr_rauw(ld, nv);
        sr_set(S_REPL, ld, nv);
    }
    for u in insts {
        if iop(u) == OP_STORE || iop(u) == OP_ALLOCA { continue; }
        if has_uses(u) {
            var nv = sr_get(S_REPL, u, -1) as i32;
            while sr_has(S_REPL, nv) { nv = sr_get(S_REPL, nv, -1) as i32; }
            sr_rauw(u, nv);
        }
        sr_erase(u);
    }
}

// SROA::propagateStoredValuesToLoads
fn propagate_stored_values_to_loads(ai: i32) {
    var all_same = true;
    var pty: i32 = -1;
    var insts: i32[>..<] = [];
    var bo: i64 = 0;
    var eo: i64 = 0;
    fn flush() {
        if all_same && insts.len > 0 {
            insts.push(ai);
            load_store_promote(insts, pty);
        }
        all_same = true;
        pty = -1;
        insts.clear();
    }
    for k in sl.len {
        let s = sl[k];
        let u = uses[s.u].user;
        if sr_is_assume_like(u) { continue; }
        if s.b >= eo {
            flush();
            bo = s.b; eo = s.e;
        } else if s.b != bo || s.e != eo {
            all_same = false;
            eo = max(eo, s.e);
            continue;
        }
        if iop(u) == OP_LOAD {
            let t = vals[u].ty;
            if !sr_ldst_is_simple(u) || (pty >= 0 && t != pty) { all_same = false; }
            pty = t;
            insts.push(u);
        } else if iop(u) == OP_STORE {
            let t = vals[op(u, 0)].ty;
            if !sr_ldst_is_simple(u) || (pty >= 0 && t != pty) { all_same = false; }
            pty = t;
            insts.push(u);
        } else {
            all_same = false;
        }
    }
    flush();
}

// isAssumeLikeIntrinsic
fn sr_is_assume_like(i: i32) -> bool {
    if !is_inst(i) || iop(i) != OP_CALL { return false; }
    let id = call_iid(i);
    if id == 0 { return false; }
    let names: const u8[:][] = ["llvm.assume", "llvm.sideeffect", "llvm.pseudoprobe", "llvm.dbg.assign", "llvm.dbg.declare",
        "llvm.dbg.value", "llvm.dbg.label", "llvm.invariant.start", "llvm.invariant.end", "llvm.lifetime.start",
        "llvm.lifetime.end", "llvm.experimental.noalias.scope.decl", "llvm.objectsize", "llvm.ptr.annotation",
        "llvm.var.annotation"];
    let nm = intr_name(id as i64);
    for n in names { if starts_with(nm, n) && (nm.len == n.len || nm[n.len] == '.') { return true; } }
    return false;
}

// Instruction::clone for a load or store (operands, flags, alignment, ordering, metadata; no name)
fn sr_clone_ldst(i: i32) -> i32 {
    var opsv: i32[>..<] = [];
    for k in nops(i) { opsv.push(op(i, k)); }
    let c = create_inst(iop(i), vals[i].ty, opsv);
    let ci = inst_of(c);
    let oi = inst_of(i);
    insts[ci].align = insts[oi].align; insts[ci].ord = insts[oi].ord; insts[ci].ord2 = insts[oi].ord2;
    insts[ci].ss = insts[oi].ss; insts[ci].bits = insts[oi].bits; insts[ci].flags = insts[oi].flags;
    insts[ci].fmf = insts[oi].fmf; insts[ci].ty2 = insts[oi].ty2; insts[ci].as_ = insts[oi].as_;
    for k in insts[oi].nmd { inst_set_md(c, md_att[insts[oi].md + 2 * k], md_att[insts[oi].md + 2 * k + 1]); }
    return c;
}

// Instruction::dropUBImplyingAttrsAndMetadata() for a load/store
fn sr_drop_ub_md(i: i32) {
    let keep: const u8[:][] = ["annotation", "range", "nonnull", "align", "fpmath", "prof", "mem.cache_hint", "nofpclass", "DIAssignID"];
    let ii = inst_of(i);
    let at = insts[ii].md;
    var w: i32 = 0;
    for k in insts[ii].nmd {
        let kind = md_att[at + 2 * k];
        var kp = kind == 0;
        let nm = sbytes(md_kind_names[kind]);
        for n in keep { if n == nm { kp = true; } }
        if kp { md_att[at + 2 * w] = kind; md_att[at + 2 * w + 1] = md_att[at + 2 * k + 1]; w++; }
    }
    insts[ii].nmd = w;
}

// SplitBlockAndInsertIfThenElse(Cond, SplitBefore, then?, else?) -> (head, tail, then, else)
fn sr_split_if_then_else(cond: i32, at: i32, want_then: bool, want_else: bool, prof: i32) -> i32, i32, i32, i32 {
    let head = inst_parent(at);
    let fv = block_func(head);
    let dl = inst_get_md(at, 0);
    let tail = split_block(head, at, "");
    let hbr = block_terminator(head);
    if dl >= 0 { inst_set_md(hbr, 0, dl); }
    var tb = tail;
    var fb = tail;
    var thenb: i32 = -1;
    var elseb: i32 = -1;
    if want_then {
        thenb = create_block_after(fv, block_prev(tail), "");
        let br = create_inst(OP_BR, T_VOID, [tail]);
        block_append_inst(thenb, br);
        if dl >= 0 { inst_set_md(br, 0, dl); }
        tb = thenb;
    }
    if want_else {
        elseb = create_block_after(fv, block_prev(tail), "");
        let br = create_inst(OP_BR, T_VOID, [tail]);
        block_append_inst(elseb, br);
        if dl >= 0 { inst_set_md(br, 0, dl); }
        fb = elseb;
    }
    // CondBrInst::Create(Cond, TrueBlock, FalseBlock) replacing the head's branch (ReplaceInstWithInst)
    let nb = create_inst(OP_CONDBR, T_VOID, [cond, tb, fb]);
    if prof >= 0 { inst_set_md(nb, md_kind_id("prof"), prof); }
    inst_insert_before(nb, hbr);
    let odl = inst_get_md(hbr, 0);
    if odl >= 0 && inst_get_md(nb, 0) < 0 { inst_set_md(nb, 0, odl); }
    sr_erase(hbr);
    dt_invalidate(fv, DT_DOM);
    dt_invalidate(fv, DT_POST);
    return head, tail, thenb, elseb;
}

// rewriteMemOpOfSelect(SI, I, Spec, DTU)
fn rewrite_mem_op_of_select(si: i32, i: i32, spec: i32) {
    let prof = inst_get_md(si, md_kind_id("prof"));
    var head: i32 = -1;
    var tail: i32 = -1;
    if spec <= 0 {
        let h, t, a, b = sr_split_if_then_else(op(si, 0), i, true, true, prof);
        head = h; tail = t;
    } else {
        let h, t, a, b = sr_split_if_then_else(op(si, 0), i, true, false, prof);
        head = h; tail = t;
        if (spec & 1) != 0 {
            // CondBrInst::swapSuccessors (with !prof swapped)
            let hb = block_terminator(head);
            let pk = md_kind_id("prof");
            let pm = inst_get_md(hb, pk);
            if pm >= 0 {
                // swapProfMetadata: the two branch weights trade places
                let n = mds[pm].nops as i64;
                let o0 = md_op(pm, 0);
                if n >= 3 && o0 >= 0 && mds[o0].kind == MK_STRING && sbytes(mds[o0].extra) == "branch_weights" {
                    var ops: i32[>..<] = [];
                    for j in n - 2 { ops.push(md_op(pm, j)); }
                    ops.push(md_op(pm, n - 1));
                    ops.push(md_op(pm, n - 2));
                    inst_set_md(hb, pk, md_get(MK_TUPLE, -1, ops, false));
                }
            }
            let s0 = op(hb, 1);
            let s1 = op(hb, 2);
            set_op(hb, 1, s1);
            set_op(hb, 2, s0);
        }
    }
    let hbi = block_terminator(head);
    var nm: u8[>..] = [];
    nm.append(val_name(head)); nm.append(".cont");
    set_name(tail, nm);
    let is_load = iop(i) == OP_LOAD;
    var pn: i32 = -1;
    if is_load {
        pn = new_inst(OP_PHI, vals[i].ty, 2);
        vals[pn].nops = 0;
        inst_insert_before(pn, i);
    }
    for k in term_nsucc(hbi) {
        let succ = term_succ(hbi, k);
        let is_then = succ == term_succ(hbi, 0);
        let idx: i64 = if is_then { 0 } else { 1 };
        let nmb = if succ == tail { head } else { succ };
        let c = sr_clone_ldst(i);
        if nmb != head {
            nm.clear(); nm.append(val_name(head)); nm.append(if is_then { ".then" } else { ".else" });
            set_name(nmb, nm);
        } else {
            sr_drop_ub_md(c);
        }
        m2r_insert_before_adopting(c, block_terminator(nmb));
        let ptr = op(si, 1 + idx);
        set_op(c, if is_load { 0 } else { 1 }, ptr);
        if is_load {
            nm.clear(); nm.append(val_name(i)); nm.append(if is_then { ".then" } else { ".else" }); nm.append(".val");
            set_name(c, nm);
            phi_add_incoming(pn, c, nmb);
        }
    }
    if is_load {
        // PN->takeName(&I)
        var n2: u8[>..] = [];
        n2.append(val_name(i));
        set_name(i, "");
        if n2.len > 0 { set_name(pn, n2); }
        sr_rauw(i, pn);
    }
}
