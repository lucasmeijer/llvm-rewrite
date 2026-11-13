// IR PGO instrumentation (`pgo-instr-gen`, PGOInstrumentationGen; `ctx-instr-gen` is not ported): the CFG minimum
// spanning tree, the CFG hash, llvm.instrprof.increment on the edges not in the MST (critical edges are split),
// llvm.instrprof.increment.step for selects, llvm.instrprof.value.profile for indirect calls and memop sizes.
// Ported from llvm/lib/Transforms/Instrumentation/PGOInstrumentation.cpp (FuncPGOInstrumentation,
// FunctionInstrumenter::instrument, SelectInstVisitor, createIRLevelProfileFlagVar, InstrumentAllFunctions,
// skipPGOGen, renameComdatFunction), llvm/include/llvm/Transforms/Instrumentation/CFGMST.h,
// llvm/lib/Transforms/Instrumentation/ValueProfileCollector.cpp + ValueProfilePlugins.inc and
// llvm/include/llvm/Analysis/IndirectCallVisitor.h (findIndirectCalls). JamCRC from llvm/lib/Support/CRC.cpp.
// Not ported (loud): -pgo-block-coverage (BlockCoverageInference.cpp), indirectbr critical edges
// (SplitIndirectBrCriticalEdges with IgnoreBlocksWithoutPHI = false), vtable value profiling.

pgo_gen_cl: struct {
    disable_vp := false;                    // -disable-vp
    do_comdat_renaming := false;            // -do-comdat-renaming
    instr_select := true;                   // -pgo-instr-select
    instr_memop := true;                    // -pgo-instr-memop
    instrument_entry := false;              // -pgo-instrument-entry
    instrument_loop_entries := false;       // -pgo-instrument-loop-entries
    function_entry_coverage := false;       // -pgo-function-entry-coverage
    block_coverage := false;                // -pgo-block-coverage
    temporal_instrumentation := false;      // -pgo-temporal-instrumentation
    function_size_threshold: s64 = 0;       // -pgo-function-size-threshold
    critical_edge_threshold: s64 = 20000;   // -pgo-critical-edge-threshold
    cold_instrument_entry_threshold: s64 = 0;   // -pgo-cold-instrument-entry-threshold
    treat_unknown_as_cold := false;         // -pgo-treat-unknown-as-cold
    instrument_cold_function_only := false; // -pgo-instrument-cold-function-only
    memop_optimize_memcmp_bcmp := true;     // -pgo-memop-optimize-memcmp-bcmp (PGOMemOPSizeOpt.cpp)
};

// ---------------------------------------------------------------- JamCRC

crc32_table: [256] u32;
crc32_table_ready := false;
jam_crc_update :: (crc_in: u32, data: [] u8) -> u32 {
    if !crc32_table_ready {
        for i: 0..255 {
            c := cast(u32) i;
            for 0..7 c = ifx (c & 1) then (0xEDB88320 ^ (c >> 1)) else (c >> 1);
            crc32_table[i] = c;
        }
        crc32_table_ready = true;
    }
    // JamCRC::update: undo the CRC-32 init, crc32, undo the xor-out = the raw table walk
    c := crc_in;
    for data c = crc32_table[(c ^ it) & 0xFF] ^ (c >> 8);
    return c;
}

// ---------------------------------------------------------------- CFGMST

Mst_Edge :: struct {
    src: Value_Id;   // NONE = the fake entry node
    dest: Value_Id;  // NONE = the fake exit node
    weight: u64;
    in_mst: bool;
    removed: bool;
    is_critical: bool;
}
Mst_Bb_Info :: struct { group: s32; index: u32; rank: u32; }

Cfg_Mst :: struct {
    f: Value_Id;
    edges: [..] Mst_Edge;
    bb_infos: [..] Mst_Bb_Info;
    bb_info_of: Table(Value_Id, s32);   // BBInfos (NONE is the fake node)
    exit_block_found: bool;
    bpi: *Bpi;
    bfi: *Bfi;
    li: *Loop_Info;
    instrument_func_entry: bool;
    instrument_loop_entries: bool;
}

mst_find_bb_info :: (m: *Cfg_Mst, b: Value_Id) -> s32 {
    found, i := table_find(*m.bb_info_of, b);
    return ifx found then i else -1;
}
mst_find_and_compress_group :: (m: *Cfg_Mst, g: s32) -> s32 {
    if m.bb_infos[g].group != g m.bb_infos[g].group = mst_find_and_compress_group(m, m.bb_infos[g].group);
    return m.bb_infos[g].group;
}
mst_union_groups :: (m: *Cfg_Mst, b1: Value_Id, b2: Value_Id) -> bool {
    g1 := mst_find_and_compress_group(m, mst_find_bb_info(m, b1));
    g2 := mst_find_and_compress_group(m, mst_find_bb_info(m, b2));
    if g1 == g2 return false;
    if m.bb_infos[g1].rank < m.bb_infos[g2].rank m.bb_infos[g1].group = g2;
    else {
        m.bb_infos[g2].group = g1;
        if m.bb_infos[g1].rank == m.bb_infos[g2].rank m.bb_infos[g1].rank += 1;
    }
    return true;
}
// addEdge
mst_add_edge :: (m: *Cfg_Mst, src: Value_Id, dest: Value_Id, w: u64) -> s64 {
    index := cast(u32) m.bb_infos.count;
    if !table_contains(*m.bb_info_of, src) {
        array_add(*m.bb_infos, .{cast(s32) m.bb_infos.count, index, 0});
        table_set(*m.bb_info_of, src, cast(s32) m.bb_infos.count - 1);
        index += 1;
    }
    if !table_contains(*m.bb_info_of, dest) {
        array_add(*m.bb_infos, .{cast(s32) m.bb_infos.count, index, 0});
        table_set(*m.bb_info_of, dest, cast(s32) m.bb_infos.count - 1);
    }
    e: Mst_Edge; e.src = src; e.dest = dest; e.weight = w;
    array_add(*m.edges, e);
    return m.edges.count - 1;
}

// buildEdges
mst_build_edges :: (m: *Cfg_Mst) {
    f := m.f;
    entry := fn_entry(f);
    entry_weight: u64 = ifx m.bfi then bfi_get_block_freq(m.bfi, entry) else 2;
    if m.instrument_func_entry entry_weight = 0;
    entry_incoming := mst_add_edge(m, NONE, entry, entry_weight);
    entry_outgoing: s64 = -1; exit_outgoing: s64 = -1; exit_incoming: s64 = -1;
    max_entry_out: u64 = 0; max_exit_out: u64 = 0; max_exit_in: u64 = 0;
    if num_successors(block_terminator(entry)) == 0 {
        mst_add_edge(m, entry, NONE, entry_weight);
        return;
    }
    CRITICAL_EDGE_MULTIPLIER : u64 : 1000;
    for bb: fn_blocks(f) {
        ti := block_terminator(bb);
        bb_weight: u64 = ifx m.bfi then bfi_get_block_freq(m.bfi, bb) else 2;
        weight: u64 = 2;
        n := num_successors(ti);
        if n {
            for i: 0..n-1 {
                target := get_successor(ti, i);
                critical := is_critical_edge(ti, i);
                scale := bb_weight;
                if critical {
                    if scale < U64_MAX_PGO / CRITICAL_EDGE_MULTIPLIER scale *= CRITICAL_EDGE_MULTIPLIER;
                    else scale = U64_MAX_PGO;
                }
                if m.bpi weight = bp_scale(bpi_edge_probability(m.bpi, bb, target), scale);
                if m.instrument_loop_entries && li_is_loop_header(m.li, target) {
                    tl := li_loop_for(m.li, target);
                    if !li_contains(m.li, tl, bb) weight = 0;
                }
                if weight == 0 weight += 1;
                e := mst_add_edge(m, bb, target, weight);
                m.edges[e].is_critical = critical;
                // handleCoroSuspendEdge
                if is_presplit_coro_suspend_exit_edge(bb, target) m.edges[e].removed = true;
                if bb == entry && weight > max_entry_out { max_entry_out = weight; entry_outgoing = e; }
                tt := block_terminator(target);
                if tt != NONE && num_successors(tt) == 0 && weight > max_exit_in { max_exit_in = weight; exit_incoming = e; }
            }
        } else {
            m.exit_block_found = true;
            e := mst_add_edge(m, bb, NONE, bb_weight);
            if bb_weight > max_exit_out { max_exit_out = bb_weight; exit_outgoing = e; }
        }
    }
    entry_in := entry_weight;
    if entry_in >= max_exit_out && entry_in * 2 < max_exit_out * 3 {
        m.edges[entry_incoming].weight = max_exit_out;
        m.edges[exit_outgoing].weight = entry_in + 1;
    }
    if max_entry_out >= max_exit_in && max_entry_out * 2 < max_exit_in * 3 {
        m.edges[entry_outgoing].weight = max_exit_in;
        m.edges[exit_incoming].weight = max_entry_out + 1;
    }
}
pgo_debug_mst := false;
U64_MAX_PGO : u64 : 0xFFFF_FFFF_FFFF_FFFF;

// sortEdgesByWeight (stable, descending)
mst_sort_edges_by_weight :: (m: *Cfg_Mst) {
    n := m.edges.count;
    tmp := NewArray(n, Mst_Edge,, allocator = temp);
    // merge sort: stable
    merge :: (a: [] Mst_Edge, t: [] Mst_Edge) {
        if a.count < 2 return;
        h := a.count / 2;
        l := array_view(a, 0, h); r := array_view(a, h, a.count - h);
        merge(l, t); merge(r, t);
        i := 0; j := 0; k := 0;
        while i < l.count && j < r.count {
            if r[j].weight > l[i].weight { t[k] = r[j]; j += 1; } else { t[k] = l[i]; i += 1; }
            k += 1;
        }
        while i < l.count { t[k] = l[i]; i += 1; k += 1; }
        while j < r.count { t[k] = r[j]; j += 1; k += 1; }
        for x: 0..a.count-1 a[x] = t[x];
    }
    merge(m.edges, tmp);
}

// computeMinimumSpanningTree
mst_compute :: (m: *Cfg_Mst) {
    for * e: m.edges {
        if e.removed continue;
        if e.is_critical && e.dest != NONE && block_is_landing_pad(e.dest) {
            if mst_union_groups(m, e.src, e.dest) e.in_mst = true;
        }
    }
    for * e: m.edges {
        if e.removed continue;
        if !m.exit_block_found && e.src == NONE continue;
        if mst_union_groups(m, e.src, e.dest) e.in_mst = true;
    }
}

cfg_mst_build :: (m: *Cfg_Mst) {
    m.edges.allocator = temp; m.bb_infos.allocator = temp; m.bb_info_of.allocator = temp;
    mst_build_edges(m);
    mst_sort_edges_by_weight(m);
    mst_compute(m);
    if m.edges.count > 1 && m.instrument_func_entry {
        t := m.edges[0]; m.edges[0] = m.edges[m.edges.count - 1]; m.edges[m.edges.count - 1] = t;
    }
}

// ---------------------------------------------------------------- value profile candidates

Vp_Candidate :: struct { v: Value_Id; insert_pt: Value_Id; annotated: Value_Id; }

// CallBase::isIndirectCall
pgo_is_indirect_call :: (c: Value_Id) -> bool {
    callee := call_callee(c);
    if vkind(callee) == .FUNCTION || is_const(callee) return false;
    return vkind(callee) != .INLINE_ASM;
}

// MemIntrinsicPlugin / IndirectCallPromotionPlugin (ValueProfilePlugins.inc)
vp_collect :: (f: Value_Id, kind: u32, out: *[..] Vp_Candidate) {
    if kind == IPVK_MEMOP_SIZE {
        for b: fn_blocks(f) for i: block_insts(b) {
            if inst_op(i) != .CALL continue;
            if is_mem_intrinsic_inst(i) {
                len := op(i, 2);
                if vkind(len) == .C_INT continue;
                array_add(out, .{len, i, i});
            } else if call_iid(i) == NOT_INTRINSIC || !glob(call_called_function(i)).intrinsic {
                if !pgo_gen_cl.memop_optimize_memcmp_bcmp continue;
                if call_called_function(i) == NONE continue;
                ok, lf := tli_lookup_call(i);
                if ok && (lf == .memcmp || lf == .bcmp) {
                    len := op(i, 2);
                    if vkind(len) == .C_INT continue;
                    array_add(out, .{len, i, i});
                }
            }
        }
    } else if kind == IPVK_INDIRECT_CALL_TARGET {
        for b: fn_blocks(f) for i: block_insts(b) {
            if !is_call_base(i) continue;
            if pgo_is_indirect_call(i) array_add(out, .{call_callee(i), i, i});
        }
    } else fatal("pgo-instr-gen: vtable value profiling is not supported");
}

// ---------------------------------------------------------------- FuncPGOInstrumentation

Func_Pgo :: struct {
    f: Value_Id;
    is_cs: bool;
    value_sites: [IPVK_LAST + 1] [..] Vp_Candidate;
    num_selects: u32;
    func_name: string;
    func_name_var: Value_Id = NONE;
    function_hash: u64;
    mst: Cfg_Mst;
}

// SelectInstVisitor in VM_counting mode
pgo_count_selects :: (f: Value_Id) -> u32 {
    if !pgo_gen_cl.instr_select || pgo_gen_cl.function_entry_coverage || pgo_gen_cl.block_coverage return 0;
    n: u32 = 0;
    for b: fn_blocks(f) for i: block_insts(b) if inst_op(i) == .SELECT && !is_vector_type(vtype(op(i, 0))) n += 1;
    return n;
}

// computeCFGHash
fpi_compute_cfg_hash :: (fp: *Func_Pgo) {
    indexes: [..] u8; indexes.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    for bb: fn_blocks(fp.f) {
        succs.count = 0;
        block_successors(bb, *succs);
        for s: succs {
            bi := mst_find_bb_info(*fp.mst, s);
            if bi < 0 continue;
            idx := fp.mst.bb_infos[bi].index;
            for j: 0..3 array_add(*indexes, cast(u8) ((idx >> (j * 8)) & 0xFF));
        }
    }
    jc := jam_crc_update(0xFFFF_FFFF, indexes);
    jch: u32 = 0xFFFF_FFFF;
    upd :: (c: u32, n: u64) -> u32 {
        d: [8] u8;
        for k: 0..7 d[k] = cast(u8) ((n >> (k * 8)) & 0xFF);
        return jam_crc_update(c, d);
    }
    jch = upd(jch, fp.num_selects);
    jch = upd(jch, cast(u64) fp.value_sites[IPVK_INDIRECT_CALL_TARGET].count);
    jch = upd(jch, cast(u64) fp.value_sites[IPVK_MEMOP_SIZE].count);
    if pgo_gen_cl.block_coverage fatal("pgo-instr-gen: -pgo-block-coverage (BlockCoverageInference) is not supported");
    jch = upd(jch, cast(u64) fp.mst.edges.count);
    fp.function_hash = ((cast(u64) jch) << 28) + jc;
    fp.function_hash &= 0x0FFF_FFFF_FFFF_FFFF;   // NamedInstrProfRecord::FUNC_HASH_MASK
    if fp.is_cs fp.function_hash |= cast(u64) 1 << 60;   // setCSFlagInHash
}

// canRenameComdat
pgo_can_rename_comdat :: (f: Value_Id, members: *Table(s32, [..] Value_Id)) -> bool {
    if !pgo_gen_cl.do_comdat_renaming || !can_rename_comdat_func(f, true) return false;
    c := glob(f).comdat;
    l := table_find_pointer(members, c);
    if l for l.* if vkind(it) != .FUNCTION || it != f return false;
    return true;
}

// renameComdatFunction
fpi_rename_comdat_function :: (fp: *Func_Pgo, members: *Table(s32, [..] Value_Id)) {
    f := fp.f;
    if !pgo_can_rename_comdat(f, members) return;
    orig_name := copy_string(vname(f),, temp);
    new_name := tprint("%.%", orig_name, fp.function_hash);
    set_name(f, new_name);
    // GlobalAlias::create(WeakAnyLinkage, OrigName, &F)
    ga := new_global(.ALIAS, glob(f).value_type, glob(f).addrspace, 1);
    gv_set_linkage(ga, .WEAK_ANY);
    set_op(ga, 0, f);
    array_add(*ir.m_aliases, ga);
    set_name(ga, orig_name);
    fp.func_name = tprint("%.%", fp.func_name, fp.function_hash);
    if glob(f).comdat < 0 {
        nc := get_comdat(new_name);
        gv_set_linkage(f, .LINKONCE_ODR);
        glob(f).comdat = nc;
        return;
    }
    orig := glob(f).comdat;
    nc := get_comdat(tprint("%.%", ir.comdats[orig].name, fp.function_hash));
    ir.comdats[nc].kind = ir.comdats[orig].kind;
    l := table_find_pointer(members, orig);
    if l for l.* glob(it).comdat = nc;
}

// FuncPGOInstrumentation::FuncPGOInstrumentation
fpi_init :: (fp: *Func_Pgo, f: Value_Id, members: *Table(s32, [..] Value_Id), create_global_var: bool, bpi: *Bpi, bfi: *Bfi, li: *Loop_Info, is_cs: bool, instrument_func_entry: bool, instrument_loop_entries: bool) {
    fp.f = f; fp.is_cs = is_cs;
    for * fp.value_sites it.allocator = temp;
    fp.mst.f = f; fp.mst.bpi = bpi; fp.mst.bfi = bfi; fp.mst.li = li;
    fp.mst.instrument_func_entry = instrument_func_entry;
    fp.mst.instrument_loop_entries = instrument_loop_entries;
    cfg_mst_build(*fp.mst);
    fp.num_selects = pgo_count_selects(f);
    vp_collect(f, IPVK_MEMOP_SIZE, *fp.value_sites[IPVK_MEMOP_SIZE]);
    if !is_cs {
        vp_collect(f, IPVK_INDIRECT_CALL_TARGET, *fp.value_sites[IPVK_INDIRECT_CALL_TARGET]);
        if instrprof_cl.enable_vtable_value_profiling vp_collect(f, IPVK_VTABLE_TARGET, *fp.value_sites[IPVK_VTABLE_TARGET]);
    }
    fp.func_name = irpgo_object_name(f);
    fpi_compute_cfg_hash(fp);
    if members.count fpi_rename_comdat_function(fp, members);
    if create_global_var fp.func_name_var = create_pgo_func_name_var(glob(f).linkage, fp.func_name);
}

// getInstrBB
fpi_get_instr_bb :: (fp: *Func_Pgo, ei: s64) -> Value_Id {
    e := fp.mst.edges[ei];
    if e.in_mst || e.removed return NONE;
    src := e.src; dest := e.dest;
    if src == NONE return dest;
    if dest == NONE return src;
    can_instrument :: (b: Value_Id) -> Value_Id { return ifx block_first_non_phi_or_dbg_or_alloca(b) == NONE then NONE else b; }
    ti := block_terminator(src);
    if num_successors(ti) <= 1 return can_instrument(src);
    if !e.is_critical return can_instrument(dest);
    succ_num: u32 = 0;
    for k: 0..num_successors(ti)-1 if get_successor(ti, k) == dest { succ_num = k; break; }
    instr_bb: Value_Id = NONE;
    if inst_op(ti) != .INDIRECTBR {
        o: Crit_Edge_Options;
        instr_bb = split_critical_edge(ti, succ_num, *o);
    }
    if instr_bb == NONE return NONE;
    mst_add_edge(*fp.mst, src, instr_bb, 0);
    ne := mst_add_edge(*fp.mst, instr_bb, dest, 0);
    fp.mst.edges[ne].in_mst = true;
    fp.mst.edges[ei].removed = true;
    return can_instrument(instr_bb);
}

// getInstrumentBBs
fpi_get_instrument_bbs :: (fp: *Func_Pgo, out: *[..] Value_Id) {
    n := fp.mst.edges.count;   // the edge list is snapshotted: edges added while splitting are not visited
    for k: 0..n-1 {
        b := fpi_get_instr_bb(fp, k);
        if b != NONE array_add(out, b);
    }
}

// SelectInstVisitor::instrumentOneSelectInst (VM_instrument over the whole function)
pgo_instrument_selects :: (f: Value_Id, idx: *u32, total: u32, name_var: Value_Id, hash: u64) {
    if !pgo_gen_cl.instr_select || pgo_gen_cl.function_entry_coverage || pgo_gen_cl.block_coverage return;
    for bb: fn_blocks(f) for si: block_insts(bb) {
        if inst_op(si) != .SELECT || is_vector_type(vtype(op(si, 0))) continue;
        b: Irb; irb_set_before(*b, si);
        cond := op(si, 0);
        if !is_guaranteed_not_to_be_poison(cond) cond = irb_freeze(*b, cond);
        step := irb_cast(*b, .ZEXT, cond, ir.t_i64);
        np := ce_pointer_bitcast_or_addrspacecast(name_var, type_ptr(0));
        step_fn := get_or_insert_intrinsic_declaration(intrinsic_id_by_name("llvm.instrprof.increment.step"));
        irb_call(*b, step_fn, .[np, const_int(ir.t_i64, hash), const_int(ir.t_i32, total), const_int(ir.t_i32, idx.*), step]);
        idx.* += 1;
    }
}

// SplitIndirectBrCriticalEdges(F, IgnoreBlocksWithoutPHI, BPI, BFI) without a DomTreeUpdater
// (llvm/lib/Transforms/Utils/BreakCriticalEdges.cpp; findIBRPredecessor is cgp_find_ibr_predecessor)
split_indirectbr_critical_edges :: (f: Value_Id, ignore_blocks_without_phi: bool, bpi: *Bpi, bfi: *Bfi) -> bool {
    targets: [..] Value_Id; targets.allocator = temp;
    for bb: fn_blocks(f) {
        t := block_terminator(bb);
        if t == NONE || inst_op(t) != .INDIRECTBR continue;
        for k: 0..cast(s64) num_successors(t) - 1 {
            s := get_successor(t, cast(u32) k);
            if !array_find(targets, s) array_add(*targets, s);
        }
    }
    if targets.count == 0 return false;
    update := bpi != null && bfi != null;
    changed := false;
    for target: targets {
        if ignore_blocks_without_phi && !is_phi(block_first(target)) continue;
        other_preds: [..] Value_Id; other_preds.allocator = temp;
        ibr_pred := cgp_find_ibr_predecessor(target, *other_preds);
        if ibr_pred == NONE || other_preds.count == 0 continue;
        first_non_phi := block_first_non_phi(target);
        if is_eh_pad(first_non_phi) || block_is_landing_pad(target) continue;
        probs: [] u32;
        if update {
            tt := block_terminator(target);
            nsucc := num_successors(tt);
            probs = NewArray(nsucc, u32,, temp);
            for k: 0..cast(s64) nsucc - 1 probs[k] = bpi_edge_probability_idx(bpi, target, cast(u32) k);
            bpi_erase_block(bpi, target);
        }
        body := split_block(target, first_non_phi, null, null, null, ".split", true);   // getFirstNonPHIIt: head bit
        if update {
            bpi_set_edge_probability(bpi, body, probs);
            bfi_set_block_freq(bfi, body, bfi_get_block_freq(bfi, target));
        }
        if ibr_pred == target ibr_pred = body;
        vm: Value_Map;
        vmap_init(*vm);
        direct := clone_basic_block(target, *vm, ".clone", f, true);
        for i: block_insts(direct) remap_source_atom(*vm, i);
        freq_direct: u64 = 0;
        for pred: other_preds {
            src := ifx pred != target then pred else body;
            replace_uses_of_with(block_terminator(src), target, direct);
            if update freq_direct = bm_add(freq_direct, bf_mul_prob(bfi_get_block_freq(bfi, src), bpi_edge_probability(bpi, src, direct)));
        }
        if update {
            bfi_set_block_freq(bfi, direct, freq_direct);
            bfi_set_block_freq(bfi, target, bm_sub(bfi_get_block_freq(bfi, target), freq_direct));
        }
        indirect := block_first(target);
        end := block_first_non_phi(target);
        dir := block_first(direct);
        merge_insert := block_first_insertion_pt(body);
        while indirect != end {
            dir_phi := dir; ind_phi := indirect;
            insert_pt := indirect;
            phi_remove_incoming_block(dir_phi, ibr_pred, false);
            dir = inst_next(dir);
            indirect = inst_next(indirect);
            new_ind := create_phi(vtype(ind_phi), 1);
            insert_at_position(new_ind, target, insert_pt, false);
            set_name(new_ind, "ind");
            phi_add_incoming(new_ind, phi_incoming_value_for_block(ind_phi, ibr_pred), ibr_pred);
            set_metadata(new_ind, 0, get_metadata(ind_phi, 0));
            merge := create_phi(vtype(ind_phi), 2);
            insert_at_position(merge, body, merge_insert, true);
            set_name(merge, "merge");
            phi_add_incoming(merge, new_ind, target);
            phi_add_incoming(merge, dir_phi, direct);
            set_metadata(merge, 0, merged_location(get_metadata(dir_phi, 0), get_metadata(ind_phi, 0)));
            rauw_with_metadata(ind_phi, merge);
            erase_inst_with_metadata(ind_phi);
        }
        changed = true;
    }
    return changed;
}

// FunctionInstrumenter::instrument
pgo_instrument_function :: (f: Value_Id, members: *Table(s32, [..] Value_Id), bpi: *Bpi, bfi: *Bfi, li: *Loop_Info, is_cs: bool) {
    if !pgo_gen_cl.block_coverage split_indirectbr_critical_edges(f, false, bpi, bfi);
    fp: Func_Pgo;
    fpi_init(*fp, f, members, true, bpi, bfi, li, is_cs, pgo_gen_cl.instrument_entry, pgo_gen_cl.instrument_loop_entries);
    name := fp.func_name_var;
    cfg_hash := const_int(ir.t_i64, fp.function_hash);
    np := ce_pointer_bitcast_or_addrspacecast(name, type_ptr(0));
    entry := fn_entry(f);
    if pgo_gen_cl.function_entry_coverage {
        b: Irb; irb_set_at(*b, entry, block_first_non_phi_or_dbg_or_alloca(entry), false);
        cover := get_or_insert_intrinsic_declaration(intrinsic_id_by_name("llvm.instrprof.cover"));
        irb_call(*b, cover, .[np, cfg_hash, const_int(ir.t_i32, 1), const_int(ir.t_i32, 0)]);
        return;
    }
    instrument_bbs: [..] Value_Id; instrument_bbs.allocator = temp;
    if pgo_debug_mst for e: fp.mst.edges print("edge % -> % w=% mst=% rm=% crit=%\n", ifx e.src == NONE then "-" else vname(e.src), ifx e.dest == NONE then "-" else vname(e.dest), e.weight, e.in_mst, e.removed, e.is_critical);
    fpi_get_instrument_bbs(*fp, *instrument_bbs);
    num_counters := cast(u32) instrument_bbs.count + fp.num_selects;
    i: u32 = 0;
    if pgo_gen_cl.temporal_instrumentation {
        num_counters += ifx pgo_gen_cl.block_coverage then cast(u32) 8 else 1;
        b: Irb; irb_set_at(*b, entry, block_first_non_phi_or_dbg_or_alloca(entry), false);
        ts := get_or_insert_intrinsic_declaration(intrinsic_id_by_name("llvm.instrprof.timestamp"));
        irb_call(*b, ts, .[np, cfg_hash, const_int(ir.t_i32, num_counters), const_int(ir.t_i32, i)]);
        i += ifx pgo_gen_cl.block_coverage then cast(u32) 8 else 1;
    }
    for bb: instrument_bbs {
        inc := get_or_insert_intrinsic_declaration(intrinsic_id_by_name(ifx pgo_gen_cl.block_coverage then "llvm.instrprof.cover" else "llvm.instrprof.increment"));
        b: Irb; irb_set_at(*b, bb, block_first_non_phi_or_dbg_or_alloca(bb), false);
        irb_call(*b, inc, .[np, cfg_hash, const_int(ir.t_i32, num_counters), const_int(ir.t_i32, i)]);
        i += 1;
    }
    pgo_instrument_selects(f, *i, num_counters, name, fp.function_hash);
    assert(i == num_counters);
    if pgo_gen_cl.disable_vp || il_is_gpu_triple() return;
    block_colors: Table(Value_Id, [..] Value_Id); block_colors.allocator = temp;
    if glob(f).has_personality && is_scoped_eh_personality(classify_eh_personality(fn_personality(f))) color_eh_funclets(f, *block_colors);
    for kind: 0..IPVK_LAST {
        site: u32 = 0;
        if kind == IPVK_MEMOP_SIZE && !pgo_gen_cl.instr_memop continue;
        for cand: fp.value_sites[kind] {
            b: Irb; irb_set_before(*b, cand.insert_pt);
            to_profile: Value_Id = NONE;
            t := vtype(cand.v);
            if is_int_type(t) to_profile = irb_zext_or_trunc(*b, cand.v, ir.t_i64);
            else if is_ptr_type(t) to_profile = irb_cast(*b, .PTRTOINT, cand.v, ir.t_i64);
            assert(to_profile != NONE, "value profiling Value is of unexpected type");
            np2 := ce_pointer_bitcast_or_addrspacecast(name, type_ptr(0));
            vp := get_or_insert_intrinsic_declaration(intrinsic_id_by_name("llvm.instrprof.value.profile"));
            c := irb_call(*b, vp, .[np2, const_int(ir.t_i64, fp.function_hash), to_profile, const_int(ir.t_i32, cast(u64) kind), const_int(ir.t_i32, site)]);
            pgo_populate_eh_operand_bundle(c, cand.annotated, *block_colors);
            site += 1;
        }
    }
}

// populateEHOperandBundle: give the new value-profiling call `c` the funclet bundle of its candidate
pgo_populate_eh_operand_bundle :: (c: Value_Id, orig: Value_Id, colors: *Table(Value_Id, [..] Value_Id)) {
    if !is_call_base(orig) return;
    pad: Value_Id = NONE;
    cf := call_called_function(orig);
    is_intrinsic := inst_op(orig) == .CALL && cf != NONE && glob(cf).intrinsic;
    if !is_intrinsic {
        k := call_bundle_index(orig, "funclet");
        if k < 0 return;
        b, e := call_bundle_range(orig, cast(u32) k);
        assert(e == b + 1);
        pad = op(orig, b);
    } else {
        if colors.count == 0 return;
        cv := table_find_pointer(colors, inst(orig).parent);
        assert(cv != null && cv.count == 1, "non-unique color for block!");
        p := block_first_non_phi(cv.*[0]);
        if p == NONE || !is_eh_pad(p) return;
        pad = p;
    }
    nc := call_add_bundle(c, "funclet", .[pad]);
    inst_insert_before(nc, c);
    erase_inst_with_metadata(c);
}

il_is_gpu_triple :: () -> bool { il: Instr_Lowerer; il.tt = triple_parse(ir.triple); return il_is_gpu(*il); }

// createIRLevelProfileFlagVar
create_ir_level_profile_flag_var :: (cs: bool) -> Value_Id {
    INSTR_PROF_RAW_VERSION :: 11;
    v: u64 = INSTR_PROF_RAW_VERSION | VARIANT_MASK_IR_PROF;
    if cs v |= cast(u64) 1 << 57;
    if pgo_gen_cl.instrument_entry v |= cast(u64) 1 << 58;
    if pgo_gen_cl.instrument_loop_entries v |= cast(u64) 1 << 55;
    if instrprof_lower_cl.profile_correlate == 1 v |= cast(u64) 1 << 59;
    if pgo_gen_cl.function_entry_coverage v |= (cast(u64) 1 << 60) | (cast(u64) 1 << 61);
    if pgo_gen_cl.block_coverage v |= cast(u64) 1 << 60;
    if pgo_gen_cl.temporal_instrumentation v |= cast(u64) 1 << 63;
    gv := gv_create(ir.t_i64, true, .WEAK_ANY, const_int(ir.t_i64, v), INSTR_PROF_RAW_VERSION_VAR, NONE, 0, dl.globals_as);
    gv_set_visibility(gv, 1);
    if triple_supports_comdat() {
        gv_set_linkage(gv, .EXTERNAL);
        glob(gv).comdat = get_comdat(INSTR_PROF_RAW_VERSION_VAR);
    }
    return gv;
}

// skipPGOUse / skipPGOGen
pgo_skip_use :: (f: Value_Id) -> bool {
    if is_declaration(f) return true;
    n := 0;
    for bb: fn_blocks(f) {
        t := block_terminator(bb);
        for k: 0..cast(s64) num_successors(t) - 1 if is_critical_edge(t, cast(u32) k) n += 1;
    }
    return n > pgo_gen_cl.critical_edge_threshold;
}
pgo_skip_gen :: (f: Value_Id) -> bool {
    if pgo_skip_use(f) return true;
    if fn_has_fn_attr(f, .Naked) || fn_has_fn_attr(f, .NoProfile) || fn_has_fn_attr(f, .SkipProfile) return true;
    count := 0;
    for fn_insts(f) count += 1;
    if count < pgo_gen_cl.function_size_threshold return true;
    if pgo_gen_cl.instrument_cold_function_only {
        ok, ec := fn_entry_count(f);
        if ok return ec > cast(u64) pgo_gen_cl.cold_instrument_entry_threshold;
        return !pgo_gen_cl.treat_unknown_as_cold;
    }
    return false;
}

// InstrumentAllFunctions + PGOInstrumentationGen::run (FDO)
pgo_instr_gen_run :: () -> Preserved {
    create_ir_level_profile_flag_var(false);
    members: Table(s32, [..] Value_Id); members.allocator = temp;
    if pgo_gen_cl.do_comdat_renaming {
        add :: (members: *Table(s32, [..] Value_Id), g: Value_Id) {
            c := glob(g).comdat;
            if c < 0 return;
            l := table_find_pointer(members, c);
            if !l { e: [..] Value_Id; e.allocator = temp; l = table_add(members, c, e); }
            array_add(l, g);
        }
        for ir.m_functions add(*members, it);
        for ir.m_globals add(*members, it);
        for ir.m_aliases add(*members, it);
    }
    fns: [..] Value_Id; fns.allocator = temp;
    for ir.m_functions array_add(*fns, it);
    for f: fns {
        if pgo_skip_gen(f) continue;
        bpi := get_bpi(f);
        bfi := get_bfi(f);
        li := get_loop_info(f);
        pgo_instrument_function(f, *members, bpi, bfi, li, false);
    }
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
