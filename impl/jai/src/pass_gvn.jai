// GVN: port of llvm/lib/Transforms/Scalar/GVN.cpp and llvm/include/llvm/Transforms/Scalar/GVN.h (GVNPass with
// GVNOptions / gvn<...>, ValueTable (createExpr, createCmpExpr, createExtractvalueExpr, createGEPExpr,
// lookupOrAddCall, computeLoadStoreVN, addMemoryStateToExp, lookupOrAdd, lookupOrAddCmp, lookupPtrToInt,
// assignExpNewValueNum, phiTranslate / phiTranslateImpl, areCallValsEqual, areAllValsInBB, eraseTranslateCacheEntry),
// LeaderMap, AvailableValue / AvailableValueInBlock + MaterializeAdjustedValue, IsValueFullyAvailableInBlock,
// ConstructSSAForLoadSet, findDominatingValue, AnalyzeSelectAvailability, AnalyzeLoadAvailability (both),
// findLoadToHoistIntoPred, eliminatePartiallyRedundantLoad, PerformLoadPRE, performLoopLoadPRE,
// processNonLocalLoad (both), processAssumeIntrinsic, findInvariantGroupValue, maybeLoadStoreLocation, the
// MemorySSA-based scanMemoryAccessesUsers / accessMayModifyLocation / collectPredecessors / collectClobberList /
// findReachingValuesForLoad, processLoad, processMaskedLoad, findLeader, propagateEquality, processInstruction,
// runImpl, processBlock, performScalarPREInsertion, performScalarPRE, performPRE, splitCriticalEdges,
// iterateOnFunction, addDeadBlock, processFoldableCondBr, assignValNumForDeadCode), of
// llvm/lib/Analysis/InstructionPrecedenceTracking.cpp's removeUsersOf, and of Local.cpp's
// patchReplacementInstruction / replaceDominatedUsesWith(If) and Loads.cpp's canReplacePointersInUseIfEqual.
// Uses memdep.jai (MemoryDependenceAnalysis), phi_trans_addr.jai, vn_coercion.jai, ssa_updater.jai,
// mssa_updater.jai, must_execute.jai (ImplicitControlFlowTracking).
//
// Optimization remarks are not ported (never printed without -pass-remarks). salvageKnowledge only acts with
// --enable-knowledge-retention (not supported, fails at the command line).

IID_FAKE_USE :: #run iid_by_name("llvm.fake.use");
IID_GC_RELOCATE :: #run iid_by_name("llvm.experimental.gc.relocate");

gvn_opts: struct {
    enable_scalar_pre := true;           // -enable-scalar-pre
    enable_load_pre := true;             // -enable-load-pre
    enable_load_in_loop_pre := true;     // -enable-load-in-loop-pre
    enable_split_backedge_in_load_pre := false;   // -enable-split-backedge-in-load-pre
    enable_memdep := true;               // -enable-gvn-memdep
    enable_memoryssa := false;           // -enable-gvn-memoryssa
    scan_users_limit: s64 = 100;         // -gvn-scan-users-limit
    max_num_deps: s64 = 100;             // -gvn-max-num-deps
    max_bb_speculations: s64 = 600;      // -gvn-max-block-speculations
    max_num_visited_insts: s64 = 100;    // -gvn-max-num-visited-insts
    max_num_insns_per_block: s64 = 100;  // -gvn-max-num-insns
};
GVN_CL_OPT_COUNT :: 18;
add_gvn_cl_opts :: (list: [] Cl_Opt, start: s64) {
    o := *gvn_opts;
    list[start + 0] = .{"enable-scalar-pre", .BOOL, *o.enable_scalar_pre, null, null};
    list[start + 1] = .{"enable-load-pre", .BOOL, *o.enable_load_pre, null, null};
    list[start + 2] = .{"enable-load-in-loop-pre", .BOOL, *o.enable_load_in_loop_pre, null, null};
    list[start + 3] = .{"enable-split-backedge-in-load-pre", .BOOL, *o.enable_split_backedge_in_load_pre, null, null};
    list[start + 4] = .{"enable-gvn-memdep", .BOOL, *o.enable_memdep, null, null};
    list[start + 5] = .{"enable-gvn-memoryssa", .BOOL, *o.enable_memoryssa, null, null};
    list[start + 6] = .{"gvn-scan-users-limit", .INT, null, *o.scan_users_limit, null};
    list[start + 7] = .{"gvn-max-num-deps", .INT, null, *o.max_num_deps, null};
    list[start + 8] = .{"gvn-max-block-speculations", .INT, null, *o.max_bb_speculations, null};
    list[start + 9] = .{"gvn-max-num-visited-insts", .INT, null, *o.max_num_visited_insts, null};
    list[start + 10] = .{"gvn-max-num-insns", .INT, null, *o.max_num_insns_per_block, null};
    list[start + 11] = .{"gvn-add-phi-translation", .BOOL, *pta_opts.enable_add_phi_translation, null, null};
    list[start + 12] = .{"memdep-block-scan-limit", .INT, null, *md_opts.block_scan_limit, null};
    list[start + 13] = .{"memdep-block-number-limit", .INT, null, *md_opts.block_number_limit, null};
    list[start + 14] = .{"memdep-cache-global-limit", .INT, null, *md_opts.cache_global_limit, null};
    // AliasAnalysis.cpp -disable-basic-aa only affects the legacy AAResultsWrapperPass (opt's new pass manager
    // ignores it); -verify-analysis-invalidation only checks
    list[start + 15] = .{"disable-basic-aa", .IGNORED, null, null, null};
    list[start + 16] = .{"verify-analysis-invalidation", .IGNORED, null, null, null};
    list[start + 17] = .{"capture-tracking-max-uses-to-explore", .INT, null, *capture_tracking_max_uses, null};
}

// ---------------------------------------------------------------- Expression / ValueTable

Gvn_Expr :: struct {
    opcode: u32 = 0xFFFF_FFFD;   // ~2U
    commutative: bool;
    ty: Type_Id = NONE;
    varargs: [..] u32;
    attrs: u32;
}
gvn_expr_new :: (opcode: u32 = 0xFFFF_FFFD) -> Gvn_Expr {
    e: Gvn_Expr; e.opcode = opcode; e.varargs.allocator = temp;
    return e;
}
gvn_expr_copy :: (s: Gvn_Expr) -> Gvn_Expr {
    e: Gvn_Expr;
    e.opcode = s.opcode; e.commutative = s.commutative; e.ty = s.ty; e.attrs = s.attrs;
    e.varargs.allocator = temp;
    for s.varargs array_add(*e.varargs, it);
    return e;
}
GVN_CMP_OPC :: (op: Opcode, pred: u8) -> u32 { return ((cast(u32) op) << 8) | cast(u32) pred; }

// ExpressionNumbering: the DenseMap's equality also intersects call attributes, so entries with the same
// (opcode, type, varargs) are chained in insertion order and the first compatible one wins (DenseMap's probe
// sequence meets equal-hash keys in insertion order: the map is never erased from).
Gvn_Expr_Entry :: struct { attrs: u32; value: u32; next: s64 = -1; }

Gvn_Vt :: struct {
    value_numbering: Table(Value_Id, u32);
    expr_heads: Table(string, s64);
    expr_entries: [..] Gvn_Expr_Entry;
    next_expr_number: u32;
    expressions: [..] Gvn_Expr;
    expr_idx: [..] u32;
    numbering_phi: Table(u32, Value_Id);
    numbering_bb: Table(u32, Value_Id);
    phi_translate_table: Table(u64, u32);
    next_value_number: u32 = 1;
}

Gvn_Leader_Node :: struct { val: Value_Id; bb: Value_Id; next: s64 = -1; }

Gvn_Dep_Kind :: enum u8 { OTHER; DEF; CLOBBER; SELECT; }
// ReachingMemVal
Gvn_Mem_Val :: struct {
    kind: Gvn_Dep_Kind;
    block: Value_Id = NONE;
    addr: Value_Id = NONE;
    inst: Value_Id = NONE;
    offset: s32 = -1;
    sel_cond: Value_Id = NONE;
    sel_t: Value_Id = NONE;
    sel_f: Value_Id = NONE;
}
rmv_unknown :: (bb: Value_Id, addr: Value_Id, i: Value_Id = NONE) -> Gvn_Mem_Val { r: Gvn_Mem_Val; r.kind = .OTHER; r.block = bb; r.addr = addr; r.inst = i; return r; }
rmv_def :: (addr: Value_Id, i: Value_Id) -> Gvn_Mem_Val { r: Gvn_Mem_Val; r.kind = .DEF; r.block = inst_block(i); r.addr = addr; r.inst = i; return r; }
rmv_clobber :: (addr: Value_Id, i: Value_Id, off: s32 = -1) -> Gvn_Mem_Val { r: Gvn_Mem_Val; r.kind = .CLOBBER; r.block = inst_block(i); r.addr = addr; r.inst = i; r.offset = off; return r; }
rmv_select :: (bb: Value_Id, c: Value_Id, t: Value_Id, f: Value_Id) -> Gvn_Mem_Val { r: Gvn_Mem_Val; r.kind = .SELECT; r.block = bb; r.sel_cond = c; r.sel_t = t; r.sel_f = f; return r; }

// AvailableValue
Av_Kind :: enum u8 { SIMPLE; LOAD; MEM_INTRIN; UNDEF; SELECT; }
Gvn_Av :: struct { val: Value_Id = NONE; kind: Av_Kind; offset: u32; v1: Value_Id = NONE; v2: Value_Id = NONE; }
av_simple :: (v: Value_Id, off: u32 = 0) -> Gvn_Av { a: Gvn_Av; a.val = v; a.kind = .SIMPLE; a.offset = off; return a; }
av_mi :: (v: Value_Id, off: u32 = 0) -> Gvn_Av { a: Gvn_Av; a.val = v; a.kind = .MEM_INTRIN; a.offset = off; return a; }
av_load :: (v: Value_Id, off: u32 = 0) -> Gvn_Av { a: Gvn_Av; a.val = v; a.kind = .LOAD; a.offset = off; return a; }
av_undef :: () -> Gvn_Av { a: Gvn_Av; a.kind = .UNDEF; return a; }
av_select :: (c: Value_Id, v1: Value_Id, v2: Value_Id) -> Gvn_Av { a: Gvn_Av; a.val = c; a.kind = .SELECT; a.v1 = v1; a.v2 = v2; return a; }
// AvailableValueInBlock
Gvn_Avb :: struct { bb: Value_Id; av: Gvn_Av; }

Gvn :: struct {
    f: Value_Id;
    // GVNOptions (-1 = unset)
    allow_scalar_pre: s8 = -1;
    allow_load_pre: s8 = -1;
    allow_load_in_loop_pre: s8 = -1;
    allow_load_pre_split_backedge: s8 = -1;
    allow_memdep: s8 = -1;
    allow_memoryssa: s8 = -1;

    md: *Mem_Dep_Results;
    dt: *Dom_Tree;
    ac: *Assumption_Cache;
    aar: Aa_Results;
    li: *Loop_Info;
    mssa: *Memory_SSA;
    mssau_storage: Mssa_Updater;
    mssau: *Mssa_Updater;
    icf: Instruction_Precedence_Tracking;
    dead_blocks: [..] Value_Id;            // SetVector
    dead_set: Table(Value_Id, bool);
    vn: Gvn_Vt;
    vn_md_enabled: bool;
    vn_mssa_enabled: bool;
    leader_heads: Table(u32, s64);
    leader_nodes: [..] Gvn_Leader_Node;
    block_rpo: Table(Value_Id, u32);
    invalid_block_rpo := true;
    to_split: [..] Split_Edge;
}
Split_Edge :: struct { term: Value_Id; succ: u32; }

gvn_is_scalar_pre_enabled :: (g: *Gvn) -> bool { if g.allow_scalar_pre >= 0 return g.allow_scalar_pre == 1; return gvn_opts.enable_scalar_pre; }
gvn_is_load_pre_enabled :: (g: *Gvn) -> bool { if g.allow_load_pre >= 0 return g.allow_load_pre == 1; return gvn_opts.enable_load_pre; }
gvn_is_load_in_loop_pre_enabled :: (g: *Gvn) -> bool { if g.allow_load_in_loop_pre >= 0 return g.allow_load_in_loop_pre == 1; return gvn_opts.enable_load_in_loop_pre; }
gvn_is_load_pre_split_backedge_enabled :: (g: *Gvn) -> bool { if g.allow_load_pre_split_backedge >= 0 return g.allow_load_pre_split_backedge == 1; return gvn_opts.enable_split_backedge_in_load_pre; }
gvn_is_memdep_enabled :: (g: *Gvn) -> bool { if g.allow_memdep >= 0 return g.allow_memdep == 1; return gvn_opts.enable_memdep; }
gvn_is_memoryssa_enabled :: (g: *Gvn) -> bool { if g.allow_memoryssa >= 0 return g.allow_memoryssa == 1; return gvn_opts.enable_memoryssa; }

gvn_is_in_dead :: inline (g: *Gvn, bb: Value_Id) -> bool { return table_contains(*g.dead_set, bb); }
gvn_add_dead :: (g: *Gvn, bb: Value_Id) {
    if table_contains(*g.dead_set, bb) return;
    table_add(*g.dead_set, bb, true);
    array_add(*g.dead_blocks, bb);
}

gvn_aaq :: inline (g: *Gvn) -> *Aa_Query { return aa_query_new(*g.aar); }

// ---- key of an expression for the hash table (opcode, type, varargs)
gvn_expr_key :: (e: *Gvn_Expr) -> string {
    n := 8 + 4 * e.varargs.count;
    s := alloc_string(n,, allocator = temp);
    p := cast(*u32) s.data;
    p[0] = e.opcode; p[1] = e.ty;
    for e.varargs p[2 + it_index] = it;
    return s;
}
// ExpressionNumbering.find / operator[]: index of the entry, or -1 (insert = false) / a new 0-valued entry
gvn_expr_lookup :: (vt: *Gvn_Vt, e: *Gvn_Expr, insert: bool) -> s64 {
    key := gvn_expr_key(e);
    found, head := table_find(*vt.expr_heads, key);
    last: s64 = -1;
    if found {
        k := head;
        while k >= 0 {
            x := *vt.expr_entries[k];
            ok := true;
            if x.attrs != 0 || e.attrs != 0 { ok2, _ := attr_list_intersect(x.attrs, e.attrs); ok = ok2; }
            if ok return k;
            last = k;
            k = x.next;
        }
    }
    if !insert return -1;
    idx := vt.expr_entries.count;
    ne: Gvn_Expr_Entry; ne.attrs = e.attrs; ne.value = 0;
    array_add(*vt.expr_entries, ne);
    if last >= 0 vt.expr_entries[last].next = idx;
    else table_add(*vt.expr_heads, key, idx);
    return idx;
}

// assignExpNewValueNum
gvn_assign_exp_new_value_num :: (vt: *Gvn_Vt, e: *Gvn_Expr) -> (u32, bool) {
    k := gvn_expr_lookup(vt, e, true);
    if vt.expr_entries[k].value == 0 {
        array_add(*vt.expressions, gvn_expr_copy(e.*));
        if vt.expr_idx.count < vt.next_value_number + 1 {
            old := vt.expr_idx.count;
            array_resize(*vt.expr_idx, vt.next_value_number * 2);
            for j: old..vt.expr_idx.count-1 vt.expr_idx[j] = 0;
        }
        vt.expr_entries[k].value = vt.next_value_number;
        vt.expr_idx[vt.next_value_number] = vt.next_expr_number;
        vt.next_value_number += 1;
        vt.next_expr_number += 1;
        return vt.expr_entries[k].value, true;
    }
    return vt.expr_entries[k].value, false;
}

gvn_vn_set :: inline (vt: *Gvn_Vt, v: Value_Id, n: u32) { table_set(*vt.value_numbering, v, n); }
gvn_vn_fresh :: (vt: *Gvn_Vt, v: Value_Id) -> u32 {
    n := vt.next_value_number;
    gvn_vn_set(vt, v, n);
    vt.next_value_number += 1;
    return n;
}

// createExpr
gvn_create_expr :: (g: *Gvn, i: Value_Id) -> Gvn_Expr {
    e := gvn_expr_new();
    e.ty = vtype(i);
    e.opcode = cast(u32) inst_op(i);
    if call_iid(i) == IID_GC_RELOCATE {
        // gc.relocate: the statepoint token, then the base and derived pointers it refers to
        array_add(*e.varargs, gvn_lookup_or_add(g, op(i, 0)));
        array_add(*e.varargs, gvn_lookup_or_add(g, gc_relocate_ptr(i, 1)));
        array_add(*e.varargs, gvn_lookup_or_add(g, gc_relocate_ptr(i, 2)));
    } else {
        for k: 0..cast(s64) nops(i) - 1 array_add(*e.varargs, gvn_lookup_or_add(g, op(i, cast(u32) k)));
    }
    if inst_is_commutative(i) {
        if e.varargs[0] > e.varargs[1] { t := e.varargs[0]; e.varargs[0] = e.varargs[1]; e.varargs[1] = t; }
        e.commutative = true;
    }
    o := inst_op(i);
    if o == .ICMP || o == .FCMP {
        pred := inst(i).pred;
        if e.varargs[0] > e.varargs[1] {
            t := e.varargs[0]; e.varargs[0] = e.varargs[1]; e.varargs[1] = t;
            pred = swapped_predicate(pred);
        }
        e.opcode = GVN_CMP_OPC(o, pred);
        e.commutative = true;
    } else if o == .INSERTVALUE {
        for inst_indices(i) array_add(*e.varargs, it);
    } else if o == .SHUFFLEVECTOR {
        for shuffle_mask(i) array_add(*e.varargs, it);
    } else if is_call_base(i) {
        e.attrs = inst(i).attrs;
    }
    return e;
}
// gc_relocate_ptr (GCRelocateInst::getBasePtr / getDerivedPtr) is in printer.jai
// createCmpExpr
gvn_create_cmp_expr :: (g: *Gvn, opc: Opcode, pred_in: u8, lhs: Value_Id, rhs: Value_Id) -> Gvn_Expr {
    e := gvn_expr_new();
    e.ty = cmp_result_type(vtype(lhs));
    array_add(*e.varargs, gvn_lookup_or_add(g, lhs));
    array_add(*e.varargs, gvn_lookup_or_add(g, rhs));
    pred := pred_in;
    if e.varargs[0] > e.varargs[1] {
        t := e.varargs[0]; e.varargs[0] = e.varargs[1]; e.varargs[1] = t;
        pred = swapped_predicate(pred);
    }
    e.opcode = GVN_CMP_OPC(opc, pred);
    e.commutative = true;
    return e;
}
// CmpInst::makeCmpResultType
cmp_result_type :: (t: Type_Id) -> Type_Id {
    if is_vector_type(t) return vector_with_elt(t, ir.t_i1);
    return ir.t_i1;
}
// WithOverflowInst::getBinaryOp
with_overflow_binary_op :: (i: Value_Id) -> Opcode {
    id := call_iid(i);
    if id == IID_SADD_WITH_OVERFLOW || id == IID_UADD_WITH_OVERFLOW return .ADD;
    if id == IID_SSUB_WITH_OVERFLOW || id == IID_USUB_WITH_OVERFLOW return .SUB;
    return .MUL;
}
// createExtractvalueExpr
gvn_create_extractvalue_expr :: (g: *Gvn, ei: Value_Id) -> Gvn_Expr {
    e := gvn_expr_new();
    e.ty = vtype(ei);
    e.opcode = 0;
    agg := op(ei, 0);
    idxs := inst_indices(ei);
    if is_inst(agg) && is_with_overflow_inst(agg) && idxs.count == 1 && idxs[0] == 0 {
        e.opcode = cast(u32) with_overflow_binary_op(agg);
        array_add(*e.varargs, gvn_lookup_or_add(g, call_arg(agg, 0)));
        array_add(*e.varargs, gvn_lookup_or_add(g, call_arg(agg, 1)));
        return e;
    }
    e.opcode = cast(u32) Opcode.EXTRACTVALUE;
    for k: 0..cast(s64) nops(ei) - 1 array_add(*e.varargs, gvn_lookup_or_add(g, op(ei, cast(u32) k)));
    for inst_indices(ei) array_add(*e.varargs, it);
    return e;
}
// createGEPExpr
gvn_create_gep_expr :: (g: *Gvn, gep: Value_Id) -> Gvn_Expr {
    e := gvn_expr_new();
    pty := scalar_type(vtype(gep));
    bw := dl_index_type_size_bits(pty);
    ok, vars, const_off := gvn_gep_collect_offset(gep, bw);
    if ok {
        e.opcode = cast(u32) Opcode.GEP;
        e.ty = NONE;
        array_add(*e.varargs, gvn_lookup_or_add(g, op(gep, 0)));
        for vars {
            array_add(*e.varargs, gvn_lookup_or_add(g, it.v));
            array_add(*e.varargs, gvn_lookup_or_add(g, const_int_ap(type_int(it.scale.bits), it.scale)));
        }
        if !ap_is_zero(const_off) array_add(*e.varargs, gvn_lookup_or_add(g, const_int_ap(type_int(const_off.bits), const_off)));
    } else {
        e.opcode = cast(u32) Opcode.GEP;
        e.ty = inst(gep).ty2;
        for k: 0..cast(s64) nops(gep) - 1 array_add(*e.varargs, gvn_lookup_or_add(g, op(gep, cast(u32) k)));
    }
    return e;
}

// GEPOperator::collectOffset (llvm/lib/IR/Operator.cpp): only scalar ConstantInts are constant offsets
gvn_gep_collect_offset :: (gep: Value_Id, bw: u32) -> (bool, [..] Gep_Var_Offset, APInt) {
    vars: [..] Gep_Var_Offset; vars.allocator = temp;
    const_off := ap_zero(bw);
    cur := inst(gep).ty2;
    for k: 1..cast(s64) nops(gep) - 1 {
        idx := op(gep, cast(u32) k);
        container := cur;
        sty: Type_Id = NONE;
        indexed: Type_Id;
        if k == 1 indexed = cur;
        else if type_kind(cur) == .STRUCT { sty = cur; indexed = NONE; }
        else indexed = type_elem(cur);
        if sty != NONE {
            if vkind(idx) != .C_INT || is_vector_type(vtype(idx)) return false, vars, const_off;
            fi := cast(u32) const_int_zext(idx);
            indexed = type_sub(sty, fi);
        }
        scalable := type_is_scalable(indexed);
        is_ci := vkind(idx) == .C_INT && !is_vector_type(vtype(idx));
        stride: u64 = 0;
        if sty == NONE stride = gep_seq_stride(container, k, indexed);
        if is_ci {
            cur = indexed;
            if is_null_value(idx) continue;
            if scalable return false, vars, const_off;
            if sty != NONE {
                const_off = ap_add(const_off, ap_from_u64(bw, dl_struct_offset(sty, cast(u32) const_int_zext(idx))));
                continue;
            }
            iv := ap_sext_or_trunc(const_ap(idx), bw);
            const_off = ap_add(const_off, ap_mul(iv, ap_from_u64(bw, stride)));
            continue;
        }
        if sty != NONE || scalable return false, vars, const_off;
        cur = indexed;
        size := ap_from_u64(bw, stride);
        if !ap_is_zero(size) {
            found := false;
            for * vars if it.v == idx { it.scale = ap_add(it.scale, size); found = true; break; }
            if !found array_add(*vars, .{idx, size});
        }
    }
    return true, vars, const_off;
}

// add(V, Num)
gvn_vn_add :: (g: *Gvn, v: Value_Id, num: u32) {
    if !table_contains(*g.vn.value_numbering, v) table_add(*g.vn.value_numbering, v, num);
    if is_inst(v) && inst_op(v) == .PHI table_set(*g.vn.numbering_phi, num, v);
}

// addMemoryStateToExp
gvn_add_memory_state_to_exp :: (g: *Gvn, i: Value_Id, e: *Gvn_Expr) {
    a := mssa_access_of(g.mssa, i);
    ma := mssa_get_clobbering_access_skip_self(g.mssa, a, gvn_aaq(g));
    array_add(*e.varargs, gvn_lookup_or_add_ma(g, ma));
}

// lookupOrAddCall
gvn_lookup_or_add_call :: (g: *Gvn, c: Value_Id) -> u32 {
    vt := *g.vn;
    if fn_has_fn_attr(inst_fn(c), .PresplitCoroutine) return gvn_vn_fresh(vt, c);
    if call_is_convergent(c) return gvn_vn_fresh(vt, c);
    if aar_does_not_access_memory(*g.aar, c) {
        e := gvn_create_expr(g, c);
        v := gvn_assign_exp_new_value_num(vt, *e);
        gvn_vn_set(vt, c, v);
        return v;
    }
    if g.md && aar_only_reads_memory(*g.aar, c) {
        e := gvn_create_expr(g, c);
        v, is_new := gvn_assign_exp_new_value_num(vt, *e);
        if is_new { gvn_vn_set(vt, c, v); return v; }
        local_dep := md_get_dependency(g.md, c);
        if !mdr_is_def(local_dep) && !mdr_is_nonlocal(local_dep) return gvn_vn_fresh(vt, c);
        if mdr_is_def(local_dep) {
            ldc := local_dep.inst;
            if inst_op(ldc) != .CALL || call_num_args(ldc) != call_num_args(c) return gvn_vn_fresh(vt, c);
            for k: 0..cast(s64) call_num_args(c) - 1 {
                cvn := gvn_lookup_or_add(g, call_arg(c, cast(u32) k));
                lvn := gvn_lookup_or_add(g, call_arg(ldc, cast(u32) k));
                if cvn != lvn return gvn_vn_fresh(vt, c);
            }
            v2 := gvn_lookup_or_add(g, ldc);
            gvn_vn_set(vt, c, v2);
            return v2;
        }
        deps := md_get_non_local_call_dependency(g.md, c);
        cdep: Value_Id = NONE;
        for d: deps {
            if mdr_is_nonlocal(d.r) continue;
            if !mdr_is_def(d.r) || cdep != NONE { cdep = NONE; break; }
            nldc := d.r.inst;
            if inst_op(nldc) == .CALL && dt_properly_dominates(g.dt, d.bb, inst_block(c)) { cdep = nldc; continue; }
            cdep = NONE;
            break;
        }
        if cdep == NONE return gvn_vn_fresh(vt, c);
        if call_num_args(cdep) != call_num_args(c) return gvn_vn_fresh(vt, c);
        for k: 0..cast(s64) call_num_args(c) - 1 {
            cvn := gvn_lookup_or_add(g, call_arg(c, cast(u32) k));
            dvn := gvn_lookup_or_add(g, call_arg(cdep, cast(u32) k));
            if cvn != dvn return gvn_vn_fresh(vt, c);
        }
        v3 := gvn_lookup_or_add(g, cdep);
        gvn_vn_set(vt, c, v3);
        return v3;
    }
    if g.mssa && g.vn_mssa_enabled && aar_only_reads_memory(*g.aar, c) {
        e := gvn_create_expr(g, c);
        gvn_add_memory_state_to_exp(g, c, *e);
        v := gvn_assign_exp_new_value_num(vt, *e);
        gvn_vn_set(vt, c, v);
        return v;
    }
    return gvn_vn_fresh(vt, c);
}

// computeLoadStoreVN
gvn_compute_load_store_vn :: (g: *Gvn, i: Value_Id) -> u32 {
    vt := *g.vn;
    if !g.mssa || !g.vn_mssa_enabled return gvn_vn_fresh(vt, i);
    e := gvn_expr_new();
    e.ty = vtype(i);
    e.opcode = cast(u32) inst_op(i);
    for k: 0..cast(s64) nops(i) - 1 array_add(*e.varargs, gvn_lookup_or_add(g, op(i, cast(u32) k)));
    gvn_add_memory_state_to_exp(g, i, *e);
    v := gvn_assign_exp_new_value_num(vt, *e);
    gvn_vn_set(vt, i, v);
    return v;
}

gvn_vn_exists :: (g: *Gvn, v: Value_Id) -> bool { return table_contains(*g.vn.value_numbering, v); }

// lookupOrAdd(MemoryAccess *)
gvn_lookup_or_add_ma :: (g: *Gvn, a: s32) -> u32 {
    if is_live_on_entry(a) || ma_is_phi(g.mssa, a) return gvn_lookup_or_add(g, ma_block(g.mssa, a));
    return gvn_lookup_or_add(g, ma_inst(g.mssa, a));
}

// lookupOrAdd(Value *)
gvn_lookup_or_add :: (g: *Gvn, v: Value_Id) -> u32 {
    vt := *g.vn;
    found, n := table_find(*vt.value_numbering, v);
    if found return n;
    if !is_inst(v) {
        num := gvn_vn_fresh(vt, v);
        if vkind(v) == .BLOCK table_set(*vt.numbering_bb, num, v);
        return num;
    }
    i := v;
    e: Gvn_Expr;
    o := inst_op(i);
    if o == {
        case .CALL; return gvn_lookup_or_add_call(g, i);
        case .FNEG; #through; case .ADD; #through; case .FADD; #through; case .SUB; #through; case .FSUB; #through;
        case .MUL; #through; case .FMUL; #through; case .UDIV; #through; case .SDIV; #through; case .FDIV; #through;
        case .UREM; #through; case .SREM; #through; case .FREM; #through; case .SHL; #through; case .LSHR; #through;
        case .ASHR; #through; case .AND; #through; case .OR; #through; case .XOR; #through; case .ICMP; #through;
        case .FCMP; #through; case .TRUNC; #through; case .ZEXT; #through; case .SEXT; #through; case .FPTOUI; #through;
        case .FPTOSI; #through; case .UITOFP; #through; case .SITOFP; #through; case .FPTRUNC; #through; case .FPEXT; #through;
        case .PTRTOINT; #through; case .PTRTOADDR; #through; case .INTTOPTR; #through; case .ADDRSPACECAST; #through;
        case .BITCAST; #through; case .SELECT; #through; case .FREEZE; #through; case .EXTRACTELEMENT; #through;
        case .INSERTELEMENT; #through; case .SHUFFLEVECTOR; #through; case .INSERTVALUE;
            e = gvn_create_expr(g, i);
        case .GEP; e = gvn_create_gep_expr(g, i);
        case .EXTRACTVALUE; e = gvn_create_extractvalue_expr(g, i);
        case .PHI;
            num := gvn_vn_fresh(vt, v);
            table_set(*vt.numbering_phi, num, v);
            return num;
        case .LOAD; #through; case .STORE; return gvn_compute_load_store_vn(g, i);
        case; return gvn_vn_fresh(vt, v);
    }
    r := gvn_assign_exp_new_value_num(vt, *e);
    gvn_vn_set(vt, v, r);
    return r;
}

// lookup(V, Verify)
gvn_lookup :: (g: *Gvn, v: Value_Id, verify := true) -> u32 {
    found, n := table_find(*g.vn.value_numbering, v);
    if found return n;
    if verify fatal("gvn: internal: value not numbered");
    return 0;
}

// lookupOrAddCmp
gvn_lookup_or_add_cmp :: (g: *Gvn, opc: Opcode, pred: u8, lhs: Value_Id, rhs: Value_Id) -> u32 {
    e := gvn_create_cmp_expr(g, opc, pred, lhs, rhs);
    r := gvn_assign_exp_new_value_num(*g.vn, *e);
    return r;
}
// lookupPtrToInt
gvn_lookup_ptr_to_int :: (g: *Gvn, ptr: Value_Id, ty: Type_Id) -> u32 {
    e := gvn_expr_new(cast(u32) Opcode.PTRTOINT);
    e.ty = ty;
    array_add(*e.varargs, gvn_lookup_or_add(g, ptr));
    k := gvn_expr_lookup(*g.vn, *e, false);
    if k < 0 return 0;
    return g.vn.expr_entries[k].value;
}
// clear
gvn_vt_clear :: (vt: *Gvn_Vt) {
    table_reset(*vt.value_numbering);
    table_reset(*vt.expr_heads);
    vt.expr_entries.count = 0;
    table_reset(*vt.numbering_phi);
    table_reset(*vt.numbering_bb);
    table_reset(*vt.phi_translate_table);
    vt.next_value_number = 1;
    vt.expressions.count = 0;
    vt.expr_idx.count = 0;
    vt.next_expr_number = 0;
}
// erase
gvn_vt_erase :: (vt: *Gvn_Vt, v: Value_Id) {
    _, num := table_find(*vt.value_numbering, v);
    table_remove(*vt.value_numbering, v);
    if is_inst(v) && inst_op(v) == .PHI table_remove(*vt.numbering_phi, num);
    else if vkind(v) == .BLOCK table_remove(*vt.numbering_bb, num);
}

// ---------------------------------------------------------------- LeaderMap

gvn_leader_insert :: (g: *Gvn, n: u32, v: Value_Id, bb: Value_Id) {
    found, head := table_find(*g.leader_heads, n);
    idx := g.leader_nodes.count;
    nd: Gvn_Leader_Node; nd.val = v; nd.bb = bb;
    if !found {
        array_add(*g.leader_nodes, nd);
        table_add(*g.leader_heads, n, idx);
        return;
    }
    nd.next = g.leader_nodes[head].next;
    array_add(*g.leader_nodes, nd);
    g.leader_nodes[head].next = idx;
}
gvn_leader_erase :: (g: *Gvn, n: u32, i: Value_Id, bb: Value_Id) {
    found, head := table_find(*g.leader_heads, n);
    if !found return;
    prev: s64 = -1;
    cur := head;
    while cur >= 0 && (g.leader_nodes[cur].val != i || g.leader_nodes[cur].bb != bb) { prev = cur; cur = g.leader_nodes[cur].next; }
    if cur < 0 return;
    if prev >= 0 { g.leader_nodes[prev].next = g.leader_nodes[cur].next; return; }
    nx := g.leader_nodes[cur].next;
    if nx < 0 { table_remove(*g.leader_heads, n); return; }
    g.leader_nodes[cur] = g.leader_nodes[nx];
}
// getLeaders(N): the nodes in iteration order
gvn_leaders :: (g: *Gvn, n: u32) -> [..] Gvn_Leader_Node {
    out: [..] Gvn_Leader_Node; out.allocator = temp;
    found, head := table_find(*g.leader_heads, n);
    if !found return out;
    k := head;
    while k >= 0 { array_add(*out, g.leader_nodes[k]); k = g.leader_nodes[k].next; }
    return out;
}
gvn_leader_clear :: (g: *Gvn) { table_reset(*g.leader_heads); g.leader_nodes.count = 0; }

// findLeader
gvn_find_leader :: (g: *Gvn, bb: Value_Id, num: u32) -> Value_Id {
    found, head := table_find(*g.leader_heads, num);
    if !found return NONE;
    val: Value_Id = NONE;
    k := head;
    while k >= 0 {
        e := g.leader_nodes[k];
        if dt_dominates(g.dt, e.bb, bb) {
            val = e.val;
            if is_const(val) return val;
        }
        k = e.next;
    }
    return val;
}

// ---------------------------------------------------------------- phi translation of value numbers

gvn_ptt_key :: inline (num: u32, bb: Value_Id) -> u64 { return ((cast(u64) num) << 32) | cast(u64) bb; }

// areAllValsInBB
gvn_are_all_vals_in_bb :: (g: *Gvn, num: u32, bb: Value_Id) -> bool {
    for gvn_leaders(g, num) if it.bb != bb return false;
    return true;
}
// phiTranslate
gvn_phi_translate :: (g: *Gvn, pred: Value_Id, phi_bb: Value_Id, num: u32) -> u32 {
    key := gvn_ptt_key(num, pred);
    found, r := table_find(*g.vn.phi_translate_table, key);
    if found return r;
    nn := gvn_phi_translate_impl(g, pred, phi_bb, num);
    if !table_contains(*g.vn.phi_translate_table, key) table_add(*g.vn.phi_translate_table, key, nn);
    return nn;
}
// areCallValsEqual
gvn_are_call_vals_equal :: (g: *Gvn, num: u32, new_num: u32, pred: Value_Id, phi_bb: Value_Id) -> bool {
    call: Value_Id = NONE;
    for gvn_leaders(g, num) {
        call = ifx is_inst(it.val) && inst_op(it.val) == .CALL then it.val else NONE;
        if call != NONE && inst_block(call) == phi_bb break;
    }
    if aar_does_not_access_memory(*g.aar, call) return true;
    if !g.md || !aar_only_reads_memory(*g.aar, call) return false;
    local_dep := md_get_dependency(g.md, call);
    if !mdr_is_nonlocal(local_dep) return false;
    deps := md_get_non_local_call_dependency(g.md, call);
    for deps if mdr_is_nonfunclocal(it.r) return true;
    return false;
}
// phiTranslateImpl
gvn_phi_translate_impl :: (g: *Gvn, pred: Value_Id, phi_bb: Value_Id, num: u32) -> u32 {
    vt := *g.vn;
    fp, pn := table_find(*vt.numbering_phi, num);
    if fp && pn != NONE {
        if inst_block(pn) != phi_bb return num;
        for k: 0..cast(s64) nops(pn) - 1 {
            if phi_block(pn, cast(u32) k) != pred continue;
            tv := gvn_lookup(g, phi_value(pn, cast(u32) k), false);
            if tv return tv;
        }
        return num;
    }
    fb, bb := table_find(*vt.numbering_bb, num);
    if fb && bb != NONE {
        if bb != phi_bb return num;
        mp := mssa_access_of(g.mssa, bb);
        for k: 0..cast(s64) ma_nops(g.mssa, mp) - 1 {
            if mphi_block(g.mssa, mp, cast(u32) k) != pred continue;
            a := mphi_value(g.mssa, mp, cast(u32) k);
            if !is_live_on_entry(a) && ma_is_phi(g.mssa, a) return gvn_lookup_or_add(g, ma_block(g.mssa, a));
            if is_live_on_entry(a) return gvn_lookup_or_add(g, fn_entry(block_fn(bb)));
            return gvn_lookup_or_add(g, ma_inst(g.mssa, a));
        }
        fatal("gvn: CFG/MemorySSA mismatch: predecessor not found among incoming blocks");
    }
    if !gvn_are_all_vals_in_bb(g, num, phi_bb) return num;
    if num >= vt.expr_idx.count || vt.expr_idx[num] == 0 return num;
    e := gvn_expr_copy(vt.expressions[vt.expr_idx[num]]);
    for k: 0..e.varargs.count-1 {
        if (k > 1 && e.opcode == cast(u32) Opcode.INSERTVALUE) || (k > 0 && e.opcode == cast(u32) Opcode.EXTRACTVALUE) ||
           (k > 1 && e.opcode == cast(u32) Opcode.SHUFFLEVECTOR) continue;
        e.varargs[k] = gvn_phi_translate(g, pred, phi_bb, e.varargs[k]);
    }
    if e.commutative {
        if e.varargs[0] > e.varargs[1] {
            t := e.varargs[0]; e.varargs[0] = e.varargs[1]; e.varargs[1] = t;
            opc := e.opcode >> 8;
            if opc == cast(u32) Opcode.ICMP || opc == cast(u32) Opcode.FCMP
                e.opcode = (opc << 8) | cast(u32) swapped_predicate(cast(u8) (e.opcode & 255));
        }
    }
    k := gvn_expr_lookup(vt, *e, true);   // ExpressionNumbering[Exp] inserts a 0 entry
    new_num := vt.expr_entries[k].value;
    if new_num {
        if e.opcode == cast(u32) Opcode.CALL && new_num != num
            return ifx gvn_are_call_vals_equal(g, num, new_num, pred, phi_bb) then new_num else num;
        return new_num;
    }
    return num;
}
// eraseTranslateCacheEntry
gvn_erase_translate_cache_entry :: (g: *Gvn, num: u32, bb: Value_Id) {
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    for preds table_remove(*g.vn.phi_translate_table, gvn_ptt_key(num, it));
}

// ---------------------------------------------------------------- availability

Avail_State :: enum u8 { UNAVAILABLE :: 0; AVAILABLE :: 1; SPECULATIVELY_AVAILABLE :: 2; }

// IsValueFullyAvailableInBlock
gvn_is_value_fully_available_in_block :: (bb: Value_Id, fab: *Table(Value_Id, Avail_State)) -> bool {
    worklist: [..] Value_Id; worklist.allocator = temp;
    unavailable_bb: Value_Id = NONE;
    num_new := 0;
    array_add(*worklist, bb);
    while worklist.count {
        cur := pop(*worklist);
        p := table_find_pointer(fab, cur);
        if p {
            if p.* == .UNAVAILABLE { unavailable_bb = cur; break; }
            continue;
        }
        num_new += 1;
        out_of_budget := num_new > gvn_opts.max_bb_speculations;
        if out_of_budget || !block_has_predecessors(cur) {
            table_add(fab, cur, .UNAVAILABLE);
            unavailable_bb = cur;
            break;
        }
        table_add(fab, cur, .SPECULATIVELY_AVAILABLE);
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(cur, *preds);
        for preds array_add(*worklist, it);
    }
    if unavailable_bb != NONE {
        worklist.count = 0;
        block_successors(unavailable_bb, *worklist);
        succs: [..] Value_Id; succs.allocator = temp;
        while worklist.count {
            b := pop(*worklist);
            p := table_find_pointer(fab, b);
            if !p continue;
            if p.* != .SPECULATIVELY_AVAILABLE continue;
            p.* = .UNAVAILABLE;
            block_successors(b, *succs);
            for succs array_add(*worklist, it);
        }
    }
    return unavailable_bb == NONE;
}

// replaceValuesPerBlockEntry
gvn_replace_values_per_block_entry :: (vpb: *[..] Gvn_Avb, old: Value_Id, new: Value_Id) {
    for * vpb.* {
        if it.av.val == old it.av.val = new;
        if it.av.kind == .SELECT {
            if it.av.v1 == old it.av.v1 = new;
            if it.av.v2 == old it.av.v2 = new;
        }
    }
}

// AvailableValue::MaterializeAdjustedValue(Load, InsertPt)
gvn_materialize_adjusted_value :: (av: Gvn_Av, load: Value_Id, insert_pt: Value_Id) -> Value_Id {
    res: Value_Id;
    load_ty := vtype(load);
    if av.kind == {
        case .SIMPLE;
            res = av.val;
            if vtype(res) != load_ty res = vnc_get_value_for_load(res, av.offset, load_ty, insert_pt, inst_fn(load));
        case .LOAD;
            cl := av.val;
            if vtype(cl) == load_ty && av.offset == 0 {
                res = cl;
                combine_metadata_for_cse(cl, load, false);
            } else {
                res = vnc_get_value_for_load(cl, av.offset, load_ty, insert_pt, inst_fn(load));
                if get_metadata(cl, md_kind_id("noundef")) == NONE {
                    keep := u32.[md_kind_id("dereferenceable"), md_kind_id("dereferenceable_or_null"), md_kind_id("invariant.load"),
                                 md_kind_id("invariant.group"), md_kind_id("alias.scope"), md_kind_id("noalias")];
                    drop_unknown_non_debug_metadata(cl, keep);
                }
            }
        case .MEM_INTRIN;
            res = vnc_get_mem_inst_value_for_load(av.val, av.offset, load_ty, insert_pt);
        case .SELECT;
            res = create_select(av.val, av.v1, av.v2);
            insert_at_position(res, inst_block(insert_pt), insert_pt, false);
            set_metadata(res, 0, get_metadata(load, 0));
        case .UNDEF;
            fatal("gvn: internal: materializing a value from a dead block");
    }
    return res;
}
gvn_avb_materialize :: (avb: Gvn_Avb, load: Value_Id) -> Value_Id { return gvn_materialize_adjusted_value(avb.av, load, block_terminator(avb.bb)); }

// ConstructSSAForLoadSet
gvn_construct_ssa_for_load_set :: (g: *Gvn, load: Value_Id, vpb: *[..] Gvn_Avb) -> Value_Id {
    if vpb.count == 1 && dt_properly_dominates(g.dt, vpb.*[0].bb, inst_block(load))
        return gvn_avb_materialize(vpb.*[0], load);
    new_phis: [..] Value_Id; new_phis.allocator = temp;
    s: Ssa_Updater;
    s.inserted_phis = *new_phis;
    ssa_init(*s, vtype(load), vname(load));
    for av: vpb.* {
        bb := av.bb;
        if av.av.kind == .UNDEF continue;
        if ssa_has_value(*s, bb) continue;
        if bb == inst_block(load) && ((av.av.kind == .SIMPLE && av.av.val == load) || (av.av.kind == .LOAD && av.av.val == load)) continue;
        ssa_add_available(*s, bb, gvn_avb_materialize(av, load));
    }
    return ssa_value_in_middle(*s, inst_block(load));
}

// findDominatingValue
gvn_find_dominating_value :: (g: *Gvn, loc: Mem_Loc, load_ty: Type_Id, from: Value_Id) -> Value_Id {
    n := 0;
    from_bb := inst_block(from);
    q := gvn_aaq(g);
    bb := from_bb;
    while bb != NONE {
        i := ifx bb == from_bb then from else block_terminator(bb);
        while i != NONE {
            n += 1;
            if n > gvn_opts.max_num_visited_insts return NONE;
            if (aa_mod_ref_inst_loc(q, i, loc) & MR_MOD) != 0 {
                if inst_op(i) == .STORE && inst_is_simple(i) && op(i, 1) == loc.ptr && vtype(op(i, 0)) == load_ty return op(i, 0);
                return NONE;
            }
            if inst_op(i) == .LOAD && op(i, 0) == loc.ptr && vtype(i) == load_ty return i;
            i = inst_prev(i);
        }
        bb = block_single_predecessor(bb);
    }
    return NONE;
}

// AnalyzeSelectAvailability
gvn_analyze_select_availability :: (g: *Gvn, load: Value_Id, cond: Value_Id, ta: Value_Id, fa: Value_Id, from: Value_Id) -> (bool, Gvn_Av) {
    loc := mloc_get(load);
    l1 := loc; l1.ptr = ta;
    v1 := gvn_find_dominating_value(g, l1, vtype(load), from);
    if v1 == NONE return false, .{};
    l2 := loc; l2.ptr = fa;
    v2 := gvn_find_dominating_value(g, l2, vtype(load), from);
    if v2 == NONE return false, .{};
    return true, av_select(cond, v1, v2);
}

gvn_is_lifetime_start :: (i: Value_Id) -> bool { return call_iid(i) == IID_LIFETIME_START; }
gvn_is_atomic :: inline (i: Value_Id) -> bool { return inst(i).ord1 != 0; }   // Load/StoreInst::isAtomic

// AnalyzeLoadAvailability(Load, Dep, Address)
gvn_analyze_load_availability :: (g: *Gvn, load: Value_Id, dep: Gvn_Mem_Val, address: Value_Id) -> (bool, Gvn_Av) {
    dep_inst := dep.inst;
    if dep.kind == .CLOBBER {
        if inst_op(dep_inst) == .STORE {
            if address != NONE && cast(s64) gvn_is_atomic(load) <= cast(s64) gvn_is_atomic(dep_inst) {
                off := vnc_analyze_load_from_clobbering_store(vtype(load), address, dep_inst);
                if off != -1 return true, av_simple(op(dep_inst, 0), cast(u32) off);
            }
        }
        if inst_op(dep_inst) == .LOAD {
            dep_load := dep_inst;
            if dep_load != load && address != NONE && cast(s64) gvn_is_atomic(load) <= cast(s64) gvn_is_atomic(dep_load) {
                load_ty := vtype(load);
                offset: s64 = dep.offset;
                if !gvn_is_memoryssa_enabled(g) {
                    if vnc_can_coerce_must_aliased_value_to_load(dep_load, load_ty, inst_fn(dep_load)) {
                        has, co := md_get_clobber_offset(g.md, dep_load);
                        offset = ifx !has || co < 0 then -1 else cast(s64) co;
                    }
                } else {
                    if !vnc_can_coerce_must_aliased_value_to_load(dep_load, load_ty, inst_fn(dep_load)) || offset < 0 offset = -1;
                }
                if offset == -1 offset = vnc_analyze_load_from_clobbering_load(load_ty, address, dep_load);
                if offset != -1 return true, av_load(dep_load, cast(u32) offset);
            }
        }
        if is_mem_intrinsic(dep_inst) {
            if address != NONE && !gvn_is_atomic(load) {
                off := vnc_analyze_load_from_clobbering_mem_inst(vtype(load), address, dep_inst);
                if off != -1 return true, av_mi(dep_inst, cast(u32) off);
            }
        }
        return false, .{};
    }
    if inst_op(dep_inst) == .ALLOCA || gvn_is_lifetime_start(dep_inst) return true, av_simple(const_undef(vtype(load)));
    init := get_initial_value_of_allocation(dep_inst, vtype(load));
    if init != NONE return true, av_simple(init);
    if inst_op(dep_inst) == .STORE {
        if !vnc_can_coerce_must_aliased_value_to_load(op(dep_inst, 0), vtype(load), inst_fn(dep_inst)) return false, .{};
        if cast(s64) gvn_is_atomic(dep_inst) < cast(s64) gvn_is_atomic(load) return false, .{};
        return true, av_simple(op(dep_inst, 0));
    }
    if inst_op(dep_inst) == .LOAD {
        if !vnc_can_coerce_must_aliased_value_to_load(dep_inst, vtype(load), inst_fn(dep_inst)) return false, .{};
        if cast(s64) gvn_is_atomic(dep_inst) < cast(s64) gvn_is_atomic(load) return false, .{};
        return true, av_load(dep_inst);
    }
    if inst_op(dep_inst) == .SELECT {
        ok, av := gvn_analyze_select_availability(g, load, op(dep_inst, 0), op(dep_inst, 1), op(dep_inst, 2), dep_inst);
        return ok, av;
    }
    return false, .{};
}

// AnalyzeLoadAvailability(Load, Deps, ValuesPerBlock, UnavailableBlocks)
gvn_analyze_load_availability_deps :: (g: *Gvn, load: Value_Id, deps: [] Gvn_Mem_Val, vpb: *[..] Gvn_Avb, unavail: *[..] Value_Id) {
    for dep: deps {
        dep_bb := dep.block;
        if gvn_is_in_dead(g, dep_bb) { array_add(vpb, .{dep_bb, av_undef()}); continue; }
        if dep.kind == .OTHER { array_add(unavail, dep_bb); continue; }
        if dep.kind == .SELECT {
            ok, av := gvn_analyze_select_availability(g, load, dep.sel_cond, dep.sel_t, dep.sel_f, block_terminator(dep_bb));
            if ok array_add(vpb, .{dep_bb, av});
            else array_add(unavail, dep_bb);
            continue;
        }
        ok, av := gvn_analyze_load_availability(g, load, dep, dep.addr);
        if ok array_add(vpb, .{dep_bb, av});
        else array_add(unavail, dep_bb);
    }
}

// findLoadToHoistIntoPred
gvn_find_load_to_hoist_into_pred :: (g: *Gvn, pred: Value_Id, load_bb: Value_Id, load: Value_Id) -> Value_Id {
    term := block_terminator(pred);
    if num_successors(term) != 2 || is_special_terminator(inst_op(term)) return NONE;
    succ := get_successor(term, 0);
    if succ == load_bb succ = get_successor(term, 1);
    if block_single_predecessor(succ) == NONE return NONE;
    num := gvn_opts.max_num_insns_per_block;
    for i: block_insts(succ) {
        if is_pseudo_probe(i) continue;
        num -= 1;
        if num == 0 return NONE;
        if !is_identical_to(i, load) continue;
        has_local_dep := true;
        if !gvn_is_memoryssa_enabled(g) {
            dep := md_get_dependency(g.md, i);
            has_local_dep = !mdr_is_nonlocal(dep);
        } else {
            m := g.mssau.mssa;
            a := mssa_access_of(m, i);
            if a >= 0 && ma_is_use(m, a) {
                c := mssa_get_clobbering_access(m, a, gvn_aaq(g));
                has_local_dep = ma_block(m, c) == succ;
            }
        }
        if !has_local_dep && !ipt_is_preceded_by_special(*g.icf, i) return i;
        return NONE;
    }
    return NONE;
}

// eliminatePartiallyRedundantLoad
Gvn_Pred_Load :: struct { bb: Value_Id; v: Value_Id; }   // MapVector entry
gvn_eliminate_partially_redundant_load :: (g: *Gvn, load: Value_Id, vpb: *[..] Gvn_Avb, avail_loads: [] Gvn_Pred_Load,
                                           ce_pred_and_load: *[..] Gvn_Pred_Load) {
    for al: avail_loads {
        ub := al.bb;
        load_ptr := al.v;
        nl := new_inst(.LOAD, vtype(load), 1);
        set_op(nl, 0, load_ptr);
        copy_load_store_properties(nl, load);
        insert_at_position(nl, ub, block_terminator(ub), false);
        set_name(nl, tprint("%.pre", vname(load)));
        set_metadata(nl, 0, get_metadata(load, 0));
        if g.mssau {
            na := mssau_create_memory_access_in_bb(g.mssau, nl, -1, inst_block(nl), .BEFORE_TERMINATOR);
            if ma_is_def(g.mssau.mssa, na) mssau_insert_def(g.mssau, na, true);
            else mssau_insert_use(g.mssau, na, true);
        }
        tags := aa_metadata(load);
        if !aa_tags_empty(tags) set_aa_metadata(nl, tags);
        for name: string.["invariant.load", "invariant.group", "range", "nofpclass"] {
            k := md_kind_id(name);
            m := get_metadata(load, k);
            if m != NONE set_metadata(nl, k, m);
        }
        am := get_metadata(load, MD_ACCESS_GROUP_KIND);
        if am != NONE && li_loop_for(g.li, inst_block(load)) == li_loop_for(g.li, ub) set_metadata(nl, MD_ACCESS_GROUP_KIND, am);
        array_add(vpb, .{ub, av_simple(nl)});
        if g.md md_invalidate_cached_pointer_info(g.md, load_ptr);
        if ce_pred_and_load {
            for ce: ce_pred_and_load.* {
                if ce.bb != ub continue;
                ipt_insert_instruction_to(*g.icf, nl, ub);
                old := ce.v;
                combine_metadata_for_cse(nl, old, true);
                rauw_with_metadata(old, nl);
                gvn_replace_values_per_block_entry(vpb, old, nl);
                vno := gvn_lookup(g, old, false);
                if vno gvn_leader_erase(g, vno, old, inst_block(old));
                gvn_remove_instruction(g, old);
                break;
            }
        }
    }
    v := gvn_construct_ssa_for_load_set(g, load, vpb);
    gvn_icf_remove_users_of(g, load);
    rauw_with_metadata(load, v);
    if is_inst(v) && inst_op(v) == .PHI ic_take_name(v, load);
    if is_inst(v) set_metadata(v, 0, get_metadata(load, 0));
    if g.md && is_ptr_or_ptr_vector(vtype(v)) md_invalidate_cached_pointer_info(g.md, v);
    gvn_salvage_and_remove_instruction(g, load);
}

// isSafeToSpeculativelyExecute(Load, CtxI, AC, DT)
gvn_is_safe_to_speculatively_execute_load :: (g: *Gvn, i: Value_Id, ctx: Value_Id) -> bool {
    if inst_op(i) == .LOAD {
        if !is_unordered(i) return false;
        fa := attr_list_fn(glob(inst_fn(i)).attrs);
        if attr_set_has(fa, .SanitizeThread) || attr_set_has(fa, .SanitizeAddress) || attr_set_has(fa, .SanitizeHWAddress) return false;
        q: Simplify_Query; q.ac = g.ac; q.dt = g.dt; q.cxt = ctx;
        return is_dereferenceable_and_aligned_pointer_ty(op(i, 0), vtype(i), inst(i).align, q);
    }
    return is_safe_to_speculatively_execute(i);
}

// PerformLoadPRE
gvn_perform_load_pre :: (g: *Gvn, load: Value_Id, vpb: *[..] Gvn_Avb, unavail: [] Value_Id) -> bool {
    load_bb := inst_block(load);
    tmp_bb := load_bb;
    must_ensure := ipt_is_preceded_by_special(*g.icf, load);
    while block_single_predecessor(tmp_bb) != NONE {
        tmp_bb = block_single_predecessor(tmp_bb);
        if tmp_bb == load_bb return false;
        for unavail if it == tmp_bb return false;
        if num_successors(block_terminator(tmp_bb)) != 1 return false;
        must_ensure = must_ensure || ipt_has_special(*g.icf, tmp_bb);
    }
    load_bb = tmp_bb;

    pred_loads: [..] Gvn_Pred_Load; pred_loads.allocator = temp;
    fab: Table(Value_Id, Avail_State); fab.allocator = temp;
    for vpb.* table_set(*fab, it.bb, .AVAILABLE);
    for unavail table_set(*fab, it, .UNAVAILABLE);
    ce_split: [..] Value_Id; ce_split.allocator = temp;
    ce_pred_and_load: [..] Gvn_Pred_Load; ce_pred_and_load.allocator = temp;
    map_set :: (m: *[..] Gvn_Pred_Load, bb: Value_Id, v: Value_Id) {
        for * m.* if it.bb == bb { it.v = v; return; }
        array_add(m, .{bb, v});
    }
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(load_bb, *preds);
    for pred: preds {
        if block_is_eh_pad_inst(block_terminator(pred)) return false;
        if gvn_is_value_fully_available_in_block(pred, *fab) continue;
        pt := block_terminator(pred);
        if num_successors(pt) != 1 {
            if inst_op(pt) == .INDIRECTBR return false;
            if block_is_eh_pad(load_bb) return false;
            if !gvn_is_load_pre_split_backedge_enabled(g) && dt_dominates(g.dt, load_bb, pred) return false;
            li := gvn_find_load_to_hoist_into_pred(g, pred, load_bb, load);
            if li != NONE map_set(*ce_pred_and_load, pred, li);
            else array_add(*ce_split, pred);
        } else {
            map_set(*pred_loads, pred, NONE);
        }
    }
    num_insert_preds := pred_loads.count + ce_split.count;
    if num_insert_preds > 1 return false;
    if must_ensure {
        if ce_split.count && !gvn_is_safe_to_speculatively_execute_load(g, load, block_first_non_phi(load_bb)) return false;
        for pred_loads if !gvn_is_safe_to_speculatively_execute_load(g, load, block_terminator(it.bb)) return false;
        for ce_pred_and_load if !gvn_is_safe_to_speculatively_execute_load(g, load, block_terminator(it.bb)) return false;
    }
    for orig: ce_split {
        np := gvn_split_critical_edges_pair(g, orig, load_bb);
        map_set(*pred_loads, np, NONE);
    }
    for ce_pred_and_load map_set(*pred_loads, it.bb, NONE);

    can_do_pre := true;
    new_insts: [..] Value_Id; new_insts.allocator = temp;
    for * pl: pred_loads {
        up := pl.bb;
        load_ptr := op(load, 0);
        cur := inst_block(load);
        while cur != load_bb {
            addr := pta_make(load_ptr, g.ac);
            load_ptr = pta_translate_with_insertion(*addr, cur, block_single_predecessor(cur), g.dt, *new_insts);
            if load_ptr == NONE { can_do_pre = false; break; }
            cur = block_single_predecessor(cur);
        }
        if load_ptr != NONE {
            addr := pta_make(load_ptr, g.ac);
            load_ptr = pta_translate_with_insertion(*addr, load_bb, up, g.dt, *new_insts);
        }
        if load_ptr == NONE { can_do_pre = false; break; }
        pl.v = load_ptr;
    }
    if !can_do_pre {
        while new_insts.count { i := pop(*new_insts); erase_inst_with_metadata(i); }
        return ce_split.count != 0;
    }
    for new_insts {
        drop_location(it);   // updateLocationAfterHoist
        gvn_lookup_or_add(g, it);
    }
    gvn_eliminate_partially_redundant_load(g, load, vpb, pred_loads, *ce_pred_and_load);
    return true;
}
block_is_eh_pad_inst :: (i: Value_Id) -> bool {
    o := inst_op(i);
    return o == .LANDINGPAD || o == .CLEANUPPAD || o == .CATCHPAD || o == .CATCHSWITCH;
}

// performLoopLoadPRE
gvn_perform_loop_load_pre :: (g: *Gvn, load: Value_Id, vpb: *[..] Gvn_Avb, unavail: [] Value_Id) -> bool {
    l := li_loop_for(g.li, inst_block(load));
    if l == NONE || li_header(g.li, l) != inst_block(load) return false;
    preheader := li_loop_preheader(g.li, l);
    latch := li_loop_latch(g.li, l);
    if preheader == NONE || latch == NONE return false;
    load_ptr := op(load, 0);
    if !li_is_loop_invariant(g.li, l, load_ptr) return false;
    if ipt_is_preceded_by_special(*g.icf, load) return false;
    loop_block: Value_Id = NONE;
    for blocker: unavail {
        if !li_contains(g.li, l, blocker) continue;
        if loop_block != NONE return false;
        if l != li_loop_for(g.li, blocker) return false;
        if dt_dominates(g.dt, blocker, latch) return false;
        if may_write_to_memory(block_terminator(blocker)) return false;
        loop_block = blocker;
    }
    if loop_block == NONE return false;
    if value_can_be_freed(load_ptr) return false;
    al: [..] Gvn_Pred_Load; al.allocator = temp;
    array_add(*al, .{loop_block, load_ptr});
    if preheader == loop_block al[0].v = load_ptr; else array_add(*al, .{preheader, load_ptr});
    gvn_eliminate_partially_redundant_load(g, load, vpb, al, null);
    return true;
}

// processNonLocalLoad(L): MemoryDependence results to reaching memory values
gvn_process_non_local_load_md :: (g: *Gvn, load: Value_Id) -> bool {
    fa := attr_list_fn(glob(inst_fn(load)).attrs);
    if attr_set_has(fa, .SanitizeAddress) || attr_set_has(fa, .SanitizeHWAddress) return false;
    deps: [..] Nl_Result; deps.allocator = temp;
    md_get_non_local_pointer_dependency(g.md, load, *deps);
    if deps.count > gvn_opts.max_num_deps return false;
    vals: [..] Gvn_Mem_Val; vals.allocator = temp;
    for d: deps {
        r := d.r;
        bb := d.bb;
        i := mdr_inst(r);
        if mdr_is_select(r) { array_add(*vals, rmv_select(bb, d.addr, d.sel_t, d.sel_f)); continue; }
        address := d.addr;
        if mdr_is_clobber(r) array_add(*vals, rmv_clobber(address, i));
        else if mdr_is_def(r) array_add(*vals, rmv_def(address, i));
        else array_add(*vals, rmv_unknown(bb, address, i));
    }
    return gvn_process_non_local_load(g, load, vals);
}

// processNonLocalLoad(L, Deps)
gvn_process_non_local_load :: (g: *Gvn, load: Value_Id, deps: [] Gvn_Mem_Val) -> bool {
    if deps.count == 1 && deps[0].kind == .OTHER return false;
    changed := false;
    if gvn_is_scalar_pre_enabled(g) {
        gep := op(load, 0);
        if is_inst(gep) && inst_op(gep) == .GEP {
            for k: 1..cast(s64) nops(gep) - 1 {
                x := op(gep, cast(u32) k);
                if is_inst(x) changed = gvn_perform_scalar_pre(g, x) || changed;
            }
        }
    }
    vpb: [..] Gvn_Avb; vpb.allocator = temp;
    unavail: [..] Value_Id; unavail.allocator = temp;
    gvn_analyze_load_availability_deps(g, load, deps, *vpb, *unavail);
    if vpb.count == 0 return changed;
    if unavail.count == 0 {
        v := gvn_construct_ssa_for_load_set(g, load, *vpb);
        gvn_icf_remove_users_of(g, load);
        rauw_with_metadata(load, v);
        if is_inst(v) && inst_op(v) == .PHI ic_take_name(v, load);
        if is_inst(v) && get_metadata(load, 0) != NONE && inst_block(load) == inst_block(v) set_metadata(v, 0, get_metadata(load, 0));
        if g.md && is_ptr_or_ptr_vector(vtype(v)) md_invalidate_cached_pointer_info(g.md, v);
        gvn_salvage_and_remove_instruction(g, load);
        return true;
    }
    if !gvn_is_load_pre_enabled(g) return changed;
    if !gvn_is_load_in_loop_pre_enabled(g) && li_loop_for(g.li, inst_block(load)) != NONE return changed;
    if gvn_perform_loop_load_pre(g, load, *vpb, unavail) || gvn_perform_load_pre(g, load, *vpb, unavail) return true;
    return changed;
}

// processAssumeIntrinsic
gvn_process_assume_intrinsic :: (g: *Gvn, ii: Value_Id) -> bool {
    v := call_arg(ii, 0);
    if vkind(v) == .C_INT {
        if is_null_value(v) {
            ns := new_inst(.STORE, ir.t_void, 2);
            set_op(ns, 0, const_poison(ir.t_i8));
            set_op(ns, 1, const_null_value(type_ptr(0)));
            inst(ns).align = 1;
            insert_at_position(ns, inst_block(ii), ii, false);
            if g.mssau {
                m := g.mssau.mssa;
                first_non_dom: s32 = -1;
                a := mssa_first_access(m, inst_block(ns));
                while a >= 0 {
                    if !ma_is_phi(m, a) && !comes_before(ma_inst(m, a), ns) { first_non_dom = a; break; }
                    a = m.acc[a].next;
                }
                nd: s32;
                if first_non_dom >= 0 nd = mssau_create_memory_access_before(g.mssau, ns, -1, first_non_dom);
                else nd = mssau_create_memory_access_in_bb(g.mssau, ns, -1, inst_block(ns), .BEFORE_TERMINATOR);
                mssau_insert_def(g.mssau, nd, false);
            }
        }
        if is_assume_with_empty_bundle(ii) {
            gvn_salvage_and_remove_instruction(g, ii);
            return true;
        }
        return false;
    }
    if is_const(v) return false;
    return gvn_propagate_equality(g, v, const_int(ir.t_i1, 1), NONE, NONE, ii);
}

// patchReplacementInstruction
patch_replacement_instruction :: (i: Value_Id, repl: Value_Id) {
    if !is_inst(repl) return;
    ri := repl;
    is_wo_extract := inst_op(i) == .EXTRACTVALUE && inst_indices(i).count == 1 && inst_indices(i)[0] == 0 &&
                     is_inst(op(i, 0)) && is_with_overflow_inst(op(i, 0));
    if is_overflowing_binary_operator(ri) && is_wo_extract drop_poison_generating_flags(ri);
    else if inst_op(i) != .LOAD and_ir_flags(ri, i);
    if is_call_base(ri) && is_call_base(i) try_intersect_attributes(ri, i);
    combine_metadata_for_cse(ri, i, false);
}
is_overflowing_binary_operator :: (i: Value_Id) -> bool {
    o := inst_op(i);
    return o == .ADD || o == .SUB || o == .MUL || o == .SHL;
}
gvn_patch_and_rauw :: (i: Value_Id, repl: Value_Id) {
    patch_replacement_instruction(i, repl);
    rauw_with_metadata(i, repl);
}

// findInvariantGroupValue
gvn_find_invariant_group_value :: (l: Value_Id, dt: *Dom_Tree) -> Value_Id {
    ptr_op := strip_pointer_casts(op(l, 0));
    if is_const(ptr_op) return NONE;
    queue: [..] Value_Id; queue.allocator = temp;
    array_add(*queue, ptr_op);
    most := l;
    ig := md_kind_id("invariant.group");
    while queue.count {
        p := pop(*queue);
        u := ir.v_first_use[p];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if !is_inst(usr) || usr == l || !dt_dominates_inst(dt, usr, most) continue;
            o := inst_op(usr);
            if o == .BITCAST || (o == .GEP && gep_has_all_zero_indices(usr)) { array_add(*queue, usr); continue; }
            lsp: Value_Id = NONE;
            if o == .LOAD lsp = op(usr, 0); else if o == .STORE lsp = op(usr, 1);
            if get_metadata(usr, ig) != NONE && p == lsp && !is_volatile(usr) most = usr;
        }
    }
    return ifx most != l then most else NONE;
}

// ---------------------------------------------------------------- MemorySSA-based reaching memory values

// maybeLoadStoreLocation
gvn_maybe_load_store_location :: (i: Value_Id, allow_stores: bool) -> (bool, Mem_Loc) {
    o := inst_op(i);
    if o == .LOAD return true, mloc_get(i);
    id := call_iid(i);
    if id == IID_MASKED_LOAD return true, mloc_for_argument(i, 0, true);
    if id == IID_MASKED_STORE { if allow_stores return true, mloc_for_argument(i, 1, true); return false, .{}; }
    if !allow_stores return false, .{};
    if o == .STORE return true, mloc_get(i);
    return false, .{};
}

// scanMemoryAccessesUsers
gvn_scan_memory_accesses_users :: (g: *Gvn, loc: Mem_Loc, is_invariant_load: bool, bb: Value_Id, clobbers: [] s32, q: *Aa_Query,
                                   l: Value_Id = NONE) -> (bool, Gvn_Mem_Val) {
    m := g.mssa;
    have := false;
    choice: Gvn_Mem_Val;
    users: [..] s32; users.allocator = temp;
    for ma: clobbers {
        scanned := 0;
        ma_users(m, ma, *users);
        for u: users {
            scanned += 1;
            if scanned >= gvn_opts.scan_users_limit return true, rmv_unknown(bb, loc.ptr);
            if ma_is_phi(m, u) || ma_block(m, u) != bb continue;
            mem_i := ma_inst(m, u);
            if mem_i == l || (l != NONE && !mssa_locally_dominates(m, u, mssa_access_of(m, l))) continue;
            ok, ml := gvn_maybe_load_store_location(mem_i, is_invariant_load);
            if !ok continue;
            ar := aa_alias(q, ml, loc);
            if ar.kind == AR_NO || ar.kind == AR_MAY continue;
            if ar.kind == AR_PARTIAL && (!ar.has_offset || ar.offset < 0) continue;
            // UpdateChoice
            if !have {
                if ar.kind == AR_PARTIAL choice = rmv_clobber(loc.ptr, mem_i, ar.offset);
                else choice = rmv_def(loc.ptr, mem_i);
                have = true;
                continue;
            }
            if !mssa_locally_dominates(m, mssa_access_of(m, choice.inst), mssa_access_of(m, mem_i)) continue;
            if ar.kind == AR_PARTIAL { choice.kind = .CLOBBER; choice.offset = ar.offset; }
            else { choice.kind = .DEF; choice.offset = -1; }
            choice.inst = mem_i;
            choice.block = inst_block(mem_i);
        }
        if have break;
    }
    return have, choice;
}

// accessMayModifyLocation
gvn_access_may_modify_location :: (g: *Gvn, clobber_ma: s32, loc: Mem_Loc, is_invariant_load: bool, bb: Value_Id, q: *Aa_Query) -> (bool, Gvn_Mem_Val) {
    m := g.mssa;
    if is_live_on_entry(clobber_ma) {
        alloc := get_underlying_object(loc.ptr);
        if is_inst(alloc) && inst_op(alloc) == .ALLOCA && inst_block(alloc) == bb return true, rmv_def(loc.ptr, alloc);
        return true, rmv_unknown(bb, loc.ptr);
    }
    if is_invariant_load || aa_mod_ref_mask(q, loc) == MR_NO return false, .{};
    ci := ma_inst(m, clobber_ma);
    ok, ml := gvn_maybe_load_store_location(ci, true);
    if ok {
        ar := aa_alias(q, ml, loc);
        if ar.kind == AR_MUST return true, rmv_def(loc.ptr, ci);
        if ar.kind == AR_NO {
            if !inst_is_atomic(ci) || !is_stronger_than_monotonic(gvn_ordering(ci)) || inst_op(ci) == .STORE return false, .{};
            return true, rmv_clobber(loc.ptr, ci);
        }
        if !inst_is_atomic(ci) && inst_op(ci) == .LOAD return false, .{};
        if ar.kind == AR_MAY || (ar.kind == AR_PARTIAL && (!ar.has_offset || ar.offset < 0)) return true, rmv_clobber(loc.ptr, ci);
        return true, rmv_clobber(loc.ptr, ci, ar.offset);
    }
    if call_iid(ci) == IID_LIFETIME_START {
        ol := mloc_for_argument(ci, 0, true);
        if aa_alias(q, ol, loc).kind == AR_MUST return true, rmv_def(loc.ptr, ci);
        return false, .{};
    }
    if is_no_alias_call(ci) {
        obj := get_underlying_object(loc.ptr);
        if obj == ci || aa_alias(q, mloc_before_or_after(ci), mloc_before_or_after(loc.ptr)).kind == AR_MUST return true, rmv_def(loc.ptr, ci);
    }
    if inst_op(ci) == .FENCE && inst(ci).ord1 == ORD_RELEASE return false, .{};
    mr := aa_mod_ref_inst_loc(q, ci, loc);
    if mr == MR_NO || mr == MR_REF return false, .{};
    return true, rmv_clobber(loc.ptr, ci);
}
gvn_ordering :: (i: Value_Id) -> u8 { return inst(i).ord1; }

// DependencyBlockInfo
Gvn_Dep_Block :: struct {
    addr: Phi_Trans_Addr;
    initial_clobber: s32;
    clobber: s32;
    has_mem_val: bool;
    mem_val: Gvn_Mem_Val;
    force_unknown: bool;
    visited: bool;
}
Gvn_Dep_Blocks :: struct { index: Table(Value_Id, s64); rows: [..] Gvn_Dep_Block; }
gdb_find :: (s: *Gvn_Dep_Blocks, bb: Value_Id) -> s64 { found, k := table_find(*s.index, bb); if found return k; return -1; }

// collectPredecessors
gvn_collect_predecessors :: (g: *Gvn, bb: Value_Id, addr: *Phi_Trans_Addr, clobber_ma: s32, blocks: *Gvn_Dep_Blocks, worklist: *[..] Value_Id) -> bool {
    if pta_needs_phi_translation_from_block(addr, bb) && !pta_is_potentially_phi_translatable(addr) return false;
    m := g.mssa;
    mphi: s32 = -1;
    if ma_block(m, clobber_ma) == bb && !is_live_on_entry(clobber_ma) && ma_is_phi(m, clobber_ma) mphi = clobber_ma;
    P :: struct { bb: Value_Id; info: Gvn_Dep_Block; }
    preds_out: [..] P; preds_out.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    for pred: preds {
        if !dt_is_reachable_from_entry(g.dt, pred) continue;
        dup := false;
        for preds_out if it.bb == pred { dup = true; break; }
        if dup continue;
        trans := pta_copy(addr.*);
        if pta_needs_phi_translation_from_block(*trans, bb) pta_translate_value(*trans, bb, pred, g.dt, false);
        k := gdb_find(blocks, pred);
        if k >= 0 {
            if blocks.rows[k].addr.addr != trans.addr return false;
            continue;
        }
        info: Gvn_Dep_Block;
        info.addr = trans;
        c := ifx mphi >= 0 then mphi_value_for_block(m, mphi, pred) else clobber_ma;
        info.initial_clobber = c; info.clobber = c;
        array_add(*preds_out, .{pred, info});
    }
    for preds_out {
        if gdb_find(blocks, it.bb) < 0 {
            table_add(*blocks.index, it.bb, blocks.rows.count);
            array_add(*blocks.rows, it.info);
        }
        array_add(worklist, it.bb);
    }
    return true;
}

// collectClobberList
gvn_collect_clobber_list :: (g: *Gvn, clobbers: *[..] s32, bb_in: Value_Id, start: *Gvn_Dep_Block, blocks: *Gvn_Dep_Blocks) {
    m := g.mssa;
    bb := bb_in;
    ma := start.initial_clobber;
    last := start.clobber;
    while true {
        while ma != last {
            array_add(clobbers, ma);
            ma = ma_defining(m, ma);
        }
        array_add(clobbers, ma);
        if is_live_on_entry(ma) || (ma_block(m, ma) == bb && !ma_is_phi(m, ma)) break;
        if ma_block(m, ma) == bb bb = dt_idom_block(g.dt, bb);
        else bb = ma_block(m, ma);
        k := gdb_find(blocks, bb);
        if k < 0 break;
        ma = blocks.rows[k].initial_clobber;
        last = blocks.rows[k].clobber;
        if ma == clobbers.*[clobbers.count - 1] clobbers.count -= 1;
    }
}

// findReachingValuesForLoad
gvn_find_reaching_values_for_load :: (g: *Gvn, l: Value_Id, values: *[..] Gvn_Mem_Val) -> bool {
    m := g.mssa;
    q := aa_query_new_earliest_escape(*g.aar, g.dt);   // EarliestEscapeAnalysis(DT, LI): no LoopInfo here
    start_block := inst_block(l);
    is_invariant_load := get_metadata(l, md_kind_id("invariant.load")) != NONE;
    clobber_ma := ma_defining(m, mssa_access_of(m, l));
    loc := mloc_get(l);
    if get_metadata(l, md_kind_id("invariant.group")) != NONE {
        gi := gvn_find_invariant_group_value(l, g.dt);
        if gi != NONE {
            p := ifx inst_op(gi) == .LOAD then op(gi, 0) else op(gi, 1);
            array_add(values, rmv_def(p, gi));
            return true;
        }
    }
    while true {
        one: [1] s32; one[0] = clobber_ma;
        ok, rmv := gvn_scan_memory_accesses_users(g, loc, is_invariant_load, start_block, one, q, l);
        if ok { array_add(values, rmv); return true; }
        if ma_block(m, clobber_ma) != start_block || (!is_live_on_entry(clobber_ma) && ma_is_phi(m, clobber_ma)) break;
        ok2, rmv2 := gvn_access_may_modify_location(g, clobber_ma, loc, is_invariant_load, start_block, q);
        if ok2 { array_add(values, rmv2); return true; }
        clobber_ma = ma_defining(m, clobber_ma);
        if ma_block(m, clobber_ma) != start_block break;
    }
    fa := attr_list_fn(glob(inst_fn(l)).attrs);
    if attr_set_has(fa, .SanitizeAddress) || attr_set_has(fa, .SanitizeHWAddress) return false;

    blocks: Gvn_Dep_Blocks; blocks.index.allocator = temp; blocks.rows.allocator = temp;
    initial: [..] Value_Id; initial.allocator = temp;
    a0 := pta_make(op(l, 0), g.ac);
    if !gvn_collect_predecessors(g, start_block, *a0, clobber_ma, *blocks, *initial) return false;
    worklist: [..] Value_Id; worklist.allocator = temp;
    for initial array_add(*worklist, it);
    while worklist.count {
        bb := pop(*worklist);
        k := gdb_find(*blocks, bb);
        if blocks.rows[k].addr.addr == NONE continue;
        cma := blocks.rows[k].clobber;
        if ma_block(m, cma) == bb && (is_live_on_entry(cma) || !ma_is_phi(m, cma)) {
            l2 := loc; l2.ptr = blocks.rows[k].addr.addr;
            ok, rmv := gvn_access_may_modify_location(g, cma, l2, is_invariant_load, bb, q);
            if ok { blocks.rows[k].has_mem_val = true; blocks.rows[k].mem_val = rmv; continue; }
            blocks.rows[k].clobber = ma_defining(m, cma);
            array_add(*worklist, bb);
            continue;
        }
        if bb == start_block && blocks.rows[k].addr.addr != op(l, 0) { blocks.rows[k].force_unknown = true; continue; }
        if bb != start_block {
            ad := pta_copy(blocks.rows[k].addr);
            if !gvn_collect_predecessors(g, bb, *ad, cma, *blocks, *worklist) blocks.rows[gdb_find(*blocks, bb)].force_unknown = true;
        }
    }
    worklist.count = 0;
    for initial array_add(*worklist, it);
    for worklist blocks.rows[gdb_find(*blocks, it)].visited = true;
    clobbers: [..] s32; clobbers.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    while worklist.count {
        bb := pop(*worklist);
        k := gdb_find(*blocks, bb);
        if blocks.rows[k].addr.addr == NONE { array_add(values, rmv_unknown(bb, NONE)); continue; }
        clobbers.count = 0;
        gvn_collect_clobber_list(g, *clobbers, bb, *blocks.rows[k], *blocks);
        l2 := loc; l2.ptr = blocks.rows[k].addr.addr;
        ok, rmv := gvn_scan_memory_accesses_users(g, l2, is_invariant_load, bb, clobbers, q);
        if ok { array_add(values, rmv); continue; }
        if blocks.rows[k].has_mem_val { array_add(values, blocks.rows[k].mem_val); continue; }
        if blocks.rows[k].force_unknown { array_add(values, rmv_unknown(bb, blocks.rows[k].addr.addr)); continue; }
        block_predecessors(bb, *preds);
        for pred: preds {
            pk := gdb_find(*blocks, pred);
            if pk < 0 continue;
            if blocks.rows[pk].visited continue;
            blocks.rows[pk].visited = true;
            array_add(*worklist, pred);
        }
    }
    return true;
}

// ---------------------------------------------------------------- processLoad / processMaskedLoad

gvn_process_load :: (g: *Gvn, l: Value_Id) -> bool {
    if !g.md && !gvn_is_memoryssa_enabled(g) return false;
    if !is_unordered(l) return false;
    if type_kind(vtype(l)) == .TOKEN return false;
    if !has_uses(l) { gvn_salvage_and_remove_instruction(g, l); return true; }
    mem_val := rmv_unknown(NONE, NONE);
    if !gvn_is_memoryssa_enabled(g) {
        dep := md_get_dependency(g.md, l);
        if mdr_is_nonlocal(dep) return gvn_process_non_local_load_md(g, l);
        if mdr_is_def(dep) mem_val = rmv_def(op(l, 0), dep.inst);
        else if mdr_is_clobber(dep) mem_val = rmv_clobber(op(l, 0), dep.inst);
    } else {
        vals: [..] Gvn_Mem_Val; vals.allocator = temp;
        if !gvn_find_reaching_values_for_load(g, l, *vals) return false;
        if vals.count > 1 || vals[0].block != inst_block(l) return gvn_process_non_local_load(g, l, vals);
        mem_val = vals[0];
    }
    if mem_val.kind == .OTHER return false;
    ok, av := gvn_analyze_load_availability(g, l, mem_val, op(l, 0));
    if !ok return false;
    v := gvn_materialize_adjusted_value(av, l, l);
    gvn_icf_remove_users_of(g, l);
    rauw_with_metadata(l, v);
    if g.mssau mssau_remove_memory_access_inst(g.mssau, l);
    gvn_salvage_and_remove_instruction(g, l);
    if g.md && is_ptr_or_ptr_vector(vtype(v)) md_invalidate_cached_pointer_info(g.md, v);
    return true;
}

gvn_process_masked_load :: (g: *Gvn, i: Value_Id) -> bool {
    if !g.md return false;
    dep := md_get_dependency(g.md, i);
    dep_inst := mdr_inst(dep);
    if dep_inst == NONE || !mdr_is_local(dep) || !mdr_is_def(dep) return false;
    mask := call_arg(i, 1);
    passthrough := call_arg(i, 2);
    if call_iid(dep_inst) != IID_MASKED_STORE || call_arg(dep_inst, 2) != mask return false;
    store_val := call_arg(dep_inst, 0);
    if vtype(store_val) != vtype(i) return false;
    sel := create_select(mask, store_val, passthrough);
    insert_at_position(sel, inst_block(i), i, false);
    gvn_icf_remove_users_of(g, i);
    rauw_with_metadata(i, sel);
    gvn_salvage_and_remove_instruction(g, i);
    return true;
}

// ---------------------------------------------------------------- propagateEquality

// replaceDominatedUsesWith(If): root is an edge (start, end) or an instruction; `check_ptr` = the
// canReplacePointersInUseIfEqual callback
gvn_replace_dominated_uses :: (g: *Gvn, from: Value_Id, to: Value_Id, e_start: Value_Id, e_end: Value_Id, root_i: Value_Id, check_ptr: bool) -> s64 {
    count := 0;
    u := ir.v_first_use[from];
    while u != NONE {
        nu := ir.u_next[u];
        usr := ir.u_user[u];
        if is_inst(usr) && call_iid(usr) == IID_FAKE_USE { u = nu; continue; }
        dom := ifx root_i != NONE then dt_dominates_use(g.dt, root_i, u) else dt_dominates_edge_use(g.dt, e_start, e_end, u);
        if dom && (!check_ptr || can_replace_pointers_in_use_if_equal(u, to)) {
            set_op(usr, cast(u32) (u - ir.v_ops[usr]), to);
            count += 1;
        }
        u = nu;
    }
    return count;
}

// canReplacePointersInUseIfEqual
can_replace_pointers_in_use_if_equal :: (u: Use_Id, to: Value_Id) -> bool {
    ty := vtype(to);
    if !is_ptr_or_ptr_vector(ty) return true;
    usr := ir.u_user[u];
    id := call_iid(usr);
    if id == IID_LIFETIME_START || id == IID_LIFETIME_END return false;
    if can_replace_pointers_if_equal(ir.u_val[u], to) return true;
    st := scalar_type(ty);
    has_non_address_bits := dl_address_size_bits(cast(u32) ir.types[st].a) != dl_pointer_type_size_bits(st);
    // isPointerUseReplacable
    limit := 40;
    wl: [..] Value_Id; wl.allocator = temp;
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*wl, usr);
    while wl.count {
        limit -= 1;
        if limit == 0 break;
        x := pop(*wl);
        seen := false;
        for visited if it == x { seen = true; break; }
        if seen continue;
        array_add(*visited, x);
        if is_inst(x) {
            o := inst_op(x);
            if o == .ICMP || o == .PTRTOADDR continue;
            if !has_non_address_bits && o == .PTRTOINT continue;
            if o == .PHI || o == .SELECT {
                uu := ir.v_first_use[x];
                while uu != NONE { array_add(*wl, ir.u_user[uu]); uu = ir.u_next[uu]; }
                continue;
            }
        }
        return false;
    }
    return limit != 0;
}

// propagateEquality(LHS, RHS, Root): root = the edge (e_start, e_end) or the instruction root_i
gvn_propagate_equality :: (g: *Gvn, lhs_in: Value_Id, rhs_in: Value_Id, e_start: Value_Id, e_end: Value_Id, root_i: Value_Id) -> bool {
    Pair :: struct { a: Value_Id; b: Value_Id; }
    wl: [..] Pair; wl.allocator = temp;
    array_add(*wl, .{lhs_in, rhs_in});
    changed := false;
    dominated: [..] Value_Id; dominated.allocator = temp;
    if root_i == NONE {
        // isOnlyReachableViaThisEdge
        if block_single_predecessor(e_end) != NONE array_add(*dominated, e_end);
    } else {
        n := dt_node(g.dt, inst_block(root_i));
        c := g.dt.nodes[n].first_child;
        while c >= 0 { array_add(*dominated, g.dt.nodes[c].block); c = g.dt.nodes[c].sibling; }
    }
    while wl.count {
        item := pop(*wl);
        lhs := item.a; rhs := item.b;
        if lhs == rhs continue;
        if is_const(lhs) && is_const(rhs) continue;
        if is_const(lhs) || (vkind(lhs) == .ARGUMENT && !is_const(rhs)) { t := lhs; lhs = rhs; rhs = t; }
        lvn := gvn_lookup_or_add(g, lhs);
        if (vkind(lhs) == .ARGUMENT && vkind(rhs) == .ARGUMENT) || (is_inst(lhs) && is_inst(rhs)) {
            rvn := gvn_lookup_or_add(g, rhs);
            if lvn < rvn { t := lhs; lhs = rhs; rhs = t; lvn = rvn; }
        }
        if !is_inst(rhs) && can_replace_pointers_if_equal(lhs, rhs)
            for dominated gvn_leader_insert(g, lvn, rhs, it);
        if !has_one_use(lhs) {
            n := gvn_replace_dominated_uses(g, lhs, rhs, e_start, e_end, root_i, true);
            if n > 0 {
                changed = true;
                if g.md md_invalidate_cached_pointer_info(g.md, lhs);
            }
        }
        if vtype(rhs) != ir.t_i1 continue;
        if vkind(rhs) != .C_INT continue;
        is_known_true := !is_null_value(rhs);
        is_known_false := !is_known_true;
        ok_and, a1, b1 := pm_logical_and(lhs);
        ok_or, a2, b2 := pm_logical_or(lhs);
        if is_known_true && ok_and { array_add(*wl, .{a1, rhs}); array_add(*wl, .{b1, rhs}); continue; }
        if is_known_false && ok_or { array_add(*wl, .{a2, rhs}); array_add(*wl, .{b2, rhs}); continue; }
        if is_inst(lhs) && (inst_op(lhs) == .ICMP || inst_op(lhs) == .FCMP) {
            cmp := lhs;
            op0 := op(cmp, 0); op1 := op(cmp, 1);
            if cmp_is_equivalence(cmp, is_known_false) array_add(*wl, .{op0, op1});
            not_pred := cmp_inverse(inst(cmp).pred);
            not_val := const_int(vtype(cmp), ifx is_known_false then cast(u64) 1 else 0);
            next_num := g.vn.next_value_number;
            num := gvn_lookup_or_add_cmp(g, inst_op(cmp), not_pred, op0, op1);
            if num < next_num {
                for e: gvn_leaders(g, num) {
                    if root_i == NONE {
                        if !dt_dominates(g.dt, e.bb, e_start) && !dt_dominates(g.dt, e_end, e.bb) continue;
                    } else {
                        ib := inst_block(root_i);
                        if !dt_dominates(g.dt, e.bb, ib) && !dt_dominates(g.dt, ib, e.bb) continue;
                    }
                    not_cmp := e.val;
                    if not_cmp != NONE && is_inst(not_cmp) {
                        n := gvn_replace_dominated_uses(g, not_cmp, not_val, e_start, e_end, root_i, false);
                        changed = changed || n > 0;
                        if g.md md_invalidate_cached_pointer_info(g.md, not_cmp);
                    }
                }
            }
            for dominated gvn_leader_insert(g, num, not_val, it);
            continue;
        }
        if is_inst(lhs) && inst_op(lhs) == .TRUNC && (inst(lhs).flags & F_NUW) != 0 {
            a := op(lhs, 0);
            array_add(*wl, .{a, const_int(vtype(a), ifx is_known_true then cast(u64) 1 else 0)});
            continue;
        }
        okn, an := pm_not(lhs);
        if okn {
            array_add(*wl, .{an, const_int(vtype(an), ifx !is_known_true then cast(u64) 1 else 0)});
            continue;
        }
    }
    return changed;
}

// ---------------------------------------------------------------- processInstruction

gvn_process_instruction :: (g: *Gvn, i: Value_Id) -> bool {
    q: Simplify_Query; q.dt = g.dt; q.ac = g.ac;
    v := simplify_instruction(i, sq_with_instruction(q, i));
    if v != NONE {
        changed := false;
        if has_uses(i) {
            gvn_icf_remove_users_of(g, i);
            rauw_with_metadata(i, v);
            changed = true;
        }
        if is_instruction_trivially_dead(i) {
            gvn_salvage_and_remove_instruction(g, i);
            changed = true;
        }
        if changed {
            if g.md && is_ptr_or_ptr_vector(vtype(v)) md_invalidate_cached_pointer_info(g.md, v);
            return true;
        }
    }
    o := inst_op(i);
    if call_iid(i) == IID_ASSUME return gvn_process_assume_intrinsic(g, i);
    if o == .LOAD {
        if gvn_process_load(g, i) return true;
        num := gvn_lookup_or_add(g, i);
        gvn_leader_insert(g, num, i, inst_block(i));
        return false;
    }
    if call_iid(i) == IID_MASKED_LOAD && gvn_process_masked_load(g, i) return true;
    if o == .CONDBR {
        c := op(i, 0);
        if is_const(c) return gvn_process_foldable_cond_br(g, i);
        ts := get_successor(i, 0);
        fs := get_successor(i, 1);
        if ts == fs return false;
        parent := inst_block(i);
        changed := false;
        changed = gvn_propagate_equality(g, c, const_int(ir.t_i1, 1), parent, ts, NONE) || changed;
        changed = gvn_propagate_equality(g, c, const_int(ir.t_i1, 0), parent, fs, NONE) || changed;
        return changed;
    }
    if o == .SWITCH {
        cond := op(i, 0);
        parent := inst_block(i);
        changed := false;
        succs: [..] Value_Id; succs.allocator = temp;
        block_successors(parent, *succs);
        n := switch_num_cases(i);
        for k: 0..cast(s64) n - 1 {
            dst := op(i, cast(u32) (2 + k));
            cnt := 0;
            for succs if it == dst cnt += 1;
            if cnt == 1 changed = gvn_propagate_equality(g, cond, switch_case_value(i, cast(u32) k), parent, dst, NONE) || changed;
        }
        return changed;
    }
    if vtype(i) == ir.t_void return false;
    next_num := g.vn.next_value_number;
    num := gvn_lookup_or_add(g, i);
    if o == .ALLOCA || is_terminator(o) || o == .PHI {
        gvn_leader_insert(g, num, i, inst_block(i));
        return false;
    }
    if o == .PTRTOADDR {
        as := cast(u32) ir.types[scalar_type(vtype(op(i, 0)))].a;
        st := scalar_type(vtype(op(i, 0)));
        if dl_address_size_bits(as) == dl_pointer_type_size_bits(st) && !dl_ptr_spec(as).unstable {
            pti_num := gvn_lookup_ptr_to_int(g, op(i, 0), vtype(i));
            pti := gvn_find_leader(g, inst_block(i), pti_num);
            if pti != NONE {
                gvn_patch_and_rauw(i, pti);
                gvn_salvage_and_remove_instruction(g, i);
                return true;
            }
        }
    }
    if num >= next_num {
        gvn_leader_insert(g, num, i, inst_block(i));
        return false;
    }
    repl := gvn_find_leader(g, inst_block(i), num);
    if repl == NONE {
        gvn_leader_insert(g, num, i, inst_block(i));
        return false;
    }
    if repl == i return false;
    gvn_patch_and_rauw(i, repl);
    if g.md && is_ptr_or_ptr_vector(vtype(repl)) md_invalidate_cached_pointer_info(g.md, repl);
    gvn_salvage_and_remove_instruction(g, i);
    return true;
}

// ---------------------------------------------------------------- removal, ICF

// InstructionPrecedenceTracking::removeUsersOf
gvn_icf_remove_users_of :: (g: *Gvn, i: Value_Id) {
    u := ir.v_first_use[i];
    while u != NONE {
        usr := ir.u_user[u];
        if is_inst(usr) ipt_remove_instruction(*g.icf, usr);
        u = ir.u_next[u];
    }
}
// salvageAndRemoveInstruction
gvn_salvage_and_remove_instruction :: (g: *Gvn, i: Value_Id) {
    salvage_debug_info(i);
    gvn_remove_instruction(g, i);
}
// removeInstruction
gvn_remove_instruction :: (g: *Gvn, i: Value_Id) {
    gvn_vt_erase(*g.vn, i);
    if g.md md_remove_instruction(g.md, i);
    if g.mssau mssau_remove_memory_access_inst(g.mssau, i);
    ipt_remove_instruction(*g.icf, i);
    erase_inst_with_metadata(i);
}

// ---------------------------------------------------------------- scalar PRE

// performScalarPREInsertion
gvn_perform_scalar_pre_insertion :: (g: *Gvn, instr: Value_Id, pred: Value_Id, curr: Value_Id, val_no: u32) -> bool {
    success := true;
    for k: 0..cast(s64) nops(instr) - 1 {
        o := op(instr, cast(u32) k);
        if vkind(o) == .ARGUMENT || is_const(o) continue;
        if !gvn_vn_exists(g, o) { success = false; break; }
        tv := gvn_phi_translate(g, pred, curr, gvn_lookup(g, o));
        v := gvn_find_leader(g, pred, tv);
        if v != NONE set_op(instr, cast(u32) k, v);
        else { success = false; break; }
    }
    if !success return false;
    insert_at_position(instr, pred, block_terminator(pred), false);
    set_name(instr, tprint("%.pre", vname(instr)));
    ipt_insert_instruction_to(*g.icf, instr, pred);
    num := gvn_lookup_or_add(g, instr);
    gvn_vn_add(g, instr, num);
    gvn_leader_insert(g, num, instr, pred);
    return true;
}

// assignBlockRPONumber
gvn_assign_block_rpo_number :: (g: *Gvn) {
    table_reset(*g.block_rpo);
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(g.f), *po);
    n: u32 = 1;
    for < po { table_set(*g.block_rpo, it, n); n += 1; }
    g.invalid_block_rpo = false;
}

// performScalarPRE
gvn_perform_scalar_pre :: (g: *Gvn, cur: Value_Id) -> bool {
    o := inst_op(cur);
    if o == .ALLOCA || is_terminator(o) || o == .PHI || vtype(cur) == ir.t_void || may_read_from_memory(cur) ||
       may_have_side_effects(cur) || type_kind(vtype(cur)) == .TOKEN return false;
    if o == .ICMP || o == .FCMP return false;
    if o == .GEP return false;
    if is_call_base(cur) && vkind(call_callee(cur)) == .INLINE_ASM return false;
    val_no := gvn_lookup(g, cur);
    num_with := 0; num_without := 0;
    pre_pred: Value_Id = NONE;
    current_block := inst_block(cur);
    if g.invalid_block_rpo gvn_assign_block_rpo_number(g);
    Pv :: struct { v: Value_Id; bb: Value_Id; }
    pred_map: [..] Pv; pred_map.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(current_block, *preds);
    for p: preds {
        if !dt_is_reachable_from_entry(g.dt, p) { num_without = 2; break; }
        _, rp := table_find(*g.block_rpo, p);
        _, rc := table_find(*g.block_rpo, current_block);
        if rp >= rc { num_without = 2; break; }
        tv := gvn_phi_translate(g, p, current_block, val_no);
        pv := gvn_find_leader(g, p, tv);
        if pv == NONE {
            array_add(*pred_map, .{NONE, p});
            pre_pred = p;
            num_without += 1;
        } else if pv == cur {
            num_without = 2;
            break;
        } else {
            array_add(*pred_map, .{pv, p});
            num_with += 1;
        }
    }
    if num_without > 1 || num_with == 0 return false;
    pre_instr: Value_Id = NONE;
    if num_without != 0 {
        if !is_safe_to_speculatively_execute(cur) {
            if ipt_is_preceded_by_special(*g.icf, cur) return false;
        }
        if inst_op(block_terminator(pre_pred)) == .INDIRECTBR return false;
        succ_num := get_successor_number(pre_pred, current_block);
        if is_critical_edge(block_terminator(pre_pred), succ_num) {
            array_add(*g.to_split, .{block_terminator(pre_pred), succ_num});
            return false;
        }
        pre_instr = ic_clone_inst(cur);
        if !gvn_perform_scalar_pre_insertion(g, pre_instr, pre_pred, current_block, val_no) {
            erase_unlinked_inst(pre_instr);
            return false;
        }
    }
    phi := create_phi(vtype(cur), cast(u32) pred_map.count);
    insert_at_position(phi, current_block, block_first(current_block), true);
    set_name(phi, tprint("%.pre-phi", vname(cur)));
    for pred_map {
        if it.v != NONE {
            patch_replacement_instruction(cur, it.v);
            phi_add_incoming(phi, it.v, it.bb);
        } else phi_add_incoming(phi, pre_instr, pre_pred);
    }
    gvn_vn_add(g, phi, val_no);
    gvn_erase_translate_cache_entry(g, val_no, current_block);
    gvn_leader_insert(g, val_no, phi, current_block);
    set_metadata(phi, 0, get_metadata(cur, 0));
    rauw_with_metadata(cur, phi);
    if g.md && is_ptr_or_ptr_vector(vtype(phi)) md_invalidate_cached_pointer_info(g.md, phi);
    gvn_leader_erase(g, val_no, cur, current_block);
    gvn_remove_instruction(g, cur);
    return true;
}
// GetSuccessorNumber
get_successor_number :: (bb: Value_Id, succ: Value_Id) -> u32 {
    t := block_terminator(bb);
    for k: 0..num_successors(t) - 1 if get_successor(t, k) == succ return k;
    fatal("gvn: internal: not a successor");
    return 0;
}

// depth_first(&F.getEntryBlock()): preorder
cfg_depth_first :: (entry: Value_Id, out: *[..] Value_Id) {
    Frame :: struct { b: Value_Id; next: u32; n: u32; }
    visited: Table(Value_Id, bool); visited.allocator = temp;
    stack: [..] Frame; stack.allocator = temp;
    table_set(*visited, entry, true);
    array_add(out, entry);
    array_add(*stack, .{entry, 0, block_num_successors(entry)});
    while stack.count {
        top := *stack[stack.count - 1];
        if top.next < top.n {
            s := get_successor(block_terminator(top.b), top.next);
            top.next += 1;
            if !table_contains(*visited, s) {
                table_set(*visited, s, true);
                array_add(out, s);
                array_add(*stack, .{s, 0, block_num_successors(s)});
            }
            continue;
        }
        stack.count -= 1;
    }
}

// performPRE
gvn_perform_pre :: (g: *Gvn) -> bool {
    changed := false;
    blocks: [..] Value_Id; blocks.allocator = temp;
    cfg_depth_first(fn_entry(g.f), *blocks);
    for cb: blocks {
        if cb == fn_entry(g.f) continue;
        if block_is_eh_pad(cb) continue;
        i := block_first(cb);
        while i != NONE {
            cur := i;
            i = inst_next(i);
            changed = gvn_perform_scalar_pre(g, cur) || changed;
        }
    }
    if gvn_split_critical_edges(g) changed = true;
    return changed;
}

gvn_crit_opts :: (g: *Gvn) -> Crit_Edge_Options {
    o: Crit_Edge_Options;
    o.dt = g.dt; o.li = g.li; o.mssau = g.mssau;
    return o;
}
// splitCriticalEdges(Pred, Succ)
gvn_split_critical_edges_pair :: (g: *Gvn, pred: Value_Id, succ: Value_Id) -> Value_Id {
    o := gvn_crit_opts(g);
    o.preserve_loop_simplify = false;   // unsetPreserveLoopSimplify
    t := block_terminator(pred);
    bb := split_critical_edge(t, get_successor_number(pred, succ), *o);
    if bb != NONE {
        if g.md md_invalidate_cached_predecessors(g.md);
        g.invalid_block_rpo = true;
    }
    return bb;
}
// splitCriticalEdges()
gvn_split_critical_edges :: (g: *Gvn) -> bool {
    if g.to_split.count == 0 return false;
    changed := false;
    while g.to_split.count {
        e := pop(*g.to_split);
        o := gvn_crit_opts(g);
        o.preserve_loop_simplify = true;
        changed = split_critical_edge(e.term, e.succ, *o) != NONE || changed;
    }
    if changed {
        if g.md md_invalidate_cached_predecessors(g.md);
        g.invalid_block_rpo = true;
    }
    return changed;
}

// ---------------------------------------------------------------- dead blocks

// addDeadBlock
gvn_add_dead_block :: (g: *Gvn, bb: Value_Id) {
    new_dead: [..] Value_Id; new_dead.allocator = temp;
    df: [..] Value_Id; df.allocator = temp;   // SmallSetVector
    array_add(*new_dead, bb);
    succs: [..] Value_Id; succs.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    while new_dead.count {
        d := pop(*new_dead);
        if gvn_is_in_dead(g, d) continue;
        dom: [..] Value_Id; dom.allocator = temp;
        dt_get_descendants(g.dt, d, *dom);
        for dom gvn_add_dead(g, it);
        for b: dom {
            block_successors(b, *succs);
            for s: succs {
                if gvn_is_in_dead(g, s) continue;
                block_predecessors(s, *preds);
                all_dead := true;
                for p: preds if !gvn_is_in_dead(g, p) { all_dead = false; break; }
                if !all_dead {
                    found := false;
                    for df if it == s { found = true; break; }
                    if !found array_add(*df, s);
                } else array_add(*new_dead, s);
            }
        }
    }
    for b: df {
        if gvn_is_in_dead(g, b) continue;
        pl: [..] Value_Id; pl.allocator = temp;
        block_predecessors(b, *pl);
        for p_in: pl {
            p := p_in;
            if !gvn_is_in_dead(g, p) continue;
            if succ_contains(p, b) && is_critical_edge(block_terminator(p), get_successor_number(p, b)) {
                s := gvn_split_critical_edges_pair(g, p, b);
                if s != NONE { p = s; gvn_add_dead(g, p); }
            }
        }
        block_predecessors(b, *pl);
        for p: pl {
            if !gvn_is_in_dead(g, p) continue;
            for phi: block_insts(b) {
                if inst_op(phi) != .PHI break;
                for k: 0..cast(s64) nops(phi) - 1 if phi_block(phi, cast(u32) k) == p phi_set_value(phi, cast(u32) k, const_poison(vtype(phi)));
                if g.md md_invalidate_cached_pointer_info(g.md, phi);
            }
        }
    }
}
// DominatorTree::getDescendants
dt_get_descendants :: (dt: *Dom_Tree, r: Value_Id, out: *[..] Value_Id) {
    out.count = 0;
    n := dt_node(dt, r);
    if n < 0 return;
    wl: [..] s32; wl.allocator = temp;
    array_add(*wl, n);
    while wl.count {
        x := pop(*wl);
        array_add(out, dt.nodes[x].block);
        c := dt.nodes[x].first_child;
        while c >= 0 { array_add(*wl, c); c = dt.nodes[c].sibling; }
    }
}

// processFoldableCondBr
gvn_process_foldable_cond_br :: (g: *Gvn, bi: Value_Id) -> bool {
    if get_successor(bi, 0) == get_successor(bi, 1) return false;
    c := op(bi, 0);
    if vkind(c) != .C_INT return false;
    dead_root := ifx !is_null_value(c) then get_successor(bi, 1) else get_successor(bi, 0);
    if gvn_is_in_dead(g, dead_root) return false;
    if block_single_predecessor(dead_root) == NONE dead_root = gvn_split_critical_edges_pair(g, inst_block(bi), dead_root);
    gvn_add_dead_block(g, dead_root);
    return true;
}
// assignValNumForDeadCode
gvn_assign_val_num_for_dead_code :: (g: *Gvn) {
    for bb: g.dead_blocks {
        for i: block_insts(bb) {
            n := gvn_lookup_or_add(g, i);
            gvn_leader_insert(g, n, i, bb);
        }
    }
}

// ---------------------------------------------------------------- driver

// processBlock
gvn_process_block :: (g: *Gvn, bb: Value_Id) -> bool {
    if gvn_is_in_dead(g, bb) return false;
    changed := false;
    to_remove: [..] Value_Id; to_remove.allocator = temp;
    changed = eliminate_duplicate_phi_nodes_collect(bb, *to_remove) || changed;
    for to_remove gvn_remove_instruction(g, it);
    for :early_inc i: block_insts(bb) changed = gvn_process_instruction(g, i) || changed;
    return changed;
}
// cleanupGlobalSets
gvn_cleanup_global_sets :: (g: *Gvn) {
    gvn_vt_clear(*g.vn);
    gvn_leader_clear(g);
    table_reset(*g.block_rpo);
    table_reset(*g.icf.first_special);
    g.invalid_block_rpo = true;
}
// iterateOnFunction
gvn_iterate_on_function :: (g: *Gvn) -> bool {
    gvn_cleanup_global_sets(g);
    changed := false;
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(g.f), *po);
    for < po changed = gvn_process_block(g, it) || changed;
    return changed;
}

// runImpl
gvn_run_impl :: (g: *Gvn) -> bool {
    ipt_init(*g.icf, .IMPLICIT_CONTROL_FLOW);
    g.vn_md_enabled = true;
    g.vn_mssa_enabled = gvn_is_memoryssa_enabled(g);
    g.invalid_block_rpo = true;
    if g.mssa { g.mssau_storage.mssa = g.mssa; g.mssau = *g.mssau_storage; }
    changed := false;
    lazy: Lazy_Dtu; lazy.dt = g.dt; lazy.pending.allocator = temp; lazy.deleted.allocator = temp;
    blocks: [..] Value_Id; blocks.allocator = temp;
    for fn_blocks(g.f) array_add(*blocks, it);
    for bb: blocks {
        if vkind(bb) == .DEAD continue;
        if merge_block_into_predecessor(bb, g.dt, g.li, g.mssau, false, *lazy) changed = true;
    }
    lazy_dtu_flush(*lazy);
    while true {
        c := gvn_iterate_on_function(g);
        changed = changed || c;
        if !c break;
    }
    if gvn_is_scalar_pre_enabled(g) {
        gvn_assign_val_num_for_dead_code(g);
        while true {
            c := gvn_perform_pre(g);
            changed = changed || c;
            if !c break;
        }
    }
    gvn_cleanup_global_sets(g);
    g.dead_blocks.count = 0;
    table_reset(*g.dead_set);
    if g.mssa && mssa_opts.verify mssa_verify(g.mssa);
    return changed;
}

// GVNPass::run; `name` = gvn or gvn<...>
gvn_run :: (f: Value_Id, name: string) -> Preserved {
    g := New(Gvn,, allocator = temp);
    g.f = f;
    gvn_parse_options(g, name);
    g.dead_blocks.allocator = temp; g.dead_set.allocator = temp;
    g.leader_heads.allocator = temp; g.leader_nodes.allocator = temp; g.block_rpo.allocator = temp; g.to_split.allocator = temp;
    vt := *g.vn;
    vt.value_numbering.allocator = temp; vt.expr_heads.allocator = temp; vt.expr_entries.allocator = temp;
    vt.expressions.allocator = temp; vt.expr_idx.allocator = temp; vt.numbering_phi.allocator = temp;
    vt.numbering_bb.allocator = temp; vt.phi_translate_table.allocator = temp;
    g.ac = get_assumption_cache(f);
    g.dt = get_domtree(f);
    g.aar = aa_results_for(f);
    if gvn_is_memdep_enabled(g) g.md = md_new(f, g.aar, g.ac, g.dt);
    g.li = get_loop_info(f);
    g.mssa = cached_memoryssa(f);
    if gvn_is_memoryssa_enabled(g) && !g.mssa g.mssa = get_memoryssa(f);
    changed := gvn_run_impl(g);
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    if g.mssa preserve(*pa, .MEMORYSSA);
    preserve(*pa, .LOOPS);
    return pa;
}

// parseGVNOptions
gvn_parse_options :: (g: *Gvn, name: string) {
    if name == "gvn" return;
    if !begins_with(name, "gvn<") || name[name.count - 1] != #char ">" fatal("invalid pass pipeline: unknown pass name '%'", name);
    params := slice(name, 4, name.count - 5);
    while params.count {
        p := params;
        semi := find_index_from_left(params, #char ";");
        if semi >= 0 { p = slice(params, 0, semi); params = slice(params, semi + 1, params.count - semi - 1); }
        else params = "";
        enable: s8 = 1;
        if begins_with(p, "no-") { enable = 0; p = slice(p, 3, p.count - 3); }
        if p == "scalar-pre" g.allow_scalar_pre = enable;
        else if p == "load-pre" g.allow_load_pre = enable;
        else if p == "split-backedge-load-pre" g.allow_load_pre_split_backedge = enable;
        else if p == "memdep" { g.allow_memdep = enable; g.allow_memoryssa = 1 - enable; }
        else if p == "memoryssa" { g.allow_memoryssa = enable; g.allow_memdep = 1 - enable; }
        else fatal("invalid GVN pass parameter '%'", p);
    }
}
