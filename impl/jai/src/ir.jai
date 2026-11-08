// IR core: flat tables indexed by 32-bit ids (see DESIGN.md).
// Ported concepts from llvm/include/llvm/IR/{Type,Value,Use,User,Constants,Instruction,Metadata,Attributes}.h
// and llvm/lib/IR/{Value,Use,Constants,Type,Metadata,Attributes,ValueSymbolTable}.cpp.

Value_Id :: u32;
Type_Id  :: u32;
Use_Id   :: u32;
Md_Id    :: u32;
NONE     :: 0xFFFF_FFFF;

// ---------------------------------------------------------------- types

Type_Kind :: enum u8 {
    VOID; HALF; BFLOAT; FLOAT; DOUBLE; X86_FP80; FP128; PPC_FP128;
    LABEL; METADATA; X86_AMX; TOKEN;
    INT; BYTE; FUNC; PTR; STRUCT; ARRAY; VECTOR; SVECTOR; TARGET_EXT;
}

TYF_PACKED  :: 1;
TYF_VARARG  :: 2;
TYF_OPAQUE  :: 4;   // identified struct without a body
TYF_LITERAL :: 8;   // literal (anonymous) struct

Type_Row :: struct {
    kind:  Type_Kind;
    flags: u8;
    a:     u64;      // int width, ptr addrspace, array/vector count
    sub:   u32;      // first contained type in ir.type_list
    nsub:  u32;
    name:  string;   // identified structs ("" = numbered), target ext name
    ints:  u32;      // target ext int params: start in ir.type_list (stored as u32)
    nints: u32;
}

// ---------------------------------------------------------------- values

Value_Kind :: enum u8 {
    DEAD;
    ARGUMENT; BLOCK; INST;
    GLOBAL_VAR; FUNCTION; ALIAS; IFUNC;
    C_INT; C_FP; C_NULL; C_ZERO; C_TOKEN_NONE; C_UNDEF; C_POISON;
    C_ARRAY; C_STRUCT; C_VECTOR; C_DATA;
    C_EXPR; C_BLOCKADDR; C_DSO_EQUIV; C_NO_CFI; C_PTRAUTH; C_TARGET_NONE;
    MD_VALUE; INLINE_ASM;
    PLACEHOLDER;     // parser forward reference
}

is_constant_kind :: inline (k: Value_Kind) -> bool {
    return (k >= .GLOBAL_VAR && k <= .C_TARGET_NONE);
}
is_global_value :: inline (k: Value_Kind) -> bool {
    return k >= .GLOBAL_VAR && k <= .IFUNC;
}

Opcode :: enum u8 {
    NONE_OP :: 0;
    RET :: 1; BR :: 2; CONDBR :: 3; SWITCH :: 4; INDIRECTBR :: 5; INVOKE :: 6; RESUME :: 7; UNREACHABLE :: 8;
    CLEANUPRET :: 9; CATCHRET :: 10; CATCHSWITCH :: 11; CALLBR :: 12;
    FNEG :: 13;
    ADD :: 14; FADD :: 15; SUB :: 16; FSUB :: 17; MUL :: 18; FMUL :: 19; UDIV :: 20; SDIV :: 21; FDIV :: 22;
    UREM :: 23; SREM :: 24; FREM :: 25; SHL :: 26; LSHR :: 27; ASHR :: 28; AND :: 29; OR :: 30; XOR :: 31;
    ALLOCA :: 32; LOAD :: 33; STORE :: 34; GEP :: 35; FENCE :: 36; CMPXCHG :: 37; ATOMICRMW :: 38;
    TRUNC :: 39; ZEXT :: 40; SEXT :: 41; FPTOUI :: 42; FPTOSI :: 43; UITOFP :: 44; SITOFP :: 45;
    FPTRUNC :: 46; FPEXT :: 47; PTRTOINT :: 48; PTRTOADDR :: 49; INTTOPTR :: 50; BITCAST :: 51; ADDRSPACECAST :: 52;
    CLEANUPPAD :: 53; CATCHPAD :: 54;
    ICMP :: 55; FCMP :: 56; PHI :: 57; CALL :: 58; SELECT :: 59; USEROP1 :: 60; USEROP2 :: 61;
    VAARG :: 62; EXTRACTELEMENT :: 63; INSERTELEMENT :: 64; SHUFFLEVECTOR :: 65; EXTRACTVALUE :: 66;
    INSERTVALUE :: 67; LANDINGPAD :: 68; FREEZE :: 69;
}

opcode_name :: (op: Opcode) -> string {
    if op == {
        case .RET; return "ret"; case .BR; return "br"; case .CONDBR; return "br"; case .SWITCH; return "switch";
        case .INDIRECTBR; return "indirectbr"; case .INVOKE; return "invoke"; case .RESUME; return "resume";
        case .UNREACHABLE; return "unreachable"; case .CLEANUPRET; return "cleanupret"; case .CATCHRET; return "catchret";
        case .CATCHSWITCH; return "catchswitch"; case .CALLBR; return "callbr"; case .FNEG; return "fneg";
        case .ADD; return "add"; case .FADD; return "fadd"; case .SUB; return "sub"; case .FSUB; return "fsub";
        case .MUL; return "mul"; case .FMUL; return "fmul"; case .UDIV; return "udiv"; case .SDIV; return "sdiv";
        case .FDIV; return "fdiv"; case .UREM; return "urem"; case .SREM; return "srem"; case .FREM; return "frem";
        case .SHL; return "shl"; case .LSHR; return "lshr"; case .ASHR; return "ashr"; case .AND; return "and";
        case .OR; return "or"; case .XOR; return "xor"; case .ALLOCA; return "alloca"; case .LOAD; return "load";
        case .STORE; return "store"; case .GEP; return "getelementptr"; case .FENCE; return "fence";
        case .CMPXCHG; return "cmpxchg"; case .ATOMICRMW; return "atomicrmw"; case .TRUNC; return "trunc";
        case .ZEXT; return "zext"; case .SEXT; return "sext"; case .FPTOUI; return "fptoui"; case .FPTOSI; return "fptosi";
        case .UITOFP; return "uitofp"; case .SITOFP; return "sitofp"; case .FPTRUNC; return "fptrunc";
        case .FPEXT; return "fpext"; case .PTRTOINT; return "ptrtoint"; case .PTRTOADDR; return "ptrtoaddr";
        case .INTTOPTR; return "inttoptr"; case .BITCAST; return "bitcast"; case .ADDRSPACECAST; return "addrspacecast";
        case .CLEANUPPAD; return "cleanuppad"; case .CATCHPAD; return "catchpad"; case .ICMP; return "icmp";
        case .FCMP; return "fcmp"; case .PHI; return "phi"; case .CALL; return "call"; case .SELECT; return "select";
        case .VAARG; return "va_arg"; case .EXTRACTELEMENT; return "extractelement";
        case .INSERTELEMENT; return "insertelement"; case .SHUFFLEVECTOR; return "shufflevector";
        case .EXTRACTVALUE; return "extractvalue"; case .INSERTVALUE; return "insertvalue";
        case .LANDINGPAD; return "landingpad"; case .FREEZE; return "freeze";
    }
    return "<bad opcode>";
}

is_terminator :: inline (op: Opcode) -> bool { return op >= .RET && op <= .CALLBR; }
is_binary_op  :: inline (op: Opcode) -> bool { return op >= .ADD && op <= .XOR; }
is_cast_op    :: inline (op: Opcode) -> bool { return op >= .TRUNC && op <= .ADDRSPACECAST; }

// Instruction / constant-expression flag bits ("subclass optional data" + misc).
F_NUW      :: 0x1;
F_NSW      :: 0x2;
F_EXACT    :: 0x4;   // also: disjoint (or), nneg (zext/uitofp), samesign (icmp)
F_INBOUNDS :: 0x8;   // GEP
F_NUSW     :: 0x10;  // GEP
F_GEP_NUW  :: 0x20;  // GEP
F_VOLATILE :: 0x40;
F_WEAK     :: 0x80;  // cmpxchg weak
F_INALLOCA :: 0x100;
F_SWIFTERR :: 0x200;
F_INRANGE  :: 0x400; // GEP constant expression with inrange(...)
F_ELEMENTWISE :: 0x800; // atomicrmw elementwise
F_HAS_ALIGN :: 0x1000;
F_CLEANUP  :: 0x2000; // landingpad cleanup
// tail kind in bits 16..17: 0 none, 1 tail, 2 musttail, 3 notail
TAIL_SHIFT :: 16;
// fast-math flags (FastMathFlags order) in bits 24..30
FMF_SHIFT :: 24;
FMF_REASSOC :: 0x01; FMF_NNAN :: 0x02; FMF_NINF :: 0x04; FMF_NSZ :: 0x08; FMF_ARCP :: 0x10; FMF_CONTRACT :: 0x20; FMF_AFN :: 0x40;
FMF_ALL :: 0x7F;

Inst_Row :: struct {
    op:      Opcode;
    pred:    u8;       // icmp/fcmp predicate (CmpInst::Predicate numbering)
    ord1:    u8;       // atomic ordering (success)
    ord2:    u8;       // atomic ordering (failure); atomicrmw: operation
    flags:   u32;
    parent:  Value_Id; // block
    prev:    Value_Id;
    next:    Value_Id;
    ty2:     Type_Id;  // alloca allocated type, GEP source type, call function type
    align:   u64;      // alignment in bytes (0 = none)
    attrs:   u32;      // call attribute list
    cc:      u32;      // calling convention
    idx:     u32;      // start in ir.u32_pool (extract/insertvalue indices, shuffle mask, bundle info)
    nidx:    u32;
    sync:    u32;      // syncscope string id (0 = system)
    addrspace: u32;    // alloca addrspace
}

Block_Row :: struct {
    parent: Value_Id;
    first:  Value_Id;
    last:   Value_Id;
    prev:   Value_Id;
    next:   Value_Id;
}

Linkage :: enum u8 {
    EXTERNAL; AVAILABLE_EXTERNALLY; LINKONCE_ANY; LINKONCE_ODR; WEAK_ANY; WEAK_ODR; APPENDING; INTERNAL;
    PRIVATE; EXTERN_WEAK; COMMON;
}

Global_Row :: struct {
    value_type: Type_Id;
    linkage:    Linkage;
    visibility: u8;     // 0 default, 1 hidden, 2 protected
    dll:        u8;     // 0 default, 1 dllimport, 2 dllexport
    tls:        u8;     // 0 none, 1 general dynamic, 2 local dynamic, 3 initial exec, 4 local exec
    unnamed_addr: u8;   // 0 none, 1 local, 2 global
    dso_local:  bool;
    is_const:   bool;
    ext_init:   bool;
    has_init:   bool;
    addrspace:  u32;
    section:    string;
    partition:  string;
    comdat:     s32 = -1;
    align:      u64;
    pref_align: u64;
    attrs:      u32;     // function: attribute list; global var: attribute set
    cc:         u32;
    gc:         string;
    code_model: u8;      // 0 none, 1 tiny, 2 small, 3 kernel, 4 medium, 5 large
    sanitizer:  u8;      // bits: 1 no_sanitize_address, 2 no_sanitize_hwaddress, 4 sanitize_memtag, 8 dyninit
    has_prefix: bool;
    has_prologue: bool;
    has_personality: bool;
    first_block: Value_Id = NONE;
    last_block:  Value_Id = NONE;
    arg_start:  Value_Id;
    nargs:      u32;
    symtab:     s32 = -1;   // local symbol table index
    intrinsic:  bool;       // name starts with "llvm."
}

// ---------------------------------------------------------------- metadata

Md_Kind :: enum u8 { STRING; VALUE; TUPLE; DI; }

Md_Row :: struct {
    kind:     Md_Kind;
    distinct: bool;
    ops:      u32;   // start in ir.md_ops
    nops:     u32;
    str:      string;
    value:    Value_Id;
}

Attach_Row :: struct {
    kind: u32;
    md:   Md_Id;
    next: u32;
}

Named_Md :: struct {
    name: string;
    ops:  [..] Md_Id;
}

Comdat_Row :: struct {
    name: string;
    kind: u8;   // 0 any, 1 exactmatch, 2 largest, 3 nodeduplicate, 4 samesize
}

// ---------------------------------------------------------------- attributes

// Attr_Kind and ATTR_NAMES are generated: gen_attrs.jai (tablegen order).

Attr :: struct {
    kind: Attr_Kind;
    ival: u64;          // int attrs; Range: bit width
    ty:   Type_Id;      // type attrs (NONE = no type)
    key:  string;       // string attrs
    val:  string;
    lo:   [] u64;       // Range lower / Initializes pairs (words)
    hi:   [] u64;
}

Attr_Set_Row :: struct {
    start: u32;     // in ir.attr_pool
    count: u32;
}

Attr_List_Row :: struct {
    fn:  u32;
    ret: u32;
    params: [] u32;
}

// ---------------------------------------------------------------- the world

IR :: struct {
    // types
    types:      [..] Type_Row;
    type_list:  [..] u32;
    type_map:   Table(string, Type_Id);
    named_types: Table(string, Type_Id);     // identified struct names
    t_void, t_label, t_metadata, t_i1, t_i8, t_i32, t_i64, t_ptr, t_token: Type_Id;

    // values (struct of arrays)
    v_kind:  [..] Value_Kind;
    v_type:  [..] Type_Id;
    v_name:  [..] string;
    v_first_use: [..] Use_Id;
    v_ops:   [..] Use_Id;
    v_nops:  [..] u32;
    v_cap:   [..] u32;
    v_aux:   [..] u32;
    v_md:    [..] u32;      // first attachment row (NONE = none)

    // uses (struct of arrays)
    u_val:   [..] Value_Id;
    u_user:  [..] Value_Id;
    u_next:  [..] Use_Id;
    u_prev:  [..] Use_Id;
    u_aux:   [..] Value_Id;   // phi incoming block

    insts:   [..] Inst_Row;
    blocks:  [..] Block_Row;
    globals: [..] Global_Row;

    // constant payloads
    words:   [..] u64;        // APInt / APFloat words, data-array elements
    cexpr:   [..] Inst_Row;   // constant expression info (op, flags, ty2, idx)
    u32_pool: [..] u32;
    const_map: Table(string, Value_Id);

    // module
    module_id:     string;
    source_filename: string;
    datalayout:    string;
    triple:        string;
    module_asm:    [..] string;
    m_globals:   [..] Value_Id;
    m_functions: [..] Value_Id;
    m_aliases:   [..] Value_Id;
    m_ifuncs:    [..] Value_Id;
    m_symtab:    Table(string, Value_Id);
    m_last_unique: u32;
    comdats:     [..] Comdat_Row;
    comdat_map:  Table(string, s32);
    named_md:    [..] Named_Md;
    sync_scopes: [..] string;

    // local symbol tables
    symtabs:     [..] Table(string, Value_Id);
    symtab_last: [..] u32;

    // metadata
    mds:      [..] Md_Row;
    md_ops:   [..] Md_Id;
    md_map:   Table(string, Md_Id);
    attaches: [..] Attach_Row;
    md_kind_names: [..] string;
    md_kind_map:   Table(string, u32);

    // attributes
    attr_pool:  [..] Attr;
    attr_sets:  [..] Attr_Set_Row;     // 0 = empty
    attr_set_map: Table(string, u32);
    attr_lists: [..] Attr_List_Row;    // 0 = empty
    attr_list_map: Table(string, u32);
}

ir: IR;

// ---------------------------------------------------------------- key building

Key :: struct {
    buf: [..] u8;
}
key_reset :: inline (k: *Key) { k.buf.count = 0; }
key_u8 :: inline (k: *Key, x: u8) { array_add(*k.buf, x); }
key_u32 :: (k: *Key, x: u32) {
    array_add(*k.buf, cast,trunc(u8) x); array_add(*k.buf, cast,trunc(u8)(x >> 8));
    array_add(*k.buf, cast,trunc(u8)(x >> 16)); array_add(*k.buf, cast,trunc(u8)(x >> 24));
}
key_u64 :: (k: *Key, x: u64) { key_u32(k, cast,trunc(u32) x); key_u32(k, cast,trunc(u32)(x >> 32)); }
key_str :: (k: *Key, s: string) {
    key_u32(k, cast(u32) s.count);
    for i: 0..s.count-1 array_add(*k.buf, s[i]);
}
key_view :: inline (k: *Key) -> string { s: string; s.data = k.buf.data; s.count = k.buf.count; return s; }
key_copy :: inline (k: *Key) -> string { return copy_string(key_view(k)); }

tmp_key: Key;

// ---------------------------------------------------------------- strings

intern_str :: (s: string) -> string { return copy_string(s); }

// ---------------------------------------------------------------- types API

new_type_row :: (row: Type_Row) -> Type_Id {
    id := cast(Type_Id) ir.types.count;
    array_add(*ir.types, row);
    return id;
}

intern_type :: (kind: Type_Kind, flags: u8, a: u64, subs: [] Type_Id) -> Type_Id {
    k := *tmp_key; key_reset(k);
    key_u8(k, cast(u8) kind); key_u8(k, flags); key_u64(k, a);
    for subs key_u32(k, it);
    found, id := table_find(*ir.type_map, key_view(k));
    if found return id;
    row: Type_Row;
    row.kind = kind; row.flags = flags; row.a = a;
    row.sub = cast(u32) ir.type_list.count; row.nsub = cast(u32) subs.count;
    for subs array_add(*ir.type_list, it);
    id = new_type_row(row);
    table_add(*ir.type_map, key_copy(k), id);
    return id;
}

type_simple :: (kind: Type_Kind) -> Type_Id { return intern_type(kind, 0, 0, .[]); }
type_int    :: (bits: u64) -> Type_Id { return intern_type(.INT, 0, bits, .[]); }
type_byte   :: (bits: u64) -> Type_Id { return intern_type(.BYTE, 0, bits, .[]); }
type_ptr    :: (as: u64) -> Type_Id { return intern_type(.PTR, 0, as, .[]); }
type_array  :: (n: u64, elt: Type_Id) -> Type_Id { return intern_type(.ARRAY, 0, n, .[elt]); }
type_vector :: (n: u64, elt: Type_Id, scalable: bool) -> Type_Id {
    return intern_type(ifx scalable then Type_Kind.SVECTOR else .VECTOR, 0, n, .[elt]);
}
type_func :: (ret: Type_Id, params: [] Type_Id, vararg: bool) -> Type_Id {
    subs: [..] Type_Id; subs.allocator = temp;
    array_add(*subs, ret);
    for params array_add(*subs, it);
    return intern_type(.FUNC, ifx vararg then cast(u8) TYF_VARARG else 0, 0, subs);
}
type_literal_struct :: (elts: [] Type_Id, packed: bool) -> Type_Id {
    flags: u8 = TYF_LITERAL;
    if packed flags |= TYF_PACKED;
    return intern_type(.STRUCT, flags, 0, elts);
}
// Identified struct: fresh row, body set later.
type_named_struct :: (name: string) -> Type_Id {
    row: Type_Row;
    row.kind = .STRUCT; row.flags = TYF_OPAQUE; row.name = name;
    return new_type_row(row);
}
set_struct_body :: (t: Type_Id, elts: [] Type_Id, packed: bool) {
    r := *ir.types[t];
    r.flags &= ~cast(u8)(TYF_OPAQUE | TYF_PACKED);
    if packed r.flags |= TYF_PACKED;
    r.sub = cast(u32) ir.type_list.count; r.nsub = cast(u32) elts.count;
    for elts array_add(*ir.type_list, it);
}

type_kind :: inline (t: Type_Id) -> Type_Kind { return ir.types[t].kind; }
type_sub  :: inline (t: Type_Id, i: u32) -> Type_Id { return ir.type_list[ir.types[t].sub + i]; }
type_nsub :: inline (t: Type_Id) -> u32 { return ir.types[t].nsub; }
type_int_width :: inline (t: Type_Id) -> u32 { return cast(u32) ir.types[t].a; }
type_elem :: inline (t: Type_Id) -> Type_Id { return type_sub(t, 0); }
type_count :: inline (t: Type_Id) -> u64 { return ir.types[t].a; }
is_vector_type :: inline (t: Type_Id) -> bool { k := type_kind(t); return k == .VECTOR || k == .SVECTOR; }
scalar_type :: (t: Type_Id) -> Type_Id { if is_vector_type(t) return type_elem(t); return t; }
is_fp_kind :: inline (k: Type_Kind) -> bool { return k >= .HALF && k <= .PPC_FP128; }
is_fp_type :: inline (t: Type_Id) -> bool { return is_fp_kind(type_kind(t)); }
is_int_type :: inline (t: Type_Id) -> bool { return type_kind(t) == .INT; }
is_ptr_type :: inline (t: Type_Id) -> bool { return type_kind(t) == .PTR; }
is_first_class :: (t: Type_Id) -> bool { k := type_kind(t); return k != .VOID && k != .FUNC; }
func_ret :: inline (ft: Type_Id) -> Type_Id { return type_sub(ft, 0); }
func_nparams :: inline (ft: Type_Id) -> u32 { return type_nsub(ft) - 1; }
func_param :: inline (ft: Type_Id, i: u32) -> Type_Id { return type_sub(ft, i + 1); }
func_vararg :: inline (ft: Type_Id) -> bool { return (ir.types[ft].flags & TYF_VARARG) != 0; }
is_aggregate :: (t: Type_Id) -> bool { k := type_kind(t); return k == .STRUCT || k == .ARRAY; }

// Number of bits of an fp type's significand precision (APFloat semantics).
fp_semantics :: (k: Type_Kind) -> (precision: s32, max_exp: s32, min_exp: s32, bits: s32) {
    if k == {
        case .HALF;     return 11, 15, -14, 16;
        case .BFLOAT;   return 8, 127, -126, 16;
        case .FLOAT;    return 24, 127, -126, 32;
        case .DOUBLE;   return 53, 1023, -1022, 64;
        case .X86_FP80; return 64, 16383, -16382, 80;
        case .FP128;    return 113, 16383, -16382, 128;
        case .PPC_FP128; return 106, 1023, -1022, 128;
    }
    return 0, 0, 0, 0;
}

// Primitive size in bits (for constant word counts).
type_bits :: (t: Type_Id) -> u32 {
    k := type_kind(t);
    if k == .INT || k == .BYTE return cast(u32) ir.types[t].a;
    if is_fp_kind(k) { p, mx, mn, b := fp_semantics(k); return cast(u32) b; }
    return 0;
}
words_for_bits :: inline (bits: u32) -> u32 { return (bits + 63) / 64; }

// ---------------------------------------------------------------- values API

new_value :: (kind: Value_Kind, type: Type_Id, nops: u32, aux: u32 = 0) -> Value_Id {
    id := cast(Value_Id) ir.v_kind.count;
    array_add(*ir.v_kind, kind);
    array_add(*ir.v_type, type);
    array_add(*ir.v_name, "");
    array_add(*ir.v_first_use, NONE);
    start := cast(Use_Id) ir.u_val.count;
    for 0..cast(s64)nops-1 {
        array_add(*ir.u_val, NONE);
        array_add(*ir.u_user, id);
        array_add(*ir.u_next, NONE);
        array_add(*ir.u_prev, NONE);
        array_add(*ir.u_aux, NONE);
    }
    array_add(*ir.v_ops, start);
    array_add(*ir.v_nops, nops);
    array_add(*ir.v_cap, nops);
    array_add(*ir.v_aux, aux);
    array_add(*ir.v_md, NONE);
    return id;
}

vkind :: inline (v: Value_Id) -> Value_Kind { return ir.v_kind[v]; }
vtype :: inline (v: Value_Id) -> Type_Id { return ir.v_type[v]; }
vname :: inline (v: Value_Id) -> string { return ir.v_name[v]; }
nops  :: inline (v: Value_Id) -> u32 { return ir.v_nops[v]; }
op_use :: inline (v: Value_Id, i: u32) -> Use_Id { return ir.v_ops[v] + i; }
op :: inline (v: Value_Id, i: u32) -> Value_Id { return ir.u_val[ir.v_ops[v] + i]; }

// Use-list primitives (llvm/include/llvm/IR/Use.h): new uses go to the FRONT of the list.
use_remove_from_list :: (u: Use_Id) {
    v := ir.u_val[u];
    if v == NONE return;
    nxt := ir.u_next[u];
    prv := ir.u_prev[u];
    if prv == NONE ir.v_first_use[v] = nxt;
    else ir.u_next[prv] = nxt;
    if nxt != NONE ir.u_prev[nxt] = prv;
    ir.u_next[u] = NONE; ir.u_prev[u] = NONE;
}
use_add_to_list :: (u: Use_Id, v: Value_Id) {
    head := ir.v_first_use[v];
    ir.u_next[u] = head;
    ir.u_prev[u] = NONE;
    if head != NONE ir.u_prev[head] = u;
    ir.v_first_use[v] = u;
}
// Use::set
use_set :: (u: Use_Id, v: Value_Id) {
    if ir.u_val[u] != NONE use_remove_from_list(u);
    ir.u_val[u] = v;
    if v != NONE use_add_to_list(u, v);
}
set_op :: inline (user: Value_Id, i: u32, v: Value_Id) { use_set(ir.v_ops[user] + i, v); }

has_uses :: inline (v: Value_Id) -> bool { return ir.v_first_use[v] != NONE; }
num_uses :: (v: Value_Id) -> int {
    n := 0; u := ir.v_first_use[v];
    while u != NONE { n += 1; u = ir.u_next[u]; }
    return n;
}

// Grow a user's operand storage to at least `cap` slots, relocating the operand range to the end of the use
// table and patching use-list links (mirrors LLVM's hung-off operand growth, which keeps use-list positions).
grow_ops :: (user: Value_Id, cap: u32) {
    if ir.v_cap[user] >= cap return;
    old := ir.v_ops[user];
    n := ir.v_nops[user];
    start := cast(Use_Id) ir.u_val.count;
    for 0..cast(s64)cap-1 {
        array_add(*ir.u_val, NONE);
        array_add(*ir.u_user, user);
        array_add(*ir.u_next, NONE);
        array_add(*ir.u_prev, NONE);
        array_add(*ir.u_aux, NONE);
    }
    for i: 0..cast(s64)n-1 {
        ou := old + cast(u32) i;
        nu := start + cast(u32) i;
        v := ir.u_val[ou];
        ir.u_val[nu] = v;
        ir.u_aux[nu] = ir.u_aux[ou];
        if v != NONE {
            nx := ir.u_next[ou]; pv := ir.u_prev[ou];
            ir.u_next[nu] = nx; ir.u_prev[nu] = pv;
            if pv == NONE ir.v_first_use[v] = nu; else ir.u_next[pv] = nu;
            if nx != NONE ir.u_prev[nx] = nu;
        }
        ir.u_val[ou] = NONE; ir.u_next[ou] = NONE; ir.u_prev[ou] = NONE; ir.u_user[ou] = NONE;
    }
    ir.v_ops[user] = start;
    ir.v_cap[user] = cap;
}

// Append an operand (phi addIncoming, switch addCase, ...).
add_op :: (user: Value_Id, v: Value_Id, aux: Value_Id = NONE) -> u32 {
    n := ir.v_nops[user];
    if n + 1 > ir.v_cap[user] {
        newcap := ifx ir.v_cap[user] < 2 then 4 else ir.v_cap[user] * 2;
        if newcap < n + 1 newcap = n + 1;
        grow_ops(user, newcap);
    }
    ir.v_nops[user] = n + 1;
    u := ir.v_ops[user] + n;
    ir.u_aux[u] = aux;
    use_set(u, v);
    return n;
}

drop_all_references :: (user: Value_Id) {
    start := ir.v_ops[user];
    for i: 0..cast(s64)ir.v_nops[user]-1 use_set(start + cast(u32) i, NONE);
}

// Value::replaceAllUsesWith (llvm/lib/IR/Value.cpp doRAUW): take the head use each time.
// Constant users are re-uniqued like Constant::handleOperandChange.
replace_all_uses_with :: (old: Value_Id, new: Value_Id) {
    while ir.v_first_use[old] != NONE {
        u := ir.v_first_use[old];
        user := ir.u_user[u];
        if is_constant_kind(vkind(user)) && !is_global_value(vkind(user)) {
            constant_handle_operand_change(user, old, new);
            continue;
        }
        use_set(u, new);
    }
}

// ---------------------------------------------------------------- names / symbol tables

new_symtab :: () -> s32 {
    t: Table(string, Value_Id);
    array_add(*ir.symtabs, t);
    array_add(*ir.symtab_last, 0);
    return cast(s32)(ir.symtabs.count - 1);
}

value_symtab :: (v: Value_Id) -> s32 {
    k := vkind(v);
    if is_global_value(k) return -1;
    fnv := value_function(v);
    if fnv == NONE return -2;
    return ir.globals[ir.v_aux[fnv]].symtab;
}

value_function :: (v: Value_Id) -> Value_Id {
    k := vkind(v);
    if k == .ARGUMENT return arg_parent(v);
    if k == .BLOCK return ir.blocks[ir.v_aux[v]].parent;
    if k == .INST {
        b := ir.insts[ir.v_aux[v]].parent;
        if b == NONE return NONE;
        return ir.blocks[ir.v_aux[b]].parent;
    }
    return NONE;
}

// Arguments store their parent function in a side array.
arg_parents: [..] Value_Id;   // indexed by v_aux of ARGUMENT (= argument row)
arg_numbers: [..] u32;
arg_parent :: inline (v: Value_Id) -> Value_Id { return arg_parents[ir.v_aux[v]]; }

// ValueSymbolTable::makeUniqueName
make_unique_name :: (tab: *Table(string, Value_Id), last: *u32, base: string, v: Value_Id, is_global: bool) -> string {
    sb: String_Builder;
    while true {
        reset(*sb);
        append(*sb, base);
        if is_global append(*sb, ".");
        last.* += 1;
        append_u64(*sb, last.*);
        s := builder_to_string(*sb);
        if !table_contains(tab, s) {
            table_add(tab, s, v);
            return s;
        }
    }
    return "";
}

// Value::setName: inserts into the symbol table, uniquing on conflict.
set_name :: (v: Value_Id, name: string) {
    old := ir.v_name[v];
    if old == name return;
    st := value_symtab(v);
    if old.count != 0 {
        if st == -1 table_remove(*ir.m_symtab, old);
        else if st >= 0 table_remove(*ir.symtabs[st], old);
    }
    if name.count == 0 { ir.v_name[v] = ""; return; }
    if st == -2 { ir.v_name[v] = intern_str(name); return; }
    tab := ifx st == -1 then *ir.m_symtab else *ir.symtabs[st];
    last := ifx st == -1 then *ir.m_last_unique else *ir.symtab_last[st];
    if !table_contains(tab, name) {
        s := intern_str(name);
        table_add(tab, s, v);
        ir.v_name[v] = s;
        return;
    }
    ir.v_name[v] = make_unique_name(tab, last, name, v, st == -1);
}

lookup_global :: (name: string) -> Value_Id {
    found, v := table_find(*ir.m_symtab, name);
    if found return v;
    return NONE;
}

// ---------------------------------------------------------------- instruction / block lists

new_inst :: (op: Opcode, type: Type_Id, nops: u32) -> Value_Id {
    row: Inst_Row;
    row.op = op; row.parent = NONE; row.prev = NONE; row.next = NONE; row.ty2 = NONE;
    aux := cast(u32) ir.insts.count;
    array_add(*ir.insts, row);
    return new_value(.INST, type, nops, aux);
}
inst :: inline (v: Value_Id) -> *Inst_Row { return *ir.insts[ir.v_aux[v]]; }
inst_op :: inline (v: Value_Id) -> Opcode { return ir.insts[ir.v_aux[v]].op; }

new_block :: (fnv: Value_Id) -> Value_Id {
    row: Block_Row;
    row.parent = fnv; row.first = NONE; row.last = NONE; row.prev = NONE; row.next = NONE;
    aux := cast(u32) ir.blocks.count;
    array_add(*ir.blocks, row);
    return new_value(.BLOCK, ir.t_label, 0, aux);
}
block :: inline (b: Value_Id) -> *Block_Row { return *ir.blocks[ir.v_aux[b]]; }

block_append_inst :: (b: Value_Id, i: Value_Id) {
    br := block(b);
    ir_ := inst(i);
    ir_.parent = b;
    ir_.prev = br.last;
    ir_.next = NONE;
    if br.last != NONE inst(br.last).next = i; else br.first = i;
    br.last = i;
}

inst_insert_before :: (i: Value_Id, pos: Value_Id) {
    b := inst(pos).parent;
    br := block(b);
    r := inst(i);
    r.parent = b;
    p := inst(pos).prev;
    r.prev = p; r.next = pos;
    inst(pos).prev = i;
    if p != NONE inst(p).next = i; else br.first = i;
}

inst_unlink :: (i: Value_Id) {
    r := inst(i);
    b := r.parent;
    if b == NONE return;
    br := block(b);
    if r.prev != NONE inst(r.prev).next = r.next; else br.first = r.next;
    if r.next != NONE inst(r.next).prev = r.prev; else br.last = r.prev;
    r.prev = NONE; r.next = NONE; r.parent = NONE;
}

erase_inst :: (i: Value_Id) {
    assert(!has_uses(i), "erasing an instruction that still has uses");
    if ir.v_name[i].count set_name(i, "");
    inst_unlink(i);
    drop_all_references(i);
    ir.v_md[i] = NONE;
    ir.v_kind[i] = .DEAD;
}

fn_append_block :: (fnv: Value_Id, b: Value_Id) {
    g := *ir.globals[ir.v_aux[fnv]];
    br := block(b);
    br.parent = fnv;
    br.prev = g.last_block; br.next = NONE;
    if g.last_block != NONE block(g.last_block).next = b; else g.first_block = b;
    g.last_block = b;
}
fn_unlink_block :: (fnv: Value_Id, b: Value_Id) {
    g := *ir.globals[ir.v_aux[fnv]];
    br := block(b);
    if br.prev != NONE block(br.prev).next = br.next; else g.first_block = br.next;
    if br.next != NONE block(br.next).prev = br.prev; else g.last_block = br.prev;
    br.prev = NONE; br.next = NONE;
}

// ---------------------------------------------------------------- globals

new_global :: (kind: Value_Kind, value_type: Type_Id, addrspace: u32, nops: u32) -> Value_Id {
    row: Global_Row;
    row.value_type = value_type;
    row.addrspace = addrspace;
    aux := cast(u32) ir.globals.count;
    array_add(*ir.globals, row);
    return new_value(kind, type_ptr(addrspace), nops, aux);
}
glob :: inline (v: Value_Id) -> *Global_Row { return *ir.globals[ir.v_aux[v]]; }

new_function :: (ft: Type_Id, name: string, addrspace: u32) -> Value_Id {
    // operands: personality, prefix, prologue (hung off, like LLVM)
    f := new_global(.FUNCTION, ft, addrspace, 3);
    g := glob(f);
    g.symtab = new_symtab();
    np := func_nparams(ft);
    g.nargs = np;
    g.arg_start = cast(Value_Id) ir.v_kind.count;
    for i: 0..cast(s64)np-1 {
        row := cast(u32) arg_parents.count;
        array_add(*arg_parents, f);
        array_add(*arg_numbers, cast(u32) i);
        new_value(.ARGUMENT, func_param(ft, cast(u32) i), 0, row);
    }
    if name.count {
        set_name(f, name);
        if begins_with(name, "llvm.") g.intrinsic = true;
    }
    return f;
}
fn_arg :: inline (f: Value_Id, i: u32) -> Value_Id { return glob(f).arg_start + i; }
is_declaration :: (v: Value_Id) -> bool {
    k := vkind(v);
    if k == .FUNCTION return glob(v).first_block == NONE;
    if k == .GLOBAL_VAR return !glob(v).has_init;
    return false;
}

remove_from_list :: (list: *[..] Value_Id, v: Value_Id) {
    for list.* if it == v { array_ordered_remove_by_index(list, it_index); return; }
}

erase_global :: (v: Value_Id) {
    k := vkind(v);
    if k == .GLOBAL_VAR remove_from_list(*ir.m_globals, v);
    else if k == .FUNCTION remove_from_list(*ir.m_functions, v);
    else if k == .ALIAS remove_from_list(*ir.m_aliases, v);
    else if k == .IFUNC remove_from_list(*ir.m_ifuncs, v);
    if ir.v_name[v].count set_name(v, "");
    drop_all_references(v);
    ir.v_kind[v] = .DEAD;
}

// ---------------------------------------------------------------- constants

// Interning key for a constant: kind, type, payload, operands.
const_key_begin :: (kind: Value_Kind, type: Type_Id) -> *Key {
    k := *tmp_key; key_reset(k);
    key_u8(k, cast(u8) kind); key_u32(k, type);
    return k;
}

const_lookup_or_create :: (k: *Key, kind: Value_Kind, type: Type_Id, ops: [] Value_Id, aux: u32) -> Value_Id, bool {
    found, v := table_find(*ir.const_map, key_view(k));
    if found return v, false;
    keycopy := key_copy(k);
    v = new_value(kind, type, cast(u32) ops.count, aux);
    for ops set_op(v, cast(u32) it_index, it);
    table_add(*ir.const_map, keycopy, v);
    const_keys_set(v, keycopy);
    return v, true;
}

const_keys: Table(Value_Id, string);
const_keys_set :: (v: Value_Id, key: string) { table_set(*const_keys, v, key); }

norm_words :: (type: Type_Id, words: [] u64) -> [] u64 {
    n := words_for_bits(type_bits(scalar_type(type)));
    if n == words.count return words;
    r := NewArray(n, u64,, allocator = temp);
    if n > 0 for i: 0..n-1 if i < words.count r[i] = words[i];
    return r;
}

const_int_words :: (type: Type_Id, words_in: [] u64) -> Value_Id {
    words := norm_words(type, words_in);
    k := const_key_begin(.C_INT, type);
    for words key_u64(k, it);
    found, v := table_find(*ir.const_map, key_view(k));
    if found return v;
    aux := cast(u32) ir.words.count;
    for words array_add(*ir.words, it);
    v = const_lookup_or_create(k, .C_INT, type, .[], aux);
    return v;
}

// Truncate words to the scalar bit width.
mask_words :: (words: [] u64, bits: u32) {
    nw := words_for_bits(bits);
    for i: nw..words.count-1 words[i] = 0;
    r := bits % 64;
    if r != 0 && nw > 0 words[nw - 1] &= ((cast(u64)1) << r) - 1;
}

const_int :: (type: Type_Id, value: u64) -> Value_Id {
    bits := type_bits(scalar_type(type));
    nw := words_for_bits(bits);
    w: [..] u64; w.allocator = temp;
    array_resize(*w, nw);
    w[0] = value;
    // sign-extend negative 64-bit values into the upper words
    if (cast(s64) value) < 0 for i: 1..nw-1 w[i] = 0xFFFF_FFFF_FFFF_FFFF;
    mask_words(w, bits);
    return const_int_words(type, w);
}
const_int_value :: (v: Value_Id) -> [] u64 {
    bits := type_bits(scalar_type(vtype(v)));
    nw := words_for_bits(bits);
    r: [] u64;
    r.data = ir.words.data + ir.v_aux[v];
    r.count = nw;
    return r;
}
const_int_zext :: (v: Value_Id) -> u64 { return ir.words[ir.v_aux[v]]; }
const_int_sext :: (v: Value_Id) -> s64 {
    bits := type_bits(scalar_type(vtype(v)));
    x := ir.words[ir.v_aux[v]];
    if bits >= 64 return cast,no_check(s64) x;
    sh := 64 - bits;
    return (cast,no_check(s64)(x << sh)) >> sh;
}

const_fp_words :: (type: Type_Id, words_in: [] u64) -> Value_Id {
    words := norm_words(type, words_in);
    k := const_key_begin(.C_FP, type);
    for words key_u64(k, it);
    found, v := table_find(*ir.const_map, key_view(k));
    if found return v;
    aux := cast(u32) ir.words.count;
    for words array_add(*ir.words, it);
    return const_lookup_or_create(k, .C_FP, type, .[], aux);
}
const_fp_value :: (v: Value_Id) -> [] u64 {
    bits := type_bits(scalar_type(vtype(v)));
    r: [] u64;
    r.data = ir.words.data + ir.v_aux[v];
    r.count = words_for_bits(bits);
    return r;
}

const_simple :: (kind: Value_Kind, type: Type_Id) -> Value_Id {
    k := const_key_begin(kind, type);
    v := const_lookup_or_create(k, kind, type, .[], 0);
    return v;
}
const_null  :: (type: Type_Id) -> Value_Id { return const_simple(.C_NULL, type); }
const_zero  :: (type: Type_Id) -> Value_Id { return const_simple(.C_ZERO, type); }
const_undef :: (type: Type_Id) -> Value_Id { return const_simple(.C_UNDEF, type); }
const_poison :: (type: Type_Id) -> Value_Id { return const_simple(.C_POISON, type); }

// Constant::getNullValue
const_null_value :: (type: Type_Id) -> Value_Id {
    k := type_kind(type);
    if k == .INT || k == .BYTE return const_int(type, 0);
    if is_fp_kind(k) { w: [2] u64; return const_fp_words(type, w); }
    if k == .PTR return const_null(type);
    if k == .TOKEN return const_simple(.C_TOKEN_NONE, type);
    if k == .VECTOR || k == .SVECTOR {
        ek := type_kind(type_elem(type));
        if is_fp_kind(ek) { w: [2] u64; return const_fp_words(type, w); }
        if ek == .PTR return const_null(type);
    }
    return const_zero(type);
}

is_null_value :: (v: Value_Id) -> bool {
    k := vkind(v);
    if k == .C_NULL || k == .C_ZERO || k == .C_TOKEN_NONE return true;
    if k == .C_INT || k == .C_FP {
        for const_int_value(v) if it != 0 return false;
        if k == .C_FP {
            // +0.0 only (bit pattern zero)
        }
        return true;
    }
    return false;
}

// ConstantDataSequential: element values stored in words (one u64 per element; fp as bit pattern).
const_data :: (type: Type_Id, elts: [] u64) -> Value_Id {
    k := const_key_begin(.C_DATA, type);
    for elts key_u64(k, it);
    found, v := table_find(*ir.const_map, key_view(k));
    if found return v;
    aux := cast(u32) ir.words.count;
    for elts array_add(*ir.words, it);
    return const_lookup_or_create(k, .C_DATA, type, .[], aux);
}
const_data_count :: (v: Value_Id) -> u64 { return type_count(vtype(v)); }
const_data_elt :: (v: Value_Id, i: u64) -> u64 { return ir.words[ir.v_aux[v] + i]; }

const_aggregate_raw :: (kind: Value_Kind, type: Type_Id, ops: [] Value_Id) -> Value_Id {
    k := const_key_begin(kind, type);
    for ops key_u32(k, it);
    v := const_lookup_or_create(k, kind, type, ops, 0);
    return v;
}

// Can the element be stored in a ConstantDataSequential? (ConstantDataSequential::isElementTypeCompatible)
data_compatible_elt :: (t: Type_Id) -> bool {
    k := type_kind(t);
    if k == .HALF || k == .BFLOAT || k == .FLOAT || k == .DOUBLE return true;
    if k == .INT || k == .BYTE { w := type_int_width(t); return w == 8 || w == 16 || w == 32 || w == 64; }
    return false;
}

// ConstantArray::get / ConstantVector::get / ConstantStruct::get with LLVM's canonicalizations
// (llvm/lib/IR/Constants.cpp ConstantArray::getImpl, ConstantVector::getImpl, ConstantStruct::get).
const_aggregate :: (kind: Value_Kind, type: Type_Id, ops: [] Value_Id) -> Value_Id {
    if kind == .C_STRUCT {
        is_zero := true; is_undef := false; is_poison := false;
        if ops.count {
            is_undef = vkind(ops[0]) == .C_UNDEF || vkind(ops[0]) == .C_POISON;
            is_poison = vkind(ops[0]) == .C_POISON;
            is_zero = is_null_value(ops[0]);
            if is_undef || is_zero {
                for ops {
                    if !is_null_value(it) is_zero = false;
                    if vkind(it) != .C_POISON is_poison = false;
                    if vkind(it) == .C_POISON || vkind(it) != .C_UNDEF is_undef = false;
                }
            }
        }
        if is_zero return const_zero(type);
        if is_poison return const_poison(type);
        if is_undef return const_undef(type);
        return const_aggregate_raw(kind, type, ops);
    }
    c := ops[0];
    all_same := true;
    for ops if it != c { all_same = false; break; }
    ck := vkind(c);
    if kind == .C_ARRAY {
        if all_same {
            if ck == .C_POISON return const_poison(type);
            if ck == .C_UNDEF return const_undef(type);
            if is_null_value(c) return const_zero(type);
        }
    } else {
        if all_same {
            if ck == .C_NULL return const_null(type);
            if is_null_value(c) return const_zero(type);
            if ck == .C_POISON return const_poison(type);
            if ck == .C_UNDEF return const_undef(type);
            if ck == .C_FP return const_fp_words(type, const_fp_value(c));
        }
    }
    et := type_elem(type);
    if data_compatible_elt(et) {
        want := ifx is_fp_type(et) then Value_Kind.C_FP else .C_INT;
        all_match := true;
        for ops if vkind(it) != want { all_match = false; break; }
        if all_match {
            elts: [..] u64; elts.allocator = temp;
            for ops array_add(*elts, ir.words[ir.v_aux[it]]);
            all_zero := true;
            for elts if it != 0 all_zero = false;
            if all_zero return const_zero(type);
            return const_data(type, elts);
        }
    }
    return const_aggregate_raw(kind, type, ops);
}

// Constant expression (getelementptr, casts, binary ops, ...). info carries op/flags/ty2/idx.
const_expr :: (op: Opcode, type: Type_Id, flags: u32, ty2: Type_Id, ops: [] Value_Id, extra: [] u32 = .[]) -> Value_Id {
    k := const_key_begin(.C_EXPR, type);
    key_u8(k, cast(u8) op); key_u32(k, flags); key_u32(k, ty2);
    key_u32(k, cast(u32) extra.count); for extra key_u32(k, it);
    for ops key_u32(k, it);
    found, v := table_find(*ir.const_map, key_view(k));
    if found return v;
    row: Inst_Row;
    row.op = op; row.flags = flags; row.ty2 = ty2;
    row.idx = cast(u32) ir.u32_pool.count; row.nidx = cast(u32) extra.count;
    for extra array_add(*ir.u32_pool, it);
    aux := cast(u32) ir.cexpr.count;
    array_add(*ir.cexpr, row);
    v = const_lookup_or_create(k, .C_EXPR, type, ops, aux);
    return v;
}
cexpr :: inline (v: Value_Id) -> *Inst_Row { return *ir.cexpr[ir.v_aux[v]]; }

const_blockaddr :: (fnv: Value_Id, bb: Value_Id) -> Value_Id {
    k := const_key_begin(.C_BLOCKADDR, ir.t_ptr);
    key_u32(k, fnv); key_u32(k, bb);
    v := const_lookup_or_create(k, .C_BLOCKADDR, type_ptr(glob(fnv).addrspace), .[fnv, bb], 0);
    return v;
}

// Constant::handleOperandChange: re-unique the constant with `from` replaced by `to`.
constant_handle_operand_change :: (c: Value_Id, from: Value_Id, to: Value_Id) {
    n := nops(c);
    newops: [..] Value_Id; newops.allocator = temp;
    if n > 0 for i: 0..n-1 { o := op(c, i); array_add(*newops, ifx o == from then to else o); }
    kind := vkind(c);
    type := vtype(c);
    repl: Value_Id = NONE;
    if kind == .C_EXPR {
        e := cexpr(c);
        extra: [] u32; extra.data = ir.u32_pool.data + e.idx; extra.count = e.nidx;
        repl = const_expr(e.op, type, e.flags, e.ty2, newops, extra);
    } else if kind == .C_ARRAY || kind == .C_STRUCT || kind == .C_VECTOR {
        repl = const_aggregate(kind, type, newops);
    } else if kind == .C_BLOCKADDR {
        repl = const_blockaddr(newops[0], newops[1]);
    } else if kind == .C_DSO_EQUIV || kind == .C_NO_CFI {
        k := const_key_begin(kind, type); key_u32(k, newops[0]);
        repl = const_lookup_or_create(k, kind, type, newops, 0);
    } else {
        // generic: just move the use
        if n > 0 for i: 0..n-1 if op(c, i) == from { set_op(c, i, to); }
        return;
    }
    if repl == c return;
    replace_all_uses_with(c, repl);
    // destroyConstant: drop from the map and its operand uses
    found, key := table_find(*const_keys, c);
    if found {
        f2, cur := table_find(*ir.const_map, key);
        if f2 && cur == c table_remove(*ir.const_map, key);
    }
    drop_all_references(c);
    ir.v_kind[c] = .DEAD;
}

// ---------------------------------------------------------------- metadata API

md_kind_id :: (name: string) -> u32 {
    found, id := table_find(*ir.md_kind_map, name);
    if found return id;
    id = cast(u32) ir.md_kind_names.count;
    s := intern_str(name);
    array_add(*ir.md_kind_names, s);
    table_add(*ir.md_kind_map, s, id);
    return id;
}

md_string :: (s: string) -> Md_Id {
    k := *tmp_key; key_reset(k); key_u8(k, 0); key_str(k, s);
    found, id := table_find(*ir.md_map, key_view(k));
    if found return id;
    row: Md_Row; row.kind = .STRING; row.str = intern_str(s);
    id = cast(Md_Id) ir.mds.count;
    array_add(*ir.mds, row);
    table_add(*ir.md_map, key_copy(k), id);
    return id;
}

md_value :: (v: Value_Id) -> Md_Id {
    k := *tmp_key; key_reset(k); key_u8(k, 1); key_u32(k, v);
    found, id := table_find(*ir.md_map, key_view(k));
    if found return id;
    row: Md_Row; row.kind = .VALUE; row.value = v;
    id = cast(Md_Id) ir.mds.count;
    array_add(*ir.mds, row);
    table_add(*ir.md_map, key_copy(k), id);
    return id;
}

md_tuple :: (ops: [] Md_Id, distinct: bool) -> Md_Id {
    k := *tmp_key;
    if !distinct {
        key_reset(k); key_u8(k, 2);
        for ops key_u32(k, it);
        found, id := table_find(*ir.md_map, key_view(k));
        if found return id;
    }
    row: Md_Row; row.kind = .TUPLE; row.distinct = distinct;
    row.ops = cast(u32) ir.md_ops.count; row.nops = cast(u32) ops.count;
    for ops array_add(*ir.md_ops, it);
    id := cast(Md_Id) ir.mds.count;
    array_add(*ir.mds, row);
    if !distinct table_add(*ir.md_map, key_copy(k), id);
    return id;
}

// Placeholder node for forward references (a temporary distinct tuple; its content is replaced later).
md_temp :: () -> Md_Id {
    row: Md_Row; row.kind = .TUPLE; row.distinct = true;
    id := cast(Md_Id) ir.mds.count;
    array_add(*ir.mds, row);
    return id;
}

md_op :: inline (m: Md_Id, i: u32) -> Md_Id { return ir.md_ops[ir.mds[m].ops + i]; }

// Instruction::setMetadata / GlobalObject::setMetadata: one attachment per kind, insertion order kept.
set_metadata :: (v: Value_Id, kind: u32, md: Md_Id) {
    a := ir.v_md[v];
    prev: u32 = NONE;
    while a != NONE {
        if ir.attaches[a].kind == kind {
            if md == NONE {
                if prev == NONE ir.v_md[v] = ir.attaches[a].next; else ir.attaches[prev].next = ir.attaches[a].next;
            } else ir.attaches[a].md = md;
            return;
        }
        prev = a; a = ir.attaches[a].next;
    }
    if md == NONE return;
    row: Attach_Row; row.kind = kind; row.md = md; row.next = NONE;
    id := cast(u32) ir.attaches.count;
    array_add(*ir.attaches, row);
    if prev == NONE ir.v_md[v] = id; else ir.attaches[prev].next = id;
}
add_metadata :: (v: Value_Id, kind: u32, md: Md_Id) {  // GlobalObject::addMetadata (allows duplicates)
    a := ir.v_md[v]; prev: u32 = NONE;
    while a != NONE { prev = a; a = ir.attaches[a].next; }
    row: Attach_Row; row.kind = kind; row.md = md; row.next = NONE;
    id := cast(u32) ir.attaches.count;
    array_add(*ir.attaches, row);
    if prev == NONE ir.v_md[v] = id; else ir.attaches[prev].next = id;
}
get_metadata :: (v: Value_Id, kind: u32) -> Md_Id {
    a := ir.v_md[v];
    while a != NONE { if ir.attaches[a].kind == kind return ir.attaches[a].md; a = ir.attaches[a].next; }
    return NONE;
}

// getAllMetadata: stable sort by kind id (dbg = 0 first).
Kind_Md :: struct { kind: u32; md: Md_Id; }
get_all_metadata :: (v: Value_Id, out: *[..] Kind_Md) {
    out.count = 0;
    a := ir.v_md[v];
    while a != NONE {
        array_add(out, .{ir.attaches[a].kind, ir.attaches[a].md});
        a = ir.attaches[a].next;
    }
    // insertion sort (stable)
    for i: 1..out.count-1 {
        x := out.*[i];
        j := i - 1;
        while j >= 0 && out.*[j].kind > x.kind { out.*[j + 1] = out.*[j]; j -= 1; }
        out.*[j + 1] = x;
    }
}

// ---------------------------------------------------------------- attributes API

attr_less :: (a: *Attr, b: *Attr) -> bool {
    as := a.kind == .STRING_ATTR; bs := b.kind == .STRING_ATTR;
    if !as {
        if bs return true;
        if a.kind != b.kind return a.kind < b.kind;
        return a.ival < b.ival;
    }
    if !bs return false;
    c := compare(a.key, b.key);
    if c != 0 return c < 0;
    return compare(a.val, b.val) < 0;
}

attr_key :: (k: *Key, a: *Attr) {
    key_u8(k, cast(u8) a.kind); key_u64(k, a.ival); key_u32(k, a.ty);
    key_str(k, a.key); key_str(k, a.val);
    key_u32(k, cast(u32) a.lo.count); for a.lo key_u64(k, it);
    key_u32(k, cast(u32) a.hi.count); for a.hi key_u64(k, it);
}

// AttributeSet::get: sorts, dedups by kind (last one wins like AttrBuilder), interns.
attr_set_get :: (attrs_in: [] Attr) -> u32 {
    if attrs_in.count == 0 return 0;
    attrs: [..] Attr; attrs.allocator = temp;
    for attrs_in {
        // AttrBuilder semantics: adding an attribute of an existing kind replaces it
        replaced := false;
        for * a: attrs {
            same := ifx it.kind == .STRING_ATTR then (a.kind == .STRING_ATTR && a.key == it.key) else a.kind == it.kind;
            if same { a.* = it; replaced = true; break; }
        }
        if !replaced array_add(*attrs, it);
    }
    for i: 1..attrs.count-1 {
        x := attrs[i];
        j := i - 1;
        while j >= 0 && attr_less(*x, *attrs[j]) { attrs[j + 1] = attrs[j]; j -= 1; }
        attrs[j + 1] = x;
    }
    k := *tmp_key; key_reset(k);
    for * attrs attr_key(k, it);
    found, id := table_find(*ir.attr_set_map, key_view(k));
    if found return id;
    if ir.attr_sets.count == 0 array_add(*ir.attr_sets, .{0, 0});
    row: Attr_Set_Row; row.start = cast(u32) ir.attr_pool.count; row.count = cast(u32) attrs.count;
    for attrs {
        a := it;
        a.key = intern_str(a.key); a.val = intern_str(a.val);
        if a.lo.count { lo := NewArray(a.lo.count, u64); for a.lo lo[it_index] = it; a.lo = lo; }
        if a.hi.count { hi := NewArray(a.hi.count, u64); for a.hi hi[it_index] = it; a.hi = hi; }
        array_add(*ir.attr_pool, a);
    }
    id = cast(u32) ir.attr_sets.count;
    array_add(*ir.attr_sets, row);
    table_add(*ir.attr_set_map, key_copy(k), id);
    return id;
}

attr_set_items :: (s: u32) -> [] Attr {
    r: [] Attr;
    if s == 0 return r;
    row := ir.attr_sets[s];
    r.data = ir.attr_pool.data + row.start;
    r.count = row.count;
    return r;
}

attr_set_has :: (s: u32, kind: Attr_Kind) -> bool {
    for attr_set_items(s) if it.kind == kind return true;
    return false;
}
attr_set_find :: (s: u32, kind: Attr_Kind) -> *Attr {
    items := attr_set_items(s);
    for * items if it.kind == kind return it;
    return null;
}

// Merge two sets (AttrBuilder::merge: b's attributes override a's).
attr_set_merge :: (a: u32, b: u32) -> u32 {
    if b == 0 return a;
    if a == 0 return b;
    all: [..] Attr; all.allocator = temp;
    for attr_set_items(a) array_add(*all, it);
    for attr_set_items(b) array_add(*all, it);
    return attr_set_get(all);
}

attr_set_remove :: (s: u32, kind: Attr_Kind) -> u32 {
    if !attr_set_has(s, kind) return s;
    all: [..] Attr; all.allocator = temp;
    for attr_set_items(s) if it.kind != kind array_add(*all, it);
    return attr_set_get(all);
}

// AttributeList::get: trailing empty param sets are dropped.
attr_list_get :: (fn: u32, ret: u32, params_in: [] u32) -> u32 {
    np := params_in.count;
    while np > 0 && params_in[np - 1] == 0 np -= 1;
    if fn == 0 && ret == 0 && np == 0 return 0;
    k := *tmp_key; key_reset(k);
    key_u32(k, fn); key_u32(k, ret);
    if np > 0 for i: 0..np-1 key_u32(k, params_in[i]);
    found, id := table_find(*ir.attr_list_map, key_view(k));
    if found return id;
    if ir.attr_lists.count == 0 { e: Attr_List_Row; array_add(*ir.attr_lists, e); }
    row: Attr_List_Row; row.fn = fn; row.ret = ret;
    row.params = NewArray(np, u32);
    if np > 0 for i: 0..np-1 row.params[i] = params_in[i];
    id = cast(u32) ir.attr_lists.count;
    array_add(*ir.attr_lists, row);
    table_add(*ir.attr_list_map, key_copy(k), id);
    return id;
}
attr_list_fn  :: (l: u32) -> u32 { if l == 0 return 0; return ir.attr_lists[l].fn; }
attr_list_ret :: (l: u32) -> u32 { if l == 0 return 0; return ir.attr_lists[l].ret; }
attr_list_param :: (l: u32, i: u32) -> u32 {
    if l == 0 return 0;
    p := ir.attr_lists[l].params;
    if i >= p.count return 0;
    return p[i];
}
attr_list_with_fn :: (l: u32, fn: u32) -> u32 {
    if l == 0 return attr_list_get(fn, 0, .[]);
    r := ir.attr_lists[l];
    return attr_list_get(fn, r.ret, r.params);
}

// ---------------------------------------------------------------- init

ir_init :: () {
    // Fixed metadata kinds (llvm/include/llvm/IR/FixedMetadataKinds.def)
    for FIXED_MD_KINDS md_kind_id(it);
    ir.t_void = type_simple(.VOID);
    ir.t_label = type_simple(.LABEL);
    ir.t_metadata = type_simple(.METADATA);
    ir.t_token = type_simple(.TOKEN);
    ir.t_i1 = type_int(1);
    ir.t_i8 = type_int(8);
    ir.t_i32 = type_int(32);
    ir.t_i64 = type_int(64);
    ir.t_ptr = type_ptr(0);
    array_add(*ir.attr_sets, .{0, 0});
    e: Attr_List_Row; array_add(*ir.attr_lists, e);
    array_add(*ir.sync_scopes, "");          // system
    array_add(*ir.sync_scopes, "singlethread");
}

FIXED_MD_KINDS :: string.[
    "dbg", "tbaa", "prof", "fpmath", "range", "tbaa.struct", "invariant.load", "alias.scope", "noalias",
    "nontemporal", "llvm.mem.parallel_loop_access", "nonnull", "dereferenceable", "dereferenceable_or_null",
    "make.implicit", "unpredictable", "invariant.group", "align", "llvm.loop", "type", "section_prefix",
    "absolute_symbol", "associated", "callees", "irr_loop", "llvm.access.group", "callback",
    "llvm.preserve.access.index", "vcall_visibility", "noundef", "annotation", "nosanitize", "func_sanitize",
    "exclude", "memprof", "callsite", "kcfi_type", "pcsections", "DIAssignID", "coro.outside.frame", "mmra",
    "noalias.addrspace", "callee_type", "nofree", "captures", "alloc_token", "implicit.ref", "nofpclass",
    "call_target", "inline_history", "elf_section_properties", "guid", "mem.cache_hint",
    "block.uniformity.profile", "callgraph",
];

// ---------------------------------------------------------------- small helpers

append_u64 :: (sb: *String_Builder, x: u64) {
    buf: [24] u8;
    n := 0;
    if x == 0 { append(sb, #char "0"); return; }
    while x > 0 { buf[n] = cast(u8)(#char "0" + x % 10); x /= 10; n += 1; }
    while n > 0 { n -= 1; append(sb, buf[n]); }
}
append_s64 :: (sb: *String_Builder, x: s64) {
    if x < 0 { append(sb, #char "-"); append_u64(sb, cast,no_check(u64)(-x)); }
    else append_u64(sb, cast(u64) x);
}

fatal :: (fmt: string, args: .. Any) {
    s := tprint(fmt, ..args);
    write_string(tprint("%: error: %\n", tool_name, s), to_standard_error = true);
    exit(1);
}

tool_name := "opt";

#import "Basic";
#import "String";
#import "Hash_Table";
