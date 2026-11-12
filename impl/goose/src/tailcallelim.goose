// TailCallElim: port of llvm/lib/Transforms/Scalar/TailRecursionElimination.cpp (canTRE,
// AllocaDerivedValueTracker, markTails, canMoveAboveCall, canTransformAccumulatorRecursion,
// TailRecursionEliminator, TailCallElimPass::run) and FoldReturnIntoUncondBranch
// (llvm/lib/Transforms/Utils/BasicBlockUtils.cpp). Optimization remarks are not emitted.
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import calls;
import flags;
import domtree;
import dtu;
import aa;
import memloc;
import tli;
import tti;
import loads;
import instident;
import instsimplify;
import vt;
import knownbits;
import constfold;
import cfgutil;
import loopsimplify;
import bfi;
import inline_function;
import sroa;
import licm;
import datalayout;
import gen_iids;
import gen_attrs;
import misc_util;

fn tre_is_tail(ci: i32) -> bool { let k = insts[inst_of(ci)].pred; return k == 1 || k == 2; }
fn tre_is_notail(ci: i32) -> bool { insts[inst_of(ci)].pred == 3 }

// ---------------------------------------------------------------------------------------------
// AllocaDerivedValueTracker: AllocaUsers = VS_PASS0, EscapePoints = VS_PASS1, Visited uses = VS_PASS2

fn tre_walk(root: i32) {
    vs_clear(VS_PASS2);
    var wl: i32[>..<] = [];
    fn add_uses(v: i32, wl: i32[>..<]&) {
        var u = vals[v].first_use;
        while u >= 0 {
            if vs_add(VS_PASS2, u) { wl.push(u); }
            u = uses[u].next;
        }
    }
    add_uses(root, wl);
    while wl.len > 0 {
        let u = wl.pop();
        let i = uses[u].user;
        let o = iop(i);
        let k = u - vals[i].ops;
        if o == OP_CALL || o == OP_INVOKE {
            let na = cb_nargs(i);
            if k < na && cb_param_has_attr(i, k, AK_ByVal) { continue; }
            let is_data = k < na + cb_bundle_ops(i);
            let nocap = is_data && cb_capture_info(i, k) == 0;
            vs_add(VS_PASS0, i);
            if !nocap && !call_only_reads_memory(i) { vs_add(VS_PASS1, i); }
            if nocap { continue; }
        } else if o == OP_LOAD {
            continue;
        } else if o == OP_STORE {
            if k == 0 { vs_add(VS_PASS1, i); }
            continue;
        } else if o == OP_BITCAST || o == OP_GEP || o == OP_PHI || o == OP_SELECT || o == OP_ADDRSPACECAST {
        } else {
            vs_add(VS_PASS1, i);
        }
        add_uses(i, wl);
    }
}

fn tre_bundles_other_than_allowed(ci: i32) -> bool {
    for k in cb_nbundles(ci) {
        let t = sbytes(cb_bundle_tag(ci, k));
        if t != "clang.arc.attachedcall" && t != "ptrauth" && t != "kcfi" { return true; }
    }
    return false;
}

fn tre_calls_returns_twice(fv: i32) -> bool {
    var found = false;
    each_inst(fv) { i =>
        if is_callbase(i) && call_has_fn_attr(i, AK_ReturnsTwice) { found = true; }
    };
    return found;
}

fn tre_mark_tails(fv: i32) -> bool {
    if tre_calls_returns_twice(fv) { return false; }
    vs_clear(VS_PASS0);
    vs_clear(VS_PASS1);
    for k in func_nargs(fv) {
        let a = func_arg(fv, k);
        if aset_has(alist_param(func_attrs(fv), k), AK_ByVal) { tre_walk(a); }
    }
    var bb0 = func_first_block(fv);
    while bb0 >= 0 {
        var i = block_first(bb0);
        while i >= 0 { if iop(i) == OP_ALLOCA { tre_walk(i); } i = inst_next(i); }
        bb0 = block_next(bb0);
    }
    var modified = false;
    // Visited: VM_PASS0 (0 unvisited, 1 unescaped, 2 escaped)
    vm_clear(VM_PASS0);
    var wl_un: i32[>..<] = [];
    var wl_esc: i32[>..<] = [];
    var deferred: i32[>..<] = [];
    var bb = func_entry(fv);
    var escaped: i64 = 1;
    while bb >= 0 {
        var i = block_first(bb);
        while i >= 0 {
            let ci = i;
            i = inst_next(i);
            if vs_has(VS_PASS1, ci) { escaped = 2; }
            if iop(ci) != OP_CALL || tre_is_tail(ci) || inst_iid(ci) == IID_pseudoprobe { continue; }
            if inst_iid(ci) == IID_stackrestore { continue; }
            let notail = tre_is_notail(ci) || tre_bundles_other_than_allowed(ci);
            if !notail && call_does_not_access_memory(ci) {
                // isa<Constant>(Arg.getUser()) / isa<Argument>(Arg.getUser()): the user is the call itself
                if cb_nargs(ci) == 0 {
                    insts[inst_of(ci)].pred = 1;
                    modified = true;
                    continue;
                }
            }
            if !notail && escaped == 1 && !vs_has(VS_PASS0, ci) { deferred.push(ci); }
        }
        for k in block_nsucc(bb) {
            let s = block_succ(bb, k);
            let st = vm_get(VM_PASS0, s, 0);
            if st < escaped {
                vm_set(VM_PASS0, s, escaped);
                if escaped == 2 { wl_esc.push(s); } else { wl_un.push(s); }
            }
        }
        if wl_esc.len > 0 {
            bb = wl_esc.pop();
            escaped = 2;
        } else {
            bb = -1;
            while wl_un.len > 0 {
                let nb = wl_un.pop();
                if vm_get(VM_PASS0, nb, 0) == 1 { bb = nb; escaped = 1; break; }
            }
        }
    }
    for ci in deferred {
        if vm_get(VM_PASS0, inst_parent(ci), 0) != 2 {
            insts[inst_of(ci)].pred = 1;
            modified = true;
        }
    }
    vm_clear(VM_PASS0);
    return modified;
}

// ---------------------------------------------------------------------------------------------

fn tre_can_move_above_call(i: i32, ci: i32) -> bool {
    if iop(i) == OP_CALL && inst_iid(i) == IID_lifetime_end { return true; }
    if inst_may_have_side_effects(i) { return false; }
    if iop(i) == OP_LOAD {
        if inst_may_have_side_effects(ci) {
            if mr_is_mod(aa_inst_loc_mr_simple(ci, ml_get(i))) ||
               !ld_safe_to_load_unconditionally_ty(op(i, 0), vals[i].ty, tre_align(i), i) { return false; }
        }
    }
    for k in nops(i) { if op(i, k) == ci { return false; } }
    return true;
}
fn tre_align(i: i32) -> i64 { let a = insts[inst_of(i)].align; return if a == 0 { 1 } else { (1 as i64) << (a - 1) }; }

// Instruction::isAssociative
fn tre_is_associative(i: i32) -> bool {
    if iop(i) == OP_CALL {
        let id = inst_iid(i);
        return id == IID_smax || id == IID_smin || id == IID_umax || id == IID_umin;
    }
    let o = iop(i);
    if o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_ADD || o == OP_MUL { return true; }
    if o == OP_FMUL || o == OP_FADD {
        let f = insts[inst_of(i)].fmf;
        return (f & FMF_REASSOC) != 0 && (f & FMF_NSZ) != 0;
    }
    return false;
}
// ConstantExpr::getIntrinsicIdentity
fn tre_intrinsic_identity(id: i32, t: i32) -> i32 {
    let bits = ty_bits(ty_scalar(t));
    if id == IID_umax { return c_null(t); }
    if id == IID_umin { return c_all_ones(t); }
    if id == IID_smax { return ap_to_cint(t, ap_smin_val(bits)); }
    if id == IID_smin { return ap_to_cint(t, ap_smax_val(bits)); }
    return -1;
}
// ConstantExpr::getIdentity(I, Ty) (AllowRHSConstant = false, NSZ = false)
fn tre_identity(i: i32, t: i32) -> i32 {
    if is_binary_op(iop(i)) { return binop_identity(iop(i), t, false); }
    if iop(i) == OP_CALL && inst_iid(i) != 0 { return tre_intrinsic_identity(inst_iid(i), t); }
    return -1;
}

fn tre_can_transform_accumulator(i: i32, ci: i32) -> bool {
    if !tre_is_associative(i) || !ii_is_commutative(i) { return false; }
    if iop(i) == OP_CALL && inst_iid(i) != 0 && tre_intrinsic_identity(inst_iid(i), vals[i].ty) < 0 { return false; }
    let a = op(i, 0) == ci;
    let b = op(i, 1) == ci;
    if a == b { return false; }
    if !mu_has_one_use(i) { return false; }
    let us = uses[vals[i].first_use].user;
    return is_inst(us) && iop(us) == OP_RET;
}

// TailRecursionEliminator state
var tr_f: i32 = -1;
var tr_header: i32 = -1;
var tr_arg_phis: i32[>..<];
var tr_ret_pn: i32 = -1;
var tr_ret_known_pn: i32 = -1;
var tr_ret_selects: i32[>..<];
var tr_acc_pn: i32 = -1;
var tr_acc_instr: i32 = -1;
var tr_use_bfi: bool = false;
var tr_orig_entry_freq: u64 = 0;
var tr_orig_entry_count: u64 = 0;

fn tre_find_candidate(bb: i32) -> i32 {
    let ti = block_terminator(bb);
    if block_first(bb) == ti { return -1; }
    var ci = ti;
    loop {
        if iop(ci) == OP_CALL && called_function(ci) == tr_f { break; }
        if ci == block_first(bb) { return -1; }
        ci = inst_prev(ci);
    }
    if !tre_is_tail(ci) { return -1; }
    let callee = called_function(ci);
    if bb == func_entry(tr_f) && block_first(bb) == ci && inst_next(ci) == ti && callee >= 0 && !tti_is_lowered_to_call(callee) {
        let na = cb_nargs(ci);
        let nf = func_nargs(tr_f);
        var k: i64 = 0;
        while k < na && k < nf { if cb_arg(ci, k) != func_arg(tr_f, k) { break; } k++; }
        if k == na && k == nf { return -1; }
    }
    return ci;
}

fn tre_create_header(ci: i32) {
    let f = tr_f;
    tr_header = func_entry(f);
    let ne = create_block_before(f, tr_header, "");
    cu_take_name(ne, tr_header);
    set_name(tr_header, "tailrecurse");
    let bi = create_inst(OP_BR, T_VOID, [tr_header]);
    block_append_inst(ne, bi);
    var x = block_first(tr_header);
    while x >= 0 {
        let nx = inst_next(x);
        if iop(x) == OP_ALLOCA && vals[op(x, 0)].kind == VK_CINT { inst_move_impl(x, ne, bi, true, false); }
        x = nx;
    }
    let ipos = block_first(tr_header);
    for k in func_nargs(f) {
        let a = func_arg(f, k);
        let pn = create_inst(OP_PHI, vals[a].ty, []);
        inst_insert_before_head(pn, ipos);
        set_name(pn, str(val_name(a), ".tr"));
        rauw(a, pn);
        phi_add_incoming(pn, a, ne);
        tr_arg_phis.push(pn);
    }
    let rt = ty_fn_ret(func_type(f));
    if rt != T_VOID {
        tr_ret_pn = create_inst(OP_PHI, rt, []);
        inst_insert_before_head(tr_ret_pn, ipos);
        set_name(tr_ret_pn, "ret.tr");
        tr_ret_known_pn = create_inst(OP_PHI, T_I1, []);
        inst_insert_before_head(tr_ret_known_pn, ipos);
        set_name(tr_ret_known_pn, "ret.known.tr");
        phi_add_incoming(tr_ret_pn, c_poison(rt), ne);
        phi_add_incoming(tr_ret_known_pn, c_false(), ne);
    }
    dtu_recalculate();
}

fn tre_insert_accumulator(acc: i32) {
    tr_acc_instr = acc;
    var preds: i32[>..<] = [];
    each_pred(tr_header) { p => preds.push(p); };
    tr_acc_pn = create_inst(OP_PHI, ty_fn_ret(func_type(tr_f)), []);
    inst_insert_before_head(tr_acc_pn, block_first(tr_header));
    set_name(tr_acc_pn, "accumulator.tr");
    for p in preds {
        if p == func_entry(tr_f) { phi_add_incoming(tr_acc_pn, tre_identity(acc, vals[acc].ty), p); }
        else { phi_add_incoming(tr_acc_pn, tr_acc_pn, p); }
    }
}

fn tre_param_align(ci: i32, k: i64) -> i64 {
    let a = aset_int_misc(alist_param(insts[inst_of(ci)].attrs, k), AK_Alignment) as i64;
    return if a == 0 { 1 } else { a };
}
fn aset_int_misc(s: i32, kind: i64) -> u64 { let a = aset_find(s, kind); return if a < 0 { 0 } else { attrs[a].i1 }; }

fn tre_copy_byval_into_temp(ci: i32, k: i64) {
    let agg = cb_param_byval_type(ci, k);
    let al = tre_param_align(ci, k);
    let a = create_inst(OP_ALLOCA, ty_ptr(dl_alloca_addr_space), [c_int(T_I32, 1)]);
    insts[inst_of(a)].ty2 = agg;
    var lg: u8 = 0;
    while ((1 as i64) << lg) < al { lg++; }
    insts[inst_of(a)].align = lg + 1;
    let entry = func_entry(tr_f);
    inst_insert_before_head(a, block_first(entry));
    set_name(a, val_name(cb_arg(ci, k)));
    irb_set_before(ci);
    let size = c_int(T_I64, dl_alloc_size(agg));
    irb_memcpy(a, al, cb_arg(ci, k), al, size, false);
    set_op(ci, k, a);
}
fn tre_copy_temp_into_argument(ci: i32, k: i64) {
    let agg = cb_param_byval_type(ci, k);
    let al = tre_param_align(ci, k);
    irb_set_before(ci);
    let size = c_int(T_I64, dl_alloc_size(agg));
    irb_memcpy(func_arg(tr_f, k), al, cb_arg(ci, k), al, size, false);
}

fn tre_remove_param_attr(f: i32, k: i64, kind: i64) {
    let g = glob_of(f);
    let l = globs[g].attrs;
    let s = alist_param(l, k);
    if !aset_has(s, kind) { return; }
    var xs: i32[>..<] = [];
    for j in aset_n(s) { let a = aset_attr(s, j); if attrs[a].kind as i64 != kind { xs.push(a); } }
    globs[g].attrs = alist_set_param(l, k, aset_get(xs));
}

fn tre_eliminate_call(ci: i32) -> bool {
    let ret = block_terminator(inst_parent(ci));
    var acc: i32 = -1;
    var x = inst_next(ci);
    while x != ret {
        if !tre_can_move_above_call(x, ci) {
            if tr_acc_pn >= 0 || !tre_can_transform_accumulator(x, ci) { return false; }
            acc = x;
        }
        x = inst_next(x);
    }
    let bb = inst_parent(ret);
    if tr_header < 0 { tre_create_header(ci); }
    let na = cb_nargs(ci);
    for k in na { if cb_param_has_attr(ci, k, AK_ByVal) { tre_copy_byval_into_temp(ci, k); } }
    for k in na {
        if cb_param_has_attr(ci, k, AK_ByVal) {
            tre_copy_temp_into_argument(ci, k);
            tre_remove_param_attr(tr_f, k, AK_ReadOnly);
            phi_add_incoming(tr_arg_phis[k], func_arg(tr_f, k), bb);
        } else {
            phi_add_incoming(tr_arg_phis[k], cb_arg(ci, k), bb);
        }
    }
    if acc >= 0 {
        tre_insert_accumulator(acc);
        set_op(acc, if op(acc, 0) != ci { 1 } else { 0 }, tr_acc_pn);
        drop_poison_generating_annotations(acc);
    }
    if tr_ret_pn >= 0 {
        let rv = if nops(ret) > 0 { op(ret, 0) } else { -1 };
        if rv == ci || acc >= 0 {
            phi_add_incoming(tr_ret_pn, tr_ret_pn, bb);
            phi_add_incoming(tr_ret_known_pn, tr_ret_known_pn, bb);
        } else {
            let si = create_inst(OP_SELECT, vals[tr_ret_pn].ty, [tr_ret_known_pn, tr_ret_pn, rv]);
            inst_insert_before(si, ret);
            set_name(si, "current.ret.tr");
            let dl = inst_get_md(ret, 0);
            if dl >= 0 { inst_set_md(si, 0, dl); }
            tr_ret_selects.push(si);
            phi_add_incoming(tr_ret_pn, si, bb);
            phi_add_incoming(tr_ret_known_pn, c_true(), bb);
        }
        if tr_acc_pn >= 0 { phi_add_incoming(tr_acc_pn, if acc >= 0 { acc } else { tr_acc_pn }, bb); }
    }
    let nbi = create_inst(OP_BR, T_VOID, [tr_header]);
    inst_insert_before(nbi, ret);
    let cdl = inst_get_md(ci, 0);
    if cdl >= 0 { inst_set_md(nbi, 0, cdl); }
    inst_erase_from_parent(ret);
    inst_erase_from_parent(ci);
    let ups: DTUpdate[1] = [DTUpdate { kind: DT_INSERT, from: bb, to: tr_header }];
    dtu_apply_updates(ups);
    if tr_orig_entry_freq != 0 {
        let rel = (bfi_freq(bb) as f64) / (tr_orig_entry_freq as f64);
        let sub = round(rel * (tr_orig_entry_count as f64)) as u64;
        let has, old = bf_entry_count(tr_f);
        if old > sub { fn_set_entry_count(tr_f, old - sub); }
    }
    return true;
}

fn tre_clone_acc(v: i32, before: i32) -> i32 {
    let n = inst_clone(tr_acc_instr);
    set_op(n, if op(tr_acc_instr, 0) == tr_acc_pn { 1 } else { 0 }, v);
    inst_insert_before(n, before);
    set_name(n, "accumulator.ret.tr");
    lc_drop_location(n);
    return n;
}

fn tre_cleanup_and_finalize() {
    let s1 = sq_no_dt; let s2 = sq_no_ac; let s3 = sq_no_tli; let sc = kb_cxt;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    for pn in tr_arg_phis {
        kb_cxt = -1;
        let v = simplify_instruction(pn);
        if v >= 0 {
            rauw(pn, v);
            inst_erase_from_parent(pn);
        }
    }
    sq_no_dt = s1; sq_no_ac = s2; sq_no_tli = s3; kb_cxt = sc;
    if tr_ret_pn < 0 { return; }
    if tr_ret_selects.len == 0 {
        drop_all_refs(tr_ret_pn);
        inst_erase_from_parent(tr_ret_pn);
        drop_all_refs(tr_ret_known_pn);
        inst_erase_from_parent(tr_ret_known_pn);
        if tr_acc_pn >= 0 {
            var bb = func_first_block(tr_f);
            while bb >= 0 {
                let ri = block_terminator(bb);
                if ri >= 0 && iop(ri) == OP_RET {
                    let n = tre_clone_acc(op(ri, 0), ri);
                    set_op(ri, 0, n);
                }
                bb = block_next(bb);
            }
        }
    } else {
        var bb = func_first_block(tr_f);
        while bb >= 0 {
            let ri = block_terminator(bb);
            if ri >= 0 && iop(ri) == OP_RET {
                let si = create_inst(OP_SELECT, vals[tr_ret_pn].ty, [tr_ret_known_pn, tr_ret_pn, op(ri, 0)]);
                inst_insert_before(si, ri);
                set_name(si, "current.ret.tr");
                tr_ret_selects.push(si);
                set_op(ri, 0, si);
            }
            bb = block_next(bb);
        }
        if tr_acc_pn >= 0 {
            for si in tr_ret_selects {
                let n = tre_clone_acc(op(si, 2), si);
                set_op(si, 2, n);
            }
        }
    }
}

// FoldReturnIntoUncondBranch(RI, BB, Pred, DTU)
fn tre_fold_return_into_uncond_branch(ri: i32, bb: i32, pred: i32) -> i32 {
    let uncond = block_terminator(pred);
    let nr = inst_clone(ri);
    inst_insert_at(nr, pred, -1, false);
    for k in nops(nr) {
        var v = op(nr, k);
        var nbc: i32 = -1;
        if is_inst(v) && iop(v) == OP_BITCAST {
            let bci = v;
            v = op(bci, 0);
            nbc = inst_clone(bci);
            inst_insert_at(nbc, pred, nr, false);
            set_op(nr, k, nbc);
        }
        var nev: i32 = -1;
        if is_inst(v) && iop(v) == OP_EXTRACTVALUE {
            let evi = v;
            v = op(evi, 0);
            nev = inst_clone(evi);
            if nbc >= 0 {
                set_op(nbc, 0, nev);
                inst_insert_at(nev, pred, nbc, false);
            } else {
                inst_insert_at(nev, pred, nr, false);
                set_op(nr, k, nev);
            }
        }
        if is_inst(v) && iop(v) == OP_PHI && inst_parent(v) == bb {
            let iv = phi_value(v, phi_block_index(v, pred));
            if nev >= 0 { set_op(nev, 0, iv); }
            else if nbc >= 0 { set_op(nbc, 0, iv); }
            else { set_op(nr, k, iv); }
        }
    }
    block_remove_predecessor(bb, pred, false);
    inst_erase_from_parent(uncond);
    let ups: DTUpdate[1] = [DTUpdate { kind: DT_DELETE, from: pred, to: bb }];
    dtu_apply_updates(ups);
    return nr;
}

// BasicBlock::getFirstNonPHIOrDbg(SkipPseudoOp = true)
fn tre_first_non_phi_or_dbg(bb: i32) -> i32 {
    var i = block_first(bb);
    while i >= 0 {
        if iop(i) != OP_PHI && !(iop(i) == OP_CALL && inst_iid(i) == IID_pseudoprobe) { return i; }
        i = inst_next(i);
    }
    return -1;
}

fn tre_process_block(bb: i32) -> bool {
    let ti = block_terminator(bb);
    if iop(ti) == OP_BR {
        let succ = op(ti, 0);
        let r = tre_first_non_phi_or_dbg(succ);
        if r < 0 || iop(r) != OP_RET { return false; }
        let ci = tre_find_candidate(bb);
        if ci < 0 { return false; }
        tre_fold_return_into_uncond_branch(r, succ, bb);
        if pred_count(succ) == 0 { dtu_delete_bb(succ); }
        tre_eliminate_call(ci);
        return true;
    } else if iop(ti) == OP_RET {
        let ci = tre_find_candidate(bb);
        if ci >= 0 { return tre_eliminate_call(ci); }
    }
    return false;
}

fn tailcallelim_run(fv: i32, update_entry_count: bool) -> u32 {
    tli_cur_fn = fv;
    tti_init_function(fv, globs[glob_of(fv)].module);
    aa_begin(fv);
    let has_count, count = bf_entry_count(fv);
    tr_use_bfi = update_entry_count && !flag_bool("tre-disable-entrycount-recompute", false) && has_count && count != 0;
    if tr_use_bfi { bfi_get(fv); }
    tr_f = fv;
    tr_header = -1;
    tr_arg_phis.clear();
    tr_ret_pn = -1;
    tr_ret_known_pn = -1;
    tr_ret_selects.clear();
    tr_acc_pn = -1;
    tr_acc_instr = -1;
    tr_orig_entry_freq = 0;
    tr_orig_entry_count = 0;
    let dta = st_fn_str_misc(fv, "disable-tail-calls");
    if dta >= 0 && sbytes(dta) == "true" { return PA_ALL; }
    dtu_begin(fv, true, true, false);
    var changed = tre_mark_tails(fv);
    if !ty_fn_vararg(func_type(fv)) {
        var can = true;
        each_inst(fv) { i => if iop(i) == OP_ALLOCA && !is_static_alloca(i) { can = false; } };
        if can {
            if tr_use_bfi { tr_orig_entry_freq = bfi_freq(func_entry(fv)); tr_orig_entry_count = count; }
            var bb = func_first_block(fv);
            while bb >= 0 {
                if tre_process_block(bb) { changed = true; }
                bb = block_next(bb);
            }
            tre_cleanup_and_finalize();
        }
    }
    dtu_end();
    if !changed { return PA_ALL; }
    return ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_POSTDOMTREE);
}

fn st_fn_str_misc(fv: i32, key: const u8[:]) -> i32 {
    let a = aset_find_str(alist_fn(func_attrs(fv)), key);
    if a < 0 { return -1; }
    return attrs[a].sval;
}
