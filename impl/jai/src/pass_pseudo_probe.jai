// Pseudo probes: `pseudo-probe` (SampleProfileProbePass, SampleProfileProber) and `pseudo-probe-update`
// (PseudoProbeUpdatePass). Ported from llvm/lib/Transforms/IPO/SampleProfileProbe.cpp and computeEHOnlyBlocks from
// llvm/include/llvm/Analysis/EHUtils.h. The probe verifier (-verify-pseudo-probe, debug output only) is not ported.

// computeEHOnlyBlocks
pp_compute_eh_only_blocks :: (f: Value_Id, out: *Table(Value_Id, bool)) {
    status: Table(Value_Id, u8); status.allocator = temp;   // 0 Unknown, 1 EH, 2 NonEH
    wl: [..] Value_Id; wl.allocator = temp;
    in_wl: Table(Value_Id, bool); in_wl.allocator = temp;
    tmp: [..] Value_Id; tmp.allocator = temp;
    add_succs :: (b: Value_Id) #expand {
        tmp.count = 0;
        block_successors(b, *tmp);
        for s: tmp if !block_is_eh_pad(s) && !table_contains(*in_wl, s) { table_set(*in_wl, s, true); array_add(*wl, s); }
    }
    get :: (status: *Table(Value_Id, u8), b: Value_Id) -> u8 { found, v := table_find(status, b); return ifx found then v else 0; }
    start := fn_entry(f);
    table_set(*status, start, 2);
    add_succs(start);
    for b: fn_blocks(f) if block_is_eh_pad(b) { add_succs(b); table_set(*status, b, 1); }
    preds: [..] Value_Id; preds.allocator = temp;
    while wl.count {
        b := wl[0];
        array_ordered_remove_by_index(*wl, 0);
        table_remove(*in_wl, b);
        old := get(*status, b);
        st := old;
        preds.count = 0;
        block_predecessors(b, *preds);
        for p: preds { ps := get(*status, p); if ps > st st = ps; }
        if old != st { add_succs(b); table_set(*status, b, st); }
    }
    for v, k: status if v == 1 table_set(out, k, true);
}

Pp_Prober :: struct {
    f: Value_Id;
    block_ids: Table(Value_Id, u32);
    call_ids: [..] struct { call: Value_Id; id: u32; };
    last_id: u32;
    function_hash: u64;
}

// getOriginalTerminator
pp_original_terminator :: (head: Value_Id, ignore: *Table(Value_Id, bool)) -> Value_Id {
    ti := block_terminator(head);
    if inst_op(ti) == .INVOKE return pp_original_terminator(get_successor(ti, 0), ignore);
    if num_successors(ti) == 1 && table_contains(ignore, get_successor(ti, 0)) return pp_original_terminator(get_successor(ti, 0), ignore);
    return ti;
}

// SampleProfileProber(F)
pp_prober_init :: (p: *Pp_Prober, f: Value_Id) {
    p.f = f;
    p.block_ids.allocator = temp;
    p.call_ids.allocator = temp;
    p.last_id = 0;
    ignore: Table(Value_Id, bool); ignore.allocator = temp;
    ignore_calls: Table(Value_Id, bool); ignore_calls.allocator = temp;
    // computeBlocksToIgnore
    pp_compute_eh_only_blocks(f, *ignore_calls);
    entry := fn_entry(f);
    for b: fn_blocks(f) if b != entry && block_num_preds(b) == 0 table_set(*ignore_calls, b, true);
    for v, k: ignore_calls table_set(*ignore, k, true);
    // findInvokeNormalDests
    preds: [..] Value_Id; preds.allocator = temp;
    for b: fn_blocks(f) {
        ti := block_terminator(b);
        if inst_op(ti) != .INVOKE continue;
        nd := get_successor(ti, 0);
        table_set(*ignore, nd, true);
        while true {
            preds.count = 0;
            block_predecessors(nd, *preds);
            if preds.count != 1 break;
            pr := preds[0];
            if num_successors(block_terminator(pr)) == 1 { table_set(*ignore, pr, true); nd = pr; }
            else break;
        }
    }
    // computeProbeId
    done := false;
    for b: fn_blocks(f) {
        if done break;
        if !table_contains(*ignore, b) { p.last_id += 1; table_set(*p.block_ids, b, p.last_id); }
        if table_contains(*ignore_calls, b) continue;
        for i: block_insts(b) {
            if !is_call_base(i) || sp_is_intrinsic_inst(i) continue;
            if p.last_id >= 0xFFFF {
                print_to_stderr("warning: Pseudo instrumentation incomplete for % because it's too large\n", vname(f));
                done = true;
                break;
            }
            p.last_id += 1;
            array_add(*p.call_ids, .{i, p.last_id});
        }
    }
    // computeCFGHash
    indexes: [..] u8; indexes.allocator = temp;
    for b: fn_blocks(f) {
        if table_contains(*ignore, b) continue;
        ti := pp_original_terminator(b, *ignore);
        n := num_successors(ti);
        for k: 0..cast(s64) n - 1 {
            found, index := table_find(*p.block_ids, get_successor(ti, cast(u32) k));
            if !found || index == 0 continue;
            for j: 0..3 array_add(*indexes, cast(u8) ((index >> cast(u32) (j * 8)) & 0xFF));
        }
    }
    crc := jam_crc_update(0xFFFF_FFFF, indexes);   // JamCRC JC; JC.update(Indexes); JC.getCRC()
    p.function_hash = ((cast(u64) p.call_ids.count) << 48) | ((cast(u64) indexes.count) << 32) | cast(u64) crc;
    p.function_hash &= 0x0FFF_FFFF_FFFF_FFFF;
}

// instrumentOneFunc
pp_instrument_one_func :: (p: *Pp_Prober, nmd: s64) {
    f := p.f;
    fname := vname(f);
    sp := fn_subprogram(f);
    if sp != NONE {
        fname = md_str_of(di_op(sp, 3));
        if fname.count == 0 fname = md_str_of(di_op(sp, 2));
    }
    guid := md5_hash_u64(fname);
    assign_debug_loc :: (i: Value_Id, sp: Md_Id) {
        if get_metadata(i, 0) != NONE return;
        if sp != NONE set_metadata(i, 0, di_location_get(0, 0, sp, NONE));
    }
    probe_fn: Value_Id = NONE;
    for b: fn_blocks(f) {
        found, index := table_find(*p.block_ids, b);
        if !found continue;
        j := block_first_insertion_pt(b);
        term := block_terminator(b);
        while j != term {
            if inst_op(j) != .PHI && !is_lifetime_start_or_end(j) && get_metadata(j, 0) != NONE break;
            j = inst_next(j);
        }
        if probe_fn == NONE probe_fn = get_or_insert_intrinsic_declaration(IID_PSEUDOPROBE);
        irb: Irb;
        irb_set_before(*irb, j);
        probe := irb_call(*irb, probe_fn, .[const_int(ir.t_i64, guid), const_int(ir.t_i64, cast(u64) index),
                                            const_int(ir.t_i32, 0), const_int(ir.t_i64, PSEUDO_PROBE_FULL_DISTRIBUTION_FACTOR)]);
        assign_debug_loc(probe, sp);
        dil := get_metadata(probe, 0);
        if dil != NONE && diloc_discriminator(dil) set_metadata(probe, 0, diloc_clone_with_discriminator(dil, 0));
    }
    for p.call_ids {
        call := it.call;
        type: u32 = ifx call_called_function(call) != NONE then cast(u32) 2 else 1;
        assign_debug_loc(call, sp);
        dil := get_metadata(call, 0);
        if dil != NONE {
            v := probe_pack(it.id, type, 0, 100, true, diloc_base_discriminator(dil));
            set_metadata(call, 0, diloc_clone_with_discriminator(dil, v));
        }
    }
    md := md_tuple(.[md_value(const_int(ir.t_i64, guid)), md_value(const_int(ir.t_i64, p.function_hash)), md_string(fname)], false);
    array_add(*ir.named_md[nmd].ops, md);
}

// SampleProfileProbePass::run
pseudo_probe_run :: () -> Preserved {
    nmd := named_md_get_or_insert("llvm.pseudo_probe_desc");
    for f: ir.m_functions {
        if is_declaration(f) continue;
        p: Pp_Prober;
        pp_prober_init(*p, f);
        pp_instrument_one_func(*p, nmd);
        fam_invalidate(f, PRESERVE_NONE);
    }
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

// getCallStackHash
pp_call_stack_hash :: (dil: Md_Id) -> u64 {
    h: u64 = 0;
    if dil == NONE return 0;
    ia := diloc_inlined_at(dil);
    while ia != NONE {
        h ^= md5_hash_u64(tprint("%", diloc_line(ia)));
        h ^= md5_hash_u64(tprint("%", diloc_col(ia)));
        // DILocation::getSubprogramLinkageName
        sp := diloc_subprogram(ia);
        n := "";
        if sp != NONE { n = md_str_of(di_op(sp, 3)); if n.count == 0 n = md_str_of(di_op(sp, 2)); }
        h ^= md5_hash_u64(n);
        ia = diloc_inlined_at(ia);
    }
    return h;
}

// PseudoProbeUpdatePass::run
pseudo_probe_update_run :: () -> Preserved {
    if sp_opts.update_pseudo_probe {
        for f: ir.m_functions {
            if is_declaration(f) continue;
            bfi := get_bfi(f);
            count :: (bfi: *Bfi, b: Value_Id) -> u64 { ok, c := bfi_block_profile_count(bfi, b); return ifx ok then c else 0; }
            K :: struct { id: u32; h: u64; sum: float32; }
            factors: [..] K; factors.allocator = temp;
            find :: (fs: *[..] K, id: u32, h: u64) -> *K {
                for * fs.* if it.id == id && it.h == h return it;
                array_add(fs, .{id, h, 0});
                return *fs.*[fs.count - 1];
            }
            for b: fn_blocks(f) for i: block_insts(b) {
                ok, pr := sp_extract_probe(i);
                if !ok continue;
                k := find(*factors, pr.id, pp_call_stack_hash(get_metadata(i, 0)));
                k.sum += cast(float32) count(bfi, b);
            }
            for b: fn_blocks(f) for i: block_insts(b) {
                ok, pr := sp_extract_probe(i);
                if !ok continue;
                k := find(*factors, pr.id, pp_call_stack_hash(get_metadata(i, 0)));
                if k.sum != 0 sp_set_probe_distribution_factor(i, cast(float32) count(bfi, b) / k.sum);
            }
            fam_invalidate(f, PRESERVE_NONE);
        }
    }
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
