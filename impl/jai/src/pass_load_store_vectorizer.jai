// LoadStoreVectorizer (`load-store-vectorizer`).
// Port of llvm/lib/Transforms/Vectorize/LoadStoreVectorizer.cpp (LLVM 23.1.5): Vectorizer::run, runOnPseudoBB,
// collectEquivalenceClasses, mergeEquivalenceClasses, gatherChains (the MRU list of chains), getConstantOffset /
// getConstantOffsetComplexAddrs / getConstantOffsetSelects, splitChainByMayAliasInstrs (isSafeToMove),
// splitChainByContiguity (gap filling), splitChainByAlignment (chain extension), vectorizeChain, reorder,
// createExtraElementAfter, createMaskForExtraElements, deleteExtraElements.
//
// The Vectorizer object is `Lsv` (one per function run); a Chain is a `[..] Lsv_Elem` in temp storage.
// Address order: mergeEquivalenceClasses walks a DenseMap<const Value *, const Value *> keyed by pointer; where
// that order decides the order of new equivalence classes, we fail loudly (-load-store-vectorizer-guess-address-order
// guesses insertion order).

lsv_guess_address_order := false;   // -load-store-vectorizer-guess-address-order (ours)

LSV_MAX_DEPTH :: 3;
LSV_STACK_ADJUSTED_ALIGNMENT :: 4;
LSV_MAX_CHAINS_TO_TRY :: 64;

Lsv_Elem :: struct { i: Value_Id; off: APInt; }   // ChainElem: Inst, OffsetFromLeader
Lsv_Chain :: [..] Lsv_Elem;

Lsv_Key :: struct { obj: Value_Id; as: u32; bits: u32; is_load: bool; }
Lsv_Class :: struct { key: Lsv_Key; insts: [..] Value_Id; erased: bool; }

Lsv :: struct {
    f: Value_Id;
    aar: Aa_Results;
    ac: *Assumption_Cache;
    dt: *Dom_Tree;
    tti: *Tti;
    b: Irb;
    to_erase: [..] Value_Id;
    extra: Table(Value_Id, bool);      // ExtraElements (membership only)
    extra_list: [..] Value_Id;         // the same elements in creation order (deleteExtraElements' order does not matter)
}

load_store_vectorizer_run :: (f: Value_Id) -> Preserved {
    if fn_has_fn_attr(f, .NoImplicitFloat) return PRESERVE_ALL;
    v: Lsv;
    v.f = f;
    v.aar = aa_results_for(f);
    v.dt = get_domtree(f);
    get_scev(f);
    v.tti = tti_get(f);
    v.ac = get_assumption_cache(f);
    v.to_erase.allocator = temp;
    v.extra.allocator = temp;
    v.extra_list.allocator = temp;
    changed := lsv_run(*v);
    if !changed return PRESERVE_ALL;
    return preserved_cfg();
}

lsv_is_extra :: inline (v: *Lsv, i: Value_Id) -> bool { return table_contains(*v.extra, i); }

lsv_run :: (v: *Lsv) -> bool {
    changed := false;
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(v.f), *po);
    for bb: po {
        barriers: [..] Value_Id; barriers.allocator = temp;
        array_add(*barriers, block(bb).first);
        for i: block_insts(bb) if !is_guaranteed_to_transfer_execution(i) array_add(*barriers, i);
        array_add(*barriers, NONE);
        for k: 0..barriers.count - 2 changed |= lsv_run_on_pseudo_bb(v, barriers[k], barriers[k + 1]);

        for i: v.to_erase {
            if lsv_is_extra(v, i) continue;
            ptr := load_store_pointer_operand(i);
            if !has_uses(i) erase_inst_with_metadata(i);
            recursively_delete_trivially_dead_value(ptr);
        }
        v.to_erase.count = 0;
        lsv_delete_extra_elements(v);
    }
    return changed;
}

lsv_run_on_pseudo_bb :: (v: *Lsv, begin: Value_Id, end: Value_Id) -> bool {
    changed := false;
    classes := lsv_collect_equivalence_classes(v, begin, end);
    for * c: classes {
        if c.erased continue;
        chains := lsv_gather_chains(v, c.insts);
        for * ch: chains changed |= lsv_run_on_chain(v, ch);
    }
    return changed;
}

lsv_run_on_chain :: (v: *Lsv, c: *Lsv_Chain) -> bool {
    changed := false;
    for * c1: lsv_split_chain_by_may_alias_instrs(v, c)
        for * c2: lsv_split_chain_by_contiguity(v, c1)
            for * c3: lsv_split_chain_by_alignment(v, c2)
                changed |= lsv_vectorize_chain(v, c3);
    return changed;
}

// ---------------------------------------------------------------- chain orders

lsv_less_bb :: (a: Lsv_Elem, b: Lsv_Elem) -> bool { return comes_before(a.i, b.i); }
lsv_less_offset :: (a: Lsv_Elem, b: Lsv_Elem) -> bool {
    if !ap_eq(a.off, b.off) return ap_slt(a.off, b.off);
    return comes_before(a.i, b.i);
}
// std::sort with a strict total order: any sorting algorithm gives the same result (merge sort here)
lsv_sort :: (c: *Lsv_Chain, by_offset: bool) {
    n := c.count;
    if n < 2 return;
    tmp := NewArray(n, Lsv_Elem,, allocator = temp);
    width := 1;
    while width < n {
        lo := 0;
        while lo < n {
            mid := min(lo + width, n); hi := min(lo + 2 * width, n);
            a := lo; b := mid; k := lo;
            while a < mid || b < hi {
                take_b := false;
                if a >= mid take_b = true;
                else if b < hi {
                    if by_offset take_b = lsv_less_offset(c.*[b], c.*[a]);
                    else take_b = lsv_less_bb(c.*[b], c.*[a]);
                }
                if take_b { tmp[k] = c.*[b]; b += 1; } else { tmp[k] = c.*[a]; a += 1; }
                k += 1;
            }
            lo = hi;
        }
        for k: 0..n - 1 c.*[k] = tmp[k];
        width *= 2;
    }
}

lsv_chain_of :: (elems: ..Lsv_Elem) -> Lsv_Chain {
    r: Lsv_Chain; r.allocator = temp;
    for elems array_add(*r, it);
    return r;
}

lsv_is_invariant_load :: (i: Value_Id) -> bool {
    return inst_op(i) == .LOAD && get_metadata(i, MDK_INVARIANT_LOAD) != NONE;
}

// ---------------------------------------------------------------- reorder

lsv_reorder :: (i: Value_Id) {
    to_move: Table(Value_Id, bool); to_move.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    array_add(*work, i);
    bb := inst(i).parent;
    while work.count {
        iw := pop(*work);
        n := nops(iw);
        for idx: 0..cast(s64) n - 1 {
            im := op(iw, cast(u32) idx);
            if im == NONE || !is_inst(im) || inst_op(im) == .PHI continue;
            if inst(im).parent != bb continue;
            if !comes_before(im, i) {
                table_set(*to_move, im, true);
                array_add(*work, im);
            }
        }
    }
    x := i;
    while x != NONE {
        im := x;
        x = inst(x).next;
        if !table_contains(*to_move, im) continue;
        inst_move_before_dbg(im, i);
    }
}

// ---------------------------------------------------------------- splitChainByMayAliasInstrs

lsv_split_chain_by_may_alias_instrs :: (v: *Lsv, c: *Lsv_Chain) -> [..] Lsv_Chain {
    ret: [..] Lsv_Chain; ret.allocator = temp;
    if c.count == 0 return ret;
    lsv_sort(c, false);
    offsets: Table(Value_Id, APInt); offsets.allocator = temp;
    for c.* if !table_contains(*offsets, it.i) table_set(*offsets, it.i, it.off);
    batch := aa_query_new(*v.aar);
    is_load := inst_op(c.*[0].i) == .LOAD;
    n := c.count;
    first := ifx is_load then 0 else n - 1;
    step := ifx is_load then 1 else -1;
    new_chain := lsv_chain_of(c.*[first]);
    k := first + step;
    while k >= 0 && k < n {
        defer k += step;
        e := c.*[k];
        if lsv_is_safe_to_move(v, is_load, e.i, new_chain[0].i, *offsets, batch) {
            array_add(*new_chain, e);
        } else {
            if new_chain.count > 1 array_add(*ret, new_chain);
            new_chain = lsv_chain_of(e);
        }
    }
    if new_chain.count > 1 array_add(*ret, new_chain);
    return ret;
}

lsv_is_safe_to_move :: (v: *Lsv, is_load: bool, elem: Value_Id, begin: Value_Id, offsets: *Table(Value_Id, APInt), batch: *Aa_Query) -> bool {
    if elem == begin return true;
    if lsv_is_invariant_load(elem) return true;
    // loads: from the instruction before elem back to begin (inclusive); stores: from after elem forward to begin
    it := ifx is_load then inst(elem).prev else inst(elem).next;
    stop := ifx is_load then inst(begin).prev else inst(begin).next;
    found, elem_off := table_find(offsets, elem);
    assert(found);
    elem_size := dl_type_store_size(load_store_type(elem));
    loc := mloc_get(elem);
    while it != stop {
        i := it;
        it = ifx is_load then inst(it).prev else inst(it).next;
        if !may_read_or_write_memory(i) continue;
        if is_load && inst_op(i) == .LOAD continue;
        if !is_load && lsv_is_invariant_load(i) continue;
        in_chain, ioff := table_find(offsets, i);
        if in_chain {
            isize := dl_type_store_size(load_store_type(i));
            if ap_eq(ioff, elem_off) ||
               (ap_sle(ioff, elem_off) && ap_sgt(ap_add(ioff, ap_from_u64(ioff.bits, isize)), elem_off)) ||
               (ap_sle(elem_off, ioff) && ap_sgt(ap_add(elem_off, ap_from_u64(elem_off.bits, elem_size)), ioff))
                return false;
            continue;
        }
        mr := aa_mod_ref_inst_loc(batch, i, loc);
        if is_load { if (mr & MR_MOD) != 0 return false; }
        else if mr != MR_NO return false;
    }
    return true;
}

// ---------------------------------------------------------------- splitChainByContiguity

lsv_split_chain_by_contiguity :: (v: *Lsv, c: *Lsv_Chain) -> [..] Lsv_Chain {
    ret: [..] Lsv_Chain; ret.allocator = temp;
    if c.count == 0 return ret;
    lsv_sort(c, true);
    c0 := c.*[0].i;
    as := ptr_addrspace(vtype(load_store_pointer_operand(c0)));
    elem_ty := scalar_type(load_store_type(c0));
    max_vec_reg_bits := lsv_vec_reg_bit_width(v, as);
    optimistic_align := max_vec_reg_bits / 8;
    max_vector_num_elems := max_vec_reg_bits / dl_type_size_bits(elem_ty);
    optimistic_ty := type_vector(max_vector_num_elems, elem_ty, false);
    try_fill_gaps := lsv_is_legal_masked(v, optimistic_ty, optimistic_align, inst_op(c0) == .LOAD);

    best_align := load_store_align(c0);
    best_off := c.*[0].off;
    for c.* {
        a := load_store_align(it.i);
        if a > best_align { best_align = a; best_off = it.off; }
    }
    derive_align :: (best_align: u64, best_off: APInt, new_off: APInt) -> u64 {
        d := ap_limited(ap_abs(ap_sub(new_off, best_off)), 0xFFFF_FFFF_FFFF_FFFF);
        return common_alignment(best_align, d);
    }

    as_ptr_bits := dl_index_size_bits(as);
    array_add(*ret, lsv_chain_of(c.*[0]));
    chain_elem_ty_bits := dl_type_size_bits(lsv_chain_elem_ty(c.*));
    prev := c.*[0];
    for k: 1..c.count - 1 {
        cur := *ret[ret.count - 1];
        e := c.*[k];
        prev_sz := ap_from_u64(as_ptr_bits, dl_type_store_size(load_store_type(prev.i)));
        prev_read_end := ap_add(prev.off, prev_sz);
        sz := dl_type_store_size(load_store_type(e.i));
        assert((8 * sz) % chain_elem_ty_bits == 0);
        read_end := ap_add(e.off, ap_from_u64(e.off.bits, sz));
        contiguous := false;
        if ap_sle(e.off, prev_read_end) {
            overlap := ap_zext_value(ap_sub(prev_read_end, e.off));
            if (8 * overlap) % chain_elem_ty_bits == 0 contiguous = true;
        }
        gap_filled := false;
        if !contiguous && try_fill_gaps && ap_eq_u64(prev_sz, sz) {
            gap := ap_sub(e.off, prev_read_end);
            prev_ty := load_store_type(prev.i);
            if ap_eq(gap, prev_sz) {
                ne := lsv_create_extra_element_after(v, prev, prev_ty, prev_sz, "GapFill", derive_align(best_align, best_off, prev_read_end));
                array_add(cur, ne);
                gap_filled = true;
            }
            if ap_eq(gap, ap_mul(ap_from_u64(prev_sz.bits, 2), prev_sz)) && cur.count % 4 == 1 {
                ne1 := lsv_create_extra_element_after(v, prev, prev_ty, prev_sz, "GapFill", derive_align(best_align, best_off, prev_read_end));
                ne2 := lsv_create_extra_element_after(v, ne1, prev_ty, prev_sz, "GapFill", derive_align(best_align, best_off, ap_add(prev_read_end, prev_sz)));
                array_add(cur, ne1);
                array_add(cur, ne2);
                gap_filled = true;
            }
        }
        if contiguous || gap_filled array_add(cur, e);
        else array_add(*ret, lsv_chain_of(e));
        if ap_sge(read_end, prev_read_end) prev = e;
    }
    out: [..] Lsv_Chain; out.allocator = temp;
    for ret if it.count > 1 array_add(*out, it);
    return out;
}

// getChainElemTy
lsv_chain_elem_ty :: (c: [] Lsv_Elem) -> Type_Id {
    for c if is_ptr_type(scalar_type(load_store_type(it.i)))
        return type_int(cast(u32) dl_type_size_bits(scalar_type(load_store_type(c[0].i))));
    for c { t := scalar_type(load_store_type(it.i)); if is_int_type(t) return t; }
    return scalar_type(load_store_type(c[0].i));
}

// ---------------------------------------------------------------- splitChainByAlignment

lsv_split_chain_by_alignment :: (v: *Lsv, c: *Lsv_Chain) -> [..] Lsv_Chain {
    ret: [..] Lsv_Chain; ret.allocator = temp;
    if c.count == 0 return ret;
    lsv_sort(c, true);
    is_load := inst_op(c.*[0].i) == .LOAD;
    as := ptr_addrspace(vtype(load_store_pointer_operand(c.*[0].i)));
    vec_reg_bytes := lsv_vec_reg_bit_width(v, as) / 8;
    may_contain_extra := false;
    for c.* if lsv_is_extra(v, it.i) { may_contain_extra = true; break; }

    Cand :: struct { cend: s64; size: u64; }
    cbegin := 0;
    while cbegin < c.count {
        defer cbegin += 1;
        cands: [..] Cand; cands.allocator = temp;
        sz := dl_type_store_size(load_store_type(c.*[cbegin].i));
        prev_read_end := ap_add(c.*[cbegin].off, ap_from_u64(c.*[cbegin].off.bits, sz));
        for cend: cbegin + 1..c.count - 1 {
            read_end := ap_add(c.*[cend].off, ap_from_u64(c.*[cend].off.bits, dl_type_store_size(load_store_type(c.*[cend].i))));
            added: u64 = 0;
            if ap_sle(prev_read_end, read_end) added = cast(u64) ap_sext_value(ap_sub(read_end, prev_read_end));
            sz += added;
            if sz > vec_reg_bytes break;
            array_add(*cands, .{cend, sz});
            prev_read_end = ap_smax(prev_read_end, read_end);
        }
        ci := cands.count - 1;
        while ci >= 0 {
            defer ci -= 1;
            cend := cands[ci].cend;
            size_bytes := cands[ci].size;
            vec_elem_ty := lsv_chain_elem_ty(c.*);
            vec_elem_bits := dl_type_size_bits(vec_elem_ty);
            assert((8 * size_bytes) % vec_elem_bits == 0);
            num_vec_elems := 8 * size_bytes / vec_elem_bits;
            vf := 8 * vec_reg_bytes / vec_elem_bits;
            // getLoadVectorFactor / getStoreVectorFactor: TTI's default (X86 does not override it) returns VF
            target_vf := vf;
            if target_vf != vf && target_vf < num_vec_elems continue;

            ptr := load_store_pointer_operand(c.*[cbegin].i);
            is_alloca_access := as == dl_alloca_addrspace() && lsv_is_alloca(strip_pointer_casts(ptr));
            alignment := load_store_align(c.*[cbegin].i);
            pref_align: u64 = LSV_STACK_ADJUSTED_ALIGNMENT;
            if is_alloca_access && alignment % size_bytes != 0 && lsv_access_is_allowed_and_fast(v, size_bytes, as, pref_align, vec_elem_bits) {
                new_align := get_or_enforce_known_alignment(ptr, pref_align, c.*[cbegin].i, null, v.dt);
                if new_align >= alignment alignment = new_align;
            }

            extending: Lsv_Chain; extending.allocator = temp;
            if !lsv_access_is_allowed_and_fast(v, size_bytes, as, alignment, vec_elem_bits) {
                allowed_and_fast := false;
                if num_vec_elems < target_vf && !lsv_is_pow2(num_vec_elems) && vec_elem_bits >= 8 {
                    vec_elem_bytes := vec_elem_bits / 8;
                    new_num := lsv_power_of_2_ceil(num_vec_elems);
                    new_size := vec_elem_bytes * new_num;
                    legal := lsv_is_legal_masked(v, type_vector(new_num, vec_elem_ty, false), alignment, is_load);
                    if legal && lsv_access_is_allowed_and_fast(v, new_size, as, alignment, vec_elem_bits) {
                        as_ptr_bits := dl_index_size_bits(as);
                        for k: 0..cast(s64) (new_num - num_vec_elems) - 1 {
                            ne := lsv_create_extra_element_after(v, c.*[cbegin], vec_elem_ty,
                                ap_from_u64(as_ptr_bits, size_bytes + cast(u64) k * vec_elem_bytes), "Extend", 1);
                            array_add(*extending, ne);
                        }
                        size_bytes = new_size;
                        num_vec_elems = new_num;
                        allowed_and_fast = true;
                    }
                }
                if !allowed_and_fast continue;
            }
            // isLegalToVectorizeLoadChain / isLegalToVectorizeStoreChain: true (X86 does not override them)

            if may_contain_extra {
                cur_has_extra := false;
                for k: cbegin..cend if lsv_is_extra(v, c.*[k].i) { cur_has_extra = true; break; }
                if cur_has_extra && !lsv_is_legal_masked(v, type_vector(num_vec_elems, vec_elem_ty, false), alignment, is_load) continue;
            }

            nc: Lsv_Chain; nc.allocator = temp;
            for k: cbegin..cend array_add(*nc, c.*[k]);
            for extending array_add(*nc, it);
            array_add(*ret, nc);
            cbegin = cend;
            break;
        }
    }
    return ret;
}

lsv_is_alloca :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .ALLOCA; }
lsv_is_pow2 :: (x: u64) -> bool { return x != 0 && (x & (x - 1)) == 0; }
lsv_power_of_2_ceil :: (x: u64) -> u64 { if x == 0 return 0; r: u64 = 1; while r < x r <<= 1; return r; }

// ---------------------------------------------------------------- TTI queries

// getLoadStoreVecRegBitWidth: X86 returns getRegisterBitWidth(RGK_FixedWidthVector); the default is 128
lsv_vec_reg_bit_width :: (v: *Lsv, as: u32) -> u64 {
    if v.tti.kind == .X86 return tti_register_bit_width(v.tti, RGK_FIXED_WIDTH_VECTOR);
    return 128;
}
// isLegalMaskedLoad / isLegalMaskedStore (ConstantMask); false without a target
lsv_is_legal_masked :: (v: *Lsv, ty: Type_Id, align: u64, is_load: bool) -> bool {
    if v.tti.kind != .X86 return false;
    if is_load return x86_is_legal_masked_load(*v.tti.xl, ty);
    return x86_is_legal_masked_store(*v.tti.xl, ty);
}
// TTI.allowsMisalignedMemoryAccesses(Ctx, BitWidth, AS, Alignment, &Fast): BasicTTIImpl asks the target lowering
// for the integer EVT of BitWidth (X86TargetLowering::allowsMisalignedMemoryAccesses / isMemoryAccessFast)
lsv_allows_misaligned :: (v: *Lsv, bit_width: u64, as: u32, align: u64) -> (bool, u32) {
    if v.tti.kind != .X86 return false, 0;
    st := *v.tti.xl;
    fast: u32 = 1;
    if align * 8 < bit_width || (align * 8) % bit_width != 0 {   // !isBitAligned(Alignment, SizeInBits)
        if bit_width == 128 fast = ifx st_isUnalignedMem16Slow(st) then cast(u32) 0 else 1;
        else if bit_width == 256 fast = ifx xs_has(st, X86FLD_IsUnalignedMem32Slow) then cast(u32) 0 else 1;
    }
    return true, fast;
}

lsv_access_is_allowed_and_fast :: (v: *Lsv, size_bytes: u64, as: u32, align: u64, vec_elem_bits: u64) -> bool {
    if align % size_bytes == 0 return true;
    allows, vec_speed := lsv_allows_misaligned(v, size_bytes * 8, as, align);
    if !allows return false;
    _, elem_speed := lsv_allows_misaligned(v, vec_elem_bits, as, align);
    if vec_speed < elem_speed return false;
    return true;
}

// ---------------------------------------------------------------- extra elements

lsv_create_extra_element_after :: (v: *Lsv, prev: Lsv_Elem, ty: Type_Id, offset: APInt, prefix: string, align: u64) -> Lsv_Elem {
    nxt := inst(prev.i).next;
    irb_set_before(*v.b, nxt);
    ptr := load_store_pointer_operand(prev.i);
    gep := irb_gep(*v.b, ir.t_i8, ptr, .[const_int_ap(vtype_index_int(offset.bits), offset)], tconcat(prefix, "GEP"));
    ne: Value_Id;
    if inst_op(prev.i) == .LOAD ne = irb_load(*v.b, ty, gep, align, false, prefix);
    else ne = irb_store(*v.b, const_poison(ty), gep, align);
    copy_metadata_and_dbg(ne, prev.i);
    table_set(*v.extra, ne, true);
    array_add(*v.extra_list, ne);
    return .{ne, ap_add(prev.off, offset)};
}

vtype_index_int :: (bits: u32) -> Type_Id { return type_int(bits); }

// Instruction::copyMetadata(SrcInst): every attachment and the debug location
copy_metadata_and_dbg :: (dst: Value_Id, src: Value_Id) {
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(src, *all);
    for all set_metadata(dst, it.kind, it.md);
    if get_metadata(src, MDK_DBG) == NONE set_metadata(dst, MDK_DBG, NONE);
}

lsv_create_mask_for_extra_elements :: (v: *Lsv, c: [] Lsv_Elem, vec_ty: Type_Id) -> Value_Id {
    n := type_count(vec_ty);
    elts := NewArray(cast(s64) n, Value_Id,, allocator = temp);
    for * elts it.* = const_int(ir.t_i1, 0);
    elem_bits := dl_type_size_bits(type_elem(vec_ty));
    for e: c {
        if lsv_is_extra(v, e.i) continue;
        eoff := ap_zext_value(ap_sub(e.off, c[0].off));
        idx := 8 * eoff / elem_bits;
        t := load_store_type(e.i);
        if type_kind(t) == .VECTOR {
            for j: 0..cast(s64) type_count(t) - 1 elts[cast(s64) idx + j] = const_int(ir.t_i1, 1);
        } else elts[idx] = const_int(ir.t_i1, 1);
    }
    return const_vector_of(elts);
}

lsv_delete_extra_elements :: (v: *Lsv) {
    for e: v.extra_list {
        if vkind(e) == .DEAD continue;
        if inst_op(e) == .LOAD {
            deleted := recursively_delete_trivially_dead_value(e);
            assert(deleted, "LSV: an extra load should always be trivially dead");
        } else {
            ptr := load_store_pointer_operand(e);
            erase_inst_with_metadata(e);
            recursively_delete_trivially_dead_value(ptr);
        }
    }
    v.extra_list.count = 0;
    table_reset(*v.extra);
}

// ---------------------------------------------------------------- vectorizeChain

lsv_vectorize_chain :: (v: *Lsv, c: *Lsv_Chain) -> bool {
    if c.count < 2 return false;
    has_extra := false;
    for c.* if lsv_is_extra(v, it.i) { has_extra = true; break; }
    if c.count == 2 && has_extra return false;
    lsv_sort(c, true);

    vec_elem_ty := lsv_chain_elem_ty(c.*);
    c0 := c.*[0].i;
    is_load := inst_op(c0) == .LOAD;
    as := ptr_addrspace(vtype(load_store_pointer_operand(c0)));
    added := dl_type_store_size(load_store_type(c0));
    prev_read_end := ap_add(c.*[0].off, ap_from_u64(c.*[0].off.bits, added));
    chain_bytes := added;
    for k: 1..c.count - 1 {
        sz := dl_type_store_size(load_store_type(c.*[k].i));
        read_end := ap_add(c.*[k].off, ap_from_u64(c.*[k].off.bits, sz));
        added = 0;
        if ap_sle(prev_read_end, read_end) added = cast(u64) ap_sext_value(ap_sub(read_end, prev_read_end));
        chain_bytes += added;
        prev_read_end = ap_smax(prev_read_end, read_end);
    }
    elem_bits := dl_type_size_bits(vec_elem_ty);
    assert((8 * chain_bytes) % elem_bits == 0);
    num_elem := 8 * chain_bytes / elem_bits;
    vec_ty := type_vector(num_elem, vec_elem_ty, false);

    alignment := load_store_align(c0);
    if as == dl_alloca_addrspace()
        alignment = max(alignment, get_or_enforce_known_alignment(load_store_pointer_operand(c0), 0, c0, null, v.dt));

    vec_inst: Value_Id;
    if is_load {
        first := c.*[0].i;
        for c.* if comes_before(it.i, first) first = it.i;
        irb_set_before(*v.b, first);
        if has_extra {
            mask := lsv_create_mask_for_extra_elements(v, c.*, vec_ty);
            fdecl := get_or_insert_intrinsic_declaration(iidn("llvm.masked.load"), .[vec_ty, vtype(load_store_pointer_operand(c0))]);
            vec_inst = irb_call(*v.b, fdecl, .[load_store_pointer_operand(c0), mask, const_poison(vec_ty)]);
            add_param_align(vec_inst, 0, alignment);
        } else {
            if num_elem == 1 vec_ty = vec_elem_ty;
            vec_inst = irb_load(*v.b, vec_ty, load_store_pointer_operand(c0), alignment);
        }
        for e: c.* {
            i := e.i;
            t := load_store_type(i);
            eoff := ap_zext_value(ap_sub(e.off, c.*[0].off));
            idx := 8 * eoff / elem_bits;
            val: Value_Id;
            if !is_vector_type(vec_ty) val = vec_inst;
            else if type_kind(t) == .VECTOR {
                n := type_count(t);
                mask := NewArray(cast(s64) n, u32,, allocator = temp);
                for * mask it.* = cast(u32) (idx + cast(u64) it_index);
                val = irb_shuffle(*v.b, vec_inst, NONE, mask, name_ref(vname(i)));
            } else val = irb_extract_element(*v.b, vec_inst, idx, name_ref(vname(i)));
            if vtype(val) != vtype(i) val = irb_bit_or_pointer_cast(*v.b, val, vtype(i));
            rauw_with_metadata(i, val);
        }
        lsv_reorder(vec_inst);
    } else {
        last := c.*[0].i;
        for c.* if comes_before(last, it.i) last = it.i;
        irb_set_before(*v.b, last);
        vec := const_poison(vec_ty);
        for e: c.* {
            i := e.i;
            eoff := ap_zext_value(ap_sub(e.off, c.*[0].off));
            idx := 8 * eoff / elem_bits;
            t := load_store_type(i);
            if type_kind(t) == .VECTOR {
                for j: 0..cast(s64) type_count(t) - 1 {
                    x := irb_extract_element(*v.b, op(i, 0), cast(u64) j);
                    if vtype(x) != vec_elem_ty x = irb_bit_or_pointer_cast(*v.b, x, vec_elem_ty);
                    vec = irb_insert_element(*v.b, vec, x, idx);
                    idx += 1;
                }
            } else {
                x := op(i, 0);
                if vtype(x) != vec_elem_ty x = irb_bit_or_pointer_cast(*v.b, x, vec_elem_ty);
                vec = irb_insert_element(*v.b, vec, x, idx);
            }
        }
        if has_extra {
            mask := lsv_create_mask_for_extra_elements(v, c.*, vtype(vec));
            fdecl := get_or_insert_intrinsic_declaration(iidn("llvm.masked.store"), .[vtype(vec), vtype(load_store_pointer_operand(c0))]);
            vec_inst = irb_call(*v.b, fdecl, .[vec, load_store_pointer_operand(c0), mask]);
            add_param_align(vec_inst, 1, alignment);
        } else {
            vec_inst = irb_store(*v.b, vec, load_store_pointer_operand(c0), alignment);
        }
    }

    insts := NewArray(c.count, Value_Id,, allocator = temp);
    for c.* insts[it_index] = it.i;
    slp_propagate_metadata(vec_inst, insts);
    for c.* array_add(*v.to_erase, it.i);
    return true;
}

// ---------------------------------------------------------------- getConstantOffset

lsv_check_no_wrap_flags :: (i: Value_Id, signed: bool) -> bool {
    if inst_op(i) == .OR && (inst(i).flags & F_EXACT) != 0 return true;
    if signed return (inst(i).flags & F_NSW) != 0;
    return (inst(i).flags & F_NUW) != 0;
}
lsv_is_add_like :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .ADD return true;
    if o == .OR return (inst(i).flags & F_EXACT) != 0;
    return false;
}
lsv_inst_or_none :: (v: Value_Id) -> Value_Id { if v != NONE && is_inst(v) return v; return NONE; }
lsv_is_const_int :: (v: Value_Id) -> bool { return is_constant_int(v); }
lsv_const_sext :: (v: Value_Id) -> s64 { return ap_sext_value(const_ap(v)); }

lsv_check_if_safe_add_sequence :: (idx_diff: APInt, a: Value_Id, ma: u32, b: Value_Id, mb: u32, signed: bool) -> bool {
    if op(a, ma) != op(b, mb) return false;
    other_a := op(a, ifx ma == 1 then cast(u32) 0 else 1);
    other_b := op(b, ifx mb == 1 then cast(u32) 0 else 1);
    ia := lsv_inst_or_none(other_a);
    ib := lsv_inst_or_none(other_b);
    if ib != NONE && lsv_is_add_like(ib) && lsv_check_no_wrap_flags(ib, signed) && lsv_is_const_int(op(ib, 1)) {
        cst := lsv_const_sext(op(ib, 1));
        if op(ib, 0) == other_a && ap_sext_value(idx_diff) == cst return true;
    }
    if ia != NONE && lsv_is_add_like(ia) && lsv_check_no_wrap_flags(ia, signed) && lsv_is_const_int(op(ia, 1)) {
        cst := lsv_const_sext(op(ia, 1));
        if op(ia, 0) == other_b && ap_sext_value(idx_diff) == -cst return true;
    }
    if ia != NONE && ib != NONE && lsv_is_add_like(ia) && lsv_is_add_like(ib) && lsv_check_no_wrap_flags(ia, signed) &&
       lsv_check_no_wrap_flags(ib, signed) && lsv_is_const_int(op(ia, 1)) && lsv_is_const_int(op(ib, 1)) {
        ca := lsv_const_sext(op(ia, 1));
        cb := lsv_const_sext(op(ib, 1));
        if op(ia, 0) == op(ib, 0) && ap_sext_value(idx_diff) == cb - ca return true;
    }
    return false;
}

lsv_get_constant_offset_complex_addrs :: (v: *Lsv, pa: Value_Id, pb: Value_Id, cxt: Value_Id, depth: u32) -> (bool, APInt) {
    gep_a := is_inst(pa) && inst_op(pa) == .GEP;
    gep_b := is_inst(pb) && inst_op(pb) == .GEP;
    if !gep_a || !gep_b { ok, r := lsv_get_constant_offset_selects(v, pa, pb, cxt, depth); return ok, r; }
    none: APInt;
    if nops(pa) != nops(pb) || op(pa, 0) != op(pb, 0) || inst(pa).ty2 != inst(pb).ty2 return false, none;
    nidx := cast(s64) nops(pa) - 1;
    cur := inst(pa).ty2;
    for k: 0..nidx - 2 {
        if op(pa, cast(u32) (k + 1)) != op(pb, cast(u32) (k + 1)) return false, none;
        cur = gep_indexed_type(cur, k + 1, op(pa, cast(u32) (k + 1)));
    }
    last_k := nidx;   // operand index of the last index
    opa := lsv_inst_or_none(op(pa, cast(u32) last_k));
    opb := lsv_inst_or_none(op(pb, cast(u32) last_k));
    if opa == NONE || opb == NONE || inst_op(opa) != inst_op(opb) || vtype(opa) != vtype(opb) return false, none;
    // getSequentialElementStride
    indexed := gep_indexed_type(cur, last_k, op(pa, cast(u32) last_k));
    stride: u64;
    if last_k > 1 && is_vector_type(cur) stride = dl_type_store_size(indexed);
    else stride = dl_type_alloc_size(indexed);
    if inst_op(opa) != .SEXT && inst_op(opa) != .ZEXT return false, none;
    signed := inst_op(opa) == .SEXT;
    val_a := op(opa, 0);
    opb = lsv_inst_or_none(op(opb, 0));
    if opb == NONE || vtype(val_a) != vtype(opb) return false, none;

    sa := sc_get_scev(val_a);
    sb := sc_get_scev(opb);
    diff_scev := sc_get_minus(sb, sa);
    if diff_scev == SCEV_CNC return false, none;
    rng := sc_signed_range(diff_scev);
    if !cr_is_single_element(rng) return false, none;
    _, sd := cr_single_element(rng);
    idx_diff := ap_copy(sd);

    safe := false;
    if lsv_is_add_like(opb) && lsv_is_const_int(op(opb, 1)) &&
       ap_sle(idx_diff, ap_from_s64(idx_diff.bits, lsv_const_sext(op(opb, 1)))) && lsv_check_no_wrap_flags(opb, signed)
        safe = true;

    opa = lsv_inst_or_none(val_a);
    if !safe && opa != NONE && lsv_is_add_like(opa) && lsv_is_add_like(opb) &&
       lsv_check_no_wrap_flags(opa, signed) && lsv_check_no_wrap_flags(opb, signed) {
        for ma: 0..1 for mb: 0..1
            if !safe safe = lsv_check_if_safe_add_sequence(idx_diff, opa, cast(u32) ma, opb, cast(u32) mb, signed);
    }

    bit_width := type_bits(scalar_type(vtype(val_a)));
    if !safe {
        q: Simplify_Query; q.ac = v.ac; q.cxt = cxt; q.dt = v.dt;
        known := known_bits(ifx ap_sge(idx_diff, ap_zero(idx_diff.bits)) then val_a else opb, q);
        allowed := ap_zext(known.zero, idx_diff.bits);
        if signed ap_clear_bit(*allowed, bit_width - 1);
        safe = ap_uge(allowed, ap_abs(idx_diff));
    }
    if !safe && !signed {
        check_val := ifx ap_sge(idx_diff, ap_zero(idx_diff.bits)) then val_a else opb;
        cr := sc_unsigned_range(sc_get_scev(check_val));
        abs_diff := ap_zext_or_trunc(ap_abs(idx_diff), bit_width);
        limit := ap_sub(ap_all_ones(bit_width), abs_diff);
        safe = ap_ule(cr_umax(cr), limit);
    }
    if safe return true, ap_mul(idx_diff, ap_from_u64(idx_diff.bits, stride));
    return false, none;
}

lsv_get_constant_offset_selects :: (v: *Lsv, pa: Value_Id, pb: Value_Id, cxt: Value_Id, depth_in: u32) -> (bool, APInt) {
    none: APInt;
    depth := depth_in;
    if depth == LSV_MAX_DEPTH return false, none;
    depth += 1;
    if is_inst(pa) && inst_op(pa) == .SELECT && is_inst(pb) && inst_op(pb) == .SELECT {
        if op(pa, 0) != op(pb, 0) return false, none;
        ok_t, td := lsv_get_constant_offset(v, op(pa, 1), op(pb, 1), cxt, depth);
        if !ok_t return false, none;
        ok_f, fd := lsv_get_constant_offset(v, op(pa, 2), op(pb, 2), cxt, depth);
        // std::optional<APInt> ==: both engaged and equal (APInt == asserts equal widths)
        if ok_f && td.bits == fd.bits && ap_eq(td, fd) return true, td;
    }
    return false, none;
}

lsv_get_constant_offset :: (v: *Lsv, pa_in: Value_Id, pb_in: Value_Id, cxt: Value_Id, depth: u32 = 0) -> (bool, APInt) {
    none: APInt;
    orig_bw := dl_index_type_size_bits(vtype(pa_in));
    pa, off_a := strip_and_accumulate_constant_offsets(pa_in, ap_zero(orig_bw), false);
    pb, off_b := strip_and_accumulate_constant_offsets(pb_in, ap_zero(orig_bw), false);
    new_bw := cast(u32) (dl_type_store_size(vtype(pa)) * 8);
    if new_bw != cast(u32) (dl_type_store_size(vtype(pb)) * 8) return false, none;
    off_a = ap_sext_or_trunc(off_a, new_bw);
    off_b = ap_sext_or_trunc(off_b, new_bw);
    if pa == pb return true, ap_sext_or_trunc(ap_sub(off_b, off_a), orig_bw);

    sb := sc_get_scev(pb);
    sa := sc_get_scev(pa);
    dist_scev := sc_get_minus(sb, sa);
    if dist_scev != SCEV_CNC {
        rng := sc_signed_range(dist_scev);
        if cr_is_single_element(rng) {
            _, sd := cr_single_element(rng);
            dist := ap_sext_or_trunc(sd, new_bw);
            return true, ap_sext_or_trunc(ap_add(ap_sub(off_b, off_a), dist), orig_bw);
        }
    }
    ok, diff := lsv_get_constant_offset_complex_addrs(v, pa, pb, cxt, depth);
    if ok return true, ap_sext_or_trunc(ap_add(ap_sub(off_b, off_a), ap_sext(diff, off_b.bits)), orig_bw);
    return false, none;
}

// ---------------------------------------------------------------- equivalence classes

lsv_key_hash :: (k: Lsv_Key) -> u64 { return (cast(u64) k.obj << 32) ^ (cast(u64) k.as << 20) ^ (cast(u64) k.bits << 1) ^ cast(u64) k.is_load; }
lsv_key_eq :: (a: Lsv_Key, b: Lsv_Key) -> bool { return a.obj == b.obj && a.as == b.as && a.bits == b.bits && a.is_load == b.is_load; }

Lsv_Class_Map :: struct {
    classes: [..] Lsv_Class;           // MapVector order; erased entries are skipped
    index: Table(u64, [..] s64);       // hash -> class indices
}
lsv_map_find :: (m: *Lsv_Class_Map, k: Lsv_Key) -> s64 {
    l := table_find_pointer(*m.index, lsv_key_hash(k));
    if !l return -1;
    for l.* if !m.classes[it].erased && lsv_key_eq(m.classes[it].key, k) return it;
    return -1;
}
// MapVector::operator[]
lsv_map_get :: (m: *Lsv_Class_Map, k: Lsv_Key) -> s64 {
    idx := lsv_map_find(m, k);
    if idx >= 0 return idx;
    c: Lsv_Class; c.key = k; c.insts.allocator = temp;
    array_add(*m.classes, c);
    idx = m.classes.count - 1;
    h := lsv_key_hash(k);
    l := table_find_pointer(*m.index, h);
    if !l { e: [..] s64; e.allocator = temp; table_set(*m.index, h, e); l = table_find_pointer(*m.index, h); }
    array_add(l, idx);
    return idx;
}

lsv_collect_equivalence_classes :: (v: *Lsv, begin: Value_Id, end: Value_Id) -> [..] Lsv_Class {
    m: Lsv_Class_Map; m.classes.allocator = temp; m.index.allocator = temp;
    x := begin;
    while x != end {
        i := x;
        x = inst(x).next;
        o := inst_op(i);
        if o != .LOAD && o != .STORE continue;
        if !inst_is_simple(i) continue;
        // isLegalToVectorizeLoad / isLegalToVectorizeStore: true
        ty := load_store_type(i);
        if !is_valid_vector_element_type(scalar_type(ty)) continue;
        ty_size := dl_type_size_bits(ty);
        if ty_size % 8 != 0 continue;
        if is_vector_type(ty) && is_ptr_or_ptr_vector(ty) continue;
        ptr := load_store_pointer_operand(i);
        as := ptr_addrspace(vtype(ptr));
        vec_reg_size := lsv_vec_reg_bit_width(v, as);
        vf := vec_reg_size / ty_size;
        is_vec := is_vector_type(ty);
        if !is_vec && !lsv_is_pow2(dl_type_size_bits(ty)) continue;
        if is_vec && !lsv_is_pow2(dl_type_size_bits(scalar_type(ty))) continue;
        // getLoadVectorFactor(VF, ...) == VF by default; VF == 0 only when the type is wider than the register
        if ty_size > vec_reg_size / 2 || (is_vec && vf == 0) continue;
        obj := get_underlying_object(ptr);
        if is_inst(obj) && inst_op(obj) == .SELECT obj = op(obj, 0);
        k := Lsv_Key.{obj, as, cast(u32) dl_type_size_bits(scalar_type(ty)), o == .LOAD};
        idx := lsv_map_get(*m, k);
        array_add(*m.classes[idx].insts, i);
    }
    lsv_merge_equivalence_classes(*m);
    return m.classes;
}

lsv_merge_equivalence_classes :: (m: *Lsv_Class_Map) {
    live := 0;
    for m.classes if !it.erased live += 1;
    if live < 2 return;
    // RedKeyToUOMap: MapVector<(AS, element size, IsLoad), SmallPtrSet<UObject, 4>>
    Red :: struct { as: u32; bits: u32; is_load: bool; objs: [..] Value_Id; }
    reds: [..] Red; reds.allocator = temp;
    found := false;
    for c: m.classes {
        if c.erased continue;
        r: *Red = null;
        for * reds if it.as == c.key.as && it.bits == c.key.bits && it.is_load == c.key.is_load { r = it; break; }
        if !r { n: Red; n.as = c.key.as; n.bits = c.key.bits; n.is_load = c.key.is_load; n.objs.allocator = temp; array_add(*reds, n); r = *reds[reds.count - 1]; }
        seen := false;
        for r.objs if it == c.key.obj { seen = true; break; }
        if !seen array_add(*r.objs, c.key.obj);
        if r.objs.count > 1 found = true;
    }
    if !found return;

    for * r: reds {
        if r.objs.count < 2 continue;
        // GetUltimateTargets
        ind_from: [..] Value_Id; ind_from.allocator = temp;
        ind_to: [..] Value_Id; ind_to.allocator = temp;
        for u: r.objs {
            t := get_underlying_object(u, 1);
            if t != u { array_add(*ind_from, u); array_add(*ind_to, t); }
        }
        lookup :: (from: [] Value_Id, to: [] Value_Id, x: Value_Id) -> Value_Id {
            for from if it == x return to[it_index];
            return NONE;
        }
        targets := NewArray(r.objs.count, Value_Id,, allocator = temp);
        for u, k: r.objs {
            t := u;
            while true { n := lookup(ind_from, ind_to, t); if n == NONE break; t = n; }
            targets[k] = t;
        }
        // The merges below run in DenseMap (pointer hash) order. That order is visible only through the position
        // of a newly created target class: fail loudly when two different new targets would be created.
        new_targets: [..] Value_Id; new_targets.allocator = temp;
        for u, k: r.objs {
            t := targets[k];
            if t == u continue;
            if lsv_map_find(m, .{t, r.as, r.bits, r.is_load}) >= 0 continue;
            dup := false;
            for new_targets if it == t { dup = true; break; }
            if !dup array_add(*new_targets, t);
        }
        if new_targets.count > 1 && !lsv_guess_address_order
            fatal("load-store-vectorizer: mergeEquivalenceClasses creates % new equivalence classes in DenseMap (heap address) order; not reproducible (-load-store-vectorizer-guess-address-order guesses insertion order)", new_targets.count);
        for u, k: r.objs {
            t := targets[k];
            if u == t continue;
            key_to := Lsv_Key.{t, r.as, r.bits, r.is_load};
            key_from := Lsv_Key.{u, r.as, r.bits, r.is_load};
            to_idx := lsv_map_get(m, key_to);
            from_idx := lsv_map_get(m, key_from);
            vt := m.classes[to_idx].insts;
            vf := m.classes[from_idx].insts;
            merged: [..] Value_Id; merged.allocator = temp;
            a := 0; b := 0;
            while a < vf.count || b < vt.count {
                if a >= vf.count { array_add(*merged, vt[b]); b += 1; continue; }
                if b >= vt.count { array_add(*merged, vf[a]); a += 1; continue; }
                if comes_before(vt[b], vf[a]) { array_add(*merged, vt[b]); b += 1; }
                else { array_add(*merged, vf[a]); a += 1; }
            }
            m.classes[to_idx].insts = merged;
            m.classes[from_idx].erased = true;
        }
    }
}

// ---------------------------------------------------------------- gatherChains

lsv_gather_chains :: (v: *Lsv, instrs: [] Value_Id) -> [..] Lsv_Chain {
    ret: [..] Lsv_Chain; ret.allocator = temp;
    if instrs.count == 0 return ret;
    as := ptr_addrspace(vtype(load_store_pointer_operand(instrs[0])));
    as_ptr_bits := dl_index_size_bits(as);
    // the MRU list: indices into `chains`, front = most recently used
    Mru :: struct { leader: Value_Id; chain: Lsv_Chain; prev: s64; next: s64; }
    chains: [..] Mru; chains.allocator = temp;
    head: s64 = -1;
    unlink :: (chains: *[..] Mru, head: *s64, k: s64) {
        p := chains.*[k].prev; n := chains.*[k].next;
        if p >= 0 chains.*[p].next = n; else head.* = n;
        if n >= 0 chains.*[n].prev = p;
        chains.*[k].prev = -1; chains.*[k].next = -1;
    }
    push_front :: (chains: *[..] Mru, head: *s64, k: s64) {
        chains.*[k].prev = -1; chains.*[k].next = head.*;
        if head.* >= 0 chains.*[head.*].prev = k;
        head.* = k;
    }
    for i: instrs {
        match := false;
        it_k := head;
        j := 0;
        while j < LSV_MAX_CHAINS_TO_TRY && it_k >= 0 {
            leader := chains[it_k].leader;
            cxt := ifx comes_before(leader, i) then i else leader;
            ok, off := lsv_get_constant_offset(v, load_store_pointer_operand(leader), load_store_pointer_operand(i), cxt);
            if ok {
                array_add(*chains[it_k].chain, .{i, off});
                unlink(*chains, *head, it_k);
                push_front(*chains, *head, it_k);
                match = true;
                break;
            }
            j += 1;
            it_k = chains[it_k].next;
        }
        if !match {
            e: Mru; e.leader = i; e.chain.allocator = temp; e.prev = -1; e.next = -1;
            array_add(*e.chain, .{i, ap_zero(as_ptr_bits)});
            array_add(*chains, e);
            push_front(*chains, *head, chains.count - 1);
        }
    }
    k := head;
    while k >= 0 {
        if chains[k].chain.count > 1 array_add(*ret, chains[k].chain);
        k = chains[k].next;
    }
    return ret;
}
