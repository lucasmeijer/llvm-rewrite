// InstCombine PHI nodes: port of llvm/lib/Transforms/InstCombine/InstCombinePHI.cpp (visitPHINode and every
// helper of that file, in the order of the C++ file).
//
// Conventions (DESIGN.md §12): a fold returns an instruction id: -1 = nullptr, the visited instruction =
// modified in place, or a new unattached instruction. Local helpers are prefixed `ph_`.
namespace ic;
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import intrinsics;
import datalayout;
import domtree;
import constfold;
import cfold;
import pm;
import vt;
import poison;
import knownbits;
import instsimplify;
import apint;
import memloc;
import cfgutil;
import mem2reg;
import ic;
import ic_builder;
import ic_common;
import ic_compares;
import ic_andorxor;
import ic_shifts;
import ic_select;

let PH_MAX_NUM_PHIS: i64 = 512;

fn ph_name(v: i32, sfx: const u8[:]) -> u8[>..] {
    var nm: u8[>..] = [];
    nm.append(val_name(v));
    nm.append(sfx);
    return nm;
}
// PHINode::Create(Ty, N, Name) (unattached; the name is registered on insertion)
fn ph_new_phi(ty: i32, n: i64, name: const u8[:]) -> i32 {
    let p = new_inst(OP_PHI, ty, n);
    vals[p].nops = 0;
    if name.len > 0 { set_name(p, name); }
    return p;
}
fn ph_dl(i: i32) -> i32 { inst_get_md(i, 0) }
fn ph_set_dl(i: i32, dl: i32) { if dl >= 0 { inst_set_md(i, 0, dl); } else { inst_erase_md(i, 0); } }
// BasicBlock::hasInsertionPt
fn ph_has_insertion_pt(bb: i32) -> bool { first_insertion_pt(bb) >= 0 }

// InstCombinerImpl::PHIArgMergedDebugLoc(Inst, PN)
fn phi_arg_merged_debug_loc(inst: i32, pn: i32) {
    let first = op(pn, 0);
    ph_set_dl(inst, ph_dl(first));
    for k in 1..nops(pn) {
        let i = op(pn, k);
        ph_set_dl(inst, m2r_merged_location(ph_dl(inst), ph_dl(i)));
    }
}

// InstCombinerImpl::foldDeadPhiWeb(PN)
fn fold_dead_phi_web(pn: i32) -> bool {
    var stack: i32[>..<] = [];
    var visited: i32[>..<] = [];
    stack.push(pn);
    visited.push(pn);
    while stack.len > 0 {
        let phi = stack.pop();
        var u = vals[phi].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if is_phi_inst(us) {
                var seen = false;
                for x in visited { if x == us { seen = true; } }
                if seen { continue; }
                visited.push(us);
                if visited.len >= 16 { return false; }
                stack.push(us);
            } else {
                return false;
            }
        }
    }
    for p in visited { ic_replace_inst_uses_with(p, c_poison(vals[p].ty)); }
    for p in visited { ic_erase(p); }
    return true;
}

// the HasPointerUse lambda of foldIntegerTypedPHI
fn ph_has_pointer_use(iip: i32) -> bool {
    var u = vals[iip].first_use;
    while u >= 0 {
        let us = uses[u].user;
        u = uses[u].next;
        var ptr: i32 = -1;
        if is_inst_op(us, OP_LOAD) { ptr = op(us, 0); }
        else if is_inst_op(us, OP_STORE) { ptr = op(us, 1); }
        else if is_inst_op(us, OP_GEP) { ptr = op(us, 0); }
        if ptr >= 0 && ptr == iip { return true; }
    }
    return false;
}

// InstCombinerImpl::foldIntegerTypedPHI(PN)
fn fold_integer_typed_phi(pn: i32) -> bool {
    if !ty_is_int(vals[pn].ty) { return false; }
    if !has_one_use(pn) { return false; }
    let itp = uses[vals[pn].first_use].user;
    if !is_inst_op(itp, OP_INTTOPTR) { return false; }
    if !ph_has_pointer_use(itp) { return false; }
    let pty = vals[itp].ty;
    if dl_ptr(ptr_as(pty)).bits != ty_bits(vals[op(itp, 0)].ty) { return false; }
    var avail: i32[>..<] = [];
    let n = nops(pn);
    for k in n {
        let bb = phi_block(pn, k);
        let arg = op(pn, k);
        if !is_inst(arg) && vals[arg].kind != VK_ARG { return false; }
        if is_inst_op(arg, OP_PTRTOINT) && vals[op(arg, 0)].ty == pty {
            avail.push(op(arg, 0));
            continue;
        }
        var arg_itp: i32 = -1;
        var u = vals[arg].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if is_inst_op(us, OP_INTTOPTR) && vals[us].ty == pty && (dt_inst_dominates_block(us, bb) || inst_parent(us) == bb) {
                arg_itp = us;
                break;
            }
        }
        if arg_itp >= 0 { avail.push(arg_itp); continue; }
        if is_phi_inst(arg) { avail.push(arg); continue; }
        if !is_inst_op(arg, OP_LOAD) { return false; }
        if !has_one_use(arg) { return false; }
        avail.push(arg);
    }
    let bb = inst_parent(pn);
    var matching: i32 = -1;
    var num_phis: i64 = 0;
    var it = block_first(bb);
    while it >= 0 && iop(it) == OP_PHI {
        let pp = it;
        it = inst_next(it);
        let np = num_phis;
        num_phis++;
        if np > PH_MAX_NUM_PHIS { return false; }
        if pp == pn || vals[pp].ty != pty { continue; }
        var differs = false;
        for k in n {
            let j = phi_block_index(pp, phi_block(pn, k));
            let v = if j >= 0 { op(pp, j) } else { -1 };
            if v != avail[k] { differs = true; break; }
        }
        if differs { continue; }
        matching = pp;
        break;
    }
    if matching >= 0 {
        ic_replace_inst_uses_with(itp, matching);
        ic_erase(itp);
        ic_erase(pn);
        return true;
    }
    var all_conv = true;
    for v in avail { if !(vals[v].ty != pty || is_inst_op(v, OP_INTTOPTR)) { all_conv = false; } }
    if all_conv { return false; }
    for v in avail {
        if vals[v].ty == pty { continue; }
        if !is_inst(v) { continue; }
        if is_terminator_op(iop(v)) { return false; }
        if is_phi_inst(v) && !ph_has_insertion_pt(inst_parent(v)) { return false; }
    }
    let nphi = ph_new_phi(pty, n, ph_name(pn, ".ptr"));
    ic_insert_new_before(nphi, pn);
    var cast_from: i32[>..<] = [];
    var cast_to: i32[>..<] = [];
    for k in n {
        let ibb = phi_block(pn, k);
        let iv = avail[k];
        if vals[iv].ty == pty { phi_add_incoming(nphi, iv, ibb); continue; }
        var ci: i32 = -1;
        for j in cast_from.len { if cast_from[j] == iv { ci = cast_to[j]; } }
        if ci < 0 {
            let o = if is_ptr_or_ptr_vec(vals[iv].ty) { OP_BITCAST } else { OP_INTTOPTR };
            ci = ic_new_cast(o, iv, pty);
            set_name(ci, ph_name(iv, ".ptr"));
            if is_inst(iv) {
                var pos = inst_next(iv);
                if is_phi_inst(iv) { pos = first_insertion_pt(inst_parent(iv)); }
                ic_insert_new_before(ci, pos);
            } else {
                let entry = func_entry(inst_func(pn));
                ic_insert_new_before(ci, first_insertion_pt(entry));
            }
            cast_from.push(iv);
            cast_to.push(ci);
        }
        phi_add_incoming(nphi, ci, ibb);
    }
    ic_replace_inst_uses_with(itp, nphi);
    ic_erase(itp);
    ic_erase(pn);
    return true;
}

// InstCombinerImpl::foldPHIArgIntToPtrToPHI(PN)
fn fold_phi_arg_int_to_ptr_to_phi(pn: i32) -> i32 {
    var u = vals[pn].first_use;
    while u >= 0 { if !is_inst_op(uses[u].user, OP_PTRTOINT) { return -1; } u = uses[u].next; }
    var any = false;
    for k in nops(pn) {
        let nv = simplify_int_to_ptr_round_trip_cast(op(pn, k));
        if nv >= 0 {
            ic_replace_operand(pn, k, nv);
            any = true;
        }
    }
    if !any { return -1; }
    return pn;
}

fn ph_indices_eq(a: i32, b: i32) -> bool {
    let x = insts[inst_of(a)];
    let y = insts[inst_of(b)];
    if x.naux != y.naux { return false; }
    for k in x.naux as i64 { if ints[x.aux as i64 + k] != ints[y.aux as i64 + k] { return false; } }
    return true;
}
// a copy of the instruction's index list into a new aggregate instruction (Insert/ExtractValueInst::Create)
fn ph_copy_indices(dst: i32, src: i32) {
    let x = insts[inst_of(src)];
    let d = inst_of(dst);
    insts[d].aux = ints.len as i32;
    insts[d].naux = x.naux;
    for k in x.naux as i64 { let m = ints[x.aux as i64 + k]; ints.push(m); }
}

// InstCombinerImpl::foldPHIArgInsertValueInstructionIntoPHI(PN)
fn fold_phi_arg_insert_value_into_phi(pn: i32) -> i32 {
    let first = op(pn, 0);
    for k in 1..nops(pn) {
        let i = op(pn, k);
        if !is_inst_op(i, OP_INSERTVALUE) || !has_one_user(i) || !ph_indices_eq(i, first) { return -1; }
    }
    var newops: i32[2] = [-1, -1];
    for oi in 2 {
        let fo = op(first, oi);
        let np = ph_new_phi(vals[fo].ty, nops(pn), ph_name(fo, ".pn"));
        for k in nops(pn) { phi_add_incoming(np, op(op(pn, k), oi), phi_block(pn, k)); }
        ic_insert_new_before(np, pn);
        newops[oi] = np;
    }
    let nv = create_inst(OP_INSERTVALUE, vals[first].ty, [newops[0], newops[1]]);
    ph_copy_indices(nv, first);
    set_name(nv, ph_name(pn, ""));
    phi_arg_merged_debug_loc(nv, pn);
    return nv;
}

// InstCombinerImpl::foldPHIArgExtractValueInstructionIntoPHI(PN)
fn fold_phi_arg_extract_value_into_phi(pn: i32) -> i32 {
    let first = op(pn, 0);
    for k in 1..nops(pn) {
        let i = op(pn, k);
        if !is_inst_op(i, OP_EXTRACTVALUE) || !has_one_user(i) || !ph_indices_eq(i, first) ||
           vals[op(i, 0)].ty != vals[op(first, 0)].ty { return -1; }
    }
    let fa = op(first, 0);
    let np = ph_new_phi(vals[fa].ty, nops(pn), ph_name(fa, ".pn"));
    for k in nops(pn) { phi_add_incoming(np, op(op(pn, k), 0), phi_block(pn, k)); }
    ic_insert_new_before(np, pn);
    let nv = create_inst(OP_EXTRACTVALUE, vals[first].ty, [np]);
    ph_copy_indices(nv, first);
    set_name(nv, ph_name(pn, ""));
    phi_arg_merged_debug_loc(nv, pn);
    return nv;
}

// CmpInst::Create(Op, Pred, L, R): no samesign, no fast-math flags
fn ph_new_cmp(o: i64, p: i64, l: i32, r: i32) -> i32 {
    let c = create_inst(o, cmp_result_ty(vals[l].ty), [l, r]);
    insts[inst_of(c)].pred = p as u8;
    return c;
}

// InstCombinerImpl::foldPHIArgBinOpIntoPHI(PN)
fn fold_phi_arg_binop_into_phi(pn: i32) -> i32 {
    let first = op(pn, 0);
    let o = iop(first);
    var lv = op(first, 0);
    var rv = op(first, 1);
    let lty = vals[lv].ty;
    let rty = vals[rv].ty;
    let is_cmp = o == OP_ICMP || o == OP_FCMP;
    for k in 1..nops(pn) {
        let i = op(pn, k);
        if !is_inst(i) || iop(i) != o || !has_one_user(i) || vals[op(i, 0)].ty != lty || vals[op(i, 1)].ty != rty { return -1; }
        if is_cmp && inst_pred(i) != inst_pred(first) { return -1; }
        if op(i, 0) != lv { lv = -1; }
        if op(i, 1) != rv { rv = -1; }
    }
    if lv < 0 && rv < 0 { return -1; }
    let inl = op(first, 0);
    let inr = op(first, 1);
    var nl: i32 = -1;
    var nr: i32 = -1;
    if lv < 0 {
        nl = ph_new_phi(lty, nops(pn), ph_name(op(first, 0), ".pn"));
        phi_add_incoming(nl, inl, phi_block(pn, 0));
        ic_insert_new_before(nl, pn);
        lv = nl;
    }
    if rv < 0 {
        nr = ph_new_phi(rty, nops(pn), ph_name(op(first, 1), ".pn"));
        phi_add_incoming(nr, inr, phi_block(pn, 0));
        ic_insert_new_before(nr, pn);
        rv = nr;
    }
    if nl >= 0 || nr >= 0 {
        for k in 1..nops(pn) {
            let ib = phi_block(pn, k);
            let ii = op(pn, k);
            if nl >= 0 { phi_add_incoming(nl, op(ii, 0), ib); }
            if nr >= 0 { phi_add_incoming(nr, op(ii, 1), ib); }
        }
    }
    if is_cmp {
        let nc = ph_new_cmp(o, inst_pred(first), lv, rv);
        phi_arg_merged_debug_loc(nc, pn);
        return nc;
    }
    let nb = ic_new_binop(o, lv, rv);
    copy_ir_flags(nb, op(pn, 0));
    for k in 1..nops(pn) { sl_and_ir_flags(nb, op(pn, k)); }
    phi_arg_merged_debug_loc(nb, pn);
    return nb;
}

// GEPOperator::hasAllConstantIndices
fn ph_gep_all_constant_indices(g: i32) -> bool {
    for k in 1..nops(g) { if !is_constant(op(g, k)) { return false; } }
    return true;
}

// InstCombinerImpl::foldPHIArgGEPIntoPHI(PN)
fn fold_phi_arg_gep_into_phi(pn: i32) -> i32 {
    let first = op(pn, 0);
    let nf = nops(first);
    var fixed: i32[>..<] = [];
    for k in nf { fixed.push(op(first, k)); }
    var all_alloca = true;
    var needed_phi = false;
    var nw = gep_flags(first);
    for k in 1..nops(pn) {
        let g = op(pn, k);
        if !is_inst_op(g, OP_GEP) || !has_one_user(g) || gep_src_ty(g) != gep_src_ty(first) || nops(g) != nf { return -1; }
        nw = sl_gep_nw_and(nw, gep_flags(g));
        if all_alloca && (!is_inst_op(op(g, 0), OP_ALLOCA) || !ph_gep_all_constant_indices(g)) { all_alloca = false; }
        for j in nf {
            if op(first, j) == op(g, j) { continue; }
            if is_constant(op(first, j)) || is_constant(op(g, j)) { return -1; }
            if vals[op(first, j)].ty != vals[op(g, j)].ty { return -1; }
            if needed_phi { return -1; }
            fixed[j] = -1;
            needed_phi = true;
        }
    }
    if all_alloca { return -1; }
    var opphis: i32[>..<] = [];
    for k in nf { opphis.push(-1); }
    var any = false;
    for j in nf {
        if fixed[j] >= 0 { continue; }
        let fo = op(first, j);
        let np = ph_new_phi(vals[fo].ty, nf, ph_name(fo, ".pn"));
        ic_insert_new_before(np, pn);
        phi_add_incoming(np, fo, phi_block(pn, 0));
        opphis[j] = np;
        fixed[j] = np;
        any = true;
    }
    if any {
        for k in 1..nops(pn) {
            let ib = phi_block(pn, k);
            let g = op(pn, k);
            for j in nf { if opphis[j] >= 0 { phi_add_incoming(opphis[j], op(g, j), ib); } }
        }
    }
    let base = fixed[0];
    var idxs: i32[>..<] = [];
    for j in 1..nf { idxs.push(fixed[j]); }
    let ng = create_inst(OP_GEP, gep_ret_type(base, idxs), fixed);
    insts[inst_of(ng)].ty2 = gep_src_ty(first);
    insts[inst_of(ng)].flags = nw;
    phi_arg_merged_debug_loc(ng, pn);
    return ng;
}
// GEPNoWrapFlags operator&
fn sl_gep_nw_and(a: u8, b: u8) -> u8 { a & b }

// isSafeAndProfitableToSinkLoad(L)
fn is_safe_and_profitable_to_sink_load(l: i32) -> bool {
    var it = inst_next(l);
    while it >= 0 {
        if inst_may_write_memory(it) {
            if is_callbase(it) && me_without(call_memory_effects(it), LOC_INACCESSIBLE) == 0 { it = inst_next(it); continue; }
            return false;
        }
        it = inst_next(it);
    }
    let p = op(l, 0);
    if is_inst_op(p, OP_ALLOCA) {
        var taken = false;
        var u = vals[p].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if is_inst_op(us, OP_LOAD) { continue; }
            if is_inst_op(us, OP_STORE) && op(us, 1) == p { continue; }
            taken = true;
            break;
        }
        if !taken && is_static_alloca(p) { return false; }
    }
    if is_inst_op(p, OP_GEP) {
        let a = op(p, 0);
        if is_inst_op(a, OP_ALLOCA) && is_static_alloca(a) && ph_gep_all_constant_indices(p) { return false; }
    }
    return true;
}
fn ph_load_is_simple(l: i32) -> bool { !inst_is_volatile(l) && !inst_is_atomic(l) }

// InstCombinerImpl::foldPHIArgLoadIntoPHI(PN)
fn fold_phi_arg_load_into_phi(pn: i32) -> i32 {
    let fl = op(pn, 0);
    if !cu_can_replace_operand_with_variable(fl, 0) { return -1; }
    if !ph_load_is_simple(fl) { return -1; }
    var la = insts[inst_of(fl)].align;
    let las = ptr_as(vals[op(fl, 0)].ty);
    if inst_parent(fl) != phi_block(pn, 0) || !is_safe_and_profitable_to_sink_load(fl) { return -1; }
    for k in 1..nops(pn) {
        let ib = phi_block(pn, k);
        let li = op(pn, k);
        if !is_inst_op(li, OP_LOAD) || !has_one_user(li) || !ph_load_is_simple(li) { return -1; }
        if ptr_as(vals[op(li, 0)].ty) != las { return -1; }
        if !cu_can_replace_operand_with_variable(li, 0) { return -1; }
        if inst_parent(li) != ib || !is_safe_and_profitable_to_sink_load(li) { return -1; }
        let a = insts[inst_of(li)].align;
        if a < la { la = a; }
    }
    let np = ph_new_phi(vals[op(fl, 0)].ty, nops(pn), ph_name(pn, ".in"));
    var inv = op(fl, 0);
    phi_add_incoming(np, inv, phi_block(pn, 0));
    let nl = create_inst(OP_LOAD, vals[fl].ty, [np]);
    insts[inst_of(nl)].align = la;
    ph_copy_metadata(nl, fl);
    for k in 1..nops(pn) {
        let bb = phi_block(pn, k);
        let li = op(pn, k);
        cu_combine_metadata(nl, li, true, false);
        let ni = op(li, 0);
        if ni != inv { inv = -1; }
        phi_add_incoming(np, ni, bb);
    }
    if inv >= 0 {
        set_op(nl, 0, inv);
        ph_delete_unattached_phi(np);
    } else {
        ic_insert_new_before(np, pn);
    }
    phi_arg_merged_debug_loc(nl, pn);
    return nl;
}
// Instruction::copyMetadata(SrcInst): every attachment, the debug location included
fn ph_copy_metadata(dst: i32, src: i32) {
    let si = inst_of(src);
    var ks: i32[>..<] = [];
    var ns: i32[>..<] = [];
    for k in insts[si].nmd {
        ks.push(md_att[insts[si].md + 2 * k]);
        ns.push(md_att[insts[si].md + 2 * k + 1]);
    }
    for k in ks.len { inst_set_md(dst, ks[k], ns[k]); }
}
// `delete NewPN` of an unattached phi: drop its operands so the values lose those uses
fn ph_delete_unattached_phi(p: i32) {
    drop_all_refs(p);
    val_set_dead(p);
}

// InstCombinerImpl::foldPHIArgZextsIntoPHI(Phi)
fn fold_phi_arg_zexts_into_phi(phi: i32) -> i32 {
    let ti = block_terminator(inst_parent(phi));
    if ti >= 0 && inst_is_eh_pad(ti) { return -1; }
    let n = nops(phi);
    if n < 3 { return -1; }
    var narrow: i32 = -1;
    for k in n { let v = op(phi, k); if is_inst_op(v, OP_ZEXT) { narrow = vals[op(v, 0)].ty; break; } }
    if narrow < 0 { return -1; }
    var newin: i32[>..<] = [];
    var nz: i64 = 0;
    var nc: i64 = 0;
    for k in n {
        let v = op(phi, k);
        if is_inst_op(v, OP_ZEXT) {
            if vals[op(v, 0)].ty != narrow || !has_one_user(v) { return -1; }
            newin.push(op(v, 0));
            nz++;
        } else if is_constant(v) {
            let t, nneg = ao_lossless_trunc(v, narrow, OP_ZEXT);
            if t < 0 { return -1; }
            newin.push(t);
            nc++;
        } else { return -1; }
    }
    if nc == 0 || nz < 2 { return -1; }
    let np = ph_new_phi(narrow, n, ph_name(phi, ".shrunk"));
    for k in n { phi_add_incoming(np, newin[k], phi_block(phi, k)); }
    ic_insert_new_before(np, phi);
    let ci = ic_new_zext_or_bitcast(np, vals[phi].ty);
    inst_erase_md(ci, 0);
    return ci;
}

// InstCombinerImpl::foldPHIArgOpIntoPHI(PN)
fn fold_phi_arg_op_into_phi(pn: i32) -> i32 {
    let ti = block_terminator(inst_parent(pn));
    if ti >= 0 && inst_is_eh_pad(ti) { return -1; }
    let first = op(pn, 0);
    let fo = iop(first);
    if fo == OP_GEP { return fold_phi_arg_gep_into_phi(pn); }
    if fo == OP_LOAD { return fold_phi_arg_load_into_phi(pn); }
    if fo == OP_INSERTVALUE { return fold_phi_arg_insert_value_into_phi(pn); }
    if fo == OP_EXTRACTVALUE { return fold_phi_arg_extract_value_into_phi(pn); }
    var cop: i32 = -1;
    var cast_src: i32 = -1;
    let is_cmp = fo == OP_ICMP || fo == OP_FCMP;
    if is_cast_inst(first) {
        cast_src = vals[op(first, 0)].ty;
        if ty_is_int(vals[pn].ty) && ty_is_int(cast_src) {
            if !should_change_type(vals[pn].ty, cast_src) { return -1; }
        }
    } else if is_binop_inst(first) || is_cmp {
        if !is_constant(op(first, 1)) { return fold_phi_arg_binop_into_phi(pn); }
        cop = op(first, 1);
    } else {
        return -1;
    }
    for k in 1..nops(pn) {
        let i = op(pn, k);
        if !is_inst(i) || !has_one_user(i) || !sl_same_operation_as(i, first) { return -1; }
        if cast_src >= 0 {
            if vals[op(i, 0)].ty != cast_src { return -1; }
        } else if op(i, 1) != cop { return -1; }
    }
    let np = ph_new_phi(vals[op(first, 0)].ty, nops(pn), ph_name(pn, ".in"));
    var inv = op(first, 0);
    phi_add_incoming(np, inv, phi_block(pn, 0));
    for k in 1..nops(pn) {
        let bb = phi_block(pn, k);
        let ni = op(op(pn, k), 0);
        if ni != inv { inv = -1; }
        phi_add_incoming(np, ni, bb);
    }
    var pv: i32 = -1;
    if inv >= 0 {
        pv = inv;
        ph_delete_unattached_phi(np);
    } else {
        ic_insert_new_before(np, pn);
        pv = np;
    }
    if is_cast_inst(first) {
        let nc = ic_new_cast(fo, pv, vals[pn].ty);
        phi_arg_merged_debug_loc(nc, pn);
        return nc;
    }
    if is_binop_inst(first) {
        let b = ic_new_binop(fo, pv, cop);
        copy_ir_flags(b, op(pn, 0));
        for k in 1..nops(pn) { sl_and_ir_flags(b, op(pn, k)); }
        phi_arg_merged_debug_loc(b, pn);
        return b;
    }
    let nc = ph_new_cmp(fo, inst_pred(first), pv, cop);
    phi_arg_merged_debug_loc(nc, pn);
    return nc;
}

// PHIsEqualValue(PN, NonPhiInVal, ValueEqualPHIs): ok, NonPhiInVal (the set is ph_eq_set)
var ph_eq_set: i32[>..<];
recursive fn phis_equal_value(pn: i32, nonphi0: i32) -> bool, i32 {
    var nonphi = nonphi0;
    for x in ph_eq_set { if x == pn { return true, nonphi; } }
    ph_eq_set.push(pn);
    if ph_eq_set.len >= 16 { return false, nonphi; }
    for k in nops(pn) {
        let o = op(pn, k);
        if is_phi_inst(o) {
            let ok, nv = phis_equal_value(o, nonphi);
            nonphi = nv;
            if !ok {
                if nonphi >= 0 { return false, nonphi; }
                nonphi = o;
            }
        } else if o != nonphi { return false, nonphi; }
    }
    return true, nonphi;
}

// getAnyNonZeroConstInt(PN)
fn get_any_non_zero_const_int(pn: i32) -> i32 {
    for k in nops(pn) {
        let v = op(pn, k);
        if m_constant_int(v) >= 0 && !ap_is_zero(ci_ap(v)) { return v; }
    }
    return c_int_ty(vals[pn].ty, 1);
}

// PHIUsageRecord
struct PhUse { phiid: i64, shift: i64, inst: i32 }
fn ph_use_lt(a: PhUse, b: PhUse) -> bool {
    if a.phiid != b.phiid { return a.phiid < b.phiid; }
    if a.shift != b.shift { return a.shift < b.shift; }
    return ty_bits(vals[a.inst].ty) < ty_bits(vals[b.inst].ty);
}

// InstCombinerImpl::SliceUpIllegalIntegerPHI(FirstPhi)
fn slice_up_illegal_integer_phi(firstphi: i32) -> i32 {
    var users: PhUse[>..<] = [];
    var slice: i32[>..<] = [];
    slice.push(firstphi);
    var pid: i64 = 0;
    while pid < slice.len {
        let pn = slice[pid];
        var u = vals[pn].first_use;
        while u >= 0 {
            let ui = uses[u].user;
            u = uses[u].next;
            if is_phi_inst(ui) {
                var seen = false;
                for x in slice { if x == ui { seen = true; } }
                if !seen { slice.push(ui); }
                continue;
            }
            if is_inst_op(ui, OP_TRUNC) {
                users.push(PhUse { phiid: pid, shift: 0, inst: ui });
                continue;
            }
            if iop(ui) != OP_LSHR || !has_one_use(ui) || !is_inst_op(uses[vals[ui].first_use].user, OP_TRUNC) ||
               m_constant_int(op(ui, 1)) < 0 { return -1; }
            let sz = ty_sbits(ui);
            if ap_uge_u64(ci_ap(op(ui, 1)), sz as u64) { return -1; }
            let sh = ap_zext64(ci_ap(op(ui, 1))) as i64;
            users.push(PhUse { phiid: pid, shift: sh, inst: uses[vals[ui].first_use].user });
        }
        pid++;
    }
    for pn in slice {
        for k in nops(pn) {
            let bb = phi_block(pn, k);
            let v = op(pn, k);
            if !is_inst_op(v, OP_INVOKE) { continue; }
            if inst_parent(v) != bb { continue; }
            return -1;
        }
        for k in nops(pn) { if !ph_has_insertion_pt(phi_block(pn, k)) { return -1; } }
    }
    if users.len == 0 { return ic_replace_inst_uses_with(firstphi, c_poison(vals[firstphi].ty)); }
    // array_pod_sort (records that compare equal produce the same element PHI)
    let nsort = users.len;
    for a in 1..nsort {
        var b = a;
        while b > 0 && ph_use_lt(users[b], users[b - 1]) {
            let t = users[b]; users[b] = users[b - 1]; users[b - 1] = t;
            b--;
        }
    }
    // ExtractedVals: (phi, offset, width) -> element phi
    var ev_phi: i32[>..<] = [];
    var ev_off: i64[>..<] = [];
    var ev_w: i64[>..<] = [];
    var ev_res: i32[>..<] = [];
    var pv_bb: i32[>..<] = [];
    var pv_val: i32[>..<] = [];
    var ui: i64 = 0;
    while ui < users.len {
        let rec = users[ui];
        let pn = slice[rec.phiid];
        let off = rec.shift;
        let ty = vals[rec.inst].ty;
        let w = ty_bits(ty);
        var elt: i32 = -1;
        for j in ev_phi.len { if ev_phi[j] == pn && ev_off[j] == off && ev_w[j] == w { elt = ev_res[j]; } }
        if elt < 0 {
            var nm: u8[>..] = [];
            nm.append(val_name(pn));
            nm.append(".off");
            format(nm, off);
            elt = ph_new_phi(ty, nops(pn), nm);
            ic_insert_before_pos(elt, pn);
            for k in nops(pn) {
                let pred = phi_block(pn, k);
                let inv = op(pn, k);
                var pv: i32 = -1;
                for j in pv_bb.len { if pv_bb[j] == pred { pv = pv_val[j]; } }
                if pv >= 0 { phi_add_incoming(elt, pv, pred); continue; }
                if inv == pn {
                    pv_bb.push(pred); pv_val.push(elt);
                    phi_add_incoming(elt, elt, pred);
                    continue;
                }
                icb_set_insert_point(block_terminator(pred));
                var res = inv;
                if off != 0 { res = icb_lshr(res, c_int_ty(vals[inv].ty, off as u64), "extract", false); }
                res = icb_trunc(res, ty, "extract.t");
                pv_bb.push(pred); pv_val.push(res);
                phi_add_incoming(elt, res, pred);
                if is_phi_inst(inv) {
                    var ref_id: i64 = -1;
                    for j in slice.len { if slice[j] == inv && ref_id < 0 { ref_id = j; } }
                    if ref_id >= 0 { users.push(PhUse { phiid: ref_id, shift: off, inst: res }); }
                }
            }
            pv_bb.resize(0);
            pv_val.resize(0);
            ev_phi.push(pn); ev_off.push(off); ev_w.push(w); ev_res.push(elt);
        }
        ic_replace_inst_uses_with(users[ui].inst, elt);
        ui++;
    }
    let pz = c_poison(vals[firstphi].ty);
    for k in 1..slice.len { ic_replace_inst_uses_with(slice[k], pz); }
    return ic_replace_inst_uses_with(firstphi, pz);
}

// simplifyUsingControlFlow(Self, PN, DT)
fn simplify_using_control_flow(pn: i32) -> i32 {
    for k in nops(pn) { if m_constant_int(op(pn, k)) < 0 { return -1; } }
    let bb = inst_parent(pn);
    if !dt_has_node(DT_DOM, bb) { return -1; }
    let idom = dt_idom(DT_DOM, bb);
    if idom < 0 { return -1; }
    let t = block_terminator(idom);
    var cond: i32 = -1;
    var sv_c: i32[>..<] = [];
    var sv_b: i32[>..<] = [];
    var sc_b: i32[>..<] = [];
    var sc_n: i64[>..<] = [];
    fn add_count(sc_b: i32[>..<]&, sc_n: i64[>..<]&, b: i32) {
        for j in sc_b.len { if sc_b[j] == b { sc_n[j] += 1; return; } }
        sc_b.push(b);
        sc_n.push(1);
    }
    fn add_succ(sv_c: i32[>..<]&, sv_b: i32[>..<]&, sc_b: i32[>..<]&, sc_n: i64[>..<]&, c: i32, b: i32) {
        var found = false;
        for j in sv_c.len { if sv_c[j] == c { sv_b[j] = b; found = true; } }
        if !found { sv_c.push(c); sv_b.push(b); }
        add_count(sc_b, sc_n, b);
    }
    if iop(t) == OP_CONDBR {
        cond = op(t, 0);
        add_succ(sv_c, sv_b, sc_b, sc_n, c_bool_ty(T_I1, true), term_succ(t, 0));
        add_succ(sv_c, sv_b, sc_b, sc_n, c_bool_ty(T_I1, false), term_succ(t, 1));
    } else if iop(t) == OP_SWITCH {
        cond = op(t, 0);
        add_count(sc_b, sc_n, op(t, 1));
        let nc = (nops(t) - 2) / 2;
        for j in nc { add_succ(sv_c, sv_b, sc_b, sc_n, op(t, 2 + 2 * j), op(t, 3 + 2 * j)); }
    } else { return -1; }
    if vals[cond].ty != vals[pn].ty { return -1; }
    var invert: i64 = -1;
    for k in nops(pn) {
        let input = op(pn, k);
        let pred = phi_block(pn, k);
        var needs: bool = false;
        if ph_is_correct_input(input, pred, bb, idom, sv_c, sv_b, sc_b, sc_n) { needs = false; }
        else if ph_is_correct_input(ce_not(input), pred, bb, idom, sv_c, sv_b, sc_b, sc_n) { needs = true; }
        else { return -1; }
        let nv: i64 = if needs { 1 } else { 0 };
        if invert >= 0 && invert != nv { return -1; }
        invert = nv;
    }
    if invert == 0 { return cond; }
    let ip = first_insertion_pt(bb);
    if ip >= 0 {
        icb_set_insert_point(ip);
        return icb_not(cond, "");
    }
    return -1;
}
// the IsCorrectInput lambda
fn ph_is_correct_input(input: i32, pred: i32, bb: i32, idom: i32, sv_c: const i32[:], sv_b: const i32[:], sc_b: const i32[:], sc_n: const i64[:]) -> bool {
    var succ: i32 = -1;
    for j in sv_c.len { if sv_c[j] == input { succ = sv_b[j]; } }
    if succ < 0 { return false; }
    var cnt: i64 = 0;
    for j in sc_b.len { if sc_b[j] == succ { cnt = sc_n[j]; } }
    return cnt == 1 && sl_dom_edge_edge(idom, succ, pred, bb);
}

// foldDependentIVs(PN, Builder)
fn fold_dependent_ivs(pn: i32) -> i32 {
    let bb = inst_parent(pn);
    if nops(pn) != 2 { return -1; }
    var start: i32 = -1;
    var ivnext: i32 = -1;
    var iv2next: i32 = -1;
    fn match_outer(v1: i32, v2: i32) -> bool, i32, i32, i32 {
        if is_binop_inst(v2) {
            if op(v2, 0) == v1 && is_binop_inst(op(v2, 1)) { return true, v1, v2, op(v2, 1); }
            if is_commutative(iop(v2)) && op(v2, 1) == v1 && is_binop_inst(op(v2, 0)) { return true, v1, v2, op(v2, 0); }
        }
        if is_op(v2, OP_GEP) && nops(v2) == 2 && op(v2, 0) == v1 && is_binop_inst(op(v2, 1)) { return true, v1, v2, op(v2, 1); }
        return false, -1, -1, -1;
    }
    let ok1, s1, n1, i1 = match_outer(op(pn, 0), op(pn, 1));
    if ok1 { start = s1; ivnext = n1; iv2next = i1; }
    else {
        let ok2, s2, n2, i2 = match_outer(op(pn, 1), op(pn, 0));
        if !ok2 { return -1; }
        start = s2; ivnext = n2; iv2next = i2;
    }
    let ok, iv2, iv2start, iv2step = ao_match_simple_recurrence(iv2next);
    if !ok || inst_parent(iv2) != bb { return -1; }
    let isbo = is_binop_inst(ivnext);
    let ident = if isbo { binop_identity(iop(ivnext), vals[iv2start].ty, false) } else { c_null(vals[iv2start].ty) };
    if iv2start != ident { return -1; }
    icb_set_insert_point(first_insertion_pt(bb));
    if !isbo {
        return icb_gep(gep_src_ty(ivnext), start, [iv2], "", gep_flags(ivnext));
    }
    let res = icb_binop(iop(ivnext), iv2, start, "");
    copy_ir_flags(res, ivnext);
    return res;
}

// PredOrder: the block order of the first PHI visited in each block (per InstCombinerImpl, i.e. per iteration)
var ph_po_bb: i32[>..<];
var ph_po_at: i64[>..<];
var ph_po_blocks: i32[>..<];
fn ic_phi_reset_pred_order() { ph_po_bb.resize(0); ph_po_at.resize(0); ph_po_blocks.resize(0); }

// PHINode::isIdenticalToWhenDefined(Other)
fn ph_identical_when_defined(a: i32, b: i32) -> bool {
    if vals[a].ty != vals[b].ty || nops(a) != nops(b) { return false; }
    for k in nops(a) { if op(a, k) != op(b, k) || phi_block(a, k) != phi_block(b, k) { return false; } }
    return true;
}

// InstCombinerImpl::visitPHINode(PN)
fn visit_phi(pn: i32) -> i32 {
    let mark = is_ops.len;
    let n = nops(pn);
    for k in n { is_ops.push(op(pn, k)); }
    var sv = simplify_inst_with_ops(pn, mark, n, sq_at(pn), RECURSION_LIMIT);
    is_ops.resize(mark);
    if sv >= 0 {
        if sv == pn { sv = c_poison(vals[pn].ty); }
        return ic_replace_inst_uses_with(pn, sv);
    }
    var r = fold_phi_arg_zexts_into_phi(pn);
    if r >= 0 { return r; }
    r = fold_phi_arg_int_to_ptr_to_phi(pn);
    if r >= 0 { return r; }
    let i0 = op(pn, 0);
    let i1 = if n > 1 { op(pn, 1) } else { -1 };
    if is_inst(i0) && i1 >= 0 && is_inst(i1) && iop(i0) == iop(i1) && has_one_user(i0) {
        r = fold_phi_arg_op_into_phi(pn);
        if r >= 0 { return r; }
    }
    if ty_kind(vals[pn].ty) == TK_PTR && ph_has_insertion_pt(inst_parent(pn)) {
        let iv0 = op(pn, 0);
        let st = strip_pointer_casts(iv0);
        if iv0 != st {
            var checked: i32[>..<] = [];
            checked.push(iv0);
            var all = true;
            for k in n {
                let iv = op(pn, k);
                var dup = false;
                for x in checked { if x == iv { dup = true; } }
                if dup { continue; }
                checked.push(iv);
                if st != strip_pointer_casts(iv) { all = false; break; }
            }
            if all {
                let o = if ptr_as(vals[st].ty) != ptr_as(vals[pn].ty) { OP_ADDRSPACECAST } else { OP_BITCAST };
                return ic_new_cast(o, st, vals[pn].ty);
            }
        }
    }
    if fold_dead_phi_web(pn) { return -1; }
    if has_one_use(pn) {
        if fold_integer_typed_phi(pn) { return -1; }
        let user = uses[vals[pn].first_use].user;
        if has_one_use(user) && (is_binop_inst(user) || iop(user) == OP_FNEG || iop(user) == OP_GEP) &&
           uses[vals[user].first_use].user == pn {
            return ic_replace_inst_uses_with(pn, c_poison(vals[pn].ty));
        }
    }
    if !has_n_uses_or_more(pn, 3) {
        var drop: i32[>..<] = [];
        var all_cmp = true;
        var u = vals[pn].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            var cmpi = if is_inst_op(us, OP_ICMP) { us } else { -1 };
            if cmpi < 0 {
                if has_one_use(us) && bo(us, OP_OR) && (op(us, 0) == pn || op(us, 1) == pn) {
                    drop.push(us);
                    let uu = uses[vals[us].first_use].user;
                    cmpi = if is_inst_op(uu, OP_ICMP) { uu } else { -1 };
                }
            }
            if cmpi < 0 || !ty_is_int(vals[pn].ty) || (inst_pred(cmpi) != P_EQ && inst_pred(cmpi) != P_NE) || !m_zero(op(cmpi, 1)) {
                all_cmp = false;
                break;
            }
        }
        if all_cmp {
            var nzc: i32 = -1;
            var made = false;
            for k in nops(pn) {
                let cx = block_terminator(phi_block(pn, k));
                let va = op(pn, k);
                kb_cxt = cx;
                if is_known_non_zero(va, 0) {
                    if nzc < 0 { nzc = get_any_non_zero_const_int(pn); }
                    if nzc != va {
                        ic_replace_operand(pn, k, nzc);
                        for x in drop { drop_poison_generating_flags(x); }
                        made = true;
                    }
                }
            }
            if made { return pn; }
        }
    }
    {
        var inv: i64 = 0;
        while inv != n && is_phi_inst(op(pn, inv)) { inv++; }
        var nonphi: i32 = if inv != n { op(pn, inv) } else { -1 };
        if nonphi >= 0 {
            inv++;
            while inv != n {
                let ov = op(pn, inv);
                if ov != nonphi && !is_phi_inst(ov) { break; }
                inv++;
            }
        }
        if inv == n {
            ph_eq_set.resize(0);
            let ok, nv = phis_equal_value(pn, nonphi);
            ph_eq_set.resize(0);
            if ok { return ic_replace_inst_uses_with(pn, nv); }
        }
    }
    let bb = inst_parent(pn);
    var po: i64 = -1;
    for j in ph_po_bb.len { if ph_po_bb[j] == bb { po = ph_po_at[j]; } }
    if po >= 0 {
        for k in n {
            let bba = phi_block(pn, k);
            let bbb = ph_po_blocks[po + k];
            if bba != bbb {
                let va = op(pn, k);
                let j = phi_block_index(pn, bbb);
                let vb = op(pn, j);
                phi_set_block(pn, k, bbb);
                set_op(pn, k, vb);
                phi_set_block(pn, j, bba);
                set_op(pn, j, va);
            }
        }
    } else {
        ph_po_bb.push(bb);
        ph_po_at.push(ph_po_blocks.len);
        for k in n { ph_po_blocks.push(phi_block(pn, k)); }
    }
    var it = block_first(bb);
    while it >= 0 && iop(it) == OP_PHI {
        let ip = it;
        it = inst_next(it);
        if ip == pn { continue; }
        if !ph_identical_when_defined(pn, ip) { continue; }
        return ic_replace_inst_uses_with(pn, ip);
    }
    if ty_is_int(vals[pn].ty) && !dl_is_legal_integer(ty_bits(vals[pn].ty)) {
        r = slice_up_illegal_integer_phi(pn);
        if r >= 0 { return r; }
    }
    let v = simplify_using_control_flow(pn);
    if v >= 0 { return ic_replace_inst_uses_with(pn, v); }
    let d = fold_dependent_ivs(pn);
    if d >= 0 { return ic_replace_inst_uses_with(pn, d); }
    return -1;
}
