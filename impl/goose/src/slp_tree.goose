// SLPVectorizer: BoUpSLP's state and the TreeEntry graph. Port of the BoUpSLP class body of
// llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp (lines 1980-6540): the TreeEntry class (Scalars, Operands,
// ReuseShuffleIndices, ReorderIndices, State, CombinedOp, UserTreeIndex, CombinedEntriesWithIndices,
// CopyableElements, InstructionsState, isSame, getVectorFactor, findLaneForValue, getOrdered, dump),
// newTreeEntry, getTreeEntries, getSameValuesTreeEntry, hasSameNode, isVectorized, areAllUsersVectorized,
// getOperandEntry, the non-vectorizable load cache, deleteTree and the per-function state (BoUpSLP's constructor:
// EphValues, MaxVecRegSize, MinVecRegSize).
//
// Data layout: tree entries are rows of `slp_te`; their lists are runs in `slp_vp` (values: Scalars), `slp_ip`
// (ints: ReuseShuffleIndices, ReorderIndices, CombinedEntriesWithIndices pairs) and `slp_opl` (one run of operand
// lists per entry, each a run of `slp_vp`). A run that changes length is re-allocated at the end of its pool. All
// pools are per tree (deleteTree truncates them). Value-keyed maps are slots of slp_util.goose's hash table.
import std;
import assume;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import datalayout;
import pm;
import flags;
import inline_cost;
import tti_vec;
import slp_util;

// TreeEntry::EntryState
let TE_VECTORIZE: i32 = 0;
let TE_SCATTER: i32 = 1;
let TE_STRIDED: i32 = 2;
let TE_EXPAND: i32 = 3;
let TE_COMPRESS: i32 = 4;
let TE_GATHER: i32 = 5;
let TE_COMBINED: i32 = 6;
let TE_SPLIT: i32 = 7;
// TreeEntry::CombinedOpcode
let CO_NONE: i32 = -1;
let CO_MINMAX: i32 = 69;
let CO_FMULADD: i32 = 70;
let CO_RBITCAST: i32 = 71;
let CO_RBITCAST_BSWAP: i32 = 72;
let CO_RBITCAST_LOADS: i32 = 73;
let CO_RBITCAST_BSWAP_LOADS: i32 = 74;
let CO_RCMP_BITCAST: i32 = 75;

struct SRun { at: i32, n: i32 }
struct STE {
    state: i32, cop: i32,
    sc: i32, nsc: i32,
    reuse: i32, nreuse: i32,
    reord: i32, nreord: i32,
    ops: i32, nops: i32,
    ui_te: i32, ui_edge: i64,
    s_main: i32, s_alt: i32, s_copy: bool,
    inter: i32, no_sched: bool,
    comb: i32, ncomb: i32,
    ncopyable: i32,
    vv: i32,
}
var slp_te: STE[>..];
var slp_vp: i32[>..];
var slp_ip: i32[>..];
var slp_opl: SRun[>..];
struct SLk { x: i32, next: i32 }
var slp_lk: SLk[>..];

// hash table slots (slp_util.goose sh_*)
let SH_S2TE: i64 = 0;       // ScalarToTreeEntries: value -> link list of entries
let SH_SPLIT: i64 = 1;      // ScalarsInSplitNodes
let SH_V2G: i64 = 2;        // ValueToGatherNodes (SetVector per value)
let SH_MUSTG: i64 = 3;      // MustGather
let SH_NSF: i64 = 4;        // NonScheduledFirst
let SH_OP2TE: i64 = 5;      // OperandsToTreeEntry: (entry, edge) -> entry
let SH_COPYABLE: i64 = 6;   // TreeEntry::CopyableElements: (entry, value)
let SH_DELNODES: i64 = 7;   // DeletedNodes
let SH_T2G: i64 = 8;        // TransformedToGatherNodes: entry -> cost
let SH_EPH: i64 = 9;        // EphValues (per function)
let SH_ALIAS: i64 = 10;     // AliasCache (per function): (inst1, inst2) -> 1 + aliased
let SH_NVL: i64 = 11;       // ListOfKnonwnNonVectorizableLoads (per function): hash -> link list of runs
let SH_SDMAP: i64 = 12;     // BlockScheduling::ScheduleDataMap (per function): inst -> schedule data
let SH_SBUN: i64 = 13;      // BlockScheduling::ScheduledBundles: inst -> link list of bundles
let SH_READY: i64 = 14;     // ReadyInsts membership: (bs, entity)
let SH_DELINST: i64 = 15;   // DeletedInstructions (per function)
let SH_LANE: i64 = 16;      // TreeEntry::ValueToLane: (entry, value) -> lane
let SH_BSMAP: i64 = 17;     // BlocksSchedules (per function): block -> bs
let SH_INSTRSZ: i64 = 18;   // InstrElementSize (per tree)
let SH_UIL: i64 = 19;       // *UserIgnoreList
let SH_ANRR: i64 = 20;      // AnalyzedReductionsRoots (per function)
let SH_ANRV: i64 = 21;      // AnalyzedReductionVals (per function)
let SH_ANMBW: i64 = 22;     // AnalyzedMinBWVals (per function)
let SH_TMP0: i64 = 40;      // short-lived local sets/maps
let SH_TMP1: i64 = 41;
let SH_TMP2: i64 = 42;
let SH_TMP3: i64 = 43;
let SH_TMP4: i64 = 44;
let SH_TMP5: i64 = 45;

// per-tree state
var slp_gathered_loads_first: i64 = -1;     // GatheredLoadsEntriesFirst
var slp_graph_transform_mode: bool = false; // IsGraphTransformMode
var slp_cast_bw_valid: bool = false;        // CastMaxMinBWSizes
var slp_cast_bw_max: i64 = 0;
var slp_cast_bw_min: i64 = 0;
var slp_base_graph_size: i64 = 1;
var slp_reduction_bw: i64 = 0;
var slp_uil_on: bool = false;               // UserIgnoreList != nullptr
var slp_uil_n: i64 = 0;
var slp_loop_nest: i32[>..<];               // CurrentLoopNest
var slp_merged_btcs: i32[>..<];             // MergedLoopBTCs (-1 = null)
var slp_load_entries: i32[>..<];            // LoadEntriesToVectorize (SetVector<unsigned>)
var slp_extra_bw_nodes: i32[>..<];          // ExtraBitWidthNodes (insertion order; see minbw for the DenseSet order)
// per-function state
var slp_fn: i32 = -1;
var slp_max_vreg: i64 = 128;
var slp_min_vreg: i64 = 128;
var slp_nvl_runs: i32[>..];                 // the sequences of ListOfKnonwnNonVectorizableLoads (runs: len, values...)
var slp_has_eph: bool = false;

fn slp_tree_size() -> i64 { slp_te.len }

// ---------------------------------------------------------------- link lists
fn slp_lk_push_tail(slot: i64, key: i64, x: i32) {
    let h = sh_get(slot, key, 0, -1) as i32;
    let n = slp_lk.len as i32;
    slp_lk.push(SLk { x: x, next: -1 });
    if h < 0 { sh_set(slot, key, 0, n as i64); return; }
    var c = h;
    while slp_lk[c].next >= 0 { c = slp_lk[c].next; }
    slp_lk[c].next = n;
}
fn slp_lk_head(slot: i64, key: i64) -> i32 { sh_get(slot, key, 0, -1) as i32 }
fn slp_lk_contains(slot: i64, key: i64, x: i32) -> bool {
    var c = slp_lk_head(slot, key);
    while c >= 0 { if slp_lk[c].x == x { return true; } c = slp_lk[c].next; }
    return false;
}
fn slp_lk_count(slot: i64, key: i64) -> i64 {
    var n: i64 = 0;
    var c = slp_lk_head(slot, key);
    while c >= 0 { n++; c = slp_lk[c].next; }
    return n;
}
// removes the last element
fn slp_lk_pop_back(slot: i64, key: i64) {
    let h = slp_lk_head(slot, key);
    if h < 0 { return; }
    if slp_lk[h].next < 0 { sh_set(slot, key, 0, -1); return; }
    var c = h;
    while slp_lk[slp_lk[c].next].next >= 0 { c = slp_lk[c].next; }
    slp_lk[c].next = -1;
}

// ---------------------------------------------------------------- runs
fn slp_vrun(xs: const i32[:]) -> i32 { let at = slp_vp.len as i32; for x in xs { slp_vp.push(x); } return at; }
fn slp_irun(xs: const i32[:]) -> i32 { let at = slp_ip.len as i32; for x in xs { slp_ip.push(x); } return at; }
fn te_scalars(te: i32) -> const i32[:] { let e = slp_te[te]; return slp_vp[(e.sc as i64)..(e.sc + e.nsc) as i64]; }
fn te_scalar(te: i32, k: i64) -> i32 { slp_vp[slp_te[te].sc as i64 + k] }
fn te_nscalars(te: i32) -> i64 { slp_te[te].nsc as i64 }
fn te_reuse(te: i32) -> const i32[:] { let e = slp_te[te]; return slp_ip[(e.reuse as i64)..(e.reuse + e.nreuse) as i64]; }
fn te_reorder(te: i32) -> const i32[:] { let e = slp_te[te]; return slp_ip[(e.reord as i64)..(e.reord + e.nreord) as i64]; }
fn te_set_reuse(te: i32, xs: const i32[:]) { slp_te[te].reuse = slp_irun(xs); slp_te[te].nreuse = xs.len as i32; }
fn te_set_reorder(te: i32, xs: const i32[:]) { slp_te[te].reord = slp_irun(xs); slp_te[te].nreord = xs.len as i32; }
fn te_set_scalars(te: i32, xs: const i32[:]) { slp_te[te].sc = slp_vrun(xs); slp_te[te].nsc = xs.len as i32; }
fn te_num_operands(te: i32) -> i64 { slp_te[te].nops as i64 }
fn te_operand(te: i32, k: i64) -> const i32[:] {
    let r = slp_opl[slp_te[te].ops as i64 + k];
    return slp_vp[(r.at as i64)..(r.at + r.n) as i64];
}
fn te_operand_run(te: i32, k: i64) -> SRun { slp_opl[slp_te[te].ops as i64 + k] }
// setOperand(OpIdx, OpVL) for OpIdx = 0..n-1 in order (setOperands)
fn te_set_operand(te: i32, k: i64, xs: const i32[:]) {
    let e = slp_te[te];
    if (e.nops as i64) < k + 1 {
        // Operands.resize(OpIdx + 1): move the run of operand lists to the end of the pool
        let at = slp_opl.len as i32;
        for j in e.nops as i64 { slp_opl.push(slp_opl[e.ops as i64 + j]); }
        for j in (e.nops as i64)..(k + 1) { slp_opl.push(SRun { at: 0, n: 0 }); }
        slp_te[te].ops = at;
        slp_te[te].nops = (k + 1) as i32;
    }
    let r = slp_vrun(xs);
    slp_opl[slp_te[te].ops as i64 + k] = SRun { at: r, n: xs.len as i32 };
}
fn te_is_gather(te: i32) -> bool { slp_te[te].state == TE_GATHER }
fn te_has_state(te: i32) -> bool { slp_te[te].s_main >= 0 && slp_te[te].s_alt >= 0 }
fn te_s(te: i32) -> SIS { let e = slp_te[te]; return SIS { main: e.s_main, alt: e.s_alt, copy: e.s_copy }; }
fn te_main(te: i32) -> i32 { slp_te[te].s_main }
fn te_alt(te: i32) -> i32 { slp_te[te].s_alt }
fn te_opcode(te: i32) -> i64 { iop(slp_te[te].s_main) }
fn te_alt_opcode(te: i32) -> i64 { iop(slp_te[te].s_alt) }
fn te_is_alt_shuffle(te: i32) -> bool { slp_te[te].s_main != slp_te[te].s_alt }
fn te_set_operations(te: i32, s: SIS) { slp_te[te].s_main = s.main; slp_te[te].s_alt = s.alt; slp_te[te].s_copy = s.copy; }
fn te_vector_factor(te: i32) -> i64 { let e = slp_te[te]; return if e.nreuse > 0 { e.nreuse as i64 } else { e.nsc as i64 }; }
fn te_is_copyable_element(te: i32, v: i32) -> bool { slp_te[te].ncopyable > 0 && sh_has(SH_COPYABLE, te as i64, v as i64) }
fn te_has_copyable_elements(te: i32) -> bool { slp_te[te].ncopyable > 0 }
fn te_add_copyable_element(te: i32, v: i32) {
    if sh_add(SH_COPYABLE, te as i64, v as i64) { slp_te[te].ncopyable += 1; }
}
// TreeEntry::isExpandedBinOp / isExpandedOperand
fn te_is_expanded_binop(te: i32, v: i32) -> bool {
    if te_is_copyable_element(te, v) { return false; }
    return sis_is_expanded_binop(te_s(te), v);
}
fn te_is_expanded_operand(te: i32, i: i32, idx: i64) -> bool {
    if te_is_copyable_element(te, i) { return false; }
    if !te_is_expanded_binop(te, i) { return false; }
    return sis_is_expanded_operand(te_s(te), i, idx);
}
fn te_matching(te: i32, i: i32) -> i32 { sis_matching(te_s(te), i) }
fn te_is_non_pow2_vec(te: i32) -> bool { !slp_is_pow2(te_nscalars(te)) }

// TreeEntry::isSame(VL)
fn te_is_same(te: i32, vl: const i32[:]) -> bool {
    fn same(vl: const i32[:], sc: const i32[:], mask: const i32[:]) -> bool {
        if mask.len != vl.len && vl.len == sc.len {
            for k in vl.len { if vl[k] != sc[k] { return false; } }
            return true;
        }
        if vl.len != mask.len { return false; }
        for k in vl.len {
            let v = vl[k];
            let m = mask[k];
            if is_undef_or_poison(v) && m == -1 { continue; }
            if m != -1 && v == sc[m as i64] { continue; }
            return false;
        }
        return true;
    }
    let sc = te_scalars(te);
    if slp_te[te].nreord > 0 {
        var mask: i32[>..<] = [];
        slp_inverse_permutation(te_reorder(te), mask);
        if vl.len == sc.len { return same(vl, sc, mask); }
        if vl.len == slp_te[te].nreuse as i64 {
            slp_add_mask(mask, te_reuse(te), false);
            return same(vl, sc, mask);
        }
        return false;
    }
    return same(vl, sc, te_reuse(te));
}
// TreeEntry::findLaneForValue(V) (the ValueToLane cache is never invalidated, as in LLVM)
fn te_find_lane(te: i32, v: i32) -> i64 {
    let c = sh_get(SH_LANE, te as i64, v as i64, -1);
    if c >= 0 { return c; }
    var lane = te_vector_factor(te);
    let n = te_nscalars(te);
    for k in n {
        if te_scalar(te, k) != v { continue; }
        lane = k;
        if slp_te[te].nreord > 0 { lane = te_reorder(te)[lane] as i64; }
        if slp_te[te].nreuse == 0 { break; }
        var found = -1;
        let ru = te_reuse(te);
        for j in ru.len { if ru[j] as i64 == lane { found = j; break; } }
        if found >= 0 { lane = found; break; }
    }
    sh_set(SH_LANE, te as i64, v as i64, lane);
    return lane;
}
// TreeEntry::getOrdered(Idx)
fn te_get_ordered(te: i32, idx: i64) -> i32 {
    if slp_te[te].nreord == 0 { return te_scalar(te, idx); }
    var mask: i32[>..<] = [];
    slp_inverse_permutation(te_reorder(te), mask);
    return te_scalar(te, mask[idx] as i64);
}
// TreeEntry::getCommonMask
fn te_common_mask(te: i32, mask: i32[>..<]&) {
    mask.clear();
    if slp_te[te].state == TE_SPLIT { return; }
    slp_inverse_permutation(te_reorder(te), mask);
    slp_add_mask(mask, te_reuse(te), false);
}
fn te_comb_n(te: i32) -> i64 { slp_te[te].ncomb as i64 }
fn te_comb_idx(te: i32, k: i64) -> i32 { slp_ip[slp_te[te].comb as i64 + 2 * k] }
fn te_comb_off(te: i32, k: i64) -> i32 { slp_ip[slp_te[te].comb as i64 + 2 * k + 1] }
fn te_comb_push(te: i32, idx: i32, off: i32) {
    let e = slp_te[te];
    let at = slp_ip.len as i32;
    for j in 2 * e.ncomb as i64 { slp_ip.push(slp_ip[e.comb as i64 + j]); }
    slp_ip.push(idx);
    slp_ip.push(off);
    slp_te[te].comb = at;
    slp_te[te].ncomb = e.ncomb + 1;
}

// ---------------------------------------------------------------- BoUpSLP queries
fn slp_tree_entries_head(v: i32) -> i32 { slp_lk_head(SH_S2TE, v as i64) }
fn slp_is_deleted_node(te: i32) -> bool { sh_has(SH_DELNODES, te as i64, 0) }
fn slp_is_transformed_to_gather(te: i32) -> bool { sh_has(SH_T2G, te as i64, 0) }
// isVectorized(V)
fn slp_is_vectorized(v: i32) -> bool {
    var c = slp_tree_entries_head(v);
    while c >= 0 {
        let te = slp_lk[c].x;
        if !slp_is_deleted_node(te) && !slp_is_transformed_to_gather(te) { return true; }
        c = slp_lk[c].next;
    }
    return false;
}
fn slp_has_tree_entries(v: i32) -> bool { slp_tree_entries_head(v) >= 0 }
fn slp_is_gathered(v: i32) -> bool { sh_has(SH_MUSTG, v as i64, 0) }
fn slp_is_not_scheduled(v: i32) -> bool { sh_has(SH_NSF, v as i64, 0) }
fn slp_is_deleted(i: i32) -> bool { sh_has(SH_DELINST, i as i64, 0) }
fn slp_uil_contains(v: i32) -> bool { slp_uil_on && sh_has(SH_UIL, v as i64, 0) }
// areAllUsersVectorized(I, VectorizedVals): with_set = VectorizedVals != nullptr (the set is the UserIgnoreList)
fn slp_are_all_users_vectorized(i: i32, with_set: bool) -> bool {
    if slp_has_one_use(i) && (!with_set || slp_uil_contains(i)) { return true; }
    var u = vals[i].first_use;
    while u >= 0 {
        let usr = uses[u].user;
        if !(slp_is_vectorized(usr) || slp_is_vector_like_inst_with_const_ops(usr) ||
             (is_inst_op(usr, OP_EXTRACTELEMENT) && slp_is_gathered(usr))) { return false; }
        u = uses[u].next;
    }
    return true;
}
// getSameValuesTreeEntry(V, VL, SameVF)
fn slp_same_values_tree_entry(v: i32, vl: const i32[:], same_vf: bool) -> i32 {
    var c = slp_tree_entries_head(v);
    while c >= 0 {
        let te = slp_lk[c].x;
        if (!same_vf || te_vector_factor(te) == vl.len) && te_is_same(te, vl) { return te; }
        c = slp_lk[c].next;
    }
    return -1;
}
// hasSameNode(S, VL)
fn slp_has_same_node(s: SIS, vl: const i32[:]) -> bool {
    if sis_valid(s) {
        var c = slp_tree_entries_head(s.main);
        while c >= 0 { if te_is_same(slp_lk[c].x, vl) { return true; } c = slp_lk[c].next; }
        c = slp_lk_head(SH_V2G, s.main as i64);
        while c >= 0 { if te_is_same(slp_lk[c].x, vl) { return true; } c = slp_lk[c].next; }
        return false;
    }
    sh_clear(SH_TMP5);
    for v in vl {
        if slp_is_constant(v) { continue; }
        var c = slp_lk_head(SH_V2G, v as i64);
        while c >= 0 {
            let te = slp_lk[c].x;
            c = slp_lk[c].next;
            if !sh_add(SH_TMP5, te as i64, 0) { continue; }
            if te_is_same(te, vl) { return true; }
        }
    }
    return false;
}
// getOperandEntry(E, Idx)
fn slp_operand_entry(te: i32, idx: i64) -> i32 {
    let r = sh_get(SH_OP2TE, te as i64, idx, -1) as i32;
    if r < 0 { fatal("internal: SLP: no operand entry"); }
    return r;
}
// ListOfKnonwnNonVectorizableLoads: registerNonVectorizableLoads / areKnownNonVectorizableLoads
fn slp_vl_hash(vl: const i32[:]) -> i64 {
    var h: u64 = 0xcbf29ce484222325;
    for v in vl { h = (h ^ (v as u64)) * 0x100000001b3; }
    return (h >> 2) as i64;
}
fn slp_known_nonvect_loads(vl: const i32[:]) -> bool {
    let h = slp_vl_hash(vl);
    var c = slp_lk_head(SH_NVL, h);
    while c >= 0 {
        let at = slp_lk[c].x as i64;
        let n = slp_nvl_runs[at] as i64;
        if n == vl.len {
            var eq = true;
            for k in n { if slp_nvl_runs[at + 1 + k] != vl[k] { eq = false; break; } }
            if eq { return true; }
        }
        c = slp_lk[c].next;
    }
    return false;
}
fn slp_register_nonvect_loads(vl: const i32[:]) {
    if slp_known_nonvect_loads(vl) { return; }
    let at = slp_nvl_runs.len as i32;
    slp_nvl_runs.push(vl.len as i32);
    for v in vl { slp_nvl_runs.push(v); }
    // these links live for the whole function: keep them in a pool deleteTree doesn't truncate
    let h = slp_vl_hash(vl);
    let n = slp_nvl_lk.len as i32;
    slp_nvl_lk.push(SLk { x: at, next: slp_lk_head_nvl(h) });
    sh_set(SH_NVL, h, 0, n as i64);
}
var slp_nvl_lk: SLk[>..];
fn slp_lk_head_nvl(h: i64) -> i32 { sh_get(SH_NVL, h, 0, -1) as i32 }

// ---------------------------------------------------------------- per function / per tree
// BoUpSLP::BoUpSLP (per function)
fn slp_r_begin(fv: i32) {
    slp_fn = fv;
    slp_cur_fn = fv;
    sh_clear(SH_EPH); sh_clear(SH_ALIAS); sh_clear(SH_NVL); sh_clear(SH_SDMAP); sh_clear(SH_DELINST);
    sh_clear(SH_BSMAP); sh_clear(SH_ANRR); sh_clear(SH_ANRV); sh_clear(SH_ANMBW);
    slp_nvl_runs.clear();
    slp_nvl_lk.clear();
    slp_collect_ephemeral_values(fv);
    slp_max_vreg = if flag_given("slp-max-reg-size") { flag_int("slp-max-reg-size", 128) } else { tv_register_bit_width(1) };
    slp_min_vreg = if flag_given("slp-min-reg-size") { flag_int("slp-min-reg-size", 128) } else { tv_min_vector_register_bit_width() };
    slp_sched_function_begin();
    slp_delete_tree();
}
// CodeMetrics::collectEphemeralValues(F, AC, EphValues)
fn slp_collect_ephemeral_values(f: i32) {
    slp_has_eph = false;
    sh_clear(SH_TMP0);
    var wl: i32[>..<] = [];
    fn append_ops(v: i32) {
        for k in nops(v) {
            let o = op(v, k);
            if !sh_add(SH_TMP0, o as i64, 0) { continue; }
            if is_inst(o) && !inst_may_have_side_effects(o) && !is_terminator(o) { wl.push(o); }
        }
    }
    var asms: i32[>..<] = [];
    ac_assumptions(f, asms);     // the function's AssumptionCache (assume.goose)
    for a in asms {
        if inst_func(a) != f { continue; }
        if sh_add(SH_EPH, a as i64, 0) { slp_has_eph = true; append_ops(a); }
    }
    var k: i64 = 0;
    while k < wl.len {
        let v = wl[k];
        k++;
        var all = true;
        var u = vals[v].first_use;
        while u >= 0 { if !sh_has(SH_EPH, uses[u].user as i64, 0) { all = false; break; } u = uses[u].next; }
        if !all { continue; }
        sh_add(SH_EPH, v as i64, 0);
        append_ops(v);
    }
}
fn slp_is_ephemeral(v: i32) -> bool { slp_has_eph && sh_has(SH_EPH, v as i64, 0) }
// deleteTree()
fn slp_delete_tree() {
    slp_te.clear();
    slp_vp.clear();
    slp_ip.clear();
    slp_opl.clear();
    slp_lk.clear();
    sh_clear(SH_S2TE); sh_clear(SH_SPLIT); sh_clear(SH_V2G); sh_clear(SH_MUSTG); sh_clear(SH_NSF);
    sh_clear(SH_OP2TE); sh_clear(SH_COPYABLE); sh_clear(SH_DELNODES); sh_clear(SH_T2G); sh_clear(SH_LANE);
    sh_clear(SH_INSTRSZ); sh_clear(SH_UIL);
    slp_load_entries.clear();
    slp_graph_transform_mode = false;
    slp_gathered_loads_first = -1;
    slp_sched_clear_all();
    slp_reduction_bw = 0;
    slp_base_graph_size = 1;
    slp_cast_bw_valid = false;
    slp_extra_bw_nodes.clear();
    slp_uil_on = false;
    slp_uil_n = 0;
    slp_loop_nest.clear();
    slp_merged_btcs.clear();
}

// newTreeEntry(VL, EntryState, Bundle, S, UserTreeIdx, ReuseShuffleIndices, ReorderIndices): bundle is a schedule
// bundle id (-1 = none / invalid). Returns -1 when a gathered-loads entry is not re-created.
fn slp_new_tree_entry(vl: const i32[:], state: i32, bundle: i32, s: SIS, ui_te: i32, ui_edge: i64,
                      reuse: const i32[:], reorder: const i32[:]) -> i32 {
    if slp_gathered_loads_first >= 0 && state == TE_GATHER && sis_valid(s) && sis_opcode(s) == OP_LOAD && ui_edge == -1 && ui_te < 0 {
        return -1;
    }
    let te = slp_te.len as i32;
    slp_te.push(STE { state: state, cop: CO_NONE, sc: 0, nsc: 0, reuse: 0, nreuse: 0, reord: 0, nreord: 0, ops: 0, nops: 0,
                      ui_te: -1, ui_edge: -1, s_main: -1, s_alt: -1, s_copy: false, inter: 0, no_sched: false,
                      comb: 0, ncomb: 0, ncopyable: 0, vv: -1 });
    if ui_te >= 0 && !sh_has(SH_OP2TE, ui_te as i64, ui_edge) { sh_set(SH_OP2TE, ui_te as i64, ui_edge, te as i64); }
    te_set_reuse(te, reuse);
    if reorder.len == 0 {
        te_set_scalars(te, vl);
        if sis_valid(s) { te_set_operations(te, s); }
    } else {
        let at = slp_vp.len as i32;
        for idx in reorder {
            if (idx as i64) >= vl.len { slp_vp.push(c_undef(vals[vl[0]].ty)); } else { slp_vp.push(vl[idx as i64]); }
        }
        slp_te[te].sc = at;
        slp_te[te].nsc = vl.len as i32;
        let s2 = slp_get_same_opcode(te_scalars(te));
        if sis_valid(s2) { te_set_operations(te, s2); }
        te_set_reorder(te, reorder);
    }
    if state == TE_SPLIT {
        te_set_operations(te, s);
        sh_clear(SH_TMP4);
        for v in vl {
            if !is_inst(v) { continue; }
            if slp_lk_head(SH_SPLIT, v as i64) < 0 {
                slp_lk_push_tail(SH_SPLIT, v as i64, te);
                sh_add(SH_TMP4, v as i64, 0);
            } else if sh_add(SH_TMP4, v as i64, 0) {
                slp_lk_push_tail(SH_SPLIT, v as i64, te);
            }
        }
    } else if state != TE_GATHER {
        if iop(s.main) == OP_PHI || slp_is_vector_like_inst_with_const_ops(s.main) ||
           (!s.copy && slp_does_not_need_to_schedule(vl)) || slp_all_non_schedulable(s, vl) {
            slp_te[te].no_sched = true;
        }
        sh_clear(SH_TMP4);
        for v in vl {
            if is_poison(v) { continue; }
            if sis_is_copyable_element(s, v) { te_add_copyable_element(te, v); continue; }
            if slp_lk_head(SH_S2TE, v as i64) < 0 {
                slp_lk_push_tail(SH_S2TE, v as i64, te);
                sh_add(SH_TMP4, v as i64, 0);
            } else if sh_add(SH_TMP4, v as i64, 0) {
                slp_lk_push_tail(SH_S2TE, v as i64, te);
            }
        }
        if bundle >= 0 { slp_sb_set_tree_entry(bundle, te); }
    } else {
        var all_consts_or_casts = true;
        for v in vl {
            if sis_valid(s) && s.copy && sis_is_copyable_element(s, v) { te_add_copyable_element(te, v); }
            if !slp_is_constant(v) {
                all_consts_or_casts = all_consts_or_casts && is_inst(v) && is_cast_op(iop(v)) && ty_is_int(vals[v].ty);
                if ui_edge != -1 || ui_te < 0 || !te_is_gather(ui_te) {
                    if !slp_lk_contains(SH_V2G, v as i64, te) { slp_lk_push_tail(SH_V2G, v as i64, te); }
                }
            }
        }
        if all_consts_or_casts {
            slp_cast_bw_valid = true;
            slp_cast_bw_max = 0xFFFFFFFF;
            slp_cast_bw_min = 1;
        }
        for v in vl { sh_add(SH_MUSTG, v as i64, 0); }
    }
    if ui_te >= 0 { slp_te[te].ui_te = ui_te; slp_te[te].ui_edge = ui_edge; }
    return te;
}
fn slp_all_non_schedulable(s: SIS, vl: const i32[:]) -> bool {
    for v in vl { if !sis_is_non_schedulable(s, v) { return false; } }
    return true;
}

// TreeEntry::dump
fn slp_dump_te(te: i32) {
    let e = slp_te[te];
    errs_int(te as i64); errs(".\n");
    for k in e.nops as i64 {
        errs("Operand "); errs_int(k); errs(":\n");
        for v in te_operand(te, k) { errs("  "); slp_dv(v); errs("\n"); }
    }
    errs("Scalars: \n");
    let s = te_s(te);
    for v in te_scalars(te) {
        errs("  "); slp_dv(v);
        if sis_valid(s) && sis_is_expanded_binop(s, v) { errs(" [[Expanded]]\n"); } else { errs("\n"); }
    }
    errs("State: ");
    if sis_valid(s) && te_has_copyable_elements(te) { errs("[[Copyable]] "); }
    let st = e.state;
    if st == TE_VECTORIZE {
        if e.inter > 0 { errs("Vectorize with interleave factor "); errs_int(e.inter as i64); errs("\n"); } else { errs("Vectorize\n"); }
    } else if st == TE_SCATTER { errs("ScatterVectorize\n"); }
    else if st == TE_STRIDED { errs("StridedVectorize\n"); }
    else if st == TE_EXPAND { errs("ExpandVectorize\n"); }
    else if st == TE_COMPRESS { errs("CompressVectorize\n"); }
    else if st == TE_GATHER { errs("NeedToGather\n"); }
    else if st == TE_COMBINED { errs("CombinedVectorize\n"); }
    else { errs("SplitVectorize\n"); }
    if sis_valid(s) {
        errs("MainOp: "); slp_dv(s.main); errs("\n");
        errs("AltOp: "); slp_dv(s.alt); errs("\n");
    } else {
        errs("MainOp: NULL\nAltOp: NULL\n");
    }
    errs("VectorizedValue: ");
    if e.vv >= 0 { slp_dv(e.vv); errs("\n"); } else { errs("NULL\n"); }
    errs("ReuseShuffleIndices: ");
    if e.nreuse == 0 { errs("Empty"); } else { for r in te_reuse(te) { errs_int(r as i64); errs(", "); } }
    errs("\n");
    errs("ReorderIndices: ");
    for r in te_reorder(te) { errs_int(r as i64); errs(", "); }
    errs("\n");
    errs("UserTreeIndex: ");
    if e.ui_te >= 0 { slp_dump_edge(e.ui_te, e.ui_edge); } else { errs("<invalid>"); }
    errs("\n");
    if e.ncomb > 0 {
        errs("Combined entries: ");
        for k in e.ncomb as i64 {
            if k > 0 { errs(", "); }
            errs("Entry index "); errs_int(te_comb_idx(te, k) as i64); errs(" with offset "); errs_int(te_comb_off(te, k) as i64);
        }
        errs("\n");
    }
}
fn slp_dump_edge(te: i32, edge: i64) {
    errs("{User:");
    if te >= 0 { errs_int(te as i64); } else { errs("null"); }
    errs(" EdgeIdx:");
    if edge < 0 { errs("4294967295"); } else { errs_int(edge); }
    errs("}");
}
fn slp_dbg_vl(vl: const i32[:]) {
    errs("[");
    for k in vl.len { if k > 0 { errs(", "); } slp_dv(vl[k]); }
    errs("]\n");
}
