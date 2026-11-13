// SLPVectorizer: BoUpSLP::computeMinimumValueSizes and collectValuesToDemote. Port of
// llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp (lines 26966-27780).
//
// collectValuesToDemote is recursive and shares BitWidth and IsProfitableToDemote by reference across its recursion:
// they are the globals `mb_bw` / `mb_prof`; ToDemote and Visited are globals too (no growable local is live across
// a recursive call). MaxDepthLevel is per call (in and out). The lambdas that take a Checker take its kind.
// MinBWs lives in the tree entries (STE.mbw / mbw_s).
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
import knownbits;
import demandedbits;
import datalayout;
import laa;
import iv_descriptors;
import tti;
import tti_x86;
import tti_vec;
import slp_util;
import slp_tree;
import slp_loads;
import slp_build;
import slp_keys;

var mb_bw: i64 = 0;                 // BitWidth (shared by reference)
var mb_prof: bool = false;          // IsProfitableToDemote (shared by reference)
var mb_todemote: i32[>..<];         // ToDemote
var mb_vis: i32[>..<];              // Visited: entry -> epoch
var mb_vis_epoch: i32 = 0;
var mb_keep: bool[>..<];            // NodesToKeepBWs
var mb_best_cost: i64 = 0;
var mb_best_bw: i64 = 0;
let SH_UILMM: i64 = 37;             // reduction ops whose getRdxKind is an integer min/max (set by slp_hr.goose)

fn slp_te_mbw(te: i32) -> i64 { slp_te[te].mbw as i64 }
fn slp_te_mbw_signed(te: i32) -> bool { slp_te[te].mbw_s }

// SimplifyQuery(*DL): no context, no DT/AC
fn mb_kb(v: i32) -> KB {
    let sc = kb_cxt; let sd = sq_no_dt; let sa = sq_no_ac; let st = sq_no_tli;
    kb_cxt = -1; sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    let r = kb_compute_all(v, 0);
    kb_cxt = sc; sq_no_dt = sd; sq_no_ac = sa; sq_no_tli = st;
    return r;
}
fn mb_known_non_negative(v: i32) -> bool {
    let k = mb_kb(v);
    return kb_is_nonneg(k);
}
// MaskedValueIsZero(V, getBitsSetFrom(OrigBitWidth, lo), SimplifyQuery(*DL))
fn mb_masked_zero_from(v: i32, obw: i64, lo: i64) -> bool {
    let k = mb_kb(v);
    let m = ap_high_bits(obw, obw - lo);
    return ap_is_subset_of(m, k.z);
}
// the number of significant demanded bits: Mask.getBitWidth() - Mask.countl_zero()
fn mb_demanded_width(i: i32) -> i64 {
    let w = ty_bits(ty_scalar(vals[i].ty));
    if w > 64 { slp_fail("DemandedBits of a value wider than 64 bits"); }
    let m = db_demanded_bits(i);
    var b = w - 1;
    var lz: i64 = 0;
    while b >= 0 && ((m >> (b as u64)) & 1) == 0 { lz++; b--; }
    return w - lz;
}
fn mb_known_bits_max_ult(v: i32, bw: i64) -> bool {
    let k = mb_kb(v);
    return ap_ult_u64(ap_not(k.z), bw as u64);
}

// IsPotentiallyTruncated(V, BitWidth) on mb_bw
fn mb_potentially_truncated(v: i32, obw: i64, signed_node: bool) -> bool {
    if is_poison(v) { return true; }
    if slp_lk_count(SH_S2TE, v as i64) > 1 { return false; }
    let signed_val = !mb_known_non_negative(v);
    if (!signed_node || signed_val) && obw > mb_bw {
        if mb_masked_zero_from(v, obw, mb_bw) { return true; }
    }
    let nsb = slp_num_sign_bits(v);
    var bw1 = obw - nsb;
    if signed_node { bw1++; }
    if is_inst(v) {
        var bw2 = mb_demanded_width(v);
        if bw2 < 1 { bw2 = 1; }
        while !signed_node && bw2 < obw {
            if mb_masked_zero_from(v, obw, bw2 - 1) { break; }
            bw2 *= 2;
        }
        if bw2 < bw1 { bw1 = bw2; }
    }
    if bw1 > mb_bw { mb_bw = bw1; }
    return mb_bw > 0 && obw >= mb_bw * 2;
}
fn mb_signed_node(e: i32) -> bool {
    for v in te_scalars(e) { if is_poison(v) { continue; } if !mb_known_non_negative(v) { return true; } }
    return false;
}
fn mb_obw(e: i32) -> i64 { slp_dl_bits(ty_scalar(vals[te_scalar(e, 0)].ty)) }

// FinalAnalysis()
recursive fn mb_final_analysis(e: i32, prof_root: bool, trunc_root: bool, maxdepth0: i64) -> bool, i64 {
    var maxdepth = maxdepth0;
    if !mb_prof { return false, maxdepth; }
    let obw = mb_obw(e);
    let sn = mb_signed_node(e);
    var res = true;
    for v in te_scalars(e) { if !mb_potentially_truncated(v, obw, sn) { res = false; break; } }
    if res && te_is_gather(e) {
        if te_has_state(e) {
            let same = slp_same_values_tree_entry(te_main(e), te_scalars(e), false);
            if same >= 0 {
                let ok, md = slp_collect_values_to_demote(same, prof_root, maxdepth, trunc_root);
                maxdepth = md;
                if ok { mb_todemote.push(e); return true, maxdepth; }
            }
        }
        var bases: i32[>..<] = [];
        for v in te_scalars(e) {
            if !is_inst_op(v, OP_EXTRACTELEMENT) { continue; }
            if !slp_contains_v(bases, op(v, 0)) { bases.push(op(v, 0)); }
        }
        let vf = te_nscalars(e);
        let oty: i32 = vals[te_scalar(e, 0)].ty;
        let nty = ty_int(mb_bw);
        if bases.len <= 2 || slp_number_of_parts(slp_widened_type(oty, vf), oty, 0x7FFFFFFF) >=
                             slp_number_of_parts(slp_widened_type(nty, vf), nty, 0x7FFFFFFF) {
            mb_todemote.push(e);
            return true, maxdepth;
        }
    }
    return res, maxdepth;
}
fn slp_contains_v(xs: const i32[:], v: i32) -> bool { for x in xs { if x == v { return true; } } return false; }

// the operand entries a TryProcessInstruction call looks at: mode 0 = getOperandEntry(E, first + k), mode 1 = the
// two combined entries of a split node
fn mb_operand(e: i32, mode: i64, first: i64, k: i64) -> i32 {
    if mode == 1 { return if k == 0 { te_comb_idx(e, 0) } else { te_comb_idx(e, te_comb_n(e) - 1) }; }
    return slp_operand_entry(e, first + k);
}
// ProcessOperands(Operands, NeedToExit): (ok, NeedToExit, MaxDepthLevel)
recursive fn mb_process_operands(e: i32, mode: i64, first: i64, n: i64, prof_root: bool, trunc_root: bool, maxdepth0: i64) -> bool, bool, i64 {
    var maxdepth = maxdepth0;
    var need_exit = false;
    let init = maxdepth;
    for k in n {
        let o = mb_operand(e, mode, first, k);
        let ok, level = slp_collect_values_to_demote(o, prof_root, init, trunc_root);
        if !ok {
            if !mb_prof { return false, need_exit, maxdepth; }
            need_exit = true;
            let fa, md = mb_final_analysis(e, prof_root, trunc_root, maxdepth);
            maxdepth = md;
            if !fa { return false, need_exit, maxdepth; }
            continue;
        }
        if level > maxdepth { maxdepth = level; }
    }
    return true, need_exit, maxdepth;
}
// the Checker lambdas: 1 shl, 2 lshr, 3 ashr, 4 udiv/urem, 5 min/max call (CompChecker), 6 abs (AbsChecker),
// 7 the intrinsic cost Checker
fn mb_checker(e: i32, kind: i64, bw: i64, obw: i64) -> bool {
    if kind == 7 {
        let ic = te_main(e);
        let id = laa_vector_intrinsic_id_for_call(ic);
        var minbw = slp_bit_ceil(bw);
        let vf = te_nscalars(e);
        var argtys: i32[>..<] = [];
        slp_intrinsic_arg_types(ic, id, vf, minbw, argtys);
        let a, b = slp_vector_call_costs(ic, slp_widened_type(ty_int(minbw), vf), argtys);
        let c = if a < b { a } else { b };
        if c < mb_best_cost { mb_best_cost = c; mb_best_bw = bw; }
        return false;
    }
    for v in te_scalars(e) {
        if kind == 1 {
            if is_poison(v) || te_is_copyable_element(e, v) { continue; }
            if !mb_known_bits_max_ult(op(v, 1), bw) { return false; }
        } else if kind == 2 {
            if is_poison(v) { continue; }
            if te_is_copyable_element(e, v) { if !mb_masked_zero_from(v, obw, bw) { return false; } continue; }
            if !(mb_known_bits_max_ult(op(v, 1), bw) && mb_masked_zero_from(op(v, 0), obw, bw)) { return false; }
        } else if kind == 3 {
            if is_poison(v) { continue; }
            let shifted = obw - bw;
            if te_is_copyable_element(e, v) { if !(shifted < slp_num_sign_bits(v)) { return false; } continue; }
            if !(mb_known_bits_max_ult(op(v, 1), bw) && shifted < slp_num_sign_bits(op(v, 0))) { return false; }
        } else if kind == 4 {
            if te_has_copyable_elements(e) && te_is_copyable_element(e, v) { if !mb_masked_zero_from(v, obw, bw) { return false; } continue; }
            if !(mb_masked_zero_from(op(v, 0), obw, bw) && mb_masked_zero_from(op(v, 1), obw, bw)) { return false; }
        } else if kind == 5 {
            let id = laa_vector_intrinsic_id_for_call(v);
            if id == IID_umin || id == IID_umax {
                if !(mb_masked_zero_from(op(v, 0), obw, bw) && mb_masked_zero_from(op(v, 1), obw, bw)) { return false; }
                continue;
            }
            let sb = obw - bw;
            let s0 = slp_num_sign_bits(op(v, 0));
            let s1 = slp_num_sign_bits(op(v, 1));
            let ok = sb <= s0 && ((sb != s0 && !mb_known_non_negative(op(v, 0))) || mb_masked_zero_from(op(v, 0), obw, bw - 1)) &&
                     sb <= s1 && ((sb != s1 && !mb_known_non_negative(op(v, 1))) || mb_masked_zero_from(op(v, 1), obw, bw - 1));
            if !ok { return false; }
        } else if kind == 6 {
            let sb = obw - bw;
            let s0 = slp_num_sign_bits(op(v, 0));
            let ok = sb <= s0 && ((sb != s0 && !mb_known_non_negative(op(v, 0))) || mb_masked_zero_from(op(v, 0), obw, bw - 1));
            if !ok { return false; }
        }
    }
    return true;
}
// AttemptCheckBitwidth(Checker, NeedToExit): (ok, NeedToExit, MaxDepthLevel)
recursive fn mb_attempt_check_bitwidth(e: i32, kind: i64, prof_root: bool, trunc_root: bool, maxdepth0: i64) -> bool, bool, i64 {
    var maxdepth = maxdepth0;
    let obw = mb_obw(e);
    var best_fail: i64 = 0;
    while mb_bw < obw {
        if mb_checker(e, kind, mb_bw, obw) { return true, false, maxdepth; }
        if best_fail == 0 {
            let fa, md = mb_final_analysis(e, prof_root, trunc_root, maxdepth);
            maxdepth = md;
            if fa { best_fail = mb_bw; }
        }
        mb_bw *= 2;
    }
    if mb_bw >= obw {
        if best_fail == 0 { mb_bw = obw; return false, false, maxdepth; }
        mb_bw = best_fail;
        return true, true, 1;
    }
    return false, false, maxdepth;
}
// TryProcessInstruction(BitWidth, Operands, Checker): n = 0 = no operands, kind 0 = no checker
recursive fn mb_try_process(e: i32, mode: i64, first: i64, n: i64, kind: i64, prof_root: bool, trunc_root: bool, maxdepth0: i64) -> bool, i64 {
    var maxdepth = maxdepth0;
    if n == 0 {
        if !trunc_root { maxdepth = 1; }
        let obw = mb_obw(e);
        let sn = mb_signed_node(e);
        for v in te_scalars(e) { mb_potentially_truncated(v, obw, sn); }
    } else {
        let obw = mb_obw(e);
        let sn = mb_signed_node(e);
        for v in te_scalars(e) { if !slp_has_one_use(v) && !mb_potentially_truncated(v, obw, sn) { return false, maxdepth; } }
        if kind != 0 {
            let ok, ne, md = mb_attempt_check_bitwidth(e, kind, prof_root, trunc_root, maxdepth);
            maxdepth = md;
            if !ok { return false, maxdepth; }
            if ne { return true, maxdepth; }
        }
        let ok2, ne2, md2 = mb_process_operands(e, mode, first, n, prof_root, trunc_root, maxdepth);
        maxdepth = md2;
        if !ok2 { return false, maxdepth; }
        if ne2 { return true, maxdepth; }
    }
    maxdepth++;
    mb_todemote.push(e);
    return mb_prof, maxdepth;
}
// collectValuesToDemote(E, IsProfitableToDemoteRoot, BitWidth = mb_bw, ToDemote, Visited, NodesToKeepBWs,
// MaxDepthLevel, IsProfitableToDemote = mb_prof, IsTruncRoot): (result, MaxDepthLevel)
recursive fn slp_collect_values_to_demote(e: i32, prof_root: bool, maxdepth0: i64, trunc_root: bool) -> bool, i64 {
    let maxdepth = maxdepth0;
    var allc = true;
    for v in te_scalars(e) { if !is_constant(v) { allc = false; break; } }
    if allc { return true, maxdepth; }
    let obw = mb_obw(e);
    if obw == mb_bw { return true, 1; }
    if mb_keep[e as i64] { return false, maxdepth; }
    let sn = mb_signed_node(e);
    var visited_before = mb_vis[e as i64] == mb_vis_epoch;
    var go_final = te_is_gather(e) || visited_before;
    if !visited_before && !te_is_gather(e) { mb_vis[e as i64] = mb_vis_epoch; }
    if !go_final {
        for v in te_scalars(e) {
            if is_constant(v) { continue; }
            var all = true;
            var u = vals[v].first_use;
            while u >= 0 {
                let usr = uses[u].user;
                u = uses[u].next;
                if !(is_inst_op(usr, OP_INSERTELEMENT) && !slp_is_vectorized(usr)) { all = false; break; }
            }
            if all { go_final = true; break; }
        }
    }
    if go_final { return mb_final_analysis(e, prof_root, trunc_root, maxdepth); }
    for v in te_scalars(e) {
        if is_constant(v) { continue; }
        var all = true;
        var u = vals[v].first_use;
        while u >= 0 {
            let usr = uses[u].user;
            u = uses[u].next;
            let ut: i32 = vals[usr].ty;
            let ok = slp_is_vectorized(usr) || (e == 0 && slp_uil_on && slp_uil_contains(usr)) ||
                     (!slp_is_cmp(usr) && ty_is_sized(ut) && ty_kind(ut) != TK_SVEC && slp_dl_bits(ut) <= mb_bw);
            if !ok { all = false; break; }
        }
        if !all && !mb_potentially_truncated(v, obw, sn) { return false, maxdepth; }
    }
    if slp_te[e].state == TE_SPLIT { return mb_try_process(e, 1, 0, 2, 0, prof_root, trunc_root, maxdepth); }
    if te_is_alt_shuffle(e) {
        let ao = te_alt_opcode(e);
        if ao == OP_SHL || ao == OP_ASHR || ao == OP_LSHR || ao == OP_UDIV || ao == OP_SDIV || ao == OP_UREM || ao == OP_SREM {
            return mb_final_analysis(e, prof_root, trunc_root, maxdepth);
        }
    }
    let o = te_opcode(e);
    if o == OP_TRUNC {
        if prof_root { mb_prof = true; }
        return mb_try_process(e, 0, 0, 0, 0, prof_root, trunc_root, maxdepth);
    }
    if o == OP_ZEXT || o == OP_SEXT {
        let ut = slp_te[e].ui_te;
        if ut >= 0 && te_has_state(ut) && te_opcode(ut) == OP_BITCAST && ty_is_fp(ty_scalar(vals[te_main(ut)].ty)) { return false, maxdepth; }
        mb_prof = true;
        return mb_try_process(e, 0, 0, 0, 0, prof_root, trunc_root, maxdepth);
    }
    if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR {
        return mb_try_process(e, 0, 0, 2, 0, prof_root, trunc_root, maxdepth);
    }
    if o == OP_FREEZE { return mb_try_process(e, 0, 0, 1, 0, prof_root, trunc_root, maxdepth); }
    if o == OP_SHL { return mb_try_process(e, 0, 0, 2, 1, prof_root, trunc_root, maxdepth); }
    if o == OP_LSHR { return mb_try_process(e, 0, 0, 2, 2, prof_root, trunc_root, maxdepth); }
    if o == OP_ASHR { return mb_try_process(e, 0, 0, 2, 3, prof_root, trunc_root, maxdepth); }
    if o == OP_UDIV || o == OP_UREM { return mb_try_process(e, 0, 0, 2, 4, prof_root, trunc_root, maxdepth); }
    if o == OP_SELECT { return mb_try_process(e, 0, 1, 2, 0, prof_root, trunc_root, maxdepth); }
    if o == OP_PHI { return mb_try_process(e, 0, 0, te_num_operands(e), 0, prof_root, trunc_root, maxdepth); }
    if o == OP_CALL && inst_iid(te_main(e)) != 0 {
        let ic = te_main(e);
        let id = laa_vector_intrinsic_id_for_call(ic);
        if id == IID_abs || id == IID_smin || id == IID_smax || id == IID_umin || id == IID_umax {
            let nops_: i64 = if id != IID_abs { 2 } else { 1 };
            let ck: i64 = if id != IID_abs { 5 } else { 6 };
            mb_best_cost = TTI_MAXC;
            mb_best_bw = mb_bw;
            let r1, r2, md = mb_attempt_check_bitwidth(e, 7, prof_root, trunc_root, maxdepth);
            mb_bw = mb_best_bw;
            return mb_try_process(e, 0, 0, nops_, ck, prof_root, trunc_root, md);
        }
    }
    return mb_final_analysis(e, prof_root, trunc_root, 1);
}

// computeMinimumValueSizes()
fn slp_compute_minimum_value_sizes() {
    let f: i32 = 0;
    let store_or_ie = te_has_state(f) && (te_opcode(f) == OP_STORE || te_opcode(f) == OP_INSERTELEMENT || te_opcode(f) == OP_INSERTVALUE);
    if (store_or_ie || slp_uil_on) && ebw_n <= 1 &&
       (!slp_cast_bw_valid || slp_cast_bw_min == 0 || slp_cast_bw_max / slp_cast_bw_min <= 2) { return; }
    var node: i64 = 0;
    if store_or_ie && !te_is_gather(f) { node = 1; }
    var trunc_root = false;
    var prof_root = !store_or_ie;
    var root_demotes: i64[>..<] = [];
    mb_keep.clear();
    mb_vis.clear();
    for k in slp_te.len { mb_keep.push(false); mb_vis.push(0); }
    if node != 0 && node < slp_te.len && slp_te[node].state == TE_VECTORIZE && te_opcode(node as i32) == OP_TRUNC {
        trunc_root = true;
        root_demotes.push(node);
        prof_root = true;
        node++;
    }
    if node < slp_te.len && sh_has(SH_ANMBW, te_scalar(node as i32, 0) as i64, 0) { return; }
    fn compute_max_bit_width(e: i32, top: bool, proot: bool, limit: i64, troot: bool, signed_cmp: bool) -> i64 {
        mb_todemote.clear();
        if te_is_gather(e) && troot && slp_te[e].ui_te >= 0 && !mb_keep[e as i64] && (e as i64) > (if store_or_ie { 2 } else { 1 }) {
            let ute = slp_te[e].ui_te;
            var all = true;
            for v in te_scalars(e) {
                if slp_has_one_use(v) || is_constant(v) { continue; }
                if slp_has_n_uses_or_more(v, SLP_USES_LIMIT) { all = false; break; }
                var none = true;
                var u = vals[v].first_use;
                while u >= 0 {
                    let usr = uses[u].user;
                    u = uses[u].next;
                    var tes: i32[>..<] = [];
                    var c = slp_tree_entries_head(usr);
                    while c >= 0 { tes.push(slp_lk[c].x); c = slp_lk[c].next; }
                    if tes.len == 0 || slp_contains_v(tes, ute) { continue; }
                    fn okind(x: i32) -> bool {
                        return is_inst(x) && (is_cast_op(iop(x)) || is_binary_op(iop(x)) || iop(x) == OP_FREEZE || iop(x) == OP_PHI || iop(x) == OP_SELECT);
                    }
                    let um = te_main(ute);
                    if !okind(usr) || is_inst_op(usr, OP_SITOFP) || is_inst_op(usr, OP_UITOFP) ||
                       (te_has_state(ute) && (!okind(um) || iop(um) == OP_SITOFP || iop(um) == OP_UITOFP)) { none = false; break; }
                    let usz = slp_dl_bits(vals[te_scalar(ute, 0)].ty);
                    var allbig = true;
                    for t in tes { if !(slp_te[t].mbw > 0 && slp_te[t].mbw as i64 > usz) { allbig = false; break; } }
                    if allbig { none = false; break; }
                    if slp_dl_bits(vals[usr].ty) > usz { none = false; break; }
                }
                if !none { all = false; break; }
            }
            if all {
                mb_todemote.push(e);
                if slp_te[ute].mbw > 0 { return slp_te[ute].mbw as i64; }
                var mbw = slp_bit_ceil(slp_dl_bits(vals[te_scalar(ute, 0)].ty));
                if mbw < 8 && mbw > 1 { mbw = 8; }
                return mbw;
            }
        }
        if !te_has_state(e) { return 0; }
        let vf = te_vector_factor(e);
        let sty: i32 = vals[te_scalar(e, 0)].ty;
        if !ty_is_int(ty_scalar(sty)) { return 0; }
        for v in te_scalars(e) { if sh_has(SH_ANMBW, v as i64, 0) { return 0; } }
        let nparts = slp_number_of_parts(slp_widened_type(sty, vf), sty, 0x7FFFFFFF);
        var mbw: i64 = 1;
        var known_pos = !signed_cmp;
        if known_pos {
            for r in te_scalars(e) {
                if is_poison(r) { continue; }
                let k = mb_kb(r);
                if !kb_is_nonneg(k) { known_pos = false; break; }
            }
        }
        let ut = slp_te[e].ui_te;
        if !known_pos && !top && ut >= 0 && te_has_state(ut) && te_opcode(ut) == OP_UITOFP {
            let a = slp_dl_bits(vals[te_scalar(ut, 0)].ty);
            let b = slp_dl_bits(sty);
            mbw = if a < b { a } else { b };
        }
        for r in te_scalars(e) {
            if is_poison(r) { continue; }
            let nsb = slp_num_sign_bits(r);
            let ntb = slp_dl_bits(ty_scalar(vals[r].ty));
            var bw1 = ntb - nsb;
            if !known_pos { bw1++; }
            if !is_inst(r) { if bw1 > mbw { mbw = bw1; } continue; }
            let bw2 = mb_demanded_width(r);
            let m = if bw1 < bw2 { bw1 } else { bw2 };
            if m > mbw { mbw = m; }
        }
        if mbw < 8 && mbw > 1 { mbw = 8; }
        let nt = ty_int(slp_bit_ceil(mbw));
        if nparts > 1 && nparts == slp_number_of_parts(slp_widened_type(nt, vf), nt, 0x7FFFFFFF) { return 0; }
        let o = te_opcode(e);
        let iprof = o == OP_TRUNC || o == OP_SEXT || o == OP_ZEXT || nparts > 1;
        mb_vis_epoch++;
        let maxdepth: i64 = if troot { limit } else { 1 };
        mb_prof = iprof;
        mb_bw = mbw;
        let ok, md = slp_collect_values_to_demote(e, proot, maxdepth, troot);
        mbw = mb_bw;
        if !ok { return 0; }
        if md <= limit {
            let ext = (o == OP_SEXT || o == OP_ZEXT) &&
                      (!top || !(store_or_ie || slp_uil_on) || slp_dl_bits(ty_scalar(sty)) / slp_dl_bits(vals[op(te_main(e), 0)].ty) > 2);
            if !ext { return 0; }
        }
        return slp_bit_ceil(mbw);
    }
    if slp_uil_on && ty_kind(vals[te_scalar(f, 0)].ty) == TK_INT {
        var all_add = true;
        for v in slp_uil_vals { if !(is_poison(v) || iop(v) == OP_ADD) { all_add = false; break; } }
        if all_add && slp_te[f].state == TE_VECTORIZE && te_opcode(f) == OP_ZEXT && vals[op(te_main(f), 0)].ty as i32 == T_I1 {
            slp_reduction_bw = 1;
        } else {
            for v in slp_uil_vals {
                if is_poison(v) { continue; }
                let nsb = slp_num_sign_bits(v);
                let ntb = slp_dl_bits(vals[v].ty);
                var bw1 = ntb - nsb;
                if !mb_known_non_negative(v) { bw1++; }
                var bw2 = bw1;
                if !sh_has(SH_UILMM, v as i64, 0) { bw2 = mb_demanded_width(v); }
                let m = if bw1 < bw2 { bw1 } else { bw2 };
                if m > slp_reduction_bw { slp_reduction_bw = m; }
            }
            if slp_reduction_bw < 8 && slp_reduction_bw > 1 { slp_reduction_bw = 8; }
            slp_reduction_bw = slp_bit_ceil(slp_reduction_bw);
        }
    }
    var top = node == 0;
    while node < slp_te.len && slp_te[node].state == TE_VECTORIZE && te_opcode(node as i32) == OP_TRUNC {
        root_demotes.push(node);
        node++;
        trunc_root = true;
    }
    var signed_cmp = false;
    if slp_uil_on {
        var all = true;
        for v in slp_uil_vals {
            let id = inst_iid(v);
            let isel = is_inst_op(v, OP_SELECT) && slp_is_cmp(op(v, 0)) &&
                       ((inst_pred(op(v, 0)) >= 38 && inst_pred(op(v, 0)) <= 41));
            if !(id == IID_smin || id == IID_smax || (isel && slp_select_is_smin_smax(v))) { all = false; break; }
        }
        signed_cmp = all;
    }
    while node < slp_te.len {
        let root = node as i32;
        var limit: i64 = 2;
        if top && slp_reduction_bw == slp_dl_bits(vals[te_scalar(0, 0)].ty) { limit = 3; }
        let mbw = compute_max_bit_width(root, top, prof_root, limit, trunc_root, signed_cmp);
        if slp_reduction_bw != 0 && (top || root_demotes.len > 0) {
            if mbw != 0 && slp_reduction_bw < mbw { slp_reduction_bw = slp_bit_ceil(mbw); }
            else if mbw == 0 { slp_reduction_bw = 0; }
        }
        for idx in root_demotes {
            var all = true;
            for v in te_scalars(idx as i32) {
                let obw = slp_dl_bits(ty_scalar(vals[v].ty));
                if obw > mbw { if !mb_masked_zero_from(v, obw, mbw) { all = false; break; } } else { all = false; break; }
            }
            if all { mb_todemote.push(idx as i32); }
        }
        root_demotes.clear();
        top = false;
        prof_root = true;
        let root_ty_bits = ty_bits(ty_scalar(vals[te_scalar(root, 0)].ty));
        if ebw_n == 0 {
            node = slp_te.len;
        } else {
            var nidx: i64 = 0;
            loop {
                nidx = ebw_begin();
                ebw_erase(nidx);
                if !(nidx <= node && ebw_n > 0) { break; }
            }
            node = nidx;
            trunc_root = false;
            signed_cmp = false;
            if node < slp_te.len {
                let u = slp_te[node].ui_te;
                trunc_root = u >= 0 && slp_te[node].ui_edge == 0 && te_has_state(u) && te_opcode(u) == OP_TRUNC && !te_is_alt_shuffle(u);
                if u >= 0 && te_has_state(u) && te_opcode(u) == OP_ICMP {
                    for v in te_scalars(u) {
                        if !is_inst_op(v, OP_ICMP) { continue; }
                        let p = inst_pred(v);
                        if (p >= 38 && p <= 41) || !mb_known_non_negative(op(v, 0)) || !mb_known_non_negative(op(v, 1)) { signed_cmp = true; break; }
                    }
                }
            }
        }
        if mbw == 0 || mbw >= root_ty_bits {
            if slp_uil_on { for v in te_scalars(root) { sh_add(SH_ANMBW, v as i64, 0); } }
            for x in mb_todemote { mb_keep[x as i64] = true; }
            continue;
        }
        for x in mb_todemote {
            if slp_te[x].mbw > 0 { continue; }
            var signed = false;
            for r in te_scalars(x) { if is_poison(r) { continue; } if !mb_known_non_negative(r) { signed = true; break; } }
            slp_te[x].mbw = mbw as i32;
            slp_te[x].mbw_s = signed;
        }
    }
}
// m_SMin / m_SMax of a select (cmp + select form)
fn slp_select_is_smin_smax(v: i32) -> bool {
    let f = match_select_pattern_v(v, 0);
    return f == SPF_SMIN || f == SPF_SMAX;
}
