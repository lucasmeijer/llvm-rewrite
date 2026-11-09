// LoopInstSimplify: port of llvm/lib/Transforms/Scalar/LoopInstSimplify.cpp (whole).
// ToSimplify / Next are VS_PASS0 / VS_PASS1 (swapped by index), VisitedPHIs is VS_PASS2.
import std;
import ir;
import irutil;
import instinfo;
import analyses;
import flags;
import domtree;
import loopinfo;
import memoryssa;
import mssaupdater;
import instsimplify;
import vt;
import assume;
import tli;
import local;
import scev_expander;
import loop_utils;

fn lis_simplify_loop_inst(l: i32, use_mssau: bool) -> bool {
    let fv = block_func(loop_header(l));
    var to_simplify = VS_PASS0;
    var next = VS_PASS1;
    var n_to: i64 = 0;
    var n_next: i64 = 0;
    vs_clear(to_simplify);
    vs_clear(next);
    vs_clear(VS_PASS2);
    var dead: i32[>..<] = [];
    var rpo: i32[>..<] = [];
    lu_loop_rpo(l, rpo);
    let verify = use_mssau && flag_bool("verify-memoryssa", false);
    var changed = false;
    loop {
        if verify { mssa_verify(fv); }
        for bb in rpo {
            var i = block_first(bb);
            while i >= 0 {
                let ni = inst_next(i);
                if iop(i) == OP_PHI { vs_add(VS_PASS2, i); }
                if vals[i].first_use < 0 {
                    if is_instruction_trivially_dead(i) { dead.push(i); }
                    i = ni;
                    continue;
                }
                let first = n_to == 0;
                if !first && !vs_has(to_simplify, i) { i = ni; continue; }
                let v = simplify_instruction(i);
                if v < 0 || !li_replacement_preserves_lcssa(i, v) { i = ni; continue; }
                var u = vals[i].first_use;
                while u >= 0 {
                    let nu = uses[u].next;
                    let us = uses[u].user;
                    use_set(u, v);
                    u = nu;
                    if !dt_has_node(DT_DOM, inst_parent(us)) { continue; }
                    if iop(us) == OP_PHI && vs_has(VS_PASS2, us) {
                        if vs_add(next, us) { n_next++; }
                        continue;
                    }
                    if !first && loop_contains(l, inst_parent(us)) {
                        if vs_add(to_simplify, us) { n_to++; }
                    }
                }
                if use_mssau && is_inst(v) {
                    let ma = mssa_access_of(i);
                    if ma >= 0 {
                        let rma = mssa_access_of(v);
                        if rma >= 0 { msu_rauw(ma, rma); }
                    }
                }
                if is_instruction_trivially_dead(i) { dead.push(i); }
                changed = true;
                i = ni;
            }
        }
        if dead.len > 0 {
            changed = true;
            lu_recursively_delete_dead(dead, use_mssau);
        }
        if verify { mssa_verify(fv); }
        if n_next == 0 { break; }
        let t = next; next = to_simplify; to_simplify = t;
        n_to = n_next;
        vs_clear(next);
        n_next = 0;
        vs_clear(VS_PASS2);
        dead.clear();
    }
    return changed;
}

// LoopInstSimplifyPass::run
fn loop_instsimplify_pass_run(l: i32, use_mssa: bool) -> u32 {
    let fv = block_func(loop_header(l));
    tli_cur_fn = fv;
    local_have_tli = true;
    vt_invalidate_assumes();
    ac_invalidate();
    if use_mssa {
        msu_reset();
        if flag_bool("verify-memoryssa", false) { mssa_verify(fv); }
    }
    if !lis_simplify_loop_inst(l, use_mssa) { return PA_ALL; }
    var pa = PA_CFG | ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_LOOPS) | ((1 as u32) << A_SCEV);
    if use_mssa { pa |= (1 as u32) << A_MEMORYSSA; }
    return pa;
}
