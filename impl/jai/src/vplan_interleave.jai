// Interleave groups in VPlan: VPInterleaveRecipe (constructor, computeCost, execute with createBitMaskForGaps /
// interleaveVectors / concatenateVectors), VPlanTransforms::createInterleaveGroups and the analysis part of
// narrowInterleaveGroups (a plan it would narrow fails loudly).
// Ported from llvm/lib/Transforms/Vectorize/VPlanRecipes.cpp, VPlanTransforms.cpp and llvm/lib/Analysis/VectorUtils.cpp
// (LLVM 23.1.5).

// The InterleavedAccessInfo of the loop being vectorized (VPInterleaveRecipe::IG points into it)
lv_cur_iai: *Iai;
vp_ig :: (r: Vp_Rec) -> *Ig { return *lv_cur_iai.groups[vr(r).ig]; }

// VPInterleaveRecipe(IG, Addr, StoredValues, Mask, NeedsMaskForGaps, MD, DL)
vp_new_interleave :: (ig: s32, addr: Vp_Val, stored: [] Vp_Val, mask: Vp_Val, needs_mask_for_gaps: bool, md: [] Vp_Md, dl: Md_Id) -> Vp_Rec {
    r := vp_new_recipe(.INTERLEAVE, .[addr], dl);
    g := *lv_cur_iai.groups[ig];
    vr(r).ig = ig; vr(r).ir_inst = g.insert_pos; vr(r).needs_mask_for_gaps = needs_mask_for_gaps;
    for md array_add(*vr(r).md, it);
    if stored.count == 0 {
        for m: ig_members(g) vp_add_multi_def_value(r, m, vtype(m));
    } else {
        for stored vp_add_operand(r, it);
    }
    if mask != NONE { vr(r).masked = true; vp_add_operand(r, mask); }
    return r;
}
vp_interleave_stored_values :: (r: Vp_Rec) -> [..] Vp_Val {
    out: [..] Vp_Val; out.allocator = temp;
    n := vp_interleave_num_store_operands(r);
    for k: 1..n array_add(*out, vp_op(r, k));
    return out;
}
vp_interleave_mask :: (r: Vp_Rec) -> Vp_Val { if vr(r).masked return vp_op(r, vp_nops(r) - 1); return NONE; }

// VPIRMetadata::intersect
vp_md_intersect :: (a: *[..] Vp_Md, b: [] Vp_Md) {
    out: [..] Vp_Md; out.allocator = temp;
    for x: a.* for y: b if x.kind == y.kind && x.node == y.node { array_add(*out, x); break; }
    a.count = 0;
    for out array_add(a, it);
}

// VPlanTransforms::createInterleaveGroups
vp_create_interleave_groups :: (groups: [] s32, epilogue_allowed: bool) {
    if groups.count == 0 return;
    member_to_recipe: Table(Value_Id, Vp_Rec); member_to_recipe.allocator = temp;
    for bb: vp_blocks_only_basic(vp_depth_first_shallow(vp_entry_basic_block(vp_vector_loop_region())))
        for r: vp_block_recipes(bb) if vp_is_widen_memory_kind(vr(r).kind) table_set(*member_to_recipe, vr(r).ir_inst, r);
    lookup :: (t: *Table(Value_Id, Vp_Rec), i: Value_Id) -> Vp_Rec { found, r := table_find(t, i); return ifx found then r else NONE; }
    dt := vp_dt_build();
    for gid: groups {
        g := *lv_cur_iai.groups[gid];
        start: Vp_Rec = NONE; start_member: Value_Id = NONE;
        for m: ig_members(g) { r := lookup(*member_to_recipe, m); if r != NONE { start_member = m; start = r; break; } }
        if start_member == NONE continue;
        md: [..] Vp_Md; md.allocator = temp;
        for vr(start).md array_add(*md, it);
        stored: [..] Vp_Val; stored.allocator = temp;
        for k: 0..g.factor - 1 {
            mi := ig_get_member(g, k);
            if mi == NONE continue;
            mr := lookup(*member_to_recipe, mi);
            if mr != NONE {
                if vr(mr).kind == .WIDEN_STORE array_add(*stored, vp_op(mr, 1));
                vp_md_intersect(*md, vr(mr).md);
            } else {
                vp_md_intersect(*md, vp_metadata_to_propagate(mi));
            }
        }
        needs_mask_for_gaps := (ig_requires_scalar_epilogue(g) && !epilogue_allowed) || (stored.count > 0 && !ig_is_full(g));
        ir_ip := g.insert_pos;
        ip := lookup(*member_to_recipe, ir_ip);
        if ip == NONE {
            assert(vr(start).kind == .WIDEN_LOAD, "Dead member in non-load group?");
            ip = start;
            for m: ig_members(g) {
                mr := lookup(*member_to_recipe, m);
                if mr != NONE && vp_dt_properly_dominates(*dt, mr, ip) ip = mr;
            }
            ir_ip = vr(ip).ir_inst;
        }
        nw: u32 = 0;
        gp := strip_pointer_casts(load_store_pointer_operand(ir_ip));
        if is_inst(gp) && inst_op(gp) == .GEP nw = gep_nowrap_flags(gp) & ~cast(u32) F_GEP_NUW;
        addr := vp_op(start, 0);
        ad := vp_def(addr);
        if ig_index_of(g, start_member) != 0 || (ad != NONE && !vp_dt_properly_dominates(*dt, ad, ip)) {
            idx := ig_index_of(g, ir_ip);
            assert(idx != 0, "index of insert position shouldn't be zero");
            off := cast(s64) dl_type_alloc_size(load_store_type(ir_ip)) * cast(s64) idx;
            offv := vp_const_int_ap(ap_from_s64(32, -off));
            b := vpb_before(ip);
            addr = vr(vpb_no_wrap_ptr_add(*b, vp_op(ip, 0), offv, nw)).def;
        }
        if g.reverse {
            rp := vp_new_single_def(.VECTOR_END_POINTER, .[addr, vpl.vf], vp_scalar_type(addr), NONE, vr(ip).dl);
            vr(rp).src_elt_ty = load_store_type(ir_ip); vr(rp).stride = -cast(s64) g.factor; vr(rp).flags = vpf_gep(nw);
            vp_insert_before(rp, ip);
            addr = vr(rp).def;
        }
        mask := ifx vr(ip).masked then vp_op(ip, vp_nops(ip) - 1) else NONE;
        vpig := vp_new_interleave(gid, addr, stored, mask, needs_mask_for_gaps, md, vr(ip).dl);
        vp_insert_before(vpig, ip);
        j := 0;
        for k: 0..g.factor - 1 {
            m := ig_get_member(g, k);
            if m == NONE continue;
            mr := lookup(*member_to_recipe, m);
            if type_kind(vtype(m)) != .VOID {
                if mr != NONE vp_rauw(vr(mr).def, vr(vpig).defs[j]);
                j += 1;
            }
            if mr != NONE vp_erase_recipe(mr);
        }
    }
}

// VPInterleaveBase::computeCost
vp_interleave_cost :: (c: *Vp_Cost_Ctx, r: Vp_Rec, vf: Ec) -> Lc {
    g := vp_ig(r);
    ip := vr(r).ir_inst;
    ip_idx := 0;
    for k: 0..g.factor - 1 {
        m := ig_get_member(g, k);
        if m == NONE continue;
        if m == ip break;
        ip_idx += 1;
    }
    stored := vp_interleave_stored_values(r);
    valv := ifx vr(r).defs.count > 0 then vr(r).defs[ip_idx] else stored[ip_idx];
    val_ty := vp_scalar_type(valv);
    vty := lv_to_vector_ty(val_ty, vf);
    as := ptr_addrspace(vp_scalar_type(vp_op(r, 0)));
    wide := type_vector(vf.n * g.factor, val_ty, vf.scalable);
    indices: [..] u32; indices.allocator = temp;
    for k: 0..g.factor - 1 if ig_get_member(g, k) != NONE array_add(*indices, k);
    cost := lcv(tti_interleaved_memory_op_cost(c.tti, inst_op(ip), wide, g.factor, indices, g.align, as, c.kind,
                                               vr(r).masked, vr(r).needs_mask_for_gaps));
    if !g.reverse return cost;
    return lc_add(cost, lc_mul(lv_tti_shuffle(c.tti, SK_REVERSE, vty, c.kind, 0), g.keys.count));
}

// InterleaveGroup::addMetadata: propagateMetadata over the members in DenseMap<int32_t, ...> iteration order
vp_ig_add_metadata :: (g: *Ig, i: Value_Id) {
    Kv :: struct { bucket: u32; v: Value_Id; }
    kv: [..] Kv; kv.allocator = temp;
    nb: u32 = 64;
    while cast(u32) g.keys.count * 4 >= nb * 3 nb *= 2;
    for g.keys array_add(*kv, .{(cast,no_check(u32) (it * 37)) & (nb - 1), g.vals[it_index]});
    // no collisions: 37 is odd, so k * 37 is a bijection modulo the bucket count for the small key range
    for a: 0..kv.count - 1 for b: a + 1..kv.count - 1 if kv[b].bucket < kv[a].bucket { t := kv[a]; kv[a] = kv[b]; kv[b] = t; }
    vl: [..] Value_Id; vl.allocator = temp;
    for kv array_add(*vl, it.v);
    slp_propagate_metadata(i, vl);
}

// CreateBitOrPointerCast (with createBitOrPointerCast's two-step int fallback)
vs_bit_or_pointer_cast :: (s: *Vp_State, v: Value_Id, dst: Type_Id) -> Value_Id {
    src := vtype(v);
    if src == dst return v;
    se := type_elem(src); de := type_elem(dst);
    one :: (s: *Vp_State, v: Value_Id, dst: Type_Id) -> Value_Id {
        if vtype(v) == dst return v;
        se := scalar_type(vtype(v)); de := scalar_type(dst);
        if is_ptr_type(se) && is_int_type(de) return irb_cast(*s.b, .PTRTOINT, v, dst);
        if is_int_type(se) && is_ptr_type(de) return irb_cast(*s.b, .INTTOPTR, v, dst);
        return irb_cast(*s.b, .BITCAST, v, dst);
    }
    if is_bit_or_noop_pointer_castable(se, de) return one(s, v, dst);
    it := type_vector(type_count(dst), type_int(dl_type_size_bits(se)), false);
    return one(s, one(s, v, it), dst);
}
vs_vector_reverse :: (s: *Vp_State, v: Value_Id) -> Value_Id {
    n := type_count(vtype(v));
    mask := NewArray(cast(s64) n, u32,, allocator = temp);
    for k: 0..n - 1 mask[k] = cast(u32) (n - 1 - k);
    return irb_shuffle(*s.b, v, NONE, mask, "reverse");
}
// concatenateVectors
vs_concatenate_vectors :: (s: *Vp_State, vecs: [] Value_Id) -> Value_Id {
    res: [..] Value_Id; res.allocator = temp;
    for vecs array_add(*res, it);
    while res.count > 1 {
        tmp: [..] Value_Id; tmp.allocator = temp;
        i := 0;
        while i < res.count - 1 {
            v0 := res[i]; v1 := res[i + 1];
            n1 := cast(u32) type_count(vtype(v0)); n2 := cast(u32) type_count(vtype(v1));
            if n1 > n2 {
                m := NewArray(n1, u32,, allocator = temp);
                for k: 0..n1 - 1 m[k] = ifx k < n2 then k else 0xFFFF_FFFF;
                v1 = irb_shuffle(*s.b, v1, NONE, m);
            }
            cm := NewArray(n1 + n2, u32,, allocator = temp);
            for k: 0..n1 + n2 - 1 cm[k] = k;
            array_add(*tmp, irb_shuffle(*s.b, v0, v1, cm));
            i += 2;
        }
        if res.count % 2 != 0 array_add(*tmp, res[res.count - 1]);
        res = tmp;
    }
    return res[0];
}

// VPInterleaveRecipe::execute
vp_interleave_execute :: (s: *Vp_State, r: Vp_Rec) {
    g := vp_ig(r);
    ip := g.insert_pos;
    sty := load_store_type(ip);
    factor := g.factor;
    vf := cast(u32) s.vf.n;
    if s.vf.scalable vp_unported("scalable interleave groups");
    vecty := type_vector(cast(u64) (vf * factor), sty, false);
    res_addr := vs_get_lane(s, vp_op(r, 0), 0);
    if vr(r).masked || vr(r).needs_mask_for_gaps vp_unported("masked interleave groups");
    if inst_op(ip) == .LOAD {
        ld := irb_load(*s.b, vecty, res_addr, g.align, false, "wide.vec");
        vp_apply_metadata(r, ld);
        vp_ig_add_metadata(g, ld);
        j := 0;
        for k: 0..factor - 1 {
            m := ig_get_member(g, k);
            if m == NONE continue;
            mask := NewArray(vf, u32,, allocator = temp);
            for e: 0..vf - 1 mask[e] = k + e * factor;
            sv := irb_shuffle(*s.b, ld, NONE, mask, "strided.vec");
            if vtype(m) != sty sv = vs_bit_or_pointer_cast(s, sv, type_vector(cast(u64) vf, vtype(m), false));
            if g.reverse sv = vs_vector_reverse(s, sv);
            vs_set(s, vr(r).defs[j], sv);
            j += 1;
        }
        return;
    }
    sub_vt := type_vector(cast(u64) vf, sty, false);
    stored := vp_interleave_stored_values(r);
    vecs: [..] Value_Id; vecs.allocator = temp;
    si := 0;
    for k: 0..factor - 1 {
        m := ig_get_member(g, k);
        if m == NONE { array_add(*vecs, const_poison(sub_vt)); continue; }
        sv := vs_get(s, stored[si]);
        si += 1;
        if g.reverse sv = vs_vector_reverse(s, sv);
        if vtype(sv) != sub_vt sv = vs_bit_or_pointer_cast(s, sv, sub_vt);
        array_add(*vecs, sv);
    }
    wide := vs_concatenate_vectors(s, vecs);
    imask := NewArray(vf * factor, u32,, allocator = temp);
    for i: 0..vf - 1 for jj: 0..factor - 1 imask[i * factor + jj] = jj * vf + i;
    ivec := irb_shuffle(*s.b, wide, NONE, imask, "interleaved.vec");
    st := irb_store(*s.b, ivec, res_addr, g.align);
    vp_apply_metadata(r, st);
    vp_ig_add_metadata(g, st);
}

// canNarrowLoad
vp_can_narrow_load :: (wide_member0: Vp_Rec, op_idx: s64, opv: Vp_Val, idx: s64, scalable: bool) -> bool {
    m0op := vp_op(wide_member0, op_idx);
    if vp_is_defined_outside_loop_regions(m0op) {
        if m0op == opv return true;
        return !scalable && vp_is_defined_outside_loop_regions(opv) && vp_scalar_type(opv) == vp_scalar_type(m0op);
    }
    r := vp_def(m0op);
    if vr(r).kind == .WIDEN_LOAD return !scalable && !vr(r).masked && vr(r).consecutive && m0op == opv;
    if vr(r).kind == .INTERLEAVE {
        g := vp_ig(r);
        return g.factor == cast(u32) g.keys.count && vr(r).defs[idx] == opv;
    }
    return false;
}
// getOpcodeOrIntrinsicID for VPWidenRecipe / VPWidenCastRecipe
vp_can_narrow_ops :: (ops: [] Vp_Val, scalable: bool) -> bool {
    m0 := vp_def(ops[0]);
    if m0 == NONE || !vp_is_with_ir_flags_kind(vr(m0).kind) return false;
    for v: ops {
        r := vp_def(v);
        if r == NONE || (vr(r).kind != .WIDEN && vr(r).kind != .WIDEN_CAST) return false;
        if vr(r).opcode != vr(m0).opcode return false;
        if vp_scalar_type(v) != vp_scalar_type(ops[0]) return false;
        has_pred := vr(r).flags.optype == .CMP || vr(r).flags.optype == .FCMP;
        if has_pred && vr(r).flags.pred != vr(m0).flags.pred return false;
    }
    for idx: 0..vp_nops(m0) - 1 {
        opsi: [..] Vp_Val; opsi.allocator = temp;
        for ops array_add(*opsi, vp_op(vp_def(it), idx));
        if vp_can_narrow_ops(opsi, scalable) continue;
        for opv, op_idx: opsi if !vp_can_narrow_load(m0, idx, opv, op_idx, scalable) return false;
    }
    return true;
}
// isAlreadyNarrow
vp_is_already_narrow :: (v: Vp_Val) -> bool {
    if vp_is_ir_value(v) return true;
    r := vp_def(v);
    return r != NONE && vr(r).kind == .REPLICATE && vr(r).single_scalar;
}
// narrowInterleaveGroupOp
vp_narrow_interleave_group_op :: (members: [] Vp_Val, narrowed: *[..] Vp_Val, preheader: Vp_Blk) -> Vp_Val {
    v := members[0];
    if array_find(narrowed.*, v) return v;
    if vp_is_defined_outside_loop_regions(v) {
        bv := vp_new_instruction(VPI_BUILD_VECTOR, members);
        vp_append_recipe(preheader, bv);
        array_add(narrowed, vr(bv).def);
        return vr(bv).def;
    }
    if vp_is_already_narrow(v) return v;
    r := vp_def(v);
    k := vr(r).kind;
    if k == .WIDEN || k == .WIDEN_CAST {
        for m: members { if it_index == 0 continue; vp_intersect_flags(*vr(r).flags, vr(vp_def(m)).flags); }
        for idx: 0..vp_nops(r) - 1 {
            opsi: [..] Vp_Val; opsi.allocator = temp;
            for members array_add(*opsi, vp_op(vp_def(it), idx));
            vp_set_operand(r, idx, vp_narrow_interleave_group_op(opsi, narrowed, preheader));
        }
        return v;
    }
    if k == .INTERLEAVE {
        g := vp_ig(r);
        l := vp_new_widen_load(g.insert_pos, vp_op(r, 0), vp_interleave_mask(r), true, vr(r).md, vr(r).dl);
        vp_insert_before(l, r);
        array_add(narrowed, vr(l).def);
        return vr(l).def;
    }
    if k == .REPLICATE {
        assert(vr(r).single_scalar && inst_op(vp_underlying_instr(r)) == .LOAD, "must be a single scalar load");
        array_add(narrowed, v);
        return v;
    }
    assert(k == .WIDEN_LOAD);
    ptr := vp_op(r, 0);
    pr := vp_def(ptr);
    if pr != NONE && vr(pr).kind == .VECTOR_POINTER ptr = vp_op(pr, 0);
    n := vp_new_replicate(vr(r).ir_inst, .[ptr], true, NONE, .{}, vr(r).md, vr(r).dl);
    vp_insert_before(n, r);
    array_add(narrowed, vr(n).def);
    return vr(n).def;
}

// VPlanTransforms::narrowInterleaveGroups: returns the copy of the plan with all VFs but the narrowed one, or null
vp_narrow_interleave_groups :: (t: *Tti) -> *Vp_Plan {
    region := vp_vector_loop_region();
    if region == NONE return null;
    e := vp_entry_basic_block(region);
    if e != vp_exiting_basic_block(region) return null;
    okb, _, _ := vpm_branch_on_count(vb(e).last);
    if !okb return null;
    have_vf := false; vf_to_opt: Ec;
    store_groups: [..] Vp_Rec; store_groups.allocator = temp;
    for r: vp_block_recipes(e) {
        k := vr(r).kind;
        if (k == .DERIVED_IV || k == .SCALAR_IV_STEPS) && vp_only_first_lane_used(vr(r).def) continue;
        if vp_is_phi_recipe(r) return null;
        is_ig := k == .INTERLEAVE;
        if vp_may_write_to_memory(r) && !is_ig return null;
        for d: 0..vp_num_defined_values(r) - 1 {
            v := vp_defined_value(r, d);
            for u: vv(v).users if vb(vr(u).parent).parent != region return null;
        }
        if !is_ig continue;
        vfs: [..] Ec; vfs.allocator = temp;
        if have_vf array_add(*vfs, vf_to_opt); else for vpl.vfs array_add(*vfs, it);
        ok, nvf := vp_is_consecutive_interleave_group(r, vfs, t);
        if !ok || (have_vf && !ec_eq(nvf, vf_to_opt)) return null;
        vf_to_opt = nvf; have_vf = true;
        stored := vp_interleave_stored_values(r);
        if stored.count == 0 continue;
        m0 := stored[0];
        all_eq := true;
        for stored if it != m0 all_eq = false;
        if vp_is_already_narrow(m0) && all_eq { array_add(*store_groups, r); continue; }
        all_loads := true;
        for sv, si: stored {
            dr := vp_def(sv);
            if dr == NONE || vr(dr).kind != .INTERLEAVE { all_loads = false; break; }
            g := vp_ig(dr);
            if g.factor != cast(u32) g.keys.count || vr(dr).defs[si] != sv { all_loads = false; break; }
        }
        if all_loads { array_add(*store_groups, r); continue; }
        if !vp_can_narrow_ops(stored, vf_to_opt.scalable) return null;
        array_add(*store_groups, r);
    }
    if store_groups.count == 0 return null;
    middle := vp_middle_block();
    req_epi := vb(middle).succs.count == 1 && vp_single_succ(middle) == vp_scalar_preheader();
    if vb(middle).succs.count != 2 && !req_epi return null;
    if vf_to_opt.scalable vp_unported("narrowInterleaveGroups for scalable VFs");
    new_plan: *Vp_Plan = null;
    if vpl.vfs.count != 1 {
        plan := vpl;
        new_plan = vp_duplicate(plan);
        // NewPlan->removeVF
        for vpl.vfs if ec_eq(it, vf_to_opt) { array_ordered_remove_by_index(*vpl.vfs, it_index); break; }
        vp_use(plan);
        vp_set_vf(vf_to_opt);
    }
    narrowed: [..] Vp_Val; narrowed.allocator = temp;
    preheader := vp_vector_preheader();
    for sg: store_groups {
        res := vp_narrow_interleave_group_op(vp_interleave_stored_values(sg), *narrowed, preheader);
        g := vp_ig(sg);
        st := vp_new_widen_store(g.insert_pos, vp_op(sg, 0), res, NONE, true, vr(sg).md, vr(sg).dl);
        vp_insert_before(st, sg);
        vp_erase_recipe(sg);
    }
    inc := vp_find_canonical_iv_increment();
    can_ty := vv(vb(region).can_iv).ty;
    vector_ph := vp_vector_preheader();
    step := vpl.uf;
    vp_rauw(vpl.vf, vp_const_int(can_ty, 1));
    vp_materialize_vector_trip_count(vector_ph, false, req_epi, step, false, 0);
    vp_set_operand(inc, 1, step);
    vp_rauw(vpl.vfxuf, step);
    vp_remove_dead_recipes();
    return new_plan;
}
// isConsecutiveInterleaveGroup
vp_is_consecutive_interleave_group :: (r: Vp_Rec, vfs: [] Ec, t: *Tti) -> (bool, Ec) {
    if vr(r).masked return false, .{};
    stored := vp_interleave_stored_values(r);
    elt_ty: Type_Id;
    if stored.count == 0 {
        elt_ty = vp_scalar_type(vr(r).defs[0]);
        for vr(r).defs if vp_scalar_type(it) != elt_ty return false, .{};
    } else {
        elt_ty = vp_scalar_type(stored[0]);
        for stored if vp_scalar_type(it) != elt_ty return false, .{};
    }
    g := vp_ig(r);
    if g.factor != cast(u32) g.keys.count return false, .{};
    for vf: vfs {
        if vf.scalable continue;
        size := cast(u64) type_bits(scalar_type(elt_ty)) * vf.n;
        if cast(u64) g.factor == vf.n && size == tti_register_bit_width(t, RGK_FIXED_WIDTH_VECTOR) return true, vf;
    }
    return false, .{};
}
