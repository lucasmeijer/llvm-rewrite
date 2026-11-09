// DomTreeUpdater: batches CFG updates for a function's dominator and post-dominator trees, eagerly or lazily.
// Port of llvm/include/llvm/Analysis/GenericDomTreeUpdater.h, GenericDomTreeUpdaterImpl.h and
// llvm/lib/Analysis/DomTreeUpdater.cpp (deleteBB, validateDeleteBB, forceFlushDeletedBB). One updater is
// active at a time (dtu_begin ... dtu_end, where dtu_end is the C++ destructor: it flushes).
// callbackDeleteBB is not ported.
import std;
import ir;
import irutil;
import domtree;

struct DTUPend { split: bool, kind: i32, from: i32, to: i32, nb: i32 }

var dtu_f: i32 = -1;
var dtu_dt: bool = false;           // DT != nullptr
var dtu_pdt: bool = false;          // PDT != nullptr
var dtu_lazy: bool = false;
var dtu_pend: DTUPend[>..<];         // PendUpdates
var dtu_dt_idx: i64 = 0;             // PendDTUpdateIndex
var dtu_pdt_idx: i64 = 0;            // PendPDTUpdateIndex
var dtu_deleted: i32[>..<];          // DeletedBBs (SmallPtrSet; iterated in insertion order)
var dtu_del_stamp: u32[>..];         // membership in DeletedBBs: block index -> dtu_del_epoch
var dtu_del_epoch: u32 = 1;
fn dtu_deleted_clear() { dtu_deleted.clear(); dtu_del_epoch += 1; }
fn dtu_deleted_has(bb: i32) -> bool { let b = block_of(bb) as i64; return b < dtu_del_stamp.len && dtu_del_stamp[b] == dtu_del_epoch; }
fn dtu_deleted_insert(bb: i32) {
    if dtu_deleted_has(bb) { return; }
    let b = block_of(bb) as i64;
    while dtu_del_stamp.len <= b { dtu_del_stamp.push(0); }
    dtu_del_stamp[b] = dtu_del_epoch;
    dtu_deleted.push(bb);
}
var dtu_recalc_dt: bool = false;     // IsRecalculatingDomTree
var dtu_recalc_pdt: bool = false;

// DomTreeUpdater(DT, PDT, Strategy). Pass use_dt / use_pdt only for trees the pass has (cached or required);
// a tree that isn't valid is treated as absent.
fn dtu_begin(fv: i32, use_dt: bool, use_pdt: bool, lazy: bool) {
    if dtu_f >= 0 { fatal("internal: nested DomTreeUpdater"); }
    dtu_f = fv;
    dtu_dt = use_dt && dt_valid(fv, DT_DOM);
    dtu_pdt = use_pdt && dt_valid(fv, DT_POST);
    dtu_lazy = lazy;
    dtu_pend.clear();
    dtu_dt_idx = 0;
    dtu_pdt_idx = 0;
    dtu_deleted_clear();
    dtu_recalc_dt = false;
    dtu_recalc_pdt = false;
}
// ~DomTreeUpdater
fn dtu_end() {
    dtu_flush();
    dtu_f = -1;
}

fn dtu_has_pending_dt_updates() -> bool { dtu_dt && dtu_pend.len != dtu_dt_idx }
fn dtu_has_pending_pdt_updates() -> bool { dtu_pdt && dtu_pend.len != dtu_pdt_idx }
fn dtu_has_pending_updates() -> bool { dtu_has_pending_dt_updates() || dtu_has_pending_pdt_updates() }
fn dtu_is_bb_pending_deletion(bb: i32) -> bool {
    if !dtu_lazy || dtu_deleted.len == 0 { return false; }
    return dtu_deleted_has(bb);
}

fn dtu_tree_updates(t: i64, ups: const DTUpdate[:]) { dt_apply_updates(dtu_f, t, ups); }

// splitDTCriticalEdges(Edges)
fn dtu_split_dt_critical_edges(es: const DTUPend[:]) {
    if !dtu_dt || es.len == 0 { return; }
    let f = dtu_f;
    var newbbs: i32[>..<] = [];
    for e in es { newbbs.push(e.nb); }
    var is_new_idom: bool[>..<] = [];
    for e in es {
        let succ = e.to;
        var ok = true;
        var done = false;
        each_pred(succ) { p0 =>
            if !done && p0 != e.nb {
                var p = p0;
                if position(newbbs, p) >= 0 {
                    // the single predecessor of a split block
                    var q: i32 = -1;
                    each_pred(p) { x => if q < 0 { q = x; } };
                    p = q;
                }
                let sn = if dt_has_node(DT_DOM, succ) { succ } else { -1 };
                let pn = if dt_has_node(DT_DOM, p) { p } else { -1 };
                if !dt_dominates_nodes(f, DT_DOM, sn, pn) { ok = false; done = true; }
            }
        };
        is_new_idom.push(ok);
    }
    for e, i in es {
        dt_add_new_block(f, DT_DOM, e.nb, e.from);
        if is_new_idom[i] { dt_change_idom(f, DT_DOM, e.to, e.nb); }
    }
}

// splitPDTCriticalEdges(Edges)
fn dtu_split_pdt_critical_edges(es: const DTUPend[:]) {
    if !dtu_pdt || es.len == 0 { return; }
    var ups: DTUpdate[>..<] = [];
    for e in es {
        ups.push(DTUpdate { kind: DT_INSERT, from: e.from, to: e.nb });
        ups.push(DTUpdate { kind: DT_INSERT, from: e.nb, to: e.to });
        if !block_has_succ(e.from, e.to) { ups.push(DTUpdate { kind: DT_DELETE, from: e.from, to: e.to }); }
    }
    dtu_tree_updates(DT_POST, ups);
}

fn block_has_succ(b: i32, s: i32) -> bool {
    let tm = block_terminator(b);
    if tm < 0 { return false; }
    for k in term_nsucc(tm) { if term_succ(tm, k) == s { return true; } }
    return false;
}

// applyUpdatesImpl<IsForward>
fn dtu_apply_impl(fwd: bool) {
    let has = if fwd { dtu_dt } else { dtu_pdt };
    if !dtu_lazy || !has { return; }
    var buf: DTUpdate[>..<] = [];
    var ebuf: DTUPend[>..<] = [];
    loop {
        let idx = if fwd { dtu_dt_idx } else { dtu_pdt_idx };
        if idx == dtu_pend.len { break; }
        var i = idx;
        if !dtu_pend[i].split {
            buf.clear();
            while i < dtu_pend.len && !dtu_pend[i].split {
                buf.push(DTUpdate { kind: dtu_pend[i].kind, from: dtu_pend[i].from, to: dtu_pend[i].to });
                i++;
            }
            dtu_tree_updates(if fwd { DT_DOM } else { DT_POST }, buf);
        } else {
            ebuf.clear();
            while i < dtu_pend.len && dtu_pend[i].split { ebuf.push(dtu_pend[i]); i++; }
            if fwd { dtu_split_dt_critical_edges(ebuf); } else { dtu_split_pdt_critical_edges(ebuf); }
        }
        if fwd { dtu_dt_idx = i; } else { dtu_pdt_idx = i; }
    }
}

// eraseDelBBNode
fn dtu_erase_del_bb_node(bb: i32) {
    if dtu_dt && !dtu_recalc_dt && dt_has_node(DT_DOM, bb) { dt_erase_node(dtu_f, DT_DOM, bb); }
    if dtu_pdt && !dtu_recalc_pdt && dt_has_node(DT_POST, bb) { dt_erase_node(dtu_f, DT_POST, bb); }
}

// forceFlushDeletedBB
fn dtu_force_flush_deleted_bb() -> bool {
    if dtu_deleted.len == 0 { return false; }
    for bb in dtu_deleted {
        dtu_erase_del_bb_node(bb);
        block_erase(bb);
    }
    dtu_deleted_clear();
    return true;
}

// dropOutOfDateUpdates
fn dtu_drop_out_of_date_updates() {
    if !dtu_lazy { return; }
    if !dtu_has_pending_updates() { dtu_force_flush_deleted_bb(); }
    if !dtu_dt { dtu_dt_idx = dtu_pend.len; }
    if !dtu_pdt { dtu_pdt_idx = dtu_pend.len; }
    let drop = min(dtu_dt_idx, dtu_pdt_idx);
    if drop > 0 {
        let n = dtu_pend.len;
        for k in drop..n { dtu_pend[k - drop] = dtu_pend[k]; }
        dtu_pend.resize(n - drop);
    }
    dtu_dt_idx -= drop;
    dtu_pdt_idx -= drop;
}

fn dtu_flush() {
    dtu_apply_impl(true);
    dtu_apply_impl(false);
    dtu_drop_out_of_date_updates();
}

// getDomTree / getPostDomTree: bring that tree up to date.
fn dtu_get_dt() { dtu_apply_impl(true); dtu_drop_out_of_date_updates(); }
fn dtu_get_pdt() { dtu_apply_impl(false); dtu_drop_out_of_date_updates(); }

// applyUpdates(Updates)
fn dtu_apply_updates(ups: const DTUpdate[:]) {
    if !dtu_dt && !dtu_pdt { return; }
    if dtu_lazy {
        for u in ups { if u.from != u.to { dtu_pend.push(DTUPend { split: false, kind: u.kind, from: u.from, to: u.to, nb: -1 }); } }
        return;
    }
    if dtu_dt { dtu_tree_updates(DT_DOM, ups); }
    if dtu_pdt { dtu_tree_updates(DT_POST, ups); }
}

// isUpdateValid
fn dtu_is_update_valid(u: DTUpdate) -> bool {
    let has_edge = block_has_succ(u.from, u.to);
    if u.kind == DT_INSERT && !has_edge { return false; }
    if u.kind == DT_DELETE && has_edge { return false; }
    return true;
}

// applyUpdatesPermissive(Updates)
fn dtu_apply_updates_permissive(ups: const DTUpdate[:]) {
    if !dtu_dt && !dtu_pdt { return; }
    var seen_f: i32[>..<] = [];
    var seen_t: i32[>..<] = [];
    var dedup: DTUpdate[>..<] = [];
    for u in ups {
        if u.from == u.to { continue; }
        var seen = false;
        for k in seen_f.len { if seen_f[k] == u.from && seen_t[k] == u.to { seen = true; break; } }
        if seen { continue; }
        seen_f.push(u.from);
        seen_t.push(u.to);
        if dtu_is_update_valid(u) {
            if dtu_lazy { dtu_pend.push(DTUPend { split: false, kind: u.kind, from: u.from, to: u.to, nb: -1 }); }
            else { dedup.push(u); }
        }
    }
    if dtu_lazy { return; }
    if dtu_dt { dtu_tree_updates(DT_DOM, dedup); }
    if dtu_pdt { dtu_tree_updates(DT_POST, dedup); }
}

// splitCriticalEdge(FromBB, ToBB, NewBB)
fn dtu_split_critical_edge(from: i32, to: i32, nb: i32) {
    if !dtu_dt && !dtu_pdt { return; }
    let e = DTUPend { split: true, kind: 0, from: from, to: to, nb: nb };
    if dtu_lazy { dtu_pend.push(e); return; }
    let es: DTUPend[1] = [e];
    if dtu_dt { dtu_split_dt_critical_edges(es); }
    if dtu_pdt { dtu_split_pdt_critical_edges(es); }
}

// recalculate(F)
fn dtu_recalculate() {
    if !dtu_lazy {
        if dtu_dt { dt_recalculate(dtu_f, DT_DOM); }
        if dtu_pdt { dt_recalculate(dtu_f, DT_POST); }
        return;
    }
    dtu_recalc_dt = true;
    dtu_recalc_pdt = true;
    dtu_force_flush_deleted_bb();
    if dtu_dt { dt_recalculate(dtu_f, DT_DOM); }
    if dtu_pdt { dt_recalculate(dtu_f, DT_POST); }
    dtu_recalc_dt = false;
    dtu_recalc_pdt = false;
    dtu_dt_idx = dtu_pend.len;
    dtu_pdt_idx = dtu_pend.len;
    dtu_drop_out_of_date_updates();
}

// validateDeleteBB: drop the instructions (last first, uses replaced by poison) and leave an `unreachable`.
fn dtu_validate_delete_bb(bb: i32) {
    if pred_count(bb) != 0 { fatal("internal: DomTreeUpdater::deleteBB of a block with predecessors"); }
    loop {
        let i = block_last(bb);
        if i < 0 { break; }
        if vals[i].first_use >= 0 { rauw(i, c_poison(vals[i].ty)); }
        inst_erase_from_parent(i);
    }
    let u = create_inst(OP_UNREACHABLE, T_VOID, []);
    block_append_inst(bb, u);
}

// deleteBB(DelBB)
fn dtu_delete_bb(bb: i32) {
    dtu_validate_delete_bb(bb);
    if dtu_lazy {
        dtu_deleted_insert(bb);
        return;
    }
    dtu_erase_del_bb_node(bb);
    block_erase(bb);
}
