// Reassociate: port of llvm/lib/Transforms/Scalar/Reassociate.cpp (and include/llvm/Transforms/Scalar/Reassociate.h).
//
// State = ReassociatePass's members (RankMap, ValueRankMap, RedoInsts, PairMap, MadeChange) in the global `ra`,
// reset per function. OrderedSet (SetVector over a deque) is `Ra_Set`: an append-only array with tombstones and a
// value -> index table, so insert/remove/front/pop_back are LLVM's operations in LLVM's order.
// PairMap keys are LLVM's (Value*, Value*) pairs canonicalized by std::less; here by id (only membership matters).
// Its WeakVH validity check is "neither value is DEAD" (ids are never reused, so the address-reuse case of LLVM
// cannot happen and the lookup just misses, which scores the same 0).

Ra_Ve :: struct { rank: u32; op: Value_Id; }          // reassociate::ValueEntry
Ra_Rv :: struct { v: Value_Id; w: u64; }              // RepeatedValue
Ra_Factor :: struct { base: Value_Id; power: u32; }   // reassociate::Factor

Ra_Set :: struct {
    items: [..] Value_Id;      // NONE = removed
    head: s64;
    index: Table(Value_Id, s64);
}
rs_init :: (s: *Ra_Set) { s.items.allocator = temp; s.index.allocator = temp; }
rs_contains :: (s: *Ra_Set, v: Value_Id) -> bool { return table_contains(*s.index, v); }
rs_insert :: (s: *Ra_Set, v: Value_Id) {
    if table_contains(*s.index, v) return;
    table_set(*s.index, v, s.items.count);
    array_add(*s.items, v);
}
rs_remove :: (s: *Ra_Set, v: Value_Id) {
    p := table_find_pointer(*s.index, v);
    if !p return;
    s.items[p.*] = NONE;
    table_remove(*s.index, v);
}
rs_empty :: (s: *Ra_Set) -> bool { return s.index.count == 0; }
rs_pop_back :: (s: *Ra_Set) -> Value_Id {
    while s.items.count > s.head && s.items[s.items.count - 1] == NONE s.items.count -= 1;
    v := s.items[s.items.count - 1];
    s.items.count -= 1;
    table_remove(*s.index, v);
    return v;
}
rs_pop_front :: (s: *Ra_Set) -> Value_Id {
    while s.items[s.head] == NONE s.head += 1;
    v := s.items[s.head];
    s.items[s.head] = NONE;
    s.head += 1;
    table_remove(*s.index, v);
    return v;
}
rs_copy :: (dst: *Ra_Set, src: *Ra_Set) {
    rs_init(dst);
    for k: src.head..src.items.count - 1 if src.items[k] != NONE rs_insert(dst, src.items[k]);
}

Ra_Pair :: struct { v1: Value_Id; v2: Value_Id; score: u32; }

Ra_State :: struct {
    rank_map: Table(Value_Id, u32);         // blocks
    value_rank_map: Table(Value_Id, u32);
    redo: Ra_Set;
    pair_map: [32] Table(u64, Ra_Pair);     // indexed by opcode (binary operators are 14..31)
    made_change: bool;
}
ra: Ra_State;

RA_GLOBAL_REASSOCIATE_LIMIT :: 10;

ra_cl: struct {
    use_cse_local := true;   // -reassociate-use-cse-local
}

reassociate_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name != "reassociate-use-cse-local" return false;
    if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" ra_cl.use_cse_local = true;
    else if value == "false" || value == "0" || value == "FALSE" || value == "False" ra_cl.use_cse_local = false;
    else fatal(tprint("opt: invalid value '%' for -reassociate-use-cse-local", value));
    return true;
}

// DenseMap::operator[] (inserts a zero entry when absent, which ValueRankMap.contains later sees)
// Value::hasOneUse (ConstantData has no use list in LLVM)
value_has_one_use :: (v: Value_Id) -> bool { return !is_constant_data(v) && has_one_use(v); }

ra_vrm_get :: (v: Value_Id) -> u32 {
    p := table_find_pointer(*ra.value_rank_map, v);
    if p return p.*;
    table_set(*ra.value_rank_map, v, 0);
    return 0;
}
ra_rm_get :: (b: Value_Id) -> u32 {
    p := table_find_pointer(*ra.rank_map, b);
    if p return p.*;
    table_set(*ra.rank_map, b, 0);
    return 0;
}

// isa<ConstantInt>: a vector-typed ConstantInt exists only with -use-constant-int-for-{fixed-length,scalable}-splat;
// scalable int splats are C_INT here but a shufflevector constant expression in LLVM by default
ra_isa_constant_int :: (v: Value_Id) -> bool {
    if vkind(v) != .C_INT return false;
    return !(type_kind(vtype(v)) == .SVECTOR && !opts.use_constant_int_for_scalable_splat);
}

ra_is_int_or_int_vec :: (t: Type_Id) -> bool { return is_int_type(scalar_type(t)); }

// hasFPAssociativeFlags
ra_has_fp_associative_flags :: (i: Value_Id) -> bool {
    f := get_fmf(i);
    return (f & FMF_REASSOC) != 0 && (f & FMF_NSZ) != 0;
}

// isReassociableOp(V, Opcode[, Opcode2])
ra_is_reassociable_op :: (v: Value_Id, opc1: Opcode, opc2: Opcode = .NONE_OP) -> Value_Id {
    if !is_binary_operator(v) || !value_has_one_use(v) return NONE;
    o := inst_op(v);
    if o != opc1 && (opc2 == .NONE_OP || o != opc2) return NONE;
    if !is_fp_math_operator(v) || ra_has_fp_associative_flags(v) return v;
    return NONE;
}

// mayHaveNonDefUseDependency (ValueTracking.cpp)
may_have_non_def_use_dependency :: (i: Value_Id) -> bool {
    if may_read_or_write_memory(i) return true;
    if !is_safe_to_speculatively_execute_full(i) return true;
    if !is_guaranteed_to_transfer_execution(i) return true;
    return false;
}

// Instruction::moveBefore(BB, It) (moveBeforeImpl with Preserve = false); pos NONE = end of bb
ra_move_before :: (i: Value_Id, bb: Value_Id, pos: Value_Id, head: bool) {
    if inst(i).records && (pos != i || head) {
        nx := inst_next(i);
        if nx == NONE fatal("reassociate: moving an instruction with trailing debug records is not supported yet");
        records_prepend(nx, records_take(i));
    }
    if pos != i {
        inst_unlink(i);
        if pos == NONE block_append_inst(bb, i); else inst_insert_before(i, pos);
    }
    if !head && pos != NONE && pos != i && inst(pos).records records_append(i, records_take(pos));
}

// new BinaryOperator(..., Name, InsertBefore = I->getIterator())
ra_insert_named :: (i: Value_Id, pos: Value_Id, name: string) -> Value_Id {
    insert_at_position(i, inst_block(pos), pos, false);
    if name.count set_name(i, name);
    return i;
}

ra_create_add :: (s1: Value_Id, s2: Value_Id, name: string, pos: Value_Id, flags_op: Value_Id) -> Value_Id {
    if ra_is_int_or_int_vec(vtype(s1)) return ra_insert_named(create_binop(.ADD, s1, s2), pos, name);
    r := create_binop(.FADD, s1, s2);
    set_fmf(r, get_fmf(flags_op));
    return ra_insert_named(r, pos, name);
}
ra_create_mul :: (s1: Value_Id, s2: Value_Id, name: string, pos: Value_Id, flags_op: Value_Id) -> Value_Id {
    if ra_is_int_or_int_vec(vtype(s1)) return ra_insert_named(create_binop(.MUL, s1, s2), pos, name);
    r := create_binop(.FMUL, s1, s2);
    set_fmf(r, get_fmf(flags_op));
    return ra_insert_named(r, pos, name);
}
ra_create_neg :: (s1: Value_Id, name: string, pos: Value_Id, flags_op: Value_Id) -> Value_Id {
    if ra_is_int_or_int_vec(vtype(s1)) return ra_insert_named(create_neg(s1), pos, name);
    if is_inst(flags_op) return ra_insert_named(create_fneg_fmf(s1, flags_op), pos, name);
    r := new_inst(.FNEG, vtype(s1), 1);
    set_op(r, 0, s1);
    return ra_insert_named(r, pos, name);
}

// ---------------------------------------------------------------- ranks

// BuildRankMap
ra_build_rank_map :: (f: Value_Id, rpot: [] Value_Id) {
    rank: u32 = 2;
    g := glob(f);
    for k: 0..cast(s64) g.nargs - 1 {
        rank += 1;
        table_set(*ra.value_rank_map, g.arg_start + cast(u32) k, rank);
    }
    for bb: rpot {
        rank += 1;
        bb_rank := rank << 16;
        table_set(*ra.rank_map, bb, bb_rank);
        for i: block_insts(bb) {
            if may_have_non_def_use_dependency(i) {
                bb_rank += 1;
                table_set(*ra.value_rank_map, i, bb_rank);
            }
        }
    }
}

// getRank (explicit worklist)
ra_get_rank :: (v: Value_Id) -> u32 {
    Item :: struct { v: Value_Id; op_no: u32; rank: u32; }
    wl: [..] Item; wl.allocator = temp;
    array_add(*wl, .{v, 0, 0});
    while true {
        item := *wl[wl.count - 1];
        r: u32 = 0;
        if !is_inst(item.v) {
            r = ifx vkind(item.v) == .ARGUMENT then ra_vrm_get(item.v) else 0;
        } else {
            i := item.v;
            known := ra_vrm_get(i);
            if known {
                r = known;
            } else if item.op_no == nops(i) || item.rank == ra_rm_get(inst_block(i)) {
                r = item.rank;
                ok1 := pm_not(i);
                ok2 := pm_neg(i);
                ok3 := pm_fneg(i);
                if !ok1 && !ok2 && !ok3 r += 1;
                table_set(*ra.value_rank_map, i, r);
            } else {
                array_add(*wl, .{op(i, item.op_no), 0, 0});
                continue;
            }
        }
        wl.count -= 1;
        if wl.count == 0 return r;
        parent := *wl[wl.count - 1];
        parent.rank = max(parent.rank, r);
        parent.op_no += 1;
    }
    return 0;
}

// canonicalizeOperands
ra_canonicalize_operands :: (i: Value_Id) {
    lhs := op(i, 0); rhs := op(i, 1);
    if lhs == rhs || is_constant_kind(vkind(rhs)) return;
    if is_constant_kind(vkind(lhs)) || ra_get_rank(rhs) < ra_get_rank(lhs) {
        swap_operands(i);
        ra.made_change = true;
    }
}

// LowerNegateToMultiply: replace 0-X with X*-1
ra_lower_negate_to_multiply :: (neg: Value_Id) -> Value_Id {
    op_no: u32 = ifx is_binary_operator(neg) then cast(u32) 1 else 0;
    ty := vtype(neg);
    neg_one := ifx ra_is_int_or_int_vec(ty) then cf_all_ones(ty) else fp_const(ty, -1);
    res := ra_create_mul(op(neg, op_no), neg_one, "", neg, neg);
    set_op(neg, op_no, const_null_value(ty));
    ic_take_name(res, neg);
    rauw_with_metadata(neg, res);
    copy_debug_loc_or_clear(res, neg);
    return res;
}

// ---------------------------------------------------------------- linearization

// LinearizeExprTree
ra_linearize_expr_tree :: (root: Value_Id, ops: *[..] Ra_Rv, to_redo: *Ra_Set, flags: *Overflow_Tracking) -> bool {
    opcode := inst_op(root);
    Wl :: struct { i: Value_Id; w: u64; }
    worklist: [..] Wl; worklist.allocator = temp;
    array_add(*worklist, .{root, 1});
    changed := false;
    leaves: Table(Value_Id, u64); leaves.allocator = temp;
    leaf_order: [..] Value_Id; leaf_order.allocator = temp;

    while worklist.count {
        top := pop(*worklist);
        i := top.i;
        weight := top.w;
        ot_merge_flags(flags, i);
        op_idx: u32 = 0;
        while op_idx < nops(i) {
            defer op_idx += 1;
            o := op(i, op_idx);
            bo := ra_is_reassociable_op(o, opcode);
            if bo != NONE {
                array_add(*worklist, .{bo, weight});
                continue;
            }
            p := table_find_pointer(*leaves, o);
            if !p {
                if !value_has_one_use(o) {
                    array_add(*leaf_order, o);
                    table_set(*leaves, o, weight);
                    continue;
                }
            } else {
                p.* += weight;
                if !value_has_one_use(o) continue;
                weight = p.*;
                table_remove(*leaves, o);
            }
            // morph negations in multiply trees into multiplies by -1
            is_neg := false;
            if opcode == .MUL { ok := pm_neg(o); is_neg = ok; }
            else if opcode == .FMUL { ok := pm_fneg(o); is_neg = ok; }
            if is_neg && is_inst(o) {
                neg := o;
                mul := ra_lower_negate_to_multiply(neg);
                array_add(*worklist, .{mul, weight});
                u := ir.v_first_use[mul];
                while u != NONE {
                    us := ir.u_user[u];
                    if is_binary_operator(us) rs_insert(to_redo, us);
                    u = ir.u_next[u];
                }
                rs_insert(to_redo, neg);
                changed = true;
                continue;
            }
            array_add(*leaf_order, o);
            table_set(*leaves, o, weight);
        }
    }

    q: Simplify_Query; q.have_tli = false;
    for v: leaf_order {
        p := table_find_pointer(*leaves, v);
        if !p continue;
        weight := p.*;
        p.* = 0;
        array_add(ops, .{v, weight});
        if opcode == .ADD && flags.all_known_non_negative && flags.has_nsw {
            flags.all_known_non_negative = flags.all_known_non_negative && is_known_non_negative(v, q);
        } else if opcode == .MUL {
            if flags.all_known_non_zero && (flags.has_nuw || (flags.has_nsw && flags.all_known_non_negative)) {
                flags.all_known_non_zero = flags.all_known_non_zero && is_known_non_zero(v, q);
                if flags.has_nsw && flags.all_known_non_negative
                    flags.all_known_non_negative = flags.all_known_non_negative && is_known_non_negative(v, q);
            }
        }
    }

    if ops.count == 0 {
        identity := cf_binop_identity(opcode, vtype(root), false);
        assert(identity != NONE);
        array_add(ops, .{identity, 1});
    }
    return changed;
}

// ---------------------------------------------------------------- rewriting

// RewriteExprTree
ra_rewrite_expr_tree :: (root: Value_Id, ops: [] Ra_Ve, flags_in: Overflow_Tracking) {
    flags := flags_in;
    assert(ops.count > 1);
    nodes_to_rewrite: [..] Value_Id; nodes_to_rewrite.allocator = temp;
    opcode := inst_op(root);
    o := root;
    not_rewritable: Table(Value_Id, bool); not_rewritable.allocator = temp;
    for ops table_set(*not_rewritable, it.op, true);
    changed_start: Value_Id = NONE;
    changed_end: Value_Id = NONE;
    i := 0;
    while true {
        defer i += 1;
        if i + 2 == ops.count {
            new_lhs := ops[i].op; new_rhs := ops[i + 1].op;
            old_lhs := op(o, 0); old_rhs := op(o, 1);
            if new_lhs == old_lhs && new_rhs == old_rhs break;
            if new_lhs == old_rhs && new_rhs == old_lhs {
                swap_operands(o);
                ra.made_change = true;
                break;
            }
            if new_lhs != old_lhs {
                bo := ra_is_reassociable_op(old_lhs, opcode);
                if bo != NONE && !table_contains(*not_rewritable, bo) array_add(*nodes_to_rewrite, bo);
                salvage_debug_info(o);
                set_op(o, 0, new_lhs);
            }
            if new_rhs != old_rhs {
                bo := ra_is_reassociable_op(old_rhs, opcode);
                if bo != NONE && !table_contains(*not_rewritable, bo) array_add(*nodes_to_rewrite, bo);
                salvage_debug_info(o);
                set_op(o, 1, new_rhs);
            }
            changed_start = o;
            if changed_end == NONE changed_end = o;
            ra.made_change = true;
            break;
        }

        new_rhs := ops[i].op;
        if new_rhs != op(o, 1) {
            if new_rhs == op(o, 0) {
                swap_operands(o);
            } else {
                bo := ra_is_reassociable_op(op(o, 1), opcode);
                if bo != NONE && !table_contains(*not_rewritable, bo) array_add(*nodes_to_rewrite, bo);
                salvage_debug_info(o);
                set_op(o, 1, new_rhs);
                changed_start = o;
                if changed_end == NONE changed_end = o;
            }
            ra.made_change = true;
        }

        bo := ra_is_reassociable_op(op(o, 0), opcode);
        if bo != NONE && !table_contains(*not_rewritable, bo) {
            o = bo;
            continue;
        }

        new_op: Value_Id;
        if nodes_to_rewrite.count == 0 {
            p := const_poison(vtype(root));
            new_op = create_binop(opcode, p, p);
            insert_at_position(new_op, inst_block(root), root, false);
            if is_fp_math_operator(new_op) set_fmf(new_op, get_fmf(root));
        } else {
            new_op = pop(*nodes_to_rewrite);
        }
        salvage_debug_info(o);
        set_op(o, 0, new_op);
        changed_start = o;
        if changed_end == NONE changed_end = o;
        ra.made_change = true;
        o = new_op;
    }

    if changed_start != NONE {
        clear_flags := true;
        while true {
            if clear_flags {
                if is_fp_math_operator(root) set_fmf(changed_start, get_fmf(root));
                else ot_apply_flags(*flags, changed_start);
            }
            if changed_start == changed_end clear_flags = false;
            if changed_start == root break;
            ra_move_before(changed_start, inst_block(root), root, false);
            changed_start = first_user(changed_start);
        }
    }

    for nodes_to_rewrite rs_insert(*ra.redo, it);
}

// NegateValue
ra_negate_value :: (v: Value_Id, bi: Value_Id, to_redo: *Ra_Set) -> Value_Id {
    if is_constant_kind(vkind(v)) {
        res: Value_Id = NONE;
        if is_fp_type(scalar_type(vtype(v))) res = cfo_unary_op_operand(.FNEG, v);
        else res = ce_neg(v);
        if res != NONE return res;
    }

    i := ra_is_reassociable_op(v, .ADD, .FADD);
    if i != NONE {
        set_op(i, 0, ra_negate_value(op(i, 0), bi, to_redo));
        set_op(i, 1, ra_negate_value(op(i, 1), bi, to_redo));
        if inst_op(i) == .ADD inst(i).flags &= ~cast(u32) (F_NUW | F_NSW);
        ra_move_before(i, inst_block(bi), bi, false);
        set_name(i, tprint("%.neg", vname(i)));
        rs_insert(to_redo, i);
        return i;
    }

    u := ir.v_first_use[v];
    while u != NONE {
        defer u = ir.u_next[u];
        us := ir.u_user[u];
        okn := pm_neg(us);
        okf := pm_fneg(us);
        if !okn && !okf continue;
        if !is_inst(us) continue;
        the_neg := us;
        if is_binary_operator(the_neg) && is_constant_kind(vkind(op(the_neg, 0))) &&
           contains_undef_or_poison_element(op(the_neg, 0)) continue;
        if inst_fn(the_neg) != inst_fn(bi) continue;
        pos: Value_Id; pbb: Value_Id; head: bool;
        if is_inst(v) {
            pos, pbb, head = inst_insertion_point_after_def(v);
            if pos == NONE continue;
        } else {
            pbb = fn_entry(inst_fn(the_neg));
            pos = block_first_non_phi_or_dbg(pbb);
            head = false;
        }
        if inst_block(the_neg) != pbb drop_location(the_neg);
        ra_move_before(the_neg, pbb, pos, head);
        if inst_op(the_neg) == .SUB inst(the_neg).flags &= ~cast(u32) (F_NUW | F_NSW);
        else and_ir_flags(the_neg, bi);
        rs_insert(to_redo, the_neg);
        return the_neg;
    }

    new_neg := ra_create_neg(v, tprint("%.neg", vname(v)), bi, bi);
    copy_debug_loc_or_clear(new_neg, bi);
    rs_insert(to_redo, new_neg);
    return new_neg;
}

// isLoadCombineCandidate
ra_is_load_combine_candidate :: (or: Value_Id) -> bool {
    wl: [..] Value_Id; wl.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    enqueue :: (v: Value_Id, wl: *[..] Value_Id, visited: *Table(Value_Id, bool)) -> bool {
        if !is_inst(v) return false;
        if !table_contains(visited, v) { table_set(visited, v, true); array_add(wl, v); }
        return true;
    }
    if !enqueue(or, *wl, *visited) return false;
    while wl.count {
        i := pop(*wl);
        o := inst_op(i);
        if o == .OR {
            for k: 0..cast(s64) nops(i) - 1 if !enqueue(op(i, cast(u32) k), *wl, *visited) return false;
            continue;
        }
        if o == .SHL || o == .ZEXT {
            if !enqueue(op(i, 0), *wl, *visited) return false;
            continue;
        }
        if o == .LOAD continue;
        return false;
    }
    return true;
}

ra_is_interesting_for_or :: (v: Value_Id) -> bool {
    for Opcode.[.ADD, .SUB, .MUL, .SHL] if ra_is_reassociable_op(v, it) != NONE return true;
    return false;
}

// shouldConvertOrWithNoCommonBitsToAdd
ra_should_convert_or_with_no_common_bits_to_add :: (or: Value_Id) -> bool {
    for k: 0..cast(s64) nops(or) - 1 if ra_is_interesting_for_or(op(or, cast(u32) k)) return true;
    vb := first_user(or);
    if value_has_one_use(or) && ra_is_interesting_for_or(vb) return true;
    return false;
}

// convertOrWithNoCommonBitsToAdd
ra_convert_or_with_no_common_bits_to_add :: (or: Value_Id) -> Value_Id {
    n := ra_create_add(op(or, 0), op(or, 1), "", or, or);
    inst(n).flags |= F_NSW | F_NUW;
    ic_take_name(n, or);
    rauw_with_metadata(or, n);
    copy_debug_loc_or_clear(n, or);
    return n;
}

// ShouldBreakUpDistribution
ra_should_break_up_distribution :: (mul: Value_Id) -> bool {
    if !value_has_one_use(mul) || !is_binary_operator(mul) || inst_op(mul) != .MUL return false;
    l := op(mul, 0);
    if !value_has_one_use(l) || !pm_imm_constant(op(mul, 1)) return false;
    lo := opr_code(l);
    if lo != .ADD && lo != .SUB return false;
    a := op(l, 0); b := op(l, 1);
    mul_user := first_user(mul);
    uo := inst_op(mul_user);
    if uo != .ADD && uo != .SUB return false;
    for k: 0..cast(s64) nops(mul_user) - 1 {
        sib := op(mul_user, cast(u32) k);
        if sib == mul || !value_has_one_use(sib) continue;
        if opr_code(sib) == .MUL && pm_imm_constant(op(sib, 1)) {
            nc := op(sib, 0);
            if (nc == a || nc == b) && !is_constant_kind(vkind(nc)) return true;
        }
    }
    return false;
}

// BreakUpDistribute
ra_break_up_distribute :: (mul: Value_Id, to_redo: *Ra_Set) -> Value_Id {
    addsub := op(mul, 0);
    if !is_inst(addsub) fatal("reassociate: distributing over a constant-expression add/sub is not supported");
    c := op(mul, 1);
    c2 := ifx inst_op(addsub) == .SUB then ce_neg(c) else c;
    m1 := ra_insert_named(create_binop(.MUL, op(addsub, 0), c), mul, "Mul1");
    m2 := ra_insert_named(create_binop(.MUL, op(addsub, 1), c2), mul, "Mul2");
    result := ra_insert_named(create_binop(.ADD, m1, m2), mul, "DistAdd");
    rauw_with_metadata(mul, result);
    copy_debug_loc_or_clear(result, mul);
    rs_insert(to_redo, m1);
    rs_insert(to_redo, m2);
    rs_insert(to_redo, result);
    return result;
}

// ShouldBreakUpSubtract
ra_should_break_up_subtract :: (sub: Value_Id) -> bool {
    okn := pm_neg(sub); okf := pm_fneg(sub);
    if okn || okf return false;
    if is_undef_value(op(sub, 1)) return false;
    v0 := op(sub, 0);
    if ra_is_reassociable_op(v0, .ADD, .FADD) != NONE || ra_is_reassociable_op(v0, .SUB, .FSUB) != NONE return true;
    v1 := op(sub, 1);
    if ra_is_reassociable_op(v1, .ADD, .FADD) != NONE || ra_is_reassociable_op(v1, .SUB, .FSUB) != NONE return true;
    vb := first_user(sub);
    if value_has_one_use(sub) && (ra_is_reassociable_op(vb, .ADD, .FADD) != NONE || ra_is_reassociable_op(vb, .SUB, .FSUB) != NONE)
        return true;
    return false;
}

// BreakUpSubtract
ra_break_up_subtract :: (sub: Value_Id, to_redo: *Ra_Set) -> Value_Id {
    neg_val := ra_negate_value(op(sub, 1), sub, to_redo);
    n := ra_create_add(op(sub, 0), neg_val, "", sub, sub);
    set_op(sub, 0, const_null_value(vtype(sub)));
    set_op(sub, 1, const_null_value(vtype(sub)));
    ic_take_name(n, sub);
    rauw_with_metadata(sub, n);
    copy_debug_loc_or_clear(n, sub);
    return n;
}

// ConvertShiftToMul
ra_convert_shift_to_mul :: (shl: Value_Id) -> Value_Id {
    sa := op(shl, 1);
    mul_cst := cf_binary(.SHL, const_int(vtype(shl), 1), sa);
    assert(mul_cst != NONE);
    mul := ra_insert_named(create_binop(.MUL, op(shl, 0), mul_cst), shl, "");
    set_op(shl, 0, const_poison(vtype(shl)));
    ic_take_name(mul, shl);
    rauw_with_metadata(shl, mul);
    copy_debug_loc_or_clear(mul, shl);
    nsw := (inst(shl).flags & F_NSW) != 0;
    nuw := (inst(shl).flags & F_NUW) != 0;
    bw := type_bits(scalar_type(vtype(shl)));
    if nsw && (nuw || ap_ult_u64(cf_ap(sa), cast(u64) bw - 1)) inst(mul).flags |= F_NSW;
    if nuw inst(mul).flags |= F_NUW; else inst(mul).flags &= ~cast(u32) F_NUW;
    return mul;
}

// FindInOperandList
ra_find_in_operand_list :: (ops: [] Ra_Ve, i: s64, x: Value_Id) -> s64 {
    x_rank := ops[i].rank;
    j := i + 1;
    while j < ops.count && ops[j].rank == x_rank {
        if ops[j].op == x return j;
        if is_inst(ops[j].op) && is_inst(x) && is_identical_to(ops[j].op, x) return j;
        j += 1;
    }
    j = i - 1;
    while j >= 0 && ops[j].rank == x_rank {
        if ops[j].op == x return j;
        if is_inst(ops[j].op) && is_inst(x) && is_identical_to(ops[j].op, x) return j;
        j -= 1;
    }
    return i;
}

// EmitAddTreeOfValues (Ops are WeakTrackingVHs)
ra_emit_add_tree_of_values :: (i: Value_Id, ops: *[..] Vh) -> Value_Id {
    if ops.count == 1 return vh_get(ops.*[0]);
    v1 := vh_get(pop(ops));
    v2 := ra_emit_add_tree_of_values(i, ops);
    na := ra_create_add(v2, v1, "reass.add", i, i);
    copy_debug_loc_or_clear(na, i);
    return na;
}

ra_ops_from_tree :: (tree: [] Ra_Rv, out: *[..] Ra_Ve) {
    for tree {
        r := ra_get_rank(it.v);
        for k: 0..cast(s64) it.w - 1 array_add(out, .{r, it.v});
    }
}

// RemoveFactorFromExpression
ra_remove_factor_from_expression :: (v_in: Value_Id, factor: Value_Id, dl: Md_Id) -> Value_Id {
    v := v_in;
    bo := ra_is_reassociable_op(v, .MUL, .FMUL);
    if bo == NONE return NONE;
    tree: [..] Ra_Rv; tree.allocator = temp;
    flags: Overflow_Tracking;
    if ra_linearize_expr_tree(bo, *tree, *ra.redo, *flags) ra.made_change = true;
    factors: [..] Ra_Ve; factors.allocator = temp;
    ra_ops_from_tree(tree, *factors);

    found_factor := false;
    needs_negate := false;
    for k: 0..factors.count - 1 {
        if factors[k].op == factor {
            found_factor = true;
            array_ordered_remove_by_index(*factors, k);
            break;
        }
        if ra_isa_constant_int(factor) {
            f2 := factors[k].op;
            if ra_isa_constant_int(f2) && ap_eq(cf_ap(factor), ap_neg(cf_ap(f2))) {
                found_factor = true; needs_negate = true;
                array_ordered_remove_by_index(*factors, k);
                break;
            }
        } else if vkind(factor) == .C_FP {
            f2 := factors[k].op;
            if vkind(f2) == .C_FP {
                a := apf_from_const(factor);
                b := apf_from_const(f2);
                nb := b;
                nw := fp_neg(nb.k, apf_words(*nb));
                apf_set_words(*nb, nw);
                if apf_compare(a, nb) == .EQUAL {
                    found_factor = true; needs_negate = true;
                    array_ordered_remove_by_index(*factors, k);
                    break;
                }
            }
        }
    }

    if !found_factor {
        ra_rewrite_expr_tree(bo, factors, flags);
        return NONE;
    }

    insert_pt := inst_next(bo);
    if factors.count == 1 {
        rs_insert(*ra.redo, bo);
        v = factors[0].op;
    } else {
        ra_rewrite_expr_tree(bo, factors, flags);
        v = bo;
    }
    if needs_negate {
        v = ra_create_neg(v, "neg", insert_pt, bo);
        set_metadata(v, 0, dl);
    }
    return v;
}

// FindSingleUseMultiplyFactors
ra_find_single_use_multiply_factors :: (v: Value_Id, factors: *[..] Value_Id) {
    bo := ra_is_reassociable_op(v, .MUL, .FMUL);
    if bo == NONE { array_add(factors, v); return; }
    ra_find_single_use_multiply_factors(op(bo, 1), factors);
    ra_find_single_use_multiply_factors(op(bo, 0), factors);
}

// OptimizeAndOrXor
ra_optimize_and_or_xor :: (opcode: Opcode, ops: *[..] Ra_Ve) -> Value_Id {
    i := 0;
    e := ops.count;
    while i != e {
        defer i += 1;
        okx, x := pm_not(ops.*[i].op);
        if okx {
            found := ra_find_in_operand_list(ops.*, i, x);
            if found != i {
                if opcode == .AND return const_null_value(vtype(x));
                if opcode == .OR return cf_all_ones(vtype(x));
            }
        }
        if i + 1 != ops.count && ops.*[i + 1].op == ops.*[i].op {
            if opcode == .AND || opcode == .OR {
                array_ordered_remove_by_index(ops, i);
                i -= 1; e -= 1;
                continue;
            }
            assert(opcode == .XOR);
            if e == 2 return const_null_value(vtype(ops.*[0].op));
            array_ordered_remove_by_index(ops, i);
            array_ordered_remove_by_index(ops, i);
            i -= 1; e -= 2;
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- xor

// reassociate::XorOpnd
Ra_Xor_Opnd :: struct {
    orig: Value_Id;
    symbolic: Value_Id;
    const_part: APInt;
    symbolic_rank: u32;
    is_or: bool;
}
ra_xor_opnd :: (v: Value_Id) -> Ra_Xor_Opnd {
    r: Ra_Xor_Opnd;
    r.orig = v;
    r.symbolic_rank = 0;
    if is_inst(v) && (inst_op(v) == .OR || inst_op(v) == .AND) {
        v0 := op(v, 0); v1 := op(v, 1);
        ok0 := pm_apint(v0);
        if ok0 { t := v0; v0 = v1; v1 = t; }
        ok1, c := pm_apint(v1);
        if ok1 {
            r.const_part = ap_copy(c);
            r.symbolic = v0;
            r.is_or = inst_op(v) == .OR;
            return r;
        }
    }
    r.symbolic = v;
    r.const_part = ap_zero(type_bits(scalar_type(vtype(v))));
    r.is_or = true;
    return r;
}
ra_xor_invalidate :: (o: *Ra_Xor_Opnd) { o.symbolic = NONE; o.orig = NONE; }

// createAndInstr
ra_create_and_instr :: (pos: Value_Id, opnd: Value_Id, c: APInt) -> Value_Id {
    if ap_is_zero(c) return NONE;
    if ap_is_all_ones(c) return opnd;
    i := ra_insert_named(create_binop(.AND, opnd, cf_int(vtype(opnd), c)), pos, "and.ra");
    copy_debug_loc_or_clear(i, pos);
    return i;
}

// CombineXorOpnd (one operand and the constant)
ra_combine_xor_opnd1 :: (pos: Value_Id, o1: *Ra_Xor_Opnd, const_opnd: *APInt, res: *Value_Id) -> bool {
    if !o1.is_or || ap_is_zero(o1.const_part) return false;
    if !value_has_one_use(o1.orig) return false;
    c1 := o1.const_part;
    if !ap_eq(c1, const_opnd.*) return false;
    x := o1.symbolic;
    res.* = ra_create_and_instr(pos, x, ap_not(c1));
    const_opnd.* = ap_xor(const_opnd.*, c1);
    if is_inst(o1.orig) rs_insert(*ra.redo, o1.orig);
    return true;
}

// CombineXorOpnd (two operands and the constant)
ra_combine_xor_opnd2 :: (pos: Value_Id, o1_in: *Ra_Xor_Opnd, o2_in: *Ra_Xor_Opnd, const_opnd: *APInt, res: *Value_Id) -> bool {
    o1 := o1_in; o2 := o2_in;
    x := o1.symbolic;
    if x != o2.symbolic return false;
    dead_inst_num := 1;
    if value_has_one_use(o1.orig) dead_inst_num += 1;
    if value_has_one_use(o2.orig) dead_inst_num += 1;

    if o1.is_or != o2.is_or {
        if o2.is_or { t := o1; o1 = o2; o2 = t; }
        c1 := o1.const_part; c2 := o2.const_part;
        c3 := ap_xor(ap_not(c1), c2);
        if !ap_is_zero(c3) && !ap_is_all_ones(c3) {
            new_inst_num := ifx ap_bool(const_opnd.*) then 1 else 2;
            if new_inst_num > dead_inst_num return false;
        }
        res.* = ra_create_and_instr(pos, x, c3);
        const_opnd.* = ap_xor(const_opnd.*, c1);
    } else if o1.is_or {
        c1 := o1.const_part; c2 := o2.const_part;
        c3 := ap_xor(c1, c2);
        if !ap_is_zero(c3) && !ap_is_all_ones(c3) {
            new_inst_num := ifx ap_bool(const_opnd.*) then 1 else 2;
            if new_inst_num > dead_inst_num return false;
        }
        res.* = ra_create_and_instr(pos, x, c3);
        const_opnd.* = ap_xor(const_opnd.*, c3);
    } else {
        c3 := ap_xor(o1.const_part, o2.const_part);
        res.* = ra_create_and_instr(pos, x, c3);
    }
    if is_inst(o1.orig) rs_insert(*ra.redo, o1.orig);
    if is_inst(o2.orig) rs_insert(*ra.redo, o2.orig);
    return true;
}

// OptimizeXor
ra_optimize_xor :: (i: Value_Id, ops: *[..] Ra_Ve) -> Value_Id {
    v := ra_optimize_and_or_xor(.XOR, ops);
    if v != NONE return v;
    if ops.count == 1 return NONE;

    opnds: [..] Ra_Xor_Opnd; opnds.allocator = temp;
    ty := vtype(ops.*[0].op);
    const_opnd := ap_zero(type_bits(scalar_type(ty)));
    for ops.* {
        ok, c := pm_apint(it.op);
        if ok {
            const_opnd = ap_xor(const_opnd, c);
        } else {
            o := ra_xor_opnd(it.op);
            o.symbolic_rank = ra_get_rank(o.symbolic);
            array_add(*opnds, o);
        }
    }
    // OpndPtrs, stable-sorted by symbolic rank
    ptrs := NewArray(opnds.count, s64,, allocator = temp);
    for k: 0..opnds.count - 1 ptrs[k] = k;
    for k: 1..ptrs.count - 1 {   // insertion sort (stable)
        x := ptrs[k];
        j := k - 1;
        while j >= 0 && opnds[ptrs[j]].symbolic_rank > opnds[x].symbolic_rank { ptrs[j + 1] = ptrs[j]; j -= 1; }
        ptrs[j + 1] = x;
    }

    prev: *Ra_Xor_Opnd = null;
    changed := false;
    for k: 0..opnds.count - 1 {
        curr := *opnds[ptrs[k]];
        cv: Value_Id = NONE;
        if !ap_is_zero(const_opnd) && ra_combine_xor_opnd1(i, curr, *const_opnd, *cv) {
            changed = true;
            if cv != NONE curr.* = ra_xor_opnd(cv);
            else { ra_xor_invalidate(curr); continue; }
        }
        if !prev || curr.symbolic != prev.symbolic {
            prev = curr;
            continue;
        }
        if ra_combine_xor_opnd2(i, curr, prev, *const_opnd, *cv) {
            ra_xor_invalidate(prev);
            if cv != NONE {
                curr.* = ra_xor_opnd(cv);
                prev = curr;
            } else {
                ra_xor_invalidate(curr);
                prev = null;
            }
            changed = true;
        }
    }

    if changed {
        ops.count = 0;
        for opnds {
            if it.symbolic == NONE continue;
            array_add(ops, .{ra_get_rank(it.orig), it.orig});
        }
        if !ap_is_zero(const_opnd) {
            c := cf_int(ty, const_opnd);
            array_add(ops, .{ra_get_rank(c), c});
        }
        sz := ops.count;
        if sz == 1 return ops.*[sz - 1].op;
        if sz == 0 return cf_int(ty, const_opnd);
    }
    return NONE;
}

// ---------------------------------------------------------------- add

ra_is_better_factor :: (factor: Value_Id, max_occ_val: Value_Id, occ: u32, max_occ: u32) -> bool {
    if occ > max_occ return true;
    if occ != max_occ return false;
    return (is_inst(factor) || vkind(factor) == .ARGUMENT) && max_occ_val != NONE &&
           is_constant_kind(vkind(max_occ_val)) && !is_undef_value(max_occ_val);
}

// OptimizeAdd
ra_optimize_add :: (i: Value_Id, ops: *[..] Ra_Ve) -> Value_Id {
    k := 0;
    e := ops.count;
    while k != e {
        defer k += 1;
        the_op := ops.*[k].op;
        if k + 1 != ops.count && ops.*[k + 1].op == the_op {
            num_found: u64 = 0;
            while true {
                array_ordered_remove_by_index(ops, k);
                num_found += 1;
                if !(k != ops.count && ops.*[k].op == the_op) break;
            }
            ty := vtype(the_op);
            c := ifx ra_is_int_or_int_vec(ty) then const_int(ty, num_found) else fp_const(ty, cast(s64) num_found);
            mul := ra_create_mul(the_op, c, "factor", i, i);
            copy_debug_loc_or_clear(mul, i);
            rs_insert(*ra.redo, mul);
            if ops.count == 0 return mul;
            array_insert_at(ops, .{ra_get_rank(mul), mul}, 0);
            k -= 1;
            e = ops.count;
            continue;
        }

        ok1, x1 := pm_neg(the_op);
        ok2, x2 := pm_not(the_op);
        ok3, x3 := pm_fneg(the_op);
        x: Value_Id;
        if ok1 x = x1; else if ok2 x = x2; else if ok3 x = x3; else continue;

        found := ra_find_in_operand_list(ops.*, k, x);
        if found == k continue;

        if ops.count == 2 && (ok1 || ok3) return const_null_value(vtype(x));
        if ops.count == 2 && ok2 return cf_all_ones(vtype(x));

        array_ordered_remove_by_index(ops, k);
        if k < found found -= 1;
        else k -= 1;
        array_ordered_remove_by_index(ops, found);
        k -= 1;
        e -= 2;
        if ok2 {
            v := cf_all_ones(vtype(x));
            array_add(ops, .{ra_get_rank(v), v});
            e += 1;
        }
    }

    factor_occ: Table(Value_Id, u32); factor_occ.allocator = temp;
    max_occ: u32 = 0;
    max_occ_val: Value_Id = NONE;
    bump :: (factor: Value_Id, factor_occ: *Table(Value_Id, u32), max_occ: *u32, max_occ_val: *Value_Id) {
        p := table_find_pointer(factor_occ, factor);
        occ: u32 = 1;
        if p { p.* += 1; occ = p.*; } else table_set(factor_occ, factor, 1);
        if ra_is_better_factor(factor, max_occ_val.*, occ, max_occ.*) { max_occ.* = occ; max_occ_val.* = factor; }
    }
    for ops.* {
        bop := ra_is_reassociable_op(it.op, .MUL, .FMUL);
        if bop == NONE continue;
        factors: [..] Value_Id; factors.allocator = temp;
        ra_find_single_use_multiply_factors(bop, *factors);
        assert(factors.count > 1);
        dups: Table(Value_Id, bool); dups.allocator = temp;
        for factor_in: factors {
            factor := factor_in;
            if table_contains(*dups, factor) continue;
            table_set(*dups, factor, true);
            bump(factor, *factor_occ, *max_occ, *max_occ_val);
            if ra_isa_constant_int(factor) {
                a := cf_ap(factor);
                if ap_is_negative(a) && !ap_is_min_signed(a) {
                    factor = const_int_words(type_int(a.bits), ap_words(ap_neg(a)));   // ConstantInt::get(Context, APInt)
                    if table_contains(*dups, factor) continue;
                    table_set(*dups, factor, true);
                    bump(factor, *factor_occ, *max_occ, *max_occ_val);
                }
            } else if vkind(factor) == .C_FP {
                f := apf_from_const(factor);
                if apf_is_negative(f) {
                    nf := f;
                    nw := fp_neg(nf.k, apf_words(*nf));
                    factor = const_fp_words(vtype(factor), nw);
                    if table_contains(*dups, factor) continue;
                    table_set(*dups, factor, true);
                    bump(factor, *factor_occ, *max_occ, *max_occ_val);
                }
            }
        }
    }

    if max_occ > 1 {
        dummy := create_binop(ifx ra_is_int_or_int_vec(vtype(i)) then Opcode.ADD else .FADD, max_occ_val, max_occ_val);
        new_mul_ops: [..] Vh; new_mul_ops.allocator = temp;
        j := 0;
        while j != ops.count {
            defer j += 1;
            bop := ra_is_reassociable_op(ops.*[j].op, .MUL, .FMUL);
            if bop == NONE continue;
            v := ra_remove_factor_from_expression(ops.*[j].op, max_occ_val, get_metadata(i, 0));
            if v != NONE {
                target := ops.*[j].op;
                m := ops.count;
                while m != j {
                    m -= 1;
                    if ops.*[m].op == target {
                        array_add(*new_mul_ops, vh_new(v));
                        array_ordered_remove_by_index(ops, m);
                    }
                }
                j -= 1;
            }
        }
        erase_unlinked_inst(dummy);

        v := ra_emit_add_tree_of_values(i, *new_mul_ops);
        if is_inst(v) rs_insert(*ra.redo, v);
        v2 := ra_create_mul(v, max_occ_val, "reass.mul", i, i);
        copy_debug_loc_or_clear(v2, i);
        rs_insert(*ra.redo, v2);
        if ops.count == 0 return v2;
        array_insert_at(ops, .{ra_get_rank(v2), v2}, 0);
    }
    return NONE;
}

// ---------------------------------------------------------------- mul

// collectMultiplyFactors
ra_collect_multiply_factors :: (ops: *[..] Ra_Ve, factors: *[..] Ra_Factor) -> bool {
    sum: u32 = 0;
    idx := 1;
    size := ops.count;
    while idx < size {
        defer idx += 1;
        o := ops.*[idx - 1].op;
        count: u32 = 1;
        while idx < size && ops.*[idx].op == o { count += 1; idx += 1; }
        if count > 1 sum += count;
    }
    if sum < 4 return false;

    sum = 0;
    idx = 1;
    while idx < ops.count {
        defer idx += 1;
        o := ops.*[idx - 1].op;
        count: u32 = 1;
        while idx < ops.count && ops.*[idx].op == o { count += 1; idx += 1; }
        if count == 1 continue;
        count &= ~cast(u32) 1;
        idx -= count;
        sum += count;
        array_add(factors, .{o, count});
        for 1..count array_ordered_remove_by_index(ops, idx);
    }
    assert(sum >= 4);
    // stable_sort by descending power
    for k: 1..factors.count - 1 {
        x := factors.*[k];
        m := k - 1;
        while m >= 0 && factors.*[m].power < x.power { factors.*[m + 1] = factors.*[m]; m -= 1; }
        factors.*[m + 1] = x;
    }
    return true;
}

ra_builder_mul :: (b: *Irb, fmf: u32, l: Value_Id, r: Value_Id) -> Value_Id {
    if ra_is_int_or_int_vec(vtype(l)) return irb_binop(b, .MUL, l, r);
    v := irb_binop(b, .FMUL, l, r);
    if is_inst(v) set_fmf(v, fmf);
    return v;
}

// buildMultiplyTree
ra_build_multiply_tree :: (b: *Irb, fmf: u32, ops: *[..] Value_Id) -> Value_Id {
    if ops.count == 1 return ops.*[ops.count - 1];
    lhs := pop(ops);
    while true {
        lhs = ra_builder_mul(b, fmf, lhs, pop(ops));
        if ops.count == 0 break;
    }
    return lhs;
}

// buildMinimalMultiplyDAG
ra_build_minimal_multiply_dag :: (b: *Irb, fmf: u32, factors: *[..] Ra_Factor) -> Value_Id {
    assert(factors.*[0].power != 0);
    outer: [..] Value_Id; outer.allocator = temp;
    last_idx := 0;
    idx := 1;
    size := factors.count;
    while idx < size && factors.*[idx].power > 0 {
        if factors.*[idx].power != factors.*[last_idx].power {
            last_idx = idx;
            idx += 1;
            continue;
        }
        inner: [..] Value_Id; inner.allocator = temp;
        array_add(*inner, factors.*[last_idx].base);
        while true {
            array_add(*inner, factors.*[idx].base);
            idx += 1;
            if !(idx < size && factors.*[idx].power == factors.*[last_idx].power) break;
        }
        m := ra_build_multiply_tree(b, fmf, *inner);
        factors.*[last_idx].base = m;
        if is_inst(m) rs_insert(*ra.redo, m);
        last_idx = idx;
        idx += 1;
    }
    // llvm::unique by equal power
    if factors.count > 0 {
        w := 1;
        for k: 1..factors.count - 1 {
            if factors.*[k].power == factors.*[w - 1].power continue;
            factors.*[w] = factors.*[k];
            w += 1;
        }
        factors.count = w;
    }
    for * f: factors.* {
        if f.power & 1 array_add(*outer, f.base);
        f.power >>= 1;
    }
    if factors.*[0].power {
        sq := ra_build_minimal_multiply_dag(b, fmf, factors);
        array_add(*outer, sq);
        array_add(*outer, sq);
    }
    if outer.count == 1 return outer[0];
    return ra_build_multiply_tree(b, fmf, *outer);
}

// OptimizeMul
ra_optimize_mul :: (i: Value_Id, ops: *[..] Ra_Ve) -> Value_Id {
    if ops.count < 4 return NONE;
    factors: [..] Ra_Factor; factors.allocator = temp;
    if !ra_collect_multiply_factors(ops, *factors) return NONE;
    b: Irb;
    irb_set_before(*b, i);
    fmf: u32 = 0;
    if is_fp_math_operator(i) fmf = get_fmf(i);
    v := ra_build_minimal_multiply_dag(*b, fmf, *factors);
    if ops.count == 0 return v;
    ne := Ra_Ve.{ra_get_rank(v), v};
    pos := 0;
    while pos < ops.count && ops.*[pos].rank > ne.rank pos += 1;   // lower_bound with operator< (rank descending)
    array_insert_at(ops, ne, pos);
    return NONE;
}

// OptimizeExpression
ra_optimize_expression :: (i: Value_Id, ops: *[..] Ra_Ve) -> Value_Id {
    cst: Value_Id = NONE;
    opcode := inst_op(i);
    while ops.count {
        c := ops.*[ops.count - 1].op;
        if is_constant_kind(vkind(c)) {
            if cst == NONE { ops.count -= 1; cst = c; continue; }
            res := cfo_binary_op_operands(opcode, c, cst);
            if res != NONE { ops.count -= 1; cst = res; continue; }
        }
        break;
    }
    if ops.count == 0 return cst;
    if cst != NONE && cst != cf_binop_identity(opcode, vtype(i), false) {
        if cst == cf_binop_absorber(opcode, vtype(i), false) return cst;
        array_add(ops, .{0, cst});
    }
    if ops.count == 1 return ops.*[0].op;

    num_ops := ops.count;
    if opcode == {
        case .AND; #through;
        case .OR;
            r := ra_optimize_and_or_xor(opcode, ops);
            if r != NONE return r;
        case .XOR;
            r := ra_optimize_xor(i, ops);
            if r != NONE return r;
        case .ADD; #through;
        case .FADD;
            r := ra_optimize_add(i, ops);
            if r != NONE return r;
        case .MUL; #through;
        case .FMUL;
            r := ra_optimize_mul(i, ops);
            if r != NONE return r;
    }
    if ops.count != num_ops return ra_optimize_expression(i, ops);
    return NONE;
}

// ---------------------------------------------------------------- erasing

// RecursivelyEraseDeadInsts
ra_recursively_erase_dead_insts :: (i: Value_Id, insts: *Ra_Set) {
    ops: [..] Value_Id; ops.allocator = temp;
    for k: 0..cast(s64) nops(i) - 1 array_add(*ops, op(i, cast(u32) k));
    table_remove(*ra.value_rank_map, i);
    rs_remove(insts, i);
    rs_remove(*ra.redo, i);
    salvage_debug_info(i);
    erase_inst_with_metadata(i);
    for o: ops if is_inst(o) && !has_uses(o) rs_insert(insts, o);
}

// EraseInst
ra_erase_inst :: (i: Value_Id) {
    ops: [..] Value_Id; ops.allocator = temp;
    for k: 0..cast(s64) nops(i) - 1 array_add(*ops, op(i, cast(u32) k));
    table_remove(*ra.value_rank_map, i);
    rs_remove(*ra.redo, i);
    salvage_debug_info(i);
    erase_inst_with_metadata(i);
    visited: Table(Value_Id, bool); visited.allocator = temp;
    for v: ops {
        if !is_inst(v) continue;
        o := v;
        opcode := inst_op(o);
        while value_has_one_use(o) && inst_op(first_user(o)) == opcode && !table_contains(*visited, o) {
            table_set(*visited, o, true);
            o = first_user(o);
        }
        if table_contains(*ra.value_rank_map, o) rs_insert(*ra.redo, o);
    }
    ra.made_change = true;
}

// ---------------------------------------------------------------- negative FP constants

// getNegatibleInsts
ra_get_negatible_insts :: (v: Value_Id, cands: *[..] Value_Id) {
    if !is_inst(v) || !value_has_one_use(v) return;
    i := v;
    o := inst_op(i);
    if o == .FMUL {
        if is_constant_kind(vkind(op(i, 0))) return;
        ok, c := pm_apfloat(op(i, 1));
        if ok && apf_is_negative(c) array_add(cands, i);
        ra_get_negatible_insts(op(i, 0), cands);
        ra_get_negatible_insts(op(i, 1), cands);
    } else if o == .FDIV {
        if is_constant_kind(vkind(op(i, 0))) && is_constant_kind(vkind(op(i, 1))) return;
        ok0, c0 := pm_apfloat(op(i, 0));
        ok1, c1 := pm_apfloat(op(i, 1));
        if (ok0 && apf_is_negative(c0)) || (ok1 && apf_is_negative(c1)) array_add(cands, i);
        ra_get_negatible_insts(op(i, 0), cands);
        ra_get_negatible_insts(op(i, 1), cands);
    }
}

// canonicalizeNegFPConstantsForOp
ra_canonicalize_neg_fp_constants_for_op :: (i: Value_Id, o: Value_Id, other: Value_Id) -> Value_Id {
    cands: [..] Value_Id; cands.allocator = temp;
    ra_get_negatible_insts(o, *cands);
    if cands.count == 0 return NONE;
    is_fsub := inst_op(i) == .FSUB;
    needs_subtract := !is_fsub && cands.count % 2 == 1;
    if needs_subtract && ra_should_break_up_subtract(i) return NONE;

    for n: cands {
        for k: 0..1 {
            ok, c := pm_apfloat(op(n, cast(u32) k));
            if ok {
                a := c;
                nw := fp_with_sign(a.k, apf_words(*a), false);
                set_op(n, cast(u32) k, const_fp_words(vtype(n), nw));
                ra.made_change = true;
            }
        }
    }
    if cands.count % 2 == 0 return i;

    b: Irb;
    irb_set_before(*b, i);
    new_inst := irb_binop(*b, ifx is_fsub then Opcode.FADD else .FSUB, other, o);
    if is_inst(new_inst) set_fmf(new_inst, get_fmf(i));
    rauw_with_metadata(i, new_inst);
    rs_insert(*ra.redo, i);
    return ifx is_inst(new_inst) then new_inst else NONE;
}

// canonicalizeNegFPConstants
ra_canonicalize_neg_fp_constants :: (i_in: Value_Id) -> Value_Id {
    i := i_in;
    if inst_op(i) == .FADD && is_inst(op(i, 1)) && value_has_one_use(op(i, 1)) {
        r := ra_canonicalize_neg_fp_constants_for_op(i, op(i, 1), op(i, 0));
        if r != NONE i = r;
    }
    if inst_op(i) == .FADD && is_inst(op(i, 0)) && value_has_one_use(op(i, 0)) {
        r := ra_canonicalize_neg_fp_constants_for_op(i, op(i, 0), op(i, 1));
        if r != NONE i = r;
    }
    if inst_op(i) == .FSUB && is_inst(op(i, 1)) && value_has_one_use(op(i, 1)) {
        r := ra_canonicalize_neg_fp_constants_for_op(i, op(i, 1), op(i, 0));
        if r != NONE i = r;
    }
    return i;
}

// ---------------------------------------------------------------- driver

// OptimizeInst
ra_optimize_inst :: (i_in: Value_Id) {
    i := i_in;
    if !is_inst(i) return;
    if !is_binary_operator(i) && inst_op(i) != .FNEG return;

    if inst_op(i) == .SHL && ra_isa_constant_int(op(i, 1)) {
        if ra_is_reassociable_op(op(i, 0), .MUL) != NONE ||
           (value_has_one_use(i) && (ra_is_reassociable_op(first_user(i), .MUL) != NONE ||
                               ra_is_reassociable_op(first_user(i), .ADD) != NONE)) {
            ni := ra_convert_shift_to_mul(i);
            rs_insert(*ra.redo, i);
            ra.made_change = true;
            i = ni;
        }
    }

    if is_commutative_op(inst_op(i)) ra_canonicalize_operands(i);

    res := ra_canonicalize_neg_fp_constants(i);
    if res != NONE i = res;

    if is_fp_math_operator(i) && !ra_has_fp_associative_flags(i) return;

    if is_int_or_int_vector_n(vtype(i), 1) return;

    if inst_op(i) == .OR && ra_should_convert_or_with_no_common_bits_to_add(i) && !ra_is_load_combine_candidate(i) {
        disjoint := (inst(i).flags & F_EXACT) != 0;
        if !disjoint {
            q: Simplify_Query; q.have_tli = false; q.cxt = i;
            disjoint = have_no_common_bits_set(op(i, 0), op(i, 1), q);
        }
        if disjoint {
            ni := ra_convert_or_with_no_common_bits_to_add(i);
            rs_insert(*ra.redo, i);
            ra.made_change = true;
            i = ni;
        }
    }

    if inst_op(i) == .MUL && ra_should_break_up_distribution(i) {
        mul_user := first_user(i);
        ni := ra_break_up_distribute(i, *ra.redo);
        rs_insert(*ra.redo, i);
        rs_insert(*ra.redo, mul_user);
        ra.made_change = true;
        i = ni;
    }

    o := inst_op(i);
    if o == .SUB {
        okn := pm_neg(i);
        if ra_should_break_up_subtract(i) {
            ni := ra_break_up_subtract(i, *ra.redo);
            rs_insert(*ra.redo, i);
            ra.made_change = true;
            i = ni;
        } else if okn {
            if ra_is_reassociable_op(op(i, 1), .MUL) != NONE &&
               (!value_has_one_use(i) || ra_is_reassociable_op(first_user(i), .MUL) == NONE) {
                ni := ra_lower_negate_to_multiply(i);
                ra_redo_binop_users(ni);
                rs_insert(*ra.redo, i);
                ra.made_change = true;
                i = ni;
            }
        }
    } else if o == .FNEG || o == .FSUB {
        okf := pm_fneg(i);
        if ra_should_break_up_subtract(i) {
            ni := ra_break_up_subtract(i, *ra.redo);
            rs_insert(*ra.redo, i);
            ra.made_change = true;
            i = ni;
        } else if okf {
            x := ifx is_binary_operator(i) then op(i, 1) else op(i, 0);
            if ra_is_reassociable_op(x, .FMUL) != NONE &&
               (!value_has_one_use(i) || ra_is_reassociable_op(first_user(i), .FMUL) == NONE) {
                ni := ra_lower_negate_to_multiply(i);
                ra_redo_binop_users(ni);
                rs_insert(*ra.redo, i);
                ra.made_change = true;
                i = ni;
            }
        }
    }

    if !inst_is_associative(i) return;
    bo := i;
    opcode := inst_op(bo);
    if value_has_one_use(bo) && inst_op(first_user(bo)) == opcode {
        u := first_user(bo);
        if u != bo && inst_block(bo) == inst_block(u) rs_insert(*ra.redo, u);
        return;
    }
    if value_has_one_use(bo) && opcode == .ADD && inst_op(first_user(bo)) == .SUB return;
    if value_has_one_use(bo) && opcode == .FADD && inst_op(first_user(bo)) == .FSUB return;
    ra_reassociate_expression(bo);
}

ra_redo_binop_users :: (ni: Value_Id) {
    u := ir.v_first_use[ni];
    while u != NONE {
        us := ir.u_user[u];
        if is_binary_operator(us) rs_insert(*ra.redo, us);
        u = ir.u_next[u];
    }
}

ra_stable_sort_ops :: (ops: [] Ra_Ve) {
    // merge sort, highest rank first, stable
    n := ops.count;
    if n < 2 return;
    buf := NewArray(n, Ra_Ve,, allocator = temp);
    width := 1;
    src := ops; dst := buf;
    while width < n {
        lo := 0;
        while lo < n {
            mid := min(lo + width, n);
            hi := min(lo + 2 * width, n);
            a := lo; b := mid; k := lo;
            while a < mid && b < hi {
                if src[b].rank > src[a].rank { dst[k] = src[b]; b += 1; }
                else { dst[k] = src[a]; a += 1; }
                k += 1;
            }
            while a < mid { dst[k] = src[a]; a += 1; k += 1; }
            while b < hi { dst[k] = src[b]; b += 1; k += 1; }
            lo = hi;
        }
        t := src; src = dst; dst = t;
        width *= 2;
    }
    if src.data != ops.data for k: 0..n - 1 ops[k] = src[k];
}

ra_pair_key :: (a: Value_Id, b: Value_Id) -> u64 {
    x := a; y := b;
    if y < x { t := x; x = y; y = t; }
    return ((cast(u64) x) << 32) | cast(u64) y;
}

// ReassociateExpression
ra_reassociate_expression :: (i: Value_Id) {
    tree: [..] Ra_Rv; tree.allocator = temp;
    flags: Overflow_Tracking;
    if ra_linearize_expr_tree(i, *tree, *ra.redo, *flags) ra.made_change = true;
    ops: [..] Ra_Ve; ops.allocator = temp;
    ra_ops_from_tree(tree, *ops);
    ra_stable_sort_ops(ops);

    v := ra_optimize_expression(i, *ops);
    if v != NONE {
        if v == i return;
        rauw_with_metadata(i, v);
        if is_inst(v) {
            d := get_metadata(i, 0);
            if d != NONE set_metadata(v, 0, d);
        }
        rs_insert(*ra.redo, i);
        return;
    }

    if value_has_one_use(i) {
        u := first_user(i);
        last := ops[ops.count - 1].op;
        if inst_op(i) == .MUL && inst_op(u) == .ADD && ra_isa_constant_int(last) && ap_is_all_ones(cf_ap(last)) {
            tmp := pop(*ops);
            array_insert_at(*ops, tmp, 0);
        } else if inst_op(i) == .FMUL && inst_op(u) == .FADD && vkind(last) == .C_FP &&
                  apf_is_exactly_value(apf_from_const(last), -1.0) {
            tmp := pop(*ops);
            array_insert_at(*ops, tmp, 0);
        }
    }

    if ops.count == 1 {
        if ops[0].op == i return;
        rauw_with_metadata(i, ops[0].op);
        if is_inst(ops[0].op) set_metadata(ops[0].op, 0, get_metadata(i, 0));
        rs_insert(*ra.redo, i);
        return;
    }

    if ops.count > 2 && ops.count <= RA_GLOBAL_REASSOCIATE_LIMIT {
        max_score: u32 = 1;
        best_rank: u32 = 0;
        best_first := 0; best_second := 0;
        idx := cast(s64) inst_op(i);
        limit_idx := 0;
        if ra_cl.use_cse_local {
            first_seen: Value_Id = NONE;
            start_idx := ops.count - 1;
            k := start_idx - 1;
            while k != -1 {
                defer k -= 1;
                val := ops[k].op;
                seen: Value_Id;
                if !is_inst(val) seen = fn_entry(inst_fn(i));
                else seen = inst_block(val);
                if first_seen == NONE { first_seen = seen; continue; }
                if first_seen != seen { limit_idx = k + 1; break; }
            }
        }
        k := ops.count - 1;
        while k > limit_idx {
            defer k -= 1;
            j := k - 1;
            while j >= limit_idx {
                defer j -= 1;
                score: u32 = 0;
                p := table_find_pointer(*ra.pair_map[idx], ra_pair_key(ops[k].op, ops[j].op));
                if p && vkind(p.v1) != .DEAD && vkind(p.v2) != .DEAD score += p.score;
                max_rank := max(ops[k].rank, ops[j].rank);
                if score > max_score || (score == max_score && max_rank < best_rank) {
                    best_first = j; best_second = k;
                    max_score = score;
                    best_rank = max_rank;
                }
            }
        }
        if max_score > 1 {
            op0 := ops[best_first];
            op1 := ops[best_second];
            array_ordered_remove_by_index(*ops, best_second);
            array_ordered_remove_by_index(*ops, best_first);
            array_add(*ops, op0);
            array_add(*ops, op1);
        }
    }
    ra_rewrite_expr_tree(i, ops, flags);
}

// BuildPairMap
ra_build_pair_map :: (rpot: [] Value_Id) {
    for bb: rpot {
        for i: block_insts(bb) {
            if !is_binary_operator(i) || !inst_is_associative(i) continue;
            if value_has_one_use(i) && is_inst(first_user(i)) && inst_op(first_user(i)) == inst_op(i) continue;
            wl: [..] Value_Id; wl.allocator = temp;
            array_add(*wl, op(i, 0));
            array_add(*wl, op(i, 1));
            ops: [..] Value_Id; ops.allocator = temp;
            while wl.count && ops.count <= RA_GLOBAL_REASSOCIATE_LIMIT {
                o := pop(*wl);
                if !is_inst(o) || inst_op(o) != inst_op(i) || !value_has_one_use(o) {
                    array_add(*ops, o);
                    continue;
                }
                if op(o, 0) != o array_add(*wl, op(o, 0));
                if op(o, 1) != o array_add(*wl, op(o, 1));
            }
            if ops.count > RA_GLOBAL_REASSOCIATE_LIMIT continue;
            idx := cast(s64) inst_op(i);
            visited: Table(u64, bool); visited.allocator = temp;
            for a: 0..ops.count - 2 {
                for b: a + 1..ops.count - 1 {
                    key := ra_pair_key(ops[a], ops[b]);
                    if table_contains(*visited, key) continue;
                    table_set(*visited, key, true);
                    p := table_find_pointer(*ra.pair_map[idx], key);
                    if p p.score += 1;
                    else {
                        x := ops[a]; y := ops[b];
                        if y < x { t := x; x = y; y = t; }
                        table_set(*ra.pair_map[idx], key, .{x, y, 1});
                    }
                }
            }
        }
    }
}

reassociate_run :: (f: Value_Id) -> Preserved {
    ra = .{};
    ra.rank_map.allocator = temp;
    ra.value_rank_map.allocator = temp;
    for * ra.pair_map it.allocator = temp;
    rs_init(*ra.redo);

    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(f), *po);
    rpot := NewArray(po.count, Value_Id,, allocator = temp);
    for k: 0..po.count - 1 rpot[k] = po[po.count - 1 - k];

    ra_build_rank_map(f, rpot);
    ra_build_pair_map(rpot);
    ra.made_change = false;

    for bb: rpot {
        ii := block_first(bb);
        while ii != NONE {
            if is_instruction_trivially_dead_tli(ii, false) {
                nx := inst_next(ii);
                ra_erase_inst(ii);
                ii = nx;
            } else {
                ra_optimize_inst(ii);
                ii = inst_next(ii);
            }
        }

        to_redo: Ra_Set;
        rs_copy(*to_redo, *ra.redo);
        while !rs_empty(*to_redo) {
            i := rs_pop_back(*to_redo);
            if is_instruction_trivially_dead_tli(i, false) {
                ra_recursively_erase_dead_insts(i, *to_redo);
                ra.made_change = true;
            }
        }

        while !rs_empty(*ra.redo) {
            i := rs_pop_front(*ra.redo);
            if is_instruction_trivially_dead_tli(i, false) ra_erase_inst(i);
            else ra_optimize_inst(i);
        }
    }
    vh_release_all();

    if ra.made_change return preserved_cfg();
    return PRESERVE_ALL;
}
