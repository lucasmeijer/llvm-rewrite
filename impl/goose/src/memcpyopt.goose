// MemCpyOpt: port of llvm/lib/Transforms/Scalar/MemCpyOptimizer.cpp (MemsetRanges, tryMergingIntoMemset, moveUp,
// processStore / processStoreOfLoad, processMemSet, performCallSlotOptzn, processMemCpyMemCpyDependence,
// processMemSetMemCpyDependence, performMemCpyToMemSetOptzn, performStackMoveOptzn, processMemCpy,
// processMemMove / isMemMoveMemSetDependency, processByValArgument, processImmutArgument, iterateOnFunction),
// with Value::getPointerOffsetFrom (llvm/lib/IR/Value.cpp), PostDominatorTree::dominates(Instruction,
// Instruction) (llvm/lib/Analysis/PostDominators.cpp) and the IRBuilder calls it makes (CreateMemSet/MemCpy/
// MemMove/MemCpyInline, CreatePtrAdd, CreateZExt/ICmp/Sub/Select with ConstantFolder semantics).
//
// MemCpyOptPass's members are the mc_* globals. The EarliestEscapeAnalysis lives for the whole run (ea_begin
// once); every `BatchAAResults BAA(*AA, EEA)` is a fresh CA_EARLIEST query info, `AA->...` calls are the
// aa_*_simple entry points. BasicBlock::iterator BBI is mc_bbi (-1 = end()).
// Not ported (fail loudly): mergeDIAssignID of stores with DIAssignID attachments.
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
import analyses;
import flags;
import tli;
import local;
import pm;
import vt;
import apint;
import constfold;
import autoupgrade;
import memloc;
import aautil;
import aa;
import capture;
import memoryssa;
import mssaupdater;
import speculate;
import instsimplify;
import cfgutil;
import ic_builder;
import ic_loadstorealloca;
import memintr;

var mc_fn: i32 = -1;
var mc_bbi: i32 = -1;
var mc_without_libcalls: bool = false;

fn mc_not_ported(what: const u8[:]) { fatal(str("MemCpyOpt: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// IRBuilder<> (ConstantFolder): insertion before an instruction, the current debug location

var mcb_pos: i32 = -1;
var mcb_dl: i32 = -1;
fn mcb_at(pos: i32) { mcb_pos = pos; mcb_dl = inst_get_md(pos, 0); }
fn mcb_insert(iv: i32) -> i32 {
    inst_insert_before(iv, mcb_pos);
    if mcb_dl >= 0 { inst_set_md(iv, 0, mcb_dl); }
    return iv;
}
fn mcb_align_set(al: u64) -> i32 { if al == 0 { 0 } else { aset_get([attr_int(AK_Alignment, al)]) } }
// CreateIntrinsic(ID, Tys, Args) + setDest/SourceAlignment
fn mcb_intrinsic(id: i64, ov: const i32[:], argsv: const i32[:], a0: u64, a1: u64) -> i32 {
    let f = au_get_declaration(id, ov);
    let fty = globs[glob_of(f)].vty;
    var opsv: i32[>..<] = [];
    for a in argsv { opsv.push(a); }
    opsv.push(f);
    let c = create_inst(OP_CALL, ty_fn_ret(fty), opsv);
    insts[inst_of(c)].ty2 = fty;
    if a0 != 0 || a1 != 0 {
        var sets: i32[>..<] = [];
        sets.push(0);
        sets.push(0);
        sets.push(mcb_align_set(a0));
        if a1 != 0 { sets.push(mcb_align_set(a1)); }
        insts[inst_of(c)].attrs = alist_get(sets);
    }
    return mcb_insert(c);
}
fn mcb_i1(b: bool) -> i32 { c_int(ty_int(1), if b { 1 } else { 0 }) }
fn mcb_i64(x: i64) -> i32 { c_int(ty_int(64), x) }
// CreateTypeSize(i64, TypeSize)
fn mcb_type_size(n: u64, scalable: bool) -> i32 {
    let t = ty_int(64);
    if !scalable || n == 0 { return c_int(t, n as! i64); }
    let vs = mcb_intrinsic(IID_vscale, [t], [], 0, 0);
    if n == 1 { return vs; }
    let m = create_inst(OP_MUL, t, [vs, c_int(t, n as! i64)]);
    insts[inst_of(m)].flags = FL_NUW;
    return mcb_insert(m);
}
// CreateMemSet(Ptr, Val, Size, MaybeAlign, isVolatile)
fn mcb_memset(p: i32, v: i32, size: i32, al: u64, vol: bool) -> i32 {
    let t1: i32 = vals[p].ty;
    let t2: i32 = vals[size].ty;
    let vc = mcb_i1(vol);
    return mcb_intrinsic(IID_memset, [t1, t2], [p, v, size, vc], al, 0);
}
// CreateMemTransferInst(IntrID, Dst, DstAlign, Src, SrcAlign, Size, isVolatile)
fn mcb_memtransfer(id: i64, d: i32, dal: u64, s: i32, sal: u64, size: i32, vol: bool) -> i32 {
    let t1: i32 = vals[d].ty;
    let t2: i32 = vals[s].ty;
    let t3: i32 = vals[size].ty;
    let f = au_get_declaration(id, [t1, t2, t3]);
    let fty = globs[glob_of(f)].vty;
    let vc = mcb_i1(vol);
    let c = create_inst(OP_CALL, ty_fn_ret(fty), [d, s, size, vc, f]);
    insts[inst_of(c)].ty2 = fty;
    if dal != 0 || sal != 0 {
        let s0 = mcb_align_set(dal);
        let s1 = mcb_align_set(sal);
        let sets: i32[4] = [0, 0, s0, s1];
        insts[inst_of(c)].attrs = alist_get(sets);
    }
    return mcb_insert(c);
}
// CreateGEP(i8, Ptr, Offset, "", NW) with FoldGEP
fn mcb_ptr_add(p: i32, off: i32, inbounds: bool) -> i32 {
    let fl: u8 = if inbounds { GEP_INBOUNDS | GEP_NUSW } else { 0 };
    if is_constant(p) && is_constant(off) { return ce_gep(ty_int(8), p, [off], fl, -1); }
    let g = create_inst(OP_GEP, vals[p].ty, [p, off]);
    insts[inst_of(g)].ty2 = ty_int(8);
    insts[inst_of(g)].flags = fl;
    return mcb_insert(g);
}
fn mcb_zext(v: i32, t: i32) -> i32 {
    if vals[v].ty == t { return v; }
    if is_constant(v) { return ce_cast(OP_ZEXT, v, t); }
    return mcb_insert(create_inst(OP_ZEXT, t, [v]));
}
fn mcb_icmp(pred: u8, a: i32, b: i32) -> i32 {
    if is_constant(a) && is_constant(b) {
        let f = cf_compare(pred as i64, a, b);
        if f >= 0 { return f; }
    }
    let rt = if ty_is_vector(vals[a].ty) { ty_vector(ty_int(1), ty_count(vals[a].ty), ty_kind(vals[a].ty) == TK_SVEC) } else { ty_int(1) };
    let c = create_inst(OP_ICMP, rt, [a, b]);
    insts[inst_of(c)].pred = pred;
    return mcb_insert(c);
}
fn mcb_sub(a: i32, b: i32) -> i32 {
    if is_constant(a) && is_constant(b) { return ce_binop(OP_SUB, a, b, 0); }
    return mcb_insert(create_inst(OP_SUB, vals[a].ty, [a, b]));
}
fn mcb_select(c: i32, a: i32, b: i32) -> i32 {
    if is_constant(c) && is_constant(a) && is_constant(b) {
        let f = cf_select(c, a, b);
        if f >= 0 { return f; }
    }
    return mcb_insert(create_inst(OP_SELECT, vals[a].ty, [c, a, b]));
}

// ---------------------------------------------------------------------------------------------
// Helpers

// copyMetadata(Src, {MD_DIAssignID})
fn mc_copy_assign_id(dst: i32, src: i32) {
    let k = md_kind_id("DIAssignID");
    let m = inst_get_md(src, k);
    if m >= 0 { inst_set_md(dst, k, m); }
}
fn mc_check_no_assign_id(i: i32) {
    if inst_get_md(i, md_kind_id("DIAssignID")) >= 0 { mc_not_ported("mergeDIAssignID"); }
}

// Value::getPointerOffsetFrom(Other, DL)
fn mc_offset_from_index(g: i32, idx: i64) -> bool, i64 {
    var t = gep_src_ty(g);
    // the type the operand at position k indexes into (gep_type_iterator)
    var off: i64 = 0;
    for k in 1..nops(g) {
        let ix = op(g, k);
        var nt = t;
        var is_struct = false;
        var stride: i64 = 0;
        var stride_scalable = false;
        if k == 1 { stride = dl_alloc_size(t); stride_scalable = ty_size_scalable(t); }
        else if ty_is_struct(t) { is_struct = true; }
        else { nt = types[t].a; stride = dl_gep_stride(t, nt); stride_scalable = ty_size_scalable(nt); }
        if k >= idx {
            if vals[ix].kind != VK_CINT || ty_is_vector(vals[ix].ty) { return false, 0; }
            if !cint_is_zero(ix) {
                if is_struct { off = ((off as! u64) + (dl_struct_offset(t, cint_lo(ix) as! i64) as! u64)) as! i64; }
                else {
                    if stride_scalable { return false, 0; }
                    off = ((off as! u64) + (stride as! u64) * (cint_sext(ix) as! u64)) as! i64;
                }
            }
        }
        if is_struct {
            if vals[ix].kind != VK_CINT { return false, 0; }
            nt = ty_field(t, cint_lo(ix) as! i64);
        }
        t = nt;
    }
    return true, off;
}
fn mc_pointer_offset_from(v: i32, other: i32) -> bool, i64 {
    let p1 = strip_and_accumulate_offsets(other, true, false, false);
    let o1 = vt_off;
    let p2 = strip_and_accumulate_offsets(v, true, false, false);
    let o2 = vt_off;
    if p1 == p2 { return true, o2 - o1; }
    if opcode_of(p1) != OP_GEP || opcode_of(p2) != OP_GEP || op(p1, 0) != op(p2, 0) || gep_src_ty(p1) != gep_src_ty(p2) {
        return false, 0;
    }
    var idx: i64 = 1;
    while idx != nops(p1) && idx != nops(p2) {
        if op(p1, idx) != op(p2, idx) { break; }
        idx++;
    }
    let ok1, i1 = mc_offset_from_index(p1, idx);
    let ok2, i2 = mc_offset_from_index(p2, idx);
    if !ok1 || !ok2 { return false, 0; }
    return true, i2 - i1 + o2 - o1;
}

// AllocaInst::getAllocationSize(DL): (ok, size, scalable)
fn mc_alloca_size(a: i32) -> bool, u64, bool {
    let t = insts[inst_of(a)].ty2;
    let sz = dl_alloc_size(t) as u64;
    let sc = ty_size_scalable(t);
    let n = op(a, 0);
    let is_array = !(vals[n].kind == VK_CINT && cint_lo(n) == 1 && (ty_bits(vals[n].ty) <= 64 || cint_hi(n) == 0));
    if is_array {
        if vals[n].kind != VK_CINT || ty_is_vector(vals[n].ty) { return false, 0, false; }
        if ty_bits(vals[n].ty) > 64 && cint_hi(n) != 0 { return false, 0, false; }
        let cnt = cint_lo(n);
        if cnt != 0 && sz > 0xFFFFFFFFFFFFFFFF / cnt { return false, 0, false; }
        return true, sz * cnt, false;
    }
    return true, sz, sc;
}
fn mc_alloca_align(a: i32) -> u64 { let x = insts[inst_of(a)].align; return if x == 0 { 1 } else { (1 as u64) << ((x - 1) as u64) }; }
fn mc_set_alloca_align(a: i32, al: u64) { insts[inst_of(a)].align = ic::icb_align_code(al as! i64); }
fn mc_ldst_align(i: i32) -> u64 { let x = insts[inst_of(i)].align; return if x == 0 { 1 } else { (1 as u64) << ((x - 1) as u64) }; }
// commonAlignment(A, Offset) = MinAlign(A, Offset)
fn mc_common_align(a: u64, off: u64) -> u64 { let x = a | off; return x & ((0 as u64) - x); }

fn mc_is_simple(i: i32) -> bool { let x = insts[inst_of(i)]; return x.ord == 0 && (x.bits & 1) == 0; }
fn mc_only_inaccessible(i: i32) -> bool { me_without(call_memory_effects(i), LOC_INACCESSIBLE) == 0 }

// PostDominatorTree::dominates(const Instruction *I1, const Instruction *I2)
fn mc_pdt_dominates_inst(i1: i32, i2: i32) -> bool {
    let b1 = inst_parent(i1);
    let b2 = inst_parent(i2);
    if b1 != b2 { return dt_dominates_block(DT_POST, b1, b2); }
    if iop(i1) == OP_PHI && iop(i2) == OP_PHI { return false; }
    var x = block_first(b1);
    while x != i1 && x != i2 { x = inst_next(x); }
    return x == i2;
}

// MemCpyOptPass::eraseInstruction
fn mc_erase(i: i32) {
    msu_remove_inst_access(i, false);
    ea_remove_instruction(i);
    inst_erase_from_parent(i);
}

// mayBeVisibleThroughUnwinding(V, Start, End)
fn mc_may_be_visible_through_unwinding(v: i32, start: i32, end: i32) -> bool {
    if func_has_fn_attr(inst_func(start), AK_NoUnwind) { return false; }
    let nv, req = aa_is_not_visible_on_unwind(get_underlying_object(v, 10));
    if nv && !req { return false; }
    var x = start;
    while x != end && x >= 0 {
        if inst_may_throw(x) { return true; }
        x = inst_next(x);
    }
    return false;
}

// accessedBetween(AA, Loc, Start, End, SkippedLifetimeStart) -> (accessed, skipped)
fn mc_accessed_between(q: i32, loc: ML, start: i32, end: i32, want_skip: bool) -> bool, i32 {
    var skipped: i32 = -1;
    var a = macc[start].next;
    while a != end && a >= 0 {
        let i = macc[a].inst;
        if mr_any(aa_inst_loc_mr(i, loc, q)) {
            if inst_iid(i) == IID_lifetime_start && want_skip && skipped < 0 {
                skipped = i;
                a = macc[a].next;
                continue;
            }
            return true, skipped;
        }
        a = macc[a].next;
    }
    return false, skipped;
}

// writtenBetween(MSSA, AA, Loc, Start, End)
fn mc_written_between(q: i32, loc: ML, start: i32, end: i32) -> bool {
    if macc[end].kind == MAK_USE {
        if macc[start].bb != macc[end].bb { return true; }
        var a = macc[start].next;
        while a != end && a >= 0 {
            if macc[a].kind != MAK_USE {
                if mr_is_mod(aa_inst_loc_mr(macc[a].inst, loc, q)) { return true; }
            }
            a = macc[a].next;
        }
        return false;
    }
    let clob = mssa_get_clobbering_loc(ma_def(end), loc, q);
    return !mssa_dominates(clob, start);
}

// ---------------------------------------------------------------------------------------------
// MemsetRanges

struct MsRange { start: i64, end: i64, ptr: i32, align: u64, head: i32, tail: i32, n: i64 }
var mc_rs: MsRange[>..<];
var mc_st_inst: i32[>..<];
var mc_st_next: i32[>..<];

fn mc_rs_push_store(r: i64, i: i32) {
    let s = mc_st_inst.len as i32;
    mc_st_inst.push(i);
    mc_st_next.push(-1);
    if mc_rs[r].tail >= 0 { mc_st_next[mc_rs[r].tail] = s; } else { mc_rs[r].head = s; }
    mc_rs[r].tail = s;
    mc_rs[r].n += 1;
}
// MemsetRanges::addRange(Start, Size, Ptr, Alignment, Inst)
fn mc_add_range(start: i64, size: i64, p: i32, al: u64, inst: i32) {
    let end = start + size;
    // partition_point: the first range with End >= Start
    var i: i64 = 0;
    while i < mc_rs.len && mc_rs[i].end < start { i++; }
    if i == mc_rs.len || end < mc_rs[i].start {
        mc_rs.push(MsRange { start: 0, end: 0, ptr: -1, align: 0, head: -1, tail: -1, n: 0 });
        var j = mc_rs.len - 1;
        while j > i { mc_rs[j] = mc_rs[j - 1]; j--; }
        mc_rs[i] = MsRange { start: start, end: end, ptr: p, align: al, head: -1, tail: -1, n: 0 };
        mc_rs_push_store(i, inst);
        return;
    }
    mc_rs_push_store(i, inst);
    if mc_rs[i].start <= start && mc_rs[i].end >= end { return; }
    if start < mc_rs[i].start {
        mc_rs[i].start = start;
        mc_rs[i].ptr = p;
        mc_rs[i].align = al;
    }
    if end > mc_rs[i].end {
        mc_rs[i].end = end;
        while i + 1 < mc_rs.len && end >= mc_rs[i + 1].start {
            // merge the next range in
            let nx = mc_rs[i + 1];
            if nx.head >= 0 {
                if mc_rs[i].tail >= 0 { mc_st_next[mc_rs[i].tail] = nx.head; } else { mc_rs[i].head = nx.head; }
                mc_rs[i].tail = nx.tail;
                mc_rs[i].n += nx.n;
            }
            if nx.end > mc_rs[i].end { mc_rs[i].end = nx.end; }
            var j = i + 1;
            while j + 1 < mc_rs.len { mc_rs[j] = mc_rs[j + 1]; j++; }
            mc_rs.pop();
        }
    }
}
fn mc_add_store(off: i64, si: i32) {
    let sz = dl_store_size(vals[op(si, 0)].ty);
    mc_add_range(off, sz, op(si, 1), mc_ldst_align(si), si);
}
fn mc_add_memset(off: i64, msi: i32) {
    let sz = cint_lo(mi_length(msi)) as! i64;
    mc_add_range(off, sz, mi_dest(msi), mi_dest_align(msi), msi);
}

// MemsetRange::isProfitableToUseMemset
fn mc_profitable(r: i64) -> bool {
    let n = mc_rs[r].n;
    if n >= 4 || mc_rs[r].end - mc_rs[r].start >= 16 { return true; }
    if n < 2 { return false; }
    var s = mc_rs[r].head;
    while s >= 0 {
        if iop(mc_st_inst[s]) != OP_STORE { return true; }
        s = mc_st_next[s];
    }
    if n == 2 { return false; }
    let bytes = (mc_rs[r].end - mc_rs[r].start) as! u32 as i64;
    var maxw: i64 = 0;
    for w in dl_native { if w > maxw { maxw = w; } }
    var max_int = maxw / 8;
    if max_int == 0 { max_int = 1; }
    let nptr = bytes / max_int;
    let nbyte = bytes % max_int;
    return n > nptr + nbyte;
}

// tryMergingIntoMemset(StartInst, StartPtr, ByteVal): the last memset created or -1
fn mc_try_merging_into_memset(start_inst: i32, start_ptr0: i32, byte_val: i32) -> i32 {
    var start_ptr = start_ptr0;
    if iop(start_inst) == OP_STORE && ty_size_scalable(vals[op(start_inst, 0)].ty) { return -1; }
    mc_rs.clear();
    mc_st_inst.clear();
    mc_st_next.clear();
    var bi = inst_next(start_inst);
    var ins_pt: i32 = -1;
    while bi >= 0 && !is_terminator(bi) {
        let ca = mssa_access_of(bi);
        if ca >= 0 { ins_pt = ca; }
        if is_callbase(bi) && mc_only_inaccessible(bi) { bi = inst_next(bi); continue; }
        let is_st = iop(bi) == OP_STORE;
        let is_ms = mi_is_memset(bi);
        if !is_st && !is_ms {
            if inst_may_write_memory(bi) || inst_may_read_memory(bi) { break; }
            bi = inst_next(bi);
            continue;
        }
        if is_st {
            if !mc_is_simple(bi) { break; }
            let sv = op(bi, 0);
            let st = vals[sv].ty;
            if ty_kind(ty_scalar(st)) == TK_PTR && dl_is_nonintegral_as(ptr_as(st)) { break; }
            if ty_size_scalable(st) { break; }
            let sb = is_bytewise_value(sv);
            if byte_val != sb { break; }
            let ok, off = mc_pointer_offset_from(op(bi, 1), start_ptr);
            if !ok { break; }
            mc_add_store(off, bi);
        } else {
            let l = mi_length(bi);
            if mi_is_volatile(bi) || byte_val != mi_value(bi) || vals[l].kind != VK_CINT || ty_is_vector(vals[l].ty) { break; }
            let ok, off = mc_pointer_offset_from(mi_dest(bi), start_ptr);
            if !ok { break; }
            mc_add_memset(off, bi);
        }
        bi = inst_next(bi);
    }
    if mc_rs.len == 0 { return -1; }
    if iop(start_inst) == OP_STORE { mc_add_store(0, start_inst); } else { mc_add_memset(0, start_inst); }
    mcb_at(bi);
    var amemset: i32 = -1;
    var stores: i32[>..<] = [];
    for r in mc_rs.len {
        if mc_rs[r].n == 1 { continue; }
        if !mc_profitable(r) { continue; }
        start_ptr = mc_rs[r].ptr;
        stores.clear();
        var s = mc_rs[r].head;
        while s >= 0 { stores.push(mc_st_inst[s]); s = mc_st_next[s]; }
        for x in stores { mc_check_no_assign_id(x); }
        amemset = mcb_memset(start_ptr, byte_val, mcb_i64(mc_rs[r].end - mc_rs[r].start), mc_rs[r].align, false);
        if stores.len > 0 {
            let dl = inst_get_md(stores[0], 0);
            if dl >= 0 { inst_set_md(amemset, 0, dl); } else { inst_erase_md(amemset, 0); }
        }
        var nd: i32 = -1;
        if macc[ins_pt].inst == bi { nd = msu_create_access_before(amemset, -1, ins_pt); }
        else { nd = msu_create_access_after(amemset, -1, ins_pt); }
        msu_insert_def(nd, true);
        ins_pt = nd;
        for x in stores { mc_erase(x); }
    }
    return amemset;
}

// ---------------------------------------------------------------------------------------------
// moveUp, processStoreOfLoad, processStore, processMemSet

fn mc_list_has(xs: const i32[:], v: i32) -> bool { for x in xs { if x == v { return true; } } return false; }

// moveUp(SI, P, LI)
fn mc_move_up(si: i32, p: i32, li: i32) -> bool {
    let store_loc = ml_get(si);
    if mr_any(aa_inst_loc_mr_simple(p, store_loc)) { return false; }
    var args: i32[>..<] = [];
    let sbb = inst_parent(si);
    let a0 = op(si, 1);
    if is_inst(a0) && inst_parent(a0) == sbb {
        if a0 == p { return false; }
        if !mc_list_has(args, a0) { args.push(a0); }
    }
    var to_lift: i32[>..<] = [];
    to_lift.push(si);
    var mlocs: ML[>..<] = [];
    mlocs.push(store_loc);
    var calls: i32[>..<] = [];
    let load_loc = ml_get(li);
    var c = inst_prev(si);
    while c != p {
        if !guaranteed_to_transfer(c) { return false; }
        let may_alias = mr_any(aa_inst_loc_mr_simple(c, ml_none()));
        var need = false;
        var ai: i64 = -1;
        for k in args.len { if args[k] == c { ai = k; } }
        if ai >= 0 {
            args[ai] = args[args.len - 1];
            args.pop();
            need = true;
        } else if may_alias {
            for l in mlocs { if mr_any(aa_inst_loc_mr_simple(c, l)) { need = true; break; } }
            if !need {
                for cl in calls { if mr_any(aa_inst_call_mr_simple(c, cl)) { need = true; break; } }
            }
        }
        if !need { c = inst_prev(c); continue; }
        if may_alias {
            if mr_is_mod(aa_inst_loc_mr_simple(c, load_loc)) { return false; }
            else if is_callbase(c) {
                if mr_any(aa_inst_call_mr_simple(p, c)) { return false; }
                calls.push(c);
            } else if iop(c) == OP_LOAD || iop(c) == OP_STORE || iop(c) == OP_VAARG {
                let ml = ml_get(c);
                if mr_any(aa_inst_loc_mr_simple(p, ml)) { return false; }
                mlocs.push(ml);
            } else {
                return false;
            }
        }
        to_lift.push(c);
        for k in nops(c) {
            let x = op(c, k);
            if is_inst(x) && inst_parent(x) == sbb {
                if x == p { return false; }
                if !mc_list_has(args, x) { args.push(x); }
            }
        }
        c = inst_prev(c);
    }
    var ins_pt: i32 = -1;
    let pa = mssa_access_of(p);
    if pa >= 0 {
        ins_pt = macc[pa].prev;
    } else {
        var x = inst_prev(p);
        loop {
            let a = mssa_access_of(x);
            if a >= 0 { ins_pt = a; break; }
            if x == li { break; }
            x = inst_prev(x);
        }
    }
    var k = to_lift.len - 1;
    while k >= 0 {
        let i = to_lift[k];
        k--;
        inst_move_before(i, p);
        let ma = mssa_access_of(i);
        if ma >= 0 {
            msu_move_after(ma, ins_pt);
            ins_pt = ma;
        }
    }
    return true;
}

// processStoreOfLoad(SI, LI, DL, BBI)
fn mc_process_store_of_load(si: i32, li: i32) -> bool {
    if !mc_is_simple(li) || !mc_has_one_use(li) || inst_parent(li) != inst_parent(si) { return false; }
    let q = aq_push(CA_EARLIEST);
    let r = mc_process_store_of_load_q(si, li, q);
    aq_pop(q);
    return r;
}
fn mc_process_store_of_load_q(si: i32, li: i32, q: i32) -> bool {
    let t = vals[li].ty;
    if ty_is_aggregate(t) && (mc_without_libcalls || (tli_has(LF_memcpy as i32) && tli_has(LF_memmove as i32))) {
        let load_loc = ml_get(li);
        var p = si;
        var x = inst_next(li);
        while x != si {
            if mr_is_mod(aa_inst_loc_mr(x, load_loc, q)) { p = x; break; }
            x = inst_next(x);
        }
        if p == si || mc_move_up(si, p, li) {
            var use_memmove = false;
            if mr_is_mod(aa_inst_loc_mr_simple(si, load_loc)) { use_memmove = true; }
            mcb_at(p);
            let size = mcb_type_size(dl_store_size(t) as u64, ty_size_scalable(t));
            let id = if use_memmove { IID_memmove } else { IID_memcpy };
            let m = mcb_memtransfer(id, op(si, 1), mc_ldst_align(si), op(li, 0), mc_ldst_align(li), size, false);
            mc_copy_assign_id(m, si);
            let last = mssa_access_of(si);
            let na = msu_create_access_after(m, -1, last);
            msu_insert_def(na, true);
            mc_erase(si);
            mc_erase(li);
            mc_bbi = m;
            return true;
        }
    }
    // call slot forwarding through a load/store pair
    let al = min(mc_ldst_align(si), mc_ldst_align(li));
    let sty = vals[op(si, 0)].ty;
    if mc_call_slot(li, si, strip_ptr_casts(op(si, 1)), strip_ptr_casts(op(li, 0)), dl_store_size(sty) as u64,
                    ty_size_scalable(sty), al, q, -1) {
        mc_erase(si);
        mc_erase(li);
        return true;
    }
    if mc_stack_move(li, si, op(si, 1), op(li, 0), dl_store_size(t) as u64, ty_size_scalable(t), q) {
        mc_bbi = inst_next(si);
        mc_erase(si);
        mc_erase(li);
        return true;
    }
    return false;
}

fn mc_has_one_use(v: i32) -> bool { let u = vals[v].first_use; return u >= 0 && uses[u].next < 0; }

// processStore(SI, BBI)
fn mc_process_store(si: i32) -> bool {
    if !mc_is_simple(si) { return false; }
    if inst_get_md(si, md_kind_id("nontemporal")) >= 0 { return false; }
    let sv = op(si, 0);
    let st = vals[sv].ty;
    if ty_kind(ty_scalar(st)) == TK_PTR && dl_is_nonintegral_as(ptr_as(st)) { return false; }
    if is_inst_op(sv, OP_LOAD) { return mc_process_store_of_load(si, sv); }
    if !(tli_has(LF_memset as i32) || mc_without_libcalls) { return false; }
    let bv = is_bytewise_value(sv);
    if bv < 0 { return false; }
    let i = mc_try_merging_into_memset(si, op(si, 1), bv);
    if i >= 0 { mc_bbi = i; return true; }
    if !ty_is_aggregate(st) { return false; }
    if ty_size_scalable(st) { return false; }
    mcb_at(si);
    let m = mcb_memset(op(si, 1), bv, mcb_i64(dl_store_size(st)), mc_ldst_align(si), false);
    mc_copy_assign_id(m, si);
    let sd = mssa_access_of(si);
    let na = msu_create_access_before(m, -1, sd);
    msu_insert_def(na, false);
    mc_erase(si);
    mc_bbi = m;
    return true;
}

// processMemSet(MSI, BBI)
fn mc_process_memset(msi: i32) -> bool {
    let l = mi_length(msi);
    if vals[l].kind == VK_CINT && !ty_is_vector(vals[l].ty) && !mi_is_volatile(msi) {
        let i = mc_try_merging_into_memset(msi, mi_dest(msi), mi_value(msi));
        if i >= 0 { mc_bbi = i; return true; }
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// performCallSlotOptzn

// isDereferenceablePointer(V, APInt(64, Size), SimplifyQuery(DL, DT, AC, CxtI))
fn mc_deref_pointer(v: i32, size: u64, cxt: i32) -> bool {
    spec_use_dt = true;
    spec_use_tli = false;
    spec_use_ac = true;
    spec_cxt = cxt;
    spec_visited.clear();
    let r = spec_deref_aligned(v, 1, ap_u64(size, 64), 16);
    spec_use_dt = false;
    spec_use_ac = false;
    spec_cxt = -1;
    return r;
}

// performCallSlotOptzn(cpyLoad, cpyStore, cpyDest, cpySrc, cpySize, cpyDestAlign, BAA, GetC); call0 >= 0 is the
// call of the memcpy form, -1 = GetC of the load/store form (the load's clobber)
fn mc_call_slot(cpy_load: i32, cpy_store: i32, cpy_dest: i32, cpy_src: i32, cpy_size: u64, scalable: bool,
                cpy_dest_align: u64, q: i32, call0: i32) -> bool {
    if scalable { return false; }
    if !is_inst_op(cpy_src, OP_ALLOCA) { return false; }
    let src_alloca = cpy_src;
    let ok, src_size, sc = mc_alloca_size(src_alloca);
    if !ok || sc { return false; }
    if cpy_size < src_size { return false; }
    var c = call0;
    if c < 0 {
        let lc = mssa_get_clobbering(mssa_access_of(cpy_load), q);
        if lc >= 0 && ma_is_use_or_def(lc) && !mssa_is_live(lc) {
            let mi = macc[lc].inst;
            if is_inst_op(mi, OP_CALL) { c = mi; }
        }
    }
    if c < 0 { return false; }
    let cf = called_function(c);
    if cf >= 0 && func_iid(cf) == IID_lifetime_start { return false; }
    if inst_parent(c) != inst_parent(cpy_store) { return false; }
    let dest_loc = if iop(cpy_store) == OP_STORE { ml_get(cpy_store) } else { ml_for_dest(cpy_store) };
    let acc, skipped = mc_accessed_between(q, dest_loc, mssa_access_of(c), mssa_access_of(cpy_store), true);
    if acc { return false; }
    if skipped >= 0 {
        let la = op(skipped, 0);
        if is_inst(la) && inst_parent(la) == inst_parent(c) && comes_before(c, la) { return false; }
    }
    let wr, expl = aa_is_writable_object(get_underlying_object(cpy_dest, 10));
    if !wr || !mc_deref_pointer(cpy_dest, cpy_size, c) { return false; }
    if mc_may_be_visible_through_unwinding(cpy_dest, c, cpy_store) { return false; }
    let src_align = mc_alloca_align(src_alloca);
    let dest_ok_align = src_align <= cpy_dest_align;
    if !dest_ok_align && !is_inst_op(cpy_dest, OP_ALLOCA) { return false; }
    // the source is only used by the call and the copy
    var ul: i32[>..<] = [];
    var u = vals[src_alloca].first_use;
    var tmp: i32[>..<] = [];
    while u >= 0 { tmp.push(uses[u].user); u = uses[u].next; }
    for x in tmp { ul.push(x); }
    while ul.len > 0 {
        let us = ul.pop();
        if is_inst_op(us, OP_ADDRSPACECAST) {
            var u2 = vals[us].first_use;
            while u2 >= 0 { ul.push(uses[u2].user); u2 = uses[u2].next; }
            continue;
        }
        if inst_is_lifetime_start_or_end(us) { continue; }
        if us != c && us != cpy_load { return false; }
    }
    var src_captured = false;
    for k in cb_nargs(c) {
        if strip_ptr_casts(cb_arg(c, k)) == cpy_src && cb_capture_info(c, k) != 0 { src_captured = true; }
    }
    if src_captured {
        let dobj = get_underlying_object(cpy_dest, 10);
        if !aa_is_identified_function_local(dobj) ||
           cc_anything(ct_may_be_captured_before(dobj, true, c, true, CC_ALL, CT_STOP_ANY, false)) { return false; }
        let src_loc = ml_make(src_alloca, ls_precise(src_size));
        var i = inst_next(c);
        while i >= 0 {
            if inst_iid(i) == IID_lifetime_end && cb_arg(i, 0) == src_alloca { break; }
            if iop(i) == OP_RET { break; }
            if i == cpy_load { i = inst_next(i); continue; }
            if mr_any(aa_inst_loc_mr(i, src_loc, q)) || is_terminator(i) { return false; }
            i = inst_next(i);
        }
    }
    var need_move_gep = false;
    if !dt_value_dominates_inst(cpy_dest, c) {
        if is_inst_op(cpy_dest, OP_GEP) && mc_gep_all_constant(cpy_dest) && dt_value_dominates_inst(op(cpy_dest, 0), c) {
            need_move_gep = true;
        } else {
            return false;
        }
    }
    let dws = ml_make(cpy_dest, ls_precise(src_size));
    var mr = aa_inst_loc_mr(c, dws, q);
    if mr_any(mr) { mr = aa_call_captures_before(c, dws, q); }
    if mr_any(mr) { return false; }
    if vals[cpy_src].ty != vals[cpy_dest].ty { return false; }
    for k in cb_nargs(c) {
        let a = cb_arg(c, k);
        if strip_ptr_casts(a) == cpy_src && vals[cpy_src].ty != vals[a].ty { return false; }
    }
    var changed = false;
    for k in cb_nargs(c) {
        if strip_ptr_casts(cb_arg(c, k)) == cpy_src {
            changed = true;
            set_op(c, k, cpy_dest);
        }
    }
    if !changed { return false; }
    if !dest_ok_align {
        let da = cpy_dest;
        mc_set_alloca_align(da, max(mc_alloca_align(da), src_align));
    }
    if need_move_gep { inst_move_before(cpy_dest, c); }
    if skipped >= 0 {
        inst_move_before(skipped, c);
        msu_move_before(mssa_access_of(skipped), mssa_access_of(c));
    }
    cu_combine_metadata(c, cpy_load, true, true);
    if cpy_load != cpy_store { cu_combine_metadata(c, cpy_store, true, true); }
    return true;
}

fn mc_gep_all_constant(g: i32) -> bool {
    for k in 1..nops(g) {
        let x = op(g, k);
        if vals[x].kind != VK_CINT || ty_is_vector(vals[x].ty) { return false; }
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// memcpy-memcpy, memset-memcpy, memcpy-to-memset

// processMemCpyMemCpyDependence(M, MDep, BAA)
fn mc_memcpy_memcpy(m: i32, mdep: i32, q: i32) -> bool {
    if mi_is_volatile(mdep) { return false; }
    if aa_is_must_alias_vals(mi_dest(mdep), mi_source(mdep), q) { return false; }
    var fwd: i64 = 0;
    if mi_source(m) != mi_dest(mdep) {
        let ok, off = mc_pointer_offset_from(mi_source(m), mi_dest(mdep));
        if !ok || off < 0 { return false; }
        fwd = off;
    }
    var copy_len = mi_length(m);
    if fwd != 0 || mi_length(mdep) != copy_len {
        let dl = mi_length(mdep);
        let ml = copy_len;
        if vals[dl].kind != VK_CINT || ty_is_vector(vals[dl].ty) || vals[ml].kind != VK_CINT || ty_is_vector(vals[ml].ty) { return false; }
        if cint_lo(dl) < cint_lo(ml) + (fwd as! u64) {
            if !mc_overread_undef_contents(m, mdep, q) { return false; }
            if cint_lo(dl) <= (fwd as! u64) { return false; }
            copy_len = c_int(vals[copy_len].ty, (cint_lo(dl) - (fwd as! u64)) as! i64);
        }
    }
    mcb_at(m);
    var new_src: i32 = -1;
    let r = mc_memcpy_memcpy_build(m, mdep, q, fwd, copy_len, new_src);
    return r;
}
fn mc_memcpy_memcpy_build(m: i32, mdep: i32, q: i32, fwd: i64, copy_len: i32, new_src0: i32) -> bool {
    var new_src = new_src0;
    var copy_src = mi_source(mdep);
    var src_align = mi_source_align(mdep);
    var mloc = ml_for_source(mdep);
    if mi_length(mdep) != copy_len { mloc.size = ls_precise(cint_lo(copy_len)); }
    if fwd > 0 {
        let ok, dofs = mc_pointer_offset_from(mi_raw_dest(m), mi_raw_source(mdep));
        if ok && dofs == fwd {
            copy_src = mi_dest(m);
        } else {
            copy_src = mcb_ptr_add(copy_src, mcb_i64(fwd), true);
            if is_inst(copy_src) { new_src = copy_src; }
        }
        mloc.ptr = copy_src;
        if src_align != 0 { src_align = mc_common_align(src_align, fwd as! u64); }
    }
    let r = mc_memcpy_memcpy_finish(m, mdep, q, copy_src, src_align, mloc, copy_len);
    // scope_exit CleanupOnRet
    if new_src >= 0 && vals[new_src].first_use < 0 { mc_erase(new_src); }
    return r;
}
fn mc_memcpy_memcpy_finish(m: i32, mdep: i32, q: i32, copy_src: i32, src_align: u64, mloc: ML, copy_len: i32) -> bool {
    if mc_written_between(q, mloc, mssa_access_of(mdep), mssa_access_of(m)) { return false; }
    if aa_is_must_alias_vals(mi_dest(m), copy_src, q) {
        mc_erase(m);
        return true;
    }
    var use_memmove = false;
    if mr_is_mod(aa_inst_loc_mr(m, ml_for_source(mdep), q)) {
        if inst_iid(m) == IID_memcpy_inline { return false; }
        use_memmove = true;
    }
    let vol = mi_is_volatile(m);
    var nm: i32 = -1;
    if use_memmove { nm = mcb_memtransfer(IID_memmove, mi_dest(m), mi_dest_align(m), copy_src, src_align, copy_len, vol); }
    else if inst_iid(m) == IID_memcpy_inline { nm = mcb_memtransfer(IID_memcpy_inline, mi_dest(m), mi_dest_align(m), copy_src, src_align, copy_len, vol); }
    else { nm = mcb_memtransfer(IID_memcpy, mi_dest(m), mi_dest_align(m), copy_src, src_align, copy_len, vol); }
    mc_copy_assign_id(nm, m);
    let last = mssa_access_of(m);
    let na = msu_create_access_after(nm, -1, last);
    msu_insert_def(na, true);
    mc_erase(m);
    return true;
}

// processMemSetMemCpyDependence(MemCpy, MemSet, BAA)
fn mc_memset_memcpy(mc: i32, ms: i32, q: i32) -> bool {
    if !aa_is_must_alias_vals(mi_dest(ms), mi_dest(mc), q) { return false; }
    if mi_is_volatile(ms) { return false; }
    var src_size = mi_length(mc);
    // isKnownNonZero(SrcSize, SimplifyQuery(DL, DT, AC, MemCpy))
    let snt = sq_no_tli;
    sq_no_tli = true;
    kb_cxt = mc;
    let nz = is_known_non_zero(src_size, 0);
    sq_no_tli = snt;
    if !nz { return false; }
    if mr_is_mod(aa_inst_loc_mr(mc, ml_for_source(mc), q)) { return false; }
    let ab, sk = mc_accessed_between(q, ml_for_dest(ms), mssa_access_of(ms), mssa_access_of(mc), false);
    if ab { return false; }
    let dest = mi_raw_dest(mc);
    var dest_size = mi_length(ms);
    if mc_may_be_visible_through_unwinding(dest, ms, mc) { return false; }
    if dest_size == src_size {
        mc_erase(ms);
        return true;
    }
    var align: u64 = 1;
    let a1 = mi_dest_align(ms);
    let a2 = mi_dest_align(mc);
    let dest_align = max(if a1 == 0 { 1 as u64 } else { a1 }, if a2 == 0 { 1 as u64 } else { a2 });
    if dest_align > 1 && vals[src_size].kind == VK_CINT && !ty_is_vector(vals[src_size].ty) {
        align = mc_common_align(dest_align, cint_lo(src_size));
    }
    mcb_at(mc);
    mcb_dl = inst_get_md(ms, 0);
    let dt = vals[dest_size].ty;
    let st = vals[src_size].ty;
    if dt != st {
        if ty_bits(dt) > ty_bits(st) { src_size = mcb_zext(src_size, dt); }
        else { dest_size = mcb_zext(dest_size, st); }
    }
    let ule = mcb_icmp(37, dest_size, src_size);
    let diff = mcb_sub(dest_size, src_size);
    let len = mcb_select(ule, c_null(vals[dest_size].ty), diff);
    if is_inst_op(len, OP_SELECT) && ic::ic_fn_entry_count(mc_fn) != 0 {
        let ops: i32[2] = [md_string("unknown"), md_string("memcpyopt")];
        inst_set_md(len, md_kind_id("prof"), md_get(MK_TUPLE, -1, ops, false));
    }
    let nms = mcb_memset(mcb_ptr_add(dest, src_size, false), op(ms, 1), len, align, false);
    let last = mssa_access_of(mc);
    let na = msu_create_access_before(nms, -1, last);
    msu_insert_def(na, true);
    mc_erase(ms);
    return true;
}

// hasUndefContents(MSSA, AA, V, Def)
fn mc_has_undef_contents(v: i32, def: i32) -> bool {
    if mssa_is_live(def) { return is_inst_op(get_underlying_object(v, 10), OP_ALLOCA); }
    let i = macc[def].inst;
    if inst_iid(i) == IID_lifetime_start {
        let a = get_underlying_object(v, 10);
        if is_inst_op(a, OP_ALLOCA) { return cb_arg(i, 0) == a; }
    }
    return false;
}
// overreadUndefContents(MSSA, MemCpy, MemSrc, BAA)
fn mc_overread_undef_contents(mc: i32, msrc: i32, q: i32) -> bool {
    let loc = ml_for_source(mc);
    let sa = mssa_access_of(msrc);
    let clob = mssa_get_clobbering_loc(ma_def(sa), loc, q);
    if ma_is_def(clob) && mc_has_undef_contents(mi_source(mc), clob) { return true; }
    return false;
}

// performMemCpyToMemSetOptzn(MemCpy, MemSet, BAA)
fn mc_memcpy_to_memset(mc: i32, ms: i32, q: i32) -> bool {
    let ms_size = mi_length(ms);
    var copy_size = mi_length(mc);
    var moff: i64 = 0;
    if mi_source(mc) != mi_dest(ms) {
        let ok, off = mc_pointer_offset_from(mi_source(mc), mi_dest(ms));
        if !ok { return false; }
        moff = off;
    }
    if moff != 0 || ms_size != copy_size {
        let cms = vals[ms_size].kind == VK_CINT && !ty_is_vector(vals[ms_size].ty);
        let ccs = vals[copy_size].kind == VK_CINT && !ty_is_vector(vals[copy_size].ty);
        if !cms || !ccs || moff < 0 || cint_lo(copy_size) + (moff as! u64) > cint_lo(ms_size) {
            if !mc_overread_undef_contents(mc, ms, q) { return false; }
            if cms && ccs {
                let msv = cint_lo(ms_size);
                let mcv = cint_lo(copy_size);
                var ns: u64 = 0;
                if moff < 0 {
                    let o = (0 - moff) as! u64;
                    ns = if mcv <= o { 0 } else { mcv - o };
                } else if moff == 0 {
                    ns = msv;
                } else {
                    ns = if msv <= (moff as! u64) { 0 } else { msv - (moff as! u64) };
                }
                copy_size = c_int(vals[copy_size].ty, ns as! i64);
            } else {
                if moff < 0 { return false; }
            }
        }
    }
    mcb_at(mc);
    var dptr = mi_raw_dest(mc);
    var al = mi_dest_align(mc);
    if moff < 0 {
        dptr = mcb_ptr_add(dptr, mcb_i64(0 - moff), false);
        if al != 0 { al = mc_common_align(al, (0 - moff) as! u64); }
    }
    let nm = mcb_memset(dptr, op(ms, 1), copy_size, al, false);
    let last = mssa_access_of(mc);
    let na = msu_create_access_after(nm, -1, last);
    msu_insert_def(na, true);
    return true;
}

// ---------------------------------------------------------------------------------------------
// performStackMoveOptzn

var mc_sm_markers: i32[>..<];
var mc_sm_aamd: i32[>..<];
var mc_sm_dest_modref: i64 = 0;
var mc_sm_reach: i32[>..<];

// CaptureTrackingWithModRef(AI, ModRefCallback, AddressCaptured) with the callback picked by `which`
// (0 = DestModRefCallback, 1 = SrcModRefCallback) -> (ok, AddressCaptured)
fn mc_sm_track(ai: i32, which: i64, load: i32, store: i32, dloc: ML, sloc: ML, q: i32) -> bool, bool {
    var addr_captured = false;
    var wl: i32[>..<] = [];
    wl.push(ai);
    let max_uses = ct_max_uses();
    var visited: i32[>..<] = [];
    while wl.len > 0 {
        let i = wl.pop();
        var u = vals[i].first_use;
        while u >= 0 {
            let nu = uses[u].next;
            let ui = uses[u].user;
            if visited.len >= max_uses { return false, addr_captured; }
            if mc_list_has(visited, u) { u = nu; continue; }
            visited.push(u);
            let ci = ct_use_capture_kind(u, ai);
            if cc_any_provenance(ci.use_cc) { return false, addr_captured; }
            if (ci.use_cc & CC_ADDRESS) != 0 { addr_captured = true; }
            if inst_may_read_or_write_memory(ui) {
                if inst_is_lifetime_start_or_end(ui) {
                    mc_sm_markers.push(ui);
                    u = nu;
                    continue;
                }
                if !mc_list_has(mc_sm_aamd, ui) { mc_sm_aamd.push(ui); }
                var ok = true;
                if which == 0 {
                    if ui != store {
                        let res = aa_inst_loc_mr(ui, dloc, q);
                        mc_sm_dest_modref |= res;
                        if mr_any(res) {
                            if inst_parent(ui) == inst_parent(store) {
                                let bb = inst_parent(ui);
                                if comes_before(ui, store) { ok = false; }
                                else if func_entry(block_func(bb)) != bb {
                                    for k in block_nsucc(bb) { mc_sm_reach.push(block_succ(bb, k)); }
                                }
                            } else {
                                mc_sm_reach.push(inst_parent(ui));
                            }
                        }
                    }
                } else {
                    if !(mc_pdt_dominates_inst(load, ui) || ui == load || ui == store) {
                        let res = aa_inst_loc_mr(ui, sloc, q);
                        if (mr_is_mod(mc_sm_dest_modref) && mr_is_ref(res)) || (mr_is_ref(mc_sm_dest_modref) && mr_is_mod(res)) { ok = false; }
                    }
                }
                if !ok { return false, addr_captured; }
            }
            if cc_anything(ci.result_cc) { wl.push(ui); }
            u = nu;
        }
    }
    return true, addr_captured;
}

fn mc_stack_move(load: i32, store: i32, dptr: i32, sptr: i32, size: u64, scalable: bool, q: i32) -> bool {
    let da = get_underlying_object(dptr, 10);
    if !is_inst_op(da, OP_ALLOCA) { return false; }
    let sa = get_underlying_object(sptr, 10);
    if !is_inst_op(sa, OP_ALLOCA) { return false; }
    if sa == da { return false; }
    if ptr_as(vals[sa].ty) != ptr_as(vals[da].ty) { return false; }
    if !ml_is_static_alloca(sa) || !ml_is_static_alloca(da) { return false; }
    let dok, doff = mc_pointer_offset_from(dptr, da);
    if !dok { return false; }
    let sok, soff = mc_pointer_offset_from(sptr, sa);
    if !sok || soff < doff || soff < 0 { return false; }
    if ((soff - doff) as! u64) % mc_alloca_align(da) != 0 { return false; }
    let ok1, ssize, ssc = mc_alloca_size(sa);
    let ok2, dsize, dsc = mc_alloca_size(da);
    if !ok1 || !ok2 { return false; }
    if ssize != dsize || ssc != dsc {
        if ssc || dsc { return false; }
    }
    if size != dsize || scalable != dsc || doff != 0 { return false; }
    if soff != 0 {
        if scalable || (soff as! u64) + size > ssize { return false; }
    }
    let move_src = !dt_value_dominates_inst(sa, da);
    if move_src {
        if !dt_value_dominates_inst(da, sa) { return false; }
    }
    mc_sm_markers.clear();
    mc_sm_aamd.clear();
    mc_sm_reach.clear();
    mc_sm_dest_modref = MR_NO;
    let dloc = ml_make(da, ls_precise_ts(dsize, dsc));
    let sloc = ml_make(sptr, ls_precise_ts(size, scalable));
    let okd, dcap = mc_sm_track(da, 0, load, store, dloc, sloc, q);
    if !okd { return false; }
    if mc_sm_reach.len > 0 {
        var wl: i32[>..<] = [];
        for b in mc_sm_reach { wl.push(b); }
        if cfr_from_many(wl, inst_parent(store), true, false, false) { return false; }
    }
    let oks, scap = mc_sm_track(sa, 1, load, store, dloc, sloc, q);
    if !oks { return false; }
    if dcap && scap { return false; }
    if move_src { inst_move_before(sa, da); }
    mc_set_alloca_align(sa, max(mc_alloca_align(sa), mc_alloca_align(da)));
    if ssize != dsize {
        if dsize > ssize {
            insts[inst_of(sa)].ty2 = insts[inst_of(da)].ty2;
            set_op(sa, 0, op(da, 0));
        }
    }
    var nd = sa;
    if soff != doff {
        mcb_at(da);
        nd = mcb_ptr_add(sa, mcb_i64(soff - doff), true);
    }
    rauw(da, nd);
    mc_erase(da);
    // dropUnknownNonDebugMetadata: keep !dbg and !DIAssignID
    let kda = md_kind_id("DIAssignID");
    let si = inst_of(sa);
    var kinds: i32[>..<] = [];
    for x in insts[si].nmd {
        let k = md_att[insts[si].md + 2 * x];
        if k != 0 && k != kda { kinds.push(k); }
    }
    for k in kinds { inst_erase_md(sa, k); }
    for i in mc_sm_markers { mc_erase(i); }
    for i in mc_sm_aamd {
        inst_erase_md(i, MDK_ALIAS_SCOPE);
        inst_erase_md(i, MDK_NOALIAS);
        inst_erase_md(i, MDK_TBAA);
        inst_erase_md(i, MDK_TBAA_STRUCT);
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// processMemCpy, processMemMove, byval / immutable arguments

// isZeroSize(Size)
fn mc_is_zero_size(s0: i32) -> bool {
    var s = s0;
    if is_inst(s) {
        let a = sq_no_dt;
        let b = sq_no_ac;
        let c = sq_no_tli;
        sq_no_dt = true;
        sq_no_ac = true;
        sq_no_tli = true;
        let r = simplify_instruction(s);
        sq_no_dt = a;
        sq_no_ac = b;
        sq_no_tli = c;
        if r >= 0 { s = r; }
    }
    if is_constant(s) {
        let k = vals[s].kind;
        return k == VK_UNDEF || k == VK_POISON || is_null_value(s);
    }
    return false;
}

// GlobalVariable::hasDefinitiveInitializer: hasInitializer && !isInterposable && !isExternallyInitialized
fn mc_has_definitive_initializer(g: i32) -> bool {
    if nops(g) == 0 { return false; }
    if ic::glob_is_interposable(g) { return false; }
    return globs[glob_of(g)].ext_init == 0;
}

fn mc_process_memcpy(m: i32) -> bool {
    if mi_is_volatile(m) { return false; }
    if mi_source(m) == mi_dest(m) {
        mc_bbi = inst_next(m);
        mc_erase(m);
        return true;
    }
    if mc_is_zero_size(mi_length(m)) {
        mc_bbi = inst_next(m);
        mc_erase(m);
        return true;
    }
    let ma = mssa_access_of(m);
    if ma < 0 { return false; }
    let gv = get_underlying_object(mi_source(m), 10);
    if is_gvar(gv) && globs[glob_of(gv)].is_const != 0 && mc_has_definitive_initializer(gv) {
        let bv = is_bytewise_value(op(gv, 0));
        if bv >= 0 {
            mcb_at(m);
            let nm = mcb_memset(mi_raw_dest(m), bv, mi_length(m), mi_dest_align(m), false);
            let na = msu_create_access_after(nm, -1, ma);
            msu_insert_def(na, true);
            mc_erase(m);
            return true;
        }
    }
    let q = aq_push(CA_EARLIEST);
    let r = mc_process_memcpy_q(m, ma, q);
    aq_pop(q);
    return r;
}
fn mc_process_memcpy_q(m: i32, ma: i32, q: i32) -> bool {
    let any_clob = ma_def(ma);
    let dest_loc = ml_for_dest(m);
    let dclob = mssa_get_clobbering_loc(any_clob, dest_loc, q);
    if ma_is_def(dclob) && !mssa_is_live(dclob) {
        let mdep = macc[dclob].inst;
        if mi_is_memset(mdep) && macc[dclob].bb == inst_parent(m) {
            if mc_memset_memcpy(m, mdep, q) { return true; }
        }
    }
    let sclob = mssa_get_clobbering_loc(any_clob, ml_for_source(m), q);
    if ma_is_def(sclob) {
        if !mssa_is_live(sclob) {
            let mi = macc[sclob].inst;
            let cs = mi_length(m);
            if vals[cs].kind == VK_CINT && !ty_is_vector(vals[cs].ty) {
                if is_inst_op(mi, OP_CALL) {
                    let da = mi_dest_align(m);
                    if mc_call_slot(m, m, mi_dest(m), mi_source(m), cint_lo(cs), false, if da == 0 { 1 as u64 } else { da }, q, mi) {
                        mc_erase(m);
                        return true;
                    }
                }
            }
            if mi_is_memcpy(mi) {
                if mc_memcpy_memcpy(m, mi, q) { return true; }
            }
            if mi_is_memset(mi) {
                if mc_memcpy_to_memset(m, mi, q) {
                    mc_erase(m);
                    return true;
                }
            }
        }
        if mc_has_undef_contents(mi_source(m), sclob) {
            mc_erase(m);
            return true;
        }
    }
    let len = mi_length(m);
    if vals[len].kind != VK_CINT || ty_is_vector(vals[len].ty) { return false; }
    if mc_stack_move(m, m, mi_dest(m), mi_source(m), cint_lo(len), false, q) {
        mc_bbi = inst_next(m);
        mc_erase(m);
        return true;
    }
    return false;
}

// isMemMoveMemSetDependency(M)
fn mc_memmove_memset_dependency(m: i32) -> bool {
    let ma = mssa_access_of(m);
    if ma < 0 { return false; }
    let sloc = ml_for_source(m);
    let src = mi_source(m);
    if opcode_of(src) != OP_GEP { return false; }
    if op(src, 0) != mi_dest(m) || !ls_has_value(sloc.size) { return false; }
    let ok, off0 = gep_accumulate_constant_offset(src);
    if !ok { return false; }
    let w = dl_ptr(ptr_as(vals[src].ty)).idx;
    let off = sext64((off0 as! u64) & wmask64(w), w);
    if off < 0 { return false; }
    let mms = ls_value(sloc.size);
    let total = ls_precise((off as! u64) + mms);
    let cl = ml_make(mi_dest(m), total);
    let q = aq_push(CA_SIMPLE);
    let r = mc_memmove_memset_dependency_q(m, ma, cl, off, mms, q);
    aq_pop(q);
    return r;
}
fn mc_memmove_memset_dependency_q(m: i32, ma: i32, cl: ML, off: i64, mms: u64, q: i32) -> bool {
    let dc = mssa_get_clobbering_loc(ma_def(ma), cl, q);
    if !ma_is_def(dc) { return false; }
    if mssa_is_live(dc) { return false; }
    let ms = macc[dc].inst;
    if !mi_is_memset(ms) { return false; }
    let l = mi_length(ms);
    if vals[l].kind != VK_CINT || ty_is_vector(vals[l].ty) || cint_lo(l) < (off as! u64) + mms { return false; }
    if !aa_is_must_alias_vals(mi_dest(ms), mi_dest(m), q) { return false; }
    return true;
}

// processMemMove(M, BBI)
fn mc_process_memmove(m: i32) -> bool {
    if mr_is_mod(aa_inst_loc_mr_simple(m, ml_for_source(m))) {
        if !mi_is_volatile(m) && mc_memmove_memset_dependency(m) {
            mc_bbi = inst_next(m);
            mc_erase(m);
            return true;
        }
        return false;
    }
    let t1: i32 = vals[mi_raw_dest(m)].ty;
    let t2: i32 = vals[mi_raw_source(m)].ty;
    let t3: i32 = vals[mi_length(m)].ty;
    let f = au_get_declaration(IID_memcpy, [t1, t2, t3]);
    set_op(m, nops(m) - 1, f);
    insts[inst_of(m)].ty2 = globs[glob_of(f)].vty;
    return true;
}

// CallBase::getParamByValType(ArgNo): -1 if none
fn mc_param_byval_type(c: i32, k: i64) -> i32 {
    let a = aset_find(alist_param(insts[inst_of(c)].attrs, k), AK_ByVal);
    if a >= 0 && attrs[a].ty >= 0 { return attrs[a].ty; }
    let f = called_function(c);
    if f >= 0 {
        let b = aset_find(alist_param(globs[glob_of(f)].attrs, k), AK_ByVal);
        if b >= 0 { return attrs[b].ty; }
    }
    return -1;
}

// processByValArgument(CB, ArgNo)
fn mc_process_byval_argument(c: i32, k: i64) -> bool {
    let arg = cb_arg(c, k);
    let bt = mc_param_byval_type(c, k);
    if bt < 0 { mc_not_ported("byval argument without a type"); }
    let bsize = dl_alloc_size(bt) as u64;
    let bsc = ty_size_scalable(bt);
    let loc = ml_make(arg, ls_precise_ts(bsize, bsc));
    let ca = mssa_access_of(c);
    if ca < 0 { return false; }
    let q = aq_push(CA_EARLIEST);
    let r = mc_process_byval_argument_q(c, k, arg, bsize, bsc, loc, ca, q);
    aq_pop(q);
    return r;
}
fn mc_process_byval_argument_q(c: i32, k: i64, arg: i32, bsize: u64, bsc: bool, loc: ML, ca: i32, q: i32) -> bool {
    var mdep: i32 = -1;
    let clob = mssa_get_clobbering_loc(ma_def(ca), loc, q);
    if ma_is_def(clob) && !mssa_is_live(clob) && mi_is_memcpy(macc[clob].inst) { mdep = macc[clob].inst; }
    if mdep < 0 || mi_is_volatile(mdep) || strip_ptr_casts(arg) != mi_dest(mdep) { return false; }
    let l = mi_length(mdep);
    if vals[l].kind != VK_CINT || ty_is_vector(vals[l].ty) { return false; }
    if bsc || cint_lo(l) < bsize { return false; }
    let ba = mi_param_align(c, k);
    if ba == 0 { return false; }
    let mda = mi_source_align(mdep);
    if (mda == 0 || mda < ba) && (ic::lsa_get_or_enforce_known_alignment(mi_source(mdep), ba as! i64, c) as! u64) < ba { return false; }
    if vals[mi_source(mdep)].ty != vals[arg].ty { return false; }
    if mc_written_between(q, ml_for_source(mdep), mssa_access_of(mdep), ca) { return false; }
    cu_combine_metadata(c, mdep, true, true);
    set_op(c, k, mi_source(mdep));
    return true;
}

// processImmutArgument(CB, ArgNo)
fn mc_process_immut_argument(c: i32, k: i64) -> bool {
    let q = aq_push(CA_EARLIEST);
    let r = mc_process_immut_argument_q(c, k, q);
    aq_pop(q);
    return r;
}
fn mc_process_immut_argument_q(c: i32, k: i64, q: i32) -> bool {
    let arg = cb_arg(c, k);
    if cb_capture_info(c, k) != 0 { return false; }
    if !cb_param_has_attr(c, k, AK_NoAlias) && mr_is_mod(aa_inst_loc_mr(c, ml_before_or_after(arg), q)) { return false; }
    let ai = strip_ptr_casts(arg);
    if !is_inst_op(ai, OP_ALLOCA) { return false; }
    let ok, asize, asc = mc_alloca_size(ai);
    if !ok || asc { return false; }
    let loc = ml_make(arg, ls_precise(asize));
    let ca = mssa_access_of(c);
    if ca < 0 { return false; }
    var mdep: i32 = -1;
    let clob = mssa_get_clobbering_loc(ma_def(ca), loc, q);
    if ma_is_def(clob) && !mssa_is_live(clob) && mi_is_memcpy(macc[clob].inst) { mdep = macc[clob].inst; }
    if mdep < 0 || mi_is_volatile(mdep) || ai != mi_dest(mdep) { return false; }
    if vals[mi_source(mdep)].ty != vals[arg].ty { return false; }
    let l = mi_length(mdep);
    if vals[l].kind != VK_CINT || ty_is_vector(vals[l].ty) { return false; }
    if ty_bits(vals[l].ty) > 64 && cint_hi(l) != 0 { return false; }
    if asize != cint_lo(l) { return false; }
    let mda0 = mi_source_align(mdep);
    let mda = if mda0 == 0 { 1 as u64 } else { mda0 };
    let aal = mc_alloca_align(ai);
    if mda < aal && (ic::lsa_get_or_enforce_known_alignment(mi_source(mdep), aal as! i64, c) as! u64) < aal { return false; }
    if mc_written_between(q, ml_for_source(mdep), mssa_access_of(mdep), ca) { return false; }
    if mr_is_mod(aa_inst_loc_mr(c, ml_for_source(mdep), q)) { return false; }
    cu_combine_metadata(c, mdep, true, true);
    set_op(c, k, mi_source(mdep));
    return true;
}

// ---------------------------------------------------------------------------------------------
// iterateOnFunction, run

fn mc_iterate_on_function(fv: i32) -> bool {
    var changed = false;
    var bb = func_entry(fv);
    while bb >= 0 {
        if !dt_has_node(DT_DOM, bb) { bb = block_next(bb); continue; }
        mc_bbi = block_first(bb);
        while mc_bbi >= 0 {
            let i = mc_bbi;
            mc_bbi = inst_next(i);
            var repeat = false;
            if iop(i) == OP_STORE {
                if mc_process_store(i) { changed = true; }
            } else if mi_is_memset(i) {
                repeat = mc_process_memset(i);
            } else if mi_is_memcpy(i) {
                repeat = mc_process_memcpy(i);
            } else if mi_is_memmove(i) {
                repeat = mc_process_memmove(i);
            } else if is_callbase(i) {
                for k in cb_nargs(i) {
                    if cb_is_byval_arg(i, k) {
                        if mc_process_byval_argument(i, k) { changed = true; }
                    } else if cb_arg_only_reads(i, k) {
                        if mc_process_immut_argument(i, k) { changed = true; }
                    }
                }
            }
            if repeat {
                // if (BI != BB.begin()) --BI;
                if mc_bbi < 0 { mc_bbi = block_last(bb); }
                else if mc_bbi != block_first(bb) { mc_bbi = inst_prev(mc_bbi); }
                changed = true;
            }
        }
        bb = block_next(bb);
    }
    return changed;
}

// MemCpyOptPass::run(F, AM)
fn memcpyopt_run(fv: i32) -> u32 {
    mc_fn = fv;
    tli_cur_fn = fv;
    local_have_tli = true;
    mc_without_libcalls = flag_bool("enable-memcpyopt-without-libcalls", false);
    aa_begin(fv);
    vt_invalidate_assumes();
    ac_invalidate();
    dt_get(fv, DT_DOM);
    dt_get(fv, DT_POST);
    mssa_get(fv);
    msu_reset();
    ea_begin(false, false);
    var changed = false;
    loop {
        if !mc_iterate_on_function(fv) { break; }
        changed = true;
    }
    if !changed { return PA_ALL; }
    return PA_CFG | ((1 as u32) << A_MEMORYSSA);
}
