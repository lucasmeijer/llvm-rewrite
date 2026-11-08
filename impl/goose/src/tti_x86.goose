// The X86 cost model: X86TTIImpl over BasicTTIImplBase. Ports
//   llvm/lib/Target/X86/X86TargetTransformInfo.cpp     (the cost queries and their tables)
//   llvm/include/llvm/CodeGen/BasicTTIImpl.h          (getTypeLegalizationCost and the BaseT fallbacks)
//   llvm/lib/Target/X86/X86Subtarget.cpp, X86TargetMachine.cpp (subtarget features per function)
//   llvm/lib/Target/X86/X86ISelLowering.cpp            (which value types have a register class)
//   llvm/lib/CodeGen/TargetLoweringBase.cpp            (computeRegisterProperties, getTypeConversion)
// The cost tables, the feature list with its implications, the CPU feature lists and the vector MVTs are
// generated into gen_x86costs.goose by tools/gen_x86costs.py.
//
// Value types: an MVT is an i32 `element code | (elements << 8)` (0 elements for a scalar), the encoding of the
// generated tables. An EVT is an i64 `code | (bits << 8) | (elements << 32)`; code XE_EXT is an integer width with
// no MVT (i3, i24, ...). Only what opt's scalar passes query is ported: every path that would need more of the
// SelectionDAG legality tables than ported here fails loudly (x86_np).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import gen_x86costs;
import datalayout;
import apint;
import pm;
import flags;

let XE_I1 = 1;
let XE_I2 = 2;
let XE_I4 = 3;
let XE_I8 = 4;
let XE_I16 = 5;
let XE_I32 = 6;
let XE_I64 = 7;
let XE_I128 = 8;
let XE_F16 = 9;
let XE_BF16 = 10;
let XE_F32 = 11;
let XE_F64 = 12;
let XE_F80 = 13;
let XE_F128 = 14;
let XE_I256 = 15;
let XE_I512 = 16;
let XE_OTHER = 17;
let XE_EXT = 31;

let EVT_OTHER: i64 = 17;

// LegalizeTypeAction
let TA_LEGAL = 0;
let TA_PROMOTE = 1;
let TA_EXPAND = 2;
let TA_SOFTEN = 3;
let TA_SCALARIZE = 5;
let TA_SPLIT = 6;
let TA_WIDEN = 7;
let TA_SOFT_PROMOTE_HALF = 9;

fn x86_np(what: const u8[:]) {
    fatal(str("TargetTransformInfo: the X86 cost model (", what, ") is not ported yet"));
}

// ---------------------------------------------------------------- subtarget

var x86_bits: u64[4] = [0, 0, 0, 0];
var x86_sse: i64 = 0;          // X86SSELevel: 0 none .. 9 AVX512
var x86_is64 = false;
var x86_soft_float = false;
var x86_prefer_width: i64 = 0xffffffff;
var x86_required_width: i64 = 0xffffffff;
var x86_os: i64 = 0;           // 0 ELF, 1 Darwin (MachO), 2 Windows (COFF)
var x86_pic = false;           // TargetMachine::isPositionIndependent

fn x86_has(f: i32) -> bool { ((x86_bits[f / 64] >> ((f % 64) as u64)) & 1) != 0 }
fn x86_set(f: i32) {
    x86_bits[f / 64] |= (1 as u64) << ((f % 64) as u64);
    for w in 4 { x86_bits[w] |= X86F_IMPLIES[f * 4 + w]; }
}
// MCSubtargetInfo ClearImpliedBits: clear f and every feature that implies it.
fn x86_clear(f: i32) {
    x86_bits[f / 64] &= ~((1 as u64) << ((f % 64) as u64));
    for g in X86F_COUNT {
        if ((X86F_IMPLIES[g * 4 + f / 64] >> ((f % 64) as u64)) & 1) != 0 {
            x86_bits[g / 64] &= ~((1 as u64) << ((g % 64) as u64));
        }
    }
}
fn x86_feature_index(name: const u8[:]) -> i32 {
    for k in X86F_COUNT { if X86F_NAMES[k] == name { return k; } }
    return -1;
}
// A comma-separated feature string ("+a,-b"), applied in order.
fn x86_apply_features(fs: const u8[:]) {
    var st: i64 = 0;
    for j in 0..fs.len + 1 {
        if j < fs.len && fs[j] != ',' { continue; }
        var f = fs[st..j];
        st = j + 1;
        if f.len == 0 { continue; }
        var on = true;
        if f[0] == '+' { f = f[1..]; } else if f[0] == '-' { on = false; f = f[1..]; }
        let k = x86_feature_index(f);
        if k < 0 { fatal(str("TargetTransformInfo: X86 subtarget feature '", f, "' is not known")); }
        if on { x86_set(k); } else { x86_clear(k); }
    }
}
fn x86_apply_cpu(cpu: const u8[:], tune: bool) {
    for c in X86CPU_NAMES.len {
        if X86CPU_NAMES[c] == cpu {
            for f in X86F_COUNT {
                let w = if tune { X86CPU_TUNING[c * 4 + (f / 64) as i64] } else { X86CPU_FEATURES[c * 4 + (f / 64) as i64] };
                if ((w >> ((f % 64) as u64)) & 1) != 0 { x86_set(f); }
            }
            return;
        }
    }
    fatal(str("TargetTransformInfo: X86 CPU '", cpu, "' is not supported"));
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

// X86TargetMachine::getSubtargetImpl(F) + X86Subtarget::initSubtargetFeatures.
fn x86_subtarget_init(triple: const u8[:], fv: i32) {
    // the triple: arch-vendor-os-environment
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
    x86_is64 = arch == "x86_64" || arch == "amd64" || arch == "x86_64h";
    var os: const u8[:] = "";
    var env: const u8[:] = "";
    if np > 2 { os = triple[parts[2]..ends[2]]; }
    if np > 3 { env = triple[parts[3]..ends[3]]; }
    x86_os = 0;
    if starts_with(os, "darwin") || starts_with(os, "macos") || starts_with(os, "ios") || starts_with(os, "tvos") ||
       starts_with(os, "watchos") { x86_os = 1; }
    if starts_with(os, "windows") || starts_with(os, "win32") {
        x86_os = 2;
        if starts_with(env, "elf") || starts_with(env, "macho") { x86_np("Windows triples with a non-COFF object format"); }
    }
    if starts_with(env, "code16") || ends_with(env, "x32") { x86_np("16-bit and x32 triples"); }
    if !x86_is64 && !(arch.len == 4 && arch[0] == 'i' && arch[2] == '8' && arch[3] == '6') {
        fatal(str("TargetTransformInfo for target triple '", triple, "' is not supported"));
    }
    // getEffectiveRelocModel without -relocation-model
    x86_pic = (x86_os == 1 && x86_is64) || (x86_os == 2 && x86_is64);
    if x86_os == 1 && !x86_is64 { x86_np("32-bit Darwin (dynamic-no-pic)"); }

    var cpu: const u8[:] = cl_mcpu[..];
    var fs: const u8[:] = cl_mattr[..];
    var tune: const u8[:] = "";
    if fv >= 0 {
        let ca = x86_str_attr(fv, "target-cpu");
        if ca >= 0 { cpu = sbytes(ca); }
        let fa = x86_str_attr(fv, "target-features");
        if fa >= 0 { fs = sbytes(fa); }
        let ta = x86_str_attr(fv, "tune-cpu");
        if ta >= 0 { tune = sbytes(ta); }
    }
    if tune.len == 0 { tune = if cpu == "x86-64" { "generic" } else { cpu }; }
    x86_soft_float = fv >= 0 && func_str_attr_is_true_tti(fv, "use-soft-float");
    x86_prefer_width = 0;
    x86_required_width = 0xffffffff;
    if fv >= 0 {
        let pa = x86_str_attr(fv, "prefer-vector-width");
        if pa >= 0 { let w = x86_parse_uint(sbytes(pa)); if w >= 0 { x86_prefer_width = w; } }
        let ma = x86_str_attr(fv, "min-legal-vector-width");
        if ma >= 0 { let w = x86_parse_uint(sbytes(ma)); if w >= 0 { x86_required_width = w; } }
    }
    if cpu.len == 0 { cpu = "generic"; }
    if tune.len == 0 { tune = "i586"; }
    for w in 4 { x86_bits[w] = 0; }
    x86_apply_cpu(cpu, false);
    x86_apply_cpu(tune, true);
    if x86_is64 { x86_apply_features("+64bit-mode,-32bit-mode,-16bit-mode,+sse2"); }
    else { x86_apply_features("-64bit-mode,+32bit-mode,-16bit-mode"); }
    if x86_soft_float { x86_apply_features("+soft-float"); }
    x86_apply_features(fs);
    if !x86_is64 { x86_apply_features("-egpr,-push2pop2,-ppx,-ndd,-ccmp,-nf,-cf,-zu,-jmpabs,-uintr"); }
    if x86_has(X86F_FeatureSoftFloat) { x86_soft_float = true; }
    x86_sse = 0;
    let lv: i32[9] = [X86F_FeatureSSE1, X86F_FeatureSSE2, X86F_FeatureSSE3, X86F_FeatureSSSE3, X86F_FeatureSSE41,
                      X86F_FeatureSSE42, X86F_FeatureAVX, X86F_FeatureAVX2, X86F_FeatureAVX512];
    for k in 9 { if x86_has(lv[k]) { x86_sse = k as i64 + 1; } }
    // PreferVectorWidth: the attribute, else Prefer128Bit / Prefer256Bit tuning, else unlimited
    if x86_prefer_width == 0 {
        x86_prefer_width = 0xffffffff;
        if x86_has(X86F_TuningPrefer128Bit) { x86_prefer_width = 128; }
        else if x86_has(X86F_TuningPrefer256Bit) { x86_prefer_width = 256; }
    }
}

fn func_str_attr_is_true_tti(fv: i32, key: const u8[:]) -> bool {
    let a = aset_find_str(alist_fn(func_attrs(fv)), key);
    if a < 0 { return false; }
    return sbytes(attrs[a].sval) == "true";
}

fn x86_sse1() -> bool { x86_sse >= 1 }
fn x86_sse2() -> bool { x86_sse >= 2 }
fn x86_ssse3() -> bool { x86_sse >= 4 }
fn x86_sse41() -> bool { x86_sse >= 5 }
fn x86_sse42() -> bool { x86_sse >= 6 }
fn x86_avx() -> bool { x86_sse >= 7 }
fn x86_avx2() -> bool { x86_sse >= 8 }
fn x86_avx512() -> bool { x86_sse >= 9 }
fn x86_bwi() -> bool { x86_has(X86F_FeatureBWI) }
fn x86_dqi() -> bool { x86_has(X86F_FeatureDQI) }
fn x86_vlx() -> bool { x86_has(X86F_FeatureVLX) }
fn x86_xop() -> bool { x86_has(X86F_FeatureXOP) }
fn x86_use_avx512_regs() -> bool {
    if !x86_avx512() { return false; }
    let can_extend_512dq = !x86_vlx() || x86_prefer_width >= 512;
    return can_extend_512dq || x86_required_width > 256;
}
fn x86_slm_arith() -> bool { x86_has(X86F_TuningUseSLMArithCosts) }
fn x86_glm_divsqrt() -> bool { x86_has(X86F_TuningUseGLMDivSqrtCosts) }

// ---------------------------------------------------------------- value types

fn xe_bits(code: i64) -> i64 {
    let b: i64[18] = [0, 1, 2, 4, 8, 16, 32, 64, 128, 16, 16, 32, 64, 80, 128, 256, 512, 0];
    return b[code];
}
fn xe_is_int(code: i64) -> bool { (code >= XE_I1 && code <= XE_I128) || code == XE_I256 || code == XE_I512 || code == XE_EXT }
fn xe_is_fp(code: i64) -> bool { code >= XE_F16 && code <= XE_F128 }
fn xe_int_code(bits: i64) -> i64 {
    if bits == 1 { return XE_I1; }
    if bits == 2 { return XE_I2; }
    if bits == 4 { return XE_I4; }
    if bits == 8 { return XE_I8; }
    if bits == 16 { return XE_I16; }
    if bits == 32 { return XE_I32; }
    if bits == 64 { return XE_I64; }
    if bits == 128 { return XE_I128; }
    if bits == 256 { return XE_I256; }
    if bits == 512 { return XE_I512; }
    return XE_EXT;
}

fn mvt_elt(m: i32) -> i64 { (m & 255) as i64 }
fn mvt_n(m: i32) -> i64 { (m >> 8) as i64 }
fn mvt_is_vec(m: i32) -> bool { (m >> 8) != 0 }
fn mvt_scalar_bits(m: i32) -> i64 { xe_bits(mvt_elt(m)) }
fn mvt_size_bits(m: i32) -> i64 { let n = mvt_n(m); xe_bits(mvt_elt(m)) * (if n == 0 { 1 } else { n }) }
fn mvt_mk(code: i64, n: i64) -> i32 { (code | (n << 8)) as i32 }
fn mvt_vec_index(m: i32) -> i64 {
    for k in X86_VECTOR_MVTS.len { if X86_VECTOR_MVTS[k] == m { return k as i64; } }
    return -1;
}

fn evt_mk(code: i64, bits: i64, n: i64) -> i64 { code | (bits << 8) | (n << 32) }
fn evt_int(bits: i64) -> i64 { evt_mk(xe_int_code(bits), bits, 0) }
fn evt_code(e: i64) -> i64 { e & 255 }
fn evt_elt_bits(e: i64) -> i64 { (e >> 8) & 0xffffff }
fn evt_n(e: i64) -> i64 { e >> 32 }
fn evt_is_vec(e: i64) -> bool { evt_n(e) != 0 }
fn evt_elt(e: i64) -> i64 { e & 0xffffffff }
fn evt_vec(elt: i64, n: i64) -> i64 { evt_elt(elt) | (n << 32) }
fn evt_is_simple(e: i64) -> bool {
    let c = evt_code(e);
    if c == XE_EXT { return false; }
    if !evt_is_vec(e) { return true; }
    return mvt_vec_index(mvt_mk(c, evt_n(e))) >= 0;
}
fn evt_to_mvt(e: i64) -> i32 { mvt_mk(evt_code(e), evt_n(e)) }
fn mvt_to_evt(m: i32) -> i64 { let c = mvt_elt(m); evt_mk(c, xe_bits(c), mvt_n(m)) }
fn evt_is_pow2_vec(e: i64) -> bool { let n = evt_n(e); (n & (n - 1)) == 0 }

fn x86_scalar_evt(t: i32, allow_unknown: bool) -> i64 {
    let k = ty_kind(t);
    if k == TK_INT { return evt_int(ty_bits(t)); }
    if k == TK_HALF { return evt_mk(XE_F16, 16, 0); }
    if k == TK_BFLOAT { return evt_mk(XE_BF16, 16, 0); }
    if k == TK_FLOAT { return evt_mk(XE_F32, 32, 0); }
    if k == TK_DOUBLE { return evt_mk(XE_F64, 64, 0); }
    if k == TK_X86_FP80 { return evt_mk(XE_F80, 80, 0); }
    if k == TK_FP128 { return evt_mk(XE_F128, 128, 0); }
    if k == TK_PTR { return evt_int(dl_ptr(ptr_as_tti(t)).bits); }
    if k == TK_BYTE { x86_np("byte types"); }
    if k == TK_PPC_FP128 || k == TK_X86_AMX { x86_np("ppc_fp128 / x86_amx value types"); }
    if !allow_unknown { fatal("TargetTransformInfo: getValueType of a type without a value type"); }
    return EVT_OTHER;
}
fn ptr_as_tti(t: i32) -> i64 { types[ty_scalar(t)].n as i64 }

// TargetLoweringBase::getValueType(DL, Ty, AllowUnknown)
fn x86_value_type(t: i32, allow_unknown: bool) -> i64 {
    let k = ty_kind(t);
    if k == TK_SVEC { x86_np("scalable vector types"); }
    if k == TK_FVEC {
        let e = x86_scalar_evt(ty_elem(t), allow_unknown);
        if e == EVT_OTHER { return EVT_OTHER; }
        return evt_vec(e, ty_count(t));
    }
    return x86_scalar_evt(t, allow_unknown);
}

// Which MVTs have a register class (X86TargetLowering's constructor).
fn x86_mvt_legal(m: i32) -> bool {
    let c = mvt_elt(m);
    let n = mvt_n(m);
    let sf = x86_soft_float;
    let x87 = !sf && x86_has(X86F_FeatureX87);
    if n == 0 {
        if c == XE_I8 || c == XE_I16 || c == XE_I32 { return true; }
        if c == XE_I64 { return x86_is64; }
        if c == XE_F16 { return !sf && x86_sse2(); }
        if c == XE_F32 { return (!sf && x86_sse1()) || x87; }
        if c == XE_F64 { return (!sf && x86_sse2()) || x87; }
        if c == XE_F80 { return x87; }
        if c == XE_F128 { return !sf && x86_is64 && x86_sse1(); }
        return false;
    }
    if sf { return false; }
    let bits = mvt_size_bits(m);
    if c == XE_BF16 {
        if x86_has(X86F_FeatureAVXNECONVERT) || x86_has(X86F_FeatureBF16) {
            if m == mvt_mk(XE_BF16, 8) || m == mvt_mk(XE_BF16, 16) { return true; }
        }
        if m == mvt_mk(XE_BF16, 32) { return x86_has(X86F_FeatureBF16) && x86_use_avx512_regs(); }
        return false;
    }
    if c == XE_I1 {
        if !x86_avx512() { return false; }
        if n == 1 || n == 2 || n == 4 || n == 8 || n == 16 { return true; }
        if n == 32 || n == 64 { return x86_bwi(); }
        return false;
    }
    if m == mvt_mk(XE_F32, 4) { return x86_sse1(); }
    let ok_elt = c == XE_I8 || c == XE_I16 || c == XE_I32 || c == XE_I64 || c == XE_F16 || c == XE_F32 || c == XE_F64;
    if !ok_elt { return false; }
    if bits == 128 { return x86_sse2(); }
    if bits == 256 { return x86_avx(); }
    if bits == 512 { return x86_use_avx512_regs(); }
    return false;
}

fn x86_largest_int_bits() -> i64 { if x86_is64 { 64 } else { 32 } }

// X86TargetLowering::getPreferredVectorAction
fn x86_preferred_vector_action(m: i32) -> i64 {
    let n = mvt_n(m);
    let c = mvt_elt(m);
    if (m == mvt_mk(XE_I1, 32) || m == mvt_mk(XE_I1, 64)) && x86_avx512() && !x86_bwi() { return TA_SPLIT; }
    if n != 1 && n <= 4 && !x86_has(X86F_FeatureF16C) && c == XE_F16 { return TA_SPLIT; }
    if n != 1 && c != XE_I1 { return TA_WIDEN; }
    if n == 1 { return TA_SCALARIZE; }
    if (n & (n - 1)) != 0 { return TA_WIDEN; }
    return TA_PROMOTE;
}

// The action and TransformToType computeRegisterProperties assigns to an MVT (the EVT returned is the next type
// for getTypeConversion; for a split vector it is the half-width vector).
fn x86_mvt_action(m: i32) -> i64, i64 {
    if x86_mvt_legal(m) { return TA_LEGAL, mvt_to_evt(m); }
    let c = mvt_elt(m);
    let n = mvt_n(m);
    if n == 0 {
        if xe_is_int(c) {
            let b = xe_bits(c);
            let lg = x86_largest_int_bits();
            if b < lg {
                var w: i64 = 8;
                while w < lg && (w <= b || !x86_mvt_legal(mvt_mk(xe_int_code(w), 0))) { w *= 2; }
                if w <= b { w = lg; }
                return TA_PROMOTE, evt_int(w);
            }
            return TA_EXPAND, evt_int(b / 2);
        }
        if c == XE_F16 || c == XE_BF16 { return TA_SOFT_PROMOTE_HALF, evt_mk(XE_F32, 32, 0); }
        if c == XE_F128 { return TA_SOFTEN, evt_int(128); }
        if c == XE_F80 { return TA_SOFTEN, evt_int(32); }
        x86_np("soft-float f32/f64 legalization");
    }
    let idx = mvt_vec_index(m);
    let pref = x86_preferred_vector_action(m);
    var action = pref;
    if action == TA_PROMOTE {
        // a wider integer element with the same count
        for k in idx + 1..X86_VECTOR_MVTS.len as i64 {
            let s = X86_VECTOR_MVTS[k];
            let sc = mvt_elt(s);
            if !xe_is_int(sc) { continue; }
            if xe_bits(sc) > xe_bits(c) && mvt_n(s) == n && x86_mvt_legal(s) { return TA_PROMOTE, mvt_to_evt(s); }
        }
        action = TA_WIDEN;
    }
    if action == TA_WIDEN {
        if (n & (n - 1)) == 0 {
            for k in idx + 1..X86_VECTOR_MVTS.len as i64 {
                let s = X86_VECTOR_MVTS[k];
                if mvt_elt(s) == c && mvt_n(s) > n && x86_mvt_legal(s) { return TA_WIDEN, mvt_to_evt(s); }
            }
        } else {
            var p: i64 = 1;
            while p < n { p *= 2; }
            let nv = mvt_mk(c, p);
            if mvt_vec_index(nv) < 0 { x86_np("widening to a vector type without an MVT"); }
            if x86_mvt_legal(nv) { return TA_WIDEN, mvt_to_evt(nv); }
        }
    }
    // split / scalarize
    if (n & (n - 1)) == 0 {
        if pref == TA_SCALARIZE { return TA_SCALARIZE, mvt_to_evt(mvt_mk(c, 0)); }
        if pref == TA_SPLIT || n > 1 { return TA_SPLIT, evt_vec(mvt_to_evt(mvt_mk(c, 0)), n / 2); }
        return TA_SCALARIZE, mvt_to_evt(mvt_mk(c, 0));
    }
    var p: i64 = 1;
    while p < n { p *= 2; }
    return TA_WIDEN, evt_vec(mvt_to_evt(mvt_mk(c, 0)), p);
}

fn evt_round_int(bits: i64) -> i64 {
    if bits <= 8 { return evt_int(8); }
    var p: i64 = 1;
    while p < bits { p *= 2; }
    return evt_int(p);
}

// TargetLoweringBase::getTypeConversion
recursive fn x86_type_conversion(e: i64) -> i64, i64 {
    if evt_is_simple(e) { return x86_mvt_action(evt_to_mvt(e)); }
    let n = evt_n(e);
    if n == 0 {
        let b = evt_elt_bits(e);
        if b < 8 || (b & (b - 1)) != 0 {
            let nv = evt_round_int(b);
            let a2, n2 = x86_type_conversion(nv);
            if a2 == TA_PROMOTE { return a2, n2; }
            return TA_PROMOTE, nv;
        }
        return TA_EXPAND, evt_int(b / 2);
    }
    if n == 1 { return TA_SCALARIZE, evt_elt(e); }
    var elt = evt_elt(e);
    var cnt = n;
    if xe_is_int(evt_code(elt)) {
        if (n & (n - 1)) != 0 {
            var p: i64 = 1;
            while p < n { p *= 2; }
            return TA_WIDEN, evt_vec(elt, p);
        }
        let la, ln = x86_type_conversion(elt);
        if la == TA_EXPAND { return TA_SPLIT, evt_vec(elt, n / 2); }
        var eb = evt_elt_bits(elt);
        loop {
            let ne = evt_round_int(eb + 1);
            eb = evt_elt_bits(ne);
            if !evt_is_simple(ne) { break; }
            let nm = mvt_mk(evt_code(ne), n);
            if mvt_vec_index(nm) >= 0 && x86_mvt_legal(nm) { return TA_PROMOTE, evt_vec(ne, n); }
        }
    }
    loop {
        // ElementCount::coefficientNextPowerOf2: strictly greater
        var p: i64 = 1;
        while p <= cnt { p *= 2; }
        cnt = p;
        if !evt_is_simple(elt) { break; }
        let lv = mvt_mk(evt_code(elt), cnt);
        if mvt_vec_index(lv) < 0 { break; }
        if x86_mvt_legal(lv) { return TA_WIDEN, mvt_to_evt(lv); }
    }
    if (n & (n - 1)) != 0 {
        var p: i64 = 1;
        while p < n { p *= 2; }
        return TA_WIDEN, evt_vec(elt, p);
    }
    return TA_SPLIT, evt_vec(elt, n / 2);
}

// BasicTTIImplBase::getTypeLegalizationCost: (cost, legal MVT)
fn x86_legalize(t: i32) -> i64, i32 {
    var e = x86_value_type(t, false);
    var cost: i64 = 1;
    loop {
        let a, nx = x86_type_conversion(e);
        if a == TA_LEGAL { return cost, evt_to_mvt(e); }
        if a == TA_SPLIT || a == TA_EXPAND { cost *= 2; }
        if nx == e { return cost, evt_to_mvt(e); }
        e = nx;
    }
}

// isTypeLegal (TTI, AllowUnknown)
fn x86_is_type_legal(t: i32) -> bool {
    let e = x86_value_type(t, true);
    if e == EVT_OTHER || !evt_is_simple(e) { return false; }
    return x86_mvt_legal(evt_to_mvt(e));
}

// getRegUsageForType = TLI getNumRegisters(EVT)
fn x86_reg_usage(t: i32) -> i64 {
    let e = x86_value_type(t, false);
    if evt_is_vec(e) { x86_np("getRegUsageForType of vector types"); }
    if !xe_is_int(evt_code(e)) {
        let a, nx = x86_type_conversion(e);
        if a == TA_LEGAL || a == TA_SOFT_PROMOTE_HALF { return 1; }
        x86_np("getRegUsageForType of this floating-point type");
    }
    let b = evt_elt_bits(e);
    let lg = x86_largest_int_bits();
    if b <= lg { return 1; }
    return (b + lg - 1) / lg;
}

// ---------------------------------------------------------------- cost tables

// CostTableLookup / ConvertCostTableLookup: the first entry matching (isd, dst[, src]); its cost for the kind,
// or -1 when the table has no entry or the entry no cost for that kind.
fn xct(t: i32, isd: i32, dst: i32, src: i32, kind: i64) -> i64 {
    for e in XCT_START[t]..XCT_START[t + 1] {
        if XCE_ISD[e] == isd && XCE_DST[e] == dst && XCE_SRC[e] == src {
            return XCE_COST[e * 4 + kind as i32] as i64;
        }
    }
    return -1;
}
fn xc1(t: i32, isd: i32, m: i32, kind: i64) -> i64 { xct(t, isd, m, 0, kind) }

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
    fatal("TargetTransformInfo: InstructionOpcodeToISD of this opcode is not ported");
    return 0;
}

// ---------------------------------------------------------------- getArithmeticInstrCost

// OperandValueInfo as kind * 4 + properties (see tti.goose OK_* and OP_* property values).
fn oi_kind(i: i64) -> i64 { i / 4 }
fn oi_props(i: i64) -> i64 { i % 4 }
fn oi_is_constant(i: i64) -> bool { let k = oi_kind(i); k == 2 || k == 3 }
fn oi_is_uniform(i: i64) -> bool { let k = oi_kind(i); k == 1 || k == 2 }
fn oi_is_pow2(i: i64) -> bool { oi_props(i) == 1 }
fn oi_is_neg_pow2(i: i64) -> bool { oi_props(i) == 2 }
fn oi_no_props(i: i64) -> i64 { oi_kind(i) * 4 }

fn x86_mul_lt(lt: i64, c: i64) -> i64 { lt * c }

let ARITH_TABLES_UC: i32[0] = [];

// X86TTIImpl::getArithmeticInstrCost. `base` is the TargetTransformInfoImplBase cost the caller computed (the
// BasicTTIImplBase fallback for every cost kind but RecipThroughput).
recursive fn x86_arith_cost(o: i64, ty: i32, kind: i64, op1: i64, op2: i64, nargs: i64, base: i64) -> i64 {
    if o == OP_MUL && ty_is_vector(ty) && ty_bits(ty_scalar(ty)) == 8 && dl_size_bits(ty) <= 64 {
        x86_np("getArithmeticInstrCost of a small vXi8 multiply");
    }
    let ltc, lt = x86_legalize(ty);
    var isd = x86_isd_of_opcode(o);
    if isd == XISD_MUL && nargs == 2 && mvt_is_vec(lt) && (mvt_elt(lt) == XE_I32 || mvt_elt(lt) == XE_I64) {
        x86_np("getArithmeticInstrCost of a vXi32/vXi64 multiply (minRequiredElementSize)");
    }
    if isd == XISD_MUL && oi_is_constant(op2) && (oi_is_pow2(op2) || oi_is_neg_pow2(op2)) {
        var c = x86_arith_cost(OP_SHL, ty, kind, oi_no_props(op1), oi_no_props(op2), 0, base_arith_cost(OP_SHL, ty, kind));
        if oi_is_neg_pow2(op2) { c = c + x86_arith_cost(OP_SUB, ty, kind, 0, 0, 0, base_arith_cost(OP_SUB, ty, kind)); }
        return c;
    }
    if (isd == XISD_SDIV || isd == XISD_SREM) && oi_is_constant(op2) && oi_is_pow2(op2) {
        let p1 = oi_no_props(op1);
        let p2 = oi_no_props(op2);
        var c = 2 * x86_arith_cost(OP_ASHR, ty, kind, p1, p2, 0, base_arith_cost(OP_ASHR, ty, kind));
        c += x86_arith_cost(OP_LSHR, ty, kind, p1, p2, 0, base_arith_cost(OP_LSHR, ty, kind));
        c += x86_arith_cost(OP_ADD, ty, kind, p1, p2, 0, base_arith_cost(OP_ADD, ty, kind));
        if isd == XISD_SREM {
            c += x86_arith_cost(OP_MUL, ty, kind, p1, p2, 0, base_arith_cost(OP_MUL, ty, kind));
            c += x86_arith_cost(OP_SUB, ty, kind, p1, p2, 0, base_arith_cost(OP_SUB, ty, kind));
        }
        return c;
    }
    if (isd == XISD_UDIV || isd == XISD_UREM) && oi_is_constant(op2) && oi_is_pow2(op2) {
        let p1 = oi_no_props(op1);
        let p2 = oi_no_props(op2);
        if isd == XISD_UDIV { return x86_arith_cost(OP_LSHR, ty, kind, p1, p2, 0, base_arith_cost(OP_LSHR, ty, kind)); }
        return x86_arith_cost(OP_AND, ty, kind, p1, p2, 0, base_arith_cost(OP_AND, ty, kind));
    }
    let uc = oi_is_uniform(op2) && oi_is_constant(op2);
    let cst = oi_is_constant(op2);
    let uni = oi_is_uniform(op2);
    let not_xop8 = !x86_xop() || mvt_scalar_bits(lt) != 8;
    var r: i64 = -1;
    if uc && x86_has(X86F_FeatureGFNI) { r = xc1(XCT_A_GFNIUniformConstCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if uc && x86_bwi() { r = xc1(XCT_A_AVX512BWUniformConstCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if uc && x86_dqi() { r = xc1(XCT_A_AVX512DQUniformConstCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if uc && x86_avx512() { r = xc1(XCT_A_AVX512UniformConstCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if uc && x86_avx2() { r = xc1(XCT_A_AVX2UniformConstCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if uc && x86_avx() && not_xop8 { r = xc1(XCT_A_AVXUniformConstCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if uc && x86_sse2() && not_xop8 { r = xc1(XCT_A_SSE2UniformConstCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if cst && x86_bwi() { r = xc1(XCT_A_AVX512BWConstCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if cst && x86_dqi() { r = xc1(XCT_A_AVX512DQConstCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if cst && x86_avx512() { r = xc1(XCT_A_AVX512ConstCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if cst && x86_avx2() { r = xc1(XCT_A_AVX2ConstCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if cst && x86_avx() { r = xc1(XCT_A_AVXConstCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if cst && x86_sse41() { r = xc1(XCT_A_SSE41ConstCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if cst && x86_sse2() { r = xc1(XCT_A_SSE2ConstCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_bwi() && uni { r = xc1(XCT_A_AVX512BWUniformCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_avx512() && uni { r = xc1(XCT_A_AVX512UniformCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_avx2() && uni { r = xc1(XCT_A_AVX2UniformCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_avx() && uni && not_xop8 { r = xc1(XCT_A_AVXUniformCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_sse2() && uni && not_xop8 { r = xc1(XCT_A_SSE2UniformCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_dqi() { r = xc1(XCT_A_AVX512DQCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_bwi() { r = xc1(XCT_A_AVX512BWCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_avx512() { r = xc1(XCT_A_AVX512CostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_avx512() && isd == XISD_SHL && lt == mvt_mk(XE_I16, 32) && cst {
        return x86_arith_cost(OP_MUL, ty, kind, oi_no_props(op1), oi_no_props(op2), 0, base_arith_cost(OP_MUL, ty, kind));
    }
    if x86_avx2() && !(x86_xop() && lt == mvt_mk(XE_I32, 4)) {
        if isd == XISD_SHL && lt == mvt_mk(XE_I16, 16) && cst {
            return x86_arith_cost(OP_MUL, ty, kind, oi_no_props(op1), oi_no_props(op2), 0, base_arith_cost(OP_MUL, ty, kind));
        }
        r = xc1(XCT_A_AVX2ShiftCostTable, isd, lt, kind); if r >= 0 { return ltc * r; }
    }
    if x86_xop() {
        var sisd = isd;
        if (sisd == XISD_SRL || sisd == XISD_SRA) && cst { sisd = XISD_SHL; }
        r = xc1(XCT_A_XOPShiftCostTable, sisd, lt, kind); if r >= 0 { return ltc * r; }
    }
    if isd == XISD_SHL && !uni && cst {
        if ((lt == mvt_mk(XE_I16, 8) || lt == mvt_mk(XE_I32, 4)) && x86_sse2()) ||
           ((lt == mvt_mk(XE_I16, 16) || lt == mvt_mk(XE_I32, 8)) && x86_avx()) { isd = XISD_MUL; }
    }
    if x86_glm_divsqrt() { r = xc1(XCT_A_GLMCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_slm_arith() { r = xc1(XCT_A_SLMCostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_avx2() { r = xc1(XCT_A_AVX2CostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_avx() { r = xc1(XCT_A_AVX1CostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_sse42() { r = xc1(XCT_A_SSE42CostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_sse41() { r = xc1(XCT_A_SSE41CostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_ssse3() { r = xc1(XCT_A_SSSE3CostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_sse2() { r = xc1(XCT_A_SSE2CostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_sse1() { r = xc1(XCT_A_SSE1CostTable, isd, lt, kind); if r >= 0 { return ltc * r; } }
    if x86_is64 { r = xc1(XCT_A_X64CostTbl, isd, lt, kind); if r >= 0 { return ltc * r; } }
    r = xc1(XCT_A_X86CostTbl, isd, lt, kind); if r >= 0 { return ltc * r; }
    if kind == 0 { x86_np("getArithmeticInstrCost for TCK_RecipThroughput"); }
    if kind == 2 {
        if isd == XISD_FADD || isd == XISD_FSUB || isd == XISD_FMUL || isd == XISD_FDIV || isd == XISD_FNEG ||
           isd == XISD_AND || isd == XISD_OR || isd == XISD_XOR { return ltc; }
    }
    return base;
}

// TargetTransformInfoImplBase::getArithmeticInstrCost without the widenable-condition operand check (the
// callers of x86_arith_cost pass the real one; nested queries have no operands).
fn base_arith_cost(o: i64, ty: i32, kind: i64) -> i64 {
    if o == OP_FDIV || o == OP_FREM || o == OP_SDIV || o == OP_SREM || o == OP_UDIV || o == OP_UREM { return 4; }
    if kind == 1 && ty_is_fp(ty_scalar(ty)) { return 3; }
    return 1;
}

// ---------------------------------------------------------------- getCmpSelInstrCost

// (opcode, value type, condition type, predicate (-1 none), kind, the instruction or -1)
recursive fn x86_cmpsel_cost(o: i64, valty: i32, condty: i32, pred0: i64, kind: i64, i: i32) -> i64 {
    let st = ty_scalar(valty);
    if !(ty_is_int(st) || ty_is_fp(st)) { return x86_basic_cmpsel_cost(o, valty, condty, kind); }
    let ltc, lt = x86_legalize(valty);
    let isd = x86_isd_of_opcode(o);
    var extra: i64 = 0;
    if (o == OP_ICMP || o == OP_FCMP) && mvt_is_vec(lt) &&
       !((x86_xop() && (!x86_avx2() || mvt_size_bits(lt) == 128)) || (x86_avx512() && 32 <= mvt_scalar_bits(lt)) || x86_bwi()) {
        x86_np("getCmpSelInstrCost of vector compares (predicate extra cost)");
    }
    var r: i64 = -1;
    if x86_slm_arith() { r = xc1(XCT_S_SLMCostTbl, isd, lt, kind); if r >= 0 { return ltc * (extra + r); } }
    if x86_bwi() { r = xc1(XCT_S_AVX512BWCostTbl, isd, lt, kind); if r >= 0 { return ltc * (extra + r); } }
    if x86_avx512() { r = xc1(XCT_S_AVX512CostTbl, isd, lt, kind); if r >= 0 { return ltc * (extra + r); } }
    if x86_avx2() { r = xc1(XCT_S_AVX2CostTbl, isd, lt, kind); if r >= 0 { return ltc * (extra + r); } }
    if x86_xop() { r = xc1(XCT_S_XOPCostTbl, isd, lt, kind); if r >= 0 { return ltc * (extra + r); } }
    if x86_avx() { r = xc1(XCT_S_AVX1CostTbl, isd, lt, kind); if r >= 0 { return ltc * (extra + r); } }
    if x86_sse42() { r = xc1(XCT_S_SSE42CostTbl, isd, lt, kind); if r >= 0 { return ltc * (extra + r); } }
    if x86_sse41() { r = xc1(XCT_S_SSE41CostTbl, isd, lt, kind); if r >= 0 { return ltc * (extra + r); } }
    if x86_sse2() { r = xc1(XCT_S_SSE2CostTbl, isd, lt, kind); if r >= 0 { return ltc * (extra + r); } }
    if x86_sse1() { r = xc1(XCT_S_SSE1CostTbl, isd, lt, kind); if r >= 0 { return ltc * (extra + r); } }
    if kind == 1 && o == OP_SELECT && ty_is_fp(st) { return 3; }
    return x86_basic_cmpsel_cost(o, valty, condty, kind);
}

// BasicTTIImplBase::getCmpSelInstrCost
fn x86_basic_cmpsel_cost(o: i64, valty: i32, condty: i32, kind: i64) -> i64 {
    if x86_value_type(valty, true) == EVT_OTHER { return 1; }
    var isd = x86_isd_of_opcode(o);
    if isd == XISD_SELECT && condty >= 0 && ty_is_vector(condty) { isd = XISD_VSELECT; }
    let ltc, lt = x86_legalize(valty);
    if !(ty_is_vector(valty) && !mvt_is_vec(lt)) && !x86_op_expand(isd, lt) { return ltc; }
    x86_np("getCmpSelInstrCost of a scalarized vector compare/select");
    return 0;
}

// TLI isOperationExpand for the few (opcode, legal type) pairs the ported cost paths ask about.
fn x86_op_expand(isd: i32, m: i32) -> bool {
    if isd == XISD_SETCC || isd == XISD_SELECT {
        return false;
    }
    if isd == XISD_VSELECT {
        if mvt_elt(m) == XE_I1 { return true; }
        return false;
    }
    x86_np("isOperationExpand for this operation");
    return false;
}

// ---------------------------------------------------------------- getMemoryOpCost

// (opcode, type, the instruction or -1, kind)
fn x86_memory_op_cost(o: i64, ty: i32, i: i32, kind: i64) -> i64 {
    if o == OP_LOAD && kind == 1 {
        // BasicTTIImplBase::getMemoryOpCost
        if x86_value_type(ty, true) == EVT_OTHER { return 4; }
        return 4;
    }
    if kind != 0 {
        if i >= 0 && is_inst_op(i, OP_STORE) {
            let p = op(i, 1);
            if is_inst_op(p, OP_GEP) {
                for k in 1..nops(p) { if !is_constant(op(p, k)) { return 2; } }
            }
        }
        return 1;
    }
    x86_np("getMemoryOpCost for TCK_RecipThroughput");
    return 0;
}

// ---------------------------------------------------------------- getCastInstrCost

// TTI::getCastContextHint: 0 None, 1 Normal (load/store), 2 Masked, 3 GatherScatter
fn x86_cast_context(i: i32) -> i64 {
    if i < 0 || !is_inst(i) { return 0; }
    let o = iop(i);
    if o == OP_ZEXT || o == OP_SEXT || o == OP_FPEXT {
        let s = op(i, 0);
        if !is_inst(s) { return 0; }
        if iop(s) == OP_LOAD { return 1; }
        let id = inst_iid(s);
        if id == IID_masked_load { return 2; }
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
            if id == IID_masked_store { return 2; }
            if id == IID_masked_scatter { return 3; }
        }
        return 0;
    }
    return 0;
}

// X86TTIImpl::getCastInstrCost. `base0` is TargetTransformInfoImplBase::getCastInstrCost (computed by tti.goose).
recursive fn x86_cast_cost(o: i64, dst: i32, src: i32, cch: i64, kind: i64, i: i32, base0: i64) -> i64 {
    let isd = x86_isd_of_opcode(o);
    let sty = x86_value_type(src, false);
    let dty = x86_value_type(dst, false);
    if !x86_avx512() || (!x86_bwi() && evt_elt_bits(evt_elt(dty)) < 32) {
        if i >= 0 && o == OP_SEXT && evt_is_vec(sty) && evt_code(sty) == XE_I1 {
            let c = op(i, 0);
            if is_inst(c) && (iop(c) == OP_ICMP || iop(c) == OP_FCMP) {
                if ty_bits(ty_scalar(vals[op(c, 0)].ty)) == evt_elt_bits(evt_elt(dty)) { return 0; }
            }
        }
    }
    var r: i64 = -1;
    if evt_is_simple(sty) && evt_is_simple(dty) {
        let s = evt_to_mvt(sty);
        let d = evt_to_mvt(dty);
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
        if x86_has(X86F_FeatureF16C) { r = xct(XCT_C_F16ConversionTbl, isd, d, s, kind); if r >= 0 { return r; } }
        if x86_sse41() { r = xct(XCT_C_SSE41ConversionTbl, isd, d, s, kind); if r >= 0 { return r; } }
        if x86_sse2() { r = xct(XCT_C_SSE2ConversionTbl, isd, d, s, kind); if r >= 0 { return r; } }
        if (isd == XISD_FP_ROUND && d == mvt_mk(XE_F16, 0)) || (isd == XISD_FP_EXTEND && s == mvt_mk(XE_F16, 0)) { return 64; }
    }
    let lsc, ls = x86_legalize(src);
    let ldc, ld = x86_legalize(dst);
    if isd == XISD_TRUNCATE && ls == ld { return 0; }
    let mx = if lsc > ldc { lsc } else { ldc };
    if x86_use_avx512_regs() {
        if x86_bwi() { r = xct(XCT_C_AVX512BWConversionTbl, isd, ld, ls, kind); if r >= 0 { return mx * r; } }
        if x86_dqi() { r = xct(XCT_C_AVX512DQConversionTbl, isd, ld, ls, kind); if r >= 0 { return mx * r; } }
        if x86_avx512() { r = xct(XCT_C_AVX512FConversionTbl, isd, ld, ls, kind); if r >= 0 { return mx * r; } }
    }
    if x86_bwi() { r = xct(XCT_C_AVX512BWVLConversionTbl, isd, ld, ls, kind); if r >= 0 { return mx * r; } }
    if x86_dqi() { r = xct(XCT_C_AVX512DQVLConversionTbl, isd, ld, ls, kind); if r >= 0 { return mx * r; } }
    if x86_avx512() { r = xct(XCT_C_AVX512VLConversionTbl, isd, ld, ls, kind); if r >= 0 { return mx * r; } }
    if x86_avx2() { r = xct(XCT_C_AVX2ConversionTbl, isd, ld, ls, kind); if r >= 0 { return mx * r; } }
    if x86_avx() { r = xct(XCT_C_AVXConversionTbl, isd, ld, ls, kind); if r >= 0 { return mx * r; } }
    if x86_has(X86F_FeatureF16C) { r = xct(XCT_C_F16ConversionTbl, isd, ld, ls, kind); if r >= 0 { return mx * r; } }
    if x86_sse41() { r = xct(XCT_C_SSE41ConversionTbl, isd, ld, ls, kind); if r >= 0 { return mx * r; } }
    if x86_sse2() { r = xct(XCT_C_SSE2ConversionTbl, isd, ld, ls, kind); if r >= 0 { return mx * r; } }
    let sb = ty_bits(ty_scalar(src));
    let db = ty_bits(ty_scalar(dst));
    if (isd == XISD_SINT_TO_FP || isd == XISD_UINT_TO_FP) && ty_is_int(ty_scalar(src)) && 1 < sb && sb < 32 {
        x86_np("getCastInstrCost of a small-integer sitofp/uitofp");
    }
    if (isd == XISD_FP_TO_SINT || isd == XISD_FP_TO_UINT) && ty_is_int(ty_scalar(dst)) && 1 < db && db < 32 {
        x86_np("getCastInstrCost of a small-integer fptosi/fptoui");
    }
    let b = x86_basic_cast_cost(o, dst, src, cch, kind, i, base0);
    if kind != 0 { return if b == 0 { 0 } else { 1 }; }
    return b;
}

// BasicTTIImplBase::getCastInstrCost; for cost kinds other than RecipThroughput only whether it is free matters
// (X86's AdjustCost), so every non-free outcome returns 1 there.
fn x86_basic_cast_cost(o: i64, dst: i32, src: i32, cch: i64, kind: i64, i: i32, base0: i64) -> i64 {
    if base0 == 0 { return 0; }
    let lsc, ls = x86_legalize(src);
    let ldc, ld = x86_legalize(dst);
    let ssz = mvt_size_bits(ls);
    let dsz = mvt_size_bits(ld);
    let s_int = ty_is_int(src) || ty_kind(src) == TK_PTR;
    let d_int = ty_is_int(dst) || ty_kind(dst) == TK_PTR;
    var bitcast_check = false;
    if o == OP_TRUNC {
        if !mvt_is_vec(ls) && !mvt_is_vec(ld) && xe_is_int(mvt_elt(ls)) && xe_is_int(mvt_elt(ld)) && ssz > dsz { return 0; }
        bitcast_check = true;
    }
    if o == OP_BITCAST || bitcast_check {
        if lsc == ldc && s_int == d_int && ssz == dsz { return 0; }
    } else if o == OP_ZEXT || o == OP_SEXT {
        if o == OP_ZEXT && ls == mvt_mk(XE_I32, 0) && ld == mvt_mk(XE_I64, 0) && x86_is64 { return 0; }
        if i >= 0 && o == OP_ZEXT && ty_is_int(src) && ty_bits(src) == 32 && ty_is_int(dst) && ty_bits(dst) == 64 && x86_is64 { return 0; }
        if cch == 1 && i >= 0 {
            let l = op(i, 0);
            if is_inst_op(l, OP_LOAD) {
                if ldc == lsc && x86_ext_load_legal(dst, src, o == OP_ZEXT) { return 0; }
            } else if inst_iid(l) == IID_masked_load {
                x86_np("getCastInstrCost of an extended masked load");
            }
        }
    } else if o == OP_FPEXT {
        // isExtFree(I): TargetLoweringBase::isFPExtFree is false for x86
    } else if o == OP_ADDRSPACECAST {
        x86_np("getCastInstrCost of addrspacecast (isFreeAddrSpaceCast)");
    }
    if kind != 0 { return 1; }
    x86_np("getCastInstrCost for TCK_RecipThroughput");
    return 0;
}

// TLI isLoadLegal(ExtVT, LoadVT, ..., ZEXTLOAD/SEXTLOAD): x86 marks extending loads from i1 as Promote; every other
// scalar integer extending load to a legal integer type is Legal.
fn x86_ext_load_legal(dst: i32, src: i32, zext: bool) -> bool {
    let d = x86_value_type(dst, false);
    let s = x86_value_type(src, false);
    if !evt_is_simple(d) || !evt_is_simple(s) { return false; }
    if evt_is_vec(d) || evt_is_vec(s) { x86_np("isLoadLegal for vector extending loads"); }
    if !xe_is_int(evt_code(d)) || !xe_is_int(evt_code(s)) { x86_np("isLoadLegal for floating-point extending loads"); }
    if evt_code(s) == XE_I1 { return false; }
    return x86_mvt_legal(evt_to_mvt(d));
}

// ---------------------------------------------------------------- getIntrinsicInstrCost

// X86TTIImpl::getIntrinsicInstrCost for an intrinsic with argument values (not type-based only).
// `fmf` the call's fast-math flags; `base` TargetTransformInfoImplBase's cost (0 for the generically free ones).
fn x86_intrinsic_cost(id: i32, rt: i32, args: const i32[:], fmf: u8, kind: i64, base: i64) -> i64 {
    var isd: i32 = 0;
    var opty = rt;
    if id == IID_abs { isd = XISD_ABS; }
    else if id == IID_bitreverse { isd = XISD_BITREVERSE; }
    else if id == IID_bswap { isd = XISD_BSWAP; }
    else if id == IID_ctlz { isd = XISD_CTLZ; }
    else if id == IID_ctpop { isd = XISD_CTPOP; }
    else if id == IID_cttz { isd = XISD_CTTZ; }
    else if id == IID_fshl || id == IID_fshr {
        isd = XISD_FSHL;
        if args[0] == args[1] {
            isd = if id == IID_fshl { XISD_ROTL } else { XISD_ROTR };
            let a = args[2];
            if a >= 0 && (vals[a].kind == VK_CINT || (is_constant(a) && splat_value(a, true) >= 0 && vals[splat_value(a, true)].kind == VK_CINT)) {
                isd = XISD_X86_VROTLI;
            }
        }
    }
    else if id == IID_lrint || id == IID_llrint { x86_np("getIntrinsicInstrCost(lrint)"); }
    else if id == IID_maxnum || id == IID_minnum { isd = XISD_FMAXNUM; }
    else if id == IID_sadd_sat { isd = XISD_SADDSAT; }
    else if id == IID_smax { isd = XISD_SMAX; }
    else if id == IID_smin { isd = XISD_SMIN; }
    else if id == IID_ssub_sat { isd = XISD_SSUBSAT; }
    else if id == IID_uadd_sat { isd = XISD_UADDSAT; }
    else if id == IID_umax { isd = XISD_UMAX; }
    else if id == IID_umin { isd = XISD_UMIN; }
    else if id == IID_usub_sat { isd = XISD_USUBSAT; }
    else if id == IID_sqrt { isd = XISD_FSQRT; }
    else if id == IID_sadd_with_overflow || id == IID_ssub_with_overflow { isd = XISD_SADDO; opty = ty_field(rt, 0); }
    else if id == IID_uadd_with_overflow || id == IID_usub_with_overflow { isd = XISD_UADDO; opty = ty_field(rt, 0); }
    else if id == IID_smul_with_overflow { isd = XISD_SMULO; opty = ty_field(rt, 0); }
    else if id == IID_umul_with_overflow { isd = XISD_UMULO; opty = ty_field(rt, 0); }
    if isd != 0 {
        let ltc, lt = x86_legalize(opty);
        if ((isd == XISD_CTTZ && !x86_has(X86F_FeatureBMI)) || (isd == XISD_CTLZ && !x86_has(X86F_FeatureLZCNT))) &&
           !mvt_is_vec(lt) {
            let c = args[1];
            if vals[c].kind == VK_CINT && !ty_is_vector(vals[c].ty) && ap_is_all_ones(ci_ap(c)) {
                isd = if isd == XISD_CTTZ { XISD_CTTZ_ZERO_POISON } else { XISD_CTLZ_ZERO_POISON };
            }
        }
        if isd == XISD_FSQRT && kind == 2 { return ltc; }
        let tabs: i32[26] = [XCT_I_GLMCostTbl, XCT_I_SLMCostTbl, XCT_I_AVX512VBMI2CostTbl, XCT_I_AVX512BITALGCostTbl,
            XCT_I_AVX512VPOPCNTDQCostTbl, XCT_I_GFNICostTbl, XCT_I_AVX512CDCostTbl, XCT_I_AVX512BWCostTbl,
            XCT_I_AVX512CostTbl, XCT_I_XOPCostTbl, XCT_I_AVX2CostTbl, XCT_I_AVX1CostTbl, XCT_I_SSE42CostTbl,
            XCT_I_SSE41CostTbl, XCT_I_SSSE3CostTbl, XCT_I_SSE2CostTbl, XCT_I_SSE1CostTbl, XCT_I_BMI64CostTbl,
            XCT_I_BMI32CostTbl, XCT_I_LZCNT64CostTbl, XCT_I_LZCNT32CostTbl, XCT_I_POPCNT64CostTbl,
            XCT_I_POPCNT32CostTbl, XCT_I_X64CostTbl, XCT_I_X86CostTbl, -1];
        let bmi = x86_has(X86F_FeatureBMI);
        let lzc = x86_has(X86F_FeatureLZCNT);
        let pop = x86_has(X86F_FeaturePOPCNT);
        let on: bool[26] = [x86_glm_divsqrt(), x86_slm_arith(), x86_has(X86F_FeatureVBMI2), x86_has(X86F_FeatureBITALG),
            x86_has(X86F_FeatureVPOPCNTDQ), x86_has(X86F_FeatureGFNI), x86_has(X86F_FeatureCDI), x86_bwi(),
            x86_avx512(), x86_xop(), x86_avx2(), x86_avx(), x86_sse42(), x86_sse41(), x86_ssse3(), x86_sse2(),
            x86_sse1(), bmi && x86_is64, bmi, lzc && x86_is64, lzc, pop && x86_is64, pop, x86_is64, true, false];
        for k in 25 {
            if !on[k] { continue; }
            let r = xc1(tabs[k], isd, lt, kind);
            if r >= 0 {
                // adjustTableCost
                if (isd == XISD_FMAXNUM || isd == XISD_FMINNUM) && (fmf & FMF_NNAN_TTI) != 0 { return ltc; }
                if !mvt_is_vec(lt) && xe_is_int(mvt_elt(lt)) && isd == XISD_BSWAP && x86_has(X86F_FeatureMOVBE) &&
                   x86_has(X86F_TuningFastMOVBE) {
                    x86_np("getIntrinsicInstrCost(bswap) with fast MOVBE");
                }
                return ltc * r;
            }
        }
    }
    // BasicTTIImplBase::getIntrinsicInstrCost
    if base == 0 { return 0; }
    if id > IID_xray_typedevent { return 1; }
    x86_np(str("getIntrinsicInstrCost fallback (BasicTTIImplBase) for intrinsic ", id as i64));
    return 0;
}

let FMF_NNAN_TTI: u8 = 2;

// ---------------------------------------------------------------- getVectorInstrCost

// (opcode, vector type, index (-1 unknown), op0, op1 (insertelement operands or -1), kind)
fn x86_vector_inst_cost(o: i64, vt: i32, index0: i64, op0: i32, op1: i32, kind: i64) -> i64 {
    if ty_kind(vt) == TK_SVEC { return TTI_INVALID_X86; }
    let sty = ty_scalar(vt);
    var rfm: i64 = 0;
    var index = index0;
    if index == -1 {
        x86_np("getVectorInstrCost with a variable index");
    }
    if o == OP_EXTRACTELEMENT && ty_is_int(sty) && ty_bits(sty) == 1 && ty_count(vt) > 1 { return 1; }
    let ltc, lt = x86_legalize(vt);
    if !mvt_is_vec(lt) { return 0; }
    let size = mvt_size_bits(lt);
    let ne = mvt_n(lt);
    var sub = ne;
    index = index % ne;
    if size > 128 {
        let nsub = size / 128;
        sub = ne / nsub;
        if sub <= index {
            rfm += if o == OP_INSERTELEMENT { 2 } else { 1 };
            index = index % sub;
        }
    }
    let ms = mvt_elt(lt);
    let cheap = (ms == XE_I16 && x86_sse2()) || (xe_is_int(ms) && x86_sse41()) ||
                (ms == XE_F32 && x86_sse1() && index == 0 && o == OP_INSERTELEMENT) ||
                (ms == XE_F32 && x86_sse41() && o == OP_INSERTELEMENT);
    if index == 0 {
        if ty_is_fp(sty) && (o != OP_INSERTELEMENT || op0 < 0 || is_undef_or_poison(op0)) { return rfm; }
        if o == OP_INSERTELEMENT && op0 >= 0 && is_undef_or_poison(op0) {
            if op1 >= 0 && is_inst_op(op1, OP_LOAD) { return rfm; }
            if !cheap {
                if op1 >= 0 && is_constant(op1) && ty_is_int(vals[op1].ty) { return 2 + rfm; }
                return 1 + rfm;
            }
        }
        if ty_is_int(sty) && o == OP_EXTRACTELEMENT { return 1 + rfm; }
    }
    if x86_slm_arith() { x86_np("getVectorInstrCost with SLM costs"); }
    if cheap { return 1 + rfm; }
    var shuffle: i64 = 1;
    if o == OP_INSERTELEMENT { x86_np("getVectorInstrCost of insertelement (getShuffleCost)"); }
    let iof: i64 = if ty_is_fp(sty) { 0 } else { 1 };
    return shuffle + iof + rfm;
}

let TTI_INVALID_X86: i64 = 0x4000000000000000;

// ---------------------------------------------------------------- misc queries

// X86TTIImpl::hasConditionalLoadStoreForType
fn x86_has_conditional_load_store_for_type(t: i32) -> bool {
    if !x86_has(X86F_FeatureCF) { return false; }
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
        if !x86_is64 { x86_np("isLegalAddressingMode with a global base on 32-bit x86"); }
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
