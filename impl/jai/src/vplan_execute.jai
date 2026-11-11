// VPTransformState and VPlan execution: VPlan::execute, VPBasicBlock / VPIRBasicBlock::execute (connectToPredecessors),
// VPTransformState::get / set, and every ported recipe's execute() as one switch on Vp_Kind.
// Ported from llvm/lib/Transforms/Vectorize/VPlan.cpp, VPlanHelpers.h and VPlanRecipes.cpp (LLVM 23.1.5).
// Recipes whose execution is not ported yet fail loudly.

Vp_State :: struct {
    vf: Ec;
    uf: u32;
    vec: Table(Vp_Val, Value_Id);              // Data.VPV2Vector
    scal: Table(Vp_Val, [..] Value_Id);        // Data.VPV2Scalars (index = lane; NONE = unset)
    b: Irb;
    fmf: u32;                                  // the IRBuilder's FastMathFlags
    prev_vpbb: Vp_Blk = NONE;
    prev_bb: Value_Id = NONE;
    exit_bb: Value_Id = NONE;
    vpbb2irbb: Table(Vp_Blk, Value_Id);
    dtu: Dtu;                                  // Lazy
    li: *Loop_Info;
    cur_parent_loop: Loop_Id = NONE;
    vpdt: Vp_Dom_Tree;
    ac: *Assumption_Cache;
    f: Value_Id;
}

vs_has_vector :: (s: *Vp_State, d: Vp_Val) -> bool { return table_contains(*s.vec, d); }
vs_has_scalar :: (s: *Vp_State, d: Vp_Val, lane: u64) -> bool {
    p := table_find_pointer(*s.scal, d);
    if !p return false;
    return cast(s64) lane < p.count && p.*[lane] != NONE;
}
vs_set :: (s: *Vp_State, d: Vp_Val, v: Value_Id, is_scalar := false) {
    if is_scalar { vs_set_lane(s, d, v, 0); return; }
    table_set(*s.vec, d, v);
}
vs_reset :: (s: *Vp_State, d: Vp_Val, v: Value_Id) { table_set(*s.vec, d, v); }
vs_set_lane :: (s: *Vp_State, d: Vp_Val, v: Value_Id, lane: u64) {
    p := table_find_pointer(*s.scal, d);
    if !p { e: [..] Value_Id; e.allocator = temp; table_set(*s.scal, d, e); p = table_find_pointer(*s.scal, d); }
    while p.count <= cast(s64) lane array_add(p, NONE);
    assert(p.*[lane] == NONE, "should overwrite existing value");
    p.*[lane] = v;
}

// VPTransformState::get(Def, Lane)
vs_get_lane :: (s: *Vp_State, d: Vp_Val, lane: u64) -> Value_Id {
    k := vv(d).kind;
    if k == .IR || k == .SYMBOLIC || k == .REGION {
        assert(vv(d).uv != NONE, "symbolic VPValue used before it is materialized");
        return vv(d).uv;
    }
    if vs_has_scalar(s, d, lane) return table_find_pointer(*s.scal, d).*[lane];
    if lane != 0 && vp_is_single_scalar(d) && vs_has_scalar(s, d, 0) return table_find_pointer(*s.scal, d).*[0];
    if vp_val_is_vpi(d, VPI_BUILD_VECTOR) return vs_get(s, vp_op(vp_def(d), cast(s64) lane), true);
    found, vecp := table_find(*s.vec, d);
    assert(found, "VPValue has no generated value");
    if !is_vector_type(vtype(vecp)) {
        assert(lane == 0, "cannot get lane > 0 for scalar");
        return vecp;
    }
    return irb_extract_element(*s.b, vecp, lane);
}

// VPTransformState::get(Def, NeedsScalar)
vs_get :: (s: *Vp_State, d: Vp_Val, needs_scalar := false) -> Value_Id {
    if needs_scalar return vs_get_lane(s, d, 0);
    found, v := table_find(*s.vec, d);
    if found return v;
    scalar := vs_get_lane(s, d, 0);
    last := vs_get_lane(s, d, s.vf.n - 1);
    saved := s.b;
    if is_inst(last) {
        bb := inst_block(last);
        if inst_op(last) == .PHI {
            pt := block_first_insertion_pt(bb);
            if pt != NONE irb_set_at(*s.b, bb, pt, false);
        } else {
            nx := inst(last).next;
            if nx != NONE irb_set_at(*s.b, bb, nx, true);
            else irb_set_end(*s.b, bb);
        }
    }
    vecv := scalar;
    if !ec_is_scalar(s.vf) vecv = irb_vector_splat(*s.b, s.vf.n, scalar, "broadcast");
    s.b = saved;
    vs_set(s, d, vecv);
    return vecv;
}

// ---------------------------------------------------------------- IR creation helpers (IRBuilder with FMF)

vs_is_fp_math :: (i: Value_Id) -> bool { return is_inst(i) && is_fp_math_operator(i); }
vs_binop :: (s: *Vp_State, opc: Opcode, a: Value_Id, b: Value_Id, name := "") -> Value_Id {
    r := irb_binop(*s.b, opc, a, b, name);
    if is_inst(r) && is_fp_math_operator(r) && r != a && r != b set_fmf(r, s.fmf);
    return r;
}
vs_unop :: (s: *Vp_State, opc: Opcode, a: Value_Id, name := "") -> Value_Id {
    assert(opc == .FNEG);
    if is_const(a) { f := cf_unary(.FNEG, a); if f != NONE return f; }
    i := new_inst(.FNEG, vtype(a), 1);
    set_op(i, 0, a);
    set_fmf(i, s.fmf);
    return irb_insert(*s.b, i, name);
}
vs_cmp :: (s: *Vp_State, pred: u8, a: Value_Id, b: Value_Id, name := "") -> Value_Id {
    if is_fp_predicate(pred) {
        if irb_is_const(a) && irb_is_const(b) { f := cf_compare(pred, a, b); if f != NONE return f; }
        return irb_insert(*s.b, create_fcmp(pred, a, b, s.fmf), name);
    }
    return irb_icmp(*s.b, pred, a, b, name);
}
vs_select :: (s: *Vp_State, c: Value_Id, t: Value_Id, f: Value_Id, fmf: u32, name := "") -> Value_Id {
    r := irb_select(*s.b, c, t, f, name);
    if is_inst(r) && inst_op(r) == .SELECT && is_fp_math_operator(r) set_fmf(r, fmf);
    return r;
}
vs_insert_element :: (s: *Vp_State, v: Value_Id, e: Value_Id, idx: Value_Id, name := "") -> Value_Id {
    if irb_is_const(v) && irb_is_const(e) && irb_is_const(idx) return ce_insert_element(v, e, idx);
    i := new_inst(.INSERTELEMENT, vtype(v), 3);
    set_op(i, 0, v); set_op(i, 1, e); set_op(i, 2, idx);
    return irb_insert(*s.b, i, name);
}
vs_extract_element :: (s: *Vp_State, v: Value_Id, idx: Value_Id, name := "") -> Value_Id {
    if irb_is_const(v) && irb_is_const(idx) return ce_extract_element(v, idx);
    i := new_inst(.EXTRACTELEMENT, type_elem(vtype(v)), 2);
    set_op(i, 0, v); set_op(i, 1, idx);
    return irb_insert(*s.b, i, name);
}
// IRBuilder::CreateStepVector (fixed VFs: a constant <0, 1, ..., VF-1>)
vs_step_vector :: (s: *Vp_State, vty: Type_Id) -> Value_Id {
    if type_kind(vty) == .SVECTOR vp_unported("scalable step vectors");
    ety := type_elem(vty);
    n := type_count(vty);
    elts: [..] Value_Id; elts.allocator = temp;
    for i: 0..n-1 array_add(*elts, const_int(ety, i));
    return const_vector_of(elts);
}

// VPIRFlags::applyFlags
vp_apply_flags :: (r: Vp_Rec, i: Value_Id) {
    f := vr(r).flags;
    fl := *inst(i).flags;
    if f.optype == {
        case .OVERFLOWING_BINOP; #through; case .TRUNC;
            fl.* &= ~cast(u32) (F_NUW | F_NSW);
            if f.nuw fl.* |= F_NUW;
            if f.nsw fl.* |= F_NSW;
        case .DISJOINT_OP; #through; case .POSSIBLY_EXACT_OP; #through; case .NON_NEG_OP;
            b := ifx f.optype == .DISJOINT_OP then f.disjoint else ifx f.optype == .POSSIBLY_EXACT_OP then f.exact else f.nneg;
            fl.* &= ~cast(u32) F_EXACT;
            if b fl.* |= F_EXACT;
        case .GEP_OP;
            fl.* &= ~cast(u32) (F_INBOUNDS | F_NUSW | F_GEP_NUW);
            fl.* |= f.gep & cast(u32) (F_INBOUNDS | F_NUSW | F_GEP_NUW);
        case .FP_MATH_OP; #through; case .FCMP;
            set_fmf(i, f.fmf);
        case .REDUCTION_OP; fatal("internal: reduction ops should not use applyFlags");
    }
}
// VPIRMetadata::applyMetadata
vp_apply_metadata :: (r: Vp_Rec, i: Value_Id) { for vr(r).md set_metadata(i, it.kind, it.node); }

// ---------------------------------------------------------------- recipe execution

// executePhiRecipe (VPPhi / VPWidenPHIRecipe)
vs_execute_phi :: (s: *Vp_State, r: Vp_Rec, is_scalar: bool, name: string) {
    n := ifx vpbu_is_header(vr(r).parent, *s.vpdt) then 1 else vp_phi_num_incoming(r);
    first := vs_get(s, vp_op(r, 0), is_scalar);
    phi := irb_phi(*s.b, vtype(first), 2, name);
    _, b0 := table_find(*s.vpbb2irbb, vp_phi_incoming_block(r, 0));
    phi_add_incoming(phi, first, b0);
    for k: 1..n-1 {
        _, bk := table_find(*s.vpbb2irbb, vp_phi_incoming_block(r, k));
        phi_add_incoming(phi, vs_get(s, vp_op(r, k), is_scalar), bk);
    }
    vs_set(s, vr(r).def, phi, is_scalar);
}

// VPInstruction::canGenerateScalarForFirstLane
vpi_can_generate_scalar_for_first_lane :: (r: Vp_Rec) -> bool {
    o := vr(r).opcode;
    if vp_is_ir_opcode(o) && (is_binary_op(vp_ir_opcode(o)) || is_cast_op(vp_ir_opcode(o))) return true;
    if vpi_is_single_scalar(r) || vpi_is_vector_to_scalar(r) return true;
    return o == vp_opc(.FREEZE) || o == vp_opc(.ICMP) || o == vp_opc(.PHI) || o == vp_opc(.SELECT) || o == VPI_BRANCH_ON_COND ||
           o == VPI_BRANCH_ON_TWO_CONDS || o == VPI_BRANCH_ON_COUNT || o == VPI_CALCULATE_TRIP_COUNT_MINUS_VF ||
           o == VPI_CANONICAL_IV_INCREMENT_FOR_PART || o == VPI_PTR_ADD || o == VPI_EXPLICIT_VECTOR_LENGTH || o == VPI_ANY_OF ||
           o == VPI_NOT;
}
vpi_has_result :: (r: Vp_Rec) -> bool {
    o := vr(r).opcode;
    if o == VPI_BRANCH_ON_COND || o == VPI_BRANCH_ON_TWO_CONDS || o == VPI_BRANCH_ON_COUNT return false;
    if vp_is_ir_opcode(o) {
        io := vp_ir_opcode(o);
        return !(io == .RET || io == .BR || io == .CONDBR || io == .STORE || io == .SWITCH || io == .INDIRECTBR || io == .RESUME ||
                 io == .CATCHRET || io == .UNREACHABLE || io == .FENCE || io == .ATOMICRMW);
    }
    return true;
}

// VPInstruction::generate
vpi_generate :: (s: *Vp_State, r: Vp_Rec) -> Value_Id {
    o := vr(r).opcode;
    name := vr(r).name;
    if vp_is_ir_opcode(o) && is_binary_op(vp_ir_opcode(o)) {
        ofl := vp_only_first_lane_used(vr(r).def);
        a := vs_get(s, vp_op(r, 0), ofl);
        b := vs_get(s, vp_op(r, 1), ofl);
        res := vs_binop(s, vp_ir_opcode(o), a, b, name);
        if is_inst(res) && res != a && res != b vp_apply_flags(r, res);
        return res;
    }
    if o == {
        case VPI_NOT;
            a := vs_get(s, vp_op(r, 0), vp_only_first_lane_used(vr(r).def));
            return irb_not(*s.b, a, name);
        case cast(u16) Opcode.EXTRACTELEMENT;
            assert(ec_is_vector(s.vf), "Only extract elements from vectors");
            if vp_is_constant_int(vp_op(r, 1)) return vs_get_lane(s, vp_op(r, 0), ap_zext_value(vp_const_int_value(vp_op(r, 1))));
            return vs_extract_element(s, vs_get(s, vp_op(r, 0)), vs_get(s, vp_op(r, 1), true), name);
        case cast(u16) Opcode.INSERTELEMENT;
            return vs_insert_element(s, vs_get(s, vp_op(r, 0), false), vs_get(s, vp_op(r, 1), true), vs_get(s, vp_op(r, 2), true), name);
        case cast(u16) Opcode.FREEZE;
            return irb_freeze(*s.b, vs_get(s, vp_op(r, 0), vp_only_first_lane_used(vr(r).def)), name);
        case cast(u16) Opcode.FCMP; #through;
        case cast(u16) Opcode.ICMP;
            ofl := vp_only_first_lane_used(vr(r).def);
            a := vs_get(s, vp_op(r, 0), ofl);
            b := vs_get(s, vp_op(r, 1), ofl);
            return vs_cmp(s, vr(r).flags.pred, a, b, name);
        case cast(u16) Opcode.SELECT;
            ofl := vp_only_first_lane_used(vr(r).def);
            c := vs_get(s, vp_op(r, 0), ofl || vp_is_single_scalar(vp_op(r, 0)));
            a := vs_get(s, vp_op(r, 1), ofl);
            b := vs_get(s, vp_op(r, 2), ofl);
            return vs_select(s, c, a, b, vp_fmf_or_none(r), name);
        case VPI_BRANCH_ON_COND;
            cond := vs_get_lane(s, vp_op(r, 0), 0);
            bb := vr(r).parent;
            second := vb(bb).succs[1];
            _, second_ir := table_find(*s.vpbb2irbb, second);
            _, irbb := table_find(*s.vpbb2irbb, bb);
            br := irb_insert(*s.b, create_cond_br(cond, irbb, second_ir));
            set_successor(br, 0, NONE);
            erase_inst(block_terminator(irbb));
            vp_apply_metadata(r, br);
            return br;
        case VPI_BROADCAST;
            return irb_vector_splat(*s.b, s.vf.n, vs_get(s, vp_op(r, 0), true), "broadcast");
        case VPI_BUILD_VECTOR;
            sty := vp_scalar_type(vp_op(r, 0));
            res := const_poison(type_vector(cast(u64) vp_nops(r), sty, false));
            for k: 0..vp_nops(r)-1 res = vs_insert_element(s, res, vs_get(s, vp_op(r, k), true), const_int(ir.t_i32, cast(u64) k));
            return res;
        case VPI_EXTRACT_LAST_LANE; #through;
        case VPI_EXTRACT_PENULTIMATE_ELEMENT;
            off: u64 = ifx o == VPI_EXTRACT_PENULTIMATE_ELEMENT then cast(u64) 2 else 1;
            res: Value_Id;
            if ec_is_vector(s.vf) res = vs_get_lane(s, vp_op(r, 0), s.vf.n - off);
            else res = vs_get(s, vp_op(r, 0));
            if is_inst(res) && inst_op(res) == .EXTRACTELEMENT && name.count set_name(res, name);
            return res;
        case VPI_LOGICAL_AND; #through;
        case VPI_LOGICAL_OR;
            a := vs_get(s, vp_op(r, 0)); b := vs_get(s, vp_op(r, 1));
            t := vtype(a);
            if o == VPI_LOGICAL_AND return irb_select(*s.b, a, b, const_null_value(t), name);
            return irb_select(*s.b, a, cf_all_ones(t), b, name);
        case VPI_PTR_ADD;
            assert(ec_is_scalar(s.vf) || vp_only_first_lane_used(vr(r).def), "can only generate first lane for PtrAdd");
            p := vs_get_lane(s, vp_op(r, 0), 0);
            a := vs_get_lane(s, vp_op(r, 1), 0);
            return irb_gep(*s.b, ir.t_i8, p, .[a], name, vr(r).flags.gep);
        case VPI_WIDE_PTR_ADD;
            p := vs_get(s, vp_op(r, 0), vp_is_single_scalar(vp_op(r, 0)));
            a := vs_get(s, vp_op(r, 1));
            return irb_gep(*s.b, ir.t_i8, p, .[a], name, vr(r).flags.gep);
        case VPI_ANY_OF;
            res := irb_freeze(*s.b, vs_get(s, vp_op(r, 0)));
            for k: 1..vp_nops(r)-1 res = vs_binop(s, .OR, res, irb_freeze(*s.b, vs_get(s, vp_op(r, k))));
            if ec_is_scalar(s.vf) return res;
            return irb_intrinsic(*s.b, "llvm.vector.reduce.or", .[vtype(res)], .[res]);
        case VPI_RESUME_FOR_EPILOGUE;
            return vs_get(s, vp_op(r, 0), true);
        case VPI_EXTRACT_LAST_ACTIVE;
            res := vs_get(s, vp_op(r, 0), true);
            k := 1;
            while k < vp_nops(r) {
                data := vs_get(s, vp_op(r, k));
                mask := vs_get(s, vp_op(r, k + 1));
                if ec_is_scalar(s.vf) res = vs_select(s, mask, data, res, 0);
                else res = irb_intrinsic(*s.b, "llvm.experimental.vector.extract.last.active", .[vtype(data)], .[data, mask, res]);
                k += 2;
            }
            return res;
        case VPI_FIRST_ORDER_RECURRENCE_SPLICE;
            v1 := vs_get(s, vp_op(r, 0));
            if !is_vector_type(vtype(v1)) return v1;
            v2 := vs_get(s, vp_op(r, 1));
            if type_kind(vtype(v1)) == .SVECTOR vp_unported("splicing scalable vectors");
            n := type_count(vtype(v1));
            mask: [..] u32; mask.allocator = temp;
            for k: 0..n-1 array_add(*mask, cast(u32) (n - 1 + k));
            return irb_shuffle(*s.b, v1, v2, mask);
        case VPI_REVERSE;
            v := vs_get(s, vp_op(r, 0));
            vt := vtype(v);
            if type_kind(vt) == .SVECTOR vp_unported("reversing scalable vectors");
            n := type_count(vt);
            mask: [..] u32; mask.allocator = temp;
            for k: 0..n-1 array_add(*mask, cast(u32) (n - 1 - k));
            return irb_shuffle(*s.b, v, NONE, mask, "reverse");
        case VPI_REDUCTION_START_VECTOR;
            if ec_is_scalar(s.vf) return vs_get(s, vp_op(r, 0), true);
            saved := s.fmf; defer s.fmf = saved;
            s.fmf = vp_fmf_or_none(r);
            scale := ap_zext_value(vp_const_int_value(vp_op(r, 2)));
            iden := irb_vector_splat(*s.b, s.vf.n / scale, vs_get(s, vp_op(r, 1), true), "");
            return vs_insert_element(s, iden, vs_get(s, vp_op(r, 0), true), const_int(ir.t_i32, 0));
        case VPI_COMPUTE_REDUCTION_RESULT;
            f := vr(r).flags;
            rk := f.rdx_kind;
            assert(!rk_is_find_iv(rk), "FindIV should use min/max reduction kinds");
            n := vp_nops(r);
            parts: [..] Value_Id; parts.allocator = temp;
            for k: 0..n-1 array_add(*parts, vs_get(s, vp_op(r, k), f.rdx_in_loop));
            saved := s.fmf; defer s.fmf = saved;
            s.fmf = vp_fmf_or_none(r);
            red := parts[0];
            if f.rdx_ordered red = parts[n - 1];
            else for k: 1..n-1 {
                if rk_is_min_max(rk) red = vs_create_min_max_op(s, rk, red, parts[k]);
                else {
                    opc := rk_opcode(rk);
                    if rk == .SUB opc = .ADD;
                    else if rk == .FSUB opc = .FADD;
                    red = vs_binop(s, opc, parts[k], red, "bin.rdx");
                }
            }
            if ec_is_vector(s.vf) && !f.rdx_in_loop red = vs_create_simple_reduction(s, red, rk);
            return red;
    }
    vp_unported(tprint("executing VPInstruction %", vp_opcode_name(o)));
    return NONE;
}

// createMinMaxOp (LoopUtils.cpp)
vs_create_min_max_op :: (s: *Vp_State, rk: Recur_Kind, l: Value_Id, r: Value_Id) -> Value_Id {
    ty := vtype(l);
    if type_kind(scalar_type(ty)) == .INT || rk == .FMINNUM || rk == .FMAXNUM || rk == .FMINIMUM || rk == .FMAXIMUM ||
       rk == .FMINIMUMNUM || rk == .FMAXIMUMNUM {
        name: string;
        if rk == {
            case .UMIN; name = "llvm.umin"; case .UMAX; name = "llvm.umax"; case .SMIN; name = "llvm.smin"; case .SMAX; name = "llvm.smax";
            case .FMIN; #through; case .FMINNUM; name = "llvm.minnum";
            case .FMAX; #through; case .FMAXNUM; name = "llvm.maxnum";
            case .FMINIMUM; name = "llvm.minimum"; case .FMAXIMUM; name = "llvm.maximum";
            case .FMINIMUMNUM; name = "llvm.minimumnum"; case .FMAXIMUMNUM; name = "llvm.maximumnum";
        }
        if is_const(l) && is_const(r) vp_unported("constant-folding min/max intrinsics");
        c := irb_intrinsic(*s.b, name, .[ty], .[l, r]);
        if is_fp_math_operator(c) set_fmf(c, s.fmf);
        set_name(c, "rdx.minmax");
        return c;
    }
    pred: u8 = 0;
    if rk == {
        case .UMIN; pred = ICMP_ULT; case .UMAX; pred = ICMP_UGT; case .SMIN; pred = ICMP_SLT; case .SMAX; pred = ICMP_SGT;
        case .FMIN; pred = FCMP_OLT; case .FMAX; pred = FCMP_OGT;
        case; fatal("internal: unknown min/max recurrence kind");
    }
    c := vs_cmp(s, pred, l, r, "rdx.minmax.cmp");
    sel := vs_select(s, c, l, r, s.fmf, "rdx.minmax.select");
    ok_ec, ec := fn_entry_count(s.f);
    if is_inst(sel) && inst_op(sel) == .SELECT && ok_ec vp_unported("setExplicitlyUnknownBranchWeightsIfProfiled on profiled functions");
    return sel;
}
// createSimpleReduction (LoopUtils.cpp)
vs_create_simple_reduction :: (s: *Vp_State, src: Value_Id, rk: Recur_Kind) -> Value_Id {
    vty := vtype(src);
    elt := type_elem(vty);
    name := lv_reduction_intrinsic_id(rk);
    c: Value_Id;
    if rk == .FMULADD || rk == .FADD_CHAIN_WITH_SUBS || rk == .FSUB || rk == .FADD || rk == .FMUL {
        iden := lv_recurrence_identity(rk, elt, s.fmf);
        c = irb_intrinsic(*s.b, name, .[vty], .[iden, src]);
    } else {
        if rk_is_any_of(rk) || rk_is_find(rk) fatal("internal: unhandled recurrence kind in createSimpleReduction");
        if is_const(src) vp_unported("constant-folding reduction intrinsics");
        c = irb_intrinsic(*s.b, name, .[vty], .[src]);
    }
    if is_fp_math_operator(c) set_fmf(c, s.fmf);
    return c;
}

// VPInstruction::execute
vpi_execute :: (s: *Vp_State, r: Vp_Rec) {
    o := vr(r).opcode;
    saved := s.fmf;
    defer s.fmf = saved;
    s.fmf = vp_fmf_or_none(r);
    if o == vp_opc(.PHI) { vs_execute_phi(s, r, true, vr(r).name); return; }
    if vp_is_instruction_with_type(r) { vpi_with_type_execute(s, r); return; }
    gv := vpi_generate(s, r);
    if !vpi_has_result(r) return;
    d := vr(r).def;
    per_first := vpi_can_generate_scalar_for_first_lane(r) && (vp_only_first_lane_used(d) || vpi_is_vector_to_scalar(r) || vpi_is_single_scalar(r));
    vs_set(s, d, gv, per_first);
    if o == VPI_RESUME_FOR_EPILOGUE || o == vp_opc(.FREEZE) vp_set_underlying(d, gv);
}
// VPInstructionWithType::execute
vpi_with_type_execute :: (s: *Vp_State, r: Vp_Rec) {
    rty := vp_scalar_type(vr(r).def);
    o := vr(r).opcode;
    if vp_opcode_is_cast(o) {
        a := vs_get_lane(s, vp_op(r, 0), 0);
        c := irb_cast(*s.b, vp_ir_opcode(o), a, rty);
        if is_inst(c) && c != a { vp_apply_flags(r, c); vp_apply_metadata(r, c); }
        vs_set_lane(s, vr(r).def, c, 0);
        return;
    }
    if o == VPI_STEP_VECTOR { vs_set(s, vr(r).def, vs_step_vector(s, type_vector(s.vf.n, rty, s.vf.scalable))); return; }
    if o == VPI_INTRINSIC {
        args: [..] Value_Id; args.allocator = temp;
        for k: 0..vp_nops(r)-2 array_add(*args, vs_get(s, vp_op(r, k), true));
        id := vp_intrinsic_id(r);
        if !(id == IID_UMAX || id == IID_SMAX || id == IID_UMIN || id == IID_SMIN) vp_unported(tprint("executing scalar intrinsic %", intrinsic_name(id)));
        c := irb_intrinsic(*s.b, intrinsic_name(id), .[rty], args);
        if vr(r).name.count set_name(c, vr(r).name);
        vs_set(s, vr(r).def, c, true);
        return;
    }
    if o == vp_opc(.LOAD) vp_unported("executing scalar VPInstruction loads");
    vp_unported(tprint("executing VPInstructionWithType %", vp_opcode_name(o)));
}

// VPWidenRecipe::execute
vp_widen_execute :: (s: *Vp_State, r: Vp_Rec) {
    o := vp_ir_opcode(vr(r).opcode);
    d := vr(r).def;
    if is_binary_op(o) || o == .FNEG {
        ops: [..] Value_Id; ops.allocator = temp;
        for vr(r).ops array_add(*ops, vs_get(s, it));
        v: Value_Id;
        if o == .FNEG v = vs_unop(s, .FNEG, ops[0]);
        else v = vs_binop(s, o, ops[0], ops[1]);
        if is_inst(v) && v != ops[0] && (ops.count < 2 || v != ops[1]) { vp_apply_flags(r, v); vp_apply_metadata(r, v); }
        vs_set(s, d, v);
        return;
    }
    if o == {
        case .EXTRACTVALUE;
            a := vs_get(s, vp_op(r, 0));
            idx := cast(u32) ap_zext_value(vp_const_int_value(vp_op(r, 1)));
            vs_set(s, d, irb_extract_value(*s.b, a, .[idx]));
        case .FREEZE;
            vs_set(s, d, irb_freeze(*s.b, vs_get(s, vp_op(r, 0))));
        case .ICMP; #through; case .FCMP;
            a := vs_get(s, vp_op(r, 0)); b := vs_get(s, vp_op(r, 1));
            c := vs_cmp(s, vr(r).flags.pred, a, b);
            if is_inst(c) { vp_apply_flags(r, c); vp_apply_metadata(r, c); }
            vs_set(s, d, c);
        case .SELECT;
            co := vp_op(r, 0);
            c := vs_get(s, co, vp_is_single_scalar(co));
            a := vs_get(s, vp_op(r, 1)); b := vs_get(s, vp_op(r, 2));
            sel := vs_select(s, c, a, b, s.fmf);
            vs_set(s, d, sel);
            if is_inst(sel) && inst_op(sel) == .SELECT {
                if is_fp_math_operator(sel) vp_apply_flags(r, sel);
                vp_apply_metadata(r, sel);
            }
        case;
            vp_unported(tprint("widening %", o));
    }
}

// VPScalarIVStepsRecipe::execute
vp_scalar_iv_steps_execute :: (s: *Vp_State, r: Vp_Rec) {
    saved := s.fmf;
    defer s.fmf = saved;
    s.fmf = vp_fmf_or_none(r);
    base := vs_get_lane(s, vp_op(r, 0), 0);
    step := vs_get_lane(s, vp_op(r, 1), 0);
    bty := scalar_type(vtype(base));
    add_op: Opcode; mul_op: Opcode;
    if type_kind(bty) == .INT { add_op = .ADD; mul_op = .MUL; }
    else { add_op = vr(r).ind_opcode; mul_op = .FMUL; }
    first_only := vp_only_first_lane_used(vr(r).def);
    end_lane := ifx first_only then cast(u64) 1 else s.vf.n;
    si := vp_steps_start_index(r);
    start0 := ifx si != NONE then vs_get(s, si, true) else const_null_value(bty);
    for lane: 0..end_lane-1 {
        lv: Value_Id;
        if type_kind(bty) == .INT lv = const_int_ap(bty, ap_u64_implicit_trunc(type_bits(bty), lane));
        else lv = fp_const(bty, cast(s64) lane);
        start := vs_binop(s, add_op, start0, lv);
        mul := vs_binop(s, mul_op, start, step);
        add := vs_binop(s, add_op, base, mul);
        vs_set_lane(s, vr(r).def, add, lane);
    }
}

// VPReplicateRecipe::execute
vp_replicate_execute :: (s: *Vp_State, r: Vp_Rec) {
    assert(vr(r).single_scalar, "VPReplicateRecipes must be unrolled before ::execute");
    ui := vp_underlying_instr(r);
    c := ic_clone_inst(ui);
    rty := vp_scalar_type(vr(r).def);
    if type_kind(rty) != .VOID && rty != vtype(c) ir.v_type[c] = rty;
    vp_apply_flags(r, c);
    vp_apply_metadata(r, c);
    if vp_has_predicate(r) inst(c).pred = vr(r).flags.pred;
    for o, k: vr(r).ops set_op(c, cast(u32) k, vs_get(s, o, true));
    irb_insert(*s.b, c);
    vs_set(s, vr(r).def, c, true);
    if call_iid(c) == IID_ASSUME vp_unported("replicating llvm.assume (AssumptionCache::registerAssumption)");
}

vp_execute_recipe :: (s: *Vp_State, r: Vp_Rec) {
    k := vr(r).kind;
    if k == {
        case .IR_INSTRUCTION;
            i := vr(r).ir_inst;
            if is_phi(i) {
                for o, idx: vr(r).ops {
                    lane := ifx vp_is_single_scalar(o) then cast(u64) 0 else s.vf.n - 1;
                    pred := vb(vr(r).parent).preds[idx];
                    pbb := vp_exiting_basic_block(pred);
                    _, pred_bb := table_find(*s.vpbb2irbb, pbb);
                    irb_set_before(*s.b, block_terminator(pred_bb));
                    v := vs_get_lane(s, o, lane);
                    if phi_block_index(i, pred_bb) < 0 phi_add_incoming(i, v, pred_bb);
                    else phi_set_incoming_value_for_block(i, pred_bb, v);
                }
            } else assert(vp_nops(r) == 0, "PHINodes must be handled by VPIRPhi");
            nx := inst(i).next;
            if nx != NONE irb_set_at(*s.b, inst_block(i), nx, false); else irb_set_end(*s.b, inst_block(i));
        case .INSTRUCTION; vpi_execute(s, r);
        case .WIDEN; vp_widen_execute(s, r);
        case .WIDEN_CAST;
            assert(ec_is_vector(s.vf), "Not vectorizing?");
            dty := type_vector(s.vf.n, vp_scalar_type(vr(r).def), s.vf.scalable);
            a := vs_get(s, vp_op(r, 0));
            c := irb_cast(*s.b, vp_ir_opcode(vr(r).opcode), a, dty);
            vs_set(s, vr(r).def, c);
            if is_inst(c) && c != a { vp_apply_flags(r, c); vp_apply_metadata(r, c); }
        case .WIDEN_GEP;
            assert(ec_is_vector(s.vf), "not widening");
            ops: [..] Value_Id; ops.allocator = temp;
            for vr(r).ops array_add(*ops, vs_get(s, it, vp_is_single_scalar(it)));
            g := irb_gep(*s.b, vr(r).src_elt_ty, ops[0], array_view(ops, 1), "wide.gep", vr(r).flags.gep);
            vs_set(s, vr(r).def, g, vp_is_single_scalar(vr(r).def));
        case .VECTOR_POINTER;
            assert(vp_nops(r) > 2, "Expected prior simplification of recipe without VFxPart");
            p := vs_get_lane(s, vp_op(r, 0), 0);
            off := vs_get(s, vp_op(r, 2), true);
            if !vpm_one(vp_op(r, 1)) {
                st := vs_get(s, vp_op(r, 1), true);
                st = irb_zext_or_trunc(*s.b, st, vtype(off));
                off = vs_binop(s, .MUL, off, st);
            }
            g := irb_gep(*s.b, vr(r).src_elt_ty, p, .[off], "", vr(r).flags.gep);
            vs_set(s, vr(r).def, g, true);
        case .VECTOR_END_POINTER;
            assert(vp_nops(r) == 3, "Expected prior materialization of offset");
            p := vs_get(s, vp_op(r, 0), true);
            off := vs_get(s, vp_op(r, 2), true);
            g := irb_gep(*s.b, vr(r).src_elt_ty, p, .[off], "", vr(r).flags.gep);
            vs_set(s, vr(r).def, g, true);
        case .SCALAR_IV_STEPS; vp_scalar_iv_steps_execute(s, r);
        case .REPLICATE; vp_replicate_execute(s, r);
        case .WIDEN_INTRINSIC; vp_widen_intrinsic_execute(s, r);
        case .INTERLEAVE; vp_interleave_execute(s, r);
        case .WIDEN_LOAD;
            sty := vp_scalar_type(vr(r).def);
            dty := type_vector(s.vf.n, sty, s.vf.scalable);
            gather := !vr(r).consecutive;
            mask: Value_Id = NONE;
            if vr(r).masked mask = vs_get(s, vp_op(r, vp_nops(r) - 1));
            addr := vs_get(s, vp_op(r, 0), !gather);
            ld: Value_Id;
            if gather {
                if mask == NONE mask = const_all_ones_of(type_vector(s.vf.n, type_int(1), s.vf.scalable));
                f := get_or_insert_intrinsic_declaration(iidn("llvm.masked.gather"), .[dty, vtype(addr)]);
                ld = irb_call(*s.b, f, .[addr, mask, const_poison(dty)], "wide.masked.gather");
                add_param_align(ld, 0, vr(r).align);
            } else if mask != NONE {
                f := get_or_insert_intrinsic_declaration(iidn("llvm.masked.load"), .[dty, vtype(addr)]);
                ld = irb_call(*s.b, f, .[addr, mask, const_poison(dty)], "wide.masked.load");
                add_param_align(ld, 0, vr(r).align);
            } else ld = irb_load(*s.b, dty, addr, vr(r).align, false, "wide.load");
            vp_apply_metadata(r, ld);
            vs_set(s, vr(r).def, ld);
        case .WIDEN_STORE;
            gather := !vr(r).consecutive;
            mask: Value_Id = NONE;
            if vr(r).masked mask = vs_get(s, vp_op(r, vp_nops(r) - 1));
            val := vs_get(s, vp_op(r, 1));
            addr := vs_get(s, vp_op(r, 0), !gather);
            st: Value_Id;
            if gather {
                if mask == NONE mask = const_all_ones_of(type_vector(s.vf.n, type_int(1), s.vf.scalable));
                f := get_or_insert_intrinsic_declaration(iidn("llvm.masked.scatter"), .[vtype(val), vtype(addr)]);
                st = irb_call(*s.b, f, .[val, addr, mask]);
                add_param_align(st, 1, vr(r).align);
            } else if mask != NONE {
                f := get_or_insert_intrinsic_declaration(iidn("llvm.masked.store"), .[vtype(val), vtype(addr)]);
                st = irb_call(*s.b, f, .[val, addr, mask]);
                add_param_align(st, 1, vr(r).align);
            } else st = irb_store(*s.b, val, addr, vr(r).align);
            vp_apply_metadata(r, st);
        case .WIDEN_PHI; vs_execute_phi(s, r, false, vr(r).name);
        case .FIRST_ORDER_RECURRENCE_PHI;
            init := vp_ir(vp_op(r, 0));
            vty := ifx ec_is_scalar(s.vf) then vtype(init) else type_vector(s.vf.n, vtype(init), s.vf.scalable);
            _, vector_ph := table_find(*s.vpbb2irbb, vp_cfg_predecessor(vr(r).parent, 0));
            if ec_is_vector(s.vf) {
                saved := s.b;
                irb_set_before(*s.b, block_terminator(vector_ph));
                last := const_int(ir.t_i32, s.vf.n - 1);
                init = vs_insert_element(s, const_poison(vty), init, last, "vector.recur.init");
                s.b = saved;
            }
            header := s.prev_bb;
            phi := create_phi(vty, 2);
            insert_at_position(phi, header, block_first_insertion_pt(header), false);
            set_name(phi, "vector.recur");
            phi_add_incoming(phi, init, vector_ph);
            vs_set(s, vr(r).def, phi);
        case .REDUCTION_PHI;
            _, vector_ph := table_find(*s.vpbb2irbb, vp_cfg_predecessor(vr(r).parent, 0));
            scalar_phi := ec_is_scalar(s.vf) || vr(r).rdx_style != .UNORDERED;
            start := vs_get(s, vp_op(r, 0), scalar_phi);
            header := s.prev_bb;
            phi := create_phi(vtype(start), 2);
            insert_at_position(phi, header, block_first_insertion_pt(header), false);
            set_name(phi, "vec.phi");
            vs_set(s, vr(r).def, phi, vr(r).rdx_style != .UNORDERED);
            phi_add_incoming(phi, start, vector_ph);
        case;
            vp_unported(tprint("executing % recipes", k));
    }
}

// ---------------------------------------------------------------- blocks

// VPBlockBase::getHierarchicalSuccessors
vp_hierarchical_successors :: (b: Vp_Blk) -> [] Vp_Blk { return vb(vp_enclosing_block_with_succs(b)).succs; }

// VPBasicBlock::connectToPredecessors
vs_connect_to_predecessors :: (s: *Vp_State, vpbb: Vp_Blk) {
    _, new_bb := table_find(*s.vpbb2irbb, vpbb);
    parent_loop := s.cur_parent_loop;
    soe := vp_single_succ(vpbb);
    if soe == NONE soe = vpbb;
    if vp_is_exit_block(soe) parent_loop = li_loop_for(s.li, vb(soe).irbb);
    if parent_loop != NONE && li_loop_for(s.li, new_bb) == NONE li_add_basic_block_to_loop(s.li, parent_loop, new_bb);
    preds: [..] Vp_Blk; preds.allocator = temp;
    if vpbu_is_header(vpbb, *s.vpdt) array_add(*preds, vb(vpbb).preds[0]);
    else for vb(vpbb).preds array_add(*preds, it);
    for p: preds {
        pvpbb := vp_exiting_basic_block(p);
        psuccs := vp_hierarchical_successors(pvpbb);
        found, pbb := table_find(*s.vpbb2irbb, pvpbb);
        assert(found, "Predecessor basic-block not found building successor.");
        t := block_terminator(pbb);
        if inst_op(t) == .UNREACHABLE {
            dl := get_metadata(t, 0);
            erase_inst(t);
            br := create_br(new_bb);
            block_append_inst(pbb, br);
            if dl != NONE set_metadata(br, 0, dl);
        } else if inst_op(t) == .BR {
            set_successor(t, 0, new_bb);
        } else {
            idx: u32 = ifx psuccs[0] == vpbb then cast(u32) 0 else 1;
            set_successor(t, idx, new_bb);
        }
        dtu_apply1(*s.dtu, true, pbb, new_bb);
    }
}

// VPIRBasicBlock::execute
vs_execute_ir_block :: (s: *Vp_State, b: Vp_Blk) {
    irbb := vb(b).irbb;
    if !block_has_predecessors(irbb) && block_num_successors(irbb) == 0 block_move_after(irbb, s.prev_bb);
    irb_set_before(*s.b, block_terminator(irbb));
    s.prev_bb = irbb;
    table_set(*s.vpbb2irbb, b, irbb);
    vs_execute_recipes(s, b);
    t := block_terminator(irbb);
    if vp_single_succ(b) != NONE && inst_op(t) == .UNREACHABLE {
        br := irb_insert(*s.b, create_br(irbb));
        set_op(br, 0, NONE);
        erase_inst(block_terminator(irbb));
    }
    vs_connect_to_predecessors(s, b);
}
// BasicBlock::moveAfter
block_move_after :: (b: Value_Id, pos: Value_Id) {
    f := block_fn(b);
    fn_unlink_block(f, b);
    fn_insert_block_after(f, pos, b);
}

// VPBasicBlock::execute
vs_execute_basic_block :: (s: *Vp_State, b: Vp_Blk) {
    if vpbu_is_header(b, *s.vpdt) {
        prev := s.cur_parent_loop;
        s.cur_parent_loop = li_alloc_loop(s.li);
        if prev != NONE li_add_child_loop(s.li, prev, s.cur_parent_loop);
        else li_add_top_level_loop(s.li, s.cur_parent_loop);
    }
    new_bb := create_block(s.f, vb(b).name, s.exit_bb);
    irb_set_end(*s.b, new_bb);
    term := irb_insert(*s.b, new_inst(.UNREACHABLE, ir.t_void, 0));
    irb_set_before(*s.b, term);
    s.prev_bb = new_bb;
    table_set(*s.vpbb2irbb, b, new_bb);
    vs_connect_to_predecessors(s, b);
    vs_execute_recipes(s, b);
    if vpbu_is_latch(b, *s.vpdt) s.cur_parent_loop = li_parent(s.li, s.cur_parent_loop);
}

// VPBasicBlock::executeRecipes
vs_execute_recipes :: (s: *Vp_State, b: Vp_Blk) {
    s.prev_vpbb = b;
    r := vb(b).first;
    while r != NONE {
        // setDebugLocFrom
        if vr(r).dl != NONE && get_metadata(s.f, 0) != NONE && module_debug_info_for_profiling()
            vp_unported("discriminators for debug-info-for-profiling (cloneByMultiplyingDuplicationFactor)");
        s.b.dbg = vr(r).dl;
        vp_execute_recipe(s, r);
        r = vr(r).next;
    }
}

// VPlan::execute
vp_execute_plan :: (s: *Vp_State) {
    for vp_depth_first_shallow(vpl.entry) assert(!vp_is_region(it), "all region blocks must be dissolved before ::execute");
    s.prev_vpbb = NONE;
    s.exit_bb = block_get_single_successor(s.prev_bb);
    s.vpdt = vp_dt_build();
    vector_ph := s.prev_bb;
    set_successor(block_terminator(vector_ph), 0, NONE);
    dtu_apply1(*s.dtu, false, vector_ph, s.exit_bb);
    vpl.name = "Final VPlan";
    vp_print_plan("execute");
    scalar_ph := s.exit_bb;
    sph := vp_scalar_preheader();
    if sph != NONE dtu_apply1(*s.dtu, false, scalar_ph, block_get_single_successor(scalar_ph));
    rpo := vp_rpo(vpl.entry, false);
    for b: rpo {
        if vp_is_ir_basic(b) vs_execute_ir_block(s, b);
        else vs_execute_basic_block(s, b);
    }
    if vp_has_early_exit() vp_unported("LoopInfo updates for early-exit dispatch blocks");
    if sph == NONE {
        // the original loop is unreachable: delete it and all its blocks
        for eb: vpl.exit_blocks for r: vp_block_phis(eb) if vp_nops(r) == 1 vp_erase_recipe(r);
        orig := li_loop_for(s.li, vb(vpl.scalar_header).irbb);
        blocks: [..] Value_Id; blocks.allocator = temp;
        for li_blocks(s.li, orig) array_add(*blocks, it);
        array_add(*blocks, scalar_ph);
        while !li_is_innermost(s.li, orig) li_erase(s.li, li_subloops(s.li, orig)[0]);
        li_erase(s.li, orig);
        for blocks li_remove_block(s.li, it);
        delete_dead_blocks(blocks, *s.dtu);
    }
    dtu_flush(*s.dtu);
    for vpb: vp_depth_first_shallow(vpl.entry) {
        if !vpbu_is_header(vpb, *s.vpdt) continue;
        latch := vb(vpb).preds[1];
        _, latch_bb := table_find(*s.vpbb2irbb, latch);
        for r: vp_block_phis(vpb) {
            needs_scalar := vp_is_vp_phi(r) || (vr(r).kind == .REDUCTION_PHI && vr(r).rdx_style != .UNORDERED);
            phi := vs_get(s, vr(r).def, needs_scalar);
            val := vs_get(s, vp_op(r, 1), needs_scalar);
            phi_add_incoming(phi, val, latch_bb);
        }
    }
}

// isVectorIntrinsicWithOverloadTypeAtArg (VectorUtils.cpp; idx -1 is the return type; no target intrinsics here)
is_vector_intrinsic_with_overload_type_at_arg :: (id: Intrinsic_Id, idx: s64) -> bool {
    n := intrinsic_name(id);
    if begins_with(n, "llvm.x86.") vp_unported(tprint("target intrinsic % (isTargetIntrinsicWithOverloadTypeAtArg)", n));
    if begins_with(n, "llvm.vp.") vp_unported(tprint("VP intrinsic % in isVectorIntrinsicWithOverloadTypeAtArg", n));
    if n == "llvm.fptosi.sat" || n == "llvm.fptoui.sat" || n == "llvm.lround" || n == "llvm.llround" || n == "llvm.lrint" ||
       n == "llvm.llrint" || n == "llvm.ucmp" || n == "llvm.scmp" || n == "llvm.vector.extract" || n == "llvm.loop.dependence.war.mask"
        return idx == -1 || idx == 0;
    if n == "llvm.modf" || n == "llvm.sincos" || n == "llvm.sincospi" || n == "llvm.is.fpclass" return idx == 0;
    if n == "llvm.powi" || n == "llvm.ldexp" return idx == -1 || idx == 1;
    return idx == -1;
}
// VPWidenIntrinsicRecipe::execute (createVectorCall)
vp_widen_intrinsic_execute :: (s: *Vp_State, r: Vp_Rec) {
    id := vr(r).iid;
    tys: [..] Type_Id; tys.allocator = temp;
    sty := vp_scalar_type(vr(r).def);
    if is_vector_intrinsic_with_overload_type_at_arg(id, -1) {
        if type_kind(sty) == .STRUCT vp_unported("struct-returning vector intrinsics");
        array_add(*tys, lv_to_vectorized_ty(sty, s.vf));
    }
    args: [..] Value_Id; args.allocator = temp;
    for o, k: vr(r).ops {
        a: Value_Id;
        if is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) k) a = vs_get_lane(s, o, 0);
        else a = vs_get(s, o, vp_uses_first_lane_only(r, o));
        if is_vector_intrinsic_with_overload_type_at_arg(id, k) array_add(*tys, vtype(a));
        array_add(*args, a);
    }
    f := get_or_insert_intrinsic_declaration(id, tys);
    ci := vp_uv(vr(r).def);
    if ci != NONE && is_inst(ci) && call_num_bundles(ci) > 0 vp_unported("operand bundles on widened intrinsic calls");
    v := irb_call(*s.b, f, args);
    if is_fp_math_operator(v) set_fmf(v, s.fmf);
    vp_apply_flags(r, v);
    vp_apply_metadata(r, v);
    if type_kind(vtype(v)) != .VOID vs_set(s, vr(r).def, v);
}
