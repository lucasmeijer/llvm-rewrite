// Debug-info metadata: the specialized DI* nodes, DIArgList, debug records (#dbg_value ...), the upgrade of
// llvm.dbg.* intrinsic calls to records, and StripDebugInfo for modules without a valid "Debug Info Version".
// Ported from llvm/lib/AsmParser/LLParser.cpp (parseDI*, parseMDField*, parseDebugRecord, parseDIArgList,
// parseDIExpressionBody), llvm/lib/IR/DebugInfoMetadata.cpp (getImpl operand orders and canonicalizations,
// DINode::splitFlags, DIExpression::isValid / ExprOperand::getSize, DISubprogram::cleanupRetainedNodes),
// llvm/lib/IR/AsmWriter.cpp (MDFieldPrinter, writeDI*, printDbgVariableRecord, SlotTracker::processDbgRecordMetadata),
// llvm/lib/IR/AutoUpgrade.cpp (upgradeDbgIntrinsicToDbgRecord, UpgradeDebugInfo) and
// llvm/lib/IR/DebugInfo.cpp (StripDebugInfo, stripDebugInfo(Function), stripDebugLocFromLoopID).
//
// A DI node is an Md_Row of kind SPECIAL: `sub` is the DI_Kind, `ops` are its metadata operands in LLVM's operand
// order (that order decides metadata numbering), `ints` its integer fields (layout per kind below).
// MDString operands are canonical: "" is stored as a null operand, like LLVM's getCanonicalMDString.

DI_Kind :: enum u8 {
    LOCATION; EXPRESSION; GLOBAL_VARIABLE_EXPRESSION; FILE; COMPILE_UNIT; SUBPROGRAM; SUBROUTINE_TYPE;
    BASIC_TYPE; DERIVED_TYPE; COMPOSITE_TYPE; LOCAL_VARIABLE; GLOBAL_VARIABLE; LEXICAL_BLOCK; LEXICAL_BLOCK_FILE;
    NAMESPACE; SUBRANGE; LABEL; ASSIGN_ID; ARG_LIST; IMPORTED_ENTITY; TEMPLATE_TYPE_PARAMETER;
    TEMPLATE_VALUE_PARAMETER;
    ENUMERATOR; GENERIC_SUBRANGE; MODULE; MACRO; MACRO_FILE; COMMON_BLOCK; OBJC_PROPERTY; STRING_TYPE; SUBRANGE_TYPE;
    FIXED_POINT_TYPE; GENERIC_DINODE;
}

DI_NAMES :: string.[
    "DILocation", "DIExpression", "DIGlobalVariableExpression", "DIFile", "DICompileUnit", "DISubprogram",
    "DISubroutineType", "DIBasicType", "DIDerivedType", "DICompositeType", "DILocalVariable", "DIGlobalVariable",
    "DILexicalBlock", "DILexicalBlockFile", "DINamespace", "DISubrange", "DILabel", "DIAssignID", "DIArgList",
    "DIImportedEntity", "DITemplateTypeParameter", "DITemplateValueParameter",
    "DIEnumerator", "DIGenericSubrange", "DIModule", "DIMacro", "DIMacroFile", "DICommonBlock", "DIObjCProperty",
    "DIStringType", "DISubrangeType", "DIFixedPointType", "GenericDINode",
];

is_di :: inline (m: Md_Id, k: DI_Kind) -> bool { return m != NONE && ir.mds[m].kind == .SPECIAL && ir.mds[m].sub == cast(u8) k; }
di_kind :: inline (m: Md_Id) -> DI_Kind { return cast(DI_Kind) ir.mds[m].sub; }
di_int :: inline (m: Md_Id, i: u32) -> u64 { return ir.md_ints[ir.mds[m].ints + i]; }
di_op :: inline (m: Md_Id, i: u32) -> Md_Id { if i >= ir.mds[m].nops return NONE; return md_op(m, i); }
// MDNode? (TUPLE or a DI node other than the non-node DIArgList)
is_md_node :: (m: Md_Id) -> bool {
    if m == NONE return false;
    k := ir.mds[m].kind;
    if k == .TUPLE || k == .DI return true;
    return k == .SPECIAL && ir.mds[m].sub != cast(u8) DI_Kind.ARG_LIST;
}
// nodes that get no slot and are printed inline (SlotTracker::CreateMetadataSlot skips DIExpression)
is_inline_md :: (m: Md_Id) -> bool { return is_di(m, .EXPRESSION) || is_di(m, .ARG_LIST); }

// Uniquing key: kind, sub, ints, ops
md_special_key :: (sub: u8, ints: [] u64, ops: [] Md_Id) -> *Key {
    k := *md_key; key_reset(k);
    key_u8(k, 3); key_u8(k, sub);
    key_u32(k, cast(u32) ints.count); for ints key_u64(k, it);
    for ops key_u32(k, it);
    return k;
}

// MDNode::get / getDistinct for a DI node
di_get :: (sub: DI_Kind, distinct: bool, ops: [] Md_Id, ints: [] u64) -> Md_Id {
    k := md_special_key(cast(u8) sub, ints, ops);
    if !distinct {
        found, id := table_find(*ir.md_map, key_view(k));
        if found return id;
    }
    row: Md_Row; row.kind = .SPECIAL; row.distinct = distinct; row.sub = cast(u8) sub;
    row.ops = cast(u32) ir.md_ops.count; row.nops = cast(u32) ops.count;
    for ops array_add(*ir.md_ops, it);
    row.ints = cast(u32) ir.md_ints.count; row.nints = cast(u32) ints.count;
    for ints array_add(*ir.md_ints, it);
    id := cast(Md_Id) ir.mds.count;
    array_add(*ir.mds, row);
    if !distinct table_add(*ir.md_map, key_copy(k), id);
    // DILocation::DILocation: updateDILocationAtomGroupWaterline(AtomGroup + 1)
    if sub == .LOCATION && ints.count > 3 && ints[3] != 0 && ints[3] + 1 > ir.next_atom_group ir.next_atom_group = ints[3] + 1;
    return id;
}

// ValueToValueMapTy::AtomMap: (inlinedAt, atom group) -> the group of the new instance
Atom_Entry :: struct { ia: Md_Id; group: u64; new: u64; }
// mapAtomInstance(DL, VMap)
atom_map_instance :: (atoms: *[..] Atom_Entry, dl: Md_Id) {
    if dl == NONE return;
    g := di_int(dl, 3);
    if g == 0 return;
    ia := di_op(dl, 1);
    for atoms.* if it.ia == ia && it.group == g return;
    n := ir.next_atom_group;   // LLVMContext::incNextDILocationAtomGroup
    ir.next_atom_group += 1;
    array_add(atoms, .{ia, g, n});
}
// RemapSourceAtom(I, VM)
atom_remap_source :: (atoms: [] Atom_Entry, i: Value_Id) {
    if atoms.count == 0 return;
    dl := get_metadata(i, 0);
    if dl == NONE return;
    g := di_int(dl, 3);
    if g == 0 return;
    ia := di_op(dl, 1);
    for atoms if it.ia == ia && it.group == g {
        set_metadata(i, 0, di_location_get(di_int(dl, 0), di_int(dl, 1), di_op(dl, 0), ia, di_int(dl, 2), it.new, di_int(dl, 4)));
        return;
    }
}

md_node_key :: (m: Md_Id) -> string {
    r := ir.mds[m];
    if r.kind == .SPECIAL {
        ints: [] u64; ints.data = ir.md_ints.data + r.ints; ints.count = r.nints;
        ops: [] Md_Id; ops.data = ir.md_ops.data + r.ops; ops.count = r.nops;
        return key_view(md_special_key(r.sub, ints, ops));
    }
    return md_tuple_key(m);
}

// canonical MDString operand: "" -> null
md_str_or_null :: (s: string) -> Md_Id { if s.count == 0 return NONE; return md_string(s); }
md_str_of :: (m: Md_Id) -> string { if m == NONE return ""; return ir.mds[m].str; }

// ---------------------------------------------------------------- field parsing (LLParser::parseMDField)

Field_Type :: enum u8 {
    MD; MD_NONNULL; STR; STR_EMPTY; STR_NONEMPTY; UINT; SINT; BOOL; TAG; ATE; LANG; LNAME; VIRT; CC; MACINFO;
    ENUM_KIND; DIALECT; EMISSION; NAMETABLE; CHECKSUM; FLAGS; SPFLAGS; SIGNED_OR_MD; UNSIGNED_OR_MD; APSINT;
    MD_LIST; FIXED_POINT_KIND;
}

Field_Spec :: struct { name: string; ty: Field_Type; required: bool; dflt: u64; max: u64 = 0xFFFF_FFFF_FFFF_FFFF; }
Field_Val :: struct { seen: bool; is_md: bool; md: Md_Id = NONE; u: u64; s: s64; str: string; neg: bool; list: [] Md_Id; }

DW_TAG_HI_USER :: 0xffff;
U64MAX :: 0xFFFF_FFFF_FFFF_FFFF;

dwarf_lookup :: (tab: [] Dwarf_Name, name: string) -> (bool, u64) {
    for tab if it.name == name return true, it.value;
    return false, 0;
}
dwarf_name :: (tab: [] Dwarf_Name, v: u64) -> string {
    for tab if it.value == v return it.name;
    return "";
}

apsint_tok_value :: () -> (neg: bool, u: u64, s: s64) {
    t := P.tok;
    if t.kind != .APSINT perr("expected integer");
    txt := t.text;
    if t.hex_kind != 0 {
        w := hex_to_words(txt, 1);
        next();
        return false, w[0], cast,no_check(s64) w[0];
    }
    neg := txt.count > 0 && txt[0] == #char "-";
    digits := ifx neg then slice(txt, 1, txt.count - 1) else txt;
    w := apint_from_decimal(digits, 128);
    if w[1] != 0 || (neg && w[0] > 0x8000_0000_0000_0000) perr("integer too large");
    next();
    u := w[0];
    s := ifx neg then -(cast,no_check(s64) u) else cast,no_check(s64) u;
    return neg, u, s;
}

parse_md_field_uint :: (name: string, max: u64) -> u64 {
    if P.tok.kind != .APSINT perr("expected unsigned integer");
    neg, u, s := apsint_tok_value();
    if neg perr("expected unsigned integer");
    if u > max perr("value for '%' too large, limit is %", name, max);
    return u;
}

parse_dwarf_enum_field :: (name: string, tab: [] Dwarf_Name, prefix: string, max: u64) -> u64 {
    if P.tok.kind == .APSINT return parse_md_field_uint(name, max);
    if P.tok.kind != .KW || !begins_with(P.tok.text, prefix) perr("expected DWARF % (%*)", name, prefix);
    ok, v := dwarf_lookup(tab, P.tok.text);
    if !ok perr("invalid DWARF value '%'", P.tok.text);
    next();
    return v;
}

parse_flag_list :: (tab: [] Dwarf_Name, prefix: string) -> u64 {
    r: u64 = 0;
    while true {
        if P.tok.kind == .APSINT {
            r |= parse_md_field_uint("flags", 0xFFFF_FFFF);
        } else {
            if P.tok.kind != .KW || !begins_with(P.tok.text, prefix) perr("expected debug info flag");
            ok, v := dwarf_lookup(tab, P.tok.text);
            if !ok perr("invalid debug info flag '%'", P.tok.text);
            r |= v;
            next();
        }
        if !eat(.BAR) break;
    }
    return r;
}

// LLParser::parseMetadata without a function state (MDField values)
parse_md_field_metadata :: () -> Md_Id {
    if P.tok.kind == .METADATA_VAR {
        if P.tok.text == "DIArgList" perr("found DIArgList outside of function");
        return parse_specialized_md(false);
    }
    if P.tok.kind == .EXCLAIM {
        next();
        if P.tok.kind == .STRING { s := P.tok.text; next(); return md_string(s); }
        if P.tok.kind == .APSINT { n := cast(u32) parse_uint(); return md_ref_numbered(n); }
        if P.tok.kind == .LBRACE return parse_md_tuple_body(false);
        perr("expected metadata");
    }
    ty := parse_type();
    if ty == ir.t_metadata perr("invalid metadata-value-metadata roundtrip");
    v := parse_value(ty);
    return md_value(v);
}

parse_one_field :: (spec: Field_Spec, val: *Field_Val) {
    name := spec.name;
    val.seen = true;
    if spec.ty == {
        case .MD; #through;
        case .MD_NONNULL;
            if is_kw("null") {
                if spec.ty == .MD_NONNULL perr("'%' cannot be null", name);
                next(); val.md = NONE; val.is_md = true; return;
            }
            val.md = parse_md_field_metadata(); val.is_md = true;
        case .STR; #through;
        case .STR_EMPTY; #through;
        case .STR_NONEMPTY;
            if P.tok.kind != .STRING perr("expected string constant");
            val.str = P.tok.text; next();
            if val.str.count == 0 {
                if spec.ty == .STR_NONEMPTY perr("'%' cannot be empty", name);
                if spec.ty == .STR { val.md = NONE; return; }
            }
            val.md = md_string(val.str);
        case .UINT; val.u = parse_md_field_uint(name, spec.max);
        case .SINT;
            if P.tok.kind != .APSINT perr("expected signed integer");
            neg, u, s := apsint_tok_value();
            val.s = s; val.u = cast,no_check(u64) s;
        case .APSINT;
            if P.tok.kind != .APSINT perr("expected integer");
            neg, u, s := apsint_tok_value();
            val.s = s; val.u = u; val.neg = neg;
        case .MD_LIST;
            // parseMDNodeVector
            expect(.LBRACE, "'{'");
            l: [..] Md_Id; l.allocator = temp;
            if P.tok.kind != .RBRACE {
                while true {
                    if is_kw("null") { next(); array_add(*l, NONE); }
                    else array_add(*l, parse_metadata_operand());
                    if !eat(.COMMA) break;
                }
            }
            expect(.RBRACE, "'}'");
            val.list = l;
        case .FIXED_POINT_KIND;
            // DIFixedPointType::getFixedPointKind
            ok, v := dwarf_lookup(FIXED_POINT_KIND_NAMES, P.tok.text);
            if P.tok.kind != .KW || !ok perr("expected fixed-point kind");
            val.u = v; next();
        case .BOOL;
            if is_kw("true") val.u = 1; else if is_kw("false") val.u = 0; else perr("expected 'true' or 'false'");
            next();
        case .TAG; val.u = parse_dwarf_enum_field(name, DW_TAG_NAMES, "DW_TAG_", DW_TAG_HI_USER);
        case .ATE; val.u = parse_dwarf_enum_field(name, DW_ATE_NAMES, "DW_ATE_", 0xff);
        case .LANG; val.u = parse_dwarf_enum_field(name, DW_LANG_NAMES, "DW_LANG_", 0xffff);
        case .LNAME; val.u = parse_dwarf_enum_field(name, DW_LNAME_NAMES, "DW_LNAME_", 0xFFFF_FFFF);
        case .VIRT; val.u = parse_dwarf_enum_field(name, DW_VIRTUALITY_NAMES, "DW_VIRTUALITY_", 2);
        case .CC; val.u = parse_dwarf_enum_field(name, DW_CC_NAMES, "DW_CC_", 0xff);
        case .MACINFO; val.u = parse_dwarf_enum_field(name, DW_MACINFO_NAMES, "DW_MACINFO_", 0xff);
        case .ENUM_KIND; val.u = parse_dwarf_enum_field(name, DW_APPLE_ENUM_KIND_NAMES, "DW_APPLE_ENUM_KIND_", 1);
        case .DIALECT; val.u = parse_dwarf_enum_field(name, DW_LLVM_LANG_DIALECT_NAMES, "DW_LLVM_LANG_DIALECT_", 2);
        case .EMISSION;
            if P.tok.kind == .APSINT { val.u = parse_md_field_uint(name, 3); return; }
            ok, v := dwarf_lookup(EMISSION_KIND_NAMES, P.tok.text);
            if P.tok.kind != .KW || !ok perr("expected emission kind");
            val.u = v; next();
        case .NAMETABLE;
            if P.tok.kind == .APSINT { val.u = parse_md_field_uint(name, 3); return; }
            ok, v := dwarf_lookup(NAME_TABLE_KIND_NAMES, P.tok.text);
            if P.tok.kind != .KW || !ok perr("expected nameTable kind");
            val.u = v; next();
        case .CHECKSUM;
            ok, v := dwarf_lookup(CHECKSUM_KIND_NAMES, P.tok.text);
            if P.tok.kind != .KW || !ok perr("invalid checksum kind");
            val.u = v; next();
        case .FLAGS; val.u = parse_flag_list(DI_FLAG_NAMES, "DIFlag");
        case .SPFLAGS; val.u = parse_flag_list(DISP_FLAG_NAMES, "DISPFlag");
        case .SIGNED_OR_MD;
            if P.tok.kind == .APSINT {
                neg, u, s := apsint_tok_value();
                val.s = s; val.u = cast,no_check(u64) s; val.is_md = false;
            } else {
                if is_kw("null") { next(); val.md = NONE; } else val.md = parse_md_field_metadata();
                val.is_md = true;
            }
        case .UNSIGNED_OR_MD;
            if P.tok.kind == .APSINT {
                val.u = parse_md_field_uint(name, spec.max); val.is_md = false;
            } else {
                if is_kw("null") { next(); val.md = NONE; } else val.md = parse_md_field_metadata();
                val.is_md = true;
            }
    }
}

EMISSION_KIND_NAMES :: Dwarf_Name.[ .{0, "NoDebug"}, .{1, "FullDebug"}, .{2, "LineTablesOnly"}, .{3, "DebugDirectivesOnly"} ];
NAME_TABLE_KIND_NAMES :: Dwarf_Name.[ .{0, "Default"}, .{1, "GNU"}, .{2, "None"}, .{3, "Apple"} ];
FIXED_POINT_KIND_NAMES :: Dwarf_Name.[ .{0, "Binary"}, .{1, "Decimal"}, .{2, "Rational"} ];
CHECKSUM_KIND_NAMES :: Dwarf_Name.[ .{1, "CSK_MD5"}, .{2, "CSK_SHA1"}, .{3, "CSK_SHA256"} ];

// LLParser::parseMDFieldsImpl: '(' field (',' field)* ')' with each field at most once
parse_di_fields :: (specs: [] Field_Spec) -> [] Field_Val {
    vals := NewArray(specs.count, Field_Val,, allocator = temp);
    for * vals { it.u = specs[it_index].dflt; it.s = cast,no_check(s64) specs[it_index].dflt; }
    expect(.LPAREN, "'(' here");
    if P.tok.kind != .RPAREN {
        while true {
            if P.tok.kind != .LABEL_STR perr("expected field label here");
            name := P.tok.text;
            found := -1;
            for specs if it.name == name { found = it_index; break; }
            if found < 0 perr("invalid field '%'", name);
            if vals[found].seen perr("field '%' cannot be specified more than once", name);
            next();
            parse_one_field(specs[found], *vals[found]);
            if !eat(.COMMA) break;
        }
    }
    expect(.RPAREN, "')' here");
    for specs if it.required && !vals[it_index].seen perr("missing required field '%'", it.name);
    return vals;
}

// ConstantAsMetadata::get(ConstantInt::get(i64, v)) for MD{Signed,Unsigned}OrMDField
md_i64 :: (v: u64) -> Md_Id { return md_value(const_int(ir.t_i64, v)); }
or_md_value :: (v: Field_Val) -> Md_Id {
    if !v.seen return NONE;
    if v.is_md return v.md;
    return md_i64(v.u);
}

// ---------------------------------------------------------------- LLParser::parseSpecializedMDNode

parse_specialized_md :: (distinct: bool) -> Md_Id {
    name := P.tok.text;
    k: DI_Kind;
    found := false;
    for DI_NAMES if it == name { k = cast(DI_Kind) it_index; found = true; break; }
    if !found || k == .ARG_LIST perr("specialized metadata (!%) is not supported yet", name);
    next();
    m := parse_di_node(k, distinct);
    md_register_uses(m);
    return m;
}

parse_di_node :: (k: DI_Kind, distinct: bool) -> Md_Id {
    U32 :: 0xFFFF_FFFF;
    if k == {
      case .LOCATION;
        v := parse_di_fields(.[.{"line", .UINT, false, 0, U32}, .{"column", .UINT, false, 0, 0xFFFF},
            .{"scope", .MD_NONNULL, true, 0, U64MAX}, .{"inlinedAt", .MD, false, 0, U64MAX}, .{"isImplicitCode", .BOOL, false, 0, U64MAX},
            .{"atomGroup", .UINT, false, 0, U64MAX}, .{"atomRank", .UINT, false, 0, 0xFF}]);
        col := v[1].u;
        if col >= (1 << 16) col = 0;   // adjustColumn
        return di_get(k, distinct, .[v[2].md, v[3].md], .[v[0].u, col, v[4].u, v[5].u, v[6].u]);
      case .ASSIGN_ID;
        if !distinct perr("missing 'distinct', required for !DIAssignID()");
        expect(.LPAREN, "'(' here"); expect(.RPAREN, "')' here");
        return di_get(k, true, .[], .[]);
      case .EXPRESSION;
        expect(.LPAREN, "'(' here");
        elts: [..] u64; elts.allocator = temp;
        if P.tok.kind != .RPAREN {
            while true {
                if P.tok.kind == .KW && begins_with(P.tok.text, "DW_OP_") {
                    ok, v := dwarf_lookup(DW_OP_NAMES, P.tok.text);
                    if !ok perr("invalid DWARF op '%'", P.tok.text);
                    array_add(*elts, v); next();
                } else if P.tok.kind == .KW && begins_with(P.tok.text, "DW_ATE_") {
                    ok, v := dwarf_lookup(DW_ATE_NAMES, P.tok.text);
                    if !ok perr("invalid DWARF attribute encoding '%'", P.tok.text);
                    array_add(*elts, v); next();
                } else {
                    if P.tok.kind != .APSINT perr("expected unsigned integer");
                    neg, u, s := apsint_tok_value();
                    if neg perr("expected unsigned integer");
                    array_add(*elts, u);
                }
                if !eat(.COMMA) break;
            }
        }
        expect(.RPAREN, "')' here");
        return di_get(k, distinct, .[], elts);
      case .GLOBAL_VARIABLE_EXPRESSION;
        v := parse_di_fields(.[.{"var", .MD, true, 0, U64MAX}, .{"expr", .MD, true, 0, U64MAX}]);
        return di_get(k, distinct, .[v[0].md, v[1].md], .[]);
      case .FILE;
        v := parse_di_fields(.[.{"filename", .STR, true, 0, U64MAX}, .{"directory", .STR, true, 0, U64MAX},
            .{"checksumkind", .CHECKSUM, false, 1, U64MAX}, .{"checksum", .STR, false, 0, U64MAX}, .{"source", .STR_EMPTY, false, 0, U64MAX}]);
        cs: u64 = 0;
        csm: Md_Id = NONE;
        if v[2].seen && v[3].seen { cs = v[2].u; csm = v[3].md; }
        else if v[2].seen || v[3].seen perr("'checksumkind' and 'checksum' must be provided together");
        src: Md_Id = NONE;
        if v[4].seen src = v[4].md;
        return di_get(k, distinct, .[v[0].md, v[1].md, csm, src], .[cs]);
      case .COMPILE_UNIT;
        if !distinct perr("missing 'distinct', required for !DICompileUnit");
        v := parse_di_fields(.[.{"file", .MD_NONNULL, true, 0, U64MAX}, .{"language", .LANG, false, 0, U64MAX},
            .{"sourceLanguageName", .LNAME, false, 0, U64MAX}, .{"sourceLanguageVersion", .UINT, false, 0, U32},
            .{"producer", .STR, false, 0, U64MAX}, .{"isOptimized", .BOOL, false, 0, U64MAX}, .{"flags", .STR, false, 0, U64MAX},
            .{"runtimeVersion", .UINT, false, 0, U32}, .{"splitDebugFilename", .STR, false, 0, U64MAX},
            .{"emissionKind", .EMISSION, false, 0, U64MAX}, .{"enums", .MD, false, 0, U64MAX}, .{"retainedTypes", .MD, false, 0, U64MAX},
            .{"globals", .MD, false, 0, U64MAX}, .{"imports", .MD, false, 0, U64MAX}, .{"macros", .MD, false, 0, U64MAX},
            .{"dwoId", .UINT, false, 0, U64MAX}, .{"splitDebugInlining", .BOOL, false, 1, U64MAX},
            .{"debugInfoForProfiling", .BOOL, false, 0, U64MAX}, .{"nameTableKind", .NAMETABLE, false, 0, U64MAX},
            .{"rangesBaseAddress", .BOOL, false, 0, U64MAX}, .{"sysroot", .STR, false, 0, U64MAX}, .{"sdk", .STR, false, 0, U64MAX},
            .{"dialect", .DIALECT, false, 0, U64MAX}]);
        if !v[1].seen && !v[2].seen perr("missing one of 'language' or 'sourceLanguageName', required for !DICompileUnit");
        if v[1].seen && v[2].seen perr("can only specify one of 'language' and 'sourceLanguageName' on !DICompileUnit");
        if v[3].seen && !v[2].seen perr("'sourceLanguageVersion' requires an associated 'sourceLanguageName' on !DICompileUnit");
        versioned: u64 = ifx v[2].seen then cast(u64) 1 else 0;
        lname := ifx v[1].seen then v[1].u else v[2].u;
        return di_get(k, true,
            .[v[0].md, v[4].md, v[6].md, v[8].md, v[10].md, v[11].md, v[12].md, v[13].md, v[14].md, v[20].md, v[21].md],
            .[lname, v[3].u, v[22].u, versioned, v[5].u, v[7].u, v[9].u, v[15].u, v[16].u, v[17].u, v[18].u, v[19].u]);
      case .SUBPROGRAM;
        v := parse_di_fields(.[.{"scope", .MD, false, 0, U64MAX}, .{"name", .STR, false, 0, U64MAX}, .{"linkageName", .STR, false, 0, U64MAX},
            .{"file", .MD, false, 0, U64MAX}, .{"line", .UINT, false, 0, U32}, .{"type", .MD_NONNULL, false, 0, U64MAX},
            .{"isLocal", .BOOL, false, 0, U64MAX}, .{"isDefinition", .BOOL, false, 1, U64MAX}, .{"scopeLine", .UINT, false, 0, U32},
            .{"containingType", .MD, false, 0, U64MAX}, .{"virtuality", .VIRT, false, 0, U64MAX},
            .{"virtualIndex", .UINT, false, 0, U32}, .{"thisAdjustment", .SINT, false, 0, U64MAX},
            .{"flags", .FLAGS, false, 0, U64MAX}, .{"spFlags", .SPFLAGS, false, 0, U64MAX}, .{"isOptimized", .BOOL, false, 0, U64MAX},
            .{"unit", .MD, false, 0, U64MAX}, .{"templateParams", .MD, false, 0, U64MAX}, .{"declaration", .MD, false, 0, U64MAX},
            .{"retainedNodes", .MD, false, 0, U64MAX}, .{"thrownTypes", .MD, false, 0, U64MAX}, .{"annotations", .MD, false, 0, U64MAX},
            .{"targetFuncName", .STR, false, 0, U64MAX}, .{"keyInstructions", .BOOL, false, 0, U64MAX}]);
        if !v[5].seen perr("missing required field 'type'");
        spflags := v[14].u;
        if !v[14].seen {
            // DISubprogram::toSPFlags(isLocal, isDefinition, isOptimized, virtuality)
            spflags = (v[10].u & 3);
            if v[6].u spflags |= SPFLAG_LOCAL_TO_UNIT;
            if v[7].u spflags |= SPFLAG_DEFINITION;
            if v[15].u spflags |= SPFLAG_OPTIMIZED;
        }
        if (spflags & SPFLAG_DEFINITION) && !distinct perr("missing 'distinct', required for !DISubprogram that is a Definition");
        m := di_get(k, distinct,
            .[v[3].md, v[0].md, v[1].md, v[2].md, v[5].md, v[16].md, v[18].md, v[19].md, v[9].md, v[17].md, v[20].md, v[21].md, v[22].md],
            .[v[4].u, v[8].u, v[11].u, v[12].u, v[13].u, spflags, v[23].u]);
        if distinct array_add(*new_distinct_sps, m);
        return m;
      case .SUBROUTINE_TYPE;
        v := parse_di_fields(.[.{"flags", .FLAGS, false, 0, U64MAX}, .{"cc", .CC, false, 0, U64MAX}, .{"types", .MD, true, 0, U64MAX}]);
        return di_get(k, distinct, .[NONE, NONE, NONE, NONE, NONE, v[2].md], .[v[0].u, v[1].u]);
      case .BASIC_TYPE;
        v := parse_di_fields(.[.{"tag", .TAG, false, DW_TAG_BASE_TYPE, U64MAX}, .{"name", .STR, false, 0, U64MAX}, .{"file", .MD, false, 0, U64MAX},
            .{"line", .UINT, false, 0, U32}, .{"scope", .MD, false, 0, U64MAX}, .{"size", .UNSIGNED_OR_MD, false, 0, U64MAX},
            .{"align", .UINT, false, 0, U32}, .{"dataSize", .UINT, false, 0, U32}, .{"encoding", .ATE, false, 0, U64MAX},
            .{"num_extra_inhabitants", .UINT, false, 0, U32}, .{"flags", .FLAGS, false, 0, U64MAX}]);
        return di_get(k, distinct, .[v[2].md, v[4].md, v[1].md, or_md_value(v[5]), NONE],
            .[v[0].u, v[3].u, v[6].u, v[8].u, v[9].u, v[7].u, v[10].u]);
      case .DERIVED_TYPE;
        v := parse_di_fields(.[.{"tag", .TAG, true, 0, U64MAX}, .{"name", .STR, false, 0, U64MAX}, .{"file", .MD, false, 0, U64MAX},
            .{"line", .UINT, false, 0, U32}, .{"scope", .MD, false, 0, U64MAX}, .{"baseType", .MD, true, 0, U64MAX},
            .{"size", .UNSIGNED_OR_MD, false, 0, U64MAX}, .{"align", .UINT, false, 0, U32}, .{"offset", .UNSIGNED_OR_MD, false, 0, U64MAX},
            .{"flags", .FLAGS, false, 0, U64MAX}, .{"extraData", .MD, false, 0, U64MAX}, .{"dwarfAddressSpace", .UINT, false, U32, U32},
            .{"annotations", .MD, false, 0, U64MAX}, .{"ptrAuthKey", .UINT, false, 0, 7},
            .{"ptrAuthIsAddressDiscriminated", .BOOL, false, 0, U64MAX}, .{"ptrAuthExtraDiscriminator", .UINT, false, 0, 0xffff},
            .{"ptrAuthIsaPointer", .BOOL, false, 0, U64MAX}, .{"ptrAuthAuthenticatesNullValues", .BOOL, false, 0, U64MAX}]);
        // dwarfAddressSpace UINT32_MAX = none; ptrauth data only if the key is nonzero
        pk, pa, pe, pi, pn: u64;
        if v[13].u { pk = v[13].u; pa = v[14].u; pe = v[15].u; pi = v[16].u; pn = v[17].u; }
        return di_get(k, distinct, .[v[2].md, v[4].md, v[1].md, or_md_value(v[6]), or_md_value(v[8]), v[5].md, v[10].md, v[12].md],
            .[v[0].u, v[3].u, v[7].u, v[11].u, v[9].u, pk, pa, pe, pi, pn]);
      case .COMPOSITE_TYPE;
        v := parse_di_fields(.[.{"tag", .TAG, true, 0, U64MAX}, .{"name", .STR, false, 0, U64MAX}, .{"file", .MD, false, 0, U64MAX},
            .{"line", .UINT, false, 0, U32}, .{"scope", .MD, false, 0, U64MAX}, .{"baseType", .MD, false, 0, U64MAX},
            .{"size", .UNSIGNED_OR_MD, false, 0, U64MAX}, .{"align", .UINT, false, 0, U32}, .{"offset", .UNSIGNED_OR_MD, false, 0, U64MAX},
            .{"flags", .FLAGS, false, 0, U64MAX}, .{"elements", .MD, false, 0, U64MAX}, .{"runtimeLang", .LANG, false, 0, U64MAX},
            .{"enumKind", .ENUM_KIND, false, U32, U64MAX}, .{"vtableHolder", .MD, false, 0, U64MAX}, .{"templateParams", .MD, false, 0, U64MAX},
            .{"identifier", .STR, false, 0, U64MAX}, .{"discriminator", .MD, false, 0, U64MAX}, .{"dataLocation", .MD, false, 0, U64MAX},
            .{"associated", .MD, false, 0, U64MAX}, .{"allocated", .MD, false, 0, U64MAX}, .{"rank", .SIGNED_OR_MD, false, 0, U64MAX},
            .{"annotations", .MD, false, 0, U64MAX}, .{"num_extra_inhabitants", .UINT, false, 0, U32},
            .{"specification", .MD, false, 0, U64MAX}, .{"bitStride", .MD, false, 0, U64MAX}]);
        rank: Md_Id = NONE;
        if v[20].seen { if v[20].is_md rank = v[20].md; else rank = md_i64(v[20].u); }
        ops := Md_Id.[v[2].md, v[4].md, v[1].md, or_md_value(v[6]), or_md_value(v[8]), v[5].md, v[10].md, v[13].md, v[14].md,
              v[15].md, v[16].md, v[17].md, v[18].md, v[19].md, rank, v[21].md, v[23].md, v[24].md];
        ints := u64.[v[0].u, v[3].u, v[11].u, v[7].u, v[22].u, v[12].u, v[9].u];
        if v[15].md != NONE && odr_uniquing_debug_types {
            // DICompositeType::buildODRType: opt enables ODR uniquing of debug types (LLVMContext DITypeMap) unless
            // --disable-debug-info-type-map
            found, ct := table_find(*odr_types, v[15].str);
            if !found {
                ct = di_get(k, true, ops, ints);
                table_add(*odr_types, copy_string(v[15].str), ct);
                return ct;
            }
            if di_int(ct, 0) == v[0].u {
                FLAG_FWD_DECL :: 4;
                if !(di_int(ct, 6) & FLAG_FWD_DECL) || (v[9].u & FLAG_FWD_DECL) return ct;
                // mutate the forward declaration in place
                for ints ir.md_ints[ir.mds[ct].ints + cast(u32) it_index] = it;
                for o, oi: ops {
                    ir.md_ops[ir.mds[ct].ops + cast(u32) oi] = o;
                    md_add_use(o, ct, cast(u32) oi);
                }
                return ct;
            }
        }
        return di_get(k, distinct, ops, ints);
      case .LOCAL_VARIABLE;
        v := parse_di_fields(.[.{"scope", .MD_NONNULL, true, 0, U64MAX}, .{"name", .STR, false, 0, U64MAX}, .{"arg", .UINT, false, 0, 0xffff},
            .{"file", .MD, false, 0, U64MAX}, .{"line", .UINT, false, 0, U32}, .{"type", .MD, false, 0, U64MAX},
            .{"flags", .FLAGS, false, 0, U64MAX}, .{"align", .UINT, false, 0, U32}, .{"annotations", .MD, false, 0, U64MAX}]);
        return di_get(k, distinct, .[v[0].md, v[1].md, v[3].md, v[5].md, v[8].md], .[v[4].u, v[2].u, v[6].u, v[7].u]);
      case .GLOBAL_VARIABLE;
        v := parse_di_fields(.[.{"name", .STR_NONEMPTY, false, 0, U64MAX}, .{"scope", .MD, false, 0, U64MAX}, .{"linkageName", .STR, false, 0, U64MAX},
            .{"file", .MD, false, 0, U64MAX}, .{"line", .UINT, false, 0, U32}, .{"type", .MD, false, 0, U64MAX},
            .{"isLocal", .BOOL, false, 0, U64MAX}, .{"isDefinition", .BOOL, false, 1, U64MAX}, .{"templateParams", .MD, false, 0, U64MAX},
            .{"declaration", .MD, false, 0, U64MAX}, .{"align", .UINT, false, 0, U32}, .{"annotations", .MD, false, 0, U64MAX}]);
        return di_get(k, distinct, .[v[1].md, v[0].md, v[3].md, v[5].md, v[0].md, v[2].md, v[9].md, v[8].md, v[11].md],
            .[v[4].u, v[6].u, v[7].u, v[10].u]);
      case .LEXICAL_BLOCK;
        v := parse_di_fields(.[.{"scope", .MD_NONNULL, true, 0, U64MAX}, .{"file", .MD, false, 0, U64MAX}, .{"line", .UINT, false, 0, U32},
            .{"column", .UINT, false, 0, 0xFFFF}]);
        col := v[3].u;
        if col >= (1 << 16) col = 0;
        return di_get(k, distinct, .[v[1].md, v[0].md], .[v[2].u, col]);
      case .LEXICAL_BLOCK_FILE;
        v := parse_di_fields(.[.{"scope", .MD_NONNULL, true, 0, U64MAX}, .{"file", .MD, false, 0, U64MAX}, .{"discriminator", .UINT, true, 0, U32}]);
        return di_get(k, distinct, .[v[1].md, v[0].md], .[v[2].u]);
      case .NAMESPACE;
        v := parse_di_fields(.[.{"scope", .MD, true, 0, U64MAX}, .{"name", .STR, false, 0, U64MAX}, .{"exportSymbols", .BOOL, false, 0, U64MAX}]);
        return di_get(k, distinct, .[NONE, v[0].md, v[1].md], .[v[2].u]);
      case .SUBRANGE;
        v := parse_di_fields(.[.{"count", .SIGNED_OR_MD, false, 0, U64MAX}, .{"lowerBound", .SIGNED_OR_MD, false, 0, U64MAX},
            .{"upperBound", .SIGNED_OR_MD, false, 0, U64MAX}, .{"stride", .SIGNED_OR_MD, false, 0, U64MAX}]);
        return di_get(k, distinct, .[or_md_value(v[0]), or_md_value(v[1]), or_md_value(v[2]), or_md_value(v[3])], .[]);
      case .LABEL;
        v := parse_di_fields(.[.{"scope", .MD_NONNULL, true, 0, U64MAX}, .{"name", .STR, true, 0, U64MAX}, .{"file", .MD, true, 0, U64MAX},
            .{"line", .UINT, true, 0, U32}, .{"column", .UINT, false, 0, 0xFFFF}, .{"isArtificial", .BOOL, false, 0, U64MAX},
            .{"coroSuspendIdx", .UINT, false, 0, U64MAX}]);
        has_idx: u64 = ifx v[6].seen then cast(u64) 1 else 0;
        return di_get(k, distinct, .[v[0].md, v[1].md, v[2].md], .[v[3].u, v[4].u, v[5].u, has_idx, v[6].u]);
      case .IMPORTED_ENTITY;
        v := parse_di_fields(.[.{"tag", .TAG, true, 0, U64MAX}, .{"scope", .MD, true, 0, U64MAX}, .{"entity", .MD, false, 0, U64MAX},
            .{"file", .MD, false, 0, U64MAX}, .{"line", .UINT, false, 0, U32}, .{"name", .STR, false, 0, U64MAX}, .{"elements", .MD, false, 0, U64MAX}]);
        return di_get(k, distinct, .[v[1].md, v[2].md, v[5].md, v[3].md, v[6].md], .[v[0].u, v[4].u]);
      case .TEMPLATE_TYPE_PARAMETER;
        v := parse_di_fields(.[.{"name", .STR, false, 0, U64MAX}, .{"type", .MD, true, 0, U64MAX}, .{"defaulted", .BOOL, false, 0, U64MAX}]);
        return di_get(k, distinct, .[v[0].md, v[1].md], .[v[2].u]);
      case .TEMPLATE_VALUE_PARAMETER;
        v := parse_di_fields(.[.{"tag", .TAG, false, DW_TAG_TEMPLATE_VALUE_PARAMETER, U64MAX}, .{"name", .STR, false, 0, U64MAX},
            .{"type", .MD, false, 0, U64MAX}, .{"defaulted", .BOOL, false, 0, U64MAX}, .{"value", .MD, true, 0, U64MAX}]);
        return di_get(k, distinct, .[v[1].md, v[2].md, v[4].md], .[v[0].u, v[3].u]);
      case .ENUMERATOR;
        // ints: value (two's complement, 64 bits), isUnsigned, value is negative. LLVM keeps an APSInt whose width
        // follows from the literal (APSInt(StringRef)), so (value, negative) determines it; wider values fail loudly.
        v := parse_di_fields(.[.{"name", .STR, true, 0, U64MAX}, .{"value", .APSINT, true, 0, U64MAX}, .{"isUnsigned", .BOOL, false, 0, U64MAX}]);
        if v[2].u && v[1].neg perr("unsigned enumerator with negative value");
        bits := ifx v[1].neg then cast,no_check(u64) v[1].s else v[1].u;
        neg: u64 = ifx v[1].neg && v[1].s < 0 then cast(u64) 1 else 0;
        return di_get(k, distinct, .[v[0].md], .[bits, v[2].u, neg]);
      case .GENERIC_SUBRANGE;
        v := parse_di_fields(.[.{"count", .SIGNED_OR_MD, false, 0, U64MAX}, .{"lowerBound", .SIGNED_OR_MD, false, 0, U64MAX},
            .{"upperBound", .SIGNED_OR_MD, false, 0, U64MAX}, .{"stride", .SIGNED_OR_MD, false, 0, U64MAX}]);
        // a signed constant becomes !DIExpression(DW_OP_consts, C)
        conv :: (f: Field_Val) -> Md_Id {
            if !f.seen return NONE;
            if f.is_md return f.md;
            return di_get(.EXPRESSION, false, .[], .[DW_OP_CONSTS, f.u]);
        }
        return di_get(k, distinct, .[conv(v[0]), conv(v[1]), conv(v[2]), conv(v[3])], .[]);
      case .MODULE;
        v := parse_di_fields(.[.{"scope", .MD, true, 0, U64MAX}, .{"name", .STR, true, 0, U64MAX}, .{"configMacros", .STR, false, 0, U64MAX},
            .{"includePath", .STR, false, 0, U64MAX}, .{"apinotes", .STR, false, 0, U64MAX}, .{"file", .MD, false, 0, U64MAX},
            .{"line", .UINT, false, 0, U32}, .{"isDecl", .BOOL, false, 0, U64MAX}]);
        return di_get(k, distinct, .[v[5].md, v[0].md, v[1].md, v[2].md, v[3].md, v[4].md], .[v[6].u, v[7].u]);
      case .MACRO;
        v := parse_di_fields(.[.{"type", .MACINFO, true, 0, U64MAX}, .{"line", .UINT, false, 0, U32}, .{"name", .STR, true, 0, U64MAX},
            .{"value", .STR, false, 0, U64MAX}]);
        return di_get(k, distinct, .[v[2].md, v[3].md], .[v[0].u, v[1].u]);
      case .MACRO_FILE;
        v := parse_di_fields(.[.{"type", .MACINFO, false, DW_MACINFO_START_FILE, U64MAX}, .{"line", .UINT, false, 0, U32},
            .{"file", .MD, true, 0, U64MAX}, .{"nodes", .MD, false, 0, U64MAX}]);
        return di_get(k, distinct, .[v[2].md, v[3].md], .[v[0].u, v[1].u]);
      case .COMMON_BLOCK;
        v := parse_di_fields(.[.{"scope", .MD, true, 0, U64MAX}, .{"declaration", .MD, false, 0, U64MAX}, .{"name", .STR, false, 0, U64MAX},
            .{"file", .MD, false, 0, U64MAX}, .{"line", .UINT, false, 0, U32}]);
        return di_get(k, distinct, .[v[0].md, v[1].md, v[2].md, v[3].md], .[v[4].u]);
      case .OBJC_PROPERTY;
        v := parse_di_fields(.[.{"name", .STR, false, 0, U64MAX}, .{"file", .MD, false, 0, U64MAX}, .{"line", .UINT, false, 0, U32},
            .{"setter", .STR, false, 0, U64MAX}, .{"getter", .STR, false, 0, U64MAX}, .{"attributes", .UINT, false, 0, U32},
            .{"type", .MD, false, 0, U64MAX}]);
        return di_get(k, distinct, .[v[0].md, v[1].md, v[4].md, v[3].md, v[6].md], .[v[2].u, v[5].u]);
      case .STRING_TYPE;
        // DIType layout (file, scope, name, size, offset) + stringLength, stringLengthExpression, stringLocationExpression
        v := parse_di_fields(.[.{"tag", .TAG, false, DW_TAG_STRING_TYPE, U64MAX}, .{"name", .STR, false, 0, U64MAX},
            .{"stringLength", .MD, false, 0, U64MAX}, .{"stringLengthExpression", .MD, false, 0, U64MAX},
            .{"stringLocationExpression", .MD, false, 0, U64MAX}, .{"size", .UNSIGNED_OR_MD, false, 0, U64MAX},
            .{"align", .UINT, false, 0, U32}, .{"encoding", .ATE, false, 0, U64MAX}]);
        return di_get(k, distinct, .[NONE, NONE, v[1].md, or_md_value(v[5]), NONE, v[2].md, v[3].md, v[4].md], .[v[0].u, v[6].u, v[7].u]);
      case .SUBRANGE_TYPE;
        // ints: tag (always DW_TAG_subrange_type), line, align, flags
        v := parse_di_fields(.[.{"name", .STR, false, 0, U64MAX}, .{"file", .MD, false, 0, U64MAX}, .{"line", .UINT, false, 0, U32},
            .{"scope", .MD, false, 0, U64MAX}, .{"baseType", .MD, false, 0, U64MAX}, .{"size", .UNSIGNED_OR_MD, false, 0, U64MAX},
            .{"align", .UINT, false, 0, U32}, .{"flags", .FLAGS, false, 0, U64MAX}, .{"lowerBound", .SIGNED_OR_MD, false, 0, U64MAX},
            .{"upperBound", .SIGNED_OR_MD, false, 0, U64MAX}, .{"stride", .SIGNED_OR_MD, false, 0, U64MAX}, .{"bias", .SIGNED_OR_MD, false, 0, U64MAX}]);
        return di_get(k, distinct, .[v[1].md, v[3].md, v[0].md, or_md_value(v[5]), NONE, v[4].md, or_md_value(v[8]), or_md_value(v[9]),
            or_md_value(v[10]), or_md_value(v[11])], .[VDW_TAG_SUBRANGE_TYPE, v[2].u, v[6].u, v[7].u]);
      case .FIXED_POINT_TYPE;
        // ints: tag, line, align, encoding, flags, kind, factor, numerator, numerator < 0, denominator, denominator < 0
        // (numerator/denominator: APInts of the literal's width in LLVM; wider than 64 bits fails loudly)
        v := parse_di_fields(.[.{"tag", .TAG, false, DW_TAG_BASE_TYPE, U64MAX}, .{"name", .STR, false, 0, U64MAX}, .{"file", .MD, false, 0, U64MAX},
            .{"line", .UINT, false, 0, U32}, .{"scope", .MD, false, 0, U64MAX}, .{"size", .UNSIGNED_OR_MD, false, 0, U64MAX},
            .{"align", .UINT, false, 0, U32}, .{"encoding", .ATE, false, 0, U64MAX}, .{"flags", .FLAGS, false, 0, U64MAX},
            .{"kind", .FIXED_POINT_KIND, false, 0, U64MAX}, .{"factor", .SINT, false, 0, U64MAX}, .{"numerator", .APSINT, false, 0, U64MAX},
            .{"denominator", .APSINT, false, 0, U64MAX}]);
        nb := ifx v[11].neg then cast,no_check(u64) v[11].s else v[11].u;
        db := ifx v[12].neg then cast,no_check(u64) v[12].s else v[12].u;
        nn: u64 = ifx v[11].neg && v[11].s < 0 then cast(u64) 1 else 0;
        dn: u64 = ifx v[12].neg && v[12].s < 0 then cast(u64) 1 else 0;
        return di_get(k, distinct, .[v[2].md, v[4].md, v[1].md, or_md_value(v[5]), NONE],
            .[v[0].u, v[3].u, v[6].u, v[7].u, v[8].u, v[9].u, v[10].u, nb, nn, db, dn]);
      case .GENERIC_DINODE;
        // ops: header, then the DWARF operands; ints: tag
        v := parse_di_fields(.[.{"tag", .TAG, true, 0, U64MAX}, .{"header", .STR, false, 0, U64MAX}, .{"operands", .MD_LIST, false, 0, U64MAX}]);
        ops: [..] Md_Id; ops.allocator = temp;
        array_add(*ops, v[1].md);
        for v[2].list array_add(*ops, it);
        return di_get(k, distinct, ops, .[v[0].u]);
    }
    perr("specialized metadata (!%) is not supported yet", DI_NAMES[k]);
    return NONE;
}

DW_TAG_BASE_TYPE :: 0x24;
DW_TAG_TEMPLATE_VALUE_PARAMETER :: 0x30;
DW_TAG_STRING_TYPE :: 0x12; DW_MACINFO_START_FILE :: 3; DW_ATE_SIGNED_FIXED :: 0x0d;

// APInt::print of an APSInt(StringRef) literal: its width is the active bits (non-negative) or the significant bits
// (negative) of the value, at least 1; `bits` is the 64-bit two's complement value
print_literal_apint :: (bits: u64, neg: bool, signed_print: bool) {
    w: s64 = 1;
    if neg { x := ~bits; for b: 0..63 if (x >> cast(u64) b) & 1 w = b + 2; }
    else { for b: 0..63 if (bits >> cast(u64) b) & 1 w = b + 1; }
    if w >= 64 { if signed_print out_s64(cast,no_check(s64) bits); else out_u64(bits); return; }
    mask := (cast(u64) 1 << cast(u64) w) - 1;
    v := bits & mask;
    if signed_print && (v >> cast(u64) (w - 1)) & 1 { out_s64(cast,no_check(s64) (v | ~mask)); return; }
    out_u64(v);
}
DW_TAG_LLVM_PTRAUTH_TYPE :: 0x4300;
SPFLAG_LOCAL_TO_UNIT :: 4; SPFLAG_DEFINITION :: 8; SPFLAG_OPTIMIZED :: 16;

new_distinct_sps: [..] Md_Id;
odr_uniquing_debug_types := true;   // LLVMContext::isODRUniquingDebugTypes (opt: enableDebugTypeODRUniquing)
odr_types: Table(string, Md_Id);

// LLParser::parseDIArgList (inside a function): !DIArgList(i32 7, i64 %0)
parse_di_arg_list :: () -> Md_Id {
    next();
    expect(.LPAREN, "'(' here");
    args: [..] Md_Id; args.allocator = temp;
    if P.tok.kind != .RPAREN {
        while true {
            ty := parse_type();
            if ty == ir.t_metadata perr("expected value-as-metadata operand");
            array_add(*args, md_value(parse_value(ty)));
            if !eat(.COMMA) break;
        }
    }
    expect(.RPAREN, "')' here");
    return di_get(.ARG_LIST, false, args, .[]);
}

// ---------------------------------------------------------------- debug records

Dbg_Record_Kind :: enum u8 { VALUE; DECLARE; ASSIGN; DECLARE_VALUE; LABEL; }

Dbg_Record :: struct {
    kind:      Dbg_Record_Kind;
    loc:       Md_Id = NONE;   // value location (ValueAsMetadata, DIArgList or an MDNode) / label for LABEL
    var:       Md_Id = NONE;
    expr:      Md_Id = NONE;
    assign_id: Md_Id = NONE;
    addr:      Md_Id = NONE;
    addr_expr: Md_Id = NONE;
    dbg:       Md_Id = NONE;   // DILocation
    next:      u32;            // 1 + index of the next record before the same instruction, 0 = end
    owner:     Value_Id = NONE; // the instruction the record is attached to (NONE = erased / not attached)
}

// LLParser::parseMetadata with a function state: also DIArgList and local ValueAsMetadata
parse_record_metadata :: () -> Md_Id {
    if P.tok.kind == .METADATA_VAR {
        if P.tok.text == "DIArgList" return parse_di_arg_list();
        return parse_specialized_md(false);
    }
    return parse_metadata_operand();
}

// LLParser::parseMDNode: !N, !{...} or a specialized node
parse_md_node :: () -> Md_Id {
    if P.tok.kind == .METADATA_VAR return parse_specialized_md(false);
    return parse_md_node_ref();
}

// LLParser::parseDebugRecord (after '#'); returns 1 + record index
parse_debug_record :: () -> u32 {
    if P.tok.kind != .KW || !begins_with(P.tok.text, "dbg_") perr("expected debug record type here");
    t := slice(P.tok.text, 4, P.tok.text.count - 4);
    r: Dbg_Record;
    if t == "value" r.kind = .VALUE;
    else if t == "declare" r.kind = .DECLARE;
    else if t == "assign" r.kind = .ASSIGN;
    else if t == "declare_value" r.kind = .DECLARE_VALUE;
    else if t == "label" r.kind = .LABEL;
    else perr("expected debug record type here");
    next();
    expect(.LPAREN, "'(' here");
    if r.kind == .LABEL {
        r.loc = parse_md_node();
        expect(.COMMA, "',' here");
        r.dbg = parse_md_node();
    } else {
        r.loc = parse_record_metadata(); expect(.COMMA, "',' here");
        r.var = parse_md_node(); expect(.COMMA, "',' here");
        r.expr = parse_md_node(); expect(.COMMA, "',' here");
        if r.kind == .ASSIGN {
            r.assign_id = parse_md_node(); expect(.COMMA, "',' here");
            r.addr = parse_record_metadata(); expect(.COMMA, "',' here");
            r.addr_expr = parse_md_node(); expect(.COMMA, "',' here");
        }
        r.dbg = parse_md_node();
    }
    expect(.RPAREN, "')' here");
    array_add(*ir.dbg_records, r);
    return cast(u32) ir.dbg_records.count;
}

// BasicBlock::insertDbgRecordBefore: append records (a chain) after the instruction's existing ones
attach_records_before :: (i: Value_Id, first: u32) {
    if first == 0 return;
    y := first;
    while y != 0 { ir.dbg_records[y - 1].owner = i; y = ir.dbg_records[y - 1].next; }
    r := inst(i);
    if r.records == 0 { r.records = first; return; }
    x := r.records;
    while ir.dbg_records[x - 1].next != 0 x = ir.dbg_records[x - 1].next;
    ir.dbg_records[x - 1].next = first;
}

resolve_record_metadata :: () {
    for * ir.dbg_records {
        it.loc = md_final_of(it.loc); it.var = md_final_of(it.var); it.expr = md_final_of(it.expr);
        it.assign_id = md_final_of(it.assign_id); it.addr = md_final_of(it.addr);
        it.addr_expr = md_final_of(it.addr_expr); it.dbg = md_final_of(it.dbg);
        if it.dbg != NONE && !is_di(it.dbg, .LOCATION) perr("invalid debug location");
    }
}

// ---------------------------------------------------------------- upgrades

// DISubprogram::cleanupRetainedNodes for the distinct subprograms the parser created
cleanup_retained_nodes :: () {
    for sp0: new_distinct_sps {
        sp := md_final_of(sp0);
        if !is_di(sp, .SUBPROGRAM) continue;
        rn := di_op(sp, 7);
        if rn == NONE || ir.mds[rn].kind != .TUPLE continue;
        kept: [..] Md_Id; kept.allocator = temp;
        for i: 0..cast(s64) ir.mds[rn].nops - 1 {
            n := md_op(rn, cast(u32) i);
            if di_is_type(n) {
                tsp := di_local_scope_subprogram(di_op(n, 1));
                if tsp != sp continue;
            }
            array_add(*kept, n);
        }
        nt := md_tuple(kept, false);
        if nt != rn ir.md_ops[ir.mds[sp].ops + 7] = nt;
    }
    new_distinct_sps.count = 0;
}

di_is_type :: (m: Md_Id) -> bool {
    if m == NONE || ir.mds[m].kind != .SPECIAL return false;
    k := di_kind(m);
    return k == .BASIC_TYPE || k == .DERIVED_TYPE || k == .COMPOSITE_TYPE || k == .SUBROUTINE_TYPE || k == .STRING_TYPE ||
        k == .SUBRANGE_TYPE || k == .FIXED_POINT_TYPE;
}
// DILocalScope::getSubprogram (NONE if the scope is not a local scope)
di_local_scope_subprogram :: (s: Md_Id) -> Md_Id {
    x := s;
    while x != NONE && ir.mds[x].kind == .SPECIAL {
        k := di_kind(x);
        if k == .SUBPROGRAM return x;
        if k == .LEXICAL_BLOCK || k == .LEXICAL_BLOCK_FILE { x = di_op(x, 1); continue; }
        return NONE;
    }
    return NONE;
}

// unwrapMAVOp / unwrapMAVMetadataOp: the metadata of a `metadata` call argument
call_md_arg :: (ci: Value_Id, i: u32) -> Md_Id {
    v := op(ci, i);
    if vkind(v) != .MD_VALUE return NONE;
    return ir.v_aux[v];
}

// unwrapMAVOp: the metadata of a `metadata` argument if it is an MDNode (NONE otherwise: a broken record that the
// verifier reports)
call_md_node_arg :: (ci: Value_Id, i: u32) -> Md_Id {
    if i >= call_nargs(ci) return NONE;
    m := call_md_arg(ci, i);
    if !is_md_node(m) return NONE;
    return m;
}

// upgradeDbgIntrinsicToDbgRecord (locations and addresses: unwrapMAVMetadataOp, the rest: unwrapMAVOp)
upgrade_dbg_intrinsic_to_record :: (name: string, ci: Value_Id) {
    r: Dbg_Record;
    if name == "label" { r.kind = .LABEL; r.loc = call_md_node_arg(ci, 0); }
    else if name == "assign" {
        r.kind = .ASSIGN; r.loc = call_md_arg(ci, 0); r.var = call_md_node_arg(ci, 1); r.expr = call_md_node_arg(ci, 2);
        r.assign_id = call_md_node_arg(ci, 3); r.addr = call_md_arg(ci, 4); r.addr_expr = call_md_node_arg(ci, 5);
    } else if name == "declare" {
        r.kind = .DECLARE; r.loc = call_md_arg(ci, 0); r.var = call_md_node_arg(ci, 1); r.expr = call_md_node_arg(ci, 2);
    } else if name == "addr" {
        fatal("upgrade of llvm.dbg.addr is not supported yet");
    } else if name == "value" {
        var_op: u32 = 1; expr_op: u32 = 2;
        if call_nargs(ci) == 4 {
            off := op(ci, 1);
            if !(is_constant_kind(vkind(off)) && is_null_value(off)) return;
            var_op = 2; expr_op = 3;
        }
        r.kind = .VALUE; r.loc = call_md_arg(ci, 0); r.var = call_md_node_arg(ci, var_op); r.expr = call_md_node_arg(ci, expr_op);
    } else fatal("internal: unknown debug intrinsic llvm.dbg.%", name);
    r.dbg = get_metadata(ci, 0);
    array_add(*ir.dbg_records, r);
    attach_records_before(ci, cast(u32) ir.dbg_records.count);
}

// llvm::UpgradeDebugInfo: without "Debug Info Version" 3 the module's debug info is stripped. With version 3 the
// module is verified (verifier.jai): a module that is broken beyond its debug info is a fatal error; broken debug
// info is reported, then stripped with a warning.
upgrade_debug_info :: () {
    version: u64 = 0;
    for nm: ir.named_md {
        if nm.name != "llvm.module.flags" continue;
        for f: nm.ops {
            if f == NONE || ir.mds[f].kind != .TUPLE || ir.mds[f].nops < 3 continue;
            idm := md_op(f, 1);
            if idm == NONE || ir.mds[idm].kind != .STRING || ir.mds[idm].str != "Debug Info Version" continue;
            vm := md_op(f, 2);
            if vm != NONE && ir.mds[vm].kind == .VALUE && vkind(ir.mds[vm].value) == .C_INT version = const_int_zext(ir.mds[vm].value);
            break;
        }
    }
    if version == 3 {
        broken, broken_di := verify_module(want_broken_di = true);
        if broken verifier_fatal("Broken module found, compilation aborted!");
        if !broken_di return;
        // DiagnosticInfoIgnoringInvalidDebugMetadata
        print("warning: ignoring invalid debug info in %\n", P.lx.file, to_standard_error = true);
        strip_debug_info();
        return;
    }
    // DiagnosticInfoDebugMetadataVersion when StripDebugInfo changed something
    if strip_debug_info() print("warning: ignoring debug info with an invalid version (%) in %\n", version, P.lx.file, to_standard_error = true);
}

// llvm::StripDebugInfo(Module &)
strip_debug_info :: () -> bool {
    changed := false;
    i := 0;
    while i < ir.named_md.count {
        n := ir.named_md[i].name;
        if begins_with(n, "llvm.dbg.") || n == "llvm.gcov" { array_ordered_remove_by_index(*ir.named_md, i); changed = true; continue; }
        i += 1;
    }
    dbg := cast(u32) 0;
    loop_kind := md_kind_id("llvm.loop");
    heap := md_kind_id("heapallocsite");
    assign := md_kind_id("DIAssignID");
    loop_map: Table(Md_Id, Md_Id); loop_map.allocator = temp;
    for f: ir.m_functions {
        if get_metadata(f, dbg) != NONE changed = true;
        set_metadata(f, dbg, NONE);
        b := glob(f).first_block;
        while b != NONE {
            x := block(b).first;
            while x != NONE {
                // dropping debug records or !DIAssignID does not count as a change (stripDebugInfo(Function &))
                if get_metadata(x, dbg) != NONE changed = true;
                set_metadata(x, dbg, NONE);
                lid := get_metadata(x, loop_kind);
                if lid != NONE {
                    found, nl := table_find(*loop_map, lid);
                    if !found { nl = strip_debug_loc_from_loop_id(lid); table_add(*loop_map, lid, nl); }
                    if nl != lid set_metadata(x, loop_kind, nl);   // not counted as a change either
                }
                set_metadata(x, heap, NONE);
                set_metadata(x, assign, NONE);
                inst(x).records = 0;
                x = inst(x).next;
            }
            b = block(b).next;
        }
    }
    for g: ir.m_globals { if get_metadata(g, dbg) != NONE changed = true; set_metadata(g, dbg, NONE); }
    if changed print_state.dirty = true;   // the slot tracker numbers metadata afresh
    return changed;
}

// stripDebugLocFromLoopID: drop DILocation operands (and nodes that only contain them) from a loop ID
strip_debug_loc_from_loop_id :: (n: Md_Id) -> Md_Id {
    if ir.mds[n].kind != .TUPLE || ir.mds[n].nops == 0 return n;
    has_selfref := md_op(n, 0) == n;
    has_loc := false;
    nn := ir.mds[n].nops;
    for i: 1..cast(s64) nn - 1 if is_di(md_op(n, cast(u32) i), .LOCATION) { has_loc = true; break; }
    if !has_loc fatal_if_nested_locations(n);
    if !has_selfref || !has_loc return n;
    kept: [..] Md_Id; kept.allocator = temp;
    array_add(*kept, NONE);   // placeholder for the self reference
    for i: 1..cast(s64) nn - 1 {
        o := md_op(n, cast(u32) i);
        if is_di(o, .LOCATION) continue;
        array_add(*kept, o);
    }
    if kept.count == 1 return NONE;
    nl := md_tuple(kept, true);
    ir.md_ops[ir.mds[nl].ops] = nl;
    return nl;
}
fatal_if_nested_locations :: (n: Md_Id) {
    // stripDebugLocFromLoopID also drops nested nodes whose operands are all DILocations; not ported
    for i: 1..cast(s64) ir.mds[n].nops - 1 {
        o := md_op(n, cast(u32) i);
        if o != NONE && ir.mds[o].kind == .TUPLE {
            for j: 0..cast(s64) ir.mds[o].nops - 1 if is_di(md_op(o, cast(u32) j), .LOCATION)
                fatal("stripping DILocations nested in loop metadata is not supported yet");
        }
    }
}

// ---------------------------------------------------------------- printing (AsmWriter writeDI*)

FP :: struct { first: bool = true; }
fp_sep :: (p: *FP) { if !p.first out(", "); p.first = false; }

pf_string :: (p: *FP, name: string, s: string, skip_empty := true) {
    if skip_empty && s.count == 0 return;
    fp_sep(p); out(name); out(": \""); print_escaped_string(s); outc(#char "\"");
}
pf_md :: (p: *FP, name: string, m: Md_Id, skip_null := true) {
    if skip_null && m == NONE return;
    fp_sep(p); out(name); out(": ");
    write_md_as_operand(m);
}
pf_uint :: (p: *FP, name: string, v: u64, skip_zero := true) {
    if skip_zero && v == 0 return;
    fp_sep(p); out(name); out(": "); out_u64(v);
}
pf_sint :: (p: *FP, name: string, v: s64, skip_zero := true) {
    if skip_zero && v == 0 return;
    fp_sep(p); out(name); out(": "); out_s64(v);
}
pf_bool :: (p: *FP, name: string, v: bool, has_default := false, dflt := false) {
    if has_default && v == dflt return;
    fp_sep(p); out(name); out(": "); out(ifx v then "true" else "false");
}
pf_md_or_int :: (p: *FP, name: string, m: Md_Id, unsigned: bool, skip_zero := true) {
    if m == NONE return;
    if ir.mds[m].kind == .VALUE && vkind(ir.mds[m].value) == .C_INT {
        c := ir.mds[m].value;
        if unsigned pf_uint(p, name, const_int_zext(c), skip_zero);
        else pf_sint(p, name, const_int_sext(c), skip_zero);
        return;
    }
    pf_md(p, name, m);
}
pf_dwarf :: (p: *FP, name: string, v: u64, tab: [] Dwarf_Name, skip_zero := true) {
    if skip_zero && v == 0 return;
    fp_sep(p); out(name); out(": ");
    s := dwarf_name(tab, v);
    if s.count out(s); else out_u64(v);
}
pf_tag :: (p: *FP, tag: u64) {
    fp_sep(p); out("tag: ");
    s := dwarf_name(DW_TAG_NAMES, tag);
    if s.count out(s); else out_u64(tag);
}
pf_di_flags :: (p: *FP, name: string, flags_in: u64) {
    if flags_in == 0 return;
    fp_sep(p); out(name); out(": ");
    flags := flags_in;
    split: [..] u64; split.allocator = temp;
    // DINode::splitFlags
    acc := flags & 3;
    if acc { array_add(*split, ifx acc == 1 then cast(u64) 1 else ifx acc == 2 then cast(u64) 2 else 3); flags &= ~acc; }
    rep := flags & (3 << 16);
    if rep { array_add(*split, rep); flags &= ~rep; }
    ivb: u64 = (1 << 2) | (1 << 5);
    if (flags & ivb) == ivb { flags &= ~ivb; array_add(*split, ivb); }
    for DI_FLAG_NAMES {
        bit := flags & it.value;
        if bit { array_add(*split, bit); flags &= ~bit; }
    }
    first := true;
    for split {
        if !first out(" | "); first = false;
        out(dwarf_name(DI_FLAG_NAMES, it));
    }
    if flags != 0 || split.count == 0 { if !first out(" | "); out_u64(flags); }
}
pf_sp_flags :: (p: *FP, name: string, flags_in: u64) {
    fp_sep(p); out(name); out(": ");
    if flags_in == 0 { out("0"); return; }
    flags := flags_in;
    first := true;
    for DISP_FLAG_NAMES {
        bit := flags & it.value;
        if bit {
            if !first out(" | "); first = false;
            out(dwarf_name(DISP_FLAG_NAMES, bit));
            flags &= ~bit;
        }
    }
    if flags != 0 || first { if !first out(" | "); out_u64(flags); }
}

// writeMetadataAsOperand / writeAsOperandInternal(Metadata)
write_md_as_operand :: (m: Md_Id) {
    if m == NONE { out("null"); return; }
    r := ir.mds[m];
    if r.kind == .SPECIAL && (r.sub == cast(u8) DI_Kind.EXPRESSION || r.sub == cast(u8) DI_Kind.ARG_LIST) {
        write_di_node(m);
        return;
    }
    if r.kind == .VALUE { write_operand(r.value, true); return; }
    write_md_operand(m, false);
}

write_di_node :: (m: Md_Id) {
    k := di_kind(m);
    outc(#char "!"); out(DI_NAMES[k]); outc(#char "(");
    p: FP;
    I :: (i: u32) -> u64 #expand { return di_int(`m, i); }
    O :: (i: u32) -> Md_Id #expand { return di_op(`m, i); }
    S :: (i: u32) -> string #expand { return md_str_of(di_op(`m, i)); }
    if k == {
      case .LOCATION;
        pf_uint(*p, "line", I(0), false);
        pf_uint(*p, "column", I(1));
        pf_md(*p, "scope", O(0), false);
        pf_md(*p, "inlinedAt", O(1));
        pf_bool(*p, "isImplicitCode", I(2) != 0, true, false);
        pf_uint(*p, "atomGroup", I(3));
        pf_uint(*p, "atomRank", I(4));
      case .ASSIGN_ID;
      case .EXPRESSION;
        write_di_expression_body(m);
      case .ARG_LIST;
        for i: 0..cast(s64) ir.mds[m].nops - 1 {
            if i > 0 out(", ");
            write_md_as_operand(md_op(m, cast(u32) i));
        }
      case .GLOBAL_VARIABLE_EXPRESSION;
        pf_md(*p, "var", O(0));
        pf_md(*p, "expr", O(1));
      case .FILE;
        pf_string(*p, "filename", S(0), false);
        pf_string(*p, "directory", S(1), false);
        if I(0) != 0 {
            fp_sep(*p); out("checksumkind: "); out(dwarf_name(CHECKSUM_KIND_NAMES, I(0)));
            pf_string(*p, "checksum", S(2), false);
        }
        if O(3) != NONE pf_string(*p, "source", S(3), false);
      case .COMPILE_UNIT;
        if I(3) {
            pf_dwarf(*p, "sourceLanguageName", I(0), DW_LNAME_NAMES, false);
            pf_uint(*p, "sourceLanguageVersion", I(1));
        } else pf_dwarf(*p, "language", I(0), DW_LANG_NAMES, false);
        pf_md(*p, "file", O(0), false);
        pf_string(*p, "producer", S(1));
        pf_bool(*p, "isOptimized", I(4) != 0);
        pf_string(*p, "flags", S(2));
        pf_uint(*p, "runtimeVersion", I(5), false);
        pf_string(*p, "splitDebugFilename", S(3));
        fp_sep(*p); out("emissionKind: "); out(dwarf_name(EMISSION_KIND_NAMES, I(6)));
        pf_md(*p, "enums", O(4));
        pf_md(*p, "retainedTypes", O(5));
        pf_md(*p, "globals", O(6));
        pf_md(*p, "imports", O(7));
        pf_md(*p, "macros", O(8));
        pf_uint(*p, "dwoId", I(7));
        pf_bool(*p, "splitDebugInlining", I(8) != 0, true, true);
        pf_bool(*p, "debugInfoForProfiling", I(9) != 0, true, false);
        if I(10) != 0 { fp_sep(*p); out("nameTableKind: "); out(dwarf_name(NAME_TABLE_KIND_NAMES, I(10))); }
        pf_bool(*p, "rangesBaseAddress", I(11) != 0, true, false);
        pf_string(*p, "sysroot", S(9));
        pf_string(*p, "sdk", S(10));
        pf_dwarf(*p, "dialect", I(2), DW_LLVM_LANG_DIALECT_NAMES);
      case .SUBPROGRAM;
        pf_string(*p, "name", S(2));
        pf_string(*p, "linkageName", S(3));
        pf_md(*p, "scope", O(1), false);
        pf_md(*p, "file", O(0));
        pf_uint(*p, "line", I(0));
        pf_md(*p, "type", O(4));
        pf_uint(*p, "scopeLine", I(1));
        pf_md(*p, "containingType", O(8));
        if (I(5) & 3) != 0 || I(2) != 0 pf_uint(*p, "virtualIndex", I(2), false);
        pf_sint(*p, "thisAdjustment", cast,no_check(s64) I(3));
        pf_di_flags(*p, "flags", I(4));
        pf_sp_flags(*p, "spFlags", I(5));
        pf_md(*p, "unit", O(5));
        pf_md(*p, "templateParams", O(9));
        pf_md(*p, "declaration", O(6));
        pf_md(*p, "retainedNodes", O(7));
        pf_md(*p, "thrownTypes", O(10));
        pf_md(*p, "annotations", O(11));
        pf_string(*p, "targetFuncName", S(12));
        pf_bool(*p, "keyInstructions", I(6) != 0, true, false);
      case .SUBROUTINE_TYPE;
        pf_di_flags(*p, "flags", I(0));
        pf_dwarf(*p, "cc", I(1), DW_CC_NAMES);
        pf_md(*p, "types", O(5), false);
      case .BASIC_TYPE;
        if I(0) != DW_TAG_BASE_TYPE pf_tag(*p, I(0));
        pf_string(*p, "name", S(2));
        pf_md(*p, "scope", O(1));
        pf_md(*p, "file", O(0));
        pf_uint(*p, "line", I(1));
        pf_md_or_int(*p, "size", O(3), true);
        pf_uint(*p, "align", I(2));
        pf_uint(*p, "dataSize", I(5));
        pf_dwarf(*p, "encoding", I(3), DW_ATE_NAMES);
        pf_uint(*p, "num_extra_inhabitants", I(4));
        pf_di_flags(*p, "flags", I(6));
      case .DERIVED_TYPE;
        pf_tag(*p, I(0));
        pf_string(*p, "name", S(2));
        pf_md(*p, "scope", O(1));
        pf_md(*p, "file", O(0));
        pf_uint(*p, "line", I(1));
        pf_md(*p, "baseType", O(5), false);
        pf_md_or_int(*p, "size", O(3), true);
        pf_uint(*p, "align", I(2));
        pf_md_or_int(*p, "offset", O(4), true);
        pf_di_flags(*p, "flags", I(4));
        pf_md(*p, "extraData", O(6));
        if I(3) != 0xFFFF_FFFF pf_uint(*p, "dwarfAddressSpace", I(3), false);
        pf_md(*p, "annotations", O(7));
        if I(0) == DW_TAG_LLVM_PTRAUTH_TYPE {
            pf_uint(*p, "ptrAuthKey", I(5));
            pf_bool(*p, "ptrAuthIsAddressDiscriminated", I(6) != 0);
            pf_uint(*p, "ptrAuthExtraDiscriminator", I(7));
            pf_bool(*p, "ptrAuthIsaPointer", I(8) != 0);
            pf_bool(*p, "ptrAuthAuthenticatesNullValues", I(9) != 0);
        }
      case .COMPOSITE_TYPE;
        pf_tag(*p, I(0));
        pf_string(*p, "name", S(2));
        pf_md(*p, "scope", O(1));
        pf_md(*p, "file", O(0));
        pf_uint(*p, "line", I(1));
        pf_md(*p, "baseType", O(5));
        pf_md_or_int(*p, "size", O(3), true);
        pf_uint(*p, "align", I(3));
        pf_md_or_int(*p, "offset", O(4), true);
        pf_uint(*p, "num_extra_inhabitants", I(4));
        pf_di_flags(*p, "flags", I(6));
        pf_md(*p, "elements", O(6));
        pf_dwarf(*p, "runtimeLang", I(2), DW_LANG_NAMES);
        pf_md(*p, "vtableHolder", O(7));
        pf_md(*p, "templateParams", O(8));
        pf_string(*p, "identifier", S(9));
        pf_md(*p, "discriminator", O(10));
        pf_md(*p, "dataLocation", O(11));
        pf_md(*p, "associated", O(12));
        pf_md(*p, "allocated", O(13));
        rk := O(14);
        if rk != NONE && ir.mds[rk].kind == .VALUE && vkind(ir.mds[rk].value) == .C_INT pf_sint(*p, "rank", const_int_sext(ir.mds[rk].value), false);
        else pf_md(*p, "rank", rk);
        pf_md(*p, "annotations", O(15));
        if O(16) != NONE pf_md(*p, "specification", O(16));
        if I(5) != 0xFFFF_FFFF pf_dwarf(*p, "enumKind", I(5), DW_APPLE_ENUM_KIND_NAMES, false);
        pf_md(*p, "bitStride", O(17));
      case .LOCAL_VARIABLE;
        pf_string(*p, "name", S(1));
        pf_uint(*p, "arg", I(1));
        pf_md(*p, "scope", O(0), false);
        pf_md(*p, "file", O(2));
        pf_uint(*p, "line", I(0));
        pf_md(*p, "type", O(3));
        pf_di_flags(*p, "flags", I(2));
        pf_uint(*p, "align", I(3));
        pf_md(*p, "annotations", O(4));
      case .GLOBAL_VARIABLE;
        pf_string(*p, "name", S(1));
        pf_string(*p, "linkageName", S(5));
        pf_md(*p, "scope", O(0), false);
        pf_md(*p, "file", O(2));
        pf_uint(*p, "line", I(0));
        pf_md(*p, "type", O(3));
        pf_bool(*p, "isLocal", I(1) != 0);
        pf_bool(*p, "isDefinition", I(2) != 0);
        pf_md(*p, "declaration", O(6));
        pf_md(*p, "templateParams", O(7));
        pf_uint(*p, "align", I(3));
        pf_md(*p, "annotations", O(8));
      case .LEXICAL_BLOCK;
        pf_md(*p, "scope", O(1), false);
        pf_md(*p, "file", O(0));
        pf_uint(*p, "line", I(0));
        pf_uint(*p, "column", I(1));
      case .LEXICAL_BLOCK_FILE;
        pf_md(*p, "scope", O(1), false);
        pf_md(*p, "file", O(0));
        pf_uint(*p, "discriminator", I(0), false);
      case .NAMESPACE;
        pf_string(*p, "name", S(2));
        pf_md(*p, "scope", O(1), false);
        pf_bool(*p, "exportSymbols", I(0) != 0, true, false);
      case .SUBRANGE;
        pf_md_or_int(*p, "count", O(0), false, false);
        pf_md_or_int(*p, "lowerBound", O(1), false, false);
        pf_md_or_int(*p, "upperBound", O(2), false, false);
        pf_md_or_int(*p, "stride", O(3), false, false);
      case .LABEL;
        pf_md(*p, "scope", O(0), false);
        pf_string(*p, "name", S(1));
        pf_md(*p, "file", O(2));
        pf_uint(*p, "line", I(0), false);
        pf_uint(*p, "column", I(1));
        pf_bool(*p, "isArtificial", I(2) != 0, true, false);
        if I(3) pf_uint(*p, "coroSuspendIdx", I(4), false);
      case .IMPORTED_ENTITY;
        pf_tag(*p, I(0));
        pf_string(*p, "name", S(2));
        pf_md(*p, "scope", O(0), false);
        pf_md(*p, "entity", O(1));
        pf_md(*p, "file", O(3));
        pf_uint(*p, "line", I(1));
        pf_md(*p, "elements", O(4));
      case .TEMPLATE_TYPE_PARAMETER;
        pf_string(*p, "name", S(0));
        pf_md(*p, "type", O(1), false);
        pf_bool(*p, "defaulted", I(0) != 0, true, false);
      case .TEMPLATE_VALUE_PARAMETER;
        if I(0) != DW_TAG_TEMPLATE_VALUE_PARAMETER pf_tag(*p, I(0));
        pf_string(*p, "name", S(0));
        pf_md(*p, "type", O(1));
        pf_bool(*p, "defaulted", I(1) != 0, true, false);
        pf_md(*p, "value", O(2), false);
      case .ENUMERATOR;
        pf_string(*p, "name", S(0), false);
        fp_sep(*p); out("value: ");
        if I(2) out_s64(cast,no_check(s64) I(0)); else out_u64(I(0));
        if I(1) pf_bool(*p, "isUnsigned", true);
      case .GENERIC_SUBRANGE;
        // a DIExpression that isConstant() as a SignedConstant prints as its value
        names :: string.["count", "lowerBound", "upperBound", "stride"];
        for nm, i: names {
            b := O(cast(u32) i);
            if is_di(b, .EXPRESSION) && ir.mds[b].nints == 2 && di_int(b, 0) == DW_OP_CONSTS pf_sint(*p, nm, cast,no_check(s64) di_int(b, 1), false);
            else pf_md(*p, nm, b);
        }
      case .MODULE;
        pf_md(*p, "scope", O(1), false);
        pf_string(*p, "name", S(2));
        pf_string(*p, "configMacros", S(3));
        pf_string(*p, "includePath", S(4));
        pf_string(*p, "apinotes", S(5));
        pf_md(*p, "file", O(0));
        pf_uint(*p, "line", I(0));
        pf_bool(*p, "isDecl", I(1) != 0, true, false);
      case .MACRO;
        fp_sep(*p); out("type: ");
        { s := dwarf_name(DW_MACINFO_NAMES, I(0)); if s.count out(s); else out_u64(I(0)); }
        pf_uint(*p, "line", I(1));
        pf_string(*p, "name", S(0));
        pf_string(*p, "value", S(1));
      case .MACRO_FILE;
        pf_uint(*p, "line", I(1));
        pf_md(*p, "file", O(0), false);
        pf_md(*p, "nodes", O(1));
      case .COMMON_BLOCK;
        pf_md(*p, "scope", O(0), false);
        pf_md(*p, "declaration", O(1), false);
        pf_string(*p, "name", S(2));
        pf_md(*p, "file", O(3));
        pf_uint(*p, "line", I(0));
      case .OBJC_PROPERTY;
        pf_string(*p, "name", S(0));
        pf_md(*p, "file", O(1));
        pf_uint(*p, "line", I(0));
        pf_string(*p, "setter", S(3));
        pf_string(*p, "getter", S(2));
        pf_uint(*p, "attributes", I(1));
        pf_md(*p, "type", O(4));
      case .STRING_TYPE;
        if I(0) != DW_TAG_STRING_TYPE pf_tag(*p, I(0));
        pf_string(*p, "name", S(2));
        pf_md(*p, "stringLength", O(5));
        pf_md(*p, "stringLengthExpression", O(6));
        pf_md(*p, "stringLocationExpression", O(7));
        pf_md_or_int(*p, "size", O(3), true);
        pf_uint(*p, "align", I(1));
        pf_dwarf(*p, "encoding", I(2), DW_ATE_NAMES);
      case .SUBRANGE_TYPE;
        pf_string(*p, "name", S(2));
        pf_md(*p, "scope", O(1));
        pf_md(*p, "file", O(0));
        pf_uint(*p, "line", I(1));
        pf_md_or_int(*p, "size", O(3), true);
        pf_uint(*p, "align", I(2));
        pf_di_flags(*p, "flags", I(3));
        pf_md(*p, "baseType", O(5), false);
        pf_md(*p, "lowerBound", O(6));
        pf_md(*p, "upperBound", O(7));
        pf_md(*p, "stride", O(8));
        pf_md(*p, "bias", O(9));
      case .FIXED_POINT_TYPE;
        if I(0) != DW_TAG_BASE_TYPE pf_tag(*p, I(0));
        pf_string(*p, "name", S(2));
        pf_md(*p, "scope", O(1));
        pf_md(*p, "file", O(0));
        pf_uint(*p, "line", I(1));
        pf_md_or_int(*p, "size", O(3), true);
        pf_uint(*p, "align", I(2));
        pf_dwarf(*p, "encoding", I(3), DW_ATE_NAMES);
        pf_di_flags(*p, "flags", I(4));
        fp_sep(*p); out("kind: "); out(dwarf_name(FIXED_POINT_KIND_NAMES, I(5)));
        if I(5) == 2 {
            // printAPInt(..., IsUnsigned = !isSigned()) of the literal's APInt (no widening, unlike DIEnumerator)
            sgn := I(3) == DW_ATE_SIGNED_FIXED;
            fp_sep(*p); out("numerator: "); print_literal_apint(I(7), I(8) != 0, sgn);
            fp_sep(*p); out("denominator: "); print_literal_apint(I(9), I(10) != 0, sgn);
        } else pf_sint(*p, "factor", cast,no_check(s64) I(6));
      case .GENERIC_DINODE;
        pf_tag(*p, I(0));
        pf_string(*p, "header", S(0));
        if ir.mds[m].nops > 1 {
            fp_sep(*p); out("operands: {");
            for i: 1..cast(s64) ir.mds[m].nops - 1 {
                if i > 1 out(", ");
                write_md_as_operand(md_op(m, cast(u32) i));
            }
            outc(#char "}");
        }
    }
    outc(#char ")");
}

DW_OP_BREG0 :: 0x70; DW_OP_BREG31 :: 0x8f; DW_OP_REG0 :: 0x50; DW_OP_REG31 :: 0x6f;
DW_OP_LLVM_FRAGMENT :: 0x1000; DW_OP_LLVM_CONVERT :: 0x1001; DW_OP_LLVM_ENTRY_VALUE :: 0x1003; DW_OP_LLVM_ARG :: 0x1005;
DW_OP_STACK_VALUE :: 0x9f; DW_OP_SWAP :: 0x16;

// DIExpression::ExprOperand::getSize
expr_op_size :: (op: u64) -> s64 {
    if op >= DW_OP_BREG0 && op <= DW_OP_BREG31 return 2;
    if op == {
        case 0x1001; #through; case 0x1000; #through; case 0x1006; #through; case 0x1007; #through;
        case 0x92;   // DW_OP_bregx
            return 3;
        case 0x10; #through; case 0x11; #through; case 0x94; #through; case 0x23; #through;   // constu consts deref_size plus_uconst
        case 0x1002; #through; case 0x1003; #through; case 0x1005; #through;
        case 0x90;   // DW_OP_regx
            return 2;
    }
    return 1;
}

VALID_EXPR_OPS :: u64.[
    0x1004, 0x1001, 0x1005, 0x1002, 0x1006, 0x1007, 0x10, 0x23, 0x22, 0x1c, 0x1e, 0x1b, 0x1d, 0x21, 0x1a, 0x27,
    0x24, 0x25, 0x26, 0x06, 0x94, 0x18, 0x30, 0x20, 0x12, 0x90, 0x92, 0x97, 0x14, 0x17, 0x11, 0x29, 0x2e, 0x2b,
    0x2a, 0x2d, 0x2c, 0x1f, 0x19,
];

// DIExpression::isValid
di_expression_valid :: (e: [] u64) -> bool {
    i := 0;
    n := e.count;
    while i < n {
        op := e[i];
        sz := expr_op_size(op);
        if i + sz > n return false;
        if (op >= DW_OP_REG0 && op <= DW_OP_REG31) || (op >= DW_OP_BREG0 && op <= DW_OP_BREG31) return true;
        if op == DW_OP_LLVM_FRAGMENT return i + sz == n;
        if op == DW_OP_STACK_VALUE {
            if i + sz != n {
                if i + sz >= n || e[i + sz] != DW_OP_LLVM_FRAGMENT return false;
            }
        } else if op == DW_OP_SWAP {
            if n == 1 return false;
        } else if op == DW_OP_LLVM_ENTRY_VALUE {
            first := 0;
            if e[0] == DW_OP_LLVM_ARG && e.count > 1 && e[1] == 0 first = 2;
            return i == first && e[i + 1] == 1;
        } else {
            ok := false;
            for VALID_EXPR_OPS if it == op { ok = true; break; }
            if !ok return false;
        }
        i += sz;
    }
    return true;
}

write_di_expression_body :: (m: Md_Id) {
    e: [] u64; e.data = ir.md_ints.data + ir.mds[m].ints; e.count = ir.mds[m].nints;
    first := true;
    sep :: () #expand { if !`first out(", "); `first = false; }
    if di_expression_valid(e) {
        i := 0;
        while i < e.count {
            op := e[i];
            sz := expr_op_size(op);
            sep(); out(dwarf_name(DW_OP_NAMES, op));
            if op == DW_OP_LLVM_CONVERT {
                sep(); out_u64(e[i + 1]);
                sep(); out(dwarf_name(DW_ATE_NAMES, e[i + 2]));
            } else {
                for a: 1..sz-1 { sep(); out_u64(e[i + a]); }
            }
            i += sz;
        }
    } else {
        for e { sep(); out_u64(it); }
    }
}

// AssemblyWriter::printDbgRecordLine
print_dbg_record :: (r: Dbg_Record) {
    out("    ");
    pon :: (m: Md_Id) { if m == NONE out("(null)"); else write_md_as_operand(m); }
    if r.kind == .LABEL {
        out("#dbg_label("); write_md_as_operand(r.loc); out(", "); write_md_as_operand(r.dbg); out(")\n");
        return;
    }
    out("#dbg_");
    if r.kind == {
        case .VALUE; out("value"); case .DECLARE; out("declare"); case .DECLARE_VALUE; out("declare_value");
        case .ASSIGN; out("assign");
    }
    outc(#char "(");
    pon(r.loc); out(", "); pon(r.var); out(", "); pon(r.expr); out(", ");
    if r.kind == .ASSIGN { pon(r.assign_id); out(", "); pon(r.addr); out(", "); pon(r.addr_expr); out(", "); }
    pon(r.dbg);
    out(")\n");
}

print_records_of :: (i: Value_Id) {
    x := inst(i).records;
    while x != 0 { print_dbg_record(ir.dbg_records[x - 1]); x = ir.dbg_records[x - 1].next; }
}

// SlotTracker::processDbgRecordMetadata
slot_records_of :: (i: Value_Id) {
    x := inst(i).records;
    while x != 0 {
        r := ir.dbg_records[x - 1];
        if r.kind == .LABEL {
            create_md_slot(r.loc);
        } else {
            if is_md_node(r.loc) create_md_slot(r.loc);
            if r.var != NONE create_md_slot(r.var);
            if r.kind == .ASSIGN {
                if r.assign_id != NONE create_md_slot(r.assign_id);
                if is_md_node(r.addr) create_md_slot(r.addr);
            }
        }
        if r.dbg != NONE create_md_slot(r.dbg);
        x = r.next;
    }
}
