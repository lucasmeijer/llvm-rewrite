// Intrinsic IDs, signatures, name mangling and declarations.
// Ported from llvm/lib/IR/Intrinsics.cpp (lookupIntrinsicID, lookupLLVMIntrinsicByName, findTargetSubtable,
// getIntrinsicInfoTableEntries, DecodeFixedType, matchIntrinsicType, isSignatureValid, getMangledTypeStr,
// getIntrinsicNameImpl, getOrInsertDeclaration, remangleIntrinsicFunction) and the part of
// llvm/lib/IR/AutoUpgrade.cpp (UpgradeIntrinsicFunction) that sets Intrinsic::getAttributes on declarations.
// Tables: gen_iit.jai (signatures, from Intrinsics.td by gen/gen_iit.py) and gen_intrinsics.jai (attributes, from
// oracle runs by gen/gen_intrinsics.py).

// An intrinsic ID is 1 + an index into INTRINSIC_INFOS; 0 is Intrinsic::not_intrinsic.
Intrinsic_Id :: s32;
NOT_INTRINSIC :: 0;

intrinsic_name :: (id: Intrinsic_Id) -> string { return INTRINSIC_INFOS[id - 1].name; }
intrinsic_is_overloaded :: (id: Intrinsic_Id) -> bool { return INTRINSIC_INFOS[id - 1].overloaded; }

intrinsic_id_by_name :: (name: string) -> Intrinsic_Id {
    for INTRINSIC_INFOS if it.name == name return cast(Intrinsic_Id)(it_index + 1);
    fatal("internal: no intrinsic named '%'", name);
    return 0;
}

// strncmp(a + s, b + s, n) where bytes past a string's end read as NUL
cmp_component :: (a: string, b: string, s: s64, e: s64) -> int {
    for i: s..e-1 {
        ca: u8 = ifx i < a.count then a[i] else 0;
        cb: u8 = ifx i < b.count then b[i] else 0;
        if ca != cb return cast(int) ca - cast(int) cb;
        if ca == 0 return 0;
    }
    return 0;
}

// Intrinsic::lookupIntrinsicID
intrinsic_lookup_id :: (name: string) -> Intrinsic_Id {
    if !begins_with(name, "llvm.") return NOT_INTRINSIC;
    // findTargetSubtable: the first dotted component after "llvm." names the target, if it is one
    lo := 0; hi := INTRINSIC_X86_START;
    target := "";
    {
        rest := slice(name, 5, name.count - 5);
        dot := find_index_from_left(rest, #char ".");
        t := ifx dot >= 0 then slice(rest, 0, dot) else rest;
        if t == "x86" { target = "x86"; lo = INTRINSIC_X86_START; hi = INTRINSIC_INFOS.count; }
    }
    // lookupLLVMIntrinsicByName: successive equal_range searches on dotted components
    cmp_end := 4;
    if target.count cmp_end += 1 + target.count;
    last_low := lo;
    while cmp_end < name.count && hi - lo > 0 {
        cmp_start := cmp_end;
        cmp_end = cmp_start + 1;
        while cmp_end < name.count && name[cmp_end] != #char "." cmp_end += 1;
        last_low = lo;
        // lower bound: first x with !(x < name)
        a := lo; b := hi;
        while a < b { m := (a + b) / 2; if cmp_component(INTRINSIC_INFOS[m].name, name, cmp_start, cmp_end) < 0 a = m + 1; else b = m; }
        new_lo := a;
        b = hi;
        while a < b { m := (a + b) / 2; if cmp_component(name, INTRINSIC_INFOS[m].name, cmp_start, cmp_end) < 0 b = m; else a = m + 1; }
        lo = new_lo; hi = a;
    }
    if hi - lo > 0 last_low = lo;
    if last_low >= INTRINSIC_INFOS.count return NOT_INTRINSIC;
    found := INTRINSIC_INFOS[last_low].name;
    if !(name == found || (begins_with(name, found) && name.count > found.count && name[found.count] == #char "."))
        return NOT_INTRINSIC;
    id := cast(Intrinsic_Id)(last_low + 1);
    if name.count == found.count || INTRINSIC_INFOS[last_low].overloaded return id;
    return NOT_INTRINSIC;
}

// The base name of the intrinsic `name` refers to, or "" (kept for callers that want a string).
intrinsic_lookup :: (name: string) -> string {
    id := intrinsic_lookup_id(name);
    if id == NOT_INTRINSIC return "";
    return intrinsic_name(id);
}

// Function::getIntrinsicID (recomputed from the name; LLVM caches it on setName)
function_intrinsic_id :: (f: Value_Id) -> Intrinsic_Id {
    if vkind(f) != .FUNCTION return NOT_INTRINSIC;
    if !begins_with(vname(f), "llvm.") return NOT_INTRINSIC;
    return intrinsic_lookup_id(vname(f));
}

// ---------------------------------------------------------------- descriptors

IIT_Table :: struct {
    descs: [] IIT_Desc;
    num_args: u32;
    vararg: bool;
}

iit_skip :: (d: [] IIT_Desc, i: s64) -> s64 {
    k := d[i].kind;
    if k == .Vector || k == .SameVecWidth return iit_skip(d, i + 1);
    if k == .Struct {
        j := i + 1;
        for 1..d[i].a j = iit_skip(d, j);
        return j;
    }
    return i + 1;
}

// Intrinsic::getIntrinsicInfoTableEntries
intrinsic_table :: (id: Intrinsic_Id) -> IIT_Table {
    info := INTRINSIC_INFOS[id - 1];
    t: IIT_Table;
    t.descs.data = IIT_DESCS.data + info.first;
    t.descs.count = info.count;
    i := iit_skip(t.descs, 0);
    n: u32 = 0;
    while i < t.descs.count { i = iit_skip(t.descs, i); n += 1; }
    if t.descs.count && t.descs[t.descs.count - 1].kind == .VarArg {
        t.vararg = true;
        t.descs.count -= 1;
        n -= 1;
    }
    t.num_args = n;
    return t;
}

iit_overload_index :: inline (d: IIT_Desc) -> u32 {
    if d.kind == .Overloaded return d.a & 0xFF;
    return d.a;   // Match/Extend/... : a; VecOfAnyPtrsToElt: a = own index, b = ref index
}

// Type::getExtendedType / getTruncatedType
type_extended :: (t: Type_Id) -> Type_Id {
    if is_vector_type(t) return type_vector(type_count(t), type_int(type_int_width(type_elem(t)) * 2), type_kind(t) == .SVECTOR);
    return type_int(type_int_width(t) * 2);
}
type_truncated :: (t: Type_Id) -> Type_Id {
    if is_vector_type(t) return type_vector(type_count(t), type_int(type_int_width(type_elem(t)) / 2), type_kind(t) == .SVECTOR);
    return type_int(type_int_width(t) / 2);
}
is_int_or_int_vector :: (t: Type_Id) -> bool { return is_int_type(scalar_type(t)); }

// VectorType::getSubdividedVectorType
type_subdivided_vector :: (t: Type_Id, n: s32) -> Type_Id {
    r := t;
    for 1..n {
        e := type_elem(r);
        r = type_vector(type_count(r) * 2, type_int(type_bits(e) / 2), type_kind(r) == .SVECTOR);
    }
    return r;
}
// VectorType::getInteger
type_vector_integer :: (t: Type_Id) -> Type_Id {
    return type_vector(type_count(t), type_int(type_bits(type_elem(t))), type_kind(t) == .SVECTOR);
}

target_ext_by_name :: (name: string) -> Type_Id {
    return intern_target_ext(name, .[], .[]);
}

// DecodeFixedType
decode_fixed_type :: (d: [] IIT_Desc, pos: *s64, otys: [] Type_Id) -> Type_Id {
    x := d[pos.*]; pos.* += 1;
    if x.kind == {
        case .Void;     return ir.t_void;
        case .MMX;      return type_vector(1, ir.t_i64, false);
        case .AMX;      return type_simple(.X86_AMX);
        case .Token;    return ir.t_token;
        case .Metadata; return ir.t_metadata;
        case .Half;     return type_simple(.HALF);
        case .BFloat;   return type_simple(.BFLOAT);
        case .Float;    return type_simple(.FLOAT);
        case .Double;   return type_simple(.DOUBLE);
        case .Quad;     return type_simple(.FP128);
        case .PPCQuad;  return type_simple(.PPC_FP128);
        case .AArch64Svcount; return target_ext_by_name("aarch64.svcount");
        case .WasmExternref;  return target_ext_by_name("wasm.externref");
        case .WasmFuncref;    return target_ext_by_name("wasm.funcref");
        case .Integer;  return type_int(x.a);
        case .Vector;
            e := decode_fixed_type(d, pos, otys);
            return type_vector(x.a, e, x.b != 0);
        case .Pointer;  return type_ptr(x.a);
        case .Struct;
            elts: [..] Type_Id; elts.allocator = temp;
            for 1..x.a array_add(*elts, decode_fixed_type(d, pos, otys));
            return type_literal_struct(elts, false);
        case .Overloaded; #through;
        case .VecOfAnyPtrsToElt; #through;
        case .Match;    return otys[iit_overload_index(x)];
        case .Extend;   return type_extended(otys[x.a]);
        case .Trunc;    return type_truncated(otys[x.a]);
        case .Subdivide2; return type_subdivided_vector(otys[x.a], 1);
        case .Subdivide4; return type_subdivided_vector(otys[x.a], 2);
        case .OneNthEltsVec;
            v := otys[x.a];
            return type_vector(type_count(v) / x.b, type_elem(v), type_kind(v) == .SVECTOR);
        case .SameVecWidth;
            e := decode_fixed_type(d, pos, otys);
            o := otys[x.a];
            if is_vector_type(o) return type_vector(type_count(o), e, type_kind(o) == .SVECTOR);
            return e;
        case .VecElement; return type_elem(otys[x.a]);
        case .VecOfBitcastsToInt; return type_vector_integer(otys[x.a]);
        case .VarArg; fatal("internal: IITDescriptor::VarArg not expected");
    }
    return NONE;
}

// Intrinsic::getType
intrinsic_type :: (id: Intrinsic_Id, otys: [] Type_Id) -> Type_Id {
    t := intrinsic_table(id);
    pos := 0;
    ret := decode_fixed_type(t.descs, *pos, otys);
    args: [..] Type_Id; args.allocator = temp;
    while pos < t.descs.count array_add(*args, decode_fixed_type(t.descs, *pos, otys));
    return type_func(ret, args, t.vararg);
}

// ---------------------------------------------------------------- signature matching

Deferred_Check :: struct { ty: Type_Id; pos: s64; }

same_element_count :: (a: Type_Id, b: Type_Id) -> bool {
    return type_count(a) == type_count(b) && type_kind(a) == type_kind(b);
}

// matchIntrinsicType: returns true on mismatch (like LLVM). Error text is not reproduced.
match_intrinsic_type :: (ty: Type_Id, d: [] IIT_Desc, pos: *s64, otys: *[..] Type_Id, deferred: *[..] Deferred_Check, is_deferred: bool) -> bool {
    if pos.* >= d.count return true;
    here := pos.*;
    defer_check :: (deferred: *[..] Deferred_Check, ty: Type_Id, here: s64) -> bool {
        array_add(deferred, .{ty, here});
        return false;
    }
    x := d[pos.*]; pos.* += 1;
    k := type_kind(ty);
    if x.kind == {
        case .Void;     return k != .VOID;
        case .MMX;      return !(k == .VECTOR && type_count(ty) == 1 && type_elem(ty) == ir.t_i64);
        case .AMX;      return k != .X86_AMX;
        case .Token;    return k != .TOKEN;
        case .Metadata; return k != .METADATA;
        case .Half;     return k != .HALF;
        case .BFloat;   return k != .BFLOAT;
        case .Float;    return k != .FLOAT;
        case .Double;   return k != .DOUBLE;
        case .Quad;     return k != .FP128;
        case .PPCQuad;  return k != .PPC_FP128;
        case .Integer;  return !(k == .INT && type_int_width(ty) == x.a);
        case .AArch64Svcount; return !(k == .TARGET_EXT && ir.types[ty].name == "aarch64.svcount");
        case .WasmExternref;  return !(k == .TARGET_EXT && ir.types[ty].name == "wasm.externref");
        case .WasmFuncref;    return !(k == .TARGET_EXT && ir.types[ty].name == "wasm.funcref");
        case .Vector;
            if !is_vector_type(ty) || type_count(ty) != x.a || (k == .SVECTOR) != (x.b != 0) return true;
            return match_intrinsic_type(type_elem(ty), d, pos, otys, deferred, is_deferred);
        case .Pointer;  return !(k == .PTR && ir.types[ty].a == x.a);
        case .Struct;
            if !(k == .STRUCT && (ir.types[ty].flags & TYF_LITERAL) && !(ir.types[ty].flags & TYF_PACKED) && type_nsub(ty) == x.a) return true;
            if type_nsub(ty) > 0 for i: 0..type_nsub(ty)-1
                if match_intrinsic_type(type_sub(ty, i), d, pos, otys, deferred, is_deferred) return true;
            return false;
        case .Overloaded;
            array_add(otys, ty);
            vc := (x.a >> 12) & 0xF;
            ec := (x.a >> 8) & 0xF;
            ok := true;
            if vc == 1 ok = is_vector_type(ty);
            else if vc == 2 ok = !is_vector_type(ty);
            et := scalar_type(ty);
            if ec == 1 ok = ok && is_int_type(et);
            else if ec == 2 ok = ok && is_fp_type(et);
            else if ec == 3 ok = ok && is_ptr_type(et);
            return !ok;
        case .Match;
            if x.a >= otys.count return is_deferred || defer_check(deferred, ty, here);
            return ty != otys.*[x.a];
        case .Extend; #through;
        case .Trunc;
            if x.a >= otys.count return is_deferred || defer_check(deferred, ty, here);
            o := otys.*[x.a];
            if !is_int_or_int_vector(o) return true;
            nt := ifx x.kind == .Extend then type_extended(o) else type_truncated(o);
            return ty != nt;
        case .OneNthEltsVec;
            if x.a >= otys.count return is_deferred || defer_check(deferred, ty, here);
            o := otys.*[x.a];
            if !is_vector_type(o) return true;
            if type_count(o) % x.b != 0 return true;
            return ty != type_vector(type_count(o) / x.b, type_elem(o), type_kind(o) == .SVECTOR);
        case .SameVecWidth;
            if x.a >= otys.count {
                pos.* = iit_skip(d, pos.*);
                return is_deferred || defer_check(deferred, ty, here);
            }
            o := otys.*[x.a];
            ov := is_vector_type(o); tv := is_vector_type(ty);
            if ov && !tv return true;
            if !ov && tv return true;
            et := ty;
            if tv {
                if !same_element_count(o, ty) return true;
                et = type_elem(ty);
            }
            return match_intrinsic_type(et, d, pos, otys, deferred, is_deferred);
        case .VecOfAnyPtrsToElt;
            ref := x.b;
            if ref >= otys.count {
                if is_deferred return true;
                array_add(otys, ty);
                return defer_check(deferred, ty, here);
            }
            if !is_deferred array_add(otys, ty);
            r := otys.*[ref];
            if !is_vector_type(r) return true;
            if !is_vector_type(ty) return true;
            return !(same_element_count(ty, r) && is_ptr_type(type_elem(ty)));
        case .VecElement;
            if x.a >= otys.count return is_deferred || defer_check(deferred, ty, here);
            o := otys.*[x.a];
            if !is_vector_type(o) return true;
            return type_elem(o) != ty;
        case .Subdivide2; #through;
        case .Subdivide4;
            if x.a >= otys.count return is_deferred || defer_check(deferred, ty, here);
            o := otys.*[x.a];
            if !is_vector_type(o) return true;
            return ty != type_subdivided_vector(o, ifx x.kind == .Subdivide2 then cast(s32) 1 else 2);
        case .VecOfBitcastsToInt;
            if x.a >= otys.count return is_deferred || defer_check(deferred, ty, here);
            o := otys.*[x.a];
            if !is_vector_type(o) return true;
            return ty != type_vector_integer(o);
        case .VarArg; fatal("internal: IITDescriptor::VarArg not expected");
    }
    return true;
}

// Intrinsic::isSignatureValid: fills `otys` with the overload types.
intrinsic_signature_valid :: (id: Intrinsic_Id, ft: Type_Id, otys: *[..] Type_Id) -> bool {
    if id == NOT_INTRINSIC return false;
    t := intrinsic_table(id);
    return signature_valid_table(ft, t, otys);
}

signature_valid_table :: (ft: Type_Id, t: IIT_Table, otys: *[..] Type_Id) -> bool {
    deferred: [..] Deferred_Check; deferred.allocator = temp;
    pos := 0;
    if match_intrinsic_type(func_ret(ft), t.descs, *pos, otys, *deferred, false) return false;
    if func_nparams(ft) != t.num_args return false;
    np := func_nparams(ft);
    if np > 0 for i: 0..np-1
        if match_intrinsic_type(func_param(ft, i), t.descs, *pos, otys, *deferred, false) return false;
    i := 0;
    while i < deferred.count {
        dc := deferred[i];
        p := dc.pos;
        if match_intrinsic_type(dc.ty, t.descs, *p, otys, *deferred, true) return false;
        i += 1;
    }
    if pos < t.descs.count return false;
    if func_vararg(ft) != t.vararg return false;
    return true;
}

// ---------------------------------------------------------------- names

// getMangledTypeStr
mangled_type_str :: (sb: *String_Builder, t: Type_Id, has_unnamed: *bool) {
    r := ir.types[t];
    if r.kind == {
        case .PTR; append(sb, "p"); append_u64(sb, r.a);
        case .ARRAY; append(sb, "a"); append_u64(sb, r.a); mangled_type_str(sb, type_elem(t), has_unnamed);
        case .STRUCT;
            if !(r.flags & TYF_LITERAL) {
                append(sb, "s_");
                if r.name.count append(sb, r.name); else has_unnamed.* = true;
            } else {
                append(sb, "sl_");
                if r.nsub > 0 for i: 0..r.nsub-1 mangled_type_str(sb, type_sub(t, i), has_unnamed);
            }
            append(sb, "s");
        case .FUNC;
            append(sb, "f_");
            mangled_type_str(sb, func_ret(t), has_unnamed);
            np := func_nparams(t);
            if np > 0 for i: 0..np-1 mangled_type_str(sb, func_param(t, i), has_unnamed);
            if func_vararg(t) append(sb, "vararg");
            append(sb, "f");
        case .VECTOR; #through;
        case .SVECTOR;
            if r.kind == .SVECTOR append(sb, "nx");
            append(sb, "v"); append_u64(sb, r.a);
            mangled_type_str(sb, type_elem(t), has_unnamed);
        case .TARGET_EXT;
            append(sb, "t"); append(sb, r.name);
            if r.nsub > 0 for i: 0..r.nsub-1 { append(sb, "_"); mangled_type_str(sb, type_sub(t, i), has_unnamed); }
            if r.nints > 0 for i: 0..r.nints-1 { append(sb, "_"); append_u64(sb, ir.type_list[r.ints + i]); }
            append(sb, "t");
        case .VOID; append(sb, "isVoid");
        case .METADATA; append(sb, "Metadata");
        case .HALF; append(sb, "f16");
        case .BFLOAT; append(sb, "bf16");
        case .FLOAT; append(sb, "f32");
        case .DOUBLE; append(sb, "f64");
        case .X86_FP80; append(sb, "f80");
        case .FP128; append(sb, "f128");
        case .PPC_FP128; append(sb, "ppcf128");
        case .X86_AMX; append(sb, "x86amx");
        case .INT; append(sb, "i"); append_u64(sb, r.a);
        case .BYTE; append(sb, "b"); append_u64(sb, r.a);
        case; fatal("internal: unhandled type in intrinsic name mangling");
    }
}

// Intrinsic::getName(ID, OverloadTys, M, FT)
intrinsic_mangled_name :: (id: Intrinsic_Id, otys: [] Type_Id) -> string {
    if otys.count == 0 return intrinsic_name(id);
    sb: String_Builder; sb.allocator = temp;
    append(*sb, intrinsic_name(id));
    has_unnamed := false;
    for otys { append(*sb, "."); mangled_type_str(*sb, it, *has_unnamed); }
    if has_unnamed fatal("intrinsic overloaded on an unnamed struct type is not supported yet (Module::getUniqueIntrinsicName)");
    return builder_to_string(*sb,, allocator = temp);
}

// Module::getOrInsertFunction(Name, FT) for a declaration without attributes; new functions go to the end of the
// function list. A new intrinsic function gets Intrinsic::getAttributes in its constructor.
get_or_insert_function :: (name: string, ft: Type_Id) -> Value_Id {
    f := lookup_global(name);
    if f != NONE return f;
    f = new_function(ft, name, 0);
    array_add(*ir.m_functions, f);
    id := function_intrinsic_id(f);
    if id != NOT_INTRINSIC set_intrinsic_attributes(f, id);
    return f;
}

// getOrInsertIntrinsicDeclarationImpl
get_or_insert_intrinsic_declaration_ft :: (id: Intrinsic_Id, otys: [] Type_Id, ft: Type_Id) -> Value_Id {
    name := intrinsic_mangled_name(id, otys);
    f := get_or_insert_function(name, ft);
    if vkind(f) == .FUNCTION && glob(f).value_type == ft return f;
    // a declaration with the wrong signature exists: rename it and insert a new one
    set_name(f, tprint("%.invalid", vname(f)));
    return get_or_insert_function(name, ft);
}

// Intrinsic::getOrInsertDeclaration(M, ID, OverloadTys)
get_or_insert_intrinsic_declaration :: (id: Intrinsic_Id, otys: [] Type_Id = .[]) -> Value_Id {
    ft := intrinsic_type(id, otys);
    return get_or_insert_intrinsic_declaration_ft(id, otys, ft);
}

// Intrinsic::remangleIntrinsicFunction: NONE if nothing to do.
remangle_intrinsic_function :: (f: Value_Id) -> Value_Id {
    otys: [..] Type_Id; otys.allocator = temp;
    id := function_intrinsic_id(f);
    ft := glob(f).value_type;
    if !intrinsic_signature_valid(id, ft, *otys) return NONE;
    wanted := intrinsic_mangled_name(id, otys);
    if vname(f) == wanted return NONE;
    existing := lookup_global(wanted);
    nd: Value_Id = NONE;
    if existing != NONE {
        if vkind(existing) == .FUNCTION && glob(existing).value_type == ft nd = existing;
        else set_name(existing, tprint("%.renamed", wanted));
    }
    if nd == NONE nd = get_or_insert_intrinsic_declaration(id, otys);
    glob(nd).cc = glob(f).cc;
    return nd;
}

// ---------------------------------------------------------------- attributes

parse_attr_text :: (text: string, is_fn: bool) -> u32 {
    if text.count == 0 return 0;
    saved_lx := P.lx; saved_tok := P.tok;
    P.lx = .{};
    P.lx.src = ifx is_fn then tprint("% }", text) else text;
    P.lx.file = "<intrinsic attribute table>";
    next();
    attrs: [..] Attr; attrs.allocator = temp;
    if is_fn {
        groups: [..] u32; groups.allocator = temp;
        parse_fn_attribute_value_pairs(*attrs, *groups, true);
    } else {
        parse_optional_param_or_return_attrs(*attrs, true);
    }
    if P.tok.kind != .RBRACE && P.tok.kind != .EOF fatal("bad intrinsic attribute text '%'", text);
    P.lx = saved_lx; P.tok = saved_tok;
    return attr_set_get(attrs);
}

// F->setAttributes(Intrinsic::getAttributes(C, id, FT))
set_intrinsic_attributes :: (f: Value_Id, id: Intrinsic_Id) {
    base := intrinsic_name(id);
    for INTRINSIC_ATTRS {
        if it.name != base continue;
        fnset := parse_attr_text(it.fn, true);
        rtext := it.ret;
        if contains(rtext, "@") {
            rt := scalar_type(func_ret(glob(f).value_type));
            rtext = replace(rtext, "@", tprint("%", type_bits(rt)),, allocator = temp);
        }
        retset := parse_attr_text(rtext, false);
        ps: [..] u32; ps.allocator = temp;
        np := func_nparams(glob(f).value_type);
        if np > 0 for i: 0..np-1 array_add(*ps, ifx i < it.params.count then parse_attr_text(it.params[i], false) else 0);
        glob(f).attrs = attr_list_get(fnset, retset, ps);
        return;
    }
    // llvm.dbg.* declarations are always upgraded away (calls become debug records), so the oracle never shows them
    if begins_with(base, "llvm.dbg.") return;
    fatal("intrinsic '%' has no entry in the generated attribute table (impl/jai/gen/gen_intrinsics.py: add a test that declares it)", base);
}

is_unknown_intrinsic :: (f: Value_Id) -> bool {
    return begins_with(vname(f), "llvm.") && function_intrinsic_id(f) == NOT_INTRINSIC;
}

intrinsic_has_pretty_args :: (f: Value_Id) -> bool {
    id := function_intrinsic_id(f);
    return id != NOT_INTRINSIC && intrinsic_name(id) == "llvm.is.fpclass";
}

// Intrinsic::printImmArg for llvm.is.fpclass (ImmArgPrinter<"printFPClassMask"> on argument 1)
print_imm_arg_comment :: (f: Value_Id, argno: u32, v: Value_Id) {
    if argno != 1 || vkind(v) != .C_INT return;
    out("/* ");
    write_fpclass(const_int_zext(v));
    out(" */ ");
}
