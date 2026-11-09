// SLPVectorizer: BoUpSLP entry points used by the pass driver. Ported from
// llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp (the BoUpSLP constructor, getVectorElementSize,
// getMaximumVF, clearReductionData / analyzed reduction values, isAnyGathered / isGathered / isNotScheduled,
// getMainAltOpsNoStateVL, canBuildSplitNode, ::getScalarizationOverhead) and X86TTIImpl::getStoreMinimumVF /
// BasicTTIImplBase::getStoreMinimumVF.
//
// WORK IN PROGRESS: the procedures below that call slp_fail are the frontier of the port (see NOTES.md).

// TTI::VectorInstrContext
VIC_NONE :: 0; VIC_LOAD :: 1; VIC_STORE :: 2;

Slp_Extra :: struct {
    f: Value_Id;
    aar: Aa_Results;
    db: *Demanded_Bits;
    eph_values: Table(Value_Id, bool);
    instr_element_size: Table(Value_Id, u64);
    analyzed_reduction_vals: [..] string;      // DenseSet<hash_code(VL)>: the joined value ids
    non_scheduled_first: Table(Value_Id, bool);
    base_graph_size: u32 = 1;
    // buildTree state (slp_build_tree.jai, slp_sched.jai)
    block_schedules: [..] *Block_Sched;           // MapVector<BasicBlock *, BlockScheduling>
    cur_bundle_sched: *Block_Sched;
    alias_cache: Table(u64, bool);
    batch_aa: *Aa_Query;
    operands_to_tree_entry: Table(u64, Te_Id);    // (user entry, edge) -> entry
    scalars_in_split_nodes: Table(Value_Id, [..] Te_Id);
    value_to_gather_nodes: Table(Value_Id, [..] Te_Id);
    load_entries_to_vectorize: [..] u32;
    is_graph_transform_mode: bool;
    gathered_loads_first: s64 = -1;
    current_loop_nest: [..] Loop_Id;
    merged_loop_btcs: [..] Scev_Id;
    has_cast_max_min_bw: bool;
    cast_max_bw: u64;
    cast_min_bw: u64;
    extra_bitwidth_nodes: [..] Te_Id;
    known_non_vectorizable_loads: [..] string;
    has_user_ignore_list: bool;
    user_ignore_list: [] Value_Id;
    entry_to_last_instruction: Table(Te_Id, Value_Id);
    phi_cmp_te: Te_Id;                            // state of getReorderingData's PHICompare
    phi_cmp_heads: [] Value_Id;
}
slpx: Slp_Extra;

// BoUpSLP(...)
slp_init :: (f: Value_Id, tti: *Tti, aar: Aa_Results, li: *Loop_Info, dt: *Dom_Tree, ac: *Assumption_Cache, db: *Demanded_Bits) {
    slp = .{};
    slp.f = f; slp.tti = tti; slp.dt = dt; slp.li = li; slp.ac = ac;
    slp.entries.allocator = temp;
    slp.scalar_to_tree_entries.allocator = temp;
    slp.deleted_nodes.allocator = temp;
    slp.transformed_to_gather_nodes.allocator = temp;
    slp.must_gather.allocator = temp;
    slp.deleted_instructions.allocator = temp;
    slp.analyzed_reduction_roots.allocator = temp;
    slpx = .{};
    slpx.f = f; slpx.aar = aar; slpx.db = db;
    slpx.eph_values.allocator = temp;
    slpx.instr_element_size.allocator = temp;
    slpx.analyzed_reduction_vals.allocator = temp;
    slpx.non_scheduled_first.allocator = temp;
    slpx.block_schedules.allocator = temp; slpx.alias_cache.allocator = temp;
    slpx.operands_to_tree_entry.allocator = temp; slpx.scalars_in_split_nodes.allocator = temp;
    slpx.value_to_gather_nodes.allocator = temp; slpx.load_entries_to_vectorize.allocator = temp;
    slpx.current_loop_nest.allocator = temp; slpx.merged_loop_btcs.allocator = temp;
    slpx.extra_bitwidth_nodes.allocator = temp; slpx.known_non_vectorizable_loads.allocator = temp;
    slpx.batch_aa = aa_query_new(*slpx.aar);
    slpx.entry_to_last_instruction.allocator = temp;
    collect_ephemeral_values_fn(f, ac, *slpx.eph_values);
    slp_init_reg_sizes(slp_cl.max_reg_size_given, slp_cl.min_reg_size_given);
}
// ~BoUpSLP
slp_finish :: () {
    vh_release_all();
}

// getMaximumVF(ElemWidth, Opcode): X86 has no getMaximumVF override (0 = no limit)
slp_get_maximum_vf :: (elem_width: u64, opc: Opcode) -> u64 {
    max_vf: u64 = ifx slp_cl.max_vf_given then cast(u64) slp_cl.max_vf else 0;
    return ifx max_vf != 0 then max_vf else 0xFFFF_FFFF;
}

// clearReductionData
slp_clear_reduction_data :: () {
    table_reset(*slp.analyzed_reduction_roots);
    array_reset_keeping_memory(*slpx.analyzed_reduction_vals);
    slp_clear_analyzed_min_bw_vals();
}
slp_vl_key :: (vl: [] Value_Id) -> string {
    sb: String_Builder; sb.allocator = temp;
    for vl print_to_builder(*sb, "%,", it);
    return builder_to_string(*sb,, temp);
}
slp_are_analyzed_reduction_vals :: (vl: [] Value_Id) -> bool {
    k := slp_vl_key(vl);
    for slpx.analyzed_reduction_vals if it == k return true;
    return false;
}
slp_analyzed_reduction_vals :: (vl: [] Value_Id) {
    if !slp_are_analyzed_reduction_vals(vl) array_add(*slpx.analyzed_reduction_vals, slp_vl_key(vl));
}
slp_is_any_gathered :: (vals: [] Value_Id) -> bool {
    for vals if table_contains(*slp.must_gather, it) return true;
    return false;
}
slp_is_gathered :: (v: Value_Id) -> bool { return table_contains(*slp.must_gather, v); }
slp_is_not_scheduled :: (v: Value_Id) -> bool { return table_contains(*slpx.non_scheduled_first, v); }
slp_canonical_graph_size :: () -> u32 { return slpx.base_graph_size; }

// getVectorElementSize(V)
slp_get_vector_element_size :: (v_in: Value_Id) -> u64 {
    v := v_in;
    if is_inst(v) && inst_op(v) == .STORE return dl_type_size_bits(vtype(op(v, 0)));
    if is_inst(v) && inst_op(v) == .INSERTELEMENT return slp_get_vector_element_size(op(v, 1));
    found, w := table_find(*slpx.instr_element_size, v);
    if found return w;
    Item :: struct { i: Value_Id; parent: Value_Id; level: s64; }
    worklist: [..] Item; worklist.allocator = temp;
    visited: [..] Value_Id; visited.allocator = temp;   // SmallPtrSet; iteration order does not matter here
    visited_set: Table(Value_Id, bool); visited_set.allocator = temp;
    if is_inst(v) {
        array_add(*worklist, .{v, inst_block(v), 0});
        array_add(*visited, v); table_set(*visited_set, v, true);
    }
    width: u64 = 0;
    first_non_bool: Value_Id = NONE;
    i1 := type_int(1);
    while worklist.count {
        top := pop(*worklist);
        i := top.i;
        ty := vtype(i);
        if is_vector_type(ty) || type_kind(ty) == .SVECTOR continue;
        if ty != i1 && first_non_bool == NONE first_non_bool = i;
        if top.level > slp_cl.recursion_max_depth continue;
        o := inst_op(i);
        id := call_iid(i);
        compatible_intrinsic := id == IID_ABS || id == IID_FABS || id == IID_FMA || id == IID_FMULADD;
        if o == .LOAD || o == .EXTRACTELEMENT || o == .EXTRACTVALUE {
            width = max(width, dl_type_size_bits(ty));
        } else if o == .PHI || is_cast_op(o) || o == .GEP || o == .ICMP || o == .FCMP || o == .SELECT || is_binary_op(o) || o == .FNEG || compatible_intrinsic {
            for k: 0..cast(s64) nops(i) - 1 {
                j := op(i, cast(u32) k);
                if is_inst(j) && !table_contains(*visited_set, j) {
                    table_set(*visited_set, j, true); array_add(*visited, j);
                    if o == .PHI || inst_block(j) == top.parent {
                        array_add(*worklist, .{j, inst_block(j), top.level + 1});
                        continue;
                    }
                }
                if first_non_bool == NONE && vtype(j) != i1 first_non_bool = j;
            }
        } else break;
    }
    if width == 0 {
        if vtype(v) == i1 && first_non_bool != NONE v = first_non_bool;
        width = dl_type_size_bits(vtype(v));
    }
    for visited table_set(*slpx.instr_element_size, it, width);
    return width;
}

// getMainAltOpsNoStateVL(VL)
slp_main_alt_ops_no_state_vl :: (vl: [] Value_Id) -> (Value_Id, Value_Id) {
    main: Value_Id = NONE; alt: Value_Id = NONE;
    for v: vl {
        if pm_poison(v) continue;
        if !is_inst(v) return NONE, NONE;
        if main == NONE { main = v; continue; }
        if inst_op(main) == inst_op(v) { if inst_block(v) != inst_block(main) return NONE, NONE; continue; }
        if alt == NONE { alt = v; continue; }
        if inst_op(alt) == inst_op(v) { if inst_block(v) != inst_block(alt) return NONE, NONE; continue; }
        return NONE, NONE;
    }
    if alt == NONE return NONE, NONE;
    return main, alt;
}

// ::getScalarizationOverhead(TTI, ScalarTy, Ty, DemandedElts, Insert, Extract, CostKind, ForPoisonSrc, VL, VIC)
slp_get_scalarization_overhead :: (sty: Type_Id, ty: Type_Id, dem: [] bool, insert: bool, extract: bool, kind: s64,
                                   for_poison_src := true, vl: [] Value_Id = .[], vic := VIC_NONE) -> Cost {
    if is_vector_type(sty) slp_fail("REVEC scalarization overhead");
    if vic != VIC_NONE && slp.tti.kind == .X86 slp_check_vic_neutral(vic);
    return tti_scalarization_overhead(slp.tti, ty, dem, insert, extract, kind, for_poison_src, vl);
}
// The VectorInstrContext hint only changes X86's cost of an extract feeding a store / insert of a load when the
// element is the scalar memory operand of a combined instruction; the jai X86 cost tables ignore it.
slp_check_vic_neutral :: (vic: s64) {}

// TTI::getStoreMinimumVF(VF, ScalarMemTy, ScalarValTy, Alignment, AddrSpace)
tti_store_minimum_vf :: (t: *Tti, vf_in: u64, mem_ty: Type_Id, val_ty: Type_Id) -> u64 {
    if t.kind != .X86 return vf_in;
    st := *t.xl;
    if st_hasF16C(st) && type_kind(mem_ty) == .HALF return 4;
    vf := vf_in;
    supported :: (st: *X86_Lowering, vf: u64, mem_ty: Type_Id, val_ty: Type_Id) -> bool {
        src_ty := type_vector(vf / 2, mem_ty, false);
        vt := x86_evt(st, src_ty);
        if evt_is_simple(vt) && (is_op_legal(st, ISD_STORE, vt.m) || xl_op_action(st, ISD_STORE, vt.m) == LA_CUSTOM) return true;   // isOperationCustom has no type check
        val_vt := x86_evt(st, type_vector(vf / 2, val_ty, false));
        legal_vt := xl_type_to_transform_to(st, vt);
        if !evt_is_simple(legal_vt) || !evt_is_simple(val_vt) return false;
        return is_type_legal_mvt(st, legal_vt.m) && xl_trunc_store_action(st, legal_vt.m, val_vt.m) == LA_LEGAL;
    }
    while vf > 2 && supported(st, vf, mem_ty, val_ty) vf /= 2;
    return vf;
}

// ---------------------------------------------------------------- the frontier (not ported yet)

slp_transform_nodes :: () { slp_fail("transformNodes"); }
slp_compute_minimum_value_sizes :: () { slp_fail("computeMinimumValueSizes"); }
slp_clear_analyzed_min_bw_vals :: () {}
slp_delete_tree_later_state :: () {   // the deleteTree members of later stages
    table_reset(*slpx.entry_to_last_instruction);
}
slp_calculate_tree_cost_and_trim_non_profitable :: () -> Cost { slp_fail("calculateTreeCostAndTrimNonProfitable"); return 0; }
slp_build_external_uses :: () { slp_fail("buildExternalUses"); }
slp_get_tree_cost :: (tree_cost: Cost) -> Cost { slp_fail("getTreeCost"); return 0; }
slp_vectorize_tree :: () { slp_fail("vectorizeTree"); }
slp_optimize_gather_sequence :: () { slp_fail("optimizeGatherSequence"); }
