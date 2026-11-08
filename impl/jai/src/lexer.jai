// Port of llvm/lib/AsmParser/LLLexer.cpp. Keywords are returned as KW tokens carrying their text;
// the parser compares the text (instead of LLVM's big keyword enum).

Tok :: enum u8 {
    EOF; ERROR;
    KW;            // keyword / bare identifier: text
    INT_TYPE;      // iN: uval = N
    BYTE_TYPE;     // bN
    LOCAL_VAR; LOCAL_ID; GLOBAL_VAR; GLOBAL_ID; COMDAT_VAR; METADATA_VAR;
    LABEL_STR; LABEL_ID; STRING; ATTR_GRP_ID; SUMMARY_ID;
    APSINT;        // text = decimal literal (maybe with '-'); or hex (hex_kind 'u'/'s', text = hex digits)
    FLOAT_LIT;     // text = literal for convertFromString
    APFLOAT_HEX;   // 0x... double bit pattern: text = hex digits
    FLOAT_HEX;     // 0xK/L/M/H/R or f0x: hex_kind, text = hex digits
    EXCLAIM; HASH; EQUAL; COMMA; LSQUARE; RSQUARE; LBRACE; RBRACE; LESS; GREATER; LPAREN; RPAREN;
    STAR; BAR; COLON; DOTDOTDOT;
}

Token :: struct {
    kind: Tok;
    text: string;
    uval: u64;
    hex_kind: u8;
    pos:  s64;
}

Lexer :: struct {
    src: string;
    pos: s64;
    file: string;
    ignore_colon: bool;
}

c_isalpha :: inline (c: u8) -> bool { return (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z"); }
c_isdigit :: inline (c: u8) -> bool { return c >= #char "0" && c <= #char "9"; }
c_isalnum :: inline (c: u8) -> bool { return c_isalpha(c) || c_isdigit(c); }
c_isxdigit :: inline (c: u8) -> bool { return c_isdigit(c) || (c >= #char "a" && c <= #char "f") || (c >= #char "A" && c <= #char "F"); }
is_label_char :: inline (c: u8) -> bool { return c_isalnum(c) || c == #char "-" || c == #char "$" || c == #char "." || c == #char "_"; }
hex_val :: inline (c: u8) -> u32 {
    if c_isdigit(c) return cast(u32)(c - #char "0");
    if c >= #char "a" && c <= #char "f" return cast(u32)(c - #char "a" + 10);
    return cast(u32)(c - #char "A" + 10);
}

lx_at :: inline (l: *Lexer, i: s64) -> u8 { if i < l.src.count return l.src[i]; return 0; }

// Returns the position after the label tail ':' or -1.
lx_label_tail :: (l: *Lexer, p: s64) -> s64 {
    while true {
        c := lx_at(l, p);
        if c == #char ":" return p + 1;
        if !is_label_char(c) return -1;
        p += 1;
    }
    return -1;
}

unescape :: (s: string) -> string {
    has := false;
    for i: 0..s.count-1 if s[i] == #char "\\" { has = true; break; }
    if !has return s;
    out: [..] u8;
    i := 0;
    while i < s.count {
        c := s[i];
        if c == #char "\\" {
            if i + 1 < s.count && s[i + 1] == #char "\\" { array_add(*out, #char "\\"); i += 2; continue; }
            if i + 2 < s.count && c_isxdigit(s[i + 1]) && c_isxdigit(s[i + 2]) {
                array_add(*out, cast(u8)(hex_val(s[i + 1]) * 16 + hex_val(s[i + 2])));
                i += 3; continue;
            }
        }
        array_add(*out, c);
        i += 1;
    }
    r: string; r.data = out.data; r.count = out.count;
    return r;
}

lex_error :: (l: *Lexer, pos: s64, msg: string) {
    line, col := line_col(l.src, pos);
    fatal("%:%:%: %", l.file, line, col, msg);
}

line_col :: (src: string, pos: s64) -> (int, int) {
    line := 1; col := 1;
    if min(pos, src.count) > 0 for i: 0..min(pos, src.count)-1 {
        if src[i] == #char "\n" { line += 1; col = 1; } else col += 1;
    }
    return line, col;
}

lex :: (l: *Lexer) -> Token {
    t: Token;
    while true {
        start := l.pos;
        t.pos = start;
        if l.pos >= l.src.count { t.kind = .EOF; return t; }
        c := l.src[l.pos];
        l.pos += 1;
        if c == {
            case #char " "; #through;
            case #char "\t"; #through;
            case #char "\n"; #through;
            case #char "\r"; #through;
            case 0; continue;
            case #char ";";
                while l.pos < l.src.count && l.src[l.pos] != #char "\n" && l.src[l.pos] != #char "\r" l.pos += 1;
                continue;
            case #char "/";
                if lx_at(l, l.pos) != #char "*" { t.kind = .ERROR; return t; }
                l.pos += 1;
                while true {
                    if l.pos >= l.src.count lex_error(l, start, "unterminated comment");
                    if l.src[l.pos] == #char "*" && lx_at(l, l.pos + 1) == #char "/" { l.pos += 2; break; }
                    l.pos += 1;
                }
                continue;
            case #char "+"; return lex_positive(l, start);
            case #char "@"; return lex_var(l, start, .GLOBAL_VAR, .GLOBAL_ID);
            case #char "%"; return lex_var(l, start, .LOCAL_VAR, .LOCAL_ID);
            case #char "$"; return lex_dollar(l, start);
            case #char "\""; return lex_quote(l, start);
            case #char ".";
                p := lx_label_tail(l, l.pos);
                if p >= 0 { l.pos = p; t.kind = .LABEL_STR; t.text = slice(l.src, start, p - 1 - start); return t; }
                if lx_at(l, l.pos) == #char "." && lx_at(l, l.pos + 1) == #char "." { l.pos += 2; t.kind = .DOTDOTDOT; return t; }
                t.kind = .ERROR; return t;
            case #char "!"; return lex_exclaim(l, start);
            case #char "^";
                if !c_isdigit(lx_at(l, l.pos)) { t.kind = .ERROR; return t; }
                return lex_uint_id(l, start, .SUMMARY_ID);
            case #char ":"; t.kind = .COLON; return t;
            case #char "#";
                if c_isdigit(lx_at(l, l.pos)) return lex_uint_id(l, start, .ATTR_GRP_ID);
                t.kind = .HASH; return t;
            case #char "="; t.kind = .EQUAL; return t;
            case #char "["; t.kind = .LSQUARE; return t;
            case #char "]"; t.kind = .RSQUARE; return t;
            case #char "{"; t.kind = .LBRACE; return t;
            case #char "}"; t.kind = .RBRACE; return t;
            case #char "<"; t.kind = .LESS; return t;
            case #char ">"; t.kind = .GREATER; return t;
            case #char "("; t.kind = .LPAREN; return t;
            case #char ")"; t.kind = .RPAREN; return t;
            case #char ","; t.kind = .COMMA; return t;
            case #char "*"; t.kind = .STAR; return t;
            case #char "|"; t.kind = .BAR; return t;
        }
        if c_isdigit(c) || c == #char "-" return lex_digit_or_negative(l, start);
        if c_isalpha(c) || c == #char "_" return lex_identifier(l, start);
        t.kind = .ERROR;
        return t;
    }
    return t;
}

lex_uint_id :: (l: *Lexer, start: s64, kind: Tok) -> Token {
    t: Token; t.pos = start;
    if !c_isdigit(lx_at(l, l.pos)) { t.kind = .ERROR; return t; }
    v: u64 = 0;
    while c_isdigit(lx_at(l, l.pos)) { v = v * 10 + cast(u64)(l.src[l.pos] - #char "0"); l.pos += 1; }
    if v > 0xFFFF_FFFF lex_error(l, start, "invalid value number (too large)");
    t.kind = kind; t.uval = v;
    return t;
}

lex_read_var_name :: (l: *Lexer) -> bool, string {
    s := l.pos;
    c := lx_at(l, s);
    if c_isalpha(c) || c == #char "-" || c == #char "$" || c == #char "." || c == #char "_" {
        l.pos += 1;
        while is_label_char(lx_at(l, l.pos)) l.pos += 1;
        return true, slice(l.src, s, l.pos - s);
    }
    return false, "";
}

lex_var :: (l: *Lexer, start: s64, var: Tok, id: Tok) -> Token {
    t: Token; t.pos = start;
    if lx_at(l, l.pos) == #char "\"" {
        l.pos += 1;
        s := l.pos;
        while true {
            if l.pos >= l.src.count lex_error(l, start, "end of file in global variable name");
            if l.src[l.pos] == #char "\"" break;
            l.pos += 1;
        }
        t.text = unescape(slice(l.src, s, l.pos - s));
        l.pos += 1;
        t.kind = var;
        return t;
    }
    ok, name := lex_read_var_name(l);
    if ok { t.kind = var; t.text = name; return t; }
    return lex_uint_id(l, start, id);
}

lex_dollar :: (l: *Lexer, start: s64) -> Token {
    t: Token; t.pos = start;
    p := lx_label_tail(l, start);
    if p >= 0 { l.pos = p; t.kind = .LABEL_STR; t.text = slice(l.src, start, p - 1 - start); return t; }
    if lx_at(l, l.pos) == #char "\"" {
        l.pos += 1;
        s := l.pos;
        while true {
            if l.pos >= l.src.count lex_error(l, start, "end of file in COMDAT variable name");
            if l.src[l.pos] == #char "\"" break;
            l.pos += 1;
        }
        t.text = unescape(slice(l.src, s, l.pos - s));
        l.pos += 1;
        t.kind = .COMDAT_VAR;
        return t;
    }
    ok, name := lex_read_var_name(l);
    if ok { t.kind = .COMDAT_VAR; t.text = name; return t; }
    t.kind = .ERROR;
    return t;
}

lex_quote :: (l: *Lexer, start: s64) -> Token {
    t: Token; t.pos = start;
    s := l.pos;
    while true {
        if l.pos >= l.src.count lex_error(l, start, "end of file in string constant");
        if l.src[l.pos] == #char "\"" break;
        l.pos += 1;
    }
    t.text = unescape(slice(l.src, s, l.pos - s));
    l.pos += 1;
    t.kind = .STRING;
    if lx_at(l, l.pos) == #char ":" { l.pos += 1; t.kind = .LABEL_STR; }
    return t;
}

lex_exclaim :: (l: *Lexer, start: s64) -> Token {
    t: Token; t.pos = start;
    c := lx_at(l, l.pos);
    if c_isalpha(c) || c == #char "-" || c == #char "$" || c == #char "." || c == #char "_" || c == #char "\\" {
        l.pos += 1;
        while true {
            c = lx_at(l, l.pos);
            if c_isalnum(c) || c == #char "-" || c == #char "$" || c == #char "." || c == #char "_" || c == #char "\\" l.pos += 1;
            else break;
        }
        t.kind = .METADATA_VAR;
        t.text = unescape(slice(l.src, start + 1, l.pos - start - 1));
        return t;
    }
    t.kind = .EXCLAIM;
    return t;
}

lex_identifier :: (l: *Lexer, start: s64) -> Token {
    t: Token; t.pos = start;
    first := l.src[start];
    int_end: s64 = ifx (first == #char "i" || first == #char "b") then -1 else l.pos;
    kw_end: s64 = -1;
    p := l.pos;
    while is_label_char(lx_at(l, p)) {
        c := l.src[p];
        if int_end < 0 && !c_isdigit(c) int_end = p;
        if kw_end < 0 && !c_isalnum(c) && c != #char "_" kw_end = p;
        p += 1;
    }
    if !l.ignore_colon && lx_at(l, p) == #char ":" {
        t.kind = .LABEL_STR; t.text = slice(l.src, start, p - start);
        l.pos = p + 1;
        return t;
    }
    if int_end < 0 int_end = p;
    if int_end != start + 1 {
        l.pos = int_end;
        n: u64 = 0;
        for i: start+1..int_end-1 n = n * 10 + cast(u64)(l.src[i] - #char "0");
        if n < 1 || n > 0x7F_FFFF lex_error(l, start, "bitwidth for integer or byte type out of range");
        t.kind = ifx first == #char "i" then Tok.INT_TYPE else .BYTE_TYPE;
        t.uval = n;
        return t;
    }
    if kw_end < 0 kw_end = p;
    // [us]0x / f0x hex constants
    if (first == #char "u" || first == #char "s" || first == #char "f") && lx_at(l, start + 1) == #char "0" &&
       lx_at(l, start + 2) == #char "x" && c_isxdigit(lx_at(l, start + 3)) {
        q := start + 3;
        while c_isxdigit(lx_at(l, q)) q += 1;
        l.pos = q;
        t.text = slice(l.src, start + 3, q - start - 3);
        t.hex_kind = first;
        t.kind = ifx first == #char "f" then Tok.FLOAT_HEX else .APSINT;
        return t;
    }
    l.pos = kw_end;
    kw := slice(l.src, start, kw_end - start);
    // "cc1234" -> cc, 1234
    if kw.count > 2 && kw[0] == #char "c" && kw[1] == #char "c" {
        all_digits := true;
        for i: 2..kw.count-1 if !c_isdigit(kw[i]) all_digits = false;
        if all_digits { l.pos = start + 2; t.kind = .KW; t.text = "cc"; return t; }
    }
    t.kind = .KW;
    t.text = kw;
    return t;
}

lex_digit_or_negative :: (l: *Lexer, start: s64) -> Token {
    t: Token; t.pos = start;
    first := l.src[start];
    if !c_isdigit(first) && !c_isdigit(lx_at(l, l.pos)) {
        e := lx_label_tail(l, l.pos);
        if e >= 0 { t.kind = .LABEL_STR; t.text = slice(l.src, start, e - 1 - start); l.pos = e; return t; }
        return lex_float_str(l, start);
    }
    while c_isdigit(lx_at(l, l.pos)) l.pos += 1;
    if c_isdigit(first) && lx_at(l, l.pos) == #char ":" {
        v: u64 = 0;
        for i: start..l.pos-1 v = v * 10 + cast(u64)(l.src[i] - #char "0");
        l.pos += 1;
        t.kind = .LABEL_ID; t.uval = v;
        return t;
    }
    c := lx_at(l, l.pos);
    if is_label_char(c) || c == #char ":" {
        e := lx_label_tail(l, l.pos);
        if e >= 0 { t.kind = .LABEL_STR; t.text = slice(l.src, start, e - 1 - start); l.pos = e; return t; }
    }
    if lx_at(l, l.pos) != #char "." {
        if first == #char "0" && lx_at(l, start + 1) == #char "x" return lex_0x(l, start);
        if first == #char "-" && lx_at(l, start + 1) == #char "0" && lx_at(l, start + 2) == #char "x" return lex_float_str(l, start);
        t.kind = .APSINT;
        t.text = slice(l.src, start, l.pos - start);
        return t;
    }
    l.pos += 1;
    while c_isdigit(lx_at(l, l.pos)) l.pos += 1;
    lex_exponent(l);
    t.kind = .FLOAT_LIT;
    t.text = slice(l.src, start, l.pos - start);
    return t;
}

lex_exponent :: (l: *Lexer) {
    c := lx_at(l, l.pos);
    if c == #char "e" || c == #char "E" {
        c1 := lx_at(l, l.pos + 1);
        if c_isdigit(c1) || ((c1 == #char "-" || c1 == #char "+") && c_isdigit(lx_at(l, l.pos + 2))) {
            l.pos += 2;
            while c_isdigit(lx_at(l, l.pos)) l.pos += 1;
        }
    }
}

lex_positive :: (l: *Lexer, start: s64) -> Token {
    t: Token; t.pos = start;
    if !c_isdigit(lx_at(l, l.pos)) return lex_float_str(l, start);
    l.pos += 1;
    while c_isdigit(lx_at(l, l.pos)) l.pos += 1;
    if lx_at(l, l.pos) == #char "x" return lex_float_str(l, start);
    if lx_at(l, l.pos) != #char "." { l.pos = start + 1; t.kind = .ERROR; return t; }
    l.pos += 1;
    while c_isdigit(lx_at(l, l.pos)) l.pos += 1;
    lex_exponent(l);
    t.kind = .FLOAT_LIT;
    t.text = slice(l.src, start, l.pos - start);
    return t;
}

lex_float_str :: (l: *Lexer, start: s64) -> Token {
    t: Token; t.pos = start;
    p := start;
    if l.src[p] == #char "-" || l.src[p] == #char "+" p += 1;
    if lx_at(l, p) != #char "0" {
        ls := p;
        while is_label_char(lx_at(l, p)) p += 1;
        label := slice(l.src, ls, p - ls);
        if label == "inf" { l.pos = p; t.kind = .FLOAT_LIT; t.text = slice(l.src, start, p - start); return t; }
        if label == "qnan" { l.pos = p; t.kind = .FLOAT_LIT; t.text = ifx l.src[start] == #char "-" then "-nan(0)" else "nan(0)"; return t; }
        if (label == "nan" || label == "snan") && lx_at(l, p) == #char "(" {
            p += 1;
            while p < l.src.count && l.src[p] != #char ")" p += 1;
            if lx_at(l, p) != #char ")" lex_error(l, start, "unclosed nan literal");
            p += 1;
            l.pos = p;
            s := slice(l.src, start, p - start);
            if s[0] == #char "+" s = slice(s, 1, s.count - 1);
            t.kind = .FLOAT_LIT; t.text = s;
            return t;
        }
        lex_error(l, start, "bad payload format for nan literal");
    }
    p += 1;
    if lx_at(l, p) != #char "x" { l.pos = start + 1; t.kind = .ERROR; return t; }
    p += 1;
    while c_isxdigit(lx_at(l, p)) p += 1;
    if lx_at(l, p) != #char "." { l.pos = start + 1; t.kind = .ERROR; return t; }
    p += 1;
    while c_isxdigit(lx_at(l, p)) p += 1;
    if lx_at(l, p) != #char "p" && lx_at(l, p) != #char "P" { l.pos = start + 1; t.kind = .ERROR; return t; }
    p += 1;
    if lx_at(l, p) == #char "+" || lx_at(l, p) == #char "-" p += 1;
    while c_isdigit(lx_at(l, p)) p += 1;
    l.pos = p;
    t.kind = .FLOAT_LIT;
    t.text = slice(l.src, start, p - start);
    return t;
}

lex_0x :: (l: *Lexer, start: s64) -> Token {
    t: Token; t.pos = start;
    p := start + 2;
    kind: u8 = #char "J";
    c := lx_at(l, p);
    if (c >= #char "K" && c <= #char "M") || c == #char "H" || c == #char "R" { kind = c; p += 1; }
    if !c_isxdigit(lx_at(l, p)) { l.pos = start + 1; t.kind = .ERROR; return t; }
    hs := p;
    while c_isxdigit(lx_at(l, p)) p += 1;
    if lx_at(l, p) == #char "." return lex_float_str(l, start);
    l.pos = p;
    t.text = slice(l.src, hs, p - hs);
    if kind == #char "J" { t.kind = .APFLOAT_HEX; return t; }
    t.kind = .FLOAT_HEX; t.hex_kind = kind;
    return t;
}
