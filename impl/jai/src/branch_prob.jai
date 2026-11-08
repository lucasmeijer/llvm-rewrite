// BranchProbabilityInfo: a port of llvm/lib/Analysis/BranchProbabilityInfo.cpp (BPIConstruction with SccInfo, the
// estimated block weights, the metadata / pointer / zero / floating-point heuristics, the query and update API and
// print<branch-prob>), llvm/lib/Support/BranchProbability.cpp (scale, printing; bp_make / bp_get / bp_compl are in
// pass_simplifycfg.jai) and the scc_iterator of llvm/include/llvm/ADT/SCCIterator.h for the CFG.
//
// A probability is a u32 numerator over BP_D (1 << 31); BP_UNKNOWN is the unknown probability. The result is
// `*Bpi` (heap, Fn_Analyses.bpi, get_bpi(f)), edges keyed by source block.

Bpi :: struct {
    f: Value_Id;
    probs: Table(Value_Id, [..] u32);   // EdgeStarts / Probs: one entry per successor
}

bpi_free :: (b: *Bpi) {
    for * b.probs array_free(it.*);
    deinit(*b.probs);
    free(b);
}

// ---------------------------------------------------------------- BranchProbability arithmetic

bp_add :: (a: u32, b: u32) -> u32 { s := cast(u64) a + b; return ifx s > BP_D then cast(u32) BP_D else cast(u32) s; }
bp_sub :: (a: u32, b: u32) -> u32 { return ifx a < b then cast(u32) 0 else a - b; }
bp_div_u32 :: (a: u32, n: u32) -> u32 { return a / n; }
// BranchProbability::scale(uint64_t Num) (and scaleByInverse with n / d swapped)
bp_scale_nd :: (num: u64, n: u32, d: u32) -> u64 {
    if num == 0 || d == n return num;
    product_high := (num >> 32) * n;
    product_low := (num & 0xFFFF_FFFF) * n;
    upper32 := cast(u32) (product_high >> 32);
    lower32 := cast(u32) (product_low & 0xFFFF_FFFF);
    mid32_partial := cast(u32) (product_high & 0xFFFF_FFFF);
    mid32 := mid32_partial + cast,no_check(u32) (product_low >> 32);
    if mid32 < mid32_partial upper32 += 1;
    rem := ((cast(u64) upper32) << 32) | mid32;
    upper_q := rem / d;
    if upper_q > 0xFFFF_FFFF return 0xFFFF_FFFF_FFFF_FFFF;
    rem = ((rem % d) << 32) | lower32;
    lower_q := rem / d;
    q := (upper_q << 32) + lower_q;
    return ifx q < lower_q then 0xFFFF_FFFF_FFFF_FFFF else q;
}
bp_scale :: (p: u32, num: u64) -> u64 { return bp_scale_nd(num, p, cast(u32) BP_D); }
// BranchProbability::normalizeProbabilities
bp_normalize :: (ps: [] u32) {
    if ps.count == 0 return;
    unknown := 0;
    sum: u64 = 0;
    for ps { if it == BP_UNKNOWN unknown += 1; else sum += it; }
    if unknown > 0 {
        for_unknown: u32 = 0;
        if sum < BP_D for_unknown = cast(u32) ((BP_D - sum) / cast(u64) unknown);
        for * ps if it.* == BP_UNKNOWN it.* = for_unknown;
        if sum <= BP_D return;
    }
    if sum == 0 {
        p := bp_make(1, cast(u64) ps.count);
        for * ps it.* = p;
        return;
    }
    for * ps it.* = cast(u32) ((cast(u64) it.* * BP_D + sum / 2) / sum);
}
// BranchProbability::print
bp_to_string :: (p: u32) -> string {
    if p == BP_UNKNOWN return "?\x1f";
    pct := round_half_even(((cast(float64) p) / cast(float64) BP_D) * 100.0 * 100.0) / 100.0;
    return tprint("0x% / 0x% = %\x1f", formatInt(p, base = 16, minimum_digits = 8), formatInt(BP_D, base = 16, minimum_digits = 8),
                  formatFloat(pct, trailing_width = 2, zero_removal = .NO));
}
// rint (round half to even, the default rounding mode)
round_half_even :: (x: float64) -> float64 {
    f := cast(float64) cast(s64) x;   // floor (x >= 0 here)
    d := x - f;
    if d > 0.5 return f + 1;
    if d < 0.5 return f;
    if cast(s64) f % 2 == 0 return f;
    return f + 1;
}

// ---------------------------------------------------------------- BranchProbabilityInfo API

// getEdges
bpi_edges :: (b: *Bpi, bb: Value_Id) -> [] u32 {
    p := table_find_pointer(*b.probs, bb);
    if !p return .[];
    return p.*;
}
// eraseBlock
bpi_erase_block :: (b: *Bpi, bb: Value_Id) {
    p := table_find_pointer(*b.probs, bb);
    if p { array_free(p.*); table_remove(*b.probs, bb); }
}
// getEdgeProbability(Src, IndexInSuccessors)
bpi_edge_probability_idx :: (b: *Bpi, src: Value_Id, idx: u32) -> u32 {
    p := bpi_edges(b, src);
    if p.count return p[idx];
    return bp_make(1, cast(u64) block_num_successors(src));
}
// getEdgeProbability(Src, Dst)
bpi_edge_probability :: (b: *Bpi, src: Value_Id, dst: Value_Id) -> u32 {
    p := bpi_edges(b, src);
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(src, *succs);
    if p.count == 0 {
        n: u64 = 0;
        for succs if it == dst n += 1;
        return bp_make(n, cast(u64) succs.count);
    }
    prob: u32 = 0;
    for succs if it == dst prob = bp_add(prob, p[it_index]);
    return prob;
}
// setEdgeProbability(Src, Probs)
bpi_set_edge_probability :: (b: *Bpi, src: Value_Id, probs: [] u32) {
    n := block_num_successors(src);
    if n == 0 { bpi_erase_block(b, src); return; }
    p := table_find_pointer(*b.probs, src);
    if !p { e: [..] u32; table_set(*b.probs, src, e); p = table_find_pointer(*b.probs, src); }
    p.count = 0;
    for probs array_add(p, it);
}
// copyEdgeProbabilities(Src, Dst)
bpi_copy_edge_probabilities :: (b: *Bpi, src: Value_Id, dst: Value_Id) {
    sp := bpi_edges(b, src);
    if block_num_successors(dst) == 0 || sp.count == 0 { bpi_erase_block(b, dst); return; }
    copy: [..] u32; copy.allocator = temp;
    for sp array_add(*copy, it);
    bpi_set_edge_probability(b, dst, copy);
}
// isEdgeHot
bpi_is_edge_hot :: (b: *Bpi, src: Value_Id, dst: Value_Id) -> bool { return bpi_edge_probability(b, src, dst) > bp_make(4, 5); }

// ---------------------------------------------------------------- scc_iterator over the CFG

// The SCCs of the blocks reachable from the entry, in scc_iterator order (each SCC in the order it is popped).
cfg_sccs :: (entry: Value_Id, out: *[..] [..] Value_Id) {
    Elem :: struct { node: Value_Id; next_child: u32; min_visited: u32; }
    visit_num: u32 = 0;
    numbers: Table(Value_Id, u32); numbers.allocator = temp;
    scc_stack: [..] Value_Id; scc_stack.allocator = temp;
    visit_stack: [..] Elem; visit_stack.allocator = temp;
    visit_one :: (n: Value_Id, visit_num: *u32, numbers: *Table(Value_Id, u32), scc_stack: *[..] Value_Id, visit_stack: *[..] Elem) {
        visit_num.* += 1;
        table_set(numbers, n, visit_num.*);
        array_add(scc_stack, n);
        array_add(visit_stack, .{n, 0, visit_num.*});
    }
    visit_one(entry, *visit_num, *numbers, *scc_stack, *visit_stack);
    while visit_stack.count {
        // DFSVisitChildren
        while true {
            top := *visit_stack[visit_stack.count - 1];
            t := block_terminator(top.node);
            n := ifx t == NONE then cast(u32) 0 else num_successors(t);
            if top.next_child >= n break;
            child := get_successor(t, top.next_child);
            top.next_child += 1;
            found, cn := table_find(*numbers, child);
            if !found { visit_one(child, *visit_num, *numbers, *scc_stack, *visit_stack); continue; }
            if top.min_visited > cn top.min_visited = cn;
        }
        visiting := visit_stack[visit_stack.count - 1].node;
        min_visit := visit_stack[visit_stack.count - 1].min_visited;
        visit_stack.count -= 1;
        if visit_stack.count && visit_stack[visit_stack.count - 1].min_visited > min_visit visit_stack[visit_stack.count - 1].min_visited = min_visit;
        _, vn := table_find(*numbers, visiting);
        if min_visit != vn continue;
        scc: [..] Value_Id; scc.allocator = temp;
        while true {
            x := pop(*scc_stack);
            array_add(*scc, x);
            table_set(*numbers, x, 0xFFFF_FFFF);
            if x == visiting break;
        }
        array_add(out, scc);
    }
}

// ---------------------------------------------------------------- BPIConstruction

BLOCK_EXEC_ZERO :: 0;
BLOCK_EXEC_LOWEST_NON_ZERO :: 1;
BLOCK_EXEC_UNREACHABLE :: 0;
BLOCK_EXEC_NORETURN :: 1;
BLOCK_EXEC_UNWIND :: 1;
BLOCK_EXEC_COLD :: 0xffff;
BLOCK_EXEC_DEFAULT :: 0xfffff;

LBH_TAKEN_WEIGHT :: 124;
LBH_NONTAKEN_WEIGHT :: 4;
PH_TAKEN_WEIGHT :: 20; PH_NONTAKEN_WEIGHT :: 12;
ZH_TAKEN_WEIGHT :: 20; ZH_NONTAKEN_WEIGHT :: 12;
FPH_TAKEN_WEIGHT :: 20; FPH_NONTAKEN_WEIGHT :: 12;
FPH_ORD_WEIGHT :: 1024 * 1024 - 1; FPH_UNO_WEIGHT :: 1;

SCC_HEADER :: 1; SCC_EXITING :: 2;

Bpi_Build :: struct {
    bpi: *Bpi;
    li: *Loop_Info;
    // SccInfo
    scc_nums: Table(Value_Id, s32);
    scc_blocks: [..] [..] [2] Value_Id;   // per SCC: (block, type) in insertion order (DenseMap order, see NOTES)
    est_block: Table(Value_Id, u32);      // EstimatedBlockWeight
    est_loop: Table(u64, u32);            // EstimatedLoopWeight, key = loop data
}

// LoopBlock: (innermost loop, SCC number when not in a loop)
Loop_Block :: struct { bb: Value_Id; l: Loop_Id = NONE; scc: s32 = -1; }

bb_loop_block :: (c: *Bpi_Build, bb: Value_Id) -> Loop_Block {
    r: Loop_Block; r.bb = bb;
    r.l = li_loop_for(c.li, bb);
    if r.l == NONE r.scc = bb_scc_num(c, bb);
    return r;
}
bb_loop_data_key :: (lb: Loop_Block) -> u64 { return ((cast(u64) lb.l) << 32) | cast(u64) cast,no_check(u32) lb.scc; }
bb_scc_num :: (c: *Bpi_Build, bb: Value_Id) -> s32 { found, n := table_find(*c.scc_nums, bb); return ifx found then n else -1; }
bb_scc_block_type :: (c: *Bpi_Build, bb: Value_Id, scc: s32) -> u32 {
    for c.scc_blocks[scc] if it[0] == bb return it[1];
    return 0;
}
bb_belongs_to_same_loop :: (a: Loop_Block, b: Loop_Block) -> bool {
    return (b.l != NONE && a.l == b.l) || (b.scc != -1 && a.scc == b.scc);
}
bb_is_loop_entering_edge :: (c: *Bpi_Build, src: Loop_Block, dst: Loop_Block) -> bool {
    return (dst.l != NONE && !li_contains_loop(c.li, dst.l, src.l)) || (dst.scc != -1 && src.scc != dst.scc);
}
bb_is_loop_exiting_edge :: (c: *Bpi_Build, src: Loop_Block, dst: Loop_Block) -> bool { return bb_is_loop_entering_edge(c, dst, src); }
bb_is_loop_entering_exiting_edge :: (c: *Bpi_Build, src: Loop_Block, dst: Loop_Block) -> bool {
    return bb_is_loop_entering_edge(c, src, dst) || bb_is_loop_exiting_edge(c, src, dst);
}

// SccInfo::SccInfo
bb_scc_info :: (c: *Bpi_Build, f: Value_Id) {
    sccs: [..] [..] Value_Id; sccs.allocator = temp;
    cfg_sccs(fn_entry(f), *sccs);
    preds: [..] Value_Id; preds.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    // LLVM interleaves SccNums[BB] = SccNum and calculateSccBlockType(BB) per block; reproduce that order.
    for scc, scc_num: sccs {
        if scc.count == 1 continue;
        for bb: scc {
            table_set(*c.scc_nums, bb, cast(s32) scc_num);
            t: u32 = 0;
            block_predecessors(bb, *preds);
            for p: preds if bb_scc_num(c, p) != scc_num { t |= SCC_HEADER; break; }
            block_successors(bb, *succs);
            for s: succs if bb_scc_num(c, s) != scc_num { t |= SCC_EXITING; break; }
            while c.scc_blocks.count <= scc_num { e: [..] [2] Value_Id; e.allocator = temp; array_add(*c.scc_blocks, e); }
            if t != 0 array_add(*c.scc_blocks[scc_num], .[bb, cast(Value_Id) t]);
        }
    }
}

// getLoopEnterBlocks
bb_loop_enter_blocks :: (c: *Bpi_Build, lb: Loop_Block, out: *[..] Value_Id) {
    preds: [..] Value_Id; preds.allocator = temp;
    if lb.l != NONE {
        block_predecessors(li_header(c.li, lb.l), *preds);
        for preds array_add(out, it);
    } else {
        for c.scc_blocks[lb.scc] {
            if (it[1] & SCC_HEADER) == 0 continue;
            block_predecessors(it[0], *preds);
            for p: preds if bb_scc_num(c, p) != lb.scc array_add(out, it[0]);
        }
    }
}
// getLoopExitBlocks
bb_loop_exit_blocks :: (c: *Bpi_Build, lb: Loop_Block, out: *[..] Value_Id) {
    if lb.l != NONE {
        tmp: [..] Value_Id; tmp.allocator = temp;
        li_exit_blocks(c.li, lb.l, *tmp);
        for tmp array_add(out, it);
    } else {
        succs: [..] Value_Id; succs.allocator = temp;
        for c.scc_blocks[lb.scc] {
            if (it[1] & SCC_EXITING) == 0 continue;
            block_successors(it[0], *succs);
            for s: succs if bb_scc_num(c, s) != lb.scc array_add(out, s);
        }
    }
}

bb_estimated_block_weight :: (c: *Bpi_Build, bb: Value_Id) -> (bool, u32) { found, w := table_find(*c.est_block, bb); return found, w; }
bb_estimated_loop_weight :: (c: *Bpi_Build, lb: Loop_Block) -> (bool, u32) { found, w := table_find(*c.est_loop, bb_loop_data_key(lb)); return found, w; }
// getEstimatedEdgeWeight
bb_estimated_edge_weight :: (c: *Bpi_Build, src: Loop_Block, dst: Loop_Block) -> (bool, u32) {
    if bb_is_loop_entering_edge(c, src, dst) { ok, w := bb_estimated_loop_weight(c, dst); return ok, w; }
    ok, w := bb_estimated_block_weight(c, dst.bb);
    return ok, w;
}
// getMaxEstimatedEdgeWeight
bb_max_estimated_edge_weight :: (c: *Bpi_Build, src: Loop_Block, succs: [] Value_Id) -> (bool, u32) {
    have := false; mx: u32 = 0;
    for succs {
        ok, w := bb_estimated_edge_weight(c, src, bb_loop_block(c, it));
        if !ok return false, 0;
        if !have || mx < w { mx = w; have = true; }
    }
    return have, mx;
}
// updateEstimatedBlockWeight
bb_update_estimated_block_weight :: (c: *Bpi_Build, lb: Loop_Block, w: u32, block_wl: *[..] Value_Id, loop_wl: *[..] Loop_Block) -> bool {
    bb := lb.bb;
    if table_contains(*c.est_block, bb) return false;
    table_set(*c.est_block, bb, w);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    for p: preds {
        pl := bb_loop_block(c, p);
        if bb_is_loop_exiting_edge(c, pl, lb) {
            if !table_contains(*c.est_loop, bb_loop_data_key(pl)) array_add(loop_wl, pl);
        } else if !table_contains(*c.est_block, p) array_add(block_wl, p);
    }
    return true;
}
// propagateEstimatedBlockWeight
bb_propagate_estimated_block_weight :: (c: *Bpi_Build, lb: Loop_Block, dt: *Dom_Tree, pdt: *Dom_Tree, w: u32, block_wl: *[..] Value_Id, loop_wl: *[..] Loop_Block) {
    bb := lb.bb;
    n := dt_node(dt, bb);
    pdt_start := dt_node(pdt, bb);
    while n >= 0 {
        dom_bb := dt.nodes[n].block;
        if !dt_dominates_nodes(pdt, pdt_start, dt_node(pdt, dom_bb)) break;
        dom_lb := bb_loop_block(c, dom_bb);
        if !bb_is_loop_entering_exiting_edge(c, dom_lb, lb) {
            if !bb_update_estimated_block_weight(c, dom_lb, w, block_wl, loop_wl) break;
        } else if bb_is_loop_exiting_edge(c, dom_lb, lb) {
            array_add(loop_wl, dom_lb);
        }
        n = dt.nodes[n].idom;
    }
}
// BasicBlock::getTerminatingDeoptimizeCall: block_terminating_deoptimize_call (pass_simplifycfg2.jai)
// getInitialEstimatedBlockWeight
bb_initial_estimated_block_weight :: (bb: Value_Id) -> (bool, u32) {
    t := block_terminator(bb);
    if inst_op(t) == .UNREACHABLE || block_terminating_deoptimize_call(bb) != NONE {
        x := block_last(bb);
        while x != NONE {
            if inst_op(x) == .CALL && call_has_fn_attr(x, .NoReturn) return true, BLOCK_EXEC_NORETURN;
            x = inst_prev(x);
        }
        return true, BLOCK_EXEC_UNREACHABLE;
    }
    if block_is_eh_pad(bb) return true, BLOCK_EXEC_UNWIND;
    for i: block_insts(bb) if inst_op(i) == .CALL && call_has_fn_attr(i, .Cold) return true, BLOCK_EXEC_COLD;
    return false, 0;
}
// estimateBlockWeights
bb_estimate_block_weights :: (c: *Bpi_Build, f: Value_Id, dt: *Dom_Tree, pdt: *Dom_Tree) {
    block_wl: [..] Value_Id; block_wl.allocator = temp;
    loop_wl: [..] Loop_Block; loop_wl.allocator = temp;
    loop_exits: Table(u64, [..] Value_Id); loop_exits.allocator = temp;
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(f), *po);
    for < k: 0..po.count - 1 {
        bb := po[k];
        ok, w := bb_initial_estimated_block_weight(bb);
        if ok bb_propagate_estimated_block_weight(c, bb_loop_block(c, bb), dt, pdt, w, *block_wl, *loop_wl);
    }
    succs: [..] Value_Id; succs.allocator = temp;
    while true {
        while loop_wl.count {
            lb := pop(*loop_wl);
            key := bb_loop_data_key(lb);
            if table_contains(*c.est_loop, key) continue;
            exits := table_find_pointer(*loop_exits, key);
            if !exits {
                e: [..] Value_Id; e.allocator = temp;
                bb_loop_exit_blocks(c, lb, *e);
                table_set(*loop_exits, key, e);
                exits = table_find_pointer(*loop_exits, key);
            }
            ok, lw := bb_max_estimated_edge_weight(c, lb, exits.*);
            if ok {
                if lw <= BLOCK_EXEC_UNREACHABLE lw = BLOCK_EXEC_LOWEST_NON_ZERO;
                table_set(*c.est_loop, key, lw);
                bb_loop_enter_blocks(c, lb, *block_wl);
            }
        }
        while block_wl.count {
            bb := pop(*block_wl);
            if table_contains(*c.est_block, bb) continue;
            lb := bb_loop_block(c, bb);
            block_successors(bb, *succs);
            ok, mw := bb_max_estimated_edge_weight(c, lb, succs);
            if ok bb_propagate_estimated_block_weight(c, lb, dt, pdt, mw, *block_wl, *loop_wl);
        }
        if block_wl.count == 0 && loop_wl.count == 0 break;
    }
}

// calcMetadataWeights
bb_calc_metadata_weights :: (c: *Bpi_Build, bb: Value_Id) -> bool {
    ti := block_terminator(bb);
    o := inst_op(ti);
    if !(o == .CONDBR || o == .SWITCH || o == .INDIRECTBR || o == .INVOKE || o == .CALLBR) return false;
    m := prof_valid_branch_weight_md(ti);
    if m == NONE return false;
    w64 := prof_weights_of_md(m);
    weights: [..] u32; weights.allocator = temp;
    for w64 array_add(*weights, cast,no_check(u32) it);
    weight_sum: u64 = 0;
    unreachable_idxs: [..] u32; unreachable_idxs.allocator = temp;
    reachable_idxs: [..] u32; reachable_idxs.allocator = temp;
    src := bb_loop_block(c, bb);
    for k: 0..weights.count - 1 {
        weight_sum += weights[k];
        dst := bb_loop_block(c, get_successor(ti, cast(u32) k));
        ok, ew := bb_estimated_edge_weight(c, src, dst);
        if ok && ew <= BLOCK_EXEC_UNREACHABLE array_add(*unreachable_idxs, cast(u32) k);
        else array_add(*reachable_idxs, cast(u32) k);
    }
    n := num_successors(ti);
    scaling: u64 = ifx weight_sum > 0xFFFF_FFFF then weight_sum / 0xFFFF_FFFF + 1 else 1;
    if scaling > 1 {
        weight_sum = 0;
        for k: 0..cast(s64) n - 1 { weights[k] = cast(u32) (weights[k] / scaling); weight_sum += weights[k]; }
    }
    if weight_sum == 0 || reachable_idxs.count == 0 {
        for k: 0..cast(s64) n - 1 weights[k] = 1;
        weight_sum = n;
    }
    bp: [..] u32; bp.allocator = temp;
    for k: 0..cast(s64) n - 1 array_add(*bp, bp_make(weights[k], cast(u64) cast(u32) weight_sum));
    if unreachable_idxs.count == 0 || reachable_idxs.count == 0 {
        bpi_set_edge_probability(c.bpi, bb, bp);
        return true;
    }
    unreachable_prob: u32 = 1;   // UR_TAKEN_PROB = getRaw(1)
    for unreachable_idxs if unreachable_prob < bp[it] bp[it] = unreachable_prob;
    new_unreachable_sum: u32 = 0;
    for unreachable_idxs new_unreachable_sum = bp_add(new_unreachable_sum, bp[it]);
    new_reachable_sum := bp_sub(cast(u32) BP_D, new_unreachable_sum);
    old_reachable_sum: u32 = 0;
    for reachable_idxs old_reachable_sum = bp_add(old_reachable_sum, bp[it]);
    if old_reachable_sum != new_reachable_sum {
        if old_reachable_sum == 0 {
            per_edge := new_reachable_sum / cast(u32) reachable_idxs.count;
            for reachable_idxs bp[it] = per_edge;
        } else {
            for reachable_idxs {
                mul := cast(u64) new_reachable_sum * bp[it];
                bp[it] = cast(u32) ((mul + old_reachable_sum / 2) / old_reachable_sum);   // divideNearest
            }
        }
    }
    bpi_set_edge_probability(c.bpi, bb, bp);
    return true;
}

// calcPointerHeuristics
bb_calc_pointer_heuristics :: (c: *Bpi_Build, bb: Value_Id) -> bool {
    bi := block_terminator(bb);
    if inst_op(bi) != .CONDBR return false;
    ci := op(bi, 0);
    if !is_inst(ci) || inst_op(ci) != .ICMP || !icmp_is_equality(inst_pred(ci)) return false;
    if !is_ptr_type(vtype(op(ci, 0))) return false;
    taken := bp_make(PH_TAKEN_WEIGHT, PH_TAKEN_WEIGHT + PH_NONTAKEN_WEIGHT);
    untaken := bp_make(PH_NONTAKEN_WEIGHT, PH_TAKEN_WEIGHT + PH_NONTAKEN_WEIGHT);
    if inst_pred(ci) == ICMP_NE { bpi_set_edge_probability(c.bpi, bb, .[taken, untaken]); return true; }
    if inst_pred(ci) == ICMP_EQ { bpi_set_edge_probability(c.bpi, bb, .[untaken, taken]); return true; }
    return false;
}

// computeUnlikelySuccessors
bb_compute_unlikely_successors :: (c: *Bpi_Build, bb: Value_Id, l: Loop_Id, unlikely: *[..] Value_Id) {
    bi := block_terminator(bb);
    if inst_op(bi) != .CONDBR return;
    ci := op(bi, 0);
    if !is_inst(ci) || (inst_op(ci) != .ICMP && inst_op(ci) != .FCMP) || !is_inst(op(ci, 0)) || !is_constant_kind(vkind(op(ci, 1))) return;
    cmp_lhs := op(ci, 0);
    cmp_phi: Value_Id = ifx is_phi(cmp_lhs) then cmp_lhs else NONE;
    cmp_const := op(ci, 1);
    chain: [..] Value_Id; chain.allocator = temp;
    while cmp_phi == NONE && cmp_lhs != NONE && is_binary_operator(cmp_lhs) && is_constant_kind(vkind(op(cmp_lhs, 1))) {
        if !li_contains_inst(c.li, l, cmp_lhs) return;
        array_add(*chain, cmp_lhs);
        nx := op(cmp_lhs, 0);
        cmp_lhs = ifx is_inst(nx) then nx else NONE;
        if cmp_lhs != NONE && is_phi(cmp_lhs) cmp_phi = cmp_lhs;
    }
    if cmp_phi == NONE || !li_contains_inst(c.li, l, cmp_phi) return;
    visited: [..] Value_Id; visited.allocator = temp;
    wl: [..] Value_Id; wl.allocator = temp;
    array_add(*wl, cmp_phi);
    array_add(*visited, cmp_phi);
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    while wl.count {
        p := pop(*wl);
        for k: 0..cast(s64) phi_num_incoming(p) - 1 {
            b := phi_block(p, cast(u32) k);
            if !li_contains(c.li, l, b) continue;
            v := phi_incoming_value_for_block(p, b);
            if is_phi(v) {
                if !block_set_contains(visited, v) { array_add(*visited, v); array_add(*wl, v); }
                continue;
            }
            k_const := v;
            if !is_constant_kind(vkind(k_const)) || !block_set_contains(succs, b) continue;
            for < x: 0..chain.count - 1 {
                k_const = cfo_binary_op_operands(inst_op(chain[x]), k_const, op(chain[x], 1));
                if k_const == NONE break;
            }
            if k_const == NONE continue;
            res := cfo_compare_inst_operands(inst_pred(ci), k_const, cmp_const);
            if res != NONE && ((is_null_value(res) && b == get_successor(bi, 0)) || (is_one_value(res) && b == get_successor(bi, 1)))
                if !block_set_contains(unlikely.*, b) array_add(unlikely, b);
        }
    }
}

// calcEstimatedHeuristics
bb_calc_estimated_heuristics :: (c: *Bpi_Build, bb: Value_Id) -> bool {
    lb := bb_loop_block(c, bb);
    unlikely: [..] Value_Id; unlikely.allocator = temp;
    tc: u32 = LBH_TAKEN_WEIGHT / LBH_NONTAKEN_WEIGHT;
    if lb.l != NONE bb_compute_unlikely_successors(c, bb, lb.l, *unlikely);
    found := false;
    succ_weights: [..] u32; succ_weights.allocator = temp;
    total: u64 = 0;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    for s: succs {
        sl := bb_loop_block(c, s);
        has, w := bb_estimated_edge_weight(c, lb, sl);
        if bb_is_loop_exiting_edge(c, lb, sl) && !(has && w == BLOCK_EXEC_ZERO) {
            w = max(cast(u32) BLOCK_EXEC_LOWEST_NON_ZERO, (ifx has then w else BLOCK_EXEC_DEFAULT) / tc);
            has = true;
        }
        is_unlikely := lb.l != NONE && block_set_contains(unlikely, s);
        if is_unlikely && !(has && w == BLOCK_EXEC_ZERO) {
            w = max(cast(u32) BLOCK_EXEC_LOWEST_NON_ZERO, (ifx has then w else BLOCK_EXEC_DEFAULT) / 2);
            has = true;
        }
        if has found = true;
        wv := ifx has then w else BLOCK_EXEC_DEFAULT;
        total += wv;
        array_add(*succ_weights, wv);
    }
    if !found || total == 0 return false;
    n := succ_weights.count;
    if total > 0xFFFF_FFFF {
        scaling := total / 0xFFFF_FFFF + 1;
        total = 0;
        for k: 0..n - 1 {
            succ_weights[k] = cast(u32) (succ_weights[k] / scaling);
            if succ_weights[k] == BLOCK_EXEC_ZERO succ_weights[k] = BLOCK_EXEC_LOWEST_NON_ZERO;
            total += succ_weights[k];
        }
    }
    probs: [..] u32; probs.allocator = temp;
    for k: 0..n - 1 array_add(*probs, bp_make(succ_weights[k], cast(u64) cast(u32) total));
    bpi_set_edge_probability(c.bpi, bb, probs);
    return true;
}

// calcZeroHeuristics
bb_calc_zero_heuristics :: (c: *Bpi_Build, bb: Value_Id) -> bool {
    bi := block_terminator(bb);
    if inst_op(bi) != .CONDBR return false;
    ci := op(bi, 0);
    if !is_inst(ci) || inst_op(ci) != .ICMP return false;
    get_constant_int :: (v: Value_Id) -> Value_Id {
        x := v;
        if is_inst(v) && inst_op(v) == .BITCAST x = op(v, 0);
        if vkind(x) == .C_INT return x;
        return NONE;
    }
    cv := get_constant_int(op(ci, 1));
    if cv == NONE return false;
    lhs := op(ci, 0);
    if is_inst(lhs) && inst_op(lhs) == .AND {
        and_rhs := get_constant_int(op(lhs, 1));
        if and_rhs != NONE && ap_is_power_of_2(const_ap(and_rhs)) return false;
    }
    func := Lib_Func.NotLibFunc;
    if is_inst(lhs) && inst_op(lhs) == .CALL {
        callee := call_called_function(lhs);
        // TLI->getLibFunc(*CalledFn, Func) with the result ignored: Func is set from the name before the
        // prototype check fails
        if callee != NONE && !glob(callee).intrinsic { ok, lf := tli_lookup_name(vname(callee)); if ok func = lf; }
    }
    pred := inst_pred(ci);
    likely: bool;
    cvap := const_ap(cv);
    if func == .strcasecmp || func == .strcmp || func == .strncasecmp || func == .strncmp || func == .memcmp || func == .bcmp {
        if pred == ICMP_EQ likely = false; else if pred == ICMP_NE likely = true; else return false;
    } else if ap_is_zero(cvap) {
        if pred == ICMP_EQ likely = false; else if pred == ICMP_NE likely = true;
        else if pred == ICMP_SLT likely = false; else if pred == ICMP_SGT likely = true; else return false;
    } else if ap_is_one(cvap) {
        if pred == ICMP_SLT likely = false; else return false;
    } else if ap_is_all_ones(cvap) {
        if pred == ICMP_EQ likely = false; else if pred == ICMP_NE likely = true;
        else if pred == ICMP_SGT likely = true; else return false;
    } else return false;
    taken := bp_make(ZH_TAKEN_WEIGHT, ZH_TAKEN_WEIGHT + ZH_NONTAKEN_WEIGHT);
    untaken := bp_make(ZH_NONTAKEN_WEIGHT, ZH_TAKEN_WEIGHT + ZH_NONTAKEN_WEIGHT);
    if likely bpi_set_edge_probability(c.bpi, bb, .[taken, untaken]);
    else bpi_set_edge_probability(c.bpi, bb, .[untaken, taken]);
    return true;
}

// calcFloatingPointHeuristics
bb_calc_floating_point_heuristics :: (c: *Bpi_Build, bb: Value_Id) -> bool {
    bi := block_terminator(bb);
    if inst_op(bi) != .CONDBR return false;
    fc := op(bi, 0);
    if !is_inst(fc) || inst_op(fc) != .FCMP return false;
    pred := inst_pred(fc);
    taken := bp_make(FPH_TAKEN_WEIGHT, FPH_TAKEN_WEIGHT + FPH_NONTAKEN_WEIGHT);
    untaken := bp_make(FPH_NONTAKEN_WEIGHT, FPH_TAKEN_WEIGHT + FPH_NONTAKEN_WEIGHT);
    ord_taken := bp_make(FPH_ORD_WEIGHT, FPH_ORD_WEIGHT + FPH_UNO_WEIGHT);
    ord_untaken := bp_make(FPH_UNO_WEIGHT, FPH_ORD_WEIGHT + FPH_UNO_WEIGHT);
    if fcmp_is_equality(pred) {
        if !cmp_is_true_when_equal(pred) bpi_set_edge_probability(c.bpi, bb, .[taken, untaken]);
        else bpi_set_edge_probability(c.bpi, bb, .[untaken, taken]);
    } else if pred == FCMP_ORD {
        bpi_set_edge_probability(c.bpi, bb, .[ord_taken, ord_untaken]);
    } else if pred == FCMP_UNO {
        bpi_set_edge_probability(c.bpi, bb, .[ord_untaken, ord_taken]);
    } else return false;
    return true;
}

// BranchProbabilityInfo::calculate
bpi_calculate :: (f: Value_Id, li: *Loop_Info, dt: *Dom_Tree, pdt: *Dom_Tree) -> *Bpi {
    b := New(Bpi);
    b.f = f;
    c: Bpi_Build;
    c.bpi = b;
    c.li = li;
    c.scc_nums.allocator = temp; c.scc_blocks.allocator = temp; c.est_block.allocator = temp; c.est_loop.allocator = temp;
    bb_scc_info(*c, f);
    bb_estimate_block_weights(*c, f, dt, pdt);
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(f), *po);
    for bb: po {
        if block_num_successors(bb) < 2 continue;
        if bb_calc_metadata_weights(*c, bb) continue;
        if bb_calc_estimated_heuristics(*c, bb) continue;
        if bb_calc_pointer_heuristics(*c, bb) continue;
        if bb_calc_zero_heuristics(*c, bb) continue;
        if bb_calc_floating_point_heuristics(*c, bb) continue;
    }
    return b;
}

// BranchProbabilityPrinterPass::run
print_branch_prob_run :: (f: Value_Id) -> Preserved {
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "Printing analysis 'Branch Probability Analysis' for function '%':\n", vname(f));
    b := get_bpi(f);
    append(*sb, "---- Branch Probabilities ----\n");
    succs: [..] Value_Id; succs.allocator = temp;
    for bb: fn_blocks(f) {
        block_successors(bb, *succs);
        for s: succs {
            p := bpi_edge_probability(b, bb, s);
            print_to_builder(*sb, "  edge % -> % probability is %%\n", value_as_operand(bb), value_as_operand(s), bp_to_string(p),
                             ifx bpi_is_edge_hot(b, bb, s) then " [HOT edge]" else "");
        }
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}
