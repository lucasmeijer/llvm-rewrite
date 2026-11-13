// NewGVN: a port of llvm/lib/Transforms/Scalar/NewGVN.cpp and llvm/include/llvm/Transforms/Scalar/GVNExpression.h
// (the Expression hierarchy, CongruenceClass, TarjanSCC, symbolic evaluation of every instruction kind, MemorySSA
// based memory equivalence, PredicateInfo-based equalities, phi-of-ops, the RPO/DFS numbering and touched-instruction
// iteration, and the dominator-tree-ordered eliminator), plus VNCoercion.cpp's getConstantValueForLoad /
// getConstantMemInstValueForLoad (NewGVN-only).
//
// Data layout (DESIGN.md): expressions are rows of `ng.exprs` (the class hierarchy is the `et` tag; operands live in
// `ng.eops`), congruence classes are rows of `ng.classes`, and every DenseMap/SmallPtrSet of the pass is a Table or an
// ordered array. SmallPtrSet iteration is modelled as small-mode order (insertion order, erase moves the last element
// into the hole); LLVM's large-mode (pointer-hash) order cannot be reproduced. Pointer comparisons used as tie-breaks
// (shouldSwapOperands, ValueDFS) use value ids / use ids (creation order); where a predicate copy's value depends on
// such a tie, the pass fails loudly (ng_address_order_tie, newgvn_run) unless -newgvn-guess-address-order (ours). Assertion-only verification
// (verifyMemoryCongruency, verifyIterationSettled, verifyStoreExpressions) and statistics are not ported; the debug
// counters always execute.

ng_opts: struct {
    enable_store_refinement := false;   // -enable-store-refinement
    enable_phi_of_ops := true;          // -enable-phi-of-ops
    trace := false;                     // -newgvn-trace (ours: a subset of LLVM's -debug-only=newgvn on stderr)
    guess_address_order := false;       // -newgvn-guess-address-order (ours): guess creation order for LLVM's heap
                                        // address order instead of failing loudly (ng_address_order_dependent)
};

newgvn_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    b :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal(tprint("opt: invalid value '%' for -%", value, name));
        return false;
    }
    if name == "enable-store-refinement" { ng_opts.enable_store_refinement = b(name, value, has_value); return true; }
    if name == "newgvn-trace" { ng_opts.trace = true; return true; }
    if name == "newgvn-guess-address-order" { ng_opts.guess_address_order = b(name, value, has_value); return true; }
    if name == "enable-phi-of-ops" { ng_opts.enable_phi_of_ops = b(name, value, has_value); return true; }
    return false;
}

// ---------------------------------------------------------------- expressions (GVNExpression.h)

Ng_ET :: enum u8 { BASE; CONSTANT; VARIABLE; DEAD; UNKNOWN; BASIC; AGGREGATE; PHI; CALL; LOAD; STORE; }
ng_et_is_basic :: inline (et: Ng_ET) -> bool { return et >= .BASIC; }
ng_et_is_memory :: inline (et: Ng_ET) -> bool { return et >= .CALL; }

NG_OPC_VARIABLE :: 0x1000_0000;   // VariableExpression / ConstantExpression opcodes (getValueID in LLVM)
NG_OPC_CONSTANT :: 0x2000_0000;

Ng_Expr :: struct {
    et: Ng_ET;
    opcode: u32 = 0xFFFF_FFFD;
    ty: Type_Id = NONE;         // BasicExpression::ValueType
    ops: s32;                   // first operand in ng.eops
    nops: u32;
    maxops: u32;
    iops: s32;                  // AggregateValueExpression int operands in ng.eiops
    niops: u32;
    mem_leader: s32 = -1;       // MemoryExpression::MemoryLeader
    inst: Value_Id = NONE;      // Call / Load / Store / Unknown instruction
    stored: Value_Id = NONE;    // StoreExpression::StoredValue
    bb: Value_Id = NONE;        // PHIExpression::BB
    val: Value_Id = NONE;       // Variable / Constant value
    hash: u64;
}

// one entry of an expression-keyed map (ExpressionToClass, ExpressionToPhiOfOps); chained per hash
Ng_Ent :: struct { e: s32; cls: s32; next: s32 = -1; live: bool; users: [..] Value_Id; }
Ng_Emap :: struct {
    heads: Table(u64, s32);
    ents: [..] Ng_Ent;
}

// ---------------------------------------------------------------- congruence classes

Ng_Class :: struct {
    id: u32;
    leader: Value_Id = NONE; leader_dfs: u32 = 0xFFFF_FFFF;
    next_leader: Value_Id = NONE; next_leader_dfs: u32 = 0xFFFF_FFFF;
    stored: Value_Id = NONE;    // RepStoredValue
    mem_leader: s32 = -1;       // RepMemoryAccess
    def_expr: s32 = -1;         // DefiningExpr
    members: [..] Value_Id;     // SmallPtrSet<Value *, 4> (small-mode order)
    mem_members: [..] s32;      // SmallPtrSet<const MemoryPhi *, 2>
    store_count: s32;
}

Ng_Item :: struct { v: Value_Id = NONE; mp: s32 = -1; }   // DFSToInstr entry: an instruction or a MemoryPhi

Ng_Result :: struct { e: s32 = -1; extra: Value_Id = NONE; pred: s32 = -1; }   // ExprResult

Ng_Val_Pair :: struct { v: Value_Id; b: Value_Id; }

NG_MPS_INVALID :: cast(u8) 0; NG_MPS_TOP :: cast(u8) 1; NG_MPS_EQUIVALENT :: cast(u8) 2; NG_MPS_UNIQUE :: cast(u8) 3;
NG_ICS_UNKNOWN :: cast(u8) 0; NG_ICS_CYCLE_FREE :: cast(u8) 1; NG_ICS_CYCLE :: cast(u8) 2;

// SparseBitVector: sorted list
Ng_Sbv :: struct { bits: [..] u32; }

Ng_Value_Set :: struct { list: [..] Value_Id; has: Table(Value_Id, bool); }

Ng :: struct {
    f: Value_Id;
    dt: *Dom_Tree;
    ac: *Assumption_Cache;
    aar: Aa_Results;
    m: *Memory_SSA;
    pi: *Predicate_Info;
    sq: Simplify_Query;
    num_func_args: u32;

    exprs: [..] Ng_Expr;
    eops: [..] Value_Id;
    eiops: [..] u32;
    dead_expr: s32;

    rpo_ordering: Table(Value_Id, u32);   // keyed by block (DomTreeNode)

    classes: [..] Ng_Class;
    top: s32;
    member_pos: Table(Value_Id, s32);
    mphi_pos: Table(s32, s32);

    value_to_class: Table(Value_Id, s32);
    value_to_expr: Table(Value_Id, s32);
    phi_node_uses: Table(Value_Id, bool);
    op_safe: Table(u64, bool);
    cache_idx: u32;
    temp_to_block: Table(Value_Id, Value_Id);
    real_to_temp: Table(Value_Id, Value_Id);
    additional_users: Table(Value_Id, Ng_Value_Set);
    expr_to_phi_of_ops: Ng_Emap;
    temp_to_memory: Table(Value_Id, s32);
    all_temps: Table(Value_Id, bool);
    revisit: Table(Value_Id, Ng_Sbv);
    revisit_order: [..] Value_Id;
    predicate_to_users: Table(Value_Id, Ng_Value_Set);
    memory_to_users: Table(s32, [..] s32);
    memory_to_class: Table(s32, s32);
    mphi_state: Table(s32, u8);
    inst_cycle_state: Table(Value_Id, u8);
    expr_to_class: Ng_Emap;
    leader_changes: Table(Value_Id, bool);
    reachable_edges: Table(u64, bool);
    reachable_edge_list: [..] u64;
    reachable_blocks: Table(Value_Id, bool);
    touched: [..] u64;
    touched_bits: s64;
    block_inst_range: Table(Value_Id, [2] u32);
    predicate_swap_choice: Table(Value_Id, Value_Id);
    instr_dfs: Table(Value_Id, u32);
    mphi_dfs: Table(s32, u32);
    dfs_to_instr: [..] Ng_Item;
    to_erase: Ng_Value_Set;
    address_order_ties: [..] Value_Id;   // ng_address_order_tie candidates (ours)
    reverse_ties: bool;                  // break rank ties in reverse creation order (ours)

    // TarjanSCC
    scc_dfs_num: u32;
    scc_in_component: Table(Value_Id, bool);
    scc_root: Table(Value_Id, u32);
    scc_stack: [..] Value_Id;
    scc_components: [..] [..] Value_Id;
    scc_value_to_component: Table(Value_Id, u32);
}

ng: *Ng;

ng_vs_insert :: (s: *Ng_Value_Set, v: Value_Id) -> bool {
    if s.list.allocator.proc == null { s.list.allocator = temp; s.has.allocator = temp; }
    if table_contains(*s.has, v) return false;
    table_set(*s.has, v, true);
    array_add(*s.list, v);
    return true;
}
ng_vs_contains :: (s: *Ng_Value_Set, v: Value_Id) -> bool { return table_contains(*s.has, v); }

ng_sbv_set :: (s: *Ng_Sbv, x: u32) {
    if s.bits.allocator.proc == null s.bits.allocator = temp;
    lo := 0; hi := s.bits.count;
    while lo < hi { mid := (lo + hi) / 2; if s.bits[mid] < x lo = mid + 1; else hi = mid; }
    if lo < s.bits.count && s.bits[lo] == x return;
    array_add(*s.bits, 0);
    i := s.bits.count - 1;
    while i > lo { s.bits[i] = s.bits[i - 1]; i -= 1; }
    s.bits[lo] = x;
}
ng_sbv_reset :: (s: *Ng_Sbv, x: u32) {
    lo := 0; hi := s.bits.count;
    while lo < hi { mid := (lo + hi) / 2; if s.bits[mid] < x lo = mid + 1; else hi = mid; }
    if lo >= s.bits.count || s.bits[lo] != x return;
    for i: lo..s.bits.count - 2 s.bits[i] = s.bits[i + 1];
    s.bits.count -= 1;
}
// RevisitOnReachabilityChange[BB] (operator[] creates the entry)
ng_revisit :: (b: Value_Id) -> *Ng_Sbv {
    p := table_find_pointer(*ng.revisit, b);
    if p return p;
    blank: Ng_Sbv; blank.bits.allocator = temp;
    array_add(*ng.revisit_order, b);
    return table_set(*ng.revisit, b, blank);
}

// ---------------------------------------------------------------- touched-instruction bit vector

ng_touch :: inline (n: u32) {
    ng.touched[n >> 6] |= (cast(u64) 1) << (n & 63);
}
ng_touch_range :: (a: u32, b: u32) {
    if b > a for i: a..b - 1 ng_touch(i);
}
ng_untouch :: inline (n: u32) {
    ng.touched[n >> 6] &= ~((cast(u64) 1) << (n & 63));
}
ng_untouch_range :: (a: u32, b: u32) {
    if b > a for i: a..b - 1 ng_untouch(i);
}
// find_next: the first set bit at or after `from`, -1 if none
ng_find_set :: (from: s64) -> s64 {
    if from >= ng.touched_bits return -1;
    w := from >> 6;
    mask: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    mask <<= cast(u64) (from & 63);
    word := ng.touched[w] & mask;
    while true {
        if word != 0 {
            b := 0;
            x := word;
            while (x & 1) == 0 { x >>= 1; b += 1; }
            r := w * 64 + b;
            if r >= ng.touched_bits return -1;
            return r;
        }
        w += 1;
        if w >= ng.touched.count return -1;
        word = ng.touched[w];
    }
    return -1;
}
ng_any_touched :: () -> bool {
    for ng.touched if it != 0 return true;
    return false;
}

// ---------------------------------------------------------------- small lookups

ng_dfs :: inline (v: Value_Id) -> u32 {   // InstrToDFSNum(Value)
    found, n := table_find(*ng.instr_dfs, v);
    if found return n;
    return 0;
}
ng_mdfs :: (a: s32) -> u32 {   // MemoryToDFSNum
    if a < 0 return 0;
    if ma_is_phi(ng.m, a) {
        found, n := table_find(*ng.mphi_dfs, a);
        if found return n;
        return 0;
    }
    i := ma_inst(ng.m, a);
    if i == NONE return 0;
    return ng_dfs(i);
}
ng_class_of :: inline (v: Value_Id) -> s32 {
    found, c := table_find(*ng.value_to_class, v);
    if found return c;
    return -1;
}
ng_cls :: inline (c: s32) -> *Ng_Class { return *ng.classes[c]; }
ng_expr :: inline (e: s32) -> *Ng_Expr { return *ng.exprs[e]; }
ng_eop :: inline (e: s32, k: u32) -> Value_Id { return ng.eops[ng.exprs[e].ops + cast(s32) k]; }
ng_set_eop :: inline (e: s32, k: u32, v: Value_Id) { ng.eops[ng.exprs[e].ops + cast(s32) k] = v; }

// getMemoryAccess(const Instruction *): real or temporary
ng_memory_access :: (i: Value_Id) -> s32 {
    a := mssa_access_of(ng.m, i);
    if a >= 0 return a;
    found, t := table_find(*ng.temp_to_memory, i);
    if found return t;
    return -1;
}
// getMemoryAccess(const BasicBlock *)
ng_memory_phi :: (b: Value_Id) -> s32 {
    a := mssa_access_of(ng.m, b);
    if a >= 0 && ma_is_phi(ng.m, a) return a;
    return -1;
}

// getBlockForValue (instructions; MemoryPhis use ng_item_block)
ng_block_of :: (v: Value_Id) -> Value_Id {
    p := inst(v).parent;
    if p != NONE return p;
    found, b := table_find(*ng.temp_to_block, v);
    if !found fatal("newgvn: internal: a temporary instruction has no block");
    return b;
}
ng_item_block :: (it: Ng_Item) -> Value_Id {
    if it.mp >= 0 return ma_block(ng.m, it.mp);
    return ng_block_of(it.v);
}

ng_is_undef :: inline (v: Value_Id) -> bool { k := vkind(v); return k == .C_UNDEF || k == .C_POISON; }   // isa<UndefValue>
ng_always_available :: inline (v: Value_Id) -> bool { return is_const(v) || is_argument(v); }

// getCopyOf / isCopyOfPHI / isCopyOfAPHI
ng_copy_of :: (v: Value_Id) -> Value_Id {
    if is_inst(v) && inst_op(v) == .BITCAST && vtype(v) == vtype(op(v, 0)) return op(v, 0);
    return NONE;
}
ng_is_copy_of_phi :: (v: Value_Id, pn: Value_Id) -> bool { return v == pn || ng_copy_of(v) == pn; }
ng_is_copy_of_a_phi :: (v: Value_Id) -> bool { c := ng_copy_of(v); return c != NONE && is_phi(c); }

ng_edge_key :: inline (from: Value_Id, to: Value_Id) -> u64 { return ((cast(u64) from) << 32) | cast(u64) to; }
ng_edge_reachable :: inline (from: Value_Id, to: Value_Id) -> bool { return table_contains(*ng.reachable_edges, ng_edge_key(from, to)); }
ng_block_reachable :: inline (b: Value_Id) -> bool { return table_contains(*ng.reachable_blocks, b); }
ng_rpo :: inline (b: Value_Id) -> u32 { found, n := table_find(*ng.rpo_ordering, b); if found return n; return 0; }

// isBackedge
ng_is_backedge :: (from: Value_Id, to: Value_Id) -> bool {
    return from == to || ng_rpo(from) >= ng_rpo(to);
}

// ---------------------------------------------------------------- expression construction

ng_new_expr :: (et: Ng_ET, maxops: u32 = 0) -> s32 {
    e: Ng_Expr;
    e.et = et;
    e.maxops = maxops;
    e.ops = cast(s32) ng.eops.count;
    for 0..cast(s64) maxops - 1 array_add(*ng.eops, NONE);
    array_add(*ng.exprs, e);
    return cast(s32) (ng.exprs.count - 1);
}
ng_op_push :: (e: s32, v: Value_Id) {
    x := ng_expr(e);
    if x.nops >= x.maxops fatal("newgvn: internal: too many expression operands");
    ng.eops[x.ops + cast(s32) x.nops] = v;
    x.nops += 1;
}
ng_swap_ops :: (e: s32, a: u32, b: u32) {
    x := ng_eop(e, a); ng_set_eop(e, a, ng_eop(e, b)); ng_set_eop(e, b, x);
}

ng_hash_mix :: inline (h: u64, x: u64) -> u64 {
    r := (h ^ x) * 0x9E37_79B9_7F4A_7C15;
    return r ^ (r >> 29);
}
// getComputedHash (a hash consistent with operator==: Load and Store expressions hash alike)
ng_hash :: (e: s32) -> u64 {
    x := ng_expr(e);
    if x.hash != 0 return x.hash;
    h: u64 = 0x1234_5678;
    h = ng_hash_mix(h, x.opcode);
    if ng_et_is_basic(x.et) {
        h = ng_hash_mix(h, x.ty);
        for k: 0..cast(s64) x.nops - 1 h = ng_hash_mix(h, ng.eops[x.ops + cast(s32) k]);
        if ng_et_is_memory(x.et) h = ng_hash_mix(h, cast(u64) (x.mem_leader + 7));
        if x.et == .AGGREGATE for k: 0..cast(s64) x.niops - 1 h = ng_hash_mix(h, ng.eiops[x.iops + cast(s32) k]);
        if x.et == .PHI h = ng_hash_mix(h, x.bb);
    } else if x.et == .VARIABLE || x.et == .CONSTANT {
        h = ng_hash_mix(h, x.val);
    } else if x.et == .UNKNOWN {
        h = ng_hash_mix(h, x.inst);
    }
    if h == 0 h = 1;
    x.hash = h;
    return h;
}

ng_basic_equals :: (a: *Ng_Expr, b: *Ng_Expr) -> bool {
    if a.opcode != b.opcode return false;
    if a.ty != b.ty || a.nops != b.nops return false;
    for k: 0..cast(s64) a.nops - 1 if ng.eops[a.ops + cast(s32) k] != ng.eops[b.ops + cast(s32) k] return false;
    return true;
}
ng_memory_equals :: (a: *Ng_Expr, b: *Ng_Expr) -> bool {
    if !ng_basic_equals(a, b) return false;
    return a.mem_leader == b.mem_leader;
}
// a->equals(b) (the virtual method of a's class)
ng_equals :: (ea: s32, eb: s32) -> bool {
    a := ng_expr(ea); b := ng_expr(eb);
    if a.et == {
        case .BASE; return true;
        case .DEAD; return true;
        case .VARIABLE; return a.val == b.val;
        case .CONSTANT; return a.val == b.val;
        case .UNKNOWN; return a.inst == b.inst;
        case .BASIC; return ng_basic_equals(a, b);
        case .AGGREGATE;
            if !ng_basic_equals(a, b) return false;
            if a.niops != b.niops return false;
            for k: 0..cast(s64) a.niops - 1 if ng.eiops[a.iops + cast(s32) k] != ng.eiops[b.iops + cast(s32) k] return false;
            return true;
        case .PHI; return ng_basic_equals(a, b) && a.bb == b.bb;
        case .CALL;
            if !ng_memory_equals(a, b) return false;
            if b.et == .CALL {
                ok, _ := attr_list_intersect(inst(a.inst).attrs, inst(b.inst).attrs);
                return ok;
            }
            return false;
        case .LOAD;
            if b.et != .LOAD && b.et != .STORE return false;
            return ng_memory_equals(a, b);
        case .STORE;
            if b.et != .LOAD && b.et != .STORE return false;
            if !ng_memory_equals(a, b) return false;
            if b.et == .STORE && a.stored != b.stored return false;
            return true;
    }
    return false;
}
// Expression::operator==
ng_expr_eq :: (ea: s32, eb: s32) -> bool {
    a := ng_expr(ea); b := ng_expr(eb);
    if a.opcode != b.opcode return false;
    if a.et != .LOAD && a.et != .STORE && a.et != b.et return false;
    return ng_equals(ea, eb);
}
// DenseMapInfo<const Expression *>::isEqual
ng_expr_is_equal :: (ea: s32, eb: s32) -> bool {
    if ea == eb return true;
    if ng_hash(ea) != ng_hash(eb) return false;
    return ng_expr_eq(ea, eb);
}
// exactlyEquals
ng_exactly_equals :: (ea: s32, eb: s32) -> bool {
    a := ng_expr(ea); b := ng_expr(eb);
    if a.et != b.et return false;
    if !ng_equals(ea, eb) return false;
    if a.et == .CALL || a.et == .LOAD || a.et == .STORE return a.inst == b.inst;
    return true;
}

// expression maps
ng_emap_find :: (m: *Ng_Emap, e: s32, exact := false) -> s32 {
    h := ng_hash(e);
    found, k := table_find(*m.heads, h);
    if !found return -1;
    while k >= 0 {
        ent := *m.ents[k];
        if ent.live {
            ok := ifx exact then (ng_hash(ent.e) == h && ng_exactly_equals(e, ent.e)) else ng_expr_is_equal(e, ent.e);
            if ok return k;
        }
        k = ent.next;
    }
    return -1;
}
ng_emap_insert :: (m: *Ng_Emap, e: s32) -> s32 {
    h := ng_hash(e);
    ent: Ng_Ent; ent.e = e; ent.cls = -1; ent.live = true; ent.users.allocator = temp;
    found, head := table_find(*m.heads, h);
    ent.next = ifx found then head else -1;
    array_add(*m.ents, ent);
    k := cast(s32) (m.ents.count - 1);
    table_set(*m.heads, h, k);
    return k;
}
ng_emap_erase :: (m: *Ng_Emap, k: s32) { m.ents[k].live = false; }
ng_emap_lookup_class :: (m: *Ng_Emap, e: s32) -> s32 {
    k := ng_emap_find(m, e);
    if k < 0 return -1;
    return m.ents[k].cls;
}

// createPHIExpression
ng_create_phi_expression :: (phi_ops: [] Ng_Val_Pair, i: Value_Id, phi_bb: Value_Id, has_backedge: *bool, orig_const: *bool) -> s32 {
    e := ng_new_expr(.PHI, cast(u32) phi_ops.count);
    x := ng_expr(e);
    x.bb = phi_bb;
    x.ty = vtype(phi_ops[0].v);
    x.opcode = cast(u32) Opcode.PHI;
    for p: phi_ops {
        bb := p.b;
        if inst_op(i) == .PHI && ng_is_copy_of_phi(p.v, i) continue;
        if !ng_edge_reachable(bb, phi_bb) continue;
        if ng_class_of(p.v) == ng.top continue;
        orig_const.* = orig_const.* && is_const(p.v);
        has_backedge.* = has_backedge.* || ng_is_backedge(bb, phi_bb);
        if ng_lookup_operand_leader(p.v) == i continue;
        ng_op_push(e, ng_lookup_operand_leader(p.v));
    }
    return e;
}

// setBasicExpressionInfo
ng_set_basic_info :: (i: Value_Id, e: s32) -> bool {
    all_constant := true;
    x := ng_expr(e);
    if inst_op(i) == .GEP x.ty = inst(i).ty2; else x.ty = vtype(i);
    x.opcode = cast(u32) inst_op(i);
    n := nops(i);
    for k: 0..cast(s64) n - 1 {
        o := ng_lookup_operand_leader(op(i, cast(u32) k));
        all_constant = all_constant && is_const(o);
        ng_op_push(e, o);
    }
    return all_constant;
}

ng_q :: (i: Value_Id) -> Simplify_Query { return sq_with_instruction(ng.sq, i); }

// createBinaryExpression
ng_create_binary_expression :: (opcode: Opcode, t: Type_Id, a1_in: Value_Id, a2_in: Value_Id, i: Value_Id) -> s32 {
    e := ng_new_expr(.BASIC, 2);
    q := ng_q(i);
    x := ng_expr(e);
    x.ty = t;
    x.opcode = cast(u32) opcode;
    a1 := a1_in; a2 := a2_in;
    if is_commutative_op(opcode) {
        if ng_should_swap_operands(a1, a2) { tmp := a1; a1 = a2; a2 = tmp; }
    }
    ng_op_push(e, ng_lookup_operand_leader(a1));
    ng_op_push(e, ng_lookup_operand_leader(a2));
    v := simplify_binop(opcode, ng_eop(e, 0), ng_eop(e, 1), q);
    r := ng_check_expr_results(e, i, v);
    if r.e >= 0 {
        ng_add_additional_users_result(*r, i);
        return r.e;
    }
    return e;
}

// checkExprResults
ng_check_expr_results :: (e: s32, i: Value_Id, v: Value_Id) -> Ng_Result {
    r: Ng_Result;
    if v == NONE return r;
    if is_const(v) {
        r.e = ng_create_constant_expression(v);
        return r;
    } else if is_argument(v) || vkind(v) == .GLOBAL_VAR {
        r.e = ng_create_variable_expression(v);
        return r;
    }
    cc := ng_class_of(v);
    if cc >= 0 {
        c := ng_cls(cc);
        if c.leader != NONE && c.leader != i {
            r.e = ng_create_variable_or_constant(c.leader);
            r.extra = v;
            return r;
        }
        if c.def_expr >= 0 {
            r.e = c.def_expr;
            r.extra = v;
            return r;
        }
    }
    return r;
}

// createExpression
ng_create_expression :: (i: Value_Id) -> Ng_Result {
    e := ng_new_expr(.BASIC, nops(i));
    q := ng_q(i);
    all_constant := ng_set_basic_info(i, e);
    opc := inst_op(i);
    if inst_is_commutative(i) {
        if ng_should_swap_operands(ng_eop(e, 0), ng_eop(e, 1)) ng_swap_ops(e, 0, 1);
    }
    if opc == .ICMP || opc == .FCMP {
        pred := inst(i).pred;
        if ng_should_swap_operands(ng_eop(e, 0), ng_eop(e, 1)) {
            ng_swap_ops(e, 0, 1);
            pred = swapped_predicate(pred);
        }
        ng_expr(e).opcode = ((cast(u32) opc) << 8) | cast(u32) pred;
        v := simplify_cmp_inst(pred, false, ng_eop(e, 0), ng_eop(e, 1), q);
        r := ng_check_expr_results(e, i, v);
        if r.e >= 0 return r;
    } else if opc == .SELECT {
        if is_const(ng_eop(e, 0)) || ng_eop(e, 1) == ng_eop(e, 2) {
            v := simplify_select_inst(ng_eop(e, 0), ng_eop(e, 1), ng_eop(e, 2), 0, q);
            r := ng_check_expr_results(e, i, v);
            if r.e >= 0 return r;
        }
    } else if is_binary_op(opc) {
        v := simplify_binop(opc, ng_eop(e, 0), ng_eop(e, 1), q);
        r := ng_check_expr_results(e, i, v);
        if r.e >= 0 return r;
    } else if is_cast_op(opc) {
        v := simplify_cast_inst(opc, ng_eop(e, 0), vtype(i), q);
        r := ng_check_expr_results(e, i, v);
        if r.e >= 0 return r;
    } else if opc == .GEP {
        idxs: [..] Value_Id; idxs.allocator = temp;
        n := ng_expr(e).nops;
        for k: 1..cast(s64) n - 1 array_add(*idxs, ng_eop(e, cast(u32) k));
        v := simplify_gep_inst(inst(i).ty2, ng_eop(e, 0), idxs, gep_nw_bits(i), q);
        r := ng_check_expr_results(e, i, v);
        if r.e >= 0 return r;
    } else if all_constant {
        cs: [..] Value_Id; cs.allocator = temp;
        n := ng_expr(e).nops;
        for k: 0..cast(s64) n - 1 array_add(*cs, ng_eop(e, cast(u32) k));
        v := cfo_inst_operands(i, cs);
        if v != NONE {
            r := ng_check_expr_results(e, i, v);
            if r.e >= 0 return r;
        }
    }
    r: Ng_Result; r.e = e;
    return r;
}

// createAggregateValueExpression
ng_create_aggregate_value_expression :: (i: Value_Id) -> s32 {
    e := ng_new_expr(.AGGREGATE, nops(i));
    ng_set_basic_info(i, e);
    idx := inst_indices(i);
    x := ng_expr(e);
    x.iops = cast(s32) ng.eiops.count;
    x.niops = cast(u32) idx.count;
    for idx array_add(*ng.eiops, it);
    return e;
}

ng_create_dead_expression :: () -> s32 { return ng.dead_expr; }
ng_create_variable_expression :: (v: Value_Id) -> s32 {
    e := ng_new_expr(.VARIABLE);
    x := ng_expr(e); x.val = v; x.opcode = NG_OPC_VARIABLE | cast(u32) vkind(v);
    return e;
}
ng_create_constant_expression :: (c: Value_Id) -> s32 {
    e := ng_new_expr(.CONSTANT);
    x := ng_expr(e); x.val = c; x.opcode = NG_OPC_CONSTANT | cast(u32) vkind(c);
    return e;
}
ng_create_variable_or_constant :: (v: Value_Id) -> s32 {
    if is_const(v) return ng_create_constant_expression(v);
    return ng_create_variable_expression(v);
}
ng_create_unknown_expression :: (i: Value_Id) -> s32 {
    e := ng_new_expr(.UNKNOWN);
    x := ng_expr(e); x.inst = i; x.opcode = cast(u32) inst_op(i);
    return e;
}

// createCallExpression
ng_create_call_expression :: (ci: Value_Id, ma_: s32) -> s32 {
    e := ng_new_expr(.CALL, nops(ci));
    ng_expr(e).inst = ci;
    ng_expr(e).mem_leader = ma_;
    ng_set_basic_info(ci, e);
    if inst_is_commutative(ci) {
        if ng_should_swap_operands(ng_eop(e, 0), ng_eop(e, 1)) ng_swap_ops(e, 0, 1);
    }
    return e;
}

// someEquivalentDominates
ng_some_equivalent_dominates :: (inst_: Value_Id, u: Value_Id) -> bool {
    cc := ng_class_of(inst_);
    if cc < 0 return false;
    c := ng_cls(cc);
    if ng_always_available(c.leader) return true;
    if dt_dominates_inst(ng.dt, c.leader, u) return true;
    if c.next_leader != NONE && dt_dominates_inst(ng.dt, c.next_leader, u) return true;
    for m: c.members {
        if m != c.leader && dt_dominates_inst(ng.dt, m, u) return true;
    }
    return false;
}

// lookupOperandLeader
ng_lookup_operand_leader :: (v: Value_Id) -> Value_Id {
    cc := ng_class_of(v);
    if cc >= 0 {
        if cc == ng.top return const_poison(vtype(v));
        c := ng_cls(cc);
        return ifx c.stored != NONE then c.stored else c.leader;
    }
    return v;
}

// lookupMemoryLeader
ng_lookup_memory_leader :: (a: s32) -> s32 {
    cc := ng_memory_class(a);
    l := ng_cls(cc).mem_leader;
    if l < 0 fatal("newgvn: internal: memory class without a leader");
    return l;
}
ng_is_memory_access_top :: (a: s32) -> bool {
    found, c := table_find(*ng.memory_to_class, a);
    return found && c == ng.top;
}

// createLoadExpression
ng_create_load_expression :: (load_ty: Type_Id, ptr: Value_Id, li: Value_Id, ma_: s32) -> s32 {
    e := ng_new_expr(.LOAD, 1);
    x := ng_expr(e);
    x.inst = li;
    x.mem_leader = ng_lookup_memory_leader(ma_);
    x.ty = load_ty;
    x.opcode = 0;
    ng_op_push(e, ptr);
    return e;
}
// createStoreExpression
ng_create_store_expression :: (si: Value_Id, ma_: s32) -> s32 {
    stored_leader := ng_lookup_operand_leader(op(si, 0));
    e := ng_new_expr(.STORE, nops(si));
    x := ng_expr(e);
    x.inst = si;
    x.stored = stored_leader;
    x.mem_leader = ma_;
    x.ty = vtype(op(si, 0));
    x.opcode = 0;
    ng_op_push(e, ng_lookup_operand_leader(op(si, 1)));
    return e;
}

ng_store_is_simple :: (i: Value_Id) -> bool { return inst(i).ord1 == 0 && (inst(i).flags & F_VOLATILE) == 0; }

ng_walker_clobber :: (a: s32) -> s32 {   // MSSAWalker->getClobberingMemoryAccess(MA)
    return mssa_get_clobbering_access(ng.m, a, aa_query_new(*ng.aar));
}

// performSymbolicStoreEvaluation
ng_perform_symbolic_store_evaluation :: (i: Value_Id) -> s32 {
    si := i;
    store_access := ng_memory_access(si);
    store_rhs := ma_defining(ng.m, store_access);
    if ng_opts.enable_store_refinement store_rhs = ng_walker_clobber(store_access);
    store_rhs = ng_lookup_memory_leader(store_rhs);
    if store_rhs != ma_defining(ng.m, store_access) ng_add_memory_users(store_rhs, store_access);
    if store_rhs == store_access store_rhs = MSSA_LIVE_ON_ENTRY;
    if ng_store_is_simple(si) {
        last_store := ng_create_store_expression(si, store_rhs);
        last_cc := ng_emap_lookup_class(*ng.expr_to_class, last_store);
        if last_cc >= 0 && ng_cls(last_cc).stored == ng_expr(last_store).stored return last_store;
        sv := ng_expr(last_store).stored;
        if is_inst(sv) && inst_op(sv) == .LOAD {
            li := sv;
            if ng_lookup_operand_leader(op(li, 0)) == ng_eop(last_store, 0) &&
               ng_lookup_memory_leader(ma_defining(ng.m, ng_memory_access(li))) == store_rhs
                return last_store;
        }
    }
    return ng_create_store_expression(si, store_access);
}

// performSymbolicLoadCoercion
ng_perform_symbolic_load_coercion :: (load_ty: Type_Id, load_ptr: Value_Id, li: Value_Id, dep: Value_Id, defining: s32) -> s32 {
    dop := inst_op(dep);
    if dop == .STORE {
        if (inst_is_atomic(li) && !inst_is_atomic(dep)) || load_ty == vtype(op(dep, 0)) return -1;
        offset := vnc_analyze_load_from_clobbering_store(load_ty, load_ptr, dep);
        if offset >= 0 {
            c := ng_lookup_operand_leader(op(dep, 0));
            if is_const(c) {
                res := ng_get_constant_value_for_load(c, cast(u64) offset, load_ty);
                if res != NONE return ng_create_constant_expression(res);
            }
        }
    } else if dop == .LOAD {
        if inst_is_atomic(li) && !inst_is_atomic(dep) return -1;
        offset := vnc_analyze_load_from_clobbering_load(load_ty, load_ptr, dep);
        if offset >= 0 {
            c := ng_lookup_operand_leader(dep);
            if is_const(c) {
                pc := ng_get_constant_value_for_load(c, cast(u64) offset, load_ty);
                if pc != NONE return ng_create_constant_expression(pc);
            }
        }
    } else if dop == .CALL && is_mem_intrinsic(dep) {
        offset := vnc_analyze_load_from_clobbering_mem_inst(load_ty, load_ptr, dep);
        if offset >= 0 {
            pc := ng_get_constant_mem_inst_value_for_load(dep, cast(u64) offset, load_ty);
            if pc != NONE return ng_create_constant_expression(pc);
        }
    }
    if call_iid(dep) == IID_LIFETIME_START {
        lifetime_ptr := op(dep, 0);
        if load_ptr == ng_lookup_operand_leader(lifetime_ptr) || aa_is_must_alias_values(aa_query_new(*ng.aar), load_ptr, lifetime_ptr)
            return ng_create_constant_expression(const_undef(load_ty));
    }
    if !is_ptr_type(vtype(dep)) || (load_ptr != ng_lookup_operand_leader(dep) && !aa_is_must_alias_values(aa_query_new(*ng.aar), load_ptr, dep))
        return -1;
    if dop == .ALLOCA return ng_create_constant_expression(const_undef(load_ty));
    init_val := get_initial_value_of_allocation(dep, load_ty);
    if init_val != NONE return ng_create_constant_expression(init_val);
    return -1;
}

// performSymbolicLoadEvaluation
ng_perform_symbolic_load_evaluation :: (i: Value_Id) -> s32 {
    li := i;
    if !load_is_simple(li) return -1;
    addr_leader := ng_lookup_operand_leader(op(li, 0));
    if ng_is_undef(addr_leader) return ng_create_constant_expression(const_poison(vtype(li)));
    original := ng_memory_access(i);
    defining := ng_walker_clobber(original);
    if !is_live_on_entry(defining) {
        if ma_is_def(ng.m, defining) {
            def_inst := ma_inst(ng.m, defining);
            if !ng_block_reachable(inst_block(def_inst)) return ng_create_constant_expression(const_poison(vtype(li)));
            cr := ng_perform_symbolic_load_coercion(vtype(li), addr_leader, li, def_inst, defining);
            if cr >= 0 return cr;
        }
    }
    le := ng_create_load_expression(vtype(li), addr_leader, li, defining);
    if ng_expr(le).mem_leader != defining ng_add_memory_users(ng_expr(le).mem_leader, original);
    return le;
}

// Our check, not LLVM's: shouldSwapOperands breaks a rank tie by pointer value (heap layout), so for an equality of two
// different operands of equal rank, which one becomes the copy's value depends on LLVM's address order
// (knowledge/llvm/newgvn.md, "PredicateInfo copies"). Ties seen while iterating are recorded; newgvn_run then
// iterates again with the ties broken the other way and fails loudly if the outcome differs.
ng_address_order_tie :: (first: Value_Id, second: Value_Id, pred: u8) -> bool {
    if first == second || ng_get_rank(first) != ng_get_rank(second) return false;
    fp_ok :: (v: Value_Id) -> bool { return vkind(v) == .C_FP && !pm_any_zero_fp(v); }
    return pred == ICMP_EQ || (pred == FCMP_OEQ && (fp_ok(first) || fp_ok(second)));
}
// The iteration's outcome as elimination sees it: reachable blocks and edges, and every instruction's class leader
// (temporaries by their incoming values) and phi-of-ops temporary.
ng_outcome_snapshot :: () -> string {
    sb: String_Builder; sb.allocator = temp;
    rep :: (sb: *String_Builder, v: Value_Id) {
        if v != NONE && is_inst(v) && table_contains(*ng.all_temps, v) {
            print_to_builder(sb, "T(");
            for k: 0..nops(v) - 1 print_to_builder(sb, "%,", op(v, k));
            print_to_builder(sb, ")");
        } else print_to_builder(sb, "%", v);
    }
    edges: [..] u64; edges.allocator = temp;
    for ng.reachable_edge_list array_add(*edges, it);
    quick_sort(edges, (a: u64, b: u64) -> s64 { return ifx a < b then -1 else ifx a > b then 1 else 0; });
    for edges print_to_builder(*sb, "e%,", it);
    for b: fn_blocks(ng.f) {
        print_to_builder(*sb, "\nb%:%", b, ng_block_reachable(b));
        for i: block_insts(b) {
            print_to_builder(*sb, " ");
            found, c := table_find(*ng.value_to_class, i);
            if found { rep(*sb, ng.classes[c].leader); print_to_builder(*sb, "/%/", ng.classes[c].stored); }
            found2, t := table_find(*ng.real_to_temp, i);
            if found2 rep(*sb, t);
        }
    }
    return builder_to_string(*sb,, temp);
}

// performSymbolicPredicateInfoEvaluation
ng_perform_symbolic_predicate_info_evaluation :: (i: Value_Id) -> Ng_Result {
    r: Ng_Result;
    pidx := ng_pi_of(i);
    if pidx < 0 return r;
    p := *ng.pi.infos[pidx];
    c := pi_get_constraint(p);
    if !c.ok return r;
    pred := c.pred;
    cmp_op0 := op(i, 0);
    cmp_op1 := c.other;
    first := ng_lookup_operand_leader(cmp_op0);
    second := ng_lookup_operand_leader(cmp_op1);
    additionally_used := cmp_op0;
    if !ng_opts.guess_address_order && ng_address_order_tie(first, second, pred) array_add(*ng.address_order_ties, i);
    if ng_should_swap_operands_for_predicate(first, second, i) {
        tmp := first; first = second; second = tmp;
        pred = swapped_predicate(pred);
        additionally_used = cmp_op1;
    }
    if pred == ICMP_EQ {
        r.e = ng_create_variable_or_constant(first);
        r.extra = additionally_used; r.pred = pidx;
        return r;
    }
    if pred == FCMP_OEQ && vkind(first) == .C_FP && !pm_any_zero_fp(first) {
        r.e = ng_create_constant_expression(first);
        r.extra = additionally_used; r.pred = pidx;
        return r;
    }
    return r;
}
// performSymbolicCallEvaluation
ng_perform_symbolic_call_evaluation :: (i: Value_Id) -> Ng_Result {
    r: Ng_Result;
    ci := i;
    if fn_has_fn_attr(ng.f, .PresplitCoroutine) return r;
    if call_is_convergent(ci) return r;
    if aar_does_not_access_memory(*ng.aar, ci) {
        r.e = ng_create_call_expression(ci, ng_cls(ng.top).mem_leader);
        return r;
    } else if aar_only_reads_memory(*ng.aar, ci) {
        a := mssa_access_of(ng.m, ci);
        if a >= 0 {
            d := ng_walker_clobber(a);
            r.e = ng_create_call_expression(ci, d);
            return r;
        }
        r.e = ng_create_call_expression(ci, ng_cls(ng.top).mem_leader);
        return r;
    }
    return r;
}

// getMemoryClass
ng_memory_class :: (a: s32) -> s32 {
    found, c := table_find(*ng.memory_to_class, a);
    if !found fatal("newgvn: internal: no memory class for an access");
    return c;
}

// setMemoryClass
ng_set_memory_class :: (from: s32, new_class: s32) -> bool {
    p := table_find_pointer(*ng.memory_to_class, from);
    changed := false;
    if p {
        old_class := p.*;
        if old_class != new_class {
            if ma_is_phi(ng.m, from) {
                ng_mem_member_erase(old_class, from);
                ng_mem_member_insert(new_class, from);
                if ng_cls(old_class).mem_leader == from {
                    if ng_defines_no_memory(old_class) {
                        ng_cls(old_class).mem_leader = -1;
                    } else {
                        ng_cls(old_class).mem_leader = ng_get_next_memory_leader(old_class);
                        ng_mark_memory_leader_change_touched(old_class);
                    }
                }
            }
            p = table_find_pointer(*ng.memory_to_class, from);
            p.* = new_class;
            changed = true;
        }
    }
    return changed;
}

// isCycleFree
ng_is_cycle_free :: (i: Value_Id) -> bool {
    found, ics := table_find(*ng.inst_cycle_state, i);
    if !found ics = NG_ICS_UNKNOWN;
    if ics == NG_ICS_UNKNOWN {
        ng_scc_start(i);
        scc := ng_scc_component_for(i);
        if scc.count == 1 {
            if !table_contains(*ng.inst_cycle_state, i) table_set(*ng.inst_cycle_state, i, NG_ICS_CYCLE_FREE);
        } else {
            all_phis := true;
            for v: scc.* if !(is_phi(v) || ng_is_copy_of_a_phi(v)) { all_phis = false; break; }
            ics = ifx all_phis then NG_ICS_CYCLE_FREE else NG_ICS_CYCLE;
            for v: scc.* if is_phi(v) && !table_contains(*ng.inst_cycle_state, v) table_set(*ng.inst_cycle_state, v, ics);
        }
    }
    if ics == NG_ICS_CYCLE return false;
    return true;
}

// TarjanSCC::Start / FindSCC (iterative; the recursion order is kept)
ng_scc_start :: (start: Value_Id) {
    found, r := table_find(*ng.scc_root, start);
    if found && r != 0 return;
    Frame :: struct { i: Value_Id; k: u32; our_dfs: u32; pending: Value_Id; }
    stack: [..] Frame; stack.allocator = temp;
    push :: (stack: *[..] Frame, i: Value_Id) {
        ng.scc_dfs_num += 1;
        table_set(*ng.scc_root, i, ng.scc_dfs_num);
        array_add(stack, .{i, 0, ng.scc_dfs_num, NONE});
    }
    root_of :: (v: Value_Id) -> u32 { found, r := table_find(*ng.scc_root, v); if found return r; return 0; }
    push(*stack, start);
    while stack.count {
        fr := *stack[stack.count - 1];
        if fr.pending != NONE {
            o := fr.pending;
            fr.pending = NONE;
            if !table_contains(*ng.scc_in_component, o) table_set(*ng.scc_root, fr.i, min(root_of(fr.i), root_of(o)));
        }
        descended := false;
        while fr.k < nops(fr.i) {
            o := op(fr.i, fr.k);
            fr.k += 1;
            if !is_inst(o) continue;
            if root_of(o) == 0 {
                fr.pending = o;
                push(*stack, o);
                descended = true;
                break;
            }
            if !table_contains(*ng.scc_in_component, o) table_set(*ng.scc_root, fr.i, min(root_of(fr.i), root_of(o)));
        }
        if descended continue;
        i := fr.i; our := fr.our_dfs;
        stack.count -= 1;
        if root_of(i) == our {
            comp_id := cast(u32) ng.scc_components.count;
            comp: [..] Value_Id; comp.allocator = temp;
            array_add(*comp, i);
            table_set(*ng.scc_in_component, i, true);
            table_set(*ng.scc_value_to_component, i, comp_id);
            while ng.scc_stack.count && root_of(ng.scc_stack[ng.scc_stack.count - 1]) >= our {
                mbr := ng.scc_stack[ng.scc_stack.count - 1];
                array_add(*comp, mbr);
                table_set(*ng.scc_in_component, mbr, true);
                table_set(*ng.scc_value_to_component, mbr, comp_id);
                ng.scc_stack.count -= 1;
            }
            array_add(*ng.scc_components, comp);
        } else {
            array_add(*ng.scc_stack, i);
        }
    }
}
ng_scc_component_for :: (v: Value_Id) -> *[..] Value_Id {
    found, c := table_find(*ng.scc_value_to_component, v);
    if !found fatal("newgvn: internal: asking for a component for a value we never processed");
    return *ng.scc_components[c];
}

// performSymbolicPHIEvaluation
ng_perform_symbolic_phi_evaluation :: (phi_ops: [] Ng_Val_Pair, i: Value_Id, phi_bb: Value_Id) -> s32 {
    has_backedge := false;
    orig_const := true;
    e := ng_create_phi_expression(phi_ops, i, phi_bb, *has_backedge, *orig_const);
    has_undef := false; has_poison := false;
    filtered: [..] Value_Id; filtered.allocator = temp;
    n := ng_expr(e).nops;
    for k: 0..cast(s64) n - 1 {
        arg := ng_eop(e, cast(u32) k);
        if vkind(arg) == .C_POISON { has_poison = true; continue; }
        if vkind(arg) == .C_UNDEF { has_undef = true; continue; }
        array_add(*filtered, arg);
    }
    if filtered.count == 0 {
        if has_undef return ng_create_constant_expression(const_undef(vtype(i)));
        if has_poison return ng_create_constant_expression(const_poison(vtype(i)));
        return ng_create_dead_expression();
    }
    all_same := filtered[0];
    same := true;
    for k: 1..filtered.count - 1 if filtered[k] != all_same { same = false; break; }
    if same {
        if has_undef && !is_guaranteed_not_to_be_poison(all_same, ng.ac, NONE, ng.dt) return e;
        if has_poison || has_undef {
            if has_backedge && !orig_const && !ng_is_undef(all_same) && !ng_is_cycle_free(i) return e;
            if is_inst(all_same) && !ng_some_equivalent_dominates(all_same, i) return e;
        }
        if is_inst(all_same) && ng_dfs(all_same) > ng_dfs(i) return e;
        return ng_create_variable_or_constant(all_same);
    }
    return e;
}

// performSymbolicAggrValueEvaluation
ng_perform_symbolic_aggr_value_evaluation :: (i: Value_Id) -> s32 {
    if inst_op(i) == .EXTRACTVALUE {
        wo := op(i, 0);
        idx := inst_indices(i);
        if is_with_overflow_inst(wo) && idx.count == 1 && idx[0] == 0 {
            id := call_iid(wo);
            bop: Opcode = .ADD;
            if id == IID_SSUB_WITH_OVERFLOW || id == IID_USUB_WITH_OVERFLOW bop = .SUB;
            else if id == IID_SMUL_WITH_OVERFLOW || id == IID_UMUL_WITH_OVERFLOW bop = .MUL;
            return ng_create_binary_expression(bop, vtype(i), call_arg(wo, 0), call_arg(wo, 1), i);
        }
    }
    return ng_create_aggregate_value_expression(i);
}

// performSymbolicCmpEvaluation
ng_perform_symbolic_cmp_evaluation :: (i: Value_Id) -> Ng_Result {
    r: Ng_Result;
    ci := i;
    op0 := ng_lookup_operand_leader(op(ci, 0));
    op1 := ng_lookup_operand_leader(op(ci, 1));
    our_pred := inst(ci).pred;
    if ng_should_swap_operands(op0, op1) {
        tmp := op0; op0 = op1; op1 = tmp;
        our_pred = swapped_predicate(inst(ci).pred);
    }
    last_pi: *Pred_Info = null;
    cmp_pi := pi_info_for(ng.pi, i);
    if cmp_pi && pi_is_assume(cmp_pi) {
        r.e = ng_create_constant_expression(const_int(vtype(ci), 1));
        return r;
    }
    if op0 == op1 {
        if cmp_is_true_when_equal(inst(ci).pred) { r.e = ng_create_constant_expression(const_int(vtype(ci), 1)); return r; }
        else if cmp_is_false_when_equal(inst(ci).pred) { r.e = ng_create_constant_expression(const_int(vtype(ci), 0)); return r; }
    }
    for k: 0..cast(u32) 1 {
        pidx := ng_pi_of(op(ci, k));
        if pidx < 0 continue;
        p := *ng.pi.infos[pidx];
        if p.kind != .BRANCH continue;
        if p == last_pi continue;
        last_pi = p;
        if !dt_dominates(ng.dt, p.to, ng_block_of(i)) continue;
        bc := p.condition;
        if !is_inst(bc) || (inst_op(bc) != .ICMP && inst_op(bc) != .FCMP) continue;
        b0 := ng_lookup_operand_leader(op(bc, 0));
        b1 := ng_lookup_operand_leader(op(bc, 1));
        bpred := inst(bc).pred;
        if ng_should_swap_operands(b0, b1) {
            tmp := b0; b0 = b1; b1 = tmp;
            bpred = swapped_predicate(inst(bc).pred);
        }
        if b0 == op0 && b1 == op1 {
            if p.true_edge {
                res := icmp_implied_by_matching_cmp(bpred, false, our_pred, false);
                if res >= 0 {
                    r.e = ng_create_constant_expression(const_int(vtype(ci), cast(u64) res));
                    r.pred = pidx;
                    return r;
                }
            } else {
                if bpred == our_pred {
                    r.e = ng_create_constant_expression(const_int(vtype(ci), 0));
                    r.pred = pidx;
                    return r;
                } else if bpred == cmp_inverse(our_pred) {
                    r.e = ng_create_constant_expression(const_int(vtype(ci), 1));
                    r.pred = pidx;
                    return r;
                }
            }
        }
    }
    return ng_create_expression(i);
}
// PredInfo->getPredicateInfoFor(V) as an index into ng.pi.infos (-1 = none)
ng_pi_of :: (v: Value_Id) -> s32 {
    found, k := table_find(*ng.pi.map, v);
    if found return k;
    return -1;
}

// performSymbolicEvaluation
ng_perform_symbolic_evaluation :: (i: Value_Id) -> Ng_Result {
    r: Ng_Result;
    e: s32 = -1;
    opc := inst_op(i);
    if opc == {
        case .EXTRACTVALUE; #through;
        case .INSERTVALUE;
            e = ng_perform_symbolic_aggr_value_evaluation(i);
        case .PHI;
            ops: [..] Ng_Val_Pair; ops.allocator = temp;
            n := nops(i);
            for k: 0..cast(s64) n - 1 array_add(*ops, .{op(i, cast(u32) k), phi_block(i, cast(u32) k)});
            ng_sort_phi_ops(ops);
            e = ng_perform_symbolic_phi_evaluation(ops, i, ng_block_of(i));
        case .CALL;
            return ng_perform_symbolic_call_evaluation(i);
        case .STORE;
            e = ng_perform_symbolic_store_evaluation(i);
        case .LOAD;
            e = ng_perform_symbolic_load_evaluation(i);
        case .BITCAST;
            if vtype(i) == vtype(op(i, 0)) {
                res := ng_perform_symbolic_predicate_info_evaluation(i);
                if res.e >= 0 return res;
            }
            return ng_create_expression(i);
        case .ADDRSPACECAST; #through;
        case .FREEZE;
            return ng_create_expression(i);
        case .ICMP; #through;
        case .FCMP;
            return ng_perform_symbolic_cmp_evaluation(i);
        case .FNEG; #through; case .ADD; #through; case .FADD; #through; case .SUB; #through; case .FSUB; #through;
        case .MUL; #through; case .FMUL; #through; case .UDIV; #through; case .SDIV; #through; case .FDIV; #through;
        case .UREM; #through; case .SREM; #through; case .FREM; #through; case .SHL; #through; case .LSHR; #through;
        case .ASHR; #through; case .AND; #through; case .OR; #through; case .XOR; #through; case .TRUNC; #through;
        case .ZEXT; #through; case .SEXT; #through; case .FPTOUI; #through; case .FPTOSI; #through;
        case .UITOFP; #through; case .SITOFP; #through; case .FPTRUNC; #through; case .FPEXT; #through;
        case .PTRTOINT; #through; case .PTRTOADDR; #through; case .INTTOPTR; #through; case .SELECT; #through;
        case .EXTRACTELEMENT; #through; case .INSERTELEMENT; #through; case .GEP;
            return ng_create_expression(i);
        case;
            return r;
    }
    r.e = e;
    return r;
}

// sortPHIOps (llvm::sort: insertion sort for the small arrays that occur)
ng_sort_phi_ops :: (ops: [] Ng_Val_Pair) {
    key :: (b: Value_Id) -> u32 {
        found, r := table_find(*ng.block_inst_range, b);
        if found return r[0];
        return 0;
    }
    for i: 1..ops.count - 1 {
        x := ops[i]; kx := key(x.b);
        j := i - 1;
        while j >= 0 && key(ops[j].b) > kx { ops[j + 1] = ops[j]; j -= 1; }
        ops[j + 1] = x;
    }
}

// ---------------------------------------------------------------- touching

// addAdditionalUsers(Value *To, Value *User)
ng_add_additional_users :: (to: Value_Id, user: Value_Id) {
    if !is_inst(to) return;
    p := table_find_pointer(*ng.additional_users, to);
    if !p { blank: Ng_Value_Set; p = table_set(*ng.additional_users, to, blank); }
    ng_vs_insert(p, user);
}
// addAdditionalUsers(ExprResult &Res, Instruction *User)
ng_add_additional_users_result :: (r: *Ng_Result, user: Value_Id) {
    if r.extra != NONE && r.extra != user ng_add_additional_users(r.extra, user);
    r.extra = NONE;
    if r.pred >= 0 {
        p := *ng.pi.infos[r.pred];
        if p.kind == .BRANCH || p.kind == .CONDITION_ASSUME {
            s := table_find_pointer(*ng.predicate_to_users, p.condition);
            if !s { blank: Ng_Value_Set; s = table_set(*ng.predicate_to_users, p.condition, blank); }
            ng_vs_insert(s, user);
        }
    }
    r.pred = -1;
}

// touchAndErase(AdditionalUsers / PredicateToUsers, V)
ng_touch_and_erase_values :: (t: *Table(Value_Id, Ng_Value_Set), v: Value_Id) {
    p := table_find_pointer(t, v);
    if !p return;
    for u: p.list ng_touch(ng_dfs(u));
    table_remove(t, v);
}

// markUsersTouched
ng_mark_users_touched :: (v: Value_Id) {
    u := ir.v_first_use[v];
    while u != NONE {
        user := ir.u_user[u];
        ng_touch(ng_dfs(user));
        u = ir.u_next[u];
    }
    ng_touch_and_erase_values(*ng.additional_users, v);
}

// addMemoryUsers
ng_add_memory_users :: (to: s32, u: s32) {
    p := table_find_pointer(*ng.memory_to_users, to);
    if !p { blank: [..] s32; blank.allocator = temp; p = table_set(*ng.memory_to_users, to, blank); }
    for p.* if it == u return;
    array_add(p, u);
}

ng_mark_memory_def_touched :: (a: s32) { ng_touch(ng_mdfs(a)); }

// markMemoryUsersTouched
ng_mark_memory_users_touched :: (a: s32) {
    if ma_is_use(ng.m, a) return;
    u := ng.m.acc[a].first_use;
    while u >= 0 {
        ng_touch(ng_mdfs(ng.m.uses[u].user));
        u = ng.m.uses[u].next;
    }
    p := table_find_pointer(*ng.memory_to_users, a);
    if p {
        for x: p.* ng_touch(ng_mdfs(x));
        table_remove(*ng.memory_to_users, a);
    }
}

ng_mark_predicate_users_touched :: (i: Value_Id) { ng_touch_and_erase_values(*ng.predicate_to_users, i); }

ng_mark_memory_leader_change_touched :: (cc: s32) {
    for ng_cls(cc).mem_members ng_mark_memory_def_touched(it);
}

ng_mark_value_leader_change_touched :: (cc: s32) {
    for m: ng_cls(cc).members {
        if is_inst(m) ng_touch(ng_dfs(m));
        table_set(*ng.leader_changes, m, true);
    }
}

// ---------------------------------------------------------------- class member sets

ng_member_insert :: (cc: s32, v: Value_Id) {
    c := ng_cls(cc);
    found, pos := table_find(*ng.member_pos, v);
    if found && pos >= 0 && pos < c.members.count && c.members[pos] == v return;
    table_set(*ng.member_pos, v, cast(s32) c.members.count);
    array_add(*c.members, v);
}
ng_member_erase :: (cc: s32, v: Value_Id) {
    c := ng_cls(cc);
    found, pos := table_find(*ng.member_pos, v);
    if !found || pos < 0 || pos >= c.members.count || c.members[pos] != v return;
    last := c.members[c.members.count - 1];
    c.members[pos] = last;
    table_set(*ng.member_pos, last, pos);
    c.members.count -= 1;
    table_set(*ng.member_pos, v, -1);
}
// CC->swap(MembersLeft)
ng_set_members :: (cc: s32, list: [] Value_Id) {
    c := ng_cls(cc);
    for c.members table_set(*ng.member_pos, it, -1);
    c.members.count = 0;
    for list {
        table_set(*ng.member_pos, it, cast(s32) c.members.count);
        array_add(*c.members, it);
    }
}
ng_mem_member_insert :: (cc: s32, a: s32) {
    c := ng_cls(cc);
    found, pos := table_find(*ng.mphi_pos, a);
    if found && pos >= 0 && pos < c.mem_members.count && c.mem_members[pos] == a return;
    table_set(*ng.mphi_pos, a, cast(s32) c.mem_members.count);
    array_add(*c.mem_members, a);
}
ng_mem_member_erase :: (cc: s32, a: s32) {
    c := ng_cls(cc);
    found, pos := table_find(*ng.mphi_pos, a);
    if !found || pos < 0 || pos >= c.mem_members.count || c.mem_members[pos] != a return;
    last := c.mem_members[c.mem_members.count - 1];
    c.mem_members[pos] = last;
    table_set(*ng.mphi_pos, last, pos);
    c.mem_members.count -= 1;
    table_set(*ng.mphi_pos, a, -1);
}
ng_defines_no_memory :: (cc: s32) -> bool { c := ng_cls(cc); return c.store_count == 0 && c.mem_members.count == 0; }

// createCongruenceClass
ng_create_class :: (leader: Value_Id, e: s32) -> s32 {
    leader_dfs: u32 = 0;
    if leader == NONE leader_dfs = 0xFFFF_FFFF;
    else if is_inst(leader) leader_dfs = ng_dfs(leader);
    c: Ng_Class;
    c.id = cast(u32) ng.classes.count;
    c.leader = leader; c.leader_dfs = leader_dfs;
    c.def_expr = e;
    c.members.allocator = temp; c.mem_members.allocator = temp;
    array_add(*ng.classes, c);
    return cast(s32) (ng.classes.count - 1);
}
ng_create_memory_class :: (a: s32) -> s32 {
    cc := ng_create_class(NONE, -1);
    ng_cls(cc).mem_leader = a;
    return cc;
}
ng_ensure_leader_of_memory_class :: (a: s32) -> s32 {
    cc := ng_memory_class(a);
    if ng_cls(cc).mem_leader != a cc = ng_create_memory_class(a);
    return cc;
}
ng_create_singleton_class :: (v: Value_Id) -> s32 {
    cc := ng_create_class(v, -1);
    ng_member_insert(cc, v);
    table_set(*ng.value_to_class, v, cc);
    return cc;
}
// addPossibleLeader
ng_add_possible_leader :: (cc: s32, v: Value_Id, dfs: u32) -> bool {
    c := ng_cls(cc);
    if dfs < c.leader_dfs {
        c.next_leader = c.leader; c.next_leader_dfs = c.leader_dfs;
        c.leader = v; c.leader_dfs = dfs;
        return true;
    } else if dfs < c.next_leader_dfs {
        c.next_leader = v; c.next_leader_dfs = dfs;
    }
    return false;
}
ng_reset_next_leader :: (cc: s32) { c := ng_cls(cc); c.next_leader = NONE; c.next_leader_dfs = 0xFFFF_FFFF; }

// getNextMemoryLeader
ng_get_next_memory_leader :: (cc: s32) -> s32 {
    c := ng_cls(cc);
    if c.store_count > 0 {
        nl := c.next_leader;
        if nl != NONE && is_inst(nl) && inst_op(nl) == .STORE return ng_memory_access(nl);
        best: Value_Id = NONE; best_dfs: u32 = 0xFFFF_FFFF;
        for v: c.members {
            if !(is_inst(v) && inst_op(v) == .STORE) continue;
            d := ng_dfs(v);
            if d < best_dfs { best = v; best_dfs = d; }
        }
        return ng_memory_access(best);
    }
    if c.mem_members.count == 1 return c.mem_members[0];
    best: s32 = -1; best_dfs: u32 = 0xFFFF_FFFF;
    for a: c.mem_members {
        d := ng_mdfs(a);
        if d < best_dfs { best = a; best_dfs = d; }
    }
    return best;
}

// getNextValueLeader
ng_get_next_value_leader :: (cc: s32) -> Value_Id {
    c := ng_cls(cc);
    if c.members.count == 1 || cc == ng.top return c.members[0];
    if c.next_leader != NONE return c.next_leader;
    best: Value_Id = NONE; best_dfs: u32 = 0xFFFF_FFFF;
    for v: c.members {
        d := ng_dfs(v);
        if d < best_dfs { best = v; best_dfs = d; }
    }
    return best;
}

// moveMemoryToNewCongruenceClass
ng_move_memory_to_new_class :: (i: Value_Id, inst_ma: s32, old_class: s32, new_class: s32) {
    if ng_cls(new_class).mem_leader < 0 {
        ng_cls(new_class).mem_leader = inst_ma;
        ng_mark_memory_leader_change_touched(new_class);
    }
    ng_set_memory_class(inst_ma, new_class);
    if ng_cls(old_class).mem_leader == inst_ma {
        if !ng_defines_no_memory(old_class) {
            ng_cls(old_class).mem_leader = ng_get_next_memory_leader(old_class);
            ng_mark_memory_leader_change_touched(old_class);
        } else {
            ng_cls(old_class).mem_leader = -1;
        }
    }
}

// moveValueToNewCongruenceClass
ng_move_value_to_new_class :: (i: Value_Id, e: s32, old_class: s32, new_class: s32) {
    if i == ng_cls(old_class).next_leader ng_reset_next_leader(old_class);
    ng_member_erase(old_class, i);
    ng_member_insert(new_class, i);
    if ng_cls(new_class).leader != i && ng_add_possible_leader(new_class, i, ng_dfs(i)) ng_mark_value_leader_change_touched(new_class);
    if inst_op(i) == .STORE {
        ng_cls(old_class).store_count -= 1;
        nc := ng_cls(new_class);
        if nc.store_count == 0 && nc.stored == NONE {
            if ng_expr(e).et == .STORE {
                nc.stored = ng_expr(e).stored;
                ng_mark_value_leader_change_touched(new_class);
                nc = ng_cls(new_class);
                nc.leader = i; nc.leader_dfs = ng_dfs(i);
            }
        }
        ng_cls(new_class).store_count += 1;
    }
    ima := ng_memory_access(i);
    if ima >= 0 && ma_is_def(ng.m, ima) ng_move_memory_to_new_class(i, ima, old_class, new_class);
    table_set(*ng.value_to_class, i, new_class);
    oc := ng_cls(old_class);
    if oc.members.count == 0 && old_class != ng.top {
        if oc.def_expr >= 0 {
            k := ng_emap_find(*ng.expr_to_class, oc.def_expr, exact = true);
            if k >= 0 ng_emap_erase(*ng.expr_to_class, k);
        }
    } else if oc.leader == i {
        if oc.store_count == 0 {
            if oc.stored != NONE oc.stored = NONE;
        }
        nl := ng_get_next_value_leader(old_class);
        oc = ng_cls(old_class);
        oc.leader = nl; oc.leader_dfs = ng_dfs(nl);
        ng_reset_next_leader(old_class);
        ng_mark_value_leader_change_touched(old_class);
    }
}

// markPhiOfOpsChanged
ng_mark_phi_of_ops_changed :: (e: s32) {
    k := ng_emap_find(*ng.expr_to_phi_of_ops, e);
    if k < 0 return;
    for u: ng.expr_to_phi_of_ops.ents[k].users ng_touch(ng_dfs(u));
    ng_emap_erase(*ng.expr_to_phi_of_ops, k);
}

// performCongruenceFinding
ng_perform_congruence_finding :: (i: Value_Id, e: s32) {
    iclass := ng_class_of(i);
    if iclass < 0 fatal("newgvn: internal: should have found a class");
    eclass: s32 = -1;
    x := ng_expr(e);
    if x.et == .VARIABLE {
        eclass = ng_class_of(x.val);
    } else if x.et == .DEAD {
        eclass = ng.top;
    }
    if eclass < 0 {
        k := ng_emap_find(*ng.expr_to_class, e);
        if k < 0 {
            k = ng_emap_insert(*ng.expr_to_class, e);
            nc := ng_create_class(NONE, e);
            ng.expr_to_class.ents[k].cls = nc;
            x = ng_expr(e);
            if x.et == .CONSTANT {
                ng_cls(nc).leader = x.val; ng_cls(nc).leader_dfs = 0;
            } else if x.et == .STORE {
                si := x.inst;
                ng_cls(nc).leader = si; ng_cls(nc).leader_dfs = ng_dfs(si);
                ng_cls(nc).stored = x.stored;
            } else {
                ng_cls(nc).leader = i; ng_cls(nc).leader_dfs = ng_dfs(i);
            }
            eclass = nc;
        } else {
            eclass = ng.expr_to_class.ents[k].cls;
        }
    }
    class_changed := iclass != eclass;
    if ng_opts.trace print_stderr("  class % -> % (leader %) expr et=% val=%\n", iclass, eclass, ifx ng_cls(eclass).leader != NONE then value_as_operand(ng_cls(eclass).leader) else "null", ng_expr(e).et, ifx ng_expr(e).val != NONE then value_as_operand(ng_expr(e).val) else "");
    leader_changed := table_contains(*ng.leader_changes, i);
    if leader_changed table_remove(*ng.leader_changes, i);
    if class_changed || leader_changed {
        if class_changed {
            ng_move_value_to_new_class(i, e, iclass, eclass);
            ng_mark_phi_of_ops_changed(e);
        }
        ng_mark_users_touched(i);
        a := ng_memory_access(i);
        if a >= 0 ng_mark_memory_users_touched(a);
        if inst_op(i) == .ICMP || inst_op(i) == .FCMP ng_mark_predicate_users_touched(i);
    }
    if class_changed && inst_op(i) == .STORE {
        found, old_e := table_find(*ng.value_to_expr, i);
        if found && ng_expr(old_e).et == .STORE && !ng_expr_eq(e, old_e) {
            k := ng_emap_find(*ng.expr_to_class, old_e, exact = true);
            if k >= 0 ng_emap_erase(*ng.expr_to_class, k);
        }
    }
    table_set(*ng.value_to_expr, i, e);
}

// ---------------------------------------------------------------- reachability

// updateReachableEdge
ng_update_reachable_edge :: (from: Value_Id, to: Value_Id) {
    key := ng_edge_key(from, to);
    if table_contains(*ng.reachable_edges, key) return;
    table_set(*ng.reachable_edges, key, true);
    array_add(*ng.reachable_edge_list, key);
    if !ng_block_reachable(to) {
        table_set(*ng.reachable_blocks, to, true);
        found, r := table_find(*ng.block_inst_range, to);
        if found ng_touch_range(r[0], r[1]);
    } else {
        mp := ng_memory_phi(to);
        if mp >= 0 ng_touch(ng_mdfs(mp));
        s := ng_revisit(to);
        for s.bits ng_touch(it);
    }
}

// findConditionEquivalence
ng_find_condition_equivalence :: (cond: Value_Id) -> Value_Id {
    r := ng_lookup_operand_leader(cond);
    if is_const(r) return r;
    return NONE;
}

// processOutgoingEdges
ng_process_outgoing_edges :: (ti: Value_Id, b: Value_Id) {
    opc := inst_op(ti);
    if opc == .CONDBR {
        cond := op(ti, 0);
        true_succ := get_successor(ti, 0);
        false_succ := get_successor(ti, 1);
        cond_eval := ng_find_condition_equivalence(cond);
        if cond_eval == NONE {
            if is_inst(cond) {
                res := ng_perform_symbolic_evaluation(cond);
                if res.e >= 0 && ng_expr(res.e).et == .CONSTANT {
                    cond_eval = ng_expr(res.e).val;
                    ng_add_additional_users_result(*res, cond);
                } else {
                    res.extra = NONE;
                }
            } else if vkind(cond) == .C_INT {
                cond_eval = cond;
            }
        }
        if cond_eval != NONE && vkind(cond_eval) == .C_INT {
            if const_int_zext(cond_eval) == 1 {
                ng_update_reachable_edge(b, true_succ);
            } else if is_null_value(cond_eval) {
                ng_update_reachable_edge(b, false_succ);
            }
        } else {
            ng_update_reachable_edge(b, true_succ);
            ng_update_reachable_edge(b, false_succ);
        }
    } else if opc == .SWITCH {
        cond := op(ti, 0);
        cond_eval := ng_find_condition_equivalence(cond);
        if cond_eval != NONE && vkind(cond_eval) == .C_INT {
            k := sw_find_case_value(ti, cond_eval);
            if k < 0 {
                ng_update_reachable_edge(b, sw_default(ti));
                return;
            }
            ng_update_reachable_edge(b, sw_case_dest(ti, cast(u32) k));
        } else {
            succs: [..] Value_Id; succs.allocator = temp;
            block_successors(inst_block(ti), *succs);
            for succs ng_update_reachable_edge(b, it);
        }
    } else {
        succs: [..] Value_Id; succs.allocator = temp;
        block_successors(inst_block(ti), *succs);
        for succs ng_update_reachable_edge(b, it);
        a := ng_memory_access(ti);
        if a >= 0 && !ma_is_use(ng.m, a) {
            cc := ng_ensure_leader_of_memory_class(a);
            if ng_set_memory_class(a, cc) ng_mark_memory_users_touched(a);
        }
    }
}

// ---------------------------------------------------------------- phi of ops

// removePhiOfOps
ng_remove_phi_of_ops :: (i: Value_Id, phi_temp: Value_Id) {
    table_remove(*ng.instr_dfs, phi_temp);
    table_remove(*ng.temp_to_block, phi_temp);
    table_remove(*ng.real_to_temp, i);
}

// addPhiOfOps
ng_add_phi_of_ops :: (pn: Value_Id, bb: Value_Id, existing: Value_Id) {
    table_set(*ng.instr_dfs, pn, ng_dfs(existing));
    table_set(*ng.all_temps, pn, true);
    table_set(*ng.temp_to_block, pn, bb);
    table_set(*ng.real_to_temp, existing, pn);
    u := ir.v_first_use[existing];
    while u != NONE {
        user := ir.u_user[u];
        if is_inst(user) table_set(*ng.phi_node_uses, user, true);
        u = ir.u_next[u];
    }
}

ng_okay_for_phi_of_ops :: (i: Value_Id) -> bool {
    if !ng_opts.enable_phi_of_ops return false;
    o := inst_op(i);
    return is_binary_op(o) || o == .SELECT || o == .ICMP || o == .FCMP || o == .LOAD;
}

// OpIsSafeForPHIOfOps
ng_op_is_safe_for_phi_of_ops :: (v: Value_Id, phi_bb: Value_Id, visited: *Table(Value_Id, bool)) -> bool {
    key :: (v: Value_Id) -> u64 { return ((cast(u64) v) << 32) | cast(u64) ng.cache_idx; }
    insert :: (v: Value_Id, b: bool) { if !table_contains(*ng.op_safe, key(v)) table_set(*ng.op_safe, key(v), b); }
    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add(*worklist, v);
    while worklist.count {
        i := pop(*worklist);
        if !is_inst(i) continue;
        found, cached := table_find(*ng.op_safe, key(i));
        if found return cached;
        if dt_properly_dominates(ng.dt, ng_block_of(i), phi_bb) {
            insert(i, true);
            continue;
        }
        if is_phi(i) && ng_block_of(i) == phi_bb {
            insert(i, false);
            return false;
        }
        if may_read_from_memory(i) return false;
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            o := op(i, cast(u32) k);
            if !is_inst(o) continue;
            f2, c2 := table_find(*ng.op_safe, key(i));
            if f2 {
                if !c2 { insert(i, false); return false; }
                continue;
            }
            if table_contains(visited, o) continue;
            table_set(visited, o, true);
            array_add(*worklist, o);
        }
    }
    insert(v, true);
    return true;
}

// findLeaderForInst
ng_find_leader_for_inst :: (trans: Value_Id, mem_access: s32, orig: Value_Id, pred_bb: Value_Id) -> Value_Id {
    idfs := ng_dfs(orig);
    table_set(*ng.all_temps, trans, true);
    if !table_contains(*ng.temp_to_block, trans) table_set(*ng.temp_to_block, trans, pred_bb);
    if !table_contains(*ng.instr_dfs, trans) table_set(*ng.instr_dfs, trans, idfs);
    res := ng_perform_symbolic_evaluation(trans);
    e := res.e;
    ng_add_additional_users_result(*res, orig);
    table_remove(*ng.instr_dfs, trans);
    table_remove(*ng.all_temps, trans);
    table_remove(*ng.temp_to_block, trans);
    if mem_access >= 0 table_remove(*ng.temp_to_memory, trans);
    if e < 0 return NONE;
    found_val := ng_find_phi_of_ops_leader(e, orig, pred_bb);
    if found_val == NONE {
        k := ng_emap_find(*ng.expr_to_phi_of_ops, e);
        if k < 0 k = ng_emap_insert(*ng.expr_to_phi_of_ops, e);
        ent := *ng.expr_to_phi_of_ops.ents[k];
        exists := false;
        for ent.users if it == orig { exists = true; break; }
        if !exists array_add(*ent.users, orig);
        return NONE;
    }
    if is_inst(found_val) && inst_op(found_val) == .STORE found_val = op(found_val, 0);
    return found_val;
}

// makePossiblePHIOfOps
ng_make_possible_phi_of_ops :: (i: Value_Id, visited: *Table(Value_Id, bool)) -> s32 {
    if !ng_okay_for_phi_of_ops(i) return -1;
    if table_contains(visited, i) return -1;
    table_set(visited, i, true);
    if !ng_is_cycle_free(i) return -1;
    mem_access := ng_memory_access(i);
    if mem_access >= 0 {
        d := ma_defining(ng.m, mem_access);
        if !ma_is_phi(ng.m, d) && ma_block(ng.m, d) == inst_block(i) return -1;
    }
    visited_ops: Table(Value_Id, bool); visited_ops.allocator = temp;
    same_phi_block: Value_Id = NONE;
    op_phi: Value_Id = NONE;
    n := nops(i);
    for k: 0..cast(s64) n - 1 {
        o := op(i, cast(u32) k);
        if !is_phi(o) {
            found, vp := table_find(*ng.real_to_temp, o);
            if !found continue;
            o = vp;
        }
        op_phi = o;
        if same_phi_block == NONE {
            same_phi_block = ng_block_of(op_phi);
        } else if same_phi_block != ng_block_of(op_phi) {
            return -1;
        }
        if nops(op_phi) == 1 return -1;
    }
    if op_phi == NONE return -1;

    phi_ops: [..] Ng_Val_Pair; phi_ops.allocator = temp;
    deps: Ng_Value_Set;
    phi_bb := ng_block_of(op_phi);
    ng_sbv_reset(ng_revisit(phi_bb), ng_dfs(i));
    np := nops(op_phi);
    for pred_num: 0..cast(s64) np - 1 {
        pred_bb := phi_block(op_phi, cast(u32) pred_num);
        found_val: Value_Id = NONE;
        current_deps: Ng_Value_Set;
        if ng_edge_reachable(pred_bb, phi_bb) {
            value_op := ic_clone_inst(i);
            inst_insert_before(value_op, block_terminator(pred_bb));
            if mem_access >= 0 && !table_contains(*ng.temp_to_memory, value_op) table_set(*ng.temp_to_memory, value_op, mem_access);
            safe := true;
            table_reset(*visited_ops);
            nv := nops(value_op);
            for k: 0..cast(s64) nv - 1 {
                orig_op := op(value_op, cast(u32) k);
                cur := orig_op;
                if is_phi(cur) {
                    cur = do_phi_translation(cur, phi_bb, pred_bb);
                    set_op(value_op, cast(u32) k, cur);
                    if cur != orig_op && cur != i ng_vs_insert(*current_deps, cur);
                } else {
                    found, vp := table_find(*ng.real_to_temp, cur);
                    if found {
                        if ng_block_of(vp) == phi_bb {
                            cur = phi_incoming_for_block(vp, pred_bb);
                            set_op(value_op, cast(u32) k, cur);
                        }
                    }
                }
                safe = safe && (cur != orig_op || ng_op_is_safe_for_phi_of_ops(cur, phi_bb, *visited_ops));
            }
            found_val = ifx !safe then NONE else ng_find_leader_for_inst(value_op, mem_access, i, pred_bb);
            erase_inst_temp(value_op);
            if found_val == NONE {
                if safe for current_deps.list ng_add_additional_users(it, i);
                return -1;
            }
            for current_deps.list ng_vs_insert(*deps, it);
        } else {
            found_val = const_poison(vtype(i));
            ng_sbv_set(ng_revisit(phi_bb), ng_dfs(i));
        }
        array_add(*phi_ops, .{found_val, pred_bb});
    }
    for deps.list ng_add_additional_users(it, i);
    ng_sort_phi_ops(phi_ops);
    e := ng_perform_symbolic_phi_evaluation(phi_ops, i, phi_bb);
    et := ng_expr(e).et;
    if et == .CONSTANT || et == .VARIABLE {
        for phi_ops if is_inst(it.v) ng_add_additional_users(it.v, i);
        return e;
    }
    found, value_phi := table_find(*ng.real_to_temp, i);
    new_phi := false;
    if !found {
        value_phi = create_phi(vtype(i), cast(u32) nops(op_phi));
        set_name(value_phi, "phiofops");
        ng_add_phi_of_ops(value_phi, phi_bb, i);
        new_phi = true;
    }
    if new_phi {
        for phi_ops phi_add_incoming(value_phi, it.v, it.b);
    } else {
        table_set(*ng.temp_to_block, value_phi, phi_bb);
        if phi_ops.count > nops(value_phi) fatal("newgvn: internal: phi of ops with a changed operand count");
        for phi_ops {
            phi_set_value(value_phi, cast(u32) it_index, it.v);
            phi_set_block(value_phi, cast(u32) it_index, it.b);
        }
    }
    ng_sbv_set(ng_revisit(phi_bb), ng_dfs(i));
    return e;
}

// Instruction::eraseFromParent of a temporary (no metadata uses)
erase_inst_temp :: (i: Value_Id) {
    drop_all_references(i);
    erase_inst(i);
}

// ---------------------------------------------------------------- initialization

// initializeCongruenceClasses
ng_initialize_classes :: (dt_order: [] Value_Id) {
    ng.top = ng_create_class(NONE, -1);
    ng_cls(ng.top).mem_leader = MSSA_LIVE_ON_ENTRY;
    table_set(*ng.memory_to_class, MSSA_LIVE_ON_ENTRY, ng_create_memory_class(MSSA_LIVE_ON_ENTRY));
    for bb: dt_order {
        lst := mssa_block(ng.m, bb);
        if lst {
            a := lst.dfirst;
            while a >= 0 {
                table_set(*ng.memory_to_class, a, ng.top);
                if ma_is_phi(ng.m, a) {
                    ng_mem_member_insert(ng.top, a);
                    if !table_contains(*ng.mphi_state, a) table_set(*ng.mphi_state, a, NG_MPS_TOP);
                } else {
                    mi := ma_inst(ng.m, a);
                    if mi != NONE && inst_op(mi) == .STORE ng_cls(ng.top).store_count += 1;
                }
                a = ng.m.acc[a].dnext;
            }
        }
        for i: block_insts(bb) {
            if inst_op(i) == .PHI {
                u := ir.v_first_use[i];
                while u != NONE {
                    user := ir.u_user[u];
                    if is_inst(user) && ng_dfs(user) != 0 && ng_okay_for_phi_of_ops(user) table_set(*ng.phi_node_uses, user, true);
                    u = ir.u_next[u];
                }
            }
            if is_terminator(inst_op(i)) && vtype(i) == ir.t_void continue;
            ng_member_insert(ng.top, i);
            table_set(*ng.value_to_class, i, ng.top);
        }
    }
    n := func_nparams(glob(ng.f).value_type);
    for k: 0..cast(s64) n - 1 ng_create_singleton_class(fn_arg(ng.f, cast(u32) k));
}

// assignDFSNumbers
ng_assign_dfs_numbers :: (b: Value_Id, start: u32) -> [2] u32 {
    e := start;
    mp := ng_memory_phi(b);
    if mp >= 0 {
        table_set(*ng.mphi_dfs, mp, e);
        e += 1;
        array_add(*ng.dfs_to_instr, .{NONE, mp});
    }
    for i: block_insts(b) {
        if is_instruction_trivially_dead(i) {
            table_set(*ng.instr_dfs, i, 0);
            salvage_debug_info(i);
            ng_mark_instruction_for_deletion(i);
            continue;
        }
        if inst_op(i) == .PHI ng_sbv_set(ng_revisit(b), e);
        table_set(*ng.instr_dfs, i, e);
        e += 1;
        array_add(*ng.dfs_to_instr, .{i, -1});
    }
    return .[start, e];
}

// valueNumberMemoryPhi
ng_value_number_memory_phi :: (mp: s32) {
    phi_bb := ma_block(ng.m, mp);
    filtered: [..] s32; filtered.allocator = temp;
    n := ma_nops(ng.m, mp);
    for k: 0..cast(s64) n - 1 {
        a := mphi_value(ng.m, mp, cast(u32) k);
        if a == mp continue;
        if ng_is_memory_access_top(a) continue;
        if !ng_edge_reachable(mphi_block(ng.m, mp, cast(u32) k), phi_bb) continue;
        array_add(*filtered, a);
    }
    if filtered.count == 0 {
        if ng_set_memory_class(mp, ng.top) ng_mark_memory_users_touched(mp);
        return;
    }
    all_same := ng_lookup_memory_leader(filtered[0]);
    all_equal := true;
    for k: 1..filtered.count - 1 if ng_lookup_memory_leader(filtered[k]) != all_same { all_equal = false; break; }
    cc := ifx all_equal then ng_memory_class(all_same) else ng_ensure_leader_of_memory_class(mp);
    found, old_state := table_find(*ng.mphi_state, mp);
    if !found old_state = NG_MPS_INVALID;
    new_state := ifx all_equal then NG_MPS_EQUIVALENT else NG_MPS_UNIQUE;
    table_set(*ng.mphi_state, mp, new_state);
    if ng_set_memory_class(mp, cc) || old_state != new_state ng_mark_memory_users_touched(mp);
}

// valueNumberInstruction
ng_value_number_instruction :: (i: Value_Id) {
    if ng_opts.trace print_stderr("Processing instruction %\n", inst_to_string(i));
    if !is_terminator(inst_op(i)) {
        symbolized: s32 = -1;
        visited: Table(Value_Id, bool); visited.allocator = temp;
        res := ng_perform_symbolic_evaluation(i);
        symbolized = res.e;
        ng_add_additional_users_result(*res, i);
        if symbolized >= 0 && ng_expr(symbolized).et != .CONSTANT && ng_expr(symbolized).et != .VARIABLE && table_contains(*ng.phi_node_uses, i) {
            phie := ng_make_possible_phi_of_ops(i, *visited);
            if phie >= 0 {
                symbolized = phie;
            } else {
                found, o := table_find(*ng.real_to_temp, i);
                if found ng_remove_phi_of_ops(i, o);
            }
        }
        if symbolized < 0 symbolized = ng_create_unknown_expression(i);
        ng_perform_congruence_finding(i, symbolized);
    } else {
        if vtype(i) != ir.t_void {
            s := ng_create_unknown_expression(i);
            ng_perform_congruence_finding(i, s);
        }
        ng_process_outgoing_edges(i, inst_block(i));
    }
}

// iterateTouchedInstructions
ng_iterate_touched_instructions :: () {
    first := ng_find_set(0);
    if first == -1 return;
    last_block := ng_item_block(ng.dfs_to_instr[first]);
    while ng_any_touched() {
        n := ng_find_set(0);
        while n != -1 {
            num := cast(u32) n;
            if num == 0 {
                ng_untouch(num);
                n = ng_find_set(n + 1);
                continue;
            }
            item := ng.dfs_to_instr[num];
            cur_block := ng_item_block(item);
            skip := false;
            if cur_block != last_block {
                last_block = cur_block;
                found, r := table_find(*ng.block_inst_range, cur_block);
                if !ng_block_reachable(cur_block) {
                    ng_untouch_range(r[0], r[1]);
                    skip = true;
                } else {
                    ng.cache_idx = ng_rpo(cur_block) - 1;
                }
            }
            if !skip {
                ng_untouch(num);
                if item.mp >= 0 ng_value_number_memory_phi(item.mp);
                else ng_value_number_instruction(item.v);
            }
            n = ng_find_set(n + 1);
        }
    }
}

// ---------------------------------------------------------------- elimination

Ng_Value_Dfs :: struct {
    dfs_in: s32;
    dfs_out: s32;
    local_num: s32;
    def: Value_Id = NONE;
    def_from_store: bool;
    u: Use_Id = NONE;
}
ng_vdfs_less :: (a: *Ng_Value_Dfs, b: *Ng_Value_Dfs) -> bool {
    if a.dfs_in != b.dfs_in return a.dfs_in < b.dfs_in;
    if a.dfs_out != b.dfs_out return a.dfs_out < b.dfs_out;
    if a.local_num != b.local_num return a.local_num < b.local_num;
    // PointerIntPair<Value *, 1, bool>: null (uses) first; then the pointer (value id), then the bit
    ad: s64 = ifx a.def == NONE then -1 else cast(s64) a.def;
    bd: s64 = ifx b.def == NONE then -1 else cast(s64) b.def;
    if ad != bd return ad < bd;
    if a.def_from_store != b.def_from_store return !a.def_from_store;
    au: s64 = ifx a.u == NONE then -1 else cast(s64) a.u;
    bu: s64 = ifx b.u == NONE then -1 else cast(s64) b.u;
    return au < bu;
}
ng_sort_vdfs :: (a: *[..] Ng_Value_Dfs) {
    // merge sort (the keys are unique, so any correct sort gives LLVM's order)
    n := a.count;
    if n < 2 return;
    tmp := NewArray(n, Ng_Value_Dfs,, allocator = temp);
    width := 1;
    src := a.data; dst := tmp.data;
    while width < n {
        i := 0;
        while i < n {
            mid := min(i + width, n); hi := min(i + 2 * width, n);
            l := i; r := mid; k := i;
            while l < mid && r < hi {
                if ng_vdfs_less(*src[r], *src[l]) { dst[k] = src[r]; r += 1; }
                else { dst[k] = src[l]; l += 1; }
                k += 1;
            }
            while l < mid { dst[k] = src[l]; l += 1; k += 1; }
            while r < hi { dst[k] = src[r]; r += 1; k += 1; }
            i += 2 * width;
        }
        t := src; src = dst; dst = t;
        width *= 2;
    }
    if src != a.data memcpy(a.data, src, n * size_of(Ng_Value_Dfs));
}

ng_node_dfs :: (b: Value_Id) -> (s32, s32) {
    nd := dt_node(ng.dt, b);
    return cast(s32) ng.dt.nodes[nd].dfs_in, cast(s32) ng.dt.nodes[nd].dfs_out;
}

// convertClassToDFSOrdered
ng_convert_class_to_dfs_ordered :: (cc: s32, out: *[..] Ng_Value_Dfs, use_counts: *Table(Value_Id, u32), probably_dead: *Ng_Value_Set) {
    instr_dfs_size := cast(s32) (ng.instr_dfs.count + ng.mphi_dfs.count);
    for d: ng_cls(cc).members {
        bb := ng_block_of(d);
        vd: Ng_Value_Dfs;
        vd.dfs_in, vd.dfs_out = ng_node_dfs(bb);
        if inst_op(d) == .STORE {
            leader := ng_lookup_operand_leader(op(d, 0));
            if ng_always_available(leader) {
                vd.def = leader;
            } else {
                vd.def = op(d, 0);
                vd.def_from_store = true;
            }
        } else {
            vd.def = d;
        }
        vd.local_num = cast(s32) ng_dfs(d);
        array_add(out, vd);
        found, pn := table_find(*ng.real_to_temp, d);
        if found {
            f2, ve := table_find(*ng.value_to_expr, d);
            if f2 && ng_expr(ve).et == .PHI {
                vd.def_from_store = false;
                vd.def = pn;
                vd.local_num = 0;
                array_add(out, vd);
            }
        }
        use_count: u32 = 0;
        u := ir.v_first_use[d];
        while u != NONE {
            user := ir.u_user[u];
            nu := ir.u_next[u];
            if is_inst(user) {
                if !ng_vs_contains(*ng.to_erase, user) {
                    vu: Ng_Value_Dfs;
                    iblock: Value_Id;
                    if inst_op(user) == .PHI {
                        k := u - ir.v_ops[user];
                        iblock = phi_block(user, k);
                        vu.local_num = instr_dfs_size + 1;
                    } else {
                        iblock = ng_block_of(user);
                        vu.local_num = cast(s32) ng_dfs(user);
                    }
                    if ng_block_reachable(iblock) {
                        vu.dfs_in, vu.dfs_out = ng_node_dfs(iblock);
                        vu.u = u;
                        use_count += 1;
                        array_add(out, vu);
                    }
                }
            }
            u = nu;
        }
        if use_count == 0 ng_vs_insert(probably_dead, d);
        else table_set(use_counts, d, use_count);
    }
}

// convertClassToLoadsAndStores
ng_convert_class_to_loads_and_stores :: (cc: s32, out: *[..] Ng_Value_Dfs) {
    for d: ng_cls(cc).members {
        if !(inst_op(d) == .LOAD || inst_op(d) == .STORE) continue;
        vd: Ng_Value_Dfs;
        vd.dfs_in, vd.dfs_out = ng_node_dfs(ng_block_of(d));
        vd.def = d;
        vd.local_num = cast(s32) ng_dfs(d);
        array_add(out, vd);
    }
}

ng_mark_instruction_for_deletion :: (i: Value_Id) { ng_vs_insert(*ng.to_erase, i); }

// replaceInstruction (patchAndReplaceAllUsesWith)
ng_replace_instruction :: (i: Value_Id, v: Value_Id) {
    patch_replacement_instruction(i, v);
    rauw_with_metadata(i, v);
    ng_mark_instruction_for_deletion(i);
}

// deleteInstructionsInBlock
ng_delete_instructions_in_block :: (bb: Value_Id) {
    term := block_terminator(bb);
    x := ifx term != NONE then inst(term).prev else block(bb).last;
    while x != NONE {
        prev := inst(x).prev;
        if has_uses(x) rauw_with_metadata(x, const_poison(vtype(x)));
        if inst_op(x) == .LANDINGPAD { x = prev; continue; }
        salvage_knowledge(x, ng.ac);
        erase_inst_with_metadata(x);
        x = prev;
    }
    ns := new_inst(.STORE, ir.t_void, 2);
    set_op(ns, 0, const_poison(ir.t_i8));
    set_op(ns, 1, const_null_value(type_ptr(0)));
    inst(ns).align = 1;
    insert_at_position(ns, bb, block_terminator(bb), false);
}

// ValueDFSStack
Ng_Stack :: struct { vals: [..] Value_Id; dfs: [..] [2] s32; }
ng_stack_in_scope :: (s: *Ng_Stack, a: s32, b: s32) -> bool {
    if s.dfs.count == 0 return false;
    t := s.dfs[s.dfs.count - 1];
    return a >= t[0] && b <= t[1];
}
ng_stack_pop_until :: (s: *Ng_Stack, a: s32, b: s32) {
    while s.dfs.count {
        t := s.dfs[s.dfs.count - 1];
        if a >= t[0] && b <= t[1] break;
        s.dfs.count -= 1; s.vals.count -= 1;
    }
}
ng_stack_push :: (s: *Ng_Stack, v: Value_Id, a: s32, b: s32) { array_add(*s.vals, v); array_add(*s.dfs, .[a, b]); }

// getClassForExpression
ng_class_for_expression :: (e: s32) -> s32 {
    x := ng_expr(e);
    if x.et == .VARIABLE return ng_class_of(x.val);
    if x.et == .DEAD return ng.top;
    return ng_emap_lookup_class(*ng.expr_to_class, e);
}

// findPHIOfOpsLeader
ng_find_phi_of_ops_leader :: (e: s32, orig: Value_Id, bb: Value_Id) -> Value_Id {
    x := ng_expr(e);
    if x.et == .CONSTANT return x.val;
    if x.et == .VARIABLE {
        v := x.val;
        if ng_always_available(v) || dt_dominates(ng.dt, ng_block_of(v), bb) return v;
    }
    cc := ng_class_for_expression(e);
    if cc < 0 return NONE;
    c := ng_cls(cc);
    if ng_always_available(c.leader) return c.leader;
    for m: c.members {
        if !is_inst(m) return m;
        if m == orig continue;
        if dt_dominates(ng.dt, ng_block_of(m), bb) return m;
    }
    return NONE;
}

// eliminateInstructions
ng_eliminate_instructions :: () -> bool {
    anything_replaced := false;
    dt_update_dfs_numbers(ng.dt);

    reachable_pred_count: Table(Value_Id, u32); reachable_pred_count.allocator = temp;
    for key: ng.reachable_edge_list {
        to := cast(Value_Id) (key & 0xFFFF_FFFF);
        p := table_find_pointer(*reachable_pred_count, to);
        if p p.* += 1; else table_set(*reachable_pred_count, to, 1);
    }
    for bb: ng.revisit_order {
        s := table_find_pointer(*ng.revisit, bb);
        for num: s.bits {
            item := ng.dfs_to_instr[num];
            phi: Value_Id = NONE;
            if item.mp < 0 {
                if is_phi(item.v) phi = item.v;
                else {
                    found, t := table_find(*ng.real_to_temp, item.v);
                    if found && is_phi(t) phi = t;
                }
            }
            if phi == NONE continue;
            found, cnt := table_find(*reachable_pred_count, bb);
            if !found cnt = 0;
            if cnt != nops(phi) {
                n := nops(phi);
                for k: 0..cast(s64) n - 1 {
                    if !ng_edge_reachable(phi_block(phi, cast(u32) k), bb) set_op(phi, cast(u32) k, const_poison(vtype(phi)));
                }
            }
        }
    }

    use_counts: Table(Value_Id, u32); use_counts.allocator = temp;
    ci := ng.classes.count - 1;
    while ci >= 0 {
        cc := cast(s32) ci;
        ci -= 1;
        possible_dead_stores: [..] Ng_Value_Dfs; possible_dead_stores.allocator = temp;
        probably_dead: Ng_Value_Set;
        c := ng_cls(cc);
        if (c.members.count == 0 && c.mem_members.count == 0) || c.members.count == 0 continue;
        if cc == ng.top {
            for m: c.members {
                found, vte := table_find(*ng.value_to_expr, m);
                if found && ng_expr(vte).et == .DEAD ng_mark_instruction_for_deletion(m);
            }
            continue;
        }
        leader := ifx c.stored != NONE then c.stored else c.leader;
        if ng_always_available(leader) {
            left: [..] Value_Id; left.allocator = temp;
            members: [..] Value_Id; members.allocator = temp;
            for c.members array_add(*members, it);
            for m: members {
                if m == leader || !is_inst(m) || vtype(m) == ir.t_void { array_add(*left, m); continue; }
                ng_replace_instruction(m, leader);
                anything_replaced = true;
            }
            ng_set_members(cc, left);
        } else {
            if c.members.count != 1 || table_contains(*ng.real_to_temp, leader) {
                stack: Ng_Stack; stack.vals.allocator = temp; stack.dfs.allocator = temp;
                set: [..] Ng_Value_Dfs; set.allocator = temp;
                ng_convert_class_to_dfs_ordered(cc, *set, *use_counts, *probably_dead);
                ng_sort_vdfs(*set);
                for *vd: set {
                    in_ := vd.dfs_in; out_ := vd.dfs_out;
                    def := vd.def;
                    from_store := vd.def_from_store;
                    u := vd.u;
                    if def != NONE && vtype(def) == ir.t_void continue;
                    if is_inst(def) && table_contains(*ng.all_temps, def) {
                        pn := def;
                        table_remove(*ng.all_temps, pn);
                        def_block := ng_block_of(def);
                        insert_at_position(pn, def_block, block_first(def_block), true);
                        ic_reinsert_name(pn);
                        def = pn;
                    }
                    should_push := def != NONE && stack.vals.count == 0;
                    out_of_scope := !ng_stack_in_scope(*stack, in_, out_);
                    if out_of_scope || should_push {
                        ng_stack_pop_until(*stack, in_, out_);
                        if def != NONE && stack.vals.count == 0 ng_stack_push(*stack, def, in_, out_);
                    }
                    if def != NONE {
                        if stack.vals.count && is_inst(def) && !from_store {
                            dominating := stack.vals[stack.vals.count - 1];
                            if dominating != def {
                                patch_replacement_instruction(def, dominating);
                                dvr: [..] u32; dvr.allocator = temp;
                                find_dbg_users(ng.f, def, *dvr);
                                for dvr dbgr_replace_variable_location_op(it, def, dominating);
                                ng_mark_instruction_for_deletion(def);
                            }
                        }
                        continue;
                    }
                    inst_use := ir.u_user[u];
                    used := ir.u_val[u];
                    if ng_vs_contains(*ng.to_erase, inst_use) {
                        p := table_find_pointer(*use_counts, used);
                        if !p p = table_set(*use_counts, used, 0);
                        p.* -= 1;
                        if p.* == 0 ng_vs_insert(*probably_dead, used);
                    }
                    if stack.vals.count == 0 continue;
                    dominating := stack.vals[stack.vals.count - 1];
                    ssa_copy: Value_Id = NONE;
                    if is_inst(dominating) && inst_op(dominating) == .BITCAST {
                        if vtype(dominating) == vtype(op(dominating, 0)) && pi_info_for(ng.pi, dominating) {
                            ssa_copy = dominating;
                            dominating = op(dominating, 0);
                        }
                    }
                    if used == dominating continue;
                    replaced := used;
                    p := pi_info_for(ng.pi, replaced);
                    if !p || dominating != p.original_op patch_replacement_instruction(replaced, dominating);
                    use_set(u, dominating);
                    lp := table_find_pointer(*use_counts, dominating);
                    if !lp lp = table_set(*use_counts, dominating, 0);
                    if lp.* == 0 && is_inst(dominating) {
                        if ng_vs_contains(*probably_dead, dominating) ng_vs_erase(*probably_dead, dominating);
                    }
                    if ssa_copy != NONE {
                        sp := table_find_pointer(*use_counts, ssa_copy);
                        if sp {
                            sp.* -= 1;
                            if sp.* == 0 ng_vs_insert(*probably_dead, ssa_copy);
                        }
                    }
                    lp = table_find_pointer(*use_counts, dominating);
                    lp.* += 1;
                    anything_replaced = true;
                }
            }
        }
        for probably_dead.list {
            if !table_contains(*probably_dead.has, it) continue;
            if would_instruction_be_trivially_dead(it, false) ng_mark_instruction_for_deletion(it);
        }
        left: [..] Value_Id; left.allocator = temp;
        for m: ng_cls(cc).members if !is_inst(m) || !ng_vs_contains(*ng.to_erase, m) array_add(*left, m);
        ng_set_members(cc, left);
        if ng_cls(cc).store_count > 0 {
            ng_convert_class_to_loads_and_stores(cc, *possible_dead_stores);
            ng_sort_vdfs(*possible_dead_stores);
            stack: Ng_Stack; stack.vals.allocator = temp; stack.dfs.allocator = temp;
            for *vd: possible_dead_stores {
                in_ := vd.dfs_in; out_ := vd.dfs_out;
                member := vd.def;
                if stack.vals.count == 0 || !ng_stack_in_scope(*stack, in_, out_) {
                    ng_stack_pop_until(*stack, in_, out_);
                    if stack.vals.count == 0 {
                        ng_stack_push(*stack, member, in_, out_);
                        continue;
                    }
                }
                if inst_op(member) == .LOAD continue;
                ng_mark_instruction_for_deletion(member);
                ng_member_erase(cc, member);
            }
        }
    }
    return anything_replaced;
}
ng_vs_erase :: (s: *Ng_Value_Set, v: Value_Id) {
    if !table_contains(*s.has, v) return;
    table_remove(*s.has, v);
    for s.list if it == v { s.list[it_index] = s.list[s.list.count - 1]; s.list.count -= 1; break; }
}

// ---------------------------------------------------------------- ranking

// getRank
ng_get_rank :: (v: Value_Id) -> u32 {
    k := vkind(v);
    if k == .C_EXPR return 3;
    if k == .C_POISON return 1;
    if k == .C_UNDEF return 2;
    if is_constant_kind(k) return 0;
    if k == .ARGUMENT return 4 + arg_no(v);
    if k == .INST {
        r := ng_dfs(v);
        if r > 0 return 5 + ng.num_func_args + r;
    }
    return 0xFFFF_FFFF;
}
// shouldSwapOperands: (rank, pointer) ordering; value ids stand in for pointers
ng_should_swap_operands :: (a: Value_Id, b: Value_Id) -> bool {
    ra := ng_get_rank(a); rb := ng_get_rank(b);
    if ra != rb return ra > rb;
    // equal-rank constants (and unranked values) are ordered by address in LLVM; creation order (value id) is
    // the closest reproducible stand-in (knowledge/llvm/newgvn.md); ng.reverse_ties is the second order newgvn_run
    // tries to see whether the outcome depends on it
    if ng.reverse_ties return a < b;
    return a > b;
}
// shouldSwapOperandsForPredicate
ng_should_swap_operands_for_predicate :: (a: Value_Id, b: Value_Id, i: Value_Id) -> bool {
    if ng_should_swap_operands(a, b) {
        table_set(*ng.predicate_swap_choice, i, b);
        return true;
    }
    p := table_find_pointer(*ng.predicate_swap_choice, i);
    if p {
        seen := p.*;
        if seen != NONE {
            if seen == b return true;
            p.* = NONE;
        }
    }
    return false;
}

// ---------------------------------------------------------------- VNCoercion (NewGVN-only parts)

// getConstantValueForLoad
ng_get_constant_value_for_load :: (src: Value_Id, offset: u64, load_ty: Type_Id) -> Value_Id {
    return cfo_load_from_const(src, load_ty, ap_from_u64(32, offset));
}
// getConstantMemInstValueForLoad
ng_get_constant_mem_inst_value_for_load :: (mi: Value_Id, offset: u64, load_ty: Type_Id) -> Value_Id {
    load_size := dl_type_size_bits(load_ty) / 8;
    if is_memset_intrinsic(mi) {
        val := call_arg(mi, 1);
        if vkind(val) != .C_INT return NONE;
        bits := cast(u32) (load_size * 8);
        byte := const_int_zext(val) & 0xFF;
        words: [..] u64; words.allocator = temp;
        nw := (bits + 63) / 64;
        for 0..cast(s64) nw - 1 {
            w: u64 = 0;
            for b: 0..7 w |= byte << cast(u64) (b * 8);
            array_add(*words, w);
        }
        splat := const_int_words(type_int(bits), words);
        return cfo_load_from_const(splat, load_ty, ap_from_u64(64, 0));
    }
    src := call_arg(mi, 1);
    return cfo_load_from_const_ptr_off(src, load_ty, ap_from_u64(dl_index_type_size_bits(vtype(src)), offset));
}

// ---------------------------------------------------------------- driver

ng_init_tables :: (s: *Ng) {
    s.exprs.allocator = temp; s.eops.allocator = temp; s.eiops.allocator = temp;
    s.rpo_ordering.allocator = temp; s.classes.allocator = temp; s.member_pos.allocator = temp; s.mphi_pos.allocator = temp;
    s.value_to_class.allocator = temp; s.value_to_expr.allocator = temp; s.phi_node_uses.allocator = temp;
    s.op_safe.allocator = temp; s.temp_to_block.allocator = temp; s.real_to_temp.allocator = temp;
    s.additional_users.allocator = temp; s.expr_to_phi_of_ops.heads.allocator = temp; s.expr_to_phi_of_ops.ents.allocator = temp;
    s.temp_to_memory.allocator = temp; s.all_temps.allocator = temp; s.revisit.allocator = temp; s.revisit_order.allocator = temp;
    s.predicate_to_users.allocator = temp; s.memory_to_users.allocator = temp; s.memory_to_class.allocator = temp;
    s.mphi_state.allocator = temp; s.inst_cycle_state.allocator = temp;
    s.expr_to_class.heads.allocator = temp; s.expr_to_class.ents.allocator = temp;
    s.leader_changes.allocator = temp; s.reachable_edges.allocator = temp; s.reachable_edge_list.allocator = temp;
    s.reachable_blocks.allocator = temp; s.touched.allocator = temp; s.block_inst_range.allocator = temp;
    s.predicate_swap_choice.allocator = temp; s.instr_dfs.allocator = temp; s.mphi_dfs.allocator = temp;
    s.dfs_to_instr.allocator = temp; s.address_order_ties.allocator = temp;
    s.scc_in_component.allocator = temp; s.scc_root.allocator = temp; s.scc_stack.allocator = temp;
    s.scc_components.allocator = temp; s.scc_value_to_component.allocator = temp;
}

// Sort the dominator tree's children arrays into RPO (NewGVN::runGVN)
ng_sort_domtree_children :: (rpo: [] Value_Id) {
    dt := ng.dt;
    for b: rpo {
        nd := dt_node(dt, b);
        if dt.nodes[nd].first_child < 0 continue;
        children: [..] s32; children.allocator = temp;
        c := dt.nodes[nd].first_child;
        while c >= 0 { array_add(*children, c); c = dt.nodes[c].sibling; }
        // llvm::sort by RPO number (unique keys)
        for i: 1..children.count - 1 {
            x := children[i]; kx := ng_rpo(dt.nodes[x].block);
            j := i - 1;
            while j >= 0 && ng_rpo(dt.nodes[children[j]].block) > kx { children[j + 1] = children[j]; j -= 1; }
            children[j + 1] = x;
        }
        dt.nodes[nd].first_child = children[0];
        for i: 0..children.count - 1 {
            dt.nodes[children[i]].sibling = ifx i + 1 < children.count then children[i + 1] else -1;
        }
        dt.nodes[nd].last_child = children[children.count - 1];
    }
}

// runGVN, up to the end of the iteration
ng_run_gvn_iterate :: () {
    ng.num_func_args = func_nparams(glob(ng.f).value_type);
    ng.dead_expr = ng_new_expr(.DEAD);
    icount: u32 = 1;
    array_add(*ng.dfs_to_instr, .{NONE, -1});
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(ng.f), *po);
    rpo: [..] Value_Id; rpo.allocator = temp;
    for < po array_add(*rpo, it);
    counter: u32 = 0;
    for rpo { counter += 1; table_set(*ng.rpo_ordering, it, counter); }
    ng_sort_domtree_children(rpo);
    // depth_first(DT->getRootNode())
    dt_order: [..] Value_Id; dt_order.allocator = temp;
    {
        dt := ng.dt;
        stack: [..] s32; stack.allocator = temp;
        array_add(*stack, dt.root_node);
        // preorder with children in list order
        Frame :: struct { n: s32; c: s32; }
        fs: [..] Frame; fs.allocator = temp;
        array_add(*fs, .{dt.root_node, dt.nodes[dt.root_node].first_child});
        array_add(*dt_order, dt.nodes[dt.root_node].block);
        while fs.count {
            top := *fs[fs.count - 1];
            if top.c < 0 { fs.count -= 1; continue; }
            c := top.c;
            top.c = dt.nodes[c].sibling;
            array_add(*dt_order, dt.nodes[c].block);
            array_add(*fs, .{c, dt.nodes[c].first_child});
        }
    }
    for b: dt_order {
        r := ng_assign_dfs_numbers(b, icount);
        table_set(*ng.block_inst_range, b, r);
        icount += r[1] - r[0];
    }
    ng_initialize_classes(dt_order);
    ng.touched_bits = icount;
    for 0..(icount + 63) / 64 - 1 array_add(*ng.touched, 0);
    entry := fn_entry(ng.f);
    found, r := table_find(*ng.block_inst_range, entry);
    ng_touch_range(r[0], r[1]);
    table_set(*ng.reachable_blocks, entry, true);
    ng.cache_idx = 0;

    ng_iterate_touched_instructions();
}
// cleanupTables: delete the temporaries that never became real
ng_cleanup_temps :: () {
    temps: [..] Value_Id; temps.allocator = temp;
    for v, k: ng.all_temps array_add(*temps, k);
    for temps drop_all_references(it);
    for temps {
        if has_uses(it) fatal("newgvn: internal: a temporary instruction still has uses");
        erase_inst(it);
    }
}
// runGVN, from elimination on
ng_run_gvn_finish :: () -> bool {
    changed := false;
    changed |= ng_eliminate_instructions();

    for ng.to_erase.list {
        if has_uses(it) rauw_with_metadata(it, const_poison(vtype(it)));
        erase_inst_with_metadata(it);
    }
    changed |= ng.to_erase.list.count != 0;

    for b: fn_blocks(ng.f) {
        if ng_block_reachable(b) continue;
        ng_delete_instructions_in_block(b);
        changed = true;
    }

    ng_cleanup_temps();
    return changed;
}

newgvn_run :: (f: Value_Id) -> Preserved {
    s := New(Ng,, allocator = temp);
    ng_init_tables(s);
    saved := ng;
    ng = s;
    defer ng = saved;
    s.f = f;
    s.ac = get_assumption_cache(f);
    s.dt = get_domtree(f);
    tli_for(f);
    s.aar = aa_results_for(f);
    s.m = get_memoryssa(f);
    s.pi = predicate_info_build(f, s.dt, s.ac);
    s.sq.dt = s.dt; s.sq.ac = s.ac; s.sq.use_instr_info = false; s.sq.can_use_undef = false;
    s.to_erase.list.allocator = temp; s.to_erase.has.allocator = temp;
    fresh :: (old: *Ng) -> *Ng {
        n := New(Ng,, allocator = temp);
        ng_init_tables(n);
        n.f = old.f; n.ac = old.ac; n.dt = old.dt; n.aar = old.aar; n.m = old.m; n.pi = old.pi; n.sq = old.sq;
        n.to_erase.list.allocator = temp; n.to_erase.has.allocator = temp;
        return n;
    }
    ng_run_gvn_iterate();
    if !ng_opts.guess_address_order && ng.address_order_ties.count {
        // Fail loudly (ours): a predicate copy compared two operands whose order is LLVM's heap address order
        // (ng_address_order_tie). Iterate again with the rank ties broken the other way; if the outcome differs, the
        // output depends on the address order. Otherwise iterate once more in creation order and go on.
        snap_a := ng_outcome_snapshot();
        ng_cleanup_temps();
        ng = fresh(ng);
        ng.reverse_ties = true;
        ng_run_gvn_iterate();
        snap_b := ng_outcome_snapshot();
        ng_cleanup_temps();
        if snap_a != snap_b
            fatal("newgvn: the value of a predicate copy (an equality of two operands of equal rank) depends on LLVM's heap address order; not reproducible (-newgvn-guess-address-order guesses creation order)");
        ng = fresh(ng);
        ng_run_gvn_iterate();
    }
    changed := ng_run_gvn_finish();
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    return pa;
}
