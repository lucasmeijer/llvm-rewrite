// PHITransAddr: port of llvm/lib/Analysis/PHITransAddr.cpp (canPHITrans, translateSubExpr, translateValue,
// RemoveInstInputs, addAsInput) without the insertion API (translateWithInsertion fails loudly when needed).
// One translator at a time: Addr in pta_addr, InstInputs in pta_inputs. The SimplifyQuery is
// {DL, TLI = nullptr, DT, AC = nullptr} like LLVM's (MemorySSA and MemoryDependence build it that way).
import std;
import ir;
import irutil;
import domtree;
import pm;
import vt;
import constfold;
import instsimplify;

var pta_addr: i32 = -1;
var pta_inputs: i32[>..<];

// PHITransAddr(Addr, DL, AC)
fn pta_init(addr: i32) {
    pta_addr = addr;
    pta_inputs.clear();
    if is_inst(addr) { pta_inputs.push(addr); }
}

fn pta_can_trans(i: i32) -> bool {
    let o = iop(i);
    if o == OP_PHI || o == OP_GEP || is_cast_op(o) { return true; }
    if o == OP_ADD && vals[op(i, 1)].kind == VK_CINT && !ty_is_vector(vals[op(i, 1)].ty) { return true; }
    return false;
}

fn pta_find(i: i32) -> i64 {
    for k in pta_inputs.len { if pta_inputs[k] == i { return k; } }
    return -1;
}
fn pta_erase_at(k: i64) {
    var j = k;
    while j + 1 < pta_inputs.len { pta_inputs[j] = pta_inputs[j + 1]; j++; }
    pta_inputs.pop();
}

fn pta_add_as_input(v: i32) -> i32 {
    if is_inst(v) && pta_find(v) < 0 { pta_inputs.push(v); }
    return v;
}

// RemoveInstInputs
recursive fn pta_remove_inputs(v: i32) {
    if !is_inst(v) { return; }
    let k = pta_find(v);
    if k >= 0 { pta_erase_at(k); return; }
    for j in nops(v) {
        let x = op(v, j);
        if is_inst(x) { pta_remove_inputs(x); }
    }
}

fn pta_phi_incoming(p: i32, b: i32) -> i32 {
    for k in nops(p) { if phi_block(p, k) == b { return op(p, k); } }
    fatal("internal: PHI has no entry for the block");
    return -1;
}

fn pta_simplify_begin() -> bool, bool {
    let a = sq_no_tli;
    let b = sq_no_ac;
    sq_no_tli = true;
    sq_no_ac = true;
    return a, b;
}

// translateSubExpr (no select condition)
recursive fn pta_translate_sub(v: i32, cur: i32, pred: i32) -> i32 {
    if !is_inst(v) { return v; }
    let k = pta_find(v);
    if k >= 0 {
        if inst_parent(v) != cur { return v; }
        pta_erase_at(k);
        if iop(v) == OP_PHI { return pta_add_as_input(pta_phi_incoming(v, pred)); }
        if !pta_can_trans(v) { return -1; }
        for j in nops(v) { pta_add_as_input(op(v, j)); }
    }
    let o = iop(v);
    if is_cast_op(o) {
        let src = op(v, 0);
        let phiin = pta_translate_sub(src, cur, pred);
        if phiin < 0 { return -1; }
        if phiin == src { return v; }
        let a, b = pta_simplify_begin();
        let s = simplify_cast(o, phiin, vals[v].ty, sq_new(-1), RECURSION_LIMIT);
        sq_no_tli = a;
        sq_no_ac = b;
        if s >= 0 {
            pta_remove_inputs(phiin);
            return pta_add_as_input(s);
        }
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
            let t = pta_translate_sub(x, cur, pred);
            if t < 0 { is_ops.resize(mark); return -1; }
            if t != x { changed = true; }
            is_ops.push(t);
        }
        if !changed { is_ops.resize(mark); return v; }
        let a, b = pta_simplify_begin();
        let s = simplify_gep(insts[inst_of(v)].ty2, is_ops[mark], mark + 1, nops(v) - 1, insts[inst_of(v)].flags, sq_new(-1), RECURSION_LIMIT);
        sq_no_tli = a;
        sq_no_ac = b;
        if s >= 0 {
            var j = mark;
            while j < is_ops.len { pta_remove_inputs(is_ops[j]); j++; }
            is_ops.resize(mark);
            return pta_add_as_input(s);
        }
        let base = is_ops[mark];
        if is_constant_data(base) { is_ops.resize(mark); return -1; }
        var u = vals[base].first_use;
        while u >= 0 {
            let g = uses[u].user;
            if is_inst(g) && iop(g) == OP_GEP && vals[g].ty == vals[v].ty && insts[inst_of(g)].ty2 == insts[inst_of(v)].ty2 &&
               nops(g) == nops(v) && inst_func(g) == block_func(cur) && dt_dominates_block(DT_DOM, inst_parent(g), pred) {
                var same = true;
                for j in nops(g) { if op(g, j) != is_ops[mark + j] { same = false; } }
                if same { is_ops.resize(mark); return g; }
            }
            u = uses[u].next;
        }
        is_ops.resize(mark);
        return -1;
    }
    if o == OP_ADD && vals[op(v, 1)].kind == VK_CINT && !ty_is_vector(vals[op(v, 1)].ty) {
        var rhs = op(v, 1);
        var nsw = op_nsw(v);
        var nuw = op_nuw(v);
        var lhs = pta_translate_sub(op(v, 0), cur, pred);
        if lhs < 0 { return -1; }
        if is_inst_op(lhs, OP_ADD) && vals[op(lhs, 1)].kind == VK_CINT && !ty_is_vector(vals[op(lhs, 1)].ty) {
            let bop = lhs;
            lhs = op(bop, 0);
            rhs = ce_binop(OP_ADD, rhs, op(bop, 1), 0);
            nsw = false;
            nuw = false;
            if pta_find(bop) >= 0 {
                pta_remove_inputs(bop);
                pta_add_as_input(lhs);
            }
        }
        let a, b = pta_simplify_begin();
        let s = simplify_add(lhs, rhs, nsw, nuw, sq_new(-1), RECURSION_LIMIT);
        sq_no_tli = a;
        sq_no_ac = b;
        if s >= 0 {
            pta_remove_inputs(lhs);
            return pta_add_as_input(s);
        }
        if lhs == op(v, 0) && rhs == op(v, 1) { return v; }
        if is_constant_data(lhs) { return -1; }
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
fn pta_translate_value(cur: i32, pred: i32, must_dominate: bool) -> i32 {
    if dt_has_node(DT_DOM, pred) { pta_addr = pta_translate_sub(pta_addr, cur, pred); }
    else { pta_addr = -1; }
    if must_dominate && pta_addr >= 0 && is_inst(pta_addr) {
        if !dt_dominates_block(DT_DOM, inst_parent(pta_addr), pred) { pta_addr = -1; }
    }
    return pta_addr;
}
