// The part of the ModuleSummaryIndex that the LowerTypeTests / WholeProgramDevirt command-line test modes read
// (-lowertypetests-read-summary, -wholeprogramdevirt-read-summary): the YAML form of
// llvm/include/llvm/IR/ModuleSummaryIndexYAML.h (MappingTraits<ModuleSummaryIndex> and the traits it uses) and the
// index queries the passes make (llvm/include/llvm/IR/ModuleSummaryIndex.h, llvm/lib/IR/ModuleSummaryIndex.cpp:
// isGUIDLive, getTypeIdSummary, getOrInsertTypeIdSummary, getValueInfo, CfiFunctionIndex).
// The YAML reader is a small block/flow YAML parser for the subset these files use (block mappings and sequences,
// flow sequences and mappings, plain and quoted scalars, comments, `---` / `...`); anything else fails loudly.
// Writing summaries (-*-write-summary) is not ported and fails loudly.

// ---------------------------------------------------------------- YAML

Y_Kind :: enum u8 { NULL; SCALAR; MAP; SEQ; }
Y_Node :: struct {
    kind: Y_Kind;
    str: string;           // SCALAR
    keys: [..] string;     // MAP
    kids: [..] s32;        // MAP values / SEQ items
}
Y_Line :: struct { indent: s64; text: string; lineno: s64; }

yaml: struct {
    nodes: [..] Y_Node;
    lines: [..] Y_Line;
    pos: s64;
    file: string;
};

yaml_error :: (lineno: s64, msg: string) {
    fatal("%: line %: YAML: %", yaml.file, lineno, msg);
}

yaml_new :: (k: Y_Kind) -> s32 {
    n: Y_Node; n.kind = k;
    array_add(*yaml.nodes, n);
    return cast(s32) (yaml.nodes.count - 1);
}

// Strip a trailing `# comment` (a '#' at the start or after whitespace, outside quotes).
yaml_strip_comment :: (s: string) -> string {
    q: u8 = 0;
    for i: 0..s.count-1 {
        c := s[i];
        if q { if c == q q = 0; continue; }
        if c == #char "'" || c == #char "\"" { q = c; continue; }
        if c == #char "#" && (i == 0 || s[i-1] == #char " " || s[i-1] == #char "\t") return slice(s, 0, i);
    }
    return s;
}

yaml_trim :: (s: string) -> string {
    a := 0; b := s.count;
    while a < b && (s[a] == #char " " || s[a] == #char "\t" || s[a] == #char "\r") a += 1;
    while b > a && (s[b-1] == #char " " || s[b-1] == #char "\t" || s[b-1] == #char "\r") b -= 1;
    return slice(s, a, b - a);
}

yaml_unquote :: (s: string, lineno: s64) -> string {
    if s.count >= 2 && s[0] == #char "'" && s[s.count-1] == #char "'" {
        inner := slice(s, 1, s.count - 2);
        // '' is an escaped quote
        out: [..] u8; out.allocator = temp;
        i := 0;
        while i < inner.count {
            if inner[i] == #char "'" && i + 1 < inner.count && inner[i+1] == #char "'" { array_add(*out, #char "'"); i += 2; continue; }
            array_add(*out, inner[i]); i += 1;
        }
        r: string; r.data = out.data; r.count = out.count;
        return copy_string(r);
    }
    if s.count >= 2 && s[0] == #char "\"" && s[s.count-1] == #char "\"" {
        inner := slice(s, 1, s.count - 2);
        for i: 0..inner.count-1 if inner[i] == #char "\\" yaml_error(lineno, "escape sequences in double-quoted scalars are not supported");
        return copy_string(inner);
    }
    return s;
}

// Position of the ':' that ends a mapping key (followed by a space or the end), outside quotes; -1 if none.
yaml_key_colon :: (s: string) -> s64 {
    q: u8 = 0;
    depth := 0;
    for i: 0..s.count-1 {
        c := s[i];
        if q { if c == q q = 0; continue; }
        if c == #char "'" || c == #char "\"" { q = c; continue; }
        if c == #char "[" || c == #char "{" depth += 1;
        if c == #char "]" || c == #char "}" depth -= 1;
        if c == #char ":" && depth == 0 && (i + 1 == s.count || s[i+1] == #char " ") return i;
    }
    return -1;
}

yaml_scalar :: (s_in: string, lineno: s64) -> s32 {
    s := yaml_trim(s_in);
    if s.count == 0 || s == "null" || s == "~" || s == "Null" || s == "NULL" return yaml_new(.NULL);
    c := s[0];
    if c == #char "[" || c == #char "{" {
        rest := s;
        n := yaml_flow(*rest, lineno);
        if yaml_trim(rest).count yaml_error(lineno, "unexpected text after a flow collection");
        return n;
    }
    if c == #char "|" || c == #char ">" || c == #char "&" || c == #char "*" || c == #char "!" yaml_error(lineno, tprint("unsupported YAML construct '%'", s));
    n := yaml_new(.SCALAR);
    yaml.nodes[n].str = yaml_unquote(s, lineno);
    return n;
}

// Flow collection ([...] or {...}) at the start of `s`; advances `s` past it.
yaml_flow :: (s: *string, lineno: s64) -> s32 {
    skip_ws :: (s: *string) { while s.count && (s.*[0] == #char " " || s.*[0] == #char "\t") advance(s, 1); }
    // a flow scalar ends at ',', ']', '}' (and ':' + space for keys)
    flow_scalar :: (s: *string, lineno: s64, is_key: bool) -> string {
        skip_ws(s);
        if s.count && (s.*[0] == #char "'" || s.*[0] == #char "\"") {
            q := s.*[0];
            i := 1;
            while i < s.count && s.*[i] != q i += 1;
            if i >= s.count yaml_error(lineno, "unterminated quoted scalar");
            r := slice(s.*, 0, i + 1);
            advance(s, i + 1);
            return yaml_unquote(r, lineno);
        }
        i := 0;
        while i < s.count {
            ch := s.*[i];
            if ch == #char "," || ch == #char "]" || ch == #char "}" break;
            if is_key && ch == #char ":" break;
            i += 1;
        }
        r := yaml_trim(slice(s.*, 0, i));
        advance(s, i);
        return r;
    }
    skip_ws(s);
    open := s.*[0];
    advance(s, 1);
    close: u8 = ifx open == #char "[" then cast(u8) #char "]" else cast(u8) #char "}";
    n := yaml_new(ifx open == #char "[" then Y_Kind.SEQ else .MAP);
    while true {
        skip_ws(s);
        if s.count == 0 yaml_error(lineno, "unterminated flow collection (multi-line flow collections are not supported)");
        if s.*[0] == close { advance(s, 1); break; }
        key: string;
        if open == #char "{" {
            key = flow_scalar(s, lineno, true);
            skip_ws(s);
            if s.count == 0 || s.*[0] != #char ":" yaml_error(lineno, "expected ':' in a flow mapping");
            advance(s, 1);
        }
        skip_ws(s);
        v: s32;
        if s.count && (s.*[0] == #char "[" || s.*[0] == #char "{") v = yaml_flow(s, lineno);
        else {
            t := flow_scalar(s, lineno, false);
            if t.count == 0 || t == "null" || t == "~" v = yaml_new(.NULL);
            else { v = yaml_new(.SCALAR); yaml.nodes[v].str = t; }
        }
        if open == #char "{" array_add(*yaml.nodes[n].keys, key);
        array_add(*yaml.nodes[n].kids, v);
        skip_ws(s);
        if s.count && s.*[0] == #char "," { advance(s, 1); continue; }
        if s.count && s.*[0] == close { advance(s, 1); break; }
        yaml_error(lineno, "expected ',' or the end of a flow collection");
    }
    return n;
}

yaml_is_seq_item :: (t: string) -> bool { return t.count >= 1 && t[0] == #char "-" && (t.count == 1 || t[1] == #char " "); }

yaml_block :: (min_indent: s64) -> s32 {
    if yaml.pos >= yaml.lines.count return yaml_new(.NULL);
    l := yaml.lines[yaml.pos];
    if l.indent < min_indent return yaml_new(.NULL);
    ind := l.indent;
    if yaml_is_seq_item(l.text) {
        n := yaml_new(.SEQ);
        while yaml.pos < yaml.lines.count {
            cur := yaml.lines[yaml.pos];
            if cur.indent != ind || !yaml_is_seq_item(cur.text) break;
            rest := slice(cur.text, 1, cur.text.count - 1);
            k := 0;
            while k < rest.count && rest[k] == #char " " k += 1;
            rest = slice(rest, k, rest.count - k);
            item: s32;
            if rest.count == 0 {
                yaml.pos += 1;
                item = yaml_block(ind + 1);
            } else if yaml_is_seq_item(rest) || yaml_key_colon(rest) >= 0 {
                // the item's content continues as a block at the column of `rest`
                yaml.lines[yaml.pos].indent = ind + 1 + k;
                yaml.lines[yaml.pos].text = rest;
                item = yaml_block(ind + 1 + k);
            } else {
                yaml.pos += 1;
                item = yaml_scalar(rest, cur.lineno);
            }
            array_add(*yaml.nodes[n].kids, item);
        }
        return n;
    }
    c := yaml_key_colon(l.text);
    if c < 0 {
        if yaml.pos + 1 < yaml.lines.count && yaml.lines[yaml.pos + 1].indent > ind yaml_error(l.lineno, "multi-line scalars are not supported");
        yaml.pos += 1;
        return yaml_scalar(l.text, l.lineno);
    }
    n := yaml_new(.MAP);
    while yaml.pos < yaml.lines.count {
        cur := yaml.lines[yaml.pos];
        if cur.indent < ind break;
        if cur.indent > ind yaml_error(cur.lineno, "bad indentation");
        if yaml_is_seq_item(cur.text) break;
        cc := yaml_key_colon(cur.text);
        if cc < 0 yaml_error(cur.lineno, "expected a mapping key");
        key := yaml_unquote(yaml_trim(slice(cur.text, 0, cc)), cur.lineno);
        val := yaml_trim(slice(cur.text, cc + 1, cur.text.count - cc - 1));
        yaml.pos += 1;
        v: s32;
        if val.count == 0 {
            if yaml.pos < yaml.lines.count && yaml.lines[yaml.pos].indent > ind v = yaml_block(ind + 1);
            else if yaml.pos < yaml.lines.count && yaml.lines[yaml.pos].indent == ind && yaml_is_seq_item(yaml.lines[yaml.pos].text) v = yaml_block(ind);
            else v = yaml_new(.NULL);
        } else {
            v = yaml_scalar(val, cur.lineno);
        }
        for yaml.nodes[n].keys if it == key yaml_error(cur.lineno, tprint("duplicated mapping key '%'", key));
        array_add(*yaml.nodes[n].keys, key);
        array_add(*yaml.nodes[n].kids, v);
    }
    return n;
}

yaml_parse :: (text: string, file: string) -> s32 {
    yaml.nodes.count = 0; yaml.lines.count = 0; yaml.pos = 0; yaml.file = file;
    lineno := 0;
    docs := 0;
    rest := text;
    while rest.count {
        lineno += 1;
        e := 0;
        while e < rest.count && rest[e] != #char "\n" e += 1;
        line := slice(rest, 0, e);
        advance(*rest, min(e + 1, rest.count));
        if line.count && line[line.count - 1] == #char "\r" line.count -= 1;
        for i: 0..line.count-1 if line[i] == #char "\t" { s := yaml_trim(line); if s.count && s[0] != #char "#" yaml_error(lineno, "tabs are not supported"); }
        s := yaml_strip_comment(line);
        if yaml_trim(s).count == 0 continue;
        if begins_with(s, "---") { docs += 1; if docs > 1 yaml_error(lineno, "multiple documents are not supported"); if yaml_trim(slice(s, 3, s.count - 3)).count yaml_error(lineno, "content after '---' is not supported"); continue; }
        if begins_with(s, "...") break;
        ind := 0;
        while ind < s.count && s[ind] == #char " " ind += 1;
        array_add(*yaml.lines, .{ind, yaml_trim(slice(s, ind, s.count - ind)), lineno});
    }
    if yaml.lines.count == 0 return yaml_new(.NULL);
    root := yaml_block(0);
    if yaml.pos < yaml.lines.count yaml_error(yaml.lines[yaml.pos].lineno, "unexpected content");
    return root;
}

// ---------------------------------------------------------------- the index

// TypeTestResolution::Kind (declaration order)
Tt_Kind :: enum u8 { Unsat; ByteArray; Inline; Single; AllOnes; Unknown; }
Tt_Res :: struct {
    kind: Tt_Kind = .Unsat;
    size_m1_bit_width: u32;
    align_log2: u64;
    size_m1: u64;
    bit_mask: u8;
    inline_bits: u64;
}
// WholeProgramDevirtResolution::ByArg::Kind
By_Arg_Kind :: enum u8 { Indir; UniformRetVal; UniqueRetVal; VirtualConstProp; }
By_Arg :: struct { kind: By_Arg_Kind; info: u64; byte: u32; bit: u32; }
By_Arg_Entry :: struct { args: [..] u64; res: By_Arg; }   // std::map<std::vector<uint64_t>, ByArg>, kept sorted
// WholeProgramDevirtResolution::Kind
Wpd_Kind :: enum u8 { Indir; SingleImpl; BranchFunnel; }
Wpd_Res :: struct { kind: Wpd_Kind; single_impl_name: string; res_by_arg: [..] By_Arg_Entry; }
Wpd_Entry :: struct { offset: u64; res: Wpd_Res; }        // std::map<uint64_t, WholeProgramDevirtResolution>, sorted
Type_Id_Summary :: struct { name: string; guid: u64; tt: Tt_Res; wpd: [..] Wpd_Entry; }

Vfunc_Id :: struct { guid: u64; offset: u64; }
Const_Vcall :: struct { vfunc: Vfunc_Id; args: [..] u64; }
Gv_Summary :: struct {
    linkage: Linkage;
    visibility: u8;
    live: bool;
    is_alias: bool;
    aliasee_guid: u64;        // alias: the aliasee's GUID
    aliasee_has_summary: bool; // fixAliaseeLinks found a summary for the aliasee
    refs: [..] u64;
    type_tests: [..] u64;
    tt_assume_vcalls: [..] Vfunc_Id;
    tcl_vcalls: [..] Vfunc_Id;
    tt_assume_const_vcalls: [..] Const_Vcall;
    tcl_const_vcalls: [..] Const_Vcall;
}
Gv_Info :: struct { guid: u64; sums: [..] Gv_Summary; }

Summary_Index :: struct {
    present: bool;
    gvs: [..] Gv_Info;               // GlobalValueMap (insertion order, see si_gv_get_or_insert)
    gv_map: Table(u64, s64);         // GUID -> index in gvs
    type_ids: [..] Type_Id_Summary;  // TypeIdMap (std::multimap by GUID; insertion order within a GUID)
    with_dead_stripping: bool;       // WithGlobalValueDeadStripping
    partially_split: bool;           // partiallySplitLTOUnits (not in the YAML form)
    cfi_defs: [..] string;           // CfiFunctionDefs
    cfi_decls: [..] string;          // CfiFunctionDecls
}

// GlobalValue::getGUIDAssumingExternalLinkage
guid_of_name :: (s: string) -> u64 {
    n := s;
    if n.count && n[0] == 1 n = slice(n, 1, n.count - 1);
    return md5_hash_u64(n);
}

si_gv_index :: (si: *Summary_Index, guid: u64) -> s64 {
    found, k := table_find(*si.gv_map, guid);
    if found return k;
    return -1;
}
// GlobalValueMap.try_emplace(GUID): new entries go to the end (GlobalValueSummaryMap's Storage is a deque in
// insertion order; begin()/end() iterate it in that order)
si_gv_get_or_insert :: (si: *Summary_Index, guid: u64) -> s64 {
    found, k := table_find(*si.gv_map, guid);
    if found return k;
    e: Gv_Info; e.guid = guid;
    array_add(*si.gvs, e);
    table_add(*si.gv_map, guid, si.gvs.count - 1);
    return si.gvs.count - 1;
}
// isGlobalValueLive
si_gv_live :: (si: *Summary_Index, s: *Gv_Summary) -> bool { return !si.with_dead_stripping || s.live; }
// isGUIDLive
si_guid_live :: (si: *Summary_Index, guid: u64) -> bool {
    k := si_gv_index(si, guid);
    if k < 0 return true;
    if si.gvs[k].sums.count == 0 return true;
    for * si.gvs[k].sums if si_gv_live(si, it) return true;
    return false;
}
// getTypeIdSummary: index into type_ids, -1 if absent
si_type_id_summary :: (si: *Summary_Index, name: string) -> s64 {
    g := guid_of_name(name);
    for * si.type_ids if it.guid == g && it.name == name return it_index;
    return -1;
}
// TypeIdMap.insert (std::multimap by GUID: after the entries with an equal GUID)
si_insert_type_id :: (si: *Summary_Index, t: Type_Id_Summary) -> s64 {
    pos := si.type_ids.count;
    for si.type_ids if it.guid > t.guid { pos = it_index; break; }
    array_insert_at(*si.type_ids, t, pos);
    return pos;
}
// getOrInsertTypeIdSummary
si_get_or_insert_type_id_summary :: (si: *Summary_Index, name: string) -> s64 {
    k := si_type_id_summary(si, name);
    if k >= 0 return k;
    e: Type_Id_Summary; e.name = copy_string(name); e.guid = guid_of_name(name);
    return si_insert_type_id(si, e);
}
si_cfi_contains :: (list: [] string, name: string) -> bool { for list if it == name return true; return false; }

// ---------------------------------------------------------------- YAML -> index

ys_get :: (n: s32, key: string) -> s32 {
    if yaml.nodes[n].kind != .MAP return -1;
    for yaml.nodes[n].keys if it == key return yaml.nodes[n].kids[it_index];
    return -1;
}
ys_check_keys :: (n: s32, allowed: [] string, what: string) {
    if yaml.nodes[n].kind == .NULL return;
    if yaml.nodes[n].kind != .MAP fatal("%: YAML: expected a mapping for %", yaml.file, what);
    for k: yaml.nodes[n].keys {
        ok := false;
        for allowed if it == k ok = true;
        if !ok fatal("%: YAML: unknown key '%' in %", yaml.file, k, what);
    }
}
ys_str :: (n: s32) -> string {
    if n < 0 || yaml.nodes[n].kind == .NULL return "";
    if yaml.nodes[n].kind != .SCALAR fatal("%: YAML: expected a scalar", yaml.file);
    return yaml.nodes[n].str;
}
// ScalarTraits<uint64_t>: getAsUnsignedInteger(Scalar, 0, N)
ys_u64 :: (n: s32, dflt: u64 = 0) -> u64 {
    if n < 0 return dflt;
    s := ys_str(n);
    v, ok := str_to_u64_auto(s);
    if !ok fatal("%: YAML: invalid number '%'", yaml.file, s);
    return v;
}
ys_bool :: (n: s32) -> bool {
    if n < 0 return false;
    s := ys_str(n);
    if s == "true" || s == "True" || s == "TRUE" || s == "1" return true;
    if s == "false" || s == "False" || s == "FALSE" || s == "0" return false;
    fatal("%: YAML: invalid boolean '%'", yaml.file, s);
    return false;
}
ys_seq :: (n: s32) -> [] s32 {
    if n < 0 || yaml.nodes[n].kind == .NULL { e: [] s32; return e; }
    if yaml.nodes[n].kind != .SEQ fatal("%: YAML: expected a sequence", yaml.file);
    return yaml.nodes[n].kids;
}
ys_vfunc :: (n: s32) -> Vfunc_Id {
    ys_check_keys(n, .["GUID", "Offset"], "a VFuncId");
    return .{ys_u64(ys_get(n, "GUID")), ys_u64(ys_get(n, "Offset"))};
}

read_summary_yaml :: (path: string, si: *Summary_Index, option: string) {
    text, ok := read_entire_file(path);
    if !ok fatal("%: %: Could not open file", option, path);
    root := yaml_parse(text, path);
    si.present = true;
    if yaml.nodes[root].kind == .NULL return;
    ys_check_keys(root, .["GlobalValueMap", "TypeIdMap", "WithGlobalValueDeadStripping", "CfiFunctionDefs", "CfiFunctionDecls"], "ModuleSummaryIndex");
    gvm := ys_get(root, "GlobalValueMap");
    if gvm >= 0 && yaml.nodes[gvm].kind != .NULL {
        if yaml.nodes[gvm].kind != .MAP fatal("%: YAML: GlobalValueMap must be a mapping", path);
        // Input::keys() iterates the MapHNode's StringMap: bucket order
        for ki: yaml_stringmap_order(yaml.nodes[gvm].keys) {
            key := yaml.nodes[gvm].keys[ki];
            sums := ys_seq(yaml.nodes[gvm].kids[ki]);
            guid, gok := str_to_u64_auto(key);
            if !gok fatal("%: YAML: key not an integer", path);
            e := si_gv_get_or_insert(si, guid);
            for sn: sums {
                ys_check_keys(sn, .["Linkage", "Visibility", "NotEligibleToImport", "Live", "Local", "CanAutoHide", "ImportType", "NoRenameOnPromotion", "Aliasee", "Refs", "TypeTests", "TypeTestAssumeVCalls", "TypeCheckedLoadVCalls", "TypeTestAssumeConstVCalls", "TypeCheckedLoadConstVCalls"], "a GlobalValueSummary");
                s: Gv_Summary;
                s.linkage = cast(Linkage) ys_u64(ys_get(sn, "Linkage"));
                s.visibility = cast(u8) ys_u64(ys_get(sn, "Visibility"));
                s.live = ys_bool(ys_get(sn, "Live"));
                al := ys_get(sn, "Aliasee");
                if al >= 0 && yaml.nodes[al].kind != .NULL {
                    s.is_alias = true;
                    s.aliasee_guid = ys_u64(al);
                    si_gv_get_or_insert(si, s.aliasee_guid);
                } else {
                    for r: ys_seq(ys_get(sn, "Refs")) { g := ys_u64(r); array_add(*s.refs, g); si_gv_get_or_insert(si, g); }
                    for r: ys_seq(ys_get(sn, "TypeTests")) array_add(*s.type_tests, ys_u64(r));
                    for r: ys_seq(ys_get(sn, "TypeTestAssumeVCalls")) array_add(*s.tt_assume_vcalls, ys_vfunc(r));
                    for r: ys_seq(ys_get(sn, "TypeCheckedLoadVCalls")) array_add(*s.tcl_vcalls, ys_vfunc(r));
                    for pass: 0..1 {
                        for r: ys_seq(ys_get(sn, ifx pass == 0 then "TypeTestAssumeConstVCalls" else "TypeCheckedLoadConstVCalls")) {
                            ys_check_keys(r, .["VFunc", "Args"], "a ConstVCall");
                            cv: Const_Vcall;
                            vf := ys_get(r, "VFunc");
                            if vf >= 0 cv.vfunc = ys_vfunc(vf);
                            for a: ys_seq(ys_get(r, "Args")) array_add(*cv.args, ys_u64(a));
                            if pass == 0 array_add(*s.tt_assume_const_vcalls, cv); else array_add(*s.tcl_const_vcalls, cv);
                        }
                    }
                }
                array_add(*si.gvs[e].sums, s);
            }
        }
        // fixAliaseeLinks
        for * gi: si.gvs for * s: gi.sums if s.is_alias {
            k := si_gv_index(si, s.aliasee_guid);
            s.aliasee_has_summary = k >= 0 && si.gvs[k].sums.count > 0;
        }
    }
    tim := ys_get(root, "TypeIdMap");
    if tim >= 0 && yaml.nodes[tim].kind != .NULL {
        if yaml.nodes[tim].kind != .MAP fatal("%: YAML: TypeIdMap must be a mapping", path);
        for key, ki: yaml.nodes[tim].keys {
            tn := yaml.nodes[tim].kids[ki];
            ys_check_keys(tn, .["TTRes", "WPDRes"], "a TypeIdSummary");
            t: Type_Id_Summary;
            t.name = copy_string(key);
            t.guid = guid_of_name(key);
            tt := ys_get(tn, "TTRes");
            if tt >= 0 {
                ys_check_keys(tt, .["Kind", "SizeM1BitWidth", "AlignLog2", "SizeM1", "BitMask", "InlineBits"], "a TypeTestResolution");
                k := ys_get(tt, "Kind");
                if k >= 0 {
                    ks := ys_str(k);
                    if ks == "Unknown" t.tt.kind = .Unknown;
                    else if ks == "Unsat" t.tt.kind = .Unsat;
                    else if ks == "ByteArray" t.tt.kind = .ByteArray;
                    else if ks == "Inline" t.tt.kind = .Inline;
                    else if ks == "Single" t.tt.kind = .Single;
                    else if ks == "AllOnes" t.tt.kind = .AllOnes;
                    else fatal("%: YAML: unknown enumerated scalar '%'", path, ks);
                }
                t.tt.size_m1_bit_width = cast(u32) ys_u64(ys_get(tt, "SizeM1BitWidth"));
                t.tt.align_log2 = ys_u64(ys_get(tt, "AlignLog2"));
                t.tt.size_m1 = ys_u64(ys_get(tt, "SizeM1"));
                t.tt.bit_mask = cast(u8) ys_u64(ys_get(tt, "BitMask"));
                t.tt.inline_bits = ys_u64(ys_get(tt, "InlineBits"));
            }
            wr := ys_get(tn, "WPDRes");
            if wr >= 0 && yaml.nodes[wr].kind != .NULL {
                if yaml.nodes[wr].kind != .MAP fatal("%: YAML: WPDRes must be a mapping", path);
                for okey, oi: yaml.nodes[wr].keys {
                    off, ook := str_to_u64_auto(okey);
                    if !ook fatal("%: YAML: key not an integer", path);
                    rn := yaml.nodes[wr].kids[oi];
                    ys_check_keys(rn, .["Kind", "SingleImplName", "ResByArg"], "a WholeProgramDevirtResolution");
                    w: Wpd_Entry; w.offset = off;
                    k := ys_get(rn, "Kind");
                    if k >= 0 {
                        ks := ys_str(k);
                        if ks == "Indir" w.res.kind = .Indir;
                        else if ks == "SingleImpl" w.res.kind = .SingleImpl;
                        else if ks == "BranchFunnel" w.res.kind = .BranchFunnel;
                        else fatal("%: YAML: unknown enumerated scalar '%'", path, ks);
                    }
                    w.res.single_impl_name = copy_string(ys_str(ys_get(rn, "SingleImplName")));
                    rba := ys_get(rn, "ResByArg");
                    if rba >= 0 && yaml.nodes[rba].kind != .NULL {
                        if yaml.nodes[rba].kind != .MAP fatal("%: YAML: ResByArg must be a mapping", path);
                        for akey, ai: yaml.nodes[rba].keys {
                            be: By_Arg_Entry;
                            // the key is a comma-separated list of integers ('' = no arguments)
                            rest := akey;
                            while rest.count {
                                c := 0;
                                while c < rest.count && rest[c] != #char "," c += 1;
                                v, vok := str_to_u64_auto(slice(rest, 0, c));
                                if !vok fatal("%: YAML: key not an integer", path);
                                array_add(*be.args, v);
                                advance(*rest, min(c + 1, rest.count));
                            }
                            an := yaml.nodes[rba].kids[ai];
                            ys_check_keys(an, .["Kind", "Info", "Byte", "Bit"], "a ByArg resolution");
                            ak := ys_get(an, "Kind");
                            if ak >= 0 {
                                ks := ys_str(ak);
                                if ks == "Indir" be.res.kind = .Indir;
                                else if ks == "UniformRetVal" be.res.kind = .UniformRetVal;
                                else if ks == "UniqueRetVal" be.res.kind = .UniqueRetVal;
                                else if ks == "VirtualConstProp" be.res.kind = .VirtualConstProp;
                                else fatal("%: YAML: unknown enumerated scalar '%'", path, ks);
                            }
                            be.res.info = ys_u64(ys_get(an, "Info"));
                            be.res.byte = cast(u32) ys_u64(ys_get(an, "Byte"));
                            be.res.bit = cast(u32) ys_u64(ys_get(an, "Bit"));
                            // std::map order: lexicographic on the argument vector
                            pos := w.res.res_by_arg.count;
                            for x: w.res.res_by_arg if u64_vec_less(be.args, x.args) { pos = it_index; break; }
                            array_insert_at(*w.res.res_by_arg, be, pos);
                        }
                    }
                    pos := t.wpd.count;
                    for x: t.wpd if w.offset < x.offset { pos = it_index; break; }
                    array_insert_at(*t.wpd, w, pos);
                }
            }
            si_insert_type_id(si, t);
        }
    }
    si.with_dead_stripping = ys_bool(ys_get(root, "WithGlobalValueDeadStripping"));
    for pass: 0..1 {
        for e: ys_seq(ys_get(root, ifx pass == 0 then "CfiFunctionDefs" else "CfiFunctionDecls")) {
            ys_check_keys(e, .["Name", "GUID"], "a CFI function");
            nm := copy_string(ys_str(ys_get(e, "Name")));
            if pass == 0 array_add(*si.cfi_defs, nm); else array_add(*si.cfi_decls, nm);
        }
    }
}

// The iteration order of a StringMap<> filled with `keys` in order (llvm/lib/Support/StringMap.cpp: xxh3_64bits
// truncated to 32 bits, linear probing, 16 initial buckets, doubling when more than 3/4 full): indices into keys
yaml_stringmap_order :: (keys: [] string) -> [..] s64 {
    nb: u32 = 16;
    table := NewArray(nb, s64,, allocator = temp);
    hashes := NewArray(nb, u32,, allocator = temp);
    for * table it.* = -1;
    n: u32 = 0;
    for key, ki: keys {
        h := cast(u32) (xxh3_64bits(cast([] u8) key) & 0xFFFF_FFFF);
        b := h & (nb - 1);
        while table[b] >= 0 b = (b + 1) & (nb - 1);
        table[b] = ki; hashes[b] = h;
        n += 1;
        if n * 4 > nb * 3 {
            ns := nb * 2;
            nt := NewArray(ns, s64,, allocator = temp);
            nh := NewArray(ns, u32,, allocator = temp);
            for * nt it.* = -1;
            for i: 0..nb-1 {
                if table[i] < 0 continue;
                x := hashes[i] & (ns - 1);
                while nt[x] >= 0 x = (x + 1) & (ns - 1);
                nt[x] = table[i]; nh[x] = hashes[i];
            }
            table = nt; hashes = nh; nb = ns;
        }
    }
    out: [..] s64; out.allocator = temp;
    for table if it >= 0 array_add(*out, it);
    return out;
}

u64_vec_less :: (a: [] u64, b: [] u64) -> bool {
    n := min(a.count, b.count);
    for i: 0..n-1 { if a[i] < b[i] return true; if a[i] > b[i] return false; }
    return a.count < b.count;
}
