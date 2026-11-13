// Instruction properties passes query: side effects, memory behaviour, triviality of death.
// Ported from llvm/lib/IR/Instruction.cpp (mayReadFromMemory, mayWriteToMemory, mayThrow, willReturn,
// mayHaveSideEffects, isVolatile), llvm/lib/IR/Instructions.cpp (CallBase::getMemoryEffects, operand bundles),
// llvm/lib/Transforms/Utils/Local.cpp (wouldInstructionBeTriviallyDead, isInstructionTriviallyDead),
// llvm/lib/Analysis/MemoryBuiltins.cpp (isRemovableAlloc, getFreedOperand), llvm/lib/Analysis/ConstantFolding.cpp
// (isMathLibCallNoop) and the parts of TargetLibraryInfo those need (x86_64-linux, every function available unless
// the caller has "no-builtins" / "no-builtin-<name>").

// ---------------------------------------------------------------- calls

is_call_base :: inline (i: Value_Id) -> bool { op := inst_op(i); return op == .CALL || op == .INVOKE || op == .CALLBR; }
call_num_args :: (i: Value_Id) -> u32 { return call_arg_count(i); }
// call_arg / call_callee / strip_pointer_casts are in autoupgrade.jai
// dyn_cast<Function>(getCalledOperand())
call_called_operand_fn :: inline (i: Value_Id) -> Value_Id {
    c := call_callee(i);
    if c != NONE && vkind(c) == .FUNCTION return c;
    return NONE;
}
// CallBase::getCalledFunction: the callee if it is a Function with the call's function type
call_called_function :: inline (i: Value_Id) -> Value_Id {
    c := call_callee(i);
    if c != NONE && vkind(c) == .FUNCTION && glob(c).value_type == inst(i).ty2 return c;
    return NONE;
}

// Intrinsic ID of a call as the intrinsic's base name ("llvm.memcpy"), "" if not an intrinsic call.
// (IntrinsicInst: a CallBase whose called function is an intrinsic.)
intrinsic_cache: Table(Value_Id, string);
function_intrinsic_base :: (f: Value_Id) -> string {
    if !glob(f).intrinsic return "";
    // dense front cache over value ids of the intrinsic_cache results
    if cast(s64) f < intrinsic_base_dense.count && intrinsic_base_known[f] return intrinsic_base_dense[f];
    found, s := table_find(*intrinsic_cache, f);
    if !found { s = intrinsic_lookup(vname(f)); table_set(*intrinsic_cache, f, s); }
    if cast(s64) f >= intrinsic_base_dense.count {
        intrinsic_base_dense.allocator = context.default_allocator; intrinsic_base_known.allocator = context.default_allocator;
        old := intrinsic_base_dense.count;
        n := max(cast(s64) f + 1, 2 * old, 1024);
        array_resize(*intrinsic_base_dense, n);
        array_resize(*intrinsic_base_known, n);
    }
    intrinsic_base_dense[f] = s; intrinsic_base_known[f] = true;
    return s;
}
intrinsic_base_dense: [..] string;
intrinsic_base_known: [..] bool;
intrinsic_id_of_call :: (i: Value_Id) -> string {
    if !is_inst(i) || !is_call_base(i) return "";
    f := call_called_function(i);
    if f == NONE return "";
    return function_intrinsic_base(f);
}

call_fn_attrs :: inline (i: Value_Id) -> u32 { return attr_list_fn(inst(i).attrs); }
// CallBase::hasFnAttr(Kind): call-site attributes, then the called function's (any Function callee)
call_has_fn_attr :: inline (i: Value_Id, k: Attr_Kind) -> bool {
    if attr_set_has(call_fn_attrs(i), k) return true;
    f := call_called_operand_fn(i);
    if f != NONE return attr_set_has(attr_list_fn(glob(f).attrs), k);
    return false;
}
call_get_fn_attr :: (i: Value_Id, k: Attr_Kind) -> *Attr {
    a := attr_set_find(call_fn_attrs(i), k);
    if a return a;
    f := call_called_operand_fn(i);
    if f != NONE return attr_set_find(attr_list_fn(glob(f).attrs), k);
    return null;
}
call_has_fn_str_attr :: (i: Value_Id, key: string) -> bool {
    for attr_set_items(call_fn_attrs(i)) if it.kind == .STRING_ATTR && it.key == key return true;
    f := call_called_operand_fn(i);
    if f != NONE for attr_set_items(attr_list_fn(glob(f).attrs)) if it.kind == .STRING_ATTR && it.key == key return true;
    return false;
}
fn_has_str_attr :: (f: Value_Id, key: string) -> bool {
    for attr_set_items(attr_list_fn(glob(f).attrs)) if it.kind == .STRING_ATTR && it.key == key return true;
    return false;
}
// CallBase::isNoBuiltin
call_is_no_builtin :: (i: Value_Id) -> bool { return call_has_fn_attr(i, .NoBuiltin) && !call_has_fn_attr(i, .Builtin); }
// CallBase::isStrictFP: hasFnAttr(StrictFP)
call_is_strict_fp :: (i: Value_Id) -> bool { return call_has_fn_attr(i, .StrictFP); }

// operand bundles: (tag, first operand, end operand) triples in u32_pool
call_num_bundles :: (i: Value_Id) -> u32 { return inst(i).nidx; }
call_bundle_tag :: (i: Value_Id, k: u32) -> string { return bundle_tags[ir.u32_pool[inst(i).idx + 3 * k]]; }
call_has_bundles_other_than :: (i: Value_Id, tags: [] string) -> bool {
    n := call_num_bundles(i);
    if n > 0 for k: 0..n-1 {
        t := call_bundle_tag(i, k);
        listed := false;
        for tags if it == t { listed = true; break; }
        if !listed return true;
    }
    return false;
}

// MemoryEffects: 2 bits per location (see parser.jai mem_*); 3 = ModRef. No attribute = unknown (all ModRef).
MEM_UNKNOWN :: 0xFFF;
attr_set_memory :: (s: u32) -> u64 {
    a := attr_set_find(s, .Memory);
    if a return a.ival;
    return MEM_UNKNOWN;
}
mem_only_reads :: (me: u64) -> bool { for 0..MEM_LOCS-1 if mem_get(me, it) & 2 return false; return true; }
mem_only_writes :: (me: u64) -> bool { for 0..MEM_LOCS-1 if mem_get(me, it) & 1 return false; return true; }
mem_does_not_access :: (me: u64) -> bool { return me == 0; }

// CallBase::getMemoryEffects
call_memory_effects :: (i: Value_Id) -> u64 {
    me := attr_set_memory(call_fn_attrs(i));
    f := call_called_operand_fn(i);
    if f != NONE {
        fme := attr_set_memory(attr_list_fn(glob(f).attrs));
        if call_num_bundles(i) > 0 {
            is_assume := intrinsic_id_of_call(i) == "llvm.assume";
            if !is_assume && call_has_bundles_other_than(i, .["ptrauth", "kcfi", "convergencectrl", "deactivation-symbol"])
                fme |= mem_all(1);
            if !is_assume && call_has_bundles_other_than(i, .["deopt", "funclet", "ptrauth", "kcfi", "convergencectrl", "deactivation-symbol"])
                fme |= mem_all(2);
        }
        if is_volatile(i) fme = mem_set(fme, 1, 3);   // inaccessibleMemOnly(ModRef)
        me &= fme;
    }
    return me;
}
call_only_reads_memory :: (i: Value_Id) -> bool { return mem_only_reads(call_memory_effects(i)); }
call_only_writes_memory :: (i: Value_Id) -> bool { return mem_only_writes(call_memory_effects(i)); }
call_does_not_throw :: (i: Value_Id) -> bool { return call_has_fn_attr(i, .NoUnwind); }

// ---------------------------------------------------------------- Instruction:: queries

ORD_UNORDERED :: 1;
is_unordered :: (i: Value_Id) -> bool { r := inst(i); return r.ord1 <= ORD_UNORDERED && (r.flags & F_VOLATILE) == 0; }

is_mem_intrinsic_name :: (id: string) -> bool {
    return id == "llvm.memcpy" || id == "llvm.memmove" || id == "llvm.memset" || id == "llvm.memcpy.inline" ||
           id == "llvm.memset.inline";
}

// Instruction::isVolatile
is_volatile :: (i: Value_Id) -> bool {
    r := inst(i);
    if r.op == {
        case .ATOMICRMW; #through;
        case .STORE; #through;
        case .LOAD; #through;
        case .CMPXCHG; return (r.flags & F_VOLATILE) != 0;
        case .CALL; #through;
        case .INVOKE;
            id := intrinsic_id_of_call(i);
            if id.count == 0 return false;
            if is_mem_intrinsic_name(id) {
                v := call_arg(i, 3);
                return vkind(v) == .C_INT && !ap_is_zero_words(v);
            }
            if id == "llvm.matrix.column.major.load" { v := call_arg(i, 2); return vkind(v) == .C_INT && const_int_zext(v) == 1; }
            if id == "llvm.matrix.column.major.store" { v := call_arg(i, 3); return vkind(v) == .C_INT && const_int_zext(v) == 1; }
            return false;
    }
    return false;
}
ap_is_zero_words :: (c: Value_Id) -> bool { for const_int_value(c) if it != 0 return false; return true; }

may_read_from_memory :: (i: Value_Id) -> bool {
    r := inst(i);
    if r.op == {
        case .VAARG; #through;
        case .LOAD; #through;
        case .FENCE; #through;
        case .CMPXCHG; #through;
        case .ATOMICRMW; #through;
        case .CATCHPAD; #through;
        case .CATCHRET; return true;
        case .CALL; #through;
        case .INVOKE; #through;
        case .CALLBR; return !call_only_writes_memory(i);
        case .STORE; return !is_unordered(i);
    }
    return false;
}
may_write_to_memory :: (i: Value_Id) -> bool {
    r := inst(i);
    if r.op == {
        case .FENCE; #through;
        case .STORE; #through;
        case .VAARG; #through;
        case .CMPXCHG; #through;
        case .ATOMICRMW; #through;
        case .CATCHPAD; #through;
        case .CATCHRET; return true;
        case .CALL; #through;
        case .INVOKE; #through;
        case .CALLBR; return !call_only_reads_memory(i);
        case .LOAD; return !is_unordered(i);
    }
    return false;
}

// llvm/lib/IR/Instruction.cpp canUnwindPastLandingPad
can_unwind_past_landing_pad :: (lp: Value_Id, include_phase_one_unwind: bool) -> bool {
    if (inst(lp).flags & F_CLEANUP) == 0 && nops(lp) == 0 return false;   // no clauses and not cleanup: nothing
    // A landingpad with only catch clauses can catch everything when one catches null (catch-all).
    // LLVM: if (LP->isCleanup()) return IncludePhaseOneUnwind; then for each clause: catch null -> false;
    // filter with zero elements -> false (catches all); otherwise true.
    if inst(lp).flags & F_CLEANUP return include_phase_one_unwind;
    n := nops(lp);
    for k: 0..n-1 {
        c := op(lp, k);
        is_filter := ir.u32_pool[inst(lp).idx + k] != 0;
        if !is_filter {
            if is_null_value(c) return false;
        } else {
            if vkind(c) == .C_ZERO || (type_kind(vtype(c)) == .ARRAY && type_count(vtype(c)) == 0) return false;
        }
    }
    return true;
}

may_throw :: (i: Value_Id, include_phase_one_unwind := false) -> bool {
    r := inst(i);
    if r.op == {
        case .CALL; return !call_does_not_throw(i);
        case .RESUME; return true;
        case .INVOKE;
            unwind := op(i, nops(i) - 2);
            pad := block_first_non_phi(unwind);
            if pad != NONE && inst_op(pad) == .LANDINGPAD return can_unwind_past_landing_pad(pad, include_phase_one_unwind);
            return false;
        case .CLEANUPRET; return nops(i) < 2;                       // unwindsToCaller: no unwind destination
        case .CATCHSWITCH; return (r.flags & F_HAS_UNWIND) == 0;    // unwindsToCaller
        case .CLEANUPPAD; return include_phase_one_unwind;          // treated like a cleanup landingpad
    }
    return false;
}

will_return :: (i: Value_Id) -> bool {
    if is_volatile(i) return false;
    if is_call_base(i) return call_has_fn_attr(i, .WillReturn);
    return true;
}

may_have_side_effects :: (i: Value_Id) -> bool { return may_write_to_memory(i) || may_throw(i) || !will_return(i); }

is_eh_pad :: (i: Value_Id) -> bool {
    opc := inst_op(i);
    return opc == .LANDINGPAD || opc == .CLEANUPPAD || opc == .CATCHPAD || opc == .CATCHSWITCH;
}
block_is_eh_pad :: (b: Value_Id) -> bool { f := block_first_non_phi(b); return f != NONE && is_eh_pad(f); }

// ---------------------------------------------------------------- TargetLibraryInfo (the subset passes need so far)

// TLI.has(F) for the library function called `name` in the TargetLibraryInfo of `caller` (tli.jai); names that
// are not library functions are reported available (callers check the name against their own tables first).
tli_available :: (caller: Value_Id, name: string) -> bool {
    ok, lf := tli_lookup_name(name);
    if !ok return true;
    return tli_func_has(tli_for(caller), lf);
}

// The AllocationFnData / FreeFnData tables are in memory_builtins.jai.

AFK_ALLOC :: 1; AFK_REALLOC :: 2; AFK_FREE :: 4;
call_alloc_kind :: (i: Value_Id) -> u64 {
    a := call_get_fn_attr(i, .AllocKind);
    if a return a.ival;
    return 0;
}
fn_alloc_kind :: (f: Value_Id) -> u64 {
    a := attr_set_find(attr_list_fn(glob(f).attrs), .AllocKind);
    if a return a.ival;
    return 0;
}

// MemoryBuiltins.cpp getCalledFunction: not for intrinsics or nobuiltin calls
mb_called_function :: (i: Value_Id) -> Value_Id {
    if !is_call_base(i) return NONE;
    if intrinsic_id_of_call(i).count return NONE;
    if call_is_no_builtin(i) return NONE;
    return call_called_function(i);
}

is_int32_or_64 :: (t: Type_Id) -> bool { return type_kind(t) == .INT && (type_int_width(t) == 32 || type_int_width(t) == 64); }

// isAllocLikeFn(CB, TLI)
is_alloc_like_fn :: (i: Value_Id, use_tli := true) -> bool {
    if use_tli { ok := mb_alloc_data(i, AT_ALLOC_LIKE); if ok return true; }
    return is_inst(i) && is_call_base(i) && (call_alloc_kind(i) & AFK_ALLOC) != 0;
}
is_removable_alloc :: (i: Value_Id, use_tli := true) -> bool { return is_alloc_like_fn(i, use_tli); }

// getFreedOperand(CB, TLI)
get_freed_operand :: (i: Value_Id, use_tli := true) -> Value_Id {
    callee := mb_called_function(i);
    if use_tli && callee != NONE && mb_tli_knows(callee, value_function(i)) {
        ft := glob(callee).value_type;
        name := lib_func_name(callee);
        is_free_fn := false;   // isLibFreeFunction
        in_table := false;
        for FREE_FNS {
            if it.name != name continue;
            in_table = true;
            is_free_fn = func_ret(ft) == ir.t_void && func_nparams(ft) == cast(u32) it.nparams && is_ptr_type(func_param(ft, 0));
            break;
        }
        // not in FreeFnData: a TLI-known function (here: `free` with its prototype) with allockind("free")
        if !in_table && name == "free" && func_ret(ft) == ir.t_void && func_nparams(ft) == 1 && is_ptr_type(func_param(ft, 0))
            is_free_fn = (fn_alloc_kind(callee) & AFK_FREE) != 0;
        if is_free_fn return call_arg(i, 0);
    }
    if call_alloc_kind(i) & AFK_FREE return call_arg_with_attribute(i, .AllocatedPointer);
    return NONE;
}

// Math library functions isMathLibCallNoop knows, with their TLI prototypes (all fp args and result of one type;
// the `l` variants are x86_fp80 on x86_64-linux).
MATH_UNARY :: string.["log", "log2", "log10", "ilogb", "exp", "exp2", "sin", "cos", "tan", "atan", "asin", "acos",
                      "sinh", "cosh", "sqrt"];
MATH_BINARY :: string.["pow", "fmod", "remainder", "atan2", "nextafter", "nexttoward"];

// TLI.getLibFunc for a math function: returns the base name ("log" for logf/logl) and the fp kind, or "".
math_libfunc :: (callee: Value_Id) -> (base: string, k: Type_Kind) {
    known, lf := tli_lookup_fn(callee);   // the TargetLibraryInfo.td prototype (LDbl = any fp type)
    if !known return "", .VOID;
    name := vname(callee);
    ft := glob(callee).value_type;
    check :: (base: string, name: string) -> bool {
        if name == base return true;
        if name.count == base.count + 1 && begins_with(name, base) && (name[base.count] == #char "f" || name[base.count] == #char "l") return true;
        return false;
    }
    for MATH_UNARY if check(it, name) return it, type_kind(func_param(ft, 0));
    for MATH_BINARY if check(it, name) return it, type_kind(func_param(ft, 0));
    return "", .VOID;
}

fp_const_as_f64 :: (c: Value_Id) -> float64, ok: bool {
    k := type_kind(vtype(c));
    w := const_fp_value(c);
    if k == .DOUBLE { x := w[0]; return (cast(*float64) *x).*, true; }
    if k == .FLOAT { x := cast(u32) w[0]; return cast(float64)(cast(*float32) *x).*, true; }
    return 0, false;
}
fp_const_info :: (c: Value_Id) -> (nan: bool, inf: bool, zero: bool, neg: bool) {
    d := fp_decode(type_kind(vtype(c)), const_fp_value(c));
    return d.cat == .NAN, d.cat == .INF, d.cat == .ZERO, d.neg;
}

// isMathLibCallNoop(Call, TLI)
is_math_lib_call_noop :: (i: Value_Id) -> bool {
    if call_is_no_builtin(i) || call_is_strict_fp(i) return false;
    f := call_called_function(i);
    if f == NONE || glob(f).intrinsic return false;
    if !tli_available(value_function(i), vname(f)) return false;
    base, k := math_libfunc(f);
    if base.count == 0 return false;
    nargs := call_num_args(i);
    if nargs == 1 {
        c := call_arg(i, 0);
        if vkind(c) != .C_FP return false;
        nan, inf, zero, neg := fp_const_info(c);
        x, have := fp_const_as_f64(c);
        lt :: (have: bool, nan: bool, x: float64, b: float64) -> bool { return have && !nan && x < b; }
        gt :: (have: bool, nan: bool, x: float64, b: float64) -> bool { return have && !nan && x > b; }
        if base == {
            case "log"; #through;
            case "log2"; #through;
            case "log10"; return nan || (!zero && !neg);
            case "ilogb"; return !nan && !zero && !inf;
            case "exp";
                if k == .DOUBLE return !(lt(have, nan, x, -745.0) || gt(have, nan, x, 709.0));
                if k == .FLOAT return !(lt(have, nan, x, -103.0) || gt(have, nan, x, 88.0));
            case "exp2";
                if k == .DOUBLE return !(lt(have, nan, x, -1074.0) || gt(have, nan, x, 1023.0));
                if k == .FLOAT return !(lt(have, nan, x, -149.0) || gt(have, nan, x, 127.0));
            case "sin"; #through;
            case "cos"; return !inf;
            case "tan";
                if k == .DOUBLE || k == .FLOAT return host_fold_fp(.TAN, x, 0);
            case "atan"; return true;
            case "asin"; #through;
            case "acos"; if k == .X86_FP80 fatal("isMathLibCallNoop: x86_fp80 asin/acos is not supported yet");
                return !(lt(have, nan, x, -1.0) || gt(have, nan, x, 1.0));
            case "sinh"; #through;
            case "cosh";
                if k == .DOUBLE return !(lt(have, nan, x, -710.0) || gt(have, nan, x, 710.0));
                if k == .FLOAT return !(lt(have, nan, x, -89.0) || gt(have, nan, x, 89.0));
            case "sqrt"; return nan || zero || !neg;
        }
        return false;
    }
    if nargs == 2 {
        c0 := call_arg(i, 0); c1 := call_arg(i, 1);
        if vkind(c0) != .C_FP || vkind(c1) != .C_FP return false;
        nan0, inf0, zero0, neg0 := fp_const_info(c0);
        nan1, inf1, zero1, neg1 := fp_const_info(c1);
        if base == {
            case "pow";
                if (k == .DOUBLE || k == .FLOAT) && vtype(c0) == vtype(c1) {
                    x, _ := fp_const_as_f64(c0); y, _2 := fp_const_as_f64(c1);
                    return host_fold_fp(.POW, x, y);
                }
            case "fmod"; #through;
            case "remainder"; return nan0 || nan1 || (!inf0 && !zero1);
            case "atan2"; return !zero0 || !zero1;
            case "nextafter"; #through;
            case "nexttoward";
                return cfc_next_toward(type_kind(vtype(c0)), const_fp_value(c0), type_kind(vtype(c1)), const_fp_value(c1), func_ret(glob(f).value_type)) != NONE;
        }
    }
    return false;
}
// ConstantFoldFP / ConstantFoldBinaryFP (ConstantFolding.cpp): call the host libm in double precision and fail when
// llvm_fenv_testexcept() reports errno ERANGE/EDOM or a floating-point exception other than FE_INEXACT.
Host_Fp_Fn :: enum u8 { TAN; POW; }
libm :: #system_library "libm";
c_tan :: (x: float64) -> float64 #foreign libm "tan";
c_pow :: (x: float64, y: float64) -> float64 #foreign libm "pow";
c_feclearexcept :: (e: s32) -> s32 #foreign libm "feclearexcept";
c_fetestexcept :: (e: s32) -> s32 #foreign libm "fetestexcept";
libc_for_errno :: #system_library "libc";
c_errno_location :: () -> *s32 #foreign libc_for_errno "__errno_location";
FE_INEXACT_X86 :: 0x20;
FE_ALL_EXCEPT_X86 :: 0x3d;
host_fold_fp :: (fn: Host_Fp_Fn, x: float64, y: float64) -> bool {
    c_feclearexcept(FE_ALL_EXCEPT_X86);
    c_errno_location().* = 0;
    r: float64;
    if fn == .TAN r = c_tan(x); else r = c_pow(x, y);
    e := c_errno_location().*;
    if e == 34 || e == 33 { c_feclearexcept(FE_ALL_EXCEPT_X86); return false; }   // ERANGE, EDOM
    if c_fetestexcept(FE_ALL_EXCEPT_X86 & ~FE_INEXACT_X86) { c_feclearexcept(FE_ALL_EXCEPT_X86); return false; }
    return true;
}

// ---------------------------------------------------------------- triviality of death (Local.cpp)

is_lifetime_intrinsic :: (id: string) -> bool { return id == "llvm.lifetime.start" || id == "llvm.lifetime.end"; }

// isAssumeWithEmptyBundle: no bundles other than "ignore"
is_assume_with_empty_bundle :: (i: Value_Id) -> bool { return !call_has_bundles_other_than(i, .["ignore"]); }

// ConstrainedFPIntrinsic::getExceptionBehavior == ebStrict
constrained_fp_is_strict :: (i: Value_Id) -> bool {
    // the exception behavior is the last argument (metadata string "fpexcept.*")
    n := call_num_args(i);
    if n == 0 return false;
    m := call_arg(i, n - 1);
    if vkind(m) != .MD_VALUE return false;
    md := ir.v_aux[m];
    if md == NONE || ir.mds[md].kind != .STRING return false;
    return ir.mds[md].str == "fpexcept.strict";
}

// wouldInstructionBeTriviallyDead(I, TLI). use_tli = false is a call with TLI == nullptr (BDCE): library
// allocation/free functions and isMathLibCallNoop don't count then, only `allockind` attributes.
would_instruction_be_trivially_dead :: (i: Value_Id, use_tli := true) -> bool {
    opc := inst_op(i);
    if is_terminator(opc) return false;
    if is_eh_pad(i) return false;
    if is_call_base(i) && is_removable_alloc(i, use_tli) return true;
    id := intrinsic_id_of_call(i);
    if !will_return(i) {
        if id.count == 0 return false;
        if id == "llvm.experimental.guard" {
            c := call_arg(i, 0);
            return vkind(c) == .C_INT && const_int_zext(c) == 1;
        }
        if id == "llvm.wasm.trunc.signed" || id == "llvm.wasm.trunc.unsigned" || id == "llvm.ptrauth.auth" ||
           id == "llvm.ptrauth.resign" || id == "llvm.ptrauth.resign.load.relative" return true;
        return false;
    }
    if !may_have_side_effects(i) return true;
    if id.count {
        if id == "llvm.stacksave" || id == "llvm.launder.invariant.group" return true;
        if id == "llvm.allow.runtime.check" || id == "llvm.allow.ubsan.check" return true;
        if is_lifetime_intrinsic(id) {
            arg := call_arg(i, 0);
            if vkind(arg) == .C_POISON return true;
            u := ir.v_first_use[arg];
            while u != NONE {
                user := ir.u_user[u];
                if !is_inst(user) || !is_lifetime_intrinsic(intrinsic_id_of_call(user)) return false;
                u = ir.u_next[u];
            }
            return true;
        }
        if id == "llvm.assume" && is_assume_with_empty_bundle(i) {
            c := call_arg(i, 0);
            if vkind(c) == .C_INT return const_int_zext(c) != 0;
            return false;
        }
        if begins_with(id, "llvm.experimental.constrained.") return !constrained_fp_is_strict(i);
    }
    if is_call_base(i) {
        freed := get_freed_operand(i, use_tli);
        if freed != NONE && is_constant_kind(vkind(freed))
            return is_null_value(freed) || vkind(freed) == .C_UNDEF || vkind(freed) == .C_POISON;
        if use_tli && is_math_lib_call_noop(i) return true;
    }
    if opc == .LOAD {
        gv := strip_pointer_casts(op(i, 0));
        if gv != NONE && vkind(gv) == .GLOBAL_VAR && (inst(i).flags & F_VOLATILE) == 0 && glob(gv).is_const return true;
    }
    return false;
}

// isInstructionTriviallyDead(I, TLI)
is_instruction_trivially_dead :: (i: Value_Id) -> bool {
    if has_uses(i) return false;
    return would_instruction_be_trivially_dead(i);
}

