// Alias analysis core: a port of
//   llvm/include/llvm/Support/ModRef.h            ModRefInfo, MemoryEffects queries (MemoryEffects is the u64 of
//                                                  parser.jai: 2 bits per IRMemLocation, MEM_UNKNOWN = all ModRef)
//   llvm/lib/Analysis/MemoryLocation.cpp          LocationSize, MemoryLocation::get*, getForArgument (+ TLI subset)
//   llvm/lib/Analysis/AliasAnalysis.cpp           AAResults aggregation (alias, getModRefInfo*, getMemoryEffects),
//                                                  isIdentifiedObject & co, getSyncEffects, callCapturesBefore
//   llvm/include/llvm/Analysis/AliasAnalysis.h    AliasResult, AAQueryInfo, SimpleAAQueryInfo, BatchAAResults
//   llvm/lib/Analysis/AliasAnalysisEvaluator.cpp  the aa-eval pass and its report
//   llvm/lib/Passes/PassBuilder.cpp               parseAAPipeline / buildDefaultAAPipeline
//
// Data-oriented: an AAResults is a small struct listing which alias analyses are registered (Aa_Kind, in priority
// order); every AAResults method loops over that list and `switch`es on the kind (BasicAA in basic_aa.jai, TBAA in
// tbaa.jai, ScopedNoAliasAA in scoped_noalias_aa.jai). An AAQueryInfo (Aa_Query) carries the per-query state: the
// alias cache, recursion depth, MayBeCrossIteration and the capture-analysis cache. SimpleAAQueryInfo = a fresh
// Aa_Query per top-level query (aa_*_once helpers); BatchAAResults = one Aa_Query reused for many queries.

// ---------------------------------------------------------------- ModRefInfo / MemoryEffects

MR_NO     :: cast(u8) 0;   // ModRefInfo::NoModRef
MR_REF    :: cast(u8) 1;
MR_MOD    :: cast(u8) 2;
MR_MODREF :: cast(u8) 3;

LOC_ARG          :: 0;   // IRMemLocation
LOC_INACCESSIBLE :: 1;
LOC_ERRNO        :: 2;
LOC_OTHER        :: 3;
LOC_TARGET0      :: 4;
LOC_TARGET1      :: 5;

ME_NONE :: cast(u64) 0;
me_read_only :: () -> u64 { return mem_all(1); }
me_write_only :: () -> u64 { return mem_all(2); }
me_loc :: (loc: s64, mr: u8) -> u64 { return mem_set(0, loc, mr); }
me_get :: inline (me: u64, loc: s64) -> u8 { return cast(u8) mem_get(me, loc); }
me_without_loc :: inline (me: u64, loc: s64) -> u64 { return mem_set(me, loc, 0); }
me_mod_ref :: (me: u64) -> u8 { r: u8; for l: 0..MEM_LOCS-1 r |= me_get(me, l); return r; }
me_only_accesses_arg_pointees :: (me: u64) -> bool { return me_without_loc(me, LOC_ARG) == 0; }
me_does_access_arg_pointees :: (me: u64) -> bool { return me_get(me, LOC_ARG) != MR_NO; }
me_only_accesses_inaccessible_or_target_mem :: (me: u64) -> bool {
    m := me_without_loc(me_without_loc(me, LOC_TARGET0), LOC_TARGET1);
    return me_without_loc(m, LOC_INACCESSIBLE) == 0;
}

// ---------------------------------------------------------------- AliasResult

AR_NO      :: cast(u8) 0;   // AliasResult::NoAlias
AR_MAY     :: cast(u8) 1;
AR_PARTIAL :: cast(u8) 2;
AR_MUST    :: cast(u8) 3;

Alias_Result :: struct {
    kind: u8;
    has_offset: bool;
    offset: s32;          // 23-bit signed in LLVM
}
ar :: inline (k: u8) -> Alias_Result { r: Alias_Result; r.kind = k; return r; }
ar_eq :: (a: Alias_Result, b: Alias_Result) -> bool { return a.kind == b.kind && a.has_offset == b.has_offset && a.offset == b.offset; }
ar_set_offset :: (r: *Alias_Result, off: s64) {
    if off >= -(1 << 22) && off < (1 << 22) { r.has_offset = true; r.offset = cast(s32) off; }
}
ar_swap :: (r: *Alias_Result, do_swap := true) {
    if do_swap && r.has_offset ar_set_offset(r, -cast(s64) r.offset);
}
ar_to_string :: (r: Alias_Result) -> string {
    if r.kind == {
        case AR_NO; return "NoAlias";
        case AR_MUST; return "MustAlias";
        case AR_MAY; return "MayAlias";
    }
    if r.has_offset return tprint("PartialAlias (off %)", r.offset);
    return "PartialAlias";
}

// ---------------------------------------------------------------- LocationSize

LS_BEFORE_OR_AFTER :: cast(u64) 0xFFFF_FFFF_FFFF_FFFF;
LS_SCALABLE_BIT    :: cast(u64) 0x4000_0000_0000_0000;
LS_AFTER           :: cast(u64) 0xBFFF_FFFF_FFFF_FFFE;   // (BeforeOrAfterPointer - 1) & ~ScalableBit
LS_MAP_TOMBSTONE   :: cast(u64) 0xFFFF_FFFF_FFFF_FFFC;
LS_IMPRECISE_BIT   :: cast(u64) 0x8000_0000_0000_0000;
LS_MAX_VALUE       :: cast(u64) 0x3FFF_FFFF_FFFF_FFFB;   // (MapTombstone - 1) & ~(ImpreciseBit | ScalableBit)

ls_precise :: (v: u64, scalable := false) -> u64 {
    if v > LS_MAX_VALUE return LS_AFTER;
    return v | (ifx scalable then LS_SCALABLE_BIT else 0);
}
ls_upper_bound :: (v: u64) -> u64 {
    if v == 0 return ls_precise(0);
    if v > LS_MAX_VALUE return LS_AFTER;
    return v | LS_IMPRECISE_BIT;
}
ls_has_value :: inline (s: u64) -> bool { return s != LS_AFTER && s != LS_BEFORE_OR_AFTER; }
ls_is_scalable :: inline (s: u64) -> bool { return (s & LS_SCALABLE_BIT) != 0; }
ls_value :: inline (s: u64) -> u64 { return s & ~(LS_IMPRECISE_BIT | LS_SCALABLE_BIT); }   // known min value
ls_is_precise :: inline (s: u64) -> bool { return (s & LS_IMPRECISE_BIT) == 0; }
ls_is_zero :: inline (s: u64) -> bool { return ls_has_value(s) && ls_value(s) == 0; }
ls_may_be_before_pointer :: inline (s: u64) -> bool { return s == LS_BEFORE_OR_AFTER; }
ls_union :: (a: u64, b: u64) -> u64 {
    if a == b return a;
    if a == LS_BEFORE_OR_AFTER || b == LS_BEFORE_OR_AFTER return LS_BEFORE_OR_AFTER;
    if a == LS_AFTER || b == LS_AFTER return LS_AFTER;
    if ls_is_scalable(a) || ls_is_scalable(b) return LS_AFTER;
    return ls_upper_bound(max(ls_value(a), ls_value(b)));
}
// LocationSize::precise(DL.getTypeStoreSize(T))
ls_of_type :: (t: Type_Id) -> u64 { return ls_precise(dl_type_store_size(t), type_is_scalable(t)); }
ls_to_string :: (s: u64) -> string {
    if s == LS_BEFORE_OR_AFTER return "LocationSize::beforeOrAfterPointer";
    if s == LS_AFTER return "LocationSize::afterPointer";
    if ls_is_precise(s) return tprint("LocationSize::precise(%)", ls_value(s));
    return tprint("LocationSize::upperBound(%)", ls_value(s));
}

// ---------------------------------------------------------------- MemoryLocation

// AA_Tags (AAMDNodes) and get_aa_metadata are in pass_sroa.jai

Mem_Loc :: struct {
    ptr: Value_Id = NONE;
    size: u64 = LS_BEFORE_OR_AFTER;
    tags: AA_Tags;
}
mloc :: (p: Value_Id, size: u64, tags := AA_Tags.{}) -> Mem_Loc { l: Mem_Loc; l.ptr = p; l.size = size; l.tags = tags; return l; }
mloc_before_or_after :: (p: Value_Id, tags := AA_Tags.{}) -> Mem_Loc { return mloc(p, LS_BEFORE_OR_AFTER, tags); }
mloc_after :: (p: Value_Id, tags := AA_Tags.{}) -> Mem_Loc { return mloc(p, LS_AFTER, tags); }

aa_metadata :: (i: Value_Id) -> AA_Tags { return get_aa_metadata(i); }   // Instruction::getAAMetadata

// MemoryLocation::get for load, store, va_arg, cmpxchg, atomicrmw
mloc_get :: (i: Value_Id) -> Mem_Loc {
    o := inst_op(i);
    if o == {
        case .LOAD; return mloc(op(i, 0), ls_of_type(vtype(i)), aa_metadata(i));
        case .STORE; return mloc(op(i, 1), ls_of_type(vtype(op(i, 0))), aa_metadata(i));
        case .VAARG; return mloc(op(i, 0), LS_AFTER, aa_metadata(i));
        case .CMPXCHG; return mloc(op(i, 0), ls_of_type(vtype(op(i, 1))), aa_metadata(i));
        case .ATOMICRMW; return mloc(op(i, 0), ls_of_type(vtype(op(i, 1))), aa_metadata(i));
    }
    fatal("internal: MemoryLocation::get on a non-memory instruction");
    return .{};
}
// MemoryLocation::getOrNone
mloc_get_or_none :: (i: Value_Id) -> (bool, Mem_Loc) {
    o := inst_op(i);
    if o == .LOAD || o == .STORE || o == .VAARG || o == .CMPXCHG || o == .ATOMICRMW return true, mloc_get(i);
    return false, .{};
}
// MemoryLocation::getForSource / getForDest of a memory intrinsic
mloc_for_source :: (mti: Value_Id) -> Mem_Loc { return mloc_for_argument(mti, 1, false); }
mloc_for_dest :: (mi: Value_Id) -> Mem_Loc { return mloc_for_argument(mi, 0, false); }

// MemoryLocation::getForDest(const CallBase *CB, TLI)
mloc_for_dest_call :: (cb: Value_Id) -> (bool, Mem_Loc) {
    write_me := call_memory_effects(cb) & me_write_only();
    if !me_only_accesses_arg_pointees(write_me) return false, .{};
    if call_num_bundles(cb) > 0 return false, .{};
    used_v: Value_Id = NONE;
    used_idx: s64 = -1;
    n := call_num_args(cb);
    if n > 0 for i: 0..n-1 {
        a := call_arg(cb, i);
        if !is_ptr_type(vtype(a)) continue;
        if call_param_only_reads(cb, i) continue;
        if used_v == NONE { used_v = a; used_idx = i; continue; }
        used_idx = -1;
        if used_v != a return false, .{};
    }
    if used_v == NONE return false, .{};
    if used_idx >= 0 return true, mloc_for_argument(cb, cast(u32) used_idx, true);
    return true, mloc_before_or_after(used_v, aa_metadata(cb));
}

// getKnownTypeFromMaskedOp: the store size of the active lanes when the mask is get.active.lane.mask(C0, C1)
masked_op_known_store_size :: (mask: Value_Id, vty: Type_Id) -> (bool, u64) {
    if call_iid(mask) != IID_GET_ACTIVE_LANE_MASK return false, 0;
    a := call_arg(mask, 0); b := call_arg(mask, 1);
    if vkind(a) != .C_INT || vkind(b) != .C_INT return false, 0;
    lo := const_ap(a); hi := const_ap(b);
    if ap_ule(hi, lo) return false, 0;
    ne := ap_sub(hi, lo);
    if ap_ugt_u64(ne, type_count(vty)) {
        if type_kind(vty) == .SVECTOR return false, 0;
        ne = ap_from_u64(ne.bits, type_count(vty));
    }
    elt := type_elem(vty);
    return true, dl_type_store_size(type_vector(ap_zext_value(ne), elt, false));
}

// MemoryLocation::getForArgument(Call, ArgIdx, TLI); `use_tli` = a TargetLibraryInfo was passed
mloc_for_argument :: (call: Value_Id, idx: u32, use_tli: bool) -> Mem_Loc {
    tags := aa_metadata(call);
    arg := call_arg(call, idx);
    id := call_iid(call);
    if id != NOT_INTRINSIC {
        if id == IID_MEMSET || id == IID_MEMCPY || id == IID_MEMCPY_INLINE || id == IID_MEMMOVE ||
           id == IID_MEMCPY_ELEMENT_UNORDERED_ATOMIC || id == IID_MEMMOVE_ELEMENT_UNORDERED_ATOMIC ||
           id == IID_MEMSET_ELEMENT_UNORDERED_ATOMIC {
            len := call_arg(call, 2);
            if vkind(len) == .C_INT return mloc(arg, ls_precise(ap_limited(const_ap(len))), tags);
            return mloc_after(arg, tags);
        }
        if id == IID_EXPERIMENTAL_MEMSET_PATTERN {
            len := call_arg(call, 2);
            if vkind(len) == .C_INT
                return mloc(arg, ls_precise(ap_limited(const_ap(len)) * dl_type_alloc_size(vtype(call_arg(call, 1)))), tags);
            return mloc_after(arg, tags);
        }
        if id == IID_LIFETIME_START || id == IID_LIFETIME_END {
            if !(is_inst(arg) && inst_op(arg) == .ALLOCA) return mloc_before_or_after(arg);
            ok, sz := alloca_allocation_size(arg);
            if ok return mloc(arg, ls_precise(sz), tags);
            if type_is_scalable(inst(arg).ty2) && is_scalar_const_int(op(arg, 0)) && ap_is_one(const_ap(op(arg, 0)))
                return mloc(arg, ls_precise(dl_type_alloc_size(inst(arg).ty2), true), tags);
            return mloc(arg, LS_AFTER, tags);
        }
        if id == IID_INVARIANT_START return mloc(arg, ls_precise(ap_limited(const_ap(call_arg(call, 0)))), tags);
        if id == IID_MASKED_LOAD {
            ty := vtype(call);
            ok, sz := masked_op_known_store_size(op(call, 1), ty);
            if ok return mloc(arg, ls_precise(sz), tags);
            return mloc(arg, ls_upper_bound_ts(ty), tags);
        }
        if id == IID_MASKED_STORE {
            ty := vtype(call_arg(call, 0));
            ok, sz := masked_op_known_store_size(op(call, 2), ty);
            if ok return mloc(arg, ls_precise(sz), tags);
            return mloc(arg, ls_upper_bound_ts(ty), tags);
        }
        if id == IID_INVARIANT_END {
            if idx == 0 return mloc(arg, ls_precise(0), tags);
            return mloc(arg, ls_precise(ap_limited(const_ap(call_arg(call, 1)))), tags);
        }
        if id == IID_MATRIX_COLUMN_MAJOR_LOAD || id == IID_MATRIX_COLUMN_MAJOR_STORE {
            is_load := id == IID_MATRIX_COLUMN_MAJOR_LOAD;
            stride := call_arg(call, ifx is_load then cast(u32) 1 else 2);
            rows := ap_limited(const_ap(call_arg(call, ifx is_load then cast(u32) 3 else 4)));
            cols := ap_limited(const_ap(call_arg(call, ifx is_load then cast(u32) 4 else 5)));
            if vkind(stride) != .C_INT return mloc(arg, LS_AFTER, tags);
            cs := ap_limited(const_ap(stride));
            vt := ifx is_load then vtype(call) else vtype(call_arg(call, 0));
            size := dl_type_alloc_size(scalar_type(vt)) * (cs * (cols - 1) + rows);
            if cs == rows return mloc(arg, ls_precise(size, type_kind(vt) == .SVECTOR), tags);
            return mloc(arg, ls_upper_bound(size), tags);
        }
    }
    if use_tli {
        lf := tli_lib_func_of_call(call);
        if lf == {
            case "strcpy"; #through; case "strcat"; #through; case "strncat";
                return mloc_after(arg, tags);
            case "__memset_chk"; #through; case "__memcpy_chk";
                size := LS_AFTER;
                len := call_arg(call, 2);
                if vkind(len) == .C_INT size = ls_upper_bound(ap_limited(const_ap(len)));
                return mloc(arg, size, tags);
            case "strncpy";
                size := LS_AFTER;
                len := call_arg(call, 2);
                if vkind(len) == .C_INT {
                    v := ap_limited(const_ap(len));
                    size = ifx idx == 0 then ls_precise(v) else ls_upper_bound(v);
                }
                return mloc(arg, size, tags);
            case "bcmp"; #through; case "memcmp"; #through; case "memchr";
                len := call_arg(call, 2);
                if vkind(len) == .C_INT return mloc(arg, ls_precise(ap_limited(const_ap(len))), tags);
                return mloc_after(arg, tags);
            case "memccpy";
                len := call_arg(call, 3);
                if vkind(len) == .C_INT return mloc(arg, ls_upper_bound(ap_limited(const_ap(len))), tags);
                return mloc_after(arg, tags);
        }
    }
    return mloc_before_or_after(arg, tags);
}
// LocationSize::upperBound(TypeSize) of a type's store size
ls_upper_bound_ts :: (t: Type_Id) -> u64 {
    if type_is_scalable(t) return LS_AFTER;
    return ls_upper_bound(dl_type_store_size(t));
}

// ---------------------------------------------------------------- TargetLibraryInfo: getLibFunc for calls

// The library functions alias analysis asks about, with their TargetLibraryInfo.td prototypes
// (p = ptr, i = int (i32), s = size_t (i64 on x86_64), v = void; first letter is the return type).
// memset_pattern4/8/16 are Darwin-only (TLI marks them unavailable on Linux), so they are not listed.
AA_LIB_FUNCS :: struct { name: string; proto: string; }.[
    .{"strcpy", "ppp"}, .{"strcat", "ppp"}, .{"strncat", "ppps"}, .{"__memset_chk", "ppiss"},
    .{"__memcpy_chk", "pppss"}, .{"strncpy", "ppps"}, .{"bcmp", "ipps"}, .{"memcmp", "ipps"},
    .{"memchr", "ppis"}, .{"memccpy", "pppis"},
];
// TLI.getLibFunc(*Call, F) && TLI.has(F) for the functions in AA_LIB_FUNCS: the name, or ""
tli_lib_func_of_call :: (call: Value_Id) -> string {
    if call_is_no_builtin(call) return "";
    f := call_called_function(call);
    if f == NONE || glob(f).intrinsic return "";
    name := vname(f);
    for AA_LIB_FUNCS {
        if it.name != name continue;
        if !tli_proto_matches(glob(f).value_type, it.proto) return "";
        if !tli_available(inst_fn(call), name) return "";
        return name;
    }
    return "";
}
tli_proto_matches :: (ft: Type_Id, proto: string) -> bool {
    if (ir.types[ft].flags & TYF_VARARG) != 0 return false;
    if func_nparams(ft) != cast(u32)(proto.count - 1) return false;
    ok :: (t: Type_Id, c: u8) -> bool {
        if c == #char "p" return is_ptr_type(t);
        if c == #char "i" return type_kind(t) == .INT && type_int_width(t) == 32;
        if c == #char "s" return type_kind(t) == .INT && type_int_width(t) == 64;
        if c == #char "v" return type_kind(t) == .VOID;
        return false;
    }
    if !ok(func_ret(ft), proto[0]) return false;
    for k: 1..proto.count-1 if !ok(func_param(ft, cast(u32)(k - 1)), proto[k]) return false;
    return true;
}
TLI_INT_SIZE :: 32;   // TLI.getIntSize() on x86_64

// MemoryBuiltins: isMallocOrCallocLikeFn (AllocationFnData entries other than strdup-like)
is_malloc_or_calloc_like_fn :: (v: Value_Id) -> bool {
    if !is_inst(v) || !is_call_base(v) return false;
    callee := mb_called_function(v);
    if callee == NONE return false;
    ft := glob(callee).value_type;
    if !is_ptr_type(func_ret(ft)) || glob(callee).intrinsic || !tli_available(value_function(v), vname(callee)) return false;
    for ALLOC_FNS {
        if it.name != vname(callee) continue;
        if begins_with(it.name, "strdup") || begins_with(it.name, "__strdup") || begins_with(it.name, "strndup") || begins_with(it.name, "__strndup") return false;
        if func_nparams(ft) != cast(u32) it.nparams return false;
        if it.fst >= 0 && !is_int32_or_64(func_param(ft, cast(u32) it.fst)) return false;
        return true;
    }
    return false;
}

// ---------------------------------------------------------------- object classification (AliasAnalysis.cpp)

// isNoAliasCall
aa_is_no_alias_call :: (v: Value_Id) -> bool { return is_inst(v) && is_call_base(v) && call_has_ret_attr(v, .NoAlias); }
is_no_alias_or_byval_argument :: (v: Value_Id) -> bool {
    if vkind(v) != .ARGUMENT return false;
    return arg_has_attr(v, .NoAlias) || arg_has_attr(v, .ByVal);
}
// isIdentifiedObject
is_identified_object :: (v: Value_Id) -> bool {
    if is_inst(v) && inst_op(v) == .ALLOCA return true;
    k := vkind(v);
    if k == .GLOBAL_VAR || k == .FUNCTION || k == .IFUNC return true;
    if aa_is_no_alias_call(v) return true;
    if is_no_alias_or_byval_argument(v) return true;
    return false;
}
// isIdentifiedFunctionLocal
is_identified_function_local :: (v: Value_Id) -> bool {
    return (is_inst(v) && inst_op(v) == .ALLOCA) || aa_is_no_alias_call(v) || is_no_alias_or_byval_argument(v);
}
// isBaseOfObject
is_base_of_object :: (v: Value_Id) -> bool { return (is_inst(v) && inst_op(v) == .ALLOCA) || vkind(v) == .GLOBAL_VAR; }
// isEscapeSource
is_escape_source :: (v: Value_Id) -> bool {
    if is_inst(v) {
        o := inst_op(v);
        if is_call_base(v) {
            if intrinsic_returns_aliasing_arg_without_capturing(v, false) return false;
            return !call_has_arg_with_additional_return_captures(v);
        }
        return o == .LOAD || o == .INTTOPTR || o == .EXTRACTVALUE || o == .EXTRACTELEMENT;
    }
    if vkind(v) == .C_EXPR && cexpr(v).op == .INTTOPTR return true;
    return false;
}
// isNotVisibleOnUnwind: (result, RequiresNoCaptureBeforeUnwind)
is_not_visible_on_unwind :: (obj: Value_Id) -> (bool, bool) {
    if is_inst(obj) && inst_op(obj) == .ALLOCA return true, false;
    if vkind(obj) == .ARGUMENT return arg_has_attr(obj, .ByVal) || arg_has_attr(obj, .DeadOnUnwind), false;
    if aa_is_no_alias_call(obj) return true, true;
    return false, false;
}
// isWritableObject: (result, ExplicitlyDereferenceableOnly)
is_writable_object :: (obj: Value_Id) -> (bool, bool) {
    if is_inst(obj) && inst_op(obj) == .ALLOCA return true, false;
    if vkind(obj) == .ARGUMENT {
        if arg_has_attr(obj, .Writable) && arg_has_attr(obj, .NoAlias) return true, true;
        return arg_has_attr(obj, .ByVal), false;
    }
    return aa_is_no_alias_call(obj), false;
}

// ---------------------------------------------------------------- AAResults and AAQueryInfo

Aa_Kind :: enum u8 { BASIC; SCOPED_NOALIAS; TBAA; GLOBALS; }

// -aa-pipeline (opt's NewPMDriver; "default" = buildDefaultAAPipeline)
aa_pipeline: struct {
    is_default := true;
    kinds: [..] Aa_Kind;
};
aa_parse_pipeline :: (text: string) {
    if text == "default" { aa_pipeline.is_default = true; return; }
    aa_pipeline.is_default = false;
    aa_pipeline.kinds.count = 0;
    rest := text;
    while rest.count {
        name := rest;
        c := find_index_from_left(rest, #char ",");
        if c >= 0 { name = slice(rest, 0, c); rest = slice(rest, c + 1, rest.count - c - 1); } else rest = "";
        if name == "basic-aa" array_add(*aa_pipeline.kinds, .BASIC);
        else if name == "scoped-noalias-aa" array_add(*aa_pipeline.kinds, .SCOPED_NOALIAS);
        else if name == "tbaa" array_add(*aa_pipeline.kinds, .TBAA);
        else if name == "globals-aa" fatal("-aa-pipeline: globals-aa (GlobalsModRef) is not implemented yet");
        else if name == "scev-aa" || name == "objc-arc-aa" fatal("-aa-pipeline: % is not implemented yet", name);
        else fatal("unknown alias analysis name '%'", name);
    }
}

// AAResults for one function (AAManager::run): the registered analyses, plus BasicAA's inputs.
Aa_Results :: struct {
    f: Value_Id;
    kinds: [4] Aa_Kind;
    nkinds: s32;
    dt: *Dom_Tree;            // BasicAA's DominatorTree (BasicAA::run always requests it)
    ac: *Assumption_Cache;
    tbaa_enabled: bool;       // EnableTBAA && !sanitize_type
}

// AM.getResult<AAManager>(F)
aa_results_for :: (f: Value_Id) -> Aa_Results {
    r: Aa_Results;
    r.f = f;
    add :: (r: *Aa_Results, k: Aa_Kind) { r.kinds[r.nkinds] = k; r.nkinds += 1; }
    if aa_pipeline.is_default {
        add(*r, .BASIC); add(*r, .SCOPED_NOALIAS); add(*r, .TBAA);
        // GlobalsAA is only consulted when a cached result exists (require<globals-aa>), which we never have.
    } else {
        for aa_pipeline.kinds add(*r, it);
    }
    for k: 0..r.nkinds-1 if r.kinds[k] == .BASIC {
        r.ac = get_assumption_cache(f);
        r.dt = get_domtree(f);
    }
    r.tbaa_enabled = !fn_has_fn_attr(f, .SanitizeType);
    if !use_deref_at_point_semantics fatal("-use-dereferenceable-at-point-semantics=false is not supported");
    return r;
}

// AAQueryInfo::LocPair key: {V1, V1Size, MayBeCrossIteration}, {V2, ...}
Aa_Pair :: struct {
    v1: Value_Id; c1: u32; s1: u64;
    v2: Value_Id; c2: u32; s2: u64;
}
aa_pair_hash :: (p: Aa_Pair) -> u32 {
    h: u64 = 0xcbf2_9ce4_8422_2325;
    mix :: (h: *u64, x: u64) { h.* = (h.* ^ x) * 0x100_0000_01b3; h.* ^= h.* >> 29; }
    mix(*h, p.v1); mix(*h, p.c1); mix(*h, p.s1); mix(*h, p.v2); mix(*h, p.c2); mix(*h, p.s2);
    return cast,trunc(u32)(h ^ (h >> 32));
}
aa_pair_eq :: (a: Aa_Pair, b: Aa_Pair) -> bool {
    return a.v1 == b.v1 && a.c1 == b.c1 && a.s1 == b.s1 && a.v2 == b.v2 && a.c2 == b.c2 && a.s2 == b.s2;
}
AA_CACHE_DEFINITIVE :: -2;
AA_CACHE_ASSUMPTION_BASED :: -1;
Aa_Cache_Entry :: struct {
    result: Alias_Result;
    num_assumption_uses: s32;
}

// SimpleCaptureAnalysis / EarliestEscapeAnalysis caches
Ee_Entry :: struct { inst: Value_Id; without_ret: u8; with_ret: u8; }

Aa_Query :: struct {
    aar: *Aa_Results;
    cache: Table(Aa_Pair, Aa_Cache_Entry, aa_pair_hash, aa_pair_eq);
    depth: s32;
    num_assumption_uses: s32;
    assumption_based: [..] Aa_Pair;
    may_be_cross_iteration: bool;
    use_dominator_tree := true;
    // capture analysis: SimpleCaptureAnalysis unless `earliest_escape` (EarliestEscapeAnalysis with ee_dt)
    earliest_escape: bool;
    ee_dt: *Dom_Tree;
    captured: Table(Value_Id, Ee_Entry);
    // BasicAA scratch (Visited in getModRefInfoMask)
}

// A query state (SimpleAAQueryInfo / BatchAAResults' AAQI); everything lives in `temp`.
aa_query_new :: (aar: *Aa_Results) -> *Aa_Query {
    q := New(Aa_Query,, allocator = temp);
    q.aar = aar;
    q.cache.allocator = temp;
    q.assumption_based.allocator = temp;
    q.captured.allocator = temp;
    return q;
}
// EarliestEscapeAnalysis-based query state (DSE, MemCpyOpt's BatchAA with EI)
aa_query_new_earliest_escape :: (aar: *Aa_Results, dt: *Dom_Tree) -> *Aa_Query {
    q := aa_query_new(aar);
    q.earliest_escape = true;
    q.ee_dt = dt;
    return q;
}

// CaptureAnalysis::getCapturesBefore
aa_captures_before :: (q: *Aa_Query, obj: Value_Id, i: Value_Id, or_at: bool, return_captures: bool) -> u8 {
    if !is_identified_function_local(obj) return CC_PROVENANCE;
    e := table_find_pointer(*q.captured, obj);
    if !q.earliest_escape {
        if !e {
            a, b := pointer_may_be_captured(obj, CC_PROVENANCE, .FULL_PROVENANCE);
            x: Ee_Entry; x.inst = NONE; x.without_ret = a; x.with_ret = b;
            table_set(*q.captured, obj, x);
            e = table_find_pointer(*q.captured, obj);
        }
        return ifx return_captures then e.with_ret else e.without_ret;
    }
    if !e {
        ci, a, b := find_earliest_capture(obj, q.aar.f, q.ee_dt, CC_PROVENANCE);
        x: Ee_Entry; x.inst = ci; x.without_ret = a; x.with_ret = b;
        table_set(*q.captured, obj, x);
        e = table_find_pointer(*q.captured, obj);
    }
    if return_captures return e.with_ret;
    not_captured_before :: (e: *Ee_Entry, i: Value_Id, or_at: bool, dt: *Dom_Tree) -> bool {
        if e.inst == NONE return true;
        if i == NONE return false;
        if i == e.inst {
            if or_at return false;
            // isNotInCycle(I, DT, LI = null, CI = null)
            return aa_is_not_in_cycle(i, dt);
        }
        return !is_potentially_reachable_inst(e.inst, i, dt);
    }
    if not_captured_before(e, i, or_at, q.ee_dt) return CC_NONE;
    return e.without_ret;
}
// EarliestEscapeAnalysis::removeInstruction: forget objects whose earliest capture was I
aa_query_remove_instruction :: (q: *Aa_Query, i: Value_Id) {
    if !q.earliest_escape return;
    dead: [..] Value_Id; dead.allocator = temp;
    for q.captured if it.inst == i array_add(*dead, it_index);
    for dead table_remove(*q.captured, it);
}
// isNotInCycle without LoopInfo/CycleInfo
aa_is_not_in_cycle :: (i: Value_Id, dt: *Dom_Tree) -> bool {
    bb := inst_block(i);
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    return succs.count == 0 || !is_potentially_reachable_from_many(succs, bb, dt);
}

// ---------------------------------------------------------------- AAResults methods

// AAResults::alias(LocA, LocB, AAQI, CtxI)
aa_alias :: (q: *Aa_Query, a: Mem_Loc, b: Mem_Loc, ctx: Value_Id = NONE) -> Alias_Result {
    result := ar(AR_MAY);
    q.depth += 1;
    for k: 0..q.aar.nkinds-1 {
        if q.aar.kinds[k] == {
            case .BASIC; result = basic_aa_alias(q, a, b, ctx);
            case .SCOPED_NOALIAS; result = scoped_noalias_alias(a, b);
            case .TBAA; result = tbaa_alias(q.aar, a, b);
            case .GLOBALS; result = ar(AR_MAY);
        }
        if result.kind != AR_MAY break;
    }
    q.depth -= 1;
    return result;
}
// AAResults::alias(LocA, LocB) with a SimpleAAQueryInfo
aa_alias_once :: (aar: *Aa_Results, a: Mem_Loc, b: Mem_Loc) -> Alias_Result { return aa_alias(aa_query_new(aar), a, b); }

// AAResults::aliasErrno
aa_alias_errno :: (q: *Aa_Query, loc: Mem_Loc) -> u8 {
    result := AR_MAY;
    for k: 0..q.aar.nkinds-1 {
        if q.aar.kinds[k] == {
            case .BASIC; result = basic_aa_alias_errno(loc);
            case .TBAA; result = tbaa_alias_errno(q.aar, loc);
            case; result = AR_MAY;
        }
        if result != AR_MAY break;
    }
    return result;
}

// AAResults::getModRefInfoMask(Loc, AAQI, IgnoreLocals)
aa_mod_ref_mask :: (q: *Aa_Query, loc: Mem_Loc, ignore_locals := false) -> u8 {
    result := MR_MODREF;
    for k: 0..q.aar.nkinds-1 {
        if q.aar.kinds[k] == {
            case .BASIC; result &= basic_aa_mod_ref_mask(q, loc, ignore_locals);
            case .TBAA; result &= tbaa_mod_ref_mask(q.aar, loc);
        }
        if result == MR_NO return MR_NO;
    }
    return result;
}

// AAResults::getArgModRefInfo
aa_arg_mod_ref :: (q: *Aa_Query, call: Value_Id, idx: u32) -> u8 {
    result := MR_MODREF;
    for k: 0..q.aar.nkinds-1 {
        if q.aar.kinds[k] == .BASIC result &= basic_aa_arg_mod_ref(call, idx);
        if result == MR_NO return MR_NO;
    }
    return result;
}

// AAResults::getMemoryEffects(Call, AAQI)
aa_memory_effects_call :: (q: *Aa_Query, call: Value_Id) -> u64 {
    result: u64 = MEM_UNKNOWN;
    for k: 0..q.aar.nkinds-1 {
        if q.aar.kinds[k] == {
            case .BASIC; result &= basic_aa_memory_effects_call(q, call);
            case .TBAA; result &= tbaa_memory_effects_call(q.aar, call);
        }
        if result == 0 return result;
    }
    return result;
}
// AAResults::getMemoryEffects(F)
aa_memory_effects_fn :: (q: *Aa_Query, f: Value_Id) -> u64 {
    result: u64 = MEM_UNKNOWN;
    for k: 0..q.aar.nkinds-1 {
        if q.aar.kinds[k] == .BASIC result &= basic_aa_memory_effects_fn(f);
        if result == 0 return result;
    }
    return result;
}

// Instruction::isFenceLike
is_fence_like :: (i: Value_Id) -> bool {
    o := inst_op(i);
    return o == .FENCE || o == .CATCHPAD || o == .CATCHRET || o == .CALL || o == .INVOKE;
}
// Instruction::isAtomic
inst_is_atomic :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .CMPXCHG || o == .ATOMICRMW || o == .FENCE return true;
    if o == .LOAD || o == .STORE return inst(i).ord1 != 0;
    return false;
}
ORD_MONOTONIC :: 2;
is_stronger_than_monotonic :: inline (o: u8) -> bool { return o > ORD_MONOTONIC; }
is_stronger_than_unordered :: inline (o: u8) -> bool { return o > ORD_UNORDERED; }

// AAResults::getModRefInfo(const Instruction *I, const CallBase *Call2, AAQI)
aa_mod_ref_inst_call :: (q: *Aa_Query, i: Value_Id, call2: Value_Id) -> u8 {
    if is_call_base(i) return aa_mod_ref_call_call(q, i, call2);
    if is_fence_like(i) return MR_MODREF;
    def_loc := mloc_get(i);
    mr := aa_mod_ref_call_loc(q, call2, def_loc);
    if mr != MR_NO return MR_MODREF;
    return MR_NO;
}

// AAResults::getModRefInfo(const CallBase *Call, const MemoryLocation &Loc, AAQI)
aa_mod_ref_call_loc :: (q: *Aa_Query, call: Value_Id, loc: Mem_Loc) -> u8 {
    result := MR_MODREF;
    for k: 0..q.aar.nkinds-1 {
        if q.aar.kinds[k] == {
            case .BASIC; result &= basic_aa_mod_ref_call_loc(q, call, loc);
            case .SCOPED_NOALIAS; result &= scoped_noalias_mod_ref_inst_loc(call, loc);
            case .TBAA; result &= tbaa_mod_ref_call_loc(q.aar, call, loc);
        }
        if result == MR_NO return MR_NO;
    }
    if result != MR_NO result &= aa_mod_ref_mask(aa_query_new(q.aar), loc);   // getModRefInfoMask(Loc): fresh AAQI
    return result;
}

// getModRefInfoInaccessibleAndTargetMemLoc
mod_ref_inaccessible_and_target_mem :: (call_use: u64, call_def: u64) -> u8 {
    result := MR_NO;
    add :: (result: *u8, call_use: u64, call_def: u64, l: s64) {
        use_mr := me_get(call_use, l);
        if use_mr == MR_NO return;
        def_mr := me_get(call_def, l);
        if def_mr == MR_NO return;
        if def_mr == MR_REF && def_mr == use_mr return;
        result.* |= use_mr;
    }
    add(*result, call_use, call_def, LOC_INACCESSIBLE);
    add(*result, call_use, call_def, LOC_TARGET0);
    add(*result, call_use, call_def, LOC_TARGET1);
    return result;
}

// AAResults::getModRefInfo(const CallBase *Call1, const CallBase *Call2, AAQI)
aa_mod_ref_call_call :: (q: *Aa_Query, call1: Value_Id, call2: Value_Id) -> u8 {
    result := MR_MODREF;
    for k: 0..q.aar.nkinds-1 {
        if q.aar.kinds[k] == {
            case .BASIC; result &= basic_aa_mod_ref_call_call(q, call1, call2);
            case .SCOPED_NOALIAS; result &= scoped_noalias_mod_ref_call_call(call1, call2);
            case .TBAA; result &= tbaa_mod_ref_call_call(q.aar, call1, call2);
        }
        if result == MR_NO return MR_NO;
    }
    me1 := aa_memory_effects_call(q, call1);
    if me1 == 0 return MR_NO;
    me2 := aa_memory_effects_call(q, call2);
    if me2 == 0 return MR_NO;
    if mem_only_reads(me1) && mem_only_reads(me2) return MR_NO;
    if mem_only_reads(me1) result &= MR_REF;
    else if mem_only_writes(me1) result &= MR_MOD;

    if me_only_accesses_arg_pointees(me2) {
        if !me_does_access_arg_pointees(me2) return MR_NO;
        r := MR_NO;
        n := call_num_args(call2);
        if n > 0 for idx: 0..n-1 {
            a := call_arg(call2, idx);
            if !is_ptr_type(vtype(a)) continue;
            loc2 := mloc_for_argument(call2, idx, true);
            arg_mr2 := aa_arg_mod_ref(q, call2, idx);
            arg_mask := MR_NO;
            if arg_mr2 & MR_MOD arg_mask = MR_MODREF;
            else if arg_mr2 & MR_REF arg_mask = MR_MOD;
            arg_mask &= aa_mod_ref_call_loc(q, call1, loc2);
            r = (r | arg_mask) & result;
            if r == result break;
        }
        return r;
    }
    if me_only_accesses_arg_pointees(me1) {
        if !me_does_access_arg_pointees(me1) return MR_NO;
        r := MR_NO;
        n := call_num_args(call1);
        if n > 0 for idx: 0..n-1 {
            a := call_arg(call1, idx);
            if !is_ptr_type(vtype(a)) continue;
            loc1 := mloc_for_argument(call1, idx, true);
            arg_mr1 := aa_arg_mod_ref(q, call1, idx);
            mr2 := aa_mod_ref_call_loc(q, call2, loc1);
            if ((arg_mr1 & MR_MOD) != 0 && mr2 != MR_NO) || ((arg_mr1 & MR_REF) != 0 && (mr2 & MR_MOD) != 0)
                r = (r | arg_mr1) & result;
            if r == result break;
        }
        return r;
    }
    if me_only_accesses_inaccessible_or_target_mem(me1) && me_only_accesses_inaccessible_or_target_mem(me2)
        return mod_ref_inaccessible_and_target_mem(me1, me2);
    return result;
}

// Instruction::mayReadOrWriteMemory
may_read_or_write_memory :: (i: Value_Id) -> bool { return may_read_from_memory(i) || may_write_to_memory(i); }

// AAResults::getModRefInfo(const Instruction *I1, const Instruction *I2, AAQI)
aa_mod_ref_inst_inst :: (q: *Aa_Query, i1: Value_Id, i2: Value_Id) -> u8 {
    if !may_read_or_write_memory(i1) || !may_read_or_write_memory(i2) return MR_NO;
    if is_call_base(i2) return aa_mod_ref_inst_call(q, i1, i2);
    has, loc := mloc_get_or_none(i2);
    mr := aa_mod_ref_inst_opt_loc(q, i1, has, loc);
    return ifx mr != MR_NO then MR_MODREF else MR_NO;
}

// getSyncEffects(AA, Loc, AAQI)
aa_sync_effects :: (q: *Aa_Query, loc: Mem_Loc) -> u8 {
    if loc.ptr == NONE return MR_MODREF;
    obj := get_underlying_object(loc.ptr);
    cc := aa_captures_before(q, obj, NONE, true, true);
    if cc == CC_NONE return MR_NO;
    mr := ifx cc_captures_read_provenance_only(cc) then MR_REF else MR_MODREF;
    return mr & aa_mod_ref_mask(aa_query_new(q.aar), loc);
}

// AAResults::getModRefInfo(const Instruction *I, const std::optional<MemoryLocation> &OptLoc, AAQI)
aa_mod_ref_inst_opt_loc :: (q: *Aa_Query, i: Value_Id, has_loc: bool, loc_in: Mem_Loc) -> u8 {
    if !has_loc && is_call_base(i) return me_mod_ref(aa_memory_effects_call(q, i));
    loc := loc_in;
    if !has_loc loc = .{};
    o := inst_op(i);
    if o == {
        case .VAARG;
            if loc.ptr != NONE {
                if aa_alias(q, mloc_get(i), loc, i).kind == AR_NO return MR_NO;
                return aa_mod_ref_mask(q, loc);
            }
            return MR_MODREF;
        case .LOAD;
            if loc.ptr != NONE {
                if aa_alias(q, mloc_get(i), loc, i).kind == AR_NO {
                    if is_stronger_than_monotonic(inst(i).ord1) return aa_sync_effects(q, loc);
                    return MR_NO;
                }
            }
            if is_stronger_than_unordered(inst(i).ord1) return MR_MODREF;
            return MR_REF;
        case .STORE;
            if loc.ptr != NONE {
                if aa_alias(q, mloc_get(i), loc, i).kind == AR_NO {
                    if is_stronger_than_monotonic(inst(i).ord1) return aa_sync_effects(q, loc);
                    return MR_NO;
                }
                if (aa_mod_ref_mask(aa_query_new(q.aar), loc) & MR_MOD) == 0 return MR_NO;
            }
            if is_stronger_than_unordered(inst(i).ord1) return MR_MODREF;
            return MR_MOD;
        case .FENCE;
            if loc.ptr != NONE {
                result := MR_MODREF;
                for k: 0..q.aar.nkinds-1 {
                    if q.aar.kinds[k] == .SCOPED_NOALIAS result &= scoped_noalias_mod_ref_inst_loc(i, loc);
                    if result == MR_NO return MR_NO;
                }
                return result & aa_sync_effects(q, loc);
            }
            return MR_MODREF;
        case .CMPXCHG; #through;
        case .ATOMICRMW;
            if loc.ptr != NONE {
                if aa_alias(q, mloc_get(i), loc, i).kind == AR_NO {
                    if is_stronger_than_monotonic(inst(i).ord1) return aa_sync_effects(q, loc);
                    return MR_NO;
                }
            }
            return MR_MODREF;
        case .CALL; #through; case .CALLBR; #through; case .INVOKE;
            return aa_mod_ref_call_loc(q, i, loc);
        case .CATCHPAD; #through; case .CATCHRET;
            if loc.ptr != NONE return aa_mod_ref_mask(q, loc);
            return MR_MODREF;
    }
    return MR_NO;
}
// AAResults::getModRefInfo(const Instruction *I, const MemoryLocation &Loc, AAQI)
aa_mod_ref_inst_loc :: (q: *Aa_Query, i: Value_Id, loc: Mem_Loc) -> u8 { return aa_mod_ref_inst_opt_loc(q, i, true, loc); }

// AAResults::callCapturesBefore(I, MemLoc, DT, AAQI)
aa_call_captures_before :: (q: *Aa_Query, i: Value_Id, loc: Mem_Loc, dt: *Dom_Tree) -> u8 {
    if !dt return MR_MODREF;
    obj := get_underlying_object(loc.ptr);
    if !is_identified_function_local(obj) return MR_MODREF;
    if !is_call_base(i) || i == obj return MR_MODREF;
    if pointer_may_be_captured_before(obj, true, i, dt, true, CC_PROVENANCE) != CC_NONE return MR_MODREF;
    r := MR_NO;
    nd := nops(i) - call_non_data_operands(i);
    if nd > 0 for k: 0..nd-1 {
        a := op(i, k);
        if !is_ptr_type(vtype(a)) continue;
        oth, _ := call_capture_info(i, k);
        if cc_captures_any_provenance(oth) continue;
        if aa_alias(q, mloc_before_or_after(a), mloc_before_or_after(obj), i).kind == AR_NO continue;
        if call_data_operand_does_not_access(i, k) continue;
        if call_param_only_reads(i, k) { r = MR_REF; continue; }
        return MR_MODREF;
    }
    return r;
}

// ---------------------------------------------------------------- CallBase per-operand memory attributes

// CallBase::paramHasAttr for ReadNone / ReadOnly / WriteOnly (call site, then the called function, adjusted for
// operand bundles)
call_param_has_mem_attr :: (c: Value_Id, k: u32, a: Attr_Kind) -> bool {
    if attr_set_has(attr_list_param(inst(c).attrs, k), a) return true;
    f := call_called_function(c);
    if f == NONE return false;
    if !attr_set_has(attr_list_param(glob(f).attrs, k), a) return false;
    reading := call_has_reading_bundles(c);
    clobbering := call_has_clobbering_bundles(c);
    if a == .ReadNone return !reading && !clobbering;
    if a == .ReadOnly return !clobbering;
    if a == .WriteOnly return !reading;
    return true;
}
call_has_reading_bundles :: (c: Value_Id) -> bool {
    return call_has_bundles_other_than(c, .["ptrauth", "kcfi", "convergencectrl", "deactivation-symbol"]) && call_iid_any(c) != IID_ASSUME;
}
call_has_clobbering_bundles :: (c: Value_Id) -> bool {
    return call_has_bundles_other_than(c, .["deopt", "funclet", "ptrauth", "kcfi", "convergencectrl", "deactivation-symbol"]) && call_iid_any(c) != IID_ASSUME;
}
// dataOperandHasImpliedAttr(OpNo, Kind)
call_data_operand_has_attr :: (c: Value_Id, k: u32, a: Attr_Kind) -> bool {
    if k < call_num_args(c) return call_param_has_mem_attr(c, k, a);
    // bundleOperandHasAttr: only deopt bundles imply readonly for pointer operands
    if a == .ReadOnly return call_bundle_tag_of_operand(c, k) == "deopt" && is_ptr_type(vtype(op(c, k)));
    return false;
}
// CallBase::doesNotAccessMemory(OpNo)
call_data_operand_does_not_access :: (c: Value_Id, k: u32) -> bool { return call_data_operand_has_attr(c, k, .ReadNone); }
// CallBase::onlyReadsMemory(OpNo)
call_data_operand_only_reads :: (c: Value_Id, k: u32) -> bool {
    if k < call_num_args(c) && call_is_byval_arg(c, k) return true;
    return call_data_operand_has_attr(c, k, .ReadOnly) || call_data_operand_has_attr(c, k, .ReadNone);
}
// CallBase::onlyWritesMemory(OpNo)
call_data_operand_only_writes :: (c: Value_Id, k: u32) -> bool {
    return call_data_operand_has_attr(c, k, .WriteOnly) || call_data_operand_has_attr(c, k, .ReadNone);
}

// ---------------------------------------------------------------- aa-eval (AAEvaluator)

aa_eval_opts: struct {
    print_all, print_no_alias, print_may_alias, print_partial_alias, print_must_alias: bool;
    print_no_mod_ref, print_ref, print_mod, print_mod_ref: bool;
    evaluate_aa_metadata: bool;
};

Aa_Eval_Counts :: struct {
    function_count: s64;
    no_alias, may_alias, partial_alias, must_alias: s64;
    no_mod_ref, mod, ref, mod_ref: s64;
}
aa_eval_counts: [..] Aa_Eval_Counts;   // one per aa-eval pass in the pipeline (reported at exit)

aa_eval_print_any :: () -> bool {
    o := *aa_eval_opts;
    return o.print_all || o.print_no_alias || o.print_may_alias || o.print_partial_alias || o.print_must_alias ||
           o.print_no_mod_ref || o.print_mod || o.print_ref || o.print_mod_ref;
}

aa_eval_run :: (f: Value_Id, counts: *Aa_Eval_Counts, sb: *String_Builder) {
    aar := aa_results_for(f);
    counts.function_count += 1;
    Ptr_Ty :: struct { p: Value_Id; t: Type_Id; }
    pointers: [..] Ptr_Ty; pointers.allocator = temp;
    other_mem_ops: [..] Value_Id; other_mem_ops.allocator = temp;
    loads: [..] Value_Id; loads.allocator = temp;
    stores: [..] Value_Id; stores.allocator = temp;
    add_ptr :: (pointers: *[..] Ptr_Ty, p: Value_Id, t: Type_Id) {
        for pointers.* if it.p == p && it.t == t return;
        array_add(pointers, .{p, t});
    }
    for i: fn_insts(f) {
        o := inst_op(i);
        if o == .LOAD { add_ptr(*pointers, op(i, 0), vtype(i)); array_add(*loads, i); }
        else if o == .STORE { add_ptr(*pointers, op(i, 1), vtype(op(i, 0))); array_add(*stores, i); }
        if is_call_base(i) || inst_is_atomic(i) array_add(*other_mem_ops, i);
    }
    printer_begin_function(f);
    if aa_eval_print_any() print_to_builder(sb, "Function: %: % pointers, % call sites\n", vname(f), pointers.count, other_mem_ops.count);

    o := *aa_eval_opts;
    print_alias :: (sb: *String_Builder, r_in: Alias_Result, p: bool, l1: Ptr_Ty, l2: Ptr_Ty) {
        if !(aa_eval_opts.print_all || p) return;
        r := r_in;
        t1 := l1.t; t2 := l2.t;
        as1 := ir.types[vtype(l1.p)].a; as2 := ir.types[vtype(l2.p)].a;
        o1 := value_as_operand(l1.p); o2 := value_as_operand(l2.p);
        if compare_strings(o2, o1) < 0 {
            o1, o2 = o2, o1; t1, t2 = t2, t1; as1, as2 = as2, as1;
            ar_swap(*r);
        }
        print_to_builder(sb, "  %:\t%", ar_to_string(r), type_to_string(t1));
        if as1 != 0 print_to_builder(sb, " addrspace(%)", as1);
        print_to_builder(sb, "* %, %", o1, type_to_string(t2));
        if as2 != 0 print_to_builder(sb, " addrspace(%)", as2);
        print_to_builder(sb, "* %\n", o2);
    }
    count_alias :: (counts: *Aa_Eval_Counts, k: u8) -> bool {
        if k == {
            case AR_NO; counts.no_alias += 1; return aa_eval_opts.print_no_alias;
            case AR_MAY; counts.may_alias += 1; return aa_eval_opts.print_may_alias;
            case AR_PARTIAL; counts.partial_alias += 1; return aa_eval_opts.print_partial_alias;
        }
        counts.must_alias += 1; return aa_eval_opts.print_must_alias;
    }
    for i1: 0..pointers.count-1 {
        s1 := ls_of_type(pointers[i1].t);
        for i2: 0..i1-1 {
            s2 := ls_of_type(pointers[i2].t);
            r := aa_alias_once(*aar, mloc(pointers[i1].p, s1), mloc(pointers[i2].p, s2));
            p := count_alias(counts, r.kind);
            print_alias(sb, r, p, pointers[i1], pointers[i2]);
        }
    }
    if o.evaluate_aa_metadata {
        print_ls :: (sb: *String_Builder, r: Alias_Result, p: bool, v1: Value_Id, v2: Value_Id) {
            if !(aa_eval_opts.print_all || p) return;
            print_to_builder(sb, "  %: % <-> %\n", ar_to_string(r), inst_to_string(v1), inst_to_string(v2));
        }
        for l: loads for s: stores {
            r := aa_alias_once(*aar, mloc_get(l), mloc_get(s));
            p := count_alias(counts, r.kind);
            print_ls(sb, r, p, l, s);
        }
        for i1: 0..stores.count-1 for i2: 0..i1-1 {
            r := aa_alias_once(*aar, mloc_get(stores[i1]), mloc_get(stores[i2]));
            p := count_alias(counts, r.kind);
            print_ls(sb, r, p, stores[i1], stores[i2]);
        }
    }
    count_mr :: (counts: *Aa_Eval_Counts, mr: u8) -> (string, bool) {
        if mr == {
            case MR_NO; counts.no_mod_ref += 1; return "NoModRef", aa_eval_opts.print_no_mod_ref;
            case MR_MOD; counts.mod += 1; return "Just Mod", aa_eval_opts.print_mod;
            case MR_REF; counts.ref += 1; return "Just Ref", aa_eval_opts.print_ref;
        }
        counts.mod_ref += 1; return "Both ModRef", aa_eval_opts.print_mod_ref;
    }
    for m: other_mem_ops for pt: pointers {
        size := ls_of_type(pt.t);
        mr := aa_mod_ref_inst_loc(aa_query_new(*aar), m, mloc(pt.p, size));
        msg, p := count_mr(counts, mr);
        if o.print_all || p
            print_to_builder(sb, "  %:  Ptr: %* %\t<->%\n", msg, type_to_string(pt.t), value_as_operand(pt.p), inst_to_string(m));
    }
    for a: other_mem_ops for b: other_mem_ops {
        if a == b continue;
        mr := aa_mod_ref_inst_inst(aa_query_new(*aar), a, b);
        msg, p := count_mr(counts, mr);
        if o.print_all || p
            print_to_builder(sb, "  %: % <-> %\n", msg, inst_to_string(a), inst_to_string(b));
    }
}

// ~AAEvaluator
aa_eval_report :: (c: *Aa_Eval_Counts) -> string {
    if c.function_count == 0 return "";
    sb: String_Builder; sb.allocator = temp;
    pct :: (sb: *String_Builder, num: s64, sum: s64) {
        print_to_builder(sb, "(%.%\x1f)\n", num * 100 / sum, (num * 1000 / sum) % 10);
    }
    alias_sum := c.no_alias + c.may_alias + c.partial_alias + c.must_alias;
    append(*sb, "===== Alias Analysis Evaluator Report =====\n");
    if alias_sum == 0 append(*sb, "  Alias Analysis Evaluator Summary: No pointers!\n");
    else {
        print_to_builder(*sb, "  % Total Alias Queries Performed\n", alias_sum);
        print_to_builder(*sb, "  % no alias responses ", c.no_alias); pct(*sb, c.no_alias, alias_sum);
        print_to_builder(*sb, "  % may alias responses ", c.may_alias); pct(*sb, c.may_alias, alias_sum);
        print_to_builder(*sb, "  % partial alias responses ", c.partial_alias); pct(*sb, c.partial_alias, alias_sum);
        print_to_builder(*sb, "  % must alias responses ", c.must_alias); pct(*sb, c.must_alias, alias_sum);
        print_to_builder(*sb, "  Alias Analysis Evaluator Pointer Alias Summary: %\x1f/%\x1f/%\x1f/%\x1f\n",
            c.no_alias * 100 / alias_sum, c.may_alias * 100 / alias_sum, c.partial_alias * 100 / alias_sum, c.must_alias * 100 / alias_sum);
    }
    mr_sum := c.no_mod_ref + c.ref + c.mod + c.mod_ref;
    if mr_sum == 0 append(*sb, "  Alias Analysis Mod/Ref Evaluator Summary: no mod/ref!\n");
    else {
        print_to_builder(*sb, "  % Total ModRef Queries Performed\n", mr_sum);
        print_to_builder(*sb, "  % no mod/ref responses ", c.no_mod_ref); pct(*sb, c.no_mod_ref, mr_sum);
        print_to_builder(*sb, "  % mod responses ", c.mod); pct(*sb, c.mod, mr_sum);
        print_to_builder(*sb, "  % ref responses ", c.ref); pct(*sb, c.ref, mr_sum);
        print_to_builder(*sb, "  % mod & ref responses ", c.mod_ref); pct(*sb, c.mod_ref, mr_sum);
        print_to_builder(*sb, "  Alias Analysis Evaluator Mod/Ref Summary: %\x1f/%\x1f/%\x1f/%\x1f\n",
            c.no_mod_ref * 100 / mr_sum, c.mod * 100 / mr_sum, c.ref * 100 / mr_sum, c.mod_ref * 100 / mr_sum);
    }
    return builder_to_string(*sb,, allocator = temp);
}

// -use-dereferenceable-at-point-semantics (Value.cpp; default true). Only the default is implemented: Value::
// getPointerDereferenceableBytes' CanBeFreed isn't computed by anyone yet.
use_deref_at_point_semantics := true;

// one Aa_Eval_Counts per aa-eval node of the pipeline, in pipeline order
aa_eval_nodes: [..] *Pass_Node;
aa_eval_counts_for :: (node: *Pass_Node) -> *Aa_Eval_Counts {
    for aa_eval_nodes if it == node return *aa_eval_counts[it_index];
    array_add(*aa_eval_nodes, node);
    blank: Aa_Eval_Counts;
    array_add(*aa_eval_counts, blank);
    return *aa_eval_counts[aa_eval_counts.count - 1];
}
// the AAEvaluator destructors run when the pass pipeline is destroyed, after the output was written
aa_eval_print_reports :: () {
    for * aa_eval_counts write_string(aa_eval_report(it), to_standard_error = true);
}

// cl::opts of aa-eval, BasicAA, TBAA, ScopedNoAliasAA (see passes.jai cl_opts)
AA_CL_OPT_COUNT :: 15;
add_aa_cl_opts :: (list: [] Cl_Opt, start: s64) {
    o := *aa_eval_opts;
    entries := Cl_Opt.[
        .{"print-all-alias-modref-info", .BOOL, null, null, null},
        .{"print-no-aliases", .BOOL, null, null, null},
        .{"print-may-aliases", .BOOL, null, null, null},
        .{"print-partial-aliases", .BOOL, null, null, null},
        .{"print-must-aliases", .BOOL, null, null, null},
        .{"print-no-modref", .BOOL, null, null, null},
        .{"print-ref", .BOOL, null, null, null},
        .{"print-mod", .BOOL, null, null, null},
        .{"print-modref", .BOOL, null, null, null},
        .{"evaluate-aa-metadata", .BOOL, null, null, null},
        .{"basic-aa-recphi", .BOOL, null, null, null},
        .{"basic-aa-separate-storage", .BOOL, null, null, null},
        .{"enable-tbaa", .BOOL, null, null, null},
        .{"enable-scoped-noalias", .BOOL, null, null, null},
        .{"use-dereferenceable-at-point-semantics", .BOOL, null, null, null},
    ];
    ptrs := (*bool).[*o.print_all, *o.print_no_alias, *o.print_may_alias, *o.print_partial_alias, *o.print_must_alias,
                     *o.print_no_mod_ref, *o.print_ref, *o.print_mod, *o.print_mod_ref, *o.evaluate_aa_metadata,
                     *basic_aa_opts.rec_phi, *basic_aa_opts.separate_storage, *tbaa_opts.enable, *scoped_noalias_opts.enable,
                     *use_deref_at_point_semantics];
    for entries {
        list[start + it_index] = it;
        list[start + it_index].b = ptrs[it_index];
    }
}
