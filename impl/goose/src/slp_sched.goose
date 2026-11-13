// SLPVectorizer: BoUpSLP::BlockScheduling. Port of llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp's
// ScheduleEntity / ScheduleData / ScheduleBundle / ScheduleCopyableData classes and BlockScheduling (class body
// around lines 5000-6460: clear, getScheduleData, getScheduleCopyableData*, areAllOperandsReplacedByCopyableData,
// addScheduleCopyableData, getScheduleBundles, isInSchedulingRegion, schedule, initialFillReadyList; out of line
// 25642-26675: buildBundle, tryScheduleBundle, extendSchedulingRegion, initScheduleData, calculateDependencies,
// resetSchedule) and BoUpSLP::isAliased.
//
// Entities: a ScheduleData or a ScheduleCopyableData is its id (>= 0) in `slp_sd` (a copyable row has `cd` set and
// is never in ScheduleDataMap), a ScheduleBundle is -(id + 1) of `slp_sb`. A block's ReadyInsts (a SetVector) is the
// subsequence of `slp_ready` with its block-scheduling id. The four copyable-data maps are global hash-table slots
// (SH_CD*) whose rows carry their block scheduling `bs`; every read filters by it (and by the region, as LLVM's
// isInSchedulingRegion does). An erased copyable row gets region 0, so no region query sees it again.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import pm;
import flags;
import speculate;
import vt;
import memloc;
import aa;
import laa;
import vecutils;
import slp_util;
import slp_tree;

struct SBS { bb: i32, start: i32, end: i32, first_ls: i32, last_ls: i32, stack_save: bool, region_size: i64,
             region_limit: i64, region_id: i32, cd_n: i64 }
// a ScheduleData, or (cd) a ScheduleCopyableData of edge (ei_te, ei_edge) in bundle cb
struct SSD { inst: i32, next_ls: i32, region: i32, deps: i32, unsched: i32, sched: bool,
             mem_h: i32, mem_t: i32, ctl_h: i32, ctl_t: i32, cd: bool, ei_te: i32, ei_edge: i64, cb: i32, bs: i32, prio: i32 }
struct SSB { m_at: i32, m_n: i32, te: i32, sched: bool, bs: i32, prio: i32 }
struct SReady { bs: i32, ent: i32, alive: bool }
var slp_bs: SBS[>..];            // BlocksSchedules (MapVector order = creation order)
var slp_sd: SSD[>..];
var slp_sb: SSB[>..];
var slp_sbm: i32[>..];           // bundle members (schedule data ids)
var slp_dl: SLk[>..];            // memory / control dependency lists
var slp_ready: SReady[>..<];
var slp_ready_alive: i64 = 0;
var slp_recalc: SReady[>..<];    // RecalcCopyableOperandDeps (a SetVector per block): (bs, schedule data)
var slp_aaq: i32 = -1;           // BatchAA's query info
let SLP_INVALID_DEPS: i32 = -1;

fn slp_sched_function_begin() {
    slp_bs.clear();
    slp_sd.clear();
    slp_sb.clear();
    slp_sbm.clear();
    slp_dl.clear();
    slp_ready.clear();
    slp_ready_alive = 0;
    slp_recalc.clear();
}
fn slp_schedule_budget() -> i64 { flag_int("slp-schedule-budget", 100000) }

// BlockScheduling::clear() for every block of BlocksSchedules (deleteTree)
fn slp_sched_clear_all() {
    sh_clear(SH_SBUN);
    sh_clear(SH_READY);
    sh_clear(SH_CDMAP); sh_clear(SH_CDINST); sh_clear(SH_CDIU); sh_clear(SH_CDUSERS);
    slp_ready.clear();
    slp_ready_alive = 0;
    slp_recalc.clear();
    slp_sb.clear();
    slp_sbm.clear();
    for b in slp_bs.len {
        slp_bs[b].start = -1;
        slp_bs[b].end = -1;
        slp_bs[b].first_ls = -1;
        slp_bs[b].last_ls = -1;
        slp_bs[b].stack_save = false;
        slp_bs[b].region_limit -= slp_bs[b].region_size;
        if slp_bs[b].region_limit < 16 { slp_bs[b].region_limit = 16; }
        slp_bs[b].region_size = 0;
        slp_bs[b].region_id += 1;
        slp_bs[b].cd_n = 0;
    }
}
// BlocksSchedules[BB] (created on first use)
fn slp_get_bs(bb: i32) -> i32 {
    let b = sh_get(SH_BSMAP, bb as i64, 0, -1) as i32;
    if b >= 0 { return b; }
    let n = slp_bs.len as i32;
    slp_bs.push(SBS { bb: bb, start: -1, end: -1, first_ls: -1, last_ls: -1, stack_save: false, region_size: 0,
                      region_limit: slp_schedule_budget(), region_id: 1, cd_n: 0 });
    sh_set(SH_BSMAP, bb as i64, 0, n as i64);
    return n;
}
fn slp_bs_of_block(bb: i32) -> i32 { sh_get(SH_BSMAP, bb as i64, 0, -1) as i32 }

// ---------------------------------------------------------------- entities
fn sd_in_region(bs: i32, sd: i32) -> bool { slp_sd[sd].region == slp_bs[bs].region_id }
// getScheduleData(I): -1 = none
fn slp_get_sd(bs: i32, v: i32) -> i32 {
    if !is_inst(v) { return -1; }
    if slp_bs[bs].bb != inst_parent(v) { return -1; }
    let sd = sh_get(SH_SDMAP, v as i64, 0, -1) as i32;
    if sd >= 0 && sd_in_region(bs, sd) { return sd; }
    return -1;
}
fn sd_valid_deps(sd: i32) -> bool { slp_sd[sd].deps != SLP_INVALID_DEPS }
fn sd_is_ready(sd: i32) -> bool { slp_sd[sd].unsched == 0 && !slp_sd[sd].sched }
fn sd_incr_unsched(sd: i32, x: i32) -> i32 { slp_sd[sd].unsched += x; return slp_sd[sd].unsched; }
fn sd_reset_unsched(sd: i32) { slp_sd[sd].unsched = slp_sd[sd].deps; }
fn sd_clear_direct_deps(sd: i32) { slp_sd[sd].deps = SLP_INVALID_DEPS; sd_reset_unsched(sd); slp_sd[sd].sched = false; }
fn sd_clear_deps(sd: i32) {
    sd_clear_direct_deps(sd);
    slp_sd[sd].mem_h = -1; slp_sd[sd].mem_t = -1;
    slp_sd[sd].ctl_h = -1; slp_sd[sd].ctl_t = -1;
}
fn sd_add_dep(sd: i32, ctl: bool, d: i32) {
    let n = slp_dl.len as i32;
    slp_dl.push(SLk { x: d, next: -1 });
    if ctl {
        if slp_sd[sd].ctl_t >= 0 { slp_dl[slp_sd[sd].ctl_t].next = n; } else { slp_sd[sd].ctl_h = n; }
        slp_sd[sd].ctl_t = n;
    } else {
        if slp_sd[sd].mem_t >= 0 { slp_dl[slp_sd[sd].mem_t].next = n; } else { slp_sd[sd].mem_h = n; }
        slp_sd[sd].mem_t = n;
    }
}
fn sb_member(b: i32, k: i64) -> i32 { slp_sbm[slp_sb[b].m_at as i64 + k] }
fn sb_n(b: i32) -> i64 { slp_sb[b].m_n as i64 }
fn slp_sb_set_tree_entry(b: i32, te: i32) { slp_sb[b].te = te; }
// ScheduleBundle::unscheduledDepsInBundle
fn sb_unsched(b: i32) -> i32 {
    var sum: i32 = 0;
    for k in sb_n(b) {
        let u = slp_sd[sb_member(b, k)].unsched;
        if u == SLP_INVALID_DEPS { return SLP_INVALID_DEPS; }
        sum += u;
    }
    return sum;
}
fn sb_valid_deps(b: i32) -> bool { for k in sb_n(b) { if !sd_valid_deps(sb_member(b, k)) { return false; } } return true; }
fn sb_is_ready(b: i32) -> bool { sb_unsched(b) == 0 && !slp_sb[b].sched }
fn ent_is_bundle(e: i32) -> bool { e < 0 }
fn ent_bundle(e: i32) -> i32 { -(e + 1) }
fn ent_of_bundle(b: i32) -> i32 { -(b + 1) }
fn ent_is_ready(e: i32) -> bool { if ent_is_bundle(e) { sb_is_ready(ent_bundle(e)) } else { sd_is_ready(e) } }
fn ent_valid_deps(e: i32) -> bool { if ent_is_bundle(e) { sb_valid_deps(ent_bundle(e)) } else { sd_valid_deps(e) } }
fn sb_in_region(bs: i32, b: i32) -> bool { for k in sb_n(b) { if !sd_in_region(bs, sb_member(b, k)) { return false; } } return true; }
// getScheduleBundles(V): the head of the inst's bundle list
fn slp_bundles_head(v: i32) -> i32 { if !is_inst(v) { return -1; } return slp_lk_head(SH_SBUN, v as i64); }
fn slp_dbg_ent(e: i32) {
    if ent_is_bundle(e) {
        let b = ent_bundle(e);
        errs("[");
        for k in sb_n(b) {
            if k > 0 { errs(", "); }
            if slp_sd[sb_member(b, k)].cd { errs("<Copyable>"); }
            slp_dv(slp_sd[sb_member(b, k)].inst);
        }
        errs("]");
    } else {
        if slp_sd[e].cd { errs("[Copyable]"); }
        slp_dv(slp_sd[e].inst);
    }
}

// ---------------------------------------------------------------- copyable data (ScheduleCopyableData maps)
// link lists in slp_lk keyed (slot, a, b)
fn cd_lk_head(slot: i64, a: i64, b: i64) -> i32 { sh_get(slot, a, b, -1) as i32 }
fn cd_lk_push(slot: i64, a: i64, b: i64, x: i32) {
    let h = cd_lk_head(slot, a, b);
    let n = slp_lk.len as i32;
    slp_lk.push(SLk { x: x, next: -1 });
    if h < 0 { sh_set(slot, a, b, n as i64); return; }
    var c = h;
    while slp_lk[c].next >= 0 { c = slp_lk[c].next; }
    slp_lk[c].next = n;
}
fn cd_lk_contains(slot: i64, a: i64, b: i64, x: i32) -> bool {
    var c = cd_lk_head(slot, a, b);
    while c >= 0 { if slp_lk[c].x == x { return true; } c = slp_lk[c].next; }
    return false;
}
// SetVector::remove
fn cd_lk_remove(slot: i64, a: i64, b: i64, x: i32) {
    var prev: i32 = -1;
    var c = cd_lk_head(slot, a, b);
    while c >= 0 {
        if slp_lk[c].x == x {
            if prev < 0 { sh_set(slot, a, b, slp_lk[c].next as i64); } else { slp_lk[prev].next = slp_lk[c].next; }
            return;
        }
        prev = c;
        c = slp_lk[c].next;
    }
}
// SetVector::insert
fn cd_lk_insert(slot: i64, a: i64, b: i64, x: i32) { if !cd_lk_contains(slot, a, b, x) { cd_lk_push(slot, a, b, x); } }
// pop_back of this block's list: removes the last element of block `bs`; -1 = empty
fn cd_lk_pop_back_bs(slot: i64, a: i64, b: i64, bs: i32) -> i32 {
    var prev: i32 = -1;
    var lastp: i32 = -2;
    var last: i32 = -1;
    var c = cd_lk_head(slot, a, b);
    while c >= 0 {
        if slp_sd[slp_lk[c].x].bs == bs { last = c; lastp = prev; }
        prev = c;
        c = slp_lk[c].next;
    }
    if last < 0 { return -1; }
    if lastp < 0 { sh_set(slot, a, b, slp_lk[last].next as i64); } else { slp_lk[lastp].next = slp_lk[last].next; }
    return slp_lk[last].x;
}
// the elements of a list that are live copyable data of block bs (in its scheduling region)
fn cd_lk_live(slot: i64, a: i64, b: i64, bs: i32, out: i32[>..<]&) {
    out.clear();
    var c = cd_lk_head(slot, a, b);
    while c >= 0 {
        let x = slp_lk[c].x;
        c = slp_lk[c].next;
        if cd_alive(bs, x) { out.push(x); }
    }
}
fn cd_alive(bs: i32, cd: i32) -> bool { slp_sd[cd].bs == bs && slp_sd[cd].region == slp_bs[bs].region_id }
fn cd_ei_key(te: i32, edge: i64) -> i64 {
    if edge >= 16777215 || edge < -1 { fatal("internal: SLP: operand index too large for the copyable-data key"); }
    return (((te + 1) as i64) << 24) | (edge + 1);
}
fn cd_iu_key(user: i32, opidx: i64) -> i64 {
    if opidx >= 1048576 || opidx < 0 { fatal("internal: SLP: operand index too large for the copyable-data key"); }
    return ((user as i64) << 20) | opidx;
}
// getScheduleCopyableData(EI, V): -1 = none
fn slp_get_cd(bs: i32, te: i32, edge: i64, v: i32) -> i32 {
    if slp_bs[bs].cd_n == 0 { return -1; }
    let cd = sh_get(SH_CDMAP, cd_ei_key(te, edge), v as i64, -1) as i32;
    if cd < 0 || slp_sd[cd].bs != bs || !cd_alive(bs, cd) { return -1; }
    return cd;
}
// getScheduleCopyableData(User, OperandIdx, V)
fn slp_cds_of_user_op(bs: i32, user: i32, opidx: i64, v: i32, out: i32[>..<]&) {
    cd_lk_live(SH_CDIU, cd_iu_key(user, opidx), v as i64, bs, out);
}
// getScheduleCopyableData(I)
fn slp_cds_of_inst(bs: i32, i: i32, out: i32[>..<]&) { cd_lk_live(SH_CDINST, i as i64, 0, bs, out); }
fn slp_has_cds_of_inst(bs: i32, i: i32) -> bool {
    var c = cd_lk_head(SH_CDINST, i as i64, 0);
    while c >= 0 { if cd_alive(bs, slp_lk[c].x) { return true; } c = slp_lk[c].next; }
    return false;
}
// getScheduleCopyableDataUsers(User)
fn slp_cd_users(bs: i32, i: i32, out: i32[>..<]&) { cd_lk_live(SH_CDUSERS, i as i64, 0, bs, out); }
fn slp_find_from(xs: const i32[:], v: i32, from: i64) -> i64 {
    for k in from..xs.len { if xs[k] == v { return k; } }
    return xs.len;
}
fn slp_contains(xs: const i32[:], v: i32) -> bool { for x in xs { if x == v { return true; } } return false; }
// the user scalar of operand lane `lane` of entry te (stores / insertvalues map through ReorderIndices)
fn slp_cd_user_lane(te: i32, lane0: i64) -> i64 {
    var lane = lane0;
    let u = te_scalar(te, lane);
    if (is_inst_op(u, OP_STORE) || is_inst_op(u, OP_INSERTVALUE)) && slp_te[te].nreord > 0 { lane = te_reorder(te)[lane] as i64; }
    return lane;
}
fn slp_nonsched_with_phi_parent(te: i32) -> bool {
    let e = slp_te[te];
    return e.no_sched && e.ui_te >= 0 && te_has_state(e.ui_te) && slp_te[e.ui_te].state != TE_SPLIT && te_opcode(e.ui_te) == OP_PHI;
}
// addScheduleCopyableData(EI, I, SchedulingRegionID, Bundle)
fn slp_add_cd(bs: i32, te: i32, edge: i64, i: i32, b: i32) -> i32 {
    let key = cd_ei_key(te, edge);
    if sh_get(SH_CDMAP, key, i as i64, -1) >= 0 { fatal("internal: SLP: copyable data already in the map"); }
    let cd = slp_sd.len as i32;
    slp_sd.push(SSD { inst: i, next_ls: -1, region: slp_bs[bs].region_id, deps: SLP_INVALID_DEPS, unsched: SLP_INVALID_DEPS,
                      sched: false, mem_h: -1, mem_t: -1, ctl_h: -1, ctl_t: -1, cd: true, ei_te: te, ei_edge: edge, cb: b,
                      bs: bs, prio: 0 });
    sh_set(SH_CDMAP, key, i as i64, cd as i64);
    slp_bs[bs].cd_n += 1;
    cd_lk_push(SH_CDINST, i as i64, 0, cd);
    if te >= 0 {
        let opv = te_operand(te, edge);
        var visited: i32[>..<] = [];
        var it = slp_find_from(opv, i, 0);
        if it >= opv.len { fatal("internal: SLP: copyable lane not set"); }
        while it < opv.len {
            let lane = slp_cd_user_lane(te, it);
            let inn = te_scalar(te, lane);
            if slp_contains(visited, inn) { it = slp_find_from(opv, i, it + 1); continue; }
            visited.push(inn);
            cd_lk_push(SH_CDIU, cd_iu_key(inn, edge), i as i64, cd);
            cd_lk_insert(SH_CDUSERS, i as i64, 0, cd);
            if inn == i {
                let ucd = slp_get_cd(bs, slp_te[te].ui_te, slp_te[te].ui_edge, inn);
                if ucd >= 0 { cd_lk_remove(SH_CDUSERS, i as i64, 0, ucd); }
            }
            it = slp_find_from(opv, i, it + 1);
        }
    } else {
        cd_lk_insert(SH_CDUSERS, i as i64, 0, cd);
    }
    return cd;
}
// areAllOperandsReplacedByCopyableData(User, Op, SLP, NumOps)
fn slp_all_ops_replaced_by_cd(bs: i32, user: i32, opv: i32, numops: i64) -> bool {
    if slp_bs[bs].cd_n == 0 { return false; }
    if slp_tree_entries_head(user) < 0 { return false; }
    var pte: i32[>..<] = [];
    var pcnt: i64[>..<] = [];
    var cur: i64 = 0;
    for k in nops(user) {
        if op(user, k) != opv { continue; }
        cur++;
        var c = slp_tree_entries_head(user);
        while c >= 0 {
            let te = slp_lk[c].x;
            c = slp_lk[c].next;
            var inc: i64 = 0;
            if slp_nonsched_with_phi_parent(te) {
                var pu: i32[>..<] = [];
                for v in te_scalars(slp_te[te].ui_te) {
                    if !is_inst_op(v, OP_PHI) { continue; }
                    if slp_contains(pu, v) { continue; }
                    pu.push(v);
                    var has = false;
                    for j in nops(v) { if op(v, j) == user { has = true; break; } }
                    if has { inc++; }
                }
            } else {
                for v in te_scalars(te) { if v == user { inc++; } }
            }
            var comm = slp_is_commutative(user) && slp_is_commutable_operand(user, k);
            if !comm {
                let mo = te_matching(te, user);
                comm = mo >= 0 && slp_is_commutative_vu(mo, user, false) && slp_is_commutable_operand(mo, k);
            }
            let same_ops = comm && op(user, 0) == op(user, 1);
            if (!comm || same_ops) && !slp_is_cmp(user) {
                if cur != numops || slp_get_cd(bs, te, k, opv) >= 0 { continue; }
                return false;
            }
            if cur != numops { continue; }
            var found = false;
            for j in pte.len { if pte[j] == te { pcnt[j] += inc; found = true; break; } }
            if !found { pte.push(te); pcnt.push(inc); }
        }
    }
    if pte.len == 0 { return true; }
    for j in pte.len {
        let te = pte[j];
        let nsp = slp_nonsched_with_phi_parent(te);
        var pu: i32[>..<] = [];
        let sc = te_scalars(te);
        var it = slp_find_from(sc, user, 0);
        if it >= sc.len { fatal("internal: SLP: user is not in the tree entry"); }
        while it < sc.len {
            let lane = slp_cd_user_lane(te, it);
            if nsp {
                let u = te_scalar(slp_te[te].ui_te, lane);
                if slp_contains(pu, u) { it = slp_find_from(sc, user, it + 1); continue; }
                pu.push(u);
            }
            for opi in slp_num_potentially_commutative_ops(te_main(te)) {
                if te_operand(te, opi)[lane] == opv && slp_get_cd(bs, te, opi, opv) >= 0 { pcnt[j] -= 1; }
            }
            it = slp_find_from(sc, user, it + 1);
        }
    }
    for j in pte.len { if pcnt[j] != numops - 1 { return false; } }
    return true;
}
fn slp_recalc_insert(bs: i32, sd: i32) {
    for r in slp_recalc { if r.bs == bs && r.ent == sd { return; } }
    slp_recalc.push(SReady { bs: bs, ent: sd, alive: true });
}

// ---------------------------------------------------------------- ReadyInsts (SetVector)
// scheduleBlock's ReadyInsts: a std::set ordered by descending SchedulingPriority (equal priorities are one key)
var slp_prio_mode: bool = false;
var slp_prio_set: i32[>..<];
fn ent_prio(e: i32) -> i32 { if ent_is_bundle(e) { slp_sb[ent_bundle(e)].prio } else { slp_sd[e].prio } }
fn slp_ready_insert(bs: i32, e: i32) {
    if slp_prio_mode {
        let p = ent_prio(e);
        for x in slp_prio_set { if ent_prio(x) == p { return; } }
        slp_prio_set.push(e);
        return;
    }
    if !sh_add(SH_READY, bs as i64, e as i64) { return; }
    slp_ready.push(SReady { bs: bs, ent: e, alive: true });
    slp_ready_alive++;
}
fn slp_ready_remove(bs: i32, e: i32) {
    if !sh_has(SH_READY, bs as i64, e as i64) { return; }
    sh_del(SH_READY, bs as i64, e as i64);
    var k = slp_ready.len;
    while k > 0 {
        k--;
        if slp_ready[k].alive && slp_ready[k].bs == bs && slp_ready[k].ent == e { slp_ready[k].alive = false; slp_ready_alive--; break; }
    }
    slp_ready_compact();
}
fn slp_ready_compact() {
    if slp_ready_alive == 0 { slp_ready.clear(); return; }
    while slp_ready.len > 0 && !slp_ready[slp_ready.len - 1].alive { slp_ready.pop(); }
}
fn slp_ready_empty(bs: i32) -> bool {
    var k = slp_ready.len;
    while k > 0 { k--; if slp_ready[k].alive && slp_ready[k].bs == bs { return false; } }
    return true;
}
fn slp_ready_pop_back(bs: i32) -> i32 {
    var k = slp_ready.len;
    while k > 0 {
        k--;
        if slp_ready[k].alive && slp_ready[k].bs == bs {
            let e = slp_ready[k].ent;
            slp_ready[k].alive = false;
            slp_ready_alive--;
            sh_del(SH_READY, bs as i64, e as i64);
            slp_ready_compact();
            return e;
        }
    }
    fatal("internal: SLP: pop from an empty ready list");
    return 0;
}
fn slp_ready_clear(bs: i32) {
    for k in slp_ready.len {
        if slp_ready[k].alive && slp_ready[k].bs == bs {
            slp_ready[k].alive = false;
            slp_ready_alive--;
            sh_del(SH_READY, bs as i64, slp_ready[k].ent as i64);
        }
    }
    slp_ready_compact();
}

// ---------------------------------------------------------------- schedule(R, S, EI, Data, ReadyList)
fn slp_decr_unsched(bs: i32, d: i32, is_control: bool) {
    if (is_control || sd_valid_deps(d)) && sd_incr_unsched(d, -1) == 0 {
        if slp_sd[d].cd {
            let b = slp_sd[d].cb;
            if sb_unsched(b) == 0 {
                slp_ready_insert(bs, ent_of_bundle(b));
                if slp_dbg_on { errs("SLP:    gets ready: "); slp_dbg_ent(ent_of_bundle(b)); errs("\n"); slp_dbg_flush(); }
            }
            return;
        }
        let inst = slp_sd[d].inst;
        var c = slp_bundles_head(inst);
        if c >= 0 {
            while c >= 0 {
                let b = slp_lk[c].x;
                c = slp_lk[c].next;
                if sb_unsched(b) == 0 {
                    slp_ready_insert(bs, ent_of_bundle(b));
                    if slp_dbg_on { errs("SLP:    gets ready: "); slp_dbg_ent(ent_of_bundle(b)); errs("\n"); slp_dbg_flush(); }
                }
            }
            return;
        }
        slp_ready_insert(bs, d);
        if slp_dbg_on { errs("SLP:    gets ready: "); slp_dbg_ent(d); errs("\n"); slp_dbg_flush(); }
    }
}
// DecrUnschedForInst(User, OpIdx, I) of a stand-alone instruction
fn slp_decr_unsched_for_inst(bs: i32, user: i32, opidx: i64, i: i32) {
    if slp_bs[bs].cd_n > 0 {
        var cds: i32[>..<] = [];
        slp_cds_of_user_op(bs, user, opidx, i, cds);
        for cd in cds { slp_decr_unsched(bs, cd, false); }
        if cds.len > 0 { return; }
    }
    let opsd = slp_get_sd(bs, i);
    if opsd >= 0 { slp_decr_unsched(bs, opsd, false); }
}
// ProcessBundleMember(BundleMember, Bundles): `tes` are the tree entries of the bundles (-1 = a bundle without one)
fn slp_process_bundle_member(bs: i32, s: SIS, member: i32, tes: const i32[:]) {
    let inn = slp_sd[member].inst;
    let is_cd = slp_sd[member].cd;
    if tes.len > 0 {
        // OperandsUses: operand instruction -> remaining uses (SH_TMP1), TotalOpCount
        sh_clear(SH_TMP1);
        var total: i64 = 0;
        if is_cd { sh_set(SH_TMP1, inn as i64, 0, 1); total = 1; }
        else { for k in nops(inn) {
            let o = op(inn, k);
            if !is_inst(o) { continue; }
            var extra: i64 = 1;
            for te in tes {
                if te >= 0 { if te_is_expanded_binop(te, inn) { extra++; } }
                else if sis_is_expanded_binop(s, inn) { extra++; }
            }
            sh_set(SH_TMP1, o as i64, 0, sh_get(SH_TMP1, o as i64, 0, 0) + extra);
            total += extra;
        } }
        let cdmap = slp_bs[bs].cd_n > 0;
        sh_clear(SH_TMP2);   // Checked: (entity, OpIdx)
        for te in tes {
            if !cdmap && total == 0 { break; }
            sh_clear(SH_TMP3);   // ParentsUniqueUsers
            if te < 0 { fatal("internal: SLP: scheduling a bundle without a tree entry"); }
            let sc = te_scalars(te);
            var it: i64 = -1;
            for k in sc.len { if sc[k] == inn { it = k; break; } }
            let e = slp_te[te];
            let nonsched_phi_parent = e.no_sched && e.ui_te >= 0 && te_has_state(e.ui_te) && slp_te[e.ui_te].state != TE_SPLIT &&
                                      te_opcode(e.ui_te) == OP_PHI;
            while it >= 0 && it < sc.len {
                var lane = it;
                if (iop(inn) == OP_STORE || iop(inn) == OP_INSERTVALUE) && e.nreord > 0 { lane = te_reorder(te)[lane] as i64; }
                var skip = false;
                if nonsched_phi_parent {
                    let usr = te_scalar(e.ui_te, lane);
                    if !sh_add(SH_TMP3, usr as i64, 0) { skip = true; }
                }
                if !skip {
                    for opi in te_num_operands(te) {
                        let i = te_operand(te, opi)[lane];
                        if !is_inst(i) { continue; }
                        if slp_dbg_on { errs("SLP:   check for readiness (def): "); slp_dv(i); errs("\n"); slp_dbg_flush(); }
                        let expanded = te_is_expanded_operand(te, inn, opi);
                        if cdmap {
                            let cd = slp_get_cd(bs, te, opi, i);
                            if cd >= 0 {
                                if sh_add(SH_TMP2, cd as i64, opi) { slp_decr_unsched(bs, cd, false); }
                                continue;
                            }
                        }
                        let rem = sh_get(SH_TMP1, i as i64, 0, -1);
                        if rem < 0 { fatal("internal: SLP: operand not found"); }
                        if rem > 0 {
                            let opsd = slp_get_sd(bs, i);
                            if opsd >= 0 {
                                if !expanded && !sh_add(SH_TMP2, opsd as i64, opi) { continue; }
                                sh_set(SH_TMP1, i as i64, 0, rem - 1);
                                total--;
                                slp_decr_unsched(bs, opsd, false);
                            } else {
                                sh_set(SH_TMP1, i as i64, 0, rem - 1);
                                total--;
                            }
                        }
                    }
                    if te_is_copyable_element(te, inn) { break; }
                }
                var nx: i64 = -1;
                for k in (it + 1)..sc.len { if sc[k] == inn { nx = k; break; } }
                it = nx;
            }
        }
        if total > 0 && iop(inn) == OP_CALL {
            let id = laa_vector_intrinsic_id_for_call(inn);
            for ai in cb_nargs(inn) {
                if !vu_scalar_op_at_arg(id, ai, true) { continue; }
                let opi = cb_arg(inn, ai);
                if !is_inst(opi) { continue; }
                let rem = sh_get(SH_TMP1, opi as i64, 0, -1);
                if rem <= 0 { continue; }
                sh_set(SH_TMP1, opi as i64, 0, rem - 1);
                total--;
                let opsd = slp_get_sd(bs, opi);
                if opsd >= 0 {
                    if slp_dbg_on { errs("SLP:   check for readiness (scalar arg): "); slp_dv(opi); errs("\n"); slp_dbg_flush(); }
                    slp_decr_unsched(bs, opsd, false);
                }
            }
        }
    } else {
        for k in nops(inn) {
            let i = op(inn, k);
            if !is_inst(i) { continue; }
            if slp_dbg_on { errs("SLP:   check for readiness (def): "); slp_dv(i); errs("\n"); slp_dbg_flush(); }
            slp_decr_unsched_for_inst(bs, inn, k, i);
        }
    }
    if is_cd { return; }
    // memory dependencies
    sh_clear(SH_TMP3);
    var c = slp_sd[member].mem_h;
    while c >= 0 {
        let d = slp_dl[c].x;
        c = slp_dl[c].next;
        if !sh_add(SH_TMP3, d as i64, 0) { continue; }
        if slp_dbg_on { errs("SLP:   check for readiness (mem): "); slp_dbg_ent(d); errs("\n"); slp_dbg_flush(); }
        slp_decr_unsched(bs, d, false);
    }
    sh_clear(SH_TMP3);
    c = slp_sd[member].ctl_h;
    while c >= 0 {
        let d = slp_dl[c].x;
        c = slp_dl[c].next;
        if !sh_add(SH_TMP3, d as i64, 0) { continue; }
        if slp_dbg_on { errs("SLP:   check for readiness (ctrl): "); slp_dbg_ent(d); errs("\n"); slp_dbg_flush(); }
        slp_decr_unsched(bs, d, true);
    }
}
fn slp_schedule_entity(bs: i32, s: SIS, data: i32) {
    if !ent_is_bundle(data) {
        let sd = data;
        slp_sd[sd].sched = true;
        if slp_dbg_on { errs("SLP:   schedule "); slp_dbg_ent(sd); errs("\n"); slp_dbg_flush(); }
        let inn = slp_sd[sd].inst;
        var tes: i32[>..<] = [];
        var c = slp_tree_entries_head(inn);
        while c >= 0 {
            let te = slp_lk[c].x;
            c = slp_lk[c].next;
            let o = iop(inn);
            if !(o == OP_EXTRACTVALUE || o == OP_EXTRACTELEMENT || is_callbase(inn)) && nops(inn) != te_num_operands(te) { continue; }
            tes.push(te);
        }
        slp_process_bundle_member(bs, s, sd, tes);
        return;
    }
    let b = ent_bundle(data);
    slp_sb[b].sched = true;
    if slp_dbg_on { errs("SLP:   schedule "); slp_dbg_ent(data); errs("\n"); slp_dbg_flush(); }
    for k in sb_n(b) {
        let sd = sb_member(b, k);
        if slp_sd[sd].cd {
            slp_sd[sd].sched = true;
            var one: i32[>..<] = [];
            one.push(slp_sb[b].te);
            slp_process_bundle_member(bs, s, sd, one);
            continue;
        }
        var tes: i32[>..<] = [];
        var all_sched = true;
        var c = slp_bundles_head(slp_sd[sd].inst);
        if c < 0 { all_sched = false; }
        while c >= 0 {
            let ob = slp_lk[c].x;
            c = slp_lk[c].next;
            if !slp_sb[ob].sched { all_sched = false; }
            tes.push(slp_sb[ob].te);
        }
        if !all_sched { continue; }
        slp_sd[sd].sched = true;
        if slp_bs[bs].cd_n == 0 { slp_process_bundle_member(bs, s, sd, tes); continue; }
        // pseudo-bundles for the tree entries of the instruction without a schedule bundle
        let inn = slp_sd[sd].inst;
        let n0 = tes.len;
        c = slp_tree_entries_head(inn);
        while c >= 0 {
            let te = slp_lk[c].x;
            c = slp_lk[c].next;
            if te_is_copyable_element(te, inn) { continue; }
            let o = iop(inn);
            if !(o == OP_EXTRACTVALUE || o == OP_EXTRACTELEMENT || is_callbase(inn)) && nops(inn) != te_num_operands(te) { continue; }
            var dup = false;
            for j in n0 { if tes[j] == te { dup = true; break; } }
            if dup { continue; }
            tes.push(te);
        }
        slp_process_bundle_member(bs, s, sd, tes);
    }
}
// initialFillReadyList(ReadyInsts)
fn slp_initial_fill_ready_list(bs: i32) {
    sh_clear(SH_TMP3);
    var i = slp_bs[bs].start;
    while i >= 0 && i != slp_bs[bs].end {
        let sd = slp_get_sd(bs, i);
        if sd >= 0 && sd_valid_deps(sd) && sd_is_ready(sd) {
            var c = slp_bundles_head(i);
            if c >= 0 {
                while c >= 0 {
                    let b = slp_lk[c].x;
                    c = slp_lk[c].next;
                    if !sh_add(SH_TMP3, b as i64, 0) { continue; }
                    if sb_valid_deps(b) && sb_is_ready(b) {
                        slp_ready_insert(bs, ent_of_bundle(b));
                        if slp_dbg_on { errs("SLP:    initially in ready list: "); slp_dbg_ent(ent_of_bundle(b)); errs("\n"); slp_dbg_flush(); }
                    }
                }
            } else {
                slp_ready_insert(bs, sd);
                if slp_dbg_on { errs("SLP:    initially in ready list: "); slp_dbg_ent(sd); errs("\n"); slp_dbg_flush(); }
            }
        }
        i = inst_next(i);
    }
}

// ---------------------------------------------------------------- building the region
// buildBundle(VL, S, EI)
fn slp_build_bundle(bs: i32, vl: const i32[:], s: SIS, ei_te: i32, ei_edge: i64) -> i32 {
    let b = slp_sb.len as i32;
    slp_sb.push(SSB { m_at: slp_sbm.len as i32, m_n: 0, te: -1, sched: false, bs: bs, prio: 0 });
    for v in vl {
        if sis_is_non_schedulable(s, v) { continue; }
        if sis_is_copyable_element(s, v) {
            let cd = slp_add_cd(bs, ei_te, ei_edge, v, b);
            slp_sbm.push(cd);
            slp_sb[b].m_n += 1;
            continue;
        }
        let m = slp_get_sd(bs, v);
        if m < 0 { fatal("internal: SLP: no ScheduleData for bundle member"); }
        slp_sbm.push(m);
        slp_sb[b].m_n += 1;
        slp_lk_push_tail(SH_SBUN, v as i64, b);
    }
    return b;
}
fn slp_is_assume_like_intr(i: i32) -> bool {
    if !is_callbase(i) { return false; }
    let id = inst_iid(i);
    return id == IID_assume || id == IID_sideeffect || id == IID_pseudoprobe || id == IID_dbg_assign || id == IID_dbg_declare ||
        id == IID_dbg_value || id == IID_dbg_label || id == IID_invariant_start || id == IID_invariant_end ||
        id == IID_lifetime_start || id == IID_lifetime_end || id == IID_experimental_noalias_scope_decl ||
        id == IID_objectsize || id == IID_ptr_annotation || id == IID_var_annotation;
}
// initScheduleData(FromI, ToI, PrevLoadStore, NextLoadStore)
fn slp_init_schedule_data(bs: i32, from: i32, to: i32, prev_ls: i32, next_ls: i32) {
    var cur = prev_ls;
    var i = from;
    let inv = md_kind_id("invariant.load");
    while i != to {
        if iop(i) == OP_PHI { i = inst_next(i); continue; }
        var sd = sh_get(SH_SDMAP, i as i64, 0, -1) as i32;
        if sd < 0 {
            sd = slp_sd.len as i32;
            slp_sd.push(SSD { inst: i, next_ls: -1, region: 0, deps: SLP_INVALID_DEPS, unsched: SLP_INVALID_DEPS, sched: false,
                              mem_h: -1, mem_t: -1, ctl_h: -1, ctl_t: -1, cd: false, ei_te: -1, ei_edge: -1, cb: -1, bs: bs, prio: 0 });
            sh_set(SH_SDMAP, i as i64, 0, sd as i64);
        }
        // ScheduleData::init
        slp_sd[sd].next_ls = -1;
        slp_sd[sd].sched = false;
        slp_sd[sd].region = slp_bs[bs].region_id;
        sd_clear_deps(sd);
        slp_sd[sd].inst = i;
        let can_ignore_load = iop(i) == OP_LOAD && ld_is_simple(i) && inst_get_md(i, inv) >= 0;
        let id = inst_iid(i);
        if inst_may_read_or_write_memory(i) && !can_ignore_load && (id == 0 || (id != IID_sideeffect && id != IID_pseudoprobe)) {
            if cur >= 0 { slp_sd[cur].next_ls = sd; } else { slp_bs[bs].first_ls = sd; }
            cur = sd;
        }
        if id == IID_stacksave || id == IID_stackrestore { slp_bs[bs].stack_save = true; }
        i = inst_next(i);
    }
    if next_ls >= 0 {
        if cur >= 0 { slp_sd[cur].next_ls = next_ls; }
    } else {
        slp_bs[bs].last_ls = cur;
    }
}
// extendSchedulingRegion(V, S)
fn slp_extend_scheduling_region(bs: i32, i: i32) -> bool {
    if slp_get_sd(bs, i) >= 0 { return true; }
    if slp_bs[bs].start < 0 {
        slp_init_schedule_data(bs, i, inst_next(i), -1, -1);
        slp_bs[bs].start = i;
        slp_bs[bs].end = inst_next(i);
        if slp_dbg_on { errs("SLP:  initialize schedule region to "); slp_dv(i); errs("\n"); slp_dbg_flush(); }
        return true;
    }
    var up = inst_prev(slp_bs[bs].start);
    var down = slp_bs[bs].end;
    while up >= 0 && slp_is_assume_like_intr(up) { up = inst_prev(up); }
    while down >= 0 && slp_is_assume_like_intr(down) { down = inst_next(down); }
    while up >= 0 && down >= 0 && up != i && down != i {
        slp_bs[bs].region_size += 1;
        if slp_bs[bs].region_size > slp_bs[bs].region_limit {
            if slp_dbg_on { errs("SLP:  exceeded schedule region size limit\n"); slp_dbg_flush(); }
            return false;
        }
        up = inst_prev(up);
        down = inst_next(down);
        while up >= 0 && slp_is_assume_like_intr(up) { up = inst_prev(up); }
        while down >= 0 && slp_is_assume_like_intr(down) { down = inst_next(down); }
    }
    if down < 0 || (up >= 0 && up == i) {
        slp_init_schedule_data(bs, i, slp_bs[bs].start, -1, slp_bs[bs].first_ls);
        slp_bs[bs].start = i;
        if slp_dbg_on { errs("SLP:  extend schedule region start to "); slp_dv(i); errs("\n"); slp_dbg_flush(); }
        return true;
    }
    slp_init_schedule_data(bs, slp_bs[bs].end, inst_next(i), slp_bs[bs].last_ls, -1);
    slp_bs[bs].end = inst_next(i);
    if slp_dbg_on { errs("SLP:  extend schedule region end to "); slp_dv(i); errs("\n"); slp_dbg_flush(); }
    return true;
}
// BoUpSLP::isAliased(Loc1, Inst1, Inst2)
fn slp_is_aliased(loc: ML, i1: i32, i2: i32) -> bool {
    let c = sh_get(SH_ALIAS, i1 as i64, i2 as i64, -1);
    if c >= 0 { return c != 0; }
    let r = aa_inst_loc_mr(i2, loc, slp_aaq) != MR_NO;
    sh_set(SH_ALIAS, i1 as i64, i2 as i64, if r { 1 } else { 0 });
    return r;
}
// getLocation(I)
fn slp_get_location(i: i32) -> ML {
    if iop(i) == OP_LOAD || iop(i) == OP_STORE { return ml_get(i); }
    return ml_null();
}
// calculateDependencies(Bundle, InsertInReadyList, SLP, ExpandedOps, ControlDeps): bundle -1 = invalid;
// the expanded ops are in SH_TMP4
fn slp_calculate_dependencies(bs: i32, bundle: i32, insert_ready: bool, ctl_deps: const i32[:]) {
    var wl: i32[>..<] = [];
    fn push_if(usd: i32) { if !sd_valid_deps(usd) || (insert_ready && sd_is_ready(usd)) { wl.push(usd); } }
    fn process_cd(cd: i32) {
        if sd_valid_deps(cd) { return; }
        if slp_dbg_on { errs("SLP:       update deps of "); slp_dbg_ent(cd); errs("\n"); slp_dbg_flush(); }
        slp_sd[cd].deps = 0;
        sd_reset_unsched(cd);
        let te = slp_sd[cd].ei_te;
        if te < 0 { return; }
        let ci = slp_sd[cd].inst;
        let opv = te_operand(te, slp_sd[cd].ei_edge);
        var visited: i32[>..<] = [];
        var it = slp_find_from(opv, ci, 0);
        if it >= opv.len { fatal("internal: SLP: copyable lane not set"); }
        while it < opv.len {
            let lane = slp_cd_user_lane(te, it);
            let inn = te_scalar(te, lane);
            if te_is_copyable_element(te, inn) {
                let usd = slp_get_cd(bs, slp_te[te].ui_te, slp_te[te].ui_edge, inn);
                if usd >= 0 {
                    slp_sd[cd].deps += 1;
                    if !slp_sd[usd].sched { sd_incr_unsched(cd, 1); }
                    push_if(usd);
                }
            } else if !slp_contains(visited, inn) {
                visited.push(inn);
                let usd = slp_get_sd(bs, inn);
                if usd >= 0 {
                    let extra: i32 = if te_is_expanded_binop(te, inn) { 2 } else { 1 };
                    slp_sd[cd].deps += extra;
                    if !slp_sd[usd].sched { sd_incr_unsched(cd, extra); }
                    push_if(usd);
                }
            }
            it = slp_find_from(opv, ci, it + 1);
        }
        if sd_is_ready(cd) && slp_sd[cd].deps == 0 && te_has_state(te) {
            let m = te_main(te);
            var pseudo = inst_parent(m) != inst_parent(ci);
            if !pseudo && iop(m) == OP_PHI {
                if slp_has_n_uses_or_more(m, SLP_USES_LIMIT) { pseudo = true; }
                else {
                    var u = vals[m].first_use;
                    while u >= 0 {
                        let usr = uses[u].user;
                        u = uses[u].next;
                        if !is_inst(usr) || inst_parent(usr) == inst_parent(m) { pseudo = true; break; }
                    }
                }
            }
            if pseudo {
                slp_sd[cd].deps += 1;
                sd_incr_unsched(cd, 1);
            }
        }
    }
    fn process_node(member: i32) {
        if slp_sd[member].cd { process_cd(member); return; }
        if sd_valid_deps(member) { return; }
        if slp_dbg_on { errs("SLP:       update deps of "); slp_dbg_ent(member); errs("\n"); slp_dbg_flush(); }
        slp_sd[member].deps = 0;
        sd_reset_unsched(member);
        let inst = slp_sd[member].inst;
        // def-use chain dependencies
        sh_clear(SH_CDTMP);   // UserToNumOps
        var u = vals[inst].first_use;
        while u >= 0 {
            let usr = uses[u].user;
            u = uses[u].next;
            if is_inst_op(usr, OP_PHI) { continue; }
            let usd = slp_get_sd(bs, usr);
            if usd < 0 { continue; }
            let nops_ = sh_get(SH_CDTMP, usr as i64, 0, 0) + 1;
            sh_set(SH_CDTMP, usr as i64, 0, nops_);
            if slp_all_ops_replaced_by_cd(bs, usr, inst, nops_) { continue; }
            var extra: i32 = 1;
            var c = slp_tree_entries_head(usr);
            while c >= 0 { if te_is_expanded_binop(slp_lk[c].x, usr) { extra++; } c = slp_lk[c].next; }
            if sh_has(SH_TMP4, usr as i64, 0) { extra++; }
            slp_sd[member].deps += extra;
            if !slp_sd[usd].sched { sd_incr_unsched(member, extra); }
            push_if(usd);
        }
        if slp_bs[bs].cd_n > 0 {
            var cdu: i32[>..<] = [];
            slp_cd_users(bs, inst, cdu);
            for usd in cdu {
                slp_sd[member].deps += 1;
                if !slp_sd[usd].sched { sd_incr_unsched(member, 1); }
                push_if(usd);
            }
        }
        sh_clear(SH_TMP3);
        fn make_control_dependent(i: i32) {
            if !sh_add(SH_TMP3, i as i64, 0) { return; }
            let dd = slp_get_sd(bs, i);
            if dd < 0 { fatal("internal: SLP: must be in schedule window"); }
            sd_add_dep(dd, true, member);
            slp_sd[member].deps += 1;
            if !slp_sd[dd].sched { sd_incr_unsched(member, 1); }
            push_if(dd);
        }
        let end = slp_bs[bs].end;
        if !guaranteed_to_transfer(inst) {
            var i = inst_next(inst);
            let first = block_first(slp_bs[bs].bb);
            while i != end {
                if spec_safe(i, first, true) { i = inst_next(i); continue; }
                make_control_dependent(i);
                if !guaranteed_to_transfer(i) { break; }
                i = inst_next(i);
            }
        }
        if slp_bs[bs].stack_save {
            let mid = inst_iid(inst);
            if mid == IID_stacksave || mid == IID_stackrestore {
                var i = inst_next(inst);
                while i != end {
                    let id = inst_iid(i);
                    if id == IID_stacksave || id == IID_stackrestore { break; }
                    if iop(i) == OP_ALLOCA { make_control_dependent(i); }
                    i = inst_next(i);
                }
            }
            if iop(inst) == OP_ALLOCA || inst_may_read_or_write_memory(inst) {
                var i = inst_next(inst);
                while i != end {
                    let id = inst_iid(i);
                    if id == IID_stacksave || id == IID_stackrestore { make_control_dependent(i); break; }
                    i = inst_next(i);
                }
            }
        }
        // memory dependencies
        let nls = slp_sd[member].next_ls;
        if nls < 0 { return; }
        let src_loc = slp_get_location(inst);
        let src_may_write = inst_may_write_memory(inst);
        var naliased: i64 = 0;
        var dist: i64 = 1;
        let non_simple_src = src_loc.ptr == ML_NULL || !slp_is_simple(inst);
        var dd = nls;
        while dd >= 0 {
            let di = slp_sd[dd].inst;
            if dist >= 160 || ((src_may_write || inst_may_write_memory(di)) &&
                               (non_simple_src || naliased >= 10 || slp_is_aliased(src_loc, inst, di))) {
                naliased++;
                sd_add_dep(dd, false, member);
                slp_sd[member].deps += 1;
                if !slp_sd[dd].sched { sd_incr_unsched(member, 1); }
                push_if(dd);
            }
            if dist >= 2 * 160 { break; }
            dist++;
            dd = slp_sd[dd].next_ls;
        }
    }
    if bundle >= 0 { wl.push(sb_member(bundle, 0)); }
    for d in ctl_deps { wl.push(d); }
    sh_clear(SH_TMP0);   // Visited bundles
    while wl.len > 0 {
        let sd = wl.pop();
        if slp_sd[sd].cd {
            let b = slp_sd[sd].cb;
            if !sb_valid_deps(b) && sh_add(SH_TMP0, b as i64, 0) { for k in sb_n(b) { process_node(sb_member(b, k)); } }
            if insert_ready && sd_is_ready(sd) && sb_is_ready(b) {
                slp_ready_insert(bs, ent_of_bundle(b));
                if slp_dbg_on { errs("SLP:     gets ready on update: "); slp_dbg_ent(ent_of_bundle(b)); errs("\n"); slp_dbg_flush(); }
            }
            continue;
        }
        var c = slp_bundles_head(slp_sd[sd].inst);
        if c < 0 {
            if !sd_valid_deps(sd) { process_node(sd); }
            if insert_ready && sd_is_ready(sd) {
                slp_ready_insert(bs, sd);
                if slp_dbg_on { errs("SLP:     gets ready on update: "); slp_dbg_ent(sd); errs("\n"); slp_dbg_flush(); }
            }
            continue;
        }
        while c >= 0 {
            let b = slp_lk[c].x;
            c = slp_lk[c].next;
            if sb_valid_deps(b) || !sh_add(SH_TMP0, b as i64, 0) { continue; }
            for k in sb_n(b) { process_node(sb_member(b, k)); }
        }
        if insert_ready && sd_is_ready(sd) {
            c = slp_bundles_head(slp_sd[sd].inst);
            while c >= 0 {
                let b = slp_lk[c].x;
                c = slp_lk[c].next;
                if !sb_is_ready(b) { continue; }
                slp_ready_insert(bs, ent_of_bundle(b));
                if slp_dbg_on { errs("SLP:     gets ready on update: "); slp_dbg_ent(ent_of_bundle(b)); errs("\n"); slp_dbg_flush(); }
            }
        }
    }
}
// the live copyable data of block bs (ScheduleCopyableDataMapByInst's values in the region)
fn slp_live_cds(bs: i32, out: i32[>..<]&) {
    out.clear();
    for k in slp_sd.len { if slp_sd[k].cd && cd_alive(bs, k as i32) { out.push(k as i32); } }
}
// resetSchedule()
fn slp_reset_schedule(bs: i32) {
    var i = slp_bs[bs].start;
    while i >= 0 && i != slp_bs[bs].end {
        let sd = slp_get_sd(bs, i);
        if sd >= 0 { slp_sd[sd].sched = false; sd_reset_unsched(sd); }
        i = inst_next(i);
    }
    if slp_bs[bs].cd_n > 0 {
        var cds: i32[>..<] = [];
        slp_live_cds(bs, cds);
        for cd in cds { slp_sd[cd].sched = false; sd_reset_unsched(cd); }
    }
    for b in slp_sb.len { if slp_sb[b].bs == bs && sb_in_region(bs, b as i32) { slp_sb[b].sched = false; } }
    slp_ready_clear(bs);
}
fn slp_users_all_phis(v: i32) -> bool {
    var u = vals[v].first_use;
    while u >= 0 { if !is_inst_op(uses[u].user, OP_PHI) { return false; } u = uses[u].next; }
    return true;
}
fn slp_needs_ctl_recalc(bs: i32, sd: i32) -> bool { slp_bs[bs].stack_save || !guaranteed_to_transfer(slp_sd[sd].inst) }

// tryScheduleBundle(VL, SLP, S, EI): -2 = std::nullopt (cannot schedule), -1 = nullptr (no scheduling needed),
// otherwise the bundle
fn slp_try_schedule_bundle(bs: i32, vl: const i32[:], s: SIS, ei_te: i32, ei_edge: i64) -> i32 {
    if iop(s.main) == OP_PHI || slp_is_vector_like_inst_with_const_ops(s.main) { return -1; }
    let has_cp = s.copy;
    let ei = ei_te >= 0;
    let no_sched = (!has_cp && slp_does_not_need_to_schedule(vl)) || slp_all_non_schedulable(s, vl);
    if has_cp && ei && te_has_state(ei_te) && te_has_copyable_elements(ei_te) && inst_parent(te_main(ei_te)) == inst_parent(s.main) {
        var all = true;
        for v in vl {
            if sis_is_copyable_element(s, v) { continue; }
            if !slp_is_used_outside_block(v) { all = false; break; }
        }
        if all { return -2; }
    }
    if has_cp && ei && te_has_state(ei_te) {
        for v in vl {
            if !is_inst(v) || !sis_is_copyable_element(s, v) { continue; }
            var u = vals[v].first_use;
            while u >= 0 {
                let iu = uses[u].user;
                u = uses[u].next;
                if !is_inst(iu) || inst_parent(iu) != inst_parent(v) { continue; }
                if iop(iu) != OP_PHI && !slp_has_one_use(iu) && slp_is_used_outside_block(iu) && !slp_users_all_phis(iu) { return -2; }
            }
        }
    }
    if has_cp {
        for v in vl {
            if is_poison(v) || sis_is_copyable_element(s, v) { continue; }
            if !slp_is_used_outside_block(v) { continue; }
            if !is_inst(v) { continue; }
            for k in nops(v) {
                let o = op(v, k);
                if !is_inst(o) { continue; }
                if slp_is_vectorized(o) && inst_next(o) == v { return -2; }
                break;
            }
        }
    }
    if has_cp && ei {
        if slp_nonsched_with_phi_parent(ei_te) {
            let gp = slp_te[ei_te].ui_te;
            let gedge = slp_te[ei_te].ui_edge;
            let phisc = te_scalars(gp);
            for idx in phisc.len {
                let o = te_operand(gp, gedge)[idx];
                if !is_inst(o) || !slp_is_commutative(o) { continue; }
                if slp_has_one_use(o) { continue; }
                var u = vals[o].first_use;
                while u >= 0 {
                    let ui = uses[u].user;
                    u = uses[u].next;
                    if is_inst(ui) && !slp_contains(phisc, ui) { return -2; }
                }
            }
        } else {
            for v in te_scalars(ei_te) {
                if te_has_copyable_elements(ei_te) && te_is_copyable_element(ei_te, v) { continue; }
                var c = slp_tree_entries_head(v);
                while c >= 0 {
                    let t = slp_lk[c].x;
                    c = slp_lk[c].next;
                    if slp_nonsched_with_phi_parent(t) { return -2; }
                }
            }
        }
    }
    if ei && slp_te[ei_te].state == TE_VECTORIZE && te_opcode(ei_te) == OP_PHI {
        for v in vl {
            if !is_inst(v) || (has_cp && sis_is_copyable_element(s, v)) { continue; }
            for t in slp_te.len {
                let ut = slp_te[t].ui_te;
                if ut >= 0 && slp_te[ut].state == TE_VECTORIZE && te_opcode(ut) == OP_PHI && te_has_copyable_elements(t as i32) &&
                   te_is_copyable_element(t as i32, v) { return -2; }
            }
        }
    }
    if no_sched {
        for v in vl {
            if !is_inst(v) || (has_cp && sis_is_copyable_element(s, v)) { continue; }
            if sis_is_expanded_binop(s, v) {
                for j in nops(v) {
                    if sis_is_expanded_operand(s, v, j) { continue; }
                    let o = op(v, j);
                    if !is_inst(o) { continue; }
                    if !slp_has_one_use(o) { return -2; }
                    let sd = slp_get_sd(bs, o);
                    if sd >= 0 && sd_valid_deps(sd) { return -2; }
                }
            }
            sh_clear(SH_CDTMP2);
            for j in nops(v) {
                let o = op(v, j);
                let n = sh_get(SH_CDTMP2, v as i64, o as i64, 0) + 1;
                sh_set(SH_CDTMP2, v as i64, o as i64, n);
                if is_inst(o) && slp_all_ops_replaced_by_cd(bs, v, o, n) {
                    let osd = slp_get_sd(bs, o);
                    if osd >= 0 && sd_valid_deps(osd) { return -2; }
                }
            }
        }
        return -1;
    }
    if has_cp && ei && slp_te[ei_te].state == TE_SPLIT {
        for v in vl { if !sis_is_non_schedulable(s, v) && sis_is_copyable_element(s, v) { return -2; } }
    }
    if has_cp && ei && te_has_state(ei_te) {
        for v in vl {
            if !sis_is_copyable_element(s, v) { continue; }
            for pv in te_scalars(ei_te) {
                if is_inst(pv) && te_is_expanded_binop(ei_te, pv) && op(pv, 0) == v { return -2; }
            }
        }
    }
    let old_end = slp_bs[bs].end;
    if slp_dbg_on { errs("SLP:  bundle: "); slp_dv(s.main); errs("\n"); slp_dbg_flush(); }
    fn try_impl(reschedule0: bool, bundle: i32) {
        var reschedule = reschedule0;
        var ctl: i32[>..<] = [];
        // RecalcCopyableOperandDeps
        var keep: SReady[>..<] = [];
        for r in slp_recalc {
            if r.bs != bs { keep.push(r); continue; }
            let sd = r.ent;
            if !sd_in_region(bs, sd) { continue; }
            if sd_valid_deps(sd) { sd_clear_direct_deps(sd); }
            ctl.push(sd);
        }
        slp_recalc.clear();
        for r in keep { slp_recalc.push(r); }
        fn check_if_need_to_clear_deps() {
            sh_clear(SH_CDTMP2);   // UserOpToNumOps
            for k in sb_n(bundle) {
                let se = sb_member(bundle, k);
                if slp_sd[se].cd {
                    let bm = slp_get_sd(bs, slp_sd[se].inst);
                    if bm >= 0 && sd_valid_deps(bm) {
                        sd_clear_direct_deps(bm);
                        if slp_needs_ctl_recalc(bs, bm) { ctl.push(bm); }
                    }
                    continue;
                }
                let sd = se;
                let inst = slp_sd[sd].inst;
                if sd_valid_deps(sd) && (!has_cp || !sis_is_copyable_element(s, inst)) && slp_has_cds_of_inst(bs, inst) && ei &&
                   te_has_state(ei_te) && (!te_has_copyable_elements(ei_te) || !te_is_copyable_element(ei_te, inst)) {
                    sd_clear_direct_deps(sd);
                }
                let exp = sis_is_expanded_binop(s, inst);
                for j in nops(inst) {
                    let o = op(inst, j);
                    let n = sh_get(SH_CDTMP2, inst as i64, o as i64, 0) + 1;
                    sh_set(SH_CDTMP2, inst as i64, o as i64, n);
                    if is_inst(o) && slp_all_ops_replaced_by_cd(bs, inst, o, n) {
                        let osd = slp_get_sd(bs, o);
                        if osd >= 0 && sd_valid_deps(osd) {
                            sd_clear_direct_deps(osd);
                            if slp_needs_ctl_recalc(bs, osd) { ctl.push(osd); }
                            slp_recalc_insert(bs, osd);
                            continue;
                        }
                    }
                    if exp {
                        let osd = slp_get_sd(bs, o);
                        if osd >= 0 && sd_valid_deps(osd) {
                            sd_clear_direct_deps(osd);
                            ctl.push(osd);
                            continue;
                        }
                    }
                    if is_inst(o) {
                        let osd = slp_get_sd(bs, o);
                        if osd >= 0 && slp_has_cds_of_inst(bs, o) { slp_recalc_insert(bs, osd); }
                    }
                }
            }
        }
        if old_end >= 0 && slp_bs[bs].end != old_end {
            var i = slp_bs[bs].start;
            while i >= 0 && i != slp_bs[bs].end {
                let sd = slp_get_sd(bs, i);
                if sd >= 0 { sd_clear_deps(sd); }
                i = inst_next(i);
            }
            if slp_bs[bs].cd_n > 0 {
                var cds: i32[>..<] = [];
                slp_live_cds(bs, cds);
                for cd in cds { sd_clear_direct_deps(cd); }
            }
            reschedule = true;
        }
        sh_clear(SH_TMP4);
        var any_expanded = false;
        for v in vl { if sis_is_expanded_binop(s, v) { sh_add(SH_TMP4, v as i64, 0); any_expanded = true; } }
        if bundle >= 0 && sb_n(bundle) > 0 {
            if slp_bs[bs].cd_n > 0 || any_expanded { check_if_need_to_clear_deps(); }
            if slp_dbg_on { errs("SLP: try schedule bundle "); slp_dbg_ent(ent_of_bundle(bundle)); errs(" in block "); errs(slp_block_name(slp_bs[bs].bb)); errs("\n"); slp_dbg_flush(); }
            slp_calculate_dependencies(bs, bundle, !reschedule, ctl);
        } else if ctl.len > 0 {
            slp_calculate_dependencies(bs, -1, !reschedule, ctl);
        }
        if reschedule {
            slp_reset_schedule(bs);
            slp_initial_fill_ready_list(bs);
        }
        while ((bundle < 0 && reschedule) || (bundle >= 0 && !sb_is_ready(bundle))) && !slp_ready_empty(bs) {
            let picked = slp_ready_pop_back(bs);
            slp_schedule_entity(bs, s, picked);
            if bundle >= 0 && picked == ent_of_bundle(bundle) { break; }
        }
    }
    for v in vl {
        if sis_is_non_schedulable(s, v) { continue; }
        if !slp_extend_scheduling_region(bs, v) {
            try_impl(false, -1);
            return -2;
        }
    }
    var reschedule = false;
    for v in vl {
        if sis_is_non_schedulable(s, v) { continue; }
        if slp_bs[bs].cd_n > 0 {
            var cds: i32[>..<] = [];
            slp_cds_of_inst(bs, v, cds);
            for cd in cds { slp_ready_remove(bs, cd); }
        }
        let m = slp_get_sd(bs, v);
        if m < 0 {
            if !sis_is_copyable_element(s, v) { fatal("internal: SLP: no ScheduleData for bundle member"); }
            continue;
        }
        slp_ready_remove(bs, m);
        var c = slp_bundles_head(v);
        while c >= 0 { slp_ready_remove(bs, ent_of_bundle(slp_lk[c].x)); c = slp_lk[c].next; }
        if !sis_is_copyable_element(s, v) && !sis_is_expanded_binop(s, v) && !slp_sd[m].sched { continue; }
        if slp_dbg_on { errs("SLP:  reset schedule because "); slp_dbg_ent(m); errs(" was already scheduled\n"); slp_dbg_flush(); }
        reschedule = true;
    }
    let bundle = slp_build_bundle(bs, vl, s, ei_te, ei_edge);
    try_impl(reschedule, bundle);
    if !sb_is_ready(bundle) {
        for k in sb_n(bundle) {
            let bd = sb_member(bundle, k);
            if slp_sd[bd].cd { continue; }
            if sd_is_ready(bd) {
                var c = slp_bundles_head(slp_sd[bd].inst);
                if c < 0 { slp_ready_insert(bs, bd); continue; }
                while c >= 0 { let b = slp_lk[c].x; c = slp_lk[c].next; if sb_is_ready(b) { slp_ready_insert(bs, ent_of_bundle(b)); } }
            }
        }
        // ScheduledBundlesList.pop_back(): the bundle is gone
        var ctl: i32[>..<] = [];
        var any_exp = false;
        for v in vl { if sis_is_expanded_binop(s, v) { any_exp = true; } }
        for v in vl {
            if sis_is_non_schedulable(s, v) { continue; }
            if sis_is_expanded_binop(s, v) {
                for j in nops(v) {
                    let opsd = slp_get_sd(bs, op(v, j));
                    if opsd >= 0 && sd_valid_deps(opsd) { sd_clear_direct_deps(opsd); ctl.push(opsd); }
                }
            }
            if sis_is_copyable_element(s, v) {
                // remove the copyable data from the region and restore the previous mappings
                let key = cd_ei_key(ei_te, ei_edge);
                let mcd = sh_get(SH_CDMAP, key, v as i64, -1) as i32;
                if mcd < 0 { fatal("internal: SLP: no ScheduleCopyableData for copyable element"); }
                let cd = cd_lk_pop_back_bs(SH_CDINST, v as i64, 0, bs);
                if cd != mcd { fatal("internal: SLP: copyable data maps out of sync"); }
                cd_lk_remove(SH_CDUSERS, v as i64, 0, cd);
                if ei {
                    let opv = te_operand(ei_te, ei_edge);
                    var visited: i32[>..<] = [];
                    var it = slp_find_from(opv, v, 0);
                    if it >= opv.len { fatal("internal: SLP: copyable lane not set"); }
                    while it < opv.len {
                        let lane = slp_cd_user_lane(ei_te, it);
                        let inn = te_scalar(ei_te, lane);
                        if slp_contains(visited, inn) { break; }
                        visited.push(inn);
                        cd_lk_pop_back_bs(SH_CDIU, cd_iu_key(inn, ei_edge), v as i64, bs);
                        it = slp_find_from(opv, v, it + 1);
                    }
                    let ucd = slp_get_cd(bs, slp_te[ei_te].ui_te, slp_te[ei_te].ui_edge, v);
                    if ucd >= 0 { cd_lk_insert(SH_CDUSERS, v as i64, 0, ucd); }
                }
                sh_del(SH_CDMAP, key, v as i64);
                slp_bs[bs].cd_n -= 1;
                slp_sd[cd].region = 0;
                let osd = slp_get_sd(bs, v);
                if osd >= 0 && sd_valid_deps(osd) {
                    sd_clear_direct_deps(osd);
                    if slp_needs_ctl_recalc(bs, osd) { ctl.push(osd); }
                    if any_exp {
                        for j in nops(v) {
                            let o2 = slp_get_sd(bs, op(v, j));
                            if o2 >= 0 && sd_valid_deps(o2) { sd_clear_direct_deps(o2); ctl.push(o2); }
                        }
                    }
                }
                continue;
            }
            slp_lk_pop_back(SH_SBUN, v as i64);
        }
        slp_sb[bundle].m_n = 0;
        slp_sb[bundle].bs = -1;
        if ctl.len > 0 {
            sh_clear(SH_TMP4);
            slp_calculate_dependencies(bs, -1, false, ctl);
        }
        return -2;
    }
    return bundle;
}
fn slp_block_name(bb: i32) -> const u8[:] { if vals[bb].name >= 0 { sbytes(vals[bb].name) } else { "" } }

// scheduleBlock(R, BS)
fn slp_schedule_block(bs: i32) {
    if slp_bs[bs].start < 0 { return; }
    if slp_dbg_on { errs("SLP: schedule block "); errs(slp_block_name(slp_bs[bs].bb)); errs("\n"); slp_dbg_flush(); }
    slp_reset_schedule(bs);
    var idx: i32 = 0;
    let end = slp_bs[bs].end;
    var i = slp_bs[bs].start;
    while i >= 0 && i != end {
        let c0 = slp_bundles_head(i);
        if c0 >= 0 {
            let sd = slp_get_sd(bs, i);
            if sd >= 0 && sd_valid_deps(sd) && slp_has_cds_of_inst(bs, i) { sd_clear_direct_deps(sd); }
            var c = c0;
            while c >= 0 {
                let b = slp_lk[c].x;
                c = slp_lk[c].next;
                slp_sb[b].prio = idx;
                idx++;
                let te = slp_sb[b].te;
                if te >= 0 && sb_valid_deps(b) && slp_te[te].ui_te >= 0 {
                    let u = slp_te[te].ui_te;
                    var hit = false;
                    if slp_te[u].state == TE_VECTORIZE && slp_te[u].no_sched {
                        for v in te_scalars(u) { if te_is_expanded_binop(u, v) { hit = true; break; } }
                    }
                    if slp_te[te].ui_edge < 0 && te_is_gather(u) { hit = true; }
                    if hit { for k in sb_n(b) { let m = sb_member(b, k); if !slp_sd[m].cd { sd_clear_direct_deps(m); } } }
                }
                if !sb_valid_deps(b) { sh_clear(SH_TMP4); slp_calculate_dependencies(bs, b, false, slp_no_ctl()); }
            }
            var cds: i32[>..<] = [];
            slp_cds_of_inst(bs, i, cds);
            var k = cds.len;
            while k > 0 {
                k--;
                let b = slp_sd[cds[k]].cb;
                slp_sb[b].prio = idx;
                idx++;
                if !sb_valid_deps(b) { sh_clear(SH_TMP4); slp_calculate_dependencies(bs, b, false, slp_no_ctl()); }
            }
            i = inst_next(i);
            continue;
        }
        var cdu: i32[>..<] = [];
        slp_cd_users(bs, i, cdu);
        let sd = slp_get_sd(bs, i);
        if sd >= 0 {
            slp_sd[sd].prio = idx;
            idx++;
            var need = cdu.len > 0;
            if !need {
                var c = slp_lk_head(SH_V2G, i as i64);
                while c >= 0 {
                    let t = slp_lk[c].x;
                    c = slp_lk[c].next;
                    if te_has_state(t) && te_has_copyable_elements(t) && te_is_copyable_element(t, i) { need = true; break; }
                }
            }
            if need {
                sd_clear_direct_deps(sd);
                var one: i32[1] = [sd];
                sh_clear(SH_TMP4);
                slp_calculate_dependencies(bs, -1, false, one[..]);
            }
        }
        var k = cdu.len;
        while k > 0 {
            k--;
            let b = slp_sd[cdu[k]].cb;
            slp_sb[b].prio = idx;
            idx++;
            if !sb_valid_deps(b) { sh_clear(SH_TMP4); slp_calculate_dependencies(bs, b, false, slp_no_ctl()); }
        }
        i = inst_next(i);
    }
    slp_prio_mode = true;
    slp_prio_set.clear();
    slp_initial_fill_ready_list(bs);
    var last = end;
    sh_clear(SH_TMP5);   // Scheduled
    while slp_prio_set.len > 0 {
        var bi: i64 = 0;
        for k in slp_prio_set.len { if ent_prio(slp_prio_set[k]) > ent_prio(slp_prio_set[bi]) { bi = k; } }
        let picked = slp_prio_set[bi];
        for k in (bi + 1)..slp_prio_set.len { slp_prio_set[k - 1] = slp_prio_set[k]; }
        slp_prio_set.pop();
        if ent_is_bundle(picked) {
            let b = ent_bundle(picked);
            let te = slp_sb[b].te;
            for k in sb_n(b) {
                let pi = slp_sd[sb_member(b, k)].inst;
                let is_cp = te_is_copyable_element(te, pi);
                if is_cp && slp_get_sd(bs, pi) >= 0 { continue; }
                if !is_cp && !sh_add(SH_TMP5, pi as i64, 0) { continue; }
                if inst_next(pi) != last { inst_move_after(pi, inst_prev(last)); slots_invalidate(); }
                last = pi;
            }
            if te_has_copyable_elements(te) {
                let m = te_main(te);
                for v in te_scalars(te) {
                    if !is_inst(v) { continue; }
                    if !slp_has_one_use(v) && te_is_copyable_element(te, v) && inst_parent(v) == inst_parent(m) &&
                       slp_does_not_need_to_be_scheduled(v) && !sis_is_non_schedulable(te_s(te), v) {
                        inst_move_before_preserving(v, last);
                        slots_invalidate();
                    }
                }
            }
            if sh_get(SH_E2LI, te as i64, 0, -1) < 0 { sh_set(SH_E2LI, te as i64, 0, last as i64); }
        } else {
            let pi = slp_sd[picked].inst;
            if inst_next(pi) != last { inst_move_after(pi, inst_prev(last)); slots_invalidate(); }
            last = pi;
        }
        slp_schedule_entity(bs, sis_invalid(), picked);
    }
    slp_prio_mode = false;
    slp_bs[bs].start = -1;
}
var slp_no_ctl_buf: i32[1];
fn slp_no_ctl() -> const i32[:] { slp_no_ctl_buf[..0] }
