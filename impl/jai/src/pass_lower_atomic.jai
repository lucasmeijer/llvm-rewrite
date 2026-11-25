// LowerAtomic (`lower-atomic`): port of llvm/lib/Transforms/Scalar/LowerAtomicPass.cpp and
// llvm/lib/Transforms/Utils/LowerAtomic.cpp (lowerAtomicCmpXchgInst, buildCmpXchgValue, buildAtomicRMWValue,
// lowerAtomicRMWInst) with IRBuilder<> (ConstantFolder). AtomicExpand's copy of buildAtomicRMWValue
// (atomic_expand.jai) uses an InstSimplifyFolder and stays separate.

lower_atomic_run :: (f: Value_Id) -> Preserved {
    changed := false;
    for bb: fn_blocks(f) {
        for :early_inc i: block_insts(bb) {
            o := inst_op(i);
            if o == .FENCE { erase_inst_with_metadata(i); changed = true; }
            else if o == .CMPXCHG { la_lower_cmpxchg(i); changed = true; }
            else if o == .ATOMICRMW { la_lower_rmw(i); changed = true; }
            else if o == .LOAD || o == .STORE {
                // setAtomic(NotAtomic): ordering and sync scope (System); does not count as a change
                if inst(i).ord1 != 0 { inst(i).ord1 = 0; inst(i).sync = 0; }
            }
        }
    }
    if changed return .{};   // PreservedAnalyses::none()
    return PRESERVE_ALL;
}

la_lower_cmpxchg :: (cxi: Value_Id) {
    b: Irb; irb_set_before(*b, cxi);
    ptr := op(cxi, 0); cmp := op(cxi, 1); val := op(cxi, 2);
    align := inst(cxi).align;
    // buildCmpXchgValue
    orig := irb_load(*b, vtype(val), ptr, align);
    equal := irb_icmp(*b, ICMP_EQ, orig, cmp);
    res := irb_select(*b, equal, val, orig);
    irb_store(*b, res, ptr, align);
    r := irb_insert_value(*b, const_poison(vtype(cxi)), orig, .[0]);
    r = irb_insert_value(*b, r, equal, .[1]);
    rauw_with_metadata(cxi, r);
    erase_inst_with_metadata(cxi);
}

la_lower_rmw :: (rmw: Value_Id) {
    b: Irb; irb_set_before(*b, rmw);
    strict := fn_has_fn_attr(inst_fn(rmw), .StrictFP);
    ptr := op(rmw, 0); val := op(rmw, 1);
    vt := vtype(val);
    orig := irb_load(*b, vt, ptr, dl_abi_align(vt));
    res := la_build_rmw_value(*b, inst(rmw).ord2, orig, val, strict);
    irb_store(*b, res, ptr, dl_abi_align(vtype(res)));
    rauw_with_metadata(rmw, orig);
    erase_inst_with_metadata(rmw);
}

// buildAtomicRMWValue with a ConstantFolder IRBuilder
la_build_rmw_value :: (b: *Irb, rop: u8, loaded: Value_Id, v: Value_Id, strict: bool) -> Value_Id {
    t := vtype(loaded);
    sel :: (b: *Irb, pred: u8, loaded: Value_Id, v: Value_Id) -> Value_Id {
        c := irb_icmp(b, pred, loaded, v);
        return irb_select(b, c, loaded, v, "new");
    }
    intr :: (b: *Irb, name: string, t: Type_Id, l: Value_Id, r: Value_Id, n := "") -> Value_Id {
        return vp_intrinsic(b, intrinsic_id_by_name(name), .[t], .[l, r], n);   // ConstantFolder::FoldIntrinsic folds nothing
    }
    if strict && (rop == RMW_FADD || rop == RMW_FSUB || rop == RMW_FMAX || rop == RMW_FMIN)
        fatal("lower-atomic: a floating-point atomicrmw in a strictfp function (constrained FP intrinsics) is not supported yet");
    if rop == {
        case RMW_XCHG; return v;
        case RMW_ADD; return irb_binop(b, .ADD, loaded, v, "new");
        case RMW_SUB; return irb_binop(b, .SUB, loaded, v, "new");
        case RMW_AND; return irb_binop(b, .AND, loaded, v, "new");
        case RMW_NAND;
            a := irb_binop(b, .AND, loaded, v);
            return irb_binop(b, .XOR, a, const_all_ones_of(vtype(a)), "new");
        case RMW_OR; return irb_binop(b, .OR, loaded, v, "new");
        case RMW_XOR; return irb_binop(b, .XOR, loaded, v, "new");
        case RMW_MAX; return sel(b, ICMP_SGT, loaded, v);
        case RMW_MIN; return sel(b, ICMP_SLE, loaded, v);
        case RMW_UMAX; return sel(b, ICMP_UGT, loaded, v);
        case RMW_UMIN; return sel(b, ICMP_ULE, loaded, v);
        case RMW_FADD; return irb_binop(b, .FADD, loaded, v, "new");
        case RMW_FSUB; return irb_binop(b, .FSUB, loaded, v, "new");
        case RMW_FMAX; return intr(b, "llvm.maxnum", t, loaded, v);
        case RMW_FMIN; return intr(b, "llvm.minnum", t, loaded, v);
    }
    name := RMW_OPS[rop];
    if name == "fmaximum" return intr(b, "llvm.maximum", t, loaded, v);
    if name == "fminimum" return intr(b, "llvm.minimum", t, loaded, v);
    if name == "fmaximumnum" return intr(b, "llvm.maximumnum", t, loaded, v);
    if name == "fminimumnum" return intr(b, "llvm.minimumnum", t, loaded, v);
    if name == "uinc_wrap" {
        inc := irb_binop(b, .ADD, loaded, const_int(t, 1));
        c := irb_icmp(b, ICMP_UGE, loaded, v);
        return irb_select(b, c, const_int(t, 0), inc, "new");
    }
    if name == "udec_wrap" {
        dec := irb_binop(b, .SUB, loaded, const_int(t, 1));
        c0 := irb_icmp(b, ICMP_EQ, loaded, const_int(t, 0));
        c1 := irb_icmp(b, ICMP_UGT, loaded, v);
        o := irb_binop(b, .OR, c0, c1);
        return irb_select(b, o, v, dec, "new");
    }
    if name == "usub_cond" {
        c := irb_icmp(b, ICMP_UGE, loaded, v);
        s := irb_binop(b, .SUB, loaded, v);
        return irb_select(b, c, s, loaded, "new");
    }
    if name == "usub_sat" return intr(b, "llvm.usub.sat", t, loaded, v, "new");
    fatal("lower-atomic: unknown atomicrmw operation '%'", name);
    return NONE;
}
