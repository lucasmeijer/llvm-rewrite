// Shared CFG-editing utilities used by SimplifyCFG (and reusable by any pass):
// - branch-weight metadata: llvm/lib/IR/ProfDataUtils.cpp (prof_*)
// - SwitchInst case API and SwitchInstProfUpdateWrapper: llvm/lib/IR/Instructions.cpp (sw_*, Sw_Prof)
// - DomTreeUpdater with the Eager strategy: llvm/lib/Analysis/DomTreeUpdater.cpp (Dtu, dtu_*)
// - DeleteDeadBlock(s) / detachDeadBlocks / emptyAndDetachBlock: llvm/lib/Transforms/Utils/BasicBlockUtils.cpp
// - BasicBlock::eraseFromParent of a block whose address is taken (~BasicBlock): llvm/lib/IR/BasicBlock.cpp
// - AttributeSet/AttributeList::intersectWith: llvm/lib/IR/Attributes.cpp (attr_set_intersect, attr_list_intersect)
// - MMRAMetadata (parse, ==, combine): llvm/lib/IR/MemoryModelRelaxationAnnotations.cpp (mmra_*)

// ---------------------------------------------------------------- ProfDataUtils.cpp

MD_PROF_NAME :: "prof";
prof_md :: (i: Value_Id) -> Md_Id { return get_metadata(i, md_kind_id(MD_PROF_NAME)); }
// isBranchWeightMD
prof_is_branch_weight_md :: (m: Md_Id) -> bool {
    if m == NONE || !md_is_node(m) || md_nops(m) < 3 return false;
    s := md_op(m, 0);
    return s != NONE && ir.mds[s].kind == .STRING && ir.mds[s].str == "branch_weights";
}
prof_has_branch_weight_md :: (i: Value_Id) -> bool { return prof_is_branch_weight_md(prof_md(i)); }
// hasBranchWeightOrigin
prof_has_branch_weight_origin :: (m: Md_Id) -> bool {
    if !prof_is_branch_weight_md(m) return false;
    s := md_op(m, 1);
    return s != NONE && ir.mds[s].kind == .STRING;
}
prof_num_branch_weights :: (m: Md_Id) -> u32 { return md_nops(m) - ifx prof_has_branch_weight_origin(m) then cast(u32) 2 else 1; }
// getValidBranchWeightMDNode
prof_valid_branch_weight_md :: (i: Value_Id) -> Md_Id {
    m := prof_md(i);
    if !prof_is_branch_weight_md(m) return NONE;
    if prof_num_branch_weights(m) == num_successors(i) return m;
    return NONE;
}
// extractFromBranchWeightMD64
prof_weights_of_md :: (m: Md_Id) -> [] u64 {
    first: u32 = ifx prof_has_branch_weight_origin(m) then cast(u32) 2 else 1;
    w := NewArray(md_nops(m) - first, u64,, allocator = temp);
    for k: first..md_nops(m)-1 {
        c := md_const_int_op(m, k);
        assert(c != NONE, "Malformed branch_weight in MD_prof node");
        w[k - first] = const_int_zext(c);
    }
    return w;
}
// extractBranchWeights(I, Weights)
prof_extract_branch_weights :: (i: Value_Id) -> (bool, [] u64) {
    m := prof_md(i);
    if !prof_is_branch_weight_md(m) return false, .[];
    return true, prof_weights_of_md(m);
}
// extractBranchWeights(I, TrueVal, FalseVal)
prof_extract_branch_weights_2 :: (i: Value_Id) -> (bool, u64, u64) {
    ok, w := prof_extract_branch_weights(i);
    if !ok || w.count > 2 return false, 0, 0;
    return true, w[0], w[1];
}
// fitWeights
prof_fit_weights :: (w: [] u64) -> [] u32 {
    mx: u64 = 0;
    for w if it > mx mx = it;
    out := NewArray(w.count, u32,, allocator = temp);
    if mx > 0xFFFF_FFFF {
        lz := 0; x := mx; while (x & 0x8000_0000_0000_0000) == 0 { x <<= 1; lz += 1; }
        off := cast(u64) (32 - lz);
        for w out[it_index] = cast(u32) (it >> off);
    } else for w out[it_index] = cast(u32) it;
    return out;
}
// setBranchWeights(I, Weights, IsExpected, ElideAllZero = true)
prof_set_branch_weights :: (i: Value_Id, w: [] u32, is_expected: bool, elide_all_zero := false) {
    if elide_all_zero {
        all0 := true;
        for w if it != 0 all0 = false;
        if all0 { set_metadata(i, md_kind_id(MD_PROF_NAME), NONE); return; }
    }
    ops: [..] Md_Id; ops.allocator = temp;
    array_add(*ops, md_string("branch_weights"));
    if is_expected array_add(*ops, md_string("expected"));
    i32 := type_int(cast(u64) 32);
    for w array_add(*ops, md_value(const_int(i32, it)));
    set_metadata(i, md_kind_id(MD_PROF_NAME), md_tuple(ops, false));
}
prof_set_branch_weights_u64 :: (i: Value_Id, w: [] u64, is_expected: bool) {
    w32 := NewArray(w.count, u32,, allocator = temp);
    for w w32[it_index] = cast(u32) it;
    prof_set_branch_weights(i, w32, is_expected);
}
// setFittedBranchWeights
prof_set_fitted_branch_weights :: (i: Value_Id, w: [] u64, is_expected := false, elide_all_zero := false) {
    prof_set_branch_weights(i, prof_fit_weights(w), is_expected, elide_all_zero);
}
// hasExplicitlyUnknownBranchWeights
prof_has_explicitly_unknown_branch_weights :: (i: Value_Id) -> bool {
    m := prof_md(i);
    if m == NONE || !md_is_node(m) || md_nops(m) != 2 return false;
    s := md_op(m, 0);
    return s != NONE && ir.mds[s].kind == .STRING && ir.mds[s].str == "unknown";
}

// ---------------------------------------------------------------- SwitchInst

// operands: [cond, default, dest_0, ..., dest_{n-1}], case value k in u_aux of operand 2 + k
sw_num_cases :: inline (sw: Value_Id) -> u32 { return nops(sw) - 2; }
sw_cond :: inline (sw: Value_Id) -> Value_Id { return op(sw, 0); }
sw_default :: inline (sw: Value_Id) -> Value_Id { return op(sw, 1); }
sw_case_value :: inline (sw: Value_Id, k: u32) -> Value_Id { return ir.u_aux[ir.v_ops[sw] + 2 + k]; }
sw_case_dest :: inline (sw: Value_Id, k: u32) -> Value_Id { return op(sw, 2 + k); }
sw_set_case_dest :: inline (sw: Value_Id, k: u32, b: Value_Id) { set_op(sw, 2 + k, b); }
sw_set_case_value :: inline (sw: Value_Id, k: u32, c: Value_Id) { ir.u_aux[ir.v_ops[sw] + 2 + k] = c; }
sw_set_default :: inline (sw: Value_Id, b: Value_Id) { set_op(sw, 1, b); }
// SwitchInst::Create(Cond, Default, NumCases) (unlinked)
create_switch :: (c: Value_Id, def: Value_Id, num_cases: u32) -> Value_Id {
    i := new_inst(.SWITCH, ir.t_void, 2);
    grow_ops(i, 2 + num_cases);
    set_op(i, 0, c); set_op(i, 1, def);
    return i;
}
// SwitchInst::addCase
sw_add_case :: (sw: Value_Id, c: Value_Id, dest: Value_Id) { add_op(sw, dest, c); }
// SwitchInst::removeCase: the last case moves into the hole
sw_remove_case :: (sw: Value_Id, k: u32) {
    n := nops(sw);
    if 2 + k + 1 != n {
        set_op(sw, 2 + k, op(sw, n - 1));
        ir.u_aux[ir.v_ops[sw] + 2 + k] = ir.u_aux[ir.v_ops[sw] + n - 1];
    }
    use_set(op_use(sw, n - 1), NONE);
    ir.u_aux[op_use(sw, n - 1)] = NONE;
    ir.v_nops[sw] = n - 1;
}
// findCaseValue: case index or -1 (default)
sw_find_case_value :: (sw: Value_Id, c: Value_Id) -> s64 {
    n := sw_num_cases(sw);
    for k: 0..cast(s64) n - 1 if sw_case_value(sw, cast(u32) k) == c return k;
    return -1;
}
// findCaseDest: the unique case value going to bb (NONE if none or several)
sw_find_case_dest :: (sw: Value_Id, bb: Value_Id) -> Value_Id {
    if bb == sw_default(sw) return NONE;
    r: Value_Id = NONE;
    for k: 0..cast(s64) sw_num_cases(sw) - 1 {
        if sw_case_dest(sw, cast(u32) k) == bb {
            if r != NONE return NONE;
            r = sw_case_value(sw, cast(u32) k);
        }
    }
    return r;
}
// defaultDestUnreachable: the default block starts with `unreachable` (getFirstNonPHIOrDbg)
sw_default_dest_unreachable :: (sw: Value_Id) -> bool {
    f := block_first_non_phi_or_dbg(sw_default(sw));
    return f != NONE && inst_op(f) == .UNREACHABLE;
}

// SwitchInstProfUpdateWrapper: weights tracked while cases change; sw_prof_done = the destructor
Sw_Prof :: struct { sw: Value_Id; have: bool; changed: bool; w: [..] u32; }
sw_prof_init :: (p: *Sw_Prof, sw: Value_Id) {
    p.sw = sw;
    p.w.allocator = temp;
    m := prof_md(sw);
    if !prof_is_branch_weight_md(m) return;
    if prof_num_branch_weights(m) != num_successors(sw) fatal("number of prof branch_weights metadata operands does not correspond to number of succesors");
    for prof_weights_of_md(m) array_add(*p.w, cast(u32) it);
    p.have = true;
}
sw_prof_remove_case :: (p: *Sw_Prof, k: u32) {
    if p.have {
        p.changed = true;
        p.w[k + 1] = p.w[p.w.count - 1];
        p.w.count -= 1;
    }
    sw_remove_case(p.sw, k);
}
sw_prof_add_case :: (p: *Sw_Prof, c: Value_Id, dest: Value_Id, has_w: bool, w: u32) {
    sw_add_case(p.sw, c, dest);
    if !p.have && has_w && w != 0 {
        p.changed = true;
        p.have = true;
        array_resize(*p.w, num_successors(p.sw));
        for *p.w it.* = 0;
        p.w[p.w.count - 1] = w;
    } else if p.have {
        p.changed = true;
        array_add(*p.w, ifx has_w then w else 0);
    }
}
sw_prof_get_weight :: (p: *Sw_Prof, idx: u32) -> (bool, u32) {
    if !p.have return false, 0;
    return true, p.w[idx];
}
sw_prof_set_weight :: (p: *Sw_Prof, idx: u32, has_w: bool, w: u32) {
    if !has_w return;
    if !p.have && w != 0 {
        p.have = true;
        array_resize(*p.w, num_successors(p.sw));
        for *p.w it.* = 0;
    }
    if p.have && p.w[idx] != w { p.changed = true; p.w[idx] = w; }
}
// replaceDefaultDest(case k)
sw_prof_replace_default_dest :: (p: *Sw_Prof, k: u32) {
    d := sw_case_dest(p.sw, k);
    if p.have p.w[0] = p.w[k + 1];
    sw_set_default(p.sw, d);
}
sw_prof_erase :: (p: *Sw_Prof) { p.changed = false; p.w.count = 0; }
sw_prof_done :: (p: *Sw_Prof) {
    if p.changed && p.have {
        if p.w.count >= 2 { prof_set_branch_weights(p.sw, p.w, false); return; }
        set_metadata(p.sw, md_kind_id(MD_PROF_NAME), NONE);
    }
}
// SwitchInstProfUpdateWrapper::getSuccessorWeight(SI, idx) (static)
sw_successor_weight :: (sw: Value_Id, idx: u32) -> (bool, u32) {
    m := prof_valid_branch_weight_md(sw);
    if m == NONE return false, 0;
    return true, cast(u32) prof_weights_of_md(m)[idx];
}

// ---------------------------------------------------------------- DomTreeUpdater (Eager)

// A null *Dtu = no DTU. With the Eager strategy every update is applied immediately.
Dtu :: struct { dt: *Dom_Tree; }
dtu_apply :: (dtu: *Dtu, updates: [] Dom_Update) {
    if !dtu || !dtu.dt || updates.count == 0 return;
    dt_apply_updates(dtu.dt, updates);
}
dtu_apply1 :: (dtu: *Dtu, insert: bool, from: Value_Id, to: Value_Id) {
    if !dtu return;
    u := Dom_Update.[.{insert, from, to}];
    dtu_apply(dtu, u);
}
// DomTreeUpdater::deleteBB: validateDeleteBB, eraseDelBBNode, eraseFromParent
dtu_delete_bb :: (dtu: *Dtu, bb: Value_Id) {
    validate_delete_bb(bb);
    if dtu && dtu.dt && dt_node(dtu.dt, bb) >= 0 dt_erase_node(dtu.dt, bb);
    block_erase_from_parent(bb);
}
// validateDeleteBB: everything goes, an `unreachable` is left
validate_delete_bb :: (bb: Value_Id) {
    while block_last(bb) != NONE {
        i := block_last(bb);
        if has_uses(i) rauw_with_metadata(i, const_poison(vtype(i)));
        drop_dbg_records(i);
        erase_inst_with_metadata(i);
    }
    u := new_inst(.UNREACHABLE, ir.t_void, 0);
    block_append_inst(bb, u);
}

// BasicBlock::eraseFromParent (~BasicBlock: a remaining blockaddress becomes inttoptr (i32 1))
block_erase_from_parent :: (bb: Value_Id) {
    // the address-taken case
    u := ir.v_first_use[bb];
    while u != NONE {
        nx := ir.u_next[u];
        user := ir.u_user[u];
        if vkind(user) == .C_BLOCKADDR {
            repl := ce_cast(.INTTOPTR, const_int(type_int(cast(u64) 32), 1), vtype(user));
            rauw_with_metadata(user, repl);
        }
        u = nx;
    }
    while block_last(bb) != NONE {
        i := block_last(bb);
        if has_uses(i) rauw_with_metadata(i, const_poison(vtype(i)));
        drop_dbg_records(i);
        erase_inst_with_metadata(i);
    }
    f := block_fn(bb);
    fn_unlink_block(f, bb);
    if vname(bb).count set_name(bb, "");
    ir.v_kind[bb] = .DEAD;
}

// ---------------------------------------------------------------- BasicBlockUtils.cpp

// emptyAndDetachBlock
empty_and_detach_block :: (bb: Value_Id, updates: *[..] Dom_Update, keep_one_input_phis: bool) {
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    uniq: [..] Value_Id; uniq.allocator = temp;
    for s: succs {
        block_remove_predecessor(s, bb, keep_one_input_phis);
        if updates {
            seen := false;
            for uniq if it == s seen = true;
            if !seen { array_add(*uniq, s); array_add(updates, .{false, bb, s}); }
        }
    }
    while block_last(bb) != NONE {
        i := block_last(bb);
        if has_uses(i) rauw_with_metadata(i, const_poison(vtype(i)));
        drop_dbg_records(i);
        erase_inst_with_metadata(i);
    }
    u := new_inst(.UNREACHABLE, ir.t_void, 0);
    block_append_inst(bb, u);
}
// detachDeadBlocks
detach_dead_blocks :: (bbs: [] Value_Id, updates: *[..] Dom_Update, keep_one_input_phis: bool) {
    for bb: bbs {
        f := block_first_non_phi(bb);
        if f != NONE && (inst_op(f) == .CATCHPAD || inst_op(f) == .CLEANUPPAD) {
            rets: [..] Value_Id; rets.allocator = temp;
            u := ir.v_first_use[f];
            while u != NONE {
                user := ir.u_user[u];
                if is_inst(user) && (inst_op(user) == .CATCHRET || inst_op(user) == .CLEANUPRET) {
                    rb := inst_block(user);
                    seen := false;
                    for rets if it == rb seen = true;
                    if !seen array_add(*rets, rb);
                }
                u = ir.u_next[u];
            }
            for rets empty_and_detach_block(it, updates, keep_one_input_phis);
        }
        empty_and_detach_block(bb, updates, keep_one_input_phis);
    }
}
// DeleteDeadBlocks(BBs, DTU, KeepOneInputPHIs)
delete_dead_blocks :: (bbs: [] Value_Id, dtu: *Dtu, keep_one_input_phis := false) {
    updates: [..] Dom_Update; updates.allocator = temp;
    detach_dead_blocks(bbs, ifx dtu then *updates else null, keep_one_input_phis);
    if dtu dtu_apply(dtu, updates);
    for bbs {
        if dtu dtu_delete_bb(dtu, it);
        else block_erase_from_parent(it);
    }
}
delete_dead_block :: (bb: Value_Id, dtu: *Dtu, keep_one_input_phis := false) {
    a := Value_Id.[bb];
    delete_dead_blocks(a, dtu, keep_one_input_phis);
}
U64_MAX : u64 : 0xFFFF_FFFF_FFFF_FFFF;

// DataLayout::hasUnstableRepresentation (getIntPtrType: dl_int_ptr_type, const_folding.jai)
dl_unstable_repr :: (t: Type_Id) -> bool { return dl_ptr_spec(ptr_addrspace(t)).unstable; }

// ---------------------------------------------------------------- Attributes.cpp intersection

// Attribute::operator==
attr_equal :: (a: *Attr, b: *Attr) -> bool {
    if a.kind != b.kind || a.ival != b.ival || a.ty != b.ty || a.key != b.key || a.val != b.val return false;
    if a.lo.count != b.lo.count || a.hi.count != b.hi.count return false;
    for a.lo if it != b.lo[it_index] return false;
    for a.hi if it != b.hi[it_index] return false;
    return true;
}
// AttributeSet::intersectWith: false when the sets cannot be intersected
attr_set_intersect :: (s0: u32, s1: u32) -> (bool, u32) {
    if s0 == s1 return true, s0;
    a := attr_set_items(s0); b := attr_set_items(s1);
    out: [..] Attr; out.allocator = temp;
    i := 0; j := 0;
    while i < a.count || j < b.count {
        x: *Attr; y: *Attr;
        if j == b.count { x = *a[i]; i += 1; }
        else if i == a.count { x = *b[j]; j += 1; }
        else {
            // cmpKind: enum kinds by value, string attributes after them by key
            pa := *a[i]; pb := *b[j];
            c: int;
            if pa.kind == .STRING_ATTR && pb.kind == .STRING_ATTR c = compare(pa.key, pb.key);
            else c = cast(int) pa.kind - cast(int) pb.kind;
            if c == 0 { x = pa; y = pb; i += 1; j += 1; }
            else if c < 0 { x = pa; i += 1; }
            else { x = pb; j += 1; }
        }
        if x.kind == .STRING_ATTR {
            if !y || !attr_equal(x, y) return false, 0;
            array_add(*out, x.*);
            continue;
        }
        prop := attr_intersect_property(x.kind);
        if !y {
            if prop == .PRESERVE return false, 0;
            continue;
        }
        if prop == .AND { r: Attr; r.kind = x.kind; r.ty = NONE; array_add(*out, r); continue; }
        if prop == .MIN { r := x.*; r.ival = min(x.ival, y.ival); array_add(*out, r); continue; }
        if prop == .CUSTOM {
            r := x.*;
            if x.kind == {
                case .Alignment; r.ival = min(max(x.ival, 1), max(y.ival, 1));
                case .Memory; r.ival = x.ival | y.ival;
                case .Captures; r.ival = x.ival | y.ival;
                case .NoFPClass; r.ival = x.ival & y.ival;
                case .Range;
                    nr := cr_union(attr_range(x), attr_range(y));
                    if cr_is_full_set(nr) continue;
                    lw := ap_words(nr.lo); hw := ap_words(nr.hi);
                    r.ival = nr.lo.bits;
                    r.lo = NewArray(lw.count, u64,, temp); for lw r.lo[it_index] = it;
                    r.hi = NewArray(hw.count, u64,, temp); for hw r.hi[it_index] = it;
                case; fatal("attr_set_intersect: unknown custom intersection rule");
            }
            array_add(*out, r);
            continue;
        }
        if !attr_equal(x, y) return false, 0;
        array_add(*out, x.*);
        if x.kind == .ByVal {
            al0 := attr_set_find(s0, .Alignment); al1 := attr_set_find(s1, .Alignment);
            if (al0 == null) != (al1 == null) || (al0 && al0.ival != al1.ival) return false, 0;
        }
    }
    return true, attr_set_get(out);
}
// AttributeList::intersectWith
attr_list_intersect :: (l0: u32, l1: u32) -> (bool, u32) {
    if l0 == l1 return true, l0;
    ok, fn := attr_set_intersect(attr_list_fn(l0), attr_list_fn(l1));
    if !ok return false, 0;
    ok2, ret := attr_set_intersect(attr_list_ret(l0), attr_list_ret(l1));
    if !ok2 return false, 0;
    n := 0;
    if l0 n = max(n, ir.attr_lists[l0].params.count);
    if l1 n = max(n, ir.attr_lists[l1].params.count);
    ps: [..] u32; ps.allocator = temp;
    for k: 0..n-1 {
        ok3, p := attr_set_intersect(attr_list_param(l0, cast(u32) k), attr_list_param(l1, cast(u32) k));
        if !ok3 return false, 0;
        array_add(*ps, p);
    }
    return true, attr_list_get(fn, ret, ps);
}

// ---------------------------------------------------------------- MemoryModelRelaxationAnnotations.cpp

Mmra_Tag :: struct { prefix: string; suffix: string; }
// MMRAMetadata(MDNode*): a single tag tuple !{!"p", !"s"} or a tuple of them; duplicates collapse (a set)
mmra_parse :: (m: Md_Id) -> [..] Mmra_Tag {
    r: [..] Mmra_Tag; r.allocator = temp;
    if m == NONE return r;
    is_tag :: (t: Md_Id) -> bool {
        return ir.mds[t].kind == .TUPLE && md_nops(t) == 2 && ir.mds[md_op(t, 0)].kind == .STRING && ir.mds[md_op(t, 1)].kind == .STRING;
    }
    add :: (r: *[..] Mmra_Tag, t: Md_Id) {
        tag := Mmra_Tag.{md_str_of(md_op(t, 0)), md_str_of(md_op(t, 1))};
        for r.* if it.prefix == tag.prefix && it.suffix == tag.suffix return;
        array_add(r, tag);
    }
    if is_tag(m) { add(*r, m); return r; }
    for k: 0..cast(s64) md_nops(m) - 1 add(*r, md_op(m, cast(u32) k));
    return r;
}
mmra_has_prefix :: (t: [] Mmra_Tag, p: string) -> bool { for t if it.prefix == p return true; return false; }
mmra_has_tag :: (t: [] Mmra_Tag, x: Mmra_Tag) -> bool { for t if it.prefix == x.prefix && it.suffix == x.suffix return true; return false; }
// MMRAMetadata::operator== (set equality)
mmra_equal :: (a: Md_Id, b: Md_Id) -> bool {
    if a == b return true;
    ta := mmra_parse(a); tb := mmra_parse(b);
    if ta.count != tb.count return false;
    for ta if !mmra_has_tag(tb, it) return false;
    return true;
}
// MMRAMetadata::combine(Ctx, A, B)
mmra_combine :: (a: Md_Id, b: Md_Id) -> Md_Id {
    ta := mmra_parse(a); tb := mmra_parse(b);
    // the tags of each side are visited in DenseSet (hash) order
    if ta.count > 1 || tb.count > 1 fatal("MMRAMetadata::combine with more than one tag on a side (DenseSet iteration order) is not supported yet");
    res: [..] Md_Id; res.allocator = temp;
    tag_md :: (t: Mmra_Tag) -> Md_Id { ops := Md_Id.[md_string(t.prefix), md_string(t.suffix)]; return md_tuple(ops, false); }
    for ta if mmra_has_prefix(tb, it.prefix) array_add(*res, tag_md(it));
    for tb if mmra_has_prefix(ta, it.prefix) array_add(*res, tag_md(it));
    return md_tuple(res, false);
}
