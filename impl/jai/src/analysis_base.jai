// Shared analysis infrastructure for ValueTracking / InstructionSimplify / ConstantFolding and the passes that use
// them:
//   - Simplify_Query (llvm/include/llvm/Analysis/SimplifyQuery.h)
//   - intrinsic ID of a call (IntrinsicInst::getIntrinsicID), cached per callee
//   - Operator views of instructions and constant expressions (llvm/include/llvm/IR/Operator.h)
//   - Instruction::comesBefore, DominatorTree::dominates for instructions/uses/edges (llvm/lib/IR/Dominators.cpp)
//   - isGuaranteedToTransferExecutionToSuccessor (llvm/lib/Analysis/ValueTracking.cpp)
//   - AssumptionCache (llvm/lib/Analysis/AssumptionCache.cpp)

MAX_ANALYSIS_RECURSION_DEPTH :: 6;   // MaxAnalysisRecursionDepth

Simplify_Query :: struct {
    dt: *Dom_Tree;               // may be null
    ac: *Assumption_Cache;       // may be null
    cxt: Value_Id = NONE;        // CxtI
    use_instr_info := true;      // IIQ.UseInstrInfo
    can_use_undef := true;
    allow_ephemerals := false;
    have_tli := true;            // a TargetLibraryInfo is available (instsimplify passes one)
    no_tli_libcalls := false;    // TLI == nullptr for ConstantFoldCall: library calls are not folded (have_tli does not
                                 // imply this: several callers that clear have_tli do pass a TLI in LLVM)
    dc: *Dom_Cond_Cache;         // DomConditionCache (InstCombine); may be null
    cc: *Cond_Context;           // CondContext (InstCombine's visitSelectInst); may be null
}

// CondContext (SimplifyQuery.h): an injected condition known to be true (or false with `invert`) for the
// values in `affected`.
Cond_Context :: struct {
    cond: Value_Id;
    invert: bool;
    affected: [..] Value_Id;
}
cc_affects :: (cc: *Cond_Context, v: Value_Id) -> bool {
    for cc.affected if it == v return true;
    return false;
}

// DomConditionCache (llvm/lib/Analysis/DomConditionCache.cpp): affected value -> conditional branches whose condition
// says something about it, in registration order.
Dom_Cond_Cache :: struct {
    affected: Table(Value_Id, [..] Value_Id);
}
// DomConditionCache::registerBranch
dc_register_branch :: (dc: *Dom_Cond_Cache, br: Value_Id) {
    aff: [..] Affected; aff.allocator = temp;
    find_values_affected_by_condition(op(br, 0), false, *aff, 0);
    for aff {
        p := table_find_pointer(*dc.affected, it.v);
        if !p {
            empty: [..] Value_Id; empty.allocator = temp;
            table_set(*dc.affected, it.v, empty);
            p = table_find_pointer(*dc.affected, it.v);
        }
        dup := false;
        for x: p.* if x == br { dup = true; break; }
        if !dup array_add(p, br);
    }
}
dc_conditions_for :: (dc: *Dom_Cond_Cache, v: Value_Id) -> [] Value_Id {
    if !dc return .[];
    p := table_find_pointer(*dc.affected, v);
    if !p return .[];
    return p.*;
}
dc_remove_value :: (dc: *Dom_Cond_Cache, v: Value_Id) { if dc table_remove(*dc.affected, v); }
sq_with_instruction :: (q: Simplify_Query, i: Value_Id) -> Simplify_Query { r := q; r.cxt = i; return r; }
sq_without_undef :: (q: Simplify_Query) -> Simplify_Query { r := q; r.can_use_undef = false; return r; }
// SimplifyQuery::isUndefValue
sq_is_undef_value :: (q: Simplify_Query, v: Value_Id) -> bool {
    if !q.can_use_undef return false;
    return pm_undef(v);
}
// safeCxtI
safe_cxt :: (v: Value_Id, cxt: Value_Id) -> Value_Id {
    if cxt != NONE && vkind(cxt) == .INST && inst(cxt).parent != NONE return cxt;
    if is_inst(v) && inst(v).parent != NONE return v;
    return NONE;
}

// InstrInfoQuery: flags only count when use_instr_info
iiq_nuw :: (q: Simplify_Query, v: Value_Id) -> bool { return q.use_instr_info && (opr_flags(v) & F_NUW) != 0; }
iiq_nsw :: (q: Simplify_Query, v: Value_Id) -> bool { return q.use_instr_info && (opr_flags(v) & F_NSW) != 0; }
iiq_exact :: (q: Simplify_Query, v: Value_Id) -> bool { return q.use_instr_info && (opr_flags(v) & F_EXACT) != 0; }
iiq_disjoint :: (q: Simplify_Query, v: Value_Id) -> bool { return q.use_instr_info && (opr_flags(v) & F_EXACT) != 0; }
iiq_samesign :: (q: Simplify_Query, v: Value_Id) -> bool { return q.use_instr_info && (opr_flags(v) & F_EXACT) != 0; }
iiq_metadata :: (q: Simplify_Query, i: Value_Id, kind_name: string) -> Md_Id {
    if !q.use_instr_info return NONE;
    return inst_md(i, kind_name);
}
inst_md :: (i: Value_Id, kind_name: string) -> Md_Id {
    found, k := table_find(*ir.md_kind_map, kind_name);
    if !found return NONE;
    return get_metadata(i, k);
}

// ---------------------------------------------------------------- intrinsics

iid_cache: Table(Value_Id, Intrinsic_Id);
fn_iid :: (f: Value_Id) -> Intrinsic_Id {
    if f == NONE || vkind(f) != .FUNCTION || !glob(f).intrinsic return NOT_INTRINSIC;
    found, id := table_find(*iid_cache, f);
    if found return id;
    id = function_intrinsic_id(f);
    table_set(*iid_cache, f, id);
    return id;
}
// dyn_cast<IntrinsicInst>(V)->getIntrinsicID(), NOT_INTRINSIC if V isn't an intrinsic call
call_iid :: inline (v: Value_Id) -> Intrinsic_Id {
    if !is_inst(v) return NOT_INTRINSIC;
    o := inst_op(v);
    if o != .CALL && o != .INVOKE && o != .CALLBR return NOT_INTRINSIC;
    return fn_iid(call_called_function(v));
}
is_intrinsic_call :: (v: Value_Id, id: Intrinsic_Id) -> bool { return call_iid(v) == id; }
// IntrinsicInst::isAssumeLikeIntrinsic
is_assume_like_intrinsic :: (i: Value_Id) -> bool {
    id := call_iid(i);
    if id == {
        case IID_ASSUME; #through; case IID_SIDEEFFECT; #through; case IID_PSEUDOPROBE; #through;
        case IID_DBG_ASSIGN; #through; case IID_DBG_DECLARE; #through; case IID_DBG_VALUE; #through; case IID_DBG_LABEL; #through;
        case IID_INVARIANT_START; #through; case IID_INVARIANT_END; #through; case IID_LIFETIME_START; #through;
        case IID_LIFETIME_END; #through; case IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL; #through; case IID_OBJECTSIZE; #through;
        case IID_PTR_ANNOTATION; #through; case IID_VAR_ANNOTATION; return true;
    }
    return false;
}

// ---------------------------------------------------------------- Operator views

// Operator::getOpcode: the opcode of an instruction or constant expression, NONE_OP otherwise
opr_code :: inline (v: Value_Id) -> Opcode {
    if v == NONE return .NONE_OP;
    k := vkind(v);
    if k == .INST return inst_op(v);
    if k == .C_EXPR return cexpr(v).op;
    return .NONE_OP;
}
opr_flags :: inline (v: Value_Id) -> u32 {
    k := vkind(v);
    if k == .INST return inst(v).flags;
    if k == .C_EXPR return cexpr(v).flags;
    return 0;
}
is_const :: inline (v: Value_Id) -> bool { return is_constant_kind(vkind(v)); }
is_argument :: inline (v: Value_Id) -> bool { return vkind(v) == .ARGUMENT; }
is_global :: inline (v: Value_Id) -> bool { return is_global_value(vkind(v)); }
inst_fmf :: inline (i: Value_Id) -> u32 { return (opr_flags(i) >> FMF_SHIFT) & FMF_ALL; }
inst_pred :: inline (i: Value_Id) -> u8 { return inst(i).pred; }
inst_fn :: (i: Value_Id) -> Value_Id { return block_fn(inst_block(i)); }
// isa<OverflowingBinaryOperator>
is_overflowing_binop :: (v: Value_Id) -> bool {
    o := opr_code(v);
    return o == .ADD || o == .SUB || o == .MUL || o == .SHL;
}
// isa<PossiblyExactOperator>
is_possibly_exact_op :: (v: Value_Id) -> bool {
    o := opr_code(v);
    return o == .UDIV || o == .SDIV || o == .LSHR || o == .ASHR;
}

// ---------------------------------------------------------------- order and dominance

// Instruction::comesBefore (same block)
comes_before :: (a: Value_Id, b: Value_Id) -> bool {
    assert(inst(a).parent == inst(b).parent, "comesBefore across blocks");
    x := inst(a).next;
    while x != NONE { if x == b return true; x = inst(x).next; }
    return false;
}

// DominatorTree::dominates(const Instruction *Def, const BasicBlock *UseBB)
dt_dominates_inst_block :: (dt: *Dom_Tree, def: Value_Id, use_bb: Value_Id) -> bool {
    def_bb := inst_block(def);
    if !dt_is_reachable_from_entry(dt, use_bb) return true;
    if !dt_is_reachable_from_entry(dt, def_bb) return false;
    if def_bb == use_bb return false;
    if inst_op(def) == .INVOKE return dt_dominates_edge_block(dt, def_bb, get_successor(def, 0), use_bb);
    return dt_dominates(dt, def_bb, use_bb);
}
// DominatorTree::dominates(const BasicBlockEdge &BBE, const BasicBlock *UseBB)
dt_dominates_edge_block :: (dt: *Dom_Tree, start: Value_Id, end: Value_Id, use_bb: Value_Id) -> bool {
    if !dt_dominates(dt, end, use_bb) return false;
    if block_single_predecessor(end) != NONE return true;
    dup := 0;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(end, *preds);
    for bb: preds {
        if bb == start {
            if dup > 0 return false;
            dup += 1;
            continue;
        }
        if !dt_dominates(dt, end, bb) return false;
    }
    return true;
}
// DominatorTree::dominates(const Value *Def, const Instruction *User)
dt_dominates_inst :: (dt: *Dom_Tree, def: Value_Id, user: Value_Id) -> bool {
    if !is_inst(def) return true;
    use_bb := inst_block(user);
    def_bb := inst_block(def);
    if !dt_is_reachable_from_entry(dt, use_bb) return true;
    if !dt_is_reachable_from_entry(dt, def_bb) return false;
    if def == user return false;
    o := inst_op(def);
    if o == .INVOKE || o == .CALLBR || inst_op(user) == .PHI return dt_dominates_inst_block(dt, def, use_bb);
    if def_bb != use_bb return dt_dominates(dt, def_bb, use_bb);
    return comes_before(def, user);
}
// DominatorTree::dominates(const BasicBlockEdge &BBE, const Use &U)
dt_dominates_edge_use :: (dt: *Dom_Tree, start: Value_Id, end: Value_Id, u: Use_Id) -> bool {
    user := ir.u_user[u];
    if is_phi(user) {
        inc := ir.u_aux[u];
        if inst_block(user) == end && inc == start return true;
        return dt_dominates_edge_block(dt, start, end, inc);
    }
    return dt_dominates_edge_block(dt, start, end, inst_block(user));
}
// DominatorTree::dominates(const Value *Def, const Use &U)
dt_dominates_use :: (dt: *Dom_Tree, def: Value_Id, u: Use_Id) -> bool {
    if !is_inst(def) return true;
    user := ir.u_user[u];
    def_bb := inst_block(def);
    use_bb := ifx is_phi(user) then ir.u_aux[u] else inst_block(user);
    if !dt_is_reachable_from_entry(dt, use_bb) return true;
    if !dt_is_reachable_from_entry(dt, def_bb) return false;
    if inst_op(def) == .INVOKE return dt_dominates_edge_use(dt, def_bb, get_successor(def, 0), u);
    if def_bb != use_bb return dt_dominates(dt, def_bb, use_bb);
    if is_phi(user) return true;
    return comes_before(def, user);
}

// isGuaranteedToTransferExecutionToSuccessor(const Instruction *)
is_guaranteed_to_transfer_execution :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .RET || o == .UNREACHABLE return false;
    if o == .CATCHPAD return classify_eh_personality(fn_personality(inst_fn(i))) == .CORECLR;
    return !may_throw(i) && will_return(i);
}
// the [begin, end) range version with a scan limit
is_guaranteed_to_transfer_execution_range :: (begin: Value_Id, end: Value_Id, scan_limit_in: u32) -> bool {
    scan_limit := scan_limit_in;
    x := begin;
    while x != end && x != NONE {
        scan_limit -= 1;
        if scan_limit == 0 return false;
        if !is_guaranteed_to_transfer_execution(x) return false;
        x = inst(x).next;
    }
    return true;
}
is_guaranteed_to_transfer_execution_block :: (bb: Value_Id) -> bool {
    for block_insts(bb) if !is_guaranteed_to_transfer_execution(it) return false;
    return true;
}

// ---------------------------------------------------------------- AssumptionCache

AC_EXPR_RESULT_IDX :: 0xFFFF_FFFF;   // AssumptionCache::ExprResultIdx
Ac_Elem :: struct { assume: Value_Id; index: u32; }
Assumption_Cache :: struct {
    fn: Value_Id;
    scanned: bool;                                // Scanned: scanFunction runs on the first query (lazily)
    assumes: [..] Value_Id;                       // AssumeHandles (DEAD rows are null handles)
    affected: Table(Value_Id, [..] Ac_Elem);      // AffectedValues
}

// AssumptionAnalysis::run: the cache is empty until its first query scans the function (scanFunction), so
// assumes a pass inserts before that query are found by the scan, in function order.
ac_build :: (f: Value_Id) -> *Assumption_Cache {
    ac := New(Assumption_Cache);
    ac.fn = f;
    return ac;
}
// scanFunction
ac_scan :: (ac: *Assumption_Cache) {
    if ac.scanned return;
    ac.scanned = true;
    for fn_insts(ac.fn) if is_intrinsic_call(it, IID_ASSUME) array_add(*ac.assumes, it);
    for ac.assumes ac_update_affected_values(ac, it);
}
// assumptions(): AssumeHandles, scanning first
ac_assumptions :: (ac: *Assumption_Cache) -> *[..] Value_Id {
    ac_scan(ac);
    return *ac.assumes;
}
ac_free :: (ac: *Assumption_Cache) {
    for * ac.affected array_free(it.*);
    deinit(*ac.affected);
    array_free(ac.assumes);
    free(ac);
}
ac_assumptions_for :: (ac: *Assumption_Cache, v: Value_Id) -> [] Ac_Elem {
    ac_scan(ac);
    p := table_find_pointer(*ac.affected, v);
    if !p return .[];
    return p.*;
}
ac_get_or_insert :: (ac: *Assumption_Cache, v: Value_Id) -> *[..] Ac_Elem {
    p := table_find_pointer(*ac.affected, v);
    if p return p;
    empty: [..] Ac_Elem;
    table_set(*ac.affected, v, empty);
    return table_find_pointer(*ac.affected, v);
}
Affected :: struct { v: Value_Id; index: u32; }
ac_find_affected_values :: (ci: Value_Id, out: *[..] Affected) {
    // operand bundles
    nb := call_num_bundles(ci);
    if nb > 0 for k: 0..nb-1 {
        tag := call_bundle_tag(ci, k);
        begin := ir.u32_pool[inst(ci).idx + 3 * k + 1];
        end := ir.u32_pool[inst(ci).idx + 3 * k + 2];
        add :: (out: *[..] Affected, v: Value_Id, idx: u32) {
            k := vkind(v);
            if k == .ARGUMENT || is_global_value(k) || k == .INST array_add(out, .{v, idx});
        }
        if tag == "separate_storage" {
            add(out, get_underlying_object(op(ci, begin)), k);
            add(out, get_underlying_object(op(ci, begin + 1)), k);
        } else if end - begin > 0 && tag != "ignore" {   // ABA_WasOn = 0
            add(out, op(ci, begin), k);
        }
    }
    cond := op(ci, 0);
    find_values_affected_by_condition(cond, true, out, AC_EXPR_RESULT_IDX);
    // TTI->getPredicatedAddrSpace: none on x86
}
ac_update_affected_values :: (ac: *Assumption_Cache, ci: Value_Id) {
    aff: [..] Affected; aff.allocator = temp;
    ac_find_affected_values(ci, *aff);
    for aff {
        avv := ac_get_or_insert(ac, it.v);
        dup := false;
        for e: avv.* if e.assume == ci && e.index == it.index { dup = true; break; }
        if !dup array_add(avv, .{ci, it.index});
    }
}
// AffectedValueCallbackVH::allUsesReplacedWith -> transferAffectedValuesInCache
ac_transfer :: (ac: *Assumption_Cache, old: Value_Id, new: Value_Id) {
    if !ac.scanned return;
    nk := vkind(new);
    if nk != .INST && nk != .ARGUMENT return;
    p := table_find_pointer(*ac.affected, old);
    if !p return;
    olds := p.*;
    nav := ac_get_or_insert(ac, new);
    for a: olds {
        has := false;
        for nav.* if it.assume == a.assume && it.index == a.index { has = true; break; }
        if !has array_add(nav, a);
    }
    table_remove(*ac.affected, old);
}

// addValueAffectedByCondition / findValuesAffectedByCondition (llvm/lib/Analysis/ValueTracking.cpp)
find_values_affected_by_condition :: (cond: Value_Id, is_assume: bool, out: *[..] Affected, idx: u32) {
    add_affected :: (v: Value_Id, out: *[..] Affected, idx: u32) {
        k := vkind(v);
        if k == .ARGUMENT || is_global_value(k) {
            array_add(out, .{v, idx});
        } else if k == .INST {
            array_add(out, .{v, idx});
            o := inst_op(v);
            if o == .PTRTOINT || o == .PTRTOADDR || o == .TRUNC {
                x := op(v, 0);
                if is_inst(x) || is_argument(x) array_add(out, .{x, idx});
            }
        }
    }
    add_cmp_operands :: (l: Value_Id, r: Value_Id, is_assume: bool, out: *[..] Affected, idx: u32) {
        if is_assume { add_affected(l, out, idx); add_affected(r, out, idx); }
        else if is_const(r) add_affected(l, out, idx);
    }
    worklist: [..] Value_Id; worklist.allocator = temp;
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*worklist, cond);
    while worklist.count {
        v := pop(*worklist);
        seen := false;
        for visited if it == v { seen = true; break; }
        if seen continue;
        array_add(*visited, v);
        if is_assume {
            add_affected(v, out, idx);
            okn, x := pm_not(v);
            if okn add_affected(x, out, idx);
        }
        okl, la, lb := pm_logical_op(v);
        if okl {
            if !is_assume { array_add(*worklist, la); array_add(*worklist, lb); }
        } else if is_inst(v) && inst_op(v) == .ICMP {
            pred := inst_pred(v);
            a := op(v, 0); b := op(v, 1);
            has_rhsc := pm_constant_int(b);
            if icmp_is_equality(pred) {
                add_affected(a, out, idx);
                if is_assume add_affected(b, out, idx);
                if has_rhsc {
                    ao := opr_code(a);
                    if (ao == .SHL || ao == .LSHR || ao == .ASHR) && pm_constant_int(op(a, 1)) add_affected(op(a, 0), out, idx);
                    else if ao == .AND || ao == .OR || ao == .SUB { add_affected(op(a, 0), out, idx); add_affected(op(a, 1), out, idx); }
                }
            } else {
                add_cmp_operands(a, b, is_assume, out, idx);
                if has_rhsc {
                    ok_add, x, c := pm_add_like(a);
                    if ok_add && pm_constant_int(c) add_affected(x, out, idx);
                    if icmp_is_unsigned(pred) {
                        ao := opr_code(a);
                        if ao == .AND || ao == .OR || (ao == .ADD && (opr_flags(a) & F_NUW) != 0) {
                            add_affected(op(a, 0), out, idx); add_affected(op(a, 1), out, idx);
                        }
                        if ao == .SUB && (opr_flags(a) & F_NUW) != 0 add_affected(op(a, 0), out, idx);
                    }
                }
                okb, x := pm_elementwise_bitcast(a);
                if okb {
                    if pred == ICMP_SLT && pm_zero(b) array_add(out, .{x, idx});
                    else if pred == ICMP_SGT && pm_all_ones(b) array_add(out, .{x, idx});
                }
            }
            if has_rhsc && call_iid(a) == IID_CTPOP add_affected(op(a, 0), out, idx);
        } else if is_inst(v) && inst_op(v) == .FCMP {
            a := op(v, 0); b := op(v, 1);
            add_cmp_operands(a, b, is_assume, out, idx);
            okn, na := pm_fneg(a);
            if okn { a = na; add_affected(a, out, idx); }
            if call_iid(a) == IID_FABS { a = op(a, 0); add_affected(a, out, idx); }
        } else if call_iid(v) == IID_IS_FPCLASS {
            add_affected(op(v, 0), out, idx);
        } else if !is_assume && opr_code(v) == .TRUNC {
            add_affected(op(v, 0), out, idx);
        } else if !is_assume {
            okn, x := pm_not(v);
            if okn array_add(*worklist, x);
        }
    }
}

// The function's AssumptionCache: fam-cached (AssumptionAnalysis); see passes.jai get_assumption_cache.
// replace_all_uses_with calls this so cached caches follow RAUW like the callback handles do.
ac_note_rauw :: (old: Value_Id, new: Value_Id) {
    k := vkind(old);
    if k != .INST && k != .ARGUMENT return;
    f := value_function(old);
    if f == NONE return;
    ac := cached_assumption_cache(f);
    if ac ac_transfer(ac, old, new);
}

// ---------------------------------------------------------------- attributes of arguments and calls

arg_no :: inline (a: Value_Id) -> u32 { return arg_numbers[ir.v_aux[a]]; }
arg_attrs :: (a: Value_Id) -> u32 { return attr_list_param(glob(arg_parent(a)).attrs, arg_no(a)); }
arg_has_attr :: (a: Value_Id, k: Attr_Kind) -> bool { return attr_set_has(arg_attrs(a), k); }
fn_has_fn_attr :: (f: Value_Id, k: Attr_Kind) -> bool { return attr_set_has(attr_list_fn(glob(f).attrs), k); }
fn_get_fn_attr :: (f: Value_Id, k: Attr_Kind) -> *Attr { return attr_set_find(attr_list_fn(glob(f).attrs), k); }
// Argument::getRange
arg_range :: (a: Value_Id) -> (bool, Const_Range) {
    at := attr_set_find(arg_attrs(a), .Range);
    if !at { r: Const_Range; return false, r; }
    return true, attr_range(at);
}
attr_range :: (at: *Attr) -> Const_Range {
    bits := cast(u32) at.ival;
    return cr_new(ap_from_words(bits, at.lo), ap_from_words(bits, at.hi));
}
// CallBase::getRetAttr (call site, then the called function)
call_ret_attr :: (c: Value_Id, k: Attr_Kind) -> *Attr {
    a := attr_set_find(attr_list_ret(inst(c).attrs), k);
    if a return a;
    f := call_called_function(c);
    if f != NONE return attr_set_find(attr_list_ret(glob(f).attrs), k);
    return null;
}
call_has_ret_attr :: (c: Value_Id, k: Attr_Kind) -> bool { return call_ret_attr(c, k) != null; }
// CallBase::paramHasAttr (call site, then the called function; mod/ref kinds aren't queried here)
call_param_attr :: (c: Value_Id, argno: u32, k: Attr_Kind) -> *Attr {
    a := attr_set_find(attr_list_param(inst(c).attrs, argno), k);
    if a return a;
    f := call_called_function(c);
    if f != NONE return attr_set_find(attr_list_param(glob(f).attrs, argno), k);
    return null;
}
call_param_has_attr :: (c: Value_Id, argno: u32, k: Attr_Kind) -> bool { return call_param_attr(c, argno, k) != null; }
// CallBase::getRange: the call-site range intersected with the callee's
call_range :: (c: Value_Id) -> (bool, Const_Range) {
    ca := attr_set_find(attr_list_ret(inst(c).attrs), .Range);
    fa: *Attr;
    f := call_called_function(c);
    if f != NONE fa = attr_set_find(attr_list_ret(glob(f).attrs), .Range);
    if ca && fa return true, cr_intersect(attr_range(ca), attr_range(fa));
    if ca return true, attr_range(ca);
    if fa return true, attr_range(fa);
    r: Const_Range;
    return false, r;
}
// CallBase::getReturnedArgOperand
call_returned_arg :: (c: Value_Id) -> Value_Id {
    n := call_num_args(c);
    l := inst(c).attrs;
    if n > 0 for i: 0..n-1 if attr_set_has(attr_list_param(l, i), .Returned) return op(c, i);
    f := call_called_function(c);
    if f != NONE {
        fl := glob(f).attrs;
        if n > 0 for i: 0..n-1 if attr_set_has(attr_list_param(fl, i), .Returned) return op(c, i);
    }
    return NONE;
}
// NullPointerIsDefined(F, AS)
null_pointer_is_defined :: (f: Value_Id, as: u64 = 0) -> bool {
    if f != NONE && fn_has_fn_attr(f, .NullPointerIsValid) return true;
    return as != 0;
}
// CallBase::isReturnNonNull
call_is_return_non_null :: (c: Value_Id) -> bool {
    if call_has_ret_attr(c, .NonNull) return true;
    d := call_ret_attr(c, .Dereferenceable);
    if d && d.ival > 0 && !null_pointer_is_defined(inst_fn(c), ir.types[vtype(c)].a) return true;
    return false;
}
// Argument::hasNonNullAttr(AllowUndefOrPoison = true)
arg_has_nonnull_attr :: (a: Value_Id, allow_undef_or_poison := true) -> bool {
    if !is_ptr_type(vtype(a)) return false;
    s := arg_attrs(a);
    if attr_set_has(s, .NonNull) && (allow_undef_or_poison || attr_set_has(s, .NoUndef)) return true;
    d := attr_set_find(s, .Dereferenceable);
    if d && d.ival > 0 && !null_pointer_is_defined(arg_parent(a), ir.types[vtype(a)].a) return true;
    return false;
}
// Argument::hasPassPointeeByValueCopyAttr
arg_has_pass_pointee_by_value_copy :: (a: Value_Id) -> bool {
    if !is_ptr_type(vtype(a)) return false;
    s := arg_attrs(a);
    return attr_set_has(s, .ByVal) || attr_set_has(s, .InAlloca) || attr_set_has(s, .Preallocated);
}
