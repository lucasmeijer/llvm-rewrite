// Module printer. Port of llvm/lib/IR/AsmWriter.cpp (AssemblyWriter, SlotTracker, TypePrinting)
// and the printing parts of TypeFinder.cpp and Attributes.cpp (getAsString).
import std;
import os;
import ir;
import bignum;
import apfloat;
import calls;

var out: u8[>..];

// ---------------------------------------------------------------------------------------------
// Slot tracker

var vslot: i32[>..];        // value id -> slot (module slots for globals, function slots for locals)
var local_slotted: i32[>..<];
var mdslot: i32[>..];       // md id -> slot
var md_order: i32[>..];
var asslot: i32[>..];       // attribute set id -> group number
var as_order: i32[>..];
var fnext: i32 = 0;
var mnext: i32 = 0;

fn ensure_slot_arrays() {
    while vslot.len < vals.len { vslot.push(-1); }
    while mdslot.len < mds.len { mdslot.push(-1); }
    while asslot.len < asets.len { asslot.push(-1); }
}

fn create_as_slot(s: i32) {
    if s == 0 { return; }
    if asslot[s] >= 0 { return; }
    asslot[s] = as_order.len as i32;
    as_order.push(s);
}

// CreateMetadataSlot: number the node, then its operands depth first.
recursive fn create_md_slot(m: i32) {
    if m < 0 { return; }
    if !md_is_node(m) { return; }
    if mdslot[m] >= 0 { return; }
    mdslot[m] = md_order.len as i32;
    md_order.push(m);
    for k in mds[m].nops {
        let o = md_ops[mds[m].ops + k];
        if o >= 0 && md_is_node(o) { create_md_slot(o); }
    }
}

fn process_attachments(at: i32, n: i32) {
    for k in n { create_md_slot(md_att[at + 2 * k + 1]); }
}

fn process_module(m: i32) {
    ensure_slot_arrays();
    var g = modules[m].first_gvar;
    while g >= 0 {
        let gi = glob_of(g);
        if vals[g].name < 0 { vslot[g] = mnext; mnext++; }
        process_attachments(globs[gi].md, globs[gi].nmd);
        if globs[gi].attrs != 0 { create_as_slot(globs[gi].attrs); }
        g = globs[gi].next;
    }
    var a = modules[m].first_alias;
    while a >= 0 { if vals[a].name < 0 { vslot[a] = mnext; mnext++; } a = globs[glob_of(a)].next; }
    var i = modules[m].first_ifunc;
    while i >= 0 {
        if vals[i].name < 0 { vslot[i] = mnext; mnext++; }
        process_attachments(globs[glob_of(i)].md, globs[glob_of(i)].nmd);
        i = globs[glob_of(i)].next;
    }
    for nm in named_mds {
        if nm.module != m { continue; }
        for k in nm.nops { create_md_slot(md_ops[nm.ops + k]); }
    }
    var f = modules[m].first_func;
    while f >= 0 {
        let gi = glob_of(f);
        if vals[f].name < 0 { vslot[f] = mnext; mnext++; }
        let fa = alist_fn(globs[gi].attrs);
        if fa != 0 { create_as_slot(fa); }
        f = globs[gi].next;
    }
}

fn is_intrinsic_call(iv: i32) -> bool {
    let callee = op(iv, nops(iv) - 1);
    return vals[callee].kind == VK_FUNC && globs[glob_of(callee)].intrinsic != 0;
}

fn process_function(f: i32) {
    ensure_slot_arrays();
    fnext = 0;
    let gi = glob_of(f);
    // processFunctionMetadata
    process_attachments(globs[gi].md, globs[gi].nmd);
    var b = globs[gi].first_block;
    while b >= 0 {
        var iv = blocks[block_of(b)].first;
        while iv >= 0 {
            let ii = inst_of(iv);
            if insts[ii].op as i64 == OP_CALL && is_intrinsic_call(iv) {
                for k in nops(iv) {
                    let o = op(iv, k);
                    if vals[o].kind == VK_MDVAL && md_is_node(vals[o].sub) { create_md_slot(vals[o].sub); }
                }
            }
            process_attachments(insts[ii].md, insts[ii].nmd);
            iv = insts[ii].next;
        }
        b = blocks[block_of(b)].next;
    }
    for k in func_nargs(f) {
        let a = func_arg(f, k);
        if vals[a].name < 0 { vslot[a] = fnext; fnext++; local_slotted.push(a); }
    }
    b = globs[gi].first_block;
    while b >= 0 {
        if vals[b].name < 0 { vslot[b] = fnext; fnext++; local_slotted.push(b); }
        var iv = blocks[block_of(b)].first;
        while iv >= 0 {
            let ii = inst_of(iv);
            if vals[iv].ty != T_VOID && vals[iv].name < 0 { vslot[iv] = fnext; fnext++; local_slotted.push(iv); }
            if is_call_base_op(insts[ii].op as i64) {
                let fa = alist_fn(insts[ii].attrs);
                if fa != 0 { create_as_slot(fa); }
            }
            iv = insts[ii].next;
        }
        b = blocks[block_of(b)].next;
    }
}

fn purge_function() {
    for v in local_slotted { vslot[v] = -1; }
    local_slotted.clear();
}

// ---------------------------------------------------------------------------------------------
// Type finder (TypeFinder::run with OnlyNamed = false) -> named and numbered struct types

var tf_seen_ty: bool[>..];
var tf_seen_val: bool[>..];
var tf_seen_md: bool[>..];
var tf_seen_al: bool[>..];
var tf_structs: i32[>..];
var tf_work: i32[>..<];
var numbered_struct_slot: i32[>..];   // type id -> number for unnamed identified structs

fn tf_type(t0: i32) {
    if tf_seen_ty[t0] { return; }
    tf_seen_ty[t0] = true;
    tf_work.push(t0);
    while tf_work.len > 0 {
        let t = tf_work.pop();
        let k = types[t].kind;
        if k == TK_STRUCT { tf_structs.push(t); }
        // subtypes in reverse
        var n: i64 = 0;
        if k == TK_STRUCT || k == TK_FUNC { n = types[t].cnt; }
        else if k == TK_ARRAY || k == TK_FVEC || k == TK_SVEC { n = 1; }
        var i = n;
        while i > 0 {
            i--;
            let st = if k == TK_STRUCT || k == TK_FUNC { ints[types[t].a + i] } else { types[t].a };
            if !tf_seen_ty[st] { tf_seen_ty[st] = true; tf_work.push(st); }
        }
    }
}

recursive fn tf_value(v: i32) {
    let k = vals[v].kind;
    if k == VK_MDVAL {
        let m = vals[v].sub;
        if md_is_node(m) { tf_md(m); return; }
        if mds[m].kind == MK_VALUE { tf_value(mds[m].extra); }
        return;
    }
    if !is_constant(v) || is_global(v) { return; }
    if tf_seen_val[v] { return; }
    tf_seen_val[v] = true;
    tf_type(vals[v].ty);
    if k == VK_CEXPR && csts[vals[v].sub].op as i64 == OP_GEP { tf_type(csts[vals[v].sub].ty2); }
    for j in vals[v].nops { tf_value(uses[vals[v].ops + j].val); }
}

recursive fn tf_md(m: i32) {
    if tf_seen_md[m] { return; }
    tf_seen_md[m] = true;
    for k in mds[m].nops {
        let o = md_ops[mds[m].ops + k];
        if o < 0 { continue; }
        if md_is_node(o) { tf_md(o); continue; }
        if mds[o].kind == MK_VALUE && is_constant(mds[o].extra) { tf_value(mds[o].extra); }
    }
}

fn tf_attrs(l: i32) {
    if tf_seen_al[l] { return; }
    tf_seen_al[l] = true;
    for k in alists[l].n {
        let s = alist_runs[alists[l].at + k];
        for j in asets[s].n {
            let a = attr_runs[asets[s].at + j];
            let ak = attrs[a].kind as i64;
            if ak > 0 && ATTR_CLASSES[ak] as i64 == ATTR_CLASS_TYPE && attrs[a].ty >= 0 { tf_type(attrs[a].ty); }
        }
    }
}

fn type_finder(m: i32) {
    tf_seen_ty.clear(); tf_seen_ty.resize(types.len, false);
    tf_seen_val.clear(); tf_seen_val.resize(vals.len, false);
    tf_seen_md.clear(); tf_seen_md.resize(mds.len, false);
    tf_seen_al.clear(); tf_seen_al.resize(alists.len, false);
    tf_structs.clear();
    var g = modules[m].first_gvar;
    while g >= 0 {
        tf_type(globs[glob_of(g)].vty);
        if nops(g) > 0 && op(g, 0) >= 0 { tf_value(op(g, 0)); }
        g = globs[glob_of(g)].next;
    }
    var a = modules[m].first_alias;
    while a >= 0 {
        tf_type(globs[glob_of(a)].vty);
        if op(a, 0) >= 0 { tf_value(op(a, 0)); }
        a = globs[glob_of(a)].next;
    }
    var i = modules[m].first_ifunc;
    while i >= 0 { tf_type(globs[glob_of(i)].vty); i = globs[glob_of(i)].next; }
    var f = modules[m].first_func;
    while f >= 0 {
        let gi = glob_of(f);
        tf_type(globs[gi].vty);
        tf_attrs(globs[gi].attrs);
        for k in nops(f) { let o = op(f, k); if o >= 0 { tf_value(o); } }
        var b = globs[gi].first_block;
        while b >= 0 {
            var iv = blocks[block_of(b)].first;
            while iv >= 0 {
                let ii = inst_of(iv);
                tf_type(vals[iv].ty);
                for k in nops(iv) {
                    let o = op(iv, k);
                    if o >= 0 && vals[o].kind != VK_INST { tf_value(o); }
                }
                let opc = insts[ii].op as i64;
                if opc == OP_GEP || opc == OP_ALLOCA { tf_type(insts[ii].ty2); }
                if is_call_base_op(opc) { tf_attrs(insts[ii].attrs); }
                for k in insts[ii].nmd {
                    if md_att[insts[ii].md + 2 * k] != 0 { tf_md(md_att[insts[ii].md + 2 * k + 1]); }
                }
                iv = insts[ii].next;
            }
            b = blocks[block_of(b)].next;
        }
        f = globs[gi].next;
    }
    for nm in named_mds {
        if nm.module != m { continue; }
        for k in nm.nops { tf_md(md_ops[nm.ops + k]); }
    }
    numbered_struct_slot.clear();
    numbered_struct_slot.resize(types.len, -1);
    var nn: i32 = 0;
    var keep = 0;
    for k in tf_structs.len {
        let t = tf_structs[k];
        if (types[t].flags & TF_NAMED) == 0 { continue; }
        if types[t].name < 0 { numbered_struct_slot[t] = nn; nn++; }
        else { tf_structs[keep] = t; keep++; }
    }
    tf_structs.resize(keep);
}

// ---------------------------------------------------------------------------------------------
// Basic writers

fn put(s: const u8[:]) { out.append(s); }
fn putc(c: u8) { out.push(c); }
fn put_int(v: i64) { format(out, v); }
fn put_uint(v: u64) { format_u64_dec(out, v); }

fn hexc(n: i64) -> u8 { "0123456789ABCDEF"[n] }

// printEscapedString
fn put_escaped(s: const u8[:]) {
    for c in s {
        if c == '\\' { put("\\\\"); }
        else if c >= 32 && c < 127 && c != '"' { putc(c); }
        else { putc('\\'); putc(hexc((c >> 4) as i64)); putc(hexc((c & 15) as i64)); }
    }
}

// printLLVMNameWithoutPrefix
fn put_name_body(s: const u8[:]) {
    var quote = s.len == 0 || (s[0] >= '0' && s[0] <= '9');
    if !quote {
        for c in s {
            let ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_';
            if !ok { quote = true; break; }
        }
    }
    if !quote { put(s); return; }
    putc('"');
    put_escaped(s);
    putc('"');
}

fn put_md_ident(s: const u8[:]) {
    for c, i in s {
        let a = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        let ok = if i == 0 { a || c == '-' || c == '$' || c == '.' || c == '_' } else { a || (c >= '0' && c <= '9') || c == '-' || c == '$' || c == '.' || c == '_' };
        if ok { putc(c); } else { putc('\\'); putc(hexc((c >> 4) as i64)); putc(hexc((c & 15) as i64)); }
    }
}

recursive fn put_type(t: i32) {
    let k = types[t].kind;
    if k == TK_VOID { put("void"); return; }
    if k == TK_HALF { put("half"); return; }
    if k == TK_BFLOAT { put("bfloat"); return; }
    if k == TK_FLOAT { put("float"); return; }
    if k == TK_DOUBLE { put("double"); return; }
    if k == TK_X86_FP80 { put("x86_fp80"); return; }
    if k == TK_FP128 { put("fp128"); return; }
    if k == TK_PPC_FP128 { put("ppc_fp128"); return; }
    if k == TK_LABEL { put("label"); return; }
    if k == TK_METADATA { put("metadata"); return; }
    if k == TK_X86_AMX { put("x86_amx"); return; }
    if k == TK_TOKEN { put("token"); return; }
    if k == TK_INT { putc('i'); put_int(types[t].n as i64); return; }
    if k == TK_FUNC {
        put_type(ints[types[t].a]);
        put(" (");
        let np = types[t].cnt - 1;
        for i in np {
            if i > 0 { put(", "); }
            put_type(ints[types[t].a + 1 + i]);
        }
        if (types[t].flags & TF_VARARG) != 0 { if np > 0 { put(", "); } put("..."); }
        putc(')');
        return;
    }
    if k == TK_STRUCT {
        if (types[t].flags & TF_NAMED) == 0 { put_struct_body(t); return; }
        if types[t].name >= 0 { putc('%'); put_name_body(sbytes(types[t].name)); return; }
        let n = if t < numbered_struct_slot.len { numbered_struct_slot[t] } else { -1 };
        if n >= 0 { putc('%'); put_int(n as i64); } else { put("%\"type <unknown>\""); }
        return;
    }
    if k == TK_PTR {
        put("ptr");
        if types[t].n != 0 { put(" addrspace("); put_int(types[t].n as i64); putc(')'); }
        return;
    }
    if k == TK_ARRAY {
        putc('[');
        format(out, types[t].cnt);
        put(" x ");
        put_type(types[t].a);
        putc(']');
        return;
    }
    if k == TK_FVEC || k == TK_SVEC {
        putc('<');
        if k == TK_SVEC { put("vscale x "); }
        format(out, types[t].cnt);
        put(" x ");
        put_type(types[t].a);
        putc('>');
        return;
    }
    put("<unknown type>");
}

recursive fn put_struct_body(t: i32) {
    if (types[t].flags & TF_OPAQUE) != 0 { put("opaque"); return; }
    let packed = (types[t].flags & TF_PACKED) != 0;
    if packed { putc('<'); }
    if types[t].cnt == 0 { put("{}"); }
    else {
        put("{ ");
        for i in types[t].cnt {
            if i > 0 { put(", "); }
            put_type(ints[types[t].a + i]);
        }
        put(" }");
    }
    if packed { putc('>'); }
}

// ---------------------------------------------------------------------------------------------
// Integers

fn put_cint(v: i32) {
    let ty = vals[v].ty;
    let bits = ty_bits(ty);
    let c = csts[vals[v].sub];
    if bits == 1 { put(if c.lo != 0 { "true" } else { "false" }); return; }
    if bits <= 64 {
        put_int(cint_sext(v));
        return;
    }
    // multiword signed decimal
    let nw = (bits + 63) / 64;
    var ws: u64[>..] = [];
    for k in nw {
        if c.ext >= 0 { ws.push(words[c.ext + k]); }
        else { ws.push(if k == 0 { c.lo } else if k == 1 { c.hi } else { 0 }); }
    }
    let top = bits - 1;
    let neg = ((ws[top / 64] >> (top % 64)) & 1) != 0;
    if neg {
        // two's complement negate within bits
        var carry: u64 = 1;
        for k in nw {
            let x = ~ws[k];
            let s = x + carry;
            carry = if carry == 1 && s == 0 { 1 } else { 0 };
            ws[k] = s;
        }
        let r = bits % 64;
        if r != 0 { ws[nw - 1] = ws[nw - 1] & ((1 << r) - 1); }
        putc('-');
    }
    var a: u32[>..<] = [];
    bn_from_words(a, ws);
    bn_format_dec(out, a);
}

// ---------------------------------------------------------------------------------------------
// Constants and operands

fn opcode_name(o: i64) -> const u8[:] {
    if o == OP_RET { return "ret"; } if o == OP_BR || o == OP_CONDBR { return "br"; } if o == OP_SWITCH { return "switch"; }
    if o == OP_INDIRECTBR { return "indirectbr"; } if o == OP_INVOKE { return "invoke"; } if o == OP_RESUME { return "resume"; }
    if o == OP_UNREACHABLE { return "unreachable"; } if o == OP_FNEG { return "fneg"; }
    if o == OP_ADD { return "add"; } if o == OP_FADD { return "fadd"; } if o == OP_SUB { return "sub"; } if o == OP_FSUB { return "fsub"; }
    if o == OP_MUL { return "mul"; } if o == OP_FMUL { return "fmul"; } if o == OP_UDIV { return "udiv"; } if o == OP_SDIV { return "sdiv"; }
    if o == OP_FDIV { return "fdiv"; } if o == OP_UREM { return "urem"; } if o == OP_SREM { return "srem"; } if o == OP_FREM { return "frem"; }
    if o == OP_SHL { return "shl"; } if o == OP_LSHR { return "lshr"; } if o == OP_ASHR { return "ashr"; } if o == OP_AND { return "and"; }
    if o == OP_OR { return "or"; } if o == OP_XOR { return "xor"; } if o == OP_ALLOCA { return "alloca"; } if o == OP_LOAD { return "load"; }
    if o == OP_STORE { return "store"; } if o == OP_GEP { return "getelementptr"; } if o == OP_FENCE { return "fence"; }
    if o == OP_CMPXCHG { return "cmpxchg"; } if o == OP_ATOMICRMW { return "atomicrmw"; }
    if o == OP_TRUNC { return "trunc"; } if o == OP_ZEXT { return "zext"; } if o == OP_SEXT { return "sext"; }
    if o == OP_FPTOUI { return "fptoui"; } if o == OP_FPTOSI { return "fptosi"; } if o == OP_UITOFP { return "uitofp"; }
    if o == OP_SITOFP { return "sitofp"; } if o == OP_FPTRUNC { return "fptrunc"; } if o == OP_FPEXT { return "fpext"; }
    if o == OP_PTRTOINT { return "ptrtoint"; } if o == OP_PTRTOADDR { return "ptrtoaddr"; } if o == OP_INTTOPTR { return "inttoptr"; }
    if o == OP_BITCAST { return "bitcast"; } if o == OP_ADDRSPACECAST { return "addrspacecast"; }
    if o == OP_ICMP { return "icmp"; } if o == OP_FCMP { return "fcmp"; } if o == OP_PHI { return "phi"; } if o == OP_CALL { return "call"; }
    if o == OP_SELECT { return "select"; } if o == OP_VAARG { return "va_arg"; } if o == OP_EXTRACTELEMENT { return "extractelement"; }
    if o == OP_INSERTELEMENT { return "insertelement"; } if o == OP_SHUFFLEVECTOR { return "shufflevector"; }
    if o == OP_EXTRACTVALUE { return "extractvalue"; } if o == OP_INSERTVALUE { return "insertvalue"; }
    if o == OP_LANDINGPAD { return "landingpad"; } if o == OP_FREEZE { return "freeze"; }
    if o == OP_CLEANUPRET { return "cleanupret"; } if o == OP_CATCHRET { return "catchret"; } if o == OP_CATCHSWITCH { return "catchswitch"; }
    if o == OP_CALLBR { return "callbr"; } if o == OP_CLEANUPPAD { return "cleanuppad"; } if o == OP_CATCHPAD { return "catchpad"; }
    return "<bad opcode>";
}

fn put_fmf(f: u8) {
    if f == FMF_FAST { put(" fast"); return; }
    if (f & FMF_REASSOC) != 0 { put(" reassoc"); }
    if (f & FMF_NNAN) != 0 { put(" nnan"); }
    if (f & FMF_NINF) != 0 { put(" ninf"); }
    if (f & FMF_NSZ) != 0 { put(" nsz"); }
    if (f & FMF_ARCP) != 0 { put(" arcp"); }
    if (f & FMF_CONTRACT) != 0 { put(" contract"); }
    if (f & FMF_AFN) != 0 { put(" afn"); }
}

// writeOptimizationInfo (non-FP part)
fn put_opt_flags(opc: i64, fl: u8) {
    if opc == OP_ADD || opc == OP_SUB || opc == OP_MUL || opc == OP_SHL {
        if (fl & FL_NUW) != 0 { put(" nuw"); }
        if (fl & FL_NSW) != 0 { put(" nsw"); }
    } else if opc == OP_UDIV || opc == OP_SDIV || opc == OP_LSHR || opc == OP_ASHR {
        if (fl & FL_EXACT) != 0 { put(" exact"); }
    } else if opc == OP_OR {
        if (fl & FL_DISJOINT) != 0 { put(" disjoint"); }
    } else if opc == OP_GEP {
        if (fl & GEP_INBOUNDS) != 0 { put(" inbounds"); }
        else if (fl & GEP_NUSW) != 0 { put(" nusw"); }
        if (fl & GEP_NUW) != 0 { put(" nuw"); }
    } else if opc == OP_ZEXT || opc == OP_UITOFP {
        if (fl & FL_NNEG) != 0 { put(" nneg"); }
    } else if opc == OP_TRUNC {
        if (fl & FL_NUW) != 0 { put(" nuw"); }
        if (fl & FL_NSW) != 0 { put(" nsw"); }
    } else if opc == OP_ICMP {
        if (fl & FL_SAMESIGN) != 0 { put(" samesign"); }
    }
}

// Constant::getSplatValue for vectors (data or aggregate). -1 if not a splat.
fn splat_value(v: i32) -> i32 {
    let n = vals[v].nops;
    if n == 0 { return -1; }
    let first = uses[vals[v].ops].val;
    for k in 1..n { if uses[vals[v].ops + k].val != first { return -1; } }
    return first;
}

recursive fn put_constant(v: i32) {
    let k = vals[v].kind;
    let ty = vals[v].ty;
    if k == VK_CINT {
        if ty_is_vector(ty) { put("splat ("); put_type(types[ty].a); putc(' '); }
        put_cint(v);
        if ty_is_vector(ty) { putc(')'); }
        return;
    }
    if k == VK_CFP {
        let c = csts[vals[v].sub];
        write_apfloat(out, types[ty_scalar(ty)].kind as i64, c.lo, c.hi);
        return;
    }
    if k == VK_AGGZERO || k == VK_CTARGETNONE { put("zeroinitializer"); return; }
    if k == VK_BLOCKADDR {
        put("blockaddress(");
        put_operand(op(v, 0), false);
        put(", ");
        put_operand(op(v, 1), false);
        putc(')');
        return;
    }
    if k == VK_CARRAY {
        putc('[');
        for i in vals[v].nops { if i > 0 { put(", "); } put_operand(op(v, i), true); }
        putc(']');
        return;
    }
    if k == VK_CDARRAY {
        let et = types[ty].a;
        if types[et].kind == TK_INT && types[et].n == 8 {
            put("c\"");
            var tmp: u8[>..] = [];
            for i in vals[v].nops { tmp.push(cint_lo(op(v, i)) as! u8); }
            put_escaped(tmp);
            putc('"');
            return;
        }
        putc('[');
        for i in vals[v].nops { if i > 0 { put(", "); } put_operand(op(v, i), true); }
        putc(']');
        return;
    }
    if k == VK_CSTRUCT {
        let packed = (types[ty].flags & TF_PACKED) != 0;
        if packed { putc('<'); }
        putc('{');
        if vals[v].nops != 0 {
            putc(' ');
            for i in vals[v].nops { if i > 0 { put(", "); } put_operand(op(v, i), true); }
            putc(' ');
        }
        putc('}');
        if packed { putc('>'); }
        return;
    }
    if k == VK_CVECTOR || k == VK_CDVECTOR {
        let s = splat_value(v);
        if s >= 0 && (vals[s].kind == VK_CINT || vals[s].kind == VK_CFP) {
            put("splat (");
            put_operand(s, true);
            putc(')');
            return;
        }
        putc('<');
        for i in vals[v].nops { if i > 0 { put(", "); } put_operand(op(v, i), true); }
        putc('>');
        return;
    }
    if k == VK_CNULL { put("null"); return; }
    if k == VK_CTOKENNONE { put("none"); return; }
    if k == VK_POISON { put("poison"); return; }
    if k == VK_UNDEF { put("undef"); return; }
    if k == VK_CEXPR {
        let c = csts[vals[v].sub];
        let opc = c.op as i64;
        put(opcode_name(opc));
        put_opt_flags(opc, c.flags);
        put(" (");
        if opc == OP_GEP { put_type(c.ty2); put(", "); }
        for i in vals[v].nops { if i > 0 { put(", "); } put_operand(op(v, i), true); }
        if is_cast_op(opc) { put(" to "); put_type(ty); }
        putc(')');
        return;
    }
    put("<placeholder or erroneous Constant>");
}

// writeAsOperandInternal
recursive fn put_operand(v: i32, print_type: bool) {
    if v < 0 { put("<null operand!>"); return; }
    if print_type { put_type(vals[v].ty); putc(' '); }
    let k = vals[v].kind;
    if vals[v].name >= 0 && k != VK_MDVAL {
        putc(if k <= VK_GVAR { '@' } else { '%' });
        put_name_body(sbytes(vals[v].name));
        return;
    }
    if is_constant(v) && !is_global(v) { put_constant(v); return; }
    if k == VK_INLINEASM {
        let a = asms[vals[v].sub];
        put("asm ");
        if a.side != 0 { put("sideeffect "); }
        if a.align != 0 { put("alignstack "); }
        if a.dialect != 0 { put("inteldialect "); }
        if a.unwind != 0 { put("unwind "); }
        putc('"');
        put_escaped(sbytes(a.asm_));
        put("\", \"");
        put_escaped(sbytes(a.cons));
        putc('"');
        return;
    }
    if k == VK_MDVAL { put_md_operand(vals[v].sub, true); return; }
    var s = if v < vslot.len { vslot[v] } else { -1 };
    if s < 0 && (k == VK_BLOCK || k == VK_ARG || k == VK_INST) { s = foreign_local_slot(v); }
    if s >= 0 {
        putc(if k <= VK_GVAR { '@' } else { '%' });
        put_int(s as i64);
    } else {
        put("<badref>");
    }
}

// writeAsOperandInternal for metadata
recursive fn put_md_operand(m: i32, from_value: bool) {
    if m < 0 { put("null"); return; }
    let k = mds[m].kind;
    if md_is_node(m) {
        let s = mdslot[m];
        if s < 0 { put("<badref>"); return; }
        putc('!');
        put_int(s as i64);
        return;
    }
    if k == MK_STRING {
        put("!\"");
        put_escaped(sbytes(mds[m].extra));
        putc('"');
        return;
    }
    if k == MK_VALUE {
        put_operand(mds[m].extra, true);
        return;
    }
    put("<unknown metadata>");
}

recursive fn put_md_body(m: i32) {
    let k = mds[m].kind;
    if k == MK_TUPLE {
        if mds[m].distinct != 0 { put("distinct "); }
        put("!{");
        for i in mds[m].nops {
            if i > 0 { put(", "); }
            let o = md_ops[mds[m].ops + i];
            if o < 0 { put("null"); }
            else if mds[o].kind == MK_VALUE { put_operand(mds[o].extra, true); }
            else { put_md_operand(o, false); }
        }
        putc('}');
        return;
    }
    put("<unsupported metadata>");
}

// ---------------------------------------------------------------------------------------------
// Attributes

fn put_modref(mr: i64) {
    if mr == 0 { put("none"); } else if mr == 1 { put("read"); } else if mr == 2 { put("write"); } else { put("readwrite"); }
}

fn put_capture_components(c: u64) {
    if c == 0 { put("none"); return; }
    var first = true;
    if (c & 3) == 1 { put("address_is_null"); first = false; }
    else if (c & 3) == 3 { put("address"); first = false; }
    if (c & 12) == 4 { if !first { put(", "); } put("read_provenance"); first = false; }
    if (c & 12) == 12 { if !first { put(", "); } put("provenance"); }
}

recursive fn put_attr(a: i32, in_group: bool) {
    let x = attrs[a];
    let k = x.kind as i64;
    if k == 0 {
        putc('"');
        put_escaped(sbytes(x.skey));
        putc('"');
        if x.sval >= 0 && strs[x.sval].len > 0 {
            put("=\"");
            put_escaped(sbytes(x.sval));
            putc('"');
        }
        return;
    }
    let cls = ATTR_CLASSES[k] as i64;
    if cls == ATTR_CLASS_ENUM { put(ATTR_NAMES[k]); return; }
    if cls == ATTR_CLASS_TYPE {
        put(ATTR_NAMES[k]);
        if x.ty >= 0 { putc('('); put_type(x.ty); putc(')'); }
        return;
    }
    if k == AK_Alignment { put(if in_group { "align=" } else { "align " }); put_uint(x.i1); return; }
    if k == AK_StackAlignment || k == AK_Dereferenceable || k == AK_DereferenceableOrNull || k == AK_DeadOnReturn {
        if k == AK_DeadOnReturn && x.i1 == 0xFFFFFFFFFFFFFFFF { put("dead_on_return"); return; }
        put(ATTR_NAMES[k]);
        if in_group { putc('='); put_uint(x.i1); } else { putc('('); put_uint(x.i1); putc(')'); }
        return;
    }
    if k == AK_AllocSize {
        put("allocsize(");
        put_uint(x.i1 >> 32);
        let n = x.i1 & 0xFFFFFFFF;
        if n != 0xFFFFFFFF { putc(','); put_uint(n); }
        putc(')');
        return;
    }
    if k == AK_VScaleRange {
        put("vscale_range(");
        put_uint(x.i1 >> 32);
        putc(',');
        put_uint(x.i1 & 0xFFFFFFFF);
        putc(')');
        return;
    }
    if k == AK_UWTable { put(if x.i1 == 2 { "uwtable" } else { "uwtable(sync)" }); return; }
    if k == AK_AllocKind {
        put("allockind(\"");
        let names = ["alloc", "realloc", "free", "uninitialized", "zeroed", "aligned"];
        var first = true;
        for n, i in names {
            if (x.i1 & ((1 as u64) << i)) != 0 { if !first { putc(','); } put(n); first = false; }
        }
        put("\")");
        return;
    }
    if k == AK_Memory {
        let d = x.i1;
        put("memory(");
        let other = me_get(d, 3);
        var first = true;
        // ME.getModRef() == union of all locations
        var all: i64 = 0;
        for l in 6 { all |= me_get(d, l); }
        if other != 0 || all == other { first = false; put_modref(other); }
        var target_done = false;
        let target_same = me_get(d, 4) == me_get(d, 5);
        let locs = [0, 1, 2, 4, 5];
        for loc in locs {
            let mr = me_get(d, loc);
            if mr == other { continue; }
            if !first && !target_done { put(", "); }
            first = false;
            if (loc == 4 || loc == 5) && target_same {
                if !target_done { put("target_mem: "); put_modref(mr); target_done = true; }
                continue;
            }
            if loc == 0 { put("argmem: "); } else if loc == 1 { put("inaccessiblemem: "); }
            else if loc == 2 { put("errnomem: "); } else if loc == 4 { put("target_mem0: "); } else { put("target_mem1: "); }
            put_modref(mr);
        }
        putc(')');
        return;
    }
    if k == AK_Captures {
        let other = x.i1 & 0xFF;
        let ret = (x.i1 >> 8) & 0xFF;
        put("captures(");
        var wrote = false;
        if other != 0 || other == ret { put_capture_components(other); wrote = true; }
        if other != ret { if wrote { put(", "); } put("ret: "); put_capture_components(ret); }
        putc(')');
        return;
    }
    if k == AK_NoFPClass {
        put("nofpclass");
        put_fpclass(x.i1);
        return;
    }
    if k == AK_Range {
        let at = x.i1 as! i64;
        put("range(i");
        put_uint(words[at]);
        putc(' ');
        put_cint(words[at + 1] as! i32);
        put(", ");
        put_cint(words[at + 2] as! i32);
        putc(')');
        return;
    }
    if k == AK_Initializes {
        let at = x.i1 as! i64;
        let n = words[at] as! i64;
        put("initializes(");
        for j in n {
            if j > 0 { put(", "); }
            putc('(');
            put_int(words[at + 1 + 2 * j] as! i64);
            put(", ");
            put_int(words[at + 2 + 2 * j] as! i64);
            putc(')');
        }
        putc(')');
        return;
    }
    put("<unknown attribute>");
}

// FPClassTest printing (llvm/lib/Support/FloatingPointMode.cpp: operator<<(raw_ostream&, FPClassTest)), with parens.
fn put_fpclass(m0: u64) {
    putc('(');
    if m0 == 0 { put("none)"); return; }
    var m = m0;
    let names = ["all", "nan", "snan", "qnan", "inf", "ninf", "pinf", "zero", "nzero", "pzero", "sub", "nsub", "psub",
                 "norm", "nnorm", "pnorm"];
    let bits = [1023, 3, 1, 2, 516, 4, 512, 96, 32, 64, 144, 16, 128, 264, 8, 256];
    var first = true;
    for n, i in names {
        let b = bits[i] as u64;
        if (m & b) == b {
            if !first { putc(' '); }
            put(n);
            first = false;
            m = m & ~b;
        }
    }
    putc(')');
}

recursive fn put_attr_set(s: i32, in_group: bool) {
    for k in asets[s].n {
        if k > 0 { putc(' '); }
        put_attr(attr_runs[asets[s].at + k], in_group);
    }
}

// ---------------------------------------------------------------------------------------------
// Module

fn linkage_name(l: i64) -> const u8[:] {
    if l == LK_EXTERNAL { return ""; }
    if l == LK_PRIVATE { return "private "; }
    if l == LK_INTERNAL { return "internal "; }
    if l == LK_LINKONCE_ANY { return "linkonce "; }
    if l == LK_LINKONCE_ODR { return "linkonce_odr "; }
    if l == LK_WEAK_ANY { return "weak "; }
    if l == LK_WEAK_ODR { return "weak_odr "; }
    if l == LK_COMMON { return "common "; }
    if l == LK_APPENDING { return "appending "; }
    if l == LK_EXTERN_WEAK { return "extern_weak "; }
    if l == LK_AVAILABLE_EXTERNALLY { return "available_externally "; }
    return "";
}

fn put_global_prefix_flags(g: i32) {
    let x = globs[g];
    let l = x.linkage as i64;
    put(linkage_name(l));
    let implicit = l == LK_INTERNAL || l == LK_PRIVATE || x.vis != 0;
    if x.dso_local != 0 && !implicit { put("dso_local "); }
    if x.vis == 1 { put("hidden "); } else if x.vis == 2 { put("protected "); }
    if x.dll == 1 { put("dllimport "); } else if x.dll == 2 { put("dllexport "); }
}

fn put_tls(t: u8) {
    if t == 1 { put("thread_local "); } else if t == 2 { put("thread_local(localdynamic) "); }
    else if t == 3 { put("thread_local(initialexec) "); } else if t == 4 { put("thread_local(localexec) "); }
}

fn unnamed_addr_str(u: u8) -> const u8[:] { if u == 1 { "local_unnamed_addr" } else if u == 2 { "unnamed_addr" } else { "" } }

fn put_attachments(at: i32, n: i32, sep: const u8[:]) {
    for k in n {
        put(sep);
        putc('!');
        put_md_ident(sbytes(md_kind_names[md_att[at + 2 * k]]));
        putc(' ');
        put_md_operand(md_att[at + 2 * k + 1], false);
    }
}

fn put_comdat_ref(gv: i32, is_var: bool) {
    let c = globs[glob_of(gv)].comdat;
    if c < 0 { return; }
    if is_var { putc(','); }
    put(" comdat");
    if vals[gv].name >= 0 && vals[gv].name == comdats[c].name { return; }
    put("($");
    put_name_body(sbytes(comdats[c].name));
    putc(')');
}

fn print_global_var(gv: i32) {
    let g = glob_of(gv);
    let x = globs[g];
    put_operand(gv, false);
    put(" = ");
    let has_init = nops(gv) > 0;
    if !has_init && x.linkage as i64 == LK_EXTERNAL { put("external "); }
    put_global_prefix_flags(g);
    put_tls(x.tls);
    let ua = unnamed_addr_str(x.unnamed);
    if ua.len > 0 { put(ua); putc(' '); }
    if x.addrspace != 0 { put("addrspace("); put_int(x.addrspace as i64); put(") "); }
    if x.ext_init != 0 { put("externally_initialized "); }
    put(if x.is_const != 0 { "constant " } else { "global " });
    put_type(x.vty);
    if has_init { putc(' '); put_operand(op(gv, 0), false); }
    if x.section >= 0 { put(", section \""); put_escaped(sbytes(x.section)); putc('"'); }
    if x.partition >= 0 { put(", partition \""); put_escaped(sbytes(x.partition)); putc('"'); }
    if x.code_model != 0 {
        put(", code_model \"");
        let cms = ["", "tiny", "small", "kernel", "medium", "large"];
        put(cms[x.code_model]);
        putc('"');
    }
    if (x.sanitizer & 1) != 0 { put(", no_sanitize_address"); }
    if (x.sanitizer & 2) != 0 { put(", no_sanitize_hwaddress"); }
    if (x.sanitizer & 4) != 0 { put(", sanitize_memtag"); }
    if (x.sanitizer & 8) != 0 { put(", sanitize_address_dyninit"); }
    put_comdat_ref(gv, true);
    if x.align != 0 { put(", align "); put_int(1 << (x.align - 1)); }
    put_attachments(x.md, x.nmd, ", ");
    if x.attrs != 0 { put(" #"); put_int(asslot[x.attrs] as i64); }
}

fn print_alias(av: i32, is_alias: bool) {
    let g = glob_of(av);
    let x = globs[g];
    put_operand(av, false);
    put(" = ");
    put_global_prefix_flags(g);
    if is_alias {
        put_tls(x.tls);
        let ua = unnamed_addr_str(x.unnamed);
        if ua.len > 0 { put(ua); putc(' '); }
        put("alias ");
    } else {
        put("ifunc ");
    }
    put_type(x.vty);
    put(", ");
    let a = op(av, 0);
    put_operand(a, vals[a].kind != VK_CEXPR);
    if x.partition >= 0 { put(", partition \""); put_escaped(sbytes(x.partition)); putc('"'); }
    if !is_alias { put_attachments(x.md, x.nmd, ", "); }
    putc('\n');
}

fn put_cc(cc: i32) {
    if cc == 8 { put("fastcc"); } else if cc == 9 { put("coldcc"); } else if cc == 10 { put("ghccc"); }
    else if cc == 13 { put("anyregcc"); } else if cc == 14 { put("preserve_mostcc"); } else if cc == 15 { put("preserve_allcc"); }
    else if cc == 16 { put("swiftcc"); } else if cc == 17 { put("cxx_fast_tlscc"); } else if cc == 18 { put("tailcc"); }
    else if cc == 20 { put("swifttailcc"); } else if cc == 21 { put("preserve_nonecc"); }
    else if cc == 64 { put("x86_stdcallcc"); } else if cc == 65 { put("x86_fastcallcc"); } else if cc == 70 { put("x86_thiscallcc"); }
    else if cc == 78 { put("x86_64_sysvcc"); } else if cc == 79 { put("win64cc"); } else if cc == 80 { put("x86_vectorcallcc"); }
    else if cc == 92 { put("x86_regcallcc"); } else if cc == 83 { put("x86_intrcc"); }
    else { put("cc"); put_int(cc as i64); }
}

fn print_function(f: i32) {
    let g = glob_of(f);
    let x = globs[g];
    let al = x.attrs;
    let fa = alist_fn(al);
    if fa != 0 {
        var any = false;
        var line: u8[>..] = [];
        for k in asets[fa].n {
            let a = attr_runs[asets[fa].at + k];
            if attrs[a].kind == 0 { continue; }
            if any { putc_to(line, ' '); }
            let mark = out.len;
            put_attr(a, false);
            line.append(out[mark..]);
            out.resize(mark);
            any = true;
        }
        if any { put("; Function Attrs: "); put(line); putc('\n'); }
    }
    process_function(f);
    let is_decl = x.is_decl != 0;
    if is_decl {
        put("declare");
        put_attachments(x.md, x.nmd, " ");
        putc(' ');
    } else {
        put("define ");
    }
    put_global_prefix_flags(g);
    if x.cc != 0 { put_cc(x.cc); putc(' '); }
    let fty = x.vty;
    let ra = alist_ret(al);
    if ra != 0 { put_attr_set(ra, false); putc(' '); }
    put_type(ty_fn_ret(fty));
    putc(' ');
    put_operand(f, false);
    putc('(');
    let np = ty_fn_nparams(fty);
    for k in np {
        if k > 0 { put(", "); }
        put_type(ty_fn_param(fty, k));
        let pa = alist_param(al, k);
        if pa != 0 { putc(' '); put_attr_set(pa, false); }
        if !is_decl {
            let a = func_arg(f, k);
            if vals[a].name >= 0 { put(" %"); put_name_body(sbytes(vals[a].name)); }
            else { put(" %"); put_int(vslot[a] as i64); }
        }
    }
    if ty_fn_vararg(fty) { if np > 0 { put(", "); } put("..."); }
    putc(')');
    let ua = unnamed_addr_str(x.unnamed);
    if ua.len > 0 { putc(' '); put(ua); }
    if x.addrspace != 0 { put(" addrspace("); put_int(x.addrspace as i64); putc(')'); }
    if fa != 0 { put(" #"); put_int(asslot[fa] as i64); }
    if x.section >= 0 { put(" section \""); put_escaped(sbytes(x.section)); putc('"'); }
    if x.partition >= 0 { put(" partition \""); put_escaped(sbytes(x.partition)); putc('"'); }
    put_comdat_ref(f, false);
    if x.align != 0 { put(" align "); put_int(1 << (x.align - 1)); }
    if x.gc >= 0 { put(" gc \""); put(sbytes(x.gc)); putc('"'); }
    if x.has_prefix != 0 { put(" prefix "); put_operand(op(f, 1), true); }
    if x.has_prologue != 0 { put(" prologue "); put_operand(op(f, 2), true); }
    if x.has_personality != 0 { put(" personality "); put_operand(op(f, 0), true); }
    if is_decl {
        putc('\n');
    } else {
        put_attachments(x.md, x.nmd, " ");
        put(" {");
        var b = x.first_block;
        while b >= 0 {
            print_block(f, b);
            b = blocks[block_of(b)].next;
        }
        put("}\n");
    }
    purge_function();
}

fn putc_to(o: u8[>..]&, c: u8) { o.push(c); }

fn column() -> i64 {
    var i = out.len;
    while i > 0 && out[i - 1] != '\n' { i--; }
    return out.len - i;
}

fn print_block(f: i32, b: i32) {
    let is_entry = globs[glob_of(f)].first_block == b;
    if vals[b].name >= 0 {
        putc('\n');
        put_name_body(sbytes(vals[b].name));
        putc(':');
    } else if !is_entry {
        putc('\n');
        let s = vslot[b];
        if s >= 0 { put_int(s as i64); putc(':'); } else { put("<badref>:"); }
    }
    if !is_entry {
        // PadToColumn(50)
        var c = column();
        if c < 50 { for k in 50 - c { putc(' '); } } else { putc(' '); }
        putc(';');
        // predecessors: users of the block that are terminators, in use-list order
        var u = vals[b].first_use;
        var any = false;
        while u >= 0 {
            let user = uses[u].user;
            if vals[user].kind == VK_INST && is_terminator_op(iop(user)) {
                if !any { put(" preds = "); any = true; } else { put(", "); }
                put_operand(insts[inst_of(user)].parent, false);
            }
            u = uses[u].next;
        }
        if !any { put(" No predecessors!"); }
    }
    putc('\n');
    var iv = blocks[block_of(b)].first;
    while iv >= 0 {
        print_inst(iv);
        putc('\n');
        iv = insts[inst_of(iv)].next;
    }
}

fn ordering_name(o: u8) -> const u8[:] {
    if o == 1 { return "unordered"; } if o == 2 { return "monotonic"; } if o == 3 { return "consume"; }
    if o == 4 { return "acquire"; } if o == 5 { return "release"; } if o == 6 { return "acq_rel"; }
    if o == 7 { return "seq_cst"; }
    return "notatomic";
}

fn put_syncscope(ss: i32) {
    if ss < 0 { return; }
    put(" syncscope(\"");
    put_escaped(sbytes(ss));
    put("\")");
}

fn icmp_name(p: u8) -> const u8[:] {
    let n = ["eq", "ne", "ugt", "uge", "ult", "ule", "sgt", "sge", "slt", "sle"];
    return n[p - 32];
}
fn fcmp_name(p: u8) -> const u8[:] {
    let n = ["false", "oeq", "ogt", "oge", "olt", "ole", "one", "ord", "uno", "ueq", "ugt", "uge", "ult", "ule", "une", "true"];
    return n[p];
}
fn rmw_name(p: u8) -> const u8[:] {
    let names = ["xchg", "add", "sub", "and", "nand", "or", "xor", "max", "min", "umax", "umin", "fadd", "fsub",
                 "fmax", "fmin", "fmaximum", "fminimum", "uinc_wrap", "udec_wrap", "usub_cond", "usub_sat"];
    return names[p];
}

// FPMathOperator::classof
fn is_fp_math_type(t: i32) -> bool {
    var s = t;
    while types[s].kind == TK_ARRAY { s = types[s].a; }
    if types[s].kind == TK_STRUCT {
        // homogeneous struct of FP (or vector of FP)
        if types[s].cnt == 0 { return false; }
        let e = ints[types[s].a];
        for k in types[s].cnt { if ints[types[s].a + k] != e { return false; } }
        s = e;
    }
    return ty_is_fp(ty_scalar(s));
}
fn is_fp_math_inst(iv: i32) -> bool {
    let o = iop(iv);
    if o == OP_FNEG || o == OP_FADD || o == OP_FSUB || o == OP_FMUL || o == OP_FDIV || o == OP_FREM || o == OP_FCMP { return true; }
    if o == OP_PHI || o == OP_SELECT || o == OP_CALL || o == OP_FPTRUNC || o == OP_FPEXT || o == OP_UITOFP || o == OP_SITOFP || o == OP_FPTOUI || o == OP_FPTOSI {
        return is_fp_math_type(vals[iv].ty);
    }
    return false;
}

fn put_shuffle_mask(rt: i32, at: i32, n: i32) {
    put(", <");
    if types[rt].kind == TK_SVEC { put("vscale x "); }
    put_int(n as i64);
    put(" x i32> ");
    var allz = true;
    var allp = true;
    for k in n { if ints[at + k] != 0 { allz = false; } if ints[at + k] != -1 { allp = false; } }
    if allz { put("zeroinitializer"); return; }
    if allp { put("poison"); return; }
    putc('<');
    for k in n {
        if k > 0 { put(", "); }
        put("i32 ");
        let e = ints[at + k];
        if e == -1 { put("poison"); } else { put_int(e as i64); }
    }
    putc('>');
}

fn put_param_operand(v: i32, s: i32) {
    put_type(vals[v].ty);
    if s != 0 { putc(' '); put_attr_set(s, false); }
    putc(' ');
    put_operand(v, false);
}

fn print_inst(iv: i32) {
    let ii = inst_of(iv);
    let x = insts[ii];
    let opc = x.op as i64;
    put("  ");
    if vals[iv].name >= 0 {
        putc('%');
        put_name_body(sbytes(vals[iv].name));
        put(" = ");
    } else if vals[iv].ty != T_VOID {
        let s = vslot[iv];
        if s < 0 { put("<badref> = "); } else { putc('%'); put_int(s as i64); put(" = "); }
    }
    if opc == OP_CALL {
        if x.pred == 2 { put("musttail "); } else if x.pred == 1 { put("tail "); } else if x.pred == 3 { put("notail "); }
    }
    put(opcode_name(opc));
    if (opc == OP_LOAD || opc == OP_STORE) && x.ord != 0 { put(" atomic"); }
    if opc == OP_CMPXCHG && (x.bits & 2) != 0 { put(" weak"); }
    if (opc == OP_LOAD || opc == OP_STORE || opc == OP_CMPXCHG || opc == OP_ATOMICRMW) && (x.bits & 1) != 0 { put(" volatile"); }
    if is_fp_math_inst(iv) { put_fmf(x.fmf); }
    put_opt_flags(opc, x.flags);
    if opc == OP_ICMP { putc(' '); put(icmp_name(x.pred)); }
    if opc == OP_FCMP { putc(' '); put(fcmp_name(x.pred)); }
    if opc == OP_ATOMICRMW { putc(' '); put(rmw_name(x.pred)); }
    let n = nops(iv);
    if opc == OP_CONDBR {
        putc(' ');
        put_operand(op(iv, 0), true);
        put(", ");
        put_operand(op(iv, 1), true);
        put(", ");
        put_operand(op(iv, 2), true);
    } else if opc == OP_SWITCH {
        putc(' ');
        put_operand(op(iv, 0), true);
        put(", ");
        put_operand(op(iv, 1), true);
        put(" [");
        var k = 2;
        while k + 1 < n {
            put("\n    ");
            put_operand(op(iv, k), true);
            put(", ");
            put_operand(op(iv, k + 1), true);
            k += 2;
        }
        put("\n  ]");
    } else if opc == OP_INDIRECTBR {
        putc(' ');
        put_operand(op(iv, 0), true);
        put(", [");
        for k in 1..n { if k > 1 { put(", "); } put_operand(op(iv, k), true); }
        putc(']');
    } else if opc == OP_PHI {
        putc(' ');
        put_type(vals[iv].ty);
        putc(' ');
        for k in n {
            if k > 0 { put(", "); }
            put("[ ");
            put_operand(op(iv, k), false);
            put(", ");
            put_operand(op_aux(iv, k), false);
            put(" ]");
        }
    } else if opc == OP_EXTRACTVALUE {
        putc(' ');
        put_operand(op(iv, 0), true);
        for k in x.naux { put(", "); put_int(ints[x.aux + k] as i64); }
    } else if opc == OP_INSERTVALUE {
        putc(' ');
        put_operand(op(iv, 0), true);
        put(", ");
        put_operand(op(iv, 1), true);
        for k in x.naux { put(", "); put_int(ints[x.aux + k] as i64); }
    } else if opc == OP_RET && n == 0 {
        put(" void");
    } else if opc == OP_LANDINGPAD {
        putc(' ');
        put_type(vals[iv].ty);
        let cleanup = (x.bits & 1) != 0;
        if cleanup || n != 0 { putc('\n'); }
        if cleanup { put("          cleanup"); }
        for k in n {
            if k != 0 || cleanup { putc('\n'); }
            if ty_is_array(vals[op(iv, k)].ty) { put("          filter "); } else { put("          catch "); }
            put_operand(op(iv, k), true);
        }
    } else if opc == OP_CATCHSWITCH {
        put(" within ");
        put_operand(op(iv, 0), false);
        put(" [");
        let first = if (x.bits & 1) != 0 { 2 } else { 1 };
        for k in first..n { if k > first { put(", "); } put_operand(op(iv, k), true); }
        put("] unwind ");
        if (x.bits & 1) != 0 { put_operand(op(iv, 1), true); } else { put("to caller"); }
    } else if opc == OP_CATCHPAD || opc == OP_CLEANUPPAD {
        put(" within ");
        put_operand(op(iv, n - 1), false);
        put(" [");
        for k in n - 1 { if k > 0 { put(", "); } put_operand(op(iv, k), true); }
        putc(']');
    } else if opc == OP_CATCHRET {
        put(" from ");
        put_operand(op(iv, 0), false);
        put(" to ");
        put_operand(op(iv, 1), true);
    } else if opc == OP_CLEANUPRET {
        put(" from ");
        put_operand(op(iv, 0), false);
        put(" unwind ");
        if n > 1 { put_operand(op(iv, 1), true); } else { put("to caller"); }
    } else if is_call_base_op(opc) {
        if x.cc != 0 { putc(' '); put_cc(x.cc); }
        let callee = cb_callee(iv);
        let fty = x.ty2;
        let al = x.attrs;
        let ra = alist_ret(al);
        if ra != 0 { putc(' '); put_attr_set(ra, false); }
        let cas = types[vals[callee].ty].n;
        if opc != OP_CALLBR && cas != 0 { put(" addrspace("); put_int(cas as i64); putc(')'); }
        putc(' ');
        put_type(if ty_fn_vararg(fty) { fty } else { ty_fn_ret(fty) });
        putc(' ');
        put_operand(callee, false);
        putc('(');
        let nargs = cb_nargs(iv);
        let fpclass = opc == OP_CALL && vals[callee].kind == VK_FUNC && vals[callee].name >= 0 && starts_with(sbytes(vals[callee].name), "llvm.is.fpclass");
        for k in nargs {
            if k > 0 { put(", "); }
            if fpclass && k == 1 && vals[op(iv, k)].kind == VK_CINT {
                put("/* ");
                put_fpclass(cint_lo(op(iv, k)));
                put(" */ ");
            }
            put_param_operand(op(iv, k), alist_param(al, k));
        }
        if opc == OP_CALL && x.pred == 2 {
            let pf = blocks[block_of(x.parent)].parent;
            if ty_fn_vararg(globs[glob_of(pf)].vty) { if nargs > 0 { put(", "); } put("..."); }
        }
        putc(')');
        let fa = alist_fn(al);
        if fa != 0 { put(" #"); put_int(asslot[fa] as i64); }
        let nb = cb_nbundles(iv);
        if nb > 0 {
            put(" [ ");
            for b in nb {
                if b > 0 { put(", "); }
                putc('"');
                put_escaped(sbytes(cb_bundle_tag(iv, b)));
                put("\"(");
                let st = cb_bundle_begin(iv, b);
                for j in cb_bundle_count(iv, b) {
                    if j > 0 { put(", "); }
                    put_operand(op(iv, st + j), true);
                }
                putc(')');
            }
            put(" ]");
        }
        if opc == OP_INVOKE {
            put("\n          to ");
            put_operand(invoke_normal_dest(iv), true);
            put(" unwind ");
            put_operand(invoke_unwind_dest(iv), true);
        } else if opc == OP_CALLBR {
            put("\n          to ");
            put_operand(callbr_default_dest(iv), true);
            put(" [");
            for j in cb_nindirect(iv) { if j > 0 { put(", "); } put_operand(callbr_indirect_dest(iv, j), true); }
            putc(']');
        }
    } else if opc == OP_ALLOCA {
        putc(' ');
        if (x.bits & 1) != 0 { put("inalloca "); }
        if (x.bits & 2) != 0 { put("swifterror "); }
        put_type(x.ty2);
        let sz = op(iv, 0);
        let one = vals[sz].kind == VK_CINT && vals[sz].ty == T_I32 && cint_lo(sz) == 1;
        if !one { put(", "); put_operand(sz, true); }
        if x.align != 0 { put(", align "); put_int(1 << (x.align - 1)); }
        if x.as_ != 0 { put(", addrspace("); put_int(x.as_ as i64); putc(')'); }
    } else if is_cast_op(opc) {
        putc(' ');
        put_operand(op(iv, 0), true);
        put(" to ");
        put_type(vals[iv].ty);
    } else if opc == OP_VAARG {
        putc(' ');
        put_operand(op(iv, 0), true);
        put(", ");
        put_type(vals[iv].ty);
    } else if n > 0 {
        if opc == OP_GEP { putc(' '); put_type(x.ty2); putc(','); }
        else if opc == OP_LOAD { putc(' '); put_type(vals[iv].ty); putc(','); }
        var all_types = opc == OP_SELECT || opc == OP_STORE || opc == OP_SHUFFLEVECTOR || opc == OP_RET || opc == OP_CMPXCHG || opc == OP_ATOMICRMW;
        let t0 = vals[op(iv, 0)].ty;
        if !all_types {
            for k in 1..n { if vals[op(iv, k)].ty != t0 { all_types = true; break; } }
        }
        if !all_types { putc(' '); put_type(t0); }
        putc(' ');
        for k in n {
            if k > 0 { put(", "); }
            put_operand(op(iv, k), all_types);
        }
    }
    if opc == OP_LOAD || opc == OP_STORE {
        if x.ord != 0 { put_syncscope(x.ss); putc(' '); put(ordering_name(x.ord)); }
        if x.align != 0 { put(", align "); put_int(1 << (x.align - 1)); }
    } else if opc == OP_CMPXCHG {
        put_syncscope(x.ss);
        putc(' ');
        put(ordering_name(x.ord));
        putc(' ');
        put(ordering_name(x.ord2));
        put(", align ");
        put_int(1 << (x.align - 1));
    } else if opc == OP_ATOMICRMW {
        put_syncscope(x.ss);
        putc(' ');
        put(ordering_name(x.ord));
        put(", align ");
        put_int(1 << (x.align - 1));
    } else if opc == OP_FENCE {
        put_syncscope(x.ss);
        putc(' ');
        put(ordering_name(x.ord));
    } else if opc == OP_SHUFFLEVECTOR {
        put_shuffle_mask(vals[iv].ty, x.aux, x.naux);
    }
    put_attachments(x.md, x.nmd, ", ");
}

fn print_module(m: i32) {
    out.clear();
    mnext = 0;
    process_module(m);
    type_finder(m);
    let mid = modules[m].module_id;
    if mid >= 0 { put("; ModuleID = '"); put(sbytes(mid)); put("'\n"); }
    let sf = modules[m].source_filename;
    if sf >= 0 && strs[sf].len > 0 { put("source_filename = \""); put_escaped(sbytes(sf)); put("\"\n"); }
    let dl = modules[m].datalayout;
    if dl >= 0 && strs[dl].len > 0 { put("target datalayout = \""); put(sbytes(dl)); put("\"\n"); }
    let tt = modules[m].triple;
    if tt >= 0 && strs[tt].len > 0 { put("target triple = \""); put(sbytes(tt)); put("\"\n"); }
    let ma = modules[m].asm_;
    if ma >= 0 {
        put("\nmodule asm\n");
        // the stored text ends with '\n' per line
        var a = sbytes(ma);
        if a.len > 0 && a[a.len - 1] == '\n' { a = a[..a.len - 1]; }
        each_split(a, '\n') {
            put("    \"");
            put_escaped(it);
            put("\"\n");
        };
    }
    // type identities
    var nnum = 0;
    for t in numbered_struct_slot { if t >= 0 { nnum++; } }
    if tf_structs.len > 0 || nnum > 0 {
        putc('\n');
        for i in nnum {
            for t, ti in numbered_struct_slot {
                if t == i as i32 {
                    putc('%');
                    put_int(i);
                    put(" = type ");
                    put_struct_body(ti as i32);
                    putc('\n');
                }
            }
        }
        for t in tf_structs {
            putc('%');
            put_name_body(sbytes(types[t].name));
            put(" = type ");
            put_struct_body(t);
            putc('\n');
        }
    }
    // comdats: in global_objects() order (functions, then variables), first use; joined by '\n'
    var corder: i32[>..] = [];
    var cseen: bool[>..] = [];
    cseen.resize(comdats.len, false);
    var cf = modules[m].first_func;
    while cf >= 0 { let c = globs[glob_of(cf)].comdat; if c >= 0 && !cseen[c] { cseen[c] = true; corder.push(c); } cf = globs[glob_of(cf)].next; }
    var cg = modules[m].first_gvar;
    while cg >= 0 { let c = globs[glob_of(cg)].comdat; if c >= 0 && !cseen[c] { cseen[c] = true; corder.push(c); } cg = globs[glob_of(cg)].next; }
    if corder.len > 0 {
        putc('\n');
        for c, ci in corder {
            if ci > 0 { putc('\n'); }
            putc('$');
            put_name_body(sbytes(comdats[c].name));
            put(" = comdat ");
            let kn = ["any", "exactmatch", "largest", "nodeduplicate", "samesize"];
            put(kn[comdats[c].kind]);
            putc('\n');
        }
    }
    var g = modules[m].first_gvar;
    if g >= 0 { putc('\n'); }
    while g >= 0 { print_global_var(g); putc('\n'); g = globs[glob_of(g)].next; }
    var a = modules[m].first_alias;
    if a >= 0 { putc('\n'); }
    while a >= 0 { print_alias(a, true); a = globs[glob_of(a)].next; }
    var i = modules[m].first_ifunc;
    if i >= 0 { putc('\n'); }
    while i >= 0 { print_alias(i, false); i = globs[glob_of(i)].next; }
    var f = modules[m].first_func;
    while f >= 0 { putc('\n'); print_function(f); f = globs[glob_of(f)].next; }
    if as_order.len > 0 {
        putc('\n');
        for s, k in as_order {
            put("attributes #");
            put_int(k);
            put(" = { ");
            put_attr_set(s, true);
            put(" }\n");
        }
    }
    var any_named = false;
    for nm in named_mds { if nm.module == m { any_named = true; } }
    if any_named { putc('\n'); }
    for nm in named_mds {
        if nm.module != m { continue; }
        putc('!');
        put_md_ident(sbytes(nm.name));
        put(" = !{");
        for k in nm.nops {
            if k > 0 { put(", "); }
            let s = mdslot[md_ops[nm.ops + k]];
            if s < 0 { put("<badref>"); } else { putc('!'); put_int(s as i64); }
        }
        put("}\n");
    }
    if md_order.len > 0 {
        putc('\n');
        for md, k in md_order {
            putc('!');
            put_int(k);
            put(" = ");
            put_md_body(md);
            putc('\n');
        }
    }
}


fn type_str(t: i32) -> u8[>..] {
    let mark = out.len;
    put_type(t);
    var r: u8[>..] = [];
    r.append(out[mark..]);
    out.resize(mark);
    return r;
}

// Slot of a local value of a function that is not being printed (AsmWriter's createSlotTracker).
fn foreign_local_slot(v: i32) -> i32 {
    let k = vals[v].kind;
    var f: i32 = -1;
    if k == VK_ARG { f = args_parent[vals[v].sub]; }
    else if k == VK_BLOCK { f = blocks[block_of(v)].parent; }
    else { let b = insts[inst_of(v)].parent; if b >= 0 { f = blocks[block_of(b)].parent; } }
    if f < 0 { return -1; }
    var n: i32 = 0;
    for j in func_nargs(f) {
        let a = func_arg(f, j);
        if vals[a].name < 0 { if a == v { return n; } n++; }
    }
    var b = globs[glob_of(f)].first_block;
    while b >= 0 {
        if vals[b].name < 0 { if b == v { return n; } n++; }
        var iv = blocks[block_of(b)].first;
        while iv >= 0 {
            if vals[iv].ty != T_VOID && vals[iv].name < 0 { if iv == v { return n; } n++; }
            iv = insts[inst_of(iv)].next;
        }
        b = blocks[block_of(b)].next;
    }
    return -1;
}
