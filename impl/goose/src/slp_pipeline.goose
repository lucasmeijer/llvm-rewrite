// SLPVectorizer: what the seeds run on a tree that is not tiny, in LLVM's order: isProfitableToReorder,
// reorderTopToBottom, reorderBottomToTop, transformNodes, computeMinimumValueSizes, then the cost model (not ported
// yet: fails loudly). Called from vectorizeStoreChain / tryToVectorizeList (slp_stores.goose) and
// HorizontalReduction::tryToReduce (slp_hr.goose).
import std;
import ir;
import irutil;
import instinfo;
import slp_util;
import slp_tree;
import slp_reorder;
import slp_transform;
import slp_minbw;
import slp_bvcost;
import slp_entrycost;
import slp_treecost;

fn slp_cost_model_not_ported() { slp_fail("BoUpSLP's cost model (calculateTreeCostAndTrimNonProfitable / getTreeCost)"); }
fn slp_vectorize_tree_not_ported() { slp_fail("BoUpSLP::vectorizeTree (codegen)"); }
fn slp_print_found_cost(c: i64, vf: i64) {
    if slp_dbg_on { errs("SLP: Found cost = "); slp_errs_cost(c); errs(" for VF="); errs_int(vf); errs("\n"); slp_dbg_flush(); }
}
// the costs of a store chain or list tree: (TreeCost, Cost)
fn slp_tree_costs() -> i64 {
    let none_: i32[1] = [0];
    let tc = slp_calculate_tree_cost_and_trim(none_[..0], -1);
    slp_eu_clear();
    sh_clear(SH_EXTRA);
    slp_build_external_uses();
    return slp_get_tree_cost(tc, none_[..0], 0, -1);
}
// vectorizeStoreChain: true if the tree got vectorized
fn slp_after_tree_store(vf: i64) -> bool {
    if slp_is_profitable_to_reorder() {
        slp_reorder_top_to_bottom();
        slp_reorder_bottom_to_top(false);
    }
    slp_transform_nodes();
    slp_compute_minimum_value_sizes();
    let cost = slp_tree_costs();
    slp_print_found_cost(cost, vf);
    if cost < -slp_threshold() {
        if slp_dbg_on { errs("SLP: Decided to vectorize cost = "); slp_errs_cost(cost); errs("\n"); slp_dbg_flush(); }
        slp_vectorize_tree_not_ported();
        return true;
    }
    return false;
}
// tryToVectorizeList: true if the tree got vectorized
fn slp_after_tree_list(first: i32, vf: i64) -> bool {
    if slp_is_profitable_to_reorder() {
        slp_reorder_top_to_bottom();
        slp_reorder_bottom_to_top(!(is_inst_op(first, OP_INSERTELEMENT) || is_inst_op(first, OP_INSERTVALUE)));
    }
    slp_transform_nodes();
    slp_compute_minimum_value_sizes();
    let cost = slp_tree_costs();
    slp_print_found_cost(cost, vf);
    if cost < -slp_threshold() {
        if slp_dbg_on { errs("SLP: Vectorizing list at cost:"); slp_errs_cost(cost); errs(".\n"); slp_dbg_flush(); }
        slp_vectorize_tree_not_ported();
        return true;
    }
    return false;
}
// HorizontalReduction::tryToReduce; `int_minmax` are the reduction ops whose getRdxKind is an integer min/max
fn slp_after_tree_reduction(ignore_reorder: bool, int_minmax: const i32[:]) {
    slp_reorder_top_to_bottom();
    slp_reorder_bottom_to_top(ignore_reorder);
    sh_clear(SH_UILMM);
    for v in int_minmax { sh_add(SH_UILMM, v as i64, 0); }
    slp_transform_nodes();
    slp_compute_minimum_value_sizes();
    slp_cost_model_not_ported();
}
