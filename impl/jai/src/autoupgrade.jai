// AutoUpgrade: what LLParser::validateEndOfModule does to old IR after parsing.
// Ported from llvm/lib/IR/AutoUpgrade.cpp (UpgradeIntrinsicFunction, upgradeIntrinsicFunction1,
// upgradeX86IntrinsicFunction (declaration part), UpgradeIntrinsicCall (generic cases), UpgradeCallsToIntrinsic)
// and the call-building parts of llvm/lib/IR/IRBuilder.cpp that those use.
// Target-specific upgrades for targets other than x86 are not ported: their intrinsic names are unknown here
// (gen_iit.jai has only Intrinsics.td and IntrinsicsX86.td). x86 call rewrites: autoupgrade_x86.jai.

// ---------------------------------------------------------------- small IR building helpers (IRBuilder)

Builder :: struct {
    before: Value_Id;     // insertion point: before this instruction
    fmf:    u32;          // fast-math flags (already shifted)
    dbg:    Md_Id = NONE; // current debug location
}

builder_at :: (ci: Value_Id) -> Builder {
    b: Builder;
    b.before = ci;
    if is_fp_math_type(vtype(ci)) b.fmf = inst(ci).flags & (FMF_ALL << FMF_SHIFT);
    b.dbg = get_metadata(ci, 0);
    return b;
}

// FPMathOperator::classof for calls: FP (vector of FP, or arrays/structs of those) result types
is_fp_math_type :: (t: Type_Id) -> bool {
    // FPMathOperator::isSupportedFloatingPointType: FP or FP vector, a literal struct of one repeated FP (vector)
    // type, or a (nested) array of FP (vector) elements
    ty := t;
    if type_kind(ty) == .STRUCT {
        if !(ir.types[ty].flags & TYF_LITERAL) || type_nsub(ty) == 0 return false;
        e := type_sub(ty, 0);
        for i: 1..cast(s64) type_nsub(ty) - 1 if type_sub(ty, cast(u32) i) != e return false;
        ty = e;
    } else {
        while type_kind(ty) == .ARRAY ty = type_elem(ty);
    }
    return is_fp_type(scalar_type(ty));
}

builder_insert :: (b: *Builder, i: Value_Id) {
    inst_insert_before(i, b.before);
    if b.dbg != NONE set_metadata(i, 0, b.dbg);
}

// IRBuilder::CreateCall(Callee, Args): no attributes, C calling convention, no bundles
builder_call :: (b: *Builder, callee: Value_Id, args: [] Value_Id) -> Value_Id {
    fty := glob(callee).value_type;
    i := new_inst(.CALL, func_ret(fty), cast(u32)(args.count + 1));
    r := inst(i);
    r.ty2 = fty;
    if is_fp_math_type(func_ret(fty)) r.flags = b.fmf;
    for args set_op(i, cast(u32) it_index, it);
    set_op(i, cast(u32) args.count, callee);
    builder_insert(b, i);
    return i;
}

// IRBuilder::CreateCast without constant folding of non-constants; constants fold like ConstantExpr::getCast
builder_cast :: (b: *Builder, op: Opcode, v: Value_Id, dt: Type_Id, name := "") -> Value_Id {
    if vtype(v) == dt return v;
    if is_constant_kind(vkind(v)) { f := fold_maybe_undesirable_cast(op, v, dt); if f != NONE return f; }
    i := new_inst(op, dt, 1);
    set_op(i, 0, v);
    builder_insert(b, i);
    if name.count set_name(i, name);
    return i;
}

call_nargs :: (ci: Value_Id) -> u32 { return func_nparams(inst(ci).ty2); }
call_arg :: (ci: Value_Id, i: u32) -> Value_Id { return op(ci, i); }
call_callee :: inline (ci: Value_Id) -> Value_Id { return op(ci, nops(ci) - 1); }

// Value::takeName
take_name :: (dst: Value_Id, src: Value_Id) {
    n := vname(src);
    if n.count == 0 return;
    set_name(src, "");
    set_name(dst, n);
}

// Instruction::copyMetadata (all attachments)
copy_metadata :: (dst: Value_Id, src: Value_Id) {
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(src, *all);
    for all set_metadata(dst, it.kind, it.md);
}

replace_and_erase :: (ci: Value_Id, rep: Value_Id) {
    if rep != NONE replace_all_uses_with(ci, rep);
    erase_inst(ci);
}

// GlobalValue rename: F->setName(F->getName() + ".old")
rename_old :: (f: Value_Id) { set_name(f, tprint("%.old", vname(f))); }

fn_ret_type :: (f: Value_Id) -> Type_Id { return func_ret(glob(f).value_type); }
fn_param_type :: (f: Value_Id, i: u32) -> Type_Id { return func_param(glob(f).value_type, i); }
fn_nargs :: (f: Value_Id) -> u32 { return func_nparams(glob(f).value_type); }

consume_front :: (s: *string, prefix: string) -> bool {
    if !begins_with(s.*, prefix) return false;
    s.* = slice(s.*, prefix.count, s.count - prefix.count);
    return true;
}

decl :: (name: string, otys: [] Type_Id = .[]) -> Value_Id {
    return get_or_insert_intrinsic_declaration(intrinsic_id_by_name(name), otys);
}

// ---------------------------------------------------------------- UpgradeIntrinsicFunction

found :: (n: Value_Id) -> Upgrade_Result { r: Upgrade_Result; r.upgraded = true; r.new_fn = n; return r; }

Upgrade_Result :: struct { upgraded: bool; new_fn: Value_Id = NONE; }

// The multiply-add intrinsics whose inputs changed from i32 vectors (21.1): 8 for the byte forms, 16 for the word
// forms, 0 otherwise (`name` without "x86.")
x86_multiply_add_input_elt_bits :: (name: string) -> u32 {
    for string.["avx512.vpdpbusd.", "avx512.vpdpbusds."] if begins_with(name, it) {
        s := slice(name, it.count, name.count - it.count);
        if s == "128" || s == "256" || s == "512" return 8;
    }
    for string.["avx512.vpdpwssd.", "avx512.vpdpwssds."] if begins_with(name, it) {
        s := slice(name, it.count, name.count - it.count);
        if s == "128" || s == "256" || s == "512" return 16;
    }
    for string.["ssd", "ssds", "sud", "suds", "uud", "uuds"] {
        if name == tprint("avx2.vpdpb%.128", it) || name == tprint("avx2.vpdpb%.256", it) || name == tprint("avx10.vpdpb%.512", it) return 8;
    }
    for string.["sud", "suds", "usd", "usds", "uud", "uuds"] {
        if name == tprint("avx2.vpdpw%.128", it) || name == tprint("avx2.vpdpw%.256", it) || name == tprint("avx10.vpdpw%.512", it) return 16;
    }
    return 0;
}

// upgradeX86IntrinsicFunction: autoupgrade_x86.jai

upgrade_intrinsic_function1 :: (f: Value_Id) -> Upgrade_Result {
    res: Upgrade_Result;
    name := vname(f);
    if !consume_front(*name, "llvm.") || name.count == 0 return res;
    ft := glob(f).value_type;
    nargs := fn_nargs(f);

    for 0..0 {   // `break` = LLVM's `break` out of the switch
        if name[0] == {
          case #char "c";
            if nargs == 1 {
                if begins_with(name, "convert.") {
                    rest := slice(name, 8, name.count - 8);
                    if convert_intrinsic_valid_type(rest, ft) { res.upgraded = true; return res; }
                }
                iid := "";
                if begins_with(name, "ctlz.") iid = "llvm.ctlz";
                else if begins_with(name, "cttz.") iid = "llvm.cttz";
                if iid.count {
                    rename_old(f);
                    return found(decl(iid, .[fn_param_type(f, 0)]));
                }
            }
            if nargs == 2 && name == "coro.end" {
                rename_old(f);
                return found(decl("llvm.coro.end"));
            }
          case #char "d";
            if consume_front(*name, "dbg.") {
                if name == "addr" || name == "value" || name == "assign" || name == "declare" || name == "label" {
                    // CanUpgradeDebugIntrinsicsToRecords: calls become debug records
                    res.upgraded = true; return res;
                }
            }
          case #char "e";
            if consume_front(*name, "experimental.vector.") {
                iid := "";
                if begins_with(name, "extract.last.active.") iid = "";
                else if begins_with(name, "extract.") iid = "llvm.vector.extract";
                else if begins_with(name, "insert.") iid = "llvm.vector.insert";
                else if begins_with(name, "reverse.") iid = "llvm.vector.reverse";
                else if begins_with(name, "interleave2.") iid = "llvm.vector.interleave2";
                else if begins_with(name, "deinterleave2.") iid = "llvm.vector.deinterleave2";
                else if begins_with(name, "partial.reduce.add") iid = "llvm.vector.partial.reduce.add";
                if iid.count {
                    tys: [..] Type_Id; tys.allocator = temp;
                    if iid == "llvm.vector.extract" || iid == "llvm.vector.interleave2" array_add(*tys, func_ret(ft));
                    if iid != "llvm.vector.interleave2" array_add(*tys, func_param(ft, 0));
                    if iid == "llvm.vector.insert" || iid == "llvm.vector.partial.reduce.add" array_add(*tys, func_param(ft, 1));
                    rename_old(f);
                    return found(decl(iid, tys));
                }
                if consume_front(*name, "reduce.") {
                    // ^([a-z]+)\.[a-z][0-9]+   and   ^v2\.([a-z]+)\.[fi][0-9]+
                    word, ok := match_reduce_name(name, false);
                    iid = "";
                    if ok {
                        for string.["add", "mul", "and", "or", "xor", "smax", "smin", "umax", "umin", "fmax", "fmin"]
                            if word == it iid = tprint("llvm.vector.reduce.%", it);
                    }
                    v2 := false;
                    if iid.count == 0 {
                        v2 = true;
                        if begins_with(name, "v2.") {
                            word, ok = match_reduce_name(slice(name, 3, name.count - 3), true);
                            if ok && (word == "fadd" || word == "fmul") iid = tprint("llvm.vector.reduce.%", word);
                        }
                    }
                    if iid.count {
                        rename_old(f);
                        return found(decl(iid, .[func_param(ft, ifx v2 then cast(u32) 1 else 0)]));
                    }
                    break;
                }
                if begins_with(name, "splice") { res.upgraded = true; return res; }
                break;
            }
            if begins_with(name, "experimental.stepvector.") {
                rename_old(f);
                return found(decl("llvm.stepvector", .[func_ret(ft)]));
            }
          case #char "f";
            if begins_with(name, "flt.rounds") { rename_old(f); return found(decl("llvm.get.rounding")); }
          case #char "i";
            if begins_with(name, "invariant.group.barrier") {
                p := func_param(ft, 0);
                rename_old(f);
                return found(decl("llvm.launder.invariant.group", .[p]));
            }
          case #char "l";
            is_start := consume_front(*name, "lifetime.start");
            is_end := !is_start && consume_front(*name, "lifetime.end");
            if is_start || is_end {
                if nargs == 2 {
                    rename_old(f);
                    return found(decl(ifx is_start then "llvm.lifetime.start" else "llvm.lifetime.end", .[func_param(ft, 1)]));
                } else if nargs == 1 && name == ".i64" {
                    res.upgraded = true; return res;
                }
            }
          case #char "m";
            iid := "";
            if begins_with(name, "memcpy.") iid = "llvm.memcpy";
            else if begins_with(name, "memmove.") iid = "llvm.memmove";
            if iid.count && nargs == 5 {
                rename_old(f);
                return found(decl(iid, .[func_param(ft, 0), func_param(ft, 1), func_param(ft, 2)]));
            }
            if begins_with(name, "memset.") && nargs == 5 {
                rename_old(f);
                return found(decl("llvm.memset", .[func_param(ft, 0), func_param(ft, 2)]));
            }
            masked := "";
            if begins_with(name, "masked.load") masked = "llvm.masked.load";
            else if begins_with(name, "masked.gather") masked = "llvm.masked.gather";
            else if begins_with(name, "masked.store") masked = "llvm.masked.store";
            else if begins_with(name, "masked.scatter") masked = "llvm.masked.scatter";
            if masked.count && nargs == 4 {
                rename_old(f);
                if masked == "llvm.masked.load" || masked == "llvm.masked.gather"
                    return found(decl(masked, .[func_ret(ft), func_param(ft, 0)]));
                return found(decl(masked, .[func_param(ft, 0), func_param(ft, 1)]));
            }
          case #char "o";
            if begins_with(name, "objectsize.") {
                if nargs == 2 || nargs == 3 {
                    tys := Type_Id.[func_ret(ft), func_param(ft, 0)];
                    rename_old(f);
                    return found(decl("llvm.objectsize", tys));
                }
            }
          case #char "p";
            if begins_with(name, "ptr.annotation.") && nargs == 4 {
                tys := Type_Id.[func_param(ft, 0), func_param(ft, 1)];
                rename_old(f);
                return found(decl("llvm.ptr.annotation", tys));
            }
          case #char "s";
            if name == "stackprotectorcheck" { res.upgraded = true; return res; }
          case #char "t";
            if name == "thread.pointer" return found(decl("llvm.thread.pointer", .[func_ret(ft)]));
          case #char "v";
            if name == "var.annotation" && nargs == 4 {
                tys := Type_Id.[func_param(ft, 0), func_param(ft, 1)];
                rename_old(f);
                return found(decl("llvm.var.annotation", tys));
            }
            if consume_front(*name, "vector.splice") {
                if !(begins_with(name, ".left") || begins_with(name, ".right")) { res.upgraded = true; return res; }
            }
          case #char "x";
            r := upgrade_x86_intrinsic_function(f, name);
            if r.upgraded return r;
          case #char "a"; #through;
          case #char "n"; #through;
          case #char "r"; #through;
          case #char "w";
            // arm/aarch64/amdgcn/nvvm/riscv/wasm upgrades: not ported (those intrinsics are unknown here)
        }
    }

    // Named or packed struct return types become literal non-packed structs.
    rt := func_ret(ft);
    id := function_intrinsic_id(f);
    if type_kind(rt) == .STRUCT && (!(ir.types[rt].flags & TYF_LITERAL) || (ir.types[rt].flags & TYF_PACKED)) && id != NOT_INTRINSIC {
        t := intrinsic_table(id);
        if t.descs.count && t.descs[0].kind == .Struct {
            elts: [..] Type_Id; elts.allocator = temp;
            for i: 0..cast(s64) type_nsub(rt) - 1 array_add(*elts, type_sub(rt, cast(u32) i));
            nst := type_literal_struct(elts, false);
            params: [..] Type_Id; params.allocator = temp;
            for i: 0..cast(s64) nargs - 1 array_add(*params, func_param(ft, cast(u32) i));
            nft := type_func(nst, params, func_vararg(ft));
            nm := copy_string(vname(f));
            rename_old(f);
            nf := new_function(nft, nm, glob(f).addrspace);
            glob(nf).linkage = glob(f).linkage;
            array_add(*ir.m_functions, nf);
            nid := function_intrinsic_id(nf);
            if nid != NOT_INTRINSIC set_intrinsic_attributes(nf, nid);
            rm := remangle_intrinsic_function(nf);
            if rm != NONE nf = rm;
            return found(nf);
        }
    }

    rm := remangle_intrinsic_function(f);
    if rm != NONE return found(rm);
    return res;
}

// "^([a-z]+)\.[a-z][0-9]+" (fi_only: "[fi]" instead of "[a-z]"); returns group 1
match_reduce_name :: (s: string, fi_only: bool) -> string, bool {
    i := 0;
    while i < s.count && s[i] >= #char "a" && s[i] <= #char "z" i += 1;
    if i == 0 || i + 3 > s.count return "", false;
    if s[i] != #char "." return "", false;
    c := s[i + 1];
    if fi_only { if c != #char "f" && c != #char "i" return "", false; }
    else if !(c >= #char "a" && c <= #char "z") return "", false;
    d := s[i + 2];
    if !(d >= #char "0" && d <= #char "9") return "", false;
    return slice(s, 0, i), true;
}

// convertIntrinsicValidType
convert_intrinsic_valid_type :: (name: string, ft: Type_Id) -> bool {
    half := type_simple(.HALF);
    if begins_with(name, "to.fp16") {
        // CastInst::castIsValid(FPTrunc, Param0, half) && castIsValid(BitCast, half, Ret)
        p := func_param(ft, 0); r := func_ret(ft);
        return is_fp_type(p) && dl_type_size_bits(p) > 16 && type_bits(r) == 16 && !is_vector_type(r) && type_kind(r) != .PTR;
    }
    if begins_with(name, "from.fp16") {
        p := func_param(ft, 0); r := func_ret(ft);
        return type_bits(p) == 16 && !is_vector_type(p) && type_kind(p) != .PTR && is_fp_type(r) && dl_type_size_bits(r) > 16;
    }
    return false;
}

// llvm::UpgradeIntrinsicFunction
upgrade_intrinsic_function :: (f_in: Value_Id) -> Upgrade_Result {
    r := upgrade_intrinsic_function1(f_in);
    f := f_in;
    if r.new_fn != NONE f = r.new_fn;
    // (an upgraded function without a replacement is erased: its attributes are never seen)
    if vkind(f) == .FUNCTION && !(r.upgraded && r.new_fn == NONE) {
        id := function_intrinsic_id(f);
        if id != NOT_INTRINSIC {
            otys: [..] Type_Id; otys.allocator = temp;
            if intrinsic_signature_valid(id, glob(f).value_type, *otys) set_intrinsic_attributes(f, id);
        }
    }
    return r;
}

// ---------------------------------------------------------------- UpgradeIntrinsicCall

align_attr_set :: (s: u32, align: u64) -> u32 {
    s2 := attr_set_remove(s, .Alignment);
    if align == 0 return s2;
    a: Attr; a.kind = .Alignment; a.ival = align; a.ty = NONE;
    return attr_set_merge(s2, attr_set_get(.[a]));
}

add_param_align :: (ci: Value_Id, argno: u32, align: u64) {
    r := inst(ci);
    np := func_nparams(r.ty2);
    ps: [..] u32; ps.allocator = temp;
    for i: 0..cast(s64) np - 1 array_add(*ps, attr_list_param(r.attrs, cast(u32) i));
    ps[argno] = align_attr_set(ps[argno], align);
    r.attrs = attr_list_get(attr_list_fn(r.attrs), attr_list_ret(r.attrs), ps);
}

const_false :: () -> Value_Id { return const_int(ir.t_i1, 0); }

strip_pointer_casts :: (v_in: Value_Id) -> Value_Id {
    v := v_in;
    // stripPointerCastsAndOffsets stops when it revisits a value (cycles in unreachable code)
    visited: [..] Value_Id; visited.allocator = temp;
    while true {
        for visited if it == v return v;
        array_add(*visited, v);
        k := vkind(v);
        if k == .INST {
            o := inst_op(v);
            if o == .BITCAST || o == .ADDRSPACECAST { v = op(v, 0); continue; }
            if o == .GEP && gep_all_zero(v) { v = op(v, 0); continue; }
        } else if k == .C_EXPR {
            o := cexpr(v).op;
            if o == .BITCAST || o == .ADDRSPACECAST { v = op(v, 0); continue; }
            if o == .GEP && gep_all_zero(v) { v = op(v, 0); continue; }
        }
        return v;
    }
    return v;
}
gep_all_zero :: (g: Value_Id) -> bool {
    n := nops(g);
    for i: 1..cast(s64) n - 1 if !is_null_value(op(g, cast(u32) i)) return false;
    return true;
}

// llvm::UpgradeIntrinsicCall
upgrade_intrinsic_call :: (ci: Value_Id, new_fn: Value_Id) {
    f := call_callee(ci);
    if vkind(f) != .FUNCTION return;
    b := builder_at(ci);
    if new_fn == NONE {
        name := vname(f);
        consume_front(*name, "llvm.");
        if consume_front(*name, "x86.") {
            rep := upgrade_x86_intrinsic_call(name, ci, *b);
            replace_and_erase(ci, rep);
            return;
        }
        if consume_front(*name, "dbg.") {
            upgrade_dbg_intrinsic_to_record(name, ci);
            erase_inst(ci);
            return;
        }
        is_old_splice := (consume_front(*name, "experimental.vector.splice") || consume_front(*name, "vector.splice")) &&
                         !(begins_with(name, ".left") || begins_with(name, ".right"));
        if name == "stackprotectorcheck" || name == "lifetime.start.i64" || name == "lifetime.end.i64" {
            erase_inst(ci);
            return;
        }
        if is_old_splice fatal("auto-upgrade of llvm.vector.splice is not supported yet");
        if consume_front(*name, "convert.") {
            // upgradeConvertIntrinsicCall
            rep: Value_Id = NONE;
            half := type_simple(.HALF);
            if begins_with(name, "to.fp16") {
                c := builder_cast(*b, .FPTRUNC, call_arg(ci, 0), half);
                rep = builder_cast(*b, .BITCAST, c, vtype(ci));
            } else if begins_with(name, "from.fp16") {
                c := builder_cast(*b, .BITCAST, call_arg(ci, 0), half);
                rep = builder_cast(*b, .FPEXT, c, vtype(ci));
            }
            replace_and_erase(ci, rep);
            return;
        }
        fatal("auto-upgrade of '%' is not supported", vname(f));
    }

    nid := function_intrinsic_id(new_fn);
    nname := ifx nid != NOT_INTRINSIC then intrinsic_name(nid) else "";
    na := call_nargs(ci);
    new_call: Value_Id = NONE;
    if nname == {
      case "llvm.bitreverse"; #through;
      case "llvm.ctpop";
        new_call = builder_call(*b, new_fn, .[call_arg(ci, 0)]);
      case "llvm.ctlz"; #through;
      case "llvm.cttz";
        if na != 1 { upgrade_default_case(ci, f, new_fn, *b); return; }
        new_call = builder_call(*b, new_fn, .[call_arg(ci, 0), const_false()]);
      case "llvm.objectsize";
        null_unknown := ifx na == 2 then const_false() else call_arg(ci, 2);
        dynamic := ifx na < 4 then const_false() else call_arg(ci, 3);
        new_call = builder_call(*b, new_fn, .[call_arg(ci, 0), call_arg(ci, 1), null_unknown, dynamic]);
      case "llvm.ptr.annotation"; #through;
      case "llvm.var.annotation";
        if na != 4 { upgrade_default_case(ci, f, new_fn, *b); return; }
        new_call = builder_call(*b, new_fn, .[call_arg(ci, 0), call_arg(ci, 1), call_arg(ci, 2), call_arg(ci, 3), const_null(type_ptr(0))]);
      case "llvm.coro.end";
        args: [..] Value_Id; args.allocator = temp;
        for i: 0..cast(s64) na - 1 array_add(*args, call_arg(ci, cast(u32) i));
        array_add(*args, const_simple(.C_TOKEN_NONE, ir.t_token));
        new_call = builder_call(*b, new_fn, args);
      case "llvm.thread.pointer";
        new_call = builder_call(*b, new_fn, .[]);
      case "llvm.memcpy"; #through;
      case "llvm.memmove"; #through;
      case "llvm.memset";
        if na != 5 { upgrade_default_case(ci, f, new_fn, *b); return; }
        new_call = builder_call(*b, new_fn, .[call_arg(ci, 0), call_arg(ci, 1), call_arg(ci, 2), call_arg(ci, 4)]);
        old := inst(ci).attrs;
        ps := u32.[attr_list_param(old, 0), attr_list_param(old, 1), attr_list_param(old, 2), attr_list_param(old, 4)];
        inst(new_call).attrs = attr_list_get(attr_list_fn(old), attr_list_ret(old), ps);
        a := call_arg(ci, 3);
        align := ifx vkind(a) == .C_INT then const_int_zext(a) else 0;
        add_param_align(new_call, 0, align);
        if nname != "llvm.memset" add_param_align(new_call, 1, align);
      case "llvm.masked.load"; #through;
      case "llvm.masked.gather"; #through;
      case "llvm.masked.store"; #through;
      case "llvm.masked.scatter";
        if na != 4 { upgrade_default_case(ci, f, new_fn, *b); return; }
        get_maybe_align :: (v: Value_Id) -> u64 {
            if vkind(v) == .C_INT {
                x := const_int_zext(v);
                if x == 0 || (x & (x - 1)) == 0 return x;
            }
            fatal("Invalid alignment argument");
            return 0;
        }
        get_align :: (v: Value_Id) -> u64 {
            a := get_maybe_align(v);
            if a == 0 fatal("Invalid zero alignment argument");
            return a;
        }
        if nname == {
          case "llvm.masked.load";
            al := get_align(call_arg(ci, 1));
            fn := decl("llvm.masked.load", .[vtype(ci), vtype(call_arg(ci, 0))]);
            new_call = builder_call(*b, fn, .[call_arg(ci, 0), call_arg(ci, 2), call_arg(ci, 3)]);
            add_param_align(new_call, 0, al);
          case "llvm.masked.gather";
            al := get_maybe_align(call_arg(ci, 1));
            if al == 0 al = dl_abi_align(scalar_type(vtype(ci)));
            fn := decl("llvm.masked.gather", .[vtype(ci), vtype(call_arg(ci, 0))]);
            new_call = builder_call(*b, fn, .[call_arg(ci, 0), call_arg(ci, 2), call_arg(ci, 3)]);
            add_param_align(new_call, 0, al);
          case "llvm.masked.store";
            al := get_align(call_arg(ci, 2));
            fn := decl("llvm.masked.store", .[vtype(call_arg(ci, 0)), vtype(call_arg(ci, 1))]);
            new_call = builder_call(*b, fn, .[call_arg(ci, 0), call_arg(ci, 1), call_arg(ci, 3)]);
            add_param_align(new_call, 1, al);
          case "llvm.masked.scatter";
            al := get_maybe_align(call_arg(ci, 2));
            if al == 0 al = dl_abi_align(scalar_type(vtype(call_arg(ci, 0))));
            fn := decl("llvm.masked.scatter", .[vtype(call_arg(ci, 0)), vtype(call_arg(ci, 1))]);
            new_call = builder_call(*b, fn, .[call_arg(ci, 0), call_arg(ci, 1), call_arg(ci, 3)]);
            add_param_align(new_call, 1, al);
        }
        copy_metadata(new_call, ci);
        inst(new_call).flags = (inst(new_call).flags & ~(cast(u32) 3 << TAIL_SHIFT)) | (inst(ci).flags & (cast(u32) 3 << TAIL_SHIFT));
      case "llvm.lifetime.start"; #through;
      case "llvm.lifetime.end";
        if na != 2 { upgrade_default_case(ci, f, new_fn, *b); return; }
        ptr := strip_pointer_casts(call_arg(ci, 1));
        if vkind(ptr) == .INST && inst_op(ptr) == .ALLOCA {
            fn := decl(nname, .[vtype(ptr)]);
            new_call = builder_call(*b, fn, .[ptr]);
        } else {
            erase_inst(ci);
            return;
        }
      case "llvm.dbg.value";
        fatal("upgrade of the old 4-operand llvm.dbg.value is not supported yet");
      case;
        if f != new_fn && upgrade_x86_call_to_new_fn(ci, f, new_fn, *b) return;
        if begins_with(nname, "llvm.x86.") && f != new_fn && x86_multiply_add_input_elt_bits(slice(nname, 9, nname.count - 9)) {
            // the vpdp* cases: bitcast the two inputs to the new element type
            elt := x86_multiply_add_input_elt_bits(slice(nname, 9, nname.count - 9));
            vb, _ := prim_size_bits(vtype(ci));
            n := cast(u32) vb / elt;
            nt := type_vector(n, type_int(elt), false);
            args := Value_Id.[call_arg(ci, 0), builder_cast(*b, .BITCAST, call_arg(ci, 1), nt), builder_cast(*b, .BITCAST, call_arg(ci, 2), nt)];
            new_call = builder_call(*b, new_fn, args);
            take_name(new_call, ci);
            replace_and_erase(ci, new_call);
            return;
        }
        if begins_with(nname, "llvm.x86.") && f != new_fn && inst(ci).ty2 != glob(new_fn).value_type
            fatal("auto-upgrade of x86 intrinsic call '%' is not supported yet", vname(f));
        upgrade_default_case(ci, f, new_fn, *b);
        return;
    }
    take_name(new_call, ci);
    replace_and_erase(ci, new_call);
}

upgrade_default_case :: (ci: Value_Id, f: Value_Id, new_fn: Value_Id, b: *Builder) {
    if f == new_fn return;
    if inst(ci).ty2 == glob(new_fn).value_type {
        set_op(ci, nops(ci) - 1, new_fn);   // CI->setCalledFunction(NewFn)
        return;
    }
    if type_kind(vtype(ci)) == .STRUCT {
        ost := vtype(ci);
        args: [..] Value_Id; args.allocator = temp;
        for i: 0..cast(s64) call_nargs(ci) - 1 array_add(*args, call_arg(ci, cast(u32) i));
        nci := builder_call(b, new_fn, args);
        inst(nci).attrs = inst(ci).attrs;
        res := const_poison(ost);
        for idx: 0..cast(s64) type_nsub(ost) - 1 {
            ev := builder_extractvalue(b, nci, cast(u32) idx);
            res = builder_insertvalue(b, res, ev, cast(u32) idx);
        }
        replace_and_erase(ci, res);
        return;
    }
    // we're probably about to produce something invalid; let the verifier complain
    set_op(ci, nops(ci) - 1, new_fn);
}

builder_extractvalue :: (b: *Builder, agg: Value_Id, idx: u32) -> Value_Id {
    if is_constant_kind(vkind(agg)) { f := cf_extract_value(agg, .[idx]); if f != NONE return f; }
    t := vtype(agg);
    rt := type_sub(t, ifx type_kind(t) == .STRUCT then idx else 0);
    i := new_inst(.EXTRACTVALUE, rt, 1);
    set_op(i, 0, agg);
    r := inst(i);
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = 1;
    array_add(*ir.u32_pool, idx);
    builder_insert(b, i);
    return i;
}
builder_insertvalue :: (b: *Builder, agg: Value_Id, v: Value_Id, idx: u32) -> Value_Id {
    if is_constant_kind(vkind(agg)) && is_constant_kind(vkind(v)) { f := cf_insert_value(agg, v, .[idx]); if f != NONE return f; }
    i := new_inst(.INSERTVALUE, vtype(agg), 2);
    set_op(i, 0, agg); set_op(i, 1, v);
    r := inst(i);
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = 1;
    array_add(*ir.u32_pool, idx);
    builder_insert(b, i);
    return i;
}

// llvm::UpgradeCallsToIntrinsic
upgrade_calls_to_intrinsic :: (f: Value_Id) {
    r := upgrade_intrinsic_function(f);
    if !r.upgraded return;
    // make_early_inc_range(F->users())
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[f];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for users {
        if vkind(it) == .INST && (inst_op(it) == .CALL || inst_op(it) == .INVOKE || inst_op(it) == .CALLBR)
            upgrade_intrinsic_call(it, r.new_fn);
    }
    if f != r.new_fn {
        if has_uses(f) fatal("internal: upgraded intrinsic '%' still has uses", vname(f));
        erase_global(f);
    }
}
// shouldUpgradeX86Intrinsic (mechanical translation of AutoUpgrade.cpp)
should_upgrade_x86_intrinsic :: (f: Value_Id, name_in: string) -> bool {
  name := name_in;
  // All of the intrinsics matches below should be marked with which llvm
  // version started autoupgrading them. At some point in the future we would
  // like to use this information to remove upgrade code for some older
  // intrinsics. It is currently undecided how we will determine that future
  // point.
  if (consume_front(*name, "avx."))
    return (begins_with(name, "blend.p") ||        // Added in 3.7
            name == "cvt.ps2.pd.256" ||           // Added in 3.9
            name == "cvtdq2.pd.256" ||            // Added in 3.9
            name == "cvtdq2.ps.256" ||            // Added in 7.0
            begins_with(name, "movnt.") ||         // Added in 3.2
            begins_with(name, "sqrt.p") ||         // Added in 7.0
            begins_with(name, "storeu.") ||        // Added in 3.9
            begins_with(name, "vbroadcast.s") ||   // Added in 3.5
            begins_with(name, "vbroadcastf128") || // Added in 4.0
            begins_with(name, "vextractf128.") ||  // Added in 3.7
            begins_with(name, "vinsertf128.") ||   // Added in 3.7
            begins_with(name, "vperm2f128.") ||    // Added in 6.0
            begins_with(name, "vpermil."));        // Added in 3.1

  if (consume_front(*name, "avx2."))
    return (name == "movntdqa" ||             // Added in 5.0
            begins_with(name, "pabs.") ||      // Added in 6.0
            begins_with(name, "padds.") ||     // Added in 8.0
            begins_with(name, "paddus.") ||    // Added in 8.0
            begins_with(name, "pblendd.") ||   // Added in 3.7
            name == "pblendw" ||              // Added in 3.7
            begins_with(name, "pbroadcast") || // Added in 3.8
            begins_with(name, "pcmpeq.") ||    // Added in 3.1
            begins_with(name, "pcmpgt.") ||    // Added in 3.1
            begins_with(name, "pmax") ||       // Added in 3.9
            begins_with(name, "pmin") ||       // Added in 3.9
            begins_with(name, "pmovsx") ||     // Added in 3.9
            begins_with(name, "pmovzx") ||     // Added in 3.9
            name == "pmul.dq" ||              // Added in 7.0
            name == "pmulu.dq" ||             // Added in 7.0
            begins_with(name, "psll.dq") ||    // Added in 3.7
            begins_with(name, "psrl.dq") ||    // Added in 3.7
            begins_with(name, "psubs.") ||     // Added in 8.0
            begins_with(name, "psubus.") ||    // Added in 8.0
            begins_with(name, "vbroadcast") || // Added in 3.8
            name == "vbroadcasti128" ||       // Added in 3.7
            name == "vextracti128" ||         // Added in 3.7
            name == "vinserti128" ||          // Added in 3.7
            name == "vperm2i128");            // Added in 6.0

  if (consume_front(*name, "avx512.")) {
    if (consume_front(*name, "mask."))
      // 'avx512.mask.*'
      return (begins_with(name, "add.p") ||       // Added in 7.0. 128/256 in 4.0
              begins_with(name, "and.") ||        // Added in 3.9
              begins_with(name, "andn.") ||       // Added in 3.9
              begins_with(name, "broadcast.s") || // Added in 3.9
              begins_with(name, "broadcastf32x4.") || // Added in 6.0
              begins_with(name, "broadcastf32x8.") || // Added in 6.0
              begins_with(name, "broadcastf64x2.") || // Added in 6.0
              begins_with(name, "broadcastf64x4.") || // Added in 6.0
              begins_with(name, "broadcasti32x4.") || // Added in 6.0
              begins_with(name, "broadcasti32x8.") || // Added in 6.0
              begins_with(name, "broadcasti64x2.") || // Added in 6.0
              begins_with(name, "broadcasti64x4.") || // Added in 6.0
              begins_with(name, "cmp.b") ||           // Added in 5.0
              begins_with(name, "cmp.d") ||           // Added in 5.0
              begins_with(name, "cmp.q") ||           // Added in 5.0
              begins_with(name, "cmp.w") ||           // Added in 5.0
              begins_with(name, "compress.b") ||      // Added in 9.0
              begins_with(name, "compress.d") ||      // Added in 9.0
              begins_with(name, "compress.p") ||      // Added in 9.0
              begins_with(name, "compress.q") ||      // Added in 9.0
              begins_with(name, "compress.store.") || // Added in 7.0
              begins_with(name, "compress.w") ||      // Added in 9.0
              begins_with(name, "conflict.") ||       // Added in 9.0
              begins_with(name, "cvtdq2pd.") ||       // Added in 4.0
              begins_with(name, "cvtdq2ps.") ||       // Added in 7.0 updated 9.0
              name == "cvtpd2dq.256" ||              // Added in 7.0
              name == "cvtpd2ps.256" ||              // Added in 7.0
              name == "cvtps2pd.128" ||              // Added in 7.0
              name == "cvtps2pd.256" ||              // Added in 7.0
              begins_with(name, "cvtqq2pd.") ||       // Added in 7.0 updated 9.0
              name == "cvtqq2ps.256" ||              // Added in 9.0
              name == "cvtqq2ps.512" ||              // Added in 9.0
              name == "cvttpd2dq.256" ||             // Added in 7.0
              name == "cvttps2dq.128" ||             // Added in 7.0
              name == "cvttps2dq.256" ||             // Added in 7.0
              begins_with(name, "cvtudq2pd.") ||      // Added in 4.0
              begins_with(name, "cvtudq2ps.") ||      // Added in 7.0 updated 9.0
              begins_with(name, "cvtuqq2pd.") ||      // Added in 7.0 updated 9.0
              name == "cvtuqq2ps.256" ||             // Added in 9.0
              name == "cvtuqq2ps.512" ||             // Added in 9.0
              begins_with(name, "dbpsadbw.") ||       // Added in 7.0
              begins_with(name, "div.p") ||    // Added in 7.0. 128/256 in 4.0
              begins_with(name, "expand.b") || // Added in 9.0
              begins_with(name, "expand.d") || // Added in 9.0
              begins_with(name, "expand.load.") || // Added in 7.0
              begins_with(name, "expand.p") ||     // Added in 9.0
              begins_with(name, "expand.q") ||     // Added in 9.0
              begins_with(name, "expand.w") ||     // Added in 9.0
              begins_with(name, "fpclass.p") ||    // Added in 7.0
              begins_with(name, "insert") ||       // Added in 4.0
              begins_with(name, "load.") ||        // Added in 3.9
              begins_with(name, "loadu.") ||       // Added in 3.9
              begins_with(name, "lzcnt.") ||       // Added in 5.0
              begins_with(name, "max.p") ||       // Added in 7.0. 128/256 in 5.0
              begins_with(name, "min.p") ||       // Added in 7.0. 128/256 in 5.0
              begins_with(name, "movddup") ||     // Added in 3.9
              begins_with(name, "move.s") ||      // Added in 4.0
              begins_with(name, "movshdup") ||    // Added in 3.9
              begins_with(name, "movsldup") ||    // Added in 3.9
              begins_with(name, "mul.p") ||       // Added in 7.0. 128/256 in 4.0
              begins_with(name, "or.") ||         // Added in 3.9
              begins_with(name, "pabs.") ||       // Added in 6.0
              begins_with(name, "packssdw.") ||   // Added in 5.0
              begins_with(name, "packsswb.") ||   // Added in 5.0
              begins_with(name, "packusdw.") ||   // Added in 5.0
              begins_with(name, "packuswb.") ||   // Added in 5.0
              begins_with(name, "padd.") ||       // Added in 4.0
              begins_with(name, "padds.") ||      // Added in 8.0
              begins_with(name, "paddus.") ||     // Added in 8.0
              begins_with(name, "palignr.") ||    // Added in 3.9
              begins_with(name, "pand.") ||       // Added in 3.9
              begins_with(name, "pandn.") ||      // Added in 3.9
              begins_with(name, "pavg") ||        // Added in 6.0
              begins_with(name, "pbroadcast") ||  // Added in 6.0
              begins_with(name, "pcmpeq.") ||     // Added in 3.9
              begins_with(name, "pcmpgt.") ||     // Added in 3.9
              begins_with(name, "perm.df.") ||    // Added in 3.9
              begins_with(name, "perm.di.") ||    // Added in 3.9
              begins_with(name, "permvar.") ||    // Added in 7.0
              begins_with(name, "pmaddubs.w.") || // Added in 7.0
              begins_with(name, "pmaddw.d.") ||   // Added in 7.0
              begins_with(name, "pmax") ||        // Added in 4.0
              begins_with(name, "pmin") ||        // Added in 4.0
              name == "pmov.qd.256" ||           // Added in 9.0
              name == "pmov.qd.512" ||           // Added in 9.0
              name == "pmov.wb.256" ||           // Added in 9.0
              name == "pmov.wb.512" ||           // Added in 9.0
              begins_with(name, "pmovsx") ||      // Added in 4.0
              begins_with(name, "pmovzx") ||      // Added in 4.0
              begins_with(name, "pmul.dq.") ||    // Added in 4.0
              begins_with(name, "pmul.hr.sw.") || // Added in 7.0
              begins_with(name, "pmulh.w.") ||    // Added in 7.0
              begins_with(name, "pmulhu.w.") ||   // Added in 7.0
              begins_with(name, "pmull.") ||      // Added in 4.0
              begins_with(name, "pmultishift.qb.") || // Added in 8.0
              begins_with(name, "pmulu.dq.") ||       // Added in 4.0
              begins_with(name, "por.") ||            // Added in 3.9
              begins_with(name, "prol.") ||           // Added in 8.0
              begins_with(name, "prolv.") ||          // Added in 8.0
              begins_with(name, "pror.") ||           // Added in 8.0
              begins_with(name, "prorv.") ||          // Added in 8.0
              begins_with(name, "pshuf.b.") ||        // Added in 4.0
              begins_with(name, "pshuf.d.") ||        // Added in 3.9
              begins_with(name, "pshufh.w.") ||       // Added in 3.9
              begins_with(name, "pshufl.w.") ||       // Added in 3.9
              begins_with(name, "psll.d") ||          // Added in 4.0
              begins_with(name, "psll.q") ||          // Added in 4.0
              begins_with(name, "psll.w") ||          // Added in 4.0
              begins_with(name, "pslli") ||           // Added in 4.0
              begins_with(name, "psllv") ||           // Added in 4.0
              begins_with(name, "psra.d") ||          // Added in 4.0
              begins_with(name, "psra.q") ||          // Added in 4.0
              begins_with(name, "psra.w") ||          // Added in 4.0
              begins_with(name, "psrai") ||           // Added in 4.0
              begins_with(name, "psrav") ||           // Added in 4.0
              begins_with(name, "psrl.d") ||          // Added in 4.0
              begins_with(name, "psrl.q") ||          // Added in 4.0
              begins_with(name, "psrl.w") ||          // Added in 4.0
              begins_with(name, "psrli") ||           // Added in 4.0
              begins_with(name, "psrlv") ||           // Added in 4.0
              begins_with(name, "psub.") ||           // Added in 4.0
              begins_with(name, "psubs.") ||          // Added in 8.0
              begins_with(name, "psubus.") ||         // Added in 8.0
              begins_with(name, "pternlog.") ||       // Added in 7.0
              begins_with(name, "punpckh") ||         // Added in 3.9
              begins_with(name, "punpckl") ||         // Added in 3.9
              begins_with(name, "pxor.") ||           // Added in 3.9
              begins_with(name, "shuf.f") ||          // Added in 6.0
              begins_with(name, "shuf.i") ||          // Added in 6.0
              begins_with(name, "shuf.p") ||          // Added in 4.0
              begins_with(name, "sqrt.p") ||          // Added in 7.0
              begins_with(name, "store.b.") ||        // Added in 3.9
              begins_with(name, "store.d.") ||        // Added in 3.9
              begins_with(name, "store.p") ||         // Added in 3.9
              begins_with(name, "store.q.") ||        // Added in 3.9
              begins_with(name, "store.w.") ||        // Added in 3.9
              name == "store.ss" ||                  // Added in 7.0
              begins_with(name, "storeu.") ||         // Added in 3.9
              begins_with(name, "sub.p") ||       // Added in 7.0. 128/256 in 4.0
              begins_with(name, "ucmp.") ||       // Added in 5.0
              begins_with(name, "unpckh.") ||     // Added in 3.9
              begins_with(name, "unpckl.") ||     // Added in 3.9
              begins_with(name, "valign.") ||     // Added in 4.0
              name == "vcvtph2ps.128" ||         // Added in 11.0
              name == "vcvtph2ps.256" ||         // Added in 11.0
              begins_with(name, "vextract") ||    // Added in 4.0
              begins_with(name, "vfmadd.") ||     // Added in 7.0
              begins_with(name, "vfmaddsub.") ||  // Added in 7.0
              begins_with(name, "vfnmadd.") ||    // Added in 7.0
              begins_with(name, "vfnmsub.") ||    // Added in 7.0
              begins_with(name, "vpdpbusd.") ||   // Added in 7.0
              begins_with(name, "vpdpbusds.") ||  // Added in 7.0
              begins_with(name, "vpdpwssd.") ||   // Added in 7.0
              begins_with(name, "vpdpwssds.") ||  // Added in 7.0
              begins_with(name, "vpermi2var.") || // Added in 7.0
              begins_with(name, "vpermil.p") ||   // Added in 3.9
              begins_with(name, "vpermilvar.") || // Added in 4.0
              begins_with(name, "vpermt2var.") || // Added in 7.0
              begins_with(name, "vpmadd52") ||    // Added in 7.0
              begins_with(name, "vpshld.") ||     // Added in 7.0
              begins_with(name, "vpshldv.") ||    // Added in 8.0
              begins_with(name, "vpshrd.") ||     // Added in 7.0
              begins_with(name, "vpshrdv.") ||    // Added in 8.0
              begins_with(name, "vpshufbitqmb.") || // Added in 8.0
              begins_with(name, "xor."));           // Added in 3.9

    if (consume_front(*name, "mask3."))
      // 'avx512.mask3.*'
      return (begins_with(name, "vfmadd.") ||    // Added in 7.0
              begins_with(name, "vfmaddsub.") || // Added in 7.0
              begins_with(name, "vfmsub.") ||    // Added in 7.0
              begins_with(name, "vfmsubadd.") || // Added in 7.0
              begins_with(name, "vfnmsub."));    // Added in 7.0

    if (consume_front(*name, "maskz."))
      // 'avx512.maskz.*'
      return (begins_with(name, "pternlog.") ||   // Added in 7.0
              begins_with(name, "vfmadd.") ||     // Added in 7.0
              begins_with(name, "vfmaddsub.") ||  // Added in 7.0
              begins_with(name, "vpdpbusd.") ||   // Added in 7.0
              begins_with(name, "vpdpbusds.") ||  // Added in 7.0
              begins_with(name, "vpdpwssd.") ||   // Added in 7.0
              begins_with(name, "vpdpwssds.") ||  // Added in 7.0
              begins_with(name, "vpermt2var.") || // Added in 7.0
              begins_with(name, "vpmadd52") ||    // Added in 7.0
              begins_with(name, "vpshldv.") ||    // Added in 8.0
              begins_with(name, "vpshrdv."));     // Added in 8.0

    // 'avx512.*'
    return (name == "movntdqa" ||               // Added in 5.0
            name == "pmul.dq.512" ||            // Added in 7.0
            name == "pmulu.dq.512" ||           // Added in 7.0
            begins_with(name, "broadcastm") ||   // Added in 6.0
            begins_with(name, "cmp.p") ||        // Added in 12.0
            begins_with(name, "cvtb2mask.") ||   // Added in 7.0
            begins_with(name, "cvtd2mask.") ||   // Added in 7.0
            begins_with(name, "cvtmask2") ||     // Added in 5.0
            begins_with(name, "cvtq2mask.") ||   // Added in 7.0
            name == "cvtusi2sd" ||              // Added in 7.0
            begins_with(name, "cvtw2mask.") ||   // Added in 7.0
            name == "kand.w" ||                 // Added in 7.0
            name == "kandn.w" ||                // Added in 7.0
            name == "knot.w" ||                 // Added in 7.0
            name == "kor.w" ||                  // Added in 7.0
            name == "kortestc.w" ||             // Added in 7.0
            name == "kortestz.w" ||             // Added in 7.0
            begins_with(name, "kunpck") ||       // added in 6.0
            name == "kxnor.w" ||                // Added in 7.0
            name == "kxor.w" ||                 // Added in 7.0
            begins_with(name, "padds.") ||       // Added in 8.0
            begins_with(name, "pbroadcast") ||   // Added in 3.9
            begins_with(name, "prol") ||         // Added in 8.0
            begins_with(name, "pror") ||         // Added in 8.0
            begins_with(name, "psll.dq") ||      // Added in 3.9
            begins_with(name, "psrl.dq") ||      // Added in 3.9
            begins_with(name, "psubs.") ||       // Added in 8.0
            begins_with(name, "ptestm") ||       // Added in 6.0
            begins_with(name, "ptestnm") ||      // Added in 6.0
            begins_with(name, "storent.") ||     // Added in 3.9
            begins_with(name, "vbroadcast.s") || // Added in 7.0
            begins_with(name, "vpshld.") ||      // Added in 8.0
            begins_with(name, "vpshrd."));       // Added in 8.0
  }

  if (consume_front(*name, "fma."))
    return (begins_with(name, "vfmadd.") ||    // Added in 7.0
            begins_with(name, "vfmsub.") ||    // Added in 7.0
            begins_with(name, "vfmsubadd.") || // Added in 7.0
            begins_with(name, "vfnmadd.") ||   // Added in 7.0
            begins_with(name, "vfnmsub."));    // Added in 7.0

  if (consume_front(*name, "fma4."))
    return begins_with(name, "vfmadd.s"); // Added in 7.0

  if (consume_front(*name, "sse."))
    return (name == "add.ss" ||            // Added in 4.0
            name == "cvtsi2ss" ||          // Added in 7.0
            name == "cvtsi642ss" ||        // Added in 7.0
            name == "div.ss" ||            // Added in 4.0
            name == "mul.ss" ||            // Added in 4.0
            begins_with(name, "sqrt.p") ||  // Added in 7.0
            name == "sqrt.ss" ||           // Added in 7.0
            begins_with(name, "storeu.") || // Added in 3.9
            name == "sub.ss");             // Added in 4.0

  if (consume_front(*name, "sse2."))
    return (name == "add.sd" ||            // Added in 4.0
            name == "cvtdq2pd" ||          // Added in 3.9
            name == "cvtdq2ps" ||          // Added in 7.0
            name == "cvtps2pd" ||          // Added in 3.9
            name == "cvtsi2sd" ||          // Added in 7.0
            name == "cvtsi642sd" ||        // Added in 7.0
            name == "cvtss2sd" ||          // Added in 7.0
            name == "div.sd" ||            // Added in 4.0
            name == "mul.sd" ||            // Added in 4.0
            begins_with(name, "padds.") ||  // Added in 8.0
            begins_with(name, "paddus.") || // Added in 8.0
            begins_with(name, "pcmpeq.") || // Added in 3.1
            begins_with(name, "pcmpgt.") || // Added in 3.1
            name == "pmaxs.w" ||           // Added in 3.9
            name == "pmaxu.b" ||           // Added in 3.9
            name == "pmins.w" ||           // Added in 3.9
            name == "pminu.b" ||           // Added in 3.9
            name == "pmulu.dq" ||          // Added in 7.0
            begins_with(name, "pshuf") ||   // Added in 3.9
            begins_with(name, "psll.dq") || // Added in 3.7
            begins_with(name, "psrl.dq") || // Added in 3.7
            begins_with(name, "psubs.") ||  // Added in 8.0
            begins_with(name, "psubus.") || // Added in 8.0
            begins_with(name, "sqrt.p") ||  // Added in 7.0
            name == "sqrt.sd" ||           // Added in 7.0
            name == "storel.dq" ||         // Added in 3.9
            begins_with(name, "storeu.") || // Added in 3.9
            name == "sub.sd");             // Added in 4.0

  if (consume_front(*name, "sse41."))
    return (begins_with(name, "blendp") || // Added in 3.7
            name == "movntdqa" ||         // Added in 5.0
            name == "pblendw" ||          // Added in 3.7
            name == "pmaxsb" ||           // Added in 3.9
            name == "pmaxsd" ||           // Added in 3.9
            name == "pmaxud" ||           // Added in 3.9
            name == "pmaxuw" ||           // Added in 3.9
            name == "pminsb" ||           // Added in 3.9
            name == "pminsd" ||           // Added in 3.9
            name == "pminud" ||           // Added in 3.9
            name == "pminuw" ||           // Added in 3.9
            begins_with(name, "pmovsx") || // Added in 3.8
            begins_with(name, "pmovzx") || // Added in 3.9
            name == "pmuldq");            // Added in 7.0

  if (consume_front(*name, "sse42."))
    return name == "crc32.64.8"; // Added in 3.4

  if (consume_front(*name, "sse4a."))
    return begins_with(name, "movnt."); // Added in 3.9

  if (consume_front(*name, "ssse3."))
    return (name == "pabs.b.128" || // Added in 6.0
            name == "pabs.d.128" || // Added in 6.0
            name == "pabs.w.128");  // Added in 6.0

  if (consume_front(*name, "xop."))
    return (name == "vpcmov" ||          // Added in 3.8
            name == "vpcmov.256" ||      // Added in 5.0
            begins_with(name, "vpcom") || // Added in 3.2, Updated in 9.0
            begins_with(name, "vprot"));  // Added in 8.0

  if (consume_front(*name, "bmi."))
    return (begins_with(name, "pdep.") || // Added in 23.0
            begins_with(name, "pext."));  // Added in 23.0

  return (name == "addcarry.u32" ||        // Added in 8.0
          name == "addcarry.u64" ||        // Added in 8.0
          name == "addcarryx.u32" ||       // Added in 8.0
          name == "addcarryx.u64" ||       // Added in 8.0
          name == "subborrow.u32" ||       // Added in 8.0
          name == "subborrow.u64" ||       // Added in 8.0
          begins_with(name, "vcvtph2ps.")); // Added in 11.0
}

// ---------------------------------------------------------------- metadata upgrades

md_const_int_value :: (m: Md_Id) -> (ok: bool, v: u64) {
    if m == NONE || ir.mds[m].kind != .VALUE return false, 0;
    v := ir.mds[m].value;
    if vkind(v) != .C_INT return false, 0;
    return true, const_int_zext(v);
}

// llvm::UpgradeTBAANode
upgrade_tbaa_node :: (m: Md_Id) -> Md_Id {
    r := ir.mds[m];
    if r.kind != .TUPLE return m;
    n := r.nops;
    if n == 0 return m;
    o0 := md_op(m, 0);
    if o0 != NONE && (ir.mds[o0].kind == .TUPLE || ir.mds[o0].kind == .DI) && n >= 3 return m;
    zero := md_value(const_int(ir.t_i64, 0));
    if n == 3 {
        scalar := md_tuple(.[md_op(m, 0), md_op(m, 1)], false);
        return md_tuple(.[scalar, scalar, zero, md_op(m, 2)], false);
    }
    return md_tuple(.[m, m, zero], false);
}

upgrade_tbaa_tags :: () {
    tbaa := md_fixed("tbaa");
    for f: ir.m_functions {
        b := glob(f).first_block;
        while b != NONE {
            i := block(b).first;
            while i != NONE {
                m := get_metadata(i, tbaa);
                if m != NONE {
                    nm := upgrade_tbaa_node(m);
                    if nm != m set_metadata(i, tbaa, nm);
                }
                i = inst(i).next;
            }
            b = block(b).next;
        }
    }
}

MOD_ERROR :: 1; MOD_OVERRIDE :: 4; MOD_MAX :: 7; MOD_MIN :: 8;

// llvm::UpgradeModuleFlags (upgradePtrauthInitFiniArrays is not ported: arm64e only)
upgrade_module_flags :: () {
    nm: *Named_Md = null;
    for * ir.named_md if it.name == "llvm.module.flags" { nm = it; break; }
    if !nm return;
    has_objc := false; has_class_props := false;
    has_swift := false; swift_abi: u64; swift_major: u64; swift_minor: u64;
    for i: 0..nm.ops.count-1 {
        op := nm.ops[i];
        if op == NONE || ir.mds[op].kind != .TUPLE || ir.mds[op].nops != 3 continue;
        idm := md_op(op, 1);
        if idm == NONE || ir.mds[idm].kind != .STRING continue;
        id := ir.mds[idm].str;
        set_behavior :: (nm: *Named_Md, i: s64, b: u64, idm: Md_Id, val: Md_Id) {
            nm.ops[i] = md_tuple(.[md_value(const_int(ir.t_i32, b)), idm, val], false);
        }
        if id == "Objective-C Image Info Version" has_objc = true;
        if id == "Objective-C Class Properties" has_class_props = true;
        if id == "PIC Level" {
            ok, v := md_const_int_value(md_op(op, 0));
            if ok && (v == MOD_ERROR || v == MOD_MAX) set_behavior(nm, i, MOD_MIN, idm, md_op(op, 2));
        }
        if id == "PIE Level" {
            ok, v := md_const_int_value(md_op(op, 0));
            if ok && v == MOD_ERROR set_behavior(nm, i, MOD_MAX, idm, md_op(op, 2));
        }
        if id == "branch-target-enforcement" || begins_with(id, "sign-return-address") {
            ok, v := md_const_int_value(md_op(op, 0));
            if ok && v == MOD_ERROR set_behavior(nm, i, MOD_MIN, idm, md_op(op, 2));
        }
        if id == "Objective-C Image Info Section" {
            vm := md_op(op, 2);
            if vm != NONE && ir.mds[vm].kind == .STRING && contains(ir.mds[vm].str, " ") {
                nv := replace(ir.mds[vm].str, " ", "",, allocator = temp);
                nm.ops[i] = md_tuple(.[md_op(op, 0), idm, md_string(nv)], false);
            }
        }
        if id == "Objective-C Garbage Collection" {
            vm := md_op(op, 2);
            if vm != NONE && ir.mds[vm].kind == .VALUE {
                v := ir.mds[vm].value;
                if vtype(v) == ir.t_i8 continue;
                val := const_int_zext(v) & 0xFFFF_FFFF;
                if (val & 0xff) != val {
                    has_swift = true;
                    swift_abi = (val & 0xff00) >> 8;
                    swift_major = (val & 0xff000000) >> 24;
                    swift_minor = (val & 0xff0000) >> 16;
                }
                nm.ops[i] = md_tuple(.[md_value(const_int(ir.t_i32, MOD_ERROR)), idm, md_value(const_int(ir.t_i8, val & 0xff))], false);
            }
        }
        if id == "amdgpu_code_object_version"
            nm.ops[i] = md_tuple(.[md_op(op, 0), md_string("amdhsa_code_object_version"), md_op(op, 2)], false);
    }
    if has_objc && !has_class_props {
        array_add(*nm.ops, md_tuple(.[md_value(const_int(ir.t_i32, MOD_OVERRIDE)), md_string("Objective-C Class Properties"),
                                     md_value(const_int(ir.t_i32, 0))], false));
    }
    if has_swift {
        array_add(*nm.ops, md_tuple(.[md_value(const_int(ir.t_i32, MOD_ERROR)), md_string("Swift ABI Version"), md_value(const_int(ir.t_i32, swift_abi))], false));
        array_add(*nm.ops, md_tuple(.[md_value(const_int(ir.t_i32, MOD_ERROR)), md_string("Swift Major Version"), md_value(const_int(ir.t_i8, swift_major))], false));
        array_add(*nm.ops, md_tuple(.[md_value(const_int(ir.t_i32, MOD_ERROR)), md_string("Swift Minor Version"), md_value(const_int(ir.t_i8, swift_minor))], false));
    }
}

// ---------------------------------------------------------------- IRBuilder with ConstantFolder (for x86 upgrades)

builder_set_fmf :: (b: *Builder, i: Value_Id) {
    if is_fp_math_type(vtype(i)) inst(i).flags = (inst(i).flags & ~(cast(u32) FMF_ALL << FMF_SHIFT)) | b.fmf;
}

builder_binop :: (b: *Builder, opc: Opcode, l: Value_Id, r: Value_Id, name := "") -> Value_Id {
    if is_constant_kind(vkind(l)) && is_constant_kind(vkind(r)) {
        f: Value_Id;
        if is_desirable_bin_op(opc) f = ce_binop(opc, l, r, 0); else f = cf_binary(opc, l, r);
        if f != NONE return f;
    }
    i := new_inst(opc, vtype(l), 2);
    set_op(i, 0, l); set_op(i, 1, r);
    builder_insert(b, i);
    if opc == .FADD || opc == .FSUB || opc == .FMUL || opc == .FDIV || opc == .FREM builder_set_fmf(b, i);
    if name.count set_name(i, name);
    return i;
}

builder_extract_element :: (b: *Builder, v: Value_Id, idx: Value_Id) -> Value_Id {
    if is_constant_kind(vkind(v)) && is_constant_kind(vkind(idx)) {
        f := cf_extract_element(v, idx);
        if f != NONE return f;
    }
    i := new_inst(.EXTRACTELEMENT, type_elem(vtype(v)), 2);
    set_op(i, 0, v); set_op(i, 1, idx);
    builder_insert(b, i);
    return i;
}

builder_insert_element :: (b: *Builder, v: Value_Id, e: Value_Id, idx: Value_Id) -> Value_Id {
    if is_constant_kind(vkind(v)) && is_constant_kind(vkind(e)) && is_constant_kind(vkind(idx)) {
        f := cf_insert_element(v, e, idx);
        if f != NONE return f;
    }
    i := new_inst(.INSERTELEMENT, vtype(v), 3);
    set_op(i, 0, v); set_op(i, 1, e); set_op(i, 2, idx);
    builder_insert(b, i);
    return i;
}

builder_shuffle :: (b: *Builder, v1: Value_Id, v2: Value_Id, mask: [] u32) -> Value_Id {
    if is_constant_kind(vkind(v1)) && is_constant_kind(vkind(v2)) {
        f := cf_shuffle_vector(v1, v2, mask);
        if f != NONE return f;
    }
    vt := vtype(v1);
    rt := type_vector(cast(u64) mask.count, type_elem(vt), type_kind(vt) == .SVECTOR);
    i := new_inst(.SHUFFLEVECTOR, rt, 2);
    set_op(i, 0, v1); set_op(i, 1, v2);
    r := inst(i);
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) mask.count;
    for mask array_add(*ir.u32_pool, it);
    builder_insert(b, i);
    return i;
}

builder_icmp :: (b: *Builder, pred: u8, l: Value_Id, r: Value_Id) -> Value_Id {
    if is_constant_kind(vkind(l)) && is_constant_kind(vkind(r)) {
        f := cf_compare(pred, l, r);
        if f != NONE return f;
    }
    t := vtype(l);
    rt := ifx is_vector_type(t) then vector_with_elt(t, ir.t_i1) else ir.t_i1;
    i := new_inst(.ICMP, rt, 2);
    inst(i).pred = pred;
    set_op(i, 0, l); set_op(i, 1, r);
    builder_insert(b, i);
    return i;
}

// IRBuilder::CreateIntrinsic(ID, OverloadTys, Args)
builder_intrinsic :: (b: *Builder, name: string, otys: [] Type_Id, args: [] Value_Id) -> Value_Id {
    return builder_call(b, decl(name, otys), args);
}

// upgradeX86IntrinsicCall: autoupgrade_x86.jai
