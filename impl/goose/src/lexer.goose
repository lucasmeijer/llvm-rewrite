// Tokenizer for textual LLVM IR. Port of llvm/lib/AsmParser/LLLexer.cpp (the parts our parser needs).
import std;
import os;
import ir;
import bignum;
import apfloat;

let T_EOF = 0;
let T_GVAR = 1;       // @name   (tstr)
let T_GID = 2;        // @N      (tuint)
let T_LVAR = 3;       // %name
let T_LID = 4;        // %N
let T_MDVAR = 5;      // !name
let T_EXCL = 6;       // !
let T_ATTRGRP = 7;    // #N
let T_COMDATVAR = 8;  // $name
let T_LABELSTR = 9;   // name:
let T_LABELID = 10;   // N:
let T_STR = 11;       // "..."  (tstr, unescaped)
let T_INT = 12;       // integer literal (tnum, tneg)
let T_FPLIT = 13;     // decimal float literal / inf / nan(...) text in tstr
let T_FPHEXD = 14;    // 0x... double bits in tfp_lo
let T_FPBITS = 15;    // 0xK/0xL/0xH/0xR/f0x: raw bits (tfp_lo, tfp_hi), tfp_bits
let T_TYPE = 16;      // primitive type (ttype)
let T_KW = 17;        // keyword (src[ts..te])
let T_PUNCT = 18;     // single char (tch)
let T_DOTS = 19;      // ...
let T_CARET = 20;     // ^N

var src: u8[>..];
var src_name: u8[>..];
var lpos: i64 = 0;
var tk: i64 = 0;
var ts: i64 = 0;
var te: i64 = 0;
var tch: u8 = 0;
var tuint: i64 = 0;
var tstr: u8[>..<];
var tnum: u32[>..<];
var tneg: bool = false;
var tnum_hex_bits: i64 = 0;   // for s0x/u0x: number of bits (0 = decimal)
var tnum_hex_signed: bool = false;
var tfp_lo: u64 = 0;
var tfp_hi: u64 = 0;
var tfp_bits: i64 = 0;
var ttype: i32 = -1;
var ignore_colon: bool = false;

fn line_col(p: i64) -> i64, i64 {
    var line = 1;
    var col = 1;
    for i in min(p, src.len) {
        if src[i] == '\n' { line++; col = 1; } else { col++; }
    }
    return line, col;
}

fn perr_at(p: i64, msg: const u8[:]) {
    let line, col = line_col(p);
    var o: u8[>..] = [];
    format(o, src_name, ":", line, ":", col, ": error: ", msg, "\n");
    write_stderr(o);
    exit(1);
}

fn perr(msg: const u8[:]) { perr_at(ts, msg); }

fn ch(p: i64) -> u8 { if p < src.len { src[p] } else { 0 } }

fn is_alpha(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
fn is_digit(c: u8) -> bool { c >= '0' && c <= '9' }
fn is_alnum(c: u8) -> bool { is_alpha(c) || is_digit(c) }
fn is_label_char(c: u8) -> bool { is_alnum(c) || c == '-' || c == '$' || c == '.' || c == '_' }

fn tok_text() -> const u8[:] { src[ts..te] }
fn tok_is(s: const u8[:]) -> bool { tk == T_KW && src[ts..te] == s }
fn tok_punct(c: u8) -> bool { tk == T_PUNCT && tch == c }

// Read a "..." string starting at lpos (just after the opening quote) into tstr, unescaping \xx and \\.
fn lex_string_body() {
    tstr.clear();
    loop {
        let c = ch(lpos);
        if lpos >= src.len { perr_at(ts, "end of file in string constant"); }
        if c == '"' { lpos++; break; }
        if c == '\\' {
            if ch(lpos + 1) == '\\' { tstr.push('\\'); lpos += 2; continue; }
            let h1 = hexdig(ch(lpos + 1));
            let h2 = hexdig(ch(lpos + 2));
            if h1 >= 0 && h2 >= 0 {
                tstr.push((h1 * 16 + h2) as! u8);
                lpos += 3;
                continue;
            }
            tstr.push('\\');
            lpos++;
            continue;
        }
        tstr.push(c);
        lpos++;
    }
}

// @, %, $ prefixes: quoted name, number, or bare name.
fn lex_var(named: i64, numbered: i64) {
    let c = ch(lpos);
    if c == '"' {
        lpos++;
        lex_string_body();
        tk = named;
        return;
    }
    if is_digit(c) && numbered >= 0 {
        var v = 0;
        while is_digit(ch(lpos)) { v = v * 10 + (ch(lpos) - '0') as i64; lpos++; }
        tuint = v;
        tk = numbered;
        return;
    }
    if is_alpha(c) || c == '-' || c == '$' || c == '.' || c == '_' {
        tstr.clear();
        while is_label_char(ch(lpos)) { tstr.push(ch(lpos)); lpos++; }
        tk = named;
        return;
    }
    perr_at(lpos, "invalid variable name");
}

fn parse_dec_into_tnum(a: i64, b: i64) {
    tnum.clear();
    for i in a..b {
        bn_mul_small(tnum, 10);
        bn_add_small(tnum, (src[i] - '0') as u32);
    }
}

var prim_types_ready = false;

fn lex_ident() {
    // Label?
    var e = lpos;
    while is_label_char(ch(e)) { e++; }
    if ch(e) == ':' && !ignore_colon {
        tstr.clear();
        for i in ts..e { tstr.push(src[i]); }
        lpos = e + 1;
        tk = T_LABELSTR;
        return;
    }
    // keyword: [a-zA-Z_][a-zA-Z0-9_]*
    var k = ts;
    while is_alnum(ch(k)) || ch(k) == '_' { k++; }
    let word = src[ts..k];
    // [usf]0x hex integers / hex floats
    if (src[ts] == 'u' || src[ts] == 's' || src[ts] == 'f') && ch(ts + 1) == '0' && ch(ts + 2) == 'x' && hexdig(ch(ts + 3)) >= 0 {
        var p = ts + 3;
        while hexdig(ch(p)) >= 0 { p++; }
        let n = p - (ts + 3);
        tnum.clear();
        for i in (ts + 3)..p { bn_mul_small(tnum, 16); bn_add_small(tnum, hexdig(src[i]) as u32); }
        lpos = p;
        te = p;
        if src[ts] == 'f' {
            tfp_lo = bn_word(tnum, 0);
            tfp_hi = bn_word(tnum, 1);
            tfp_bits = n * 4;
            tk = T_FPBITS;
            return;
        }
        tneg = false;
        tnum_hex_bits = n * 4;
        tnum_hex_signed = src[ts] == 's';
        let ab = bn_active_bits(tnum);
        if ab > 0 && ab < tnum_hex_bits { tnum_hex_bits = ab; }
        tk = T_INT;
        return;
    }
    lpos = k;
    te = k;
    // integer types
    if word.len > 1 && word[0] == 'i' {
        var all = true;
        for c in word[1..] { if !is_digit(c) { all = false; } }
        if all {
            var bits = 0;
            for c in word[1..] { bits = bits * 10 + (c - '0') as i64; if bits > 16777215 { perr("bitwidth for integer type out of range"); } }
            if bits == 0 { perr("bitwidth for integer type out of range"); }
            ttype = ty_int(bits);
            tk = T_TYPE;
            return;
        }
    }
    var t: i32 = -1;
    if word == "void" { t = T_VOID; }
    else if word == "half" { t = ty_simple(TK_HALF); }
    else if word == "bfloat" { t = ty_simple(TK_BFLOAT); }
    else if word == "float" { t = T_FLOAT; }
    else if word == "double" { t = T_DOUBLE; }
    else if word == "x86_fp80" { t = ty_simple(TK_X86_FP80); }
    else if word == "fp128" { t = ty_simple(TK_FP128); }
    else if word == "ppc_fp128" { t = ty_simple(TK_PPC_FP128); }
    else if word == "label" { t = T_LABEL; }
    else if word == "metadata" { t = T_METADATA; }
    else if word == "x86_amx" { t = ty_simple(TK_X86_AMX); }
    else if word == "token" { t = T_TOKEN; }
    else if word == "ptr" { t = T_PTR; }
    if t >= 0 { ttype = t; tk = T_TYPE; return; }
    // cc1234 -> "cc"
    if word.len > 2 && word[0] == 'c' && word[1] == 'c' && is_digit(word[2]) {
        lpos = ts + 2;
        te = lpos;
    }
    tk = T_KW;
}

fn lex_number() {
    // [-]?[0-9]+ ... ; ts at the first char
    var p = lpos;
    let first = src[ts];
    if !is_digit(first) && !is_digit(ch(p)) {
        // -label or -inf / -nan
        var e = p;
        while is_label_char(ch(e)) { e++; }
        if ch(e) == ':' {
            tstr.clear();
            for i in ts..e { tstr.push(src[i]); }
            lpos = e + 1;
            tk = T_LABELSTR;
            return;
        }
        lex_float_str();
        return;
    }
    while is_digit(ch(p)) { p++; }
    if is_digit(first) && ch(p) == ':' {
        var v = 0;
        for i in ts..p { v = v * 10 + (src[i] - '0') as i64; }
        tuint = v;
        lpos = p + 1;
        tk = T_LABELID;
        return;
    }
    if is_label_char(ch(p)) && ch(p) != '.' || (ch(p) == '.' && false) {
        var e = p;
        while is_label_char(ch(e)) { e++; }
        if ch(e) == ':' {
            tstr.clear();
            for i in ts..e { tstr.push(src[i]); }
            lpos = e + 1;
            tk = T_LABELSTR;
            return;
        }
    }
    if ch(p) != '.' {
        if src[ts] == '0' && ch(ts + 1) == 'x' { lex_0x(); return; }
        if src[ts] == '-' && ch(ts + 1) == '0' && ch(ts + 2) == 'x' { lex_float_str(); return; }
        let neg = src[ts] == '-';
        let a = if neg { ts + 1 } else { ts };
        parse_dec_into_tnum(a, p);
        tneg = neg;
        tnum_hex_bits = 0;
        lpos = p;
        te = p;
        tk = T_INT;
        return;
    }
    p++;
    while is_digit(ch(p)) { p++; }
    if ch(p) == 'e' || ch(p) == 'E' {
        if is_digit(ch(p + 1)) || ((ch(p + 1) == '-' || ch(p + 1) == '+') && is_digit(ch(p + 2))) {
            p += 2;
            while is_digit(ch(p)) { p++; }
        }
    }
    tstr.clear();
    for i in ts..p { tstr.push(src[i]); }
    lpos = p;
    te = p;
    tk = T_FPLIT;
}

fn lex_float_str() {
    var p = ts;
    if ch(p) == '-' || ch(p) == '+' { p++; }
    var e = p;
    while is_label_char(ch(e)) { e++; }
    let label = src[p..e];
    if label == "inf" || label == "qnan" {
        tstr.clear();
        for i in ts..e { tstr.push(src[i]); }
        lpos = e;
        te = e;
        tk = T_FPLIT;
        return;
    }
    if (label == "nan" || label == "snan") && ch(e) == '(' {
        var q = e + 1;
        while q < src.len && src[q] != ')' { q++; }
        if q >= src.len { perr("unclosed nan literal"); }
        tstr.clear();
        for i in ts..(q + 1) { tstr.push(src[i]); }
        lpos = q + 1;
        te = lpos;
        tk = T_FPLIT;
        return;
    }
    perr("hexadecimal float literals ([-+]0x1.8p+1) are not supported yet");
}

fn lex_0x() {
    var p = ts + 2;
    var kind: u8 = 'J';
    let c = ch(p);
    if (c >= 'K' && c <= 'M') || c == 'H' || c == 'R' { kind = c; p++; }
    if hexdig(ch(p)) < 0 { perr("bad hex constant"); }
    let start = p;
    while hexdig(ch(p)) >= 0 { p++; }
    if ch(p) == '.' { perr("hexadecimal float literals are not supported yet"); }
    tnum.clear();
    for i in start..p { bn_mul_small(tnum, 16); bn_add_small(tnum, hexdig(src[i]) as u32); }
    lpos = p;
    te = p;
    if kind == 'J' {
        tfp_lo = bn_word(tnum, 0);
        tfp_hi = 0;
        tk = T_FPHEXD;
        return;
    }
    tfp_lo = bn_word(tnum, 0);
    tfp_hi = bn_word(tnum, 1);
    if kind == 'K' {
        // FP80HexToIntPair: first 4 hex digits are the high 16 bits, then 16 digits low 64 bits
        var hi: u64 = 0;
        var lo: u64 = 0;
        var i = start;
        let n = p - start;
        // digits beyond 20 are an error in LLVM; take the last 20
        var k = 0;
        while i < p {
            let d = hexdig(src[i]) as u64;
            if n - k > 16 { hi = (hi << 4) | d; } else { lo = (lo << 4) | d; }
            i++;
            k++;
        }
        tfp_lo = lo;
        tfp_hi = hi;
        tfp_bits = 80;
    } else if kind == 'L' || kind == 'M' {
        // HexToIntPair: first 16 digits high word, next 16 low word
        var hi: u64 = 0;
        var lo: u64 = 0;
        var k = 0;
        for i in start..p {
            let d = hexdig(src[i]) as u64;
            if k < 16 { hi = (hi << 4) | d; } else { lo = (lo << 4) | d; }
            k++;
        }
        tfp_lo = lo;
        tfp_hi = hi;
        tfp_bits = 128;
    } else {
        tfp_bits = 16;
    }
    tk = T_FPBITS;
}

fn lex() {
    loop {
        // skip whitespace and comments
        while lpos < src.len {
            let c = src[lpos];
            if c == ' ' || c == '\t' || c == '\n' || c == '\r' { lpos++; continue; }
            if c == ';' {
                while lpos < src.len && src[lpos] != '\n' { lpos++; }
                continue;
            }
            if c == '/' && lpos + 1 < src.len && src[lpos + 1] == '*' {
                lpos += 2;
                while lpos + 1 < src.len && !(src[lpos] == '*' && src[lpos + 1] == '/') { lpos++; }
                lpos += 2;
                continue;
            }
            break;
        }
        ts = lpos;
        if lpos >= src.len { tk = T_EOF; te = lpos; return; }
        let c = src[lpos];
        lpos++;
        if c == '@' { lex_var(T_GVAR, T_GID); te = lpos; return; }
        if c == '%' { lex_var(T_LVAR, T_LID); te = lpos; return; }
        if c == '$' { lex_var(T_COMDATVAR, -1); te = lpos; return; }
        if c == '#' {
            if !is_digit(ch(lpos)) { perr("expected attribute group id"); }
            var v = 0;
            while is_digit(ch(lpos)) { v = v * 10 + (ch(lpos) - '0') as i64; lpos++; }
            tuint = v;
            tk = T_ATTRGRP;
            te = lpos;
            return;
        }
        if c == '^' {
            var v = 0;
            while is_digit(ch(lpos)) { v = v * 10 + (ch(lpos) - '0') as i64; lpos++; }
            tuint = v;
            tk = T_CARET;
            te = lpos;
            return;
        }
        if c == '!' {
            let d = ch(lpos);
            if is_alpha(d) || d == '-' || d == '$' || d == '.' || d == '_' || d == '\\' {
                tstr.clear();
                loop {
                    let x = ch(lpos);
                    if is_label_char(x) { tstr.push(x); lpos++; continue; }
                    if x == '\\' && hexdig(ch(lpos + 1)) >= 0 && hexdig(ch(lpos + 2)) >= 0 {
                        tstr.push((hexdig(ch(lpos + 1)) * 16 + hexdig(ch(lpos + 2))) as! u8);
                        lpos += 3;
                        continue;
                    }
                    break;
                }
                tk = T_MDVAR;
                te = lpos;
                return;
            }
            tk = T_EXCL;
            te = lpos;
            return;
        }
        if c == '"' {
            lex_string_body();
            if ch(lpos) == ':' && !ignore_colon { lpos++; tk = T_LABELSTR; te = lpos; return; }
            tk = T_STR;
            te = lpos;
            return;
        }
        if c == '.' && ch(lpos) == '.' && ch(lpos + 1) == '.' { lpos += 2; tk = T_DOTS; te = lpos; return; }
        if is_digit(c) || c == '-' { lex_number(); return; }
        if c == '+' {
            if !is_digit(ch(lpos)) { lex_float_str(); return; }
            var p = lpos;
            while is_digit(ch(p)) { p++; }
            if ch(p) != '.' { perr("invalid token"); }
            p++;
            while is_digit(ch(p)) { p++; }
            if ch(p) == 'e' || ch(p) == 'E' {
                if is_digit(ch(p + 1)) || ((ch(p + 1) == '-' || ch(p + 1) == '+') && is_digit(ch(p + 2))) {
                    p += 2;
                    while is_digit(ch(p)) { p++; }
                }
            }
            tstr.clear();
            for i in ts..p { tstr.push(src[i]); }
            lpos = p;
            te = p;
            tk = T_FPLIT;
            return;
        }
        if is_alpha(c) || c == '_' || c == '$' || c == '.' {
            lex_ident();
            return;
        }
        tk = T_PUNCT;
        tch = c;
        te = lpos;
        return;
    }
}

// Lexer state save/restore for lookahead.
struct LexState { lpos: i64, tk: i64, ts: i64, te: i64, tch: u8 }
fn lex_save() -> LexState { LexState { lpos: lpos, tk: tk, ts: ts, te: te, tch: tch } }
fn lex_restore(s: LexState) {
    lpos = s.ts;
    lex();
}
