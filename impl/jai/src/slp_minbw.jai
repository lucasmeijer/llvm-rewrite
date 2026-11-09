// SLPVectorizer: minimum bit widths of the tree. Ported from llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp
// (BoUpSLP::computeMinimumValueSizes, collectValuesToDemote).
//
// ExtraBitWidthNodes is a DenseSet<unsigned> whose begin() decides the next root; `Dense_U32_Set` reproduces
// DenseSet<unsigned>'s bucket layout (64 buckets, hash = key * 37, quadratic probing, tombstones on erase) so that
// iteration order matches.

Min_Bw :: struct { bits: u64; signed: bool; }

// DenseSet<unsigned> with LLVM's iteration order (up to 48 elements: the 64-bucket table)
DSET_BUCKETS :: 64;
DSET_EMPTY :: 0xFFFF_FFFF;
DSET_TOMB :: 0xFFFF_FFFE;
Dense_U32_Set :: struct {
    buckets: [DSET_BUCKETS] u32;
    count: s64;
    initialized: bool;
}
dset_init :: (s: *Dense_U32_Set) { for * s.buckets it.* = DSET_EMPTY; s.count = 0; s.initialized = true; }
dset_insert :: (s: *Dense_U32_Set, k: u32) {
    if !s.initialized dset_init(s);
    mask := cast(u32) DSET_BUCKETS - 1;
    b := (k * 37) & mask;
    probe: u32 = 1;
    first_tomb := -1;
    while true {
        x := s.buckets[b];
        if x == k return;
        if x == DSET_EMPTY {
            if first_tomb >= 0 b = cast(u32) first_tomb;
            break;
        }
        if x == DSET_TOMB && first_tomb < 0 first_tomb = cast(s64) b;
        b = (b + probe) & mask;
        probe += 1;
    }
    if (s.count + 1) * 4 >= DSET_BUCKETS * 3 slp_fail("more than 47 extra bit-width nodes (DenseSet growth)");
    s.buckets[b] = k;
    s.count += 1;
}
// *begin(), then erase(begin())
dset_pop_front :: (s: *Dense_U32_Set) -> u32 {
    for * s.buckets if it.* != DSET_EMPTY && it.* != DSET_TOMB { k := it.*; it.* = DSET_TOMB; s.count -= 1; return k; }
    return DSET_EMPTY;
}
dset_clear :: (s: *Dense_U32_Set) { dset_init(s); }

slp_simple_query :: () -> Simplify_Query { q: Simplify_Query; return q; }   // SimplifyQuery(*DL)

slp_min_bw :: (te: Te_Id) -> (bool, Min_Bw) {
    found, r := table_find(*slpx.min_bws, te);
    return found, r;
}

// collectValuesToDemote(E, IsProfitableToDemoteRoot, BitWidth, ToDemote, Visited, NodesToKeepBWs, MaxDepthLevel,
// IsProfitableToDemote, IsTruncRoot)
Demote_Ctx :: struct {
    is_profitable_to_demote_root: bool;
    to_demote: *[..] Te_Id;
    visited: *[..] Te_Id;
    nodes_to_keep: [] Te_Id;
    is_profitable_to_demote: *bool;
    is_trunc_root: bool;
}
slp_collect_values_to_demote :: (te: Te_Id, c: *Demote_Ctx, bit_width: *u64, max_depth: *u64) -> bool {
    e := *slp.entries[te];
    all_c := true; for e.scalars if !is_constant_kind(vkind(it)) { all_c = false; break; }
    if all_c return true;
    orig := dl_type_size_bits(scalar_type(vtype(e.scalars[0])));
    if orig == bit_width.* { max_depth.* = 1; return true; }
    for c.nodes_to_keep if it == te return false;
    q := slp_simple_query();
    is_signed_node := false;
    for r: e.scalars { if pm_poison(r) continue; if !is_known_non_negative(r, q) { is_signed_node = true; break; } }
    is_potentially_truncated :: (v: Value_Id, bw: *u64, orig: u64, is_signed_node: bool) -> bool {
        q := slp_simple_query();
        if pm_poison(v) return true;
        if slp_get_tree_entries(v).count > 1 return false;
        is_signed_val := !is_known_non_negative(v, q);
        if (!is_signed_node || is_signed_val) && orig > bw.* {
            if masked_value_is_zero(v, ap_bits_set_from(cast(u32) orig, cast(u32) bw.*), q) return true;
        }
        nsb := cast(u64) num_sign_bits_ctx(v, NONE, slp.dt, slp.ac);
        bw1 := orig - nsb;
        if is_signed_node bw1 += 1;
        if is_inst(v) {
            m := db_demanded_bits(slpx.db, v);
            bw2 := max(cast(u64) 1, cast(u64) (m.bits - ap_clz(m)));
            while !is_signed_node && bw2 < orig {
                if masked_value_is_zero(v, ap_bits_set_from(cast(u32) orig, cast(u32) (bw2 - 1)), q) break;
                bw2 *= 2;
            }
            bw1 = min(bw1, bw2);
        }
        bw.* = max(bw.*, bw1);
        return bw.* > 0 && orig >= bw.* * 2;
    }
    final_analysis :: (te: Te_Id, c: *Demote_Ctx, bit_width: *u64, max_depth: *u64, orig: u64, is_signed_node: bool) -> bool {
        e := *slp.entries[te];
        if !c.is_profitable_to_demote.* return false;
        res := true;
        for v: e.scalars if !is_potentially_truncated(v, bit_width, orig, is_signed_node) { res = false; break; }
        if res && te_is_gather(te) {
            if te_has_state(te) {
                same := slp_get_same_values_tree_entry(e.s.main, e.scalars);
                if same != TE_NONE && slp_collect_values_to_demote(same, c, bit_width, max_depth) {
                    array_add(c.to_demote, te);
                    return true;
                }
            }
            bases: [..] Value_Id; bases.allocator = temp;
            for v: e.scalars {
                if !is_inst(v) || inst_op(v) != .EXTRACTELEMENT continue;
                dup := false; for bases if it == op(v, 0) { dup = true; break; }
                if !dup array_add(*bases, op(v, 0));
            }
            vf := cast(u64) e.scalars.count;
            ost := vtype(e.scalars[0]);
            nt := type_int(cast(u32) bit_width.*);
            if bases.count <= 2 || slp_number_of_parts(slp.tti, slp_widened_type(ost, vf), ost) >= slp_number_of_parts(slp.tti, slp_widened_type(nt, vf), nt) {
                array_add(c.to_demote, te);
                return true;
            }
        }
        return res;
    }
    visited_before := false;
    for c.visited.* if it == te { visited_before = true; break; }
    if !visited_before && !te_is_gather(te) array_add(c.visited, te);
    any_ins_only := false;
    for v: e.scalars {
        if is_constant_kind(vkind(v)) continue;
        all := true;
        u := ir.v_first_use[v];
        while u != NONE { usr := ir.u_user[u]; u = ir.u_next[u]; if !(is_inst(usr) && inst_op(usr) == .INSERTELEMENT && !slp_is_vectorized(usr)) { all = false; break; } }
        if all { any_ins_only = true; break; }
    }
    if te_is_gather(te) || visited_before || any_ins_only return final_analysis(te, c, bit_width, max_depth, orig, is_signed_node);
    for v: e.scalars {
        if is_constant_kind(vkind(v)) continue;
        all := true;
        u := ir.v_first_use[v];
        while u != NONE {
            usr := ir.u_user[u]; u = ir.u_next[u];
            if slp_is_vectorized(usr) continue;
            if e.idx == 0 && slpx.has_user_ignore_list && slp_in_user_ignore_list(usr) continue;
            ut := vtype(usr);
            if !is_cmp_inst(usr) && type_is_sized(ut) && type_kind(ut) != .SVECTOR && dl_type_size_bits(ut) <= bit_width.* continue;
            all = false; break;
        }
        if !all && !is_potentially_truncated(v, bit_width, orig, is_signed_node) return false;
    }
    process_operands :: (ops: [] Te_Id, c: *Demote_Ctx, bit_width: *u64, max_depth: *u64, need_to_exit: *bool, te: Te_Id, orig: u64, is_signed_node: bool) -> bool {
        need_to_exit.* = false;
        init := max_depth.*;
        for o: ops {
            level := init;
            if !slp_collect_values_to_demote(o, c, bit_width, *level) {
                if !c.is_profitable_to_demote.* return false;
                need_to_exit.* = true;
                if !final_analysis(te, c, bit_width, max_depth, orig, is_signed_node) return false;
                continue;
            }
            max_depth.* = max(max_depth.*, level);
        }
        return true;
    }
    CHK_NONE :: 0; CHK_SHL :: 1; CHK_LSHR :: 2; CHK_ASHR :: 3; CHK_UDIV :: 4; CHK_COMP :: 5; CHK_ABS :: 6; CHK_CALL_COST :: 7;
    run_checker :: (kind: s64, te: Te_Id, bw: u64, orig: u64, id: Intrinsic_Id) -> bool {
        e := *slp.entries[te];
        q := slp_simple_query();
        for v: e.scalars {
            if kind == CHK_SHL || kind == CHK_LSHR || kind == CHK_ASHR { if pm_poison(v) continue; }
            ok := true;
            if kind == {
                case CHK_SHL;
                    if slp_te_is_copyable(te, v) continue;
                    ok = ap_ult_u64(kb_max_value(known_bits(op(v, 1), q)), bw);
                case CHK_LSHR;
                    shifted := ap_bits_set_from(cast(u32) orig, cast(u32) bw);
                    if slp_te_is_copyable(te, v) { ok = masked_value_is_zero(v, shifted, q); }
                    else ok = ap_ult_u64(kb_max_value(known_bits(op(v, 1), q)), bw) && masked_value_is_zero(op(v, 0), shifted, q);
                case CHK_ASHR;
                    shifted := orig - bw;
                    if slp_te_is_copyable(te, v) ok = shifted < cast(u64) num_sign_bits_ctx(v, NONE, slp.dt, slp.ac);
                    else ok = ap_ult_u64(kb_max_value(known_bits(op(v, 1), q)), bw) && shifted < cast(u64) num_sign_bits_ctx(op(v, 0), NONE, slp.dt, slp.ac);
                case CHK_UDIV;
                    m := ap_bits_set_from(cast(u32) orig, cast(u32) bw);
                    if slp_te_has_copyables(te) && slp_te_is_copyable(te, v) ok = masked_value_is_zero(v, m, q);
                    else ok = masked_value_is_zero(op(v, 0), m, q) && masked_value_is_zero(op(v, 1), m, q);
                case CHK_COMP;
                    if id == IID_UMIN || id == IID_UMAX {
                        m := ap_bits_set_from(cast(u32) orig, cast(u32) bw);
                        ok = masked_value_is_zero(op(v, 0), m, q) && masked_value_is_zero(op(v, 1), m, q);
                    } else {
                        sign_bits := orig - bw;
                        m := ap_bits_set_from(cast(u32) orig, cast(u32) (bw - 1));
                        s0 := cast(u64) num_sign_bits_ctx(op(v, 0), NONE, slp.dt, slp.ac);
                        s1 := cast(u64) num_sign_bits_ctx(op(v, 1), NONE, slp.dt, slp.ac);
                        ok = sign_bits <= s0 && ((sign_bits != s0 && !is_known_non_negative(op(v, 0), q)) || masked_value_is_zero(op(v, 0), m, q)) &&
                             sign_bits <= s1 && ((sign_bits != s1 && !is_known_non_negative(op(v, 1), q)) || masked_value_is_zero(op(v, 1), m, q));
                    }
                case CHK_ABS;
                    sign_bits := orig - bw;
                    m := ap_bits_set_from(cast(u32) orig, cast(u32) (bw - 1));
                    s0 := cast(u64) num_sign_bits_ctx(op(v, 0), NONE, slp.dt, slp.ac);
                    ok = sign_bits <= s0 && ((sign_bits != s0 && !is_known_non_negative(op(v, 0), q)) || masked_value_is_zero(op(v, 0), m, q));
            }
            if !ok return false;
        }
        return true;
    }
    // AttemptCheckBitwidth(Checker, NeedToExit)
    attempt_check_bitwidth :: (kind: s64, te: Te_Id, c: *Demote_Ctx, bit_width: *u64, max_depth: *u64, need_to_exit: *bool, orig: u64, is_signed_node: bool, id: Intrinsic_Id) -> bool {
        need_to_exit.* = false;
        best_fail: u64 = 0;
        while bit_width.* < orig {
            defer bit_width.* *= 2;
            if run_checker(kind, te, bit_width.*, orig, id) return true;
            if best_fail == 0 && final_analysis(te, c, bit_width, max_depth, orig, is_signed_node) best_fail = bit_width.*;
        }
        if bit_width.* >= orig {
            if best_fail == 0 { bit_width.* = orig; return false; }
            max_depth.* = 1;
            bit_width.* = best_fail;
            need_to_exit.* = true;
            return true;
        }
        return false;
    }
    try_process :: (te: Te_Id, c: *Demote_Ctx, bit_width: *u64, max_depth: *u64, ops: [] Te_Id, checker: s64, orig: u64, is_signed_node: bool, id: Intrinsic_Id = NOT_INTRINSIC) -> bool {
        e := *slp.entries[te];
        if ops.count == 0 {
            if !c.is_trunc_root max_depth.* = 1;
            for v: e.scalars is_potentially_truncated(v, bit_width, orig, is_signed_node);
        } else {
            for v: e.scalars if !has_one_use(v) && !is_potentially_truncated(v, bit_width, orig, is_signed_node) return false;
            need_to_exit := false;
            if checker != CHK_NONE && !attempt_check_bitwidth(checker, te, c, bit_width, max_depth, *need_to_exit, orig, is_signed_node, id) return false;
            if need_to_exit return true;
            if !process_operands(ops, c, bit_width, max_depth, *need_to_exit, te, orig, is_signed_node) return false;
            if need_to_exit return true;
        }
        max_depth.* += 1;
        array_add(c.to_demote, te);
        return c.is_profitable_to_demote.*;
    }
    if e.state == TE_SPLIT_VECTORIZE {
        cw := e.combined_entries_with_indices;
        return try_process(te, c, bit_width, max_depth, .[cast(Te_Id) cw[0][0], cast(Te_Id) cw[cw.count - 1][0]], CHK_NONE, orig, is_signed_node);
    }
    if is_alt_shuffle(e.s) {
        ao := is_alt_opcode(e.s);
        if ao == .SHL || ao == .ASHR || ao == .LSHR || ao == .UDIV || ao == .SDIV || ao == .UREM || ao == .SREM
            return final_analysis(te, c, bit_width, max_depth, orig, is_signed_node);
    }
    o0 :: (te: Te_Id) -> Te_Id { return slp_get_operand_entry(te, 0); }
    o1 :: (te: Te_Id) -> Te_Id { return slp_get_operand_entry(te, 1); }
    if te_opcode(te) == {
        case .TRUNC;
            if c.is_profitable_to_demote_root c.is_profitable_to_demote.* = true;
            return try_process(te, c, bit_width, max_depth, .[], CHK_NONE, orig, is_signed_node);
        case .ZEXT; #through;
        case .SEXT;
            u := e.user_tree_index.user;
            if u != TE_NONE && te_has_state(u) && te_opcode(u) == .BITCAST && is_fp_type(scalar_type(vtype(slp.entries[u].s.main))) return false;
            c.is_profitable_to_demote.* = true;
            return try_process(te, c, bit_width, max_depth, .[], CHK_NONE, orig, is_signed_node);
        case .ADD; #through; case .SUB; #through; case .MUL; #through; case .AND; #through; case .OR; #through; case .XOR;
            return try_process(te, c, bit_width, max_depth, .[o0(te), o1(te)], CHK_NONE, orig, is_signed_node);
        case .FREEZE;
            return try_process(te, c, bit_width, max_depth, .[o0(te)], CHK_NONE, orig, is_signed_node);
        case .SHL;
            return try_process(te, c, bit_width, max_depth, .[o0(te), o1(te)], CHK_SHL, orig, is_signed_node);
        case .LSHR;
            return try_process(te, c, bit_width, max_depth, .[o0(te), o1(te)], CHK_LSHR, orig, is_signed_node);
        case .ASHR;
            return try_process(te, c, bit_width, max_depth, .[o0(te), o1(te)], CHK_ASHR, orig, is_signed_node);
        case .UDIV; #through; case .UREM;
            return try_process(te, c, bit_width, max_depth, .[o0(te), o1(te)], CHK_UDIV, orig, is_signed_node);
        case .SELECT;
            return try_process(te, c, bit_width, max_depth, .[slp_get_operand_entry(te, 1), slp_get_operand_entry(te, 2)], CHK_NONE, orig, is_signed_node);
        case .PHI;
            ops: [..] Te_Id; ops.allocator = temp;
            for k: 0..e.operands.count-1 array_add(*ops, slp_get_operand_entry(te, cast(u32) k));
            return try_process(te, c, bit_width, max_depth, ops, CHK_NONE, orig, is_signed_node);
        case .CALL;
            ic := e.s.main;
            if call_iid(ic) == NOT_INTRINSIC { }
            else {
                id := get_vector_intrinsic_id_for_call(ic);
                if id == IID_ABS || id == IID_SMIN || id == IID_SMAX || id == IID_UMIN || id == IID_UMAX {
                    ops: [..] Te_Id; ops.allocator = temp;
                    array_add(*ops, o0(te));
                    checker := CHK_ABS;
                    if id != IID_ABS { array_add(*ops, o1(te)); checker = CHK_COMP; }
                    best_cost: Cost = 0x7FFF_FFFF_FFFF_FFFF;
                    best_bw := bit_width.*;
                    vf := cast(u64) e.scalars.count;
                    // AttemptCheckBitwidth with the cost checker (always false: walks the widths, keeps the cheapest)
                    need_to_exit := false;
                    best_fail: u64 = 0;
                    while bit_width.* < orig {
                        defer bit_width.* *= 2;
                        min_bw := bit_ceil(bit_width.*);
                        arg_tys := slp_build_intrinsic_arg_types(ic, id, vf, cast(u32) min_bw);
                        ic_, lc := slp_vector_call_costs(ic, slp_widened_type(type_int(cast(u32) min_bw), vf), arg_tys);
                        cst := min(ic_, lc);
                        if cst < best_cost { best_cost = cst; best_bw = bit_width.*; }
                        if best_fail == 0 && final_analysis(te, c, bit_width, max_depth, orig, is_signed_node) best_fail = bit_width.*;
                    }
                    if bit_width.* >= orig {
                        if best_fail == 0 bit_width.* = orig;
                        else { max_depth.* = 1; bit_width.* = best_fail; need_to_exit = true; }
                    }
                    bit_width.* = best_bw;
                    return try_process(te, c, bit_width, max_depth, ops, checker, orig, is_signed_node, id);
                }
            }
    }
    max_depth.* = 1;
    return final_analysis(te, c, bit_width, max_depth, orig, is_signed_node);
}

// computeMinimumValueSizes()
slp_compute_minimum_value_sizes :: () {
    f := cast(Te_Id) 0;
    is_store_or_insert := te_has_state(f) && (te_opcode(f) == .STORE || te_opcode(f) == .INSERTELEMENT || te_opcode(f) == .INSERTVALUE);
    if (is_store_or_insert || slpx.has_user_ignore_list) && slpx.extra_bitwidth_nodes.count <= 1 &&
       (!slpx.has_cast_max_min_bw || slpx.cast_min_bw == 0 || slpx.cast_max_bw / slpx.cast_min_bw <= 2)
        return;
    node_idx: s64 = 0;
    if is_store_or_insert && !te_is_gather(f) node_idx = 1;
    is_trunc_root := false;
    is_profitable_to_demote_root := !is_store_or_insert;
    root_demotes: [..] Te_Id; root_demotes.allocator = temp;
    nodes_to_keep: [..] Te_Id; nodes_to_keep.allocator = temp;
    if node_idx != 0 && slp.entries[node_idx].state == TE_VECTORIZE && te_opcode(cast(Te_Id) node_idx) == .TRUNC {
        is_trunc_root = true;
        array_add(*root_demotes, cast(Te_Id) node_idx);
        is_profitable_to_demote_root = true;
        node_idx += 1;
    }
    if table_contains(*slpx.analyzed_min_bw_vals, slp.entries[node_idx].scalars[0]) return;
    // the ExtraBitWidthNodes DenseSet, rebuilt from the insertion-ordered list
    extra: Dense_U32_Set;
    dset_init(*extra);
    for slpx.extra_bitwidth_nodes dset_insert(*extra, cast(u32) it);
    to_demote: [..] Te_Id; to_demote.allocator = temp;
    q := slp_simple_query();
    compute_max_bit_width :: (te: Te_Id, is_top_root: bool, is_profitable_to_demote_root: bool, limit: u64, is_trunc_root: bool, is_signed_cmp: bool,
                              to_demote: *[..] Te_Id, nodes_to_keep: [] Te_Id, is_store_or_insert: bool) -> u64 {
        array_reset_keeping_memory(to_demote);
        e := *slp.entries[te];
        q := slp_simple_query();
        keep := false; for nodes_to_keep if it == te { keep = true; break; }
        if te_is_gather(te) && is_trunc_root && e.user_tree_index.user != TE_NONE && !keep && e.idx > (ifx is_store_or_insert then 2 else 1) {
            ut := e.user_tree_index.user;
            all := true;
            for v: e.scalars {
                if has_one_use(v) || is_constant_kind(vkind(v)) continue;
                if has_n_uses_or_more(v, SLP_USES_LIMIT) { all = false; break; }
                bad := false;
                u := ir.v_first_use[v];
                while u != NONE {
                    usr := ir.u_user[u]; u = ir.u_next[u];
                    tes := slp_get_tree_entries(usr);
                    inn := false; for tes if it == ut { inn = true; break; }
                    if tes.count == 0 || inn continue;
                    is_ok_kind :: (x: Value_Id) -> bool {
                        o := inst_op(x);
                        return (is_cast_op(o) || is_binary_op(o) || o == .FREEZE || o == .PHI || o == .SELECT) && o != .SITOFP && o != .UITOFP;
                    }
                    if !is_inst(usr) || !is_ok_kind(usr) || (te_has_state(ut) && !is_ok_kind(slp.entries[ut].s.main)) { bad = true; break; }
                    ut_sz := dl_type_size_bits(vtype(slp.entries[ut].scalars[0]));
                    all_wider := true;
                    for x: tes { ok, mb := slp_min_bw(x); if !(ok && mb.bits > ut_sz) { all_wider = false; break; } }
                    if all_wider { bad = true; break; }
                    if dl_type_size_bits(vtype(usr)) > ut_sz { bad = true; break; }
                }
                if bad { all = false; break; }
            }
            if all {
                array_add(to_demote, te);
                ok, mb := slp_min_bw(ut);
                if ok return mb.bits;
                mbw := bit_ceil(dl_type_size_bits(vtype(slp.entries[ut].scalars[0])));
                if mbw < 8 && mbw > 1 mbw = 8;
                return mbw;
            }
        }
        if !te_has_state(te) return 0;
        vf := cast(u64) te_vector_factor(te);
        sty := vtype(e.scalars[0]);
        if type_kind(scalar_type(sty)) != .INT return 0;
        for e.scalars if table_contains(*slpx.analyzed_min_bw_vals, it) return 0;
        num_parts := slp_number_of_parts(slp.tti, slp_widened_type(sty, vf), sty);
        max_bw: u64 = 1;
        is_known_positive := !is_signed_cmp;
        if is_known_positive for r: e.scalars { if pm_poison(r) continue; if !kb_is_non_negative(known_bits(r, q)) { is_known_positive = false; break; } }
        u := e.user_tree_index.user;
        if !is_known_positive && !is_top_root && u != TE_NONE && te_has_state(u) && te_opcode(u) == .UITOFP
            max_bw = min(dl_type_size_bits(vtype(slp.entries[u].scalars[0])), dl_type_size_bits(sty));
        for root: e.scalars {
            if pm_poison(root) continue;
            nsb := cast(u64) num_sign_bits_ctx(root, NONE, slp.dt, slp.ac);
            bw1 := dl_type_size_bits(scalar_type(vtype(root))) - nsb;
            if !is_known_positive bw1 += 1;
            if !is_inst(root) { max_bw = max(bw1, max_bw); continue; }
            m := db_demanded_bits(slpx.db, root);
            bw2 := cast(u64) (m.bits - ap_clz(m));
            max_bw = max(min(bw1, bw2), max_bw);
        }
        if max_bw < 8 && max_bw > 1 max_bw = 8;
        nt := type_int(cast(u32) bit_ceil(max_bw));
        if num_parts > 1 && num_parts == slp_number_of_parts(slp.tti, slp_widened_type(nt, vf), nt) return 0;
        o := te_opcode(te);
        is_profitable := o == .TRUNC || o == .SEXT || o == .ZEXT || num_parts > 1;
        visited: [..] Te_Id; visited.allocator = temp;
        max_depth: u64 = ifx is_trunc_root then limit else 1;
        c: Demote_Ctx;
        c.is_profitable_to_demote_root = is_profitable_to_demote_root;
        c.to_demote = to_demote;
        c.visited = *visited;
        c.nodes_to_keep = nodes_to_keep;
        c.is_profitable_to_demote = *is_profitable;
        c.is_trunc_root = is_trunc_root;
        if !slp_collect_values_to_demote(te, *c, *max_bw, *max_depth) return 0;
        if max_depth <= limit {
            ext_ok := (o == .SEXT || o == .ZEXT) &&
                      (!is_top_root || !(is_store_or_insert || slpx.has_user_ignore_list) ||
                       dl_type_size_bits(scalar_type(sty)) / dl_type_size_bits(vtype(op(e.s.main, 0))) > 2);
            if !ext_ok return 0;
        }
        return bit_ceil(max_bw);
    }
    if slpx.has_user_ignore_list && type_kind(vtype(slp.entries[0].scalars[0])) == .INT {
        all_add := true;
        for v: slpx.user_ignore_list if !(pm_poison(v) || inst_op(v) == .ADD) { all_add = false; break; }
        if all_add && slp.entries[0].state == TE_VECTORIZE && te_opcode(0) == .ZEXT && vtype(op(slp.entries[0].s.main, 0)) == type_int(1) {
            slpx.reduction_bit_width = 1;
        } else {
            for v: slpx.user_ignore_list {
                if pm_poison(v) continue;
                nsb := cast(u64) num_sign_bits_ctx(v, NONE, slp.dt, slp.ac);
                bw1 := dl_type_size_bits(vtype(v)) - nsb;
                if !is_known_non_negative(v, q) bw1 += 1;
                bw2 := bw1;
                if !hr_is_int_min_max_kind(hr_get_rdx_kind(v)) {
                    m := db_demanded_bits(slpx.db, v);
                    bw2 = cast(u64) (m.bits - ap_clz(m));
                }
                slpx.reduction_bit_width = max(min(bw1, bw2), slpx.reduction_bit_width);
            }
            if slpx.reduction_bit_width < 8 && slpx.reduction_bit_width > 1 slpx.reduction_bit_width = 8;
            slpx.reduction_bit_width = bit_ceil(slpx.reduction_bit_width);
        }
    }
    is_top_root := node_idx == 0;
    while node_idx < slp.entries.count && slp.entries[node_idx].state == TE_VECTORIZE && te_opcode(cast(Te_Id) node_idx) == .TRUNC {
        array_add(*root_demotes, cast(Te_Id) node_idx);
        node_idx += 1;
        is_trunc_root = true;
    }
    is_signed_cmp := false;
    if slpx.has_user_ignore_list {
        all := true;
        for v: slpx.user_ignore_list if !(ic_pm_min_max_lr(v, IID_SMIN) || ic_pm_min_max_lr(v, IID_SMAX)) { all = false; break; }
        is_signed_cmp = all;
    }
    while node_idx < slp.entries.count {
        tree_root := slp.entries[node_idx].scalars;
        limit: u64 = 2;
        if is_top_root && slpx.reduction_bit_width == dl_type_size_bits(vtype(slp.entries[0].scalars[0])) limit = 3;
        max_bw := compute_max_bit_width(cast(Te_Id) node_idx, is_top_root, is_profitable_to_demote_root, limit, is_trunc_root, is_signed_cmp, *to_demote, nodes_to_keep, is_store_or_insert);
        if slpx.reduction_bit_width != 0 && (is_top_root || root_demotes.count) {
            if max_bw != 0 && slpx.reduction_bit_width < max_bw slpx.reduction_bit_width = bit_ceil(max_bw);
            else if max_bw == 0 slpx.reduction_bit_width = 0;
        }
        for idx: root_demotes {
            all := true;
            for v: slp.entries[idx].scalars {
                ob := dl_type_size_bits(scalar_type(vtype(v)));
                if ob > max_bw { if !masked_value_is_zero(v, ap_bits_set_from(cast(u32) ob, cast(u32) max_bw), q) { all = false; break; } }
                else { all = false; break; }
            }
            if all array_add(*to_demote, idx);
        }
        array_reset_keeping_memory(*root_demotes);
        is_top_root = false;
        is_profitable_to_demote_root = true;
        if extra.count == 0 {
            node_idx = slp.entries.count;
        } else {
            new_idx: u32 = 0;
            while true {
                new_idx = dset_pop_front(*extra);
                if !(cast(s64) new_idx <= node_idx && extra.count > 0) break;
            }
            node_idx = new_idx;
            is_trunc_root = false; is_signed_cmp = false;
            if node_idx < slp.entries.count {
                u := slp.entries[node_idx].user_tree_index;
                if u.user != TE_NONE {
                    ue := *slp.entries[u.user];
                    is_trunc_root = u.edge == 0 && te_has_state(u.user) && te_opcode(u.user) == .TRUNC && !is_alt_shuffle(ue.s);
                    if te_has_state(u.user) && te_opcode(u.user) == .ICMP {
                        for v: ue.scalars {
                            if !is_inst(v) || inst_op(v) != .ICMP continue;
                            if icmp_is_signed(inst(v).pred) || !is_known_non_negative(op(v, 0), q) || !is_known_non_negative(op(v, 1), q) { is_signed_cmp = true; break; }
                        }
                    }
                }
            }
        }
        if max_bw == 0 || max_bw >= dl_type_size_bits(scalar_type(vtype(tree_root[0]))) {
            if slpx.has_user_ignore_list for tree_root table_set(*slpx.analyzed_min_bw_vals, it, true);
            for to_demote { dup := false; for x: nodes_to_keep if x == it { dup = true; break; } if !dup array_add(*nodes_to_keep, it); }
            continue;
        }
        for idx: to_demote {
            if table_contains(*slpx.min_bws, idx) continue;
            is_signed := false;
            for r: slp.entries[idx].scalars { if pm_poison(r) continue; if !is_known_non_negative(r, q) { is_signed = true; break; } }
            table_set(*slpx.min_bws, idx, .{max_bw, is_signed});
        }
    }
}
