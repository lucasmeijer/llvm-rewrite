// Internalize: give every global that is not part of the public API internal linkage.
// Ported from llvm/lib/Transforms/IPO/Internalize.cpp, with the matching rules of llvm/lib/Support/GlobPattern.cpp
// (*, ?, [...] classes with ranges and ^/! inversion, \ escapes; no brace expansion: GlobPattern::create without
// MaxSubPatterns treats braces literally).

internalize_opts: struct {
    api_file: string;          // -internalize-public-api-file
    api_list: [..] string;     // -internalize-public-api-list (cl::list, CommaSeparated)
};

internalize_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == "internalize-public-api-list" {
        if !has_value fatal("option -% needs a value", name);
        v := value;
        while true {
            k := find_index_from_left(v, #char ",");
            if k < 0 { array_add(*internalize_opts.api_list, copy_string(v)); break; }
            array_add(*internalize_opts.api_list, copy_string(slice(v, 0, k)));
            v = slice(v, k + 1, v.count - k - 1);
        }
        return true;
    }
    if name == "internalize-public-api-file" { if !has_value fatal("option -% needs a value", name); internalize_opts.api_file = copy_string(value); return true; }
    return false;
}

// GlobPattern::match (the SubGlobPattern semantics, as a backtracking matcher)
glob_match :: (pat: string, s: string) -> bool {
    p := 0; i := 0;
    star_p := -1; star_i := 0;
    while i < s.count {
        if p < pat.count {
            c := pat[p];
            if c == #char "*" { p += 1; star_p = p; star_i = i; continue; }
            if c == #char "?" { p += 1; i += 1; continue; }
            if c == #char "[" {
                ok, next := glob_bracket_match(pat, p, s[i]);
                if ok { p = next; i += 1; continue; }
            } else if c == #char "\\" {
                if p + 1 < pat.count && pat[p + 1] == s[i] { p += 2; i += 1; continue; }
            } else if c == s[i] { p += 1; i += 1; continue; }
        }
        if star_p < 0 return false;
        star_i += 1;
        i = star_i;
        p = star_p;
    }
    while p < pat.count && pat[p] == #char "*" p += 1;
    return p == pat.count;
}
// a [...] class at pat[p]: ']' may be the first character; returns (matches, index after the class)
glob_bracket_match :: (pat: string, p: s64, ch: u8) -> bool, s64 {
    i := p + 1;
    j := i + 1;
    while j < pat.count && pat[j] != #char "]" j += 1;
    if j >= pat.count fatal("invalid glob pattern, unmatched '[': %", pat);
    chars := slice(pat, i, j - i);
    invert := chars.count > 0 && (chars[0] == #char "^" || chars[0] == #char "!");
    if invert chars = slice(chars, 1, chars.count - 1);
    set: [256] bool;
    k := 0;
    while chars.count - k >= 3 {
        if chars[k + 1] != #char "-" { set[chars[k]] = true; k += 1; continue; }
        a := chars[k]; b := chars[k + 2];
        if a > b fatal("invalid glob pattern: %", pat);
        for x: a..b set[x] = true;
        k += 3;
    }
    while k < chars.count { set[chars[k]] = true; k += 1; }
    m := set[ch];
    if invert m = !m;
    return m, j + 1;
}

Internalize :: struct {
    always_preserved: [..] string;
    patterns: [..] string;         // PreserveAPIList
    preserve_names: [..] string;   // internalize<preserve-gv=...>
    use_names: bool;
    is_wasm: bool;
}
Int_Comdat_Info :: struct { size: u32; external: bool; }

// MustPreserveGV: PreserveAPIList, or the preserve-gv name list
int_must_preserve :: (s: *Internalize, gv: Value_Id) -> bool {
    if s.use_names { for s.preserve_names if vname(gv) == it return true; return false; }
    for s.patterns if glob_match(it, vname(gv)) return true;
    return false;
}

// shouldPreserveGV
int_should_preserve :: (s: *Internalize, gv: Value_Id) -> bool {
    if is_declaration(gv) return true;
    if glob(gv).linkage == .AVAILABLE_EXTERNALLY return true;
    if glob(gv).dll == 2 return true;
    if vkind(gv) == .GLOBAL_VAR && glob(gv).ext_init return true;
    if gv_has_local_linkage(gv) return false;
    for s.always_preserved if it == vname(gv) return true;
    return int_must_preserve(s, gv);
}

// maybeInternalize
int_maybe_internalize :: (s: *Internalize, gv: Value_Id, cmap: *Table(s32, Int_Comdat_Info)) -> bool {
    c := gv_comdat(gv);
    if c >= 0 {
        found, info := table_find(cmap, c);
        if found && info.external return false;
        if vkind(gv) == .FUNCTION || vkind(gv) == .GLOBAL_VAR {
            p := table_find_pointer(cmap, c);
            if p.size == 1 glob(gv).comdat = -1;
            else if !s.is_wasm ir.comdats[c].kind = 3;   // NoDeduplicate
        }
        if gv_has_local_linkage(gv) return false;
    } else {
        if gv_has_local_linkage(gv) return false;
        if int_should_preserve(s, gv) return false;
    }
    gv_set_visibility(gv, 0);
    gv_set_linkage(gv, .INTERNAL);
    return true;
}

// checkComdat
int_check_comdat :: (s: *Internalize, gv: Value_Id, cmap: *Table(s32, Int_Comdat_Info)) {
    c := gv_comdat(gv);
    if c < 0 return;
    p := table_find_pointer(cmap, c);
    if !p { table_set(cmap, c, .{}); p = table_find_pointer(cmap, c); }
    p.size += 1;
    if int_should_preserve(s, gv) p.external = true;
}

internalize_run :: (node: *Pass_Node) -> Preserved {
    s: Internalize;
    s.always_preserved.allocator = temp; s.patterns.allocator = temp; s.preserve_names.allocator = temp;
    if node.name != "internalize" {
        // internalize<preserve-gv=A;preserve-gv=B>
        if !begins_with(node.name, "internalize<") || node.name[node.name.count - 1] != #char ">" fatal("invalid pass '%'", node.name);
        params := slice(node.name, 12, node.name.count - 13);
        while params.count {
            k := find_index_from_left(params, #char ";");
            p := ifx k < 0 then params else slice(params, 0, k);
            params = ifx k < 0 then "" else slice(params, k + 1, params.count - k - 1);
            if !begins_with(p, "preserve-gv=") fatal("invalid Internalize pass parameter '%'", p);
            array_add(*s.preserve_names, slice(p, 12, p.count - 12));
        }
        s.use_names = s.preserve_names.count > 0;
    }
    if !s.use_names {
        if internalize_opts.api_file.count {
            data, ok := read_entire_file(internalize_opts.api_file);
            if !ok write_string(tprint("WARNING: Internalize couldn't load file '%'! Continuing as if it's empty.\n", internalize_opts.api_file), to_standard_error = true);
            else {
                // line_iterator(Buf, SkipBlanks = true): '#' comment lines are skipped too
                for line: split(data, "\n") {
                    l := line;
                    if l.count && l[l.count - 1] == #char "\r" l.count -= 1;
                    if l.count == 0 || l[0] == #char "#" continue;
                    array_add(*s.patterns, l);
                }
            }
        }
        for internalize_opts.api_list array_add(*s.patterns, it);
    }

    changed := false;
    used: [..] Value_Id; used.allocator = temp;
    collect_used_global_variables(*used, false);

    cmap: Table(s32, Int_Comdat_Info); cmap.allocator = temp;
    if ir.comdats.count {
        for ir.m_functions int_check_comdat(*s, it, *cmap);
        for ir.m_globals int_check_comdat(*s, it, *cmap);
        for ir.m_aliases int_check_comdat(*s, it, *cmap);
    }
    for used array_add(*s.always_preserved, vname(it));
    for string.["llvm.used", "llvm.compiler.used", "llvm.global_ctors", "llvm.global_dtors", "llvm.global.annotations", "__stack_chk_fail"]
        array_add(*s.always_preserved, it);
    tt := triple_parse(ir.triple);
    if tt.os == .AIX array_add(*s.always_preserved, "__ssp_canary_word");
    else array_add(*s.always_preserved, "__stack_chk_guard");
    if tt.arch == .nvptx || tt.arch == .nvptx64 array_add(*s.always_preserved, "__llvm_rpc_client");
    s.is_wasm = tt.arch == .wasm32 || tt.arch == .wasm64 || tt.obj == .Wasm;

    for ir.m_functions if int_maybe_internalize(*s, it, *cmap) changed = true;
    for ir.m_globals if int_maybe_internalize(*s, it, *cmap) changed = true;
    for ir.m_aliases if int_maybe_internalize(*s, it, *cmap) changed = true;
    if changed { printer_note_ir_changed(); return PRESERVE_NONE; }
    return PRESERVE_ALL;
}
