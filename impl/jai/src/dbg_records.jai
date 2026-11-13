// Debug-record utilities for passes that move, convert or delete debug records.
// Ported from llvm/lib/IR/DebugProgramInstruction.cpp (DbgRecord::eraseFromParent, insertion), llvm/lib/IR/Metadata.cpp
// (ReplaceableMetadataImpl::getAllDbgVariableRecordUsers: users in reverse order of tracking, ValueAsMetadata
// handleRAUW / handleDeletion), llvm/lib/IR/DebugInfo.cpp (findDbgUsers, findDbgValues, getDebugValueLoc),
// llvm/lib/IR/DebugInfoMetadata.cpp (DIExpression::startsWithDeref / isDeref / getActiveBits /
// getSingleLocationExpressionElements, DIVariable::getSizeInBits, DILocation::getMergedLocation) and
// llvm/lib/Transforms/Utils/Local.cpp (ConvertDebugDeclareToDebugValue, InsertDebugValueAtStoreLoc,
// valueCoversEntireFragment, PhiHasDebugValue).
//
// A record knows its owner instruction (Dbg_Record.owner, kept by attach_records_before and erase_inst).
// The "tracking stamp" orders a value's debug users like LLVM's UseMap index: records parsed from the input have
// their record index as stamp, records created or re-tracked later get increasing stamps above every index.
// Value -> records is an index built lazily per pass invocation (dbgr_index_reset at the start of a pass).

dbgr :: inline (r: u32) -> *Dbg_Record { return *ir.dbg_records[r - 1]; }

dbg_stamps: Table(u32, u64);
dbg_stamp_next: u64 = 1 << 40;
dbgr_stamp :: (r: u32) -> u64 {
    found, s := table_find(*dbg_stamps, r);
    if found return s;
    return cast(u64) r;
}
dbgr_restamp :: (r: u32) { table_set(*dbg_stamps, r, dbg_stamp_next); dbg_stamp_next += 1; }

// value -> records that reference it from their location (or address, for dbg_assign)
Dbg_Index :: struct {
    fn: Value_Id = NONE;
    users: Table(Value_Id, [..] u32);
}
dbg_index: Dbg_Index;

dbgr_index_reset :: () {
    dbg_index.fn = NONE;
    deinit(*dbg_index.users);
    dbg_index.users = .{};
}

dbgr_values_of_loc :: (m: Md_Id, out: *[..] Value_Id) {
    if m == NONE return;
    if ir.mds[m].kind == .VALUE { array_add(out, ir.mds[m].value); return; }
    if is_di(m, .ARG_LIST) {
        n := ir.mds[m].nops;
        if n > 0 for k: 0..n-1 {
            o := md_op(m, k);
            if o != NONE && ir.mds[o].kind == .VALUE array_add(out, ir.mds[o].value);
        }
    }
}

dbgr_index_add :: (v: Value_Id, r: u32) {
    l := table_find_pointer(*dbg_index.users, v);
    if !l { e: [..] u32; l = table_add(*dbg_index.users, v, e); }
    for l.* if it == r return;
    array_add(l, r);
}
dbgr_index_record :: (r: u32) {
    vals: [..] Value_Id; vals.allocator = temp;
    rec := dbgr(r);
    dbgr_values_of_loc(rec.loc, *vals);
    if rec.kind == .ASSIGN dbgr_values_of_loc(rec.addr, *vals);
    for vals dbgr_index_add(it, r);
}
dbgr_index_ensure :: (f: Value_Id) {
    if dbg_index.fn == f return;
    dbgr_index_reset();
    dbg_index.fn = f;
    for b: fn_blocks(f) for i: block_insts(b) {
        x := inst(i).records;
        while x != 0 { dbgr_index_record(x); x = dbgr(x).next; }
    }
}

// Does the record's location refer to v?
dbgr_refers_to :: (r: u32, v: Value_Id, md_only_loc: bool) -> bool {
    vals: [..] Value_Id; vals.allocator = temp;
    rec := dbgr(r);
    dbgr_values_of_loc(rec.loc, *vals);
    if !md_only_loc && rec.kind == .ASSIGN dbgr_values_of_loc(rec.addr, *vals);
    for vals if it == v return true;
    return false;
}

// findDbgUsers(V, DVRs): live records whose location (or dbg_assign address) refers to v. LocalAsMetadata users
// first (reverse tracking order), then the users of each DIArgList containing v.
find_dbg_users :: (f: Value_Id, v: Value_Id, out: *[..] u32, values_and_assigns_only := false) {
    out.count = 0;
    dbgr_index_ensure(f);
    l := table_find_pointer(*dbg_index.users, v);
    if !l return;
    direct: [..] u32; direct.allocator = temp;
    via_list: [..] u32; via_list.allocator = temp;
    for r: l.* {
        rec := dbgr(r);
        if rec.owner == NONE continue;
        if values_and_assigns_only && rec.kind != .VALUE && rec.kind != .ASSIGN continue;
        is_direct := (rec.loc != NONE && ir.mds[rec.loc].kind == .VALUE && ir.mds[rec.loc].value == v) ||
                     (rec.kind == .ASSIGN && rec.addr != NONE && ir.mds[rec.addr].kind == .VALUE && ir.mds[rec.addr].value == v);
        if is_direct array_add(*direct, r);
        else if dbgr_refers_to(r, v, false) array_add(*via_list, r);
    }
    sort_desc :: (a: *[..] u32) {
        for i: 1..a.count-1 {
            x := a.*[i]; sx := dbgr_stamp(x);
            j := i - 1;
            while j >= 0 && dbgr_stamp(a.*[j]) < sx { a.*[j + 1] = a.*[j]; j -= 1; }
            a.*[j + 1] = x;
        }
    }
    sort_desc(*direct);
    // arg-list users: the lists in reverse order of tracking, each list's records in reverse order of tracking
    for i: 1..via_list.count-1 {
        x := via_list[i]; ax := arglist_stamp(dbgr(x).loc); sx := dbgr_stamp(x);
        j := i - 1;
        while j >= 0 {
            aj := arglist_stamp(dbgr(via_list[j]).loc);
            if !(aj < ax || (aj == ax && dbgr_stamp(via_list[j]) < sx)) break;
            via_list[j + 1] = via_list[j]; j -= 1;
        }
        via_list[j + 1] = x;
    }
    for direct array_add(out, it);
    for via_list array_add(out, it);
}

// Value::replaceAllUsesWith including ValueAsMetadata::handleRAUW for debug records.
rauw_with_metadata :: (old: Value_Id, new: Value_Id) {
    replace_all_uses_with(old, new);
    md_value_replace(old, new);
}

// ValueAsMetadata::handleRAUW (the metadata half). A local turning into a constant, or a value that already has
// a ValueAsMetadata, re-tracks the users (new stamps, in their old order).
md_value_replace :: (old: Value_Id, new: Value_Id) {
    k := *md_key; key_reset(k); key_u8(k, 1); key_u32(k, old);
    if !table_contains(*ir.md_map, key_view(k)) return;
    key_reset(k); key_u8(k, 1); key_u32(k, new);
    retrack := is_constant_kind(vkind(new)) || table_contains(*ir.md_map, key_view(k));
    // the index may hold stale entries (records whose location was changed since): keep the real users only
    moved: [..] u32; moved.allocator = temp;
    have_index := dbg_index.fn != NONE;
    if have_index {
        l := table_find_pointer(*dbg_index.users, old);
        if l {
            for l.* if dbgr(it).owner != NONE && dbgr_refers_to(it, old, false) array_add(*moved, it);
            table_remove(*dbg_index.users, old);
        }
    }
    md_value_rauw(old, new);
    if !have_index return;
    if retrack {
        for i: 1..moved.count-1 {
            x := moved[i]; sx := dbgr_stamp(x);
            j := i - 1;
            while j >= 0 && dbgr_stamp(moved[j]) > sx { moved[j + 1] = moved[j]; j -= 1; }
            moved[j + 1] = x;
        }
        for moved {
            dbgr_restamp(it);
            if is_di(dbgr(it).loc, .ARG_LIST) arglist_restamp(dbgr(it).loc);   // DIArgList::handleChangedOperand re-tracks
        }
    }
    for moved dbgr_index_add(new, it);
}

// ValueAsMetadata::handleDeletion + DebugValueUser::handleChangedValue: records that refer to an erased value
// refer to poison instead.
md_value_deleted :: (v: Value_Id) {
    md_value_replace(v, const_poison(vtype(v)));
}

// Instruction::eraseFromParent for a value that may be referenced from debug records.
erase_inst_with_metadata :: (i: Value_Id) {
    md_value_deleted(i);
    erase_inst(i);
}

// DbgRecord::eraseFromParent
dbgr_erase :: (r: u32) {
    rec := dbgr(r);
    o := rec.owner;
    assert(o != NONE, "erasing a debug record that is not attached");
    x := inst(o).records;
    if x == r inst(o).records = rec.next;
    else {
        while dbgr(x).next != r x = dbgr(x).next;
        dbgr(x).next = rec.next;
    }
    rec.next = 0;
    rec.owner = NONE;
}

// new DbgVariableRecord(ValueAsMetadata::get(V), Var, Expr, DL) inserted with BasicBlock::insertDbgRecordBefore(.., I)
dbgr_insert_value_before :: (v: Value_Id, var: Md_Id, expr: Md_Id, dbg: Md_Id, before: Value_Id) -> u32 {
    r: Dbg_Record;
    r.kind = .VALUE;
    r.loc = md_value(v);
    r.var = var; r.expr = expr; r.dbg = dbg;
    array_add(*ir.dbg_records, r);
    id := cast(u32) ir.dbg_records.count;
    dbgr_restamp(id);
    attach_records_before(before, id);
    if dbg_index.fn != NONE dbgr_index_record(id);
    return id;
}

// ---------------------------------------------------------------- DIExpression / DIVariable queries

diexpr_elts :: (m: Md_Id) -> [] u64 {
    e: [] u64;
    e.data = ir.md_ints.data + ir.mds[m].ints;
    e.count = ir.mds[m].nints;
    return e;
}

// DIExpression::isSingleLocationExpression + getSingleLocationExpressionElements
diexpr_single_location_elts :: (m: Md_Id) -> (ok: bool, elts: [] u64) {
    e := diexpr_elts(m);
    if !di_expression_valid(e) return false, .[];
    if e.count == 0 return true, e;
    i := 0;
    if e[0] == DW_OP_LLVM_ARG {
        if e[1] != 0 return false, .[];
        i = 2;
    }
    while i < e.count {
        if e[i] == DW_OP_LLVM_ARG return false, .[];
        i += expr_op_size(e[i]);
    }
    if e[0] == DW_OP_LLVM_ARG { r: [] u64; r.data = e.data + 2; r.count = e.count - 2; return true, r; }
    return true, e;
}
diexpr_starts_with_deref :: (m: Md_Id) -> bool {
    ok, e := diexpr_single_location_elts(m);
    return ok && e.count > 0 && e[0] == DW_OP_DEREF_;
}
diexpr_is_deref :: (m: Md_Id) -> bool {
    ok, e := diexpr_single_location_elts(m);
    return ok && e.count == 1 && e[0] == DW_OP_DEREF_;
}
DW_OP_DEREF_ :: 0x06;
DW_OP_LLVM_FRAGMENT_ :: 0x1000;
DW_OP_LLVM_EXTRACT_BITS_SEXT :: 0x1006;
DW_OP_LLVM_EXTRACT_BITS_ZEXT :: 0x1007;

// dropInitialDeref (Local.cpp)
diexpr_drop_initial_deref :: (m: Md_Id) -> Md_Id {
    e := diexpr_elts(m);
    n := ifx e[0] == DW_OP_LLVM_ARG then 3 else 1;
    rest: [] u64; rest.data = e.data + n; rest.count = e.count - n;
    copy := NewArray(rest.count, u64,, allocator = temp);
    for rest copy[it_index] = it;
    return di_get(.EXPRESSION, false, .[], copy);
}

// DIType::getSizeInBits (0 if the size is not a constant)
ditype_size_bits :: (t: Md_Id) -> u64 {
    s := di_op(t, 3);
    if s == NONE || ir.mds[s].kind != .VALUE return 0;
    v := ir.mds[s].value;
    if vkind(v) != .C_INT return 0;
    return const_int_zext(v);
}

// DIVariable::getSizeInBits
divar_size_bits :: (var: Md_Id) -> (bool, u64) {
    t := di_op(var, 3);
    while t != NONE && ir.mds[t].kind == .SPECIAL {
        k := di_kind(t);
        is_type := k == .BASIC_TYPE || k == .DERIVED_TYPE || k == .COMPOSITE_TYPE || k == .SUBROUTINE_TYPE;
        if is_type && k != .SUBROUTINE_TYPE {
            sz := ditype_size_bits(t);
            if sz return true, sz;
        }
        if k == .DERIVED_TYPE { t = di_op(t, 5); continue; }
        break;
    }
    return false, 0;
}

// DIVariable::getSignedness: DIBasicType encodings
divar_signedness :: (var: Md_Id) -> (known: bool, signed: bool) {
    t := di_op(var, 3);
    if !is_di(t, .BASIC_TYPE) return false, false;
    enc := di_int(t, 3);
    if enc == 0x05 || enc == 0x06 || enc == 0x0d return true, true;           // signed, signed_char, signed_fixed
    if enc == 0x07 || enc == 0x08 || enc == 0x0e return true, false;          // unsigned, unsigned_char, unsigned_fixed
    return false, false;
}

// DIExpression::getActiveBits(Var)
diexpr_active_bits :: (expr: Md_Id, var: Md_Id) -> (bool, u64) {
    init_ok, init := divar_size_bits(var);
    ok, active := init_ok, init;
    e := diexpr_elts(expr);
    i := 0;
    while i < e.count {
        o := e[i];
        if o == DW_OP_LLVM_EXTRACT_BITS_ZEXT || o == DW_OP_LLVM_EXTRACT_BITS_SEXT {
            known, signed := divar_signedness(var);
            op_signed := o == DW_OP_LLVM_EXTRACT_BITS_SEXT;
            if !known || signed != op_signed { ok, active = init_ok, init; }
            else {
                if ok active = min(active, e[i + 2]); else active = e[i + 2];
                ok = true;
            }
        } else if o == DW_OP_LLVM_FRAGMENT_ {
            if ok active = min(active, e[i + 2]); else active = e[i + 2];
            ok = true;
        } else {
            ok, active = init_ok, init;
        }
        i += expr_op_size(o);
    }
    return ok, active;
}

// ---------------------------------------------------------------- DILocation

di_location_get :: (line: u64, col: u64, scope: Md_Id, inlined_at: Md_Id, implicit: u64 = 0, group: u64 = 0, rank: u64 = 0) -> Md_Id {
    return di_get(.LOCATION, false, .[scope, inlined_at], .[line, col, implicit, group, rank]);
}
diloc_line :: (l: Md_Id) -> u64 { return di_int(l, 0); }
diloc_col :: (l: Md_Id) -> u64 { return di_int(l, 1); }
diloc_scope :: (l: Md_Id) -> Md_Id { return di_op(l, 0); }
diloc_inlined_at :: (l: Md_Id) -> Md_Id { return di_op(l, 1); }

// getDebugValueLoc
debug_value_loc :: (r: u32) -> Md_Id {
    d := dbgr(r).dbg;
    if d == NONE return NONE;
    return di_location_get(0, 0, diloc_scope(d), diloc_inlined_at(d));
}

// DIScope::getScope / getFile for local scopes
discope_parent :: (s: Md_Id) -> Md_Id {
    k := di_kind(s);
    if k == .FILE || k == .COMPILE_UNIT return NONE;
    return di_op(s, 1);
}
discope_file :: (s: Md_Id) -> Md_Id {
    if is_di(s, .FILE) return s;
    return di_op(s, 0);
}
// getLocalScopeLocationOr
local_scope_location_or :: (s: Md_Id, l: u64, c: u64) -> (u64, u64) {
    k := di_kind(s);
    if k == .LEXICAL_BLOCK_FILE return l, c;
    if k == .LEXICAL_BLOCK return di_int(s, 0), di_int(s, 1);
    if k == .SUBPROGRAM return di_int(s, 0), 0;
    fatal("internal: unhandled type of DILocalScope");
    return 0, 0;
}

// getNearestMatchingScope<EqualScopesMatcher> / <ScopeLocationsMatcher>
nearest_matching_scope :: (l1: Md_Id, l2: Md_Id, by_location: bool) -> (Md_Id, u64, u64) {
    Entry :: struct { file: Md_Id; line: u64; col: u64; scopes: [..] Md_Id; }
    entries: [..] Entry; entries.allocator = temp;
    s1 := diloc_scope(l1);
    ln, cl := diloc_line(l1), diloc_col(l1);
    while s1 != NONE {
        ln, cl = local_scope_location_or(s1, ln, cl);
        f := discope_file(s1);
        key_file := ifx by_location then f else NONE;
        kl := ifx by_location then ln else 0;
        kc := ifx by_location then cl else 0;
        found := false;
        for * entries if it.file == key_file && it.line == kl && it.col == kc {
            already := false;
            for x: it.scopes if x == s1 already = true;
            if !already array_add(*it.scopes, s1);
            found = true; break;
        }
        if !found {
            e: Entry; e.file = key_file; e.line = kl; e.col = kc; e.scopes.allocator = temp;
            array_add(*e.scopes, s1);
            array_add(*entries, e);
        }
        if is_di(s1, .SUBPROGRAM) break;
        s1 = discope_parent(s1);
    }
    s2 := diloc_scope(l2);
    ln, cl = diloc_line(l2), diloc_col(l2);
    while s2 != NONE {
        ln, cl = local_scope_location_or(s2, ln, cl);
        if by_location {
            f := discope_file(s2);
            for entries if it.file == f && it.line == ln && it.col == cl {
                for x: it.scopes if x == s2 return s2, ln, cl;
                return it.scopes[0], ln, cl;
            }
        } else {
            for entries for x: it.scopes if x == s2 return s2, ln, cl;
        }
        if is_di(s2, .SUBPROGRAM) break;
        s2 = discope_parent(s2);
    }
    return NONE, diloc_line(l2), diloc_col(l2);
}

diloc_subprogram :: (l: Md_Id) -> Md_Id { return di_local_scope_subprogram(diloc_scope(l)); }

// DILocation::getMergedLocation (PickMergedSourceLocations is off by default)
merged_location :: (a: Md_Id, b: Md_Id) -> Md_Id {
    if a == b return a;
    if a == NONE || b == NONE return NONE;
    alocs: [..] Md_Id; alocs.allocator = temp;
    blocs: [..] Md_Id; blocs.allocator = temp;
    l := a;
    while l != NONE { array_add(*alocs, l); l = diloc_inlined_at(l); }
    // ARIt/BRIt as forward indices of the matching starting location (-1 = none)
    ai := -1; bi := -1;
    l = b;
    idx := 0;
    while l != NONE {
        array_add(*blocs, l);
        if ai < 0 {
            sp := diloc_subprogram(l); ia := diloc_inlined_at(l);
            for x, xi: alocs if diloc_subprogram(x) == sp && diloc_inlined_at(x) == ia { ai = xi; bi = idx; break; }
            if ai >= 0 break;
        }
        l = diloc_inlined_at(l);
        idx += 1;
    }
    a_ia := diloc_inlined_at(a);
    b_ia := diloc_inlined_at(b);
    merge_pair :: (l1: Md_Id, l2: Md_Id, ia: Md_Id, a_ia: Md_Id, b_ia: Md_Id) -> Md_Id {
        if l1 == l2 return di_location_get(diloc_line(l1), diloc_col(l1), diloc_scope(l1), ia, di_int(l1, 2), di_int(l1, 3), di_int(l1, 4));
        if diloc_subprogram(l1) != diloc_subprogram(l2) return NONE;
        scope := nearest_matching_scope(l1, l2, false);
        assert(scope != NONE, "No common scope in the same subprogram?");
        f1 := discope_file(diloc_scope(l1));
        f2 := discope_file(diloc_scope(l2));
        if discope_file(scope) != f1 || f1 != f2 {
            cscope, cl, cc := nearest_matching_scope(l1, l2, true);
            k := di_kind(cscope);
            if (k == .LEXICAL_BLOCK || k == .LEXICAL_BLOCK_FILE) && cscope != scope
                fatal("merging debug locations that need a cloned lexical block (cloneAndReplaceParentScope) is not supported yet");
            scope = cscope;
            if discope_file(scope) != f1 || f1 != f2 return di_location_get(cl, cc, cscope, ia);
        }
        same_line := diloc_line(l1) == diloc_line(l2);
        same_col := diloc_col(l1) == diloc_col(l2);
        line := ifx same_line then diloc_line(l1) else 0;
        col := ifx same_line && same_col then diloc_col(l1) else 0;
        implicit: u64 = ifx di_int(l1, 2) != 0 && di_int(l2, 2) != 0 then cast(u64) 1 else 0;
        g1, g2, r1, r2 := di_int(l1, 3), di_int(l2, 3), di_int(l1, 4), di_int(l2, 4);
        if !same_line || !(g1 || g2) return di_location_get(line, col, scope, ia, implicit, 0, 0);
        if b_ia == a_ia && ia == b_ia {
            use_l1: bool;
            if r1 == r2 {
                if !g1 || !g2 use_l1 = !g2; else use_l1 = g1 < g2;
            } else {
                if !r1 || !r2 use_l1 = !r2; else use_l1 = r1 < r2;
            }
            return di_location_get(line, col, scope, ia, implicit, ifx use_l1 then g1 else g2, ifx use_l1 then r1 else r2);
        }
        fatal("merging debug locations with key-instruction atoms across inlined-at chains is not supported yet");
        return NONE;
    }
    result: Md_Id = ifx ai >= 0 then diloc_inlined_at(alocs[ai]) else NONE;
    if ai >= 0 {
        while ai >= 0 && bi >= 0 {
            t := merge_pair(alocs[ai], blocs[bi], result, a_ia, b_ia);
            if t == NONE break;
            result = t;
            ai -= 1; bi -= 1;
        }
    }
    if result != NONE return result;
    return di_location_get(0, 0, diloc_scope(a), NONE);
}

// DebugLoc::getMergedLocation
merged_debug_loc :: (a: Md_Id, b: Md_Id) -> Md_Id {
    if a == NONE || b == NONE return NONE;
    return merged_location(a, b);
}

// ---------------------------------------------------------------- Local.cpp dbg.declare conversion

// valueCoversEntireFragment
value_covers_entire_fragment :: (ty: Type_Id, r: u32) -> bool {
    if type_kind(ty) == .SVECTOR fatal("debug-info conversion for scalable vector values is not supported yet");
    value_size := dl_type_alloc_size(ty) * 8;
    rec := dbgr(r);
    ok, frag := diexpr_active_bits(rec.expr, rec.var);
    if ok return value_size >= frag;
    if rec.kind == .DECLARE {
        loc := rec.loc;
        if loc != NONE && ir.mds[loc].kind == .VALUE {
            ai := ir.mds[loc].value;
            if is_inst(ai) && inst_op(ai) == .ALLOCA {
                aty := inst(ai).ty2;
                if type_kind(aty) == .SVECTOR fatal("debug-info conversion for scalable allocas is not supported yet");
                sz := dl_type_alloc_size(aty);
                n := op(ai, 0);
                is_one := vkind(n) == .C_INT && const_int_zext(n) == 1 && type_int_width(vtype(n)) <= 64;
                if !is_one {
                    if vkind(n) != .C_INT return false;
                    sz *= const_int_zext(n);
                }
                return value_size >= sz * 8;
            }
        }
    }
    return false;
}

// ConvertDebugDeclareToDebugValue(DVR, StoreInst *SI, DIB)
convert_debug_declare_to_debug_value_store :: (r: u32, si: Value_Id) {
    rec := dbgr(r);
    var, expr := rec.var, rec.expr;
    dv := op(si, 0);
    new_loc := debug_value_loc(r);
    can := diexpr_is_deref(expr) || (!diexpr_starts_with_deref(expr) && value_covers_entire_fragment(vtype(dv), r));
    if !can dv = const_poison(vtype(dv));
    dbgr_insert_value_before(dv, var, expr, new_loc, si);
}

// InsertDebugValueAtStoreLoc
insert_debug_value_at_store_loc :: (r: u32, si: Value_Id) {
    rec := dbgr(r);
    var := rec.var;
    expr := diexpr_drop_initial_deref(rec.expr);
    new_loc := debug_value_loc(r);
    dbgr_insert_value_before(op(si, 0), var, expr, new_loc, si);
}

// PhiHasDebugValue
phi_has_debug_value :: (f: Value_Id, var: Md_Id, expr: Md_Id, phi: Value_Id) -> bool {
    users: [..] u32; users.allocator = temp;
    find_dbg_users(f, phi, *users, values_and_assigns_only = true);
    for users if dbgr(it).var == var && dbgr(it).expr == expr return true;
    return false;
}

// BasicBlock::getFirstInsertionPt (NONE = end)
block_first_insertion_pt :: (b: Value_Id) -> Value_Id {
    i := block(b).first;
    while i != NONE && inst_op(i) == .PHI i = inst(i).next;
    if i == NONE return NONE;
    o := inst_op(i);
    if o == .LANDINGPAD || o == .CATCHPAD || o == .CLEANUPPAD || o == .CATCHSWITCH {
        if o == .CATCHSWITCH return NONE;
        return inst(i).next;
    }
    return i;
}

// ConvertDebugDeclareToDebugValue(DVR, PHINode *APN, DIB)
convert_debug_declare_to_debug_value_phi :: (f: Value_Id, r: u32, phi: Value_Id) {
    rec := dbgr(r);
    var, expr := rec.var, rec.expr;
    if phi_has_debug_value(f, var, expr, phi) return;
    if !value_covers_entire_fragment(vtype(phi), r) return;
    b := inst(phi).parent;
    pt := block_first_insertion_pt(b);
    new_loc := debug_value_loc(r);
    if pt != NONE dbgr_insert_value_before(phi, var, expr, new_loc, pt);
}

// ---------------------------------------------------------------- discriminators (DILocation, Support/Discriminator.h)

disc_prefix_encoding_from_unsigned :: (u_in: u32) -> u32 { u := u_in & 0xfff; return ifx u > 0x1f then (((u & 0xfe0) << 1) | (u & 0x1f) | 0x20) else u; }
disc_unsigned_from_prefix_encoding :: (u_in: u32) -> u32 {
    if u_in & 1 return 0;
    u := u_in >> 1;
    return ifx (u & 0x20) != 0 then (((u >> 1) & 0xfe0) | (u & 0x1f)) else (u & 0x1f);
}
disc_next_component :: (d: u32) -> u32 {
    if (d & 1) == 0 return d >> (ifx (d & 0x40) != 0 then cast(u32) 14 else 7);
    return d >> 1;
}
disc_encode_component :: (c: u32) -> u32 { return ifx c == 0 then cast(u32) 1 else (disc_prefix_encoding_from_unsigned(c) << 1); }
disc_encoding_bits :: (c: u32) -> u32 { return ifx c == 0 then cast(u32) 1 else (ifx c > 0x1f then cast(u32) 14 else 7); }
disc_is_pseudo_probe :: (d: u32) -> bool { return (d & 0x7) == 0x7 && (d & 0xFFFFFFF8) != 0; }
disc_decode :: (d: u32) -> (u32, u32, u32) {
    bd := disc_unsigned_from_prefix_encoding(d);
    df := disc_unsigned_from_prefix_encoding(disc_next_component(d));
    ci := disc_unsigned_from_prefix_encoding(disc_next_component(disc_next_component(d)));
    return bd, df, ci;
}
// DILocation::encodeDiscriminator: (ok, encoded)
disc_encode :: (bd: u32, df: u32, ci: u32) -> (bool, u32) {
    comps := u32.[bd, df, ci];
    remaining: u64 = cast(u64) bd + df + ci;
    i := 0;
    ret: u32 = 0;
    next: u32 = 0;
    while remaining > 0 {
        c := comps[i]; i += 1;
        remaining -= c;
        ec := disc_encode_component(c);
        if next < 32 ret |= ec << next;
        next += disc_encoding_bits(c);
    }
    tbd, tdf, tci := disc_decode(ret);
    if tbd == bd && tdf == df && tci == ci return true, ret;
    return false, 0;
}
// DILocation::getDiscriminator
diloc_discriminator :: (l: Md_Id) -> u32 {
    s := diloc_scope(l);
    if s != NONE && is_di(s, .LEXICAL_BLOCK_FILE) return cast(u32) di_int(s, 0);
    return 0;
}
// DILocation::cloneWithDiscriminator
diloc_clone_with_discriminator :: (l: Md_Id, d: u32) -> Md_Id {
    scope := diloc_scope(l);
    while scope != NONE && is_di(scope, .LEXICAL_BLOCK_FILE) && di_int(scope, 0) != 0 scope = di_op(scope, 1);
    file := discope_file(diloc_scope(l));
    ns := di_get(.LEXICAL_BLOCK_FILE, false, .[file, scope], .[cast(u64) d]);
    return di_location_get(diloc_line(l), diloc_col(l), ns, diloc_inlined_at(l), di_int(l, 2), di_int(l, 3), di_int(l, 4));
}
// DILocation::cloneByMultiplyingDuplicationFactor (without FS discriminators): NONE when it cannot be encoded
diloc_clone_by_multiplying_duplication_factor :: (l: Md_Id, df_in: u32) -> Md_Id {
    d := diloc_discriminator(l);
    if disc_is_pseudo_probe(d) return l;
    cur := disc_unsigned_from_prefix_encoding(disc_next_component(d));   // getDuplicationFactor (0 means 1)
    if cur == 0 cur = 1;
    df := df_in * cur;
    if df <= 1 return l;
    bd := disc_unsigned_from_prefix_encoding(d);
    ci := disc_unsigned_from_prefix_encoding(disc_next_component(disc_next_component(d)));
    ok, enc := disc_encode(bd, df, ci);
    if ok return diloc_clone_with_discriminator(l, enc);
    return NONE;
}
// Function::shouldEmitDebugInfoForProfiling
fn_should_emit_debug_info_for_profiling :: (f: Value_Id) -> bool {
    sp := get_metadata(f, 0);
    if sp == NONE || !is_di(sp, .SUBPROGRAM) return false;
    cu := di_op(sp, 5);
    return cu != NONE && is_di(cu, .COMPILE_UNIT) && di_int(cu, 9) != 0;
}
