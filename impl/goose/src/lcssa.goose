// LCSSA: loop-closed SSA form (the lcssa pass and formLCSSA* for other passes).
// Port of llvm/lib/Transforms/Utils/LCSSA.cpp (formLCSSAForInstructions, computeBlocksDominatingExits,
// formLCSSA, formLCSSARecursively, LCSSAPass::run), with the SSAUpdater (ssaupdater.goose). Not ported (fail
// loudly): ScalarEvolution updates.
import std;
import ir;
import irutil;
import instinfo;
import analyses;
import domtree;
import loopinfo;
import ssaupdater;
import dinfo;
import scev;
import scev_create;

fn lcssa_new_phi(ty: i32, reserve: i64) -> i32 {
    let pn = new_inst(OP_PHI, ty, reserve);
    vals[pn].nops = 0;
    return pn;
}

// The findDbgValues(I) loop of formLCSSAForInstructions: #dbg_value/#dbg_assign records outside the loop that
// use I get the value available in their block (DbgVariableRecord::replaceVariableLocationOp).
fn lcssa_rewrite_dbg_values(iv: i32, ibb: i32, l: i32, added: const i32[:]) {
    var recs: i32[>..<] = [];
    find_dbg_values(iv, recs);
    for r in recs {
        let owner = dbgrecs[r].owner;
        if owner == -1 { fatal("LCSSA: a debug record without a marker uses a rewritten value"); }
        // DVR->getMarker()->getParent(): a block's trailing marker too (changeToUnreachable leaves the erased
        // terminator's records there)
        let ubb = if owner >= 0 { inst_parent(owner) } else { -2 - owner };
        if ibb == ubb || loop_contains(l, ubb) { continue; }
        let v = if added.len == 1 { added[0] } else { ssa_find_value_for_block(ubb) };
        if v < 0 { continue; }
        let loc = dbgrecs[r].loc;
        if mds[loc].kind != MK_VALUE && mds[loc].kind != MK_DIARGLIST { fatal("LCSSA: unexpected debug record location"); }
        dbg_set_loc(r, m2r_md_replace_value(loc, iv, v));
    }
}

var lcssa_se: bool = false;
var lcssa_collect: bool = false;
var lcssa_phis_to_remove: i32[>..<];
var lcssa_inserted: i32[>..<];

// formLCSSAForInstructions(Worklist, DT, LI, SE, PHIsToRemove, InsertedPHIs)
fn form_lcssa_for_instructions(worklist: i32[>..<]&) -> bool {
    var changed = false;
    var to_rewrite: i32[>..<] = [];     // use ids
    var exits: i32[>..<] = [];
    var added: i32[>..<] = [];
    var post: i32[>..<] = [];
    var to_remove: i32[>..<] = [];      // LocalPHIsToRemove (SetVector)
    var preds: i32[>..<] = [];
    while worklist.len > 0 {
        to_rewrite.clear();
        let iv = worklist.pop();
        let ibb = inst_parent(iv);
        let fv = block_func(ibb);
        let l = li_loop_for(ibb);
        if l < 0 { fatal("internal: LCSSA instruction is not in a loop"); }
        loop_exit_blocks(l, exits);
        if exits.len == 0 { continue; }
        var u = vals[iv].first_use;
        while u >= 0 {
            let nu = uses[u].next;
            let user = uses[u].user;
            var ubb = inst_parent(user);
            if !dt_has_node(DT_DOM, ubb) {
                use_set(u, c_poison(vals[iv].ty));
                u = nu;
                continue;
            }
            if iop(user) == OP_PHI { ubb = use_aux[u]; }
            if ibb != ubb && !loop_contains(l, ubb) { to_rewrite.push(u); }
            u = nu;
        }
        if to_rewrite.len == 0 { continue; }
        // the value of an invoke is only available in its normal destination
        let dombb = if iop(iv) == OP_INVOKE { term_succ(iv, 0) } else { ibb };
        let domn = if dt_has_node(DT_DOM, dombb) { dombb } else { -1 };
        added.clear();
        post.clear();
        ssa_init(vals[iv].ty, val_name(iv));
        let has_scev = lcssa_se && sc_valid && sc_is_scevable(vals[iv].ty) && sc_get_existing(iv) >= 0;
        for eb in exits {
            let en = if dt_has_node(DT_DOM, eb) { eb } else { -1 };
            if !dt_dominates_nodes(fv, DT_DOM, domn, en) { continue; }
            if ssa_has_value_for_block(eb) { continue; }
            preds.clear();
            each_pred(eb) { p => preds.push(p); };
            let pn = lcssa_new_phi(vals[iv].ty, preds.len);
            let f = block_first(eb);
            if f >= 0 { inst_insert_before_head(pn, f); } else { block_append_inst(eb, pn); }
            if lcssa_collect { lcssa_inserted.push(pn); }
            var nm: u8[>..] = [];
            nm.append(val_name(iv));
            nm.append(".lcssa");
            set_name(pn, nm);
            let dl = inst_get_md(iv, 0);
            if dl >= 0 { inst_set_md(pn, 0, dl); }
            for p in preds {
                let k = push_op(pn, iv);
                phi_set_block(pn, k, p);
                if !loop_contains(l, p) { to_rewrite.push(vals[pn].ops + k as i32); }
            }
            added.push(pn);
            ssa_add_available_value(eb, pn);
            let ol = li_loop_for(eb);
            if ol >= 0 && !loop_contains_loop(l, ol) { post.push(pn); }
            // a cached SCEV for the original instruction: the new LCSSA phi gets one too
            if has_scev { sc_get_scev(pn); }
        }
        for u2 in to_rewrite {
            let user = uses[u2].user;
            var ubb = inst_parent(user);
            if iop(user) == OP_PHI { ubb = use_aux[u2]; }
            let f = block_first(ubb);
            if f >= 0 && iop(f) == OP_PHI && position(exits, ubb) >= 0 { use_set(u2, f); continue; }
            if added.len == 1 { use_set(u2, added[0]); continue; }
            ssa_rewrite_use(u2);
        }
        if dbgrecs.len > 0 { lcssa_rewrite_dbg_values(iv, ibb, l, added); }
        for pn in ssa_inserted {
            let ol = li_loop_for(inst_parent(pn));
            if ol >= 0 && !loop_contains_loop(l, ol) { post.push(pn); }
            if lcssa_collect { lcssa_inserted.push(pn); }
        }
        for pn in post { if vals[pn].first_use >= 0 { worklist.push(pn); } }
        for pn in added { if vals[pn].first_use < 0 && position(to_remove, pn) < 0 { to_remove.push(pn); } }
        changed = true;
    }
    if lcssa_collect { for pn in to_remove { lcssa_phis_to_remove.push(pn); } }
    else { for pn in to_remove { if !is_dead(pn) && vals[pn].first_use < 0 { inst_erase_from_parent(pn); } } }
    return changed;
}

// computeBlocksDominatingExits
fn blocks_dominating_exits(l: i32, exits: const i32[:], out: i32[>..<]&) {
    out.clear();
    var wl: i32[>..<] = [];
    for e in exits { wl.push(e); }
    while wl.len > 0 {
        let bb = wl.pop();
        if loop_header(l) == bb { continue; }
        let id = dt_idom(DT_DOM, bb);
        if !loop_contains(l, id) { continue; }
        if position(out, id) < 0 { out.push(id); wl.push(id); }
    }
}

// formLCSSA(L, DT, LI, SE)
fn form_lcssa(l: i32) -> bool {
    var exits: i32[>..<] = [];
    loop_exit_blocks(l, exits);
    if exits.len == 0 { return false; }
    var doms: i32[>..<] = [];
    blocks_dominating_exits(l, exits, doms);
    var wl: i32[>..<] = [];
    for bb in doms {
        if li_loop_for(bb) != l { continue; }
        var i = block_first(bb);
        while i >= 0 {
            let fu = vals[i].first_use;
            var skip = fu < 0;
            if !skip && uses[fu].next < 0 {
                let ub = uses[fu].user;
                if inst_parent(ub) == bb && iop(ub) != OP_PHI { skip = true; }
            }
            if !skip && vals[i].ty != T_TOKEN { wl.push(i); }
            i = inst_next(i);
        }
    }
    return form_lcssa_for_instructions(wl);
}

// formLCSSARecursively
recursive fn form_lcssa_recursively(l: i32) -> bool {
    var changed = false;
    for k in loop_nsubs(l) { if form_lcssa_recursively(loop_sub(l, k)) { changed = true; } }
    if form_lcssa(l) { changed = true; }
    return changed;
}

// LCSSAPass::run
fn lcssa_run(fv: i32) -> u32 {
    li_get(fv);
    dt_get(fv, DT_DOM);
    // AM.getCachedResult<ScalarEvolutionAnalysis>(F)
    lcssa_se = scev_valid(fv);
    var changed = false;
    for k in li_ntop(fv) { if form_lcssa_recursively(li_top(fv, k)) { changed = true; } }
    lcssa_se = false;
    if !changed { return PA_ALL; }
    return PA_CFG | ((1 as u32) << A_SCEV) | ((1 as u32) << A_MEMORYSSA);
}
