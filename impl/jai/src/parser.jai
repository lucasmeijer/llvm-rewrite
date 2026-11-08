// Port of llvm/lib/AsmParser/LLParser.cpp (textual IR -> IR tables).
// Reproduces LLParser's creation order and forward-reference placeholders (see DESIGN.md §3), because they
// decide use-list order and module list order.

Parser :: struct {
    lx:  Lexer;
    tok: Token;

    numbered_globals: Table(u32, Value_Id);
    next_global_id: u32;
    fwd_globals:     Table(string, Value_Id);
    fwd_global_ids:  Table(u32, Value_Id);
    fwd_global_order: [..] Value_Id;

    numbered_types: Table(u32, Type_Id);

    attr_groups: Table(u32, [..] Attr);
    fwd_attr_refs: [..] Fwd_Attr_Ref;

    md_numbered: Table(u32, Md_Id);        // temporary per forward-referenced number
    md_defined:  Table(u32, Md_Id);        // defined nodes

    // per function
    fnv: Value_Id = NONE;
    local_numbered: Table(u32, Value_Id);
    local_next: u32;
    fwd_locals:     Table(string, Value_Id);
    fwd_local_ids:  Table(u32, Value_Id);

    blockaddr_fwd: [..] Blockaddr_Fwd;
    insts_with_tbaa: [..] Value_Id;
    pending_arg_ids: [..] u32;
    callee_fty: Type_Id = NONE;
}

Fwd_Attr_Ref :: struct { v: Value_Id; groups: [..] u32; is_call: bool; is_gvar: bool; }
Blockaddr_Fwd :: struct { placeholder: Value_Id; fn_name: string; fn_id: u32; by_id: bool; bb_name: string; bb_id: u32; bb_by_id: bool; }

P: Parser;

// ---------------------------------------------------------------- token helpers

next :: inline () { P.tok = lex(*P.lx); }
is_kw :: inline (s: string) -> bool { return P.tok.kind == .KW && P.tok.text == s; }
eat_kw :: (s: string) -> bool { if is_kw(s) { next(); return true; } return false; }
eat :: (k: Tok) -> bool { if P.tok.kind == k { next(); return true; } return false; }

perr :: (fmt: string, args: .. Any) {
    line, col := line_col(P.lx.src, P.tok.pos);
    s := tprint(fmt, ..args);
    fatal("%:%:%: %", P.lx.file, line, col, s);
}
expect :: (k: Tok, what: string) { if !eat(k) perr("expected %", what); }
expect_kw :: (s: string) { if !eat_kw(s) perr("expected '%'", s); }

parse_uint :: () -> u64 {
    if P.tok.kind != .APSINT || P.tok.hex_kind != 0 || (P.tok.text.count && P.tok.text[0] == #char "-") perr("expected integer");
    v: u64 = 0;
    for i: 0..P.tok.text.count-1 v = v * 10 + cast(u64)(P.tok.text[i] - #char "0");
    next();
    return v;
}
parse_string :: () -> string {
    if P.tok.kind != .STRING perr("expected string constant");
    s := P.tok.text;
    next();
    return s;
}

// ---------------------------------------------------------------- module

parse_module :: (src: string, file: string) {
    P.lx.src = src;
    P.lx.file = file;
    next();
    // target definitions first (LLParser::parseTargetDefinitions)
    while true {
        if is_kw("target") {
            next();
            if eat_kw("triple") { expect(.EQUAL, "'='"); ir.triple = parse_string(); }
            else if eat_kw("datalayout") { expect(.EQUAL, "'='"); ir.datalayout = parse_string(); }
            else perr("unknown target property");
        } else if is_kw("source_filename") {
            next(); expect(.EQUAL, "'='"); ir.source_filename = parse_string(); saw_source_filename = true;
        } else break;
    }
    if ir.datalayout.count == 0 && ir.triple.count {
        d, ok := compute_default_datalayout(ir.triple);
        if !ok fatal("%: no default data layout for target triple '%' (only x86 is supported)", file, ir.triple);
        ir.datalayout = d;
    }
    dl_init(ir.datalayout);
    while P.tok.kind != .EOF parse_top_level();
    validate_end_of_module();
}

parse_top_level :: () {
    t := P.tok;
    if t.kind == {
        case .KW;
            if t.text == "declare" { next(); parse_declare(); return; }
            if t.text == "define" { next(); parse_define(); return; }
            if t.text == "module" { next(); expect_kw("asm"); array_add(*ir.module_asm, parse_string()); return; }
            if t.text == "target" || t.text == "source_filename" {
                next();
                if t.text == "target" {
                    if eat_kw("triple") { expect(.EQUAL, "'='"); ir.triple = parse_string(); }
                    else if eat_kw("datalayout") { expect(.EQUAL, "'='"); ir.datalayout = parse_string(); dl_init(ir.datalayout); }
                } else { expect(.EQUAL, "'='"); ir.source_filename = parse_string(); saw_source_filename = true; }
                return;
            }
            if t.text == "attributes" { next(); parse_attr_group(); return; }
            if t.text == "uselistorder" || t.text == "uselistorder_bb" perr("uselistorder directives are not supported");
            perr("expected top-level entity");
        case .LOCAL_VAR; parse_named_type(); return;
        case .LOCAL_ID; parse_unnamed_type(); return;
        case .GLOBAL_VAR; #through;
        case .GLOBAL_ID; parse_global_def(); return;
        case .COMDAT_VAR; parse_comdat(); return;
        case .METADATA_VAR; parse_named_metadata(); return;
        case .EXCLAIM; parse_standalone_metadata(); return;
        case .SUMMARY_ID; perr("module summaries are not supported");
    }
    perr("expected top-level entity");
}

// ---------------------------------------------------------------- types

get_named_type :: (name: string) -> Type_Id {
    found, t := table_find(*ir.named_types, name);
    if found return t;
    s := intern_str(name);
    t = type_named_struct(s);
    table_add(*ir.named_types, s, t);
    return t;
}

parse_named_type :: () {
    name := P.tok.text;
    next();
    expect(.EQUAL, "'='");
    expect_kw("type");
    parse_struct_definition(name, false, 0);
}
parse_unnamed_type :: () {
    id := cast(u32) P.tok.uval;
    next();
    expect(.EQUAL, "'='");
    expect_kw("type");
    parse_struct_definition("", true, id);
}

parse_struct_definition :: (name: string, numbered: bool, id: u32) {
    existing: Type_Id = NONE;
    if numbered {
        found, t := table_find(*P.numbered_types, id);
        if found existing = t;
    } else {
        found, t := table_find(*ir.named_types, name);
        if found existing = t;
    }
    if is_kw("opaque") {
        next();
        if existing == NONE {
            t := ifx numbered then type_named_struct("") else get_named_type(name);
            if numbered table_add(*P.numbered_types, id, t);
        }
        return;
    }
    packed := false;
    if P.tok.kind == .LESS {
        // could be a packed struct <{ ... }> or a vector type alias
        save := P.lx.pos; savetok := P.tok;
        next();
        if P.tok.kind == .LBRACE { packed = true; }
        else { P.lx.pos = save; P.tok = savetok; }
    }
    if P.tok.kind == .LBRACE {
        next();
        elts: [..] Type_Id; elts.allocator = temp;
        if P.tok.kind != .RBRACE {
            while true {
                array_add(*elts, parse_type());
                if !eat(.COMMA) break;
            }
        }
        expect(.RBRACE, "'}'");
        if packed expect(.GREATER, "'>'");
        t := existing;
        if t == NONE {
            t = ifx numbered then type_named_struct("") else get_named_type(name);
            if numbered table_add(*P.numbered_types, id, t);
        }
        set_struct_body(t, elts, packed);
        return;
    }
    // non-struct type: the name is an alias for the type
    ty := parse_type();
    if numbered table_add(*P.numbered_types, id, ty);
    else table_set(*ir.named_types, intern_str(name), ty);
}

parse_type :: (allow_void := false) -> Type_Id {
    t: Type_Id = NONE;
    tk := P.tok;
    if tk.kind == {
        case .INT_TYPE; next(); t = type_int(tk.uval);
        case .BYTE_TYPE; next(); t = type_byte(tk.uval);
        case .KW;
            s := tk.text;
            if s == "void" { next(); t = ir.t_void; }
            else if s == "half" { next(); t = type_simple(.HALF); }
            else if s == "bfloat" { next(); t = type_simple(.BFLOAT); }
            else if s == "float" { next(); t = type_simple(.FLOAT); }
            else if s == "double" { next(); t = type_simple(.DOUBLE); }
            else if s == "x86_fp80" { next(); t = type_simple(.X86_FP80); }
            else if s == "fp128" { next(); t = type_simple(.FP128); }
            else if s == "ppc_fp128" { next(); t = type_simple(.PPC_FP128); }
            else if s == "label" { next(); t = ir.t_label; }
            else if s == "metadata" { next(); t = ir.t_metadata; }
            else if s == "x86_amx" { next(); t = type_simple(.X86_AMX); }
            else if s == "token" { next(); t = ir.t_token; }
            else if s == "ptr" {
                next();
                as := parse_optional_addrspace();
                t = type_ptr(as);
            } else if s == "target" {
                next();
                t = parse_target_ext_type();
            } else if s == "opaque" { perr("opaque type only allowed in type definitions"); }
            else perr("expected type");
        case .LOCAL_VAR; next(); t = get_named_type(tk.text);
        case .LOCAL_ID;
            next();
            found, tt := table_find(*P.numbered_types, cast(u32) tk.uval);
            if found t = tt;
            else { t = type_named_struct(""); table_add(*P.numbered_types, cast(u32) tk.uval, t); }
        case .LBRACE;
            next();
            elts: [..] Type_Id; elts.allocator = temp;
            if P.tok.kind != .RBRACE {
                while true { array_add(*elts, parse_type()); if !eat(.COMMA) break; }
            }
            expect(.RBRACE, "'}'");
            t = type_literal_struct(elts, false);
        case .LSQUARE;
            next();
            n := parse_uint();
            expect_kw("x");
            elt := parse_type();
            expect(.RSQUARE, "']'");
            t = type_array(n, elt);
        case .LESS;
            next();
            if P.tok.kind == .LBRACE {
                next();
                elts: [..] Type_Id; elts.allocator = temp;
                if P.tok.kind != .RBRACE {
                    while true { array_add(*elts, parse_type()); if !eat(.COMMA) break; }
                }
                expect(.RBRACE, "'}'");
                expect(.GREATER, "'>'");
                t = type_literal_struct(elts, true);
            } else {
                scalable := false;
                if eat_kw("vscale") { expect_kw("x"); scalable = true; }
                n := parse_uint();
                expect_kw("x");
                elt := parse_type();
                expect(.GREATER, "'>'");
                t = type_vector(n, elt, scalable);
            }
        case;
            perr("expected type");
    }
    // function types and pointer stars
    while true {
        if P.tok.kind == .LPAREN {
            t = parse_function_type(t);
        } else if P.tok.kind == .STAR {
            perr("ptr* is invalid - use ptr instead");
        } else if is_kw("addrspace") {
            perr("ptr* is invalid - use ptr instead");
        } else break;
    }
    if !allow_void && t == ir.t_void perr("void type only allowed for function results");
    return t;
}

parse_function_type :: (ret: Type_Id) -> Type_Id {
    expect(.LPAREN, "'('");
    params: [..] Type_Id; params.allocator = temp;
    vararg := false;
    if P.tok.kind != .RPAREN {
        while true {
            if P.tok.kind == .DOTDOTDOT { next(); vararg = true; break; }
            pt := parse_type();
            // attributes and names in a function type are not allowed (LLParser::parseArgumentList(.., true))
            array_add(*params, pt);
            if !eat(.COMMA) break;
        }
    }
    expect(.RPAREN, "')'");
    return type_func(ret, params, vararg);
}

parse_target_ext_type :: () -> Type_Id {
    expect(.LPAREN, "'('");
    name := parse_string();
    tys: [..] Type_Id; tys.allocator = temp;
    ints: [..] u32; ints.allocator = temp;
    while eat(.COMMA) {
        if P.tok.kind == .APSINT array_add(*ints, cast(u32) parse_uint());
        else array_add(*tys, parse_type());
    }
    expect(.RPAREN, "')'");
    return intern_target_ext(name, tys, ints);
}

// TargetExtType::get
intern_target_ext :: (name: string, tys: [] Type_Id, ints: [] u32) -> Type_Id {
    k := *type_key; key_reset(k);
    key_u8(k, cast(u8) Type_Kind.TARGET_EXT); key_str(k, name);
    for tys key_u32(k, it);
    key_u8(k, 0xFF);
    for ints key_u32(k, it);
    found, id := table_find(*ir.type_map, key_view(k));
    if found return id;
    row: Type_Row; row.kind = .TARGET_EXT; row.name = intern_str(name);
    row.sub = cast(u32) ir.type_list.count; row.nsub = cast(u32) tys.count;
    for tys array_add(*ir.type_list, it);
    row.ints = cast(u32) ir.type_list.count; row.nints = cast(u32) ints.count;
    for ints array_add(*ir.type_list, it);
    id = new_type_row(row);
    table_add(*ir.type_map, key_copy(k), id);
    return id;
}

parse_optional_addrspace :: () -> u32 {
    if !is_kw("addrspace") return 0;
    next();
    expect(.LPAREN, "'('");
    as: u32 = 0;
    if P.tok.kind == .STRING {
        s := parse_string();
        if s == "A" as = dl.alloca_as;
        else if s == "G" as = dl.globals_as;
        else if s == "P" as = dl.program_as;
        else perr("unknown address space name");
    } else as = cast(u32) parse_uint();
    expect(.RPAREN, "')'");
    return as;
}

// ---------------------------------------------------------------- comdat

get_comdat :: (name: string) -> s32 {
    found, id := table_find(*ir.comdat_map, name);
    if found return id;
    s := intern_str(name);
    array_add(*ir.comdats, .{s, 0});
    id = cast(s32)(ir.comdats.count - 1);
    table_add(*ir.comdat_map, s, id);
    return id;
}

parse_comdat :: () {
    name := P.tok.text;
    next();
    expect(.EQUAL, "'='");
    expect_kw("comdat");
    kind: u8 = 0;
    if eat_kw("any") kind = 0;
    else if eat_kw("exactmatch") kind = 1;
    else if eat_kw("largest") kind = 2;
    else if eat_kw("nodeduplicate") kind = 3;
    else if eat_kw("samesize") kind = 4;
    else perr("unknown selection kind");
    id := get_comdat(name);
    ir.comdats[id].kind = kind;
}

parse_optional_comdat :: (gname: string) -> s32 {
    if !is_kw("comdat") return -1;
    next();
    if P.tok.kind == .LPAREN {
        next();
        if P.tok.kind != .COMDAT_VAR perr("expected comdat variable");
        name := P.tok.text;
        next();
        expect(.RPAREN, "')'");
        return get_comdat(name);
    }
    if gname.count == 0 perr("comdat cannot be unnamed");
    return get_comdat(gname);
}

// ---------------------------------------------------------------- linkage etc.

Linkage_Info :: struct {
    linkage: Linkage;
    has_linkage: bool;
    visibility: u8;
    dll: u8;
    dso_local: bool;
}

parse_optional_linkage :: () -> Linkage_Info {
    li: Linkage_Info;
    li.has_linkage = true;
    if eat_kw("private") li.linkage = .PRIVATE;
    else if eat_kw("internal") li.linkage = .INTERNAL;
    else if eat_kw("weak") li.linkage = .WEAK_ANY;
    else if eat_kw("weak_odr") li.linkage = .WEAK_ODR;
    else if eat_kw("linkonce") li.linkage = .LINKONCE_ANY;
    else if eat_kw("linkonce_odr") li.linkage = .LINKONCE_ODR;
    else if eat_kw("available_externally") li.linkage = .AVAILABLE_EXTERNALLY;
    else if eat_kw("appending") li.linkage = .APPENDING;
    else if eat_kw("common") li.linkage = .COMMON;
    else if eat_kw("extern_weak") li.linkage = .EXTERN_WEAK;
    else if eat_kw("external") li.linkage = .EXTERNAL;
    else { li.has_linkage = false; li.linkage = .EXTERNAL; }
    // dso_local / dso_preemptable
    if eat_kw("dso_local") li.dso_local = true;
    else eat_kw("dso_preemptable");
    if eat_kw("default") li.visibility = 0;
    else if eat_kw("hidden") li.visibility = 1;
    else if eat_kw("protected") li.visibility = 2;
    if eat_kw("dllimport") li.dll = 1;
    else if eat_kw("dllexport") li.dll = 2;
    return li;
}

is_local_linkage :: inline (l: Linkage) -> bool { return l == .INTERNAL || l == .PRIVATE; }

// GlobalValue::maybeSetDSOLocal / isImplicitDSOLocal
apply_dso_local :: (g: *Global_Row, dso_local: bool) {
    if dso_local || is_local_linkage(g.linkage) || g.visibility != 0 g.dso_local = true;
}

parse_optional_tls :: () -> u8 {
    if !is_kw("thread_local") return 0;
    next();
    if P.tok.kind != .LPAREN return 1;
    next();
    m: u8 = 1;
    if eat_kw("localdynamic") m = 2;
    else if eat_kw("initialexec") m = 3;
    else if eat_kw("localexec") m = 4;
    else perr("expected localdynamic, initialexec or localexec");
    expect(.RPAREN, "')'");
    return m;
}

parse_optional_unnamed_addr :: () -> u8 {
    if eat_kw("unnamed_addr") return 2;
    if eat_kw("local_unnamed_addr") return 1;
    return 0;
}

parse_optional_cc :: () -> u32 {
    if P.tok.kind != .KW return 0;
    if P.tok.text == "cc" {
        next();
        return cast(u32) parse_uint();
    }
    for CC_PARSE if it.name == P.tok.text { next(); return it.num; }
    return 0;
}

// ---------------------------------------------------------------- global values

global_slot_next :: () -> u32 { return P.next_global_id; }

parse_global_def :: () {
    name := "";
    id: u32 = NONE;
    if P.tok.kind == .GLOBAL_VAR { name = P.tok.text; }
    else { id = cast(u32) P.tok.uval; }
    next();
    expect(.EQUAL, "'='");
    li := parse_optional_linkage();
    tls := parse_optional_tls();
    ua := parse_optional_unnamed_addr();
    if is_kw("alias") || is_kw("ifunc") {
        parse_alias_or_ifunc(name, id, li, tls, ua);
        return;
    }
    parse_global(name, id, li, tls, ua);
}

// Placeholder for a forward-referenced global (LLParser's createGlobalFwdRef: an unnamed i8 GlobalVariable
// appended to the module's global list).
create_global_fwd_ref :: (as: u32) -> Value_Id {
    g := new_global(.GLOBAL_VAR, ir.t_i8, as, 1);
    glob(g).linkage = .EXTERN_WEAK;
    array_add(*ir.m_globals, g);
    return g;
}

get_global_val_by_name :: (name: string, as: u32) -> Value_Id {
    v := lookup_global(name);
    if v != NONE return v;
    found, fw := table_find(*P.fwd_globals, name);
    if found return fw;
    fw = create_global_fwd_ref(as);
    table_add(*P.fwd_globals, intern_str(name), fw);
    array_add(*P.fwd_global_order, fw);
    return fw;
}
get_global_val_by_id :: (id: u32, as: u32) -> Value_Id {
    found, v := table_find(*P.numbered_globals, id);
    if found return v;
    f2, fw := table_find(*P.fwd_global_ids, id);
    if f2 return fw;
    fw = create_global_fwd_ref(as);
    table_add(*P.fwd_global_ids, id, fw);
    return fw;
}

// Look up a forward reference for a new definition; returns NONE if none.
take_fwd_global :: (name: string, id: *u32) -> Value_Id {
    if name.count {
        found, fw := table_find(*P.fwd_globals, name);
        if found { table_remove(*P.fwd_globals, name); return fw; }
        if lookup_global(name) != NONE perr("redefinition of global '@%'", name);
        return NONE;
    }
    if id.* == NONE id.* = P.next_global_id;
    found, fw := table_find(*P.fwd_global_ids, id.*);
    if found { table_remove(*P.fwd_global_ids, id.*); return fw; }
    return NONE;
}
add_numbered_global :: (id: u32, v: Value_Id) {
    table_set(*P.numbered_globals, id, v);
    if id + 1 > P.next_global_id P.next_global_id = id + 1;
}

resolve_fwd_global :: (fw: Value_Id, real: Value_Id) {
    if fw == NONE return;
    replace_all_uses_with(fw, real);
    erase_global(fw);
}

parse_global :: (name: string, id_in: u32, li: Linkage_Info, tls: u8, ua: u8) {
    id := id_in;
    as := parse_optional_addrspace();
    ext_init := eat_kw("externally_initialized");
    is_const := false;
    if eat_kw("constant") is_const = true;
    else if eat_kw("global") is_const = false;
    else perr("expected 'global' or 'constant'");
    ty := parse_type();
    init: Value_Id = NONE;
    is_decl_linkage := li.linkage == .EXTERNAL || li.linkage == .EXTERN_WEAK;
    if !li.has_linkage || !is_decl_linkage {
        init = parse_constant(ty);
    }
    fw := take_fwd_global(name, *id);
    gv := new_global(.GLOBAL_VAR, ty, as, 1);
    if name.count set_name(gv, name);
    else add_numbered_global(id, gv);
    array_add(*ir.m_globals, gv);
    g := glob(gv);
    if init != NONE { set_op(gv, 0, init); g.has_init = true; }
    g.is_const = is_const;
    g.linkage = li.linkage;
    g.visibility = li.visibility;
    g.dll = li.dll;
    g.ext_init = ext_init;
    g.tls = tls;
    g.unnamed_addr = ua;
    apply_dso_local(g, li.dso_local);
    resolve_fwd_global(fw, gv);
    g = glob(gv);
    while eat(.COMMA) {
        if eat_kw("section") { glob(gv).section = intern_str(parse_string()); }
        else if eat_kw("partition") { glob(gv).partition = intern_str(parse_string()); }
        else if is_kw("align") { next(); glob(gv).align = parse_uint(); }
        else if eat_kw("code_model") {
            s := parse_string();
            cm: u8 = 0;
            if s == "tiny" cm = 1; else if s == "small" cm = 2; else if s == "kernel" cm = 3;
            else if s == "medium" cm = 4; else if s == "large" cm = 5; else perr("invalid code model");
            glob(gv).code_model = cm;
        }
        else if P.tok.kind == .METADATA_VAR { parse_global_object_metadata_attachment(gv); }
        else if eat_kw("no_sanitize_address") glob(gv).sanitizer |= 1;
        else if eat_kw("no_sanitize_hwaddress") glob(gv).sanitizer |= 2;
        else if eat_kw("sanitize_memtag") glob(gv).sanitizer |= 4;
        else if eat_kw("sanitize_address_dyninit") glob(gv).sanitizer |= 8;
        else {
            c := parse_optional_comdat(name);
            if c < 0 perr("unknown global variable property!");
            glob(gv).comdat = c;
        }
    }
    attrs: [..] Attr; attrs.allocator = temp;
    groups: [..] u32;
    parse_fn_attribute_value_pairs(*attrs, *groups, false);
    if attrs.count || groups.count {
        glob(gv).attrs = attr_set_get(attrs);
        array_add(*P.fwd_attr_refs, .{gv, groups, false, true});
    }
}

parse_alias_or_ifunc :: (name: string, id_in: u32, li: Linkage_Info, tls: u8, ua: u8) {
    id := id_in;
    is_alias := is_kw("alias");
    next();
    ty := parse_type();
    expect(.COMMA, "','");
    // aliasee: typed constant
    aty := parse_type();
    aliasee := parse_constant(aty);
    fw := take_fwd_global(name, *id);
    kind := ifx is_alias then Value_Kind.ALIAS else .IFUNC;
    as := ir.types[vtype(aliasee)].a;
    gv := new_global(kind, ty, cast(u32) as, 1);
    if name.count set_name(gv, name); else add_numbered_global(id, gv);
    g := glob(gv);
    g.linkage = li.linkage; g.visibility = li.visibility; g.dll = li.dll; g.tls = tls; g.unnamed_addr = ua;
    apply_dso_local(g, li.dso_local);
    set_op(gv, 0, aliasee);
    if is_alias array_add(*ir.m_aliases, gv); else array_add(*ir.m_ifuncs, gv);
    resolve_fwd_global(fw, gv);
    while eat(.COMMA) {
        if eat_kw("partition") glob(gv).partition = intern_str(parse_string());
        else if P.tok.kind == .METADATA_VAR && !is_alias parse_global_object_metadata_attachment(gv);
        else perr("unknown alias or ifunc property!");
    }
}

// ---------------------------------------------------------------- functions

Arg_Info :: struct { ty: Type_Id; attrs: u32; name: string; id: u32 = NONE; }

parse_declare :: () {
    while P.tok.kind == .METADATA_VAR {
        // function-level metadata attachments on declarations: parsed after creation in LLVM; collect
        break;
    }
    mds: [..] Kind_Md; mds.allocator = temp;
    while P.tok.kind == .METADATA_VAR {
        k := md_kind_id(P.tok.text);
        next();
        m := parse_md_node_ref();
        array_add(*mds, .{k, m});
    }
    f := parse_function_header(false);
    for mds add_metadata(f, it.kind, it.md);
}

parse_define :: () {
    f := parse_function_header(true);
    // function metadata attachments
    while P.tok.kind == .METADATA_VAR {
        k := md_kind_id(P.tok.text);
        next();
        m := parse_md_node_ref();
        add_metadata(f, k, m);
    }
    parse_function_body(f);
}

parse_function_header :: (is_define: bool) -> Value_Id {
    li := parse_optional_linkage();
    cc := parse_optional_cc();
    ret_attrs: [..] Attr; ret_attrs.allocator = temp;
    parse_optional_param_or_return_attrs(*ret_attrs, false);
    ret := parse_type(true);
    name := "";
    id: u32 = NONE;
    if P.tok.kind == .GLOBAL_VAR name = P.tok.text;
    else if P.tok.kind == .GLOBAL_ID id = cast(u32) P.tok.uval;
    else perr("expected function name");
    next();
    if P.tok.kind != .LPAREN perr("expected '(' in function argument list");
    next();
    args: [..] Arg_Info; args.allocator = temp;
    vararg := false;
    if P.tok.kind != .RPAREN {
        while true {
            if P.tok.kind == .DOTDOTDOT { next(); vararg = true; break; }
            a: Arg_Info;
            a.ty = parse_type();
            pa: [..] Attr; pa.allocator = temp;
            parse_optional_param_or_return_attrs(*pa, true);
            a.attrs = attr_set_get(pa);
            if P.tok.kind == .LOCAL_VAR { a.name = P.tok.text; next(); }
            else if P.tok.kind == .LOCAL_ID { a.id = cast(u32) P.tok.uval; next(); }
            array_add(*args, a);
            if !eat(.COMMA) break;
        }
    }
    expect(.RPAREN, "')'");
    ua := parse_optional_unnamed_addr();
    as := parse_optional_addrspace();
    fnattrs: [..] Attr; fnattrs.allocator = temp;
    groups: [..] u32;
    parse_fn_attribute_value_pairs(*fnattrs, *groups, false);
    section, partition, gc: string;
    if eat_kw("section") section = parse_string();
    if eat_kw("partition") partition = parse_string();
    comdat := parse_optional_comdat(name);
    align: u64 = 0;
    if is_kw("align") { next(); align = parse_uint(); }
    pref_align: u64 = 0;
    if eat_kw("prefalign") { expect(.LPAREN, "'('"); pref_align = parse_uint(); expect(.RPAREN, "')'"); }
    if eat_kw("gc") gc = parse_string();
    prefix, prologue, personality: Value_Id = NONE;
    if eat_kw("prefix") { t := parse_type(); prefix = parse_constant(t); }
    if eat_kw("prologue") { t := parse_type(); prologue = parse_constant(t); }
    if eat_kw("personality") { t := parse_type(); personality = parse_constant(t); }

    // alignment parsed as attribute moves to the field
    for fnattrs if it.kind == .Alignment { align = it.ival; remove it; }

    params: [..] Type_Id; params.allocator = temp;
    psets: [..] u32; psets.allocator = temp;
    for args { array_add(*params, it.ty); array_add(*psets, it.attrs); }
    pal := attr_list_get(attr_set_get(fnattrs), attr_set_get(ret_attrs), psets);
    ft := type_func(ret, params, vararg);

    fw: Value_Id = NONE;
    if name.count {
        found, f0 := table_find(*P.fwd_globals, name);
        if found { fw = f0; table_remove(*P.fwd_globals, name); }
        else if lookup_global(name) != NONE perr("invalid redefinition of function '%'", name);
    } else {
        if id == NONE id = P.next_global_id;
        found, f0 := table_find(*P.fwd_global_ids, id);
        if found { fw = f0; table_remove(*P.fwd_global_ids, id); }
    }
    f := new_function(ft, name, as);
    array_add(*ir.m_functions, f);
    if name.count == 0 add_numbered_global(id, f);
    g := glob(f);
    g.linkage = li.linkage;
    g.visibility = li.visibility;
    g.dll = li.dll;
    g.cc = cc;
    g.attrs = pal;
    g.unnamed_addr = ua;
    g.align = align;
    g.pref_align = pref_align;
    g.section = intern_str(section);
    g.partition = intern_str(partition);
    g.comdat = comdat;
    g.gc = intern_str(gc);
    apply_dso_local(g, li.dso_local);
    if personality != NONE { set_op(f, 0, personality); g.has_personality = true; }
    if prefix != NONE { set_op(f, 1, prefix); glob(f).has_prefix = true; }
    if prologue != NONE { set_op(f, 2, prologue); glob(f).has_prologue = true; }
    array_add(*P.fwd_attr_refs, .{f, groups, false, false});
    for args {
        if it.name.count {
            a := fn_arg(f, cast(u32) it_index);
            set_name(a, it.name);
            if vname(a) != it.name perr("redefinition of argument '%%'", "%", it.name);
        }
    }
    if fw != NONE resolve_fwd_global(fw, f);
    // remember unnamed arg numbers for the body
    P.pending_arg_ids.count = 0;
    for args array_add(*P.pending_arg_ids, it.id);
    return f;
}


parse_function_body :: (f: Value_Id) {
    if P.tok.kind != .LBRACE perr("expected '{' in function body");
    next();
    P.fnv = f;
    table_reset(*P.local_numbered);
    table_reset(*P.fwd_locals);
    table_reset(*P.fwd_local_ids);
    P.local_next = 0;
    // number unnamed arguments
    g := glob(f);
    if g.nargs > 0 for i: 0..g.nargs-1 {
        a := fn_arg(f, i);
        if vname(a).count == 0 {
            aid := ifx i < P.pending_arg_ids.count then P.pending_arg_ids[i] else NONE;
            if aid == NONE aid = P.local_next;
            if aid < P.local_next perr("argument expected to be numbered '%%'", "%", P.local_next);
            table_set(*P.local_numbered, aid, a);
            P.local_next = aid + 1;
        }
    }
    resolve_fwd_blockaddresses(f);
    if P.tok.kind == .RBRACE perr("function body requires at least one basic block");
    while P.tok.kind != .RBRACE {
        if is_kw("uselistorder") perr("uselistorder directives are not supported");
        parse_basic_block();
    }
    next();
    // finishFunction: check forward refs
    for P.fwd_locals perr("use of undefined value '%%'", "%", it_index);
    for P.fwd_local_ids perr("use of undefined value '%%'", "%", it_index);
    P.fnv = NONE;
}

// ---------------------------------------------------------------- per-function values

local_symtab :: () -> *Table(string, Value_Id) { return *ir.symtabs[glob(P.fnv).symtab]; }

get_local_by_name :: (name: string, ty: Type_Id) -> Value_Id {
    found, v := table_find(local_symtab(), name);
    if !found { f2, fv := table_find(*P.fwd_locals, name); if f2 { v = fv; found = true; } }
    if found {
        if ty == ir.t_label && vkind(v) != .BLOCK perr("'%%' is not a basic block", "%", name);
        if ty != ir.t_label && vtype(v) != ty perr("'%%' defined with type '%' but expected '%'", "%", name, type_to_string(vtype(v)), type_to_string(ty));
        return v;
    }
    if ty == ir.t_label {
        b := new_block(P.fnv);
        fn_append_block(P.fnv, b);
        set_name(b, name);
        table_add(*P.fwd_locals, vname(b), b);
        return b;
    }
    ph := new_value(.PLACEHOLDER, ty, 0);
    table_add(*P.fwd_locals, intern_str(name), ph);
    return ph;
}

get_local_by_id :: (id: u32, ty: Type_Id) -> Value_Id {
    found, v := table_find(*P.local_numbered, id);
    if !found { f2, fv := table_find(*P.fwd_local_ids, id); if f2 { v = fv; found = true; } }
    if found {
        if ty == ir.t_label && vkind(v) != .BLOCK perr("'%%' is not a basic block", "%", id);
        if ty != ir.t_label && vtype(v) != ty perr("'%%' defined with type '%' but expected '%'", "%", id, type_to_string(vtype(v)), type_to_string(ty));
        return v;
    }
    if ty == ir.t_label {
        b := new_block(P.fnv);
        fn_append_block(P.fnv, b);
        table_add(*P.fwd_local_ids, id, b);
        return b;
    }
    ph := new_value(.PLACEHOLDER, ty, 0);
    table_add(*P.fwd_local_ids, id, ph);
    return ph;
}

define_bb :: (name: string, id_in: u32) -> Value_Id {
    b: Value_Id;
    if name.count {
        b = get_local_by_name(name, ir.t_label);
        table_remove(*P.fwd_locals, name);
    } else {
        id := id_in;
        if id == NONE id = P.local_next;
        if id < P.local_next perr("label expected to be numbered '%'", P.local_next);
        b = get_local_by_id(id, ir.t_label);
        table_remove(*P.fwd_local_ids, id);
        table_set(*P.local_numbered, id, b);
        P.local_next = id + 1;
    }
    // move the block to the end of the function
    fn_unlink_block(P.fnv, b);
    fn_append_block(P.fnv, b);
    return b;
}

set_inst_name :: (i: Value_Id, name: string, id_in: u32, has_name: bool) {
    if vtype(i) == ir.t_void {
        if has_name perr("instructions returning void cannot have a name");
        return;
    }
    if name.count == 0 {
        id := id_in;
        if id == NONE id = P.local_next;
        if id < P.local_next perr("instruction expected to be numbered '%%'", "%", P.local_next);
        found, ph := table_find(*P.fwd_local_ids, id);
        if found {
            if vtype(ph) != vtype(i) perr("instruction forward referenced with type '%'", type_to_string(vtype(ph)));
            replace_all_uses_with(ph, i);
            ir.v_kind[ph] = .DEAD;
            table_remove(*P.fwd_local_ids, id);
        }
        table_set(*P.local_numbered, id, i);
        P.local_next = id + 1;
        return;
    }
    found, ph := table_find(*P.fwd_locals, name);
    if found {
        if vtype(ph) != vtype(i) perr("instruction forward referenced with type '%'", type_to_string(vtype(ph)));
        replace_all_uses_with(ph, i);
        ir.v_kind[ph] = .DEAD;
        table_remove(*P.fwd_locals, name);
    }
    set_name(i, name);
    if vname(i) != name perr("multiple definition of local value named '%'", name);
}

parse_basic_block :: () {
    name := "";
    id: u32 = NONE;
    if P.tok.kind == .LABEL_STR { name = P.tok.text; next(); }
    else if P.tok.kind == .LABEL_ID { id = cast(u32) P.tok.uval; next(); }
    b := define_bb(name, id);
    while true {
        iname := "";
        iid: u32 = NONE;
        has_name := false;
        if P.tok.kind == .LOCAL_ID {
            iid = cast(u32) P.tok.uval; next(); has_name = true;
            expect(.EQUAL, "'=' after instruction id");
        } else if P.tok.kind == .LOCAL_VAR {
            iname = P.tok.text; next(); has_name = true;
            expect(.EQUAL, "'=' after instruction name");
        }
        if P.tok.kind == .HASH perr("debug records are not supported");
        i, extra_md := parse_instruction();
        block_append_inst(b, i);
        // instruction metadata
        if extra_md || P.tok.kind == .COMMA {
            parse_instruction_metadata(i);
        }
        set_inst_name(i, iname, iid, has_name);
        if is_terminator(inst_op(i)) break;
    }
}

parse_instruction_metadata :: (i: Value_Id) {
    while eat(.COMMA) {
        if P.tok.kind != .METADATA_VAR perr("expected metadata after comma");
        k := md_kind_id(P.tok.text);
        next();
        m := parse_md_node_ref();
        set_metadata(i, k, m);
        if k == 1 array_add(*P.insts_with_tbaa, i);
    }
}

parse_global_object_metadata_attachment :: (v: Value_Id) {
    k := md_kind_id(P.tok.text);
    next();
    m := parse_md_node_ref();
    add_metadata(v, k, m);
}

// ---------------------------------------------------------------- values

// Parse a value of the given type (local or constant).
parse_value :: (ty: Type_Id) -> Value_Id {
    t := P.tok;
    if P.fnv != NONE {
        if t.kind == .LOCAL_VAR { next(); return get_local_by_name(t.text, ty); }
        if t.kind == .LOCAL_ID { next(); return get_local_by_id(cast(u32) t.uval, ty); }
    }
    if ty == ir.t_metadata return parse_metadata_as_value();
    if is_kw("asm") return parse_inline_asm(ty);
    return parse_constant(ty);
}

parse_type_and_value :: () -> Value_Id {
    ty := parse_type();
    return parse_value(ty);
}

parse_metadata_as_value :: () -> Value_Id {
    m := parse_metadata_operand();
    k := const_key_begin(.MD_VALUE, ir.t_metadata); key_u32(k, m);
    v := const_lookup_or_create(k, .MD_VALUE, ir.t_metadata, .[], m);
    return v;
}

Inline_Asm_Row :: struct { asm_str: string; constraints: string; flags: u32; fty: Type_Id; }
inline_asms: [..] Inline_Asm_Row;

parse_inline_asm :: (ty: Type_Id) -> Value_Id {
    next();
    flags: u32 = 0;
    if eat_kw("sideeffect") flags |= 1;
    if eat_kw("alignstack") flags |= 2;
    if eat_kw("inteldialect") flags |= 4;
    if eat_kw("unwind") flags |= 8;
    s := parse_string();
    expect(.COMMA, "','");
    c := parse_string();
    // the function type is set by the call (P.callee_fty)
    k := const_key_begin(.INLINE_ASM, ty);
    key_str(k, s); key_str(k, c); key_u32(k, flags); key_u32(k, P.callee_fty);
    found, v := table_find(*ir.const_map, key_view(k));
    if found return v;
    aux := cast(u32) inline_asms.count;
    array_add(*inline_asms, .{intern_str(s), intern_str(c), flags, P.callee_fty});
    v = const_lookup_or_create(k, .INLINE_ASM, ty, .[], aux);
    return v;
}

parse_global_type_and_value :: () -> Value_Id {
    ty := parse_type();
    return parse_constant(ty);
}

// Constant elements list for aggregates: "ty val, ty val, ..."
parse_global_value_vector :: (out: *[..] Value_Id) {
    if P.tok.kind == .RBRACE || P.tok.kind == .RSQUARE || P.tok.kind == .GREATER || P.tok.kind == .RPAREN return;
    while true {
        array_add(out, parse_global_type_and_value());
        if !eat(.COMMA) break;
    }
}

hex_to_words :: (hex: string, nwords: u32) -> [] u64 {
    w := NewArray(nwords, u64,, allocator = temp);
    bit := 0;
    i := hex.count - 1;
    while i >= 0 {
        d := cast(u64) hex_val(hex[i]);
        wi := bit / 64;
        if wi < nwords w[wi] |= d << cast(u64)(bit % 64);
        bit += 4;
        i -= 1;
    }
    return w;
}

parse_int_literal :: (ty: Type_Id) -> Value_Id {
    t := P.tok;
    next();
    bits := type_bits(ty);
    if t.hex_kind == 0 {
        return const_int_words(ty, apint_from_decimal(t.text, bits));
    }
    // [us]0x...: APSInt of width = 4*digits, truncated to active bits; signed for 's'
    nbits := cast(u32) t.text.count * 4;
    raw := hex_to_words(t.text, max(words_for_bits(nbits), words_for_bits(bits)) + 1);
    // active bits
    active: u32 = 0;
    for wi: 0..raw.count-1 if raw[wi] != 0 {
        x := raw[wi]; n: u32 = 0; while x != 0 { n += 1; x >>= 1; }
        active = cast(u32) wi * 64 + n;
    }
    width := ifx active > 0 && active < nbits then active else nbits;
    signed := t.hex_kind == #char "s";
    if signed && width > 0 && width < bits {
        // sign-extend from width
        top := ((raw[(width - 1) / 64] >> ((width - 1) % 64)) & 1) != 0;
        if top {
            for b: width..cast(u32)(raw.count * 64)-1 raw[b / 64] |= (cast(u64)1) << (b % 64);
        }
    }
    w := NewArray(words_for_bits(bits), u64,, allocator = temp);
    for i: 0..w.count-1 w[i] = raw[i];
    mask_words(w, bits);
    return const_int_words(ty, w);
}

// Convert a parsed float token into a ConstantFP of `ty`.
parse_fp_literal :: (ty: Type_Id) -> Value_Id {
    t := P.tok;
    k := type_kind(ty);
    if !is_fp_kind(k) perr("floating point constant invalid for type");
    next();
    if t.kind == .FLOAT_LIT {
        w, ok, overflow, zero := fp_from_string(k, t.text);
        if !ok perr("invalid floating-point literal");
        if overflow perr("floating-point constant overflowed type");
        return const_fp_words(ty, w);
    }
    if t.kind == .APFLOAT_HEX {
        dw := hex_to_words(t.text, 1);
        if k == .DOUBLE return const_fp_words(ty, dw);
        if k != .HALF && k != .BFLOAT && k != .FLOAT perr("floating point constant invalid for type");
        d := fp_decode(.DOUBLE, dw);
        snan := d.cat == .NAN && !big_bit(d.sig, 51);
        w, exact := fp_convert(.DOUBLE, k, dw);
        if !exact && d.cat != .NAN perr("floating point constant invalid for type");
        if snan {
            // APFloat::getSNaN with the converted payload: clear quiet bit, keep payload (nonzero)
            p, mx, mn, bits := fp_semantics(k);
            w2 := NewArray(1, u64,, allocator = temp);
            w2[0] = w[0] & ~((cast(u64)1) << cast(u64)(p - 2));
            frac := w2[0] & (((cast(u64)1) << cast(u64)(p - 1)) - 1);
            if frac == 0 w2[0] |= 1;
            return const_fp_words(ty, w2);
        }
        return const_fp_words(ty, w);
    }
    // FLOAT_HEX: K/L/M/H/R or f0x
    p, mx, mn, bits := fp_semantics(k);
    hk := t.hex_kind;
    if hk == #char "f" {
        if cast(u32) t.text.count * 4 != cast(u32) bits perr("float hex literal has incorrect number of bits");
        return const_fp_words(ty, hex_to_words(t.text, words_for_bits(cast(u32) bits)));
    }
    if hk == #char "H" && k != .HALF perr("floating point constant invalid for type");
    if hk == #char "R" && k != .BFLOAT perr("floating point constant invalid for type");
    if hk == #char "K" && k != .X86_FP80 perr("floating point constant invalid for type");
    if hk == #char "L" && k != .FP128 perr("floating point constant invalid for type");
    if hk == #char "M" && k != .PPC_FP128 perr("floating point constant invalid for type");
    if hk == #char "K" {
        // FP80HexToIntPair: first 4 hex digits are the high 16 bits (sign/exponent), rest the 64-bit mantissa
        w := NewArray(2, u64,, allocator = temp);
        s := t.text;
        hi_n := s.count - 16;
        if hi_n < 0 hi_n = 0;
        hi := hex_to_words(slice(s, 0, hi_n), 1);
        lo := hex_to_words(slice(s, hi_n, s.count - hi_n), 1);
        w[0] = lo[0]; w[1] = hi[0] & 0xFFFF;
        return const_fp_words(ty, w);
    }
    if hk == #char "L" || hk == #char "M" {
        // HexToIntPair: first 16 hex digits -> Pair[0] (high in the text = low word!), rest -> Pair[1]
        s := t.text;
        n0 := min(16, s.count);
        a := hex_to_words(slice(s, 0, n0), 1);
        b := hex_to_words(slice(s, n0, s.count - n0), 1);
        w := NewArray(2, u64,, allocator = temp);
        w[0] = a[0]; w[1] = b[0];
        return const_fp_words(ty, w);
    }
    return const_fp_words(ty, hex_to_words(t.text, 1));
}

// LLParser::parseValID + convertValIDToValue for constants, with the type known.
parse_constant :: (ty: Type_Id) -> Value_Id {
    t := P.tok;
    if t.kind == {
        case .GLOBAL_VAR;
            next();
            if !is_ptr_type(ty) perr("global variable reference must have pointer type");
            return get_global_val_by_name(t.text, cast(u32) ir.types[ty].a);
        case .GLOBAL_ID;
            next();
            if !is_ptr_type(ty) perr("global variable reference must have pointer type");
            return get_global_val_by_id(cast(u32) t.uval, cast(u32) ir.types[ty].a);
        case .APSINT;
            k := type_kind(ty);
            if k != .INT && k != .BYTE perr("integer/byte constant must have integer/byte type");
            return parse_int_literal(ty);
        case .FLOAT_LIT; #through;
        case .APFLOAT_HEX; #through;
        case .FLOAT_HEX;
            return parse_fp_literal(ty);
        case .LBRACE;
            next();
            elts: [..] Value_Id; elts.allocator = temp;
            parse_global_value_vector(*elts);
            expect(.RBRACE, "'}'");
            return make_struct_constant(ty, elts, false);
        case .LESS;
            next();
            if P.tok.kind == .LBRACE {
                next();
                elts: [..] Value_Id; elts.allocator = temp;
                parse_global_value_vector(*elts);
                expect(.RBRACE, "'}'");
                expect(.GREATER, "'>'");
                return make_struct_constant(ty, elts, true);
            }
            elts: [..] Value_Id; elts.allocator = temp;
            parse_global_value_vector(*elts);
            expect(.GREATER, "'>'");
            if elts.count == 0 perr("constant vector must not be empty");
            vt := type_vector(cast(u64) elts.count, vtype(elts[0]), false);
            if vt != ty perr("constant expression type mismatch");
            return const_aggregate(.C_VECTOR, vt, elts);
        case .LSQUARE;
            next();
            elts: [..] Value_Id; elts.allocator = temp;
            parse_global_value_vector(*elts);
            expect(.RSQUARE, "']'");
            if elts.count == 0 {
                if type_kind(ty) != .ARRAY || type_count(ty) != 0 perr("invalid empty array initializer");
                return const_zero(ty);
            }
            at := type_array(cast(u64) elts.count, vtype(elts[0]));
            if at != ty perr("constant expression type mismatch: got type '%' but expected '%'", type_to_string(at), type_to_string(ty));
            return const_aggregate(.C_ARRAY, at, elts);
        case .KW;
            return parse_constant_keyword(ty);
    }
    perr("expected value token");
    return NONE;
}

make_struct_constant :: (ty: Type_Id, elts: [] Value_Id, packed: bool) -> Value_Id {
    if type_kind(ty) != .STRUCT perr("constant expression type mismatch");
    r := ir.types[ty];
    if ((r.flags & TYF_PACKED) != 0) != packed perr("constant struct packedness mismatch");
    if r.nsub != elts.count perr("constant struct element count mismatch");
    for elts if vtype(it) != type_sub(ty, cast(u32) it_index) perr("element % of struct initializer doesn't match struct element type", it_index);
    return const_aggregate(.C_STRUCT, ty, elts);
}

cast_opcode :: (s: string) -> Opcode {
    if s == "trunc" return .TRUNC; if s == "zext" return .ZEXT; if s == "sext" return .SEXT;
    if s == "fptrunc" return .FPTRUNC; if s == "fpext" return .FPEXT; if s == "fptoui" return .FPTOUI;
    if s == "fptosi" return .FPTOSI; if s == "uitofp" return .UITOFP; if s == "sitofp" return .SITOFP;
    if s == "ptrtoint" return .PTRTOINT; if s == "ptrtoaddr" return .PTRTOADDR; if s == "inttoptr" return .INTTOPTR;
    if s == "bitcast" return .BITCAST; if s == "addrspacecast" return .ADDRSPACECAST;
    return .NONE_OP;
}

parse_constant_keyword :: (ty: Type_Id) -> Value_Id {
    s := P.tok.text;
    if s == "true" || s == "false" {
        next();
        if scalar_type(ty) != ir.t_i1 perr("expected i1 type for boolean constant");
        return const_int(ty, ifx s == "true" then cast(u64) 1 else 0);
    }
    if s == "null" {
        next();
        if !is_ptr_type(ty) perr("null must be a pointer type");
        return const_null(ty);
    }
    if s == "undef" { next(); return const_undef(ty); }
    if s == "poison" { next(); return const_poison(ty); }
    if s == "zeroinitializer" {
        next();
        // Constant::getNullValue
        return const_null_value(ty);
    }
    if s == "none" { next(); if ty != ir.t_token perr("invalid type for none constant"); return const_simple(.C_TOKEN_NONE, ty); }
    if s == "c" {
        next();
        if P.tok.kind != .STRING perr("expected string");
        str := P.tok.text;
        next();
        if type_kind(ty) != .ARRAY perr("constant expression type mismatch");
        if type_count(ty) != cast(u64) str.count perr("constant expression type mismatch: string length");
        elts := NewArray(str.count, u64,, allocator = temp);
        for i: 0..str.count-1 elts[i] = str[i];
        return make_const_data(ty, elts);
    }
    if s == "splat" {
        next();
        expect(.LPAREN, "'('");
        c := parse_global_type_and_value();
        expect(.RPAREN, "')'");
        if !is_vector_type(ty) perr("vector constant must have vector type");
        if type_elem(ty) != vtype(c) perr("constant expression type mismatch");
        return const_splat(ty, c);
    }
    if s == "blockaddress" {
        next();
        expect(.LPAREN, "'('");
        fn_tok := P.tok; next();
        expect(.COMMA, "','");
        bb_tok := P.tok; next();
        expect(.RPAREN, "')'");
        return parse_blockaddress(ty, fn_tok, bb_tok);
    }
    if s == "dso_local_equivalent" || s == "no_cfi" {
        next();
        gt := P.tok;
        gv := parse_constant(ir.t_ptr);
        kind := ifx s == "no_cfi" then Value_Kind.C_NO_CFI else .C_DSO_EQUIV;
        k := const_key_begin(kind, vtype(gv)); key_u32(k, gv);
        v := const_lookup_or_create(k, kind, vtype(gv), .[gv], 0);
        return v;
    }
    if s == "asm" perr("inline asm only allowed as a call operand");
    op := cast_opcode(s);
    if op != .NONE_OP {
        next();
        expect(.LPAREN, "'('");
        src := parse_global_type_and_value();
        expect_kw("to");
        dt := parse_type();
        expect(.RPAREN, "')'");
        return const_cast(op, src, dt);
    }
    if s == "add" || s == "sub" || s == "xor" {
        bop := ifx s == "add" then Opcode.ADD else ifx s == "sub" then Opcode.SUB else .XOR;
        next();
        flags: u32 = 0;
        if bop != .XOR {
            if eat_kw("nuw") flags |= F_NUW;
            if eat_kw("nsw") { flags |= F_NSW; if eat_kw("nuw") flags |= F_NUW; }
        }
        expect(.LPAREN, "'('");
        a := parse_global_type_and_value();
        expect(.COMMA, "','");
        b := parse_global_type_and_value();
        expect(.RPAREN, "')'");
        if vtype(a) != vtype(b) perr("operands of constexpr must have same type");
        return const_binop(bop, a, b, flags);
    }
    if s == "getelementptr" {
        next();
        flags: u32 = 0;
        while true {
            if eat_kw("inbounds") flags |= F_INBOUNDS;
            else if eat_kw("nusw") flags |= F_NUSW;
            else if eat_kw("nuw") flags |= F_GEP_NUW;
            else break;
        }
        extra: [..] u32; extra.allocator = temp;
        if eat_kw("inrange") {
            expect(.LPAREN, "'('");
            lo := P.tok.text; next();
            expect(.COMMA, "','");
            hi := P.tok.text; next();
            expect(.RPAREN, "')'");
            flags |= F_INRANGE;
            lv := apint_from_decimal(lo, 64); hv := apint_from_decimal(hi, 64);
            array_add(*extra, cast,trunc(u32) lv[0]); array_add(*extra, cast,trunc(u32)(lv[0] >> 32));
            array_add(*extra, cast,trunc(u32) hv[0]); array_add(*extra, cast,trunc(u32)(hv[0] >> 32));
        }
        expect(.LPAREN, "'('");
        srcty := parse_type();
        expect(.COMMA, "','");
        elts: [..] Value_Id; elts.allocator = temp;
        parse_global_value_vector(*elts);
        expect(.RPAREN, "')'");
        if elts.count == 0 perr("base of getelementptr must be a pointer");
        return const_gep(srcty, elts, flags, extra);
    }
    if s == "extractelement" || s == "insertelement" || s == "shufflevector" {
        perr("% constant expressions are not supported yet", s);
    }
    if s == "ptrauth" perr("ptrauth constants are not supported yet");
    perr("expected value token (got '%')", s);
    return NONE;
}

make_const_data :: (ty: Type_Id, elts: [] u64) -> Value_Id {
    all_zero := true;
    for elts if it != 0 all_zero = false;
    if all_zero return const_zero(ty);
    return const_data(ty, elts);
}

// ConstantVector::getSplat
const_splat :: (ty: Type_Id, c: Value_Id) -> Value_Id {
    if type_kind(ty) == .SVECTOR {
        if is_null_value(c) return const_zero(ty);
        k := vkind(c);
        if k == .C_INT return const_int_words(ty, const_int_value(c));
        if k == .C_FP return const_fp_words(ty, const_fp_value(c));
        perr("unsupported scalable splat");
    }
    n := type_count(ty);
    elts := NewArray(cast(s64) n, Value_Id,, allocator = temp);
    if n > 0 for i: 0..n-1 elts[i] = c;
    return const_aggregate(.C_VECTOR, ty, elts);
}

const_cast :: (op: Opcode, src: Value_Id, dt: Type_Id) -> Value_Id {
    // minimal constant folding (ConstantFoldCastInstruction): casts of poison/undef, null ptrtoint
    k := vkind(src);
    if k == .C_POISON return const_poison(dt);
    if op == .BITCAST && vtype(src) == dt return src;
    if k == .C_UNDEF && (op != .ZEXT && op != .SEXT) return const_undef(dt);
    if k == .C_NULL && (op == .PTRTOINT || op == .PTRTOADDR) && is_int_type(dt) return const_int(dt, 0);
    if k == .C_INT && op == .INTTOPTR && const_int_zext(src) == 0 && words_all_zero(const_int_value(src)) return const_null(dt);
    return const_expr(op, dt, 0, NONE, .[src]);
}
words_all_zero :: (w: [] u64) -> bool { for w if it != 0 return false; return true; }

const_binop :: (op: Opcode, a: Value_Id, b: Value_Id, flags: u32) -> Value_Id {
    return const_expr(op, vtype(a), flags, NONE, .[a, b]);
}

const_gep :: (srcty: Type_Id, elts: [] Value_Id, flags: u32, extra: [] u32) -> Value_Id {
    base := elts[0];
    bt := vtype(base);
    // result type: ptr (or vector of ptr if any operand is a vector)
    rt := bt;
    for elts if is_vector_type(vtype(it)) && !is_vector_type(rt) rt = type_vector(type_count(vtype(it)), bt, type_kind(vtype(it)) == .SVECTOR);
    // ConstantFoldGetElementPtr: no-op GEPs (all indices zero/undef, no inrange) fold to the base
    if elts.count == 1 return base;
    if vkind(base) == .C_POISON return const_poison(rt);
    if (flags & F_INRANGE) == 0 {
        noop := true;
        for i: 1..elts.count-1 {
            ix := elts[i];
            if !(is_null_value(ix) || vkind(ix) == .C_UNDEF || vkind(ix) == .C_POISON) noop = false;
        }
        if noop && rt == bt return base;
    }
    return const_expr(.GEP, rt, flags, srcty, elts, extra);
}

parse_blockaddress :: (ty: Type_Id, fn_tok: Token, bb_tok: Token) -> Value_Id {
    fnv: Value_Id = NONE;
    if fn_tok.kind == .GLOBAL_ID {
        found, v := table_find(*P.numbered_globals, cast(u32) fn_tok.uval);
        if found fnv = v;
    } else if fn_tok.kind == .GLOBAL_VAR {
        if !table_contains(*P.fwd_globals, fn_tok.text) fnv = lookup_global(fn_tok.text);
    } else perr("expected function name in blockaddress");
    if bb_tok.kind != .LOCAL_VAR && bb_tok.kind != .LOCAL_ID perr("expected basic block name in blockaddress");
    if fnv != NONE {
        if vkind(fnv) != .FUNCTION perr("expected function name in blockaddress");
        if fnv == P.fnv {
            bb := ifx bb_tok.kind == .LOCAL_VAR then get_local_by_name(bb_tok.text, ir.t_label) else get_local_by_id(cast(u32) bb_tok.uval, ir.t_label);
            return const_blockaddr(fnv, bb);
        }
        if is_declaration(fnv) perr("cannot take blockaddress inside a declaration");
        if bb_tok.kind == .LOCAL_ID perr("cannot take address of numeric label after the function is defined");
        found, bb := table_find(*ir.symtabs[glob(fnv).symtab], bb_tok.text);
        if !found || vkind(bb) != .BLOCK perr("referenced value is not a basic block");
        return const_blockaddr(fnv, bb);
    }
    // forward reference: placeholder internal global, resolved when the function body is parsed
    for P.blockaddr_fwd {
        same_fn := ifx fn_tok.kind == .GLOBAL_ID then (it.by_id && it.fn_id == cast(u32) fn_tok.uval) else (!it.by_id && it.fn_name == fn_tok.text);
        same_bb := ifx bb_tok.kind == .LOCAL_ID then (it.bb_by_id && it.bb_id == cast(u32) bb_tok.uval) else (!it.bb_by_id && it.bb_name == bb_tok.text);
        if same_fn && same_bb return it.placeholder;
    }
    as := cast(u32) ir.types[ty].a;
    ph := new_global(.GLOBAL_VAR, ir.t_i8, as, 1);
    glob(ph).linkage = .INTERNAL;
    array_add(*ir.m_globals, ph);
    f: Blockaddr_Fwd;
    f.placeholder = ph;
    f.by_id = fn_tok.kind == .GLOBAL_ID; f.fn_id = cast(u32) fn_tok.uval; f.fn_name = intern_str(fn_tok.text);
    f.bb_by_id = bb_tok.kind == .LOCAL_ID; f.bb_id = cast(u32) bb_tok.uval; f.bb_name = intern_str(bb_tok.text);
    array_add(*P.blockaddr_fwd, f);
    return ph;
}

resolve_fwd_blockaddresses :: (f: Value_Id) {
    i := 0;
    while i < P.blockaddr_fwd.count {
        it := P.blockaddr_fwd[i];
        match := false;
        if it.by_id { found, v := table_find(*P.numbered_globals, it.fn_id); match = found && v == f; }
        else match = vname(f) == it.fn_name;
        if !match { i += 1; continue; }
        bb := ifx it.bb_by_id then get_local_by_id(it.bb_id, ir.t_label) else get_local_by_name(it.bb_name, ir.t_label);
        ba := const_blockaddr(f, bb);
        replace_all_uses_with(it.placeholder, ba);
        erase_global(it.placeholder);
        array_ordered_remove_by_index(*P.blockaddr_fwd, i);
    }
}

// ---------------------------------------------------------------- attributes

attr_kind_from_name :: (s: string) -> Attr_Kind {
    for ATTR_NAMES if it.name == s return it.kind;
    return .NONE_ATTR;
}

is_type_attr :: inline (k: Attr_Kind) -> bool { return k > .LAST_ENUM && k < .LAST_TYPE; }

// LLParser::parseEnumAttribute
parse_enum_attribute :: (kind: Attr_Kind, out: *[..] Attr, in_group: bool) {
    a: Attr;
    a.kind = kind;
    a.ty = NONE;
    if is_type_attr(kind) {
        next();
        if P.tok.kind == .LPAREN {
            next();
            a.ty = parse_type();
            expect(.RPAREN, "')'");
        } else if kind != .ElementType && kind != .ByVal && kind != .StructRet && kind != .InAlloca && kind != .ByRef && kind != .Preallocated {
        } else {
            perr("expected '('");
        }
        array_add(out, a);
        return;
    }
    if kind == {
        case .Alignment;
            next();
            if in_group { expect(.EQUAL, "'='"); a.ival = parse_uint(); }
            else {
                if P.tok.kind == .LPAREN { next(); a.ival = parse_uint(); expect(.RPAREN, "')'"); }
                else a.ival = parse_uint();
            }
        case .StackAlignment;
            next();
            if in_group { expect(.EQUAL, "'='"); a.ival = parse_uint(); }
            else { expect(.LPAREN, "'('"); a.ival = parse_uint(); expect(.RPAREN, "')'"); }
        case .AllocSize;
            next();
            expect(.LPAREN, "'('");
            e := parse_uint();
            n: u64 = 0xFFFF_FFFF;
            if eat(.COMMA) n = parse_uint();
            expect(.RPAREN, "')'");
            a.ival = (e << 32) | n;
        case .VScaleRange;
            next();
            expect(.LPAREN, "'('");
            mn := parse_uint();
            mx := mn;
            if eat(.COMMA) mx = parse_uint();
            expect(.RPAREN, "')'");
            a.ival = (mn << 32) | mx;
        case .Dereferenceable; #through;
        case .DereferenceableOrNull;
            next();
            if in_group && P.tok.kind == .EQUAL { next(); a.ival = parse_uint(); }
            else { expect(.LPAREN, "'('"); a.ival = parse_uint(); expect(.RPAREN, "')'"); }
        case .DeadOnReturn;
            next();
            a.ival = 0xFFFF_FFFF_FFFF_FFFF;
            if in_group && P.tok.kind == .EQUAL { next(); a.ival = parse_uint(); }
            else if P.tok.kind == .LPAREN { next(); a.ival = parse_uint(); expect(.RPAREN, "')'"); }
        case .UWTable;
            next();
            a.ival = 2; // Default (async)
            if P.tok.kind == .LPAREN {
                next();
                if eat_kw("sync") a.ival = 1;
                else if eat_kw("async") a.ival = 2;
                else perr("expected unwind table kind");
                expect(.RPAREN, "')'");
            }
        case .AllocKind;
            next();
            expect(.LPAREN, "'('");
            s := parse_string();
            expect(.RPAREN, "')'");
            parts := split(s, ",",, allocator = temp);
            for parts {
                if it == "alloc" a.ival |= 1;
                else if it == "realloc" a.ival |= 2;
                else if it == "free" a.ival |= 4;
                else if it == "uninitialized" a.ival |= 8;
                else if it == "zeroed" a.ival |= 16;
                else if it == "aligned" a.ival |= 32;
                else perr("unknown allockind %", it);
            }
        case .Memory;
            a.ival = parse_memory_attr();
        case .NoFPClass;
            a.ival = parse_nofpclass_attr();
        case .Captures;
            a.ival = parse_captures_attr();
        case .Range;
            next();
            expect(.LPAREN, "'('");
            if P.tok.kind != .INT_TYPE perr("expected integer type");
            bits := cast(u32) P.tok.uval;
            next();
            lo_t := P.tok; next();
            expect(.COMMA, "','");
            hi_t := P.tok; next();
            expect(.RPAREN, "')'");
            a.ival = bits;
            a.lo = apint_from_decimal(lo_t.text, bits);
            a.hi = apint_from_decimal(hi_t.text, bits);
        case .Initializes;
            next();
            expect(.LPAREN, "'('");
            lo: [..] u64; lo.allocator = temp;
            hi: [..] u64; hi.allocator = temp;
            while true {
                expect(.LPAREN, "'('");
                l := P.tok.text; next();
                expect(.COMMA, "','");
                h := P.tok.text; next();
                expect(.RPAREN, "')'");
                array_add(*lo, apint_from_decimal(l, 64)[0]);
                array_add(*hi, apint_from_decimal(h, 64)[0]);
                if !eat(.COMMA) break;
            }
            expect(.RPAREN, "')'");
            a.lo = lo; a.hi = hi;
        case .DenormalFPEnv;
            a.ival = parse_denormal_fpenv();
        case;
            next();
    }
    array_add(out, a);
}

// MemoryEffects encoding: 2 bits per location (ArgMem=0, InaccessibleMem=1, ErrnoMem=2, Other=3,
// TargetMem0=4, TargetMem1=5); ModRef: 0 none, 1 ref, 2 mod, 3 modref.
MEM_LOCS :: 6;
mem_all :: (mr: u64) -> u64 { r: u64 = 0; for i: 0..MEM_LOCS-1 r |= mr << cast(u64)(2 * i); return r; }
mem_get :: (me: u64, loc: s64) -> u64 { return (me >> cast(u64)(2 * loc)) & 3; }
mem_set :: (me: u64, loc: s64, mr: u64) -> u64 { sh := cast(u64)(2 * loc); return (me & ~((cast(u64)3) << sh)) | (mr << sh); }

parse_memory_attr :: () -> u64 {
    P.lx.ignore_colon = true;
    defer P.lx.ignore_colon = false;
    next();
    expect(.LPAREN, "'('");
    me: u64 = 0;
    seen_loc := false;
    while true {
        loc := -1;
        if is_kw("argmem") loc = 0;
        else if is_kw("inaccessiblemem") loc = 1;
        else if is_kw("errnomem") loc = 2;
        else if is_kw("target_mem0") loc = 4;
        else if is_kw("target_mem1") loc = 5;
        else if is_kw("target_mem") loc = 100;
        if loc >= 0 {
            next();
            expect(.COLON, "':'");
        } else if seen_loc perr("default access kind must be specified first");
        mr: u64 = 0;
        if eat_kw("none") mr = 0;
        else if eat_kw("read") mr = 1;
        else if eat_kw("write") mr = 2;
        else if eat_kw("readwrite") mr = 3;
        else perr("expected memory location (argmem, inaccessiblemem, errnomem) or access kind (none, read, write, readwrite)");
        if loc < 0 me = mem_all(mr);
        else if loc == 100 { me = mem_set(me, 4, mr); me = mem_set(me, 5, mr); seen_loc = true; }
        else { me = mem_set(me, loc, mr); seen_loc = true; }
        if !eat(.COMMA) break;
    }
    expect(.RPAREN, "')'");
    return me;
}

// DenormalFPEnv encoding: default output | default input << 4 | f32 output << 8 | f32 input << 12;
// kinds: ieee 0, preservesign 1, positivezero 2, dynamic 3 (llvm/ADT/FloatingPointMode.h).
DENORMAL_NAMES :: string.["ieee", "preservesign", "positivezero", "dynamic"];

parse_denormal_entry :: () -> u64 {
    outm: u64 = 0xFF;
    for DENORMAL_NAMES if is_kw(it) { outm = cast(u64) it_index; break; }
    if outm == 0xFF perr("expected denormal behavior kind (ieee, preservesign, positivezero, dynamic)");
    next();
    inm := outm;
    if eat(.BAR) {
        inm = 0xFF;
        for DENORMAL_NAMES if is_kw(it) { inm = cast(u64) it_index; break; }
        if inm == 0xFF perr("expected denormal behavior kind (ieee, preservesign, positivezero, dynamic)");
        next();
    }
    return outm | (inm << 4);
}

parse_denormal_fpenv :: () -> u64 {
    P.lx.ignore_colon = true;
    defer P.lx.ignore_colon = false;
    next();
    expect(.LPAREN, "'('");
    dflt: u64 = 0;
    f32: u64 = 0xFFFF;
    has_default := false;
    if !is_kw("float") { dflt = parse_denormal_entry(); has_default = true; }
    comma := eat(.COMMA);
    if is_kw("float") {
        if has_default && !comma perr("expected ',' before float:");
        next();
        expect(.COLON, "':' before float denormal_fpenv");
        f32 = parse_denormal_entry();
    }
    expect(.RPAREN, "unterminated denormal_fpenv");
    if f32 == 0xFFFF f32 = dflt;
    return dflt | (f32 << 8);
}

// FPClassTest bits (llvm/ADT/FloatingPointMode.h)
FPCLASS_NAMES :: struct { mask: u64; name: string; }.[
    .{0x3FF, "all"}, .{0x3, "nan"}, .{0x1, "snan"}, .{0x2, "qnan"}, .{0x204, "inf"}, .{0x4, "ninf"},
    .{0x200, "pinf"}, .{0x60, "zero"}, .{0x20, "nzero"}, .{0x40, "pzero"}, .{0x90, "sub"}, .{0x10, "nsub"},
    .{0x80, "psub"}, .{0x108, "norm"}, .{0x8, "nnorm"}, .{0x100, "pnorm"},
];

parse_nofpclass_attr :: () -> u64 {
    next();
    expect(.LPAREN, "'('");
    mask: u64 = 0;
    if P.tok.kind == .APSINT {
        mask = parse_uint();
    } else {
        while P.tok.kind == .KW {
            found := false;
            for FPCLASS_NAMES if it.name == P.tok.text { mask |= it.mask; found = true; break; }
            if !found perr("invalid mask value for 'nofpclass'");
            next();
        }
    }
    expect(.RPAREN, "')'");
    return mask;
}

// CaptureInfo encoding: low 4 bits "other" components, next 4 bits "ret" components.
// Components: AddressIsNull=1, Address=3, ReadProvenance=4, Provenance=12 (llvm/Support/ModRef.h)
parse_capture_components :: () -> u64 {
    cc: u64 = 0;
    while true {
        if eat_kw("none") {}
        else if eat_kw("address") cc |= 3;
        else if eat_kw("address_is_null") cc |= 1;
        else if eat_kw("provenance") cc |= 12;
        else if eat_kw("read_provenance") cc |= 4;
        else perr("expected one of 'none', 'address', 'address_is_null', 'provenance' or 'read_provenance'");
        if P.tok.kind != .COMMA return cc;
        // lookahead: "ret:" ends the list
        save := P.lx.pos; savetok := P.tok;
        next();
        if is_kw("ret") { P.lx.pos = save; P.tok = savetok; return cc; }
    }
    return cc;
}

parse_captures_attr :: () -> u64 {
    P.lx.ignore_colon = true;
    defer P.lx.ignore_colon = false;
    next();
    expect(.LPAREN, "'('");
    other: u64 = 0; ret: u64 = 0;
    seen_ret := false;
    if !is_kw("ret") {
        other = parse_capture_components();
        ret = other;
    }
    if eat(.COMMA) || is_kw("ret") {
        expect_kw("ret");
        expect(.COLON, "':'");
        ret = parse_capture_components();
        seen_ret = true;
    }
    expect(.RPAREN, "')'");
    return other | (ret << 4);
}

parse_string_attribute :: (out: *[..] Attr) {
    a: Attr;
    a.kind = .STRING_ATTR;
    a.ty = NONE;
    a.key = P.tok.text;
    next();
    if eat(.EQUAL) a.val = parse_string();
    array_add(out, a);
}

// LLParser::parseOptionalParamOrReturnAttrs
parse_optional_param_or_return_attrs :: (out: *[..] Attr, is_param: bool) {
    while true {
        if P.tok.kind == .STRING { parse_string_attribute(out); continue; }
        if P.tok.kind != .KW return;
        if P.tok.text == "nocapture" {
            next();
            a: Attr; a.kind = .Captures; a.ty = NONE; a.ival = 0;
            array_add(out, a);
            continue;
        }
        kind := attr_kind_from_name(P.tok.text);
        if kind == .NONE_ATTR return;
        parse_enum_attribute(kind, out, false);
    }
}

// LLParser::parseFnAttributeValuePairs
parse_fn_attribute_value_pairs :: (out: *[..] Attr, groups: *[..] u32, in_group: bool) {
    me: u64 = 0xFFFF_FFFF_FFFF_FFFF;  // unknown
    while true {
        if P.tok.kind == .RBRACE break;
        if P.tok.kind == .STRING { parse_string_attribute(out); continue; }
        if P.tok.kind == .ATTR_GRP_ID {
            if in_group perr("cannot have an attribute group reference in an attribute group");
            array_add(groups, cast(u32) P.tok.uval);
            next();
            continue;
        }
        if P.tok.kind != .KW { if in_group perr("unterminated attribute group"); break; }
        s := P.tok.text;
        legacy: u64 = 0xFF;
        if s == "readnone" legacy = 0;
        else if s == "readonly" legacy = 1;
        else if s == "writeonly" legacy = 2;
        else if s == "argmemonly" legacy = 10;
        else if s == "inaccessiblememonly" legacy = 11;
        else if s == "inaccessiblemem_or_argmemonly" legacy = 12;
        if legacy != 0xFF {
            next();
            full := mem_all(3);
            if me == 0xFFFF_FFFF_FFFF_FFFF me = full;
            if legacy <= 2 {
                lim := mem_all(ifx legacy == 0 then cast(u64) 0 else ifx legacy == 1 then cast(u64) 1 else 2);
                me &= lim;
            } else if legacy == 10 { me &= mem_set(0, 0, 3); }
            else if legacy == 11 { me &= mem_set(0, 1, 3); }
            else { me &= mem_set(mem_set(0, 0, 3), 1, 3); }
            continue;
        }
        kind := attr_kind_from_name(s);
        if kind == .NONE_ATTR {
            if !in_group break;
            perr("unterminated attribute group");
        }
        parse_enum_attribute(kind, out, in_group);
    }
    if me != 0xFFFF_FFFF_FFFF_FFFF {
        a: Attr; a.kind = .Memory; a.ty = NONE; a.ival = me;
        array_add(out, a);
    }
}

parse_attr_group :: () {
    if P.tok.kind != .ATTR_GRP_ID perr("expected attribute group id");
    id := cast(u32) P.tok.uval;
    next();
    expect(.EQUAL, "'='");
    expect(.LBRACE, "'{'");
    found, existing := table_find(*P.attr_groups, id);
    attrs: [..] Attr;
    groups: [..] u32; groups.allocator = temp;
    parse_fn_attribute_value_pairs(*attrs, *groups, true);
    expect(.RBRACE, "end of attribute group");
    if attrs.count == 0 perr("attribute group has no attributes");
    table_set(*P.attr_groups, id, attrs);
}

// ---------------------------------------------------------------- metadata

// Numbered metadata follows LLParser + MDNode semantics (llvm/lib/IR/Metadata.cpp): a reference to an undefined
// !N is a temporary node; when !N is defined the temporary is RAUW'd, and every uniqued user is re-uniqued
// (MDNode::handleChangedOperand): a node that now references itself becomes distinct, a node that collides with an
// existing equal node is replaced by it.
md_ref_numbered :: (n: u32) -> Md_Id {
    found, m := table_find(*P.md_defined, n);
    if found return m;
    found, m = table_find(*P.md_numbered, n);
    if found return m;
    m = md_temp();
    ir.mds[m].kind = .DI;   // marks a temporary; value = number
    ir.mds[m].value = n;
    ir.mds[m].str = "<fwd>";
    table_add(*P.md_numbered, n, m);
    return m;
}

is_md_temp :: inline (m: Md_Id) -> bool { return m != NONE && ir.mds[m].kind == .DI && ir.mds[m].str == "<fwd>"; }

Md_Use :: struct { user: Md_Id; idx: u32; }
md_users: Table(Md_Id, [..] Md_Use);
md_forward: Table(Md_Id, Md_Id);   // node replaced by an equal node

md_register_uses :: (m: Md_Id) {
    r := ir.mds[m];
    if r.kind != .TUPLE return;
    for i: 0..cast(s64)r.nops-1 {
        o := ir.md_ops[r.ops + cast(u32) i];
        if o == NONE continue;
        ok := ir.mds[o].kind;
        if ok != .TUPLE && ok != .DI continue;
        list := table_find_pointer(*md_users, o);
        if !list { e: [..] Md_Use; list = table_add(*md_users, o, e); }
        array_add(list, .{m, cast(u32) i});
    }
}

md_tuple_key :: (m: Md_Id) -> string {
    k := *md_key; key_reset(k); key_u8(k, 2);
    r := ir.mds[m];
    for i: 0..cast(s64)r.nops-1 key_u32(k, ir.md_ops[r.ops + cast(u32) i]);
    return key_view(k);
}

md_rauw :: (old: Md_Id, new: Md_Id) {
    list := table_find_pointer(*md_users, old);
    if !list return;
    uses := list.*;
    table_remove(*md_users, old);
    for uses md_handle_changed_operand(it.user, it.idx, old, new);
}

md_handle_changed_operand :: (m: Md_Id, idx: u32, old: Md_Id, new: Md_Id) {
    if ir.v_kind.count < 0 return;
    r := *ir.mds[m];
    if r.kind != .TUPLE return;
    if ir.md_ops[r.ops + idx] != old return;   // stale use
    if r.distinct || table_contains(*md_forward, m) {
        ir.md_ops[r.ops + idx] = new;
        md_add_use(new, m, idx);
        return;
    }
    // uniqued: erase from the store, change the operand, re-unique
    key := md_tuple_key(m);
    f, cur := table_find(*ir.md_map, key);
    if f && cur == m table_remove(*ir.md_map, key);
    ir.md_ops[r.ops + idx] = new;
    md_add_use(new, m, idx);
    if new == m { ir.mds[m].distinct = true; return; }
    key = md_tuple_key(m);
    f, cur = table_find(*ir.md_map, key);
    if f && cur != m {
        table_set(*md_forward, m, cur);
        md_rauw(m, cur);
        return;
    }
    table_add(*ir.md_map, copy_string(key), m);
}

md_add_use :: (o: Md_Id, user: Md_Id, idx: u32) {
    if o == NONE return;
    ok := ir.mds[o].kind;
    if ok != .TUPLE && ok != .DI return;
    list := table_find_pointer(*md_users, o);
    if !list { e: [..] Md_Use; list = table_add(*md_users, o, e); }
    array_add(list, .{user, idx});
}

md_final_of :: (m: Md_Id) -> Md_Id {
    x := m;
    while true {
        if x == NONE return x;
        if is_md_temp(x) {
            n := ir.mds[x].value;
            found, d := table_find(*P.md_defined, n);
            if !found perr("use of undefined metadata '!%'", n);
            x = d;
            continue;
        }
        found, f := table_find(*md_forward, x);
        if !found return x;
        x = f;
    }
    return x;
}

parse_md_node_ref :: () -> Md_Id {
    // !N or !{...}
    if P.tok.kind == .EXCLAIM {
        next();
        if P.tok.kind == .APSINT { n := cast(u32) parse_uint(); return md_ref_numbered(n); }
        if P.tok.kind == .LBRACE return parse_md_tuple_body(false);
        perr("expected metadata node");
    }
    perr("expected metadata node");
    return NONE;
}

parse_md_tuple_body :: (distinct: bool) -> Md_Id {
    expect(.LBRACE, "'{'");
    ops: [..] Md_Id; ops.allocator = temp;
    if P.tok.kind != .RBRACE {
        while true {
            if is_kw("null") { next(); array_add(*ops, NONE); }
            else array_add(*ops, parse_metadata_operand());
            if !eat(.COMMA) break;
        }
    }
    expect(.RBRACE, "'}'");
    m := md_tuple(ops, distinct);
    md_register_uses(m);
    return m;
}

// Metadata operand: !N, !"str", !{...}, !DIxxx(...), or "type value".
parse_metadata_operand :: () -> Md_Id {
    if P.tok.kind == .EXCLAIM {
        next();
        if P.tok.kind == .STRING { s := P.tok.text; next(); return md_string(s); }
        if P.tok.kind == .APSINT { n := cast(u32) parse_uint(); return md_ref_numbered(n); }
        if P.tok.kind == .LBRACE return parse_md_tuple_body(false);
        perr("expected metadata");
    }
    if P.tok.kind == .METADATA_VAR perr("specialized metadata (!%) is not supported yet", P.tok.text);
    if is_kw("distinct") perr("distinct metadata only allowed at top level");
    // ValueAsMetadata
    ty := parse_type();
    if ty == ir.t_metadata perr("invalid metadata-value-metadata roundtrip");
    v := parse_value(ty);
    return md_value(v);
}

parse_named_metadata :: () {
    name := P.tok.text;
    next();
    expect(.EQUAL, "'='");
    expect(.EXCLAIM, "'!'");
    expect(.LBRACE, "'{'");
    nm: *Named_Md = null;
    for * ir.named_md if it.name == name { nm = it; break; }
    if !nm {
        n: Named_Md; n.name = intern_str(name);
        array_add(*ir.named_md, n);
        nm = *ir.named_md[ir.named_md.count - 1];
    }
    if P.tok.kind != .RBRACE {
        while true {
            if P.tok.kind == .METADATA_VAR perr("specialized metadata is not supported yet");
            expect(.EXCLAIM, "'!'");
            if P.tok.kind != .APSINT perr("expected metadata number");
            n := cast(u32) parse_uint();
            array_add(*nm.ops, md_ref_numbered(n));
            if !eat(.COMMA) break;
        }
    }
    expect(.RBRACE, "'}'");
}

parse_standalone_metadata :: () {
    next();
    if P.tok.kind != .APSINT perr("expected metadata number");
    n := cast(u32) parse_uint();
    expect(.EQUAL, "'='");
    distinct := eat_kw("distinct");
    if P.tok.kind == .METADATA_VAR perr("specialized metadata (!%) is not supported yet", P.tok.text);
    expect(.EXCLAIM, "'!'");
    if table_contains(*P.md_defined, n) perr("Metadata id is already used");
    m := parse_md_tuple_body(distinct);
    table_add(*P.md_defined, n, m);
    found, t := table_find(*P.md_numbered, n);
    if found {
        table_remove(*P.md_numbered, n);
        md_rauw(t, m);
    }
}

resolve_all_metadata :: () {
    for P.md_numbered perr("use of undefined metadata '!%'", it_index);
    for * a: ir.attaches a.md = md_final_of(a.md);
    for * nm: ir.named_md for * nm.ops it.* = md_final_of(it.*);
    for i: 0..ir.v_kind.count-1 {
        if ir.v_kind[i] == .MD_VALUE ir.v_aux[i] = md_final_of(ir.v_aux[i]);
    }
    // operands of surviving nodes may still name forwarded nodes
    for i: 0..ir.md_ops.count-1 {
        o := ir.md_ops[i];
        if o != NONE && (is_md_temp(o) || table_contains(*md_forward, o)) ir.md_ops[i] = md_final_of(o);
    }
}

// ---------------------------------------------------------------- instructions

parse_fmf :: () -> u32 {
    f: u32 = 0;
    while P.tok.kind == .KW {
        s := P.tok.text;
        if s == "fast" f |= FMF_ALL;
        else if s == "nnan" f |= FMF_NNAN;
        else if s == "ninf" f |= FMF_NINF;
        else if s == "nsz" f |= FMF_NSZ;
        else if s == "arcp" f |= FMF_ARCP;
        else if s == "contract" f |= FMF_CONTRACT;
        else if s == "reassoc" f |= FMF_REASSOC;
        else if s == "afn" f |= FMF_AFN;
        else break;
        next();
    }
    return f << FMF_SHIFT;
}

binop_opcode :: (s: string) -> Opcode {
    if s == "add" return .ADD; if s == "fadd" return .FADD; if s == "sub" return .SUB; if s == "fsub" return .FSUB;
    if s == "mul" return .MUL; if s == "fmul" return .FMUL; if s == "udiv" return .UDIV; if s == "sdiv" return .SDIV;
    if s == "fdiv" return .FDIV; if s == "urem" return .UREM; if s == "srem" return .SREM; if s == "frem" return .FREM;
    if s == "shl" return .SHL; if s == "lshr" return .LSHR; if s == "ashr" return .ASHR; if s == "and" return .AND;
    if s == "or" return .OR; if s == "xor" return .XOR;
    return .NONE_OP;
}

ICMP_PREDS :: string.["eq", "ne", "ugt", "uge", "ult", "ule", "sgt", "sge", "slt", "sle"];
FCMP_PREDS :: string.["false", "oeq", "ogt", "oge", "olt", "ole", "one", "ord", "uno", "ueq", "ugt", "uge", "ult", "ule", "une", "true"];
ORDERING_NAMES :: string.["notatomic", "unordered", "monotonic", "consume", "acquire", "release", "acq_rel", "seq_cst"];
RMW_OPS :: string.["xchg", "add", "sub", "and", "nand", "or", "xor", "max", "min", "umax", "umin", "fadd", "fsub",
    "fmax", "fmin", "fmaximum", "fminimum", "fmaximumnum", "fminimumnum", "uinc_wrap", "udec_wrap", "usub_cond", "usub_sat"];

parse_ordering :: () -> u8 {
    for ORDERING_NAMES if it_index != 0 && it_index != 3 && is_kw(it) { next(); return cast(u8) it_index; }
    perr("Expected ordering on atomic instruction");
    return 0;
}
parse_scope :: () -> u32 {
    if !eat_kw("syncscope") return 0;
    expect(.LPAREN, "'('");
    s := parse_string();
    expect(.RPAREN, "')'");
    for ir.sync_scopes if it_index > 0 && it == s return cast(u32) it_index;
    array_add(*ir.sync_scopes, intern_str(s));
    return cast(u32)(ir.sync_scopes.count - 1);
}

parse_optional_comma_align :: (i: *Inst_Row) -> bool {
    // returns true if a metadata attachment comma was seen (", !foo")
    while P.tok.kind == .COMMA {
        save := P.lx.pos; savetok := P.tok;
        next();
        if P.tok.kind == .METADATA_VAR { P.lx.pos = save; P.tok = savetok; return true; }
        if is_kw("align") { next(); i.align = parse_uint(); continue; }
        P.lx.pos = save; P.tok = savetok;
        return false;
    }
    return false;
}

// Returns the instruction and whether a ", !md" attachment list follows.
parse_instruction :: () -> Value_Id, bool {
    if P.tok.kind != .KW perr("expected instruction opcode");
    s := P.tok.text;
    next();
    bop := binop_opcode(s);
    if bop != .NONE_OP {
        flags: u32 = 0;
        if bop == .ADD || bop == .SUB || bop == .MUL || bop == .SHL {
            if eat_kw("nuw") flags |= F_NUW;
            if eat_kw("nsw") { flags |= F_NSW; if eat_kw("nuw") flags |= F_NUW; }
        } else if bop == .UDIV || bop == .SDIV || bop == .LSHR || bop == .ASHR {
            if eat_kw("exact") flags |= F_EXACT;
        } else if bop == .OR {
            if eat_kw("disjoint") flags |= F_EXACT;
        } else if bop == .FADD || bop == .FSUB || bop == .FMUL || bop == .FDIV || bop == .FREM {
            flags |= parse_fmf();
        }
        ty := parse_type();
        a := parse_value(ty);
        expect(.COMMA, "','");
        b := parse_value(ty);
        i := new_inst(bop, ty, 2);
        inst(i).flags = flags;
        set_op(i, 0, a); set_op(i, 1, b);
        return i, false;
    }
    if s == "fneg" {
        fmf := parse_fmf();
        ty := parse_type();
        a := parse_value(ty);
        i := new_inst(.FNEG, ty, 1);
        inst(i).flags = fmf;
        set_op(i, 0, a);
        return i, false;
    }
    cop := cast_opcode(s);
    if cop != .NONE_OP {
        flags: u32 = 0;
        if cop == .TRUNC {
            if eat_kw("nuw") flags |= F_NUW;
            if eat_kw("nsw") { flags |= F_NSW; if eat_kw("nuw") flags |= F_NUW; }
        } else if cop == .ZEXT || cop == .UITOFP {
            if eat_kw("nneg") flags |= F_EXACT;
        } else if cop == .FPTRUNC || cop == .FPEXT || cop == .UITOFP || cop == .SITOFP {
            flags |= parse_fmf();
        }
        if cop == .UITOFP flags |= parse_fmf();
        v := parse_type_and_value();
        expect_kw("to");
        dt := parse_type();
        i := new_inst(cop, dt, 1);
        inst(i).flags = flags;
        set_op(i, 0, v);
        return i, false;
    }
    if s == "icmp" || s == "fcmp" {
        flags: u32 = 0;
        pred: u8 = 0;
        if s == "icmp" {
            if eat_kw("samesign") flags |= F_EXACT;
            found := false;
            for ICMP_PREDS if is_kw(it) { pred = cast(u8)(32 + it_index); found = true; break; }
            if !found perr("expected icmp predicate (e.g. 'eq')");
            next();
        } else {
            flags |= parse_fmf();
            found := false;
            for FCMP_PREDS if is_kw(it) { pred = cast(u8) it_index; found = true; break; }
            if !found perr("expected fcmp predicate (e.g. 'oeq')");
            next();
        }
        ty := parse_type();
        a := parse_value(ty);
        expect(.COMMA, "','");
        b := parse_value(ty);
        rt := ir.t_i1;
        if is_vector_type(ty) rt = type_vector(type_count(ty), ir.t_i1, type_kind(ty) == .SVECTOR);
        i := new_inst(ifx s == "icmp" then Opcode.ICMP else .FCMP, rt, 2);
        inst(i).flags = flags; inst(i).pred = pred;
        set_op(i, 0, a); set_op(i, 1, b);
        return i, false;
    }
    if s == "ret" {
        if is_kw("void") { next(); return new_inst(.RET, ir.t_void, 0), false; }
        ty := parse_type();
        v := parse_value(ty);
        i := new_inst(.RET, ir.t_void, 1);
        set_op(i, 0, v);
        return i, false;
    }
    if s == "br" {
        ty := parse_type();
        if ty == ir.t_label {
            b := parse_value(ir.t_label);
            i := new_inst(.BR, ir.t_void, 1);
            set_op(i, 0, b);
            return i, false;
        }
        if ty != ir.t_i1 perr("branch condition must have 'i1' type");
        c := parse_value(ty);
        expect(.COMMA, "','");
        t1 := parse_type(); if t1 != ir.t_label perr("expected label");
        a := parse_value(ir.t_label);
        expect(.COMMA, "','");
        t2 := parse_type(); if t2 != ir.t_label perr("expected label");
        b := parse_value(ir.t_label);
        i := new_inst(.CONDBR, ir.t_void, 3);
        set_op(i, 0, c); set_op(i, 1, a); set_op(i, 2, b);
        return i, false;
    }
    if s == "switch" {
        ty := parse_type();
        c := parse_value(ty);
        expect(.COMMA, "','");
        dt := parse_type(); if dt != ir.t_label perr("expected label");
        d := parse_value(ir.t_label);
        expect(.LSQUARE, "'['");
        cases: [..] Value_Id; cases.allocator = temp;
        while P.tok.kind != .RSQUARE {
            cty := parse_type();
            cv := parse_constant(cty);
            expect(.COMMA, "','");
            lt := parse_type(); if lt != ir.t_label perr("expected label");
            dest := parse_value(ir.t_label);
            array_add(*cases, cv); array_add(*cases, dest);
        }
        next();
        // SwitchInst::Create(Cond, Default, NumCases) + addCase: successors are operands, case values side data
        i := new_inst(.SWITCH, ir.t_void, 2);
        grow_ops(i, cast(u32)(2 + cases.count / 2));
        set_op(i, 0, c); set_op(i, 1, d);
        k := 0;
        while k < cases.count { add_op(i, cases[k + 1], cases[k]); k += 2; }
        return i, false;
    }
    if s == "indirectbr" {
        a := parse_type_and_value();
        expect(.COMMA, "','");
        expect(.LSQUARE, "'['");
        dests: [..] Value_Id; dests.allocator = temp;
        if P.tok.kind != .RSQUARE {
            while true {
                lt := parse_type(); if lt != ir.t_label perr("expected label");
                array_add(*dests, parse_value(ir.t_label));
                if !eat(.COMMA) break;
            }
        }
        expect(.RSQUARE, "']'");
        i := new_inst(.INDIRECTBR, ir.t_void, 1);
        grow_ops(i, cast(u32)(1 + dests.count));
        set_op(i, 0, a);
        for dests add_op(i, it);
        return i, false;
    }
    if s == "unreachable" return new_inst(.UNREACHABLE, ir.t_void, 0), false;
    if s == "resume" {
        v := parse_type_and_value();
        i := new_inst(.RESUME, ir.t_void, 1);
        set_op(i, 0, v);
        return i, false;
    }
    if s == "select" {
        fmf := parse_fmf();
        c := parse_type_and_value();
        expect(.COMMA, "','");
        a := parse_type_and_value();
        expect(.COMMA, "','");
        b := parse_type_and_value();
        i := new_inst(.SELECT, vtype(a), 3);
        inst(i).flags = fmf;
        set_op(i, 0, c); set_op(i, 1, a); set_op(i, 2, b);
        return i, false;
    }
    if s == "va_arg" {
        a := parse_type_and_value();
        expect(.COMMA, "','");
        ty := parse_type();
        i := new_inst(.VAARG, ty, 1);
        set_op(i, 0, a);
        return i, false;
    }
    if s == "freeze" {
        a := parse_type_and_value();
        i := new_inst(.FREEZE, vtype(a), 1);
        set_op(i, 0, a);
        return i, false;
    }
    if s == "extractelement" {
        a := parse_type_and_value(); expect(.COMMA, "','");
        b := parse_type_and_value();
        i := new_inst(.EXTRACTELEMENT, type_elem(vtype(a)), 2);
        set_op(i, 0, a); set_op(i, 1, b);
        return i, false;
    }
    if s == "insertelement" {
        a := parse_type_and_value(); expect(.COMMA, "','");
        b := parse_type_and_value(); expect(.COMMA, "','");
        c := parse_type_and_value();
        i := new_inst(.INSERTELEMENT, vtype(a), 3);
        set_op(i, 0, a); set_op(i, 1, b); set_op(i, 2, c);
        return i, false;
    }
    if s == "shufflevector" {
        a := parse_type_and_value(); expect(.COMMA, "','");
        b := parse_type_and_value(); expect(.COMMA, "','");
        m := parse_type_and_value();
        mt := vtype(m);
        n := type_count(mt);
        rt := type_vector(n, type_elem(vtype(a)), type_kind(mt) == .SVECTOR);
        i := new_inst(.SHUFFLEVECTOR, rt, 2);
        set_op(i, 0, a); set_op(i, 1, b);
        r := inst(i);
        r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) n;
        get_shuffle_mask(m, n);
        return i, false;
    }
    if s == "phi" {
        fmf := parse_fmf();
        ty := parse_type();
        vals: [..] Value_Id; vals.allocator = temp;
        bbs: [..] Value_Id; bbs.allocator = temp;
        while true {
            expect(.LSQUARE, "'['");
            v := parse_value(ty);
            expect(.COMMA, "','");
            b := parse_value(ir.t_label);
            expect(.RSQUARE, "']'");
            array_add(*vals, v); array_add(*bbs, b);
            if P.tok.kind != .COMMA break;
            // ", !md" ends the list
            save := P.lx.pos; savetok := P.tok;
            next();
            if P.tok.kind == .METADATA_VAR { P.lx.pos = save; P.tok = savetok; break; }
            P.lx.pos = save; P.tok = savetok;
            next();
        }
        i := new_inst(.PHI, ty, 0);
        inst(i).flags = fmf;
        grow_ops(i, cast(u32) vals.count);
        for vals add_op(i, it, bbs[it_index]);
        return i, false;
    }
    if s == "landingpad" {
        ty := parse_type();
        i := new_inst(.LANDINGPAD, ty, 0);   // LandingPadInst::Create(Ty, NumReservedClauses) + addClause
        if eat_kw("cleanup") inst(i).flags |= F_CLEANUP;
        kinds: [..] u32; kinds.allocator = temp;
        clauses: [..] Value_Id; clauses.allocator = temp;
        while is_kw("catch") || is_kw("filter") {
            ik: u32 = ifx is_kw("catch") then cast(u32) 0 else 1;
            next();
            array_add(*clauses, parse_type_and_value());
            array_add(*kinds, ik);
        }
        grow_ops(i, cast(u32) clauses.count);
        for clauses add_op(i, it);
        r := inst(i);
        r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) kinds.count;
        for kinds array_add(*ir.u32_pool, it);
        return i, false;
    }
    if s == "alloca" {
        i := new_inst(.ALLOCA, ir.t_ptr, 1);
        r := inst(i);
        if eat_kw("inalloca") r.flags |= F_INALLOCA;
        if eat_kw("swifterror") r.flags |= F_SWIFTERR;
        ty := parse_type();
        size: Value_Id = NONE;
        as: u32 = dl.alloca_as;
        md_follows := false;
        while eat(.COMMA) {
            if is_kw("align") { next(); inst(i).align = parse_uint(); }
            else if is_kw("addrspace") { as = parse_optional_addrspace(); }
            else if P.tok.kind == .METADATA_VAR { md_follows = true; break; }
            else if size == NONE { size = parse_type_and_value(); }
            else perr("expected alloca property");
        }
        r = inst(i);
        r.ty2 = ty;
        r.addrspace = as;
        ir.v_type[i] = type_ptr(as);
        if r.align == 0 r.align = dl_pref_align(ty);
        if size == NONE size = const_int(ir.t_i32, 1);
        set_op(i, 0, size);
        if md_follows { parse_instruction_metadata_after_comma(i); }
        return i, false;
    }
    if s == "load" {
        atomic := eat_kw("atomic");
        vol := eat_kw("volatile");
        ty := parse_type();
        expect(.COMMA, "','");
        p := parse_type_and_value();
        i := new_inst(.LOAD, ty, 1);
        r := inst(i);
        if vol r.flags |= F_VOLATILE;
        if atomic { r.sync = parse_scope(); r.ord1 = parse_ordering(); }
        md := parse_optional_comma_align(inst(i));
        r = inst(i);
        if r.align == 0 r.align = dl_abi_align(ty);
        set_op(i, 0, p);
        return i, md;
    }
    if s == "store" {
        atomic := eat_kw("atomic");
        vol := eat_kw("volatile");
        v := parse_type_and_value();
        expect(.COMMA, "','");
        p := parse_type_and_value();
        i := new_inst(.STORE, ir.t_void, 2);
        r := inst(i);
        if vol r.flags |= F_VOLATILE;
        if atomic { r.sync = parse_scope(); r.ord1 = parse_ordering(); }
        md := parse_optional_comma_align(inst(i));
        r = inst(i);
        if r.align == 0 r.align = dl_abi_align(vtype(v));
        set_op(i, 0, v); set_op(i, 1, p);
        return i, md;
    }
    if s == "cmpxchg" {
        weak := eat_kw("weak");
        vol := eat_kw("volatile");
        p := parse_type_and_value(); expect(.COMMA, "','");
        c := parse_type_and_value(); expect(.COMMA, "','");
        nv := parse_type_and_value();
        sc := parse_scope();
        o1 := parse_ordering();
        o2 := parse_ordering();
        rt := type_literal_struct(.[vtype(c), ir.t_i1], false);
        i := new_inst(.CMPXCHG, rt, 3);
        r := inst(i);
        if weak r.flags |= F_WEAK;
        if vol r.flags |= F_VOLATILE;
        r.sync = sc; r.ord1 = o1; r.ord2 = o2;
        md := parse_optional_comma_align(inst(i));
        r = inst(i);
        if r.align == 0 r.align = dl_type_store_size(vtype(c));
        set_op(i, 0, p); set_op(i, 1, c); set_op(i, 2, nv);
        return i, md;
    }
    if s == "atomicrmw" {
        vol := eat_kw("volatile");
        elementwise := eat_kw("elementwise");
        opi: u8 = 0;
        found := false;
        for RMW_OPS if is_kw(it) { opi = cast(u8) it_index; found = true; break; }
        if !found perr("expected binary operation in atomicrmw");
        next();
        p := parse_type_and_value(); expect(.COMMA, "','");
        v := parse_type_and_value();
        sc := parse_scope();
        o := parse_ordering();
        i := new_inst(.ATOMICRMW, vtype(v), 2);
        r := inst(i);
        if vol r.flags |= F_VOLATILE;
        if elementwise r.flags |= F_ELEMENTWISE;
        r.ord2 = opi; r.sync = sc; r.ord1 = o;
        md := parse_optional_comma_align(inst(i));
        r = inst(i);
        if r.align == 0 r.align = dl_type_store_size(vtype(v));
        set_op(i, 0, p); set_op(i, 1, v);
        return i, md;
    }
    if s == "fence" {
        sc := parse_scope();
        o := parse_ordering();
        i := new_inst(.FENCE, ir.t_void, 0);
        inst(i).sync = sc; inst(i).ord1 = o;
        return i, false;
    }
    if s == "getelementptr" {
        flags: u32 = 0;
        while true {
            if eat_kw("inbounds") flags |= F_INBOUNDS;
            else if eat_kw("nusw") flags |= F_NUSW;
            else if eat_kw("nuw") flags |= F_GEP_NUW;
            else break;
        }
        ty := parse_type();
        expect(.COMMA, "','");
        base := parse_type_and_value();
        idxs: [..] Value_Id; idxs.allocator = temp;
        md := false;
        rt := vtype(base);
        while eat(.COMMA) {
            if P.tok.kind == .METADATA_VAR { md = true; break; }
            ix := parse_type_and_value();
            if is_vector_type(vtype(ix)) && !is_vector_type(rt) rt = type_vector(type_count(vtype(ix)), rt, type_kind(vtype(ix)) == .SVECTOR);
            array_add(*idxs, ix);
        }
        i := new_inst(.GEP, rt, cast(u32)(1 + idxs.count));
        r := inst(i);
        r.flags = flags; r.ty2 = ty;
        set_op(i, 0, base);
        for idxs set_op(i, cast(u32)(1 + it_index), it);
        if md parse_instruction_metadata_after_comma(i);
        return i, false;
    }
    if s == "extractvalue" {
        a := parse_type_and_value();
        idx: [..] u32; idx.allocator = temp;
        md := false;
        while eat(.COMMA) {
            if P.tok.kind == .METADATA_VAR { md = true; break; }
            array_add(*idx, cast(u32) parse_uint());
        }
        rt := vtype(a);
        for idx rt = type_sub(rt, ifx type_kind(rt) == .STRUCT then it else 0);
        i := new_inst(.EXTRACTVALUE, rt, 1);
        set_op(i, 0, a);
        r := inst(i);
        r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) idx.count;
        for idx array_add(*ir.u32_pool, it);
        if md parse_instruction_metadata_after_comma(i);
        return i, false;
    }
    if s == "insertvalue" {
        a := parse_type_and_value(); expect(.COMMA, "','");
        b := parse_type_and_value();
        idx: [..] u32; idx.allocator = temp;
        md := false;
        while eat(.COMMA) {
            if P.tok.kind == .METADATA_VAR { md = true; break; }
            array_add(*idx, cast(u32) parse_uint());
        }
        i := new_inst(.INSERTVALUE, vtype(a), 2);
        set_op(i, 0, a); set_op(i, 1, b);
        r := inst(i);
        r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) idx.count;
        for idx array_add(*ir.u32_pool, it);
        if md parse_instruction_metadata_after_comma(i);
        return i, false;
    }
    if s == "call" || s == "tail" || s == "musttail" || s == "notail" {
        tck: u32 = 0;
        if s == "tail" tck = 1; else if s == "musttail" tck = 2; else if s == "notail" tck = 3;
        if tck != 0 expect_kw("call");
        return parse_call(tck), false;
    }
    if s == "invoke" return parse_invoke(), false;
    if s == "callbr" perr("callbr is not supported yet");
    if s == "cleanupret" || s == "catchret" || s == "catchswitch" || s == "catchpad" || s == "cleanuppad"
        perr("funclet instructions are not supported yet");
    perr("expected instruction opcode (got '%')", s);
    return NONE, false;
}

parse_instruction_metadata_after_comma :: (i: Value_Id) {
    // we already consumed one comma and sit on a METADATA_VAR
    while true {
        k := md_kind_id(P.tok.text);
        next();
        m := parse_md_node_ref();
        set_metadata(i, k, m);
        if k == 1 array_add(*P.insts_with_tbaa, i);
        if P.tok.kind != .COMMA break;
        next();
        if P.tok.kind != .METADATA_VAR perr("expected metadata after comma");
    }
}

get_shuffle_mask :: (m: Value_Id, n: u64) {
    k := vkind(m);
    if n > 0 for i: 0..n-1 {
        e: u32 = 0;
        if k == .C_ZERO || is_null_value(m) e = 0;
        else if k == .C_UNDEF || k == .C_POISON e = 0xFFFF_FFFF;
        else if k == .C_DATA e = cast(u32) const_data_elt(m, i);
        else if k == .C_VECTOR {
            el := op(m, cast(u32) i);
            if vkind(el) == .C_INT e = cast(u32) const_int_zext(el);
            else e = 0xFFFF_FFFF;
        } else if k == .C_INT e = cast(u32) const_int_zext(m);
        else perr("invalid shufflevector mask");
        array_add(*ir.u32_pool, e);
    }
}

Param_Info :: struct { v: Value_Id; attrs: u32; }

parse_param_list :: (out: *[..] Param_Info) {
    expect(.LPAREN, "'('");
    while P.tok.kind != .RPAREN {
        if out.count > 0 expect(.COMMA, "','");
        if P.tok.kind == .DOTDOTDOT { next(); break; }   // musttail varargs
        ty := parse_type();
        pa: [..] Attr; pa.allocator = temp;
        v: Value_Id;
        if ty == ir.t_metadata {
            v = parse_metadata_as_value();
        } else {
            parse_optional_param_or_return_attrs(*pa, true);
            v = parse_value(ty);
        }
        array_add(out, .{v, attr_set_get(pa)});
    }
    expect(.RPAREN, "')'");
}

Bundle :: struct { tag: string; inputs: [..] Value_Id; }

parse_optional_bundles :: (out: *[..] Bundle) {
    if P.tok.kind != .LSQUARE return;
    next();
    while P.tok.kind != .RSQUARE {
        if out.count > 0 expect(.COMMA, "','");
        b: Bundle;
        b.tag = intern_str(parse_string());
        expect(.LPAREN, "'('");
        while P.tok.kind != .RPAREN {
            if b.inputs.count > 0 expect(.COMMA, "','");
            ty := parse_type();
            array_add(*b.inputs, parse_value(ty));
        }
        next();
        array_add(out, b);
    }
    next();
}


parse_call :: (tck: u32) -> Value_Id {
    fmf := parse_fmf();
    cc := parse_optional_cc();
    ret_attrs: [..] Attr; ret_attrs.allocator = temp;
    parse_optional_param_or_return_attrs(*ret_attrs, false);
    as := parse_optional_addrspace();
    rt := parse_type(true);
    callee_tok := P.tok;
    callee_lx := P.lx.pos;
    // skip the callee token for now; we need the argument list to resolve the function type
    callee_is_asm := is_kw("asm");
    if callee_is_asm {
        // asm "..." , "..."
        next();
        while is_kw("sideeffect") || is_kw("alignstack") || is_kw("inteldialect") || is_kw("unwind") next();
        parse_string(); expect(.COMMA, "','"); parse_string();
    } else next();
    args: [..] Param_Info; args.allocator = temp;
    parse_param_list(*args);
    fnattrs: [..] Attr; fnattrs.allocator = temp;
    groups: [..] u32;
    parse_fn_attribute_value_pairs(*fnattrs, *groups, false);
    bundles: [..] Bundle; bundles.allocator = temp;
    parse_optional_bundles(*bundles);
    // resolveFunctionType
    fty := rt;
    if type_kind(rt) != .FUNC {
        pts: [..] Type_Id; pts.allocator = temp;
        for args array_add(*pts, vtype(it.v));
        fty = type_func(rt, pts, false);
    }
    // now resolve the callee
    save_tok := P.tok; save_pos := P.lx.pos;
    P.tok = callee_tok; P.lx.pos = callee_lx;
    P.callee_fty = fty;
    callee := parse_value(type_ptr(as));
    P.tok = save_tok; P.lx.pos = save_pos;
    nb := 0;
    for bundles nb += it.inputs.count;
    nargs := args.count;
    i := new_inst(.CALL, func_ret(fty), cast(u32)(nargs + nb + 1));
    psets: [..] u32; psets.allocator = temp;
    for args array_add(*psets, it.attrs);
    r := inst(i);
    r.ty2 = fty;
    r.cc = cc;
    r.flags = fmf | (tck << TAIL_SHIFT);
    r.attrs = attr_list_get(attr_set_get(fnattrs), attr_set_get(ret_attrs), psets);
    // bundle info: per bundle (tag string index, begin, end)
    if bundles.count {
        r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) bundles.count;
        pos := cast(u32) nargs;
        for bundles {
            array_add(*ir.u32_pool, bundle_tag_id(it.tag));
            array_add(*ir.u32_pool, pos);
            pos += cast(u32) it.inputs.count;
            array_add(*ir.u32_pool, pos);
        }
    }
    // CallInst::init: arguments, then bundle operands, then the callee
    for args set_op(i, cast(u32) it_index, it.v);
    k: u32 = cast(u32) nargs;
    for b: bundles for b.inputs { set_op(i, k, it); k += 1; }
    set_op(i, k, callee);
    array_add(*P.fwd_attr_refs, .{i, groups, true, false});
    return i;
}

parse_invoke :: () -> Value_Id {
    cc := parse_optional_cc();
    ret_attrs: [..] Attr; ret_attrs.allocator = temp;
    parse_optional_param_or_return_attrs(*ret_attrs, false);
    as := parse_optional_addrspace();
    rt := parse_type(true);
    callee_tok := P.tok;
    callee_lx := P.lx.pos;
    if is_kw("asm") perr("inline asm invoke is not supported yet");
    next();
    args: [..] Param_Info; args.allocator = temp;
    parse_param_list(*args);
    fnattrs: [..] Attr; fnattrs.allocator = temp;
    groups: [..] u32;
    parse_fn_attribute_value_pairs(*fnattrs, *groups, false);
    bundles: [..] Bundle; bundles.allocator = temp;
    parse_optional_bundles(*bundles);
    expect_kw("to");
    nt := parse_type(); if nt != ir.t_label perr("expected label");
    normal := parse_value(ir.t_label);
    expect_kw("unwind");
    ut := parse_type(); if ut != ir.t_label perr("expected label");
    unwind := parse_value(ir.t_label);
    fty := rt;
    if type_kind(rt) != .FUNC {
        pts: [..] Type_Id; pts.allocator = temp;
        for args array_add(*pts, vtype(it.v));
        fty = type_func(rt, pts, false);
    }
    save_tok := P.tok; save_pos := P.lx.pos;
    P.tok = callee_tok; P.lx.pos = callee_lx;
    P.callee_fty = fty;
    callee := parse_value(type_ptr(as));
    P.tok = save_tok; P.lx.pos = save_pos;
    nb := 0;
    for bundles nb += it.inputs.count;
    nargs := args.count;
    i := new_inst(.INVOKE, func_ret(fty), cast(u32)(nargs + nb + 3));
    psets: [..] u32; psets.allocator = temp;
    for args array_add(*psets, it.attrs);
    r := inst(i);
    r.ty2 = fty; r.cc = cc;
    r.attrs = attr_list_get(attr_set_get(fnattrs), attr_set_get(ret_attrs), psets);
    if bundles.count {
        r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) bundles.count;
        pos := cast(u32) nargs;
        for bundles {
            array_add(*ir.u32_pool, bundle_tag_id(it.tag));
            array_add(*ir.u32_pool, pos);
            pos += cast(u32) it.inputs.count;
            array_add(*ir.u32_pool, pos);
        }
    }
    // InvokeInst::init: args, bundles, normal dest, unwind dest, callee
    for args set_op(i, cast(u32) it_index, it.v);
    k: u32 = cast(u32) nargs;
    for b: bundles for b.inputs { set_op(i, k, it); k += 1; }
    set_op(i, k, normal); set_op(i, k + 1, unwind); set_op(i, k + 2, callee);
    array_add(*P.fwd_attr_refs, .{i, groups, true, false});
    return i;
}

bundle_tags: [..] string;
bundle_tag_id :: (s: string) -> u32 {
    for bundle_tags if it == s return cast(u32) it_index;
    array_add(*bundle_tags, s);
    return cast(u32)(bundle_tags.count - 1);
}

// ---------------------------------------------------------------- end of module

validate_end_of_module :: () {
    // attribute group references (ForwardRefAttrGroups)
    for P.fwd_attr_refs {
        merged: [..] Attr; merged.allocator = temp;
        for g: it.groups {
            found, attrs := table_find(*P.attr_groups, g);
            if found for attrs array_add(*merged, it);
        }
        v := it.v;
        if it.is_gvar {
            glob(v).attrs = attr_set_merge(glob(v).attrs, attr_set_get(merged));
        } else if it.is_call {
            r := inst(v);
            fnset := attr_set_merge(attr_list_fn(r.attrs), attr_set_get(merged));
            r.attrs = attr_list_with_fn(r.attrs, fnset);
        } else {
            g := glob(v);
            fnset := attr_set_merge(attr_list_fn(g.attrs), attr_set_get(merged));
            a := attr_set_find(fnset, .Alignment);
            if a { g.align = a.ival; fnset = attr_set_remove(fnset, .Alignment); }
            g.attrs = attr_list_with_fn(g.attrs, fnset);
        }
    }
    if P.blockaddr_fwd.count perr("expected function name in blockaddress");
    for ir.named_types {
        // types referenced but never defined stay opaque in LLVM only if defined as opaque; otherwise error
    }
    // Forward-referenced intrinsics are auto-declared (with the mangling suffix the call's type needs);
    // ForwardRefVals is a std::map, so this goes in name order. Other forward refs are errors.
    names: [..] string; names.allocator = temp;
    for v, n: P.fwd_globals array_add(*names, n);
    quick_sort(names, (a: string, b: string) -> s64 { return compare(a, b); });
    for name: names {
        _, fw := table_find(*P.fwd_globals, name);
        if !begins_with(name, "llvm.") perr("use of undefined value '@%'", name);
        auto_declare_intrinsic(name, fw);
        erase_global(fw);
        table_remove(*P.fwd_globals, name);
    }
    for P.fwd_global_ids perr("use of undefined value '@%'", it_index);
    resolve_all_metadata();
    // UpgradeCallsToIntrinsic for every function (make_early_inc_range: functions appended meanwhile are visited)
    i := 0;
    while i < ir.m_functions.count {
        f := ir.m_functions[i];
        upgrade_calls_to_intrinsic(f);
        if i < ir.m_functions.count && ir.m_functions[i] == f i += 1;
    }
}

auto_declare_intrinsic :: (name: string, fw: Value_Id) {
    id := intrinsic_lookup_id(name);
    // make_early_inc_range(Info.first->uses())
    uses: [..] Use_Id; uses.allocator = temp;
    u := ir.v_first_use[fw];
    while u != NONE { array_add(*uses, u); u = ir.u_next[u]; }
    for u: uses {
        cb := ir.u_user[u];
        is_callee := vkind(cb) == .INST && (inst_op(cb) == .CALL || inst_op(cb) == .INVOKE || inst_op(cb) == .CALLBR) &&
                     u == op_use(cb, nops(cb) - 1);
        if !is_callee perr("intrinsic can only be used as callee");
        fty := inst(cb).ty2;
        otys: [..] Type_Id; otys.allocator = temp;
        if id != NOT_INTRINSIC && intrinsic_signature_valid(id, fty, *otys) {
            use_set(u, get_or_insert_intrinsic_declaration(id, otys));
        } else {
            tmp := new_function(fty, name, 0);
            array_add(*ir.m_functions, tmp);
            tid := function_intrinsic_id(tmp);
            if tid != NOT_INTRINSIC set_intrinsic_attributes(tmp, tid);
            r := upgrade_intrinsic_function(tmp);
            if !r.upgraded {
                if id == NOT_INTRINSIC perr("unknown intrinsic '%'", name);
                perr("invalid signature for intrinsic '%'", name);
            }
            use_set(u, tmp);
            upgrade_intrinsic_call(cb, r.new_fn);
            if !has_uses(tmp) erase_global(tmp);
        }
    }
}

#import "File";
#import "Sort";
saw_source_filename := false;
