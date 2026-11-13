// SLPVectorizer: the gather-shuffle analysis that the reordering, the cost model and codegen share. Port of
// llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp: isUndefVector (with a use mask), getLastInstructionInBundle
// (with EntryToLastInstruction), tryToGatherSingleRegisterExtractElements, tryToGatherExtractElements,
// isGatherShuffledSingleRegisterEntry, isGatherShuffledEntry and getGatherCost.
//
// Entries (SmallVector<SmallVector<const TreeEntry *>>, at most 2 per part) are kept flat: `ents` holds 2 slots per
// part (-1 = none) and `nents` the count per part. A ShuffleKind result is an SK_* value, -1 = std::nullopt.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import constfold;
import domtree;
import tti_vec;
import tti_x86;
import tti_x86_vec;
import gen_x86target;
import slp_util;
import slp_tree;
import slp_sched;
import slp_loads;
import slp_build;


// an EdgeInfo's EdgeIdx as LLVM's unsigned (UINT_MAX for -1)
fn slp_eidx(e: i64) -> i64 { if e < 0 { 0xFFFFFFFF } else { e } }
fn slp_reachable(bb: i32) -> bool { dt_has_node(DT_DOM, bb) }
fn slp_dfs(bb: i32) -> u32 { dt_dfs_in(slp_fn, DT_DOM, bb) }

// isUndefVector<IsPoisonOnly>(V, UseMask): out[i] is set if lane i is undef (or not used: UseMask[i] set)
fn slp_undef_vector_mask(v: i32, poison_only: bool, usemask: const bool[:], out: bool[>..<]&) {
    out.clear();
    let n = if usemask.len == 0 { 1 } else { usemask.len };
    for k in n { out.push(true); }
    fn is_t(x: i32) -> bool { if poison_only { is_poison(x) } else { is_undef_or_poison(x) } }
    fn reset_all() { for k in out.len { out[k] = false; } }
    fn consts(c: i32, um: const bool[:]) {
        for i in ty_count(vals[c].ty) {
            let e = c_aggregate_element(c, i);
            if e >= 0 && !is_t(e) && (um.len == 0 || (i < um.len && !um[i])) { if i < out.len { out[i] = false; } }
        }
    }
    if is_t(v) { return; }
    if ty_kind(vals[v].ty) != TK_FVEC { reset_all(); return; }
    if is_constant(v) { consts(v, usemask); return; }
    if usemask.len == 0 { reset_all(); return; }
    var base = v;
    while is_inst_op(base, OP_INSERTELEMENT) {
        let ii = base;
        base = op(ii, 0);
        if is_t(op(ii, 1)) { continue; }
        let idx = slp_element_index(ii, 0);
        if idx < 0 { reset_all(); return; }
        if idx < usemask.len && !usemask[idx] { out[idx] = false; }
    }
    if v == base { reset_all(); return; }
    // Res &= isUndefVector(Base, SubMask) with an all-false SubMask of the same size
    var sub: bool[>..<] = [];
    for k in usemask.len { sub.push(true); }
    if !is_t(base) {
        if ty_kind(vals[base].ty) != TK_FVEC || !is_constant(base) {
            for k in sub.len { sub[k] = false; }
        } else {
            for i in ty_count(vals[base].ty) {
                let e = c_aggregate_element(base, i);
                if e >= 0 && !is_t(e) && i < sub.len { sub[i] = false; }
            }
        }
    }
    for k in out.len { out[k] = out[k] && sub[k]; }
}

// ---------------------------------------------------------------- getLastInstructionInBundle
fn slp_bundle_of_entry_in(bs: i32, te: i32, v: i32) -> i32 {
    var c = slp_bundles_head(v);
    while c >= 0 {
        let b = slp_lk[c].x;
        c = slp_lk[c].next;
        if slp_sb[b].bs == bs && slp_sb[b].te == te { return b; }
    }
    return -1;
}
recursive fn slp_last_instruction_in_bundle(e: i32) -> i32 {
    let cached = sh_get(SH_E2LI, e as i64, 0, -1) as i32;
    if cached >= 0 { return cached; }
    var front: i32 = -1;
    var opcode: i64 = 0;
    if te_has_state(e) { front = te_main(e); opcode = te_opcode(e); }
    else {
        for v in te_scalars(e) { if is_inst(v) { front = v; break; } }
        opcode = iop(front);
    }
    var bb = inst_parent(front);
    fn find_last() -> i32 {
        var last = front;
        for v in te_scalars(e) {
            if !is_inst(v) { continue; }
            if te_is_copyable_element(e, v) { continue; }
            if inst_parent(last) == inst_parent(v) {
                if slp_comes_before(last, v) { last = v; }
                continue;
            }
            if !slp_reachable(inst_parent(last)) { last = v; continue; }
            if !slp_reachable(inst_parent(v)) { continue; }
            if slp_dfs(inst_parent(last)) < slp_dfs(inst_parent(v)) { last = v; }
        }
        bb = inst_parent(last);
        return last;
    }
    fn find_first() -> i32 {
        var first = front;
        for v in te_scalars(e) {
            if !is_inst(v) { continue; }
            if te_is_copyable_element(e, v) { continue; }
            if inst_parent(first) == inst_parent(v) {
                if slp_comes_before(v, first) { first = v; }
                continue;
            }
            if !slp_reachable(inst_parent(first)) { first = v; continue; }
            if !slp_reachable(inst_parent(v)) { continue; }
            if slp_dfs(inst_parent(first)) > slp_dfs(inst_parent(v)) { first = v; }
        }
        return first;
    }
    fn done(r: i32) -> i32 { sh_set(SH_E2LI, e as i64, 0, r as i64); return r; }
    if slp_te[e].state == TE_SPLIT {
        var res = find_last();
        var c = slp_tree_entries_head(res);
        while c >= 0 {
            let t = slp_lk[c].x;
            c = slp_lk[c].next;
            var i = slp_te[t].vv;
            if i < 0 || !is_inst(i) { i = slp_last_instruction_in_bundle(t); }
            if inst_parent(res) == inst_parent(i) && slp_comes_before(res, i) { res = i; }
        }
        return done(res);
    }
    if slp_gathered_loads_first >= 0 && (e as i64) >= slp_gathered_loads_first && !te_is_gather(e) && opcode == OP_LOAD {
        return done(find_first());
    }
    // FindScheduleBundle
    var bundle: i32 = -1;
    if !te_is_gather(e) {
        let bs = slp_bs_of_block(bb);
        if bs >= 0 {
            for v in te_scalars(e) {
                if !is_inst(v) || iop(v) == OP_PHI || (!te_is_copyable_element(e, v) && slp_does_not_need_to_be_scheduled(v)) { continue; }
                let b = slp_bundle_of_entry_in(bs, e, v);
                if b >= 0 { bundle = b; break; }
            }
        }
    }
    if !te_is_gather(e) && bundle < 0 {
        var gep_case = false;
        if opcode == OP_GEP { for v in te_scalars(e) { if !is_inst_op(v, OP_GEP) && is_inst(v) { gep_case = true; break; } } }
        var last_case = gep_case;
        if !last_case {
            var all = true;
            for v in te_scalars(e) {
                let ok = is_poison(v) || (e == 0 && (is_inst_op(v, OP_INSERTELEMENT) || is_inst_op(v, OP_INSERTVALUE))) ||
                         te_is_copyable_element(e, v) || (!slp_is_vector_like_inst_with_const_ops(v) && slp_is_used_outside_block(v));
                if !ok { all = false; break; }
            }
            if all {
                var c2 = !slp_te[e].no_sched;
                if !c2 {
                    for v in te_scalars(e) {
                        if !is_inst(v) || (te_has_copyable_elements(e) && te_is_copyable_element(e, v)) { continue; }
                        if !slp_are_all_operands_non_insts(v) { c2 = true; break; }
                    }
                }
                if !c2 {
                    var none = true;
                    for v in te_scalars(e) {
                        if !is_inst(v) || (te_has_copyable_elements(e) && te_is_copyable_element(e, v)) { continue; }
                        if sh_has(SH_MUSTG, v as i64, 0) { none = false; break; }
                    }
                    c2 = none;
                }
                last_case = c2;
            }
        }
        return done(if last_case { find_last() } else { find_first() });
    }
    if bundle >= 0 {
        return done(slp_sd[sb_member(bundle, sb_n(bundle) - 1)].inst);
    }
    return done(find_last());
}

// ---------------------------------------------------------------- extractelement gathers
// tryToGatherSingleRegisterExtractElements(VL[at..at+n], Mask): the kind or -1
fn slp_gather_single_reg_ee(vl: i32[>..<]&, at: i64, n: i64, mask: i32[>..<]&) -> i64 {
    var keys: i32[>..<] = [];       // VectorOpToIdx (MapVector): key order
    var kidx: i32[>..<] = [];       // (key index, lane) pairs flattened per insertion
    var klane: i32[>..<] = [];
    var undefs: i32[>..<] = [];
    for i in n {
        let v = vl[at + i];
        if !is_inst_op(v, OP_EXTRACTELEMENT) {
            if is_undef_or_poison(v) { undefs.push(i as i32); }
            continue;
        }
        let vt: i32 = vals[op(v, 0)].ty;
        let ix = op(v, 1);
        if ty_kind(vt) != TK_FVEC || !(is_cint(ix) || is_undef_or_poison(ix)) { continue; }
        let idx = slp_extract_index(v);
        if idx < 0 { undefs.push(i as i32); continue; }
        if idx >= ty_count(vt) { undefs.push(i as i32); continue; }
        var um: bool[>..<] = [];
        for k in ty_count(vt) { um.push(k != idx); }
        var r: bool[>..<] = [];
        slp_undef_vector_mask(op(v, 0), true, um, r);
        var all = true;
        for b in r { if !b { all = false; break; } }
        if all { undefs.push(i as i32); continue; }
        let vec = op(v, 0);
        var ki: i64 = -1;
        for k in keys.len { if keys[k] == vec { ki = k; break; } }
        if ki < 0 { ki = keys.len; keys.push(vec); }
        kidx.push(ki as i32);
        klane.push(i as i32);
    }
    // Vectors: (key, lanes) sorted by the number of lanes, descending (stable)
    var cnt: i64[>..<] = [];
    for k in keys.len { cnt.push(0); }
    for k in kidx { cnt[k as i64] += 1; }
    var order: i64[>..<] = [];
    for k in keys.len { order.push(k); }
    // stable insertion sort by count descending
    for i in 1..order.len {
        let x = order[i];
        var j = i;
        while j > 0 && cnt[order[j - 1]] < cnt[x] { order[j] = order[j - 1]; j--; }
        order[j] = x;
    }
    let undef_sz = undefs.len;
    var single_max: i64 = 0;
    var pair_max: i64 = 0;
    if order.len > 0 {
        single_max = cnt[order[0]] + undef_sz;
        if order.len > 1 { pair_max = single_max + cnt[order[1]]; }
    }
    if single_max == 0 && pair_max == 0 && undef_sz == 0 { return -1; }
    var saved: i32[>..<] = [];
    for i in n { saved.push(vl[at + i]); }
    let pz = c_poison(vals[vl[at]].ty);
    var gathered: i32[>..<] = [];
    for i in n { gathered.push(pz); }
    fn swap_lane(i: i64) { let t = gathered[i]; gathered[i] = vl[at + i]; vl[at + i] = t; }
    if single_max >= pair_max && single_max > 0 {
        for k in kidx.len { if kidx[k] as i64 == order[0] { swap_lane(klane[k] as i64); } }
    } else if order.len > 0 {
        for w in 2 { for k in kidx.len { if kidx[k] as i64 == order[w] { swap_lane(klane[k] as i64); } } }
    }
    for i in undefs { swap_lane(i as i64); }
    let res = slp_is_fixed_vector_shuffle(gathered, mask);
    var all_poison = true;
    for m in mask { if m != -1 { all_poison = false; break; } }
    if res < 0 || all_poison {
        for i in n { vl[at + i] = saved[i]; }
        return -1;
    }
    for i in gathered.len {
        if mask[i] == -1 && !is_poison(gathered[i]) && is_undef_or_poison(gathered[i]) { swap_lane(i); }
    }
    return res;
}
// tryToGatherExtractElements(VL, Mask, NumParts): one kind per part (-1 = none); empty when no part has one
fn slp_gather_extract_elements(vl: i32[>..<]&, mask: i32[>..<]&, nparts: i64, res: i64[>..<]&) {
    res.clear();
    for k in nparts { res.push(-1); }
    mask.clear();
    for k in vl.len { mask.push(-1); }
    let slice = slp_part_num_elems(vl.len, nparts);
    for part in nparts {
        let off = part * slice;
        let psz = slp_num_elems(vl.len, slice, part);
        if off + psz > vl.len { break; }
        var sub: i32[>..<] = [];
        let r = slp_gather_single_reg_ee(vl, off, psz, sub);
        res[part] = r;
        for k in sub.len { mask[part * slice + k] = sub[k]; }
        if psz != slice { break; }
    }
    var any = false;
    for r in res { if r >= 0 { any = true; } }
    if !any { res.clear(); }
}

// ---------------------------------------------------------------- isGatherShuffledEntry
fn slp_set_contains(s: const i32[:], x: i32) -> bool { for y in s { if y == x { return true; } } return false; }
// isGatherShuffledSingleRegisterEntry(TE, VL, Mask, Entries, Part, ForOrder, SliceSize): Entries go to `out`
fn slp_gather_shuffled_single_reg(te: i32, vl: const i32[:], mask: i32[>..<]&, out: i32[>..<]&, part: i64, for_order: bool,
                                  slice: i64) -> i64 {
    out.clear();
    if te == 0 { return -1; }
    let mbase = part * slice;
    // GetUserEntry(TE)
    var ut = te;
    while slp_te[ut].ui_te >= 0 && slp_te[ut].ui_edge < 0 { ut = slp_te[ut].ui_te; }
    var use_te: i32 = -1;
    var use_edge: i64 = -1;
    if ut == 0 { use_te = 0; use_edge = 0; } else { use_te = slp_te[ut].ui_te; use_edge = slp_te[ut].ui_edge; }
    if use_te < 0 || (use_te == 0 && te_is_gather(use_te) && !te_has_state(use_te)) { return -1; }
    var ins_pt = slp_last_instruction_in_bundle(use_te);
    var ins_bb: i32 = -1;
    let use_phi = te_has_state(use_te) && iop(te_main(use_te)) == OP_PHI && slp_te[use_te].state != TE_SPLIT;
    if use_phi {
        ins_bb = phi_block(te_main(use_te), use_edge);
        ins_pt = block_terminator(ins_bb);
    } else {
        ins_bb = inst_parent(ins_pt);
    }
    if !slp_reachable(ins_bb) { return -1; }
    fn has_gather_user(t0: i32) -> bool {
        var t = t0;
        while t != 0 && slp_te[t].ui_te >= 0 {
            if slp_te[t].ui_edge < 0 { return true; }
            t = slp_te[t].ui_te;
        }
        return false;
    }
    fn check_ordering(ip: i32) -> bool {
        let ib = inst_parent(ip);
        if !dt_has_node(DT_DOM, ib) { return false; }
        if inst_parent(ins_pt) != ib && (dt_dominates_block(DT_DOM, ins_bb, ib) || !dt_dominates_block(DT_DOM, ib, ins_bb)) { return false; }
        if inst_parent(ins_pt) == ib && slp_comes_before(ins_pt, ip) { return false; }
        return true;
    }
    var used: i32[>..<] = [];      // UsedTEs: two sets, kept as runs [0, nused0) and [nused0, end)
    var nsets: i64 = 0;
    var set0: i32[>..<] = [];
    var set1: i32[>..<] = [];
    var uve_v: i32[>..<] = [];     // UsedValuesEntry (value -> set index)
    var uve_i: i64[>..<] = [];
    var visited: i32[>..<] = [];
    var reused_found = false;
    fn uve_find(v: i32) -> i64 { for k in uve_v.len { if uve_v[k] == v { return k; } } return -1; }
    fn uve_emplace(v: i32, x: i64) { if uve_find(v) < 0 { uve_v.push(v); uve_i.push(x); } }
    fn check_and_use_same_node(p: i32) -> bool {
        if reused_found { return false; }
        if (te_vector_factor(p) != vl.len && te_nscalars(p) != vl.len) || (!te_is_same(p, vl) && !te_is_same(p, te_scalars(te))) {
            return false;
        }
        reused_found = slp_runs_equal(te_scalars(te), te_scalars(p)) && slp_runs_equal(te_reorder(te), te_reorder(p)) &&
                       slp_runs_equal(te_reuse(te), te_reuse(p));
        set0.clear(); set1.clear();
        set0.push(p);
        nsets = 1;
        for v in vl { if slp_is_constant(v) { continue; } uve_emplace(v, 0); }
        return true;
    }
    fn check_parent_nodes(u1: i32, u2: i32, edge0: i64) -> bool {
        var p2 = u2;
        var edge = edge0;
        var pti_t: i32[>..<] = [];
        var pti_e: i64[>..<] = [];
        while p2 >= 0 {
            var have = false;
            for k in pti_t.len { if pti_t[k] == p2 { have = true; break; } }
            if !have { pti_t.push(p2); pti_e.push(edge); }
            edge = slp_te[p2].ui_edge;
            p2 = slp_te[p2].ui_te;
        }
        var p1 = u1;
        while p1 >= 0 {
            let idx = slp_te[p1].ui_edge;
            p1 = slp_te[p1].ui_te;
            if p1 < 0 { break; }
            for k in pti_t.len { if pti_t[k] == p1 { return slp_eidx(idx) < slp_eidx(pti_e[k]); } }
        }
        return false;
    }
    var ip_outside_known = false;
    var ip_outside = false;
    fn ip_used_outside() -> bool {
        if !ip_outside_known { ip_outside = slp_is_used_outside_block(ins_pt); ip_outside_known = true; }
        return ip_outside;
    }
    let use_ip_outside = te_has_copyable_elements(use_te) && !te_is_copyable_element(use_te, ins_pt) && ip_used_outside();
    fn check_nonsched_ordering(e: i32, ip: i32) -> bool {
        return use_ip_outside && inst_next(ip) == ins_pt &&
               (!te_has_copyable_elements(e) || !te_is_copyable_element(e, ip) || !slp_is_used_outside_block(ip));
    }
    var needs_first = slp_te[use_te].state == TE_VECTORIZE && te_has_state(use_te) &&
                      (te_opcode(use_te) != OP_PHI || te_is_alt_shuffle(use_te));
    if needs_first { for v in te_scalars(use_te) { if !slp_is_used_outside_block(v) { needs_first = false; break; } } }
    fn all_scalars_outside(u: i32) -> bool { for v in te_scalars(u) { if !slp_is_used_outside_block(v) { return false; } } return true; }
    for v in vl {
        if slp_is_constant(v) || slp_set_contains(visited, v) { continue; }
        visited.push(v);
        var vtes: i32[>..<] = [];
        var gnodes: i32[>..<] = [];
        var c = slp_lk_head(SH_V2G, v as i64);
        while c >= 0 { gnodes.push(slp_lk[c].x); c = slp_lk[c].next; }
        if slp_is_transformed_to_gather(te) {
            c = slp_lk_head(SH_SPLIT, v as i64);
            while c >= 0 {
                let e = slp_lk[c].x;
                c = slp_lk[c].next;
                if te == e || !slp_is_transformed_to_gather(e) || slp_te[e].ui_te < 0 || te_is_gather(slp_te[e].ui_te) { continue; }
                gnodes.push(e);
            }
            c = slp_tree_entries_head(v);
            while c >= 0 {
                let e = slp_lk[c].x;
                c = slp_lk[c].next;
                if te == e || !slp_is_transformed_to_gather(e) || slp_te[e].ui_te < 0 || te_is_gather(slp_te[e].ui_te) { continue; }
                gnodes.push(e);
            }
        }
        for p in gnodes {
            if p == te || p == 0 || slp_is_deleted_node(p) { continue; }
            var comb_has = false;
            for k in te_comb_n(p) { if te_comb_idx(p, k) == te { comb_has = true; break; } }
            if comb_has { continue; }
            let u_te = slp_te[p].ui_te;
            let u_edge = slp_te[p].ui_edge;
            var user_phi: i32 = -1;
            if slp_te[u_te].state != TE_SPLIT && te_has_state(u_te) && iop(te_main(u_te)) == OP_PHI { user_phi = te_main(u_te); }
            let ip = if user_phi >= 0 { block_terminator(phi_block(user_phi, u_edge)) } else { slp_last_instruction_in_bundle(u_te) };
            if ins_pt == ip {
                if needs_first {
                    if slp_te[u_te].state != TE_VECTORIZE || (te_has_state(u_te) && te_opcode(u_te) == OP_PHI && !te_is_alt_shuffle(u_te)) ||
                       !all_scalars_outside(u_te) { continue; }
                }
                if !slp_does_not_need_to_be_scheduled(ip) && (use_te != u_te || slp_eidx(use_edge) < slp_eidx(u_edge)) { continue; }
                if slp_te[use_te].state == TE_VECTORIZE && te_opcode(use_te) == OP_PHI && slp_te[u_te].state == TE_VECTORIZE &&
                   te_opcode(u_te) == OP_PHI && use_te != u_te { continue; }
                if use_te == u_te && slp_eidx(use_edge) < slp_eidx(u_edge) { continue; }
                if use_te != u_te && (use_te < u_te || has_gather_user(use_te)) { continue; }
                if check_parent_nodes(use_te, u_te, u_edge) { continue; }
            }
            if !te_is_gather(use_te) && user_phi < 0 && slp_te[use_te].no_sched != slp_te[u_te].no_sched &&
               slp_set_contains(te_scalars(u_te), ins_pt) { continue; }
            if (ins_bb != inst_parent(ip) || slp_eidx(use_edge) < slp_eidx(u_edge) || use_te != u_te) &&
               (!check_ordering(ip) || (te_has_copyable_elements(u_te) && ip_used_outside() && slp_set_contains(te_scalars(u_te), ins_pt))) {
                continue;
            }
            if check_and_use_same_node(p) { break; }
            if check_nonsched_ordering(u_te, ip) { continue; }
            if !slp_set_contains(vtes, p) { vtes.push(p); }
        }
        // getSplitTreeEntries(V)
        var vte: i32 = -1;
        c = slp_lk_head(SH_SPLIT, v as i64);
        while c >= 0 {
            let m = slp_lk[c].x;
            c = slp_lk[c].next;
            if m != te && m != use_te && !slp_is_deleted_node(m) && !slp_is_transformed_to_gather(m) { vte = m; break; }
        }
        if vte >= 0 {
            var none = true;
            for k in te_comb_n(te) { if te_comb_idx(te, k) == vte { none = false; break; } }
            if none {
                let lbi = slp_last_instruction_in_bundle(vte);
                if lbi == ins_pt || !check_ordering(lbi) { continue; }
            }
            if check_and_use_same_node(vte) { break; }
            if !slp_set_contains(vtes, vte) { vtes.push(vte); }
        }
        var vt_list: i32[>..<] = [];
        c = slp_tree_entries_head(v);
        while c >= 0 { vt_list.push(slp_lk[c].x); c = slp_lk[c].next; }
        if vt_list.len > 0 {
            var it: i64 = -1;
            for k in vt_list.len {
                let t = vt_list[k];
                if t != te && !slp_is_deleted_node(t) && !slp_is_transformed_to_gather(t) { it = k; break; }
            }
            if it >= 0 {
                var vte2 = vt_list[it];
                let glf = if slp_gathered_loads_first >= 0 { slp_gathered_loads_first } else { 0 };
                if for_order && (vte2 as i64) < glf && vt_list.len > 1 && slp_te[vte2].state != TE_VECTORIZE {
                    // VTEs.drop_front(): the first vectorized node after the first entry
                    var mit: i32 = -1;
                    for k in 1..vt_list.len { if slp_te[vt_list[k]].state == TE_VECTORIZE { mit = vt_list[k]; break; } }
                    if mit < 0 { continue; }
                    vte2 = mit;
                }
                var none = true;
                for k in te_comb_n(te) { if te_comb_idx(te, k) == vte2 { none = false; break; } }
                if none {
                    let lbi = slp_last_instruction_in_bundle(vte2);
                    if lbi == ins_pt || !check_ordering(lbi) || check_nonsched_ordering(vte2, lbi) { continue; }
                }
                if check_and_use_same_node(vte2) { break; }
                if !slp_set_contains(vtes, vte2) { vtes.push(vte2); }
            }
        }
        if reused_found { break; }
        if vtes.len == 0 { continue; }
        if nsets == 0 {
            set0.clear();
            for x in vtes { set0.push(x); }
            nsets = 1;
            uve_emplace(v, 0);
        } else {
            var idx: i64 = 0;
            var placed = false;
            for si in nsets {
                var inter: i32[>..<] = [];
                if si == 0 { for x in vtes { if slp_set_contains(set0, x) { inter.push(x); } } }
                else { for x in vtes { if slp_set_contains(set1, x) { inter.push(x); } } }
                if inter.len > 0 {
                    if si == 0 { set0.clear(); for x in inter { set0.push(x); } } else { set1.clear(); for x in inter { set1.push(x); } }
                    placed = true;
                    break;
                }
                idx++;
            }
            if !placed {
                if nsets == 2 { continue; }
                set1.clear();
                for x in vtes { set1.push(x); }
                nsets = 2;
                idx = 1;
            }
            uve_emplace(v, idx);
        }
    }
    if nsets == 0 { out.clear(); return -1; }
    var vf: i64 = 0;
    fn sort_by_idx(s: i32[>..<]&) {
        for i in 1..s.len { let x = s[i]; var j = i; while j > 0 && s[j - 1] > x { s[j] = s[j - 1]; j--; } s[j] = x; }
    }
    if nsets == 1 {
        var first: i32[>..<] = [];
        for x in set0 { first.push(x); }
        sort_by_idx(first);
        var it: i32 = -1;
        for p in first {
            if (te_vector_factor(p) == te_nscalars(te) && te_is_same(p, te_scalars(te))) || te_is_same(p, vl) { it = p; break; }
        }
        if it >= 0 && (reused_found || te_vector_factor(it) == vl.len ||
                       (te_vector_factor(it) == te_nscalars(te) && slp_te[te].nreuse as i64 == vl.len && te_is_same(it, te_scalars(te)))) {
            out.push(it);
            if reused_found || te_vector_factor(it) == vl.len {
                for k in vl.len { mask[mbase + k] = k as i32; }
            } else {
                var cm: i32[>..<] = [];
                te_common_mask(te, cm);
                for k in cm.len { mask[k] = cm[k]; }
            }
            for i in vl.len { if is_poison(vl[i]) { mask[mbase + i] = -1; } }
            return SK_PERMUTESINGLESRC;
        }
        out.push(first[0]);
        for k in uve_i.len { uve_i[k] = 0; }
        vf = te_vector_factor(first[0]);
    } else {
        // VFToTE: VF -> the entry with the smallest index
        var vf_k: i64[>..<] = [];
        var vf_t: i32[>..<] = [];
        for t in set0 {
            let f = te_vector_factor(t);
            var found = false;
            for k in vf_k.len { if vf_k[k] == f { if vf_t[k] > t { vf_t[k] = t; } found = true; break; } }
            if !found { vf_k.push(f); vf_t.push(t); }
        }
        var second: i32[>..<] = [];
        for x in set1 { second.push(x); }
        sort_by_idx(second);
        for t in second {
            var hit: i64 = -1;
            for k in vf_k.len { if vf_k[k] == te_vector_factor(t) { hit = k; break; } }
            if hit >= 0 { vf = vf_k[hit]; out.push(vf_t[hit]); out.push(t); break; }
        }
        if out.len == 0 {
            var mx = set0[0];
            for t in set0 { if t > mx { mx = t; } }
            out.push(mx);
            out.push(second[0]);
            let a = te_vector_factor(out[0]);
            let b = te_vector_factor(out[1]);
            vf = if a > b { a } else { b };
        } else {
            vf = te_vector_factor(out[0]);
        }
        for k in uve_v.len {
            for j in out.len {
                if slp_set_contains(te_scalars(out[j]), uve_v[k]) { uve_i[k] = j; break; }
            }
        }
    }
    var splat_or_undefs = slp_is_splat(vl);
    if !splat_or_undefs { var allu = true; for v in vl { if !is_undef_or_poison(v) { allu = false; break; } } splat_or_undefs = allu; }
    fn compatible_phis(v: i32, v1: i32) -> bool {
        for i in phi_nincoming(v) {
            let a = op(v, i);
            let b = op(v1, i);
            if slp_is_constant(a) && slp_is_constant(b) { continue; }
            var pr: i32[2] = [a, b];
            if !sis_valid(slp_get_same_opcode(pr[..])) { return false; }
            if inst_parent(a) != inst_parent(b) { return false; }
        }
        return true;
    }
    var mbi_v: i32[>..<] = [];
    var mbi_r: bool[>..<] = [];
    fn might_be_ignored(v: i32) -> bool {
        for k in mbi_v.len { if mbi_v[k] == v { return mbi_r[k]; } }
        let r = is_inst(v) && !splat_or_undefs && !slp_is_vectorized(v) && !slp_is_vector_like_inst_with_const_ops(v) &&
                !slp_are_all_users_vectorized(v, slp_uil_on) && slp_is_simple(v);
        mbi_v.push(v);
        mbi_r.push(r);
        return r;
    }
    fn neighbor_might_be_ignored(v: i32, idx: i64) -> bool {
        let v1 = vl[idx];
        var same = false;
        let k1 = uve_find(v1);
        if k1 >= 0 { same = uve_i[k1] == uve_i[uve_find(v)]; }
        if !(v != v1 && might_be_ignored(v1) && !same) { return false; }
        var pr: i32[2] = [v, v1];
        if !sis_valid(slp_get_same_opcode(pr[..])) { return false; }
        if inst_parent(v) != inst_parent(v1) { return false; }
        return !is_inst_op(v1, OP_PHI) || compatible_phis(v, v1);
    }
    var used_idx: bool[>..<] = [];
    for k in out.len { used_idx.push(false); }
    var lane_e: i64[>..<] = [];
    var lane_i: i64[>..<] = [];
    for i in vl.len {
        let v = vl[i];
        let k = uve_find(v);
        if k < 0 { continue; }
        if slp_is_constant(v) || (might_be_ignored(v) && ((i > 0 && neighbor_might_be_ignored(v, i - 1)) ||
                                                         (i != vl.len - 1 && neighbor_might_be_ignored(v, i + 1)))) { continue; }
        let idx = uve_i[k];
        lane_e.push(idx);
        lane_i.push(i);
        used_idx[idx] = true;
    }
    var temp: i32[>..<] = [];
    for i in out.len {
        if !used_idx[i] { continue; }
        for k in lane_e.len { if lane_e[k] == i { lane_e[k] = temp.len; } }
        temp.push(out[i]);
    }
    out.clear();
    for x in temp { out.push(x); }
    if lane_e.len == out.len {
        let n = slp_num_elems(te_nscalars(te), slice, part);
        var eq = vl.len == n;
        if eq { for k in vl.len { if vl[k] != te_scalar(te, mbase + k) { eq = false; break; } } }
        if !eq { out.clear(); return -1; }
    }
    var is_identity = out.len == 1;
    for k in lane_e.len {
        let idx = mbase + lane_i[k];
        let e = out[lane_e[k]];
        var lane: i64 = 0;
        if for_order {
            let sc = te_scalars(e);
            lane = sc.len;
            for j in sc.len { if sc[j] == vl[lane_i[k]] { lane = j; break; } }
        } else {
            lane = te_find_lane(e, vl[lane_i[k]]);
        }
        mask[idx] = (lane_e[k] * vf + lane) as i32;
        is_identity = is_identity && mask[idx] as i64 == lane_i[k];
    }
    if for_order || is_identity || out.len == 0 {
        if out.len == 1 {
            if is_identity || lane_e.len > 1 || vl.len <= 2 { return SK_PERMUTESINGLESRC; }
        } else if out.len == 2 {
            if lane_e.len > 2 || vl.len <= 2 { return SK_PERMUTETWOSRC; }
        }
    } else if ty_kind(vals[vl[0]].ty) != TK_FVEC && (lane_e.len > out.len || vl.len <= 2) {
        let sty: i32 = vals[vl[0]].ty;
        var sub: i32[>..<] = [];
        for k in vl.len { sub.push(mask[mbase + k]); }
        var mn = sub[0];
        var mx = sub[0];
        for x in sub {
            if x == -1 { continue; }
            if mn == -1 || (mn as i64) % vf > (x as i64) % vf { mn = x; }
            if mx == -1 || (mx as i64) % vf < (x as i64) % vf { mx = x; }
        }
        var offset: i64 = 0;
        let min_idx = (mn as i64) % vf;
        if min_idx > 1 {
            let rf = slp_floor_full_vector_number_of_elements(sty, min_idx);
            let rft = slp_widened_type(sty, rf);
            if slp_number_of_parts(rft, sty, rf) > 1 { offset = rf; }
        }
        var nvf = (mx as i64) % vf - offset + 1;
        if nvf < vl.len { nvf = vl.len; }
        if nvf < vf {
            for k in sub.len {
                if sub[k] == -1 { continue; }
                let x = sub[k] as i64;
                sub[k] = (x % vf - offset + (if x >= vf { nvf } else { 0 })) as i32;
            }
        } else {
            nvf = vf;
        }
        let vecty = slp_widened_type(sty, nvf);
        let mvt = slp_widened_type(sty, sub.len);
        fn shuffle_cost(m: const i32[:], two: bool, e0: i32) -> i64 {
            if !two && slp_te[e0].inter > 0 && sv_is_deinterleave_mask_of_factor(m, slp_te[e0].inter as i64) { return 0; }
            return slp_shuffle_cost(if two { SK_PERMUTETWOSRC } else { SK_PERMUTESINGLESRC }, vecty, m, 0, -1);
        }
        var sc_ = shuffle_cost(sub, out.len > 1, out[0]);
        var first_c: i64 = 0;
        var fm: i32[>..<] = [];
        for x in sub { fm.push(x); }
        if out.len == 1 || !te_is_gather(out[0]) {
            first_c = sc_;
        } else {
            var dem: bool[>..<] = [];
            for k in sub.len { dem.push(true); }
            var ident = true;
            for k in fm.len {
                if fm[k] as i64 >= nvf { fm[k] = -1; }
                else { dem[k] = false; if fm[k] != -1 { ident = ident && k == fm[k] as i64; } }
            }
            if !ident { first_c = shuffle_cost(fm, false, out[0]); }
            first_c = tc_add(first_c, slp_scalarization_overhead(sty, mvt, dem, true, false, true));
        }
        var second_c: i64 = 0;
        var sm: i32[>..<] = [];
        for x in sub { sm.push(x); }
        if out.len == 1 || !te_is_gather(out[1]) {
            second_c = sc_;
        } else {
            var dem: bool[>..<] = [];
            for k in sub.len { dem.push(true); }
            var ident = true;
            for k in sm.len {
                if (sm[k] as i64) < nvf && sm[k] >= 0 { sm[k] = -1; }
                else { dem[k] = false; if sm[k] != -1 { sm[k] = (sm[k] as i64 - nvf) as i32; ident = ident && k == sm[k] as i64; } }
            }
            if !ident { second_c = shuffle_cost(sm, false, out[1]); }
            second_c = tc_add(second_c, slp_scalarization_overhead(sty, mvt, dem, true, false, true));
        }
        var dem: bool[>..<] = [];
        for x in sub { dem.push(x != -1); }
        let bv = slp_scalarization_overhead(sty, mvt, dem, true, false, true);
        var best: i32 = -1;
        if first_c < sc_ {
            for k in vl.len { if mask[mbase + k] as i64 >= vf { mask[mbase + k] = -1; } }
            best = out[0];
            sc_ = first_c;
        }
        if second_c < sc_ {
            for k in vl.len {
                if (mask[mbase + k] as i64) < vf { mask[mbase + k] = -1; } else { mask[mbase + k] = (mask[mbase + k] as i64 - vf) as i32; }
            }
            best = out[1];
            sc_ = second_c;
        }
        if !(bv < sc_) {
            if best >= 0 { out.clear(); out.push(best); }
            return if out.len > 1 { SK_PERMUTETWOSRC } else { SK_PERMUTESINGLESRC };
        }
    }
    out.clear();
    for k in vl.len { mask[mbase + k] = -1; }
    return -1;
}
// ShuffleVectorInst::isDeInterleaveMaskOfFactor(Mask, Factor)
fn sv_is_deinterleave_mask_of_factor(m: const i32[:], factor: i64) -> bool {
    for idx in factor {
        var ok = true;
        for i in m.len { if m[i] >= 0 && m[i] as i64 != idx + i * factor { ok = false; break; } }
        if ok { return true; }
    }
    return false;
}
fn slp_runs_equal(a: const i32[:], b: const i32[:]) -> bool {
    if a.len != b.len { return false; }
    for k in a.len { if a[k] != b[k] { return false; } }
    return true;
}
// isGatherShuffledEntry(TE, VL, Mask, Entries, NumParts, ForOrder): kinds per part in `res` (empty = none)
fn slp_gather_shuffled_entry(te: i32, vl: const i32[:], mask: i32[>..<]&, ents: i32[>..<]&, nents: i32[>..<]&, nparts: i64,
                             for_order: bool, res: i64[>..<]&) {
    ents.clear();
    nents.clear();
    res.clear();
    if te == 0 {
        if slp_gathered_loads_first < 0 { return; }
        var none = true;
        for t in 1..slp_te.len { if !te_is_gather(t as i32) { none = false; break; } }
        if none { return; }
    }
    mask.clear();
    for k in vl.len { mask.push(-1); }
    let pw = slp_full_vector_number_of_elements(vals[vl[0]].ty, vl.len);
    let u = slp_te[te].ui_te;
    if u >= 0 && te_is_gather(u) && slp_te[te].ui_edge < 0 &&
       (te == 0 || (te_has_state(te) && te_opcode(te) == OP_EXTRACTELEMENT) || slp_is_splat(te_scalars(te)) ||
        (te_has_state(te) && slp_same_values_tree_entry(te_main(te), te_scalars(te), false) >= 0)) { return; }
    let slice = slp_part_num_elems(pw, nparts);
    for part in nparts {
        if part * slice >= vl.len { break; }
        let n = slp_num_elems(vl.len, slice, part);
        var sub: i32[>..<] = [];
        let r = slp_gather_shuffled_single_reg(te, vl[(part * slice)..(part * slice + n)], mask, sub, part, for_order, slice);
        if r < 0 { sub.clear(); }
        nents.push(sub.len as i32);
        ents.push(if sub.len > 0 { sub[0] } else { -1 });
        ents.push(if sub.len > 1 { sub[1] } else { -1 });
        res.push(r);
        if sub.len == 1 && r == SK_PERMUTESINGLESRC && te_vector_factor(sub[0]) == vl.len &&
           (te_is_same(sub[0], te_scalars(te)) || te_is_same(sub[0], vl)) {
            let e0 = sub[0];
            ents.clear(); nents.clear(); res.clear();
            for k in vl.len { mask[k] = k as i32; }
            for i in vl.len { if is_poison(vl[i]) { mask[i] = -1; } }
            nents.push(1); ents.push(e0); ents.push(-1);
            res.push(SK_PERMUTESINGLESRC);
            return;
        }
    }
    var all_none = true;
    for r in res { if r >= 0 { all_none = false; } }
    if all_none { ents.clear(); nents.clear(); res.clear(); }
}

// getGatherCost(VL, ForPoisonSrc, ScalarTy)
fn slp_gather_cost(vl: const i32[:], for_poison: bool, sty: i32) -> i64 {
    let vf = vl.len;
    let vecty = slp_widened_type(sty, vf);
    var dem: bool[>..<] = [];
    for k in vf { dem.push(false); }
    var cost: i64 = 0;
    var csm: i32[>..<] = [];
    for k in vf { csm.push(k as i32); }
    var any_dem = false;
    for i in vf {
        let v = vl[i];
        if (for_poison && slp_is_constant(v)) || is_undef_or_poison(v) { continue; }
        if slp_is_constant(v) { csm[i] = (i + vf) as i32; continue; }
        dem[i] = true;
        any_dem = true;
        if vals[v].ty as i32 != sty {
            cost = tc_add(cost, tv_cast(OP_TRUNC, sty, vals[v].ty, 0, TCK_RECIP_THROUGHPUT, -1));
        }
    }
    var any_const = false;
    for v in vl { if !is_undef_or_poison(v) && slp_is_constant(v) { any_const = true; break; } }
    if !for_poison && any_const { cost = tc_add(cost, slp_shuffle_cost(SK_PERMUTETWOSRC, vecty, csm, 0, -1)); }
    if any_dem { cost = tc_add(cost, slp_scalarization_overhead_vl(sty, vecty, dem, true, false, for_poison && !any_const, vl)); }
    return cost;
}
// ::getScalarizationOverhead(..., VL): X86's insert path for a non-poison source passes VL[I] to getVectorInstrCost
fn slp_scalarization_overhead_vl(sty: i32, ty: i32, dem: const bool[:], insert: bool, extract: bool, for_poison: bool,
                                 vl: const i32[:]) -> i64 {
    if insert && !for_poison && tti_kind == TTI_X86 && ty_kind(sty) != TK_FVEC {
        var c: i64 = 0;
        for i in dem.len {
            if !dem[i] { continue; }
            let s = if vl.len > 0 { vl[i] } else { -1 };
            c = tc_add(c, x86_vector_inst_cost(OP_INSERTELEMENT, ty, i, x86_null_value_marker(), s, TCK_RECIP_THROUGHPUT));
        }
        return c;
    }
    return slp_scalarization_overhead(sty, ty, dem, insert, extract, for_poison);
}
