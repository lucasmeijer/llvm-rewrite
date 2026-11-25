// IR2Vec: a port of llvm/lib/Analysis/IR2Vec.cpp and llvm/include/llvm/Analysis/IR2Vec.h (Vocabulary,
// readVocabularyFromFile / buildVocabStorage / fromFile, the Symbolic and FlowAware embedders, IR2VecPrinterPass,
// IR2VecVocabPrinterPass). The vocabulary JSON is read with a small JSON reader (numbers via libc strtod, like
// llvm::json's parser); Embedding::print's format("%.2f") is reproduced exactly (ir2vec_fmt2).

ir2vec_vocab_path := "";        // -ir2vec-vocab-path
ir2vec_opc_weight: float32 = 1.0;   // -ir2vec-opc-weight (cl::opt<float>)
ir2vec_type_weight: float32 = 0.5;  // -ir2vec-type-weight
ir2vec_arg_weight: float32 = 0.2;   // -ir2vec-arg-weight
ir2vec_flow_aware := false;     // -ir2vec-kind=flow-aware

IR2VEC_MAX_OPCODES :: 69;
IR2VEC_TYPE_NAMES :: string.["FloatTy", "VoidTy", "LabelTy", "MetadataTy", "VectorTy", "TokenTy", "IntegerTy", "ByteTy",
                             "FunctionTy", "PointerTy", "StructTy", "ArrayTy", "UnknownTy"];
IR2VEC_OPERAND_NAMES :: string.["Function", "Pointer", "Constant", "Variable"];
IR2VEC_OPCODE_NAMES :: string.[
    "Ret", "UncondBr", "CondBr", "Switch", "IndirectBr", "Invoke", "Resume", "Unreachable", "CleanupRet", "CatchRet",
    "CatchSwitch", "CallBr", "FNeg", "Add", "FAdd", "Sub", "FSub", "Mul", "FMul", "UDiv", "SDiv", "FDiv", "URem", "SRem",
    "FRem", "Shl", "LShr", "AShr", "And", "Or", "Xor", "Alloca", "Load", "Store", "GetElementPtr", "Fence",
    "AtomicCmpXchg", "AtomicRMW", "Trunc", "ZExt", "SExt", "FPToUI", "FPToSI", "UIToFP", "SIToFP", "FPTrunc", "FPExt",
    "PtrToInt", "PtrToAddr", "IntToPtr", "BitCast", "AddrSpaceCast", "CleanupPad", "CatchPad", "ICmp", "FCmp", "PHI",
    "Call", "Select", "UserOp1", "UserOp2", "VAArg", "ExtractElement", "InsertElement", "ShuffleVector", "ExtractValue",
    "InsertValue", "LandingPad", "Freeze"];
// CmpInst::getPredicateName, in the vocabulary's dense order (FCMP_FALSE..FCMP_TRUE, ICMP_EQ..ICMP_SLE)
IR2VEC_PRED_NAMES :: string.["FCMP_false", "FCMP_oeq", "FCMP_ogt", "FCMP_oge", "FCMP_olt", "FCMP_ole", "FCMP_one",
    "FCMP_ord", "FCMP_uno", "FCMP_ueq", "FCMP_ugt", "FCMP_uge", "FCMP_ult", "FCMP_ule", "FCMP_une", "FCMP_true",
    "ICMP_eq", "ICMP_ne", "ICMP_ugt", "ICMP_uge", "ICMP_ult", "ICMP_ule", "ICMP_sgt", "ICMP_sge", "ICMP_slt", "ICMP_sle"];

Ir2vec_Vocab :: struct {
    loaded: bool;
    dim: s64;
    // the four sections, flattened: opcodes, canonical types, operand kinds, predicates
    entries: [..] [] float64;
}
ir2vec_vocab: Ir2vec_Vocab;

// ---------------------------------------------------------------- a small JSON reader

Json_Kind :: enum u8 { NULL_; BOOL; NUMBER; STRING; ARRAY; OBJECT; }
Json :: struct {
    kind: Json_Kind;
    num: float64;
    str: string;
    items: [..] Json;          // ARRAY elements; OBJECT values
    keys: [..] string;         // OBJECT keys
}
Json_Parser :: struct { s: string; pos: s64; err: string; }

json_skip_ws :: (p: *Json_Parser) {
    while p.pos < p.s.count && (p.s[p.pos] == #char " " || p.s[p.pos] == #char "\t" || p.s[p.pos] == #char "\n" || p.s[p.pos] == #char "\r") p.pos += 1;
}
json_fail :: (p: *Json_Parser, msg: string) -> bool { if !p.err p.err = msg; return false; }

ir2vec_libc :: #system_library "libc";
ir2vec_strtod :: (s: *u8, end: **u8) -> float64 #foreign ir2vec_libc "strtod";

json_parse_value :: (p: *Json_Parser, out: *Json) -> bool {
    json_skip_ws(p);
    if p.pos >= p.s.count return json_fail(p, "Unexpected EOF");
    c := p.s[p.pos];
    if c == #char "{" {
        p.pos += 1;
        out.kind = .OBJECT;
        json_skip_ws(p);
        if p.pos < p.s.count && p.s[p.pos] == #char "}" { p.pos += 1; return true; }
        while true {
            json_skip_ws(p);
            if p.pos >= p.s.count || p.s[p.pos] != #char "\"" return json_fail(p, "Expected object key");
            k: Json;
            if !json_parse_value(p, *k) return false;
            json_skip_ws(p);
            if p.pos >= p.s.count || p.s[p.pos] != #char ":" return json_fail(p, "Expected : after object key");
            p.pos += 1;
            v: Json;
            if !json_parse_value(p, *v) return false;
            array_add(*out.keys, k.str);
            array_add(*out.items, v);
            json_skip_ws(p);
            if p.pos < p.s.count && p.s[p.pos] == #char "," { p.pos += 1; continue; }
            if p.pos < p.s.count && p.s[p.pos] == #char "}" { p.pos += 1; return true; }
            return json_fail(p, "Expected , or } after object property");
        }
    }
    if c == #char "[" {
        p.pos += 1;
        out.kind = .ARRAY;
        json_skip_ws(p);
        if p.pos < p.s.count && p.s[p.pos] == #char "]" { p.pos += 1; return true; }
        while true {
            v: Json;
            if !json_parse_value(p, *v) return false;
            array_add(*out.items, v);
            json_skip_ws(p);
            if p.pos < p.s.count && p.s[p.pos] == #char "," { p.pos += 1; continue; }
            if p.pos < p.s.count && p.s[p.pos] == #char "]" { p.pos += 1; return true; }
            return json_fail(p, "Expected , or ] after array element");
        }
    }
    if c == #char "\"" {
        p.pos += 1;
        sb: String_Builder; sb.allocator = temp;
        while true {
            if p.pos >= p.s.count return json_fail(p, "Unterminated string");
            ch := p.s[p.pos];
            p.pos += 1;
            if ch == #char "\"" break;
            if ch == #char "\\" {
                if p.pos >= p.s.count return json_fail(p, "Unterminated string");
                e := p.s[p.pos];
                p.pos += 1;
                if e == {
                    case #char "\""; append(*sb, "\"");
                    case #char "\\"; append(*sb, "\\");
                    case #char "/"; append(*sb, "/");
                    case #char "n"; append(*sb, "\n");
                    case #char "t"; append(*sb, "\t");
                    case #char "r"; append(*sb, "\r");
                    case #char "b"; append(*sb, "\x08");
                    case #char "f"; append(*sb, "\x0c");
                    case; return json_fail(p, "unsupported JSON string escape (\\u...)");
                }
                continue;
            }
            append(*sb, ch);
        }
        out.kind = .STRING;
        out.str = builder_to_string(*sb,, allocator = temp);
        return true;
    }
    if begins_with(slice(p.s, p.pos, p.s.count - p.pos), "true") { p.pos += 4; out.kind = .BOOL; out.num = 1; return true; }
    if begins_with(slice(p.s, p.pos, p.s.count - p.pos), "false") { p.pos += 5; out.kind = .BOOL; return true; }
    if begins_with(slice(p.s, p.pos, p.s.count - p.pos), "null") { p.pos += 4; out.kind = .NULL_; return true; }
    if c == #char "-" || (c >= #char "0" && c <= #char "9") {
        start := p.pos;
        while p.pos < p.s.count {
            d := p.s[p.pos];
            if (d >= #char "0" && d <= #char "9") || d == #char "-" || d == #char "+" || d == #char "." || d == #char "e" || d == #char "E" p.pos += 1;
            else break;
        }
        txt := slice(p.s, start, p.pos - start);
        cs := temp_c_string(txt);
        end: *u8;
        out.num = ir2vec_strtod(cs, *end);
        if end != cs + txt.count return json_fail(p, "Invalid JSON value (number?)");
        out.kind = .NUMBER;
        return true;
    }
    return json_fail(p, "Invalid JSON value");
}

json_object_get :: (o: *Json, key: string) -> *Json {
    for o.keys if it == key return *o.items[it_index];
    return null;
}

// ---------------------------------------------------------------- the vocabulary

// a parsed section: std::map<std::string, Embedding> (keys sorted)
Ir2vec_Section :: struct { keys: [..] string; vals: [..] [..] float64; }

ir2vec_section_find :: (s: *Ir2vec_Section, key: string) -> *[..] float64 {
    for s.keys if it == key return *s.vals[it_index];
    return null;
}

ir2vec_vocab_error :: (msg: string) {
    write_string(tprint("LLVM ERROR: error reading vocabulary: %\n", msg), to_standard_error = true);
    exit(1);
}

// VocabStorage::parseVocabSection
ir2vec_parse_section :: (root: *Json, key: string, out: *Ir2vec_Section) -> s64 {
    if root.kind != .OBJECT ir2vec_vocab_error("JSON root is not an object");
    v := json_object_get(root, key);
    if !v ir2vec_vocab_error(tprint("Missing '%' section in vocabulary file", key));
    if v.kind != .OBJECT ir2vec_vocab_error(tprint("Unable to parse '%' section from vocabulary", key));
    for v.keys {
        e := *v.items[it_index];
        if e.kind != .ARRAY ir2vec_vocab_error(tprint("Unable to parse '%' section from vocabulary", key));
        vals: [..] float64;
        for x: e.items {
            if x.kind != .NUMBER ir2vec_vocab_error(tprint("Unable to parse '%' section from vocabulary", key));
            array_add(*vals, x.num);
        }
        // std::map: sorted keys, a repeated key keeps the last value (json::Object is a map too)
        found := false;
        for k, ki: out.keys if k == it { out.vals[ki] = vals; found = true; break; }
        if found continue;
        pos := 0;
        while pos < out.keys.count && compare(out.keys[pos], it) < 0 pos += 1;
        array_insert_at(*out.keys, copy_string(it), pos);
        array_insert_at(*out.vals, vals, pos);
    }
    if out.keys.count == 0 ir2vec_vocab_error(tprint("Dimension of '%' section of the vocabulary is zero", key));   // begin() of an empty map
    dim := out.vals[0].count;
    if dim == 0 ir2vec_vocab_error(tprint("Dimension of '%' section of the vocabulary is zero", key));
    for out.vals if it.count != dim
        ir2vec_vocab_error(tprint("All vectors in the '%' section of the vocabulary are not of the same dimension", key));
    return dim;
}

// IR2VecVocabAnalysis::run / Vocabulary::fromFile / buildVocabStorage
ir2vec_get_vocab :: () -> *Ir2vec_Vocab {
    v := *ir2vec_vocab;
    if v.loaded return v;
    if ir2vec_vocab_path == "" {
        write_string("LLVM ERROR: IR2Vec vocabulary file path not specified; You may need to set it using --ir2vec-vocab-path\n", to_standard_error = true);
        exit(1);
    }
    text, ok := read_entire_file(ir2vec_vocab_path, log_errors = false);
    if !ok ir2vec_vocab_error(tprint("%: No such file or directory", ir2vec_vocab_path));
    p: Json_Parser; p.s = text;
    root: Json;
    if !json_parse_value(*p, *root) ir2vec_vocab_error(p.err);
    json_skip_ws(*p);
    if p.pos != p.s.count ir2vec_vocab_error("Text after end of document");
    opc, typ, arg: Ir2vec_Section;
    od := ir2vec_parse_section(*root, "Opcodes", *opc);
    td := ir2vec_parse_section(*root, "Types", *typ);
    ad := ir2vec_parse_section(*root, "Arguments", *arg);
    if !(od == td && td == ad) ir2vec_vocab_error("Vocabulary sections have different dimensions");
    // scaleVocabSection: Embedding *= (double) Weight
    scale :: (s: *Ir2vec_Section, w: float32) { for * vec: s.vals for * vec.* it.* *= cast(float64) w; }
    scale(*opc, ir2vec_opc_weight);
    scale(*typ, ir2vec_type_weight);
    scale(*arg, ir2vec_arg_weight);
    v.dim = od;
    lookup :: (s: *Ir2vec_Section, key: string, dim: s64) -> [] float64 {
        r := NewArray(dim, float64);
        e := ir2vec_section_find(s, key);
        if e for e.* r[it_index] = it;   // a missing entity is a zero vector
        return r;
    }
    for IR2VEC_OPCODE_NAMES array_add(*v.entries, lookup(*opc, it, v.dim));
    for IR2VEC_TYPE_NAMES array_add(*v.entries, lookup(*typ, it, v.dim));
    for IR2VEC_OPERAND_NAMES array_add(*v.entries, lookup(*arg, it, v.dim));
    for IR2VEC_PRED_NAMES array_add(*v.entries, lookup(*arg, it, v.dim));
    v.loaded = true;
    return v;
}

IR2VEC_TYPE_BASE :: IR2VEC_MAX_OPCODES;
IR2VEC_OPERAND_BASE :: IR2VEC_TYPE_BASE + IR2VEC_TYPE_NAMES.count;
IR2VEC_PRED_BASE :: IR2VEC_OPERAND_BASE + IR2VEC_OPERAND_NAMES.count;

// getCanonicalTypeID(Type::getTypeID())
ir2vec_canonical_type :: (t: Type_Id) -> s64 {
    k := type_kind(t);
    if k == {
        case .HALF; #through; case .BFLOAT; #through; case .FLOAT; #through; case .DOUBLE; #through;
        case .X86_FP80; #through; case .FP128; #through; case .PPC_FP128; return 0;
        case .VOID; return 1;
        case .LABEL; return 2;
        case .METADATA; return 3;
        case .X86_AMX; #through; case .VECTOR; #through; case .SVECTOR; return 4;
        case .TOKEN; return 5;
        case .INT; return 6;
        case .BYTE; return 7;
        case .FUNC; return 8;
        case .PTR; return 9;
        case .STRUCT; return 10;
        case .ARRAY; return 11;
        case .TARGET_EXT; return 12;
    }
    fatal("ir2vec: unexpected type kind");
    return 12;
}
// getOperandKind
ir2vec_operand_kind :: (v: Value_Id) -> s64 {
    if vkind(v) == .FUNCTION return 0;
    if type_kind(vtype(v)) == .PTR return 1;
    if is_const(v) return 2;
    return 3;
}
// getPredicateLocalIndex
ir2vec_pred_index :: (p: u8) -> s64 {
    if p <= 15 return p;
    return cast(s64) p - 32 + 16;
}

ir2vec_add :: (a: [] float64, b: [] float64) { for * a it.* += b[it_index]; }
ir2vec_zero :: (dim: s64) -> [] float64 { r := NewArray(dim, float64,, allocator = temp); return r; }

Ir2vec_Embedder :: struct {
    v: *Ir2vec_Vocab;
    flow: bool;
    map: Table(Value_Id, [] float64);   // FlowAwareEmbedder::InstVecMap
}

// computeEmbeddings(const Instruction &)
ir2vec_inst :: (e: *Ir2vec_Embedder, i: Value_Id) -> [] float64 {
    if e.flow {
        found, c := table_find(*e.map, i);
        if found return c;
    }
    dim := e.v.dim;
    arg := ir2vec_zero(dim);
    for k: 0..cast(s64) nops(i) - 1 {
        o := op(i, cast(u32) k);
        if e.flow && is_inst(o) {
            found, c := table_find(*e.map, o);
            if found { ir2vec_add(arg, c); continue; }
        }
        ir2vec_add(arg, e.v.entries[IR2VEC_OPERAND_BASE + ir2vec_operand_kind(o)]);
    }
    r := ir2vec_zero(dim);
    oe := e.v.entries[cast(s64) inst_op(i) - 1];
    te := e.v.entries[IR2VEC_TYPE_BASE + ir2vec_canonical_type(vtype(i))];
    for * r it.* = oe[it_index] + te[it_index];
    ir2vec_add(r, arg);
    if inst_op(i) == .ICMP || inst_op(i) == .FCMP ir2vec_add(r, e.v.entries[IR2VEC_PRED_BASE + ir2vec_pred_index(inst(i).pred)]);
    if e.flow table_set(*e.map, i, r);
    return r;
}
// computeEmbeddings(const BasicBlock &)
ir2vec_bb :: (e: *Ir2vec_Embedder, bb: Value_Id) -> [] float64 {
    r := ir2vec_zero(e.v.dim);
    for i: block_insts(bb) if !is_debug_or_pseudo_inst(i) ir2vec_add(r, ir2vec_inst(e, i));
    return r;
}

// format("%.2f", x), exactly as printf rounds (round-half-even on the exact binary value)
ir2vec_fmt2 :: (sb: *String_Builder, x: float64) {
    bits := (cast(*u64) *x).*;
    neg := (bits >> 63) != 0;
    exp_bits := cast(s64) ((bits >> 52) & 0x7FF);
    frac := bits & 0xF_FFFF_FFFF_FFFF;
    if exp_bits == 0x7FF {
        if neg append(sb, "-");
        append(sb, ifx frac != 0 then "nan" else "inf");
        return;
    }
    mant: u64;
    e: s64;
    if exp_bits == 0 { mant = frac; e = -1074; } else { mant = frac | (1 << 52); e = exp_bits - 1075; }
    // x * 100 = mant * 100 * 2^e
    m100 := mant * 100;   // < 2^60
    q: u64;
    if e >= 0 {
        // an integer: x * 100 is exact, the two decimals are zero
        if neg append(sb, "-");
        append(sb, big_to_decimal(big_shl(big_from_u64(mant), e)));
        append(sb, ".00");
        return;
    } else if -e >= 62 {
        q = 0;   // below 0.005: rounds to zero (it can't be exactly half)
    } else {
        sh := cast(u64) -e;
        q = m100 >> sh;
        r := m100 & ((cast(u64) 1 << sh) - 1);
        half := cast(u64) 1 << (sh - 1);
        if r > half || (r == half && (q & 1) != 0) q += 1;
    }
    if neg append(sb, "-");
    print_to_builder(sb, "%.", q / 100);
    d := q % 100;
    if d < 10 append(sb, "0");
    print_to_builder(sb, "%", d);
}

// Embedding::print
ir2vec_print_emb :: (sb: *String_Builder, v: [] float64) {
    append(sb, " [");
    for v { append(sb, " "); ir2vec_fmt2(sb, it); append(sb, " "); }
    append(sb, "]\n");
}

// IR2VecPrinterPass
print_ir2vec_run :: () -> Preserved {
    v := ir2vec_get_vocab();
    sb: String_Builder; sb.allocator = temp;
    for f: ir.m_functions {
        e: Ir2vec_Embedder;
        e.v = v;
        e.flow = ir2vec_flow_aware;
        e.map.allocator = temp;
        print_to_builder(*sb, "IR2Vec embeddings for function %:\n", vname(f));
        append(*sb, "Function vector: ");
        fv := ir2vec_zero(v.dim);
        if !is_declaration(f) {
            order: [..] Value_Id; order.allocator = temp;
            sl_depth_first(f, *order);   // depth_first(&F)
            for order ir2vec_add(fv, ir2vec_bb(*e, it));
        }
        ir2vec_print_emb(*sb, fv);
        append(*sb, "Basic block vectors:\n");
        for bb: fn_blocks(f) {
            print_to_builder(*sb, "Basic block: %:\n", vname(bb));
            ir2vec_print_emb(*sb, ir2vec_bb(*e, bb));
        }
        append(*sb, "Instruction vectors:\n");
        for bb: fn_blocks(f) for i: block_insts(bb) {
            append(*sb, "Instruction: ");
            append(*sb, inst_to_string(i));
            ir2vec_print_emb(*sb, ir2vec_inst(*e, i));
        }
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}

// IR2VecVocabPrinterPass
print_ir2vec_vocab_run :: () -> Preserved {
    v := ir2vec_get_vocab();
    sb: String_Builder; sb.allocator = temp;
    names: [..] string; names.allocator = temp;
    for IR2VEC_OPCODE_NAMES array_add(*names, it);
    for IR2VEC_TYPE_NAMES array_add(*names, it);
    for IR2VEC_OPERAND_NAMES array_add(*names, it);
    for IR2VEC_PRED_NAMES array_add(*names, it);
    for v.entries {
        print_to_builder(*sb, "Key: %: ", names[it_index]);
        ir2vec_print_emb(*sb, it);
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}
