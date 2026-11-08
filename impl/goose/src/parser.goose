// Recursive-descent parser for textual LLVM IR. Port of llvm/lib/AsmParser/LLParser.cpp
// (module structure, forward references, numbering rules, instructions, constants, attributes, metadata).
import std;
import os;
import ir;
import bignum;
import apfloat;
import lexer;
import datalayout;
import printer;

// ---------------------------------------------------------------------------------------------
// Parser state

var gnum: i32[>..];            // numbered globals @N
var gfwd_st: i32 = -1;         // forward-referenced named globals (placeholders, by name)
var gfwd_num: i32[>..];        // numbered global forward refs
var name2type: i32[>..];       // string id -> named struct type
var numbered_types: i32[>..];  // %N = type
var md_slots: i32[>..];        // !N -> md id
var attr_grps: i32[>..];       // #N -> attribute set id (-1 undefined)
var name2comdat: i32[>..];
var md2val: i32[>..];          // md id -> MetadataAsValue value id

struct GrpRef { kind: i32, target: i32, idx: i32, grp: i32 }
let GR_FN = 0;        // function: target = function value, fn attrs
let GR_CALL = 1;      // call: target = instruction value
let GR_GVAR = 2;      // global variable attributes
var grp_refs: GrpRef[>..];

// Per-function
var cur_fn: i32 = -1;
var fn_numbered: i32[>..<];
var fwd_local_st: i32 = -1;
var fwd_local_num: i32[>..<];
var fwd_local_count: i64 = 0;

// Scratch stacks shared by the recursive parse functions (mark/resize discipline).
var tstack: i32[>..<];
var vstack: i32[>..<];
var mstack: i32[>..<];
var astack: i32[>..<];

fn idx_get(arr: i32[>..]&, k: i32) -> i32 { if k < arr.len { arr[k] } else { -1 } }
fn idx_set(arr: i32[>..]&, k: i32, v: i32) {
    while arr.len <= k { arr.push(-1); }
    arr[k] = v;
}

fn expect_punct(c: u8, what: const u8[:]) {
    if !tok_punct(c) { perr(str("expected ", what)); }
    lex();
}
fn eat_punct(c: u8) -> bool { if tok_punct(c) { lex(); return true; } return false; }
fn eat_kw(s: const u8[:]) -> bool { if tok_is(s) { lex(); return true; } return false; }
fn expect_kw(s: const u8[:]) { if !tok_is(s) { perr(str("expected '", s, "'")); } lex(); }

fn tok_uint() -> i64 {
    if tk != T_INT || tneg { perr("expected integer"); }
    let v = bn_word(tnum, 0);
    return v as! i64;
}
fn parse_uint() -> i64 { let v = tok_uint(); lex(); return v; }
fn parse_sint() -> i64 {
    if tk != T_INT { perr("expected integer"); }
    let v = bn_word(tnum, 0) as! i64;
    let r = if tneg { -v } else { v };
    lex();
    return r;
}

fn tstr_id() -> i32 { intern(tstr) }

// ---------------------------------------------------------------------------------------------
// Types

fn get_named_type(nm: i32) -> i32 {
    var t = idx_get(name2type, nm);
    if t < 0 {
        t = ty_named_struct(nm);
        idx_set(name2type, nm, t);
    }
    return t;
}

fn get_numbered_type(n: i64) -> i32 {
    while numbered_types.len <= n { numbered_types.push(-1); }
    if numbered_types[n] < 0 { numbered_types[n] = ty_named_struct(-1); }
    return numbered_types[n];
}

// parseType: base type followed by function-type / pointer suffixes.
recursive fn parse_type() -> i32 {
    var t: i32 = -1;
    if tk == T_TYPE {
        t = ttype;
        lex();
        if t == T_PTR && tok_is("addrspace") {
            lex();
            expect_punct('(', "'('");
            let a = parse_uint();
            expect_punct(')', "')'");
            t = ty_ptr(a);
        }
    } else if tk == T_LVAR {
        t = get_named_type(tstr_id());
        lex();
    } else if tk == T_LID {
        t = get_numbered_type(tuint);
        lex();
    } else if tok_punct('{') {
        lex();
        t = parse_struct_body_literal(false);
    } else if tok_punct('[') {
        lex();
        let n = parse_uint();
        expect_kw("x");
        let et = parse_type();
        expect_punct(']', "']'");
        t = ty_array(et, n);
    } else if tok_punct('<') {
        lex();
        if tok_punct('{') {
            lex();
            t = parse_struct_body_literal(true);
            expect_punct('>', "'>'");
        } else {
            var scalable = false;
            if tok_is("vscale") { lex(); expect_kw("x"); scalable = true; }
            let n = parse_uint();
            expect_kw("x");
            let et = parse_type();
            expect_punct('>', "'>'");
            t = ty_vector(et, n, scalable);
        }
    } else if tok_is("target") {
        perr("target extension types are not supported yet");
    } else {
        perr("expected type");
    }
    // suffixes
    loop {
        if tok_punct('(') {
            lex();
            let mark = tstack.len;
            tstack.push(t);
            var vararg = false;
            if !tok_punct(')') {
                loop {
                    if tk == T_DOTS { lex(); vararg = true; break; }
                    let pt = parse_type();
                    // parameter attributes are not allowed in function types; names are ignored
                    tstack.push(pt);
                    if !eat_punct(',') { break; }
                }
            }
            expect_punct(')', "')' in function type");
            let at = ints.len as i32;
            for k in mark..tstack.len { ints.push(tstack[k]); }
            let n = tstack.len - mark;
            tstack.resize(mark);
            t = ty_func_run(at, n, vararg);
            continue;
        }
        if tok_punct('*') { perr("ptr* is invalid - use ptr instead"); }
        break;
    }
    return t;
}

// after '{' (or '<{')
recursive fn parse_struct_body_literal(packed: bool) -> i32 {
    let mark = tstack.len;
    if !tok_punct('}') {
        loop {
            let et = parse_type();
            tstack.push(et);
            if !eat_punct(',') { break; }
        }
    }
    expect_punct('}', "'}'");
    let at = ints.len as i32;
    for k in mark..tstack.len { ints.push(tstack[k]); }
    let n = tstack.len - mark;
    tstack.resize(mark);
    return ty_struct_run(at, n, packed);
}

// %T = type ...
fn parse_named_type_def(t: i32) {
    if tok_is("opaque") { lex(); return; }
    var packed = false;
    if tok_punct('<') { lex(); packed = true; }
    if !tok_punct('{') {
        // e.g. %T = type i32 is not a struct definition; LLVM makes it an alias. Unsupported.
        perr("only struct type definitions are supported");
    }
    lex();
    let mark = tstack.len;
    if !tok_punct('}') {
        loop {
            let et = parse_type();
            tstack.push(et);
            if !eat_punct(',') { break; }
        }
    }
    expect_punct('}', "'}'");
    if packed { expect_punct('>', "'>'"); }
    let at = ints.len as i32;
    for k in mark..tstack.len { ints.push(tstack[k]); }
    let n = tstack.len - mark;
    tstack.resize(mark);
    ty_set_body(t, at, n, packed);
}

// ---------------------------------------------------------------------------------------------
// Values

fn ty_is_valid_elem(t: i32) -> bool { true }

fn make_fwd(ty: i32) -> i32 { new_val(VK_FWD, ty, -1, 0) }

// Local value lookup / forward reference (PerFunctionState::getVal).
fn get_local_by_name(nm: i32, ty: i32) -> i32 {
    let st = globs[glob_of(cur_fn)].symtab;
    let v = symtab_lookup(st, nm);
    if v >= 0 {
        if vals[v].ty != ty { perr(str("'%", sbytes(nm), "' defined with type '", type_str(vals[v].ty), "' but expected '", type_str(ty), "'")); }
        return v;
    }
    let f = symtab_lookup(fwd_local_st, nm);
    if f >= 0 {
        if vals[f].ty != ty { perr(str("'%", sbytes(nm), "' defined with type '", type_str(vals[f].ty), "' but expected '", type_str(ty), "'")); }
        return f;
    }
    if ty == T_LABEL {
        // BasicBlock::Create(Context, Name, &F): named block, in the symbol table right away
        let b = new_block(-1);
        blocks[block_of(b)].parent = cur_fn;
        symtab_set_name(st, b, sbytes(nm), false);
        return b;
    }
    let ph = make_fwd(ty);
    vals[ph].name = nm;
    symtab_insert_raw(fwd_local_st, ph);
    fwd_local_count += 1;
    return ph;
}

fn get_local_by_id(n: i64, ty: i32) -> i32 {
    if n < fn_numbered.len {
        let v = fn_numbered[n];
        if vals[v].ty != ty { perr(str("'%", n, "' defined with type '", type_str(vals[v].ty), "' but expected '", type_str(ty), "'")); }
        return v;
    }
    while fwd_local_num.len <= n { fwd_local_num.push(-1); }
    let f = fwd_local_num[n];
    if f >= 0 {
        if vals[f].ty != ty { perr(str("'%", n, "' defined with type '", type_str(vals[f].ty), "' but expected '", type_str(ty), "'")); }
        return f;
    }
    var ph: i32 = -1;
    if ty == T_LABEL {
        ph = new_block(-1);
        blocks[block_of(ph)].parent = cur_fn;
    } else {
        ph = make_fwd(ty);
    }
    fwd_local_num[n] = ph;
    fwd_local_count += 1;
    return ph;
}

// Defining a local: resolve any forward reference (RAUW) and number it if unnamed.
fn define_local(v: i32, name_tok: i64, nm: i32, num: i64) {
    let st = globs[glob_of(cur_fn)].symtab;
    if name_tok == T_LVAR {
        let f = symtab_lookup(fwd_local_st, nm);
        if f >= 0 {
            if vals[f].ty != vals[v].ty { perr("instruction forward referenced with type mismatch"); }
            symtab_remove(fwd_local_st, f);
            fwd_local_count -= 1;
            rauw(f, v);
            vals[f].kind = VK_DEAD;
        }
        if symtab_lookup(st, nm) >= 0 { perr(str("multiple definition of local value named '", sbytes(nm), "'")); }
        symtab_set_name(st, v, sbytes(nm), false);
        return;
    }
    // numbered (explicit or implicit)
    var n = num;
    if n < 0 { n = fn_numbered.len; }
    if n != fn_numbered.len { perr(str("instruction expected to be numbered '%", fn_numbered.len, "'")); }
    if n < fwd_local_num.len && fwd_local_num[n] >= 0 {
        let f = fwd_local_num[n];
        fwd_local_num[n] = -1;
        fwd_local_count -= 1;
        if vals[f].ty != vals[v].ty { perr("instruction forward referenced with type mismatch"); }
        rauw(f, v);
        vals[f].kind = VK_DEAD;
    }
    fn_numbered.push(v);
}

// Global lookup (getGlobalVal): placeholders are unnamed i8 globals, RAUW'd later.
fn get_global_by_name(nm: i32, ty: i32) -> i32 {
    if types[ty].kind != TK_PTR { perr("global variable reference must have pointer type"); }
    let st = modules[cur_module].symtab;
    let v = symtab_lookup(st, nm);
    if v >= 0 { return v; }
    let f = symtab_lookup(gfwd_st, nm);
    if f >= 0 { return f; }
    let ph = new_glob(VK_GVAR, ty, -1, 0);
    globs[glob_of(ph)].vty = T_I8;
    globs[glob_of(ph)].linkage = LK_EXTERN_WEAK as u8;
    vals[ph].name = nm;
    symtab_insert_raw(gfwd_st, ph);
    vals[ph].kind = VK_GVAR;
    return ph;
}

fn get_global_by_id(n: i64, ty: i32) -> i32 {
    if n < gnum.len && gnum[n] >= 0 { return gnum[n]; }
    let f = idx_get(gfwd_num, n as i32);
    if f >= 0 { return f; }
    let ph = new_glob(VK_GVAR, ty, -1, 0);
    globs[glob_of(ph)].vty = T_I8;
    idx_set(gfwd_num, n as i32, ph);
    return ph;
}

// After creating global gv with the given name: resolve forward references.
fn resolve_global_fwd(gv: i32, nm: i32, num: i64) {
    var f: i32 = -1;
    if nm >= 0 {
        f = symtab_lookup(gfwd_st, nm);
        if f >= 0 { symtab_remove(gfwd_st, f); }
    } else {
        f = idx_get(gfwd_num, num as i32);
        if f >= 0 { gfwd_num[num] = -1; }
    }
    if f >= 0 {
        rauw_with_constants(f, gv);
        vals[f].kind = VK_DEAD;
    }
}

// Value::replaceAllUsesWith including Constant::handleOperandChange for constant users.
recursive fn rauw_with_constants(old: i32, nv: i32) {
    while vals[old].first_use >= 0 {
        let u = vals[old].first_use;
        let user = uses[u].user;
        if is_constant(user) && !is_global(user) {
            const_handle_operand_change(user, old, nv);
            continue;
        }
        use_set(u, nv);
    }
}

// Constant::handleOperandChange: replace From by To in a uniqued constant (replaceOperandsInPlace
// when no equal constant exists, otherwise RAUW to the existing one and destroy this one).
recursive fn const_handle_operand_change(c: i32, from: i32, to: i32) {
    let mark = vstack.len;
    for k in vals[c].nops {
        let o = uses[vals[c].ops + k].val;
        vstack.push(if o == from { to } else { o });
    }
    let kind = vals[c].kind as i64;
    let ty = vals[c].ty;
    var cs = csts[vals[c].sub];
    cs.hash = cst_hash(kind, ty, cs, vstack[mark..]);
    // look for an existing equal constant
    var existing: i32 = -1;
    if cst_tab.len > 0 {
        let mask = cst_tab.len - 1;
        var j = (cs.hash as i64) & mask;
        loop {
            let e = cst_tab[j];
            if e == -1 { break; }
            if e >= 0 && e != c && csts[vals[e].sub].hash == cs.hash && cst_eq(e, kind, ty, cs, vstack[mark..]) { existing = e; break; }
            j = (j + 1) & mask;
        }
    }
    if existing >= 0 {
        vstack.resize(mark);
        rauw_with_constants(c, existing);
        cst_remove(c);
        drop_all_refs(c);
        vals[c].kind = VK_DEAD;
        return;
    }
    cst_remove(c);
    for k in vals[c].nops {
        if uses[vals[c].ops + k].val == from { set_op(c, k, to); }
    }
    vstack.resize(mark);
    csts[vals[c].sub].hash = cs.hash;
    cst_insert(c);
}

fn cst_find_slot(c: i32) -> i64 {
    let mask = cst_tab.len - 1;
    var j = (csts[vals[c].sub].hash as i64) & mask;
    loop {
        let e = cst_tab[j];
        if e == -1 { return -1; }
        if e == c { return j; }
        j = (j + 1) & mask;
    }
}
fn cst_remove(c: i32) {
    if cst_tab.len == 0 { return; }
    let j = cst_find_slot(c);
    if j >= 0 { cst_tab[j] = -2; }
}
fn cst_insert(c: i32) {
    let mask = cst_tab.len - 1;
    var j = (csts[vals[c].sub].hash as i64) & mask;
    while cst_tab[j] >= 0 { j = (j + 1) & mask; }
    cst_tab[j] = c;
}

// ---------------------------------------------------------------------------------------------
// Constants and values

fn tnum_to_int_const(ty: i32) -> i32 {
    // APSInt -> extOrTrunc to the type's width
    let bits = ty_bits(ty);
    var w: u32[>..<] = [];
    bn_copy(w, tnum);
    let nw = (bits + 63) / 64;
    var ws: u64[>..] = [];
    for k in max(nw, 2) { ws.push(bn_word(w, k)); }
    var neg = tneg;
    if tnum_hex_bits > 0 && tnum_hex_signed {
        // s0x: sign-extend from its bit width
        let hb = tnum_hex_bits;
        if hb < bits && bn_bit(w, hb - 1) {
            // sign extend: set bits hb..bits-1
            for b in hb..(nw * 64) { ws[b / 64] = ws[b / 64] | ((1 as u64) << (b % 64)); }
        }
    }
    if neg {
        // two's complement negate over nw words
        var carry: u64 = 1;
        for k in ws.len {
            let x = ~ws[k];
            let s = x + carry;
            carry = if carry == 1 && s == 0 { 1 } else { 0 };
            ws[k] = s;
        }
    }
    if bits <= 128 { return c_int_words(ty, ws[0], ws[1]); }
    return c_int_wide(ty, ws);
}

fn fp_kind_of(ty: i32) -> i64 { types[ty].kind as i64 }

fn parse_fp_const(ty: i32) -> i32 {
    if !ty_is_fp(ty) { perr("floating point constant invalid for type"); }
    let k = fp_kind_of(ty);
    if tk == T_FPLIT {
        var s: u8[>..] = [];
        s.append(tstr);
        lex();
        let body: const u8[:] = if s.len > 0 && (s[0] == '+' || s[0] == '-') { s[1..] } else { s };
        let neg = s.len > 0 && s[0] == '-';
        if body == "inf" {
            let lo, hi = fp_encode(k, neg, 0, 0, 0, true);
            return c_fp(ty, lo, hi);
        }
        if body == "qnan" || starts_with(body, "nan(") || starts_with(body, "snan(") {
            // build the NaN: quiet unless snan; payload from the hex digits
            let f = fp_fmt(k);
            var pl: u32[>..<] = [];
            let open = find(body, "(");
            if body != "qnan" {
                var i = open + 1;
                if body[i] == '0' && body[i + 1] == 'x' { i += 2; }
                while i < body.len && body[i] != ')' { bn_mul_small(pl, 16); bn_add_small(pl, hexdig(body[i]) as u32); i++; }
            }
            let fb = f.p - 1;
            if !starts_with(body, "snan") { bn_add_small(pl, 0); var q: u32[>..<] = []; bn_set_u64(q, 1); bn_shl(q, fb - 1); for kk in q.len { while pl.len <= kk { pl.push(0); } pl[kk] = pl[kk] | q[kk]; } }
            let emask: u64 = (1 << f.ebits) - 1;
            let sb: u64 = if neg { 1 } else { 0 };
            if f.total <= 64 { return c_fp(ty, (sb << (f.total - 1)) | (emask << fb) | bn_word(pl, 0), 0); }
            if k == TK_X86_FP80 { return c_fp(ty, bn_word(pl, 0) | 0x8000000000000000, (sb << 15) | emask); }
            return c_fp(ty, bn_word(pl, 0), (sb << 63) | (emask << 48) | bn_word(pl, 1));
        }
        let lo, hi, ok = fp_parse_decimal(k, s);
        if !ok { perr("invalid floating point literal"); }
        return c_fp(ty, lo, hi);
    }
    if tk == T_FPHEXD {
        let bits = tfp_lo;
        lex();
        if k == TK_DOUBLE { return c_fp(ty, bits, 0); }
        if k == TK_HALF || k == TK_BFLOAT || k == TK_FLOAT {
            let lo, hi = fp_convert(TK_DOUBLE, k, bits, 0);
            return c_fp(ty, lo, hi);
        }
        perr("floating point constant invalid for type");
    }
    if tk == T_FPBITS {
        let f = fp_fmt(k);
        if tfp_bits != f.total { perr("float hex literal has incorrect number of bits"); }
        let lo = tfp_lo;
        let hi = tfp_hi;
        lex();
        return c_fp(ty, lo, hi);
    }
    perr("expected floating point constant");
    return -1;
}

fn get_md_as_value(m: i32) -> i32 {
    let v = idx_get(md2val, m);
    if v >= 0 { return v; }
    let nv = new_val(VK_MDVAL, T_METADATA, m, 0);
    idx_set(md2val, m, nv);
    return nv;
}

fn get_inline_asm(ty: i32, a: i32, c: i32, side: bool, alignstack: bool, intel: bool, unwind: bool) -> i32 {
    for v, i in vals {
        if v.kind == VK_INLINEASM && v.ty == ty {
            let x = asms[v.sub];
            if x.asm_ == a && x.cons == c && (x.side != 0) == side && (x.align != 0) == alignstack && (x.dialect != 0) == intel && (x.unwind != 0) == unwind { return i as i32; }
        }
    }
    let s = asms.len as i32;
    asms.push(Asm { asm_: a, cons: c, side: if side { 1 } else { 0 }, align: if alignstack { 1 } else { 0 }, dialect: if intel { 1 } else { 0 }, unwind: if unwind { 1 } else { 0 } });
    return new_val(VK_INLINEASM, ty, s, 0);
}

fn binop_from_kw(s: const u8[:]) -> i64 {
    if s == "add" { return OP_ADD; } if s == "fadd" { return OP_FADD; } if s == "sub" { return OP_SUB; }
    if s == "fsub" { return OP_FSUB; } if s == "mul" { return OP_MUL; } if s == "fmul" { return OP_FMUL; }
    if s == "udiv" { return OP_UDIV; } if s == "sdiv" { return OP_SDIV; } if s == "fdiv" { return OP_FDIV; }
    if s == "urem" { return OP_UREM; } if s == "srem" { return OP_SREM; } if s == "frem" { return OP_FREM; }
    if s == "shl" { return OP_SHL; } if s == "lshr" { return OP_LSHR; } if s == "ashr" { return OP_ASHR; }
    if s == "and" { return OP_AND; } if s == "or" { return OP_OR; } if s == "xor" { return OP_XOR; }
    return -1;
}

fn cast_from_kw(s: const u8[:]) -> i64 {
    if s == "trunc" { return OP_TRUNC; } if s == "zext" { return OP_ZEXT; } if s == "sext" { return OP_SEXT; }
    if s == "fptoui" { return OP_FPTOUI; } if s == "fptosi" { return OP_FPTOSI; } if s == "uitofp" { return OP_UITOFP; }
    if s == "sitofp" { return OP_SITOFP; } if s == "fptrunc" { return OP_FPTRUNC; } if s == "fpext" { return OP_FPEXT; }
    if s == "ptrtoint" { return OP_PTRTOINT; } if s == "ptrtoaddr" { return OP_PTRTOADDR; } if s == "inttoptr" { return OP_INTTOPTR; }
    if s == "bitcast" { return OP_BITCAST; } if s == "addrspacecast" { return OP_ADDRSPACECAST; }
    return -1;
}

fn parse_wrap_flags(opc: i64) -> u8 {
    var fl: u8 = 0;
    loop {
        if (opc == OP_ADD || opc == OP_SUB || opc == OP_MUL || opc == OP_SHL || opc == OP_TRUNC) && tok_is("nuw") { lex(); fl |= FL_NUW; continue; }
        if (opc == OP_ADD || opc == OP_SUB || opc == OP_MUL || opc == OP_SHL || opc == OP_TRUNC) && tok_is("nsw") { lex(); fl |= FL_NSW; continue; }
        if (opc == OP_UDIV || opc == OP_SDIV || opc == OP_LSHR || opc == OP_ASHR) && tok_is("exact") { lex(); fl |= FL_EXACT; continue; }
        if opc == OP_OR && tok_is("disjoint") { lex(); fl |= FL_DISJOINT; continue; }
        if (opc == OP_ZEXT || opc == OP_UITOFP) && tok_is("nneg") { lex(); fl |= FL_NNEG; continue; }
        if opc == OP_ICMP && tok_is("samesign") { lex(); fl |= FL_SAMESIGN; continue; }
        break;
    }
    return fl;
}

fn parse_fmf() -> u8 {
    var f: u8 = 0;
    loop {
        if tok_is("fast") { f |= FMF_FAST; lex(); continue; }
        if tok_is("nnan") { f |= FMF_NNAN; lex(); continue; }
        if tok_is("ninf") { f |= FMF_NINF; lex(); continue; }
        if tok_is("nsz") { f |= FMF_NSZ; lex(); continue; }
        if tok_is("arcp") { f |= FMF_ARCP; lex(); continue; }
        if tok_is("contract") { f |= FMF_CONTRACT; lex(); continue; }
        if tok_is("reassoc") { f |= FMF_REASSOC; lex(); continue; }
        if tok_is("afn") { f |= FMF_AFN; lex(); continue; }
        break;
    }
    return f;
}

fn parse_gep_flags() -> u8 {
    var f: u8 = 0;
    loop {
        if tok_is("inbounds") { f |= GEP_INBOUNDS | GEP_NUSW; lex(); continue; }
        if tok_is("nusw") { f |= GEP_NUSW; lex(); continue; }
        if tok_is("nuw") { f |= GEP_NUW; lex(); continue; }
        break;
    }
    return f;
}

fn icmp_pred(s: const u8[:]) -> i64 {
    if s == "eq" { return 32; } if s == "ne" { return 33; } if s == "ugt" { return 34; } if s == "uge" { return 35; }
    if s == "ult" { return 36; } if s == "ule" { return 37; } if s == "sgt" { return 38; } if s == "sge" { return 39; }
    if s == "slt" { return 40; } if s == "sle" { return 41; }
    return -1;
}
fn fcmp_pred(s: const u8[:]) -> i64 {
    if s == "false" { return 0; } if s == "oeq" { return 1; } if s == "ogt" { return 2; } if s == "oge" { return 3; }
    if s == "olt" { return 4; } if s == "ole" { return 5; } if s == "one" { return 6; } if s == "ord" { return 7; }
    if s == "uno" { return 8; } if s == "ueq" { return 9; } if s == "ugt" { return 10; } if s == "uge" { return 11; }
    if s == "ult" { return 12; } if s == "ule" { return 13; } if s == "une" { return 14; } if s == "true" { return 15; }
    return -1;
}

fn parse_cmp_pred(fp: bool) -> i64 {
    if tk != T_KW { perr("expected comparison predicate"); }
    let p = if fp { fcmp_pred(tok_text()) } else { icmp_pred(tok_text()) };
    if p < 0 { perr("expected comparison predicate"); }
    lex();
    return p;
}

// GEP result type: ptr, or vector of ptr if the base or any index is a vector.
fn gep_result_type(base_ty: i32, idx_start: i64) -> i32 {
    if ty_is_vector(base_ty) { return base_ty; }
    for k in idx_start..vstack.len {
        let it = vals[vstack[k]].ty;
        if ty_is_vector(it) { return ty_vector(base_ty, types[it].cnt, types[it].kind == TK_SVEC); }
    }
    return base_ty;
}

// Type of an indexed element (GetElementPtrInst::getIndexedType) for GEP validation (not checked here).

// splat (ty v)
recursive fn make_splat(ty: i32, v: i32) -> i32 {
    if !ty_is_vector(ty) { perr("constant expression type mismatch: splat requires vector type"); }
    let n = types[ty].cnt;
    let mark = vstack.len;
    for k in n { vstack.push(v); }
    let r = c_aggregate(ty, vstack[mark..]);
    vstack.resize(mark);
    return r;
}

// parseValID + convertValIDToValue for a known type. Handles constants, locals, globals, blocks, metadata.
recursive fn parse_value(ty: i32) -> i32 {
    if tk == T_LVAR {
        if cur_fn < 0 { perr("local value used outside a function"); }
        let nm = tstr_id();
        lex();
        return get_local_by_name(nm, ty);
    }
    if tk == T_LID {
        if cur_fn < 0 { perr("local value used outside a function"); }
        let n = tuint;
        lex();
        return get_local_by_id(n, ty);
    }
    if ty == T_LABEL { perr("expected a basic block"); }
    if ty == T_METADATA {
        let m = parse_metadata_operand();
        return get_md_as_value(m);
    }
    return parse_constant(ty);
}

recursive fn parse_constant(ty: i32) -> i32 {
    if tk == T_GVAR { let nm = tstr_id(); lex(); return get_global_by_name(nm, ty); }
    if tk == T_GID { let n = tuint; lex(); return get_global_by_id(n, ty); }
    if tk == T_INT {
        if !ty_is_int(ty) { perr("integer constant must have integer type"); }
        let c = tnum_to_int_const(ty);
        lex();
        return c;
    }
    if tk == T_FPLIT || tk == T_FPHEXD || tk == T_FPBITS { return parse_fp_const(ty); }
    if tk == T_KW {
        let w = tok_text();
        if w == "true" || w == "false" {
            let isT = w == "true";
            lex();
            if !ty_is_int(ty) || ty_bits(ty) != 1 { perr("integer constant must have integer type"); }
            return c_int(ty, if isT { 1 } else { 0 });
        }
        if w == "null" { lex(); if types[ty].kind != TK_PTR { perr("null must be a pointer type"); } return c_simple(VK_CNULL, ty); }
        if w == "none" { lex(); return c_simple(VK_CTOKENNONE, ty); }
        if w == "undef" { lex(); return c_undef(ty); }
        if w == "poison" { lex(); return c_poison(ty); }
        if w == "zeroinitializer" {
            lex();
            return c_null(ty);
        }
        if w == "c" {
            lex();
            if tk != T_STR { perr("expected string"); }
            if !ty_is_array(ty) || types[types[ty].a].kind != TK_INT || types[types[ty].a].n != 8 { perr("constant expression type mismatch"); }
            if tstr.len != types[ty].cnt { perr("constant expression type mismatch: string length"); }
            let mark = vstack.len;
            for b in tstr { vstack.push(c_int(T_I8, b as i64)); }
            lex();
            let r = c_aggregate(ty, vstack[mark..]);
            vstack.resize(mark);
            return r;
        }
        if w == "splat" {
            lex();
            expect_punct('(', "'('");
            let et = parse_type();
            let v = parse_value(et);
            expect_punct(')', "')'");
            return make_splat(ty, v);
        }
        if w == "blockaddress" { return parse_blockaddress(ty); }
        if w == "dso_local_equivalent" || w == "no_cfi" {
            perr("dso_local_equivalent/no_cfi constants are not supported yet");
        }
        if w == "asm" {
            lex();
            var side = false;
            var als = false;
            var intel = false;
            var unw = false;
            loop {
                if tok_is("sideeffect") { side = true; lex(); continue; }
                if tok_is("alignstack") { als = true; lex(); continue; }
                if tok_is("inteldialect") { intel = true; lex(); continue; }
                if tok_is("unwind") { unw = true; lex(); continue; }
                break;
            }
            if tk != T_STR { perr("expected asm string"); }
            let a = tstr_id();
            lex();
            expect_punct(',', "','");
            if tk != T_STR { perr("expected constraint string"); }
            let c = tstr_id();
            lex();
            return get_inline_asm(ty, a, c, side, als, intel, unw);
        }
        // constant expressions
        let cop = cast_from_kw(w);
        if cop >= 0 {
            lex();
            var fl: u8 = 0;
            expect_punct('(', "'('");
            let st = parse_type();
            let v = parse_value(st);
            expect_kw("to");
            let dt = parse_type();
            expect_punct(')', "')'");
            if dt != ty { perr("constant expression type mismatch"); }
            let mark = vstack.len;
            vstack.push(v);
            let r = c_expr(cop, dt, vstack[mark..], fl, 0, -1, -1);
            vstack.resize(mark);
            return r;
        }
        let bop = binop_from_kw(w);
        if bop >= 0 {
            lex();
            let fl = parse_wrap_flags(bop);
            expect_punct('(', "'('");
            let t1 = parse_type();
            let a = parse_value(t1);
            expect_punct(',', "','");
            let t2 = parse_type();
            let b = parse_value(t2);
            expect_punct(')', "')'");
            let mark = vstack.len;
            vstack.push(a);
            vstack.push(b);
            let r = c_expr(bop, t1, vstack[mark..], fl, 0, -1, -1);
            vstack.resize(mark);
            return r;
        }
        if w == "getelementptr" {
            lex();
            var fl = parse_gep_flags();
            var inr: i32 = -1;
            if tok_is("inrange") { perr("inrange is not supported yet"); }
            expect_punct('(', "'('");
            let sty = parse_type();
            expect_punct(',', "','");
            let mark = vstack.len;
            let bt = parse_type();
            let base = parse_value(bt);
            vstack.push(base);
            while eat_punct(',') {
                let it = parse_type();
                let iv = parse_value(it);
                vstack.push(iv);
            }
            expect_punct(')', "')'");
            let rt = gep_result_type(bt, mark + 1);
            let r = c_expr(OP_GEP, rt, vstack[mark..], fl, 0, sty, inr);
            vstack.resize(mark);
            return r;
        }
        if w == "extractelement" || w == "insertelement" || w == "shufflevector" {
            perr("vector constant expressions are not supported yet");
        }
        perr(str("expected value token, got '", w, "'"));
    }
    if tok_punct('{') {
        lex();
        if !ty_is_struct(ty) { perr("constant expression type mismatch: struct literal for non-struct type"); }
        let mark = vstack.len;
        if !tok_punct('}') {
            loop {
                let et = parse_type();
                let v = parse_value(et);
                vstack.push(v);
                if !eat_punct(',') { break; }
            }
        }
        expect_punct('}', "'}'");
        if (vstack.len - mark) != types[ty].cnt { perr("constant expression type mismatch: struct element count"); }
        let r = c_aggregate(ty, vstack[mark..]);
        vstack.resize(mark);
        return r;
    }
    if tok_punct('<') {
        lex();
        if tok_punct('{') {
            lex();
            let mark = vstack.len;
            if !tok_punct('}') {
                loop {
                    let et = parse_type();
                    let v = parse_value(et);
                    vstack.push(v);
                    if !eat_punct(',') { break; }
                }
            }
            expect_punct('}', "'}'");
            expect_punct('>', "'>'");
            let r = c_aggregate(ty, vstack[mark..]);
            vstack.resize(mark);
            return r;
        }
        if !ty_is_vector(ty) { perr("vector constant must have vector type"); }
        let mark = vstack.len;
        if !tok_punct('>') {
            loop {
                let et = parse_type();
                let v = parse_value(et);
                vstack.push(v);
                if !eat_punct(',') { break; }
            }
        }
        expect_punct('>', "'>'");
        if (vstack.len - mark) != types[ty].cnt { perr("constant expression type mismatch: vector element count"); }
        let r = c_aggregate(ty, vstack[mark..]);
        vstack.resize(mark);
        return r;
    }
    if tok_punct('[') {
        lex();
        if !ty_is_array(ty) { perr("constant expression type mismatch: array literal for non-array type"); }
        let mark = vstack.len;
        if !tok_punct(']') {
            loop {
                let et = parse_type();
                let v = parse_value(et);
                vstack.push(v);
                if !eat_punct(',') { break; }
            }
        }
        expect_punct(']', "']'");
        if (vstack.len - mark) != types[ty].cnt { perr("constant expression type mismatch: array element count"); }
        let r = c_aggregate(ty, vstack[mark..]);
        vstack.resize(mark);
        return r;
    }
    perr("expected value token");
    return -1;
}

// blockaddress(@f, %bb)
var ba_fwd: i32[>..];   // pending: placeholder value, function name id, block name id, block number (triples)

fn parse_blockaddress(ty: i32) -> i32 {
    lex();
    expect_punct('(', "'('");
    if tk != T_GVAR { perr("expected function name in blockaddress"); }
    let fnm = tstr_id();
    lex();
    expect_punct(',', "','");
    var bnm: i32 = -1;
    var bnum: i64 = -1;
    if tk == T_LVAR { bnm = tstr_id(); } else if tk == T_LID { bnum = tuint; } else { perr("expected basic block name in blockaddress"); }
    lex();
    expect_punct(')', "')'");
    let st = modules[cur_module].symtab;
    let f = symtab_lookup(st, fnm);
    if f >= 0 && f == cur_fn {
        // inside the function being parsed: get or create the block
        let b = if bnm >= 0 { get_local_by_name(bnm, T_LABEL) } else { get_local_by_id(bnum, T_LABEL) };
        return make_blockaddress(f, b);
    }
    if f >= 0 && globs[glob_of(f)].is_decl == 0 {
        // already defined function
        let b = if bnm >= 0 { symtab_lookup(globs[glob_of(f)].symtab, bnm) } else { -1 };
        if b < 0 { perr("referenced value is not a basic block"); }
        return make_blockaddress(f, b);
    }
    // forward reference: placeholder global, resolved after the function body
    let ph = new_glob(VK_GVAR, ty, -1, 0);
    globs[glob_of(ph)].vty = T_I8;
    ba_fwd.push(ph);
    ba_fwd.push(fnm);
    ba_fwd.push(bnm);
    ba_fwd.push(bnum as i32);
    return ph;
}

fn make_blockaddress(f: i32, b: i32) -> i32 {
    let mark = vstack.len;
    vstack.push(f);
    vstack.push(b);
    let r = cst_get(VK_BLOCKADDR, ty_ptr(0), cst_none(), vstack[mark..]);
    vstack.resize(mark);
    return r;
}

fn resolve_blockaddress_fwd(f: i32) {
    let fnm = vals[f].name;
    var k = 0;
    while k < ba_fwd.len {
        if ba_fwd[k] >= 0 && ba_fwd[k + 1] == fnm {
            let ph = ba_fwd[k];
            let bnm = ba_fwd[k + 2];
            let bnum = ba_fwd[k + 3];
            var b: i32 = -1;
            if bnm >= 0 { b = symtab_lookup(globs[glob_of(f)].symtab, bnm); }
            else if bnum >= 0 && bnum < fn_numbered.len { b = fn_numbered[bnum]; }
            if b < 0 || vals[b].kind != VK_BLOCK { perr("referenced value is not a basic block"); }
            let ba = make_blockaddress(f, b);
            rauw_with_constants(ph, ba);
            vals[ph].kind = VK_DEAD;
            ba_fwd[k] = -1;
        }
        k += 4;
    }
}

recursive fn parse_type_and_value() -> i32 {
    let t = parse_type();
    return parse_value(t);
}

// ---------------------------------------------------------------------------------------------
// Metadata

fn get_md_slot(n: i64) -> i32 {
    let m = idx_get(md_slots, n as i32);
    if m >= 0 { return m; }
    let t = md_get(MK_TEMP, n as i32, [], true);
    idx_set(md_slots, n as i32, t);
    return t;
}

// A metadata operand as it appears in an MDNode or as a call argument: !N, !"str", !{...}, null, <ty> <val>
recursive fn parse_metadata_operand() -> i32 {
    if tk == T_EXCL {
        lex();
        if tk == T_INT { let n = parse_uint(); return get_md_slot(n); }
        if tk == T_STR { let m = md_string(tstr); lex(); return m; }
        if tok_punct('{') { return parse_md_tuple(false); }
        perr("expected metadata operand");
    }
    if tk == T_MDVAR {
        perr("specialized metadata nodes (!DI...) are not supported yet");
    }
    if tok_is("distinct") { lex(); if tk != T_EXCL { perr("expected '!'"); } lex(); return parse_md_tuple(true); }
    if tok_is("null") { lex(); return -1; }
    // value as metadata
    let t = parse_type();
    if t == T_METADATA { return parse_metadata_operand(); }
    let v = parse_value(t);
    return md_value(v);
}

// after '!' with current token '{'
recursive fn parse_md_tuple(distinct: bool) -> i32 {
    expect_punct('{', "'{'");
    let mark = mstack.len;
    if !tok_punct('}') {
        loop {
            let m = parse_metadata_operand();
            mstack.push(m);
            if !eat_punct(',') { break; }
        }
    }
    expect_punct('}', "'}'");
    let r = md_get(MK_TUPLE, -1, mstack[mark..], distinct);
    mstack.resize(mark);
    return r;
}

// !N = [distinct] !{...}
fn parse_md_def() {
    lex();  // '!'
    let n = parse_uint();
    expect_punct('=', "'='");
    var distinct = false;
    if tok_is("distinct") { lex(); distinct = true; }
    if tk == T_MDVAR { perr("specialized metadata nodes (!DI...) are not supported yet"); }
    if tk != T_EXCL { perr("expected metadata node"); }
    lex();
    let m = parse_md_tuple(distinct);
    let old = idx_get(md_slots, n as i32);
    if old >= 0 && mds[old].kind == MK_TEMP {
        // overwrite the placeholder in place with the definition, so references stay valid
        let d = mds[m];
        mds[old].kind = d.kind;
        mds[old].distinct = d.distinct;
        mds[old].ops = d.ops;
        mds[old].nops = d.nops;
        mds[old].extra = d.extra;
        mds[old].hash = d.hash;
        if d.distinct == 0 {
            // make the old id the canonical uniqued node if the new one was freshly created
            md_rebuild_tab_prefer(old, m);
        }
        return;
    }
    if old >= 0 { perr(str("Metadata id is already used")); }
    idx_set(md_slots, n as i32, m);
}

fn md_rebuild_tab_prefer(keep: i32, drop: i32) {
    // mark the duplicate as distinct garbage so it is never found again
    mds[drop].distinct = 1;
    mds[drop].kind = MK_TEMP;
    md_rebuild_tab();
}

fn parse_md_attachment_kind() -> i32 {
    if tk != T_MDVAR { perr("expected metadata kind"); }
    let k = md_kind_id(tstr);
    lex();
    return k;
}

// attachment node: !N or !{...}
fn parse_md_node_ref() -> i32 {
    if tk == T_EXCL {
        lex();
        if tk == T_INT { let n = parse_uint(); return get_md_slot(n); }
        if tok_punct('{') { return parse_md_tuple(false); }
    }
    if tok_is("distinct") { lex(); lex(); return parse_md_tuple(true); }
    perr("expected metadata node");
    return -1;
}

// Instruction/global attachments: pairs pushed to astack then stored sorted by kind.
fn store_attachments(mark: i64) -> i32, i32 {
    // sort pairs by kind (stable; later duplicates replace earlier)
    let n = (astack.len - mark) / 2;
    if n == 0 { return 0, 0; }
    let at = md_att.len as i32;
    var cnt = 0;
    // insertion into md_att in kind order
    for k in n {
        let kind = astack[mark + 2 * k];
        let node = astack[mark + 2 * k + 1];
        // replace existing
        var replaced = false;
        for j in cnt { if md_att[at + 2 * j] == kind { md_att[at + 2 * j + 1] = node; replaced = true; } }
        if replaced { continue; }
        md_att.push(kind);
        md_att.push(node);
        cnt++;
        var j = cnt - 1;
        while j > 0 && md_att[at + 2 * (j - 1)] > md_att[at + 2 * j] {
            let k0 = md_att[at + 2 * j];
            let n0 = md_att[at + 2 * j + 1];
            md_att[at + 2 * j] = md_att[at + 2 * (j - 1)];
            md_att[at + 2 * j + 1] = md_att[at + 2 * (j - 1) + 1];
            md_att[at + 2 * (j - 1)] = k0;
            md_att[at + 2 * (j - 1) + 1] = n0;
            j--;
        }
    }
    astack.resize(mark);
    return at, cnt as i32;
}

// ---------------------------------------------------------------------------------------------
// Attributes

fn attr_kind_by_name(s: const u8[:]) -> i64 {
    for n, i in ATTR_NAMES { if i > 0 && n == s { return i; } }
    return -1;
}

fn parse_paren_uint() -> i64 {
    expect_punct('(', "'('");
    let v = parse_uint();
    expect_punct(')', "')'");
    return v;
}

fn modref_kw() -> i64 {
    if tok_is("none") { return 0; }
    if tok_is("read") { return 1; }
    if tok_is("write") { return 2; }
    if tok_is("readwrite") { return 3; }
    return -1;
}

// MemoryEffects as 2 bits per IRMemLocation (ArgMem, InaccessibleMem, ErrnoMem, Other, TargetMem0, TargetMem1).

fn parse_memory_attr() -> u64 {
    lex();
    ignore_colon = true;
    expect_punct('(', "'('");
    var me: u64 = 0;
    // re-lex current token with colon ignored is not needed: locations are followed by ':' punct
    loop {
        var locs: i64 = -1;   // -2 = all target
        if tok_is("argmem") { locs = 0; } else if tok_is("inaccessiblemem") { locs = 1; }
        else if tok_is("errnomem") { locs = 2; } else if tok_is("target_mem0") { locs = 4; }
        else if tok_is("target_mem1") { locs = 5; } else if tok_is("target_mem") { locs = -2; }
        if locs != -1 {
            lex();
            expect_punct(':', "':' after location");
        }
        let mr = modref_kw();
        if mr < 0 { perr("expected access kind (none, read, write, readwrite)"); }
        lex();
        if locs == -1 { me = me_all(mr); }
        else if locs == -2 { me = me_set(me_set(me, 4, mr), 5, mr); }
        else { me = me_set(me, locs, mr); }
        if eat_punct(')') { break; }
        expect_punct(',', "','");
    }
    ignore_colon = false;
    return me;
}

// CaptureComponents: None=0, AddressIsNull=1, Address=3, ReadProvenance=4, Provenance=12.
fn parse_captures_attr() -> u64 {
    ignore_colon = true;
    lex();
    expect_punct('(', "'('");
    var other: u64 = 0;
    var ret: u64 = 0;
    var has_ret = false;
    var in_ret = false;
    loop {
        if tok_is("ret") { lex(); expect_punct(':', "':'"); has_ret = true; in_ret = true; }
        var c: u64 = 0;
        if tok_is("none") { c = 0; }
        else if tok_is("address_is_null") { c = 1; }
        else if tok_is("address") { c = 3; }
        else if tok_is("provenance") { c = 12; }
        else if tok_is("read_provenance") { c = 4; }
        else { perr("expected one of 'none', 'address', 'address_is_null', 'provenance' or 'read_provenance'"); }
        lex();
        if in_ret { ret |= c; } else { other |= c; }
        if eat_punct(')') { break; }
        expect_punct(',', "','");
    }
    ignore_colon = false;
    if !has_ret { ret = other; }
    return other | (ret << 8);
}

fn parse_allockind() -> u64 {
    lex();
    expect_punct('(', "'('");
    if tk != T_STR { perr("expected allockind value"); }
    var k: u64 = 0;
    each_split(tstr, ',') {
        if it == "alloc" { k |= 1; } else if it == "realloc" { k |= 2; } else if it == "free" { k |= 4; }
        else if it == "uninitialized" { k |= 8; } else if it == "zeroed" { k |= 16; } else if it == "aligned" { k |= 32; }
        else { perr("unknown allockind"); }
    };
    lex();
    expect_punct(')', "')'");
    return k;
}

fn parse_nofpclass() -> u64 {
    lex();
    expect_punct('(', "'('");
    var m: u64 = 0;
    loop {
        if tk == T_INT { m |= parse_uint() as u64; }
        else if tk == T_KW {
            let w = tok_text();
            // FPClassTest bits: snan 1, qnan 2, ninf 4, nnorm 8, nsub 16, nzero 32, pzero 64, psub 128, pnorm 256, pinf 512
            if w == "nan" { m |= 3; } else if w == "snan" { m |= 1; } else if w == "qnan" { m |= 2; }
            else if w == "inf" { m |= 4 | 512; } else if w == "ninf" { m |= 4; } else if w == "pinf" { m |= 512; }
            else if w == "zero" { m |= 32 | 64; } else if w == "nzero" { m |= 32; } else if w == "pzero" { m |= 64; }
            else if w == "sub" { m |= 16 | 128; } else if w == "nsub" { m |= 16; } else if w == "psub" { m |= 128; }
            else if w == "norm" { m |= 8 | 256; } else if w == "nnorm" { m |= 8; } else if w == "pnorm" { m |= 256; }
            else if w == "all" { m |= 1023; }
            else { perr("unknown nofpclass test"); }
            lex();
        } else { break; }
        if tok_punct(')') { break; }
    }
    expect_punct(')', "')'");
    return m;
}

// range(i32 lo, hi): words pushed to `words`: [bits, lo words..., hi words...]; i1 = index
fn parse_range_attr() -> u64 {
    lex();
    expect_punct('(', "'('");
    let t = parse_type();
    if !ty_is_int(t) { perr("the range must have integer type!"); }
    let bits = ty_bits(t);
    let lo = parse_int_words(t);
    expect_punct(',', "','");
    let hi = parse_int_words(t);
    expect_punct(')', "')'");
    let at = words.len;
    words.push(bits as u64);
    words.push(lo as u64);
    words.push(hi as u64);
    return at as u64;
}

// parse an integer literal into a uniqued ConstantInt of type t (returns value id)
fn parse_int_words(t: i32) -> i32 {
    if tk != T_INT { perr("expected integer"); }
    let c = tnum_to_int_const(t);
    lex();
    return c;
}

// Parses one attribute if the current token starts one; returns attr id or -1.
// ctx: 0 = param/return, 1 = function (in a definition), 2 = attribute group body.
recursive fn parse_one_attr(ctx: i64) -> i32 {
    if tk == T_STR {
        var k: u8[>..] = [];
        k.append(tstr);
        lex();
        if eat_punct('=') {
            if tk != T_STR { perr("expected string attribute value"); }
            var v: u8[>..] = [];
            v.append(tstr);
            lex();
            return attr_str(k, v, v.len > 0);
        }
        return attr_str(k, "", false);
    }
    if tk != T_KW { return -1; }
    let w = tok_text();
    if w == "align" {
        lex();
        var a = 0;
        if ctx == 2 { expect_punct('=', "'='"); a = parse_uint(); }
        else if tok_punct('(') { a = parse_paren_uint(); }
        else { a = parse_uint(); }
        return attr_int(AK_Alignment, a as u64);
    }
    if w == "alignstack" {
        lex();
        var a = 0;
        if ctx == 2 { expect_punct('=', "'='"); a = parse_uint(); } else { a = parse_paren_uint(); }
        return attr_int(AK_StackAlignment, a as u64);
    }
    if w == "dereferenceable" || w == "dereferenceable_or_null" {
        let kk = if w == "dereferenceable" { AK_Dereferenceable } else { AK_DereferenceableOrNull };
        lex();
        var a = 0;
        if ctx == 2 && tok_punct('=') { lex(); a = parse_uint(); } else { a = parse_paren_uint(); }
        return attr_int(kk, a as u64);
    }
    if w == "dead_on_return" {
        lex();
        var a: u64 = 0xFFFFFFFFFFFFFFFF;
        if tok_punct('(') { a = parse_paren_uint() as u64; }
        else if ctx == 2 && tok_punct('=') { lex(); a = parse_uint() as u64; }
        return attr_int(AK_DeadOnReturn, a);
    }
    if w == "allocsize" {
        lex();
        expect_punct('(', "'('");
        let e = parse_uint();
        var n: u64 = 0xFFFFFFFF;
        if eat_punct(',') { n = parse_uint() as u64; }
        expect_punct(')', "')'");
        return attr_int(AK_AllocSize, ((e as u64) << 32) | n);
    }
    if w == "vscale_range" {
        lex();
        expect_punct('(', "'('");
        let a = parse_uint();
        var b = a;
        if eat_punct(',') { b = parse_uint(); }
        expect_punct(')', "')'");
        return attr_int(AK_VScaleRange, ((a as u64) << 32) | (b as u64));
    }
    if w == "uwtable" {
        lex();
        var k: u64 = 2;
        if tok_punct('(') {
            lex();
            if tok_is("sync") { k = 1; } else if tok_is("async") { k = 2; } else { perr("expected unwind table kind"); }
            lex();
            expect_punct(')', "')'");
        }
        return attr_int(AK_UWTable, k);
    }
    if w == "memory" { return attr_int(AK_Memory, parse_memory_attr()); }
    if w == "captures" { return attr_int(AK_Captures, parse_captures_attr()); }
    if w == "nocapture" { lex(); return attr_int(AK_Captures, 0); }
    if w == "allockind" { return attr_int(AK_AllocKind, parse_allockind()); }
    if w == "nofpclass" { return attr_int(AK_NoFPClass, parse_nofpclass()); }
    if w == "range" { return attr_int(AK_Range, parse_range_attr()); }
    if w == "initializes" {
        lex();
        expect_punct('(', "'('");
        let at = words.len;
        words.push(0);
        var n: u64 = 0;
        loop {
            expect_punct('(', "'('");
            let lo = parse_sint();
            expect_punct(',', "','");
            let hi = parse_sint();
            expect_punct(')', "')'");
            words.push(lo as! u64);
            words.push(hi as! u64);
            n++;
            if !eat_punct(',') { break; }
        }
        expect_punct(')', "')'");
        words[at] = n;
        return attr_int(AK_Initializes, at as u64);
    }
    if w == "denormal_fpenv" { perr("denormal_fpenv attribute is not supported yet"); }
    let k = attr_kind_by_name(w);
    if k < 0 { return -1; }
    let cls = ATTR_CLASSES[k] as i64;
    if cls == ATTR_CLASS_TYPE {
        lex();
        var t: i32 = -1;
        if tok_punct('(') { lex(); t = parse_type(); expect_punct(')', "')'"); }
        return attr_type(k, t);
    }
    if cls != ATTR_CLASS_ENUM { perr(str("unsupported attribute '", w, "'")); }
    // function-only memory attributes on functions are upgraded to memory(...) — handled by caller
    lex();
    return attr_enum(k);
}

// Upgrade readnone/readonly/writeonly/argmemonly/... on functions to memory(...) (LLParser does this).
fn upgrade_fn_memory_attrs(mark: i64) {
    var me: u64 = 0xFFFFFFFFFFFFFFFF;  // unset
    var have = false;
    var i = mark;
    var outn = mark;
    let n = astack.len;
    var ro = false;
    var rn = false;
    var wo = false;
    while i < n {
        let a = astack[i];
        let k = attrs[a].kind as i64;
        if k == AK_ReadNone { rn = true; have = true; }
        else if k == AK_ReadOnly { ro = true; have = true; }
        else if k == AK_WriteOnly { wo = true; have = true; }
        else { astack[outn] = a; outn++; }
        i++;
    }
    astack.resize(outn);
    if !have { return; }
    // ME = readnone ? none : readonly ? read : writeonly ? write : all ; intersect if several
    var mr: i64 = 3;
    if rn { mr = 0; } else if ro && wo { mr = 0; } else if ro { mr = 1; } else if wo { mr = 2; }
    var d = me_all(mr);
    // combine with an explicit memory attribute
    for j in mark..astack.len {
        let a = astack[j];
        if attrs[a].kind as i64 == AK_Memory {
            let x = attrs[a].i1;
            var r: u64 = 0;
            for l in 6 { r = me_set(r, l, me_get(x, l) & me_get(d, l)); }
            astack[j] = attr_int(AK_Memory, r);
            return;
        }
    }
    astack.push(attr_int(AK_Memory, d));
}

// Parameter / return attributes (no groups).
recursive fn parse_param_attrs() -> i32 {
    let mark = astack.len;
    loop {
        let a = parse_one_attr(0);
        if a < 0 { break; }
        astack.push(a);
    }
    let s = aset_get(astack[mark..]);
    astack.resize(mark);
    return s;
}

// Function attributes after the signature: attrs and #N refs (recorded in grp_refs).
fn parse_fn_attrs(kind: i64, target: i32) -> i32 {
    let mark = astack.len;
    loop {
        if tk == T_ATTRGRP {
            grp_refs.push(GrpRef { kind: kind as i32, target: target, idx: 0, grp: tuint as i32 });
            lex();
            continue;
        }
        if tok_is("align") || tok_is("alignstack") || tok_is("section") || tok_is("partition") || tok_is("gc") || tok_is("prefix") || tok_is("prologue") || tok_is("personality") || tok_is("comdat") {
            if tok_is("alignstack") {
                lex();
                let v = parse_paren_uint();
                astack.push(attr_int(AK_StackAlignment, v as u64));
                continue;
            }
            break;
        }
        let a = parse_one_attr(1);
        if a < 0 { break; }
        astack.push(a);
    }
    upgrade_fn_memory_attrs(mark);
    let s = aset_get(astack[mark..]);
    astack.resize(mark);
    return s;
}

// attributes #N = { ... }
fn parse_attr_group_def() {
    lex();
    if tk != T_ATTRGRP { perr("expected attribute group id"); }
    let n = tuint;
    lex();
    expect_punct('=', "'='");
    expect_punct('{', "'{'");
    let mark = astack.len;
    while !tok_punct('}') {
        let a = parse_one_attr(2);
        if a < 0 { perr("unterminated attribute group"); }
        astack.push(a);
    }
    lex();
    upgrade_fn_memory_attrs(mark);
    let s = aset_get(astack[mark..]);
    astack.resize(mark);
    idx_set(attr_grps, n as i32, s);
}

fn merge_sets(a: i32, b: i32) -> i32 {
    if a == 0 { return b; }
    if b == 0 { return a; }
    let mark = astack.len;
    for k in asets[a].n { astack.push(attr_runs[asets[a].at + k]); }
    for k in asets[b].n { astack.push(attr_runs[asets[b].at + k]); }
    let s = aset_get(astack[mark..]);
    astack.resize(mark);
    return s;
}

fn alist_with_fn(l: i32, fnset: i32) -> i32 {
    let mark = astack.len;
    astack.push(fnset);
    for k in 1..alists[l].n { astack.push(alist_runs[alists[l].at + k]); }
    if alists[l].n == 0 { }
    let r = alist_get(astack[mark..]);
    astack.resize(mark);
    return r;
}

fn resolve_attr_groups() {
    for g in grp_refs {
        let s = idx_get(attr_grps, g.grp);
        if s < 0 { perr_at(0, str("unresolved attribute group reference #", g.grp)); }
        if g.kind == GR_FN {
            let gi = glob_of(g.target);
            let l = globs[gi].attrs;
            let cur = alist_fn(l);
            globs[gi].attrs = alist_with_fn(l, merge_sets(cur, s));
        } else if g.kind == GR_CALL {
            let ii = inst_of(g.target);
            let l = insts[ii].attrs;
            insts[ii].attrs = alist_with_fn(l, merge_sets(alist_fn(l), s));
        } else {
            let gi = glob_of(g.target);
            globs[gi].attrs = merge_sets(globs[gi].attrs, s);
        }
    }
    grp_refs.clear();
}

// ---------------------------------------------------------------------------------------------
// Globals

fn parse_linkage() -> i64 {
    if tk != T_KW { return -1; }
    let w = tok_text();
    var l: i64 = -1;
    if w == "private" { l = LK_PRIVATE; } else if w == "internal" { l = LK_INTERNAL; }
    else if w == "weak" { l = LK_WEAK_ANY; } else if w == "weak_odr" { l = LK_WEAK_ODR; }
    else if w == "linkonce" { l = LK_LINKONCE_ANY; } else if w == "linkonce_odr" { l = LK_LINKONCE_ODR; }
    else if w == "available_externally" { l = LK_AVAILABLE_EXTERNALLY; } else if w == "appending" { l = LK_APPENDING; }
    else if w == "common" { l = LK_COMMON; } else if w == "extern_weak" { l = LK_EXTERN_WEAK; }
    else if w == "external" { l = LK_EXTERNAL; }
    if l >= 0 { lex(); }
    return l;
}

struct GlobFlags { linkage: i64, has_linkage: bool, dso_local: bool, vis: i64, dll: i64, tls: i64, unnamed: i64, addrspace: i64, ext_init: bool }

fn parse_global_prefix() -> GlobFlags {
    var f = GlobFlags { linkage: LK_EXTERNAL, has_linkage: false, dso_local: false, vis: 0, dll: 0, tls: 0, unnamed: 0, addrspace: 0, ext_init: false };
    let l = parse_linkage();
    if l >= 0 { f.linkage = l; f.has_linkage = true; }
    loop {
        if tok_is("dso_local") { f.dso_local = true; lex(); continue; }
        if tok_is("dso_preemptable") { lex(); continue; }
        if tok_is("default") { f.vis = 0; lex(); continue; }
        if tok_is("hidden") { f.vis = 1; lex(); continue; }
        if tok_is("protected") { f.vis = 2; lex(); continue; }
        if tok_is("dllimport") { f.dll = 1; lex(); continue; }
        if tok_is("dllexport") { f.dll = 2; lex(); continue; }
        if tok_is("thread_local") {
            lex();
            f.tls = 1;
            if eat_punct('(') {
                if tok_is("localdynamic") { f.tls = 2; } else if tok_is("initialexec") { f.tls = 3; }
                else if tok_is("localexec") { f.tls = 4; } else { perr("expected localdynamic, initialexec or localexec"); }
                lex();
                expect_punct(')', "')'");
            }
            continue;
        }
        if tok_is("unnamed_addr") { f.unnamed = 2; lex(); continue; }
        if tok_is("local_unnamed_addr") { f.unnamed = 1; lex(); continue; }
        if tok_is("addrspace") { lex(); f.addrspace = parse_paren_uint(); continue; }
        if tok_is("externally_initialized") { f.ext_init = true; lex(); continue; }
        break;
    }
    return f;
}

fn apply_glob_flags(v: i32, f: GlobFlags) {
    let g = glob_of(v);
    globs[g].linkage = f.linkage as u8;
    globs[g].vis = f.vis as u8;
    globs[g].dll = f.dll as u8;
    globs[g].tls = f.tls as u8;
    globs[g].unnamed = f.unnamed as u8;
    globs[g].ext_init = if f.ext_init { 1 } else { 0 };
    var dso = f.dso_local;
    if f.linkage == LK_INTERNAL || f.linkage == LK_PRIVATE || f.vis != 0 { dso = true; }
    globs[g].dso_local = if dso { 1 } else { 0 };
}

fn get_comdat(nm: i32) -> i32 {
    var c = idx_get(name2comdat, nm);
    if c < 0 {
        c = comdats.len as i32;
        comdats.push(Comdat { name: nm, kind: 0 });
        idx_set(name2comdat, nm, c);
    }
    return c;
}

// [comdat [($name)]] for a global with name nm
fn parse_optional_comdat(nm: i32) -> i32 {
    if !tok_is("comdat") { return -1; }
    lex();
    if eat_punct('(') {
        if tk != T_COMDATVAR { perr("expected comdat variable"); }
        let c = get_comdat(tstr_id());
        lex();
        expect_punct(')', "')'");
        return c;
    }
    if nm < 0 { perr("comdat cannot be unnamed"); }
    return get_comdat(nm);
}

fn parse_align_value() -> u8 {
    let a = parse_uint();
    if a == 0 || (a & (a - 1)) != 0 { perr("alignment is not a power of two"); }
    return (log2_exact(a) + 1) as u8;
}

// @name = ... global / constant / alias / ifunc
fn parse_global_def(nm: i32, num: i64) {
    let f = parse_global_prefix();
    if tok_is("alias") || tok_is("ifunc") {
        let is_alias = tok_is("alias");
        lex();
        let vt = parse_type();
        expect_punct(',', "','");
        let at = parse_type();
        let aliasee = parse_constant(at);
        let pt = ty_ptr(f.addrspace);
        let v = new_glob(if is_alias { VK_ALIAS } else { VK_IFUNC }, pt, -1, 1);
        globs[glob_of(v)].vty = vt;
        apply_glob_flags(v, f);
        if nm >= 0 { symtab_set_name(modules[cur_module].symtab, v, sbytes(nm), true); }
        else { idx_set(gnum, num as i32, v); }
        set_op(v, 0, aliasee);
        module_append_global(v);
        resolve_global_fwd(v, nm, num);
        while eat_punct(',') {
            if tok_is("partition") { lex(); globs[glob_of(v)].partition = tstr_id(); lex(); continue; }
            perr("unknown alias property");
        }
        return;
    }
    var is_const = false;
    if tok_is("constant") { is_const = true; lex(); }
    else if tok_is("global") { lex(); }
    else { perr("expected 'global' or 'constant'"); }
    let vt = parse_type();
    var init: i32 = -1;
    // External linkage without initializer: "external" keyword or extern_weak
    let no_init = f.has_linkage && (f.linkage == LK_EXTERNAL || f.linkage == LK_EXTERN_WEAK);
    if !no_init { init = parse_constant(vt); }
    let pt = ty_ptr(f.addrspace);
    let v = new_glob(VK_GVAR, pt, -1, if init >= 0 { 1 } else { 0 });
    let g = glob_of(v);
    globs[g].vty = vt;
    globs[g].is_const = if is_const { 1 } else { 0 };
    globs[g].is_decl = if init >= 0 { 0 } else { 1 };
    globs[g].addrspace = f.addrspace as i32;
    if nm >= 0 { symtab_set_name(modules[cur_module].symtab, v, sbytes(nm), true); }
    else { idx_set(gnum, num as i32, v); }
    if init >= 0 { set_op(v, 0, init); }
    apply_glob_flags(v, f);
    module_append_global(v);
    resolve_global_fwd(v, nm, num);
    let mark = astack.len;
    while eat_punct(',') {
        if tok_is("section") { lex(); globs[g].section = tstr_id(); lex(); continue; }
        if tok_is("partition") { lex(); globs[g].partition = tstr_id(); lex(); continue; }
        if tok_is("align") { lex(); globs[g].align = parse_align_value(); continue; }
        if tok_is("code_model") {
            lex();
            if tk != T_STR { perr("expected code model"); }
            let s = tstr;
            var cm: u8 = 0;
            if s == "tiny" { cm = 1; } else if s == "small" { cm = 2; } else if s == "kernel" { cm = 3; }
            else if s == "medium" { cm = 4; } else if s == "large" { cm = 5; }
            globs[g].code_model = cm;
            lex();
            continue;
        }
        if tk == T_MDVAR {
            let k = parse_md_attachment_kind();
            let n = parse_md_node_ref();
            astack.push(k);
            astack.push(n);
            continue;
        }
        if tok_is("no_sanitize_address") { globs[g].sanitizer |= 1; lex(); continue; }
        if tok_is("no_sanitize_hwaddress") { globs[g].sanitizer |= 2; lex(); continue; }
        if tok_is("sanitize_memtag") { globs[g].sanitizer |= 4; lex(); continue; }
        if tok_is("sanitize_address_dyninit") { globs[g].sanitizer |= 8; lex(); continue; }
        let c = parse_optional_comdat(nm);
        if c >= 0 { globs[g].comdat = c; continue; }
        perr("unknown global variable property!");
    }
    let at, cnt = store_attachments(mark);
    globs[g].md = at;
    globs[g].nmd = cnt;
    // attributes (rare for globals)
    let amark = astack.len;
    loop {
        if tk == T_ATTRGRP { grp_refs.push(GrpRef { kind: GR_GVAR, target: v, idx: 0, grp: tuint as i32 }); lex(); continue; }
        let a = parse_one_attr(1);
        if a < 0 { break; }
        astack.push(a);
    }
    if astack.len > amark { globs[g].attrs = aset_get(astack[amark..]); }
    astack.resize(amark);
}

fn parse_cc() -> i32 {
    if tk != T_KW { return 0; }
    let w = tok_text();
    var c: i64 = -1;
    if w == "ccc" { c = 0; } else if w == "fastcc" { c = 8; } else if w == "coldcc" { c = 9; }
    else if w == "ghccc" { c = 10; } else if w == "anyregcc" { c = 13; } else if w == "preserve_mostcc" { c = 14; }
    else if w == "preserve_allcc" { c = 15; } else if w == "swiftcc" { c = 16; } else if w == "cxx_fast_tlscc" { c = 17; }
    else if w == "tailcc" { c = 18; } else if w == "swifttailcc" { c = 20; } else if w == "preserve_nonecc" { c = 21; }
    else if w == "x86_stdcallcc" { c = 64; } else if w == "x86_fastcallcc" { c = 65; } else if w == "x86_thiscallcc" { c = 70; }
    else if w == "x86_64_sysvcc" { c = 78; } else if w == "win64cc" { c = 79; } else if w == "x86_vectorcallcc" { c = 80; }
    else if w == "x86_regcallcc" { c = 92; } else if w == "x86_intrcc" { c = 83; }
    else if w == "cc" {
        lex();
        return parse_uint() as i32;
    }
    if c < 0 { return 0; }
    lex();
    return c as i32;
}

// define/declare
fn parse_function(is_define: bool) {
    lex();
    let f = parse_global_prefix();
    let cc = parse_cc();
    let retattrs = parse_param_attrs();
    let rt = parse_type();
    var nm: i32 = -1;
    var num: i64 = -1;
    if tk == T_GVAR { nm = tstr_id(); } else if tk == T_GID { num = tuint; } else { perr("expected function name"); }
    lex();
    expect_punct('(', "'('");
    // arguments
    let tmark = tstack.len;
    let amark = astack.len;    // per-arg attribute sets
    let nmark = vstack.len;    // arg names: string id or -1, or -2-N for numbered
    var vararg = false;
    if !tok_punct(')') {
        loop {
            if tk == T_DOTS { lex(); vararg = true; break; }
            let at = parse_type();
            let pa = parse_param_attrs();
            tstack.push(at);
            astack.push(pa);
            if tk == T_LVAR { vstack.push(tstr_id()); lex(); }
            else if tk == T_LID { vstack.push((-2 - tuint) as i32); lex(); }
            else { vstack.push(-1); }
            if !eat_punct(',') { break; }
        }
    }
    expect_punct(')', "')'");
    let rmark = ints.len as i32;
    ints.push(rt);
    for k in tmark..tstack.len { ints.push(tstack[k]); }
    let nparams = tstack.len - tmark;
    let fty = ty_func_run(rmark, nparams + 1, vararg);
    tstack.resize(tmark);
    // unnamed_addr, addrspace, fn attrs, section, comdat, align, gc, prefix, prologue, personality
    var unnamed: i64 = 0;
    if tok_is("unnamed_addr") { unnamed = 2; lex(); } else if tok_is("local_unnamed_addr") { unnamed = 1; lex(); }
    var fas: i64 = 0;
    if tok_is("addrspace") { lex(); fas = parse_paren_uint(); }
    // create the function now (attribute group refs need its id)
    let v = new_glob(VK_FUNC, ty_ptr(fas), -1, 0);
    let g = glob_of(v);
    globs[g].vty = fty;
    let fnattrs = parse_fn_attrs(GR_FN, v);
    var section: i32 = -1;
    var partition: i32 = -1;
    var comdat: i32 = -1;
    var align: u8 = 0;
    var gc: i32 = -1;
    var prefix: i32 = -1;
    var prologue: i32 = -1;
    var personality: i32 = -1;
    var pending_comdat_self = false;
    loop {
        if tok_is("section") { lex(); section = tstr_id(); lex(); continue; }
        if tok_is("partition") { lex(); partition = tstr_id(); lex(); continue; }
        if tok_is("comdat") {
            lex();
            if eat_punct('(') { comdat = get_comdat(tstr_id()); lex(); expect_punct(')', "')'"); }
            else { pending_comdat_self = true; }
            continue;
        }
        if tok_is("align") { lex(); align = parse_align_value(); continue; }
        if tok_is("prefalign") { perr("prefalign is not supported yet"); }
        if tok_is("gc") { lex(); gc = tstr_id(); lex(); continue; }
        if tok_is("prefix") { lex(); prefix = parse_type_and_value(); continue; }
        if tok_is("prologue") { lex(); prologue = parse_type_and_value(); continue; }
        if tok_is("personality") { lex(); personality = parse_type_and_value(); continue; }
        break;
    }
    // metadata attachments (function-level)
    let mmark = astack.len;
    while tk == T_MDVAR {
        let k = parse_md_attachment_kind();
        let n = parse_md_node_ref();
        astack.push(k);
        astack.push(n);
    }
    let mat, mcnt = store_attachments(mmark);
    // attribute list: [fn, ret, params...]
    let lmark = astack.len;
    astack.push(fnattrs);
    astack.push(retattrs);
    for k in amark..lmark { astack.push(astack[k]); }
    let al = alist_get(astack[lmark..]);
    astack.resize(amark);
    globs[g].attrs = al;
    globs[g].cc = cc;
    globs[g].section = section;
    globs[g].partition = partition;
    globs[g].align = align;
    globs[g].gc = gc;
    globs[g].md = mat;
    globs[g].nmd = mcnt;
    globs[g].unnamed = unnamed as u8;
    globs[g].addrspace = fas as i32;
    apply_glob_flags(v, f);
    globs[g].unnamed = unnamed as u8;
    if nm >= 0 {
        if symtab_lookup(modules[cur_module].symtab, nm) >= 0 { perr(str("invalid redefinition of function '", sbytes(nm), "'")); }
        symtab_set_name(modules[cur_module].symtab, v, sbytes(nm), true);
    } else {
        idx_set(gnum, num as i32, v);
    }
    if pending_comdat_self { comdat = get_comdat(nm); }
    globs[g].comdat = comdat;
    // hung-off operands: personality, prefix, prologue
    if personality >= 0 || prefix >= 0 || prologue >= 0 {
        // Function operand layout (Function::allocHungoffUselist): [personality, prefix, prologue]
        for k in 3 { add_op_slot(v); }
        if personality >= 0 { set_op(v, 0, personality); globs[g].has_personality = 1; }
        if prefix >= 0 { set_op(v, 1, prefix); globs[g].has_prefix = 1; }
        if prologue >= 0 { set_op(v, 2, prologue); globs[g].has_prologue = 1; }
    }
    // intrinsic?
    let nb = sbytes(vals[v].name);
    if vals[v].name >= 0 && starts_with(nb, "llvm.") { globs[g].intrinsic = 1; }
    module_append_global(v);
    resolve_global_fwd(v, nm, num);
    // arguments
    let args_at = ints.len as i32;
    for k in nparams { ints.push(-1); }
    globs[g].args = args_at;
    globs[g].nargs = nparams as i32;
    globs[g].symtab = new_symtab();
    for k in nparams {
        let a = new_arg(v, ty_fn_param(fty, k), k);
        ints[args_at + k] = a;
    }
    if !is_define {
        vstack.resize(nmark);
        globs[g].is_decl = 1;
        return;
    }
    globs[g].is_decl = 0;
    // function body
    cur_fn = v;
    fn_numbered.clear();
    fwd_local_num.clear();
    fwd_local_st = new_symtab();
    fwd_local_count = 0;
    for k in nparams {
        let a = ints[args_at + k];
        let an = vstack[nmark + k];
        if an >= 0 {
            if symtab_lookup(globs[g].symtab, an) >= 0 { perr(str("redefinition of argument '%", sbytes(an), "'")); }
            symtab_set_name(globs[g].symtab, a, sbytes(an), false);
        } else {
            let want = if an == -1 { fn_numbered.len } else { (-2 - an) as i64 };
            if want != fn_numbered.len { perr(str("argument expected to be numbered '%", fn_numbered.len, "'")); }
            fn_numbered.push(a);
        }
    }
    vstack.resize(nmark);
    if !tok_punct('{') { perr("expected '{' in function body"); }
    lex();
    parse_function_body(v);
    resolve_blockaddress_fwd(v);
    if fwd_local_count != 0 {
        // find one for the message
        for x in fwd_local_num { if x >= 0 { perr("use of undefined value"); } }
        perr("use of undefined value");
    }
    cur_fn = -1;
}

fn parse_function_body(fv: i32) {
    let st = globs[glob_of(fv)].symtab;
    if tok_punct('}') { perr("function body requires at least one basic block"); }
    while !tok_punct('}') {
        // basic block label
        var bb: i32 = -1;
        if tk == T_LABELSTR {
            let nm = intern(tstr);
            lex();
            bb = symtab_lookup(st, nm);
            if bb >= 0 {
                if vals[bb].kind != VK_BLOCK { perr("redefinition of value"); }
                if blocks[block_of(bb)].prev >= 0 || globs[glob_of(fv)].first_block == bb { perr(str("redefinition of label '", sbytes(nm), "'")); }
            } else {
                bb = new_block(-1);
                blocks[block_of(bb)].parent = fv;
                symtab_set_name(st, bb, sbytes(nm), false);
            }
        } else {
            var n: i64 = -1;
            if tk == T_LABELID { n = tuint; lex(); }
            let want = fn_numbered.len;
            if n >= 0 && n != want { perr(str("label expected to be numbered '", want, "'")); }
            if want < fwd_local_num.len && fwd_local_num[want] >= 0 {
                bb = fwd_local_num[want];
                fwd_local_num[want] = -1;
                fwd_local_count -= 1;
                if vals[bb].kind != VK_BLOCK { perr("label forward referenced as a value"); }
            } else {
                bb = new_block(-1);
                blocks[block_of(bb)].parent = fv;
            }
            fn_numbered.push(bb);
        }
        func_append_block(fv, bb);
        // instructions until a terminator
        loop {
            let iv = parse_instruction(bb);
            if is_terminator_op(iop(iv)) { break; }
        }
    }
    lex();
}

// Parses one instruction with its optional "%x =" and trailing metadata; appends it to bb.
fn parse_instruction(bb: i32) -> i32 {
    var name_tok: i64 = -1;
    var nm: i32 = -1;
    var num: i64 = -1;
    let start = ts;
    if tk == T_LVAR || tk == T_LID {
        name_tok = tk;
        if tk == T_LVAR { nm = tstr_id(); } else { num = tuint; }
        lex();
        expect_punct('=', "'=' after instruction name");
    }
    if tk != T_KW { perr("expected instruction opcode"); }
    let iv = parse_inst_body(bb);
    // trailing ", !kind !N" attachments
    let mark = astack.len;
    while tok_punct(',') {
        lex();
        if tk == T_MDVAR {
            let k = parse_md_attachment_kind();
            let n = parse_md_node_ref();
            astack.push(k);
            astack.push(n);
            continue;
        }
        perr("expected metadata after comma");
    }
    let at, cnt = store_attachments(mark);
    let ii = inst_of(iv);
    insts[ii].md = at;
    insts[ii].nmd = cnt;
    block_append_inst(bb, iv);
    let is_void = vals[iv].ty == T_VOID;
    if name_tok >= 0 && is_void { perr_at(start, "instructions returning void cannot have a name"); }
    if !is_void {
        if name_tok == T_LVAR { define_local(iv, T_LVAR, nm, -1); }
        else { define_local(iv, T_LID, -1, num); }
    }
    return iv;
}

fn parse_ordering() -> u8 {
    if tok_is("unordered") { lex(); return 1; }
    if tok_is("monotonic") { lex(); return 2; }
    if tok_is("acquire") { lex(); return 4; }
    if tok_is("release") { lex(); return 5; }
    if tok_is("acq_rel") { lex(); return 6; }
    if tok_is("seq_cst") { lex(); return 7; }
    perr("Expected ordering on atomic instruction");
    return 0;
}

fn parse_syncscope() -> i32 {
    if !tok_is("syncscope") { return -1; }
    lex();
    expect_punct('(', "'('");
    if tk != T_STR { perr("expected syncscope name"); }
    let s = tstr_id();
    lex();
    expect_punct(')', "')'");
    return s;
}

// ", align N" if present (consumes the comma only when followed by align)
fn parse_opt_comma_align(ii: i32) {
    if tok_punct(',') {
        let save = lpos;
        let sts = ts;
        lex();
        if tok_is("align") {
            lex();
            insts[ii].align = parse_align_value();
            return;
        }
        // not align: put the comma back
        lpos = sts;
        lex();
    }
}

fn mk_inst(opc: i64, ty: i32, opsv: const i32[:]) -> i32 {
    let v = new_inst(opc, ty, opsv.len);
    for k in opsv.len { set_op(v, k, opsv[k]); }
    return v;
}

fn rmw_op(s: const u8[:]) -> i64 {
    let names = ["xchg", "add", "sub", "and", "nand", "or", "xor", "max", "min", "umax", "umin", "fadd", "fsub",
                 "fmax", "fmin", "fmaximum", "fminimum", "uinc_wrap", "udec_wrap", "usub_cond", "usub_sat"];
    for n, i in names { if n == s { return i; } }
    return -1;
}

fn parse_inst_body(bb: i32) -> i32 {
    let w = tok_text();
    let opstart = ts;
    // tail call prefixes
    if w == "tail" || w == "musttail" || w == "notail" {
        let tkind: u8 = if w == "tail" { 1 } else if w == "musttail" { 2 } else { 3 };
        lex();
        if !tok_is("call") { perr("expected 'call'"); }
        return parse_call(tkind);
    }
    if w == "call" { return parse_call(0); }
    if w == "ret" {
        lex();
        if tk == T_TYPE && ttype == T_VOID { lex(); return new_inst(OP_RET, T_VOID, 0); }
        let v = parse_type_and_value();
        return mk_inst(OP_RET, T_VOID, [v]);
    }
    if w == "br" {
        lex();
        let t = parse_type();
        if t == T_LABEL {
            let d = parse_value(T_LABEL);
            return mk_inst(OP_BR, T_VOID, [d]);
        }
        let c = parse_value(t);
        expect_punct(',', "','");
        let tt = parse_type();
        let a = parse_value(T_LABEL);
        expect_punct(',', "','");
        let ft = parse_type();
        let b = parse_value(T_LABEL);
        return mk_inst(OP_CONDBR, T_VOID, [c, a, b]);
    }
    if w == "switch" {
        lex();
        let c = parse_type_and_value();
        expect_punct(',', "','");
        let lt = parse_type();
        let d = parse_value(T_LABEL);
        expect_punct('[', "'['");
        let mark = vstack.len;
        while !tok_punct(']') {
            let cv = parse_type_and_value();
            expect_punct(',', "','");
            let bt = parse_type();
            let dest = parse_value(T_LABEL);
            vstack.push(cv);
            vstack.push(dest);
        }
        lex();
        let ncases = (vstack.len - mark) / 2;
        let v = new_inst(OP_SWITCH, T_VOID, 2 + ncases * 2);
        vals[v].nops = 2;
        set_op(v, 0, c);
        set_op(v, 1, d);
        for k in ncases {
            vals[v].nops += 2;
            set_op(v, 2 + 2 * k, vstack[mark + 2 * k]);
            set_op(v, 3 + 2 * k, vstack[mark + 2 * k + 1]);
        }
        vstack.resize(mark);
        return v;
    }
    if w == "indirectbr" {
        lex();
        let a = parse_type_and_value();
        expect_punct(',', "','");
        expect_punct('[', "'['");
        let mark = vstack.len;
        vstack.push(a);
        if !tok_punct(']') {
            loop {
                let lt = parse_type();
                let d = parse_value(T_LABEL);
                vstack.push(d);
                if !eat_punct(',') { break; }
            }
        }
        expect_punct(']', "']'");
        let v = mk_inst(OP_INDIRECTBR, T_VOID, vstack[mark..]);
        vstack.resize(mark);
        return v;
    }
    if w == "unreachable" { lex(); return new_inst(OP_UNREACHABLE, T_VOID, 0); }
    if w == "fneg" {
        lex();
        let fm = parse_fmf();
        let a = parse_type_and_value();
        let v = mk_inst(OP_FNEG, vals[a].ty, [a]);
        insts[inst_of(v)].fmf = fm;
        return v;
    }
    let bop = binop_from_kw(w);
    if bop >= 0 {
        lex();
        var fl: u8 = 0;
        var fm: u8 = 0;
        if bop == OP_FADD || bop == OP_FSUB || bop == OP_FMUL || bop == OP_FDIV || bop == OP_FREM { fm = parse_fmf(); }
        else { fl = parse_wrap_flags(bop); }
        let a = parse_type_and_value();
        expect_punct(',', "','");
        let b = parse_value(vals[a].ty);
        let v = mk_inst(bop, vals[a].ty, [a, b]);
        insts[inst_of(v)].flags = fl;
        insts[inst_of(v)].fmf = fm;
        return v;
    }
    let cop = cast_from_kw(w);
    if cop >= 0 {
        lex();
        let fl = parse_wrap_flags(cop);
        var fm: u8 = 0;
        if cop == OP_FPTRUNC || cop == OP_FPEXT || cop == OP_UITOFP || cop == OP_SITOFP || cop == OP_FPTOUI || cop == OP_FPTOSI { fm = parse_fmf(); }
        let a = parse_type_and_value();
        expect_kw("to");
        let dt = parse_type();
        let v = mk_inst(cop, dt, [a]);
        insts[inst_of(v)].flags = fl;
        insts[inst_of(v)].fmf = fm;
        return v;
    }
    if w == "icmp" || w == "fcmp" {
        let fp = w == "fcmp";
        lex();
        var fl: u8 = 0;
        var fm: u8 = 0;
        if fp { fm = parse_fmf(); } else { fl = parse_wrap_flags(OP_ICMP); }
        let p = parse_cmp_pred(fp);
        let a = parse_type_and_value();
        expect_punct(',', "','");
        let b = parse_value(vals[a].ty);
        let at = vals[a].ty;
        let rt = if ty_is_vector(at) { ty_vector(T_I1, types[at].cnt, types[at].kind == TK_SVEC) } else { T_I1 };
        let v = mk_inst(if fp { OP_FCMP } else { OP_ICMP }, rt, [a, b]);
        insts[inst_of(v)].pred = p as u8;
        insts[inst_of(v)].flags = fl;
        insts[inst_of(v)].fmf = fm;
        return v;
    }
    if w == "phi" {
        lex();
        let fm = parse_fmf();
        let t = parse_type();
        let mark = vstack.len;
        loop {
            expect_punct('[', "'['");
            let val = parse_value(t);
            expect_punct(',', "','");
            let b = parse_value(T_LABEL);
            expect_punct(']', "']'");
            vstack.push(val);
            vstack.push(b);
            if !tok_punct(',') { break; }
            // ", [" continues; ", !md" ends
            let sts = ts;
            lex();
            if !tok_punct('[') { lpos = sts; lex(); break; }
        }
        let n = (vstack.len - mark) / 2;
        let v = new_inst(OP_PHI, t, n);
        for k in n {
            set_op(v, k, vstack[mark + 2 * k]);
            use_aux[vals[v].ops + k] = vstack[mark + 2 * k + 1];
        }
        vstack.resize(mark);
        insts[inst_of(v)].fmf = fm;
        return v;
    }
    if w == "select" {
        lex();
        let fm = parse_fmf();
        let c = parse_type_and_value();
        expect_punct(',', "','");
        let a = parse_type_and_value();
        expect_punct(',', "','");
        let b = parse_type_and_value();
        let v = mk_inst(OP_SELECT, vals[a].ty, [c, a, b]);
        insts[inst_of(v)].fmf = fm;
        return v;
    }
    if w == "freeze" {
        lex();
        let a = parse_type_and_value();
        return mk_inst(OP_FREEZE, vals[a].ty, [a]);
    }
    if w == "va_arg" {
        lex();
        let a = parse_type_and_value();
        expect_punct(',', "','");
        let t = parse_type();
        return mk_inst(OP_VAARG, t, [a]);
    }
    if w == "extractelement" {
        lex();
        let a = parse_type_and_value();
        expect_punct(',', "','");
        let b = parse_type_and_value();
        return mk_inst(OP_EXTRACTELEMENT, types[vals[a].ty].a, [a, b]);
    }
    if w == "insertelement" {
        lex();
        let a = parse_type_and_value();
        expect_punct(',', "','");
        let b = parse_type_and_value();
        expect_punct(',', "','");
        let c = parse_type_and_value();
        return mk_inst(OP_INSERTELEMENT, vals[a].ty, [a, b, c]);
    }
    if w == "shufflevector" {
        lex();
        let a = parse_type_and_value();
        expect_punct(',', "','");
        let b = parse_type_and_value();
        expect_punct(',', "','");
        let mt = parse_type();
        let m = parse_value(mt);
        // mask constant -> ints; result type <n x elem>
        let n = types[mt].cnt;
        let at = ints.len as i32;
        for k in n { ints.push(shuffle_mask_elem(m, k)); }
        let rt = ty_vector(types[vals[a].ty].a, n, types[mt].kind == TK_SVEC);
        let v = mk_inst(OP_SHUFFLEVECTOR, rt, [a, b]);
        insts[inst_of(v)].aux = at;
        insts[inst_of(v)].naux = n as i32;
        return v;
    }
    if w == "extractvalue" || w == "insertvalue" {
        let is_ins = w == "insertvalue";
        lex();
        let a = parse_type_and_value();
        var b: i32 = -1;
        if is_ins { expect_punct(',', "','"); b = parse_type_and_value(); }
        let at = ints.len as i32;
        var t = vals[a].ty;
        var n = 0;
        while tok_punct(',') {
            let sts = ts;
            lex();
            if tk != T_INT { lpos = sts; lex(); break; }
            let idx = parse_uint();
            ints.push(idx as i32);
            n++;
            if !ty_is_aggregate(t) { perr("invalid indices for extractvalue"); }
            t = ty_index(t, idx);
        }
        if n == 0 { perr("expected index"); }
        let v = if is_ins { mk_inst(OP_INSERTVALUE, vals[a].ty, [a, b]) } else { mk_inst(OP_EXTRACTVALUE, t, [a]) };
        insts[inst_of(v)].aux = at;
        insts[inst_of(v)].naux = n as i32;
        return v;
    }
    if w == "alloca" {
        lex();
        var bits: u8 = 0;
        if tok_is("inalloca") { lex(); bits |= 1; }
        if tok_is("swifterror") { lex(); bits |= 2; }
        let t = parse_type();
        var size: i32 = -1;
        var align: u8 = 0;
        var as_: i64 = 0;
        while eat_punct(',') {
            if tok_is("align") { lex(); align = parse_align_value(); continue; }
            if tok_is("addrspace") { lex(); as_ = parse_paren_uint(); continue; }
            if tk == T_MDVAR { lpos = ts; tk = T_PUNCT; tch = ','; lpos = ts; break; }
            size = parse_type_and_value();
        }
        if size < 0 { size = c_int(T_I32, 1); }
        if align == 0 { align = (log2_exact(dl_align(t, false)) + 1) as u8; }
        let v = mk_inst(OP_ALLOCA, ty_ptr(as_), [size]);
        let ii = inst_of(v);
        insts[ii].ty2 = t;
        insts[ii].align = align;
        insts[ii].bits = bits;
        insts[ii].as_ = as_ as i32;
        return v;
    }
    if w == "load" {
        lex();
        var atomic = false;
        var vol = false;
        if tok_is("atomic") { atomic = true; lex(); }
        if tok_is("volatile") { vol = true; lex(); }
        let t = parse_type();
        expect_punct(',', "','");
        let p = parse_type_and_value();
        let v = mk_inst(OP_LOAD, t, [p]);
        let ii = inst_of(v);
        if vol { insts[ii].bits = 1; }
        if atomic { insts[ii].ss = parse_syncscope(); insts[ii].ord = parse_ordering(); }
        parse_opt_comma_align(ii);
        if insts[ii].align == 0 { insts[ii].align = (log2_exact(dl_align(t, true)) + 1) as u8; }
        return v;
    }
    if w == "store" {
        lex();
        var atomic = false;
        var vol = false;
        if tok_is("atomic") { atomic = true; lex(); }
        if tok_is("volatile") { vol = true; lex(); }
        let a = parse_type_and_value();
        expect_punct(',', "','");
        let p = parse_type_and_value();
        let v = mk_inst(OP_STORE, T_VOID, [a, p]);
        let ii = inst_of(v);
        if vol { insts[ii].bits = 1; }
        if atomic { insts[ii].ss = parse_syncscope(); insts[ii].ord = parse_ordering(); }
        parse_opt_comma_align(ii);
        if insts[ii].align == 0 { insts[ii].align = (log2_exact(dl_align(vals[a].ty, true)) + 1) as u8; }
        return v;
    }
    if w == "fence" {
        lex();
        let ss = parse_syncscope();
        let o = parse_ordering();
        let v = new_inst(OP_FENCE, T_VOID, 0);
        insts[inst_of(v)].ord = o;
        insts[inst_of(v)].ss = ss;
        return v;
    }
    if w == "cmpxchg" {
        lex();
        var bits: u8 = 0;
        if tok_is("weak") { bits |= 2; lex(); }
        if tok_is("volatile") { bits |= 1; lex(); }
        let p = parse_type_and_value();
        expect_punct(',', "','");
        let c = parse_type_and_value();
        expect_punct(',', "','");
        let n = parse_type_and_value();
        let ss = parse_syncscope();
        let o1 = parse_ordering();
        let o2 = parse_ordering();
        let ct = vals[c].ty;
        let at = ints.len as i32;
        ints.push(ct);
        ints.push(T_I1);
        let rt = ty_struct_run(at, 2, false);
        let v = mk_inst(OP_CMPXCHG, rt, [p, c, n]);
        let ii = inst_of(v);
        insts[ii].bits = bits;
        insts[ii].ord = o1;
        insts[ii].ord2 = o2;
        insts[ii].ss = ss;
        parse_opt_comma_align(ii);
        if insts[ii].align == 0 { insts[ii].align = (log2_exact(dl_store_size(ct)) + 1) as u8; }
        return v;
    }
    if w == "atomicrmw" {
        lex();
        var bits: u8 = 0;
        if tok_is("volatile") { bits |= 1; lex(); }
        if tk != T_KW { perr("expected binary operation in atomicrmw"); }
        let opn = rmw_op(tok_text());
        if opn < 0 { perr("expected binary operation in atomicrmw"); }
        lex();
        let p = parse_type_and_value();
        expect_punct(',', "','");
        let a = parse_type_and_value();
        let ss = parse_syncscope();
        let o = parse_ordering();
        let v = mk_inst(OP_ATOMICRMW, vals[a].ty, [p, a]);
        let ii = inst_of(v);
        insts[ii].bits = bits;
        insts[ii].pred = opn as u8;
        insts[ii].ord = o;
        insts[ii].ss = ss;
        parse_opt_comma_align(ii);
        if insts[ii].align == 0 { insts[ii].align = (log2_exact(dl_store_size(vals[a].ty)) + 1) as u8; }
        return v;
    }
    if w == "getelementptr" {
        lex();
        let fl = parse_gep_flags();
        let sty = parse_type();
        expect_punct(',', "','");
        let mark = vstack.len;
        let base = parse_type_and_value();
        vstack.push(base);
        while tok_punct(',') {
            let sts = ts;
            lex();
            if tk == T_MDVAR { lpos = sts; lex(); break; }
            let iv = parse_type_and_value();
            vstack.push(iv);
        }
        let rt = gep_result_type(vals[base].ty, mark + 1);
        let v = mk_inst(OP_GEP, rt, vstack[mark..]);
        vstack.resize(mark);
        insts[inst_of(v)].ty2 = sty;
        insts[inst_of(v)].flags = fl;
        return v;
    }
    if w == "invoke" || w == "landingpad" || w == "resume" || w == "callbr" || w == "catchswitch" || w == "catchpad" || w == "cleanuppad" || w == "catchret" || w == "cleanupret" {
        perr(str("instruction '", w, "' is not supported yet"));
    }
    perr(str("expected instruction opcode, got '", w, "'"));
    return -1;
}

fn shuffle_mask_elem(m: i32, k: i64) -> i32 {
    let kind = vals[m].kind;
    if kind == VK_AGGZERO { return 0; }
    if kind == VK_UNDEF || kind == VK_POISON { return -1; }
    let e = op(m, k);
    if vals[e].kind == VK_CINT { return cint_sext(e) as i32; }
    return -1;
}

// call [fmf] [cc] [ret attrs] [addrspace(N)] <ty> <callee>(<args>) [fn attrs] [bundles]
fn parse_call(tkind: u8) -> i32 {
    lex();   // 'call'
    let fm = parse_fmf();
    let cc = parse_cc();
    let retattrs = parse_param_attrs();
    var cas: i64 = 0;
    if tok_is("addrspace") { lex(); cas = parse_paren_uint(); }
    let t = parse_type();
    // callee
    let mark = vstack.len;      // args
    let amark = astack.len;     // param attr sets
    // parse callee value: type is ptr
    var callee: i32 = -1;
    let save_ts = ts;
    callee = parse_value(ty_ptr(cas));
    expect_punct('(', "'('");
    if !tok_punct(')') {
        loop {
            if tk == T_DOTS { lex(); break; }
            let at = parse_type();
            let pa = parse_param_attrs();
            var av: i32 = -1;
            if at == T_METADATA {
                let m = parse_metadata_operand();
                av = get_md_as_value(m);
            } else {
                av = parse_value(at);
            }
            vstack.push(av);
            astack.push(pa);
            if !eat_punct(',') { break; }
        }
    }
    expect_punct(')', "')'");
    let nargs = vstack.len - mark;
    // function type
    var fty = t;
    if types[t].kind != TK_FUNC {
        let rmark = ints.len as i32;
        ints.push(t);
        for k in nargs { ints.push(vals[vstack[mark + k]].ty); }
        fty = ty_func_run(rmark, nargs + 1, false);
    }
    let v = new_inst(OP_CALL, ty_fn_ret(fty), nargs + 1);
    for k in nargs { set_op(v, k, vstack[mark + k]); }
    set_op(v, nargs, callee);
    vstack.resize(mark);
    let fnattrs = parse_fn_attrs(GR_CALL, v);
    if tok_punct('[') { perr("operand bundles are not supported yet"); }
    let lmark = astack.len;
    astack.push(fnattrs);
    astack.push(retattrs);
    for k in amark..lmark { astack.push(astack[k]); }
    let al = alist_get(astack[lmark..]);
    astack.resize(amark);
    let ii = inst_of(v);
    insts[ii].attrs = al;
    insts[ii].cc = cc;
    insts[ii].ty2 = fty;
    insts[ii].pred = tkind;
    insts[ii].fmf = fm;
    return v;
}

// ---------------------------------------------------------------------------------------------
// Module

fn parse_module(path: const u8[:]) {
    src.clear();
    if !read_file(path, src) { fatal(str("could not open input file '", path, "'")); }
    src_name.clear();
    src_name.append(path);
    cur_module = new_module();
    modules[cur_module].module_id = intern(path);
    modules[cur_module].source_filename = intern(path);
    gfwd_st = new_symtab();
    dl_reset();
    lpos = 0;
    lex();
    loop {
        if tk == T_EOF { break; }
        if tok_is("target") {
            lex();
            if tok_is("datalayout") {
                lex();
                expect_punct('=', "'='");
                if tk != T_STR { perr("expected string"); }
                modules[cur_module].datalayout = tstr_id();
                dl_parse(tstr);
                lex();
                continue;
            }
            if tok_is("triple") {
                lex();
                expect_punct('=', "'='");
                if tk != T_STR { perr("expected string"); }
                modules[cur_module].triple = tstr_id();
                lex();
                continue;
            }
            perr("unknown target property");
        }
        if tok_is("source_filename") {
            lex();
            expect_punct('=', "'='");
            if tk != T_STR { perr("expected string"); }
            modules[cur_module].source_filename = tstr_id();
            lex();
            continue;
        }
        if tok_is("module") {
            lex();
            expect_kw("asm");
            if tk != T_STR { perr("expected string"); }
            var buf: u8[>..] = [];
            if modules[cur_module].asm_ >= 0 { buf.append(sbytes(modules[cur_module].asm_)); }
            buf.append(tstr);
            buf.push('\n');
            modules[cur_module].asm_ = intern(buf);
            lex();
            continue;
        }
        if tok_is("define") { parse_function(true); continue; }
        if tok_is("declare") { parse_function(false); continue; }
        if tok_is("attributes") { parse_attr_group_def(); continue; }
        if tok_is("uselistorder") || tok_is("uselistorder_bb") { perr("uselistorder directives are not supported yet"); }
        if tk == T_LVAR || tk == T_LID {
            // %T = type ...
            var t: i32 = -1;
            if tk == T_LVAR { t = get_named_type(tstr_id()); } else { t = get_numbered_type(tuint); }
            lex();
            expect_punct('=', "'='");
            expect_kw("type");
            parse_named_type_def(t);
            continue;
        }
        if tk == T_COMDATVAR {
            let c = get_comdat(tstr_id());
            lex();
            expect_punct('=', "'='");
            expect_kw("comdat");
            var k: u8 = 0;
            if tok_is("any") { k = 0; } else if tok_is("exactmatch") { k = 1; } else if tok_is("largest") { k = 2; }
            else if tok_is("nodeduplicate") { k = 3; } else if tok_is("samesize") { k = 4; } else { perr("unknown selection kind"); }
            lex();
            comdats[c].kind = k;
            continue;
        }
        if tk == T_GVAR || tk == T_GID {
            var nm: i32 = -1;
            var num: i64 = -1;
            if tk == T_GVAR { nm = tstr_id(); } else { num = tuint; }
            lex();
            expect_punct('=', "'='");
            parse_global_def(nm, num);
            continue;
        }
        if tk == T_GVAR { continue; }
        if tk == T_EXCL {
            // !N = ...
            parse_md_def();
            continue;
        }
        if tk == T_MDVAR {
            // !name = !{...}
            let nm = tstr_id();
            lex();
            expect_punct('=', "'='");
            if tk != T_EXCL { perr("expected '!'"); }
            lex();
            expect_punct('{', "'{'");
            let at = md_ops.len as i32;
            var n = 0;
            if !tok_punct('}') {
                loop {
                    if tk != T_EXCL { perr("expected '!' here"); }
                    lex();
                    let id = parse_uint();
                    md_ops.push(get_md_slot(id));
                    n++;
                    if !eat_punct(',') { break; }
                }
            }
            expect_punct('}', "'}'");
            // merge into an existing named node of the same name
            var found = false;
            for &x in named_mds {
                if x.name == nm && x.module == cur_module {
                    // re-append: concatenate (rare)
                    let nat = md_ops.len as i32;
                    for k in x.nops { md_ops.push(md_ops[x.ops + k]); }
                    for k in n { md_ops.push(md_ops[at + k]); }
                    x.ops = nat;
                    x.nops = x.nops + n as i32;
                    found = true;
                }
            }
            if !found { named_mds.push(NamedMd { name: nm, ops: at, nops: n as i32, module: cur_module }); }
            continue;
        }
        perr("expected top-level entity");
    }
    // validateEndOfModule
    resolve_attr_groups();
    for m in md_slots { if m >= 0 && mds[m].kind == MK_TEMP { perr_at(src.len, "use of undefined metadata"); } }
    if symtabs[gfwd_st].count > 0 { perr_at(src.len, "use of undefined value"); }
    for f in gfwd_num { if f >= 0 { perr_at(src.len, "use of undefined value"); } }
    for k in ba_fwd.len / 4 { if ba_fwd[4 * k] >= 0 { perr_at(src.len, "expected function name in blockaddress"); } }
    // intrinsic declarations get their attributes from the intrinsic table
    upgrade_intrinsic_attrs();
}


// ---------------------------------------------------------------------------------------------
// Intrinsic attributes (UpgradeIntrinsicFunction replaces the attribute list of intrinsic declarations).

import gen_intrinsics;

// Lex an extra piece of text appended after the input; returns the old length to restore.
fn text_lex_begin(text: const u8[:]) -> i64 {
    let save = src.len;
    src.push('\n');
    src.append(text);
    src.push('\n');
    lpos = save;
    lex();
    return save;
}
fn text_lex_end(save: i64) { src.resize(save); }

fn intrinsic_entry(name: const u8[:]) -> i64 {
    var lo = 0;
    var hi = INTRINSIC_ATTRS.len;
    while lo < hi {
        let mid = (lo + hi) / 2;
        let e = INTRINSIC_ATTRS[mid];
        let t = find(e, "\t");
        let c = bytes_cmp(e[..t], name);
        if c == 0 { return mid; }
        if c < 0 { lo = mid + 1; } else { hi = mid; }
    }
    return -1;
}

fn upgrade_intrinsic_attrs() {
    var f = modules[cur_module].first_func;
    while f >= 0 {
        let g = glob_of(f);
        if globs[g].intrinsic != 0 {
            let k = intrinsic_entry(sbytes(vals[f].name));
            if k >= 0 {
                let e = INTRINSIC_ATTRS[k];
                var p1: u8[>..] = [];
                var p2: u8[>..] = [];
                var p3: u8[>..] = [];
                var field = 0;
                for c in e {
                    if c == '\t' { field++; continue; }
                    if field == 1 { p1.push(c); } else if field == 2 { p2.push(c); } else if field == 3 { p3.push(c); }
                }
                // return attrs: prefix before the return type
                let s1 = text_lex_begin(p1);
                let ret = parse_param_attrs();
                text_lex_end(s1);
                let amark = astack.len;
                let s2 = text_lex_begin(p2);
                if tk != T_EOF {
                    loop {
                        if tk == T_DOTS { break; }
                        parse_type();
                        let pa = parse_param_attrs();
                        astack.push(pa);
                        if !eat_punct(',') { break; }
                    }
                }
                text_lex_end(s2);
                let s3 = text_lex_begin(p3);
                let fa = parse_fn_attrs(GR_FN, -1);
                text_lex_end(s3);
                let lmark = astack.len;
                astack.push(fa);
                astack.push(ret);
                for j in amark..lmark { astack.push(astack[j]); }
                globs[g].attrs = alist_get(astack[lmark..]);
                astack.resize(amark);
            }
        }
        f = globs[g].next;
    }
}
