// ScalarEvolution: one result per function (ScalarEvolutionAnalysis results in the FunctionAnalysisManager).
// The loaded instance lives in the scev*.goose globals (sc_fv); the others are snapshots of those tables in the
// archive below (archive.goose), swapped in when their function asks for its ScalarEvolution or a pass starts on
// it (fam_enter), so value-handle callbacks and forget* calls always reach the result of the function being
// changed. Every table that scev_reset() clears is saved, except the scratch stacks, which are empty between
// queries. Generated table list: keep it in sync with scev_reset / scev_reset_* when adding a cache.
import std;
import ir;
import archive;
import scev;
import scev_create;
import scev_btc;
import scev_eval;
import scev_guards;
import scev_lt;
import scev_pred;
import scev_range;

let SCA_NT: i64 = 37;
var sca_own: i32[>..<];     // per snapshot: its function (-1 = dead)
var sca_gl: i32[>..<];      // per snapshot: glob index of the function
var sca_dir: i64[>..<];     // per snapshot: SCA_NT (start, length) pairs
var sca_slot: i32[>..];     // glob index -> snapshot + 1 (0 = none)
var sca_dead: i64 = 0;
var sca_scev: Scev[>..<];
var sca_i32: i32[>..<];
var sca_side: ScSide[>..<];
var sca_ent: ENT[>..<];
var sca_bti: BTI[>..<];
var sca_lnode: LNode[>..<];
var sca_side2: ScSide2[>..<];
var sca_ats: AtScope[>..<];
var sca_gi: GInfo[>..<];
var sca_pred: SPred[>..<];
var sca_cm: ScCm[>..<];
var sca_hs: HSlot[>..<];
var sca_i64: i64[>..<];

fn sca_find(fv: i32) -> i64 {
    let g = glob_of(fv) as i64;
    if g >= sca_slot.len { return -1; }
    return (sca_slot[g] as i64) - 1;
}
fn scev_archived(fv: i32) -> bool { sca_find(fv) >= 0 }
fn sca_kill(s: i64) {
    sca_slot[sca_gl[s]] = 0;
    sca_own[s] = -1;
    sca_dead++;
}
// FAM.invalidate of an archived result
fn scev_archive_drop(fv: i32) { let s = sca_find(fv); if s >= 0 { sca_kill(s); } }

// the loaded result goes to the archive (another function's is about to be loaded)
fn scev_stash() {
    if !sc_valid { return; }
    let fv = sc_fv;
    sc_valid = false;
    if sca_dead > 16 && sca_dead > sca_own.len - sca_dead { sca_compact(); }
    let old = sca_find(fv);
    if old >= 0 { sca_kill(old); }
    let s = ar_new(sca_own, sca_dir, SCA_NT, fv);
    let g = glob_of(fv);
    sca_gl.push(g);
    while sca_slot.len <= (g as i64) { sca_slot.push(0); }
    sca_slot[g] = (s + 1) as i32;
    var sc: i64[>..<] = [];
    ar_put(sca_dir, SCA_NT, s, 0, sca_scev, scevs);
    ar_put(sca_dir, SCA_NT, s, 1, sca_i32, sc_ops);
    ar_put(sca_dir, SCA_NT, s, 2, sca_i32, sc_tab);
    ar_put(sca_dir, SCA_NT, s, 3, sca_i32, sc_predl);
    ar_put(sca_dir, SCA_NT, s, 4, sca_i32, sc_users_head);
    ar_put(sca_dir, SCA_NT, s, 5, sca_i32, sc_values_head);
    ar_put(sca_dir, SCA_NT, s, 6, sca_i32, sc_becusers_head);
    ar_put(sca_dir, SCA_NT, s, 7, sca_side, sc_side);
    ar_put(sca_dir, SCA_NT, s, 8, sca_ent, sc_ents);
    ar_put(sca_dir, SCA_NT, s, 9, sca_bti, sc_btis);
    ar_put(sca_dir, SCA_NT, s, 10, sca_lnode, sc_lpool);
    ar_put(sca_dir, SCA_NT, s, 11, sca_side2, sc_side2);
    ar_put(sca_dir, SCA_NT, s, 12, sca_ats, sc_atscopes);
    ar_put(sca_dir, SCA_NT, s, 13, sca_gi, sc_guards);
    ar_put(sca_dir, SCA_NT, s, 14, sca_pred, sc_preds);
    ar_put(sca_dir, SCA_NT, s, 15, sca_cm, sc_cm);
    ar_put(sca_dir, SCA_NT, s, 16, sca_hs, sc_vmap.slots); sc.push(sc_vmap.n); sc.push(sc_vmap.used);
    ar_put(sca_dir, SCA_NT, s, 17, sca_hs, sc_fold.slots); sc.push(sc_fold.n); sc.push(sc_fold.used);
    ar_put(sca_dir, SCA_NT, s, 18, sca_hs, sc_ldisp.slots); sc.push(sc_ldisp.n); sc.push(sc_ldisp.used);
    ar_put(sca_dir, SCA_NT, s, 19, sca_hs, sc_bdisp.slots); sc.push(sc_bdisp.n); sc.push(sc_bdisp.used);
    ar_put(sca_dir, SCA_NT, s, 20, sca_hs, sc_atscope.slots); sc.push(sc_atscope.n); sc.push(sc_atscope.used);
    ar_put(sca_dir, SCA_NT, s, 21, sca_hs, sc_atscope_users.slots); sc.push(sc_atscope_users.n); sc.push(sc_atscope_users.used);
    ar_put(sca_dir, SCA_NT, s, 22, sca_hs, sc_pending_loop_preds.slots); sc.push(sc_pending_loop_preds.n); sc.push(sc_pending_loop_preds.used);
    ar_put(sca_dir, SCA_NT, s, 23, sca_hs, sc_pending_phi_ranges.slots); sc.push(sc_pending_phi_ranges.n); sc.push(sc_pending_phi_ranges.used);
    ar_put(sca_dir, SCA_NT, s, 24, sca_hs, sc_pending_merges.slots); sc.push(sc_pending_merges.n); sc.push(sc_pending_merges.used);
    ar_put(sca_dir, SCA_NT, s, 25, sca_hs, sc_bti_map.slots); sc.push(sc_bti_map.n); sc.push(sc_bti_map.used);
    ar_put(sca_dir, SCA_NT, s, 26, sca_hs, sc_cevl_exit.slots); sc.push(sc_cevl_exit.n); sc.push(sc_cevl_exit.used);
    ar_put(sca_dir, SCA_NT, s, 27, sca_hs, sc_bti_tag.slots); sc.push(sc_bti_tag.n); sc.push(sc_bti_tag.used);
    ar_put(sca_dir, SCA_NT, s, 28, sca_hs, sc_loop_users.slots); sc.push(sc_loop_users.n); sc.push(sc_loop_users.used);
    ar_put(sca_dir, SCA_NT, s, 29, sca_hs, sc_rw_cache.slots); sc.push(sc_rw_cache.n); sc.push(sc_rw_cache.used);
    ar_put(sca_dir, SCA_NT, s, 30, sca_hs, sc_loop_props.slots); sc.push(sc_loop_props.n); sc.push(sc_loop_props.used);
    ar_put(sca_dir, SCA_NT, s, 31, sca_hs, sc_ce_vals.slots); sc.push(sc_ce_vals.n); sc.push(sc_ce_vals.used);
    ar_put(sca_dir, SCA_NT, s, 32, sca_hs, sc_gmap.slots); sc.push(sc_gmap.n); sc.push(sc_gmap.used);
    ar_put(sca_dir, SCA_NT, s, 33, sca_hs, sc_gne.slots); sc.push(sc_gne.n); sc.push(sc_gne.used);
    ar_put(sca_dir, SCA_NT, s, 34, sca_hs, sc_gpairs.slots); sc.push(sc_gpairs.n); sc.push(sc_gpairs.used);
    ar_put(sca_dir, SCA_NT, s, 35, sca_hs, sc_incoming_guards.slots); sc.push(sc_incoming_guards.n); sc.push(sc_incoming_guards.used);
    sc.push(sc_count as i64);
    sc.push(sc_first_unknown as i64);
    sc.push(sc_rw_serial as i64);
    sc.push(sc_ce_serial as i64);
    sc.push(sc_ld_epoch as i64);
    sc.push(sc_bd_epoch as i64);
    sc.push(if sc_has_guards { 1 } else { 0 });
    ar_put(sca_dir, SCA_NT, s, 36, sca_i64, sc);
}
// loads fv's archived result (the loaded one must have been stashed or dropped); false if there is none
fn scev_unstash(fv: i32) -> bool {
    let s = sca_find(fv);
    if s < 0 { return false; }
    var sc: i64[>..<] = [];
    ar_get(sca_dir, SCA_NT, s, 0, sca_scev, scevs);
    ar_get(sca_dir, SCA_NT, s, 1, sca_i32, sc_ops);
    ar_get(sca_dir, SCA_NT, s, 2, sca_i32, sc_tab);
    ar_get(sca_dir, SCA_NT, s, 3, sca_i32, sc_predl);
    ar_get(sca_dir, SCA_NT, s, 4, sca_i32, sc_users_head);
    ar_get(sca_dir, SCA_NT, s, 5, sca_i32, sc_values_head);
    ar_get(sca_dir, SCA_NT, s, 6, sca_i32, sc_becusers_head);
    ar_get(sca_dir, SCA_NT, s, 7, sca_side, sc_side);
    ar_get(sca_dir, SCA_NT, s, 8, sca_ent, sc_ents);
    ar_get(sca_dir, SCA_NT, s, 9, sca_bti, sc_btis);
    ar_get(sca_dir, SCA_NT, s, 10, sca_lnode, sc_lpool);
    ar_get(sca_dir, SCA_NT, s, 11, sca_side2, sc_side2);
    ar_get(sca_dir, SCA_NT, s, 12, sca_ats, sc_atscopes);
    ar_get(sca_dir, SCA_NT, s, 13, sca_gi, sc_guards);
    ar_get(sca_dir, SCA_NT, s, 14, sca_pred, sc_preds);
    ar_get(sca_dir, SCA_NT, s, 15, sca_cm, sc_cm);
    ar_get(sca_dir, SCA_NT, s, 36, sca_i64, sc);
    ar_get(sca_dir, SCA_NT, s, 16, sca_hs, sc_vmap.slots); sc_vmap.n = sc[0]; sc_vmap.used = sc[1];
    ar_get(sca_dir, SCA_NT, s, 17, sca_hs, sc_fold.slots); sc_fold.n = sc[2]; sc_fold.used = sc[3];
    ar_get(sca_dir, SCA_NT, s, 18, sca_hs, sc_ldisp.slots); sc_ldisp.n = sc[4]; sc_ldisp.used = sc[5];
    ar_get(sca_dir, SCA_NT, s, 19, sca_hs, sc_bdisp.slots); sc_bdisp.n = sc[6]; sc_bdisp.used = sc[7];
    ar_get(sca_dir, SCA_NT, s, 20, sca_hs, sc_atscope.slots); sc_atscope.n = sc[8]; sc_atscope.used = sc[9];
    ar_get(sca_dir, SCA_NT, s, 21, sca_hs, sc_atscope_users.slots); sc_atscope_users.n = sc[10]; sc_atscope_users.used = sc[11];
    ar_get(sca_dir, SCA_NT, s, 22, sca_hs, sc_pending_loop_preds.slots); sc_pending_loop_preds.n = sc[12]; sc_pending_loop_preds.used = sc[13];
    ar_get(sca_dir, SCA_NT, s, 23, sca_hs, sc_pending_phi_ranges.slots); sc_pending_phi_ranges.n = sc[14]; sc_pending_phi_ranges.used = sc[15];
    ar_get(sca_dir, SCA_NT, s, 24, sca_hs, sc_pending_merges.slots); sc_pending_merges.n = sc[16]; sc_pending_merges.used = sc[17];
    ar_get(sca_dir, SCA_NT, s, 25, sca_hs, sc_bti_map.slots); sc_bti_map.n = sc[18]; sc_bti_map.used = sc[19];
    ar_get(sca_dir, SCA_NT, s, 26, sca_hs, sc_cevl_exit.slots); sc_cevl_exit.n = sc[20]; sc_cevl_exit.used = sc[21];
    ar_get(sca_dir, SCA_NT, s, 27, sca_hs, sc_bti_tag.slots); sc_bti_tag.n = sc[22]; sc_bti_tag.used = sc[23];
    ar_get(sca_dir, SCA_NT, s, 28, sca_hs, sc_loop_users.slots); sc_loop_users.n = sc[24]; sc_loop_users.used = sc[25];
    ar_get(sca_dir, SCA_NT, s, 29, sca_hs, sc_rw_cache.slots); sc_rw_cache.n = sc[26]; sc_rw_cache.used = sc[27];
    ar_get(sca_dir, SCA_NT, s, 30, sca_hs, sc_loop_props.slots); sc_loop_props.n = sc[28]; sc_loop_props.used = sc[29];
    ar_get(sca_dir, SCA_NT, s, 31, sca_hs, sc_ce_vals.slots); sc_ce_vals.n = sc[30]; sc_ce_vals.used = sc[31];
    ar_get(sca_dir, SCA_NT, s, 32, sca_hs, sc_gmap.slots); sc_gmap.n = sc[32]; sc_gmap.used = sc[33];
    ar_get(sca_dir, SCA_NT, s, 33, sca_hs, sc_gne.slots); sc_gne.n = sc[34]; sc_gne.used = sc[35];
    ar_get(sca_dir, SCA_NT, s, 34, sca_hs, sc_gpairs.slots); sc_gpairs.n = sc[36]; sc_gpairs.used = sc[37];
    ar_get(sca_dir, SCA_NT, s, 35, sca_hs, sc_incoming_guards.slots); sc_incoming_guards.n = sc[38]; sc_incoming_guards.used = sc[39];
    sc_count = sc[40];
    sc_first_unknown = sc[41] as i32;
    sc_rw_serial = sc[42] as i32;
    sc_ce_serial = sc[43] as i32;
    sc_ld_epoch = sc[44] as i32;
    sc_bd_epoch = sc[45] as i32;
    sc_has_guards = sc[46] != 0;
    sca_kill(s);
    sc_fv = fv;
    sc_valid = true;
    return true;
}
fn sca_compact() {
    ar_compact(sca_own, sca_dir, SCA_NT, [0], sca_scev);
    ar_compact(sca_own, sca_dir, SCA_NT, [1, 2, 3, 4, 5, 6], sca_i32);
    ar_compact(sca_own, sca_dir, SCA_NT, [7], sca_side);
    ar_compact(sca_own, sca_dir, SCA_NT, [8], sca_ent);
    ar_compact(sca_own, sca_dir, SCA_NT, [9], sca_bti);
    ar_compact(sca_own, sca_dir, SCA_NT, [10], sca_lnode);
    ar_compact(sca_own, sca_dir, SCA_NT, [11], sca_side2);
    ar_compact(sca_own, sca_dir, SCA_NT, [12], sca_ats);
    ar_compact(sca_own, sca_dir, SCA_NT, [13], sca_gi);
    ar_compact(sca_own, sca_dir, SCA_NT, [14], sca_pred);
    ar_compact(sca_own, sca_dir, SCA_NT, [15], sca_cm);
    ar_compact(sca_own, sca_dir, SCA_NT, [16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35], sca_hs);
    ar_compact(sca_own, sca_dir, SCA_NT, [36], sca_i64);
    ar_drop_dead(sca_own, sca_dir, SCA_NT, sca_slot, sca_gl);
    sca_dead = 0;
}
