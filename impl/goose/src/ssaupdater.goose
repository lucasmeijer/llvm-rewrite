// SSAUpdater: rewrite uses of a value that now has several definitions, inserting PHIs where needed.
// Port of llvm/lib/Transforms/Utils/SSAUpdater.cpp (Initialize, AddAvailableValue, HasValueForBlock,
// FindValueForBlock, GetValueAtEndOfBlock, GetValueInMiddleOfBlock, RewriteUse, RewriteUseAfterInsertions,
// the SSAUpdaterTraits<SSAUpdater> specialization) and llvm/include/llvm/Transforms/Utils/SSAUpdaterImpl.h
// (BuildBlockList, FindDominators, FindPHIPlacement, FindAvailableVals, FindExistingPHI, CheckIfPHIMatches,
// RecordMatchingPHIs). Also simplifyPHINode (llvm/lib/Analysis/InstructionSimplify.cpp), which both the updater
// and LoopSimplify run on PHIs.
// One updater is active at a time (ssa_init starts a new one); the PHIs it inserted are in ssa_inserted.
import std;
import ir;
import irutil;
import instinfo;
import domtree;

var ssa_ty: i32 = -1;
var ssa_name: u8[>..];
var ssa_av_val: i32[>..];        // AvailableVals, by block index; valid iff ssa_av_stamp matches ssa_epoch
var ssa_av_stamp: i32[>..];
var ssa_epoch: i32 = 0;
var ssa_inserted: i32[>..<];     // InsertedPHIs

// SSAUpdater::Initialize(Ty, Name)
fn ssa_init(ty: i32, name: const u8[:]) {
    ssa_epoch++;
    ssa_ty = ty;
    ssa_name.resize(0);
    ssa_name.append(name);
    ssa_inserted.clear();
}
fn ssa_has_value_for_block(bb: i32) -> bool {
    let k = block_of(bb) as i64;
    return k < ssa_av_stamp.len && ssa_av_stamp[k] == ssa_epoch;
}
// FindValueForBlock: -1 if none
fn ssa_find_value_for_block(bb: i32) -> i32 { if ssa_has_value_for_block(bb) { ssa_av_val[block_of(bb)] } else { -1 } }
fn ssa_add_available_value(bb: i32, v: i32) {
    let k = block_of(bb) as i64;
    while ssa_av_stamp.len <= k { ssa_av_stamp.push(0); ssa_av_val.push(-1); }
    ssa_av_stamp[k] = ssa_epoch;
    ssa_av_val[k] = v;
}

fn ssa_new_phi(reserve: i64, bb: i32) -> i32 {
    let pn = new_inst(OP_PHI, ssa_ty, reserve);
    vals[pn].nops = 0;
    let f = block_first(bb);
    if f >= 0 { inst_insert_before(pn, f); } else { block_append_inst(bb, pn); }
    if ssa_name.len > 0 { set_name(pn, ssa_name); }
    return pn;
}

// ---------------------------------------------------------------------------------------------
// simplifyPHINode. use_dt: a SimplifyQuery with the DominatorTree (else valueDominatesPHI only knows that
// arguments, constants and entry-block instructions dominate).

// isGuaranteedNotToBePoison: only the cases that need no analysis; anything else fails loudly.
fn phi_not_poison(v: i32) -> bool {
    let k = vals[v].kind;
    if k == VK_CINT || k == VK_CFP || k == VK_CNULL { return true; }
    fatal("isGuaranteedNotToBePoison is not ported for this value (simplifyPHINode with undef inputs)");
    return false;
}

fn simplify_phi_node(pn: i32, use_dt: bool) -> i32 {
    var common: i32 = -1;
    var has_poison = false;
    var has_undef = false;
    for k in phi_nincoming(pn) {
        let x = phi_value(pn, k);
        if x == pn { continue; }
        if vals[x].kind == VK_POISON { has_poison = true; continue; }
        if vals[x].kind == VK_UNDEF { has_undef = true; continue; }
        if common >= 0 && x != common { return -1; }
        common = x;
    }
    if common < 0 { return if has_undef { c_undef(vals[pn].ty) } else { c_poison(vals[pn].ty) }; }
    if has_poison || has_undef {
        // valueDominatesPHI
        if is_inst(common) {
            if use_dt {
                if !dt_value_dominates_inst(common, pn) { return -1; }
            } else {
                let cb = inst_parent(common);
                let o = iop(common);
                if !(cb == func_entry(block_func(cb)) && o != OP_INVOKE && o != OP_CALLBR) { return -1; }
            }
        }
        if has_undef && !phi_not_poison(common) { return -1; }
    }
    return common;
}
// simplifyInstruction(PN, Q): a result equal to the PHI itself (unreachable code) becomes poison.
fn simplify_phi(pn: i32, use_dt: bool) -> i32 {
    let r = simplify_phi_node(pn, use_dt);
    if r == pn { return c_poison(vals[pn].ty); }
    return r;
}

// ---------------------------------------------------------------------------------------------
// SSAUpdaterImpl<SSAUpdater>::GetValue(BB)

struct SBBInfo { bb: i32, aval: i32, defbb: i32, blknum: i32, idom: i32, preds_at: i32, npreds: i32, phitag: i32 }

var si_infos: SBBInfo[>..<];
var si_preds: i32[>..<];
var si_map: i32[>..];            // block index -> info index, stamped with si_epoch
var si_map_stamp: i32[>..];
var si_epoch: i32 = 0;

fn si_lookup(bb: i32) -> i32 {
    let k = block_of(bb) as i64;
    if k < si_map_stamp.len && si_map_stamp[k] == si_epoch { return si_map[k]; }
    return -1;
}
fn si_set(bb: i32, info: i32) {
    let k = block_of(bb) as i64;
    while si_map_stamp.len <= k { si_map_stamp.push(0); si_map.push(-1); }
    si_map_stamp[k] = si_epoch;
    si_map[k] = info;
}
fn si_new(bb: i32, v: i32) -> i32 {
    let id = si_infos.len as i32;
    si_infos.push(SBBInfo { bb: bb, aval: v, defbb: if v >= 0 { id } else { -1 }, blknum: 0, idom: -1, preds_at: 0, npreds: 0, phitag: -1 });
    return id;
}
fn si_pred(info: i32, p: i64) -> i32 { si_preds[si_infos[info].preds_at + p] }

// Traits::FindPredecessorBlocks: the first PHI's incoming blocks, else predecessors().
fn si_find_preds(bb: i32, out: i32[>..<]&) {
    out.clear();
    let f = block_first(bb);
    if f >= 0 && iop(f) == OP_PHI { for k in phi_nincoming(f) { out.push(phi_block(f, k)); } }
    else { each_pred(bb) { p => out.push(p); }; }
}

// IntersectDominators
fn si_intersect(b1: i32, b2: i32) -> i32 {
    var x = b1;
    var y = b2;
    while x != y {
        while si_infos[x].blknum < si_infos[y].blknum {
            x = si_infos[x].idom;
            if x < 0 { return y; }
        }
        while si_infos[y].blknum < si_infos[x].blknum {
            y = si_infos[y].idom;
            if y < 0 { return x; }
        }
    }
    return x;
}

// IsDefInDomFrontier
fn si_def_in_dom_frontier(pred: i32, idom: i32) -> bool {
    var p = pred;
    while p != idom {
        if si_infos[p].defbb == p { return true; }
        p = si_infos[p].idom;
    }
    return false;
}

// CheckIfPHIMatches + RecordMatchingPHIs; tagged collects the infos tagged during the check.
fn si_check_phi_matches(phi0: i32, tagged: i32[>..<]&) -> bool {
    var wl: i32[>..<] = [];
    wl.push(phi0);
    let pb = si_lookup(inst_parent(phi0));
    si_infos[pb].phitag = phi0;
    tagged.push(pb);
    var ok = true;
    while wl.len > 0 && ok {
        let phi = wl.pop();
        for k in phi_nincoming(phi) {
            let iv = phi_value(phi, k);
            var pi = si_lookup(phi_block(phi, k));
            if si_infos[pi].defbb != pi { pi = si_infos[pi].defbb; }
            if si_infos[pi].aval >= 0 {
                if iv == si_infos[pi].aval { continue; }
                ok = false;
                break;
            }
            if !(is_inst(iv) && iop(iv) == OP_PHI) || inst_parent(iv) != si_infos[pi].bb { ok = false; break; }
            if si_infos[pi].phitag >= 0 {
                if iv == si_infos[pi].phitag { continue; }
                ok = false;
                break;
            }
            si_infos[pi].phitag = iv;
            tagged.push(pi);
            wl.push(iv);
        }
    }
    if !ok {
        for t in tagged { si_infos[t].phitag = -1; }
        tagged.clear();
    }
    return ok;
}

fn si_find_existing_phi(bb: i32) {
    var tagged: i32[>..<] = [];
    var count = 0;
    var p = block_first(bb);
    while p >= 0 && iop(p) == OP_PHI {
        count++;
        if count > 80 { break; }        // -ssaupdater-phi-search-limit
        if si_check_phi_matches(p, tagged) {
            for t in tagged {
                let phi = si_infos[t].phitag;
                let pbb = inst_parent(phi);
                ssa_add_available_value(pbb, phi);
                let bi = si_lookup(pbb);
                si_infos[bi].aval = phi;
            }
            break;
        }
        p = inst_next(p);
    }
}

fn ssa_impl_get_value(bb: i32) -> i32 {
    si_epoch++;
    si_infos.clear();
    si_preds.clear();
    var list: i32[>..<] = [];       // BlockList
    // BuildBlockList
    var roots: i32[>..<] = [];
    var wl: i32[>..<] = [];
    var preds: i32[>..<] = [];
    let first = si_new(bb, -1);
    si_set(bb, first);
    wl.push(first);
    while wl.len > 0 {
        let info = wl.pop();
        si_find_preds(si_infos[info].bb, preds);
        si_infos[info].npreds = preds.len as i32;
        si_infos[info].preds_at = si_preds.len as i32;
        for p in preds { si_preds.push(-1); }
        for pk, idx in preds {
            let ex = si_lookup(pk);
            if ex >= 0 { si_preds[si_infos[info].preds_at + idx] = ex; continue; }
            let pv = ssa_find_value_for_block(pk);
            let pi = si_new(pk, pv);
            si_set(pk, pi);
            si_preds[si_infos[info].preds_at + idx] = pi;
            if pv >= 0 { roots.push(pi); continue; }
            wl.push(pi);
        }
    }
    let pseudo = si_new(-1, -1);
    var blknum: i32 = 1;
    while roots.len > 0 {
        let info = roots.pop();
        si_infos[info].idom = pseudo;
        si_infos[info].blknum = -1;
        wl.push(info);
    }
    while wl.len > 0 {
        let info = wl[wl.len - 1];
        if si_infos[info].blknum == -2 {
            si_infos[info].blknum = blknum;
            blknum++;
            if si_infos[info].aval < 0 { list.push(info); }
            wl.pop();
            continue;
        }
        si_infos[info].blknum = -2;
        let tm = block_terminator(si_infos[info].bb);
        if tm >= 0 {
            for k in term_nsucc(tm) {
                let si = si_lookup(term_succ(tm, k));
                if si < 0 || si_infos[si].blknum != 0 { continue; }
                si_infos[si].blknum = -1;
                wl.push(si);
            }
        }
    }
    si_infos[pseudo].blknum = blknum;
    if list.len == 0 {
        let v = c_poison(ssa_ty);
        ssa_add_available_value(bb, v);
        return v;
    }
    // FindDominators
    loop {
        var changed = false;
        var i = list.len;
        while i > 0 {
            i--;
            let info = list[i];
            var nidom: i32 = -1;
            for p in si_infos[info].npreds {
                let pred = si_pred(info, p as i64);
                if si_infos[pred].blknum == 0 {
                    let pv = c_poison(ssa_ty);
                    si_infos[pred].aval = pv;
                    ssa_add_available_value(si_infos[pred].bb, pv);
                    si_infos[pred].defbb = pred;
                    si_infos[pred].blknum = si_infos[pseudo].blknum;
                    si_infos[pseudo].blknum += 1;
                }
                if nidom < 0 { nidom = pred; } else { nidom = si_intersect(nidom, pred); }
            }
            if nidom >= 0 && nidom != si_infos[info].idom { si_infos[info].idom = nidom; changed = true; }
        }
        if !changed { break; }
    }
    // FindPHIPlacement
    loop {
        var changed = false;
        var i = list.len;
        while i > 0 {
            i--;
            let info = list[i];
            if si_infos[info].defbb == info { continue; }
            var ndef = si_infos[si_infos[info].idom].defbb;
            for p in si_infos[info].npreds {
                if si_def_in_dom_frontier(si_pred(info, p as i64), si_infos[info].idom) { ndef = info; break; }
            }
            if ndef != si_infos[info].defbb { si_infos[info].defbb = ndef; changed = true; }
        }
        if !changed { break; }
    }
    // FindAvailableVals
    for info in list {
        if si_infos[info].defbb != info { continue; }
        // FindSingularVal
        let np = si_infos[info].npreds as i64;
        if np > 0 {
            let sing = si_infos[si_infos[si_pred(info, 0)].defbb].aval;
            var ok = sing >= 0;
            if ok {
                for p in 1..np {
                    let pd = si_infos[si_pred(info, p)].defbb;
                    let pv = if pd >= 0 { si_infos[pd].aval } else { -1 };
                    if pv < 0 || pv != sing { ok = false; break; }
                }
            }
            if ok {
                ssa_add_available_value(si_infos[info].bb, sing);
                si_infos[info].aval = sing;
                si_infos[info].defbb = si_infos[si_pred(info, 0)].defbb;
                continue;
            }
        }
        si_find_existing_phi(si_infos[info].bb);
        if si_infos[info].aval >= 0 { continue; }
        let phi = ssa_new_phi(np, si_infos[info].bb);
        si_infos[info].aval = phi;
        ssa_add_available_value(si_infos[info].bb, phi);
    }
    var i = list.len;
    while i > 0 {
        i--;
        let info = list[i];
        if si_infos[info].defbb != info {
            ssa_add_available_value(si_infos[info].bb, si_infos[si_infos[info].defbb].aval);
            continue;
        }
        // ValueIsNewPHI
        let phi = si_infos[info].aval;
        if !(is_inst(phi) && iop(phi) == OP_PHI && nops(phi) == 0) { continue; }
        for p in si_infos[info].npreds {
            var pi = si_pred(info, p as i64);
            let pred = si_infos[pi].bb;
            if si_infos[pi].defbb != pi { pi = si_infos[pi].defbb; }
            phi_add_incoming(phi, si_infos[pi].aval, pred);
        }
        ssa_inserted.push(phi);
    }
    let bi = si_lookup(bb);
    return si_infos[si_infos[bi].defbb].aval;
}

// GetValueAtEndOfBlock(BB)
fn ssa_get_value_at_end_of_block(bb: i32) -> i32 {
    let v = ssa_find_value_for_block(bb);
    if v >= 0 { return v; }
    return ssa_impl_get_value(bb);
}

// GetValueInMiddleOfBlock(BB)
fn ssa_get_value_in_middle_of_block(bb: i32) -> i32 {
    if !ssa_has_value_for_block(bb) { return ssa_get_value_at_end_of_block(bb); }
    var pb: i32[>..<] = [];
    var pv: i32[>..<] = [];
    var single: i32 = -1;
    let f = block_first(bb);
    let has_phi = f >= 0 && iop(f) == OP_PHI;
    var preds: i32[>..<] = [];
    if has_phi { for k in phi_nincoming(f) { preds.push(phi_block(f, k)); } }
    else { each_pred(bb) { p => preds.push(p); }; }
    for p, i in preds {
        let v = ssa_get_value_at_end_of_block(p);
        pb.push(p);
        pv.push(v);
        if i == 0 { single = v; } else if v != single { single = -1; }
    }
    if pb.len == 0 { return c_poison(ssa_ty); }
    if single >= 0 { return single; }
    if has_phi {
        // IsEquivalentPHI against the (first-wins) map of PredValues
        var distinct: i64 = 0;
        for p, i in pb { if position(pb[..i], p) < 0 { distinct++; } }
        var p = f;
        while p >= 0 && iop(p) == OP_PHI {
            var eq = phi_nincoming(p) == distinct;
            if eq {
                for k in phi_nincoming(p) {
                    let j = position(pb, phi_block(p, k));
                    if j < 0 || pv[j] != phi_value(p, k) { eq = false; break; }
                }
            }
            if eq { return p; }
            p = inst_next(p);
        }
    }
    let phi = ssa_new_phi(pb.len, bb);
    for k in pb.len { phi_add_incoming(phi, pv[k], pb[k]); }
    let sv = simplify_phi(phi, false);
    if sv >= 0 {
        inst_erase_from_parent(phi);
        return sv;
    }
    let fnp = first_non_phi(bb);
    if fnp >= 0 { let dl = inst_get_md(fnp, 0); if dl >= 0 { inst_set_md(phi, 0, dl); } }
    ssa_inserted.push(phi);
    return phi;
}

// RewriteUse(U)
fn ssa_rewrite_use(u: i32) {
    let user = uses[u].user;
    let v = if iop(user) == OP_PHI { ssa_get_value_at_end_of_block(use_aux[u]) } else { ssa_get_value_in_middle_of_block(inst_parent(user)) };
    use_set(u, v);
}

// RewriteUseAfterInsertions(U)
fn ssa_rewrite_use_after_insertions(u: i32) {
    let user = uses[u].user;
    let bb = if iop(user) == OP_PHI { use_aux[u] } else { inst_parent(user) };
    use_set(u, ssa_get_value_at_end_of_block(bb));
}
