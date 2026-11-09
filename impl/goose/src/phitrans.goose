// PHITransAddr: port of llvm/lib/Analysis/PHITransAddr.cpp, whole: canPHITrans, isPotentiallyPHITranslatable,
// RemoveInstInputs, translateSubExpr (with the select-condition form), translateValue (both overloads),
// getSelectCondition, translateWithInsertion / insertTranslatedSubExpr, and the header's
// needsPHITranslationFromBlock.
//
// A translator is a record in `ptas` (Addr, the AssumptionCache flag, InstInputs as a run in `pta_pool`).
// Copies (`PHITransAddr Tmp(*this)`) are new records. Records and their runs are released with
// pta_mark()/pta_release(m): MemDep and GVN make translators in nested scopes. A run that grows moves to the end
// of the pool (the old space is dead until the pool is emptied, which happens when the last record is released).
// The SimplifyQuery is {DL, TLI = nullptr, DT, AC}: MemorySSA passes AC = nullptr, MemDep and GVN their AC.
import std;
import ir;
import irutil;
import instinfo;
import domtree;
import pm;
import vt;
import flags;
import constfold;
import instsimplify;

struct PTA { addr: i32, ac: bool, start: i32, len: i32, cap: i32 }
var ptas: PTA[>..<];
var pta_pool: i32[>..<];

fn pta_mark() -> i64 { ptas.len }
fn pta_release(m: i64) {
    ptas.resize(m);
    if m == 0 { pta_pool.clear(); }
}

fn pta_alloc_run(cap: i64) -> i32 {
    let at = pta_pool.len as i32;
    for k in cap { pta_pool.push(-1); }
    return at;
}

// PHITransAddr(Addr, DL, AC)
fn pta_new(addr: i32, ac: bool) -> i32 {
    let t = ptas.len as i32;
    ptas.push(PTA { addr: addr, ac: ac, start: pta_alloc_run(4), len: 0, cap: 4 });
    pta_add_as_input(t, addr);
    return t;
}
// PHITransAddr(const PHITransAddr &)
fn pta_copy(src: i32) -> i32 {
    let t = ptas.len as i32;
    let n = ptas[src].len;
    let cap = if n < 4 { 4 } else { n };
    let st = pta_alloc_run(cap as i64);
    for k in n { pta_pool[st + k] = pta_pool[ptas[src].start + k]; }
    ptas.push(PTA { addr: ptas[src].addr, ac: ptas[src].ac, start: st, len: n, cap: cap });
    return t;
}
// operator= (copy assignment into an existing record)
fn pta_assign(dst: i32, src: i32) {
    let n = ptas[src].len;
    if ptas[dst].cap < n {
        ptas[dst].start = pta_alloc_run(n as i64);
        ptas[dst].cap = n;
    }
    for k in n { pta_pool[ptas[dst].start + k] = pta_pool[ptas[src].start + k]; }
    ptas[dst].len = n;
    ptas[dst].addr = ptas[src].addr;
    ptas[dst].ac = ptas[src].ac;
}

fn pta_get_addr(t: i32) -> i32 { ptas[t].addr }
fn pta_input(t: i32, k: i64) -> i32 { pta_pool[ptas[t].start as i64 + k] }

fn pta_find(t: i32, i: i32) -> i64 {
    let st = ptas[t].start as i64;
    for k in ptas[t].len { if pta_pool[st + k] == i { return k; } }
    return -1;
}
fn pta_erase_at(t: i32, k: i64) {
    let st = ptas[t].start as i64;
    var j = k;
    while j + 1 < ptas[t].len { pta_pool[st + j] = pta_pool[st + j + 1]; j++; }
    ptas[t].len--;
}
fn pta_push(t: i32, i: i32) {
    if ptas[t].len == ptas[t].cap {
        let ncap = ptas[t].cap * 2;
        let st = pta_alloc_run(ncap as i64);
        for k in ptas[t].len { pta_pool[st + k] = pta_pool[ptas[t].start + k]; }
        ptas[t].start = st;
        ptas[t].cap = ncap;
    }
    pta_pool[ptas[t].start + ptas[t].len] = i;
    ptas[t].len++;
}

// addAsInput
fn pta_add_as_input(t: i32, v: i32) -> i32 {
    if v >= 0 && is_inst(v) && pta_find(t, v) < 0 { pta_push(t, v); }
    return v;
}

// isa<ConstantInt> (splat ConstantInts: -use-constant-int-for-fixed-length-splat fails loudly in flags.goose)
fn pta_is_cint(v: i32) -> bool { is_cint(v) && !ty_is_vector(vals[v].ty) }

fn pta_can_trans(i: i32) -> bool {
    let o = iop(i);
    if o == OP_PHI || o == OP_GEP || is_cast_op(o) { return true; }
    if o == OP_ADD && pta_is_cint(op(i, 1)) { return true; }
    return false;
}

// needsPHITranslationFromBlock
fn pta_needs_translation_from_block(t: i32, bb: i32) -> bool {
    for k in ptas[t].len { if inst_parent(pta_input(t, k)) == bb { return true; } }
    return false;
}

// isPotentiallyPHITranslatable
fn pta_is_potentially_translatable(t: i32) -> bool {
    let a = ptas[t].addr;
    return a < 0 || !is_inst(a) || pta_can_trans(a);
}

// RemoveInstInputs
recursive fn pta_remove_inputs(t: i32, v: i32) {
    if !is_inst(v) { return; }
    let k = pta_find(t, v);
    if k >= 0 { pta_erase_at(t, k); return; }
    for j in nops(v) {
        let x = op(v, j);
        if is_inst(x) { pta_remove_inputs(t, x); }
    }
}

fn pta_phi_incoming(p: i32, b: i32) -> i32 {
    for k in nops(p) { if phi_block(p, k) == b { return op(p, k); } }
    fatal("internal: PHI has no entry for the block");
    return -1;
}

fn pta_simplify_begin(t: i32) -> bool, bool {
    let a = sq_no_tli;
    let b = sq_no_ac;
    sq_no_tli = true;
    sq_no_ac = !ptas[t].ac;
    return a, b;
}

// translateSubExpr(V, CurBB, PredBB, DT, Cond, CondVal); cond -1 = no select condition
recursive fn pta_translate_sub(t: i32, v: i32, cur: i32, pred: i32, cond: i32, cond_val: bool) -> i32 {
    if v < 0 || !is_inst(v) { return v; }
    let k = pta_find(t, v);
    if k >= 0 {
        if inst_parent(v) != cur { return v; }
        pta_erase_at(t, k);
        if iop(v) == OP_PHI {
            let inc = pta_phi_incoming(v, pred);
            if cond >= 0 && is_inst_op(inc, OP_SELECT) && op(inc, 0) == cond {
                return pta_add_as_input(t, if cond_val { op(inc, 1) } else { op(inc, 2) });
            }
            return pta_add_as_input(t, inc);
        }
        if !pta_can_trans(v) { return -1; }
        for j in nops(v) { pta_add_as_input(t, op(v, j)); }
    }
    let o = iop(v);
    if is_cast_op(o) {
        let src = op(v, 0);
        let phiin = pta_translate_sub(t, src, cur, pred, cond, cond_val);
        if phiin < 0 { return -1; }
        if phiin == src { return v; }
        let a, b = pta_simplify_begin(t);
        let s = simplify_cast(o, phiin, vals[v].ty, sq_new(-1), RECURSION_LIMIT);
        sq_no_tli = a;
        sq_no_ac = b;
        if s >= 0 {
            pta_remove_inputs(t, phiin);
            return pta_add_as_input(t, s);
        }
        if !has_use_list(phiin) { return -1; }
        var u = vals[phiin].first_use;
        while u >= 0 {
            let x = uses[u].user;
            if is_inst(x) && iop(x) == o && vals[x].ty == vals[v].ty && dt_dominates_block(DT_DOM, inst_parent(x), pred) { return x; }
            u = uses[u].next;
        }
        return -1;
    }
    if o == OP_GEP {
        let mark = is_ops.len;
        var changed = false;
        for j in nops(v) {
            let x = op(v, j);
            let tx = pta_translate_sub(t, x, cur, pred, cond, cond_val);
            if tx < 0 { is_ops.resize(mark); return -1; }
            if tx != x { changed = true; }
            is_ops.push(tx);
        }
        if !changed { is_ops.resize(mark); return v; }
        let a, b = pta_simplify_begin(t);
        let s = simplify_gep(insts[inst_of(v)].ty2, is_ops[mark], mark + 1, nops(v) - 1, insts[inst_of(v)].flags, sq_new(-1), RECURSION_LIMIT);
        sq_no_tli = a;
        sq_no_ac = b;
        if s >= 0 {
            var j = mark;
            while j < is_ops.len { pta_remove_inputs(t, is_ops[j]); j++; }
            is_ops.resize(mark);
            return pta_add_as_input(t, s);
        }
        let base = is_ops[mark];
        if is_constant_data(base) { is_ops.resize(mark); return -1; }
        let curf = block_func(cur);
        let vty = vals[v].ty;
        let vty2 = insts[inst_of(v)].ty2;
        let vn = nops(v);
        var u = vals[base].first_use;
        while u >= 0 {
            let g = uses[u].user;
            if is_inst(g) && iop(g) == OP_GEP && vals[g].ty == vty && insts[inst_of(g)].ty2 == vty2 &&
               nops(g) == vn && inst_func(g) == curf && dt_dominates_block(DT_DOM, inst_parent(g), pred) {
                var same = true;
                for j in nops(g) { if op(g, j) != is_ops[mark + j] { same = false; } }
                if same { is_ops.resize(mark); return g; }
            }
            u = uses[u].next;
        }
        is_ops.resize(mark);
        return -1;
    }
    if o == OP_ADD && pta_is_cint(op(v, 1)) {
        var rhs = op(v, 1);
        var nsw = op_nsw(v);
        var nuw = op_nuw(v);
        var lhs = pta_translate_sub(t, op(v, 0), cur, pred, cond, cond_val);
        if lhs < 0 { return -1; }
        if is_inst_op(lhs, OP_ADD) && pta_is_cint(op(lhs, 1)) {
            let bop = lhs;
            lhs = op(bop, 0);
            rhs = ce_binop(OP_ADD, rhs, op(bop, 1), 0);
            nsw = false;
            nuw = false;
            if pta_find(t, bop) >= 0 {
                pta_remove_inputs(t, bop);
                pta_add_as_input(t, lhs);
            }
        }
        let a, b = pta_simplify_begin(t);
        let s = simplify_add(lhs, rhs, nsw, nuw, sq_new(-1), RECURSION_LIMIT);
        sq_no_tli = a;
        sq_no_ac = b;
        if s >= 0 {
            pta_remove_inputs(t, lhs);
            return pta_add_as_input(t, s);
        }
        if lhs == op(v, 0) && rhs == op(v, 1) { return v; }
        if !has_use_list(lhs) { return -1; }
        var u = vals[lhs].first_use;
        while u >= 0 {
            let x = uses[u].user;
            if is_inst_op(x, OP_ADD) && op(x, 0) == lhs && op(x, 1) == rhs && inst_func(x) == block_func(cur) &&
               dt_dominates_block(DT_DOM, inst_parent(x), pred) { return x; }
            u = uses[u].next;
        }
        return -1;
    }
    return -1;
}

// translateValue(CurBB, PredBB, DT, MustDominate)
fn pta_translate_value(t: i32, cur: i32, pred: i32, must_dominate: bool) -> i32 {
    var a: i32 = -1;
    if dt_has_node(DT_DOM, pred) { a = pta_translate_sub(t, ptas[t].addr, cur, pred, -1, false); }
    ptas[t].addr = a;
    if must_dominate && a >= 0 && is_inst(a) {
        if !dt_dominates_block(DT_DOM, inst_parent(a), pred) { ptas[t].addr = -1; }
    }
    return ptas[t].addr;
}

// translateValue(CurBB, PredBB, DT, Cond): the (true, false) addresses; (-1, -1) when the pred is unreachable
fn pta_translate_select(t: i32, cur: i32, pred: i32, cond: i32) -> i32, i32 {
    if !dt_has_node(DT_DOM, pred) { return -1, -1; }
    let m = pta_mark();
    let t1 = pta_copy(t);
    let a = pta_translate_sub(t1, ptas[t1].addr, cur, pred, cond, true);
    let t2 = pta_copy(t);
    let b = pta_translate_sub(t2, ptas[t2].addr, cur, pred, cond, false);
    pta_release(m);
    return a, b;
}

// getSelectCondition
fn pta_get_select_condition(t: i32) -> i32 {
    for k in ptas[t].len {
        let i = pta_input(t, k);
        if iop(i) == OP_SELECT { return op(i, 0); }
    }
    return -1;
}

// translateWithInsertion(CurBB, PredBB, DT, NewInsts)
fn pta_translate_with_insertion(t: i32, cur: i32, pred: i32, newinsts: i32[>..<]&) -> i32 {
    let nisize = newinsts.len;
    let a0 = ptas[t].addr;
    let a = pta_insert_translated(t, a0, cur, pred, newinsts);
    ptas[t].addr = a;
    if a >= 0 { return a; }
    while newinsts.len != nisize { inst_erase_from_parent(newinsts.pop()); }
    return -1;
}

fn pta_insert_name(src: i32, out: u8[>..]&) {
    out.clear();
    out.append(val_name(src));
    out.append(".phi.trans.insert");
}

// insertTranslatedSubExpr
recursive fn pta_insert_translated(t: i32, inval: i32, cur: i32, pred: i32, newinsts: i32[>..<]&) -> i32 {
    let m = pta_mark();
    let tmp = pta_new(inval, ptas[t].ac);
    let addr = pta_translate_value(tmp, cur, pred, true);
    pta_release(m);
    if addr >= 0 { return addr; }
    if !is_inst(inval) { return -1; }
    let o = iop(inval);
    let pt = block_terminator(pred);
    if is_cast_op(o) {
        let opv = pta_insert_translated(t, op(inval, 0), cur, pred, newinsts);
        if opv < 0 { return -1; }
        let nw = create_inst(o, vals[inval].ty, [opv]);
        inst_insert_before(nw, pt);
        var nm: u8[>..] = [];
        pta_insert_name(inval, nm);
        set_name(nw, nm);
        pta_copy_dbg_loc(nw, inval);
        newinsts.push(nw);
        return nw;
    }
    if o == OP_GEP {
        let gcur = inst_parent(inval);
        let n = nops(inval);
        // GEPOps live in the instruction itself: create it with the original operands and replace them
        let mark = pta_gep_ops.len;
        for j in n {
            let opv = pta_insert_translated(t, op(inval, j), gcur, pred, newinsts);
            if opv < 0 { pta_gep_ops.resize(mark); return -1; }
            pta_gep_ops.push(opv);
        }
        let nw = new_inst(OP_GEP, vals[inval].ty, n);
        for j in n { set_op(nw, j, pta_gep_ops[mark + j]); }
        pta_gep_ops.resize(mark);
        insts[inst_of(nw)].ty2 = insts[inst_of(inval)].ty2;
        inst_insert_before(nw, pt);
        var nm: u8[>..] = [];
        pta_insert_name(inval, nm);
        set_name(nw, nm);
        pta_copy_dbg_loc(nw, inval);
        insts[inst_of(nw)].flags = insts[inst_of(inval)].flags;
        newinsts.push(nw);
        return nw;
    }
    if flag_bool("gvn-add-phi-translation", false) && o == OP_ADD && pta_is_cint(op(inval, 1)) {
        let opv = pta_insert_translated(t, op(inval, 0), cur, pred, newinsts);
        if opv < 0 { return -1; }
        let nw = create_inst(OP_ADD, vals[inval].ty, [opv, op(inval, 1)]);
        inst_insert_before(nw, pt);
        var nm: u8[>..] = [];
        pta_insert_name(inval, nm);
        set_name(nw, nm);
        var fl: u8 = 0;
        if op_nsw(inval) { fl = fl | FL_NSW; }
        if op_nuw(inval) { fl = fl | FL_NUW; }
        insts[inst_of(nw)].flags = fl;
        newinsts.push(nw);
        return nw;
    }
    return -1;
}
var pta_gep_ops: i32[>..<];

fn pta_copy_dbg_loc(dst: i32, src: i32) {
    let d = inst_get_md(src, 0);
    if d >= 0 { inst_set_md(dst, 0, d); } else { inst_erase_md(dst, 0); }
}
