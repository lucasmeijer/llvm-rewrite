// X86TTIImpl over BasicTTIImplBase: the x86 cost model.
// Ports llvm/lib/Target/X86/X86TargetTransformInfo.cpp (cost tables generated into gen_x86_tti.jai by
// gen/gen_x86_tti.py) and llvm/include/llvm/CodeGen/BasicTTIImpl.h (the bt_* procedures: getTypeLegalizationCost,
// the generic arithmetic / cast / compare / memory / intrinsic costs, scalarization overhead), plus the
// X86TargetLowering hooks they call (isLegalAddressingMode, isTruncateFree, isZExtFree, getValueType).
// What isn't ported yet fails loudly with "x86 TTI: ... is not ported yet".

x86_np :: (what: string) { fatal("x86 TTI: % is not ported yet", what); }

// ---------------------------------------------------------------- types

// TargetLoweringBase::getValueType(DL, Ty, AllowUnknown): (known, EVT); unknown = MVT::Other
x86_value_type :: (st: *X86_Lowering, ty: Type_Id, allow_unknown: bool) -> (bool, Evt) {
    k := type_kind(ty);
    scalar :: (st: *X86_Lowering, t: Type_Id) -> (bool, Evt) {
        if type_kind(t) == {
            case .INT; return true, evt_int(type_int_width(t));
            case .HALF; return true, evt_simple(MVT_f16);
            case .BFLOAT; return true, evt_simple(MVT_bf16);
            case .FLOAT; return true, evt_simple(MVT_f32);
            case .DOUBLE; return true, evt_simple(MVT_f64);
            case .X86_FP80; return true, evt_simple(MVT_f80);
            case .FP128; return true, evt_simple(MVT_f128);
            case .PPC_FP128; return true, evt_simple(MVT_ppcf128);
            case .PTR; return true, evt_simple(mvt_int(cast(u32) dl_type_size_bits(t)));
            case .VOID; return true, evt_simple(MVT_isVoid);
            case .X86_AMX; return true, evt_simple(MVT_x86amx);
        }
        return false, evt_simple(MVT_Other);
    }
    if k == .VECTOR || k == .SVECTOR {
        ok, e := scalar(st, type_elem(ty));
        if !ok { if !allow_unknown x86_np("getValueType of a vector of this element type"); return false, e; }
        return true, evt_vec(e, cast(u32) type_count(ty), k == .SVECTOR);
    }
    ok, e := scalar(st, ty);
    if !ok && !allow_unknown x86_np(tprint("getValueType of type kind %", k));
    return ok, e;
}
x86_evt :: (st: *X86_Lowering, ty: Type_Id) -> Evt { _, e := x86_value_type(st, ty, false); return e; }

// BasicTTIImplBase::getTypeLegalizationCost: (cost, legal MVT)
bt_type_legalization_cost :: (st: *X86_Lowering, ty: Type_Id) -> (Cost, u32) {
    mty := x86_evt(st, ty);
    c: Cost = 1;
    while true {
        a, nx := xl_type_conversion(st, mty);
        if a == TA_SCALARIZE_SCALABLE_VECTOR return COST_INVALID, ifx evt_is_simple(mty) then mty.m else MVT_i64;
        if a == TA_LEGAL return c, mty.m;
        if a == TA_SPLIT_VECTOR || a == TA_EXPAND_INTEGER c *= 2;
        if evt_eq(mty, nx) return c, mty.m;
        mty = nx;
    }
    return c, 0;
}

// getRegUsageForType = TLI->getNumRegisters(Ctx, getValueType(DL, Ty))
x86_reg_usage_for_type :: (st: *X86_Lowering, ty: Type_Id) -> s64 {
    e := x86_evt(st, ty);
    if evt_is_simple(e) return st.num_registers[xl_ord(e.m)];
    if !evt_is_vector(e) {
        reg := xl_type_to_transform_to(st, e);    // TargetLowering::getNumRegisters for an extended integer
        while !xl_is_type_legal(st, reg) reg = xl_type_to_transform_to(st, reg);
        return (evt_bits(e) + evt_bits(reg) - 1) / evt_bits(reg);
    }
    x86_np("getRegUsageForType of an extended vector type");
    return 0;
}

// X86II::MO_* operand flags that classifyGlobalReference can produce
MO_NO_FLAG :: 0; MO_GOT :: 1; MO_GOTOFF :: 2; MO_GOTPCREL :: 3; MO_PIC_BASE_OFFSET :: 4; MO_DLLIMPORT :: 5;
MO_DARWIN_NONLAZY :: 6; MO_DARWIN_NONLAZY_PIC_BASE :: 7; MO_COFFSTUB :: 8; MO_ABS8 :: 9;

st_is_coff :: (st: *X86_Lowering) -> bool { return st_isOSWindows(st) && !ends_with(st.triple, "-elf") && !ends_with(st.triple, "-macho"); }
st_is_macho :: (st: *X86_Lowering) -> bool { return st_isTargetDarwin(st) || (st_isOSWindows(st) && ends_with(st.triple, "-macho")); }
// getEffectiveRelocModel (no -relocation-model): Darwin 64-bit PIC, Darwin 32-bit DynamicNoPIC, Win64 PIC, else static
RELOC_STATIC :: 0; RELOC_PIC :: 1; RELOC_DYNAMIC_NO_PIC :: 2;
// (with -relocation-model: X86TargetMachine's getEffectiveRelocModel adjustments of an explicit model)
x86_reloc_model :: (st: *X86_Lowering) -> s64 {
    rm := reloc_model_cl.model;
    if rm < 0 {
        if st_isTargetDarwin(st) return ifx st_is64Bit(st) then RELOC_PIC else RELOC_DYNAMIC_NO_PIC;
        if st_isOSWindows(st) && st_is64Bit(st) return RELOC_PIC;
        return RELOC_STATIC;
    }
    if rm == RELOC_DYNAMIC_NO_PIC {
        if st_is64Bit(st) return RELOC_PIC;
        if !st_isTargetDarwin(st) return RELOC_STATIC;
    }
    if rm == RELOC_STATIC && st_isTargetDarwin(st) && st_is64Bit(st) return RELOC_PIC;
    return rm;
}
// opt -relocation-model (codegen::getExplicitRelocModel): -1 = not given
reloc_model_cl: struct { model: s64 = -1; };
// TargetMachine::isPositionIndependent
x86_is_pic :: (st: *X86_Lowering) -> bool { return x86_reloc_model(st) == RELOC_PIC; }
// TargetMachine::shouldAssumeDSOLocal
x86_should_assume_dso_local :: (st: *X86_Lowering, gv: Value_Id) -> bool {
    g := glob(gv);
    if g.dso_local return true;
    if st_is_coff(st) {
        if g.dll == 1 return false;
        if st_isTargetCygMing(st) && (is_declaration(gv) || g.linkage == .AVAILABLE_EXTERNALLY) && vkind(gv) == .GLOBAL_VAR return false;
        if g.linkage == .EXTERN_WEAK return false;
        return true;
    }
    if st_is_macho(st) {
        if x86_reloc_model(st) == RELOC_STATIC return true;
        return gv_is_strong_definition_for_linker(gv);
    }
    return false;
}
// X86Subtarget::classifyLocalReference (small code model, no tagged globals)
x86_classify_local_reference :: (st: *X86_Lowering, gv: Value_Id) -> s64 {
    if !x86_is_pic(st) return MO_NO_FLAG;
    if st_is64Bit(st) return MO_NO_FLAG;   // ELF small code model: RIP-relative; others: RIP-rel / movabsq
    if st_is_coff(st) return MO_NO_FLAG;
    if st_isTargetDarwin(st) {
        l := glob(gv).linkage;
        if is_declaration(gv) || l == .AVAILABLE_EXTERNALLY || l == .COMMON return MO_DARWIN_NONLAZY_PIC_BASE;
        return MO_PIC_BASE_OFFSET;
    }
    return MO_GOTOFF;
}
// X86Subtarget::classifyGlobalReference (small code model)
x86_classify_global_reference :: (st: *X86_Lowering, gv: Value_Id) -> s64 {
    abs := get_metadata(gv, md_kind_id("absolute_symbol"));
    if abs != NONE {
        // getAbsoluteSymbolRange: [lo, hi) from the node; only a full set means "no range"
        lo := md_const_int_op(abs, 0); hi := md_const_int_op(abs, 1);
        r := cr_new(const_ap(lo), const_ap(hi));
        if !cr_is_full_set(r) {
            if ap_ult(cr_umax(r), ap_from_u64(r.lo.bits, 128)) return MO_ABS8;
            return MO_NO_FLAG;
        }
    }
    if x86_should_assume_dso_local(st, gv) return x86_classify_local_reference(st, gv);
    if st_is_coff(st) { if glob(gv).dll == 1 return MO_DLLIMPORT; return MO_COFFSTUB; }
    if st_isOSWindows(st) return MO_NO_FLAG;
    if st_is64Bit(st) return MO_GOTPCREL;
    if st_isTargetDarwin(st) return ifx x86_is_pic(st) then MO_DARWIN_NONLAZY_PIC_BASE else MO_DARWIN_NONLAZY;
    if x86_reloc_model(st) == RELOC_STATIC return MO_NO_FLAG;
    return MO_GOT;
}

// X86TargetLowering::isLegalAddressingMode (small code model)
x86_is_legal_addressing_mode :: (st: *X86_Lowering, ty: Type_Id, base_gv: Value_Id, offset: s64, has_base_reg: bool, scale: s64, addrspace: u32) -> bool {
    // isOffsetSuitableForCodeModel(BaseOffs, Small, BaseGV != null)
    if offset < -0x8000_0000 || offset > 0x7FFF_FFFF return false;
    if base_gv != NONE && offset >= 16 * 1024 * 1024 return false;
    if base_gv != NONE {
        f := x86_classify_global_reference(st, base_gv);
        // isGlobalStubReference
        if f == MO_DLLIMPORT || f == MO_GOTPCREL || f == MO_GOT || f == MO_DARWIN_NONLAZY_PIC_BASE || f == MO_DARWIN_NONLAZY || f == MO_COFFSTUB return false;
        // isGlobalRelativeToPICBase
        if has_base_reg && (f == MO_GOTOFF || f == MO_GOT || f == MO_PIC_BASE_OFFSET || f == MO_DARWIN_NONLAZY_PIC_BASE) return false;
        if x86_is_pic(st) && st_is64Bit(st) && (offset != 0 || scale > 1) return false;
    }
    if scale == 0 || scale == 1 || scale == 2 || scale == 4 || scale == 8 return true;
    if scale == 3 || scale == 5 || scale == 9 return !has_base_reg;
    return false;
}

// TLI->InstructionOpcodeToISD
isd_of_opcode :: (opc: Opcode) -> u32 {
    if opc == {
        case .ADD; return ISD_ADD; case .FADD; return ISD_FADD; case .SUB; return ISD_SUB; case .FSUB; return ISD_FSUB;
        case .MUL; return ISD_MUL; case .FMUL; return ISD_FMUL; case .UDIV; return ISD_UDIV; case .SDIV; return ISD_SDIV;
        case .FDIV; return ISD_FDIV; case .UREM; return ISD_UREM; case .SREM; return ISD_SREM; case .FREM; return ISD_FREM;
        case .SHL; return ISD_SHL; case .LSHR; return ISD_SRL; case .ASHR; return ISD_SRA; case .AND; return ISD_AND;
        case .OR; return ISD_OR; case .XOR; return ISD_XOR; case .FNEG; return ISD_FNEG;
        case .TRUNC; return ISD_TRUNCATE; case .ZEXT; return ISD_ZERO_EXTEND; case .SEXT; return ISD_SIGN_EXTEND;
        case .FPTOUI; return ISD_FP_TO_UINT; case .FPTOSI; return ISD_FP_TO_SINT; case .UITOFP; return ISD_UINT_TO_FP;
        case .SITOFP; return ISD_SINT_TO_FP; case .FPTRUNC; return ISD_FP_ROUND; case .FPEXT; return ISD_FP_EXTEND;
        case .PTRTOINT; return ISD_BITCAST; case .PTRTOADDR; return ISD_BITCAST; case .INTTOPTR; return ISD_BITCAST;
        case .BITCAST; return ISD_BITCAST; case .ADDRSPACECAST; return ISD_ADDRSPACECAST;
        case .ICMP; return ISD_SETCC; case .FCMP; return ISD_SETCC; case .SELECT; return ISD_SELECT;
        case .EXTRACTELEMENT; return ISD_EXTRACT_VECTOR_ELT; case .INSERTELEMENT; return ISD_INSERT_VECTOR_ELT;
        case .SHUFFLEVECTOR; return ISD_VECTOR_SHUFFLE; case .LOAD; return ISD_LOAD; case .STORE; return ISD_STORE;
        case .FREEZE; return ISD_FREEZE;
    }
    x86_np(tprint("InstructionOpcodeToISD(%)", opcode_name(opc)));
    return 0;
}

// ---------------------------------------------------------------- cost tables (CostTableLookup)

// The kind's cost of the first entry matching (isd, mvt[, src]): -1 when there is no entry or no cost for the kind.
xt :: (tbl: [] XCost_Entry, isd: u32, m: u32, kind: s64) -> Cost {
    for tbl if it.isd == isd && it.dst == m return it.c[kind];
    return -1;
}
xtc :: (tbl: [] XCost_Entry, isd: u32, dst: u32, src: u32, kind: s64) -> Cost {
    for tbl if it.isd == isd && it.dst == dst && it.src == src return it.c[kind];
    return -1;
}

// ---------------------------------------------------------------- the stubs filled in below

// minRequiredElementSize (TargetTransformInfoImpl.h): (bits, signed)
min_required_element_size :: (v: Value_Id) -> (u32, bool) {
    k := vkind(v);
    ty := vtype(v);
    if is_vector_type(ty) && (k == .C_DATA || k == .C_VECTOR) {
        signed := false;
        mn: u32 = 0;
        n := type_count(ty);
        for e: 0..cast(s64) n - 1 {
            c := cf_elt(v, cast(u64) e);
            if vkind(c) != .C_INT return type_bits(type_elem(ty)), signed;
            a := cf_ap(c);
            signed |= ap_is_negative(a);
            mn = max(mn, ap_significant_bits(a) - 1);
        }
        return mn, signed;
    }
    if k == .C_INT && !is_vector_type(ty) { a := cf_ap(v); return ap_significant_bits(a) - 1, ap_is_negative(a); }
    if is_inst(v) && inst_op(v) == .SEXT return type_bits(scalar_type(vtype(op(v, 0)))) - 1, true;
    if is_inst(v) && inst_op(v) == .ZEXT return type_bits(scalar_type(vtype(op(v, 0)))), false;
    return type_bits(scalar_type(ty)), false;
}

// VectorType::getExtendedElementVectorType
vec_extended_elt_type :: (t: Type_Id) -> Type_Id {
    return type_vector(type_count(t), type_int(cast(u64) type_int_width(type_elem(t)) * 2), type_kind(t) == .SVECTOR);
}

// X86TTIImpl::getArithmeticInstrCost
x86_arith_cost :: (t: *Tti, opc: Opcode, ty: Type_Id, kind: s64, o1: Op_Info, o2: Op_Info, args: [] Value_Id = .[], cxt: Value_Id = NONE) -> Cost {
    st := *t.xl;
    if opc == .MUL && is_vector_type(ty) && type_bits(scalar_type(ty)) * type_count(ty) <= 64 && type_bits(scalar_type(ty)) == 8 {
        wide := vec_extended_elt_type(ty);
        return cost_add(cost_add(x86_cast_cost(t, .ZEXT, wide, ty, CCH_NONE, kind, NONE),
                                 x86_cast_cost(t, .TRUNC, ty, wide, CCH_NONE, kind, NONE)),
                        x86_arith_cost(t, opc, wide, kind, o1, o2));
    }
    ltc, ltm := bt_type_legalization_cost(st, ty);
    isd := isd_of_opcode(opc);
    if isd == ISD_MUL && args.count == 2 && mvt_is_vec(ltm) && (mvt_scalar(ltm) == MVT_i32 || mvt_scalar(ltm) == MVT_i64) {
        s1, sg1 := min_required_element_size(args[0]);
        s2, sg2 := min_required_element_size(args[1]);
        mn := max(s1, s2);
        signed := sg1 || sg2;
        if mn <= 15 && !st_isPMADDWDSlow(st) && mvt_scalar(ltm) == MVT_i32 {
            is_cv :: (v: Value_Id) -> bool { k := vkind(v); return is_vector_type(vtype(v)) && (k == .C_DATA || k == .C_VECTOR); }
            c1 := is_cv(args[0]); c2 := is_cv(args[1]);
            x1 := is_inst(args[0]) && inst_op(args[0]) == .SEXT && (s1 == 15 || (s1 < 15 && !st_hasSSE41(st)));
            x2 := is_inst(args[1]) && inst_op(args[1]) == .SEXT && (s2 == 15 || (s2 < 15 && !st_hasSSE41(st)));
            if c1 || c2 || !sg1 || !sg2 || x1 || x2 ltm = mvt_vec(MVT_i16, 2 * mvt_n(ltm));
        }
        if st_useSLMArithCosts(st) && ltm == MVT_v4i32 {
            if mn <= 7 return ltc * 3;
            if !signed && mn <= 8 return ltc * 3;
            if mn <= 15 return ltc * 5;
            if !signed && mn <= 16 return ltc * 5;
        }
        if !signed && mn <= 32 && mvt_scalar(ltm) == MVT_i64 isd = ISD_X86_PMULUDQ;
    }
    if isd == ISD_MUL && oi_is_constant(o2) && (oi_is_power_of_2(o2) || oi_is_negated_power_of_2(o2)) {
        c := x86_arith_cost(t, .SHL, ty, kind, oi_no_props(o1), oi_no_props(o2));
        if oi_is_negated_power_of_2(o2) c = cost_add(c, x86_arith_cost(t, .SUB, ty, kind, OI_ANY, OI_ANY));
        return c;
    }
    if (isd == ISD_SDIV || isd == ISD_SREM) && oi_is_constant(o2) && oi_is_power_of_2(o2) {
        n1 := oi_no_props(o1); n2 := oi_no_props(o2);
        c := cost_mul(2, x86_arith_cost(t, .ASHR, ty, kind, n1, n2));
        c = cost_add(c, x86_arith_cost(t, .LSHR, ty, kind, n1, n2));
        c = cost_add(c, x86_arith_cost(t, .ADD, ty, kind, n1, n2));
        if isd == ISD_SREM {
            c = cost_add(c, x86_arith_cost(t, .MUL, ty, kind, n1, n2));
            c = cost_add(c, x86_arith_cost(t, .SUB, ty, kind, n1, n2));
        }
        return c;
    }
    if (isd == ISD_UDIV || isd == ISD_UREM) && oi_is_constant(o2) && oi_is_power_of_2(o2) {
        if isd == ISD_UDIV return x86_arith_cost(t, .LSHR, ty, kind, oi_no_props(o1), oi_no_props(o2));
        return x86_arith_cost(t, .AND, ty, kind, oi_no_props(o1), oi_no_props(o2));
    }
    // the table cascade: the first table (in LLVM's order) with an entry and a cost for this kind wins
    look :: (tbl: [] XCost_Entry, isd: u32, m: u32, kind: s64, ltc: Cost) -> (bool, Cost) {
        c := xt(tbl, isd, m, kind);
        if c < 0 return false, 0;
        return true, cost_mul(ltc, c);
    }
    U :: oi_is_uniform; C :: oi_is_constant;
    no_xop8 := !st_hasXOP(st) || mvt_scalar_bits(ltm) != 8;
    #insert -> string {
        // (condition, table) in X86TTIImpl::getArithmeticInstrCost order, before the shift special cases
        rows :: string.[
            "U(o2) && C(o2) && st_hasGFNI(st)", "GFNIUniformConstCostTable",
            "U(o2) && C(o2) && st_hasBWI(st)", "AVX512BWUniformConstCostTable",
            "U(o2) && C(o2) && st_hasDQI(st)", "AVX512DQUniformConstCostTable",
            "U(o2) && C(o2) && st_hasAVX512(st)", "AVX512UniformConstCostTable",
            "U(o2) && C(o2) && st_hasAVX2(st)", "AVX2UniformConstCostTable",
            "U(o2) && C(o2) && st_hasAVX(st) && no_xop8", "AVXUniformConstCostTable",
            "U(o2) && C(o2) && st_hasSSE2(st) && no_xop8", "SSE2UniformConstCostTable",
            "C(o2) && st_hasBWI(st)", "AVX512BWConstCostTable",
            "C(o2) && st_hasDQI(st)", "AVX512DQConstCostTable",
            "C(o2) && st_hasAVX512(st)", "AVX512ConstCostTable",
            "C(o2) && st_hasAVX2(st)", "AVX2ConstCostTable",
            "C(o2) && st_hasAVX(st)", "AVXConstCostTable",
            "C(o2) && st_hasSSE41(st)", "SSE41ConstCostTable",
            "C(o2) && st_hasSSE2(st)", "SSE2ConstCostTable",
            "st_hasBWI(st) && U(o2)", "AVX512BWUniformCostTable",
            "st_hasAVX512(st) && U(o2)", "AVX512UniformCostTable",
            "st_hasAVX2(st) && U(o2)", "AVX2UniformCostTable",
            "st_hasAVX(st) && U(o2) && no_xop8", "AVXUniformCostTable",
            "st_hasSSE2(st) && U(o2) && no_xop8", "SSE2UniformCostTable",
            "st_hasDQI(st)", "AVX512DQCostTable",
            "st_hasBWI(st)", "AVX512BWCostTable",
            "st_hasAVX512(st)", "AVX512CostTable",
        ];
        sb: String_Builder;
        i := 0;
        while i < rows.count {
            print_to_builder(*sb, "if % { ok, c := look(XT_getArithmeticInstrCost_%, isd, ltm, kind, ltc); if ok return c; }\n", rows[i], rows[i + 1]);
            i += 2;
        }
        return builder_to_string(*sb);
    }
    if st_hasAVX512(st) {
        if isd == ISD_SHL && ltm == MVT_v32i16 && C(o2) return x86_arith_cost(t, .MUL, ty, kind, oi_no_props(o1), oi_no_props(o2));
    }
    if st_hasAVX2(st) && !(st_hasXOP(st) && ltm == MVT_v4i32) {
        if isd == ISD_SHL && ltm == MVT_v16i16 && C(o2) return x86_arith_cost(t, .MUL, ty, kind, oi_no_props(o1), oi_no_props(o2));
        ok, c := look(XT_getArithmeticInstrCost_AVX2ShiftCostTable, isd, ltm, kind, ltc); if ok return c;
    }
    if st_hasXOP(st) {
        shift_isd := isd;
        if (shift_isd == ISD_SRL || shift_isd == ISD_SRA) && C(o2) shift_isd = ISD_SHL;
        ok, c := look(XT_getArithmeticInstrCost_XOPShiftCostTable, shift_isd, ltm, kind, ltc); if ok return c;
    }
    if isd == ISD_SHL && !U(o2) && C(o2) {
        vt := ltm;
        if ((vt == MVT_v8i16 || vt == MVT_v4i32) && st_hasSSE2(st)) || ((vt == MVT_v16i16 || vt == MVT_v8i32) && st_hasAVX(st)) isd = ISD_MUL;
    }
    #insert -> string {
        rows :: string.[
            "st_useGLMDivSqrtCosts(st)", "GLMCostTable",
            "st_useSLMArithCosts(st)", "SLMCostTable",
            "st_hasAVX2(st)", "AVX2CostTable",
            "st_hasAVX(st)", "AVX1CostTable",
            "st_hasSSE42(st)", "SSE42CostTable",
            "st_hasSSE41(st)", "SSE41CostTable",
            "st_hasSSSE3(st)", "SSSE3CostTable",
            "st_hasSSE2(st)", "SSE2CostTable",
            "st_hasSSE1(st)", "SSE1CostTable",
            "st_is64Bit(st)", "X64CostTbl",
            "true", "X86CostTbl",
        ];
        sb: String_Builder;
        i := 0;
        while i < rows.count {
            print_to_builder(*sb, "if % { ok, c := look(XT_getArithmeticInstrCost_%, isd, ltm, kind, ltc); if ok return c; }\n", rows[i], rows[i + 1]);
            i += 2;
        }
        return builder_to_string(*sb);
    }
    if kind == TCK_RECIP_THROUGHPUT && mvt_is_vec(ltm) && (isd == ISD_SDIV || isd == ISD_SREM || isd == ISD_UDIV || isd == ISD_UREM) {
        sc := x86_arith_cost(t, opc, scalar_type(ty), kind, oi_no_props(o1), oi_no_props(o2));
        return cost_mul(20 * ltc * mvt_n(ltm), sc);
    }
    if kind == TCK_CODE_SIZE {
        if isd == ISD_FADD || isd == ISD_FSUB || isd == ISD_FMUL || isd == ISD_FDIV || isd == ISD_FNEG ||
           isd == ISD_AND || isd == ISD_OR || isd == ISD_XOR return ltc;
    }
    return bt_arith_cost(t, opc, ty, kind, o1, o2, args, cxt);
}

// BasicTTIImplBase::getArithmeticInstrCost
bt_arith_cost :: (t: *Tti, opc: Opcode, ty: Type_Id, kind: s64, o1: Op_Info, o2: Op_Info, args: [] Value_Id, cxt: Value_Id) -> Cost {
    st := *t.xl;
    isd := isd_of_opcode(opc);
    if kind != TCK_RECIP_THROUGHPUT return base_arith_cost(opc, ty, kind, args);
    ltc, ltm := bt_type_legalization_cost(st, ty);
    is_float := is_fp_type(scalar_type(ty));
    op_cost: Cost = ifx is_float then 2 else 1;
    if is_op_legal_or_promote(st, isd, ltm) return cost_mul(ltc, op_cost);
    if !is_op_expand(st, isd, ltm) return cost_mul(cost_mul(ltc, 2), op_cost);
    if isd == ISD_UREM || isd == ISD_SREM {
        signed := isd == ISD_SREM;
        if is_op_legal_or_custom(st, ifx signed then ISD_SDIVREM else ISD_UDIVREM, ltm) ||
           is_op_legal_or_custom(st, ifx signed then ISD_SDIV else ISD_UDIV, ltm) {
            dc := x86_arith_cost(t, ifx signed then Opcode.SDIV else .UDIV, ty, kind, o1, o2);
            mc := x86_arith_cost(t, .MUL, ty, kind, OI_ANY, OI_ANY);
            sc := x86_arith_cost(t, .SUB, ty, kind, OI_ANY, OI_ANY);
            return cost_add(cost_add(dc, mc), sc);
        }
    }
    if type_kind(ty) == .SVECTOR return COST_INVALID;
    if type_kind(ty) == .VECTOR {
        c := x86_arith_cost(t, opc, scalar_type(ty), kind, o1, o2, args, cxt);
        tys := NewArray(args.count, Type_Id,, allocator = temp);
        for *tys it.* = ty;
        return cost_add(bt_scalarization_overhead_args(t, ty, args, tys, kind), cost_mul(cast(Cost) type_count(ty), c));
    }
    return op_cost;
}

// X86TTIImpl::getCastInstrCost
x86_cast_cost :: (t: *Tti, opc: Opcode, dst: Type_Id, src: Type_Id, cch: u8, kind: s64, i: Value_Id = NONE) -> Cost {
    st := *t.xl;
    isd := isd_of_opcode(opc);
    src_e := x86_evt(st, src);
    dst_e := x86_evt(st, dst);
    if !st_hasAVX512(st) || (!st_hasBWI(st) && evt_scalar_bits(dst_e) < 32) {
        if i != NONE && opc == .SEXT && evt_is_vector(src_e) && !evt_scalable(src_e) && evt_is_simple(evt_elt(src_e)) && evt_elt(src_e).m == MVT_i1 {
            c := op(i, 0);
            if is_inst(c) && (inst_op(c) == .ICMP || inst_op(c) == .FCMP) {
                if type_bits(scalar_type(vtype(op(c, 0)))) == evt_scalar_bits(dst_e) return TCC_FREE;
            }
        }
    }
    lookc :: (tbl: [] XCost_Entry, isd: u32, d: u32, s: u32, kind: s64, mul: Cost) -> (bool, Cost) {
        c := xtc(tbl, isd, d, s, kind);
        if c < 0 return false, 0;
        return true, cost_mul(mul, c);
    }
    cascade :: () -> string #expand {
        return #string DONE
    if st_useAVX512Regs(st) {
        if st_hasBWI(st) { ok, c := lookc(XT_getCastInstrCost_AVX512BWConversionTbl, isd, D, S, kind, MUL); if ok return c; }
        if st_hasDQI(st) { ok, c := lookc(XT_getCastInstrCost_AVX512DQConversionTbl, isd, D, S, kind, MUL); if ok return c; }
        if st_hasAVX512(st) { ok, c := lookc(XT_getCastInstrCost_AVX512FConversionTbl, isd, D, S, kind, MUL); if ok return c; }
    }
    if st_hasBWI(st) { ok, c := lookc(XT_getCastInstrCost_AVX512BWVLConversionTbl, isd, D, S, kind, MUL); if ok return c; }
    if st_hasDQI(st) { ok, c := lookc(XT_getCastInstrCost_AVX512DQVLConversionTbl, isd, D, S, kind, MUL); if ok return c; }
    if st_hasAVX512(st) { ok, c := lookc(XT_getCastInstrCost_AVX512VLConversionTbl, isd, D, S, kind, MUL); if ok return c; }
    if st_hasAVX2(st) { ok, c := lookc(XT_getCastInstrCost_AVX2ConversionTbl, isd, D, S, kind, MUL); if ok return c; }
    if st_hasAVX(st) { ok, c := lookc(XT_getCastInstrCost_AVXConversionTbl, isd, D, S, kind, MUL); if ok return c; }
    if st_hasF16C(st) { ok, c := lookc(XT_getCastInstrCost_F16ConversionTbl, isd, D, S, kind, MUL); if ok return c; }
    if st_hasSSE41(st) { ok, c := lookc(XT_getCastInstrCost_SSE41ConversionTbl, isd, D, S, kind, MUL); if ok return c; }
    if st_hasSSE2(st) { ok, c := lookc(XT_getCastInstrCost_SSE2ConversionTbl, isd, D, S, kind, MUL); if ok return c; }
DONE;
    }
    if evt_is_simple(src_e) && evt_is_simple(dst_e) {
        D := dst_e.m; S := src_e.m; MUL: Cost = 1;
        #insert #run cascade();
        if (isd == ISD_FP_ROUND && D == MVT_f16) || (isd == ISD_FP_EXTEND && S == MVT_f16) return 64;
    }
    lts_c, lts_m := bt_type_legalization_cost(st, src);
    ltd_c, ltd_m := bt_type_legalization_cost(st, dst);
    if isd == ISD_TRUNCATE && lts_m == ltd_m return TCC_FREE;
    {
        D := ltd_m; S := lts_m; MUL := cost_max(lts_c, ltd_c);
        #insert #run cascade();
    }
    sbits := type_bits(scalar_type(src));
    if (isd == ISD_SINT_TO_FP || isd == ISD_UINT_TO_FP) && 1 < sbits && sbits < 32 {
        ext_src := type_with_new_bit_width(src, 32);
        ext_opc := ifx isd == ISD_SINT_TO_FP then Opcode.SEXT else .ZEXT;
        ext: Cost = 0;
        if !(type_kind(src) == .INT && i != NONE && is_inst(op(i, 0)) && inst_op(op(i, 0)) == .LOAD)
            ext = x86_cast_cost(t, ext_opc, ext_src, src, cch, kind);
        return cost_add(ext, x86_cast_cost(t, .SITOFP, dst, ext_src, CCH_NONE, kind));
    }
    dbits := type_bits(scalar_type(dst));
    if (isd == ISD_FP_TO_SINT || isd == ISD_FP_TO_UINT) && 1 < dbits && dbits < 32 {
        trunc_dst := type_with_new_bit_width(dst, 32);
        return cost_add(x86_cast_cost(t, .FPTOSI, trunc_dst, src, cch, kind), x86_cast_cost(t, .TRUNC, dst, trunc_dst, CCH_NONE, kind));
    }
    c := bt_cast_cost(t, opc, dst, src, cch, kind, i);
    if kind != TCK_RECIP_THROUGHPUT return ifx c == 0 then 0 else 1;
    return c;
}

// Type::getWithNewBitWidth: type_with_new_bit_width (ic_compares.jai)

// BasicTTIImplBase::getCastInstrCost
bt_cast_cost :: (t: *Tti, opc: Opcode, dst: Type_Id, src: Type_Id, cch: u8, kind: s64, i: Value_Id) -> Cost {
    st := *t.xl;
    if base_cast_cost(opc, dst, src) == 0 return 0;
    isd := isd_of_opcode(opc);
    s_c, s_m := bt_type_legalization_cost(st, src);
    d_c, d_m := bt_type_legalization_cost(st, dst);
    ssize := mvt_bits(s_m);
    dsize := mvt_bits(d_m);
    iop :: (t: Type_Id) -> bool { return type_kind(t) == .INT || type_kind(t) == .PTR; }
    int_src := iop(src); int_dst := iop(dst);
    if opc == {
        case .TRUNC;
            if mvt_is_int(s_m) && !mvt_is_vec(s_m) && mvt_is_int(d_m) && !mvt_is_vec(d_m) && ssize > dsize return 0;   // isTruncateFree(EVT, EVT)
            if s_c == d_c && int_src == int_dst && ssize == dsize return 0;
        case .BITCAST;
            if s_c == d_c && int_src == int_dst && ssize == dsize return 0;
        case .FPEXT;
            // isExtFree(I): isFPExtFree is false on x86, isExtFreeImpl false
        case .ZEXT; #through;
        case .SEXT;
            if opc == .ZEXT && s_m == MVT_i32 && d_m == MVT_i64 && st_is64Bit(st) return 0;   // isZExtFree(MVT, MVT)
            if i != NONE && opc == .ZEXT {   // isExtFree(I): isZExtFree(Type, Type)
                ft := vtype(op(i, 0)); tt := vtype(i);
                if type_kind(ft) == .INT && type_int_width(ft) == 32 && type_kind(tt) == .INT && type_int_width(tt) == 64 && st_is64Bit(st) return 0;
            }
            if cch == CCH_NORMAL && i != NONE {
                ext_vt := x86_evt(st, dst);
                load_vt := x86_evt(st, src);
                ltype := ifx opc == .ZEXT then ISD_ZEXTLOAD else ISD_SEXTLOAD;
                l := op(i, 0);
                if is_inst(l) && inst_op(l) == .LOAD {
                    if d_c == s_c && evt_is_simple(ext_vt) && evt_is_simple(load_vt) && xl_load_ext_action(st, ltype, ext_vt.m, load_vt.m) == LA_LEGAL return 0;
                } else if call_iid(l) != NOT_INTRINSIC && iid_name(call_iid(l)) == "llvm.masked.load" {
                    x86_np("getCastInstrCost of an extended masked load");
                }
            }
        case .ADDRSPACECAST;
            sa := ptr_addrspace(src); da := ptr_addrspace(dst);
            // X86TargetLowering::isNoopAddrSpaceCast: TM.getPointerSize uses the target's own DataLayout
            if x86_tm_pointer_bits(st, sa) == x86_tm_pointer_bits(st, da) && sa < 256 && da < 256 return 0;
    }
    sv := is_vector_type(src); dv := is_vector_type(dst);
    if s_c == d_c && is_op_legal_or_promote(st, isd, d_m) return s_c;
    if !sv && !dv {
        if !is_op_expand(st, isd, d_m) return 1;
        return 4;
    }
    if dv && sv {
        if s_c == d_c && ssize == dsize {
            if opc == .ZEXT return s_c;
            if opc == .SEXT return s_c * 2;
            if !is_op_expand(st, isd, d_m) return s_c;
        }
        split_src := xl_type_action(st, x86_evt(st, src)) == TA_SPLIT_VECTOR;
        split_dst := xl_type_action(st, x86_evt(st, dst)) == TA_SPLIT_VECTOR;
        if (split_src || split_dst) && type_count(src) % 2 == 0 && type_count(dst) % 2 == 0 {
            hd := type_vector(type_count(dst) / 2, type_elem(dst), type_kind(dst) == .SVECTOR);
            hs := type_vector(type_count(src) / 2, type_elem(src), type_kind(src) == .SVECTOR);
            split: Cost = ifx !split_src || !split_dst then 1 else 0;   // getVectorSplitCost() == 1
            return cost_add(split, cost_mul(2, x86_cast_cost(t, opc, hd, hs, cch, kind, i)));
        }
        if type_kind(dst) == .SVECTOR return COST_INVALID;
        n := type_count(dst);
        c := x86_cast_cost(t, opc, scalar_type(dst), scalar_type(src), cch, kind, i);
        return cost_add(bt_scalarization_overhead(t, dst, true, true, kind), cost_mul(cast(Cost) n, c));
    }
    if opc == .BITCAST {
        c: Cost = 0;
        if sv c = cost_add(c, bt_scalarization_overhead(t, src, false, true, kind));
        if dv c = cost_add(c, bt_scalarization_overhead(t, dst, true, false, kind));
        return c;
    }
    x86_np("getCastInstrCost: unhandled cast");
    return 0;
}

// X86TTIImpl::getCmpSelInstrCost
x86_cmp_sel_cost :: (t: *Tti, opc: Opcode, val_ty: Type_Id, cond_ty: Type_Id, vec_pred: u8, kind: s64, o1 := OI_ANY, o2 := OI_ANY, i: Value_Id = NONE) -> Cost {
    st := *t.xl;
    sk := type_kind(scalar_type(val_ty));
    if !(sk == .INT || is_fp_kind(sk)) return bt_cmp_sel_cost(t, opc, val_ty, cond_ty, vec_pred, kind, o1, o2, i);
    ltc, mty := bt_type_legalization_cost(st, val_ty);
    isd := isd_of_opcode(opc);
    extra: Cost = 0;
    if opc == .ICMP || opc == .FCMP {
        if mvt_is_vec(mty) && !((st_hasXOP(st) && (!st_hasAVX2(st) || mvt_bits(mty) == 128)) ||
                                (st_hasAVX512(st) && 32 <= mvt_scalar_bits(mty)) || st_hasBWI(st)) {
            pred := vec_pred;
            if i != NONE && (pred == BAD_ICMP_PREDICATE || pred == BAD_FCMP_PREDICATE) pred = inst(i).pred;
            cmp_const := false;
            if i != NONE && (inst_op(i) == .ICMP || inst_op(i) == .FCMP) cmp_const = is_constant_kind(vkind(op(i, 1)));
            if pred == {
                case ICMP_NE; extra = ifx cmp_const then 0 else 1;
                case ICMP_SGE; #through;
                case ICMP_SLE; extra = ifx cmp_const then 0 else 1;
                case ICMP_ULT; #through;
                case ICMP_UGT; extra = ifx cmp_const then 1 else 2;
                case ICMP_ULE; #through;
                case ICMP_UGE;
                    if (st_hasSSE41(st) && mvt_scalar_bits(mty) == 32) || (st_hasSSE2(st) && mvt_scalar_bits(mty) < 32) extra = 1;
                    else extra = ifx cmp_const then 2 else 3;
                case FCMP_ONE; #through;
                case FCMP_UEQ;
                    if cond_ty != NONE && !st_hasAVX(st)
                        return cost_add(cost_add(x86_cmp_sel_cost(t, opc, val_ty, cond_ty, FCMP_UNO, kind, o1, o2),
                                                 x86_cmp_sel_cost(t, opc, val_ty, cond_ty, FCMP_OEQ, kind, o1, o2)),
                                        x86_arith_cost(t, .OR, cond_ty, kind, OI_ANY, OI_ANY));
                case BAD_ICMP_PREDICATE; #through;
                case BAD_FCMP_PREDICATE; extra = 3;
            }
        }
    }
    look :: (tbl: [] XCost_Entry, isd: u32, m: u32, kind: s64, ltc: Cost, extra: Cost) -> (bool, Cost) {
        c := xt(tbl, isd, m, kind);
        if c < 0 return false, 0;
        return true, cost_mul(ltc, extra + c);
    }
    #insert -> string {
        rows :: string.["st_useSLMArithCosts(st)", "SLMCostTbl", "st_hasBWI(st)", "AVX512BWCostTbl",
            "st_hasAVX512(st)", "AVX512CostTbl", "st_hasAVX2(st)", "AVX2CostTbl", "st_hasXOP(st)", "XOPCostTbl",
            "st_hasAVX(st)", "AVX1CostTbl", "st_hasSSE42(st)", "SSE42CostTbl", "st_hasSSE41(st)", "SSE41CostTbl",
            "st_hasSSE2(st)", "SSE2CostTbl", "st_hasSSE1(st)", "SSE1CostTbl"];
        sb: String_Builder;
        i := 0;
        while i < rows.count {
            print_to_builder(*sb, "if % { ok, c := look(XT_getCmpSelInstrCost_%, isd, mty, kind, ltc, extra); if ok return c; }\n", rows[i], rows[i + 1]);
            i += 2;
        }
        return builder_to_string(*sb);
    }
    if kind == TCK_LATENCY && opc == .SELECT && is_fp_type(scalar_type(val_ty)) return 3;
    return bt_cmp_sel_cost(t, opc, val_ty, cond_ty, vec_pred, kind, o1, o2, i);
}

// BasicTTIImplBase::getCmpSelInstrCost
bt_cmp_sel_cost :: (t: *Tti, opc: Opcode, val_ty: Type_Id, cond_ty: Type_Id, vec_pred: u8, kind: s64, o1: Op_Info, o2: Op_Info, i: Value_Id) -> Cost {
    st := *t.xl;
    isd := isd_of_opcode(opc);
    known, e := x86_value_type(st, val_ty, true);
    if !known return 1;   // MVT::Other: TargetTransformInfoImplBase
    if isd == ISD_SELECT && cond_ty != NONE && is_vector_type(cond_ty) isd = ISD_VSELECT;
    ltc, ltm := bt_type_legalization_cost(st, val_ty);
    if !(is_vector_type(val_ty) && !mvt_is_vec(ltm)) && !is_op_expand(st, isd, ltm) return ltc;
    if is_vector_type(val_ty) {
        if type_kind(val_ty) == .SVECTOR return COST_INVALID;
        n := type_count(val_ty);
        c := x86_cmp_sel_cost(t, opc, scalar_type(val_ty), scalar_type(cond_ty), vec_pred, kind, o1, o2, i);
        return cost_add(bt_scalarization_overhead(t, val_ty, true, false, kind), cost_mul(cast(Cost) n, c));
    }
    return 1;
}

// X86TTIImpl::getMemoryOpCost
x86_memory_op_cost :: (t: *Tti, opc: Opcode, src: Type_Id, align: u64, addrspace: u32, kind: s64, opinfo := OI_ANY, i: Value_Id = NONE) -> Cost {
    st := *t.xl;
    if opc == .LOAD && kind == TCK_LATENCY return bt_memory_op_cost(t, opc, src, align, addrspace, kind, opinfo, i);
    if kind != TCK_RECIP_THROUGHPUT {
        if i != NONE && inst_op(i) == .STORE {
            g := op(i, 1);
            if is_inst(g) && inst_op(g) == .GEP {
                for k: 1..cast(s64) nops(g) - 1 if !is_constant_kind(vkind(op(g, cast(u32) k))) return TCC_BASIC * 2;
            }
        }
        return TCC_BASIC;
    }
    known, _ := x86_value_type(st, src, true);
    if !known return bt_memory_op_cost(t, opc, src, align, addrspace, kind, opinfo, i);
    ltc, ltm := bt_type_legalization_cost(st, src);
    c: Cost = 0;
    if opc == .STORE && oi_is_constant(opinfo) c = cost_add(c, x86_memory_op_cost(t, .LOAD, src, dl_abi_align(src), 0, kind, opinfo));
    if type_kind(src) != .VECTOR || !mvt_is_vec(ltm) return cost_add(ifx mvt_is_fp(ltm) && !mvt_is_vec(ltm) then c else 0, ltc);
    return x86_vector_memory_op_cost(t, opc, src, align, addrspace, kind, opinfo, i, c, ltm);
}

// BasicTTIImplBase::getMemoryOpCost
bt_memory_op_cost :: (t: *Tti, opc: Opcode, src: Type_Id, align: u64, addrspace: u32, kind: s64, opinfo: Op_Info, i: Value_Id) -> Cost {
    st := *t.xl;
    known, _ := x86_value_type(st, src, true);
    if !known return 4;
    ltc, ltm := bt_type_legalization_cost(st, src);
    if opc == .LOAD && kind == TCK_LATENCY return 4;
    c := ltc;
    if kind != TCK_RECIP_THROUGHPUT return c;
    if is_vector_type(src) && dl_type_store_size(src) * 8 < mvt_bits(ltm) {
        mem := x86_evt(st, src);
        la := LA_EXPAND;
        if evt_is_simple(mem) {
            if opc == .STORE la = xl_trunc_store_action(st, ltm, mem.m);
            else la = xl_load_ext_action(st, ISD_EXTLOAD, ltm, mem.m);
        }
        if la != LA_LEGAL && la != LA_CUSTOM c = cost_add(c, bt_scalarization_overhead(t, src, opc != .STORE, opc == .STORE, kind));
    }
    return c;
}

// X86TTIImpl::getIntrinsicInstrCost
x86_intrinsic_cost :: (t: *Tti, ica: *Ica, kind: s64) -> Cost {
    st := *t.xl;
    ret := ica.ret;
    opty := ret;
    id := ica.id;
    isd: u32 = 0;
    n := ifx id != NOT_INTRINSIC then iid_name(id) else "";
    type_based := ica.type_based_only;
    if n == {
        case "llvm.abs"; isd = ISD_ABS;
        case "llvm.bitreverse"; isd = ISD_BITREVERSE;
        case "llvm.bswap"; isd = ISD_BSWAP;
        case "llvm.ctlz"; isd = ISD_CTLZ;
        case "llvm.ctpop"; isd = ISD_CTPOP;
        case "llvm.cttz"; isd = ISD_CTTZ;
        case "llvm.fshl"; #through;
        case "llvm.fshr";
            isd = ISD_FSHL;
            if !type_based && ica.args[0] == ica.args[1] {
                isd = ifx n == "llvm.fshl" then ISD_ROTL else ISD_ROTR;
                ok, _ := pm_apint(ica.args[2], true);
                if ok isd = ISD_X86_VROTLI;
            }
        case "llvm.lrint"; #through;
        case "llvm.llrint";
            return x86_cast_cost(t, .FPTOSI, ret, ica.tys[0], CCH_NONE, kind);
        case "llvm.maxnum"; #through;
        case "llvm.minnum"; isd = ISD_FMAXNUM;
        case "llvm.sadd.sat"; isd = ISD_SADDSAT;
        case "llvm.smax"; isd = ISD_SMAX;
        case "llvm.smin"; isd = ISD_SMIN;
        case "llvm.ssub.sat"; isd = ISD_SSUBSAT;
        case "llvm.uadd.sat"; isd = ISD_UADDSAT;
        case "llvm.umax"; isd = ISD_UMAX;
        case "llvm.umin"; isd = ISD_UMIN;
        case "llvm.usub.sat"; isd = ISD_USUBSAT;
        case "llvm.sqrt"; isd = ISD_FSQRT;
        case "llvm.sadd.with.overflow"; #through;
        case "llvm.ssub.with.overflow"; isd = ISD_SADDO; opty = type_sub(ret, 0);
        case "llvm.uadd.with.overflow"; #through;
        case "llvm.usub.with.overflow"; isd = ISD_UADDO; opty = type_sub(ret, 0);
        case "llvm.smul.with.overflow"; isd = ISD_SMULO; opty = type_sub(ret, 0);
        case "llvm.umul.with.overflow"; isd = ISD_UMULO; opty = type_sub(ret, 0);
    }
    if isd != 0 {
        ltc, mty := bt_type_legalization_cost(st, opty);
        adjust :: (st: *X86_Lowering, ica: *Ica, e_isd: u32, c: Cost, ltc: Cost, mty: u32) -> Cost {
            if e_isd == ISD_FMAXNUM || e_isd == ISD_FMINNUM {
                if (ica.fmf & FMF_NNAN) != 0 return ltc;
            }
            if mvt_is_int(mty) && !mvt_is_vec(mty) {
                if e_isd == ISD_BSWAP && st_hasMOVBE(st) && xs_has(st, X86FLD_HasFastMOVBE) {
                    ii := ica.inst;
                    if ii != NONE {
                        if num_uses(ii) == 1 && inst_op(ir.u_user[ir.v_first_use[ii]]) == .STORE return TCC_FREE;
                        l := op(ii, 0);
                        if is_inst(l) && inst_op(l) == .LOAD && num_uses(l) == 1 return TCC_FREE;
                    }
                }
            }
            return cost_mul(ltc, c);
        }
        if ((isd == ISD_CTTZ && !st_hasBMI(st)) || (isd == ISD_CTLZ && !st_hasLZCNT(st))) && !mvt_is_vec(mty) && !type_based {
            a1 := ica.args[1];
            if is_const_int(a1) && cf_is_all_ones(a1) isd = ifx isd == ISD_CTTZ then ISD_CTTZ_ZERO_POISON else ISD_CTLZ_ZERO_POISON;
        }
        if isd == ISD_FSQRT && kind == TCK_CODE_SIZE return ltc;
        look :: (tbl: [] XCost_Entry, isd: u32, m: u32, kind: s64) -> (bool, Cost, u32) {
            for tbl if it.isd == isd && it.dst == m {
                c := it.c[kind];
                if c < 0 return false, 0, 0;
                return true, c, it.isd;
            }
            return false, 0, 0;
        }
        #insert -> string {
            rows :: string.["st_useGLMDivSqrtCosts(st)", "GLMCostTbl", "st_useSLMArithCosts(st)", "SLMCostTbl",
                "st_hasVBMI2(st)", "AVX512VBMI2CostTbl", "st_hasBITALG(st)", "AVX512BITALGCostTbl",
                "st_hasVPOPCNTDQ(st)", "AVX512VPOPCNTDQCostTbl", "st_hasGFNI(st)", "GFNICostTbl",
                "st_hasCDI(st)", "AVX512CDCostTbl", "st_hasBWI(st)", "AVX512BWCostTbl", "st_hasAVX512(st)", "AVX512CostTbl",
                "st_hasXOP(st)", "XOPCostTbl", "st_hasAVX2(st)", "AVX2CostTbl", "st_hasAVX(st)", "AVX1CostTbl",
                "st_hasSSE42(st)", "SSE42CostTbl", "st_hasSSE41(st)", "SSE41CostTbl", "st_hasSSSE3(st)", "SSSE3CostTbl",
                "st_hasSSE2(st)", "SSE2CostTbl", "st_hasSSE1(st)", "SSE1CostTbl",
                "st_hasBMI(st) && st_is64Bit(st)", "BMI64CostTbl", "st_hasBMI(st)", "BMI32CostTbl",
                "st_hasLZCNT(st) && st_is64Bit(st)", "LZCNT64CostTbl", "st_hasLZCNT(st)", "LZCNT32CostTbl",
                "st_hasPOPCNT(st) && st_is64Bit(st)", "POPCNT64CostTbl", "st_hasPOPCNT(st)", "POPCNT32CostTbl",
                "st_is64Bit(st)", "X64CostTbl", "true", "X86CostTbl"];
            sb: String_Builder;
            i := 0;
            while i < rows.count {
                print_to_builder(*sb, "if % { ok, c, ei := look(XT_getIntrinsicInstrCost_%, isd, mty, kind); if ok return adjust(st, ica, ei, c, ltc, mty); }\n", rows[i], rows[i + 1]);
                i += 2;
            }
            return builder_to_string(*sb);
        }
        if type_based && (n == "llvm.fshl" || n == "llvm.fshr") {
            cond_ty := type_with_new_bit_width(ret, 1);
            c: Cost = 0;
            for o: Opcode.[.OR, .SUB, .SHL, .LSHR, .AND] c = cost_add(c, x86_arith_cost(t, o, ret, kind, OI_ANY, OI_ANY));
            c = cost_add(c, x86_cmp_sel_cost(t, .ICMP, ret, cond_ty, ICMP_EQ, kind));
            c = cost_add(c, x86_cmp_sel_cost(t, .SELECT, ret, cond_ty, ICMP_EQ, kind));
            return c;
        }
    }
    return bt_intrinsic_cost(t, ica, kind);
}


// pointer size in the X86 TargetMachine's DataLayout (computeX86DataLayout: p270/p271 32-bit, p272 64-bit)
x86_tm_pointer_bits :: (st: *X86_Lowering, as: u32) -> u32 {
    if as == 270 || as == 271 return 32;
    if as == 272 return 64;
    return st_ptr_bits(st);
}
