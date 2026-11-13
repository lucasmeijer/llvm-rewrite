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

fn slp_cost_model_not_ported() { slp_fail("BoUpSLP's cost model (calculateTreeCostAndTrimNonProfitable / getTreeCost)"); }
// vectorizeStoreChain
fn slp_after_tree_store() {
    if slp_is_profitable_to_reorder() {
        slp_reorder_top_to_bottom();
        slp_reorder_bottom_to_top(false);
    }
    slp_transform_nodes();
    slp_compute_minimum_value_sizes();
    slp_cost_model_not_ported();
}
// tryToVectorizeList
fn slp_after_tree_list(first: i32) {
    if slp_is_profitable_to_reorder() {
        slp_reorder_top_to_bottom();
        slp_reorder_bottom_to_top(!(is_inst_op(first, OP_INSERTELEMENT) || is_inst_op(first, OP_INSERTVALUE)));
    }
    slp_transform_nodes();
    slp_compute_minimum_value_sizes();
    slp_cost_model_not_ported();
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
