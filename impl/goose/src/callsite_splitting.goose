// CallSiteSplitting: port of llvm/lib/Transforms/Scalar/CallSiteSplitting.cpp (CallSiteSplittingPass), with
// DuplicateInstructionsInSplitBetween from jt.goose (BasicBlockUtils.cpp / Cloning.cpp).
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import calls;
import flags;
import domtree;
import dtu;
import tli;
import tti;
import tti_x86;
import local;
import cfgutil;
import jt;
import autoupgrade;
import gen_attrs;
import misc_util;

struct CsCond { cmp: i32, pred: i64 }

fn cs_first_non_phi_or_dbg(bb: i32) -> i32 {
    var i = block_first(bb);
    while i >= 0 {
        if iop(i) != OP_PHI && !(iop(i) == OP_CALL && inst_iid(i) == IID_pseudoprobe) { return i; }
        i = inst_next(i);
    }
    return -1;
}

fn cs_set_param_set(cb: i32, k: i64, s: i32) {
    let ii = inst_of(cb);
    insts[ii].attrs = alist_set_param(insts[ii].attrs, k, s);
}
fn cs_add_nonnull(cb: i32, v: i32) {
    for k in cb_nargs(cb) {
        if cb_arg(cb, k) == v {
            let s = alist_param(insts[inst_of(cb)].attrs, k);
            if !aset_has(s, AK_NonNull) { cs_set_param_set(cb, k, aset_with(s, attr_enum(AK_NonNull))); }
        }
    }
}
fn cs_set_constant_in_argument(cb: i32, v: i32, c: i32) {
    for k in cb_nargs(cb) {
        if cb_arg(cb, k) == v {
            let s = alist_param(insts[inst_of(cb)].attrs, k);
            if aset_has(s, AK_NonNull) {
                var xs: i32[>..<] = [];
                for j in aset_n(s) { let a = aset_attr(s, j); if attrs[a].kind as i64 != AK_NonNull { xs.push(a); } }
                cs_set_param_set(cb, k, aset_get(xs));
            }
            set_op(cb, k, c);
        }
    }
}

fn cs_cond_relevant(cmp: i32, cb: i32) -> bool {
    let op0 = op(cmp, 0);
    for k in cb_nargs(cb) {
        let a = cb_arg(cb, k);
        if is_constant(a) || cb_param_has_attr(cb, k, AK_NonNull) { continue; }
        if a == op0 { return true; }
    }
    return false;
}

fn cs_record_condition(cb: i32, from: i32, to: i32, conds: CsCond[>..<]&) {
    let bi = block_terminator(from);
    if bi < 0 || iop(bi) != OP_CONDBR { return; }
    let c = op(bi, 0);
    if !is_inst(c) || iop(c) != OP_ICMP || !is_constant(op(c, 1)) { return; }
    let p = inst_pred(c);
    if p == 32 || p == 33 {
        if cs_cond_relevant(c, cb) {
            let inv = if p == 32 { 33 } else { 32 };
            conds.push(CsCond { cmp: c, pred: if term_succ(bi, 0) == to { p } else { inv } });
        }
    }
}

fn cs_record_conditions(cb: i32, pred: i32, conds: CsCond[>..<]&, stop_at: i32) {
    var from = pred;
    var to = pred;
    var visited: i32[>..<] = [];
    loop {
        if to == stop_at { break; }
        let sp = single_pred(from);
        var seen = false;
        if sp >= 0 { for x in visited { if x == sp { seen = true; } } }
        if seen { break; }
        if sp < 0 { break; }
        from = sp;
        cs_record_condition(cb, from, to, conds);
        visited.push(from);
        to = from;
    }
}

fn cs_add_conditions(cb: i32, conds: const CsCond[:]) {
    for c in conds {
        let arg = op(c.cmp, 0);
        let cv = op(c.cmp, 1);
        if c.pred == 32 { cs_set_constant_in_argument(cb, arg, cv); }
        else if ty_kind(vals[cv].ty) == TK_PTR && is_null_value(cv) { cs_add_nonnull(cb, arg); }
    }
}

fn cs_preds(bb: i32, out: i32[>..<]&) { out.clear(); each_pred(bb) { p => out.push(p); }; }

fn cs_can_split(cb: i32) -> bool {
    if call_has_fn_attr(cb, AK_Convergent) || call_has_fn_attr(cb, AK_NoDuplicate) { return false; }
    if iop(cb) != OP_CALL { return false; }
    let bb = inst_parent(cb);
    var preds: i32[>..<] = [];
    cs_preds(bb, preds);
    if preds.len != 2 || iop(block_terminator(preds[0])) == OP_INDIRECTBR || iop(block_terminator(preds[1])) == OP_INDIRECTBR { return false; }
    let fnp = first_non_phi(bb);
    if fnp >= 0 && iop(fnp) != OP_LANDINGPAD && inst_is_eh_pad(fnp) { return false; }
    if fnp >= 0 && inst_is_eh_pad(fnp) { return false; }
    let thr = flag_int("callsite-splitting-duplication-threshold", 5);
    var cost: i64 = 0;
    var i = block_first(bb);
    while i != cb {
        cost = tc_add(cost, tti_instruction_cost(i, TCK_CODE_SIZE));
        if cost >= thr { return false; }
        i = inst_next(i);
    }
    return true;
}

fn cs_clone_for_musttail(i: i32, before: i32, v: i32) -> i32 {
    let c = inst_clone(i);
    inst_insert_before(c, before);
    if vals[i].name >= 0 { set_name(c, val_name(i)); }
    if v >= 0 { set_op(c, 0, v); }
    return c;
}

fn cs_copy_musttail_return(split: i32, ci: i32, nci: i32) {
    let is_void = ty_fn_ret(func_type(block_func(split))) == T_VOID;
    var ii = inst_next(ci);
    var bci: i32 = -1;
    if iop(ii) == OP_BITCAST { bci = ii; ii = inst_next(ii); }
    let ri = ii;
    let ti = block_terminator(split);
    var v = nci;
    if bci >= 0 { v = cs_clone_for_musttail(bci, ti, v); }
    cs_clone_for_musttail(ri, ti, if is_void { -1 } else { v });
}

fn cs_split_call_site(cb: i32, ppreds: const i32[:], c0: const CsCond[:], c1: const CsCond[:]) {
    let tail = inst_parent(cb);
    let musttail = insts[inst_of(cb)].pred == 2;
    var call_pn: i32 = -1;
    if !musttail && vals[cb].first_use >= 0 {
        call_pn = create_inst(OP_PHI, vals[cb].ty, []);
        let dl = inst_get_md(cb, 0);
        if dl >= 0 { inst_set_md(call_pn, 0, dl); }
    }
    vm_clear(VM_PASS0);
    vm_clear(VM_PASS1);
    let maps: i64[2] = [VM_PASS0, VM_PASS1];
    for i in 2 {
        let pbb = ppreds[i];
        let sb = jt_duplicate_instructions_in_split_between(tail, pbb, inst_next(cb), maps[i]);
        let nci = inst_prev(block_terminator(sb));
        if i == 0 { cs_add_conditions(nci, c0); } else { cs_add_conditions(nci, c1); }
        var pn = block_first(tail);
        while pn >= 0 && iop(pn) == OP_PHI {
            for k in cb_nargs(cb) {
                if cb_arg(cb, k) == pn { set_op(nci, k, phi_value(pn, phi_block_index(pn, sb))); }
            }
            pn = inst_next(pn);
        }
        if call_pn >= 0 { phi_add_incoming(call_pn, nci, sb); }
        if musttail { cs_copy_musttail_return(sb, cb, nci); }
    }
    if musttail {
        var splits: i32[>..<] = [];
        cs_preds(tail, splits);
        for b in splits {
            inst_erase_from_parent(block_terminator(b));
            let ups: DTUpdate[1] = [DTUpdate { kind: DT_DELETE, from: b, to: tail }];
            dtu_apply_updates_permissive(ups);
        }
        dtu_delete_bb(tail);
        return;
    }
    let orig_begin = block_first(tail);
    if call_pn >= 0 {
        inst_insert_before_head(call_pn, orig_begin);
        set_name(call_pn, "phi.call");
        rauw(cb, call_pn);
    }
    var it = cb;
    while it >= 0 {
        let cur = it;
        it = inst_prev(it);
        if vals[cur].first_use >= 0 {
            if iop(cur) == OP_PHI { continue; }
            let npn = create_inst(OP_PHI, vals[cur].ty, []);
            let dl = inst_get_md(cur, 0);
            if dl >= 0 { inst_set_md(npn, 0, dl); }
            for m in maps {
                let v = vm_get(m, cur, -1) as i32;
                phi_add_incoming(npn, v, inst_parent(v));
            }
            inst_insert_before_head(npn, block_first(tail));
            rauw(cur, npn);
        }
        cu_drop_dbg_records(cur);
        inst_erase_from_parent(cur);
        if cur == orig_begin { break; }
    }
}

fn cs_is_predicated_on_phi(cb: i32) -> bool {
    let parent = inst_parent(cb);
    if cb != cs_first_non_phi_or_dbg(parent) { return false; }
    var pn = block_first(parent);
    while pn >= 0 && iop(pn) == OP_PHI {
        for k in cb_nargs(cb) {
            if cb_arg(cb, k) != pn { continue; }
            if phi_block(pn, 0) == phi_block(pn, 1) { return false; }
            if phi_value(pn, 0) == phi_value(pn, 1) { continue; }
            if is_constant(phi_value(pn, 0)) && is_constant(phi_value(pn, 1)) { return true; }
        }
        pn = inst_next(pn);
    }
    return false;
}

fn cs_try_to_split(cb: i32) -> bool {
    if cb_nargs(cb) == 0 || !cs_can_split(cb) { return false; }
    var preds: i32[>..<] = [];
    cs_preds(inst_parent(cb), preds);
    var c0: CsCond[>..<] = [];
    var c1: CsCond[>..<] = [];
    var pp: i32[2] = [-1, -1];
    var found = false;
    if preds[0] != preds[1] {
        dtu_get_dt();
        let bb = inst_parent(cb);
        let stop_at = if dt_has_node(DT_DOM, bb) { dt_idom(DT_DOM, bb) } else { -1 };
        // llvm::reverse(Preds): PredsCS[0] is Preds[1]
        pp[0] = preds[1];
        pp[1] = preds[0];
        cs_record_condition(cb, pp[0], bb, c0);
        cs_record_conditions(cb, pp[0], c0, stop_at);
        cs_record_condition(cb, pp[1], bb, c1);
        cs_record_conditions(cb, pp[1], c1, stop_at);
        found = c0.len > 0 || c1.len > 0;
    }
    if !found {
        c0.clear(); c1.clear();
        if !cs_is_predicated_on_phi(cb) { return false; }
        pp[0] = preds[0];
        pp[1] = preds[1];
    }
    cs_split_call_site(cb, pp, c0, c1);
    return true;
}

fn callsite_splitting_run(fv: i32) -> u32 {
    tli_cur_fn = fv;
    local_have_tli = true;
    tti_init_function(fv, globs[glob_of(fv)].module);
    dt_get(fv, DT_DOM);
    dtu_begin(fv, true, false, true);
    var changed = false;
    var bb = func_first_block(fv);
    while bb >= 0 {
        let nbb = block_next(bb);
        var ii = cs_first_non_phi_or_dbg(bb);
        let ie = block_terminator(bb);
        while ii >= 0 && ii != ie && ii != block_terminator(bb) {
            let cb = ii;
            ii = inst_next(ii);
            if !is_callbase(cb) || inst_iid(cb) != 0 || is_instruction_trivially_dead(cb) { continue; }
            let callee = called_function(cb);
            if callee < 0 || func_is_decl(callee) { continue; }
            let musttail = iop(cb) == OP_CALL && insts[inst_of(cb)].pred == 2;
            if cs_try_to_split(cb) { changed = true; }
            if musttail { break; }
        }
        bb = nbb;
    }
    dtu_end();
    if !changed { return PA_ALL; }
    return (1 as u32) << A_DOMTREE;
}
