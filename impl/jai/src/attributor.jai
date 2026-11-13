// The Attributor framework, restricted to what AttributorLight (`attributor-light`, `attributor-light-cgscc`) uses:
// a port of llvm/lib/Transforms/IPO/Attributor.cpp (runAttributorLightOnFunctions, Attributor::run,
// runTillFixpoint, updateAA, manifestAttributes, identifyDefaultAbstractAttributes, hasAttr / getAttrs /
// manifestAttrs / removeAttrs on the AttrsMap, SubsumingPositionIterator, getAssumedSimplifiedValues,
// checkForAllUses / CallSites / Callees / Instructions / ReadWriteInstructions, isAssumedReadOnly/ReadNone,
// isNoSyncInst, InformationCache::initializeInformationCache, recordDependence), of the templates in
// llvm/include/llvm/Transforms/IPO/Attributor.h (IRPosition, the integer states, getOrCreateAAFor, lookupAAFor,
// shouldInitialize / shouldUpdateAA, IRAttribute::isImpliedByIR / manifest, AA::hasAssumedIRAttr), of
// MustBeExecutedContextExplorer from llvm/lib/Analysis/MustExecute.cpp (+ MustExecute.h) and of fillMapFromAssume /
// getKnowledgeFromUse from llvm/lib/Analysis/AssumeBundleQueries.cpp.
//
// The abstract attributes themselves are in attributor_aas.jai.
//
// AttributorLight's configuration (AC.Allowed = 17 AA kinds, UseLiveness = false, DeleteFns = false) makes several
// parts of the framework inert, and they are not ported: liveness (every isAssumedDead query is false), AAIsDead /
// AAPotentialValues / AAPointerInfo / AAValueSimplify (not allowed, so getOrCreateAAFor returns null for them: with
// no AAPotentialValues, getAssumedSimplifiedValues yields the value itself, or fails for a returned position),
// cleanupIR (nothing is ever registered for deletion or replacement), signature rewriting, function deletion,
// call-base contexts (-attributor-enable-call-site-specific-deduction is off), shallow/deep wrappers. `!callback`
// metadata (AbstractCallSite callback calls) fails loudly.
//
// Design: every abstract attribute is a heap `Abs_Attr` row with a kind tag; LLVM's virtual initialize / updateImpl /
// manifest / indicatePessimisticFixpoint are switches on (kind, position kind) in attributor_aas.jai. Lambdas passed
// to the checkForAll* helpers become loops over the lists these helpers return.

ATR_UNCHANGED :: false;
ATR_CHANGED :: true;

// ---------------------------------------------------------------- IRPosition

// Encoding of IRPosition::Enc: a Value_Id (or, for call site arguments, a Use_Id) plus two bits.
IRP_ENC_VALUE :: cast(u8) 0;
IRP_ENC_RETURNED :: cast(u8) 1;
IRP_ENC_FLOATING_FUNCTION :: cast(u8) 2;
IRP_ENC_CSARG :: cast(u8) 3;

Irp :: struct { enc: u8 = IRP_ENC_VALUE; v: u32 = NONE; }

Irp_Kind :: enum u8 { INVALID; FLOAT; RETURNED; CALL_SITE_RETURNED; FUNCTION; CALL_SITE; ARGUMENT; CALL_SITE_ARGUMENT; }

irp_eq :: inline (a: Irp, b: Irp) -> bool { return a.enc == b.enc && a.v == b.v; }
irp_is_call :: inline (v: Value_Id) -> bool { return v != NONE && vkind(v) == .INST && is_call_base(v); }

// IRPosition::value / inst / function / returned / argument / callsite_*
irp_value :: (v: Value_Id) -> Irp {
    if vkind(v) == .ARGUMENT return irp_argument(v);
    if irp_is_call(v) return irp_cs_returned(v);
    return irp_float(v);
}
irp_float :: (v: Value_Id) -> Irp {
    if vkind(v) == .FUNCTION || irp_is_call(v) return .{IRP_ENC_FLOATING_FUNCTION, v};
    return .{IRP_ENC_VALUE, v};
}
irp_inst :: (i: Value_Id) -> Irp { return irp_float(i); }
irp_function :: (f: Value_Id) -> Irp { return .{IRP_ENC_VALUE, f}; }
irp_returned :: (f: Value_Id) -> Irp { return .{IRP_ENC_RETURNED, f}; }
irp_argument :: (a: Value_Id) -> Irp { return .{IRP_ENC_VALUE, a}; }
irp_cs_function :: (cb: Value_Id) -> Irp { return .{IRP_ENC_VALUE, cb}; }
irp_cs_returned :: (cb: Value_Id) -> Irp { return .{IRP_ENC_RETURNED, cb}; }
irp_cs_argument :: (cb: Value_Id, k: u32) -> Irp { return .{IRP_ENC_CSARG, op_use(cb, k)}; }

irp_kind :: (p: Irp) -> Irp_Kind {
    if p.enc == IRP_ENC_CSARG return .CALL_SITE_ARGUMENT;
    if p.enc == IRP_ENC_FLOATING_FUNCTION return .FLOAT;
    if p.v == NONE return .INVALID;
    k := vkind(p.v);
    if k == .ARGUMENT return .ARGUMENT;
    if k == .FUNCTION { if p.enc == IRP_ENC_RETURNED return .RETURNED; return .FUNCTION; }
    if irp_is_call(p.v) { if p.enc == IRP_ENC_RETURNED return .CALL_SITE_RETURNED; return .CALL_SITE; }
    return .FLOAT;
}
irp_anchor :: inline (p: Irp) -> Value_Id { if p.enc == IRP_ENC_CSARG return ir.u_user[p.v]; return p.v; }
// getCallSiteArgNo
irp_cs_arg_no :: (p: Irp) -> s64 {
    k := irp_kind(p);
    if k == .ARGUMENT return arg_no(p.v);
    if k == .CALL_SITE_ARGUMENT return cast(s64) (p.v - ir.v_ops[ir.u_user[p.v]]);
    return -1;
}
// getAssociatedArgument (callbacks fail loudly at the start of the run)
irp_assoc_arg :: (p: Irp) -> Value_Id {
    if irp_kind(p) == .ARGUMENT return p.v;
    argno := irp_cs_arg_no(p);
    if argno < 0 return NONE;
    callee := call_callee(irp_anchor(p));
    if callee != NONE && vkind(callee) == .FUNCTION && cast(s64) fn_nargs(callee) > argno return fn_arg(callee, cast(u32) argno);
    return NONE;
}
// getCalleeArgNo
irp_callee_arg_no :: (p: Irp) -> s64 {
    a := irp_assoc_arg(p);
    if a != NONE return arg_no(a);
    return irp_cs_arg_no(p);
}
irp_anchor_scope :: (p: Irp) -> Value_Id {
    v := irp_anchor(p);
    k := vkind(v);
    if k == .FUNCTION return v;
    if k == .ARGUMENT return arg_parent(v);
    if k == .INST return inst_fn(v);
    return NONE;
}
irp_assoc_fn :: (p: Irp) -> Value_Id {
    a := irp_anchor(p);
    if irp_is_call(a) {
        arg := irp_assoc_arg(p);
        if arg != NONE return arg_parent(arg);
        c := strip_pointer_casts(call_callee(a));
        if vkind(c) == .FUNCTION return c;
        return NONE;
    }
    return irp_anchor_scope(p);
}
irp_ctx_i :: (p: Irp) -> Value_Id {
    v := irp_anchor(p);
    k := vkind(v);
    if k == .INST return v;
    f: Value_Id = NONE;
    if k == .ARGUMENT f = arg_parent(v);
    else if k == .FUNCTION f = v;
    if f != NONE && !is_declaration(f) return block_first(fn_entry(f));
    return NONE;
}
irp_assoc_value :: (p: Irp) -> Value_Id {
    a := irp_anchor(p);
    n := irp_cs_arg_no(p);
    if n < 0 || vkind(a) == .ARGUMENT return a;
    return call_arg(a, cast(u32) n);
}
irp_assoc_type :: (p: Irp) -> Type_Id {
    if irp_kind(p) == .RETURNED return fn_ret_type(irp_assoc_fn(p));
    return vtype(irp_assoc_value(p));
}
irp_is_fn_interface :: (p: Irp) -> bool { k := irp_kind(p); return k == .FUNCTION || k == .RETURNED || k == .ARGUMENT; }
irp_is_function_scope :: (p: Irp) -> bool { k := irp_kind(p); return k == .CALL_SITE || k == .FUNCTION; }
irp_is_any_call_site :: (p: Irp) -> bool { k := irp_kind(p); return k == .CALL_SITE || k == .CALL_SITE_RETURNED || k == .CALL_SITE_ARGUMENT; }
irp_is_argument_position :: (p: Irp) -> bool { k := irp_kind(p); return k == .ARGUMENT || k == .CALL_SITE_ARGUMENT; }
// function_scope
irp_function_scope :: (p: Irp) -> Irp {
    if irp_is_any_call_site(p) return irp_cs_function(irp_anchor(p));
    return irp_function(irp_assoc_fn(p));
}

ATTR_IDX_FN :: -2;
ATTR_IDX_RET :: -1;
irp_attr_idx :: (p: Irp) -> s64 {
    k := irp_kind(p);
    if k == .FUNCTION || k == .CALL_SITE return ATTR_IDX_FN;
    if k == .RETURNED || k == .CALL_SITE_RETURNED return ATTR_IDX_RET;
    if k == .ARGUMENT return irp_callee_arg_no(p);
    if k == .CALL_SITE_ARGUMENT return irp_cs_arg_no(p);
    fatal("internal: attributor: no attribute index for a floating position");
    return 0;
}
irp_attr_list_anchor :: (p: Irp) -> Value_Id {
    a := irp_anchor(p);
    if irp_is_call(a) return a;
    return irp_assoc_fn(p);
}
attr_list_set_at :: (l: u32, idx: s64) -> u32 {
    if idx == ATTR_IDX_FN return attr_list_fn(l);
    if idx == ATTR_IDX_RET return attr_list_ret(l);
    return attr_list_param(l, cast(u32) idx);
}
attr_list_with_set_at :: (l: u32, idx: s64, s: u32) -> u32 {
    if idx == ATTR_IDX_FN return attr_list_with_fn(l, s);
    if idx == ATTR_IDX_RET {
        if l == 0 return attr_list_get(0, s, .[]);
        r := ir.attr_lists[l];
        return attr_list_get(r.fn, s, r.params);
    }
    return attr_list_with_param(l, cast(u32) idx, s);
}

// ---------------------------------------------------------------- states

// The integer states (IntegerStateBase / BitIntegerState / BooleanState; worst state 0 for all of them).
Bstate :: struct { known: u32; assumed: u32; best: u32; }
bs_new :: (best: u32) -> Bstate { s: Bstate; s.known = 0; s.assumed = best; s.best = best; return s; }
bs_is_valid :: inline (s: Bstate) -> bool { return s.assumed != 0; }
bs_is_fix :: inline (s: Bstate) -> bool { return s.assumed == s.known; }
bs_optimistic :: inline (s: *Bstate) { s.known = s.assumed; }
bs_pessimistic :: inline (s: *Bstate) -> bool { s.assumed = s.known; return ATR_CHANGED; }
bs_is_known :: inline (s: Bstate, bits: u32) -> bool { return (s.known & bits) == bits; }
bs_is_assumed :: inline (s: Bstate, bits: u32) -> bool { return (s.assumed & bits) == bits; }
bs_add_known :: inline (s: *Bstate, bits: u32) { s.assumed |= bits; s.known |= bits; }
bs_intersect_assumed :: inline (s: *Bstate, bits: u32) { s.assumed = (s.assumed & bits) | s.known; }
bs_remove_assumed :: inline (s: *Bstate, bits: u32) { bs_intersect_assumed(s, ~bits); }
bs_remove_known :: inline (s: *Bstate, bits: u32) { s.known &= ~bits; }
// operator^= (handleNewAssumedValue), operator&= (joinAND), operator+= (handleNewKnownValue)
bs_clamp :: inline (s: *Bstate, r: Bstate) { bs_intersect_assumed(s, r.assumed); }
bs_join_and :: inline (s: *Bstate, r: Bstate) { s.known &= r.known; s.assumed &= r.assumed; }
bs_add_known_of :: inline (s: *Bstate, r: Bstate) { bs_add_known(s, r.known); }
// clampStateAndIndicateChange
bs_clamp_and_indicate :: (s: *Bstate, r: Bstate) -> bool { old := s.assumed; bs_clamp(s, r); return old != s.assumed; }

// ---------------------------------------------------------------- abstract attributes

Atr_Kind :: enum u8 {
    NO_UNWIND; NO_SYNC; NO_FREE; NON_NULL; MUST_PROGRESS; NO_RECURSE; WILL_RETURN; INTRA_REACH; NO_RETURN;
    NO_CAPTURE; MEM_BEHAVIOR; MEM_LOCATION; DENORMAL_FP; NO_FPCLASS; CALL_EDGES; INTER_REACH; UNDERLYING_OBJECTS;
}

DEP_REQUIRED :: cast(u8) 0;
DEP_OPTIONAL :: cast(u8) 1;
DEP_NONE :: cast(u8) 2;

// AAMemoryLocation::AccessInfo
Ml_Access :: struct { i: Value_Id; ptr: Value_Id; kind: u8; }
// ReachabilityQueryInfo (exclusion sets are never used by the light AAs)
Rqi :: struct { from: Value_Id; to: Value_Id; reachable: bool; }

Abs_Attr :: struct {
    kind: Atr_Kind;
    pos: Irp;
    pk: Irp_Kind;
    s: Bstate;
    deps: [..] u32;            // AADepGraphNode::Deps: SetVector of (aa << 1) | dep class
    // AAMemoryLocation
    accesses: [8] [..] Ml_Access;
    // AAUnderlyingObjects
    intra_objs: [..] Value_Id;
    inter_objs: [..] Value_Id;
    // AACallEdges
    callees: [..] Value_Id;
    unknown_callee: bool;
    unknown_callee_non_asm: bool;
    // CachedReachabilityAA
    queries: [..] s32;         // QueryVector (indices into rq)
    rq: [..] Rqi;
    rq_cache: Table(u64, s32); // QueryCache: (from, to) -> RQI index
    // DenormalFPMathState
    dn_mode: u32;              // DenormalFPEnv-like packing: Mode output/input, ModeF32 output/input (4 bits each)
    dn_fix: bool;
}

Atr_Phase :: enum u8 { SEEDING; UPDATE; MANIFEST; CLEANUP; }

Atr_Dep_Info :: struct { from: u32; to: u32; cls: u8; }

// InformationCache::FunctionInfo
Atr_Fn_Info :: struct {
    by_opcode: Table(u8, [..] Value_Id);
    rw_insts: [..] Value_Id;
    called_via_must_tail: bool;
    contains_must_tail: bool;
    is_kernel: bool;
}

Atr_Knowledge :: struct { assume: Value_Id; min: u64; max: u64; }

Attributor_State :: struct {
    functions: [..] Value_Id;
    fn_set: Table(Value_Id, bool);
    is_module_pass: bool;
    cached_only: bool;             // AnalysisGetter(FAM, CachedOnly)
    aas: [..] *Abs_Attr;
    aa_map: Table(u64, u32);
    root: [..] u32;                // DG.SyntheticRoot.Deps (all REQUIRED)
    phase: Atr_Phase;
    dep_stack: [..] *[..] Atr_Dep_Info;
    init_chain: u32;
    query_awaiting: [..] u32;      // QueryAAsAwaitingUpdate (SetVector)
    attrs_map: Table(Value_Id, u32);
    visited_functions: Table(Value_Id, bool);
    // InformationCache
    fn_info: Table(Value_Id, *Atr_Fn_Info);
    knowledge: Table(u64, [..] Atr_Knowledge);
    assume_only: Table(Value_Id, bool);
    inlineable: Table(Value_Id, bool);
    // MustBeExecutedContextExplorer caches
    block_transfer: Table(Value_Id, bool);
    irreducible: Table(Value_Id, bool);
}
atr: Attributor_State;

atr_max_iterations: u32 = 32;      // -attributor-max-iterations
atr_max_init_chain: u32 = 1024;    // -attributor-max-initialization-chain-length

aa_key :: inline (k: Atr_Kind, p: Irp) -> u64 { return ((cast(u64) k) << 40) | ((cast(u64) p.enc) << 32) | cast(u64) p.v; }
aa :: inline (i: u32) -> *Abs_Attr { return atr.aas[i]; }
atr_is_run_on :: (f: Value_Id) -> bool { return atr.functions.count == 0 || table_contains(*atr.fn_set, f); }

// The AbstractAttribute static properties per kind.
aa_best_state :: (k: Atr_Kind) -> u32 {
    if k == .NO_CAPTURE return 7;
    if k == .MEM_BEHAVIOR return 3;
    if k == .MEM_LOCATION return 511;
    if k == .NO_FPCLASS return 1023;
    return 1;
}
aa_has_trivial_initializer :: (k: Atr_Kind) -> bool {
    return k == .NO_UNWIND || k == .NO_SYNC || k == .NO_FREE || k == .MUST_PROGRESS || k == .NO_RECURSE ||
           k == .WILL_RETURN || k == .NO_RETURN;
}
aa_is_query :: (k: Atr_Kind) -> bool { return k == .INTRA_REACH || k == .INTER_REACH; }
aa_is_valid_for_init :: (k: Atr_Kind, p: Irp) -> bool {
    if k == {
        case .NO_SYNC; #through;
        case .NO_FREE; #through;
        case .MEM_LOCATION;
            if !irp_is_function_scope(p) && !is_ptr_or_ptr_vector(irp_assoc_type(p)) return false;
        case .NON_NULL; #through;
        case .UNDERLYING_OBJECTS;
            if !is_ptr_or_ptr_vector(irp_assoc_type(p)) return false;
        case .NO_CAPTURE;
            if !is_ptr_type(irp_assoc_type(p)) return false;
        case .MEM_BEHAVIOR;
            if !irp_is_function_scope(p) && !is_ptr_type(irp_assoc_type(p)) return false;
        case .NO_FPCLASS;
            return is_fp_math_type(irp_assoc_type(p));
    }
    return true;
}
// Attributor::isFunctionIPOAmendable
atr_is_ipo_amendable :: (f: Value_Id) -> bool {
    return (!is_declaration(f) && gv_is_definition_exact(f)) || table_contains(*atr.inlineable, f);
}
// Attributor::shouldUpdateAA
atr_should_update :: (k: Atr_Kind, p: Irp) -> bool {
    if atr.phase == .MANIFEST || atr.phase == .CLEANUP return false;
    afn := irp_assoc_fn(p);
    if irp_is_any_call_site(p) {
        if afn == NONE && k == .MEM_LOCATION return false;                                // requiresCalleeForCallBase
        if k != .CALL_EDGES && vkind(call_callee(irp_anchor(p))) == .INLINE_ASM return false;   // requiresNonAsmForCallBase
    }
    if k == .UNDERLYING_OBJECTS {                                                          // requiresCallersForArgOrFunction
        pk := irp_kind(p);
        if (pk == .FUNCTION || pk == .ARGUMENT) && !gv_has_local_linkage(afn) return false;
    }
    // isValidIRPositionForUpdate
    if irp_is_fn_interface(p) && !atr_is_ipo_amendable(afn) return false;
    return afn == NONE || atr.is_module_pass || atr_is_run_on(afn) || atr_is_run_on(irp_anchor_scope(p));
}
// Attributor::shouldInitialize
atr_should_initialize :: (k: Atr_Kind, p: Irp) -> (bool, bool) {
    if !aa_is_valid_for_init(k, p) return false, false;
    anchor_fn := irp_anchor_scope(p);
    if anchor_fn != NONE && (fn_has_fn_attr(anchor_fn, .Naked) || fn_has_fn_attr(anchor_fn, .OptimizeNone)) return false, false;
    if atr.init_chain > atr_max_init_chain return false, false;
    should_update := atr_should_update(k, p);
    return !aa_has_trivial_initializer(k) || should_update, should_update;
}

aa_is_valid :: (i: u32) -> bool {
    a := aa(i);
    if a.kind == .DENORMAL_FP return dn_state_is_valid(a.dn_mode);
    return bs_is_valid(a.s);
}
aa_is_fix :: (i: u32) -> bool {
    a := aa(i);
    if a.kind == .DENORMAL_FP return a.dn_fix;
    return bs_is_fix(a.s);
}
aa_optimistic :: (i: u32) -> bool {
    a := aa(i);
    if a.kind == .DENORMAL_FP { ch := !a.dn_fix; a.dn_fix = true; return ch; }
    bs_optimistic(*a.s);
    return ATR_UNCHANGED;
}
// indicatePessimisticFixpoint (AAMemoryLocationImpl overrides it)
aa_pessimistic :: (i: u32) -> bool {
    a := aa(i);
    if a.kind == .DENORMAL_FP { ch := !a.dn_fix; a.dn_fix = true; return ch; }
    if a.kind == .MEM_LOCATION ml_pessimistic_accesses(i);
    return bs_pessimistic(*aa(i).s);
}

// Attributor::recordDependence
atr_record_dependence :: (from: u32, to: u32, cls: u8) {
    if cls == DEP_NONE return;
    if atr.dep_stack.count == 0 return;
    if aa_is_fix(from) return;
    array_add(atr.dep_stack[atr.dep_stack.count - 1], .{from, to, cls});
}
aa_add_dep :: (from: u32, dep: u32) {
    a := aa(from);
    for a.deps if it == dep return;
    array_add(*a.deps, dep);
}

// Attributor::lookupAAFor (AllowInvalidState: getOrCreateAAFor passes true)
atr_lookup :: (k: Atr_Kind, p: Irp, q: u32, cls: u8, allow_invalid := true) -> u32 {
    found, i := table_find(*atr.aa_map, aa_key(k, p));
    if !found return NONE;
    if cls != DEP_NONE && q != NONE && aa_is_valid(i) atr_record_dependence(i, q, cls);
    if !allow_invalid && !aa_is_valid(i) return NONE;
    return i;
}

// Attributor::getOrCreateAAFor (getAAFor is the same with a querying AA)
atr_get_aa :: (k: Atr_Kind, p: Irp, q: u32, cls: u8, update_after_init := true) -> u32 {
    existing := atr_lookup(k, p, q, cls);
    if existing != NONE return existing;
    ok, should_update := atr_should_initialize(k, p);
    if !ok return NONE;
    a := New(Abs_Attr);
    a.kind = k; a.pos = p; a.pk = irp_kind(p);
    a.s = bs_new(aa_best_state(k));
    i := cast(u32) atr.aas.count;
    array_add(*atr.aas, a);
    table_set(*atr.aa_map, aa_key(k, p), i);
    if atr.phase == .SEEDING || atr.phase == .UPDATE array_add(*atr.root, i);
    atr.init_chain += 1;
    aa_initialize(i);
    atr.init_chain -= 1;
    if !should_update { aa_pessimistic(i); return i; }
    if update_after_init {
        old := atr.phase;
        atr.phase = .UPDATE;
        atr_update_aa(i);
        atr.phase = old;
    }
    if q != NONE && aa_is_valid(i) atr_record_dependence(i, q, cls);
    return i;
}

// AbstractAttribute::update
aa_update :: (i: u32) -> bool {
    if aa_is_fix(i) return ATR_UNCHANGED;
    return aa_update_impl(i);
}

// Attributor::updateAA (UseLiveness is off: the AA is never assumed dead)
atr_update_aa :: (i: u32) -> bool {
    dv := New([..] Atr_Dep_Info);
    array_add(*atr.dep_stack, dv);
    cs := aa_update(i);
    if !aa_is_query(aa(i).kind) && dv.count == 0 && !aa_is_fix(i) {
        rerun := ATR_UNCHANGED;
        if cs rerun = aa_update(i);
        if !rerun && dv.count == 0 aa_optimistic(i);
    }
    if !aa_is_fix(i) {
        // rememberDependences
        for dv.* aa_add_dep(it.from, (it.to << 1) | cast(u32) it.cls);
    }
    pop(*atr.dep_stack);
    return cs;
}

atr_register_for_update :: (i: u32) {
    for atr.query_awaiting if it == i return;
    array_add(*atr.query_awaiting, i);
}

// ---------------------------------------------------------------- SetVector of AA indices

Aa_Set :: struct { list: [..] u32; member: Table(u32, bool); }
aset_insert :: (s: *Aa_Set, i: u32) -> bool {
    if table_contains(*s.member, i) return false;
    table_set(*s.member, i, true);
    array_add(*s.list, i);
    return true;
}
aset_clear :: (s: *Aa_Set) { s.list.count = 0; table_reset(*s.member); }

// Attributor::runTillFixpoint
atr_run_till_fixpoint :: () {
    iteration: u32 = 1;
    changed: [..] u32;
    worklist: Aa_Set;
    invalid: Aa_Set;
    for atr.root aset_insert(*worklist, it);
    while true {
        num_aas := atr.root.count;
        u := 0;
        while u < invalid.list.count {
            inv := invalid.list[u];
            u += 1;
            deps := aa(inv).deps;
            for d: deps {
                dep := d >> 1;
                if (d & 1) == DEP_OPTIONAL { aset_insert(*worklist, dep); continue; }
                aa_pessimistic(dep);
                if !aa_is_valid(dep) aset_insert(*invalid, dep);
                else array_add(*changed, dep);
            }
            aa(inv).deps.count = 0;
        }
        for c: changed {
            for d: aa(c).deps aset_insert(*worklist, d >> 1);
            aa(c).deps.count = 0;
        }
        changed.count = 0;
        aset_clear(*invalid);
        k := 0;
        while k < worklist.list.count {
            w := worklist.list[k];
            k += 1;
            if !aa_is_fix(w) if atr_update_aa(w) array_add(*changed, w);
            if !aa_is_valid(w) aset_insert(*invalid, w);
        }
        for j: num_aas..atr.root.count - 1 array_add(*changed, atr.root[j]);
        aset_clear(*worklist);
        for changed aset_insert(*worklist, it);
        for atr.query_awaiting aset_insert(*worklist, it);
        atr.query_awaiting.count = 0;
        if worklist.list.count == 0 break;
        iteration += 1;
        if !(iteration - 1 < atr_max_iterations) break;
    }
    // Reset abstract attributes not settled in a sound fixpoint by now.
    visited: Table(u32, bool);
    u := 0;
    while u < changed.count {
        c := changed[u];
        u += 1;
        if table_contains(*visited, c) continue;
        table_set(*visited, c, true);
        if !aa_is_fix(c) aa_pessimistic(c);
        for d: aa(c).deps array_add(*changed, d >> 1);
        aa(c).deps.count = 0;
    }
}

// Attributor::manifestAttributes
atr_manifest_attributes :: () -> bool {
    num_final := atr.root.count;
    change := ATR_UNCHANGED;
    for r: 0..num_final - 1 {
        i := atr.root[r];
        if !aa_is_fix(i) aa_optimistic(i);
        if !aa_is_valid(i) continue;
        p := aa(i).pos;
        if irp_ctx_i(p) != NONE && !atr_is_run_on(irp_anchor_scope(p)) continue;
        if aa_manifest(i) change = ATR_CHANGED;
    }
    if num_final != atr.root.count fatal("internal: attributor: abstract attributes were created during the manifest");
    for v, anchor: atr.attrs_map {
        if vkind(anchor) == .FUNCTION fn_set_attr_list(anchor, v);
        else inst(anchor).attrs = v;
    }
    return change;
}

// ---------------------------------------------------------------- attributes in the AttrsMap

// The attribute set of `p` as the Attributor currently sees it (updateAttrMap's lookup; inserts into the map).
atr_attr_set :: (p: Irp) -> (bool, u32) {
    k := irp_kind(p);
    if k == .FLOAT || k == .INVALID return false, 0;
    anchor := irp_attr_list_anchor(p);
    found, l := table_find(*atr.attrs_map, anchor);
    if !found {
        if irp_is_call(anchor) l = inst(anchor).attrs;
        else l = glob(anchor).attrs;
        table_set(*atr.attrs_map, anchor, l);
    }
    return true, attr_list_set_at(l, irp_attr_idx(p));
}
atr_set_attr_set :: (p: Irp, s: u32) {
    anchor := irp_attr_list_anchor(p);
    l := table_find_pointer(*atr.attrs_map, anchor);
    l.* = attr_list_with_set_at(l.*, irp_attr_idx(p), s);
}

// SubsumingPositionIterator
atr_subsuming_positions :: (p: Irp, out: *[..] Irp) {
    out.count = 0;
    array_add(out, p);
    can_ignore_bundles :: (cb: Value_Id) -> bool { return call_num_bundles(cb) == 0 || call_iid(cb) == IID_ASSUME; }
    k := irp_kind(p);
    if k == {
        case .ARGUMENT; #through;
        case .RETURNED;
            array_add(out, irp_function(irp_anchor_scope(p)));
        case .CALL_SITE;
            cb := irp_anchor(p);
            if can_ignore_bundles(cb) {
                callee := call_callee(cb);
                if vkind(callee) == .FUNCTION array_add(out, irp_function(callee));
            }
        case .CALL_SITE_RETURNED;
            cb := irp_anchor(p);
            if can_ignore_bundles(cb) {
                callee := call_callee(cb);
                if vkind(callee) == .FUNCTION {
                    array_add(out, irp_returned(callee));
                    array_add(out, irp_function(callee));
                    for k: 0..cast(s64) fn_nargs(callee) - 1 {
                        a := fn_arg(callee, cast(u32) k);
                        if arg_has_attr(a, .Returned) {
                            array_add(out, irp_cs_argument(cb, cast(u32) k));
                            array_add(out, irp_value(call_arg(cb, cast(u32) k)));
                            array_add(out, irp_argument(a));
                        }
                    }
                }
            }
            array_add(out, irp_cs_function(cb));
        case .CALL_SITE_ARGUMENT;
            cb := irp_anchor(p);
            if can_ignore_bundles(cb) {
                callee := call_callee(cb);
                if vkind(callee) == .FUNCTION {
                    a := irp_assoc_arg(p);
                    if a != NONE array_add(out, irp_argument(a));
                    array_add(out, irp_function(callee));
                }
            }
            array_add(out, irp_value(irp_assoc_value(p)));
    }
}

attr_enum :: (k: Attr_Kind, v: u64 = 0) -> Attr { a: Attr; a.kind = k; a.ty = NONE; a.ival = v; return a; }

// Attributor::getAttrsFromAssumes
atr_attrs_from_assumes :: (p: Irp, k: Attr_Kind, out: *[..] Attr) -> bool {
    v := irp_assoc_value(p);
    entries := table_find_pointer(*atr.knowledge, atr_knowledge_key(v, k));
    if !entries || entries.count == 0 return false;
    n := out.count;
    it := mbe_begin(irp_ctx_i(p));
    for e: entries.* if mbe_find_in_context_of(e.assume, *it) array_add(out, attr_enum(k, e.max));
    return n != out.count;
}

// Attributor::hasAttr
atr_has_attr :: (p: Irp, kinds: [] Attr_Kind, ignore_subsuming := false, implied_kind := Attr_Kind.NONE_ATTR) -> bool {
    implied := false;
    has := false;
    positions: [..] Irp; positions.allocator = temp;
    atr_subsuming_positions(p, *positions);
    for q: positions {
        ok, s := atr_attr_set(q);
        if ok for k: kinds if attr_set_has(s, k) { implied |= k != implied_kind; has = true; }
        if has break;
        if ignore_subsuming break;
        implied = true;
    }
    if !has {
        implied = true;
        attrs: [..] Attr; attrs.allocator = temp;
        for k: kinds if atr_attrs_from_assumes(p, k, *attrs) { has = true; break; }
    }
    if implied_kind != .NONE_ATTR && has && implied atr_manifest_attrs(p, .[attr_enum(implied_kind)]);
    return has;
}
// Attributor::getAttrs
atr_get_attrs :: (p: Irp, kinds: [] Attr_Kind, out: *[..] Attr, ignore_subsuming := false) {
    positions: [..] Irp; positions.allocator = temp;
    atr_subsuming_positions(p, *positions);
    for q: positions {
        ok, s := atr_attr_set(q);
        if ok for k: kinds { a := attr_set_find(s, k); if a array_add(out, a.*); }
        if ignore_subsuming break;
    }
    for k: kinds atr_attrs_from_assumes(p, k, out);
}
// Attributor::removeAttrs
atr_remove_attrs :: (p: Irp, kinds: [] Attr_Kind) -> bool {
    ok, s := atr_attr_set(p);
    if !ok return ATR_UNCHANGED;
    changed := false;
    for k: kinds if attr_set_has(s, k) changed = true;
    if !changed return ATR_UNCHANGED;
    ns := s;
    for k: kinds ns = attr_set_remove(ns, k);
    atr_set_attr_set(p, ns);
    return ATR_CHANGED;
}
// Attributor::manifestAttrs with addIfNotExistent
atr_manifest_attrs :: (p: Irp, attrs: [] Attr, force_replace := false) -> bool {
    if attrs.count == 0 return ATR_UNCHANGED;
    ok, s := atr_attr_set(p);
    if !ok return ATR_UNCHANGED;
    add: [..] Attr; add.allocator = temp;
    for at: attrs {
        k := at.kind;
        if k < .LAST_ENUM {
            if attr_set_has(s, k) continue;
            array_add(*add, at);
            continue;
        }
        if k == .STRING_ATTR fatal("internal: attributor: string attributes are not manifested by the light AAs");
        if k > .LAST_TYPE && k < .LAST_INT {
            if !force_replace && k == .Memory {
                old := attr_set_memory(s);
                me := at.ival & old;
                if me == old continue;
                array_add(*add, attr_enum(.Memory, me));
                continue;
            }
            old := attr_set_find(s, k);
            if old && !force_replace && old.ival >= at.ival continue;   // isEqualOrWorse
            array_add(*add, at);
            continue;
        }
        fatal("internal: attributor: unexpected attribute kind in manifestAttrs");
    }
    if add.count == 0 return ATR_UNCHANGED;
    ns := s;
    for add ns = attr_set_with(ns, it);
    atr_set_attr_set(p, ns);
    return ATR_CHANGED;
}

// ---------------------------------------------------------------- InformationCache

atr_knowledge_key :: (v: Value_Id, k: Attr_Kind) -> u64 { return ((cast(u64) v) << 8) | cast(u64) k; }

// InformationCache::getFunctionInfo (lazily runs initializeInformationCache)
atr_fn_info :: (f: Value_Id) -> *Atr_Fn_Info {
    found, fi := table_find(*atr.fn_info, f);
    if found return fi;
    fi = New(Atr_Fn_Info);
    table_set(*atr.fn_info, f, fi);
    atr_initialize_information_cache(f, fi);
    return fi;
}

atr_initialize_information_cache :: (f: Value_Id, fi: *Atr_Fn_Info) {
    fi.is_kernel = fn_has_str_attr(f, "kernel");
    assume_uses: Table(Value_Id, s64); assume_uses.allocator = temp;
    add_to_assume_uses_map :: (v: Value_Id, map: *Table(Value_Id, s64)) {
        work: [..] Value_Id; work.allocator = temp;
        if is_inst(v) array_add(*work, v);
        while work.count {
            i := pop(*work);
            p := table_find_pointer(map, i);
            if !p { table_set(map, i, num_uses(i)); p = table_find_pointer(map, i); }
            p.* -= 1;
            if p.* != 0 continue;
            table_set(*atr.assume_only, i, true);
            for k: 0..cast(s64) nops(i) - 1 { o := op(i, cast(u32) k); if is_inst(o) array_add(*work, o); }
        }
    }
    for i: fn_insts(f) {
        o := inst_op(i);
        interesting := false;
        if o == {
            case .CALL;
                if call_iid(i) == IID_ASSUME {
                    table_set(*atr.assume_only, i, true);
                    atr_fill_map_from_assume(i);
                    add_to_assume_uses_map(call_arg(i, 0), *assume_uses);
                } else if ((inst(i).flags >> TAIL_SHIFT) & 3) == 2 {
                    fi.contains_must_tail = true;
                    callee := call_callee(i);
                    if vkind(callee) == .FUNCTION atr_fn_info(callee).called_via_must_tail = true;
                }
                interesting = true;
            case .CALLBR; #through; case .INVOKE; #through; case .CLEANUPRET; #through; case .CATCHSWITCH; #through;
            case .ATOMICRMW; #through; case .CMPXCHG; #through; case .BR; #through; case .CONDBR; #through;
            case .RESUME; #through; case .RET; #through; case .LOAD; #through; case .STORE; #through;
            case .ALLOCA; #through; case .ADDRSPACECAST;
                interesting = true;
        }
        if interesting {
            l := table_find_pointer(*fi.by_opcode, cast(u8) o);
            if !l { e: [..] Value_Id; table_set(*fi.by_opcode, cast(u8) o, e); l = table_find_pointer(*fi.by_opcode, cast(u8) o); }
            array_add(l, i);
        }
        if may_read_or_write_memory(i) array_add(*fi.rw_insts, i);
    }
    if fn_has_fn_attr(f, .AlwaysInline) && is_inline_viable(f).ok table_set(*atr.inlineable, f, true);
}

// fillMapFromAssume
atr_fill_map_from_assume :: (assume: Value_Id) {
    nb := call_num_bundles(assume);
    if nb == 0 return;
    for b: 0..nb - 1 {
        tag := call_bundle_tag(assume, b);
        kind := attr_kind_from_name(tag);
        beg, end := call_bundle_range(assume, b);
        was_on: Value_Id = NONE;
        if end > beg was_on = op(assume, beg);
        if was_on == NONE && kind == .NONE_ATTR continue;
        key := atr_knowledge_key(was_on, kind);
        entries := table_find_pointer(*atr.knowledge, key);
        if !entries { e: [..] Atr_Knowledge; table_set(*atr.knowledge, key, e); entries = table_find_pointer(*atr.knowledge, key); }
        idx := -1;
        for entries.* if it.assume == assume { idx = it_index; break; }
        if end - beg <= 1 {
            if idx < 0 array_add(entries, .{assume, 0, 0});
            else { entries.*[idx].min = 0; entries.*[idx].max = 0; }
            continue;
        }
        c := op(assume, beg + 1);
        if vkind(c) != .C_INT || is_vector_type(vtype(c)) continue;
        val := ap_zext_value(const_ap(c));
        if idx < 0 { array_add(entries, .{assume, val, val}); continue; }
        if val < entries.*[idx].min entries.*[idx].min = val;
        if val > entries.*[idx].max entries.*[idx].max = val;
    }
}

// getKnowledgeFromUse(U, {NonNull, Dereferenceable}): (kind, argument) of the assume bundle using U
atr_knowledge_from_use :: (u: Use_Id) -> (bool, Attr_Kind, u64) {
    user := ir.u_user[u];
    if !is_inst(user) || inst_op(user) != .CALL || call_iid(user) != IID_ASSUME return false, .NONE_ATTR, 0;
    if call_arg(user, 0) == ir.u_val[u] return false, .NONE_ATTR, 0;   // m_Unless(m_Specific(U->get()))
    opno := u - ir.v_ops[user];
    nb := call_num_bundles(user);
    for b: 0..cast(s64) nb - 1 {
        beg, end := call_bundle_range(user, cast(u32) b);
        if opno < beg || opno >= end continue;
        kind := attr_kind_from_name(call_bundle_tag(user, cast(u32) b));
        arg: u64 = 0;
        if end - beg > 1 {
            c := op(user, beg + 1);
            ok := vkind(c) == .C_INT && !is_vector_type(vtype(c));
            if kind == .Alignment {
                arg = ifx ok then ap_zext_value(const_ap(c)) else 1;
                if end - beg > 2 {
                    c2 := op(user, beg + 2);
                    a2: u64 = 1;
                    if vkind(c2) == .C_INT && !is_vector_type(vtype(c2)) a2 = ap_zext_value(const_ap(c2));
                    arg = min_align(arg, a2);
                }
            } else if kind == .Dereferenceable || kind == .DereferenceableOrNull {
                arg = ifx ok then ap_zext_value(const_ap(c)) else 0;
            } else if kind != .NONE_ATTR {
                fatal("internal: attributor: assume bundle '%' has an argument", call_bundle_tag(user, cast(u32) b));
            }
        }
        if kind == .NonNull || kind == .Dereferenceable return true, kind, arg;
        return false, .NONE_ATTR, 0;
    }
    return false, .NONE_ATTR, 0;
}
min_align :: (a: u64, b: u64) -> u64 { x := a | b; return x & (~x + 1); }

// AnalysisGetter: cached results only for the module pass, computed ones for the CGSCC pass
atr_dt :: (f: Value_Id) -> *Dom_Tree { if atr.cached_only return cached_domtree(f); return get_domtree(f); }
atr_pdt :: (f: Value_Id) -> *Dom_Tree { if atr.cached_only return cached_postdomtree(f); return get_postdomtree(f); }
atr_li :: (f: Value_Id) -> *Loop_Info { if atr.cached_only return cached_loop_info(f); return get_loop_info(f); }
atr_ac :: (f: Value_Id) -> *Assumption_Cache { if atr.cached_only return cached_assumption_cache(f); return get_assumption_cache(f); }
atr_se :: (f: Value_Id) -> *Scev_State { if atr.cached_only return cached_scev(f); return get_scev(f); }
// TargetLibraryAnalysis is never cached before the pass runs when opt starts with it; the CGSCC pass computes it.
atr_have_tli :: () -> bool { return !atr.cached_only; }

// ---------------------------------------------------------------- MustBeExecutedContextExplorer

Mbe_Iter :: struct { visited: Table(u64, bool); cur: Value_Id = NONE; head: Value_Id = NONE; tail: Value_Id = NONE; }
MBE_BACKWARD :: cast(u64) 0;
MBE_FORWARD :: cast(u64) 1;
mbe_key :: inline (i: Value_Id, dir: u64) -> u64 { return ((cast(u64) i) << 1) | dir; }

// begin(PP): a fresh copy of the iterator for PP (callers copy the cached one before advancing it)
mbe_begin :: (pp: Value_Id) -> Mbe_Iter {
    it: Mbe_Iter;
    it.visited.allocator = temp;
    it.cur = pp; it.head = pp; it.tail = pp;
    table_set(*it.visited, mbe_key(pp, MBE_FORWARD), true);
    table_set(*it.visited, mbe_key(pp, MBE_BACKWARD), true);
    return it;
}
mbe_at_end :: inline (it: *Mbe_Iter) -> bool { return it.cur == NONE && it.head == NONE && it.tail == NONE; }
mbe_count :: (it: *Mbe_Iter, i: Value_Id) -> bool {
    return table_contains(*it.visited, mbe_key(i, MBE_FORWARD)) || table_contains(*it.visited, mbe_key(i, MBE_BACKWARD));
}
// MustBeExecutedIterator::advance
mbe_advance :: (it: *Mbe_Iter) {
    it.head = mbe_next_instruction(it.head);
    if it.head != NONE && !table_contains(*it.visited, mbe_key(it.head, MBE_FORWARD)) {
        table_set(*it.visited, mbe_key(it.head, MBE_FORWARD), true);
        it.cur = it.head;
        return;
    }
    it.head = NONE;
    it.tail = mbe_prev_instruction(it.tail);
    if it.tail != NONE && !table_contains(*it.visited, mbe_key(it.tail, MBE_BACKWARD)) {
        table_set(*it.visited, mbe_key(it.tail, MBE_BACKWARD), true);
        it.cur = it.tail;
        return;
    }
    it.tail = NONE;
    it.cur = NONE;
}
// findInContextOf(I, EIt, EEnd)
mbe_find_in_context_of :: (i: Value_Id, it: *Mbe_Iter) -> bool {
    found := mbe_count(it, i);
    while !found && !mbe_at_end(it) {
        mbe_advance(it);
        found = it.cur == i;
    }
    return found;
}

mbe_maybe_endless_loop :: (f: Value_Id) -> bool { return !fn_has_fn_attr(f, .WillReturn); }

// MustBeExecutedContextExplorer::findForwardJoinPoint
mbe_find_forward_join_point :: (init_bb: Value_Id) -> Value_Id {
    f := block_fn(init_bb);
    li := atr_li(f);
    pdt := atr_pdt(f);
    l: Loop_Id = NONE;
    if li l = li_loop_for(li, init_bb);
    header_bb := ifx l != NONE then li_header(li, l) else init_bb;
    will_return_and_no_throw := (fn_has_fn_attr(f, .WillReturn) || (l != NONE && !mbe_maybe_endless_loop(f))) && fn_has_fn_attr(f, .NoUnwind);
    work: [..] Value_Id; work.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(init_bb, *succs);
    for s: succs {
        is_latch := s == header_bb;
        if !will_return_and_no_throw || !is_latch array_add(*work, s);
    }
    if work.count == 0 return NONE;
    if work.count == 1 return work[0];
    join: Value_Id = NONE;
    if pdt {
        n := dt_node(pdt, init_bb);
        if n >= 0 {
            idom := pdt.nodes[n].idom;
            if idom >= 0 join = pdt.nodes[idom].block;
        }
    }
    if join == NONE && work.count == 2 {
        s0 := work[0]; s1 := work[1];
        s0u := block_unique_successor(s0);
        s1u := block_unique_successor(s1);
        if s0u == init_bb join = s1;
        else if s1u == init_bb join = s0;
        else if s0 == s1u join = s0;
        else if s1 == s0u join = s1;
        else if s0u == s1u join = s0u;
    }
    if join == NONE && l != NONE join = li_unique_exit_block(li, l);
    if join == NONE return NONE;
    if !fn_has_fn_attr(f, .WillReturn) || !fn_has_fn_attr(f, .NoUnwind) {
        visited: Table(Value_Id, bool); visited.allocator = temp;
        while work.count {
            to_bb := pop(*work);
            if to_bb == join continue;
            if table_contains(*visited, to_bb) {
                if !fn_has_fn_attr(f, .WillReturn) {
                    if !li return NONE;
                    found, irr := table_find(*atr.irreducible, f);
                    if !found { irr = mbe_may_contain_irreducible_control(f, li); table_set(*atr.irreducible, f, irr); }
                    if irr return NONE;
                    tl := li_loop_for(li, to_bb);
                    if tl != NONE && mbe_maybe_endless_loop(f) return NONE;
                }
                continue;
            }
            table_set(*visited, to_bb, true);
            found, transfers := table_find(*atr.block_transfer, to_bb);
            if !found { transfers = is_guaranteed_to_transfer_execution_block(to_bb); table_set(*atr.block_transfer, to_bb, transfers); }
            if !transfers return NONE;
            succs.count = 0;
            block_successors(to_bb, *succs);
            for succs array_add(*work, it);
        }
    }
    return join;
}
// mayContainIrreducibleControl
mbe_may_contain_irreducible_control :: (f: Value_Id, li: *Loop_Info) -> bool {
    if !li return false;
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(f), *po);
    rpo: [..] Value_Id; rpo.allocator = temp;
    for < po array_add(*rpo, it);
    return contains_irreducible_cfg_rpo(li, rpo);
}

// MustBeExecutedContextExplorer::findBackwardJoinPoint
mbe_find_backward_join_point :: (init_bb: Value_Id) -> Value_Id {
    f := block_fn(init_bb);
    li := atr_li(f);
    dt := atr_dt(f);
    if dt {
        n := dt_node(dt, init_bb);
        if n >= 0 {
            idom := dt.nodes[n].idom;
            if idom >= 0 return dt.nodes[idom].block;
        }
    }
    l: Loop_Id = NONE;
    if li l = li_loop_for(li, init_bb);
    header_bb := ifx l != NONE then li_header(li, l) else NONE;
    work: [..] Value_Id; work.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(init_bb, *preds);
    for p: preds {
        is_backedge := p == init_bb || (header_bb == init_bb && li_contains(li, l, p));
        if !is_backedge array_add(*work, p);
    }
    if work.count == 0 return NONE;
    if work.count == 1 return work[0];
    join: Value_Id = NONE;
    if work.count == 2 {
        p0 := work[0]; p1 := work[1];
        p0u := block_unique_predecessor(p0);
        p1u := block_unique_predecessor(p1);
        if p0 == p1u join = p0;
        else if p1 == p0u join = p1;
        else if p0u == p1u join = p0u;
    }
    if join == NONE && l != NONE join = li_header(li, l);
    return join;
}

// getMustBeExecutedNextInstruction
mbe_next_instruction :: (pp: Value_Id) -> Value_Id {
    if pp == NONE return NONE;
    if !is_guaranteed_to_transfer_execution(pp) return NONE;
    if !is_terminator(inst_op(pp)) return inst_next(pp);
    n := num_successors(pp);
    if n == 0 return NONE;
    if n == 1 return block_first(get_successor(pp, 0));
    join := mbe_find_forward_join_point(inst_block(pp));
    if join != NONE return block_first(join);
    return NONE;
}
// getMustBeExecutedPrevInstruction
mbe_prev_instruction :: (pp: Value_Id) -> Value_Id {
    if pp == NONE return NONE;
    prev := inst_prev(pp);
    if prev != NONE return prev;
    join := mbe_find_backward_join_point(inst_block(pp));
    if join != NONE return block_last(join);
    return NONE;
}

// ---------------------------------------------------------------- queries over the IR

// The instructions of `f` with the given opcodes, in checkForAllInstructionsImpl order (opcode by opcode).
// Returns false where checkForAllInstructions would fail before calling its predicate (no definition).
atr_insts :: (f: Value_Id, opcodes: [] Opcode) -> (bool, [..] Value_Id) {
    r: [..] Value_Id; r.allocator = temp;
    if f == NONE || is_declaration(f) return false, r;
    fi := atr_fn_info(f);
    for o: opcodes {
        l := table_find_pointer(*fi.by_opcode, cast(u8) o);
        if l for l.* array_add(*r, it);
    }
    return true, r;
}
CALL_LIKE_OPCODES :: Opcode.[.INVOKE, .CALLBR, .CALL];
// checkForAllCallLikeInstructions / checkForAllInstructions with the querying AA's associated function
atr_call_like_insts :: (q: u32) -> (bool, [..] Value_Id) { ok, r := atr_insts(irp_assoc_fn(aa(q).pos), CALL_LIKE_OPCODES); return ok, r; }
atr_aa_insts :: (q: u32, opcodes: [] Opcode) -> (bool, [..] Value_Id) { ok, r := atr_insts(irp_assoc_fn(aa(q).pos), opcodes); return ok, r; }
// checkForAllReadWriteInstructions
atr_rw_insts :: (q: u32) -> (bool, [..] Value_Id) {
    r: [..] Value_Id; r.allocator = temp;
    f := irp_assoc_fn(aa(q).pos);
    if f == NONE return false, r;
    for atr_fn_info(f).rw_insts array_add(*r, it);
    return true, r;
}

// checkForAllCallSites: the call sites the predicate is applied to, in order; `complete` is false if the walk stops
// (after those) with a failure.
atr_call_sites :: (f: Value_Id, require_all: bool) -> (sites: [..] Value_Id, complete: bool) {
    sites: [..] Value_Id; sites.allocator = temp;
    if require_all && !gv_has_local_linkage(f) return sites, false;
    uses: [..] Use_Id; uses.allocator = temp;
    // a blockaddress has no operands in LLVM 23 (here it uses its function): not a use of the function
    u := ir.v_first_use[f];
    while u != NONE { if vkind(ir.u_user[u]) != .C_BLOCKADDR array_add(*uses, u); u = ir.u_next[u]; }
    k := 0;
    while k < uses.count {
        cu := uses[k];
        k += 1;
        user := ir.u_user[cu];
        if vkind(user) == .C_EXPR && is_cast_op(cexpr(user).op) && is_ptr_type(vtype(user)) {
            x := ir.v_first_use[user];
            while x != NONE { array_add(*uses, x); x = ir.u_next[x]; }
            continue;
        }
        // AbstractCallSite(&U)
        eu := cu;
        cb := user;
        if !irp_is_call(cb) {
            cb = NONE;
            if vkind(user) == .C_EXPR && num_uses(user) == 1 && is_cast_op(cexpr(user).op) {
                eu = ir.v_first_use[user];
                if irp_is_call(ir.u_user[eu]) cb = ir.u_user[eu];
            }
            if cb == NONE return sites, false;
        }
        is_callee := eu == op_use(cb, nops(cb) - 1);
        if !is_callee {
            // a non-callee operand of a call with a known callee but no !callback: not a call site
            if !require_all continue;
            return sites, false;
        }
        n := min(cast(s64) call_num_args(cb), cast(s64) fn_nargs(f));
        for a: 0..n - 1 if vtype(fn_arg(f, cast(u32) a)) != vtype(call_arg(cb, cast(u32) a)) return sites, false;
        array_add(*sites, cb);
    }
    return sites, true;
}

// checkForAllCallees: the possible callees of `cb` (false: unknown)
atr_callees :: (q: u32, cb: Value_Id) -> (bool, [..] Value_Id) {
    r: [..] Value_Id; r.allocator = temp;
    c := call_callee(cb);
    if vkind(c) == .FUNCTION { array_add(*r, c); return true, r; }
    e := atr_get_aa(.CALL_EDGES, irp_cs_function(cb), q, DEP_OPTIONAL);
    if e == NONE || aa(e).unknown_callee return false, r;
    for aa(e).callees array_add(*r, it);
    return true, r;
}

// getAssumedSimplifiedValues without AAPotentialValues: the value itself, or failure for a returned position
atr_simplified_values_ok :: (p: Irp) -> bool { return irp_kind(p) != .RETURNED; }

// Attributor::checkForAllUses as an explicit walk: atr_uses_next returns the next use for the predicate (or NONE
// when done); after the predicate, atr_uses_follow adds the users' uses when it asked to follow.
Uses_Walk :: struct {
    work: [..] Use_Id;
    visited: Table(Use_Id, bool);
    q: u32;
}
atr_uses_begin :: (q: u32, v: Value_Id) -> (bool, Uses_Walk) {
    w: Uses_Walk;
    w.work.allocator = temp;
    w.visited.allocator = temp;
    w.q = q;
    if is_constant_data(v) return false, w;
    atr_uses_add(*w, v);
    return true, w;
}
atr_uses_add :: (w: *Uses_Walk, v: Value_Id) {
    u := ir.v_first_use[v];
    while u != NONE { array_add(*w.work, u); u = ir.u_next[u]; }
}
atr_uses_next :: (w: *Uses_Walk) -> Use_Id {
    while w.work.count {
        u := pop(*w.work);
        user := ir.u_user[u];
        can_mark := !is_inst(user) || inst_op(user) == .PHI;
        if can_mark {
            if table_contains(*w.visited, u) continue;
            table_set(*w.visited, u, true);
        }
        if is_droppable_user(user) continue;
        if is_inst(user) && inst_op(user) == .STORE && u == op_use(user, 0) {
            if table_contains(*w.visited, u) continue;
            table_set(*w.visited, u, true);
            if atr_stored_value_has_no_copies(user, w.q) continue;   // all potential copies (none) visited
        }
        return u;
    }
    return NONE;
}
atr_uses_follow :: (w: *Uses_Walk, u: Use_Id) { atr_uses_add(w, ir.u_user[u]); }

// AA::getPotentialCopiesOfStoredValue(OnlyExact) without AAPointerInfo: it succeeds (with no copies) only if every
// underlying object of the pointer is undef, or null where null is not defined and the pointer is that null.
atr_stored_value_has_no_copies :: (si: Value_Id, q: u32) -> bool {
    ptr := op(si, 1);
    uo := atr_get_aa(.UNDERLYING_OBJECTS, irp_value(ptr), q, DEP_OPTIONAL);
    if uo == NONE return false;
    objs: [..] Value_Id; objs.allocator = temp;
    uo_objects(uo, false, *objs);
    for obj: objs {
        k := vkind(obj);
        if k == .C_UNDEF || k == .C_POISON continue;
        if k == .C_NULL {
            if !null_pointer_is_defined(inst_fn(si), ptr_addrspace(vtype(ptr))) && ptr == obj continue;
            return false;
        }
        return false;
    }
    return true;
}

// AA::isNoSyncInst
atr_is_no_sync_inst :: (i: Value_Id, q: u32) -> bool {
    if is_call_base(i) {
        if call_has_fn_attr(i, .NoSync) return true;
        if !call_has_fn_attr(i, .Convergent) && !may_read_or_write_memory(i) return true;
        ok, _ := atr_has_assumed_ir_attr(.NoSync, q, irp_cs_function(i), DEP_OPTIONAL);
        return ok;
    }
    if !may_read_or_write_memory(i) return true;
    return !aa_is_non_relaxed_atomic(i);
}
// AANoSync::isNonRelaxedAtomic
aa_is_non_relaxed_atomic :: (i: Value_Id) -> bool {
    if !inst_is_atomic(i) return false;
    r := inst(i);
    if r.op == .FENCE return r.sync != SYNC_SCOPE_SINGLE_THREAD;
    if r.op == .CMPXCHG return r.ord1 != ORD_MONOTONIC || r.ord2 != ORD_MONOTONIC;
    if r.op == .ATOMICRMW || r.op == .STORE || r.op == .LOAD return r.ord1 != ORD_UNORDERED && r.ord1 != ORD_MONOTONIC;
    fatal("internal: attributor: new atomic operation");
    return true;
}

// isAssumedReadOnlyOrReadNone
atr_is_assumed_read_only_or_none :: (p: Irp, q: u32, require_read_none: bool) -> (bool, bool) {
    if require_read_none {
        ok, known := atr_has_assumed_ir_attr(.ReadNone, q, p, DEP_OPTIONAL, true);
        if ok return true, known;
    } else {
        ok, known := atr_has_assumed_ir_attr(.ReadOnly, q, p, DEP_OPTIONAL, true);
        if ok return true, known;
    }
    k := irp_kind(p);
    if k == .FUNCTION || k == .CALL_SITE {
        ml := atr_get_aa(.MEM_LOCATION, p, q, DEP_NONE);
        if ml != NONE && ml_is_assumed_read_none(aa(ml).s) {
            known := ml_is_known_read_none(aa(ml).s);
            if !known atr_record_dependence(ml, q, DEP_OPTIONAL);
            return true, known;
        }
    }
    mb := atr_get_aa(.MEM_BEHAVIOR, p, q, DEP_NONE);
    if mb != NONE {
        s := aa(mb).s;
        if bs_is_assumed(s, MB_NO_ACCESSES) || (!require_read_none && bs_is_assumed(s, MB_NO_WRITES)) {
            known := ifx require_read_none then bs_is_known(s, MB_NO_ACCESSES) else bs_is_known(s, MB_NO_WRITES);
            if !known atr_record_dependence(mb, q, DEP_OPTIONAL);
            return true, known;
        }
    }
    return false, false;
}
atr_is_assumed_read_only :: (p: Irp, q: u32) -> (bool, bool) { a, k := atr_is_assumed_read_only_or_none(p, q, false); return a, k; }
atr_is_assumed_read_none :: (p: Irp, q: u32) -> (bool, bool) { a, k := atr_is_assumed_read_only_or_none(p, q, true); return a, k; }

// AA::hasAssumedIRAttr: (assumed, known, the AA queried or NONE)
atr_has_assumed_ir_attr :: (ak: Attr_Kind, q: u32, p: Irp, cls: u8, ignore_subsuming := false) -> (bool, bool, u32) {
    k: Atr_Kind;
    bits: u32 = 1;
    implied := false;
    if ak == {
        case .NoUnwind; k = .NO_UNWIND; implied = atr_default_implied_by_ir(p, ak, ignore_subsuming);
        case .WillReturn; k = .WILL_RETURN; implied = aa_will_return_implied_by_ir(p, ignore_subsuming);
        case .NoFree; k = .NO_FREE; implied = atr_has_attr(p, .[.ReadNone, .ReadOnly, .NoFree], ignore_subsuming, .NoFree);
        case .Captures; k = .NO_CAPTURE; bits = 7; implied = aa_no_capture_implied_by_ir(p, ignore_subsuming);
        case .NoRecurse; k = .NO_RECURSE; implied = atr_default_implied_by_ir(p, ak, ignore_subsuming);
        case .NoReturn; k = .NO_RETURN; implied = atr_default_implied_by_ir(p, ak, ignore_subsuming);
        case .NoSync; k = .NO_SYNC; implied = aa_no_sync_implied_by_ir(p, ignore_subsuming);
        case .NoAlias;
            if aa_no_alias_implied_by_ir(p, ignore_subsuming) return true, true, NONE;
            return false, false, NONE;   // AANoAlias is not allowed
        case .NonNull; k = .NON_NULL; implied = aa_non_null_implied_by_ir(p, ignore_subsuming);
        case .MustProgress; k = .MUST_PROGRESS; implied = atr_has_attr(p, .[.MustProgress, .WillReturn], ignore_subsuming, .MustProgress);
        case .ReadNone; k = .MEM_BEHAVIOR; bits = MB_NO_ACCESSES; implied = atr_default_implied_by_ir(p, ak, ignore_subsuming);
        case .ReadOnly; k = .MEM_BEHAVIOR; bits = MB_NO_WRITES; implied = atr_default_implied_by_ir(p, ak, ignore_subsuming);
        case .WriteOnly; k = .MEM_BEHAVIOR; bits = MB_NO_READS; implied = atr_default_implied_by_ir(p, ak, ignore_subsuming);
        case; fatal("internal: attributor: hasAssumedIRAttr not available for this attribute kind");
    }
    if implied return true, true, NONE;
    if q == NONE return false, false, NONE;
    i := atr_get_aa(k, p, q, cls);
    if i == NONE || !bs_is_assumed(aa(i).s, bits) return false, false, i;
    return true, bs_is_known(aa(i).s, bits), i;
}
// IRAttribute::isImpliedByIR
atr_default_implied_by_ir :: (p: Irp, ak: Attr_Kind, ignore_subsuming: bool) -> bool {
    v := irp_assoc_value(p);
    k := vkind(v);
    if k == .C_UNDEF || k == .C_POISON return true;
    return atr_has_attr(p, .[ak], ignore_subsuming, ak);
}

// ---------------------------------------------------------------- the driver

// runAttributorLightOnFunctions
attributor_light_run_on :: (functions: [] Value_Id, is_module_pass: bool, cached_only: bool) -> (bool, [..] Value_Id) {
    atr = .{};
    atr.is_module_pass = is_module_pass;
    atr.cached_only = cached_only;
    for functions { array_add(*atr.functions, it); table_set(*atr.fn_set, it, true); }
    modified: [..] Value_Id; modified.allocator = temp;
    if functions.count == 0 return false, modified;
    // !callback metadata needs AbstractCallSite callback calls, which are not ported
    for f: ir.m_functions if fn_has_callback_md(f) fatal("attributor-light: !callback metadata is not supported yet");
    atr.phase = .SEEDING;
    for f: functions {
        if is_declaration(f) continue;
        atr_identify_default_abstract_attributes(f);
    }
    atr.phase = .UPDATE;
    atr_run_till_fixpoint();
    atr.phase = .MANIFEST;
    // modified functions: the anchors of the AttrsMap that changed (getModifiedFunctions is CGModifiedFunctions,
    // which only cleanupIR fills; it stays empty here)
    changed := atr_manifest_attributes();
    atr.phase = .CLEANUP;
    return changed, modified;
}

// Attributor::checkAndQueryIRAttr
atr_check_and_query :: (ak: Attr_Kind, k: Atr_Kind, p: Irp, s: u32, skip_has_attr_check := false) {
    if skip_has_attr_check || !attr_set_has(s, ak) {
        ok, _ := atr_has_assumed_ir_attr(ak, NONE, p, DEP_NONE);
        if !ok atr_get_aa(k, p, NONE, DEP_NONE);
    }
}

// Attributor::identifyDefaultAbstractAttributes, restricted to the allowed AAs (the others are never created, and
// getAssumedSimplified / checkAndQueryIRAttr for not-allowed kinds have no effect)
atr_identify_default_abstract_attributes :: (f: Value_Id) {
    if table_contains(*atr.visited_functions, f) return;
    table_set(*atr.visited_functions, f, true);
    fi := atr_fn_info(f);
    if !atr.is_module_pass && !fi.called_via_must_tail {
        u := ir.v_first_use[f];
        while u != NONE {
            usr := ir.u_user[u];
            if irp_is_call(usr) && u == op_use(usr, nops(usr) - 1) && ((inst(usr).flags >> TAIL_SHIFT) & 3) == 2 fi.called_via_must_tail = true;
            u = ir.u_next[u];
        }
    }
    fpos := irp_function(f);
    ipo := atr_is_ipo_amendable(f);
    attrs := glob(f).attrs;
    fn_attrs := attr_list_fn(attrs);
    atr_check_and_query(.MustProgress, .MUST_PROGRESS, fpos, fn_attrs);
    atr_check_and_query(.NoFree, .NO_FREE, fpos, fn_attrs);
    atr_check_and_query(.WillReturn, .WILL_RETURN, fpos, fn_attrs);
    atr_check_and_query(.NoSync, .NO_SYNC, fpos, fn_attrs);
    if ipo {
        atr_check_and_query(.NoUnwind, .NO_UNWIND, fpos, fn_attrs);
        atr_check_and_query(.NoReturn, .NO_RETURN, fpos, fn_attrs);
        atr_check_and_query(.NoRecurse, .NO_RECURSE, fpos, fn_attrs);
        atr_get_aa(.MEM_BEHAVIOR, fpos, NONE, DEP_NONE);
        atr_get_aa(.MEM_LOCATION, fpos, NONE, DEP_NONE);
        // getDenormalMode(IEEEsingle): the f32 mode if set, else the default one
        if dn_f32_mode_is_dynamic(f) atr_get_aa(.DENORMAL_FP, fpos, NONE, DEP_NONE);
        rt := fn_ret_type(f);
        if type_kind(rt) != .VOID {
            rpos := irp_returned(f);
            ret_attrs := attr_list_ret(attrs);
            if is_ptr_type(rt) {
                atr_check_and_query(.NonNull, .NON_NULL, rpos, ret_attrs);
            } else if is_fp_math_type(rt) {
                atr_get_aa(.NO_FPCLASS, rpos, NONE, DEP_NONE);
            }
        }
    }
    for k: 0..cast(s64) fn_nargs(f) - 1 {
        a := fn_arg(f, cast(u32) k);
        apos := irp_argument(a);
        arg_attrs := attr_list_param(attrs, cast(u32) k);
        if !ipo {
            if is_ptr_type(vtype(a)) atr_check_and_query(.NoFree, .NO_FREE, apos, arg_attrs);
            continue;
        }
        if is_ptr_type(vtype(a)) {
            atr_check_and_query(.NonNull, .NON_NULL, apos, arg_attrs);
            atr_check_and_query(.Captures, .NO_CAPTURE, apos, arg_attrs, true);
            atr_get_aa(.MEM_BEHAVIOR, apos, NONE, DEP_NONE);
            atr_check_and_query(.NoFree, .NO_FREE, apos, arg_attrs);
        } else if is_fp_math_type(vtype(a)) {
            atr_get_aa(.NO_FPCLASS, apos, NONE, DEP_NONE);
        }
    }
    _, calls := atr_insts(f, CALL_LIKE_OPCODES);
    for cb: calls {
        callee := call_callee(cb);
        if vkind(callee) != .FUNCTION continue;   // AAIndirectCallInfo is not allowed
        if is_declaration(callee) && !fn_has_callback_md(callee) continue;
        if type_kind(fn_ret_type(callee)) != .VOID && has_uses(cb) {
            if is_fp_math_type(fn_ret_type(callee)) atr_get_aa(.NO_FPCLASS, irp_inst(cb), NONE, DEP_NONE);
        }
        cb_attrs := inst(cb).attrs;
        for k: 0..cast(s64) call_num_args(cb) - 1 {
            cpos := irp_cs_argument(cb, cast(u32) k);
            cs_attrs := attr_list_param(cb_attrs, cast(u32) k);
            at := vtype(call_arg(cb, cast(u32) k));
            if !is_ptr_type(at) {
                if is_fp_math_type(at) atr_get_aa(.NO_FPCLASS, cpos, NONE, DEP_NONE);
                continue;
            }
            atr_check_and_query(.NonNull, .NON_NULL, cpos, cs_attrs);
            atr_check_and_query(.Captures, .NO_CAPTURE, cpos, cs_attrs, true);
            if !attr_set_has(cs_attrs, .ReadNone) atr_get_aa(.MEM_BEHAVIOR, cpos, NONE, DEP_NONE);
            atr_check_and_query(.NoFree, .NO_FREE, cpos, cs_attrs);
        }
    }
    // the load/store and alloca seeds only create AAs that are not allowed
}

// ---------------------------------------------------------------- the passes

// AttributorLightPass::run
attributor_light_module_run :: () -> Preserved {
    functions: [..] Value_Id; functions.allocator = temp;
    for ir.m_functions array_add(*functions, it);
    changed, _ := attributor_light_run_on(functions, true, true);
    return attributor_light_preserved(changed);
}
// AttributorLightCGSCCPass::run
attributor_light_cgscc_run :: (c: s32) -> Preserved {
    functions: [..] Value_Id; functions.allocator = temp;
    for lcg.sccs[c].nodes array_add(*functions, lcg_fn(it));
    if functions.count == 0 return PRESERVE_ALL;
    changed, _ := attributor_light_run_on(functions, false, false);
    return attributor_light_preserved(changed);
}
attributor_light_preserved :: (changed: bool) -> Preserved {
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    pa: Preserved;
    pa.all_fn = true;
    return pa;
}
