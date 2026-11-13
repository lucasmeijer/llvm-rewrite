// SLPVectorizer: the graph reordering. Port of llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp: reorderReuses,
// reorderOrder, BoUpSLP::isIdentityOrder, findReusedOrderedScalars, clusterSortPtrAccesses,
// findPartiallyOrderedLoads, getReorderingData, isRepeatedNonIdentityClusteredMask, reorderNodeWithReuses,
// combineOrders, isProfitableToReorder, TreeEntry::reorderSplitNode / reorderOperands / buildAltOpShuffleMask,
// reorderTopToBottom, buildReorderableOperands, reorderBottomToTop, collectUserStores, canFormVector,
// findExternalStoreUsersReorderIndices; ShuffleVectorInst::isOneUseSingleSourceMask / isIdentityMask
// (llvm/lib/IR/Instructions.cpp).
//
// An OrdersType is an i32 list (Sz = "undef"). std::optional<OrdersType> results are (bool, out list).
// MapVector<OrdersType, unsigned> OrdersUses is `SOU` (keys in a pool, insertion order). The PriorityQueue of
// reorderBottomToTop is libstdc++'s binary heap (push_heap / pop_heap), because entries with the same user compare
// equal and the pop order decides OrdersUses' insertion order.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import vt;
import laa;
import domtree;
import tti_vec;
import tti_x86;
import gen_x86target;
import vecutils;
import slp_util;
import slp_tree;
import slp_ops;
import slp_sched;
import slp_loads;
import slp_build;
import slp_gather;

// ---------------------------------------------------------------- masks and orders
fn slp_is_identity_order(o: const i32[:]) -> bool {
    let sz = o.len;
    for k in sz { if o[k] as i64 != k && o[k] as i64 != sz { return false; } }
    return true;
}
fn slp_single_source_mask(m: const i32[:], nsrc: i64) -> bool {
    var l = false;
    var r = false;
    for x in m {
        if x == -1 { continue; }
        if (x as i64) < nsrc { l = true; } else { r = true; }
        if l && r { return false; }
    }
    return l || r;
}
// ShuffleVectorInst::isIdentityMask(Mask, NumSrcElts)
fn slp_is_identity_mask(m: const i32[:], nsrc: i64) -> bool {
    if m.len != nsrc { return false; }
    if !slp_single_source_mask(m, nsrc) { return false; }
    for i in m.len { if m[i] != -1 && m[i] as i64 != i && m[i] as i64 != nsrc + i { return false; } }
    return true;
}
// ShuffleVectorInst::isOneUseSingleSourceMask(Mask, VF)
fn slp_is_one_use_single_source_mask(m: const i32[:], vf: i64) -> bool {
    if vf <= 0 || m.len < vf || m.len % vf != 0 { return false; }
    var k: i64 = 0;
    while k < m.len {
        var allp = true;
        for j in vf { if m[k + j] != -1 { allp = false; break; } }
        if !allp {
            var used: bool[>..<] = [];
            for j in vf { used.push(false); }
            for j in vf { let x = m[k + j]; if x != -1 && (x as i64) < vf { used[x as i64] = true; } }
            for u in used { if !u { return false; } }
        }
        k += vf;
    }
    return true;
}
// reorderReuses(Reuses, Mask)
fn slp_reorder_reuses(reuses: i32[>..<]&, mask: const i32[:]) {
    var prev: i32[>..<] = [];
    for x in reuses { prev.push(x); }
    for i in prev.len { if mask[i] != -1 { reuses[mask[i] as i64] = prev[i]; } }
}
// reorderOrder(Order, Mask, BottomOrder)
fn slp_reorder_order(order: i32[>..<]&, mask: const i32[:], bottom: bool) {
    let sz = mask.len;
    if bottom {
        var prev: i32[>..<] = [];
        if order.len == 0 { for k in sz { prev.push(k as i32); } } else { for x in order { prev.push(x); } }
        order.clear();
        for k in sz { order.push(sz as i32); }
        for i in sz { if mask[i] != -1 { order[i] = prev[mask[i] as i64]; } }
        var ident = true;
        for k in sz { if order[k] as i64 != sz && order[k] as i64 != k { ident = false; break; } }
        if ident { order.clear(); return; }
        slp_fixup_ordering_indices(order);
        return;
    }
    var mo: i32[>..<] = [];
    if order.len == 0 { for k in sz { mo.push(k as i32); } } else { slp_inverse_permutation(order, mo); }
    slp_reorder_reuses(mo, mask);
    if slp_is_identity_mask(mo, sz) { order.clear(); return; }
    order.clear();
    for k in sz { order.push(sz as i32); }
    for i in sz { if mo[i] != -1 { order[mo[i] as i64] = i as i32; } }
    slp_fixup_ordering_indices(order);
}
// combineOrders(Order, SecondaryOrder)
fn slp_combine_orders(order: i32[>..<]&, second: const i32[:]) {
    let sz = order.len;
    var used: bool[>..<] = [];
    for k in sz { used.push(false); }
    for i in sz { if order[i] as i64 != sz { used[order[i] as i64] = true; } }
    if second.len == 0 {
        for i in sz { if order[i] as i64 == sz && !used[i] { order[i] = i as i32; } }
    } else {
        for i in sz { if second[i] as i64 != sz && order[i] as i64 == sz && !used[second[i] as i64] { order[i] = second[i]; } }
    }
}
fn slp_copy_list(xs: const i32[:], out: i32[>..<]&) { out.clear(); for x in xs { out.push(x); } }
fn slp_lists_equal(a: const i32[:], b: const i32[:]) -> bool {
    if a.len != b.len { return false; }
    for k in a.len { if a[k] != b[k] { return false; } }
    return true;
}

// ---------------------------------------------------------------- tree entry mutation
fn te_set_scalars_list(te: i32, xs: const i32[:]) { slp_te[te].sc = slp_vrun(xs); slp_te[te].nsc = xs.len as i32; }
fn te_clear_reorder(te: i32) { slp_te[te].nreord = 0; }
fn te_reorder_scalars(te: i32, mask: const i32[:]) {
    var sc: i32[>..<] = [];
    slp_copy_list(te_scalars(te), sc);
    slp_reorder_scalars(sc, mask);
    te_set_scalars_list(te, sc);
}
// TreeEntry::reorderOperands(Mask)
fn te_reorder_operands(te: i32, mask: const i32[:]) {
    let n = te_num_operands(te);
    if n == 0 { return; }
    var runs: SRun[>..<] = [];
    for k in n {
        var o: i32[>..<] = [];
        slp_copy_list(te_operand(te, k), o);
        if o.len > 0 { slp_reorder_scalars(o, mask); }
        runs.push(SRun { at: slp_vrun(o), n: o.len as i32 });
    }
    let at = slp_opl.len as i32;
    for r in runs { slp_opl.push(r); }
    slp_te[te].ops = at;
}
// TE.getOperand(K) = xs (a fresh run of operand lists)
fn te_replace_operand(te: i32, k: i64, xs: const i32[:]) {
    let n = te_num_operands(te);
    var runs: SRun[>..<] = [];
    for j in n { runs.push(te_operand_run(te, j)); }
    runs[k] = SRun { at: slp_vrun(xs), n: xs.len as i32 };
    let at = slp_opl.len as i32;
    for r in runs { slp_opl.push(r); }
    slp_te[te].ops = at;
}
fn te_reorder_list(te: i32, out: i32[>..<]&) { slp_copy_list(te_reorder(te), out); }
fn te_reuse_list(te: i32, out: i32[>..<]&) { slp_copy_list(te_reuse(te), out); }
// TreeEntry::reorderSplitNode(Idx, Mask, MaskOrder)
fn te_reorder_split_node(te: i32, idx: i64, mask: const i32[:], mask_order: const i32[:]) {
    let vf = te_vector_factor(te);
    var nm: i32[>..<] = [];
    var nmo: i32[>..<] = [];
    for k in vf { nm.push(k as i32); nmo.push(k as i32); }
    if idx == 0 {
        for k in mask.len { nm[k] = mask[k]; }
        for k in mask_order.len { nmo[k] = mask_order[k]; }
    } else {
        let off = te_comb_off(te, te_comb_n(te) - 1) as i64;
        for i in mask.len {
            nm[i + off] = (mask[i] as i64 + off) as i32;
            nmo[i + off] = (mask_order[i] as i64 + off) as i32;
        }
    }
    te_reorder_scalars(te, nm);
    var ro: i32[>..<] = [];
    te_reorder_list(te, ro);
    slp_reorder_order(ro, nmo, true);
    if ro.len > 0 && slp_is_identity_order(ro) { ro.clear(); }
    te_set_reorder(te, ro);
}
// TreeEntry::buildAltOpShuffleMask(IsAltOp, Mask) with isAlternateInstruction
fn te_build_alt_op_shuffle_mask(te: i32, mask: i32[>..<]&) {
    let sz = te_nscalars(te);
    mask.clear();
    for k in sz { mask.push(-1); }
    var om: i32[>..<] = [];
    let has_ord = slp_te[te].nreord > 0;
    if has_ord { slp_inverse_permutation(te_reorder(te), om); }
    for i in sz {
        var idx = i;
        if has_ord { idx = om[i] as i64; }
        let v = te_scalar(te, idx);
        if is_poison(v) { continue; }
        if slp_is_alternate_instruction(v, te_main(te), te_alt(te)) { mask[i] = (sz + idx) as i32; } else { mask[i] = idx as i32; }
    }
    if slp_te[te].nreuse > 0 {
        var nm: i32[>..<] = [];
        for x in te_reuse(te) { nm.push(if x != -1 { mask[x as i64] } else { -1 }); }
        slp_copy_list(nm, mask);
    }
}

// ---------------------------------------------------------------- findReusedOrderedScalars
fn slp_find_reused_ordered_scalars(te: i32, top: bool, ignore: bool, cur: i32[>..<]&) -> bool {
    cur.clear();
    var gs: i32[>..<] = [];
    slp_copy_list(te_scalars(te), gs);
    let sty: i32 = vals[gs[0]].ty;
    let ns = gs.len;
    if !slp_is_valid_element_type(sty) { return false; }
    let vecty = slp_widened_type(sty, ns);
    var nparts = slp_number_of_parts(vecty, sty, ns);
    var emask: i32[>..<] = [];
    var mask: i32[>..<] = [];
    var ents: i32[>..<] = [];
    var nents: i32[>..<] = [];
    var eshuf: i64[>..<] = [];
    var gshuf: i64[>..<] = [];
    slp_gather_extract_elements(gs, emask, nparts, eshuf);
    slp_gather_shuffled_entry(te, gs, mask, ents, nents, nparts, true, gshuf);
    if gshuf.len == 0 && eshuf.len == 0 { return false; }
    for k in ns { cur.push(ns as i32); }
    if gshuf.len == 1 && gshuf[0] == SK_PERMUTESINGLESRC && te_is_same(ents[0], te_scalars(te)) {
        let f = ents[0];
        if top { return false; }
        if slp_te[f].ui_te == slp_te[te].ui_te { return false; }
        if !ignore && f == 0 { return false; }
        if slp_te[f].nreuse > 0 && te_vector_factor(te) == 2 && mask.len == 2 {
            let ru = te_reuse(f);
            for k in ru.len { if ru[k] % 2 != (k as i32) % 2 { return false; } }
        }
        for k in ns { cur[k] = k as i32; }
        return true;
    }
    fn is_splat_mask(m: const i32[:]) -> bool {
        var single: i32 = -1;
        for x in m {
            if single == -1 && x != -1 { single = x; }
            if !(x == -1 || x == single) { return false; }
        }
        return true;
    }
    if (eshuf.len == 0 && is_splat_mask(mask) && (nents.len != 1 || slp_te[ents[0]].nreord == 0)) ||
       (gshuf.len == 0 && is_splat_mask(emask)) { return false; }
    var shuffled: bool[>..<] = [];
    for k in nparts { shuffled.push(false); }
    // TransformMaskToOrder(CurrentOrder, Mask, PartSz, NumParts, GetVF): vfs[i] is GetVF(i)
    fn transform(m: const i32[:], psz: i64, np: i64, vfs: const i64[:]) {
        for i in np {
            if shuffled[i] { continue; }
            let vf = vfs[i];
            if vf == 0 { continue; }
            let limit = slp_num_elems(cur.len, psz, i);
            let base = i * psz;
            var any = false;
            for k in limit { if cur[base + k] as i64 != ns { any = true; break; } }
            if any { for k in limit { cur[base + k] = ns as i32; } shuffled[i] = true; continue; }
            var first_min: i64 = 0x7FFFFFFF;
            var second = false;
            for k in limit {
                let idx = m[base + k];
                if idx == -1 {
                    let v = gs[base + k];
                    if slp_is_constant(v) && !is_poison(v) { second = true; break; }
                    continue;
                }
                if (idx as i64) < vf { if first_min > idx as i64 { first_min = idx as i64; } }
                else { second = true; break; }
            }
            first_min = (first_min / psz) * psz;
            if second { for k in limit { cur[base + k] = ns as i32; } shuffled[i] = true; continue; }
            for k in limit {
                var idx = m[base + k] as i64;
                if idx == -1 { continue; }
                idx -= first_min;
                if idx >= psz { second = true; break; }
                if base + idx >= cur.len { continue; }
                if cur[base + idx] as i64 > base + k && cur[base + idx] as i64 != base + idx { cur[base + idx] = (base + k) as i32; }
            }
            if second { for k in limit { cur[base + k] = ns as i32; } shuffled[i] = true; continue; }
        }
    }
    var psz = slp_part_num_elems(ns, nparts);
    if eshuf.len > 0 {
        var vfs: i64[>..<] = [];
        for i in nparts {
            if i >= eshuf.len || eshuf[i] < 0 { vfs.push(0); continue; }
            var vf: i64 = 0;
            let sz = slp_num_elems(te_vector_factor(te), psz, i);
            for idx in sz {
                var k = i * psz + idx;
                if k >= emask.len { break; }
                if emask[k] == -1 { continue; }
                if slp_te[te].nreuse > 0 { k = te_reuse(te)[k] as i64; }
                if k == -1 { continue; }
                if slp_te[te].nreord > 0 {
                    let ro = te_reorder(te);
                    var p = ro.len;
                    for j in ro.len { if ro[j] as i64 == k { p = j; break; } }
                    k = p;
                }
                let ev = te_scalar(te, k);
                if !is_inst_op(ev, OP_EXTRACTELEMENT) { continue; }
                let c = ty_count(vals[op(ev, 0)].ty);
                if c > vf { vf = c; }
            }
            vfs.push(vf);
        }
        transform(emask, psz, nparts, vfs);
    }
    if gshuf.len == 1 && nparts != 1 {
        for b in shuffled { if b { return false; } }
        psz = ns;
        nparts = 1;
    }
    if nents.len > 0 {
        var vfs: i64[>..<] = [];
        for i in nparts {
            if i >= gshuf.len || gshuf[i] < 0 { vfs.push(0); continue; }
            let n = nents[i] as i64;
            let a = te_vector_factor(ents[2 * i]);
            let b = te_vector_factor(ents[2 * i + n - 1]);
            vfs.push(if a > b { a } else { b });
        }
        transform(mask, psz, nparts, vfs);
    }
    var nundef: i64 = 0;
    for x in cur { if x as i64 == ns { nundef++; } }
    var all = shuffled.len > 0;
    for b in shuffled { if !b { all = false; } }
    if all || (ns > 2 && nundef >= ns / 2) { return false; }
    return true;
}

// ---------------------------------------------------------------- loads
// clusterSortPtrAccesses(VL, BBs, ElemTy, SortedIndices)
fn slp_cluster_sort_ptr_accesses(vl: const i32[:], bbs: const i32[:], ety: i32, sorted: i32[>..<]&) -> bool {
    let rmd = slp_recursion_max_depth_opt();
    // Bases: MapVector<(BB, underlying object), vector of clusters>, a cluster is a list of (Ptr, Offset, OrigIdx)
    var bkey_bb: i32[>..<] = [];
    var bkey_obj: i32[>..<] = [];
    // clusters: cl_base (base index), entries in cl_* lists: (cluster, ptr, off, idx)
    var cl_base: i64[>..<] = [];
    var e_cl: i64[>..<] = [];
    var e_ptr: i32[>..<] = [];
    var e_off: i64[>..<] = [];
    var e_idx: i64[>..<] = [];
    fn base_of(bb: i32, obj: i32) -> i64 {
        for k in bkey_bb.len { if bkey_bb[k] == bb && bkey_obj[k] == obj { return k; } }
        bkey_bb.push(bb);
        bkey_obj.push(obj);
        return bkey_bb.len - 1;
    }
    fn new_cluster(b: i64, p: i32, off: i64, idx: i64) {
        cl_base.push(b);
        e_cl.push(cl_base.len - 1); e_ptr.push(p); e_off.push(off); e_idx.push(idx);
    }
    fn cluster_front(c: i64) -> i32 { for k in e_cl.len { if e_cl[k] == c { return e_ptr[k]; } } return -1; }
    new_cluster(base_of(bbs[0], get_underlying_object(vl[0], rmd)), vl[0], 0, 0);
    sorted.clear();
    for cnt in 1..vl.len {
        let ptr = vl[cnt];
        let b = base_of(bbs[cnt], get_underlying_object(ptr, rmd));
        var found = false;
        for c in cl_base.len {
            if cl_base[c] != b { continue; }
            let ok, d = laa_get_pointers_diff(ety, cluster_front(c as i64), ety, ptr, true, true);
            if !ok { continue; }
            e_cl.push(c as i64); e_ptr.push(ptr); e_off.push(d); e_idx.push(cnt);
            found = true;
            break;
        }
        if !found {
            if bkey_bb.len > vl.len / 2 - 1 { return false; }
            new_cluster(b, ptr, 0, cnt);
        }
    }
    if bkey_bb.len == vl.len { return false; }
    if bkey_bb.len == 1 && (cl_base.len == 1 || cl_base.len == vl.len) { return false; }
    fn compare_pointers(p1_0: i32, p2_0: i32) -> bool {
        var fp: i32[>..<] = [];
        var sp: i32[>..<] = [];
        var p1 = p1_0;
        var p2 = p2_0;
        var depth: i64 = 0;
        while !slp_contains(fp, p2) && !slp_contains(sp, p1) {
            if p1 == p2 || depth > rmd { return false; }
            fp.push(p1);
            sp.push(p2);
            p1 = get_underlying_object(p1, 1);
            p2 = get_underlying_object(p2, 1);
            depth++;
        }
        return slp_contains(fp, p2) && !slp_contains(sp, p1);
    }
    // per base: sort each cluster by offset (stable), check consecutive; then stable-sort the clusters
    var out_clusters: i64[>..<] = [];
    for b in bkey_bb.len {
        var cls: i64[>..<] = [];
        for c in cl_base.len { if cl_base[c] == b as i64 { cls.push(c as i64); } }
        for c in cls {
            var es: i64[>..<] = [];
            for k in e_cl.len { if e_cl[k] == c { es.push(k as i64); } }
            var pos: i64[>..<] = [];
            for k in es { pos.push(k); }
            if es.len > 1 {
                std_stable_sort(es, 0, es.len) { x, y => e_off[x] < e_off[y] };
                let init = e_off[es[0]];
                for j in es.len { if e_off[es[j]] != j + init { return false; } }
            }
            // write the sorted order back: renumber entries of this cluster by their sorted position
            var tmp_ptr: i32[>..<] = [];
            var tmp_off: i64[>..<] = [];
            var tmp_idx: i64[>..<] = [];
            for k in es { tmp_ptr.push(e_ptr[k]); tmp_off.push(e_off[k]); tmp_idx.push(e_idx[k]); }
            for j in es.len { e_ptr[pos[j]] = tmp_ptr[j]; e_off[pos[j]] = tmp_off[j]; e_idx[pos[j]] = tmp_idx[j]; }
        }
        std_stable_sort(cls, 0, cls.len) { x, y => compare_pointers(cluster_front(x), cluster_front(y)) };
        for c in cls { out_clusters.push(c); }
    }
    for c in out_clusters { for k in e_cl.len { if e_cl[k] == c { sorted.push(e_idx[k] as i32); } } }
    return true;
}
// findPartiallyOrderedLoads(TE)
fn slp_find_partially_ordered_loads(te: i32, order: i32[>..<]&) -> bool {
    let sty: i32 = vals[te_scalar(te, 0)].ty;
    var ptrs: i32[>..<] = [];
    var bbs: i32[>..<] = [];
    for v in te_scalars(te) {
        if !is_inst_op(v, OP_LOAD) || !ld_is_simple(v) { return false; }
        ptrs.push(op(v, 0));
        bbs.push(inst_parent(v));
    }
    for x in slp_load_entries { if x == te { return false; } }
    return slp_cluster_sort_ptr_accesses(ptrs, bbs, sty, order);
}

// ---------------------------------------------------------------- getReorderingData
fn slp_get_reordering_data(te: i32, top: bool, ignore: bool, res: i32[>..<]&) -> bool {
    res.clear();
    let e = slp_te[te];
    let sz = te_nscalars(te);
    if e.nreuse > 0 {
        if slp_is_splat(te_scalars(te)) { return false; }
        if te_is_gather(te) {
            var co: i32[>..<] = [];
            if slp_find_reused_ordered_scalars(te, top, ignore, co) {
                var mask: i32[>..<] = [];
                slp_fixup_ordering_indices(co);
                slp_inverse_permutation(co, mask);
                slp_add_mask(mask, te_reuse(te), false);
                let vf = te_vector_factor(te);
                for k in vf { res.push(vf as i32); }
                for k in vf / sz {
                    for i in sz {
                        let idx = mask[k * sz + i];
                        if idx != -1 { res[idx as i64 + k * sz] = (i + k * sz) as i32; }
                    }
                }
                return true;
            }
        }
        let sty = slp_value_type(te_scalar(te, 0), false);
        if sz == 2 && te_vector_factor(te) == 4 && slp_number_of_parts(slp_widened_type(sty, 2 * te_vector_factor(te)), sty, 0x7FFFFFFF) == 1 {
            return false;
        }
        if (e.nreuse as i64) % sz != 0 { return false; }
        if !slp_is_one_use_single_source_mask(te_reuse(te), sz) {
            var rm: i32[>..<] = [];
            if e.nreord == 0 { for k in sz { rm.push(k as i32); } } else { slp_inverse_permutation(te_reorder(te), rm); }
            slp_add_mask(rm, te_reuse(te), false);
            let vf = rm.len;
            for k in vf { res.push(vf as i32); }
            let np = slp_div_ceil(vf, sz);
            var used: bool[>..<] = [];
            for k in np { used.push(false); }
            var i: i64 = 0;
            while i < vf {
                var val: i32 = -1;
                var ucnt: i64 = 0;
                let limit = if sz < vf - i { sz } else { vf - i };
                var bad = false;
                for k in limit {
                    let idx = rm[i + k];
                    if val == -1 && idx != -1 { val = idx; }
                    if idx == -1 { ucnt++; }
                    if idx != -1 && idx != val { bad = true; break; }
                }
                if bad || val as i64 >= np || val == -1 || used[val as i64] || ucnt > sz / 2 { res.clear(); return false; }
                used[val as i64] = true;
                for k in np {
                    let idx = val as i64 + sz * k;
                    if idx < vf && i + k < vf { res[idx] = (i + k) as i32; }
                }
                i += sz;
            }
            return true;
        }
        let vf = te_vector_factor(te);
        var reused: i32[>..<] = [];
        te_reuse_list(te, reused);
        if te_has_state(te) && te_opcode(te) == OP_EXTRACTELEMENT {
            var ok = true;
            for v in te_scalars(te) {
                if is_poison(v) { continue; }
                let ix = slp_extract_index(v);
                if !(ix >= 0 && ix < sz) { ok = false; break; }
            }
            if ok {
                var rm: i32[>..<] = [];
                if e.nreord == 0 { for k in sz { rm.push(k as i32); } } else { slp_inverse_permutation(te_reorder(te), rm); }
                for i in vf {
                    let idx = reused[i];
                    if idx == -1 { continue; }
                    let v = te_scalar(te, rm[idx as i64] as i64);
                    let ei = slp_extract_index(v);
                    var p = rm.len;
                    for j in rm.len { if rm[j] as i64 == ei { p = j; break; } }
                    reused[i] = p as i32;
                }
            }
        }
        for k in vf { res.push(k as i32); }
        var k: i64 = 0;
        while k < vf {
            var co: i32[>..<] = [];
            te_reorder_list(te, co);
            var sub: i32[>..<] = [];
            for j in sz { sub.push(reused[k + j]); }
            if sub[0] == -1 { for j in sz { sub[j] = j as i32; } }
            slp_reorder_order(co, sub, false);
            for j in co.len { res[k + j] = (co[j] as i64 + k) as i32; }
            k += sz;
        }
        if te_is_gather(te) {
            var ident = true;
            for j in res.len { if res[j] as i64 != j { ident = false; break; } }
            if ident { res.clear(); return false; }
        }
        return true;
    }
    if e.state == TE_STRIDED && !top && (e.ui_te < 0 || !te_has_state(e.ui_te) || !is_binary_op(te_opcode(e.ui_te))) &&
       (e.nreord == 0 || slp_is_reverse_order(te_reorder(te))) { return false; }
    let vstate = e.state == TE_VECTORIZE || e.state == TE_STRIDED || e.state == TE_EXPAND || e.state == TE_COMPRESS;
    if e.state == TE_SPLIT || (vstate && (is_inst_op(te_main(te), OP_LOAD) || is_inst_op(te_main(te), OP_EXTRACTELEMENT) ||
                                         is_inst_op(te_main(te), OP_EXTRACTVALUE) ||
                                         (top && (is_inst_op(te_main(te), OP_STORE) || is_inst_op(te_main(te), OP_INSERTELEMENT) ||
                                                  is_inst_op(te_main(te), OP_INSERTVALUE))))) {
        te_reorder_list(te, res);
        return true;
    }
    if !top && ignore && e.state == TE_VECTORIZE && te_is_alt_shuffle(te) {
        var mask: i32[>..<] = [];
        te_build_alt_op_shuffle_mask(te, mask);
        let vf = te_vector_factor(te);
        for k in vf { res.push(vf as i32); }
        for i in vf { if mask[i] != -1 { res[(mask[i] as i64) % vf] = i as i32; } }
        return true;
    }
    if e.nreord > 0 { te_reorder_list(te, res); return true; }
    if e.state == TE_VECTORIZE && te_opcode(te) == OP_PHI {
        return slp_phi_reordering(te, res);
    }
    if te_is_gather(te) && (!te_has_state(te) || !te_is_alt_shuffle(te) || slp_lk_head(SH_SPLIT, te_main(te) as i64) >= 0) &&
       slp_all_same_type(te_scalars(te)) {
        let sc = te_scalars(te);
        var ee_case = te_has_state(te) && te_opcode(te) == OP_EXTRACTELEMENT;
        if !ee_case {
            var all = true;
            var any = false;
            for v in sc {
                if is_inst_op(v, OP_EXTRACTELEMENT) { any = true; } else if !is_undef_or_poison(v) { all = false; }
            }
            ee_case = all && any;
        }
        if ee_case {
            for v in sc { if is_inst_op(v, OP_EXTRACTELEMENT) && ty_kind(vals[op(v, 0)].ty) != TK_FVEC { ee_case = false; break; } }
        }
        if ee_case {
            var co: i32[>..<] = [];
            var scc: i32[>..<] = [];
            slp_copy_list(sc, scc);
            let reuse = slp_can_reuse_extract(scc, co, true);
            if reuse || co.len > 0 { slp_copy_list(co, res); return true; }
        }
        let n = sc.len;
        var nundef: i64 = 0;
        for v in te_scalars(te) { if is_undef_or_poison(v) { nundef++; } }
        if slp_is_splat(te_scalars(te)) && !slp_all_constant(te_scalars(te)) && nundef == n - 1 {
            var it: i64 = n;
            for j in n { if !slp_is_constant(te_scalar(te, j)) { it = j; break; } }
            if it == 0 { res.clear(); return true; }
            let ty = slp_widened_type(vals[te_scalar(te, 0)].ty, n);
            if it != n {
                var order: i32[>..<] = [];
                for j in n { order.push(n as i32); }
                order[it] = 0;
                slp_fixup_ordering_indices(order);
                var mask: i32[>..<] = [];
                slp_inverse_permutation(order, mask);
                let pc = if top { 0 } else { slp_shuffle_cost(SK_PERMUTESINGLESRC, ty, mask, 0, -1) };
                let v = te_scalar(te, it);
                let pz = c_poison(ty);
                let ifc = tv_vec_inst(OP_INSERTELEMENT, ty, 0, pz, v, TCK_RECIP_THROUGHPUT);
                let iic = tv_vec_inst(OP_INSERTELEMENT, ty, it, pz, v, TCK_RECIP_THROUGHPUT);
                if tc_add(ifc, pc) < iic {
                    for j in n { res.push(n as i32); }
                    res[it] = 0;
                    return true;
                }
            }
        }
        if slp_is_splat(te_scalars(te)) { return false; }
        if n >= 3 {
            if slp_find_partially_ordered_loads(te, res) { return true; }
            res.clear();
        }
        if te_has_state(te) && te_opcode(te) == OP_LOAD {
            var ptrs: i32[>..<] = [];
            var co: i32[>..<] = [];
            var scc: i32[>..<] = [];
            slp_copy_list(te_scalars(te), scc);
            let r = slp_can_vectorize_loads(scc, scc[0], co, ptrs, false, true);
            if r == LS_VECTORIZE || r == LS_STRIDED || r == LS_COMPRESS { slp_copy_list(co, res); return true; }
        }
        if slp_find_reused_ordered_scalars(te, top, ignore, res) { return true; }
        res.clear();
    }
    return false;
}
// the PHI part of getReorderingData
fn slp_phi_reordering(te: i32, res: i32[>..<]&) -> bool {
    let n = te_nscalars(te);
    var bvhead: i32[>..<] = [];
    for k in n { bvhead.push(-1); }
    for k in n {
        let v = te_scalar(te, k);
        if slp_is_constant(v) || vals[v].first_use < 0 { continue; }
        let u0 = uses[vals[v].first_use].user;
        if !is_inst_op(u0, OP_INSERTELEMENT) { continue; }
        var ii = u0;
        var head: i32 = -1;
        let bb = inst_parent(ii);
        while ii >= 0 && slp_has_one_use(ii) && inst_parent(ii) == bb {
            head = ii;
            let o = op(ii, 0);
            ii = if is_inst_op(o, OP_INSERTELEMENT) { o } else { -1 };
        }
        bvhead[k] = head;
    }
    fn by_blocks(b1: i32, b2: i32) -> bool {
        if !slp_reachable(b1) { return false; }
        if !slp_reachable(b2) { return true; }
        return slp_dfs(b1) < slp_dfs(b2);
    }
    fn phi_less(i1: i32, i2: i32) -> bool {
        let v1 = te_scalar(te, i1 as i64);
        let v2 = te_scalar(te, i2 as i64);
        if v1 == v2 || (vals[v1].first_use < 0 && vals[v2].first_use < 0) { return false; }
        if is_poison(v1) { return true; }
        if is_poison(v2) { return false; }
        let n1 = slp_num_uses(v1);
        let n2 = slp_num_uses(v2);
        if n1 < n2 { return true; }
        if n1 > n2 { return false; }
        let f1 = uses[vals[v1].first_use].user;
        let f2 = uses[vals[v2].first_use].user;
        if inst_parent(f1) != inst_parent(f2) { return by_blocks(inst_parent(f1), inst_parent(f2)); }
        let ie1 = is_inst_op(f1, OP_INSERTELEMENT);
        let ie2 = is_inst_op(f2, OP_INSERTELEMENT);
        let ee1 = is_inst_op(f1, OP_EXTRACTELEMENT);
        let ee2 = is_inst_op(f2, OP_EXTRACTELEMENT);
        if ie1 && !ie2 { return true; }
        if !ie1 && ie2 { return false; }
        if ie1 && ie2 {
            let h1 = bvhead[i1 as i64];
            let h2 = bvhead[i2 as i64];
            if h1 >= 0 && h2 < 0 { return true; }
            if h1 < 0 { return false; }
            if h1 == h2 { return slp_element_index(f1, 0) < slp_element_index(f2, 0); }
            if inst_parent(h1) != inst_parent(h2) { return by_blocks(inst_parent(h1), inst_parent(h2)); }
            return slp_comes_before(h1, h2);
        }
        if ee1 && !ee2 { return true; }
        if !ee1 && ee2 { return false; }
        if ee1 && ee2 {
            let o1 = op(f1, 0);
            let o2 = op(f2, 0);
            let in1 = is_inst(o1);
            let in2 = is_inst(o2);
            let a1 = is_arg(o1);
            let a2 = is_arg(o2);
            if !in2 && !a2 { return in1 || a1; }
            if o1 == o2 { return slp_element_index(f1, 0) < slp_element_index(f2, 0); }
            if !in1 && in2 { return false; }
            if in1 && in2 {
                if inst_parent(o1) != inst_parent(o2) { return by_blocks(inst_parent(o1), inst_parent(o2)); }
                return slp_comes_before(o1, o2);
            }
            if !a1 && a2 { return false; }
            return args_no[vals[o1].sub] < args_no[vals[o2].sub];
        }
        return false;
    }
    var phis: i32[>..<] = [];
    for k in n { phis.push(k as i32); }
    std_stable_sort(phis, 0, phis.len) { a, b => phi_less(a, b) };
    if slp_is_identity_order(phis) { return false; }
    slp_copy_list(phis, res);
    return true;
}

// ---------------------------------------------------------------- isProfitableToReorder
fn slp_is_profitable_to_reorder() -> bool {
    if flag_bool("slp-disable-tree-reorder", false) { return false; }
    let tiny_vf: i64 = 2;
    let phi_ops_limit: i64 = 12;
    let gather_loads_limit: i64 = 2;
    if slp_te.len <= 10 { return true; }
    let f: i32 = 0;
    if te_has_state(f) && !te_is_gather(f) &&
       (te_opcode(f) == OP_STORE || te_opcode(f) == OP_PHI ||
        (te_vector_factor(f) <= tiny_vf && (te_opcode(f) == OP_PTRTOINT || te_opcode(f) == OP_ICMP))) && slp_te[f].nreord == 0 {
        if te_has_state(f) && te_opcode(f) == OP_PHI && te_nscalars(f) == tiny_vf && te_num_operands(f) > phi_ops_limit { return false; }
        if te_has_state(f) && te_opcode(f) == OP_STORE && slp_te[f].nreord == 0 {
            var rsc: i64 = 0;
            for t in slp_te.len {
                let e = slp_te[t];
                if e.state == TE_SPLIT && e.nreord > 0 && e.ui_te >= 0 && slp_te[e.ui_te].state == TE_VECTORIZE &&
                   slp_is_commutative(te_main(e.ui_te)) { rsc++; }
            }
            var cnt: i64 = 0;
            for t0 in slp_te.len {
                let t = t0 as i32;
                let e = slp_te[t];
                var a = (!te_is_gather(t) && (e.nreord == 0 || (e.ui_te >= 0 && slp_te[e.ui_te].state == TE_VECTORIZE && slp_te[e.ui_te].nreuse > 0))) ||
                        (te_is_gather(t) && e.nreord == 0 && (!te_has_state(t) || te_is_alt_shuffle(t) || te_opcode(t) == OP_LOAD ||
                                                              te_opcode(t) == OP_ZEXT || te_opcode(t) == OP_SEXT));
                if a {
                    var b = te_vector_factor(f) > tiny_vf || !te_is_gather(t);
                    if !b {
                        var none = true;
                        for v in te_scalars(t) { if !slp_is_constant(v) && slp_is_vectorized(v) { none = false; break; } }
                        b = none;
                    }
                    a = b;
                }
                if a { cnt++; }
            }
            if rsc <= 1 && cnt >= slp_te.len - rsc { return false; }
        }
        var has_phis = false;
        var has_load = true;
        var gather_loads: i64 = 0;
        for t0 in 1..slp_te.len {
            let t = t0 as i32;
            if slp_te[t].state == TE_SPLIT { continue; }
            if !te_has_state(t) {
                var a1 = true;
                var a2 = true;
                for v in te_scalars(t) {
                    if !(is_constant(v) || is_inst_op(v, OP_PHI)) { a1 = false; }
                    if !(slp_is_binop(v) || is_inst_op(v, OP_PHI)) { a2 = false; }
                }
                if a1 || a2 { continue; }
                if te_nscalars(f) == tiny_vf {
                    var any = false;
                    for v in te_scalars(t) { if is_inst_op(v, OP_PHI) || slp_is_gep_operator(v) { any = true; break; } }
                    if any { continue; }
                }
                return true;
            }
            if te_opcode(t) == OP_LOAD && slp_te[t].nreord == 0 {
                if !te_is_gather(t) { has_load = false; continue; }
                if has_load { return true; }
                gather_loads++;
                if gather_loads >= gather_loads_limit { return true; }
            }
            if te_opcode(t) == OP_GEP || is_binary_op(te_opcode(t)) { continue; }
            if te_opcode(t) != OP_PHI {
                var nphi: i64 = 0;
                for v in te_scalars(t) { if is_inst_op(v, OP_PHI) { nphi++; } }
                if !te_has_copyable_elements(t) || nphi < te_nscalars(t) / 2 { return true; }
            }
            if te_nscalars(f) == tiny_vf && te_num_operands(t) > phi_ops_limit { return false; }
            has_phis = true;
        }
        return !has_phis;
    }
    return true;
}

// ---------------------------------------------------------------- external store users
// findExternalStoreUsersReorderIndices(TE) (with collectUserStores and canFormVector): orders in `out` (runs)
fn slp_external_store_users_orders(te: i32, out_at: i64[>..<]&, out_n: i64[>..<]&, pool: i32[>..<]&) {
    out_at.clear();
    out_n.clear();
    let nl = te_nscalars(te);
    let rmd = slp_recursion_max_depth_opt();
    // PtrToStoresMap: (BB, value type, underlying object) -> stores
    var k_bb: i32[>..<] = [];
    var k_ty: i32[>..<] = [];
    var k_obj: i32[>..<] = [];
    var s_k: i64[>..<] = [];
    var s_si: i32[>..<] = [];
    fn count_of(k: i64) -> i64 { var c: i64 = 0; for x in s_k { if x == k { c++; } } return c; }
    fn front_of(k: i64) -> i32 { for j in s_k.len { if s_k[j] == k { return s_si[j]; } } return -1; }
    for lane in nl {
        let v = te_scalar(te, lane);
        if !is_inst(v) { continue; }
        if slp_has_n_uses_or_more(v, SLP_USES_LIMIT) { break; }
        var u = vals[v].first_use;
        while u >= 0 {
            let si = uses[u].user;
            u = uses[u].next;
            if !is_inst_op(si, OP_STORE) || !ld_is_simple(si) || inst_func(si) != slp_fn ||
               !slp_is_valid_element_type(vals[op(si, 0)].ty) { continue; }
            if slp_is_vectorized(si) { continue; }
            let ptr = get_underlying_object(op(si, 1), rmd);
            let ty: i32 = vals[op(si, 0)].ty;
            var k: i64 = -1;
            for j in k_bb.len { if k_bb[j] == inst_parent(si) && k_ty[j] == ty && k_obj[j] == ptr { k = j; break; } }
            if k < 0 { k = k_bb.len; k_bb.push(inst_parent(si)); k_ty.push(ty); k_obj.push(ptr); }
            let c = count_of(k);
            if c > lane { continue; }
            if c > 0 {
                let ok, d = laa_get_pointers_diff(ty, op(si, 1), ty, op(front_of(k), 1), true, true);
                if !ok { continue; }
            }
            s_k.push(k);
            s_si.push(si);
        }
    }
    for k in k_bb.len {
        var sv: i32[>..<] = [];
        for j in s_k.len { if s_k[j] == k as i64 { sv.push(s_si[j]); } }
        if sv.len != nl { continue; }
        // canFormVector(StoresVec, ReorderIndices)
        let s0 = sv[0];
        let s0ty: i32 = vals[op(s0, 0)].ty;
        var offs: i64[>..<] = [];
        var idxs: i64[>..<] = [];
        offs.push(0); idxs.push(0);
        for i in 1..sv.len {
            let ok, d = laa_get_pointers_diff(s0ty, op(s0, 1), vals[op(sv[i], 0)].ty, op(sv[i], 1), true, true);
            offs.push(if ok { d } else { 0 });
            idxs.push(i);
        }
        var ord: i64[>..<] = [];
        for i in offs.len { ord.push(i); }
        std_stable_sort(ord, 0, ord.len) { a, b => offs[a] < offs[b] };
        var ok = true;
        for j in ord.len { if j > 0 && offs[ord[j]] != offs[ord[j - 1]] + 1 { ok = false; break; } }
        if !ok { continue; }
        var ri: i32[>..<] = [];
        for j in sv.len { ri.push(0); }
        var ident = true;
        for j in ord.len { ri[idxs[ord[j]]] = j as i32; ident = ident && idxs[ord[j]] == j; }
        if ident { ri.clear(); }
        out_at.push(pool.len);
        out_n.push(ri.len);
        for x in ri { pool.push(x); }
    }
    if out_at.len > 1 {
        // collectUserStores iterates a pointer-keyed SmallDenseMap: its order decides the OrdersUses order
        var same = true;
        for j in 1..out_at.len {
            if !slp_lists_equal(pool[out_at[0]..(out_at[0] + out_n[0])], pool[out_at[j]..(out_at[j] + out_n[j])]) { same = false; }
        }
        if !same { slp_fail("findExternalStoreUsersReorderIndices with several store groups of different orders (DenseMap order)"); }
    }
}

// ---------------------------------------------------------------- reorderNodeWithReuses
// isRepeatedNonIdentityClusteredMask(Mask, Sz)
fn slp_is_repeated_non_identity_clustered_mask(m: const i32[:], sz: i64) -> bool {
    if slp_is_identity_mask(m[0..sz], sz) { return false; }
    var i = sz;
    while i < m.len {
        for k in sz { if m[i + k] != m[k] { return false; } }
        i += sz;
    }
    return true;
}
fn te_reorder_node_with_reuses(te: i32, mask: const i32[:]) {
    var ru: i32[>..<] = [];
    te_reuse_list(te, ru);
    slp_reorder_reuses(ru, mask);
    te_set_reuse(te, ru);
    let sz = te_nscalars(te);
    if !te_is_gather(te) || !slp_is_one_use_single_source_mask(ru, sz) || !slp_is_repeated_non_identity_clustered_mask(ru, sz) { return; }
    var nm: i32[>..<] = [];
    slp_inverse_permutation(te_reorder(te), nm);
    slp_add_mask(nm, ru, false);
    te_clear_reorder(te);
    var no: i32[>..<] = [];
    for k in sz { no.push(nm[k]); }
    slp_inverse_permutation(no, nm);
    te_reorder_scalars(te, nm);
    for k in ru.len { ru[k] = (k % sz) as i32; }
    te_set_reuse(te, ru);
}

// ---------------------------------------------------------------- OrdersUses
// MapVector<OrdersType, unsigned>: keys are runs of ou_pool
struct SOU { at: i64, n: i64, cnt: i64 }
fn sou_find(ou: SOU[>..<]&, pool: i32[>..<]&, key: const i32[:]) -> i64 {
    for k in ou.len { if ou[k].n == key.len && slp_lists_equal(pool[ou[k].at..(ou[k].at + ou[k].n)], key) { return k; } }
    let at = pool.len;
    for x in key { pool.push(x); }
    ou.push(SOU { at: at, n: key.len, cnt: 0 });
    return ou.len - 1;
}
// choosing the most used order; `filled` = the top-to-bottom variant (FilledIdentityCnt). The best order is copied
// into `best`.
fn sou_best(ou: SOU[>..<]&, pool: i32[>..<]&, vf: i64, filled: bool, best: i32[>..<]&) {
    var ident_cnt: i64 = 0;
    var filled_cnt: i64 = 0;
    var ident: i32[>..<] = [];
    for k in vf { ident.push(vf as i32); }
    for p in ou.len {
        let key = pool[ou[p].at..(ou[p].at + ou[p].n)];
        if key.len == 0 || slp_is_identity_order(key) {
            if key.len > 0 { filled_cnt += ou[p].cnt; }
            ident_cnt += ou[p].cnt;
            slp_combine_orders(ident, key);
        }
    }
    // BestOrder: -1 = IdentityOrder, else the key of pair k (combineOrders mutates both in place)
    var bi: i64 = -1;
    var cnt = ident_cnt;
    fn best_view() -> const i32[:] { if bi < 0 { ident[..] } else { pool[ou[bi].at..(ou[bi].at + ou[bi].n)] } }
    for p in ou.len {
        let pc = ou[p].cnt;
        var take = cnt < pc;
        if !take && filled {
            let bv = best_view();
            take = cnt == ident_cnt && ident_cnt == filled_cnt && cnt == pc && bv.len > 0 && slp_is_identity_order(bv);
        }
        if take {
            // combineOrders(Pair.first, BestOrder)
            var key: i32[>..<] = [];
            slp_copy_list(pool[ou[p].at..(ou[p].at + ou[p].n)], key);
            var bcopy: i32[>..<] = [];
            slp_copy_list(best_view(), bcopy);
            slp_combine_orders(key, bcopy);
            for j in key.len { pool[ou[p].at + j] = key[j]; }
            bi = p;
            cnt = pc;
        } else {
            var bcopy: i32[>..<] = [];
            slp_copy_list(best_view(), bcopy);
            slp_combine_orders(bcopy, pool[ou[p].at..(ou[p].at + ou[p].n)]);
            if bi < 0 { slp_copy_list(bcopy, ident); } else { for j in bcopy.len { pool[ou[bi].at + j] = bcopy[j]; } }
        }
    }
    slp_copy_list(best_view(), best);
}

// ---------------------------------------------------------------- reorderTopToBottom
fn slp_is_vstate(st: i32) -> bool { st == TE_VECTORIZE || st == TE_STRIDED || st == TE_EXPAND || st == TE_COMPRESS }
fn slp_reorder_top_to_bottom() {
    for t in slp_te.len {
        if slp_te[t].state == TE_VECTORIZE && ty_is_struct(slp_value_type(te_scalar(t as i32, 0), false)) { return; }
    }
    let ignore = !slp_uil_on && te_has_state(0) &&
                 (te_opcode(0) == OP_INSERTELEMENT || te_opcode(0) == OP_INSERTVALUE || te_opcode(0) == OP_STORE);
    // VFToOrderedEntries (VF -> SetVector of entries), as (vf, entry) pairs in insertion order
    var vfe_vf: i64[>..<] = [];
    var vfe_te: i32[>..<] = [];
    fn vfe_insert(vf: i64, te: i32) {
        for k in vfe_vf.len { if vfe_vf[k] == vf && vfe_te[k] == te { return; } }
        vfe_vf.push(vf);
        vfe_te.push(te);
    }
    // the orders of GathersToOrders / PhisToOrders / AltShufflesToOrders / ExternalUserReorderMap: entry -> runs of pool
    var pool: i32[>..<] = [];
    var g_te: i32[>..<] = [];
    var g_at: i64[>..<] = [];
    var g_n: i64[>..<] = [];
    var p_te: i32[>..<] = [];
    var p_at: i64[>..<] = [];
    var p_n: i64[>..<] = [];
    var a_te: i32[>..<] = [];
    var x_te: i32[>..<] = [];
    var x_at: i64[>..<] = [];   // per external map entry: the first order index in xo_*
    var x_n: i64[>..<] = [];
    var xo_at: i64[>..<] = [];
    var xo_n: i64[>..<] = [];
    fn find_te(xs: const i32[:], te: i32) -> i64 { for k in xs.len { if xs[k] == te { return k; } } return -1; }
    for t0 in slp_te.len {
        let t = t0 as i32;
        var eat: i64[>..<] = [];
        var en: i64[>..<] = [];
        slp_external_store_users_orders(t, eat, en, pool);
        if eat.len > 0 {
            vfe_insert(te_vector_factor(t), t);
            if find_te(x_te, t) < 0 {
                x_te.push(t);
                x_at.push(xo_at.len);
                x_n.push(eat.len);
                for k in eat.len { xo_at.push(eat[k]); xo_n.push(en[k]); }
            }
        }
        if te_has_state(t) && te_is_alt_shuffle(t) && slp_te[t].state != TE_SPLIT {
            let sty: i32 = vals[te_scalar(t, 0)].ty;
            let vecty = slp_widened_type(sty, te_nscalars(t));
            let o0 = te_opcode(t);
            let o1 = te_alt_opcode(t);
            var om: bool[>..<] = [];
            slp_alt_instr_mask(te_scalars(t), sty, o1, om);
            if slp_tti_legal_alt_instr(vecty, o0, o1, om) {
                vfe_insert(te_vector_factor(t), t);
                if find_te(a_te, t) < 0 { a_te.push(t); }
            }
        }
        var cur: i32[>..<] = [];
        if slp_get_reordering_data(t, true, ignore, cur) {
            var cnt: i64 = 0;
            var ut = t;
            var skip = false;
            while ut >= 0 && cnt < slp_recursion_max_depth_opt() {
                let u = slp_te[ut].ui_te;
                if u < 0 { break; }
                if slp_te[u].state == TE_VECTORIZE && te_is_alt_shuffle(u) && u != 0 { skip = true; break; }
                ut = u;
                cnt++;
            }
            if skip { continue; }
            vfe_insert(te_vector_factor(t), t);
            let st = slp_te[t].state;
            if !(slp_is_vstate(st) || st == TE_SPLIT) || slp_te[t].nreuse > 0 {
                if find_te(g_te, t) < 0 { g_te.push(t); g_at.push(pool.len); g_n.push(cur.len); for x in cur { pool.push(x); } }
            }
            if st == TE_VECTORIZE && te_opcode(t) == OP_PHI {
                if find_te(p_te, t) < 0 { p_te.push(t); p_at.push(pool.len); p_n.push(cur.len); for x in cur { pool.push(x); } }
            }
        }
    }
    var vf = te_vector_factor(0);
    while vfe_vf.len > 0 && vf > 1 {
        var entries: i32[>..<] = [];
        for k in vfe_vf.len { if vfe_vf[k] == vf { entries.push(vfe_te[k]); } }
        if entries.len == 0 { vf--; continue; }
        // Cleanup: erase the VF's entries
        var nvf: i64[>..<] = [];
        var nte: i32[>..<] = [];
        for k in vfe_vf.len { if vfe_vf[k] != vf { nvf.push(vfe_vf[k]); nte.push(vfe_te[k]); } }
        vfe_vf.clear(); vfe_te.clear();
        for k in nvf.len { vfe_vf.push(nvf[k]); vfe_te.push(nte[k]); }
        var ou: SOU[>..<] = [];
        var oup: i32[>..<] = [];
        for opte in entries {
            let gi = find_te(g_te, opte);
            if slp_te[opte].nreuse > 0 && gi < 0 && slp_te[opte].state != TE_SPLIT { continue; }
            var order: i32[>..<] = [];
            var got = false;
            if te_is_gather(opte) || slp_te[opte].nreuse > 0 {
                if gi >= 0 { slp_copy_list(pool[g_at[gi]..(g_at[gi] + g_n[gi])], order); got = true; }
            }
            if !got && te_has_state(opte) && te_is_alt_shuffle(opte) {
                if find_te(a_te, opte) >= 0 { order.clear(); got = true; }
            }
            if !got && slp_te[opte].state == TE_VECTORIZE && te_opcode(opte) == OP_PHI {
                let pi = find_te(p_te, opte);
                if pi >= 0 { slp_copy_list(pool[p_at[pi]..(p_at[pi] + p_n[pi])], order); got = true; }
            }
            if !got { te_reorder_list(opte, order); }
            let xi = find_te(x_te, opte);
            if xi >= 0 {
                if te_vector_factor(opte) != te_nscalars(opte) {
                    let k = sou_find(ou, oup, slp_no_mask());
                    ou[k].cnt += x_n[xi];
                } else {
                    for j in x_n[xi] {
                        let o = x_at[xi] + j;
                        let k = sou_find(ou, oup, pool[xo_at[o]..(xo_at[o] + xo_n[o])]);
                        ou[k].cnt += 1;
                    }
                }
                if order.len == 0 { continue; }
            }
            if slp_te[opte].state == TE_VECTORIZE && te_opcode(opte) == OP_STORE && order.len > 0 {
                var mask: i32[>..<] = [];
                slp_inverse_permutation(order, mask);
                let e = order.len;
                var co: i32[>..<] = [];
                for x in mask { co.push(if x == -1 { e as i32 } else { x }); }
                slp_fixup_ordering_indices(co);
                let k = sou_find(ou, oup, co);
                ou[k].cnt += 1;
            } else {
                let k = sou_find(ou, oup, order);
                ou[k].cnt += 1;
            }
        }
        if ou.len == 0 { vf--; continue; }
        var best: i32[>..<] = [];
        sou_best(ou, oup, vf, true, best);
        if slp_is_identity_order(best) { vf--; continue; }
        slp_fixup_ordering_indices(best);
        var mask: i32[>..<] = [];
        slp_inverse_permutation(best, mask);
        let e = best.len;
        var mo: i32[>..<] = [];
        for x in best { mo.push(if (x as i64) < e { x } else { -1 }); }
        for t0 in slp_te.len {
            let t = t0 as i32;
            if te_nscalars(t) != vf {
                if slp_te[t].nreuse as i64 == vf && slp_te[t].state != TE_EXPAND {
                    te_reorder_node_with_reuses(t, mask);
                    let u = slp_te[t].ui_te;
                    if u >= 0 && slp_te[u].state == TE_SPLIT { te_reorder_split_node(u, slp_te[t].ui_edge, mask, mo); }
                }
                continue;
            }
            let st = slp_te[t].state;
            let m = te_main(t);
            if (st == TE_SPLIT && slp_te[t].nreuse == 0) ||
               (slp_is_vstate(st) && (is_inst_op(m, OP_EXTRACTELEMENT) || is_inst_op(m, OP_EXTRACTVALUE) || is_inst_op(m, OP_LOAD) ||
                                      is_inst_op(m, OP_STORE) || is_inst_op(m, OP_INSERTELEMENT) || is_inst_op(m, OP_INSERTVALUE))) {
                var ro: i32[>..<] = [];
                te_reorder_list(t, ro);
                slp_reorder_order(ro, mask, false);
                te_set_reorder(t, ro);
                if is_inst_op(m, OP_INSERTELEMENT) || is_inst_op(m, OP_INSERTVALUE) || is_inst_op(m, OP_STORE) { te_reorder_operands(t, mask); }
            } else {
                te_reorder_operands(t, mask);
                te_reorder_scalars(t, mask);
            }
            if slp_te[t].nreuse > 0 && slp_te[t].state != TE_EXPAND {
                var co: i32[>..<] = [];
                slp_reorder_order(co, mo, false);
                var nr: i32[>..<] = [];
                slp_inverse_permutation(co, nr);
                slp_add_mask(nr, te_reuse(t), false);
                te_set_reuse(t, nr);
            } else if slp_te[t].ui_te >= 0 && slp_te[slp_te[t].ui_te].state == TE_SPLIT {
                te_reorder_split_node(slp_te[t].ui_te, slp_te[t].ui_edge, mask, mo);
            }
        }
        vf--;
    }
}

// ---------------------------------------------------------------- reorderBottomToTop
// buildReorderableOperands(UserTE, Edges, ReorderableGathers = NonVectorized, GatherOps)
fn slp_build_reorderable_operands(ut: i32, e_idx: i64[>..<]&, e_te: i32[>..<]&, nonvec: const bool[:], gops: i32[>..<]&) {
    for i in te_num_operands(ut) {
        var skip = false;
        for k in e_idx.len {
            if e_idx[k] == i { let st = slp_te[e_te[k]].state; if slp_is_vstate(st) || st == TE_SPLIT { skip = true; break; } }
        }
        if skip { continue; }
        if te_has_state(ut) {
            let o = te_opcode(ut);
            let st = slp_te[ut].state;
            if o == OP_EXTRACTELEMENT || o == OP_EXTRACTVALUE { continue; }
            if (o == OP_INSERTELEMENT || o == OP_INSERTVALUE) && i == 0 { continue; }
            if o == OP_STORE && i == 1 && (st == TE_VECTORIZE || st == TE_STRIDED || st == TE_EXPAND) { continue; }
            if o == OP_LOAD && (st == TE_VECTORIZE || st == TE_STRIDED || st == TE_COMPRESS) { continue; }
        }
        let t = slp_operand_entry(ut, i);
        if t < 0 { fatal("internal: SLP: expected operand entry"); }
        if !te_is_gather(t) {
            e_idx.push(i);
            e_te.push(t);
            if slp_te[t].state == TE_SCATTER && slp_te[t].nreuse == 0 && slp_te[t].nreord == 0 { gops.push(t); }
            continue;
        }
        if nonvec[t as i64] { gops.push(t); }
    }
}
// TreeEntryCompare(LHS, RHS)
fn slp_te_less(a: i32, b: i32) -> bool {
    let ua = slp_te[a].ui_te;
    let ub = slp_te[b].ui_te;
    if ua >= 0 && ub >= 0 { return ua < ub; }
    return a < b;
}
// std::priority_queue<TreeEntry *, ..., TreeEntryCompare> with libstdc++'s heap algorithms
fn slp_pq_push(h: i32[>..<]&, x: i32) {
    h.push(x);
    var hole = h.len - 1;
    var parent = (hole - 1) / 2;
    while hole > 0 && slp_te_less(h[parent], x) {
        h[hole] = h[parent];
        hole = parent;
        parent = (hole - 1) / 2;
    }
    h[hole] = x;
}
fn slp_pq_pop(h: i32[>..<]&) {
    let len = h.len - 1;
    let value = h[len];
    h[len] = h[0];
    // __adjust_heap(first, 0, len, value)
    var hole: i64 = 0;
    var second: i64 = 0;
    while second < (len - 1) / 2 {
        second = 2 * (second + 1);
        if slp_te_less(h[second], h[second - 1]) { second--; }
        h[hole] = h[second];
        hole = second;
    }
    if (len & 1) == 0 && len >= 2 && second == (len - 2) / 2 {
        second = 2 * (second + 1);
        h[hole] = h[second - 1];
        hole = second - 1;
    }
    var parent = (hole - 1) / 2;
    while hole > 0 && slp_te_less(h[parent], value) {
        h[hole] = h[parent];
        hole = parent;
        parent = (hole - 1) / 2;
    }
    h[hole] = value;
    h.pop();
}
fn slp_reorder_bottom_to_top(ignore0: bool) {
    var ignore = ignore0;
    var q: i32[>..<] = [];
    let n = slp_te.len;
    var g2o: bool[>..<] = [];       // GathersToOrders
    var nonvec: bool[>..<] = [];    // NonVectorized
    var visited: bool[>..<] = [];
    var revisited: bool[>..<] = [];
    for k in n { g2o.push(false); nonvec.push(false); visited.push(false); revisited.push(false); }
    for t0 in n {
        let t = t0 as i32;
        let st = slp_te[t].state;
        if !(slp_is_vstate(st) || st == TE_SPLIT) { nonvec[t0] = true; }
        var cur: i32[>..<] = [];
        if slp_get_reordering_data(t, false, ignore, cur) {
            slp_pq_push(q, t);
            if !(slp_is_vstate(st) || st == TE_SPLIT) || slp_te[t].nreuse > 0 { g2o[t0] = true; }
        }
    }
    while q.len > 0 {
        var t = q[0];
        let ut = slp_te[t].ui_te;
        slp_pq_pop(q);
        var ordered: i32[>..<] = [];
        ordered.push(t);
        while q.len > 0 {
            t = q[0];
            if ut < 0 || ut != slp_te[t].ui_te { break; }
            slp_pq_pop(q);
            ordered.push(t);
        }
        var user: i32 = -1;
        var d_idx: i64[>..<] = [];
        var d_te: i32[>..<] = [];
        for x in ordered {
            let st = slp_te[x].state;
            if !(slp_is_vstate(st) || st == TE_SPLIT || (te_is_gather(x) && g2o[x as i64])) || slp_te[x].ui_te < 0 ||
               slp_te[x].nreuse > 0 || visited[x as i64] { continue; }
            visited[x as i64] = true;
            user = slp_te[x].ui_te;
            d_idx.push(slp_te[x].ui_edge);
            d_te.push(x);
        }
        if user < 0 { continue; }
        if slp_te[user].state == TE_VECTORIZE && ty_is_struct(slp_value_type(te_scalar(user, 0), false)) { continue; }
        if slp_te[user].state == TE_SPLIT {
            var bad = false;
            for x in d_te { if slp_te[x].ui_te < 0 { bad = true; } }
            if bad { continue; }
            for ci in te_comb_n(user) {
                let opte = te_comb_idx(user, ci);
                let cidx = te_comb_off(user, ci);
                if slp_te[opte].state != TE_SPLIT && slp_te[opte].nreord > 0 && slp_te[opte].nreuse > 0 { continue; }
                var order: i32[>..<] = [];
                te_reorder_list(opte, order);
                if order.len == 0 || slp_te[opte].nreuse > 0 {
                    if !te_is_gather(opte) && slp_te[opte].nreuse == 0 { continue; }
                    var bo: i32[>..<] = [];
                    if !slp_get_reordering_data(opte, false, ignore, bo) || bo.len == 0 || slp_is_identity_order(bo) { continue; }
                    slp_copy_list(bo, order);
                }
                slp_fixup_ordering_indices(order);
                var mask: i32[>..<] = [];
                slp_inverse_permutation(order, mask);
                let e = order.len;
                var mo: i32[>..<] = [];
                for x in order { mo.push(if (x as i64) < e { x } else { -1 }); }
                te_reorder_split_node(user, if cidx != 0 { 1 } else { 0 }, mask, mo);
                if slp_te[opte].nreord > 0 { te_clear_reorder(opte); }
                else if slp_te[opte].nreuse > 0 {
                    var ru: i32[>..<] = [];
                    te_reuse_list(opte, ru);
                    slp_reorder_reuses(ru, mask);
                    te_set_reuse(opte, ru);
                } else {
                    te_reorder_scalars(opte, mask);
                }
            }
            if slp_te[user].nreuse == 0 && slp_te[user].nreord > 0 { slp_pq_push(q, user); }
            continue;
        }
        var gops: i32[>..<] = [];
        slp_build_reorderable_operands(user, d_idx, d_te, nonvec, gops);
        var ou: SOU[>..<] = [];
        var oup: i32[>..<] = [];
        var vops: i32[>..<] = [];
        var vusers: i32[>..<] = [];
        fn allows_reordering(x: i32) -> bool {
            if slp_te[x].nreord > 0 || slp_te[x].nreuse > 0 || (slp_te[x].state == TE_VECTORIZE && te_is_alt_shuffle(x)) ||
               (ignore && x == 0) { return true; }
            if te_is_gather(x) {
                if g2o[x as i64] {
                    var o: i32[>..<] = [];
                    if !slp_get_reordering_data(x, false, ignore, o) { return true; }   // value_or(OrdersType(1)): non-empty
                    return o.len > 0;
                }
                return true;
            }
            return false;
        }
        fn num_operands(x: i32) -> i64 {
            if slp_te[x].state == TE_SPLIT { return te_num_operands(x); }
            if is_inst_op(te_main(x), OP_CALL) { return cb_nargs(te_main(x)); }
            return te_num_operands(x);
        }
        fn vec_intr_id(x: i32) -> i32 {
            if is_inst_op(te_main(x), OP_CALL) { return laa_vector_intrinsic_id_for_call(te_main(x)); }
            return 0;
        }
        fn reordered_with_operands(x: i32) -> bool {
            let id = vec_intr_id(x);
            for idx in num_operands(x) {
                if id != 0 && vu_scalar_op_at_arg(id, idx, true) { continue; }
                var o = slp_operand_entry(x, idx);
                if te_is_gather(o) && te_has_state(o) {
                    let vo = slp_same_values_tree_entry(te_main(o), te_scalars(o), false);
                    if vo >= 0 { o = vo; }
                }
                if slp_te[o].nreord == 0 && slp_te[o].nreuse == 0 { return false; }
            }
            return true;
        }
        for di in d_te.len {
            let opte = d_te[di];
            if slp_contains(vops, opte) { continue; }
            vops.push(opte);
            if slp_te[opte].nreuse > 0 && !g2o[opte as i64] { continue; }
            var order: i32[>..<] = [];
            if te_is_gather(opte) || slp_te[opte].nreuse > 0 {
                if !slp_get_reordering_data(opte, false, ignore, order) { order.clear(); order.push(0); }
            } else {
                te_reorder_list(opte, order);
            }
            if order.len == 1 { continue; }
            if order.len > 0 && !slp_is_identity_order(order) {
                var root: i32 = -1;
                if te_has_state(opte) { root = te_main(opte); }
                else { for v in te_scalars(opte) { if !slp_is_constant(v) { root = v; break; } } }
                // GetSameNodesUsers(Root)
                var users: i32[>..<] = [];
                fn add_same(x: i32) {
                    if x != opte && slp_te[x].ui_te >= 0 && te_vector_factor(x) == te_vector_factor(opte) &&
                       te_nscalars(x) == te_nscalars(opte) &&
                       ((slp_te[x].nreord == 0 && te_is_same(opte, te_scalars(x))) || (slp_te[opte].nreord == 0 && te_is_same(x, te_scalars(opte)))) {
                        if !slp_contains(users, slp_te[x].ui_te) { users.push(slp_te[x].ui_te); }
                    }
                }
                var c = slp_lk_head(SH_V2G, root as i64);
                while c >= 0 { add_same(slp_lk[c].x); c = slp_lk[c].next; }
                c = slp_tree_entries_head(root);
                while c >= 0 { add_same(slp_lk[c].x); c = slp_lk[c].next; }
                if users.len > 0 {
                    var all = true;
                    for ute in users {
                        if revisited[ute as i64] { all = false; break; }
                        revisited[ute as i64] = true;
                        let ok = ute == user || slp_te[ute].nreord > 0 || slp_te[ute].nreuse > 0 ||
                                 (slp_te[ute].ui_te >= 0 && slp_te[ute].ui_te == user) ||
                                 (slp_te[user].ui_te >= 0 && slp_te[user].ui_te == ute) ||
                                 (ignore && slp_te[ute].ui_te >= 0 && slp_te[ute].ui_te == 0) ||
                                 reordered_with_operands(ute);
                        if !ok { all = false; break; }
                    }
                    if !all { continue; }
                }
                for ute in users {
                    let id = vec_intr_id(ute);
                    for idx in num_operands(ute) {
                        if id != 0 && vu_scalar_op_at_arg(id, idx, true) { continue; }
                        let o = slp_operand_entry(ute, idx);
                        visited[o as i64] = false;
                        slp_pq_push(q, o);
                    }
                }
            }
            var nops_: i64 = 0;
            for x in d_te { if x == opte { nops_++; } }
            if slp_te[opte].state == TE_VECTORIZE && te_opcode(opte) == OP_STORE && order.len > 0 {
                var mask: i32[>..<] = [];
                slp_inverse_permutation(order, mask);
                let e = order.len;
                var co: i32[>..<] = [];
                for x in mask { co.push(if x == -1 { e as i32 } else { x }); }
                slp_fixup_ordering_indices(co);
                let k = sou_find(ou, oup, co);
                ou[k].cnt += nops_;
            } else {
                let k = sou_find(ou, oup, order);
                ou[k].cnt += nops_;
            }
            let rk = sou_find(ou, oup, slp_no_mask());
            if slp_te[opte].ui_te >= 0 {
                let u2 = slp_te[opte].ui_te;
                if slp_contains(vusers, u2) { continue; }
                vusers.push(u2);
                if allows_reordering(u2) { continue; }
                var cnt: i64 = 0;
                for x in d_te { if allows_reordering(x) && slp_te[x].ui_te == u2 { cnt++; } }
                if cnt <= d_te.len / 2 { ou[rk].cnt += 1; }
            }
        }
        if ou.len == 0 {
            for x in d_te { visited[x as i64] = true; }
            continue;
        }
        let vf = te_vector_factor(d_te[0]);
        var best: i32[>..<] = [];
        sou_best(ou, oup, vf, false, best);
        if slp_is_identity_order(best) {
            for x in d_te { visited[x as i64] = true; }
            continue;
        }
        slp_fixup_ordering_indices(best);
        vops.clear();
        var mask: i32[>..<] = [];
        slp_inverse_permutation(best, mask);
        let e = best.len;
        var mo: i32[>..<] = [];
        for x in best { mo.push(if (x as i64) < e { x } else { -1 }); }
        for x in d_te {
            if slp_contains(vops, x) { continue; }
            vops.push(x);
            if slp_te[x].state == TE_VECTORIZE && ty_is_struct(slp_value_type(te_scalar(x, 0), false)) { continue; }
            if slp_te[x].nreuse as i64 == best.len { te_reorder_node_with_reuses(x, mask); continue; }
            let st = slp_te[x].state;
            if !slp_is_vstate(st) && st != TE_SPLIT && (st != TE_SCATTER || slp_te[x].nreord == 0) { continue; }
            var ro: i32[>..<] = [];
            te_reorder_list(x, ro);
            slp_reorder_order(ro, mask, false);
            te_set_reorder(x, ro);
            if ignore && x == 0 { ignore = false; }
        }
        for g in gops {
            if slp_te[g].nreuse > 0 {
                var ru: i32[>..<] = [];
                te_reuse_list(g, ru);
                slp_reorder_reuses(ru, mask);
                te_set_reuse(g, ru);
                continue;
            }
            te_reorder_scalars(g, mask);
            visited[g as i64] = true;
        }
        fn not_profitable_alt(x: i32) -> bool {
            return te_is_alt_shuffle(x) && (slp_te[x].nreuse > 0 || te_vector_factor(x) == 2 || slp_te[x].nreord == 0);
        }
        let um = te_main(user);
        if slp_te[user].state != TE_VECTORIZE ||
           !(is_inst_op(um, OP_EXTRACTELEMENT) || is_inst_op(um, OP_EXTRACTVALUE) || is_inst_op(um, OP_LOAD)) || not_profitable_alt(user) {
            te_reorder_operands(user, mask);
        }
        if !(is_inst_op(um, OP_INSERTELEMENT) || is_inst_op(um, OP_INSERTVALUE) || is_inst_op(um, OP_STORE)) || not_profitable_alt(user) ||
           slp_te[user].state == TE_COMPRESS {
            te_reorder_scalars(user, mask);
            var ro: i32[>..<] = [];
            te_reorder_list(user, ro);
            slp_reorder_order(ro, mo, true);
            te_set_reorder(user, ro);
            if slp_te[user].nreuse == 0 && slp_te[user].nreord > 0 && !not_profitable_alt(user) { slp_pq_push(q, user); }
        } else {
            var ro: i32[>..<] = [];
            te_reorder_list(user, ro);
            slp_reorder_order(ro, mask, false);
            te_set_reorder(user, ro);
        }
    }
    if ignore && slp_te[0].nreord > 0 && slp_te[0].nreuse == 0 { te_clear_reorder(0); }
}
