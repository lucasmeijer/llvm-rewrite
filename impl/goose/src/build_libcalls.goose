// BuildLibCalls: port of llvm/lib/Transforms/Utils/BuildLibCalls.cpp (inferNonMandatoryLibFuncAttrs with its set*
// helpers, getOrInsertLibFunc, isLibFuncEmittable, hasFloatFn/getFloatFn, emitLibCall and the emit* helpers
// LibCallSimplifier uses) and the InferFunctionAttrs pass (llvm/lib/Transforms/IPO/InferFunctionAttrs.cpp).
//
// inferNonMandatoryLibFuncAttrs's switch is the statement program BLC_PROG of gen_libfunc_attrs.goose
// (tools/gen_libfunc_attrs.py), interpreted by blc_infer in LLVM's order including fallthroughs.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_tli;
import gen_libfunc_attrs;
import datalayout;
import tli;
import autoupgrade;
import memloc;

fn blc_not_ported(what: const u8[:]) { fatal(str("BuildLibCalls: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// Function attribute editing (Function::addFnAttr / addRetAttr / addParamAttr)

// index: 0 = function, 1 = return, 2 + k = parameter k (AttributeList's internal order)
fn fn_aset(fv: i32, idx: i64) -> i32 {
    let l = globs[glob_of(fv)].attrs;
    if l == 0 { return 0; }
    if idx == 0 { return alist_fn(l); }
    if idx == 1 { return alist_ret(l); }
    return alist_param(l, idx - 2);
}
fn fn_set_aset(fv: i32, idx: i64, s: i32) {
    let g = glob_of(fv);
    let l = globs[g].attrs;
    let n = if l == 0 { 0 } else { alists[l].n as i64 };
    var sets: i32[>..<] = [];
    for j in 0..max(n, idx + 1) {
        var x: i32 = 0;
        if j < n { x = alist_runs[alists[l].at + j]; }
        if j == idx { x = s; }
        sets.push(x);
    }
    globs[g].attrs = alist_get(sets);
}
fn fn_add_attr(fv: i32, idx: i64, a: i32) {
    let s = fn_aset(fv, idx);
    var xs: i32[>..<] = [];
    for k in aset_n(s) { let x = aset_attr(s, k); if attrs[x].kind != attrs[a].kind || attrs[a].kind == 0 { xs.push(x); } }
    xs.push(a);
    fn_set_aset(fv, idx, aset_get(xs));
}
fn fn_has(fv: i32, idx: i64, kind: i64) -> bool { aset_has(fn_aset(fv, idx), kind) }

// Function::getMemoryEffects / setMemoryEffects
fn fn_memory_effects(fv: i32) -> u64 { aset_memory(fn_aset(fv, 0)) }

fn blc_set_enum(fv: i32, idx: i64, kind: i64) -> bool {
    if fn_has(fv, idx, kind) { return false; }
    fn_add_attr(fv, idx, attr_enum(kind));
    return true;
}
fn blc_set_memory(fv: i32, me: u64) -> bool {
    let orig = fn_memory_effects(fv);
    let nm = orig & me;
    if orig == nm { return false; }
    fn_add_attr(fv, 0, attr_int(AK_Memory, nm));
    return true;
}

// MemoryEffects constructors (llvm/Support/ModRef.h)
fn me_arg_only() -> u64 { me_set(0, LOC_ARG, MR_MODREF) }
fn me_inacc_or_arg() -> u64 { me_set(me_set(0, LOC_ARG, MR_MODREF), LOC_INACCESSIBLE, MR_MODREF) }
fn me_inacc_or_errno() -> u64 { me_set(me_set(0, LOC_INACCESSIBLE, MR_MODREF), LOC_ERRNO, MR_MOD) }
fn me_inacc_or_arg_or_errno() -> u64 { me_set(me_inacc_or_arg(), LOC_ERRNO, MR_MOD) }

// isReallocLikeFn(F): allockind has Realloc
fn fn_alloc_kind(fv: i32) -> u64 { aset_int_v(fn_aset(fv, 0), AK_AllocKind) }
fn aset_int_v(s: i32, kind: i64) -> u64 { let a = aset_find(s, kind); if a < 0 { 0 } else { attrs[a].i1 } }

// isLibFreeFunction(F, LibFunc)
fn blc_is_lib_free_function(fv: i32, lf: i32) -> bool {
    let fty = globs[glob_of(fv)].vty;
    var k: i64 = 0;
    while k < TLI_FREE_DATA.len {
        if TLI_FREE_DATA[k] == lf {
            if ty_kind(ty_fn_ret(fty)) != TK_VOID { return false; }
            if ty_fn_nparams(fty) != TLI_FREE_DATA[k + 1] as i64 { return false; }
            if ty_kind(ty_fn_param(fty, 0)) != TK_PTR { return false; }
            return true;
        }
        k += 2;
    }
    return (fn_alloc_kind(fv) & 4) != 0;
}

// The decoded statement program
var blc_stmt_at: i32[>..<];
var blc_stmt_len: i32[>..<];
var blc_entry: i32[>..<];
fn blc_decode() {
    if blc_entry.len > 0 { return; }
    var st: i64 = 0;
    for i in 0..BLC_PROG.len + 1 {
        if i == BLC_PROG.len || BLC_PROG[i] == '|' {
            blc_stmt_at.push(st as i32);
            blc_stmt_len.push((i - st) as i32);
            st = i + 1;
        }
    }
    var v: i64 = 0;
    var neg = false;
    for i in 0..BLC_ENTRY.len + 1 {
        if i == BLC_ENTRY.len || BLC_ENTRY[i] == ',' {
            blc_entry.push((if neg { -v } else { v }) as i32);
            v = 0;
            neg = false;
        } else if BLC_ENTRY[i] == '-' { neg = true; }
        else { v = v * 10 + (BLC_ENTRY[i] - '0') as i64; }
    }
}
// the k-th space-separated word of statement s
fn blc_word(s: i64, k: i64) -> const u8[:] {
    let a = blc_stmt_at[s] as i64;
    let e = a + blc_stmt_len[s] as i64;
    var w: i64 = 0;
    var b = a;
    for i in a..e + 1 {
        if i == e || BLC_PROG[i] == ' ' {
            if w == k { return BLC_PROG[b..i]; }
            w++;
            b = i + 1;
        }
    }
    return "";
}
fn blc_num(s: const u8[:]) -> i64 {
    var v: i64 = 0;
    var neg = false;
    for c in s { if c == '-' { neg = true; } else { v = v * 10 + (c - '0') as i64; } }
    return if neg { -v } else { v };
}

// inferNonMandatoryLibFuncAttrs(F, TLI)
fn blc_infer(fv: i32) -> bool {
    let lf = tli_get_libfunc(fv);
    if lf < 0 || !tli_has(lf) { return false; }
    var changed = false;
    if module_rtlib_use_got(globs[glob_of(fv)].module) { changed = blc_set_enum(fv, 0, AK_NonLazyBind) || changed; }
    blc_decode();
    var s = blc_entry[lf] as i64;
    while s >= 0 && s < blc_stmt_at.len {
        let op = blc_word(s, 0);
        if op == "break" { break; }
        if op == "return" { return changed; }
        let a1 = blc_word(s, 1);
        let has1 = a1.len > 0;
        let n1 = if has1 && a1[0] != '?' { blc_num(a1) } else { 0 };
        var c = false;
        if op == "DoesNotAccessMemory" { c = blc_set_memory(fv, 0); }
        else if op == "IsCold" { c = blc_set_enum(fv, 0, AK_Cold); }
        else if op == "NoReturn" { c = blc_set_enum(fv, 0, AK_NoReturn); }
        else if op == "OnlyReadsMemory" { c = if has1 { blc_set_enum(fv, 2 + n1, AK_ReadOnly) } else { blc_set_memory(fv, 0x555) }; }
        else if op == "OnlyWritesMemory" { c = if has1 { blc_set_enum(fv, 2 + n1, AK_WriteOnly) } else { blc_set_memory(fv, 0xAAA) }; }
        else if op == "OnlyAccessesArgMemory" { c = blc_set_memory(fv, me_arg_only()); }
        else if op == "OnlyAccessesInaccessibleMemOrArgMem" { c = blc_set_memory(fv, me_inacc_or_arg()); }
        else if op == "OnlyAccessesInaccessibleMemOrErrnoMem" { c = blc_set_memory(fv, me_inacc_or_errno()); }
        else if op == "OnlyAccessesInaccessibleMemOrArgMemOrErrnoMem" { c = blc_set_memory(fv, me_inacc_or_arg_or_errno()); }
        else if op == "OnlyWritesErrnoMemory" { c = blc_set_memory(fv, me_set(0, LOC_ERRNO, MR_MOD)); }
        else if op == "OnlyWritesArgMemOrErrnoMem" { c = blc_set_memory(fv, me_set(me_set(0, LOC_ARG, MR_MOD), LOC_ERRNO, MR_MOD)); }
        else if op == "DoesNotThrow" { c = blc_set_enum(fv, 0, AK_NoUnwind); }
        else if op == "DoesNotCallback" { c = blc_set_enum(fv, 0, AK_NoCallback); }
        else if op == "RetDoesNotAlias" { c = blc_set_enum(fv, 1, AK_NoAlias); }
        else if op == "DoesNotCapture" {
            if !fn_has(fv, 2 + n1, AK_Captures) { fn_add_attr(fv, 2 + n1, attr_int(AK_Captures, 0)); c = true; }
        }
        else if op == "DoesNotAlias" { c = blc_set_enum(fv, 2 + n1, AK_NoAlias); }
        else if op == "DoesNotSync" { c = blc_set_enum(fv, 0, AK_NoSync); }
        else if op == "RetNoUndef" { c = blc_set_ret_noundef(fv); }
        else if op == "ArgsNoUndef" { c = blc_set_args_noundef(fv); }
        else if op == "ArgNoUndef" { c = blc_set_enum(fv, 2 + n1, AK_NoUndef); }
        else if op == "RetAndArgsNoUndef" { let r = blc_set_ret_noundef(fv); let a = blc_set_args_noundef(fv); c = r || a; }
        else if op == "ReturnedArg" { c = blc_set_enum(fv, 2 + n1, AK_Returned); }
        else if op == "DoesNotFreeMemory" { c = blc_set_enum(fv, 0, AK_NoFree); }
        else if op == "WillReturn" { c = blc_set_enum(fv, 0, AK_WillReturn); }
        else if op == "AlignedAllocParam" { c = blc_set_enum(fv, 2 + n1, AK_AllocAlign); }
        else if op == "AllocatedPointerParam" { c = blc_set_enum(fv, 2 + n1, AK_AllocatedPointer); }
        else if op == "AllocSize" {
            if !fn_has(fv, 0, AK_AllocSize) {
                let b = blc_num(blc_word(s, 2));
                let nv: u64 = if b < 0 { 0xFFFFFFFF } else { b as u64 };
                fn_add_attr(fv, 0, attr_int(AK_AllocSize, ((n1 as u64) << 32) | nv));
                c = true;
            }
        }
        else if op == "AllocFamily" {
            if aset_find_str(fn_aset(fv, 0), "alloc-family") < 0 {
                var fam = a1;
                if a1[0] == '?' {
                    // ?<LibFunc>:<then>:<else>
                    var p1: i64 = 0;
                    var p2: i64 = 0;
                    for i in a1.len { if a1[i] == ':' { if p1 == 0 { p1 = i; } else { p2 = i; } } }
                    fam = if lf as i64 == tli_def(a1[1..p1]) { a1[p1 + 1..p2] } else { a1[p2 + 1..] };
                }
                var fb: u8[>..] = [];
                fb.append(fam);
                fn_add_attr(fv, 0, attr_str("alloc-family", fb, true));
                c = true;
            }
        }
        else if op == "AllocKind" {
            if !fn_has(fv, 0, AK_AllocKind) { fn_add_attr(fv, 0, attr_int(AK_AllocKind, n1 as u64)); c = true; }
        }
        else { fatal(str("internal: unknown BuildLibCalls statement ", op)); }
        if c { changed = true; }
        s++;
    }
    if !blc_is_lib_free_function(fv, lf) && (fn_alloc_kind(fv) & 2) == 0 {
        if blc_set_enum(fv, 0, AK_NoFree) { changed = true; }
    }
    return changed;
}
fn blc_set_ret_noundef(fv: i32) -> bool {
    if ty_fn_ret(globs[glob_of(fv)].vty) != T_VOID && !fn_has(fv, 1, AK_NoUndef) {
        fn_add_attr(fv, 1, attr_enum(AK_NoUndef));
        return true;
    }
    return false;
}
fn blc_set_args_noundef(fv: i32) -> bool {
    var changed = false;
    for k in ty_fn_nparams(globs[glob_of(fv)].vty) {
        if !fn_has(fv, 2 + k, AK_NoUndef) { fn_add_attr(fv, 2 + k, attr_enum(AK_NoUndef)); changed = true; }
    }
    return changed;
}

// Module::getRtLibUseGOT: the "RtLibUseGOT" module flag
fn module_rtlib_use_got(m: i32) -> bool { module_flag_int(m, "RtLibUseGOT") > 0 }
// a module flag's integer value (-1 = absent)
fn module_flag_int(m: i32, key: const u8[:]) -> i64 {
    for &nm in named_mds {
        if nm.module != m || sbytes(nm.name) != "llvm.module.flags" { continue; }
        for i in nm.nops {
            let e = md_ops[nm.ops + i];
            if e < 0 || mds[e].kind != MK_TUPLE || mds[e].nops < 3 { continue; }
            let kk = md_op(e, 1);
            if kk < 0 || mds[kk].kind != MK_STRING || sbytes(mds[kk].extra) != key { continue; }
            let v = md_op(e, 2);
            if v >= 0 && mds[v].kind == MK_VALUE && vals[mds[v].extra].kind == VK_CINT { return cint_lo(mds[v].extra) as! i64; }
            return 0;
        }
    }
    return -1;
}

// inferNonMandatoryLibFuncAttrs(M, Name, TLI)
fn blc_infer_by_name(name: const u8[:]) -> bool {
    let f = symtab_lookup(modules[cur_module].symtab, intern(name));
    if f < 0 || vals[f].kind != VK_FUNC { return false; }
    return blc_infer(f);
}

// ---------------------------------------------------------------------------------------------
// isLibFuncEmittable, getOrInsertLibFunc

// isLibFuncEmittable(M, TLI, LibFunc)
fn blc_is_emittable(lf: i64) -> bool {
    if !tli_has(lf as i32) { return false; }
    let gv = symtab_lookup(modules[cur_module].symtab, intern(TLI_NAMES[lf]));
    if gv >= 0 {
        if vals[gv].kind == VK_FUNC { return tli_valid_proto(globs[glob_of(gv)].vty, lf as i32); }
        return false;
    }
    return true;
}
// isLibFuncEmittable(M, TLI, Name)
fn blc_is_emittable_name(name: const u8[:]) -> bool {
    let lf = tli_lookup_name(name);
    return lf >= 0 && blc_is_emittable(lf as i64);
}

// Module::getOrInsertFunction(Name, T, AttributeList)
fn module_get_or_insert_function(name: const u8[:], fty: i32, al: i32) -> i32 {
    let ex = symtab_lookup(modules[cur_module].symtab, intern(name));
    if ex >= 0 {
        if vals[ex].kind == VK_FUNC { return ex; }
        blc_not_ported("getOrInsertFunction of a name used by a non-function");
    }
    let f = au_create_function(name, fty);
    globs[glob_of(f)].attrs = al;
    return f;
}

// getOrInsertLibFunc(M, TLI, TheLibFunc, T, AttributeList)
fn blc_get_or_insert(lf: i64, fty: i32, al: i32) -> i32 {
    let f = module_get_or_insert_function(TLI_NAMES[lf], fty, al);
    // setArgExtAttr / setRetExtAttr: no extension attributes on the targets we support (x86-64)
    // markRegisterParameterAttributes
    if ty_fn_nparams(fty) > 0 && !ty_fn_vararg(fty) {
        let cc = globs[glob_of(f)].cc as i64;
        if (cc == 0 || cc == 64) && module_flag_int(globs[glob_of(f)].module, "NumRegisterParameters") > 0 {
            blc_not_ported("markRegisterParameterAttributes (NumRegisterParameters)");
        }
    }
    return f;
}

// FunctionType::get(Ret, Params, VarArg)
fn ty_func_of(ret: i32, ps: const i32[:], va: bool) -> i32 {
    let at = ints.len as i32;
    ints.push(ret);
    for p in ps { ints.push(p); }
    return ty_func_run(at, ps.len + 1, va);
}

// hasFloatFn(M, TLI, Ty, DoubleFn, FloatFn, LongDoubleFn)
fn blc_has_float_fn(ty: i32, d: i64, f: i64, l: i64) -> bool {
    let k = ty_kind(ty);
    if k == TK_HALF { return false; }
    if k == TK_FLOAT { return blc_is_emittable(f); }
    if k == TK_DOUBLE { return blc_is_emittable(d); }
    return blc_is_emittable(l);
}
// getFloatFn: the LibFunc
fn blc_get_float_fn(ty: i32, d: i64, f: i64, l: i64) -> i64 {
    let k = ty_kind(ty);
    if k == TK_FLOAT { return f; }
    if k == TK_DOUBLE { return d; }
    return l;
}

// ---------------------------------------------------------------------------------------------
// InferFunctionAttrs (llvm/lib/Transforms/IPO/InferFunctionAttrs.cpp) and inferAttributesFromOthers (Local.cpp)

// inferAttributesFromOthers(F)
fn infer_attributes_from_others(fv: i32) -> bool {
    var changed = false;
    if !fn_has(fv, 0, AK_NoSync) && fn_memory_effects(fv) == 0 && !fn_has(fv, 0, AK_Convergent) {
        fn_add_attr(fv, 0, attr_enum(AK_NoSync));
        changed = true;
    }
    if !fn_has(fv, 0, AK_NoFree) && (fn_memory_effects(fv) & 0xAAA) == 0 {
        fn_add_attr(fv, 0, attr_enum(AK_NoFree));
        changed = true;
    }
    if !fn_has(fv, 0, AK_MustProgress) && fn_has(fv, 0, AK_WillReturn) {
        fn_add_attr(fv, 0, attr_enum(AK_MustProgress));
        changed = true;
    }
    return changed;
}

// inferAllPrototypeAttributes(M, GetTLI)
fn inferattrs_run(m: i32) -> bool {
    var changed = false;
    let save = tli_cur_fn;
    let save_m = cur_module;
    cur_module = m;
    var f = modules[m].first_func;
    while f >= 0 {
        if func_is_decl(f) && !fn_has(f, 0, AK_OptimizeNone) {
            tli_cur_fn = f;
            if !fn_has(f, 0, AK_NoBuiltin) { if blc_infer(f) { changed = true; } }
            if infer_attributes_from_others(f) { changed = true; }
        }
        f = globs[glob_of(f)].next;
    }
    tli_cur_fn = save;
    cur_module = save_m;
    return changed;
}
