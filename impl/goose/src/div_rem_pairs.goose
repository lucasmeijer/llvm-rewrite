// DivRemPairs: port of llvm/lib/Transforms/Scalar/DivRemPairs.cpp (DivRemPairsPass).
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import domtree;
import tti;
import tti_x86_vec;
import vt;
import poison;
import licm;
import sink;
import misc_util;

struct DrKey { signed: bool, a: i32, b: i32 }

fn dr_set_dl(i: i32, dl: i32) { if dl >= 0 { inst_set_md(i, 0, dl); } else { inst_erase_md(i, 0); } }

// matchExpandedRem: returns (ok, key)
fn dr_match_expanded_rem(i: i32) -> bool, DrKey {
    let none = DrKey { signed: false, a: -1, b: -1 };
    if iop(i) != OP_SUB { return false, none; }
    let x = op(i, 0);
    let m = op(i, 1);
    if !is_inst(m) || iop(m) != OP_MUL { return false, none; }
    for k in 2 {
        let d = op(m, k);
        let y = op(m, 1 - k);
        if is_inst(d) && (iop(d) == OP_UDIV || iop(d) == OP_SDIV) && op(d, 0) == x && op(d, 1) == y {
            return true, DrKey { signed: iop(d) == OP_SDIV, a: x, b: y };
        }
    }
    return false, none;
}

fn dr_expanded(r: i32) -> bool { iop(r) != OP_SREM && iop(r) != OP_UREM }

fn dr_has_div_rem_op(t: i32, signed: bool) -> bool { tti_kind == TTI_X86 && x86_has_div_rem_op(t, signed) }

fn dr_safe_to_hoist(i: i32, bb: i32) -> bool {
    var x = block_first(bb);
    while x >= 0 && x != i {
        if !guaranteed_to_transfer(x) { return false; }
        x = inst_next(x);
    }
    return true;
}

fn div_rem_pairs_run(fv: i32) -> u32 {
    tti_init_function(fv, globs[glob_of(fv)].module);
    dt_get(fv, DT_DOM);
    // DivMap (last definition wins) and RemMap (MapVector: first-insertion order, last value)
    var div_keys: DrKey[>..<] = [];
    var div_vals: i32[>..<] = [];
    var rem_keys: DrKey[>..<] = [];
    var rem_vals: i32[>..<] = [];
    fn put(ks: DrKey[>..<]&, vs: i32[>..<]&, k: DrKey, v: i32) {
        for j in ks.len { if ks[j] == k { vs[j] = v; return; } }
        ks.push(k);
        vs.push(v);
    }
    var bb = func_first_block(fv);
    while bb >= 0 {
        var i = block_first(bb);
        while i >= 0 {
            let o = iop(i);
            if o == OP_SDIV || o == OP_UDIV { put(div_keys, div_vals, DrKey { signed: o == OP_SDIV, a: op(i, 0), b: op(i, 1) }, i); }
            else if o == OP_SREM || o == OP_UREM { put(rem_keys, rem_vals, DrKey { signed: o == OP_SREM, a: op(i, 0), b: op(i, 1) }, i); }
            else {
                let ok, k = dr_match_expanded_rem(i);
                if ok { put(rem_keys, rem_vals, k, i); }
            }
            i = inst_next(i);
        }
        bb = block_next(bb);
    }
    var wl_div: i32[>..<] = [];
    var wl_rem: i32[>..<] = [];
    for j in rem_keys.len {
        for d in div_keys.len {
            if div_keys[d] == rem_keys[j] { wl_div.push(div_vals[d]); wl_rem.push(rem_vals[j]); break; }
        }
    }
    let s_ac = sq_no_ac;
    sq_no_ac = true;
    var changed = false;
    for w in wl_div.len {
        let div = wl_div[w];
        var rem = wl_rem[w];
        let signed = iop(div) == OP_SDIV;
        let has = dr_has_div_rem_op(vals[div].ty, signed);
        if has && dr_expanded(rem) {
            let x = op(div, 0);
            let y = op(div, 1);
            let real = create_inst(if signed { OP_SREM } else { OP_UREM }, vals[div].ty, [x, y]);
            inst_insert_after(real, rem);
            set_name(real, str(val_name(rem), ".recomposed"));
            let orig = rem;
            rem = real;
            rauw(orig, real);
            dr_set_dl(real, inst_get_md(orig, 0));
            inst_erase_from_parent(orig);
            changed = true;
        }
        if has && inst_parent(rem) == inst_parent(div) { continue; }
        var div_dom = dt_value_dominates_inst(div, rem);
        if !div_dom && !dt_value_dominates_inst(rem, div) {
            var pred: i32 = -1;
            let dbb = inst_parent(div);
            let rbb = inst_parent(rem);
            let rsucc = if block_nsucc(rbb) == 1 { block_succ(rbb, 0) } else { -1 };
            if rsucc == dbb {
                pred = unique_pred_of(rbb);
            } else {
                let rp = unique_pred_of(rbb);
                if rp >= 0 && has && rp == unique_pred_of(dbb) { pred = rp; }
            }
            var ok = pred >= 0;
            if ok {
                let pt = block_terminator(pred);
                ok = iop(pt) != OP_CATCHSWITCH && guaranteed_to_transfer(pt) && dr_safe_to_hoist(rem, rbb) &&
                     dr_safe_to_hoist(div, dbb);
                if ok {
                    for k in block_nsucc(pred) { let s = block_succ(pred, k); if s != dbb && s != rbb { ok = false; } }
                }
                if ok {
                    each_pred(dbb) { p => if p != rbb && p != pred { ok = false; } };
                }
            }
            if ok {
                div_dom = true;
                lc_move_before(div, block_terminator(pred), false);
                changed = true;
                if has {
                    lc_move_before(rem, block_terminator(pred), false);
                    continue;
                }
            } else { continue; }
        }
        if !has && dr_expanded(rem) { continue; }
        if has {
            if div_dom { inst_move_after(rem, div); } else { inst_move_after(div, rem); }
        } else {
            let x = op(div, 0);
            let y = op(div, 1);
            let mul = create_inst(OP_MUL, vals[div].ty, [div, y]);
            let sub = create_inst(OP_SUB, vals[div].ty, [x, mul]);
            if !div_dom { lc_move_before(div, rem, false); }
            inst_insert_after(mul, rem);
            dr_set_dl(mul, inst_get_md(rem, 0));
            inst_insert_after(sub, mul);
            dr_set_dl(sub, inst_get_md(rem, 0));
            drop_poison_generating_flags(div);
            if !is_guaranteed_not_to_be_undef(x, div, 0) {
                let fr = create_inst(OP_FREEZE, vals[x].ty, [x]);
                inst_insert_before(fr, div);
                set_name(fr, str(val_name(x), ".frozen"));
                dr_set_dl(fr, inst_get_md(div, 0));
                set_op(div, 0, fr);
                set_op(sub, 0, fr);
            }
            if !is_guaranteed_not_to_be_undef(y, div, 0) {
                let fr = create_inst(OP_FREEZE, vals[y].ty, [y]);
                inst_insert_before(fr, div);
                set_name(fr, str(val_name(y), ".frozen"));
                dr_set_dl(fr, inst_get_md(div, 0));
                set_op(div, 1, fr);
                set_op(mul, 1, fr);
            }
            set_name(sub, str(val_name(rem), ".decomposed"));
            let orig = rem;
            rem = sub;
            rauw(orig, sub);
            inst_erase_from_parent(orig);
        }
        changed = true;
    }
    sq_no_ac = s_ac;
    if !changed { return PA_ALL; }
    return PA_CFG;
}
