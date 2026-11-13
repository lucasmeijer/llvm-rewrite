// ConstraintSystem: port of llvm/lib/Analysis/ConstraintSystem.cpp and llvm/include/llvm/Analysis/ConstraintSystem.h
// (Fourier–Motzkin elimination over int64 coefficients with checked arithmetic), plus the MathExtras.h
// AddOverflow / SubOverflow / MulOverflow it uses (wrapped result, overflow flag).
//
// A row is a sparse list of (coefficient, id) entries sorted by id; id 0 is the constant. Ids are uint16_t in
// LLVM and truncated the same way here. Value2Index lives in the ConstraintInfo (pass_constraint_elimination.jai)
// next to each system, like ConstraintSystem::Value2Index.

Cs_Entry :: struct { coef: s64; id: u16; }

Constraint_System :: struct {
    num_variables: s64;
    constraints: [..] [..] Cs_Entry;
    value2index: Table(Value_Id, u32);
}

// llvm::AddOverflow / SubOverflow / MulOverflow (signed int64): (wrapped result, overflowed)
add_ov_s64 :: (a: s64, b: s64) -> (s64, bool) {
    r := cast,no_check(s64) (cast,no_check(u64) a + cast,no_check(u64) b);
    return r, ((a ^ r) & (b ^ r)) < 0;
}
sub_ov_s64 :: (a: s64, b: s64) -> (s64, bool) {
    r := cast,no_check(s64) (cast,no_check(u64) a - cast,no_check(u64) b);
    return r, ((a ^ b) & (a ^ r)) < 0;
}
mul_ov_s64 :: (a: s64, b: s64) -> (s64, bool) {
    r := cast,no_check(s64) (cast,no_check(u64) a * cast,no_check(u64) b);
    if a == 0 || b == 0 return 0, false;
    S64_MIN :: -0x7FFF_FFFF_FFFF_FFFF - 1;
    if (a == -1 && b == S64_MIN) || (b == -1 && a == S64_MIN) return r, true;
    return r, r / b != a;
}
wrap_mul_s64 :: (a: s64, b: s64) -> s64 { r := mul_ov_s64(a, b); return r; }
wrap_add_s64 :: (a: s64, b: s64) -> s64 { r := add_ov_s64(a, b); return r; }

cs_init :: (cs: *Constraint_System, args: [] Value_Id) {
    cs.constraints.allocator = temp;
    cs.value2index.allocator = temp;
    cs.num_variables += args.count;
    for args table_set(*cs.value2index, it, cast(u32) cs.value2index.count + 1);
}

cs_size :: (cs: *Constraint_System) -> s64 { return cs.constraints.count; }

cs_all_zero_but_first :: (r: [] s64) -> bool {
    for k: 1..r.count - 1 if r[k] != 0 return false;
    return true;
}

// addVariableRow
cs_add_variable_row :: (cs: *Constraint_System, r: [] s64) -> bool {
    if cs_all_zero_but_first(r) return false;
    row: [..] Cs_Entry; row.allocator = temp;
    for c, idx: r {
        if c == 0 continue;
        array_add(*row, .{c, cast,no_check(u16) idx});
    }
    if cs.constraints.count == 0 cs.num_variables = r.count;
    array_add(*cs.constraints, row);
    return true;
}

// addVariableRowFill
cs_add_variable_row_fill :: (cs: *Constraint_System, r: [] s64) -> bool {
    if cs_all_zero_but_first(r) return false;
    cs.num_variables = max(r.count, cs.num_variables);
    return cs_add_variable_row(cs, r);
}

cs_pop_last_constraint :: (cs: *Constraint_System) { cs.constraints.count -= 1; }
cs_pop_last_n_variables :: (cs: *Constraint_System, n: s64) {
    assert(cs.num_variables > n);
    cs.num_variables -= n;
}

// negate / negateOrEqual / toStrictLessThan (empty result = overflow)
cs_negate_or_equal :: (r_in: [] s64) -> [..] s64 {
    r: [..] s64; r.allocator = temp;
    array_resize(*r, r_in.count, false);
    for r_in {
        v, ov := mul_ov_s64(it, -1);
        if ov { r.count = 0; return r; }
        r[it_index] = v;
    }
    return r;
}
cs_negate :: (r_in: [] s64) -> [..] s64 {
    first, ov := add_ov_s64(r_in[0], 1);
    if ov { e: [..] s64; e.allocator = temp; return e; }
    tmp := NewArray(r_in.count, s64,, allocator = temp);
    for r_in tmp[it_index] = it;
    tmp[0] = first;
    return cs_negate_or_equal(tmp);
}
cs_to_strict_less_than :: (r_in: [] s64) -> [..] s64 {
    r: [..] s64; r.allocator = temp;
    v, ov := sub_ov_s64(r_in[0], 1);
    if ov return r;
    array_resize(*r, r_in.count, false);
    for r_in r[it_index] = it;
    r[0] = v;
    return r;
}

// getLastCoefficient
cs_last_coefficient :: (row: [] Cs_Entry, id: u16) -> s64 {
    if row.count == 0 return 0;
    if row[row.count - 1].id == id return row[row.count - 1].coef;
    return 0;
}

// The solver works on a copy of the rows (isConditionImplied copies the system).
Cs_Solver :: struct {
    num_variables: s64;
    constraints: [..] [..] Cs_Entry;
}

// eliminateUsingFM
cs_eliminate_using_fm :: (s: *Cs_Solver) -> bool {
    assert(s.constraints.count > 0);
    last_idx := cast,no_check(u16) (s.num_variables - 1);
    remaining: [..] [..] Cs_Entry; remaining.allocator = temp;
    r1 := 0;
    while r1 < s.constraints.count {
        row1 := *s.constraints[r1];
        if cs_last_coefficient(row1.*, last_idx) == 0 {
            if row1.count > 0 && row1.*[row1.count - 1].id == last_idx row1.count -= 1;
            r1 += 1;
        } else {
            t := s.constraints[r1];
            s.constraints[r1] = s.constraints[s.constraints.count - 1];
            s.constraints[s.constraints.count - 1] = t;
            array_add(*remaining, s.constraints[s.constraints.count - 1]);
            s.constraints.count -= 1;
        }
    }

    n := remaining.count;
    for a: 0..n - 1 {
        for b: a + 1..n - 1 {
            upper_last := cs_last_coefficient(remaining[b], last_idx);
            lower_last := cs_last_coefficient(remaining[a], last_idx);
            assert(upper_last != 0 && lower_last != 0);
            if (lower_last < 0 && upper_last < 0) || (lower_last > 0 && upper_last > 0) continue;
            lower_r := a; upper_r := b;
            if upper_last < 0 {
                t := lower_r; lower_r = upper_r; upper_r = t;
                u := lower_last; lower_last = upper_last; upper_last = u;
            }
            nr: [..] Cs_Entry; nr.allocator = temp;
            iu := 0; il := 0;
            lower_row := remaining[lower_r];
            upper_row := remaining[upper_r];
            overflow := false;
            while true {
                if iu >= upper_row.count || il >= lower_row.count break;
                upper_v: s64 = 0;
                lower_v: s64 = 0;
                current: u16 = 0xFFFF;
                if iu < upper_row.count current = min(upper_row[iu].id, current);
                if il < lower_row.count current = min(lower_row[il].id, current);
                if iu < upper_row.count && upper_row[iu].id == current { upper_v = upper_row[iu].coef; iu += 1; }
                m1, ov1 := mul_ov_s64(upper_v, wrap_mul_s64(-1, lower_last));
                if ov1 { overflow = true; break; }
                if il < lower_row.count && lower_row[il].id == current { lower_v = lower_row[il].coef; il += 1; }
                m2, ov2 := mul_ov_s64(lower_v, upper_last);
                if ov2 { overflow = true; break; }
                nn, ov3 := add_ov_s64(m1, m2);
                if ov3 { overflow = true; break; }
                if nn == 0 continue;
                array_add(*nr, .{nn, current});
            }
            if overflow || nr.count == 0 continue;
            array_add(*s.constraints, nr);
            if s.constraints.count > 500 return false;
        }
    }
    s.num_variables -= 1;
    return true;
}

// mayHaveSolutionImpl
cs_may_have_solution :: (s: *Cs_Solver) -> bool {
    while s.constraints.count > 0 && s.num_variables > 1 {
        if !cs_eliminate_using_fm(s) return true;
    }
    if s.constraints.count == 0 || s.num_variables > 1 return true;
    for s.constraints {
        if it.count == 0 continue;
        if it[0].id == 0 && it[0].coef < 0 return false;
    }
    return true;
}

// isConditionImplied
cs_is_condition_implied :: (cs: *Constraint_System, r_in: [] s64) -> bool {
    if cs_all_zero_but_first(r_in) return r_in[0] >= 0;
    // Everything the solver allocates is dropped again: only the answer escapes.
    mark := get_temporary_storage_mark();
    defer set_temporary_storage_mark(mark);
    pmark := ptemp_get_mark();
    defer ptemp_set_mark(pmark);
    r := cs_negate(r_in);
    if r.count == 0 return false;
    s: Cs_Solver;
    s.num_variables = cs.num_variables;
    s.constraints.allocator = temp;
    array_reserve(*s.constraints, cs.constraints.count + 1);
    for cs.constraints {
        row: [..] Cs_Entry; row.allocator = temp;
        array_resize(*row, it.count, false);
        for e, k: it row[k] = e;
        array_add(*s.constraints, row);
    }
    // NewSystem.addVariableRow(R)
    if !cs_all_zero_but_first(r) {
        row: [..] Cs_Entry; row.allocator = temp;
        for c, idx: r { if c != 0 array_add(*row, .{c, cast,no_check(u16) idx}); }
        if s.constraints.count == 0 s.num_variables = r.count;
        array_add(*s.constraints, row);
    }
    return !cs_may_have_solution(*s);
}
