// LoopDistribute: port of llvm/lib/Transforms/Scalar/LoopDistribute.cpp (whole; the optimization remarks are not
// emitted), with makeFollowupLoopID / addStringMetadataToLoop / getOptionalBoolLoopAttribute
// (llvm/lib/Transforms/Utils/LoopUtils.cpp, llvm/lib/Analysis/LoopInfo.cpp) and Loop::setLoopID.
// Partitions (InstPartition) are records in ld_parts; the std::list order is ld_list; each partition's
// SmallSetVector is a linked list of pool entries (ld_set_*), its VMap is loop_versioning.goose's VMap 1 + id.
import std;
import ir;
import irutil;
import instinfo;
import analyses;
import flags;
import domtree;
import loopinfo;
import loopsimplify;
import lcssa;
import salvage;
import aa;
import tli;
import scev;
import scev_create;
import scev_lt;
import pse;
import laa;
import loop_utils;
import loop_versioning;

struct LdPart { head: i32, tail: i32, n: i32, cycle: bool, cloned: i32, blk_at: i32, blk_n: i32 }
var ld_parts: LdPart[>..<];
var ld_list: i32[>..<];
var ld_set_inst: i32[>..<];
var ld_set_next: i32[>..<];
var ld_set_map = hm_new();       // (part, inst) -> pool entry
var ld_blocks: i32[>..<];        // ClonedLoopBlocks runs
var ld_l: i32 = -1;
var ld_fv: i32 = -1;
var ld_inst_part = hm_new();     // InstToPartitionId (missing = 0, as operator[] inserts)

fn ld_key(p: i32, i: i32) -> u64 { ((p as u64) << 32) | (i as u64) }
fn ld_has(p: i32, i: i32) -> bool { hm_get(ld_set_map, ld_key(p, i), -1) >= 0 }
// SmallSetVector::insert
fn ld_insert(p: i32, i: i32) -> bool {
    if ld_has(p, i) { return false; }
    ld_set_inst.push(i);
    ld_set_next.push(-1);
    let e = (ld_set_inst.len - 1) as i32;
    if ld_parts[p].tail >= 0 { ld_set_next[ld_parts[p].tail] = e; } else { ld_parts[p].head = e; }
    ld_parts[p].tail = e;
    ld_parts[p].n += 1;
    hm_put(ld_set_map, ld_key(p, i), e as i64);
    return true;
}
fn ld_members(p: i32, out: i32[>..<]&) {
    out.clear();
    var e = ld_parts[p].head;
    while e >= 0 { out.push(ld_set_inst[e]); e = ld_set_next[e]; }
}
// InstPartition(I, L, DepCycle)
fn ld_new_part(i: i32, cycle: bool) -> i32 {
    ld_parts.push(LdPart { head: -1, tail: -1, n: 0, cycle: cycle, cloned: -1, blk_at: 0, blk_n: 0 });
    let p = (ld_parts.len - 1) as i32;
    ld_insert(p, i);
    return p;
}
// moveTo(Other)
fn ld_move_to(p: i32, other: i32) {
    var ms: i32[>..<] = [];
    ld_members(p, ms);
    for i in ms { ld_insert(other, i); }
    for i in ms { hm_del(ld_set_map, ld_key(p, i)); }
    ld_parts[p].head = -1; ld_parts[p].tail = -1; ld_parts[p].n = 0;
    if ld_parts[p].cycle { ld_parts[other].cycle = true; }
}

// addToCyclicPartition / addToNewNonCyclicPartition
fn ld_add_to_cyclic(i: i32) {
    if ld_list.len == 0 || !ld_parts[ld_list[ld_list.len - 1]].cycle { ld_list.push(ld_new_part(i, true)); }
    else { ld_insert(ld_list[ld_list.len - 1], i); }
}
fn ld_add_to_new_noncyclic(i: i32) { ld_list.push(ld_new_part(i, false)); }

// mergeAdjacentPartitionsIf: kind 0 = !hasDepCycle, 1 = the non-if-convertible predicate
fn ld_pred(p: i32, kind: i64) -> bool {
    if kind == 0 { return !ld_parts[p].cycle; }
    if ld_parts[p].cycle { return true; }
    var seen_store = false;
    var ms: i32[>..<] = [];
    ld_members(p, ms);
    for i in ms {
        if iop(i) == OP_STORE {
            seen_store = true;
            if !laa_block_needs_predication(inst_parent(i), ld_l) { return false; }
        }
    }
    return seen_store;
}
fn ld_merge_adjacent_if(kind: i64) {
    var prev: i32 = -1;
    var k: i64 = 0;
    while k < ld_list.len {
        let p = ld_list[k];
        let m = ld_pred(p, kind);
        if prev < 0 && m { prev = p; k++; }
        else if prev >= 0 && m {
            ld_move_to(p, prev);
            ld_list_erase(k);
        } else { prev = -1; k++; }
    }
}
fn ld_list_erase(k: i64) {
    var j = k;
    while j + 1 < ld_list.len { ld_list[j] = ld_list[j + 1]; j++; }
    ld_list.pop();
}

// populateUsedSet (per partition)
fn ld_populate_used_set(p: i32) {
    for k in loop_nblocks(ld_l) { ld_insert(p, block_terminator(loop_block(ld_l, k))); }
    var wl: i32[>..<] = [];
    ld_members(p, wl);
    while wl.len > 0 {
        let i = wl.pop();
        for k in nops(i) {
            let v = op(i, k);
            if v >= 0 && is_inst(v) && loop_contains(ld_l, inst_parent(v)) && ld_insert(p, v) { wl.push(v); }
        }
    }
}

// mergeToAvoidDuplicatedLoads
fn ld_merge_to_avoid_duplicated_loads() -> bool {
    var lk: i32[>..<] = [];     // LoadToPartition
    var lv: i32[>..<] = [];
    // ToBeMerged: EquivalenceClasses<InstPartition *> (members in insertion order; union appends)
    var ec_val: i32[>..<] = [];
    var ec_leader: i32[>..<] = [];
    var ec_next: i32[>..<] = [];
    var ec_tail: i32[>..<] = [];
    for k in ld_list.len {
        let pi = ld_list[k];
        var ms: i32[>..<] = [];
        ld_members(pi, ms);
        for inst in ms {
            if iop(inst) != OP_LOAD { continue; }
            var f: i64 = -1;
            for j in lk.len { if lk[j] == inst { f = j; } }
            if f < 0 { lk.push(inst); lv.push(pi); continue; }
            var j = k;
            loop {
                j--;
                let pj = ld_list[j];
                // unionSets(PartI, PartJ)
                var n1: i64 = -1; var n2: i64 = -1;
                for x in ec_val.len { if ec_val[x] == pi { n1 = x; } }
                if n1 < 0 { ec_val.push(pi); ec_leader.push(ec_val.len as i32 - 1); ec_next.push(-1); ec_tail.push(ec_val.len as i32 - 1); n1 = ec_val.len - 1; }
                for x in ec_val.len { if ec_val[x] == pj { n2 = x; } }
                if n2 < 0 { ec_val.push(pj); ec_leader.push(ec_val.len as i32 - 1); ec_next.push(-1); ec_tail.push(ec_val.len as i32 - 1); n2 = ec_val.len - 1; }
                let l1 = ec_leader[n1];
                let l2 = ec_leader[n2];
                if l1 != l2 {
                    ec_next[ec_tail[l1]] = l2;
                    ec_tail[l1] = ec_tail[l2];
                    var x = l2;
                    while x >= 0 { ec_leader[x] = l1; x = ec_next[x]; }
                }
                if pj == lv[f] { break; }
            }
        }
    }
    if ec_val.len == 0 { return false; }
    for c in ec_val.len {
        if ec_leader[c] != c as i32 { continue; }
        let pi = ec_val[c];
        var x = ec_next[c];
        while x >= 0 { ld_move_to(ec_val[x], pi); x = ec_next[x]; }
    }
    var w: i64 = 0;
    for k in ld_list.len { if ld_parts[ld_list[k]].n > 0 { ld_list[w] = ld_list[k]; w++; } }
    ld_list.resize(w);
    return true;
}

// setupPartitionIdOnInstructions
fn ld_setup_partition_ids() {
    hm_clear(ld_inst_part);
    for k in ld_list.len {
        var ms: i32[>..<] = [];
        ld_members(ld_list[k], ms);
        for i in ms {
            let c = hm_get(ld_inst_part, i as u64, -100);
            if c == -100 { hm_put(ld_inst_part, i as u64, k); } else { hm_put(ld_inst_part, i as u64, -1); }
        }
    }
}
fn ld_part_id(i: i32) -> i64 { let c = hm_get(ld_inst_part, i as u64, -100); if c == -100 { 0 } else { c } }

// computePartitionSetForPointers(LAI)
fn ld_partition_set_for_pointers(out: i64[>..<]&) {
    out.clear();
    for i in rpc_ptrs.len {
        let p = rpc_ptrs[i].ptr;
        var insts_: i64[>..<] = [];
        mdc_accesses_of(mai(p, true), insts_);
        var rd: i64[>..<] = [];
        mdc_accesses_of(mai(p, false), rd);
        for x in rd { insts_.push(x); }
        var part: i64 = -2;
        for x in insts_ {
            let t = ld_part_id(mdc_inst[x]);
            if part == -2 { part = t; }
            else if part == -1 { break; }
            else if part != t { part = -1; }
        }
        out.push(part);
    }
}

// makeFollowupLoopID(OrigLoopID, FollowupOptions, InheritOptionsExceptPrefix, AlwaysNew): -2 = std::nullopt,
// -1 = nullptr
fn ld_make_followup_loop_id(orig: i32, opts: const u8[:][:], prefix: const u8[:], has_prefix: bool, always_new: bool) -> i32 {
    if orig < 0 { return if always_new { -1 } else { -2 }; }
    let inherit_all = !has_prefix;
    let inherit_some = has_prefix && prefix.len > 0;
    var ops: i32[>..<] = [];
    ops.push(-1);
    var changed = false;
    if inherit_all || inherit_some {
        for k in 1..mds[orig].nops as i64 {
            let o = md_op(orig, k);
            var inherit = false;
            if inherit_some {
                if mds[o].nops == 0 { inherit = true; }
                else {
                    let nm = md_op(o, 0);
                    if nm < 0 || mds[nm].kind != MK_STRING { inherit = true; }
                    else { inherit = !starts_with(sbytes(mds[nm].extra), prefix); }
                }
            }
            if inherit { ops.push(o); } else { changed = true; }
        }
    } else { changed = mds[orig].nops > 1; }
    var any = false;
    for name in opts {
        let f = find_option_md_for_loop_id(orig, name);
        if f < 0 { continue; }
        any = true;
        for k in 1..mds[f].nops as i64 { ops.push(md_op(f, k)); changed = true; }
    }
    if !always_new && !any { return -2; }
    if !always_new && !changed { return orig; }
    if ops.len == 1 { return -1; }
    let r = md_get(MK_TUPLE, -1, ops, true);
    md_ops[mds[r].ops] = r;
    return r;
}
// Loop::setLoopID(LoopID)
fn ld_set_loop_id(l: i32, id: i32) {
    let h = loop_header(l);
    for k in loop_nblocks(l) {
        let t = block_terminator(loop_block(l, k));
        for j in term_nsucc(t) {
            if term_succ(t, j) == h {
                if id >= 0 { inst_set_md(t, MDK_LOOP, id); } else { inst_erase_md(t, MDK_LOOP); }
                break;
            }
        }
    }
}
// addStringMetadataToLoop(L, Name, V)
fn ld_add_string_metadata_to_loop(l: i32, name: const u8[:], v: i64) {
    var ops: i32[>..<] = [];
    ops.push(-1);
    let lid = loop_id(l);
    if lid >= 0 {
        for k in 1..mds[lid].nops as i64 {
            let n = md_op(lid, k);
            if mds[n].nops == 2 {
                let s = md_op(n, 0);
                if s >= 0 && mds[s].kind == MK_STRING && sbytes(mds[s].extra) == name {
                    let c = md_op(n, 1);
                    if c >= 0 && mds[c].kind == MK_VALUE && is_cint(mds[c].extra) && cint_sext(mds[c].extra) == v { return; }
                    continue;
                }
            }
            ops.push(n);
        }
    }
    let pair: i32[2] = [md_string(name), md_value(c_int(T_I32, v))];
    ops.push(md_get(MK_TUPLE, -1, pair, false));
    let r = md_get(MK_TUPLE, -1, ops, true);
    md_ops[mds[r].ops] = r;
    ld_set_loop_id(l, r);
}

// the partition's distributed loop
fn ld_dist_loop(p: i32) -> i32 { if ld_parts[p].cloned >= 0 { ld_parts[p].cloned } else { ld_l } }

// setNewLoopID(OrigLoopID, Part)
fn ld_set_new_loop_id(orig: i32, p: i32) {
    let o2: const u8[:] = if ld_parts[p].cycle { "llvm.loop.distribute.followup_sequential" } else { "llvm.loop.distribute.followup_coincident" };
    let opts: const u8[:][2] = ["llvm.loop.distribute.followup_all", o2];
    let id = ld_make_followup_loop_id(orig, opts, "", false, false);
    if id != -2 { ld_set_loop_id(ld_dist_loop(p), id); }
}

// cloneLoops
fn ld_clone_loops() {
    let oph = loop_preheader(ld_l);
    let pred = single_pred(oph);
    let exit = lver_exit_block(ld_l);
    let orig_id = loop_id(ld_l);
    var top_ph = oph;
    var index = ld_list.len - 1;
    var k = ld_list.len - 2;
    while k >= 0 {
        let p = ld_list[k];
        lver_vmap_cur = 1 + p;
        var nm: u8[>..] = [];
        nm.append(".ldist");
        laa_fmt_u64(nm, index as u64);
        var bs: i32[>..<] = [];
        let nl = lver_clone_loop_with_preheader(top_ph, pred, ld_l, nm, bs);
        ld_parts[p].cloned = nl;
        ld_parts[p].blk_at = ld_blocks.len as i32;
        ld_parts[p].blk_n = bs.len as i32;
        for b in bs { ld_blocks.push(b); }
        lver_map_set(exit, top_ph);
        lver_remap_blocks(bs);
        ld_set_new_loop_id(orig_id, p);
        index--;
        top_ph = loop_preheader(nl);
        k--;
    }
    lver_vmap_cur = 0;
    let pt = block_terminator(pred);
    for j in nops(pt) { if op(pt, j) == oph { set_op(pt, j, top_ph); } }
    ld_set_new_loop_id(orig_id, ld_list[ld_list.len - 1]);
    for c in ld_list.len - 1 {
        let cur = ld_list[c];
        let nx = ld_list[c + 1];
        dt_change_idom(ld_fv, DT_DOM, loop_preheader(ld_dist_loop(nx)), loop_exiting_block(ld_dist_loop(cur)));
    }
}

// removeUnusedInsts
fn ld_remove_unused_insts() {
    for p in ld_list {
        lver_vmap_cur = 1 + p;
        let empty = lver_map_empty();
        var unused: i32[>..<] = [];
        for k in loop_nblocks(ld_l) {
            var i = block_first(loop_block(ld_l, k));
            while i >= 0 {
                if !ld_has(p, i) { unused.push(if empty { i } else { lver_map(i) }); }
                i = inst_next(i);
            }
        }
        var j = unused.len - 1;
        while j >= 0 {
            let i = unused[j];
            salvage_debug_info(i);
            if vals[i].first_use >= 0 { rauw(i, c_poison(vals[i].ty)); }
            inst_erase_from_parent(i);
            j--;
        }
    }
    lver_vmap_cur = 0;
}

// fail(RemarkName, Message): a forced distribution reports DiagnosticInfoOptimizationFailure (a warning)
fn ld_fail(forced: bool) -> bool {
    if forced { write_stderr("warning: loop not distributed: failed explicitly specified loop distribution\n"); }
    return false;
}

// processLoop
fn ld_process_loop(l: i32, forced: bool, has_forced: bool) -> bool {
    ld_l = l;
    ld_parts.clear(); ld_list.clear(); ld_set_inst.clear(); ld_set_next.clear(); hm_clear(ld_set_map); ld_blocks.clear();
    if lver_exit_block(l) < 0 { return ld_fail(forced); }
    if !loop_is_simplify_form(l) { return ld_fail(forced); }
    if !lver_is_rotated_form(l) { return ld_fail(forced); }
    var ph = loop_preheader(l);
    lai_compute(l, false);
    if lai_can_vec_mem { return ld_fail(forced); }
    if !mdc_record || mdc_deps.len == 0 { return ld_fail(forced); }
    // MemoryInstructionDependences
    var cnt: i64[>..<] = [];
    for k in mdc_inst.len { cnt.push(0); }
    for d in mdc_deps {
        if dep_is_possibly_backward(d.ty as i64) { cnt[d.src] += 1; cnt[d.dst] -= 1; }
    }
    var active: i64 = 0;
    for k in mdc_inst.len {
        let i = mdc_inst[k];
        if active != 0 || cnt[k] > 0 { ld_add_to_cyclic(i); } else { ld_add_to_new_noncyclic(i); }
        active += cnt[k];
    }
    var defs: i32[>..<] = [];
    lver_defs_used_outside(l, defs);
    for i in defs { ld_add_to_new_noncyclic(i); }
    if ld_list.len < 2 { return ld_fail(forced); }
    // mergeBeforePopulating
    ld_merge_adjacent_if(0);
    if !flag_bool("loop-distribute-non-if-convertible", false) { ld_merge_adjacent_if(1); }
    if ld_list.len < 2 { return ld_fail(forced); }
    for p in ld_list { ld_populate_used_set(p); }
    if ld_merge_to_avoid_duplicated_loads() {
        if ld_list.len < 2 { return ld_fail(forced); }
    }
    let u = pse_union(lai_pse);
    if lai_has_convergent && !su_always_true(u) { return ld_fail(forced); }
    let thr = if forced { flag_int("loop-distribute-scev-check-threshold-with-pragma", 128) } else { flag_int("loop-distribute-scev-check-threshold", 8) };
    if su_n(u) > thr { return ld_fail(forced); }
    if !forced && lu_boolean_loop_attr(l, "llvm.loop.disable_nonforced") { return ld_fail(forced); }
    ld_setup_partition_ids();
    var p2p: i64[>..<] = [];
    ld_partition_set_for_pointers(p2p);
    // includeOnlyCrossPartitionChecks
    var checks: i64[>..<] = [];
    for c in rpc_checks {
        let g1 = rpc_groups[c / 4294967296];
        let g2 = rpc_groups[c % 4294967296];
        var need = false;
        for a in g1.n as i64 {
            for b in g2.n as i64 {
                let i1 = rpc_gmem[(g1.at as i64) + a];
                let i2 = rpc_gmem[(g2.at as i64) + b];
                let same = p2p[i1] != -1 && p2p[i1] == p2p[i2];
                if rpc_needs_checking_ptrs(i1, i2) && !same { need = true; }
            }
        }
        if need { checks.push(c); }
    }
    if lai_has_convergent && checks.len != 0 { return ld_fail(forced); }
    if single_pred(ph) < 0 || block_first(ph) != block_terminator(ph) {
        lu_split_block(ph, block_terminator(ph), false);
    }
    if !su_always_true(u) || checks.len != 0 {
        let orig_id = loop_id(l);
        if !lver_is_lcssa_form(l) { let s = lcssa_se; lcssa_se = true; form_lcssa_recursively(l); lcssa_se = s; }
        lver_init(l, checks);
        lver_version_loop(defs);
        lver_annotate_loop_with_noalias();
        let opts: const u8[:][2] = ["llvm.loop.distribute.followup_all", "llvm.loop.distribute.followup_fallback"];
        let uid = ld_make_followup_loop_id(orig_id, opts, "llvm.loop.distribute.", true, true);
        ld_set_loop_id(lver_nl, uid);
        ld_add_string_metadata_to_loop(lver_nl, "llvm.loop.isdistributed", 1);
    }
    ld_clone_loops();
    ld_remove_unused_insts();
    let unused = has_forced;
    return true;
}

// getOptionalBoolLoopAttribute(L, Name): 0 = false, 1 = true, -1 = std::nullopt
fn ld_optional_bool_loop_attr(l: i32, name: const u8[:]) -> i64 {
    let md = find_option_md_for_loop_id(loop_id(l), name);
    if md < 0 { return -1; }
    if mds[md].nops == 1 { return 1; }
    if mds[md].nops == 2 {
        let o = md_op(md, 1);
        if o >= 0 && mds[o].kind == MK_VALUE && is_cint(mds[o].extra) { return if cint_is_zero(mds[o].extra) { 0 } else { 1 }; }
    }
    return -1;
}

// LoopDistributePass::run / runImpl
fn loop_distribute_run(fv: i32) -> u32 {
    ld_fv = fv;
    li_get(fv);
    dt_get(fv, DT_DOM);
    scev_get(fv);
    aa_begin(fv);
    tli_cur_fn = fv;
    var wl: i32[>..<] = [];
    lver_innermost_preorder(fv, wl);
    var changed = false;
    let enable = flag_bool("enable-loop-distribute", false);
    for l in wl {
        // setForced: llvm.loop.distribute.enable
        var has_forced = false;
        var forced = false;
        let md = find_option_md_for_loop_id(loop_id(l), "llvm.loop.distribute.enable");
        if md >= 0 && mds[md].nops >= 2 {
            let o = md_op(md, 1);
            if o >= 0 && mds[o].kind == MK_VALUE && is_cint(mds[o].extra) { has_forced = true; forced = !cint_is_zero(mds[o].extra); }
        }
        if ld_optional_bool_loop_attr(l, "llvm.loop.isdistributed") == 1 { continue; }
        let run = if has_forced { forced } else { enable };
        if run { if ld_process_loop(l, has_forced && forced, has_forced) { changed = true; } }
    }
    pse_reset();
    if !changed { return PA_ALL; }
    return ((1 as u32) << A_LOOPS) | ((1 as u32) << A_DOMTREE);
}
