// Port of the dead-instruction predicates of llvm/lib/Transforms/Utils/Local.cpp
// (isInstructionTriviallyDead, wouldInstructionBeTriviallyDead[OnUnusedPaths]) and the MemoryBuiltins.cpp /
// ConstantFolding.cpp helpers they use (isRemovableAlloc, getFreedOperand, isMathLibCallNoop).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import tli;
import gen_attrs;
import gen_iids;
import intrinsics;

// MemoryBuiltins.cpp getCalledFunction: not for intrinsics, not for nobuiltin calls.
fn mb_called_function(iv: i32) -> i32 {
    if inst_iid(iv) != 0 { return -1; }
    if !is_callbase(iv) { return -1; }
    if call_is_nobuiltin(iv) { return -1; }
    return called_function(iv);
}

// AllocFnKind bits (llvm/IR/Attributes.h): Alloc = 1 << 0? (Unknown 0, Alloc 1, Realloc 2, Free 4,
// Uninitialized 8, Zeroed 16, Aligned 32).
let AFK_ALLOC: u64 = 1;
let AFK_REALLOC: u64 = 2;
let AFK_FREE: u64 = 4;

fn call_alloc_kind(iv: i32) -> u64 {
    var a = aset_find(alist_fn(insts[inst_of(iv)].attrs), AK_AllocKind);
    if a < 0 {
        let c = cb_callee(iv);
        if c >= 0 && vals[c].kind == VK_FUNC { a = aset_find(alist_fn(globs[glob_of(c)].attrs), AK_AllocKind); }
    }
    if a < 0 { return 0; }
    return attrs[a].i1;
}

// isAllocLikeFn(CB, TLI): known malloc/calloc/strdup-like library function, or allockind("alloc").
fn is_alloc_like_fn(iv: i32) -> bool {
    let f = mb_called_function(iv);
    if f >= 0 && tli_alloc_like(f) { return true; }
    return (call_alloc_kind(iv) & AFK_ALLOC) != 0;
}

fn is_removable_alloc(iv: i32) -> bool { is_alloc_like_fn(iv) }

// CallBase::getArgOperandWithAttribute
fn call_arg_with_attr(iv: i32, kind: i64) -> i32 {
    let l = insts[inst_of(iv)].attrs;
    for k in cb_nargs(iv) { if aset_has(alist_param(l, k), kind) { return cb_arg(iv, k); } }
    let c = called_function(iv);
    if c >= 0 {
        let fl = globs[glob_of(c)].attrs;
        for k in cb_nargs(iv) { if aset_has(alist_param(fl, k), kind) { return cb_arg(iv, k); } }
    }
    return -1;
}

// getFreedOperand
fn get_freed_operand(iv: i32) -> i32 {
    let f = mb_called_function(iv);
    if f >= 0 && tli_is_free_fn(f) { return cb_arg(iv, 0); }
    if (call_alloc_kind(iv) & AFK_FREE) != 0 { return call_arg_with_attr(iv, AK_AllocatedPointer); }
    return -1;
}

fn is_constant_value(v: i32) -> bool { v >= 0 && is_constant(v) }

// wouldInstructionBeTriviallyDead
fn would_be_trivially_dead(iv: i32) -> bool {
    if is_terminator(iv) { return false; }
    if inst_is_eh_pad(iv) { return false; }
    let id = inst_iid(iv);
    if is_callbase(iv) && is_removable_alloc(iv) { return true; }
    if !inst_will_return(iv) {
        if id == 0 { return false; }
        if id == IID_experimental_guard {
            let c = cb_arg(iv, 0);
            return is_cint(c) && cint_lo(c) == 1;
        }
        if id == IID_ptrauth_auth || id == IID_ptrauth_resign { return true; }
        return false;
    }
    if !inst_may_have_side_effects(iv) { return true; }
    if id != 0 {
        if id == IID_stacksave || id == IID_launder_invariant_group { return true; }
        if id == IID_allow_runtime_check || id == IID_allow_ubsan_check { return true; }
        if id == IID_lifetime_start || id == IID_lifetime_end {
            let a = cb_arg(iv, 0);
            if is_poison(a) { return true; }
            // all uses of the alloca are lifetime intrinsics
            if !has_use_list(a) { return false; }
            var u = vals[a].first_use;
            while u >= 0 {
                let us = uses[u].user;
                let uid = inst_iid(us);
                if uid != IID_lifetime_start && uid != IID_lifetime_end { return false; }
                u = uses[u].next;
            }
            return true;
        }
        if id == IID_assume && cb_nbundles(iv) == 0 {
            let c = cb_arg(iv, 0);
            if is_cint(c) { return !cint_is_zero(c); }
            return false;
        }
        if is_constrained_fp_iid(id) {
            return constrained_exception_behavior(iv) != 2;
        }
    }
    if is_callbase(iv) {
        let fo = get_freed_operand(iv);
        if fo >= 0 && is_constant_value(fo) { return is_null_value(fo) || is_undef_or_poison(fo); }
        if is_math_libcall_noop(iv) { return true; }
    }
    if iop(iv) == OP_LOAD {
        let p = strip_ptr_casts(op(iv, 0));
        if is_gvar(p) && (insts[inst_of(iv)].bits & 1) == 0 && globs[glob_of(p)].is_const != 0 { return true; }
    }
    return false;
}

fn is_instruction_trivially_dead(iv: i32) -> bool {
    if vals[iv].first_use >= 0 { return false; }
    return would_be_trivially_dead(iv);
}

// Value::stripPointerCasts: bitcast/addrspacecast (instructions and constant expressions), all-zero GEPs,
// aliases are not looked through.
fn strip_ptr_casts(v0: i32) -> i32 {
    var v = v0;
    loop {
        let k = vals[v].kind;
        if k == VK_INST {
            let o = iop(v);
            if o == OP_BITCAST || o == OP_ADDRSPACECAST { v = op(v, 0); continue; }
            if o == OP_GEP && gep_all_zero(v) { v = op(v, 0); continue; }
            return v;
        }
        if k == VK_CEXPR {
            let o = csts[vals[v].sub].op as i64;
            if o == OP_BITCAST || o == OP_ADDRSPACECAST { v = op(v, 0); continue; }
            if o == OP_GEP && gep_all_zero(v) { v = op(v, 0); continue; }
            return v;
        }
        return v;
    }
}
fn gep_all_zero(v: i32) -> bool {
    for k in 1..nops(v) { let x = op(v, k); if !(is_constant(x) && is_null_value(x)) { return false; } }
    return true;
}

// ConstrainedFPIntrinsic
fn is_constrained_fp_iid(id: i32) -> bool {
    if id == 0 { return false; }
    return starts_with(intr_name(id as i64), "llvm.experimental.constrained.");
}
// fp::ExceptionBehavior from the trailing metadata string: 0 ignore, 1 maytrap, 2 strict (default strict).
fn constrained_exception_behavior(iv: i32) -> i64 {
    let n = cb_nargs(iv);
    if n == 0 { return 2; }
    let a = cb_arg(iv, n - 1);
    if vals[a].kind != VK_MDVAL { return 2; }
    let m = vals[a].sub;
    if mds[m].kind != MK_STRING { return 2; }
    let s = sbytes(mds[m].extra);
    if s == "fpexcept.ignore" { return 0; }
    if s == "fpexcept.maytrap" { return 1; }
    return 2;
}
