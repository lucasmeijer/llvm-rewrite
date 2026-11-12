// MergedLoadStoreMotion: port of llvm/lib/Transforms/Scalar/MergedLoadStoreMotion.cpp
// (MergedLoadStoreMotionPass; only store sinking exists in LLVM 23).
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import aa;
import memloc;
import tli;
import loads;
import instident;
import cfgutil;
import mem2reg;
import aic_trunc;
import misc_util;

fn mm_single_succ(bb: i32) -> i32 { if block_nsucc(bb) == 1 { block_succ(bb, 0) } else { -1 } }
fn mm_size(bb: i32) -> i64 { var n: i64 = 0; var i = block_first(bb); while i >= 0 { n++; i = inst_next(i); } return n; }
fn mm_is_simple(i: i32) -> bool { !inst_is_volatile(i) && insts[inst_of(i)].ord == 0 }

fn mm_is_diamond_head(bb: i32) -> bool {
    let bi = block_terminator(bb);
    if bi < 0 || iop(bi) != OP_CONDBR { return false; }
    let s0 = term_succ(bi, 0);
    let s1 = term_succ(bi, 1);
    if single_pred(s0) < 0 || single_pred(s1) < 0 { return false; }
    let a = mm_single_succ(s0);
    let b = mm_single_succ(s1);
    return a >= 0 && b >= 0 && a == b;
}

// isStoreSinkBarrierInRange(Start, End, Loc): mayThrow in [Start, End), canInstructionRangeModRef over [Start, End]
fn mm_barrier_in_range(start: i32, end: i32, loc: ML) -> bool {
    var i = start;
    while i != end { if inst_may_throw(i) { return true; } i = inst_next(i); }
    i = start;
    loop {
        if aa_inst_loc_mr_simple(i, loc) != MR_NO { return true; }
        if i == end { break; }
        i = inst_next(i);
    }
    return false;
}

fn mm_can_sink_from_block(bb1: i32, s0: i32) -> i32 {
    let bb0 = inst_parent(s0);
    var i = block_last(bb1);
    while i >= 0 {
        let s1 = i;
        i = inst_prev(i);
        if iop(s1) != OP_STORE { continue; }
        let l0 = ml_get(s0);
        let l1 = ml_get(s1);
        if aa_alias_simple(l0, l1).k == AR_MUST &&
           !mm_barrier_in_range(inst_next(s1), block_last(bb1), l1) &&
           !mm_barrier_in_range(inst_next(s0), block_last(bb0), l0) &&
           ii_has_same_special_state(s0, s1, false, false) &&
           ld_is_bit_or_noop_ptr_castable(vals[op(s0, 0)].ty, vals[op(s1, 0)].ty) {
            return s1;
        }
    }
    return -1;
}

// Instruction::isIdenticalTo
fn mm_is_identical(a: i32, b: i32) -> bool {
    return ii_is_identical_when_defined(a, b, false) && insts[inst_of(a)].flags == insts[inst_of(b)].flags &&
           insts[inst_of(a)].fmf == insts[inst_of(b)].fmf;
}

fn mm_can_sink_stores_and_geps(s0: i32, s1: i32) -> bool {
    let p0 = op(s0, 1);
    let p1 = op(s1, 1);
    if p0 == p1 { return true; }
    if !is_inst(p0) || iop(p0) != OP_GEP || !is_inst(p1) || iop(p1) != OP_GEP { return false; }
    return mm_is_identical(p0, p1) && mu_has_one_use(p0) && inst_parent(p0) == inst_parent(s0) &&
           mu_has_one_use(p1) && inst_parent(p1) == inst_parent(s1);
}

fn mm_apply_merged_location(i: i32, a: i32, b: i32) {
    let m = m2r_merged_location(inst_get_md(a, 0), inst_get_md(b, 0));
    if m >= 0 { inst_set_md(i, 0, m); } else { inst_erase_md(i, 0); }
}

fn mm_get_phi_operand(bb: i32, s0: i32, s1: i32) -> i32 {
    let o1 = op(s0, 0);
    let o2 = op(s1, 0);
    if o1 == o2 { return -1; }
    let pn = create_inst(OP_PHI, vals[o1].ty, []);
    inst_insert_before_head(pn, block_first(bb));
    set_name(pn, str(val_name(o2), ".sink"));
    mm_apply_merged_location(pn, s0, s1);
    phi_add_incoming(pn, o1, inst_parent(s0));
    phi_add_incoming(pn, o2, inst_parent(s1));
    return pn;
}

fn mm_sink_stores_and_geps(bb: i32, s0: i32, s1: i32) {
    let p0 = op(s0, 1);
    let p1 = op(s1, 1);
    let ins = mu_first_insertion_pt(bb);
    ii_and_ir_flags(s0, s1);
    cu_combine_metadata(s0, s1, true, false);
    mm_apply_merged_location(s0, s0, s1);
    let dia = md_kind_id("DIAssignID");
    if inst_get_md(s0, dia) >= 0 || inst_get_md(s1, dia) >= 0 { fatal("mldst-motion: mergeDIAssignID is not ported yet"); }
    ab_set(s0);
    let v0 = op(s0, 0);
    let t1 = vals[op(s1, 0)].ty;
    var cast = v0;
    if vals[v0].ty != t1 {
        let st = vals[v0].ty;
        var o = OP_BITCAST;
        if ty_kind(ty_scalar(st)) == TK_PTR && ty_kind(ty_scalar(t1)) == TK_INT { o = OP_PTRTOINT; }
        else if ty_kind(ty_scalar(st)) == TK_INT && ty_kind(ty_scalar(t1)) == TK_PTR { o = OP_INTTOPTR; }
        cast = ab_cast(o, v0, t1, 0, "");
    }
    set_op(s0, 0, cast);
    let snew = inst_clone(s0);
    inst_insert_before_head(snew, ins);
    let pn = mm_get_phi_operand(bb, s0, s1);
    if pn >= 0 { set_op(snew, 0, pn); }
    inst_erase_from_parent(s0);
    inst_erase_from_parent(s1);
    if p0 != p1 {
        let gn = inst_clone(p0);
        inst_insert_before(gn, snew);
        mm_apply_merged_location(gn, p0, p1);
        set_op(snew, 1, gn);
        rauw(p0, gn);
        inst_erase_from_parent(p0);
        rauw(p1, gn);
        inst_erase_from_parent(p1);
    }
}

fn mm_merge_stores(head: i32, split_footer: bool) -> bool {
    var merged = false;
    let tail = mm_single_succ(term_succ(block_terminator(head), 0));
    var sink = tail;
    let pred0 = block_succ(head, 0);
    let pred1 = block_succ(head, 1);
    if pred0 == pred1 { return false; }
    if !split_footer && pred_count(tail) >= 3 { return false; }
    let size1 = mm_size(pred1);
    var nstores: i64 = 0;
    var rbi = block_last(pred0);
    while rbi >= 0 {
        let i = rbi;
        rbi = inst_prev(rbi);
        if iop(i) != OP_STORE || !mm_is_simple(i) { continue; }
        let s0 = i;
        nstores++;
        if nstores * size1 >= 250 { break; }
        let s1 = mm_can_sink_from_block(pred1, s0);
        if s1 >= 0 {
            if !mm_can_sink_stores_and_geps(s0, s1) { break; }
            if sink == tail && pred_count(tail) >= 3 {
                cu_dtu = false;
                sink = cu_split_block_predecessors(tail, [pred0, pred1], ".sink.split");
                if sink < 0 { break; }
            }
            merged = true;
            mm_sink_stores_and_geps(sink, s0, s1);
            rbi = block_last(pred0);
        }
    }
    return merged;
}

fn mldst_motion_run(fv: i32, split_footer: bool) -> u32 {
    tli_cur_fn = fv;
    aa_begin(fv);
    var changed = false;
    var bb = func_first_block(fv);
    while bb >= 0 {
        let nb = block_next(bb);
        if mm_is_diamond_head(bb) { if mm_merge_stores(bb, split_footer) { changed = true; } }
        bb = nb;
    }
    if !changed { return PA_ALL; }
    return if split_footer { PA_NONE } else { PA_CFG };
}
