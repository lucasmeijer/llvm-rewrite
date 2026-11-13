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
import printer;
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
    return slp_get_tree_cost_extracts(cost, vvals, rdx_cost, rdx_root);
}
// areTwoInsertFromSameBuildVector(VU, V, GetBaseOperand) with getTreeCost's GetBaseOperand
fn slp_tc_base_operand(ii: i32) -> i32 {
    let o0 = op(ii, 0);
    if slp_is_vectorized(ii) && !slp_is_vectorized(o0) { return -1; }
    return o0;
}
fn slp_two_inserts_same_bv(vu: i32, v: i32) -> bool {
    if inst_parent(vu) != inst_parent(v) { return false; }
    if vals[vu].ty as i32 != vals[v].ty as i32 { return false; }
    if !slp_has_one_use(vu) && !slp_has_one_use(v) { return false; }
    var ie1 = vu;
    var ie2 = v;
    let idx1 = slp_element_index(ie1, 0);
    let idx2 = slp_element_index(ie2, 0);
    if idx1 < 0 || idx2 < 0 { return false; }
    var reused: bool[>..<] = [];
    for k in ty_count(vals[vu].ty) { reused.push(false); }
    var is_reused = false;
    loop {
        if ie2 == vu && ie1 < 0 { return slp_has_one_use(vu); }
        if ie1 == v && ie2 < 0 { return slp_has_one_use(v); }
        if ie1 >= 0 && ie1 != v {
            var i1 = slp_element_index(ie1, 0);
            if i1 < 0 { i1 = idx2; }
            is_reused = is_reused || reused[i1];
            reused[i1] = true;
            if (ie1 != vu && !slp_has_one_use(ie1)) || is_reused { ie1 = -1; }
            else { let b = slp_tc_base_operand(ie1); ie1 = if is_inst_op(b, OP_INSERTELEMENT) { b } else { -1 }; }
        }
        if ie2 >= 0 && ie2 != vu {
            var i2 = slp_element_index(ie2, 0);
            if i2 < 0 { i2 = idx1; }
            is_reused = is_reused || reused[i2];
            reused[i2] = true;
            if (ie2 != v && !slp_has_one_use(ie2)) || is_reused { ie2 = -1; }
            else { let b = slp_tc_base_operand(ie2); ie2 = if is_inst_op(b, OP_INSERTELEMENT) { b } else { -1 }; }
        }
        if is_reused || (ie1 < 0 && ie2 < 0) { break; }
    }
    return false;
}
// isFirstInsertElement(IE1, IE2)
fn slp_is_first_insert_element(ie1: i32, ie2: i32) -> bool {
    if ie1 == ie2 { return false; }
    var i1 = ie1;
    var i2 = ie2;
    let idx1 = slp_element_index(ie1, 0);
    let idx2 = slp_element_index(ie2, 0);
    loop {
        if i2 == ie1 { return true; }
        if i1 == ie2 { return false; }
        let p1 = i1;
        let p2 = i2;
        if i1 >= 0 && (i1 == ie1 || slp_has_one_use(i1)) {
            var e = slp_element_index(i1, 0);
            if e < 0 { e = idx2; }
            if e != idx2 { let o = op(i1, 0); i1 = if is_inst_op(o, OP_INSERTELEMENT) { o } else { -1 }; }
        }
        if i2 >= 0 && (i2 == ie2 || slp_has_one_use(i2)) {
            var e = slp_element_index(i2, 0);
            if e < 0 { e = idx1; }
            if e != idx1 { let o = op(i2, 0); i2 = if is_inst_op(o, OP_INSERTELEMENT) { o } else { -1 }; }
        }
        if !((i1 >= 0 && p1 != i1) || (i2 >= 0 && p2 != i2)) { break; }
    }
    fatal("internal: SLP: two different buildvectors not expected");
    return false;
}
// the extract-cost part of getTreeCost
fn slp_get_tree_cost_extracts(cost0: i64, vvals: const i32[:], rdx_cost: i64, rdx_root: i32) -> i64 {
    let thr = slp_threshold();
    var cost = cost0;
    // ScaleCost(C, TE, Scalar, U) with the EntryToScale cache
    var sc_te: i32[>..<] = [];
    var sc_s: i32[>..<] = [];
    var sc_u: i32[>..<] = [];
    var sc_v: u64[>..<] = [];
    fn scale_cost(c: i64, t: i32, scalar: i32, u: i32) -> i64 {
        if !tc_valid(c) || c == 0 { return c; }
        var sv: u64 = 0;
        var found = false;
        for k in sc_te.len { if sc_te[k] == t && sc_s[k] == scalar && sc_u[k] == u { sv = sc_v[k]; found = true; break; } }
        if !found || sv == 0 {
            sv = slp_scale_to_loop_iterations(t, scalar, u);
            if !found { sc_te.push(t); sc_s.push(scalar); sc_u.push(u); sc_v.push(sv); }
        }
        if slp_dbg_on { errs("Scale "); errs_int(sv as i64); errs(" For entry "); errs_int(t as i64); errs("\n"); slp_dbg_flush(); }
        return slp_cost_scale(c, sv);
    }
    var ext_cost: i64 = 0;
    // ShuffledInserts: per buildvector: first insert, then (entry, mask) pairs in a MapVector; DemandedElts
    var si_first: i32[>..<] = [];
    var si_dem_at: i64[>..<] = [];
    var si_dem: bool[>..<] = [];
    var vm_si: i64[>..<] = [];
    var vm_te: i32[>..<] = [];
    var vm_at: i64[>..<] = [];
    var vm_pool: i32[>..<] = [];
    var used_inserts: i32[>..<] = [];
    var vcasts_te: i32[>..<] = [];
    var vcasts_ty: i32[>..<] = [];
    var vte_k: i32[>..<] = [];      // ValueToExtUses: scalar -> index (computed lazily)
    var vte_i: i64[>..<] = [];
    var vte_ready = false;
    var ec_te: i32[>..<] = [];      // ExtractsCount: entry -> set of instructions
    var ec_i: i32[>..<] = [];
    var ops_from_casts: i32[>..<] = [];
    // AllUsersGEPSWithStoresLoads
    var all_gep_users = true;
    var pointers: i32[>..<] = [];
    var user_sty: i32 = -1;
    for x in slp_eu {
        var usr = x.user;
        if usr >= 0 && (is_inst_op(usr, OP_ZEXT) || is_inst_op(usr, OP_SEXT)) && slp_has_one_use(usr) { usr = slp_user_back(usr); }
        var acc: i32 = -1;
        if usr >= 0 && is_inst_op(usr, OP_GEP) && slp_has_one_use(usr) {
            let ub = slp_user_back(usr);
            if is_inst_op(ub, OP_LOAD) || is_inst_op(ub, OP_STORE) { acc = slp_value_type(ub, false); }
        }
        if acc >= 0 && ty_kind(acc) != TK_SVEC && (user_sty < 0 || user_sty == acc) { user_sty = acc; pointers.push(usr); }
        else { all_gep_users = false; break; }
    }
    // ScalarToExtractBlock
    var s2b_s: i32[>..<] = [];
    var s2b_b: i32[>..<] = [];
    for x in slp_eu {
        if x.user < 0 || is_inst_op(x.user, OP_INSERTELEMENT) { continue; }
        if slp_is_ephemeral(x.user) { continue; }
        let up = inst_parent(x.user);
        let term = block_terminator(up);
        if !slp_reachable(up) || inst_is_eh_pad(first_non_phi(up)) || (term >= 0 && iop(term) == OP_UNREACHABLE) { continue; }
        var ub: i32 = -1;
        if is_inst_op(x.user, OP_PHI) {
            if li_loop_for(inst_parent(x.user)) >= 0 {
                for k in phi_nincoming(x.user) {
                    if op(x.user, k) != x.scalar { continue; }
                    let inbb = phi_block(x.user, k);
                    ub = if ub >= 0 { dt_find_ncd(DT_DOM, ub, inbb) } else { inbb };
                }
            }
            if ub < 0 { ub = inst_parent(x.user); }
        } else {
            ub = inst_parent(x.user);
        }
        var found = false;
        for k in s2b_s.len {
            if s2b_s[k] == x.scalar { found = true; if s2b_b[k] >= 0 && ub >= 0 { s2b_b[k] = dt_find_ncd(DT_DOM, s2b_b[k], ub); } break; }
        }
        if !found { s2b_s.push(x.scalar); s2b_b.push(ub); }
    }
    var csu_s: i32[>..<] = [];      // CheckedScalarUser
    var csu_u: i32[>..<] = [];
    fn csu_has(a: i32, b: i32) -> bool { for k in csu_s.len { if csu_s[k] == a && csu_u[k] == b { return true; } } return false; }
    var ecc: i32[>..<] = [];        // ExtractCostCalculated (scalar; struct indices are not supported)
    fn is_phi_in_loop(eu: SEU) -> bool {
        if eu.user >= 0 && is_inst_op(eu.user, OP_PHI) {
            let l = li_loop_for(inst_parent(eu.user));
            return l >= 0 && (inst_parent(eu.user) == inst_parent(eu.scalar) || l == li_loop_for(inst_parent(eu.scalar)));
        }
        return false;
    }
    fn vte_find(v: i32) -> i64 { for k in vte_k.len { if vte_k[k] == v { return vte_i[k]; } } return -1; }
    var ei: i64 = 0;
    while ei < slp_eu.len {
        let x = slp_eu[ei];
        let this_ei = ei;
        ei++;
        if slp_dbg_on {
            errs("SLP: Computing cost for external use of TreeEntry "); errs_int(x.te as i64); errs(" in lane "); errs_int(x.lane); errs("\n");
            if x.user >= 0 { errs("  User:"); slp_dv(x.user); errs("\n"); } else { errs("  User: nullptr\n"); }
            errs("  Use: "); slp_name_or_as_operand(x.scalar); errs("\n");
            slp_dbg_flush();
        }
        if x.user >= 0 && slp_is_ephemeral(x.user) { continue; }
        if csu_has(x.scalar, x.user) || (x.user >= 0 && csu_has(x.scalar, -1)) { continue; }
        csu_s.push(x.scalar); csu_u.push(x.user);
        if x.user >= 0 {
            let up = inst_parent(x.user);
            let term = block_terminator(up);
            if !slp_reachable(up) || inst_is_eh_pad(first_non_phi(up)) || (term >= 0 && iop(term) == OP_UNREACHABLE) { continue; }
        }
        if ty_is_vector(vals[x.scalar].ty) || ty_is_struct_of_vectors(vals[x.scalar].ty) { continue; }
        if is_inst_op(x.scalar, OP_INSERTVALUE) { continue; }
        if x.user >= 0 && is_inst_op(x.user, OP_INSERTELEMENT) && op(x.user, 1) == x.scalar && ty_kind(vals[x.user].ty) == TK_FVEC {
            let vu = x.user;
            if slp_contains(used_inserts, vu) { continue; }
            used_inserts.push(vu);
            let iidx = slp_element_index(vu, 0);
            if iidx >= 0 {
                let ste = x.te;
                var vec_id: i64 = -1;
                for k in si_first.len { if slp_two_inserts_same_bv(vu, si_first[k]) { vec_id = k; break; } }
                let fty: i32 = vals[vu].ty;
                if vec_id < 0 {
                    si_first.push(vu);
                    si_dem_at.push(si_dem.len);
                    for k in ty_count(fty) { si_dem.push(false); }
                    vec_id = si_first.len - 1;
                    var seen = false;
                    for k in vcasts_te.len { if vcasts_te[k] == ste && vcasts_ty[k] == ty_scalar(fty) { seen = true; } }
                    if slp_te[ste].mbw > 0 && !seen {
                        vcasts_te.push(ste); vcasts_ty.push(ty_scalar(fty));
                        let bwsz = slp_te[ste].mbw as i64;
                        let dsz = slp_dl_bits(ty_scalar(fty));
                        let vo = if dsz < bwsz { OP_TRUNC } else if slp_te[ste].mbw_s { OP_SEXT } else { OP_ZEXT };
                        let c = tv_cast(vo, fty, slp_widened_type(ty_int(bwsz), ty_count(fty)), 0, TCK_RECIP_THROUGHPUT, -1);
                        if slp_dbg_on { errs("SLP: Adding cost "); slp_errs_cost(c); errs(" for extending externally used vector with non-equal minimum bitwidth.\n"); slp_dbg_flush(); }
                        cost = tc_add(cost, c);
                    }
                } else {
                    if slp_is_first_insert_element(vu, si_first[vec_id]) { si_first[vec_id] = vu; }
                }
                var mi: i64 = -1;
                for k in vm_si.len { if vm_si[k] == vec_id && vm_te[k] == ste { mi = k; break; } }
                if mi < 0 {
                    mi = vm_si.len;
                    vm_si.push(vec_id); vm_te.push(ste); vm_at.push(vm_pool.len);
                    for k in ty_count(fty) { vm_pool.push(-1); }
                }
                vm_pool[vm_at[mi] + iidx] = x.lane as i32;
                si_dem[si_dem_at[vec_id] + iidx] = true;
                continue;
            }
        }
        let sty: i32 = vals[x.scalar].ty;
        let bw = te_vector_factor(x.te);
        var vecty = slp_widened_type(sty, bw);
        let entry = x.te;
        if ty_is_struct(vecty) { slp_fail("getTreeCost: extracts of struct-typed scalars"); }
        if !(x.user >= 0 && is_inst_op(x.user, OP_INSERTELEMENT)) {
            if slp_contains(ecc, x.scalar) { continue; }
            ecc.push(x.scalar);
        }
        var extra: i64 = 0;
        if slp_te[entry].mbw > 0 {
            let mint = ty_int(slp_te[entry].mbw as i64);
            let ext = if mb_known_non_negative(x.scalar) { OP_ZEXT } else { OP_SEXT };
            vecty = slp_widened_type(mint, bw);
            extra = tv_extract_with_extend(ext, sty, vecty, x.lane);
            if slp_dbg_on { errs("  ExtractExtend or ExtractSubvec cost: "); slp_errs_cost(extra); errs("\n"); slp_dbg_flush(); }
        } else {
            extra = tv_vec_inst(OP_EXTRACTELEMENT, vecty, x.lane, -1, -1, TCK_RECIP_THROUGHPUT);
            if slp_dbg_on { errs("  ExtractElement cost for "); slp_errs_type(sty); errs(" from "); slp_errs_type(vecty); errs(": "); slp_errs_cost(extra); errs("\n"); slp_dbg_flush(); }
        }
        if entry != 0 || te_opcode(entry) == OP_GEP || te_opcode(entry) == OP_LOAD {
            if !vte_ready {
                vte_ready = true;
                for k in slp_eu.len {
                    if is_phi_in_loop(slp_eu[k]) { continue; }
                    if vte_find(slp_eu[k].scalar) < 0 { vte_k.push(slp_eu[k].scalar); vte_i.push(k); }
                }
            }
            let inst = x.scalar;
            var scost = tv_inst_cost(inst, TCK_RECIP_THROUGHPUT);
            fn operand_is_scalar(v: i32) -> bool {
                if !slp_is_vectorized(v) {
                    if is_inst_op(v, OP_EXTRACTELEMENT) { return !slp_has_one_use(v) || !sh_has(SH_MUSTG, v as i64, 0); }
                    return true;
                }
                if ty_is_struct(vals[v].ty) { return false; }
                return vte_find(v) >= 0;
            }
            var as_scalar = true;
            for k in nops(inst) { if !operand_is_scalar(op(inst, k)) { as_scalar = false; break; } }
            var as_scalar_cast = false;
            if is_cast_op(iop(inst)) && !as_scalar {
                let o = op(inst, 0);
                if is_inst(o) {
                    var all = true;
                    for k in nops(o) { if !operand_is_scalar(op(o, k)) { all = false; break; } }
                    if all {
                        let oc: i64 = if slp_is_vectorized(o) && vte_find(o) < 0 { tv_inst_cost(o, TCK_RECIP_THROUGHPUT) } else { 0 };
                        if tc_add(scost, oc) <= extra { as_scalar = true; as_scalar_cast = true; scost = tc_add(scost, oc); }
                    }
                }
            }
            if as_scalar {
                var keep = scost <= extra;
                var phi_user = (keep || (tc_sub(scost, extra) <= TCC_BASIC && te_nscalars(0) > 2)) && te_has_state(0) && te_opcode(0) == OP_PHI &&
                               !slp_has_n_uses_or_more(inst, SLP_USES_LIMIT);
                if phi_user {
                    var u = vals[inst].first_use;
                    while u >= 0 {
                        let usr = uses[u].user;
                        u = uses[u].next;
                        if (!is_inst_op(usr, OP_PHI) || inst_parent(usr) != inst_parent(te_main(0))) && !slp_is_vectorized(usr) { phi_user = false; break; }
                    }
                }
                if phi_user {
                    var cnt: i64 = 0;
                    for v in te_scalars(entry) { if vte_find(v) >= 0 { cnt++; } }
                    phi_user = cnt <= 2;
                }
                if phi_user {
                    keep = true;
                } else if keep && scost != 0 && tc_sub(extra, scost) <= TCC_BASIC &&
                          (slp_gathered_loads_first < 0 || (entry as i64) < slp_gathered_loads_first) {
                    var cnt: i64 = 0;
                    for v in te_scalars(entry) { if vte_find(v) >= 0 { cnt++; } }
                    var nec: i64 = 0;
                    for k in ec_te.len { if ec_te[k] == entry { nec++; } }
                    cnt -= nec;
                    keep = cnt <= 1 || !slp_is_pow2(cnt);
                }
                if keep {
                    sh_add(SH_EUORIG, x.scalar as i64, 0);
                    for k in nops(inst) {
                        let v = op(inst, k);
                        if ty_is_struct(vals[v].ty) { continue; }
                        let j = vte_find(v);
                        if j >= 0 { slp_eu[j].user = -1; }
                    }
                    extra = scost;
                    if !is_phi_in_loop(x) {
                        var have = false;
                        for k in ec_te.len { if ec_te[k] == entry && ec_i[k] == inst { have = true; } }
                        if !have { ec_te.push(entry); ec_i.push(inst); }
                    }
                    if as_scalar_cast {
                        let o0 = op(inst, 0);
                        if !slp_contains(ops_from_casts, o0) { ops_from_casts.push(o0); }
                        if is_inst(o0) {
                            for k in nops(o0) {
                                let v = op(o0, k);
                                if ty_is_struct(vals[v].ty) { continue; }
                                let j = vte_find(v);
                                if j >= 0 { slp_eu[j].user = -1; }
                            }
                        }
                    }
                }
            }
        }
        let cur_user = slp_eu[this_ei].user;
        if !sh_has(SH_EUORIG, x.scalar as i64, 0) {
            if tc_valid(extra) && extra != 0 {
                if cur_user < 0 {
                    extra = scale_cost(extra, entry, x.scalar, -1);
                } else {
                    var eb: i32 = -1;
                    for k in s2b_s.len { if s2b_s[k] == x.scalar { eb = s2b_b[k]; } }
                    let l = if eb >= 0 { li_loop_for(eb) } else { -1 };
                    if l >= 0 {
                        var one: i32[1] = [x.scalar];
                        let sc = slp_loop_nest_scale(slp_innermost_noninvariant_loop(l, one[..]));
                        if slp_dbg_on { errs("SLP: Extract scale "); errs_int(sc as i64); errs(" (NCD block) for "); slp_name_or_as_operand(x.scalar); errs("\n"); slp_dbg_flush(); }
                        extra = slp_cost_scale(extra, sc);
                    }
                }
            }
        } else {
            extra = scale_cost(extra, entry, x.scalar, cur_user);
        }
        ext_cost = tc_add(ext_cost, extra);
    }
    if all_gep_users && pointers.len > 0 {
        let base = get_underlying_object(pointers[0], 6);
        var all = true;
        for p in pointers { if get_underlying_object(p, 6) != base { all = false; break; } }
        if all {
            let vecty = slp_widened_type(user_sty, te_nscalars(0));
            let sg = slp_pointers_chain_cost(pointers, base, 0, user_sty);
            let vg = slp_pointers_chain_cost(pointers, base, 2, vecty);
            ext_cost = tc_add(ext_cost, scale_cost(tc_sub(vg, sg), 0, -1, -1));
        }
    }
    for v in ops_from_casts {
        sh_add(SH_EUORIG, v as i64, 0);
        var c = slp_tree_entries_head(v);
        while c >= 0 {
            let t = slp_lk[c].x;
            c = slp_lk[c].next;
            if slp_is_transformed_to_gather(t) || slp_is_deleted_node(t) { continue; }
            slp_eu.push(SEU { scalar: v, user: -1, te: t, lane: te_find_lane(t, v) });
            break;
        }
    }
    if vvals.len > 0 && slp_te[0].mbw > 0 { slp_fail("getTreeCost: the reduced value resize cost"); }
    if thr < 0 && slp_te.len > 1 && is_inst_op(te_scalar(0, 0), OP_INSERTELEMENT) && te_has_state(1) && slp_te[1].state == TE_VECTORIZE {
        var all = true;
        for v in te_scalars(1) { if !sh_has(SH_EUORIG, v as i64, 0) { all = false; break; } }
        if all { return TTI_INVALID; }
    }
    cost = tc_add(cost, ext_cost);
    for si in si_first.len {
        let first = si_first[si];
        let base = op(first, 0);
        var ents: i32[>..<] = [];
        var masks_at: i64[>..<] = [];
        for k in vm_si.len { if vm_si[k] == si as i64 { ents.push(vm_te[k]); masks_at.push(vm_at[k]); } }
        let fty: i32 = vals[first].ty;
        let n = ty_count(fty);
        var vf: i64 = 0;
        // ResizeToVF(TE, Mask, ForSingleMask): (entry, identity-found)
        fn resize_to_vf(t: i32, m: const i32[:], single: bool) -> bool {
            var c: i64 = 0;
            let mvf = m.len;
            let vecvf = te_vector_factor(t);
            var large = false;
            for x in m { if x as i64 >= mvf { large = true; } }
            if (mvf != vecvf && large) || !slp_is_identity_mask(m, mvf) {
                if large {
                    var om: i32[>..<] = [];
                    for k in vecvf { om.push(-1); }
                    let lim = if mvf < vecvf { mvf } else { vecvf };
                    for k in lim { om[k] = m[k]; }
                    c = slp_shuffle_cost(SK_PERMUTESINGLESRC, slp_widened_type(vals[te_main(t)].ty, vecvf), om, 0, -1);
                    if slp_dbg_on { errs("SLP: Adding cost "); slp_errs_cost(c); errs(" for final shuffle of insertelement external users.\n"); slp_dump_te(t); errs("SLP: Current total cost = "); slp_errs_cost(cost); errs("\n"); slp_dbg_flush(); }
                    cost = tc_add(cost, c);
                    return true;
                }
                if !single {
                    var rm: i32[>..<] = [];
                    for k in mvf { rm.push(-1); }
                    for k in mvf { if m[k] != -1 { rm[m[k] as i64] = m[k]; } }
                    if !slp_is_identity_mask(rm, mvf) { c = slp_shuffle_cost(SK_PERMUTESINGLESRC, slp_widened_type(vals[te_main(t)].ty, vecvf), rm, 0, -1); }
                    if slp_dbg_on { errs("SLP: Adding cost "); slp_errs_cost(c); errs(" for final shuffle of insertelement external users.\n"); slp_dump_te(t); errs("SLP: Current total cost = "); slp_errs_cost(cost); errs("\n"); slp_dbg_flush(); }
                    cost = tc_add(cost, c);
                }
            }
            return false;
        }
        // EstimateShufflesCost(Mask, TEs): t1 -1 = a single entry
        fn estimate(m: const i32[:], t0: i32, t1: i32) -> i32 {
            if t1 < 0 {
                if vf == 0 { vf = te_vector_factor(t0); }
                let fty2 = slp_widened_type(vals[te_scalar(t0, 0)].ty, vf);
                var trivial = true;
                for k in m.len { if !(m[k] == -1 || ((k as i64) < vf && m[k] as i64 == k)) { trivial = false; break; } }
                if !slp_is_identity_mask(m, vf) && !trivial {
                    var c = slp_shuffle_cost(SK_PERMUTESINGLESRC, fty2, m, 0, -1);
                    c = scale_cost(c, t0, -1, -1);
                    if slp_dbg_on { errs("SLP: Adding cost "); slp_errs_cost(c); errs(" for final shuffle of insertelement external users.\n"); slp_dump_te(t0); errs("SLP: Current total cost = "); slp_errs_cost(cost); errs("\n"); slp_dbg_flush(); }
                    cost = tc_add(cost, c);
                }
                vf = m.len;
                return t0;
            }
            if vf == 0 {
                if t0 >= 0 && te_vector_factor(t0) == te_vector_factor(t1) { vf = te_vector_factor(t0); } else { vf = m.len; }
            }
            let fty2 = slp_widened_type(vals[te_scalar(t1, 0)].ty, vf);
            var c = slp_shuffle_cost(SK_PERMUTETWOSRC, fty2, m, 0, -1);
            c = scale_cost(c, t1, -1, -1);
            if slp_dbg_on {
                errs("SLP: Adding cost "); slp_errs_cost(c); errs(" for final shuffle of vector node and external insertelement users.\n");
                if t0 >= 0 { slp_dump_te(t0); } slp_dump_te(t1); errs("SLP: Current total cost = "); slp_errs_cost(cost); errs("\n"); slp_dbg_flush();
            }
            cost = tc_add(cost, c);
            vf = m.len;
            return t1;
        }
        // performExtractsShuffleAction(ShuffleMask = (ents, masks), Base, GetVF, ResizeToVF, EstimateShufflesCost)
        var mask: i32[>..<] = [];
        for k in n { mask.push(vm_pool[masks_at[0] + k]); }
        var vmi: i64 = 1;
        var prev: i32 = -1;
        var um: bool[>..<] = [];
        slp_build_use_mask(mask.len, mask, 2, um);
        var bu: bool[>..<] = [];
        slp_undef_vector_mask(base, false, um, bu);
        var base_undef = true;
        for b in bu { if !b { base_undef = false; } }
        if !base_undef {
            let r = resize_to_vf(ents[0], mask, false);
            var bp: bool[>..<] = [];
            slp_undef_vector_mask(base, true, um, bp);
            let mvf = mask.len;
            for i in mvf {
                if mask[i] == -1 { mask[i] = if bp[i] { -1 } else { i as i32 }; }
                else { mask[i] = ((if r { i as i64 } else { mask[i] as i64 }) + mvf) as i32; }
            }
            prev = estimate(mask, -1, ents[0]);
        } else if ents.len == 1 {
            let r = resize_to_vf(ents[0], mask, true);
            if r { prev = ents[0]; } else { prev = estimate(mask, ents[0], -1); }
        } else {
            let v1 = te_vector_factor(ents[0]);
            let v2 = te_vector_factor(ents[1]);
            var sec: i32[>..<] = [];
            for k in n { sec.push(vm_pool[masks_at[1] + k]); }
            if v1 == v2 {
                for i in mask.len { if sec[i] != -1 { mask[i] = (sec[i] as i64 + v1) as i32; } }
                prev = estimate(mask, ents[0], ents[1]);
            } else {
                let r1 = resize_to_vf(ents[0], mask, false);
                let r2 = resize_to_vf(ents[1], sec, false);
                let mvf = mask.len;
                for i in mvf {
                    if mask[i] != -1 { if r1 { mask[i] = i as i32; } }
                    else if sec[i] != -1 { mask[i] = ((if r2 { i as i64 } else { sec[i] as i64 }) + mvf) as i32; }
                }
                prev = estimate(mask, ents[0], ents[1]);
            }
            vmi = 2;
        }
        while vmi < ents.len {
            var sec: i32[>..<] = [];
            for k in n { sec.push(vm_pool[masks_at[vmi] + k]); }
            let r = resize_to_vf(ents[vmi], sec, false);
            let mvf = mask.len;
            for i in mvf {
                if sec[i] != -1 { mask[i] = ((if r { i as i64 } else { sec[i] as i64 }) + mvf) as i32; }
                else if mask[i] != -1 { mask[i] = i as i32; }
            }
            prev = estimate(mask, prev, ents[vmi]);
            vmi++;
        }
        let ic = tv_scalarization_overhead(fty, si_dem[si_dem_at[si]..(si_dem_at[si] + n)], true, false, TCK_RECIP_THROUGHPUT);
        cost = tc_sub(cost, ic);
    }
    if slp_reduction_bw != 0 && slp_te[0].mbw > 0 && slp_te[0].mbw as i64 != slp_reduction_bw {
        slp_fail("getTreeCost: the reduced value resize cost (ReductionBitWidth)");
    }
    var spill: i64 = -1;
    if cost < -thr {
        spill = 0;   // getSpillCost: getCostOfKeepingLiveOverCall is 0 on X86 and without a target
        cost = tc_add(cost, spill);
    }
    if slp_dbg_on {
        errs("SLP: Spill Cost = "); if spill >= 0 { slp_errs_cost(spill); } else { errs("<skipped>"); }
        errs(".\nSLP: Extract Cost = "); slp_errs_cost(ext_cost); errs(".\n");
        if rdx_root >= 0 { errs("SLP:  Reduction Cost = "); slp_errs_cost(rdx_cost); errs(".\n"); }
        errs("SLP: Total Cost = "); slp_errs_cost(cost); errs(".\n");
        slp_dbg_flush();
    }
    return cost;
}
fn slp_errs_type(t: i32) { let s = type_str(t); errs(s[..]); }
// Value::getNameOrAsOperand()
fn slp_name_or_as_operand(v: i32) {
    if vals[v].name >= 0 && sbytes(vals[v].name).len > 0 { errs(sbytes(vals[v].name)); return; }
    errs_operand(v, slp_cur_fn, false);
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

