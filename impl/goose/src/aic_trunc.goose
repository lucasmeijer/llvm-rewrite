// TruncInstCombine: port of llvm/lib/Transforms/AggressiveInstCombine/TruncInstCombine.cpp (and
// AggressiveInstCombineInternal.h), plus the IRBuilder<> (ConstantFolder) used by aggressive_instcombine.goose.
//
// InstInfoMap (MapVector<Instruction*, Info>) is `tc_keys` + parallel Info arrays in insertion order, with an
// HMap index; erasing an entry leaves a tombstone (key -1), as MapVector::erase keeps the others' order.
import std;
import ir;
import irutil;
import instinfo;
import pm;
import vt;
import knownbits;
import constfold;
import cfold;
import apint;
import datalayout;
import domtree;
import scev;
import autoupgrade;
import intrinsics;
import calls;

// ---------------------------------------------------------------------------------------------
// IRBuilder<> (ConstantFolder): ab_pos = -1 is BB->end(); ab_head: the iterator's head bit; the debug location
// of SetInsertPoint(I) / SetInsertPoint(BB, It)

var ab_bb: i32 = -1;
var ab_pos: i32 = -1;
var ab_head: bool = false;
var ab_dl: i32 = -1;
// IRBuilder<> B(I) / SetInsertPoint(I)
fn ab_set(i: i32) { ab_bb = inst_parent(i); ab_pos = i; ab_head = false; ab_dl = inst_get_md(i, 0); }
// SetInsertPoint(BB, It) (It = pos, -1 = end(); the debug location only changes when It != end())
fn ab_set_at(bb: i32, pos: i32, head: bool) {
    ab_bb = bb; ab_pos = pos; ab_head = head;
    if pos >= 0 { ab_dl = inst_get_md(pos, 0); }
}
// SetInsertPoint(BB): end of BB, the debug location is kept
fn ab_set_end(bb: i32) { ab_bb = bb; ab_pos = -1; ab_head = false; }
fn ab_insert(iv: i32, name: const u8[:]) -> i32 {
    inst_insert_at(iv, ab_bb, ab_pos, ab_head);
    if name.len > 0 && vals[iv].ty != T_VOID { set_name(iv, name); }
    if ab_dl >= 0 { inst_set_md(iv, 0, ab_dl); }
    return iv;
}
// CreateBinOp / CreateAdd / ... with no-wrap or exact flags (FoldBinOp / FoldNoWrapBinOp / FoldExactBinOp)
fn ab_binop(o: i64, a: i32, b: i32, fl: u8, name: const u8[:]) -> i32 {
    if is_constant(a) && is_constant(b) {
        if is_desirable_binop(o) { return ce_binop(o, a, b, fl); }
        let r = cf_binop(o, a, b);
        if r >= 0 { return r; }
    }
    let iv = create_inst(o, vals[a].ty, [a, b]);
    insts[inst_of(iv)].flags = fl;
    return ab_insert(iv, name);
}
// CreateCast (FoldCast)
fn ab_cast(o: i64, v: i32, ty: i32, fl: u8, name: const u8[:]) -> i32 {
    if vals[v].ty == ty { return v; }
    if is_constant(v) {
        if is_desirable_cast_op(o) { return ce_cast(o, v, ty); }
        let r = cf_cast(o, v, ty);
        if r >= 0 { return r; }
    }
    let iv = create_inst(o, ty, [v]);
    insts[inst_of(iv)].flags = fl;
    return ab_insert(iv, name);
}
fn ab_trunc(v: i32, ty: i32) -> i32 { ab_cast(OP_TRUNC, v, ty, 0, "") }
fn ab_zext(v: i32, ty: i32) -> i32 { ab_cast(OP_ZEXT, v, ty, 0, "") }
fn ab_sext(v: i32, ty: i32) -> i32 { ab_cast(OP_SEXT, v, ty, 0, "") }
// CreateIntCast
fn ab_int_cast(v: i32, ty: i32, signed: bool) -> i32 {
    let o = if ty_bits(ty_scalar(vals[v].ty)) > ty_bits(ty_scalar(ty)) { OP_TRUNC } else if signed { OP_SEXT } else { OP_ZEXT };
    return ab_cast(o, v, ty, 0, "");
}
// CreateZExtOrTrunc
fn ab_zext_or_trunc(v: i32, ty: i32) -> i32 {
    let a = ty_bits(ty_scalar(vals[v].ty));
    let b = ty_bits(ty_scalar(ty));
    if a < b { return ab_zext(v, ty); }
    if a > b { return ab_trunc(v, ty); }
    return v;
}
fn ab_cmp_ty(t: i32) -> i32 { if ty_is_vector(t) { ty_vector(T_I1, types[t].cnt, types[t].kind == TK_SVEC) } else { T_I1 } }
// CreateICmp (FoldCmp: ConstantFoldCompareInstruction)
fn ab_icmp(p: i64, a: i32, b: i32) -> i32 {
    if is_constant(a) && is_constant(b) {
        let r = cf_compare(p, a, b);
        if r >= 0 { return r; }
    }
    let iv = create_inst(OP_ICMP, ab_cmp_ty(vals[a].ty), [a, b]);
    insts[inst_of(iv)].pred = p as u8;
    return ab_insert(iv, "");
}
// CreateSelect(C, T, F, Name, MDFrom)
fn ab_select(c: i32, t: i32, f: i32, name: const u8[:], mdfrom: i32) -> i32 {
    if is_constant(c) && is_constant(t) && is_constant(f) {
        let r = cf_select(c, t, f);
        if r >= 0 { return r; }
    }
    let iv = create_inst(OP_SELECT, vals[t].ty, [c, t, f]);
    if mdfrom >= 0 {
        let prof = inst_get_md(mdfrom, md_kind_id("prof"));
        let unp = inst_get_md(mdfrom, md_kind_id("unpredictable"));
        if prof >= 0 { inst_set_md(iv, md_kind_id("prof"), prof); }
        if unp >= 0 { inst_set_md(iv, md_kind_id("unpredictable"), unp); }
    }
    return ab_insert(iv, name);
}
fn ab_extract_element(v: i32, idx: i32) -> i32 {
    if is_constant(v) && is_constant(idx) {
        let r = cf_extractelement(v, idx);
        if r >= 0 { return r; }
    }
    return ab_insert(create_inst(OP_EXTRACTELEMENT, types[vals[v].ty].a, [v, idx]), "");
}
fn ab_insert_element(v: i32, e: i32, idx: i32) -> i32 {
    if is_constant(v) && is_constant(e) && is_constant(idx) {
        let r = cf_insertelement(v, e, idx);
        if r >= 0 { return r; }
    }
    return ab_insert(create_inst(OP_INSERTELEMENT, vals[v].ty, [v, e, idx]), "");
}
fn ab_phi(ty: i32, name: const u8[:]) -> i32 { ab_insert(create_inst(OP_PHI, ty, []), name) }
fn ab_freeze(v: i32) -> i32 { ab_insert(create_inst(OP_FREEZE, vals[v].ty, [v]), "") }
// CreateIntrinsic(ID, OverloadTypes, Args, FMFSource, Name) (ConstantFolder::FoldIntrinsic folds nothing)
fn ab_intrinsic(id: i64, ov: const i32[:], args: const i32[:], fmf_src: i32, name: const u8[:]) -> i32 {
    let f = au_get_declaration(id, ov);
    let fty = globs[glob_of(f)].vty;
    var ops: i32[>..<] = [];
    for a in args { ops.push(a); }
    ops.push(f);
    let iv = create_inst(OP_CALL, ty_fn_ret(fty), ops);
    insts[inst_of(iv)].ty2 = fty;
    if fmf_src >= 0 && is_fp_math_operator(iv) { insts[inst_of(iv)].fmf = insts[inst_of(fmf_src)].fmf; }
    return ab_insert(iv, name);
}

// Value::takeName
fn ab_take_name(dst: i32, src: i32) {
    if dst == src { return; }
    if vals[dst].name >= 0 { set_name(dst, ""); }
    if vals[src].name < 0 { return; }
    var buf: u8[>..] = [];
    buf.append(sbytes(vals[src].name));
    set_name(src, "");
    set_name(dst, buf);
}

// ---------------------------------------------------------------------------------------------
// TruncInstCombine

var tc_keys: i32[>..<];
var tc_valid: u32[>..<];
var tc_min: u32[>..<];
var tc_new: i32[>..<];
var tc_ix = hm_new();
var tc_wl: i32[>..<];      // Worklist of TruncInsts
var tc_cur: i32 = -1;      // CurrentTruncInst
var tc_fv: i32 = -1;

fn tc_map_clear() { tc_keys.resize(0); tc_valid.resize(0); tc_min.resize(0); tc_new.resize(0); hm_clear(tc_ix); }
fn tc_has(i: i32) -> bool { hm_has(tc_ix, i as u64) }
// InstInfoMap[I] (inserts a default Info)
fn tc_slot(i: i32) -> i64 {
    let j = hm_get(tc_ix, i as u64, -1);
    if j >= 0 { return j; }
    tc_keys.push(i); tc_valid.push(0); tc_min.push(0); tc_new.push(-1);
    hm_put(tc_ix, i as u64, tc_keys.len - 1);
    return tc_keys.len - 1;
}

// getRelevantOperands
fn tc_relevant_operands(i: i32, out: i32[>..<]&) {
    let o = iop(i);
    if o == OP_TRUNC || o == OP_ZEXT || o == OP_SEXT { return; }
    if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_SHL ||
       o == OP_LSHR || o == OP_ASHR || o == OP_UDIV || o == OP_UREM || o == OP_INSERTELEMENT {
        out.push(op(i, 0)); out.push(op(i, 1)); return;
    }
    if o == OP_EXTRACTELEMENT { out.push(op(i, 0)); return; }
    if o == OP_SELECT { out.push(op(i, 1)); out.push(op(i, 2)); return; }
    if o == OP_PHI { for k in nops(i) { out.push(op(i, k)); } return; }
    fatal("aggressive-instcombine: getRelevantOperands of an unexpected instruction");
}

// buildTruncExpressionGraph
fn tc_build_graph() -> bool {
    var wl: i32[>..<] = [];
    var stk: i32[>..<] = [];
    tc_map_clear();
    wl.push(op(tc_cur, 0));
    while wl.len > 0 {
        let cur = wl[wl.len - 1];
        if is_constant(cur) { wl.pop(); continue; }
        if !is_inst(cur) { return false; }
        let i = cur;
        if stk.len > 0 && stk[stk.len - 1] == i {
            wl.pop();
            stk.pop();
            tc_slot(i);
            continue;
        }
        if tc_has(i) { wl.pop(); continue; }
        stk.push(i);
        let o = iop(i);
        if o == OP_TRUNC || o == OP_ZEXT || o == OP_SEXT { continue; }
        if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_SHL ||
           o == OP_LSHR || o == OP_ASHR || o == OP_UDIV || o == OP_UREM || o == OP_INSERTELEMENT ||
           o == OP_EXTRACTELEMENT || o == OP_SELECT {
            tc_relevant_operands(i, wl);
            continue;
        }
        if o == OP_PHI {
            var ops: i32[>..<] = [];
            tc_relevant_operands(i, ops);
            for x in ops {
                var instk = false;
                for s in stk { if s == x { instk = true; } }
                if !instk { wl.push(x); }
            }
            continue;
        }
        return false;
    }
    return true;
}

// getMinBitWidth
fn tc_get_min_bit_width() -> i64 {
    var wl: i32[>..<] = [];
    var stk: i32[>..<] = [];
    let src = op(tc_cur, 0);
    let dty = vals[tc_cur].ty;
    let trunc_bw = ty_bits(ty_scalar(dty));
    let orig_bw = ty_bits(ty_scalar(vals[src].ty));
    if is_constant(src) { return trunc_bw; }
    wl.push(src);
    tc_valid[tc_slot(src)] = trunc_bw as u32;
    while wl.len > 0 {
        let cur = wl[wl.len - 1];
        if is_constant(cur) { wl.pop(); continue; }
        let i = cur;
        let s = tc_slot(i);
        var ops: i32[>..<] = [];
        tc_relevant_operands(i, ops);
        if stk.len > 0 && stk[stk.len - 1] == i {
            wl.pop();
            stk.pop();
            for x in ops {
                if is_inst(x) {
                    let m = tc_min[tc_slot(x)];
                    if m > tc_min[s] { tc_min[s] = m; }
                }
            }
            continue;
        }
        stk.push(i);
        let vbw = tc_valid[s];
        if vbw > tc_min[s] { tc_min[s] = vbw; }
        for x in ops {
            if !is_inst(x) { continue; }
            let j = hm_get(tc_ix, x as u64, -1);
            let xb: u32 = if j >= 0 { tc_valid[j] } else { 0 };
            if xb >= vbw { continue; }
            tc_valid[tc_slot(x)] = vbw;
            wl.push(x);
        }
    }
    let j = hm_get(tc_ix, src as u64, -1);
    var minbw: i64 = if j >= 0 { tc_min[j] as i64 } else { 0 };
    if minbw > trunc_bw {
        if ty_is_vector(dty) { return orig_bw; }
        var found: i64 = -1;
        for w in dl_native { if found < 0 && minbw <= w { found = w; } }
        minbw = if found >= 0 { found } else { orig_bw };
    } else {
        let from_legal = minbw == 1 || dl_is_legal_integer(orig_bw);
        let to_legal = minbw == 1 || dl_is_legal_integer(minbw);
        if !ty_is_vector(dty) && from_legal && !to_legal { return orig_bw; }
    }
    return minbw;
}

// computeKnownBits / ComputeNumSignBits with (DL, AC, CtxI = CurrentTruncInst, DT)
fn tc_known(v: i32) -> KB {
    let sc = kb_cxt; let sdt = sq_no_dt; let sac = sq_no_ac; let stli = sq_no_tli;
    kb_cxt = tc_cur; sq_no_dt = false; sq_no_ac = false; sq_no_tli = true;
    let k = kb_compute_all(v, 0);
    kb_cxt = sc; sq_no_dt = sdt; sq_no_ac = sac; sq_no_tli = stli;
    return k;
}
fn tc_num_sign_bits(v: i32) -> i64 {
    let sc = kb_cxt; let sdt = sq_no_dt; let sac = sq_no_ac; let stli = sq_no_tli;
    kb_cxt = tc_cur; sq_no_dt = false; sq_no_ac = false; sq_no_tli = true;
    let n = num_sign_bits(v, 0);
    kb_cxt = sc; sq_no_dt = sdt; sq_no_ac = sac; sq_no_tli = stli;
    return n;
}
fn tc_kb_max(k: KB) -> AP { ap_not(k.z) }

// getBestTruncatedType: the reduced scalar bit width, 0 = nullptr
fn tc_get_best_truncated_type() -> i64 {
    if !tc_build_graph() { return 0; }
    var desired: i64 = 0;
    for k in tc_keys.len {
        let i = tc_keys[k];
        if i < 0 { continue; }
        let u0 = vals[i].first_use;
        if u0 >= 0 && uses[u0].next < 0 { continue; }   // hasOneUse
        let is_ext = iop(i) == OP_ZEXT || iop(i) == OP_SEXT;
        var u = u0;
        while u >= 0 {
            let ui = uses[u].user;
            u = uses[u].next;
            if !is_inst(ui) { continue; }
            if ui != tc_cur && !tc_has(ui) {
                if !is_ext { return 0; }
                let ebw = ty_bits(ty_scalar(vals[op(i, 0)].ty));
                if desired != 0 && desired != ebw { return 0; }
                desired = ebw;
            }
        }
    }
    let orig_bw = ty_bits(ty_scalar(vals[op(tc_cur, 0)].ty));
    for k in tc_keys.len {
        let i = tc_keys[k];
        if i < 0 { continue; }
        let o = iop(i);
        if o == OP_SHL || o == OP_LSHR || o == OP_ASHR {
            let kr = tc_known(op(i, 1));
            let mx = ap_uadd_sat(tc_kb_max(kr), ap_u64(1, orig_bw));
            var mbw = ap_limited(mx, orig_bw as u64) as i64;
            if mbw == orig_bw { return 0; }
            if o == OP_LSHR {
                let kl = tc_known(op(i, 0));
                let ab = ap_active_bits(tc_kb_max(kl));
                if ab > mbw { mbw = ab; }
            }
            if o == OP_ASHR {
                let ns = tc_num_sign_bits(op(i, 0));
                let x = orig_bw - ns + 1;
                if x > mbw { mbw = x; }
            }
            if mbw >= orig_bw { return 0; }
            tc_min[k] = mbw as u32;
        }
        if o == OP_UDIV || o == OP_UREM {
            var mbw: i64 = 0;
            for j in nops(i) {
                let kk = tc_known(op(i, j));
                let ab = ap_active_bits(tc_kb_max(kk));
                if ab > mbw { mbw = ab; }
                if mbw >= orig_bw { return 0; }
            }
            tc_min[k] = mbw as u32;
        }
    }
    let minbw = tc_get_min_bit_width();
    if minbw >= orig_bw || (desired != 0 && desired != minbw) { return 0; }
    return minbw;
}

// getReducedType
fn tc_reduced_type(v: i32, sbw: i64) -> i32 {
    let t = vals[v].ty;
    let st = ty_int(sbw);
    if ty_is_vector(t) { return ty_vector(st, types[t].cnt, types[t].kind == TK_SVEC); }
    return st;
}
// getReducedOperand
fn tc_reduced_operand(v: i32, sbw: i64) -> i32 {
    let ty = tc_reduced_type(v, sbw);
    if is_constant(v) {
        let c = ce_cast(OP_TRUNC, v, ty);
        return cf_fold_constant(c);
    }
    let j = hm_get(tc_ix, v as u64, -1);
    if j < 0 || tc_new[j] < 0 { fatal("aggressive-instcombine: reduced operand without a new value"); }
    return tc_new[j];
}

// ReduceExpressionGraph
fn tc_reduce_expression_graph(sbw: i64) {
    var old_phis: i32[>..<] = [];
    var new_phis: i32[>..<] = [];
    for k in tc_keys.len {
        let i = tc_keys[k];
        if i < 0 { continue; }
        ab_set(i);
        var res: i32 = -1;
        let o = iop(i);
        if o == OP_TRUNC || o == OP_ZEXT || o == OP_SEXT {
            let ty = tc_reduced_type(i, sbw);
            if vals[op(i, 0)].ty == ty { tc_new[k] = op(i, 0); continue; }
            res = ab_int_cast(op(i, 0), ty, o == OP_SEXT);
            var e: i64 = -1;
            for w in tc_wl.len { if e < 0 && tc_wl[w] == i { e = w; } }
            let is_tr = is_inst_op(res, OP_TRUNC);
            if e >= 0 {
                if is_tr { tc_wl[e] = res; } else { remove_at(tc_wl, e); }
            } else if is_tr { tc_wl.push(res); }
        } else if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_SHL ||
                  o == OP_LSHR || o == OP_ASHR || o == OP_UDIV || o == OP_UREM {
            let l = tc_reduced_operand(op(i, 0), sbw);
            let r = tc_reduced_operand(op(i, 1), sbw);
            res = ab_binop(o, l, r, 0, "");
            if (o == OP_UDIV || o == OP_LSHR || o == OP_ASHR) && is_inst(res) {
                let ex = (insts[inst_of(i)].flags & FL_EXACT) != 0;
                if ex { insts[inst_of(res)].flags |= FL_EXACT; } else { insts[inst_of(res)].flags &= ~FL_EXACT; }
            }
        } else if o == OP_EXTRACTELEMENT {
            let v = tc_reduced_operand(op(i, 0), sbw);
            res = ab_extract_element(v, op(i, 1));
        } else if o == OP_INSERTELEMENT {
            let v = tc_reduced_operand(op(i, 0), sbw);
            let e = tc_reduced_operand(op(i, 1), sbw);
            res = ab_insert_element(v, e, op(i, 2));
        } else if o == OP_SELECT {
            let l = tc_reduced_operand(op(i, 1), sbw);
            let r = tc_reduced_operand(op(i, 2), sbw);
            res = ab_select(op(i, 0), l, r, "", i);
        } else if o == OP_PHI {
            ab_head = true;
            res = ab_phi(tc_reduced_type(i, sbw), "");
            old_phis.push(i);
            new_phis.push(res);
        } else { fatal("aggressive-instcombine: unhandled instruction"); }
        tc_new[k] = res;
        if is_inst(res) { ab_take_name(res, i); }
    }
    for p in old_phis.len {
        let opn = old_phis[p];
        let npn = new_phis[p];
        for k in nops(opn) { phi_add_incoming(npn, tc_reduced_operand(op(opn, k), sbw), phi_block(opn, k)); }
    }
    var res = tc_reduced_operand(op(tc_cur, 0), sbw);
    let dty = vals[tc_cur].ty;
    if vals[res].ty != dty {
        ab_set(tc_cur);
        res = ab_int_cast(res, dty, false);
        if is_inst(res) { ab_take_name(res, tc_cur); }
    }
    rauw(tc_cur, res);
    inst_erase_from_parent(tc_cur);
    for p in old_phis {
        rauw(p, c_poison(vals[p].ty));
        let j = hm_get(tc_ix, p as u64, -1);
        if j >= 0 { tc_keys[j] = -1; hm_del(tc_ix, p as u64); }
        inst_erase_from_parent(p);
    }
    var k = tc_keys.len - 1;
    while k >= 0 {
        let i = tc_keys[k];
        k--;
        if i < 0 { continue; }
        if vals[i].first_use < 0 { inst_erase_from_parent(i); }
    }
}

// TruncInstCombine::run
fn tc_run(fv: i32) -> bool {
    tc_fv = fv;
    var changed = false;
    tc_wl.resize(0);
    var bb = func_entry(fv);
    while bb >= 0 {
        if dt_has_node(DT_DOM, bb) {
            var i = block_first(bb);
            while i >= 0 { if iop(i) == OP_TRUNC { tc_wl.push(i); } i = inst_next(i); }
        }
        bb = block_next(bb);
    }
    while tc_wl.len > 0 {
        tc_cur = tc_wl.pop();
        let sbw = tc_get_best_truncated_type();
        if sbw > 0 {
            tc_reduce_expression_graph(sbw);
            changed = true;
        }
    }
    tc_map_clear();
    return changed;
}
