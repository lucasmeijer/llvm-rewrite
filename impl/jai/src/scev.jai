// ScalarEvolution, part 1: SCEV nodes, uniquing and the folding constructors.
// Port of llvm/lib/Analysis/ScalarEvolution.cpp (LLVM 23.1.5): SCEV::print, CompareValueComplexity /
// CompareSCEVComplexity / GroupByComplexity, constantFoldAndGroupOps, BinomialCoefficient, evaluateAtIteration,
// getConstant .. getUnknown (truncate / zero / sign / any extend with the AddRec no-wrap reasoning, getAddExpr,
// getMulExpr, getUDivExpr, getURemExpr, getAddRecExpr, getGEPExpr, getMinMaxExpr, getSequentialMinMaxExpr,
// getPtrToIntExpr / getPtrToAddrExpr), the type helpers and getMinusSCEV / getNegativeSCEV / getNotSCEV.
// Also include/llvm/Analysis/ScalarEvolutionExpressions.h (node kinds, flags, SCEVTraversal) and
// ScalarEvolutionPatternMatch.h (the matchers are spelled out inline).
//
// Data-oriented (DESIGN.md "ScalarEvolution"): a SCEV is a Scev_Id row of `se.nodes` (id 0 = SCEVCouldNotCompute),
// its operands a run in `se.ops`. Nodes are uniqued like LLVM's FoldingSet: a hash of (kind, operands, type, value,
// loop) into `se.unique` (bucket head) chained through Scev_Row.hnext. SCEVUse in LLVM 23 can carry use-specific
// no-wrap flags, but nothing in 23.1.5 creates such a use, so operands are plain ids (every SCEV is canonical).
// One ScalarEvolution per function lives on the heap (Fn_Analyses.se); the procedures below work on the global
// `se`, which get_scev(f) points at the function's instance.
//
// Operand lists (LLVM's SmallVector<SCEVUse>) are [..] Scev_Id arrays in `temp`. Never keep a slice of `se.ops`
// across a call that may create nodes (the pool may move): read operands with sc_op(s, i) or copy them first.

Scev_Id :: u32;
SCEV_CNC :: cast(Scev_Id) 0;

Scev_Kind :: enum u8 {
    CONSTANT; VSCALE; TRUNC; ZEXT; SEXT; ADD; MUL; UDIV; ADDREC; UMAX; SMAX; UMIN; SMIN; SEQ_UMIN;
    PTRTOADDR; PTRTOINT; UNKNOWN; CNC;
}

// SCEV::NoWrapFlags
SF_ANY :: cast(u8) 0;
SF_NW  :: cast(u8) 1;
SF_NUW :: cast(u8) 2;
SF_NSW :: cast(u8) 4;
SF_MASK :: cast(u8) 7;

Scev_Row :: struct {
    kind: Scev_Kind;
    flags: u8;
    size: u16;          // ExpressionSize
    nops: u32;
    ops: u32;           // first operand in se.ops
    type: Type_Id;      // getType()
    val: Value_Id = NONE;   // SCEVConstant: the ConstantInt; SCEVUnknown: the value
    loop: Loop_Id = NONE;   // SCEVAddRecExpr
    hnext: Scev_Id;     // next node in the same uniquing bucket (0 = end)
    hash: u64;
}

Loop_Disposition :: enum u8 { VARIANT; INVARIANT; COMPUTABLE; UNIFORM; }
Block_Disposition :: enum u8 { DOES_NOT_DOMINATE; DOMINATES; PROPERLY_DOMINATES; }

Scev_State :: struct {
    fn: Value_Id;
    dt: *Dom_Tree;
    li: *Loop_Info;
    ac: *Assumption_Cache;
    nodes: [..] Scev_Row;
    ops: [..] Scev_Id;
    unique: Table(u64, Scev_Id);
    first_unknown_count: s64;

    value_expr: Table(Value_Id, Scev_Id);           // ValueExprMap
    expr_values: Table(Scev_Id, [..] Value_Id);     // ExprValueMap
    fold_cache: Table(u64, Scev_Id);                // FoldCache: (kind, op, type)
    has_rec: Table(Scev_Id, bool);                  // HasRecMap
    unsigned_ranges: Table(Scev_Id, Const_Range);
    signed_ranges: Table(Scev_Id, Const_Range);
    const_multiple: Table(Scev_Id, APInt);
    loop_disp: Table(Scev_Id, [..] Disp_Entry);
    block_disp: Table(Scev_Id, [..] Disp_Entry);
    values_at_scopes: Table(Scev_Id, [..] Scope_Entry);
    values_at_scopes_users: Table(Scev_Id, [..] Scope_Entry);   // (L, V) pairs
    users: Table(Scev_Id, [..] Scev_Id);            // SCEVUsers
    fold_cache_user: Table(Scev_Id, [..] u64);      // FoldCacheUser
    be_count_users: Table(Scev_Id, [..] u64);       // BECountUsers: (L << 1) | Predicated
    loop_users: Table(Loop_Id, [..] Scev_Id);       // LoopUsers
    signed_wrap_tried: Table(Scev_Id, bool);        // SignedWrapViaInductionTried
    unsigned_wrap_tried: Table(Scev_Id, bool);      // UnsignedWrapViaInductionTried
    btc: Table(Loop_Id, *Backedge_Taken_Info);      // BackedgeTakenCounts
    pred_btc: Table(Loop_Id, *Backedge_Taken_Info); // PredicatedBackedgeTakenCounts
    const_evolution: Table(Value_Id, Value_Id);     // ConstantEvolutionLoopExitValue (NONE = null)
    loop_props: Table(Loop_Id, Loop_Properties);
    pending_loop_predicates: Table(Value_Id, bool);
    pending_phi_ranges: Table(Value_Id, bool);
    pending_merges: Table(Value_Id, bool);
    pending_phi_range_iter: Table(Value_Id, bool);
    predicated_rewrites: Table(u64, Pred_Rewrite);  // PredicatedSCEVRewrites: (SCEV, Loop)
    preds: [..] Scev_Pred_Row;                     // UniquePreds
    pred_ops: [..] u32;
    pred_unique: Table(u64, u32);
    walking_be_dominating_conds: bool;
    proving_split_predicate: bool;
    has_guards: bool;
    loop_guards_depth: u32;
}

Disp_Entry :: struct { key: u32; d: u8; }
Scope_Entry :: struct { l: Loop_Id; s: Scev_Id; }   // s == NONE: pending
Pred_Rewrite :: struct { s: Scev_Id; preds: [..] u32; }
Loop_Properties :: struct { has_no_abnormal_exits: bool; has_no_side_effects: bool; }

se: *Scev_State;

// cl::opts (ScalarEvolution.cpp), see passes.jai cl_opts()
scev_opts: struct {
    max_brute_force_iterations: u64 = 100;         // scalar-evolution-max-iterations
    verify_scev: bool;                              // verify-scev
    mulops_inline_threshold: u64 = 32;             // scev-mulops-inline-threshold
    addops_inline_threshold: u64 = 500;            // scev-addops-inline-threshold
    max_scev_compare_depth: u64 = 32;              // scalar-evolution-max-scev-compare-depth
    max_scev_operations_implication_depth: u64 = 2;
    max_value_compare_depth: u64 = 2;              // scalar-evolution-max-value-compare-depth
    max_arith_depth: u64 = 32;                     // scalar-evolution-max-arith-depth
    max_constant_evolving_depth: u64 = 32;
    max_cast_depth: u64 = 8;                       // scalar-evolution-max-cast-depth
    max_add_rec_size: u64 = 8;                     // scalar-evolution-max-add-rec-size
    huge_expr_threshold: u64 = 4096;               // scalar-evolution-huge-expr-threshold
    range_iter_threshold: u64 = 32;                // scev-range-iter-threshold
    max_loop_guard_collection_depth: u64 = 1;      // scalar-evolution-max-loop-guard-collection-depth
    classify_expressions: bool = true;             // scalar-evolution-classify-expressions
    use_expensive_range_sharpening: bool;          // scalar-evolution-use-expensive-range-sharpening
    max_phi_scc_analysis_size: u64 = 8;            // scalar-evolution-max-scc-analysis-depth
    use_context_for_no_wrap_flag_inference: bool = true;  // scalar-evolution-use-context-for-no-wrap-flag-inference
};

// ---------------------------------------------------------------- state

scev_new :: (f: Value_Id, dt: *Dom_Tree, li: *Loop_Info, ac: *Assumption_Cache) -> *Scev_State {
    s := New(Scev_State);
    s.fn = f; s.dt = dt; s.li = li; s.ac = ac;
    cnc: Scev_Row;
    cnc.kind = .CNC;
    cnc.type = NONE;
    array_add(*s.nodes, cnc);
    array_add(*s.preds, .{});   // pred id 0 unused
    // ScalarEvolution::ScalarEvolution: HasGuards = any llvm.experimental.guard declaration with uses
    for g: ir.m_functions {
        if vname(g) == "llvm.experimental.guard" && has_uses(g) s.has_guards = true;
    }
    return s;
}

scev_free :: (s: *Scev_State) {
    array_free(s.nodes); array_free(s.ops);
    deinit(*s.unique); deinit(*s.value_expr); deinit(*s.expr_values); deinit(*s.fold_cache);
    deinit(*s.has_rec); deinit(*s.unsigned_ranges); deinit(*s.signed_ranges); deinit(*s.const_multiple);
    deinit(*s.loop_disp); deinit(*s.block_disp); deinit(*s.values_at_scopes);
    deinit(*s.btc); deinit(*s.pred_btc); deinit(*s.const_evolution); deinit(*s.loop_props);
    free(s);
    if se == s se = null;
}

// ---------------------------------------------------------------- node accessors

sc_row :: inline (s: Scev_Id) -> *Scev_Row { return *se.nodes[s]; }
sc_kind :: inline (s: Scev_Id) -> Scev_Kind { return se.nodes[s].kind; }
sc_type :: inline (s: Scev_Id) -> Type_Id { return se.nodes[s].type; }
sc_nops :: inline (s: Scev_Id) -> u32 { return se.nodes[s].nops; }
sc_op :: inline (s: Scev_Id, i: u32) -> Scev_Id { return se.ops[se.nodes[s].ops + i]; }
sc_flags :: inline (s: Scev_Id, mask: u8 = SF_MASK) -> u8 { return se.nodes[s].flags & mask; }
sc_loop :: inline (s: Scev_Id) -> Loop_Id { return se.nodes[s].loop; }
sc_value :: inline (s: Scev_Id) -> Value_Id { return se.nodes[s].val; }
sc_size :: inline (s: Scev_Id) -> u16 { return se.nodes[s].size; }
sc_is_cnc :: inline (s: Scev_Id) -> bool { return s == SCEV_CNC; }

sc_is_const :: inline (s: Scev_Id) -> bool { return se.nodes[s].kind == .CONSTANT; }
sc_is_unknown :: inline (s: Scev_Id) -> bool { return se.nodes[s].kind == .UNKNOWN; }
sc_is_addrec :: inline (s: Scev_Id) -> bool { return se.nodes[s].kind == .ADDREC; }
sc_is_add :: inline (s: Scev_Id) -> bool { return se.nodes[s].kind == .ADD; }
sc_is_mul :: inline (s: Scev_Id) -> bool { return se.nodes[s].kind == .MUL; }
sc_is_udiv :: inline (s: Scev_Id) -> bool { return se.nodes[s].kind == .UDIV; }
sc_is_trunc :: inline (s: Scev_Id) -> bool { return se.nodes[s].kind == .TRUNC; }
sc_is_zext :: inline (s: Scev_Id) -> bool { return se.nodes[s].kind == .ZEXT; }
sc_is_sext :: inline (s: Scev_Id) -> bool { return se.nodes[s].kind == .SEXT; }
// SCEVIntegralCastExpr: trunc, zext, sext
sc_is_integral_cast :: inline (s: Scev_Id) -> bool { k := se.nodes[s].kind; return k == .TRUNC || k == .ZEXT || k == .SEXT; }
// SCEVCastExpr
sc_is_cast :: inline (s: Scev_Id) -> bool { k := se.nodes[s].kind; return k == .TRUNC || k == .ZEXT || k == .SEXT || k == .PTRTOINT || k == .PTRTOADDR; }
sc_is_minmax_kind :: inline (k: Scev_Kind) -> bool { return k == .UMAX || k == .SMAX || k == .UMIN || k == .SMIN; }
sc_is_minmax :: inline (s: Scev_Id) -> bool { return sc_is_minmax_kind(se.nodes[s].kind); }
sc_is_seq_minmax :: inline (s: Scev_Id) -> bool { return se.nodes[s].kind == .SEQ_UMIN; }
// SCEVNAryExpr
sc_is_nary :: inline (s: Scev_Id) -> bool {
    k := se.nodes[s].kind;
    return k == .ADD || k == .MUL || k == .ADDREC || sc_is_minmax_kind(k) || k == .SEQ_UMIN;
}
// SCEVCommutativeExpr
sc_is_commutative :: inline (s: Scev_Id) -> bool { k := se.nodes[s].kind; return k == .ADD || k == .MUL || sc_is_minmax_kind(k); }

sc_ap :: (s: Scev_Id) -> APInt {
    v := se.nodes[s].val;
    return ap_from_words(type_int_width(vtype(v)), const_int_value(v));
}
sc_const_is_zero :: (s: Scev_Id) -> bool { return sc_is_const(s) && ap_is_zero(sc_ap(s)); }
sc_is_zero :: inline (s: Scev_Id) -> bool { return sc_const_is_zero(s); }
sc_is_one :: (s: Scev_Id) -> bool { return sc_is_const(s) && ap_is_one(sc_ap(s)); }
sc_is_all_ones :: (s: Scev_Id) -> bool { return sc_is_const(s) && ap_is_all_ones(sc_ap(s)); }
// SCEV::isNonConstantNegative
sc_is_non_constant_negative :: (s: Scev_Id) -> bool {
    if !sc_is_mul(s) return false;
    c := sc_op(s, 0);
    if !sc_is_const(c) return false;
    return ap_is_negative(sc_ap(c));
}
sc_operands :: (s: Scev_Id) -> [..] Scev_Id {
    r: [..] Scev_Id;
    r.allocator = temp;
    n := sc_nops(s);
    array_reserve(*r, n);
    for i: 0..cast(s64) n - 1 array_add(*r, sc_op(s, cast(u32) i));
    return r;
}
sc_list :: (items: .. Scev_Id) -> [..] Scev_Id {
    r: [..] Scev_Id;
    r.allocator = temp;
    for items array_add(*r, it);
    return r;
}
sc_list_copy :: (items: [] Scev_Id) -> [..] Scev_Id {
    r: [..] Scev_Id;
    r.allocator = temp;
    array_reserve(*r, items.count);
    for items array_add(*r, it);
    return r;
}
// AddRec helpers
sc_start :: inline (ar: Scev_Id) -> Scev_Id { return sc_op(ar, 0); }
sc_is_affine :: inline (ar: Scev_Id) -> bool { return sc_nops(ar) == 2; }
sc_is_quadratic :: inline (ar: Scev_Id) -> bool { return sc_nops(ar) == 3; }
// SCEVAddRecExpr::getStepRecurrence
sc_step_recurrence :: (ar: Scev_Id) -> Scev_Id {
    if sc_is_affine(ar) return sc_op(ar, 1);
    ops := sc_operands(ar);
    array_ordered_remove_by_index(*ops, 0);
    return sc_get_add_rec_ops(*ops, sc_loop(ar), SF_ANY);
}
sc_has_nuw :: inline (s: Scev_Id) -> bool { return (se.nodes[s].flags & SF_NUW) != 0; }
sc_has_nsw :: inline (s: Scev_Id) -> bool { return (se.nodes[s].flags & SF_NSW) != 0; }
sc_has_nw :: inline (s: Scev_Id) -> bool { return (se.nodes[s].flags & SF_NW) != 0; }

// ScalarEvolution::maskFlags / setFlags / clearFlags / hasFlags
mask_flags :: inline (f: u8, m: u8) -> u8 { return f & m; }
set_flags :: inline (f: u8, m: u8) -> u8 { return f | m; }
clear_flags :: inline (f: u8, m: u8) -> u8 { return f & ~m; }
has_flags :: inline (f: u8, m: u8) -> bool { return (f & m) == m; }

// ---------------------------------------------------------------- types

// isSCEVable
sc_is_scevable :: (t: Type_Id) -> bool { k := type_kind(t); return k == .INT || k == .PTR; }
// getTypeSizeInBits
sc_type_bits :: (t: Type_Id) -> u32 {
    if type_kind(t) == .PTR return dl_index_type_size_bits(t);
    return type_int_width(t);
}
sc_bits :: inline (s: Scev_Id) -> u32 { return sc_type_bits(sc_type(s)); }
// getEffectiveSCEVType
sc_effective_type :: (t: Type_Id) -> Type_Id {
    if type_kind(t) == .INT return t;
    return type_int(dl_index_type_size_bits(t));
}
// getWiderType
sc_wider_type :: (a: Type_Id, b: Type_Id) -> Type_Id { if sc_type_bits(a) >= sc_type_bits(b) return a; return b; }
sc_is_ptr :: inline (s: Scev_Id) -> bool { return type_kind(se.nodes[s].type) == .PTR; }

// ---------------------------------------------------------------- uniquing (FoldingSet)

sc_hash_mix :: inline (h: u64, x: u64) -> u64 {
    r := (h ^ x) * 0x100000001b3;
    return r ^ (r >> 29);
}
// The FoldingSetNodeID of a node: kind, operands, then the type (casts, vscale), value (constant, unknown) and loop
// (addrec). Fields not in LLVM's ID are always equal for equal IDs here (e.g. a ptrtoint's type).
sc_key_hash :: (kind: Scev_Kind, ops: [] Scev_Id, type: Type_Id, val: Value_Id, l: Loop_Id) -> u64 {
    h: u64 = 0xcbf29ce484222325;
    h = sc_hash_mix(h, cast(u64) kind);
    for ops h = sc_hash_mix(h, cast(u64) it + 0x9e37);
    h = sc_hash_mix(h, cast(u64) type);
    h = sc_hash_mix(h, cast(u64) val);
    h = sc_hash_mix(h, cast(u64) l);
    return h;
}
sc_key_type :: (kind: Scev_Kind, type: Type_Id) -> Type_Id {
    if kind == .TRUNC || kind == .ZEXT || kind == .SEXT || kind == .VSCALE || kind == .PTRTOADDR || kind == .PTRTOINT return type;
    return NONE;
}
sc_find :: (kind: Scev_Kind, ops: [] Scev_Id, type: Type_Id = NONE, val: Value_Id = NONE, l: Loop_Id = NONE) -> Scev_Id {
    kt := sc_key_type(kind, type);
    h := sc_key_hash(kind, ops, kt, val, l);
    found, head := table_find(*se.unique, h);
    if !found return SCEV_CNC;
    s := head;
    while s != 0 {
        r := *se.nodes[s];
        if r.hash == h && r.kind == kind && r.nops == ops.count && r.val == val && r.loop == l &&
           sc_key_type(kind, r.type) == kt {
            same := true;
            for ops if se.ops[r.ops + it_index] != it { same = false; break; }
            if same return s;
        }
        s = r.hnext;
    }
    return SCEV_CNC;
}
// Allocate and insert a node (the caller checked sc_find first).
sc_insert :: (kind: Scev_Kind, ops: [] Scev_Id, type: Type_Id, val: Value_Id = NONE, l: Loop_Id = NONE, flags: u8 = 0) -> Scev_Id {
    row: Scev_Row;
    row.kind = kind;
    row.flags = flags;
    row.type = type;
    row.val = val;
    row.loop = l;
    row.ops = cast(u32) se.ops.count;
    row.nops = cast(u32) ops.count;
    size: u32 = 1;
    for ops { size += se.nodes[it].size; if size > 0xFFFF size = 0xFFFF; array_add(*se.ops, it); }
    row.size = cast(u16) size;
    if kind == .CONSTANT || kind == .UNKNOWN || kind == .VSCALE row.size = 1;
    kt := sc_key_type(kind, type);
    row.hash = sc_key_hash(kind, ops, kt, val, l);
    id := cast(Scev_Id) se.nodes.count;
    found, head := table_find(*se.unique, row.hash);
    if found row.hnext = head;
    array_add(*se.nodes, row);
    table_set(*se.unique, row.hash, id);
    // registerUser(S, Ops) (every creation site of a non-leaf node calls it)
    sc_register_user(id, ops);
    if kind == .ADDREC {
        p := table_find_pointer(*se.loop_users, l);
        if !p { blank: [..] Scev_Id; table_set(*se.loop_users, l, blank); p = table_find_pointer(*se.loop_users, l); }
        array_add(p, id);
    }
    return id;
}
// UniqueSCEVs.RemoveNode (SCEVUnknown::deleted / allUsesReplacedWith)
sc_unique_remove :: (s: Scev_Id) {
    h := se.nodes[s].hash;
    found, head := table_find(*se.unique, h);
    if !found return;
    if head == s {
        nx := se.nodes[s].hnext;
        if nx == 0 table_remove(*se.unique, h); else table_set(*se.unique, h, nx);
        return;
    }
    p := head;
    while p != 0 {
        if se.nodes[p].hnext == s { se.nodes[p].hnext = se.nodes[s].hnext; return; }
        p = se.nodes[p].hnext;
    }
}

// ---------------------------------------------------------------- leaves

// getConstant(ConstantInt *)
sc_get_constant_value :: (v: Value_Id) -> Scev_Id {
    s := sc_find(.CONSTANT, .[], NONE, v);
    if s return s;
    return sc_insert(.CONSTANT, .[], vtype(v), v);
}
// getConstant(const APInt &)
sc_get_constant :: (a: APInt) -> Scev_Id {
    w := ap_words(a);
    return sc_get_constant_value(const_int_words(type_int(a.bits), w));
}
// getConstant(Type *, uint64_t, bool isSigned) (implicit truncation)
sc_get_constant_t :: (t: Type_Id, v: u64, is_signed := false) -> Scev_Id {
    it := sc_effective_type(t);
    bits := type_int_width(it);
    a: APInt;
    if is_signed a = ap_from_s64(bits, cast,no_check(s64) v); else a = ap_from_u64(bits, v);
    return sc_get_constant(a);
}
sc_get_zero :: (t: Type_Id) -> Scev_Id { return sc_get_constant(ap_zero(sc_type_bits(t))); }
sc_get_one :: (t: Type_Id) -> Scev_Id { return sc_get_constant(ap_one(sc_type_bits(t))); }
sc_get_minus_one :: (t: Type_Id) -> Scev_Id { return sc_get_constant(ap_all_ones(sc_type_bits(t))); }
// getPowerOfTwo
sc_get_power_of_two :: (t: Type_Id, power: u32) -> Scev_Id { return sc_get_constant(ap_one_bit_set(sc_type_bits(t), power)); }

sc_get_vscale :: (t: Type_Id) -> Scev_Id {
    s := sc_find(.VSCALE, .[], t);
    if s return s;
    return sc_insert(.VSCALE, .[], t);
}
// getElementCount
sc_get_element_count :: (t: Type_Id, min: u64, scalable: bool, flags: u8 = SF_ANY) -> Scev_Id {
    r := sc_get_constant_t(t, min);
    if scalable r = sc_get_mul2(r, sc_get_vscale(t), flags);
    return r;
}

sc_get_unknown :: (v: Value_Id) -> Scev_Id {
    s := sc_find(.UNKNOWN, .[], NONE, v);
    if s return s;
    return sc_insert(.UNKNOWN, .[], vtype(v), v);
}

// getSizeOfExpr(IntTy, TypeSize)
sc_get_size_of_size :: (int_ty: Type_Id, size: u64, scalable: bool) -> Scev_Id {
    r := sc_get_constant_t(int_ty, size);
    if scalable r = sc_get_mul2(r, sc_get_vscale(int_ty));
    return r;
}
sc_get_size_of :: (int_ty: Type_Id, alloc_ty: Type_Id) -> Scev_Id {
    sz, scalable := sc_type_alloc_size(alloc_ty);
    return sc_get_size_of_size(int_ty, sz, scalable);
}
sc_get_store_size_of :: (int_ty: Type_Id, t: Type_Id) -> Scev_Id {
    if type_kind(t) == .SVECTOR return sc_get_size_of_size(int_ty, dl_type_store_size(t), true);
    return sc_get_size_of_size(int_ty, dl_type_store_size(t), false);
}
// TypeSize of getTypeAllocSize (known minimum, scalable)
sc_type_alloc_size :: (t: Type_Id) -> (u64, bool) {
    return dl_type_alloc_size(t), sc_type_is_scalable(t);
}
sc_type_is_scalable :: (t: Type_Id) -> bool {
    k := type_kind(t);
    if k == .SVECTOR return true;
    if k == .ARRAY return sc_type_is_scalable(type_elem(t));
    if k == .STRUCT { for i: 0..cast(s64) type_nsub(t) - 1 if sc_type_is_scalable(type_sub(t, cast(u32) i)) return true; }
    return false;
}

// ---------------------------------------------------------------- printing

sc_to_string :: (s: Scev_Id) -> string {
    sb: String_Builder;
    sb.allocator = temp;
    sc_print(*sb, s);
    return builder_to_string(*sb,, allocator = temp);
}
sc_print :: (sb: *String_Builder, s: Scev_Id) {
    r := se.nodes[s];
    if r.kind == {
        case .CONSTANT; append(sb, value_as_operand(r.val));
        case .VSCALE; append(sb, "vscale");
        case .PTRTOADDR; #through;
        case .PTRTOINT;
            o := sc_op(s, 0);
            append(sb, ifx r.kind == .PTRTOADDR then "(ptrtoaddr " else "(ptrtoint ");
            append(sb, type_to_string(sc_type(o))); append(sb, " "); sc_print(sb, o);
            append(sb, " to "); append(sb, type_to_string(r.type)); append(sb, ")");
        case .TRUNC; #through;
        case .ZEXT; #through;
        case .SEXT;
            o := sc_op(s, 0);
            append(sb, ifx r.kind == .TRUNC then "(trunc " else ifx r.kind == .ZEXT then "(zext " else "(sext ");
            append(sb, type_to_string(sc_type(o))); append(sb, " "); sc_print(sb, o);
            append(sb, " to "); append(sb, type_to_string(r.type)); append(sb, ")");
        case .ADDREC;
            append(sb, "{");
            sc_print(sb, sc_op(s, 0));
            for i: 1..cast(s64) r.nops - 1 { append(sb, ",+,"); sc_print(sb, sc_op(s, cast(u32) i)); }
            append(sb, "}<");
            if r.flags & SF_NUW append(sb, "nuw><");
            if r.flags & SF_NSW append(sb, "nsw><");
            if (r.flags & SF_NW) && !(r.flags & SF_NUW) && !(r.flags & SF_NSW) append(sb, "nw><");
            append(sb, value_as_operand(li_header(se.li, r.loop)));
            append(sb, ">");
        case .ADD; #through;
        case .MUL; #through;
        case .UMAX; #through;
        case .SMAX; #through;
        case .UMIN; #through;
        case .SMIN; #through;
        case .SEQ_UMIN;
            op_str: string;
            if r.kind == {
                case .ADD; op_str = " + ";
                case .MUL; op_str = " * ";
                case .UMAX; op_str = " umax ";
                case .SMAX; op_str = " smax ";
                case .UMIN; op_str = " umin ";
                case .SMIN; op_str = " smin ";
                case .SEQ_UMIN; op_str = " umin_seq ";
            }
            append(sb, "(");
            for i: 0..cast(s64) r.nops - 1 { if i > 0 append(sb, op_str); sc_print(sb, sc_op(s, cast(u32) i)); }
            append(sb, ")");
            if r.kind == .ADD || r.kind == .MUL {
                if r.flags & SF_NUW append(sb, "<nuw>");
                if r.flags & SF_NSW append(sb, "<nsw>");
            }
        case .UDIV;
            append(sb, "("); sc_print(sb, sc_op(s, 0)); append(sb, " /u "); sc_print(sb, sc_op(s, 1)); append(sb, ")");
        case .UNKNOWN; append(sb, value_as_operand(r.val));
        case .CNC; append(sb, "***COULDNOTCOMPUTE***");
    }
}

// ---------------------------------------------------------------- traversal (SCEVTraversal / SCEVExprContains)

// visitAll with a visitor: `follow` decides whether to descend into a node; `done` stops the walk.
Sc_Visitor :: struct {
    follow: (v: *Sc_Visitor, s: Scev_Id) -> bool;
    is_done: (v: *Sc_Visitor) -> bool;
    data: *void;
    found: bool;
}
sc_visit_all :: (root: Scev_Id, v: *Sc_Visitor) {
    visited: Table(Scev_Id, bool);
    visited.allocator = temp;
    work: [..] Scev_Id;
    work.allocator = temp;
    push :: (s: Scev_Id, visited: *Table(Scev_Id, bool), work: *[..] Scev_Id, v: *Sc_Visitor) {
        if table_contains(visited, s) return;
        table_set(visited, s, true);
        if v.follow(v, s) array_add(work, s);
    }
    push(root, *visited, *work, v);
    while work.count > 0 && !(v.is_done && v.is_done(v)) {
        s := pop(*work);
        k := sc_kind(s);
        if k == .CONSTANT || k == .VSCALE || k == .UNKNOWN || k == .CNC continue;
        n := sc_nops(s);
        for i: 0..cast(s64) n - 1 {
            push(sc_op(s, cast(u32) i), *visited, *work, v);
            if v.is_done && v.is_done(v) break;
        }
    }
}
// SCEVExprContains(Root, Pred)
sc_expr_contains :: (root: Scev_Id, pred: (s: Scev_Id, data: *void) -> bool, data: *void = null) -> bool {
    Ctx :: struct { pred: (s: Scev_Id, data: *void) -> bool; data: *void; }
    ctx := Ctx.{pred, data};
    v: Sc_Visitor;
    v.data = *ctx;
    v.follow = (v: *Sc_Visitor, s: Scev_Id) -> bool {
        c := cast(*Ctx) v.data;
        if !v.found v.found = c.pred(s, c.data);
        return !v.found;
    };
    v.is_done = (v: *Sc_Visitor) -> bool { return v.found; };
    sc_visit_all(root, *v);
    return v.found;
}

// ---------------------------------------------------------------- complexity ordering

// Value::getValueID
value_id_of :: (v: Value_Id) -> s32 {
    k := vkind(v);
    if k == {
        case .C_UNDEF; return 0;
        case .C_POISON; return 1;
        case .C_ZERO; return 2;
        case .C_DATA; if type_kind(vtype(v)) == .ARRAY return 3; return 4;
        case .C_INT; if type_kind(scalar_type(vtype(v))) == .BYTE return 6; return 5;
        case .C_FP; return 7;
        case .C_TARGET_NONE; return 8;
        case .C_NULL; return 9;
        case .C_TOKEN_NONE; return 10;
        case .C_ARRAY; return 11;
        case .C_STRUCT; return 12;
        case .C_VECTOR; return 13;
        case .FUNCTION; return 14;
        case .ALIAS; return 15;
        case .IFUNC; return 16;
        case .GLOBAL_VAR; return 17;
        case .C_BLOCKADDR; return 18;
        case .C_EXPR; return 19;
        case .C_DSO_EQUIV; return 20;
        case .C_NO_CFI; return 21;
        case .C_PTRAUTH; return 22;
        case .ARGUMENT; return 23;
        case .BLOCK; return 24;
        case .MD_VALUE; return 25;
        case .INLINE_ASM; return 26;
        case .INST; return 30 + cast(s32) inst_op(v);
    }
    return 255;
}

// CompareValueComplexity
compare_value_complexity :: (lv: Value_Id, rv: Value_Id, depth: u32) -> s32 {
    if depth > scev_opts.max_value_compare_depth return 0;
    lp := type_kind(vtype(lv)) == .PTR;
    rp := type_kind(vtype(rv)) == .PTR;
    if lp != rp return (cast(s32) lp) - (cast(s32) rp);
    lid := value_id_of(lv); rid := value_id_of(rv);
    if lid != rid return lid - rid;
    if vkind(lv) == .ARGUMENT return cast(s32) arg_no(lv) - cast(s32) arg_no(rv);
    if is_global_value(vkind(lv)) {
        ll := cast(s32) glob(lv).linkage; rl := cast(s32) glob(rv).linkage;
        if ll != rl return ll - rl;
        semantic :: (g: Value_Id) -> bool { l := glob(g).linkage; return !(l == .PRIVATE || l == .INTERNAL); }
        if semantic(lv) && semantic(rv) return sc_string_compare(vname(lv), vname(rv));
    }
    if vkind(lv) == .INST {
        lb := inst_block(lv); rb := inst_block(rv);
        if lb != rb {
            ld := li_block_depth(se.li, lb); rd := li_block_depth(se.li, rb);
            if ld != rd return cast(s32) ld - cast(s32) rd;
        }
        ln := nops(lv); rn := nops(rv);
        if ln != rn return cast(s32) ln - cast(s32) rn;
        for i: 0..cast(s64) ln - 1 {
            r := compare_value_complexity(op(lv, cast(u32) i), op(rv, cast(u32) i), depth + 1);
            if r != 0 return r;
        }
    }
    return 0;
}
// StringRef::compare
sc_string_compare :: (a: string, b: string) -> s32 {
    n := min(a.count, b.count);
    for i: 0..n-1 {
        if a[i] != b[i] return ifx a[i] < b[i] then cast(s32) -1 else 1;
    }
    if a.count == b.count return 0;
    return ifx a.count < b.count then cast(s32) -1 else 1;
}

// CompareSCEVComplexity: (has_value = false) is std::nullopt
compare_scev_complexity :: (lhs: Scev_Id, rhs: Scev_Id, depth: u32 = 0) -> (s32, bool) {
    if lhs == rhs return 0, true;
    lt := sc_kind(lhs); rt := sc_kind(rhs);
    if lt != rt return cast(s32) lt - cast(s32) rt, true;
    if depth > scev_opts.max_scev_compare_depth return 0, false;
    if lt == {
        case .UNKNOWN;
            return compare_value_complexity(sc_value(lhs), sc_value(rhs), depth + 1), true;
        case .CONSTANT;
            la := sc_ap(lhs); ra := sc_ap(rhs);
            if la.bits != ra.bits return cast(s32) la.bits - cast(s32) ra.bits, true;
            return ifx ap_ult(la, ra) then cast(s32) -1 else 1, true;
        case .VSCALE;
            return cast(s32) type_int_width(sc_type(lhs)) - cast(s32) type_int_width(sc_type(rhs)), true;
        case .ADDREC;
            ll := sc_loop(lhs); rl := sc_loop(rhs);
            if ll != rl {
                if dt_dominates(se.dt, li_header(se.li, ll), li_header(se.li, rl)) return 1, true;
                return -1, true;
            }
    }
    ln := sc_nops(lhs); rn := sc_nops(rhs);
    if ln != rn return cast(s32) ln - cast(s32) rn, true;
    for i: 0..cast(s64) ln - 1 {
        x, ok := compare_scev_complexity(sc_op(lhs, cast(u32) i), sc_op(rhs, cast(u32) i), depth + 1);
        if !ok return 0, false;
        if x != 0 return x, true;
    }
    return 0, true;
}
sc_is_less_complex :: (a: Scev_Id, b: Scev_Id) -> bool {
    c, ok := compare_scev_complexity(a, b);
    return ok && c < 0;
}

// GroupByComplexity
group_by_complexity :: (ops: *[..] Scev_Id) {
    n := ops.count;
    if n < 2 return;
    if n == 2 {
        if sc_is_less_complex(ops.*[1], ops.*[0]) { t := ops.*[0]; ops.*[0] = ops.*[1]; ops.*[1] = t; }
        return;
    }
    // llvm::stable_sort: the comparator is not a strict weak order at the depth limit, so reproduce libstdc++'s
    // algorithm exactly (LLVM 23.1.5's opt is built against GCC 12's libstdc++)
    gnu_stable_sort(ops.*, sc_is_less_complex);
    i := 0;
    e := n;
    while i != e - 2 {
        s := ops.*[i];
        complexity := sc_kind(s);
        j := i + 1;
        while j != e && sc_kind(ops.*[j]) == complexity {
            if ops.*[j] == s {
                t := ops.*[i+1]; ops.*[i+1] = ops.*[j]; ops.*[j] = t;
                i += 1;
                if i == e - 2 return;
            }
            j += 1;
        }
        i += 1;
    }
}

has_huge_expression :: (ops: [] Scev_Id) -> bool {
    for ops if cast(u64) sc_size(it) >= scev_opts.huge_expr_threshold return true;
    return false;
}

Fold_Kind :: enum u8 { ADD; MUL; SMAX; SMIN; UMAX; UMIN; }
fold_apply :: (k: Fold_Kind, a: APInt, b: APInt) -> APInt {
    if k == {
        case .ADD; return ap_add(a, b);
        case .MUL; return ap_mul(a, b);
        case .SMAX; return ap_smax(a, b);
        case .SMIN; return ap_smin(a, b);
        case .UMAX; return ap_umax(a, b);
        case .UMIN; return ap_umin(a, b);
    }
    return a;
}
fold_is_identity :: (k: Fold_Kind, c: APInt) -> bool {
    if k == {
        case .ADD; return ap_is_zero(c);
        case .MUL; return ap_is_one(c);
        case .SMAX; return ap_is_min_signed(c);
        case .UMAX; return ap_is_zero(c);
        case .SMIN; return ap_is_max_signed(c);
        case .UMIN; return ap_is_all_ones(c);
    }
    return false;
}
fold_is_absorber :: (k: Fold_Kind, c: APInt) -> bool {
    if k == {
        case .ADD; return false;
        case .MUL; return ap_is_zero(c);
        case .SMAX; return ap_is_max_signed(c);
        case .UMAX; return ap_is_all_ones(c);
        case .SMIN; return ap_is_min_signed(c);
        case .UMIN; return ap_is_zero(c);
    }
    return false;
}
// constantFoldAndGroupOps: returns the folded result or SCEV_CNC (= nullptr)
constant_fold_and_group_ops :: (ops: *[..] Scev_Id, k: Fold_Kind) -> Scev_Id {
    folded: Scev_Id = SCEV_CNC;
    idx := 0;
    while idx < ops.count {
        o := ops.*[idx];
        if sc_is_const(o) {
            if folded == SCEV_CNC folded = o;
            else folded = sc_get_constant(fold_apply(k, sc_ap(folded), sc_ap(o)));
            array_ordered_remove_by_index(ops, idx);
            continue;
        }
        idx += 1;
    }
    if ops.count == 0 return folded;
    if folded != SCEV_CNC && fold_is_absorber(k, sc_ap(folded)) return folded;
    group_by_complexity(ops);
    if folded != SCEV_CNC && !fold_is_identity(k, sc_ap(folded)) array_insert_at(ops, folded, 0);
    if ops.count == 1 return ops.*[0];
    return SCEV_CNC;
}

// ---------------------------------------------------------------- AddRec evaluation

// APInt::multiplicativeInverse (of an odd number, modulo 2^bits): Newton's method
ap_multiplicative_inverse :: (a: APInt) -> APInt {
    factor := a;
    t: u32 = 3;
    while t < a.bits {
        factor = ap_mul(factor, ap_sub(ap_from_u64(a.bits, 2), ap_mul(factor, a)));
        t *= 2;
    }
    factor = ap_mul(factor, ap_sub(ap_from_u64(a.bits, 2), ap_mul(factor, a)));
    return factor;
}

// BinomialCoefficient(It, K)
binomial_coefficient :: (it: Scev_Id, k: u32, result_ty: Type_Id) -> Scev_Id {
    if k == 1 return sc_get_truncate_or_zero_extend(it, result_ty);
    if k > 1000 return SCEV_CNC;
    w := sc_type_bits(result_ty);
    odd_factorial := ap_one(w);
    t: u32 = 1;
    i: u32 = 3;
    while i <= k {
        two_factors := ctz64(cast(u64) i);
        t += two_factors;
        odd_factorial = ap_mul(odd_factorial, ap_from_u64(w, cast(u64) (i >> two_factors)));
        i += 1;
    }
    calculation_bits := w + t;
    div_factor := ap_one_bit_set(calculation_bits, t);
    multiply_factor := ap_multiplicative_inverse(odd_factorial);
    calc_ty := type_int(calculation_bits);
    dividend := sc_get_truncate_or_zero_extend(it, calc_ty);
    for j: 1..k-1 {
        s := sc_get_minus(it, sc_get_constant_t(sc_type(it), cast(u64) j));
        dividend = sc_get_mul2(dividend, sc_get_truncate_or_zero_extend(s, calc_ty));
    }
    div_result := sc_get_udiv(dividend, sc_get_constant(div_factor));
    return sc_get_mul2(sc_get_constant(multiply_factor), sc_get_truncate_or_zero_extend(div_result, result_ty));
}

// SCEVAddRecExpr::evaluateAtIteration(Operands, It)
evaluate_at_iteration_ops :: (operands: [] Scev_Id, it: Scev_Id) -> Scev_Id {
    result := operands[0];
    for i: 1..operands.count-1 {
        coeff := binomial_coefficient(it, cast(u32) i, sc_type(result));
        if coeff == SCEV_CNC return coeff;
        result = sc_get_add2(result, sc_get_mul2(operands[i], coeff));
    }
    return result;
}
evaluate_at_iteration :: (ar: Scev_Id, it: Scev_Id) -> Scev_Id {
    ops := sc_operands(ar);
    return evaluate_at_iteration_ops(ops, it);
}

// ---------------------------------------------------------------- ptrtoint / ptrtoaddr

// SCEVCastSinkingRewriter: is_addr selects ptrtoaddr (getPtrToAddrExpr) vs ptrtoint (getLosslessPtrToIntExpr)
cast_sinking_rewrite :: (s: Scev_Id, target_ty: Type_Id, is_addr: bool) -> Scev_Id {
    if !sc_is_ptr(s) return s;
    k := sc_kind(s);
    if k == .ADD || k == .MUL {
        ops: [..] Scev_Id; ops.allocator = temp;
        changed := false;
        n := sc_nops(s);
        for i: 0..cast(s64) n - 1 {
            o := sc_op(s, cast(u32) i);
            r := cast_sinking_rewrite(o, target_ty, is_addr);
            array_add(*ops, r);
            changed |= r != o;
        }
        if !changed return s;
        if k == .ADD return sc_get_add(*ops, sc_flags(s));
        return sc_get_mul(*ops, sc_flags(s));
    }
    if k == .UNKNOWN {
        if vkind(sc_value(s)) == .C_NULL return sc_get_zero(target_ty);
        ck := ifx is_addr then Scev_Kind.PTRTOADDR else .PTRTOINT;
        f := sc_find(ck, .[s], target_ty);
        if f return f;
        return sc_insert(ck, .[s], target_ty);
    }
    // SCEVRewriteVisitor defaults for the remaining pointer-typed kinds
    if k == .ADDREC {
        ops: [..] Scev_Id; ops.allocator = temp;
        changed := false;
        for i: 0..cast(s64) sc_nops(s) - 1 {
            o := sc_op(s, cast(u32) i);
            r := cast_sinking_rewrite(o, target_ty, is_addr);
            array_add(*ops, r);
            changed |= r != o;
        }
        if !changed return s;
        return sc_get_add_rec_ops(*ops, sc_loop(s), sc_flags(s));
    }
    if sc_is_minmax(s) || sc_is_seq_minmax(s) {
        ops: [..] Scev_Id; ops.allocator = temp;
        changed := false;
        for i: 0..cast(s64) sc_nops(s) - 1 {
            o := sc_op(s, cast(u32) i);
            r := cast_sinking_rewrite(o, target_ty, is_addr);
            array_add(*ops, r);
            changed |= r != o;
        }
        if !changed return s;
        if k == .SEQ_UMIN return sc_get_sequential_min_max(k, *ops);
        return sc_get_min_max(k, *ops);
    }
    fatal("ScalarEvolution: cannot sink a pointer cast into %", sc_to_string(s));
    return SCEV_CNC;
}

// getLosslessPtrToIntExpr
sc_get_lossless_ptr_to_int :: (op: Scev_Id) -> Scev_Id {
    if dl_ni_ptr_type(sc_type(op)) return SCEV_CNC;
    as := cast(u32) ir.types[sc_type(op)].a;
    int_ptr_ty := type_int(dl_ptr_spec(as).bits);
    if sc_type_bits(sc_effective_type(sc_type(op))) != dl_ptr_spec(as).bits return SCEV_CNC;
    return cast_sinking_rewrite(op, int_ptr_ty, false);
}
// getPtrToAddrExpr
sc_get_ptr_to_addr :: (op: Scev_Id) -> Scev_Id {
    as := cast(u32) ir.types[sc_type(op)].a;
    if dl_ptr_spec(as).unstable return SCEV_CNC;
    ty := type_int(dl_ptr_spec(as).idx_bits);   // DataLayout::getAddressType = index type
    return cast_sinking_rewrite(op, ty, true);
}
// getPtrToIntExpr
sc_get_ptr_to_int :: (op: Scev_Id, ty: Type_Id) -> Scev_Id {
    i := sc_get_lossless_ptr_to_int(op);
    if i == SCEV_CNC return i;
    return sc_get_truncate_or_zero_extend(i, ty);
}

// ---------------------------------------------------------------- truncate

sc_get_truncate :: (op: Scev_Id, ty_in: Type_Id, depth: u32 = 0) -> Scev_Id {
    ty := sc_effective_type(ty_in);
    s := sc_find(.TRUNC, .[op], ty);
    if s return s;
    if sc_is_const(op) return sc_get_constant(ap_trunc(sc_ap(op), type_int_width(ty)));
    if sc_is_trunc(op) return sc_get_truncate(sc_op(op, 0), ty, depth + 1);
    if sc_is_sext(op) return sc_get_truncate_or_sign_extend(sc_op(op, 0), ty, depth + 1);
    if sc_is_zext(op) return sc_get_truncate_or_zero_extend(sc_op(op, 0), ty, depth + 1);
    if depth > scev_opts.max_cast_depth return sc_insert(.TRUNC, .[op], ty);

    if sc_is_add(op) || sc_is_mul(op) {
        operands: [..] Scev_Id; operands.allocator = temp;
        num_truncs := 0;
        n := sc_nops(op);
        i: u32 = 0;
        while i != n && num_truncs < 2 {
            o := sc_op(op, i);
            t := sc_get_truncate(o, ty, depth + 1);
            if !sc_is_integral_cast(o) && sc_is_trunc(t) num_truncs += 1;
            array_add(*operands, t);
            i += 1;
        }
        if num_truncs < 2 {
            if sc_is_add(op) return sc_get_add(*operands);
            return sc_get_mul(*operands);
        }
        s = sc_find(.TRUNC, .[op], ty);
        if s return s;
    }
    if sc_is_addrec(op) {
        operands: [..] Scev_Id; operands.allocator = temp;
        for i: 0..cast(s64) sc_nops(op) - 1 array_add(*operands, sc_get_truncate(sc_op(op, cast(u32) i), ty, depth + 1));
        return sc_get_add_rec_ops(*operands, sc_loop(op), SF_ANY);
    }
    if sc_get_min_trailing_zeros(op) >= sc_type_bits(ty) return sc_get_zero(ty);
    // the insert position is still valid in LLVM; re-check (getMinTrailingZeros creates no truncs of op)
    s = sc_find(.TRUNC, .[op], ty);
    if s return s;
    return sc_insert(.TRUNC, .[op], ty);
}

// ---------------------------------------------------------------- extensions

// getSignedOverflowLimitForStep / getUnsignedOverflowLimitForStep: returns (limit or SCEV_CNC = nullptr, pred)
overflow_limit_for_step :: (step: Scev_Id, signed: bool) -> (Scev_Id, u8) {
    bits := sc_bits(step);
    if signed {
        if sc_is_known_positive(step)
            return sc_get_constant(ap_sub(ap_signed_min(bits), sc_signed_range_max(step))), ICMP_SLT;
        if sc_is_known_negative(step)
            return sc_get_constant(ap_sub(ap_signed_max(bits), sc_signed_range_min(step))), ICMP_SGT;
        return SCEV_CNC, 0;
    }
    return sc_get_constant(ap_sub(ap_zero(bits), sc_unsigned_range_max(step))), ICMP_ULT;
}
sc_get_extend :: (op: Scev_Id, ty: Type_Id, depth: u32, signed: bool) -> Scev_Id {
    if signed return sc_get_sign_extend(op, ty, depth);
    return sc_get_zero_extend(op, ty, depth);
}

// getPreStartForExtend<ExtendOpTy> (SCEV_CNC = nullptr)
get_pre_start_for_extend :: (ar: Scev_Id, ty: Type_Id, depth: u32, signed: bool) -> Scev_Id {
    wrap_type := ifx signed then SF_NSW else SF_NUW;
    l := sc_loop(ar);
    start := sc_start(ar);
    step := sc_step_recurrence(ar);
    if !sc_is_add(start) return SCEV_CNC;
    sa := start;
    diff_ops := sc_operands(sa);
    for diff_ops if it == step { array_ordered_remove_by_index(*diff_ops, it_index); break; }
    if diff_ops.count == cast(s64) sc_nops(sa) return SCEV_CNC;

    pre_start_flags := mask_flags(sc_flags(sa), SF_NUW);
    pre_start := sc_get_add(*diff_ops, pre_start_flags);
    pre_ar := sc_get_add_rec(pre_start, step, l, SF_ANY);
    if !sc_is_addrec(pre_ar) pre_ar = SCEV_CNC;

    be_count := sc_get_backedge_taken_count(l);
    if pre_ar != SCEV_CNC && sc_flags(pre_ar, wrap_type) != 0 && be_count != SCEV_CNC && sc_is_known_positive(be_count)
        return pre_start;

    bits := sc_bits(ar);
    wide_ty := type_int(bits * 2);
    operand_extended_start := sc_get_add2(sc_get_extend(pre_start, wide_ty, depth, signed), sc_get_extend(step, wide_ty, depth, signed));
    if sc_get_extend(start, wide_ty, depth, signed) == operand_extended_start {
        if pre_ar != SCEV_CNC && sc_flags(ar, wrap_type) != 0 sc_set_no_wrap_flags(pre_ar, wrap_type);
        return pre_start;
    }
    limit, pred := overflow_limit_for_step(step, signed);
    if limit != SCEV_CNC && sc_is_loop_entry_guarded_by_cond(l, pred, pre_start, limit) return pre_start;
    return SCEV_CNC;
}

// getExtendAddRecStart<ExtendOpTy>
get_extend_add_rec_start :: (ar: Scev_Id, ty: Type_Id, depth: u32, signed: bool) -> Scev_Id {
    pre_start := get_pre_start_for_extend(ar, ty, depth, signed);
    if pre_start == SCEV_CNC return sc_get_extend(sc_start(ar), ty, depth, signed);
    return sc_get_add2(sc_get_extend(sc_step_recurrence(ar), ty, depth, signed), sc_get_extend(pre_start, ty, depth, signed));
}

// proveNoWrapByVaryingStart<ExtendOpTy>
prove_no_wrap_by_varying_start :: (start: Scev_Id, step: Scev_Id, l: Loop_Id, signed: bool) -> bool {
    wrap_type := ifx signed then SF_NSW else SF_NUW;
    if !sc_is_const(start) return false;
    start_ai := sc_ap(start);
    for delta: s64.[-2, -1, 1, 2] {
        pre_start := sc_get_constant(ap_sub(start_ai, ap_from_s64(start_ai.bits, delta)));
        pre_ar := sc_find(.ADDREC, .[pre_start, step], NONE, NONE, l);
        if pre_ar && sc_flags(pre_ar, wrap_type) != 0 {
            delta_s := sc_get_constant_t(sc_type(start), cast,no_check(u64) delta);
            limit, pred := overflow_limit_for_step(delta_s, signed);
            if limit != SCEV_CNC && sc_is_known_predicate(pred, pre_ar, limit) return true;
        }
    }
    return false;
}

// extractConstantWithoutWrapping (C + x + y + ...)
extract_constant_without_wrapping_add :: (c: Scev_Id, whole: Scev_Id) -> APInt {
    ca := sc_ap(c);
    bits := ca.bits;
    tz := bits;
    i: u32 = 1;
    while i < sc_nops(whole) && tz != 0 { tz = min(tz, sc_get_min_trailing_zeros(sc_op(whole, i))); i += 1; }
    if tz {
        if tz < bits return ap_zext(ap_trunc(ca, tz), bits);
        return ca;
    }
    return ap_zero(bits);
}
// extractConstantWithoutWrapping {C,+,x}
extract_constant_without_wrapping_step :: (cs: APInt, step: Scev_Id) -> APInt {
    bits := cs.bits;
    tz := sc_get_min_trailing_zeros(step);
    if tz {
        if tz < bits return ap_zext(ap_trunc(cs, tz), bits);
        return cs;
    }
    return ap_zero(bits);
}

fold_id :: (kind: Scev_Kind, op: Scev_Id, ty: Type_Id) -> u64 {
    return ((cast(u64) kind) << 56) | ((cast(u64) ty) << 32) | cast(u64) op;
}

sc_get_zero_extend :: (op: Scev_Id, ty_in: Type_Id, depth: u32 = 0) -> Scev_Id {
    ty := sc_effective_type(ty_in);
    id := fold_id(.ZEXT, op, ty);
    found, cached := table_find(*se.fold_cache, id);
    if found return cached;
    s := sc_get_zero_extend_impl(op, ty, depth);
    if !sc_is_zext(s) sc_insert_fold_cache(id, s);
    return s;
}

sc_get_zero_extend_impl :: (op: Scev_Id, ty: Type_Id, depth: u32) -> Scev_Id {
    if sc_is_const(op) return sc_get_constant(ap_zext(sc_ap(op), sc_type_bits(ty)));
    if sc_is_zext(op) return sc_get_zero_extend(sc_op(op, 0), ty, depth + 1);
    s := sc_find(.ZEXT, .[op], ty);
    if s return s;
    if depth > scev_opts.max_cast_depth return sc_insert(.ZEXT, .[op], ty);

    if sc_is_trunc(op) {
        x := sc_op(op, 0);
        cr := sc_unsigned_range(x);
        trunc_bits := sc_bits(op);
        new_bits := sc_type_bits(ty);
        if cr_contains_range(cr_zero_extend(cr_truncate(cr, trunc_bits), new_bits), cr_zext_or_trunc(cr, new_bits))
            return sc_get_truncate_or_zero_extend(x, ty, depth);
    }

    if sc_is_addrec(op) && sc_is_affine(op) {
        ar := op;
        start := sc_start(ar);
        step := sc_step_recurrence(ar);
        bits := sc_bits(ar);
        l := sc_loop(ar);
        if sc_has_nuw(ar) {
            start = get_extend_add_rec_start(ar, ty, depth + 1, false);
            step = sc_get_zero_extend(step, ty, depth + 1);
            return sc_get_add_rec(start, step, l, sc_flags(ar));
        }
        max_be_count := sc_get_constant_max_backedge_taken_count(l);
        if max_be_count != SCEV_CNC {
            casted := sc_get_truncate_or_zero_extend(max_be_count, sc_type(start), depth);
            recasted := sc_get_truncate_or_zero_extend(casted, sc_type(max_be_count), depth);
            if max_be_count == recasted {
                wide_ty := type_int(bits * 2);
                zmul := sc_get_mul2(casted, step, SF_ANY, depth + 1);
                zadd := sc_get_zero_extend(sc_get_add2(start, zmul, SF_ANY, depth + 1), wide_ty, depth + 1);
                wide_start := sc_get_zero_extend(start, wide_ty, depth + 1);
                wide_max := sc_get_zero_extend(casted, wide_ty, depth + 1);
                oea := sc_get_add2(wide_start, sc_get_mul2(wide_max, sc_get_zero_extend(step, wide_ty, depth + 1), SF_ANY, depth + 1), SF_ANY, depth + 1);
                if zadd == oea {
                    sc_set_no_wrap_flags(ar, SF_NUW);
                    start = get_extend_add_rec_start(ar, ty, depth + 1, false);
                    step = sc_get_zero_extend(step, ty, depth + 1);
                    return sc_get_add_rec(start, step, l, sc_flags(ar));
                }
                oea = sc_get_add2(wide_start, sc_get_mul2(wide_max, sc_get_sign_extend(step, wide_ty, depth + 1), SF_ANY, depth + 1), SF_ANY, depth + 1);
                if zadd == oea {
                    sc_set_no_wrap_flags(ar, SF_NW);
                    start = get_extend_add_rec_start(ar, ty, depth + 1, false);
                    step = sc_get_sign_extend(step, ty, depth + 1);
                    return sc_get_add_rec(start, step, l, sc_flags(ar));
                }
            }
        }
        if max_be_count != SCEV_CNC || se.has_guards || ac_has_assumptions(se.ac) {
            new_flags := prove_no_unsigned_wrap_via_induction(ar);
            sc_set_no_wrap_flags(ar, new_flags);
            if sc_has_nuw(ar) {
                start = get_extend_add_rec_start(ar, ty, depth + 1, false);
                step = sc_get_zero_extend(step, ty, depth + 1);
                return sc_get_add_rec(start, step, l, sc_flags(ar));
            }
            if sc_is_known_negative(step) {
                n := sc_get_constant(ap_sub(ap_all_ones(bits), sc_signed_range_min(step)));
                if sc_is_loop_backedge_guarded_by_cond(l, ICMP_UGT, ar, n) || sc_is_known_on_every_iteration(ICMP_UGT, ar, n) {
                    sc_set_no_wrap_flags(ar, SF_NW);
                    start = get_extend_add_rec_start(ar, ty, depth + 1, false);
                    step = sc_get_sign_extend(step, ty, depth + 1);
                    return sc_get_add_rec(start, step, l, sc_flags(ar));
                }
            }
        }
        if sc_is_const(start) {
            c := sc_ap(start);
            d := extract_constant_without_wrapping_step(c, step);
            if !ap_is_zero(d) {
                szext_d := sc_get_zero_extend(sc_get_constant(d), ty, depth);
                residual := sc_get_add_rec(sc_get_constant(ap_sub(c, d)), step, l, sc_flags(ar));
                szext_r := sc_get_zero_extend(residual, ty, depth + 1);
                return sc_get_add2(szext_d, szext_r, SF_NSW | SF_NUW, depth + 1);
            }
        }
        if prove_no_wrap_by_varying_start(start, step, l, false) {
            sc_set_no_wrap_flags(ar, SF_NUW);
            start = get_extend_add_rec_start(ar, ty, depth + 1, false);
            step = sc_get_zero_extend(step, ty, depth + 1);
            return sc_get_add_rec(start, step, l, sc_flags(ar));
        }
    }

    {
        ok, lhs, rhs := match_urem(op);
        if ok return sc_get_urem(sc_get_zero_extend(lhs, ty, depth + 1), sc_get_zero_extend(rhs, ty, depth + 1));
    }
    if sc_is_udiv(op)
        return sc_get_udiv(sc_get_zero_extend(sc_op(op, 0), ty, depth + 1), sc_get_zero_extend(sc_op(op, 1), ty, depth + 1));

    if sc_is_add(op) {
        sa := op;
        if sc_has_nuw(sa) {
            ops: [..] Scev_Id; ops.allocator = temp;
            for i: 0..cast(s64) sc_nops(sa) - 1 array_add(*ops, sc_get_zero_extend(sc_op(sa, cast(u32) i), ty, depth + 1));
            return sc_get_add(*ops, SF_NUW, depth + 1);
        }
        // zext((-C) + smax(C2, X)) --> sext(-C) + sext(smax(C2, X)) for C2 >= |C|
        if sc_has_nsw(sa) && sc_nops(sa) == 2 && sc_is_const(sc_op(sa, 0)) {
            sm := sc_op(sa, 1);
            if sc_kind(sm) == .SMAX && sc_nops(sm) == 2 && sc_is_const(sc_op(sm, 0)) {
                c := sc_ap(sc_op(sa, 0));
                c2 := sc_ap(sc_op(sm, 0));
                if ap_is_negative(c) && !ap_is_min_signed(c) && ap_sge(c2, ap_abs(c))
                    return sc_get_add2(sc_get_sign_extend(sc_op(sa, 0), ty, depth + 1), sc_get_sign_extend(sc_op(sa, 1), ty, depth + 1), SF_NSW, depth + 1);
            }
        }
        if sc_is_const(sc_op(sa, 0)) {
            d := extract_constant_without_wrapping_add(sc_op(sa, 0), sa);
            if !ap_is_zero(d) {
                szext_d := sc_get_zero_extend(sc_get_constant(d), ty, depth);
                residual := sc_get_add2(sc_get_constant(ap_neg(d)), sa, SF_ANY, depth);
                szext_r := sc_get_zero_extend(residual, ty, depth + 1);
                return sc_get_add2(szext_d, szext_r, SF_NSW | SF_NUW, depth + 1);
            }
        }
    }

    if sc_is_mul(op) {
        sm := op;
        if sc_has_nuw(sm) {
            ops: [..] Scev_Id; ops.allocator = temp;
            for i: 0..cast(s64) sc_nops(sm) - 1 array_add(*ops, sc_get_zero_extend(sc_op(sm, cast(u32) i), ty, depth + 1));
            return sc_get_mul(*ops, SF_NUW, depth + 1);
        }
        // zext(2^K * (trunc X to iN)) to iM --> 2^K * (zext(trunc X to i{N-K}) to iM)<nuw>
        if sc_nops(sm) == 2 && sc_is_const(sc_op(sm, 0)) && sc_is_trunc(sc_op(sm, 1)) {
            c := sc_ap(sc_op(sm, 0));
            trunc_rhs := sc_op(sc_op(sm, 1), 0);
            if ap_is_power_of_2(c) {
                new_trunc_bits := sc_bits(sc_op(sm, 1)) - ap_log2(c);
                new_trunc_ty := type_int(new_trunc_bits);
                return sc_get_mul2(sc_get_zero_extend(sc_op(sm, 0), ty),
                                   sc_get_zero_extend(sc_get_truncate(trunc_rhs, new_trunc_ty), ty), SF_NUW, depth + 1);
            }
        }
    }

    if sc_kind(op) == .UMIN || sc_kind(op) == .UMAX {
        operands: [..] Scev_Id; operands.allocator = temp;
        for i: 0..cast(s64) sc_nops(op) - 1 array_add(*operands, sc_get_zero_extend(sc_op(op, cast(u32) i), ty));
        if sc_kind(op) == .UMIN return sc_get_min_max(.UMIN, *operands);
        return sc_get_min_max(.UMAX, *operands);
    }
    if sc_is_seq_minmax(op) {
        operands: [..] Scev_Id; operands.allocator = temp;
        for i: 0..cast(s64) sc_nops(op) - 1 array_add(*operands, sc_get_zero_extend(sc_op(op, cast(u32) i), ty));
        return sc_get_sequential_min_max(.SEQ_UMIN, *operands);
    }

    s = sc_find(.ZEXT, .[op], ty);
    if s return s;
    return sc_insert(.ZEXT, .[op], ty);
}

sc_get_sign_extend :: (op: Scev_Id, ty_in: Type_Id, depth: u32 = 0) -> Scev_Id {
    ty := sc_effective_type(ty_in);
    id := fold_id(.SEXT, op, ty);
    found, cached := table_find(*se.fold_cache, id);
    if found return cached;
    s := sc_get_sign_extend_impl(op, ty, depth);
    if !sc_is_sext(s) sc_insert_fold_cache(id, s);
    return s;
}

sc_get_sign_extend_impl :: (op: Scev_Id, ty: Type_Id, depth: u32) -> Scev_Id {
    if sc_is_const(op) return sc_get_constant(ap_sext(sc_ap(op), sc_type_bits(ty)));
    if sc_is_sext(op) return sc_get_sign_extend(sc_op(op, 0), ty, depth + 1);
    if sc_is_zext(op) return sc_get_zero_extend(sc_op(op, 0), ty, depth + 1);
    s := sc_find(.SEXT, .[op], ty);
    if s return s;
    if depth > scev_opts.max_cast_depth return sc_insert(.SEXT, .[op], ty);

    if sc_is_trunc(op) {
        x := sc_op(op, 0);
        cr := sc_signed_range(x);
        trunc_bits := sc_bits(op);
        new_bits := sc_type_bits(ty);
        if cr_contains_range(cr_sign_extend(cr_truncate(cr, trunc_bits), new_bits), cr_sext_or_trunc(cr, new_bits))
            return sc_get_truncate_or_sign_extend(x, ty, depth);
    }

    if sc_is_add(op) {
        sa := op;
        if sc_has_nsw(sa) {
            ops: [..] Scev_Id; ops.allocator = temp;
            for i: 0..cast(s64) sc_nops(sa) - 1 array_add(*ops, sc_get_sign_extend(sc_op(sa, cast(u32) i), ty, depth + 1));
            return sc_get_add(*ops, SF_NSW, depth + 1);
        }
        if sc_is_const(sc_op(sa, 0)) {
            d := extract_constant_without_wrapping_add(sc_op(sa, 0), sa);
            if !ap_is_zero(d) {
                ssext_d := sc_get_sign_extend(sc_get_constant(d), ty, depth);
                residual := sc_get_add2(sc_get_constant(ap_neg(d)), sa, SF_ANY, depth);
                ssext_r := sc_get_sign_extend(residual, ty, depth + 1);
                return sc_get_add2(ssext_d, ssext_r, SF_NSW | SF_NUW, depth + 1);
            }
        }
    }

    if sc_is_addrec(op) && sc_is_affine(op) {
        ar := op;
        start := sc_start(ar);
        step := sc_step_recurrence(ar);
        bits := sc_bits(ar);
        l := sc_loop(ar);
        if sc_has_nsw(ar) {
            start = get_extend_add_rec_start(ar, ty, depth + 1, true);
            step = sc_get_sign_extend(step, ty, depth + 1);
            return sc_get_add_rec(start, step, l, SF_NSW);
        }
        max_be_count := sc_get_constant_max_backedge_taken_count(l);
        if max_be_count != SCEV_CNC {
            casted := sc_get_truncate_or_zero_extend(max_be_count, sc_type(start), depth);
            recasted := sc_get_truncate_or_zero_extend(casted, sc_type(max_be_count), depth);
            if max_be_count == recasted {
                wide_ty := type_int(bits * 2);
                smul := sc_get_mul2(casted, step, SF_ANY, depth + 1);
                sadd := sc_get_sign_extend(sc_get_add2(start, smul, SF_ANY, depth + 1), wide_ty, depth + 1);
                wide_start := sc_get_sign_extend(start, wide_ty, depth + 1);
                wide_max := sc_get_zero_extend(casted, wide_ty, depth + 1);
                oea := sc_get_add2(wide_start, sc_get_mul2(wide_max, sc_get_sign_extend(step, wide_ty, depth + 1), SF_ANY, depth + 1), SF_ANY, depth + 1);
                if sadd == oea {
                    sc_set_no_wrap_flags(ar, SF_NSW);
                    start = get_extend_add_rec_start(ar, ty, depth + 1, true);
                    step = sc_get_sign_extend(step, ty, depth + 1);
                    return sc_get_add_rec(start, step, l, sc_flags(ar));
                }
                oea = sc_get_add2(wide_start, sc_get_mul2(wide_max, sc_get_zero_extend(step, wide_ty, depth + 1), SF_ANY, depth + 1), SF_ANY, depth + 1);
                if sadd == oea {
                    sc_set_no_wrap_flags(ar, SF_NW);
                    start = get_extend_add_rec_start(ar, ty, depth + 1, true);
                    step = sc_get_zero_extend(step, ty, depth + 1);
                    return sc_get_add_rec(start, step, l, sc_flags(ar));
                }
            }
        }
        new_flags := prove_no_signed_wrap_via_induction(ar);
        sc_set_no_wrap_flags(ar, new_flags);
        if sc_has_nsw(ar) {
            start = get_extend_add_rec_start(ar, ty, depth + 1, true);
            step = sc_get_sign_extend(step, ty, depth + 1);
            return sc_get_add_rec(start, step, l, sc_flags(ar));
        }
        if sc_is_const(start) {
            c := sc_ap(start);
            d := extract_constant_without_wrapping_step(c, step);
            if !ap_is_zero(d) {
                ssext_d := sc_get_sign_extend(sc_get_constant(d), ty, depth);
                residual := sc_get_add_rec(sc_get_constant(ap_sub(c, d)), step, l, sc_flags(ar));
                ssext_r := sc_get_sign_extend(residual, ty, depth + 1);
                return sc_get_add2(ssext_d, ssext_r, SF_NSW | SF_NUW, depth + 1);
            }
        }
        if prove_no_wrap_by_varying_start(start, step, l, true) {
            sc_set_no_wrap_flags(ar, SF_NSW);
            start = get_extend_add_rec_start(ar, ty, depth + 1, true);
            step = sc_get_sign_extend(step, ty, depth + 1);
            return sc_get_add_rec(start, step, l, sc_flags(ar));
        }
    }

    if sc_is_known_non_negative(op) return sc_get_zero_extend(op, ty, depth + 1);

    if sc_kind(op) == .SMIN || sc_kind(op) == .SMAX {
        operands: [..] Scev_Id; operands.allocator = temp;
        for i: 0..cast(s64) sc_nops(op) - 1 array_add(*operands, sc_get_sign_extend(sc_op(op, cast(u32) i), ty));
        if sc_kind(op) == .SMIN return sc_get_min_max(.SMIN, *operands);
        return sc_get_min_max(.SMAX, *operands);
    }

    s = sc_find(.SEXT, .[op], ty);
    if s return s;
    return sc_insert(.SEXT, .[op], ty);
}

// getCastExpr
sc_get_cast :: (kind: Scev_Kind, op: Scev_Id, ty: Type_Id) -> Scev_Id {
    if kind == {
        case .TRUNC; return sc_get_truncate(op, ty);
        case .ZEXT; return sc_get_zero_extend(op, ty);
        case .SEXT; return sc_get_sign_extend(op, ty);
        case .PTRTOADDR; return sc_get_ptr_to_addr(op);
        case .PTRTOINT; return sc_get_ptr_to_int(op, ty);
    }
    fatal("ScalarEvolution: not a cast kind");
    return SCEV_CNC;
}

// getAnyExtendExpr
sc_get_any_extend :: (op: Scev_Id, ty_in: Type_Id) -> Scev_Id {
    ty := sc_effective_type(ty_in);
    if sc_is_const(op) && ap_is_negative(sc_ap(op)) return sc_get_sign_extend(op, ty);
    if sc_is_trunc(op) {
        new_op := sc_op(op, 0);
        if sc_bits(new_op) < sc_type_bits(ty) return sc_get_any_extend(new_op, ty);
        return sc_get_truncate_or_noop(new_op, ty);
    }
    zext := sc_get_zero_extend(op, ty);
    if !sc_is_zext(zext) return zext;
    sext := sc_get_sign_extend(op, ty);
    if !sc_is_sext(sext) return sext;
    if sc_is_addrec(op) {
        ops: [..] Scev_Id; ops.allocator = temp;
        for i: 0..cast(s64) sc_nops(op) - 1 array_add(*ops, sc_get_any_extend(sc_op(op, cast(u32) i), ty));
        return sc_get_add_rec_ops(*ops, sc_loop(op), SF_NW);
    }
    if sc_kind(op) == .SMAX return sext;
    return zext;
}

sc_get_truncate_or_zero_extend :: (v: Scev_Id, ty: Type_Id, depth: u32 = 0) -> Scev_Id {
    sb := sc_bits(v); tb := sc_type_bits(ty);
    if sb == tb return v;
    if sb > tb return sc_get_truncate(v, ty, depth);
    return sc_get_zero_extend(v, ty, depth);
}
sc_get_truncate_or_sign_extend :: (v: Scev_Id, ty: Type_Id, depth: u32 = 0) -> Scev_Id {
    sb := sc_bits(v); tb := sc_type_bits(ty);
    if sb == tb return v;
    if sb > tb return sc_get_truncate(v, ty, depth);
    return sc_get_sign_extend(v, ty, depth);
}
sc_get_noop_or_zero_extend :: (v: Scev_Id, ty: Type_Id) -> Scev_Id {
    if sc_bits(v) == sc_type_bits(ty) return v;
    return sc_get_zero_extend(v, ty);
}
sc_get_noop_or_sign_extend :: (v: Scev_Id, ty: Type_Id) -> Scev_Id {
    if sc_bits(v) == sc_type_bits(ty) return v;
    return sc_get_sign_extend(v, ty);
}
sc_get_noop_or_any_extend :: (v: Scev_Id, ty: Type_Id) -> Scev_Id {
    if sc_bits(v) == sc_type_bits(ty) return v;
    return sc_get_any_extend(v, ty);
}
sc_get_truncate_or_noop :: (v: Scev_Id, ty: Type_Id) -> Scev_Id {
    if sc_bits(v) == sc_type_bits(ty) return v;
    return sc_get_truncate(v, ty);
}
// getUMaxFromMismatchedTypes
sc_get_umax_from_mismatched_types :: (lhs: Scev_Id, rhs: Scev_Id) -> Scev_Id {
    pl := lhs; pr := rhs;
    if sc_bits(lhs) > sc_bits(rhs) pr = sc_get_zero_extend(rhs, sc_type(lhs));
    else pl = sc_get_noop_or_zero_extend(lhs, sc_type(rhs));
    return sc_get_umax2(pl, pr);
}
// getUMinFromMismatchedTypes
sc_get_umin_from_mismatched_types2 :: (lhs: Scev_Id, rhs: Scev_Id, sequential := false) -> Scev_Id {
    ops := sc_list(lhs, rhs);
    return sc_get_umin_from_mismatched_types(*ops, sequential);
}
sc_get_umin_from_mismatched_types :: (ops: *[..] Scev_Id, sequential := false) -> Scev_Id {
    if ops.count == 1 return ops.*[0];
    max_type: Type_Id = NONE;
    for ops.* { if max_type != NONE max_type = sc_wider_type(max_type, sc_type(it)); else max_type = sc_type(it); }
    promoted: [..] Scev_Id; promoted.allocator = temp;
    for ops.* array_add(*promoted, sc_get_noop_or_zero_extend(it, max_type));
    return sc_get_umin(*promoted, sequential);
}

// ---------------------------------------------------------------- add

// CollectAddOperandsWithScales
Scale_Map :: struct { keys: [..] Scev_Id; scales: [..] APInt; }
scale_map_find :: (m: *Scale_Map, k: Scev_Id) -> s64 { for m.keys if it == k return it_index; return -1; }
collect_add_operands_with_scales :: (m: *Scale_Map, new_ops: *[..] Scev_Id, acc: *APInt, ops: [] Scev_Id, scale: APInt) -> bool {
    interesting := false;
    i := 0;
    while i < ops.count && sc_is_const(ops[i]) {
        c := ops[i];
        i += 1;
        if !ap_is_one(scale) || !ap_is_zero(acc.*) || ap_is_zero(sc_ap(c)) interesting = true;
        acc.* = ap_add(acc.*, ap_mul(scale, sc_ap(c)));
    }
    while i < ops.count {
        o := ops[i];
        if sc_is_mul(o) && sc_is_const(sc_op(o, 0)) {
            new_scale := ap_mul(scale, sc_ap(sc_op(o, 0)));
            if sc_nops(o) == 2 && sc_is_add(sc_op(o, 1)) {
                add := sc_op(o, 1);
                add_ops := sc_operands(add);
                interesting |= collect_add_operands_with_scales(m, new_ops, acc, add_ops, new_scale);
            } else {
                mul_ops := sc_operands(o);
                array_ordered_remove_by_index(*mul_ops, 0);
                key := sc_get_mul(*mul_ops);
                k := scale_map_find(m, key);
                if k < 0 {
                    array_add(*m.keys, key); array_add(*m.scales, new_scale);
                    array_add(new_ops, key);
                } else {
                    m.scales[k] = ap_add(m.scales[k], new_scale);
                    interesting = true;
                }
            }
        } else {
            k := scale_map_find(m, o);
            if k < 0 {
                array_add(*m.keys, o); array_add(*m.scales, scale);
                array_add(new_ops, o);
            } else {
                m.scales[k] = ap_add(m.scales[k], scale);
                interesting = true;
            }
        }
        i += 1;
    }
    return interesting;
}

// StrengthenNoWrapFlags
strengthen_no_wrap_flags :: (type: Scev_Kind, ops: [] Scev_Id, flags_in: u8) -> u8 {
    flags := flags_in;
    sign_or_unsign_mask := SF_NUW | SF_NSW;
    sign_or_unsign_wrap := mask_flags(flags, sign_or_unsign_mask);
    if sign_or_unsign_wrap == SF_NSW {
        all_nn := true;
        for ops if !sc_is_known_non_negative(it) { all_nn = false; break; }
        if all_nn flags = set_flags(flags, sign_or_unsign_mask);
    }
    sign_or_unsign_wrap = mask_flags(flags, sign_or_unsign_mask);
    if sign_or_unsign_wrap != sign_or_unsign_mask && (type == .ADD || type == .MUL) && ops.count == 2 && sc_is_const(ops[0]) {
        opcode := ifx type == .ADD then Opcode.ADD else .MUL;
        c := sc_ap(ops[0]);
        if !(sign_or_unsign_wrap & SF_NSW) {
            nsw_region := cr_guaranteed_no_wrap_region(opcode, cr_single(c), false);
            if cr_contains_range(nsw_region, sc_signed_range(ops[1])) flags = set_flags(flags, SF_NSW);
        }
        if !(sign_or_unsign_wrap & SF_NUW) {
            nuw_region := cr_guaranteed_no_wrap_region(opcode, cr_single(c), true);
            if cr_contains_range(nuw_region, sc_unsigned_range(ops[1])) flags = set_flags(flags, SF_NUW);
        }
    }
    if type == .ADDREC && has_flags(flags, SF_NW) && !has_flags(flags, SF_NUW) && ops.count == 2 &&
       sc_is_zero(ops[0]) && sc_is_known_non_negative(ops[1])
        flags = set_flags(flags, SF_NUW);
    if type == .MUL && !has_flags(flags, SF_NUW) && ops.count == 2 {
        if sc_is_udiv(ops[0]) && sc_op(ops[0], 1) == ops[1] flags = set_flags(flags, SF_NUW);
        if sc_is_udiv(ops[1]) && sc_op(ops[1], 1) == ops[0] flags = set_flags(flags, SF_NUW);
    }
    return flags;
}

// isAvailableAtLoopEntry
sc_is_available_at_loop_entry :: (s: Scev_Id, l: Loop_Id) -> bool {
    return sc_is_loop_invariant(s, l) && sc_properly_dominates(s, li_header(se.li, l));
}

sc_get_add2 :: (a: Scev_Id, b: Scev_Id, flags: u8 = SF_ANY, depth: u32 = 0) -> Scev_Id {
    ops := sc_list(a, b);
    return sc_get_add(*ops, flags, depth);
}
sc_get_add3 :: (a: Scev_Id, b: Scev_Id, c: Scev_Id, flags: u8 = SF_ANY, depth: u32 = 0) -> Scev_Id {
    ops := sc_list(a, b, c);
    return sc_get_add(*ops, flags, depth);
}

sc_get_add :: (ops: *[..] Scev_Id, orig_flags: u8 = SF_ANY, depth: u32 = 0) -> Scev_Id {
    if ops.count == 1 return ops.*[0];
    folded := constant_fold_and_group_ops(ops, .ADD);
    if folded != SCEV_CNC return folded;

    idx := ifx sc_is_const(ops.*[0]) then 1 else 0;

    if cast(u64) depth > scev_opts.max_arith_depth || has_huge_expression(ops.*)
        return get_or_create_add(ops.*, strengthen_no_wrap_flags(.ADD, ops.*, orig_flags));

    {
        s := sc_find(.ADD, ops.*);
        if s {
            if sc_flags(s, orig_flags) != orig_flags sc_row(s).flags |= strengthen_no_wrap_flags(.ADD, ops.*, orig_flags);
            return s;
        }
    }

    ty := sc_type(ops.*[0]);
    found_match := false;
    i := 0;
    e := ops.count;
    while i < e - 1 {
        if ops.*[i] == ops.*[i+1] {
            count := 2;
            while i + count != e && ops.*[i+count] == ops.*[i] count += 1;
            scale := sc_get_constant_t(ty, cast(u64) count);
            mul := sc_get_mul2(scale, ops.*[i], SF_ANY, depth + 1);
            if ops.count == count return mul;
            ops.*[i] = mul;
            for 1..count-1 array_ordered_remove_by_index(ops, i + 1);
            i -= 1; e -= count - 1;
            found_match = true;
        }
        i += 1;
    }
    if found_match return sc_get_add(ops, orig_flags, depth + 1);

    // Check for truncates. If all the operands are truncated from the same type, see if factoring out the
    // truncate would permit the result to be folded.
    {
        src_type: Type_Id = NONE;
        oi := ops.*[idx];
        if sc_is_trunc(oi) src_type = sc_type(sc_op(oi, 0));
        else if sc_is_mul(oi) {
            last := sc_op(oi, sc_nops(oi) - 1);
            if sc_is_trunc(last) src_type = sc_type(sc_op(last, 0));
        }
        if src_type != NONE {
            large_ops: [..] Scev_Id; large_ops.allocator = temp;
            ok := true;
            for o: ops.* {
                if sc_is_trunc(o) {
                    if sc_type(sc_op(o, 0)) != src_type { ok = false; break; }
                    array_add(*large_ops, sc_op(o, 0));
                } else if sc_is_const(o) {
                    array_add(*large_ops, sc_get_any_extend(o, src_type));
                } else if sc_is_mul(o) {
                    large_mul_ops: [..] Scev_Id; large_mul_ops.allocator = temp;
                    j: u32 = 0;
                    f := sc_nops(o);
                    while j != f && ok {
                        mj := sc_op(o, j);
                        if sc_is_trunc(mj) {
                            if sc_type(sc_op(mj, 0)) != src_type { ok = false; break; }
                            array_add(*large_mul_ops, sc_op(mj, 0));
                        } else if sc_is_const(mj) {
                            array_add(*large_mul_ops, sc_get_any_extend(mj, src_type));
                        } else { ok = false; break; }
                        j += 1;
                    }
                    if ok array_add(*large_ops, sc_get_mul(*large_mul_ops, SF_ANY, depth + 1));
                } else { ok = false; break; }
            }
            if ok {
                fold := sc_get_add(*large_ops, SF_ANY, depth + 1);
                if sc_is_const(fold) || sc_is_unknown(fold) return sc_get_truncate(fold, ty);
            }
        }
    }

    if ops.count == 2 {
        a := ops.*[0]; b := ops.*[1];
        if sc_is_add(b) && sc_is_const(a) && sc_is_const(sc_op(b, 0)) {
            c1 := sc_ap(sc_op(b, 0));
            c2 := sc_ap(a);
            preserved: u8 = SF_ANY;
            const_add := ap_add(c1, c2);
            add_flags := sc_flags(b);
            if has_flags(add_flags, SF_NUW) && ap_ule(const_add, c1) preserved = set_flags(preserved, SF_NUW);
            if has_flags(add_flags, SF_NSW) && ap_is_negative(c1) == ap_is_negative(const_add) && ap_ule(ap_abs(const_add), ap_abs(c1))
                preserved = set_flags(preserved, SF_NSW);
            if preserved != SF_ANY {
                new_ops := sc_operands(b);
                new_ops[0] = sc_get_constant(const_add);
                return sc_get_add(*new_ops, preserved);
            }
        }
        // Try to push the constant operand into a ZExt: A + zext (-A + B) -> zext (B), if trunc (A) + -A + B
        // does not unsigned-wrap.
        if sc_is_zext(b) && sc_is_add(sc_op(b, 0)) {
            inner_add := sc_op(b, 0);
            narrow_a := sc_get_truncate(a, sc_type(inner_add));
            if narrow_a == sc_get_negative(sc_op(inner_add, 0)) && sc_get_zero_extend(narrow_a, sc_type(b)) == a &&
               has_flags(strengthen_no_wrap_flags(.ADD, .[narrow_a, inner_add], SF_ANY), SF_NUW)
                return sc_get_zero_extend(sc_get_add2(narrow_a, inner_add), sc_type(b));
        }
    }

    // Canonicalize (-1 * urem X, Y) + X --> (Y * X/Y)
    if ops.count == 2 {
        o0 := ops.*[0];
        if sc_is_mul(o0) && sc_nops(o0) == 2 && sc_is_all_ones(sc_op(o0, 0)) {
            ok, ul, ur := match_urem(sc_op(o0, 1));
            if ok && ul == ops.*[1] return sc_get_mul2(ur, sc_get_udiv(ops.*[1], ur));
        }
    }

    while idx < ops.count && sc_kind(ops.*[idx]) < .ADD idx += 1;

    if idx < ops.count {
        deleted_add := false;
        common_flags := mask_flags(orig_flags, SF_NUW);
        while sc_is_add(ops.*[idx]) {
            add := ops.*[idx];
            if cast(u64) ops.count > scev_opts.addops_inline_threshold || cast(u64) sc_nops(add) > scev_opts.addops_inline_threshold break;
            array_ordered_remove_by_index(ops, idx);
            for k: 0..cast(s64) sc_nops(add) - 1 array_add(ops, sc_op(add, cast(u32) k));
            deleted_add = true;
            common_flags = mask_flags(common_flags, sc_flags(add));
        }
        if deleted_add return sc_get_add(ops, common_flags, depth + 1);
    }

    while idx < ops.count && sc_kind(ops.*[idx]) < .MUL idx += 1;

    if idx < ops.count && sc_is_mul(ops.*[idx]) {
        bits := sc_type_bits(ty);
        m: Scale_Map; m.keys.allocator = temp; m.scales.allocator = temp;
        new_ops: [..] Scev_Id; new_ops.allocator = temp;
        acc := ap_zero(bits);
        cur := sc_list_copy(ops.*);
        if collect_add_operands_with_scales(*m, *new_ops, *acc, cur, ap_one(bits)) {
            // std::map<APInt, SmallVector, ult>: groups by scale, in ascending unsigned order of the scale
            scales: [..] APInt; scales.allocator = temp;
            groups: [..] [..] Scev_Id; groups.allocator = temp;
            for nop: new_ops {
                sc := m.scales[scale_map_find(*m, nop)];
                pos := 0;
                while pos < scales.count && ap_ult(scales[pos], sc) pos += 1;
                if pos < scales.count && ap_eq(scales[pos], sc) {
                    array_add(*groups[pos], nop);
                } else {
                    g: [..] Scev_Id; g.allocator = temp;
                    array_add(*g, nop);
                    array_insert_at(*scales, sc, pos);
                    array_insert_at(*groups, g, pos);
                }
            }
            ops.count = 0;
            if !ap_is_zero(acc) array_add(ops, sc_get_constant(acc));
            for g, gi: groups {
                if ap_is_one(scales[gi]) {
                    array_add(ops, sc_get_add(*groups[gi], SF_ANY, depth + 1));
                } else if !ap_is_zero(scales[gi]) {
                    array_add(ops, sc_get_mul2(sc_get_constant(scales[gi]), sc_get_add(*groups[gi], SF_ANY, depth + 1), SF_ANY, depth + 1));
                }
            }
            if ops.count == 0 return sc_get_zero(ty);
            if ops.count == 1 return ops.*[0];
            return sc_get_add(ops, SF_ANY, depth + 1);
        }
    }

    // If we are adding something to a multiply expression, make sure the something is not already an operand
    // of the multiply. If so, merge it into the multiply.
    strip_factor :: (m: Scev_Id, op_idx: u32, depth: u32) -> Scev_Id {
        if sc_nops(m) == 2 return sc_op(m, ifx op_idx == 0 then cast(u32) 1 else 0);
        remaining := sc_operands(m);
        array_ordered_remove_by_index(*remaining, op_idx);
        return sc_get_mul(*remaining, SF_ANY, depth + 1);
    }
    while idx < ops.count && sc_is_mul(ops.*[idx]) {
        mul := ops.*[idx];
        mul_op: u32 = 0;
        while mul_op != sc_nops(mul) {
            mul_op_scev := sc_op(mul, mul_op);
            if sc_is_const(mul_op_scev) { mul_op += 1; continue; }
            cofactors: [..] Scev_Id; cofactors.allocator = temp;
            dead: [..] s64; dead.allocator = temp;
            for add_op: 0..ops.count-1 {
                if mul_op_scev == ops.*[add_op] {
                    array_add(*cofactors, sc_get_one(ty));
                    array_add(*dead, add_op);
                    continue;
                }
                if add_op <= idx || !sc_is_mul(ops.*[add_op]) continue;
                other := ops.*[add_op];
                for omo: 0..cast(s64) sc_nops(other) - 1 {
                    if sc_op(other, cast(u32) omo) == mul_op_scev {
                        array_add(*cofactors, strip_factor(other, cast(u32) omo, depth));
                        array_add(*dead, add_op);
                        break;
                    }
                }
            }
            if cofactors.count > 0 {
                array_add(*cofactors, strip_factor(mul, mul_op, depth));
                inner_sum := sc_get_add(*cofactors, SF_ANY, depth + 1);
                outer_mul := sc_get_mul2(mul_op_scev, inner_sum, SF_ANY, depth + 1);
                if ops.count == dead.count + 1 return outer_mul;
                array_ordered_remove_by_index(ops, idx);
                for < k: 0..dead.count-1 {
                    d := dead[k];
                    array_ordered_remove_by_index(ops, ifx d > idx then d - 1 else d);
                }
                array_add(ops, outer_mul);
                return sc_get_add(ops, SF_ANY, depth + 1);
            }
            mul_op += 1;
        }
        idx += 1;
    }

    while idx < ops.count && sc_kind(ops.*[idx]) < .ADDREC idx += 1;

    while idx < ops.count && sc_is_addrec(ops.*[idx]) {
        li_ops: [..] Scev_Id; li_ops.allocator = temp;
        add_rec := ops.*[idx];
        add_rec_loop := sc_loop(add_rec);
        i = 0;
        e = ops.count;
        while i != e {
            if sc_is_available_at_loop_entry(ops.*[i], add_rec_loop) {
                array_add(*li_ops, ops.*[i]);
                array_ordered_remove_by_index(ops, i);
                i -= 1; e -= 1;
            }
            i += 1;
        }
        if li_ops.count > 0 {
            array_add(*li_ops, add_rec);
            flags := strengthen_no_wrap_flags(.ADD, li_ops, orig_flags);
            li_ops.count -= 1;
            array_add(*li_ops, sc_start(add_rec));
            add_rec_ops := sc_operands(add_rec);
            add_flags := flags;
            if add_flags != SF_ANY {
                def_i := sc_get_defining_scope_bound(li_ops);
                reach_i := block(li_header(se.li, add_rec_loop)).first;
                if !sc_is_guaranteed_to_transfer_execution_to(def_i, reach_i) add_flags = SF_ANY;
            }
            add_rec_ops[0] = sc_get_add(*li_ops, add_flags, depth + 1);
            flags = sc_flags(add_rec, set_flags(flags, SF_NW));
            new_rec := sc_get_add_rec_ops(*add_rec_ops, add_rec_loop, flags);
            if ops.count == 1 return new_rec;
            for k: 0..ops.count-1 if ops.*[k] == add_rec { ops.*[k] = new_rec; break; }
            return sc_get_add(ops, SF_ANY, depth + 1);
        }
        other_idx := idx + 1;
        while other_idx < ops.count && sc_is_addrec(ops.*[other_idx]) {
            if add_rec_loop == sc_loop(ops.*[other_idx]) {
                add_rec_ops := sc_operands(add_rec);
                while other_idx != ops.count && sc_is_addrec(ops.*[other_idx]) {
                    other_ar := ops.*[other_idx];
                    if sc_loop(other_ar) == add_rec_loop {
                        on := sc_nops(other_ar);
                        for k: 0..cast(s64) on - 1 {
                            if k >= add_rec_ops.count {
                                for kk: k..cast(s64) on - 1 array_add(*add_rec_ops, sc_op(other_ar, cast(u32) kk));
                                break;
                            }
                            add_rec_ops[k] = sc_get_add2(add_rec_ops[k], sc_op(other_ar, cast(u32) k), SF_ANY, depth + 1);
                        }
                        array_ordered_remove_by_index(ops, other_idx);
                        other_idx -= 1;
                    }
                    other_idx += 1;
                }
                ops.*[idx] = sc_get_add_rec_ops(*add_rec_ops, add_rec_loop, SF_ANY);
                return sc_get_add(ops, SF_ANY, depth + 1);
            }
            other_idx += 1;
        }
        idx += 1;
    }

    return get_or_create_add(ops.*, strengthen_no_wrap_flags(.ADD, ops.*, orig_flags));
}

// getOrCreateAddExpr: the type is the first pointer-typed operand's, else operand 0's
get_or_create_add :: (ops: [] Scev_Id, flags: u8) -> Scev_Id {
    s := sc_find(.ADD, ops);
    if !s {
        ty := sc_type(ops[0]);
        for ops if sc_is_ptr(it) { ty = sc_type(it); break; }
        s = sc_insert(.ADD, ops, ty);
    }
    sc_row(s).flags |= flags;
    return s;
}
get_or_create_add_rec :: (ops: [] Scev_Id, l: Loop_Id, flags: u8) -> Scev_Id {
    s := sc_find(.ADDREC, ops, NONE, NONE, l);
    if !s s = sc_insert(.ADDREC, ops, sc_type(ops[0]), NONE, l);
    sc_set_no_wrap_flags(s, flags);
    return s;
}
get_or_create_mul :: (ops: [] Scev_Id, flags: u8) -> Scev_Id {
    s := sc_find(.MUL, ops);
    if !s s = sc_insert(.MUL, ops, sc_type(ops[0]));
    sc_row(s).flags |= flags;
    return s;
}

// ScalarEvolution::setNoWrapFlags(SCEVAddRecExpr *, Flags)
sc_set_no_wrap_flags :: (ar: Scev_Id, flags_in: u8) {
    flags := flags_in;
    if sc_flags(ar, flags) != flags {
        if flags & (SF_NUW | SF_NSW) flags |= SF_NW;
        sc_row(ar).flags |= flags;
        table_remove(*se.unsigned_ranges, ar);
        table_remove(*se.signed_ranges, ar);
        table_remove(*se.const_multiple, ar);
    }
}

// ---------------------------------------------------------------- mul

umul_ov_u64 :: (i: u64, j: u64, overflow: *bool) -> u64 {
    k := i * j;
    if j > 1 && k / j != i overflow.* = true;
    return k;
}
choose_u64 :: (n_in: u64, k_in: u64, overflow: *bool) -> u64 {
    n := n_in; k := k_in;
    if n == 0 || n == k return 1;
    if k > n return 0;
    if k > n / 2 k = n - k;
    r: u64 = 1;
    i: u64 = 1;
    while i <= k {
        r = umul_ov_u64(r, n - (i - 1), overflow);
        r /= i;
        i += 1;
    }
    return r;
}

contains_constant_in_add_mul_chain :: (start: Scev_Id) -> bool {
    v: Sc_Visitor;
    v.follow = (v: *Sc_Visitor, s: Scev_Id) -> bool {
        v.found |= sc_is_const(s);
        return sc_is_add(s) || sc_is_mul(s);
    };
    v.is_done = (v: *Sc_Visitor) -> bool { return v.found; };
    sc_visit_all(start, *v);
    return v.found;
}

sc_get_mul2 :: (a: Scev_Id, b: Scev_Id, flags: u8 = SF_ANY, depth: u32 = 0) -> Scev_Id {
    ops := sc_list(a, b);
    return sc_get_mul(*ops, flags, depth);
}
sc_get_mul3 :: (a: Scev_Id, b: Scev_Id, c: Scev_Id, flags: u8 = SF_ANY, depth: u32 = 0) -> Scev_Id {
    ops := sc_list(a, b, c);
    return sc_get_mul(*ops, flags, depth);
}

sc_get_mul :: (ops: *[..] Scev_Id, orig_flags: u8 = SF_ANY, depth: u32 = 0) -> Scev_Id {
    if ops.count == 1 return ops.*[0];
    folded := constant_fold_and_group_ops(ops, .MUL);
    if folded != SCEV_CNC return folded;

    if cast(u64) depth > scev_opts.max_arith_depth || has_huge_expression(ops.*)
        return get_or_create_mul(ops.*, strengthen_no_wrap_flags(.MUL, ops.*, orig_flags));

    {
        s := sc_find(.MUL, ops.*);
        if s {
            if sc_flags(s, orig_flags) != orig_flags sc_row(s).flags |= strengthen_no_wrap_flags(.MUL, ops.*, orig_flags);
            return s;
        }
    }

    if sc_is_const(ops.*[0]) {
        lhsc := ops.*[0];
        if ops.count == 2 {
            o1 := ops.*[1];
            // C1*(C2+V) -> C1*C2 + C1*V
            if sc_is_add(o1) && sc_nops(o1) == 2 && contains_constant_in_add_mul_chain(o1) {
                op0 := sc_op(o1, 0); op1 := sc_op(o1, 1);
                lhs := sc_get_mul2(lhsc, op0, SF_ANY, depth + 1);
                rhs := sc_get_mul2(lhsc, op1, SF_ANY, depth + 1);
                return sc_get_add2(lhs, rhs, SF_ANY, depth + 1);
            }
            if sc_is_all_ones(lhsc) {
                if sc_is_add(o1) {
                    new_ops: [..] Scev_Id; new_ops.allocator = temp;
                    any_folded := false;
                    for k: 0..cast(s64) sc_nops(o1) - 1 {
                        m := sc_get_mul2(lhsc, sc_op(o1, cast(u32) k), SF_ANY, depth + 1);
                        if !sc_is_mul(m) any_folded = true;
                        array_add(*new_ops, m);
                    }
                    if any_folded return sc_get_add(*new_ops, SF_ANY, depth + 1);
                } else if sc_is_addrec(o1) {
                    operands: [..] Scev_Id; operands.allocator = temp;
                    for k: 0..cast(s64) sc_nops(o1) - 1 array_add(*operands, sc_get_mul2(lhsc, sc_op(o1, cast(u32) k), SF_ANY, depth + 1));
                    flags_mask := SF_NW;
                    if sc_has_nsw(o1) {
                        min_int := ap_signed_min(sc_bits(o1));
                        if !ap_eq(sc_signed_range_min(o1), min_int) flags_mask = set_flags(flags_mask, SF_NSW);
                    }
                    return sc_get_add_rec_ops(*operands, sc_loop(o1), sc_flags(o1, flags_mask));
                }
            }
            // Try to push the constant operand into a ZExt: C * zext (A + B) -> zext (C*A + C*B) if trunc (C) * (A + B)
            // does not unsigned-wrap.
            if sc_is_zext(o1) && sc_is_add(sc_op(o1, 0)) {
                inner_add := sc_op(o1, 0);
                narrow_c := sc_get_truncate(lhsc, sc_type(inner_add));
                if sc_is_const(sc_op(inner_add, 0)) && sc_get_zero_extend(narrow_c, sc_type(o1)) == lhsc &&
                   has_flags(strengthen_no_wrap_flags(.MUL, .[narrow_c, inner_add], SF_ANY), SF_NUW) {
                    res := sc_get_mul2(narrow_c, inner_add, SF_NUW, depth + 1);
                    return sc_get_zero_extend(res, sc_type(o1), depth + 1);
                }
            }
            // Fold (C1 * D /u C2) -> C1/C2 * D, if C1 and C2 are powers-of-2, and D is a multiple of C2, and
            // (C1 * D /u C2) -> D /u (C2/C1) if C2 > C1. ... |C1| for C1 negative.
            c1v := sc_ap(lhsc);
            if ap_is_negative(c1v) && !ap_is_min_signed(c1v) && !ap_is_all_ones(c1v) c1v = ap_abs(c1v);
            if ap_is_power_of_2(c1v) && sc_is_udiv(o1) && sc_is_const(sc_op(o1, 1)) {
                d := sc_op(o1, 0);
                c2 := sc_op(o1, 1);
                c2a := sc_ap(c2);
                if ap_is_power_of_2(c2a) && ap_log2(c1v) <= sc_get_min_trailing_zeros(d) {
                    new_mul: Scev_Id = SCEV_CNC;
                    if ap_uge(c1v, c2a) {
                        new_mul = sc_get_mul2(sc_get_udiv(sc_get_constant(c1v), c2), d);
                    } else if ap_log2(c2a) <= sc_get_min_trailing_zeros(d) {
                        new_mul = sc_get_udiv(d, sc_get_udiv(c2, sc_get_constant(c1v)));
                    }
                    if new_mul != SCEV_CNC {
                        if ap_eq(c1v, sc_ap(lhsc)) return new_mul;
                        return sc_get_negative(new_mul);
                    }
                }
            }
        }
    }

    idx := 0;
    while idx < ops.count && sc_kind(ops.*[idx]) < .MUL idx += 1;
    if idx < ops.count {
        deleted_mul := false;
        while sc_is_mul(ops.*[idx]) {
            if cast(u64) ops.count > scev_opts.mulops_inline_threshold break;
            mul := ops.*[idx];
            array_ordered_remove_by_index(ops, idx);
            for k: 0..cast(s64) sc_nops(mul) - 1 array_add(ops, sc_op(mul, cast(u32) k));
            deleted_mul = true;
        }
        if deleted_mul return sc_get_mul(ops, SF_ANY, depth + 1);
    }

    while idx < ops.count && sc_kind(ops.*[idx]) < .ADDREC idx += 1;

    while idx < ops.count && sc_is_addrec(ops.*[idx]) {
        li_ops: [..] Scev_Id; li_ops.allocator = temp;
        add_rec := ops.*[idx];
        i := 0;
        e := ops.count;
        while i != e {
            if sc_is_available_at_loop_entry(ops.*[i], sc_loop(add_rec)) {
                array_add(*li_ops, ops.*[i]);
                array_ordered_remove_by_index(ops, i);
                i -= 1; e -= 1;
            }
            i += 1;
        }
        if li_ops.count > 0 {
            new_ops: [..] Scev_Id; new_ops.allocator = temp;
            scale := sc_get_mul(*li_ops, SF_ANY, depth + 1);
            flags := sc_flags(add_rec, strengthen_no_wrap_flags(.MUL, .[scale, add_rec], orig_flags));
            for k: 0..cast(s64) sc_nops(add_rec) - 1 {
                array_add(*new_ops, sc_get_mul2(scale, sc_op(add_rec, cast(u32) k), SF_ANY, depth + 1));
                if has_flags(flags, SF_NSW) && !has_flags(flags, SF_NUW) {
                    nsw_region := cr_guaranteed_no_wrap_region(.MUL, sc_signed_range(scale), false);
                    if !cr_contains_range(nsw_region, sc_signed_range(sc_op(add_rec, cast(u32) k))) flags = clear_flags(flags, SF_NSW);
                }
            }
            new_rec := sc_get_add_rec_ops(*new_ops, sc_loop(add_rec), flags);
            if ops.count == 1 return new_rec;
            for k: 0..ops.count-1 if ops.*[k] == add_rec { ops.*[k] = new_rec; break; }
            return sc_get_mul(ops, SF_ANY, depth + 1);
        }

        ops_modified := false;
        other_idx := idx + 1;
        while other_idx != ops.count && sc_is_addrec(ops.*[other_idx]) {
            other_ar := ops.*[other_idx];
            if sc_loop(other_ar) != sc_loop(add_rec) { other_idx += 1; continue; }
            if cast(u64) (sc_nops(add_rec) + sc_nops(other_ar) - 1) > scev_opts.max_add_rec_size || has_huge_expression(.[add_rec, other_ar]) {
                other_idx += 1; continue;
            }
            overflow := false;
            ty := sc_type(add_rec);
            larger_than_64 := sc_type_bits(ty) > 64;
            add_rec_ops: [..] Scev_Id; add_rec_ops.allocator = temp;
            xe := cast(s64) (sc_nops(add_rec) + sc_nops(other_ar) - 1);
            x := 0;
            while x != xe && !overflow {
                sum_ops: [..] Scev_Id; sum_ops.allocator = temp;
                y := x;
                ye := 2 * x + 1;
                while y != ye && !overflow {
                    coeff1 := choose_u64(cast(u64) x, cast(u64) (2 * x - y), *overflow);
                    z := max(y - x, y - cast(s64) sc_nops(add_rec) + 1);
                    ze := min(x + 1, cast(s64) sc_nops(other_ar));
                    while z < ze && !overflow {
                        coeff2 := choose_u64(cast(u64) (2 * x - y), cast(u64) (x - z), *overflow);
                        coeff: u64;
                        if larger_than_64 coeff = umul_ov_u64(coeff1, coeff2, *overflow);
                        else coeff = coeff1 * coeff2;
                        coeff_term := sc_get_constant_t(ty, coeff);
                        term1 := sc_op(add_rec, cast(u32) (y - z));
                        term2 := sc_op(other_ar, cast(u32) z);
                        array_add(*sum_ops, sc_get_mul3(coeff_term, term1, term2, SF_ANY, depth + 1));
                        z += 1;
                    }
                    y += 1;
                }
                if sum_ops.count == 0 array_add(*sum_ops, sc_get_zero(ty));
                array_add(*add_rec_ops, sc_get_add(*sum_ops, SF_ANY, depth + 1));
                x += 1;
            }
            if !overflow {
                new_add_rec := sc_get_add_rec_ops(*add_rec_ops, sc_loop(add_rec), SF_ANY);
                if ops.count == 2 return new_add_rec;
                ops.*[idx] = new_add_rec;
                array_ordered_remove_by_index(ops, other_idx);
                other_idx -= 1;
                ops_modified = true;
                if !sc_is_addrec(new_add_rec) break;
                add_rec = new_add_rec;
            }
            other_idx += 1;
        }
        if ops_modified return sc_get_mul(ops, SF_ANY, depth + 1);
        idx += 1;
    }

    return get_or_create_mul(ops.*, strengthen_no_wrap_flags(.MUL, ops.*, orig_flags));
}

// ---------------------------------------------------------------- urem / udiv

// m_scev_URem(LHS, RHS, SE)
match_urem :: (expr: Scev_Id) -> (bool, Scev_Id, Scev_Id) {
    if sc_is_ptr(expr) return false, 0, 0;
    if sc_is_zext(expr) && sc_is_trunc(sc_op(expr, 0)) {
        trunc_ty := sc_type(sc_op(expr, 0));
        lhs := sc_op(sc_op(expr, 0), 0);
        if sc_bits(lhs) > sc_bits(expr) return false, 0, 0;
        if sc_type(lhs) != sc_type(expr) lhs = sc_get_zero_extend(lhs, sc_type(expr));
        rhs := sc_get_constant(ap_shl(ap_one(sc_bits(expr)), sc_type_bits(trunc_ty)));
        return true, lhs, rhs;
    }
    if !(sc_is_add(expr) && sc_nops(expr) == 2 && sc_is_mul(sc_op(expr, 0))) return false, 0, 0;
    mul := sc_op(expr, 0);
    a := sc_op(expr, 1);
    try :: (expr: Scev_Id, a: Scev_Id, b: Scev_Id) -> bool { return expr == sc_get_urem(a, b); }
    if sc_nops(mul) == 3 && sc_is_const(sc_op(mul, 0)) {
        if try(expr, a, sc_op(mul, 1)) return true, a, sc_op(mul, 1);
        if try(expr, a, sc_op(mul, 2)) return true, a, sc_op(mul, 2);
        return false, 0, 0;
    }
    if sc_nops(mul) == 2 {
        if try(expr, a, sc_op(mul, 1)) return true, a, sc_op(mul, 1);
        if try(expr, a, sc_op(mul, 0)) return true, a, sc_op(mul, 0);
        n1 := sc_get_negative(sc_op(mul, 1));
        if try(expr, a, n1) return true, a, n1;
        n0 := sc_get_negative(sc_op(mul, 0));
        if try(expr, a, n0) return true, a, n0;
    }
    return false, 0, 0;
}

sc_get_urem :: (lhs: Scev_Id, rhs: Scev_Id) -> Scev_Id {
    if sc_is_const(rhs) {
        rc := sc_ap(rhs);
        if ap_is_one(rc) return sc_get_zero(sc_type(lhs));
        if ap_is_power_of_2(rc) {
            full_ty := sc_type(lhs);
            trunc_ty := type_int(ap_log2(rc));
            return sc_get_zero_extend(sc_get_truncate(lhs, trunc_ty), full_ty);
        }
    }
    udiv := sc_get_udiv(lhs, rhs);
    mult := sc_get_mul2(udiv, rhs, SF_NUW);
    return sc_get_minus(lhs, mult, SF_NUW);
}

sc_get_udiv :: (lhs_in: Scev_Id, rhs: Scev_Id) -> Scev_Id {
    lhs := lhs_in;
    s := sc_find(.UDIV, .[lhs, rhs]);
    if s return s;
    if sc_is_zero(lhs) return lhs;

    if sc_is_const(rhs) {
        rc := sc_ap(rhs);
        if ap_is_one(rc) return lhs;
        if !ap_is_zero(rc) {
            ty := sc_type(lhs);
            lz := ap_clz(rc);
            max_shift_amt := sc_type_bits(ty) - lz - 1;
            if !ap_is_power_of_2(rc) max_shift_amt += 1;
            ext_ty := type_int(sc_type_bits(ty) + max_shift_amt);
            if sc_is_addrec(lhs) {
                ar := lhs;
                step := sc_step_recurrence(ar);
                if sc_is_const(step) {
                    step_int := sc_ap(step);
                    div_int := rc;
                    if ap_is_zero(ap_urem(step_int, div_int)) &&
                       sc_get_zero_extend(ar, ext_ty) == sc_get_add_rec(sc_get_zero_extend(sc_start(ar), ext_ty), sc_get_zero_extend(step, ext_ty), sc_loop(ar), SF_ANY) {
                        operands: [..] Scev_Id; operands.allocator = temp;
                        for k: 0..cast(s64) sc_nops(ar) - 1 array_add(*operands, sc_get_udiv(sc_op(ar, cast(u32) k), rhs));
                        return sc_get_add_rec_ops(*operands, sc_loop(ar), SF_NW);
                    }
                    // (A*B)/C --> A*(B/C) if safe and B/C can be folded. {X,+,N}/C => {Y,+,N}/C ...
                    if ap_is_zero(ap_urem(div_int, step_int)) {
                        start_rem := sc_get_urem(sc_start(ar), step);
                        if sc_is_const(start_rem) {
                            sr := sc_ap(start_rem);
                            no_wrap := sc_get_zero_extend(ar, ext_ty) ==
                                       sc_get_add_rec(sc_get_zero_extend(sc_start(ar), ext_ty), sc_get_zero_extend(step, ext_ty), sc_loop(ar), SF_ANY);
                            can_fold_with_wrap := ap_ule(step_int, div_int) && ap_is_power_of_2(step_int) && ap_is_power_of_2(div_int);
                            new_start := sc_get_minus(sc_start(ar), sc_get_constant(sr));
                            if !ap_is_zero(sr) && (no_wrap || can_fold_with_wrap) && !sc_is_add(new_start) {
                                new_lhs := sc_get_add_rec(new_start, step, sc_loop(ar), ifx no_wrap then SF_NW else SF_ANY);
                                if lhs != new_lhs {
                                    lhs = new_lhs;
                                    s = sc_find(.UDIV, .[lhs, rhs]);
                                    if s return s;
                                }
                            }
                        }
                    }
                }
            }
            // (A*B)/C --> A*(B/C) if safe and B/C can be folded.
            if sc_is_mul(lhs) {
                m := lhs;
                operands: [..] Scev_Id; operands.allocator = temp;
                for k: 0..cast(s64) sc_nops(m) - 1 array_add(*operands, sc_get_zero_extend(sc_op(m, cast(u32) k), ext_ty));
                if sc_get_zero_extend(m, ext_ty) == sc_get_mul(*operands) {
                    for k: 0..cast(s64) sc_nops(m) - 1 {
                        o := sc_op(m, cast(u32) k);
                        div := sc_get_udiv(o, rhs);
                        if !sc_is_udiv(div) && sc_get_mul2(div, rhs) == o {
                            ops2 := sc_operands(m);
                            ops2[k] = div;
                            return sc_get_mul(*ops2);
                        }
                    }
                    // (A/B)/C --> A/(B*C) ... (C1*A)/C2 -> C1'*A / C2' with gcd
                    if sc_is_const(sc_op(m, 0)) {
                        lhsc := sc_ap(sc_op(m, 0));
                        factor := ap_gcd(lhsc, rc);
                        if !(ap_active_bits(factor) <= 1) {   // !Factor.isIntN(1)
                            new_operands: [..] Scev_Id; new_operands.allocator = temp;
                            array_add(*new_operands, sc_get_constant(ap_udiv(lhsc, factor)));
                            for k: 1..cast(s64) sc_nops(m) - 1 array_add(*new_operands, sc_op(m, cast(u32) k));
                            new_mul := sc_get_mul(*new_operands);
                            return sc_get_udiv(new_mul, sc_get_constant(ap_udiv(rc, factor)));
                        }
                    }
                }
            }
            // (A/B)/C --> A/(B*C) if safe and B*C can be folded.
            if sc_is_udiv(lhs) {
                if sc_is_const(sc_op(lhs, 1)) {
                    new_rhs, ov := ap_umul_ov(sc_ap(sc_op(lhs, 1)), rc);
                    if ov return sc_get_constant_t(sc_type(rhs), 0, false);
                    return sc_get_udiv(sc_op(lhs, 0), sc_get_constant(new_rhs));
                }
            }
            // (A+B)/C --> (A/C + B/C) if safe and A/C and B/C can be folded.
            if sc_is_add(lhs) {
                a := lhs;
                operands: [..] Scev_Id; operands.allocator = temp;
                for k: 0..cast(s64) sc_nops(a) - 1 array_add(*operands, sc_get_zero_extend(sc_op(a, cast(u32) k), ext_ty));
                if sc_get_zero_extend(a, ext_ty) == sc_get_add(*operands) {
                    operands.count = 0;
                    for k: 0..cast(s64) sc_nops(a) - 1 {
                        o := sc_get_udiv(sc_op(a, cast(u32) k), rhs);
                        if sc_is_udiv(o) || sc_get_mul2(o, rhs) != sc_op(a, cast(u32) k) break;
                        array_add(*operands, o);
                    }
                    if operands.count == cast(s64) sc_nops(a) return sc_get_add(*operands);
                }
            }
            // ((-M + N) + M * A) / N -> ((N-1) + M*A) / N  (N, M powers of 2, M < N)
            if sc_is_add(lhs) && sc_nops(lhs) == 2 && sc_is_const(sc_op(lhs, 0)) {
                mm := sc_op(lhs, 1);
                if sc_is_mul(mm) && sc_nops(mm) == 2 && sc_is_const(sc_op(mm, 0)) {
                    n := rc;
                    n_minus_m := sc_ap(sc_op(lhs, 0));
                    m := sc_ap(sc_op(mm, 0));
                    a := sc_op(mm, 1);
                    if ap_is_power_of_2(n) && ap_is_power_of_2(m) && ap_ult(m, n) && ap_eq(n_minus_m, ap_sub(n, m))
                        return sc_get_udiv(sc_get_add2(sc_get_constant(ap_sub_u64(n, 1)), sc_get_mul2(sc_get_constant(m), a)), rhs);
                }
            }
            if sc_is_const(lhs) return sc_get_constant(ap_udiv(sc_ap(lhs), rc));
        }
    }

    // ((-C + (C smax %x)) /u %x) evaluates to zero, for positive constant C.
    if sc_is_add(lhs) && sc_nops(lhs) == 2 && sc_is_const(sc_op(lhs, 0)) {
        sm := sc_op(lhs, 1);
        if sc_kind(sm) == .SMAX && sc_nops(sm) == 2 && sc_is_const(sc_op(sm, 0)) && sc_op(sm, 1) == rhs {
            neg_c := sc_ap(sc_op(lhs, 0));
            c := sc_ap(sc_op(sm, 0));
            if ap_is_negative(neg_c) && !ap_is_min_signed(neg_c) && ap_eq(c, ap_neg(neg_c)) return sc_get_zero(sc_type(lhs));
        }
    }

    // X /u Y --> (X * Y) / Y ... (A * B)<nuw> /u B -> A
    if sc_is_mul(lhs) && sc_has_nuw(lhs) {
        m := lhs;
        for k: 0..cast(s64) sc_nops(m) - 1 {
            if sc_op(m, cast(u32) k) == rhs {
                operands := sc_operands(m);
                array_ordered_remove_by_index(*operands, k);
                return sc_get_mul(*operands);
            }
        }
    }

    // (A * vscale)<nuw> /u (B * vscale)<nuw> -> A /u B
    {
        ok1, nl := match_c_nuw_mul_vscale(lhs);
        ok2, nr := match_c_nuw_mul_vscale(rhs);
        if ok1 && ok2 return sc_get_udiv(nl, nr);
    }

    s = sc_find(.UDIV, .[lhs, rhs]);
    if s return s;
    return sc_insert(.UDIV, .[lhs, rhs], sc_type(rhs));
}
// m_scev_c_NUWMul(m_SCEV(X), m_SCEVVScale())
match_c_nuw_mul_vscale :: (s: Scev_Id) -> (bool, Scev_Id) {
    if !sc_is_mul(s) || !sc_has_nuw(s) || sc_nops(s) != 2 return false, 0;
    if sc_kind(sc_op(s, 1)) == .VSCALE return true, sc_op(s, 0);
    if sc_kind(sc_op(s, 0)) == .VSCALE return true, sc_op(s, 1);
    return false, 0;
}
// getUDivExactExpr
sc_get_udiv_exact :: (lhs: Scev_Id, rhs: Scev_Id) -> Scev_Id {
    // TODO in LLVM: this is getUDivExpr with a known-exact division; LLVM 23 just calls getUDivExpr
    return sc_get_udiv(lhs, rhs);
}

// ---------------------------------------------------------------- addrec

sc_get_add_rec :: (start: Scev_Id, step: Scev_Id, l: Loop_Id, flags: u8) -> Scev_Id {
    operands: [..] Scev_Id; operands.allocator = temp;
    array_add(*operands, start);
    if sc_is_addrec(step) && sc_loop(step) == l {
        for k: 0..cast(s64) sc_nops(step) - 1 array_add(*operands, sc_op(step, cast(u32) k));
        return sc_get_add_rec_ops(*operands, l, mask_flags(flags, SF_NW));
    }
    array_add(*operands, step);
    return sc_get_add_rec_ops(*operands, l, flags);
}

sc_get_add_rec_ops :: (operands: *[..] Scev_Id, l: Loop_Id, flags_in: u8) -> Scev_Id {
    if operands.count == 1 return operands.*[0];
    if sc_is_zero(operands.*[operands.count - 1]) {
        operands.count -= 1;
        return sc_get_add_rec_ops(operands, l, SF_ANY);
    }
    flags := strengthen_no_wrap_flags(.ADDREC, operands.*, flags_in);

    if sc_is_addrec(operands.*[0]) {
        nested_ar := operands.*[0];
        nested_loop := sc_loop(nested_ar);
        cond: bool;
        if li_contains_loop(se.li, l, nested_loop) cond = li_depth(se.li, l) < li_depth(se.li, nested_loop);
        else cond = !li_contains_loop(se.li, nested_loop, l) && dt_dominates(se.dt, li_header(se.li, l), li_header(se.li, nested_loop));
        if cond {
            nested_operands := sc_operands(nested_ar);
            operands.*[0] = sc_start(nested_ar);
            all_invariant := true;
            for operands.* if !sc_is_loop_invariant(it, l) { all_invariant = false; break; }
            if all_invariant {
                outer_flags := mask_flags(flags, SF_NW | sc_flags(nested_ar));
                nested_operands[0] = sc_get_add_rec_ops(operands, l, outer_flags);
                all_invariant = true;
                for nested_operands if !sc_is_loop_invariant(it, nested_loop) { all_invariant = false; break; }
                if all_invariant {
                    inner_flags := mask_flags(sc_flags(nested_ar), SF_NW | flags);
                    return sc_get_add_rec_ops(*nested_operands, nested_loop, inner_flags);
                }
            }
            operands.*[0] = nested_ar;
        }
    }
    return get_or_create_add_rec(operands.*, l, flags);
}

// ---------------------------------------------------------------- GEP

// getGEPExpr(BaseExpr, IndexExprs, SrcElementTy, NW): nw_flags = GEP F_INBOUNDS/F_NUSW/F_GEP_NUW bits
sc_get_gep :: (base_expr: Scev_Id, index_exprs: [] Scev_Id, src_elt_ty: Type_Id, nw_flags: u32, index_values: [] Value_Id) -> Scev_Id {
    offset_wrap := SF_ANY;
    nusw := (nw_flags & (F_NUSW | F_INBOUNDS)) != 0;
    nuw := (nw_flags & F_GEP_NUW) != 0;
    if nusw offset_wrap = set_flags(offset_wrap, SF_NSW);
    if nuw offset_wrap = set_flags(offset_wrap, SF_NUW);
    cur_ty := sc_type(base_expr);
    int_idx_ty := sc_effective_type(sc_type(base_expr));
    first_iter := true;
    offsets: [..] Scev_Id; offsets.allocator = temp;
    for ie, k: index_exprs {
        if type_kind(cur_ty) == .STRUCT {
            field_no := const_int_zext(sc_value(ie));
            field_offset := sc_get_constant_t(int_idx_ty, dl_struct_offset(cur_ty, cast(u32) field_no));
            array_add(*offsets, field_offset);
            cur_ty = type_sub(cur_ty, cast(u32) field_no);
        } else {
            if first_iter { cur_ty = src_elt_ty; first_iter = false; }
            else cur_ty = type_elem(cur_ty);
            element_size := sc_get_size_of(int_idx_ty, cur_ty);
            idx := sc_get_truncate_or_sign_extend(ie, int_idx_ty);
            local_offset := sc_get_mul2(idx, element_size, offset_wrap);
            array_add(*offsets, local_offset);
        }
    }
    if offsets.count == 0 return base_expr;
    offset := sc_get_add(*offsets, offset_wrap);
    gep_nuw := nuw || (nusw && sc_is_known_non_negative(offset));
    base_wrap := ifx gep_nuw then SF_NUW else SF_ANY;
    return sc_get_add2(base_expr, offset, base_wrap);
}

// ---------------------------------------------------------------- min / max

sc_get_min_max :: (kind: Scev_Kind, ops: *[..] Scev_Id) -> Scev_Id {
    if ops.count == 1 return ops.*[0];
    is_signed := kind == .SMAX || kind == .SMIN;
    is_max := kind == .SMAX || kind == .UMAX;
    fk: Fold_Kind;
    if kind == {
        case .SMAX; fk = .SMAX;
        case .SMIN; fk = .SMIN;
        case .UMAX; fk = .UMAX;
        case .UMIN; fk = .UMIN;
    }
    folded := constant_fold_and_group_ops(ops, fk);
    if folded != SCEV_CNC return folded;
    {
        s := sc_find(kind, ops.*);
        if s return s;
    }
    idx := 0;
    while idx < ops.count && sc_kind(ops.*[idx]) < kind idx += 1;
    if idx < ops.count {
        deleted_any := false;
        while idx < ops.count && sc_kind(ops.*[idx]) == kind {
            smme := ops.*[idx];
            array_ordered_remove_by_index(ops, idx);
            for k: 0..cast(s64) sc_nops(smme) - 1 array_add(ops, sc_op(smme, cast(u32) k));
            deleted_any = true;
        }
        if deleted_any return sc_get_min_max(kind, ops);
    }
    ge_pred := ifx is_signed then cast(u8) ICMP_SGE else ICMP_UGE;
    le_pred := ifx is_signed then cast(u8) ICMP_SLE else ICMP_ULE;
    first_pred := ifx is_max then ge_pred else le_pred;
    second_pred := ifx is_max then le_pred else ge_pred;
    i := 0;
    e := ops.count - 1;
    while i != e {
        if ops.*[i] == ops.*[i+1] || sc_is_known_via_non_recursive_reasoning(first_pred, ops.*[i], ops.*[i+1]) {
            array_ordered_remove_by_index(ops, i + 1);
            i -= 1; e -= 1;
        } else if sc_is_known_via_non_recursive_reasoning(second_pred, ops.*[i], ops.*[i+1]) {
            array_ordered_remove_by_index(ops, i);
            i -= 1; e -= 1;
        }
        i += 1;
    }
    if ops.count == 1 return ops.*[0];
    s := sc_find(kind, ops.*);
    if s return s;
    return sc_insert(kind, ops.*, sc_type(ops.*[0]), NONE, NONE, SF_NUW | SF_NSW);
}

// SCEVSequentialMinMaxDeduplicatingVisitor
Seq_Dedup :: struct { root_kind: Scev_Kind; non_seq_kind: Scev_Kind; seen: Table(Scev_Id, bool); }
seq_dedup_visit_ops :: (d: *Seq_Dedup, orig: [] Scev_Id, new_ops: *[..] Scev_Id) -> bool {
    changed := false;
    ops: [..] Scev_Id; ops.allocator = temp;
    for o: orig {
        has, nop := seq_dedup_visit(d, o);
        if !has || nop != o changed = true;
        if has array_add(*ops, nop);
    }
    if changed new_ops.* = ops;
    return changed;
}
// returns (has_value, value): std::optional<const SCEV *>
seq_dedup_visit :: (d: *Seq_Dedup, s: Scev_Id) -> (bool, Scev_Id) {
    if table_contains(*d.seen, s) return false, 0;
    table_set(*d.seen, s, true);
    k := sc_kind(s);
    if !(sc_is_minmax_kind(k) || k == .SEQ_UMIN) return true, s;
    if !(d.root_kind == k || d.non_seq_kind == k) return true, s;
    new_ops: [..] Scev_Id; new_ops.allocator = temp;
    orig := sc_operands(s);
    changed := seq_dedup_visit_ops(d, orig, *new_ops);
    if !changed return true, s;
    if new_ops.count == 0 return false, 0;
    if k == .SEQ_UMIN return true, sc_get_sequential_min_max(k, *new_ops);
    return true, sc_get_min_max(k, *new_ops);
}

// scevUnconditionallyPropagatesPoisonFromOperands
scev_unconditionally_propagates_poison :: (k: Scev_Kind) -> bool { return k != .SEQ_UMIN; }

// SCEVPoisonCollector
poison_collect :: (s: Scev_Id, look_through: bool, out: *[..] Scev_Id) {
    Ctx :: struct { look_through: bool; out: *[..] Scev_Id; }
    ctx := Ctx.{look_through, out};
    v: Sc_Visitor;
    v.data = *ctx;
    v.follow = (v: *Sc_Visitor, s: Scev_Id) -> bool {
        c := cast(*Ctx) v.data;
        if !c.look_through && !scev_unconditionally_propagates_poison(sc_kind(s)) return false;
        if sc_is_unknown(s) && !is_guaranteed_not_to_be_poison(sc_value(s)) {
            found := false;
            for c.out.* if it == s { found = true; break; }
            if !found array_add(c.out, s);
        }
        return true;
    };
    sc_visit_all(s, *v);
}
// impliesPoison(AssumedPoison, S) (the SCEV version)
sc_implies_poison :: (assumed_poison: Scev_Id, s: Scev_Id) -> bool {
    pc1: [..] Scev_Id; pc1.allocator = temp;
    poison_collect(assumed_poison, true, *pc1);
    if pc1.count == 0 return true;
    pc2: [..] Scev_Id; pc2.allocator = temp;
    poison_collect(s, false, *pc2);
    for a: pc1 {
        found := false;
        for b: pc2 if a == b { found = true; break; }
        if !found return false;
    }
    return true;
}
// getPoisonGeneratingValues
sc_get_poison_generating_values :: (result: *[..] Value_Id, s: Scev_Id) {
    pc: [..] Scev_Id; pc.allocator = temp;
    poison_collect(s, false, *pc);
    for pc {
        v := sc_value(it);
        found := false;
        for r: result.* if r == v { found = true; break; }
        if !found array_add(result, v);
    }
}

sc_get_sequential_min_max :: (kind: Scev_Kind, ops: *[..] Scev_Id) -> Scev_Id {
    if ops.count == 1 return ops.*[0];
    {
        s := sc_find(kind, ops.*);
        if s return s;
    }
    {
        d: Seq_Dedup;
        d.root_kind = kind;
        d.non_seq_kind = .UMIN;
        d.seen.allocator = temp;
        orig := sc_list_copy(ops.*);
        changed := seq_dedup_visit_ops(*d, orig, ops);
        if changed return sc_get_sequential_min_max(kind, ops);
    }
    {
        idx := 0;
        deleted_any := false;
        while idx < ops.count {
            if sc_kind(ops.*[idx]) != kind { idx += 1; continue; }
            smme := ops.*[idx];
            array_ordered_remove_by_index(ops, idx);
            for k: 0..cast(s64) sc_nops(smme) - 1 array_insert_at(ops, sc_op(smme, cast(u32) k), idx + k);
            deleted_any = true;
        }
        if deleted_any return sc_get_sequential_min_max(kind, ops);
    }
    saturation_point := sc_get_zero(sc_type(ops.*[0]));
    pred: u8 = ICMP_ULE;
    for i: 1..ops.count-1 {
        if !sc_is_guaranteed_not_to_cause_ub(ops.*[i]) continue;
        if sc_implies_poison(ops.*[i], ops.*[i-1]) || sc_is_known_via_non_recursive_reasoning(ICMP_NE, ops.*[i-1], saturation_point) {
            seq_ops := sc_list(ops.*[i-1], ops.*[i]);
            ops.*[i-1] = sc_get_min_max(.UMIN, *seq_ops);
            array_ordered_remove_by_index(ops, i);
            return sc_get_sequential_min_max(kind, ops);
        }
        if sc_is_known_via_non_recursive_reasoning(pred, ops.*[i-1], ops.*[i]) {
            array_ordered_remove_by_index(ops, i);
            return sc_get_sequential_min_max(kind, ops);
        }
    }
    s := sc_find(kind, ops.*);
    if s return s;
    return sc_insert(kind, ops.*, sc_type(ops.*[0]), NONE, NONE, SF_NUW | SF_NSW);
}

sc_get_smax2 :: (a: Scev_Id, b: Scev_Id) -> Scev_Id { ops := sc_list(a, b); return sc_get_min_max(.SMAX, *ops); }
sc_get_umax2 :: (a: Scev_Id, b: Scev_Id) -> Scev_Id { ops := sc_list(a, b); return sc_get_min_max(.UMAX, *ops); }
sc_get_smin2 :: (a: Scev_Id, b: Scev_Id) -> Scev_Id { ops := sc_list(a, b); return sc_get_min_max(.SMIN, *ops); }
sc_get_umin2 :: (a: Scev_Id, b: Scev_Id, sequential := false) -> Scev_Id { ops := sc_list(a, b); return sc_get_umin(*ops, sequential); }
sc_get_umin :: (ops: *[..] Scev_Id, sequential := false) -> Scev_Id {
    if sequential return sc_get_sequential_min_max(.SEQ_UMIN, ops);
    return sc_get_min_max(.UMIN, ops);
}
// getAbsExpr
sc_get_abs :: (op: Scev_Id, is_nsw: bool) -> Scev_Id {
    flags := ifx is_nsw then SF_NSW else SF_ANY;
    return sc_get_smax2(op, sc_get_negative(op, flags));
}

// ---------------------------------------------------------------- negation, subtraction

sc_get_negative :: (v: Scev_Id, flags: u8 = SF_ANY) -> Scev_Id {
    if sc_is_const(v) return sc_get_constant(ap_neg(sc_ap(v)));
    ty := sc_effective_type(sc_type(v));
    return sc_get_mul2(v, sc_get_minus_one(ty), flags);
}
// MatchNotExpr: (-1 + (-1 * X)) -> X
match_not_expr :: (e: Scev_Id) -> Scev_Id {
    if sc_is_add(e) && sc_nops(e) == 2 && sc_is_all_ones(sc_op(e, 0)) {
        m := sc_op(e, 1);
        if sc_is_mul(m) && sc_nops(m) == 2 && sc_is_all_ones(sc_op(m, 0)) return sc_op(m, 1);
    }
    return SCEV_CNC;
}
// getNotSCEV
sc_get_not :: (v: Scev_Id) -> Scev_Id {
    if sc_is_const(v) return sc_get_constant(ap_not(sc_ap(v)));
    if sc_is_minmax(v) {
        matched: [..] Scev_Id; matched.allocator = temp;
        ok := true;
        for k: 0..cast(s64) sc_nops(v) - 1 {
            m := match_not_expr(sc_op(v, cast(u32) k));
            if m == SCEV_CNC { ok = false; break; }
            array_add(*matched, m);
        }
        if ok {
            nk: Scev_Kind;
            if sc_kind(v) == {
                case .SMAX; nk = .SMIN;
                case .SMIN; nk = .SMAX;
                case .UMAX; nk = .UMIN;
                case .UMIN; nk = .UMAX;
            }
            return sc_get_min_max(nk, *matched);
        }
    }
    ty := sc_effective_type(sc_type(v));
    return sc_get_minus(sc_get_minus_one(ty), v);
}
// removePointerBase
sc_remove_pointer_base :: (p: Scev_Id) -> Scev_Id {
    if sc_is_addrec(p) {
        ops := sc_operands(p);
        ops[0] = sc_remove_pointer_base(ops[0]);
        return sc_get_add_rec_ops(*ops, sc_loop(p), SF_ANY);
    }
    if sc_is_add(p) {
        ops := sc_operands(p);
        for ops if sc_is_ptr(it) { ops[it_index] = sc_remove_pointer_base(it); break; }
        return sc_get_add(*ops);
    }
    return sc_get_zero(sc_type(p));
}
// getPointerBase
sc_get_pointer_base :: (v_in: Scev_Id) -> Scev_Id {
    v := v_in;
    if !sc_is_ptr(v) return v;
    while true {
        if sc_is_addrec(v) v = sc_start(v);
        else if sc_is_add(v) {
            ptr_op: Scev_Id = SCEV_CNC;
            for k: 0..cast(s64) sc_nops(v) - 1 { o := sc_op(v, cast(u32) k); if sc_is_ptr(o) ptr_op = o; }
            v = ptr_op;
        } else return v;
    }
    return v;
}
// getMinusSCEV
sc_get_minus :: (lhs_in: Scev_Id, rhs_in: Scev_Id, flags: u8 = SF_ANY, depth: u32 = 0) -> Scev_Id {
    lhs := lhs_in; rhs := rhs_in;
    if lhs == rhs return sc_get_zero(sc_type(lhs));
    if sc_is_ptr(rhs) {
        if !sc_is_ptr(lhs) || sc_get_pointer_base(lhs) != sc_get_pointer_base(rhs) return SCEV_CNC;
        lhs = sc_remove_pointer_base(lhs);
        rhs = sc_remove_pointer_base(rhs);
    }
    add_flags := SF_ANY;
    rhs_is_not_min_signed := !ap_is_min_signed(sc_signed_range_min(rhs));
    if has_flags(flags, SF_NSW) {
        if rhs_is_not_min_signed || sc_is_known_non_negative(lhs) add_flags = SF_NSW;
    }
    neg_flags := ifx rhs_is_not_min_signed then SF_NSW else SF_ANY;
    return sc_get_add2(lhs, sc_get_negative(rhs, neg_flags), add_flags, depth);
}

// containsAddRecurrence
sc_contains_add_recurrence :: (s: Scev_Id) -> bool {
    found, v := table_find(*se.has_rec, s);
    if found return v;
    r := sc_expr_contains(s, (x: Scev_Id, d: *void) -> bool { return sc_is_addrec(x); });
    table_set(*se.has_rec, s, r);
    return r;
}

// ---------------------------------------------------------------- std::stable_sort (GCC 12 libstdc++, stl_algo.h)

// __stable_sort with a temporary buffer of (len + 1) / 2 elements: __stable_sort_adaptive, __merge_sort_with_buffer
// (__chunk_insertion_sort with _S_chunk_size 7, __merge_sort_loop), __merge_adaptive
gnu_stable_sort :: (a: [] Scev_Id, less: (Scev_Id, Scev_Id) -> bool) {
    n := a.count;
    if n == 0 return;
    buf := NewArray((n + 1) / 2, Scev_Id,, allocator = temp);
    len := (n + 1) / 2;
    first := a;
    first.count = len;
    second: [] Scev_Id;
    second.data = a.data + len;
    second.count = n - len;
    gnu_merge_sort_with_buffer(first, buf, less);
    gnu_merge_sort_with_buffer(second, buf, less);
    gnu_merge_adaptive(a, len, n - len, buf, less);
}
gnu_insertion_sort :: (a: [] Scev_Id, less: (Scev_Id, Scev_Id) -> bool) {
    if a.count == 0 return;
    for i: 1..a.count-1 {
        if less(a[i], a[0]) {
            val := a[i];
            j := i;
            while j > 0 { a[j] = a[j-1]; j -= 1; }
            a[0] = val;
        } else {
            val := a[i];
            last := i;
            nxt := i - 1;
            while less(val, a[nxt]) { a[last] = a[nxt]; last = nxt; nxt -= 1; }
            a[last] = val;
        }
    }
}
gnu_sub :: (a: [] Scev_Id, start: s64, count: s64) -> [] Scev_Id { r: [] Scev_Id; r.data = a.data + start; r.count = count; return r; }
// __move_merge: [f1, l1) and [f2, l2) into result; returns the number written
gnu_move_merge :: (x: [] Scev_Id, y: [] Scev_Id, result: [] Scev_Id, less: (Scev_Id, Scev_Id) -> bool) -> s64 {
    i := 0; j := 0; k := 0;
    while i != x.count && j != y.count {
        if less(y[j], x[i]) { result[k] = y[j]; j += 1; }
        else { result[k] = x[i]; i += 1; }
        k += 1;
    }
    while i != x.count { result[k] = x[i]; i += 1; k += 1; }
    while j != y.count { result[k] = y[j]; j += 1; k += 1; }
    return k;
}
gnu_merge_sort_loop :: (src: [] Scev_Id, dst: [] Scev_Id, step_in: s64, less: (Scev_Id, Scev_Id) -> bool) {
    step := step_in;
    two_step := 2 * step;
    f := 0;
    r := 0;
    last := src.count;
    while last - f >= two_step {
        r += gnu_move_merge(gnu_sub(src, f, step), gnu_sub(src, f + step, step), gnu_sub(dst, r, dst.count - r), less);
        f += two_step;
    }
    step = min(last - f, step);
    gnu_move_merge(gnu_sub(src, f, step), gnu_sub(src, f + step, last - f - step), gnu_sub(dst, r, dst.count - r), less);
}
gnu_merge_sort_with_buffer :: (a: [] Scev_Id, buf: [] Scev_Id, less: (Scev_Id, Scev_Id) -> bool) {
    len := a.count;
    step := 7;
    // __chunk_insertion_sort
    f := 0;
    while len - f >= step { gnu_insertion_sort(gnu_sub(a, f, step), less); f += step; }
    gnu_insertion_sort(gnu_sub(a, f, len - f), less);
    b := gnu_sub(buf, 0, len);
    while step < len {
        gnu_merge_sort_loop(a, b, step, less);
        step *= 2;
        gnu_merge_sort_loop(b, a, step, less);
        step *= 2;
    }
}
// __merge_adaptive with a buffer that holds the shorter run (always the case here)
gnu_merge_adaptive :: (a: [] Scev_Id, len1: s64, len2: s64, buf: [] Scev_Id, less: (Scev_Id, Scev_Id) -> bool) {
    if len1 <= len2 && len1 <= buf.count {
        for i: 0..len1-1 buf[i] = a[i];
        // __move_merge_adaptive(buffer, buffer_end, middle, last, first)
        i := 0; j := len1; k := 0;
        while i != len1 && j != len1 + len2 {
            if less(a[j], buf[i]) { a[k] = a[j]; j += 1; }
            else { a[k] = buf[i]; i += 1; }
            k += 1;
        }
        while i != len1 { a[k] = buf[i]; i += 1; k += 1; }
    } else if len2 <= buf.count {
        for i: 0..len2-1 buf[i] = a[len1 + i];
        // __move_merge_adaptive_backward(first, middle, buffer, buffer_end, last)
        if len1 == 0 { for i: 0..len2-1 a[i] = buf[i]; return; }
        if len2 == 0 return;
        l1 := len1 - 1;
        l2 := len2 - 1;
        r := len1 + len2;
        while true {
            if less(buf[l2], a[l1]) {
                r -= 1; a[r] = a[l1];
                if l1 == 0 { for < q: 0..l2 { r -= 1; a[r] = buf[q]; } return; }
                l1 -= 1;
            } else {
                r -= 1; a[r] = buf[l2];
                if l2 == 0 return;
                l2 -= 1;
            }
        }
    } else {
        fatal("internal: gnu_merge_adaptive without a large enough buffer");
    }
}
