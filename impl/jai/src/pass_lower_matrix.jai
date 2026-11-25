// LowerMatrixIntrinsicsPass (lower-matrix-intrinsics, lower-matrix-intrinsics<minimal>): a port of
// llvm/lib/Transforms/Scalar/LowerMatrixIntrinsics.cpp and TileInfo (llvm/lib/Transforms/Utils/MatrixUtils.cpp),
// with the MatrixBuilder calls it makes (llvm/include/llvm/IR/MatrixBuilder.h).
//
// Not ported: the optimization remarks (RemarkGenerator / ExprLinearizer, and the OpInfoTy counters that only feed
// them): they print only with -pass-remarks*, which our opt rejects. -matrix-print-after-transpose-opt fails loudly.
//
// Data: ShapeMap and Inst2ColumnMatrix are Tables keyed by Value_Id (LLVM only looks them up; the MapVector order
// of Inst2ColumnMatrix only matters for the remarks). A MatrixTy is `Lm_Mat` (its vectors; the layout is the global
// -matrix-default-layout, like every MatrixTy/ShapeInfo constructor in LLVM). FusedInsts and the other pointer sets
// are only queried, never iterated, so no address order leaks into the output.

lm_cl: struct {
    fuse := true;                     // -fuse-matrix
    tile_size: u32 = 4;               // -fuse-matrix-tile-size
    loops_threshold: u32 = 200;       // -fuse-matrix-loops-threshold
    force_fuse := false;              // -force-fuse-matrix
    allow_contract := false;          // -matrix-allow-contract
    verify_shapes := false;           // -verify-matrix-shapes
    row_major := false;               // -matrix-default-layout=row-major
    print_after_transpose := false;   // -matrix-print-after-transpose-opt
    split_remainder_over: u32 = 0;    // -matrix-split-matmul-remainder-over-threshold
};

lm_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "fuse-matrix"; lm_cl.fuse = smisc_bool(name, value, has_value);
        case "fuse-matrix-tile-size"; lm_cl.tile_size = cast(u32) smisc_int(name, value, has_value);
        case "fuse-matrix-loops-threshold"; lm_cl.loops_threshold = cast(u32) smisc_int(name, value, has_value);
        case "force-fuse-matrix"; lm_cl.force_fuse = smisc_bool(name, value, has_value);
        case "matrix-allow-contract"; lm_cl.allow_contract = smisc_bool(name, value, has_value);
        case "verify-matrix-shapes"; lm_cl.verify_shapes = smisc_bool(name, value, has_value);
        case "matrix-print-after-transpose-opt"; lm_cl.print_after_transpose = smisc_bool(name, value, has_value);
        case "matrix-split-matmul-remainder-over-threshold"; lm_cl.split_remainder_over = cast(u32) smisc_int(name, value, has_value);
        case "matrix-default-layout";
            if value == {
                case "column-major"; lm_cl.row_major = false;
                case "row-major"; lm_cl.row_major = true;
                case; fatal("opt: for the --matrix-default-layout option: Cannot find option named '%'!", value);
            }
        case; return false;
    }
    return true;
}

IID_MATRIX_TRANSPOSE :: #run iid_by_name("llvm.matrix.transpose");

lm_col_major :: inline () -> bool { return !lm_cl.row_major; }

// ShapeInfo
Lm_Shape :: struct { rows: u32; cols: u32; }
lm_shape_stride :: (s: Lm_Shape) -> u32 { return ifx lm_col_major() then s.rows else s.cols; }
lm_shape_num_vectors :: (s: Lm_Shape) -> u32 { return ifx lm_col_major() then s.cols else s.rows; }
lm_shape_t :: (s: Lm_Shape) -> Lm_Shape { return .{s.cols, s.rows}; }
// ShapeInfo(Value *NumRows, Value *NumColumns)
lm_shape_v :: (r: Value_Id, c: Value_Id) -> Lm_Shape {
    if vkind(r) != .C_INT || vkind(c) != .C_INT fatal("lower-matrix-intrinsics: matrix dimensions must be constant integers");
    return .{cast(u32) const_int_zext(r), cast(u32) const_int_zext(c)};
}

// MatrixTy
Lm_Mat :: struct { v: [..] Value_Id; }
lm_mat_new :: () -> Lm_Mat { m: Lm_Mat; m.v.allocator = temp; return m; }
lm_mat_copy :: (m: Lm_Mat) -> Lm_Mat { r := lm_mat_new(); for m.v array_add(*r.v, it); return r; }
// MatrixTy(NumRows, NumColumns, EltTy): poison vectors
lm_mat_poison :: (rows: u32, cols: u32, elt: Type_Id) -> Lm_Mat {
    m := lm_mat_new();
    d := ifx lm_col_major() then cols else rows;
    vt := type_vector(ifx lm_col_major() then rows else cols, elt, false);
    for 1..d array_add(*m.v, const_poison(vt));
    return m;
}
lm_mat_vec_ty :: (m: Lm_Mat) -> Type_Id { return vtype(m.v[0]); }
lm_mat_elt :: (m: Lm_Mat) -> Type_Id { return type_elem(vtype(m.v[0])); }
lm_mat_rows :: (m: Lm_Mat) -> u32 {
    if lm_col_major() return cast(u32) type_count(vtype(m.v[0]));
    return cast(u32) m.v.count;
}
lm_mat_cols :: (m: Lm_Mat) -> u32 {
    if lm_col_major() return cast(u32) m.v.count;
    return cast(u32) type_count(vtype(m.v[0]));
}
lm_mat_stride :: (m: Lm_Mat) -> u32 { return ifx lm_col_major() then lm_mat_rows(m) else lm_mat_cols(m); }
// embedInVector
lm_embed :: (m: Lm_Mat, b: *Irb) -> Value_Id {
    if m.v.count == 1 return m.v[0];
    return xia_concatenate_vectors(b, m.v);
}
// createSequentialMask as a ShuffleVector mask
lm_seq_mask :: (start: u32, n: u32, undefs: u32) -> [] u32 {
    m := NewArray(n + undefs, u32,, allocator = temp);
    for i: 0..cast(s64) n - 1 m[i] = start + cast(u32) i;
    for i: 0..cast(s64) undefs - 1 m[n + i] = 0xFFFF_FFFF;
    return m;
}
// extractVector(I, J, NumElts)
lm_extract_vector :: (m: Lm_Mat, i: u32, j: u32, num: u32, b: *Irb) -> Value_Id {
    vec := ifx lm_col_major() then m.v[j] else m.v[i];
    return irb_shuffle(b, vec, NONE, lm_seq_mask(ifx lm_col_major() then i else j, num, 0), "block");
}

Lm :: struct {
    f: Value_Id;
    tti: *Tti;
    use_am: bool;          // AM != nullptr (not <minimal>)
    dt: *Dom_Tree;         // null = isMinimal()
    li: *Loop_Info;
    aar: Aa_Results;
    shape: Table(Value_Id, Lm_Shape);   // ShapeMap
    to_remove: [..] Value_Id;
    i2m: Table(Value_Id, Lm_Mat);      // Inst2ColumnMatrix
    fused: Table(Value_Id, bool);      // FusedInsts
    lifetime_ends: [..] Value_Id;
}

lm_has_shape :: (s: *Lm, v: Value_Id) -> bool { return table_contains(*s.shape, v); }

// getFastMathFlags
lm_fmf :: (i: Value_Id) -> u32 {
    fmf: u32 = 0;
    if is_fp_math_inst(i) fmf = inst_fmf(i);
    if lm_cl.allow_contract fmf |= FMF_CONTRACT;
    return fmf;
}

// TTI.getRegisterBitWidth(RGK_FixedWidthVector)
lm_reg_bits :: (s: *Lm) -> u64 { return tti_register_bit_width(s.tti, RGK_FIXED_WIDTH_VECTOR); }
lm_elt_bits :: (t: Type_Id) -> u64 {
    b := type_bits(t);
    if b == 0 fatal("lower-matrix-intrinsics: matrices of '%' elements are not supported", type_to_string(t));
    return b;
}
// getNumOps(ST, N)
lm_num_ops :: (s: *Lm, st: Type_Id, n: u32) -> u32 {
    w := lm_reg_bits(s);
    return cast(u32) ((cast(u64) type_bits(st) * n + w - 1) / w);
}
// getNumNativeVectorOps
lm_num_native_vector_ops :: (s: *Lm, elt: Type_Id, r: u32, m: u32, c: u32) -> u32 {
    fmas := c * lm_num_ops(s, elt, r) * m;
    aloads := lm_num_ops(s, elt, r) * m;
    bloads := lm_num_ops(s, elt, m) * c;
    stores := lm_num_ops(s, elt, r) * c;
    return fmas + aloads + bloads + stores;
}

lm_cost_sub :: (a: Cost, b: Cost) -> Cost { if !cost_valid(a) || !cost_valid(b) return COST_INVALID; return a - b; }

// computeVectorAddr
lm_compute_vector_addr :: (base: Value_Id, vec_idx: Value_Id, stride: Value_Id, num: u32, elt: Type_Id, b: *Irb) -> Value_Id {
    start := irb_binop(b, .MUL, vec_idx, stride, "vec.start");
    if vkind(start) == .C_INT && const_int_zext(start) == 0 return base;
    return irb_gep(b, elt, base, .[start], "vec.gep", F_INBOUNDS);
}

// isShapePreserving
lm_is_shape_preserving :: (v: Value_Id) -> bool {
    if !is_inst(v) return true;
    o := inst_op(v);
    if o == .SELECT return true;
    if is_binary_op(o) return true;
    if is_cast_op(o) {
        if o == {
            case .TRUNC; #through; case .ZEXT; #through; case .SEXT; #through; case .FPTOUI; #through;
            case .FPTOSI; #through; case .UITOFP; #through; case .SITOFP; #through; case .FPTRUNC; #through;
            case .FPEXT; return true;
            case .BITCAST;
                st := vtype(op(v, 0)); dt := vtype(v);
                if type_kind(st) == .VECTOR && type_kind(dt) == .VECTOR return type_count(st) == type_count(dt);
                return false;
        }
        return false;
    }
    id := call_iid(v);
    if id != NOT_INTRINSIC return id == IID_ABS || id == IID_FABS;
    return o == .PHI || o == .FNEG;
}
// getShapedOperandsForInst: the first operand index (selects skip the condition)
lm_first_shaped_op :: (i: Value_Id) -> u32 { return ifx inst_op(i) == .SELECT then cast(u32) 1 else 0; }

lm_is_matrix_iid :: (id: Intrinsic_Id) -> bool {
    return id == IID_MATRIX_MULTIPLY || id == IID_MATRIX_TRANSPOSE || id == IID_MATRIX_COLUMN_MAJOR_LOAD || id == IID_MATRIX_COLUMN_MAJOR_STORE;
}

// computeShapeInfoForInst
lm_compute_shape :: (s: *Lm, i: Value_Id) -> (bool, Lm_Shape) {
    id := call_iid(i);
    if id == IID_MATRIX_MULTIPLY return true, lm_shape_v(call_arg(i, 2), call_arg(i, 4));
    if id == IID_MATRIX_TRANSPOSE return true, lm_shape_v(call_arg(i, 2), call_arg(i, 1));
    if id == IID_MATRIX_COLUMN_MAJOR_STORE return true, lm_shape_v(call_arg(i, 5), call_arg(i, 4));
    if id == IID_MATRIX_COLUMN_MAJOR_LOAD return true, lm_shape_v(call_arg(i, 3), call_arg(i, 4));
    if inst_op(i) == .STORE {
        found, sh := table_find(*s.shape, op(i, 0));
        if found return true, sh;
    }
    if lm_is_shape_preserving(i) {
        n := lm_operand_count(i);
        k := lm_first_shaped_op(i);
        while k < n {
            found, sh := table_find(*s.shape, op(i, k));
            if found return true, sh;
            k += 1;
        }
    }
    return false, .{};
}
// I->operands(): for calls this includes the callee (it never has a shape)
lm_operand_count :: (i: Value_Id) -> u32 { return nops(i); }

// supportsShapeInfo
lm_supports_shape :: (v: Value_Id) -> bool {
    if !is_inst(v) return false;
    if lm_is_matrix_iid(call_iid(v)) return true;
    o := inst_op(v);
    return lm_is_shape_preserving(v) || o == .STORE || o == .LOAD;
}

// setShapeInfo
lm_set_shape :: (s: *Lm, v: Value_Id, sh: Lm_Shape) -> bool {
    k := vkind(v);
    if k == .C_UNDEF || k == .C_POISON || !lm_supports_shape(v) return false;
    found, old := table_find(*s.shape, v);
    if found {
        if lm_cl.verify_shapes && (old.rows != sh.rows || old.cols != sh.cols)
            fatal("Conflicting shapes (%x% vs %x%) for %\nLLVM ERROR: Matrix shape verification failed, compilation aborted!",
                  old.rows, old.cols, sh.rows, sh.cols, inst_to_string(v));
        return false;
    }
    table_set(*s.shape, v, sh);
    return true;
}

// propagateShapeForward
lm_propagate_forward :: (s: *Lm, wl: *[..] Value_Id) -> [..] Value_Id {
    nw: [..] Value_Id; nw.allocator = temp;
    while wl.count {
        i := wl.*[wl.count - 1]; wl.count -= 1;
        prop := false;
        ok, sh := lm_compute_shape(s, i);
        if ok prop = lm_set_shape(s, i, sh);
        if prop {
            array_add(*nw, i);
            u := ir.v_first_use[i];
            while u != NONE {
                user := ir.u_user[u];
                if !lm_has_shape(s, user) array_add(wl, user);
                u = ir.u_next[u];
            }
        }
    }
    return nw;
}

// propagateShapeBackward
lm_propagate_backward :: (s: *Lm, wl: *[..] Value_Id) -> [..] Value_Id {
    nw: [..] Value_Id; nw.allocator = temp;
    push :: (wl: *[..] Value_Id, v: Value_Id) { if is_inst(v) array_add(wl, v); }
    while wl.count {
        v := wl.*[wl.count - 1]; wl.count -= 1;
        before := wl.count;
        if !is_inst(v) continue;
        id := call_iid(v);
        o := inst_op(v);
        if id == IID_MATRIX_MULTIPLY {
            a := call_arg(v, 0); b := call_arg(v, 1);
            m := call_arg(v, 2); n := call_arg(v, 3); k := call_arg(v, 4);
            if lm_set_shape(s, a, lm_shape_v(m, n)) push(wl, a);
            if lm_set_shape(s, b, lm_shape_v(n, k)) push(wl, b);
        } else if id == IID_MATRIX_TRANSPOSE {
            a := call_arg(v, 0);
            if lm_set_shape(s, a, lm_shape_v(call_arg(v, 1), call_arg(v, 2))) push(wl, a);
        } else if id == IID_MATRIX_COLUMN_MAJOR_STORE {
            a := call_arg(v, 0);
            if lm_set_shape(s, a, lm_shape_v(call_arg(v, 4), call_arg(v, 5))) push(wl, a);
        } else if o == .LOAD || id == IID_MATRIX_COLUMN_MAJOR_LOAD {
        } else if o == .STORE {
        } else if lm_is_shape_preserving(v) {
            _, sh := table_find(*s.shape, v);   // ShapeMap[V] (default-constructs a 0x0 shape if missing)
            if !lm_has_shape(s, v) fatal("internal: lower-matrix-intrinsics: backward propagation from an instruction without a shape");
            n := lm_operand_count(v);
            k := lm_first_shaped_op(v);
            while k < n {
                x := op(v, k);
                if lm_set_shape(s, x, sh) push(wl, x);
                k += 1;
            }
        }
        for idx: before..wl.count - 1 {
            u := ir.v_first_use[wl.*[idx]];
            while u != NONE {
                user := ir.u_user[u];
                if is_inst(user) && user != v array_add(*nw, user);
                u = ir.u_next[u];
            }
        }
    }
    return nw;
}

// ---------------------------------------------------------------- MatrixBuilder

// CreateMatrixTranspose(Matrix, Rows, Columns, Name)
lm_create_transpose :: (b: *Irb, m: Value_Id, rows: u32, cols: u32, name := "") -> Value_Id {
    rt := type_vector(rows * cols, type_elem(vtype(m)), false);
    f := get_or_insert_intrinsic_declaration(IID_MATRIX_TRANSPOSE, .[rt]);
    return irb_call(b, f, .[m, const_int(ir.t_i32, rows), const_int(ir.t_i32, cols)], name);
}
// CreateMatrixMultiply(LHS, RHS, LHSRows, LHSColumns, RHSColumns, Name)
lm_create_multiply :: (b: *Irb, l: Value_Id, r: Value_Id, lrows: u32, lcols: u32, rcols: u32, name := "") -> Value_Id {
    rt := type_vector(lrows * rcols, type_elem(vtype(l)), false);
    f := get_or_insert_intrinsic_declaration(IID_MATRIX_MULTIPLY, .[rt, vtype(l), vtype(r)]);
    return irb_call(b, f, .[l, r, const_int(ir.t_i32, lrows), const_int(ir.t_i32, lcols), const_int(ir.t_i32, rcols)], name);
}
// Twine(V->getName()) + Suffix
lm_name_plus :: (v: Value_Id, suffix: string) -> string { return tconcat(vname(v), suffix); }

// ---------------------------------------------------------------- transpose optimizations

// eraseFromParentAndRemoveFromShapeMap
lm_erase :: (s: *Lm, i: Value_Id) {
    table_remove(*s.shape, i);
    erase_inst_with_metadata(i);
}
// eraseFromParentAndMove: `ii` is the reverse iterator (NONE = rend)
lm_erase_and_move :: (s: *Lm, v: Value_Id, ii: *Value_Id) {
    if has_uses(v) return;
    if ii.* != NONE && v == ii.* ii.* = inst_prev(ii.*);
    lm_erase(s, v);
}
// updateShapeAndReplaceAllUsesWith
lm_update_shape_and_rauw :: (s: *Lm, old: Value_Id, new: Value_Id) {
    found, sh := table_find(*s.shape, old);
    if found {
        table_remove(*s.shape, old);
        if lm_supports_shape(new) && !lm_has_shape(s, new) table_set(*s.shape, new, sh);
    }
    rauw_with_metadata(old, new);
}

lm_is_splat :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .SHUFFLEVECTOR && sv_is_zero_elt_splat_i(v); }
lm_is_const_int :: (v: Value_Id) -> bool { return vkind(v) == .C_INT; }
lm_is_binop :: (v: Value_Id, o: Opcode) -> bool { return is_inst(v) && inst_op(v) == o; }

// sinkTranspose: returns the new instruction (NONE = none)
lm_sink_transpose :: (s: *Lm, i: Value_Id, ii: *Value_Id, changed: *bool) -> Value_Id {
    if call_iid(i) != IID_MATRIX_TRANSPOSE return NONE;
    ta := call_arg(i, 0); r := call_arg(i, 1); c := call_arg(i, 2);
    if !lm_is_const_int(r) || !lm_is_const_int(c) return NONE;
    b: Irb; irb_set_before(*b, i);

    // Transpose of a transpose is a nop when the shapes match.
    if call_iid(ta) == IID_MATRIX_TRANSPOSE && call_arg(ta, 1) == c && call_arg(ta, 2) == r {
        tata := call_arg(ta, 0);
        lm_update_shape_and_rauw(s, i, tata);
        lm_erase_and_move(s, i, ii);
        lm_erase_and_move(s, ta, ii);
        changed.* = true;
        return NONE;
    }
    // k^T -> k
    if lm_is_splat(ta) {
        lm_update_shape_and_rauw(s, i, ta);
        lm_erase_and_move(s, i, ii);
        changed.* = true;
        return NONE;
    }
    // (A * B)^t -> B^t * A^t
    if call_iid(ta) == IID_MATRIX_MULTIPLY && lm_is_const_int(call_arg(ta, 2)) && lm_is_const_int(call_arg(ta, 3)) && lm_is_const_int(call_arg(ta, 4)) {
        tama := call_arg(ta, 0); tamb := call_arg(ta, 1);
        // m_ConstantInt(R), m_ConstantInt(K), m_ConstantInt(C) rebind R and C to the multiply's dimensions
        rr := cast(u32) const_int_zext(call_arg(ta, 2));
        kk := cast(u32) const_int_zext(call_arg(ta, 3));
        cc := cast(u32) const_int_zext(call_arg(ta, 4));
        // distributeTransposes(TAMB, {K, C}, TAMA, {R, K})
        t0 := lm_create_transpose(*b, tamb, kk, cc, lm_name_plus(tamb, "_t"));
        lm_set_shape(s, t0, .{cc, kk});
        t1 := lm_create_transpose(*b, tama, rr, kk, lm_name_plus(tama, "_t"));
        lm_set_shape(s, t1, .{kk, rr});
        ni := lm_create_multiply(*b, t0, t1, cc, kk, rr, "mmul");
        lm_update_shape_and_rauw(s, i, ni);
        lm_erase_and_move(s, i, ii);
        lm_erase_and_move(s, ta, ii);
        changed.* = true;
        return ni;
    }
    rr := cast(u32) const_int_zext(r); cc := cast(u32) const_int_zext(c);
    is_fp := is_fp_type(scalar_type(vtype(i)));
    // (A * k)^t -> A^t * k
    if (lm_is_binop(ta, .MUL) || lm_is_binop(ta, .FMUL)) && (lm_is_splat(op(ta, 0)) || lm_is_splat(op(ta, 1))) {
        tama := op(ta, 0); tamb := op(ta, 1);
        t0 := lm_create_transpose(*b, tama, rr, cc, lm_name_plus(tama, "_t"));
        lm_set_shape(s, t0, .{cc, rr});
        t1 := lm_create_transpose(*b, tamb, rr, cc, lm_name_plus(tamb, "_t"));
        lm_set_shape(s, t1, .{cc, rr});
        lb: Irb; irb_set_before(*lb, i);
        ni := irb_binop(*lb, ifx is_fp then Opcode.FMUL else .MUL, t0, t1, "mmul");
        lm_set_shape(s, ni, .{cc, rr});
        lm_update_shape_and_rauw(s, i, ni);
        lm_erase_and_move(s, i, ii);
        lm_erase_and_move(s, ta, ii);
        changed.* = true;
        return ni;
    }
    // (A + B)^t -> A^t + B^t
    if lm_is_binop(ta, .ADD) || lm_is_binop(ta, .FADD) {
        tama := op(ta, 0); tamb := op(ta, 1);
        t0 := lm_create_transpose(*b, tama, rr, cc, lm_name_plus(tama, "_t"));
        lm_set_shape(s, t0, .{cc, rr});
        t1 := lm_create_transpose(*b, tamb, rr, cc, lm_name_plus(tamb, "_t"));
        lm_set_shape(s, t1, .{cc, rr});
        lb: Irb; irb_set_before(*lb, i);
        ni := irb_binop(*lb, ifx is_fp then Opcode.FADD else .ADD, t0, t1, "madd");
        lm_set_shape(s, ni, .{cc, rr});
        lm_update_shape_and_rauw(s, i, ni);
        lm_erase_and_move(s, i, ii);
        lm_erase_and_move(s, ta, ii);
        changed.* = true;
        return ni;
    }
    return NONE;
}

// liftTranspose
lm_lift_transpose :: (s: *Lm, i: Value_Id) -> bool {
    cleanup :: (s: *Lm, t: Value_Id, a: Value_Id, b: Value_Id) {
        if !has_uses(t) lm_erase(s, t);
        if !has_uses(a) lm_erase(s, a);
        if a != b && !has_uses(b) lm_erase(s, b);
    }
    // A^t * B ^t -> (B * A)^t
    if call_iid(i) == IID_MATRIX_MULTIPLY && lm_is_const_int(call_arg(i, 2)) && lm_is_const_int(call_arg(i, 3)) && lm_is_const_int(call_arg(i, 4)) &&
       call_iid(call_arg(i, 0)) == IID_MATRIX_TRANSPOSE && call_iid(call_arg(i, 1)) == IID_MATRIX_TRANSPOSE {
        a := call_arg(i, 0); bb := call_arg(i, 1);
        at := call_arg(a, 0); bt := call_arg(bb, 0);
        r := cast(u32) const_int_zext(call_arg(i, 2)); k := cast(u32) const_int_zext(call_arg(i, 3)); c := cast(u32) const_int_zext(call_arg(i, 4));
        b: Irb; irb_set_before(*b, i);
        m := lm_create_multiply(*b, bt, at, c, k, r);
        lm_set_shape(s, m, .{c, r});
        ni := lm_create_transpose(*b, m, c, r);
        lm_update_shape_and_rauw(s, i, ni);
        cleanup(s, i, a, bb);
        return true;
    }
    // A^t + B ^t -> (A + B)^t
    if lm_is_binop(i, .FADD) {
        a := op(i, 0); bb := op(i, 1);
        if call_iid(a) == IID_MATRIX_TRANSPOSE && lm_is_const_int(call_arg(a, 1)) && lm_is_const_int(call_arg(a, 2)) &&
           call_iid(bb) == IID_MATRIX_TRANSPOSE && lm_is_const_int(call_arg(bb, 1)) && lm_is_const_int(call_arg(bb, 2)) {
            at := call_arg(a, 0); bt := call_arg(bb, 0);
            r := cast(u32) const_int_zext(call_arg(a, 1)); c := cast(u32) const_int_zext(call_arg(a, 2));
            b: Irb; irb_set_before(*b, i);
            add := irb_binop(*b, .FADD, at, bt, "mfadd");
            ni := lm_create_transpose(*b, add, r, c, "mfadd_t");
            lm_update_shape_and_rauw(s, i, ni);
            cleanup(s, i, a, bb);
            if is_inst(add) lm_set_shape(s, add, .{r, c});
            return true;
        }
    }
    return false;
}

// optimizeTransposes
lm_optimize_transposes :: (s: *Lm) -> bool {
    changed := false;
    bb := glob(s.f).last_block;
    while bb != NONE {
        ii := block_last(bb);
        while ii != NONE {
            i := ii;
            ii = inst_prev(ii);
            ni := lm_sink_transpose(s, i, *ii, *changed);
            if ni != NONE ii = inst_prev(ni);
        }
        bb = block(bb).prev;
    }
    for bb: fn_blocks(s.f) for :early_inc i: block_insts(bb) {
        if lm_lift_transpose(s, i) changed = true;
    }
    return changed;
}

// ---------------------------------------------------------------- lowering helpers

// getMatrix
lm_get_matrix :: (s: *Lm, mv_in: Value_Id, si: Lm_Shape, b: *Irb) -> Lm_Mat {
    mv := mv_in;
    n := cast(u32) type_count(vtype(mv));
    found, m := table_find(*s.i2m, mv);
    if found {
        if si.rows == lm_mat_rows(m) && si.cols == lm_mat_cols(m) return lm_mat_copy(m);
        mv = lm_embed(m, b);
    }
    split := lm_mat_new();
    st := lm_shape_stride(si);
    start: u32 = 0;
    while start < n {
        array_add(*split.v, irb_shuffle(b, mv, NONE, lm_seq_mask(start, st, 0), "split"));
        start += st;
    }
    return split;
}

// getAlignForIndex
lm_align_for_index :: (idx: u32, stride: Value_Id, elt: Type_Id, a: u64) -> u64 {
    init := ifx a then a else dl_alignment(elt, true);
    if idx == 0 return init;
    bits := dl_type_size_bits(elt);
    if vkind(stride) == .C_INT {
        sb := const_int_zext(stride) * bits / 8;
        return common_alignment(init, idx * sb);
    }
    return common_alignment(init, bits / 8);
}
lm_index_type :: (ptr: Value_Id) -> Type_Id { return type_int(dl_index_type_size_bits(vtype(ptr))); }
lm_index :: (ptr: Value_Id, v: u64) -> Value_Id { return const_int(lm_index_type(ptr), v); }
// castToIndexType
lm_cast_to_index :: (ptr: Value_Id, v: Value_Id, b: *Irb) -> Value_Id {
    return irb_zext_or_trunc(b, v, lm_index_type(ptr), lm_name_plus(v, ".cast"));
}

// loadMatrix(Ty, Ptr, MAlign, Stride, IsVolatile, Shape)
lm_load_matrix :: (ty: Type_Id, ptr: Value_Id, align: u64, stride_in: Value_Id, volatile: bool, sh: Lm_Shape, b: *Irb) -> Lm_Mat {
    elt := type_elem(ty);
    vt := type_vector(lm_shape_stride(sh), elt, false);
    res := lm_mat_new();
    stride := lm_cast_to_index(ptr, stride_in, b);
    sbits := type_int_width(vtype(stride));
    for i: 0..cast(s64) lm_shape_num_vectors(sh) - 1 {
        gep := lm_compute_vector_addr(ptr, const_int(type_int(sbits), cast(u64) i), stride, lm_shape_stride(sh), elt, b);
        array_add(*res.v, irb_load(b, vt, gep, lm_align_for_index(cast(u32) i, stride, elt, align), volatile, "col.load"));
    }
    return res;
}
// loadMatrix(MatrixPtr, Align, IsVolatile, MatrixShape, I, J, ResultShape, EltTy)
lm_load_tile :: (mptr: Value_Id, align: u64, volatile: bool, msh: Lm_Shape, i: Value_Id, j: Value_Id, rsh: Lm_Shape, elt: Type_Id, b: *Irb) -> Lm_Mat {
    off := irb_binop(b, .ADD, irb_binop(b, .MUL, j, lm_index(mptr, lm_shape_stride(msh))), i);
    start := irb_gep(b, elt, mptr, .[off], "", F_INBOUNDS);
    tt := type_vector(rsh.rows * rsh.cols, elt, false);
    return lm_load_matrix(tt, start, align, lm_index(mptr, lm_shape_stride(msh)), volatile, rsh, b);
}
// storeMatrix(MatrixTy StoreVal, MatrixPtr, MAlign, IsVolatile, MatrixShape, I, J, EltTy)
lm_store_tile :: (val: Lm_Mat, mptr: Value_Id, align: u64, volatile: bool, msh: Lm_Shape, i: Value_Id, j: Value_Id, elt: Type_Id, b: *Irb) {
    off := irb_binop(b, .ADD, irb_binop(b, .MUL, j, lm_index(mptr, lm_shape_stride(msh))), i);
    start := irb_gep(b, elt, mptr, .[off], "", F_INBOUNDS);
    tt := type_vector(lm_mat_rows(val) * lm_mat_cols(val), elt, false);
    lm_store_matrix(tt, val, start, align, lm_index(mptr, lm_shape_stride(msh)), volatile, b);
}
// storeMatrix(Ty, StoreVal, Ptr, MAlign, Stride, IsVolatile)
lm_store_matrix :: (ty: Type_Id, val: Lm_Mat, ptr: Value_Id, align: u64, stride_in: Value_Id, volatile: bool, b: *Irb) {
    stride := lm_cast_to_index(ptr, stride_in, b);
    sbits := type_int_width(vtype(stride));
    elt := type_elem(ty);
    for vec, idx: val.v {
        gep := lm_compute_vector_addr(ptr, const_int(type_int(sbits), cast(u64) idx), stride, lm_mat_stride(val), elt, b);
        irb_store(b, vec, gep, lm_align_for_index(cast(u32) idx, stride, elt, align), volatile);
    }
}

// insertVector(Col, I, Block)
lm_insert_vector :: (col: Value_Id, i: u32, block_in: Value_Id, b: *Irb) -> Value_Id {
    bn := cast(u32) type_count(vtype(block_in));
    n := cast(u32) type_count(vtype(col));
    blk := irb_shuffle(b, block_in, NONE, lm_seq_mask(0, bn, n - bn));
    mask: [..] u32; mask.allocator = temp;
    k: u32 = 0;
    while k < i { array_add(*mask, k); k += 1; }
    while k < i + bn { array_add(*mask, k - i + n); k += 1; }
    while k < n { array_add(*mask, k); k += 1; }
    return irb_shuffle(b, col, blk, mask);
}

// createMulAdd
lm_mul_add :: (sum: Value_Id, a: Value_Id, bv: Value_Id, use_fp: bool, b: *Irb, contract: bool) -> Value_Id {
    if sum == NONE return irb_binop(b, ifx use_fp then Opcode.FMUL else .MUL, a, bv);
    if use_fp {
        if contract return irb_intrinsic(b, "llvm.fmuladd", .[vtype(a)], .[a, bv, sum]);
        mul := irb_binop(b, .FMUL, a, bv);
        return irb_binop(b, .FADD, sum, mul);
    }
    mul := irb_binop(b, .MUL, a, bv);
    return irb_binop(b, .ADD, sum, mul);
}

// finalizeLowering
lm_finalize :: (s: *Lm, i: Value_Id, m: Lm_Mat, b: *Irb) {
    if !table_contains(*s.i2m, i) table_set(*s.i2m, i, m);
    array_add(*s.to_remove, i);
    flat: Value_Id = NONE;
    u := ir.v_first_use[i];
    while u != NONE {
        nx := ir.u_next[u];
        if !lm_has_shape(s, ir.u_user[u]) {
            if flat == NONE flat = lm_embed(m, b);
            use_set(u, flat);
        }
        u = nx;
    }
}

// capBlockSize
lm_cap_block_size :: (s: *Lm, block_size_in: u32, rem: u32, elt: Type_Id) -> u32 {
    block_size := block_size_in;
    if block_size <= rem return block_size;
    vt := type_vector(rem, elt, false);
    if tti_is_type_legal(s.tti, vt) return rem;
    if cast(u64) type_bits(elt) * rem <= lm_cl.split_remainder_over return rem;
    while true { block_size /= 2; if block_size <= rem break; }
    return block_size;
}

// emitMatrixMultiply
lm_emit_matrix_multiply :: (s: *Lm, result: *Lm_Mat, a: Lm_Mat, bm: Lm_Mat, b: *Irb, tiled: bool, scalar_transposed: bool, fmf: u32) {
    elt := lm_mat_elt(result.*);
    vf := cast(u32) max(lm_reg_bits(s) / lm_elt_bits(elt), 1);
    r := lm_mat_rows(result.*); c := lm_mat_cols(result.*); m := lm_mat_cols(a);
    is_fp := is_fp_type(elt);
    contract := (fmf & FMF_CONTRACT) != 0;
    b.fmf = fmf;
    if lm_col_major() {
        for j: 0..cast(s64) c - 1 {
            jj := cast(u32) j;
            block_size := vf;
            sum_zero := vkind(result.v[jj]) == .C_ZERO;
            i: u32 = 0;
            while i < r {
                block_size = lm_cap_block_size(s, block_size, r - i, elt);
                sum := ifx tiled then lm_extract_vector(result.*, i, jj, block_size, b) else NONE;
                for k: 0..cast(s64) m - 1 {
                    kk := cast(u32) k;
                    l := lm_extract_vector(a, i, kk, block_size, b);
                    rh := irb_extract_element(b, bm.v[ifx scalar_transposed then kk else jj], ifx scalar_transposed then jj else kk);
                    splat := irb_vector_splat(b, block_size, rh, "splat");
                    sum = lm_mul_add(ifx sum_zero && kk == 0 then NONE else sum, l, splat, is_fp, b, contract);
                }
                result.v[jj] = lm_insert_vector(result.v[jj], i, sum, b);
                i += block_size;
            }
        }
    } else {
        for i: 0..cast(s64) r - 1 {
            ii := cast(u32) i;
            block_size := vf;
            sum_zero := vkind(result.v[ii]) == .C_ZERO;
            j: u32 = 0;
            while j < c {
                block_size = lm_cap_block_size(s, block_size, c - j, elt);
                sum: Value_Id = NONE;
                for k: 0..cast(s64) m - 1 {
                    kk := cast(u32) k;
                    rv := lm_extract_vector(bm, kk, j, block_size, b);
                    lh := irb_extract_element(b, a.v[ifx scalar_transposed then kk else ii], ifx scalar_transposed then ii else kk);
                    splat := irb_vector_splat(b, block_size, lh, "splat");
                    sum = lm_mul_add(ifx sum_zero && kk == 0 then NONE else sum, splat, rv, is_fp, b, contract);
                }
                result.v[ii] = lm_insert_vector(result.v[ii], j, sum, b);
                j += block_size;
            }
        }
    }
}

// ---------------------------------------------------------------- dot products

// m_One / ConstantInt::isOne on the scalar immediate arguments
lm_is_one :: (v: Value_Id) -> bool { return vkind(v) == .C_INT && const_int_zext(v) == 1; }
lm_has_one_use :: (v: Value_Id) -> bool { u := ir.v_first_use[v]; return u != NONE && ir.u_next[u] == NONE; }
lm_is_bin_op_inst :: (v: Value_Id) -> bool { return is_inst(v) && is_binary_op(inst_op(v)); }

// the CanBeFlattened lambda
lm_can_be_flattened :: (v: Value_Id) -> bool {
    if lm_is_bin_op_inst(v) return true;
    if !lm_has_one_use(v) return false;
    if is_inst(v) && inst_op(v) == .LOAD return true;
    id := call_iid(v);
    if id == IID_MATRIX_TRANSPOSE return true;
    if id == IID_MATRIX_COLUMN_MAJOR_LOAD && lm_is_one(call_arg(v, 1)) return true;
    return false;
}

// the GetCostForArg lambda
lm_cost_for_arg :: (s: *Lm, v: Value_Id, n: u32) -> Cost {
    if !lm_has_shape(s, v) return COST_INVALID;
    if !is_inst(v) return 0;
    vt := vtype(v);
    elt := type_elem(vt);
    e1 := type_vector(1, elt, false);
    if !lm_can_be_flattened(v) {
        c: Cost = 0;
        for 1..cast(s64) n - 1 c = cost_add(c, tti_shuffle_cost(s.tti, SK_SPLICE, e1, e1, .[], TCK_RECIP_THROUGHPUT, 0, NONE, .[], NONE));
        return c;
    }
    if lm_is_bin_op_inst(v) && lm_has_shape(s, v) {
        orig := cost_mul(tti_arith_cost(s.tti, inst_op(v), elt, TCK_RECIP_THROUGHPUT), n);
        nw := tti_arith_cost(s.tti, inst_op(v), vt, TCK_RECIP_THROUGHPUT);
        return lm_cost_sub(nw, orig);
    }
    if call_iid(v) == IID_MATRIX_TRANSPOSE {
        c: Cost = 0;
        for 1..cast(s64) n - 1 c = lm_cost_sub(c, tti_shuffle_cost(s.tti, SK_SPLICE, e1, e1, .[], TCK_RECIP_THROUGHPUT, 0, NONE, .[], NONE));
        return c;
    }
    if n == 1 return 0;
    return lm_cost_sub(tti_memory_op_cost(s.tti, .LOAD, vt, 1, 0, TCK_RECIP_THROUGHPUT),
                       cost_mul(n, tti_memory_op_cost(s.tti, .LOAD, elt, 1, 0, TCK_RECIP_THROUGHPUT)));
}

// lowerDotProduct
lm_lower_dot_product :: (s: *Lm, mm: Value_Id, fmf: u32) {
    if table_contains(*s.fused, mm) || !lm_col_major() return;
    lsh := lm_shape_v(call_arg(mm, 2), call_arg(mm, 3));
    rsh := lm_shape_v(call_arg(mm, 3), call_arg(mm, 4));
    if lsh.rows != 1 || rsh.cols != 1 return;
    lhs := call_arg(mm, 0);
    rhs := call_arg(mm, 1);
    elt := type_elem(vtype(lhs));
    is_int := is_int_type(elt);
    if !is_int && (fmf & FMF_REASSOC) == 0 return;

    seen: Table(Value_Id, bool); seen.allocator = temp;
    wl: [..] Value_Id; wl.allocator = temp;
    to_flatten: [..] Value_Id; to_flatten.allocator = temp;
    array_add(*wl, lhs);
    lhs_cost: Cost = 0;
    while wl.count {
        v := wl[wl.count - 1]; wl.count -= 1;
        if table_contains(*seen, v) continue;
        table_set(*seen, v, true);
        c := lm_cost_for_arg(s, v, lsh.cols);
        if cost_add(c, lhs_cost) >= lhs_cost continue;
        lhs_cost = cost_add(lhs_cost, c);
        array_add(*to_flatten, v);
        if is_inst(v) for k: 0..cast(s64) nops(v) - 1 array_add(*wl, op(v, cast(u32) k));
    }

    add_opc: Opcode = ifx is_int then .ADD else .FADD;
    mul_opc: Opcode = ifx is_int then .MUL else .FMUL;
    red := cost_add(tti_arithmetic_reduction_cost(s.tti, add_opc, vtype(lhs), !is_int, fmf, TCK_RECIP_THROUGHPUT),
                    tti_arith_cost(s.tti, mul_opc, vtype(lhs), TCK_RECIP_THROUGHPUT));
    seq := cost_add(cost_mul(tti_arith_cost(s.tti, add_opc, elt, TCK_RECIP_THROUGHPUT), cast(Cost) lsh.cols - 1),
                    cost_mul(tti_arith_cost(s.tti, mul_opc, elt, TCK_RECIP_THROUGHPUT), lsh.cols));
    if lm_cost_sub(cost_add(lhs_cost, red), seq) > 0 return;

    table_set(*s.fused, mm, true);
    b: Irb; irb_set_before(*b, mm);
    for v: to_flatten {
        // the FlattenArg lambda
        if !lm_can_be_flattened(v) continue;
        if lm_is_bin_op_inst(v) {
            p := table_find_pointer(*s.shape, v);
            if p { p.* = lm_shape_t(p.*); continue; }
        }
        table_set(*s.fused, v, true);
        id := call_iid(v);
        if id == IID_MATRIX_COLUMN_MAJOR_LOAD {
            arg := call_arg(v, 0);
            vol := lm_is_one(call_arg(v, 2));
            al := lm_align_for_index(0, call_arg(v, 1), type_elem(vtype(v)), call_param_align(v, 0));
            nl := irb_load(*b, vtype(v), arg, al, vol);
            rauw_with_metadata(v, nl);
            lm_erase(s, v);
            continue;
        } else if id == IID_MATRIX_TRANSPOSE {
            array_add(*s.to_remove, v);
            rauw_with_metadata(v, call_arg(v, 0));
            continue;
        }
    }
    lhs = call_arg(mm, 0);
    mul := irb_binop(*b, mul_opc, lhs, rhs);
    result: Value_Id;
    if is_int {
        result = irb_intrinsic(*b, "llvm.vector.reduce.add", .[vtype(mul)], .[mul]);
    } else {
        result = irb_intrinsic(*b, "llvm.vector.reduce.fadd", .[vtype(mul)], .[const_null_value(type_elem(vtype(lhs))), mul]);
        inst(result).flags |= fmf << FMF_SHIFT;
    }
    result = irb_insert_element(*b, const_poison(vtype(mm)), result, 0);
    rauw_with_metadata(mm, result);
    table_set(*s.fused, mm, true);
    array_add(*s.to_remove, mm);
}

// ---------------------------------------------------------------- fusion

// getNonAliasingPointer: (pointer, alloca or NONE)
lm_non_aliasing_pointer :: (s: *Lm, load: Value_Id, store: Value_Id, mm: Value_Id) -> (Value_Id, Value_Id) {
    store_loc := mloc_get(store);
    load_loc := mloc_get(load);
    if aa_alias_once(*s.aar, load_loc, store_loc).kind == AR_NO return op(load, 0), NONE;

    entry := fn_entry(s.f);
    ab: Irb; irb_set_before(*ab, block_first(entry));
    load_as := cast(u32) ir.types[vtype(op(load, 0))].a;
    store_as := cast(u32) ir.types[vtype(op(store, 1))].a;
    vt := vtype(load);
    if load_as != store_as {
        at := type_array(type_count(vt), type_elem(vt));
        alloca := irb_alloca(*ab, at, NONE, "", load_as);
        b: Irb; irb_set_before(*b, mm);
        irb_lifetime(*b, IID_LIFETIME_START, alloca);
        irb_memcpy(*b, alloca, inst(alloca).align, op(load, 0), inst(load).align, const_int(ir.t_i64, ls_value(load_loc.size)), false);
        return alloca, alloca;
    }

    check0 := inst_block(mm);
    updates: [..] Dom_Update; updates.allocator = temp;
    t0 := block_terminator(check0);
    if t0 != NONE for k: 0..cast(s64) num_successors(t0) - 1 array_add(*updates, .{false, check0, get_successor(t0, cast(u32) k)});

    check1 := split_block(inst_block(mm), mm, null, s.li, null, "alias_cont");
    copy := split_block(inst_block(mm), mm, null, s.li, null, "copy");
    fusion := split_block(inst_block(mm), mm, null, s.li, null, "no_alias");

    b: Irb; irb_set_before(*b, mm);
    erase_inst_with_metadata(block_terminator(check0));
    irb_set_end(*b, check0);
    addr_ty := lm_index_type(op(store, 1));
    store_begin := op(store, 1);
    store_end := irb_gep(*b, ir.t_i8, store_begin, .[const_int(addr_ty, ls_value(store_loc.size))], "store.end", F_INBOUNDS | F_GEP_NUW);
    load_begin := op(load, 0);
    br1 := irb_cond_br(*b, irb_icmp(*b, ICMP_ULT, load_begin, store_end), check1, fusion);
    set_explicitly_unknown_branch_weights_if_profiled(br1, "lower-matrix-intrinsics");

    erase_inst_with_metadata(block_terminator(check1));
    irb_set_at(*b, check1, block_first(check1), true);
    at := type_array(type_count(vt), type_elem(vt));
    alloca := irb_alloca(*ab, at, NONE, "", load_as);
    irb_lifetime(*b, IID_LIFETIME_START, alloca);
    load_end := irb_gep(*b, ir.t_i8, load_begin, .[const_int(addr_ty, ls_value(load_loc.size))], "load.end", F_INBOUNDS | F_GEP_NUW);
    br2 := irb_cond_br(*b, irb_icmp(*b, ICMP_ULT, store_begin, load_end), copy, fusion);
    set_explicitly_unknown_branch_weights_if_profiled(br2, "lower-matrix-intrinsics");

    irb_set_at(*b, copy, block_first(copy), true);
    irb_memcpy(*b, alloca, inst(alloca).align, op(load, 0), inst(load).align, const_int(ir.t_i64, ls_value(load_loc.size)), false);
    irb_set_at(*b, fusion, block_first(fusion), true);
    phi := irb_phi(*b, vtype(op(load, 0)), 3);
    phi_add_incoming(phi, op(load, 0), check0);
    phi_add_incoming(phi, op(load, 0), check1);
    phi_add_incoming(phi, alloca, copy);

    array_add(*updates, .{true, check0, check1});
    array_add(*updates, .{true, check0, fusion});
    array_add(*updates, .{true, check1, copy});
    array_add(*updates, .{true, check1, fusion});
    dt_apply_updates(s.dt, updates);
    return phi, alloca;
}

// isFusionProfitable
lm_is_fusion_profitable :: (s: *Lm, mm: Value_Id) -> bool {
    if lm_cl.force_fuse return true;
    lsh := lm_shape_v(call_arg(mm, 2), call_arg(mm, 3));
    rsh := lm_shape_v(call_arg(mm, 3), call_arg(mm, 4));
    r := lsh.rows; c := rsh.cols; m := lsh.cols;
    elt := type_elem(vtype(mm));
    vf := cast(u32) max(lm_reg_bits(s) / lm_elt_bits(elt), 1);
    if r <= vf && c == 1 return false;
    op0 := (r + vf - 1) / vf * m;
    op1 := (m + vf - 1) / vf * c;
    return op0 + op1 > tti_number_of_registers(s.tti, tti_register_class_for_type(s.tti, true));
}

// getZeroMatrix
lm_zero_matrix :: (elt: Type_Id, r: u32, c: u32) -> Lm_Mat {
    res := lm_mat_new();
    ct := type_vector(r, elt, false);
    for 1..c array_add(*res.v, const_zero(ct));
    return res;
}

// TileInfo::MatrixLoop
Lm_Matrix_Loop :: struct { index: Value_Id = NONE; header: Value_Id = NONE; latch: Value_Id = NONE; }
// TileInfo
Lm_Tile_Info :: struct {
    num_rows: u32; num_columns: u32; num_inner: u32; tile_size: u32;
    column_loop: Lm_Matrix_Loop;
    row_loop: Lm_Matrix_Loop;
    k_loop: Lm_Matrix_Loop;
}

// TileInfo::CreateLoop
lm_create_loop :: (preheader: Value_Id, exit: Value_Id, bound: Value_Id, step: Value_Id, name: string, b: *Irb, dtu: *Dtu, l: Loop_Id, li: *Loop_Info) -> Value_Id {
    f := block_fn(preheader);
    header := create_block(f, tconcat(name, ".header"), exit);
    body := create_block(f, tconcat(name, ".body"), exit);
    latch := create_block(f, tconcat(name, ".latch"), exit);
    i64 := ir.t_i64;
    block_append_inst(header, create_br(body));
    block_append_inst(body, create_br(latch));
    iv := create_phi(i64, 2);
    inst_insert_before(iv, block_terminator(header));
    set_name(iv, tconcat(name, ".iv"));
    phi_add_incoming(iv, const_int(i64, 0), preheader);
    irb_set_end(b, latch);
    inc := irb_binop(b, .ADD, iv, step, tconcat(name, ".step"));
    cond := irb_icmp(b, ICMP_NE, inc, bound, tconcat(name, ".cond"));
    br := irb_cond_br(b, cond, header, exit);
    set_fitted_branch_weights(br, .[const_int_zext(bound) / const_int_zext(step), 1]);
    phi_add_incoming(iv, inc, latch);
    pbr := block_terminator(preheader);
    if inst_op(pbr) != .BR fatal("internal: lower-matrix-intrinsics: tiled loop preheader does not end in an unconditional branch");
    tmp := get_successor(pbr, 0);
    set_successor(pbr, 0, header);
    dtu_apply_permissive(dtu, .[
        .{false, preheader, tmp},
        .{true, header, body},
        .{true, body, latch},
        .{true, latch, header},
        .{true, latch, exit},
        .{true, preheader, header}]);
    li_add_basic_block_to_loop(li, l, header);
    li_add_basic_block_to_loop(li, l, body);
    li_add_basic_block_to_loop(li, l, latch);
    return body;
}

// TileInfo::CreateTiledLoops
lm_create_tiled_loops :: (ti: *Lm_Tile_Info, start: Value_Id, end: Value_Id, b: *Irb, dtu: *Dtu, li: *Loop_Info) -> Value_Id {
    col_l := li_alloc_loop(li);
    row_l := li_alloc_loop(li);
    k_l := li_alloc_loop(li);
    li_add_child_loop(li, row_l, k_l);
    li_add_child_loop(li, col_l, row_l);
    parent := li_loop_for(li, start);
    if parent != NONE li_add_child_loop(li, parent, col_l);
    else li_add_top_level_loop(li, col_l);

    i64 := ir.t_i64;
    col_body := lm_create_loop(start, end, const_int(i64, ti.num_columns), const_int(i64, ti.tile_size), "cols", b, dtu, col_l, li);
    ti.column_loop.latch = block_single_successor_of(col_body);
    row_body := lm_create_loop(col_body, ti.column_loop.latch, const_int(i64, ti.num_rows), const_int(i64, ti.tile_size), "rows", b, dtu, row_l, li);
    ti.row_loop.latch = block_single_successor_of(row_body);
    inner_body := lm_create_loop(row_body, ti.row_loop.latch, const_int(i64, ti.num_inner), const_int(i64, ti.tile_size), "inner", b, dtu, k_l, li);
    ti.k_loop.latch = block_single_successor_of(inner_body);
    ti.column_loop.header = block_single_predecessor(col_body);
    ti.row_loop.header = block_single_predecessor(row_body);
    ti.k_loop.header = block_single_predecessor(inner_body);
    ti.row_loop.index = block_first(ti.row_loop.header);
    ti.column_loop.index = block_first(ti.column_loop.header);
    ti.k_loop.index = block_first(ti.k_loop.header);
    return inner_body;
}

// createTiledLoops
lm_create_tiled_loops_for :: (s: *Lm, mm: Value_Id, lptr: Value_Id, lsh: Lm_Shape, rptr: Value_Id, rsh: Lm_Shape, store: Value_Id) {
    elt := type_elem(vtype(mm));
    ts := lm_cl.tile_size;
    ti: Lm_Tile_Info;
    ti.num_rows = lsh.rows; ti.num_columns = rsh.cols; ti.num_inner = lsh.cols; ti.tile_size = ts;
    dtu: Dtu; dtu.dt = s.dt; dtu.lazy = true;
    dtu.pending.allocator = temp; dtu.deleted.allocator = temp;
    start := inst_block(mm);
    end := split_block(start, mm, s.dt, s.li, null, "continue");
    b: Irb; irb_set_before(*b, mm);
    inner_body := lm_create_tiled_loops(*ti, start, end, *b, *dtu, s.li);

    tvt := type_vector(ts, scalar_type(vtype(mm)), false);
    tile := lm_mat_new();
    irb_set_before(*b, block_terminator(ti.k_loop.header));
    phis: [..] Value_Id; phis.allocator = temp;
    for k: 0..cast(s64) ts - 1 {
        phi := irb_phi(*b, tvt, 2, tprint("result.vec.%", k));
        phi_add_incoming(phi, const_zero(tvt), block_single_successor_of(ti.row_loop.header));
        array_add(*tile.v, phi);
        array_add(*phis, phi);
    }
    irb_set_before(*b, block_terminator(inner_body));
    a := lm_load_tile(lptr, 0, false, lsh, ti.row_loop.index, ti.k_loop.index, .{ts, ts}, elt, *b);
    bm := lm_load_tile(rptr, 0, false, rsh, ti.k_loop.index, ti.column_loop.index, .{ts, ts}, elt, *b);
    lm_emit_matrix_multiply(s, *tile, a, bm, *b, true, false, lm_fmf(mm));
    b.fmf = 0;
    irb_set_before(*b, block_terminator(ti.row_loop.latch));
    lm_store_tile(tile, op(store, 1), inst(store).align, (inst(store).flags & F_VOLATILE) != 0, .{lsh.rows, rsh.cols},
                  ti.row_loop.index, ti.column_loop.index, elt, *b);
    for k: 0..tile.v.count - 1 phi_add_incoming(phis[k], tile.v[k], ti.k_loop.latch);

    unroll := min(cast(u32) 10, lsh.cols / ts);
    add_string_metadata_to_loop(s.li, li_loop_for(s.li, ti.k_loop.header), "llvm.loop.unroll.count", unroll);
    dtu_flush(*dtu);
}

// emitSIMDTiling
lm_emit_simd_tiling :: (s: *Lm, mm: Value_Id, l0: Value_Id, l1: Value_Id, store: Value_Id) {
    if !lm_col_major() fatal("internal: lower-matrix-intrinsics: tiling only supported for column-major matrixes");
    if !lm_is_fusion_profitable(s, mm) return;
    lsh := lm_shape_v(call_arg(mm, 2), call_arg(mm, 3));
    rsh := lm_shape_v(call_arg(mm, 3), call_arg(mm, 4));
    r := lsh.rows; c := rsh.cols; m := lsh.cols;
    elt := type_elem(vtype(mm));
    aptr, aalloca := lm_non_aliasing_pointer(s, l0, store, mm);
    bptr, balloca := lm_non_aliasing_pointer(s, l1, store, mm);
    cptr := op(store, 1);
    ts := lm_cl.tile_size;
    num_ops := lm_num_native_vector_ops(s, elt, r, m, c);
    use_loops := num_ops > lm_cl.loops_threshold && r % ts == 0 && c % ts == 0;
    store_vol := (inst(store).flags & F_VOLATILE) != 0;
    if use_loops {
        lm_create_tiled_loops_for(s, mm, aptr, lsh, bptr, rsh, store);
    } else {
        b: Irb; irb_set_before(*b, store);
        fmf := lm_fmf(mm);
        j: u32 = 0;
        while j < c {
            i: u32 = 0;
            while i < r {
                tr := min(r - i, ts);
                tc := min(c - j, ts);
                res := lm_zero_matrix(elt, tr, tc);
                k: u32 = 0;
                while k < m {
                    tm := min(m - k, ts);
                    a := lm_load_tile(aptr, inst(l0).align, (inst(l0).flags & F_VOLATILE) != 0, lsh, lm_index(aptr, i), lm_index(aptr, k), .{tr, tm}, elt, *b);
                    bm := lm_load_tile(bptr, inst(l1).align, (inst(l1).flags & F_VOLATILE) != 0, rsh, lm_index(bptr, k), lm_index(bptr, j), .{tm, tc}, elt, *b);
                    lm_emit_matrix_multiply(s, *res, a, bm, *b, true, false, fmf);
                    k += ts;
                }
                lm_store_tile(res, cptr, inst(store).align, store_vol, .{r, m}, lm_index(cptr, i), lm_index(cptr, j), elt, *b);
                i += ts;
            }
            j += ts;
        }
    }
    {
        b: Irb; irb_set_before(*b, store);
        if aalloca != NONE irb_lifetime(*b, IID_LIFETIME_END, aalloca);
        if balloca != NONE irb_lifetime(*b, IID_LIFETIME_END, balloca);
    }
    table_set(*s.fused, store, true);
    table_set(*s.fused, mm, true);
    lm_erase(s, store);
    lm_erase(s, mm);
    if !has_uses(l0) { table_set(*s.fused, l0, true); lm_erase(s, l0); }
    if l1 != l0 && !has_uses(l1) { table_set(*s.fused, l1, true); lm_erase(s, l1); }
}

// LowerMatrixMultiplyFused
lm_lower_multiply_fused :: (s: *Lm, mm: Value_Id) {
    if !lm_cl.fuse || !s.dt || lm_cl.tile_size == 0 return;
    a := call_arg(mm, 0);
    bv := call_arg(mm, 1);
    tv := ifx lm_col_major() then bv else a;
    if call_iid(tv) == IID_MATRIX_TRANSPOSE {
        t := call_arg(tv, 0);
        b: Irb; irb_set_before(*b, mm);
        elt := type_elem(vtype(mm));
        lsh := lm_shape_v(call_arg(mm, 2), call_arg(mm, 3));
        rsh := lm_shape_v(call_arg(mm, 3), call_arg(mm, 4));
        r := lsh.rows; m := lsh.cols; c := rsh.cols;
        ma, mb: Lm_Mat;
        transpose: Value_Id;
        if lm_col_major() {
            ma = lm_get_matrix(s, a, .{r, m}, *b);
            mb = lm_get_matrix(s, t, .{c, m}, *b);
            transpose = bv;
        } else {
            ma = lm_get_matrix(s, t, .{r, m}, *b);
            mb = lm_get_matrix(s, bv, .{c, m}, *b);
            transpose = a;
        }
        result := lm_mat_poison(r, c, elt);
        lm_emit_matrix_multiply(s, *result, ma, mb, *b, false, true, lm_fmf(mm));
        table_set(*s.fused, mm, true);
        if lm_has_one_use(transpose) {
            table_set(*s.fused, transpose, true);
            array_add(*s.to_remove, transpose);
            table_set(*s.i2m, transpose, lm_mat_poison(m, c, elt));
        }
        lm_finalize(s, mm, result, *b);
        return;
    }

    if !lm_has_one_use(mm) || !lm_col_major() return;
    l0 := a; l1 := bv;
    store := ir.u_user[ir.v_first_use[mm]];
    if !(is_inst(l0) && inst_op(l0) == .LOAD && is_inst(l1) && inst_op(l1) == .LOAD && inst_op(store) == .STORE) return;

    // The store address must dominate the MatMul instruction, otherwise we create invalid IR.
    wl: [..] Value_Id; wl.allocator = temp;
    in_wl: Table(Value_Id, bool); in_wl.allocator = temp;
    add_wl :: (wl: *[..] Value_Id, in_wl: *Table(Value_Id, bool), v: Value_Id) {
        if table_contains(in_wl, v) return;
        table_set(in_wl, v, true);
        array_add(wl, v);
    }
    add_wl(*wl, *in_wl, op(store, 1));
    to_hoist: [..] Value_Id; to_hoist.allocator = temp;
    idx := 0;
    while idx < wl.count {
        cur := wl[idx];
        idx += 1;
        if !is_inst(cur) continue;
        if inst_op(cur) == .PHI return;
        if dt_dominates_inst(s.dt, cur, mm) continue;
        if may_have_side_effects(cur) || may_read_from_memory(cur) return;
        array_add(*to_hoist, cur);
        for k: 0..cast(s64) nops(cur) - 1 add_wl(*wl, *in_wl, op(cur, cast(u32) k));
    }
    std_sort_by(to_hoist, (x: Value_Id, y: Value_Id, d: *void) -> bool { return dt_dominates_inst(cast(*Dom_Tree) d, x, y); }, s.dt);
    for to_hoist inst_move_before_dbg(it, mm);

    // Deal with lifetime.end calls that might be between Load0/Load1 and the store.
    l0_loc := mloc_get(l0);
    l1_loc := mloc_get(l1);
    store_parent := inst_block(store);
    same_block := inst_block(l0) == store_parent && inst_block(l1) == store_parent;
    e := 0;
    while e != s.lifetime_ends.count {
        end := s.lifetime_ends[e];
        if dt_dominates_inst(s.dt, end, l0) && dt_dominates_inst(s.dt, end, l1) { e += 1; continue; }
        if dt_dominates_inst(s.dt, store, end) { e += 1; continue; }
        if same_block && inst_block(end) != store_parent { e += 1; continue; }
        end_loc := mloc_for_argument(end, 0, false);
        if end_loc.ptr == NONE { e += 1; continue; }
        if aa_alias_once(*s.aar, l0_loc, end_loc).kind == AR_NO && aa_alias_once(*s.aar, l1_loc, end_loc).kind == AR_NO { e += 1; continue; }
        if inst_block(end) == store_parent { inst_move_after_head(end, store); e += 1; continue; }
        array_add(*s.to_remove, end);
        s.lifetime_ends[e] = s.lifetime_ends[s.lifetime_ends.count - 1];
        s.lifetime_ends.count -= 1;
    }
    lm_emit_simd_tiling(s, mm, l0, l1, store);
}

// ---------------------------------------------------------------- Visit* lowering

// LowerLoad / loadMatrix for a load-like instruction
lm_lower_multiply :: (s: *Lm, mm: Value_Id, b: *Irb) -> Lm_Mat {
    elt := type_elem(vtype(mm));
    lsh := lm_shape_v(call_arg(mm, 2), call_arg(mm, 3));
    rsh := lm_shape_v(call_arg(mm, 3), call_arg(mm, 4));
    lhs := lm_get_matrix(s, call_arg(mm, 0), lsh, b);
    rhs := lm_get_matrix(s, call_arg(mm, 1), rsh, b);
    result := lm_mat_poison(lsh.rows, rsh.cols, elt);
    lm_emit_matrix_multiply(s, *result, lhs, rhs, b, false, false, lm_fmf(mm));
    return result;
}

// LowerTranspose
lm_lower_transpose :: (s: *Lm, i: Value_Id, b: *Irb) -> Lm_Mat {
    res := lm_mat_new();
    input := call_arg(i, 0);
    vt := vtype(input);
    ash := lm_shape_v(call_arg(i, 1), call_arg(i, 2));
    im := lm_get_matrix(s, input, ash, b);
    new_vecs := ifx lm_col_major() then ash.rows else ash.cols;
    new_elts := ifx lm_col_major() then ash.cols else ash.rows;
    for k: 0..cast(s64) new_vecs - 1 {
        rv := const_poison(type_vector(new_elts, type_elem(vt), false));
        for v, j: im.v {
            e := irb_extract_element(b, v, cast(u64) k);
            rv = irb_insert_element(b, rv, e, cast(u64) j);
        }
        array_add(*res.v, rv);
    }
    return res;
}

// VisitIntrinsicInst
lm_visit_intrinsic :: (s: *Lm, i: Value_Id, si: Lm_Shape, b: *Irb) -> Lm_Mat {
    id := call_iid(i);
    if id == IID_MATRIX_MULTIPLY return lm_lower_multiply(s, i, b);
    if id == IID_MATRIX_TRANSPOSE return lm_lower_transpose(s, i, b);
    if id == IID_MATRIX_COLUMN_MAJOR_LOAD {
        // (LLVM asserts the column-major layout; release builds lower with the row-major layout, like here)
        return lm_load_matrix(vtype(i), call_arg(i, 0), call_param_align(i, 0), call_arg(i, 1), lm_is_one(call_arg(i, 2)),
                              lm_shape_v(call_arg(i, 3), call_arg(i, 4)), b);
    }
    if id == IID_MATRIX_COLUMN_MAJOR_STORE {
        mv := call_arg(i, 0);
        sv := lm_get_matrix(s, mv, lm_shape_v(call_arg(i, 4), call_arg(i, 5)), b);
        lm_store_matrix(vtype(mv), sv, call_arg(i, 1), call_param_align(i, 1), call_arg(i, 2), lm_is_one(call_arg(i, 3)), b);
        return lm_mat_new();
    }
    if id == IID_ABS || id == IID_FABS {
        res := lm_mat_new();
        m := lm_get_matrix(s, call_arg(i, 0), si, b);
        b.fmf = lm_fmf(i);
        for v: m.v {
            if id == IID_ABS array_add(*res.v, irb_intrinsic(b, "llvm.abs", .[vtype(v)], .[v, call_arg(i, 1)]));
            else array_add(*res.v, irb_intrinsic(b, "llvm.fabs", .[vtype(v)], .[v]));
        }
        return res;
    }
    fatal("internal: lower-matrix-intrinsics: only intrinsics supporting shape info should be seen here");
    return .{};
}

// VisitPHI
lm_visit_phi :: (s: *Lm, i: Value_Id, si: Lm_Shape, b: *Irb) -> Lm_Mat {
    bb := inst_block(i);
    ip := block_first_insertion_pt(bb);
    irb_set_at(b, bb, ip, true);
    phim := lm_get_matrix(s, i, si, b);
    reshaped: Table(Value_Id, Lm_Mat); reshaped.allocator = temp;
    n := phi_num_incoming(i);
    for k: 0..cast(s64) n - 1 {
        iv := phi_value(i, cast(u32) k);
        ib := phi_block(i, cast(u32) k);
        irb_set_before(b, block_terminator(ib));
        if is_inst(iv) {
            pt, pbb, head := inst_insertion_point_after_def(iv);
            if pt != NONE irb_set_at(b, pbb, pt, head);
        }
        found, opm := table_find(*reshaped, ib);
        if !found {
            opm = lm_get_matrix(s, iv, si, b);
            table_set(*reshaped, ib, opm);
        }
        for v, vi: phim.v phi_add_incoming(v, opm.v[vi], ib);
    }
    irb_set_at(b, bb, ip, true);
    return phim;
}

// VisitBinaryOperator
lm_visit_binop :: (s: *Lm, i: Value_Id, si: Lm_Shape, b: *Irb) -> Lm_Mat {
    res := lm_mat_new();
    a := lm_get_matrix(s, op(i, 0), si, b);
    bm := lm_get_matrix(s, op(i, 1), si, b);
    b.fmf = lm_fmf(i);
    if a.v.count != bm.v.count fatal("internal: lower-matrix-intrinsics: operand matrices differ in size");
    for v, k: a.v array_add(*res.v, irb_binop(b, inst_op(i), v, bm.v[k]));
    return res;
}

// CreateFNeg
lm_fneg :: (b: *Irb, v: Value_Id) -> Value_Id {
    if irb_is_const(v) { f := cf_unary(.FNEG, v); if f != NONE return f; }
    i := new_inst(.FNEG, vtype(v), 1);
    set_op(i, 0, v);
    return irb_insert(b, i);
}

// VisitUnaryOperator
lm_visit_unop :: (s: *Lm, i: Value_Id, si: Lm_Shape, b: *Irb) -> Lm_Mat {
    res := lm_mat_new();
    m := lm_get_matrix(s, op(i, 0), si, b);
    b.fmf = lm_fmf(i);
    for v: m.v array_add(*res.v, lm_fneg(b, v));
    return res;
}

// VisitCastInstruction
lm_visit_cast :: (s: *Lm, i: Value_Id, si: Lm_Shape, b: *Irb) -> Lm_Mat {
    res := lm_mat_new();
    m := lm_get_matrix(s, op(i, 0), si, b);
    b.fmf = lm_fmf(i);
    nt := type_vector(lm_mat_stride(m), type_elem(vtype(i)), false);
    for v: m.v array_add(*res.v, irb_cast(b, inst_op(i), v, nt));
    return res;
}

// VisitSelectInst
lm_visit_select :: (s: *Lm, i: Value_Id, si: Lm_Shape, b: *Irb) -> Lm_Mat {
    cond := op(i, 0);
    res := lm_mat_new();
    a := lm_get_matrix(s, op(i, 1), si, b);
    bm := lm_get_matrix(s, op(i, 2), si, b);
    condv: [..] Value_Id; condv.allocator = temp;
    md_from: Value_Id = NONE;
    if type_kind(vtype(cond)) == .VECTOR {
        cm := lm_get_matrix(s, cond, si, b);
        for cm.v array_add(*condv, it);
    } else {
        for 1..a.v.count array_add(*condv, cond);
        md_from = i;
    }
    if condv.count != a.v.count || bm.v.count != a.v.count fatal("internal: lower-matrix-intrinsics: select operand matrices differ in size");
    for cv, k: condv array_add(*res.v, irb_select(b, cv, a.v[k], bm.v[k], "", md_from));
    return res;
}

// ---------------------------------------------------------------- Visit

lm_visit :: (s: *Lm) -> bool {
    wl: [..] Value_Id; wl.allocator = temp;
    for bb: fn_blocks(s.f) for i: block_insts(bb) if lm_is_matrix_iid(call_iid(i)) array_add(*wl, i);
    if wl.count == 0 return false;

    if s.use_am {
        // ORE (OptimizationRemarkEmitterAnalysis: no effect without -pass-remarks), AAManager, DT, LoopAnalysis
        s.aar = aa_results_for(s.f);
        s.dt = get_domtree(s.f);
        s.li = get_loop_info(s.f);
    }

    while wl.count {
        nw := lm_propagate_forward(s, *wl);
        wl = lm_propagate_backward(s, *nw);
    }

    changed := false;
    if s.dt {
        if lm_optimize_transposes(s) changed = true;
        if lm_cl.print_after_transpose fatal("lower-matrix-intrinsics: -matrix-print-after-transpose-opt is not supported");
    }

    fusable: [..] Value_Id; fusable.allocator = temp;
    matrix_insts: [..] Value_Id; matrix_insts.allocator = temp;
    s.lifetime_ends.allocator = temp;
    rpo: [..] Value_Id; rpo.allocator = temp;
    cfg_post_order(fn_entry(s.f), *rpo);
    for < bb: rpo for i: block_insts(bb) {
        if call_iid(i) == IID_LIFETIME_END array_add(*s.lifetime_ends, i);
        if !lm_has_shape(s, i) continue;
        if call_iid(i) == IID_MATRIX_MULTIPLY array_add(*fusable, i);
        array_add(*matrix_insts, i);
    }

    for fusable lm_lower_dot_product(s, it, lm_fmf(it));
    for fusable if !table_contains(*s.fused, it) lm_lower_multiply_fused(s, it);
    if s.fused.count changed = true;

    // pre-process the PHINodes
    for i: matrix_insts {
        if table_contains(*s.fused, i) continue;
        if inst_op(i) != .PHI continue;
        found, si := table_find(*s.shape, i);
        if !found fatal("internal: lower-matrix-intrinsics: a matrix instruction lost its shape");
        elt := type_elem(vtype(i));
        phim := lm_mat_poison(si.rows, si.cols, elt);
        b: Irb; irb_set_before(*b, i);
        for k: 0..phim.v.count - 1 phim.v[k] = irb_phi(*b, vtype(phim.v[0]), phi_num_incoming(i), vname(i));
        table_set(*s.i2m, i, phim);
    }

    // lower the remaining instructions with shape information
    for i: matrix_insts {
        if table_contains(*s.fused, i) continue;
        found, si := table_find(*s.shape, i);
        if !found fatal("internal: lower-matrix-intrinsics: a matrix instruction lost its shape");
        b: Irb; irb_set_before(*b, i);
        o := inst_op(i);
        res: Lm_Mat;
        if is_binary_op(o) res = lm_visit_binop(s, i, si, *b);
        else if is_cast_op(o) res = lm_visit_cast(s, i, si, *b);
        else if o == .FNEG res = lm_visit_unop(s, i, si, *b);
        else if call_iid(i) != NOT_INTRINSIC res = lm_visit_intrinsic(s, i, si, *b);
        else if o == .SELECT res = lm_visit_select(s, i, si, *b);
        else if o == .LOAD {
            ptr := op(i, 0);
            res = lm_load_matrix(vtype(i), ptr, inst(i).align, lm_index(ptr, lm_shape_stride(si)), (inst(i).flags & F_VOLATILE) != 0, si, *b);
        } else if o == .STORE {
            mv := op(i, 0); ptr := op(i, 1);
            sv := lm_get_matrix(s, mv, si, *b);
            lm_store_matrix(vtype(mv), sv, ptr, inst(i).align, lm_index(ptr, lm_shape_stride(si)), (inst(i).flags & F_VOLATILE) != 0, *b);
            res = lm_mat_new();
        } else if o == .PHI res = lm_visit_phi(s, i, si, *b);
        else continue;
        lm_finalize(s, i, res, *b);
        changed = true;
    }

    // delete the instructions backwards
    poisoned: Table(Value_Id, bool); poisoned.allocator = temp;
    for < i: s.to_remove {
        u := ir.v_first_use[i];
        while u != NONE {
            nx := ir.u_next[u];
            user := ir.u_user[u];
            if is_inst(user) table_set(*poisoned, user, true);
            use_set(u, const_poison(vtype(i)));
            u = nx;
        }
        erase_inst_with_metadata(i);
        table_remove(*poisoned, i);
    }
    if poisoned.count fatal("internal: lower-matrix-intrinsics: Poisoned but instruction not removed");
    return changed;
}

lower_matrix_intrinsics_run :: (f: Value_Id, node: *Pass_Node) -> Preserved {
    minimal := node.name == "lower-matrix-intrinsics<minimal>";
    s: Lm;
    s.f = f;
    s.tti = tti_get(f);
    s.use_am = !minimal;
    s.shape.allocator = temp; s.i2m.allocator = temp; s.fused.allocator = temp; s.to_remove.allocator = temp;
    if !lm_visit(*s) return PRESERVE_ALL;
    pa: Preserved;
    if !minimal { preserve(*pa, .LOOPS); preserve(*pa, .DOMTREE); }
    return pa;
}
