// Instruction properties: intrinsic ids, call attributes, memory effects, side effects.
// Ports llvm/lib/IR/Instruction.cpp (mayReadFromMemory, mayWriteToMemory, mayThrow, mayHaveSideEffects,
// willReturn, isVolatile, isEHPad, dropPoisonGenerating*), llvm/lib/IR/Instructions.cpp (CallBase memory
// effects, hasFnAttr), llvm/lib/IR/Intrinsics.cpp (lookupIntrinsicID).
import std;
import ir;
import irutil;
import calls;
import gen_attrs;
import gen_iids;
import intrinsics;

// Intrinsic ids: func_iid (intrinsics.goose, LLVM numbering) and the IID_* constants (gen_iids.goose).

// CallBase::getCalledFunction: the callee if it is a Function of the call's function type.
fn called_function(iv: i32) -> i32 {
    let c = cb_callee(iv);
    if c >= 0 && vals[c].kind == VK_FUNC && globs[glob_of(c)].vty == insts[inst_of(iv)].ty2 { return c; }
    return -1;
}

// IntrinsicInst: a call (or invoke) of an intrinsic function. CallBase::getIntrinsicID uses the callee even
// when the function type differs.
fn call_iid(iv: i32) -> i32 {
    if !is_callbase(iv) { return 0; }
    let c = cb_callee(iv);
    if c >= 0 && vals[c].kind == VK_FUNC { return func_iid(c) as i32; }
    return 0;
}
fn inst_iid(iv: i32) -> i32 { if is_inst(iv) && iop(iv) == OP_CALL { call_iid(iv) } else { 0 } }
fn is_intrinsic_inst(iv: i32) -> bool { inst_iid(iv) != 0 }

// ---------------------------------------------------------------------------------------------
// Attributes of calls

fn func_attrs(fv: i32) -> i32 { globs[glob_of(fv)].attrs }
fn func_has_fn_attr(fv: i32, kind: i64) -> bool { aset_has(alist_fn(func_attrs(fv)), kind) }

// CallBase::hasFnAttrImpl: the call site's function attributes, then the callee's (if it is a Function).
fn call_has_fn_attr(iv: i32, kind: i64) -> bool {
    if aset_has(alist_fn(insts[inst_of(iv)].attrs), kind) { return true; }
    let c = cb_callee(iv);
    if c >= 0 && vals[c].kind == VK_FUNC { return func_has_fn_attr(c, kind); }
    return false;
}
fn call_has_fn_str_attr(iv: i32, key: const u8[:]) -> bool {
    if aset_find_str(alist_fn(insts[inst_of(iv)].attrs), key) >= 0 { return true; }
    let c = cb_callee(iv);
    if c >= 0 && vals[c].kind == VK_FUNC { return aset_find_str(alist_fn(func_attrs(c)), key) >= 0; }
    return false;
}

fn aset_find_str(s: i32, key: const u8[:]) -> i32 {
    for k in aset_n(s) {
        let a = aset_attr(s, k);
        if attrs[a].kind == 0 && sbytes(attrs[a].skey) == key { return a; }
    }
    return -1;
}

// CallBase::isNoBuiltin / isStrictFP
fn call_is_nobuiltin(iv: i32) -> bool { call_has_fn_attr(iv, AK_NoBuiltin) && !call_has_fn_attr(iv, AK_Builtin) }
fn call_is_strictfp(iv: i32) -> bool { call_has_fn_attr(iv, AK_StrictFP) }

// MemoryEffects (llvm/Support/ModRef.h): 2 bits per location (ArgMem, InaccessibleMem, ErrnoMem, Other,
// TargetMem0, TargetMem1); Ref = 1, Mod = 2.
let ME_UNKNOWN: u64 = 0xFFF;
let ME_LOC_INACCESSIBLE = 1;

fn aset_memory(s: i32) -> u64 {
    let a = aset_find(s, AK_Memory);
    if a < 0 { return ME_UNKNOWN; }
    return attrs[a].i1;
}
fn me_only_reads(m: u64) -> bool { (m & 0xAAA) == 0 }
fn me_only_writes(m: u64) -> bool { (m & 0x555) == 0 }
fn me_none(m: u64) -> bool { m == 0 }

// CallBase::hasReadingOperandBundles / hasClobberingOperandBundles
fn bundle_tag_is(iv: i32, k: i64, tags: const u8[:][:]) -> bool {
    let t = sbytes(cb_bundle_tag(iv, k));
    for x in tags { if t == x { return true; } }
    return false;
}
fn call_has_reading_bundles(iv: i32) -> bool {
    if call_iid(iv) == IID_assume { return false; }
    let skip: const u8[:][] = ["ptrauth", "kcfi", "convergencectrl", "deactivation-symbol"];
    for k in cb_nbundles(iv) { if !bundle_tag_is(iv, k, skip) { return true; } }
    return false;
}
fn call_has_clobbering_bundles(iv: i32) -> bool {
    if call_iid(iv) == IID_assume { return false; }
    let skip: const u8[:][] = ["deopt", "funclet", "ptrauth", "kcfi", "convergencectrl", "deactivation-symbol"];
    for k in cb_nbundles(iv) { if !bundle_tag_is(iv, k, skip) { return true; } }
    return false;
}

// CallBase::getMemoryEffects
fn call_memory_effects(iv: i32) -> u64 {
    var me = aset_memory(alist_fn(insts[inst_of(iv)].attrs));
    let c = cb_callee(iv);
    if c >= 0 && vals[c].kind == VK_FUNC {
        var fme = aset_memory(alist_fn(func_attrs(c)));
        if cb_nbundles(iv) > 0 {
            if call_has_reading_bundles(iv) { fme |= 0x555; }
            if call_has_clobbering_bundles(iv) { fme |= 0xAAA; }
        }
        if inst_is_volatile(iv) { fme |= (3 as u64) << (2 * ME_LOC_INACCESSIBLE); }
        me &= fme;
    }
    return me;
}
fn call_only_reads_memory(iv: i32) -> bool { me_only_reads(call_memory_effects(iv)) }
fn call_only_writes_memory(iv: i32) -> bool { me_only_writes(call_memory_effects(iv)) }
fn call_does_not_access_memory(iv: i32) -> bool { me_none(call_memory_effects(iv)) }

// ---------------------------------------------------------------------------------------------
// Instruction properties

fn is_mem_intrinsic_id(id: i32) -> bool {
    id == IID_memcpy || id == IID_memcpy_inline || id == IID_memmove || id == IID_memset || id == IID_memset_inline
}

// Instruction::isVolatile
fn inst_is_volatile(iv: i32) -> bool {
    let o = iop(iv);
    let ii = inst_of(iv);
    if o == OP_ATOMICRMW || o == OP_STORE || o == OP_LOAD || o == OP_CMPXCHG { return (insts[ii].bits & 1) != 0; }
    if o == OP_CALL || o == OP_INVOKE {
        let id = call_iid(iv);
        if id == 0 { return false; }
        if is_mem_intrinsic_id(id) {
            let vol = cb_arg(iv, 3);
            return is_cint(vol) && !cint_is_zero(vol);
        }
        if id == IID_matrix_column_major_load { let a = cb_arg(iv, 2); return is_cint(a) && cint_lo(a) == 1; }
        if id == IID_matrix_column_major_store { let a = cb_arg(iv, 3); return is_cint(a) && cint_lo(a) == 1; }
    }
    return false;
}

// Atomic orderings as stored in Inst.ord: 0 notatomic, 1 unordered, 2 monotonic, 3 consume, 4 acquire,
// 5 release, 6 acq_rel, 7 seq_cst.
// LoadInst/StoreInst::isUnordered: (not atomic or unordered) and not volatile.
fn ldst_is_unordered(iv: i32) -> bool {
    let x = insts[inst_of(iv)];
    return x.ord <= 1 && (x.bits & 1) == 0;
}

fn inst_may_read_memory(iv: i32) -> bool {
    let o = iop(iv);
    if o == OP_VAARG || o == OP_LOAD || o == OP_FENCE || o == OP_CMPXCHG || o == OP_ATOMICRMW || o == OP_CATCHPAD || o == OP_CATCHRET { return true; }
    if o == OP_CALL || o == OP_INVOKE || o == OP_CALLBR { return !call_only_writes_memory(iv); }
    if o == OP_STORE { return !ldst_is_unordered(iv); }
    return false;
}

fn inst_may_write_memory(iv: i32) -> bool {
    let o = iop(iv);
    if o == OP_FENCE || o == OP_STORE || o == OP_VAARG || o == OP_CMPXCHG || o == OP_ATOMICRMW || o == OP_CATCHPAD || o == OP_CATCHRET { return true; }
    if o == OP_CALL || o == OP_INVOKE || o == OP_CALLBR { return !call_only_reads_memory(iv); }
    if o == OP_LOAD { return !ldst_is_unordered(iv); }
    return false;
}

fn inst_may_read_or_write_memory(iv: i32) -> bool { inst_may_read_memory(iv) || inst_may_write_memory(iv) }

// canUnwindPastLandingPad
fn landingpad_can_unwind_past(lp: i32, include_phase_one: bool) -> bool {
    if (insts[inst_of(lp)].bits & 1) != 0 { return include_phase_one; }
    for k in nops(lp) {
        let cl = op(lp, k);
        let is_filter = ty_is_array(vals[cl].ty);
        if !is_filter && vals[cl].kind == VK_CNULL { return false; }
        if is_filter && ty_count(vals[cl].ty) == 0 { return false; }
    }
    return true;
}

// CleanupReturnInst / CatchSwitchInst::unwindsToCaller (no unwind destination)
fn cleanupret_unwinds_to_caller(iv: i32) -> bool { nops(iv) < 2 }
fn catchswitch_unwinds_to_caller(iv: i32) -> bool { (insts[inst_of(iv)].bits & 1) == 0 }

// Instruction::mayThrow(IncludePhaseOneUnwind = false)
fn inst_may_throw(iv: i32) -> bool {
    let o = iop(iv);
    if o == OP_CALL { return !call_has_fn_attr(iv, AK_NoUnwind); }
    if o == OP_CLEANUPRET { return cleanupret_unwinds_to_caller(iv); }
    if o == OP_CATCHSWITCH { return catchswitch_unwinds_to_caller(iv); }
    if o == OP_RESUME { return true; }
    if o == OP_INVOKE {
        let lp = first_non_phi(invoke_unwind_dest(iv));
        if lp >= 0 && iop(lp) == OP_LANDINGPAD { return landingpad_can_unwind_past(lp, false); }
        return false;
    }
    return false;
}

// Instruction::willReturn
fn inst_will_return(iv: i32) -> bool {
    if inst_is_volatile(iv) { return false; }
    if is_callbase(iv) { return call_has_fn_attr(iv, AK_WillReturn); }
    return true;
}

fn inst_may_have_side_effects(iv: i32) -> bool {
    return inst_may_write_memory(iv) || inst_may_throw(iv) || !inst_will_return(iv);
}

fn inst_is_eh_pad(iv: i32) -> bool {
    let o = iop(iv);
    return o == OP_CATCHSWITCH || o == OP_CATCHPAD || o == OP_CLEANUPPAD || o == OP_LANDINGPAD;
}

fn inst_is_lifetime_start_or_end(iv: i32) -> bool {
    let id = inst_iid(iv);
    return id == IID_lifetime_start || id == IID_lifetime_end;
}

// Is the instruction an FPMathOperator (Operator.h)?
fn is_fp_math_operator(iv: i32) -> bool {
    let o = iop(iv);
    if o == OP_FNEG || o == OP_FADD || o == OP_FSUB || o == OP_FMUL || o == OP_FDIV || o == OP_FREM || o == OP_FCMP { return true; }
    if o == OP_PHI || o == OP_SELECT || o == OP_CALL {
        var t = vals[iv].ty;
        while ty_is_array(t) { t = ty_elem(t); }
        if ty_is_struct(t) {
            // homogeneous struct of FP (or FP vector) types
            let n = ty_count(t);
            if n == 0 { return false; }
            let e0 = ty_field(t, 0);
            for k in n { if ty_field(t, k) != e0 { return false; } }
            t = e0;
        }
        return ty_is_fp(ty_scalar(t));
    }
    return false;
}

// Instruction::dropPoisonGeneratingFlags
fn drop_poison_generating_flags(iv: i32) {
    let o = iop(iv);
    let ii = inst_of(iv);
    if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL || o == OP_UDIV || o == OP_SDIV ||
       o == OP_LSHR || o == OP_ASHR || o == OP_OR || o == OP_ZEXT || o == OP_UITOFP || o == OP_TRUNC ||
       o == OP_ICMP || o == OP_GEP {
        insts[ii].flags = 0;
    }
    if o == OP_CALL {
        let id = call_iid(iv);
        if id == IID_ctlz || id == IID_cttz || id == IID_abs { set_op(iv, 1, c_false()); }
    }
    if is_fp_math_operator(iv) { insts[ii].fmf = insts[ii].fmf & ~(FMF_NNAN | FMF_NINF); }
}

// Instruction::eraseMetadata(KindID)
fn inst_erase_md(iv: i32, kind: i32) {
    let ii = inst_of(iv);
    let at = insts[ii].md;
    let n = insts[ii].nmd;
    var w: i32 = 0;
    for k in n {
        let kk = md_att[at + 2 * k];
        let node = md_att[at + 2 * k + 1];
        if kk == kind { continue; }
        md_att[at + 2 * w] = kk;
        md_att[at + 2 * w + 1] = node;
        w++;
    }
    insts[ii].nmd = w;
}
fn inst_get_md(iv: i32, kind: i32) -> i32 {
    let ii = inst_of(iv);
    for k in insts[ii].nmd { if md_att[insts[ii].md + 2 * k] == kind { return md_att[insts[ii].md + 2 * k + 1]; } }
    return -1;
}

// Remove the attributes of the given kinds from one set.
fn aset_without(s: i32, kinds: const i64[:]) -> i32 {
    var keep: i32[>..<] = [];
    var changed = false;
    for k in aset_n(s) {
        let a = aset_attr(s, k);
        var drop = false;
        for kd in kinds { if attrs[a].kind as i64 == kd { drop = true; } }
        if drop { changed = true; } else { keep.push(a); }
    }
    if !changed { return s; }
    return aset_get(keep);
}

// Instruction::dropPoisonGeneratingAttributes: range/align/nonnull/nofpclass off the return and params.
fn drop_poison_generating_attributes(iv: i32) {
    if !is_callbase(iv) { return; }
    let ii = inst_of(iv);
    let l = insts[ii].attrs;
    if l == 0 { return; }
    let kinds: i64[4] = [AK_Range, AK_Alignment, AK_NonNull, AK_NoFPClass];
    var sets: i32[>..<] = [];
    let n = alists[l].n as i64;
    for k in n {
        let s = alist_runs[alists[l].at + k];
        sets.push(if k == 0 { s } else { aset_without(s, kinds) });
    }
    insts[ii].attrs = alist_get(sets);
}

// Instruction::dropPoisonGeneratingAnnotations
fn drop_poison_generating_annotations(iv: i32) {
    drop_poison_generating_flags(iv);
    let names: const u8[:][] = ["range", "nonnull", "align", "nofpclass"];
    for nm in names { inst_erase_md(iv, md_kind_id(nm)); }
    drop_poison_generating_attributes(iv);
}
