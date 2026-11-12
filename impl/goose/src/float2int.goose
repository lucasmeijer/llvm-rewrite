// Float2Int: port of llvm/lib/Transforms/Scalar/Float2Int.cpp (Float2IntPass), with the EquivalenceClasses
// member order of llvm/include/llvm/ADT/EquivalenceClasses.h (Members in insertion order, a class's member list
// appended on union).
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import flags;
import domtree;
import apint;
import apfloat;
import bignum;
import fpu;
import constfold;
import constrange;
import datalayout;
import aic_trunc;

// SeenInsts (MapVector): index by VM_PASS0 (value -> index + 1)
var f2_seen_inst: i32[>..<];
var f2_seen_rng: CRange[>..<];
// Roots (SetVector): list + VS_PASS0
var f2_roots: i32[>..<];
// EquivalenceClasses: node arrays, value -> node index + 1 in VM_PASS1
var f2_ec_val: i32[>..<];
var f2_ec_next: i32[>..<];
var f2_ec_lead: i32[>..<];      // leader: end of its list; other: its leader (or an older leader)
var f2_ec_isl: bool[>..<];
var f2_ec_conv: i32[>..<];      // ConvertedInsts value (-1 = not converted)
var f2_conv_order: i32[>..<];   // ConvertedInsts insertion order (node indices)
var f2_ops: i32[>..<];          // convert()'s NewOperands (recursion: runs with a mark)
var f2_bw: i64 = 65;

fn f2_map_fcmp(p: i64) -> i64 {
    return match p {
        1, 9 => 32,     // oeq, ueq -> eq
        2, 10 => 38,    // ogt, ugt -> sgt
        3, 11 => 39,    // oge, uge -> sge
        4, 12 => 40,    // olt, ult -> slt
        5, 13 => 41,    // ole, ule -> sle
        6, 14 => 33,    // one, une -> ne
        _ => -1,
    };
}

fn f2_bad() -> CRange { rg_full(f2_bw) }
fn f2_unknown() -> CRange { rg_empty(f2_bw) }
fn f2_validate(r: CRange) -> CRange { if rg_w(r) > f2_bw { f2_bad() } else { r } }

fn f2_seen_idx(i: i32) -> i64 { vm_get(VM_PASS0, i, 0) - 1 }
fn f2_seen(i: i32, r: CRange) {
    let k = f2_seen_idx(i);
    if k >= 0 { f2_seen_rng[k] = r; return; }
    f2_seen_inst.push(i);
    f2_seen_rng.push(r);
    vm_set(VM_PASS0, i, f2_seen_inst.len as i64);
}

fn f2_ec_insert(v: i32) -> i64 {
    let k = vm_get(VM_PASS1, v, 0) - 1;
    if k >= 0 { return k; }
    let n = f2_ec_val.len;
    f2_ec_val.push(v);
    f2_ec_next.push(-1);
    f2_ec_lead.push(n as i32);
    f2_ec_isl.push(true);
    f2_ec_conv.push(-1);
    vm_set(VM_PASS1, v, n + 1);
    return n;
}
fn f2_ec_leader(k0: i64) -> i64 {
    var k = k0;
    while !f2_ec_isl[k] { k = f2_ec_lead[k] as i64; }
    return k;
}
fn f2_ec_union(a: i32, b: i32) {
    let ia = f2_ec_insert(a);
    let ib = f2_ec_insert(b);
    let l1 = f2_ec_leader(ia);
    let l2 = f2_ec_leader(ib);
    if l1 == l2 { return; }
    let end1 = f2_ec_lead[l1] as i64;
    f2_ec_next[end1] = l2 as i32;
    f2_ec_lead[l1] = f2_ec_lead[l2];
    f2_ec_isl[l2] = false;
    f2_ec_lead[l2] = l1 as i32;
}

fn f2_find_roots(fv: i32) {
    var bb = func_first_block(fv);
    while bb >= 0 {
        if dt_has_node(DT_DOM, bb) {
            var i = block_first(bb);
            while i >= 0 {
                if !ty_is_vector(vals[i].ty) {
                    let o = iop(i);
                    var add = false;
                    if o == OP_FPTOUI || o == OP_FPTOSI { add = true; }
                    else if o == OP_FCMP && f2_map_fcmp(inst_pred(i)) >= 0 { add = true; }
                    if add && vs_add(VS_PASS0, i) { f2_roots.push(i); }
                }
                i = inst_next(i);
            }
        }
        bb = block_next(bb);
    }
}

fn f2_walk_backwards() {
    var wl: i32[>..<] = [];
    for r in f2_roots { wl.push(r); }
    while wl.len > 0 {
        let i = wl.pop();
        if f2_seen_idx(i) >= 0 { continue; }
        let o = iop(i);
        if o == OP_UITOFP || o == OP_SITOFP {
            let bw = ty_bits(vals[op(i, 0)].ty);
            f2_seen(i, f2_validate(rg_cast(o, rg_full(bw), f2_bw)));
            continue;
        }
        if o == OP_FNEG || o == OP_FADD || o == OP_FSUB || o == OP_FMUL || o == OP_FPTOUI || o == OP_FPTOSI || o == OP_FCMP {
            f2_seen(i, f2_unknown());
        } else {
            f2_seen(i, f2_bad());
        }
        for k in nops(i) {
            let x = op(i, k);
            if is_inst(x) {
                f2_ec_union(i, x);
                if !rg_eq(f2_seen_rng[f2_seen_idx(i)], f2_bad()) { wl.push(x); }
            } else if vals[x].kind != VK_CFP {
                f2_seen(i, f2_bad());
            }
        }
    }
}

// (ok, value as a signed integer of width w) of an integral finite ConstantFP; ok = false if it doesn't fit
fn f2_const_int(c: i32, w: i64) -> bool, AP {
    var mag: u32[>..<] = [];
    let neg = fp_trunc_magnitude(fp_kind_ty(vals[c].ty), cint_lo(c), cint_hi(c), mag);
    let ab = bn_active_bits(mag);
    if neg {
        if ab > w || (ab == w && bn_ctz(mag) != w - 1) { return false, ap_zero(w); }
    } else if ab > w - 1 { return false, ap_zero(w); }
    var ws: u64[>..] = [];
    for k in (ab + 63) / 64 { ws.push(bn_word(mag, k)); }
    if ws.len == 0 { ws.push(0); }
    let m = ap_from_words(w, ws);
    return true, if neg { ap_neg(m) } else { m };
}

// calcRange: (computed, range); computed = false is std::nullopt
fn f2_calc_range(i: i32) -> bool, CRange {
    var rs: CRange[>..<] = [];
    for k in nops(i) {
        let x = op(i, k);
        if is_inst(x) {
            let r = f2_seen_rng[f2_seen_idx(x)];
            if rg_eq(r, f2_unknown()) { return false, r; }
            rs.push(r);
        } else if vals[x].kind == VK_CFP {
            let kind = fp_kind_ty(vals[x].ty);
            let p = fp_decompose(kind, cint_lo(x), cint_hi(x));
            if p.cat == FC_NAN || p.cat == FC_INF { return true, f2_bad(); }
            if p.cat == FC_ZERO && p.neg && is_fp_math_operator(i) && (insts[inst_of(i)].fmf & FMF_NSZ) == 0 { return true, f2_bad(); }
            let rlo, rhi = fp_round_to_integral(kind, cint_lo(x), cint_hi(x), FRM_NEAREST_EVEN);
            if rlo != cint_lo(x) || rhi != cint_hi(x) { return true, f2_bad(); }
            let ok, v = f2_const_int(x, f2_bw);
            if !ok { return true, f2_bad(); }
            rs.push(rg_single(v));
        } else {
            fatal("float2int: Should have already marked this as badRange!");
        }
    }
    let o = iop(i);
    if o == OP_FNEG { return true, rg_sub(rg_single(ap_zero(rg_w(rs[0]))), rs[0]); }
    if o == OP_FADD || o == OP_FSUB || o == OP_FMUL { return true, rg_binop(o, rs[0], rs[1]); }
    if o == OP_FPTOUI || o == OP_FPTOSI { return true, rg_cast(o, rs[0], f2_bw); }
    if o == OP_FCMP { return true, rg_union(rs[0], rs[1]); }
    fatal("float2int: Should have been handled in walkForwards!");
    return false, rs[0];
}

fn f2_walk_forwards() {
    // std::deque: push_back / pop_back / push_front
    var dq: i32[>..<] = [];
    var front: i64 = 0;   // dq[front..] is the deque; push_front writes below `front` when there's room
    var tmp: i32[>..<] = [];
    for k in f2_seen_inst.len { if rg_eq(f2_seen_rng[k], f2_unknown()) { tmp.push(f2_seen_inst[k]); } }
    // reserve room for push_front
    for k in tmp.len + 1 { dq.push(-1); }
    front = dq.len;
    for x in tmp { dq.push(x); }
    while dq.len > front {
        let i = dq.pop();
        let ok, r = f2_calc_range(i);
        if ok { f2_seen(i, r); }
        else {
            if front == 0 {
                // grow the room at the front
                var rest: i32[>..<] = [];
                for k in dq.len { rest.push(dq[k]); }
                dq.clear();
                for k in rest.len + 1 { dq.push(-1); }
                front = dq.len;
                for x in rest { dq.push(x); }
            }
            front--;
            dq[front] = i;
        }
    }
}

fn f2_prec(t: i32) -> i64 {
    let k = types[t].kind as i64;
    if k == TK_PPC_FP128 { return 106; }
    return fp_fmt(k).p;
}

fn f2_smallest_legal_int(minbw: i64) -> i32 {
    for w in dl_native { if minbw <= w { return ty_int(w); } }
    return -1;
}

fn f2_sext_or_trunc(v: i32, ty: i32) -> i32 {
    let a = ty_bits(ty_scalar(vals[v].ty));
    let b = ty_bits(ty_scalar(ty));
    if a < b { return ab_sext(v, ty); }
    if a > b { return ab_trunc(v, ty); }
    return v;
}

recursive fn f2_convert(i: i32, to: i32) -> i32 {
    let node = vm_get(VM_PASS1, i, 0) - 1;
    if node < 0 { fatal("float2int: converting an instruction outside the classes"); }
    if f2_ec_conv[node] >= 0 { return f2_ec_conv[node]; }
    let mark = f2_ops.len;
    let o = iop(i);
    for k in nops(i) {
        let v = op(i, k);
        if o == OP_UITOFP || o == OP_SITOFP { f2_ops.push(v); }
        else if is_inst(v) { let c = f2_convert(v, to); f2_ops.push(c); }
        else if vals[v].kind == VK_CFP {
            let ok, x = f2_const_int(v, ty_bits(to));
            if !ok { fatal("float2int: constant out of range in convert"); }
            f2_ops.push(ap_to_cint(to, x));
        } else { fatal("float2int: Unhandled operand type?"); }
    }
    ab_set(i);
    var nv: i32 = -1;
    let nm = val_name(i);
    if o == OP_FPTOUI { nv = ab_zext_or_trunc(f2_ops[mark], vals[i].ty); }
    else if o == OP_FPTOSI { nv = f2_sext_or_trunc(f2_ops[mark], vals[i].ty); }
    else if o == OP_FCMP {
        let p = f2_map_fcmp(inst_pred(i));
        let a = f2_ops[mark];
        let b = f2_ops[mark + 1];
        if is_constant(a) && is_constant(b) {
            nv = cf_compare(p, a, b);
        }
        if nv < 0 {
            let iv = create_inst(OP_ICMP, ab_cmp_ty(vals[a].ty), [a, b]);
            insts[inst_of(iv)].pred = p as u8;
            nv = ab_insert(iv, nm);
        }
    }
    else if o == OP_UITOFP { nv = ab_zext_or_trunc(f2_ops[mark], to); }
    else if o == OP_SITOFP { nv = f2_sext_or_trunc(f2_ops[mark], to); }
    else if o == OP_FNEG { nv = ab_binop(OP_SUB, c_null(vals[f2_ops[mark]].ty), f2_ops[mark], 0, nm); }
    else if o == OP_FADD || o == OP_FSUB || o == OP_FMUL {
        let bo = if o == OP_FADD { OP_ADD } else if o == OP_FSUB { OP_SUB } else { OP_MUL };
        nv = ab_binop(bo, f2_ops[mark], f2_ops[mark + 1], 0, nm);
    } else { fatal("float2int: Unhandled instruction!"); }
    f2_ops.resize(mark);
    if vs_has(VS_PASS0, i) { rauw(i, nv); }
    f2_ec_conv[node] = nv;
    f2_conv_order.push(node as i32);
    return nv;
}

fn f2_validate_and_transform() -> bool {
    var changed = false;
    for e in f2_ec_val.len {
        if !f2_ec_isl[e] { continue; }
        var r = rg_empty(f2_bw);
        var fail = false;
        var conv_ty: i32 = -1;
        var m = e as i32;
        while m >= 0 {
            let i = f2_ec_val[m];
            m = f2_ec_next[m];
            let si = f2_seen_idx(i);
            if si < 0 { continue; }
            r = rg_union(r, f2_seen_rng[si]);
            if !vs_has(VS_PASS0, i) {
                if conv_ty < 0 { conv_ty = vals[i].ty; }
                var u = vals[i].first_use;
                while u >= 0 {
                    let us = uses[u].user;
                    if !is_inst(us) || f2_seen_idx(us) < 0 { fail = true; break; }
                    u = uses[u].next;
                }
            }
            if fail { break; }
        }
        if fail || rg_is_full(r) || rg_is_sign_wrapped(r) { continue; }
        if conv_ty < 0 { fatal("float2int: Must have set the convertedtoty by this point!"); }
        let minbw = rg_min_signed_bits(r) + 1;
        if minbw > f2_prec(conv_ty) - 1 { continue; }
        var ty = f2_smallest_legal_int(minbw);
        if ty < 0 {
            if minbw <= 32 { ty = T_I32; }
            else if minbw <= 64 { ty = ty_int(64); }
            else { continue; }
        }
        var m2 = e as i32;
        while m2 >= 0 {
            f2_convert(f2_ec_val[m2], ty);
            m2 = f2_ec_next[m2];
        }
        changed = true;
    }
    return changed;
}

fn float2int_run(fv: i32) -> u32 {
    f2_bw = flag_int("float2int-max-integer-bw", 64) + 1;
    f2_seen_inst.clear(); f2_seen_rng.clear(); f2_roots.clear();
    f2_ec_val.clear(); f2_ec_next.clear(); f2_ec_lead.clear(); f2_ec_isl.clear(); f2_ec_conv.clear();
    f2_conv_order.clear();
    vs_clear(VS_PASS0); vm_clear(VM_PASS0); vm_clear(VM_PASS1);
    dt_get(fv, DT_DOM);
    f2_find_roots(fv);
    f2_walk_backwards();
    f2_walk_forwards();
    let changed = f2_validate_and_transform();
    if changed {
        var k = f2_conv_order.len - 1;
        while k >= 0 { inst_erase_from_parent(f2_ec_val[f2_conv_order[k]]); k--; }
    }
    if !changed { return PA_ALL; }
    return PA_CFG;
}
