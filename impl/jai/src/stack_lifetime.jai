// StackLifetime: live ranges of allocas from their lifetime markers (May or Must liveness), as instruction-number
// bit sets. Ported from llvm/lib/Analysis/StackLifetime.cpp (collectMarkers, calculateLocalLiveness,
// calculateLiveIntervals, run, getLiveRange / overlaps). Only what CoroFrame's storage reuse needs; the
// stack-lifetime printer is not ported.

Stack_Lifetime :: struct {
    n_allocas: s64;
    must: bool;
    numbering: Table(Value_Id, s32);
    n_insts: s64;                       // Instructions.size()
    blocks: [..] Value_Id;              // depth_first(&F)
    block_index: Table(Value_Id, s32);
    inst_start: [..] s64;               // BlockInstRange
    inst_end: [..] s64;
    markers: [..] [..] Sl_Marker;       // BBMarkers per block
    begin: [..] [..] bool;              // BlockLifetimeInfo per block: Begin / End / LiveIn / LiveOut
    end: [..] [..] bool;
    live_in: [..] [..] bool;
    live_out: [..] [..] bool;
    interesting: [..] bool;
    ranges: [..] [..] bool;             // LiveRanges
}
Sl_Marker :: struct { inst_no: s64; alloca_no: s32; is_start: bool; }

// depth_first(&F): preorder, successors in order
sl_depth_first :: (f: Value_Id, out: *[..] Value_Id) {
    Frame :: struct { b: Value_Id; next: u32; n: u32; }
    visited: Table(Value_Id, bool); visited.allocator = temp;
    stack: [..] Frame; stack.allocator = temp;
    e := fn_entry(f);
    table_set(*visited, e, true);
    array_add(out, e);
    array_add(*stack, .{e, 0, block_num_successors(e)});
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

sl_bits :: (n: s64) -> [..] bool { b: [..] bool; b.allocator = temp; array_resize(*b, n); return b; }

// StackLifetime(F, Allocas, Type) + run()
stack_lifetime_run :: (f: Value_Id, allocas: [] Value_Id, may_liveness: bool) -> Stack_Lifetime {
    sl: Stack_Lifetime;
    sl.n_allocas = allocas.count;
    sl.must = !may_liveness;
    sl.numbering.allocator = temp; sl.blocks.allocator = temp; sl.block_index.allocator = temp;
    sl.inst_start.allocator = temp; sl.inst_end.allocator = temp; sl.markers.allocator = temp;
    sl.begin.allocator = temp; sl.end.allocator = temp; sl.live_in.allocator = temp; sl.live_out.allocator = temp;
    sl.ranges.allocator = temp;
    for allocas table_set(*sl.numbering, it, cast(s32) it_index);
    // collectMarkers
    sl.interesting = sl_bits(sl.n_allocas);
    sl_depth_first(f, *sl.blocks);
    na := sl.n_allocas;
    for bb: sl.blocks {
        table_set(*sl.block_index, bb, cast(s32) it_index);
        array_add(*sl.begin, sl_bits(na)); array_add(*sl.end, sl_bits(na));
        array_add(*sl.live_in, sl_bits(na)); array_add(*sl.live_out, sl_bits(na));
        m: [..] Sl_Marker; m.allocator = temp;
        array_add(*sl.markers, m);
    }
    for bb: sl.blocks {
        bi := it_index;
        sl.n_insts += 1;   // the block's own slot
        start := sl.n_insts - 1;
        for i: block_insts(bb) {
            if inst_op(i) != .CALL continue;
            id := call_iid(i);
            if id != IID_LIFETIME_START && id != IID_LIFETIME_END continue;
            a := call_arg(i, 0);
            found, no := table_find(*sl.numbering, a);
            if !found continue;
            is_start := id == IID_LIFETIME_START;
            if is_start sl.interesting[no] = true;
            array_add(*sl.markers[bi], .{sl.n_insts, no, is_start});
            sl.n_insts += 1;
            if is_start { sl.end[bi][no] = false; sl.begin[bi][no] = true; }
            else { sl.begin[bi][no] = false; sl.end[bi][no] = true; }
        }
        array_add(*sl.inst_start, start);
        array_add(*sl.inst_end, sl.n_insts);
    }
    // run
    for k: 0..na - 1 {
        r := sl_bits(sl.n_insts);
        if !sl.interesting[k] for * r it.* = true;   // getFullLiveRange
        array_add(*sl.ranges, r);
    }
    // calculateLocalLiveness
    preds: [..] Value_Id; preds.allocator = temp;
    bits_in := sl_bits(na);
    changed := true;
    while changed {
        changed = false;
        for bb: sl.blocks {
            bi := it_index;
            for * bits_in it.* = false;
            any := false;
            block_predecessors(bb, *preds);
            for p: preds {
                found, pi := table_find(*sl.block_index, p);
                if !found continue;
                for k: 0..na - 1 if sl.live_out[pi][k] bits_in[k] = true;
                any = true;
            }
            if sl.must && !any for * bits_in it.* = true;
            for k: 0..na - 1 if bits_in[k] sl.live_in[bi][k] = true;
            if sl.must { for k: 0..na - 1 { if sl.begin[bi][k] bits_in[k] = false; if sl.end[bi][k] bits_in[k] = true; } }
            else { for k: 0..na - 1 { if sl.end[bi][k] bits_in[k] = false; if sl.begin[bi][k] bits_in[k] = true; } }
            for k: 0..na - 1 if bits_in[k] && !sl.live_out[bi][k] { changed = true; sl.live_out[bi][k] = true; }
        }
    }
    if sl.must for bi: 0..sl.blocks.count - 1 for k: 0..na - 1 { sl.live_in[bi][k] = !sl.live_in[bi][k]; sl.live_out[bi][k] = !sl.live_out[bi][k]; }
    // calculateLiveIntervals
    for bb: sl.blocks {
        bi := it_index;
        bs := sl.inst_start[bi]; be := sl.inst_end[bi];
        started := sl_bits(na);
        start := NewArray(na, s64,, allocator = temp);
        for k: 0..na - 1 if sl.live_in[bi][k] { started[k] = true; start[k] = bs; }
        for m: sl.markers[bi] {
            if m.is_start {
                if !started[m.alloca_no] { started[m.alloca_no] = true; start[m.alloca_no] = m.inst_no; }
            } else {
                if started[m.alloca_no] {
                    for x: start[m.alloca_no]..m.inst_no - 1 sl.ranges[m.alloca_no][x] = true;
                    started[m.alloca_no] = false;
                }
            }
        }
        for k: 0..na - 1 if started[k] for x: start[k]..be - 1 sl.ranges[k][x] = true;
    }
    return sl;
}

// getLiveRange(AI1).overlaps(getLiveRange(AI2))
stack_lifetime_interfere :: (sl: *Stack_Lifetime, a: Value_Id, b: Value_Id) -> bool {
    fa, ia := table_find(*sl.numbering, a);
    fb, ib := table_find(*sl.numbering, b);
    assert(fa && fb);
    ra := sl.ranges[ia]; rb := sl.ranges[ib];
    for k: 0..ra.count - 1 if ra[k] && rb[k] return true;
    return false;
}
