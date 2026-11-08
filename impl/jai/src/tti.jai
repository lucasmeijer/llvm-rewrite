// TargetTransformInfo: the cost model and target queries passes use.
// Ports llvm/lib/Analysis/TargetTransformInfo.cpp (the wrapper: getOperandInfo, getCastContextHint,
// getPredictableBranchThreshold, NoTTIImpl), llvm/include/llvm/Analysis/TargetTransformInfoImpl.h
// (TargetTransformInfoImplBase = what NoTTIImpl answers, and TargetTransformInfoImplCRTPBase::getInstructionCost /
// getGEPCost / isExpensiveToSpeculativelyExecute), llvm/lib/Analysis/CostModel.cpp (print<cost-model>) and the
// TargetIRAnalysis / X86TargetMachine::getSubtargetImpl subtarget selection (-mcpu, -mattr, "target-cpu",
// "tune-cpu", "target-features", "prefer-vector-width", "min-legal-vector-width", "use-soft-float").
// The x86 target (X86TTIImpl over BasicTTIImplBase) is tti_x86.jai; X86TargetLowering legality is x86_lowering.jai.
//
// Design: one `Tti` per distinct subtarget key (like X86TargetMachine's SubtargetMap), `tti_get(f)` =
// AM.getResult<TargetIRAnalysis>(F). Every query is a procedure `tti_<query>(t, ...)` that switches on t.kind
// (NONE = NoTTIImpl, X86 = X86TTIImpl); there is no virtual dispatch. A query x86 answers with code that is not
// ported fails loudly.
//
// Costs are InstructionCost: s64 with COST_INVALID (and everything above it) as the invalid state, which compares
// greater than every valid cost like InstructionCost::operator<, and propagates through cost_add / cost_mul.

Cost :: s64;
COST_INVALID : Cost : 0x4000_0000_0000_0000;
cost_valid :: inline (c: Cost) -> bool { return c < COST_INVALID; }
cost_add :: (a: Cost, b: Cost) -> Cost {
    if !cost_valid(a) || !cost_valid(b) return COST_INVALID;
    return a + b;
}
cost_mul :: (a: Cost, b: Cost) -> Cost {
    if !cost_valid(a) || !cost_valid(b) return COST_INVALID;
    return a * b;
}
cost_max :: (a: Cost, b: Cost) -> Cost { return ifx a > b then a else b; }
cost_to_string :: (c: Cost) -> string { if !cost_valid(c) return "Invalid"; return tprint("%", c); }

TCK_RECIP_THROUGHPUT :: 0;
TCK_LATENCY :: 1;
TCK_CODE_SIZE :: 2;
TCK_SIZE_AND_LATENCY :: 3;

BAD_FCMP_PREDICATE :: 16;
TCC_FREE : Cost : 0;
TCC_BASIC : Cost : 1;
TCC_EXPENSIVE : Cost : 4;

// TTI::OperandValueInfo
OK_ANY_VALUE :: 0; OK_UNIFORM_VALUE :: 1; OK_UNIFORM_CONSTANT_VALUE :: 2; OK_NON_UNIFORM_CONSTANT_VALUE :: 3;
OP_NONE :: 0; OP_POWER_OF_2 :: 1; OP_NEGATED_POWER_OF_2 :: 2;
Op_Info :: struct { kind: u8; props: u8; }
oi_is_constant :: (o: Op_Info) -> bool { return o.kind == OK_UNIFORM_CONSTANT_VALUE || o.kind == OK_NON_UNIFORM_CONSTANT_VALUE; }
oi_is_uniform :: (o: Op_Info) -> bool { return o.kind == OK_UNIFORM_VALUE || o.kind == OK_UNIFORM_CONSTANT_VALUE; }
oi_is_power_of_2 :: (o: Op_Info) -> bool { return o.props == OP_POWER_OF_2; }
oi_is_negated_power_of_2 :: (o: Op_Info) -> bool { return o.props == OP_NEGATED_POWER_OF_2; }
oi_no_props :: (o: Op_Info) -> Op_Info { return .{o.kind, OP_NONE}; }
OI_ANY :: Op_Info.{OK_ANY_VALUE, OP_NONE};

// TTI::CastContextHint
CCH_NONE :: 0; CCH_NORMAL :: 1; CCH_MASKED :: 2; CCH_GATHER_SCATTER :: 3; CCH_INTERLEAVE :: 4; CCH_REVERSED :: 5;

// TTI::ShuffleKind
SK_BROADCAST :: 0; SK_REVERSE :: 1; SK_SELECT :: 2; SK_TRANSPOSE :: 3; SK_INSERT_SUBVECTOR :: 4;
SK_EXTRACT_SUBVECTOR :: 5; SK_PERMUTE_TWO_SRC :: 6; SK_PERMUTE_SINGLE_SRC :: 7; SK_SPLICE :: 8;

Tti_Kind :: enum u8 { NONE; X86; }

Tti :: struct {
    kind: Tti_Kind;
    xl: X86_Lowering;     // X86 subtarget + lowering (kind == .X86)
}

// IntrinsicCostAttributes
Ica :: struct {
    id: Intrinsic_Id;
    ret: Type_Id;
    args: [] Value_Id;      // empty when the attributes are type-based only
    tys: [] Type_Id;
    fmf: u32;
    inst: Value_Id = NONE;
    scalar_cost: Cost = COST_INVALID;
    type_based_only: bool;
}
// IntrinsicCostAttributes(Id, CI, ScalarCost, TypeBasedOnly)
ica_from_call :: (c: Value_Id, type_based_only := false, scalar_cost := COST_INVALID) -> Ica {
    a: Ica;
    a.id = call_iid(c);
    a.ret = vtype(c);
    a.inst = c;
    a.scalar_cost = scalar_cost;
    a.type_based_only = type_based_only;
    if is_fp_math_inst(c) a.fmf = inst_fmf(c);
    n := call_num_args(c);
    tys := NewArray(n, Type_Id,, allocator = temp);
    args := NewArray(n, Value_Id,, allocator = temp);
    for k: 0..cast(s64) n - 1 { args[k] = op(c, cast(u32) k); tys[k] = vtype(args[k]); }
    a.tys = tys;
    if !type_based_only a.args = args;
    return a;
}

// ---------------------------------------------------------------- TargetIRAnalysis (subtargets)

tti_opts: struct {
    mcpu: string;                  // opt -mcpu
    mattr: string;                 // opt -mattr (comma separated, as given)
    cost_kind: s64 = -1;           // CostModel.cpp -cost-kind: -1 = throughput (default), 0..3, 4 = all
    intrinsic_cost_strategy: s64;  // -intrinsic-cost-strategy: 0 instruction-cost, 1 intrinsic-cost, 2 type-based
    predictable_branch_threshold: s64 = -1;   // -predictable-branch-threshold (getNumOccurrences > 0 when >= 0)
    redux_cost: bool;              // -costmodel-reduxcost (declared in TargetTransformInfo.cpp, read nowhere)
};

tti_cl: struct { cost_kind: string; intrinsic_cost_strategy: string; }
TTI_CL_OPT_COUNT :: 6;
add_tti_cl_opts :: (list: [] Cl_Opt, start: s64) {
    list[start + 0] = .{"mcpu", .STRING, null, null, *tti_opts.mcpu};
    list[start + 1] = .{"mattr", .STRING, null, null, *tti_opts.mattr};
    list[start + 2] = .{"cost-kind", .STRING, null, null, *tti_cl.cost_kind};
    list[start + 3] = .{"intrinsic-cost-strategy", .STRING, null, null, *tti_cl.intrinsic_cost_strategy};
    list[start + 4] = .{"predictable-branch-threshold", .INT, null, *tti_opts.predictable_branch_threshold, null};
    list[start + 5] = .{"costmodel-reduxcost", .BOOL, *tti_opts.redux_cost, null, null};
}
// the enum-valued options, decoded where they are used
tti_decode_cl :: () {
    k := tti_cl.cost_kind;
    if k == "" || k == "throughput" tti_opts.cost_kind = -1;
    else if k == "latency" tti_opts.cost_kind = TCK_LATENCY;
    else if k == "code-size" tti_opts.cost_kind = TCK_CODE_SIZE;
    else if k == "size-latency" tti_opts.cost_kind = TCK_SIZE_AND_LATENCY;
    else if k == "all" tti_opts.cost_kind = 4;
    else fatal("Cannot find option named '%'!", k);
    s := tti_cl.intrinsic_cost_strategy;
    if s == "" || s == "instruction-cost" tti_opts.intrinsic_cost_strategy = 0;
    else if s == "intrinsic-cost" tti_opts.intrinsic_cost_strategy = 1;
    else if s == "type-based-intrinsic-cost" tti_opts.intrinsic_cost_strategy = 2;
    else fatal("Cannot find option named '%'!", s);
}

tti_none: Tti;
tti_cache: Table(string, *Tti);   // X86TargetMachine::SubtargetMap

tti_is_x86_triple :: (t: string) -> bool {
    return begins_with(t, "x86_64") || begins_with(t, "i386") || begins_with(t, "i486") || begins_with(t, "i586") ||
           begins_with(t, "i686") || begins_with(t, "i786") || begins_with(t, "i886") || begins_with(t, "i986") ||
           begins_with(t, "amd64") || begins_with(t, "x86");
}

// AM.getResult<TargetIRAnalysis>(F): NoTTIImpl without a target triple, X86TTIImpl for x86 triples.
tti_get :: (f: Value_Id) -> *Tti {
    if ir.triple.count == 0 return *tti_none;
    if !tti_is_x86_triple(ir.triple) fatal("TargetTransformInfo for target triple '%' is not supported", ir.triple);
    fa := attr_list_fn(glob(f).attrs);
    str_attr :: (fa: u32, key: string) -> (bool, string) {
        for attr_set_items(fa) if it.kind == .STRING_ATTR && it.key == key return true, it.val;
        return false, "";
    }
    has_cpu, cpu := str_attr(fa, "target-cpu");
    if !has_cpu cpu = tti_opts.mcpu;
    has_tune, tune := str_attr(fa, "tune-cpu");
    if !has_tune tune = ifx cpu == "x86-64" then "generic" else cpu;
    has_fs, fs := str_attr(fa, "target-features");
    if !has_fs fs = tti_opts.mattr;
    key: String_Builder; key.allocator = temp;
    pvw: u32 = 0;
    has_p, p := str_attr(fa, "prefer-vector-width");
    if has_p { v, ok := parse_c_uint(p); if ok { append(*key, "p"); append(*key, p); pvw = cast(u32) v; } }
    rvw: u32 = 0xFFFF_FFFF;
    has_m, m := str_attr(fa, "min-legal-vector-width");
    if has_m { v, ok := parse_c_uint(m); if ok { append(*key, "m"); append(*key, m); rvw = cast(u32) v; } }
    append(*key, cpu);
    append(*key, tune);
    has_sf, sfv := str_attr(fa, "use-soft-float");
    soft := has_sf && sfv == "true";
    if soft append(*key, ifx fs.count == 0 then "+soft-float" else "+soft-float,");
    append(*key, fs);
    k := builder_to_string(*key);
    found, t := table_find(*tti_cache, k);
    if found return t;
    t = New(Tti);
    t.kind = .X86;
    full_fs := fs;
    if soft full_fs = ifx fs.count == 0 then "+soft-float" else tprint("+soft-float,%", fs);
    x86_subtarget_init(*t.xl, ir.triple, cpu, tune, copy_string(full_fs), pvw, rvw);
    table_set(*tti_cache, copy_string(k), t);
    return t;
}

// StringRef::getAsInteger(0, Width) for an unsigned value
parse_c_uint :: (s: string) -> (s64, bool) {
    if s.count == 0 return 0, false;
    v: s64 = 0;
    for c: cast([] u8) s {
        if c < #char "0" || c > #char "9" return 0, false;
        v = v * 10 + (c - #char "0");
    }
    return v, true;
}

// MCSubtargetInfo::ApplyFeatureFlag over X86_FEATURES; unknown names warn on stderr like LLVM (twice per new
// subtarget: X86GenSubtargetInfo's constructor and initializeSubtargetDependencies both parse the string).
x86_find_feature :: (name: string) -> s64 {
    for X86_FEATURES if it.name == name return it_index;
    return -1;
}
x86_apply_features :: (feat: *[X86_FEATURE_WORDS] u64, fs: string, warn: bool) {
    if fs.count == 0 return;
    for part: split(fs, ",",, allocator = temp) {
        if part.count == 0 continue;
        f := to_lower_copy(part,, allocator = temp);
        enable := true;
        name := f;
        if f[0] == #char "+" { name = slice(f, 1, f.count - 1); }
        else if f[0] == #char "-" { enable = false; name = slice(f, 1, f.count - 1); }
        k := x86_find_feature(name);
        if k < 0 {
            if warn {
                shown := ifx f[0] == #char "+" || f[0] == #char "-" then f else tprint("+%", f);
                print_stderr("'%' is not a recognized feature for this target (ignoring feature)\n", shown);
            }
            continue;
        }
        if enable {
            for w: 0..X86_FEATURE_WORDS-1 feat.*[w] |= X86_FEATURES[k].implies[w];
            feat.*[k / 64] |= (cast(u64) 1) << cast(u64) (k % 64);
        } else {
            // ClearImpliedBits: clear k and every feature that implies it
            feat.*[k / 64] &= ~((cast(u64) 1) << cast(u64) (k % 64));
            for X86_FEATURES {
                if (it.implies[k / 64] >> cast(u64) (k % 64)) & 1
                    feat.*[it_index / 64] &= ~((cast(u64) 1) << cast(u64) (it_index % 64));
            }
        }
    }
}
x86_find_cpu :: (name: string) -> s64 {
    for X86_CPUS if it.name == name return it_index;
    return -1;
}

// opt creates the TargetMachine (and its default subtarget, from -mcpu / -mattr) once after reading the module:
// one round of diagnostics.
tti_create_target_machine :: () {
    if !tti_is_x86_triple(ir.triple) return;
    cpu := ifx tti_opts.mcpu.count == 0 then "generic" else tti_opts.mcpu;
    if x86_find_cpu(cpu) < 0 print_stderr("'%' is not a recognized processor for this target (ignoring processor)\n", cpu);
    feat: [X86_FEATURE_WORDS] u64;
    x86_apply_features(*feat, tti_opts.mattr, true);
}

// codegen::getFeaturesStr: the -mattr list, lower-cased, '+' added where no sign was given
mattr_features_string :: () -> string {
    if tti_opts.mattr.count == 0 return "";
    sb: String_Builder; sb.allocator = temp;
    first := true;
    for part: split(tti_opts.mattr, ",",, allocator = temp) {
        if part.count == 0 continue;
        f := to_lower_copy(part,, allocator = temp);
        if !first append(*sb, ",");
        first = false;
        if f[0] != #char "+" && f[0] != #char "-" append(*sb, "+");
        append(*sb, f);
    }
    return builder_to_string(*sb);
}
// codegen::setFunctionAttributes(M, CPU, Features, TuneCPU): opt adds "target-cpu" / "target-features" to every
// function from -mcpu / -mattr
opt_set_function_attributes :: () {
    cpu := tti_opts.mcpu;
    feats := mattr_features_string();
    if cpu.count == 0 && feats.count == 0 return;
    for f: ir.m_functions {
        fa := attr_list_fn(glob(f).attrs);
        items: [..] Attr; items.allocator = temp;
        old_feats := "";
        has_cpu := false;
        for attr_set_items(fa) {
            if it.kind == .STRING_ATTR && it.key == "target-cpu" has_cpu = true;
            if it.kind == .STRING_ATTR && it.key == "target-features" { old_feats = it.val; continue; }
            array_add(*items, it);
        }
        changed := false;
        if cpu.count && !has_cpu {
            a: Attr; a.kind = .STRING_ATTR; a.key = copy_string(cpu); a.val = "";
            a.key = "target-cpu"; a.val = copy_string(cpu);
            array_add(*items, a);
            changed = true;
        }
        if feats.count {
            a: Attr; a.kind = .STRING_ATTR; a.key = "target-features";
            a.val = copy_string(ifx old_feats.count == 0 then feats else tprint("%,%", old_feats, feats));
            array_add(*items, a);
            changed = true;
        } else if old_feats.count {
            a: Attr; a.kind = .STRING_ATTR; a.key = "target-features"; a.val = old_feats;
            array_add(*items, a);
        }
        if changed glob(f).attrs = attr_list_with_fn(glob(f).attrs, attr_set_get(items));
    }
}

// X86Subtarget::initSubtargetFeatures + X86Subtarget constructor (vector widths)
x86_subtarget_init :: (st: *X86_Lowering, triple: string, cpu_in: string, tune_in: string, fs: string, pvw: u32, rvw: u32) {
    st.triple = copy_string(triple);
    cpu := ifx cpu_in.count == 0 then "generic" else cpu_in;
    tune := ifx tune_in.count == 0 then "i586" else tune_in;
    is64 := begins_with(triple, "x86_64") || begins_with(triple, "amd64");
    full := ifx is64 then "+64bit-mode,-32bit-mode,-16bit-mode,+sse2" else "-64bit-mode,+32bit-mode,-16bit-mode";
    if fs.count full = tprint("%,%", full, fs);
    if find_index_from_left(full, "-64bit-mode") >= 0 {
        for string.["egpr", "push2pop2", "ppx", "ndd", "ccmp", "nf", "cf", "zu", "jmpabs", "uintr"] full = tprint("%,-%", full, it);
    }
    // InitMCProcessorInfo(CPU, TuneCPU, FS), run twice (the generated constructor, then ParseSubtargetFeatures)
    for pass: 0..1 {
        feat: [X86_FEATURE_WORDS] u64;
        ci := x86_find_cpu(cpu);
        if ci < 0 {
            print_stderr("'%' is not a recognized processor for this target (ignoring processor)\n", cpu);
        } else {
            for w: 0..X86_FEATURE_WORDS-1 feat[w] |= X86_CPUS[ci].features[w];
        }
        ti := x86_find_cpu(tune);
        if ti < 0 {
            print_stderr("'%' is not a recognized processor for this target (ignoring processor)\n", tune);
        } else {
            for w: 0..X86_FEATURE_WORDS-1 feat[w] |= X86_CPUS[ti].tune[w];
        }
        x86_apply_features(*feat, full, true);
        st.feat = feat;
    }
    if is64 && !xs_has(st, X86FLD_HasX86_64) fatal("LLVM ERROR: 64-bit code requested on a subtarget that doesn't support it!");
    // PreferVectorWidth: the attribute, else the prefer-128/256-bit tuning
    st.prefer_vector_width = 0xFFFF_FFFF;
    if pvw st.prefer_vector_width = pvw;
    else if xs_has(st, X86FLD_Prefer128Bit) st.prefer_vector_width = 128;
    else if xs_has(st, X86FLD_Prefer256Bit) st.prefer_vector_width = 256;
    st.required_vector_width = rvw;
    x86_lowering_init(st);
}

// ---------------------------------------------------------------- simple target queries

// getPredictableBranchThreshold as a percentage (BranchProbability(N, 100))
tti_predictable_branch_threshold :: (t: *Tti) -> s64 {
    if tti_opts.predictable_branch_threshold >= 0 return tti_opts.predictable_branch_threshold;
    return 99;
}
tti_branch_mispredict_penalty :: (t: *Tti) -> Cost {
    if t.kind == .X86 return 14;
    return 0;
}
tti_is_profitable_to_hoist :: (t: *Tti, i: Value_Id) -> bool { return true; }   // X86TargetLowering doesn't override it
tti_has_conditional_load_store_for_type :: (t: *Tti, ty: Type_Id, is_store: bool) -> bool {
    if t.kind != .X86 return false;
    st := *t.xl;
    if !st_hasCF(st) return false;
    if ty == NONE return true;
    k := type_kind(ty);
    if k != .INT && !(k == .VECTOR && type_count(ty) == 1) return false;
    s := scalar_type(ty);
    if type_kind(s) != .INT return false;
    w := type_int_width(s);
    return w == 16 || w == 32 || w == 64;
}
tti_should_build_lookup_tables :: (t: *Tti) -> bool {
    if t.kind != .X86 return true;
    st := *t.xl;
    return is_op_legal_or_custom(st, ISD_BR_JT, MVT_Other) || is_op_legal_or_custom(st, ISD_BRIND, MVT_Other);
}
tti_should_build_lookup_tables_for_constant :: (t: *Tti, c: Value_Id) -> bool { return true; }
tti_minimum_lookup_table_entry_bit_width :: (t: *Tti) -> s64 { return 8; }
tti_should_build_rel_lookup_tables :: (t: *Tti) -> bool {
    if t.kind != .X86 return false;
    fatal("TTI::shouldBuildRelLookupTables (relocation model / code model) is not ported yet");
    return false;
}
tti_is_type_legal :: (t: *Tti, ty: Type_Id) -> bool {
    if t.kind != .X86 return false;
    ok, e := x86_value_type(*t.xl, ty, true);
    if !ok return false;
    return xl_is_type_legal(*t.xl, e);
}
tti_reg_usage_for_type :: (t: *Tti, ty: Type_Id) -> s64 {
    if t.kind != .X86 return 1;
    return x86_reg_usage_for_type(*t.xl, ty);
}
tti_is_expensive_to_speculatively_execute :: (t: *Tti, i: Value_Id) -> bool {
    if t.kind == .X86 && inst_op(i) == .FDIV return true;
    return tti_instruction_cost(t, i, TCK_SIZE_AND_LATENCY) >= TCC_EXPENSIVE;
}

// TTI::isLoweredToCall (TargetTransformInfoImpl.h)
tti_is_lowered_to_call :: (f: Value_Id) -> bool {
    if glob(f).intrinsic return false;
    if is_local_linkage(glob(f).linkage) || vname(f).count == 0 return true;
    NOT_CALLS :: string.["copysign", "copysignf", "copysignl", "fabs", "fabsf", "fabsl", "fmin", "fminf", "fminl",
        "fmax", "fmaxf", "fmaxl", "sin", "sinf", "sinl", "cos", "cosf", "cosl", "tan", "tanf", "tanl", "asin", "asinf",
        "asinl", "acos", "acosf", "acosl", "atan", "atanf", "atanl", "atan2", "atan2f", "atan2l", "sinh", "sinhf",
        "sinhl", "cosh", "coshf", "coshl", "tanh", "tanhf", "tanhl", "sqrt", "sqrtf", "sqrtl", "exp10", "exp10l",
        "exp10f", "pow", "powf", "powl", "exp2", "exp2l", "exp2f", "floor", "floorf", "ceil", "round", "ffs", "ffsl",
        "abs", "labs", "llabs"];
    for NOT_CALLS if vname(f) == it return false;
    return true;
}

// ---------------------------------------------------------------- TargetTransformInfo.cpp helpers

// llvm::getSplatValue (VectorUtils.cpp)
vu_get_splat_value :: (v: Value_Id) -> Value_Id {
    if is_constant_kind(vkind(v)) return get_splat_value(v);
    // shufflevector (insertelement _, Splat, 0), _, zeroinitializer
    if is_inst(v) && inst_op(v) == .SHUFFLEVECTOR {
        ie := op(v, 0);
        if is_inst(ie) && inst_op(ie) == .INSERTELEMENT {
            idx := op(ie, 2);
            if is_const_int(idx) && ap_is_zero(cf_ap(idx)) {
                mask := shuffle_mask(v);
                for mask if it != 0 && it != 0xFFFF_FFFF return NONE;   // m_ZeroMask: 0 or poison
                return op(ie, 1);
            }
        }
    }
    return NONE;
}

int_props :: (c: Value_Id) -> u8 {
    a := cf_ap(c);
    if ap_is_power_of_2(a) return OP_POWER_OF_2;
    if ap_is_negated_power_of_2(a) return OP_NEGATED_POWER_OF_2;
    return OP_NONE;
}

// TargetTransformInfo::getOperandInfo
tti_operand_info :: (v: Value_Id) -> Op_Info {
    k := vkind(v);
    if k == .C_UNDEF || k == .C_POISON return OI_ANY;
    if (k == .C_INT || k == .C_FP) && !is_vector_type(vtype(v)) {
        props: u8 = OP_NONE;
        if k == .C_INT props = int_props(v);
        return .{OK_UNIFORM_CONSTANT_VALUE, props};
    }
    info: u8 = OK_ANY_VALUE;
    props: u8 = OP_NONE;
    if is_inst(v) && inst_op(v) == .SHUFFLEVECTOR && sv_is_zero_elt_splat(v) info = OK_UNIFORM_VALUE;
    splat := vu_get_splat_value(v);
    if splat != NONE {
        sk := vkind(splat);
        if sk == .ARGUMENT || is_global_value(sk) info = OK_UNIFORM_VALUE;
        else if is_constant_kind(sk) {
            info = OK_UNIFORM_CONSTANT_VALUE;
            if sk == .C_INT props = int_props(splat);
        }
    } else if k == .C_DATA {
        info = OK_NON_UNIFORM_CONSTANT_VALUE;
        all_pow2 := true; all_neg := true;
        n := const_data_count(v);
        for e: 0..cast(s64) n - 1 {
            c := cf_elt(v, cast(u64) e);
            if vkind(c) == .C_INT {
                a := cf_ap(c);
                all_pow2 &= ap_is_power_of_2(a);
                all_neg &= ap_is_negated_power_of_2(a);
                if all_pow2 || all_neg continue;
            }
            all_pow2 = false; all_neg = false;
            break;
        }
        if all_pow2 props = OP_POWER_OF_2;
        if all_neg props = OP_NEGATED_POWER_OF_2;
    } else if k == .C_VECTOR || (k == .C_INT && is_vector_type(vtype(v))) || (k == .C_FP && is_vector_type(vtype(v))) {
        info = OK_NON_UNIFORM_CONSTANT_VALUE;
    }
    return .{info, props};
}

// TargetTransformInfo::getCastContextHint
tti_cast_context_hint :: (i: Value_Id) -> u8 {
    if i == NONE return CCH_NONE;
    ls_kind :: (v: Value_Id, ldst: Opcode, masked: string, gs: string) -> u8 {
        if !is_inst(v) return CCH_NONE;
        if inst_op(v) == ldst return CCH_NORMAL;
        id := call_iid(v);
        if id != NOT_INTRINSIC {
            if iid_name(id) == masked return CCH_MASKED;
            if iid_name(id) == gs return CCH_GATHER_SCATTER;
        }
        return CCH_NONE;
    }
    o := inst_op(i);
    if o == .ZEXT || o == .SEXT || o == .FPEXT return ls_kind(op(i, 0), .LOAD, "llvm.masked.load", "llvm.masked.gather");
    if o == .TRUNC || o == .FPTRUNC {
        if num_uses(i) == 1 return ls_kind(ir.u_user[ir.v_first_use[i]], .STORE, "llvm.masked.store", "llvm.masked.scatter");
    }
    return CCH_NONE;
}

iid_name :: (id: Intrinsic_Id) -> string { return INTRINSIC_INFOS[id - 1].name; }

// ---------------------------------------------------------------- ShuffleVectorInst mask predicates

sv_num_src_elts :: (s: Value_Id) -> s64 { return cast(s64) type_count(vtype(op(s, 0))); }
// isSingleSourceMask / isIdentityMask / ... (ShuffleVectorInst static helpers, Instructions.cpp)
svm_is_single_source :: (mask: [] s32, n: s64) -> bool {
    uses_lhs := false; uses_rhs := false;
    for mask {
        if it < 0 continue;
        if it < n uses_lhs = true; else uses_rhs = true;
        if uses_lhs && uses_rhs return false;
    }
    return uses_lhs || uses_rhs;
}
svm_is_identity_no_checks :: (mask: [] s32, n: s64) -> bool {
    if !svm_is_single_source(mask, n) return false;
    for mask { if it < 0 continue; if it != it_index && it != n + it_index return false; }
    return true;
}
svm_is_identity :: (mask: [] s32, n: s64) -> bool { if mask.count != n return false; return svm_is_identity_no_checks(mask, n); }
svm_is_reverse :: (mask: [] s32, n: s64) -> bool {
    if mask.count != n || !svm_is_single_source(mask, n) return false;
    if n < 2 return false;
    for mask { if it < 0 continue; if it != n - it_index - 1 && it != n + n - it_index - 1 return false; }
    return true;
}
svm_is_zero_elt_splat :: (mask: [] s32, n: s64) -> bool {
    if mask.count != n || !svm_is_single_source(mask, n) return false;
    for mask { if it < 0 continue; if it != 0 && it != n return false; }
    return true;
}
svm_is_select :: (mask: [] s32, n: s64) -> bool {
    if mask.count != n return false;
    if svm_is_single_source(mask, n) return false;
    for mask { if it < 0 continue; if it != it_index && it != n + it_index return false; }
    return true;
}
svm_is_transpose :: (mask: [] s32, n: s64) -> bool {
    if mask.count != n return false;
    sz := mask.count;
    if sz < 2 || (sz & (sz - 1)) != 0 return false;
    if mask[0] != 0 && mask[0] != 1 return false;
    if mask[1] - mask[0] != sz return false;
    for i: 2..sz-1 {
        if mask[i] == -1 return false;
        if mask[i] - mask[i - 2] != 2 return false;
    }
    return true;
}
svm_is_splice :: (mask: [] s32, n: s64) -> (bool, s32) {
    if mask.count != n return false, 0;
    start: s64 = -1;
    for mask {
        if it < 0 continue;
        if start == -1 {
            if it < it_index || n <= it - it_index return false, 0;
            start = it - it_index;
        } else if it != start + it_index return false, 0;
    }
    if start == -1 return false, 0;
    return true, cast(s32) start;
}
svm_is_extract_subvector :: (mask: [] s32, n: s64) -> (bool, s32) {
    if !svm_is_single_source(mask, n) return false, 0;
    if n <= mask.count return false, 0;
    sub_index: s64 = -1;
    for mask {
        if it < 0 continue;
        offset := (it % n) - it_index;
        if sub_index < 0 sub_index = offset;
        else if sub_index != offset return false, 0;
    }
    if 0 <= sub_index && sub_index + mask.count <= n return true, cast(s32) sub_index;
    return false, 0;
}
// ShuffleVectorInst::isInsertSubvectorMask(Mask, NumSrcElts): (ok, NumSubElts, Index)
svm_is_insert_subvector :: (mask: [] s32, n: s64) -> (bool, s32, s32) {
    nmask := mask.count;
    if nmask < n return false, 0, 0;
    if svm_is_single_source(mask, n) return false, 0, 0;
    src0_lo: s64 = -1; src1_lo: s64 = -1; src0_hi: s64 = 0; src1_hi: s64 = 0;
    id0 := true; id1 := true;
    for m, i: mask {
        if m < 0 continue;
        if m < n {
            if src0_lo < 0 src0_lo = i;
            src0_hi = i + 1;
            id0 &= m == i;
        } else {
            if src1_lo < 0 src1_lo = i;
            src1_hi = i + 1;
            id1 &= m == i + n;
        }
    }
    if src0_lo < 0 || src1_lo < 0 return false, 0, 0;
    if id0 {
        sub := array_view(mask, src1_lo, src1_hi - src1_lo);
        if svm_is_identity_no_checks(sub, n) return true, cast(s32) sub.count, cast(s32) src1_lo;
    }
    if id1 {
        sub := array_view(mask, src0_lo, src0_hi - src0_lo);
        if svm_is_identity_no_checks(sub, n) return true, cast(s32) sub.count, cast(s32) src0_lo;
    }
    return false, 0, 0;
}

shuffle_mask_s32 :: (s: Value_Id) -> [] s32 {
    m := shuffle_mask(s);
    out := NewArray(m.count, s32,, allocator = temp);
    for m out[it_index] = ifx it == 0xFFFF_FFFF then cast(s32) -1 else cast(s32) it;
    return out;
}
sv_is_zero_elt_splat :: (s: Value_Id) -> bool { return svm_is_zero_elt_splat(shuffle_mask_s32(s), sv_num_src_elts(s)); }

// ---------------------------------------------------------------- the cost queries

tti_arith_cost :: (t: *Tti, opc: Opcode, ty: Type_Id, kind: s64, o1 := OI_ANY, o2 := OI_ANY, args: [] Value_Id = .[], cxt: Value_Id = NONE) -> Cost {
    if t.kind == .X86 return x86_arith_cost(t, opc, ty, kind, o1, o2, args, cxt);
    return base_arith_cost(opc, ty, kind, args);
}
// TargetTransformInfoImplBase::getArithmeticInstrCost
base_arith_cost :: (opc: Opcode, ty: Type_Id, kind: s64, args: [] Value_Id) -> Cost {
    if opc == .FDIV || opc == .FREM || opc == .SDIV || opc == .SREM || opc == .UDIV || opc == .UREM return TCC_EXPENSIVE;
    if opc == .AND || opc == .OR {
        for args if call_iid(it) != NOT_INTRINSIC && iid_name(call_iid(it)) == "llvm.experimental.widenable.condition" return TCC_FREE;
    }
    if kind == TCK_LATENCY && is_fp_type(scalar_type(ty)) return 3;
    return 1;
}

tti_cast_cost :: (t: *Tti, opc: Opcode, dst: Type_Id, src: Type_Id, cch: u8, kind: s64, i: Value_Id = NONE) -> Cost {
    if t.kind == .X86 return x86_cast_cost(t, opc, dst, src, cch, kind, i);
    return base_cast_cost(opc, dst, src);
}
// TargetTransformInfoImplBase::getCastInstrCost
base_cast_cost :: (opc: Opcode, dst: Type_Id, src: Type_Id) -> Cost {
    if opc == {
        case .INTTOPTR;
            s := type_bits(scalar_type(src));
            if dl_is_legal_integer(s) && s <= dl_type_size_bits(scalar_type(dst)) return 0;
        case .PTRTOADDR;
            d := type_bits(scalar_type(dst));
            if dl_is_legal_integer(d) return 0;
        case .PTRTOINT;
            d := type_bits(scalar_type(dst));
            if dl_is_legal_integer(d) && d >= dl_type_size_bits(scalar_type(src)) return 0;
        case .BITCAST;
            if dst == src || (type_kind(dst) == .PTR && type_kind(src) == .PTR) return 0;
        case .TRUNC;
            if type_kind(dst) != .SVECTOR && dl_is_legal_integer(dl_type_size_bits(dst)) return 0;
    }
    return 1;
}

tti_cf_cost :: (t: *Tti, opc: Opcode, kind: s64, i: Value_Id = NONE) -> Cost {
    if t.kind == .X86 {
        // X86TTIImpl::getCFInstrCost
        if kind != TCK_RECIP_THROUGHPUT return ifx opc == .PHI then TCC_FREE else TCC_BASIC;
        return TCC_FREE;   // branches are assumed to be predicted
    }
    if opc == .PHI && kind != TCK_RECIP_THROUGHPUT return 0;
    return 1;
}

tti_cmp_sel_cost :: (t: *Tti, opc: Opcode, val_ty: Type_Id, cond_ty: Type_Id, pred: u8, kind: s64, o1 := OI_ANY, o2 := OI_ANY, i: Value_Id = NONE) -> Cost {
    if t.kind == .X86 return x86_cmp_sel_cost(t, opc, val_ty, cond_ty, pred, kind, o1, o2, i);
    return 1;
}

tti_memory_op_cost :: (t: *Tti, opc: Opcode, ty: Type_Id, align: u64, addrspace: u32, kind: s64, opinfo := OI_ANY, i: Value_Id = NONE) -> Cost {
    if t.kind == .X86 return x86_memory_op_cost(t, opc, ty, align, addrspace, kind, opinfo, i);
    return 1;
}

tti_insert_extract_value_cost :: (t: *Tti, opc: Opcode, kind: s64) -> Cost {
    if opc == .INSERTVALUE && kind != TCK_RECIP_THROUGHPUT return TCC_BASIC;
    return TCC_FREE;
}

tti_vector_inst_cost :: (t: *Tti, i: Value_Id, ty: Type_Id, kind: s64, index: u32) -> Cost {
    if t.kind == .X86 return x86_vector_inst_cost(t, inst_op(i), ty, kind, index, i);
    return 1;
}

tti_shuffle_cost :: (t: *Tti, sk: s64, dst: Type_Id, src: Type_Id, mask: [] s32, kind: s64, index: s64, sub_ty: Type_Id, args: [] Value_Id, cxt: Value_Id) -> Cost {
    if t.kind == .X86 return x86_shuffle_cost(t, sk, dst, src, mask, kind, index, sub_ty, args, cxt);
    return 1;
}
tti_replication_shuffle_cost :: (t: *Tti, elt_ty: Type_Id, factor: s64, vf: s64, dem_dst: [] bool, kind: s64) -> Cost {
    if t.kind == .X86 return x86_replication_shuffle_cost(t, elt_ty, factor, vf, dem_dst, kind);
    return 1;
}

FREE_INTRINSICS :: string.["llvm.allow.runtime.check", "llvm.allow.ubsan.check", "llvm.annotation", "llvm.assume",
    "llvm.sideeffect", "llvm.pseudoprobe", "llvm.arithmetic.fence", "llvm.dbg.assign", "llvm.dbg.declare",
    "llvm.dbg.value", "llvm.dbg.label", "llvm.invariant.start", "llvm.invariant.end", "llvm.launder.invariant.group",
    "llvm.strip.invariant.group", "llvm.is.constant", "llvm.lifetime.start", "llvm.lifetime.end",
    "llvm.experimental.noalias.scope.decl", "llvm.objectsize", "llvm.ptr.annotation", "llvm.var.annotation",
    "llvm.experimental.gc.result", "llvm.experimental.gc.relocate", "llvm.coro.alloc", "llvm.coro.begin",
    "llvm.coro.begin.custom.abi", "llvm.coro.dead", "llvm.coro.id", "llvm.coro.id.async", "llvm.coro.id.retcon",
    "llvm.coro.id.retcon.once", "llvm.coro.noop", "llvm.coro.free", "llvm.coro.end", "llvm.coro.frame",
    "llvm.coro.size", "llvm.coro.align", "llvm.coro.suspend", "llvm.coro.subfn.addr", "llvm.threadlocal.address",
    "llvm.experimental.widenable.condition", "llvm.ssa.copy"];
is_free_intrinsic :: (id: Intrinsic_Id) -> bool {
    n := iid_name(id);
    for FREE_INTRINSICS if it == n return true;
    return false;
}

tti_intrinsic_cost :: (t: *Tti, ica: *Ica, kind: s64) -> Cost {
    if t.kind == .X86 return x86_intrinsic_cost(t, ica, kind);
    return base_intrinsic_cost(ica);
}
// TargetTransformInfoImplBase::getIntrinsicInstrCost
base_intrinsic_cost :: (ica: *Ica) -> Cost {
    if is_free_intrinsic(ica.id) return 0;
    if ica.id == IID_BSWAP {
        if !is_vector_type(ica.ret) {
            b := dl_type_size_bits(ica.ret);
            if (b & (b - 1)) != 0 return COST_INVALID;
        }
    }
    return 1;
}

// TargetTransformInfoImplCRTPBase::getGEPCost
tti_gep_cost :: (t: *Tti, src_ty: Type_Id, ptr: Value_Id, idx: [] Value_Id, access_ty: Type_Id, kind: s64) -> Cost {
    base := strip_pointer_casts(ptr);
    base_gv: Value_Id = ifx is_global_value(vkind(base)) then base else NONE;
    has_base_reg := base_gv == NONE;
    ptr_bits := cast(u32) dl_type_size_bits(vtype(ptr));
    offset := ap_zero(ptr_bits);
    scale: s64 = 0;
    if idx.count == 0 return ifx base_gv == NONE then TCC_FREE else TCC_BASIC;
    cur := src_ty;     // gep_type_begin: the first index steps over the source element type
    target_ty: Type_Id = NONE;
    for v, k: idx {
        // indexed type at this position
        struct_ty: Type_Id = NONE;
        if k == 0 target_ty = src_ty;
        else {
            if type_kind(cur) == .STRUCT { struct_ty = cur; }
            target_ty = NONE;
        }
        ci: Value_Id = NONE;
        if is_const_int(v) && !is_vector_type(vtype(v)) ci = v;
        else {
            s := vu_get_splat_value(v);
            if s != NONE && is_const_int(s) ci = s;
        }
        if k > 0 && type_kind(cur) == .STRUCT {
            field := ap_zext_value(cf_ap(ci));
            offset = ap_add(offset, ap_from_u64(ptr_bits, dl_struct_offset(cur, cast(u32) field)));
            target_ty = type_sub(cur, cast(u32) field);
        } else {
            elt_ty := ifx k == 0 then src_ty else type_elem(cur);
            target_ty = elt_ty;
            if type_kind(elt_ty) == .SVECTOR return TCC_BASIC;
            esize := cast(s64) dl_type_alloc_size(elt_ty);
            if ci != NONE {
                c := ap_sext_or_trunc(cf_ap(ci), ptr_bits);
                offset = ap_add(offset, ap_mul(c, ap_from_s64(ptr_bits, esize)));
            } else {
                if scale != 0 return TCC_BASIC;
                scale = esize;
            }
        }
        cur = target_ty;
    }
    at := access_ty;
    if at == NONE at = target_ty;
    off := ap_sext_value(ap_sext_or_trunc(offset, 64));
    if tti_is_legal_addressing_mode(t, at, base_gv, off, has_base_reg, scale, ptr_addrspace(vtype(ptr))) return TCC_FREE;
    return TCC_BASIC;
}
ptr_addrspace :: (t: Type_Id) -> u32 { return cast(u32) ir.types[scalar_type(t)].a; }

tti_is_legal_addressing_mode :: (t: *Tti, ty: Type_Id, base_gv: Value_Id, offset: s64, has_base_reg: bool, scale: s64, addrspace: u32) -> bool {
    if t.kind == .X86 return x86_is_legal_addressing_mode(*t.xl, ty, base_gv, offset, has_base_reg, scale, addrspace);
    // TargetTransformInfoImplBase::isLegalAddressingMode
    return base_gv == NONE && offset == 0 && (scale == 0 || scale == 1);
}

// Value::getAccessType (Instruction of the GEP's single user)
inst_access_type :: (u: Value_Id) -> Type_Id {
    o := inst_op(u);
    if o == .LOAD return vtype(u);
    if o == .STORE return vtype(op(u, 0));
    if o == .ATOMICRMW return vtype(op(u, 1));
    if o == .CMPXCHG return vtype(op(u, 1));
    if o == .CALL || o == .INVOKE {
        id := call_iid(u);
        if id != NOT_INTRINSIC {
            n := iid_name(id);
            if n == "llvm.masked.load" || n == "llvm.masked.gather" return vtype(u);
            if n == "llvm.masked.store" || n == "llvm.masked.scatter" return vtype(op(u, 0));
        }
    }
    return NONE;
}

// TargetTransformInfo::getInstructionCost(U, CostKind) (operands = U's operands)
tti_instruction_cost :: (t: *Tti, u: Value_Id, kind: s64) -> Cost {
    if is_call_base(u) && call_iid(u) == NOT_INTRINSIC {
        f := call_called_function(u);
        if f != NONE {
            if !tti_is_lowered_to_call(f) return TCC_BASIC;
            return TCC_BASIC * (cast(Cost) func_nparams(glob(f).value_type) + 1);
        }
        return TCC_BASIC * (cast(Cost) call_num_args(u) + 1);
    }
    ty := vtype(u);
    opc := inst_op(u);
    if opc == {
        case .CALL;
            ica := ica_from_call(u);
            return tti_intrinsic_cost(t, *ica, kind);
        case .BR; #through;
        case .CONDBR; #through;
        case .RET; #through;
        case .PHI; #through;
        case .SWITCH;
            return tti_cf_cost(t, opc, kind, u);
        case .FREEZE; return TCC_FREE;
        case .EXTRACTVALUE; #through;
        case .INSERTVALUE; return tti_insert_extract_value_cost(t, opc, kind);
        case .ALLOCA; if is_static_alloca(u) return TCC_FREE;
        case .GEP;
            access: Type_Id = NONE;
            // GEP->hasOneUser(): all uses by the same user
            if has_uses(u) {
                first_user := ir.u_user[ir.v_first_use[u]];
                one := true;
                x := ir.v_first_use[u];
                while x != NONE { if ir.u_user[x] != first_user { one = false; break; } x = ir.u_next[x]; }
                if one access = inst_access_type(first_user);
            }
            n := nops(u);
            idx := NewArray(n - 1, Value_Id,, allocator = temp);
            for k: 1..cast(s64) n - 1 idx[k - 1] = op(u, cast(u32) k);
            return tti_gep_cost(t, inst(u).ty2, op(u, 0), idx, access, kind);
        case .ADD; #through; case .FADD; #through; case .SUB; #through; case .FSUB; #through; case .MUL; #through;
        case .FMUL; #through; case .UDIV; #through; case .SDIV; #through; case .FDIV; #through; case .UREM; #through;
        case .SREM; #through; case .FREM; #through; case .SHL; #through; case .LSHR; #through; case .ASHR; #through;
        case .AND; #through; case .OR; #through; case .XOR; #through; case .FNEG;
            o1 := tti_operand_info(op(u, 0));
            o2 := OI_ANY;
            if opc != .FNEG o2 = tti_operand_info(op(u, 1));
            args: [..] Value_Id; args.allocator = temp;
            for k: 0..cast(s64) nops(u) - 1 array_add(*args, op(u, cast(u32) k));
            return tti_arith_cost(t, opc, ty, kind, o1, o2, args, u);
        case .INTTOPTR; #through; case .PTRTOADDR; #through; case .PTRTOINT; #through; case .SITOFP; #through;
        case .UITOFP; #through; case .FPTOUI; #through; case .FPTOSI; #through; case .TRUNC; #through;
        case .FPTRUNC; #through; case .BITCAST; #through; case .FPEXT; #through; case .SEXT; #through;
        case .ZEXT; #through; case .ADDRSPACECAST;
            return tti_cast_cost(t, opc, ty, vtype(op(u, 0)), tti_cast_context_hint(u), kind, u);
        case .STORE;
            return tti_memory_op_cost(t, opc, vtype(op(u, 0)), inst(u).align, ptr_addrspace(vtype(op(u, 1))), kind, tti_operand_info(op(u, 0)), u);
        case .LOAD;
            lt := ty;
            if kind == TCK_CODE_SIZE && num_uses(u) == 1 && !is_vector_type(lt) {
                user := ir.u_user[ir.v_first_use[u]];
                if is_inst(user) && inst_op(user) == .TRUNC lt = vtype(user);
            }
            return tti_memory_op_cost(t, opc, lt, inst(u).align, ptr_addrspace(vtype(op(u, 0))), kind, OI_ANY, u);
        case .SELECT;
            okA, a0, a1 := pm_logical_and(u);
            okO, b0, b1 := pm_logical_or(u);
            if okA || okO {
                x := ifx okA then a0 else b0;
                y := ifx okA then a1 else b1;
                args := Value_Id.[x, y];
                return tti_arith_cost(t, ifx okO then Opcode.OR else .AND, ty, kind, tti_operand_info(x), tti_operand_info(y), args, u);
            }
            return tti_cmp_sel_cost(t, opc, ty, vtype(op(u, 0)), BAD_ICMP_PREDICATE, kind, tti_operand_info(op(u, 1)), tti_operand_info(op(u, 2)), u);
        case .ICMP; #through;
        case .FCMP;
            return tti_cmp_sel_cost(t, opc, vtype(op(u, 0)), ty, inst(u).pred, kind, tti_operand_info(op(u, 0)), tti_operand_info(op(u, 1)), u);
        case .INSERTELEMENT;
            idx: u32 = 0xFFFF_FFFF;
            c := op(u, 2);
            if is_const_int(c) && ap_active_bits(cf_ap(c)) <= 32 idx = cast(u32) ap_zext_value(cf_ap(c));
            return tti_vector_inst_cost(t, u, ty, kind, idx);
        case .EXTRACTELEMENT;
            idx: u32 = 0xFFFF_FFFF;
            c := op(u, 1);
            if is_const_int(c) && ap_active_bits(cf_ap(c)) <= 32 idx = cast(u32) ap_zext_value(cf_ap(c));
            return tti_vector_inst_cost(t, u, vtype(op(u, 0)), kind, idx);
        case .SHUFFLEVECTOR;
            return tti_shuffle_instruction_cost(t, u, kind);
    }
    return TCC_BASIC;
}

// the ShuffleVector case of getInstructionCost
tti_shuffle_instruction_cost :: (t: *Tti, u: Value_Id, kind: s64) -> Cost {
    vec_ty := vtype(u);
    src_ty := vtype(op(u, 0));
    mask := shuffle_mask_s32(u);
    n := cast(s64) type_count(src_ty);
    ops := Value_Id.[op(u, 0), op(u, 1)];
    all_undef := true;
    for mask if it >= 0 { all_undef = false; break; }
    if all_undef return TCC_FREE;
    if mask.count != n {
        increases := mask.count > n;
        if increases {
            // isIdentityWithPadding
            ok := true;
            for k: 0..n-1 { m := mask[k]; if m >= 0 && m != k { ok = false; break; } }
            if ok for k: n..mask.count-1 if mask[k] >= 0 { ok = false; break; }
            if ok return TCC_FREE;
        }
        is_ext, sub_index := svm_is_extract_subvector(mask, n);
        if is_ext return tti_shuffle_cost(t, SK_EXTRACT_SUBVECTOR, vec_ty, src_ty, mask, kind, sub_index, vec_ty, ops, u);
        is_ins, nsub, ins_index := svm_is_insert_subvector(mask, n);
        if is_ins return tti_shuffle_cost(t, SK_INSERT_SUBVECTOR, vec_ty, src_ty, mask, kind, ins_index, type_vector(cast(u64) nsub, type_elem(vec_ty), false), ops, u);
        is_rep, rf := svm_is_replication_vf(mask, n);
        if is_rep {
            dem := NewArray(mask.count, bool,, temp);
            for mask dem[it_index] = it != -1;
            return tti_replication_shuffle_cost(t, type_elem(src_ty), rf, n, dem, kind);
        }
        unary := is_undef_value(op(u, 1));
        adj: [..] s32; adj.allocator = temp;
        for mask array_add(*adj, it);
        if increases {
            for * adj if it.* >= n it.* = cast(s32) (it.* + (mask.count - n));
            return tti_shuffle_cost(t, ifx unary then SK_PERMUTE_SINGLE_SRC else SK_PERMUTE_TWO_SRC, vec_ty, vec_ty, adj, kind, 0, NONE, ops, u);
        }
        while adj.count < n array_add(*adj, -1);
        sc := tti_shuffle_cost(t, ifx unary then SK_PERMUTE_SINGLE_SRC else SK_PERMUTE_TWO_SRC, src_ty, src_ty, adj, kind, 0, NONE, ops, u);
        em := NewArray(mask.count, s32,, temp);
        for * em it.* = cast(s32) it_index;
        return cost_add(sc, tti_shuffle_cost(t, SK_EXTRACT_SUBVECTOR, vec_ty, src_ty, em, kind, 0, vec_ty, .[], u));
    }
    if svm_is_identity(mask, n) return TCC_FREE;
    if svm_is_reverse(mask, n) return tti_shuffle_cost(t, SK_REVERSE, vec_ty, src_ty, mask, kind, 0, NONE, ops, u);
    if svm_is_transpose(mask, n) return tti_shuffle_cost(t, SK_TRANSPOSE, vec_ty, src_ty, mask, kind, 0, NONE, ops, u);
    if svm_is_zero_elt_splat(mask, n) return tti_shuffle_cost(t, SK_BROADCAST, vec_ty, src_ty, mask, kind, 0, NONE, ops, u);
    if svm_is_single_source(mask, n) return tti_shuffle_cost(t, SK_PERMUTE_SINGLE_SRC, vec_ty, src_ty, mask, kind, 0, NONE, ops, u);
    is_ins, nsub, sub_index := svm_is_insert_subvector(mask, n);
    if is_ins return tti_shuffle_cost(t, SK_INSERT_SUBVECTOR, vec_ty, src_ty, mask, kind, sub_index, type_vector(cast(u64) nsub, type_elem(vec_ty), false), ops, u);
    if svm_is_select(mask, n) return tti_shuffle_cost(t, SK_SELECT, vec_ty, src_ty, mask, kind, 0, NONE, ops, u);
    is_spl, spl := svm_is_splice(mask, n);
    if is_spl return tti_shuffle_cost(t, SK_SPLICE, vec_ty, src_ty, mask, kind, spl, NONE, ops, u);
    return tti_shuffle_cost(t, SK_PERMUTE_TWO_SRC, vec_ty, src_ty, mask, kind, 0, NONE, ops, u);
}

// ---------------------------------------------------------------- print<cost-model> (CostModel.cpp)

cost_model_get_cost :: (t: *Tti, i: Value_Id, kind: s64) -> Cost {
    if call_iid(i) != NOT_INTRINSIC && tti_opts.intrinsic_cost_strategy != 0 {
        ica := ica_from_call(i, tti_opts.intrinsic_cost_strategy == 2);
        return tti_intrinsic_cost(t, *ica, kind);
    }
    return tti_instruction_cost(t, i, kind);
}

cost_model_printer_run :: (f: Value_Id) {
    tti_decode_cl();
    t := tti_get(f);
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "Printing analysis 'Cost Model Analysis' for function '%':\n", vname(f));
    for b: fn_blocks(f) for i: block_insts(b) {
        append(*sb, "Cost Model: ");
        if tti_opts.cost_kind == 4 {
            append(*sb, "Found costs of ");
            r := cost_model_get_cost(t, i, TCK_RECIP_THROUGHPUT);
            c := cost_model_get_cost(t, i, TCK_CODE_SIZE);
            l := cost_model_get_cost(t, i, TCK_LATENCY);
            s := cost_model_get_cost(t, i, TCK_SIZE_AND_LATENCY);
            if r == c && r == l && r == s append(*sb, cost_to_string(r));
            else print_to_builder(*sb, "RThru:% CodeSize:% Lat:% SizeLat:%", cost_to_string(r), cost_to_string(c), cost_to_string(l), cost_to_string(s));
            print_to_builder(*sb, " for: %\n", inst_to_string(i));
        } else {
            k := ifx tti_opts.cost_kind < 0 then TCK_RECIP_THROUGHPUT else tti_opts.cost_kind;
            c := cost_model_get_cost(t, i, k);
            if cost_valid(c) print_to_builder(*sb, "Found an estimated cost of %", c);
            else append(*sb, "Invalid cost");
            print_to_builder(*sb, " for instruction: %\n", inst_to_string(i));
        }
    }
    print_stderr("%", builder_to_string(*sb));
}
