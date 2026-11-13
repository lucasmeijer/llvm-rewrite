// The Verifier's intrinsic checks (part of the port of llvm/lib/IR/Verifier.cpp, see verifier.jai): visitIntrinsicCall,
// visitVPIntrinsic, visitConstrainedFPIntrinsic, verifyStatepoint, verifyFrameRecoverIndices,
// verifyDeoptimizeCallingConvs, verifyNoAliasScopeDecl; the signature check with LLVM's messages
// (llvm/lib/IR/Intrinsics.cpp isSignatureValid / matchIntrinsicType with MatchPosition) and the convergence-control
// verifier (llvm/include/llvm/IR/GenericConvergenceVerifierImpl.h, llvm/lib/IR/ConvergenceVerifier.cpp).

// ---------------------------------------------------------------- isSignatureValid with messages

Match_Pos :: struct {
    is_ret: bool;
    num: u32;
    nidx: u8;
    idx_struct: [2] bool;
    idx_num: [2] u32;
}
Deferred_Msg_Check :: struct { ty: Type_Id; pos: s64; mp: Match_Pos; }

mp_write :: (sb: *String_Builder, p: Match_Pos) {
    append(sb, "intrinsic ");
    if p.is_ret append(sb, "return"); else print_to_builder(sb, "argument %", p.num);
    for k: 0..cast(s64) p.nidx - 1 {
        if p.idx_struct[k] print_to_builder(sb, " struct element %", p.idx_num[k]);
        else append(sb, " vector element");
    }
}

// Intrinsic::isSignatureValid(ID, FT, OverloadTys, OS)
intrinsic_signature_valid_msg :: (id: Intrinsic_Id, ft: Type_Id, otys: *[..] Type_Id, sb: *String_Builder) -> bool {
    if id == NOT_INTRINSIC return false;
    t := intrinsic_table(id);
    deferred: [..] Deferred_Msg_Check; deferred.allocator = temp;
    pos := 0;
    mp: Match_Pos; mp.is_ret = true;
    if vf_match_intrinsic_type(func_ret(ft), t.descs, *pos, mp, otys, *deferred, false, sb) return false;
    np := func_nparams(ft);
    if np != t.num_args { print_to_builder(sb, "intrinsic has incorrect number of args. Expected %, but got %", t.num_args, np); return false; }
    mp.is_ret = false;
    for k: 0..cast(s64) np - 1 {
        mp.num = cast(u32) k;
        if vf_match_intrinsic_type(func_param(ft, cast(u32) k), t.descs, *pos, mp, otys, *deferred, false, sb) return false;
    }
    i := 0;
    while i < deferred.count {
        dc := deferred[i];
        p := dc.pos;
        if vf_match_intrinsic_type(dc.ty, t.descs, *p, dc.mp, otys, *deferred, true, sb) return false;
        i += 1;
    }
    if pos < t.descs.count { append(sb, "intrinsic has too few arguments!"); return false; }
    if func_vararg(ft) != t.vararg {
        if t.vararg append(sb, "intrinsic was not defined with variable arguments!");
        else append(sb, "intrinsic was defined with variable arguments!");
        return false;
    }
    return true;
}

// matchIntrinsicType: true on mismatch, with the message in sb
vf_match_intrinsic_type :: (ty: Type_Id, d: [] IIT_Desc, pos: *s64, mp_in: Match_Pos, otys: *[..] Type_Id,
                            deferred: *[..] Deferred_Msg_Check, is_deferred: bool, sb: *String_Builder) -> bool {
    mp := mp_in;
    if pos.* >= d.count {
        mp_write(sb, mp);
        append(sb, " too many ");
        append(sb, ifx mp.is_ret then "returns" else "arguments");
        return true;
    }
    here := pos.*;
    x := d[pos.*]; pos.* += 1;
    k := type_kind(ty);
    tys :: (t: Type_Id) -> string { return vf_type_string(t); }
    msg :: (valid: bool, expected: string, oidx := -1) -> bool #expand {
        if valid return false;
        mp_write(`sb, `mp);
        append(`sb, " type");
        if oidx >= 0 print_to_builder(`sb, " (overload type %)", oidx);
        print_to_builder(`sb, " expected %, but got %", expected, tys(`ty));
        return true;
    }
    msg_invalid_overload :: (qual: string, expected: string, oidx: u32) -> bool #expand {
        mp_write(`sb, `mp);
        print_to_builder(`sb, " is % overload type %, so overload type % expected %, but got %", qual, oidx, oidx, expected, tys(`otys.*[oidx]));
        return true;
    }
    msg_invalid_dep :: (valid: bool, qual: string, expected: string, oidx: u32) -> bool #expand {
        if valid return false;
        mp_write(`sb, `mp);
        print_to_builder(`sb, " type (% overload type %) expected %", qual, oidx, expected);
        if qual != "matching" print_to_builder(`sb, " (overload type % is %)", oidx, tys(`otys.*[oidx]));
        print_to_builder(`sb, ", but got %", tys(`ty));
        return true;
    }
    defer_check :: () -> bool #expand {
        array_add(`deferred, .{`ty, `here, `mp});
        return false;
    }
    if x.kind == {
      case .Void;     return msg(k == .VOID, "void");
      case .MMX;      return msg(k == .VECTOR && type_count(ty) == 1 && type_elem(ty) == ir.t_i64, "x86_mmx (<1 x i64>)");
      case .AMX;      return msg(k == .X86_AMX, "x86_amx");
      case .Token;    return msg(k == .TOKEN, "token");
      case .Metadata; return msg(k == .METADATA, "metadata");
      case .Half;     return msg(k == .HALF, "half");
      case .BFloat;   return msg(k == .BFLOAT, "bfloat");
      case .Float;    return msg(k == .FLOAT, "float");
      case .Double;   return msg(k == .DOUBLE, "double");
      case .Quad;     return msg(k == .FP128, "fp128");
      case .PPCQuad;  return msg(k == .PPC_FP128, "ppc_fp128");
      case .Integer;  return msg(k == .INT && type_int_width(ty) == x.a, tprint("i%", x.a));
      case .AArch64Svcount; return msg(k == .TARGET_EXT && ir.types[ty].name == "aarch64.svcount", "aarch64.svcount");
      case .WasmExternref;  return msg(k == .TARGET_EXT && ir.types[ty].name == "wasm.externref", "wasm.externref");
      case .WasmFuncref;    return msg(k == .TARGET_EXT && ir.types[ty].name == "wasm.funcref", "wasm.funcref");
      case .Vector;
        scal := x.b != 0;
        if msg(is_vector_type(ty) && type_count(ty) == x.a && (k == .SVECTOR) == scal, tprint("%vector with % elements", ifx scal then "vscale " else "", x.a)) return true;
        mp.idx_struct[mp.nidx] = false; mp.idx_num[mp.nidx] = 0; mp.nidx += 1;
        return vf_match_intrinsic_type(type_elem(ty), d, pos, mp, otys, deferred, is_deferred, sb);
      case .Pointer;
        valid := k == .PTR && ir.types[ty].a == x.a;
        if x.a == 0 return msg(valid, "ptr");
        return msg(valid, tprint("ptr addrspace(%)", x.a));
      case .Struct;
        if msg(k == .STRUCT && (ir.types[ty].flags & TYF_LITERAL) && !(ir.types[ty].flags & TYF_PACKED) && type_nsub(ty) == x.a, tprint("literal non-packed struct with % elements", x.a)) return true;
        for e: 0..cast(s64) type_nsub(ty) - 1 {
            mp2 := mp;
            mp2.idx_struct[mp2.nidx] = true; mp2.idx_num[mp2.nidx] = cast(u32) e; mp2.nidx += 1;
            if vf_match_intrinsic_type(type_sub(ty, cast(u32) e), d, pos, mp2, otys, deferred, is_deferred, sb) return true;
        }
        return false;
      case .Overloaded;
        oidx := cast(s64) (x.a & 0xFF);
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
        if ok return false;
        VK :: string.["", "vector", "scalar"];
        EK :: string.["", "integer", "fp", "pointer"];
        if ec == 0 return msg(false, tprint("any % type", VK[vc]), oidx);
        if vc == 0 return msg(false, tprint("any % or % vector", EK[ec], EK[ec]), oidx);
        if vc == 1 return msg(false, tprint("any % vector", EK[ec]), oidx);
        return msg(false, tprint("any % type", EK[ec]), oidx);
      case .Match;
        if x.a >= otys.count return is_deferred || defer_check();
        return msg_invalid_dep(ty == otys.*[x.a], "matching", tys(otys.*[x.a]), x.a);
      case .Extend; #through;
      case .Trunc;
        if x.a >= otys.count return is_deferred || defer_check();
        o := otys.*[x.a];
        qual := ifx x.kind == .Extend then "extended" else "truncated";
        if !is_int_or_int_vector(o) return msg_invalid_overload(qual, "int or vector of int", x.a);
        nt := ifx x.kind == .Extend then type_extended(o) else type_truncated(o);
        return msg_invalid_dep(ty == nt, qual, tys(nt), x.a);
      case .OneNthEltsVec;
        if x.a >= otys.count return is_deferred || defer_check();
        o := otys.*[x.a];
        qual := tprint("1/nth (n=%) elements vector of", x.b);
        if !is_vector_type(o) return msg_invalid_overload(qual, "vector", x.a);
        if type_count(o) % x.b != 0 return msg_invalid_overload(qual, tprint("vector with multiple of % elements", x.b), x.a);
        e := type_vector(type_count(o) / x.b, type_elem(o), type_kind(o) == .SVECTOR);
        return msg_invalid_dep(e == ty, qual, tys(e), x.a);
      case .SameVecWidth;
        if x.a >= otys.count {
            pos.* = iit_skip(d, pos.*);
            return is_deferred || defer_check();
        }
        o := otys.*[x.a];
        ov := is_vector_type(o); tv := is_vector_type(ty);
        qual := "same vector width of";
        if ov && !tv return msg_invalid_dep(false, qual, "vector", x.a);
        if !ov && tv return msg_invalid_dep(false, qual, "scalar", x.a);
        et := ty;
        if tv {
            if !vf_same_ec(o, ty) return msg_invalid_dep(false, qual, tprint("vector with % elements", vf_ec_string(o)), x.a);
            et = type_elem(ty);
            mp.idx_struct[mp.nidx] = false; mp.idx_num[mp.nidx] = 0; mp.nidx += 1;
        }
        return vf_match_intrinsic_type(et, d, pos, mp, otys, deferred, is_deferred, sb);
      case .VecOfAnyPtrsToElt;
        ref := x.b;
        if ref >= otys.count {
            if is_deferred return true;
            array_add(otys, ty);
            return defer_check();
        }
        if !is_deferred array_add(otys, ty);
        qual := "vector of pointers to elements of";
        r := otys.*[ref];
        if !is_vector_type(r) return msg_invalid_overload(qual, "vector", ref);
        if !is_vector_type(ty) return msg_invalid_dep(false, qual, "vector", ref);
        valid := vf_same_ec(ty, r) && is_ptr_type(type_elem(ty));
        return msg_invalid_dep(valid, qual, tprint("vector of pointers with % elements", vf_ec_string(r)), ref);
      case .VecElement;
        if x.a >= otys.count return is_deferred || defer_check();
        o := otys.*[x.a];
        qual := "vector element of";
        if !is_vector_type(o) return msg_invalid_overload(qual, "vector", x.a);
        return msg_invalid_dep(type_elem(o) == ty, qual, tys(type_elem(o)), x.a);
      case .Subdivide2; #through;
      case .Subdivide4;
        if x.a >= otys.count return is_deferred || defer_check();
        o := otys.*[x.a];
        n: s32 = ifx x.kind == .Subdivide2 then cast(s32) 1 else 2;
        qual := tprint("subdivided by % vector of", ifx n == 1 then 2 else 4);
        if !is_vector_type(o) return msg_invalid_overload(qual, "vector", x.a);
        e := type_subdivided_vector(o, n);
        return msg_invalid_dep(e == ty, qual, tys(e), x.a);
      case .VecOfBitcastsToInt;
        if x.a >= otys.count return is_deferred || defer_check();
        o := otys.*[x.a];
        qual := "vector of bitcasts to int of";
        if !is_vector_type(o) return msg_invalid_overload(qual, "vector", x.a);
        e := type_vector_integer(o);
        return msg_invalid_dep(e == ty, qual, tys(e), x.a);
      case .VarArg; fatal("internal: IITDescriptor::VarArg not expected");
    }
    return true;
}

// ElementCount printing: "N" or "vscale x N"
vf_ec_string :: (t: Type_Id) -> string {
    if type_kind(t) == .SVECTOR return tprint("vscale x %", type_count(t));
    return tprint("%", type_count(t));
}

// Intrinsic::getName(ID, OverloadTys, M, FT); with an unnamed identified struct among the overloads LLVM makes the
// name unique per module (getUniqueIntrinsicName): the existing name is the one it would keep
vf_intrinsic_expected_name :: (id: Intrinsic_Id, otys: [] Type_Id, f: Value_Id) -> string {
    if otys.count == 0 return intrinsic_name(id);
    sb: String_Builder; sb.allocator = temp;
    append(*sb, intrinsic_name(id));
    has_unnamed := false;
    for otys { append(*sb, "."); mangled_type_str(*sb, it, *has_unnamed); }
    s := builder_to_string(*sb,, allocator = temp);
    if has_unnamed && begins_with(vname(f), s) return vname(f);
    return s;
}

// ---------------------------------------------------------------- visitIntrinsicCall

md_arg :: (call: Value_Id, k: u32) -> Md_Id {
    v := op(call, k);
    if vkind(v) != .MD_VALUE return NONE;
    return ir.v_aux[v];
}

// convertStrToRoundingMode
vf_rounding_mode_valid :: (s: string) -> (ok: bool, dynamic: bool) {
    if s == "round.dynamic" return true, true;
    for string.["round.tonearest", "round.downward", "round.upward", "round.towardzero", "round.tonearestaway"] if s == it return true, false;
    return false, false;
}

// APFloatBase::isValidArbitraryFPFormat / getArbitraryFPFormatSizeInBits
vf_arbitrary_fp_format_bits :: (s: string) -> u32 {
    if s == "Float8E5M2" || s == "Float8E5M2FNUZ" || s == "Float8E4M3" || s == "Float8E4M3FN" || s == "Float8E4M3FNUZ" ||
       s == "Float8E4M3B11FNUZ" || s == "Float8E3M4" || s == "Float8E8M0FNU" return 8;
    if s == "Float6E3M2FN" || s == "Float6E2M3FN" return 6;
    if s == "Float4E2M1FN" return 4;
    return 0;
}

vf_visit_intrinsic_call :: (iid: Intrinsic_Id, call: Value_Id) {
    f := block(inst(call).parent).parent;
    na := call_num_args(call);
    for k: 0..cast(s64) na - 1 {
        v := op(call, cast(u32) k);
        if vkind(v) == .MD_VALUE vf_visit_metadata_as_value(ir.v_aux[v], f);
        if is_constant_kind(vkind(v)) vcheck(type_kind(vtype(v)) != .X86_AMX, "const x86_amx is not allowed in argument!");
    }
    arg :: (k: u32) -> Value_Id #expand { return op(`call, k); }
    ci_val :: (k: u32) -> u64 #expand { c := op(`call, k); if vkind(c) == .C_INT return const_int_zext(c); return 0; }
    ty := vtype(call);
    if iid == {
      case VI_assume;
        nb := call_num_bundles(call);
        if nb {
            c := arg(0);
            vcheck(vkind(c) == .C_INT && const_int_zext(c) == 1, "assume with operand bundles must have i1 true condition", vq_val(call));
        }
        for k: 0..cast(s64) nb - 1 {
            tag := call_bundle_tag(call, cast(u32) k);
            b, e := vf_bundle_inputs(call, cast(u32) k);
            n := e - b;
            at :: (j: u32) -> Type_Id #expand { return vtype(op(`call, `b + j)); }
            int64 :: (t: Type_Id) -> bool { return is_int_type(t) && type_int_width(t) <= 64; }
            // getBundleAttrFromOBU: the tag names an attribute
            if tag == "align" {
                vcheck(n >= 2 && n <= 3, "alignment assumptions should have 2 or 3 arguments", vq_val(call));
                vcheck(is_ptr_type(at(0)), "first argument should be a pointer", vq_val(call));
                vcheck(int64(at(1)), "second argument should be an integer with a maximum width of 64 bits", vq_val(call));
                vcheck(n < 3 || int64(at(2)), "third argument should be an integer with a maximum width of 64 bits if present", vq_val(call));
            } else if tag == "cold" {
                vcheck(n == 0, "cold assumptions should have no arguments", vq_val(call));
            } else if tag == "dereferenceable" || tag == "dereferenceable_or_null" {
                vcheck(n == 2, "dereferenceable assumptions should have 2 arguments", vq_val(call));
                vcheck(is_ptr_type(at(0)), "first argument should be a pointer", vq_val(call));
                vcheck(int64(at(1)), "second argument should be an integer with a maximum width of 64 bits", vq_val(call));
            } else if tag == "ignore" {
            } else if tag == "nonnull" {
                vcheck(n == 1, "nonnull assumptions should have 1 argument", vq_val(call));
                vcheck(is_ptr_type(at(0)), "first argument should be a pointer", vq_val(call));
            } else if tag == "noundef" {
                vcheck(n == 1, "noundef assumptions should have 1 argument", vq_val(call));
            } else if tag == "separate_storage" {
                vcheck(n == 2, "separate_storage assumptions should have 2 arguments", vq_val(call));
                vcheck(is_ptr_type(at(0)) && is_ptr_type(at(1)), "arguments to separate_storage assumptions should be pointers", vq_val(call));
            } else {
                check_failed("tags must be valid attribute names", vq_val(call));
            }
        }
      case VI_ucmp; #through;
      case VI_scmp;
        src := vtype(arg(0));
        vcheck(vf_scalar_bits(ty) >= 2, "result type must be at least 2 bits wide", vq_val(call));
        dv := is_vector_type(ty);
        vcheck(is_vector_type(src) == dv, "ucmp/scmp argument and result types must both be either vector or scalar types", vq_val(call));
        if dv vcheck(vf_same_ec(src, ty), "return type and arguments must have the same number of elements", vq_val(call));
      case VI_coro_begin; #through;
      case VI_coro_begin_custom_abi;
        a0 := arg(0);
        vcheck(is_inst(a0) && is_call_base(a0) && begins_with(intrinsic_id_of_call(a0), "llvm.coro.id"), "id argument of llvm.coro.begin must refer to coro.id");
      case VI_coro_id;
        vcheck(vkind(arg(0)) == .C_INT, "align argument only accepts constants");
        promise := arg(1);
        vcheck(vkind(promise) == .C_NULL || (is_inst(promise) && inst_op(promise) == .ALLOCA), "promise argument must refer to an alloca");
        coro := vf_strip_pointer_casts_and_aliases(arg(2));
        before_early := vkind(coro) == .C_NULL;
        vcheck(before_early || vkind(coro) == .FUNCTION, "coro argument must refer to a function");
        info := arg(3);
        if vkind(info) == .C_NULL return;
        vcheck(!before_early, "cannot run CoroSplit before CoroEarly");
        vcheck(vkind(info) == .GLOBAL_VAR && glob(info).is_const && gv_has_definitive_initializer(info), "info argument of llvm.coro.id must refer to an initialized constant");
        init := op(info, 0);
        vcheck(vkind(init) == .C_STRUCT || vkind(init) == .C_ARRAY, "info argument of llvm.coro.id must refer to either a struct or an array");
      case VI_is_fpclass;
        vcheck((ci_val(1) & ~cast(u64) FC_ALL_FLAGS) == 0, "unsupported bits for llvm.is.fpclass test mask");
      case VI_fptrunc_round;
        md := md_arg(call, 1);
        vcheck(md != NONE, "missing rounding mode argument", vq_val(call));
        vcheck(md_is_string(md), "invalid value for llvm.fptrunc.round metadata operand (the operand should be a string)", vq_md(md));
        ok, dyn := vf_rounding_mode_valid(ir.mds[md].str);
        vcheck(ok && !dyn, "unsupported rounding mode argument", vq_val(call));
      case VI_convert_to_arbitrary_fp; #through;
      case VI_convert_from_arbitrary_fp;
        to := iid == VI_convert_to_arbitrary_fp;
        vt := ifx to then vtype(arg(0)) else ty;
        it := ifx to then ty else vtype(arg(0));
        if is_vector_type(vt) {
            vcheck(is_vector_type(it), "if floating-point operand is a vector, integer operand must also be a vector", vq_val(call));
            vcheck(vf_same_ec(vt, it), "floating-point and integer vector operands must have the same element count", vq_val(call));
        }
        im := md_arg(call, 1);
        vcheck(im != NONE, "missing interpretation metadata operand", vq_val(call));
        vcheck(md_is_string(im), "interpretation metadata operand must be a string", vq_val(call));
        interp := ir.mds[im].str;
        vcheck(interp.count > 0, "interpretation metadata string must not be empty", vq_val(call));
        bits := vf_arbitrary_fp_format_bits(interp);
        vcheck(bits != 0, "unsupported interpretation metadata string", vq_val(call));
        vcheck(vf_scalar_bits(it) == bits, "integer type bit width must equal the arbitrary FP format width", vq_val(call));
        if to {
            rm := md_arg(call, 2);
            vcheck(rm != NONE, "missing rounding mode metadata operand", vq_val(call));
            vcheck(md_is_string(rm), "rounding mode metadata operand must be a string", vq_val(call));
            ok, dyn := vf_rounding_mode_valid(ir.mds[rm].str);
            vcheck(ok && !dyn, "unsupported rounding mode argument", vq_val(call));
        }
      case VI_experimental_memset_pattern;
        vcheck(vf_type_is_sized(vtype(arg(1))), "unsized types cannot be used as memset patterns", vq_val(call));
      case VI_memcpy_element_unordered_atomic; #through;
      case VI_memmove_element_unordered_atomic; #through;
      case VI_memset_element_unordered_atomic;
        es := ci_val(3);
        vcheck(es != 0 && (es & (es - 1)) == 0, "element size of the element-wise atomic memory intrinsic must be a power of 2", vq_val(call));
        da := call_param_attr(call, 0, .Alignment);
        vcheck(da != null && es <= da.ival, "incorrect alignment of the destination argument", vq_val(call));
        if iid != VI_memset_element_unordered_atomic {
            sa := call_param_attr(call, 1, .Alignment);
            vcheck(sa != null && es <= sa.ival, "incorrect alignment of the source argument", vq_val(call));
        }
      case VI_call_preallocated_setup;
        num := arg(0);
        found_call := false;
        u := ir.v_first_use[call];
        while u != NONE {
            uc := ir.u_user[u];
            u = ir.u_next[u];
            vcheck(is_inst(uc) && is_call_base(uc), "Uses of llvm.call.preallocated.setup must be calls");
            uid := intrinsic_id_of_call_iid(uc);
            if uid == VI_call_preallocated_arg {
                ai := op(uc, 1);
                vcheck(vkind(ai) == .C_INT, "llvm.call.preallocated.alloc arg index must be a constant");
                av := const_int_sext(ai); nv := const_int_sext(num);
                vcheck(av >= 0 && av < nv, "llvm.call.preallocated.alloc arg index must be between 0 and corresponding llvm.call.preallocated.setup's argument count");
            } else if uid == VI_call_preallocated_teardown {
            } else {
                vcheck(!found_call, "Can have at most one call corresponding to a llvm.call.preallocated.setup");
                found_call = true;
                np: u64 = 0;
                for k: 0..cast(s64) call_num_args(uc) - 1 if vf_call_param_has_attr(uc, cast(u32) k, .Preallocated) np += 1;
                vcheck(np != 0, "cannot use preallocated intrinsics on a call without preallocated arguments");
                vcheck(const_int_zext(num) == np, "llvm.call.preallocated.setup arg size must be equal to number of preallocated arguments at call site", vq_val(call), vq_val(uc));
                if vf_bundle_count(uc, "preallocated") > 1 return;
                pb := vf_bundle_input(uc, "preallocated");
                vcheck(vf_bundle_count(uc, "preallocated") == 1, "Use of llvm.call.preallocated.setup outside intrinsics must be in \"preallocated\" operand bundle");
                vcheck(pb == call, "preallocated bundle must have token from corresponding llvm.call.preallocated.setup");
            }
        }
      case VI_call_preallocated_arg;
        t := arg(0);
        vcheck(is_inst(t) && is_call_base(t) && intrinsic_id_of_call_iid(t) == VI_call_preallocated_setup, "llvm.call.preallocated.arg token argument must be a llvm.call.preallocated.setup");
        vcheck(call_has_fn_attr(call, .Preallocated), "llvm.call.preallocated.arg must be called with a \"preallocated\" call site attribute");
      case VI_call_preallocated_teardown;
        t := arg(0);
        vcheck(is_inst(t) && is_call_base(t) && intrinsic_id_of_call_iid(t) == VI_call_preallocated_setup, "llvm.call.preallocated.teardown token argument must be a llvm.call.preallocated.setup");
      case VI_gcroot; #through;
      case VI_gcwrite; #through;
      case VI_gcread;
        if iid == VI_gcroot {
            ai := strip_pointer_casts(arg(0));
            is_alloca := is_inst(ai) && inst_op(ai) == .ALLOCA;
            vcheck(is_alloca, "llvm.gcroot parameter #1 must be an alloca.", vq_val(call));
            vcheck(is_constant_kind(vkind(arg(1))), "llvm.gcroot parameter #2 must be a constant.", vq_val(call));
            if !is_ptr_type(inst(ai).ty2)
                vcheck(vkind(arg(1)) != .C_NULL, "llvm.gcroot parameter #1 must either be a pointer alloca, or argument #2 must be a non-null constant.", vq_val(call));
        }
        vcheck(glob(f).gc.count > 0, "Enclosing function does not use GC.", vq_val(call));
      case VI_init_trampoline;
        vcheck(vkind(strip_pointer_casts(arg(1))) == .FUNCTION, "llvm.init_trampoline parameter #2 must resolve to a function.", vq_val(call));
      case VI_reloc_none;
        vcheck(md_is_string(md_arg(call, 0)), "llvm.reloc.none argument must be a metadata string", vq_val(call));
      case VI_stackprotector;
        a := strip_pointer_casts(arg(1));
        vcheck(is_inst(a) && inst_op(a) == .ALLOCA, "llvm.stackprotector parameter #2 must resolve to an alloca.", vq_val(call));
      case VI_localescape;
        bb := inst(call).parent;
        vcheck(bb == glob(f).first_block, "llvm.localescape used outside of entry block", vq_val(call));
        vcheck(!vf.saw_frame_escape, "multiple calls to llvm.localescape in one function", vq_val(call));
        for k: 0..cast(s64) na - 1 {
            a := arg(cast(u32) k);
            if vkind(a) == .C_NULL continue;
            ai := strip_pointer_casts(a);
            vcheck(is_inst(ai) && inst_op(ai) == .ALLOCA && vf_is_static_alloca(ai), "llvm.localescape only accepts static allocas", vq_val(call));
        }
        e := vf_frame_escape_entry(f);
        e.escaped = na;
        vf.saw_frame_escape = true;
      case VI_localrecover;
        fn := strip_pointer_casts(arg(0));
        vcheck(vkind(fn) == .FUNCTION && !is_declaration(fn), "llvm.localrecover first argument must be function defined in this module", vq_val(call));
        idx := ci_val(2);
        e := vf_frame_escape_entry(fn);
        lim := ifx idx > 0xFFFF_FFFE then cast(u64) 0xFFFF_FFFF else idx;
        nv := lim + 1;
        if nv > e.max_recovered e.max_recovered = cast(u32) nv;
      case VI_experimental_gc_statepoint;
        if inst_op(call) == .CALL vcheck(vkind(call_callee(call)) != .INLINE_ASM, "gc.statepoint support for inline assembly unimplemented", vq_val(call));
        vcheck(glob(f).gc.count > 0, "Enclosing function does not use GC.", vq_val(call));
        vf_verify_statepoint(call);
      case VI_experimental_gc_result;
        vcheck(glob(f).gc.count > 0, "Enclosing function does not use GC.", vq_val(call));
        sp := arg(0);
        if vkind(sp) == .C_UNDEF || vkind(sp) == .C_POISON return;
        vcheck(is_inst(sp) && is_call_base(sp) && intrinsic_id_of_call_iid(sp) == VI_experimental_gc_statepoint, "gc.result operand #1 must be from a statepoint", vq_val(call), vq_val(arg(0)));
        et := attr_set_find(attr_list_param(inst(sp).attrs, 2), .ElementType);
        tfty := ifx et then et.ty else NONE;
        vcheck(tfty != NONE && ty == func_ret(tfty), "gc.result result type does not match wrapped callee", vq_val(call));
      case VI_experimental_gc_relocate;
        vf_visit_gc_relocate(call, f);
      case VI_experimental_patchpoint;
        if inst(call).cc == VCC_ANYREG vcheck(is_first_class(ty) && !is_aggregate(ty) && type_kind(ty) != .VOID, "patchpoint: invalid return type used with anyregcc", vq_val(call));
      case VI_eh_exceptioncode; #through;
      case VI_eh_exceptionpointer;
        a := arg(0);
        vcheck(is_inst(a) && inst_op(a) == .CATCHPAD, "eh.exceptionpointer argument must be a catchpad", vq_val(call));
      case VI_get_active_lane_mask;
        vcheck(scalar_type(ty) == ir.t_i1, "get_active_lane_mask: element type is not i1", vq_val(call));
      case VI_experimental_get_vector_length;
        vf := arg(1);
        vcheck(!const_int_is_negative(vf) && const_int_zext(vf) != 0, "get_vector_length: VF must be positive", vq_val(call));
      case VI_experimental_guard;
        vcheck(inst_op(call) == .CALL, "experimental_guard cannot be invoked", vq_val(call));
        vcheck(vf_bundle_count(call, "deopt") == 1, "experimental_guard must have exactly one \"deopt\" operand bundle");
      case VI_experimental_deoptimize;
        vcheck(inst_op(call) == .CALL, "experimental_deoptimize cannot be invoked", vq_val(call));
        vcheck(vf_bundle_count(call, "deopt") == 1, "experimental_deoptimize must have exactly one \"deopt\" operand bundle");
        vcheck(ty == func_ret(glob(f).value_type), "experimental_deoptimize return type must match caller return type");
        if inst_op(call) == .CALL {
            nx := inst(call).next;
            is_ret := nx != NONE && inst_op(nx) == .RET;
            vcheck(is_ret, "calls to experimental_deoptimize must be followed by a return");
            if ty != ir.t_void && is_ret
                vcheck(nops(nx) > 0 && op(nx, 0) == call, "calls to experimental_deoptimize must be followed by a return of the value computed by experimental_deoptimize");
        }
      case VI_vastart;
        vcheck(func_vararg(glob(f).value_type), "va_start called in a non-varargs function");
      case VI_get_dynamic_area_offset;
        vcheck(is_int_type(ty) && dl_ptr_spec(dl.alloca_as).bits == type_int_width(ty), "get_dynamic_area_offset result type must be scalar integer matching alloca address space width", vq_val(call));
      case VI_smul_fix; #through; case VI_smul_fix_sat; #through; case VI_umul_fix; #through; case VI_umul_fix_sat; #through;
      case VI_sdiv_fix; #through; case VI_sdiv_fix_sat; #through; case VI_udiv_fix; #through; case VI_udiv_fix_sat;
        scale := ci_val(2);
        w := vf_scalar_bits(vtype(arg(0)));
        if iid == VI_smul_fix || iid == VI_smul_fix_sat || iid == VI_sdiv_fix || iid == VI_sdiv_fix_sat
            vcheck(scale < w, "the scale of s[mul|div]_fix[_sat] must be less than the width of the operands");
        else
            vcheck(scale <= w, "the scale of u[mul|div]_fix[_sat] must be less than or equal to the width of the operands");
      case VI_lrint; #through; case VI_llrint; #through; case VI_lround; #through; case VI_llround;
        vt := vtype(arg(0));
        name := vname(call_called_function(call));
        vcheck(is_vector_type(vt) == is_vector_type(ty), tprint("%: argument and result disagree on vector use", name), vq_val(call));
        if is_vector_type(vt) vcheck(vf_same_ec(vt, ty), tprint("%: argument must be same length as result", name), vq_val(call));
      case VI_bswap;
        vcheck(vf_scalar_bits(ty) % 16 == 0, "bswap must be an even number of bytes", vq_val(call));
      case VI_invariant_start;
        s := arg(0);
        vcheck(vkind(s) == .C_INT && (!const_int_is_negative(s) || const_int_sext(s) == -1), "invariant_start parameter must be -1, 0 or a positive number", vq_val(call));
      case VI_matrix_multiply; #through; case VI_matrix_transpose; #through;
      case VI_matrix_column_major_load; #through; case VI_matrix_column_major_store;
        vf_visit_matrix_intrinsic(iid, call);
      case VI_stepvector;
        vcheck(is_vector_type(ty) && is_int_type(scalar_type(ty)) && vf_scalar_bits(ty) >= 8, "stepvector only supported for vectors of integers with a bitwidth of at least 8.", vq_val(call));
      case VI_experimental_vector_match;
        t1 := vtype(arg(0)); t2 := vtype(arg(1)); mt := vtype(arg(2));
        vcheck(is_vector_type(t1) && is_vector_type(t2) && is_vector_type(mt), "Operands must be vectors.", vq_val(call));
        vcheck(type_kind(t2) == .VECTOR, "Second operand must be a fixed length vector.", vq_val(call));
        vcheck(is_int_type(type_elem(t1)), "First operand must be a vector of integers.", vq_val(call));
        vcheck(type_elem(t1) == type_elem(t2), "First two operands must have the same element type.", vq_val(call));
        vcheck(vf_same_ec(t1, mt), "First operand and mask must have the same number of elements.", vq_val(call));
        vcheck(type_elem(mt) == ir.t_i1, "Mask must be a vector of i1's.", vq_val(call));
        vcheck(ty == mt, "Return type must match the mask type.", vq_val(call));
      case VI_vector_insert;
        vt := vtype(arg(0)); st := vtype(arg(1));
        idx := ci_val(2) & 0xFFFF_FFFF;
        vcheck(type_elem(vt) == type_elem(st), "vector_insert parameters must have the same element type.", vq_val(call));
        vcheck(idx % type_count(st) == 0, "vector_insert index must be a constant multiple of the subvector's known minimum vector length.");
        if (type_kind(vt) == .SVECTOR) == (type_kind(st) == .SVECTOR)
            vcheck(idx < type_count(vt) && idx + type_count(st) <= type_count(vt), "subvector operand of vector_insert would overrun the vector being inserted into.");
      case VI_vector_extract;
        vt := vtype(arg(0));
        idx := ci_val(1) & 0xFFFF_FFFF;
        vcheck(type_elem(ty) == type_elem(vt), "vector_extract result must have the same element type as the input vector.", vq_val(call));
        vcheck(idx % type_count(ty) == 0, "vector_extract index must be a constant multiple of the result type's known minimum vector length.");
        if (type_kind(vt) == .SVECTOR) == (type_kind(ty) == .SVECTOR)
            vcheck(idx < type_count(vt) && idx + type_count(ty) <= type_count(vt), "vector_extract would overrun.");
      case VI_vector_partial_reduce_fadd; #through;
      case VI_vector_partial_reduce_add;
        acc := vtype(arg(0)); vec := vtype(arg(1));
        vcheck(type_count(vec) % type_count(acc) == 0, "Invalid vector widths for partial reduction. The width of the input vector must be a positive integer multiple of the width of the accumulator vector.");
      case VI_experimental_noalias_scope_decl;
        array_add(*vf.noalias_decls, call);
      case VI_preserve_array_access_index; #through;
      case VI_preserve_struct_access_index;
        vcheck(attr_set_find(attr_list_param(inst(call).attrs, 0), .ElementType) != null, "Intrinsic requires elementtype attribute on first argument.", vq_val(call));
      case VI_callbr_landingpad;
        cbr := arg(0);
        vcheck(is_inst(cbr) && inst_op(cbr) == .CALLBR, "intrinstic requires callbr operand", vq_val(call));
        lbb := inst(call).parent;
        pbb := vf_unique_predecessor(lbb);
        if pbb == NONE { check_failed("Intrinsic in block must have 1 unique predecessor", vq_val(call)); return; }
        pt := block_terminator(pbb);
        if pt == NONE || inst_op(pt) != .CALLBR { check_failed("Intrinsic must have corresponding callbr in predecessor", vq_val(call)); return; }
        found := false;
        for k: 1..cast(s64) num_successors(cbr) - 1 if get_successor(cbr, cast(u32) k) == lbb { found = true; break; }
        vcheck(found, "Intrinsic's corresponding callbr must have intrinsic's parent basic block in indirect destination list", vq_val(call));
        vcheck(block(lbb).first == call, "No other instructions may proceed intrinsic", vq_val(call));
      case VI_structured_gep;
        et := attr_set_find(attr_list_param(inst(call).attrs, 0), .ElementType);
        vcheck(et != null, "Intrinsic first parameter is missing an ElementType attribute", vq_val(call));
        t := et.ty;
        for k: 1..cast(s64) na - 1 {
            idx := arg(cast(u32) k);
            vcheck(is_int_type(vtype(idx)), "Index operand type must be an integer", vq_val(call));
            tk := type_kind(t);
            if tk == .ARRAY t = type_elem(t);
            else if tk == .STRUCT {
                vcheck(vkind(idx) == .C_INT, "Indexing into a struct requires a constant int", vq_val(call));
                vcheck(const_int_zext(idx) < type_nsub(t), "Indexing in a struct should be inbounds", vq_val(call));
                t = type_sub(t, cast(u32) const_int_zext(idx));
            } else if is_vector_type(t) t = type_elem(t);
            else check_failed("Reached a non-composite type with more indices to process", vq_val(call));
        }
      case VI_structured_alloca;
        vcheck(attr_set_has(attr_list_ret(inst(call).attrs), .ElementType), "@llvm.structured.alloca calls require elementtype attribute.", vq_val(call));
      case VI_ptrmask;
        t0 := vtype(arg(0)); t1 := vtype(arg(1));
        vcheck(vf_is_ptr_or_ptr_vector(t0), "llvm.ptrmask intrinsic first argument must be pointer or vector of pointers", vq_val(call));
        vcheck(is_vector_type(t0) == is_vector_type(t1), "llvm.ptrmask intrinsic arguments must be both scalars or both vectors", vq_val(call));
        if is_vector_type(t0) vcheck(vf_same_ec(t0, t1), "llvm.ptrmask intrinsic arguments must have the same number of elements", vq_val(call));
        as := cast(u32) ir.types[scalar_type(t0)].a;
        vcheck(dl_ptr_spec(as).idx_bits == vf_scalar_bits(t1), "llvm.ptrmask intrinsic second argument bitwidth must match pointer index type size of first argument", vq_val(call));
      case VI_thread_pointer;
        vcheck(ir.types[ty].a == dl.globals_as, "llvm.thread.pointer intrinsic return type must be for the globals address space", vq_val(call));
      case VI_threadlocal_address;
        a := arg(0);
        vcheck(is_global_value(vkind(a)), "llvm.threadlocal.address first argument must be a GlobalValue");
        vcheck(glob(a).tls != 0, "llvm.threadlocal.address operand isThreadLocal() must be true");
      case VI_lifetime_start; #through;
      case VI_lifetime_end;
        p := arg(0);
        ok := (is_inst(p) && inst_op(p) == .ALLOCA) || vkind(p) == .C_POISON || (is_inst(p) && is_call_base(p) && vf_intrinsic_inst_iid(p) == VI_structured_alloca);
        vcheck(ok, "llvm.lifetime.start/end can only be used on alloca or poison", vq_val(call));
      case VI_sponentry;
        vcheck(ir.types[func_ret(inst(call).ty2)].a == dl.alloca_as, "llvm.sponentry must return a pointer to the stack", vq_val(call));
      case VI_write_volatile_register;
        m := md_arg(call, 0);
        vcheck(vf_md_nops(m) == 1 && md_is_string(md_op(m, 0)), "llvm.write_volatile_register metadata must be a single MDString", vq_val(call));
      case VI_ptrauth_auth_with_pc_and_resign;
        key := ci_val(1);
        vcheck(key == 0 || key == 1, "ptrauth.auth.with.pc.and.resign key must be IA (0) or IB (1)", vq_val(call));
      case;
        name := intrinsic_name(iid);
        if begins_with(name, "llvm.vp.") || begins_with(name, "llvm.experimental.vp.") {
            if vf_is_vp_intrinsic(name) vf_visit_vp_intrinsic(iid, call);
        } else if begins_with(name, "llvm.experimental.constrained.") {
            vf_visit_constrained_fp_intrinsic(iid, call);
        }
    }
    // unmediated control transfers between funclets
    if intrinsic_may_lower_to_function_call(iid) && glob(f).has_personality {
        pers := classify_eh_personality(fn_personality(f));
        if vf_is_scoped_eh_personality(pers) {
            if !vf.eh_colors_done { vf_compute_eh_colors(f); vf.eh_colors_done = true; }
            in_funclet := false;
            found, colors := table_find(*vf.eh_colors, inst(call).parent);
            if found for cb: colors {
                fi := block_first_non_phi(cb);
                if fi != NONE && is_funclet_pad(fi) in_funclet = true;
            }
            has_token := vf_bundle_count(call, "funclet") != 0;
            if in_funclet vcheck(has_token, "Missing funclet token on intrinsic call", vq_val(call));
        }
    }
}

vf_is_vp_intrinsic :: (name: string) -> bool {
    for VP_INFOS if it.name == name return true;
    return false;
}

vf_is_scoped_eh_personality :: (p: Eh_Personality) -> bool {
    return p == .MSVC_CXX || p == .MSVC_X86SEH || p == .MSVC_TABLESEH || p == .CORECLR || p == .WASM_CXX || p == .XL_CXX || p == .ZOS_CXX;
}

vf_compute_eh_colors :: (f: Value_Id) {
    table_reset(*vf.eh_colors);
    color_eh_funclets(f, *vf.eh_colors);
}

vf_is_static_alloca :: (a: Value_Id) -> bool {
    if vkind(op(a, 0)) != .C_INT return false;
    b := inst(a).parent;
    return b == glob(block(b).parent).first_block && (inst(a).flags & F_INALLOCA) == 0;
}

vf_frame_escape_entry :: (f: Value_Id) -> *Frame_Escape {
    for * vf.frame_escape if it.f == f return it;
    e: Frame_Escape; e.f = f;
    array_add(*vf.frame_escape, e);
    return *vf.frame_escape[vf.frame_escape.count - 1];
}

vf_verify_frame_recover_indices :: () {
    for vf.frame_escape {
        vcheck(it.max_recovered <= it.escaped, "all indices passed to llvm.localrecover must be less than the number of arguments passed to llvm.localescape in the parent function", vq_val(it.f));
    }
}

vf_verify_deoptimize_calling_convs :: () {
    if vf.deopt_decls.count == 0 return;
    first := vf.deopt_decls[0];
    for k: 1..vf.deopt_decls.count - 1 {
        g := vf.deopt_decls[k];
        vcheck(glob(first).cc == glob(g).cc, "All llvm.experimental.deoptimize declarations must have the same calling convention", vq_val(first), vq_val(g));
    }
}

vf_verify_noalias_scope_decl :: () {
    for ii: vf.noalias_decls {
        a := op(ii, 0);
        vcheck(vkind(a) == .MD_VALUE, "llvm.experimental.noalias.scope.decl must have a MetadataAsValue argument", vq_val(ii));
        m := ir.v_aux[a];
        vcheck(is_md_node(m), "!id.scope.list must point to an MDNode", vq_val(ii));
        vcheck(vf_md_nops(m) == 1, "!id.scope.list must point to a list with a single scope", vq_val(ii));
        vf_visit_alias_scope_list_metadata(m);
    }
    // the domination rule is checked only with -verify-noalias-scope-decl-dom (off by default)
}

vf_visit_matrix_intrinsic :: (iid: Intrinsic_Id, call: Value_Id) {
    ifn := call_called_function(call);
    ci :: (k: u32) -> u64 #expand { return const_int_zext(op(`call, k)); }
    stride: Value_Id = NONE;
    rows, cols: u64;
    res_ty: Type_Id;
    op0e: Type_Id = NONE; op1e: Type_Id = NONE;
    if iid == VI_matrix_multiply {
        rows = ci(2); n := ci(3); cols = ci(4);
        vcheck(type_count(vtype(op(call, 0))) == rows * n, "First argument of a matrix operation does not match specified shape!");
        vcheck(type_count(vtype(op(call, 1))) == n * cols, "Second argument of a matrix operation does not match specified shape!");
        res_ty = vtype(call);
        op0e = type_elem(vtype(op(call, 0))); op1e = type_elem(vtype(op(call, 1)));
    } else if iid == VI_matrix_transpose {
        rows = ci(1); cols = ci(2);
        res_ty = vtype(call);
        op0e = type_elem(vtype(op(call, 0)));
    } else if iid == VI_matrix_column_major_load {
        s := op(call, 1); if vkind(s) == .C_INT stride = s;
        rows = ci(3); cols = ci(4);
        res_ty = vtype(call);
    } else {
        s := op(call, 2); if vkind(s) == .C_INT stride = s;
        rows = ci(4); cols = ci(5);
        res_ty = vtype(op(call, 0));
        op0e = type_elem(vtype(op(call, 0)));
    }
    et := type_elem(res_ty);
    vcheck(is_int_type(et) || is_fp_type(et), "Result type must be an integer or floating-point type!", vq_val(ifn));
    if op0e != NONE vcheck(et == op0e, "Vector element type mismatch of the result and first operand vector!", vq_val(ifn));
    if op1e != NONE vcheck(et == op1e, "Vector element type mismatch of the result and second operand vector!", vq_val(ifn));
    vcheck(type_count(res_ty) == rows * cols, "Result of a matrix operation does not fit in the returned vector!");
    if stride != NONE {
        vcheck(type_int_width(vtype(stride)) <= 64, "Stride bitwidth cannot exceed 64!", vq_val(ifn));
        vcheck(const_int_zext(stride) >= rows, "Stride must be greater or equal than the number of rows!", vq_val(ifn));
    }
}

vf_visit_gc_relocate :: (call: Value_Id, f: Value_Id) {
    vcheck(call_num_args(call) == 3, "wrong number of arguments", vq_val(call));
    ty := vtype(call);
    vcheck(is_ptr_type(scalar_type(ty)), "gc.relocate must return a pointer or a vector of pointers", vq_val(call));
    tok := op(call, 0);
    statepoint: Value_Id = NONE;
    if is_inst(tok) && inst_op(tok) == .LANDINGPAD {
        lbb := inst(tok).parent;
        ibb := vf_unique_predecessor(lbb);
        vcheck(ibb != NONE, "safepoints should have unique landingpads", vq_val(lbb));
        t := block_terminator(ibb);
        vcheck(t != NONE, "safepoint block should be well formed", vq_val(ibb));
        vcheck(is_call_base(t) && vf_intrinsic_inst_iid(t, true) == VI_experimental_gc_statepoint, "gc relocate should be linked to a statepoint", vq_val(ibb));
        statepoint = t;
    } else {
        is_sp := is_inst(tok) && is_call_base(tok) && vf_intrinsic_inst_iid(tok, true) == VI_experimental_gc_statepoint;
        vcheck(is_sp || vkind(tok) == .C_UNDEF || vkind(tok) == .C_POISON, "gc relocate is incorrectly tied to the statepoint", vq_val(call), vq_val(tok));
        statepoint = tok;
    }
    base := op(call, 1);
    vcheck(vkind(base) == .C_INT, "gc.relocate operand #2 must be integer offset", vq_val(call));
    derived := op(call, 2);
    vcheck(vkind(derived) == .C_INT, "gc.relocate operand #3 must be integer offset", vq_val(call));
    bi := const_int_zext(base); di := const_int_zext(derived);
    if vkind(statepoint) == .C_UNDEF || vkind(statepoint) == .C_POISON return;
    live_b, live_e: u32;
    has_live := false;
    nb := call_num_bundles(statepoint);
    for k: 0..cast(s64) nb - 1 if call_bundle_tag(statepoint, cast(u32) k) == "gc-live" { live_b, live_e = vf_bundle_inputs(statepoint, cast(u32) k); has_live = true; break; }
    if has_live {
        vcheck(bi < live_e - live_b, "gc.relocate: statepoint base index out of bounds", vq_val(call));
        vcheck(di < live_e - live_b, "gc.relocate: statepoint derived index out of bounds", vq_val(call));
    }
    // getBasePtr / getDerivedPtr: from the gc-live bundle, else from the statepoint's arguments
    first := ifx has_live then live_b else 0;
    bt := vtype(op(statepoint, first + cast(u32) bi));
    dt := vtype(op(statepoint, first + cast(u32) di));
    vcheck(vf_is_ptr_or_ptr_vector(bt), "gc.relocate: relocated value must be a pointer", vq_val(call));
    vcheck(vf_is_ptr_or_ptr_vector(dt), "gc.relocate: relocated value must be a pointer", vq_val(call));
    vcheck(is_vector_type(ty) == is_vector_type(dt), "gc.relocate: vector relocates to vector and pointer to pointer", vq_val(call));
    vcheck(ir.types[scalar_type(ty)].a == ir.types[scalar_type(dt)].a, "gc.relocate: relocating a pointer shouldn't change its address space", vq_val(call));
    gc := glob(f).gc;
    // getGCStrategy: the built-in strategies
    known := gc == "statepoint-example" || gc == "coreclr" || gc == "erlang" || gc == "ocaml" || gc == "shadow-stack";
    vcheck(known, "gc.relocate: calling function must have GCStrategy", vq_val(f));
    if gc == "statepoint-example" || gc == "coreclr" {
        // isGCManagedPointer: pointers in address space 1
        is_gc :: (t: Type_Id) -> bool { return ir.types[scalar_type(t)].a == 1; }
        vcheck(is_gc(ty), "gc.relocate: must return gc pointer", vq_val(call));
        vcheck(is_gc(bt), "gc.relocate: relocated value must be a gc pointer", vq_val(call));
        vcheck(is_gc(dt), "gc.relocate: relocated value must be a gc pointer", vq_val(call));
    }
}

vf_verify_statepoint :: (call: Value_Id) {
    vcheck(!call_does_not_access_memory(call) && !call_only_reads_memory(call) && !vf_call_only_accesses_arg_memory(call),
        "gc.statepoint must read and write all memory to preserve reordering restrictions required by safepoint semantics", vq_val(call));
    npb := const_int_sext(op(call, 1));
    vcheck(npb >= 0, "gc.statepoint number of patchable bytes must be positive", vq_val(call));
    et := attr_set_find(attr_list_param(inst(call).attrs, 2), .ElementType);
    vcheck(et != null, "gc.statepoint callee argument must have elementtype attribute", vq_val(call));
    tfty := et.ty;
    vcheck(type_kind(tfty) == .FUNC, "gc.statepoint callee elementtype must be function type", vq_val(call));
    ncall := cast(s32) const_int_zext(op(call, 3));
    vcheck(ncall >= 0, "gc.statepoint number of arguments to underlying call must be positive", vq_val(call));
    np := cast(s32) func_nparams(tfty);
    if func_vararg(tfty) {
        vcheck(ncall >= np, "gc.statepoint mismatch in number of vararg call args", vq_val(call));
        vcheck(type_kind(func_ret(tfty)) == .VOID, "gc.statepoint doesn't support wrapping non-void vararg functions yet", vq_val(call));
    } else {
        vcheck(ncall == np, "gc.statepoint mismatch in number of call args", vq_val(call));
    }
    flags := const_int_zext(op(call, 4));
    vcheck((flags & ~cast(u64) 3) == 0, "unknown flag used in gc.statepoint flags argument", vq_val(call));
    attrs := inst(call).attrs;
    for k: 0..np - 1 {
        vcheck(vtype(op(call, cast(u32) (5 + k))) == func_param(tfty, cast(u32) k), "gc.statepoint call argument does not match wrapped function type", vq_val(call));
        if func_vararg(tfty) vcheck(!attr_set_has(attr_list_param(attrs, cast(u32) (5 + k)), .StructRet), "Attribute 'sret' cannot be used for vararg call arguments!", vq_val(call));
    }
    end_call := 4 + ncall;
    ntv := op(call, cast(u32) (end_call + 1));
    vcheck(vkind(ntv) == .C_INT, "gc.statepoint number of transition arguments must be constant integer", vq_val(call));
    nt := cast(s32) const_int_zext(ntv);
    vcheck(nt == 0, "gc.statepoint w/inline transition bundle is deprecated", vq_val(call));
    end_trans := end_call + 1 + nt;
    ndv := op(call, cast(u32) (end_trans + 1));
    vcheck(vkind(ndv) == .C_INT, "gc.statepoint number of deoptimization arguments must be constant integer", vq_val(call));
    nd := cast(s32) const_int_zext(ndv);
    vcheck(nd == 0, "gc.statepoint w/inline deopt operands is deprecated", vq_val(call));
    vcheck(7 + ncall == cast(s32) call_num_args(call), "gc.statepoint too many arguments", vq_val(call));
    u := ir.v_first_use[call];
    while u != NONE {
        user := ir.u_user[u];
        u = ir.u_next[u];
        is_call := is_inst(user) && inst_op(user) == .CALL;
        vcheck(is_call, "illegal use of statepoint token", vq_val(call), vq_val(user));
        uid := vf_intrinsic_inst_iid(user);
        vcheck(uid == VI_experimental_gc_relocate || uid == VI_experimental_gc_result, "gc.result or gc.relocate are the only value uses of a gc.statepoint", vq_val(call), vq_val(user));
        if uid == VI_experimental_gc_result vcheck(op(user, 0) == call, "gc.result connected to wrong gc.statepoint", vq_val(call), vq_val(user));
    }
}

vf_call_only_accesses_arg_memory :: (call: Value_Id) -> bool {
    me := call_memory_effects(call);
    // MemoryEffects::onlyAccessesArgPointees: only the argmem location (bits 0..1) may be set
    return (me & ~cast(u64) 3) == 0;
}
call_does_not_access_memory :: (call: Value_Id) -> bool { return call_memory_effects(call) == 0; }

vf_visit_vp_intrinsic :: (iid: Intrinsic_Id, call: Value_Id) {
    ty := vtype(call);
    if iid == VI_vp_trunc || iid == VI_vp_zext || iid == VI_vp_sext || iid == VI_vp_fptrunc || iid == VI_vp_fpext || vf_is_vp_cast(iid) {
        vt := vtype(op(call, 0));
        vcheck(vf_same_ec(ty, vt), "VP cast intrinsic first argument and result vector lengths must be equal", vq_val(call));
        rb := vf_scalar_bits(ty); vb := vf_scalar_bits(vt);
        if iid == VI_vp_trunc vcheck(rb < vb, "llvm.vp.trunc intrinsic the bit size of first argument must be larger than the bit size of the return type", vq_val(call));
        else if iid == VI_vp_zext || iid == VI_vp_sext vcheck(rb > vb, "llvm.vp.zext or llvm.vp.sext intrinsic the bit size of first argument must be smaller than the bit size of the return type", vq_val(call));
        else if iid == VI_vp_fptrunc vcheck(rb < vb, "llvm.vp.fptrunc intrinsic the bit size of first argument must be larger than the bit size of the return type", vq_val(call));
        else if iid == VI_vp_fpext vcheck(rb > vb, "llvm.vp.fpext intrinsic the bit size of first argument must be smaller than the bit size of the return type", vq_val(call));
    }
    if iid == VI_vp_fcmp {
        p := vf_cmp_predicate_from_md(call, 2);
        vcheck(p >= 0 && p <= 15, "invalid predicate for VP FP comparison intrinsic", vq_val(call));
    } else if iid == VI_vp_icmp {
        p := vf_cmp_predicate_from_md(call, 2);
        vcheck(p >= 32 && p <= 41, "invalid predicate for VP integer comparison intrinsic", vq_val(call));
    } else if iid == VI_vp_is_fpclass {
        vcheck((const_int_zext(op(call, 1)) & ~cast(u64) FC_ALL_FLAGS) == 0, "unsupported bits for llvm.vp.is.fpclass test mask");
    } else if iid == VI_experimental_vp_splice {
        idx := const_int_sext(op(call, 2));
        kmin := cast(s64) type_count(ty);
        f := block(inst(call).parent).parent;
        vs := attr_set_find(attr_list_fn(glob(f).attrs), .VScaleRange);
        if vs kmin *= cast(s64) (vs.ival >> 32);
        vcheck((idx < 0 && -idx <= kmin) || (idx >= 0 && idx < kmin), "The splice index exceeds the range [-VL, VL-1] where VL is the known minimum number of elements in the vector. For scalable vectors the minimum number of elements is determined from vscale_range.", vq_val(call));
    }
}
vf_is_vp_cast :: (iid: Intrinsic_Id) -> bool {
    n := intrinsic_name(iid);
    for string.["llvm.vp.trunc", "llvm.vp.zext", "llvm.vp.sext", "llvm.vp.fptrunc", "llvm.vp.fpext", "llvm.vp.fptoui", "llvm.vp.fptosi",
        "llvm.vp.uitofp", "llvm.vp.sitofp", "llvm.vp.ptrtoint", "llvm.vp.inttoptr"] if n == it return true;
    return false;
}

// CmpInst predicate of a metadata string argument ("oeq", "eq", ...), -1 if none
vf_cmp_predicate_from_md :: (call: Value_Id, k: u32) -> s32 {
    m := md_arg(call, k);
    if !md_is_string(m) return -1;
    s := ir.mds[m].str;
    F :: string.["false", "oeq", "ogt", "oge", "olt", "ole", "one", "ord", "uno", "ueq", "ugt", "uge", "ult", "ule", "une", "true"];
    for F if it == s return cast(s32) it_index;
    I :: string.["eq", "ne", "ugt", "uge", "ult", "ule", "sgt", "sge", "slt", "sle"];
    for I if it == s return cast(s32) (32 + it_index);
    return -1;
}

vf_visit_constrained_fp_intrinsic :: (iid: Intrinsic_Id, call: Value_Id) {
    na := call_num_args(call);
    has_rm := constrained_has_rounding(iid);
    is_cmp := iid == VI_experimental_constrained_fcmp || iid == VI_experimental_constrained_fcmps;
    nonmd := na - 1 - (ifx has_rm then cast(u32) 1 else 0) - (ifx is_cmp then cast(u32) 1 else 0);
    nops_exp := nonmd + 1 + (ifx has_rm then cast(u32) 1 else 0) + (ifx is_cmp then cast(u32) 1 else 0);
    vcheck(na == nops_exp, "invalid arguments for constrained FP intrinsic", vq_val(call));
    ty := vtype(call);
    if is_cmp {
        p := vf_cmp_predicate_from_md(call, na - 2);
        vcheck(p >= 0 && p <= 15, "invalid predicate for constrained FP comparison intrinsic", vq_val(call));
    } else if iid == VI_experimental_constrained_fptosi || iid == VI_experimental_constrained_fptoui {
        ot := vtype(op(call, 0));
        vcheck(is_fp_or_fp_vector(ot), "Intrinsic first argument must be floating point", vq_val(call));
        vcheck(is_vector_type(ot) == is_vector_type(ty), "Intrinsic first argument and result disagree on vector use", vq_val(call));
        vcheck(is_int_or_int_vector(ty), "Intrinsic result must be an integer", vq_val(call));
        if is_vector_type(ty) vcheck(vf_same_ec(ot, ty), "Intrinsic first argument and result vector lengths must be equal", vq_val(call));
    } else if iid == VI_experimental_constrained_sitofp || iid == VI_experimental_constrained_uitofp {
        ot := vtype(op(call, 0));
        vcheck(is_int_or_int_vector(ot), "Intrinsic first argument must be integer", vq_val(call));
        vcheck(is_vector_type(ot) == is_vector_type(ty), "Intrinsic first argument and result disagree on vector use", vq_val(call));
        vcheck(is_fp_or_fp_vector(ty), "Intrinsic result must be a floating point", vq_val(call));
        if is_vector_type(ty) vcheck(vf_same_ec(ot, ty), "Intrinsic first argument and result vector lengths must be equal", vq_val(call));
    } else if iid == VI_experimental_constrained_fptrunc || iid == VI_experimental_constrained_fpext {
        ot := vtype(op(call, 0));
        vcheck(is_fp_or_fp_vector(ot), "Intrinsic first argument must be FP or FP vector", vq_val(call));
        vcheck(is_fp_or_fp_vector(ty), "Intrinsic result must be FP or FP vector", vq_val(call));
        vcheck(is_vector_type(ot) == is_vector_type(ty), "Intrinsic first argument and result disagree on vector use", vq_val(call));
        if is_vector_type(ot) vcheck(vf_same_ec(ot, ty), "Intrinsic first argument and result vector lengths must be equal", vq_val(call));
        if iid == VI_experimental_constrained_fptrunc vcheck(vf_scalar_bits(ot) > vf_scalar_bits(ty), "Intrinsic first argument's type must be larger than result type", vq_val(call));
        else vcheck(vf_scalar_bits(ot) < vf_scalar_bits(ty), "Intrinsic first argument's type must be smaller than result type", vq_val(call));
    }
    eb := constrained_md_string(call, 1);
    vcheck(eb == "fpexcept.ignore" || eb == "fpexcept.maytrap" || eb == "fpexcept.strict", "invalid exception behavior argument", vq_val(call));
    if has_rm {
        rs := constrained_md_string(call, 2);
        ok, dyn := vf_rounding_mode_valid(rs);
        vcheck(ok, "invalid rounding mode argument", vq_val(call));
    }
}

// ---------------------------------------------------------------- convergence control

Conv_Op :: enum u8 { NONE; ENTRY; ANCHOR; LOOP; }

vf_conv_op :: (i: Value_Id) -> Conv_Op {
    if !is_call_base(i) return .NONE;
    iid := intrinsic_id_of_call_iid(i);
    if iid == NOT_INTRINSIC return .NONE;
    if iid == VI_experimental_convergence_anchor return .ANCHOR;
    if iid == VI_experimental_convergence_entry return .ENTRY;
    if iid == VI_experimental_convergence_loop return .LOOP;
    return .NONE;
}

// a "Check" of the convergence verifier: reportFailure prints the message (through CheckFailed) and the values
// with a fresh slot tracker each (SSAContext::print)
vf_conv_fail :: (msg: string, vals: ..Value_Id) {
    check_failed(msg);
    for vals vf_err(tprint("%\n", vf_isolated_value_string(it)));
}
vcheck_conv :: (c: bool, msg: string, vals: ..Value_Id) #expand {
    if !c { vf_conv_fail(msg, ..vals); `return; }
}

// V->print(OS) with its own ModuleSlotTracker
vf_isolated_value_string :: (v: Value_Id) -> string {
    saved_w := W; saved_vst := vst; saved_need := vst_need;
    W = .{};
    vst.active = false; vst_need = false;
    printer_reset();
    print_state.dirty = true;
    s: string;
    if is_inst(v) s = copy_string(inst_to_string(v),, allocator = temp);
    else s = copy_string(value_as_operand_typed(v),, allocator = temp);
    W = saved_w; vst = saved_vst; vst_need = saved_need;
    current_function = vst.fn;
    return s;
}

// findAndCheckConvergenceTokenUsed
vf_conv_token_used :: (i: Value_Id) -> (Value_Id, failed: bool) {
    if !is_call_base(i) return NONE, false;
    cnt := vf_bundle_count(i, "convergencectrl");
    if cnt > 1 { vf_conv_fail("The 'convergencectrl' bundle can occur at most once on a call", i); return NONE, true; }
    if cnt == 0 return NONE, false;
    nb := call_num_bundles(i);
    b, e: u32;
    for k: 0..cast(s64) nb - 1 if call_bundle_tag(i, cast(u32) k) == "convergencectrl" { b, e = vf_bundle_inputs(i, cast(u32) k); break; }
    if !(e - b == 1 && type_kind(vtype(op(i, b))) == .TOKEN) { vf_conv_fail("The 'convergencectrl' bundle requires exactly one token use.", i); return NONE, true; }
    tok := op(i, b);
    def := ifx is_inst(tok) then tok else NONE;
    if !(def != NONE && vf_conv_op(def) != .NONE) {
        vf_conv_fail("Convergence control tokens can only be produced by calls to the convergence control intrinsics.", tok, i);
        return NONE, true;
    }
    table_set(*vf.conv_tokens, i, def);
    return def, false;
}

// GenericConvergenceVerifier::visit(const Instruction &)
vf_conv_visit :: (i: Value_Id) {
    cop := vf_conv_op(i);
    tok, failed := vf_conv_token_used(i);
    if failed { tok = NONE; }
    f := block(inst(i).parent).parent;
    if cop == {
      case .ENTRY;
        vcheck_conv(fn_has_fn_attr(f, .Convergent), "Entry intrinsic can occur only in a convergent function.", i);
        vcheck_conv(inst(i).parent == glob(f).first_block, "Entry intrinsic can occur only in the entry block.", i);
        vcheck_conv(!vf.conv_seen_first, "Entry intrinsic cannot be preceded by a convergent operation in the same basic block.", i);
        vcheck_conv(tok == NONE, "Entry or anchor intrinsic cannot have a convergencectrl token operand.", i);
      case .ANCHOR;
        vcheck_conv(tok == NONE, "Entry or anchor intrinsic cannot have a convergencectrl token operand.", i);
      case .LOOP;
        vcheck_conv(tok != NONE, "Loop intrinsic must have a convergencectrl token operand.", i);
        vcheck_conv(!vf.conv_seen_first, "Loop intrinsic cannot be preceded by a convergent operation in the same basic block.", i);
    }
    conv := call_has_fn_attr(i, .Convergent);
    if conv vf.conv_seen_first = true;
    if tok != NONE || cop != .NONE {
        vcheck_conv(vf.conv_kind != 2, "Cannot mix controlled and uncontrolled convergence in the same function.", i);
        vf.conv_kind = 1;
    } else if conv {
        vcheck_conv(vf.conv_kind != 1, "Cannot mix controlled and uncontrolled convergence in the same function.", i);
        vf.conv_kind = 2;
    }
}

// GenericConvergenceVerifier::verify(DT)
vf_conv_verify :: (f: Value_Id) {
    dt := vf_dt();
    ci := ci_compute(f);
    defer ci_free(ci);
    Live :: struct { bb: Value_Id; tokens: [..] Value_Id; }
    live_map: [..] Live; live_map.allocator = temp;
    hearts: Table(Cycle_Id, Value_Id); hearts.allocator = temp;
    find_live :: (m: *[..] Live, b: Value_Id) -> s64 { for m.* if it.bb == b return it_index; return -1; }
    contains :: (a: [] Value_Id, v: Value_Id) -> bool { for a if it == v return true; return false; }
    check_token :: (tok: Value_Id, user: Value_Id, live: *[..] Value_Id, ci: *Cycle_Info, dt: *Dom_Tree, hearts: *Table(Cycle_Id, Value_Id)) {
        vcheck_conv(dt_dominates(dt, inst(tok).parent, inst(user).parent), "Convergence control token must dominate all its uses.", tok, user);
        vcheck_conv(contains(live.*, tok), "Convergence region is not well-nested.", tok, user);
        while live.count && live.*[live.count - 1] != tok live.count -= 1;
        bb := inst(user).parent;
        c := ci_cycle_for(ci, bb);
        if c == NONE return;
        def_bb := inst(tok).parent;
        if def_bb == bb || ci_contains(ci, c, def_bb) return;
        if vf_conv_op(user) != .LOOP {
            vf_conv_fail("Convergence token used by an instruction other than llvm.experimental.convergence.loop in a cycle that does not contain the token's definition.", user);
            vf_err(tprint("%\n", vf_cycle_string(ci, c)));
            return;
        }
        while true {
            p := ci.cycles[c].parent;
            if p == NONE || ci_contains(ci, p, def_bb) break;
            c = p;
        }
        if !(ci.cycles[c].entries.count == 1 && bb == ci_header(ci, c)) {
            vf_conv_fail("Cycle heart must dominate all blocks in the cycle.", user);
            vf_err(tprint("%\n%\n", vf_isolated_operand_string(bb), vf_cycle_string(ci, c)));
            return;
        }
        if table_contains(hearts, c) {
            found, prev := table_find(hearts, c);
            vf_conv_fail("Two static convergence token uses in a cycle that does not contain either token's definition.", user, prev);
            vf_err(tprint("%\n", vf_cycle_string(ci, c)));
            return;
        }
        table_set(hearts, c, user);
    }
    rpo := vf_reverse_post_order(f);
    live: [..] Value_Id; live.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    for bb: rpo {
        live.count = 0;
        li := find_live(*live_map, bb);
        if li >= 0 {
            for live_map[li].tokens array_add(*live, it);
            array_unordered_remove_by_index(*live_map, li);
        }
        for i: block_insts(bb) {
            found, tok := table_find(*vf.conv_tokens, i);
            if found && tok != NONE check_token(tok, i, *live, ci, dt, *hearts);
            if vf_conv_op(i) != .NONE array_add(*live, i);
        }
        block_successors(bb, *succs);
        for s: succs {
            si := find_live(*live_map, s);
            if si < 0 {
                e: Live; e.bb = s; e.tokens.allocator = temp;
                for t: live {
                    if !dt_dominates(dt, inst(t).parent, s) break;
                    array_add(*e.tokens, t);
                }
                array_add(*live_map, e);
            } else {
                // keep the tokens that are live here too (llvm::partition keeps the order of the kept ones)
                kept: [..] Value_Id; kept.allocator = temp;
                for t: live_map[si].tokens if contains(live, t) array_add(*kept, t);
                live_map[si].tokens = kept;
            }
        }
    }
}

vf_isolated_operand_string :: (v: Value_Id) -> string { return vf_isolated_value_string(v); }

vf_cycle_string :: (ci: *Cycle_Info, c: Cycle_Id) -> string {
    // CycleInfo::print(C): the cycle's printable form (GenericCycle::print: "depth=N: entries(...) ...")
    r := *ci.cycles[c];
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "depth=%: entries(", r.depth);
    for r.entries { if it_index append(*sb, " "); append(*sb, ci_block_name(it)); }
    append(*sb, ")");
    for r.blocks { if ci_is_entry(ci, c, it) continue; append(*sb, " "); append(*sb, ci_block_name(it)); }
    return builder_to_string(*sb,, allocator = temp);
}

vf_reverse_post_order :: (f: Value_Id) -> [..] Value_Id {
    order: [..] Value_Id; order.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    Frame :: struct { b: Value_Id; next: u32; }
    stack: [..] Frame; stack.allocator = temp;
    entry := glob(f).first_block;
    if entry == NONE return order;
    table_add(*visited, entry, true);
    array_add(*stack, .{entry, 0});
    while stack.count {
        top := *stack[stack.count - 1];
        t := block_terminator(top.b);
        n := ifx t != NONE then num_successors(t) else 0;
        if top.next < n {
            s := get_successor(t, top.next);
            top.next += 1;
            if !table_contains(*visited, s) { table_add(*visited, s, true); array_add(*stack, .{s, 0}); }
            continue;
        }
        array_add(*order, top.b);
        stack.count -= 1;
    }
    // reverse
    for k: 0..order.count / 2 - 1 { tmp := order[k]; order[k] = order[order.count - 1 - k]; order[order.count - 1 - k] = tmp; }
    return order;
}
