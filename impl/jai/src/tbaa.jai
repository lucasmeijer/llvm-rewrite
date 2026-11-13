// TypeBasedAA: a port of llvm/lib/Analysis/TypeBasedAliasAnalysis.cpp (TBAANode, TBAAStructTagNode,
// TBAAStructTypeNode views of the metadata, matchAccessTags / mayBeAccessToSubobjectOf / getLeastCommonType, the
// TypeBasedAAResult queries). The generic-tag side of matchAccessTags (MDNode::getMostGenericTBAA, used when passes
// merge instructions) is `tbaa_most_generic`; createAccessTag interns new metadata nodes.
//
// Metadata nodes are Md_Id rows; "is an MDNode" = an operand that is a TUPLE/SPECIAL node (not a string or a value).

tbaa_opts: struct { enable := true; };   // -enable-tbaa

md_is_node :: (m: Md_Id) -> bool { return m != NONE && (ir.mds[m].kind == .TUPLE || ir.mds[m].kind == .SPECIAL); }
md_nops :: inline (m: Md_Id) -> u32 { return ir.mds[m].nops; }
// dyn_cast_or_null<MDNode>(N->getOperand(i))
md_node_op :: (m: Md_Id, i: u32) -> Md_Id {
    if i >= md_nops(m) return NONE;
    o := md_op(m, i);
    if md_is_node(o) return o;
    return NONE;
}
// mdconst::dyn_extract<ConstantInt>(N->getOperand(i)): the value, or NONE
md_const_int_op :: (m: Md_Id, i: u32) -> Value_Id {
    if i >= md_nops(m) return NONE;
    o := md_op(m, i);
    if o == NONE || ir.mds[o].kind != .VALUE return NONE;
    v := ir.mds[o].value;
    if v == NONE || !is_scalar_const_int(v) return NONE;
    return v;
}
md_const_int_zext :: (m: Md_Id, i: u32) -> u64 {
    v := md_const_int_op(m, i);
    assert(v != NONE, "TBAA: expected a ConstantInt operand");
    return ap_limited(const_ap(v));
}

// isNewFormatTypeNode
tbaa_is_new_format_type_node :: (n: Md_Id) -> bool {
    if md_nops(n) < 3 return false;
    return md_is_node(md_op(n, 0));
}
// TBAANode::getParent
tbaa_node_parent :: (n: Md_Id) -> Md_Id {
    if tbaa_is_new_format_type_node(n) return md_op(n, 0);
    if md_nops(n) < 2 return NONE;
    return md_node_op(n, 1);
}
// TBAAStructTagNode
tbaa_tag_access_type :: (t: Md_Id) -> Md_Id { return md_node_op(t, 1); }
tbaa_tag_base_type :: (t: Md_Id) -> Md_Id { return md_node_op(t, 0); }
tbaa_tag_offset :: (t: Md_Id) -> u64 { return md_const_int_zext(t, 2); }
tbaa_tag_is_new_format :: (t: Md_Id) -> bool {
    if md_nops(t) < 4 return false;
    at := tbaa_tag_access_type(t);
    if at != NONE && !tbaa_is_new_format_type_node(at) return false;
    return true;
}
tbaa_tag_is_type_immutable :: (t: Md_Id) -> bool {
    opno: u32 = ifx tbaa_tag_is_new_format(t) then cast(u32) 4 else 3;
    if md_nops(t) < opno + 1 return false;
    ci := md_const_int_op(t, opno);
    if ci == NONE return false;
    return ap_get_bit(const_ap(ci), 0);
}

// TBAAStructTypeNode
tbaa_type_num_fields :: (n: Md_Id) -> u32 {
    nf := tbaa_is_new_format_type_node(n);
    first: u32 = ifx nf then cast(u32) 3 else 1;
    per: u32 = ifx nf then cast(u32) 3 else 2;
    if md_nops(n) < first return 0;
    return (md_nops(n) - first) / per;
}
tbaa_type_field_type :: (n: Md_Id, idx: u32) -> Md_Id {
    nf := tbaa_is_new_format_type_node(n);
    first: u32 = ifx nf then cast(u32) 3 else 1;
    per: u32 = ifx nf then cast(u32) 3 else 2;
    return md_op(n, first + idx * per);
}
tbaa_type_id :: (n: Md_Id) -> Md_Id { return md_op(n, ifx tbaa_is_new_format_type_node(n) then cast(u32) 2 else 0); }
// TBAAStructTypeNode::getField(Offset): (field type or NONE, updated offset)
tbaa_type_get_field :: (n: Md_Id, offset_in: u64) -> (Md_Id, u64) {
    offset := offset_in;
    nf := tbaa_is_new_format_type_node(n);
    num := md_nops(n);
    if nf {
        if num < 6 return NONE, offset;
    } else {
        if num < 2 return NONE, offset;
        if num <= 3 {
            cur: u64 = ifx num == 2 then cast(u64) 0 else md_const_int_zext(n, 2);
            offset -= cur;
            return md_node_op(n, 1), offset;
        }
    }
    first: u32 = ifx nf then cast(u32) 3 else 1;
    per: u32 = ifx nf then cast(u32) 3 else 2;
    the_idx: u32 = 0;
    idx := first;
    while idx < num {
        cur := md_const_int_zext(n, idx + 1);
        if cur > offset { the_idx = idx - per; break; }
        idx += per;
    }
    if the_idx == 0 the_idx = num - per;
    cur := md_const_int_zext(n, the_idx + 1);
    offset -= cur;
    return md_node_op(n, the_idx), offset;
}

// getLeastCommonType
tbaa_least_common_type :: (a: Md_Id, b: Md_Id) -> Md_Id {
    if a == NONE || b == NONE return NONE;
    if a == b return a;
    path_a: [..] Md_Id; path_a.allocator = temp;
    path_b: [..] Md_Id; path_b.allocator = temp;
    t := a;
    while t != NONE {
        for path_a if it == t fatal("Cycle found in TBAA metadata.");
        array_add(*path_a, t);
        t = tbaa_node_parent(t);
    }
    t = b;
    while t != NONE {
        for path_b if it == t fatal("Cycle found in TBAA metadata.");
        array_add(*path_b, t);
        t = tbaa_node_parent(t);
    }
    ia := path_a.count - 1; ib := path_b.count - 1;
    ret: Md_Id = NONE;
    while ia >= 0 && ib >= 0 {
        if path_a[ia] == path_b[ib] ret = path_a[ia];
        else break;
        ia -= 1; ib -= 1;
    }
    return ret;
}

// createAccessTag
tbaa_create_access_tag :: (access_type: Md_Id) -> Md_Id {
    if access_type == NONE || md_nops(access_type) < 2 return NONE;
    zero := md_value(const_int(ir.t_i64, 0));
    if tbaa_is_new_format_type_node(access_type) {
        size := md_value(const_int(ir.t_i64, 0xFFFF_FFFF_FFFF_FFFF));
        return md_tuple(.[access_type, access_type, zero, size], false);
    }
    return md_tuple(.[access_type, access_type, zero], false);
}

// hasField
tbaa_has_field :: (base: Md_Id, field: Md_Id) -> bool {
    n := tbaa_type_num_fields(base);
    if n > 0 for i: 0..n-1 {
        t := tbaa_type_field_type(base, i);
        if t == field || tbaa_has_field(t, field) return true;
    }
    return false;
}

// mayBeAccessToSubobjectOf: (matched, may_alias, generic_tag)
tbaa_may_be_access_to_subobject_of :: (base_tag: Md_Id, sub_tag: Md_Id, common: Md_Id, want_generic: bool) -> (bool, bool, Md_Id) {
    generic: Md_Id = NONE;
    if tbaa_tag_access_type(base_tag) == tbaa_tag_base_type(base_tag) && tbaa_tag_access_type(base_tag) == common {
        if want_generic generic = tbaa_create_access_tag(common);
        return true, true, generic;
    }
    new_format := tbaa_tag_is_new_format(base_tag);
    base_type := tbaa_tag_base_type(base_tag);
    offset_in_base := tbaa_tag_offset(base_tag);
    while true {
        if base_type == NONE break;
        if base_type == tbaa_tag_base_type(sub_tag) {
            may_alias := offset_in_base == tbaa_tag_offset(sub_tag) || base_type == tbaa_tag_access_type(base_tag) ||
                         tbaa_tag_base_type(sub_tag) == tbaa_tag_access_type(sub_tag);
            if want_generic generic = ifx may_alias then sub_tag else tbaa_create_access_tag(common);
            return true, may_alias, generic;
        }
        if new_format && base_type == tbaa_tag_access_type(base_tag) break;
        base_type, offset_in_base = tbaa_type_get_field(base_type, offset_in_base);
    }
    if new_format {
        field_type := tbaa_tag_base_type(sub_tag);
        if tbaa_has_field(base_type, field_type) {
            if want_generic generic = tbaa_create_access_tag(common);
            return true, true, generic;
        }
    }
    return false, false, NONE;
}

// matchAccessTags(A, B, GenericTag): (may alias, generic tag)
tbaa_match_access_tags :: (a: Md_Id, b: Md_Id, want_generic := false) -> (bool, Md_Id) {
    if a == b return true, a;
    if a == NONE || b == NONE return true, NONE;
    common := tbaa_least_common_type(tbaa_tag_access_type(a), tbaa_tag_access_type(b));
    if common == NONE return true, NONE;
    ok, may, g := tbaa_may_be_access_to_subobject_of(a, b, common, want_generic);
    if ok return may, g;
    ok, may, g = tbaa_may_be_access_to_subobject_of(b, a, common, want_generic);
    if ok return may, g;
    return false, ifx want_generic then tbaa_create_access_tag(common) else NONE;
}
tbaa_aliases :: (a: Md_Id, b: Md_Id) -> bool { r, _ := tbaa_match_access_tags(a, b); return r; }
// MDNode::getMostGenericTBAA
tbaa_most_generic :: (a: Md_Id, b: Md_Id) -> Md_Id { _, g := tbaa_match_access_tags(a, b, true); return g; }

tbaa_should_use :: (aar: *Aa_Results) -> bool { return tbaa_opts.enable && aar.tbaa_enabled; }

// TypeBasedAAResult::alias
tbaa_alias :: (aar: *Aa_Results, a: Mem_Loc, b: Mem_Loc) -> Alias_Result {
    if !tbaa_should_use(aar) return ar(AR_MAY);
    if tbaa_aliases(a.tags.tbaa, b.tags.tbaa) return ar(AR_MAY);
    return ar(AR_NO);
}
// TypeBasedAAResult::aliasErrno
tbaa_alias_errno :: (aar: *Aa_Results, loc: Mem_Loc) -> u8 {
    if !tbaa_should_use(aar) return AR_MAY;
    n := loc.tags.tbaa;
    if n == NONE return AR_MAY;
    nmd: *Named_Md;
    for * ir.named_md if it.name == "llvm.errno.tbaa" { nmd = it; break; }
    if !nmd return AR_MAY;
    for nmd.ops if tbaa_aliases(n, it) return AR_MAY;
    return AR_NO;
}
// TypeBasedAAResult::getModRefInfoMask
tbaa_mod_ref_mask :: (aar: *Aa_Results, loc: Mem_Loc) -> u8 {
    if !tbaa_should_use(aar) return MR_MODREF;
    m := loc.tags.tbaa;
    if m == NONE return MR_MODREF;
    if tbaa_tag_is_type_immutable(m) return MR_NO;
    return MR_MODREF;
}
// TypeBasedAAResult::getMemoryEffects(Call)
tbaa_memory_effects_call :: (aar: *Aa_Results, call: Value_Id) -> u64 {
    if !tbaa_should_use(aar) return MEM_UNKNOWN;
    m := get_metadata(call, md_fixed("tbaa"));
    if m != NONE && tbaa_tag_is_type_immutable(m) return 0;
    return MEM_UNKNOWN;
}
// TypeBasedAAResult::getModRefInfo(Call, Loc)
tbaa_mod_ref_call_loc :: (aar: *Aa_Results, call: Value_Id, loc: Mem_Loc) -> u8 {
    if !tbaa_should_use(aar) return MR_MODREF;
    l := loc.tags.tbaa;
    if l != NONE {
        m := get_metadata(call, md_fixed("tbaa"));
        if m != NONE && !tbaa_aliases(l, m) return MR_NO;
    }
    return MR_MODREF;
}
// TypeBasedAAResult::getModRefInfo(Call1, Call2)
tbaa_mod_ref_call_call :: (aar: *Aa_Results, c1: Value_Id, c2: Value_Id) -> u8 {
    if !tbaa_should_use(aar) return MR_MODREF;
    m1 := get_metadata(c1, md_fixed("tbaa"));
    if m1 != NONE {
        m2 := get_metadata(c2, md_fixed("tbaa"));
        if m2 != NONE && !tbaa_aliases(m1, m2) return MR_NO;
    }
    return MR_MODREF;
}
