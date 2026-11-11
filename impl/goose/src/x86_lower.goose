// The X86 TargetLowering state the cost model reads. Ports
//   llvm/lib/CodeGen/TargetLoweringBase.cpp   (the action tables and their setters, computeRegisterProperties,
//                                              getTypeConversion, getVectorTypeBreakdownMVT, getValueType)
//   llvm/include/llvm/CodeGen/TargetLowering.h (getOperationAction, isOperationLegalOrCustom & co.,
//                                              getLoadAction, getTruncStoreAction, getTypeToPromoteTo)
//   llvm/lib/Target/X86/X86ISelLowering.cpp    (getPreferredVectorAction; the constructor's actions are generated
//                                              into gen_x86lower.goose by tools/gen_x86lower.py)
//
// Value types: an MVT is its MVT::SimpleValueType number (gen_x86target.goose: MVT_v4i32, ...; 0 = invalid).
// An EVT is an i64: an MVT number when simple, else EVT_EXT | ...: an extended integer (EVT_EXT | bits), or an
// extended vector (EVT_EXT | EVT_EXTVEC | count << 24 | element), the element being an MVT number or
// EVT_EXTINT | bits for an extended integer element.
// The tables are built for one subtarget at a time (xl_build, called by x86_subtarget_init when the subtarget
// differs from the last one).
import std;
import gen_x86target;
import gen_x86lower;
import tti_x86;

let LA_LEGAL: i32 = 0;
let LA_PROMOTE: i32 = 1;
let LA_EXPAND: i32 = 2;
let LA_LIBCALL: i32 = 3;
let LA_CUSTOM: i32 = 4;

// LegalizeTypeAction
let TA_LEGAL: i32 = 0;
let TA_PROMOTE: i32 = 1;
let TA_EXPAND: i32 = 2;
let TA_SOFTEN: i32 = 3;
let TA_EXPAND_FLOAT: i32 = 4;
let TA_SCALARIZE: i32 = 5;
let TA_SPLIT: i32 = 6;
let TA_WIDEN: i32 = 7;
let TA_PROMOTE_FLOAT: i32 = 8;
let TA_SOFT_PROMOTE_HALF: i32 = 9;
let TA_SCALARIZE_SCALABLE: i32 = 10;

let XL_OPT_LEVEL = true;

// ---------------------------------------------------------------- MVT queries

fn mvt_bits(m: i32) -> i32 { MVT_SIZE[m] }
fn mvt_nelem(m: i32) -> i32 { MVT_NELEM[m] }
fn mvt_is_int(m: i32) -> bool { (MVT_KIND[m] & 1) != 0 }
fn mvt_is_fp(m: i32) -> bool { (MVT_KIND[m] & 2) != 0 }
fn mvt_is_vec(m: i32) -> bool { (MVT_KIND[m] & 4) != 0 }
fn mvt_is_scalable(m: i32) -> bool { (MVT_KIND[m] & 8) != 0 }
fn mvt_valid(m: i32) -> bool { m != 0 }
fn mvt_elt(m: i32) -> i32 { if mvt_is_vec(m) { MVT_ELT[m] } else { m } }
fn mvt_scalar(m: i32) -> i32 { mvt_elt(m) }
fn mvt_scalar_bits(m: i32) -> i32 { mvt_bits(mvt_elt(m)) }
fn mvt_is128(m: i32) -> bool { mvt_is_vec(m) && mvt_bits(m) == 128 }
fn mvt_is256(m: i32) -> bool { mvt_is_vec(m) && mvt_bits(m) == 256 }
fn mvt_is512(m: i32) -> bool { mvt_is_vec(m) && mvt_bits(m) == 512 }
fn mvt_is_pow2_vec(m: i32) -> bool { let n = mvt_nelem(m); (n & (n - 1)) == 0 }

// MVT::getIntegerVT (0 when there is none)
fn mvt_int(bits: i64) -> i32 {
    for m in MVT_FIRST_INTEGER..MVT_LAST_INTEGER + 1 { if mvt_bits(m) as i64 == bits { return m; } }
    return 0;
}
// MVT::getVectorVT (fixed length; 0 when there is none)
fn mvt_vec(elt: i32, n: i64) -> i32 {
    for m in MVT_FIRST_FIXEDLEN_VECTOR..MVT_LAST_FIXEDLEN_VECTOR + 1 {
        if MVT_ELT[m] == elt && MVT_NELEM[m] as i64 == n { return m; }
    }
    return 0;
}
fn mvt_change_elt_to_int(m: i32) -> i32 {
    let e = mvt_int(mvt_scalar_bits(m));
    if !mvt_is_vec(m) { return e; }
    return mvt_vec(e, mvt_nelem(m));
}
fn next_pow2_u(n: i64) -> i64 { var p: i64 = 1; while p < n { p *= 2; } return p; }
// MVT::getPow2VectorType
fn mvt_pow2_vec(m: i32) -> i32 {
    if mvt_is_pow2_vec(m) { return m; }
    return mvt_vec(mvt_elt(m), next_pow2_u(mvt_nelem(m)));
}

// ---------------------------------------------------------------- EVTs

let EVT_EXT: i64 = 0x4000000000000000;
let EVT_EXTVEC: i64 = 0x2000000000000000;
let EVT_EXTINT: i64 = 0x100000;

fn evt_is_simple(e: i64) -> bool { e < EVT_EXT }
fn evt_mvt(e: i64) -> i32 { if evt_is_simple(e) { e as i32 } else { 0 } }
// EVT::getIntegerVT
fn evt_int(bits: i64) -> i64 {
    let m = mvt_int(bits);
    if m != 0 { return m as i64; }
    return EVT_EXT | bits;
}
// element encoding inside an extended vector
fn evt_elt_code(elt: i64) -> i64 {
    if evt_is_simple(elt) { return elt; }
    return EVT_EXTINT | (elt & 0xfffff);
}
// EVT::getVectorVT
fn evt_vec(elt: i64, n: i64) -> i64 {
    if evt_is_simple(elt) {
        let m = mvt_vec(elt as i32, n);
        if m != 0 { return m as i64; }
    }
    return EVT_EXT | EVT_EXTVEC | (n << 24) | evt_elt_code(elt);
}
fn evt_is_vec(e: i64) -> bool {
    if evt_is_simple(e) { return mvt_is_vec(e as i32); }
    return (e & EVT_EXTVEC) != 0;
}
fn evt_nelem(e: i64) -> i64 {
    if evt_is_simple(e) { return mvt_nelem(e as i32); }
    return (e >> 24) & 0xffffffff;
}
// getVectorElementType (or the scalar itself)
fn evt_elt(e: i64) -> i64 {
    if evt_is_simple(e) { return mvt_elt(e as i32); }
    if (e & EVT_EXTVEC) == 0 { return e; }
    let c = e & 0xffffff;
    if (c & EVT_EXTINT) != 0 { return EVT_EXT | (c & 0xfffff); }
    return c;
}
fn evt_scalar_bits(e: i64) -> i64 {
    let s = evt_elt(e);
    if evt_is_simple(s) { return mvt_bits(s as i32); }
    return s & 0xfffff;
}
fn evt_bits(e: i64) -> i64 {
    if evt_is_simple(e) { return mvt_bits(e as i32); }
    if !evt_is_vec(e) { return e & 0xfffff; }
    return evt_scalar_bits(e) * evt_nelem(e);
}
fn evt_is_int(e: i64) -> bool {
    let s = evt_elt(e);
    if evt_is_simple(s) { return mvt_is_int(s as i32); }
    return true;
}
fn evt_is_fp(e: i64) -> bool {
    let s = evt_elt(e);
    if evt_is_simple(s) { return mvt_is_fp(s as i32); }
    return false;
}
fn evt_is_pow2_vec(e: i64) -> bool { let n = evt_nelem(e); (n & (n - 1)) == 0 }
// EVT::getRoundIntegerType
fn evt_round_int(e: i64) -> i64 {
    let b = evt_bits(e);
    if b <= 8 { return evt_int(8); }
    return evt_int(next_pow2_u(b));
}
fn evt_half_elts(e: i64) -> i64 { evt_vec(evt_elt(e), evt_nelem(e) / 2) }
// EVT::changeTypeToInteger / changeVectorElementTypeToInteger
fn evt_to_int(e: i64) -> i64 {
    if evt_is_vec(e) { return evt_vec(evt_int(evt_scalar_bits(e)), evt_nelem(e)); }
    return evt_int(evt_bits(e));
}

// ---------------------------------------------------------------- the tables

var xl_regclass: bool[>..] = [];
var xl_op: u8[>..] = [];        // [mvt * XISD_BUILTIN_OP_END + op]
var xl_loadext: u16[>..] = [];  // [val * MVT_COUNT + mem], 4 bits per ISD::LoadExtType
var xl_truncst: u8[>..] = [];   // [val * MVT_COUNT + mem]
var xl_ta: u8[>..] = [];        // ValueTypeActions
var xl_transform: i32[>..] = [];
var xl_numregs: i32[>..] = [];
var xl_regtype: i32[>..] = [];
var xl_promote_op: i32[>..] = [];  // PromoteToType: (op, vt) -> to
var xl_promote_vt: i32[>..] = [];
var xl_promote_to: i32[>..] = [];

fn xl_add_reg_class(vt: i32) { xl_regclass[vt] = true; }
fn xl_soa(op: i32, vt: i32, a: i32) { xl_op[vt * XISD_BUILTIN_OP_END + op] = a as u8; }
fn xl_slea(ext: i32, val: i32, mem: i32, a: i32) {
    let k = val * MVT_COUNT + mem;
    let sh = (4 * ext) as u16;
    xl_loadext[k] = (xl_loadext[k] & ~((15 as u16) << sh)) | ((a as u16) << sh);
}
fn xl_stsa(val: i32, mem: i32, a: i32) { xl_truncst[val * MVT_COUNT + mem] = a as u8; }
fn xl_scca(cc: i32, vt: i32, a: i32) { }
// setOperationPromotedToType
fn xl_sopt(op: i32, vt: i32, to: i32) {
    xl_soa(op, vt, LA_PROMOTE);
    for k in xl_promote_op.len {
        if xl_promote_op[k] == op && xl_promote_vt[k] == vt { xl_promote_to[k] = to; return; }
    }
    xl_promote_op.push(op);
    xl_promote_vt.push(vt);
    xl_promote_to.push(to);
}

fn xl_is_type_legal(vt: i32) -> bool { xl_regclass[vt] }
fn xl_op_action_mvt(op: i32, vt: i32) -> i32 {
    if op >= XISD_BUILTIN_OP_END { return LA_CUSTOM; }
    return xl_op[vt * XISD_BUILTIN_OP_END + op] as i32;
}
fn xl_is_op_custom(op: i32, vt: i32) -> bool { xl_op_action_mvt(op, vt) == LA_CUSTOM }
fn xl_is_op_expand(op: i32, vt: i32) -> bool { !xl_is_type_legal(vt) || xl_op_action_mvt(op, vt) == LA_EXPAND }
fn xl_is_op_expand_or_libcall(op: i32, vt: i32) -> bool {
    xl_is_op_expand(op, vt) || xl_op_action_mvt(op, vt) == LA_LIBCALL
}

// ---- TargetLowering queries on EVTs
fn tl_is_type_legal(e: i64) -> bool { evt_is_simple(e) && xl_regclass[e as i32] }
fn tl_op_action(op: i32, e: i64) -> i32 {
    if op >= XISD_BUILTIN_OP_END { return LA_CUSTOM; }
    if !evt_is_simple(e) { return LA_EXPAND; }
    return xl_op[(e as i32) * XISD_BUILTIN_OP_END + op] as i32;
}
fn tl_legal_or_custom(op: i32, e: i64) -> bool {
    let a = tl_op_action(op, e);
    return (e == MVT_Other as i64 || tl_is_type_legal(e)) && (a == LA_LEGAL || a == LA_CUSTOM);
}
fn tl_legal_or_promote(op: i32, e: i64) -> bool {
    let a = tl_op_action(op, e);
    return (e == MVT_Other as i64 || tl_is_type_legal(e)) && (a == LA_LEGAL || a == LA_PROMOTE);
}
fn tl_legal_or_custom_or_promote(op: i32, e: i64) -> bool {
    let a = tl_op_action(op, e);
    return (e == MVT_Other as i64 || tl_is_type_legal(e)) && (a == LA_LEGAL || a == LA_CUSTOM || a == LA_PROMOTE);
}
fn tl_op_custom(op: i32, e: i64) -> bool { tl_op_action(op, e) == LA_CUSTOM }
fn tl_op_expand(op: i32, e: i64) -> bool { !tl_is_type_legal(e) || tl_op_action(op, e) == LA_EXPAND }
fn tl_op_legal(op: i32, e: i64) -> bool {
    return (e == MVT_Other as i64 || tl_is_type_legal(e)) && tl_op_action(op, e) == LA_LEGAL;
}
fn tl_op_expand_or_libcall(op: i32, e: i64) -> bool { tl_op_expand(op, e) || tl_op_action(op, e) == LA_LIBCALL }
// getLoadAction (not atomic; X86 has no custom load actions)
fn tl_load_action(val: i64, mem: i64, ext: i32) -> i32 {
    if !evt_is_simple(val) || !evt_is_simple(mem) { return LA_EXPAND; }
    let w = xl_loadext[(val as i32) * MVT_COUNT + (mem as i32)];
    return ((w >> ((4 * ext) as u16)) & 15) as i32;
}
fn tl_load_legal(val: i64, mem: i64, ext: i32) -> bool { tl_load_action(val, mem, ext) == LA_LEGAL }
fn tl_load_legal_or_custom(val: i64, mem: i64, ext: i32) -> bool {
    let a = tl_load_action(val, mem, ext);
    return a == LA_LEGAL || a == LA_CUSTOM;
}
fn tl_truncstore_action(val: i64, mem: i64) -> i32 {
    if !evt_is_simple(val) || !evt_is_simple(mem) { return LA_EXPAND; }
    return xl_truncst[(val as i32) * MVT_COUNT + (mem as i32)] as i32;
}
fn tl_truncstore_legal(val: i64, mem: i64) -> bool { tl_is_type_legal(val) && tl_truncstore_action(val, mem) == LA_LEGAL }
fn tl_truncstore_legal_or_custom(val: i64, mem: i64) -> bool {
    if !tl_is_type_legal(val) { return false; }
    let a = tl_truncstore_action(val, mem);
    return a == LA_LEGAL || a == LA_CUSTOM;
}
// getTypeToPromoteTo
fn tl_type_to_promote_to(op: i32, vt: i32) -> i32 {
    for k in xl_promote_op.len {
        if xl_promote_op[k] == op && xl_promote_vt[k] == vt { return xl_promote_to[k]; }
    }
    let bits = mvt_scalar_bits(vt);
    var nvt = vt;
    loop {
        nvt += 1;
        if nvt >= MVT_COUNT || mvt_is_int(nvt) != mvt_is_int(vt) || mvt_is_fp(nvt) != mvt_is_fp(vt) {
            fatal("TargetTransformInfo: getTypeToPromoteTo found no type");
        }
        if !(bits >= mvt_scalar_bits(nvt) || !xl_is_type_legal(nvt) || xl_op_action_mvt(op, nvt) == LA_PROMOTE) { break; }
    }
    return nvt;
}

// ---------------------------------------------------------------- building

// X86TargetLowering::getPreferredVectorAction (falls back to TargetLoweringBase's)
fn xl_preferred_vector_action(vt: i32) -> i32 {
    let n = mvt_nelem(vt);
    let e = mvt_elt(vt);
    if (vt == MVT_v32i1 || vt == MVT_v64i1) && x86_avx512() && !xst_hasBWI() { return TA_SPLIT; }
    if !mvt_is_scalable(vt) && n != 1 && n <= 4 && !xst_hasF16C() && e == MVT_f16 { return TA_SPLIT; }
    if !mvt_is_scalable(vt) && n != 1 && e != MVT_i1 { return TA_WIDEN; }
    if n == 1 && !mvt_is_scalable(vt) { return TA_SCALARIZE; }
    if !mvt_is_pow2_vec(vt) { return TA_WIDEN; }
    return TA_PROMOTE;
}

// getRegisterType(MVT)
fn xl_register_type(vt: i32) -> i32 { xl_regtype[vt] }

// getVectorTypeBreakdownMVT: (NumRegisters, RegisterVT)
fn xl_vector_breakdown_mvt(vt: i32) -> i32, i32 {
    var ec = mvt_nelem(vt) as i64;
    let elt = mvt_elt(vt);
    var nregs: i64 = 1;
    if mvt_is_scalable(vt) && (ec & (ec - 1)) != 0 { fatal("TargetTransformInfo: scalable non-power-of-2 MVT"); }
    if (ec & (ec - 1)) != 0 { nregs = ec; ec = 1; }
    while ec > 1 && !xl_is_type_legal(mvt_vec(elt, ec)) {
        ec = ec / 2;
        nregs = nregs << 1;
    }
    var nvt = mvt_vec(elt, ec);
    if ec == 1 && nvt == 0 { nvt = elt; }
    if !xl_is_type_legal(nvt) { nvt = elt; }
    var lane = mvt_scalar_bits(nvt) as i64;
    lane = next_pow2_u(lane);
    let dest = xl_register_type(nvt);
    if mvt_bits(dest) < mvt_bits(nvt) {
        return (nregs * (lane / (mvt_scalar_bits(dest) as i64))) as i32, dest;
    }
    return nregs as i32, dest;
}

// initActions + the X86TargetLowering constructor + computeRegisterProperties, for the current subtarget
fn xl_build() {
    let n = MVT_COUNT;
    xl_regclass.resize(0, false);
    xl_regclass.resize(n, false);
    xl_op.resize(0, 0);
    xl_op.resize(n * XISD_BUILTIN_OP_END, 0);
    xl_loadext.resize(0, 0);
    xl_loadext.resize(n * n, 0);
    xl_truncst.resize(0, 0);
    xl_truncst.resize(n * n, 0);
    xl_promote_op.resize(0, 0);
    xl_promote_vt.resize(0, 0);
    xl_promote_to.resize(0, 0);
    xl_init_actions();
    // initActions: every opcode is Expand for i2 and i4 (the enum_seq loop gen_x86lower.py leaves out)
    for op in XISD_BUILTIN_OP_END {
        xl_op[MVT_i2 * XISD_BUILTIN_OP_END + op] = LA_EXPAND as u8;
        xl_op[MVT_i4 * XISD_BUILTIN_OP_END + op] = LA_EXPAND as u8;
    }
    xl_x86_ctor();
    xl_compute_register_properties();
}

fn xl_compute_register_properties() {
    let n = MVT_COUNT;
    xl_ta.resize(0, 0);
    xl_ta.resize(n, 0);
    xl_transform.resize(0, 0);
    xl_numregs.resize(0, 0);
    xl_regtype.resize(0, 0);
    for i in n { xl_transform.push(i); xl_numregs.push(1); xl_regtype.push(i); }
    xl_numregs[MVT_isVoid] = 0;
    var largest = MVT_LAST_INTEGER;
    while !xl_regclass[largest] { largest -= 1; }
    for r in largest + 1..MVT_LAST_INTEGER + 1 {
        xl_numregs[r] = 2 * xl_numregs[r - 1];
        xl_regtype[r] = largest;
        xl_transform[r] = r - 1;
        xl_ta[r] = TA_EXPAND as u8;
    }
    var legal_int = largest;
    var ir = largest - 1;
    while ir >= MVT_i1 {
        if xl_is_type_legal(ir) { legal_int = ir; }
        else {
            xl_regtype[ir] = legal_int;
            xl_transform[ir] = legal_int;
            xl_ta[ir] = TA_PROMOTE as u8;
        }
        ir -= 1;
    }
    if !xl_is_type_legal(MVT_ppcf128) {
        if xl_is_type_legal(MVT_f64) {
            xl_numregs[MVT_ppcf128] = 2 * xl_numregs[MVT_f64];
            xl_regtype[MVT_ppcf128] = MVT_f64;
            xl_transform[MVT_ppcf128] = MVT_f64;
            xl_ta[MVT_ppcf128] = TA_EXPAND_FLOAT as u8;
        } else {
            xl_numregs[MVT_ppcf128] = xl_numregs[MVT_i128];
            xl_regtype[MVT_ppcf128] = xl_regtype[MVT_i128];
            xl_transform[MVT_ppcf128] = MVT_i128;
            xl_ta[MVT_ppcf128] = TA_SOFTEN as u8;
        }
    }
    if !xl_is_type_legal(MVT_f128) {
        xl_numregs[MVT_f128] = xl_numregs[MVT_i128];
        xl_regtype[MVT_f128] = xl_regtype[MVT_i128];
        xl_transform[MVT_f128] = MVT_i128;
        xl_ta[MVT_f128] = TA_SOFTEN as u8;
    }
    if !xl_is_type_legal(MVT_f80) {
        xl_numregs[MVT_f80] = 3 * xl_numregs[MVT_i32];
        xl_regtype[MVT_f80] = xl_regtype[MVT_i32];
        xl_transform[MVT_f80] = MVT_i32;
        xl_ta[MVT_f80] = TA_SOFTEN as u8;
    }
    if !xl_is_type_legal(MVT_f64) {
        xl_numregs[MVT_f64] = xl_numregs[MVT_i64];
        xl_regtype[MVT_f64] = xl_regtype[MVT_i64];
        xl_transform[MVT_f64] = MVT_i64;
        xl_ta[MVT_f64] = TA_SOFTEN as u8;
    }
    if !xl_is_type_legal(MVT_f32) {
        xl_numregs[MVT_f32] = xl_numregs[MVT_i32];
        xl_regtype[MVT_f32] = xl_regtype[MVT_i32];
        xl_transform[MVT_f32] = MVT_i32;
        xl_ta[MVT_f32] = TA_SOFTEN as u8;
    }
    if !xl_is_type_legal(MVT_f16) {
        // useFPRegsForHalfType() is false for X86
        xl_numregs[MVT_f16] = xl_numregs[MVT_i16];
        xl_regtype[MVT_f16] = xl_regtype[MVT_i16];
        xl_transform[MVT_f16] = MVT_f32;
        xl_ta[MVT_f16] = TA_SOFT_PROMOTE_HALF as u8;
    }
    if !xl_is_type_legal(MVT_bf16) {
        xl_numregs[MVT_bf16] = xl_numregs[MVT_f32];
        xl_regtype[MVT_bf16] = xl_regtype[MVT_f32];
        xl_transform[MVT_bf16] = MVT_f32;
        xl_ta[MVT_bf16] = TA_SOFT_PROMOTE_HALF as u8;
    }
    for i in MVT_FIRST_VECTOR..MVT_LAST_VECTOR + 1 {
        if xl_is_type_legal(i) { continue; }
        let elt = mvt_elt(i);
        let ec = mvt_nelem(i);
        let sc = mvt_is_scalable(i);
        let pref = xl_preferred_vector_action(i);
        var done = false;
        var fall = false;
        if pref == TA_PROMOTE {
            let endvt = if sc { MVT_LAST_INTEGER_SCALABLE_VECTOR } else { MVT_LAST_INTEGER_FIXEDLEN_VECTOR };
            for v in i + 1..endvt + 1 {
                if mvt_scalar_bits(v) > mvt_bits(elt) && mvt_nelem(v) == ec && mvt_is_scalable(v) == sc && xl_is_type_legal(v) {
                    xl_transform[i] = v;
                    xl_regtype[i] = v;
                    xl_numregs[i] = 1;
                    xl_ta[i] = TA_PROMOTE as u8;
                    done = true;
                    break;
                }
            }
            if !done { fall = true; }
        }
        if !done && (pref == TA_WIDEN || fall) {
            fall = true;
            if (ec & (ec - 1)) == 0 {
                for v in i + 1..MVT_LAST_VECTOR + 1 {
                    if mvt_elt(v) == elt && mvt_is_scalable(v) == sc && mvt_nelem(v) > ec && xl_is_type_legal(v) {
                        xl_transform[i] = v;
                        xl_regtype[i] = v;
                        xl_numregs[i] = 1;
                        xl_ta[i] = TA_WIDEN as u8;
                        done = true;
                        break;
                    }
                }
            } else {
                let nv = mvt_pow2_vec(i);
                if nv != 0 && xl_is_type_legal(nv) {
                    xl_transform[i] = nv;
                    xl_ta[i] = TA_WIDEN as u8;
                    xl_regtype[i] = nv;
                    xl_numregs[i] = 1;
                    done = true;
                }
            }
        }
        if !done {
            let nr, rvt = xl_vector_breakdown_mvt(i);
            xl_numregs[i] = nr;
            xl_regtype[i] = rvt;
            let nv = mvt_pow2_vec(i);
            if nv == i {
                xl_transform[i] = MVT_Other;
                if pref == TA_SCALARIZE { xl_ta[i] = TA_SCALARIZE as u8; }
                else if pref == TA_SPLIT { xl_ta[i] = TA_SPLIT as u8; }
                else if ec > 1 { xl_ta[i] = TA_SPLIT as u8; }
                else { xl_ta[i] = (if sc { TA_SCALARIZE_SCALABLE } else { TA_SCALARIZE }) as u8; }
            } else {
                xl_transform[i] = nv;
                xl_ta[i] = TA_WIDEN as u8;
            }
        }
    }
}

// ---------------------------------------------------------------- type conversion

// TargetLoweringBase::getTypeConversion: (action, next type)
recursive fn tl_type_conversion(e: i64) -> i32, i64 {
    if evt_is_simple(e) {
        let s = e as i32;
        let la = xl_ta[s] as i32;
        if la == TA_SPLIT { return la, evt_half_elts(e); }
        if la == TA_SCALARIZE { return la, mvt_elt(s) as i64; }
        return la, xl_transform[s] as i64;
    }
    if !evt_is_vec(e) {
        let b = evt_bits(e);
        if b < 8 || (b & (b - 1)) != 0 {
            let nv = evt_round_int(e);
            let a2, n2 = tl_type_conversion(nv);
            if a2 == TA_PROMOTE { return a2, n2; }
            return TA_PROMOTE, nv;
        }
        return TA_EXPAND, evt_int(b / 2);
    }
    var nelts = evt_nelem(e);
    var elt = evt_elt(e);
    if nelts == 1 { return TA_SCALARIZE, elt; }
    if evt_is_int(elt) {
        if !evt_is_pow2_vec(e) {
            nelts = next_pow2_strict(nelts);
            return TA_WIDEN, evt_vec(elt, nelts);
        }
        let la, ln = tl_type_conversion(elt);
        if la == TA_EXPAND { return TA_SPLIT, evt_half_elts(e); }
        let old = elt;
        loop {
            elt = evt_round_int(evt_int(1 + evt_bits(elt)));
            if !evt_is_simple(elt) { break; }
            let nvt = mvt_vec(elt as i32, nelts);
            if nvt != 0 && xl_ta[nvt] as i32 == TA_LEGAL { return TA_PROMOTE, evt_vec(elt, nelts); }
        }
        elt = old;
    }
    loop {
        nelts = next_pow2_strict(nelts);
        if !evt_is_simple(elt) { break; }
        let lv = mvt_vec(elt as i32, nelts);
        if lv == 0 { break; }
        if xl_ta[lv] as i32 == TA_LEGAL { return TA_WIDEN, lv as i64; }
    }
    if !evt_is_pow2_vec(e) { return TA_WIDEN, evt_vec(evt_elt(e), next_pow2_u(evt_nelem(e))); }
    return TA_SPLIT, evt_vec(evt_elt(e), evt_nelem(e) / 2);
}
// NextPowerOf2: strictly greater
fn next_pow2_strict(n: i64) -> i64 { var p: i64 = 1; while p <= n { p *= 2; } return p; }

fn tl_type_action(e: i64) -> i32 { let a, n = tl_type_conversion(e); return a; }
fn tl_type_to_transform_to(e: i64) -> i64 { let a, n = tl_type_conversion(e); return n; }

// TargetLoweringBase::getNumRegisters(Context, VT) (X86 doesn't override it outside calling conventions)
recursive fn tl_num_registers(e: i64) -> i64 {
    if evt_is_simple(e) { return xl_numregs[e as i32] as i64; }
    if evt_is_vec(e) {
        let n, iv, nint, rv = tl_vector_type_breakdown(e);
        return n;
    }
    if evt_is_int(e) {
        let bits = evt_bits(e);
        let rw = mvt_bits(xl_register_type_evt(e)) as i64;
        return (bits + rw - 1) / rw;
    }
    fatal("TargetTransformInfo: getNumRegisters of an unsupported type");
    return 0;
}

// getRegisterType(Context, VT)
recursive fn xl_register_type_evt(e: i64) -> i32 {
    if evt_is_simple(e) { return xl_regtype[e as i32]; }
    if evt_is_vec(e) {
        let n, iv, nint, rv = tl_vector_type_breakdown(e);
        return rv;
    }
    if evt_is_int(e) { return xl_register_type_evt(tl_type_to_transform_to(e)); }
    fatal("TargetTransformInfo: getRegisterType of an unsupported type");
    return 0;
}

// TargetLoweringBase::getVectorTypeBreakdown (fixed-length): (NumRegs, IntermediateVT, NumIntermediates, RegisterVT)
recursive fn tl_vector_type_breakdown(e: i64) -> i64, i64, i64, i32 {
    let nelts0 = evt_nelem(e);
    let ta = tl_type_action(e);
    if nelts0 != 1 && (ta == TA_WIDEN || ta == TA_PROMOTE) {
        let r = tl_type_to_transform_to(e);
        if tl_is_type_legal(r) { return 1, r, 1, r as i32; }
    }
    let elt = evt_elt(e);
    var nvr: i64 = 1;
    var nelts = nelts0;
    if (nelts & (nelts - 1)) != 0 { nvr = nelts; nelts = 1; }
    while nelts > 1 && !tl_is_type_legal(evt_vec(elt, nelts)) {
        nelts = nelts / 2;
        nvr = nvr << 1;
    }
    var nvt = evt_vec(elt, nelts);
    if !tl_is_type_legal(nvt) { nvt = elt; }
    let dest = xl_register_type_evt(nvt);
    if (mvt_bits(dest) as i64) < evt_bits(nvt) {
        var sz = evt_bits(nvt);
        if (sz & (sz - 1)) != 0 { sz = next_pow2_strict(sz); }
        return nvr * (sz / (mvt_bits(dest) as i64)), nvt, nvr, dest;
    }
    return nvr, nvt, nvr, dest;
}
