// IRSimilarityIdentifier: a port of llvm/lib/Analysis/IRSimilarityIdentifier.cpp (IRInstructionData,
// IRInstructionMapper and its InstructionClassification, IRSimilarityCandidate with compareStructure and the canonical
// numbering, findCandidates, IRSimilarityAnalysis, IRSimilarityAnalysisPrinterPass `print-ir-similarity`) and of
// llvm/lib/Support/SuffixTree.cpp (Ukkonen construction, RepeatedSubstringIterator).
//
// LLVM iterates several DenseMap<unsigned, ...> / DenseSet<unsigned> (the suffix tree's children, the structural
// groups, the GVN mapping sets the canonical numbering picks from). Their iteration order is a function of the
// bucket layout, which `Dm32` reproduces exactly (llvm/ADT/DenseMap.h of LLVM 23: hash = key * 37, linear probing,
// 64 buckets on first growth, grow at 3/4 load, Knuth Algorithm R deletion, remove_if rehash). Where LLVM iterates a
// set of pointers and the result could depend on the address order, we check that it does not, and fail loudly
// otherwise (NOTES.md "Heap/pointer address order").
//
// Data layout: one IRInstructionData row per `Irsim_Data` in `irsim.data`; row 0 is the sentinel of the single
// IRInstructionDataList (an intrusive doubly linked list whose insert/remove reproduce simple_ilist exactly,
// including the double push_back populateMapper does at the end of a function). Candidates are rows of
// `irsim.cands`; a SimilarityGroup is a list of candidate ids (LLVM copies the candidates; they are not modified
// after the copy, so sharing the row is equivalent).

// ---------------------------------------------------------------- DenseMap<unsigned, unsigned> layout

DM32_NO :: 0xFFFF_FFFF;
Dm32 :: struct {
    keys: [..] u32;
    vals: [..] u32;
    used: [..] bool;
    n: u32;
}
dm32_nb :: inline (m: *Dm32) -> u32 { return cast(u32) m.keys.count; }
dm32_home :: inline (k: u32, nb: u32) -> u32 { return (k * 37) & (nb - 1); }
// NextPowerOf2 (llvm/Support/MathExtras.h): the smallest power of two strictly greater than a
dm32_next_pow2 :: (a: u64) -> u64 { r: u64 = 1; while r <= a r <<= 1; return r; }
dm32_alloc :: (m: *Dm32, nb: u32) {
    // fresh buffers: dm32_grow keeps reading the old ones
    empty: Dm32;
    m.keys = empty.keys; m.vals = empty.vals; m.used = empty.used;
    m.keys.allocator = temp; m.vals.allocator = temp; m.used.allocator = temp;
    array_resize(*m.keys, nb, initialize = false);
    array_resize(*m.vals, nb, initialize = false);
    array_resize(*m.used, nb);
    for * m.used it.* = false;
    m.n = 0;
}
// DenseMap(NumElementsToReserve)
dm32_init :: (m: *Dm32, reserve: u32 = 0) {
    nb: u32 = 0;
    if reserve > 0 nb = cast(u32) dm32_next_pow2(cast(u64) (reserve * 4 / 3 + 1));
    dm32_alloc(m, nb);
}
// DenseSet(std::initializer_list) with one element: DenseSetImpl(PowerOf2Ceil(1)) = 4 buckets
dm32_set_of :: (k: u32) -> Dm32 {
    m: Dm32;
    dm32_init(*m, 1);
    dm32_insert(*m, k);
    return m;
}
dm32_lookup :: (m: *Dm32, k: u32) -> found: bool, bucket: s64 {
    nb := dm32_nb(m);
    if nb == 0 return false, -1;
    b := dm32_home(k, nb);
    while true {
        if !m.used[b] return false, b;
        if m.keys[b] == k return true, b;
        b = (b + 1) & (nb - 1);
    }
    return false, -1;
}
dm32_contains :: inline (m: *Dm32, k: u32) -> bool { f := dm32_lookup(m, k); return f; }
dm32_get :: (m: *Dm32, k: u32) -> found: bool, val: u32 {
    f, b := dm32_lookup(m, k);
    if !f return false, DM32_NO;
    return true, m.vals[b];
}
// grow(MinNumBuckets): roundUpNumBuckets, then moveFrom in bucket order
dm32_grow :: (m: *Dm32, min_nb: u32) {
    nb: u32 = 64;
    if min_nb > 0 { p := dm32_next_pow2(cast(u64) (min_nb - 1)); if p > 64 nb = cast(u32) p; }
    old := m.*;
    dm32_alloc(m, nb);
    for b: 0..old.keys.count - 1 {
        if !old.used[b] continue;
        k := old.keys[b];
        t := dm32_home(k, nb);
        while m.used[t] t = (t + 1) & (nb - 1);
        m.used[t] = true; m.keys[t] = k; m.vals[t] = old.vals[b];
    }
    m.n = old.n;
}
// try_emplace / insert: (bucket, inserted); an existing entry keeps its value
dm32_insert :: (m: *Dm32, k: u32, v: u32 = 0) -> bucket: s64, inserted: bool {
    f, b := dm32_lookup(m, k);
    if f return b, false;
    nb := dm32_nb(m);
    if (m.n + 1) * 4 >= nb * 3 {
        dm32_grow(m, nb * 2);
        f, b = dm32_lookup(m, k);
    }
    m.used[b] = true; m.keys[b] = k; m.vals[b] = v;
    m.n += 1;
    return b, true;
}
// eraseFromFilledBucket (Knuth TAOCP 6.4 Algorithm R)
dm32_erase_bucket :: (m: *Dm32, bucket: s64) {
    m.n -= 1;
    mask := dm32_nb(m) - 1;
    i := cast(u32) bucket;
    j := i;
    while true {
        j = (j + 1) & mask;
        if !m.used[j] break;
        ideal := m.keys[j] * 37;
        if ((i - ideal) & mask) < ((j - ideal) & mask) {
            m.keys[i] = m.keys[j]; m.vals[i] = m.vals[j];
            i = j;
        }
    }
    m.used[i] = false;
}
dm32_erase :: (m: *Dm32, k: u32) -> bool {
    f, b := dm32_lookup(m, k);
    if !f return false;
    dm32_erase_bucket(m, b);
    return true;
}
// clear (with shrink_and_clear)
dm32_clear :: (m: *Dm32) {
    if m.n == 0 return;
    nb := dm32_nb(m);
    if m.n * 4 < nb && nb > 64 {
        log2c: u32 = 0;
        while (cast(u64) 1 << log2c) < cast(u64) m.n log2c += 1;
        nnb := max(cast(u32) 64, cast(u32) 1 << (log2c + 1));
        if nnb != nb { dm32_alloc(m, nnb); return; }
    }
    for * m.used it.* = false;
    m.n = 0;
}
// copy constructor (copyFrom: same bucket count and layout)
dm32_copy :: (src: *Dm32) -> Dm32 {
    m: Dm32;
    dm32_alloc(*m, dm32_nb(src));
    for b: 0..src.keys.count - 1 { m.used[b] = src.used[b]; m.keys[b] = src.keys[b]; m.vals[b] = src.vals[b]; }
    m.n = src.n;
    return m;
}
// the keys in iteration order
dm32_keys :: (m: *Dm32) -> [..] u32 {
    r: [..] u32; r.allocator = temp;
    for b: 0..m.keys.count - 1 if m.used[b] array_add(*r, m.keys[b]);
    return r;
}
dm32_first :: (m: *Dm32) -> u32 {
    for b: 0..m.keys.count - 1 if m.used[b] return m.keys[b];
    return DM32_NO;
}

// ---------------------------------------------------------------- SuffixTree (llvm/lib/Support/SuffixTree.cpp)

ST_EMPTY :: 0xFFFF_FFFF;
St_Node :: struct {
    start: u32;
    end: u32;                 // internal nodes; leaves end at Suffix_Tree.leaf_end
    leaf: bool;
    children: Dm32;           // DenseMap<unsigned, SuffixTreeNode *> (values: node ids)
    link: u32;
    concat_len: u32;
    suffix_idx: u32;
}
Suffix_Tree :: struct {
    str: [] u32;
    nodes: [..] St_Node;
    root: u32;
    leaf_end: u32 = ST_EMPTY;
    active_node: u32;
    active_idx: u32 = ST_EMPTY;
    active_len: u32;
}
St_Repeated :: struct { length: u32; starts: [..] u32; }

st_is_root :: inline (st: *Suffix_Tree, n: u32) -> bool { return !st.nodes[n].leaf && st.nodes[n].start == ST_EMPTY; }
st_end_idx :: inline (st: *Suffix_Tree, n: u32) -> u32 { return ifx st.nodes[n].leaf then st.leaf_end else st.nodes[n].end; }
st_num_elements :: (st: *Suffix_Tree, n: u32) -> u32 {
    if st_is_root(st, n) return 0;
    return st_end_idx(st, n) - st.nodes[n].start + 1;
}
st_set_child :: (st: *Suffix_Tree, parent: u32, edge: u32, child: u32) {
    b, ins := dm32_insert(*st.nodes[parent].children, edge, child);
    if !ins st.nodes[parent].children.vals[b] = child;
}
st_insert_leaf :: (st: *Suffix_Tree, parent: u32, start: u32, edge: u32) -> u32 {
    n: St_Node; n.start = start; n.leaf = true; n.link = ST_EMPTY;
    array_add(*st.nodes, n);
    id := cast(u32) st.nodes.count - 1;
    st_set_child(st, parent, edge, id);
    return id;
}
st_insert_internal :: (st: *Suffix_Tree, parent: u32, start: u32, end: u32, edge: u32) -> u32 {
    n: St_Node; n.start = start; n.end = end; n.link = st.root;
    dm32_init(*n.children);
    array_add(*st.nodes, n);
    id := cast(u32) st.nodes.count - 1;
    if parent != ST_EMPTY st_set_child(st, parent, edge, id);
    return id;
}
// SuffixTree::extend
st_extend :: (st: *Suffix_Tree, end_idx: u32, suffixes_in: u32) -> u32 {
    suffixes := suffixes_in;
    needs_link: u32 = ST_EMPTY;
    while suffixes > 0 {
        if st.active_len == 0 st.active_idx = end_idx;
        first_char := st.str[st.active_idx];
        found, next_node := dm32_get(*st.nodes[st.active_node].children, first_char);
        if !found {
            st_insert_leaf(st, st.active_node, end_idx, first_char);
            if needs_link != ST_EMPTY { st.nodes[needs_link].link = st.active_node; needs_link = ST_EMPTY; }
        } else {
            sub_len := st_num_elements(st, next_node);
            if st.active_len >= sub_len {
                st.active_idx += sub_len;
                st.active_len -= sub_len;
                st.active_node = next_node;
                continue;
            }
            last_char := st.str[end_idx];
            if st.str[st.nodes[next_node].start + st.active_len] == last_char {
                if needs_link != ST_EMPTY && !st_is_root(st, st.active_node) { st.nodes[needs_link].link = st.active_node; needs_link = ST_EMPTY; }
                st.active_len += 1;
                break;
            }
            nstart := st.nodes[next_node].start;
            split := st_insert_internal(st, st.active_node, nstart, nstart + st.active_len - 1, first_char);
            st_insert_leaf(st, split, end_idx, last_char);
            st.nodes[next_node].start += st.active_len;
            st_set_child(st, split, st.str[st.nodes[next_node].start], next_node);
            if needs_link != ST_EMPTY st.nodes[needs_link].link = split;
            needs_link = split;
        }
        suffixes -= 1;
        if st_is_root(st, st.active_node) {
            if st.active_len > 0 {
                st.active_len -= 1;
                st.active_idx = end_idx - suffixes + 1;
            }
        } else {
            st.active_node = st.nodes[st.active_node].link;
        }
    }
    return suffixes;
}
st_build :: (str: [] u32) -> Suffix_Tree {
    st: Suffix_Tree;
    st.str = str;
    st.nodes.allocator = temp;
    st.root = ST_EMPTY;
    st.root = st_insert_internal(*st, ST_EMPTY, ST_EMPTY, ST_EMPTY, 0);
    st.nodes[st.root].link = st.root;
    st.active_node = st.root;
    to_add: u32 = 0;
    for k: 0..str.count - 1 {
        to_add += 1;
        st.leaf_end = cast(u32) k;
        to_add = st_extend(*st, cast(u32) k, to_add);
    }
    // setSuffixIndices
    Visit :: struct { n: u32; len: u32; }
    stack: [..] Visit; stack.allocator = temp;
    array_add(*stack, .{st.root, 0});
    while stack.count {
        v := pop(*stack);
        st.nodes[v.n].concat_len = v.len;
        if !st.nodes[v.n].leaf {
            ch := *st.nodes[v.n].children;
            for b: 0..ch.keys.count - 1 {
                if !ch.used[b] continue;
                c := ch.vals[b];
                array_add(*stack, .{c, v.len + st_num_elements(*st, c)});
            }
        } else {
            st.nodes[v.n].suffix_idx = cast(u32) str.count - v.len;
        }
    }
    return st;
}
// for (RepeatedSubstring &RS : ST): RepeatedSubstringIterator::advance with MinLength 2, no leaf descendants
st_repeated_substrings :: (st: *Suffix_Tree) -> [..] St_Repeated {
    out: [..] St_Repeated; out.allocator = temp;
    stack: [..] u32; stack.allocator = temp;
    array_add(*stack, st.root);
    while stack.count {
        cur := pop(*stack);
        length := st.nodes[cur].concat_len;
        ch := *st.nodes[cur].children;
        for b: 0..ch.keys.count - 1 if ch.used[b] && !st.nodes[ch.vals[b]].leaf array_add(*stack, ch.vals[b]);
        if length < 2 continue;
        if st_is_root(st, cur) continue;
        rs: St_Repeated; rs.starts.allocator = temp;
        for b: 0..ch.keys.count - 1 if ch.used[b] && st.nodes[ch.vals[b]].leaf array_add(*rs.starts, st.nodes[ch.vals[b]].suffix_idx);
        if rs.starts.count < 2 continue;
        rs.length = length;
        array_add(*out, rs);
    }
    return out;
}

// ---------------------------------------------------------------- IRInstructionData and the mapper

Irsim_Data :: struct {
    inst: Value_Id = NONE;          // nullptr for the illegal entry that ends a function
    legal: bool;
    ops: [..] Value_Id;             // OperVals
    revised_pred: s32 = -1;         // RevisedPredicate (-1: none)
    has_callee_name: bool;
    callee_name: string;
    rel_locs: [..] s32;             // RelativeBlockLocations
    prev: u32 = 0xFFFF_FFFF;        // ilist links (row 0 is the sentinel; 0xFFFFFFFF = nullptr)
    next: u32 = 0xFFFF_FFFF;
}
IRSIM_NULL :: 0xFFFF_FFFF;

Irsim_Cand :: struct {
    start_idx: u32;
    len: u32;
    first: u32;
    last: u32;
    v2n: Table(Value_Id, u32);      // ValueToNumber
    n2v: [..] Value_Id;             // NumberToValue (numbers 1..count: index number - 1)
    n2c: [..] u32;                  // NumberToCanonNum (indexed by number; IRSIM_NULL = none)
    c2n: [..] u32;                  // CanonNumToNumber (indexed by canonical number)
}

Irsim :: struct {
    data: [..] Irsim_Data;          // row 0: the IDL sentinel
    cands: [..] Irsim_Cand;
    groups: [..] [..] u32;          // SimilarityCandidates: lists of candidate ids
    // IRInstructionMapper
    illegal_number: u32 = 0xFFFF_FFFD;
    legal_number: u32;
    int_map_buckets: Table(u64, [..] u32);   // InstructionIntegerMap: a coarse key -> (data row) representatives
    int_map_num: Table(u32, u32);            // representative row -> number
    bb_number: Table(Value_Id, u32);         // BasicBlockToInteger
    added_illegal_last_time: bool;
    can_combine_with_prev: bool;
    have_legal_range: bool;
    match_calls_by_name: bool;
    // InstructionClassification
    enable_branches := true;
    enable_indirect_calls := true;
    enable_intrinsics := true;
    enable_musttail_calls := false;
}

irsim_cl: struct {
    disable_branches: bool;          // -no-ir-sim-branch-matching
    disable_indirect_calls: bool;    // -no-ir-sim-indirect-calls
    match_calls_by_name: bool;       // -ir-sim-calls-by-name
    disable_intrinsics: bool;        // -no-ir-sim-intrinsics
};
irsim_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    parse_bool :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("opt: invalid boolean value '%' for option -%", value, name);
        return false;
    }
    if name == "no-ir-sim-branch-matching" { irsim_cl.disable_branches = parse_bool(name, value, has_value); return true; }
    if name == "no-ir-sim-indirect-calls" { irsim_cl.disable_indirect_calls = parse_bool(name, value, has_value); return true; }
    if name == "ir-sim-calls-by-name" { irsim_cl.match_calls_by_name = parse_bool(name, value, has_value); return true; }
    if name == "no-ir-sim-intrinsics" { irsim_cl.disable_intrinsics = parse_bool(name, value, has_value); return true; }
    return false;
}

irsim_ilist_insert_before :: (s: *Irsim, next: u32, n: u32) {
    prev := s.data[next].prev;
    s.data[n].next = next;
    s.data[n].prev = prev;
    s.data[prev].next = n;
    s.data[next].prev = n;
}
irsim_ilist_push_back :: (s: *Irsim, n: u32) { irsim_ilist_insert_before(s, 0, n); }
// simple_ilist::erase(First, Last): removeRangeImpl
irsim_ilist_erase_range :: (s: *Irsim, first: u32, last: u32) {
    if first == last return;
    prev := s.data[first].prev;
    final := s.data[last].prev;
    s.data[last].prev = prev;
    s.data[prev].next = last;
    s.data[first].prev = IRSIM_NULL;
    s.data[final].next = IRSIM_NULL;
}

// CallBase::isIndirectCall
irsim_is_indirect_call :: (c: Value_Id) -> bool {
    v := call_callee(c);
    if vkind(v) == .FUNCTION return false;
    if vkind(v) == .INLINE_ASM return false;
    if is_const(v) return false;
    return true;
}
// isa<IntrinsicInst>: a call whose called function's name starts with "llvm." (even an unknown intrinsic)
irsim_is_intrinsic_inst :: (i: Value_Id) -> bool {
    if inst_op(i) != .CALL return false;
    f := call_called_function(i);
    return f != NONE && glob(f).intrinsic;
}
irsim_is_must_tail :: (c: Value_Id) -> bool { return inst_op(c) == .CALL && call_tail_kind(c) == 2; }
irsim_is_tail_cc :: (c: Value_Id) -> bool { cc := inst(c).cc; return cc == VCC_SWIFTTAIL || cc == VCC_TAIL; }

// IRInstructionMapper::InstructionClassification::visit: true = Legal (there are no Invisible instructions)
irsim_classify :: (s: *Irsim, i: Value_Id) -> bool {
    o := inst_op(i);
    if o == {
        case .BR; #through;
        case .CONDBR; #through;
        case .PHI; return s.enable_branches;
        case .ALLOCA; #through;
        case .VAARG; #through;
        case .LANDINGPAD; #through;
        case .CLEANUPPAD; #through;
        case .CATCHPAD; return false;
        case .INVOKE; #through;
        case .CALLBR; return false;
        case .CALL;
            if call_iid(i) != NOT_INTRINSIC {
                if is_assume_like_intrinsic(i) return false;
                return s.enable_intrinsics;
            }
            f := call_called_function(i);
            indirect := irsim_is_indirect_call(i);
            if indirect && !s.enable_indirect_calls return false;
            if f == NONE && !indirect return false;
            if irsim_is_tail_cc(i) && !s.enable_musttail_calls return false;
            if irsim_is_must_tail(i) && !s.enable_musttail_calls return false;
            return true;
    }
    if is_terminator(o) return false;
    return true;
}

// predicateForConsistency
irsim_predicate_for_consistency :: (i: Value_Id) -> u8 {
    p := inst(i).pred;
    if p == {
        case FCMP_OGT; #through; case FCMP_UGT; #through; case FCMP_OGE; #through; case FCMP_UGE; #through;
        case ICMP_SGT; #through; case ICMP_UGT; #through; case ICMP_SGE; #through; case ICMP_UGE;
            return swapped_predicate(p);
    }
    return p;
}
irsim_get_predicate :: (s: *Irsim, d: u32) -> u8 {
    r := *s.data[d];
    if r.revised_pred >= 0 return cast(u8) r.revised_pred;
    return inst(r.inst).pred;
}

// IRInstructionData(I, Legality, IDL) + initializeInstruction
irsim_new_data :: (s: *Irsim, i: Value_Id, legal: bool) -> u32 {
    d: Irsim_Data;
    d.inst = i; d.legal = legal;
    d.ops.allocator = temp; d.rel_locs.allocator = temp;
    if i != NONE {
        o := inst_op(i);
        is_cmp := o == .ICMP || o == .FCMP;
        if is_cmp {
            p := irsim_predicate_for_consistency(i);
            if p != inst(i).pred d.revised_pred = p;
        }
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            v := op(i, cast(u32) k);
            if is_cmp && d.revised_pred >= 0 { array_insert_at(*d.ops, v, 0); continue; }
            array_add(*d.ops, v);
        }
        if o == .PHI for k: 0..cast(s64) n - 1 array_add(*d.ops, phi_block(i, cast(u32) k));
    }
    array_add(*s.data, d);
    return cast(u32) s.data.count - 1;
}
irsim_block_oper_vals :: (s: *Irsim, d: u32) -> [] Value_Id {
    r := *s.data[d];
    o := inst_op(r.inst);
    if o == .BR return r.ops;
    if o == .CONDBR { a := r.ops; a.data += 1; a.count -= 1; return a; }
    if o == .PHI { n := cast(s64) phi_num_incoming(r.inst); a := r.ops; a.data += n; a.count -= n; return a; }
    fatal("internal: ir-similarity: block operands of a non-branch");
    return .[];
}
irsim_bb_num :: (s: *Irsim, b: Value_Id) -> s32 {
    found, n := table_find(*s.bb_number, b);
    if !found fatal("internal: ir-similarity: a block without a number");
    return cast,no_check(s32) n;
}
irsim_set_branch_successors :: (s: *Irsim, d: u32) {
    cur := irsim_bb_num(s, inst_block(s.data[d].inst));
    for v: irsim_block_oper_vals(s, d) array_add(*s.data[d].rel_locs, irsim_bb_num(s, v) - cur);
}
irsim_set_phi_predecessors :: (s: *Irsim, d: u32) {
    p := s.data[d].inst;
    cur := irsim_bb_num(s, inst_block(p));
    for k: 0..cast(s64) phi_num_incoming(p) - 1 array_add(*s.data[d].rel_locs, irsim_bb_num(s, phi_block(p, cast(u32) k)) - cur);
}
// setCalleeName
irsim_set_callee_name :: (s: *Irsim, d: u32, by_name: bool) {
    i := s.data[d].inst;
    s.data[d].has_callee_name = true;
    s.data[d].callee_name = "";
    id := call_iid(i);
    if irsim_is_intrinsic_inst(i) {
        // an unknown llvm.* function: Intrinsic::getName(not_intrinsic)
        if id == NOT_INTRINSIC { s.data[d].callee_name = "not_intrinsic"; return; }
        // Intrinsic::getName(ID, FT->params(), M, FT) for an overloaded intrinsic: the name mangles every parameter
        // type; only equality of these names matters, so the parameter type ids stand in for the mangling
        if intrinsic_is_overloaded(id) {
            ft := inst(i).ty2;
            sb: String_Builder; sb.allocator = temp;
            append(*sb, intrinsic_name(id));
            np := func_nparams(ft);
            for k: 0..cast(s64) np - 1 print_to_builder(*sb, ".%", func_param(ft, cast(u32) k));
            print_to_builder(*sb, "->%", func_ret(ft));
            s.data[d].callee_name = builder_to_string(*sb,, allocator = temp);
        } else {
            s.data[d].callee_name = intrinsic_name(id);
        }
        return;
    }
    if !irsim_is_indirect_call(i) && by_name s.data[d].callee_name = vname(call_called_function(i));
}

// isClose
irsim_is_close :: (s: *Irsim, a: u32, b: u32) -> bool {
    ra := *s.data[a]; rb := *s.data[b];
    if !ra.legal || !rb.legal return false;
    ia := ra.inst; ib := rb.inst;
    oa := inst_op(ia); ob := inst_op(ib);
    if !is_same_operation_as(ia, ib) {
        if (oa == .ICMP || oa == .FCMP) && (ob == .ICMP || ob == .FCMP) {
            if irsim_get_predicate(s, a) != irsim_get_predicate(s, b) return false;
            n := min(ra.ops.count, rb.ops.count);
            for k: 0..n - 1 if vtype(ra.ops[k]) != vtype(rb.ops[k]) return false;
            return true;
        }
        return false;
    }
    if oa == .GEP {
        if (inst(ia).flags & F_INBOUNDS) != (inst(ib).flags & F_INBOUNDS) return false;
        // zip(indices) after the first index
        na := cast(s64) nops(ia) - 1; nb := cast(s64) nops(ib) - 1;
        // Without indices, drop_begin steps past the end of the (empty) zipped range and all_of compares the memory
        // behind the operand lists: the first word (the GEP's Type *) matches, the next one (the instructions' ilist
        // links) differs. So a GEP without indices is close to no other instruction.
        if na == 0 return false;
        n := min(na, nb);
        for k: 1..n - 1 if op(ia, cast(u32) (k + 1)) != op(ib, cast(u32) (k + 1)) return false;
        return true;
    }
    if oa == .CALL && ob == .CALL {
        if ra.callee_name != rb.callee_name return false;
    }
    if (oa == .BR || oa == .CONDBR) && (ob == .BR || ob == .CONDBR) && ra.rel_locs.count != rb.rel_locs.count return false;
    return true;
}

irsim_coarse_key :: (s: *Irsim, d: u32) -> u64 {
    i := s.data[d].inst;
    o := inst_op(i);
    // isClose implies the same opcode for everything but compares (icmp/fcmp share a revised predicate)
    return ((cast(u64) o) << 56) ^ ((cast(u64) vtype(i)) << 20) ^ cast(u64) s.data[d].ops.count;
}

// mapToLegalUnsigned
irsim_map_legal :: (s: *Irsim, i: Value_Id, ints: *[..] u32, rows: *[..] u32) {
    s.added_illegal_last_time = false;
    if s.can_combine_with_prev s.have_legal_range = true;
    s.can_combine_with_prev = true;
    d := irsim_new_data(s, i, true);
    array_add(rows, d);
    o := inst_op(i);
    if o == .BR || o == .CONDBR irsim_set_branch_successors(s, d);
    if o == .CALL irsim_set_callee_name(s, d, s.match_calls_by_name);
    if o == .PHI irsim_set_phi_predecessors(s, d);
    key := irsim_coarse_key(s, d);
    bucket := table_find_pointer(*s.int_map_buckets, key);
    if !bucket {
        l: [..] u32; l.allocator = temp;
        bucket = table_set(*s.int_map_buckets, key, l);
    }
    for rep: bucket.* {
        if irsim_is_close(s, rep, d) {
            _, n := table_find(*s.int_map_num, rep);
            array_add(ints, n);
            return;
        }
    }
    array_add(bucket, d);
    table_set(*s.int_map_num, d, s.legal_number);
    array_add(ints, s.legal_number);
    s.legal_number += 1;
}
// mapToIllegalUnsigned
irsim_map_illegal :: (s: *Irsim, i: Value_Id, ints: *[..] u32, rows: *[..] u32, at_end := false) {
    s.can_combine_with_prev = false;
    if s.added_illegal_last_time return;
    d := ifx at_end then irsim_new_data(s, NONE, false) else irsim_new_data(s, i, false);
    array_add(rows, d);
    s.added_illegal_last_time = true;
    array_add(ints, s.illegal_number);
    s.illegal_number -= 1;
}
// convertToUnsignedVec
irsim_convert_block :: (s: *Irsim, bb: Value_Id, list: *[..] u32, ints: *[..] u32) {
    bb_ints: [..] u32; bb_ints.allocator = temp;
    bb_rows: [..] u32; bb_rows.allocator = temp;
    for i: block_insts(bb) {
        if irsim_classify(s, i) irsim_map_legal(s, i, *bb_ints, *bb_rows);
        else irsim_map_illegal(s, i, *bb_ints, *bb_rows);
    }
    if s.added_illegal_last_time irsim_map_illegal(s, NONE, *bb_ints, *bb_rows, true);
    for bb_rows irsim_ilist_push_back(s, it);
    for bb_rows array_add(list, it);
    for bb_ints array_add(ints, it);
}

// ---------------------------------------------------------------- IRSimilarityCandidate

irsim_cand_next :: inline (s: *Irsim, d: u32) -> u32 {
    n := s.data[d].next;
    if n == IRSIM_NULL fatal("internal: ir-similarity: walked off the instruction data list");
    return n;
}
// the data rows of a candidate, front to back
irsim_cand_rows :: (s: *Irsim, c: u32) -> [..] u32 {
    r: [..] u32; r.allocator = temp;
    d := s.cands[c].first;
    last := s.cands[c].last;
    while true {
        array_add(*r, d);
        if d == last break;
        d = irsim_cand_next(s, d);
    }
    return r;
}
irsim_cand_end :: (s: *Irsim, c: u32) -> u32 { return s.data[s.cands[c].last].next; }
irsim_front_inst :: inline (s: *Irsim, c: u32) -> Value_Id { return s.data[s.cands[c].first].inst; }
irsim_back_inst :: inline (s: *Irsim, c: u32) -> Value_Id { return s.data[s.cands[c].last].inst; }
irsim_start_bb :: inline (s: *Irsim, c: u32) -> Value_Id { return inst_block(irsim_front_inst(s, c)); }
irsim_end_idx :: inline (s: *Irsim, c: u32) -> u32 { return s.cands[c].start_idx + s.cands[c].len - 1; }
irsim_get_gvn :: (s: *Irsim, c: u32, v: Value_Id) -> bool, u32 {
    f, n := table_find(*s.cands[c].v2n, v);
    return f, n;
}
irsim_from_gvn :: (s: *Irsim, c: u32, n: u32) -> bool, Value_Id {
    k := cast(s64) n - 1;
    if n == 0 || k >= s.cands[c].n2v.count return false, NONE;
    return true, s.cands[c].n2v[k];
}
irsim_canon :: (s: *Irsim, c: u32, n: u32) -> bool, u32 { f, v := u32map_find(*s.cands[c].n2c, n); return f, v; }
irsim_from_canon :: (s: *Irsim, c: u32, n: u32) -> bool, u32 { f, v := u32map_find(*s.cands[c].c2n, n); return f, v; }
// a map from small unsigned keys: an array with IRSIM_NULL holes
u32map_find :: inline (m: *[..] u32, k: u32) -> bool, u32 {
    if cast(s64) k >= m.count return false, 0;
    v := m.*[k];
    return v != IRSIM_NULL, v;
}
u32map_contains :: inline (m: *[..] u32, k: u32) -> bool { f := u32map_find(m, k); return f; }
u32map_set :: (m: *[..] u32, k: u32, v: u32) {
    if cast(s64) k >= m.count {
        old := m.count;
        array_resize(m, cast(s64) k + 1, initialize = false);
        for i: old..m.count - 1 m.*[i] = IRSIM_NULL;
    }
    m.*[k] = v;
}

// getBasicBlocks(BBSet, BBList): the blocks in instruction order
irsim_cand_blocks :: (s: *Irsim, c: u32) -> [..] Value_Id {
    r: [..] Value_Id; r.allocator = temp;
    for d: irsim_cand_rows(s, c) {
        b := inst_block(s.data[d].inst);
        seen := false;
        for r if it == b { seen = true; break; }
        if !seen array_add(*r, b);
    }
    return r;
}

// IRSimilarityCandidate::IRSimilarityCandidate
irsim_new_cand :: (s: *Irsim, start_idx: u32, len: u32, first: u32, last: u32) -> u32 {
    c: Irsim_Cand;
    c.start_idx = start_idx; c.len = len; c.first = first; c.last = last;
    c.v2n.allocator = temp; c.n2v.allocator = temp; c.n2c.allocator = temp; c.c2n.allocator = temp;
    array_add(*s.cands, c);
    id := cast(u32) s.cands.count - 1;
    cc := *s.cands[id];
    number :: (cc: *Irsim_Cand, v: Value_Id) {
        if table_contains(*cc.v2n, v) return;
        array_add(*cc.n2v, v);
        table_set(*cc.v2n, v, cast(u32) cc.n2v.count);
    }
    d := first;
    for k: 0..cast(s64) len - 1 {
        for v: s.data[d].ops number(cc, v);
        number(cc, s.data[d].inst);
        if k + 1 < len d = irsim_cand_next(s, d);
    }
    // the blocks of the candidate: LLVM numbers them in DenseSet<BasicBlock *> (address) order. Only the canonical
    // numbers among blocks depend on it, and the outliner only compares those for equality, so instruction order
    // stands in for it.
    for b: irsim_cand_blocks(s, id) number(cc, b);
    return id;
}

// isSimilar
irsim_is_similar :: (s: *Irsim, a: u32, b: u32) -> bool {
    if s.cands[a].len != s.cands[b].len return false;
    ra := irsim_cand_rows(s, a); rb := irsim_cand_rows(s, b);
    for k: 0..ra.count - 1 if !irsim_is_close(s, ra[k], rb[k]) return false;
    return true;
}

// DenseMap<unsigned, DenseSet<unsigned>>: a Dm32 whose values index `sets`
Gvn_Mapping :: struct {
    map: Dm32;
    sets: [..] Dm32;
}
gm_init :: (m: *Gvn_Mapping) { dm32_init(*m.map); m.sets.allocator = temp; }
gm_clear :: (m: *Gvn_Mapping) { dm32_clear(*m.map); m.sets.count = 0; }
gm_set :: inline (m: *Gvn_Mapping, bucket: s64) -> *Dm32 { return *m.sets[m.map.vals[bucket]]; }
// insert(make_pair(key, set)): the set is stored only when the key is new
gm_insert :: (m: *Gvn_Mapping, key: u32, set: Dm32) -> bucket: s64, inserted: bool {
    f, b := dm32_lookup(*m.map, key);
    if f return b, false;
    array_add(*m.sets, set);
    b2, ins := dm32_insert(*m.map, key, cast(u32) m.sets.count - 1);
    return b2, ins;
}
gm_find :: (m: *Gvn_Mapping, key: u32) -> *Dm32 {
    f, b := dm32_lookup(*m.map, key);
    if !f return null;
    return gm_set(m, b);
}

// checkNumberingAndReplaceCommutative
irsim_check_numbering_commutative :: (s: *Irsim, src: u32, cur: *Gvn_Mapping, src_ops: [] Value_Id, target: *Dm32) -> bool {
    for v: src_ops {
        _, arg := irsim_get_gvn(s, src, v);
        b := gm_insert(cur, arg, dm32_copy(target));
        set := gm_set(cur, b);
        new_set: Dm32; dm32_init(*new_set);
        for k: dm32_keys(set) if dm32_contains(target, k) dm32_insert(*new_set, k);
        if new_set.n == 0 return false;
        if new_set.n != set.n { tmp := set.*; set.* = new_set; new_set = tmp; }
        if set.n != 1 continue;
        to_remove := dm32_first(set);
        for inner: src_ops {
            if inner == v continue;
            _, iv := irsim_get_gvn(s, src, inner);
            other := gm_find(cur, iv);
            if !other continue;
            dm32_erase(other, to_remove);
            if other.n == 0 return false;
        }
    }
    return true;
}
// checkNumberingAndReplace
irsim_check_numbering :: (cur: *Gvn_Mapping, src: u32, tgt: u32) -> bool {
    b, inserted := gm_insert(cur, src, dm32_set_of(tgt));
    if inserted return true;
    set := gm_set(cur, b);
    if set.n > 1 && dm32_contains(set, tgt) {
        dm32_clear(set);
        dm32_insert(set, tgt);
        return true;
    }
    return dm32_contains(set, tgt);
}
irsim_compare_non_commutative :: (s: *Irsim, a: u32, ops_a: [] Value_Id, map_a: *Gvn_Mapping, b: u32, ops_b: [] Value_Id, map_b: *Gvn_Mapping) -> bool {
    for k: 0..ops_a.count - 1 {
        _, va := irsim_get_gvn(s, a, ops_a[k]);
        _, vb := irsim_get_gvn(s, b, ops_b[k]);
        if !irsim_check_numbering(map_a, va, vb) return false;
        if !irsim_check_numbering(map_b, vb, va) return false;
    }
    return true;
}
irsim_compare_commutative :: (s: *Irsim, a: u32, ops_a: [] Value_Id, map_a: *Gvn_Mapping, b: u32, ops_b: [] Value_Id, map_b: *Gvn_Mapping) -> bool {
    nums_a: Dm32; dm32_init(*nums_a);
    nums_b: Dm32; dm32_init(*nums_b);
    for k: 0..ops_a.count - 1 {
        _, va := irsim_get_gvn(s, a, ops_a[k]);
        _, vb := irsim_get_gvn(s, b, ops_b[k]);
        dm32_insert(*nums_a, va);
        dm32_insert(*nums_b, vb);
    }
    if !irsim_check_numbering_commutative(s, a, map_a, ops_a, *nums_b) return false;
    if !irsim_check_numbering_commutative(s, b, map_b, ops_b, *nums_a) return false;
    return true;
}
// compareAssignmentMapping
irsim_compare_assignment :: (ia: u32, ib: u32, map_a: *Gvn_Mapping, map_b: *Gvn_Mapping) -> bool {
    b, inserted := gm_insert(map_a, ia, dm32_set_of(ib));
    set := gm_set(map_a, b);
    if !inserted && !dm32_contains(set, ib) return false;
    else if set.n != 1 {
        others := dm32_keys(set);
        for o: others {
            if o == ib continue;
            other := gm_find(map_a, o);
            if !other continue;
            dm32_erase(other, ia);
        }
        _, b2 := dm32_lookup(*map_a.map, ia);
        dm32_erase_bucket(*map_a.map, b2);
        gm_insert(map_a, ia, dm32_set_of(ib));
    }
    return true;
}
// checkRelativeLocations
irsim_check_relative_locations :: (s: *Irsim, a: u32, rel_a: s32, v_a: Value_Id, b: u32, rel_b: s32, v_b: Value_Id) -> bool {
    in_a := false; for irsim_cand_blocks(s, a) if it == v_a { in_a = true; break; }
    in_b := false; for irsim_cand_blocks(s, b) if it == v_b { in_b = true; break; }
    if in_a != in_b return false;
    if in_a return rel_a == rel_b;
    return true;
}
// compareStructure(A, B, MappingA, MappingB)
irsim_compare_structure :: (s: *Irsim, a: u32, b: u32, map_a: *Gvn_Mapping, map_b: *Gvn_Mapping) -> bool {
    if s.cands[a].len != s.cands[b].len return false;
    if s.cands[a].n2v.count != s.cands[b].n2v.count return false;
    ra := irsim_cand_rows(s, a); rb := irsim_cand_rows(s, b);
    for k: 0..ra.count - 1 {
        da := ra[k]; db := rb[k];
        if !irsim_is_close(s, da, db) return false;
        ia := s.data[da].inst; ib := s.data[db].inst;
        if !s.data[da].legal || !s.data[db].legal return false;
        ops_a := s.data[da].ops; ops_b := s.data[db].ops;
        _, va := irsim_get_gvn(s, a, ia);
        _, vb := irsim_get_gvn(s, b, ib);
        if !irsim_compare_assignment(va, vb, map_a, map_b) return false;
        if !irsim_compare_assignment(vb, va, map_b, map_a) return false;
        if inst_is_commutative(ia) && !is_fp_math_operator(ia) && !irsim_is_intrinsic_inst(ia) {
            if !irsim_compare_commutative(s, a, ops_a, map_a, b, ops_b, map_b) return false;
            continue;
        }
        if !irsim_compare_non_commutative(s, a, ops_a, map_a, b, ops_b, map_b) return false;
        oa := inst_op(ia);
        if !(oa == .BR || oa == .CONDBR || oa == .PHI) || oa != inst_op(ib) continue;
        rel_a := s.data[da].rel_locs; rel_b := s.data[db].rel_locs;
        abl := irsim_block_oper_vals(s, da); bbl := irsim_block_oper_vals(s, db);
        if rel_a.count != rel_b.count && abl.count != bbl.count return false;
        n := min(min(rel_a.count, rel_b.count), min(abl.count, bbl.count));
        for j: 0..n - 1 if !irsim_check_relative_locations(s, a, rel_a[j], abl[j], b, rel_b[j], bbl[j]) return false;
    }
    return true;
}

// overlap
irsim_overlap :: (s: *Irsim, a: u32, b: u32) -> bool {
    does :: (s: *Irsim, x: u32, y: u32) -> bool { return s.cands[x].start_idx <= irsim_end_idx(s, y) && s.cands[y].start_idx >= s.cands[x].start_idx; }
    return does(s, a, b) || does(s, b, a);
}

irsim_addr_order_fatal :: (what: string) {
    fatal("ir-similarity: % depends on the heap address order in LLVM (DenseSet of pointers); not reproducible", what);
}

// createCanonicalMappingFor: canonical numbers in NumberToValue (DenseMap<unsigned, Value *>) iteration order
irsim_create_canonical_mapping :: (s: *Irsim, c: u32) {
    cc := *s.cands[c];
    m: Dm32; dm32_init(*m);
    for k: 1..cc.n2v.count dm32_insert(*m, cast(u32) k);
    canon: u32 = 0;
    for n: dm32_keys(*m) {
        u32map_set(*cc.n2c, n, canon);
        u32map_set(*cc.c2n, canon, n);
        canon += 1;
    }
}
irsim_canon_insert :: (cc: *Irsim_Cand, canon: u32, gvn: u32) {
    // CanonNumToNumber.insert / NumberToCanonNum.insert keep the first entry
    found, old := u32map_find(*cc.c2n, canon);
    if found {
        if old != gvn irsim_addr_order_fatal("the canonical numbering of a candidate");
    } else u32map_set(*cc.c2n, canon, gvn);
    if !u32map_contains(*cc.n2c, gvn) u32map_set(*cc.n2c, gvn, canon);
}
// createCanonicalRelationFrom(SourceCand, ToSourceMapping, FromSourceMapping)
irsim_canonical_relation_from_mapping :: (s: *Irsim, c: u32, src: u32, to_src: *Gvn_Mapping, from_src: *Gvn_Mapping) {
    used: Dm32; dm32_init(*used);
    cc := *s.cands[c];
    for bk: 0..to_src.map.keys.count - 1 {
        if !to_src.map.used[bk] continue;
        source_gvn := to_src.map.keys[bk];
        set := gm_set(to_src, bk);
        result: u32;
        if set.n > 1 {
            found := false;
            for v: dm32_keys(set) {
                if dm32_contains(*used, v) continue;
                fs := gm_find(from_src, v);
                if !fs fatal("internal: ir-similarity: no reverse mapping");
                if !dm32_contains(fs, source_gvn) continue;
                found = true;
                result = v;
                break;
            }
            if !found fatal("internal: ir-similarity: could not find matching value for source GVN");
        } else result = dm32_first(set);
        dm32_insert(*used, result);
        f, canon := irsim_canon(s, src, result);
        if !f fatal("internal: ir-similarity: no canonical number");
        irsim_canon_insert(cc, canon, source_gvn);
    }
    start_bb := irsim_start_bb(s, c);
    for bb: irsim_cand_blocks(s, c) {
        _, bb_gvn := irsim_get_gvn(s, c, bb);
        if u32map_contains(*cc.n2c, bb_gvn) continue;
        first := ifx bb == start_bb then irsim_front_inst(s, c) else block_first(bb);
        _, first_gvn := irsim_get_gvn(s, c, first);
        _, first_canon := irsim_canon(s, c, first_gvn);
        _, source_gvn := irsim_from_canon(s, src, first_canon);
        _, source_v := irsim_from_gvn(s, src, source_gvn);
        _, source_bb_gvn := irsim_get_gvn(s, src, inst_block(source_v));
        _, source_canon_bb := irsim_canon(s, src, source_bb_gvn);
        irsim_canon_insert(cc, source_canon_bb, bb_gvn);
    }
}
// createCanonicalRelationFrom(SourceCand, SourceCandLarge, TargetCandLarge), computed into `pairs` (canonical number,
// GVN of c) in ValueToNumber order; false when a lookup fails (LLVM would dereference an empty optional) or two values
// get the same canonical number (LLVM keeps the first in DenseMap<Value *> address order)
irsim_relation_through_larger :: (s: *Irsim, c: u32, src: u32, src_large: u32, tgt_large: u32, pairs: *[..] [2] u32) -> bool {
    pairs.count = 0;
    cc := *s.cands[c];
    seen: [..] u32; seen.allocator = temp;
    for v, k: cc.n2v {
        tgt_gvn := cast(u32) k + 1;
        f1, large_tgt_gvn := irsim_get_gvn(s, tgt_large, v);
        if !f1 return false;
        f2, tgt_canon := irsim_canon(s, tgt_large, large_tgt_gvn);
        if !f2 return false;
        f3, large_src_gvn := irsim_from_canon(s, src_large, tgt_canon);
        if !f3 return false;
        f4, large_src_v := irsim_from_gvn(s, src_large, large_src_gvn);
        if !f4 return false;
        f5, src_gvn := irsim_get_gvn(s, src, large_src_v);
        if !f5 return false;
        f6, src_canon := irsim_canon(s, src, src_gvn);
        if !f6 return false;
        if u32map_contains(*seen, src_canon) irsim_addr_order_fatal("the canonical numbering through a larger candidate");
        u32map_set(*seen, src_canon, 1);
        array_add(pairs, .[src_canon, tgt_gvn]);
    }
    return true;
}
// The larger candidates come from DenseSet<IRSimilarityCandidate *> walks (address order) when several candidates
// of the chosen group contain CandA or CandB: every choice that LLVM could make without crashing must give the same
// numbering.
irsim_canonical_relation_from_larger :: (s: *Irsim, c: u32, src: u32, choices: [] [2] u32) {
    result: [..] [2] u32; result.allocator = temp;
    trial: [..] [2] u32; trial.allocator = temp;
    have := false;
    // the front and back instructions are mapped first: a choice whose larger candidates are not aligned with A and B
    // fails there (cheaply) and fails the full mapping the same way
    maps_one :: (s: *Irsim, v: Value_Id, src: u32, src_large: u32, tgt_large: u32) -> bool {
        f1, g1 := irsim_get_gvn(s, tgt_large, v); if !f1 return false;
        f2, c2 := irsim_canon(s, tgt_large, g1); if !f2 return false;
        f3, g3 := irsim_from_canon(s, src_large, c2); if !f3 return false;
        f4, v4 := irsim_from_gvn(s, src_large, g3); if !f4 return false;
        f5, g5 := irsim_get_gvn(s, src, v4); if !f5 return false;
        f6 := irsim_canon(s, src, g5);
        return f6;
    }
    front := irsim_front_inst(s, c); back := irsim_back_inst(s, c);
    for ch: choices {
        if choices.count > 1 && (!maps_one(s, front, src, ch[0], ch[1]) || !maps_one(s, back, src, ch[0], ch[1])) continue;
        if !irsim_relation_through_larger(s, c, src, ch[0], ch[1], *trial) {
            if choices.count == 1 fatal("internal: ir-similarity: incomplete numbering through a larger candidate");
            continue;
        }
        if !have { for trial array_add(*result, it); have = true; continue; }
        same := trial.count == result.count;
        if same for trial if it[0] != result[it_index][0] || it[1] != result[it_index][1] { same = false; break; }
        if !same irsim_addr_order_fatal("the choice of a larger candidate (different numberings)");
    }
    if !have irsim_addr_order_fatal(tprint("the choice of a larger candidate (no consistent choice of %)", choices.count));
    cc := *s.cands[c];
    for result {
        u32map_set(*cc.c2n, it[0], it[1]);
        u32map_set(*cc.n2c, it[1], it[0]);
    }
}

Irsim_Find_State :: struct {
    index_to_cands: Table(u32, [..] u32);   // IndexToIncludedCand (DenseSet<IRSimilarityCandidate *>, insertion order here)
    cand_to_group: Table(u32, u32);         // CandToGroup: candidate -> overall group number
}

// CheckLargerCands: (found, larger A, larger B)
irsim_check_larger_cands :: (s: *Irsim, a: u32, b: u32, st: *Irsim_Find_State) -> bool, [] [2] u32 {
    collect :: (s: *Irsim, x: u32, st: *Irsim_Find_State, groups: *Dm32, per_group: *Table(u32, [..] u32)) -> bool {
        l := table_find_pointer(*st.index_to_cands, s.cands[x].start_idx);
        if !l return false;
        for m: l.* {
            if s.cands[m].start_idx > s.cands[x].start_idx || irsim_end_idx(s, m) < irsim_end_idx(s, x) continue;
            _, g := table_find(*st.cand_to_group, m);
            pl := table_find_pointer(per_group, g);
            if !pl { e: [..] u32; e.allocator = temp; pl = table_set(per_group, g, e); }
            array_add(pl, m);
            dm32_insert(groups, g);
        }
        return true;
    }
    groups_a: Dm32; dm32_init(*groups_a);
    groups_b: Dm32; dm32_init(*groups_b);
    per_a: Table(u32, [..] u32); per_a.allocator = temp;
    per_b: Table(u32, [..] u32); per_b.allocator = temp;
    if !collect(s, a, st, *groups_a, *per_a) return false, .[];
    if !collect(s, b, st, *groups_b, *per_b) return false, .[];
    // The group sets are filled in pointer order. Linear probing makes the set of occupied buckets independent of
    // that order, and set_intersect's remove_if + rehash places every surviving group at its home bucket when the
    // survivors' home buckets are distinct: then begin() is order independent. Otherwise every surviving group is a
    // possible choice.
    removed := false;
    for bk: 0..groups_a.keys.count - 1 {
        if !groups_a.used[bk] continue;
        if !dm32_contains(*groups_b, groups_a.keys[bk]) { groups_a.used[bk] = false; groups_a.n -= 1; removed = true; }
    }
    if removed dm32_grow(*groups_a, dm32_nb(*groups_a));
    if groups_a.n == 0 return false, .[];
    unique_first := true;
    {
        nb := dm32_nb(*groups_a);
        ks := dm32_keys(*groups_a);
        for i: 0..ks.count - 1 for j: i + 1..ks.count - 1 if dm32_home(ks[i], nb) == dm32_home(ks[j], nb) unique_first = false;
    }
    choices: [..] [2] u32; choices.allocator = temp;
    for g: dm32_keys(*groups_a) {
        la := table_find_pointer(*per_a, g);
        lb := table_find_pointer(*per_b, g);
        // IncludedGroupAndCandA.insert keeps the first candidate of the group in DenseSet<pointer> order: every
        // candidate of the group is a possible choice
        for x: la.* for y: lb.* array_add(*choices, .[x, y]);
        if unique_first break;
    }
    return true, choices;
}

// findCandidateStructures (StructuralGroups: a Dm32 whose values index `group_lists`)
irsim_find_candidate_structures :: (s: *Irsim, cands: [] u32, structural: *Dm32, group_lists: *[..] [..] u32, st: *Irsim_Find_State) {
    local_group: Table(u32, u32); local_group.allocator = temp;
    current_group: u32 = 0;
    map_a: Gvn_Mapping; gm_init(*map_a);
    map_b: Gvn_Mapping; gm_init(*map_b);
    for ci, k: cands {
        outer: u32;
        found, g := table_find(*local_group, ci);
        if found outer = g;
        else { table_set(*local_group, ci, current_group); outer = current_group; current_group += 1; }
        fg, gl := dm32_get(structural, outer);
        if !fg {
            irsim_create_canonical_mapping(s, ci);
            l: [..] u32; l.allocator = temp;
            array_add(*l, ci);
            array_add(group_lists, l);
            gl = cast(u32) group_lists.count - 1;
            dm32_insert(structural, outer, gl);
        }
        for j: k + 1..cands.count - 1 {
            inner := cands[j];
            if table_contains(*local_group, inner) continue;
            has_larger, choices := irsim_check_larger_cands(s, ci, inner, st);
            if has_larger {
                irsim_canonical_relation_from_larger(s, inner, ci, choices);
                table_set(*local_group, inner, outer);
                array_add(*group_lists.*[gl], inner);
                continue;
            }
            gm_clear(*map_a);
            gm_clear(*map_b);
            if !irsim_compare_structure(s, ci, inner, *map_a, *map_b) continue;
            irsim_canonical_relation_from_mapping(s, inner, ci, *map_a, *map_b);
            table_set(*local_group, inner, outer);
            array_add(*group_lists.*[gl], inner);
        }
    }
}

// findCandidates
irsim_find_candidates :: (s: *Irsim, list: [] u32, ints: [] u32) {
    t0 := seconds_since_init();
    st_tree := st_build(ints);
    rses := st_repeated_substrings(*st_tree);
    if getenv("JAI_IRSIM_TIME") != null print("irsim: suffix tree % s, % substrings\n", seconds_since_init() - t0, rses.count);
    // stable_sort by length, longest first
    sorted: [..] St_Repeated; sorted.allocator = temp;
    array_reserve(*sorted, rses.count);
    lens: [..] u32; lens.allocator = temp;
    for rses { seen := false; for l: lens if l == it.length { seen = true; break; } if !seen array_add(*lens, it.length); }
    quick_sort(lens, (a: u32, b: u32) -> s64 { return cast(s64) b - cast(s64) a; });
    for l: lens for rses if it.length == l array_add(*sorted, it);

    fs: Irsim_Find_State;
    fs.index_to_cands.allocator = temp; fs.cand_to_group.allocator = temp;
    structural: Dm32; dm32_init(*structural);
    group_lists: [..] [..] u32; group_lists.allocator = temp;
    cands: [..] u32; cands.allocator = temp;
    for rs: sorted {
        // createCandidatesFromSuffixTree
        cands.count = 0;
        if rs.length >= 2 {
            for start: rs.starts {
                end := start + rs.length - 1;
                illegal := false;
                for k: start..end if ints[k] > s.illegal_number { illegal = true; break; }
                if illegal continue;
                array_add(*cands, irsim_new_cand(s, start, rs.length, list[start], list[end]));
            }
        }
        if cands.count < 2 continue;
        group_lists.count = 0;
        irsim_find_candidate_structures(s, cands, *structural, *group_lists, *fs);
        for key: dm32_keys(*structural) {
            _, gl := dm32_get(*structural, key);
            grp := group_lists[gl];
            if grp.count <= 1 continue;
            copy: [..] u32; copy.allocator = temp;
            for grp array_add(*copy, it);
            array_add(*s.groups, copy);
            gnum := cast(u32) s.groups.count - 1;
            for c: copy {
                for idx: s.cands[c].start_idx..irsim_end_idx(s, c) {
                    l := table_find_pointer(*fs.index_to_cands, idx);
                    if !l { e: [..] u32; e.allocator = temp; l = table_set(*fs.index_to_cands, idx, e); }
                    present := false;
                    for l.* if it == c { present = true; break; }
                    if !present array_add(l, c);
                }
                if !table_contains(*fs.cand_to_group, c) table_set(*fs.cand_to_group, c, gnum);
            }
        }
        dm32_clear(*structural);
    }
}

// IRSimilarityIdentifier::findSimilarity(Module &M) with IRSimilarityAnalysis's options
irsim_find_similarity :: () -> *Irsim {
    s := New(Irsim,, allocator = temp);
    s.data.allocator = temp; s.cands.allocator = temp; s.groups.allocator = temp;
    s.int_map_buckets.allocator = temp; s.int_map_num.allocator = temp; s.bb_number.allocator = temp;
    s.enable_branches = !irsim_cl.disable_branches;
    s.enable_indirect_calls = !irsim_cl.disable_indirect_calls;
    s.match_calls_by_name = irsim_cl.match_calls_by_name;
    s.enable_intrinsics = !irsim_cl.disable_intrinsics;
    s.enable_musttail_calls = false;
    sentinel: Irsim_Data;
    sentinel.prev = 0; sentinel.next = 0;
    array_add(*s.data, sentinel);

    list: [..] u32; list.allocator = temp;
    ints: [..] u32; ints.allocator = temp;
    // populateMapper: initializeForBBs numbers the blocks of every function
    bbn: u32 = 0;
    for f: ir.m_functions for bb: fn_blocks(f) { table_set(*s.bb_number, bb, bbn); bbn += 1; }
    for f: ir.m_functions {
        if fn_entry(f) == NONE continue;
        for bb: fn_blocks(f) irsim_convert_block(s, bb, *list, *ints);
        irsim_map_illegal(s, NONE, *ints, *list, true);
        // Mapper.IDL->push_back(*InstrListForModule.back()): when the function ended on an illegal instruction this
        // pushes a row that is already in the list (simple_ilist then links it to itself)
        if list.count > 0 irsim_ilist_push_back(s, list[list.count - 1]);
    }
    t0 := seconds_since_init();
    irsim_find_candidates(s, list, ints);
    if getenv("JAI_IRSIM_TIME") != null print("irsim: % instructions, findCandidates % s\n", ints.count, seconds_since_init() - t0);
    return s;
}

// IRSimilarityAnalysisPrinterPass (print-ir-similarity), printing to errs()
print_ir_similarity_run :: () {
    s := irsim_find_similarity();
    sb: String_Builder; sb.allocator = temp;
    for grp: s.groups {
        print_to_builder(*sb, "% candidates of length %.  Found in: \n", grp.count, s.cands[grp[0]].len);
        for c: grp {
            front := irsim_front_inst(s, c);
            bb := inst_block(front);
            print_to_builder(*sb, "  Function: %, Basic Block: ", vname(block_fn(bb)));
            if vname(bb) == "" append(*sb, "(unnamed)");
            else append(*sb, vname(bb));
            append(*sb, "\n    Start Instruction: ");
            append(*sb, inst_to_string(front));
            append(*sb, "\n      End Instruction: ");
            append(*sb, inst_to_string(irsim_back_inst(s, c)));
            append(*sb, "\n");
        }
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
}

