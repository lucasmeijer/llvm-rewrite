// ReplaceWithVeclib: port of llvm/lib/CodeGen/ReplaceWithVeclib.cpp (LLVM 23.1.5): replaces calls to vector
// intrinsics that have a TLI vector-library mapping (-vector-library) by calls to the library function.
// Used by opt (`replace-with-veclib`) and by llc's IR pipeline (codegen_pipeline.jai).

replace_with_veclib_run :: (f: Value_Id) -> Preserved {
    replaced: [..] Value_Id; replaced.allocator = temp;
    for b: fn_blocks(f) for i: block_insts(b) {
        if inst_op(i) != .CALL continue;
        iid := call_iid(i);
        if iid == NOT_INTRINSIC continue;
        rt := vtype(i);
        if !is_vector_type(rt) && type_kind(rt) != .VOID continue;
        if rwv_replace_with_call_to_veclib(i, iid) array_add(*replaced, i);
    }
    for replaced erase_inst_with_metadata(it);
    if replaced.count == 0 return PRESERVE_ALL;
    pa := preserved_cfg();
    preserve(*pa, .SCEV); preserve(*pa, .DEMANDED_BITS);
    return pa;
}

#scope_file

// getTLIFunction(M, VectorFTy, TLIName, CC, ScalarFunc)
rwv_get_tli_function :: (vfty: Type_Id, name: string, cc: s64, scalar_fn: Value_Id) -> Value_Id {
    f := module_get_function(name);
    if f != NONE return f;
    f = new_function(vfty, name, dl.program_as);
    array_add(*ir.m_functions, f);
    if scalar_fn != NONE ipo_fn_copy_attributes_from(f, scalar_fn);
    if cc >= 0 glob(f).cc = cast(u32) cc;
    itm_append_to_compiler_used(f);
    return f;
}

// replaceWithCallToVeclib(TLI, II)
rwv_replace_with_call_to_veclib :: (ii: Value_Id, iid: Intrinsic_Id) -> bool {
    rt := vtype(ii);
    srt := scalar_type(rt);
    ec: u64 = 0; ec_scalable := false;
    if is_vector_type(rt) { ec = type_count(rt); ec_scalable = type_kind(rt) == .SVECTOR; }
    oload: [..] Type_Id; oload.allocator = temp;
    if type_kind(rt) != .VOID && rwv_overload_type_at_arg(iid, -1) array_add(*oload, srt);
    sargs: [..] Type_Id; sargs.allocator = temp;
    n := call_arg_count(ii);
    for k: 0..cast(s64) n - 1 {
        at := vtype(call_arg(ii, cast(u32) k));
        is_oload := rwv_overload_type_at_arg(iid, k);
        if rwv_scalar_op_at_arg(iid, k) {
            array_add(*sargs, at);
            if is_oload array_add(*oload, at);
        } else if is_vector_type(at) {
            st := type_elem(at);
            array_add(*sargs, st);
            if is_oload array_add(*oload, st);
            if ec == 0 { ec = type_count(at); ec_scalable = type_kind(at) == .SVECTOR; }
            else if ec != type_count(at) || ec_scalable != (type_kind(at) == .SVECTOR) return false;
        } else return false;
    }
    scalar_name := ifx intrinsic_is_overloaded(iid) then intrinsic_mangled_name(iid, oload) else intrinsic_name(iid);
    vd := tli_get_vector_mapping_info(scalar_name, cast(u32) ec, ec_scalable, false);
    if !vd vd = tli_get_vector_mapping_info(scalar_name, cast(u32) ec, ec_scalable, true);
    if !vd return false;
    sfty := type_func(srt, sargs, false);
    ok, info := vfabi_try_demangle(vec_desc_abi_variant_string(vd), sfty);
    if !ok return false;
    for p: info.shape.params {
        if p.kind == .GLOBAL_PREDICATE continue;
        if p.pos >= n fatal("internal: replace-with-veclib: VFABI parameter position out of range");
        if is_vector_type(vtype(call_arg(ii, p.pos))) != (p.kind == .VECTOR) return false;
    }
    vfty := vfabi_create_function_type(*info, sfty);
    tf := rwv_get_tli_function(vfty, vd.vector, vd.cc, call_called_function(ii));
    // replaceWithTLIFunction
    args: [..] Value_Id; args.allocator = temp;
    for k: 0..cast(s64) n - 1 array_add(*args, call_arg(ii, cast(u32) k));
    masked := false;
    for info.shape.params if it.kind == .GLOBAL_PREDICATE masked = true;
    if masked array_add(*args, const_all_ones_of(type_vector(cast(u64) info.shape.vf, ir.t_i1, info.shape.scalable)));
    b: Irb;
    irb_set_before(*b, ii);
    nc := irb_call_with_bundles_of(*b, tf, args, ii);
    if is_fp_math_operator(nc) && is_fp_math_operator(ii) set_fmf(nc, get_fmf(ii));
    rauw_with_metadata(ii, nc);
    inst(nc).cc = glob(tf).cc;
    return true;
}

rwv_vp_info :: (n: string) -> *Vp_Info {
    for * VP_INFOS if it.name == n return it;
    return null;
}

// isVectorIntrinsicWithOverloadTypeAtArg(ID, OpdIdx, /*TTI=*/nullptr) (VectorUtils.cpp)
rwv_overload_type_at_arg :: (id: Intrinsic_Id, idx: s64) -> bool {
    n := intrinsic_name(id);
    vp := rwv_vp_info(n);
    if vp && is_cast_op(vp.opcode) return idx == -1 || idx == 0;   // VPCastIntrinsic::isVPCast
    if n == "llvm.fptosi.sat" || n == "llvm.fptoui.sat" || n == "llvm.lround" || n == "llvm.llround" || n == "llvm.lrint" ||
       n == "llvm.llrint" || n == "llvm.vp.lrint" || n == "llvm.vp.llrint" || n == "llvm.ucmp" || n == "llvm.scmp" ||
       n == "llvm.vector.extract" || n == "llvm.loop.dependence.war.mask"
        return idx == -1 || idx == 0;
    if n == "llvm.modf" || n == "llvm.sincos" || n == "llvm.sincospi" || n == "llvm.is.fpclass" || n == "llvm.vp.is.fpclass" return idx == 0;
    if n == "llvm.powi" || n == "llvm.ldexp" return idx == -1 || idx == 1;
    if n == "llvm.experimental.vp.strided.load" return idx == -1 || idx == 0 || idx == 1;
    return idx == -1;
}

// isVectorIntrinsicWithScalarOpAtArg(ID, ScalarOpdIdx, /*TTI=*/nullptr) (VectorUtils.cpp)
rwv_scalar_op_at_arg :: (id: Intrinsic_Id, idx: s64) -> bool {
    n := intrinsic_name(id);
    vp := rwv_vp_info(n);
    if vp && vp.evl_pos >= 0 && cast(s64) vp.evl_pos == idx return true;   // VPIntrinsic::getVectorLengthParamPos
    if n == "llvm.abs" || n == "llvm.vp.abs" || n == "llvm.ctlz" || n == "llvm.vp.ctlz" || n == "llvm.cttz" || n == "llvm.vp.cttz" ||
       n == "llvm.is.fpclass" || n == "llvm.vp.is.fpclass" || n == "llvm.powi" || n == "llvm.vector.extract"
        return idx == 1;
    if n == "llvm.smul.fix" || n == "llvm.smul.fix.sat" || n == "llvm.umul.fix" || n == "llvm.umul.fix.sat" ||
       n == "llvm.vector.splice.left" || n == "llvm.vector.splice.right"
        return idx == 2;
    if n == "llvm.experimental.vp.splice" return idx == 2 || idx == 4;
    if n == "llvm.experimental.vp.strided.load" return idx == 0 || idx == 1;
    if n == "llvm.loop.dependence.war.mask" return true;
    return false;
}
