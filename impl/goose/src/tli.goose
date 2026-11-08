// TargetLibraryInfo for x86-64 targets: library function recognition (getLibFunc + isValidProtoForLibFunc),
// availability (initializeLibCalls for Linux/GNU and other non-Darwin, non-Windows triples; per-function
// "no-builtins" / "no-builtin-<name>"), plus MemoryBuiltins.cpp's alloc/free tables and ConstantFolding.cpp's
// isMathLibCallNoop. Ports llvm/lib/Analysis/TargetLibraryInfo.cpp, MemoryBuiltins.cpp, ConstantFolding.cpp.
import std;
import binary;
import math;
import ir;
import irutil;
import calls;
import gen_tli;
import gen_attrs;
import instinfo;
import apfloat;

// ---------------------------------------------------------------------------------------------
// Availability (TargetLibraryInfoImpl::AvailableArray), computed once per module triple.

var tli_avail: bool[>..];
var tli_avail_triple: i32 = -2;
var tli_cur_fn: i32 = -1;        // the function the current pass runs on (TargetLibraryAnalysis(F))

fn tli_unavail(names: const u8[:][]) {
    for nm in names {
        let lf = tli_lookup_name(nm);
        if lf < 0 { fatal(str("internal: unknown libfunc ", nm)); }
        tli_avail[lf] = false;
    }
}

fn tli_init(m: i32) {
    let tt = modules[m].triple;
    if tli_avail_triple == tt && tli_avail.len == LF_COUNT { return; }
    tli_avail_triple = tt;
    let t: const u8[:] = if tt >= 0 { sbytes(tt) } else { "" };
    let is_linux = find(t, "linux") >= 0;
    let is_gnu = find(t, "-gnu") >= 0;
    let is_musl = find(t, "musl") >= 0;
    if find(t, "darwin") >= 0 || find(t, "macos") >= 0 || find(t, "ios") >= 0 || find(t, "windows") >= 0 ||
       find(t, "freebsd") >= 0 || find(t, "aix") >= 0 || find(t, "nvptx") >= 0 || find(t, "amdgcn") >= 0 ||
       find(t, "ps4") >= 0 || find(t, "ps5") >= 0 || find(t, "solaris") >= 0 || find(t, "dxil") >= 0 ||
       find(t, "emscripten") >= 0 || find(t, "mingw") >= 0 || find(t, "cygwin") >= 0 {
        fatal(str("TargetLibraryInfo: triple '", t, "' is not supported yet (only Linux and generic triples)"));
    }
    tli_avail.clear();
    tli_avail.resize(LF_COUNT, true);
    tli_unavail(["getc_unlocked", "getchar_unlocked", "putc_unlocked", "putchar_unlocked", "fputc_unlocked",
        "fgetc_unlocked", "fread_unlocked", "fwrite_unlocked", "fputs_unlocked", "fgets_unlocked"]);
    tli_unavail(["memset_pattern4", "memset_pattern8", "memset_pattern16"]);
    tli_unavail(["sinpi", "sinpif", "cospi", "cospif", "__sincospi_stret", "__sincospif_stret"]);
    if !(is_linux && (is_gnu || is_musl)) { tli_unavail(["bcmp"]); }
    tli_unavail(["iprintf", "siprintf", "fiprintf", "__small_printf", "__small_sprintf", "__small_fprintf"]);
    tli_unavail(["??2@YAPAXI@Z", "??2@YAPAXIABUnothrow_t@std@@@Z", "??2@YAPEAX_K@Z", "??2@YAPEAX_KAEBUnothrow_t@std@@@Z",
        "??3@YAXPAX@Z", "??3@YAXPAXABUnothrow_t@std@@@Z", "??3@YAXPAXI@Z", "??3@YAXPEAX@Z",
        "??3@YAXPEAXAEBUnothrow_t@std@@@Z", "??3@YAXPEAX_K@Z", "??_U@YAPAXI@Z", "??_U@YAPAXIABUnothrow_t@std@@@Z",
        "??_U@YAPEAX_K@Z", "??_U@YAPEAX_KAEBUnothrow_t@std@@@Z", "??_V@YAXPAX@Z", "??_V@YAXPAXABUnothrow_t@std@@@Z",
        "??_V@YAXPAXI@Z", "??_V@YAXPEAX@Z", "??_V@YAXPEAXAEBUnothrow_t@std@@@Z", "??_V@YAXPEAX_K@Z"]);
    tli_unavail(["exp10", "exp10f", "exp10l"]);
    if !is_linux { tli_unavail(["ffsl", "ffsll"]); }
    tli_unavail(["fls", "flsl", "flsll"]);
    if !(is_linux && is_gnu) {
        tli_unavail(["__strdup", "__strtok_r", "__isoc99_scanf", "__isoc99_sscanf", "_IO_getc", "_IO_putc"]);
        if !is_musl { tli_unavail(["memalign"]); }
        tli_unavail(["fopen64", "fseeko64", "fstat64", "fstatvfs64", "ftello64", "lstat64", "open64", "stat64",
            "statvfs64", "tmpfile64"]);
        tli_unavail(["__acos_finite", "__acosf_finite", "__acosl_finite", "__acosh_finite", "__acoshf_finite",
            "__acoshl_finite", "__asin_finite", "__asinf_finite", "__asinl_finite", "__atan2_finite",
            "__atan2f_finite", "__atan2l_finite", "__atanh_finite", "__atanhf_finite", "__atanhl_finite",
            "__cosh_finite", "__coshf_finite", "__coshl_finite", "__exp10_finite", "__exp10f_finite",
            "__exp10l_finite", "__exp2_finite", "__exp2f_finite", "__exp2l_finite", "__exp_finite",
            "__expf_finite", "__expl_finite", "__log10_finite", "__log10f_finite", "__log10l_finite",
            "__log2_finite", "__log2f_finite", "__log2l_finite", "__log_finite", "__logf_finite",
            "__logl_finite", "__pow_finite", "__powf_finite", "__powl_finite", "__sinh_finite",
            "__sinhf_finite", "__sinhl_finite", "__sqrt_finite", "__sqrtf_finite", "__sqrtl_finite"]);
    } else {
        let ok: const u8[:][] = ["getc_unlocked", "getchar_unlocked", "putc_unlocked", "putchar_unlocked",
            "fputc_unlocked", "fgetc_unlocked", "fread_unlocked", "fwrite_unlocked", "fputs_unlocked", "fgets_unlocked"];
        for nm in ok { tli_avail[tli_lookup_name(nm)] = true; }
    }
    tli_unavail(["__nvvm_reflect", "vec_calloc", "vec_malloc", "vec_realloc", "vec_free"]);
}

// getLibFunc(StringRef): exact name lookup (binary search over the sorted table).
fn tli_lookup_name(name: const u8[:]) -> i32 {
    var lo: i64 = 0;
    var hi: i64 = TLI_SORTED.len - 1;
    while lo <= hi {
        let mid = (lo + hi) / 2;
        let id = TLI_SORTED[mid];
        let c = bytes_cmp(TLI_NAMES[id], name);
        if c == 0 { return id; }
        if c < 0 { lo = mid + 1; } else { hi = mid - 1; }
    }
    return -1;
}

let TLI_INT_BITS = 32;
let TLI_SIZET_BITS = 64;

fn tli_match_type(c: u8, t: i32) -> bool {
    let k = ty_kind(t);
    let isint = k == TK_INT;
    let bits = if isint { ty_bits(t) } else { 0 };
    match c {
        'v' => k == TK_VOID,
        'b' => isint && bits == 8,
        'h' => isint && bits == 16,
        'w' => isint && bits == 32,
        'i' => isint && bits == TLI_INT_BITS,
        'I', 'l' => isint && bits >= TLI_INT_BITS,
        'x' => isint,
        'q', 'L' => isint && bits == 64,
        'z', 'Z' => isint && bits == TLI_SIZET_BITS,
        'f' => k == TK_FLOAT,
        'd' => k == TK_DOUBLE,
        'D', 'F' => ty_is_fp(t),
        'p' => k == TK_PTR,
        's' => k == TK_STRUCT,
        _ => false,
    }
}

// isValidProtoForLibFunc (the manually checked cabs/sincospi_stret/size_returning_new cases are not ported:
// they are reported as not matching).
fn tli_valid_proto(fty: i32, lf: i32) -> bool {
    let sig = TLI_SIGS[lf];
    if sig[0] == '?' { return false; }
    if starts_with(TLI_NAMES[lf], "__size_returning_new") { return false; }
    let np = ty_fn_nparams(fty);
    var idx: i64 = 0;
    var t: i32 = ty_fn_ret(fty);
    var last = t;
    while idx < sig.len {
        let c = sig[idx];
        if c == 'e' { return ty_fn_vararg(fty); }
        if c == '=' {
            if t != last { return false; }
        } else {
            if t < 0 || !tli_match_type(c, t) { return false; }
            last = t;
        }
        if idx == np { t = -1; idx++; continue; }
        t = ty_fn_param(fty, idx);
        idx++;
    }
    return idx == np + 1 && !ty_fn_vararg(fty);
}

// getLibFunc(const Function&): not for intrinsics; the name (minus a leading \1) must be known and the
// prototype must match.
fn tli_get_libfunc(fv: i32) -> i32 {
    let g = glob_of(fv);
    if globs[g].intrinsic != 0 { return -1; }
    if vals[fv].name < 0 { return -1; }
    var nm = sbytes(vals[fv].name);
    if nm.len > 0 && nm[0] == 1 { nm = nm[1..]; }
    if nm.len == 0 { return -1; }
    let lf = tli_lookup_name(nm);
    if lf < 0 { return -1; }
    if !tli_valid_proto(globs[g].vty, lf) { return -1; }
    return lf;
}

// TargetLibraryInfo::has(F) for the current function: available for the triple and not disabled by the
// caller's "no-builtins" / "no-builtin-<name>" attributes.
fn tli_has(lf: i32) -> bool {
    let fv = tli_cur_fn;
    if fv < 0 { fatal("internal: TargetLibraryInfo used outside of a function pass"); }
    tli_init(globs[glob_of(fv)].module);
    if !tli_avail[lf] { return false; }
    let s = alist_fn(globs[glob_of(fv)].attrs);
    for k in aset_n(s) {
        let a = aset_attr(s, k);
        if attrs[a].kind != 0 { continue; }
        let key = sbytes(attrs[a].skey);
        if key == "no-builtins" { return false; }
        if starts_with(key, "no-builtin-") && key[11..] == TLI_NAMES[lf] { return false; }
    }
    return true;
}

// getLibFunc + has
fn tli_lib_func_available(fv: i32) -> i32 {
    let lf = tli_get_libfunc(fv);
    if lf < 0 || !tli_has(lf) { return -1; }
    return lf;
}

// getAllocationDataForFunction(Callee, AllocLike, TLI) != nullopt
fn tli_alloc_like(fv: i32) -> bool {
    let fty = globs[glob_of(fv)].vty;
    if ty_kind(ty_fn_ret(fty)) != TK_PTR { return false; }
    let lf = tli_lib_func_available(fv);
    if lf < 0 { return false; }
    var k: i64 = 0;
    while k < TLI_ALLOC_DATA.len {
        if TLI_ALLOC_DATA[k] == lf {
            let np = TLI_ALLOC_DATA[k + 2] as i64;
            let fst = TLI_ALLOC_DATA[k + 3] as i64;
            let snd = TLI_ALLOC_DATA[k + 4] as i64;
            fn int3264(t: i32) -> bool { ty_is_int(t) && (ty_bits(t) == 32 || ty_bits(t) == 64) }
            return ty_fn_nparams(fty) == np && (fst < 0 || int3264(ty_fn_param(fty, fst))) &&
                (snd < 0 || int3264(ty_fn_param(fty, snd)));
        }
        k += 6;
    }
    return false;
}

// TLI lookup + isLibFreeFunction (the allockind("free") fallback is the caller's).
fn tli_is_free_fn(fv: i32) -> bool {
    let lf = tli_lib_func_available(fv);
    if lf < 0 { return false; }
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
    return false;
}

// ---------------------------------------------------------------------------------------------
// isMathLibCallNoop (ConstantFolding.cpp)

fn cfp_is_nan(v: i32) -> bool { fp_decompose(ty_kind(vals[v].ty) as i64, cint_lo(v), cint_hi(v)).cat == FC_NAN }
fn cfp_is_zero(v: i32) -> bool { fp_decompose(ty_kind(vals[v].ty) as i64, cint_lo(v), cint_hi(v)).cat == FC_ZERO }
fn cfp_is_inf(v: i32) -> bool { fp_decompose(ty_kind(vals[v].ty) as i64, cint_lo(v), cint_hi(v)).cat == FC_INF }
fn cfp_is_neg(v: i32) -> bool { fp_decompose(ty_kind(vals[v].ty) as i64, cint_lo(v), cint_hi(v)).neg }

// The constant as a host double (exact for half/float/double).
fn cfp_to_f64(v: i32) -> f64 {
    let k = ty_kind(vals[v].ty) as i64;
    if k == TK_DOUBLE { return binary::f64_of_bits(cint_lo(v)); }
    if k == TK_FLOAT { return binary::f64_of_bits(fp_convert(TK_FLOAT, TK_DOUBLE, cint_lo(v), 0)); }
    if k == TK_HALF { return binary::f64_of_bits(fp_convert(TK_HALF, TK_DOUBLE, cint_lo(v), 0)); }
    fatal("isMathLibCallNoop: only half/float/double constants are supported");
    return 0.0;
}

// llvm_fenv_testexcept after a host libm call, approximated: an invalid/overflow/divide-by-zero exception
// shows as a NaN from non-NaN inputs or an infinity from finite inputs. (Underflow is not detected.)
fn host_call_raised(inputs_nan: bool, inputs_inf: bool, r: f64) -> bool {
    if r != r { return !inputs_nan; }
    if r == r + 1.0 && r != 0.0 && (r > 1.0e308 || r < -1.0e308) { return !inputs_inf; }
    return false;
}

fn is_math_libcall_noop(iv: i32) -> bool {
    if call_is_nobuiltin(iv) || call_is_strictfp(iv) { return false; }
    let c = cb_callee(iv);
    if c < 0 || vals[c].kind != VK_FUNC || globs[glob_of(c)].vty != insts[inst_of(iv)].ty2 { return false; }
    let lf = tli_get_libfunc(c);
    if lf < 0 { return false; }
    let nm = TLI_NAMES[lf];
    let na = cb_nargs(iv);
    if na == 1 {
        let a = cb_arg(iv, 0);
        if vals[a].kind != VK_CFP { return false; }
        let k = ty_kind(vals[a].ty) as i64;
        if nm == "logl" || nm == "log" || nm == "logf" || nm == "log2l" || nm == "log2" || nm == "log2f" ||
           nm == "log10l" || nm == "log10" || nm == "log10f" {
            return cfp_is_nan(a) || (!cfp_is_zero(a) && !cfp_is_neg(a));
        }
        if nm == "ilogb" { return !cfp_is_nan(a) && !cfp_is_zero(a) && !cfp_is_inf(a); }
        if nm == "expl" || nm == "exp" || nm == "expf" {
            if k == TK_DOUBLE { let x = cfp_to_f64(a); return !(x < -745.0 || x > 709.0); }
            if k == TK_FLOAT { let x = cfp_to_f64(a); return !(x < -103.0 || x > 88.0); }
            return false;
        }
        if nm == "exp2l" || nm == "exp2" || nm == "exp2f" {
            if k == TK_DOUBLE { let x = cfp_to_f64(a); return !(x < -1074.0 || x > 1023.0); }
            if k == TK_FLOAT { let x = cfp_to_f64(a); return !(x < -149.0 || x > 127.0); }
            return false;
        }
        if nm == "sinl" || nm == "sin" || nm == "sinf" || nm == "cosl" || nm == "cos" || nm == "cosf" { return !cfp_is_inf(a); }
        if nm == "tanl" || nm == "tan" || nm == "tanf" {
            if k == TK_DOUBLE || k == TK_FLOAT || k == TK_HALF {
                let x = cfp_to_f64(a);
                return !host_call_raised(x != x, cfp_is_inf(a), tan(x));
            }
            return false;
        }
        if nm == "atan" || nm == "atanf" || nm == "atanl" { return true; }
        if nm == "asinl" || nm == "asin" || nm == "asinf" || nm == "acosl" || nm == "acos" || nm == "acosf" {
            if cfp_is_nan(a) { return true; }
            if k == TK_X86_FP80 || k == TK_FP128 {
                // compare against +-1 without a host conversion: |x| <= 1 <=> exponent < 0, or x == +-1
                let p = fp_decompose(k, cint_lo(a), cint_hi(a));
                if p.cat == FC_ZERO { return true; }
                if p.cat == FC_INF { return false; }
                return p.exponent < 0 || (p.exponent == 0 && p.sig1 == 0 && (p.sig0 & (p.sig0 - 1)) == 0);
            }
            let x = cfp_to_f64(a);
            return !(x < -1.0 || x > 1.0);
        }
        if nm == "sinh" || nm == "cosh" || nm == "sinhf" || nm == "coshf" || nm == "sinhl" || nm == "coshl" {
            if k == TK_DOUBLE { let x = cfp_to_f64(a); return !(x < -710.0 || x > 710.0); }
            if k == TK_FLOAT { let x = cfp_to_f64(a); return !(x < -89.0 || x > 89.0); }
            return false;
        }
        if nm == "sqrtl" || nm == "sqrt" || nm == "sqrtf" { return cfp_is_nan(a) || cfp_is_zero(a) || !cfp_is_neg(a); }
        return false;
    }
    if na == 2 {
        let a = cb_arg(iv, 0);
        let b = cb_arg(iv, 1);
        if vals[a].kind != VK_CFP || vals[b].kind != VK_CFP { return false; }
        let k = ty_kind(vals[a].ty) as i64;
        if nm == "powl" || nm == "pow" || nm == "powf" {
            if (k == TK_DOUBLE || k == TK_FLOAT || k == TK_HALF) && vals[a].ty == vals[b].ty {
                let x = cfp_to_f64(a);
                let y = cfp_to_f64(b);
                return !host_call_raised(x != x || y != y, cfp_is_inf(a) || cfp_is_inf(b), pow(x, y));
            }
            return false;
        }
        if nm == "fmodl" || nm == "fmod" || nm == "fmodf" || nm == "remainderl" || nm == "remainder" || nm == "remainderf" {
            return cfp_is_nan(a) || cfp_is_nan(b) || (!cfp_is_inf(a) && !cfp_is_zero(b));
        }
        if nm == "atan2" || nm == "atan2f" || nm == "atan2l" { return !cfp_is_zero(a) || !cfp_is_zero(b); }
        if starts_with(nm, "nextafter") || starts_with(nm, "nexttoward") {
            fatal("isMathLibCallNoop: nextafter/nexttoward constant folding is not ported yet");
        }
        return false;
    }
    return false;
}

