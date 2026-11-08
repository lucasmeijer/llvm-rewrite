// The IR core: global id-indexed tables (see DESIGN.md).
// Mirrors llvm/include/llvm/IR/{Value,Use,User,Type,Constants,Instruction,BasicBlock,Function}.h.
import std;
import os;
import gen_attrs;

// ---------------------------------------------------------------------------------------------
// Errors

fn fatal(msg: const u8[:]) {
    write_stderr("error: ");
    write_stderr(msg);
    write_stderr("\n");
    exit(1);
}

// ---------------------------------------------------------------------------------------------
// Strings: one byte pool, interned ids.

struct Str { off: i32, len: i32, hash: u32 }

var chars: u8[>..];
var strs: Str[>..];
var str_tab: i32[>..<];

fn hash_bytes(s: const u8[:]) -> u32 {
    var h: u32 = 2166136261;
    for c in s { h = (h ^ c) * 16777619; }
    return h;
}

fn sbytes(id: i32) -> const u8[:] {
    let s = strs[id];
    return chars[s.off..s.off + s.len];
}

fn ht_rebuild_strs() {
    var n: i64 = 64;
    while n < (strs.len + 1) * 2 { n *= 2; }
    str_tab.clear();
    str_tab.resize(n, -1);
    let mask = n - 1;
    for s, i in strs {
        var j = (s.hash as i64) & mask;
        while str_tab[j] >= 0 { j = (j + 1) & mask; }
        str_tab[j] = i as i32;
    }
}

fn intern(s: const u8[:]) -> i32 {
    if str_tab.len == 0 || (strs.len + 1) * 2 > str_tab.len { ht_rebuild_strs(); }
    let h = hash_bytes(s);
    let mask = str_tab.len - 1;
    var j = (h as i64) & mask;
    loop {
        let e = str_tab[j];
        if e < 0 { break; }
        if strs[e].hash == h && sbytes(e) == s { return e; }
        j = (j + 1) & mask;
    }
    let id = strs.len as i32;
    let off = chars.len as i32;
    chars.append(s);
    strs.push(Str { off: off, len: s.len as i32, hash: h });
    str_tab[j] = id;
    return id;
}

// A string that is not interned (e.g. a big c"..." payload): appended to the pool, id returned.
fn str_concat2(a: const u8[:], b: const u8[:]) -> i32 {
    var tmp: u8[>..] = [];
    tmp.append(a);
    tmp.append(b);
    return intern(tmp);
}

// ---------------------------------------------------------------------------------------------
// Small integer pool for variable-length runs (type elements, indices, masks, …).

var ints: i32[>..];
var words: u64[>..];

fn ints_push_run(xs: const i32[:]) -> i32 {
    let at = ints.len as i32;
    for x in xs { ints.push(x); }
    return at;
}

// ---------------------------------------------------------------------------------------------
// Types (llvm/IR/Type.h, DerivedTypes.h). Uniqued: equal types have equal ids.

let TK_VOID = 0;
let TK_HALF = 1;
let TK_BFLOAT = 2;
let TK_FLOAT = 3;
let TK_DOUBLE = 4;
let TK_X86_FP80 = 5;
let TK_FP128 = 6;
let TK_PPC_FP128 = 7;
let TK_LABEL = 8;
let TK_METADATA = 9;
let TK_X86_AMX = 10;
let TK_TOKEN = 11;
let TK_INT = 12;
let TK_FUNC = 13;
let TK_PTR = 14;
let TK_STRUCT = 15;
let TK_ARRAY = 16;
let TK_FVEC = 17;
let TK_SVEC = 18;
let TK_TARGETEXT = 19;
let TK_BYTE = 20;          // byte type bN: n = bits

let TF_VARARG: u8 = 1;
let TF_PACKED: u8 = 2;
let TF_NAMED: u8 = 4;
let TF_OPAQUE: u8 = 8;     // named struct with no body (yet)
let TF_HASBODY: u8 = 16;

// n: int bits / ptr addrspace; a: element type or start of elements in `ints`; cnt: element count.
struct Ty { kind: u8, flags: u8, n: i32, a: i32, cnt: i64, name: i32, hash: u32 }

var types: Ty[>..];
var type_tab: i32[>..<];
var named_types: i32[>..];      // identified structs, creation order

fn ty_hash(t: Ty) -> u32 {
    var h: u32 = (t.kind as u32) * 31 + (t.flags as u32) * 7919;
    h = (h ^ (t.n as! u32)) * 16777619;
    h = (h ^ (t.cnt as! u32)) * 16777619;
    if t.kind == TK_FUNC || t.kind == TK_STRUCT || t.kind == TK_TARGETEXT {
        for k in t.cnt { h = (h ^ (ints[t.a + k] as! u32)) * 16777619; }
        if t.kind == TK_TARGETEXT { h = (h ^ (t.name as! u32)) * 16777619; }
    } else {
        h = (h ^ (t.a as! u32)) * 16777619;
    }
    return h;
}

fn ty_eq(x: Ty, y: Ty) -> bool {
    if x.kind != y.kind || x.flags != y.flags || x.n != y.n || x.cnt != y.cnt { return false; }
    if x.kind == TK_FUNC || x.kind == TK_STRUCT || x.kind == TK_TARGETEXT {
        if x.kind == TK_TARGETEXT && x.name != y.name { return false; }
        for k in x.cnt { if ints[x.a + k] != ints[y.a + k] { return false; } }
        return true;
    }
    return x.a == y.a;
}

fn rebuild_type_tab() {
    var n: i64 = 256;
    while n < (types.len + 1) * 2 { n *= 2; }
    type_tab.clear();
    type_tab.resize(n, -1);
    let mask = n - 1;
    for t, i in types {
        if (t.flags & TF_NAMED) != 0 { continue; }
        var j = (t.hash as i64) & mask;
        while type_tab[j] >= 0 { j = (j + 1) & mask; }
        type_tab[j] = i as i32;
    }
}

// Interns a (non-named) type. For FUNC/STRUCT, t.a must point at a run in `ints` (may be dropped if found).
fn ty_get(t0: Ty) -> i32 {
    var t = t0;
    t.hash = ty_hash(t);
    if type_tab.len == 0 || (types.len + 1) * 2 > type_tab.len { rebuild_type_tab(); }
    let mask = type_tab.len - 1;
    var j = (t.hash as i64) & mask;
    loop {
        let e = type_tab[j];
        if e < 0 { break; }
        if types[e].hash == t.hash && ty_eq(types[e], t) { return e; }
        j = (j + 1) & mask;
    }
    let id = types.len as i32;
    types.push(t);
    type_tab[j] = id;
    return id;
}

fn ty_simple(kind: i64) -> i32 { ty_get(Ty { kind: kind as u8, flags: 0, n: 0, a: 0, cnt: 0, name: -1, hash: 0 }) }
fn ty_int(bits: i64) -> i32 { ty_get(Ty { kind: TK_INT, flags: 0, n: bits as i32, a: 0, cnt: 0, name: -1, hash: 0 }) }
fn ty_byte(bits: i64) -> i32 { ty_get(Ty { kind: TK_BYTE, flags: 0, n: bits as i32, a: 0, cnt: 0, name: -1, hash: 0 }) }
fn ty_ptr(as_: i64) -> i32 { ty_get(Ty { kind: TK_PTR, flags: 0, n: as_ as i32, a: 0, cnt: 0, name: -1, hash: 0 }) }
fn ty_array(elem: i32, n: i64) -> i32 { ty_get(Ty { kind: TK_ARRAY, flags: 0, n: 0, a: elem, cnt: n, name: -1, hash: 0 }) }
fn ty_vector(elem: i32, n: i64, scalable: bool) -> i32 {
    let k: u8 = if scalable { TK_SVEC } else { TK_FVEC };
    return ty_get(Ty { kind: k, flags: 0, n: 0, a: elem, cnt: n, name: -1, hash: 0 });
}
// elems: a run already pushed into ints at `at` of length n.
fn ty_struct_run(at: i32, n: i64, packed: bool) -> i32 {
    let fl = if packed { TF_PACKED } else { 0 as u8 };
    let mark = ints.len;
    let id = ty_get(Ty { kind: TK_STRUCT, flags: fl, n: 0, a: at, cnt: n, name: -1, hash: 0 });
    return id;
}
fn ty_func_run(at: i32, n: i64, vararg: bool) -> i32 {
    let fl = if vararg { TF_VARARG } else { 0 as u8 };
    return ty_get(Ty { kind: TK_FUNC, flags: fl, n: 0, a: at, cnt: n, name: -1, hash: 0 });
}
// TargetExtType: name string id; ints run at `at`: [ntypes, type params..., int params...], n = run length.
fn ty_target_ext(name: i32, at: i32, n: i64) -> i32 {
    return ty_get(Ty { kind: TK_TARGETEXT, flags: 0, n: 0, a: at, cnt: n, name: name, hash: 0 });
}
fn ty_target_ntypes(t: i32) -> i64 { ints[types[t].a] as i64 }
fn ty_target_type(t: i32, k: i64) -> i32 { ints[types[t].a + 1 + k] }
fn ty_target_nints(t: i32) -> i64 { types[t].cnt - 1 - ty_target_ntypes(t) }
fn ty_target_int(t: i32, k: i64) -> i64 { ints[types[t].a + 1 + ty_target_ntypes(t) + k] as i64 }

fn ty_named_struct(name: i32) -> i32 {
    let id = types.len as i32;
    types.push(Ty { kind: TK_STRUCT, flags: TF_NAMED | TF_OPAQUE, n: 0, a: 0, cnt: 0, name: name, hash: 0 });
    named_types.push(id);
    return id;
}
fn ty_set_body(t: i32, at: i32, n: i64, packed: bool) {
    types[t].a = at;
    types[t].cnt = n;
    var fl = (types[t].flags & ~TF_OPAQUE) | TF_HASBODY;
    if packed { fl |= TF_PACKED; }
    types[t].flags = fl;
}

var T_VOID: i32 = -1;
var T_LABEL: i32 = -1;
var T_METADATA: i32 = -1;
var T_I1: i32 = -1;
var T_I8: i32 = -1;
var T_I32: i32 = -1;
var T_I64: i32 = -1;
var T_PTR: i32 = -1;
var T_FLOAT: i32 = -1;
var T_DOUBLE: i32 = -1;
var T_TOKEN: i32 = -1;

fn init_types() {
    T_VOID = ty_simple(TK_VOID);
    T_LABEL = ty_simple(TK_LABEL);
    T_METADATA = ty_simple(TK_METADATA);
    T_TOKEN = ty_simple(TK_TOKEN);
    T_I1 = ty_int(1);
    T_I8 = ty_int(8);
    T_I32 = ty_int(32);
    T_I64 = ty_int(64);
    T_PTR = ty_ptr(0);
    T_FLOAT = ty_simple(TK_FLOAT);
    T_DOUBLE = ty_simple(TK_DOUBLE);
}

fn ty_kind(t: i32) -> u8 { types[t].kind }
fn ty_is_int(t: i32) -> bool { types[t].kind == TK_INT }
fn ty_is_fp(t: i32) -> bool { let k = types[t].kind; k >= TK_HALF && k <= TK_PPC_FP128 }
fn ty_is_vector(t: i32) -> bool { let k = types[t].kind; k == TK_FVEC || k == TK_SVEC }
fn ty_is_struct(t: i32) -> bool { types[t].kind == TK_STRUCT }
fn ty_is_array(t: i32) -> bool { types[t].kind == TK_ARRAY }
fn ty_is_aggregate(t: i32) -> bool { let k = types[t].kind; k == TK_STRUCT || k == TK_ARRAY }
fn ty_bits(t: i32) -> i64 { types[t].n as i64 }
fn ty_elem(t: i32) -> i32 { types[t].a }
fn ty_count(t: i32) -> i64 { types[t].cnt }
fn ty_scalar(t: i32) -> i32 { if ty_is_vector(t) { types[t].a } else { t } }
// The k-th element of a struct, or the parameter k-1 / return (k = 0) of a function.
fn ty_field(t: i32, k: i64) -> i32 { ints[types[t].a + k] }
fn ty_fn_ret(t: i32) -> i32 { ints[types[t].a] }
fn ty_fn_nparams(t: i32) -> i64 { types[t].cnt - 1 }
fn ty_fn_param(t: i32, k: i64) -> i32 { ints[types[t].a + 1 + k] }
fn ty_fn_vararg(t: i32) -> bool { (types[t].flags & TF_VARARG) != 0 }
fn ty_is_first_class(t: i32) -> bool { let k = types[t].kind; k != TK_VOID && k != TK_FUNC }

// Element type at index k of an aggregate or vector.
fn ty_index(t: i32, k: i64) -> i32 {
    if types[t].kind == TK_STRUCT { return ints[types[t].a + k]; }
    return types[t].a;
}

// ---------------------------------------------------------------------------------------------
// Values (llvm/IR/Value.h). One id space for everything.

let VK_FUNC = 0;
let VK_ALIAS = 1;
let VK_IFUNC = 2;
let VK_GVAR = 3;
let VK_BLOCKADDR = 4;
let VK_CEXPR = 5;
let VK_DSOLOCAL = 6;
let VK_NOCFI = 7;
let VK_PTRAUTH = 8;
let VK_CARRAY = 9;
let VK_CSTRUCT = 10;
let VK_CVECTOR = 11;
// ConstantData (no use lists) from here to VK_CTOKENNONE.
let VK_UNDEF = 12;
let VK_POISON = 13;
let VK_AGGZERO = 14;
let VK_CDARRAY = 15;
let VK_CDVECTOR = 16;
let VK_CINT = 17;
let VK_CFP = 18;
let VK_CTARGETNONE = 19;
let VK_CNULL = 20;
let VK_CTOKENNONE = 21;
let VK_ARG = 22;
let VK_BLOCK = 23;
let VK_MDVAL = 24;
let VK_INLINEASM = 25;
let VK_INST = 26;
let VK_FWD = 27;       // forward-reference placeholder in the parser
let VK_DEAD = 28;

struct Val { kind: u8, flags: u8, ty: i32, sub: i32, name: i32, first_use: i32, ops: i32, nops: i32, cap: i32 }

var vals: Val[>..];

fn is_constant(v: i32) -> bool { vals[v].kind <= VK_CTOKENNONE }
fn is_constant_data(v: i32) -> bool { let k = vals[v].kind; k >= VK_UNDEF && k <= VK_CTOKENNONE }
fn is_global(v: i32) -> bool { vals[v].kind <= VK_GVAR }
fn has_use_list(v: i32) -> bool { !is_constant_data(v) }
fn vty(v: i32) -> i32 { vals[v].ty }
fn vkind(v: i32) -> u8 { vals[v].kind }

fn new_val(kind: i64, ty: i32, sub: i32, nops: i64) -> i32 {
    let id = vals.len as i32;
    let at = alloc_uses(id, nops);
    vals.push(Val { kind: kind as u8, flags: 0, ty: ty, sub: sub, name: -1, first_use: -1, ops: at, nops: nops as i32, cap: nops as i32 });
    return id;
}

// ---------------------------------------------------------------------------------------------
// Uses (llvm/IR/Use.h). Operand runs in one pool, intrusive doubly linked use lists.

struct Use { val: i32, user: i32, next: i32, prev: i32 }

var uses: Use[>..];
var use_aux: i32[>..];             // parallel: PHI incoming block (value id) etc.
var free_runs: i32[32];            // free operand runs by log2 capacity; linked through uses[].next

fn log2_ceil(n: i64) -> i64 { var k = 0; while (1 << k) < n { k++; } return k; }

fn alloc_uses(user: i32, n: i64) -> i32 {
    if n == 0 { return uses.len as i32; }
    let at = uses.len as i32;
    for k in n {
        uses.push(Use { val: -1, user: user, next: -1, prev: -1 });
        use_aux.push(-1);
    }
    return at;
}

fn op(user: i32, k: i64) -> i32 { uses[vals[user].ops + k].val }
fn nops(user: i32) -> i64 { vals[user].nops as i64 }
fn op_aux(user: i32, k: i64) -> i32 { use_aux[vals[user].ops + k] }

fn use_unlink(u: i32) {
    let v = uses[u].val;
    if v < 0 || !has_use_list(v) { return; }
    let p = uses[u].prev;
    let n = uses[u].next;
    if p >= 0 { uses[p].next = n; } else { vals[v].first_use = n; }
    if n >= 0 { uses[n].prev = p; }
    uses[u].next = -1;
    uses[u].prev = -1;
}

// Use::set: unlink, then push at the head of the new value's list (Use::addToList).
fn use_set(u: i32, v: i32) {
    use_unlink(u);
    uses[u].val = v;
    if v < 0 || !has_use_list(v) { return; }
    let head = vals[v].first_use;
    uses[u].next = head;
    uses[u].prev = -1;
    if head >= 0 { uses[head].prev = u; }
    vals[v].first_use = u;
}

fn set_op(user: i32, k: i64, v: i32) { use_set(vals[user].ops + k as i32, v); }

// User::growHungoffUses: copy the run to a new one of capacity ncap. Each copied use is `set` (pushed at the
// head of its value's use list) in operand order, then the old uses are destroyed (unlinked) last to first.
fn grow_ops(user: i32, ncap: i64) {
    let n = vals[user].nops as i64;
    let old = vals[user].ops;
    let at = uses.len as i32;
    for k in ncap {
        uses.push(Use { val: -1, user: user, next: -1, prev: -1 });
        use_aux.push(-1);
    }
    for k in n {
        use_set(at + k as i32, uses[old + k].val);
        use_aux[at + k] = use_aux[old + k];
    }
    var k = n;
    while k > 0 { k--; use_unlink(old + k as i32); uses[old + k].val = -1; }
    vals[user].ops = at;
    vals[user].cap = ncap as i32;
}

// Appends one operand slot. Growth policy of PHINode::growOperands (n + n/2, at least 2); SwitchInst and
// IndirectBrInst callers grow with grow_ops themselves (3n / 2n) before calling this.
fn add_op_slot(user: i32) -> i64 {
    let n = vals[user].nops as i64;
    if n == vals[user].cap as i64 {
        var ncap = n + n / 2;
        if ncap < 2 { ncap = 2; }
        grow_ops(user, ncap);
    }
    vals[user].nops = (n + 1) as i32;
    return n;
}

fn push_op(user: i32, v: i32) -> i64 {
    let k = add_op_slot(user);
    set_op(user, k, v);
    return k;
}

fn drop_all_refs(user: i32) {
    for k in vals[user].nops { set_op(user, k, -1); }
}

// Value::doRAUW: repeatedly take the head use and point it at `nv` (which reverses the order).
fn rauw(old: i32, nv: i32) {
    while vals[old].first_use >= 0 {
        let u = vals[old].first_use;
        use_set(u, nv);
    }
}

fn first_use(v: i32) -> i32 { vals[v].first_use }
fn use_next(u: i32) -> i32 { uses[u].next }
fn use_user(u: i32) -> i32 { uses[u].user }
fn has_uses(v: i32) -> bool { vals[v].first_use >= 0 }

// ---------------------------------------------------------------------------------------------
// Constants (llvm/IR/Constants.h). Uniqued like LLVMContextImpl's maps.

// lo/hi: integer words 0 and 1 (or FP bit pattern); ext: index into `words` for ints wider than 128.
// For constant expressions: op, pred, flags, ty2 (GEP source type), aux/naux (indices in `ints`).
struct Cst { lo: u64, hi: u64, ext: i32, op: u8, pred: u8, flags: u8, ty2: i32, aux: i32, naux: i32, hash: u32, inr: i32 }

var csts: Cst[>..];
var cst_tab: i32[>..<];
var cst_count: i64 = 0;

fn cst_hash(kind: i64, ty: i32, c: Cst, opsv: const i32[:]) -> u32 {
    var h: u32 = (kind as u32) * 2654435761 + (ty as! u32) * 40503;
    h = (h ^ (c.lo as! u32)) * 16777619;
    h = (h ^ ((c.lo >> 32) as! u32)) * 16777619;
    h = (h ^ (c.hi as! u32)) * 16777619;
    h = (h ^ ((c.hi >> 32) as! u32)) * 16777619;
    h = (h ^ (c.op as u32) ^ ((c.pred as u32) << 8) ^ ((c.flags as u32) << 16)) * 16777619;
    h = (h ^ (c.ty2 as! u32)) * 16777619;
    h = (h ^ (c.inr as! u32)) * 16777619;
    for x in opsv { h = (h ^ (x as! u32)) * 16777619; }
    if c.ext >= 0 {
        let nw = (ty_bits(ty) + 63) / 64;
        for k in nw { h = (h ^ (words[c.ext + k] as! u32)) * 16777619; }
    }
    for k in c.naux { h = (h ^ (ints[c.aux + k] as! u32)) * 16777619; }
    return h;
}

fn cst_eq(v: i32, kind: i64, ty: i32, c: Cst, opsv: const i32[:]) -> bool {
    let x = vals[v];
    if x.kind as i64 != kind || x.ty != ty { return false; }
    let d = csts[x.sub];
    if d.lo != c.lo || d.hi != c.hi || d.op != c.op || d.pred != c.pred || d.flags != c.flags || d.ty2 != c.ty2 || d.naux != c.naux || d.inr != c.inr { return false; }
    if x.nops as i64 != opsv.len { return false; }
    for k in opsv.len { if uses[x.ops + k].val != opsv[k] { return false; } }
    if (d.ext >= 0) != (c.ext >= 0) { return false; }
    if c.ext >= 0 {
        let nw = (ty_bits(ty) + 63) / 64;
        for k in nw { if words[d.ext + k] != words[c.ext + k] { return false; } }
    }
    for k in c.naux { if ints[d.aux + k] != ints[c.aux + k] { return false; } }
    return true;
}

fn rebuild_cst_tab() {
    var n: i64 = 1024;
    while n < (cst_count + 1) * 2 { n *= 2; }
    cst_tab.clear();
    cst_tab.resize(n, -1);
    let mask = n - 1;
    for v, i in vals {
        if v.kind > VK_CTOKENNONE || v.kind <= VK_GVAR { continue; }
        if v.kind == VK_BLOCKADDR { }
        var j = (csts[v.sub].hash as i64) & mask;
        while cst_tab[j] >= 0 { j = (j + 1) & mask; }
        cst_tab[j] = i as i32;
    }
}

fn cst_none() -> Cst { Cst { lo: 0, hi: 0, ext: -1, op: 0, pred: 0, flags: 0, ty2: -1, aux: 0, naux: 0, hash: 0, inr: -1 } }

fn cst_get(kind: i64, ty: i32, c0: Cst, opsv: const i32[:]) -> i32 {
    var c = c0;
    c.hash = cst_hash(kind, ty, c, opsv);
    if cst_tab.len == 0 || (cst_count + 1) * 2 > cst_tab.len { rebuild_cst_tab(); }
    let mask = cst_tab.len - 1;
    var j = (c.hash as i64) & mask;
    loop {
        let e = cst_tab[j];
        if e < 0 { break; }
        if csts[vals[e].sub].hash == c.hash && cst_eq(e, kind, ty, c, opsv) { return e; }
        j = (j + 1) & mask;
    }
    let sub = csts.len as i32;
    csts.push(c);
    let id = new_val(kind, ty, sub, opsv.len);
    for k in opsv.len { set_op(id, k, opsv[k]); }
    cst_tab[j] = id;
    cst_count += 1;
    return id;
}

fn c_int_words(ty: i32, lo: u64, hi: u64) -> i32 {
    var c = cst_none();
    let bits = ty_bits(ty);
    var l = lo;
    var h = hi;
    if bits < 64 { l = l & ((1 << bits) - 1); h = 0; }
    else if bits == 64 { h = 0; }
    else if bits < 128 { h = h & ((1 << (bits - 64)) - 1); }
    c.lo = l;
    c.hi = h;
    return cst_get(VK_CINT, ty, c, []);
}
fn c_int(ty: i32, v: i64) -> i32 {
    let hi: u64 = if v < 0 { 0xFFFFFFFFFFFFFFFF } else { 0 };
    if ty_bits(ty) > 128 { return c_int_wide_sext(ty, v); }
    return c_int_words(ty, v as! u64, hi);
}
fn c_int_wide(ty: i32, ws: const u64[:]) -> i32 {
    let bits = ty_bits(ty);
    let nw = (bits + 63) / 64;
    var c = cst_none();
    let at = words.len as i32;
    for k in nw { words.push(if k < ws.len { ws[k] } else { 0 }); }
    let r = bits % 64;
    if r != 0 { words[at + nw - 1] = words[at + nw - 1] & ((1 << r) - 1); }
    c.ext = at;
    c.lo = words[at];
    c.hi = words[at + 1];
    return cst_get(VK_CINT, ty, c, []);
}
fn c_int_wide_sext(ty: i32, v: i64) -> i32 {
    let nw = (ty_bits(ty) + 63) / 64;
    var ws: u64[>..] = [];
    for k in nw { ws.push(if k == 0 { v as! u64 } else if v < 0 { 0xFFFFFFFFFFFFFFFF } else { 0 }); }
    return c_int_wide(ty, ws);
}
fn c_fp(ty: i32, lo: u64, hi: u64) -> i32 {
    var c = cst_none();
    c.lo = lo;
    c.hi = hi;
    return cst_get(VK_CFP, ty, c, []);
}
fn c_simple(kind: i64, ty: i32) -> i32 { cst_get(kind, ty, cst_none(), []) }
fn c_null(ty: i32) -> i32 {
    let k = types[ty].kind;
    if k == TK_INT { return c_int(ty, 0); }
    if k == TK_PTR { return c_simple(VK_CNULL, ty); }
    if k >= TK_HALF && k <= TK_PPC_FP128 { return c_fp(ty, 0, 0); }
    if k == TK_TOKEN { return c_simple(VK_CTOKENNONE, ty); }
    if k == TK_TARGETEXT { return c_simple(VK_CTARGETNONE, ty); }
    // LLVM 23: a null vector of pointers is a vector-typed ConstantPointerNull (printed "splat (ptr null)")
    if (k == TK_FVEC || k == TK_SVEC) && types[types[ty].a].kind == TK_PTR { return c_simple(VK_CNULL, ty); }
    if (k == TK_FVEC || k == TK_SVEC) && ty_is_fp(types[ty].a) { return c_fp_vec_zero(ty); }
    return c_simple(VK_AGGZERO, ty);
}
// LLVM 23 has two zero vectors of FP elements, both printed `zeroinitializer`: Constant::getNullValue (and
// ConstantVector::getSplat of 0.0) gives a vector-typed ConstantFP, ConstantVector::get of all-null elements a
// ConstantAggregateZero. Both are VK_AGGZERO here; the ConstantFP one has flags = 1 (a distinct constant, as in
// LLVM). Only code that dyn_casts to ConstantFP tells them apart: `c_is_vector_cfp`.
fn c_fp_vec_zero(ty: i32) -> i32 {
    var c = cst_none();
    c.flags = 1;
    return cst_get(VK_AGGZERO, ty, c, []);
}
// dyn_cast<ConstantFP> of a vector constant succeeds: LLVM's FP splats (all elements the same ConstantFP) and
// the getNullValue zero vector (see c_fp_vec_zero)
fn c_is_vector_cfp(v: i32) -> bool {
    let ty = vals[v].ty;
    if !ty_is_vector(ty) || !ty_is_fp(types[ty].a) { return false; }
    let k = vals[v].kind;
    if k == VK_CFP { return true; }
    if k == VK_AGGZERO { return csts[vals[v].sub].flags == 1; }
    if k == VK_CDVECTOR || k == VK_CVECTOR {
        let n = vals[v].nops as i64;
        let f = op(v, 0);
        if vals[f].kind != VK_CFP { return false; }
        for i in 1..n { if op(v, i) != f { return false; } }
        return true;
    }
    return false;
}
fn c_undef(ty: i32) -> i32 { c_simple(VK_UNDEF, ty) }
fn c_poison(ty: i32) -> i32 { c_simple(VK_POISON, ty) }
fn c_true() -> i32 { c_int(T_I1, 1) }
fn c_false() -> i32 { c_int(T_I1, 0) }

fn cint_lo(v: i32) -> u64 { csts[vals[v].sub].lo }
fn cint_hi(v: i32) -> u64 { csts[vals[v].sub].hi }
fn cint_sext(v: i32) -> i64 {
    let bits = ty_bits(vals[v].ty);
    let lo = csts[vals[v].sub].lo;
    if bits >= 64 { return lo as! i64; }
    let sh = 64 - bits;
    return ((lo << sh) as! i64) >> sh;
}
fn cint_is_zero(v: i32) -> bool {
    let c = csts[vals[v].sub];
    if c.ext >= 0 {
        let nw = (ty_bits(vals[v].ty) + 63) / 64;
        for k in nw { if words[c.ext + k] != 0 { return false; } }
        return true;
    }
    return c.lo == 0 && c.hi == 0;
}

fn is_null_value(v: i32) -> bool {
    let k = vals[v].kind;
    if k == VK_CINT { return cint_is_zero(v); }
    if k == VK_CFP { return csts[vals[v].sub].lo == 0 && csts[vals[v].sub].hi == 0; }
    return k == VK_CNULL || k == VK_AGGZERO || k == VK_CTOKENNONE || k == VK_CTARGETNONE;
}

// Is this element "simple data" (ConstantDataSequential::isElementTypeCompatible)?
fn is_cds_elem_ty(t: i32) -> bool {
    let k = types[t].kind;
    if k == TK_HALF || k == TK_BFLOAT || k == TK_FLOAT || k == TK_DOUBLE { return true; }
    if k == TK_INT { let b = types[t].n; return b == 8 || b == 16 || b == 32 || b == 64; }
    return false;
}

// ConstantArray::get / ConstantStruct::get / ConstantVector::get with LLVM's canonicalizations.
fn c_aggregate(ty: i32, elems: const i32[:]) -> i32 {
    let k = types[ty].kind;
    if elems.len == 0 {
        return c_simple(VK_AGGZERO, ty);
    }
    // ConstantStruct::get / ConstantArray::getImpl / ConstantVector::getImpl: all poison -> poison,
    // all undef (no poison) -> undef, all null -> zeroinitializer (a vector of null pointers stays a
    // ConstantPointerNull); arrays and vectors need all elements identical.
    var all_poison = true;
    var all_undef = true;
    var all_null = true;
    var all_same = true;
    for e in elems {
        let ek = vals[e].kind;
        if ek != VK_POISON { all_poison = false; }
        if ek != VK_UNDEF { all_undef = false; }
        if !is_null_value(e) { all_null = false; }
        if e != elems[0] { all_same = false; }
    }
    if k != TK_STRUCT && !all_same { all_poison = false; all_undef = false; all_null = false; }
    if (k == TK_FVEC || k == TK_SVEC) && all_same && vals[elems[0]].kind == VK_CNULL { return c_simple(VK_CNULL, ty); }
    if all_null { return c_simple(VK_AGGZERO, ty); }
    if all_poison { return c_poison(ty); }
    if all_undef { return c_undef(ty); }
    if k == TK_STRUCT { return cst_get(VK_CSTRUCT, ty, cst_none(), elems); }
    let et = types[ty].a;
    if is_cds_elem_ty(et) {
        var all_simple = true;
        for e in elems { let ek = vals[e].kind; if ek != VK_CINT && ek != VK_CFP { all_simple = false; } }
        if all_simple {
            let dk = if k == TK_ARRAY { VK_CDARRAY } else { VK_CDVECTOR };
            return cst_get(dk, ty, cst_none(), elems);
        }
    }
    let ak = if k == TK_ARRAY { VK_CARRAY } else { VK_CVECTOR };
    return cst_get(ak, ty, cst_none(), elems);
}

// Number of elements of an aggregate constant (for zeroinitializer/undef these are synthesized).
fn c_elem_count(ty: i32) -> i64 {
    let k = types[ty].kind;
    if k == TK_STRUCT { return types[ty].cnt; }
    return types[ty].cnt;
}

// Constant expression. ops are operand values; aux run in `ints` for e.g. shufflevector masks.
fn c_expr(opc: i64, ty: i32, opsv: const i32[:], flags: u8, pred: u8, ty2: i32, inr: i32) -> i32 {
    var c = cst_none();
    c.op = opc as u8;
    c.flags = flags;
    c.pred = pred;
    c.ty2 = ty2;
    c.inr = inr;
    return cst_get(VK_CEXPR, ty, c, opsv);
}

// ---------------------------------------------------------------------------------------------
// Opcodes (llvm/IR/Instruction.def).

let OP_RET = 1;
let OP_BR = 2;          // UncondBr
let OP_CONDBR = 3;
let OP_SWITCH = 4;
let OP_INDIRECTBR = 5;
let OP_INVOKE = 6;
let OP_RESUME = 7;
let OP_UNREACHABLE = 8;
let OP_CLEANUPRET = 9;
let OP_CATCHRET = 10;
let OP_CATCHSWITCH = 11;
let OP_CALLBR = 12;
let OP_FNEG = 13;
let OP_ADD = 14;
let OP_FADD = 15;
let OP_SUB = 16;
let OP_FSUB = 17;
let OP_MUL = 18;
let OP_FMUL = 19;
let OP_UDIV = 20;
let OP_SDIV = 21;
let OP_FDIV = 22;
let OP_UREM = 23;
let OP_SREM = 24;
let OP_FREM = 25;
let OP_SHL = 26;
let OP_LSHR = 27;
let OP_ASHR = 28;
let OP_AND = 29;
let OP_OR = 30;
let OP_XOR = 31;
let OP_ALLOCA = 32;
let OP_LOAD = 33;
let OP_STORE = 34;
let OP_GEP = 35;
let OP_FENCE = 36;
let OP_CMPXCHG = 37;
let OP_ATOMICRMW = 38;
let OP_TRUNC = 39;
let OP_ZEXT = 40;
let OP_SEXT = 41;
let OP_FPTOUI = 42;
let OP_FPTOSI = 43;
let OP_UITOFP = 44;
let OP_SITOFP = 45;
let OP_FPTRUNC = 46;
let OP_FPEXT = 47;
let OP_PTRTOINT = 48;
let OP_PTRTOADDR = 49;
let OP_INTTOPTR = 50;
let OP_BITCAST = 51;
let OP_ADDRSPACECAST = 52;
let OP_CLEANUPPAD = 53;
let OP_CATCHPAD = 54;
let OP_ICMP = 55;
let OP_FCMP = 56;
let OP_PHI = 57;
let OP_CALL = 58;
let OP_SELECT = 59;
let OP_VAARG = 62;
let OP_EXTRACTELEMENT = 63;
let OP_INSERTELEMENT = 64;
let OP_SHUFFLEVECTOR = 65;
let OP_EXTRACTVALUE = 66;
let OP_INSERTVALUE = 67;
let OP_LANDINGPAD = 68;
let OP_FREEZE = 69;

fn is_terminator_op(o: i64) -> bool { o >= OP_RET && o <= OP_CALLBR }
fn is_binary_op(o: i64) -> bool { o >= OP_ADD && o <= OP_XOR }
fn is_cast_op(o: i64) -> bool { o >= OP_TRUNC && o <= OP_ADDRSPACECAST }

// Poison-generating / misc flag bits (Inst.flags, Cst.flags).
let FL_NUW: u8 = 1;
let FL_NSW: u8 = 2;
let FL_EXACT: u8 = 4;
let FL_DISJOINT: u8 = 8;
let FL_NNEG: u8 = 16;
let FL_SAMESIGN: u8 = 32;
// GEP no-wrap flags (GEPNoWrapFlags): inbounds, nusw, nuw
let GEP_INBOUNDS: u8 = 1;
let GEP_NUSW: u8 = 2;
let GEP_NUW: u8 = 4;
// trunc uses FL_NUW / FL_NSW.

// Fast-math flags (FastMathFlags bit order).
let FMF_REASSOC: u8 = 1;
let FMF_NNAN: u8 = 2;
let FMF_NINF: u8 = 4;
let FMF_NSZ: u8 = 8;
let FMF_ARCP: u8 = 16;
let FMF_CONTRACT: u8 = 32;
let FMF_AFN: u8 = 64;
let FMF_FAST: u8 = 127;

// ---------------------------------------------------------------------------------------------
// Instructions, blocks, functions, globals.

// pred: icmp/fcmp predicate, atomicrmw operation; align: log2(alignment)+1 (0 = none);
// ord/ord2: atomic orderings; bits: volatile (1), weak (2), tail kinds (tail=4, musttail=8, notail=16), inalloca etc.
// ty2: GEP source type / alloca allocated type / call function type / load result in val.ty.
// attrs: attribute list of a call. cc: calling convention. aux/naux: run in `ints` (indices, mask).
// md/nmd: attachments run in md_att (pairs kind, node). ss: syncscope string id (-1 = system).
struct Inst {
    op: u8, flags: u8, fmf: u8, pred: u8, align: u8, ord: u8, ord2: u8, bits: u8,
    val: i32, parent: i32, prev: i32, next: i32,
    ty2: i32, attrs: i32, cc: i32, aux: i32, naux: i32, md: i32, nmd: i32, ss: i32, as_: i32
}

struct Block { val: i32, parent: i32, prev: i32, next: i32, first: i32, last: i32 }

var insts: Inst[>..];
var blocks: Block[>..];

// Linkage (GlobalValue::LinkageTypes order).
let LK_EXTERNAL = 0;
let LK_AVAILABLE_EXTERNALLY = 1;
let LK_LINKONCE_ANY = 2;
let LK_LINKONCE_ODR = 3;
let LK_WEAK_ANY = 4;
let LK_WEAK_ODR = 5;
let LK_APPENDING = 6;
let LK_INTERNAL = 7;
let LK_PRIVATE = 8;
let LK_EXTERN_WEAK = 9;
let LK_COMMON = 10;

// One record for every global value (function, variable, alias, ifunc).
// For functions: blocks list, args run (in ints), attrs, cc, personality/prefix/prologue are operands.
// For variables: initializer is operand 0 (if any). Aliases/ifuncs: aliasee/resolver is operand 0.
struct Glob {
    val: i32, module: i32, prev: i32, next: i32,
    linkage: u8, vis: u8, dll: u8, unnamed: u8, dso_local: u8, tls: u8, is_const: u8, ext_init: u8,
    is_decl: u8, has_personality: u8, has_prefix: u8, has_prologue: u8, align: u8, pref_align: u8, vty: i32,
    addrspace: i32, section: i32, partition: i32, comdat: i32, gc: i32, attrs: i32, cc: i32,
    first_block: i32, last_block: i32, args: i32, nargs: i32, md: i32, nmd: i32, code_model: u8, sanitizer: u8,
    symtab: i32, intrinsic: u8, last_unique: i32
}

var globs: Glob[>..];

// Module-level lists.
struct Module {
    first_gvar: i32, last_gvar: i32, first_func: i32, last_func: i32,
    first_alias: i32, last_alias: i32, first_ifunc: i32, last_ifunc: i32,
    source_filename: i32, datalayout: i32, triple: i32, module_id: i32, asm_: i32,
    symtab: i32
}

var modules: Module[>..];
var cur_module: i32 = 0;

struct Comdat { name: i32, kind: u8 }
var comdats: Comdat[>..];

fn new_module() -> i32 {
    let id = modules.len as i32;
    modules.push(Module { first_gvar: -1, last_gvar: -1, first_func: -1, last_func: -1, first_alias: -1,
        last_alias: -1, first_ifunc: -1, last_ifunc: -1, source_filename: -1, datalayout: -1, triple: -1,
        module_id: -1, asm_: -1, symtab: new_symtab() });
    return id;
}

fn glob_of(v: i32) -> i32 { vals[v].sub }
fn inst_of(v: i32) -> i32 { vals[v].sub }
fn block_of(v: i32) -> i32 { vals[v].sub }

fn new_glob(kind: i64, ty: i32, name: i32, nops: i64) -> i32 {
    let g = globs.len as i32;
    let v = new_val(kind, ty, g, nops);
    globs.push(Glob { val: v, module: cur_module, prev: -1, next: -1, linkage: 0, vis: 0, dll: 0, unnamed: 0,
        dso_local: 0, tls: 0, is_const: 0, ext_init: 0, is_decl: 1, has_personality: 0, has_prefix: 0,
        has_prologue: 0, align: 0, pref_align: 0, vty: -1, addrspace: 0, section: -1, partition: -1, comdat: -1, gc: -1,
        attrs: 0, cc: 0, first_block: -1, last_block: -1, args: 0, nargs: 0, md: 0, nmd: 0, code_model: 0,
        sanitizer: 0, symtab: -1, intrinsic: 0, last_unique: 0 });
    return v;
}

// Append a global to its module list (kind decides which list).
fn module_append_global(v: i32) {
    let g = glob_of(v);
    let m = globs[g].module;
    let k = vals[v].kind;
    var last: i32 = -1;
    if k == VK_GVAR { last = modules[m].last_gvar; }
    else if k == VK_FUNC { last = modules[m].last_func; }
    else if k == VK_ALIAS { last = modules[m].last_alias; }
    else { last = modules[m].last_ifunc; }
    globs[g].prev = last;
    globs[g].next = -1;
    if last >= 0 { globs[glob_of(last)].next = v; }
    if k == VK_GVAR { if last < 0 { modules[m].first_gvar = v; } modules[m].last_gvar = v; }
    else if k == VK_FUNC { if last < 0 { modules[m].first_func = v; } modules[m].last_func = v; }
    else if k == VK_ALIAS { if last < 0 { modules[m].first_alias = v; } modules[m].last_alias = v; }
    else { if last < 0 { modules[m].first_ifunc = v; } modules[m].last_ifunc = v; }
}

fn module_remove_global(v: i32) {
    let g = glob_of(v);
    let m = globs[g].module;
    let k = vals[v].kind;
    let p = globs[g].prev;
    let n = globs[g].next;
    if p >= 0 { globs[glob_of(p)].next = n; }
    else if k == VK_GVAR { modules[m].first_gvar = n; }
    else if k == VK_FUNC { modules[m].first_func = n; }
    else if k == VK_ALIAS { modules[m].first_alias = n; }
    else { modules[m].first_ifunc = n; }
    if n >= 0 { globs[glob_of(n)].prev = p; }
    else if k == VK_GVAR { modules[m].last_gvar = p; }
    else if k == VK_FUNC { modules[m].last_func = p; }
    else if k == VK_ALIAS { modules[m].last_alias = p; }
    else { modules[m].last_ifunc = p; }
    globs[g].prev = -1;
    globs[g].next = -1;
}

fn new_block(name: i32) -> i32 {
    let b = blocks.len as i32;
    let v = new_val(VK_BLOCK, T_LABEL, b, 0);
    vals[v].name = name;
    blocks.push(Block { val: v, parent: -1, prev: -1, next: -1, first: -1, last: -1 });
    block_nums.push(-1);
    return v;
}

// BasicBlock::getNumber: assigned from the function's NextBlockNum when the block's parent changes
// (BasicBlock::setParent), so it is the creation order within the function; -1 when not in a function.
var block_nums: i32[>..];       // block index -> number
var fn_next_bnum: i32[>..];     // glob index -> Function::NextBlockNum
fn block_set_parent(bv: i32, fv: i32) {
    let b = block_of(bv);
    if blocks[b].parent == fv { return; }
    blocks[b].parent = fv;
    if fv < 0 { block_nums[b] = -1; return; }
    let g = glob_of(fv) as i64;
    while fn_next_bnum.len <= g { fn_next_bnum.push(0); }
    block_nums[b] = fn_next_bnum[g];
    fn_next_bnum[g] += 1;
}
fn block_number(bv: i32) -> i32 { block_nums[block_of(bv)] }
// Function::getMaxBlockNumber
fn func_max_block_number(fv: i32) -> i32 { let g = glob_of(fv) as i64; if g < fn_next_bnum.len { fn_next_bnum[g] } else { 0 } }

// Insert block bv at the end of function fv.
fn func_append_block(fv: i32, bv: i32) {
    let g = glob_of(fv);
    let b = block_of(bv);
    let last = globs[g].last_block;
    block_set_parent(bv, fv);
    blocks[b].prev = last;
    blocks[b].next = -1;
    if last >= 0 { blocks[block_of(last)].next = bv; } else { globs[g].first_block = bv; }
    globs[g].last_block = bv;
}

fn func_remove_block(bv: i32) {
    let b = block_of(bv);
    let fv = blocks[b].parent;
    let g = glob_of(fv);
    let p = blocks[b].prev;
    let n = blocks[b].next;
    if p >= 0 { blocks[block_of(p)].next = n; } else { globs[g].first_block = n; }
    if n >= 0 { blocks[block_of(n)].prev = p; } else { globs[g].last_block = p; }
    blocks[b].prev = -1;
    blocks[b].next = -1;
    block_set_parent(bv, -1);
}

fn new_inst(opc: i64, ty: i32, nopnds: i64) -> i32 {
    let i = insts.len as i32;
    let v = new_val(VK_INST, ty, i, nopnds);
    insts.push(Inst { op: opc as u8, flags: 0, fmf: 0, pred: 0, align: 0, ord: 0, ord2: 0, bits: 0, val: v,
        parent: -1, prev: -1, next: -1, ty2: -1, attrs: 0, cc: 0, aux: 0, naux: 0, md: 0, nmd: 0, ss: -1, as_: 0 });
    return v;
}

fn iop(v: i32) -> i64 { insts[vals[v].sub].op as i64 }

fn block_append_inst(bv: i32, iv: i32) {
    let b = block_of(bv);
    let i = inst_of(iv);
    let last = blocks[b].last;
    insts[i].parent = bv;
    insts[i].prev = last;
    insts[i].next = -1;
    if last >= 0 { insts[inst_of(last)].next = iv; } else { blocks[b].first = iv; }
    blocks[b].last = iv;
}

fn inst_insert_before(iv: i32, pos: i32) {
    let i = inst_of(iv);
    let pi = inst_of(pos);
    let bv = insts[pi].parent;
    let b = block_of(bv);
    let p = insts[pi].prev;
    insts[i].parent = bv;
    insts[i].prev = p;
    insts[i].next = pos;
    insts[pi].prev = iv;
    if p >= 0 { insts[inst_of(p)].next = iv; } else { blocks[b].first = iv; }
}

fn inst_remove(iv: i32) {
    let i = inst_of(iv);
    let bv = insts[i].parent;
    let b = block_of(bv);
    let p = insts[i].prev;
    let n = insts[i].next;
    if p >= 0 { insts[inst_of(p)].next = n; } else { blocks[b].first = n; }
    if n >= 0 { insts[inst_of(n)].prev = p; } else { blocks[b].last = p; }
    insts[i].prev = -1;
    insts[i].next = -1;
    insts[i].parent = -1;
}

fn inst_erase(iv: i32) {
    inst_remove(iv);
    drop_all_refs(iv);
    vals[iv].kind = VK_DEAD;
}

fn block_terminator(bv: i32) -> i32 {
    let l = blocks[block_of(bv)].last;
    if l >= 0 && is_terminator_op(iop(l)) { return l; }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// Symbol tables (llvm/IR/ValueSymbolTable.cpp): name -> value, with LLVM's uniquing.

struct Symtab { slots: i32, cap: i32, count: i32, last_unique: i32 }
var symtabs: Symtab[>..];
var symslots: i32[>..];        // all tables' slots; a grown table gets a fresh region

fn new_symtab() -> i32 {
    let id = symtabs.len as i32;
    let at = symslots.len as i32;
    for k in 16 { symslots.push(-1); }
    symtabs.push(Symtab { slots: at, cap: 16, count: 0, last_unique: 0 });
    return id;
}

fn symtab_find_slot(st: i32, name: i32) -> i64 {
    let t = symtabs[st];
    let mask = (t.cap - 1) as i64;
    var j = (strs[name].hash as i64) & mask;
    loop {
        let e = symslots[t.slots + j];
        if e < 0 || vals[e].name == name { return j; }
        j = (j + 1) & mask;
    }
}

fn symtab_lookup(st: i32, name: i32) -> i32 {
    let j = symtab_find_slot(st, name);
    return symslots[symtabs[st].slots + j];
}

fn symtab_grow(st: i32) {
    let t = symtabs[st];
    let ncap = t.cap * 2;
    let at = symslots.len as i32;
    for k in ncap { symslots.push(-1); }
    symtabs[st].slots = at;
    symtabs[st].cap = ncap;
    let mask = (ncap - 1) as i64;
    for k in t.cap {
        let e = symslots[t.slots + k];
        if e < 0 { continue; }
        var j = (strs[vals[e].name].hash as i64) & mask;
        while symslots[at + j] >= 0 { j = (j + 1) & mask; }
        symslots[at + j] = e;
    }
}

fn symtab_insert_raw(st: i32, v: i32) {
    if (symtabs[st].count + 1) * 2 > symtabs[st].cap { symtab_grow(st); }
    let j = symtab_find_slot(st, vals[v].name);
    symslots[symtabs[st].slots + j] = v;
    symtabs[st].count += 1;
}

fn symtab_remove(st: i32, v: i32) {
    // Backward-shift deletion for linear probing.
    let t = symtabs[st];
    let mask = (t.cap - 1) as i64;
    var j = symtab_find_slot(st, vals[v].name);
    if symslots[t.slots + j] != v { return; }
    symslots[t.slots + j] = -1;
    symtabs[st].count -= 1;
    var k = (j + 1) & mask;
    loop {
        let e = symslots[t.slots + k];
        if e < 0 { break; }
        let home = (strs[vals[e].name].hash as i64) & mask;
        // can e move to j?
        let dist_j = (j - home) & mask;
        let dist_k = (k - home) & mask;
        if dist_j < dist_k {
            symslots[t.slots + j] = e;
            symslots[t.slots + k] = -1;
            j = k;
        }
        k = (k + 1) & mask;
    }
}

fn format_u64_dec(out: u8[>..]&, v: u64) {
    if v == 0 { out.push('0'); return; }
    var buf: u8[20] = [0; 20];
    var n = 0;
    var x = v;
    while x > 0 { buf[n] = ('0' + (x % 10) as! u8); x = x / 10; n++; }
    while n > 0 { n--; out.push(buf[n]); }
}

// Value::setName semantics: give v the name `base`, uniquing within st (ValueSymbolTable::makeUniqueName).
fn symtab_set_name(st: i32, v: i32, base: const u8[:], is_global_name: bool) {
    if base.len == 0 { vals[v].name = -1; return; }
    let nm = intern(base);
    if symtab_lookup(st, nm) < 0 {
        vals[v].name = nm;
        symtab_insert_raw(st, v);
        return;
    }
    var buf: u8[>..] = [];
    loop {
        buf.clear();
        buf.append(base);
        if is_global_name { buf.push('.'); }
        symtabs[st].last_unique += 1;
        format_u64_dec(buf, symtabs[st].last_unique as u64);
        let cand = intern(buf);
        if symtab_lookup(st, cand) < 0 {
            vals[v].name = cand;
            symtab_insert_raw(st, v);
            return;
        }
    }
}

// The symbol table a value's name lives in.
fn symtab_for(v: i32) -> i32 {
    let k = vals[v].kind;
    if k <= VK_GVAR { return modules[globs[glob_of(v)].module].symtab; }
    var fv: i32 = -1;
    if k == VK_ARG { fv = args_parent[vals[v].sub]; }
    else if k == VK_BLOCK { fv = blocks[block_of(v)].parent; }
    else if k == VK_INST { let bv = insts[inst_of(v)].parent; if bv >= 0 { fv = blocks[block_of(bv)].parent; } }
    if fv < 0 { return -1; }
    return globs[glob_of(fv)].symtab;
}

fn set_name(v: i32, name: const u8[:]) {
    let st = symtab_for(v);
    if vals[v].name >= 0 && st >= 0 { symtab_remove(st, v); }
    if st < 0 { vals[v].name = if name.len > 0 { intern(name) } else { -1 }; return; }
    symtab_set_name(st, v, name, vals[v].kind <= VK_GVAR);
}

var args_parent: i32[>..];     // argument sub -> function value
var args_no: i32[>..];         // argument sub -> index

fn new_arg(fv: i32, ty: i32, k: i64) -> i32 {
    let a = args_parent.len as i32;
    args_parent.push(fv);
    args_no.push(k as i32);
    return new_val(VK_ARG, ty, a, 0);
}

fn func_arg(fv: i32, k: i64) -> i32 { ints[globs[glob_of(fv)].args + k] }
fn func_nargs(fv: i32) -> i64 { globs[glob_of(fv)].nargs as i64 }
fn func_type(fv: i32) -> i32 { globs[glob_of(fv)].vty }

// ---------------------------------------------------------------------------------------------
// Attributes (llvm/IR/Attributes.h). Attribute -> interned set (sorted) -> interned list.

// kind: AttrKind (1..AK_COUNT-1) or 0 for a string attribute (skey/sval string ids, sval -1 = no value).
// i1/i2: integer payload(s) (alignment value, dereferenceable bytes, allocsize args, memory effects, …);
// ty: type payload; for ranges: words index in `words` (lo/hi pairs).
struct Attr { kind: i32, i1: u64, i2: u64, ty: i32, skey: i32, sval: i32, hash: u32 }

var attrs: Attr[>..];
var attr_tab: i32[>..<];

// Attribute sets: runs of attribute ids in attr_runs, sorted by AttributeImpl::cmp. Set 0 = empty.
struct ASet { at: i32, n: i32, hash: u32, bits0: u64, bits1: u64 }   // bits: enum kinds present (kind < 128)
var asets: ASet[>..];
var aset_tab: i32[>..<];
var attr_runs: i32[>..];

// Attribute lists: runs of set ids [fn, ret, p0, p1, ...] (trailing empties trimmed). List 0 = empty.
struct AList { at: i32, n: i32, hash: u32 }
var alists: AList[>..];
var alist_tab: i32[>..<];
var alist_runs: i32[>..];

fn attr_hash(a: Attr) -> u32 {
    var h: u32 = (a.kind as! u32) * 2654435761;
    h = (h ^ (a.i1 as! u32) ^ ((a.i1 >> 32) as! u32)) * 16777619;
    h = (h ^ (a.i2 as! u32) ^ ((a.i2 >> 32) as! u32)) * 16777619;
    h = (h ^ (a.ty as! u32)) * 16777619;
    h = (h ^ (a.skey as! u32)) * 16777619;
    h = (h ^ (a.sval as! u32)) * 16777619;
    return h;
}

fn attr_get(a0: Attr) -> i32 {
    var a = a0;
    a.hash = attr_hash(a);
    if attr_tab.len == 0 || (attrs.len + 1) * 2 > attr_tab.len {
        var n: i64 = 256;
        while n < (attrs.len + 1) * 2 { n *= 2; }
        attr_tab.clear();
        attr_tab.resize(n, -1);
        for x, i in attrs {
            var j = (x.hash as i64) & (n - 1);
            while attr_tab[j] >= 0 { j = (j + 1) & (n - 1); }
            attr_tab[j] = i as i32;
        }
    }
    let mask = attr_tab.len - 1;
    var j = (a.hash as i64) & mask;
    loop {
        let e = attr_tab[j];
        if e < 0 { break; }
        let x = attrs[e];
        if x.hash == a.hash && x.kind == a.kind && x.i1 == a.i1 && x.i2 == a.i2 && x.ty == a.ty && x.skey == a.skey && x.sval == a.sval { return e; }
        j = (j + 1) & mask;
    }
    let id = attrs.len as i32;
    attrs.push(a);
    attr_tab[j] = id;
    return id;
}

fn attr_enum(kind: i64) -> i32 { attr_get(Attr { kind: kind as i32, i1: 0, i2: 0, ty: -1, skey: -1, sval: -1, hash: 0 }) }
fn attr_int(kind: i64, v: u64) -> i32 { attr_get(Attr { kind: kind as i32, i1: v, i2: 0, ty: -1, skey: -1, sval: -1, hash: 0 }) }
fn attr_type(kind: i64, t: i32) -> i32 { attr_get(Attr { kind: kind as i32, i1: 0, i2: 0, ty: t, skey: -1, sval: -1, hash: 0 }) }
fn attr_str(k: const u8[:], v: const u8[:], has_v: bool) -> i32 {
    let sk = intern(k);
    let sv = if has_v { intern(v) } else { -1 };
    return attr_get(Attr { kind: 0, i1: 0, i2: 0, ty: -1, skey: sk, sval: sv, hash: 0 });
}

fn bytes_cmp(a: const u8[:], b: const u8[:]) -> i64 {
    let n = min(a.len, b.len);
    for i in n {
        if a[i] != b[i] { return if a[i] < b[i] { -1 } else { 1 }; }
    }
    if a.len == b.len { return 0; }
    return if a.len < b.len { -1 } else { 1 };
}

// AttributeImpl::cmp(KindOnly=false)
fn attr_cmp(x: i32, y: i32) -> i64 {
    if x == y { return 0; }
    let a = attrs[x];
    let b = attrs[y];
    if a.kind != 0 {
        if b.kind == 0 { return -1; }
        if a.kind != b.kind { return if a.kind < b.kind { -1 } else { 1 }; }
        // same enum kind: compare payloads (int, then type) — rarely relevant inside one set
        if a.i1 != b.i1 { return if a.i1 < b.i1 { -1 } else { 1 }; }
        if a.i2 != b.i2 { return if a.i2 < b.i2 { -1 } else { 1 }; }
        return 0;
    }
    if b.kind != 0 { return 1; }
    let kc = bytes_cmp(sbytes(a.skey), sbytes(b.skey));
    if kc != 0 { return kc; }
    let av: const u8[:] = if a.sval >= 0 { sbytes(a.sval) } else { "" };
    let bv: const u8[:] = if b.sval >= 0 { sbytes(b.sval) } else { "" };
    return bytes_cmp(av, bv);
}

fn init_attrs() {
    asets.push(ASet { at: 0, n: 0, hash: 0, bits0: 0, bits1: 0 });
    alists.push(AList { at: 0, n: 0, hash: 0 });
}

// Builds an attribute set from a list of attribute ids (any order, duplicates of a kind: the later one wins).
fn aset_get(xs0: const i32[:]) -> i32 {
    if xs0.len == 0 { return 0; }
    var xs: i32[>..<] = [];
    for x in xs0 {
        // replace an existing one of the same kind/key
        var replaced = false;
        for &y in xs {
            let ay = attrs[y];
            let ax = attrs[x];
            if (ax.kind != 0 && ay.kind == ax.kind) || (ax.kind == 0 && ay.kind == 0 && ay.skey == ax.skey) {
                y = x;
                replaced = true;
            }
        }
        if !replaced { xs.push(x); }
    }
    // insertion sort by attr_cmp
    for i in 1..xs.len {
        let x = xs[i];
        var j = i;
        while j > 0 && attr_cmp(xs[j - 1], x) > 0 { xs[j] = xs[j - 1]; j--; }
        xs[j] = x;
    }
    var h: u32 = 7;
    for x in xs { h = (h ^ (x as! u32)) * 16777619; }
    if aset_tab.len == 0 || (asets.len + 1) * 2 > aset_tab.len {
        var n: i64 = 256;
        while n < (asets.len + 1) * 2 { n *= 2; }
        aset_tab.clear();
        aset_tab.resize(n, -1);
        for s, i in asets {
            if i == 0 { continue; }
            var j = (s.hash as i64) & (n - 1);
            while aset_tab[j] >= 0 { j = (j + 1) & (n - 1); }
            aset_tab[j] = i as i32;
        }
    }
    let mask = aset_tab.len - 1;
    var j = (h as i64) & mask;
    loop {
        let e = aset_tab[j];
        if e < 0 { break; }
        let s = asets[e];
        if s.hash == h && s.n as i64 == xs.len {
            var same = true;
            for k in xs.len { if attr_runs[s.at + k] != xs[k] { same = false; break; } }
            if same { return e; }
        }
        j = (j + 1) & mask;
    }
    let id = asets.len as i32;
    let at = attr_runs.len as i32;
    var b0: u64 = 0;
    var b1: u64 = 0;
    for x in xs {
        attr_runs.push(x);
        let k = attrs[x].kind as i64;
        if k > 0 && k < 64 { b0 |= (1 as u64) << (k as u64); } else if k >= 64 && k < 128 { b1 |= (1 as u64) << ((k - 64) as u64); }
    }
    asets.push(ASet { at: at, n: xs.len as i32, hash: h, bits0: b0, bits1: b1 });
    aset_tab[j] = id;
    return id;
}

fn aset_n(s: i32) -> i64 { asets[s].n as i64 }
fn aset_attr(s: i32, k: i64) -> i32 { attr_runs[asets[s].at + k] }
fn aset_find(s: i32, kind: i64) -> i32 {
    if kind > 0 && kind < 64 { if (asets[s].bits0 & ((1 as u64) << (kind as u64))) == 0 { return -1; } }
    else if kind >= 64 && kind < 128 { if (asets[s].bits1 & ((1 as u64) << ((kind - 64) as u64))) == 0 { return -1; } }
    for k in asets[s].n { let a = attr_runs[asets[s].at + k]; if attrs[a].kind as i64 == kind { return a; } }
    return -1;
}
fn aset_has(s: i32, kind: i64) -> bool { aset_find(s, kind) >= 0 }

// xs: [fn, ret, p0, ...] set ids.
fn alist_get(xs0: const i32[:]) -> i32 {
    var n = xs0.len;
    while n > 0 && xs0[n - 1] == 0 { n--; }
    if n == 0 { return 0; }
    let xs = xs0[0..n];
    var h: u32 = 11;
    for x in xs { h = (h ^ (x as! u32)) * 16777619; }
    if alist_tab.len == 0 || (alists.len + 1) * 2 > alist_tab.len {
        var cap: i64 = 256;
        while cap < (alists.len + 1) * 2 { cap *= 2; }
        alist_tab.clear();
        alist_tab.resize(cap, -1);
        for s, i in alists {
            if i == 0 { continue; }
            var j = (s.hash as i64) & (cap - 1);
            while alist_tab[j] >= 0 { j = (j + 1) & (cap - 1); }
            alist_tab[j] = i as i32;
        }
    }
    let mask = alist_tab.len - 1;
    var j = (h as i64) & mask;
    loop {
        let e = alist_tab[j];
        if e < 0 { break; }
        let s = alists[e];
        if s.hash == h && s.n as i64 == xs.len {
            var same = true;
            for k in xs.len { if alist_runs[s.at + k] != xs[k] { same = false; break; } }
            if same { return e; }
        }
        j = (j + 1) & mask;
    }
    let id = alists.len as i32;
    let at = alist_runs.len as i32;
    for x in xs { alist_runs.push(x); }
    alists.push(AList { at: at, n: xs.len as i32, hash: h });
    alist_tab[j] = id;
    return id;
}

fn alist_fn(l: i32) -> i32 { if alists[l].n > 0 { alist_runs[alists[l].at] } else { 0 } }
fn alist_ret(l: i32) -> i32 { if alists[l].n > 1 { alist_runs[alists[l].at + 1] } else { 0 } }
fn alist_param(l: i32, k: i64) -> i32 { if alists[l].n as i64 > k + 2 { alist_runs[alists[l].at + 2 + k] } else { 0 } }

// ---------------------------------------------------------------------------------------------
// Metadata (llvm/IR/Metadata.h).

let MK_TUPLE = 0;      // MDTuple
let MK_STRING = 1;     // MDString: extra = string id
let MK_VALUE = 2;      // ConstantAsMetadata / LocalAsMetadata: extra = value id
let MK_TEMP = 3;       // forward reference placeholder
let MK_DILOCATION = 4;
let MK_GENERIC = 5;    // unused
let MK_DI = 6;         // specialized DI node (dinfo.goose): extra = DIK_* kind, ops = fields in schema order
let MK_INTLIT = 7;     // integer field value of a DI node: extra = low 32 bits, ops = [high 32 bits]
let MK_DIEXPR = 8;     // DIExpression: ops = elements (MK_INTLIT); a node, but printed inline (no slot)
let MK_DIARGLIST = 9;  // DIArgList: ops = ValueAsMetadata; not a node

struct Md { kind: u8, distinct: u8, ops: i32, nops: i32, extra: i32, hash: u32 }
var mds: Md[>..];
var md_ops: i32[>..];
var md_tab: i32[>..<];

fn md_hash(kind: i64, extra: i32, opsv: const i32[:]) -> u32 {
    var h: u32 = (kind as u32) * 2654435761 + (extra as! u32) * 31;
    for x in opsv { h = (h ^ (x as! u32)) * 16777619; }
    return h;
}

fn md_rebuild_tab() {
    var n: i64 = 256;
    while n < (mds.len + 1) * 2 { n *= 2; }
    md_tab.clear();
    md_tab.resize(n, -1);
    for m, i in mds {
        if m.distinct != 0 || m.kind == MK_TEMP { continue; }
        var j = (m.hash as i64) & (n - 1);
        while md_tab[j] >= 0 { j = (j + 1) & (n - 1); }
        md_tab[j] = i as i32;
    }
}

fn md_get(kind: i64, extra: i32, opsv: const i32[:], distinct: bool) -> i32 {
    let h = md_hash(kind, extra, opsv);
    if !distinct {
        if md_tab.len == 0 || (mds.len + 1) * 2 > md_tab.len { md_rebuild_tab(); }
        let mask = md_tab.len - 1;
        var j = (h as i64) & mask;
        loop {
            let e = md_tab[j];
            if e < 0 { break; }
            let m = mds[e];
            if m.hash == h && m.kind as i64 == kind && m.extra == extra && m.nops as i64 == opsv.len {
                var same = true;
                for k in opsv.len { if md_ops[m.ops + k] != opsv[k] { same = false; break; } }
                if same { return e; }
            }
            j = (j + 1) & mask;
        }
        let id = mds.len as i32;
        let at = md_ops.len as i32;
        for x in opsv { md_ops.push(x); }
        mds.push(Md { kind: kind as u8, distinct: 0, ops: at, nops: opsv.len as i32, extra: extra, hash: h });
        md_tab[j] = id;
        return id;
    }
    let id = mds.len as i32;
    let at = md_ops.len as i32;
    for x in opsv { md_ops.push(x); }
    mds.push(Md { kind: kind as u8, distinct: 1, ops: at, nops: opsv.len as i32, extra: extra, hash: h });
    return id;
}

fn md_string(s: const u8[:]) -> i32 { md_get(MK_STRING, intern(s), [], false) }
fn md_value(v: i32) -> i32 { md_get(MK_VALUE, v, [], false) }
fn md_op(m: i32, k: i64) -> i32 { md_ops[mds[m].ops + k] }
fn md_is_node(m: i32) -> bool { let k = mds[m].kind; k == MK_TUPLE || k == MK_DILOCATION || k == MK_GENERIC || k == MK_DI || k == MK_DIEXPR }

// Metadata kinds (FixedMetadataKinds.def, then custom kinds in registration order).
var md_kind_names: i32[>..];

fn md_kind_id(name: const u8[:]) -> i32 {
    let s = intern(name);
    for n, i in md_kind_names { if n == s { return i as i32; } }
    md_kind_names.push(s);
    return (md_kind_names.len - 1) as i32;
}

fn init_md_kinds() {
    for f in FIXED_MD_KINDS { md_kind_names.push(intern(f)); }
}

// Attachments: pairs (kind, node) in md_att, kept sorted by kind.
var md_att: i32[>..];

// Named metadata, in creation order.
struct NamedMd { name: i32, ops: i32, nops: i32, module: i32 }
var named_mds: NamedMd[>..];

// ---------------------------------------------------------------------------------------------
// Inline asm values

struct Asm { asm_: i32, cons: i32, side: u8, align: u8, dialect: u8, unwind: u8 }
var asms: Asm[>..];

fn init_ir() {
    init_types();
    init_attrs();
    init_md_kinds();
    for k in 32 { free_runs[k] = -1; }
}

// MemoryEffects: 2 bits per IRMemLocation (ArgMem, InaccessibleMem, ErrnoMem, Other, TargetMem0, TargetMem1).
fn me_all(mr: i64) -> u64 { var d: u64 = 0; for l in 6 { d |= (mr as u64) << (2 * l); } return d; }
fn me_set(d: u64, loc: i64, mr: i64) -> u64 { (d & ~((3 as u64) << (2 * loc))) | ((mr as u64) << (2 * loc)) }
fn me_get(d: u64, loc: i64) -> i64 { ((d >> (2 * loc)) & 3) as! i64 }
