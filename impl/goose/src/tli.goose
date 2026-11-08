// TargetLibraryInfo: library function recognition (getLibFunc + isValidProtoForLibFunc), availability
// (initializeBase + initializeLibCalls for every triple, setAvailableWithName custom names, opt's
// -disable-simplify-libcalls / -disable-builtin / -enable-builtin, the per-function "no-builtins" /
// "no-builtin-<name>" overrides), getName, hasOptimizedCodeGen, getWCharSize, getSizeTSize, getIntSize,
// isCallingConvCCompatible, getLibFunc(Opcode, Type); plus MemoryBuiltins.cpp's alloc/free tables and
// ConstantFolding.cpp's isMathLibCallNoop. Ports llvm/lib/Analysis/TargetLibraryInfo.cpp,
// llvm/include/llvm/Analysis/TargetLibraryInfo.h, MemoryBuiltins.cpp, ConstantFolding.cpp.
// Tables: gen_tli.goose (tools/gen_tli.py, from TargetLibraryInfo.td); triples: triple.goose.
// Not ported: vector function libraries (-vector-library, VecFuncs.def; opt rejects the option).
import std;
import binary;
import math;
import ir;
import datalayout;
import irutil;
import calls;
import gen_tli;
import gen_attrs;
import instinfo;
import apfloat;
import triple;
import gen_triple;

// ---------------------------------------------------------------------------------------------
// TargetLibraryInfoImpl, built once per module triple (opt's TLII, TargetLibraryAnalysis's baseline).

// AvailabilityState
let TLI_UNAVAILABLE: u8 = 0;
let TLI_CUSTOM_NAME: u8 = 1;
let TLI_STANDARD_NAME: u8 = 3;

var tli_state: u8[>..];          // AvailableArray, per LibFunc
var tli_custom: i32[>..];        // CustomNames: string id per LibFunc (-1 = none)
var tli_triple_id: i32 = -2;     // the module triple the tables were built for
var tli_tt: Triple;              // that triple, parsed
var tli_int_size: i64 = 32;      // SizeOfInt
var tli_cur_fn: i32 = -1;        // the function the current pass runs on (TargetLibraryAnalysis(F))

// opt's command line (tools/opt/optdriver.cpp): applied to the TLII after initialization
var tli_cl_disable_all = false;  // -disable-simplify-libcalls
var tli_cl_disable: u8[>..];     // -disable-builtin=<name> occurrences, '\n'-terminated
var tli_cl_enable: u8[>..];      // -enable-builtin=<name> occurrences, '\n'-terminated

fn tli_def(name: const u8[:]) -> i64 {
    for d, i in TLI_DEFS { if d == name { return i; } }
    fatal(str("internal: unknown LibFunc ", name));
    return -1;
}
// TLI.setUnavailable(LibFunc_<def>) / setAvailable for each def name
fn tli_unavail(names: const u8[:][:]) { for nm in names { tli_state[tli_def(nm)] = TLI_UNAVAILABLE; } }
fn tli_avail_set(names: const u8[:][:]) {
    for nm in names { let d = tli_def(nm); tli_state[d] = TLI_STANDARD_NAME; tli_custom[d] = -1; }
}
// setAvailableWithName
fn tli_avail_with_name(def: const u8[:], name: const u8[:]) {
    let d = tli_def(def);
    if TLI_NAMES[d] == name { tli_state[d] = TLI_STANDARD_NAME; tli_custom[d] = -1; }
    else { tli_state[d] = TLI_CUSTOM_NAME; tli_custom[d] = intern(name); }
}
fn tli_disable_all() { for i in tli_state.len { tli_state[i] = TLI_UNAVAILABLE; } }

fn tli_has_sincospi_stret(t: Triple) -> bool {
    if !tt_is_os_darwin(t) { return false; }
    if t.arch == TA_x86 { return false; }
    if tt_is_macosx(t) && tt_macosx_version_lt(t, 10, 9, 0) { return false; }
    if tt_is_ios(t) && tt_os_version_lt(t, 7, 0, 0) { return false; }
    return true;
}
fn tli_has_bcmp(t: Triple) -> bool {
    if tt_is_linux(t) { return tt_is_gnu_env(t) || tt_is_musl(t); }
    return tt_is_freebsd(t) || tt_is_solaris(t);
}

// The module's triple (empty when it has none)
fn tli_triple_str(m: i32) -> const u8[:] {
    let tt = modules[m].triple;
    return if tt >= 0 { sbytes(tt) } else { "" };
}

// TargetLibraryInfoImpl(T) + opt's adjustments, for module m
fn tli_init(m: i32) {
    let tid = modules[m].triple;
    if tli_triple_id == tid && tli_state.len == LF_COUNT { return; }
    tli_triple_id = tid;
    tli_tt = triple_parse(tli_triple_str(m));
    let t = tli_tt;
    tli_state.clear();
    tli_state.resize(LF_COUNT, TLI_STANDARD_NAME);   // memset(AvailableArray, -1, ...)
    tli_custom.clear();
    tli_custom.resize(LF_COUNT, -1);
    // initializeBase
    let ext_i32 = t.arch == TA_ppc64 || t.arch == TA_ppc64le || t.arch == TA_sparcv9 || t.arch == TA_systemz;
    let sext_i32 = t.arch == TA_loongarch32 || t.arch == TA_loongarch64 || t.arch == TA_mips || t.arch == TA_mipsel ||
        t.arch == TA_mips64 || t.arch == TA_mips64el || t.arch == TA_riscv64 || t.arch == TA_riscv64be;
    tli_needs_ext = ext_i32 || sext_i32;
    tli_int_size = if tt_is_arch16(t) { 16 } else { 32 };
    tli_initialize_lib_calls(t);
    // optdriver.cpp
    if tli_cl_disable_all { tli_disable_all(); return; }
    tli_apply_cl_list(tli_cl_disable, false);
    tli_apply_cl_list(tli_cl_enable, true);
}
var tli_needs_ext = false;       // ShouldExtI32Param/Return or ShouldSignExtI32Param/Return

fn tli_apply_cl_list(xs: const u8[:], enable: bool) {
    var st: i64 = 0;
    for j in xs.len {
        if xs[j] != '\n' { continue; }
        let lf = tli_lookup_name(xs[st..j]);
        st = j + 1;
        if lf < 0 { continue; }   // reported by tli_check_cl_builtins
        if enable { tli_state[lf] = TLI_STANDARD_NAME; tli_custom[lf] = -1; } else { tli_state[lf] = TLI_UNAVAILABLE; }
    }
}
// optdriver.cpp's "cannot disable/enable nonexistent builtin function" check: the message, or "" if fine
fn tli_check_cl_builtins(out: u8[>..]&) {
    if tli_cl_disable_all { return; }
    for k in 2 {
        let xs: const u8[:] = if k == 0 { tli_cl_disable } else { tli_cl_enable };
        var st: i64 = 0;
        for j in xs.len {
            if xs[j] != '\n' { continue; }
            let nm = xs[st..j];
            st = j + 1;
            if tli_lookup_name(nm) < 0 {
                out.append(if k == 0 { "cannot disable nonexistent builtin function " } else { "cannot enable nonexistent builtin function " });
                out.append(nm);
                return;
            }
        }
    }
}

// initializeLibCalls(TLI, T, StandardNames, VecLib), in LLVM's order
fn tli_initialize_lib_calls(t: Triple) {
    tli_unavail(["getc_unlocked", "getchar_unlocked", "putc_unlocked", "putchar_unlocked", "fputc_unlocked",
        "fgetc_unlocked", "fread_unlocked", "fwrite_unlocked", "fputs_unlocked", "fgets_unlocked"]);
    if tt_is_amdgpu(t) { tli_disable_all(); return; }
    if tt_is_dxil(t) { tli_disable_all(); return; }
    if tt_is_macosx(t) {
        tli_avail_set(["getc_unlocked", "getchar_unlocked", "putc_unlocked", "putchar_unlocked"]);
        tli_unavail(["memrchr"]);
        if tt_macosx_version_lt(t, 10, 5, 0) { tli_unavail(["memset_pattern4", "memset_pattern8", "memset_pattern16"]); }
    } else if tt_is_ios(t) {
        if tt_os_version_lt(t, 3, 0, 0) { tli_unavail(["memset_pattern4", "memset_pattern8", "memset_pattern16"]); }
    } else if !tt_is_watchos(t) {
        tli_unavail(["memset_pattern4", "memset_pattern8", "memset_pattern16"]);
    }
    if !tli_has_sincospi_stret(t) {
        tli_unavail(["sinpi", "sinpif", "cospi", "cospif", "sincospi_stret", "sincospif_stret"]);
    }
    if !tli_has_bcmp(t) { tli_unavail(["bcmp"]); }
    if tt_is_macosx(t) && t.arch == TA_x86 && !tt_macosx_version_lt(t, 10, 7, 0) {
        tli_avail_with_name("fwrite", "fwrite$UNIX2003");
        tli_avail_with_name("fputs", "fputs$UNIX2003");
    }
    if t.arch != TA_xcore && t.arch != TA_tce && t.os != TOS_Emscripten { tli_unavail(["iprintf", "siprintf", "fiprintf"]); }
    if t.os != TOS_Emscripten { tli_unavail(["small_printf", "small_sprintf", "small_fprintf"]); }
    if tt_is_windows(t) && !tt_is_cygming(t) {
        var has_partial_c99 = true;
        if tt_is_known_windows_msvc(t) { has_partial_c99 = t.envv.maj == 0 || t.envv.maj >= 19; }
        let is_arm = t.arch == TA_aarch64 || t.arch == TA_arm;
        let has_partial_float = is_arm || t.arch == TA_x86_64;
        if !has_partial_float {
            tli_unavail(["acosf", "asinf", "atan2f", "atanf", "ceilf", "cosf", "coshf", "expf", "floorf", "fmodf",
                "hypotf", "log10f", "logf", "modff", "powf", "remainderf", "remquof", "fdimf", "sinf", "sinhf", "sqrtf",
                "tanf", "tanhf"]);
        }
        if !is_arm { tli_unavail(["fabsf"]); }
        tli_unavail(["frexpf", "ldexpf"]);
        tli_unavail(["acosl", "asinl", "atan2l", "atanl", "ceill", "cosl", "coshl", "expl", "fabsl", "floorl", "fmodl",
            "frexpl", "hypotl", "ldexpl", "log10l", "logl", "modfl", "powl", "remainderl", "remquol", "fdiml", "sinl",
            "sinhl", "sqrtl", "tanl", "tanhl"]);
        if !has_partial_c99 {
            tli_unavail(["acosh", "acoshf", "asinh", "asinhf", "atanh", "atanhf"]);
            tli_avail_with_name("cabs", "_cabs");
            tli_unavail(["cabsf", "cbrt", "cbrtf"]);
            tli_avail_with_name("copysign", "_copysign");
            tli_avail_with_name("copysignf", "_copysignf");
            tli_unavail(["exp2", "exp2f", "expm1", "expm1f", "fmax", "fmaxf", "fmin", "fminf", "log1p", "log1pf",
                "log2", "log2f"]);
            tli_avail_with_name("logb", "_logb");
            tli_unavail(["ilogb", "ilogbf"]);
            if has_partial_float { tli_avail_with_name("logbf", "_logbf"); } else { tli_unavail(["logbf"]); }
            tli_unavail(["nextafter", "nextafterf", "nexttoward", "nexttowardf", "rint", "rintf", "round", "roundf",
                "scalbln", "scalblnf", "scalblnl", "scalbn", "scalbnf", "scalbnl", "trunc", "truncf"]);
        }
        tli_unavail(["acoshl", "asinhl", "atanhl", "cabsl", "cbrtl", "copysignl", "exp2l", "expm1l", "fmaxl", "fminl",
            "log1pl", "log2l", "logbl", "ilogbl", "nearbyintl", "nextafterl", "nexttowardl", "rintl", "roundl",
            "scalblnl", "scalbnl", "truncl"]);
        tli_unavail(["access", "chmod", "closedir", "fdopen", "fileno", "fseeko", "fstat", "ftello", "gettimeofday",
            "memccpy", "mkdir", "open", "opendir", "pclose", "popen", "read", "rmdir", "stat", "strcasecmp",
            "strncasecmp", "unlink", "utime", "write"]);
    }
    if tt_is_windows(t) && !tt_is_windows_cygwin(t) {
        tli_unavail(["bcmp", "bcopy", "bzero", "chown", "ctermid", "ffs", "flockfile", "fstatvfs", "ftrylockfile",
            "funlockfile", "getitimer", "getlogin_r", "getpwnam", "htonl", "htons", "lchown", "lstat", "memrchr",
            "ntohl", "ntohs", "pread", "pwrite", "readlink", "realpath", "setitimer", "statvfs", "stpcpy", "stpncpy",
            "times", "uname", "unsetenv", "utimes"]);
        tli_unavail(["ldexpf"]);
    }
    if tt_is_msvcrt(t) {
        tli_unavail(["ZdaPv", "ZdaPvRKSt9nothrow_t", "ZdaPvSt11align_val_t", "ZdaPvSt11align_val_tRKSt9nothrow_t",
            "ZdaPvj", "ZdaPvjSt11align_val_t", "ZdaPvm", "ZdaPvmSt11align_val_t", "ZdlPv", "ZdlPvRKSt9nothrow_t",
            "ZdlPvSt11align_val_t", "ZdlPvSt11align_val_tRKSt9nothrow_t", "ZdlPvj", "ZdlPvjSt11align_val_t", "ZdlPvm",
            "ZdlPvmSt11align_val_t", "Znaj", "ZnajRKSt9nothrow_t", "ZnajSt11align_val_t",
            "ZnajSt11align_val_tRKSt9nothrow_t", "Znam", "ZnamRKSt9nothrow_t", "ZnamRKSt9nothrow_t12__hot_cold_t",
            "ZnamSt11align_val_t", "ZnamSt11align_val_tRKSt9nothrow_t", "Znwj", "ZnwjRKSt9nothrow_t",
            "ZnwjSt11align_val_t", "ZnwjSt11align_val_tRKSt9nothrow_t", "Znwm", "ZnwmRKSt9nothrow_t",
            "ZnwmRKSt9nothrow_t12__hot_cold_t", "ZnwmSt11align_val_t", "ZnwmSt11align_val_tRKSt9nothrow_t",
            "Znwm12__hot_cold_t", "ZnwmSt11align_val_t12__hot_cold_t",
            "ZnwmSt11align_val_tRKSt9nothrow_t12__hot_cold_t", "Znam12__hot_cold_t", "ZnamSt11align_val_t12__hot_cold_t",
            "ZnamSt11align_val_tRKSt9nothrow_t12__hot_cold_t", "size_returning_new", "size_returning_new_hot_cold",
            "size_returning_new_aligned", "size_returning_new_aligned_hot_cold"]);
    } else {
        tli_unavail(["msvc_new_int", "msvc_new_int_nothrow", "msvc_new_longlong", "msvc_new_longlong_nothrow",
            "msvc_delete_ptr32", "msvc_delete_ptr32_nothrow", "msvc_delete_ptr32_int", "msvc_delete_ptr64",
            "msvc_delete_ptr64_nothrow", "msvc_delete_ptr64_longlong", "msvc_new_array_int",
            "msvc_new_array_int_nothrow", "msvc_new_array_longlong", "msvc_new_array_longlong_nothrow",
            "msvc_delete_array_ptr32", "msvc_delete_array_ptr32_nothrow", "msvc_delete_array_ptr32_int",
            "msvc_delete_array_ptr64", "msvc_delete_array_ptr64_nothrow", "msvc_delete_array_ptr64_longlong"]);
    }
    if t.os == TOS_MacOSX {
        tli_unavail(["exp10l"]);
        if tt_macosx_version_lt(t, 10, 9, 0) { tli_unavail(["exp10", "exp10f"]); }
        else { tli_avail_with_name("exp10", "__exp10"); tli_avail_with_name("exp10f", "__exp10f"); }
    } else if t.os == TOS_IOS || t.os == TOS_TvOS || t.os == TOS_WatchOS || t.os == TOS_XROS {
        tli_unavail(["exp10l"]);
        if !tt_is_watchos(t) && (tt_os_version_lt(t, 7, 0, 0) || (tt_os_version_lt(t, 9, 0, 0) && tt_is_x86(t))) {
            tli_unavail(["exp10", "exp10f"]);
        } else { tli_avail_with_name("exp10", "__exp10"); tli_avail_with_name("exp10f", "__exp10f"); }
    } else {
        tli_unavail(["exp10", "exp10f", "exp10l"]);
    }
    let ffsl_os = t.os == TOS_Darwin || t.os == TOS_MacOSX || t.os == TOS_IOS || t.os == TOS_TvOS ||
        t.os == TOS_WatchOS || t.os == TOS_XROS || t.os == TOS_FreeBSD || t.os == TOS_Linux;
    if !ffsl_os { tli_unavail(["ffsl"]); }
    if !ffsl_os { tli_unavail(["ffsll"]); }
    if !tt_is_freebsd(t) { tli_unavail(["fls", "flsl", "flsll"]); }
    if !tt_is_linux(t) || !tt_is_gnu_env(t) {
        tli_unavail(["dunder_strdup", "dunder_strtok_r", "dunder_isoc99_scanf", "dunder_isoc99_sscanf",
            "under_IO_getc", "under_IO_putc"]);
        if !tt_is_android(t) && !tt_is_musl(t) { tli_unavail(["memalign"]); }
        tli_unavail(["fopen64", "fseeko64", "fstat64", "fstatvfs64", "ftello64", "lstat64", "open64", "stat64",
            "statvfs64", "tmpfile64"]);
        tli_unavail(["acos_finite", "acosf_finite", "acosl_finite", "acosh_finite", "acoshf_finite",
            "acoshl_finite", "asin_finite", "asinf_finite", "asinl_finite", "atan2_finite", "atan2f_finite",
            "atan2l_finite", "atanh_finite", "atanhf_finite", "atanhl_finite", "cosh_finite", "coshf_finite",
            "coshl_finite", "exp10_finite", "exp10f_finite", "exp10l_finite", "exp2_finite", "exp2f_finite",
            "exp2l_finite", "exp_finite", "expf_finite", "expl_finite", "log10_finite", "log10f_finite",
            "log10l_finite", "log2_finite", "log2f_finite", "log2l_finite", "log_finite", "logf_finite",
            "logl_finite", "pow_finite", "powf_finite", "powl_finite", "sinh_finite", "sinhf_finite",
            "sinhl_finite", "sqrt_finite", "sqrtf_finite", "sqrtl_finite"]);
    }
    if (tt_is_linux(t) && tt_is_gnu_env(t)) || (tt_is_android(t) && !tt_android_version_lt(t, 28)) {
        tli_avail_set(["getc_unlocked", "getchar_unlocked", "putc_unlocked", "putchar_unlocked", "fputc_unlocked",
            "fgetc_unlocked", "fread_unlocked", "fwrite_unlocked", "fputs_unlocked", "fgets_unlocked"]);
    }
    if tt_is_ps(t) {
        tli_avail_set(["memalign"]);
        tli_unavail(["ZdaPvj", "ZdaPvjSt11align_val_t", "ZdlPvj", "ZdlPvjSt11align_val_t", "Znaj",
            "ZnajRKSt9nothrow_t", "ZnajSt11align_val_t", "ZnajSt11align_val_tRKSt9nothrow_t", "Znwj",
            "ZnwjRKSt9nothrow_t", "ZnwjSt11align_val_t", "ZnwjSt11align_val_tRKSt9nothrow_t"]);
        tli_unavail(["memccpy_chk", "memcpy_chk", "memmove_chk", "mempcpy_chk", "memset_chk", "snprintf_chk",
            "sprintf_chk", "stpcpy_chk", "stpncpy_chk", "strcat_chk", "strcpy_chk", "strlcat_chk", "strlcpy_chk",
            "strlen_chk", "strncat_chk", "strncpy_chk", "vsnprintf_chk", "vsprintf_chk"]);
        tli_unavail(["access", "chmod", "chown", "closedir", "ctermid", "execl", "execle", "execlp", "execv", "execvP",
            "execve", "execvp", "execvpe", "fork", "fstat", "fstatvfs", "getenv", "getitimer", "getlogin_r", "getpwnam",
            "gettimeofday", "lchown", "lstat", "mkdir", "open", "opendir", "pclose", "popen", "pread", "pvalloc",
            "pwrite", "read", "readlink", "realpath", "rename", "rmdir", "setitimer", "stat", "statvfs", "system",
            "times", "tmpfile", "unlink", "uname", "unsetenv", "utime", "utimes", "valloc", "write"]);
        tli_unavail(["atomic_load", "atomic_store", "dunder_strndup", "bcmp", "bcopy", "bzero", "cabs", "cabsf",
            "cabsl", "ffs", "flockfile", "fseeko", "ftello", "ftrylockfile", "funlockfile", "htonl", "htons", "isascii",
            "memccpy", "mempcpy", "memrchr", "ntohl", "ntohs", "reallocarray", "reallocf", "roundeven", "roundevenf",
            "roundevenl", "stpcpy", "stpncpy", "strlcat", "strlcpy", "strndup", "strnlen", "toascii"]);
    }
    if tt_is_freebsd(t) {
        tli_avail_set(["dunder_strtok_r", "memalign", "fputc_unlocked", "fputs_unlocked", "fread_unlocked",
            "fwrite_unlocked", "getc_unlocked", "getchar_unlocked", "putc_unlocked", "putchar_unlocked"]);
        tli_unavail(["dunder_strndup", "memccpy_chk", "strlen_chk", "fmaximum_num", "fmaximum_numf", "fmaximum_numl",
            "fminimum_num", "fminimum_numf", "fminimum_numl", "roundeven", "roundevenf", "roundevenl"]);
    }
    if tt_is_nvptx(t) {
        tli_disable_all();
        tli_avail_set(["nvvm_reflect", "malloc", "free"]);
    } else {
        tli_unavail(["nvvm_reflect"]);
    }
    if !tt_is_aix(t) { tli_unavail(["vec_calloc", "vec_malloc", "vec_realloc", "vec_free"]); }
    if tt_is_aix(t) { tli_unavail(["memrchr"]); }
    // addVectorizableFunctionsFromVecLib(VecLib = NoLibrary): nothing
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

// TargetLibraryInfoImpl::getSizeTSize(M): the index size of address space 0
fn tli_sizet_bits() -> i64 { dl_ptr(0).idx }
// getIntSize() (of the current module's TLI)
fn tli_int_bits() -> i64 {
    if tli_cur_fn >= 0 { tli_init(globs[glob_of(tli_cur_fn)].module); }
    else { tli_init(cur_module); }
    return tli_int_size;
}
// getWCharSize(M): the "wchar_size" module flag, else the triple's default
fn tli_wchar_size(m: i32) -> i64 {
    let v = tli_module_flag_int(m, "wchar_size");
    if v >= 0 { return v; }
    return tt_default_wchar_size(triple_parse(tli_triple_str(m)));
}
// a module flag's integer value (-1 = absent)
fn tli_module_flag_int(m: i32, key: const u8[:]) -> i64 {
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

// isCallingConvCCompatible(CC, TT, FuncTy): C, or an ARM AAPCS variant on non-iOS with int/pointer signatures
fn tli_is_cc_c_compatible(cc: i64, fty: i32, m: i32) -> bool {
    if cc == 0 { return true; }
    // ARM_APCS = 66, ARM_AAPCS = 67, ARM_AAPCS_VFP = 68
    if cc == 66 || cc == 67 || cc == 68 {
        if tt_is_ios(triple_parse(tli_triple_str(m))) { return false; }
        let rt = ty_fn_ret(fty);
        if ty_kind(rt) != TK_PTR && !ty_is_int(rt) && ty_kind(rt) != TK_VOID { return false; }
        for k in ty_fn_nparams(fty) {
            let p = ty_fn_param(fty, k);
            if ty_kind(p) != TK_PTR && !ty_is_int(p) { return false; }
        }
        return true;
    }
    return false;
}
// TargetLibraryInfoImpl::isCallingConvCCompatible(CallBase*)
fn tli_call_is_cc_c_compatible(ci: i32) -> bool {
    tli_is_cc_c_compatible(insts[inst_of(ci)].cc as i64, insts[inst_of(ci)].ty2, globs[glob_of(inst_func(ci))].module)
}

// getLibFunc(Opcode, Ty, F): frem of double/float is fmod/fmodf
fn tli_get_libfunc_for_opcode(is_frem: bool, ty: i32) -> i32 {
    if !is_frem || (ty_kind(ty) != TK_DOUBLE && ty_kind(ty) != TK_FLOAT) { return -1; }
    return if ty_kind(ty) == TK_DOUBLE { LF_fmod } else { LF_fmodf };
}

fn tli_match_type(c: u8, t: i32) -> bool {
    let k = ty_kind(t);
    let isint = k == TK_INT;
    let bits = if isint { ty_bits(t) } else { 0 };
    match c {
        'v' => k == TK_VOID,
        'b' => isint && bits == 8,
        'h' => isint && bits == 16,
        'w' => isint && bits == 32,
        'i' => isint && bits == tli_int_size,
        'I', 'l' => isint && bits >= tli_int_size,
        'x' => isint,
        'q', 'L' => isint && bits == 64,
        'z', 'Z' => isint && bits == tli_sizet_bits(),
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
    let np = ty_fn_nparams(fty);
    let nm = TLI_NAMES[lf];
    if nm == "cabs" || nm == "cabsf" || nm == "cabsl" {
        let rt = ty_fn_ret(fty);
        if !ty_is_fp(rt) || np == 0 { return false; }
        let pt = ty_fn_param(fty, 0);
        if np == 1 { return ty_is_array(pt) && ty_count(pt) == 2 && ty_elem(pt) == rt; }
        if np == 2 { return pt == rt && ty_fn_param(fty, 1) == rt; }
        return false;
    }
    if nm == "__sincospi_stret" || nm == "__sincospif_stret" {
        if np != 1 { return false; }
        let rt = ty_fn_ret(fty);
        let pt = ty_fn_param(fty, 0);
        if ty_is_struct(rt) { return ty_count(rt) == 2 && ty_field(rt, 0) == pt && ty_field(rt, 1) == pt; }
        if ty_kind(rt) == TK_FVEC { return ty_count(rt) == 2 && ty_elem(rt) == pt; }
        return false;
    }
    if starts_with(nm, "__size_returning_new") {
        let sb = tli_sizet_bits();
        fn isz(t: i32, b: i64) -> bool { ty_is_int(t) && ty_bits(t) == b }
        if nm == "__size_returning_new" { if np != 1 || !isz(ty_fn_param(fty, 0), sb) { return false; } }
        else if nm == "__size_returning_new_hot_cold" { if np != 2 || !isz(ty_fn_param(fty, 0), sb) || !isz(ty_fn_param(fty, 1), 8) { return false; } }
        else if nm == "__size_returning_new_aligned" { if np != 2 || !isz(ty_fn_param(fty, 0), sb) || !isz(ty_fn_param(fty, 1), sb) { return false; } }
        else if nm == "__size_returning_new_aligned_hot_cold" {
            if np != 3 || !isz(ty_fn_param(fty, 0), sb) || !isz(ty_fn_param(fty, 1), sb) || !isz(ty_fn_param(fty, 2), 8) { return false; }
        } else { return false; }
        let rt = ty_fn_ret(fty);
        // StructType::get({ptr, iSizeT}) (literal, not packed)
        return ty_is_struct(rt) && types[rt].name < 0 && (types[rt].flags & TF_PACKED) == 0 && ty_count(rt) == 2 &&
            ty_field(rt, 0) == ty_ptr(0) && isz(ty_field(rt, 1), sb);
    }
    if sig[0] == '?' { return false; }
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
    tli_init(globs[g].module);
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

// TargetLibraryInfo(Impl, F)::getState(LF) for the current function: the module's baseline, overridden as
// unavailable by the caller's "no-builtins" / "no-builtin-<name>" attributes.
fn tli_get_state(lf: i32) -> u8 {
    let fv = tli_cur_fn;
    if fv < 0 { fatal("internal: TargetLibraryInfo used outside of a function pass"); }
    tli_init(globs[glob_of(fv)].module);
    let s = alist_fn(globs[glob_of(fv)].attrs);
    for k in aset_n(s) {
        let a = aset_attr(s, k);
        if attrs[a].kind != 0 { continue; }
        let key = sbytes(attrs[a].skey);
        if key == "no-builtins" { return TLI_UNAVAILABLE; }
        if starts_with(key, "no-builtin-") && tli_lookup_name(key[11..]) == lf { return TLI_UNAVAILABLE; }
    }
    return tli_state[lf];
}
// TargetLibraryInfo::has(F)
fn tli_has(lf: i32) -> bool { tli_get_state(lf) != TLI_UNAVAILABLE }
// TargetLibraryInfo::getName(F): "" when unavailable, else the standard or the custom name
fn tli_name(lf: i64) -> const u8[:] {
    let st = tli_get_state(lf as i32);
    if st == TLI_UNAVAILABLE { return ""; }
    if st == TLI_STANDARD_NAME { return TLI_NAMES[lf]; }
    return sbytes(tli_custom[lf]);
}
// TargetLibraryInfo::hasOptimizedCodeGen(F)
fn tli_has_optimized_codegen(lf: i32) -> bool {
    if tli_get_state(lf) == TLI_UNAVAILABLE { return false; }
    let d = TLI_DEFS[lf];
    for x in ["acos", "acosf", "acosl", "asin", "asinf", "asinl", "atan2", "atan2f", "atan2l", "atan", "atanf", "atanl",
              "copysign", "copysignf", "copysignl", "cos", "cosf", "cosl", "cosh", "coshf", "coshl", "exp2", "exp2f",
              "exp2l", "exp10", "exp10f", "exp10l", "ldexp", "ldexpf", "ldexpl", "log2", "log2f", "log2l", "memcmp",
              "bcmp", "strcmp", "memcpy", "memset", "memmove", "sin", "sinf", "sinl", "sinh", "sinhf", "sinhl", "sqrt",
              "sqrtf", "sqrtl", "sqrt_finite", "sqrtf_finite", "sqrtl_finite", "strcpy", "stpcpy", "strlen", "strnlen",
              "strstr", "memchr", "memccpy", "mempcpy", "tan", "tanf", "tanl", "tanh", "tanhf", "tanhl"] {
        if d == x { return true; }
    }
    return false;
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

