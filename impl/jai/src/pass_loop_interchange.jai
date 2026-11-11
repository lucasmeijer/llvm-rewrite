// LoopInterchangePass (llvm/lib/Transforms/Scalar/LoopInterchange.cpp), a LoopNest pass in default<O1..O3>
// (PTO.LoopInterchange = -enable-loopinterchange, on by default). Ported so far: the early exits of
// LoopInterchangePass::run and LoopInterchange::run(LoopNest &) (hasSupportedLoopDepth, isComputableLoopNest, the
// loops forming one chain). A nest that passes them needs DependenceInfo (DependenceAnalysis.cpp, not ported) for
// its dependency matrix and fails loudly.

li_cl: struct {
    min_loop_nest_depth: s64 = 2;    // -loop-interchange-min-loop-nest-depth
    max_loop_nest_depth: s64 = 10;   // -loop-interchange-max-loop-nest-depth
}

// LoopNest::getLoops(): breadth_first(&Root)
loop_nest_loops_bfs :: (li: *Loop_Info, root: Loop_Id) -> [..] Loop_Id {
    out: [..] Loop_Id; out.allocator = temp;
    array_add(*out, root);
    i := 0;
    while i < out.count {
        for li_subloops(li, out[i]) array_add(*out, it);
        i += 1;
    }
    return out;
}

loop_interchange_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    li := lar.li;
    loops := loop_nest_loops_bfs(li, l);
    // hasSupportedLoopDepth
    if loops.count < li_cl.min_loop_nest_depth || loops.count > li_cl.max_loop_nest_depth return PRESERVE_ALL;
    // isComputableLoopNest
    se = lar.se;
    for x: loops {
        if sc_get_backedge_taken_count(x) == SCEV_CNC return PRESERVE_ALL;
        if li_num_back_edges(li, x) != 1 return PRESERVE_ALL;
        if li_exiting_block(li, x) == NONE return PRESERVE_ALL;
    }
    // LoopInterchange::run(LoopNest &): the loops must form a single chain
    for i: 1..loops.count - 1 if li_parent(li, loops[i]) != loops[i - 1] return PRESERVE_ALL;
    fatal("loop-interchange: a % deep loop nest needs DependenceAnalysis, which is not implemented yet", loops.count);
    return PRESERVE_NONE;
}
