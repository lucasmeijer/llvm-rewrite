// Vector function variants: ported from llvm/lib/IR/VFABIDemangler.cpp (tryDemangleForVFABI, getVectorVariantNames,
// createFunctionType, setVectorVariantNames, VFShape::hasValidParameterList), include/llvm/IR/VFABIDemangler.h
// (VFParamKind, VFISAKind, VFParameter, VFShape, VFInfo), the VFDatabase class of include/llvm/Analysis/VectorUtils.h,
// and the vector-library half of llvm/lib/Analysis/TargetLibraryInfo.cpp (VecDesc, addVectorizableFunctions,
// addVectorizableFunctionsFromVecLib, isFunctionVectorizable, getVectorizedFunction, getVectorMappingInfo,
// getWidestVF) with opt's -vector-library option (lib/CodeGen/CommandFlags.cpp). The VecFuncs.def tables are
// gen_vecfuncs.jai (gen/gen_vecfuncs.py).
//
// API (LLVM name -> here):
//   VFABI::tryDemangleForVFABI(Name, FTy)        vfabi_try_demangle(name, fty) -> (bool, Vf_Info)
//   VFABI::getVectorVariantNames(CI, Out)        vfabi_get_vector_variant_names(call) -> [..] string
//   VFABI::createFunctionType(Info, ScalarFTy)   vfabi_create_function_type(*info, fty)
//   VFABI::setVectorVariantNames(CI, Names)      vfabi_set_vector_variant_names(call, names)
//   VFShape::get(FTy, EC, HasGlobalPred)         vf_shape_get(fty, vf, scalable, global_pred)
//   VFDatabase::getMappings(CI)                  vfdb_get_mappings(call) -> [..] Vf_Info
//   VFDatabase::hasMaskedVariant(CI, VF)         vfdb_has_masked_variant(call, has_vf, vf, scalable)
//   VFDatabase(CI).getVectorizedFunction(Shape)  vfdb_get_vectorized_function(call, *shape) -> Value_Id (NONE)
//   TLI.isFunctionVectorizable(Name)             tli_is_function_vectorizable(name)
//   TLI.getVectorMappingInfo(F, VF, Masked)      tli_get_vector_mapping_info(name, vf, scalable, masked) -> *Vec_Desc
//   TLI.getVectorizedFunction(F, VF, Masked)     tli_get_vectorized_function(name, vf, scalable, masked) -> string
//   TLI.getWidestVF(F, FixedVF, ScalableVF)      tli_get_widest_vf(name) -> (fixed, scalable)
//   VecDesc::getVectorFunctionABIVariantString   vec_desc_abi_variant_string(*desc)
// Every result lives in temp storage.

Vf_Param_Kind :: enum u8 {
    VECTOR; OMP_LINEAR; OMP_LINEAR_REF; OMP_LINEAR_VAL; OMP_LINEAR_UVAL; OMP_LINEAR_POS; OMP_LINEAR_VAL_POS;
    OMP_LINEAR_REF_POS; OMP_LINEAR_UVAL_POS; OMP_UNIFORM; GLOBAL_PREDICATE; UNKNOWN;
}
Vf_Isa :: enum u8 { ADVANCED_SIMD; SVE; RVV; SSE; AVX; AVX2; AVX512; LLVM; UNKNOWN; }
Vf_Param :: struct { pos: u32; kind: Vf_Param_Kind; step: s32; align: u64 = 1; }
Vf_Shape :: struct { vf: u32; scalable: bool; params: [..] Vf_Param; }
Vf_Info :: struct { shape: Vf_Shape; scalar_name: string; vector_name: string; isa: Vf_Isa; }

vf_shape_equal :: (a: *Vf_Shape, b: *Vf_Shape) -> bool {
    if a.vf != b.vf || a.scalable != b.scalable || a.params.count != b.params.count return false;
    for a.params {
        p := b.params[it_index];
        if it.pos != p.pos || it.kind != p.kind || it.step != p.step || it.align != p.align return false;
    }
    return true;
}
// VFShape::get(FTy, EC, HasGlobalPred)
vf_shape_get :: (fty: Type_Id, vf: u32, scalable: bool, global_pred: bool) -> Vf_Shape {
    s: Vf_Shape;
    s.vf = vf; s.scalable = scalable;
    s.params.allocator = temp;
    np := func_nparams(fty);
    for i: 0..cast(s64) np - 1 array_add(*s.params, .{pos = cast(u32) i, kind = .VECTOR});
    if global_pred array_add(*s.params, .{pos = np, kind = .GLOBAL_PREDICATE});
    return s;
}
// VFInfo::isMasked
vf_info_is_masked :: (i: *Vf_Info) -> bool {
    return i.shape.params.count > 0 && i.shape.params[i.shape.params.count - 1].kind == .GLOBAL_PREDICATE;
}

// ---------------------------------------------------------------- demangling (VFABIDemangler.cpp)

#scope_file
Vf_Parse_Ret :: enum u8 { OK; NONE; ERROR; }

consume_front :: (s: *string, p: string) -> bool {
    if !begins_with(s.*, p) return false;
    s.* = slice(s.*, p.count, s.count - p.count);
    return true;
}
// StringRef::consumeInteger(10, unsigned/uint64_t): at least one digit, no overflow
consume_unsigned :: (s: *string) -> (bool, u64) {
    n := 0;
    v: u64 = 0;
    while n < s.count && s.data[n] >= #char "0" && s.data[n] <= #char "9" {
        d := cast(u64) (s.data[n] - #char "0");
        if v > (0xFFFF_FFFF_FFFF_FFFF - d) / 10 return false, 0;
        v = v * 10 + d;
        n += 1;
    }
    if n == 0 return false, 0;
    s.* = slice(s.*, n, s.count - n);
    return true, v;
}
// StringRef::consumeInteger(10, unsigned): fails when the value does not fit
consume_u32 :: (s: *string) -> (bool, u32) {
    save := s.*;
    ok, v := consume_unsigned(s);
    if !ok || v > 0xFFFF_FFFF { s.* = save; return false, 0; }
    return true, cast(u32) v;
}
// StringRef::consumeInteger(10, int): consumeSignedInteger (an optional leading '-')
consume_s32 :: (s: *string) -> (bool, s32) {
    save := s.*;
    neg := consume_front(s, "-");
    ok, v := consume_unsigned(s);
    if !ok { s.* = save; return false, 0; }
    if neg {
        if v > 0x8000_0000 { s.* = save; return false, 0; }
        return true, cast(s32) (-cast(s64) v);
    }
    if v > 0x7FFF_FFFF { s.* = save; return false, 0; }
    return true, cast(s32) v;
}

// VFABI::getVFParamKindFromString
vf_param_kind_from_string :: (t: string) -> Vf_Param_Kind {
    if t == {
        case "v"; return .VECTOR;
        case "l"; return .OMP_LINEAR;
        case "R"; return .OMP_LINEAR_REF;
        case "L"; return .OMP_LINEAR_VAL;
        case "U"; return .OMP_LINEAR_UVAL;
        case "ls"; return .OMP_LINEAR_POS;
        case "Ls"; return .OMP_LINEAR_VAL_POS;
        case "Rs"; return .OMP_LINEAR_REF_POS;
        case "Us"; return .OMP_LINEAR_UVAL_POS;
        case "u"; return .OMP_UNIFORM;
    }
    fatal("internal: VFABI parameter token '%'", t);
    return .UNKNOWN;
}

try_parse_isa :: (s: *string) -> (Vf_Parse_Ret, Vf_Isa) {
    if s.count == 0 return .ERROR, .UNKNOWN;
    if consume_front(s, "_LLVM_") return .OK, .LLVM;
    isa: Vf_Isa = .UNKNOWN;
    if s.data[0] == {
        case #char "n"; isa = .ADVANCED_SIMD;
        case #char "s"; isa = .SVE;
        case #char "r"; isa = .RVV;
        case #char "b"; isa = .SSE;
        case #char "c"; isa = .AVX;
        case #char "d"; isa = .AVX2;
        case #char "e"; isa = .AVX512;
    }
    s.* = slice(s.*, 1, s.count - 1);
    return .OK, isa;
}
try_parse_mask :: (s: *string) -> (Vf_Parse_Ret, bool) {
    if consume_front(s, "M") return .OK, true;
    if consume_front(s, "N") return .OK, false;
    return .ERROR, false;
}
try_parse_vlen :: (s: *string, isa: Vf_Isa) -> (Vf_Parse_Ret, u32, bool) {
    if consume_front(s, "x") {
        if isa != .SVE && isa != .RVV return .ERROR, 0, false;
        return .OK, 0, true;
    }
    ok, vf := consume_u32(s);
    if !ok || vf == 0 return .ERROR, 0, false;
    return .OK, vf, false;
}
try_parse_linear_token_with_runtime_step :: (s: *string, token: string) -> (Vf_Parse_Ret, Vf_Param_Kind, s32) {
    if consume_front(s, token) {
        kind := vf_param_kind_from_string(token);
        ok, pos := consume_s32(s);
        if !ok return .ERROR, kind, 0;
        return .OK, kind, pos;
    }
    return .NONE, .UNKNOWN, 0;
}
try_parse_compile_time_linear_token :: (s: *string, token: string) -> (Vf_Parse_Ret, Vf_Param_Kind, s32) {
    if consume_front(s, token) {
        kind := vf_param_kind_from_string(token);
        negate := consume_front(s, "n");
        ok, step := consume_s32(s);
        if !ok step = 1;
        if negate step *= -1;
        return .OK, kind, step;
    }
    return .NONE, .UNKNOWN, 0;
}
try_parse_parameter :: (s: *string) -> (Vf_Parse_Ret, Vf_Param_Kind, s32) {
    if consume_front(s, "v") return .OK, .VECTOR, 0;
    if consume_front(s, "u") return .OK, .OMP_UNIFORM, 0;
    for t: string.["ls", "Rs", "Ls", "Us"] {
        r, k, p := try_parse_linear_token_with_runtime_step(s, t);
        if r != .NONE return r, k, p;
    }
    for t: string.["l", "R", "L", "U"] {
        r, k, p := try_parse_compile_time_linear_token(s, t);
        if r == .OK return r, k, p;
    }
    return .NONE, .UNKNOWN, 0;
}
try_parse_align :: (s: *string) -> (Vf_Parse_Ret, u64) {
    if consume_front(s, "a") {
        ok, v := consume_unsigned(s);
        if !ok return .ERROR, 1;
        if !has_single_bit(v) return .ERROR, 1;
        return .OK, v;
    }
    return .NONE, 1;
}
// getElementCountForTy(ISA, Ty): the known minimum of the scalable element count (0 = none)
element_count_for_ty :: (t: Type_Id) -> u32 {
    k := type_kind(t);
    if (k == .INT && type_int_width(t) == 64) || k == .DOUBLE || k == .PTR return 2;
    if (k == .INT && type_int_width(t) == 32) || k == .FLOAT return 4;
    if (k == .INT && type_int_width(t) == 16) || k == .HALF || k == .BFLOAT return 8;
    if k == .INT && type_int_width(t) == 8 return 16;
    return 0;
}
// getScalableECFromSignature (0 = none)
scalable_ec_from_signature :: (fty: Type_Id, params: [] Vf_Param) -> u32 {
    min_ec: u32 = 0xFFFF_FFFF;
    for params {
        if it.kind != .VECTOR continue;
        ec := element_count_for_ty(func_param(fty, it.pos));
        if ec == 0 return 0;
        if ec < min_ec min_ec = ec;
    }
    rt := func_ret(fty);
    if type_kind(rt) != .VOID {
        if type_kind(rt) == .STRUCT && (ir.types[rt].name.count != 0 || ir.types[rt].a != 0) return 0;   // !isUnpackedStructLiteral
        for contained_types(rt) {
            ec := element_count_for_ty(it);
            if ec == 0 return 0;
            if ec < min_ec min_ec = ec;
        }
    }
    if min_ec < 0xFFFF_FFFF return min_ec;
    return 0;
}
#scope_export

// VFABI::tryDemangleForVFABI(MangledName, FTy)
vfabi_try_demangle :: (mangled: string, fty: Type_Id) -> (bool, Vf_Info) {
    info: Vf_Info;
    original := mangled;
    vector_name := mangled;
    s := mangled;
    if !consume_front(*s, "_ZGV") return false, info;
    r, isa := try_parse_isa(*s);
    if r != .OK return false, info;
    r2, is_masked := try_parse_mask(*s);
    if r2 != .OK return false, info;
    r3, vf, scalable := try_parse_vlen(*s, isa);
    if r3 != .OK return false, info;
    params: [..] Vf_Param; params.allocator = temp;
    while true {
        pos := cast(u32) params.count;
        pr, kind, step := try_parse_parameter(*s);
        if pr == .ERROR return false, info;
        if pr != .OK break;
        ar, align := try_parse_align(*s);
        if ar == .ERROR return false, info;
        array_add(*params, .{pos, kind, step, align});
    }
    if params.count == 0 return false, info;
    if params.count != cast(s64) func_nparams(fty) return false, info;
    ec := vf;
    if scalable {
        ec = scalable_ec_from_signature(fty, params);
        if ec == 0 return false, info;
    }
    if !consume_front(*s, "_") return false, info;
    n := 0;
    while n < s.count && s.data[n] != #char "(" n += 1;
    scalar_name := slice(s, 0, n);
    if scalar_name.count == 0 return false, info;
    // MangledName.ltrim(ScalarName): drops every leading character that occurs in ScalarName
    in_set :: (c: u8, set: string) -> bool { for set if it == c return true; return false; }
    k := 0;
    while k < s.count && in_set(s.data[k], scalar_name) k += 1;
    s = slice(s, k, s.count - k);
    if consume_front(*s, "(") {
        if s.count == 0 || s.data[s.count - 1] != #char ")" return false, info;
        s.count -= 1;
        vector_name = s;
        if vector_name.count == 0 return false, info;
    }
    if isa == .LLVM && vector_name == original return false, info;
    if is_masked array_add(*params, .{pos = cast(u32) params.count, kind = .GLOBAL_PREDICATE});
    info.shape.vf = ec;
    info.shape.scalable = scalable;
    info.shape.params = params;
    info.scalar_name = scalar_name;
    info.vector_name = vector_name;
    info.isa = isa;
    return true, info;
}

// VFABI::getVectorVariantNames(CI, VariantMappings)
vfabi_get_vector_variant_names :: (c: Value_Id) -> [..] string {
    out: [..] string; out.allocator = temp;
    s := call_fn_str_attr(c, VFABI_MAPPINGS_ATTR_NAME);
    if s.count == 0 return out;
    // S.split(ListAttr, ","), then a SetVector (first occurrences, in order)
    parts: [..] string; parts.allocator = temp;
    start := 0;
    for i: 0..s.count {
        if i == s.count || s.data[i] == #char "," {
            p := slice(s, start, i - start);
            dup := false; for parts if it == p { dup = true; break; }
            if !dup array_add(*parts, p);
            start = i + 1;
        }
    }
    for parts {
        ok, info := vfabi_try_demangle(it, inst(c).ty2);
        if ok && module_get_function(info.vector_name) != NONE array_add(*out, it);
    }
    return out;
}
VFABI_MAPPINGS_ATTR_NAME :: "vector-function-abi-variant";

// VFABI::createFunctionType(Info, ScalarFTy)
vfabi_create_function_type :: (info: *Vf_Info, sfty: Type_Id) -> Type_Id {
    if info.shape.scalable fatal("vector function variants with scalable vectors are not supported yet");
    tys: [..] Type_Id; tys.allocator = temp;
    vf := cast(u64) info.shape.vf;
    spi: u32 = 0;
    for info.shape.params {
        if it.kind == .GLOBAL_PREDICATE { array_add(*tys, type_vector(vf, ir.t_i1, false)); continue; }
        t := func_param(sfty, spi); spi += 1;
        if it.kind == .VECTOR t = type_vector(vf, t, false);
        array_add(*tys, t);
    }
    rt := func_ret(sfty);
    if type_kind(rt) != .VOID rt = to_vectorized_ty(rt, vf);
    return type_func(rt, tys, false);
}
// toVectorizedTy(Ty, EC) for a fixed EC
to_vectorized_ty :: (t: Type_Id, vf: u64) -> Type_Id {
    if vf == 1 return t;   // EC.isScalar()
    if type_kind(t) == .STRUCT {
        n := cast(s64) type_nsub(t);
        e := NewArray(n, Type_Id,, temp);
        for k: 0..n-1 e[k] = type_vector(vf, type_sub(t, cast(u32) k), false);
        return type_literal_struct(e, false);
    }
    return type_vector(vf, t, false);
}

// VFABI::setVectorVariantNames(CI, VariantMappings)
vfabi_set_vector_variant_names :: (c: Value_Id, names: [] string) {
    if names.count == 0 return;
    sb: String_Builder;
    for names { if it_index > 0 append(*sb, ","); append(*sb, it); }
    a: Attr;
    a.kind = .STRING_ATTR; a.ty = NONE;
    a.key = VFABI_MAPPINGS_ATTR_NAME;
    a.val = builder_to_string(*sb);
    call_add_fn_attr(c, a);
}

// ---------------------------------------------------------------- VFDatabase (VectorUtils.h)

// VFDatabase::getMappings(CI) (getVFABIMappings)
vfdb_get_mappings :: (c: Value_Id) -> [..] Vf_Info {
    out: [..] Vf_Info; out.allocator = temp;
    f := call_called_function(c);
    if f == NONE return out;
    scalar_name := vname(f);
    for vfabi_get_vector_variant_names(c) {
        ok, info := vfabi_try_demangle(it, inst(c).ty2);
        if ok && info.scalar_name == scalar_name array_add(*out, info);
    }
    return out;
}
// VFDatabase::hasMaskedVariant(CI, VF)
vfdb_has_masked_variant :: (c: Value_Id, has_vf := false, vf: u32 = 0, scalable := false) -> bool {
    m := vfdb_get_mappings(c);
    for * m if !has_vf || (it.shape.vf == vf && it.shape.scalable == scalable) if vf_info_is_masked(it) return true;
    return false;
}
// VFDatabase(CI).getVectorizedFunction(Shape)
vfdb_get_vectorized_function :: (c: Value_Id, shape: *Vf_Shape) -> Value_Id {
    scalar_shape := vf_shape_get(inst(c).ty2, 1, false, false);
    if vf_shape_equal(shape, *scalar_shape) return call_called_function(c);
    m := vfdb_get_mappings(c);
    for * m if vf_shape_equal(*it.shape, shape) return module_get_function(it.vector_name);
    return NONE;
}
// !VFDatabase::getMappings(CI).empty()
call_has_vector_variants :: (c: Value_Id) -> bool { return vfdb_get_mappings(c).count > 0; }

// ---------------------------------------------------------------- TLI vector library (TargetLibraryInfo.cpp)

Vector_Library :: enum u8 { NoLibrary; Accelerate; DarwinLibSystemM; LIBMVEC; MASSV; SVML; SLEEFGNUABI; ArmPL; AMDLIBM; }
tli_vector_library: Vector_Library = .NoLibrary;   // opt -vector-library=<lib>

// the cl::opt<VectorLibrary> "vector-library" values
tli_parse_vector_library :: (value: string) -> bool {
    if value == {
        case "none"; tli_vector_library = .NoLibrary;
        case "Accelerate"; tli_vector_library = .Accelerate;
        case "Darwin_libsystem_m"; tli_vector_library = .DarwinLibSystemM;
        case "LIBMVEC"; tli_vector_library = .LIBMVEC;
        case "MASSV"; tli_vector_library = .MASSV;
        case "SVML"; tli_vector_library = .SVML;
        case "sleefgnuabi"; tli_vector_library = .SLEEFGNUABI;
        case "ArmPL"; tli_vector_library = .ArmPL;
        case "AMDLIBM"; tli_vector_library = .AMDLIBM;
        case; return false;
    }
    return true;
}

#scope_file
tli_vector_descs: [..] *Vec_Desc;   // VectorDescs, sorted by scalar name
tli_vector_descs_ready := false;

add_vectorizable_functions :: (fns: [] Vec_Desc) {
    for * fns array_add(*tli_vector_descs, it);
}
// addVectorizableFunctionsFromVecLib(VecLib, TargetTriple), then llvm::sort(VectorDescs, compareByScalarFnName)
// (the (scalar name, VF, masked) keys are unique in every library, so the unstable sort order does not matter)
tli_vector_descs_get :: () -> [] *Vec_Desc {
    if tli_vector_descs_ready return tli_vector_descs;
    tli_vector_descs_ready = true;
    arch := tli_get_baseline().triple.arch;
    if tli_vector_library == {
        case .Accelerate; add_vectorizable_functions(VECFUNCS_ACCELERATE);
        case .DarwinLibSystemM; add_vectorizable_functions(VECFUNCS_DARWIN_LIBSYSTEM_M);
        case .LIBMVEC;
            if arch == .x86 || arch == .x86_64 add_vectorizable_functions(VECFUNCS_LIBMVEC_X86);
            else if arch == .aarch64 || arch == .aarch64_be add_vectorizable_functions(VECFUNCS_LIBMVEC_AARCH64);
        case .MASSV; add_vectorizable_functions(VECFUNCS_MASSV);
        case .SVML; add_vectorizable_functions(VECFUNCS_SVML);
        case .SLEEFGNUABI;
            if arch == .aarch64 || arch == .aarch64_be {
                add_vectorizable_functions(VECFUNCS_SLEEFGNUABI_VF2);
                add_vectorizable_functions(VECFUNCS_SLEEFGNUABI_VF4);
                add_vectorizable_functions(VECFUNCS_SLEEFGNUABI_VFSCALABLE);
            } else if arch == .riscv64 add_vectorizable_functions(VECFUNCS_SLEEFGNUABI_VFSCALABLE_RISCV);
        case .ArmPL; if arch == .aarch64 || arch == .aarch64_be add_vectorizable_functions(VECFUNCS_ARMPL);
        case .AMDLIBM; add_vectorizable_functions(VECFUNCS_AMDLIBM);
    }
    // insertion sort by scalar name (stable; equal keys never decide a lookup)
    d := tli_vector_descs;
    for i: 1..d.count-1 {
        x := d[i]; j := i - 1;
        while j >= 0 && compare(d[j].scalar, x.scalar) > 0 { d[j + 1] = d[j]; j -= 1; }
        d[j + 1] = x;
    }
    return tli_vector_descs;
}
// sanitizeFunctionName: "" for names with a NUL byte; drops the \01 mangling escape
sanitize_function_name :: (name: string) -> string {
    if name.count == 0 return "";
    for name if it == 0 return "";
    if name.data[0] == 1 return slice(name, 1, name.count - 1);
    return name;
}
// lower_bound(VectorDescs, F, compareWithScalarFnName)
lower_bound_scalar :: (d: [] *Vec_Desc, name: string) -> s64 {
    lo := 0; hi := d.count;
    while lo < hi {
        mid := (lo + hi) / 2;
        if compare(d[mid].scalar, name) < 0 lo = mid + 1; else hi = mid;
    }
    return lo;
}
#scope_export

// VecDesc::getVectorFunctionABIVariantString
vec_desc_abi_variant_string :: (d: *Vec_Desc) -> string { return tprint("%_%(%)", d.vabi_prefix, d.scalar, d.vector); }

// TargetLibraryInfoImpl::isFunctionVectorizable(funcName)
tli_is_function_vectorizable :: (name_in: string) -> bool {
    name := sanitize_function_name(name_in);
    if name.count == 0 return false;
    d := tli_vector_descs_get();
    i := lower_bound_scalar(d, name);
    return i < d.count && d[i].scalar == name;
}
// TargetLibraryInfoImpl::getVectorMappingInfo(F, VF, Masked)
tli_get_vector_mapping_info :: (name_in: string, vf: u32, scalable: bool, masked: bool) -> *Vec_Desc {
    name := sanitize_function_name(name_in);
    if name.count == 0 return null;
    d := tli_vector_descs_get();
    i := lower_bound_scalar(d, name);
    while i < d.count && d[i].scalar == name {
        if d[i].vf == vf && d[i].scalable == scalable && d[i].masked == masked return d[i];
        i += 1;
    }
    return null;
}
// TargetLibraryInfoImpl::getVectorizedFunction(F, VF, Masked)
tli_get_vectorized_function :: (name: string, vf: u32, scalable: bool, masked: bool) -> string {
    d := tli_get_vector_mapping_info(name, vf, scalable, masked);
    if d return d.vector;
    return "";
}
// TargetLibraryInfoImpl::getWidestVF(ScalarF, FixedVF, ScalableVF): (fixed VF, scalable known-minimum VF)
tli_get_widest_vf :: (name_in: string) -> (u32, u32) {
    name := sanitize_function_name(name_in);
    fixed: u32 = 1; scal: u32 = 0;
    if name.count == 0 return fixed, scal;
    d := tli_vector_descs_get();
    i := lower_bound_scalar(d, name);
    while i < d.count && d[i].scalar == name {
        if d[i].scalable { if d[i].vf > scal scal = d[i].vf; }
        else if d[i].vf > fixed fixed = d[i].vf;
        i += 1;
    }
    return fixed, scal;
}
