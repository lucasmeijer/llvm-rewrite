// SLPVectorizer: BoUpSLP::BlockScheduling. Port of llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp's
// ScheduleEntity / ScheduleData / ScheduleBundle classes and BlockScheduling (class body around lines 5000-6460:
// clear, getScheduleData, getScheduleBundles, isInSchedulingRegion, schedule, initialFillReadyList; out of line
// 25642-26675: buildBundle, tryScheduleBundle, extendSchedulingRegion, initScheduleData, calculateDependencies,
// resetSchedule) and BoUpSLP::isAliased.
//
// Copyable elements (ScheduleCopyableData) are not ported: InstructionsCompatibilityAnalysis fails loudly before a
// copyable state reaches the scheduler, so every copyable-data map is empty here and the queries over them
// (getScheduleCopyableData*, areAllOperandsReplacedByCopyableData) answer "none" / false.
//
// Entities: a ScheduleData is its id (>= 0) in `slp_sd`, a ScheduleBundle is -(id + 1) of `slp_sb`. A block's
// ReadyInsts (a SetVector) is the subsequence of `slp_ready` with its block-scheduling id.
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
             region_limit: i64, region_id: i32 }
struct SSD { inst: i32, next_ls: i32, region: i32, deps: i32, unsched: i32, sched: bool,
             mem_h: i32, mem_t: i32, ctl_h: i32, ctl_t: i32 }
struct SSB { m_at: i32, m_n: i32, te: i32, sched: bool, bs: i32 }
struct SReady { bs: i32, ent: i32, alive: bool }
var slp_bs: SBS[>..];            // BlocksSchedules (MapVector order = creation order)
var slp_sd: SSD[>..];
var slp_sb: SSB[>..];
var slp_sbm: i32[>..];           // bundle members (schedule data ids)
var slp_dl: SLk[>..];            // memory / control dependency lists
var slp_ready: SReady[>..<];
var slp_ready_alive: i64 = 0;
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
}
fn slp_schedule_budget() -> i64 { flag_int("slp-schedule-budget", 100000) }

// BlockScheduling::clear() for every block of BlocksSchedules (deleteTree)
fn slp_sched_clear_all() {
    sh_clear(SH_SBUN);
    sh_clear(SH_READY);
    slp_ready.clear();
    slp_ready_alive = 0;
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
    }
}
// BlocksSchedules[BB] (created on first use)
fn slp_get_bs(bb: i32) -> i32 {
    let b = sh_get(SH_BSMAP, bb as i64, 0, -1) as i32;
    if b >= 0 { return b; }
    let n = slp_bs.len as i32;
    slp_bs.push(SBS { bb: bb, start: -1, end: -1, first_ls: -1, last_ls: -1, stack_save: false, region_size: 0,
                      region_limit: slp_schedule_budget(), region_id: 1 });
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
        for k in sb_n(b) { if k > 0 { errs(", "); } slp_dv(slp_sd[sb_member(b, k)].inst); }
        errs("]");
    } else {
        slp_dv(slp_sd[e].inst);
    }
}

// ---------------------------------------------------------------- ReadyInsts (SetVector)
fn slp_ready_insert(bs: i32, e: i32) {
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
// ProcessBundleMember(BundleMember, Bundles): `tes` are the tree entries of the bundles (-1 = a bundle without one)
fn slp_process_bundle_member(bs: i32, s: SIS, member: i32, tes: const i32[:]) {
    let inn = slp_sd[member].inst;
    if tes.len > 0 {
        // OperandsUses: operand instruction -> remaining uses (SH_TMP1), TotalOpCount
        sh_clear(SH_TMP1);
        var total: i64 = 0;
        for k in nops(inn) {
            let o = op(inn, k);
            if !is_inst(o) { continue; }
            var extra: i64 = 1;
            for te in tes {
                if te >= 0 { if te_is_expanded_binop(te, inn) { extra++; } }
                else if sis_is_expanded_binop(s, inn) { extra++; }
            }
            sh_set(SH_TMP1, o as i64, 0, sh_get(SH_TMP1, o as i64, 0, 0) + extra);
            total += extra;
        }
        sh_clear(SH_TMP2);   // Checked: (entity, OpIdx)
        for te in tes {
            if total == 0 { break; }
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
            let opsd = slp_get_sd(bs, i);
            if opsd >= 0 { slp_decr_unsched(bs, opsd, false); }
        }
    }
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
fn slp_build_bundle(bs: i32, vl: const i32[:], s: SIS) -> i32 {
    let b = slp_sb.len as i32;
    slp_sb.push(SSB { m_at: slp_sbm.len as i32, m_n: 0, te: -1, sched: false, bs: bs });
    for v in vl {
        if sis_is_non_schedulable(s, v) { continue; }
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
                              mem_h: -1, mem_t: -1, ctl_h: -1, ctl_t: -1 });
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
    fn process_node(member: i32) {
        if sd_valid_deps(member) { return; }
        if slp_dbg_on { errs("SLP:       update deps of "); slp_dbg_ent(member); errs("\n"); slp_dbg_flush(); }
        slp_sd[member].deps = 0;
        sd_reset_unsched(member);
        let inst = slp_sd[member].inst;
        // def-use chain dependencies
        var u = vals[inst].first_use;
        while u >= 0 {
            let usr = uses[u].user;
            u = uses[u].next;
            if is_inst_op(usr, OP_PHI) { continue; }
            let usd = slp_get_sd(bs, usr);
            if usd < 0 { continue; }
            var extra: i32 = 1;
            var c = slp_tree_entries_head(usr);
            while c >= 0 { if te_is_expanded_binop(slp_lk[c].x, usr) { extra++; } c = slp_lk[c].next; }
            if sh_has(SH_TMP4, usr as i64, 0) { extra++; }
            slp_sd[member].deps += extra;
            if !slp_sd[usd].sched { sd_incr_unsched(member, extra); }
            if !sd_valid_deps(usd) || (insert_ready && sd_is_ready(usd)) { wl.push(usd); }
        }
        sh_clear(SH_TMP3);
        fn make_control_dependent(i: i32) {
            if !sh_add(SH_TMP3, i as i64, 0) { return; }
            let dd = slp_get_sd(bs, i);
            if dd < 0 { fatal("internal: SLP: must be in schedule window"); }
            sd_add_dep(dd, true, member);
            slp_sd[member].deps += 1;
            if !slp_sd[dd].sched { sd_incr_unsched(member, 1); }
            if !sd_valid_deps(dd) || (insert_ready && sd_is_ready(dd)) { wl.push(dd); }
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
                if !sd_valid_deps(dd) || (insert_ready && sd_is_ready(dd)) { wl.push(dd); }
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
// resetSchedule()
fn slp_reset_schedule(bs: i32) {
    var i = slp_bs[bs].start;
    while i >= 0 && i != slp_bs[bs].end {
        let sd = slp_get_sd(bs, i);
        if sd >= 0 { slp_sd[sd].sched = false; sd_reset_unsched(sd); }
        i = inst_next(i);
    }
    for b in slp_sb.len { if slp_sb[b].bs == bs && sb_in_region(bs, b as i32) { slp_sb[b].sched = false; } }
    slp_ready_clear(bs);
}

// tryScheduleBundle(VL, SLP, S, EI): -2 = std::nullopt (cannot schedule), -1 = nullptr (no scheduling needed),
// otherwise the bundle
fn slp_try_schedule_bundle(bs: i32, vl: const i32[:], s: SIS, ui_te: i32) -> i32 {
    if iop(s.main) == OP_PHI || slp_is_vector_like_inst_with_const_ops(s.main) { return -1; }
    if s.copy { slp_fail("scheduling of copyable elements (ScheduleCopyableData)"); }
    let no_sched = slp_does_not_need_to_schedule(vl) || slp_all_non_schedulable(s, vl);
    // (the checks for copyable elements in this node or in PHI-operand nodes never apply: copyables are not built)
    if no_sched {
        for v in vl {
            if !is_inst(v) { continue; }
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
        }
        return -1;
    }
    let old_end = slp_bs[bs].end;
    if slp_dbg_on { errs("SLP:  bundle: "); slp_dv(s.main); errs("\n"); slp_dbg_flush(); }
    fn try_impl(reschedule0: bool, bundle: i32) {
        var reschedule = reschedule0;
        var ctl: i32[>..<] = [];
        if old_end >= 0 && slp_bs[bs].end != old_end {
            var i = slp_bs[bs].start;
            while i >= 0 && i != slp_bs[bs].end {
                let sd = slp_get_sd(bs, i);
                if sd >= 0 { sd_clear_deps(sd); }
                i = inst_next(i);
            }
            reschedule = true;
        }
        sh_clear(SH_TMP4);
        var any_expanded = false;
        for v in vl { if sis_is_expanded_binop(s, v) { sh_add(SH_TMP4, v as i64, 0); any_expanded = true; } }
        if bundle >= 0 && sb_n(bundle) > 0 {
            if any_expanded {
                // CheckIfNeedToClearDeps(Bundle) without copyable data
                for k in sb_n(bundle) {
                    let sd = sb_member(bundle, k);
                    let inst = slp_sd[sd].inst;
                    if !sis_is_expanded_binop(s, inst) { continue; }
                    for j in nops(inst) {
                        let opsd = slp_get_sd(bs, op(inst, j));
                        if opsd >= 0 && sd_valid_deps(opsd) {
                            sd_clear_direct_deps(opsd);
                            ctl.push(opsd);
                        }
                    }
                }
            }
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
        let m = slp_get_sd(bs, v);
        if m < 0 { continue; }
        slp_ready_remove(bs, m);
        var c = slp_bundles_head(v);
        while c >= 0 { slp_ready_remove(bs, ent_of_bundle(slp_lk[c].x)); c = slp_lk[c].next; }
        if !sis_is_expanded_binop(s, v) && !slp_sd[m].sched { continue; }
        if slp_dbg_on { errs("SLP:  reset schedule because "); slp_dbg_ent(m); errs(" was already scheduled\n"); slp_dbg_flush(); }
        reschedule = true;
    }
    let bundle = slp_build_bundle(bs, vl, s);
    try_impl(reschedule, bundle);
    if !sb_is_ready(bundle) {
        for k in sb_n(bundle) {
            let bd = sb_member(bundle, k);
            if sd_is_ready(bd) {
                var c = slp_bundles_head(slp_sd[bd].inst);
                if c < 0 { slp_ready_insert(bs, bd); continue; }
                while c >= 0 { let b = slp_lk[c].x; c = slp_lk[c].next; if sb_is_ready(b) { slp_ready_insert(bs, ent_of_bundle(b)); } }
            }
        }
        // ScheduledBundlesList.pop_back(): the bundle is gone
        var ctl: i32[>..<] = [];
        for v in vl {
            if sis_is_non_schedulable(s, v) { continue; }
            if sis_is_expanded_binop(s, v) {
                for j in nops(v) {
                    let opsd = slp_get_sd(bs, op(v, j));
                    if opsd >= 0 && sd_valid_deps(opsd) { sd_clear_direct_deps(opsd); ctl.push(opsd); }
                }
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
