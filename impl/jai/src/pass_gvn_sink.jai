// GVNSink: a port of llvm/lib/Transforms/Scalar/GVNSink.cpp (SinkingInstructionCandidate, ModelledPHI, the
// use-based ValueTable with InstructionUseExpr, GVNSink::run / sinkBB / analyzeInstructionForSinking /
// sinkLastInstruction / foldPointlessPHINodes) and of llvm/include/llvm/Transforms/Utils/LockstepReverseIterator.h
// (the EarlyFailure = false form).
//
// Pointer order: InstructionUseExpr sorts the users of an instruction by address before hashing their value
// numbers; value ids (creation order) stand in for the addresses. The value number of an expression is decided by
// hash equality in LLVM (HashNumbering); here by equality of the hashed fields (identical except on hash collisions).
// The DenseMap<uint32_t, unsigned> VNums that max_element walks is iterated in LLVM's bucket order (gs_densemap_order).
// When the decision really depends on the address order (two candidates with the same users as a multiset, in a
// different order), the pass fails loudly. `-gvn-sink-guess-address-order` (our flag) guesses creation order
// instead: right on 18 of 27 such corpus files and on tests/perf/compile after sroa, wrong on all four after the
// O2 pipeline (knowledge/llvm/gvn-hoist-sink.md).

Gs_Phi :: struct {   // ModelledPHI
    values: [..] Value_Id;
    blocks: [..] Value_Id;
}
gs_phi_eq :: (a: *Gs_Phi, b: *Gs_Phi) -> bool {
    if a.values.count != b.values.count || a.blocks.count != b.blocks.count return false;
    for a.values if it != b.values[it_index] return false;
    for a.blocks if it != b.blocks[it_index] return false;
    return true;
}
gs_phi_copy :: (p: *Gs_Phi) -> Gs_Phi {
    r: Gs_Phi; r.values.allocator = temp; r.blocks.allocator = temp;
    for p.values array_add(*r.values, it);
    for p.blocks array_add(*r.blocks, it);
    return r;
}
// SetVector<ModelledPHI>
Gs_Phi_Set :: struct { list: [..] Gs_Phi; }
gs_set_find :: (s: *Gs_Phi_Set, p: *Gs_Phi) -> s64 {
    for * s.list if gs_phi_eq(it, p) return it_index;
    return -1;
}
gs_set_insert :: (s: *Gs_Phi_Set, p: *Gs_Phi) -> bool {
    if s.list.allocator.proc == null s.list.allocator = temp;
    if gs_set_find(s, p) >= 0 return false;
    array_add(*s.list, gs_phi_copy(p));
    return true;
}
gs_set_remove :: (s: *Gs_Phi_Set, p: *Gs_Phi) -> bool {
    k := gs_set_find(s, p);
    if k < 0 return false;
    for i: k..s.list.count - 2 s.list[i] = s.list[i + 1];
    s.list.count -= 1;
    return true;
}

// SmallSetVector<BasicBlock *, 4>
Gs_Block_Set :: struct { list: [..] Value_Id; }
gs_bs_contains :: (s: *Gs_Block_Set, b: Value_Id) -> bool { for s.list if it == b return true; return false; }
gs_bs_insert :: (s: *Gs_Block_Set, b: Value_Id) { if !gs_bs_contains(s, b) array_add(*s.list, b); }
gs_bs_remove :: (s: *Gs_Block_Set, b: Value_Id) {
    for s.list if it == b {
        for i: it_index..s.list.count - 2 s.list[i] = s.list[i + 1];
        s.list.count -= 1;
        return;
    }
}

// LockstepReverseIterator<false>
Gs_Lri :: struct {
    blocks: [..] Value_Id;
    insts: [..] Value_Id;
    active: Gs_Block_Set;
    fail: bool;
}
gs_lri_reset :: (l: *Gs_Lri) {
    l.fail = false;
    l.active.list.count = 0;
    for l.blocks gs_bs_insert(*l.active, it);
    l.insts.count = 0;
    for bb: l.blocks {
        prev := inst(block_terminator(bb)).prev;
        if prev == NONE { gs_bs_remove(*l.active, bb); continue; }
        array_add(*l.insts, prev);
    }
    if l.insts.count == 0 l.fail = true;
}
gs_lri_restrict_to_blocks :: (l: *Gs_Lri, blocks: *Gs_Block_Set) {
    k := 0;
    while k < l.insts.count {
        p := inst_block(l.insts[k]);
        if !gs_bs_contains(blocks, p) {
            gs_bs_remove(*l.active, p);
            for i: k..l.insts.count - 2 l.insts[i] = l.insts[i + 1];
            l.insts.count -= 1;
        } else k += 1;
    }
}
gs_lri_dec :: (l: *Gs_Lri) {
    if l.fail return;
    ni: [..] Value_Id; ni.allocator = temp;
    for l.insts {
        prev := inst(it).prev;
        if prev == NONE gs_bs_remove(*l.active, inst_block(it));
        else array_add(*ni, prev);
    }
    if ni.count == 0 l.fail = true;
    else { l.insts.count = 0; for ni array_add(*l.insts, it); }
}

Gs_Candidate :: struct {
    num_blocks: u32;
    num_instructions: u32;
    num_phis: u32;
    num_memory_insts: u32;
    cost: s32 = -1;
    blocks: [..] Value_Id;
}

Gvn_Sink :: struct {
    f: Value_Id;
    value_numbering: Table(Value_Id, u32);
    hash_numbering: Table(string, u32);
    next_value_number: u32 = 1;
    reachable: Table(Value_Id, bool);
    rpot_order: Table(Value_Id, u32);
    // for detecting pointer-order dependence: the VN computed from the users' VNs as a multiset, and whether the
    // address order of the users could change the hash (two or more distinct user VNs, or an ambiguous user)
    multiset_sig: Table(Value_Id, string);
    ambiguous: Table(Value_Id, bool);
    ambiguous_step: bool;   // set by gs_analyze_instruction_for_sinking
}
gs_strict := true;   // -gvn-sink-guess-address-order (ours) clears it: guess LLVM's address order instead of failing
gvn_sink_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == "gvn-sink-guess-address-order" { gs_strict = false; return true; }
    return false;
}
gs_not_reproducible :: (why := "") {
    if !gs_strict return;
    fatal("gvn-sink: the value numbers of two candidates depend on the address order of their users in LLVM; not reproducible");
}

// isMemoryInst
gs_is_memory_inst :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .LOAD || o == .STORE return true;
    if (o == .INVOKE || o == .CALL) && !mem_does_not_access(call_memory_effects(i)) return true;
    return false;
}

// ValueTable::lookupOrAdd
gs_lookup_or_add :: (g: *Gvn_Sink, v: Value_Id) -> u32 {
    found, n := table_find(*g.value_numbering, v);
    if found return n;
    if !is_inst(v) {
        table_set(*g.value_numbering, v, g.next_value_number);
        g.next_value_number += 1;
        return g.next_value_number - 1;
    }
    i := v;
    if !table_contains(*g.reachable, inst_block(i)) return 0xFFFF_FFFF;
    has_exp := false;
    volatile := false;
    o := inst_op(i);
    if o == .LOAD || o == .STORE {
        // createMemoryExpr: isStrongerThanUnordered(ordering) || isAtomic()
        if inst(i).ord1 == 0 { has_exp = true; volatile = (inst(i).flags & F_VOLATILE) != 0; }
    } else if o == .CALL || o == .INVOKE || o == .FNEG || is_binary_op(o) || o == .ICMP || o == .FCMP ||
              (is_cast_op(o)) || o == .SELECT || o == .EXTRACTELEMENT || o == .INSERTELEMENT ||
              o == .SHUFFLEVECTOR || o == .INSERTVALUE || o == .GEP {
        has_exp = true;
    }
    if !has_exp {
        table_set(*g.value_numbering, v, g.next_value_number);
        g.next_value_number += 1;
        return g.next_value_number - 1;
    }
    // InstructionUseExpr: the users (one per use), sorted by address
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[i];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for a: 1..users.count - 1 {
        x := users[a]; b := a - 1;
        while b >= 0 && users[b] > x { users[b + 1] = users[b]; b -= 1; }
        users[b + 1] = x;
    }
    opcode := cast(u32) o;
    if o == .ICMP || o == .FCMP opcode = (opcode << 8) | cast(u32) inst(i).pred;
    muo: u32 = 0xFFFF_FFFF;
    if gs_is_memory_inst(i) muo = gs_get_memory_use_order(g, i);
    k: Key; k.buf.allocator = temp;
    key_u32(*k, opcode); key_u32(*k, vtype(i)); key_u32(*k, muo); key_u8(*k, cast(u8) volatile);
    if o == .SHUFFLEVECTOR {
        m := shuffle_mask(i);
        key_u32(*k, cast(u32) m.count);
        for m key_u32(*k, it);
    }
    ms: Key; ms.buf.allocator = temp;
    for k.buf array_add(*ms.buf, it);
    uvns: [..] u32; uvns.allocator = temp;
    amb := false;
    for users {
        n := gs_lookup_or_add(g, it);
        key_u32(*k, n);
        array_add(*uvns, n);
        if table_contains(*g.ambiguous, it) amb = true;
    }
    for a: 1..uvns.count - 1 {
        x := uvns[a]; b := a - 1;
        while b >= 0 && uvns[b] > x { uvns[b + 1] = uvns[b]; b -= 1; }
        uvns[b + 1] = x;
    }
    for uvns { key_u32(*ms, it); if it != uvns[0] amb = true; }
    table_set(*g.multiset_sig, v, copy_string(key_view(*ms),, allocator = temp));
    if amb table_set(*g.ambiguous, v, true);
    s := key_copy(*k);
    found2, e := table_find(*g.hash_numbering, s);
    if !found2 {
        e = g.next_value_number;
        table_set(*g.hash_numbering, s, e);
        g.next_value_number += 1;
    }
    table_set(*g.value_numbering, v, e);
    return e;
}

// ValueTable::getMemoryUseOrder
gs_get_memory_use_order :: (g: *Gvn_Sink, i: Value_Id) -> u32 {
    x := inst(i).next;
    while x != NONE && !is_terminator(inst_op(x)) {
        defer x = inst(x).next;
        if !gs_is_memory_inst(x) continue;
        if inst_op(x) == .LOAD continue;
        if (inst_op(x) == .CALL || inst_op(x) == .INVOKE) && mem_only_reads(call_memory_effects(x)) continue;
        return gs_lookup_or_add(g, x);
    }
    return 0;
}

gs_lookup :: (g: *Gvn_Sink, v: Value_Id) -> u32 {
    found, n := table_find(*g.value_numbering, v);
    if !found fatal("gvn-sink: internal: value not numbered");
    return n;
}

// The iteration order of a DenseMap<uint32_t, ...> after inserting `keys` (in order, duplicates ignored):
// DenseMapInfo<unsigned>::getHashValue = Val * 37, quadratic probing, 64 buckets to start, grow at 3/4 load.
gs_densemap_order :: (keys: [] u32) -> [..] u32 {
    nb := 64;
    buckets: [..] u32; buckets.allocator = temp;
    EMPTY :: 0xFFFF_FFFF;
    insert :: (buckets: *[..] u32, nb: s64, key: u32) {
        b := cast(s64) ((key * 37) & cast(u32) (nb - 1));
        probe := 1;
        while true {
            if buckets.*[b] == key return;
            if buckets.*[b] == EMPTY { buckets.*[b] = key; return; }
            b = (b + probe) & (nb - 1);
            probe += 1;
        }
    }
    reset :: (buckets: *[..] u32, nb: s64) { buckets.count = 0; for 0..nb - 1 array_add(buckets, EMPTY); }
    reset(*buckets, nb);
    count := 0;
    for key: keys {
        present := false;
        for buckets if it == key { present = true; break; }
        if present continue;
        if (count + 1) * 4 >= nb * 3 {
            old: [..] u32; old.allocator = temp;
            for buckets array_add(*old, it);
            nb *= 2;
            reset(*buckets, nb);
            for old if it != EMPTY insert(*buckets, nb, it);
        }
        insert(*buckets, nb, key);
        count += 1;
    }
    out: [..] u32; out.allocator = temp;
    for buckets if it != EMPTY array_add(*out, it);
    return out;
}

gs_should_avoid_sinking_instruction :: (i: Value_Id) -> bool {
    return inst_op(i) == .PHI || is_eh_pad(i) || inst_op(i) == .ALLOCA || type_kind(vtype(i)) == .TOKEN;
}

// ModelledPHI(PN, BlockOrder)
gs_modelled_phi_from_phi :: (g: *Gvn_Sink, pn: Value_Id) -> Gs_Phi {
    Op :: struct { b: Value_Id; v: Value_Id; }
    ops: [..] Op; ops.allocator = temp;
    n := nops(pn);
    for k: 0..cast(s64) n - 1 array_add(*ops, .{phi_block(pn, cast(u32) k), op(pn, cast(u32) k)});
    key :: (g: *Gvn_Sink, b: Value_Id) -> u32 { found, r := table_find(*g.rpot_order, b); if found return r; return 0; }
    for a: 1..ops.count - 1 {
        x := ops[a]; kx := key(g, x.b); b := a - 1;
        while b >= 0 && key(g, ops[b].b) > kx { ops[b + 1] = ops[b]; b -= 1; }
        ops[b + 1] = x;
    }
    p: Gs_Phi; p.values.allocator = temp; p.blocks.allocator = temp;
    for ops { array_add(*p.blocks, it.b); array_add(*p.values, it.v); }
    return p;
}

gs_phi_restrict_to_blocks :: (p: *Gs_Phi, nb: *Gs_Block_Set) {
    k := 0;
    while k < p.blocks.count {
        if !gs_bs_contains(nb, p.blocks[k]) {
            for i: k..p.blocks.count - 2 { p.blocks[i] = p.blocks[i + 1]; p.values[i] = p.values[i + 1]; }
            p.blocks.count -= 1; p.values.count -= 1;
        } else k += 1;
    }
}

Gs_Contents :: struct { has: Table(Value_Id, bool); }

// analyzeInstructionForSinking
gs_analyze_instruction_for_sinking :: (g: *Gvn_Sink, lri: *Gs_Lri, inst_num: *u32, memory_inst_num: *u32,
                                       needed: *Gs_Phi_Set, contents: *Table(Value_Id, bool)) -> (bool, Gs_Candidate) {
    none: Gs_Candidate;
    insts: [..] Value_Id; insts.allocator = temp;
    for lri.insts array_add(*insts, it);
    keys: [..] u32; keys.allocator = temp;
    counts: Table(u32, u32); counts.allocator = temp;
    for i: insts {
        n := gs_lookup_or_add(g, i);
        if n == 0xFFFF_FFFF return false, none;
        array_add(*keys, n);
        p := table_find_pointer(*counts, n);
        if p p.* += 1; else table_set(*counts, n, 1);
    }
    // LLVM compares the hashes of the users' value numbers in user *address* order: when two candidates have the same
    // users as a multiset and that order matters, whether they get the same value number depends on heap layout
    for a: 0..insts.count - 1 for b: a + 1..insts.count - 1 {
        x := insts[a]; y := insts[b];
        if !table_contains(*g.ambiguous, x) && !table_contains(*g.ambiguous, y) continue;
        _, sx := table_find(*g.multiset_sig, x);
        _, sy := table_find(*g.multiset_sig, y);
        if sx != sy continue;
        // our numbers (users in creation order) say equal: the step is taken; gs_sink_bb fails only if the chosen
        // candidate includes it. Our numbers say different: LLVM may well continue, nothing can be concluded
        if gs_lookup(g, x) != gs_lookup(g, y) gs_not_reproducible("differ"); if insts.count > 2 gs_not_reproducible("many");
        g.ambiguous_step = true;
    }
    order := gs_densemap_order(keys);
    // llvm::max_element(VNums, less_second): the first maximum in iteration order
    vnum_to_sink := order[0];
    _, best := table_find(*counts, vnum_to_sink);
    for order {
        _, c := table_find(*counts, it);
        if c > best { best = c; vnum_to_sink = it; }
    }
    _, cnt := table_find(*counts, vnum_to_sink);
    if cnt == 1 return false, none;

    active := *lri.active;
    initial_active := active.list.count;
    new_insts: [..] Value_Id; new_insts.allocator = temp;
    for i: insts {
        if gs_lookup(g, i) != vnum_to_sink gs_bs_remove(active, inst_block(i));
        else array_add(*new_insts, i);
    }
    for new_insts if gs_should_avoid_sinking_instruction(it) return false, none;

    recompute := false;
    if active.list.count != initial_active {
        nn: Gs_Phi_Set;
        for * needed.list {
            p := gs_phi_copy(it);
            gs_phi_restrict_to_blocks(*p, active);
            gs_set_insert(*nn, *p);
        }
        needed.list.count = 0;
        for * nn.list array_add(*needed.list, it.*);
        gs_lri_restrict_to_blocks(lri, active);
        recompute = true;
    }
    new_phi: Gs_Phi; new_phi.values.allocator = temp; new_phi.blocks.allocator = temp;
    for new_insts array_add(*new_phi.values, it);
    for active.list array_add(*new_phi.blocks, it);
    if gs_set_remove(needed, *new_phi) recompute = true;
    if recompute {
        table_reset(contents);
        for * needed.list for v: it.values table_set(contents, v, true);
    }
    for new_phi.values if table_contains(contents, it) return false, none;

    i0 := new_insts[0];
    for new_insts if !is_same_operation_as(i0, it) return false, none;

    e := nops(i0);
    for opn: 0..cast(s64) e - 1 {
        phi: Gs_Phi; phi.values.allocator = temp; phi.blocks.allocator = temp;
        for active.list array_add(*phi.blocks, it);
        for new_insts array_add(*phi.values, op(it, cast(u32) opn));
        all_same := true;
        for phi.values if it != phi.values[0] { all_same = false; break; }
        if all_same continue;
        if !can_replace_operand_with_variable(i0, cast(u32) opn) return false, none;
        if gs_set_find(needed, *phi) >= 0 continue;
        same_type := true;
        for phi.values if vtype(it) != vtype(phi.values[0]) { same_type = false; break; }
        if !same_type return false, none;
        if (inst_op(i0) == .CALL || inst_op(i0) == .INVOKE) && opn == e - 1 {
            any_const := false;
            for phi.values if is_const(it) { any_const = true; break; }
            if any_const return false, none;
        }
        gs_set_insert(needed, *phi);
        for phi.values table_set(contents, it, true);
    }
    if gs_is_memory_inst(new_insts[0]) memory_inst_num.* += 1;
    cand: Gs_Candidate;
    inst_num.* += 1;
    cand.num_instructions = inst_num.*;
    cand.num_memory_insts = memory_inst_num.*;
    cand.num_blocks = cast(u32) active.list.count;
    cand.num_phis = cast(u32) needed.list.count;
    cand.blocks.allocator = temp;
    for active.list array_add(*cand.blocks, it);
    return true, cand;
}

// SinkingInstructionCandidate::calculateCost (unsigned arithmetic, then int)
gs_calculate_cost :: (c: *Gs_Candidate, num_orig_phis: u32, num_orig_blocks: u32) {
    extra: u32 = c.num_phis - num_orig_phis;
    split_edge_cost: u32 = ifx num_orig_blocks > c.num_blocks then cast(u32) 2 else 0;
    r: u32 = c.num_instructions * (c.num_blocks - 1) - extra * extra - split_edge_cost;
    c.cost = cast,no_check(s32) r;
}

// sinkBB
gs_sink_bb :: (g: *Gvn_Sink, bb_end: Value_Id) -> u32 {
    preds: [..] Value_Id; preds.allocator = temp;
    all: [..] Value_Id; all.allocator = temp;
    block_predecessors(bb_end, *all);
    for b: all {
        if !table_contains(*g.rpot_order, b) return 0;
        t := block_terminator(b);
        o := inst_op(t);
        if o == .BR || o == .CONDBR || o == .SWITCH array_add(*preds, b);
        else return 0;
    }
    if preds.count < 2 return 0;
    key :: (g: *Gvn_Sink, b: Value_Id) -> u32 { found, r := table_find(*g.rpot_order, b); if found return r; return 0; }
    for a: 1..preds.count - 1 {
        x := preds[a]; kx := key(g, x); b := a - 1;
        while b >= 0 && key(g, preds[b]) > kx { preds[b + 1] = preds[b]; b -= 1; }
        preds[b + 1] = x;
    }
    num_orig_preds := preds.count;
    {
        k := 0;
        for preds if num_successors(block_terminator(it)) == 1 { preds[k] = it; k += 1; }
        preds.count = k;
    }
    lri: Gs_Lri;
    lri.blocks.allocator = temp; lri.insts.allocator = temp; lri.active.list.allocator = temp;
    for preds array_add(*lri.blocks, it);
    gs_lri_reset(*lri);
    candidates: [..] Gs_Candidate; candidates.allocator = temp;
    inst_num: u32 = 0; memory_inst_num: u32 = 0;
    needed: Gs_Phi_Set; needed.list.allocator = temp;
    contents: Table(Value_Id, bool); contents.allocator = temp;
    for i: block_insts(bb_end) {
        if inst_op(i) != .PHI break;
        p := gs_modelled_phi_from_phi(g, i);
        gs_set_insert(*needed, *p);
        for p.values table_set(*contents, it, true);
    }
    num_orig_phis := cast(u32) needed.list.count;
    first_ambiguous: s64 = -1;   // index of the first candidate whose step compared address-order-dependent numbers
    while !lri.fail {
        g.ambiguous_step = false;
        ok, cand := gs_analyze_instruction_for_sinking(g, *lri, *inst_num, *memory_inst_num, *needed, *contents);
        if g.ambiguous_step && first_ambiguous < 0 {
            // with different numbers LLVM stops here (two blocks) or continues differently: only candidates before
            // this one are certain
            first_ambiguous = candidates.count;
        }
        if !ok break;
        gs_calculate_cost(*cand, num_orig_phis, cast(u32) preds.count);
        array_add(*candidates, cand);
        gs_lri_dec(*lri);
    }
    // stable_sort by Cost, descending
    for a: 1..candidates.count - 1 {
        x := candidates[a]; b := a - 1;
        while b >= 0 && x.cost > candidates[b].cost { candidates[b + 1] = candidates[b]; b -= 1; }
        candidates[b + 1] = x;
    }
    if first_ambiguous >= 0 && candidates.count > 0 && candidates[0].cost > 0 {
        // the candidates are sorted now. If LLVM's numbers differ it stops at the ambiguous step: its best is then
        // ours only if ours comes from an earlier step (the maximum of the full list is the maximum of the prefix)
        if cast(s64) candidates[0].num_instructions > first_ambiguous gs_not_reproducible("best");
    }
    if candidates.count == 0 || candidates[0].cost <= 0 return 0;
    c := candidates[0];
    insert_bb := bb_end;
    if c.blocks.count < num_orig_preds {
        insert_bb = split_block_predecessors(bb_end, c.blocks, ".gvnsink.split", null, null);
        if insert_bb == NONE return 0;
    }
    for 0..cast(s64) c.num_instructions - 1 gs_sink_last_instruction(c.blocks, insert_bb);
    return c.num_instructions;
}

// Instruction::moveBefore(It) for an iterator with the head bit (getFirstInsertionPt, begin()): the moved
// instruction's records stay where it was (handleMarkerRemoval), the destination's records stay on `pos`
gs_move_before_head :: (i: Value_Id, pos: Value_Id) {
    if i == pos return;
    if inst(i).records {
        nx := inst_next(i);
        assert(nx != NONE, "moving a terminator with debug records");
        records_prepend(nx, records_take(i));
    }
    inst_unlink(i);
    inst_insert_before(i, pos);
}

// sinkLastInstruction
gs_sink_last_instruction :: (blocks: [] Value_Id, bb_end: Value_Id) {
    insts: [..] Value_Id; insts.allocator = temp;
    for blocks array_add(*insts, inst(block_terminator(it)).prev);
    i0 := insts[0];
    new_ops: [..] Value_Id; new_ops.allocator = temp;
    e := nops(i0);
    for o: 0..cast(s64) e - 1 {
        need_phi := false;
        for insts if op(it, cast(u32) o) != op(i0, cast(u32) o) { need_phi = true; break; }
        if !need_phi { array_add(*new_ops, op(i0, cast(u32) o)); continue; }
        opv := op(i0, cast(u32) o);
        pn := create_phi(vtype(opv), cast(u32) insts.count);
        set_name(pn, tconcat(vname(opv), ".sink"));
        insert_at_position(pn, bb_end, block_first(bb_end), true);
        ic_reinsert_name(pn);
        for insts phi_add_incoming(pn, op(it, cast(u32) o), inst_block(it));
        array_add(*new_ops, pn);
    }
    for o: 0..cast(s64) e - 1 use_set(op_use(i0, cast(u32) o), new_ops[o]);
    gs_move_before_head(i0, block_first_insertion_pt(bb_end));
    for insts if it != i0 {
        combine_metadata_for_cse(i0, it, true);
        and_ir_flags(i0, it);
    }
    for insts if it != i0 {
        rauw_with_metadata(it, i0);
        apply_merged_location(i0, get_metadata(i0, MDK_DBG), get_metadata(it, MDK_DBG));
    }
    gs_fold_pointless_phi_nodes(bb_end);
    for insts if it != i0 erase_inst_with_metadata(it);
}

// foldPointlessPHINodes
gs_fold_pointless_phi_nodes :: (bb: Value_Id) {
    i := block_first(bb);
    while i != NONE && inst_op(i) == .PHI {
        pn := i;
        i = inst_next(i);
        n := nops(pn);
        same := true;
        for k: 0..cast(s64) n - 1 if op(pn, cast(u32) k) != op(pn, 0) { same = false; break; }
        if !same continue;
        if op(pn, 0) != pn rauw_with_metadata(pn, op(pn, 0));
        else rauw_with_metadata(pn, const_poison(vtype(pn)));
        erase_inst_with_metadata(pn);
    }
}

gvn_sink_run :: (f: Value_Id) -> Preserved {
    g := New(Gvn_Sink,, allocator = temp);
    g.f = f;
    g.value_numbering.allocator = temp; g.hash_numbering.allocator = temp; g.reachable.allocator = temp;
    g.rpot_order.allocator = temp; g.multiset_sig.allocator = temp; g.ambiguous.allocator = temp;
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(f), *po);
    rpot: [..] Value_Id; rpot.allocator = temp;
    for < po array_add(*rpot, it);
    for rpot table_set(*g.reachable, it, true);
    ordering: u32 = 0;
    ordering += 1; table_set(*g.rpot_order, rpot[0], ordering);
    for rpot if block_has_predecessors(it) { ordering += 1; table_set(*g.rpot_order, it, ordering); }
    num_sunk: u32 = 0;
    for rpot num_sunk += gs_sink_bb(g, it);
    if num_sunk == 0 return PRESERVE_ALL;
    pa: Preserved;
    return pa;
}
