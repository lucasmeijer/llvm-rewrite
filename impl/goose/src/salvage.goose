// salvageDebugInfo: port of llvm/lib/Transforms/Utils/Local.cpp (salvageDebugInfo,
// salvageDebugInfoForDbgValues, salvageDebugInfoImpl, getSalvageOpsForGEP/BinOp/IcmpOp), the DIExpression
// helpers it uses (llvm/lib/IR/DebugInfoMetadata.cpp: appendOffset, appendOpsToArg, prependOpcodes,
// getNumLocationOperands, getExtOps), DIExpression::foldConstantMath (llvm/lib/IR/DIExpressionOptimizer.cpp),
// GEPOperator::collectOffset (llvm/lib/IR/Operator.cpp) and the DbgVariableRecord location setters
// (replaceVariableLocationOp, addVariableLocationOps, setKillLocation).
//
// Debug users come from the central metadata tracking (dinfo.goose find_dbg_users). dbg_assign address
// salvaging is not ported (fails loudly).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import datalayout;
import dinfo;
import mem2reg;
import pm;
import vt;
import intrinsics;
import instsimplify;

let SV_OP_CONSTU: i64 = 0x10;
let SV_OP_CONSTS: i64 = 0x11;
let SV_OP_AND: i64 = 0x1a;
let SV_OP_DIV: i64 = 0x1b;
let SV_OP_MINUS: i64 = 0x1c;
let SV_OP_MOD: i64 = 0x1d;
let SV_OP_MUL: i64 = 0x1e;
let SV_OP_OR: i64 = 0x21;
let SV_OP_PLUS: i64 = 0x22;
let SV_OP_PLUS_UCONST: i64 = 0x23;
let SV_OP_SHL: i64 = 0x24;
let SV_OP_SHR: i64 = 0x25;
let SV_OP_SHRA: i64 = 0x26;
let SV_OP_XOR: i64 = 0x27;
let SV_OP_EQ: i64 = 0x29;
let SV_OP_GE: i64 = 0x2a;
let SV_OP_GT: i64 = 0x2b;
let SV_OP_LE: i64 = 0x2c;
let SV_OP_LT: i64 = 0x2d;
let SV_OP_NE: i64 = 0x2e;
let SV_OP_LIT0: i64 = 0x30;
let SV_OP_LIT31: i64 = 0x4f;
let SV_OP_STACK_VALUE: i64 = 0x9f;
let SV_OP_LLVM_FRAGMENT: i64 = 0x1000;
let SV_OP_LLVM_CONVERT: i64 = 0x1001;
let SV_OP_LLVM_ARG: i64 = 0x1005;
let SV_ATE_SIGNED: i64 = 5;
let SV_ATE_UNSIGNED: i64 = 7;     // DW_ATE_unsigned (Dwarf.def 0x07)

let SV_MAX_DEBUG_ARGS: i64 = 16;
let SV_MAX_EXPRESSION_SIZE: i64 = 128;

// ---------------------------------------------------------------------------------------------
// DIExpression helpers (an expression is an MK_DIEXPR node whose operands are md_int elements)

fn sv_expr_get(ops: const i64[:]) -> i32 {
    var els: i32[>..<] = [];
    for x in ops { els.push(md_int(x)); }
    return md_get(MK_DIEXPR, -1, els, false);
}
fn sv_expr_elems(e: i32, out: i64[>..<]&) {
    for k in diexpr_nelems(e) { out.push(diexpr_elem(e, k)); }
}
fn sv_op_size(ops: const i64[:], at: i64) -> i64 { diexpr_op_size(ops[at]) }

fn sv_expr_is_variadic(ops: const i64[:]) -> bool {
    var at: i64 = 0;
    while at < ops.len {
        if ops[at] == SV_OP_LLVM_ARG { return true; }
        at += sv_op_size(ops, at);
    }
    return false;
}
// DIExpression::getNumLocationOperands
fn sv_num_location_operands(e: i32) -> i64 {
    var ops: i64[>..<] = [];
    sv_expr_elems(e, ops);
    var r: i64 = 0;
    var at: i64 = 0;
    while at < ops.len {
        if ops[at] == SV_OP_LLVM_ARG && at + 1 < ops.len { r = max(r, ops[at + 1] + 1); }
        at += sv_op_size(ops, at);
    }
    return r;
}
// DIExpression::appendOffset
fn sv_append_offset(ops: i64[>..<]&, off: i64) {
    if off > 0 { ops.push(SV_OP_PLUS_UCONST); ops.push(off); }
    else if off < 0 {
        ops.push(SV_OP_CONSTU);
        let abs_minus_one = (-(off + 1)) as! u64;
        ops.push((abs_minus_one + 1) as! i64);
        ops.push(SV_OP_MINUS);
    }
}
// DIExpression::appendOpsToArg (non-variadic: prependOpcodes)
fn sv_append_ops_to_arg(e: i32, add: const i64[:], argno: i64, stack_value0: bool) -> i32 {
    var cur: i64[>..<] = [];
    sv_expr_elems(e, cur);
    var stack_value = stack_value0;
    var out: i64[>..<] = [];
    if !sv_expr_is_variadic(cur) {
        // prependOpcodes(Expr, Ops, StackValue)
        for x in add { out.push(x); }
        if add.len == 0 { stack_value = false; }
    }
    let variadic = sv_expr_is_variadic(cur);
    var at: i64 = 0;
    while at < cur.len {
        let o = cur[at];
        let sz = sv_op_size(cur, at);
        if stack_value {
            if o == SV_OP_STACK_VALUE { stack_value = false; }
            else if o == SV_OP_LLVM_FRAGMENT { out.push(SV_OP_STACK_VALUE); stack_value = false; }
        }
        for j in sz { if at + j < cur.len { out.push(cur[at + j]); } }
        if variadic && o == SV_OP_LLVM_ARG && at + 1 < cur.len && cur[at + 1] == argno {
            for x in add { out.push(x); }
        }
        at += sz;
    }
    if stack_value { out.push(SV_OP_STACK_VALUE); }
    return sv_expr_get(out);
}

// ---------------------------------------------------------------------------------------------
// DIExpression::foldConstantMath

// the element index of the op n ops after `at`, -1 if there is none (DIExpressionCursor::peekNextN)
fn sv_nth_op(ops: const i64[:], at: i64, n: i64) -> i64 {
    if at >= ops.len { return -1; }
    var p = at;
    for i in n {
        p += sv_op_size(ops, p);
        if p >= ops.len { return -1; }
    }
    return p;
}
fn sv_is_const(ops: const i64[:], at: i64) -> bool { ops[at] == SV_OP_CONSTU }
fn sv_arg(ops: const i64[:], at: i64) -> u64 { if at + 1 < ops.len { ops[at + 1] as! u64 } else { 0 } }

fn sv_is_neutral(o: i64, v: u64) -> bool {
    if o == SV_OP_PLUS || o == SV_OP_MINUS || o == SV_OP_SHL || o == SV_OP_SHR { return v == 0; }
    if o == SV_OP_MUL || o == SV_OP_DIV { return v == 1; }
    return false;
}
fn sv_clz(x: u64) -> u64 { var n: u64 = 0; var b: u64 = 0x8000000000000000; while n < 64 && (x & b) == 0 { n++; b = b >> 1; } return n; }
fn sv_ctz(x: u64) -> u64 { var n: u64 = 0; var b: u64 = 1; while n < 64 && (x & b) == 0 { n++; b = b << 1; } return n; }
// foldOperationIfPossible: (ok, result)
fn sv_fold_op(c1: u64, c2: u64, o: i64) -> bool, u64 {
    if o == SV_OP_PLUS { let r = c1 + c2; if r < c1 { return false, 0; } return true, r; }
    if o == SV_OP_MINUS { if c1 < c2 { return false, 0; } return true, c1 - c2; }
    if o == SV_OP_SHL { if c2 >= 64 || sv_clz(c1) < c2 { return false, 0; } return true, c1 << c2; }
    if o == SV_OP_SHR { if c2 >= 64 || sv_ctz(c1) < c2 { return false, 0; } return true, c1 >> c2; }
    if o == SV_OP_MUL {
        if c1 == 0 || c2 == 0 { return true, 0; }
        let r = c1 * c2;
        if r / c2 != c1 { return false, 0; }
        return true, r;
    }
    if o == SV_OP_DIV { if c2 != 0 { return true, c1 / c2; } return false, 0; }
    return false, 0;
}
fn sv_foldable_commutative(a: i64, b: i64) -> bool { a == b && (a == SV_OP_PLUS || a == SV_OP_MUL) }

// erase ops[from..to)
fn sv_erase(ops: i64[>..<]&, from: i64, to: i64) {
    let n = to - from;
    for i in from..ops.len - n { ops[i] = ops[i + n]; }
    ops.resize(ops.len - n);
}

fn sv_fold_constant_math(e: i32) -> i32 {
    var w: i64[>..<] = [];
    sv_expr_elems(e, w);
    // canonicalizeDwarfOperations
    var r: i64[>..<] = [];
    var at: i64 = 0;
    while at < w.len {
        let o = w[at];
        let sz = sv_op_size(w, at);
        if o >= SV_OP_LIT0 && o <= SV_OP_LIT31 { r.push(SV_OP_CONSTU); r.push(o - SV_OP_LIT0); at += sz; continue; }
        if o == SV_OP_PLUS_UCONST { r.push(SV_OP_CONSTU); r.push(sv_arg(w, at) as! i64); r.push(SV_OP_PLUS); at += sz; continue; }
        for j in sz { if at + j < w.len { r.push(w[at + j]); } }
        at += sz;
    }
    var loc: i64 = 0;
    while loc < r.len {
        let p0 = loc;
        if !sv_is_const(r, p0) { loc += sv_op_size(r, p0); continue; }
        let c1 = sv_arg(r, p0);
        let p1 = sv_nth_op(r, loc, 1);
        if p1 < 0 { break; }
        // tryFoldNoOpMath
        if sv_is_neutral(r[p1], c1) { sv_erase(r, loc, loc + 3); loc = 0; continue; }
        let p2 = sv_nth_op(r, loc, 2);
        if p2 < 0 { loc += sv_op_size(r, p0); continue; }
        // tryFoldConstants
        if sv_is_const(r, p1) {
            let ok, res = sv_fold_op(c1, sv_arg(r, p1), r[p2]);
            if !ok { loc += sv_op_size(r, p0); continue; }
            sv_erase(r, loc + 2, loc + 5);
            r[loc] = SV_OP_CONSTU;
            r[loc + 1] = res as! i64;
            loc = 0;
            continue;
        }
        let p3 = sv_nth_op(r, loc, 3);
        if p3 < 0 { loc += sv_op_size(r, p0); continue; }
        // tryFoldCommutativeMath
        if sv_is_const(r, p2) && sv_foldable_commutative(r[p1], r[p3]) {
            let ok, res = sv_fold_op(c1, sv_arg(r, p2), r[p1]);
            if !ok { loc += sv_op_size(r, p0); continue; }
            sv_erase(r, loc + 3, loc + 6);
            r[loc] = SV_OP_CONSTU;
            r[loc + 1] = res as! i64;
            loc = 0;
            continue;
        }
        let p4 = sv_nth_op(r, loc, 4);
        if p4 < 0 { loc += sv_op_size(r, p0); continue; }
        let p5 = sv_nth_op(r, loc, 5);
        if p5 < 0 { loc += sv_op_size(r, p0); continue; }
        // tryFoldCommutativeMathWithArgInBetween
        if sv_is_const(r, p4) && r[p2] == SV_OP_LLVM_ARG && sv_foldable_commutative(r[p1], r[p3]) &&
           sv_foldable_commutative(r[p3], r[p5]) {
            let ok, res = sv_fold_op(c1, sv_arg(r, p4), r[p1]);
            if !ok { loc += sv_op_size(r, p0); continue; }
            sv_erase(r, loc + 6, loc + 9);
            r[loc] = SV_OP_CONSTU;
            r[loc + 1] = res as! i64;
            loc = 0;
            continue;
        }
        loc += sv_op_size(r, p0);
    }
    // optimizeDwarfOperations
    var out: i64[>..<] = [];
    at = 0;
    while at < r.len {
        let o = r[at];
        let sz = sv_op_size(r, at);
        if o == SV_OP_CONSTU && sv_arg(r, at) == 0 { out.push(SV_OP_LIT0); at += sz; continue; }
        let nx = at + sz;
        if nx >= r.len {
            for j in sz { if at + j < r.len { out.push(r[at + j]); } }
            break;
        }
        if o == SV_OP_CONSTU && r[nx] == SV_OP_PLUS {
            out.push(SV_OP_PLUS_UCONST);
            out.push(sv_arg(r, at) as! i64);
            at = nx + sv_op_size(r, nx);
            continue;
        }
        for j in sz { if at + j < r.len { out.push(r[at + j]); } }
        at += sz;
    }
    return sv_expr_get(out);
}

// ---------------------------------------------------------------------------------------------
// salvageDebugInfoImpl

// DL.getIntPtrType(T)'s scalar size for a pointer type, else the scalar size
fn sv_int_size(t: i32) -> i64 {
    let s = ty_scalar(t);
    if types[s].kind == TK_PTR { return dl_ptr(types[s].n as i64).bits; }
    return ty_scalar_bits(t);
}

// CastInst::isNoopCast(DL)
fn sv_is_noop_cast(i: i32) -> bool {
    let o = iop(i);
    if o == OP_BITCAST { return true; }
    let st = vals[op(i, 0)].ty;
    let dt = vals[i].ty;
    if o == OP_PTRTOINT { return dl_ptr(types[ty_scalar(st)].n as i64).bits == ty_scalar_bits(dt); }
    if o == OP_PTRTOADDR { return dl_ptr(types[ty_scalar(st)].n as i64).bits == ty_scalar_bits(dt); }
    if o == OP_INTTOPTR { return dl_ptr(types[ty_scalar(dt)].n as i64).bits == ty_scalar_bits(st); }
    return false;
}

fn sv_dwarf_binop(o: i64) -> i64 {
    if o == OP_ADD { return SV_OP_PLUS; }
    if o == OP_SUB { return SV_OP_MINUS; }
    if o == OP_MUL { return SV_OP_MUL; }
    if o == OP_SDIV { return SV_OP_DIV; }
    if o == OP_SREM { return SV_OP_MOD; }
    if o == OP_OR { return SV_OP_OR; }
    if o == OP_AND { return SV_OP_AND; }
    if o == OP_XOR { return SV_OP_XOR; }
    if o == OP_SHL { return SV_OP_SHL; }
    if o == OP_LSHR { return SV_OP_SHR; }
    if o == OP_ASHR { return SV_OP_SHRA; }
    return 0;
}
fn sv_dwarf_icmp(p: i64) -> i64 {
    if p == 32 { return SV_OP_EQ; }
    if p == 33 { return SV_OP_NE; }
    if p == 34 || p == 38 { return SV_OP_GT; }
    if p == 35 || p == 39 { return SV_OP_GE; }
    if p == 36 || p == 40 { return SV_OP_LT; }
    if p == 37 || p == 41 { return SV_OP_LE; }
    return 0;
}

// handleSSAValueOperands
fn sv_ssa_operands(cur0: i64, ops: i64[>..<]&, addl: i32[>..<]&, i: i32) {
    var cur = cur0;
    if cur == 0 { ops.push(SV_OP_LLVM_ARG); ops.push(0); cur = 1; }
    ops.push(SV_OP_LLVM_ARG);
    ops.push(cur);
    addl.push(op(i, 1));
}

// getSalvageOpsForGEP (+ GEPOperator::collectOffset)
fn sv_gep_ops(g: i32, cur0: i64, ops: i64[>..<]&, addl: i32[>..<]&) -> i32 {
    let w = dl_ptr(ptr_as(vals[g].ty)).idx;
    if w > 64 { fatal("salvageDebugInfo: GEP index widths over 64 bits are not ported yet"); }
    let mask: u64 = if w == 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << (w as u64)) - 1 };
    var coff: u64 = 0;
    var vvals: i32[>..<] = [];     // SmallMapVector<Value *, APInt>
    var vmul: u64[>..<] = [];
    let src = insts[inst_of(g)].ty2;
    var t = src;
    for k in 1..nops(g) {
        let x = op(g, k);
        var indexed = t;
        var stride: i64 = 0;
        var is_struct = false;
        if k == 1 { indexed = src; stride = dl_alloc_size(src); }
        else if ty_is_struct(t) { is_struct = true; }
        else { indexed = types[t].a; stride = dl_gep_stride(t, indexed); }
        let is_ci = vals[x].kind == VK_CINT && ty_kind(vals[x].ty) == TK_INT;
        if is_struct {
            if !is_ci { return -1; }
            let fi = cint_lo(x) as! i64;
            indexed = ty_field(t, fi);
            if !cint_is_zero(x) {
                if ty_contains_scalable(indexed) { return -1; }
                coff = (coff + (dl_struct_offset(t, fi) as! u64)) & mask;
            }
            t = indexed;
            continue;
        }
        let scalable = ty_contains_scalable(indexed);
        if is_ci {
            if ty_bits(vals[x].ty) > 64 { fatal("salvageDebugInfo: GEP indices wider than 64 bits are not ported yet"); }
            if !cint_is_zero(x) {
                if scalable { return -1; }
                coff = (coff + ((ci_sval(x) as! u64) & mask) * ((stride as! u64) & mask)) & mask;
            }
            t = indexed;
            continue;
        }
        if scalable { return -1; }
        let sz = (stride as! u64) & mask;
        if sz != 0 {
            var found: i64 = -1;
            for j in vvals.len { if vvals[j] == x { found = j; } }
            if found < 0 { vvals.push(x); vmul.push(0); found = vvals.len - 1; }
            vmul[found] = (vmul[found] + sz) & mask;
        }
        t = indexed;
    }
    var cur = cur0;
    if vvals.len > 0 && cur == 0 {
        // Opcodes.insert(begin, {DW_OP_LLVM_arg, 0})
        var tmp: i64[>..<] = [];
        for x in ops { tmp.push(x); }
        ops.clear();
        ops.push(SV_OP_LLVM_ARG);
        ops.push(0);
        for x in tmp { ops.push(x); }
        cur = 1;
    }
    for j in vvals.len {
        addl.push(vvals[j]);
        ops.push(SV_OP_LLVM_ARG);
        ops.push(cur);
        cur++;
        ops.push(SV_OP_CONSTU);
        ops.push(vmul[j] as! i64);
        ops.push(SV_OP_MUL);
        ops.push(SV_OP_PLUS);
    }
    sv_append_offset(ops, sext64(coff, w));
    return op(g, 0);
}

fn sv_binop_ops(i: i32, cur: i64, ops: i64[>..<]&, addl: i32[>..<]&) -> i32 {
    let c = op(i, 1);
    let is_ci = vals[c].kind == VK_CINT && !ty_is_vector(vals[c].ty);
    if is_ci && ty_bits(vals[c].ty) > 64 { return -1; }
    let o = iop(i);
    if is_ci {
        let v = ci_sval(c);
        if o == OP_ADD || o == OP_SUB {
            let off = if o == OP_ADD { v } else { ((0 as u64) - (v as! u64)) as! i64 };
            sv_append_offset(ops, off);
            return op(i, 0);
        }
        ops.push(SV_OP_CONSTU);
        ops.push(v);
    } else {
        sv_ssa_operands(cur, ops, addl, i);
    }
    let d = sv_dwarf_binop(o);
    if d == 0 { return -1; }
    ops.push(d);
    return op(i, 0);
}

fn sv_icmp_ops(i: i32, cur: i64, ops: i64[>..<]&, addl: i32[>..<]&) -> i32 {
    let c = op(i, 1);
    let is_ci = vals[c].kind == VK_CINT && !ty_is_vector(vals[c].ty);
    if is_ci && ty_bits(vals[c].ty) > 64 { return -1; }
    let p = inst_pred(i);
    if is_ci {
        let signed = p >= 38 && p <= 41;
        ops.push(if signed { SV_OP_CONSTS } else { SV_OP_CONSTU });
        ops.push(ci_sval(c));
    } else {
        sv_ssa_operands(cur, ops, addl, i);
    }
    let d = sv_dwarf_icmp(p);
    if d == 0 { return -1; }
    ops.push(d);
    return op(i, 0);
}

// salvageDebugInfoImpl(I, CurrentLocOps, Ops, AdditionalValues): the new location value, -1 if none
fn sv_salvage_impl(i: i32, cur: i64, ops: i64[>..<]&, addl: i32[>..<]&) -> i32 {
    let o = iop(i);
    if is_cast_op(o) {
        let from = op(i, 0);
        if sv_is_noop_cast(i) { return from; }
        let t = vals[i].ty;
        if ty_is_vector(t) || !(o == OP_TRUNC || o == OP_SEXT || o == OP_ZEXT || o == OP_INTTOPTR || o == OP_PTRTOINT) { return -1; }
        let fs = sv_int_size(vals[from].ty);
        let ts = sv_int_size(t);
        let tk = if o == OP_SEXT { SV_ATE_SIGNED } else { SV_ATE_UNSIGNED };
        ops.push(SV_OP_LLVM_CONVERT); ops.push(fs); ops.push(tk);
        ops.push(SV_OP_LLVM_CONVERT); ops.push(ts); ops.push(tk);
        return from;
    }
    if o == OP_GEP { return sv_gep_ops(i, cur, ops, addl); }
    if is_binary_op(o) { return sv_binop_ops(i, cur, ops, addl); }
    if o == OP_ICMP { return sv_icmp_ops(i, cur, ops, addl); }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// DbgVariableRecord location helpers

// location_ops()
fn sv_location_ops(r: i32, out: i32[>..<]&) {
    let l = dbgrecs[r].loc;
    if l < 0 { return; }
    if mds[l].kind == MK_VALUE { out.push(mds[l].extra); return; }
    if mds[l].kind == MK_DIARGLIST {
        for k in mds[l].nops { let o = md_op(l, k); if o >= 0 && mds[o].kind == MK_VALUE { out.push(mds[o].extra); } }
    }
}
// replaceVariableLocationOp(Old, New)
fn sv_replace_location_op(r: i32, old: i32, nw: i32) {
    dbg_set_loc(r, m2r_md_replace_value(dbgrecs[r].loc, old, nw));
}
// setKillLocation
fn sv_set_kill_location(r: i32) {
    var ls: i32[>..<] = [];
    sv_location_ops(r, ls);
    var done: i32[>..<] = [];
    for v in ls {
        var seen = false;
        for d in done { if d == v { seen = true; } }
        if seen { continue; }
        done.push(v);
        dbg_set_loc(r, m2r_md_replace_value(dbgrecs[r].loc, v, c_poison(vals[v].ty)));
    }
}
// addVariableLocationOps(NewValues, NewExpr)
fn sv_add_location_ops(r: i32, addl: const i32[:], e: i32) {
    var ls: i32[>..<] = [];
    sv_location_ops(r, ls);
    var mdsv: i32[>..<] = [];
    for v in ls { mdsv.push(md_value(v)); }
    for v in addl { mdsv.push(md_value(v)); }
    dbgrecs[r].expr = e;
    dbg_set_loc(r, md_get(MK_DIARGLIST, -1, mdsv, false));
}

// salvageDebugInfoForDbgValues(I, DPUsers)
fn salvage_debug_info_for(i: i32, users: const i32[:]) {
    var salvaged = false;
    for r in users {
        let kind = dbgrecs[r].kind as i64;
        if kind == DR_ASSIGN { fatal("salvageDebugInfo: dbg_assign records are not ported yet"); }
        let stack_value = kind != DR_DECLARE;
        var ls: i32[>..<] = [];
        sv_location_ops(r, ls);
        var addl: i32[>..<] = [];
        var op0: i32 = -1;
        var e = dbgrecs[r].expr;
        var li: i64 = 0;
        while li < ls.len && ls[li] != i { li++; }
        while e >= 0 && li < ls.len {
            var ops: i64[>..<] = [];
            let cur = sv_num_location_operands(e);
            op0 = sv_salvage_impl(i, cur, ops, addl);
            if op0 < 0 { break; }
            e = sv_append_ops_to_arg(e, ops, li, stack_value);
            li++;
            while li < ls.len && ls[li] != i { li++; }
        }
        if op0 < 0 { break; }
        e = sv_fold_constant_math(e);
        sv_replace_location_op(r, i, op0);
        let valid = diexpr_nelems(e) <= SV_MAX_EXPRESSION_SIZE;
        if addl.len == 0 && valid {
            dbgrecs[r].expr = e;
        } else if kind != DR_DECLARE && valid && (ls.len as i64) + addl.len <= SV_MAX_DEBUG_ARGS {
            sv_add_location_ops(r, addl, e);
        } else {
            sv_set_kill_location(r);
        }
        salvaged = true;
    }
    if salvaged { return; }
    for r in users { sv_set_kill_location(r); }
}

// salvageDebugInfo(I)
fn salvage_debug_info(i: i32) {
    if dbgrecs.len == 0 { return; }
    var users: i32[>..<] = [];
    m2r_find_dbg_users(i, users);
    if users.len == 0 { return; }
    salvage_debug_info_for(i, users);
}
