// Float2Int: port of llvm/lib/Transforms/Scalar/Float2Int.cpp (findRoots, walkBackwards, calcRange, walkForwards,
// validateAndTransform, convert, cleanup). EquivalenceClasses<Instruction*> (llvm/include/llvm/ADT/
// EquivalenceClasses.h) is `F2i.ec_*`: Members in insertion order, each class a leader-headed list (union appends
// the second list to the first).

f2i_cl: struct {
    max_integer_bw: u32 = 64;   // -float2int-max-integer-bw
};

F2i :: struct {
    seen_keys: [..] Value_Id;                 // MapVector<Instruction*, ConstantRange> SeenInsts
    seen_vals: [..] Const_Range;
    seen_idx: Table(Value_Id, s64);
    roots: [..] Value_Id;                     // SmallSetVector Roots
    root_set: Table(Value_Id, bool);
    ec_members: [..] Value_Id;                // EquivalenceClasses: Members (insertion order)
    ec_idx: Table(Value_Id, s32);
    ec_leader: [..] s32;
    ec_next: [..] s32;                        // -1 = end of list
    ec_end: [..] s32;                         // leaders: last element of the list
    conv_keys: [..] Value_Id;                 // MapVector<Instruction*, Value*> ConvertedInsts
    conv_vals: [..] Value_Id;
    conv_idx: Table(Value_Id, s64);
}

f2i_map_fcmp_pred :: (p: u8) -> u8 {
    if p == {
        case FCMP_OEQ; #through; case FCMP_UEQ; return ICMP_EQ;
        case FCMP_OGT; #through; case FCMP_UGT; return ICMP_SGT;
        case FCMP_OGE; #through; case FCMP_UGE; return ICMP_SGE;
        case FCMP_OLT; #through; case FCMP_ULT; return ICMP_SLT;
        case FCMP_OLE; #through; case FCMP_ULE; return ICMP_SLE;
        case FCMP_ONE; #through; case FCMP_UNE; return ICMP_NE;
    }
    return 255;   // BAD_ICMP_PREDICATE
}

f2i_bad :: () -> Const_Range { return cr_full(f2i_cl.max_integer_bw + 1); }
f2i_unknown :: () -> Const_Range { return cr_empty(f2i_cl.max_integer_bw + 1); }
f2i_validate :: (r: Const_Range) -> Const_Range { if cr_bits(r) > f2i_cl.max_integer_bw + 1 return f2i_bad(); return r; }

f2i_seen :: (s: *F2i, i: Value_Id, r: Const_Range) {
    found, idx := table_find(*s.seen_idx, i);
    if found { s.seen_vals[idx] = r; return; }
    table_set(*s.seen_idx, i, s.seen_keys.count);
    array_add(*s.seen_keys, i);
    array_add(*s.seen_vals, r);
}
f2i_seen_get :: (s: *F2i, i: Value_Id) -> (bool, Const_Range) {
    found, idx := table_find(*s.seen_idx, i);
    if !found { r: Const_Range; return false, r; }
    return true, s.seen_vals[idx];
}

f2i_ec_insert :: (s: *F2i, v: Value_Id) -> s32 {
    found, k := table_find(*s.ec_idx, v);
    if found return k;
    k = cast(s32) s.ec_members.count;
    table_set(*s.ec_idx, v, k);
    array_add(*s.ec_members, v);
    array_add(*s.ec_leader, k);
    array_add(*s.ec_next, -1);
    array_add(*s.ec_end, k);
    return k;
}
f2i_ec_find :: (s: *F2i, k: s32) -> s32 {
    x := k;
    while s.ec_leader[x] != x x = s.ec_leader[x];
    s.ec_leader[k] = x;
    return x;
}
f2i_ec_union :: (s: *F2i, a: Value_Id, b: Value_Id) {
    ka := f2i_ec_insert(s, a); kb := f2i_ec_insert(s, b);
    l1 := f2i_ec_find(s, ka); l2 := f2i_ec_find(s, kb);
    if l1 == l2 return;
    s.ec_next[s.ec_end[l1]] = l2;
    s.ec_end[l1] = s.ec_end[l2];
    s.ec_leader[l2] = l1;
}

f2i_find_roots :: (s: *F2i, f: Value_Id, dt: *Dom_Tree) {
    for bb: fn_blocks(f) {
        if !dt_is_reachable_from_entry(dt, bb) continue;
        for i: block_insts(bb) {
            if is_vector_type(vtype(i)) continue;
            o := inst_op(i);
            add := o == .FPTOUI || o == .FPTOSI || (o == .FCMP && f2i_map_fcmp_pred(inst_pred(i)) != 255);
            if add && !table_contains(*s.root_set, i) { table_set(*s.root_set, i, true); array_add(*s.roots, i); }
        }
    }
}

f2i_walk_backwards :: (s: *F2i) {
    wl: [..] Value_Id; wl.allocator = temp;
    for s.roots array_add(*wl, it);
    while wl.count {
        i := pop(*wl);
        if table_contains(*s.seen_idx, i) continue;
        o := inst_op(i);
        if o == .UITOFP || o == .SITOFP {
            bw := type_bits(vtype(op(i, 0)));   // getPrimitiveSizeInBits
            f2i_seen(s, i, f2i_validate(cr_cast_op(cr_full(bw), o, f2i_cl.max_integer_bw + 1)));
            continue;
        }
        if o == .FNEG || o == .FADD || o == .FSUB || o == .FMUL || o == .FPTOUI || o == .FPTOSI || o == .FCMP f2i_seen(s, i, f2i_unknown());
        else f2i_seen(s, i, f2i_bad());
        for k: 0..cast(s64) nops(i) - 1 {
            v := op(i, cast(u32) k);
            if is_inst(v) {
                f2i_ec_union(s, i, v);
                _, r := f2i_seen_get(s, i);
                if !cr_eq(r, f2i_bad()) array_add(*wl, v);
            } else if vkind(v) != .C_FP {
                f2i_seen(s, i, f2i_bad());
            }
        }
    }
}

f2i_calc_range :: (s: *F2i, i: Value_Id) -> (bool, Const_Range) {
    op_ranges: [..] Const_Range; op_ranges.allocator = temp;
    bw := f2i_cl.max_integer_bw + 1;
    for k: 0..cast(s64) nops(i) - 1 {
        v := op(i, cast(u32) k);
        if is_inst(v) {
            found, r := f2i_seen_get(s, v);
            assert(found, "def not seen before use!");
            if cr_eq(r, f2i_unknown()) return false, r;
            array_add(*op_ranges, r);
        } else if vkind(v) == .C_FP {
            kind := type_kind(vtype(v));
            w := const_fp_value(v);
            d := fp_decode(kind, w);
            if d.cat == .INF || d.cat == .NAN || (d.cat == .ZERO && d.neg && is_fp_math_inst(i) && (inst_fmf(i) & FMF_NSZ) == 0) return true, f2i_bad();
            nw, st := fp_round_to_integral(kind, w, RM_NEAREST_TIES_TO_EVEN);
            same := nw.count == w.count;
            if same for nw if it != w[it_index] { same = false; break; }
            if st != 0 || !same return true, f2i_bad();
            iw, ist, exact := fp_to_integer_rm(kind, w, bw, true, RM_NEAREST_TIES_TO_EVEN);
            if ist == 0 || ist == .INEXACT array_add(*op_ranges, cr_single(ap_from_words(bw, iw)));
            else return true, f2i_bad();
        } else assert(false, "Should have already marked this as badRange!");
    }
    o := inst_op(i);
    if o == {
        case .FNEG; return true, cr_sub(cr_single(ap_zero(cr_bits(op_ranges[0]))), op_ranges[0]);
        case .FADD; return true, cr_binary_op(op_ranges[0], .ADD, op_ranges[1]);
        case .FSUB; return true, cr_binary_op(op_ranges[0], .SUB, op_ranges[1]);
        case .FMUL; return true, cr_binary_op(op_ranges[0], .MUL, op_ranges[1]);
        case .FPTOUI; #through;
        case .FPTOSI; return true, cr_cast_op(op_ranges[0], o, bw);
        case .FCMP; return true, cr_union(op_ranges[0], op_ranges[1]);
    }
    assert(false, "Should have been handled in walkForwards!");
    return true, f2i_bad();
}

f2i_walk_forwards :: (s: *F2i) {
    // std::deque: pop_back, push_front
    dq: [..] Value_Id; dq.allocator = temp;
    head := 0;   // dq[head..] is the deque; push_front writes at head - 1 (grow on the left by rebuilding)
    for s.seen_keys if cr_eq(s.seen_vals[it_index], f2i_unknown()) array_add(*dq, it);
    while dq.count > head {
        i := dq[dq.count - 1];
        dq.count -= 1;
        ok, r := f2i_calc_range(s, i);
        if ok { f2i_seen(s, i, r); continue; }
        if head == 0 {
            // make room on the left
            n := dq.count;
            grow := max(n, 8);
            nd: [..] Value_Id; nd.allocator = temp;
            array_resize(*nd, grow + n);
            for x: 0..n-1 nd[grow + x] = dq[x];
            dq = nd; head = grow;
        }
        head -= 1;
        dq[head] = i;
    }
}

f2i_convert :: (s: *F2i, i: Value_Id, to_ty: Type_Id) -> Value_Id {
    found, idx := table_find(*s.conv_idx, i);
    if found return s.conv_vals[idx];
    o := inst_op(i);
    new_ops: [..] Value_Id; new_ops.allocator = temp;
    for k: 0..cast(s64) nops(i) - 1 {
        v := op(i, cast(u32) k);
        if o == .UITOFP || o == .SITOFP array_add(*new_ops, v);
        else if is_inst(v) array_add(*new_ops, f2i_convert(s, v, to_ty));
        else if vkind(v) == .C_FP {
            iw, st, exact := fp_to_integer_rm(type_kind(vtype(v)), const_fp_value(v), type_bits(to_ty), true, RM_NEAREST_TIES_TO_EVEN);
            array_add(*new_ops, const_int_words(to_ty, iw));
        } else assert(false, "Unhandled operand type?");
    }
    b: Irb;
    irb_set_before(*b, i);
    nv: Value_Id;
    if o == {
        case .FPTOUI; nv = irb_zext_or_trunc(*b, new_ops[0], vtype(i));
        case .FPTOSI; nv = f2i_sext_or_trunc(*b, new_ops[0], vtype(i));
        case .FCMP; nv = irb_icmp(*b, f2i_map_fcmp_pred(inst_pred(i)), new_ops[0], new_ops[1], vname(i));
        case .UITOFP; nv = irb_zext_or_trunc(*b, new_ops[0], to_ty);
        case .SITOFP; nv = f2i_sext_or_trunc(*b, new_ops[0], to_ty);
        case .FNEG; nv = irb_binop(*b, .SUB, const_null_value(vtype(new_ops[0])), new_ops[0], vname(i));   // CreateNeg
        case .FADD; nv = irb_binop(*b, .ADD, new_ops[0], new_ops[1], vname(i));
        case .FSUB; nv = irb_binop(*b, .SUB, new_ops[0], new_ops[1], vname(i));
        case .FMUL; nv = irb_binop(*b, .MUL, new_ops[0], new_ops[1], vname(i));
        case; assert(false, "Unhandled instruction!");
    }
    if table_contains(*s.root_set, i) rauw_with_metadata(i, nv);
    table_set(*s.conv_idx, i, s.conv_keys.count);
    array_add(*s.conv_keys, i);
    array_add(*s.conv_vals, nv);
    return nv;
}
// IRBuilder::CreateSExtOrTrunc
f2i_sext_or_trunc :: (b: *Irb, v: Value_Id, t: Type_Id) -> Value_Id {
    vb := type_int_width(vtype(v)); tb := type_int_width(t);
    if vb < tb return irb_cast(b, .SEXT, v, t);
    if vb > tb return irb_cast(b, .TRUNC, v, t);
    return v;
}

f2i_validate_and_transform :: (s: *F2i) -> bool {
    made_change := false;
    for e: 0..cast(s32) s.ec_members.count - 1 {
        if s.ec_leader[e] != e continue;   // isLeader
        r := cr_empty(f2i_cl.max_integer_bw + 1);
        fail := false;
        converted_to_ty: Type_Id = NONE;
        m := e;
        while m >= 0 {
            i := s.ec_members[m];
            defer m = s.ec_next[m];
            found, sr := f2i_seen_get(s, i);
            if !found continue;
            r = cr_union(r, sr);
            if !table_contains(*s.root_set, i) {
                if converted_to_ty == NONE converted_to_ty = vtype(i);
                u := ir.v_first_use[i];
                while u != NONE {
                    usr := ir.u_user[u];
                    if !is_inst(usr) || !table_contains(*s.seen_idx, usr) { fail = true; break; }
                    u = ir.u_next[u];
                }
            }
            if fail break;
        }
        if fail || cr_is_full_set(r) || cr_is_sign_wrapped_set(r) continue;
        assert(converted_to_ty != NONE, "Must have set the convertedtoty by this point!");
        min_bw := cr_min_signed_bits(r) + 1;
        prec := fp_semantics(type_kind(converted_to_ty));
        if cast(s64) min_bw > cast(s64) prec - 1 continue;
        ty := ic_smallest_legal_int_type(min_bw);
        if ty == NONE {
            if min_bw <= 32 ty = type_int(32);
            else if min_bw <= 64 ty = type_int(64);
            else continue;
        }
        m = e;
        while m >= 0 { f2i_convert(s, s.ec_members[m], ty); m = s.ec_next[m]; }
        made_change = true;
    }
    return made_change;
}

float2int_run :: (f: Value_Id) -> Preserved {
    dt := get_domtree(f);
    s: F2i;
    s.seen_keys.allocator = temp; s.seen_vals.allocator = temp; s.seen_idx.allocator = temp;
    s.roots.allocator = temp; s.root_set.allocator = temp;
    s.ec_members.allocator = temp; s.ec_idx.allocator = temp; s.ec_leader.allocator = temp; s.ec_next.allocator = temp; s.ec_end.allocator = temp;
    s.conv_keys.allocator = temp; s.conv_vals.allocator = temp; s.conv_idx.allocator = temp;
    f2i_find_roots(*s, f, dt);
    f2i_walk_backwards(*s);
    f2i_walk_forwards(*s);
    if !f2i_validate_and_transform(*s) return PRESERVE_ALL;
    k := s.conv_keys.count;
    while k > 0 { k -= 1; erase_inst_with_metadata(s.conv_keys[k]); }
    return preserved_cfg();
}
