// X86InterleavedAccessGroup: port of llvm/lib/Target/X86/X86InterleavedAccess.cpp (isSupported, decompose,
// transpose_4x4, interleave8bitStride4VF8, interleave8bitStride4, interleave8bitStride3, deinterleave8bitStride3,
// reorderSubVector, concatSubVector, genShuffleBland, createShuffleStride, setGroupSize, DecodePALIGNRMask,
// group2Shuffle, lowerIntoOptimizedSequence, X86TargetLowering::lowerInterleavedLoad / lowerInterleavedStore) with
// llvm::createUnpackShuffleMask (X86ISelLowering.cpp) and createSequentialMask / concatenateVectors (VectorUtils.cpp).
// The group is a plain struct (`Xia_Group`); an MVT is (number of elements, element bits).

Xia_Group :: struct {
    inst: Value_Id;            // the wide load or the store
    shuffles: [] Value_Id;
    indices: [] u32;
    factor: u32;
    st: *X86_Lowering;
    b: Irb;
}
Xia_Vt :: struct { n: s64; bits: s64; }   // a simple vector MVT
xia_vt_size :: (vt: Xia_Vt) -> s64 { return vt.n * vt.bits; }
// scaleVectorType: half the elements, twice the element size
xia_scale_vt :: (vt: Xia_Vt) -> Xia_Vt { return .{vt.n / 2, vt.bits * 2}; }

XIA_CONCAT :: s32.[
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63];

xia_mask :: () -> [..] s32 { m: [..] s32; m.allocator = temp; return m; }

// Builder.CreateShuffleVector(V1, V2, Mask) / (V, Mask)
xia_shuffle :: (b: *Irb, v1: Value_Id, v2: Value_Id, mask: [] s32) -> Value_Id {
    m := NewArray(mask.count, u32,, allocator = temp);
    for mask m[it_index] = ifx it < 0 then 0xFFFF_FFFF else cast(u32) it;
    return irb_shuffle(b, v1, v2, m);
}

// createSequentialMask(Start, NumInts, NumUndefs)
xia_sequential_mask :: (start: u32, num_ints: u32, num_undefs: u32) -> [..] s32 {
    m := xia_mask();
    for i: 0..cast(s64) num_ints - 1 array_add(*m, cast,no_check(s32) (start + cast(u32) i));
    for 1..num_undefs array_add(*m, -1);
    return m;
}

// llvm::concatenateVectors (VectorUtils.cpp)
xia_concatenate_vectors :: (b: *Irb, vecs: [] Value_Id) -> Value_Id {
    two :: (b: *Irb, v1: Value_Id, v2_in: Value_Id) -> Value_Id {
        v2 := v2_in;
        n1 := cast(u32) type_count(vtype(v1)); n2 := cast(u32) type_count(vtype(v2));
        if n1 > n2 v2 = xia_shuffle(b, v2, NONE, xia_sequential_mask(0, n2, n1 - n2));
        return xia_shuffle(b, v1, v2, xia_sequential_mask(0, n1 + n2, 0));
    }
    res: [..] Value_Id; res.allocator = temp;
    for vecs array_add(*res, it);
    num := res.count;
    while true {
        tmp: [..] Value_Id; tmp.allocator = temp;
        i := 0;
        while i < num - 1 { array_add(*tmp, two(b, res[i], res[i + 1])); i += 2; }
        if num % 2 != 0 array_add(*tmp, res[num - 1]);
        res = tmp;
        num = res.count;
        if num <= 1 break;
    }
    return res[0];
}

// llvm::createUnpackShuffleMask(VT, Mask, Lo, Unary)
xia_create_unpack_shuffle_mask :: (vt: Xia_Vt, lo: bool, unary: bool) -> [..] s32 {
    m := xia_mask();
    num_elts := vt.n;
    in_lane := 128 / vt.bits;
    for i: 0..num_elts - 1 {
        lane_start := (i / in_lane) * in_lane;
        pos := (i % in_lane) / 2 + lane_start;
        pos += ifx unary then 0 else num_elts * (i % 2);
        pos += ifx lo then 0 else in_lane / 2;
        array_add(*m, cast(s32) pos);
    }
    return m;
}

// X86InterleavedAccessGroup::isSupported
xia_is_supported :: (g: *Xia_Group) -> bool {
    shuffle_elem_size := dl_type_size_bits(type_elem(vtype(g.shuffles[0])));
    if !st_hasAVX(g.st) || (g.factor != 4 && g.factor != 3) return false;
    wide: u64;
    is_load := inst_op(g.inst) == .LOAD;
    if is_load {
        wide = dl_type_size_bits(vtype(g.inst));
        if ptr_addrspace(vtype(op(g.inst, 0))) != 0 return false;
    } else wide = dl_type_size_bits(vtype(g.shuffles[0]));
    if shuffle_elem_size == 64 && wide == 1024 && g.factor == 4 return true;
    if shuffle_elem_size == 8 && !is_load && g.factor == 4 && (wide == 256 || wide == 512 || wide == 1024 || wide == 2048) return true;
    if shuffle_elem_size == 8 && g.factor == 3 && (wide == 384 || wide == 768 || wide == 1536) return true;
    return false;
}

// decompose(VecInst, NumSubVectors, SubVecTy, DecomposedVectors)
xia_decompose :: (g: *Xia_Group, vec_inst: Value_Id, num_sub: u32, sub_ty: Type_Id) -> [..] Value_Id {
    out: [..] Value_Id; out.allocator = temp;
    if inst_op(vec_inst) == .SHUFFLEVECTOR {
        op0 := op(vec_inst, 0); op1 := op(vec_inst, 1);
        for i: 0..cast(s64) num_sub - 1
            array_add(*out, xia_shuffle(*g.b, op0, op1, xia_sequential_mask(g.indices[i], cast(u32) type_count(sub_ty), 0)));
        return out;
    }
    li := vec_inst;
    num_loads := num_sub;
    vec_length := dl_type_size_bits(vtype(li));
    base_ptr := op(li, 0);
    base_ty: Type_Id;
    if vec_length == 768 || vec_length == 1536 {
        base_ty = type_vector(16, ir.t_i8, false);
        num_loads = num_sub * cast(u32) (vec_length / 384);
    } else base_ty = sub_ty;
    first_align := inst(li).align;
    subsequent := common_alignment(first_align, dl_type_size_bits(base_ty) / 8);
    align := first_align;
    for i: 0..cast(s64) num_loads - 1 {
        p := irb_gep(*g.b, base_ty, base_ptr, .[const_int(ir.t_i32, cast(u64) i)]);
        array_add(*out, irb_load(*g.b, base_ty, p, align));
        align = subsequent;
    }
    return out;
}

// genShuffleBland
xia_gen_shuffle_bland :: (vt: Xia_Vt, mask: [] s32, out: *[..] s32, low: s64, high: s64) {
    for mask array_add(out, cast(s32) (it + low));
    for mask array_add(out, cast(s32) (it + high + vt.n));
}

// reorderSubVector
xia_reorder_sub_vector :: (g: *Xia_Group, vt: Xia_Vt, tm: *[..] Value_Id, vec: [] Value_Id, vpshuf: [] s32, vec_elems: s64, stride: s64) {
    if vec_elems == 16 {
        for i: 0..stride - 1 tm.*[i] = xia_shuffle(*g.b, vec[i], NONE, vpshuf);
        return;
    }
    temp: [8] Value_Id;
    i := 0;
    while i < (vec_elems / 16) * stride {
        opt := xia_mask();
        xia_gen_shuffle_bland(vt, vpshuf, *opt, (i / stride) * 16, (i + 1) / stride * 16);
        temp[i / 2] = xia_shuffle(*g.b, vec[i % stride], vec[(i + 1) % stride], opt);
        i += 2;
    }
    if vec_elems == 32 {
        for k: 0..stride - 1 tm.*[k] = temp[k];
        return;
    }
    for k: 0..stride - 1 tm.*[k] = xia_shuffle(*g.b, temp[2 * k], temp[2 * k + 1], XIA_CONCAT);
}

xia_resize :: (tm: *[..] Value_Id, n: s64) { while tm.count < n array_add(tm, NONE); tm.count = n; }

// interleave8bitStride4VF8
xia_interleave8bit_stride4_vf8 :: (g: *Xia_Group, m: [] Value_Id, tm: *[..] Value_Id) {
    vt := Xia_Vt.{8, 16};
    xia_resize(tm, 2);
    mask_low := xia_mask();
    for i: 0..7 { array_add(*mask_low, cast(s32) i); array_add(*mask_low, cast(s32) (i + 8)); }
    low_t1 := xia_create_unpack_shuffle_mask(vt, true, false);
    high_t1 := xia_create_unpack_shuffle_mask(vt, false, false);
    high_word := narrow_shuffle_mask_elts(2, high_t1);
    low_word := narrow_shuffle_mask_elts(2, low_t1);
    v1 := xia_shuffle(*g.b, m[0], m[1], mask_low);
    v2 := xia_shuffle(*g.b, m[2], m[3], mask_low);
    tm.*[0] = xia_shuffle(*g.b, v1, v2, low_word);
    tm.*[1] = xia_shuffle(*g.b, v1, v2, high_word);
}

// interleave8bitStride4
xia_interleave8bit_stride4 :: (g: *Xia_Group, m: [] Value_Id, tm: *[..] Value_Id, num_elm: s64) {
    vt := Xia_Vt.{num_elm, 8};
    half := xia_scale_vt(vt);
    xia_resize(tm, 4);
    mask_low := xia_create_unpack_shuffle_mask(vt, true, false);
    mask_high := xia_create_unpack_shuffle_mask(vt, false, false);
    low_t := xia_create_unpack_shuffle_mask(half, true, false);
    high_t := xia_create_unpack_shuffle_mask(half, false, false);
    lh: [2] [..] s32;
    lh[0] = narrow_shuffle_mask_elts(2, low_t);
    lh[1] = narrow_shuffle_mask_elts(2, high_t);
    iv: [4] Value_Id;
    iv[0] = xia_shuffle(*g.b, m[0], m[1], mask_low);
    iv[1] = xia_shuffle(*g.b, m[0], m[1], mask_high);
    iv[2] = xia_shuffle(*g.b, m[2], m[3], mask_low);
    iv[3] = xia_shuffle(*g.b, m[2], m[3], mask_high);
    out: [4] Value_Id;
    for i: 0..3 out[i] = xia_shuffle(*g.b, iv[i / 2], iv[i / 2 + 2], lh[i % 2]);
    if vt.n == 16 {
        for i: 0..3 tm.*[i] = out[i];
        return;
    }
    xia_reorder_sub_vector(g, vt, tm, out, array_view(XIA_CONCAT, 0, 16), num_elm, 4);
}

// createShuffleStride
xia_create_shuffle_stride :: (vt: Xia_Vt, stride: s64) -> [..] s32 {
    m := xia_mask();
    vf := vt.n;
    lanes := max(xia_vt_size(vt) / 128, 1);
    lane_size := vf / lanes;
    for lane: 0..lanes - 1 for i: 0..lane_size - 1 array_add(*m, cast(s32) ((i * stride) % lane_size + lane_size * lane));
    return m;
}

// setGroupSize
xia_set_group_size :: (vt: Xia_Vt) -> [3] s64 {
    r: [3] s64;
    vf := vt.n / max(xia_vt_size(vt) / 128, 1);
    first := 0;
    for i: 0..2 {
        // std::ceil((VF - FirstGroupElement) / 3.0)
        d := vf - first;
        gs := ifx d >= 0 then (d + 2) / 3 else -((-d) / 3);
        r[i] = gs;
        first = (gs * 3 + first) % vf;
    }
    return r;
}

// DecodePALIGNRMask(VT, Imm, ShuffleMask, AlignDirection, Unary)
xia_decode_palignr_mask :: (vt: Xia_Vt, imm_in: s64, align_direction := true, unary := false) -> [..] s32 {
    m := xia_mask();
    num_elts := cast(u32) vt.n;
    num_lanes := cast(u32) max(xia_vt_size(vt) / 128, 1);
    lane_elts := num_elts / num_lanes;
    imm := cast(u32) imm_in;
    imm = ifx align_direction then imm else lane_elts - imm;
    offset := imm * cast(u32) (vt.bits / 8);
    l: u32 = 0;
    while l != num_elts {
        for i: 0..lane_elts - 1 {
            base := i + offset;
            if base >= lane_elts base = ifx unary then base % lane_elts else base + num_elts - lane_elts;
            array_add(*m, cast,no_check(s32) (base + l));
        }
        l += lane_elts;
    }
    return m;
}

// concatSubVector
xia_concat_sub_vector :: (g: *Xia_Group, vec: *[6] Value_Id, in_vec: [] Value_Id, vec_elems: s64) {
    if vec_elems == 16 {
        for i: 0..2 vec.*[i] = in_vec[i];
        return;
    }
    for j: 0..vec_elems / 32 - 1 for i: 0..2
        vec.*[i + j * 3] = xia_shuffle(*g.b, in_vec[j * 6 + i], in_vec[j * 6 + i + 3], array_view(XIA_CONCAT, 0, 32));
    if vec_elems == 32 return;
    for i: 0..2 vec.*[i] = xia_shuffle(*g.b, vec.*[i], vec.*[i + 3], XIA_CONCAT);
}

// deinterleave8bitStride3
xia_deinterleave8bit_stride3 :: (g: *Xia_Group, in_vec: [] Value_Id, tm: *[..] Value_Id, vec_elems: s64) {
    xia_resize(tm, 3);
    st := vtype(g.shuffles[0]);
    vt := Xia_Vt.{cast(s64) type_count(st), cast(s64) dl_type_size_bits(type_elem(st))};
    vpshuf := xia_create_shuffle_stride(vt, 3);
    gs := xia_set_group_size(vt);
    vpalign: [2] [..] s32;
    for i: 0..1 vpalign[i] = xia_decode_palignr_mask(vt, gs[2 - i], false);
    vpalign2 := xia_decode_palignr_mask(vt, gs[2] + gs[1], true, true);
    vpalign3 := xia_decode_palignr_mask(vt, gs[1], true, true);
    vec: [6] Value_Id;
    tv: [3] Value_Id;
    xia_concat_sub_vector(g, *vec, in_vec, vec_elems);
    for i: 0..2 vec[i] = xia_shuffle(*g.b, vec[i], NONE, vpshuf);
    for i: 0..2 tv[i] = xia_shuffle(*g.b, vec[(i + 2) % 3], vec[i], vpalign[0]);
    for i: 0..2 vec[i] = xia_shuffle(*g.b, tv[(i + 1) % 3], tv[i], vpalign[1]);
    temp_vec := xia_shuffle(*g.b, vec[1], NONE, vpalign3);
    tm.*[0] = xia_shuffle(*g.b, vec[0], NONE, vpalign2);
    tm.*[1] = ifx vec_elems == 8 then vec[2] else temp_vec;
    tm.*[2] = ifx vec_elems == 8 then temp_vec else vec[2];
}

// group2Shuffle
xia_group2_shuffle :: (vt: Xia_Vt, mask: [3] s64) -> [..] s32 {
    out := xia_mask();
    index_group: [3] s64;
    index := 0;
    vf := vt.n;
    lane := ifx xia_vt_size(vt) / 128 > 0 then xia_vt_size(vt) / 128 else 1;
    for i: 0..2 {
        index_group[(index * 3) % (vf / lane)] = index;
        index += mask[i];
    }
    for i: 0..vf / lane - 1 {
        array_add(*out, cast(s32) index_group[i % 3]);
        index_group[i % 3] += 1;
    }
    return out;
}

// interleave8bitStride3
xia_interleave8bit_stride3 :: (g: *Xia_Group, in_vec: [] Value_Id, tm: *[..] Value_Id, vec_elems: s64) {
    xia_resize(tm, 3);
    vt := Xia_Vt.{vec_elems, 8};
    gs := xia_set_group_size(vt);
    vpalign: [3] [..] s32;
    for i: 0..2 vpalign[i] = xia_decode_palignr_mask(vt, gs[i]);
    vpalign2 := xia_decode_palignr_mask(vt, gs[1] + gs[2], false, true);
    vpalign3 := xia_decode_palignr_mask(vt, gs[1], false, true);
    vec: [3] Value_Id;
    tv: [3] Value_Id;
    vec[0] = xia_shuffle(*g.b, in_vec[0], NONE, vpalign2);
    vec[1] = xia_shuffle(*g.b, in_vec[1], NONE, vpalign3);
    vec[2] = in_vec[2];
    for i: 0..2 tv[i] = xia_shuffle(*g.b, vec[i], vec[(i + 2) % 3], vpalign[1]);
    for i: 0..2 vec[i] = xia_shuffle(*g.b, tv[i], tv[(i + 1) % 3], vpalign[2]);
    vpshuf := xia_group2_shuffle(vt, gs);
    xia_reorder_sub_vector(g, vt, tm, vec, vpshuf, vt.n, 3);
}

// transpose_4x4
xia_transpose_4x4 :: (g: *Xia_Group, m: [] Value_Id, tm: *[..] Value_Id) {
    assert(m.count == 4);
    xia_resize(tm, 4);
    v1 := xia_shuffle(*g.b, m[0], m[2], s32.[0, 1, 4, 5]);
    v2 := xia_shuffle(*g.b, m[1], m[3], s32.[0, 1, 4, 5]);
    v3 := xia_shuffle(*g.b, m[0], m[2], s32.[2, 3, 6, 7]);
    v4 := xia_shuffle(*g.b, m[1], m[3], s32.[2, 3, 6, 7]);
    tm.*[0] = xia_shuffle(*g.b, v1, v2, s32.[0, 4, 2, 6]);
    tm.*[2] = xia_shuffle(*g.b, v3, v4, s32.[0, 4, 2, 6]);
    tm.*[1] = xia_shuffle(*g.b, v1, v2, s32.[1, 5, 3, 7]);
    tm.*[3] = xia_shuffle(*g.b, v3, v4, s32.[1, 5, 3, 7]);
}

// lowerIntoOptimizedSequence
xia_lower_into_optimized_sequence :: (g: *Xia_Group) -> bool {
    tv: [..] Value_Id; tv.allocator = temp;
    shuffle_ty := vtype(g.shuffles[0]);
    if inst_op(g.inst) == .LOAD {
        num_sub := cast(u32) (type_count(vtype(g.inst)) / g.factor);
        if num_sub == {
            case 4; #through; case 8; #through; case 16; #through; case 32; #through; case 64;
                if cast(u32) type_count(shuffle_ty) != num_sub return false;
            case; return false;
        }
        dec := xia_decompose(g, g.inst, g.factor, shuffle_ty);
        if num_sub == 4 xia_transpose_4x4(g, dec, *tv);
        else xia_deinterleave8bit_stride3(g, dec, *tv, num_sub);
        for s, i: g.shuffles rauw_with_metadata(s, tv[g.indices[i]]);
        return true;
    }
    elt := type_elem(shuffle_ty);
    num_sub := cast(u32) (type_count(shuffle_ty) / g.factor);
    dec := xia_decompose(g, g.shuffles[0], g.factor, type_vector(num_sub, elt, false));
    if num_sub == {
        case 4; xia_transpose_4x4(g, dec, *tv);
        case 8; xia_interleave8bit_stride4_vf8(g, dec, *tv);
        case 16; #through; case 32; #through; case 64;
            if g.factor == 4 xia_interleave8bit_stride4(g, dec, *tv, num_sub);
            if g.factor == 3 xia_interleave8bit_stride3(g, dec, *tv, num_sub);
        case; return false;
    }
    wide := xia_concatenate_vectors(*g.b, tv);
    irb_store(*g.b, wide, op(g.inst, 1), inst(g.inst).align);
    return true;
}

// X86TargetLowering::lowerInterleavedLoad
x86_lower_interleaved_load :: (st: *X86_Lowering, load: Value_Id, shuffles: [] Value_Id, indices: [] u32, factor: u32) -> bool {
    if inst_op(load) != .LOAD return false;
    g: Xia_Group;
    g.inst = load; g.shuffles = shuffles; g.indices = indices; g.factor = factor; g.st = st;
    irb_set_before(*g.b, load);
    return xia_is_supported(*g) && xia_lower_into_optimized_sequence(*g);
}

// X86TargetLowering::lowerInterleavedStore
x86_lower_interleaved_store :: (st: *X86_Lowering, store: Value_Id, svi: Value_Id, factor: u32) -> bool {
    if inst_op(store) != .STORE return false;
    mask := shuf_mask(svi);
    indices := NewArray(factor, u32,, allocator = temp);
    for k: 0..cast(s64) factor - 1 indices[k] = cast,no_check(u32) mask[k];
    shuffles := NewArray(1, Value_Id,, allocator = temp); shuffles[0] = svi;
    g: Xia_Group;
    g.inst = store; g.shuffles = shuffles; g.indices = indices; g.factor = factor; g.st = st;
    irb_set_before(*g.b, store);
    return xia_is_supported(*g) && xia_lower_into_optimized_sequence(*g);
}
