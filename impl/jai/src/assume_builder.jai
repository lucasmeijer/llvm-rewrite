// AssumeBundleBuilder: a port of the knowledge-salvaging half of llvm/lib/Transforms/Utils/AssumeBundleBuilder.cpp
// (-enable-knowledge-retention; isUsefullToPreserve, canonicalizedKnowledge, AssumeBuilderState, buildAssumeFromInst,
// salvageKnowledge) and of GEPOperator::getMaxPreservedAlignment (llvm/lib/IR/Operator.cpp).
// salvageKnowledge takes the AssumptionCache and DominatorTree (tryToPreserveWithoutAddingAssume); the assume-builder
// and assume-simplify passes (AssumeBuilderPass, AssumeSimplify) are at the end of this file.

knowledge_retention: struct {
    enabled := false;    // -enable-knowledge-retention
};

// the passes that honour -enable-knowledge-retention here (the others call salvageKnowledge in ways not ported)
knowledge_retention_check :: (kind: Pass_Kind, name: string) {
    if !knowledge_retention.enabled return;
    // registry_gaps.jai (assume-builder / assume-simplify are this file's; none of the others calls salvageKnowledge)
    if kind == .GAP_MODULE || kind == .GAP_FUNCTION || kind == .GAP_LOOP || kind == .GAP_CGSCC || kind == .NO_OP_LOOPNEST return;
    if kind == .VERIFY_FUNCTION || kind == .VERIFY_MODULE || kind == .REQUIRE_VERIFY return;   // the Verifier
    if kind == .DSE || kind == .EARLY_CSE || kind == .NEWGVN || kind == .SCCP || kind == .IPSCCP || kind == .REQUIRE || kind == .INVALIDATE || kind == .NO_OP_FUNCTION || kind == .NO_OP_MODULE ||
       kind == .MODULE_PM || kind == .FUNCTION_ADAPTOR || kind == .VERIFY_MEMORYSSA || kind == .PRINT_MEMORYSSA return;
    // DCE.cpp and LICM.cpp call salvageKnowledge(I) (no AC); the loop adaptor, LoopRotate and InstCombine never do
    if kind == .DCE || kind == .LICM || kind == .LOOP_ADAPTOR || kind == .LOOP_ROTATE || kind == .INSTCOMBINE || kind == .LOOP_SIMPLIFY || kind == .LCSSA return;
    // IPO passes that never call salvageKnowledge (GlobalOpt.cpp, GlobalDCE.cpp, ConstantMerge.cpp, ...)
    if kind == .GLOBAL_OPT || kind == .GLOBAL_DCE || kind == .CONSTANT_MERGE || kind == .STRIP_DEAD_PROTOTYPES ||
       kind == .ELIM_AVAIL_EXTERN || kind == .INTERNALIZE || kind == .DEAD_ARG_ELIM || kind == .ASSIGN_GUID || kind == .ARG_PROMOTION return;
    // the CFI / devirtualization passes never call salvageKnowledge (LowerTypeTests.cpp, WholeProgramDevirt.cpp,
    // CrossDSOCFI.cpp, GlobalSplit.cpp)
    if kind == .CROSS_DSO_CFI || kind == .GLOBAL_SPLIT || kind == .WHOLE_PROGRAM_DEVIRT || kind == .LOWER_TYPE_TESTS ||
       kind == .DROP_TYPE_TESTS || kind == .SIMPLIFY_TYPE_TESTS return;
    // the coroutine passes never call salvageKnowledge (their InlineFunction calls fail loudly in inline_function.jai)
    if kind == .CORO_EARLY || kind == .CORO_CLEANUP || kind == .CORO_ELIDE || kind == .CORO_SPLIT || kind == .CORO_ANNOTATION_ELIDE || kind == .CORO_COND return;
    // IROutliner.cpp, IRSimilarityIdentifier.cpp and CodeExtractor.cpp never call salvageKnowledge
    if kind == .IR_OUTLINER || kind == .PRINT_IR_SIMILARITY return;
    // the ObjC ARC passes never call salvageKnowledge (lib/Transforms/ObjCARC/*.cpp)
    if kind == .OBJC_ARC || kind == .OBJC_ARC_CONTRACT || kind == .OBJC_ARC_EXPAND || kind == .PA_EVAL return;
    // GuardWidening.cpp, LoopPredication.cpp, LowerGuardIntrinsic.cpp, LowerWidenableCondition.cpp,
    // MakeGuardsExplicit.cpp, Utils/GuardUtils.cpp and InductiveRangeCheckElimination.cpp (+ LoopConstrainer.cpp,
    // ScalarEvolutionExpander.cpp) never call salvageKnowledge
    if kind == .GUARD_WIDENING || kind == .GUARD_WIDENING_LOOP || kind == .LOOP_PREDICATION || kind == .LOWER_GUARD_INTRINSIC ||
       kind == .LOWER_WIDENABLE_CONDITION || kind == .MAKE_GUARDS_EXPLICIT || kind == .IRCE return;
    // LoopFuse.cpp, LoopFlatten.cpp and what they call (CodeMoverUtils, LoopPeel, SimplifyIndVar, LoopVersioning,
    // DependenceAnalysis, LoopAccessAnalysis, BasicBlockUtils) never call salvageKnowledge
    if kind == .LOOP_FUSE || kind == .LOOP_FLATTEN return;
    // LoopVersioning.cpp, LoopBoundSplit.cpp (+ CloneFunction, LoopSimplify) never call salvageKnowledge
    if kind == .LOOP_VERSIONING || kind == .LOOP_BOUND_SPLIT || kind == .LOOP_VERSIONING_LICM || kind == .HARDWARE_LOOPS || kind == .LOOP_UNROLL_AND_JAM return;
    // RewriteStatepointsForGC.cpp never calls salvageKnowledge; PlaceSafepoints only through InlineFunction (which fails
    // loudly in inline_function.jai under the flag)
    if kind == .REWRITE_STATEPOINTS || kind == .PLACE_SAFEPOINTS || kind == .VERIFY_SAFEPOINT_IR return;
    // OpenMPOpt.cpp, Attributor.cpp and OMPIRBuilder.cpp never call salvageKnowledge
    if kind == .OPENMP_OPT || kind == .OPENMP_OPT_CGSCC return;
    // jai_extras_d's passes never call salvageKnowledge (LoadStoreVectorizer.cpp, ...)
    // NaryReassociate.cpp, SeparateConstOffsetFromGEP.cpp and StraightLineStrengthReduce.cpp never call salvageKnowledge
    if kind == .NARY_REASSOCIATE || kind == .SEPARATE_CONST_OFFSET || kind == .SLSR return;
    // KCFI.cpp, LowerAllowCheckPass.cpp, BoundsChecking.cpp, AllocToken.cpp, StackProtector.cpp never call salvageKnowledge
    // (SafeStack.cpp only through InlineFunction, which fails loudly under the flag)
    if kind == .KCFI || kind == .LOWER_ALLOW_CHECK || kind == .BOUNDS_CHECKING || kind == .ALLOC_TOKEN || kind == .STACK_PROTECTOR || kind == .SAFE_STACK return;
    if kind == .LOAD_STORE_VECTORIZER || kind == .CONSTHOIST || kind == .LOWER_ATOMIC || kind == .LOWER_INVOKE || kind == .INDIRECTBR_EXPAND || kind == .INTERLEAVED_ACCESS || kind == .INFER_ADDRESS_SPACES || kind == .GLOBAL_MERGE || kind == .EXPAND_IR_INSTS return;
    // the CGSCC infrastructure and the inliners call salvageKnowledge only through InlineFunction (ported)
    if kind == .CGSCC_ADAPTOR || kind == .CGSCC_PM || kind == .CGSCC_FN_ADAPTOR || kind == .DEVIRT || kind == .NO_OP_CGSCC ||
       kind == .INLINE || kind == .ALWAYS_INLINE || kind == .MODULE_INLINE || kind == .INLINER_WRAPPER || kind == .INLINER_WRAPPER_PM return;
    // LowerMatrixIntrinsics.cpp and MatrixUtils.cpp never call salvageKnowledge
    if kind == .LOWER_MATRIX_INTRINSICS return;
    fatal("-enable-knowledge-retention is not supported with pass '%' yet", name);
}

Ab_Knowledge :: struct { kind: Attr_Kind; arg: u64; was_on: Value_Id = NONE; }

// GEPOperator::getMaxPreservedAlignment
gep_max_preserved_alignment :: (g: Value_Id) -> u64 {
    result: u64 = (cast(u64) 1) << 32;
    min_align :: (a: u64, b: u64) -> u64 { x := a | b; return x & (~x + 1); }
    n := nops(g);
    t := opr_gep_source_type(g);
    prev: Type_Id = NONE;
    for i: 1..cast(s64) n - 1 {
        c := op(g, cast(u32) i);
        if i > 1 { prev = t; t = gep_indexed_type(prev, i, c); }
        offset: u64;
        if i > 1 && type_kind(prev) == .STRUCT {
            offset = dl_struct_offset(prev, cast(u32) ap_zext_value(const_ap(c)));
        } else {
            count: u64 = ifx is_scalar_const_int(c) then ap_limited(const_ap(c)) else 1;   // getLimitedValue()
            offset = gep_seq_stride(ifx i > 1 then prev else NONE, i, t) * count;
        }
        result = min_align(offset, result);
    }
    return result;
}

ab_is_usefull_to_preserve :: (k: Attr_Kind) -> bool {
    return k == .NonNull || k == .NoUndef || k == .Alignment || k == .Dereferenceable || k == .DereferenceableOrNull || k == .Cold;
}
ab_is_int_attr_kind :: (k: Attr_Kind) -> bool { return k == .Alignment || k == .Dereferenceable || k == .DereferenceableOrNull; }

// canonicalizedKnowledge
ab_canonicalized_knowledge :: (rk_in: Ab_Knowledge) -> Ab_Knowledge {
    rk := rk_in;
    if rk.kind == .NonNull { rk.was_on = strip_in_bounds_offsets(rk.was_on); return rk; }
    if rk.kind == .Alignment {
        // stripInBoundsOffsets with a callback on every visited value
        v := rk.was_on;
        visited: [..] Value_Id; visited.allocator = temp;
        array_add(*visited, v);
        while true {
            if opr_code(v) == .GEP {
                x := rk.arg | gep_max_preserved_alignment(v);
                rk.arg = x & (~x + 1);
            }
            nv := strip_pointer_casts_one_step_in_bounds(v);
            if nv == v break;
            v = nv;
            seen := false;
            for visited if it == v { seen = true; break; }
            if seen break;
            array_add(*visited, v);
        }
        rk.was_on = v;
        return rk;
    }
    if rk.kind == .Dereferenceable || rk.kind == .DereferenceableOrNull {
        off := ap_zero(dl_index_type_size_bits(vtype(rk.was_on)));
        base, o := strip_and_accumulate_constant_offsets(rk.was_on, off, false);
        offset := ap_sext_value(o);
        if offset < 0 return rk;
        rk.arg = rk.arg + cast(u64) offset;
        rk.was_on = base;
    }
    return rk;
}
// one step of stripPointerCastsAndOffsets<PSK_InBounds> (returns v when it cannot be stripped)
strip_pointer_casts_one_step_in_bounds :: (v: Value_Id) -> Value_Id {
    if !is_ptr_type(vtype(v)) return v;
    o := opr_code(v);
    if o == .GEP { if (opr_flags(v) & F_INBOUNDS) == 0 return v; return op(v, 0); }
    if o == .BITCAST { nv := op(v, 0); if !is_ptr_type(vtype(nv)) return v; return nv; }
    if o == .ADDRSPACECAST return op(v, 0);
    if is_inst(v) && is_call_base(v) { rv := call_returned_arg(v); if rv != NONE return rv; }
    return v;
}

Assume_Builder :: struct {
    inst_being_modified: Value_Id = NONE;
    ac: *Assumption_Cache;     // salvageKnowledge(I, AC, DT): tryToPreserveWithoutAddingAssume
    dt: *Dom_Tree;
    keys: [..] Ab_Knowledge;   // SmallMapVector<(WasOn, Kind), ArgValue>: insertion order
}

ab_is_knowledge_worth_preserving :: (b: *Assume_Builder, rk: Ab_Knowledge) -> bool {
    if rk.was_on == NONE return true;
    if is_ptr_type(vtype(rk.was_on)) {
        u := get_underlying_object(rk.was_on);
        if (is_inst(u) && inst_op(u) == .ALLOCA) || is_global_value(vkind(u)) return false;
    }
    if vkind(rk.was_on) == .ARGUMENT {
        at := attr_set_find(arg_attrs(rk.was_on), rk.kind);
        if at && (!ab_is_int_attr_kind(rk.kind) || at.ival >= rk.arg) return false;
        return true;
    }
    if is_inst(rk.was_on) && would_instruction_be_trivially_dead(rk.was_on, false) {   // TLI = nullptr
        if !has_uses(rk.was_on) return false;
        single: Use_Id = NONE;
        u := ir.v_first_use[rk.was_on];
        multiple := false;
        while u != NONE {
            usr := ir.u_user[u];
            droppable := is_inst(usr) && inst_op(usr) == .CALL &&
                         (call_iid(usr) == IID_ASSUME || intrinsic_id_of_call(usr) == "llvm.pseudoprobe" ||
                          intrinsic_id_of_call(usr) == "llvm.experimental.noalias.scope.decl");
            if !droppable { if single != NONE { multiple = true; break; } single = u; }
            u = ir.u_next[u];
        }
        if !multiple && single != NONE && ir.u_user[single] == b.inst_being_modified return false;
    }
    return true;
}

ab_add_knowledge :: (b: *Assume_Builder, rk_in: Ab_Knowledge) {
    rk := ab_canonicalized_knowledge(rk_in);
    if !ab_is_knowledge_worth_preserving(b, rk) return;
    if ab_try_to_preserve_without_adding_assume(b, rk) return;
    for * b.keys if it.was_on == rk.was_on && it.kind == rk.kind { it.arg = max(it.arg, rk.arg); return; }
    array_add(*b.keys, rk);
}
// getKnowledgeFromBundle(Assume, BOI)
ab_knowledge_from_bundle :: (assume: Value_Id, k: u32) -> Ab_Knowledge {
    rk: Ab_Knowledge;
    rk.kind = attr_kind_from_name(call_bundle_tag(assume, k));
    begin := ir.u32_pool[inst(assume).idx + 3 * k + 1];
    end := ir.u32_pool[inst(assume).idx + 3 * k + 2];
    if end > begin rk.was_on = op(assume, begin);
    arg_or :: (assume: Value_Id, begin: u32, end: u32, idx: u32, default: u64) -> u64 {
        c := op(assume, begin + 1 + idx);
        if vkind(c) == .C_INT && !is_vector_type(vtype(c)) return ap_zext_value(const_ap(c));
        return default;
    }
    if end - begin > 1 {
        if rk.kind == {
            case .Alignment; rk.arg = arg_or(assume, begin, end, 0, 1);
            case .Dereferenceable; #through;
            case .DereferenceableOrNull; rk.arg = arg_or(assume, begin, end, 0, 0);
            case .NONE_ATTR; rk.arg = 0;
            case; fatal("internal: assume bundle '%' has an argument", call_bundle_tag(assume, k));
        }
    }
    if rk.kind == .Alignment && end - begin > 2 {
        a := rk.arg | arg_or(assume, begin, end, 1, 1);
        rk.arg = a & (~a + 1);   // MinAlign
    }
    return rk;
}

// tryToPreserveWithoutAddingAssume (getKnowledgeForValue over AC.assumptionsFor(WasOn))
ab_try_to_preserve_without_adding_assume :: (b: *Assume_Builder, rk: Ab_Knowledge) -> bool {
    if b.inst_being_modified == NONE || rk.was_on == NONE || !b.ac return false;
    for e: ac_assumptions_for(b.ac, rk.was_on) {
        if vkind(e.assume) == .DEAD || e.index == AC_EXPR_RESULT_IDX continue;
        other := ab_knowledge_from_bundle(e.assume, e.index);
        if other.kind == .NONE_ATTR continue;   // RetainedKnowledge's operator bool
        if rk.was_on != other.was_on continue;
        if other.kind != rk.kind continue;
        if !is_valid_assume_for_context(e.assume, b.inst_being_modified, b.dt) continue;
        if other.arg >= rk.arg return true;
        if is_valid_assume_for_context(b.inst_being_modified, e.assume, b.dt) {
            begin := ir.u32_pool[inst(e.assume).idx + 3 * e.index + 1];
            set_op(e.assume, begin + 1, const_int(ir.t_i64, rk.arg));   // ABA_Argument
            return true;
        }
    }
    return false;
}

ab_add_attribute :: (b: *Assume_Builder, a: Attr, was_on: Value_Id) {
    if a.kind == .STRING_ATTR || a.ty != NONE || !ab_is_usefull_to_preserve(a.kind) return;
    arg: u64 = ifx ab_is_int_attr_kind(a.kind) then a.ival else 0;
    ab_add_knowledge(b, .{a.kind, arg, was_on});
}
ab_add_call :: (b: *Assume_Builder, c: Value_Id) {
    add_attr_list :: (b: *Assume_Builder, c: Value_Id, l: u32, nargs: u32) {
        if nargs > 0 for idx: 0..nargs - 1 {
            for attr_set_items(attr_list_param(l, idx)) {
                is_poison_attr := it.kind == .NonNull || it.kind == .Alignment;
                passing_undef_ub := call_param_has_attr(c, idx, .NoUndef) || call_param_has_attr(c, idx, .Dereferenceable) ||
                                    call_param_has_attr(c, idx, .DereferenceableOrNull);
                if !is_poison_attr || passing_undef_ub ab_add_attribute(b, it, call_arg(c, idx));
            }
        }
        for attr_set_items(attr_list_fn(l)) ab_add_attribute(b, it, NONE);
    }
    add_attr_list(b, c, inst(c).attrs, call_num_args(c));
    f := call_called_function(c);
    if f != NONE add_attr_list(b, c, glob(f).attrs, glob(f).nargs);
}
ab_add_accessed_ptr :: (b: *Assume_Builder, mem_inst: Value_Id, ptr: Value_Id, acc_ty: Type_Id, align: u64) {
    deref := dl_type_store_size(acc_ty);
    if deref != 0 {
        ab_add_knowledge(b, .{.Dereferenceable, deref, ptr});
        if !null_pointer_is_defined(inst_fn(mem_inst), type_addrspace(vtype(ptr))) ab_add_knowledge(b, .{.NonNull, 0, ptr});
    }
    if max(align, 1) > 1 ab_add_knowledge(b, .{.Alignment, align, ptr});
}
ab_add_instruction :: (b: *Assume_Builder, i: Value_Id) {
    o := inst_op(i);
    if is_call_base(i) { ab_add_call(b, i); return; }
    if o == .LOAD { ab_add_accessed_ptr(b, i, op(i, 0), vtype(i), inst(i).align); return; }
    if o == .STORE { ab_add_accessed_ptr(b, i, op(i, 1), vtype(op(i, 0)), inst(i).align); return; }
    if o == .ATOMICRMW { ab_add_accessed_ptr(b, i, op(i, 0), vtype(op(i, 1)), inst(i).align); return; }
    if o == .CMPXCHG { ab_add_accessed_ptr(b, i, op(i, 0), vtype(op(i, 1)), inst(i).align); return; }
}
// build(): an unlinked `call void @llvm.assume(i1 true) [ bundles ]`, or NONE
ab_build :: (b: *Assume_Builder) -> Value_Id {
    if b.keys.count == 0 return NONE;
    f := get_or_insert_intrinsic_declaration(IID_ASSUME);
    nb := 0;
    for b.keys { if it.was_on != NONE nb += 1; if it.arg != 0 nb += 1; }
    i := new_inst(.CALL, ir.t_void, cast(u32)(1 + nb + 1));
    r := inst(i);
    r.ty2 = glob(f).value_type;
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) b.keys.count;
    pos: u32 = 1;
    for b.keys {
        array_add(*ir.u32_pool, bundle_tag_id(attr_name(it.kind)));
        array_add(*ir.u32_pool, pos);
        if it.was_on != NONE pos += 1;
        if it.arg != 0 pos += 1;
        array_add(*ir.u32_pool, pos);
    }
    set_op(i, 0, const_int(ir.t_i1, 1));
    set_op(i, cast(u32)(1 + nb), f);
    k: u32 = 1;
    for b.keys {
        if it.was_on != NONE { set_op(i, k, it.was_on); k += 1; }
        if it.arg != 0 { set_op(i, k, const_int(ir.t_i64, it.arg)); k += 1; }
    }
    return i;
}

// salvageKnowledge(I, AC, DT); AC and DT may be null
salvage_knowledge :: (i: Value_Id, ac: *Assumption_Cache = null, dt: *Dom_Tree = null) -> bool {
    if !knowledge_retention.enabled || is_terminator(inst_op(i)) return false;
    b: Assume_Builder; b.inst_being_modified = i; b.keys.allocator = temp; b.ac = ac; b.dt = dt;
    ab_add_instruction(*b, i);
    a := ab_build(*b);
    if a == NONE return false;
    insert_at_position(a, inst_block(i), i, false);
    if ac ac_register_assumption(ac, a);
    return true;
}

// ---------------------------------------------------------------- AssumeBuilderPass, AssumeSimplifyPass

// AssumeBuilderPass::run: salvageKnowledge(&I, AC, DT) for every instruction (DT: the cached tree). LLVM forgets the
// `return` in `if (!Changed) PreservedAnalyses::all();`, so the result is always "CFG preserved".
assume_builder_run :: (f: Value_Id) -> Preserved {
    ac := get_assumption_cache(f);
    dt := cached_domtree(f);
    for :early_inc i: fn_insts(f) salvage_knowledge(i, ac, dt);
    return preserved_cfg();
}

// AssumeSimplifyPass::run
assume_simplify_run :: (f: Value_Id) -> Preserved {
    if !knowledge_retention.enabled return PRESERVE_ALL;
    s: Assume_Simplify;
    s.f = f;
    s.ac = get_assumption_cache(f);
    s.dt = cached_domtree(f);
    s.cleanup.allocator = temp;
    // simplifyAssumes
    asm_drop_redundant_knowledge(*s);
    asm_run_cleanup(*s, false);
    asm_merge_assumes(*s);
    asm_run_cleanup(*s, true);
    if !s.made_change return PRESERVE_ALL;
    return preserved_cfg();
}

Assume_Simplify :: struct {
    f: Value_Id;
    ac: *Assumption_Cache;
    dt: *Dom_Tree;
    cleanup: [..] Value_Id;   // SmallDenseSet<IntrinsicInst *> CleanupToDo (erasing is order independent)
    made_change: bool;
    // BBToAssume: SmallDenseMap<BasicBlock *, SmallVector<IntrinsicInst *, 4>>; `bbs` keeps first-insertion order
    bbs: [..] Value_Id;
    by_bb: Table(Value_Id, [..] Value_Id);
}

asm_cleanup_insert :: (s: *Assume_Simplify, a: Value_Id) { array_add_if_unique(*s.cleanup, a); }

// buildMapping
asm_build_mapping :: (s: *Assume_Simplify, filter_boolean_argument: bool) {
    nb: [..] Value_Id; nb.allocator = temp; s.bbs = nb;
    nt: Table(Value_Id, [..] Value_Id); nt.allocator = temp; s.by_bb = nt;
    for v: ac_assumptions(s.ac).* {
        if v == NONE || vkind(v) == .DEAD continue;
        if filter_boolean_argument {
            a := op(v, 0);
            if vkind(a) != .C_INT || is_null_value(a) continue;
        }
        bb := inst_block(v);
        l := table_find_pointer(*s.by_bb, bb);
        if !l {
            e: [..] Value_Id; e.allocator = temp;
            table_set(*s.by_bb, bb, e);
            l = table_find_pointer(*s.by_bb, bb);
            array_add(*s.bbs, bb);
        }
        array_add(l, v);
    }
    for bb: s.bbs {
        l := table_find_pointer(*s.by_bb, bb);
        // llvm::sort by comesBefore (a strict order within one block: any sort gives the same result)
        quick_sort(l.*, (a: Value_Id, b: Value_Id) -> s64 { if a == b return 0; return ifx comes_before(a, b) then -1 else 1; });
    }
}

// RunCleanup
asm_run_cleanup :: (s: *Assume_Simplify, force: bool) {
    for a: s.cleanup {
        if vkind(a) == .DEAD continue;
        c := op(a, 0);
        if vkind(c) != .C_INT || is_null_value(c) || (!force && !is_assume_with_empty_bundle(a)) continue;
        s.made_change = true;
        erase_inst_with_metadata(a);
    }
    s.cleanup.count = 0;
}

// the BundleOpInfo fields of bundle k: (tag, begin, end) in u32_pool
asm_bundle_begin :: (a: Value_Id, k: u32) -> u32 { return ir.u32_pool[inst(a).idx + 3 * k + 1]; }
asm_bundle_end :: (a: Value_Id, k: u32) -> u32 { return ir.u32_pool[inst(a).idx + 3 * k + 2]; }

// dropRedundantKnowledge
asm_drop_redundant_knowledge :: (s: *Assume_Simplify) {
    Map_Value :: struct { assume: Value_Id; arg: u64; k: u32; }
    asm_build_mapping(s, false);
    Key :: struct { v: Value_Id; kind: Attr_Kind; }
    knowledge: [..] struct { key: Key; vals: [..] Map_Value; }; knowledge.allocator = temp;
    lookup :: (kn: *type_of(knowledge), key: Key) -> *[..] Map_Value {
        for * kn.* if it.key.v == key.v && it.key.kind == key.kind return *it.vals;
        e: type_of(kn.*[0]); e.key = key; e.vals.allocator = temp;
        array_add(kn, e);
        return *kn.*[kn.count - 1].vals;
    }
    ignore_tag := bundle_tag_id("ignore");
    entry_ip := block_first_insertion_pt(fn_entry(s.f));
    order: [..] Value_Id; order.allocator = temp;
    sl_depth_first(s.f, *order);   // depth_first(&F)
    for bb: order {
        l := table_find_pointer(*s.by_bb, bb);
        if !l continue;
        for assume: l.* {
            nb := inst(assume).nidx;
            for k: 0..cast(s64) nb - 1 {
                bk := cast(u32) k;
                remove_from_assume :: (s: *Assume_Simplify, assume: Value_Id, bk: u32, ignore_tag: u32) {
                    asm_cleanup_insert(s, assume);
                    b := asm_bundle_begin(assume, bk); e := asm_bundle_end(assume, bk);
                    if b != e set_op(assume, b, const_poison(vtype(op(assume, b))));   // ABA_WasOn
                    ir.u32_pool[inst(assume).idx + 3 * bk] = ignore_tag;
                }
                if ir.u32_pool[inst(assume).idx + 3 * bk] == ignore_tag { asm_cleanup_insert(s, assume); continue; }
                rk := ab_knowledge_from_bundle(assume, bk);
                if rk.was_on != NONE && vkind(rk.was_on) == .ARGUMENT {
                    arg := rk.was_on;
                    at := attr_set_find(arg_attrs(arg), rk.kind);
                    has_same := at != null;
                    if has_same && (!ab_is_int_attr_kind(rk.kind) || at.ival >= rk.arg) {
                        remove_from_assume(s, assume, bk, ignore_tag);
                        continue;
                    }
                    if is_valid_assume_for_context(assume, entry_ip, null) || assume == entry_ip {
                        if has_same arg_remove_attr(arg, rk.kind);
                        na: Attr; na.kind = rk.kind; na.ty = NONE;
                        if ab_is_int_attr_kind(rk.kind) na.ival = rk.arg;
                        arg_add_attr(arg, na);
                        s.made_change = true;
                        remove_from_assume(s, assume, bk, ignore_tag);
                        continue;
                    }
                }
                vals := lookup(*knowledge, .{rk.was_on, rk.kind});
                for * elem: vals.* {
                    if !is_valid_assume_for_context(elem.assume, assume, s.dt) continue;
                    if elem.arg >= rk.arg {
                        remove_from_assume(s, assume, bk, ignore_tag);
                        continue;   // (LLVM continues the inner loop)
                    } else if is_valid_assume_for_context(assume, elem.assume, s.dt) {
                        set_op(elem.assume, asm_bundle_begin(elem.assume, elem.k) + 1, const_int(ir.t_i64, rk.arg));   // ABA_Argument
                        s.made_change = true;
                        remove_from_assume(s, assume, bk, ignore_tag);
                        continue;
                    }
                }
                array_add(vals, .{assume, rk.arg, bk});
            }
        }
    }
}

// mergeRange
asm_merge_range :: (s: *Assume_Simplify, bb: Value_Id, range: [] Value_Id) {
    if range.count < 2 return;
    b: Assume_Builder; b.keys.allocator = temp;
    ip := block_first_non_phi(bb);
    head := true;   // getFirstNonPHIIt() has the head bit; every iterator derived below does not
    if inst_op(ip) == .LANDINGPAD { ip = inst(ip).next; head = false; }
    for a: range {
        asm_cleanup_insert(s, a);
        for k: 0..cast(s64) inst(a).nidx - 1 {
            rk := ab_knowledge_from_bundle(a, cast(u32) k);
            if rk.kind == .NONE_ATTR continue;   // !RK
            ab_add_knowledge(*b, rk);
            if rk.was_on != NONE && is_inst(rk.was_on) {
                w := rk.was_on;
                if inst_block(w) == inst_block(ip) && (comes_before(ip, w) || ip == w) { ip = inst(w).next; head = false; }
            }
        }
    }
    if comes_before(ip, range[0]) {
        x := range[0];
        while x != ip {
            if !is_guaranteed_to_transfer_execution(x) { ip = inst(x).next; head = false; break; }
            x = inst(x).prev;
        }
    }
    m := ab_build(*b);
    if m == NONE return;
    s.made_change = true;
    insert_at_position(m, inst_block(ip), ip, head);   // MergedAssume->insertBefore(InsertPt)
    ac_register_assumption(s.ac, m);
}

// mergeAssumes. BBToAssume is walked in pointer order in LLVM; each block's merge only touches that block, so the
// block order is not visible in the IR (only in the AssumptionCache's order, which no later output reads here).
asm_merge_assumes :: (s: *Assume_Simplify) {
    asm_build_mapping(s, true);
    for bb: s.bbs {
        l := table_find_pointer(*s.by_bb, bb).*;
        if l.count < 2 continue;
        splits: [..] s64; splits.allocator = temp;
        array_add(*splits, 0);
        last := 0;
        x := l[0];
        e := l[l.count - 1];
        while x != e {
            if !is_guaranteed_to_transfer_execution(x) {
                while comes_before(l[last], x) last += 1;
                if splits[splits.count - 1] != last array_add(*splits, last);
            }
            x = inst(x).next;
        }
        array_add(*splits, l.count);
        for k: 0..splits.count - 2 {
            r: [] Value_Id; r.data = l.data + splits[k]; r.count = splits[k + 1] - splits[k];
            asm_merge_range(s, bb, r);
        }
    }
}
