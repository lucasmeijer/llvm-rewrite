// Instruction identity and IR-flag/attribute merging, ports of llvm/lib/IR/Instruction.cpp
// (isIdenticalToWhenDefined, hasSameSpecialState, andIRFlags, isCommutative), llvm/lib/IR/IntrinsicInst.h
// (IntrinsicInst::isCommutative), llvm/lib/IR/Attributes.cpp (AttributeSet::intersectWith,
// AttributeList::intersectWith) and CallBase::tryIntersectAttributes. Used by EarlyCSE; GVN, SimplifyCFG
// hoisting/sinking and MergeFunctions-like passes need the same.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import apint;
import constrange;
import pm;

// IntrinsicInst::isCommutative
fn ii_intrinsic_is_commutative(id: i32) -> bool {
    return id == IID_maxnum || id == IID_minnum || id == IID_maximum || id == IID_minimum ||
           id == IID_maximumnum || id == IID_minimumnum || id == IID_smax || id == IID_smin ||
           id == IID_umax || id == IID_umin || id == IID_sadd_sat || id == IID_uadd_sat ||
           id == IID_sadd_with_overflow || id == IID_uadd_with_overflow || id == IID_smul_with_overflow ||
           id == IID_umul_with_overflow || id == IID_smul_fix || id == IID_umul_fix || id == IID_smul_fix_sat ||
           id == IID_umul_fix_sat || id == IID_fma || id == IID_fmuladd;
}
// Instruction::isCommutative(Opcode)
fn ii_opcode_is_commutative(o: i64) -> bool {
    return o == OP_ADD || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_FADD || o == OP_FMUL;
}
// Instruction::isCommutative()
fn ii_is_commutative(iv: i32) -> bool {
    let id = inst_iid(iv);
    if id != 0 { return ii_intrinsic_is_commutative(id); }
    return ii_opcode_is_commutative(iop(iv));
}

// ---------------------------------------------------------------------------------------------
// Attribute intersection

// Attribute equality by value (range / initializes payloads are runs in `words`, not uniqued by content)
fn ii_attr_same(x: i32, y: i32) -> bool {
    if x == y { return true; }
    let a = attrs[x];
    let b = attrs[y];
    if a.kind != b.kind { return false; }
    let k = a.kind as i64;
    if k == AK_Range {
        let wa = a.i1 as! i64;
        let wb = b.i1 as! i64;
        return words[wa] == words[wb] && words[wa + 1] == words[wb + 1] && words[wa + 2] == words[wb + 2];
    }
    if k == AK_Initializes {
        let wa = a.i1 as! i64;
        let wb = b.i1 as! i64;
        let n = words[wa] as! i64;
        if words[wb] as! i64 != n { return false; }
        // (n, then n pairs of 64-bit bounds)
        for j in 2 * n { if words[wa + 1 + j] != words[wb + 1 + j] { return false; } }
        return true;
    }
    return a.i1 == b.i1 && a.i2 == b.i2 && a.ty == b.ty && a.skey == b.skey && a.sval == b.sval;
}

// Attribute::cmpKind: enum attributes by kind, then string attributes by key
fn ii_attr_cmp_kind(x: i32, y: i32) -> i64 {
    let a = attrs[x];
    let b = attrs[y];
    if a.kind != 0 {
        if b.kind == 0 { return -1; }
        if a.kind == b.kind { return 0; }
        return if a.kind < b.kind { -1 } else { 1 };
    }
    if b.kind != 0 { return 1; }
    return bytes_cmp(sbytes(a.skey), sbytes(b.skey));
}

fn ii_range_of(x: i32) -> CRange {
    let wi = attrs[x].i1 as! i64;
    return rg_new(ap_from_cint(words[wi + 1] as i32), ap_from_cint(words[wi + 2] as i32));
}

// AttributeSet::intersectWith: (ok, set)
fn ii_aset_intersect(s0: i32, s1: i32) -> bool, i32 {
    if s0 == s1 { return true, s0; }
    var out: i32[>..<] = [];
    let n0 = aset_n(s0);
    let n1 = aset_n(s1);
    var i0: i64 = 0;
    var i1: i64 = 0;
    while i0 < n0 || i1 < n1 {
        var a0: i32 = -1;
        var a1: i32 = -1;
        if i1 == n1 { a0 = aset_attr(s0, i0); i0++; }
        else if i0 == n0 { a0 = aset_attr(s1, i1); i1++; }
        else {
            let c = ii_attr_cmp_kind(aset_attr(s0, i0), aset_attr(s1, i1));
            if c == 0 { a0 = aset_attr(s0, i0); a1 = aset_attr(s1, i1); i0++; i1++; }
            else if c < 0 { a0 = aset_attr(s0, i0); i0++; }
            else { a0 = aset_attr(s1, i1); i1++; }
        }
        let kind = attrs[a0].kind as i64;
        if kind == 0 {
            if a1 < 0 || !ii_attr_same(a0, a1) { return false, 0; }
            out.push(a0);
            continue;
        }
        let rule = ATTR_INTERSECT[kind] as i64;
        if a1 < 0 {
            if rule == 0 { return false, 0; }
            continue;
        }
        if rule == 1 { out.push(attr_enum(kind)); continue; }
        if rule == 2 {
            let v = if attrs[a0].i1 < attrs[a1].i1 { attrs[a0].i1 } else { attrs[a1].i1 };
            out.push(attr_int(kind, v));
            continue;
        }
        if rule == 3 {
            if kind == AK_Alignment {
                // align values are bytes (valueOrOne)
                let x = if attrs[a0].i1 == 0 { 1 as u64 } else { attrs[a0].i1 };
                let y = if attrs[a1].i1 == 0 { 1 as u64 } else { attrs[a1].i1 };
                out.push(attr_int(kind, if x < y { x } else { y }));
            } else if kind == AK_Memory {
                out.push(attr_int(kind, attrs[a0].i1 | attrs[a1].i1));
            } else if kind == AK_Captures {
                out.push(attr_int(kind, attrs[a0].i1 | attrs[a1].i1));
            } else if kind == AK_NoFPClass {
                out.push(attr_int(kind, attrs[a0].i1 & attrs[a1].i1));
            } else if kind == AK_Range {
                let r = rg_union(ii_range_of(a0), ii_range_of(a1));
                if !rg_is_full(r) {
                    let w = rg_w(r);
                    let t = ty_int(w);
                    let at = words.len;
                    words.push(w as u64);
                    words.push(ap_to_cint(t, r.lo) as u64);
                    words.push(ap_to_cint(t, r.hi) as u64);
                    out.push(attr_int(AK_Range, at as u64));
                }
            } else {
                fatal(str("internal: unknown attribute with a custom intersection rule: ", ATTR_NAMES[kind]));
            }
            continue;
        }
        if !ii_attr_same(a0, a1) { return false, 0; }
        out.push(a0);
        if kind == AK_ByVal {
            let x = aset_find(s0, AK_Alignment);
            let y = aset_find(s1, AK_Alignment);
            if x != y && (x < 0 || y < 0 || !ii_attr_same(x, y)) { return false, 0; }
        }
    }
    return true, aset_get(out);
}

// AttributeList::intersectWith: (ok, list)
fn ii_alist_intersect(l0: i32, l1: i32) -> bool, i32 {
    if l0 == l1 { return true, l0; }
    let n = max(alists[l0].n as i64, alists[l1].n as i64);
    var sets: i32[>..<] = [];
    for k in n {
        let a = if k < alists[l0].n as i64 { alist_runs[alists[l0].at + k] } else { 0 };
        let b = if k < alists[l1].n as i64 { alist_runs[alists[l1].at + k] } else { 0 };
        let ok, s = ii_aset_intersect(a, b);
        if !ok { return false, 0; }
        sets.push(s);
    }
    return true, alist_get(sets);
}

// CallBase::tryIntersectAttributes(Other)
fn ii_try_intersect_attributes(c: i32, other: i32) -> bool {
    let ok, l = ii_alist_intersect(insts[inst_of(c)].attrs, insts[inst_of(other)].attrs);
    if !ok { return false; }
    insts[inst_of(c)].attrs = l;
    return true;
}

// ---------------------------------------------------------------------------------------------
// Identity

// hasIdenticalOperandBundleSchema
fn ii_same_bundle_schema(a: i32, b: i32) -> bool {
    let n = cb_nbundles(a);
    if n != cb_nbundles(b) { return false; }
    for k in n {
        if cb_bundle_tag(a, k) != cb_bundle_tag(b, k) || cb_bundle_begin(a, k) != cb_bundle_begin(b, k) ||
           cb_bundle_count(a, k) != cb_bundle_count(b, k) { return false; }
    }
    return true;
}

fn ii_ints_equal(a: i32, b: i32) -> bool {
    let x = insts[inst_of(a)];
    let y = insts[inst_of(b)];
    if x.naux != y.naux { return false; }
    for k in x.naux { if ints[x.aux + k] != ints[y.aux + k] { return false; } }
    return true;
}

// Instruction::hasSameSpecialState(I2, IgnoreAlignment, IntersectAttrs)
fn ii_has_same_special_state(a: i32, b: i32, ignore_align: bool, intersect_attrs: bool) -> bool {
    let o = iop(a);
    let x = insts[inst_of(a)];
    let y = insts[inst_of(b)];
    if o == OP_ALLOCA { return x.ty2 == y.ty2 && (x.align == y.align || ignore_align); }
    if o == OP_LOAD || o == OP_STORE {
        return (x.bits & 1) == (y.bits & 1) && (x.align == y.align || ignore_align) && x.ord == y.ord && x.ss == y.ss;
    }
    if o == OP_ICMP || o == OP_FCMP { return x.pred == y.pred; }
    if o == OP_CALL || o == OP_INVOKE || o == OP_CALLBR {
        if o == OP_CALL {
            let ta = x.pred == 1 || x.pred == 2;
            let tb = y.pred == 1 || y.pred == 2;
            if ta != tb { return false; }
        }
        if x.cc != y.cc { return false; }
        if intersect_attrs {
            let ok, l = ii_alist_intersect(x.attrs, y.attrs);
            if !ok { return false; }
        } else if x.attrs != y.attrs { return false; }
        return ii_same_bundle_schema(a, b);
    }
    if o == OP_SWITCH {
        // case values: operands 2, 4, ... (already compared as operands by the callers)
        let n = nops(a) / 2;
        for k in 1..n { if k < nops(b) / 2 && op(a, 2 * k) != op(b, 2 * k) { return false; } }
        return true;
    }
    if o == OP_INSERTVALUE || o == OP_EXTRACTVALUE || o == OP_SHUFFLEVECTOR { return ii_ints_equal(a, b); }
    if o == OP_FENCE { return x.ord == y.ord && x.ss == y.ss; }
    if o == OP_CMPXCHG {
        return (x.bits & 1) == (y.bits & 1) && (x.align == y.align || ignore_align) && (x.bits & 2) == (y.bits & 2) &&
               x.ord == y.ord && x.ord2 == y.ord2 && x.ss == y.ss;
    }
    if o == OP_ATOMICRMW {
        return x.pred == y.pred && x.bits == y.bits && (x.align == y.align || ignore_align) && x.ord == y.ord && x.ss == y.ss;
    }
    if o == OP_GEP { return x.ty2 == y.ty2; }
    return true;
}

// Instruction::isIdenticalToWhenDefined(I, IntersectAttrs)
fn ii_is_identical_when_defined(a: i32, b: i32, intersect_attrs: bool) -> bool {
    if iop(a) != iop(b) || nops(a) != nops(b) || vals[a].ty != vals[b].ty { return false; }
    let n = nops(a);
    if n == 0 { return ii_has_same_special_state(a, b, false, intersect_attrs); }
    for k in n { if op(a, k) != op(b, k) { return false; } }
    if iop(a) == OP_PHI {
        for k in n { if phi_block(a, k) != phi_block(b, k) { return false; } }
        return true;
    }
    return ii_has_same_special_state(a, b, false, intersect_attrs);
}

// ---------------------------------------------------------------------------------------------
// Instruction::andIRFlags(V) for an instruction V

fn ii_is_overflowing_binop(o: i64) -> bool { o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL }
fn ii_is_possibly_exact(o: i64) -> bool { o == OP_SDIV || o == OP_UDIV || o == OP_ASHR || o == OP_LSHR }

fn ii_and_ir_flags(iv: i32, v: i32) {
    if !is_inst(v) { return; }
    let o = iop(iv);
    let ov = iop(v);
    let fs = insts[inst_of(v)].flags;
    var f = insts[inst_of(iv)].flags;
    if ii_is_overflowing_binop(ov) && ii_is_overflowing_binop(o) { f = f & (fs | ~(FL_NSW | FL_NUW)); }
    if ov == OP_TRUNC && o == OP_TRUNC { f = f & (fs | ~(FL_NSW | FL_NUW)); }
    if ii_is_possibly_exact(ov) && ii_is_possibly_exact(o) { f = f & (fs | ~FL_EXACT); }
    if ov == OP_OR && o == OP_OR { f = f & (fs | ~FL_DISJOINT); }
    if ov == OP_GEP && o == OP_GEP { f = f & fs; }
    if (ov == OP_ZEXT || ov == OP_UITOFP) && (o == OP_ZEXT || o == OP_UITOFP) { f = f & (fs | ~FL_NNEG); }
    if ov == OP_ICMP && o == OP_ICMP { f = f & (fs | ~FL_SAMESIGN); }
    insts[inst_of(iv)].flags = f;
    if is_fp_math_operator(v) && is_fp_math_operator(iv) {
        insts[inst_of(iv)].fmf = insts[inst_of(iv)].fmf & insts[inst_of(v)].fmf;
    }
}
