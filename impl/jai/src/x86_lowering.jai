// X86TargetLowering legality: the operation / load-ext / trunc-store / cond-code action tables and type
// legalization, for the cost model (and later instruction selection).
// Ports llvm/lib/CodeGen/TargetLoweringBase.cpp (initActions, computeRegisterProperties, getTypeConversion,
// getVectorTypeBreakdownMVT), llvm/include/llvm/CodeGen/TargetLowering.h (getOperationAction,
// isOperationLegalOrCustom & co., getValueType, getTypeAction), and llvm/lib/Target/X86/X86ISelLowering.cpp
// (the constructor's setOperationAction calls are translated by gen/gen_x86_lowering.py into
// gen_x86_lowering.jai; getPreferredVectorAction, isTruncateFree, isZExtFree, isLegalAddressingMode, ... are here).
//
// MVT encoding (shared with the generated tables): element code (MVE_*) | (elements << 8) | (scalable << 30);
// 0 elements = scalar. The MVT *order* (ValueTypes.td) is MVT_ALL; `xl_ord(m)` is a type's position in it.

LA_LEGAL   : u8 : 0;
LA_PROMOTE : u8 : 1;
LA_EXPAND  : u8 : 2;
LA_LIBCALL : u8 : 3;
LA_CUSTOM  : u8 : 4;

// TargetLoweringBase::LegalizeTypeAction
TA_LEGAL :: 0; TA_PROMOTE_INTEGER :: 1; TA_EXPAND_INTEGER :: 2; TA_SOFTEN_FLOAT :: 3; TA_EXPAND_FLOAT :: 4;
TA_SCALARIZE_VECTOR :: 5; TA_SPLIT_VECTOR :: 6; TA_WIDEN_VECTOR :: 7; TA_PROMOTE_FLOAT :: 8;
TA_SOFT_PROMOTE_HALF :: 9; TA_SCALARIZE_SCALABLE_VECTOR :: 10;

MVT_SCALABLE :: 1 << 30;

X86_Lowering :: struct {
    feat: [X86_FEATURE_WORDS] u64;
    triple: string;
    prefer_vector_width: u32 = 0xFFFF_FFFF;
    required_vector_width: u32 = 0xFFFF_FFFF;
    reg_class: [] bool;          // by MVT ordinal: addRegisterClass was called
    op_actions: [] u8;           // [ordinal * ISD_COUNT + isd]
    load_ext: Table(u64, u8);    // (ext, val ord, mem ord)
    trunc_store: Table(u64, u8); // (val ord, mem ord)
    cond_code: Table(u64, u8);   // (cc, ord)
    promote_to: Table(u64, u32); // (isd, ord) -> MVT
    type_action: [] u8;          // by ordinal
    transform_to: [] u32;        // by ordinal: MVT
    num_registers: [] u32;
    register_type: [] u32;
}

// ---------------------------------------------------------------- MVTs

xl_ord_table: Table(u32, s32);
xl_ord :: (m: u32) -> s32 {
    if xl_ord_table.count == 0 {
        for MVT_ALL table_set(*xl_ord_table, it, cast(s32) it_index);
    }
    found, k := table_find(*xl_ord_table, m);
    if !found return -1;
    return k;
}
mvt_valid :: (m: u32) -> bool { return m != 0 && xl_ord(m) >= 0; }
mvt_elt_code :: inline (m: u32) -> u32 { return m & 0xFF; }
mvt_n :: inline (m: u32) -> u32 { return (m >> 8) & 0x3F_FFFF; }
mvt_is_vec :: inline (m: u32) -> bool { return mvt_n(m) != 0; }
mvt_is_scalable :: inline (m: u32) -> bool { return (m & MVT_SCALABLE) != 0; }
mvt_elt :: inline (m: u32) -> u32 { return mvt_elt_code(m); }
mvt_scalar :: inline (m: u32) -> u32 { return mvt_elt_code(m); }
mve_bits :: (e: u32) -> u32 {
    if e == {
        case MVE_I1; return 1; case MVE_I2; return 2; case MVE_I4; return 4; case MVE_I8; return 8;
        case MVE_I16; return 16; case MVE_I32; return 32; case MVE_I64; return 64; case MVE_I128; return 128;
        case MVE_F16; return 16; case MVE_BF16; return 16; case MVE_F32; return 32; case MVE_F64; return 64;
        case MVE_F80; return 80; case MVE_F128; return 128;
    }
    if e == MVT_i256 return 256;
    if e == MVT_i512 return 512;
    if e == MVT_ppcf128 return 128;
    if e == MVT_x86amx return 8192;
    return 0;
}
mvt_scalar_bits :: (m: u32) -> u32 { return mve_bits(mvt_elt_code(m)); }
mvt_bits :: (m: u32) -> u32 { n := mvt_n(m); return mvt_scalar_bits(m) * ifx n == 0 then cast(u32) 1 else n; }
mve_is_int :: (e: u32) -> bool { return (e >= MVE_I1 && e <= MVE_I128) || e == MVT_i256 || e == MVT_i512; }
mve_is_fp :: (e: u32) -> bool { return (e >= MVE_F16 && e <= MVE_F128) || e == MVT_ppcf128; }
mvt_is_int :: (m: u32) -> bool { return mve_is_int(mvt_elt_code(m)); }
mvt_is_fp :: (m: u32) -> bool { return mve_is_fp(mvt_elt_code(m)); }
// MVT::getIntegerVT (0 = invalid)
mvt_int :: (bits: u32) -> u32 {
    if bits == {
        case 1; return MVT_i1; case 2; return MVT_i2; case 4; return MVT_i4; case 8; return MVT_i8;
        case 16; return MVT_i16; case 32; return MVT_i32; case 64; return MVT_i64; case 128; return MVT_i128;
        case 256; return MVT_i256; case 512; return MVT_i512;
    }
    return 0;
}
// MVT::getVectorVT (0 = invalid)
mvt_vec :: (elt: u32, n: u32, scalable := false) -> u32 {
    m := (elt & 0xFF) | (n << 8) | (ifx scalable then cast(u32) MVT_SCALABLE else 0);
    if xl_ord(m) < 0 return 0;
    return m;
}
mvt_list :: (pred: (m: u32) -> bool) -> [] u32 {
    out: [..] u32; out.allocator = temp;
    for MVT_ALL if pred(it) array_add(*out, it);
    return out;
}
mvt_is_special :: (m: u32) -> bool {
    e := mvt_elt_code(m);
    return !mve_is_int(e) && !mve_is_fp(e);
}
mvt_all_valuetypes :: () -> [] u32 { return mvt_list((m: u32) -> bool { return m != MVT_Other && m != MVT_isVoid && m != MVT_Glue && m != MVT_Untyped && m != MVT_token && m != MVT_iPTR; }); }
mvt_fp_valuetypes :: () -> [] u32 { return mvt_list((m: u32) -> bool { return !mvt_is_vec(m) && mve_is_fp(mvt_elt_code(m)); }); }
mvt_integer_valuetypes :: () -> [] u32 { return mvt_list((m: u32) -> bool { return !mvt_is_vec(m) && mve_is_int(mvt_elt_code(m)); }); }
mvt_fixedlen_vector_valuetypes :: () -> [] u32 { return mvt_list((m: u32) -> bool { return mvt_is_vec(m) && !mvt_is_scalable(m); }); }
mvt_integer_fixedlen_vector_valuetypes :: () -> [] u32 { return mvt_list((m: u32) -> bool { return mvt_is_vec(m) && !mvt_is_scalable(m) && mvt_is_int(m); }); }
mvt_fp_fixedlen_vector_valuetypes :: () -> [] u32 { return mvt_list((m: u32) -> bool { return mvt_is_vec(m) && !mvt_is_scalable(m) && mvt_is_fp(m); }); }
mvt_vector_valuetypes :: () -> [] u32 { return mvt_list((m: u32) -> bool { return mvt_is_vec(m); }); }
mvt_scalable_vector_valuetypes :: () -> [] u32 { return mvt_list((m: u32) -> bool { return mvt_is_vec(m) && mvt_is_scalable(m); }); }
// MVT::getPow2VectorType
mvt_pow2_vector :: (m: u32) -> u32 {
    n := mvt_n(m);
    if (n & (n - 1)) == 0 return m;
    p: u32 = 1;
    while p < n p *= 2;
    return mvt_vec(mvt_elt_code(m), p, mvt_is_scalable(m));
}

// ---------------------------------------------------------------- subtarget predicates (X86Subtarget.h)

xs_has :: inline (st: *X86_Lowering, f: s64) -> bool { return (st.feat[f / 64] >> cast(u64) (f % 64)) & 1 != 0; }
st_is64Bit :: (st: *X86_Lowering) -> bool { return xs_has(st, X86F_Is64Bit); }
st_is32Bit :: (st: *X86_Lowering) -> bool { return xs_has(st, X86F_Is32Bit); }
st_hasSSE1 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86F_FeatureSSE1); }
st_hasSSE2 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86F_FeatureSSE2); }
st_hasSSE3 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86F_FeatureSSE3); }
st_hasSSSE3 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86F_FeatureSSSE3); }
st_hasSSE41 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86F_FeatureSSE41); }
st_hasSSE42 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86F_FeatureSSE42); }
st_hasAVX :: (st: *X86_Lowering) -> bool { return xs_has(st, X86F_FeatureAVX); }
st_hasAVX2 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86F_FeatureAVX2); }
st_hasInt256 :: (st: *X86_Lowering) -> bool { return st_hasAVX2(st); }
st_hasAVX512 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86F_FeatureAVX512); }
st_hasAnyFMA :: (st: *X86_Lowering) -> bool { return xs_has(st, X86F_FeatureFMA) || xs_has(st, X86F_FeatureFMA4); }
st_hasFMA :: (st: *X86_Lowering) -> bool { return xs_has(st, X86F_FeatureFMA); }
st_hasFMA4 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86F_FeatureFMA4); }
st_hasX87 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasX87); }
st_hasCMOV :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasCMOV); }
st_canUseCMOV :: (st: *X86_Lowering) -> bool { return st_hasCMOV(st) || st_hasSSE1(st) || st_is64Bit(st); }
st_canUseCMPXCHG8B :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasCX8); }
st_canUseCMPXCHG16B :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasCX16) && st_is64Bit(st); }
st_hasAMXTILE :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasAMXTILE); }
st_hasAVX10_2 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasAVX10_2); }
st_hasAVXNECONVERT :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasAVXNECONVERT); }
st_hasBF16 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasBF16); }
st_hasBITALG :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasBITALG); }
st_hasBMI :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasBMI); }
st_hasBMI2 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasBMI2); }
st_hasBMM :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasBMM); }
st_hasBWI :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasBWI); }
st_hasCDI :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasCDI); }
st_hasDQI :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasDQI); }
st_hasF16C :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasF16C); }
st_hasFP16 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasFP16); }
st_hasGFNI :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasGFNI); }
st_hasLZCNT :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasLZCNT); }
st_hasMMX :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasMMX); }
st_hasMOVBE :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasMOVBE); }
st_hasPCLMUL :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasPCLMUL); }
st_hasPOPCNT :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasPOPCNT); }
st_hasPRFCHW :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasPRFCHW); }
st_hasPREFETCHI :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasPREFETCHI); }
st_hasSSEPrefetch :: (st: *X86_Lowering) -> bool { return st_hasSSE1(st) || st_hasPRFCHW(st) || st_hasPREFETCHI(st); }
st_hasSlowDivide32 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasSlowDivide32); }
st_hasSlowDivide64 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasSlowDivide64); }
st_hasVBMI :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasVBMI); }
st_hasVBMI2 :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasVBMI2); }
st_hasVLX :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasVLX); }
st_hasVPOPCNTDQ :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasVPOPCNTDQ); }
st_hasXOP :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasXOP); }
st_hasCF :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasCF); }
st_hasEGPR :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasEGPR); }
st_hasSSE4A :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasSSE4A); }
st_hasVNNI :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasVNNI); }
st_isAtom :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_IsAtom); }
st_isSHLDSlow :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_IsSHLDSlow); }
st_useSoftFloat :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_UseSoftFloat); }
st_isPMADDWDSlow :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_IsPMADDWDSlow); }
st_useSLMArithCosts :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_UseSLMArithCosts); }
st_useGLMDivSqrtCosts :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_UseGLMDivSqrtCosts); }
st_hasFastBEXTR :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasFastBEXTR); }
st_hasFastScalarFSQRT :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasFastScalarFSQRT); }
st_hasFastVectorFSQRT :: (st: *X86_Lowering) -> bool { return xs_has(st, X86FLD_HasFastVectorFSQRT); }
st_getPreferVectorWidth :: (st: *X86_Lowering) -> u32 { return st.prefer_vector_width; }
st_canExtendTo512DQ :: (st: *X86_Lowering) -> bool { return st_hasAVX512(st) && (!st_hasVLX(st) || st.prefer_vector_width >= 512); }
st_canExtendTo512BW :: (st: *X86_Lowering) -> bool { return st_hasBWI(st) && st_canExtendTo512DQ(st); }
st_useAVX512Regs :: (st: *X86_Lowering) -> bool { return st_hasAVX512(st) && (st_canExtendTo512DQ(st) || st.required_vector_width > 256); }
st_useBWIRegs :: (st: *X86_Lowering) -> bool { return st_hasBWI(st) && st_useAVX512Regs(st); }
st_ptr_bits :: (st: *X86_Lowering) -> u32 { return ifx st_is64Bit(st) && !begins_with(st.triple, "x86_64-unknown-linux-gnux32") then cast(u32) 64 else 32; }
// Triple predicates (Triple.h)
st_os :: (st: *X86_Lowering) -> string {
    parts := split(st.triple, "-",, allocator = temp);
    if parts.count >= 3 return parts[2];
    return "";
}
st_env :: (st: *X86_Lowering) -> string {
    parts := split(st.triple, "-",, allocator = temp);
    if parts.count >= 4 return parts[3];
    return "";
}
st_isOSWindows :: (st: *X86_Lowering) -> bool { return begins_with(st_os(st), "windows") || begins_with(st_os(st), "win32"); }
st_isTargetWin64 :: (st: *X86_Lowering) -> bool { return st_is64Bit(st) && st_isOSWindows(st); }
st_isTargetWindowsMSVC :: (st: *X86_Lowering) -> bool { e := st_env(st); return st_isOSWindows(st) && (e == "" || begins_with(e, "msvc")); }
st_isTargetWindowsItanium :: (st: *X86_Lowering) -> bool { return st_isOSWindows(st) && begins_with(st_env(st), "itanium"); }
st_isTargetCygMing :: (st: *X86_Lowering) -> bool { e := st_env(st); return st_isOSWindows(st) && (begins_with(e, "gnu") || begins_with(e, "cygnus")); }
st_isTargetDarwin :: (st: *X86_Lowering) -> bool { o := st_os(st); return begins_with(o, "darwin") || begins_with(o, "macos") || begins_with(o, "ios") || begins_with(o, "tvos") || begins_with(o, "watchos"); }
st_isTargetELF :: (st: *X86_Lowering) -> bool { return !st_isOSWindows(st) && !st_isTargetDarwin(st); }
st_isTargetPS :: (st: *X86_Lowering) -> bool { o := st_os(st); return begins_with(o, "ps4") || begins_with(o, "ps5"); }

// ---------------------------------------------------------------- setters (TargetLoweringBase.h)

xl_op_index :: inline (st: *X86_Lowering, isd: u32, vt: u32) -> s64 {
    o := xl_ord(vt);
    assert(o >= 0, "unknown MVT");
    return cast(s64) o * ISD_COUNT + isd;
}
soa :: (st: *X86_Lowering, isd: u32, vt: u32, a: u8) { st.op_actions[xl_op_index(st, isd, vt)] = a; }
soa :: (st: *X86_Lowering, isds: [] u32, vt: u32, a: u8) { for isds soa(st, it, vt, a); }
soa :: (st: *X86_Lowering, isd: u32, vts: [] u32, a: u8) { for vts soa(st, isd, it, a); }
soa :: (st: *X86_Lowering, isds: [] u32, vts: [] u32, a: u8) { for i: isds for v: vts soa(st, i, v, a); }
// setOperationPromotedToType: Promote + AddPromotedToType
sopt :: (st: *X86_Lowering, isd: u32, vt: u32, to: u32) {
    soa(st, isd, vt, LA_PROMOTE);
    table_set(*st.promote_to, (cast(u64) isd << 32) | cast(u64) xl_ord(vt), to);
}
sopt :: (st: *X86_Lowering, isds: [] u32, vt: u32, to: u32) { for isds sopt(st, it, vt, to); }
slea :: (st: *X86_Lowering, ext: u32, val: u32, mem: u32, a: u8) {
    table_set(*st.load_ext, (cast(u64) ext << 40) | (cast(u64) xl_ord(val) << 20) | cast(u64) xl_ord(mem), a);
}
slea :: (st: *X86_Lowering, exts: [] u32, val: u32, mem: u32, a: u8) { for exts slea(st, it, val, mem, a); }
slea :: (st: *X86_Lowering, exts: [] u32, val: u32, mems: [] u32, a: u8) { for e: exts for m: mems slea(st, e, val, m, a); }
slea :: (st: *X86_Lowering, ext: u32, val: u32, mems: [] u32, a: u8) { for mems slea(st, ext, val, it, a); }
stsa :: (st: *X86_Lowering, val: u32, mem: u32, a: u8) {
    table_set(*st.trunc_store, (cast(u64) xl_ord(val) << 20) | cast(u64) xl_ord(mem), a);
}
scca :: (st: *X86_Lowering, cc: u32, vt: u32, a: u8) { table_set(*st.cond_code, (cast(u64) cc << 32) | cast(u64) xl_ord(vt), a); }
scca :: (st: *X86_Lowering, ccs: [] u32, vt: u32, a: u8) { for ccs scca(st, it, vt, a); }
add_reg_class :: (st: *X86_Lowering, vt: u32) { st.reg_class[xl_ord(vt)] = true; }

// ---------------------------------------------------------------- queries

// isTypeLegal(MVT): a register class exists (after computeRegisterProperties RegClassForVT is unchanged)
is_type_legal_mvt :: (st: *X86_Lowering, vt: u32) -> bool {
    o := xl_ord(vt);
    if o < 0 return false;
    return st.reg_class[o];
}
// TargetLoweringBase::getOperationAction(Op, VT) for a simple VT
xl_op_action :: (st: *X86_Lowering, isd: u32, vt: u32) -> u8 {
    if isd_is_target(isd) return LA_CUSTOM;   // target-specific (X86ISD) opcodes
    if vt == MVT_i2 || vt == MVT_i4 return LA_EXPAND;   // initActions: every opcode on i2/i4
    return st.op_actions[xl_op_index(st, isd, vt)];
}
is_op_legal_or_custom_or_promote :: (st: *X86_Lowering, isd: u32, vt: u32) -> bool {
    a := xl_op_action(st, isd, vt);
    return (vt == MVT_Other || is_type_legal_mvt(st, vt)) && (a == LA_LEGAL || a == LA_CUSTOM || a == LA_PROMOTE);
}
is_op_legal_or_promote :: (st: *X86_Lowering, isd: u32, vt: u32) -> bool {
    a := xl_op_action(st, isd, vt);
    return (vt == MVT_Other || is_type_legal_mvt(st, vt)) && (a == LA_LEGAL || a == LA_PROMOTE);
}
is_op_legal_or_custom :: (st: *X86_Lowering, isd: u32, vt: u32) -> bool {
    a := xl_op_action(st, isd, vt);
    return (vt == MVT_Other || is_type_legal_mvt(st, vt)) && (a == LA_LEGAL || a == LA_CUSTOM);
}
is_op_legal :: (st: *X86_Lowering, isd: u32, vt: u32) -> bool {
    return (vt == MVT_Other || is_type_legal_mvt(st, vt)) && xl_op_action(st, isd, vt) == LA_LEGAL;
}
is_op_custom :: (st: *X86_Lowering, isd: u32, vt: u32) -> bool {
    return (vt == MVT_Other || is_type_legal_mvt(st, vt)) && xl_op_action(st, isd, vt) == LA_CUSTOM;
}
is_op_expand :: (st: *X86_Lowering, isd: u32, vt: u32) -> bool {
    return !is_type_legal_mvt(st, vt) || xl_op_action(st, isd, vt) == LA_EXPAND;
}
is_op_expand_or_libcall :: (st: *X86_Lowering, isd: u32, vt: u32) -> bool {
    a := xl_op_action(st, isd, vt);
    return a == LA_EXPAND || a == LA_LIBCALL;
}
xl_load_ext_action :: (st: *X86_Lowering, ext: u32, val: u32, mem: u32) -> u8 {
    found, a := table_find(*st.load_ext, (cast(u64) ext << 40) | (cast(u64) xl_ord(val) << 20) | cast(u64) xl_ord(mem));
    return ifx found then a else LA_LEGAL;
}
xl_trunc_store_action :: (st: *X86_Lowering, val: u32, mem: u32) -> u8 {
    found, a := table_find(*st.trunc_store, (cast(u64) xl_ord(val) << 20) | cast(u64) xl_ord(mem));
    return ifx found then a else LA_LEGAL;
}

// ---------------------------------------------------------------- X86TargetLowering::getPreferredVectorAction

x86_preferred_vector_action :: (st: *X86_Lowering, vt: u32) -> s64 {
    if (vt == MVT_v32i1 || vt == MVT_v64i1) && st_hasAVX512(st) && !st_hasBWI(st) return TA_SPLIT_VECTOR;
    n := mvt_n(vt);
    if !mvt_is_scalable(vt) && n != 1 && n <= 4 && !st_hasF16C(st) && mvt_elt_code(vt) == MVE_F16 return TA_SPLIT_VECTOR;
    if !mvt_is_scalable(vt) && n != 1 && mvt_elt_code(vt) != MVE_I1 return TA_WIDEN_VECTOR;
    // TargetLoweringBase::getPreferredVectorAction (ElementCount::isScalar: one element, not scalable)
    if n == 1 && !mvt_is_scalable(vt) return TA_SCALARIZE_VECTOR;
    if (n & (n - 1)) != 0 return TA_WIDEN_VECTOR;
    return TA_PROMOTE_INTEGER;
}

// ---------------------------------------------------------------- TargetLoweringBase::computeRegisterProperties

xl_compute_register_properties :: (st: *X86_Lowering) {
    N := MVT_ALL.count;
    for i: 0..N-1 {
        st.num_registers[i] = 1;
        st.register_type[i] = MVT_ALL[i];
        st.transform_to[i] = MVT_ALL[i];
        st.type_action[i] = TA_LEGAL;
    }
    st.num_registers[xl_ord(MVT_isVoid)] = 0;
    ints := mvt_integer_valuetypes();     // i1 .. LAST_INTEGER_VALUETYPE, in MVT order
    largest := ints.count - 1;
    while !st.reg_class[xl_ord(ints[largest])] largest -= 1;
    for k: largest + 1..ints.count - 1 {
        o := xl_ord(ints[k]);
        st.num_registers[o] = 2 * st.num_registers[xl_ord(ints[k - 1])];
        st.register_type[o] = ints[largest];
        st.transform_to[o] = ints[k - 1];
        st.type_action[o] = TA_EXPAND_INTEGER;
    }
    legal_int := largest;
    k := largest - 1;
    while k >= 0 {
        o := xl_ord(ints[k]);
        if st.reg_class[o] legal_int = k;
        else {
            st.register_type[o] = ints[legal_int];
            st.transform_to[o] = ints[legal_int];
            st.type_action[o] = TA_PROMOTE_INTEGER;
        }
        k -= 1;
    }
    set :: (st: *X86_Lowering, vt: u32, nregs: u32, reg: u32, to: u32, a: s64) {
        o := xl_ord(vt);
        st.num_registers[o] = nregs; st.register_type[o] = reg; st.transform_to[o] = to; st.type_action[o] = cast(u8) a;
    }
    oi :: (st: *X86_Lowering, vt: u32) -> s32 { return xl_ord(vt); }
    if !is_type_legal_mvt(st, MVT_ppcf128) {
        if is_type_legal_mvt(st, MVT_f64)
            set(st, MVT_ppcf128, 2 * st.num_registers[oi(st, MVT_f64)], MVT_f64, MVT_f64, TA_EXPAND_FLOAT);
        else
            set(st, MVT_ppcf128, st.num_registers[oi(st, MVT_i128)], st.register_type[oi(st, MVT_i128)], MVT_i128, TA_SOFTEN_FLOAT);
    }
    if !is_type_legal_mvt(st, MVT_f128)
        set(st, MVT_f128, st.num_registers[oi(st, MVT_i128)], st.register_type[oi(st, MVT_i128)], MVT_i128, TA_SOFTEN_FLOAT);
    if !is_type_legal_mvt(st, MVT_f80)
        set(st, MVT_f80, 3 * st.num_registers[oi(st, MVT_i32)], st.register_type[oi(st, MVT_i32)], MVT_i32, TA_SOFTEN_FLOAT);
    if !is_type_legal_mvt(st, MVT_f64)
        set(st, MVT_f64, st.num_registers[oi(st, MVT_i64)], st.register_type[oi(st, MVT_i64)], MVT_i64, TA_SOFTEN_FLOAT);
    if !is_type_legal_mvt(st, MVT_f32)
        set(st, MVT_f32, st.num_registers[oi(st, MVT_i32)], st.register_type[oi(st, MVT_i32)], MVT_i32, TA_SOFTEN_FLOAT);
    if !is_type_legal_mvt(st, MVT_f16)   // X86: useFPRegsForHalfType() is true
        set(st, MVT_f16, st.num_registers[oi(st, MVT_f32)], st.register_type[oi(st, MVT_f32)], MVT_f32, TA_SOFT_PROMOTE_HALF);
    if !is_type_legal_mvt(st, MVT_bf16)
        set(st, MVT_bf16, st.num_registers[oi(st, MVT_f32)], st.register_type[oi(st, MVT_f32)], MVT_f32, TA_SOFT_PROMOTE_HALF);

    for i: 0..N-1 {
        vt := MVT_ALL[i];
        if !mvt_is_vec(vt) || is_type_legal_mvt(st, vt) continue;
        elt := mvt_elt_code(vt);
        n := mvt_n(vt);
        scal := mvt_is_scalable(vt);
        pref := x86_preferred_vector_action(st, vt);
        done := false;
        if pref == TA_PROMOTE_INTEGER {
            for j: i + 1..N-1 {
                svt := MVT_ALL[j];
                if !mvt_is_vec(svt) || !mvt_is_int(svt) || mvt_is_scalable(svt) != scal continue;
                if mvt_scalar_bits(svt) > mve_bits(elt) && mvt_n(svt) == n && is_type_legal_mvt(st, svt) {
                    set(st, vt, 1, svt, svt, TA_PROMOTE_INTEGER);
                    done = true;
                    break;
                }
            }
        }
        if !done && (pref == TA_PROMOTE_INTEGER || pref == TA_WIDEN_VECTOR) {
            if (n & (n - 1)) == 0 {
                for j: i + 1..N-1 {
                    svt := MVT_ALL[j];
                    if !mvt_is_vec(svt) continue;
                    if mvt_elt_code(svt) == elt && mvt_is_scalable(svt) == scal && mvt_n(svt) > n && is_type_legal_mvt(st, svt) {
                        set(st, vt, 1, svt, svt, TA_WIDEN_VECTOR);
                        done = true;
                        break;
                    }
                }
            } else {
                nvt := mvt_pow2_vector(vt);
                if is_type_legal_mvt(st, nvt) {
                    set(st, vt, 1, nvt, nvt, TA_WIDEN_VECTOR);
                    done = true;
                }
            }
        }
        if !done {
            nregs, regvt := xl_vector_type_breakdown_mvt(st, vt);
            st.num_registers[i] = nregs;
            st.register_type[i] = regvt;
            nvt := mvt_pow2_vector(vt);
            if nvt == vt {
                st.transform_to[i] = MVT_Other;
                if pref == TA_SCALARIZE_VECTOR st.type_action[i] = TA_SCALARIZE_VECTOR;
                else if pref == TA_SPLIT_VECTOR st.type_action[i] = TA_SPLIT_VECTOR;
                else if n > 1 st.type_action[i] = TA_SPLIT_VECTOR;
                else st.type_action[i] = cast(u8) ifx scal then TA_SCALARIZE_SCALABLE_VECTOR else TA_SCALARIZE_VECTOR;
            } else {
                st.transform_to[i] = nvt;
                st.type_action[i] = TA_WIDEN_VECTOR;
            }
        }
    }
}

// getVectorTypeBreakdownMVT: (NumRegisters, RegisterVT)
xl_vector_type_breakdown_mvt :: (st: *X86_Lowering, vt: u32) -> (u32, u32) {
    ec := mvt_n(vt);
    elt := mvt_elt_code(vt);
    scal := mvt_is_scalable(vt);
    nregs: u32 = 1;
    if (ec & (ec - 1)) != 0 { nregs = ec; ec = 1; }
    while ec > 1 && !is_type_legal_mvt(st, mvt_vec(elt, ec, scal)) { ec /= 2; nregs <<= 1; }
    nvt := mvt_vec(elt, ec, scal);
    if !is_type_legal_mvt(st, nvt) nvt = elt;
    lane := mvt_scalar_bits(nvt);
    p: u32 = 1; while p < lane p *= 2; lane = p;
    dest := st.register_type[xl_ord(nvt)];
    if mvt_bits(dest) < mvt_bits(nvt) return nregs * (lane / mvt_scalar_bits(dest)), dest;
    return nregs, dest;
}

// ---------------------------------------------------------------- EVTs and getTypeConversion

// EVT: a simple MVT (m != 0), an extended integer (m == 0, n == 0, ebits), or an extended vector of n elements
// whose element is the simple em or (em == 0) an extended integer of ebits.
Evt :: struct { m: u32; em: u32; ebits: u32; n: u32; scalable: bool; }
evt_simple :: (m: u32) -> Evt { e: Evt; e.m = m; return e; }
evt_is_simple :: inline (e: Evt) -> bool { return e.m != 0; }
evt_is_vector :: (e: Evt) -> bool { return ifx e.m != 0 then mvt_is_vec(e.m) else e.n != 0; }
evt_eq :: (a: Evt, b: Evt) -> bool { return a.m == b.m && a.em == b.em && a.ebits == b.ebits && a.n == b.n && a.scalable == b.scalable; }
evt_int :: (bits: u32) -> Evt {
    m := mvt_int(bits);
    if m != 0 return evt_simple(m);
    e: Evt; e.ebits = bits; return e;
}
evt_vec :: (elt: Evt, n: u32, scalable: bool) -> Evt {
    if elt.m != 0 {
        m := mvt_vec(elt.m, n, scalable);
        if m != 0 return evt_simple(m);
    }
    e: Evt; e.em = elt.m; e.ebits = ifx elt.m != 0 then mve_bits(elt.m) else elt.ebits; e.n = n; e.scalable = scalable;
    return e;
}
evt_elt :: (e: Evt) -> Evt {
    if e.m != 0 return evt_simple(mvt_elt_code(e.m));
    if e.em != 0 return evt_simple(e.em);
    return evt_int(e.ebits);
}
evt_n :: (e: Evt) -> u32 { return ifx e.m != 0 then mvt_n(e.m) else e.n; }
evt_scalable :: (e: Evt) -> bool { return ifx e.m != 0 then mvt_is_scalable(e.m) else e.scalable; }
evt_scalar_bits :: (e: Evt) -> u32 { return ifx e.m != 0 then mvt_scalar_bits(e.m) else e.ebits; }
evt_bits :: (e: Evt) -> u32 { n := evt_n(e); return evt_scalar_bits(e) * ifx n == 0 then cast(u32) 1 else n; }
evt_is_int :: (e: Evt) -> bool { if e.m != 0 return mvt_is_int(e.m); return e.em == 0 || mve_is_int(e.em); }
// EVT::getRoundIntegerType
evt_round_int :: (e: Evt) -> Evt {
    b := evt_bits(e);
    if b <= 8 return evt_simple(MVT_i8);
    p: u32 = 1; while p < b p *= 2;
    return evt_int(p);
}

// TargetLoweringBase::getTypeConversion: (action, next type)
xl_type_conversion :: (st: *X86_Lowering, vt: Evt) -> (s64, Evt) {
    if evt_is_simple(vt) {
        o := xl_ord(vt.m);
        la := cast(s64) st.type_action[o];
        if la == TA_SPLIT_VECTOR return la, evt_vec(evt_elt(vt), evt_n(vt) / 2, evt_scalable(vt));
        if la == TA_SCALARIZE_VECTOR return la, evt_simple(mvt_elt_code(vt.m));
        return la, evt_simple(st.transform_to[o]);
    }
    if !evt_is_vector(vt) {
        bits := evt_bits(vt);
        if bits < 8 || (bits & (bits - 1)) != 0 {
            nvt := evt_round_int(vt);
            a, nx := xl_type_conversion(st, nvt);
            if a == TA_PROMOTE_INTEGER return a, nx;
            return TA_PROMOTE_INTEGER, nvt;
        }
        return TA_EXPAND_INTEGER, evt_int(bits / 2);
    }
    n := evt_n(vt);
    scal := evt_scalable(vt);
    elt := evt_elt(vt);
    if n == 1 && !scal return TA_SCALARIZE_VECTOR, elt;
    if evt_is_int(elt) {
        if (n & (n - 1)) != 0 {
            p: u32 = 1; while p < n p *= 2;
            return TA_WIDEN_VECTOR, evt_vec(elt, p, scal);
        }
        lka, _ := xl_type_conversion(st, elt);
        if lka == TA_EXPAND_INTEGER {
            if scal && n == 1 return TA_SCALARIZE_SCALABLE_VECTOR, elt;
            return TA_SPLIT_VECTOR, evt_vec(elt, n / 2, scal);
        }
        e := elt;
        while true {
            e = evt_round_int(evt_int(1 + evt_bits(e)));
            if !evt_is_simple(e) break;
            nvt := mvt_vec(e.m, n, scal);
            if nvt != 0 && st.type_action[xl_ord(nvt)] == TA_LEGAL return TA_PROMOTE_INTEGER, evt_vec(e, n, scal);
        }
    }
    cnt := n;
    while true {
        // ElementCount::coefficientNextPowerOf2 (strictly greater)
        p: u32 = 1; while p <= cnt p *= 2;
        cnt = p;
        if !evt_is_simple(elt) break;
        lv := mvt_vec(elt.m, cnt, scal);
        if lv == 0 break;
        if st.type_action[xl_ord(lv)] == TA_LEGAL return TA_WIDEN_VECTOR, evt_simple(lv);
    }
    if (n & (n - 1)) != 0 {
        p: u32 = 1; while p < n p *= 2;
        return TA_WIDEN_VECTOR, evt_vec(elt, p, scal);
    }
    if scal && n == 1 return TA_SCALARIZE_SCALABLE_VECTOR, elt;
    return TA_SPLIT_VECTOR, evt_vec(elt, n / 2, scal);
}
xl_type_action :: (st: *X86_Lowering, vt: Evt) -> s64 { a, _ := xl_type_conversion(st, vt); return a; }
xl_type_to_transform_to :: (st: *X86_Lowering, vt: Evt) -> Evt { _, n := xl_type_conversion(st, vt); return n; }
xl_is_type_legal :: (st: *X86_Lowering, vt: Evt) -> bool { return evt_is_simple(vt) && is_type_legal_mvt(st, vt.m); }

// ---------------------------------------------------------------- construction

x86_lowering_init :: (st: *X86_Lowering) {
    N := MVT_ALL.count;
    st.reg_class = NewArray(N, bool);
    st.op_actions = NewArray(N * ISD_COUNT, u8);
    st.type_action = NewArray(N, u8);
    st.transform_to = NewArray(N, u32);
    st.num_registers = NewArray(N, u32);
    st.register_type = NewArray(N, u32);
    tlb_init_actions(st);
    x86_lowering_actions(st);
    xl_compute_register_properties(st);
}
