// SLPVectorizer: the cost of a whole tree. Port of llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp:
// buildExternalUses, getRootEntryInstruction, doesInTreeUserNeedToExtract, getNumScalarInsts, getNumVectorInsts,
// getLoopTripCount, getScaleToLoopIterations, getLoopNestScale, getGatherNodeEffectiveScale,
// calculateTreeCostAndTrimNonProfitable and getTreeCost up to the extract costs of the external uses (the rest of
// getTreeCost, getSpillCost and the reduction parts fail loudly: they matter only for trees that get vectorized).
//
// ExternalUses (a SmallVector<ExternalUser>) is `slp_eu`; ExternalUsesAsOriginalScalar / ExternalUsesWithNonUsers
// are hash-table slots. The "Recalculate costs after tree trimming" trace iterates a pointer-keyed DenseMap
// (NodesCosts); ours prints the entries in index order (the compare tool skips that block).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import pm;
import flags;
import vt;
import apint;
import datalayout;
import loopinfo;
import loop_md;
import scev;
import scev_btc;
import scev_create;
import laa;
import vecutils;
import domtree;
import tti;
import tti_x86;
import tti_vec;
import tti_x86_vec;
import gen_x86target;
import slp_util;
import slp_tree;
import slp_loads;
import slp_build;
import slp_gather;
import slp_reorder;
import slp_transform;
import slp_minbw;
import slp_bvcost;
import slp_entrycost;

struct SEU { scalar: i32, user: i32, te: i32, lane: i64 }
var slp_eu: SEU[>..<];
let SH_EUORIG: i64 = 46;      // ExternalUsesAsOriginalScalar
let SH_EUNONU: i64 = 47;      // ExternalUsesWithNonUsers
let SH_EXTRA: i64 = 48;       // ExternallyUsedValues of buildExternalUses
let SH_S2X: i64 = 49;         // buildExternalUses' ScalarToExtUses: scalar -> 1 + index
fn slp_eu_clear() { slp_eu.clear(); sh_clear(SH_EUORIG); sh_clear(SH_EUNONU); }

// getRootEntryInstruction(Entry)
fn slp_root_entry_instruction(t: i32) -> i32 {
    if te_has_state(t) && (te_opcode(t) == OP_STORE || te_opcode(t) == OP_LOAD) && slp_te[t].state == TE_STRIDED &&
       slp_te[t].nreord > 0 && slp_is_reverse_order(te_reorder(t)) {
        let v = te_scalar(t, te_reorder(t)[0] as i64);
        return if is_inst(v) { v } else { -1 };
    }
    let v = te_scalar(t, 0);
    return if is_inst(v) { v } else { -1 };
}
// doesInTreeUserNeedToExtract(Scalar, UserInst, TLI, TTI)
fn slp_in_tree_user_needs_extract(s: i32, ui: i32) -> bool {
    if ui < 0 { return false; }
    let o = iop(ui);
    if o == OP_LOAD { return op(ui, 0) == s; }
    if o == OP_STORE { return op(ui, 1) == s; }
    if o == OP_CALL {
        let id = laa_vector_intrinsic_id_for_call(ui);
        for k in cb_nargs(ui) { if vu_scalar_op_at_arg(id, k, true) && cb_arg(ui, k) == s { return true; } }
        return false;
    }
    return false;
}
fn slp_num_vect_scalars() -> i64 {
    sh_clear(SH_TMP5);
    var n: i64 = 0;
    for t in slp_te.len {
        for v in te_scalars(t as i32) { if slp_tree_entries_head(v) >= 0 && sh_add(SH_TMP5, v as i64, 0) { n++; } }
    }
    return n + 1;
}
fn slp_te_dead(t: i32) -> bool { slp_is_deleted_node(t) || slp_is_transformed_to_gather(t) }
// buildExternalUses(ExternallyUsedValues): the values are in SH_EXTRA
fn slp_build_external_uses() {
    let nvs = slp_num_vect_scalars();
    sh_clear(SH_S2X);
    for t0 in slp_te.len {
        let t = t0 as i32;
        if te_is_gather(t) || slp_te[t].state == TE_SPLIT || slp_is_deleted_node(t) || slp_is_transformed_to_gather(t) { continue; }
        for lane in te_nscalars(t) {
            let s = te_scalar(t, lane);
            if !is_inst(s) || te_is_copyable_element(t, s) { continue; }
            let is_struct = ty_is_struct(vals[s].ty);
            var it = sh_get(SH_S2X, s as i64, 0, 0) - 1;
            if it >= 0 && slp_eu[it].user < 0 { continue; }
            if !is_struct && slp_has_n_uses_or_more(s, nvs) {
                let fl = te_find_lane(t, s);
                if slp_dbg_on { errs("SLP: Need to extract from lane "); errs_int(fl); errs(" from "); slp_dv(s); errs("for many users.\n"); slp_dbg_flush(); }
                if it < 0 { sh_set(SH_S2X, s as i64, 0, slp_eu.len + 1); }
                slp_eu.push(SEU { scalar: s, user: -1, te: t, lane: fl });
                sh_add(SH_EUNONU, s as i64, 0);
                continue;
            }
            if sh_has(SH_EXTRA, s as i64, 0) {
                let fl = te_find_lane(t, s);
                if slp_dbg_on { errs("SLP: Need to extract: Extra arg from lane "); errs_int(fl); errs(" from "); slp_dv(s); errs(".\n"); slp_dbg_flush(); }
                if it < 0 { sh_set(SH_S2X, s as i64, 0, slp_eu.len + 1); }
                slp_eu.push(SEU { scalar: s, user: -1, te: t, lane: fl });
                continue;
            }
            var u = vals[s].first_use;
            while u >= 0 {
                var usr = uses[u].user;
                u = uses[u].next;
                if slp_dbg_on { errs("SLP: Checking user:"); slp_dv(usr); errs(".\n"); slp_dbg_flush(); }
                if !is_inst(usr) || slp_is_deleted(usr) { continue; }
                let ui = usr;
                if slp_uil_on && slp_uil_contains(ui) { continue; }
                var ues: i32[>..<] = [];
                var c = slp_tree_entries_head(usr);
                while c >= 0 { ues.push(slp_lk[c].x); c = slp_lk[c].next; }
                var any_live = false;
                for x in ues { if !slp_te_dead(x) { any_live = true; break; } }
                if any_live {
                    let ptr_ls = ty_kind(ty_scalar(vals[s].ty)) == TK_PTR && (is_inst_op(ui, OP_LOAD) || is_inst_op(ui, OP_STORE));
                    var removed = !(ptr_ls || is_inst_op(ui, OP_CALL));
                    if !removed {
                        var all = true;
                        for x in ues {
                            if slp_te_dead(x) { continue; }
                            if !(slp_te[x].state == TE_SCATTER || !slp_in_tree_user_needs_extract(s, slp_root_entry_instruction(x))) { all = false; break; }
                        }
                        removed = all;
                    }
                    if removed {
                        if slp_dbg_on { errs("SLP: \tInternal user will be removed:"); slp_dv(usr); errs(".\n"); slp_dbg_flush(); }
                        continue;
                    }
                    if !is_struct {
                        usr = -1;
                        if it >= 0 { slp_eu[it].user = -1; break; }
                    }
                }
                if usr >= 0 && !is_struct && slp_has_n_uses_or_more(s, SLP_USES_LIMIT) { usr = -1; }
                let fl = te_find_lane(t, s);
                if slp_dbg_on { errs("SLP: Need to extract:"); slp_dv(ui); errs(" from lane "); errs_int(fl); errs(" from "); slp_dv(s); errs(".\n"); slp_dbg_flush(); }
                if it < 0 { it = slp_eu.len; sh_set(SH_S2X, s as i64, 0, slp_eu.len + 1); }
                slp_eu.push(SEU { scalar: s, user: usr, te: t, lane: fl });
                sh_add(SH_EUNONU, s as i64, 0);
                if usr < 0 { break; }
            }
        }
    }
}

// ---------------------------------------------------------------- instruction counts
fn slp_num_scalar_insts() -> i64 {
    var cnt: i64 = 0;
    for t0 in slp_te.len {
        let t = t0 as i32;
        if slp_is_deleted_node(t) { continue; }
        if te_is_gather(t) || slp_is_transformed_to_gather(t) {
            for v in te_scalars(t) { if is_inst_op(v, OP_EXTRACTELEMENT) { cnt++; } }
            continue;
        }
        if slp_te[t].state == TE_COMBINED { continue; }
        for v in te_scalars(t) {
            if !is_inst(v) || (te_has_copyable_elements(t) && te_is_copyable_element(t, v)) { continue; }
            cnt++;
            if slp_is_int_div_rem(iop(v)) || slp_is_fp_div_rem(iop(v)) { cnt++; }
            if is_inst_op(v, OP_CALL) {
                let id = laa_vector_intrinsic_id_for_call(v);
                if !is_trivially_vectorizable(id) { cnt++; }
            }
        }
        if slp_te[t].cop == CO_NONE && te_has_state(t) {
            let o = te_opcode(t);
            if o == OP_SELECT {
                for v in te_scalars(t) {
                    if te_has_copyable_elements(t) && te_is_copyable_element(t, v) { continue; }
                    if !is_inst_op(v, OP_SELECT) { continue; }
                    var one: i32[1] = [v];
                    let id, so = slp_can_convert_to_min_or_max(one[..]);
                    if id != 0 { cnt--; }
                }
            } else if o == OP_FADD || o == OP_FSUB {
                for v in te_scalars(t) {
                    if te_has_copyable_elements(t) && te_is_copyable_element(t, v) { continue; }
                    if !is_inst(v) || (te_is_alt_shuffle(t) && iop(v) != OP_FADD && iop(v) != OP_FSUB) { continue; }
                    var one: i32[1] = [v];
                    if tc_valid(slp_can_convert_to_fma(one[..], SIS { main: v, alt: v, copy: false })) { cnt--; }
                }
            }
        }
    }
    return cnt;
}
fn slp_num_vector_insts() -> i64 {
    var cnt: i64 = 0;
    var srcs: i32[>..<] = [];
    for t0 in slp_te.len {
        let t = t0 as i32;
        if slp_is_deleted_node(t) || slp_te[t].state == TE_COMBINED { continue; }
        if te_is_gather(t) || slp_is_transformed_to_gather(t) {
            if te_has_state(t) {
                let s1 = slp_same_values_tree_entry(te_main(t), te_scalars(t), false);
                if s1 >= 0 && s1 != t && te_vector_factor(s1) == te_vector_factor(t) { continue; }
                var rev: i32[>..<] = [];
                var k = te_nscalars(t);
                while k > 0 { k--; rev.push(te_scalar(t, k)); }
                let s2 = slp_same_values_tree_entry(te_main(t), rev, false);
                if s2 >= 0 && te_vector_factor(s2) == te_vector_factor(t) { cnt++; continue; }
            }
            var all = true;
            for v in te_scalars(t) { if !(is_inst_op(v, OP_EXTRACTELEMENT) || is_constant(v)) { all = false; break; } }
            if all {
                for v in te_scalars(t) { if is_inst_op(v, OP_EXTRACTELEMENT) && !slp_contains(srcs, op(v, 0)) { srcs.push(op(v, 0)); } }
            } else {
                for v in te_scalars(t) { if !slp_is_constant(v) { cnt++; } }
            }
            continue;
        }
        let o = te_opcode(t);
        if o == OP_INSERTELEMENT || o == OP_EXTRACTELEMENT { continue; }
        if o == OP_INSERTVALUE {
            if !slp_can_vector_store_insert_value(t) { cnt += 2; }
            if slp_te[t].nreord > 0 || slp_te[t].nreuse > 0 { cnt++; }
            continue;
        }
        if slp_te[t].state == TE_SPLIT { cnt += 2; } else { cnt++; }
        if slp_te[t].nreord > 0 || slp_te[t].nreuse > 0 { cnt++; }
    }
    cnt += srcs.len;
    var counted: i32[>..<] = [];
    for x in slp_eu {
        if x.user >= 0 && is_inst_op(x.user, OP_INSERTELEMENT) { continue; }
        if x.user >= 0 && slp_is_ephemeral(x.user) { continue; }
        if ty_is_vector(vals[x.scalar].ty) || ty_is_struct_of_vectors(vals[x.scalar].ty) { continue; }
        if sh_has(SH_EUORIG, x.scalar as i64, 0) { continue; }
        if slp_contains(counted, x.scalar) { continue; }
        counted.push(x.scalar);
        cnt++;
    }
    return cnt;
}
fn ty_is_struct_of_vectors(t: i32) -> bool {
    if !ty_is_struct(t) { return false; }
    let n = ty_count(t);
    if n == 0 { return false; }
    for k in n { if !ty_is_vector(ty_field(t, k)) { return false; } }
    return true;
}

// ---------------------------------------------------------------- loop scaling
// getLoopTripCount(L, SE)
fn slp_loop_trip_count(l: i32) -> i64 {
    let lat = slp_loop_aware_trip_count();
    if lat == 0 { return 1; }
    var sc = sc_get_small_constant_trip_count(l);
    if sc == 0 {
        let h, t = get_loop_estimated_trip_count(l);
        sc = if h { t as i64 } else { 0 };
    }
    if sc != 0 {
        if loop_exiting_block(l) < 0 { return if lat < sc { lat } else { sc }; }
        return sc;
    }
    return lat;
}
// getLoopNestScale(L)
fn slp_loop_nest_scale(l: i32) -> u64 {
    if l < 0 || slp_loop_aware_trip_count() == 0 { return 1; }
    var chain: i32[>..<] = [];
    var c = l;
    while c >= 0 { chain.push(c); c = loop_parent(c); }
    var scale: u64 = 1;
    var k = chain.len;
    while k > 0 {
        k--;
        var tc = slp_loop_trip_count(chain[k]) as u64;
        if tc < 1 { tc = 1; }
        // SaturatingMultiply
        if tc != 0 && scale > 0xFFFFFFFFFFFFFFFF / tc { scale = 0xFFFFFFFFFFFFFFFF; } else { scale = scale * tc; }
    }
    return if scale < 1 { 1 } else { scale };
}
// getScaleToLoopIterations(TE, Scalar, U)
fn slp_scale_to_loop_iterations(t: i32, scalar: i32, u: i32) -> u64 {
    var parent: i32 = -1;
    if u >= 0 {
        if is_inst_op(u, OP_PHI) && scalar >= 0 {
            if li_loop_for(inst_parent(u)) >= 0 {
                for i in phi_nincoming(u) {
                    if op(u, i) != scalar { continue; }
                    let inbb = phi_block(u, i);
                    if parent < 0 || slp_loop_depth_of(inbb) > slp_loop_depth_of(parent) { parent = inbb; }
                }
            }
        }
        if parent < 0 { parent = inst_parent(u); }
    } else if te_is_gather(t) || slp_te[t].state == TE_SPLIT {
        var ut = slp_te[t].ui_te;
        var edge = slp_te[t].ui_edge;
        while ut >= 0 {
            if te_is_gather(ut) || slp_te[ut].state == TE_SPLIT { edge = slp_te[ut].ui_edge; ut = slp_te[ut].ui_te; continue; }
            if slp_te[ut].state == TE_VECTORIZE && te_opcode(ut) == OP_PHI { parent = phi_block(te_main(ut), edge); }
            else { parent = inst_parent(te_main(ut)); }
            break;
        }
        if parent < 0 { return 1; }
    } else {
        parent = inst_parent(te_main(t));
    }
    let l = li_loop_for(parent);
    if l < 0 { return 1; }
    if scalar >= 0 {
        var one: i32[1] = [scalar];
        return slp_loop_nest_scale(slp_innermost_noninvariant_loop(l, one[..]));
    }
    return slp_loop_nest_scale(slp_innermost_noninvariant_loop(l, te_scalars(t)));
}
fn slp_loop_depth_of(bb: i32) -> i64 { let l = li_loop_for(bb); return if l < 0 { 0 } else { loop_depth(l) }; }
// getGatherNodeEffectiveScale(TE, U)
fn slp_gather_node_effective_scale(t: i32, u: i32) -> u64 {
    let base = slp_scale_to_loop_iterations(t, -1, u);
    if !flag_bool("slp-per-lane-gather-scale", true) || slp_loop_aware_trip_count() == 0 || base <= 1 { return base; }
    var sum: u64 = 0;
    var n: u64 = 0;
    for v in te_scalars(t) {
        if slp_is_constant(v) { continue; }
        n++;
        var ls = slp_scale_to_loop_iterations(t, v, u);
        if ls > base { ls = base; }
        if sum > 0xFFFFFFFFFFFFFFFF - ls { return base; }
        sum = sum + ls;
    }
    if n == 0 { return base; }
    if sum > 0xFFFFFFFFFFFFFFFF - (n - 1) { return base; }
    let avg = (sum + n - 1) / n;
    if avg < 1 { return 1; }
    if avg > base { return base; }
    return avg;
}
fn slp_cost_scale(c: i64, s: u64) -> i64 { tc_mul(c, s as i64) }

// ---------------------------------------------------------------- calculateTreeCostAndTrimNonProfitable
var slp_nodes_cost: i64[>..<];       // NodesCosts: per entry (TTI_INVALID + 1 = not in the map)
let SLP_NC_NONE: i64 = 0x4000000000000001;
fn slp_calculate_tree_cost_and_trim(vvals: const i32[:], rdx_root: i32) -> i64 {
    for t in slp_te.len {
        if te_is_gather(t as i32) && ty_is_struct(vals[te_scalar(t as i32, 0)].ty) {
            if slp_dbg_on { errs("SLP: rejecting tree with buildvector struct values of size "); errs_int(slp_te.len); errs(".\n"); slp_dbg_flush(); }
            return TTI_INVALID;
        }
    }
    slp_nodes_cost.clear();
    for t in slp_te.len { slp_nodes_cost.push(SLP_NC_NONE); }
    sh_clear(SH_CHKEXT);
    cv_clear();
    var gl_nodes: i32[>..<] = [];
    var ext_cost: i64[>..<] = [];
    for t in slp_te.len { ext_cost.push(SLP_NC_NONE); }
    if slp_dbg_on { errs("SLP: Calculating cost for tree of size "); errs_int(slp_te.len); errs(".\n"); slp_dbg_flush(); }
    let nvs = slp_num_vect_scalars();
    var euv_v: i32[>..<] = [];
    var euv_r: bool[>..<] = [];
    fn is_ext_used_v(v: i32) -> bool {
        for k in euv_v.len { if euv_v[k] == v { return euv_r[k]; } }
        var res = false;
        if slp_has_one_use(v) || vals[v].ty as i32 == T_VOID {
        } else if slp_has_n_uses_or_more(v, nvs) {
            res = true;
        } else if is_inst(v) {
            var u = vals[v].first_use;
            while u >= 0 {
                let usr = uses[u].user;
                u = uses[u].next;
                if slp_user_feeds_vectorizable(usr, v) { continue; }
                var ents: i32[>..<] = [];
                var c = slp_tree_entries_head(usr);
                while c >= 0 { ents.push(slp_lk[c].x); c = slp_lk[c].next; }
                if ents.len == 0 && !sh_has(SH_MUSTG, usr as i64, 0) { res = true; break; }
                var any = false;
                for x in ents { if slp_is_deleted_node(x) { any = true; } }
                if any { res = true; break; }
                c = slp_lk_head(SH_V2G, usr as i64);
                while c >= 0 { if slp_is_deleted_node(slp_lk[c].x) { any = true; } c = slp_lk[c].next; }
                if any { res = true; break; }
            }
        }
        euv_v.push(v);
        euv_r.push(res);
        return res;
    }
    var cost: i64 = 0;
    var scale_of: u64[>..<] = [];
    for t in slp_te.len { scale_of.push(0); }
    var prev_scale: u64 = 0;
    var prev_parent: i32 = -1;
    for t0 in slp_te.len {
        let t = t0 as i32;
        if slp_te[t].state == TE_COMBINED {
            if slp_dbg_on {
                errs("SLP: Skipping cost for combined node that starts with "); slp_dv(te_scalar(t, 0)); errs(".\n");
                slp_dump_te(t); errs("SLP: Current total cost = "); slp_errs_cost(cost); errs("\n"); slp_dbg_flush();
            }
            slp_nodes_cost[t0] = 0;
            continue;
        }
        if te_has_state(t) && (te_is_gather(t) || slp_te[t].state == TE_SPLIT) {
            let s = slp_same_values_tree_entry(te_main(t), te_scalars(t), false);
            if s >= 0 && te_vector_factor(s) == te_vector_factor(t) {
                if slp_dbg_on {
                    errs("SLP: Adding cost 0 for bundle "); slp_short_bundle_name(te_scalars(t), t); errs(".\n");
                    errs("SLP: Current total cost = "); slp_errs_cost(cost); errs("\n"); slp_dbg_flush();
                }
                slp_nodes_cost[t0] = 0;
                continue;
            }
        }
        var c = slp_entry_cost(t, vvals);
        var scale: u64 = 0;
        let free = c == 0;
        let gather_like = te_is_gather(t) || slp_te[t].state == TE_SPLIT;
        if !free && !te_is_gather(t) && te_has_state(t) {
            if prev_parent == inst_parent(te_main(t)) {
                scale = prev_scale;
                c = slp_cost_scale(c, scale);
                if scale_of[t0] == 0 { scale_of[t0] = scale; }
            }
        }
        if !free && scale == 0 {
            scale = if gather_like { slp_gather_node_effective_scale(t, if t == 0 { rdx_root } else { -1 }) } else { slp_scale_to_loop_iterations(t, -1, -1) };
            c = slp_cost_scale(c, scale);
            if scale_of[t0] == 0 { scale_of[t0] = scale; }
            if !te_is_gather(t) && te_has_state(t) {
                prev_parent = inst_parent(te_main(t));
                prev_scale = scale;
            }
        }
        cost = tc_add(cost, c);
        slp_nodes_cost[t0] = c;
        if slp_dbg_on {
            errs("SLP: Adding cost "); slp_errs_cost(c); errs(" for bundle "); slp_short_bundle_name(te_scalars(t), t); errs(".\n");
            errs("SLP: Current total cost = "); slp_errs_cost(cost); errs("\n"); slp_dbg_flush();
        }
        if t > 0 && slp_te[t].ui_te < 0 && te_has_state(t) && te_opcode(t) == OP_LOAD { if !slp_contains(gl_nodes, t) { gl_nodes.push(t); } }
        if !te_is_gather(t) && slp_te[t].state != TE_SPLIT &&
           !(t == 0 && (te_opcode(t) == OP_INSERTELEMENT || te_opcode(t) == OP_INSERTVALUE || te_opcode(t) == OP_STORE)) &&
           !ty_is_struct(slp_value_type(te_scalar(t, 0), false)) {
            var dem: bool[>..<] = [];
            for k in te_vector_factor(t) { dem.push(false); }
            var any = false;
            for v in te_scalars(t) {
                if te_has_copyable_elements(t) && te_is_copyable_element(t, v) { continue; }
                if is_ext_used_v(v) { dem[te_find_lane(t, v)] = true; any = true; }
            }
            if any {
                var esty: i32 = vals[te_scalar(t, 0)].ty;
                if slp_te[t].mbw > 0 { esty = ty_int(slp_te[t].mbw as i64); }
                let vecty = slp_widened_type(esty, te_vector_factor(t));
                var ec = slp_scalarization_overhead(esty, vecty, dem, false, true, true);
                if tc_valid(ec) && ec != 0 {
                    if scale == 0 { scale = slp_scale_to_loop_iterations(t, -1, -1); }
                    ec = slp_cost_scale(ec, scale);
                    if scale_of[t0] == 0 { scale_of[t0] = scale; }
                }
                ext_cost[t0] = ec;
            }
        }
    }
    let thr = slp_threshold();
    if flag_given("slp-threshold") && thr < 0 && cost < -thr { return cost; }
    let root: i32 = 0;
    var rsz: i64 = 0;
    if slp_te[root].mbw > 0 { rsz = slp_te[root].mbw as i64; }
    else {
        let a = slp_vector_element_size(te_scalar(root, 0));
        let b = slp_dl_bits(ty_scalar(slp_value_type(te_scalar(root, 0), false)));
        rsz = if a > b { a } else { b };
    }
    let minvf = slp_min_vf(rsz);
    if cost >= -thr && te_nscalars(0) * 2 <= minvf &&
       (!te_has_state(0) || (te_opcode(0) != OP_STORE && li_loop_for(inst_parent(te_main(0))) >= 0)) { return cost; }
    // SubtreeCosts: (total, cost, nodes)
    var st_total: i64[>..<] = [];
    var st_cost: i64[>..<] = [];
    var st_nodes: i32[>..<] = [];     // node lists: (owner, node) pairs
    var st_owner: i32[>..<] = [];
    for t in slp_te.len { st_total.push(0); st_cost.push(0); }
    for t0 in slp_te.len {
        let t = t0 as i32;
        let c = if slp_nodes_cost[t0] == SLP_NC_NONE { 0 } else { slp_nodes_cost[t0] };
        let ec = if ext_cost[t0] == SLP_NC_NONE { 0 } else { ext_cost[t0] };
        st_total[t0] = tc_add(st_total[t0], tc_add(c, ec));
        st_cost[t0] = tc_add(st_cost[t0], c);
        var u = slp_te[t].ui_te;
        var vis_t: i32[>..<] = [];
        while u >= 0 {
            if slp_contains(vis_t, u) { break; }
            vis_t.push(u);
            st_total[u as i64] = tc_add(st_total[u as i64], tc_add(c, ec));
            st_cost[u as i64] = tc_add(st_cost[u as i64], c);
            st_owner.push(u); st_nodes.push(t);
            u = slp_te[u].ui_te;
        }
    }
    var vis_a: i32[>..<] = [];
    var vis_b: i32[>..<] = [];
    for t in gl_nodes {
        let tot = st_total[t as i64];
        let cc = st_cost[t as i64];
        for v in te_scalars(t) {
            var c = slp_lk_head(SH_V2G, v as i64);
            while c >= 0 {
                var u = slp_lk[c].x;
                c = slp_lk[c].next;
                loop {
                    if u < 0 { break; }
                    var seen = false;
                    for k in vis_a.len { if vis_a[k] == t && vis_b[k] == u { seen = true; break; } }
                    if seen { break; }
                    vis_a.push(t); vis_b.push(u);
                    st_total[u as i64] = tc_add(st_total[u as i64], tot);
                    st_cost[u as i64] = tc_add(st_cost[u as i64], cc);
                    u = slp_te[u].ui_te;
                }
            }
        }
    }
    // the PriorityQueue Worklist (FirstGreater): repeatedly the entry with the largest total cost (ties: larger index)
    var wl: i32[>..<] = [];
    for t in slp_te.len { wl.push(t as i32); }
    fn wl_less(a: i32, b: i32) -> bool { st_total[a as i64] < st_total[b as i64] || (st_total[a as i64] == st_total[b as i64] && a < b) }
    fn wl_top() -> i64 {
        var best: i64 = -1;
        for k in wl.len { if best < 0 || wl_less(wl[best], wl[k]) { best = k; } }
        return best;
    }
    fn wl_pop(k: i64) { wl[k] = wl[wl.len - 1]; wl.pop(); }
    if !slp_uil_on && te_vector_factor(0) < minvf && te_has_state(0) && te_opcode(0) == OP_STORE {
        let tk = wl_top();
        if wl[tk] == 0 || wl[tk] == 1 { return cost; }
    }
    var changed = false;
    var prefer_trimmed = false;
    while wl.len > 0 {
        let tk = wl_top();
        let t = wl[tk];
        if !(st_total[t as i64] > 0) { break; }
        var skip = te_is_gather(t) || t == 0 || slp_is_deleted_node(t) || ty_is_struct(slp_value_type(te_scalar(t, 0), false));
        if !skip && slp_te[t].ui_te >= 0 && slp_te[slp_te[t].ui_te].state == TE_SPLIT {
            for v in te_scalars(t) { if slp_lk_count(SH_SPLIT, v as i64) > 1 { skip = true; break; } }
        }
        if skip { wl_pop(tk); continue; }
        if slp_te[t].state == TE_VECTORIZE && !te_is_alt_shuffle(t) && (te_opcode(t) == OP_ICMP || te_opcode(t) == OP_FCMP) {
            var inv = false;
            for v in te_scalars(t) { if slp_is_cmp(v) && inst_pred(v) != inst_pred(te_main(t)) { inv = true; break; } }
            if inv { wl_pop(tk); continue; }
        }
        var tsc = st_total[t as i64];
        var sc = st_cost[t as i64];
        if tsc < te_nscalars(t) { wl_pop(tk); continue; }
        var nodes: i32[>..<] = [];
        for k in st_owner.len { if st_owner[k] == t { nodes.push(st_nodes[k]); } }
        var any_t2g = false;
        for x in nodes { if slp_is_transformed_to_gather(x) { any_t2g = true; } }
        if slp_t2g_count() > 0 {
            for idx in nodes {
                if slp_is_transformed_to_gather(idx) {
                    let g = sh_get(SH_T2G, idx as i64, 0, 0);
                    tsc = tc_add(tc_sub(tsc, st_total[idx as i64]), g);
                    sc = tc_add(tc_sub(sc, st_cost[idx as i64]), g);
                }
            }
        }
        if tsc < 0 || tsc < te_nscalars(t) { wl_pop(tk); continue; }
        let evf = te_vector_factor(t);
        var dem: bool[>..<] = [];
        for k in evf { dem.push(false); }
        for k in te_nscalars(t) { if !slp_is_constant(te_scalar(t, k)) { dem[k] = true; } }
        var gsty = slp_value_type(te_scalar(t, 0), false);
        if slp_te[t].mbw > 0 { gsty = ty_int(slp_te[t].mbw as i64); }
        let gvt = slp_widened_type(gsty, evf);
        var gc = slp_scalarization_overhead(gsty, gvt, dem, true, false, true);
        var mask: i32[>..<] = [];
        let st = slp_te[t].state;
        if slp_te[t].nreord > 0 && st != TE_COMPRESS && (st != TE_STRIDED || !slp_is_reverse_order(te_reorder(t))) {
            var nm: i32[>..<] = [];
            if te_opcode(t) == OP_STORE { slp_copy_list(te_reorder(t), nm); } else { slp_inverse_permutation(te_reorder(t), nm); }
            slp_add_mask(mask, nm, false);
        }
        if slp_te[t].nreuse > 0 { slp_add_mask(mask, te_reuse(t), false); }
        if mask.len > 0 && !slp_is_identity_mask(mask, evf) { gc = tc_add(gc, slp_shuffle_cost(SK_PERMUTESINGLESRC, gvt, mask, 0, -1)); }
        if !te_has_state(t) || !te_is_alt_shuffle(t) {
            var all = true;
            for v in te_scalars(t) {
                if !((te_has_copyable_elements(t) && te_is_copyable_element(t, v)) || slp_is_constant(v) || sh_has(SH_MUSTG, v as i64, 0) ||
                     slp_lk_count(SH_S2TE, v as i64) > 1) { all = false; break; }
            }
            if all { gc = tc_mul(gc, 2); }
        }
        var eq_alt = tsc == gc && te_has_state(t) && te_is_alt_shuffle(t) && is_binary_op(te_opcode(t));
        if eq_alt {
            for x in nodes { if te_has_state(x) && te_opcode(x) == OP_EXTRACTELEMENT { eq_alt = false; break; } }
        }
        var npow2 = false;
        for x in nodes { if !slp_is_pow2(te_nscalars(x)) { npow2 = true; } }
        let margin: i64 = if npow2 { 1 } else { 0 };
        if tsc > tc_add(gc, margin) || eq_alt {
            prefer_trimmed = prefer_trimmed || tsc == gc;
            if te_has_state(0) && te_opcode(0) == OP_INSERTELEMENT && t == 1 {
                if cost < -thr {
                    if slp_dbg_on { errs("SLP: Skipping trim of node "); errs_int(t as i64); errs(" - tree already profitable with cost "); slp_errs_cost(cost); errs(".\n"); slp_dbg_flush(); }
                    wl_pop(tk);
                    continue;
                }
                return TTI_INVALID;
            }
            if slp_dbg_on {
                errs("SLP: Trimming unprofitable subtree at node "); errs_int(t as i64); errs(" with cost "); slp_errs_cost(st_total[t as i64]);
                errs(" and gather cost "); slp_errs_cost(gc); errs(".\n"); slp_dbg_flush();
            }
            if slp_te[t].ui_te >= 0 {
                sh_set(SH_T2G, t as i64, 0, gc);
                slp_nodes_cost[t as i64] = SLP_NC_NONE;
            } else {
                sh_add(SH_DELNODES, t as i64, 0);
                sh_del(SH_T2G, t as i64, 0);
                slp_nodes_cost[t as i64] = SLP_NC_NONE;
            }
            for x in nodes {
                sh_add(SH_DELNODES, x as i64, 0);
                sh_del(SH_T2G, x as i64, 0);
                slp_nodes_cost[x as i64] = SLP_NC_NONE;
            }
            changed = true;
        }
        wl_pop(tk);
    }
    if !changed { return st_cost[0]; }
    for t in gl_nodes {
        if slp_is_deleted_node(t) || slp_is_transformed_to_gather(t) { continue; }
        slp_fail("calculateTreeCostAndTrimNonProfitable: trimming gathered-loads nodes");
    }
    for t0 in slp_te.len {
        let t = t0 as i32;
        if slp_te[t].ui_te < 0 && slp_is_transformed_to_gather(t) { continue; }
        if slp_is_deleted_node(t) { continue; }
        if slp_nodes_cost[t0] == SLP_NC_NONE {
            var c = slp_entry_cost(t, vvals);
            if !tc_valid(c) || c == 0 { slp_nodes_cost[t0] = c; continue; }
            var sc = scale_of[t0];
            if sc == 0 {
                let gl = te_is_gather(t) || slp_te[t].state == TE_SPLIT;
                sc = if gl { slp_gather_node_effective_scale(t, -1) } else { slp_scale_to_loop_iterations(t, -1, -1) };
            }
            slp_nodes_cost[t0] = slp_cost_scale(c, sc);
        }
    }
    if slp_dbg_on { errs("SLP: Recalculate costs after tree trimming.\n"); slp_dbg_flush(); }
    var ncost: i64 = 0;
    for t0 in slp_te.len {
        if slp_nodes_cost[t0] == SLP_NC_NONE { continue; }
        ncost = tc_add(ncost, slp_nodes_cost[t0]);
        if slp_dbg_on {
            errs("SLP: Adding cost "); slp_errs_cost(slp_nodes_cost[t0]); errs(" for bundle "); slp_short_bundle_name(te_scalars(t0 as i32), t0 as i32); errs(".\n");
            errs("SLP: Current total cost = "); slp_errs_cost(ncost); errs("\n"); slp_dbg_flush();
        }
    }
    if ncost > cost || (!prefer_trimmed && ncost == cost) {
        sh_clear(SH_DELNODES);
        sh_clear(SH_T2G);
        ncost = cost;
    } else {
        if slp_te.len >= 2 && te_has_state(0) && te_opcode(0) == OP_INSERTELEMENT && slp_is_transformed_to_gather(1) { return TTI_INVALID; }
        if slp_te.len >= 3 && te_has_state(0) && te_opcode(0) == OP_INSERTELEMENT && te_has_state(1) && slp_te[1].state == TE_VECTORIZE &&
           (te_opcode(1) == OP_ZEXT || te_opcode(1) == OP_SEXT || te_opcode(1) == OP_TRUNC) && slp_is_transformed_to_gather(2) { return TTI_INVALID; }
    }
    return ncost;
}
fn slp_t2g_count() -> i64 {
    var n: i64 = 0;
    for t in slp_te.len { if slp_is_transformed_to_gather(t as i32) { n++; } }
    return n;
}
// store/insertelt v, [cast]U will likely be vectorized (the first checks of IsExternallyUsedV)
fn slp_user_feeds_vectorizable(u: i32, i: i32) -> bool {
    fn cast_or_self_one_use(x: i32) -> bool {
        if x == i { return true; }
        return is_inst(x) && is_cast_op(iop(x)) && op(x, 0) == i && slp_has_one_use(x);
    }
    if is_inst_op(u, OP_INSERTELEMENT) && is_cint(op(u, 2)) {
        let x = op(u, 1);
        if x == i { return true; }
        if slp_has_one_use(x) && cast_or_self_one_use(x) { return true; }
    }
    if is_inst_op(u, OP_STORE) {
        let x = op(u, 0);
        if x == i { return true; }
        if slp_has_one_use(x) && cast_or_self_one_use(x) { return true; }
    }
    return false;
}

// getTreeCost(TreeCost, VectorizedVals, ReductionCost, RdxRoot)
fn slp_get_tree_cost(tree_cost: i64, vvals: const i32[:], rdx_cost0: i64, rdx_root: i32) -> i64 {
    let thr = slp_threshold();
    if flag_bool("slp-inst-count-check", true) && te_vector_factor(0) == 2 && thr == 0 {
        let ns = slp_num_scalar_insts();
        let nv = slp_num_vector_insts();
        if slp_dbg_on { errs("SLP: Inst count check: vector="); errs_int(nv); errs(" scalar="); errs_int(ns); errs("\n"); slp_dbg_flush(); }
        if nv > ns {
            var bypass = false;
            if flag_bool("slp-vectorize-poor-throughput", true) && tree_cost < -thr {
                slp_cheap_kind.clear(); slp_cheap_a.clear(); slp_cheap_b.clear();
                for t0 in slp_te.len {
                    let t = t0 as i32;
                    if te_has_state(t) && !slp_is_deleted_node(t) && !te_is_gather(t) && !slp_is_transformed_to_gather(t) &&
                       slp_te[t].state != TE_COMBINED && slp_is_poor_throughput_op(te_main(t)) { bypass = true; break; }
                }
            }
            if bypass { return slp_get_tree_cost_rest(tree_cost, vvals, rdx_cost0, rdx_root); }
            if slp_dbg_on { errs("SLP: Rejecting tree: vector inst count "); errs_int(nv); errs(" > scalar inst count "); errs_int(ns); errs(".\n"); slp_dbg_flush(); }
            return TTI_INVALID;
        }
    }
    return slp_get_tree_cost_rest(tree_cost, vvals, rdx_cost0, rdx_root);
}
fn slp_get_tree_cost_rest(tree_cost: i64, vvals: const i32[:], rdx_cost0: i64, rdx_root: i32) -> i64 {
    let thr = slp_threshold();
    var cost = tree_cost;
    var rdx_cost = rdx_cost0;
    if slp_uil_on {
        if tc_valid(rdx_cost) && rdx_cost != 0 {
            let s = slp_scale_to_loop_iterations(0, -1, rdx_root);
            if slp_dbg_on { errs("Scale "); errs_int(s as i64); errs(" For entry 0\n"); slp_dbg_flush(); }
            rdx_cost = slp_cost_scale(rdx_cost, s);
        }
    }
    cost = tc_add(cost, rdx_cost);
    for x in slp_eu {
        if ty_is_struct(vals[x.scalar].ty) && (x.te != 0 || slp_te[x.te].state != TE_VECTORIZE || te_opcode(x.te) != OP_INSERTVALUE) &&
           !(x.user >= 0 && is_inst_op(x.user, OP_EXTRACTVALUE)) { return TTI_INVALID; }
    }
    let limit: i64 = 100;
    var ndel: i64 = 0;
    for t in slp_te.len { if slp_is_deleted_node(t as i32) { ndel++; } }
    if cost >= -thr + limit && (slp_te.len - ndel) * te_vector_factor(0) < limit { return cost; }
    var any_ie = false;
    for x in slp_eu { if x.user >= 0 && is_inst_op(x.user, OP_INSERTELEMENT) { any_ie = true; } }
    if cost >= -thr && !any_ie { return cost; }
    slp_fail("getTreeCost: the extract costs of the external uses");
    return cost;
}

// ---------------------------------------------------------------- isPoorThroughputOp (PoorThroughputOpCache: slp_cheap_*)
var slp_cheap_kind: i64[>..<];
var slp_cheap_a: i64[>..<];
var slp_cheap_b: i64[>..<];
fn slp_cheap_has(kind: i64, a: i64, b: i64) -> bool {
    for k in slp_cheap_kind.len { if slp_cheap_kind[k] == kind && slp_cheap_a[k] == a && slp_cheap_b[k] == b { return true; } }
    return false;
}
// getPoorThroughputTypeKey(Ty): (TypeID << 16) | scalar size
fn slp_type_key(t: i32) -> i64 { (slp_type_id(t) << 16) | tt_scalar_bits(t) }
// isPoorThroughputOp(I, TTI, TLI, Cache)
fn slp_is_poor_throughput_op(i: i32) -> bool {
    let o = iop(i);
    if !is_binary_op(o) && o != OP_CALL { return false; }
    let ty = vals[i].ty as i32;
    if ty_is_vector(ty) || ty_is_aggregate(ty) || !slp_is_valid_element_type(ty) { return false; }
    fn analyze(i: i32) -> bool {
        let sc = tti_instruction_cost(i, TCK_RECIP_THROUGHPUT);
        if sc < TCC_EXPENSIVE { return false; }
        // getVectorOpCost(I, MinVF = 2, TTI, TLI)
        var vc: i64 = 0;
        if iop(i) == OP_CALL {
            let id = laa_vector_intrinsic_id_for_call(i);
            var tys: i32[>..<] = [];
            slp_intrinsic_arg_types(i, id, 2, 0, tys);
            let ic, lc = slp_vector_call_costs(i, slp_widened_type(vals[i].ty, 2), tys);
            vc = if ic < lc { ic } else { lc };
        } else {
            vc = tv_arith0(iop(i), ty_vector(vals[i].ty, 2, false), TCK_RECIP_THROUGHPUT);
        }
        return vc < tc_mul(sc, 2);
    }
    fn check(kind: i64, a: i64, b: i64, i: i32) -> bool {
        if slp_cheap_has(kind, a, b) { return false; }
        if analyze(i) { return true; }
        slp_cheap_kind.push(kind); slp_cheap_a.push(a); slp_cheap_b.push(b);
        return false;
    }
    if o == OP_CALL {
        for k in cb_nargs(i) { if !slp_is_valid_element_type(vals[cb_arg(i, k)].ty) { return false; } }
        let id = laa_vector_intrinsic_id_for_call(i);
        if id != 0 { return check(1, id as i64, slp_type_key(ty), i); }
        let f = called_function(i);
        if f < 0 { return analyze(i); }
        return check(2, f as i64, 0, i);
    }
    return check(0, o, slp_type_key(ty), i);
}

