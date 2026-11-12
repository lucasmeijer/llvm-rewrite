// InterleavedAccessInfo (analyzeInterleaving, collectConstStrideAccesses, collectDependences,
// canReorderMemAccessesForInterleavedGroups, invalidateGroupsRequiringScalarEpilogue, invalidateGroups) and
// InterleaveGroup<Instruction>. Ported from llvm/lib/Analysis/VectorUtils.cpp and
// llvm/include/llvm/Analysis/VectorUtils.h (LLVM 23.1.5).
// One loop at a time: the groups live in globals, reset by iai_reset. A group's members sit in 2*Factor-1 slots
// indexed by key + Factor - 1 (keys stay in (-Factor, Factor) because the first member has key 0).
import std;
import ir;
import irutil;
import instinfo;
import flags;
import datalayout;
import apint;
import loopinfo;
import scev;
import scev_create;
import pse;
import laa;
import lv_legality;

struct IGroup { factor: i32, reverse: bool, align: i64, smallest: i32, largest: i32, insert_pos: i32, alive: bool, at: i32, n: i32 }
var iai_groups: IGroup[>..<];     // every group created for this loop (id = index); `alive` = in InterleaveGroups
var iai_slots: i32[>..<];
var iai_map = hm_new();           // InterleaveGroupMap: instruction -> group id
var iai_deps = hm_new();          // Dependences: (src << 32 | dst) -> 1
var iai_req_epi: bool = false;    // RequiresScalarEpilogue
var iai_l: i32 = -1;

fn iai_reset() {
    iai_groups.clear(); iai_slots.clear(); hm_clear(iai_map); hm_clear(iai_deps); iai_req_epi = false; iai_l = -1;
}

fn iai_max_factor() -> i64 { flag_int("max-interleave-group-factor", 8) }
// isStrided(Stride)
fn iai_is_strided(stride: i64) -> bool { let f = if stride < 0 { -stride } else { stride }; return f >= 2 && f <= iai_max_factor(); }

// getInterleaveGroup(I): -1 when not interleaved
fn iai_group_of(i: i32) -> i32 { hm_get(iai_map, i as u64, -1) as i32 }
fn iai_is_interleaved(i: i32) -> bool { hm_has(iai_map, i as u64) }
fn iai_requires_scalar_epilogue() -> bool { iai_req_epi }
fn iai_has_groups() -> bool { for g in iai_groups { if g.alive { return true; } } return false; }

// InterleaveGroup::getMember(Index): -1 when absent
fn ig_member(g: i32, index: i64) -> i32 {
    let gr = iai_groups[g];
    let key = gr.smallest as i64 + index;
    let f = gr.factor as i64;
    if key <= -f || key >= f { return -1; }
    return iai_slots[gr.at as i64 + key + f - 1];
}
fn ig_factor(g: i32) -> i64 { iai_groups[g].factor as i64 }
fn ig_insert_pos(g: i32) -> i32 { iai_groups[g].insert_pos }
fn ig_is_reverse(g: i32) -> bool { iai_groups[g].reverse }
fn ig_align(g: i32) -> i64 { iai_groups[g].align }
fn ig_num_members(g: i32) -> i64 { iai_groups[g].n as i64 }
fn ig_is_full(g: i32) -> bool { iai_groups[g].n == iai_groups[g].factor }
// getIndex(Instr)
fn ig_index_of(g: i32, i: i32) -> i64 {
    let gr = iai_groups[g];
    let f = gr.factor as i64;
    for s in 2 * f - 1 { if iai_slots[gr.at as i64 + s] == i { return s - (f - 1) - gr.smallest as i64; } }
    fatal("internal: InterleaveGroup contains no such member");
    return 0;
}
// requiresScalarEpilogue() of the group
fn ig_requires_scalar_epilogue(g: i32) -> bool { ig_member(g, ig_factor(g) - 1) < 0 }

// insertMember(Instr, Index, NewAlign)
fn ig_insert_member(g: i32, i: i32, index: i64, align: i64) -> bool {
    let gr = iai_groups[g];
    let key = index + gr.smallest as i64;
    if key < -0x80000000 || key > 0x7FFFFFFF { return false; }
    let f = gr.factor as i64;
    if key > -f && key < f && iai_slots[gr.at as i64 + key + f - 1] >= 0 { return false; }
    if key > gr.largest as i64 {
        if index >= f { return false; }
        iai_groups[g].largest = key as i32;
    } else if key < gr.smallest as i64 {
        if gr.largest as i64 - key >= f { return false; }
        iai_groups[g].smallest = key as i32;
    }
    if align < gr.align { iai_groups[g].align = align; }
    iai_slots[gr.at as i64 + key + f - 1] = i;
    iai_groups[g].n = gr.n + 1;
    return true;
}

// createInterleaveGroup(Instr, Stride, Alignment)
fn iai_create_group(i: i32, stride: i64, align: i64) -> i32 {
    let f = if stride < 0 { -stride } else { stride };
    let at = iai_slots.len;
    for k in 2 * f - 1 { iai_slots.push(-1); }
    iai_slots[at + f - 1] = i;
    let g = iai_groups.len as i32;
    iai_groups.push(IGroup { factor: f as i32, reverse: stride < 0, align: align, smallest: 0, largest: 0, insert_pos: i,
                             alive: true, at: at as i32, n: 1 });
    hm_put(iai_map, i as u64, g as i64);
    return g;
}
// releaseGroup(Group)
fn iai_release_group(g: i32) {
    iai_groups[g].alive = false;
    for k in ig_factor(g) { let m = ig_member(g, k); if m >= 0 { hm_del(iai_map, m as u64); } }
}

// areDependencesValid: LAI's dependence checker kept its dependence list
fn iai_deps_valid() -> bool { mdc_record }

// collectDependences
fn iai_collect_dependences() {
    if !iai_deps_valid() { return; }
    for d in mdc_deps {
        let s = mdc_inst[d.src as i64];
        let t = mdc_inst[d.dst as i64];
        hm_put(iai_deps, ((s as u64) << 32) | (t as u32 as u64), 1);
    }
}

// the StrideDescriptors of collectConstStrideAccesses, in program order
var iai_acc_i: i32[>..<];
var iai_acc_stride: i64[>..<];
var iai_acc_scev: i32[>..<];
var iai_acc_size: i64[>..<];
var iai_acc_align: i64[>..<];
fn iai_acc_index(i: i32) -> i64 { for k in iai_acc_i.len { if iai_acc_i[k] == i { return k; } } return -1; }

// canReorderMemAccessesForInterleavedGroups(A, B) with A, B indices into the stride descriptors
fn iai_can_reorder(a: i64, b: i64) -> bool {
    let src = iai_acc_i[a];
    let sink = iai_acc_i[b];
    if !inst_may_write_memory(src) { return true; }
    if !iai_is_strided(iai_acc_stride[a]) && !iai_is_strided(iai_acc_stride[b]) { return true; }
    if !iai_deps_valid() { return false; }
    return !hm_has(iai_deps, ((src as u64) << 32) | (sink as u32 as u64));
}

fn iai_ldst_align(i: i32) -> i64 { let a = insts[inst_of(i)].align; return if a == 0 { 1 } else { 1 << (a - 1) as i64 }; }

// collectConstStrideAccesses(AccessStrideInfo, Strides, Predicates)
fn iai_collect_const_stride_accesses(preds: i32[>..<]&, want_preds: bool) {
    iai_acc_i.clear(); iai_acc_stride.clear(); iai_acc_scev.clear(); iai_acc_size.clear(); iai_acc_align.clear();
    var po: i32[>..<] = [];
    lv_loop_postorder(iai_l, po);
    var bi = po.len - 1;
    while bi >= 0 {
        let bb = po[bi];
        bi--;
        var i = block_first(bb);
        while i >= 0 {
            let o = iop(i);
            if o == OP_LOAD || o == OP_STORE {
                let ptr = laa_ldst_ptr(i);
                let ety = laa_ldst_type(i);
                let size = dl_alloc_size(ety);
                if size * 8 == dl_size_bits(ety) {
                    var ps: i32[>..<] = [];
                    let ok, s = laa_get_ptr_stride(ety, ptr, iai_l, false, want_preds, ps);
                    for p in ps { preds.push(p); }
                    let stride = if ok { s } else { 0 };
                    let sc = laa_replace_symbolic_stride_scev(ptr);
                    iai_acc_i.push(i); iai_acc_stride.push(stride); iai_acc_scev.push(sc);
                    iai_acc_size.push(size); iai_acc_align.push(iai_ldst_align(i));
                }
            }
            i = inst_next(i);
        }
    }
}

fn iai_contains(xs: const i32[:], x: i32) -> bool { for y in xs { if y == x { return true; } } return false; }

// analyzeInterleaving(EnablePredicatedInterleavedMemAccesses) with the loop's PSE `pse`
fn iai_analyze_interleaving(l: i32, pse: i32, opt_for_size: bool, enable_pred: bool) {
    iai_reset();
    iai_l = l;
    let sp = lai_pse;
    lai_pse = pse;
    iai_analyze_impl(enable_pred, opt_for_size);
    lai_pse = sp;
}

fn iai_analyze_impl(enable_pred: bool, opt_for_size: bool) {
    let l = iai_l;
    var preds: i32[>..<] = [];
    iai_collect_const_stride_accesses(preds, !opt_for_size);
    if iai_acc_i.len == 0 { return; }
    iai_collect_dependences();
    var store_groups: i32[>..<] = [];
    var load_groups: i32[>..<] = [];
    var completed: i32[>..<] = [];
    fn is_pred(bb: i32) -> bool { laa_block_needs_predication(bb, l) }
    var bi = iai_acc_i.len - 1;
    while bi >= 0 {
        let b = iai_acc_i[bi];
        let sb = iai_acc_stride[bi];
        var gb: i32 = -1;
        if iai_is_strided(sb) && (!is_pred(inst_parent(b)) || enable_pred) {
            gb = iai_group_of(b);
            if gb < 0 {
                gb = iai_create_group(b, sb, iai_acc_align[bi]);
                if inst_may_write_memory(b) { store_groups.push(gb); } else { load_groups.push(gb); }
            }
        }
        var ai = bi - 1;
        while ai >= 0 {
            let a = iai_acc_i[ai];
            let cur = ai;
            ai--;
            let ga = iai_group_of(a);
            if inst_may_write_memory(a) && ga != gb {
                var dependent: i32 = -1;
                if gb >= 0 && iai_contains(load_groups, gb) {
                    for idx in ig_factor(gb) {
                        let m = ig_member(gb, idx);
                        if m >= 0 && !iai_can_reorder(cur, iai_acc_index(m)) { dependent = m; break; }
                    }
                } else if !iai_can_reorder(cur, bi) { dependent = b; }
                if dependent >= 0 {
                    if ga >= 0 && iai_contains(store_groups, ga) {
                        var keep: i32[>..<] = [];
                        for x in store_groups { if x != ga { keep.push(x); } }
                        store_groups.clear();
                        for x in keep { store_groups.push(x); }
                        iai_release_group(ga);
                    }
                    if gb >= 0 && iai_contains(load_groups, gb) && !iai_contains(completed, gb) { completed.push(gb); }
                }
            }
            if gb >= 0 && iai_contains(completed, gb) { continue; }
            let sa = iai_acc_stride[cur];
            if !iai_is_strided(sa) || !iai_is_strided(sb) { continue; }
            if iai_is_interleaved(a) || inst_may_read_memory(a) != inst_may_read_memory(b) ||
               inst_may_write_memory(a) != inst_may_write_memory(b) { continue; }
            if sa != sb || iai_acc_size[cur] != iai_acc_size[bi] { continue; }
            if types[ty_scalar(vals[laa_ldst_ptr(a)].ty)].n != types[ty_scalar(vals[laa_ldst_ptr(b)].ty)].n { continue; }
            let dist = sc_minus(iai_acc_scev[cur], iai_acc_scev[bi]);
            if !sc_is_const(dist) { continue; }
            let d = ap_sext64(sc_ap(dist));
            let size = iai_acc_size[bi];
            if d % size != 0 { continue; }
            let ba = inst_parent(a);
            let bb = inst_parent(b);
            if (is_pred(ba) || is_pred(bb)) && (!enable_pred || ba != bb) { continue; }
            // int IndexA = GroupB->getIndex(B) + DistanceToB / Size (truncated to int)
            let index_a = ((ig_index_of(gb, b) + d / size) as i32) as i64;
            if ig_insert_member(gb, a, index_a, iai_acc_align[cur]) {
                hm_put(iai_map, a as u64, gb as i64);
                if inst_may_read_memory(a) { iai_groups[gb].insert_pos = a; }
            }
        }
        bi--;
    }
    if load_groups.len != 0 || store_groups.len != 0 { pse_add_predicates(lai_pse, preds); }
    fn may_wrap(g: i32, index: i64) -> bool {
        let m = ig_member(g, index);
        if m < 0 { fatal("internal: interleave group member does not exist"); }
        let ok, s = laa_get_ptr_stride_assume(laa_ldst_type(m), laa_ldst_ptr(m), l, false, true);
        if ok && s != 0 { return false; }
        iai_release_group(g);
        return true;
    }
    for g in load_groups {
        if !iai_groups[g].alive { continue; }
        if ig_is_full(g) { continue; }
        if may_wrap(g, 0) { continue; }
        if ig_member(g, ig_factor(g) - 1) >= 0 { let r = may_wrap(g, ig_factor(g) - 1); }
        else {
            if ig_is_reverse(g) { iai_release_group(g); continue; }
            iai_req_epi = true;
        }
    }
    for g in store_groups {
        if !iai_groups[g].alive { continue; }
        if ig_is_full(g) { continue; }
        if !enable_pred { iai_release_group(g); continue; }
        if may_wrap(g, 0) { continue; }
        var k = ig_factor(g) - 1;
        while k > 0 {
            if ig_member(g, k) >= 0 { let r = may_wrap(g, k); break; }
            k--;
        }
    }
}

// invalidateGroupsRequiringScalarEpilogue
fn iai_invalidate_groups_requiring_scalar_epilogue() {
    if !iai_req_epi { return; }
    var released = false;
    for g in iai_groups.len {
        let gi = g as i32;
        if !iai_groups[gi].alive || !ig_requires_scalar_epilogue(gi) { continue; }
        iai_release_group(gi);
        released = true;
    }
    if !released { fatal("internal: At least one group must be invalidated, as a scalar epilogue was required"); }
    iai_req_epi = false;
}
// invalidateGroups
fn iai_invalidate_groups() -> bool {
    if !iai_has_groups() { return false; }
    for g in iai_groups.len { iai_groups[g].alive = false; }
    hm_clear(iai_map);
    iai_req_epi = false;
    return true;
}
