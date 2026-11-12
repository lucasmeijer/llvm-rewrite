// MoveAutoInit: port of llvm/lib/Transforms/Utils/MoveAutoInit.cpp (MoveAutoInitPass).
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import calls;
import flags;
import domtree;
import aa;
import memloc;
import memoryssa;
import mssaupdater;
import memintr;
import vt;
import tli;
import misc_util;

fn ma_has_auto_init(i: i32) -> bool {
    let m = inst_get_md(i, md_kind_id("annotation"));
    if m < 0 { return false; }
    for k in mds[m].nops as i64 {
        let o = md_op(m, k);
        if o >= 0 && mds[o].kind == MK_STRING && sbytes(mds[o].extra) == "auto-init" { return true; }
    }
    return false;
}

// usersDominator: -1 = nullptr
fn ma_users_dominator(ml: ML, i: i32) -> i32 {
    var cur: i32 = -1;
    let ima = mssa_access_of(i);
    let q = aq_push(CA_SIMPLE);
    let thr = flag_int("move-auto-init-threshold", 128);
    var visited: i32[>..<] = [];
    var wl: i32[>..<] = [];
    var u = mssa_first_use(ima);
    while u >= 0 { wl.push(mssa_use_user(u)); u = mssa_use_next(u); }
    while wl.len > 0 {
        let ma = wl.pop();
        var seen = false;
        for x in visited { if x == ma { seen = true; break; } }
        if seen { continue; }
        visited.push(ma);
        if visited.len > thr { aq_pop(q); return -1; }
        var found = false;
        let k = macc[ma].kind;
        if k == MAK_DEF || k == MAK_USE {
            let mi = macc[ma].inst;
            if aa_inst_loc_mr(mi, ml, q) != MR_NO && !inst_is_lifetime_start_or_end(mi) && mi != i {
                found = true;
                cur = if cur >= 0 { dt_find_ncd(DT_DOM, cur, inst_parent(mi)) } else { inst_parent(mi) };
            }
        }
        if !found {
            var u2 = mssa_first_use(ma);
            while u2 >= 0 { wl.push(mssa_use_user(u2)); u2 = mssa_use_next(u2); }
        }
    }
    aq_pop(q);
    return cur;
}

fn move_auto_init_run(fv: i32) -> u32 {
    tli_cur_fn = fv;
    dt_get(fv, DT_DOM);
    mssa_get(fv);
    let entry = func_entry(fv);
    var job_i: i32[>..<] = [];
    var job_b: i32[>..<] = [];
    var i = block_first(entry);
    while i >= 0 {
        let cur = i;
        i = inst_next(i);
        if !ma_has_auto_init(cur) { continue; }
        var ml = ml_null();
        if iop(cur) == OP_CALL && mi_is_mem_intrinsic(cur) { ml = ml_for_dest(cur); }
        else if iop(cur) == OP_STORE { ml = ml_get(cur); }
        else { continue; }
        let uo = get_underlying_object(ml.ptr, 10);
        if !(is_inst(uo) && iop(uo) == OP_ALLOCA) { continue; }
        if inst_is_volatile(cur) { continue; }
        var ud = ma_users_dominator(ml, cur);
        if ud < 0 || ud == entry { continue; }
        // the transitive successors of UsersDominator, and whether it is on a cycle
        vs_clear(VS_PASS0);
        var wl: i32[>..<] = [];
        for k in block_nsucc(ud) { wl.push(block_succ(ud, k)); }
        var has_cycle = false;
        while wl.len > 0 {
            let cb = wl.pop();
            if cb == ud { has_cycle = true; }
            for k in block_nsucc(cb) {
                let s = block_succ(cb, k);
                if !vs_add(VS_PASS0, s) { continue; }
                wl.push(s);
            }
        }
        if has_cycle {
            var head = ud;
            loop {
                let up = unique_pred_of_mu(head);
                if up < 0 { break; }
                head = up;
            }
            if head == entry { continue; }
            var domp: i32 = -1;
            each_pred(head) { p =>
                if !vs_has(VS_PASS0, p) && dt_has_node(DT_DOM, p) && dt_dominates_block(DT_DOM, p, head) {
                    domp = if domp >= 0 { dt_find_ncd(DT_DOM, domp, p) } else { p };
                }
            };
            if domp < 0 || domp == entry { continue; }
            ud = domp;
        }
        loop {
            let f = first_non_phi(ud);
            if f < 0 || iop(f) != OP_CATCHSWITCH { break; }
            each_pred(ud) { p => if dt_has_node(DT_DOM, p) { ud = dt_find_ncd(DT_DOM, ud, p); } };
        }
        if ud != entry { job_i.push(cur); job_b.push(ud); }
    }
    if job_i.len == 0 { return PA_ALL; }
    msu_reset();
    var k = job_i.len - 1;
    while k >= 0 {
        let x = job_i[k];
        let b = job_b[k];
        let pos = mu_first_insertion_pt(b);
        inst_move_impl(x, b, pos, true, false);
        msu_move_to_place(mssa_access_of(x), inst_parent(x), MSP_BEGINNING);
        k--;
    }
    if flag_bool("verify-memoryssa", false) { mssa_verify(fv); }
    return PA_CFG | ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_MEMORYSSA);
}

// BasicBlock::getUniquePredecessor
fn unique_pred_of_mu(bb: i32) -> i32 {
    var r: i32 = -1;
    var bad = false;
    each_pred(bb) { p => if r >= 0 && r != p { bad = true; } r = p; };
    return if bad { -1 } else { r };
}
