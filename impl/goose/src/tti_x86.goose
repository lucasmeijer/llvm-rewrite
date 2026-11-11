// The X86 cost model, part 1: subtarget, type legalization, cost tables, and the scalar/elementwise cost queries.
// Ports
//   llvm/lib/Target/X86/X86TargetTransformInfo.cpp  (getArithmeticInstrCost, getCastInstrCost, getCmpSelInstrCost,
//                                                    getCFInstrCost, misc queries)
//   llvm/include/llvm/CodeGen/BasicTTIImpl.h       (getTypeLegalizationCost; the BaseT:: fallbacks of these)
//   llvm/include/llvm/Analysis/TargetTransformInfoImpl.h (TargetTransformInfoImplBase, minRequiredElementSize)
//   llvm/lib/Target/X86/X86Subtarget.cpp, X86TargetMachine.cpp, llvm/lib/MC/MCSubtargetInfo.cpp (the subtarget)
// Part 2 (shuffles, vector element ops, scalarization, memory ops, reductions) is tti_x86_vec.goose, part 3
// (intrinsics) tti_x86_intr.goose; the TargetLowering tables are x86_lower.goose. Generated data:
// gen_x86target.goose (MVTs, ISD opcodes, features, CPUs, scheduling models) and gen_x86costs.goose (cost tables),
// both by tools/gen_x86target.py; gen_x86lower.goose by tools/gen_x86lower.py.
//
// Costs are InstructionCost: an i64 where TTI_INVALID (and anything above) is the invalid state; combine them with
// tc_add / tc_mul only. Functions named x86_* are X86TTIImpl's (or "thisT()->" calls), bt_* BasicTTIImplBase's
// bodies, base_* TargetTransformInfoImplBase's.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import gen_x86target;
import gen_x86costs;
import x86_lower;
import tti_x86_vec;
import tti_x86_intr;
import datalayout;
import apint;
import pm;
import flags;
import cfold;

let TCK_RECIP_THROUGHPUT: i64 = 0;
let TCK_LATENCY: i64 = 1;
let TCK_CODE_SIZE: i64 = 2;
let TCK_SIZE_AND_LATENCY: i64 = 3;

let TCC_FREE: i64 = 0;
let TCC_BASIC: i64 = 1;
let TCC_EXPENSIVE: i64 = 4;

let TTI_INVALID: i64 = 0x4000000000000000;
let TTI_MAXC: i64 = 0x3fffffffffffffff;

fn tc_valid(c: i64) -> bool { c < TTI_INVALID }
fn tc_add(a: i64, b: i64) -> i64 {
    if !tc_valid(a) || !tc_valid(b) { return TTI_INVALID; }
    let s = a + b;
    return if s > TTI_MAXC { TTI_MAXC } else { s };
}
fn tc_add3(a: i64, b: i64, c: i64) -> i64 { tc_add(tc_add(a, b), c) }
fn tc_sub(a: i64, b: i64) -> i64 { if !tc_valid(a) || !tc_valid(b) { TTI_INVALID } else { a - b } }
fn tc_mul(a: i64, k: i64) -> i64 {
    if !tc_valid(a) || !tc_valid(k) { return TTI_INVALID; }
    if a != 0 && k != 0 && (a > TTI_MAXC / (if k < 0 { -k } else { k }) || a < -TTI_MAXC / (if k < 0 { -k } else { k })) {
        return if (a < 0) != (k < 0) { -TTI_MAXC } else { TTI_MAXC };
    }
    return a * k;
}
fn tc_max(a: i64, b: i64) -> i64 { if a > b { a } else { b } }

fn x86_np(what: const u8[:]) {
    fatal(str("TargetTransformInfo: the X86 cost model (", what, ") is not ported yet"));
}

// ---------------------------------------------------------------- subtarget

var x86_sse_level: i64 = 0;    // X86SSELevel: 0 none .. 9 AVX512
var x86_st_is64 = false;
var x86_st_soft_float = false;
var x86_prefer_width: i64 = 0xffffffff;
var x86_required_width: i64 = 0xffffffff;
var x86_os: i64 = 0;           // 0 ELF, 1 Darwin (MachO), 2 Windows (COFF)
var x86_env: i64 = 0;          // Windows: 0 MSVC, 1 GNU, 2 Cygnus, 3 Itanium
var x86_is_ps_os = false;
var x86_is_linux_os = false;
var x86_pic = false;           // TargetMachine::isPositionIndependent
var x86_is64 = false;          // Is64Bit (also read by tti.goose)
var x86_tune_sched: i64 = -1;  // the TuneCPU's scheduling model (gen_x86target.goose X86SM_*), -1 none
var x86_st_key: u8[>..] = [];  // the subtarget the lowering tables were built for

fn x86_set(f: i32) {
    x86_bits[f / 64] |= (1 as u64) << ((f % 64) as u64);
    for w in X86F_WORDS { x86_bits[w] |= X86F_IMPLIES[f * X86F_WORDS + w]; }
}
// MCSubtargetInfo ClearImpliedBits: clear f and every feature that implies it.
fn x86_clear(f: i32) {
    x86_bits[f / 64] &= ~((1 as u64) << ((f % 64) as u64));
    for g in X86F_COUNT {
        if ((X86F_IMPLIES[g * X86F_WORDS + f / 64] >> ((f % 64) as u64)) & 1) != 0 {
            x86_bits[g / 64] &= ~((1 as u64) << ((g % 64) as u64));
        }
    }
}
fn x86_feature_index(name: const u8[:]) -> i32 {
    if name.len == 0 { return -1; }
    for k in X86F_COUNT { if X86F_NAMES[k] == name { return k; } }
    return -1;
}
fn x86_lower_ch(c: u8) -> u8 { if c >= 'A' && c <= 'Z' { c + 32 } else { c } }
// A comma-separated feature string ("+a,-b"), applied in order (ApplyFeatureFlag; names are lower-cased by
// SubtargetFeatures::AddFeature, unknown ones ignored: subtarget.goose prints LLVM's warning).
fn x86_apply_features(fs: const u8[:]) {
    var st: i64 = 0;
    for j in 0..fs.len + 1 {
        if j < fs.len && fs[j] != ',' { continue; }
        let f0 = fs[st..j];
        st = j + 1;
        if f0.len == 0 { continue; }
        var on = true;
        var b: i64 = 0;
        if f0[0] == '+' { b = 1; } else if f0[0] == '-' { on = false; b = 1; }
        var nm: u8[..64] = [];
        for c in f0[b..] { if nm.len < 64 { nm.push(x86_lower_ch(c)); } }
        let k = x86_feature_index(nm[..]);
        if k < 0 { continue; }
        if on { x86_set(k); } else { x86_clear(k); }
    }
}
fn x86_cpu_index(cpu: const u8[:]) -> i64 {
    for c in X86CPU_COUNT { if X86CPU_NAMES[c] == cpu { return c as i64; } }
    return -1;
}
fn x86_apply_cpu(c: i64, tune: bool) {
    for f in X86F_COUNT {
        let w = if tune { X86CPU_TUNING[c * X86F_WORDS as i64 + (f / 64) as i64] } else { X86CPU_FEATURES[c * X86F_WORDS as i64 + (f / 64) as i64] };
        if ((w >> ((f % 64) as u64)) & 1) != 0 { x86_set(f); }
    }
}

fn x86_str_attr(fv: i32, key: const u8[:]) -> i32 {
    let a = aset_find_str(alist_fn(func_attrs(fv)), key);
    if a < 0 { return -1; }
    return attrs[a].sval;
}

fn x86_parse_uint(s: const u8[:]) -> i64 {
    if s.len == 0 { return -1; }
    var v: i64 = 0;
    for c in s { if c < '0' || c > '9' { return -1; } v = v * 10 + (c - '0') as i64; }
    return v;
}

// ST->getSchedModel() parameters of the TuneCPU (MCSchedModel; an unknown CPU gets the default model)
fn x86_loop_micro_op_buffer_size() -> i64 {
    if x86_tune_sched < 0 { return 0; }
    return X86SM_LOOP_MICRO_OP_BUFFER_SIZE[x86_tune_sched] as i64;
}
fn x86_issue_width() -> i64 { if x86_tune_sched < 0 { 1 } else { X86SM_ISSUE_WIDTH[x86_tune_sched] as i64 } }

// X86TargetMachine::getSubtargetImpl(F) + X86Subtarget::initSubtargetFeatures; rebuilds the TargetLowering
// tables (x86_lower.goose) when the subtarget differs from the previous one.
fn x86_subtarget_init(triple: const u8[:], fv: i32) {
    var parts: i64[4] = [0, 0, 0, 0];
    var ends: i64[4] = [0, 0, 0, 0];
    var np: i64 = 0;
    var st: i64 = 0;
    for j in 0..triple.len + 1 {
        if j < triple.len && triple[j] != '-' { continue; }
        if np < 4 { parts[np] = st; ends[np] = j; np += 1; }
        st = j + 1;
    }
    let arch = triple[parts[0]..ends[0]];
    x86_st_is64 = arch == "x86_64" || arch == "amd64" || arch == "x86_64h";
    x86_is64 = x86_st_is64;
    var os: const u8[:] = "";
    var env: const u8[:] = "";
    if np > 2 { os = triple[parts[2]..ends[2]]; }
    if np > 3 { env = triple[parts[3]..ends[3]]; }
    x86_os = 0;
    x86_env = 0;
    x86_is_ps_os = starts_with(os, "ps4") || starts_with(os, "ps5");
    x86_is_linux_os = starts_with(os, "linux");
    if starts_with(os, "darwin") || starts_with(os, "macos") || starts_with(os, "ios") || starts_with(os, "tvos") ||
       starts_with(os, "watchos") || starts_with(os, "xros") || starts_with(os, "driverkit") { x86_os = 1; }
    if starts_with(os, "windows") || starts_with(os, "win32") || starts_with(os, "mingw32") || starts_with(os, "cygwin") {
        x86_os = 2;
        if starts_with(os, "mingw32") || starts_with(env, "gnu") { x86_env = 1; }
        if starts_with(os, "cygwin") || starts_with(env, "cygnus") { x86_env = 2; }
        if starts_with(env, "itanium") { x86_env = 3; }
        if starts_with(env, "elf") || starts_with(env, "macho") { x86_np("Windows triples with a non-COFF object format"); }
    }
    if starts_with(env, "code16") || ends_with(env, "x32") { x86_np("16-bit and x32 triples"); }
    if !x86_st_is64 && !(arch.len == 4 && arch[0] == 'i' && arch[2] == '8' && arch[3] == '6') {
        fatal(str("TargetTransformInfo for target triple '", triple, "' is not supported"));
    }
    // getEffectiveRelocModel without -relocation-model
    x86_pic = (x86_os == 1 && x86_st_is64) || (x86_os == 2 && x86_st_is64);
    if x86_os == 1 && !x86_st_is64 { x86_np("32-bit Darwin (dynamic-no-pic)"); }

    var cpu: const u8[:] = cl_mcpu[..];
    var fs: const u8[:] = cl_mattr[..];
    var tune: const u8[:] = "";
    var pw: i64 = 0;
    var rw: i64 = 0xffffffff;
    var sf = false;
    if fv >= 0 {
        let ca = x86_str_attr(fv, "target-cpu");
        if ca >= 0 { cpu = sbytes(ca); }
        let fa = x86_str_attr(fv, "target-features");
        if fa >= 0 { fs = sbytes(fa); }
        let ta = x86_str_attr(fv, "tune-cpu");
        if ta >= 0 { tune = sbytes(ta); }
        sf = func_str_attr_is_true_tti(fv, "use-soft-float");
        let pa = x86_str_attr(fv, "prefer-vector-width");
        if pa >= 0 { let w = x86_parse_uint(sbytes(pa)); if w >= 0 { pw = w; } }
        let ma = x86_str_attr(fv, "min-legal-vector-width");
        if ma >= 0 { let w = x86_parse_uint(sbytes(ma)); if w >= 0 { rw = w; } }
    }
    if tune.len == 0 { tune = if cpu == "x86-64" { "generic" } else { cpu }; }
    let key = str(triple, "|", cpu, "|", tune, "|", fs, "|", pw, "|", rw, "|", sf);
    if key[..] == x86_st_key[..] { return; }
    x86_st_soft_float = sf;
    x86_prefer_width = pw;
    x86_required_width = rw;
    // initSubtargetFeatures
    if cpu.len == 0 { cpu = "generic"; }
    if tune.len == 0 { tune = "i586"; }
    for w in X86F_WORDS { x86_bits[w] = 0; }
    let ci = x86_cpu_index(cpu);
    if ci >= 0 { x86_apply_cpu(ci, false); }
    let ti = x86_cpu_index(tune);
    if ti >= 0 { x86_apply_cpu(ti, true); }
    x86_tune_sched = if ti >= 0 { X86CPU_SCHED[ti] as i64 } else { -1 };
    // X86_MC::ParseX86Triple + FS
    if x86_st_is64 { x86_apply_features("+64bit-mode,-32bit-mode,-16bit-mode,+sse2"); }
    else { x86_apply_features("-64bit-mode,+32bit-mode,-16bit-mode"); }
    if x86_st_soft_float { x86_apply_features("+soft-float"); }
    x86_apply_features(fs);
    if !x86_st_is64 { x86_apply_features("-egpr,-push2pop2,-ppx,-ndd,-ccmp,-nf,-cf,-zu,-jmpabs,-uintr"); }
    x86_sse_level = 0;
    for f in X86F_COUNT { if x86_has(f) && (X86F_SSE_LEVEL[f] as i64) > x86_sse_level { x86_sse_level = X86F_SSE_LEVEL[f] as i64; } }
    // PreferVectorWidth: the attribute, else Prefer128Bit / Prefer256Bit tuning, else unlimited
    if x86_prefer_width == 0 {
        x86_prefer_width = 0xffffffff;
        if xst_prefer128Bit() { x86_prefer_width = 128; }
        else if xst_prefer256Bit() { x86_prefer_width = 256; }
    }
    xce_init();
    xl_build();
    x86_st_key.resize(0, 0);
    x86_st_key.append(key[..]);
}

fn func_str_attr_is_true_tti(fv: i32, key: const u8[:]) -> bool {
    let a = aset_find_str(alist_fn(func_attrs(fv)), key);
    if a < 0 { return false; }
    return sbytes(attrs[a].sval) == "true";
}

// X86Subtarget queries (the boolean feature getters are xst_* in gen_x86target.goose)
fn x86_is64() -> bool { x86_st_is64 }
fn x86_use_soft_float() -> bool { x86_st_soft_float || xst_useSoftFloat() }
fn x86_sse1() -> bool { x86_sse_level >= 1 }
fn x86_sse2() -> bool { x86_sse_level >= 2 }
fn x86_sse3() -> bool { x86_sse_level >= 3 }
fn x86_ssse3() -> bool { x86_sse_level >= 4 }
fn x86_sse41() -> bool { x86_sse_level >= 5 }
fn x86_sse42() -> bool { x86_sse_level >= 6 }
fn x86_avx() -> bool { x86_sse_level >= 7 }
fn x86_avx2() -> bool { x86_sse_level >= 8 }
fn x86_avx512() -> bool { x86_sse_level >= 9 }
fn x86_any_fma() -> bool { xst_hasFMA() || xst_hasFMA4() }
fn x86_can_use_cmov() -> bool { xst_hasCMOV() || x86_sse1() || x86_st_is64 }
fn x86_cx16_64() -> bool { xst_hasCX16() && x86_st_is64 }
fn x86_sse_prefetch() -> bool { x86_sse1() || xst_hasPRFCHW() || xst_hasPREFETCHI() }
fn x86_can_extend_512dq() -> bool { x86_avx512() && (!xst_hasVLX() || x86_prefer_width >= 512) }
fn x86_can_extend_512bw() -> bool { xst_hasBWI() && x86_can_extend_512dq() }
fn x86_use_avx512_regs() -> bool { x86_avx512() && (x86_can_extend_512dq() || x86_required_width > 256) }
fn x86_use_bwi_regs() -> bool { xst_hasBWI() && x86_use_avx512_regs() }
fn x86_is_windows() -> bool { x86_os == 2 }
fn x86_is_win64() -> bool { x86_st_is64 && x86_os == 2 }
fn x86_is_win32() -> bool { !x86_st_is64 && x86_os == 2 }
fn x86_is_windows_msvc() -> bool { x86_os == 2 && x86_env == 0 }
fn x86_is_windows_itanium() -> bool { x86_os == 2 && x86_env == 3 }
fn x86_is_cygming() -> bool { x86_os == 2 && (x86_env == 1 || x86_env == 2) }
fn x86_is_darwin() -> bool { x86_os == 1 }
fn x86_is_elf() -> bool { x86_os == 0 }
fn x86_is_ps() -> bool { x86_is_ps_os }
fn x86_is_linux() -> bool { x86_is_linux_os }
fn x86_ptr_bits() -> i64 { if x86_st_is64 { 64 } else { 32 } }
fn x86_bwi() -> bool { xst_hasBWI() }
fn x86_dqi() -> bool { xst_hasDQI() }
fn x86_vlx() -> bool { xst_hasVLX() }
fn x86_xop() -> bool { xst_hasXOP() }
fn x86_slm_arith() -> bool { xst_useSLMArithCosts() }
fn x86_glm_divsqrt() -> bool { xst_useGLMDivSqrtCosts() }

// ---------------------------------------------------------------- value types and legalization

// TargetLoweringBase::getValueType(DL, Ty, AllowUnknown); MVT_Other for a type without an EVT when allowed
recursive fn x86_value_type(t: i32, allow_unknown: bool) -> i64 {
    let k = ty_kind(t);
    if k == TK_SVEC { x86_np("scalable vector types"); }
    if k == TK_FVEC {
        let e = x86_value_type(ty_elem(t), allow_unknown);
        if e == MVT_Other as i64 { return e; }
        return evt_vec(e, ty_count(t));
    }
    if k == TK_INT { return evt_int(ty_bits(t)); }
    if k == TK_HALF { return MVT_f16 as i64; }
    if k == TK_BFLOAT { return MVT_bf16 as i64; }
    if k == TK_FLOAT { return MVT_f32 as i64; }
    if k == TK_DOUBLE { return MVT_f64 as i64; }
    if k == TK_X86_FP80 { return MVT_f80 as i64; }
    if k == TK_FP128 { return MVT_f128 as i64; }
    if k == TK_PPC_FP128 { return MVT_ppcf128 as i64; }
    if k == TK_X86_AMX { return MVT_x86amx as i64; }
    if k == TK_PTR { return evt_int(dl_ptr(types[t].n as i64).bits); }
    if k == TK_VOID { return MVT_isVoid as i64; }
    if k == TK_TOKEN { return MVT_token as i64; }
    if k == TK_BYTE { x86_np("byte types"); }
    if !allow_unknown { fatal("TargetTransformInfo: getValueType of a type without a value type"); }
    return MVT_Other as i64;
}

// BasicTTIImplBase::getTypeLegalizationCost: (cost, legal MVT)
fn x86_legalize(t: i32) -> i64, i32 {
    var e = x86_value_type(t, false);
    var cost: i64 = 1;
    loop {
        let a, nx = tl_type_conversion(e);
        if a == TA_SCALARIZE_SCALABLE { return TTI_INVALID, if evt_is_simple(e) { e as i32 } else { MVT_i64 }; }
        if a == TA_LEGAL { return cost, evt_mvt(e); }
        if a == TA_SPLIT || a == TA_EXPAND { cost = tc_mul(cost, 2); }
        if nx == e { return cost, evt_mvt(e); }
        e = nx;
    }
}

// isTypeLegal (BasicTTIImplBase: getValueType with AllowUnknown)
fn x86_is_type_legal(t: i32) -> bool {
    let e = x86_value_type(t, true);
    return tl_is_type_legal(e);
}

// getRegUsageForType = TLI getNumRegisters(EVT)
fn x86_reg_usage(t: i32) -> i64 { tl_num_registers(x86_value_type(t, false)) }

// Type::getPrimitiveSizeInBits / getScalarSizeInBits
fn tt_prim_bits(t: i32) -> i64 { cf_prim_bits(t) }
fn tt_scalar_bits(t: i32) -> i64 { cf_prim_bits(ty_scalar(t)) }
fn tt_is_fp_or_fpvec(t: i32) -> bool { ty_is_fp(ty_scalar(t)) }
fn tt_is_int_or_intvec(t: i32) -> bool { ty_is_int(ty_scalar(t)) }
fn tt_vec(elt: i32, n: i64) -> i32 { ty_vector(elt, n, false) }
fn tt_nelem(t: i32) -> i64 { if ty_is_vector(t) { ty_count(t) } else { 1 } }
// Type::getWithNewBitWidth
fn tt_with_bits(t: i32, bits: i64) -> i32 {
    if ty_is_vector(t) { return ty_vector(ty_int(bits), ty_count(t), ty_kind(t) == TK_SVEC); }
    return ty_int(bits);
}
// Type::getWithNewType
fn tt_with_elt(t: i32, e: i32) -> i32 {
    if ty_is_vector(t) { return ty_vector(e, ty_count(t), ty_kind(t) == TK_SVEC); }
    return e;
}

// ---------------------------------------------------------------- cost tables

// CostTableLookup / ConvertCostTableLookup: the first entry matching (key, dst[, src]); its cost for the kind,
// or -1 when the table has no entry or the entry no cost for that kind.
fn xct(t: i32, key: i32, dst: i32, src: i32, kind: i64) -> i64 {
    for e in XCT_START[t]..XCT_START[t + 1] {
        let b = e * 7;
        if xce_data[b] == key && xce_data[b + 1] == dst && xce_data[b + 2] == src {
            return xce_data[b + 3 + kind as i32] as i64;
        }
    }
    return -1;
}
fn xc1(t: i32, key: i32, m: i32, kind: i64) -> i64 { xct(t, key, m, 0, kind) }
// whether the table has an entry (CostTableLookup != nullptr), whatever its cost for the kind
fn xct_has(t: i32, key: i32, dst: i32, src: i32) -> bool {
    for e in XCT_START[t]..XCT_START[t + 1] {
        let b = e * 7;
        if xce_data[b] == key && xce_data[b + 1] == dst && xce_data[b + 2] == src { return true; }
    }
    return false;
}

// TargetLoweringBase::InstructionOpcodeToISD
fn x86_isd_of_opcode(o: i64) -> i32 {
    if o == OP_ADD { return XISD_ADD; }
    if o == OP_SUB { return XISD_SUB; }
    if o == OP_MUL { return XISD_MUL; }
    if o == OP_SDIV { return XISD_SDIV; }
    if o == OP_UDIV { return XISD_UDIV; }
    if o == OP_SREM { return XISD_SREM; }
    if o == OP_UREM { return XISD_UREM; }
    if o == OP_SHL { return XISD_SHL; }
    if o == OP_LSHR { return XISD_SRL; }
    if o == OP_ASHR { return XISD_SRA; }
    if o == OP_AND { return XISD_AND; }
    if o == OP_OR { return XISD_OR; }
    if o == OP_XOR { return XISD_XOR; }
    if o == OP_FADD { return XISD_FADD; }
    if o == OP_FSUB { return XISD_FSUB; }
    if o == OP_FMUL { return XISD_FMUL; }
    if o == OP_FDIV { return XISD_FDIV; }
    if o == OP_FREM { return XISD_FREM; }
    if o == OP_FNEG { return XISD_FNEG; }
    if o == OP_TRUNC { return XISD_TRUNCATE; }
    if o == OP_ZEXT { return XISD_ZERO_EXTEND; }
    if o == OP_SEXT { return XISD_SIGN_EXTEND; }
    if o == OP_FPTOUI { return XISD_FP_TO_UINT; }
    if o == OP_FPTOSI { return XISD_FP_TO_SINT; }
    if o == OP_UITOFP { return XISD_UINT_TO_FP; }
    if o == OP_SITOFP { return XISD_SINT_TO_FP; }
    if o == OP_FPTRUNC { return XISD_FP_ROUND; }
    if o == OP_FPEXT { return XISD_FP_EXTEND; }
    if o == OP_PTRTOINT || o == OP_PTRTOADDR || o == OP_INTTOPTR || o == OP_BITCAST { return XISD_BITCAST; }
    if o == OP_ADDRSPACECAST { return XISD_ADDRSPACECAST; }
    if o == OP_ICMP || o == OP_FCMP { return XISD_SETCC; }
    if o == OP_SELECT { return XISD_SELECT; }
    if o == OP_EXTRACTELEMENT { return XISD_EXTRACT_VECTOR_ELT; }
    if o == OP_INSERTELEMENT { return XISD_INSERT_VECTOR_ELT; }
    if o == OP_SHUFFLEVECTOR { return XISD_VECTOR_SHUFFLE; }
    if o == OP_LOAD { return XISD_LOAD; }
    if o == OP_STORE { return XISD_STORE; }
    fatal("TargetTransformInfo: InstructionOpcodeToISD of this opcode is not ported");
    return 0;
}

// ---------------------------------------------------------------- operand infos

// OperandValueInfo as kind * 4 + properties: kind 0 AnyValue, 1 UniformValue, 2 UniformConstantValue,
// 3 NonUniformConstantValue; properties 0 None, 1 PowerOf2, 2 NegatedPowerOf2 (tti.goose computes them).
fn oi_kind(i: i64) -> i64 { i / 4 }
fn oi_props(i: i64) -> i64 { i % 4 }
fn oi_is_constant(i: i64) -> bool { let k = oi_kind(i); k == 2 || k == 3 }
fn oi_is_uniform(i: i64) -> bool { let k = oi_kind(i); k == 1 || k == 2 }
fn oi_is_pow2(i: i64) -> bool { oi_props(i) == 1 }
fn oi_is_neg_pow2(i: i64) -> bool { oi_props(i) == 2 }
fn oi_no_props(i: i64) -> i64 { oi_kind(i) * 4 }

// ---------------------------------------------------------------- getArithmeticInstrCost

// TargetTransformInfoImplBase::getArithmeticInstrCost; a0/a1 the Args (-1 none)
fn base_arith_cost(o: i64, ty: i32, kind: i64, a0: i32, a1: i32) -> i64 {
    if o == OP_FDIV || o == OP_FREM || o == OP_SDIV || o == OP_SREM || o == OP_UDIV || o == OP_UREM { return TCC_EXPENSIVE; }
    if o == OP_AND || o == OP_OR {
        if (a0 >= 0 && inst_iid(a0) == IID_experimental_widenable_condition) ||
           (a1 >= 0 && inst_iid(a1) == IID_experimental_widenable_condition) { return TCC_FREE; }
    }
    if kind == TCK_LATENCY && ty_is_fp(ty_scalar(ty)) { return 3; }
    return 1;
}

// getArithmeticInstrCost(Opcode, Ty, CostKind) with default operand infos and no Args
recursive fn x86_arith0(o: i64, ty: i32, kind: i64) -> i64 { x86_arith_cost(o, ty, kind, 0, 0, -1, -1, 0, -1) }

// BasicTTIImplBase::minRequiredElementSize: (size, signed)
fn x86_min_required_elt_size(v: i32) -> i64, bool {
    let k = vals[v].kind;
    if (k == VK_CDVECTOR || k == VK_CVECTOR) && ty_kind(vals[v].ty) == TK_FVEC {
        let n = ty_count(vals[v].ty);
        let maxsz = tt_prim_bits(ty_elem(vals[v].ty));
        var signed = false;
        var minsz: i64 = 0;
        for i in n {
            let e = agg_elem(v, i);
            if e >= 0 && vals[e].kind == VK_CINT {
                let a = ci_ap(e);
                if ap_is_neg(a) { signed = true; }
                let s = ap_sig_bits(a) - 1;
                if s > minsz { minsz = s; }
            } else {
                return maxsz, signed;
            }
        }
        return minsz, signed;
    }
    if k == VK_CINT {
        let a = ci_ap(v);
        return ap_sig_bits(a) - 1, ap_is_neg(a);
    }
    if is_inst_op(v, OP_SEXT) { return tt_scalar_bits(vals[op(v, 0)].ty) - 1, true; }
    if is_inst_op(v, OP_ZEXT) { return tt_scalar_bits(vals[op(v, 0)].ty), false; }
    return tt_scalar_bits(vals[v].ty), false;
}

// X86TTIImpl::getArithmeticInstrCost. op1/op2: operand infos; a0/a1/nargs: Args; cxt: CxtI or -1.
recursive fn x86_arith_cost(o: i64, ty: i32, kind: i64, op1: i64, op2: i64, a0: i32, a1: i32, nargs: i64, cxt: i32) -> i64 {
    if o == OP_MUL && ty_is_vector(ty) && tt_prim_bits(ty) <= 64 && tt_scalar_bits(ty) == 8 {
        let wide = tt_with_bits(ty, 16);
        return tc_add3(x86_cast_cost(OP_ZEXT, wide, ty, 0, kind, -1), x86_cast_cost(OP_TRUNC, ty, wide, 0, kind, -1),
                       x86_arith_cost(o, wide, kind, op1, op2, -1, -1, 0, -1));
    }
    let ltc, lt0 = x86_legalize(ty);
    var lt = lt0;
    var isd = x86_isd_of_opcode(o);
    if isd == XISD_MUL && nargs == 2 && mvt_is_vec(lt) && (mvt_elt(lt) == MVT_i32 || mvt_elt(lt) == MVT_i64) {
        let s1, sg1 = x86_min_required_elt_size(a0);
        let s2, sg2 = x86_min_required_elt_size(a1);
        let opmin = if s1 > s2 { s1 } else { s2 };
        let signed_mode = sg1 || sg2;
        if opmin <= 15 && !xst_isPMADDWDSlow() && mvt_elt(lt) == MVT_i32 {
            let c1 = vals[a0].kind == VK_CDVECTOR || vals[a0].kind == VK_CVECTOR;
            let c2 = vals[a1].kind == VK_CDVECTOR || vals[a1].kind == VK_CVECTOR;
            let x1 = is_inst_op(a0, OP_SEXT) && (s1 == 15 || (s1 < 15 && !x86_sse41()));
            let x2 = is_inst_op(a1, OP_SEXT) && (s2 == 15 || (s2 < 15 && !x86_sse41()));
            let zext = !sg1 || !sg2;
            if c1 || c2 || zext || x1 || x2 { lt = mvt_vec(MVT_i16, 2 * mvt_nelem(lt) as i64); }
        }
        if x86_slm_arith() && lt == MVT_v4i32 {
            if opmin <= 7 { return tc_mul(ltc, 3); }
            if !signed_mode && opmin <= 8 { return tc_mul(ltc, 3); }
            if opmin <= 15 { return tc_mul(ltc, 5); }
            if !signed_mode && opmin <= 16 { return tc_mul(ltc, 5); }
        }
        if !signed_mode && opmin <= 32 && mvt_elt(lt) == MVT_i64 { isd = XISD_X86_PMULUDQ; }
    }
    if isd == XISD_MUL && oi_is_constant(op2) && (oi_is_pow2(op2) || oi_is_neg_pow2(op2)) {
        var c = x86_arith_cost(OP_SHL, ty, kind, oi_no_props(op1), oi_no_props(op2), -1, -1, 0, -1);
        if oi_is_neg_pow2(op2) { c = tc_add(c, x86_arith0(OP_SUB, ty, kind)); }
        return c;
    }
    if (isd == XISD_SDIV || isd == XISD_SREM) && oi_is_constant(op2) && oi_is_pow2(op2) {
        let p1 = oi_no_props(op1);
        let p2 = oi_no_props(op2);
        var c = tc_mul(x86_arith_cost(OP_ASHR, ty, kind, p1, p2, -1, -1, 0, -1), 2);
        c = tc_add(c, x86_arith_cost(OP_LSHR, ty, kind, p1, p2, -1, -1, 0, -1));
        c = tc_add(c, x86_arith_cost(OP_ADD, ty, kind, p1, p2, -1, -1, 0, -1));
        if isd == XISD_SREM {
            c = tc_add(c, x86_arith_cost(OP_MUL, ty, kind, p1, p2, -1, -1, 0, -1));
            c = tc_add(c, x86_arith_cost(OP_SUB, ty, kind, p1, p2, -1, -1, 0, -1));
        }
        return c;
    }
    if (isd == XISD_UDIV || isd == XISD_UREM) && oi_is_constant(op2) && oi_is_pow2(op2) {
        let p1 = oi_no_props(op1);
        let p2 = oi_no_props(op2);
        if isd == XISD_UDIV { return x86_arith_cost(OP_LSHR, ty, kind, p1, p2, -1, -1, 0, -1); }
        return x86_arith_cost(OP_AND, ty, kind, p1, p2, -1, -1, 0, -1);
    }
    let uc = oi_is_uniform(op2) && oi_is_constant(op2);
    let cst = oi_is_constant(op2);
    let uni = oi_is_uniform(op2);
    let not_xop8 = !x86_xop() || mvt_scalar_bits(lt) != 8;
    var r: i64 = -1;
    if uc && xst_hasGFNI() { r = xc1(XCT_A_GFNIUniformConstCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if uc && x86_bwi() { r = xc1(XCT_A_AVX512BWUniformConstCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if uc && x86_dqi() { r = xc1(XCT_A_AVX512DQUniformConstCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if uc && x86_avx512() { r = xc1(XCT_A_AVX512UniformConstCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if uc && x86_avx2() { r = xc1(XCT_A_AVX2UniformConstCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if uc && x86_avx() && not_xop8 { r = xc1(XCT_A_AVXUniformConstCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if uc && x86_sse2() && not_xop8 { r = xc1(XCT_A_SSE2UniformConstCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if cst && x86_bwi() { r = xc1(XCT_A_AVX512BWConstCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if cst && x86_dqi() { r = xc1(XCT_A_AVX512DQConstCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if cst && x86_avx512() { r = xc1(XCT_A_AVX512ConstCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if cst && x86_avx2() { r = xc1(XCT_A_AVX2ConstCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if cst && x86_avx() { r = xc1(XCT_A_AVXConstCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if cst && x86_sse41() { r = xc1(XCT_A_SSE41ConstCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if cst && x86_sse2() { r = xc1(XCT_A_SSE2ConstCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_bwi() && uni { r = xc1(XCT_A_AVX512BWUniformCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_avx512() && uni { r = xc1(XCT_A_AVX512UniformCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_avx2() && uni { r = xc1(XCT_A_AVX2UniformCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_avx() && uni && not_xop8 { r = xc1(XCT_A_AVXUniformCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_sse2() && uni && not_xop8 { r = xc1(XCT_A_SSE2UniformCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_dqi() { r = xc1(XCT_A_AVX512DQCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_bwi() { r = xc1(XCT_A_AVX512BWCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_avx512() { r = xc1(XCT_A_AVX512CostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_avx512() && isd == XISD_SHL && lt == MVT_v32i16 && cst {
        return x86_arith_cost(OP_MUL, ty, kind, oi_no_props(op1), oi_no_props(op2), -1, -1, 0, -1);
    }
    if x86_avx2() && !(x86_xop() && lt == MVT_v4i32) {
        if isd == XISD_SHL && lt == MVT_v16i16 && cst {
            return x86_arith_cost(OP_MUL, ty, kind, oi_no_props(op1), oi_no_props(op2), -1, -1, 0, -1);
        }
        r = xc1(XCT_A_AVX2ShiftCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); }
    }
    if x86_xop() {
        var sisd = isd;
        if (sisd == XISD_SRL || sisd == XISD_SRA) && cst { sisd = XISD_SHL; }
        r = xc1(XCT_A_XOPShiftCostTable, sisd, lt, kind); if r >= 0 { return tc_mul(ltc, r); }
    }
    if isd == XISD_SHL && !uni && cst {
        if ((lt == MVT_v8i16 || lt == MVT_v4i32) && x86_sse2()) || ((lt == MVT_v16i16 || lt == MVT_v8i32) && x86_avx()) {
            isd = XISD_MUL;
        }
    }
    if x86_glm_divsqrt() { r = xc1(XCT_A_GLMCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_slm_arith() { r = xc1(XCT_A_SLMCostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_avx2() { r = xc1(XCT_A_AVX2CostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_avx() { r = xc1(XCT_A_AVX1CostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_sse42() { r = xc1(XCT_A_SSE42CostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_sse41() { r = xc1(XCT_A_SSE41CostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_ssse3() { r = xc1(XCT_A_SSSE3CostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_sse2() { r = xc1(XCT_A_SSE2CostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_sse1() { r = xc1(XCT_A_SSE1CostTable, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_st_is64 { r = xc1(XCT_A_X64CostTbl, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    r = xc1(XCT_A_X86CostTbl, isd, lt, kind); if r >= 0 { return tc_mul(ltc, r); }
    if kind == TCK_RECIP_THROUGHPUT && mvt_is_vec(lt) &&
       (isd == XISD_SDIV || isd == XISD_SREM || isd == XISD_UDIV || isd == XISD_UREM) {
        let sc = x86_arith_cost(o, ty_scalar(ty), kind, oi_no_props(op1), oi_no_props(op2), -1, -1, 0, -1);
        return tc_mul(tc_mul(tc_mul(ltc, 20), mvt_nelem(lt) as i64), sc);
    }
    if kind == TCK_CODE_SIZE {
        if isd == XISD_FADD || isd == XISD_FSUB || isd == XISD_FMUL || isd == XISD_FDIV || isd == XISD_FNEG ||
           isd == XISD_AND || isd == XISD_OR || isd == XISD_XOR { return ltc; }
    }
    return bt_arith_cost(o, ty, kind, op1, op2, a0, a1, nargs, cxt);
}

// BasicTTIImplBase::getArithmeticInstrCost
recursive fn bt_arith_cost(o: i64, ty: i32, kind: i64, op1: i64, op2: i64, a0: i32, a1: i32, nargs: i64, cxt: i32) -> i64 {
    let isd = x86_isd_of_opcode(o);
    if kind != TCK_RECIP_THROUGHPUT { return base_arith_cost(o, ty, kind, a0, a1); }
    let ltc, lt = x86_legalize(ty);
    let opc: i64 = if tt_is_fp_or_fpvec(ty) { 2 } else { 1 };
    let le = lt as i64;
    if tl_legal_or_promote(isd, le) { return tc_mul(ltc, opc); }
    if !tl_op_expand(isd, le) { return tc_mul(tc_mul(ltc, 2), opc); }
    if isd == XISD_UREM || isd == XISD_SREM {
        let signed = isd == XISD_SREM;
        if tl_legal_or_custom(if signed { XISD_SDIVREM } else { XISD_UDIVREM }, le) ||
           tl_legal_or_custom(if signed { XISD_SDIV } else { XISD_UDIV }, le) {
            let dc = x86_arith_cost(if signed { OP_SDIV } else { OP_UDIV }, ty, kind, op1, op2, -1, -1, 0, -1);
            let mc = x86_arith0(OP_MUL, ty, kind);
            let sc = x86_arith0(OP_SUB, ty, kind);
            return tc_add3(dc, mc, sc);
        }
    }
    if ty_kind(ty) == TK_SVEC { return TTI_INVALID; }
    if ty_kind(ty) == TK_FVEC {
        let c = x86_arith_cost(o, ty_scalar(ty), kind, op1, op2, a0, a1, nargs, cxt);
        // getScalarizationOverhead(VTy, Args, Tys = Args.size() x Ty)
        var so = x86_scalarization_overhead_all(ty, true, false, kind);
        if nargs > 0 {
            var tys: i32[2] = [ty, ty];
            var vs: i32[2] = [a0, a1];
            so = tc_add(so, bt_operands_scalarization_overhead_filtered(vs[..nargs], tys[..nargs], kind));
        } else {
            so = tc_add(so, x86_scalarization_overhead_all(ty, false, true, kind));
        }
        return tc_add(so, tc_mul(c, ty_count(ty)));
    }
    return opc;
}

// getOperandsScalarizationOverhead(filterConstantAndDuplicatedOperands(Ops, Tys))
recursive fn bt_operands_scalarization_overhead_filtered(vs: const i32[:], tys: const i32[:], kind: i64) -> i64 {
    var c: i64 = 0;
    for k in vs.len {
        let v = vs[k];
        if v < 0 || is_constant(v) { continue; }
        var dup = false;
        for j in k { if vs[j] == v { dup = true; } }
        if dup { continue; }
        let t = tys[k];
        let s = ty_scalar(t);
        if !ty_is_int(s) && !ty_is_fp(s) && ty_kind(s) != TK_PTR { continue; }
        if ty_is_vector(t) { c = tc_add(c, x86_scalarization_overhead_all(t, false, true, kind)); }
    }
    return c;
}
// getOperandsScalarizationOverhead(Tys)
recursive fn bt_operands_scalarization_overhead(tys: const i32[:], kind: i64) -> i64 {
    var c: i64 = 0;
    for t in tys {
        let s = ty_scalar(t);
        if !ty_is_int(s) && !ty_is_fp(s) && ty_kind(s) != TK_PTR { continue; }
        if ty_is_vector(t) { c = tc_add(c, x86_scalarization_overhead_all(t, false, true, kind)); }
    }
    return c;
}

// ---------------------------------------------------------------- getCastInstrCost

// TTI::getCastContextHint: 0 None, 1 Normal (load/store), 2 Masked, 3 GatherScatter, 4 Interleave, 5 Reversed
fn x86_cast_context(i: i32) -> i64 {
    if i < 0 || !is_inst(i) { return 0; }
    let o = iop(i);
    if o == OP_ZEXT || o == OP_SEXT || o == OP_FPEXT {
        let s = op(i, 0);
        if !is_inst(s) { return 0; }
        if iop(s) == OP_LOAD { return 1; }
        let id = inst_iid(s);
        if id == IID_masked_load || id == IID_masked_expandload { return 2; }
        if id == IID_masked_gather { return 3; }
        return 0;
    }
    if o == OP_TRUNC || o == OP_FPTRUNC {
        let fu = vals[i].first_use;
        if fu >= 0 && uses[fu].next < 0 {
            let u = uses[fu].user;
            if !is_inst(u) { return 0; }
            if iop(u) == OP_STORE { return 1; }
            let id = inst_iid(u);
            if id == IID_masked_store || id == IID_masked_compressstore { return 2; }
            if id == IID_masked_scatter { return 3; }
        }
        return 0;
    }
    return 0;
}

// TargetTransformInfoImplBase::getCastInstrCost
fn base_cast_cost(o: i64, dst: i32, src: i32) -> i64 {
    if o == OP_INTTOPTR {
        let s = tt_scalar_bits(src);
        if dl_is_legal_integer(s) && s <= dl_size_bits(ty_scalar(dst)) { return 0; }
    } else if o == OP_PTRTOADDR {
        if dl_is_legal_integer(tt_scalar_bits(dst)) { return 0; }
    } else if o == OP_PTRTOINT {
        let d = tt_scalar_bits(dst);
        if dl_is_legal_integer(d) && d >= dl_size_bits(ty_scalar(src)) { return 0; }
    } else if o == OP_BITCAST {
        if dst == src || (ty_kind(dst) == TK_PTR && ty_kind(src) == TK_PTR) { return 0; }
    } else if o == OP_TRUNC {
        if ty_kind(dst) != TK_SVEC && dl_is_legal_integer(dl_size_bits(dst)) { return 0; }
    }
    return 1;
}

// X86TTIImpl::getCastInstrCost. cch: TTI::CastContextHint; i: the instruction or -1.
recursive fn x86_cast_cost(o: i64, dst: i32, src: i32, cch: i64, kind: i64, i: i32) -> i64 {
    let isd = x86_isd_of_opcode(o);
    let sty = x86_value_type(src, false);
    let dty = x86_value_type(dst, false);
    if !x86_avx512() || (!x86_bwi() && evt_scalar_bits(dty) < 32) {
        if i >= 0 && o == OP_SEXT && evt_is_vec(sty) && evt_elt(sty) == MVT_i1 as i64 {
            let c = op(i, 0);
            if is_inst(c) && (iop(c) == OP_ICMP || iop(c) == OP_FCMP) {
                if tt_scalar_bits(vals[op(c, 0)].ty) == evt_scalar_bits(dty) { return TCC_FREE; }
            }
        }
    }
    var r: i64 = -1;
    if evt_is_simple(sty) && evt_is_simple(dty) {
        let s = sty as i32;
        let d = dty as i32;
        if x86_use_avx512_regs() {
            if x86_bwi() { r = xct(XCT_C_AVX512BWConversionTbl, isd, d, s, kind); if r >= 0 { return r; } }
            if x86_dqi() { r = xct(XCT_C_AVX512DQConversionTbl, isd, d, s, kind); if r >= 0 { return r; } }
            if x86_avx512() { r = xct(XCT_C_AVX512FConversionTbl, isd, d, s, kind); if r >= 0 { return r; } }
        }
        if x86_bwi() { r = xct(XCT_C_AVX512BWVLConversionTbl, isd, d, s, kind); if r >= 0 { return r; } }
        if x86_dqi() { r = xct(XCT_C_AVX512DQVLConversionTbl, isd, d, s, kind); if r >= 0 { return r; } }
        if x86_avx512() { r = xct(XCT_C_AVX512VLConversionTbl, isd, d, s, kind); if r >= 0 { return r; } }
        if x86_avx2() { r = xct(XCT_C_AVX2ConversionTbl, isd, d, s, kind); if r >= 0 { return r; } }
        if x86_avx() { r = xct(XCT_C_AVXConversionTbl, isd, d, s, kind); if r >= 0 { return r; } }
        if xst_hasF16C() { r = xct(XCT_C_F16ConversionTbl, isd, d, s, kind); if r >= 0 { return r; } }
        if x86_sse41() { r = xct(XCT_C_SSE41ConversionTbl, isd, d, s, kind); if r >= 0 { return r; } }
        if x86_sse2() { r = xct(XCT_C_SSE2ConversionTbl, isd, d, s, kind); if r >= 0 { return r; } }
        if (isd == XISD_FP_ROUND && d == MVT_f16) || (isd == XISD_FP_EXTEND && s == MVT_f16) { return 64; }
    }
    let lsc, ls = x86_legalize(src);
    let ldc, ld = x86_legalize(dst);
    if isd == XISD_TRUNCATE && ls == ld { return TCC_FREE; }
    let mx = tc_max(lsc, ldc);
    if x86_use_avx512_regs() {
        if x86_bwi() { r = xct(XCT_C_AVX512BWConversionTbl, isd, ld, ls, kind); if r >= 0 { return tc_mul(mx, r); } }
        if x86_dqi() { r = xct(XCT_C_AVX512DQConversionTbl, isd, ld, ls, kind); if r >= 0 { return tc_mul(mx, r); } }
        if x86_avx512() { r = xct(XCT_C_AVX512FConversionTbl, isd, ld, ls, kind); if r >= 0 { return tc_mul(mx, r); } }
    }
    if x86_bwi() { r = xct(XCT_C_AVX512BWVLConversionTbl, isd, ld, ls, kind); if r >= 0 { return tc_mul(mx, r); } }
    if x86_dqi() { r = xct(XCT_C_AVX512DQVLConversionTbl, isd, ld, ls, kind); if r >= 0 { return tc_mul(mx, r); } }
    if x86_avx512() { r = xct(XCT_C_AVX512VLConversionTbl, isd, ld, ls, kind); if r >= 0 { return tc_mul(mx, r); } }
    if x86_avx2() { r = xct(XCT_C_AVX2ConversionTbl, isd, ld, ls, kind); if r >= 0 { return tc_mul(mx, r); } }
    if x86_avx() { r = xct(XCT_C_AVXConversionTbl, isd, ld, ls, kind); if r >= 0 { return tc_mul(mx, r); } }
    if xst_hasF16C() { r = xct(XCT_C_F16ConversionTbl, isd, ld, ls, kind); if r >= 0 { return tc_mul(mx, r); } }
    if x86_sse41() { r = xct(XCT_C_SSE41ConversionTbl, isd, ld, ls, kind); if r >= 0 { return tc_mul(mx, r); } }
    if x86_sse2() { r = xct(XCT_C_SSE2ConversionTbl, isd, ld, ls, kind); if r >= 0 { return tc_mul(mx, r); } }
    let sb = tt_scalar_bits(src);
    let db = tt_scalar_bits(dst);
    if (isd == XISD_SINT_TO_FP || isd == XISD_UINT_TO_FP) && 1 < sb && sb < 32 {
        let ext = tt_with_bits(src, 32);
        let eo = if isd == XISD_SINT_TO_FP { OP_SEXT } else { OP_ZEXT };
        var ec: i64 = 0;
        if !(ty_is_int(src) && i >= 0 && is_inst_op(op(i, 0), OP_LOAD)) { ec = x86_cast_cost(eo, ext, src, cch, kind, -1); }
        return tc_add(ec, x86_cast_cost(OP_SITOFP, dst, ext, 0, kind, -1));
    }
    if (isd == XISD_FP_TO_SINT || isd == XISD_FP_TO_UINT) && 1 < db && db < 32 {
        let td = tt_with_bits(dst, 32);
        return tc_add(x86_cast_cost(OP_FPTOSI, td, src, cch, kind, -1), x86_cast_cost(OP_TRUNC, dst, td, 0, kind, -1));
    }
    let b = bt_cast_cost(o, dst, src, cch, kind, i);
    if kind != TCK_RECIP_THROUGHPUT { return if b == 0 { 0 } else { 1 }; }
    return b;
}

// BasicTTIImplBase::getCastInstrCost
recursive fn bt_cast_cost(o: i64, dst: i32, src: i32, cch: i64, kind: i64, i: i32) -> i64 {
    if base_cast_cost(o, dst, src) == 0 { return 0; }
    let isd = x86_isd_of_opcode(o);
    let lsc, ls = x86_legalize(src);
    let ldc, ld = x86_legalize(dst);
    let ssz = mvt_bits(ls);
    let dsz = mvt_bits(ld);
    let s_int = ty_is_int(src) || ty_kind(src) == TK_PTR;
    let d_int = ty_is_int(dst) || ty_kind(dst) == TK_PTR;
    var to_bitcast = false;
    if o == OP_TRUNC {
        if x86_tl_truncate_free_mvt(ls, ld) { return 0; }
        to_bitcast = true;
    }
    if o == OP_BITCAST || to_bitcast {
        if lsc == ldc && s_int == d_int && ssz == dsz { return 0; }
    } else if o == OP_FPEXT {
        // isExtFree(I): X86TargetLowering::isFPExtFree / isExtFreeImpl are false for an fpext
    } else if o == OP_ZEXT || o == OP_SEXT {
        if o == OP_ZEXT && x86_tl_zext_free_mvt(ls, ld) { return 0; }
        if i >= 0 && x86_tl_is_ext_free(i) { return 0; }
        if cch == 1 && i >= 0 {
            let ext_vt = x86_value_type(dst, false);
            let load_vt = x86_value_type(src, false);
            let lty = if o == OP_ZEXT { XLE_ZEXTLOAD } else { XLE_SEXTLOAD };
            let l = op(i, 0);
            if is_inst_op(l, OP_LOAD) {
                if ldc == lsc && tl_load_legal(ext_vt, load_vt, lty) { return 0; }
            } else if inst_iid(l) == IID_masked_load {
                if ldc == lsc && tl_load_legal(ext_vt, load_vt, lty) { return 0; }
            }
        }
    } else if o == OP_ADDRSPACECAST {
        // X86TargetLowering::isFreeAddrSpaceCast = isNoopAddrSpaceCast: both address spaces below 256
        let sa = types[ty_scalar(src)].n as i64;
        let da = types[ty_scalar(dst)].n as i64;
        if sa < 256 && da < 256 { return 0; }
    }
    let src_vec = ty_is_vector(src);
    let dst_vec = ty_is_vector(dst);
    if lsc == ldc && tl_legal_or_promote(isd, ld as i64) { return lsc; }
    if !src_vec && !dst_vec {
        if !tl_op_expand(isd, ld as i64) { return 1; }
        return 4;
    }
    if dst_vec && src_vec {
        if lsc == ldc && ssz == dsz {
            if o == OP_ZEXT { return lsc; }
            if o == OP_SEXT { return tc_mul(lsc, 2); }
            if !tl_op_expand(isd, ld as i64) { return lsc; }
        }
        let split_src = tl_type_action(x86_value_type(src, false)) == TA_SPLIT;
        let split_dst = tl_type_action(x86_value_type(dst, false)) == TA_SPLIT;
        if (split_src || split_dst) && ty_count(src) % 2 == 0 && ty_count(dst) % 2 == 0 {
            let hd = ty_vector(ty_elem(dst), ty_count(dst) / 2, ty_kind(dst) == TK_SVEC);
            let hs = ty_vector(ty_elem(src), ty_count(src) / 2, ty_kind(src) == TK_SVEC);
            // getVectorSplitCost() is 1
            let sc: i64 = if !split_src || !split_dst { 1 } else { 0 };
            return tc_add(sc, tc_mul(x86_cast_cost(o, hd, hs, cch, kind, i), 2));
        }
        if ty_kind(dst) == TK_SVEC { return TTI_INVALID; }
        let num = ty_count(dst);
        let c = x86_cast_cost(o, ty_scalar(dst), ty_scalar(src), cch, kind, i);
        return tc_add(x86_scalarization_overhead_all(dst, true, true, kind), tc_mul(c, num));
    }
    if o == OP_BITCAST {
        var c: i64 = 0;
        if src_vec { c = tc_add(c, x86_scalarization_overhead_all(src, false, true, kind)); }
        if dst_vec { c = tc_add(c, x86_scalarization_overhead_all(dst, true, false, kind)); }
        return c;
    }
    fatal("TargetTransformInfo: getCastInstrCost: unhandled cast");
    return 0;
}

// X86TargetLowering::isTruncateFree(EVT, EVT) on MVTs
fn x86_tl_truncate_free_mvt(a: i32, b: i32) -> bool {
    if !mvt_is_int(a) || mvt_is_vec(a) || !mvt_is_int(b) || mvt_is_vec(b) { return false; }
    return mvt_bits(a) > mvt_bits(b);
}
// X86TargetLowering::isZExtFree(EVT, EVT): i32 -> i64 in 64-bit mode
fn x86_tl_zext_free_mvt(a: i32, b: i32) -> bool { a == MVT_i32 && b == MVT_i64 && x86_st_is64 }
// TargetLoweringBase::isExtFree(I): isExtFreeImpl: X86 makes a zext free when its operand is a load
// (isZExtFree(SDValue) is only for the DAG); the generic version: an extension of a load that is legal as an
// extending load is free only in the DAG. X86TargetLowering::isExtFreeImpl is not overridden, so: false unless
// the extension is a zext of i32 to i64 in 64-bit mode (isZExtFree(Type, Type)).
fn x86_tl_is_ext_free(i: i32) -> bool {
    let o = iop(i);
    if o != OP_ZEXT && o != OP_SEXT && o != OP_FPEXT { return false; }
    // TargetLoweringBase::isExtFree: isa<FPExtInst> -> isFPExtFree (false); else isExtFreeImpl (false) ...
    // ... unless isZExtFree(I->getOperand(0)->getType(), I->getType()) for a zext
    if o == OP_ZEXT {
        let s = vals[op(i, 0)].ty;
        let d = vals[i].ty;
        if ty_is_int(s) && ty_is_int(d) && ty_bits(s) == 32 && ty_bits(d) == 64 && x86_st_is64 { return true; }
    }
    return false;
}

// ---------------------------------------------------------------- getCmpSelInstrCost

// predicate numbers (CmpInst::Predicate)
let PRED_FCMP_OEQ: i64 = 1;
let PRED_FCMP_ONE: i64 = 6;
let PRED_FCMP_UNO: i64 = 8;
let PRED_FCMP_UEQ: i64 = 9;
let PRED_ICMP_NE: i64 = 33;
let PRED_ICMP_UGT: i64 = 34;
let PRED_ICMP_UGE: i64 = 35;
let PRED_ICMP_ULT: i64 = 36;
let PRED_ICMP_ULE: i64 = 37;
let PRED_ICMP_SGE: i64 = 39;
let PRED_ICMP_SLE: i64 = 41;
let PRED_BAD_FCMP: i64 = 16;
let PRED_BAD_ICMP: i64 = 42;

// X86TTIImpl::getCmpSelInstrCost (opcode, value type, condition type (-1 none), predicate, kind, instruction or -1)
recursive fn x86_cmpsel_cost(o: i64, valty: i32, condty: i32, pred0: i64, kind: i64, op1: i64, op2: i64, i: i32) -> i64 {
    let st = ty_scalar(valty);
    if !(ty_is_int(st) || ty_is_fp(st)) { return bt_cmpsel_cost(o, valty, condty, pred0, kind, op1, op2, i); }
    let ltc, lt = x86_legalize(valty);
    let isd = x86_isd_of_opcode(o);
    var extra: i64 = 0;
    if (o == OP_ICMP || o == OP_FCMP) && mvt_is_vec(lt) &&
       !((x86_xop() && (!x86_avx2() || mvt_is128(lt))) || (x86_avx512() && 32 <= mvt_scalar_bits(lt)) || x86_bwi()) {
        var pred = pred0;
        if i >= 0 && (pred == PRED_BAD_ICMP || pred == PRED_BAD_FCMP) { pred = inst_pred(i); }
        var with_const = false;
        if i >= 0 && is_inst(i) && (iop(i) == OP_ICMP || iop(i) == OP_FCMP) { with_const = is_constant(op(i, 1)); }
        let sb = mvt_scalar_bits(lt);
        if pred == PRED_ICMP_NE || pred == PRED_ICMP_SGE || pred == PRED_ICMP_SLE {
            extra = if with_const { 0 } else { 1 };
        } else if pred == PRED_ICMP_ULT || pred == PRED_ICMP_UGT {
            extra = if with_const { 1 } else { 2 };
        } else if pred == PRED_ICMP_ULE || pred == PRED_ICMP_UGE {
            if (x86_sse41() && sb == 32) || (x86_sse2() && sb < 32) { extra = 1; }
            else { extra = if with_const { 2 } else { 3 }; }
        } else if pred == PRED_FCMP_ONE || pred == PRED_FCMP_UEQ {
            if condty >= 0 && !x86_avx() {
                return tc_add3(x86_cmpsel_cost(o, valty, condty, PRED_FCMP_UNO, kind, op1, op2, -1),
                               x86_cmpsel_cost(o, valty, condty, PRED_FCMP_OEQ, kind, op1, op2, -1),
                               x86_arith0(OP_OR, condty, kind));
            }
        } else if pred == PRED_BAD_ICMP || pred == PRED_BAD_FCMP {
            extra = 3;
        }
    }
    var r: i64 = -1;
    if x86_slm_arith() { r = xc1(XCT_S_SLMCostTbl, isd, lt, kind); if r >= 0 { return tc_mul(ltc, extra + r); } }
    if x86_bwi() { r = xc1(XCT_S_AVX512BWCostTbl, isd, lt, kind); if r >= 0 { return tc_mul(ltc, extra + r); } }
    if x86_avx512() { r = xc1(XCT_S_AVX512CostTbl, isd, lt, kind); if r >= 0 { return tc_mul(ltc, extra + r); } }
    if x86_avx2() { r = xc1(XCT_S_AVX2CostTbl, isd, lt, kind); if r >= 0 { return tc_mul(ltc, extra + r); } }
    if x86_xop() { r = xc1(XCT_S_XOPCostTbl, isd, lt, kind); if r >= 0 { return tc_mul(ltc, extra + r); } }
    if x86_avx() { r = xc1(XCT_S_AVX1CostTbl, isd, lt, kind); if r >= 0 { return tc_mul(ltc, extra + r); } }
    if x86_sse42() { r = xc1(XCT_S_SSE42CostTbl, isd, lt, kind); if r >= 0 { return tc_mul(ltc, extra + r); } }
    if x86_sse41() { r = xc1(XCT_S_SSE41CostTbl, isd, lt, kind); if r >= 0 { return tc_mul(ltc, extra + r); } }
    if x86_sse2() { r = xc1(XCT_S_SSE2CostTbl, isd, lt, kind); if r >= 0 { return tc_mul(ltc, extra + r); } }
    if x86_sse1() { r = xc1(XCT_S_SSE1CostTbl, isd, lt, kind); if r >= 0 { return tc_mul(ltc, extra + r); } }
    if kind == TCK_LATENCY && o == OP_SELECT && ty_is_fp(st) { return 3; }
    return bt_cmpsel_cost(o, valty, condty, pred0, kind, op1, op2, i);
}

// BasicTTIImplBase::getCmpSelInstrCost
recursive fn bt_cmpsel_cost(o: i64, valty: i32, condty: i32, pred: i64, kind: i64, op1: i64, op2: i64, i: i32) -> i64 {
    var isd = x86_isd_of_opcode(o);
    if x86_value_type(valty, true) == MVT_Other as i64 { return 1; }
    if isd == XISD_SELECT && condty >= 0 && ty_is_vector(condty) { isd = XISD_VSELECT; }
    let ltc, lt = x86_legalize(valty);
    if !(ty_is_vector(valty) && !mvt_is_vec(lt)) && !tl_op_expand(isd, lt as i64) { return ltc; }
    if ty_is_vector(valty) {
        if ty_kind(valty) == TK_SVEC { return TTI_INVALID; }
        let num = ty_count(valty);
        let c = x86_cmpsel_cost(o, ty_scalar(valty), if condty >= 0 { ty_scalar(condty) } else { -1 }, pred, kind, op1, op2, i);
        return tc_add(x86_scalarization_overhead_all(valty, true, false, kind), tc_mul(c, num));
    }
    return 1;
}

// ---------------------------------------------------------------- getCFInstrCost

// X86TTIImpl::getCFInstrCost
fn x86_cf_cost(o: i64, kind: i64) -> i64 {
    if kind != TCK_RECIP_THROUGHPUT { return if o == OP_PHI { 0 } else { 1 }; }
    return TCC_FREE;
}

// ---------------------------------------------------------------- misc queries

// X86TTIImpl::hasConditionalLoadStoreForType
fn x86_has_conditional_load_store_for_type(t: i32) -> bool {
    if !xst_hasCF() { return false; }
    if t < 0 { return true; }
    var s = t;
    if ty_kind(t) == TK_FVEC {
        if ty_count(t) != 1 { return false; }
        s = ty_elem(t);
    } else if ty_kind(t) == TK_SVEC { return false; }
    if !ty_is_int(s) { return false; }
    let b = ty_bits(s);
    return b == 16 || b == 32 || b == 64;
}

// X86TargetLowering::isLegalAddressingMode (small code model; the base global classified by
// X86Subtarget::classifyGlobalReference / TargetMachine::shouldAssumeDSOLocal)
fn x86_legal_addressing_mode(base_gv: i32, off: i64, has_base: bool, scale: i64) -> bool {
    if off < -2147483648 || off > 2147483647 { return false; }
    if base_gv >= 0 {
        if off >= 16 * 1024 * 1024 { return false; }
        if !x86_st_is64 { x86_np("isLegalAddressingMode with a global base on 32-bit x86"); }
        if !x86_dso_local(base_gv) { return false; }   // MO_GOTPCREL / MO_COFFSTUB / MO_DLLIMPORT: a stub
        if x86_pic && (off != 0 || scale > 1) { return false; }
    }
    if scale == 0 || scale == 1 || scale == 2 || scale == 4 || scale == 8 { return true; }
    if scale == 3 || scale == 5 || scale == 9 { return !has_base; }
    return false;
}

// TargetMachine::shouldAssumeDSOLocal for a 64-bit target
fn x86_dso_local(gv: i32) -> bool {
    let g = globs[glob_of(gv)];
    let lk = g.linkage as i64;
    if g.dso_local != 0 { return true; }
    if lk == LK_INTERNAL || lk == LK_PRIVATE { return true; }
    if g.vis != 0 && lk != LK_EXTERN_WEAK { return true; }
    if x86_os == 2 {
        if g.dll == 1 { return false; }   // dllimport
        if lk == LK_EXTERN_WEAK { return false; }
        if g.is_decl != 0 && vals[gv].kind == VK_GVAR { x86_np("shouldAssumeDSOLocal of a declared variable on Windows (MinGW auto-import)"); }
        return true;
    }
    if x86_os == 1 {
        if !x86_pic { return true; }
        x86_np("shouldAssumeDSOLocal on Darwin (isStrongDefinitionForLinker)");
    }
    return false;
}

// ---------------------------------------------------------------- calling-convention register types

// RegisterTypeForVT of an MVT (TargetLoweringBase::computeRegisterProperties)
recursive fn x86_register_type_mvt(m: i32) -> i32 {
    if x86_mvt_legal(m) { return m; }
    let c = mvt_elt(m);
    if !mvt_is_vec(m) {
        if xe_is_int(c) {
            let b = xe_bits(c);
            let lg = x86_largest_int_bits();
            if b > lg { return mvt_mk(xe_int_code(lg), 0); }
            var w: i64 = b;
            while !x86_mvt_legal(mvt_mk(xe_int_code(w), 0)) { w = if w < 8 { 8 } else { w * 2 }; }
            return mvt_mk(xe_int_code(w), 0);
        }
        if c == XE_F128 { return x86_register_type_mvt(mvt_mk(XE_I128, 0)); }
        if c == XE_F80 { return x86_register_type_mvt(mvt_mk(XE_I32, 0)); }
        if c == XE_F64 { return x86_register_type_mvt(mvt_mk(XE_I64, 0)); }
        if c == XE_F32 { return x86_register_type_mvt(mvt_mk(XE_I32, 0)); }
        if c == XE_F16 { return x86_register_type_mvt(mvt_mk(XE_I16, 0)); }   // useFPRegsForHalfType() is false
        if c == XE_BF16 { return x86_register_type_mvt(mvt_mk(XE_F32, 0)); }
        x86_np("the register type of this scalar value type");
    }
    let a, nx = x86_mvt_action(m);
    if (a == TA_PROMOTE || a == TA_WIDEN) && evt_is_simple(nx) && x86_mvt_legal(evt_to_mvt(nx)) { return evt_to_mvt(nx); }
    // getVectorTypeBreakdownMVT
    var n = mvt_n(m);
    if (n & (n - 1)) != 0 { n = 1; }
    while n > 1 && !(mvt_vec_index(mvt_mk(c, n)) >= 0 && x86_mvt_legal(mvt_mk(c, n))) { n = n / 2; }
    var nv = mvt_mk(c, n);
    if !(mvt_vec_index(nv) >= 0 && x86_mvt_legal(nv)) { nv = mvt_mk(c, 0); }
    return x86_register_type_mvt(nv);
}

fn x86_evt_legal(e: i64) -> bool { evt_is_simple(e) && x86_mvt_legal(evt_to_mvt(e)) }

// TargetLoweringBase::getRegisterType(Context, EVT)
recursive fn x86_register_type(e: i64) -> i32 {
    if evt_is_simple(e) { return x86_register_type_mvt(evt_to_mvt(e)); }
    if evt_is_vec(e) {
        // getVectorTypeBreakdown
        let ta, rt = x86_type_conversion(e);
        if evt_n(e) != 1 && (ta == TA_WIDEN || ta == TA_PROMOTE) && x86_evt_legal(rt) { return evt_to_mvt(rt); }
        let elt = evt_elt(e);
        var n = evt_n(e);
        if (n & (n - 1)) != 0 { n = 1; }
        while n > 1 && !x86_evt_legal(evt_vec(elt, n)) { n = n / 2; }
        var nv = evt_vec(elt, n);
        if !x86_evt_legal(nv) { nv = elt; }
        return x86_register_type(nv);
    }
    if xe_is_int(evt_code(e)) {
        let ta, rt = x86_type_conversion(e);
        return x86_register_type(rt);
    }
    x86_np("the register type of an extended non-integer value type");
    return 0;
}

// X86TargetLowering::getRegisterTypeForCallingConv(Context, CC, VT) for the current subtarget
recursive fn x86_register_type_for_cc(e: i64, cc: i64) -> i32 {
    if evt_is_vec(e) {
        let elt = evt_code(evt_elt(e));
        let n = evt_n(e);
        if elt == XE_I1 && x86_avx512() {
            // handleMaskRegisterForCallingConv; X86_RegCall = 92, Intel_OCL_BI = 77
            let rc = cc == 92 || cc == 77;
            if n == 2 { return mvt_mk(XE_I64, 2); }
            if n == 4 { return mvt_mk(XE_I32, 4); }
            if n == 8 && !rc { return mvt_mk(XE_I16, 8); }
            if n == 16 && !rc { return mvt_mk(XE_I8, 16); }
            if n == 32 && (!x86_bwi() || cc != 92) { return mvt_mk(XE_I8, 32); }
            if n == 64 && x86_bwi() && cc != 92 { return if x86_use_avx512_regs() { mvt_mk(XE_I8, 64) } else { mvt_mk(XE_I8, 32) }; }
            if (n & (n - 1)) != 0 || (n == 64 && !x86_bwi()) || n > 64 { return mvt_mk(XE_I8, 0); }
        }
        if elt == XE_F16 && n < 8 { return mvt_mk(XE_F16, 8); }
    }
    if !x86_is64 && !x86_has(X86F_FeatureX87) && !evt_is_vec(e) && (evt_code(e) == XE_F64 || evt_code(e) == XE_F80) { return mvt_mk(XE_I32, 0); }
    if x86_mvt_legal(mvt_mk(XE_F16, 0)) {
        if evt_is_vec(e) && evt_code(evt_elt(e)) == XE_BF16 { return x86_register_type_for_cc(evt_vec(evt_mk(XE_F16, 16, 0), evt_n(e)), cc); }
        if !evt_is_vec(e) && evt_code(e) == XE_BF16 { return mvt_mk(XE_F16, 0); }
    }
    return x86_register_type(e);
}

// ComputeValueVTs(TLI, DL, Ty, VTs): the value types of the scalar / vector leaves of an aggregate
recursive fn x86_compute_value_vts(t: i32, out: i64[>..<]&) {
    let k = ty_kind(t);
    if k == TK_STRUCT {
        for j in types[t].cnt { x86_compute_value_vts(ints[types[t].a + j], out); }
        return;
    }
    if k == TK_ARRAY {
        for j in types[t].cnt { x86_compute_value_vts(types[t].a, out); }
        return;
    }
    if k == TK_VOID { return; }
    out.push(x86_value_type(t, false));
}
