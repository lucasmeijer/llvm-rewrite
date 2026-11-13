// llvm::demangle (llvm/lib/Demangle/Demangle.cpp) with a small subset of the Itanium demangler
// (llvm/include/llvm/Demangle/ItaniumDemangle.h): plain, nested and local names, the special names
// _ZTV/_ZTS/_ZTI/_ZGV/_ZTT, internal-linkage _ZL names, builtin, pointer/reference/cv-qualified and named parameter
// types. Substitutions (S_ / S<n>_ except St), templates and the other manglings (Rust _R, D _D, MSVC ?) fail loudly
// rather than giving a different string than LLVM.

Dm :: struct {
    s: string;
    p: s64;
    ok: bool = true;
}

dm_peek :: (d: *Dm, k: s64 = 0) -> u8 { if d.p + k < d.s.count return d.s[d.p + k]; return 0; }
dm_eat :: (d: *Dm, c: u8) -> bool { if dm_peek(d) == c { d.p += 1; return true; } return false; }
dm_fail :: (d: *Dm) { d.ok = false; }

// llvm::demangle(MangledName)
llvm_demangle :: (name: string) -> string {
    if name.count == 0 return name;
    s := name;
    if begins_with(s, "_Z") || begins_with(s, "__Z") || begins_with(s, "___Z") || begins_with(s, "____Z") {
        if begins_with(s, "___Z") || begins_with(s, "____Z") fatal("demangle: block invocation names ('%') are not supported", name);
        if begins_with(s, "__Z") s = slice(s, 1, s.count - 1);
        r, ok := dm_itanium(s);
        if ok return r;
        fatal("demangle: the Itanium mangled name '%' is beyond the ported subset of the demangler", name);
    }
    if begins_with(s, "??_C@_0") {
        r, ok := dm_msvc_string_literal(s);
        if ok return r;
    }
    if begins_with(s, "?") && !begins_with(s, "??") {
        r, ok := dm_msvc_simple_variable(s);
        if ok return r;
    }
    if begins_with(s, "_R") || begins_with(s, "_D") || begins_with(s, "?")
        fatal("demangle: the mangled name '%' (Rust / D / MSVC) is not supported", name);
    if s[0] == #char "." && s.count > 1 && (begins_with(slice(s, 1, s.count - 1), "_Z"))
        fatal("demangle: names with a leading dot ('%') are not supported", name);
    return name;
}

dm_itanium :: (s: string) -> (string, bool) {
    d: Dm; d.s = s; d.p = 2;
    sb: String_Builder; sb.allocator = temp;
    // special names
    if dm_peek(*d) == #char "T" {
        c := dm_peek(*d, 1);
        prefix := "";
        if c == #char "V" prefix = "vtable for ";
        else if c == #char "S" prefix = "typeinfo name for ";
        else if c == #char "I" prefix = "typeinfo for ";
        else if c == #char "T" prefix = "VTT for ";
        else return "", false;
        d.p += 2;
        t := dm_type(*d);
        if !d.ok return "", false;
        if d.p < s.count {
            if s[d.p] == #char "." return tprint("%1%2 (%3)", prefix, t, slice(s, d.p, s.count - d.p)), true;
            return "", false;
        }
        return tconcat(prefix, t), true;
    }
    if dm_peek(*d) == #char "G" && dm_peek(*d, 1) == #char "V" {
        d.p += 2;
        n := dm_name(*d);
        if !d.ok || d.p != s.count return "", false;
        return tconcat("guard variable for ", n), true;
    }
    e := dm_encoding(*d);
    if !d.ok return "", false;
    // a vendor suffix (.something) is printed as " (.something)"
    if d.p < s.count {
        if s[d.p] == #char "." return tprint("% (%)", e, slice(s, d.p, s.count - d.p)), true;
        return "", false;
    }
    return e, true;
}

// <encoding> ::= <name> <bare-function-type> | <name>
dm_encoding :: (d: *Dm) -> string {
    dm_eat(d, #char "L");
    n := dm_name(d);
    if !d.ok return "";
    c := dm_peek(d);
    if c == 0 || c == #char "E" || c == #char "." return n;
    // function parameters
    params := dm_bare_function_type(d);
    return tconcat(n, params);
}

dm_bare_function_type :: (d: *Dm) -> string {
    sb: String_Builder; sb.allocator = temp;
    append(*sb, "(");
    if dm_peek(d) == #char "v" && (dm_peek(d, 1) == 0 || dm_peek(d, 1) == #char "E" || dm_peek(d, 1) == #char ".") {
        d.p += 1;
        append(*sb, ")");
        return builder_to_string(*sb,, allocator = temp);
    }
    first := true;
    while d.ok && dm_peek(d) != 0 && dm_peek(d) != #char "E" && dm_peek(d) != #char "." {
        t := dm_type(d);
        if !d.ok return "";
        if !first append(*sb, ", ");
        append(*sb, t);
        first = false;
    }
    append(*sb, ")");
    return builder_to_string(*sb,, allocator = temp);
}

// <name> ::= <nested-name> | <local-name> | <unscoped-name>
dm_name :: (d: *Dm) -> string {
    c := dm_peek(d);
    if c == #char "N" return dm_nested_name(d);
    if c == #char "Z" return dm_local_name(d);
    if c == #char "S" && dm_peek(d, 1) == #char "t" { d.p += 2; return tconcat("std::", dm_unqualified_name(d)); }
    if c == #char "S" || c == #char "I" { dm_fail(d); return ""; }
    return dm_unqualified_name(d);
}

dm_nested_name :: (d: *Dm) -> string {
    d.p += 1;   // N
    // CV-qualifiers / ref-qualifiers of member functions are not supported
    c := dm_peek(d);
    if c == #char "K" || c == #char "V" || c == #char "r" || c == #char "R" || c == #char "O" { dm_fail(d); return ""; }
    sb: String_Builder; sb.allocator = temp;
    first := true;
    if dm_peek(d) == #char "S" && dm_peek(d, 1) == #char "t" { d.p += 2; append(*sb, "std"); first = false; }
    while d.ok && !dm_eat(d, #char "E") {
        if dm_peek(d) == 0 || dm_peek(d) == #char "S" || dm_peek(d) == #char "I" || dm_peek(d) == #char "C" || dm_peek(d) == #char "D" { dm_fail(d); return ""; }
        n := dm_unqualified_name(d);
        if !d.ok return "";
        if !first append(*sb, "::");
        append(*sb, n);
        first = false;
    }
    return builder_to_string(*sb,, allocator = temp);
}

// <local-name> ::= Z <encoding> E <entity name> [<discriminator>] | Z <encoding> E s [<discriminator>]
dm_local_name :: (d: *Dm) -> string {
    d.p += 1;   // Z
    enc := dm_encoding(d);
    if !d.ok || !dm_eat(d, #char "E") { dm_fail(d); return ""; }
    if dm_eat(d, #char "s") { dm_discriminator(d); return tconcat(enc, "::string literal"); }
    if dm_peek(d) == #char "d" { dm_fail(d); return ""; }
    n := dm_name(d);
    if !d.ok return "";
    dm_discriminator(d);
    return tprint("%::%", enc, n);
}

dm_discriminator :: (d: *Dm) {
    if dm_peek(d) != #char "_" return;
    d.p += 1;
    if dm_eat(d, #char "_") {
        while dm_peek(d) >= #char "0" && dm_peek(d) <= #char "9" d.p += 1;
        if !dm_eat(d, #char "_") dm_fail(d);
        return;
    }
    if dm_peek(d) >= #char "0" && dm_peek(d) <= #char "9" { d.p += 1; return; }
    dm_fail(d);
}

// <unqualified-name> ::= <source-name> (operator / ctor / dtor names are not supported)
dm_unqualified_name :: (d: *Dm) -> string {
    if !(dm_peek(d) >= #char "0" && dm_peek(d) <= #char "9") { dm_fail(d); return ""; }
    n: s64 = 0;
    while dm_peek(d) >= #char "0" && dm_peek(d) <= #char "9" { n = n * 10 + cast(s64)(dm_peek(d) - #char "0"); d.p += 1; }
    if d.p + n > d.s.count { dm_fail(d); return ""; }
    id := slice(d.s, d.p, n);
    d.p += n;
    if begins_with(id, "_GLOBAL__N") return "(anonymous namespace)";
    if dm_peek(d) == #char "I" || dm_peek(d) == #char "B" { dm_fail(d); return ""; }
    return id;
}

DM_BUILTINS :: struct { c: u8; name: string; }.[
    .{#char "v", "void"}, .{#char "w", "wchar_t"}, .{#char "b", "bool"}, .{#char "c", "char"}, .{#char "a", "signed char"},
    .{#char "h", "unsigned char"}, .{#char "s", "short"}, .{#char "t", "unsigned short"}, .{#char "i", "int"},
    .{#char "j", "unsigned int"}, .{#char "l", "long"}, .{#char "m", "unsigned long"}, .{#char "x", "long long"},
    .{#char "y", "unsigned long long"}, .{#char "n", "__int128"}, .{#char "o", "unsigned __int128"}, .{#char "f", "float"},
    .{#char "d", "double"}, .{#char "e", "long double"}, .{#char "g", "__float128"}, .{#char "z", "..."},
];

dm_type :: (d: *Dm) -> string {
    c := dm_peek(d);
    for DM_BUILTINS if it.c == c { d.p += 1; return it.name; }
    if c == #char "P" { d.p += 1; t := dm_type(d); return tconcat(t, "*"); }
    if c == #char "R" { d.p += 1; t := dm_type(d); return tconcat(t, "&"); }
    if c == #char "O" { d.p += 1; t := dm_type(d); return tconcat(t, "&&"); }
    if c == #char "K" { d.p += 1; t := dm_type(d); if d.ok && dm_peek(d, -2) == #char "P" { dm_fail(d); return ""; } return tconcat(t, " const"); }
    if c == #char "N" return dm_nested_name(d);
    if c >= #char "0" && c <= #char "9" return dm_unqualified_name(d);
    if c == #char "S" && dm_peek(d, 1) == #char "t" { d.p += 2; return tconcat("std::", dm_unqualified_name(d)); }
    dm_fail(d);
    return "";
}

// MicrosoftDemangle's demangleStringLiteral for narrow (??_C@_0) literals that are not truncated: "<chars>"
dm_msvc_string_literal :: (s: string) -> (string, bool) {
    p := 7;   // after ??_C@_0
    // the length: a digit d is d + 1, otherwise hex digits A..P terminated by '@'
    len: u64;
    if p < s.count && s[p] >= #char "0" && s[p] <= #char "9" { len = cast(u64)(s[p] - #char "0") + 1; p += 1; }
    else {
        while p < s.count && s[p] != #char "@" {
            if s[p] < #char "A" || s[p] > #char "P" return "", false;
            len = len * 16 + cast(u64)(s[p] - #char "A");
            p += 1;
        }
        p += 1;
    }
    // the hash
    while p < s.count && s[p] != #char "@" p += 1;
    p += 1;
    out: [..] u8; out.allocator = temp;
    while p < s.count && s[p] != #char "@" {
        c := s[p];
        if c == #char "?" {
            if p + 1 < s.count && s[p + 1] >= #char "0" && s[p + 1] <= #char "9" {
                array_add(*out, (",/\\:. \n\t'-")[s[p + 1] - #char "0"]);
                p += 2;
                continue;
            }
            if p + 3 < s.count && s[p + 1] == #char "$" {
                hi := s[p + 2]; lo := s[p + 3];
                if hi < #char "A" || hi > #char "P" || lo < #char "A" || lo > #char "P" return "", false;
                array_add(*out, cast(u8)((hi - #char "A") * 16 + (lo - #char "A")));
                p += 4;
                continue;
            }
            return "", false;
        }
        array_add(*out, c);
        p += 1;
    }
    if cast(u64) out.count != len return "", false;
    if out.count == 0 || out[out.count - 1] != 0 return "", false;
    sb: String_Builder; sb.allocator = temp;
    append(*sb, "\"");
    for k: 0..out.count-2 {
        c := out[k];
        if c == #char "\n" { append(*sb, "\\n"); continue; }
        if c == #char "\t" { append(*sb, "\\t"); continue; }
        if c < 0x20 || c >= 0x7f || c == #char "\\" || c == #char "\"" return "", false;
        append(*sb, c);
    }
    append(*sb, "\"");
    return builder_to_string(*sb,, allocator = temp), true;
}

// MicrosoftDemangle for a plain global variable "?<name>@@3<type>A" of a builtin or pointer-to-builtin type
dm_msvc_simple_variable :: (s: string) -> (string, bool) {
    at := find_index_from_left(s, "@@3");
    if at < 2 return "", false;
    name := slice(s, 1, at - 1);
    for c: cast([] u8) name if !(c_isalnum(c) || c == #char "_") return "", false;
    rest := slice(s, at + 3, s.count - at - 3);
    BUILTIN :: struct { c: u8; n: string; }.[
        .{#char "C", "signed char"}, .{#char "D", "char"}, .{#char "E", "unsigned char"}, .{#char "F", "short"},
        .{#char "G", "unsigned short"}, .{#char "H", "int"}, .{#char "I", "unsigned int"}, .{#char "J", "long"},
        .{#char "K", "unsigned long"}, .{#char "M", "float"}, .{#char "N", "double"},
    ];
    ptr := false;
    if begins_with(rest, "PA") { ptr = true; rest = slice(rest, 2, rest.count - 2); }
    if rest.count != 2 || rest[1] != #char "A" return "", false;
    for BUILTIN if it.c == rest[0] {
        if ptr return tprint("% *%", it.n, name), true;
        return tprint("% %", it.n, name), true;
    }
    return "", false;
}
