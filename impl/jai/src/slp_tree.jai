// SLPVectorizer: BoUpSLP state — the vectorizable tree (TreeEntry rows), the scalar -> entries maps and the queries
// on them. Ported from llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp (class BoUpSLP: TreeEntry, EdgeInfo,
// getTreeEntries, isVectorized, isDeleted, areAllUsersVectorized, getVectorElementSize, canMapToVector,
// getMinVF/getMaximumVF/getMaxVecRegSize; the BoUpSLP constructor's register-size selection).
//
// WORK IN PROGRESS (L1.vectorize.slp): this file holds the data layout the rest of the BoUpSLP port is meant to
// use; buildTree, scheduling, reordering, the cost model and vectorizeTree are not ported yet. See NOTES.md
// "SLPVectorizer (in progress)".
//
// Layout (DESIGN.md "SLPVectorizer"): a TreeEntry is a row of `slp.entries` addressed by its index (`Te_Id`, =
// TreeEntry::Idx); `UserTreeIndex` is an Edge_Info {user entry, edge}. Pointer-keyed DenseMaps of LLVM are Tables
// keyed by Value_Id / Te_Id; where LLVM iterates such a map the port keeps an explicit insertion-order list.

Te_Id :: s32;
TE_NONE :: cast(Te_Id) -1;
EDGE_NONE :: 0xFFFF_FFFF;   // EdgeInfo::EdgeIdx = UINT_MAX

Edge_Info :: struct {
    user: Te_Id = TE_NONE;
    edge: u32 = EDGE_NONE;
}

TE_VECTORIZE :: 0; TE_SCATTER_VECTORIZE :: 1; TE_STRIDED_VECTORIZE :: 2; TE_EXPAND_VECTORIZE :: 3;
TE_COMPRESS_VECTORIZE :: 4; TE_NEED_TO_GATHER :: 5; TE_COMBINED_VECTORIZE :: 6; TE_SPLIT_VECTORIZE :: 7;

// TreeEntry::CombinedOpcode (MinMax = Instruction::OtherOpsEnd + 1)
TE_NOT_COMBINED :: -1;
TE_MIN_MAX :: 70; TE_FMULADD :: 71; TE_REDUCED_BITCAST :: 72; TE_REDUCED_BITCAST_BSWAP :: 73;
TE_REDUCED_BITCAST_LOADS :: 74; TE_REDUCED_BITCAST_BSWAP_LOADS :: 75; TE_REDUCED_CMP_BITCAST :: 76;

Tree_Entry :: struct {
    scalars: [..] Value_Id;
    vectorized_value: Value_Id = NONE;           // WeakTrackingVH
    state: s32;
    combined_op: s32 = TE_NOT_COMBINED;
    reuse_shuffle_indices: [..] s32;
    reorder_indices: [..] u32;
    user_tree_index: Edge_Info;
    idx: Te_Id;
    combined_entries_with_indices: [..] [2] u32;  // (entry index, offset)
    struct_ev_indices: [..] u32;
    operands: [..] [..] Value_Id;                 // Operands[op_index][lane]
    copyable_elements: [..] Value_Id;             // SmallPtrSet (membership only)
    s: Inst_State;
    interleave_factor: u32;
    does_not_need_to_schedule: bool;
}

Slp_State :: struct {
    f: Value_Id;
    tti: *Tti;
    dt: *Dom_Tree;
    li: *Loop_Info;
    ac: *Assumption_Cache;
    max_vec_reg_size: u64;
    min_vec_reg_size: u64;
    entries: [..] Tree_Entry;                        // VectorizableTree
    scalar_to_tree_entries: Table(Value_Id, [..] Te_Id);
    deleted_nodes: Table(Te_Id, bool);
    transformed_to_gather_nodes: Table(Te_Id, Cost);
    must_gather: Table(Value_Id, bool);
    deleted_instructions: Table(Value_Id, bool);
    analyzed_reduction_roots: Table(Value_Id, bool);
}
slp: Slp_State;

// BoUpSLP(...): MaxVecRegSize / MinVecRegSize (the cl::opts only when given on the command line)
slp_init_reg_sizes :: (max_given: bool, min_given: bool) {
    slp.max_vec_reg_size = ifx max_given then cast(u64) slp_cl.max_reg_size else tti_register_bit_width(slp.tti, RGK_FIXED_WIDTH_VECTOR);
    slp.min_vec_reg_size = ifx min_given then cast(u64) slp_cl.min_reg_size else tti_min_vector_register_bit_width(slp.tti);
}
slp_get_min_vf :: (sz: u64) -> u64 { return max(cast(u64) 2, slp.min_vec_reg_size / sz); }

// getTreeEntries(V)
slp_get_tree_entries :: (v: Value_Id) -> [] Te_Id {
    p := table_find_pointer(*slp.scalar_to_tree_entries, v);
    if !p return .[];
    return p.*;
}
// isVectorized(V)
slp_is_vectorized :: (v: Value_Id) -> bool {
    for slp_get_tree_entries(v) {
        if !table_contains(*slp.deleted_nodes, it) && !table_contains(*slp.transformed_to_gather_nodes, it) return true;
    }
    return false;
}
// isDeleted(I)
slp_is_deleted :: (i: Value_Id) -> bool { return table_contains(*slp.deleted_instructions, i); }
// areAllUsersVectorized(I, VectorizedVals = nullptr)
slp_are_all_users_vectorized :: (i: Value_Id) -> bool {
    if has_one_use(i) return true;
    u := ir.v_first_use[i];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if slp_is_vectorized(usr) || slp_is_vector_like_inst_with_const_ops(usr) ||
           (vc_is_op(usr, .EXTRACTELEMENT) && table_contains(*slp.must_gather, usr)) continue;
        return false;
    }
    return true;
}
// isAnalyzedReductionRoot / analyzedReductionRoot
slp_is_analyzed_reduction_root :: (i: Value_Id) -> bool { return table_contains(*slp.analyzed_reduction_roots, i); }
slp_analyzed_reduction_root :: (i: Value_Id) { table_set(*slp.analyzed_reduction_roots, i, true); }

// canMapToVector(T): the number of elements of a homogeneous aggregate isomorphic to a vector, 0 otherwise
slp_can_map_to_vector :: (t_in: Type_Id) -> u64 {
    n: u64 = 1;
    t := t_in;
    while type_kind(t) == .STRUCT || type_kind(t) == .ARRAY || type_kind(t) == .VECTOR {
        if type_is_empty(t) return 0;
        if type_kind(t) == .STRUCT {
            k := cast(s64) type_nsub(t);
            for j: 0..k-1 if type_sub(t, cast(u32) j) != type_sub(t, 0) return 0;
            n *= cast(u64) k;
            t = type_sub(t, 0);
        } else {
            n *= type_count(t);
            t = type_elem(t);
        }
    }
    if !slp_is_valid_element_type(t) return 0;
    vt_size := dl_type_store_size(slp_widened_type(t, n)) * 8;
    if vt_size < slp.min_vec_reg_size || vt_size > slp.max_vec_reg_size || vt_size != dl_type_store_size(t_in) * 8 return 0;
    return n;
}

