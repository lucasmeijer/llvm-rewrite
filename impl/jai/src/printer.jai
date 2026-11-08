// Port of llvm/lib/IR/AsmWriter.cpp (AssemblyWriter, SlotTracker, TypePrinting) and TypeFinder
// (llvm/lib/IR/TypeFinder.cpp).

W: struct {
    buf: [..] u8;
    // SlotTracker
    mslot: [..] s32;        // module slots, indexed by value id (-1 none)
    fslot: [..] s32;        // function slots, indexed by value id
    ftouched: [..] Value_Id;
    md_slot: Table(Md_Id, s32);
    md_order: [..] Md_Id;
    as_slot: Table(u32, s32);
    as_order: [..] u32;
    // TypePrinting
    type_number: Table(Type_Id, s32);
    named_types: [..] Type_Id;
    numbered_types: [..] Type_Id;
    // TypeFinder state
    tf_visited_types: [..] bool;
    tf_visited_consts: Table(Value_Id, bool);
    tf_visited_md: Table(Md_Id, bool);
    tf_structs: [..] Type_Id;
};

out :: (s: string) {
    n := W.buf.count;
    array_resize(*W.buf, n + s.count, initialize = false);
    memcpy(W.buf.data + n, s.data, s.count);
}
outc :: inline (c: u8) { array_add(*W.buf, c); }
out_u64 :: (x: u64) {
    buf: [24] u8;
    n := 0;
    if x == 0 { outc(#char "0"); return; }
    while x > 0 { buf[n] = cast(u8)(#char "0" + x % 10); x /= 10; n += 1; }
    while n > 0 { n -= 1; outc(buf[n]); }
}
out_s64 :: (x: s64) {
    if x < 0 { outc(#char "-"); out_u64(cast,no_check(u64)(-x)); }
    else out_u64(cast(u64) x);
}

current_column :: () -> s64 {
    i := W.buf.count - 1;
    n := 0;
    while i >= 0 && W.buf[i] != #char "\n" { n += 1; i -= 1; }
    return n;
}

pad_to_column :: (c: s64) {
    cur := current_column();
    n := max(c - cur, 1);
    if n > 0 for 0..n-1 outc(#char " ");
}

HEXDIGITS :: "0123456789ABCDEF";

print_escaped_string :: (s: string) {
    for i: 0..s.count-1 {
        c := s[i];
        if c == #char "\\" { outc(#char "\\"); outc(c); }
        else if c >= 0x20 && c <= 0x7E && c != #char "\"" outc(c);
        else { outc(#char "\\"); outc(HEXDIGITS[c >> 4]); outc(HEXDIGITS[c & 0xF]); }
    }
}

print_llvm_name_without_prefix :: (name: string) {
    needs_quotes := c_isdigit(name[0]);
    if !needs_quotes {
        for i: 0..name.count-1 {
            c := name[i];
            if !c_isalnum(c) && c != #char "-" && c != #char "." && c != #char "_" { needs_quotes = true; break; }
        }
    }
    if !needs_quotes { out(name); return; }
    outc(#char "\"");
    print_escaped_string(name);
    outc(#char "\"");
}
print_llvm_name :: (name: string, prefix: u8) {
    if prefix != 0 outc(prefix);
    print_llvm_name_without_prefix(name);
}

// ---------------------------------------------------------------- types

print_type :: (t: Type_Id) {
    r := ir.types[t];
    if r.kind == {
        case .VOID; out("void"); case .HALF; out("half"); case .BFLOAT; out("bfloat"); case .FLOAT; out("float");
        case .DOUBLE; out("double"); case .X86_FP80; out("x86_fp80"); case .FP128; out("fp128");
        case .PPC_FP128; out("ppc_fp128"); case .LABEL; out("label"); case .METADATA; out("metadata");
        case .X86_AMX; out("x86_amx"); case .TOKEN; out("token");
        case .BYTE; outc(#char "b"); out_u64(r.a);
        case .INT; outc(#char "i"); out_u64(r.a);
        case .FUNC;
            print_type(type_sub(t, 0));
            out(" (");
            for i: 1..r.nsub-1 { if i > 1 out(", "); print_type(type_sub(t, i)); }
            if r.flags & TYF_VARARG { if r.nsub > 1 out(", "); out("..."); }
            outc(#char ")");
        case .STRUCT;
            if r.flags & TYF_LITERAL { print_struct_body(t); return; }
            if r.name.count { print_llvm_name(r.name, #char "%"); return; }
            found, n := table_find(*W.type_number, t);
            if found { outc(#char "%"); out_s64(n); }
            else out("%\"type 0x0\"");
        case .PTR;
            out("ptr");
            if r.a != 0 { out(" addrspace("); out_u64(r.a); outc(#char ")"); }
        case .ARRAY;
            outc(#char "["); out_u64(r.a); out(" x "); print_type(type_elem(t)); outc(#char "]");
        case .VECTOR; #through;
        case .SVECTOR;
            outc(#char "<");
            if r.kind == .SVECTOR out("vscale x ");
            out_u64(r.a); out(" x "); print_type(type_elem(t)); outc(#char ">");
        case .TARGET_EXT;
            out("target(\""); print_escaped_string(r.name); outc(#char "\"");
            if r.nsub > 0 for i: 0..r.nsub-1 { out(", "); print_type(type_sub(t, i)); }
            if r.nints > 0 for i: 0..r.nints-1 { out(", "); out_u64(ir.type_list[r.ints + i]); }
            outc(#char ")");
    }
}

print_struct_body :: (t: Type_Id) {
    r := ir.types[t];
    if r.flags & TYF_OPAQUE { out("opaque"); return; }
    if r.flags & TYF_PACKED outc(#char "<");
    if r.nsub == 0 out("{}");
    else {
        out("{ ");
        if r.nsub > 0 for i: 0..r.nsub-1 { if i > 0 out(", "); print_type(type_sub(t, i)); }
        out(" }");
    }
    if r.flags & TYF_PACKED outc(#char ">");
}

type_to_string :: (t: Type_Id) -> string {
    start := W.buf.count;
    print_type(t);
    v: string; v.data = W.buf.data + start; v.count = W.buf.count - start;
    s := copy_string(v,, allocator = temp);
    W.buf.count = start;
    return s;
}

// ---------------------------------------------------------------- TypeFinder

tf_incorporate_type :: (t: Type_Id) {
    while W.tf_visited_types.count <= t array_add(*W.tf_visited_types, false);
    if W.tf_visited_types[t] return;
    W.tf_visited_types[t] = true;
    work: [..] Type_Id; work.allocator = temp;
    array_add(*work, t);
    while work.count {
        ty := pop(*work);
        if type_kind(ty) == .STRUCT array_add(*W.tf_structs, ty);
        r := ir.types[ty];
        i := cast(s64) r.nsub - 1;
        while i >= 0 {
            st := ir.type_list[r.sub + cast(u32) i];
            while W.tf_visited_types.count <= st array_add(*W.tf_visited_types, false);
            if !W.tf_visited_types[st] { W.tf_visited_types[st] = true; array_add(*work, st); }
            i -= 1;
        }
    }
}

tf_incorporate_value :: (v: Value_Id) {
    if v == NONE return;
    k := vkind(v);
    if k == .MD_VALUE {
        m := ir.v_aux[v];
        if m == NONE return;
        mk := ir.mds[m].kind;
        if mk == .TUPLE || mk == .DI { tf_incorporate_md(m); return; }
        if mk == .VALUE { tf_incorporate_value(ir.mds[m].value); return; }
        return;
    }
    if !is_constant_kind(k) || is_global_value(k) return;
    if table_contains(*W.tf_visited_consts, v) return;
    table_add(*W.tf_visited_consts, v, true);
    tf_incorporate_type(vtype(v));
    if k == .C_EXPR && cexpr(v).op == .GEP tf_incorporate_type(cexpr(v).ty2);
    if nops(v) > 0 for i: 0..nops(v)-1 tf_incorporate_value(op(v, i));
}

tf_incorporate_md :: (m: Md_Id) {
    if table_contains(*W.tf_visited_md, m) return;
    table_add(*W.tf_visited_md, m, true);
    r := ir.mds[m];
    for i: 0..cast(s64)r.nops-1 {
        o := ir.md_ops[r.ops + cast(u32) i];
        if o == NONE continue;
        ok := ir.mds[o].kind;
        if ok == .TUPLE || ok == .DI || ok == .SPECIAL { tf_incorporate_md(o); continue; }
        if ok == .VALUE {
            v := ir.mds[o].value;
            if is_constant_kind(vkind(v)) tf_incorporate_value(v);
        }
    }
}

tf_incorporate_attr_set :: (s: u32) {
    for attr_set_items(s) if it.kind > .LAST_ENUM && it.kind < .LAST_TYPE && it.ty != NONE tf_incorporate_type(it.ty);
}
tf_incorporate_attrs :: (l: u32) {
    if l == 0 return;
    row := ir.attr_lists[l];
    // AttributeList index order: function, return, params
    tf_incorporate_attr_set(row.fn);
    tf_incorporate_attr_set(row.ret);
    for row.params tf_incorporate_attr_set(it);
}

type_finder_run :: () {
    for g: ir.m_globals {
        tf_incorporate_type(glob(g).value_type);
        if glob(g).has_init tf_incorporate_value(op(g, 0));
    }
    for a: ir.m_aliases {
        tf_incorporate_type(glob(a).value_type);
        tf_incorporate_value(op(a, 0));
    }
    for i: ir.m_ifuncs tf_incorporate_type(glob(i).value_type);
    mds: [..] Kind_Md; mds.allocator = temp;
    for f: ir.m_functions {
        g := glob(f);
        tf_incorporate_type(g.value_type);
        tf_incorporate_attrs(g.attrs);
        if g.has_personality tf_incorporate_value(op(f, 0));
        if g.has_prefix tf_incorporate_value(op(f, 1));
        if g.has_prologue tf_incorporate_value(op(f, 2));
        if g.nargs > 0 for ai: 0..g.nargs-1 tf_incorporate_value(fn_arg(f, ai));
        b := g.first_block;
        while b != NONE {
            i := block(b).first;
            while i != NONE {
                tf_incorporate_type(vtype(i));
                if nops(i) > 0 for oi: 0..nops(i)-1 {
                    o := op(i, oi);
                    if o != NONE && vkind(o) != .INST tf_incorporate_value(o);
                }
                r := inst(i);
                if r.op == .GEP tf_incorporate_type(r.ty2);
                if r.op == .ALLOCA tf_incorporate_type(r.ty2);
                if r.op == .CALL || r.op == .INVOKE || r.op == .CALLBR tf_incorporate_attrs(r.attrs);
                get_all_metadata(i, *mds);
                for mds if it.kind != 0 tf_incorporate_md(it.md);
                i = r.next;
            }
            b = block(b).next;
        }
    }
    for nm: ir.named_md for nm.ops tf_incorporate_md(it);
}

type_printing_init :: () {
    type_finder_run();
    next: s32 = 0;
    for W.tf_structs {
        r := ir.types[it];
        if r.flags & TYF_LITERAL continue;
        if r.name.count == 0 { table_add(*W.type_number, it, next); next += 1; array_add(*W.numbered_types, it); }
        else array_add(*W.named_types, it);
    }
}

// ---------------------------------------------------------------- SlotTracker

ensure_slot_arrays :: () {
    n := ir.v_kind.count;
    while W.mslot.count < n array_add(*W.mslot, -1);
    while W.fslot.count < n array_add(*W.fslot, -1);
}

create_md_slot :: (m: Md_Id) {
    if m == NONE return;
    k := ir.mds[m].kind;
    if k != .TUPLE && k != .DI && k != .SPECIAL return;
    if is_inline_md(m) {
        // no slot (SlotTracker::CreateMetadataSlot skips DIExpression; DIArgList is not an MDNode), but the
        // writer still reaches nodes through a DIArgList's operands only as values
        return;
    }
    if table_contains(*W.md_slot, m) return;
    table_add(*W.md_slot, m, cast(s32) W.md_order.count);
    array_add(*W.md_order, m);
    r := ir.mds[m];
    for i: 0..cast(s64)r.nops-1 {
        o := ir.md_ops[r.ops + cast(u32) i];
        if o != NONE create_md_slot(o);
    }
}

create_as_slot :: (s: u32) {
    if s == 0 return;
    if table_contains(*W.as_slot, s) return;
    table_add(*W.as_slot, s, cast(s32) W.as_order.count);
    array_add(*W.as_order, s);
}

process_global_object_md :: (v: Value_Id) {
    mds: [..] Kind_Md; mds.allocator = temp;
    get_all_metadata(v, *mds);
    for mds create_md_slot(it.md);
}

process_module :: () {
    ensure_slot_arrays();
    next: s32 = 0;
    for g: ir.m_globals {
        if vname(g).count == 0 { W.mslot[g] = next; next += 1; }
        process_global_object_md(g);
        create_as_slot(glob(g).attrs);
    }
    for a: ir.m_aliases if vname(a).count == 0 { W.mslot[a] = next; next += 1; }
    for i: ir.m_ifuncs {
        if vname(i).count == 0 { W.mslot[i] = next; next += 1; }
        process_global_object_md(i);
    }
    for nm: ir.named_md for nm.ops create_md_slot(it);
    for f: ir.m_functions {
        if vname(f).count == 0 { W.mslot[f] = next; next += 1; }
        create_as_slot(attr_list_fn(glob(f).attrs));
    }
}

called_function :: (i: Value_Id) -> Value_Id {
    c := op(i, nops(i) - 1);
    if c != NONE && vkind(c) == .FUNCTION && glob(c).value_type == inst(i).ty2 return c;
    return NONE;
}
callee_operand :: (i: Value_Id) -> Value_Id { return op(i, nops(i) - 1); }

process_function :: (f: Value_Id) {
    ensure_slot_arrays();
    for W.ftouched W.fslot[it] = -1;
    W.ftouched.count = 0;
    next: s32 = 0;
    // processFunctionMetadata (lazily, per function)
    process_global_object_md(f);
    mds: [..] Kind_Md; mds.allocator = temp;
    g := glob(f);
    b := g.first_block;
    while b != NONE {
        i := block(b).first;
        while i != NONE {
            r := inst(i);
            if r.records slot_records_of(i);
            if r.op == .CALL {
                cf := called_function(i);
                if cf != NONE && glob(cf).intrinsic {
                    if nops(i) > 0 for oi: 0..nops(i)-1 {
                        o := op(i, oi);
                        if o != NONE && vkind(o) == .MD_VALUE {
                            m := ir.v_aux[o];
                            if m != NONE && (ir.mds[m].kind == .TUPLE || ir.mds[m].kind == .DI || ir.mds[m].kind == .SPECIAL) create_md_slot(m);
                        }
                    }
                }
            }
            get_all_metadata(i, *mds);
            for mds create_md_slot(it.md);
            i = r.next;
        }
        b = block(b).next;
    }
    if g.nargs > 0 for ai: 0..g.nargs-1 {
        a := fn_arg(f, ai);
        if vname(a).count == 0 { W.fslot[a] = next; next += 1; array_add(*W.ftouched, a); }
    }
    b = g.first_block;
    while b != NONE {
        if vname(b).count == 0 { W.fslot[b] = next; next += 1; array_add(*W.ftouched, b); }
        i := block(b).first;
        while i != NONE {
            r := inst(i);
            if vtype(i) != ir.t_void && vname(i).count == 0 { W.fslot[i] = next; next += 1; array_add(*W.ftouched, i); }
            if r.op == .CALL || r.op == .INVOKE || r.op == .CALLBR create_as_slot(attr_list_fn(r.attrs));
            i = r.next;
        }
        b = block(b).next;
    }
}

// ---------------------------------------------------------------- values

write_operand :: (v: Value_Id, with_type: bool) {
    if v == NONE { out("<null operand!>"); return; }
    if with_type { print_type(vtype(v)); outc(#char " "); }
    k := vkind(v);
    name := vname(v);
    if name.count && k != .PLACEHOLDER {
        print_llvm_name(name, ifx is_global_value(k) then cast(u8) #char "@" else #char "%");
        return;
    }
    if is_constant_kind(k) && !is_global_value(k) { write_constant(v); return; }
    if k == .INLINE_ASM {
        a := inline_asms[ir.v_aux[v]];
        out("asm ");
        if a.flags & 1 out("sideeffect ");
        if a.flags & 2 out("alignstack ");
        if a.flags & 4 out("inteldialect ");
        if a.flags & 8 out("unwind ");
        outc(#char "\""); print_escaped_string(a.asm_str); out("\", \""); print_escaped_string(a.constraints); outc(#char "\"");
        return;
    }
    if k == .MD_VALUE { write_md_operand(ir.v_aux[v], true); return; }
    if is_global_value(k) {
        s := ifx v < W.mslot.count then W.mslot[v] else -1;
        if s >= 0 { outc(#char "@"); out_s64(s); } else out("<badref>");
        return;
    }
    s := ifx v < W.fslot.count then W.fslot[v] else -1;
    if s >= 0 { outc(#char "%"); out_s64(s); } else out("<badref>");
}

write_ap_float :: (k: Type_Kind, w: [] u64) {
    if k == .PPC_FP128 {
        // ForceBitwiseOutput unless the second double is +0.0; otherwise it prints like its first double, but
        // the decimal form only when it denotes exactly that double
        if w[1] == 0 {
            hw := NewArray(1, u64,, allocator = temp); hw[0] = w[0];
            hd := fp_decode(.DOUBLE, hw);
            if hd.cat == .INF || hd.cat == .NAN { write_ap_float(.DOUBLE, hw); return; }
            s := fp_to_string_e6(.DOUBLE, hw);
            if ppc_decimal_is_double(s, w[0]) { out(s); return; }
        }
        out("f"); write_full_hex(w, 128);
        return;
    }
    d := fp_decode(k, w);
    if k != .PPC_FP128 {
        if d.cat == .INF { outc(ifx d.neg then cast(u8) #char "-" else #char "+"); out("inf"); return; }
        if d.cat == .NAN {
            outc(ifx d.neg then cast(u8) #char "-" else #char "+");
            p, mx, mn, bits := fp_semantics(k);
            // payload = fraction bits (x87: excluding the explicit integer bit)
            fbits := ifx k == .X86_FP80 then 63 else p - 1;
            payload: Big; payload.allocator = temp;
            if fbits > 0 for i: 0..fbits-1 if big_bit(d.sig, i) { li := i / 32; while payload.count <= li array_add(*payload, 0); payload[li] |= cast(u32)1 << cast(u32)(i % 32); }
            big_trim(*payload);
            qbit := fbits - 1;
            quiet := big_bit(payload, qbit);
            only_quiet := quiet && big_bitlen(payload) == qbit + 1 && !big_any_below(payload, qbit);
            if only_quiet { out("qnan"); return; }
            if !quiet outc(#char "s");
            out("nan(");
            // clear the quiet bit, print the rest in hex with no leading zeros
            rest: Big; rest.allocator = temp;
            if qbit > 0 for i: 0..qbit-1 if big_bit(payload, i) { li := i / 32; while rest.count <= li array_add(*rest, 0); rest[li] |= cast(u32)1 << cast(u32)(i % 32); }
            big_trim(*rest);
            out("0x"); out(big_to_hex(rest));
            outc(#char ")");
            return;
        }
    }
    if k == .PPC_FP128 || d.cat == .NAN || d.cat == .INF {
        // not exercised: fall through to hex
    } else {
        s := fp_to_string_e6(k, w);
        w2, ok, of, zr := fp_from_string(k, s);
        same := ok;
        if ok for w2 if it != w[it_index] same = false;
        if same { out(s); return; }
    }
    outc(#char "f");
    pp, mx2, mn2, nbits := fp_semantics(k);
    write_full_hex(w, cast(u32) nbits);
}

write_full_hex :: (w: [] u64, bits: u32) {
    nd := max((bits + 3) / 4, 1);
    out("0x");
    if nd > 0 for i: 0..nd-1 {
        bitpos := (nd - 1 - i) * 4;
        nib := (w[bitpos / 64] >> (bitpos % 64)) & 0xF;
        outc(HEXDIGITS[nib]);
    }
}

write_int_value :: (t: Type_Id, w: [] u64) {
    st := scalar_type(t);
    if st == ir.t_i1 { out(ifx (w[0] & 1) != 0 then "true" else "false"); return; }
    out(apint_to_signed_decimal(w, type_bits(st)));
}

// ConstantDataSequential element as a printed constant
write_data_element :: (et: Type_Id, x: u64) {
    print_type(et);
    outc(#char " ");
    if is_fp_type(et) { w: [1] u64; w[0] = x; write_ap_float(type_kind(et), w); }
    else { w: [1] u64; w[0] = x; write_int_value(et, w); }
}

write_constant :: (v: Value_Id) {
    t := vtype(v);
    k := vkind(v);
    if k == {
        case .C_INT;
            if is_vector_type(t) { out("splat ("); print_type(type_elem(t)); outc(#char " "); }
            write_int_value(t, const_int_value(v));
            if is_vector_type(t) outc(#char ")");
        case .C_FP;
            if is_vector_type(t) {
                if words_all_zero(const_fp_value(v)) { out("zeroinitializer"); return; }
                out("splat ("); print_type(type_elem(t)); outc(#char " ");
            }
            write_ap_float(type_kind(scalar_type(t)), const_fp_value(v));
            if is_vector_type(t) outc(#char ")");
        case .C_ZERO; #through;
        case .C_TARGET_NONE; out("zeroinitializer");
        case .C_BLOCKADDR;
            out("blockaddress(");
            write_operand(op(v, 0), false);
            out(", ");
            bb := op(v, 1);
            // the block may belong to another function: number it in that function's context
            write_block_ref(bb);
            outc(#char ")");
        case .C_DSO_EQUIV; out("dso_local_equivalent "); write_operand(op(v, 0), false);
        case .C_NO_CFI; out("no_cfi "); write_operand(op(v, 0), false);
        case .C_PTRAUTH;
            out("ptrauth (");
            nw: u32 = 2;
            if !is_null_value(op(v, 2)) nw = 3;
            if vkind(op(v, 3)) != .C_NULL nw = 4;
            if vkind(op(v, 4)) != .C_NULL nw = 5;
            for i: 0..nw-1 { if i > 0 out(", "); write_operand(op(v, i), true); }
            outc(#char ")");
        case .C_ARRAY;
            outc(#char "[");
            if nops(v) > 0 for i: 0..nops(v)-1 { if i > 0 out(", "); write_operand(op(v, i), true); }
            outc(#char "]");
        case .C_DATA;
            et := type_elem(t);
            n := const_data_count(v);
            if type_kind(t) == .ARRAY && et == ir.t_i8 {
                out("c\"");
                if n > 0 for i: 0..n-1 {
                    c := cast(u8) const_data_elt(v, i);
                    if c == #char "\\" { outc(#char "\\"); outc(c); }
                    else if c >= 0x20 && c <= 0x7E && c != #char "\"" outc(c);
                    else { outc(#char "\\"); outc(HEXDIGITS[c >> 4]); outc(HEXDIGITS[c & 0xF]); }
                }
                outc(#char "\"");
                return;
            }
            if type_kind(t) == .ARRAY {
                outc(#char "[");
                if n > 0 for i: 0..n-1 { if i > 0 out(", "); write_data_element(et, const_data_elt(v, i)); }
                outc(#char "]");
                return;
            }
            // vector: splat?
            splat := true;
            for i: 1..n-1 if const_data_elt(v, i) != const_data_elt(v, 0) { splat = false; break; }
            if splat { out("splat ("); write_data_element(et, const_data_elt(v, 0)); outc(#char ")"); return; }
            outc(#char "<");
            if n > 0 for i: 0..n-1 { if i > 0 out(", "); write_data_element(et, const_data_elt(v, i)); }
            outc(#char ">");
        case .C_STRUCT;
            packed := (ir.types[t].flags & TYF_PACKED) != 0;
            if packed outc(#char "<");
            outc(#char "{");
            if nops(v) != 0 {
                outc(#char " ");
                if nops(v) > 0 for i: 0..nops(v)-1 { if i > 0 out(", "); write_operand(op(v, i), true); }
                outc(#char " ");
            }
            outc(#char "}");
            if packed outc(#char ">");
        case .C_VECTOR;
            n := nops(v);
            first := op(v, 0);
            splat := true;
            for i: 1..n-1 if op(v, i) != first { splat = false; break; }
            fk := vkind(first);
            if splat && (fk == .C_INT || fk == .C_FP) { out("splat ("); write_operand(first, true); outc(#char ")"); return; }
            outc(#char "<");
            if n > 0 for i: 0..n-1 { if i > 0 out(", "); write_operand(op(v, i), true); }
            outc(#char ">");
        case .C_NULL;
            if is_vector_type(t) { out("splat ("); print_type(type_elem(t)); out(" null)"); return; }
            out("null");
        case .C_TOKEN_NONE; out("none");
        case .C_POISON; out("poison");
        case .C_UNDEF; out("undef");
        case .C_EXPR;
            e := cexpr(v);
            if e.op == .SHUFFLEVECTOR {
                sv := cf_shuffle_splat_value(v);
                if sv != NONE && (vkind(sv) == .C_INT || vkind(sv) == .C_FP) {
                    out("splat ("); write_operand(sv, true); outc(#char ")");
                    return;
                }
            }
            out(opcode_name(e.op));
            write_optimization_info(e.op, e.flags, true);
            if e.op == .GEP && (e.flags & F_INRANGE) {
                lo := cast,no_check(s64)((cast(u64) ir.u32_pool[e.idx]) | ((cast(u64) ir.u32_pool[e.idx + 1]) << 32));
                hi := cast,no_check(s64)((cast(u64) ir.u32_pool[e.idx + 2]) | ((cast(u64) ir.u32_pool[e.idx + 3]) << 32));
                out(" inrange("); out_s64(lo); out(", "); out_s64(hi); outc(#char ")");
            }
            out(" (");
            if e.op == .GEP { print_type(e.ty2); out(", "); }
            if nops(v) > 0 for i: 0..nops(v)-1 { if i > 0 out(", "); write_operand(op(v, i), true); }
            if is_cast_op(e.op) { out(" to "); print_type(t); }
            if e.op == .SHUFFLEVECTOR print_shuffle_mask_row(t, e.*);
            outc(#char ")");
        case;
            out("<placeholder or erroneous Constant>");
    }
}

write_block_ref :: (bb: Value_Id) {
    if vname(bb).count { print_llvm_name(vname(bb), #char "%"); return; }
    s := ifx bb < W.fslot.count then W.fslot[bb] else -1;
    if s >= 0 && block_in_current_function(bb) { outc(#char "%"); out_s64(s); return; }
    // number the block within its own function (createSlotTracker)
    f := block(bb).parent;
    n: s32 = 0;
    g := glob(f);
    if g.nargs > 0 for ai: 0..g.nargs-1 if vname(fn_arg(f, ai)).count == 0 n += 1;
    b := g.first_block;
    while b != NONE {
        if vname(b).count == 0 { if b == bb { outc(#char "%"); out_s64(n); return; } n += 1; }
        i := block(b).first;
        while i != NONE { if vtype(i) != ir.t_void && vname(i).count == 0 n += 1; i = inst(i).next; }
        b = block(b).next;
    }
    out("<badref>");
}
current_function: Value_Id = NONE;
block_in_current_function :: (bb: Value_Id) -> bool { return block(bb).parent == current_function; }

write_fmf :: (flags: u32) {
    f := (flags >> FMF_SHIFT) & FMF_ALL;
    if f == FMF_ALL { out(" fast"); return; }
    if f & FMF_REASSOC out(" reassoc");
    if f & FMF_NNAN out(" nnan");
    if f & FMF_NINF out(" ninf");
    if f & FMF_NSZ out(" nsz");
    if f & FMF_ARCP out(" arcp");
    if f & FMF_CONTRACT out(" contract");
    if f & FMF_AFN out(" afn");
}

// writeOptimizationInfo. is_fp_math must be computed by the caller for instructions.
write_optimization_info :: (op: Opcode, flags: u32, is_const: bool, fp_math := false) {
    if fp_math write_fmf(flags);
    if op == .ADD || op == .SUB || op == .MUL || op == .SHL {
        if flags & F_NUW out(" nuw");
        if flags & F_NSW out(" nsw");
    } else if op == .UDIV || op == .SDIV || op == .LSHR || op == .ASHR {
        if flags & F_EXACT out(" exact");
    } else if op == .OR {
        if flags & F_EXACT out(" disjoint");
    } else if op == .GEP {
        if flags & F_INBOUNDS out(" inbounds");
        else if flags & F_NUSW out(" nusw");
        if flags & F_GEP_NUW out(" nuw");
    } else if op == .ZEXT || op == .UITOFP {
        if flags & F_EXACT out(" nneg");
    } else if op == .TRUNC {
        if flags & F_NUW out(" nuw");
        if flags & F_NSW out(" nsw");
    } else if op == .ICMP {
        if flags & F_EXACT out(" samesign");
    }
}

// FPMathOperator::classof
is_fp_math_inst :: (i: Value_Id) -> bool {
    r := inst(i);
    if r.op == {
        case .FNEG; #through;
        case .FADD; #through;
        case .FSUB; #through;
        case .FMUL; #through;
        case .FDIV; #through;
        case .FREM; #through;
        case .FPTRUNC; #through;
        case .FPEXT; #through;
        case .FCMP; return true;
        case .UITOFP; #through;
        case .SITOFP; #through;
        case .PHI; #through;
        case .SELECT; #through;
        case .CALL;
            t := vtype(i);
            while type_kind(t) == .ARRAY t = type_elem(t);
            if type_kind(t) == .STRUCT {
                // homogeneous struct of fp
                n := type_nsub(t);
                if n == 0 return false;
                e0 := type_sub(t, 0);
                for j: 1..n-1 if type_sub(t, j) != e0 return false;
                t = e0;
            }
            return is_fp_type(scalar_type(t));
    }
    return false;
}

// ---------------------------------------------------------------- metadata

print_metadata_identifier :: (name: string) {
    if name.count == 0 { out("<empty name> "); return; }
    c := name[0];
    if c_isalpha(c) || c == #char "-" || c == #char "$" || c == #char "." || c == #char "_" outc(c);
    else { outc(#char "\\"); outc(HEXDIGITS[c >> 4]); outc(HEXDIGITS[c & 0xF]); }
    for i: 1..name.count-1 {
        c = name[i];
        if c_isalnum(c) || c == #char "-" || c == #char "$" || c == #char "." || c == #char "_" outc(c);
        else { outc(#char "\\"); outc(HEXDIGITS[c >> 4]); outc(HEXDIGITS[c & 0xF]); }
    }
}

write_md_operand :: (m: Md_Id, from_value: bool) {
    if m == NONE { out("null"); return; }
    r := ir.mds[m];
    if is_inline_md(m) { write_di_node(m); return; }
    if r.kind == .TUPLE || r.kind == .DI || r.kind == .SPECIAL {
        found, s := table_find(*W.md_slot, m);
        if found { outc(#char "!"); out_s64(s); }
        else out("<badref>");
        return;
    }
    if r.kind == .STRING { out("!\""); print_escaped_string(r.str); outc(#char "\""); return; }
    write_operand(r.value, true);
}

write_md_tuple :: (m: Md_Id) {
    r := ir.mds[m];
    out("!{");
    for i: 0..cast(s64)r.nops-1 {
        if i > 0 out(", ");
        o := ir.md_ops[r.ops + cast(u32) i];
        if o == NONE { out("null"); continue; }
        if ir.mds[o].kind == .VALUE { write_operand(ir.mds[o].value, true); continue; }
        write_md_operand(o, false);
    }
    outc(#char "}");
}

print_metadata_attachments :: (mds: [] Kind_Md, sep: string) {
    for mds {
        out(sep);
        outc(#char "!");
        print_metadata_identifier(ir.md_kind_names[it.kind]);
        outc(#char " ");
        write_md_operand(it.md, false);
    }
}

// ---------------------------------------------------------------- attributes

get_mod_ref_str :: (mr: u64) -> string {
    if mr == 0 return "none"; if mr == 1 return "read"; if mr == 2 return "write";
    return "readwrite";
}

write_capture_components :: (cc: u64) {
    if cc == 0 { out("none"); return; }
    first := true;
    sep :: () #expand { if !`first out(", "); `first = false; }
    if (cc & 3) == 1 { sep(); out("address_is_null"); }
    else if (cc & 3) == 3 { sep(); out("address"); }
    if (cc & 12) == 4 { sep(); out("read_provenance"); }
    if (cc & 12) == 12 { sep(); out("provenance"); }
}

// Attribute::getAsString (and AssemblyWriter::writeAttribute for type attributes)
write_attribute :: (a: *Attr, in_group: bool) {
    if a.kind == .STRING_ATTR {
        outc(#char "\""); out(a.key); outc(#char "\"");
        if a.val.count { out("=\""); print_escaped_string(a.val); outc(#char "\""); }
        return;
    }
    name := attr_name(a.kind);
    if a.kind < .LAST_ENUM { out(name); return; }
    if a.kind < .LAST_TYPE {
        out(name);
        if a.ty != NONE { outc(#char "("); print_type(a.ty); outc(#char ")"); }
        return;
    }
    if a.kind == {
        case .Alignment;
            out(ifx in_group then "align=" else "align "); out_u64(a.ival);
        case .StackAlignment; #through;
        case .Dereferenceable; #through;
        case .DereferenceableOrNull;
            out(name);
            if in_group { outc(#char "="); out_u64(a.ival); } else { outc(#char "("); out_u64(a.ival); outc(#char ")"); }
        case .DeadOnReturn;
            out(name);
            if a.ival != 0xFFFF_FFFF_FFFF_FFFF {
                if in_group { outc(#char "="); out_u64(a.ival); } else { outc(#char "("); out_u64(a.ival); outc(#char ")"); }
            }
        case .AllocSize;
            out("allocsize("); out_u64(a.ival >> 32);
            n := a.ival & 0xFFFF_FFFF;
            if n != 0xFFFF_FFFF { outc(#char ","); out_u64(n); }
            outc(#char ")");
        case .VScaleRange;
            out("vscale_range("); out_u64(a.ival >> 32); outc(#char ","); out_u64(a.ival & 0xFFFF_FFFF); outc(#char ")");
        case .UWTable;
            out(ifx a.ival == 2 then "uwtable" else "uwtable(sync)");
        case .AllocKind;
            out("allockind(\"");
            first := true;
            NAMES :: string.["alloc", "realloc", "free", "uninitialized", "zeroed", "aligned"];
            for NAMES if a.ival & (cast(u64)1 << cast(u64) it_index) { if !first outc(#char ","); first = false; out(it); }
            out("\")");
        case .Memory;
            me := a.ival;
            out("memory(");
            first := true;
            other := mem_get(me, 3);
            all_same := true;
            for l: 0..MEM_LOCS-1 if mem_get(me, l) != other all_same = false;
            if other != 0 || all_same { first = false; out(get_mod_ref_str(other)); }
            target_same := mem_get(me, 4) == mem_get(me, 5);
            target_printed := false;
            for l: 0..MEM_LOCS-1 {
                if l == 3 continue;
                mr := mem_get(me, l);
                if mr == other continue;
                if !first && !target_printed out(", ");
                first = false;
                if (l == 4 || l == 5) && target_same {
                    if !target_printed { out("target_mem: "); out(get_mod_ref_str(mr)); target_printed = true; }
                    continue;
                }
                if l == 0 out("argmem: ");
                else if l == 1 out("inaccessiblemem: ");
                else if l == 2 out("errnomem: ");
                else if l == 4 out("target_mem0: ");
                else if l == 5 out("target_mem1: ");
                out(get_mod_ref_str(mr));
            }
            outc(#char ")");
        case .Captures;
            other := a.ival & 0xF; ret := (a.ival >> 4) & 0xF;
            out("captures(");
            first := true;
            if other != 0 || other == ret { write_capture_components(other); first = false; }
            if other != ret { if !first out(", "); out("ret: "); write_capture_components(ret); }
            outc(#char ")");
        case .DenormalFPEnv;
            out("denormal_fpenv(");
            dflt := a.ival & 0xFF; f32 := (a.ival >> 8) & 0xFF;
            pmode :: (m: u64) {
                o := m & 0xF; i := (m >> 4) & 0xF;
                out(DENORMAL_NAMES[o]);
                if i != o { outc(#char "|"); out(DENORMAL_NAMES[i]); }
            }
            if f32 == dflt pmode(dflt);
            else {
                if dflt != 0 { pmode(dflt); out(", "); }
                out("float: ");
                pmode(f32);
            }
            outc(#char ")");
        case .NoFPClass;
            out("nofpclass");
            write_fpclass(a.ival);
        case .Range;
            out("range(i"); out_u64(a.ival); outc(#char " ");
            out(apint_to_signed_decimal(a.lo, cast(u32) a.ival)); out(", ");
            out(apint_to_signed_decimal(a.hi, cast(u32) a.ival)); outc(#char ")");
        case .Initializes;
            out("initializes(");
            for a.lo {
                if it_index > 0 outc(#char ",");
                outc(#char "("); out_s64(cast,no_check(s64) it); out(", "); out_s64(cast,no_check(s64) a.hi[it_index]); outc(#char ")");
            }
            outc(#char ")");
        case; out(name);
    }
}

// operator<<(raw_ostream, FPClassTest)
write_fpclass :: (mask_in: u64) {
    outc(#char "(");
    mask := mask_in;
    if mask == 0 { out("none)"); return; }
    first := true;
    for FPCLASS_NAMES {
        if (mask & it.mask) == it.mask {
            if !first outc(#char " ");
            first = false;
            out(it.name);
            mask &= ~it.mask;
        }
    }
    outc(#char ")");
}

attr_name :: (k: Attr_Kind) -> string {
    for ATTR_NAMES if it.kind == k return it.name;
    return "<unknown attr>";
}

write_attribute_set :: (s: u32, in_group := false) {
    items := attr_set_items(s);
    for * items {
        if it_index > 0 outc(#char " ");
        write_attribute(it, in_group);
    }
}

// ---------------------------------------------------------------- module printing

linkage_name :: (l: Linkage) -> string {
    if l == {
        case .PRIVATE; return "private "; case .INTERNAL; return "internal "; case .LINKONCE_ANY; return "linkonce ";
        case .LINKONCE_ODR; return "linkonce_odr "; case .WEAK_ANY; return "weak "; case .WEAK_ODR; return "weak_odr ";
        case .COMMON; return "common "; case .APPENDING; return "appending "; case .EXTERN_WEAK; return "extern_weak ";
        case .AVAILABLE_EXTERNALLY; return "available_externally ";
    }
    return "";
}

print_dso_location :: (g: *Global_Row) {
    implicit := is_local_linkage(g.linkage) || (g.visibility != 0 && g.linkage != .EXTERN_WEAK);
    if g.dso_local && !implicit out("dso_local ");
}
print_visibility :: (v: u8) { if v == 1 out("hidden "); else if v == 2 out("protected "); }
print_dll :: (d: u8) { if d == 1 out("dllimport "); else if d == 2 out("dllexport "); }
print_tls :: (t: u8) {
    if t == 1 out("thread_local ");
    else if t == 2 out("thread_local(localdynamic) ");
    else if t == 3 out("thread_local(initialexec) ");
    else if t == 4 out("thread_local(localexec) ");
}
unnamed_addr_str :: (u: u8) -> string { if u == 1 return "local_unnamed_addr"; if u == 2 return "unnamed_addr"; return ""; }

maybe_print_comdat :: (v: Value_Id) {
    g := glob(v);
    if g.comdat < 0 return;
    if vkind(v) == .GLOBAL_VAR outc(#char ",");
    out(" comdat");
    cname := ir.comdats[g.comdat].name;
    if vname(v) == cname return;
    outc(#char "(");
    print_llvm_name(cname, #char "$");
    outc(#char ")");
}

print_global :: (gv: Value_Id) {
    write_operand(gv, false);
    out(" = ");
    g := glob(gv);
    if !g.has_init && g.linkage == .EXTERNAL out("external ");
    out(linkage_name(g.linkage));
    print_dso_location(g);
    print_visibility(g.visibility);
    print_dll(g.dll);
    print_tls(g.tls);
    ua := unnamed_addr_str(g.unnamed_addr);
    if ua.count { out(ua); outc(#char " "); }
    if g.addrspace != 0 { out("addrspace("); out_u64(g.addrspace); out(") "); }
    if g.ext_init out("externally_initialized ");
    out(ifx g.is_const then "constant " else "global ");
    print_type(g.value_type);
    if g.has_init { outc(#char " "); write_operand(op(gv, 0), false); }
    if g.section.count { out(", section \""); print_escaped_string(g.section); outc(#char "\""); }
    if g.partition.count { out(", partition \""); print_escaped_string(g.partition); outc(#char "\""); }
    if g.code_model {
        CM :: string.["", "tiny", "small", "kernel", "medium", "large"];
        out(", code_model \""); out(CM[g.code_model]); outc(#char "\"");
    }
    if g.sanitizer & 1 out(", no_sanitize_address");
    if g.sanitizer & 2 out(", no_sanitize_hwaddress");
    if g.sanitizer & 4 out(", sanitize_memtag");
    if g.sanitizer & 8 out(", sanitize_address_dyninit");
    maybe_print_comdat(gv);
    if g.align { out(", align "); out_u64(g.align); }
    mds: [..] Kind_Md; mds.allocator = temp;
    get_all_metadata(gv, *mds);
    print_metadata_attachments(mds, ", ");
    if g.attrs != 0 {
        found, s := table_find(*W.as_slot, g.attrs);
        out(" #"); out_s64(s);
    }
}

print_alias :: (a: Value_Id) {
    write_operand(a, false);
    out(" = ");
    g := glob(a);
    out(linkage_name(g.linkage));
    print_dso_location(g);
    print_visibility(g.visibility);
    print_dll(g.dll);
    print_tls(g.tls);
    ua := unnamed_addr_str(g.unnamed_addr);
    if ua.count { out(ua); outc(#char " "); }
    out("alias ");
    print_type(g.value_type);
    out(", ");
    aliasee := op(a, 0);
    write_operand(aliasee, vkind(aliasee) != .C_EXPR);
    if g.partition.count { out(", partition \""); print_escaped_string(g.partition); outc(#char "\""); }
    outc(#char "\n");
}

print_ifunc :: (a: Value_Id) {
    write_operand(a, false);
    out(" = ");
    g := glob(a);
    out(linkage_name(g.linkage));
    print_dso_location(g);
    print_visibility(g.visibility);
    out("ifunc ");
    print_type(g.value_type);
    out(", ");
    r := op(a, 0);
    write_operand(r, vkind(r) != .C_EXPR);
    if g.partition.count { out(", partition \""); print_escaped_string(g.partition); outc(#char "\""); }
    mds: [..] Kind_Md; mds.allocator = temp;
    get_all_metadata(a, *mds);
    print_metadata_attachments(mds, ", ");
    outc(#char "\n");
}

print_calling_conv :: (cc: u32) {
    for CC_PRINT if it.num == cc { out(it.name); return; }
    out("cc"); out_u64(cc);
}

print_function :: (f: Value_Id) {
    g := glob(f);
    fnattrs := attr_list_fn(g.attrs);
    if fnattrs != 0 {
        first := true;
        has_any := false;
        for attr_set_items(fnattrs) if it.kind != .STRING_ATTR has_any = true;
        if has_any {
            out("; Function Attrs: ");
            items := attr_set_items(fnattrs);
            for * items {
                if it.kind == .STRING_ATTR continue;
                if !first outc(#char " ");
                first = false;
                write_attribute(it, false);
            }
            outc(#char "\n");
        }
    }
    if g.intrinsic && intrinsic_lookup(vname(f)).count == 0 out("; Unknown intrinsic\n");
    process_function(f);
    current_function = f;
    decl := g.first_block == NONE;
    mds: [..] Kind_Md; mds.allocator = temp;
    if decl {
        out("declare");
        get_all_metadata(f, *mds);
        print_metadata_attachments(mds, " ");
        outc(#char " ");
    } else out("define ");
    out(linkage_name(g.linkage));
    print_dso_location(g);
    print_visibility(g.visibility);
    print_dll(g.dll);
    if g.cc != 0 { print_calling_conv(g.cc); outc(#char " "); }
    ft := g.value_type;
    ret := attr_list_ret(g.attrs);
    if ret != 0 { write_attribute_set(ret); outc(#char " "); }
    print_type(func_ret(ft));
    outc(#char " ");
    write_operand(f, false);
    outc(#char "(");
    np := func_nparams(ft);
    if decl {
        if np > 0 for i: 0..np-1 {
            if i > 0 out(", ");
            print_type(func_param(ft, i));
            pa := attr_list_param(g.attrs, i);
            if pa != 0 { outc(#char " "); write_attribute_set(pa); }
        }
    } else {
        if np > 0 for i: 0..np-1 {
            if i > 0 out(", ");
            a := fn_arg(f, i);
            print_type(vtype(a));
            pa := attr_list_param(g.attrs, i);
            if pa != 0 { outc(#char " "); write_attribute_set(pa); }
            if vname(a).count { outc(#char " "); print_llvm_name(vname(a), #char "%"); }
            else { out(" %"); out_s64(W.fslot[a]); }
        }
    }
    if func_vararg(ft) { if np > 0 out(", "); out("..."); }
    outc(#char ")");
    ua := unnamed_addr_str(g.unnamed_addr);
    if ua.count { outc(#char " "); out(ua); }
    if g.addrspace != 0 || dl.program_as != 0 { out(" addrspace("); out_u64(g.addrspace); outc(#char ")"); }
    if fnattrs != 0 {
        found, s := table_find(*W.as_slot, fnattrs);
        out(" #"); out_s64(s);
    }
    if g.section.count { out(" section \""); print_escaped_string(g.section); outc(#char "\""); }
    if g.partition.count { out(" partition \""); print_escaped_string(g.partition); outc(#char "\""); }
    maybe_print_comdat(f);
    if g.align { out(" align "); out_u64(g.align); }
    if g.pref_align { out(" prefalign("); out_u64(g.pref_align); outc(#char ")"); }
    if g.gc.count { out(" gc \""); out(g.gc); outc(#char "\""); }
    if g.has_prefix { out(" prefix "); write_operand(op(f, 1), true); }
    if g.has_prologue { out(" prologue "); write_operand(op(f, 2), true); }
    if g.has_personality { out(" personality "); write_operand(op(f, 0), true); }
    if decl {
        outc(#char "\n");
    } else {
        get_all_metadata(f, *mds);
        print_metadata_attachments(mds, " ");
        out(" {");
        b := g.first_block;
        while b != NONE {
            print_basic_block(b, b == g.first_block);
            b = block(b).next;
        }
        out("}\n");
    }
    current_function = NONE;
}

// AssemblyAnnotationWriter hooks used by Function::print(OS, AAW) (emitBasicBlockStartAnnot, emitInstructionAnnot);
// null = no annotation writer. Set them around a print_function call (memoryssa.jai).
print_annot_block: (b: Value_Id) = null;
print_annot_inst: (i: Value_Id) = null;

print_basic_block :: (b: Value_Id, is_entry: bool) {
    if vname(b).count {
        outc(#char "\n");
        print_llvm_name(vname(b), 0);
        outc(#char ":");
    } else if !is_entry {
        outc(#char "\n");
        s := W.fslot[b];
        if s >= 0 { out_s64(s); outc(#char ":"); } else out("<badref>:");
    }
    if !is_entry {
        pad_to_column(50);
        outc(#char ";");
        // predecessors: users of the block that are terminators, in use-list order
        first := true;
        u := ir.v_first_use[b];
        while u != NONE {
            user := ir.u_user[u];
            if vkind(user) == .INST && is_terminator(inst_op(user)) {
                if first out(" preds = "); else out(", ");
                first = false;
                write_operand(inst(user).parent, false);
            }
            u = ir.u_next[u];
        }
        if first out(" No predecessors!");
    }
    outc(#char "\n");
    if print_annot_block print_annot_block(b);
    i := block(b).first;
    while i != NONE {
        if inst(i).records print_records_of(i);
        if print_annot_inst print_annot_inst(i);
        print_instruction(i);
        outc(#char "\n");
        i = inst(i).next;
    }
}

write_param_operand :: (v: Value_Id, attrs: u32) {
    print_type(vtype(v));
    if attrs != 0 { outc(#char " "); write_attribute_set(attrs); }
    outc(#char " ");
    write_operand(v, false);
}

write_atomic :: (ord: u8, sync: u32) {
    if ord == 0 return;
    if sync != 0 { out(" syncscope(\""); print_escaped_string(ir.sync_scopes[sync]); out("\")"); }
    outc(#char " "); out(ORDERING_NAMES[ord]);
}

write_operand_bundles :: (i: Value_Id) {
    r := inst(i);
    if r.nidx == 0 return;
    out(" [ ");
    if r.nidx > 0 for bi: 0..r.nidx-1 {
        if bi > 0 out(", ");
        tag := ir.u32_pool[r.idx + bi * 3];
        b0 := ir.u32_pool[r.idx + bi * 3 + 1];
        b1 := ir.u32_pool[r.idx + bi * 3 + 2];
        outc(#char "\""); print_escaped_string(bundle_tags[tag]); outc(#char "\"");
        outc(#char "(");
        if b1 > b0 for k: b0..b1-1 { if k > b0 out(", "); write_operand(op(i, k), true); }
        outc(#char ")");
    }
    out(" ]");
}

call_arg_count :: (i: Value_Id) -> u32 {
    r := inst(i);
    n := func_nparams(r.ty2);
    // varargs: all operands before bundles and the trailing callee/dests
    total := nops(i);
    trailing: u32 = ifx r.op == .INVOKE then cast(u32) 3 else ifx r.op == .CALLBR then 2 + r.addrspace else 1;
    nb: u32 = 0;
    if r.nidx { last := r.nidx - 1; nb = ir.u32_pool[r.idx + last * 3 + 2] - ir.u32_pool[r.idx + 1]; }
    return total - trailing - nb;
}

print_shuffle_mask :: (t: Type_Id, i: Value_Id) { print_shuffle_mask_row(t, inst(i).*); }
print_shuffle_mask_row :: (t: Type_Id, r: Inst_Row) {
    out(", <");
    if type_kind(t) == .SVECTOR out("vscale x ");
    out_u64(r.nidx); out(" x i32> ");
    all_zero := true; all_poison := true;
    if r.nidx > 0 for k: 0..r.nidx-1 {
        e := ir.u32_pool[r.idx + k];
        if e != 0 all_zero = false;
        if e != 0xFFFF_FFFF all_poison = false;
    }
    if all_zero { out("zeroinitializer"); return; }
    if all_poison { out("poison"); return; }
    outc(#char "<");
    if r.nidx > 0 for k: 0..r.nidx-1 {
        if k > 0 out(", ");
        out("i32 ");
        e := ir.u32_pool[r.idx + k];
        if e == 0xFFFF_FFFF out("poison"); else out_s64(cast(s32) e);
    }
    outc(#char ">");
}

print_instruction :: (i: Value_Id) {
    r := inst(i);
    out("  ");
    if vname(i).count { print_llvm_name(vname(i), #char "%"); out(" = "); }
    else if vtype(i) != ir.t_void {
        s := W.fslot[i];
        if s < 0 out("<badref> = "); else { outc(#char "%"); out_s64(s); out(" = "); }
    }
    if r.op == .CALL {
        tk := (r.flags >> TAIL_SHIFT) & 3;
        if tk == 2 out("musttail "); else if tk == 1 out("tail "); else if tk == 3 out("notail ");
    }
    out(opcode_name(r.op));
    if (r.op == .LOAD || r.op == .STORE) && r.ord1 != 0 out(" atomic");
    if r.op == .CMPXCHG && (r.flags & F_WEAK) out(" weak");
    if (r.op == .LOAD || r.op == .STORE || r.op == .CMPXCHG || r.op == .ATOMICRMW) && (r.flags & F_VOLATILE) out(" volatile");
    write_optimization_info(r.op, r.flags, false, is_fp_math_inst(i));
    if r.op == .ICMP { outc(#char " "); out(ICMP_PREDS[r.pred - 32]); }
    if r.op == .FCMP { outc(#char " "); out(FCMP_PREDS[r.pred]); }
    if r.op == .ATOMICRMW {
        if r.flags & F_ELEMENTWISE out(" elementwise");
        outc(#char " "); out(RMW_OPS[r.ord2]);
    }
    n := nops(i);
    operand := ifx n > 0 then op(i, 0) else NONE;
    if r.op == {
        case .CONDBR;
            outc(#char " "); write_operand(op(i, 0), true); out(", ");
            write_operand(op(i, 1), true); out(", "); write_operand(op(i, 2), true);
        case .SWITCH;
            outc(#char " "); write_operand(op(i, 0), true); out(", "); write_operand(op(i, 1), true);
            out(" [");
            for k: 2..cast(s64)n-1 {
                out("\n    ");
                write_operand(ir.u_aux[ir.v_ops[i] + cast(u32) k], true); out(", "); write_operand(op(i, cast(u32) k), true);
            }
            out("\n  ]");
        case .INDIRECTBR;
            outc(#char " "); write_operand(operand, true); out(", [");
            for k: 1..n-1 { if k > 1 out(", "); write_operand(op(i, k), true); }
            outc(#char "]");
        case .PHI;
            outc(#char " "); print_type(vtype(i)); outc(#char " ");
            if n > 0 for k: 0..n-1 {
                if k > 0 out(", ");
                out("[ ");
                write_operand(op(i, k), false);
                out(", ");
                write_operand(ir.u_aux[ir.v_ops[i] + k], false);
                out(" ]");
            }
        case .EXTRACTVALUE;
            outc(#char " "); write_operand(op(i, 0), true);
            if r.nidx > 0 for k: 0..r.nidx-1 { out(", "); out_u64(ir.u32_pool[r.idx + k]); }
        case .INSERTVALUE;
            outc(#char " "); write_operand(op(i, 0), true); out(", "); write_operand(op(i, 1), true);
            if r.nidx > 0 for k: 0..r.nidx-1 { out(", "); out_u64(ir.u32_pool[r.idx + k]); }
        case .LANDINGPAD;
            outc(#char " "); print_type(vtype(i));
            cleanup := (r.flags & F_CLEANUP) != 0;
            if cleanup || n != 0 outc(#char "\n");
            if cleanup out("          cleanup");
            if n > 0 for k: 0..n-1 {
                if k != 0 || cleanup outc(#char "\n");
                if ir.u32_pool[r.idx + k] == 0 out("          catch "); else out("          filter ");
                write_operand(op(i, k), true);
            }
        case .CATCHSWITCH;
            out(" within "); write_operand(op(i, 0), false);
            out(" [");
            first: u32 = ifx r.flags & F_HAS_UNWIND then cast(u32) 2 else 1;
            for k: first..n-1 { if k > first out(", "); write_operand(op(i, k), true); }
            out("] unwind ");
            if r.flags & F_HAS_UNWIND write_operand(op(i, 1), true); else out("to caller");
        case .CATCHPAD; #through;
        case .CLEANUPPAD;
            out(" within "); write_operand(op(i, n - 1), false);
            out(" [");
            if n > 1 for k: 0..n-2 { if k > 0 out(", "); write_operand(op(i, k), true); }
            outc(#char "]");
        case .CATCHRET;
            out(" from "); write_operand(op(i, 0), false);
            out(" to "); write_operand(op(i, 1), true);
        case .CLEANUPRET;
            out(" from "); write_operand(op(i, 0), false);
            out(" unwind ");
            if n > 1 write_operand(op(i, 1), true); else out("to caller");
        case .RET;
            if operand == NONE out(" void");
            else { outc(#char " "); write_operand(operand, true); }
        case .CALL; #through;
        case .CALLBR; #through;
        case .INVOKE;
            if r.cc != 0 { outc(#char " "); print_calling_conv(r.cc); }
            callee := callee_operand(i);
            fty := r.ty2;
            ret := attr_list_ret(r.attrs);
            if ret != 0 { outc(#char " "); write_attribute_set(ret); }
            cas := ir.types[vtype(callee)].a;
            if r.op != .CALLBR && (cas != 0 || dl.program_as != 0) { out(" addrspace("); out_u64(cas); outc(#char ")"); }
            outc(#char " ");
            print_type(ifx func_vararg(fty) then fty else func_ret(fty));
            outc(#char " ");
            write_operand(callee, false);
            outc(#char "(");
            na := call_arg_count(i);
            cf := called_function(i);
            pretty := cf != NONE && glob(cf).intrinsic && intrinsic_has_pretty_args(cf);
            if na > 0 for k: 0..na-1 {
                if k > 0 out(", ");
                if pretty print_imm_arg_comment(cf, k, op(i, k));
                write_param_operand(op(i, k), attr_list_param(r.attrs, k));
            }
            if r.op == .CALL && ((r.flags >> TAIL_SHIFT) & 3) == 2 {
                pf := block(r.parent).parent;
                if func_vararg(glob(pf).value_type) { if na > 0 out(", "); out("..."); }
            }
            outc(#char ")");
            fa := attr_list_fn(r.attrs);
            if fa != 0 { found, s := table_find(*W.as_slot, fa); out(" #"); out_s64(s); }
            write_operand_bundles(i);
            if r.op == .INVOKE {
                out("\n          to "); write_operand(op(i, n - 3), true);
                out(" unwind "); write_operand(op(i, n - 2), true);
            }
            if r.op == .CALLBR {
                nd := r.addrspace;
                out("\n          to "); write_operand(op(i, n - 2 - nd), true);
                out(" [");
                if nd > 0 for k: 0..nd-1 { if k > 0 out(", "); write_operand(op(i, n - 1 - nd + k), true); }
                outc(#char "]");
            }
        case .ALLOCA;
            outc(#char " ");
            if r.flags & F_INALLOCA out("inalloca ");
            if r.flags & F_SWIFTERR out("swifterror ");
            print_type(r.ty2);
            sz := op(i, 0);
            is_one := vkind(sz) == .C_INT && vtype(sz) == ir.t_i32 && const_int_zext(sz) == 1;
            if !is_one { out(", "); write_operand(sz, true); }
            if r.align { out(", align "); out_u64(r.align); }
            if r.addrspace != 0 { out(", addrspace("); out_u64(r.addrspace); outc(#char ")"); }
        case;
            if is_cast_op(r.op) {
                if operand != NONE { outc(#char " "); write_operand(operand, true); }
                out(" to "); print_type(vtype(i));
            } else if r.op == .VAARG {
                if operand != NONE { outc(#char " "); write_operand(operand, true); }
                out(", "); print_type(vtype(i));
            } else if operand != NONE {
                if r.op == .GEP { outc(#char " "); print_type(r.ty2); outc(#char ","); }
                else if r.op == .LOAD { outc(#char " "); print_type(vtype(i)); outc(#char ","); }
                print_all := false;
                the_type := vtype(operand);
                if r.op == .SELECT || r.op == .STORE || r.op == .SHUFFLEVECTOR || r.op == .RET || r.op == .CMPXCHG || r.op == .ATOMICRMW {
                    print_all = true;
                } else {
                    for k: 1..n-1 { o := op(i, k); if o != NONE && vtype(o) != the_type { print_all = true; break; } }
                }
                if !print_all { outc(#char " "); print_type(the_type); }
                outc(#char " ");
                if n > 0 for k: 0..n-1 { if k > 0 out(", "); write_operand(op(i, k), print_all); }
            }
    }
    if r.op == .LOAD || r.op == .STORE {
        if r.ord1 != 0 write_atomic(r.ord1, r.sync);
        if r.align { out(", align "); out_u64(r.align); }
    } else if r.op == .CMPXCHG {
        if r.sync != 0 { out(" syncscope(\""); print_escaped_string(ir.sync_scopes[r.sync]); out("\")"); }
        outc(#char " "); out(ORDERING_NAMES[r.ord1]); outc(#char " "); out(ORDERING_NAMES[r.ord2]);
        out(", align "); out_u64(r.align);
    } else if r.op == .ATOMICRMW {
        write_atomic(r.ord1, r.sync);
        out(", align "); out_u64(r.align);
    } else if r.op == .FENCE {
        write_atomic(r.ord1, r.sync);
    } else if r.op == .SHUFFLEVECTOR {
        print_shuffle_mask(vtype(i), i);
    }
    mds: [..] Kind_Md; mds.allocator = temp;
    get_all_metadata(i, *mds);
    print_metadata_attachments(mds, ", ");
    // printInfoComment: printGCRelocateComment
    if r.op == .CALL {
        cf := op(i, nops(i) - 1);
        if vkind(cf) == .FUNCTION && intrinsic_lookup(vname(cf)) == "llvm.experimental.gc.relocate" print_gc_relocate_comment(i);
    }
}

// GCRelocateInst::getBasePtr/getDerivedPtr (llvm/lib/IR/IntrinsicInst.cpp); NONE = "invalid"
gc_relocate_ptr :: (i: Value_Id, which: u32) -> Value_Id {
    tok := op(i, 0);
    k := vkind(tok);
    if k == .C_UNDEF || k == .C_POISON || k == .C_TOKEN_NONE return const_undef(vtype(tok));
    sp := tok;
    if k == .INST && inst_op(tok) == .LANDINGPAD {
        // the invoke that ends the landing pad's unique predecessor
        b := inst(tok).parent;
        pred: Value_Id = NONE;
        u := ir.v_first_use[b];
        while u != NONE {
            us := ir.u_user[u];
            if vkind(us) == .INST && is_terminator(inst_op(us)) {
                pb := inst(us).parent;
                if pred == NONE pred = pb; else if pred != pb return NONE;
            }
            u = ir.u_next[u];
        }
        if pred == NONE return NONE;
        sp = block(pred).last;
    }
    if vkind(sp) != .INST return NONE;
    ix := op(i, which);
    if vkind(ix) != .C_INT return NONE;
    idx := const_int_zext(ix);
    r := inst(sp);
    if r.nidx > 0 for bi: 0..r.nidx-1 {
        tag := ir.u32_pool[r.idx + bi * 3];
        if bundle_tags[tag] != "gc-live" continue;
        b0 := ir.u32_pool[r.idx + bi * 3 + 1];
        b1 := ir.u32_pool[r.idx + bi * 3 + 2];
        if idx > cast(u64)(b1 - b0) return NONE;
        return op(sp, b0 + cast(u32) idx);
    }
    if idx > cast(u64) call_arg_count(sp) return NONE;
    return op(sp, cast(u32) idx);
}

print_gc_relocate_comment :: (i: Value_Id) {
    out(" ; (");
    b := gc_relocate_ptr(i, 1);
    if b != NONE write_operand(b, false); else out("invalid");
    out(", ");
    d := gc_relocate_ptr(i, 2);
    if d != NONE write_operand(d, false); else out("invalid");
    out(")");
}

print_module :: () -> string {
    W.buf.count = 0;
    type_printing_init();
    process_module();
    if ir.module_id.count && !contains(ir.module_id, "\n") { out("; ModuleID = '"); out(ir.module_id); out("'\n"); }
    if ir.source_filename.count { out("source_filename = \""); print_escaped_string(ir.source_filename); out("\"\n"); }
    if ir.datalayout.count { out("target datalayout = \""); out(ir.datalayout); out("\"\n"); }
    if ir.triple.count { out("target triple = \""); out(ir.triple); out("\"\n"); }
    if ir.module_asm.count {
        outc(#char "\n");
        for ir.module_asm {
            out("module asm");
            outc(#char "\n");
            parts := split(it, "\n",, allocator = temp);
            for p: parts {
                if it_index == parts.count - 1 && p.count == 0 && parts.count > 1 break;
                out("    \""); print_escaped_string(p); out("\"\n");
            }
        }
    }
    if W.named_types.count || W.numbered_types.count {
        outc(#char "\n");
        for W.numbered_types { outc(#char "%"); out_s64(it_index); out(" = type "); print_struct_body(it); outc(#char "\n"); }
        for W.named_types { print_llvm_name(ir.types[it].name, #char "%"); out(" = type "); print_struct_body(it); outc(#char "\n"); }
    }
    // comdats used by global objects: functions first, then globals (Module::global_objects)
    used: [..] s32; used.allocator = temp;
    add_comdat :: (used: *[..] s32, c: s32) { if c < 0 return; for used.* if it == c return; array_add(used, c); }
    for ir.m_functions add_comdat(*used, glob(it).comdat);
    for ir.m_globals add_comdat(*used, glob(it).comdat);
    if used.count outc(#char "\n");
    for used {
        c := ir.comdats[it];
        print_llvm_name(c.name, #char "$");
        out(" = comdat ");
        KINDS :: string.["any", "exactmatch", "largest", "nodeduplicate", "samesize"];
        out(KINDS[c.kind]);
        outc(#char "\n");
        if it_index != used.count - 1 outc(#char "\n");
    }
    if ir.m_globals.count outc(#char "\n");
    for ir.m_globals { print_global(it); outc(#char "\n"); }
    if ir.m_aliases.count outc(#char "\n");
    for ir.m_aliases print_alias(it);
    if ir.m_ifuncs.count outc(#char "\n");
    for ir.m_ifuncs print_ifunc(it);
    for ir.m_functions { outc(#char "\n"); print_function(it); }
    if W.as_order.count {
        outc(#char "\n");
        for W.as_order {
            out("attributes #"); out_s64(it_index); out(" = { ");
            write_attribute_set(it, true);
            out(" }\n");
        }
    }
    if ir.named_md.count outc(#char "\n");
    for nm: ir.named_md {
        outc(#char "!");
        print_metadata_identifier(nm.name);
        out(" = !{");
        for nm.ops {
            if it_index > 0 out(", ");
            found, s := table_find(*W.md_slot, it);
            if found { outc(#char "!"); out_s64(s); } else out("<badref>");
        }
        out("}\n");
    }
    if W.md_order.count {
        outc(#char "\n");
        for W.md_order {
            outc(#char "!"); out_s64(it_index); out(" = ");
            if ir.mds[it].distinct out("distinct ");
            if ir.mds[it].kind == .SPECIAL write_di_node(it); else write_md_tuple(it);
            outc(#char "\n");
        }
    }
    r: string; r.data = W.buf.data; r.count = W.buf.count;
    return r;
}
