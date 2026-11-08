// Intrinsic tables and signatures. Port of llvm/lib/IR/Intrinsics.cpp (lookupIntrinsicID, IIT decoding,
// matchIntrinsicType / isSignatureValid, DecodeFixedType / getType, getMangledTypeStr / getName,
// getAttributes, remangleIntrinsicFunction) over the TableGen tables in gen_intrinsics.goose.
import std;
import ir;
import gen_attrs;
import gen_intrinsics;

// ---------------------------------------------------------------------------------------------
// Intrinsic ID per function (Function::IntID). Indexed by glob id; -1/0 = not_intrinsic.

var glob_iid: i32[>..];

fn func_iid(fv: i32) -> i64 {
    let g = glob_of(fv);
    if g < glob_iid.len { return glob_iid[g] as i64; }
    return 0;
}

// Function::updateAfterNameChange
fn func_update_iid(fv: i32) {
    let g = glob_of(fv);
    while glob_iid.len <= g { glob_iid.push(0); }
    var id: i64 = 0;
    if vals[fv].name >= 0 && starts_with(sbytes(vals[fv].name), "llvm.") {
        globs[g].intrinsic = 1;
        id = intr_lookup(sbytes(vals[fv].name));
    } else {
        globs[g].intrinsic = 0;
    }
    glob_iid[g] = id as i32;
}

// Table access (gen_intrinsics.goose stores the big tables as fixed-width hex strings).
fn hexv(s: const u8[:], i: i64, w: i64) -> i64 {
    var v: i64 = 0;
    for k in w {
        let c = s[i * w + k];
        let d: i64 = if c >= 'a' { (c - 'a') as i64 + 10 } else { (c - '0') as i64 };
        v = v * 16 + d;
    }
    return v;
}
var name_off: i32[>..];
fn intr_init() {
    if name_off.len > 0 { return; }
    name_off.push(0);
    for c, i in INTR_NAMES_BLOB { if c == '\n' { name_off.push((i + 1) as i32); } }
}
fn intr_name(id: i64) -> const u8[:] {
    intr_init();
    return INTR_NAMES_BLOB[name_off[id]..name_off[id + 1] - 1];
}
fn intr_is_overloaded(id: i64) -> bool { hexv(INTR_OVERLOADED, id, 1) != 0 }
fn iit_byte(p: i64) -> i64 { hexv(INTR_IIT, p, 2) }

// ---------------------------------------------------------------------------------------------
// lookupIntrinsicID

// strncmp(a + cs, b + cs, ce - cs) on NUL-terminated views of a and b
fn intr_cmp_part(a: const u8[:], b: const u8[:], cs: i64, ce: i64) -> i64 {
    var k = cs;
    while k < ce {
        let x: i64 = if k < a.len { a[k] as i64 } else { 0 };
        let y: i64 = if k < b.len { b[k] as i64 } else { 0 };
        if x != y { return if x < y { -1 } else { 1 }; }
        if x == 0 { return 0; }
        k++;
    }
    return 0;
}

fn intr_lookup(name: const u8[:]) -> i64 {
    if !starts_with(name, "llvm.") { return 0; }
    // findTargetSubtable
    let rest = name[5..];
    var tl = 0;
    while tl < rest.len && rest[tl] != '.' { tl++; }
    let target = rest[..tl];
    var ti = 0;
    for tn, i in INTR_TARGET_NAMES { if i > 0 && tn == target { ti = i; } }
    let base = INTR_TARGET_OFF[ti] as i64 + 1;   // IntrinsicNameOffsetTable[1] + Offset
    let cnt = INTR_TARGET_CNT[ti] as i64;
    // lookupLLVMIntrinsicByName
    var ce: i64 = 4;
    if ti > 0 { ce += 1 + INTR_TARGET_NAMES[ti].len; }
    var lo = base;
    var hi = base + cnt;
    var last_lo = lo;
    while ce < name.len && hi - lo > 0 {
        let cs = ce;
        var e = cs + 1;
        while e < name.len && name[e] != '.' { e++; }
        ce = e;
        last_lo = lo;
        // equal_range
        var a = lo;
        var b = hi;
        while a < b { let m = (a + b) / 2; if intr_cmp_part(intr_name(m), name, cs, ce) < 0 { a = m + 1; } else { b = m; } }
        var c = a;
        var d = hi;
        while c < d { let m = (c + d) / 2; if intr_cmp_part(name, intr_name(m), cs, ce) < 0 { d = m; } else { c = m + 1; } }
        lo = a;
        hi = c;
    }
    if hi - lo > 0 { last_lo = lo; }
    if last_lo == base + cnt { return 0; }
    let found = intr_name(last_lo);
    if !(name == found || (starts_with(name, found) && name.len > found.len && name[found.len] == '.')) { return 0; }
    let id = last_lo;
    if name.len == found.len || intr_is_overloaded(id) { return id; }
    return 0;
}

// ---------------------------------------------------------------------------------------------
// IIT descriptors (Intrinsic::IITDescriptor)

let IITD_VOID = 0;
let IITD_VARARG = 1;
let IITD_MMX = 2;
let IITD_TOKEN = 3;
let IITD_METADATA = 4;
let IITD_HALF = 5;
let IITD_FLOAT = 6;
let IITD_DOUBLE = 7;
let IITD_QUAD = 8;
let IITD_INTEGER = 9;
let IITD_VECTOR = 10;
let IITD_POINTER = 11;
let IITD_STRUCT = 12;
let IITD_OVERLOADED = 13;
let IITD_MATCH = 14;
let IITD_EXTEND = 15;
let IITD_TRUNC = 16;
let IITD_ONENTH = 17;
let IITD_SAMEVECWIDTH = 18;
let IITD_VECOFANYPTRS = 19;
let IITD_VECELEMENT = 20;
let IITD_SUBDIVIDE2 = 21;
let IITD_SUBDIVIDE4 = 22;
let IITD_VECOFBITCASTS = 23;
let IITD_AMX = 24;
let IITD_PPCQUAD = 25;
let IITD_BFLOAT = 26;
let IITD_SVCOUNT = 27;
let IITD_EXTERNREF = 28;
let IITD_FUNCREF = 29;

// Decoded table of the intrinsic being worked on: kind, field (for vectors: width, with scalable flag in b).
var iitk: i32[>..<];
var iitf: i64[>..<];
var iitb: i32[>..<];

fn iit_push(k: i64, f: i64, b: i64) { iitk.push(k as i32); iitf.push(f); iitb.push(b as i32); }

// DecodeIITType; p indexes INTR_IIT.
recursive fn decode_iit(p0: i64) -> i64 {
    var p = p0;
    let info = iit_byte(p);
    p++;
    if info == 0 { iit_push(IITD_VOID, 0, 0); return p; }
    if info == 26 { iit_push(IITD_VARARG, 0, 0); return p; }
    if info == 17 { iit_push(IITD_MMX, 0, 0); return p; }
    if info == 42 { iit_push(IITD_AMX, 0, 0); return p; }
    if info == 18 { iit_push(IITD_TOKEN, 0, 0); return p; }
    if info == 19 { iit_push(IITD_METADATA, 0, 0); return p; }
    if info == 6 { iit_push(IITD_HALF, 0, 0); return p; }
    if info == 40 { iit_push(IITD_BFLOAT, 0, 0); return p; }
    if info == 7 { iit_push(IITD_FLOAT, 0, 0); return p; }
    if info == 8 { iit_push(IITD_DOUBLE, 0, 0); return p; }
    if info == 33 { iit_push(IITD_QUAD, 0, 0); return p; }
    if info == 43 { iit_push(IITD_PPCQUAD, 0, 0); return p; }
    if info == 1 { iit_push(IITD_INTEGER, 1, 0); return p; }
    if info == 47 { iit_push(IITD_INTEGER, 2, 0); return p; }
    if info == 48 { iit_push(IITD_INTEGER, 4, 0); return p; }
    if info == 49 { iit_push(IITD_SVCOUNT, 0, 0); return p; }
    if info == 2 { iit_push(IITD_INTEGER, 8, 0); return p; }
    if info == 3 { iit_push(IITD_INTEGER, 16, 0); return p; }
    if info == 4 { iit_push(IITD_INTEGER, 32, 0); return p; }
    if info == 5 { iit_push(IITD_INTEGER, 64, 0); return p; }
    if info == 30 { iit_push(IITD_INTEGER, 128, 0); return p; }
    var vw: i64 = 0;
    if info == 25 { vw = 1; } else if info == 9 { vw = 2; } else if info == 44 { vw = 3; } else if info == 10 { vw = 4; }
    else if info == 50 { vw = 6; } else if info == 11 { vw = 8; } else if info == 51 { vw = 10; } else if info == 12 { vw = 16; }
    else if info == 13 { vw = 32; } else if info == 16 { vw = 64; } else if info == 39 { vw = 128; } else if info == 41 { vw = 256; }
    else if info == 31 { vw = 512; } else if info == 32 { vw = 1024; } else if info == 52 { vw = 2048; } else if info == 53 { vw = 4096; }
    if vw > 0 {
        var sc: i64 = 0;
        if iit_byte(p) == 35 { p++; sc = 1; }
        iit_push(IITD_VECTOR, vw, sc);
        return decode_iit(p);
    }
    if info == 45 { iit_push(IITD_EXTERNREF, 0, 0); return p; }
    if info == 46 { iit_push(IITD_FUNCREF, 0, 0); return p; }
    if info == 14 { iit_push(IITD_POINTER, 0, 0); return p; }
    if info == 24 { iit_push(IITD_POINTER, iit_byte(p), 0); return p + 1; }
    if info == 15 {
        let idx = iit_byte(p);
        let kinds = iit_byte(p + 1);
        iit_push(IITD_OVERLOADED, (kinds << 8) | idx, 0);
        return p + 2;
    }
    if info == 20 { iit_push(IITD_MATCH, iit_byte(p), 0); return p + 1; }
    if info == 22 { iit_push(IITD_EXTEND, iit_byte(p), 0); return p + 1; }
    if info == 23 { iit_push(IITD_TRUNC, iit_byte(p), 0); return p + 1; }
    if info == 27 { iit_push(IITD_ONENTH, ((iit_byte(p + 1)) << 16) | (iit_byte(p)), 0); return p + 2; }
    if info == 28 { iit_push(IITD_SAMEVECWIDTH, iit_byte(p), 0); return decode_iit(p + 1); }
    if info == 29 { iit_push(IITD_VECOFANYPTRS, ((iit_byte(p + 1)) << 16) | (iit_byte(p)), 0); return p + 2; }
    if info == 21 {
        let n = iit_byte(p) + 2;
        p++;
        iit_push(IITD_STRUCT, n, 0);
        for k in n { p = decode_iit(p); }
        return p;
    }
    if info == 36 { iit_push(IITD_SUBDIVIDE2, iit_byte(p), 0); return p + 1; }
    if info == 37 { iit_push(IITD_SUBDIVIDE4, iit_byte(p), 0); return p + 1; }
    if info == 34 { iit_push(IITD_VECELEMENT, iit_byte(p), 0); return p + 1; }
    if info == 38 { iit_push(IITD_VECOFBITCASTS, iit_byte(p), 0); return p + 1; }
    fatal("unhandled IIT entry");
    return p;
}

// getIntrinsicInfoTableEntries: fills iitk/iitf/iitb; returns number of args and vararg flag.
fn intr_table(id: i64) -> i64, bool {
    iitk.clear(); iitf.clear(); iitb.clear();
    var p = hexv(INTR_IIT_OFF, id, 5);
    p = decode_iit(p);
    var nargs: i64 = 0;
    while iit_byte(p) != 0 { p = decode_iit(p); nargs++; }
    var va = false;
    if iitk.len > 0 && iitk[iitk.len - 1] as i64 == IITD_VARARG {
        va = true;
        iitk.pop(); iitf.pop(); iitb.pop();
        nargs--;
    }
    return nargs, va;
}

fn iit_oidx(k: i64) -> i64 { iitf[k] & 0xFF }
fn iit_hi(k: i64) -> i64 { iitf[k] >> 16 }

// ---------------------------------------------------------------------------------------------
// Type helpers (Type::getExtendedType etc.)

fn ty_with_elem(t: i32, e: i32) -> i32 {
    if ty_is_vector(t) { return ty_vector(e, types[t].cnt, types[t].kind == TK_SVEC); }
    return e;
}
fn ty_scalar_bits(t: i32) -> i64 {
    let s = ty_scalar(t);
    let k = types[s].kind;
    if k == TK_INT { return ty_bits(s); }
    if k == TK_HALF || k == TK_BFLOAT { return 16; }
    if k == TK_FLOAT { return 32; }
    if k == TK_DOUBLE { return 64; }
    if k == TK_X86_FP80 { return 80; }
    if k == TK_FP128 || k == TK_PPC_FP128 { return 128; }
    return 0;
}
fn ty_extended(t: i32) -> i32 { ty_with_elem(t, ty_int(ty_bits(ty_scalar(t)) * 2)) }
fn ty_truncated(t: i32) -> i32 { ty_with_elem(t, ty_int(ty_bits(ty_scalar(t)) / 2)) }
fn ty_vec_integer(t: i32) -> i32 { ty_with_elem(t, ty_int(ty_scalar_bits(t))) }
fn ty_subdivided(t: i32, n: i64) -> i32 {
    var v = t;
    for k in n {
        let e = types[v].a;
        var ne: i32 = -1;
        if ty_is_int(e) { ne = ty_int(ty_bits(e) / 2); }
        else if types[e].kind == TK_DOUBLE { ne = T_FLOAT; }
        else if types[e].kind == TK_FLOAT { ne = ty_simple(TK_HALF); }
        else { fatal("cannot subdivide vector element type"); }
        v = ty_vector(ne, types[v].cnt * 2, types[v].kind == TK_SVEC);
    }
    return v;
}
fn ty_one_nth(t: i32, n: i64) -> i32 { ty_vector(types[t].a, types[t].cnt / n, types[t].kind == TK_SVEC) }

// ---------------------------------------------------------------------------------------------
// matchIntrinsicType / isSignatureValid. Overload types collect in `otys`.

var otys: i32[>..<];
var deferred_ty: i32[>..<];
var deferred_pos: i64[>..<];
var mpos: i64 = 0;      // current position in the descriptor table (ArrayRef Infos)

recursive fn match_type(ty: i32, is_deferred: bool) -> bool {
    if mpos >= iitk.len { return true; }
    let start = mpos;
    let k = iitk[mpos] as i64;
    let f = iitf[mpos];
    let fb = iitb[mpos] as i64;
    mpos++;
    let tk = types[ty].kind;
    if k == IITD_VOID { return tk != TK_VOID; }
    if k == IITD_MMX { return !(tk == TK_FVEC && types[ty].cnt == 1 && ty_is_int(types[ty].a) && ty_bits(types[ty].a) == 64); }
    if k == IITD_AMX { return tk != TK_X86_AMX; }
    if k == IITD_TOKEN { return tk != TK_TOKEN; }
    if k == IITD_METADATA { return tk != TK_METADATA; }
    if k == IITD_HALF { return tk != TK_HALF; }
    if k == IITD_BFLOAT { return tk != TK_BFLOAT; }
    if k == IITD_FLOAT { return tk != TK_FLOAT; }
    if k == IITD_DOUBLE { return tk != TK_DOUBLE; }
    if k == IITD_QUAD { return tk != TK_FP128; }
    if k == IITD_PPCQUAD { return tk != TK_PPC_FP128; }
    if k == IITD_INTEGER { return !(tk == TK_INT && ty_bits(ty) == f); }
    if k == IITD_SVCOUNT || k == IITD_EXTERNREF || k == IITD_FUNCREF { return true; }
    if k == IITD_VECTOR {
        let want_kind = if fb != 0 { TK_SVEC } else { TK_FVEC };
        if !(tk == want_kind && types[ty].cnt == f) { return true; }
        return match_type(types[ty].a, is_deferred);
    }
    if k == IITD_POINTER { return !(tk == TK_PTR && types[ty].n as i64 == f); }
    if k == IITD_STRUCT {
        if !(tk == TK_STRUCT && (types[ty].flags & TF_NAMED) == 0 && (types[ty].flags & TF_PACKED) == 0 && types[ty].cnt == f) { return true; }
        for j in types[ty].cnt {
            if match_type(ty_field(ty, j), is_deferred) { return true; }
        }
        return false;
    }
    if k == IITD_OVERLOADED {
        otys.push(ty);
        let vc = (f >> 12) & 0xF;
        let ec = (f >> 8) & 0xF;
        var ok = true;
        if vc == 1 { ok = ty_is_vector(ty); } else if vc == 2 { ok = !ty_is_vector(ty); }
        let et = ty_scalar(ty);
        if ec == 1 { ok = ok && ty_is_int(et); }
        else if ec == 2 { ok = ok && ty_is_fp(et); }
        else if ec == 3 { ok = ok && types[et].kind == TK_PTR; }
        return !ok;
    }
    let oidx = f & 0xFF;
    if k == IITD_MATCH {
        if oidx >= otys.len { return is_deferred || defer_check(ty, start); }
        return ty != otys[oidx];
    }
    if k == IITD_EXTEND || k == IITD_TRUNC {
        if oidx >= otys.len { return is_deferred || defer_check(ty, start); }
        let ot = otys[oidx];
        if !ty_is_int(ty_scalar(ot)) { return true; }
        let nt = if k == IITD_EXTEND { ty_extended(ot) } else { ty_truncated(ot) };
        return ty != nt;
    }
    if k == IITD_ONENTH {
        let div = f >> 16;
        if oidx >= otys.len { return is_deferred || defer_check(ty, start); }
        let ot = otys[oidx];
        if !ty_is_vector(ot) { return true; }
        if types[ot].cnt % div != 0 { return true; }
        return ty_one_nth(ot, div) != ty;
    }
    if k == IITD_SAMEVECWIDTH {
        if oidx >= otys.len {
            skip_one();
            return is_deferred || defer_check(ty, start);
        }
        let ov = otys[oidx];
        let ovec = ty_is_vector(ov);
        let tvec = ty_is_vector(ty);
        if ovec != tvec { return true; }
        var et = ty;
        if tvec {
            if types[ov].cnt != types[ty].cnt || types[ov].kind != types[ty].kind { return true; }
            et = types[ty].a;
        }
        return match_type(et, is_deferred);
    }
    if k == IITD_VECOFANYPTRS {
        let r = f >> 16;
        if r >= otys.len {
            if is_deferred { return true; }
            otys.push(ty);
            return defer_check(ty, start);
        }
        if !is_deferred { otys.push(ty); }
        let rt = otys[r];
        if !ty_is_vector(rt) || !ty_is_vector(ty) { return true; }
        return !(types[ty].cnt == types[rt].cnt && types[ty].kind == types[rt].kind && types[types[ty].a].kind == TK_PTR);
    }
    if k == IITD_VECELEMENT {
        if oidx >= otys.len { return is_deferred || defer_check(ty, start); }
        let ot = otys[oidx];
        if !ty_is_vector(ot) { return true; }
        return types[ot].a != ty;
    }
    if k == IITD_SUBDIVIDE2 || k == IITD_SUBDIVIDE4 {
        if oidx >= otys.len { return is_deferred || defer_check(ty, start); }
        let ot = otys[oidx];
        if !ty_is_vector(ot) { return true; }
        return ty_subdivided(ot, if k == IITD_SUBDIVIDE2 { 1 } else { 2 }) != ty;
    }
    if k == IITD_VECOFBITCASTS {
        if oidx >= otys.len { return is_deferred || defer_check(ty, start); }
        let ot = otys[oidx];
        if !ty_is_vector(ot) { return true; }
        return ty_vec_integer(ot) != ty;
    }
    return true;
}

fn defer_check(ty: i32, pos: i64) -> bool {
    deferred_ty.push(ty);
    deferred_pos.push(pos);
    return false;
}

// Skips one complete descriptor (the element type following SameVecWidth) — Infos.consume_front().
fn skip_one() { mpos++; }

// isSignatureValid(FTy, ...) for intrinsic id; fills otys.
recursive fn intr_signature_valid(id: i64, fty: i32) -> bool {
    otys.clear();
    if id <= 0 { return false; }
    let nargs, va = intr_table(id);
    deferred_ty.clear();
    deferred_pos.clear();
    mpos = 0;
    if match_type(ty_fn_ret(fty), false) { return false; }
    if ty_fn_nparams(fty) != nargs { return false; }
    for k in ty_fn_nparams(fty) {
        if match_type(ty_fn_param(fty, k), false) { return false; }
    }
    let end = mpos;
    var i = 0;
    while i < deferred_ty.len {
        mpos = deferred_pos[i];
        if match_type(deferred_ty[i], true) { return false; }
        i++;
    }
    if end != iitk.len { return false; }
    if ty_fn_vararg(fty) != va { return false; }
    return true;
}

// ---------------------------------------------------------------------------------------------
// DecodeFixedType / getType

var dpos: i64 = 0;
var tscratch: i32[>..<];

recursive fn decode_fixed(ov: const i32[:]) -> i32 {
    let k = iitk[dpos] as i64;
    let f = iitf[dpos];
    let fb = iitb[dpos] as i64;
    dpos++;
    if k == IITD_VOID { return T_VOID; }
    if k == IITD_MMX { return ty_vector(T_I64, 1, false); }
    if k == IITD_AMX { return ty_simple(TK_X86_AMX); }
    if k == IITD_TOKEN { return T_TOKEN; }
    if k == IITD_METADATA { return T_METADATA; }
    if k == IITD_HALF { return ty_simple(TK_HALF); }
    if k == IITD_BFLOAT { return ty_simple(TK_BFLOAT); }
    if k == IITD_FLOAT { return T_FLOAT; }
    if k == IITD_DOUBLE { return T_DOUBLE; }
    if k == IITD_QUAD { return ty_simple(TK_FP128); }
    if k == IITD_PPCQUAD { return ty_simple(TK_PPC_FP128); }
    if k == IITD_INTEGER { return ty_int(f); }
    if k == IITD_VECTOR { let e = decode_fixed(ov); return ty_vector(e, f, fb != 0); }
    if k == IITD_POINTER { return ty_ptr(f); }
    if k == IITD_STRUCT {
        let mark = tscratch.len;
        for j in f { let e = decode_fixed(ov); tscratch.push(e); }
        let at = ints.len as i32;
        for j in mark..tscratch.len { ints.push(tscratch[j]); }
        tscratch.resize(mark);
        return ty_struct_run(at, f, false);
    }
    let oidx = f & 0xFF;
    if k == IITD_OVERLOADED || k == IITD_VECOFANYPTRS || k == IITD_MATCH { return ov[oidx]; }
    if k == IITD_EXTEND { return ty_extended(ov[oidx]); }
    if k == IITD_TRUNC { return ty_truncated(ov[oidx]); }
    if k == IITD_SUBDIVIDE2 { return ty_subdivided(ov[oidx], 1); }
    if k == IITD_SUBDIVIDE4 { return ty_subdivided(ov[oidx], 2); }
    if k == IITD_ONENTH { return ty_one_nth(ov[oidx], f >> 16); }
    if k == IITD_SAMEVECWIDTH {
        let e = decode_fixed(ov);
        let t = ov[oidx];
        return ty_with_elem(t, e);
    }
    if k == IITD_VECELEMENT { return types[ov[oidx]].a; }
    if k == IITD_VECOFBITCASTS { return ty_vec_integer(ov[oidx]); }
    fatal("unsupported intrinsic type descriptor");
    return -1;
}

// Intrinsic::getType
fn intr_get_type(id: i64, ov: const i32[:]) -> i32 {
    let nargs, va = intr_table(id);
    dpos = 0;
    var tys: i32[>..] = [];
    let rt = decode_fixed(ov);
    tys.push(rt);
    while dpos < iitk.len { let a = decode_fixed(ov); tys.push(a); }
    let at = ints.len as i32;
    for t in tys { ints.push(t); }
    return ty_func_run(at, tys.len, va);
}

// ---------------------------------------------------------------------------------------------
// Names

recursive fn mangled_type(out: u8[>..]&, t: i32) {
    let k = types[t].kind;
    if k == TK_PTR { out.push('p'); format_u64_dec(out, types[t].n as u64); return; }
    if k == TK_ARRAY { out.push('a'); format_u64_dec(out, types[t].cnt as u64); mangled_type(out, types[t].a); return; }
    if k == TK_STRUCT {
        if (types[t].flags & TF_NAMED) != 0 {
            out.append("s_");
            if types[t].name >= 0 { out.append(sbytes(types[t].name)); }
            else { fatal("intrinsic overloaded on an unnamed struct type is not supported"); }
        } else {
            out.append("sl_");
            for j in types[t].cnt { mangled_type(out, ty_field(t, j)); }
        }
        out.push('s');
        return;
    }
    if k == TK_FUNC {
        out.append("f_");
        mangled_type(out, ty_fn_ret(t));
        for j in ty_fn_nparams(t) { mangled_type(out, ty_fn_param(t, j)); }
        if ty_fn_vararg(t) { out.append("vararg"); }
        out.push('f');
        return;
    }
    if k == TK_FVEC || k == TK_SVEC {
        if k == TK_SVEC { out.append("nx"); }
        out.push('v');
        format_u64_dec(out, types[t].cnt as u64);
        mangled_type(out, types[t].a);
        return;
    }
    if k == TK_TARGETEXT { fatal("intrinsic overloaded on a target extension type is not supported"); }
    if k == TK_VOID { out.append("isVoid"); return; }
    if k == TK_METADATA { out.append("Metadata"); return; }
    if k == TK_HALF { out.append("f16"); return; }
    if k == TK_BFLOAT { out.append("bf16"); return; }
    if k == TK_FLOAT { out.append("f32"); return; }
    if k == TK_DOUBLE { out.append("f64"); return; }
    if k == TK_X86_FP80 { out.append("f80"); return; }
    if k == TK_FP128 { out.append("f128"); return; }
    if k == TK_PPC_FP128 { out.append("ppcf128"); return; }
    if k == TK_X86_AMX { out.append("x86amx"); return; }
    if k == TK_INT { out.push('i'); format_u64_dec(out, types[t].n as u64); return; }
    if k == TK_BYTE { out.push('b'); format_u64_dec(out, types[t].n as u64); return; }
    fatal("unhandled type in intrinsic name mangling");
}

// Intrinsic::getName(id, OverloadTys)
fn intr_full_name(id: i64, ov: const i32[:]) -> u8[>..] {
    var r: u8[>..] = [];
    r.append(intr_name(id));
    for t in ov { r.push('.'); mangled_type(r, t); }
    return r;
}

// ---------------------------------------------------------------------------------------------
// Attributes (Intrinsic::getAttributes). Set items: "name", "name:N" (int attrs), "captures:N",
// "memory:N", "range:LO:HI" (bit width from the parameter type).

fn intr_attr_set(text: const u8[:], ty: i32) -> i32 {
    var xs: i32[>..] = [];
    each_split(text, ' ') {
        let item = it;
        var c = 0;
        while c < item.len && item[c] != ':' { c++; }
        if c == item.len {
            var k: i64 = -1;
            for n, i in ATTR_NAMES { if i > 0 && n == item { k = i; } }
            if k < 0 { fatal(str("unknown intrinsic attribute '", item, "'")); }
            xs.push(attr_enum(k));
        } else {
            let key = item[..c];
            let rest = item[c + 1..];
            if key == "range" {
                var d = 0;
                while rest[d] != ':' { d++; }
                let lo = parse_dec_i64(rest[..d]);
                let hi = parse_dec_i64(rest[d + 1..]);
                let it_ = ty_scalar(ty);
                let at = words.len;
                words.push(ty_bits(it_) as u64);
                words.push(c_int(it_, lo) as u64);
                words.push(c_int(it_, hi) as u64);
                xs.push(attr_int(AK_Range, at as u64));
            } else {
                let v = parse_dec_i64(rest) as u64;
                var k: i64 = -1;
                if key == "captures" { k = AK_Captures; }
                else if key == "memory" { k = AK_Memory; }
                else if key == "align" { k = AK_Alignment; }
                else { for n, i in ATTR_NAMES { if i > 0 && n == key { k = i; } } }
                if k < 0 { fatal(str("unknown intrinsic attribute '", key, "'")); }
                xs.push(attr_int(k, v));
            }
        }
    };
    return aset_get(xs);
}

fn parse_dec_i64(s: const u8[:]) -> i64 {
    var neg = false;
    var i = 0;
    if s.len > 0 && s[0] == '-' { neg = true; i = 1; }
    var v: i64 = 0;
    while i < s.len { v = v * 10 + (s[i] - '0') as i64; i++; }
    return if neg { -v } else { v };
}

// AttributeList for intrinsic id with function type fty.
fn intr_attributes(id: i64, fty: i32) -> i32 {
    if id <= 0 { return 0; }
    let np = ty_fn_nparams(fty);
    var sets: i32[>..] = [];
    for k in np + 2 { sets.push(0); }
    let ai = hexv(INTR_ARG_ATTR, id, 3);
    let st = hexv(INTR_ARGINFO_START, ai, 4);
    let n = hexv(INTR_ARGINFO_COUNT, ai, 2);
    for j in n {
        let argno = hexv(INTR_ARGPAIR_NO, st + j, 2);
        let si = hexv(INTR_ARGPAIR_SET, st + j, 2);
        // FT->getContainedType(ArgNo): 0 = return type
        let cty = if argno == 0 { ty_fn_ret(fty) } else { ty_fn_param(fty, argno - 1) };
        let s = intr_attr_set(INTR_ARGSETS[si], cty);
        // AttributeList index: 0 = return -> slot 1; k -> param k-1 -> slot k+1
        sets[argno + 1] = s;
    }
    let fi = hexv(INTR_FN_ATTR, id, 2);
    if fi != 255 { sets[0] = intr_attr_set(INTR_FNSETS[fi], -1); }
    return alist_get(sets);
}

// Intrinsic::hasStructReturnType
fn intr_has_struct_return(id: i64) -> bool {
    intr_table(id);
    return iitk.len > 0 && iitk[0] as i64 == IITD_STRUCT;
}
